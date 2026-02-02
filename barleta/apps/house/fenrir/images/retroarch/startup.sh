#!/bin/bash
# RetroArch startup script for Wolf streaming
# Waits for Wayland display to be available before launching

set -e

RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/.X11-unix}"
export XDG_RUNTIME_DIR="$RUNTIME_DIR"

# Wayland clients require XDG_RUNTIME_DIR to be private (0700).
# In sidecar mode, the dir may be owned by root/init, so don't fail if chown fails.
mkdir -p "$RUNTIME_DIR" 2>/dev/null || true
chmod 700 "$RUNTIME_DIR" 2>/dev/null || true
# Skip chown - in sidecar mode we can't change ownership of shared volume

# Use runtime cookie when available and mirror to HOME for libpulse fallback.
PULSE_COOKIE_PATH="${PULSE_COOKIE:-${RUNTIME_DIR}/.config/pulse/cookie}"
export PULSE_COOKIE="$PULSE_COOKIE_PATH"
HOME_DIR="${HOME:-/home/retro}"
if [ -f "$PULSE_COOKIE_PATH" ]; then
    mkdir -p "$HOME_DIR/.config/pulse"
    cp -f "$PULSE_COOKIE_PATH" "$HOME_DIR/.config/pulse/cookie"
    chmod 600 "$HOME_DIR/.config/pulse/cookie" 2>/dev/null || true
fi

# Wait for Wayland display socket
# Handle both relative (wayland-0) and absolute (/tmp/.X11-unix/wayland-1) paths
WAYLAND_DISPLAY_VAL="${WAYLAND_DISPLAY:-wayland-0}"
if [[ "$WAYLAND_DISPLAY_VAL" = /* ]]; then
    WAYLAND_SOCKET="$WAYLAND_DISPLAY_VAL"
else
    WAYLAND_SOCKET="${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY_VAL}"
fi
echo "Waiting for Wayland display at ${WAYLAND_SOCKET}..."
TIMEOUT=30
WAITED=0
while [ ! -S "${WAYLAND_SOCKET}" ] && [ $WAITED -lt $TIMEOUT ]; do
    sleep 1
    WAITED=$((WAITED + 1))
    echo "Waiting for wayland socket... ($WAITED/$TIMEOUT)"
done

if [ ! -S "${WAYLAND_SOCKET}" ]; then
    echo "ERROR: Wayland display not available after ${TIMEOUT}s"
    exit 1
fi

echo "Wayland display ready, launching RetroArch..."

# Launch RetroArch
exec retroarch "$@"
