# Gamescope Scanout Export + PipeWire Capture Improvements

## Overview

Two major feature areas implemented across gamescope-bazzite (compositor) and Sunshine (streaming server):

1. **PipeWire Capture Improvements** — Framerate negotiation, rate limiting, commit-skip optimizations
2. **Gamescope Scanout DMA-BUF Export** — New Wayland protocol for zero-overhead capture, bypassing PipeWire entirely

### Performance Results
- **KMS capture:** 44% GPU usage (baseline, requires root/CAP_SYS_ADMIN)
- **Old gamescope PipeWire:** 57% GPU usage (+13% overhead from re-compositing)
- **New gamescope PipeWire (our changes):** 65% → improved framerate behavior but inherent PipeWire overhead remains
- **Gamescope Scanout Export (new):** Matches KMS performance (~44%) — zero re-compositing overhead, no root required

---

## Part 1: PipeWire Capture Improvements

### Problem
When Moonlight requested 60fps, gamescope was sending 120fps via PipeWire. The PipeWire path also had 13-21% more GPU overhead than KMS due to re-compositing.

### Changes

#### Sunshine Side

**File: `Sunshine/src/platform/linux/pipewire_common.h`**
- Modified `build_format_parameter()` to advertise the actual requested framerate via `SPA_FORMAT_VIDEO_maxFramerate`
- Previously hardcoded; now uses `refresh_rate` parameter (e.g., 60fps when Moonlight requests 60fps)
```cpp
uint32_t max_fps = refresh_rate > 0 ? refresh_rate : 60;
max_framerates[0] = SPA_FRACTION(max_fps, 1);   // preferred
max_framerates[1] = SPA_FRACTION(1, 1);          // min
max_framerates[2] = SPA_FRACTION(max_fps, 1);    // max
spa_pod_builder_add(b, SPA_FORMAT_VIDEO_maxFramerate,
    SPA_POD_CHOICE_RANGE_Fraction(&max_framerates[0], &max_framerates[1], &max_framerates[2]), 0);
```

#### Gamescope Side

**File: `gamescope/src/pipewire.cpp`**
- Added `static std::atomic<uint32_t> s_nMaxFramerate{0}` to store consumer-requested max framerate
- In `stream_handle_param_changed()`: parses `max_framerate` from SPA format negotiation, stores in atomic
- Added `uint32_t pipewire_get_max_framerate(void)` accessor function

**File: `gamescope/src/pipewire.hpp`**
- Added declaration: `uint32_t pipewire_get_max_framerate(void);`

**File: `gamescope/src/steamcompmgr.cpp`**
- Added `#include <chrono>` for timing
- **Rate limiter in `paint_pipewire()`**: Uses deadline advancement to cap output framerate to consumer's requested max. Key design: advances next deadline from PREVIOUS deadline (not wall-clock time) to prevent framerate loss from `vulkan_wait()` blocking time accumulating.
```cpp
static auto s_tNextPipewireFrame = std::chrono::steady_clock::time_point{};
auto tNow = std::chrono::steady_clock::now();
uint32_t nMaxFPS = pipewire_get_max_framerate();
if ( nMaxFPS == 0 ) nMaxFPS = 60;
auto frameInterval = std::chrono::microseconds( 1000000 / nMaxFPS );
if ( tNow < s_tNextPipewireFrame ) return;
if ( tNow - s_tNextPipewireFrame > frameInterval * 2 )
    s_tNextPipewireFrame = tNow + frameInterval;
else
    s_tNextPipewireFrame += frameInterval;
```
- **Commit-skip optimization**: Changed to only check focus + override window commits (removed overlay/MangoHUD commits that were changing at 120Hz, causing double frame count)
- **NoFilter for PipeWire paint**: Changed focus window paint to use `PaintWindowFlag::NoFilter` (LINEAR filter instead of full FSR/NIS upscale) since PipeWire captures don't need expensive upscaling

