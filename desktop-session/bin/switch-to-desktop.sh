#!/bin/bash
set -euo pipefail

STATE_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/gamehub-session"
REQUEST_FILE="${STATE_DIR}/requested-mode"

mkdir -p "${STATE_DIR}"
printf 'desktop\n' > "${REQUEST_FILE}"

# Exiting Steam is the handoff point. The session supervisor keeps the outer
# gamescope process alive and replaces Steam with the nested desktop.
/usr/local/bin/steam +quit >/dev/null 2>&1 || true
