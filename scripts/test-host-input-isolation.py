#!/usr/bin/env python3
"""Host-side isolation test for container-tagged virtual input devices.

Creates "Isotest Tagged <Kind>" (phys container-isotest: must stay hidden from
the host desktop and host SDL) and "Isotest Control <Kind>" (phys
isotest-control: must stay visible) with uinput, emits events, and checks
libinput seat0 and SDL3 for each device.

Run as a normal user (no sudo); needs write access to /dev/uinput:

    python3 -I scripts/test-host-input-isolation.py [seconds]

Exits 0 on PASS, 1 on FAIL.
"""
import ctypes
import fcntl
import glob
import os
import pwd
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time

from evdev import AbsInfo, UInput, ecodes as e

UDEV_WAIT = 3.0    # seconds for udev to process the new nodes
RUN_SECS = 6.0     # default emission / observation window
HIDE_DIR = "/dev/gamehub-input"
TAGS = {"Tagged": "container-isotest", "Control": "isotest-control"}


def kbd_caps():
    return {e.EV_KEY: list(range(e.KEY_ESC, e.KEY_KPDOT + 1))}, []


def mouse_caps():
    return {e.EV_KEY: [e.BTN_LEFT, e.BTN_RIGHT, e.BTN_MIDDLE],
            e.EV_REL: [e.REL_X, e.REL_Y, e.REL_WHEEL]}, []


def touch_caps():
    x, y = AbsInfo(0, 0, 1920, 0, 0, 10), AbsInfo(0, 0, 1080, 0, 0, 10)
    return {e.EV_KEY: [e.BTN_TOUCH],
            e.EV_ABS: [(e.ABS_X, x), (e.ABS_Y, y),
                       (e.ABS_MT_SLOT, AbsInfo(0, 0, 9, 0, 0, 0)),
                       (e.ABS_MT_TRACKING_ID, AbsInfo(0, 0, 65535, 0, 0, 0)),
                       (e.ABS_MT_POSITION_X, x), (e.ABS_MT_POSITION_Y, y)]}, [e.INPUT_PROP_DIRECT]


def pad_caps():
    stick = AbsInfo(0, -32767, 32767, 16, 128, 0)
    trig = AbsInfo(0, 0, 255, 0, 0, 0)
    hat = AbsInfo(0, -1, 1, 0, 0, 0)
    keys = [e.BTN_SOUTH, e.BTN_EAST, e.BTN_NORTH, e.BTN_WEST, e.BTN_TL, e.BTN_TR,
            e.BTN_SELECT, e.BTN_START, e.BTN_MODE, e.BTN_THUMBL, e.BTN_THUMBR]
    return {e.EV_KEY: keys,
            e.EV_ABS: [(e.ABS_X, stick), (e.ABS_Y, stick), (e.ABS_RX, stick), (e.ABS_RY, stick),
                       (e.ABS_Z, trig), (e.ABS_RZ, trig), (e.ABS_HAT0X, hat), (e.ABS_HAT0Y, hat)]}, []


KINDS = {"Kbd": kbd_caps, "Mouse": mouse_caps, "Touch": touch_caps, "Pad": pad_caps}


class Sdl:
    """Minimal SDL3 joystick probe via ctypes."""

    def __init__(self):
        s = self.lib = ctypes.CDLL("libSDL3.so.0")  # OSError if missing
        s.SDL_Init.argtypes = [ctypes.c_uint32]
        s.SDL_Init.restype = ctypes.c_bool
        s.SDL_GetJoysticks.argtypes = [ctypes.POINTER(ctypes.c_int)]
        s.SDL_GetJoysticks.restype = ctypes.POINTER(ctypes.c_uint32)
        for fn in (s.SDL_GetJoystickNameForID, s.SDL_GetJoystickPathForID):
            fn.argtypes = [ctypes.c_uint32]
            fn.restype = ctypes.c_char_p
        s.SDL_IsGamepad.argtypes = [ctypes.c_uint32]
        s.SDL_IsGamepad.restype = ctypes.c_bool
        s.SDL_OpenJoystick.argtypes = [ctypes.c_uint32]
        s.SDL_OpenJoystick.restype = ctypes.c_void_p
        s.SDL_GetJoystickButton.argtypes = [ctypes.c_void_p, ctypes.c_int]
        s.SDL_GetJoystickButton.restype = ctypes.c_bool
        s.SDL_GetJoystickAxis.argtypes = [ctypes.c_void_p, ctypes.c_int]
        s.SDL_GetJoystickAxis.restype = ctypes.c_int16
        s.SDL_GetError.restype = ctypes.c_char_p
        if not s.SDL_Init(0x200 | 0x2000):  # SDL_INIT_JOYSTICK | SDL_INIT_GAMEPAD
            raise OSError((s.SDL_GetError() or b"SDL_Init failed").decode())
        self.joys = {}

    def poll(self):
        s = self.lib
        s.SDL_PumpEvents()
        s.SDL_UpdateJoysticks()
        n = ctypes.c_int(0)
        ids = s.SDL_GetJoysticks(ctypes.byref(n))
        for i in range(n.value):
            jid = ids[i]
            if jid not in self.joys:
                self.joys[jid] = {
                    "name": (s.SDL_GetJoystickNameForID(jid) or b"").decode(),
                    "path": (s.SDL_GetJoystickPathForID(jid) or b"").decode(),
                    "gamepad": bool(s.SDL_IsGamepad(jid)),
                    "handle": s.SDL_OpenJoystick(jid),
                    "samples": set()}
            j = self.joys[jid]
            if j["handle"]:
                j["samples"].add((s.SDL_GetJoystickButton(j["handle"], 0),
                                  s.SDL_GetJoystickAxis(j["handle"], 0)))

    def devices(self):
        return list(self.joys.values())


