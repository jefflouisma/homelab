ARG BASE_IMAGE=ghcr.io/games-on-whales/gstreamer:1.26.7

########################################################
# STAGE 1: gst-wayland-display builder (Rust, ~11 min)
# Independent stage - only rebuilds when:
# - GST_COMMIT changes (fork updates)
# - SMITHAY_COMMIT changes
# - Rust version changes
########################################################
FROM $BASE_IMAGE AS gst-builder

ENV DEBIAN_FRONTEND=noninteractive

# Minimal deps for Rust build + openssl for cargo-c
RUN apt-get update -y && \
    apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    git \
    build-essential \
    pkg-config \
    libicu76 \
    libssl-dev \
    libwayland-dev libwayland-server0 libinput-dev libxkbcommon-dev libgbm-dev \
    libglib2.0-dev libegl-dev libgles-dev libopengl-dev libdrm-dev \
    && rm -rf /var/lib/apt/lists/*

# Install Rust and set version
# Explicitly set HOME and Cargo/Rustup directories to avoid path issues
ENV HOME=/root
ENV CARGO_HOME=/root/.cargo
ENV RUSTUP_HOME=/root/.rustup
ENV CARGO_BUILD_JOBS=1
ARG RUST_VERSION=1.91.1
ENV RUST_VERSION=$RUST_VERSION
ENV PATH="${CARGO_HOME}/bin:${PATH}"
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain ${RUST_VERSION}

# ARGs for cache invalidation - only change these when repos are updated
ARG SMITHAY_COMMIT=a166cf4c94b5aedc332a65aa1dd753e8148829c3
ARG GST_COMMIT=a000a57

WORKDIR /tmp/

# Clone and patch Smithay for NVIDIA EGL compatibility
RUN git clone https://github.com/games-on-whales/smithay /tmp/smithay-patched && \
    cd /tmp/smithay-patched && \
    git checkout $SMITHAY_COMMIT && \
    # Delete EGL_EXT_device_enumeration and EGL_EXT_device_query checks
    # EGL_EXT_device_base (NVIDIA 590) is composite extension including both
    sed -i '35,41d' src/backend/egl/device.rs

# Clone, configure and build gst-wayland-display with cargo cache mount
RUN --mount=type=cache,target=/root/.cargo/registry \
    --mount=type=cache,target=/root/.cargo/git \
    git clone https://github.com/jefflouisma/gst-wayland-display && \
    cd gst-wayland-display && \
    git checkout $GST_COMMIT && \
    mkdir -p .cargo && \
    echo '[patch."https://github.com/games-on-whales/smithay"]' > .cargo/config.toml && \
    echo 'smithay = { path = "/tmp/smithay-patched" }' >> .cargo/config.toml && \
    cargo install cargo-c -j 1 && \
    cargo cinstall --jobs 1 --features="cuda" --prefix=/usr/local/lib/x86_64-linux-gnu/ --libdir=/usr/local/lib/x86_64-linux-gnu/gstreamer-1.0

########################################################
# STAGE 2: Wolf C++ builder (~16 min)
# Independent stage - only rebuilds when:
# - wolf/ source code changes
# - C++ build flags change
# Does NOT depend on gst-wayland-display!
########################################################
FROM $BASE_IMAGE AS wolf-builder

ENV DEBIAN_FRONTEND=noninteractive

# Wolf build dependencies (C++ toolchain)
RUN apt-get update -y && \
    apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    ninja-build \
    cmake \
    pkg-config \
    ccache \
    git \
    clang \
    build-essential \
    libboost-thread-dev libboost-locale-dev libboost-filesystem-dev libboost-log-dev libboost-stacktrace-dev libboost-container-dev \
    libwayland-dev libwayland-server0 libinput-dev libxkbcommon-dev libgbm-dev \
    libcurl4-openssl-dev \
    libssl-dev \
    libevdev-dev \
    libpulse-dev \
    libunwind-dev \
    libudev-dev \
    libdrm-dev \
    libpci-dev \
    libglib2.0-dev libegl-dev libgles-dev libopengl-dev \
    && rm -rf /var/lib/apt/lists/*

COPY . /wolf/
WORKDIR /wolf

ENV CCACHE_DIR=/cache/ccache
ENV CMAKE_BUILD_DIR=/cache/cmake-build

RUN --mount=type=cache,target=/cache/ccache \
    cmake -B$CMAKE_BUILD_DIR \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DCMAKE_CXX_STANDARD=17 \
    -DCMAKE_CXX_EXTENSIONS=OFF \
    -DCMAKE_CXX_FLAGS="-Wno-missing-template-arg-list-after-template-kw" \
    -DBUILD_SHARED_LIBS=OFF \
    -DBoost_USE_STATIC_LIBS=ON \
    -DBUILD_FAKE_UDEV_CLI=ON \
    -DBUILD_TESTING=OFF \
    -G Ninja && \
    ninja -C $CMAKE_BUILD_DIR -j1 wolf && \
    ninja -C $CMAKE_BUILD_DIR -j1 fake-udev && \
    # Copy out built executables from buildkit cache
    cp $CMAKE_BUILD_DIR/src/moonlight-server/wolf /wolf/wolf && \
    cp $CMAKE_BUILD_DIR/src/fake-udev/fake-udev /wolf/fake-udev

########################################################
# STAGE 3: Runtime image
# Copies artifacts from both builder stages
# Only rebuilds on runtime config changes (~1 min)
########################################################
FROM $BASE_IMAGE AS runner
ENV DEBIAN_FRONTEND=noninteractive

# Wolf runtime dependencies
RUN apt-get update -y && \
    apt-get install -y --no-install-recommends \
    ca-certificates \
    libssl3 \
    libicu76 \
    libevdev2 \
    libudev1 \
    libcurl4 \
    libdrm2 \
    libpci3 \
    libunwind8 \
    && rm -rf /var/lib/apt/lists/*

# gst-plugin-wayland runtime dependencies
# NVIDIA GBM requires: Mesa libgbm >= 21.2, DRM KMS enabled, AND egl-wayland >= 1.1.8
# See: https://download.nvidia.com/XFree86/Linux-x86_64/510.68.02/README/gbm.html
RUN apt-get update -y && \
    apt-get install -y --no-install-recommends \
    libwayland-server0 libinput10 libxkbcommon0 libgbm1 \
    libglvnd0 libgl1 libglx0 libegl1 libgles2 xwayland hwdata \
    libnvidia-egl-wayland1 \
    && rm -rf /var/lib/apt/lists/* \
    # Create GBM directory for nvidia backend symlink (created at runtime by startup.sh)
    # libgbm searches in /usr/lib/gbm/ by default, NOT /usr/lib/x86_64-linux-gnu/gbm/
    # startup.sh runs as non-root so needs write permission to this directory
    && mkdir -p /usr/lib/gbm \
    && chmod 777 /usr/lib/gbm \
    # Create EGL external platform directory for nvidia config JSON files
    && mkdir -p /usr/share/egl/egl_external_platform.d \
    && chmod 777 /usr/share/egl/egl_external_platform.d

ENV GST_PLUGIN_PATH=/usr/local/lib/x86_64-linux-gnu/gstreamer-1.0/

# Copy gst-wayland-display from gst-builder stage
COPY --from=gst-builder /usr/local/lib/x86_64-linux-gnu/gstreamer-1.0/* $GST_PLUGIN_PATH
COPY --from=gst-builder /usr/local/lib/liblibgstwaylanddisplay* /usr/local/lib/

# Copy Wolf executables from wolf-builder stage
COPY --from=wolf-builder /wolf/wolf /wolf/wolf
COPY --from=wolf-builder /wolf/fake-udev /wolf/fake-udev

# CRITICAL: Make existing EGL platform config files writable for non-root users
# Base image has 15_nvidia_gbm.json and 10_nvidia_wayland.json owned by root:644
RUN chmod 777 /usr/lib/x86_64-linux-gnu/gbm /usr/share/egl/egl_external_platform.d 2>/dev/null || true && \
    chmod 666 /usr/share/egl/egl_external_platform.d/*.json 2>/dev/null || true

WORKDIR /wolf

ENV WOLF_CFG_FOLDER=/etc/wolf/cfg

ENV GST_GL_API=gles2 \
    GST_GL_PLATFORM=egl \
    GST_GL_WINDOW=surfaceless \
    WOLF_USE_ZERO_COPY=TRUE \
    WOLF_LOG_LEVEL=INFO \
    WOLF_CFG_FILE=$WOLF_CFG_FOLDER/config.toml \
    WOLF_PRIVATE_KEY_FILE=$WOLF_CFG_FOLDER/key.pem \
    WOLF_PRIVATE_CERT_FILE=$WOLF_CFG_FOLDER/cert.pem \
    WOLF_PULSE_IMAGE=ghcr.io/games-on-whales/pulseaudio:master \
    WOLF_RENDER_NODE=/dev/dri/renderD128 \
    WOLF_STOP_CONTAINER_ON_EXIT=TRUE \
    WOLF_DOCKER_SOCKET=/var/run/docker.sock \
    RUST_BACKTRACE=full \
    RUST_LOG=WARN \
    HOST_APPS_STATE_FOLDER=/etc/wolf \
    GST_DEBUG=2 \
    PUID=0 \
    PGID=0 \
    UNAME="root"

# XDG_RUNTIME_DIR - auto-creates volume when starting
VOLUME /run/user/wolf/
ENV XDG_RUNTIME_DIR=/run/user/wolf

# HTTPS
EXPOSE 47984/tcp
# HTTP
EXPOSE 47989/tcp
# Control
EXPOSE 47999/udp
# RTSP
EXPOSE 48010/tcp
# Video
EXPOSE 48100/udp
# Audio
EXPOSE 48200/udp

LABEL org.opencontainers.image.source="https://github.com/games-on-whales/wolf/"
LABEL org.opencontainers.image.description="Wolf: stream virtual desktops and games in Docker"

# See GOW/base-app
COPY --chmod=777 docker/startup.sh /opt/gow/startup-app.sh
ENTRYPOINT ["/entrypoint.sh"]
