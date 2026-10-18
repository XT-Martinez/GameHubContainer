#!/bin/bash
set -euo pipefail

export MOZ_ENABLE_WAYLAND=1
exec /usr/local/bin/steam