### Bugs Fixed in PipeWire Path
1. **120fps when 60fps requested**: MangoHUD overlay commits changing at 120Hz bypassed commit-skip + no rate limiter
2. **40fps cap at 60fps setting**: Rate limiter timestamp was set AFTER `vulkan_wait()` (5ms GPU wait added to every interval)
3. **45fps cap at 60fps setting**: Quantization mismatch at 90Hz effective callback rate. Fixed with deadline advancement approach

---

## Part 2: Gamescope Scanout DMA-BUF Export Protocol

### Architecture
Event-driven Wayland protocol where gamescope exports its composited scanout buffer directly to Sunshine without re-compositing. Gamescope's triple-buffered Vulkan output images (`g_output.outputImages[0..2]`) are exported as DMA-BUF FDs.

### Protocol Definition

**File: `gamescope/protocol/gamescope-scanout.xml`** (NEW)
Copy also at: `third-party/gamescope-protocols/gamescope-scanout.xml`

```xml
<interface name="gamescope_scanout" version="1">
  <!-- Enums -->
  <enum name="subscribe_flags" bitfield="true">
    <entry name="prefer_hdr" value="0x1"/>
  </enum>
  <enum name="colorspace">
    <entry name="sdr_srgb" value="0"/>
    <entry name="hdr10_pq" value="1"/>
  </enum>

  <!-- Client → Server -->
  <request name="destroy" type="destructor"/>
  <request name="subscribe">       <!-- max_fps (0=unlimited), flags -->
  <request name="release_buffer">   <!-- buffer_id -->

  <!-- Server → Client -->
  <event name="frame">       <!-- buffer_id, width, height, fourcc, modifier, num_planes, timestamp, colorspace -->
  <event name="plane">       <!-- fd, stride, offset (one per plane) -->
  <event name="frame_done">  <!-- signals all planes sent -->
  <event name="hdr_metadata"> <!-- CTA-861.G: display primaries, white point, luminance, CLL, FALL -->
</interface>
```

### Gamescope Server-Side Implementation

**File: `gamescope/protocol/meson.build`** (MODIFIED)
- Added `'gamescope-scanout.xml'` to protocol list

**File: `gamescope/src/wlserver.hpp`** (MODIFIED)
- Added `#include <chrono>` and `#include <set>`
- Added `gamescope_scanout_client` struct to `wlserver_t`:
  - `resource`, `max_fps`, `prefer_hdr`, `subscribed`
  - `next_frame_time` — per-client rate limiter deadline
  - `outstanding_buffer_ids` — tracks unreleased buffers (max 2 of 3 triple-buffered)
  - `last_hdr_state` — tracks HDR state changes for metadata events
  - `last_focus_commit_id`, `last_override_commit_id` — per-client commit-skip state
  - `force_send_frames` — grace period counter: bypasses commit-skip for N frames after (re)subscribe
- Added `std::vector<gamescope_scanout_client> gamescope_scanout_clients`
- Added declaration: `void wlserver_scanout_send_frame( uint64_t ulFocusCommitId, uint64_t ulOverrideCommitId );`

**File: `gamescope/src/wlserver.cpp`** (MODIFIED)
- Added `#include "rendervulkan.hpp"` for `vulkan_get_last_output_image()`, `g_output`, `CVulkanTexture`
- Added `#include "gamescope-scanout-protocol.h"` for generated protocol bindings

Protocol handlers:
- `gamescope_scanout_handle_destroy()` — destroys resource
- `gamescope_scanout_handle_subscribe(max_fps, flags)` — updates client settings, resets commit tracking (last_focus_commit_id=0, last_override_commit_id=0), clears outstanding buffers, sets force_send_frames=3
- `gamescope_scanout_handle_release_buffer(buffer_id)` — removes from outstanding set
- `gamescope_scanout_bind()` — creates resource, initializes client struct, sets destructor that removes client from vector
- `create_gamescope_scanout()` — creates wl_global, called from wlserver_init()

