# Sunshine Gamescope Capture Port Handover

## Goal

Port only the custom Sunshine gamescope scanout capture backend onto latest upstream Sunshine `master`.

Do not port container input isolation changes.

## Current Repository State

Repo root:

```bash
/var/mnt/DATA/repo/GameHubContainer
```

Original Sunshine submodule:

```bash
/var/mnt/DATA/repo/GameHubContainer/Sunshine
```

This checkout has pre-existing dirty changes and should not be overwritten:

```text
branch: vulkan-pr-4
dirty files:
  M src/config.cpp
  M src/config.h
  M src/platform/linux/vulkan_encode.cpp
  M src/video.cpp
  m third-party/build-deps
```

Upstream remote was added there:

```bash
git -C Sunshine remote -v
```

Expected remotes:

```text
origin    https://github.com/XT-Martinez/Sunshine
upstream  https://github.com/LizardByte/Sunshine
```

Fetched upstream `master` successfully. Latest fetched commit:

```text
0a47d3d0 chore: revise bug report template for clarity and rules (#5387)
```

## Port Worktree

A clean separate worktree was created to avoid touching the dirty submodule checkout:

```bash
/var/mnt/DATA/repo/GameHubContainer/Sunshine-upstream-gamescope
```

Branch:

```text
port-gamescope-capture-upstream
```

Base:

```text
upstream/master @ 0a47d3d0
```

Continue all porting work in:

```bash
cd /var/mnt/DATA/repo/GameHubContainer/Sunshine-upstream-gamescope
```

## Reference Documentation

Read:

```bash
/var/mnt/DATA/repo/GameHubContainer/CUSTOM_SUNSHINE_GAMESCOPE.md
```

Relevant section: "Part 2: Gamescope Scanout DMA-BUF Export Protocol" and "Sunshine Client-Side Implementation".

## Changes To Port

### New Files

Port/copy:

```text
src/platform/linux/gamescopegrab.cpp
third-party/gamescope-protocols/gamescope-scanout.xml
```

Source files exist in the current fork:

```bash
/var/mnt/DATA/repo/GameHubContainer/Sunshine/src/platform/linux/gamescopegrab.cpp
/var/mnt/DATA/repo/GameHubContainer/Sunshine/third-party/gamescope-protocols/gamescope-scanout.xml
```

If the protocol XML is missing in Sunshine, use:

```bash
/var/mnt/DATA/repo/GameHubContainer/gamescope/protocol/gamescope-scanout.xml
```

### `src/platform/linux/misc.cpp`

Add `GAMESCOPE` capture source guarded by `SUNSHINE_BUILD_GAMESCOPE`.

Expected integration:

- add enum value after `NVFBC` and before `WAYLAND`
- declare:

```cpp
std::vector<std::string> gs_display_names();
std::shared_ptr<display_t> gs_display(mem_type_e hwdevice_type, const std::string &display_name, const video::config_t &config);
```

- add `verify_gs()`
- route `display_names()` to `gs_display_names()`
- route `display()` to:

```cpp
BOOST_LOG(info) << "Screencasting with gamescope scanout export"sv;
return gs_display(hwdevice_type, display_name, config);
```

- update `init()` to accept:

```ini
capture = gamescope
```

Original custom notes say `verify_gs()` should require:

```cpp
window_system == window_system_e::WAYLAND && !gs_display_names().empty()
```

However, on the Bazzite host observed during testing, the user manager had:

```text
XDG_SESSION_TYPE=x11
XDG_CURRENT_DESKTOP=gamescope
```

while gamescope’s Wayland socket existed at:

```text
/run/user/1000/gamescope-0
```

For practical Bazzite Game Mode testing, consider making `verify_gs()` rely on actual protocol discovery instead:

```cpp
return !gs_display_names().empty();
```

This is a deliberate divergence from the earlier notes and should be called out in the final summary if used.

### `cmake/prep/options.cmake`

Under Linux capture options, add:

```cmake
option(SUNSHINE_ENABLE_GAMESCOPE
        "Enable gamescope scanout export capture if available." ON)
```

### `cmake/compile_definitions/linux.cmake`

Inside the Wayland section, add gamescope protocol generation and source inclusion when enabled:

```cmake
if(${SUNSHINE_ENABLE_GAMESCOPE})
    add_compile_definitions(SUNSHINE_BUILD_GAMESCOPE)
    GEN_WAYLAND("${CMAKE_SOURCE_DIR}/third-party/gamescope-protocols" "." gamescope-scanout)
    list(APPEND PLATFORM_TARGET_FILES
            "${CMAKE_SOURCE_DIR}/src/platform/linux/gamescopegrab.cpp")
endif()
```

This backend requires Wayland client support.

### Web UI

Edit:

```text
src_assets/common/assets/web/configs/tabs/Advanced.vue
```

Add the capture dropdown option in the Linux capture method list(s):

```html
<option value="gamescope">Gamescope (Scanout Export)</option>
```

## Upstream Layout Notes

In the upstream worktree, `src/platform/linux/misc.cpp` currently has source enum values:

```cpp
NVFBC
WAYLAND
KMS
X11
KWIN
PORTAL
MAX_FLAGS
```

`display()` currently checks KMS first before dropping `CAP_SYS_ADMIN`. Be careful with ordering:

- KMS must still be handled before dropping elevated privileges.
- Gamescope does not need `CAP_SYS_ADMIN`.
- If selected, gamescope can be checked after privilege drop.

Desired automatic priority when `capture` is unset:

```text
NvFBC > Gamescope > Wayland > KMS > X11 > KWin/Portal
```

But preserve upstream’s privilege handling around KMS.

## Host Test Context

Current Homebrew Sunshine config on the Bazzite host was:

```ini
capture = kms
```

Logs showed KMS capture on:

```text
/dev/dri/card1 -> amdgpu
connector ID 117
cursor plane 91
```

Problem remained even with custom gamescope and:

```text
--force-composition --disable-layers
```

This suggests KMS is the wrong capture layer for Steam Deck UI overlays/input behavior on this host. The scanout backend is the next test.

For patched Sunshine runtime test, service likely needs:

```ini
capture = gamescope
```

and systemd user service environment:

```bash
WAYLAND_DISPLAY=gamescope-0
```

Possibly also:

```bash
XDG_SESSION_TYPE=wayland
```

if `verify_gs()` keeps the Wayland session-type gate.

## Suggested Verification

After porting:

```bash
git -C /var/mnt/DATA/repo/GameHubContainer/Sunshine-upstream-gamescope diff --stat
rg "SUNSHINE_BUILD_GAMESCOPE|gamescopegrab|capture == \"gamescope\"|Gamescope" /var/mnt/DATA/repo/GameHubContainer/Sunshine-upstream-gamescope
```

Try CMake configure if dependencies are present:

```bash
cmake -S /var/mnt/DATA/repo/GameHubContainer/Sunshine-upstream-gamescope \
  -B /var/mnt/DATA/repo/GameHubContainer/Sunshine-upstream-gamescope/build-gamescope-port \
  -DBUILD_DOCS=OFF \
  -DBUILD_TESTS=OFF \
  -DSUNSHINE_ENABLE_CUDA=OFF \
  -DSUNSHINE_ENABLE_GAMESCOPE=ON
```

If the build environment is incomplete, report configure/build blockers clearly.

## Useful Existing Commands

Show upstream base:

```bash
git -C Sunshine rev-parse --short upstream/master
```

Show port branch:

```bash
git -C Sunshine-upstream-gamescope status --short --branch
```

Show original dirty submodule:

```bash
git -C Sunshine status --short --branch
```
