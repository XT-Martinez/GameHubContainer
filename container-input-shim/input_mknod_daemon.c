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
 * Environment variables:
 *   UINPUT_SHIM_DEBUG   - set to "1" for verbose logging to stderr
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
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <linux/netlink.h>
#include <arpa/inet.h>
#include <time.h>
#include <unistd.h>

/* ── Configuration ─────────────────────────────────────────── */

#define SYSFS_INPUT    "/sys/class/input"
#define SYSFS_HIDRAW   "/sys/class/hidraw"
#define DEV_INPUT      "/dev/input"
#define DEV_BASE       "/dev"
#define UDEV_DATA_DIR  "/run/udev/data"
#define TAG_PREFIX     "container-"

/* How long to wait for sysfs to populate */
#define PHYS_RETRY_COUNT   20
#define PHYS_RETRY_USEC    50000   /* 50ms per retry → 1s max */

/* Poll interval in microseconds (500ms) */
#define POLL_INTERVAL_USEC  500000

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

static int read_hidraw_phys(const char *devname, char *phys, size_t phys_size) {
    /* hidraw phys is at /sys/class/hidraw/hidrawN/device/phys
     * but sometimes it's under the hid parent: .../device/device/phys */
    char phys_path[PATH_MAX];

    /* Try direct path first */
    snprintf(phys_path, sizeof(phys_path),
             SYSFS_HIDRAW "/%s/device/phys", devname);
    FILE *f = fopen(phys_path, "r");
    if (!f) {
        /* Try hid parent */
        snprintf(phys_path, sizeof(phys_path),
                 SYSFS_HIDRAW "/%s/device/device/phys", devname);
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

/* ── Device node creation/removal ─────────────────────────── */

static void create_input_node(const char *devname) {
    unsigned int maj, min;
    if (!read_dev_numbers(SYSFS_INPUT, devname, &maj, &min)) {
        DBG("cannot read dev numbers for %s", devname);
        return;
    }

    /* Ensure /dev/input/ exists */
    mkdir(DEV_INPUT, 0755);

    char nodepath[PATH_MAX];
    snprintf(nodepath, sizeof(nodepath), DEV_INPUT "/%s", devname);

    /* Remove stale node if present */
    unlink(nodepath);

    if (mknod(nodepath, S_IFCHR | 0666, makedev(maj, min)) != 0) {
        DBG("mknod %s failed: %s", nodepath, strerror(errno));
        return;
    }
    DBG("created %s (%u:%u)", nodepath, maj, min);

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

    if (unlink(nodepath) == 0)
        DBG("removed %s", nodepath);

    /* Clean up udev DB entry */
    if (maj || min) {
        remove_udev_db(maj, min);

        /* Send remove event */
        char devpath[PATH_MAX];
        snprintf(devpath, sizeof(devpath),
                 "/devices/virtual/input/%s", devname);
        send_udev_event("remove", devpath, "input", nodepath,
                        maj, min, DEV_CLASS_UNKNOWN);
    }
}

static void create_hidraw_node(const char *devname) {
    unsigned int maj, min;
    if (!read_dev_numbers(SYSFS_HIDRAW, devname, &maj, &min)) {
        DBG("cannot read dev numbers for hidraw %s", devname);
        return;
    }

    char nodepath[PATH_MAX];
    snprintf(nodepath, sizeof(nodepath), DEV_BASE "/%s", devname);

    unlink(nodepath);

    if (mknod(nodepath, S_IFCHR | 0666, makedev(maj, min)) != 0) {
        DBG("mknod %s failed: %s", nodepath, strerror(errno));
        return;
    }
    DBG("created %s (%u:%u)", nodepath, maj, min);

    /* Write udev DB for hidraw */
    write_udev_db(maj, min, DEV_CLASS_HIDRAW);

    /* Send synthetic udev event */
    char devpath[PATH_MAX];
    if (read_devpath(SYSFS_HIDRAW, devname, devpath, sizeof(devpath))) {
        send_udev_event("add", devpath, "hidraw", nodepath,
                        maj, min, DEV_CLASS_HIDRAW);
    }
}

static void remove_hidraw_node(const char *devname) {
    char nodepath[PATH_MAX];
    snprintf(nodepath, sizeof(nodepath), DEV_BASE "/%s", devname);

    struct stat st;
    unsigned int maj = 0, min = 0;
    if (stat(nodepath, &st) == 0) {
        maj = major(st.st_rdev);
        min = minor(st.st_rdev);
    }

    if (unlink(nodepath) == 0)
        DBG("removed %s", nodepath);

    if (maj || min) {
        remove_udev_db(maj, min);
        char devpath[PATH_MAX];
        snprintf(devpath, sizeof(devpath),
                 "/devices/virtual/misc/%s", devname);
        send_udev_event("remove", devpath, "hidraw", nodepath,
                        maj, min, DEV_CLASS_UNKNOWN);
    }
}

/* ── Polling scan ────────────────────────────────────────── */

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
        if (!is_container_input(ent->d_name))
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
                remove_input_node(ent->d_name);
            }
        }
        closedir(d);
    }

    return count;
}

static int poll_and_sync_hidraw(void) {
    int count = 0;

    DIR *d = opendir(SYSFS_HIDRAW);
    if (!d)
        return 0; /* hidraw sysfs may not exist if no HID devices */

    struct dirent *ent;
    while ((ent = readdir(d))) {
        if (!is_hidraw_device(ent->d_name))
            continue;
        if (!is_container_hidraw(ent->d_name))
            continue;

        count++;

        char nodepath[PATH_MAX];
        snprintf(nodepath, sizeof(nodepath), DEV_BASE "/%s", ent->d_name);
        struct stat st;
        if (stat(nodepath, &st) == 0)
            continue;

        DBG("new container hidraw: %s", ent->d_name);
        create_hidraw_node(ent->d_name);
    }
    closedir(d);

    /* Remove stale hidraw nodes — scan /dev for hidraw* and check sysfs */
    d = opendir(DEV_BASE);
    if (d) {
        while ((ent = readdir(d))) {
            if (!is_hidraw_device(ent->d_name))
                continue;

            char syspath[PATH_MAX];
            snprintf(syspath, sizeof(syspath),
                     SYSFS_HIDRAW "/%s", ent->d_name);
            struct stat st;
            if (stat(syspath, &st) != 0) {
                DBG("stale hidraw gone: %s", ent->d_name);
                remove_hidraw_node(ent->d_name);
            }
        }
        closedir(d);
    }

    return count;
}

/* ── Main loop ────────────────────────────────────────────── */

int main(void) {
    /* Clear umask so mknod(0666) creates world-readable nodes */
    umask(0);

    const char *dbg = getenv("UINPUT_SHIM_DEBUG");
    debug_enabled = (dbg && dbg[0] == '1');

    INFO("starting — polling %s + %s for %s* devices",
         SYSFS_INPUT, SYSFS_HIDRAW, TAG_PREFIX);

    /* Prepare udev infrastructure */
    ensure_udev_dirs();
    if (init_udev_netlink() < 0)
        ERR("udev netlink init failed — SDL gamepad discovery may not work");

    /* Initial scan */
    int ni = poll_and_sync_input();
    int nh = poll_and_sync_hidraw();
    INFO("initial scan: %d input + %d hidraw container device(s)", ni, nh);

    /* Poll loop */
    for (;;) {
        usleep(POLL_INTERVAL_USEC);
        poll_and_sync_input();
        poll_and_sync_hidraw();
    }

    return 0;
}
