# Sunshine + Gamescope Container

A containerized game streaming setup that runs a custom **Sunshine** streaming server, a custom **Gamescope** compositor, and **Steam** in a single container — with full input isolation between multiple instances.

## Goals

1. **Zero-root streaming**: Use Wayland-native gamescope scanout capture instead of KMS/DRM, eliminating the need for `CAP_SYS_ADMIN` or root access for screen capture.
2. **Multi-instance isolation**: Run multiple Sunshine+Gamescope+Steam containers on the same host without input devices leaking between them or to the host desktop.
3. **SteamOS compatibility**: Use Valve's patched Mesa and PipeWire from Bazzite COPRs for gamescope-optimized rendering (HDR, framerate control).
4. **No application modifications**: The uinput shim works transparently via `LD_PRELOAD` — no changes needed to Sunshine, Steam, or any other application.

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

### uinput Isolation Shim (`libuinput_shim.so`)

An `LD_PRELOAD` library that solves the **container input isolation problem**.

When a process inside a container creates a virtual input device via `/dev/uinput`, that device appears globally in the kernel's input subsystem — visible to the host and other containers. This breaks multi-instance setups where each container should have its own isolated set of virtual controllers, keyboards, and mice.

The shim intercepts libc calls (`open`, `ioctl`, `write`) to:

1. **Tag every virtual device** with a container identifier by overriding the `phys` field (e.g., `container-sunshine-1`). This works for both uinput devices (mouse, keyboard, gamepads) and UHID devices (PS5 DualSense).

2. **Auto-create device nodes** in the container's private `/dev/input/` tmpfs. After a uinput device is created, the shim reads sysfs to find the resulting `eventN`/`jsN` devices and calls `mknod` to make them available inside the container.

This means:
- Host udev rules can ignore all `container-*` tagged devices (the host desktop and host Steam are unaffected)
- Each container only sees its own devices in `/dev/input/`
- Steam, SDL, and Inputtino work unmodified — the shim is transparent

**How it distinguishes host Steam from container Steam**: Both create devices named "Steam Virtual Gamepad". The shim rewrites the `phys` field on ALL uinput devices created inside the container, regardless of which application creates them. Host Steam's devices have a different `phys`, so the udev rule doesn't match them.

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

### Repository setup (for a dedicated repo)

```bash
git init sunshine-gamescope-container
cd sunshine-gamescope-container

# Add submodules
git submodule add <your-gamescope-fork-url> gamescope
git submodule add <your-sunshine-fork-url> sunshine

# Copy container files from this directory
cp -r /path/to/sunshine-container/{Dockerfile,docker-compose.yml,container-input-shim,services,scripts} .
```

### Build the image

```bash
podman build -t sunshine-gamescope .
```

This is a multi-stage build:
1. **gamescope-builder**: Compiles custom gamescope with Meson (~5 min)
2. **sunshine-builder**: Compiles custom Sunshine with CMake, fetches Boost/FFmpeg via FetchContent (~10 min)
3. **shim-builder**: Compiles the uinput shim (~5 sec)
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
    --network=host \
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

1. Wait for Steam to finish bootstrapping (first launch downloads ~1.5GB)
2. Access the Sunshine web UI at `https://<host-ip>:47990`
3. Set up a username and password
4. Pair with Moonlight on your client device

## Rootless Podman

This container works with rootless Podman with some caveats:

### mknod in rootless containers

The uinput shim calls `mknod` to create device nodes in the container's `/dev/input/`. In rootless Podman:

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
┌─────────────────────────────────────────────────────────┐
│  Container (rootless Podman)                            │
│                                                         │
│  LD_PRELOAD=libuinput_shim.so                          │
│  CONTAINER_ID=sunshine-1                                │
│                                                         │
│  ┌──────────────┐    Wayland     ┌──────────────────┐  │
│  │   Sunshine    │◄──scanout────►│    Gamescope      │  │
│  │  (streaming)  │   protocol    │  (compositor)     │  │
│  └──────┬───────┘               └────────┬─────────┘  │
│         │                                │             │
│    VAAPI encode                    Vulkan render       │
│         │                                │             │
│         ▼                                ▼             │
│  ┌──────────────────────────────────────────────────┐  │
│  │              /dev/dri (GPU passthrough)           │  │
│  └──────────────────────────────────────────────────┘  │
│                                                         │
│  ┌──────────────┐  ┌───────────┐  ┌────────────────┐  │
│  │  Inputtino   │  │   Steam   │  │  Steam Input   │  │
│  │ (virtual kbd │  │ (Big Pic) │  │ (virtual pads) │  │
│  │  mouse, pad) │  │           │  │                │  │
│  └──────┬───────┘  └───────────┘  └───────┬────────┘  │
│         │ uinput ioctl                     │ uinput    │
│         ▼                                  ▼           │
│  ┌──────────────────────────────────────────────────┐  │
│  │  libuinput_shim.so                               │  │
│  │  • Intercepts UI_SET_PHYS → "container-sunshine-1│" │
│  │  • After UI_DEV_CREATE → mknod /dev/input/eventN │  │
│  └──────────────────────────────────────────────────┘  │
│         │                                              │
│         ▼                                              │
│  /dev/input/ (private tmpfs — only this container's    │
│               devices visible)                         │
│                                                         │
└─────────────────────────────────────────────────────────┘

Host kernel: device appears globally but tagged with
             phys="container-sunshine-1"

Host udev:   ATTR{phys}=="container-*" →
             LIBINPUT_IGNORE_DEVICE=1, ID_INPUT=""
             (host desktop ignores it)
```

## Known Limitations

- **UHID auto-mknod**: PS5 DualSense controllers use UHID, which creates input devices asynchronously via the kernel HID driver. The shim tags the `phys` field correctly, but auto-mknod for UHID child devices is not yet implemented. Workaround: use mdevd or an inotify watcher inside the container for UHID devices.
- **dup()/dup2() tracking**: If a process duplicates a uinput file descriptor, the shim loses tracking of the new fd. This is uncommon in practice.
- **Networking for multiple instances**: With `--network=host`, all instances share the host network. Sunshine uses ports 47984-48110 by default. For multiple instances, configure each Sunshine to use different port ranges, or use bridge networking with port mapping.
- **Steam first launch**: The first boot downloads Steam (~1.5GB). Use persistent volumes to avoid re-downloading on container recreation.
- **Fedora version**: The Bazzite COPRs (Valve Mesa, PipeWire) target specific Fedora versions. If the COPR doesn't have builds for your Fedora version, the package installation will fail. Check COPR availability before changing `FEDORA_VERSION`.
