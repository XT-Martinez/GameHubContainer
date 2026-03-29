#!/bin/bash
# Resolution matching for Sunshine prep command.
#
# When a Moonlight client connects, Sunshine sets SUNSHINE_CLIENT_WIDTH,
# SUNSHINE_CLIENT_HEIGHT, and SUNSHINE_CLIENT_FPS, then runs this script.
# We use wlr-randr to dynamically change gamescope's output resolution
# via the wlr-output-management Wayland protocol.

WIDTH="${SUNSHINE_CLIENT_WIDTH:-}"
HEIGHT="${SUNSHINE_CLIENT_HEIGHT:-}"
FPS="${SUNSHINE_CLIENT_FPS:-}"

if [ -z "$WIDTH" ] || [ -z "$HEIGHT" ]; then
    echo "set-resolution: no client resolution provided, skipping"
    exit 0
fi

# Default to 60 if FPS not provided
FPS="${FPS:-60}"

echo "set-resolution: requesting ${WIDTH}x${HEIGHT}@${FPS}Hz"

# Use gamescope's wayland display
export WAYLAND_DISPLAY="${GAMESCOPE_WAYLAND_DISPLAY:-${WAYLAND_DISPLAY:-gamescope-0}}"

# Apply the mode change via wlr-output-management protocol
if wlr-randr --output gamescope --custom-mode "${WIDTH}x${HEIGHT}@${FPS}"; then
    echo "set-resolution: mode change applied successfully"
else
    echo "set-resolution: wlr-randr failed (exit $?), resolution unchanged" >&2
    exit 1
fi
