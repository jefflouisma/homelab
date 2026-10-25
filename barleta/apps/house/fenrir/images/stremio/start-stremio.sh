#!/bin/bash
set -euo pipefail
export HOME=/home/retro
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/.X11-unix}"
export QT_QPA_PLATFORM=wayland
export QTWEBENGINE_DISABLE_SANDBOX=1
export QTWEBENGINE_REMOTE_DEBUGGING=127.0.0.1:9222
# Qt WebEngine renders its UI in software; mpv and Wolf retain GPU access.
export QTWEBENGINE_CHROMIUM_FLAGS="--disable-gpu --disable-dev-shm-usage"
mkdir -p "$HOME/.config/pulse"
wayland_socket="${WAYLAND_DISPLAY:-wayland-1}"
[[ "$wayland_socket" = /* ]] || wayland_socket="$XDG_RUNTIME_DIR/$wayland_socket"
pulse_socket="$XDG_RUNTIME_DIR/pulse-socket"
for ((attempt=0; attempt<60; attempt++)); do
    if [[ -S "$wayland_socket" && -w "$wayland_socket" && -S "$pulse_socket" ]]; then
        break
    fi
    sleep 1
done
[[ -S "$wayland_socket" && -w "$wayland_socket" && -S "$pulse_socket" ]] || {
    echo "Stremio: Wayland/PulseAudio did not become ready" >&2
    exit 1
}
export PULSE_SERVER="unix:$pulse_socket"
export PULSE_COOKIE="$XDG_RUNTIME_DIR/.config/pulse/cookie"
if [[ -r "$PULSE_COOKIE" ]]; then
    cp "$PULSE_COOKIE" "$HOME/.config/pulse/cookie"
    chmod 600 "$HOME/.config/pulse/cookie"
fi
sink=$(pactl list sinks short | awk '$2 ~ /^virtual_sink/ {print $2; exit}')
if [[ -n "$sink" ]]; then
    export PULSE_SINK="$sink"
fi
python3 /usr/local/lib/fenrir/install-torrentio.py &
unset DBUS_SESSION_BUS_ADDRESS
exec dbus-run-session -- /opt/stremio/stremio "$@"
