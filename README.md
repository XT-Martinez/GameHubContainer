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

A lightweight sidecar daemon that **creates `/dev/input/` device nodes** for container-tagged devices.

Each container runs with a private `/dev/input/` tmpfs that starts empty. The daemon watches `/sys/class/input/` via inotify and, for every new `eventN` or `jsN` device whose `phys` field starts with `container-`, reads the major:minor numbers from sysfs and calls `mknod` to create the device node in `/dev/input/`.

This split design solves the **UHID async problem**: when Inputtino creates a PS5 DualSense via UHID, the kernel's `hid-playstation` driver creates child input devices asynchronously (main controller, motion sensor, touchpad). The shim can't mknod these because they don't exist yet at `write()` time. The daemon watches for them via inotify and handles them as they appear.

The daemon also:
- **Scans existing devices at startup** in case it starts after some devices are already created
- **Removes stale nodes** when devices are deleted from sysfs
- **Handles all device types uniformly** — uinput, UHID, and any future device creation methods

**How host Steam is distinguished from container Steam**: Both create devices named "Steam Virtual Gamepad". The shim rewrites the `phys` field on ALL uinput devices created inside the container, regardless of which application creates them. Host Steam's devices have a different `phys`, so the host udev rule doesn't match them.

### Resolution Matching

A default Sunshine configuration is included that automatically aligns gamescope's output resolution with the Moonlight client's request. When a stream starts, Sunshine runs `set-resolution.sh` as a prep command, which uses `wlr-randr` to set gamescope's output to the client's requested width, height, and refresh rate via the `SUNSHINE_CLIENT_WIDTH`, `SUNSHINE_CLIENT_HEIGHT`, and `SUNSHINE_CLIENT_FPS` environment variables.

## Prerequisites

### Host Setup (required once)

#### 1. Install the udev rule

This prevents the host desktop from consuming virtual input devices created by containers:

```bash
sudo cp container-input-shim/99-sunshine-container-ignore.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules
sudo udevadm trigger
```

**What this does**: Any input device with `phys` matching `container-*` gets:
- `LIBINPUT_IGNORE_DEVICE=1` — libinput (and thus your desktop compositor) ignores it
- `ID_INPUT=""` — systemd-logind and other consumers don't treat it as host input

**What this does NOT do**: It does not remove the device from the kernel. The device still exists in sysfs and can be opened by processes that know its path. This is by design — the container needs kernel-level devices for Steam/SDL to work.

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
podman run -d \
    --name sunshine \
    --systemd=true \
    --cap-add SYS_ADMIN \
    --cap-add MKNOD \
    --device /dev/dri \
    --device /dev/uinput \
    --device-cgroup-rule='c 13:* rmw' \
    --tmpfs /dev/input:rw,noexec,nosuid,size=1m \
    -v /sys:/sys:ro \
    -v sunshine-steam:/home/gamer/.steam \
    -v sunshine-local:/home/gamer/.local/share/Steam \
    -v sunshine-config:/home/gamer/.config/sunshine \
    -e CONTAINER_ID=sunshine-1 \
    --network=host \
    --security-opt label=disable \
    sunshine-gamescope:latest
```

### Multiple instances

```bash
# Instance 1
podman run -d --name sunshine-1 \
    --systemd=true \
    --cap-add SYS_ADMIN --cap-add MKNOD \
    --device /dev/dri --device /dev/uinput \
    --device-cgroup-rule='c 13:* rmw' \
    --tmpfs /dev/input:rw,noexec,nosuid,size=1m \
    -v /sys:/sys:ro \
    -v s1-steam:/home/gamer/.steam \
    -v s1-local:/home/gamer/.local/share/Steam \
    -v s1-config:/home/gamer/.config/sunshine \
    -e CONTAINER_ID=sunshine-1 \
    --network=host \
    --security-opt label=disable \
    sunshine-gamescope:latest

# Instance 2
podman run -d --name sunshine-2 \
    --systemd=true \
    --cap-add SYS_ADMIN --cap-add MKNOD \
    --device /dev/dri --device /dev/uinput \
    --device-cgroup-rule='c 13:* rmw' \
    --tmpfs /dev/input:rw,noexec,nosuid,size=1m \
    -v /sys:/sys:ro \
    -v s2-steam:/home/gamer/.steam \
    -v s2-local:/home/gamer/.local/share/Steam \
    -v s2-config:/home/gamer/.config/sunshine \
    -e CONTAINER_ID=sunshine-2 \
    -p 57984:47984/tcp \
    -p 57989:47989/tcp \
    -p 57990:47990/tcp \
    -p 58010:48010/tcp \
    -p 57998:47998/udp \
    -p 57999:47999/udp \
    -p 58000:48000/udp \
    --security-opt label=disable \
    sunshine-gamescope:latest
