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

Recent scanout fixes keep 90/120fps stable across Moonlight reconnects, expose HDR correctly to games via the patched EDID + `DXVK_HDR`, and avoid idle GPU usage by only forcing repaint during recent software-cursor movement instead of repainting every VBlank for the entire lifetime of a stream.

**Key changes:**
- New Wayland protocol: `gamescope-scanout.xml`
- Server-side implementation in `wlserver.cpp`: per-client rate limiting, commit-skip, HDR metadata, triple-buffer safety, explicit unsubscribe for persistent clients
- Integration hook in `steamcompmgr.cpp`: event-driven frame export after each paint cycle

### Custom Sunshine

Upstream [Sunshine](https://github.com/LizardByte/Sunshine) (self-hosted game streaming server) with one addition on top: a **gamescope scanout capture backend** (submodule branch `gamescope-capture-upstream`). Encoding uses upstream's Vulkan encoder (`h264_vulkan`, `hevc_vulkan`, `av1_vulkan`).

Instead of going through PipeWire or requiring DRM access, this Sunshine build connects directly to gamescope's Wayland compositor and uses the `gamescope_scanout` protocol to receive frames. The capture backend maintains a persistent Wayland connection that survives display reinit cycles (HDR toggling, resolution changes), avoiding the ~400ms reconnection penalty, while explicitly unsubscribing when the active display is torn down so idle connections do not keep gamescope repainting.

**Key changes:**
- New capture backend: `gamescopegrab.cpp` (~575 lines)
- Persistent Wayland connection singleton that survives display reinit, with explicit unsubscribe on teardown
- Event-driven capture with per-frame HDR metadata
- Priority in capture method selection: NvFBC > **Gamescope** > Wayland > KMS > X11

The fork's earlier Vulkan encoder changes were dropped in favor of upstream's. The `gamescope` submodule likewise tracks `gamescope-ba-rebased`, the fork rebased onto upstream ValveSoftware/gamescope. See `PENDING_TASKS.md` for open follow-ups.

### Input Isolation (Shim + Daemon)

Container input isolation is handled by two cooperating components:

#### uinput Tagging Shim (`libuinput_shim.so`)

An `LD_PRELOAD` library that **tags** every virtual input device created inside the container with a container identifier.

When a process creates a virtual input device via `/dev/uinput` or `/dev/uhid`, the device appears globally in the kernel's input subsystem — visible to the host and other containers. The shim solves this by intercepting libc calls (`open`, `ioctl`, `write`) and overriding the `phys` field on every device with `container-<CONTAINER_ID>`.

The image installs **both 64-bit and 32-bit variants** of the shim:
- `/usr/lib64/libuinput_shim.so` for native 64-bit processes
- `/usr/lib/libuinput_shim.so` for 32-bit processes such as Steam's main client bootstrap

Steam is launched through a small wrapper that sets `LD_PRELOAD=/usr/$LIB/libuinput_shim.so`, letting the dynamic loader pick the correct shim for each process ABI. This is required for Steam Input virtual controllers created by the 32-bit Steam client to be tagged and mirrored back into the container's private `/dev/input`.

This works for:
- **uinput devices** (mouse, keyboard, gamepads via Inputtino and Steam Input): the shim intercepts `UI_SET_PHYS` and `UI_DEV_CREATE` ioctls
- **UHID devices** (PS5 DualSense, Steam Input virtual controllers): the shim intercepts `write()` calls with `UHID_CREATE2` events and rewrites the `phys` field

For UHID devices, the kernel does not propagate the `phys` field to child input/hidraw sysfs attributes. To work around this, the shim also:
- **Records UHID device names** to `/run/container-input/uhid-names` so the mknod daemon can identify UHID child devices by name
- **Prefixes UHID device names** with `"Container "` (e.g., `"Container Sunshine PS5 (virtual) pad"`) so host udev rules can distinguish container UHID devices from identical host Sunshine devices

#### Input Device Node Daemon (`input-mknod-daemon`)

A lightweight sidecar daemon that **exposes device nodes** and **populates the udev database** for container-tagged devices. It handles three responsibilities:

1. **Device node exposure**: Polls `/sys/class/input/` and `/sys/class/hidraw/` every 500ms. For devices whose `phys` starts with `container-`, makes `/dev/input/eventN`, `/dev/input/jsN`, and `/dev/hidrawN` available in the container's private `/dev/input/`.
   - **Rootless (default)**: The host `/dev` is bind-mounted read-only at a hidden path, `HOST_DEV_DIR` (default `/run/gamehub-host/dev`). At startup the daemon chmods `/run/gamehub-host` to `0700`, so only container root can reach the host nodes and the `gamer` user cannot. The daemon creates an empty placeholder file under `/dev/input/` and `mount --bind`s the host node over it. `input-mknod.service` lists `HOST_DEV_DIR`, `GAMER_UID`, and `UINPUT_SHIM_DEBUG` in `PassEnvironment=`, so the `-e` values set on the container reach the system daemon. This works because rootless tmpfs mounts are `nodev` and `mknod` is denied in user namespaces. Removal unmounts with `MNT_DETACH` before unlinking.
   - **Stale nodes**: If a container device disappears and the kernel reuses its `eventN`/`hidrawN` number for a host device, the daemon removes the stale node on the next poll. It checks that the sysfs entry is still container-tagged and that `major:minor` matches before it keeps anything.
   - **Readiness wait**: The host udev rule applies ownership asynchronously. The daemon only binds a node once the host node is owned by `GAMER_UID` (default 1000, the in-container `gamer` user, mapped to the host user by `--userns=keep-id`). It retries on later polls, and after about 3 seconds (6 polls) proceeds anyway with a warning.
   - **Rootful fallback**: If `HOST_DEV_DIR` is missing or the bind fails, the daemon falls back to `mknod()` with 0666 permissions. This is the only path that works under `sudo podman` with `--cap-add MKNOD`.
   - For UHID devices (where the kernel doesn't propagate phys), falls back to **name-based matching** against the shim's claim file (`/run/container-input/uhid-names`), but only for devices under `/sys/devices/virtual/misc/uhid/`.

2. **Fake udev database**: Writes `/run/udev/data/cMAJ:MIN` entries with device type properties (`ID_INPUT_JOYSTICK=1`, `ID_INPUT_KEYBOARD=1`, etc.). This allows libudev consumers (SDL/Steam) to discover devices without running udevd. Device type is determined via `ioctl(EVIOCGBIT)` capability detection.

3. **Synthetic udev events**: Sends netlink messages on `NETLINK_KOBJECT_UEVENT` group 2 (the udev multicast group) with the `libudev\0` + `0xfeedcafe` header format. This triggers SDL's `udev_monitor` to pick up device hotplug events in real-time. Also creates `/run/udev/control` to signal "udev is present" to libudev. These netlink sends need `CAP_NET_ADMIN` in a private network namespace; rootless mode therefore uses pasta networking with published ports rather than `--network=host` (see Rootful vs Rootless).

> **Why polling instead of inotify?** sysfs does not generate inotify `IN_CREATE`/`IN_DELETE` events. The daemon originally used inotify but it silently blocked forever. Polling at 500ms provides reliable detection with negligible CPU overhead.

> **Why fake udev instead of running udevd?** A real udevd would create device nodes for ALL host devices visible in `/sys`, breaking container isolation. The daemon only creates nodes for `container-*` devices while still populating the udev database that SDL needs for gamepad discovery.

This split design solves the **UHID async problem**: when Inputtino creates a PS5 DualSense via UHID, the kernel's `hid-playstation` driver creates child input devices asynchronously (main controller, motion sensor, touchpad). The shim can't create or bind these nodes because they don't exist yet at `write()` time. The daemon catches them on the next poll cycle.

The daemon also:
- **Scans existing devices at startup** in case it starts after some devices are already created
- **Removes stale nodes** when devices are deleted from sysfs (two-pass scan/cleanup)
- **Sends remove events** to notify SDL when devices are unplugged
- **Classifies device types** via evdev capability bits (keyboard, mouse, joystick, touch, accelerometer, hidraw)

**How host Steam is distinguished from container Steam**: Both create devices named "Steam Virtual Gamepad". The shim rewrites the `phys` field on ALL uinput devices created inside the container, regardless of which application creates them. Host Steam's devices have a different `phys`, so the host udev rule doesn't match them.

### Resolution and Refresh Rate

The initial output resolution is set at container startup via environment variables:

- `SCREEN_WIDTH` (default: 1920) — gamescope output width
- `SCREEN_HEIGHT` (default: 1080) — gamescope output height
- `CUSTOM_REFRESH_RATES` (default: 60,90,120) — available refresh rates

**Dynamic resolution**: When a Moonlight client connects, Sunshine runs `set-resolution.sh` which calls `wlr-randr` to change gamescope's output resolution and refresh rate to match the client request. This uses the `wlr-output-management` Wayland protocol, which the headless backend now implements. The change propagates through:

1. Gamescope compositor output (Vulkan images recreated)
2. All Xwayland server modes (games see the new resolution)
3. Scanout export to Sunshine (stream matches client resolution)

Steam can also switch between the configured `CUSTOM_REFRESH_RATES` via its frame limit setting, which calls `HackTemporarySetDynamicRefresh()` on the headless backend.

### HDR

The headless backend always advertises HDR10 capability (BT.2020/PQ, 1000 nit peak). HDR output is activated when gamescope is started with `--hdr-enabled` (set by default via `ENABLE_GAMESCOPE_HDR=1`). A synthetic EDID with HDR static metadata is generated and written to `$GAMESCOPE_PATCHED_EDID_FILE` so Steam and games can detect HDR support. HDR metadata is sent per-frame through the scanout export protocol to Sunshine, which forwards it to the Moonlight client.

To disable HDR, set `ENABLE_GAMESCOPE_HDR=0` in the podman run command (e.g., `-e ENABLE_GAMESCOPE_HDR=0`).

### Sleep / DPMS

Steam's idle sleep settings work inside the container. When sleep triggers, gamescope enters DPMS mode (black screen, no frames streamed). On real hardware the power button resumes the system; in a container, gamescope instead wakes automatically when:

- A Moonlight client reconnects (scanout subscribe)
- Any keyboard or mouse input arrives from the streaming client

This means you can let Steam sleep normally — just reconnect from Moonlight or move the mouse to wake it up. No need to set sleep to "never".

### Steam Overlay Keyboard Shortcuts

Gamescope maps `Ctrl+1` to the Steam overlay and `Ctrl+2` to the quick-access menu by default. These conflict with some games, so `run.sh` disables the Ctrl mappings by default while preserving the gamepad Home-button behavior and `Super+1` / `Super+2` mappings.

To restore the Ctrl shortcuts for an instance, start it with:

```bash
GS_ENABLE_CTRL_12=1 ./run.sh 1 57989
```

### Decky / RyzenAdj TDP Control

SimpleDeckyTDP can use its bundled RyzenAdj binary from inside the container, but RyzenAdj needs hardware-level host access that is intentionally disabled by default. After installing Decky Loader and SimpleDeckyTDP inside the container, launch the instance with:

```bash
ENABLE_RYZENADJ=1 ./run.sh 1 57989
```

This switches that instance to rootful `sudo podman` (RyzenAdj cannot work rootless) and grants container root `CAP_SYS_RAWIO`, `/dev/mem`, and read/write access to `/sys/bus/pci/devices/0000:00:00.0/config`; all other `/sys` paths remain read-only. It is only appropriate for a trusted single-user container, because container root can then tune the host APU.

The host must already pass `sudo ryzenadj -i`. If its PCI host-bridge path differs, set `RYZENADJ_PCI_CONFIG` to the path used by host RyzenAdj. Do not run competing host-side and container-side TDP controllers at the same time.

### Desktop Mode (Switch to Desktop)

The container supports switching from Steam Game Mode to a full desktop environment and back — without restarting gamescope or the streaming session. This mirrors the "Switch to Desktop" feature on SteamOS/Steam Deck.

**Architecture**: A `session-supervisor.sh` replaces the direct Steam launch as gamescope's `CLIENTCMD`. It manages a state machine that alternates between running Steam (game mode) and running a nested [labwc](https://labwc.github.io/) Wayland compositor (desktop mode). labwc connects to gamescope as a native Wayland client (`WLR_BACKENDS=wayland`), and gamescope's XDG focus fallback promotes it as the composited window when no X11 (Steam) window is focused.

**Desktop environment**: labwc runs with waybar (taskbar), wofi (app launcher), mako (notifications), foot (terminal), thunar (file manager), and firefox. A custom GameHub theme provides a consistent dark-blue aesthetic.

**Switching to desktop**:
1. User selects "Switch to Desktop" from Steam's menu (installed as a non-Steam shortcut)
2. `switch-to-desktop.sh` writes `desktop` to the mode-request file and sends `steam +quit`
3. The session supervisor waits for Steam teardown, then launches labwc inside gamescope

**Returning to Steam**:
1. User clicks "Return to Steam" in waybar or presses `Super+Escape`
2. `return-to-steam.sh` writes `steam` to the mode-request file and kills labwc
3. The session supervisor shows a splash screen (via `foot` on gamescope's XDG shell) and launches Steam
4. Once Steam's X11 window takes focus, the splash is no longer rendered

**SteamOS compatibility**: `steamos-session-select` and `return-to-gamemode` are provided as shims that route to the appropriate switch/return scripts, so Steam's built-in "Switch to Desktop" button works without modification.

**Gamescope changes for desktop mode**:
- **XDG focus fallback** (`steamcompmgr.cpp`): When no X11 window has focus, the compositor promotes the highest-priority XDG toplevel (labwc) as the focus window for painting and scanout export
- **XDG surface destroy fix** (`wlserver.cpp`): The destroy handler no longer returns early when `wl_surface` cleanup runs before `xdg_surface` cleanup during abrupt client disconnects, preventing a dangling-pointer crash that previously made returning to Steam crash gamescope

## Prerequisites

### Host Setup (required once)

#### 1. Install the udev rule

The rules file is a template. The install script fills in your host user and primary group, installs the result to `/etc/udev/rules.d/`, and reloads udev. Run it once, as your own user (it calls `sudo` itself):

```bash
scripts/install-host-udev-rules.sh            # target user defaults to you
scripts/install-host-udev-rules.sh <user>     # or name the host user explicitly
```

Root is refused as the target. Re-run the script after changing users or after pulling updated rules.

This rule does three things:
1. Prevents the host desktop from consuming virtual input devices created by containers
2. Sets `/dev/uinput` and `/dev/uhid` to world-writable (needed for container access)
3. Keeps container-tagged devices `root:root 0600` at their public path, then the hide helper moves them out of reach and hands them to your host user, so they are visible inside the rootless container

**What this does**:
- `/dev/uinput` and `/dev/uhid` set to `MODE="0666"` — allows the container's non-root user to create virtual input devices
- Container-tagged input devices (`phys` matching `container-*`) and UHID devices (name matching `Container *`) get:
  - `OWNER`/`GROUP` are not set by the rule itself: the node stays `root:root` at its public path so a same-user program cannot open it during the window before it is moved. The hide helper then `chown`s it to your host user and its primary group. This is required for rootless: `--userns=keep-id:uid=1000,gid=1000` maps only that host user into the container, so any other owner would show up as `nobody` and be unusable. `MODE` stays `0600`, so only that user and root can open them.
  - `MODE="0600"` — strips group-read permission, which makes HHD (Handheld Daemon) skip them (critical for SteamOS/Bazzite hosts where seat-based filtering alone is insufficient)
  - `ID_SEAT="seat9"` — assigns to a non-existent seat, hiding from systemd-logind
  - `LIBINPUT_IGNORE_DEVICE="1"` — libinput (and desktop compositors) ignores them

**Hidden node path**: The install script also installs `/usr/local/libexec/gamehub-hide-input-node`, which udev runs for each container-tagged node (`event*`, `js*`, `hidraw*`). It first moves the node from its normal path to `/dev/gamehub-input/<kernel-name>`, and only then `chown`s it to your host user (`0600`). The ordering matters: Flatpak Steam's SDL watches `/dev/input` with inotify and could open the node in the gap between udev's `chown` and the move, so the node is root-only at its public path until it is hidden. The directory is owned by the container root's host subuid (the start of your `/etc/subuid` range) with mode `0700`. Same-user host programs such as Steam or SDL games then get `ENOENT` or `EACCES` instead of the device. The in-container daemon checks `HOST_DEV_DIR/gamehub-input/` first and falls back to the normal path. This only prevents accidental pickup; `podman unshare` or `/proc/<pid>/root` still reach the nodes for a process running as your user.

**uhid (DualSense emulation)**: `/dev/uhid` must be usable by the rootless container. If it is `root 0600` (the `uhid` module is not loaded), run:

```bash
sudo modprobe uhid && echo uhid | sudo tee /etc/modules-load.d/uhid.conf && sudo udevadm trigger --action=add --sysname-match=uhid
```

**Coexistence with host Sunshine**: Safe to install alongside stock host rules such as `60-sunshine.rules` / `60-sunshine-ublue.rules`. Host Sunshine pads keep their normal names (`Sunshine X-Box One…`, `Sunshine PS5…`) and are not matched. Container UHID pads are renamed to `Container Sunshine…`, so host rules that match exact Sunshine names leave host gamepads alone. The only overlap is that this rule opens `/dev/uinput` and `/dev/uhid` to `0666` (host Sunshine still works; access is slightly broader than stock `0660`).

#### 2. Input group (not needed for rootless)

The rootless container does **not** need your user in the `input` group. `/dev/uinput` access comes from the udev rule and the logind ACL, and the container's `/dev/input` is built from device nodes the daemon binds, not from group membership.

Being in the host `input` group is harmless by itself: rootless podman drops supplementary groups unless the container asks for them. You may stay in it for other uses, such as native host Sunshine.

The only thing to avoid is `--group-add keep-groups` (or any other way of passing host groups into the container). That would expose the host `input` group to the container and, with it, host keyboards through the hidden host `/dev` bind.

#### 3. Verify input isolation

```bash
python3 -I scripts/test-host-input-isolation.py [seconds]
```

Run it as your normal user, not with sudo; it needs write access to `/dev/uinput`. It creates a tagged and an untagged virtual keyboard, mouse, touchscreen and gamepad, then checks that host libinput (seat0) and SDL3 ignore the tagged devices and see the untagged ones. It exits 0 on PASS and 1 on FAIL. After changing the udev rules, rerun `scripts/install-host-udev-rules.sh` before the test.

#### 4. GPU access

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
4. **runtime**: Fedora 44 with Valve's Mesa/PipeWire from Bazzite COPRs, Steam, and the built binaries

Subsequent builds are faster due to Docker layer caching.

## Running

### Single instance

Prefer `./run.sh` (or `./run.sh 1 57989` for a custom port range). `run.sh` runs **rootless** podman (no sudo) by default. `ENABLE_RYZENADJ=1` or `ROOTFUL=1` switches it to `sudo podman` with the legacy rootful flags (see Rootful vs Rootless). Manual rootless equivalent:

```bash
podman run -d \
    --name sunshine \
    --systemd=true \
    --shm-size=1g \
    --userns=keep-id:uid=1000,gid=1000 --user 0:0 \
    --cap-add SYS_ADMIN \
    --cap-add NET_ADMIN \
    --device /dev/dri \
    --device /dev/uinput \
    --device /dev/uhid \
    --device /dev/fuse \
    --tmpfs /dev/input:rw,nosuid,size=1m \
    --mount type=bind,src=/dev,dst=/run/gamehub-host/dev,ro=true \
    -e HOST_DEV_DIR=/run/gamehub-host/dev \
    -v /sys:/sys:ro \
    -v sunshine-steam:/home/gamer/.steam \
    -v sunshine-local:/home/gamer/.local/share/Steam \
    -v sunshine-config:/home/gamer/.config/sunshine \
    -v /var/mnt/DATA:/mnt/DATA:rw,rslave \
    -e CONTAINER_ID=sunshine-1 \
    -e SCREEN_WIDTH=1920 \
    -e SCREEN_HEIGHT=1080 \
    -p 47984:47984/tcp \
    -p 47989:47989/tcp \
    -p 47990:47990/tcp \
    -p 48010:48010/tcp \
    -p 47998:47998/udp \
    -p 47999:47999/udp \
    -p 48000:48000/udp \
    --security-opt label=disable \
    gamehub-container:latest
```

What the rootless flags do:
- `--userns=keep-id:uid=1000,gid=1000` maps your host user to the container's `gamer` (uid/gid 1000), so the udev-assigned device ownership lines up inside the container. Container root keeps `CAP_SYS_ADMIN` in its own user namespace, so mounts still work. `--user 0:0` is required because keep-id otherwise starts the container process as uid 1000, and systemd (PID 1) exits immediately when not root.
- The hidden `/dev` bind (`/run/gamehub-host/dev`) is how the daemon reaches host device nodes. It is a recursive read-only bind: rootless podman rejects `bind-nonrecursive=true` on `/dev` with EINVAL because its submounts are locked in the user namespace, so host `/dev` submounts also appear under it. That is acceptable because `/run/gamehub-host` is `0700` and only container root can enter it. It is not visible at `/dev`, and the `/dev/input` tmpfs is only populated with this container's tagged devices. Do not add `--group-add keep-groups` (see Host Setup).
- Published ports (`-p`) replace `--network=host`. Rootless networking runs in a private network namespace, which is required for the daemon's synthetic udev events. Use 1:1 mappings (see Multiple instances).
- No `--device-cgroup-rule` or `--cap-add MKNOD`. Device cgroup filtering does not apply rootless, and `mknod` is not needed.

**Host data volume**: Mount shared storage only at a non-Steam path such as `/mnt/DATA`. Do **not** bind-mount under `/run/media/deck/...` (or `/run/media/<user>/...`). SteamOS/Steam treat that path as removable/external storage and will show the volume as an external drive. To use a Steam library on the host disk, mount at `/mnt/DATA` and add e.g. `/mnt/DATA/SteamLibrary` manually in Steam (via `libraryfolders.vdf`), not via the external-drive UI.

### Multiple instances

Each instance needs a unique `CONTAINER_ID`, unique Sunshine port range, and separate storage volumes.

**Important**: Sunshine's internal ports must match the external ports. Use the `SUNSHINE_PORT` environment variable to set the base port (e.g., `-e SUNSHINE_PORT=57989`). Sunshine derives all other ports from this base (HTTP = port - 5, RTSP = port + 21, etc.). Use 1:1 port mapping so Moonlight can reach all ports correctly during pairing.

`run.sh` also starts a detached host-side mDNS publisher for Moonlight discovery. It advertises the same service native Sunshine uses: `<container-name>._nvstream._tcp` on the Sunshine HTTP port. Publisher logs are written to `/tmp/gamehub-mdns-<container-name>.log`.

```bash
# Instance 1 — default ports (47984-48010)
podman run -d --name sunshine-1 \
    --systemd=true \
    --shm-size=1g \
    --userns=keep-id:uid=1000,gid=1000 --user 0:0 \
    --cap-add SYS_ADMIN --cap-add NET_ADMIN \
    --device /dev/dri --device /dev/uinput --device /dev/uhid --device /dev/fuse \
    --tmpfs /dev/input:rw,nosuid,size=1m \
    --mount type=bind,src=/dev,dst=/run/gamehub-host/dev,ro=true \
    -e HOST_DEV_DIR=/run/gamehub-host/dev \
    -v /sys:/sys:ro \
    -v s1-steam:/home/gamer/.steam \
    -v s1-local:/home/gamer/.local/share/Steam \
    -v s1-config:/home/gamer/.config/sunshine \
    -v /var/mnt/DATA:/mnt/DATA:rw,rslave \
    -e CONTAINER_ID=sunshine-1 \
    -e SCREEN_WIDTH=1920 \
    -e SCREEN_HEIGHT=1080 \
    -p 47984:47984/tcp -p 47989:47989/tcp -p 47990:47990/tcp -p 48010:48010/tcp \
    -p 47998:47998/udp -p 47999:47999/udp -p 48000:48000/udp \
    --security-opt label=disable \
    gamehub-container:latest

# Instance 2 — port range 57984-58010
# SUNSHINE_PORT sets the base port via command line (no need to edit sunshine.conf)
podman run -d --name sunshine-2 \
    --systemd=true \
    --shm-size=1g \
    --userns=keep-id:uid=1000,gid=1000 --user 0:0 \
    --cap-add SYS_ADMIN --cap-add NET_ADMIN \
    --device /dev/dri --device /dev/uinput --device /dev/uhid --device /dev/fuse \
    --tmpfs /dev/input:rw,nosuid,size=1m \
    --mount type=bind,src=/dev,dst=/run/gamehub-host/dev,ro=true \
    -e HOST_DEV_DIR=/run/gamehub-host/dev \
    -v /sys:/sys:ro \
    -v s2-steam:/home/gamer/.steam \
    -v s2-local:/home/gamer/.local/share/Steam \
    -v s2-config:/home/gamer/.config/sunshine \
    -v /var/mnt/DATA:/mnt/DATA:rw,rslave \
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

### Logs

Rootless instances are read without sudo:

```bash
podman logs -f sunshine-1
```

Only instances started with `ENABLE_RYZENADJ=1` / `ROOTFUL=1` (under `sudo podman`) need `sudo` for `podman logs` / `podman exec`.

### First run

1. Wait for Steam to finish bootstrapping (~1-2 minutes). A pre-cached bootstrap archive is included in the image. The gaming session may restart once during initial Steam setup — this is normal.
2. Access the Sunshine web UI at `https://<host-ip>:47990` (or the instance's configured web UI port)
3. Set up a username and password
4. For multi-instance setups: set `SUNSHINE_PORT` env var to match the external port mapping (or set `port` in the Sunshine web UI under Configuration > Network)
5. Pair with Moonlight on your client device

**Remote Web UI / CSRF**: Opening the UI from a non-localhost origin (e.g. `https://192.168.x.x:57990`) can be blocked by CSRF protection. Add that exact origin to Sunshine config and restart Sunshine only:

```bash
# In ~/.config/sunshine/sunshine.conf inside the container
csrf_allowed_origins = https://192.168.x.x:57990

# Restart Sunshine without restarting the container
podman exec -u gamer <container> bash -c \
  'XDG_RUNTIME_DIR=/run/user/1000 systemctl --user restart sunshine.service'
```

### Gamepad type and Steam Input

Sunshine creates one virtual pad via Inputtino (Xbox One uinput, Switch, or DualSense UHID). Steam Deck UI often enables **Steam Input**, which then creates a second pad (typically `Microsoft X-Box 360 pad` with Valve VID `28de`). That second pad is intentional — Steam remaps the real device so games see a stable Xbox layout while Steam keeps gyro, touchpad, and per-game configs on the source pad.

| Goal | Recommendation |
|------|----------------|
| Gyro / DualSense features | Keep DS5: `gamepad = ds5`, or leave auto with client motion sensors (`motion_as_ds4`) |
| Avoid dual-layout confusion | Per-game Steam Input **Forced On** (use Steam's X360 pad) or **Forced Off** (raw Sunshine pad only) |
| Xbox-only, no motion | `gamepad = xone` and disable `motion_as_ds4` / `touchpad_as_ds4` so auto never picks DS5 |

Deck UI can look correct while a game has inverted/wrong face buttons if the game binds the **wrong** pad (or both). Check with `cat /proc/bus/input/devices` while streaming for both `Sunshine`/`Container Sunshine` and Steam/`X-Box 360` devices.

## Rootful vs Rootless Podman

**Rootless podman (the default for `./run.sh`) is recommended.** It needs no sudo and keeps input isolation between instances (with the caveat under Rootless limitations), using a hidden host `/dev` bind and the daemon's bind-mount path instead of `mknod`. Rootful podman is an opt-in fallback, needed only for RyzenAdj (and the KMS capture fallback).

### What works in rootless mode

| Feature | Rootless (default) | Rootful (`ENABLE_RYZENADJ=1` / `ROOTFUL=1`) |
|---|---|---|
| Gamescope scanout capture | Yes | Yes |
| Vulkan/VAAPI encoding | Yes | Yes |
| Steam + Big Picture | Yes | Yes |
| Virtual mouse/keyboard (uinput) | Yes (with host udev rule) | Yes |
| Virtual gamepad (uinput) | Yes (with host udev rule) | Yes |
| PS5 DualSense (UHID) | Yes (with host udev rule) | Yes |
| Input isolation (`/dev/input/` tmpfs) | Yes (bind-mounted host nodes) | Yes (`mknod`) |
| Multi-instance input isolation | Yes (one host user, see limitations) | Yes |
| RyzenAdj / TDP control | **No** | Yes |
| KMS/DRM capture fallback | **No** | Yes |
| Networking | Private netns, published ports | Host network allowed |

### Rootful fallback

`ENABLE_RYZENADJ=1` or `ROOTFUL=1` makes `run.sh` use `sudo podman run` with the legacy flags: `--cap-add MKNOD`, `--device-cgroup-rule` for the input and hidraw majors, `--tmpfs /dev/input:rw,dev,nosuid,size=1m`, and host networking where allowed. The daemon's `mknod()` fallback handles device nodes in this mode. Earlier rootful setups with `--network=host` broadcast the daemon's synthetic udev events into the host network namespace. Rootless mode avoids this by running in a private netns with published ports.

### Rootless limitations

- **RyzenAdj** needs real `CAP_SYS_RAWIO` and `/dev/mem`, which rootless cannot grant. Use the rootful fallback above.
- **KMS/DRM capture fallback** needs a real `CAP_SYS_ADMIN` on the host. Gamescope scanout capture (Wayland, DMA-BUF) works rootless and is the default.
- **Single host user**: all instances run under one host user, so the udev ownership is the same for every container. Isolation protects against accidental cross-talk between instances and the host desktop, but not against a deliberately malicious container. Per-instance host users would be needed for that.

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│  Container (rootless Podman, --userns=keep-id)               │
│                                                              │
│  LD_PRELOAD=/usr/$LIB/libuinput_shim.so                      │
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
│  │  libuinput_shim.so (LD_PRELOAD, 32-bit + 64-bit)    │   │
│  │  Tags phys="container-sunshine-1" on all devices      │   │
│  │  (uinput via ioctl, UHID via write)                   │   │
│  │  UHID: also prefixes name with "Container ",          │   │
│  │        records name to /run/container-input/uhid-names │   │
│  └──────────────────────────────────────────────────────┘   │
│         │ devices appear in kernel                           │
│         ▼                                                    │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  input-mknod-daemon (sidecar, polling 500ms)         │   │
│  │  Polls /sys/class/input/ + /sys/class/hidraw/         │   │
│  │  Match: phys=="container-*" OR UHID name in claims    │   │
│  │    → bind /dev/input/eventN, jsN, /dev/hidrawN        │   │
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
             phys="container-sunshine-1" (uinput)
             name="Container ..." (UHID)

Host udev:   ATTRS{phys}=="container-*" OR ATTRS{name}=="Container *" →
             OWNER/GROUP=<host user>, MODE=0600, ID_SEAT="seat9", LIBINPUT_IGNORE_DEVICE=1
             (hidden from HHD, logind, libinput, host desktop)
```

## Known Limitations

- **Rootless podman requires the host udev rule**: Rootless device nodes are bind-mounted from the hidden host `/dev` (`HOST_DEV_DIR`), and their ownership comes from the host rule installed by `scripts/install-host-udev-rules.sh`. Without that rule the daemon waits (about 3 seconds) and then binds nodes the container user cannot open. Rootful `mknod()` fallback does not need the rule for ownership.
- **HDR in games**: HDR is enabled at the compositor level via `GAMESCOPE_DISPLAY_SUPPORTS_HDR`, but games detect HDR through the patched EDID file (`GAMESCOPE_PATCHED_EDID_FILE`) and the `DXVK_HDR` environment variable. Both must be present in gamescope's environment — the container-env.conf systemd drop-in and environment.d/container.conf handle this.
- **Port mapping and pairing**: Sunshine's internal ports must match external ports for Moonlight pairing to work. Use 1:1 port mapping (e.g., `-p 57989:57989`) and set `port = <HTTPS_PORT>` in sunshine.conf. NAT-style mapping (e.g., `57989:47989`) causes "certificate mismatch" errors during pairing.
- **CSRF on remote Web UI**: Non-localhost origins need `csrf_allowed_origins` in `sunshine.conf` (see First run). `origin_web_ui_allowed = wan` alone is not enough for CSRF.
- **Steam startup**: Steam in SteamOS mode may restart once during initial setup (~1-2 min). SteamOS compatibility stubs are included to prevent extended crash loops, but the first session restart is normal.
- **Host DATA as external drive**: Bind-mounting host storage under `/run/media/deck/...` makes SteamOS treat it as removable storage. Prefer `/mnt/DATA` only (see Running).
- **Gamepad/hidraw hotplug**: The mknod daemon creates fake udev DB entries and sends synthetic netlink events (MurmurHash2 subsystem filter + `USEC_INITIALIZED`) for SDL/Steam gamepad discovery. Requires `CAP_NET_ADMIN` for the netlink socket.
- **DualSense (DS5) + Steam Input dual pads**: DS5 is auto-selected when the client reports motion (`motion_as_ds4`) or touchpad (`touchpad_as_ds4`), or with `gamepad = ds5`. Requires `hid-playstation` on the host. UHID phys is not propagated to child sysfs nodes — the shim uses a claim file and `Container ` name prefix. Steam Input often creates a second Xbox 360 virtual pad on top; Deck UI uses Steam's pad, while some games bind the raw DS5 (or both), which can look like inverted face buttons. Use per-game Steam Input Forced On/Off, or force `gamepad = xone` if gyro is not needed (see Gamepad type and Steam Input).
- **tmpfs /dev/input/ and `dev` flag**: Rootless uses `--tmpfs /dev/input:rw,nosuid,size=1m` (no `dev`) and bind-mounts host nodes over placeholder files. The rootful fallback still needs `--tmpfs /dev/input:rw,dev,nosuid,size=1m`, because `mknod()` nodes on a `nodev` tmpfs are unusable.
- **dup()/dup2() tracking**: If a process duplicates a uinput file descriptor, the shim loses tracking of the new fd. The mknod daemon still picks up the device via polling, but the `phys` field won't be tagged. This is uncommon in practice.
- **Networking for multiple instances**: Rootless instances use a private network namespace with published ports. Each instance needs its own port range, set with `SUNSHINE_PORT` and 1:1 `-p` mappings. The rootful fallback may still use `--network=host`, in which case instances share the host network.
- **Fedora version**: The Bazzite COPRs (Valve Mesa, PipeWire) target specific Fedora versions. If the COPR doesn't have builds for your Fedora version, the package installation will fail. Check COPR availability before changing `FEDORA_VERSION`.
- **NVENC**: The NVENC encoder code is patched at build time to compile against newer nv-codec-headers. This is a no-op on AMD GPUs (NVENC runtime detection gracefully fails without an NVIDIA GPU).
