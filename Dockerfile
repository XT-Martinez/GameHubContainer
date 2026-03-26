# syntax=docker/dockerfile:1
#
# Sunshine + Gamescope + Steam container image
# Fedora 43 base with Valve's patched Mesa/PipeWire from Bazzite COPRs
#
# Expected build context (repo root with submodules):
#   gamescope/              - custom gamescope source
#   sunshine/               - custom sunshine source
#   container-input-shim/   - uinput isolation shim
#   services/               - systemd user service files
#   scripts/                - session launch scripts
#
# Build:
#   podman build -t sunshine-gamescope .
#
# If building from the parent Sunshine repo (development):
#   podman build -f sunshine-container/Dockerfile \
#     --build-context gamescope=gamescope-bazzite \
#     --build-context sunshine=. \
#     --build-context shim=sunshine-container/container-input-shim \
#     --build-context services=sunshine-container/services \
#     --build-context scripts=sunshine-container/scripts \
#     -t sunshine-gamescope .

ARG FEDORA_VERSION=43

# ============================================================
# Common base with fast mirrors
# ============================================================
FROM fedora:${FEDORA_VERSION} AS base

RUN printf '%s\n' \
    'fastestmirror=True' \
    'max_parallel_downloads=10' \
    'defaultyes=True' >> /etc/dnf/dnf.conf

# ============================================================
# Stage 1: Build gamescope
# ============================================================
FROM base AS gamescope-builder

RUN --mount=type=cache,dst=/var/cache/libdnf5 \
    dnf5 -y install \
    meson ninja-build gcc gcc-c++ cmake git pkgconf-pkg-config \
    python3-jinja2 \
    vulkan-headers vulkan-loader-devel glslang \
    wayland-devel wayland-protocols-devel \
    libX11-devel libXdamage-devel libXcomposite-devel libXcursor-devel \
    libXrender-devel libXext-devel libXfixes-devel libXxf86vm-devel \
    libXtst-devel libXres-devel libXmu-devel libXi-devel libxkbcommon-devel \
    libdrm-devel pixman-devel libdecor-devel libdisplay-info-devel \
    systemd-devel libinput-devel libseat-devel libeis-devel \
    pipewire-devel lcms2-devel xorg-x11-server-Xwayland-devel \
    SDL2-devel libavif-devel libcap-devel luajit-devel hwdata-devel \
    glm-devel stb_image-devel \
    xcb-util-wm-devel xcb-util-errors-devel xcb-util-renderutil-devel

COPY gamescope/ /build/gamescope/
WORKDIR /build/gamescope

RUN meson setup builddir \
    --prefix=/usr \
    --buildtype=release \
    --force-fallback-for=wlroots,libliftoff,vkroots \
    -Dpipewire=enabled \
    && ninja -C builddir \
    && DESTDIR=/build/install ninja -C builddir install

# ============================================================
# Stage 2: Build Sunshine
# ============================================================
FROM base AS sunshine-builder

RUN --mount=type=cache,dst=/var/cache/libdnf5 \
    dnf5 -y install \
    cmake gcc14 gcc14-c++ git wget which \
    libcap-devel libcurl-devel libdrm-devel libevdev-devel \
    libnotify-devel libva-devel \
    libX11-devel libxcb-devel libXcursor-devel libXfixes-devel \
    libXi-devel libXinerama-devel libXrandr-devel libXtst-devel \
    openssl-devel glslc pipewire-devel \
    vulkan-headers vulkan-loader-devel \
    appstream libappstream-glib \
    libayatana-appindicator3-devel libgudev \
    mesa-libGL-devel mesa-libgbm-devel \
    miniupnpc-devel nodejs-npm \
    numactl-devel opus-devel pulseaudio-libs-devel \
    python3-jinja2 python3-setuptools \
    systemd-devel systemd-udev \
    wayland-devel wayland-protocols-devel

COPY Sunshine/ /build/sunshine/
WORKDIR /build/sunshine

ENV CC=gcc-14 CXX=g++-14

