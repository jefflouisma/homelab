#!/bin/bash
# RetroArch startup script for Wolf streaming
# Waits for Wayland display to be available before launching

set -e

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
