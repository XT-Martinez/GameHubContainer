#!/bin/bash
# Install the container input udev rules for the rootless GameHubContainer.
#
# The rules template (container-input-shim/99-sunshine-container-ignore.rules)
# contains @GAMEHUB_USER@ and @GAMEHUB_GROUP@ placeholders. This script fills
# them in with the host user that runs the rootless container (and that user's
# primary group), installs the result to /etc/udev/rules.d/, and re-triggers
# udev for the affected subsystems.
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

if [ "$(id -u)" -ne 0 ]; then
    echo "install-host-udev-rules: re-running with sudo for $TARGET_USER:$TARGET_GROUP"
    exec sudo -- "$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")" "$TARGET_USER"
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

sed -e "s|@GAMEHUB_USER@|$TARGET_USER|g" \
    -e "s|@GAMEHUB_GROUP@|$TARGET_GROUP|g" \
    "$TEMPLATE" > "$tmp"

if grep -q '@GAMEHUB_' "$tmp"; then
    die "unsubstituted placeholder left in rendered rules; refusing to install"
fi

install -m 0644 -o root -g root "$tmp" "$DEST"
echo "install-host-udev-rules: installed $DEST (owner $TARGET_USER:$TARGET_GROUP)"

udevadm control --reload-rules
udevadm trigger --subsystem-match=input --subsystem-match=hidraw --subsystem-match=misc
echo "install-host-udev-rules: udev rules reloaded and triggered"
