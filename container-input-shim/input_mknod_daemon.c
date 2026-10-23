/*
 * input_mknod_daemon.c — sidecar daemon for container input device node creation
 *                         and fake udev database/event injection
 *
 * Polls /sys/class/input/ for new input devices.  When a device appears whose
 * phys field starts with "container-", creates the corresponding /dev/input/
 * device node, writes a udev database entry so libudev consumers (SDL/Steam)
 * can discover it, and sends a synthetic udev netlink event for hotplug.
 *
 * Also handles /sys/class/hidraw/ for DualSense passthrough devices.
 *
 * This pairs with the LD_PRELOAD shim (libuinput_shim.so) which tags devices
 * with the container identifier.  Together they provide:
 *   - Shim: tags phys on uinput and UHID devices (synchronous, at creation)
 *   - Daemon: creates /dev/ nodes + udev DB + netlink events (asynchronous)
 *
 * Node creation has two modes:
 *
 *   Bind mode (rootless podman, HOST_DEV_DIR exists as a directory):
 *     mknod() is not permitted in a rootless container, and tmpfs /dev is
 *     nodev.  Instead, the host /dev is bind-mounted read-only at
 *     HOST_DEV_DIR, and each node is an empty placeholder file that is
 *     mount --bind'ed over the host node (e.g. /dev/input/event5 <-
 *     /run/gamehub-host/dev/input/event5).  The host node is looked up at
 *     HOST_DEV_DIR/gamehub-input/<kernel-name> first (host udev moves
 *     container-tagged nodes there), then at its original location
 *     (HOST_DEV_DIR/input/event5, or HOST_DEV_DIR/hidraw3 for hidraw) as a
 *     fallback.  Host udev sets the owner asynchronously, so creation is
 *     deferred until the chosen host node is owned by GAMER_UID (up to
 *     DEFER_MAX polls, then proceeds with a warning).  An input node of a
 *     HID device also waits (up to DEFER_MAX polls, in both modes) until the
 *     device's hidraw node is placed, so SDL sees hidraw first and uses
 *     HIDAPI for it (hid_sibling_pending).  Removal unmounts the
 *     placeholder before unlinking it.  A bind mount pins the inode, so a
 *     later host-side rename does not affect a node that is already bound.
 *
 *   Bind mode stages each node: the placeholder and bind live in
 *   STAGE_DIR, and the public name (/dev/input/event5, /dev/hidraw0) is a
 *   symlink to it.  Steam runs games in a pressure-vessel sandbox, a mount
 *   namespace copied when the game starts, and Proton's Wine finds devices
 *   there by inotify on /dev/input and /dev, reading the node's rdev as
 *   soon as the name appears.  STAGE_DIR is a shared mount, so a bind made
 *   after the game started reaches the sandbox, and the symlink appears only
 *   once its target is the device, so Wine never sees an empty placeholder.
 *   Without both, a controller reconnected mid-game is lost to the game.
 *
 *   Hidraw view (both modes): /sys is the host kernel's, so a hidraw device
 *   shows up in /sys/class/hidraw as soon as the kernel creates it, before
 *   its /dev node is placed.  Steam polls /sys/class/hidraw and opens new
 *   devices right away; an open that fails with ENOENT is not retried, and
 *   SDL then takes the controller through evdev (a plain "PS5 Controller"
 *   with Cross and Circle swapped in the Steam UI) instead of HIDAPI.  So a
 *   tmpfs is mounted over /sys/class/hidraw, and a device's link appears
 *   there only once its /dev node is in place (and goes before the node on
 *   removal).  Host hidraw devices never appear.  The daemon lists the real
 *   directory through a bind at HIDRAW_REAL_DIR; the kernel's links are
 *   relative, so device attributes are read through the resolved
 *   /sys/devices path (hidraw_base).
 *
 *   Mknod mode (rootful, or HOST_DEV_DIR absent): plain mknod(2) of the
 *     char device.  If a bind in bind mode fails, the daemon falls back to
 *     mknod for that node.
 *
 * Environment variables:
 *   UINPUT_SHIM_DEBUG   - set to "1" for verbose logging to stderr
 *   HOST_DEV_DIR        - host /dev bind point (default /run/gamehub-host/dev);
 *                         its presence as a directory selects bind mode.
 *                         In bind mode its parent directory is chmod'ed 0700
 *                         so non-root container processes cannot reach the
 *                         host /dev bind (skipped for /, /run, /dev, /run/user)
 *   GAMER_UID           - host uid that must own a host node before it is
 *                         bound in bind mode (default 1000)
 *
 * Build:  gcc -O2 -o input-mknod-daemon input_mknod_daemon.c
 * Usage:  input-mknod-daemon  (runs in foreground, suitable for systemd)
 */

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <linux/input.h>
#include <linux/hidraw.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <sys/types.h>
#include <linux/netlink.h>
#include <arpa/inet.h>
#include <time.h>
#include <unistd.h>

/* ── Configuration ─────────────────────────────────────────── */

#define SYSFS_INPUT    "/sys/class/input"
#define SYSFS_HIDRAW   "/sys/class/hidraw"
/* Hidraw view: the real /sys/class/hidraw stays readable here (see header) */
#define HIDRAW_REAL_DIR "/run/gamehub-sysfs-hidraw"
#define DEV_INPUT      "/dev/input"
#define DEV_BASE       "/dev"
#define UDEV_DATA_DIR  "/run/udev/data"
#define TAG_PREFIX     "container-"

/* UHID device name claims file (written by uinput shim) */
#define UHID_NAMES_FILE "/run/container-input/uhid-names"

/* Bind mode: host /dev bind point and default owner (see header comment) */
#define HOST_DEV_DEFAULT  "/run/gamehub-host/dev"
#define HOST_HIDDEN_DIR   "gamehub-input"   /* under HOST_DEV_DIR: host-moved nodes */
/* Bind mode: where nodes are bound before their public name links to them */
#define STAGE_DIR         DEV_INPUT "/.gamehub-nodes"
#define GAMER_UID_DEFAULT 1000

/* How long to wait for sysfs to populate */
#define PHYS_RETRY_COUNT   20
#define PHYS_RETRY_USEC    50000   /* 50ms per retry → 1s max */

/* Poll interval in microseconds (500ms) */
#define POLL_INTERVAL_USEC  500000

/* Bind mode readiness: polls to wait for host udev ownership before proceeding */
#define DEFER_MAX          6
#define DEFER_SLOTS        64
#define NODE_SLOTS         128

/* Netlink constants for synthetic udev events */
#define NETLINK_KOBJECT_UEVENT  15
#define UDEV_MONITOR_MAGIC      0xfeedcafe
#define MONITOR_GROUP_UDEV      2

/* ── Logging ───────────────────────────────────────────────── */

static int debug_enabled;

#define DBG(fmt, ...) do {                                              \
    if (debug_enabled)                                                  \
        fprintf(stderr, "[input-mknod] " fmt "\n", ##__VA_ARGS__);     \
} while (0)

