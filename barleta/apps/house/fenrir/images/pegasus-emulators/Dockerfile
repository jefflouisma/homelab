# Pegasus + Emulators Container Image
# Multi-emulator game streaming container for Fenrir/Wolf
# Includes: Pegasus Frontend, RetroArch, shadps4

FROM gameonwhales/gst-wayland-display:latest

# Build arguments
ARG SHADPS4_VERSION=0.6.0
ARG RETROARCH_VERSION=1.19.1

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Pegasus Frontend
    pegasus-frontend \
    # RetroArch and cores
    retroarch \
    libretro-* \
    # Vulkan support
    vulkan-tools \
    mesa-vulkan-drivers \
    # Audio
    pulseaudio \
    # Controller support
    joystick \
    jstest-gtk \
    # Fonts for UI
    fonts-liberation \
    fonts-noto \
    # Utilities
    curl \
    wget \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# Download and install shadps4
RUN mkdir -p /opt/shadps4 && \
    curl -fsSL "https://github.com/shadps4-emu/shadPS4/releases/download/v${SHADPS4_VERSION}/shadps4-linux64-qt.tar.gz" | \
    tar -xz -C /opt/shadps4 --strip-components=1 && \
    chmod +x /opt/shadps4/shadps4

# Create game directories
RUN mkdir -p /games/ps4 /games/roms /saves /config

# Configure Pegasus
COPY pegasus-config/ /root/.config/pegasus-frontend/

# Configure RetroArch
COPY retroarch-config/ /root/.config/retroarch/

# Set up environment
ENV XDG_RUNTIME_DIR=/tmp/runtime-root
ENV WAYLAND_DISPLAY=wayland-0
ENV PULSE_SERVER=unix:/tmp/pulse/native
ENV LD_LIBRARY_PATH=/nvidia-libs:/usr/local/cuda/lib64

# Default command - Pegasus Frontend
CMD ["pegasus-fe"]
