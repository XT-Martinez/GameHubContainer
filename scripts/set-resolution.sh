#!/bin/bash
# Resolution matching for Sunshine prep command.
#
# Gamescope doesn't support dynamic resolution changes via xrandr or wlr-randr.
# The output resolution is set at gamescope startup via SCREEN_WIDTH/SCREEN_HEIGHT
# environment variables (see start-gaming-session.sh).
#
# This script logs the client request for debugging. To change the streaming
# resolution, restart the container with different env vars:
#   -e SCREEN_WIDTH=2560 -e SCREEN_HEIGHT=1440

WIDTH="${SUNSHINE_CLIENT_WIDTH:-unknown}"
HEIGHT="${SUNSHINE_CLIENT_HEIGHT:-unknown}"
FPS="${SUNSHINE_CLIENT_FPS:-unknown}"

echo "Client requested: ${WIDTH}x${HEIGHT}@${FPS}Hz"
echo "Gamescope output resolution is fixed at startup (SCREEN_WIDTH x SCREEN_HEIGHT)"


