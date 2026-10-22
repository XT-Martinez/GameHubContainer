#!/bin/bash
# Install RyzenAdj and the GameHub RyzenAdj helper on the host, so rootless
# containers can set APU power limits without root or /dev/mem access.
#
# Builds RyzenAdj (pinned release) in a throwaway Fedora container with
# rootless podman, then installs:
#   /usr/local/bin/ryzenadj                     host RyzenAdj
#   /usr/local/libexec/gamehub-ryzenadjd        per-request helper (scripts/gamehub-ryzenadjd)
#   /etc/systemd/system/gamehub-ryzenadj.socket and gamehub-ryzenadj@.service
#   /etc/gamehub/ryzenadj.conf                  allowed uids and value ranges
#                                               (kept if it already exists)
#   /usr/local/libexec/gamehub-cpufreq-access   boot-time handover of the CPU
#   /etc/systemd/system/gamehub-cpufreq-access.service  EPP, governor and
#   /etc/gamehub/cpufreq-access.conf            boost files (scripts/gamehub-cpufreq-access)
# and enables the socket at /run/gamehub-ryzenadj/ryzenadj.sock. run.sh binds
# that directory into rootless containers, where /usr/local/bin/ryzenadj
# (scripts/ryzenadj) forwards to it, and binds /sys/devices/system/cpu
# read-write once the cpufreq files are handed over.
#
# Usage: scripts/install-host-ryzenadj.sh [host-user]
#   host-user defaults to $SUDO_USER, then to the current user. The user and
#   its subuid range (its rootless containers) are allowed to send requests.
#   Set RYZENADJ_BIN to install an existing ryzenadj binary instead of building.
#
# Builds as the current user, then re-runs itself with sudo to install.

set -euo pipefail

RYZENADJ_REPO="https://github.com/FlyGoat/RyzenAdj.git"
RYZENADJ_TAG="v0.19.0"
RYZENADJ_COMMIT="ea71739b4a3e1a0a624dfd1c9c268a31cb2a4182"
BUILD_IMAGE="registry.fedoraproject.org/fedora:44"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
HELPER_SRC="$SCRIPT_DIR/gamehub-ryzenadjd"
CPUFREQ_SRC="$SCRIPT_DIR/gamehub-cpufreq-access"
CONF_TEMPLATE="$REPO_DIR/configs/gamehub-ryzenadj.conf"
UNIT_DIR_SRC="$REPO_DIR/services/host"

die() {
    echo "install-host-ryzenadj: $*" >&2
    exit 1
}

TARGET_USER="${1:-${SUDO_USER:-$(id -un)}}"

