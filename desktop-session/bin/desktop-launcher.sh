#!/bin/bash
set -euo pipefail

exec /usr/bin/wofi \
    --show drun \
    --prompt "Applications" \
    --style /usr/share/gamehub-desktop/wofi/style.css