def create(devs):
    for kind, caps_fn in KINDS.items():
        caps, props = caps_fn()
        extra = (dict(vendor=0x045E, product=0x028E, version=0x110, bustype=e.BUS_USB)
                 if kind == "Pad" else {})  # Xbox 360 IDs so SDL treats it as a pad
        for tag, phys in TAGS.items():
            devs[(tag, kind)] = UInput(caps, name=f"Isotest {tag} {kind}", phys=phys,
                                       input_props=props, **extra)


def emit(devs, secs, sdl):
    end = time.time() + secs
    x = 0
    while time.time() < end:
        x ^= 1
        for (tag, kind), u in devs.items():
            if kind == "Kbd":
                u.write(e.EV_KEY, e.KEY_F13, 1); u.syn()
                u.write(e.EV_KEY, e.KEY_F13, 0); u.syn()
            elif kind == "Mouse":
                u.write(e.EV_REL, e.REL_X, 1 if x else -1); u.syn()
            elif kind == "Touch":
                u.write(e.EV_ABS, e.ABS_MT_SLOT, 0)
                u.write(e.EV_ABS, e.ABS_MT_TRACKING_ID, 1 if x else -1)
                u.write(e.EV_ABS, e.ABS_MT_POSITION_X, 100)
                u.write(e.EV_ABS, e.ABS_MT_POSITION_Y, 100)
                u.write(e.EV_KEY, e.BTN_TOUCH, x)
                u.write(e.EV_ABS, e.ABS_X, 100)
                u.write(e.EV_ABS, e.ABS_Y, 100)
                u.syn()
            else:
                u.write(e.EV_KEY, e.BTN_SOUTH, x)
                u.write(e.EV_ABS, e.ABS_X, 20000 if x else 0)
                u.syn()
        for _ in range(10):  # sample SDL while waiting for the next 0.25s tick
            if sdl:
                sdl.poll()
            time.sleep(0.025)


def start_libinput():
    if not shutil.which("libinput"):
        print("WARN: libinput not found, skipping seat0 check")
        return None, None
    cmd = ["libinput", "debug-events", "--udev", "seat0"]
    if shutil.which("stdbuf"):
        cmd = ["stdbuf", "-oL"] + cmd
    fd, path = tempfile.mkstemp(prefix="isotest-li-")
    proc = subprocess.Popen(cmd, stdout=fd, stderr=subprocess.STDOUT)
    os.close(fd)
    return proc, path


def parse_libinput(path):
    """Return (set of eventN reported as DEVICE_ADDED, {eventN: event line count})."""
    added, counts = set(), {}
    with open(path, errors="replace") as f:
        for line in f:
            m = re.search(r"event(\d+) +([A-Z_]+)", line)
            if not m:
                continue
            ev, kind = m.group(1), m.group(2)
            if kind == "DEVICE_ADDED":
                added.add(ev)
            elif not kind.startswith("DEVICE_"):
                counts[ev] = counts.get(ev, 0) + 1
    return added, counts


def owner(st):
    try:
        user = pwd.getpwuid(st.st_uid).pw_name
    except KeyError:
        user = str(st.st_uid)
    return f"{user} {stat.S_IMODE(st.st_mode):04o}"


def node_state(path):
    try:
        return f"present ({owner(os.stat(path))})"
    except FileNotFoundError:
        return "absent"
    except PermissionError:
        return "hidden (EACCES)"
    except OSError as ex:
        return f"error ({ex.strerror})"


