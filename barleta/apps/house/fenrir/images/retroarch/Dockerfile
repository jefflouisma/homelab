# Fenrir RetroArch Container
# Custom RetroArch image for Wolf/Moonlight game streaming
# Based on games-on-whales gst-wayland-display for Wolf compatibility

FROM ghcr.io/games-on-whales/base:edge

LABEL org.opencontainers.image.source="https://github.com/jefflouisma/homelab"
LABEL org.opencontainers.image.description="RetroArch for Fenrir game streaming"

# Install RetroArch and popular cores
RUN apt-get update && apt-get install -y --no-install-recommends \
    # RetroArch core
    retroarch \
    # Popular cores - console emulation
    libretro-beetle-psx-hw \
    libretro-mupen64plus-next \
    libretro-mgba \
    libretro-snes9x \
    libretro-nestopia \
    libretro-desmume \
    libretro-ppsspp \
    libretro-flycast \
    libretro-bsnes-mercury-balanced \
    libretro-gambatte \
    libretro-genesis-plus-gx \
    # Vulkan/GPU support
    vulkan-tools \
    mesa-vulkan-drivers \
    # Audio
    pulseaudio \
    # Controller support
    joystick \
    # Fonts for UI
    fonts-liberation \
    fonts-noto \
    && rm -rf /var/lib/apt/lists/*

# Create directories
RUN mkdir -p /roms /saves /config /screenshots

# Copy default configuration
COPY config/retroarch.cfg /root/.config/retroarch/retroarch.cfg

# Environment for Wolf/Wayland streaming
ENV XDG_RUNTIME_DIR=/tmp/runtime-root
ENV WAYLAND_DISPLAY=wayland-0
ENV PULSE_SERVER=unix:/tmp/pulse/native
ENV LD_LIBRARY_PATH=/nvidia-libs:/usr/local/cuda/lib64

# Run as non-root user for security (matches Wolf expectations)
# The base image already sets up ubuntu user
USER ubuntu

# Default command
CMD ["retroarch"]
