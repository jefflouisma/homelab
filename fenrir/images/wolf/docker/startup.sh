#!/bin/bash
set -e

# Make sure configure folder exists
# as Wolf may try to create default config in non existing folder and crash.
# See https://github.com/games-on-whales/wolf/pull/65#discussion_r1509235307
# and https://github.com/games-on-whales/wolf/issues/64#issuecomment-1951479056
export WOLF_CFG_FOLDER=$HOST_APPS_STATE_FOLDER/cfg
mkdir -p $WOLF_CFG_FOLDER
# Adjust env variables if the user moved the folder
export WOLF_CFG_FILE=$WOLF_CFG_FOLDER/config.toml
export WOLF_PRIVATE_KEY_FILE=$WOLF_CFG_FOLDER/key.pem
export WOLF_PRIVATE_CERT_FILE=$WOLF_CFG_FOLDER/cert.pem

# Set default values for environment variables
export WOLF_RENDER_NODE=${WOLF_RENDER_NODE:-/dev/dri/renderD128}
export WOLF_ENCODER_NODE=${WOLF_ENCODER_NODE:-$WOLF_RENDER_NODE}
export GST_GL_DRM_DEVICE=${GST_GL_DRM_DEVICE:-$WOLF_ENCODER_NODE}

# Update fake-udev if missing from the path
export WOLF_DOCKER_FAKE_UDEV_PATH=${WOLF_DOCKER_FAKE_UDEV_PATH:-$HOST_APPS_STATE_FOLDER/fake-udev}
cp /wolf/fake-udev $WOLF_DOCKER_FAKE_UDEV_PATH

# Create nvidia GBM backend symlink where libgbm searches by default
# NVIDIA container toolkit mounts libraries at /nvidia-libs but libgbm
# looks in /usr/lib/gbm/ for nvidia-drm_gbm.so (NOT /usr/lib/x86_64-linux-gnu/gbm/)
mkdir -p /usr/lib/gbm
if [ -f /nvidia-libs/libnvidia-egl-gbm.so.1 ]; then
    ln -sf /nvidia-libs/libnvidia-egl-gbm.so.1 /usr/lib/gbm/nvidia-drm_gbm.so
fi

# Create EGL external platform configuration for NVIDIA GBM backend
# Required for libgbm to find nvidia-drm driver and create DMA buffers
# See: https://github.com/games-on-whales/wolf/issues/301
mkdir -p /usr/share/egl/egl_external_platform.d
chmod 777 /usr/share/egl/egl_external_platform.d 2>/dev/null || true

# Create NVIDIA GBM platform config if nvidia-egl-gbm library exists
if [ -f /nvidia-libs/libnvidia-egl-gbm.so.1 ]; then
    cat > /usr/share/egl/egl_external_platform.d/15_nvidia_gbm.json << 'EOF'
{
    "file_format_version" : "1.0.0",
    "ICD" : {
        "library_path" : "libnvidia-egl-gbm.so.1"
    }
}
EOF
fi

# Create NVIDIA Wayland platform config if library exists
if [ -f /nvidia-libs/libnvidia-egl-wayland.so.1 ]; then
    cat > /usr/share/egl/egl_external_platform.d/10_nvidia_wayland.json << 'EOF'
{
    "file_format_version" : "1.0.0",
    "ICD" : {
        "library_path" : "libnvidia-egl-wayland.so.1"
    }
}
EOF
fi

exec /wolf/wolf