Main function `wlserver_scanout_send_frame(ulFocusCommitId, ulOverrideCommitId)`:
1. **Early-out check**: scans clients for any needing a frame (force_send_frames > 0 OR commit ID mismatch)
2. Gets `vulkan_get_last_output_image(false, false)` — returns `outputImages[(nOutImage+2)%3]` (safe to read)
3. Reads `wlr_dmabuf_attributes` from texture (fds, format, modifier, pitches, offsets)
4. Gets `CLOCK_MONOTONIC` timestamp
5. Per-client loop:
   - **Grace period**: if `force_send_frames > 0`, decrement and skip commit-skip
   - **Per-client commit-skip**: only send if focus/override commits changed for THIS client
   - **Rate limiting**: per-client deadline advancement (same algorithm as PipeWire rate limiter)
   - **Outstanding buffer limit**: max 2 unreleased buffers (of 3 triple-buffered)
   - **HDR metadata on change**: reads from `g_output.swapchainHDRMetadata->View<hdr_output_metadata>().hdmi_metadata_type1`
   - **Frame events**: sends frame header, plane FDs (with `dup()` — Wayland closes sent FDs), frame_done
   - Tracks outstanding buffer IDs and updates commit tracking

**File: `gamescope/src/steamcompmgr.cpp`** (MODIFIED)
- Integration hook in `bIsVBlankFromTimer` block, after `paint_pipewire()`:
```cpp
// Scanout export: send frame to subscribed clients
if ( !wlserver.gamescope_scanout_clients.empty() )
{
    global_focus_t *pScanoutFocus = GetCurrentFocus();
    if ( pScanoutFocus && pScanoutFocus->focusWindow )
    {
        uint64_t ulFocusCommitId = window_last_done_commit_id( pScanoutFocus->focusWindow );
        uint64_t ulOverrideCommitId = window_last_done_commit_id( pScanoutFocus->overrideWindow );
        wlserver_lock();
        wlserver_scanout_send_frame( ulFocusCommitId, ulOverrideCommitId );
        wlserver_unlock();
    }
}
```

### Sunshine Client-Side Implementation

**File: `Sunshine/src/platform/linux/gamescopegrab.cpp`** (NEW — ~575 lines)

Key classes and structures:

`gs::pending_frame_t` — holds frame metadata received from protocol events:
- buffer_id, width, height, fourcc, modifier, num_planes, colorspace, timestamp_ns
- fds[4], strides[4], offsets[4], planes_received counter
- `reset()` method closes any open FDs

`gs::connection_t` — **persistent Wayland connection** that survives display reinit cycles:
- Holds `wl_display*`, `wl_registry*`, `gamescope_scanout*` proxy
- Dispatch thread: polls Wayland fd with 100ms timeout, dispatches events
- `active_display` atomic pointer: routes frame callbacks to the current display instance
- Static singleton: `gs::s_conn` shared across display reinit cycles
- Destructor stops dispatch thread, destroys protocol objects, disconnects

`gs::get_connection()` — factory that returns existing connection or creates new one:
- Connects to `WAYLAND_DISPLAY` env var
- Binds `gamescope_scanout_interface` from registry
- Sets up protocol listener with `connection_t*` as user data
- Starts dispatch thread

`gs::display_vram_t` — extends `platf::display_t`:
- `init()`: Gets/reuses connection, sets `active_display = this`, subscribes with max_fps, waits for first frame (2s timeout), sets dimensions, records initial HDR state
- `capture()`: Main loop — waits for frame_ready condition variable, checks resolution/HDR changes (returns `capture_e::reinit`), fills `egl::img_descriptor_t` with surface descriptor (fds, pitches, offsets, fourcc, modifier), transfers FD ownership, sends release_buffer
- `alloc_img()`: Creates `egl::img_descriptor_t` with dimensions
- `make_avcodec_encode_device()`: Factory for VAAPI/Vulkan/CUDA encode devices
- `is_hdr()`: Returns `hdr_active` (set per-frame from colorspace field)
- `get_hdr_metadata()`: Returns gamescope metadata if received, else standard BT.2020 fallback primaries
- `is_event_driven()`: Returns true
- Destructor: sets `active_display = nullptr`, resets pending frame (does NOT destroy connection)

