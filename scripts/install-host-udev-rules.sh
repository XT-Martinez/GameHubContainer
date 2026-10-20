#!/bin/bash
# Install the container input udev rules for the rootless GameHubContainer.
#
# Installs the rules (container-input-shim/99-sunshine-container-ignore.rules)
# to /etc/udev/rules.d/ and the node-hiding helper to /usr/local/libexec/,
# filling the helper's placeholders with the host user that runs the rootless
# container (and that user's primary group), then re-triggers udev for the
# affected subsystems.
#
# The helper hides container input nodes in a directory owned by the host subuid
# that container root maps to. That uid is the start of the target user's entry
# in /etc/subuid (and the gid is the start of its entry in /etc/subgid), because
# --userns=keep-id:uid=1000,gid=1000 maps container root to subuid start.
#
# Usage: scripts/install-host-udev-rules.sh [host-user]
#   host-user defaults to $SUDO_USER, then to the current user.
#   Root is refused as the target user.
#
# Re-runs itself with sudo when not already root.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE="$REPO_DIR/container-input-shim/99-sunshine-container-ignore.rules"
DEST="/etc/udev/rules.d/99-sunshine-container-ignore.rules"
HELPER_SRC="$SCRIPT_DIR/gamehub-hide-input-node"
HELPER_DEST="/usr/local/libexec/gamehub-hide-input-node"

die() {
    echo "install-host-udev-rules: $*" >&2
    exit 1
}

TARGET_USER="${1:-${SUDO_USER:-$(id -un)}}"

[[ "$TARGET_USER" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid user name: '$TARGET_USER'"
id -u "$TARGET_USER" >/dev/null 2>&1 || die "no such user: '$TARGET_USER'"
[ "$(id -u "$TARGET_USER")" -ne 0 ] || die "refusing to use root as the target user; pass your own user name"

TARGET_GROUP="$(id -gn "$TARGET_USER")"
[[ "$TARGET_GROUP" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid primary group name: '$TARGET_GROUP'"

[ -f "$TEMPLATE" ] || die "template not found: $TEMPLATE"
[ -f "$HELPER_SRC" ] || die "helper not found: $HELPER_SRC"

# Host uid/gid that container root maps to: the start of the target user's subuid/subgid range.
# Matches by user name, or by numeric uid/gid in the first field.
subid_start() {
    local file="$1" name="$2" numeric="$3" start
    [ -r "$file" ] || die "cannot read $file"
    start="$(awk -F: -v n="$name" -v num="$numeric" '$1 == n || $1 == num { print $2; exit }' "$file")"
    [[ "$start" =~ ^[0-9]+$ ]] || die "no subid range for '$name' in $file (needed for rootless container node hiding)"
    printf '%s\n' "$start"
}

HIDE_UID="$(subid_start /etc/subuid "$TARGET_USER" "$(id -u "$TARGET_USER")")"
HIDE_GID="$(subid_start /etc/subgid "$TARGET_USER" "$(id -g "$TARGET_USER")")"

if [ "$(id -u)" -ne 0 ]; then
    echo "install-host-udev-rules: re-running with sudo for $TARGET_USER:$TARGET_GROUP"
    exec sudo -- "$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")" "$TARGET_USER"
fi

tmp="$(mktemp)"
helper_tmp="$(mktemp)"
trap 'rm -f "$tmp" "$helper_tmp"' EXIT

sed -e "s|@GAMEHUB_USER@|$TARGET_USER|g" \
    -e "s|@GAMEHUB_GROUP@|$TARGET_GROUP|g" \
    "$TEMPLATE" > "$tmp"

if grep -q '@GAMEHUB_' "$tmp"; then
    die "unsubstituted placeholder left in rendered rules; refusing to install"
fi

sed -e "s|@GAMEHUB_HIDE_UID@|$HIDE_UID|g" \
    -e "s|@GAMEHUB_HIDE_GID@|$HIDE_GID|g" \
    -e "s|@GAMEHUB_NODE_USER@|$TARGET_USER|g" \
    -e "s|@GAMEHUB_NODE_GROUP@|$TARGET_GROUP|g" \
    "$HELPER_SRC" > "$helper_tmp"

if grep -q '@GAMEHUB_' "$helper_tmp"; then
    die "unsubstituted placeholder left in helper; refusing to install"
fi

install -D -m 0755 -o root -g root "$helper_tmp" "$HELPER_DEST"
echo "install-host-udev-rules: installed $HELPER_DEST (hide uid:gid $HIDE_UID:$HIDE_GID)"

install -m 0644 -o root -g root "$tmp" "$DEST"
echo "install-host-udev-rules: installed $DEST (owner $TARGET_USER:$TARGET_GROUP)"

udevadm control --reload-rules
udevadm trigger --subsystem-match=input --subsystem-match=hidraw --subsystem-match=misc
echo "install-host-udev-rules: udev rules reloaded and triggered"
