#!/bin/bash
# Launch GameHubContainer instance
# Usage: ./run.sh [instance-number] [sunshine-port]
#   instance 1 uses default ports (47984-48010)
#   instance 2+ needs explicit sunshine port (e.g., 57989)

set -euo pipefail

INSTANCE="${1:-1}"
PORT="${2:-}"
NAME="sunshine-${INSTANCE}"
HIDRAW_MAJOR=$(grep hidraw /proc/devices | awk '{print $1}')

echo "Container Name: $NAME"
echo "Resolution: ${SCREEN_WIDTH:-1920}x${SCREEN_HEIGHT:-1080}"

# Build port args
PORT_ARGS=()
if [[ -n "$PORT" ]]; then
    HTTP=$((PORT - 5))
    HTTPS=$((PORT + 1))
    RTSP=$PORT
    CONTROL=$((PORT + 21))
    VIDEO=$((PORT + 9))
    AUDIO=$((PORT + 10))
    MIC=$((PORT + 11))
    PORT_ARGS=(
        -e "SUNSHINE_PORT=${PORT}"
        -p "${HTTP}:${HTTP}/tcp"
        -p "${HTTPS}:${HTTPS}/tcp"
        -p "${RTSP}:${RTSP}/tcp"
        -p "${CONTROL}:${CONTROL}/tcp"
        -p "${VIDEO}:${VIDEO}/udp"
        -p "${AUDIO}:${AUDIO}/udp"
        -p "${MIC}:${MIC}/udp"
    )
else
    # Default ports — use host networking
    PORT_ARGS=(--network=host)
fi

echo "Starting ${NAME} (hidraw major=${HIDRAW_MAJOR})"
[[ -n "$PORT" ]] && echo "  Sunshine port: ${PORT}" || echo "  Sunshine port: default (47989)"

sudo podman run -d --rm \
    --name "${NAME}" \
    --hostname "${NAME}" \
    --replace \
    --systemd=true \
    --shm-size=1g \
    --cap-add SYS_ADMIN --cap-add MKNOD --cap-add NET_ADMIN \
    --device /dev/dri --device /dev/uinput --device /dev/uhid \
    --device-cgroup-rule='c 13:* rmw' \
    --device-cgroup-rule="c ${HIDRAW_MAJOR}:* rmw" \
    --tmpfs /dev/input:rw,dev,nosuid,size=1m \
    -v /sys:/sys:ro \
    -v "${NAME}-home:/home/gamer/" \
    -v /var/mnt/DATA/:/mnt/DATA/:z \
    -e "CONTAINER_ID=${NAME}" \
    -e SCREEN_WIDTH="${SCREEN_WIDTH:-1920}" \
    -e SCREEN_HEIGHT="${SCREEN_HEIGHT:-1080}" \
    "${PORT_ARGS[@]}" \
    --security-opt label=disable \
    gamehub-container:latest

echo "${NAME} started. Logs: sudo podman exec -u gamer ${NAME} bash -c 'XDG_RUNTIME_DIR=/run/user/1000 journalctl --user -f'"
sudo podman exec -u gamer ${NAME} bash -c 'XDG_RUNTIME_DIR=/run/user/1000 journalctl --user -f
