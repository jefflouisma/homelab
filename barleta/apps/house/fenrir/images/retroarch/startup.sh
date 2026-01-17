#!/bin/bash
# RetroArch startup script for Wolf streaming
# Waits for Wayland display to be available before launching

set -e

# Wait for Wayland display socket
echo "Waiting for Wayland display..."
TIMEOUT=30
WAITED=0
while [ ! -S "${XDG_RUNTIME_DIR}/wayland-0" ] && [ $WAITED -lt $TIMEOUT ]; do
    sleep 1
    WAITED=$((WAITED + 1))
    echo "Waiting for wayland socket... ($WAITED/$TIMEOUT)"
done

if [ ! -S "${XDG_RUNTIME_DIR}/wayland-0" ]; then
    echo "ERROR: Wayland display not available after ${TIMEOUT}s"
    exit 1
fi

echo "Wayland display ready, launching RetroArch..."

# Launch RetroArch
exec retroarch "$@"