#define INFO(fmt, ...) \
    fprintf(stderr, "[input-mknod] " fmt "\n", ##__VA_ARGS__)

#define ERR(fmt, ...) \
    fprintf(stderr, "[input-mknod] ERROR: " fmt "\n", ##__VA_ARGS__)

/* ── Node placement settings (set once in main) ───────────── */

static int bind_mode;                       /* 1 = bind placeholders, 0 = mknod */
static char host_dev_dir[PATH_MAX] = HOST_DEV_DEFAULT;
static unsigned int gamer_uid = GAMER_UID_DEFAULT;
static int stage_ready;                     /* STAGE_DIR is a shared mount */
/* Where hidraw devices are listed: HIDRAW_REAL_DIR once the view is set up */
static const char *hidraw_list = SYSFS_HIDRAW;
static int hidraw_view;                     /* the hidraw view is mounted */

/* ── Udev netlink header ──────────────────────────────────── */

struct udev_monitor_netlink_header {
    char prefix[8];                    /* "libudev\0" */
    unsigned int magic;                /* htobe32(0xfeedcafe) */
    unsigned int header_size;
    unsigned int properties_off;
    unsigned int properties_len;
    unsigned int filter_subsystem_hash;
    unsigned int filter_devtype_hash;
    unsigned int filter_tag_bloom_hi;
    unsigned int filter_tag_bloom_lo;
};

/*
 * MurmurHash2 — used by libudev for BPF subsystem/devtype filtering.
 * Copied from systemd/Wolf fake-udev (public domain algorithm).
 */
static unsigned int murmur_hash2(const char *key, size_t len, unsigned int seed) {
    const unsigned int m = 0x5bd1e995;
    const int r = 24;
    unsigned int h = seed ^ len;
    const unsigned char *data = (const unsigned char *)key;

    while (len >= 4) {
        unsigned int k;
        memcpy(&k, data, sizeof(k));
        k *= m;
        k ^= k >> r;
        k *= m;
        h *= m;
        h ^= k;
        data += 4;
        len -= 4;
    }

    switch (len) {
    case 3: h ^= data[2] << 16; /* fallthrough */
    case 2: h ^= data[1] << 8;  /* fallthrough */
    case 1: h ^= data[0]; h *= m;
    }

    h ^= h >> 13;
    h *= m;
    h ^= h >> 15;
    return h;
}

/* Hash a subsystem string for the udev monitor header filter */
static unsigned int subsystem_hash(const char *subsystem) {
    return murmur_hash2(subsystem, strlen(subsystem), 0);
}

/* ── Device type classification ───────────────────────────── */

enum device_class {
    DEV_CLASS_UNKNOWN = 0,
    DEV_CLASS_KEYBOARD,
    DEV_CLASS_MOUSE,
    DEV_CLASS_MOUSE_ABS,
    DEV_CLASS_JOYSTICK,
    DEV_CLASS_TOUCHSCREEN,
    DEV_CLASS_TOUCHPAD,
    DEV_CLASS_ACCELEROMETER,
    DEV_CLASS_HIDRAW,
};

/* Bit test helper for EVIOCGBIT results */
#define TEST_BIT(bit, array) ((array[(bit) / 8] >> ((bit) % 8)) & 1)

static enum device_class classify_evdev(const char *devpath) {
    int fd = open(devpath, O_RDONLY | O_NONBLOCK);
    if (fd < 0)
        return DEV_CLASS_UNKNOWN;

    unsigned char ev_bits[(EV_MAX + 7) / 8];
    unsigned char key_bits[(KEY_MAX + 7) / 8];
    unsigned char abs_bits[(ABS_MAX + 7) / 8];
    unsigned char rel_bits[(REL_MAX + 7) / 8];

    memset(ev_bits, 0, sizeof(ev_bits));
    memset(key_bits, 0, sizeof(key_bits));
    memset(abs_bits, 0, sizeof(abs_bits));
    memset(rel_bits, 0, sizeof(rel_bits));

    ioctl(fd, EVIOCGBIT(0, sizeof(ev_bits)), ev_bits);

    int has_key = TEST_BIT(EV_KEY, ev_bits);
    int has_abs = TEST_BIT(EV_ABS, ev_bits);
    int has_rel = TEST_BIT(EV_REL, ev_bits);

    if (has_key)
        ioctl(fd, EVIOCGBIT(EV_KEY, sizeof(key_bits)), key_bits);
    if (has_abs)
        ioctl(fd, EVIOCGBIT(EV_ABS, sizeof(abs_bits)), abs_bits);
    if (has_rel)
        ioctl(fd, EVIOCGBIT(EV_REL, sizeof(rel_bits)), rel_bits);

    close(fd);

    /* Joystick/gamepad: has BTN_GAMEPAD or BTN_JOYSTICK with ABS axes */
    if (has_key && has_abs) {
        if (TEST_BIT(BTN_GAMEPAD, key_bits) || TEST_BIT(BTN_JOYSTICK, key_bits))
            return DEV_CLASS_JOYSTICK;
        /* Also catch gamepads that only report BTN_SOUTH (Xbox style) */
        if (TEST_BIT(BTN_SOUTH, key_bits) && TEST_BIT(ABS_X, abs_bits))
            return DEV_CLASS_JOYSTICK;
    }

    /* Accelerometer / motion sensor: has ABS but no KEY buttons */
    if (has_abs && !has_key) {
        if (TEST_BIT(ABS_X, abs_bits) && TEST_BIT(ABS_Y, abs_bits) &&
            TEST_BIT(ABS_Z, abs_bits))
            return DEV_CLASS_ACCELEROMETER;
    }

    /* Touchscreen: has ABS_MT_SLOT or ABS_MT_POSITION_X with BTN_TOUCH */
    if (has_abs && has_key) {
        if (TEST_BIT(BTN_TOUCH, key_bits) &&
            (TEST_BIT(ABS_MT_SLOT, abs_bits) || TEST_BIT(ABS_MT_POSITION_X, abs_bits))) {
            /* Distinguish touchscreen from touchpad: touchpad has BTN_TOOL_FINGER */
            if (TEST_BIT(BTN_TOOL_FINGER, key_bits))
                return DEV_CLASS_TOUCHPAD;
            return DEV_CLASS_TOUCHSCREEN;
        }
    }

    /* Mouse (relative): has REL_X + REL_Y + mouse buttons */
    if (has_rel && has_key) {
        if (TEST_BIT(REL_X, rel_bits) && TEST_BIT(REL_Y, rel_bits) &&
            TEST_BIT(BTN_LEFT, key_bits))
            return DEV_CLASS_MOUSE;
    }

    /* Mouse (absolute): has ABS_X + ABS_Y + mouse buttons but not a touch device */
    if (has_abs && has_key) {
        if (TEST_BIT(ABS_X, abs_bits) && TEST_BIT(ABS_Y, abs_bits) &&
            TEST_BIT(BTN_LEFT, key_bits) && !TEST_BIT(BTN_TOUCH, key_bits))
            return DEV_CLASS_MOUSE_ABS;
    }

    /* Keyboard: has letter/number keys */
    if (has_key) {
        if (TEST_BIT(KEY_A, key_bits) && TEST_BIT(KEY_Z, key_bits))
            return DEV_CLASS_KEYBOARD;
    }

    return DEV_CLASS_UNKNOWN;
}

static const char *device_class_name(enum device_class cls) {
    switch (cls) {
    case DEV_CLASS_KEYBOARD:      return "keyboard";
    case DEV_CLASS_MOUSE:         return "mouse";
    case DEV_CLASS_MOUSE_ABS:     return "mouse-abs";
    case DEV_CLASS_JOYSTICK:      return "joystick";
    case DEV_CLASS_TOUCHSCREEN:   return "touchscreen";
    case DEV_CLASS_TOUCHPAD:      return "touchpad";
    case DEV_CLASS_ACCELEROMETER: return "accelerometer";
    case DEV_CLASS_HIDRAW:        return "hidraw";
    default:                      return "unknown";
    }
}

/* ── Helpers ───────────────────────────────────────────────── */

static int is_input_device(const char *name) {
    return (strncmp(name, "event", 5) == 0 ||
            strncmp(name, "js", 2) == 0);
}

static int is_hidraw_device(const char *name) {
    return strncmp(name, "hidraw", 6) == 0;
}

/*
 * Read the phys field of a device's parent input device.
 * For event45: reads /sys/class/input/event45/device/phys
 *
 * Retries with backoff because sysfs attributes may not be
 * populated immediately (especially for UHID children).
 */
static int read_device_phys(const char *sysfs_base, const char *devname,
                            char *phys, size_t phys_size) {
    char phys_path[PATH_MAX];
    snprintf(phys_path, sizeof(phys_path),
             "%s/%s/device/phys", sysfs_base, devname);

    for (int attempt = 0; attempt < PHYS_RETRY_COUNT; attempt++) {
        FILE *f = fopen(phys_path, "r");
        if (f) {
            if (fgets(phys, phys_size, f)) {
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

static int hidraw_base(const char *devname, char *base, size_t base_size);

static int read_hidraw_phys(const char *devname, char *phys, size_t phys_size) {
    /* hidraw phys is at /sys/class/hidraw/hidrawN/device/phys
     * but sometimes it's under the hid parent: .../device/device/phys */
    char base[PATH_MAX], phys_path[PATH_MAX];
    if (!hidraw_base(devname, base, sizeof(base)))
        return 0;

    /* Try direct path first */
    snprintf(phys_path, sizeof(phys_path),
             "%s/%s/device/phys", base, devname);
    FILE *f = fopen(phys_path, "r");
    if (!f) {
        /* Try hid parent */
        snprintf(phys_path, sizeof(phys_path),
                 "%s/%s/device/device/phys", base, devname);
        f = fopen(phys_path, "r");
    }
    if (!f) return 0;

    if (fgets(phys, phys_size, f)) {
        char *nl = strchr(phys, '\n');
        if (nl) *nl = '\0';
        fclose(f);
        return 1;
    }
    fclose(f);
    return 0;
}

static int is_container_input(const char *devname) {
    char phys[256] = {0};
    if (!read_device_phys(SYSFS_INPUT, devname, phys, sizeof(phys)))
        return 0;
    return strncmp(phys, TAG_PREFIX, strlen(TAG_PREFIX)) == 0;
}

static int is_container_hidraw(const char *devname) {
    char phys[256] = {0};
    if (!read_hidraw_phys(devname, phys, sizeof(phys)))
        return 0;
    return strncmp(phys, TAG_PREFIX, strlen(TAG_PREFIX)) == 0;
}

/* ── UHID device claim matching ───────────────────────────── */

/*
 * Check if a sysfs device path resolves through /devices/virtual/misc/uhid/.
 * Only UHID-created devices live there, so this filters out real hardware.
 */
static int is_uhid_device(const char *sysfs_base, const char *devname) {
    char link_path[PATH_MAX], resolved[PATH_MAX];
    snprintf(link_path, sizeof(link_path), "%s/%s", sysfs_base, devname);
    if (!realpath(link_path, resolved))
        return 0;
    return strstr(resolved, "/misc/uhid/") != NULL;
}

/* Read the "name" attribute from a device's parent input device */
static int read_device_name(const char *sysfs_base, const char *devname,
                            char *name, size_t name_size) {
    char path[PATH_MAX];
    snprintf(path, sizeof(path), "%s/%s/device/name", sysfs_base, devname);
    FILE *f = fopen(path, "r");
    if (!f) return 0;
    if (fgets(name, name_size, f)) {
        char *nl = strchr(name, '\n');
        if (nl) *nl = '\0';
        fclose(f);
        return name[0] != '\0';
    }
    fclose(f);
    return 0;
}

/* Read HID_NAME from a hidraw device's parent HID uevent */
static int read_hidraw_hid_name(const char *devname,
                                 char *name, size_t name_size) {
    char base[PATH_MAX], path[PATH_MAX];
    if (!hidraw_base(devname, base, sizeof(base)))
        return 0;
    snprintf(path, sizeof(path), "%s/%s/device/uevent", base, devname);
    FILE *f = fopen(path, "r");
    if (!f) return 0;

    char line[512];
    while (fgets(line, sizeof(line), f)) {
        if (strncmp(line, "HID_NAME=", 9) == 0) {
            char *val = line + 9;
            char *nl = strchr(val, '\n');
            if (nl) *nl = '\0';
            snprintf(name, name_size, "%s", val);
            fclose(f);
            return name[0] != '\0';
        }
    }
    fclose(f);
    return 0;
}

/*
 * Check if a device name matches any UHID name claimed by our shim.
 * Child input devices have names like "<HID name> Touchpad" or
 * "<HID name> Motion Sensors", so we use prefix matching.
 */
static int is_uhid_claimed(const char *device_name) {
    FILE *f = fopen(UHID_NAMES_FILE, "r");
    if (!f) return 0;

    char line[256];
    while (fgets(line, sizeof(line), f)) {
        char *nl = strchr(line, '\n');
        if (nl) *nl = '\0';
        if (line[0] && strncmp(device_name, line, strlen(line)) == 0) {
            fclose(f);
            return 1;
        }
    }
    fclose(f);
    return 0;
}

/* Check if an input device is a UHID device claimed by this container */
static int is_uhid_claimed_input(const char *devname) {
    if (!is_uhid_device(SYSFS_INPUT, devname))
        return 0;
    char name[256];
    if (!read_device_name(SYSFS_INPUT, devname, name, sizeof(name)))
        return 0;
    DBG("UHID input %s name=\"%s\"", devname, name);
    return is_uhid_claimed(name);
}

/* Check if a hidraw device is a UHID device claimed by this container */
static int is_uhid_claimed_hidraw(const char *devname) {
    char base[PATH_MAX];
    if (!hidraw_base(devname, base, sizeof(base)) || !is_uhid_device(base, devname))
        return 0;
    char name[256];
    if (!read_hidraw_hid_name(devname, name, sizeof(name)))
        return 0;
    DBG("UHID hidraw %s HID_NAME=\"%s\"", devname, name);
    return is_uhid_claimed(name);
}

/* Read sysfs dev (major:minor) file */
static int read_dev_numbers(const char *sysfs_base, const char *devname,
                            unsigned int *maj, unsigned int *min) {
    char path[PATH_MAX];
    snprintf(path, sizeof(path), "%s/%s/dev", sysfs_base, devname);
    FILE *f = fopen(path, "r");
    if (!f) return 0;
    int ok = (fscanf(f, "%u:%u", maj, min) == 2);
    fclose(f);
    return ok;
}

/* Read the sysfs DEVPATH for a device (for netlink event) */
static int read_devpath(const char *sysfs_base, const char *devname,
                        char *devpath, size_t devpath_size) {
    char link_path[PATH_MAX], resolved[PATH_MAX];
    snprintf(link_path, sizeof(link_path), "%s/%s", sysfs_base, devname);

    char *rp = realpath(link_path, resolved);
    if (!rp) return 0;

    /* DEVPATH is relative to /sys */
    const char *sys_prefix = "/sys";
    if (strncmp(resolved, sys_prefix, 4) == 0) {
        snprintf(devpath, devpath_size, "%s", resolved + 4);
    } else {
        snprintf(devpath, devpath_size, "%s", resolved);
    }
    return 1;
}

/*
 * The directory holding a hidraw device's sysfs directory, e.g.
 * /sys/devices/virtual/misc/uhid/0005:054C:0CE6.0001/hidraw for hidraw0, so
 * that base/devname is the device.  Resolved from the link in hidraw_list:
 * the kernel's links are relative to /sys/class/hidraw, which still leads to
 * /sys/devices with the view's tmpfs mounted there.
 */
static int hidraw_base(const char *devname, char *base, size_t base_size) {
    char link_path[PATH_MAX], target[PATH_MAX], full[2 * PATH_MAX], resolved[PATH_MAX];
    snprintf(link_path, sizeof(link_path), "%s/%s", hidraw_list, devname);
    ssize_t len = readlink(link_path, target, sizeof(target) - 1);
    if (len <= 0)
        return 0;
    target[len] = '\0';
    if (target[0] == '/')
        snprintf(full, sizeof(full), "%s", target);
    else
        snprintf(full, sizeof(full), SYSFS_HIDRAW "/%s", target);
    if (!realpath(full, resolved))
        return 0;
    char *slash = strrchr(resolved, '/');
    if (!slash || slash == resolved)
        return 0;
    *slash = '\0';
    snprintf(base, base_size, "%s", resolved);
    return 1;
}

/* ── Udev database ────────────────────────────────────────── */

static void ensure_udev_dirs(void) {
    mkdir("/run/udev", 0755);
    mkdir(UDEV_DATA_DIR, 0755);

    /* Touch /run/udev/control to signal "udev is present" to libudev */
    int fd = open("/run/udev/control", O_CREAT | O_WRONLY, 0644);
    if (fd >= 0) close(fd);
}

static void write_udev_db(unsigned int maj, unsigned int min,
                           enum device_class cls) {
    char path[PATH_MAX];
    snprintf(path, sizeof(path), UDEV_DATA_DIR "/c%u:%u", maj, min);

    FILE *f = fopen(path, "w");
    if (!f) {
        ERR("cannot write udev db %s: %s", path, strerror(errno));
        return;
    }

    /* Initialization timestamp */
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    long long usec = (long long)ts.tv_sec * 1000000LL + ts.tv_nsec / 1000;
    fprintf(f, "I:%lld\n", usec);

    /* Device type properties — matches what udev's input_id builtin sets */
    fprintf(f, "E:ID_INPUT=1\n");

    switch (cls) {
    case DEV_CLASS_KEYBOARD:
        fprintf(f, "E:ID_INPUT_KEY=1\n");
        fprintf(f, "E:ID_INPUT_KEYBOARD=1\n");
        break;
    case DEV_CLASS_MOUSE:
    case DEV_CLASS_MOUSE_ABS:
        fprintf(f, "E:ID_INPUT_MOUSE=1\n");
        break;
    case DEV_CLASS_JOYSTICK:
        fprintf(f, "E:ID_INPUT_JOYSTICK=1\n");
        break;
    case DEV_CLASS_TOUCHSCREEN:
        fprintf(f, "E:ID_INPUT_TOUCHSCREEN=1\n");
        break;
    case DEV_CLASS_TOUCHPAD:
        fprintf(f, "E:ID_INPUT_TOUCHPAD=1\n");
        break;
    case DEV_CLASS_ACCELEROMETER:
        fprintf(f, "E:ID_INPUT_ACCELEROMETER=1\n");
        break;
    case DEV_CLASS_HIDRAW:
        /* hidraw gets minimal properties */
        break;
    default:
        break;
    }

    /* Seat tags — needed for logind/polkit integration */
    fprintf(f, "G:seat\n");
    fprintf(f, "G:uaccess\n");
    fprintf(f, "Q:seat\n");
    fprintf(f, "Q:uaccess\n");
    fprintf(f, "V:1\n");

    fclose(f);
    DBG("wrote udev db %s (class=%s)", path, device_class_name(cls));
}

static void remove_udev_db(unsigned int maj, unsigned int min) {
    char path[PATH_MAX];
    snprintf(path, sizeof(path), UDEV_DATA_DIR "/c%u:%u", maj, min);
    if (unlink(path) == 0)
        DBG("removed udev db %s", path);
}

/* ── Udev netlink event sender ────────────────────────────── */

static int udev_netlink_fd = -1;

static int init_udev_netlink(void) {
    udev_netlink_fd = socket(AF_NETLINK, SOCK_RAW, NETLINK_KOBJECT_UEVENT);
    if (udev_netlink_fd < 0) {
        ERR("cannot create netlink socket: %s", strerror(errno));
        return -1;
    }

    struct sockaddr_nl addr = {
        .nl_family = AF_NETLINK,
        .nl_groups = MONITOR_GROUP_UDEV,
    };
    if (bind(udev_netlink_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        ERR("cannot bind netlink socket: %s", strerror(errno));
        close(udev_netlink_fd);
        udev_netlink_fd = -1;
        return -1;
    }

    DBG("udev netlink socket ready");
    return 0;
}

/*
 * Build a null-separated property string and send it as a synthetic udev event.
 * This is what libudev monitors listen for on NETLINK_KOBJECT_UEVENT group 2.
 */
static void send_udev_event(const char *action, const char *devpath,
                             const char *subsystem, const char *devname,
                             unsigned int maj, unsigned int min,
                             enum device_class cls) {
    if (udev_netlink_fd < 0)
        return;

    /* Build null-separated properties */
    char props[4096];
    int off = 0;

#define PROP(fmt, ...) do {                                         \
    int n = snprintf(props + off, sizeof(props) - off, fmt, ##__VA_ARGS__); \
    if (n > 0) off += n + 1; /* include null terminator */          \
} while (0)

    PROP("ACTION=%s", action);
    PROP("DEVPATH=%s", devpath);
    PROP("SUBSYSTEM=%s", subsystem);
    PROP("DEVNAME=%s", devname);
    PROP("MAJOR=%u", maj);
    PROP("MINOR=%u", min);
    PROP("SEQNUM=%lld", (long long)time(NULL));

    /* USEC_INITIALIZED signals to libudev that the device was processed */
    {
        struct timespec ts;
        clock_gettime(CLOCK_MONOTONIC, &ts);
        PROP("USEC_INITIALIZED=%lld",
             (long long)ts.tv_sec * 1000000LL + ts.tv_nsec / 1000);
    }

    if (strcmp(action, "add") == 0) {
        PROP("ID_INPUT=1");
        switch (cls) {
        case DEV_CLASS_KEYBOARD:
            PROP("ID_INPUT_KEY=1");
            PROP("ID_INPUT_KEYBOARD=1");
            PROP(".INPUT_CLASS=kbd");
            break;
        case DEV_CLASS_MOUSE:
        case DEV_CLASS_MOUSE_ABS:
            PROP("ID_INPUT_MOUSE=1");
            PROP(".INPUT_CLASS=mouse");
            break;
        case DEV_CLASS_JOYSTICK:
            PROP("ID_INPUT_JOYSTICK=1");
            PROP(".INPUT_CLASS=joystick");
            break;
        case DEV_CLASS_TOUCHSCREEN:
            PROP("ID_INPUT_TOUCHSCREEN=1");
            PROP(".INPUT_CLASS=touchscreen");
            break;
        case DEV_CLASS_TOUCHPAD:
            PROP("ID_INPUT_TOUCHPAD=1");
            PROP(".INPUT_CLASS=mouse");
            break;
        case DEV_CLASS_ACCELEROMETER:
            PROP("ID_INPUT_ACCELEROMETER=1");
            break;
        default:
            break;
        }
        PROP("TAGS=:seat:uaccess:");
        PROP("CURRENT_TAGS=:seat:uaccess:");
    }

#undef PROP

    /* Build the udev monitor header */
    struct udev_monitor_netlink_header hdr;
    memset(&hdr, 0, sizeof(hdr));
    memcpy(hdr.prefix, "libudev", 8);
    hdr.magic = htobe32(UDEV_MONITOR_MAGIC);
    hdr.header_size = sizeof(hdr);
    hdr.properties_off = sizeof(hdr);
    hdr.properties_len = off;
    hdr.filter_subsystem_hash = htobe32(subsystem_hash(subsystem));

    struct sockaddr_nl dst = {
        .nl_family = AF_NETLINK,
        .nl_groups = MONITOR_GROUP_UDEV,
    };
    struct iovec iov[2] = {
        { .iov_base = &hdr, .iov_len = sizeof(hdr) },
        { .iov_base = props, .iov_len = off },
    };
    struct msghdr msg = {
        .msg_name = &dst,
        .msg_namelen = sizeof(dst),
        .msg_iov = iov,
        .msg_iovlen = 2,
    };

    if (sendmsg(udev_netlink_fd, &msg, 0) < 0) {
        DBG("sendmsg udev event failed: %s", strerror(errno));
    } else {
        DBG("sent udev %s event for %s (class=%s)",
            action, devname, device_class_name(cls));
    }
}

/* ── Device node placement/removal ────────────────────────── */

/*
 * Bind-mode readiness deferral.  A device's host node is handed to GAMER_UID
 * by host udev asynchronously, so bind mode waits (up to DEFER_MAX polls) for
 * that before placing the node.  Entries exist only while a device is being
 * deferred; they are dropped on success, on giving up, or when the device
 * disappears from sysfs (defer_prune).
 */
/* Deferral reasons, one entry per device and reason */
enum defer_family {
    DEFER_INPUT_OWNER = 0,  /* input node: waiting for host udev ownership */
    DEFER_HIDRAW_OWNER = 1, /* hidraw node: waiting for host udev ownership */
    DEFER_HID_SIBLING = 2,  /* input node: waiting for its HID device's hidraw node */
};

struct defer_entry {
    char name[32];
    int family;     /* enum defer_family */
    int used;
    int seen;       /* deferred during the current scan pass */
    int count;      /* deferrals so far */
};

static struct defer_entry defer_tab[DEFER_SLOTS];

static struct defer_entry *defer_lookup(const char *devname, int family) {
    for (int i = 0; i < DEFER_SLOTS; i++) {
        struct defer_entry *e = &defer_tab[i];
        if (e->used && e->family == family && strcmp(e->name, devname) == 0)
            return e;
    }
    return NULL;
}

static struct defer_entry *defer_alloc(const char *devname, int family) {
    for (int i = 0; i < DEFER_SLOTS; i++) {
        struct defer_entry *e = &defer_tab[i];
        if (!e->used) {
            snprintf(e->name, sizeof(e->name), "%s", devname);
            e->family = family;
            e->used = 1;
            e->seen = 0;
            e->count = 0;
            return e;
        }
    }
    return NULL;
}

/* End of a scan pass: free this family's entries not deferred in the pass */
static void defer_prune(int family) {
    for (int i = 0; i < DEFER_SLOTS; i++) {
        struct defer_entry *e = &defer_tab[i];
        if (!e->used || e->family != family)
            continue;
        if (!e->seen) {
            DBG("dropped deferred %s (gone)", e->name);
            e->used = 0;
        } else {
            e->seen = 0;
        }
    }
}

/*
 * Devpath of each placed node, recorded when the node is created.  A device
 * destroyed and recreated between two polls usually gets the same devname
 * and maj:min (the kernel reuses the lowest free minor) but a new parent
 * (inputN), so a changed devpath is how pass 2 detects it.  The recorded
 * devpath is also what remove events carry: libinput matches removals by
 * syspath.  Nodes found without an entry (e.g. after a daemon restart) are
 * adopted with their current devpath.
 */
struct node_entry {
    char name[32];
    int hidraw;
    int used;
    char devpath[256];
};

static struct node_entry node_tab[NODE_SLOTS];

static struct node_entry *node_lookup(const char *devname, int hidraw) {
    for (int i = 0; i < NODE_SLOTS; i++) {
        struct node_entry *e = &node_tab[i];
        if (e->used && e->hidraw == hidraw && strcmp(e->name, devname) == 0)
            return e;
    }
    return NULL;
}

static void node_record(const char *devname, int hidraw, const char *devpath) {
    struct node_entry *e = node_lookup(devname, hidraw);
    for (int i = 0; !e && i < NODE_SLOTS; i++) {
        if (!node_tab[i].used)
            e = &node_tab[i];
    }
    if (!e) {
        INFO("node table full, not tracking %s", devname);
        return;
    }
    snprintf(e->name, sizeof(e->name), "%s", devname);
    e->hidraw = hidraw;
    e->used = 1;
    snprintf(e->devpath, sizeof(e->devpath), "%s", devpath);
}

static void node_forget(const char *devname, int hidraw) {
    struct node_entry *e = node_lookup(devname, hidraw);
    if (e)
        e->used = 0;
}

/*
 * Has devname been recreated since its node was placed?  Compares the current
 * sysfs devpath with the recorded one; an untracked node is adopted.
 */
static int node_recreated(const char *sysfs_base, const char *devname, int hidraw) {
    char devpath[PATH_MAX];
    if (!read_devpath(sysfs_base, devname, devpath, sizeof(devpath)))
        return 0;   /* transient */
    struct node_entry *e = node_lookup(devname, hidraw);
    if (!e) {
        node_record(devname, hidraw, devpath);
        return 0;
    }
    /* Bounded: a devpath longer than the table field is stored truncated */
    return strncmp(e->devpath, devpath, sizeof(e->devpath) - 1) != 0;
}

/*
 * Devpath for a remove event: the recorded one, else a best guess from the
 * device family.
 */
static void removed_devpath(const char *devname, int hidraw,
                            char *out, size_t outsz) {
    struct node_entry *e = node_lookup(devname, hidraw);
    if (e)
        snprintf(out, outsz, "%s", e->devpath);
    else
        snprintf(out, outsz, "/devices/virtual/%s/%s",
                 hidraw ? "misc" : "input", devname);
}

/* Does host_path name a char device with rdev maj:min? */
static int host_node_match(const char *host_path, unsigned int maj, unsigned int min) {
    struct stat st;
    return stat(host_path, &st) == 0 && S_ISCHR(st.st_mode) &&
           st.st_rdev == makedev(maj, min);
}

/*
 * Host node path for container device devname (maj:min).  Candidates, in
 * lookup order:
 *   HOST_DEV_DIR/gamehub-input/<devname>   (host udev moved the node here)
 *   HOST_DEV_DIR/input/<devname>           (original location, input family)
 *   HOST_DEV_DIR/<devname>                 (original location, hidraw family)
 * Returns 1 if a candidate is a char device with rdev maj:min (out is that
 * candidate).  Returns 0 if none matched: out is then the original location,
 * so the ownership check and mknod fallback behave as before.  Returns -1 if
 * a path would not fit in outsz.
 */
static int host_node_path(const char *devname, int hidraw,
                          unsigned int maj, unsigned int min,
                          char *out, size_t outsz) {
    char hidden[PATH_MAX], orig[PATH_MAX];
    int hn = snprintf(hidden, sizeof(hidden), "%s/" HOST_HIDDEN_DIR "/%s",
                      host_dev_dir, devname);
    int on;
    if (hidraw)
        on = snprintf(orig, sizeof(orig), "%s/%s", host_dev_dir, devname);
    else
        on = snprintf(orig, sizeof(orig), "%s/input/%s", host_dev_dir, devname);
    if (hn < 0 || hn >= (int)sizeof(hidden) || on < 0 || on >= (int)sizeof(orig))
        return -1;

    if (host_node_match(hidden, maj, min)) {
        if (snprintf(out, outsz, "%s", hidden) >= (int)outsz)
            return -1;
        return 1;
    }
    if (snprintf(out, outsz, "%s", orig) >= (int)outsz)
        return -1;
    return host_node_match(orig, maj, min);
}

/*
 * Bind mode only: returns 1 if creation should wait for a later poll because
 * the chosen host node is not yet owned by gamer_uid.  After DEFER_MAX
 * deferrals the node is created anyway with a warning.  Always returns 0 in
 * mknod mode.
 */
static int should_defer_node(const char *devname, int hidraw,
                             unsigned int maj, unsigned int min) {
    if (!bind_mode)
        return 0;

    char hostpath[PATH_MAX];
    if (host_node_path(devname, hidraw, maj, min, hostpath, sizeof(hostpath)) < 0)
        return 0;   /* cannot form the path; place_node falls back to mknod */
    struct stat st;
    int ready = (stat(hostpath, &st) == 0 && st.st_uid == gamer_uid);

    int family = hidraw ? DEFER_HIDRAW_OWNER : DEFER_INPUT_OWNER;
    struct defer_entry *e = defer_lookup(devname, family);
    if (ready) {
        if (e)
            e->used = 0;
        return 0;
    }

    if (!e) {
        e = defer_alloc(devname, family);
        if (!e) {
            INFO("deferral table full, not waiting for %s", devname);
            return 0;
        }
    }
    e->seen = 1;

    if (e->count < DEFER_MAX) {
        e->count++;
        DBG("deferring %s: %s not owned by uid %u (%d/%d)",
            devname, hostpath, gamer_uid, e->count, DEFER_MAX);
        return 1;
    }

    INFO("WARNING: %s: %s still not owned by uid %u after %d polls, creating anyway",
         devname, hostpath, gamer_uid, DEFER_MAX);
    e->used = 0;
    return 0;
}

/*
 * Returns 1 if input node devname belongs to a HID device (e.g. a UHID
 * DualSense) whose hidraw node is not placed in the container yet, so its
 * creation should wait for a later poll.  SDL (Steam) drives a controller
 * through HIDAPI only if the hidraw node is there when the evdev node shows
 * up; otherwise it keeps the evdev path, whose DualSense mapping differs
 * (Circle confirms in the Steam UI) until the controller reconnects.  Gives
 * up after DEFER_MAX polls.  Devices without a HID parent (uinput mice,
 * keyboards, pads) never wait.
 */
static int hid_sibling_pending(const char *devname) {
    char path[PATH_MAX], link[PATH_MAX];
    /* eventN/device is inputM; inputM/device is the HID device, if any */
    snprintf(path, sizeof(path), SYSFS_INPUT "/%s/device/device/subsystem", devname);
    ssize_t n = readlink(path, link, sizeof(link) - 1);
    if (n <= 0)
        return 0;
    link[n] = '\0';
    const char *sub = strrchr(link, '/');
    if (strcmp(sub ? sub + 1 : link, "hid") != 0)
        return 0;

    int placed = 0;
    snprintf(path, sizeof(path), SYSFS_INPUT "/%s/device/device/hidraw", devname);
    DIR *d = opendir(path);   /* absent until the kernel connects hidraw */
    if (d) {
        struct dirent *ent;
        while ((ent = readdir(d))) {
            if (!is_hidraw_device(ent->d_name))
                continue;
            char nodepath[PATH_MAX];
            struct stat st;
            snprintf(nodepath, sizeof(nodepath), DEV_BASE "/%s", ent->d_name);
            if (stat(nodepath, &st) == 0 && S_ISCHR(st.st_mode))
                placed = 1;
        }
        closedir(d);
    }

    struct defer_entry *e = defer_lookup(devname, DEFER_HID_SIBLING);
    if (placed) {
        if (e)
            e->used = 0;
        return 0;
    }
    if (!e) {
        e = defer_alloc(devname, DEFER_HID_SIBLING);
        if (!e) {
            INFO("deferral table full, not waiting for the hidraw node of %s", devname);
            return 0;
        }
    }
    e->seen = 1;
    if (e->count < DEFER_MAX) {
        e->count++;
        DBG("deferring %s: hidraw node of its HID device not placed yet (%d/%d)",
            devname, e->count, DEFER_MAX);
        return 1;
    }
    INFO("WARNING: %s: hidraw node of its HID device still missing after %d polls, creating anyway",
         devname, DEFER_MAX);
    e->used = 0;
    return 0;
}

/* Is path the mount point of an entry in /proc/self/mountinfo? */
static int is_mount_point(const char *path) {
    FILE *f = fopen("/proc/self/mountinfo", "re");
    if (!f)
        return 0;
    char line[4096], mnt[PATH_MAX];
    int found = 0;
    while (!found && fgets(line, sizeof(line), f)) {
        /* Fields: id parent major:minor root mount-point ... */
        if (sscanf(line, "%*s %*s %*s %*s %4095s", mnt) == 1 &&
            strcmp(mnt, path) == 0)
            found = 1;
    }
    fclose(f);
    return found;
}

/*
 * Hidraw view (see the header comment): bind the real /sys/class/hidraw at
 * HIDRAW_REAL_DIR, then mount a tmpfs over /sys/class/hidraw.  Both mounts
 * are kept when the daemon restarts.  On failure the real directory stays in
 * place and is used as before.
 */
static void setup_hidraw_view(void) {
    if (mkdir(HIDRAW_REAL_DIR, 0700) != 0 && errno != EEXIST) {
        INFO("WARNING: cannot create %s: %s", HIDRAW_REAL_DIR, strerror(errno));
        return;
    }
    int have_real = is_mount_point(HIDRAW_REAL_DIR);
    int have_view = is_mount_point(SYSFS_HIDRAW);
    if (have_view && !have_real) {
        /* Should not happen; the real directory is under the tmpfs */
        if (umount2(SYSFS_HIDRAW, MNT_DETACH) != 0) {
            INFO("WARNING: cannot unmount stale %s: %s", SYSFS_HIDRAW, strerror(errno));
            return;
        }
        have_view = 0;
    }
    if (!have_real &&
        mount(SYSFS_HIDRAW, HIDRAW_REAL_DIR, NULL, MS_BIND, NULL) != 0) {
        INFO("WARNING: cannot bind %s at %s: %s", SYSFS_HIDRAW, HIDRAW_REAL_DIR,
             strerror(errno));
        return;
    }
    if (!have_view &&
        mount("gamehub-hidraw", SYSFS_HIDRAW, "tmpfs",
              MS_NOSUID | MS_NODEV | MS_NOEXEC, "mode=0755,size=64k") != 0) {
        INFO("WARNING: cannot mount the hidraw view on %s: %s", SYSFS_HIDRAW,
             strerror(errno));
        umount2(HIDRAW_REAL_DIR, MNT_DETACH);
        return;
    }
    hidraw_list = HIDRAW_REAL_DIR;
    hidraw_view = 1;
    INFO("%s lists only placed container hidraw devices (real list at %s)",
         SYSFS_HIDRAW, HIDRAW_REAL_DIR);
}

/* Show a placed hidraw device in the view: copy the kernel's link */
static void hidraw_view_add(const char *devname) {
    if (!hidraw_view)
        return;
    char real[PATH_MAX], view[PATH_MAX], target[PATH_MAX];
    snprintf(real, sizeof(real), HIDRAW_REAL_DIR "/%s", devname);
    snprintf(view, sizeof(view), SYSFS_HIDRAW "/%s", devname);
    ssize_t len = readlink(real, target, sizeof(target) - 1);
    if (len <= 0) {
        DBG("cannot read link %s: %s", real, strerror(errno));
        return;
    }
    target[len] = '\0';
    unlink(view);
    if (symlink(target, view) != 0)
        INFO("WARNING: cannot add %s to the hidraw view: %s", devname, strerror(errno));
}

static void hidraw_view_remove(const char *devname) {
    if (!hidraw_view)
        return;
    char view[PATH_MAX];
    snprintf(view, sizeof(view), SYSFS_HIDRAW "/%s", devname);
    unlink(view);
}

/*
 * Bind mode: make STAGE_DIR a shared tmpfs (see the header comment).  It must
 * be shared before Steam starts a game, so this runs before the first scan.
 * On failure nodes are bound at their public names as before.
 */
static void setup_stage_dir(void) {
    mkdir(DEV_INPUT, 0755);
    if (mkdir(STAGE_DIR, 0755) != 0 && errno != EEXIST) {
        INFO("WARNING: cannot create %s: %s", STAGE_DIR, strerror(errno));
        return;
    }
    if (!is_mount_point(STAGE_DIR) &&
        mount("tmpfs", STAGE_DIR, "tmpfs", MS_NOSUID | MS_NODEV,
              "mode=0755,size=64k") != 0) {
        INFO("WARNING: cannot mount %s: %s", STAGE_DIR, strerror(errno));
        return;
    }
    if (mount(NULL, STAGE_DIR, NULL, MS_SHARED, NULL) != 0) {
        INFO("WARNING: cannot make %s shared: %s", STAGE_DIR, strerror(errno));
        return;
    }
    stage_ready = 1;
    INFO("staging nodes in %s (shared)", STAGE_DIR);
}

/* Bind a placeholder at path to hostpath.  Returns 0 on success. */
static int bind_placeholder(const char *hostpath, const char *path) {
    int fd = open(path, O_CREAT | O_WRONLY | O_CLOEXEC, 0644);
    if (fd < 0) {
        INFO("cannot create placeholder %s: %s", path, strerror(errno));
        return -1;
    }
    close(fd);
    if (mount(hostpath, path, NULL, MS_BIND, NULL) != 0) {
        INFO("bind %s -> %s failed: %s", hostpath, path, strerror(errno));
        unlink(path);
        return -1;
    }
    return 0;
}

/*
 * Place a node at nodepath for host device devname (maj:min).  Bind mode:
 * bind the host node over an empty placeholder, where the host node is chosen
 * by host_node_path (hidden dir first, then the original location) and must
 * be a char device with the expected rdev.  With STAGE_DIR ready the
 * placeholder is STAGE_DIR/devname and nodepath becomes a symlink to it;
 * otherwise the placeholder is nodepath itself.  If binding fails, mknod is
 * tried.  Returns 0 on success, -1 on failure.
 */
static int place_node(const char *nodepath, const char *devname, int hidraw,
                      unsigned int maj, unsigned int min) {
    if (bind_mode) {
        char hostpath[PATH_MAX];
        if (host_node_path(devname, hidraw, maj, min, hostpath, sizeof(hostpath)) != 1) {
            DBG("host node for %s missing or not char %u:%u, using mknod",
                devname, maj, min);
        } else if (stage_ready) {
            char stagepath[PATH_MAX];
            snprintf(stagepath, sizeof(stagepath), STAGE_DIR "/%s", devname);
            if (bind_placeholder(hostpath, stagepath) == 0) {
                if (symlink(stagepath, nodepath) == 0) {
                    DBG("bound %s -> %s, linked %s (%u:%u)",
                        hostpath, stagepath, nodepath, maj, min);
                    return 0;
                }
                INFO("symlink %s -> %s failed: %s",
                     nodepath, stagepath, strerror(errno));
                umount2(stagepath, MNT_DETACH);
                unlink(stagepath);
            }
            INFO("falling back to mknod for %s", devname);
        } else if (bind_placeholder(hostpath, nodepath) == 0) {
            DBG("bound %s -> %s (%u:%u)", hostpath, nodepath, maj, min);
            return 0;
        } else {
            INFO("falling back to mknod for %s", devname);
        }
    }

    if (mknod(nodepath, S_IFCHR | 0666, makedev(maj, min)) != 0) {
        DBG("mknod %s failed: %s", nodepath, strerror(errno));
        return -1;
    }
    DBG("created %s (%u:%u)", nodepath, maj, min);
    return 0;
}

/* Unmount a bind placeholder (EINVAL: not a mount point, ENOENT: absent;
 * both ignored), then unlink it. */
static void drop_placeholder(const char *path) {
    if (umount2(path, MNT_DETACH | UMOUNT_NOFOLLOW) != 0 &&
        errno != EINVAL && errno != ENOENT)
        DBG("umount2 %s failed: %s", path, strerror(errno));
    if (unlink(path) == 0)
        DBG("removed %s", path);
}

/*
 * Remove a node placed by place_node: the public name (a symlink, a bind
 * placeholder or a mknod node), then its staged placeholder, if any.
 */
static void drop_node(const char *nodepath, const char *devname) {
    struct stat st;
    if (lstat(nodepath, &st) == 0 && S_ISLNK(st.st_mode)) {
        if (unlink(nodepath) == 0)
            DBG("removed link %s", nodepath);
    } else {
        drop_placeholder(nodepath);
    }
    if (stage_ready) {
        char stagepath[PATH_MAX];
        snprintf(stagepath, sizeof(stagepath), STAGE_DIR "/%s", devname);
        drop_placeholder(stagepath);
    }
}

static void create_input_node(const char *devname) {
    unsigned int maj, min;
    if (!read_dev_numbers(SYSFS_INPUT, devname, &maj, &min)) {
        DBG("cannot read dev numbers for %s", devname);
        return;
    }

    if (should_defer_node(devname, 0, maj, min))
        return;
    if (hid_sibling_pending(devname))
        return;

    /* Ensure /dev/input/ exists */
    mkdir(DEV_INPUT, 0755);

    char nodepath[PATH_MAX];
    snprintf(nodepath, sizeof(nodepath), DEV_INPUT "/%s", devname);

    /* Remove stale node or placeholder if present */
    drop_node(nodepath, devname);

    if (place_node(nodepath, devname, 0, maj, min) != 0)
        return;

    /* Classify device type for udev DB */
    enum device_class cls = DEV_CLASS_UNKNOWN;
    if (strncmp(devname, "event", 5) == 0) {
        cls = classify_evdev(nodepath);
        DBG("classified %s as %s", devname, device_class_name(cls));
    }
    /* js* devices: set joystick class */
    if (strncmp(devname, "js", 2) == 0)
        cls = DEV_CLASS_JOYSTICK;

    /* Write udev database entry */
    write_udev_db(maj, min, cls);

    /* Send synthetic udev event */
    char devpath[PATH_MAX];
    if (read_devpath(SYSFS_INPUT, devname, devpath, sizeof(devpath))) {
        node_record(devname, 0, devpath);
        send_udev_event("add", devpath, "input", nodepath, maj, min, cls);
    }
}

static void remove_input_node(const char *devname) {
    /* Read major:minor before removing node (need it for DB cleanup) */
    char nodepath[PATH_MAX];
    snprintf(nodepath, sizeof(nodepath), DEV_INPUT "/%s", devname);

    struct stat st;
    unsigned int maj = 0, min = 0;
    if (stat(nodepath, &st) == 0) {
        maj = major(st.st_rdev);
        min = minor(st.st_rdev);
    }

    drop_node(nodepath, devname);

    /* Clean up udev DB entry */
    if (maj || min) {
        remove_udev_db(maj, min);

        /* Send remove event */
        char devpath[PATH_MAX];
        removed_devpath(devname, 0, devpath, sizeof(devpath));
        send_udev_event("remove", devpath, "input", nodepath,
                        maj, min, DEV_CLASS_UNKNOWN);
    }
    node_forget(devname, 0);
}

static void create_hidraw_node(const char *devname) {
    unsigned int maj, min;
    char base[PATH_MAX];
    if (!hidraw_base(devname, base, sizeof(base)) ||
        !read_dev_numbers(base, devname, &maj, &min)) {
        DBG("cannot read dev numbers for hidraw %s", devname);
        return;
    }

    if (should_defer_node(devname, 1, maj, min))
        return;

    char nodepath[PATH_MAX];
    snprintf(nodepath, sizeof(nodepath), DEV_BASE "/%s", devname);

    /* Remove stale node or placeholder if present */
    drop_node(nodepath, devname);

    if (place_node(nodepath, devname, 1, maj, min) != 0)
        return;

    /* Write udev DB for hidraw */
    write_udev_db(maj, min, DEV_CLASS_HIDRAW);

    /* Only now that the node exists may Steam see the device in sysfs */
    hidraw_view_add(devname);

    /* Send synthetic udev event */
    char devpath[PATH_MAX];
    if (read_devpath(base, devname, devpath, sizeof(devpath))) {
        node_record(devname, 1, devpath);
        send_udev_event("add", devpath, "hidraw", nodepath,
                        maj, min, DEV_CLASS_HIDRAW);
    }
}

static void remove_hidraw_node(const char *devname) {
    char nodepath[PATH_MAX];
    snprintf(nodepath, sizeof(nodepath), DEV_BASE "/%s", devname);

    /* Out of the view before the node goes, the reverse of creation */
    hidraw_view_remove(devname);

    struct stat st;
    unsigned int maj = 0, min = 0;
    if (stat(nodepath, &st) == 0) {
        maj = major(st.st_rdev);
        min = minor(st.st_rdev);
    }

    drop_node(nodepath, devname);

    if (maj || min) {
        remove_udev_db(maj, min);
        char devpath[PATH_MAX];
        removed_devpath(devname, 1, devpath, sizeof(devpath));
        send_udev_event("remove", devpath, "hidraw", nodepath,
                        maj, min, DEV_CLASS_UNKNOWN);
    }
    node_forget(devname, 1);
}

/* ── Polling scan ────────────────────────────────────────── */

/*
 * Pass 2 staleness.  A node is stale if its sysfs entry is gone, the device
 * is no longer container-owned (the number was reused by a host device), the
 * node's rdev no longer matches sysfs, or the device was recreated under the
 * same name (its devpath changed).  An unreadable sysfs dev file is
 * treated as not stale (transient).
 */
static int node_rdev_mismatch(const char *sysfs_base, const char *devname,
                              const char *nodepath) {
    unsigned int maj, min;
    if (!read_dev_numbers(sysfs_base, devname, &maj, &min))
        return 0;
    struct stat ns;
    if (stat(nodepath, &ns) != 0)
        return 0;
    /* A placeholder whose bind mount was lost is a plain file: stale */
    if (!S_ISCHR(ns.st_mode) || ns.st_rdev != makedev(maj, min))
        return 1;
    /* A bound host node that host udev has since unlinked (device removed,
     * possibly recreated under the same name): stale */
    return bind_mode && ns.st_nlink == 0;
}

static int input_node_stale(const char *devname, const char *nodepath) {
    char syspath[PATH_MAX];
    snprintf(syspath, sizeof(syspath), SYSFS_INPUT "/%s", devname);
    struct stat st;
    if (stat(syspath, &st) != 0) {
        DBG("stale device gone: %s", devname);
        return 1;
    }
    if (!is_container_input(devname) && !is_uhid_claimed_input(devname)) {
        DBG("%s no longer container-owned", devname);
        return 1;
    }
    if (node_rdev_mismatch(SYSFS_INPUT, devname, nodepath)) {
        DBG("%s rdev no longer matches sysfs", devname);
        return 1;
    }
    if (node_recreated(SYSFS_INPUT, devname, 0)) {
        DBG("%s was recreated (devpath changed)", devname);
        return 1;
    }
    return 0;
}

static int hidraw_node_stale(const char *devname, const char *nodepath) {
    char base[PATH_MAX], syspath[PATH_MAX];
    struct stat st;
    if (!hidraw_base(devname, base, sizeof(base))) {
        DBG("stale hidraw gone: %s", devname);
        return 1;
    }
    snprintf(syspath, sizeof(syspath), "%s/%s", base, devname);
    if (stat(syspath, &st) != 0) {
        DBG("stale hidraw gone: %s", devname);
        return 1;
    }
    if (!is_container_hidraw(devname) && !is_uhid_claimed_hidraw(devname)) {
        DBG("hidraw %s no longer container-owned", devname);
        return 1;
    }
    if (node_rdev_mismatch(base, devname, nodepath)) {
        DBG("hidraw %s rdev no longer matches sysfs", devname);
        return 1;
    }
    if (node_recreated(base, devname, 1)) {
        DBG("hidraw %s was recreated (devpath changed)", devname);
        return 1;
    }
    return 0;
}

/*
 * Scan /sys/class/input/ and create/remove device nodes as needed.
 * Returns the number of container devices currently present.
 */
static int poll_and_sync_input(void) {
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
        if (!is_container_input(ent->d_name) &&
            !is_uhid_claimed_input(ent->d_name))
            continue;

        count++;

        /* Check if node already exists */
        char nodepath[PATH_MAX];
        snprintf(nodepath, sizeof(nodepath), DEV_INPUT "/%s", ent->d_name);
        struct stat st;
        if (stat(nodepath, &st) == 0)
            continue;   /* already created */

        DBG("new container device: %s", ent->d_name);
        create_input_node(ent->d_name);
    }
    closedir(d);
    defer_prune(DEFER_INPUT_OWNER);
    defer_prune(DEFER_HID_SIBLING);

    /* Pass 2: remove stale nodes whose sysfs entry is gone */
    d = opendir(DEV_INPUT);
    if (d) {
        while ((ent = readdir(d))) {
            if (!is_input_device(ent->d_name))
                continue;

            char nodepath[PATH_MAX];
            snprintf(nodepath, sizeof(nodepath), DEV_INPUT "/%s", ent->d_name);
            if (input_node_stale(ent->d_name, nodepath))
                remove_input_node(ent->d_name);
        }
        closedir(d);
    }

    return count;
}

static int poll_and_sync_hidraw(void) {
    int count = 0;

    DIR *d = opendir(hidraw_list);
    if (!d)
        return 0; /* hidraw sysfs may not exist if no HID devices */

    struct dirent *ent;
    while ((ent = readdir(d))) {
        if (!is_hidraw_device(ent->d_name))
            continue;
        if (!is_container_hidraw(ent->d_name) &&
            !is_uhid_claimed_hidraw(ent->d_name))
            continue;

        count++;

        char nodepath[PATH_MAX];
        snprintf(nodepath, sizeof(nodepath), DEV_BASE "/%s", ent->d_name);
        struct stat st;
        if (stat(nodepath, &st) == 0) {
            /* Placed before the view existed (daemon restart) */
            char view[PATH_MAX];
            snprintf(view, sizeof(view), SYSFS_HIDRAW "/%s", ent->d_name);
            if (hidraw_view && lstat(view, &st) != 0)
                hidraw_view_add(ent->d_name);
            continue;
        }

        DBG("new container hidraw: %s", ent->d_name);
        create_hidraw_node(ent->d_name);
    }
    closedir(d);
    defer_prune(DEFER_HIDRAW_OWNER);

    /* Remove stale hidraw nodes — scan /dev for hidraw* and check sysfs */
    d = opendir(DEV_BASE);
    if (d) {
        while ((ent = readdir(d))) {
            if (!is_hidraw_device(ent->d_name))
                continue;

            char nodepath[PATH_MAX];
            snprintf(nodepath, sizeof(nodepath), DEV_BASE "/%s", ent->d_name);
            if (hidraw_node_stale(ent->d_name, nodepath))
                remove_hidraw_node(ent->d_name);
        }
        closedir(d);
    }

    /* Drop view links whose node is gone (e.g. left by a daemon restart) */
    if (hidraw_view && (d = opendir(SYSFS_HIDRAW))) {
        while ((ent = readdir(d))) {
            if (!is_hidraw_device(ent->d_name))
                continue;
            char nodepath[PATH_MAX];
            snprintf(nodepath, sizeof(nodepath), DEV_BASE "/%s", ent->d_name);
            struct stat st;
            if (stat(nodepath, &st) != 0)
                hidraw_view_remove(ent->d_name);
        }
        closedir(d);
    }

    return count;
}

/* ── Main loop ────────────────────────────────────────────── */

int main(void) {
    /*
     * Clear umask so mknod(0666) creates world-readable nodes (mknod mode).
     * Bind-mode placeholders are created 0644 and the bound node takes the
     * host node's mode, so the umask does not affect bind mode.
     */
    umask(0);

    const char *dbg = getenv("UINPUT_SHIM_DEBUG");
    debug_enabled = (dbg && dbg[0] == '1');

    INFO("starting — polling %s + %s for %s* devices",
         SYSFS_INPUT, SYSFS_HIDRAW, TAG_PREFIX);

    /* Node placement mode: bind if HOST_DEV_DIR is a directory, else mknod */
    const char *hd = getenv("HOST_DEV_DIR");
    if (hd && hd[0])
        snprintf(host_dev_dir, sizeof(host_dev_dir), "%s", hd);

    const char *gu = getenv("GAMER_UID");
    if (gu && gu[0]) {
        char *end = NULL;
        unsigned long v = strtoul(gu, &end, 10);
        if (end && *end == '\0' && end != gu)
            gamer_uid = (unsigned int)v;
        else
            INFO("ignoring invalid GAMER_UID=\"%s\", using %u", gu, gamer_uid);
    }

    struct stat hst;
    bind_mode = (stat(host_dev_dir, &hst) == 0 && S_ISDIR(hst.st_mode));
    INFO("node mode: %s (HOST_DEV_DIR=%s, GAMER_UID=%u)",
         bind_mode ? "bind" : "mknod", host_dev_dir, gamer_uid);

    if (bind_mode) {
        /* Hide the host /dev bind from non-root: lock down its parent dir */
        char parent[PATH_MAX];
        snprintf(parent, sizeof(parent), "%s", host_dev_dir);
        char *slash = strrchr(parent, '/');
        if (!slash)
            parent[0] = '\0';
        else if (slash == parent)
            parent[1] = '\0';
        else
            *slash = '\0';

        if (parent[0] == '\0' || strcmp(parent, "/") == 0 ||
            strcmp(parent, "/run") == 0 || strcmp(parent, "/dev") == 0 ||
            strcmp(parent, "/run/user") == 0) {
            INFO("not restricting %s (protected path, parent of HOST_DEV_DIR)", parent);
        } else if (chmod(parent, 0700) == 0) {
            INFO("chmod 0700 %s (hides HOST_DEV_DIR from non-root)", parent);
        } else {
            INFO("WARNING: chmod 0700 %s failed: %s", parent, strerror(errno));
        }
    }

    if (bind_mode)
        setup_stage_dir();
    setup_hidraw_view();

    /* Prepare udev infrastructure */
    ensure_udev_dirs();

    /* Create UHID claims directory (world-writable so user-space shim can write) */
    mkdir("/run/container-input", 0755);
    chmod("/run/container-input", 0777);
    if (init_udev_netlink() < 0)
        ERR("udev netlink init failed — SDL gamepad discovery may not work");

    /*
     * hidraw before input in every pass: a HID controller's evdev node waits
     * for its hidraw node (hid_sibling_pending), so both usually appear in
     * the same pass, hidraw first.
     */
    int nh = poll_and_sync_hidraw();
    int ni = poll_and_sync_input();
    INFO("initial scan: %d input + %d hidraw container device(s)", ni, nh);

    /* Poll loop */
    for (;;) {
        usleep(POLL_INTERVAL_USEC);
        poll_and_sync_hidraw();
        poll_and_sync_input();
    }

    return 0;
}