# Fix NVENC compatibility with newer nv-codec-headers pulled by FetchContent.
# This is a no-op on AMD but must compile for the runtime detection code path.
RUN sed -i 's/#error Check and update.*/#warning NVENC version mismatch - runtime detection will handle it/' \
        src/nvenc/nvenc_base.cpp && \
    sed -i 's/format_config\.pixelBitDepthMinus8 = 2;/\/\/ pixelBitDepthMinus8 removed in newer SDK/' \
        src/nvenc/nvenc_base.cpp && \
    sed -i 's/format_config\.inputPixelBitDepthMinus8 = 2;/\/\/ inputPixelBitDepthMinus8 removed in newer SDK/' \
        src/nvenc/nvenc_base.cpp

# CMake fetches Boost, FFmpeg prebuilts, and other deps via FetchContent
RUN cmake -B build -G "Unix Makefiles" \
    -DBUILD_DOCS=OFF \
    -DBUILD_TESTS=OFF \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DSUNSHINE_ASSETS_DIR=share/sunshine \
    -DSUNSHINE_EXECUTABLE_PATH=/usr/bin/sunshine \
    -DSUNSHINE_ENABLE_CUDA=OFF \
    -DSUNSHINE_ENABLE_DRM=ON \
    -DSUNSHINE_ENABLE_GAMESCOPE=ON \
    -DSUNSHINE_ENABLE_PORTAL=ON \
    -DSUNSHINE_ENABLE_WAYLAND=ON \
    -DSUNSHINE_ENABLE_X11=ON \
    -DSUNSHINE_BUILD_FLATPAK=OFF \
    && make -j$(nproc) -C build \
    && DESTDIR=/build/install make -C build install

# ============================================================
# Stage 3: Build uinput shim + mknod daemon
# ============================================================
FROM base AS shim-builder

RUN dnf5 -y install gcc kernel-headers make systemd-devel

COPY container-input-shim/ /build/
WORKDIR /build
RUN make    # builds both libuinput_shim.so and input-mknod-daemon

# ============================================================
# Stage 4: Runtime image
# ============================================================
FROM fedora:${FEDORA_VERSION}

ARG GAMER_UID=1000

RUN printf '%s\n' \
    'fastestmirror=True' \
    'max_parallel_downloads=10' \
    'defaultyes=True' >> /etc/dnf/dnf.conf

# ── Repository setup ──────────────────────────────────────────
# Enable Bazzite COPRs (Valve's patched Mesa, PipeWire, etc.)
# Enable terra (Steam), RPM Fusion (multimedia deps)
RUN --mount=type=cache,dst=/var/cache/libdnf5 \
    dnf5 -y install dnf5-plugins && \
    for copr in ublue-os/bazzite ublue-os/bazzite-multilib; do \
        dnf5 -y copr enable $copr; \
    done && \
    dnf5 -y install --nogpgcheck \
        --repofrompath 'terra,https://repos.fyralabs.com/terra$releasever' \
        terra-release terra-release-extras && \
    dnf5 -y install \
        https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm \
        https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm && \
    dnf5 -y config-manager setopt \
        "*bazzite*".priority=1 \
        "*terra*".priority=3 \
        "*rpmfusion*".priority=5 \
        "*rpmfusion*".exclude="mesa-dri-drivers,mesa-vulkan-drivers,mesa-va-drivers,mesa-vdpau-drivers,mesa-libEGL,mesa-libGL,mesa-libgbm,mesa-libglapi,mesa-filesystem" \
        "*fedora*".exclude="mesa-*"

# ── Valve's patched Mesa (AMD) ────────────────────────────────
# Base Mesa from Bazzite COPR (patched for gamescope), then swap vulkan
# drivers with freeworld from RPM Fusion for patent-encumbered codecs
# (H.264/H.265 encode) needed for Vulkan Video Encode and VAAPI.
#
# mesa-vulkan-drivers-freeworld Conflicts: mesa-vulkan-drivers, so a plain
# install silently skips the x86_64 freeworld (only i686 installs since
# there's no i686 base to conflict with). dnf5 swap handles this correctly.
RUN --mount=type=cache,dst=/var/cache/libdnf5 \
    dnf5 -y install \
        mesa-dri-drivers \
        mesa-vulkan-drivers \
        mesa-libEGL \
        mesa-libGL \
        mesa-libgbm && \
    dnf5 -y install --skip-unavailable \
        mesa-va-drivers-freeworld && \
    dnf5 -y swap \
        mesa-vulkan-drivers mesa-vulkan-drivers-freeworld || \
        echo "WARNING: vulkan freeworld swap failed — H.264/H.265 Vulkan Video Encode unavailable"

