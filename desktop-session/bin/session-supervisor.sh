#!/bin/bash
set -euo pipefail

STATE_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/gamehub-session"
REQUEST_FILE="${STATE_DIR}/requested-mode"
CURRENT_FILE="${STATE_DIR}/current-mode"

mkdir -p "${STATE_DIR}"
rm -f "${REQUEST_FILE}"
printf 'steam\n' > "${CURRENT_FILE}"

# --- Splash screen helpers ---
# foot creates an XDG surface on gamescope's Wayland display.  The XDG
# focus fallback promotes it while no X11 window exists.  Once Steam's
# X11 window takes focus the splash is no longer painted.
_splash_pid=""

kill_splash() {
    if [ -n "${_splash_pid}" ]; then
        kill "${_splash_pid}" 2>/dev/null || true
        _splash_pid=""
    fi
}

show_splash() {
    local msg="${1:-Returning to Steam...}"
    kill_splash
    WAYLAND_DISPLAY="${GAMESCOPE_WAYLAND_DISPLAY:-gamescope-0}" \
        foot --fullscreen --app-id=gamehub-splash \
            -o 'colors.background=0d1118' \
            -o 'colors.foreground=8893a8' \
            -o 'font=monospace:size=16' \
            -o 'pad=0x0' \
            sh -c "
                printf '\033[?25l'
                clear
                rows=\$(tput lines 2>/dev/null || echo 40)
                cols=\$(tput cols 2>/dev/null || echo 120)
                y=\$(( rows / 2 ))
                x=\$(( (cols - ${#msg}) / 2 ))
                [ \$x -lt 0 ] && x=0
                printf '\033[%d;%dH%s' \"\$y\" \"\$x\" '${msg}'
                sleep 30
            " &
    _splash_pid=$!
}

wait_for_steam_teardown() {
    local names
    names=(
        steam
        steamwebhelper
        steam-runtime-steam-remote
        steam-runtime-launcher-service
        steamsysinfo
        steam-monitor
    )

    # Ask any stragglers to exit cleanly first.
    for name in "${names[@]}"; do
        pkill -TERM -u "$(id -u)" -x "${name}" >/dev/null 2>&1 || true
    done

    for _ in $(seq 1 50); do
        local still_running=0
        for name in "${names[@]}"; do
            if pgrep -u "$(id -u)" -x "${name}" >/dev/null 2>&1; then
                still_running=1
                break
            fi
        done

        if [ "${still_running}" -eq 0 ]; then
            return 0
        fi

        sleep 0.2
    done

    for name in "${names[@]}"; do
        pkill -KILL -u "$(id -u)" -x "${name}" >/dev/null 2>&1 || true
    done

    sleep 0.5
}

run_steam() {
    rm -f "${REQUEST_FILE}"
    printf 'steam\n' > "${CURRENT_FILE}"
    /usr/local/bin/steam -gamepadui -steamos3 -steampal -steamdeck
}

run_desktop() {
    rm -f "${REQUEST_FILE}"
    printf 'desktop\n' > "${CURRENT_FILE}"
    /usr/local/bin/start-desktop-session.sh
}

mode="steam"

while true; do
    if [ "${mode}" = "steam" ]; then
        if run_steam; then
            rc=0
        else
            rc=$?
        fi
        kill_splash

        requested="$(cat "${REQUEST_FILE}" 2>/dev/null || true)"
        if [ "${requested}" = "desktop" ]; then
            wait_for_steam_teardown
            mode="desktop"
            continue
        fi

        exit "${rc}"
    fi

    if run_desktop; then
        rc=0
    else
        rc=$?
    fi

    requested="$(cat "${REQUEST_FILE}" 2>/dev/null || true)"
    if [ -z "${requested}" ] || [ "${requested}" = "steam" ]; then
        show_splash "Returning to Steam..."
        mode="steam"
        continue
    fi

    exit "${rc}"
done
