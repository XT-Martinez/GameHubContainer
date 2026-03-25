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
#include <sys/inotify.h>
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

    if (mknod(nodepath, S_IFCHR | 0660, makedev(maj, min)) == 0) {
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

/* ── Main loop ────────────────────────────────────────────── */

int main(void) {
    const char *dbg = getenv("UINPUT_SHIM_DEBUG");
    debug_enabled = (dbg && dbg[0] == '1');

    DBG("starting — watching %s for %s* devices", SYSFS_INPUT, TAG_PREFIX);

    /* Handle any devices that already exist */
    scan_existing_devices();

    /* Set up inotify */
    int ifd = inotify_init1(IN_CLOEXEC);
    if (ifd < 0) {
        ERR("inotify_init1: %s", strerror(errno));
        return 1;
    }

    int wd = inotify_add_watch(ifd, SYSFS_INPUT, IN_CREATE | IN_DELETE);
    if (wd < 0) {
        ERR("inotify_add_watch(%s): %s", SYSFS_INPUT, strerror(errno));
        return 1;
    }

    DBG("watching for events...");

    /* Event buffer — aligned for inotify_event */
    char buf[4096]
        __attribute__((aligned(__alignof__(struct inotify_event))));

    for (;;) {
        ssize_t len = read(ifd, buf, sizeof(buf));
        if (len < 0) {
            if (errno == EINTR)
                continue;
            ERR("read: %s", strerror(errno));
            break;
        }
        if (len == 0)
            break;

        for (char *ptr = buf; ptr < buf + len; ) {
            struct inotify_event *ev = (struct inotify_event *)ptr;

            if (ev->len > 0 && is_input_device(ev->name)) {
                if (ev->mask & IN_CREATE) {
                    DBG("new device: %s", ev->name);
                    if (is_container_device(ev->name))
                        create_dev_node(ev->name);
                } else if (ev->mask & IN_DELETE) {
                    /* Unconditionally remove — our /dev/input is
                     * a private tmpfs, so anything in it is ours */
                    remove_dev_node(ev->name);
                }
            }

            ptr += sizeof(struct inotify_event) + ev->len;
        }
    }

    close(ifd);
    return 0;
}
