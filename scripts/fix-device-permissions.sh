#!/bin/sh
# Fix device permissions for container use.
#
# In rootless podman, device nodes are owned by nobody:nobody (unmapped host
# uid 0). Three approaches are tried in order:
#   1. chmod 0666 — works in rootful podman
#   2. setfacl — adds ACL entry for gamer (uid 1000), works in rootless
#   3. mknod — recreate node owned by container root, last resort

GAMER_UID=1000

for dev_info in "uinput 10 223" "uhid 10 239"; do
    set -- $dev_info
    name=$1 major=$2 minor=$3
    dev="/dev/$name"

    [ -e "$dev" ] || continue

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
    saved_dev="$dev"
    rm -f "$dev"
    if mknod "$dev" c "$major" "$minor" 2>/dev/null; then
        chmod 0666 "$dev" 2>/dev/null
        echo "Fixed $dev via mknod -> 0666"
        continue
    fi

    # All methods failed — try to restore with mknod even if chmod won't help
    mknod "$dev" c "$major" "$minor" 2>/dev/null || true
    echo "ERROR: Could not fix permissions for $dev — input devices will not work" >&2
    echo "  Workaround: run 'sudo chmod 666 /dev/uinput' on the HOST before starting the container" >&2
done
