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
export PATH="/usr/local/bin:${PATH}"

# Ensure XDG_RUNTIME_DIR exists
mkdir -p "$XDG_RUNTIME_DIR"

# SDL controller database
if [ -f /usr/share/sdl/gamecontrollerdb.txt ]; then
    export SDL_GAMECONTROLLERCONFIG_FILE=/usr/share/sdl/gamecontrollerdb.txt
fi

# Container has no seat/session — force headless backend without libseat.
# Export to current shell (for the exec'd gamescope-session-plus below)
# AND set in the systemd user manager (for services started later, e.g. sunshine).
export LIBSEAT_BACKEND=noop
export WLR_BACKENDS=headless
export BACKEND=headless
export SCREEN_WIDTH="${SCREEN_WIDTH:-1920}"
export SCREEN_HEIGHT="${SCREEN_HEIGHT:-1080}"
export CUSTOM_REFRESH_RATES="${CUSTOM_REFRESH_RATES:-60,90,120}"
export CONTAINER_ID="${CONTAINER_ID:-default}"
export ENABLE_GAMESCOPE_HDR="${ENABLE_GAMESCOPE_HDR:-1}"
export ENABLE_GAMESCOPE_WSI="${ENABLE_GAMESCOPE_WSI:-1}"
export GAMESCOPE_PATCHED_EDID_FILE="${XDG_RUNTIME_DIR}/gamescope-edid.bin"
${SUNSHINE_PORT:+export SUNSHINE_PORT=$SUNSHINE_PORT}

# Write env vars to environment.d so gamescope-session-plus sources them.
# gamescope-session-plus reads ~/.config/environment.d/*.conf with set -a,
# ensuring variables like CUSTOM_REFRESH_RATES reach gamescope.
mkdir -p "${HOME}/.config/environment.d"
cat > "${HOME}/.config/environment.d/container.conf" <<ENVEOF
CUSTOM_REFRESH_RATES=${CUSTOM_REFRESH_RATES}
ENABLE_GAMESCOPE_HDR=${ENABLE_GAMESCOPE_HDR}
ENABLE_GAMESCOPE_WSI=${ENABLE_GAMESCOPE_WSI}
BACKEND=${BACKEND}
LIBSEAT_BACKEND=${LIBSEAT_BACKEND}
WLR_BACKENDS=${WLR_BACKENDS}
GAMESCOPE_PATCHED_EDID_FILE=${GAMESCOPE_PATCHED_EDID_FILE}
DXVK_HDR=1
ENABLE_HDR_WSI=1
ENVEOF

systemctl --user import-environment 2>/dev/null || true
systemctl --user set-environment \
    LIBSEAT_BACKEND="$LIBSEAT_BACKEND" \
    WLR_BACKENDS="$WLR_BACKENDS" \
    BACKEND="$BACKEND" \
    SCREEN_WIDTH="$SCREEN_WIDTH" \
    SCREEN_HEIGHT="$SCREEN_HEIGHT" \
    CUSTOM_REFRESH_RATES="$CUSTOM_REFRESH_RATES" \
    CONTAINER_ID="$CONTAINER_ID" \
    ENABLE_GAMESCOPE_HDR="$ENABLE_GAMESCOPE_HDR" \
    ENABLE_GAMESCOPE_WSI="$ENABLE_GAMESCOPE_WSI" \
    GAMESCOPE_PATCHED_EDID_FILE="$GAMESCOPE_PATCHED_EDID_FILE" \
    ${SUNSHINE_PORT:+SUNSHINE_PORT=$SUNSHINE_PORT}

exec gamescope-session-plus steam
