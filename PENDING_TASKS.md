# Pending Tasks

Open follow-ups after the `rootless-podman` branch (rootless podman input
isolation, submodules rebased onto upstream).

## Done

- **Rootless podman with input isolation.** `run.sh` runs rootless by default;
  the input daemon bind-mounts this container's tagged host nodes instead of
  using mknod. Smoke-tested: hotplug, ownership, read/write open, udev DB, and
  cleanup on unplug all pass, and host devices stay invisible.
- **Sunshine rebased onto upstream.** `Sunshine` now tracks
  `gamescope-capture-upstream`: upstream LizardByte/Sunshine with only the
  gamescope scanout capture backend ported on top. The fork's Vulkan encoder
  changes are dropped (upstream ships `h264/hevc/av1_vulkan`, confirmed working
  with upstream's prebuilt FFmpeg).
- **gamescope rebased onto upstream.** `gamescope` now tracks
  `gamescope-ba-rebased` (ValveSoftware/gamescope master plus the fork's
  commits), including a fix for a headless crash when a scanout export client
  subscribes before the first composite.
- **`GS_ENABLE_CTRL_12`.** The rebased gamescope gates the Ctrl+1 / Ctrl+2
  mappings on it (`src/wlserver.cpp`), and the variable reaches `gamescope-wl`
  via `/run/container.env`. Not yet tested by pressing the keys.
- Old untracked `wolf/`, `Sunshine-upstream-gamescope/` and `.vscode/` are gone.
- **Host input isolation** (2026-10-19). Before the fix, libinput already
  ignored tagged keyboard/mouse/touch, but host SDL3 could open a tagged
  gamepad because the host user owns rootless container nodes. Fix:
  `gamehub-hide-input-node` (udev helper installed by
  `scripts/install-host-udev-rules.sh`) moves tagged `event*`/`js*`/`hidraw*`
  nodes to `/dev/gamehub-input/<name>` (0700, container root's subuid), then
  gives them to the host user; at the public path they stay root-only, so
  Flatpak Steam's inotify watcher cannot open them in between. Verified:
  `scripts/test-host-input-isolation.py` PASSes all 12 checks, and in
  `sunshine-2` a tagged pad is bound from the hidden dir, `gamer` opens and
  reads it, and both sides clean up on unplug.
- **`/dev/uhid`** is now loaded at boot and `0666` (section 1 below kept for
  reference on other hosts).

## 1. Host setup: `/dev/uhid`

`/dev/uhid` on the host is still `root 0600` (the `uhid` module was not loaded
when the udev rule was installed), so DualSense (UHID) emulation will not work.
Fix:

```bash
sudo modprobe uhid && echo uhid | sudo tee /etc/modules-load.d/uhid.conf && sudo udevadm trigger --action=add --sysname-match=uhid
```

## 2. Runtime checks still to do

- Connect a real Moonlight client to the rootless container and stream (video,
  audio, keyboard/mouse, gamepad, rumble).
- Rootful fallback (`ROOTFUL=1` / `ENABLE_RYZENADJ=1`) has not been run since
  the changes; check the mknod path and that rtkit now starts there.
- Press Ctrl+1 / Ctrl+2 with `GS_ENABLE_CTRL_12=0` and `=1`.
- Default ports 47984-48010 are taken by the host (linuxbrew) Sunshine, so
  instance 1 cannot start while it runs. Testing used `./run.sh 2 57989`.

## 3. Known limitations (accepted for now)

- Rootless cannot do realtime scheduling; `rtkit-daemon` is skipped
  (`ConditionCapability=CAP_SYS_NICE`).
- RyzenAdj needs rootful mode. KMS capture is not used (gamescope scanout
  capture only), so Sunshine has no file caps.
- All instances run as one host user, so isolation protects against accidental
  cross-talk, not a deliberately malicious container.
- Sunshine logs "Failed to create client: Daemon not running" (no Avahi in the
  container); harmless, the host-side mDNS publisher advertises instead.
- Hiding the node paths (`/dev/gamehub-input`) only defends against accidental
  pickup. A host process running as the user can still reach the nodes via
  `podman unshare` or `/proc/<pid>/root`.
- A separate host-uid design (container nodes owned by another host uid) was
  rejected. Rootless podman cannot do idmapped mounts (crun `mount_setattr`
  EPERM), so the container would lose write access to the shared `/mnt/DATA`
  drive.

## 4. Rootless RyzenAdj

Implemented as a host helper: `scripts/install-host-ryzenadj.sh` installs
RyzenAdj, `gamehub-ryzenadjd` (whitelisted, clamped options, uid-checked) and
`gamehub-ryzenadj.socket`; `run.sh` binds the socket directory into rootless
containers and `scripts/ryzenadj` forwards to it. SimpleDeckyTDP uses the
`ryzenadj` on `PATH`, so its TDP control goes through the helper; its EPP,
governor and boost controls work through `gamehub-cpufreq-access.service`.
Remaining: undervolting (curve optimiser) and other unclamped options still
need the rootful fallback.

## 5. Cleanup

- `Sunshine` checkout has untracked leftovers from the old nested-submodule
  layout (`third-party/doxyconfig/`,
  `packaging/linux/flatpak/deps/shared-modules/`, and dirty `third-party/tray`,
  `third-party/libdisplaydevice`, `third-party/build-deps`). Clean them up or
  reset the nested submodules.
- `SUNSHINE_GAMESCOPE_PORT_HANDOVER.md` and
  `Dockerfile.sunshine-upstream-gamescope-build` describe the now-finished port;
  remove or archive them.
- `gamescopegrab.cpp` still lacks doxygen comments expected upstream, and its
  `is_event_driven()` override was removed during the port; confirm capture
  pacing is unaffected.
- Old submodule branches `gamescope-ba` and `vulkan-pr-4` remain on the forks;
  delete them once the rebased branches are proven.
