# Performance

This page records the latency and GPU-cost work on this container's streaming path, from gamescope's compositor to the packet Sunshine sends, with what each change measured. [CUSTOM_SUNSHINE_GAMESCOPE.md](CUSTOM_SUNSHINE_GAMESCOPE.md) describes the gamescope capture protocol in detail; this page covers why it exists and what it costs.

All numbers come from one machine: an AMD Phoenix APU (Radeon 780M, VCN 4) streaming 1920x1080 10-bit HDR to Moonlight, with a game holding the GPU near 100% unless noted. "Host latency" is Moonlight's *host processing latency*, which Sunshine measures from the capture timestamp to the packet header.

## Where things stand

AV1, CBR, GPU-bound game, steady state:

| Stage | Average | Worst per 20 s window |
|---|---|---|
| gamescope frame to Sunshine's encoder thread | 0.12 ms | 0.5-1.0 ms |
| Convert (hand the captured buffer to the encoder) | 0.01 ms | 0.05-0.3 ms |
| Encode on VCN | 1.74 ms | 2.1-3.3 ms |
| **Moonlight host latency** | **~1.9 ms** | **2.2-2.4 ms, now and then ~3 ms** |

The encode is the floor: VCN already runs at its top clock (2400 MHz) while streaming, and its fastest frame takes 1.56 ms. The occasional slow encode happens about once in 2,000 frames, on frames of normal size (CBR pads every frame to the same size), so it comes from contention with the game rather than from the content.

How the host latency got here, each step under the same kind of GPU load:

