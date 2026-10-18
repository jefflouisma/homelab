# Fenrir RetroArch Container
# Custom RetroArch image for Wolf/Moonlight game streaming
# High-quality emulation with cores from libretro buildbot

FROM ghcr.io/games-on-whales/base:edge

LABEL org.opencontainers.image.source="https://github.com/jefflouisma/homelab"
LABEL org.opencontainers.image.description="RetroArch for Fenrir game streaming"

# Install RetroArch and dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    retroarch \
    python3-yaml \
    p7zip-full \
    # Vulkan/GPU support
    vulkan-tools \
    mesa-vulkan-drivers \
    libvulkan1 \
    # Audio
    pulseaudio \
    # Controller support
    joystick \
    # Fonts for UI
    fonts-liberation \
    fonts-noto \
    # Download utilities
    wget \
    unzip \
    git \
    # Dolphin core dependencies (use libXXX-dev for header+runtime, or specific runtime libs)
    libhidapi-hidraw0 \
    libevdev2 \
    libusb-1.0-0 \
    libbluetooth3 \
    libgl1 \
    libxi6 \
    libx11-6 \
    && rm -rf /var/lib/apt/lists/*

ARG UPSTREAM_REFRESH=manual
RUN wget -q https://buildbot.libretro.com/nightly/linux/x86_64/RetroArch_update.7z -O /tmp/retroarch.7z && \
    7z x -y /tmp/retroarch.7z -o/tmp/retroarch-download >/dev/null && \
    chmod +x /tmp/retroarch-download/RetroArch-Linux-x86_64/RetroArch-Linux-x86_64.AppImage && \
    cd /opt && /tmp/retroarch-download/RetroArch-Linux-x86_64/RetroArch-Linux-x86_64.AppImage --appimage-extract >/dev/null && \
    mv squashfs-root retroarch && \
    chmod -R a+rX /opt/retroarch && \
    printf '#!/bin/sh\ncd /opt/retroarch && exec ./AppRun "$@"\n' > /usr/local/bin/retroarch && \
    chmod +x /usr/local/bin/retroarch && \
    rm -rf /tmp/retroarch.7z /tmp/retroarch-download

# Download RetroArch assets from libretro-assets GitHub repo
# These contain the menu icons for Ozone/XMB themes
RUN mkdir -p /usr/share/retroarch/assets && \
    cd /tmp && \
    git clone --depth 1 https://github.com/libretro/retroarch-assets.git && \
    cp -r retroarch-assets/* /usr/share/retroarch/assets/ && \
    rm -rf retroarch-assets

# Create core directory
RUN mkdir -p /usr/lib/libretro

# Download high-quality cores from libretro buildbot
# Using correct filenames verified from https://buildbot.libretro.com/nightly/linux/x86_64/latest/

# PlayStation (mednafen_psx_hw - hardware accelerated, formerly beetle)
RUN wget -q https://buildbot.libretro.com/nightly/linux/x86_64/latest/mednafen_psx_hw_libretro.so.zip -O /tmp/core.zip \
    && unzip -q /tmp/core.zip -d /usr/lib/libretro && rm /tmp/core.zip

# PlayStation 2 (pcsx2)  
RUN wget -q https://buildbot.libretro.com/nightly/linux/x86_64/latest/pcsx2_libretro.so.zip -O /tmp/core.zip \
    && unzip -q /tmp/core.zip -d /usr/lib/libretro && rm /tmp/core.zip

# Nintendo 64 (mupen64plus_next)
RUN wget -q https://buildbot.libretro.com/nightly/linux/x86_64/latest/mupen64plus_next_libretro.so.zip -O /tmp/core.zip \
    && unzip -q /tmp/core.zip -d /usr/lib/libretro && rm /tmp/core.zip

# PSP (ppsspp)
RUN wget -q https://buildbot.libretro.com/nightly/linux/x86_64/latest/ppsspp_libretro.so.zip -O /tmp/core.zip \
    && unzip -q /tmp/core.zip -d /usr/lib/libretro && rm /tmp/core.zip

# Dreamcast (flycast)
RUN wget -q https://buildbot.libretro.com/nightly/linux/x86_64/latest/flycast_libretro.so.zip -O /tmp/core.zip \
    && unzip -q /tmp/core.zip -d /usr/lib/libretro && rm /tmp/core.zip

# GameCube/Wii (dolphin)
RUN wget -q https://buildbot.libretro.com/nightly/linux/x86_64/latest/dolphin_libretro.so.zip -O /tmp/core.zip \
    && unzip -q /tmp/core.zip -d /usr/lib/libretro && rm /tmp/core.zip

# Download Dolphin Sys folder (required for game compatibility)
# Note: /roms is a PVC mount, so we put system files in /usr/share/retroarch/system
RUN mkdir -p /usr/share/retroarch/system/dolphin-emu && \
    git clone --depth 1 https://github.com/dolphin-emu/dolphin.git /tmp/dolphin && \
    cp -r /tmp/dolphin/Data/Sys /usr/share/retroarch/system/dolphin-emu/ && \
    rm -rf /tmp/dolphin

# Nintendo 3DS (citra)
RUN wget -q https://buildbot.libretro.com/nightly/linux/x86_64/latest/citra_libretro.so.zip -O /tmp/core.zip \
    && unzip -q /tmp/core.zip -d /usr/lib/libretro && rm /tmp/core.zip

# Game Boy Advance (mgba)
RUN wget -q https://buildbot.libretro.com/nightly/linux/x86_64/latest/mgba_libretro.so.zip -O /tmp/core.zip \
    && unzip -q /tmp/core.zip -d /usr/lib/libretro && rm /tmp/core.zip

# Super Nintendo (snes9x)
RUN wget -q https://buildbot.libretro.com/nightly/linux/x86_64/latest/snes9x_libretro.so.zip -O /tmp/core.zip \
    && unzip -q /tmp/core.zip -d /usr/lib/libretro && rm /tmp/core.zip

# NES (mesen)
RUN wget -q https://buildbot.libretro.com/nightly/linux/x86_64/latest/mesen_libretro.so.zip -O /tmp/core.zip \
    && unzip -q /tmp/core.zip -d /usr/lib/libretro && rm /tmp/core.zip

# Nintendo DS (melonDS)
RUN wget -q https://buildbot.libretro.com/nightly/linux/x86_64/latest/melonds_libretro.so.zip -O /tmp/core.zip \
    && unzip -q /tmp/core.zip -d /usr/lib/libretro && rm /tmp/core.zip

# Sega Genesis (genesis_plus_gx)
RUN wget -q https://buildbot.libretro.com/nightly/linux/x86_64/latest/genesis_plus_gx_libretro.so.zip -O /tmp/core.zip \
    && unzip -q /tmp/core.zip -d /usr/lib/libretro && rm /tmp/core.zip

# Saturn (mednafen_saturn) 
RUN wget -q https://buildbot.libretro.com/nightly/linux/x86_64/latest/mednafen_saturn_libretro.so.zip -O /tmp/core.zip \
    && unzip -q /tmp/core.zip -d /usr/lib/libretro && rm /tmp/core.zip

# Arcade (FinalBurn Neo)
RUN wget -q https://buildbot.libretro.com/nightly/linux/x86_64/latest/fbneo_libretro.so.zip -O /tmp/core.zip \
    && unzip -q /tmp/core.zip -d /usr/lib/libretro && rm /tmp/core.zip

# Set permissions on cores
RUN chmod +x /usr/lib/libretro/*.so

COPY emudeck/stream_scaling.py emudeck/probe-core-options.py /usr/local/bin/
RUN python3 /usr/local/bin/probe-core-options.py /usr/lib/libretro /etc/stream-core-options.json

# Download core info files (.info) for proper core detection
RUN git clone --depth 1 https://github.com/libretro/libretro-core-info.git /tmp/info && \
    mkdir -p /usr/share/retroarch/info && \
    cp /tmp/info/*.info /usr/share/retroarch/info/ && \
    rm -rf /tmp/info

# Download database files (.rdb) for content scanning
RUN git clone --depth 1 https://github.com/libretro/libretro-database.git /tmp/db && \
    mkdir -p /usr/share/retroarch/database && \
    cp -r /tmp/db/rdb /usr/share/retroarch/database/ && \
    rm -rf /tmp/db

# Create directories
RUN mkdir -p /roms /saves /config /screenshots /config/playlists

# Copy startup script that waits for Wayland display
COPY retroarch/startup.sh /usr/local/bin/startup.sh
RUN chmod +x /usr/local/bin/startup.sh

# Copy default configuration
COPY retroarch/config/retroarch.cfg /root/.config/retroarch/retroarch.cfg

# Copy Wolf virtual Xbox controller autoconfig profiles
# Supports both linuxraw and sdl2 drivers for backwards compatibility
COPY retroarch/autoconfig/linuxraw/ /usr/share/retroarch/autoconfig/linuxraw/
COPY retroarch/autoconfig/sdl2/ /usr/share/retroarch/autoconfig/sdl2/

# Environment for Wolf/Wayland streaming
ENV XDG_RUNTIME_DIR=/tmp/runtime-root
ENV WAYLAND_DISPLAY=wayland-0
ENV PULSE_SERVER=unix:/tmp/pulse/native
ENV LD_LIBRARY_PATH=/nvidia-libs:/usr/local/cuda/lib64

# Run as non-root user for security (matches Wolf expectations)
USER ubuntu
RUN retroarch --version

# Default command - use startup script that waits for display
CMD ["/usr/local/bin/startup.sh"]
