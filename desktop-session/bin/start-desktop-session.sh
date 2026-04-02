#!/bin/bash
set -euo pipefail

export XDG_CURRENT_DESKTOP=labwc
export XDG_SESSION_DESKTOP=labwc
export XDG_SESSION_TYPE=wayland
export MOZ_ENABLE_WAYLAND=1
export QT_QPA_PLATFORM=wayland
export QT_WAYLAND_DISABLE_WINDOWDECORATION=1
export GTK_THEME=Adwaita:dark
export XCURSOR_THEME=Adwaita
export XCURSOR_SIZE=24
export LABWC_UPDATE_ACTIVATION_ENV=1
export WAYLAND_DISPLAY="${GAMESCOPE_WAYLAND_DISPLAY:-${WAYLAND_DISPLAY:-gamescope-0}}"
export WLR_BACKENDS=wayland

# Steam-specific input method hooks are useful in game mode, but they make
# desktop applications behave oddly in the nested session.
unset BACKEND
unset GTK_IM_MODULE
unset LIBSEAT_BACKEND
unset QT_IM_MODULE

exec /usr/bin/labwc -C /usr/share/gamehub-desktop/labwc