Event callbacks (routed through `connection_t::active_display`):
- `handle_frame()`: Resets pending, fills metadata, sets `hdr_active` from colorspace
- `handle_plane()`: Collects FD + stride + offset per plane
- `handle_frame_done()`: Sets `frame_ready = true`, notifies condition variable
- `handle_hdr_metadata()`: Sets `hdr_meta_received = true`, fills `SS_HDR_METADATA` struct

Namespace `platf` functions:
- `gs_display()`: Creates `display_vram_t`, rejects `mem_type_e::system`
- `gs_display_names()`: **Fast path** — if `s_conn` exists, returns `{"0"}` immediately (avoids ~400ms Wayland roundtrip on reinit). **Slow path** — creates temporary connection to probe for interface.

**File: `Sunshine/src/platform/linux/misc.cpp`** (MODIFIED)
- Added `GAMESCOPE` to `source::source_e` enum (positioned after NVFBC, before WAYLAND)
- Added `gs_display_names()`, `gs_display()` declarations and `verify_gs()` function
- Added gamescope routing in `display_names()`, `display()`, and `init()` functions
- Priority order: NvFBC > **Gamescope** > Wayland > KMS > X11 > Portal > PipeWire
- Selectable via config: `capture = gamescope`

**File: `Sunshine/cmake/compile_definitions/linux.cmake`** (MODIFIED)
- Added gamescope section inside Wayland block (requires Wayland):
```cmake
if(${SUNSHINE_ENABLE_GAMESCOPE})
    add_compile_definitions(SUNSHINE_BUILD_GAMESCOPE)
    GEN_WAYLAND("${CMAKE_SOURCE_DIR}/third-party/gamescope-protocols" "." gamescope-scanout)
    list(APPEND PLATFORM_TARGET_FILES
            "${CMAKE_SOURCE_DIR}/Sunshine/src/platform/linux/gamescopegrab.cpp")
endif()
```

**File: `Sunshine/cmake/prep/options.cmake`** (MODIFIED)
- Added: `option(SUNSHINE_ENABLE_GAMESCOPE "Enable gamescope scanout export capture if available." ON)`

**File: `Sunshine/src_assets/common/assets/web/configs/tabs/Advanced.vue`** (MODIFIED)
- Added `<option value="gamescope">Gamescope (Scanout Export)</option>` to Linux capture method dropdown

**File: `Sunshine/third-party/gamescope-protocols/gamescope-scanout.xml`** (NEW)
- Copy of protocol XML for Sunshine's wayland-scanner code generation

---

## Bugs Fixed in Scanout Export

