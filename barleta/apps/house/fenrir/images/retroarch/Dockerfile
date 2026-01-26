# Fenrir RetroArch Container
# Custom RetroArch image for Wolf/Moonlight game streaming
# High-quality emulation with cores from libretro buildbot

FROM ghcr.io/games-on-whales/base:edge

LABEL org.opencontainers.image.source="https://github.com/jefflouisma/homelab"
LABEL org.opencontainers.image.description="RetroArch for Fenrir game streaming"

# Install RetroArch and dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    retroarch \
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
    # Dolphin core dependencies
    libhidapi-hidraw0 \
    libenet7 \
    libfmt9 \
    libevdev2 \
    libusb-1.0-0 \
    libbluetooth3 \
    libgl1-mesa-glx \
    libxi6 \
    libx11-6 \
    && rm -rf /var/lib/apt/lists/*

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
RUN mkdir -p /roms/system/dolphin-emu && \
    git clone --depth 1 https://github.com/dolphin-emu/dolphin.git /tmp/dolphin && \
    cp -r /tmp/dolphin/Data/Sys /roms/system/dolphin-emu/ && \
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
COPY startup.sh /usr/local/bin/startup.sh
RUN chmod +x /usr/local/bin/startup.sh

# Copy default configuration
COPY config/retroarch.cfg /root/.config/retroarch/retroarch.cfg

# Environment for Wolf/Wayland streaming
ENV XDG_RUNTIME_DIR=/tmp/runtime-root
ENV WAYLAND_DISPLAY=wayland-0
ENV PULSE_SERVER=unix:/tmp/pulse/native
ENV LD_LIBRARY_PATH=/nvidia-libs:/usr/local/cuda/lib64

# Run as non-root user for security (matches Wolf expectations)
USER ubuntu

# Default command - use startup script that waits for display
CMD ["/usr/local/bin/startup.sh"]
