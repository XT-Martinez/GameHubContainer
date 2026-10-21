#!/bin/bash
# Launch GameHubContainer instance
# Usage: ./run.sh [instance-number] [sunshine-port]
#   instance 1 uses the default base port 47989 (ports 47984-48010)
#   instance 2+ needs explicit sunshine port (e.g., 57989)
#
# Modes:
#   default                   rootless podman (no sudo). Per-container input
#                             isolation via the keep-id userns and a hidden
#                             read-only host /dev bind. Always uses published
#                             ports (never --network=host).
#   ENABLE_RYZENADJ=1 or      rootful legacy mode (sudo podman). Required for
#   ROOTFUL=1                 RyzenAdj (/dev/mem). Host networking when no port
#                             is given; daemon falls back to mknod.

set -euo pipefail

INSTANCE="${1:-1}"
PORT="${2:-}"
NAME="sunshine-${INSTANCE}"
SUNSHINE_MAC_ADDRESS="${SUNSHINE_MAC_ADDRESS:-$(printf '%s' "${NAME}" | md5sum | sed 's/^\(..\)\(..\)\(..\)\(..\)\(..\).*$/02:\1:\2:\3:\4:\5/')}"
HOST_DATA_PATH="${HOST_DATA_PATH:-/var/mnt/DATA}"
IMAGE="${IMAGE:-gamehub-container:latest}"
GS_ENABLE_CTRL_12="${GS_ENABLE_CTRL_12:-0}"
ENABLE_RYZENADJ="${ENABLE_RYZENADJ:-0}"
ROOTFUL="${ROOTFUL:-0}"
# Sunshine web UI CSRF origins: the host's LAN addresses and hostname, so the UI
# works from other machines. Override with SUNSHINE_CSRF_ORIGINS (comma-separated https:// origins).
if [[ -z "${SUNSHINE_CSRF_ORIGINS:-}" ]]; then
    SUNSHINE_CSRF_ORIGINS="$({
        ip -4 -o addr show scope global 2>/dev/null | awk '{sub(/\/.*/, "", $4); print "https://" $4}'
        hostname 2>/dev/null | sed '/./s|^|https://|'
    } | paste -sd, -)"
fi
RYZENADJ_PCI_CONFIG="${RYZENADJ_PCI_CONFIG:-/sys/bus/pci/devices/0000:00:00.0/config}"

if [[ "${ENABLE_RYZENADJ}" == "1" || "${ROOTFUL}" == "1" ]]; then
    ROOTFUL_MODE=1
    PODMAN=(sudo podman)
    MODE_LABEL="rootful legacy (sudo podman)"
else
    ROOTFUL_MODE=0
    PODMAN=(podman)
    MODE_LABEL="rootless (podman, keep-id userns)"
fi

# Rootful only: the hidraw major is needed for the cgroup device rule.
# Rootless has no device cgroup filtering, so it is not looked up there.
HIDRAW_MAJOR=""
if [[ "${ROOTFUL_MODE}" == "1" ]]; then
    HIDRAW_MAJOR=$(awk '$2 == "hidraw" { print $1; exit }' /proc/devices 2>/dev/null || true)
    if [[ -z "${HIDRAW_MAJOR}" ]]; then
        echo "WARNING: no hidraw major in /proc/devices; skipping hidraw cgroup rule" >&2
    fi
fi

if [[ ! -d "${HOST_DATA_PATH}" ]]; then
    echo "ERROR: HOST_DATA_PATH does not exist: ${HOST_DATA_PATH}" >&2
    exit 1
fi

echo "Container Name: $NAME"
echo "Mode: ${MODE_LABEL}"
echo "Image: ${IMAGE}"
echo "Resolution: ${SCREEN_WIDTH:-1920}x${SCREEN_HEIGHT:-1080}"
echo "Sunshine MAC: ${SUNSHINE_MAC_ADDRESS}"
echo "Host data: ${HOST_DATA_PATH} -> /mnt/DATA"
echo "Steam Ctrl+1/2 shortcuts: ${GS_ENABLE_CTRL_12}"
echo "Web UI origins: ${SUNSHINE_CSRF_ORIGINS:-none}"
echo "RyzenAdj TDP access: ${ENABLE_RYZENADJ}"

