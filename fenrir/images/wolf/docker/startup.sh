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

# Create nvidia GBM backend symlinks where libgbm searches by default
# NVIDIA container toolkit mounts libraries at /nvidia-libs but libgbm probes via TWO paths:
# 1. Default fallback: always tries dri_gbm.so first (ignores GBM_BACKEND env var)
# 2. Vendor-specific: queries DRM driver name (nvidia-drm) and tries nvidia-drm_gbm.so
# Create BOTH symlinks to cover all libgbm probing paths for NVIDIA GPU
# NOTE: gbm-backend-init container may have already created these files
echo "[startup.sh] === GBM Backend Check ===" >&2
echo "[startup.sh] Checking /usr/lib/gbm/ directory..." >&2
ls -la /usr/lib/gbm/ 2>&1 | head -5 >&2 || echo "[startup.sh] /usr/lib/gbm/ does not exist!" >&2

# Only create symlinks if they don't exist (-f returns true for files AND symlinks)
if [ -f /usr/lib/gbm/dri_gbm.so ] && [ -f /usr/lib/gbm/nvidia-drm_gbm.so ]; then
    echo "[startup.sh] GBM symlinks already exist (from init container), skipping creation" >&2
elif [ -f /nvidia-libs/libnvidia-egl-gbm.so.1 ]; then
    echo "[startup.sh] Creating GBM symlinks -> nvidia backend..." >&2
    ln -sfv /nvidia-libs/libnvidia-egl-gbm.so.1 /usr/lib/gbm/dri_gbm.so 2>&1 >&2
    ln -sfv /nvidia-libs/libnvidia-egl-gbm.so.1 /usr/lib/gbm/nvidia-drm_gbm.so 2>&1 >&2
else
    echo "[startup.sh] WARNING: /nvidia-libs/libnvidia-egl-gbm.so.1 NOT FOUND!" >&2
    echo "[startup.sh] Contents of /nvidia-libs/:" >&2
    ls -la /nvidia-libs/ 2>&1 | head -20 >&2
fi

# Create EGL external platform configuration for NVIDIA GBM backend
# Required for libgbm to find nvidia-drm driver and create DMA buffers
# See: https://github.com/games-on-whales/wolf/issues/301
# NOTE: /usr/share/egl/egl_external_platform.d is mounted as writable emptyDir in K8s
# The path is also symlinked/available via __EGL_EXTERNAL_PLATFORM_CONFIG_DIRS env var
EGL_PLATFORM_DIR="/usr/share/egl/egl_external_platform.d"
mkdir -p "$EGL_PLATFORM_DIR" 2>/dev/null || true

# Create NVIDIA GBM platform config if nvidia-egl-gbm library exists
if [ -f /nvidia-libs/libnvidia-egl-gbm.so.1 ]; then
    cat > "$EGL_PLATFORM_DIR/15_nvidia_gbm.json" 2>/dev/null << 'EOF' || echo "[startup.sh] Could not write EGL GBM config (path may be read-only)" >&2
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
    cat > "$EGL_PLATFORM_DIR/10_nvidia_wayland.json" 2>/dev/null << 'EOF' || echo "[startup.sh] Could not write EGL Wayland config (path may be read-only)" >&2
{
    "file_format_version" : "1.0.0",
    "ICD" : {
        "library_path" : "libnvidia-egl-wayland.so.1"
    }
}
EOF
fi

# Background loop to fix Wayland socket permissions after wolf creates it.
# Wolf runs as root but clients (e.g., retroarch) run as uid 1000.
# The socket needs to be world-writable (or chowned) for clients to connect.
(
    SOCKET_PATH="/tmp/.X11-unix/wayland-1"
    echo "[startup.sh] Starting Wayland socket permission fixer..." >&2
    for i in $(seq 1 30); do
        if [ -S "$SOCKET_PATH" ]; then
            chmod 777 "$SOCKET_PATH" 2>/dev/null && \
                echo "[startup.sh] Fixed Wayland socket permissions: chmod 777 $SOCKET_PATH" >&2
            # Also chown to match the client uid if XDG requirements need it
            chown 1000:1000 "$SOCKET_PATH" 2>/dev/null && \
                echo "[startup.sh] Fixed Wayland socket ownership: chown 1000:1000 $SOCKET_PATH" >&2
            break
        fi
        sleep 0.5
    done
) &

exec /wolf/wolf