```

Each instance has isolated input devices — a gamepad connected to instance 1 is invisible to instance 2.

### Using Compose

```bash
podman compose up -d
podman compose logs -f
```

### First run

1. Wait for Steam to finish bootstrapping (a pre-cached bootstrap archive is included in the image, so this is mostly local extraction rather than a network download)
2. Access the Sunshine web UI at `https://<host-ip>:47990`
3. Set up a username and password
4. Pair with Moonlight on your client device

## Rootless Podman

This container works with rootless Podman with some caveats:

### mknod in rootless containers

The mknod daemon calls `mknod` to create device nodes in the container's `/dev/input/`. In rootless Podman:

- `mknod` creates the device node file inside the user namespace (this always works)
- **Opening** the device requires the cgroup device controller to allow it
- `--device-cgroup-rule='c 13:* rmw'` grants access to input devices (major 13)

If `mknod` fails with `EPERM`, use `--privileged`:

```bash
podman run --privileged ...
```

`--privileged` in rootless Podman is **not the same as root** — you're still in a user namespace. It relaxes capability and device cgroup restrictions within that namespace, which is sufficient for `mknod` to work.

### Requirements for rootless operation

| Requirement | How to satisfy |
|---|---|
| `/dev/uinput` access | Host user in `input` group |
| `/dev/dri` access | Host user in `video` + `render` groups |
| `mknod` inside container | `--cap-add MKNOD` + `--device-cgroup-rule='c 13:* rmw'` (or `--privileged`) |
| systemd as PID 1 | Podman auto-detects with `--systemd=true` |

### If --privileged is needed

If the minimal capability set doesn't work on your system, `--privileged` is the escape hatch:

```bash
podman run -d \
    --name sunshine \
    --systemd=true \
    --privileged \
    --device /dev/dri \
    --device /dev/uinput \
    --tmpfs /dev/input:rw,noexec,nosuid,size=1m \
    -v /sys:/sys:ro \
    -e CONTAINER_ID=sunshine-1 \
    --network=host \
    sunshine-gamescope:latest
```

This grants all capabilities within the user namespace and disables device cgroup filtering. In rootless mode, this is safe — the container still cannot escape the user namespace boundary.

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│  Container (rootless Podman)                                 │
│                                                              │
│  LD_PRELOAD=libuinput_shim.so                               │
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
│  │  input-mknod-daemon (sidecar, inotify)               │   │
│  │  Watches /sys/class/input/ for new devices            │   │
│  │  If phys matches "container-*":                       │   │
│  │    → reads major:minor from sysfs                     │   │
│  │    → mknod /dev/input/eventN                          │   │
│  │  Handles uinput (sync) + UHID/PS5 (async) uniformly  │   │
│  └──────────────────────────────────────────────────────┘   │
│         │                                                    │
│         ▼                                                    │
│  /dev/input/ (private tmpfs — only this container's          │
│               devices visible here)                          │
│                                                              │
└──────────────────────────────────────────────────────────────┘

Host kernel: device appears globally but tagged with
             phys="container-sunshine-1"

Host udev:   ATTR{phys}=="container-*" →
             LIBINPUT_IGNORE_DEVICE=1, ID_INPUT=""
             (host desktop and host Steam unaffected)
```

## Known Limitations

- **dup()/dup2() tracking**: If a process duplicates a uinput file descriptor, the shim loses tracking of the new fd. The mknod daemon still picks up the device via inotify, but the `phys` field won't be tagged. This is uncommon in practice.
- **Networking for multiple instances**: With `--network=host`, all instances share the host network. Sunshine uses ports 47984-48110 by default. For multiple instances, configure each Sunshine to use different port ranges, or use bridge networking with explicit port mapping.
- **Fedora version**: The Bazzite COPRs (Valve Mesa, PipeWire) target specific Fedora versions. If the COPR doesn't have builds for your Fedora version, the package installation will fail. Check COPR availability before changing `FEDORA_VERSION`.
- **NVENC**: The NVENC encoder code is patched at build time to compile against newer nv-codec-headers. This is a no-op on AMD GPUs (NVENC runtime detection gracefully fails without an NVIDIA GPU).
