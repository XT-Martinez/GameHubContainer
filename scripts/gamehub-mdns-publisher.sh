#!/bin/bash
# Publish a Moonlight/Sunshine mDNS service from the host for a rootful Podman container.

set -euo pipefail

NAME="${1:?container name required}"
MDNS_PORT="${2:?mDNS port required}"

if ! command -v avahi-publish-service >/dev/null 2>&1; then
    echo "ERROR: avahi-publish-service not found" >&2
    exit 127
fi

cleanup() {
    if [[ -n "${AVAHI_PID:-}" ]]; then
        kill "${AVAHI_PID}" >/dev/null 2>&1 || true
        wait "${AVAHI_PID}" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT INT TERM

echo "Waiting for Sunshine to listen on port ${MDNS_PORT}..."
ready=0
for _ in $(seq 1 60); do
    if ss -tlnH "sport = :${MDNS_PORT}" 2>/dev/null | grep -q .; then
        ready=1
        break
    fi
    sleep 1
done

if [[ "${ready}" -eq 0 ]]; then
    echo "WARNING: Sunshine did not start within 60s, publishing mDNS anyway"
fi

echo "Publishing mDNS: ${NAME}/_nvstream._tcp:${MDNS_PORT}"
avahi-publish-service "${NAME}" _nvstream._tcp "${MDNS_PORT}" &
AVAHI_PID=$!

sudo -n podman wait "${NAME}" >/dev/null 2>&1 || true
