/*
 * input_mknod_daemon.c — sidecar daemon for container input device node creation
 *
 * Watches /sys/class/input/ via inotify for new input devices.  When a device
 * appears whose phys field starts with "container-", creates the corresponding
 * /dev/input/eventN or /dev/input/jsN device node.
 *
 * This pairs with the LD_PRELOAD shim (libuinput_shim.so) which tags devices
 * with the container identifier.  Together they provide:
 *   - Shim: tags phys on uinput and UHID devices (synchronous, at creation)
 *   - Daemon: creates /dev/input/ nodes (asynchronous, via inotify)
 *
 * This split handles UHID devices (PS5 DualSense) where the kernel HID driver
 * creates child input devices asynchronously after the UHID descriptor is
 * processed — the shim can't mknod those because they don't exist yet at
 * write() time.
 *
 * Environment variables:
 *   UINPUT_SHIM_DEBUG   - set to "1" for verbose logging to stderr
 *
 * Build:  gcc -O2 -o input-mknod-daemon input_mknod_daemon.c
 * Usage:  input-mknod-daemon  (runs in foreground, suitable for systemd)
 */

#include <dirent.h>
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <unistd.h>

/* ── Configuration ─────────────────────────────────────────── */

#define SYSFS_INPUT "/sys/class/input"
#define DEV_INPUT   "/dev/input"
#define TAG_PREFIX  "container-"

/* How long to wait for sysfs to populate after inotify fires */
#define PHYS_RETRY_COUNT   20
#define PHYS_RETRY_USEC    50000   /* 50ms per retry → 1s max */

/* ── Logging ───────────────────────────────────────────────── */

static int debug_enabled;

#define DBG(fmt, ...) do {                                              \
    if (debug_enabled)                                                  \
        fprintf(stderr, "[input-mknod] " fmt "\n", ##__VA_ARGS__);     \
} while (0)

