#!/bin/bash
# Wait for gamescope's Wayland display socket to appear, then write
# an environment file that sunshine.service reads via EnvironmentFile=.
#
# Gamescope creates a Wayland socket named gamescope-N in XDG_RUNTIME_DIR.
# We only match gamescope-* sockets to avoid latching onto other Wayland
# compositors (PipeWire, etc.) that may appear first.

set -euo pipefail

XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
ENV_FILE="$XDG_RUNTIME_DIR/sunshine-wayland.env"
TIMEOUT=60

for i in $(seq 1 "$TIMEOUT"); do
    for sock in "$XDG_RUNTIME_DIR"/gamescope-*; do
        # Skip the glob pattern itself if no match
        [ -S "$sock" ] || continue

        WAYLAND_DISPLAY="$(basename "$sock")"
        echo "Found Wayland display: $WAYLAND_DISPLAY"

        # Wait for gamescope to finish protocol registration.
        # The socket appears before all globals (like gamescope_scanout)
        # are registered, causing early connections to miss protocols.
        sleep 3

        # Verify socket still exists (gamescope may recreate display during init)
        if [ -S "$sock" ]; then
            echo "WAYLAND_DISPLAY=$WAYLAND_DISPLAY" > "$ENV_FILE"
            echo "Wayland display verified: $WAYLAND_DISPLAY"
            exit 0
        fi

        echo "Socket disappeared, continuing to wait..."
    done
    sleep 1
done

echo "ERROR: No gamescope Wayland display found after ${TIMEOUT}s" >&2
exit 1
