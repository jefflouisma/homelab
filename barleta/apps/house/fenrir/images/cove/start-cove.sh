#!/bin/bash
set -euo pipefail
export HOME=/home/retro
export COVE_DATA_DIR="$HOME/.config/cove"
export TMPDIR=/Volumes/4TB_Drive/tmp/cove
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/.X11-unix}"
mkdir -p "$COVE_DATA_DIR" "$TMPDIR/java" "$HOME/.config/pulse"
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
    echo "Cove: Wayland/PulseAudio did not become ready" >&2
    exit 1
}
export PULSE_SERVER="unix:$pulse_socket"
export PULSE_COOKIE="$XDG_RUNTIME_DIR/.config/pulse/cookie"
if [[ -r "$PULSE_COOKIE" ]]; then
    cp "$PULSE_COOKIE" "$HOME/.config/pulse/cookie"
    chmod 600 "$HOME/.config/pulse/cookie"
fi
sink=$(pactl list sinks short | awk '$2 ~ /^virtual_sink/ {print $2; exit}')
if [[ -n "$sink" ]]; then export PULSE_SINK="$sink"; fi

# Compose Desktop uses AWT/X11. A rootful Xwayland window bridges it to Wolf's
# Wayland compositor; Openbox keeps the TV shell at the negotiated stream size.
export DISPLAY=:0
width="${GAMESCOPE_WIDTH:-1920}"
height="${GAMESCOPE_HEIGHT:-1080}"
[[ "$width" =~ ^[1-9][0-9]{2,4}$ && "$height" =~ ^[1-9][0-9]{2,4}$ ]]
Xwayland "$DISPLAY" -nolisten tcp -ac -noreset -fullscreen -geometry "${width}x${height}" &
xwayland_pid=$!
for ((attempt=0; attempt<30; attempt++)); do
    if xdpyinfo >/dev/null 2>&1; then break; fi
    kill -0 "$xwayland_pid" || { echo "Cove: Xwayland exited" >&2; exit 1; }
    sleep 1
done
xdpyinfo >/dev/null
openbox --config-file /etc/fenrir/openbox.xml &
xset s off
xset -dpms 2>/dev/null || true
export JAVA_TOOL_OPTIONS="-Dskiko.renderApi=SOFTWARE -Djava.io.tmpdir=$TMPDIR/java -Dsun.awt.X11.XWMClass=Cove"
python3 /usr/local/lib/fenrir/install-torrentio.py &
unset DBUS_SESSION_BUS_ADDRESS
exec dbus-run-session -- /usr/bin/cove --backend-mode kotlin --tv "$@"