def udev_props(name):
    if not shutil.which("udevadm"):
        return {}
    devpath = os.path.realpath(f"/sys/class/input/{name}")[len("/sys"):]
    out = subprocess.run(["udevadm", "info", "-q", "property", "-p", devpath],
                         capture_output=True, text=True).stdout
    return dict(line.split("=", 1) for line in out.splitlines() if "=" in line)


def label_of(path, names, devs):
    """Map an evdev path reported by SDL back to its Isotest device label."""
    for (tag, kind), name in names.items():
        if os.path.basename(path) == name:
            return f"Isotest {tag} {kind}"
    return "unknown"


def event_name(u):
    """eventN for a UInput device, via sysfs (UI_GET_SYSNAME).

    u.device is None for tagged devices once the host hides their node, because
    python-evdev looks the device up under /dev/input.
    """
    buf = bytearray(64)
    fcntl.ioctl(u.fd, (2 << 30) | (len(buf) << 16) | (ord("U") << 8) | 44, buf)  # UI_GET_SYSNAME
    sysname = buf.split(b"\0", 1)[0].decode()
    events = glob.glob(f"/sys/devices/virtual/input/{sysname}/event*")
    return os.path.basename(events[0])


def run(devs, secs):
    names = {k: event_name(u) for k, u in devs.items()}  # eventN
    try:
        sdl = Sdl()
    except (OSError, AttributeError) as ex:
        print(f"WARN: SDL3 unavailable, skipping joystick check ({ex})")
        sdl = None

    proc, log = start_libinput()
    try:
        emit(devs, secs, sdl)
    finally:
        if proc:
            proc.terminate()
            proc.wait()
    li = parse_libinput(log) if log else None
    if log:
        os.unlink(log)

    print("== Device nodes ==")
    for (tag, kind), name in names.items():
        props = udev_props(name)
        devnode = props.get("DEVNAME", f"/dev/input/{name}")
        udev = " ".join(f"{k}={props[k]}" for k in sorted(props)
                        if k in ("ID_SEAT", "LIBINPUT_IGNORE_DEVICE") or k.startswith("ID_INPUT"))
        print(f"{tag} {kind} ({name})")
        print(f"    original: {node_state(devnode)}")
        print(f"    hidden:   {node_state(f'{HIDE_DIR}/{name}')}")
        print(f"    udev:     {udev or '(none)'}")

    print("== libinput seat0 ==")
    if li is None:
        print("  skipped")
    else:
        for (tag, kind), name in names.items():
            num = name[len("event"):]
            print(f"  Isotest {tag} {kind}: added={num in li[0]} events={li[1].get(num, 0)}")

    print("== SDL3 joysticks ==")
    sdl_devs = sdl.devices() if sdl else None
    if sdl_devs is None:
        print("  skipped")
    elif not sdl_devs:
        print("  none")
    for d in sdl_devs or []:
        print(f"  {d['path']} ({d['name']!r}) -> {label_of(d['path'], names, devs)} "
              f"gamepad={d['gamepad']} state-changes={len(d['samples']) > 1}")
    sdl_nodes = {os.path.basename(d["path"]) for d in sdl_devs or []}

    print("== Checks ==")
    results = []
    for (tag, kind), name in names.items():
        label = f"Isotest {tag} {kind}"
        num = name[len("event"):]
        if tag == "Tagged":
            if li is not None:
                results.append((num not in li[0], f"{label} absent from libinput seat0"))
            if sdl_devs is not None:
                results.append((name not in sdl_nodes, f"{label} absent from SDL"))
        elif kind == "Pad":
            if sdl_devs is not None:
                results.append((name in sdl_nodes, f"{label} visible to SDL"))
        elif li is not None:
            results.append((num in li[0], f"{label} visible to libinput seat0"))
    for ok, msg in results:
        print(f"  {'PASS' if ok else 'FAIL'}  {msg}")

    passed = bool(results) and all(ok for ok, _ in results)
    print(f"RESULT: {'PASS' if passed else 'FAIL'}" +
          ("" if results else " (no checks could run)"))
    return 0 if passed else 1


def main():
    secs = float(sys.argv[1]) if len(sys.argv) > 1 else RUN_SECS
    devs = {}
    try:
        try:
            create(devs)
        except PermissionError:
            print("FAIL: cannot open /dev/uinput (needs write access)")
            return 1
        time.sleep(UDEV_WAIT)
        return run(devs, secs)
    finally:
        for u in devs.values():
            u.close()


if __name__ == "__main__":
    sys.exit(main())
