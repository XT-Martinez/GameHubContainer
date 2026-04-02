#!/bin/bash
set -euo pipefail

STATE_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/gamehub-session"
REQUEST_FILE="${STATE_DIR}/requested-mode"

mkdir -p "${STATE_DIR}"
printf 'steam\n' > "${REQUEST_FILE}"

# If the user launched the desktop Steam client, close it before returning
# to the gamepad UI so Steam comes back in a clean mode.
# Only send +quit when Steam is already running — otherwise it would start
# a new instance just to shut it down.
if pgrep -u "$(id -u)" -x steam >/dev/null 2>&1; then
    /usr/local/bin/steam +quit >/dev/null 2>&1 || true
    sleep 1
fi

pkill -u "$(id -u)" -x labwc || true
