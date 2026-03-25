/*
 * uinput_shim.c — LD_PRELOAD shim for container input device tagging
 *
 * Tags all uinput/UHID devices with a container identifier by overriding
 * the `phys` field.  Device node creation (/dev/input/) is handled
 * separately by the input-mknod daemon (inotify-based sidecar).
 *
 * Environment variables:
 *   CONTAINER_ID        - identifier embedded in device phys field (default: "default")
 *   UINPUT_SHIM_DEBUG   - set to "1" for verbose logging to stderr
 *
 * Build:  gcc -shared -fPIC -o libuinput_shim.so uinput_shim.c -ldl
 * Usage:  LD_PRELOAD=/usr/lib/libuinput_shim.so CONTAINER_ID=abc123 <program>
 *
 * Known limitations:
 *   - dup()/dup2()/fcntl(F_DUPFD) on uinput/uhid fds are not tracked
 *   - MAX_FDS is fixed at 4096; fds beyond that are not intercepted
 */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/uhid.h>
#include <linux/uinput.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* ── Configuration ─────────────────────────────────────────── */

#define MAX_FDS   4096
#define PHYS_MAX  256
#define TAG_PREFIX "container-"

/* ── State ─────────────────────────────────────────────────── */

static char phys_tag[PHYS_MAX];
static int  debug_enabled;

enum fd_kind { FD_NONE = 0, FD_UINPUT, FD_UHID };

static enum fd_kind fd_type[MAX_FDS];
static _Bool        phys_done[MAX_FDS];

/* ── Real libc pointers ────────────────────────────────────── */

static int     (*real_open)(const char *, int, ...);
static int     (*real_openat)(int, const char *, int, ...);
static int     (*real_close)(int);
static int     (*real_ioctl)(int, unsigned long, ...);
static ssize_t (*real_write)(int, const void *, size_t);

/* ── Logging ───────────────────────────────────────────────── */

#define DBG(fmt, ...) do {                                          \
    if (debug_enabled)                                              \
        fprintf(stderr, "[uinput-shim] " fmt "\n", ##__VA_ARGS__); \
} while (0)

/* ── Constructor ───────────────────────────────────────────── */

__attribute__((constructor))
static void shim_init(void) {
    real_open   = dlsym(RTLD_NEXT, "open");
    real_openat = dlsym(RTLD_NEXT, "openat");
    real_close  = dlsym(RTLD_NEXT, "close");
    real_ioctl  = dlsym(RTLD_NEXT, "ioctl");
    real_write  = dlsym(RTLD_NEXT, "write");

    const char *id = getenv("CONTAINER_ID");
    if (!id || !*id)
        id = "default";
    snprintf(phys_tag, sizeof(phys_tag), TAG_PREFIX "%s", id);

    const char *dbg = getenv("UINPUT_SHIM_DEBUG");
    debug_enabled = (dbg && dbg[0] == '1');

    DBG("initialized — phys_tag=\"%s\"", phys_tag);
}

/* ── Helpers ───────────────────────────────────────────────── */

static void track_open(int fd, const char *path) {
    if (fd < 0 || fd >= MAX_FDS || !path)
        return;

    if (strcmp(path, "/dev/uinput") == 0) {
        fd_type[fd]   = FD_UINPUT;
        phys_done[fd] = 0;
        DBG("tracking fd %d as uinput", fd);
    } else if (strcmp(path, "/dev/uhid") == 0) {
        fd_type[fd]   = FD_UHID;
        phys_done[fd] = 0;
        DBG("tracking fd %d as uhid", fd);
    }
}

/* ── Hooked: open / openat / close ─────────────────────────── */

int open(const char *path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = va_arg(ap, mode_t);
        va_end(ap);
    }
    int fd = real_open(path, flags, mode);
    track_open(fd, path);
    return fd;
}

int open64(const char *path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = va_arg(ap, mode_t);
        va_end(ap);
    }
    int fd = real_open(path, flags, mode);
    track_open(fd, path);
    return fd;
}

int openat(int dirfd, const char *path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = va_arg(ap, mode_t);
        va_end(ap);
    }
    int fd = real_openat(dirfd, path, flags, mode);
    track_open(fd, path);
    return fd;
}

int openat64(int dirfd, const char *path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = va_arg(ap, mode_t);
        va_end(ap);
    }
    int fd = real_openat(dirfd, path, flags, mode);
    track_open(fd, path);
    return fd;
}

int close(int fd) {
    if (fd >= 0 && fd < MAX_FDS && fd_type[fd] != FD_NONE) {
        DBG("closing tracked fd %d", fd);
        fd_type[fd]   = FD_NONE;
        phys_done[fd] = 0;
    }
    return real_close(fd);
}

/* ── Hooked: ioctl (uinput phys tagging) ──────────────────── */

int ioctl(int fd, unsigned long request, ...) {
    va_list ap;
    va_start(ap, request);
    void *arg = va_arg(ap, void *);
    va_end(ap);

    /* Pass through anything that isn't a tracked uinput fd */
    if (fd < 0 || fd >= MAX_FDS || fd_type[fd] != FD_UINPUT)
        return real_ioctl(fd, request, arg);

    /* Override any phys the application tries to set */
    if (request == UI_SET_PHYS) {
        DBG("overriding UI_SET_PHYS on fd %d (app wanted \"%s\")",
            fd, arg ? (const char *)arg : "(null)");
        phys_done[fd] = 1;
        return real_ioctl(fd, UI_SET_PHYS, phys_tag);
    }

    /* Before device creation, inject phys if not already set */
    if (request == UI_DEV_CREATE) {
        if (!phys_done[fd]) {
            DBG("injecting UI_SET_PHYS before UI_DEV_CREATE on fd %d", fd);
            real_ioctl(fd, UI_SET_PHYS, phys_tag);
            phys_done[fd] = 1;
        }
        /* Device node creation handled by input-mknod daemon */
        return real_ioctl(fd, request, arg);
    }

    return real_ioctl(fd, request, arg);
}

/* ── Hooked: write (UHID phys tagging) ────────────────────── */

ssize_t write(int fd, const void *buf, size_t count) {
    if (fd < 0 || fd >= MAX_FDS || fd_type[fd] != FD_UHID)
        return real_write(fd, buf, count);

    /*
     * UHID events start with a __u32 type field.
     * For UHID_CREATE2, rewrite the phys field with our container tag.
     * The kernel HID driver will propagate this phys to all child
     * input devices, which the input-mknod daemon picks up via inotify.
     */
    if (count >= sizeof(struct uhid_event)) {
        const struct uhid_event *ev = (const struct uhid_event *)buf;

        if (ev->type == UHID_CREATE2) {
            struct uhid_event copy;
            memcpy(&copy, buf, sizeof(copy));
            snprintf((char *)copy.u.create2.phys,
                     sizeof(copy.u.create2.phys),
                     "%s", phys_tag);
            DBG("tagged UHID_CREATE2 phys on fd %d (name=\"%s\")",
                fd, copy.u.create2.name);
            return real_write(fd, &copy, count);
        }
    }

    return real_write(fd, buf, count);
}
