#!/bin/bash
# Set gamescope output resolution to match the Moonlight client request.
# Called by Sunshine as a global_prep_cmd on stream start.
#
# Environment (set by Sunshine):
#   SUNSHINE_CLIENT_WIDTH   - requested width (e.g. 1920)
#   SUNSHINE_CLIENT_HEIGHT  - requested height (e.g. 1080)
#   SUNSHINE_CLIENT_FPS     - requested framerate (e.g. 60)
#   SUNSHINE_CLIENT_HDR     - HDR requested (true/false)
#   WAYLAND_DISPLAY         - gamescope's Wayland display

set -euo pipefail

WIDTH="${SUNSHINE_CLIENT_WIDTH:-1920}"
HEIGHT="${SUNSHINE_CLIENT_HEIGHT:-1080}"
FPS="${SUNSHINE_CLIENT_FPS:-60}"

if ! command -v wlr-randr &>/dev/null; then
    echo "wlr-randr not found, skipping resolution change" >&2
    exit 0
fi

# Discover the output name (first output from wlr-randr)
OUTPUT="$(wlr-randr 2>/dev/null | awk 'NR==1 {print $1}')"
if [ -z "$OUTPUT" ]; then
    echo "No wlr-randr output found, skipping resolution change" >&2
    exit 0
fi

echo "Setting ${OUTPUT} to ${WIDTH}x${HEIGHT}@${FPS}Hz"

# Try custom-mode first (arbitrary resolution), fall back to standard mode
wlr-randr --output "$OUTPUT" --custom-mode "${WIDTH}x${HEIGHT}@${FPS}" 2>&1 || \
wlr-randr --output "$OUTPUT" --mode "${WIDTH}x${HEIGHT}" 2>&1 || \
    echo "WARNING: Could not set resolution ${WIDTH}x${HEIGHT}@${FPS}" >&2

# Always exit 0 — don't block the stream if resolution change fails
exit 0
