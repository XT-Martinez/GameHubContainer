#!/bin/bash
# Rebuild Sunshine and/or gamescope incrementally and swap them into a running
# container, instead of building a new image for each change.
#
#   ./dev-hotswap.sh [-c CONTAINER] sunshine|gamescope...
#
#   sunshine   rebuild Sunshine, swap /usr/bin/sunshine, restart sunshine.service
#   gamescope  rebuild gamescope, swap /usr/bin/gamescope and the WSI layer, and
#              restart the gamescope session (this also restarts Steam and any
#              running game; Sunshine restarts with it)
#
# CONTAINER defaults to the only running sunshine-* container.
#
# The first run tags the Dockerfile's builder stages as gamehub-dev:<stage>
# (from the build cache when the sources match the last image build) and creates
# build volumes seeded with their compiled trees, so later runs only recompile
# what changed. Set REFRESH=1 to retag the builder stages, e.g. after changing
# patches/ffmpeg/ (then also remove the build volumes, see below).
#
# Swapped binaries last until the container is recreated: build an image to
# keep a change. To start over: podman volume rm gamehub-dev-sunshine gamehub-dev-gamescope
set -euo pipefail
cd "$(dirname "$0")"

PODMAN=(${PODMAN:-podman})
CONTAINER=""
OUT="${TMPDIR:-/tmp}/gamehub-dev-out"

usage() {
    sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while getopts "c:h" opt; do
    case "$opt" in
        c) CONTAINER="$OPTARG" ;;
        h) usage ;;
        *) usage 1 ;;
    esac
done
shift $((OPTIND - 1))
[[ $# -gt 0 ]] || usage 1

if [[ -z "$CONTAINER" ]]; then
    mapfile -t running < <("${PODMAN[@]}" ps --format '{{.Names}}' | grep '^sunshine-' || true)
    if [[ ${#running[@]} -ne 1 ]]; then
        echo "ERROR: found ${#running[@]} running sunshine-* containers; pick one with -c" >&2
        exit 1
    fi
    CONTAINER="${running[0]}"
fi
echo "Container: ${CONTAINER}"

mkdir -p "$OUT"

# Tag a builder stage of the Dockerfile as gamehub-dev:<stage>
builder_image() {
    local image="gamehub-dev:$1"
    if [[ -n "${REFRESH:-}" ]] || ! "${PODMAN[@]}" image exists "$image"; then
        echo "Tagging builder stage $1 (a full build if the sources changed since the last image build)" >&2
        "${PODMAN[@]}" build --target "$1" -t "$image" . >&2
    fi
    echo "$image"
}

# Run a build in a builder image: the volume at $2 keeps the build tree (seeded
# from the image on first use), the host source is copied over it so that only
# files changed since the last run get newer timestamps and recompile.
run_build() {
    local image=$1 tree=$2 volume=$3 src=$4 script=$5
    "${PODMAN[@]}" run --rm \
        --security-opt label=disable \
        -v "${volume}:${tree}" \
        -v "${PWD}/${src}:/src:ro" \
        -v "${OUT}:/out" \
        -w "$tree" \
        "$image" bash -c "set -e; cp -a -u /src/. ${tree}/; ${script}"
}

# Copy a file into the container next to its target, then rename it into
# place: a running executable or loaded library can't be overwritten.
swap_in() {
    local file=$1 dest=$2
    "${PODMAN[@]}" cp "$file" "${CONTAINER}:${dest}.new"
    "${PODMAN[@]}" exec "$CONTAINER" bash -c "chown root:root '${dest}.new' && chmod 755 '${dest}.new' && mv -f '${dest}.new' '${dest}'"
    echo "Swapped ${dest}"
}

restart_units() {
    "${PODMAN[@]}" exec "$CONTAINER" systemctl --user -M gamer@ restart "$@"
    echo "Restarted $*"
}

for component in "$@"; do
    case "$component" in
        sunshine)
            image=$(builder_image sunshine-builder)
            # Same NVENC compatibility edits as the Dockerfile (cp -u leaves an
            # edited file alone until the source changes again)
            run_build "$image" /build/sunshine gamehub-dev-sunshine Sunshine '
                sed -i "s/#error Check and update.*/#warning NVENC version mismatch - runtime detection will handle it/" src/nvenc/nvenc_base.cpp
                sed -i "s/format_config\.pixelBitDepthMinus8 = 2;/\/\/ pixelBitDepthMinus8 removed in newer SDK/" src/nvenc/nvenc_base.cpp
                sed -i "s/format_config\.inputPixelBitDepthMinus8 = 2;/\/\/ inputPixelBitDepthMinus8 removed in newer SDK/" src/nvenc/nvenc_base.cpp
                make -j"$(nproc)" -C build sunshine
                install -m 755 "$(readlink -f build/sunshine)" /out/sunshine'
            swap_in "$OUT/sunshine" /usr/bin/sunshine
            restart_units sunshine.service
            ;;
        gamescope)
            image=$(builder_image gamescope-builder)
            run_build "$image" /build/gamescope gamehub-dev-gamescope gamescope '
                ninja -C builddir
                install -m 755 builddir/src/gamescope /out/gamescope
                install -m 755 builddir/layer/libVkLayer_FROG_gamescope_wsi_x86_64.so /out/'
            swap_in "$OUT/gamescope" /usr/bin/gamescope
            swap_in "$OUT/libVkLayer_FROG_gamescope_wsi_x86_64.so" /usr/lib64/libVkLayer_FROG_gamescope_wsi_x86_64.so
            # Sunshine is bound to the session, so restart both together
            restart_units gamescope-session-plus@steam.service sunshine.service
            ;;
        *)
            echo "ERROR: unknown component '${component}'" >&2
            usage 1
            ;;
    esac
done
