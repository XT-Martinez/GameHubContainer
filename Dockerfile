# syntax=docker/dockerfile:1
#
# Sunshine + Gamescope + Steam container image
# Fedora 44 base with Valve's patched Mesa/PipeWire from Bazzite COPRs
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

ARG FEDORA_VERSION=44

# ============================================================
# Common base with fast mirrors
# ============================================================
FROM fedora:${FEDORA_VERSION} AS base

RUN printf '%s\n' \
    'fastestmirror=True' \
    'max_parallel_downloads=20' \
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
    -Denable_tests=false \
    && ninja -C builddir \
    && DESTDIR=/build/install ninja -C builddir install

# ============================================================
# Stage 2: Build Sunshine
# ============================================================
FROM base AS sunshine-builder

RUN --mount=type=cache,dst=/var/cache/libdnf5 \
    dnf5 -y install \
    cmake gcc gcc-c++ libstdc++-static git wget which \
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

ENV CC=gcc CXX=g++

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
    -DSUNSHINE_ENABLE_KWIN=OFF \
    -DSUNSHINE_ENABLE_PORTAL=ON \
    -DSUNSHINE_ENABLE_WAYLAND=ON \
    -DSUNSHINE_ENABLE_X11=ON \
    -DSUNSHINE_ENABLE_TRAY=OFF \
    -DSUNSHINE_BUILD_FLATPAK=OFF \
    && make -j$(nproc) -C build \
    && DESTDIR=/build/install make -C build install

# ============================================================
# Stage 3: Build uinput shim + mknod daemon
# ============================================================
FROM base AS shim-builder

RUN dnf5 -y install gcc glibc-devel.i686 kernel-headers libatomic libatomic.i686 libgcc.i686 make systemd-devel

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
    'max_parallel_downloads=20' \
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
    # mirrors.rpmfusion.org redirects to a random mirror with no retry; fall back
    # to a fixed mirror when the redirect target is unreachable.
    for base in https://mirrors.rpmfusion.org https://mirror.math.princeton.edu/pub/rpmfusion; do \
        dnf5 -y install \
            $base/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm \
            $base/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm && break; \
    done && \
    rpm -q rpmfusion-free-release rpmfusion-nonfree-release && \
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
        gamescope.x86_64

# ── Gamescope session management ──────────────────────────────
RUN --mount=type=cache,dst=/var/cache/libdnf5 \
    dnf5 -y install \
        switcheroo-control \
        gamescope-session \
        gamescope-session-steam && \
    mkdir -p /usr/share/gamescope-session-plus/ && \
    curl --retry 3 -Lo /usr/share/gamescope-session-plus/bootstrap_steam.tar.gz \
        https://large-package-sources.nobaraproject.org/bootstrap_steam.tar.gz && \
    if [ -d /usr/share/gamescope-session ] && [ ! -e /usr/share/gamescope-session-plus/sessions.d ]; then \
        ln -s /usr/share/gamescope-session/sessions.d /usr/share/gamescope-session-plus/sessions.d; \
    fi && \
    if ! command -v gamescope-session-plus >/dev/null && command -v gamescope-session >/dev/null; then \
        printf '%s\n' '#!/bin/sh' 'exec gamescope-session "$@"' > /usr/local/bin/gamescope-session-plus && \
        chmod +x /usr/local/bin/gamescope-session-plus; \
    fi && \
    if [ -f /usr/lib/systemd/user/gamescope-session@.service ] && \
       [ ! -e /etc/systemd/user/gamescope-session-plus@.service ]; then \
        mkdir -p /etc/systemd/user && \
        ln -s /usr/lib/systemd/user/gamescope-session@.service \
            /etc/systemd/user/gamescope-session-plus@.service; \
    fi

# ── Steam ─────────────────────────────────────────────────────
# Steam's 32-bit updater binary needs i686 Mesa GL libraries to render its
# update UI (fonts + GL context). The "*fedora*".exclude="mesa-*" above blocks
# ALL mesa packages including i686, so we explicitly install the 32-bit ones
# first with the exclude disabled.
RUN --mount=type=cache,dst=/var/cache/libdnf5 \
    dnf5 -y --setopt="*fedora*".exclude="" install \
        mesa-libGL.i686 \
        mesa-libEGL.i686 \
        mesa-dri-drivers.i686 \
        mesa-libgbm.i686 && \
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
        labwc waybar wofi swaybg mako foot fuzzel \
        thunar gvfs xfconf tumbler firefox \
        adwaita-icon-theme papirus-icon-theme \
        grim slurp wl-clipboard xdg-utils \
        # Input
        libevdev libinput hidapi \
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
        # Networking (SteamOS OOBE requires NetworkManager D-Bus API)
        NetworkManager iproute \
        # System
        systemd acl \
        which evtest procps-ng util-linux \
        # switcherooctl needs PyGObject
        python3-gobject \
        # Steam runtime needs locale and hw detection
        glibc-langpack-en pciutils \
        # SDL controller database
        && \
    # Heroic Games Launcher (Epic/GOG/Amazon)
    dnf5 -y copr enable atim/heroic-games-launcher && \
    dnf5 -y install heroic-games-launcher-bin && \
    mkdir -p /usr/share/sdl/ && \
    curl --retry 3 -Lo /usr/share/sdl/gamecontrollerdb.txt \
        https://raw.githubusercontent.com/mdqinc/SDL_GameControllerDB/refs/heads/master/gamecontrollerdb.txt && \
    rm -f \
        /usr/share/dbus-1/services/fr.emersion.mako.service \
        /etc/xdg/autostart/mako.desktop \
        /etc/xdg/autostart/fr.emersion.mako.desktop \
        /usr/share/applications/fr.emersion.mako.desktop

