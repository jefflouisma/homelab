# Fenrir EmuDeck Container
# ES-DE frontend + standalone emulators via AppImage Extract Pattern
# + RetroArch cores for retro systems
# Zero Flatpak dependencies — container-native design

FROM ghcr.io/games-on-whales/base:edge

LABEL org.opencontainers.image.source="https://github.com/jefflouisma/homelab"
LABEL org.opencontainers.image.description="EmuDeck for Fenrir game streaming (ES-DE + standalone emulators)"

# =============================================================================
# Version pinning — bump these ARGs for easy updates
# =============================================================================
ARG ESDE_VERSION=3.5.0
ARG PCSX2_VERSION=2.8.2
ARG PPSSPP_VERSION=1.20.4
ARG SHADPS4_VERSION=0.20.0
# DuckStation and RPCS3 use rolling/latest releases

# =============================================================================
# Stage 1: System dependencies
# =============================================================================
RUN apt-get update && apt-get install -y --no-install-recommends \
    # RetroArch
    retroarch \
    p7zip-full \
    # Vulkan/GPU support
    vulkan-tools \
    mesa-vulkan-drivers \
    libvulkan1 \
    # Audio
    pulseaudio \
    # Controller support (udev needed for hotplug detection of Wolf virtual gamepads)
    udev \
    joystick \
    # Fonts for UI
    fonts-liberation \
    fonts-noto \
    # Download utilities
    wget \
    unzip \
    git \
    curl \
    # AppImage extraction (unsquashfs for cross-build compat)
    squashfs-tools \
    python3-minimal \
    python3-yaml \
    patchelf \
    file \
    # Dolphin core dependencies
    libhidapi-hidraw0 \
    libevdev2 \
    libusb-1.0-0 \
    libbluetooth3 \
    libgl1 \
    libxi6 \
    libx11-6 \
    # Standalone emulator shared dependencies
    libsdl2-2.0-0 \
    libqt6widgets6 \
    libqt6gui6 \
    libqt6core6 \
    libqt6network6 \
    libqt6svg6 \
    qt6-qpa-plugins \
    libxkbcommon0 \
    libwayland-client0 \
    libwayland-egl1 \
    libegl1 \
    libgles2 \
    && rm -rf /var/lib/apt/lists/*

# Copy AppImage extraction helper (supports both squashfs and DwarFS)
COPY extract-appimage.sh /usr/local/bin/extract-appimage
RUN chmod +x /usr/local/bin/extract-appimage

# DwarFS extractor for AppImages that use DwarFS (e.g. PPSSPP)
ARG DWARFS_VERSION=0.14.1
RUN wget -q "https://github.com/mhx/dwarfs/releases/download/v${DWARFS_VERSION}/dwarfs-fuse-extract-${DWARFS_VERSION}-Linux-x86_64" \
      -O /usr/local/bin/dwarfsextract && \
    chmod +x /usr/local/bin/dwarfsextract

# =============================================================================
# Stage 2: ES-DE Frontend (AppImage extract)
# =============================================================================
RUN mkdir -p /Volumes/4TB_Drive/tmp && \
    ESDE_URL="$(wget -qO- "https://gitlab.com/api/v4/projects/18817634/releases/v${ESDE_VERSION}" | \
      python3 -c 'import json,sys; print(next(a["url"] for a in json.load(sys.stdin)["assets"]["links"] if a["name"] == "ES-DE_x64.AppImage"))')" && \
    wget -q "$ESDE_URL" -O /Volumes/4TB_Drive/tmp/esde.AppImage && \
    extract-appimage /Volumes/4TB_Drive/tmp/esde.AppImage /opt/es-de && \
    rm -f /Volumes/4TB_Drive/tmp/esde.AppImage

COPY --chmod=755 es-de.sh /usr/local/bin/es-de
COPY --chmod=755 package-path.py /usr/local/bin/package-path
COPY --chmod=755 kytyps5.sh /usr/local/bin/kytyps5
COPY --chmod=755 generate-ps5-shortcuts.py /usr/local/bin/generate-ps5-shortcuts

ARG UPSTREAM_REFRESH=manual
RUN wget -q https://buildbot.libretro.com/nightly/linux/x86_64/RetroArch_update.7z -O /tmp/retroarch.7z && \
    7z x -y /tmp/retroarch.7z -o/tmp/retroarch-download >/dev/null && \
    extract-appimage /tmp/retroarch-download/RetroArch-Linux-x86_64/RetroArch-Linux-x86_64.AppImage /opt/retroarch && \
    chmod -R a+rX /opt/retroarch && \
    printf '#!/bin/sh\ncd /opt/retroarch && exec ./AppRun "$@"\n' > /usr/local/bin/retroarch && \
    chmod +x /usr/local/bin/retroarch && \
    rm -rf /tmp/retroarch.7z /tmp/retroarch-download

# =============================================================================
# Stage 3: RetroArch cores from libretro buildbot
# =============================================================================
RUN mkdir -p /usr/lib/libretro

# PS1 (mednafen_psx_hw - hardware accelerated)
RUN wget -q https://buildbot.libretro.com/nightly/linux/x86_64/latest/mednafen_psx_hw_libretro.so.zip -O /tmp/core.zip \
    && unzip -q /tmp/core.zip -d /usr/lib/libretro && rm /tmp/core.zip

# PS2 (pcsx2 libretro core as fallback)
RUN wget -q https://buildbot.libretro.com/nightly/linux/x86_64/latest/pcsx2_libretro.so.zip -O /tmp/core.zip \
    && unzip -q /tmp/core.zip -d /usr/lib/libretro && rm /tmp/core.zip

# N64 (mupen64plus_next)
RUN wget -q https://buildbot.libretro.com/nightly/linux/x86_64/latest/mupen64plus_next_libretro.so.zip -O /tmp/core.zip \
    && unzip -q /tmp/core.zip -d /usr/lib/libretro && rm /tmp/core.zip

# PSP (ppsspp libretro core as fallback)
RUN wget -q https://buildbot.libretro.com/nightly/linux/x86_64/latest/ppsspp_libretro.so.zip -O /tmp/core.zip \
    && unzip -q /tmp/core.zip -d /usr/lib/libretro && rm /tmp/core.zip

# Dreamcast (flycast)
RUN wget -q https://buildbot.libretro.com/nightly/linux/x86_64/latest/flycast_libretro.so.zip -O /tmp/core.zip \
    && unzip -q /tmp/core.zip -d /usr/lib/libretro && rm /tmp/core.zip

# GameCube/Wii (dolphin)
RUN wget -q https://buildbot.libretro.com/nightly/linux/x86_64/latest/dolphin_libretro.so.zip -O /tmp/core.zip \
    && unzip -q /tmp/core.zip -d /usr/lib/libretro && rm /tmp/core.zip

# Dolphin Sys folder (required for game compatibility)
RUN mkdir -p /usr/share/retroarch/system/dolphin-emu && \
    git clone --depth 1 https://github.com/dolphin-emu/dolphin.git /tmp/dolphin && \
    cp -r /tmp/dolphin/Data/Sys /usr/share/retroarch/system/dolphin-emu/ && \
    rm -rf /tmp/dolphin

# 3DS (citra)
RUN wget -q https://buildbot.libretro.com/nightly/linux/x86_64/latest/citra_libretro.so.zip -O /tmp/core.zip \
    && unzip -q /tmp/core.zip -d /usr/lib/libretro && rm /tmp/core.zip

# GBA (mgba)
RUN wget -q https://buildbot.libretro.com/nightly/linux/x86_64/latest/mgba_libretro.so.zip -O /tmp/core.zip \
    && unzip -q /tmp/core.zip -d /usr/lib/libretro && rm /tmp/core.zip

# SNES (snes9x)
RUN wget -q https://buildbot.libretro.com/nightly/linux/x86_64/latest/snes9x_libretro.so.zip -O /tmp/core.zip \
    && unzip -q /tmp/core.zip -d /usr/lib/libretro && rm /tmp/core.zip

# NES (mesen)
RUN wget -q https://buildbot.libretro.com/nightly/linux/x86_64/latest/mesen_libretro.so.zip -O /tmp/core.zip \
    && unzip -q /tmp/core.zip -d /usr/lib/libretro && rm /tmp/core.zip

# DS (melonDS)
RUN wget -q https://buildbot.libretro.com/nightly/linux/x86_64/latest/melonds_libretro.so.zip -O /tmp/core.zip \
    && unzip -q /tmp/core.zip -d /usr/lib/libretro && rm /tmp/core.zip

# Genesis (genesis_plus_gx)
RUN wget -q https://buildbot.libretro.com/nightly/linux/x86_64/latest/genesis_plus_gx_libretro.so.zip -O /tmp/core.zip \
    && unzip -q /tmp/core.zip -d /usr/lib/libretro && rm /tmp/core.zip

# Saturn (mednafen_saturn)
RUN wget -q https://buildbot.libretro.com/nightly/linux/x86_64/latest/mednafen_saturn_libretro.so.zip -O /tmp/core.zip \
    && unzip -q /tmp/core.zip -d /usr/lib/libretro && rm /tmp/core.zip

# Arcade (FinalBurn Neo)
RUN wget -q https://buildbot.libretro.com/nightly/linux/x86_64/latest/fbneo_libretro.so.zip -O /tmp/core.zip \
    && unzip -q /tmp/core.zip -d /usr/lib/libretro && rm /tmp/core.zip

RUN chmod +x /usr/lib/libretro/*.so

# melonDS omits GNU-stack metadata in x64 assembly; glibc 2.41 rejects its executable-stack flag.
RUN patchelf --clear-execstack /usr/lib/libretro/melonds_libretro.so

COPY probe-core-options.py /usr/local/bin/probe-core-options.py
RUN TMPDIR=/Volumes/4TB_Drive/tmp python3 /usr/local/bin/probe-core-options.py /usr/lib/libretro /etc/stream-core-options.json

# RetroArch assets, core info, and databases
RUN mkdir -p /usr/share/retroarch/assets && \
    cd /tmp && \
    git clone --depth 1 https://github.com/libretro/retroarch-assets.git && \
    cp -r retroarch-assets/* /usr/share/retroarch/assets/ && \
    rm -rf retroarch-assets

RUN git clone --depth 1 https://github.com/libretro/libretro-core-info.git /tmp/info && \
    mkdir -p /usr/share/retroarch/info && \
    cp /tmp/info/*.info /usr/share/retroarch/info/ && \
    rm -rf /tmp/info

RUN git clone --depth 1 https://github.com/libretro/libretro-database.git /tmp/db && \
    mkdir -p /usr/share/retroarch/database && \
    cp -r /tmp/db/rdb /usr/share/retroarch/database/ && \
    rm -rf /tmp/db

# =============================================================================
# Stage 4: Standalone emulators (AppImage Extract Pattern)
# =============================================================================

# PCSX2 (PS2) — AppImage
RUN wget -q "https://github.com/PCSX2/pcsx2/releases/download/v${PCSX2_VERSION}/pcsx2-v${PCSX2_VERSION}-linux-appimage-x64-Qt.AppImage" \
      -O /tmp/pcsx2.AppImage && \
    extract-appimage /tmp/pcsx2.AppImage /opt/pcsx2 && \
    printf '#!/bin/sh\nexport LD_LIBRARY_PATH=/opt/pcsx2/usr/lib:$LD_LIBRARY_PATH\ncd /opt/pcsx2 && exec ./AppRun "$@"\n' > /usr/local/bin/pcsx2-qt && \
    chmod +x /usr/local/bin/pcsx2-qt && \
    rm -f /tmp/pcsx2.AppImage

# DuckStation (PS1) — AppImage (rolling release)
RUN wget -q "https://github.com/stenzek/duckstation/releases/download/latest/DuckStation-x64.AppImage" \
      -O /tmp/duckstation.AppImage && \
    extract-appimage /tmp/duckstation.AppImage /opt/duckstation && \
    printf '#!/bin/sh\nexport LD_LIBRARY_PATH=/opt/duckstation/usr/lib:$LD_LIBRARY_PATH\ncd /opt/duckstation && exec ./AppRun "$@"\n' > /usr/local/bin/duckstation-qt && \
    chmod +x /usr/local/bin/duckstation-qt && \
    rm -f /tmp/duckstation.AppImage

# PPSSPP (PSP) — AppImage
RUN wget -q "https://github.com/hrydgard/ppsspp/releases/download/v${PPSSPP_VERSION}/PPSSPP-v${PPSSPP_VERSION}-anylinux-x86_64.AppImage" \
      -O /tmp/ppsspp.AppImage && \
    extract-appimage /tmp/ppsspp.AppImage /opt/ppsspp && \
    printf '#!/bin/sh\nexport LD_LIBRARY_PATH=/opt/ppsspp/usr/lib:$LD_LIBRARY_PATH\ncd /opt/ppsspp && exec ./AppRun "$@"\n' > /usr/local/bin/PPSSPPSDL && \
    chmod +x /usr/local/bin/PPSSPPSDL && \
    rm -f /tmp/ppsspp.AppImage

# RPCS3 (PS3) — AppImage (rolling release from rpcs3-binaries-linux)
RUN RPCS3_URL=$(wget -qO- "https://api.github.com/repos/RPCS3/rpcs3-binaries-linux/releases/latest" | \
      grep -oP '"browser_download_url":\s*"\K[^"]+\.AppImage') && \
    wget -q "$RPCS3_URL" -O /tmp/rpcs3.AppImage && \
    extract-appimage /tmp/rpcs3.AppImage /opt/rpcs3 && \
    printf '#!/bin/sh\nexport LD_LIBRARY_PATH=/opt/rpcs3/usr/lib:$LD_LIBRARY_PATH\ncd /opt/rpcs3 && exec ./AppRun "$@"\n' > /usr/local/bin/rpcs3 && \
    chmod +x /usr/local/bin/rpcs3 && \
    rm -f /tmp/rpcs3.AppImage

# shadPS4 (PS4) — zip contains an AppImage (tag format: v.X.Y.Z)
RUN wget -q "https://github.com/shadps4-emu/shadPS4/releases/download/v.${SHADPS4_VERSION}/shadps4-linux-sdl-${SHADPS4_VERSION}.zip" \
      -O /tmp/shadps4.zip && \
    unzip -q /tmp/shadps4.zip -d /tmp/shadps4-extract && \
    extract-appimage /tmp/shadps4-extract/Shadps4-sdl.AppImage /opt/shadps4 && \
    printf '#!/bin/sh\nexport LD_LIBRARY_PATH=/opt/shadps4/usr/lib:$LD_LIBRARY_PATH\ncd /opt/shadps4 && exec ./AppRun "$@"\n' > /usr/local/bin/shadps4 && \
    chmod +x /usr/local/bin/shadps4 && \
    rm -rf /tmp/shadps4.zip /tmp/shadps4-extract

# =============================================================================
# Stage 5: Directory structure & configuration
# =============================================================================

# Create the EmuDeck-style directory structure (PVC mount points)
RUN mkdir -p /Emulation/roms /Emulation/bios /Emulation/saves /Emulation/storage \
    /config /screenshots

# Create ROM subdirectories for all systems ES-DE expects
RUN mkdir -p \
    /Emulation/roms/nes /Emulation/roms/snes /Emulation/roms/n64 \
    /Emulation/roms/gba /Emulation/roms/gbc /Emulation/roms/gb \
    /Emulation/roms/nds /Emulation/roms/3ds \
    /Emulation/roms/psx /Emulation/roms/ps2 /Emulation/roms/ps3 \
    /Emulation/roms/psp /Emulation/roms/ps4 \
    /Emulation/roms/gc /Emulation/roms/wii \
    /Emulation/roms/dreamcast /Emulation/roms/saturn \
    /Emulation/roms/genesis /Emulation/roms/megadrive \
    /Emulation/roms/segacd /Emulation/roms/sega32x \
    /Emulation/roms/arcade /Emulation/roms/fbneo \
    /Emulation/roms/mame

# Copy startup script
COPY startup.sh /usr/local/bin/startup.sh
RUN chmod +x /usr/local/bin/startup.sh
COPY --chmod=755 prepare-ps3-firmware.sh /usr/local/bin/prepare-ps3-firmware
COPY --chmod=755 prepare-console-display.py /usr/local/bin/prepare-console-display
COPY stream_scaling.py /usr/local/bin/stream_scaling.py

# Copy PS4 game name resolution script
COPY generate-ps4-shortcuts.sh /usr/local/bin/generate-ps4-shortcuts.sh
RUN chmod +x /usr/local/bin/generate-ps4-shortcuts.sh

# Copy RetroArch configuration
COPY config/retroarch.cfg /etc/retroarch.cfg

# Copy Wolf virtual Xbox controller autoconfig profiles
COPY autoconfig/sdl2/ /usr/share/retroarch/autoconfig/sdl2/
COPY autoconfig/linuxraw/ /usr/share/retroarch/autoconfig/linuxraw/

# Copy ES-DE configuration
COPY config/es_settings.xml /etc/es-de/es_settings.xml
COPY config/custom_systems/ /etc/es-de/custom_systems/

# =============================================================================
# Stage 6: Environment & entry point
# =============================================================================
ENV XDG_RUNTIME_DIR=/tmp/runtime-root
ENV WAYLAND_DISPLAY=wayland-0
ENV PULSE_SERVER=unix:/tmp/pulse/native
ENV LD_LIBRARY_PATH=/nvidia-libs:/usr/local/cuda/lib64
ENV HOME=/home/retro

# Create non-root user matching Wolf expectations
RUN if ! id retro >/dev/null 2>&1; then \
      if getent passwd 1000 >/dev/null; then \
        usermod --login retro --home /home/retro "$(getent passwd 1000 | cut -d: -f1)"; \
      else \
        useradd -m -d /home/retro -s /bin/bash -u 1000 retro; \
      fi; \
    fi && mkdir -p /home/retro && chown 1000:1000 /home/retro

RUN mkdir -p /Volumes/4TB_Drive/tmp/fenrir-session /Volumes/4TB_Drive/tmp/kytyps5 && \
    chown -R 1000:1000 /Volumes/4TB_Drive/tmp
USER retro
RUN retroarch --version

CMD ["/usr/local/bin/startup.sh"]
