#!/bin/bash
# Wait for gamescope's Wayland display socket to appear, then write
# an environment file that sunshine.service reads via EnvironmentFile=.
#
# Gamescope (wlroots) creates wayland-N in XDG_RUNTIME_DIR.
# In a fresh container this is typically wayland-1.

set -euo pipefail

XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
ENV_FILE="$XDG_RUNTIME_DIR/sunshine-wayland.env"
TIMEOUT=30

for i in $(seq 1 "$TIMEOUT"); do
    for sock in "$XDG_RUNTIME_DIR"/wayland-*; do
        # Skip the glob pattern itself if no match
        [ -S "$sock" ] || continue

        WAYLAND_DISPLAY="$(basename "$sock")"
        echo "WAYLAND_DISPLAY=$WAYLAND_DISPLAY" > "$ENV_FILE"
        echo "Found Wayland display: $WAYLAND_DISPLAY"
        exit 0
    done
    sleep 1
done

echo "ERROR: No Wayland display found after ${TIMEOUT}s" >&2
exit 1