#define ERR(fmt, ...) \
    fprintf(stderr, "[input-mknod] ERROR: " fmt "\n", ##__VA_ARGS__)

/* ── Helpers ───────────────────────────────────────────────── */

static int is_input_device(const char *name) {
    return (strncmp(name, "event", 5) == 0 ||
            strncmp(name, "js", 2) == 0);
}

/*
 * Read the phys field of a device's parent input device.
 * For event45: reads /sys/class/input/event45/device/phys
 *
 * Retries with backoff because sysfs attributes may not be
 * populated immediately after the inotify event fires (especially
 * for UHID devices where the HID driver creates children async).
 */
static int read_device_phys(const char *devname, char *phys, size_t phys_size) {
    char phys_path[PATH_MAX];
    snprintf(phys_path, sizeof(phys_path),
             SYSFS_INPUT "/%s/device/phys", devname);

    for (int attempt = 0; attempt < PHYS_RETRY_COUNT; attempt++) {
        FILE *f = fopen(phys_path, "r");
        if (f) {
            if (fgets(phys, phys_size, f)) {
                /* Strip trailing newline */
                char *nl = strchr(phys, '\n');
                if (nl) *nl = '\0';
                fclose(f);
                return 1;
            }
            fclose(f);
        }
        usleep(PHYS_RETRY_USEC);
    }
    return 0;
}

static int is_container_device(const char *devname) {
    char phys[256] = {0};
    if (!read_device_phys(devname, phys, sizeof(phys)))
        return 0;
    return strncmp(phys, TAG_PREFIX, strlen(TAG_PREFIX)) == 0;
}

static void create_dev_node(const char *devname) {
    char dev_path[PATH_MAX];
    snprintf(dev_path, sizeof(dev_path),
             SYSFS_INPUT "/%s/dev", devname);

    /* Read major:minor from sysfs */
    FILE *f = fopen(dev_path, "r");
    if (!f) {
        DBG("cannot read %s: %s", dev_path, strerror(errno));
        return;
    }

    unsigned int maj, min;
    int ok = (fscanf(f, "%u:%u", &maj, &min) == 2);
    fclose(f);
    if (!ok)
        return;

    /* Ensure /dev/input/ exists */
    mkdir(DEV_INPUT, 0755);

    char nodepath[PATH_MAX];
    snprintf(nodepath, sizeof(nodepath), DEV_INPUT "/%s", devname);

    /* Remove stale node if present */
    unlink(nodepath);

    if (mknod(nodepath, S_IFCHR | 0666, makedev(maj, min)) == 0) {
        DBG("created %s (%u:%u)", nodepath, maj, min);
    } else {
        DBG("mknod %s failed: %s", nodepath, strerror(errno));
    }
}

static void remove_dev_node(const char *devname) {
    char nodepath[PATH_MAX];
    snprintf(nodepath, sizeof(nodepath), DEV_INPUT "/%s", devname);

    if (unlink(nodepath) == 0) {
        DBG("removed %s", nodepath);
    }
    /* ENOENT is fine — we didn't create it */
}

/* ── Initial scan ─────────────────────────────────────────── */

/*
 * On startup, scan all existing devices in case the daemon started
 * after some devices were already created.
 */
static void scan_existing_devices(void) {
    DIR *d = opendir(SYSFS_INPUT);
    if (!d) {
        ERR("cannot open %s: %s", SYSFS_INPUT, strerror(errno));
        return;
    }

    struct dirent *ent;
    while ((ent = readdir(d))) {
        if (is_input_device(ent->d_name) && is_container_device(ent->d_name)) {
            create_dev_node(ent->d_name);
        }
    }
    closedir(d);
}

/* ── Polling scan ─────────────────────────────────────────── */

/*
 * Scan /sys/class/input/ and create/remove device nodes as needed.
 * Returns the number of container devices currently present.
 *
 * We also clean up stale nodes in /dev/input/ that no longer have
 * a corresponding sysfs entry.
 */
static int poll_and_sync(void) {
    int count = 0;

    /* Pass 1: create nodes for new container devices */
    DIR *d = opendir(SYSFS_INPUT);
    if (!d) {
        ERR("cannot open %s: %s", SYSFS_INPUT, strerror(errno));
        return 0;
    }

    struct dirent *ent;
    while ((ent = readdir(d))) {
        if (!is_input_device(ent->d_name))
            continue;
        if (!is_container_device(ent->d_name))
            continue;

        count++;

        /* Check if node already exists */
        char nodepath[PATH_MAX];
        snprintf(nodepath, sizeof(nodepath), DEV_INPUT "/%s", ent->d_name);
        struct stat st;
        if (stat(nodepath, &st) == 0)
            continue;   /* already created */

        DBG("new container device: %s", ent->d_name);
        create_dev_node(ent->d_name);
    }
    closedir(d);

    /* Pass 2: remove stale nodes whose sysfs entry is gone */
    d = opendir(DEV_INPUT);
    if (d) {
        while ((ent = readdir(d))) {
            if (!is_input_device(ent->d_name))
                continue;

            char syspath[PATH_MAX];
            snprintf(syspath, sizeof(syspath),
                     SYSFS_INPUT "/%s", ent->d_name);
            struct stat st;
            if (stat(syspath, &st) != 0) {
                DBG("stale device gone: %s", ent->d_name);
                remove_dev_node(ent->d_name);
            }
        }
        closedir(d);
    }

    return count;
}

/* ── Main loop ────────────────────────────────────────────── */

/* Poll interval in microseconds (500ms) */
#define POLL_INTERVAL_USEC  500000

int main(void) {
    /* Clear umask so mknod(0666) creates world-readable nodes */
    umask(0);

    const char *dbg = getenv("UINPUT_SHIM_DEBUG");
    debug_enabled = (dbg && dbg[0] == '1');

    fprintf(stderr, "[input-mknod] starting — polling %s for %s* devices\n",
            SYSFS_INPUT, TAG_PREFIX);

    /* Initial scan */
    int n = poll_and_sync();
    fprintf(stderr, "[input-mknod] initial scan: %d container device(s)\n", n);

    /* Poll loop */
    for (;;) {
        usleep(POLL_INTERVAL_USEC);
        poll_and_sync();
    }

    return 0;
}
