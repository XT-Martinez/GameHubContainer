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
SUNSHINE_MAC_ADDRESS="${SUNSHINE_MAC_ADDRESS:-$(printf '%s' "${NAME}" | md5sum | sed 's/^\(..\)\(..\)\(..\)\(..\)\(..\).*$/02:\1:\2:\3:\4:\5/')}"
HOST_DATA_PATH="${HOST_DATA_PATH:-/var/mnt/DATA}"
IMAGE="${IMAGE:-gamehub-container:latest}"
GS_ENABLE_CTRL_12="${GS_ENABLE_CTRL_12:-0}"
ENABLE_RYZENADJ="${ENABLE_RYZENADJ:-0}"
RYZENADJ_PCI_CONFIG="${RYZENADJ_PCI_CONFIG:-/sys/bus/pci/devices/0000:00:00.0/config}"

if [[ ! -d "${HOST_DATA_PATH}" ]]; then
    echo "ERROR: HOST_DATA_PATH does not exist: ${HOST_DATA_PATH}" >&2
    exit 1
fi

echo "Container Name: $NAME"
echo "Image: ${IMAGE}"
echo "Resolution: ${SCREEN_WIDTH:-1920}x${SCREEN_HEIGHT:-1080}"
echo "Sunshine MAC: ${SUNSHINE_MAC_ADDRESS}"
echo "Host data: ${HOST_DATA_PATH} -> /mnt/DATA"
echo "Steam Ctrl+1/2 shortcuts: ${GS_ENABLE_CTRL_12}"
echo "RyzenAdj TDP access: ${ENABLE_RYZENADJ}"

RYZENADJ_ARGS=()
if [[ "${ENABLE_RYZENADJ}" == "1" ]]; then
    if [[ ! -e /dev/mem || ! -e "${RYZENADJ_PCI_CONFIG}" ]]; then
        echo "ERROR: RyzenAdj access requested, but a required host device is missing" >&2
        echo "  /dev/mem: $(test -e /dev/mem && echo present || echo missing)" >&2
        echo "  PCI config: ${RYZENADJ_PCI_CONFIG}" >&2
        exit 1
    fi

    # RyzenAdj falls back to /dev/mem and the AMD host bridge PCI config.
    # Keep all other sysfs paths read-only for the container.
    RYZENADJ_ARGS=(
        --cap-add SYS_RAWIO
        --device /dev/mem
        --mount "type=bind,src=${RYZENADJ_PCI_CONFIG},dst=${RYZENADJ_PCI_CONFIG},rw=true"
    )
fi

# Build port args
PORT_ARGS=()
if [[ -n "$PORT" ]]; then
    # Sunshine port offsets from the base port (config.port):
    #   +0  PORT_HTTP          Moonlight discovery (mDNS-advertised)
    #   -5  PORT_HTTPS         Moonlight HTTPS / pairing
    #   +1  confighttp HTTPS   Sunshine web UI
    #   +21 RTSP_SETUP_PORT    RTSP session setup
    #   +9  VIDEO_STREAM_PORT  Video stream (UDP)
    #   +10 CONTROL_PORT       Control channel (UDP)
    #   +11 AUDIO_STREAM_PORT  Audio stream (UDP)
    P_HTTP=$((PORT))
    P_HTTPS=$((PORT - 5))
    P_WEB=$((PORT + 1))
    P_RTSP=$((PORT + 21))
    P_VIDEO=$((PORT + 9))
    P_CONTROL=$((PORT + 10))
    P_AUDIO=$((PORT + 11))
    PORT_ARGS=(
        -e "SUNSHINE_PORT=${PORT}"
        -p "${P_HTTP}:${P_HTTP}/tcp"
        -p "${P_HTTPS}:${P_HTTPS}/tcp"
        -p "${P_WEB}:${P_WEB}/tcp"
        -p "${P_RTSP}:${P_RTSP}/tcp"
        -p "${P_VIDEO}:${P_VIDEO}/udp"
        -p "${P_CONTROL}:${P_CONTROL}/udp"
        -p "${P_AUDIO}:${P_AUDIO}/udp"
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
    "${RYZENADJ_ARGS[@]}" \
    -v "${NAME}-home:/home/gamer/" \
    -v "${HOST_DATA_PATH}:/mnt/DATA:rw,rslave" \
    -e "CONTAINER_ID=${NAME}" \
    -e "SUNSHINE_MAC_ADDRESS=${SUNSHINE_MAC_ADDRESS}" \
    -e "GS_ENABLE_CTRL_12=${GS_ENABLE_CTRL_12}" \
    -e SCREEN_WIDTH="${SCREEN_WIDTH:-1920}" \
    -e SCREEN_HEIGHT="${SCREEN_HEIGHT:-1080}" \
    "${PORT_ARGS[@]}" \
    --security-opt label=disable \
    "${IMAGE}"

# Advertise via mDNS so Moonlight discovers this instance like native Sunshine.
# Sunshine registers _nvstream._tcp with the HTTP port and no TXT records.
MDNS_PORT="${PORT:-47989}"
MDNS_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/gamehub-mdns-publisher.sh"
start_mdns_publisher() {
    if ! command -v avahi-publish-service >/dev/null 2>&1; then
        echo "WARNING: avahi-publish-service not found; Moonlight auto-discovery will not be advertised"
        return
    fi

    if [[ ! -x "${MDNS_SCRIPT}" ]]; then
        echo "WARNING: mDNS helper is not executable: ${MDNS_SCRIPT}"
        return
    fi

    pkill -f "${MDNS_SCRIPT} ${NAME} ${MDNS_PORT}" >/dev/null 2>&1 || true
    nohup "${MDNS_SCRIPT}" "${NAME}" "${MDNS_PORT}" \
        >"/tmp/gamehub-mdns-${NAME}.log" 2>&1 &
    echo "mDNS publisher started: ${NAME}/_nvstream._tcp:${MDNS_PORT}"
    echo "mDNS logs: /tmp/gamehub-mdns-${NAME}.log"
}

start_mdns_publisher

echo "${NAME} started (mDNS: ${NAME}/_nvstream._tcp:${MDNS_PORT})"
echo "Logs: sudo podman exec -u gamer ${NAME} bash -c 'XDG_RUNTIME_DIR=/run/user/1000 journalctl --user -f'"
sudo podman exec -u gamer ${NAME} bash -c 'XDG_RUNTIME_DIR=/run/user/1000 journalctl --user -f'
