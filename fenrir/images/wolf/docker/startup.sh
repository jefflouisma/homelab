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

# Create nvidia GBM backend symlink for MESA-LOADER
# NVIDIA container toolkit mounts libraries at /nvidia-libs but MESA looks
# in /usr/lib/x86_64-linux-gnu/gbm/ for nvidia-drm_gbm.so
mkdir -p /usr/lib/x86_64-linux-gnu/gbm
if [ -f /nvidia-libs/libnvidia-egl-gbm.so.1 ]; then
    ln -sf /nvidia-libs/libnvidia-egl-gbm.so.1 /usr/lib/x86_64-linux-gnu/gbm/nvidia-drm_gbm.so
fi

exec /wolf/wolf