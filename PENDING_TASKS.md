# Pending Tasks

Open follow-ups for the `desktop_mode` branch.

## 1. Implement `GS_ENABLE_CTRL_12`

`run.sh` passes `GS_ENABLE_CTRL_12` into the container (default `0`), and
`services/container-env.service` writes it to `/run/container.env`. Nothing in
this repo reads it yet, so the README claim that the Ctrl+1 / Ctrl+2 gamescope
mappings are disabled by default is not currently true.

- Find where gamescope's Ctrl+1 / Ctrl+2 mappings live (likely the `gamescope`
  submodule, `src/wlserver.cpp` / `src/LibInputHandler.cpp`) and gate them on
  `GS_ENABLE_CTRL_12`.
- Keep the gamepad Home-button behavior and the `Super+1` / `Super+2` mappings.
- Make sure the variable reaches gamescope (e.g. via `gamescope-session-plus`).
- Until done, treat the README "Steam Overlay Keyboard Shortcuts" section as
  describing intended behavior.

## 2. Commit and push the submodules

Both submodules have uncommitted work and are not part of the pushed commits.

- `gamescope` (branch `gamescope-ba`): local changes in `src/LibInputHandler.cpp`,
  `src/wlserver.cpp`, `subprojects/stb.wrap`, `subprojects/wlroots`. The branch is
  also about 8 commits ahead of `origin/gamescope-ba`. The superproject pointer
  (`5ac8001`) refers to a commit that may not exist on the remote, so a fresh
  `--recurse-submodules` clone could fail until it is pushed.
- `Sunshine` (branch `vulkan-pr-4`): local changes in `src/config.cpp`,
  `src/config.h`, `src/platform/linux/vulkan_encode.cpp`, `src/video.cpp`, and
  `third-party/build-deps`.
- After pushing each submodule, commit the updated pointers in this repo.

## 2a. Rebase `Sunshine` onto upstream and drop our Vulkan changes

The Vulkan encoder is now merged upstream (LizardByte/Sunshine), so the
`vulkan-pr-4` fork changes should be dropped rather than committed.

- Verify the upstream merge contains what we need (`src/platform/linux/vulkan_encode.cpp`,
  `vk_*` config options) and which release/commit it landed in.
- Rebase/port only the gamescope scanout capture backend onto upstream `master`
  (see `SUNSHINE_GAMESCOPE_PORT_HANDOVER.md`; `Dockerfile.sunshine-upstream-gamescope-build`
  builds it).
- Do not commit the current dirty `Sunshine` changes. The `vk_csc_offload`
  (RGB->YCbCr offload) work in `vulkan_encode.cpp`, `video.cpp` and `config.*` is
  not upstream. Either propose it upstream as a separate PR or drop it.
- Repoint the `Sunshine` submodule (and `.gitmodules` url/branch) at the rebased
  branch, then update the README "Custom Sunshine" section.
- The `gamescope` input fixes (`LibInputHandler.cpp`, `wlserver.cpp`) are
  independent of this and can still be committed and pushed.

## 3. Untracked directories

- `wolf/` (clone of `games-on-whales/wolf`) and `Sunshine-upstream-gamescope/`
  are separate git clones and were intentionally not committed. Add them to
  `.gitignore` or make them proper submodules.
- `.vscode/settings.json` is an empty `{}`; ignore or delete it.

## 4. Sunshine gamescope capture port

See `SUNSHINE_GAMESCOPE_PORT_HANDOVER.md` for the in-progress port of the
gamescope scanout capture backend onto upstream Sunshine `master`, and
`Dockerfile.sunshine-upstream-gamescope-build` for its build.