1. **Second encoder probe timeout**: Global commit-skip blocked new clients. Fixed with per-client commit tracking (`last_focus_commit_id` per client, reset to 0 on subscribe)
2. **HDR washed-out colors**: gamescope was sending all-zero HDR metadata. Fixed by reading from `g_output.swapchainHDRMetadata`. Sunshine side adds fallback BT.2020 primaries when metadata not yet received.
3. **HDR toggle not detected**: `capture()` never returned `reinit` on HDR change. Fixed by tracking `encoder_hdr_state` vs `hdr_active` from per-frame colorspace field.
4. **Green screen after HDR toggle**: Commit-skip meant only 1 frame sent on static screen; if captured during transition, it was corrupted. Fixed with `force_send_frames = 3` grace period after (re)subscribe.
5. **Slow HDR toggle (~2s freeze)**: Full Wayland teardown/reconnect on reinit. Fixed with persistent `connection_t` that survives across display reinit cycles + fast-path `gs_display_names()`.
6. **Persistent connection + commit-skip interaction**: Re-subscribe on same Wayland client didn't reset commit tracking. Fixed by resetting `last_focus_commit_id`, `last_override_commit_id`, and `outstanding_buffer_ids` in subscribe handler.
7. **Tiled/corrupted capture with Vulkan encoder (headless backend)**: Headless backend returned `UsesModifiers() = false`, causing output images to be created with `VK_IMAGE_TILING_OPTIMAL` but exported with `modifier = DRM_FORMAT_MOD_INVALID`. Sunshine's Vulkan encoder imported them as `VK_IMAGE_TILING_LINEAR` → GPU-tiled memory read as linear → corrupted tiles. Fixed by making `HeadlessBackend::UsesModifiers()` return `true` and `GetSupportedModifiers()` return `GetSupportedSampleModifiers()` (same pattern as DeferredBackend). VAAPI was unaffected because its EGL import path handles tiling transparently.

---

## Key Design Decisions

1. **Event-driven vs polling**: Chose event-driven — gamescope pushes frames after paint_all() commits to DRM. Gives variable framerate (only sends when game renders new frame), at cost of slightly slower reinit vs polling-based KMS.

2. **Per-client commit-skip**: Instead of global commit-skip (which blocked new clients), each client tracks its own commit IDs. New clients always get the first frame. Grace period of 3 frames after subscribe ensures clean frames on static content.

3. **Persistent Wayland connection**: The `connection_t` singleton survives display destruction/recreation. On reinit, only the `active_display` pointer is swapped. This eliminates ~400ms Wayland roundtrip overhead during HDR/resolution changes.

4. **FD lifetime**: Protocol sends `dup()`'d FDs (Wayland closes sent FDs). Sunshine transfers FD ownership to `img_descriptor_t` (sets `pending.fds[i] = -1` after transfer). `release_buffer` signals gamescope it can reuse the buffer.

5. **Triple-buffer safety**: `vulkan_get_last_output_image(false, false)` returns `outputImages[(nOutImage+2)%3]` — two frames behind the current write, safe to read. Outstanding buffer limit of 2 prevents all 3 buffers from being held by the client.

---

## File List Summary

### New Files
| File | Description |
|------|-------------|
| `gamescope/protocol/gamescope-scanout.xml` | Wayland protocol definition |
| `Sunshine/third-party/gamescope-protocols/gamescope-scanout.xml` | Protocol copy for Sunshine build |
| `Sunshine/src/platform/linux/gamescopegrab.cpp` | Sunshine capture backend (~575 lines) |

### Modified Files
| File | Changes |
|------|---------|
| `gamescope/protocol/meson.build` | Added gamescope-scanout.xml |
| `gamescope/src/wlserver.hpp` | Added scanout client struct + function decl |
| `gamescope/src/wlserver.cpp` | Protocol handlers + send_frame (~200 lines added) |
| `gamescope/src/steamcompmgr.cpp` | Rate limiter, commit-skip, scanout hook, NoFilter |
| `gamescope/src/Backends/HeadlessBackend.cpp` | Enable DRM modifiers for headless output images (fixes tiled Vulkan capture) |
| `gamescope/src/pipewire.cpp` | Max framerate atomic + accessor |
| `gamescope/src/pipewire.hpp` | pipewire_get_max_framerate() declaration |
| `Sunshine/src/platform/linux/misc.cpp` | GAMESCOPE source registration |
| `Sunshine/src/platform/linux/pipewire_common.h` | maxFramerate SPA negotiation |
| `Sunshine/cmake/compile_definitions/linux.cmake` | GAMESCOPE build section |
| `Sunshine/cmake/prep/options.cmake` | SUNSHINE_ENABLE_GAMESCOPE option |
| `Sunshine/src_assets/common/assets/web/configs/tabs/Advanced.vue` | Gamescope capture dropdown |