[[ "$TARGET_USER" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid user name: '$TARGET_USER'"
id -u "$TARGET_USER" >/dev/null 2>&1 || die "no such user: '$TARGET_USER'"
TARGET_UID="$(id -u "$TARGET_USER")"
TARGET_GID="$(id -g "$TARGET_USER")"
[ "$TARGET_UID" -ne 0 ] || die "refusing to use root as the target user; pass your own user name"

for f in "$HELPER_SRC" "$CPUFREQ_SRC" "$CONF_TEMPLATE" "$UNIT_DIR_SRC/gamehub-ryzenadj.socket" \
    "$UNIT_DIR_SRC/gamehub-ryzenadj@.service" "$UNIT_DIR_SRC/gamehub-cpufreq-access.service"; do
    [ -f "$f" ] || die "not found: $f"
done

# The user's rootless containers run as uids from its subuid range.
SUBUID_RANGE="$(awk -F: -v n="$TARGET_USER" -v num="$TARGET_UID" \
    '($1 == n || $1 == num) && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ { print $2 "-" ($2 + $3 - 1); exit }' /etc/subuid)"
[[ "$SUBUID_RANGE" =~ ^[0-9]+-[0-9]+$ ]] || die "no subuid range for '$TARGET_USER' in /etc/subuid"

if [ "$(id -u)" -ne 0 ]; then
    # Reinstall without rebuilding when the pinned version is already installed.
    if [ -z "${RYZENADJ_BIN:-}" ] && [ -x /usr/local/bin/ryzenadj ] && \
        [ "$(/usr/local/bin/ryzenadj --help 2>&1 | sed -n 's/^Version: *//p' | tr -d ' ')" = "$RYZENADJ_TAG" ]; then
        echo "install-host-ryzenadj: RyzenAdj $RYZENADJ_TAG already installed, not rebuilding"
        RYZENADJ_BIN=/usr/local/bin/ryzenadj
    fi
    if [ -z "${RYZENADJ_BIN:-}" ]; then
        command -v podman >/dev/null || die "podman is needed to build RyzenAdj (or set RYZENADJ_BIN)"
        build_dir="$(mktemp -d /tmp/gamehub-ryzenadj.XXXXXX)"
        echo "install-host-ryzenadj: building RyzenAdj $RYZENADJ_TAG in $BUILD_IMAGE"
        podman run --rm -v "$build_dir:/out:Z" "$BUILD_IMAGE" bash -euc '
            dnf -y -q install git gcc gcc-c++ cmake make pciutils-devel >/dev/null
            git clone -q --depth 1 --branch "$1" "$2" /src 2>/dev/null
            [ "$(git -C /src rev-parse HEAD)" = "$3" ] || { echo "unexpected commit for $1" >&2; exit 1; }
            cmake -S /src -B /build -DCMAKE_BUILD_TYPE=Release >/dev/null
            make -C /build -j"$(nproc)" >/dev/null
            install -m 0755 /build/ryzenadj /out/ryzenadj' \
            _ "$RYZENADJ_TAG" "$RYZENADJ_REPO" "$RYZENADJ_COMMIT"
        RYZENADJ_BIN="$build_dir/ryzenadj"
    fi
    [ -x "$RYZENADJ_BIN" ] || die "not an executable: $RYZENADJ_BIN"
    echo "install-host-ryzenadj: re-running with sudo for $TARGET_USER"
    exec sudo -- env RYZENADJ_BIN="$RYZENADJ_BIN" "$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")" "$TARGET_USER"
fi

[ -x "${RYZENADJ_BIN:-}" ] || die "RYZENADJ_BIN must point to a ryzenadj binary when run as root"

if ! [ "$RYZENADJ_BIN" -ef /usr/local/bin/ryzenadj ]; then
    install -D -m 0755 -o root -g root "$RYZENADJ_BIN" /usr/local/bin/ryzenadj
fi
install -D -m 0755 -o root -g root "$HELPER_SRC" /usr/local/libexec/gamehub-ryzenadjd
install -D -m 0755 -o root -g root "$CPUFREQ_SRC" /usr/local/libexec/gamehub-cpufreq-access
install -m 0644 -o root -g root "$UNIT_DIR_SRC/gamehub-ryzenadj.socket" "$UNIT_DIR_SRC/gamehub-ryzenadj@.service" \
    "$UNIT_DIR_SRC/gamehub-cpufreq-access.service" /etc/systemd/system/
echo "install-host-ryzenadj: installed /usr/local/bin/ryzenadj ($(/usr/local/bin/ryzenadj --help 2>&1 | sed -n 's/^Version: //p'))"

if [ -e /etc/gamehub/ryzenadj.conf ]; then
    echo "install-host-ryzenadj: keeping existing /etc/gamehub/ryzenadj.conf"
else
    tmp="$(mktemp)"
    trap 'rm -f "$tmp"' EXIT
    sed -e "s|@GAMEHUB_UID@|$TARGET_UID|g" -e "s|@GAMEHUB_SUBUID_RANGE@|$SUBUID_RANGE|g" "$CONF_TEMPLATE" > "$tmp"
    if grep -q '@GAMEHUB_' "$tmp"; then
        die "unsubstituted placeholder left in config; refusing to install"
    fi
    install -D -m 0644 -o root -g root "$tmp" /etc/gamehub/ryzenadj.conf
    echo "install-host-ryzenadj: installed /etc/gamehub/ryzenadj.conf (uids $TARGET_UID, $SUBUID_RANGE)"
fi

# Container root in the user's keep-id containers is the first subuid; the
# user's group covers container root in plain rootless containers.
printf 'CPUFREQ_OWNER_UID=%s\nCPUFREQ_GROUP_GID=%s\n' "${SUBUID_RANGE%-*}" "$TARGET_GID" > /etc/gamehub/cpufreq-access.conf.new
chmod 0644 /etc/gamehub/cpufreq-access.conf.new
mv -f /etc/gamehub/cpufreq-access.conf.new /etc/gamehub/cpufreq-access.conf

systemctl daemon-reload
systemctl enable --now gamehub-ryzenadj.socket
systemctl enable gamehub-cpufreq-access.service
systemctl restart gamehub-cpufreq-access.service
echo "install-host-ryzenadj: gamehub-ryzenadj.socket and gamehub-cpufreq-access.service enabled; restart containers with run.sh to bind them in"
