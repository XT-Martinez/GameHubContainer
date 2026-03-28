# Sunshine + Gamescope Container

A containerized game streaming setup that runs a custom **Sunshine** streaming server, a custom **Gamescope** compositor, and **Steam** in a single container — with full input isolation between multiple instances.

## Goals

1. **Zero-root streaming**: Use Wayland-native gamescope scanout capture instead of KMS/DRM, eliminating the need for `CAP_SYS_ADMIN` or root access for screen capture.
2. **Multi-instance isolation**: Run multiple Sunshine+Gamescope+Steam containers on the same host without input devices leaking between them or to the host desktop.
3. **SteamOS compatibility**: Use Valve's patched Mesa and PipeWire from Bazzite COPRs for gamescope-optimized rendering (HDR, framerate control).
4. **No application modifications**: The uinput shim and mknod daemon work transparently — no changes needed to Sunshine, Steam, or any other application.

## Components

### Custom Gamescope

A fork of [gamescope](https://github.com/ValveSoftware/gamescope) (Valve's micro-compositor) with an added **Wayland protocol for zero-overhead screen capture**.

Standard Sunshine capture on Wayland uses PipeWire, which forces gamescope to re-composite every frame into a PipeWire buffer — adding 13-21% GPU overhead. Our custom gamescope adds a `gamescope_scanout` Wayland protocol that exports its composited scanout buffer directly as DMA-BUF file descriptors. Sunshine connects to this protocol and reads the frames with zero copy, matching the performance of root-requiring KMS capture (~44% GPU) without needing any elevated privileges.

**Key changes:**
- New Wayland protocol: `gamescope-scanout.xml`
- Server-side implementation in `wlserver.cpp`: per-client rate limiting, commit-skip, HDR metadata, triple-buffer safety
- Integration hook in `steamcompmgr.cpp`: event-driven frame export after each paint cycle

### Custom Sunshine

A fork of [Sunshine](https://github.com/LizardByte/Sunshine) (self-hosted game streaming server) with a **gamescope scanout capture backend**.

Instead of going through PipeWire or requiring DRM access, this Sunshine build connects directly to gamescope's Wayland compositor and uses the `gamescope_scanout` protocol to receive frames. The capture backend maintains a persistent Wayland connection that survives display reinit cycles (HDR toggling, resolution changes), avoiding the ~400ms reconnection penalty.

**Key changes:**
- New capture backend: `gamescopegrab.cpp` (~575 lines)
- Persistent Wayland connection singleton that survives display reinit
- Event-driven capture with per-frame HDR metadata
- Priority in capture method selection: NvFBC > **Gamescope** > Wayland > KMS > X11

### Input Isolation (Shim + Daemon)

Container input isolation is handled by two cooperating components:

#### uinput Tagging Shim (`libuinput_shim.so`)

An `LD_PRELOAD` library that **tags** every virtual input device created inside the container with a container identifier.

When a process creates a virtual input device via `/dev/uinput` or `/dev/uhid`, the device appears globally in the kernel's input subsystem — visible to the host and other containers. The shim solves this by intercepting libc calls (`open`, `ioctl`, `write`) and overriding the `phys` field on every device with `container-<CONTAINER_ID>`.

This works for:
- **uinput devices** (mouse, keyboard, gamepads via Inputtino and Steam Input): the shim intercepts `UI_SET_PHYS` and `UI_DEV_CREATE` ioctls
- **UHID devices** (PS5 DualSense): the shim intercepts `write()` calls with `UHID_CREATE2` events and rewrites the `phys` field

The shim is purely a tagger — it does not create device nodes or touch the filesystem.

#### Input Device Node Daemon (`input-mknod-daemon`)

A lightweight sidecar daemon that **creates device nodes** and **populates the udev database** for container-tagged devices. It handles three responsibilities:

1. **Device node creation**: Polls `/sys/class/input/` and `/sys/class/hidraw/` every 500ms. For devices whose `phys` starts with `container-`, creates `/dev/input/eventN`, `/dev/input/jsN`, and `/dev/hidrawN` nodes with 0666 permissions.

2. **Fake udev database**: Writes `/run/udev/data/cMAJ:MIN` entries with device type properties (`ID_INPUT_JOYSTICK=1`, `ID_INPUT_KEYBOARD=1`, etc.). This allows libudev consumers (SDL/Steam) to discover devices without running udevd. Device type is determined via `ioctl(EVIOCGBIT)` capability detection.

3. **Synthetic udev events**: Sends netlink messages on `NETLINK_KOBJECT_UEVENT` group 2 (the udev multicast group) with the `libudev\0` + `0xfeedcafe` header format. This triggers SDL's `udev_monitor` to pick up device hotplug events in real-time. Also creates `/run/udev/control` to signal "udev is present" to libudev.

> **Why polling instead of inotify?** sysfs does not generate inotify `IN_CREATE`/`IN_DELETE` events. The daemon originally used inotify but it silently blocked forever. Polling at 500ms provides reliable detection with negligible CPU overhead.

> **Why fake udev instead of running udevd?** A real udevd would create device nodes for ALL host devices visible in `/sys`, breaking container isolation. The daemon only creates nodes for `container-*` devices while still populating the udev database that SDL needs for gamepad discovery.

This split design solves the **UHID async problem**: when Inputtino creates a PS5 DualSense via UHID, the kernel's `hid-playstation` driver creates child input devices asynchronously (main controller, motion sensor, touchpad). The shim can't mknod these because they don't exist yet at `write()` time. The daemon catches them on the next poll cycle.

The daemon also:
- **Scans existing devices at startup** in case it starts after some devices are already created
- **Removes stale nodes** when devices are deleted from sysfs (two-pass scan/cleanup)
- **Sends remove events** to notify SDL when devices are unplugged
- **Classifies device types** via evdev capability bits (keyboard, mouse, joystick, touch, accelerometer, hidraw)

**How host Steam is distinguished from container Steam**: Both create devices named "Steam Virtual Gamepad". The shim rewrites the `phys` field on ALL uinput devices created inside the container, regardless of which application creates them. Host Steam's devices have a different `phys`, so the host udev rule doesn't match them.

### Resolution and Refresh Rate

Gamescope's headless backend does not support dynamic resolution changes (xrandr and wlr-randr mode switching are ignored). Instead, the output resolution is set at container startup via environment variables:

- `SCREEN_WIDTH` (default: 1920) — gamescope output width
- `SCREEN_HEIGHT` (default: 1080) — gamescope output height
- `CUSTOM_REFRESH_RATES` (default: 60,90,120) — available refresh rates

To stream at a different resolution, restart the container with different values (e.g., `-e SCREEN_WIDTH=2560 -e SCREEN_HEIGHT=1440`).

## Prerequisites

### Host Setup (required once)

#### 1. Install the udev rule

This rule does two things:
1. Prevents the host desktop from consuming virtual input devices created by containers
2. Sets `/dev/uinput` and `/dev/uhid` to world-writable (needed for container access)

```bash
sudo cp container-input-shim/99-sunshine-container-ignore.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules
sudo udevadm trigger
```

**What this does**:
- `/dev/uinput` and `/dev/uhid` set to `MODE="0666"` — allows the container's non-root user to create virtual input devices
- Any input device with `phys` matching `container-*` gets `LIBINPUT_IGNORE_DEVICE=1` — libinput (and thus your desktop compositor) ignores it
- Container-tagged devices also get `ID_INPUT=""` — systemd-logind and other consumers don't treat them as host input

#### 2. Add your user to the `input` group

Required for `/dev/uinput` access (even in rootless containers):

```bash
sudo usermod -aG input $USER
# Log out and back in for the group change to take effect
```

#### 3. GPU access

Your user needs access to `/dev/dri/` devices (typically via the `video` and `render` groups):

```bash
sudo usermod -aG video,render $USER
```

## Building

### Build the image

```bash
podman build -t gamehub-container .
```

This is a multi-stage build:
1. **gamescope-builder**: Compiles custom gamescope with Meson (~5 min)
2. **sunshine-builder**: Compiles custom Sunshine with CMake, fetches Boost/FFmpeg via FetchContent (~10 min)
3. **shim-builder**: Compiles the uinput tagging shim and mknod daemon (~5 sec)
4. **runtime**: Fedora 43 with Valve's Mesa/PipeWire from Bazzite COPRs, Steam, and the built binaries

Subsequent builds are faster due to Docker layer caching.

## Running

### Single instance

```bash
# Check your hidraw major number: grep hidraw /proc/devices (commonly 241-243)
HIDRAW_MAJOR=$(grep hidraw /proc/devices | awk '{print $1}')

sudo podman run -d \
    --name sunshine \
    --systemd=true \
    --shm-size=1g \
    --cap-add SYS_ADMIN \
    --cap-add MKNOD \
    --cap-add NET_ADMIN \
    --device /dev/dri \
    --device /dev/uinput \
    --device-cgroup-rule='c 13:* rmw' \
    --device-cgroup-rule="c ${HIDRAW_MAJOR}:* rmw" \
    --tmpfs /dev/input:rw,dev,nosuid,size=1m \
    -v /sys:/sys:ro \
    -v sunshine-steam:/home/gamer/.steam \
    -v sunshine-local:/home/gamer/.local/share/Steam \
    -v sunshine-config:/home/gamer/.config/sunshine \
    -e CONTAINER_ID=sunshine-1 \
    -e SCREEN_WIDTH=1920 \
    -e SCREEN_HEIGHT=1080 \
    --network=host \
    --security-opt label=disable \
    gamehub-container:latest
```

### Multiple instances

Each instance needs a unique `CONTAINER_ID`, unique Sunshine port range, and separate storage volumes.

**Important**: Sunshine's internal ports must match the external ports. Use the `SUNSHINE_PORT` environment variable to set the base port (e.g., `-e SUNSHINE_PORT=57989`). Sunshine derives all other ports from this base (HTTP = port - 5, RTSP = port + 21, etc.). Use 1:1 port mapping so Moonlight can reach all ports correctly during pairing.

```bash
# Instance 1 — default ports (47984-48010)
sudo podman run -d --name sunshine-1 \
    --systemd=true \
    --shm-size=1g \
    --cap-add SYS_ADMIN --cap-add MKNOD --cap-add NET_ADMIN \
    --device /dev/dri --device /dev/uinput \
    --device-cgroup-rule='c 13:* rmw' \
    --device-cgroup-rule="c ${HIDRAW_MAJOR}:* rmw" \
    --tmpfs /dev/input:rw,dev,nosuid,size=1m \
    -v /sys:/sys:ro \
    -v s1-steam:/home/gamer/.steam \
    -v s1-local:/home/gamer/.local/share/Steam \
    -v s1-config:/home/gamer/.config/sunshine \
    -e CONTAINER_ID=sunshine-1 \
    -e SCREEN_WIDTH=1920 \
    -e SCREEN_HEIGHT=1080 \
    --network=host \
    --security-opt label=disable \
    gamehub-container:latest

# Instance 2 — port range 57984-58010
# SUNSHINE_PORT sets the base port via command line (no need to edit sunshine.conf)
sudo podman run -d --name sunshine-2 \
    --systemd=true \
    --shm-size=1g \
    --cap-add SYS_ADMIN --cap-add MKNOD --cap-add NET_ADMIN \
    --device /dev/dri --device /dev/uinput \
    --device-cgroup-rule='c 13:* rmw' \
    --device-cgroup-rule="c ${HIDRAW_MAJOR}:* rmw" \
    --tmpfs /dev/input:rw,dev,nosuid,size=1m \
    -v /sys:/sys:ro \
    -v s2-steam:/home/gamer/.steam \
    -v s2-local:/home/gamer/.local/share/Steam \
    -v s2-config:/home/gamer/.config/sunshine \
    -e CONTAINER_ID=sunshine-2 \
    -e SUNSHINE_PORT=57989 \
    -e SCREEN_WIDTH=1920 \
    -e SCREEN_HEIGHT=1080 \
    -p 57984:57984/tcp \
    -p 57989:57989/tcp \
    -p 57990:57990/tcp \
    -p 58010:58010/tcp \
    -p 57998:57998/udp \
    -p 57999:57999/udp \
    -p 58000:58000/udp \
    --security-opt label=disable \
    gamehub-container:latest
```

Each instance has isolated input devices — a gamepad connected to instance 1 is invisible to instance 2.

In Moonlight, add instance 2 as `<host-ip>:57989`.

### Using Compose

```bash
podman compose up -d
podman compose logs -f
```

### First run

1. Wait for Steam to finish bootstrapping (~1-2 minutes). A pre-cached bootstrap archive is included in the image. The gaming session may restart once during initial Steam setup — this is normal.
2. Access the Sunshine web UI at `https://<host-ip>:47990` (or the instance's configured web UI port)
3. Set up a username and password
4. For multi-instance setups: set `SUNSHINE_PORT` env var to match the external port mapping (or set `port` in the Sunshine web UI under Configuration > Network)
5. Pair with Moonlight on your client device

## Rootful vs Rootless Podman

**Rootful podman (`sudo podman run`) is recommended** for multi-instance setups. The input isolation system requires `mknod` to create device nodes in the container's private `/dev/input/` tmpfs, and the Linux kernel blocks `mknod` for character devices in user namespaces — even with `--privileged`.

### What works in rootless mode

| Feature | Rootless | Rootful |
|---|---|---|
| Gamescope scanout capture | Yes | Yes |
| Vulkan/VAAPI encoding | Yes | Yes |
| Steam + Big Picture | Yes | Yes |
| Virtual mouse/keyboard (uinput) | Yes (with host udev rule) | Yes |
| Virtual gamepad (uinput) | Yes (with host udev rule) | Yes |
| PS5 DualSense (UHID) | Yes (with host udev rule) | Yes |
| Input isolation (`/dev/input/` tmpfs) | **No** — `mknod` fails | Yes |
| Multi-instance input isolation | **No** | Yes |

### Rootless single-instance workaround

For a single instance without input isolation, you can run rootless with `--privileged` and WITHOUT the `/dev/input/` tmpfs. All host input devices will be visible inside the container, but the udev rule prevents the host from consuming container-created devices:

```bash
podman run -d \
    --name sunshine \
    --systemd=true \
    --shm-size=1g \
    --privileged \
    --device /dev/dri \
    --device /dev/uinput \
    -v /sys:/sys:ro \
    -e CONTAINER_ID=sunshine-1 \
    -e SCREEN_WIDTH=1920 \
    -e SCREEN_HEIGHT=1080 \
    --network=host \
    --security-opt label=disable \
    gamehub-container:latest
```

`--privileged` in rootless Podman is **not the same as root** — you're still in a user namespace. It relaxes capability and device cgroup restrictions within that namespace.

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│  Container (rootful Podman recommended for multi-instance)    │
│                                                              │
│  LD_PRELOAD=libuinput_shim.so (Sunshine only)                │
│  CONTAINER_ID=sunshine-1                                     │
│                                                              │
│  ┌──────────────┐    Wayland      ┌──────────────────┐      │
│  │   Sunshine    │◄──scanout─────►│    Gamescope      │      │
│  │  (streaming)  │   protocol     │  (compositor)     │      │
│  └──────┬───────┘                └────────┬─────────┘      │
│         │                                 │                  │
│    Vulkan encode                     Vulkan render            │
│         │                                 │                  │
│         ▼                                 ▼                  │
│  ┌──────────────────────────────────────────────────────┐   │
│  │              /dev/dri (GPU passthrough)               │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                              │
│  ┌──────────────┐  ┌───────────┐  ┌────────────────┐       │
│  │  Inputtino   │  │   Steam   │  │  Steam Input   │       │
│  │ (virtual kbd │  │ (Big Pic) │  │ (virtual pads) │       │
│  │  mouse, pad) │  │           │  │                │       │
│  └──────┬───────┘  └───────────┘  └───────┬────────┘       │
│         │ uinput ioctl                     │ uinput         │
│         ▼                                  ▼                │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  libuinput_shim.so (LD_PRELOAD)                      │   │
│  │  Tags phys="container-sunshine-1" on all devices      │   │
│  │  (uinput via ioctl, UHID via write)                   │   │
│  └──────────────────────────────────────────────────────┘   │
│         │ devices appear in kernel                           │
│         ▼                                                    │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  input-mknod-daemon (sidecar, polling 500ms)         │   │
│  │  Polls /sys/class/input/ + /sys/class/hidraw/         │   │
│  │  If phys matches "container-*":                       │   │
│  │    → mknod /dev/input/eventN, jsN, /dev/hidrawN       │   │
│  │    → classify via ioctl(EVIOCGBIT)                    │   │
│  │    → write /run/udev/data/cMAJ:MIN (fake udev DB)    │   │
│  │    → send netlink udev "add" event (0xfeedcafe hdr)   │   │
│  └──────────────────────────────────────────────────────┘   │
│         │                                                    │
│         ├──► /dev/input/ (private tmpfs, only this           │
│         │    container's devices visible)                    │
│         │                                                    │
│         ├──► /run/udev/data/ (fake udev DB for libudev)     │
│         │                                                    │
│         ▼                                                    │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  Gamescope headless libinput (path-based, no udev)   │   │
│  │  Reads mouse, keyboard, touch from /dev/input/        │   │
│  └──────────────────────────────────────────────────────┘   │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  Steam/SDL (reads /run/udev/data/ via libudev)        │   │
│  │  Discovers gamepads, hidraw (DualSense) devices       │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                              │
└──────────────────────────────────────────────────────────────┘

Host kernel: device appears globally but tagged with
             phys="container-sunshine-1"

Host udev:   ATTR{phys}=="container-*" →
             ENV{ID_SEAT}="seat9", LIBINPUT_IGNORE_DEVICE=1
             (devices hidden on non-existent seat, host unaffected)
```

## Known Limitations

- **Rootless podman + input isolation**: The kernel blocks `mknod` for character devices in user namespaces. The `input-mknod-daemon` cannot create `/dev/input/` device nodes in rootless mode. Use rootful podman (`sudo podman run`) for multi-instance input isolation.
- **No dynamic resolution**: Gamescope's headless backend does not support resolution changes after startup (xrandr and wlr-randr mode switching are ignored). Set `SCREEN_WIDTH`/`SCREEN_HEIGHT` at container start.
- **Port mapping and pairing**: Sunshine's internal ports must match external ports for Moonlight pairing to work. Use 1:1 port mapping (e.g., `-p 57989:57989`) and set `port = <HTTPS_PORT>` in sunshine.conf. NAT-style mapping (e.g., `57989:47989`) causes "certificate mismatch" errors during pairing.
- **Steam startup**: Steam in SteamOS mode may restart once during initial setup (~1-2 min). SteamOS compatibility stubs are included to prevent extended crash loops, but the first session restart is normal.
- **Gamepad/hidraw hotplug**: The mknod daemon creates fake udev DB entries and sends synthetic netlink events (MurmurHash2 subsystem filter + `USEC_INITIALIZED`) for SDL/Steam gamepad discovery. Requires `CAP_NET_ADMIN` for the netlink socket.
- **DualSense (DS5) detection**: DS5 mode requires the Moonlight client to advertise motion controls or manual `gamepad = ds5` in sunshine.conf. The `hid-playstation` kernel module must be loaded on the host. The hidraw device for DS5 is only created if the UHID phys is properly tagged by the shim.
- **tmpfs /dev/input/ requires `dev` flag**: The `--tmpfs /dev/input:rw,dev,...` mount must include `dev` explicitly. Without it, podman defaults to `nodev` which blocks all character device access on the tmpfs, even with correct file permissions.
- **dup()/dup2() tracking**: If a process duplicates a uinput file descriptor, the shim loses tracking of the new fd. The mknod daemon still picks up the device via polling, but the `phys` field won't be tagged. This is uncommon in practice.
- **Networking for multiple instances**: With `--network=host`, all instances share the host network. For multiple instances, use `SUNSHINE_PORT` env var and bridge networking with explicit 1:1 port mapping.
- **Fedora version**: The Bazzite COPRs (Valve Mesa, PipeWire) target specific Fedora versions. If the COPR doesn't have builds for your Fedora version, the package installation will fail. Check COPR availability before changing `FEDORA_VERSION`.
- **NVENC**: The NVENC encoder code is patched at build time to compile against newer nv-codec-headers. This is a no-op on AMD GPUs (NVENC runtime detection gracefully fails without an NVIDIA GPU).
