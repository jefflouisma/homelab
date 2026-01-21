#!/bin/bash
# RetroArch startup script for Wolf streaming
# Waits for Wayland display to be available before launching

set -e

RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/.X11-unix}"
export XDG_RUNTIME_DIR="$RUNTIME_DIR"

# Wayland clients require XDG_RUNTIME_DIR to be private (0700).
mkdir -p "$RUNTIME_DIR"
chmod 700 "$RUNTIME_DIR" 2>/dev/null || true
chown "$(id -u)":"$(id -g)" "$RUNTIME_DIR" 2>/dev/null || true

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
WAYLAND_SOCKET="${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY:-wayland-0}"
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
