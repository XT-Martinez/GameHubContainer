#!/bin/sh
# Fix device permissions for container use.
#
# Runs inside the container as root (device-permissions.service).
#
# Rootless: /dev/uinput and /dev/uhid are bind-mounted from the host (see the
# host-dev bind in run.sh). They are host nodes, so chmod/setfacl fail and
# recreating them with mknod would replace a working node. Therefore:
#   0. If gamer (GAMER_UID) can already read and write the node, print OK and skip.
#   1. chmod 0666 (rootful: container root owns the node)
#   2. setfacl -m u:gamer:rw (ACL support)
#   3. mknod recreation, last resort. Only when CAP_MKNOD works, and the
#      original node is replaced atomically with mv, never removed first.

GAMER_UID=1000
GAMER_GID=1000

# can_gamer_rw DEV: succeed if GAMER_UID can read and write DEV.
can_gamer_rw() {
    _dev=$1
    if command -v setpriv >/dev/null 2>&1; then
        setpriv --reuid="${GAMER_UID}" --regid="${GAMER_GID}" --init-groups \
            sh -c 'test -r "$1" && test -w "$1"' sh "$_dev" 2>/dev/null
        return $?
    fi
    if command -v runuser >/dev/null 2>&1; then
        runuser -u gamer -- sh -c 'test -r "$1" && test -w "$1"' sh "$_dev" 2>/dev/null
        return $?
    fi
    # Neither helper: decide from mode/owner bits (owner rw, or other rw).
    _info=$(stat -c '%u %A' "$_dev" 2>/dev/null) || return 1
    _uid=${_info%% *}
    _mode=${_info#* }
    if [ "$_uid" = "${GAMER_UID}" ] && [ "$(printf '%s' "$_mode" | cut -c2-3)" = "rw" ]; then
        return 0
    fi
    [ "$(printf '%s' "$_mode" | cut -c8-9)" = "rw" ]
}

# can_mknod MAJOR MINOR: succeed only if CAP_MKNOD works for this device number
# (probe a temp node with the real major/minor, then remove it).
can_mknod() {
    _tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/fixdev.XXXXXX" 2>/dev/null) || return 1
    _probe="${_tmpdir}/probe"
    if mknod "$_probe" c "$1" "$2" 2>/dev/null; then
        rm -f "$_probe"
        rmdir "$_tmpdir" 2>/dev/null
        return 0
    fi
    rmdir "$_tmpdir" 2>/dev/null
    return 1
}

# recreate_node DEV MAJOR MINOR: build the node under a temp name, then rename over DEV.
recreate_node() {
    _dev=$1 _major=$2 _minor=$3
    _new="${_dev}.gamehub-new.$$"
    rm -f "$_new"
    mknod "$_new" c "$_major" "$_minor" 2>/dev/null || return 1
    chmod 0666 "$_new" 2>/dev/null
    if mv -f "$_new" "$_dev" 2>/dev/null; then
        return 0
    fi
    # Original is still in place (e.g. a bind mount cannot be replaced); drop only our temp node.
    rm -f "$_new"
    return 1
}

for dev_info in "uinput 10 223" "uhid 10 239"; do
    set -- $dev_info
    name=$1 major=$2 minor=$3
    dev="/dev/$name"

    [ -e "$dev" ] || continue

    # Method 0: already usable by gamer (rootless bind-mounted host node)
    if can_gamer_rw "$dev"; then
        echo "OK: $dev is already read/write for uid ${GAMER_UID}, skipping"
        continue
    fi

    # Method 1: chmod (works when container root owns the device)
    if chmod 0666 "$dev" 2>/dev/null; then
        verify=$(stat -c '%a' "$dev" 2>/dev/null)
        if [ "$verify" = "666" ]; then
            echo "Fixed $dev via chmod -> 0666"
            continue
        fi
    fi

    # Method 2: setfacl (works in rootless podman with ACL support)
    if command -v setfacl >/dev/null 2>&1; then
        if setfacl -m "u:${GAMER_UID}:rw" "$dev" 2>/dev/null; then
            echo "Fixed $dev via ACL -> u:${GAMER_UID}:rw"
            continue
        fi
    fi

    # Method 3: recreate device node (requires CAP_MKNOD + cgroup device access)
    if can_mknod "$major" "$minor" && recreate_node "$dev" "$major" "$minor"; then
        echo "Fixed $dev via mknod -> 0666"
        continue
    fi

    echo "ERROR: Could not fix permissions for $dev — input devices will not work" >&2
    echo "  Workaround: run 'sudo chmod 666 /dev/uinput' on the HOST before starting the container" >&2
done
