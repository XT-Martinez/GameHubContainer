#!/bin/bash
set -euo pipefail

# Ask first when a person started this from the desktop. Callers that already
# asked (Steam's own session switch) pass --yes. Go on when the user accepts
# (0) or the prompt could not start at all (e.g. 1, 127), so a broken prompt
# never traps the user; stay on a cancel (10) or when it was killed (>128).
if [ "${1:-}" != "--yes" ] && [ -n "${WAYLAND_DISPLAY:-}" ] && pgrep -u "$(id -u)" -x labwc >/dev/null 2>&1; then
    /usr/local/bin/gamehub-confirm \
        --title "Return to Game Mode?" \
        --body "The desktop closes and Steam opens in Game Mode. Save your work in open apps first." \
        --icon steam --accept "Return to Game Mode" --cancel "Stay on Desktop" || rc=$?
    if [ "${rc:-0}" -eq 10 ] || [ "${rc:-0}" -gt 128 ]; then
        exit 0
    fi
fi

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
