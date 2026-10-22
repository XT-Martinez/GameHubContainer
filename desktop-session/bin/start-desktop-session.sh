#!/bin/bash
set -euo pipefail

export XDG_CURRENT_DESKTOP=labwc
export XDG_SESSION_DESKTOP=labwc
export XDG_SESSION_TYPE=wayland
export MOZ_ENABLE_WAYLAND=1
export QT_QPA_PLATFORM=wayland
export QT_WAYLAND_DISABLE_WINDOWDECORATION=1
export GTK_THEME=adw-gtk3-dark
export XCURSOR_THEME=Adwaita
export XCURSOR_SIZE=24
export LABWC_UPDATE_ACTIVATION_ENV=1
export WAYLAND_DISPLAY="${GAMESCOPE_WAYLAND_DISPLAY:-${WAYLAND_DISPLAY:-gamescope-0}}"
export WLR_BACKENDS=wayland
export WLR_RENDERER=vulkan
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"

# Fluent icons, with folders in the accent colour (built by gamehub-theme)
export ICON_THEME=GameHub
export XDG_DATA_DIRS="/usr/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"

# Steam-specific input method hooks are useful in game mode, but they make
# desktop applications behave oddly in the nested session.
unset BACKEND
unset GTK_IM_MODULE
unset LIBSEAT_BACKEND
unset QT_IM_MODULE

# GTK theme, icons, cursor and fonts for GTK 3 and GTK 4 apps
for v in 3.0 4.0; do
    mkdir -p "${XDG_CONFIG_HOME}/gtk-${v}"
    cat > "${XDG_CONFIG_HOME}/gtk-${v}/settings.ini" <<GTKEOF
[Settings]
gtk-application-prefer-dark-theme=1
gtk-icon-theme-name=GameHub
gtk-theme-name=adw-gtk3-dark
gtk-cursor-theme-name=Adwaita
gtk-cursor-theme-size=24
gtk-font-name=Inter 10
GTKEOF
done

# libadwaita and portal-aware apps read these instead of settings.ini
if command -v gsettings >/dev/null 2>&1; then
    gsettings set org.gnome.desktop.interface color-scheme prefer-dark 2>/dev/null || true
    gsettings set org.gnome.desktop.interface gtk-theme adw-gtk3-dark 2>/dev/null || true
    gsettings set org.gnome.desktop.interface icon-theme GameHub 2>/dev/null || true
    gsettings set org.gnome.desktop.interface font-name 'Inter 10' 2>/dev/null || true
    gsettings set org.gnome.desktop.interface monospace-font-name 'JetBrains Mono 11' 2>/dev/null || true
fi

# Render the themed configs (labwc theme, waybar, fuzzel, mako, dock, GTK
# accent, icon theme) for the saved wallpaper and accent colour
/usr/local/bin/gamehub-theme apply --no-reload || true

exec /usr/bin/labwc -C /usr/share/gamehub-desktop/labwc
