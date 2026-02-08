#!/bin/bash
# EmuDeck startup script for Wolf streaming
# Waits for Wayland display, sets up ES-DE directories, and launches ES-DE
# Based on the proven RetroArch startup.sh pattern

set -e

echo "=== EmuDeck Container Starting ==="

# ─── XDG Runtime ──────────────────────────────────────────────────────────────
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/.X11-unix}"
export XDG_RUNTIME_DIR="$RUNTIME_DIR"

mkdir -p "$RUNTIME_DIR" 2>/dev/null || true
chmod 700 "$RUNTIME_DIR" 2>/dev/null || true

# ─── PulseAudio Cookie ───────────────────────────────────────────────────────
PULSE_COOKIE_PATH="${PULSE_COOKIE:-${RUNTIME_DIR}/.config/pulse/cookie}"
export PULSE_COOKIE="$PULSE_COOKIE_PATH"
HOME_DIR="${HOME:-/home/retro}"
if [ -f "$PULSE_COOKIE_PATH" ]; then
    mkdir -p "$HOME_DIR/.config/pulse"
    cp -f "$PULSE_COOKIE_PATH" "$HOME_DIR/.config/pulse/cookie"
    chmod 600 "$HOME_DIR/.config/pulse/cookie" 2>/dev/null || true
fi

# ─── Wait for Wayland ────────────────────────────────────────────────────────
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
echo "Wayland display ready."

# ─── ES-DE Directory Setup ───────────────────────────────────────────────────
# Create the symlink from ~/ROMs to /Emulation/roms so ES-DE auto-discovers
mkdir -p "$HOME_DIR"
ln -sfn /Emulation/roms "$HOME_DIR/ROMs"

# Set up ES-DE config directory
ESDE_CONFIG_DIR="$HOME_DIR/.config/es-de"
mkdir -p "$ESDE_CONFIG_DIR"

# Copy default ES-DE settings if not already customized (PVC persistence)
if [ ! -f "$ESDE_CONFIG_DIR/es_settings.xml" ]; then
    cp /etc/es-de/es_settings.xml "$ESDE_CONFIG_DIR/es_settings.xml"
    echo "Copied default ES-DE settings."
fi

# Copy custom ES-DE system definitions (PS3 with RPCS3 Directory as default)
ESDE_CUSTOM_SYSTEMS="$ESDE_CONFIG_DIR/custom_systems"
mkdir -p "$ESDE_CUSTOM_SYSTEMS"
if [ ! -f "$ESDE_CUSTOM_SYSTEMS/es_systems.xml" ]; then
    cp /etc/es-de/custom_systems/es_systems.xml "$ESDE_CUSTOM_SYSTEMS/es_systems.xml"
    echo "Copied custom ES-DE system definitions (PS3/RPCS3)."
fi

# ─── RPCS3 Configuration ────────────────────────────────────────────────────
RPCS3_CONFIG_DIR="$HOME_DIR/.config/rpcs3"
mkdir -p "$RPCS3_CONFIG_DIR"

# Auto-install PS3 firmware if available in BIOS directory
if [ -f "/Emulation/bios/PS3UPDAT.PUP" ] && [ ! -d "$RPCS3_CONFIG_DIR/dev_flash" ]; then
    echo "PS3 firmware found, installing..."
    rpcs3 --installfw /Emulation/bios/PS3UPDAT.PUP 2>&1 || echo "RPCS3 firmware install returned non-zero (may still succeed)"
    echo "PS3 firmware installation complete."
fi

# Set up RetroArch config directory
RETROARCH_CONFIG_DIR="$HOME_DIR/.config/retroarch"
mkdir -p "$RETROARCH_CONFIG_DIR"

if [ ! -f "$RETROARCH_CONFIG_DIR/retroarch.cfg" ]; then
    cp /etc/retroarch.cfg "$RETROARCH_CONFIG_DIR/retroarch.cfg"
    echo "Copied default RetroArch config."
fi

# Ensure saves directory exists
mkdir -p /Emulation/saves/retroarch/states 2>/dev/null || true
mkdir -p /Emulation/saves/retroarch/saves 2>/dev/null || true
mkdir -p /Emulation/saves/pcsx2/memcards 2>/dev/null || true
mkdir -p /Emulation/saves/ppsspp 2>/dev/null || true
mkdir -p /Emulation/saves/duckstation 2>/dev/null || true
mkdir -p /Emulation/saves/rpcs3 2>/dev/null || true
mkdir -p /Emulation/saves/shadps4 2>/dev/null || true

# ─── PS4 Game Name Resolution ────────────────────────────────────────────────
# Generate named symlinks for PS4 games (CUSA* → human-readable titles)
if [ -d "/Emulation/roms/ps4" ]; then
    echo "Generating PS4 game shortcuts..."
    generate-ps4-shortcuts.sh /Emulation/roms/ps4 /Emulation/storage/ps4-games
fi

# ─── Qt Wayland Platform ─────────────────────────────────────────────────────
# Standalone emulators (PCSX2, DuckStation, RPCS3, shadPS4) are Qt apps — force Wayland
export QT_QPA_PLATFORM=wayland
export SDL_VIDEODRIVER=wayland

# ─── Launch ES-DE ─────────────────────────────────────────────────────────────
echo "Launching ES-DE frontend..."
exec es-de --resolution 1920 1080 "$@"