# ── Valve's patched PipeWire + WirePlumber ────────────────────
RUN --mount=type=cache,dst=/var/cache/libdnf5 \
    dnf5 -y install \
        pipewire \
        pipewire-alsa \
        pipewire-pulseaudio \
        pipewire-utils \
        wireplumber

# ── Gamescope (COPR version for runtime deps, binary overridden later) ──
RUN --mount=type=cache,dst=/var/cache/libdnf5 \
    dnf5 --enable-repo=terra -y install \
        gamescope.x86_64 \
        gamescope-libs.x86_64 \
        gamescope-shaders

# ── Gamescope session management ──────────────────────────────
RUN --mount=type=cache,dst=/var/cache/libdnf5 \
    mkdir -p /usr/share/gamescope-session-plus/ && \
    curl --retry 3 -Lo /usr/share/gamescope-session-plus/bootstrap_steam.tar.gz \
        https://large-package-sources.nobaraproject.org/bootstrap_steam.tar.gz && \
    dnf5 -y install switcheroo-control && \
    dnf5 -y install \
        --repo copr:copr.fedorainfracloud.org:ublue-os:bazzite \
        gamescope-session-plus \
        gamescope-session-steam

# ── Steam ─────────────────────────────────────────────────────
RUN --mount=type=cache,dst=/var/cache/libdnf5 \
    dnf5 --enable-repo=terra -y --setopt=install_weak_deps=False install \
        steam

# ── Remaining runtime dependencies ───────────────────────────
RUN --mount=type=cache,dst=/var/cache/libdnf5 \
    dnf5 -y install \
        # Display / Wayland
        libwayland-client \
        xorg-x11-server-Xwayland \
        dbus dbus-x11 \
        xrandr \
        # Input
        libevdev libinput \
        # Sunshine runtime deps
        vulkan-loader vulkan-tools \
        libva libva-utils libdrm libcap \
        openssl numactl-libs \
        pulseaudio-libs pulseaudio-utils \
        libcurl miniupnpc \
        libayatana-appindicator3 libnotify \
        # Gaming / overlay
        mangohud vkBasalt \
        # Display control
        wlr-randr \
        # System
        systemd acl \
        which evtest procps-ng util-linux \
        # switcherooctl needs PyGObject
        python3-gobject \
        # Steam runtime needs locale and hw detection
        glibc-langpack-en pciutils \
        # SDL controller database
        && \
    mkdir -p /usr/share/sdl/ && \
    curl --retry 3 -Lo /usr/share/sdl/gamecontrollerdb.txt \
        https://raw.githubusercontent.com/mdqinc/SDL_GameControllerDB/refs/heads/master/gamecontrollerdb.txt

# ── Overlay custom-built binaries ─────────────────────────────

# Custom gamescope (replaces COPR version)
COPY --from=gamescope-builder /build/install/ /

# Custom Sunshine
COPY --from=sunshine-builder /build/install/ /

# uinput isolation shim (phys tagging) + mknod daemon (device node creation)
COPY --from=shim-builder /build/libuinput_shim.so /usr/lib64/libuinput_shim.so
COPY --from=shim-builder /build/input-mknod-daemon /usr/local/bin/input-mknod-daemon
COPY container-input-shim/99-sunshine-container-ignore.rules /etc/udev/rules.d/

