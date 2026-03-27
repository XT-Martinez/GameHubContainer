#!/bin/bash
# Launch gamescope session with Steam Big Picture.
#
# gamescope-session-plus handles:
#   - gamescope command-line flags (resolution, refresh rate)
#   - Environment setup (SDL, shader cache, controller mappings)
#   - Steam launch in Big Picture / Game Mode
#
# This script blocks until gamescope exits.
#
# Resolution/refresh rate are set at gamescope startup via env vars:
#   SCREEN_WIDTH  (default: 1920)
#   SCREEN_HEIGHT (default: 1080)
#   CUSTOM_REFRESH_RATES (default: 60,90,120 — gamescope --custom-refresh-rates)

set -euo pipefail

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export HOME="${HOME:-/home/gamer}"

# Ensure XDG_RUNTIME_DIR exists
mkdir -p "$XDG_RUNTIME_DIR"

# SDL controller database
if [ -f /usr/share/sdl/gamecontrollerdb.txt ]; then
    export SDL_GAMECONTROLLERCONFIG_FILE=/usr/share/sdl/gamecontrollerdb.txt
fi

# Container has no seat/session — force headless backend without libseat.
# These must be set in the systemd user manager so they propagate to
# gamescope-session-plus@steam.service (which is started as a separate unit).
systemctl --user import-environment 2>/dev/null || true
systemctl --user set-environment \
    LIBSEAT_BACKEND=noop \
    WLR_BACKENDS=headless \
    BACKEND=headless \
    LD_PRELOAD=/usr/lib64/libuinput_shim.so \
    SCREEN_WIDTH="${SCREEN_WIDTH:-1920}" \
    SCREEN_HEIGHT="${SCREEN_HEIGHT:-1080}" \
    CUSTOM_REFRESH_RATES="${CUSTOM_REFRESH_RATES:-60,90,120}" \
    CONTAINER_ID="${CONTAINER_ID:-default}" \
    ${SUNSHINE_PORT:+SUNSHINE_PORT=$SUNSHINE_PORT}

exec gamescope-session-plus steam