# ── Overlay custom-built binaries ─────────────────────────────

# Custom gamescope (replaces COPR version)
COPY --from=gamescope-builder /build/install/ /

# Custom Sunshine
COPY --from=sunshine-builder /build/install/ /

# uinput isolation shim (phys tagging) + mknod daemon (device node creation)
COPY --from=shim-builder /build/libuinput_shim.so /usr/lib64/libuinput_shim.so
COPY --from=shim-builder /build/libuinput_shim32.so /usr/lib/libuinput_shim.so
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
COPY desktop-session/bin/ /usr/local/bin/
COPY desktop-session/labwc/ /usr/share/gamehub-desktop/labwc/
COPY desktop-session/waybar/ /usr/share/gamehub-desktop/waybar/
COPY desktop-session/wofi/ /usr/share/gamehub-desktop/wofi/
COPY desktop-session/mako/ /usr/share/gamehub-desktop/mako/
COPY desktop-session/foot/ /usr/share/gamehub-desktop/foot/
COPY desktop-session/fuzzel/ /usr/share/gamehub-desktop/fuzzel/
COPY desktop-session/assets/ /usr/share/gamehub-desktop/assets/
COPY desktop-session/themes/GameHub/ /usr/share/themes/GameHub/
COPY desktop-session/applications/ /usr/share/applications/
COPY desktop-session/gamescope-session-plus/steam /usr/share/gamehub-desktop/steam.session
RUN mkdir -p /usr/share/applications/steam && \
    mkdir -p /etc/gamescope-session-plus/sessions.d && \
    cp /usr/share/applications/gamehub-switch-to-desktop.desktop \
       /usr/share/applications/steam/gamehub-switch-to-desktop.desktop && \
    install -m 0644 /usr/share/gamehub-desktop/steam.session \
       /etc/gamescope-session-plus/sessions.d/steam && \
    ln -sf /usr/local/bin/steamos-session-select /usr/bin/steamos-session-select && \
    ln -sf /usr/local/bin/return-to-gamemode /usr/bin/return-to-gamemode && \
    chmod +x /usr/local/bin/*.sh /usr/local/bin/steam /usr/local/bin/session-supervisor.sh /usr/local/bin/start-desktop-session.sh /usr/local/bin/desktop-launcher.sh /usr/local/bin/desktop-steam.sh /usr/local/bin/switch-to-desktop.sh /usr/local/bin/return-to-steam.sh /usr/local/bin/steamos-session-select /usr/local/bin/return-to-gamemode /usr/share/gamehub-desktop/labwc/autostart

# Install system services (need real root for mknod/chmod in rootless podman)
COPY services/device-permissions.service /etc/systemd/system/device-permissions.service
COPY services/input-mknod.service /etc/systemd/system/input-mknod.service
COPY services/container-env.service /etc/systemd/system/container-env.service
RUN mkdir -p /etc/systemd/system/multi-user.target.wants && \
    ln -sf /etc/systemd/system/device-permissions.service \
        /etc/systemd/system/multi-user.target.wants/device-permissions.service && \
    ln -sf /etc/systemd/system/input-mknod.service \
        /etc/systemd/system/multi-user.target.wants/input-mknod.service && \
    ln -sf /etc/systemd/system/container-env.service \
        /etc/systemd/system/multi-user.target.wants/container-env.service && \
    ln -sf /usr/lib/systemd/system/NetworkManager.service \
        /etc/systemd/system/multi-user.target.wants/NetworkManager.service

# Default Sunshine config (system location — copied to user dir on first start)
COPY configs/sunshine.conf /etc/sunshine/sunshine.conf.default

# Add drop-ins for gamescope-session-plus (vendor unit has no Restart= or env).
# The environment drop-in ensures LIBSEAT_BACKEND=noop and other critical vars
# are set on the FIRST start, not just after gaming-session.service's set-environment
# runs (which is a race). Container-specific vars come from /run/container.env
# (written by container-env.service before user sessions start).
RUN mkdir -p /etc/systemd/user/gamescope-session-plus@steam.service.d && \
    printf '%s\n' \
        '[Service]' \
        'Restart=on-failure' \
        'RestartSec=5' \
        '' \
        '[Unit]' \
        'StartLimitIntervalSec=300' \
        'StartLimitBurst=10' \
        > /etc/systemd/user/gamescope-session-plus@steam.service.d/restart.conf && \
    printf '%s\n' \
        '[Service]' \
        'EnvironmentFile=-/run/container.env' \
        'Environment=LIBSEAT_BACKEND=noop' \
        'Environment=WLR_BACKENDS=headless' \
        'Environment=BACKEND=headless' \
        'Environment=ENABLE_GAMESCOPE_HDR=1' \
        'Environment=ENABLE_GAMESCOPE_WSI=1' \
        'Environment=GAMESCOPE_PATCHED_EDID_FILE=/run/user/1000/gamescope-edid.bin' \
        'Environment=DXVK_HDR=1' \
        'Environment=ENABLE_HDR_WSI=1' \
        > /etc/systemd/user/gamescope-session-plus@steam.service.d/container-env.conf

# Enable user services globally
# sunshine.service must be enabled (is-enabled=enabled) because gamescope-session-plus
# checks this before running "systemctl restart --user sunshine.service".
# wait-for-wayland.sh prevents sunshine from connecting before gamescope is ready.
RUN mkdir -p /etc/systemd/user/default.target.wants && \
    ln -sf /etc/systemd/user/gaming-session.service \
        /etc/systemd/user/default.target.wants/gaming-session.service && \
    ln -sf /etc/systemd/user/sunshine.service \
        /etc/systemd/user/default.target.wants/sunshine.service

# Do NOT give /usr/bin/sunshine file capabilities (setcap). A binary with file
# caps runs in secure-exec mode, where glibc ignores LD_PRELOAD paths containing
# a slash, so libuinput_shim.so would not load: Sunshine's virtual keyboard, mouse,
# touch and pen devices would then be untagged, visible to the host desktop and
# never bound into the container's /dev/input. The caps were only for KMS capture,
# which this image does not use (gamescope scanout capture needs no privileges).

# ── systemd container tuning ─────────────────────────────────

RUN systemctl mask \
        systemd-remount-fs.service \
        getty@.service \
        serial-getty@.service \
        systemd-udev-trigger.service \
        fstrim.timer && \
    # rtkit needs CAP_SYS_NICE (granted only in rootful mode; rootless cannot
    # do realtime scheduling). Skip it cleanly instead of crash-looping.
    mkdir -p /etc/systemd/system/rtkit-daemon.service.d && \
    printf '%s\n' '[Unit]' 'ConditionCapability=CAP_SYS_NICE' \
        > /etc/systemd/system/rtkit-daemon.service.d/container.conf && \
    # Ensure tmpfiles creates XDG_RUNTIME_DIR and fixes volume mount ownership
    printf '%s\n' \
        "d /run/user/${GAMER_UID} 0700 gamer gamer -" \
        "d /home/gamer/.steam 0755 gamer gamer -" \
        "d /home/gamer/.local 0755 gamer gamer -" \
        "d /home/gamer/.local/share 0755 gamer gamer -" \
        "d /home/gamer/.local/share/Steam 0755 gamer gamer -" \
        "d /home/gamer/.local/share/Steam/config 0755 gamer gamer -" \
        "L+ /home/gamer/.steam/root - - - - /home/gamer/.local/share/Steam" \
        "L+ /home/gamer/.steam/steam - - - - /home/gamer/.local/share/Steam" \
        "d /home/gamer/.config 0755 gamer gamer -" \
        "d /home/gamer/.config/sunshine 0755 gamer gamer -" \
        > /etc/tmpfiles.d/gaming-session.conf && \
    # Fix DRI and uinput device permissions at boot
    # (container user may not match host group IDs)
    printf '%s\n' \
        'z /dev/dri/card* 0666 root root -' \
        'z /dev/dri/renderD* 0666 root root -' \
        'z /dev/uinput 0666 root root -' \
        > /etc/tmpfiles.d/device-permissions.conf && \
    # Ensure /run/udev structure exists for fake udev DB (no udevd needed)
    # The mknod daemon populates /run/udev/data/ and sends netlink events
    printf '%s\n' \
        'd /run/udev 0755 root root -' \
        'd /run/udev/data 0755 root root -' \
        'f /run/udev/control 0644 root root -' \
        > /etc/tmpfiles.d/fake-udev.conf

# ── Environment ──────────────────────────────────────────────

ENV CONTAINER_ID=default
# Sunshine base port (controls all Sunshine ports: HTTP, HTTPS, RTSP, video, audio, etc.)
# Set to match the external port mapping for Moonlight pairing to work correctly.
# Leave empty to use Sunshine's default (47989).
ENV SUNSHINE_PORT=

# Podman systemd container
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