| Change | Average | Max |
|---|---|---|
| Compute-shader RGB to YUV conversion (Sunshine's default) | 4.5 ms | 8 ms |
| VCN converts RGB itself (RGB-direct) | 2.2 ms | 3.8 ms |
| Captured buffers imported once and reused | 1.9 ms | 2.2-2.4 ms |

## Capture: gamescope scanout export

The usual ways to capture gamescope cost either privileges or GPU time:

- **KMS capture** needs `CAP_SYS_ADMIN` and a real display, neither of which a rootless headless container has.
- **gamescope's PipeWire stream** composites a second copy of every frame for PipeWire.

This container's gamescope has a Wayland protocol, `gamescope_scanout`, that hands Sunshine the DMA-BUF of the image gamescope just composited. Sunshine's `gamescope` capture backend (`capture = gamescope`) reads it with no copy and no extra composite, and returns the buffer when the encoder is done with it.

GPU usage with the same game, as measured when the protocol was written:

| Capture | GPU usage |
|---|---|
| KMS (needs root) | 44% |
| gamescope PipeWire, stock | 57% |
| gamescope scanout export | ~44% |

Changes on the gamescope side (submodule `gamescope`, branch `gamescope-ba-rebased`) that affect cost or latency:

- **Frames are pushed, not polled.** gamescope sends a frame when it composites one, with the time it was sent. A static screen sends nothing and keeps the GPU idle. Frames are also sent after cursor-only repaints, so the pointer moves smoothly on low-FPS Steam pages.
- **The performance overlay doesn't set the stream rate.** MangoApp redraws on every refresh, and with adaptive sync off each of those repaints used to go out as a new frame: Moonlight received 120 fps on a static page or a 60 fps game. Repaints of the external overlay alone no longer count as new frames; its latest state goes out with the next real one. The stream follows the game's frame rate again, and the host latency max settled at 2.2-2.4 ms, probably because the encoder no longer competes with the game for duplicate frames.
- **Tiled buffers.** The headless backend used to force `LINEAR` buffers on Steam, the games and its own output images. It now offers every modifier the GPU can sample, which saves GPU time and memory bandwidth in the game itself.
- **Uncompressed output images** (`GAMESCOPE_UNCOMPRESSED_OUTPUT`, on by default). VCN can't read DCC-compressed images, and RGB-direct (below) feeds the output image straight to it. Set the variable to `0` to allow compression again; Sunshine then falls back to the compute conversion.
- **Adaptive sync in headless mode.** The headless output composites on a timer. Without VRR, a game frame that lands just after a tick waits for the next one before it is captured. With adaptive sync on (Steam's toggle, or `--adaptive-sync`), each game frame is composited as it lands, and the frame limiter caps the game at the refresh rate. This wait happens before the capture timestamp, so Moonlight's host latency doesn't show it (it stayed at 2.2 ms average); it shortens the time from the game's frame to the encoder.
- **With adaptive sync, frames are sent as soon as they're composited.** The send to scanout clients used to run only on the vblank timer, so a frame composited on the game's commit still waited for the next tick: 2.5-3.2 ms on average and 7-12 ms at worst, with a game at ~63 fps on a 120 Hz output. It now goes out right after the composite (0.01-0.02 ms, max 0.16 ms), which makes adaptive sync worth turning on for streaming. `gamescopectl scanout_send_on_vrr_paint 0` restores the old behaviour.

## Encode: Sunshine's Vulkan encoder

Sunshine (submodule `Sunshine`, branch `gamescope-capture-upstream`) uses the Vulkan Video encoder (`encoder = vulkan`) on RADV. The FFmpeg it links is built in the Dockerfile's `ffmpeg-builder` stage with the patches in `patches/ffmpeg/`.

### RGB-direct: VCN does the colour conversion

Sunshine's Vulkan encoder normally converts each RGB frame to YUV with a compute shader. That shader waits behind the game's GPU work. Dropping the stream to 1600x900 showed this clearly: with vsync off the host latency was 4.5 ms, and with vsync on (GPU no longer saturated) it was 2.3-2.5 ms.

RADV's `VK_VALVE_video_encode_rgb_conversion` lets VCN take RGB input and convert it itself. With `patches/ffmpeg/04-vulkan-encode-rgb-input.patch`, FFmpeg's Vulkan encoder accepts RGB frames, and Sunshine hands it gamescope's scanout image directly. Host latency under load went from 4.5 ms average (8 ms max) to 2.2 ms (3.8 ms max). HDR colours are unchanged.

It is on by default (`SUNSHINE_VK_RGB_DIRECT=0` turns it off). It applies only to 10-bit streams (gamescope's headless output is 10-bit RGB) whose resolution matches the container's; anything else uses the compute conversion, and Sunshine logs why. The [README](README.md#encoder-rgb-input-lower-host-latency) has the details.

### Import each captured buffer once

The RGB-direct path first imported every captured DMA-BUF into Vulkan from scratch (image, memory, semaphore) and freed it after encoding. gamescope only cycles through three output images, so Sunshine now keeps the imports, keyed by the DMA-BUF's inode and layout, and reuses them.

| | Before | After |
|---|---|---|
| Convert, average / max | 0.26 / 1.4-1.6 ms | 0.01 / 0.05-0.3 ms |
| Host latency, average / max | 2.15 / 3.5-3.8 ms | 1.9 / 2.2-2.4 ms |

### Recover from packet loss without a keyframe

When packets are lost, Moonlight asks the host to invalidate the frames it couldn't decode (for HEVC and AV1 only, never H.264). The Vulkan encoder used to answer with an IDR: a frame several times larger than usual, which spikes bitrate and latency right when the network is struggling.

With `patches/ffmpeg/05-vulkan-encode-ref-invalidation.patch`, FFmpeg's H.265 and AV1 Vulkan encoders keep a few older reference frames in the DPB (`ref_history`: the two newest and every fourth one further back, 6 for AV1 and 5 for HEVC). On an invalidation request, the next frame is a P frame that references the newest frame from before the loss. An IDR is sent only when no such frame is left.

### Thread priority in a rootless container

Sunshine asked for nice -15 for its capture and encode threads and gave up when that failed. Rootless podman has no `CAP_SYS_NICE`, so the threads stayed at nice 0. Sunshine now falls back to the lowest value `RLIMIT_NICE` allows (nice -10 here). The capture backend's Wayland thread, which every frame passes through first, gets the same priority. This was a bug fix; it didn't move the latency numbers measurably, which showed the outliers weren't caused by CPU scheduling.

### Settings

`sunshine.conf` as used for the numbers above:

```ini
capture = gamescope
encoder = vulkan
vk_quality = speed       # fastest VCN preset
vk_tune = 3              # ultra-low latency
vk_rc_mode = 2           # CBR
minimum_fps_target = 20
```

- **Codec: AV1 or HEVC.** They perform about the same (encode average 1.74 ms for AV1, 1.79 ms for HEVC). On VCN 4, RADV quietly runs HEVC's speed preset as "balanced", which is probably why HEVC is a hair slower. H.264 is roughly twice as slow (4 ms average, 8 ms max): RGB-direct doesn't support it, so it still runs the compute conversion, its encode takes about twice as long, and Moonlight never asks it to invalidate references.
- **`vk_tune = 3` (ultra-low latency)** turns on VCN's low-latency firmware mode in RADV, the equivalent of AMF's `LowLatencyInternal` and AV1 latency mode on Windows. `vk_quality = speed` picks the fastest preset.
- **CBR over VBR.** VBR added up to 1 ms to the max host latency with no change to the average.
- **`minimum_fps_target`** defaults to half the stream rate, so a 120 fps stream re-encodes the last frame at least 60 times a second. A low value such as `20` lets the stream follow the game's frame rate.
- **CPU energy preference.** With the host's EPP set to `power`, host latency rose from 4.0-4.2 ms to 5.0-5.3 ms (measured before RGB-direct). `balance_performance` is the better trade-off while streaming.

## Measuring

With `min_log_level = 1` (debug), Sunshine logs a breakdown of host latency every 20 seconds:

```
Latency: capture to encoder thread (min/max/avg): 0.07ms/0.68ms/0.12ms
Latency: convert (min/max/avg): 0.00ms/0.06ms/0.01ms
Latency: encode (min/max/avg): 1.57ms/2.15ms/1.74ms
```

They add up to Moonlight's host latency, apart from ~0.1 ms for packetizing. The log is `~/.config/sunshine/sunshine.log` inside the container. The first window after a stream starts includes encoder start-up and switching from the Steam UI to a game, so it is noisier than the rest.

To try a change without rebuilding the image, `./dev-hotswap.sh sunshine` (or `gamescope`) rebuilds incrementally in the Dockerfile's builder stages and swaps the binary into the running container. Swapping gamescope restarts Steam and any running game.

## Known limits and things that didn't help

- **Spikes when switching from the Steam UI to a game.** gamescope's own send of a frame to Sunshine occasionally takes 6-11 ms, most likely from publishing MangoApp state in the middle of the send. These show up as one-off maxima during transitions, not in steady state.
- **gamescope's composite runs at normal GPU priority.** Under a heavy game it can sit behind the game's GPU work. This happens before the capture timestamp, so Moonlight's host latency doesn't show it. amdgpu only grants high-priority queues to processes with `CAP_SYS_NICE` on the host or to the DRM master, so a rootless container can't raise it. Measuring it would take a glass-to-glass test, such as a timestamp drawn into the picture and read back on the client.
- **Slices.** They don't shorten the encode on AMD: one stream uses one VCN instance however it's sliced (Rubylight's 630-run test on Windows found the same). Sending each slice before the frame finishes would need per-slice output, which Vulkan Video doesn't offer.
- **For comparison:** [Rubylight](https://github.com/RamazanKara/Rubylight/blob/main/rust/PERFORMANCE.md), an AMD-only Windows host, reports AV1 encode at 1080p60 on an RX 7900 XT of 2.28 ms median, 2.85 ms p95 and 3.28 ms p99.
