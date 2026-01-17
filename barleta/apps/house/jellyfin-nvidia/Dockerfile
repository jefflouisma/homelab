# Custom Jellyfin image with NVIDIA libraries baked in
# For Harvester HCI with consumer GPU (RTX 5080)
# This bypasses the need for NVIDIA Container Toolkit on immutable OS

FROM nvidia/cuda:12.6.0-runtime-ubuntu22.04

LABEL maintainer="barleta-homelab"
LABEL description="Jellyfin with NVIDIA GPU transcoding support for Harvester"

# Install dependencies and Jellyfin
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gnupg \
    wget \
    ffmpeg \
    libfontconfig1 \
    libfreetype6 \
    libssl3 \
    locales \
    && rm -rf /var/lib/apt/lists/*

# Set locale
RUN locale-gen en_US.UTF-8
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

# Add Jellyfin repository and install
RUN curl -fsSL https://repo.jellyfin.org/jellyfin_team.gpg.key | gpg --dearmor -o /usr/share/keyrings/jellyfin.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/jellyfin.gpg] https://repo.jellyfin.org/ubuntu jammy main" > /etc/apt/sources.list.d/jellyfin.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends jellyfin-server jellyfin-web jellyfin-ffmpeg6 \
    && rm -rf /var/lib/apt/lists/*

# Install NVIDIA Video Codec SDK headers for hardware transcoding
RUN mkdir -p /usr/local/include/ffnvcodec \
    && curl -fsSL https://raw.githubusercontent.com/FFmpeg/nv-codec-headers/master/include/ffnvcodec/nvEncodeAPI.h \
       -o /usr/local/include/ffnvcodec/nvEncodeAPI.h \
    && curl -fsSL https://raw.githubusercontent.com/FFmpeg/nv-codec-headers/master/include/ffnvcodec/dynlink_cuda.h \
       -o /usr/local/include/ffnvcodec/dynlink_cuda.h

# Create jellyfin user and directories
RUN useradd -r -s /bin/false jellyfin \
    && mkdir -p /config /cache /media \
    && chown -R jellyfin:jellyfin /config /cache

# Environment for NVIDIA
ENV NVIDIA_VISIBLE_DEVICES=all
ENV NVIDIA_DRIVER_CAPABILITIES=compute,utility,video
ENV JELLYFIN_DATA_DIR=/config
ENV JELLYFIN_CACHE_DIR=/cache
ENV JELLYFIN_CONFIG_DIR=/config
ENV JELLYFIN_LOG_DIR=/config/log
ENV JELLYFIN_FFMPEG=/usr/lib/jellyfin-ffmpeg/ffmpeg

# Expose ports
EXPOSE 8096 8920 7359/udp

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:8096/health || exit 1

# Volume mount points
VOLUME ["/config", "/cache", "/media"]

# Run as root to access GPU devices (required for direct device access)
USER root

# Start Jellyfin
ENTRYPOINT ["/usr/bin/jellyfin"]
CMD ["--datadir=/config", "--configdir=/config", "--cachedir=/cache", "--logdir=/config/log"]
