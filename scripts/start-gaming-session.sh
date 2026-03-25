#!/bin/bash
# Launch gamescope session with Steam Big Picture.
#
# gamescope-session-plus handles:
#   - gamescope command-line flags (resolution, refresh rate)
#   - Environment setup (SDL, shader cache, controller mappings)
#   - Steam launch in Big Picture / Game Mode
#
# This script blocks until gamescope exits.

set -euo pipefail

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export HOME="${HOME:-/home/gamer}"

# Ensure XDG_RUNTIME_DIR exists
mkdir -p "$XDG_RUNTIME_DIR"

# SDL controller database
if [ -f /usr/share/sdl/gamecontrollerdb.txt ]; then
    export SDL_GAMECONTROLLERCONFIG_FILE=/usr/share/sdl/gamecontrollerdb.txt
fi

exec gamescope-session-plus steam
