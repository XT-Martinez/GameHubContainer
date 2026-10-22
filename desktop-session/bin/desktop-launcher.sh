#!/bin/bash
set -euo pipefail

# Toggle: if fuzzel is already open, kill it; otherwise launch it.
if pkill -x fuzzel 2>/dev/null; then
    exit 0
fi

exec /usr/bin/fuzzel \
    --config="${XDG_CONFIG_HOME:-$HOME/.config}/gamehub-desktop/fuzzel/fuzzel.ini"