# ── SteamOS compatibility stubs ───────────────────────────────
# Steam in SteamOS mode (-steamos3 -steampal -steamdeck) tries to call
# SteamOS-specific helpers that don't exist in a container. Missing helpers
# cause Steam to error-exit, triggering gamescope-session-plus's short-session
# counter, which resets Steam config at 5 failures — creating a 20+ minute
# crash loop on startup. These no-op stubs prevent that.
RUN mkdir -p /usr/bin/steamos-polkit-helpers && \
    for stub in \
        /usr/bin/steamos-polkit-helpers/jupiter-dock-updater \
        /usr/bin/steamos-polkit-helpers/steamos-update \
        /usr/bin/steamos-polkit-helpers/steamos-factory-reset-config \
        /usr/bin/steamos-polkit-helpers/steamos-select-branch \
    ; do \
        printf '#!/bin/sh\nexit 0\n' > "$stub" && chmod +x "$stub"; \
    done && \
    # lsb_release is called by Steam but not installed
    printf '#!/bin/sh\necho "Fedora"\n' > /usr/bin/lsb_release && \
    chmod +x /usr/bin/lsb_release

# ── User and session setup ────────────────────────────────────

# Create gaming user
RUN useradd -m -u ${GAMER_UID} -G video,render,input gamer && \
    # Enable lingering (starts user session at boot without login)
    mkdir -p /var/lib/systemd/linger && \
    touch /var/lib/systemd/linger/gamer

# Install user service files and scripts
COPY services/gaming-session.service services/sunshine.service \
    /etc/systemd/user/
COPY scripts/ /usr/local/bin/
RUN chmod +x /usr/local/bin/*.sh

# Install system services (need real root for mknod/chmod in rootless podman)
COPY services/device-permissions.service /etc/systemd/system/device-permissions.service
COPY services/input-mknod.service /etc/systemd/system/input-mknod.service
RUN mkdir -p /etc/systemd/system/multi-user.target.wants && \
    ln -sf /etc/systemd/system/device-permissions.service \
        /etc/systemd/system/multi-user.target.wants/device-permissions.service && \
    ln -sf /etc/systemd/system/input-mknod.service \
        /etc/systemd/system/multi-user.target.wants/input-mknod.service

# Default Sunshine config (system location — copied to user dir on first start)
COPY configs/sunshine.conf /etc/sunshine/sunshine.conf.default

# Enable user services globally
# sunshine.service must be enabled (is-enabled=enabled) because gamescope-session-plus
# checks this before running "systemctl restart --user sunshine.service".
# wait-for-wayland.sh prevents sunshine from connecting before gamescope is ready.
RUN mkdir -p /etc/systemd/user/default.target.wants && \
    ln -sf /etc/systemd/user/gaming-session.service \
        /etc/systemd/user/default.target.wants/gaming-session.service && \
    ln -sf /etc/systemd/user/sunshine.service \
        /etc/systemd/user/default.target.wants/sunshine.service

# Sunshine needs CAP_SYS_ADMIN for DRM capture fallback
RUN setcap 'cap_sys_admin+p' /usr/bin/sunshine || true

# ── systemd container tuning ─────────────────────────────────

RUN systemctl mask \
        systemd-remount-fs.service \
        getty@.service \
        serial-getty@.service \
        systemd-udev-trigger.service \
        fstrim.timer && \
    # Ensure tmpfiles creates XDG_RUNTIME_DIR and fixes volume mount ownership
    printf '%s\n' \
        "d /run/user/${GAMER_UID} 0700 gamer gamer -" \
        "d /home/gamer/.steam 0755 gamer gamer -" \
        "d /home/gamer/.steam/root 0755 gamer gamer -" \
        "d /home/gamer/.steam/root/config 0755 gamer gamer -" \
        "d /home/gamer/.local 0755 gamer gamer -" \
        "d /home/gamer/.local/share 0755 gamer gamer -" \
        "d /home/gamer/.local/share/Steam 0755 gamer gamer -" \
        "d /home/gamer/.config 0755 gamer gamer -" \
        "d /home/gamer/.config/sunshine 0755 gamer gamer -" \
        > /etc/tmpfiles.d/gaming-session.conf && \
    # Fix DRI and uinput device permissions at boot
    # (container user may not match host group IDs)
    printf '%s\n' \
        'z /dev/dri/card* 0666 root root -' \
        'z /dev/dri/renderD* 0666 root root -' \
        'z /dev/uinput 0666 root root -' \
        > /etc/tmpfiles.d/device-permissions.conf

# ── Environment ──────────────────────────────────────────────

ENV CONTAINER_ID=default

# Podman systemd container
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