# Rootless and rootful podman keep separate image stores.
if ! "${PODMAN[@]}" image exists "${IMAGE}"; then
    echo "ERROR: image ${IMAGE} not found in the ${PODMAN[*]} store; build it with: ${PODMAN[*]} build -t ${IMAGE} ." >&2
    exit 1
fi

# Rootless preflight: the shim/daemon need to open these host nodes read-write
# as the current user. Warn only; the container still starts.
if [[ "${ROOTFUL_MODE}" == "0" ]]; then
    for dev in /dev/uinput /dev/uhid; do
        if [[ ! -r "${dev}" || ! -w "${dev}" ]]; then
            echo "WARNING: ${dev} is not read-writable by $(id -un); input devices may not work." >&2
            echo "  Install the host udev rules: scripts/install-host-udev-rules.sh" >&2
        fi
    done
fi

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

# Mode-specific runtime args
if [[ "${ROOTFUL_MODE}" == "1" ]]; then
    MODE_ARGS=(
        --cap-add SYS_ADMIN --cap-add MKNOD --cap-add NET_ADMIN
        # rtkit (realtime audio scheduling) needs these; only effective rootful
        --cap-add SYS_NICE --cap-add DAC_READ_SEARCH --cap-add SYS_PTRACE
        --device /dev/dri --device /dev/uinput --device /dev/uhid --device /dev/fuse
        --device-cgroup-rule='c 13:* rmw'
        --tmpfs /dev/input:rw,dev,nosuid,size=1m
    )
    if [[ -n "${HIDRAW_MAJOR}" ]]; then
        MODE_ARGS+=(--device-cgroup-rule="c ${HIDRAW_MAJOR}:* rmw")
    fi
else
    MODE_ARGS=(
        # Map host user (uid/gid 1000) to in-container gamer (1000:1000).
        --userns=keep-id:uid=1000,gid=1000
        # keep-id also defaults the process user to 1000; systemd must be PID 1 as root.
        --user 0:0
        --cap-add SYS_ADMIN --cap-add NET_ADMIN
        --device /dev/dri --device /dev/uinput --device /dev/uhid --device /dev/fuse
        --tmpfs /dev/input:rw,nosuid,size=1m
        # Hidden host /dev under /run/gamehub-host (parent is 0700, so gamer cannot traverse it).
        # Recursive bind on purpose: rootless crun rejects bind-nonrecursive here (EINVAL,
        # /dev has userns-locked submounts), so /dev submounts also appear under the hidden dir.
        # The daemon bind-mounts host event/hidraw nodes from here
        # into its private /dev/input, so no mknod (and no device cgroup rules) is needed.
        --mount "type=bind,src=/dev,dst=/run/gamehub-host/dev,ro=true"
        -e HOST_DEV_DIR=/run/gamehub-host/dev
    )
fi

# Build port args
# Rootless always publishes ports (private netns), defaulting to base port 47989.
if [[ "${ROOTFUL_MODE}" == "0" && -z "$PORT" ]]; then
    PORT=47989
fi

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
    # Rootful only: default ports use host networking
    PORT_ARGS=(--network=host)
fi

echo "Starting ${NAME} (${MODE_LABEL})"
[[ -n "$PORT" ]] && echo "  Sunshine port: ${PORT}" || echo "  Sunshine port: default (host network)"

"${PODMAN[@]}" run -d --rm \
    --name "${NAME}" \
    --hostname "${NAME}" \
    --replace \
    --systemd=true \
    --shm-size=1g \
    "${MODE_ARGS[@]}" \
    -v /sys:/sys:ro \
    "${RYZENADJ_ARGS[@]}" \
    -v "${NAME}-home:/home/gamer/" \
    -v "${HOST_DATA_PATH}:/mnt/DATA:rw,rslave" \
    -e "CONTAINER_ID=${NAME}" \
    -e "SUNSHINE_MAC_ADDRESS=${SUNSHINE_MAC_ADDRESS}" \
    -e "GS_ENABLE_CTRL_12=${GS_ENABLE_CTRL_12}" \
    -e "SUNSHINE_CSRF_ORIGINS=${SUNSHINE_CSRF_ORIGINS}" \
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
echo "Logs: ${PODMAN[*]} exec -u gamer ${NAME} bash -c 'XDG_RUNTIME_DIR=/run/user/1000 journalctl --user -f'"
"${PODMAN[@]}" exec -u gamer "${NAME}" bash -c 'XDG_RUNTIME_DIR=/run/user/1000 journalctl --user -f'
