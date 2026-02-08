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

# Copy custom ES-DE system definitions (always update from image — config may change)
ESDE_CUSTOM_SYSTEMS="$ESDE_CONFIG_DIR/custom_systems"
mkdir -p "$ESDE_CUSTOM_SYSTEMS"
cp /etc/es-de/custom_systems/es_systems.xml "$ESDE_CUSTOM_SYSTEMS/es_systems.xml"
echo "Copied custom ES-DE system definitions"

# ─── RPCS3 Configuration ────────────────────────────────────────────────────
RPCS3_CONFIG_DIR="$HOME_DIR/.config/rpcs3"
mkdir -p "$RPCS3_CONFIG_DIR/GuiConfigs"

# Pre-create RPCS3 Qt settings to suppress welcome dialog when launching games
# Keys sourced from rpcs3/rpcs3qt/gui_settings.h (gui_save definitions)
RPCS3_GUI_INI="$RPCS3_CONFIG_DIR/GuiConfigs/CurrentSettings.ini"
if [ ! -f "$RPCS3_GUI_INI" ]; then
    cat > "$RPCS3_GUI_INI" << 'RPCS3_INI'
[main_window]
infoBoxEnabledWelcome=false
infoBoxEnabledInstallPUP=false
infoBoxEnabledInstallPKG=false
confirmationBoxExitGame=false
confirmationBoxBootGame=false
RPCS3_INI
    echo "Created RPCS3 GUI settings (welcome dialog suppressed)"
fi

# NOTE: PS3 firmware is NOT installed at startup. RPCS3's --installfw always
# opens a GUI dialog, which blocks ES-DE from launching. Instead, firmware
# installation happens when the user first launches a PS3 game from ES-DE:
# 1. User selects a PS3 game in ES-DE
# 2. ES-DE launches RPCS3 with the game
# 3. RPCS3 prompts to install firmware if missing (one-time)
# 4. PPU modules compile on first run per game
# 5. Firmware + PPU cache persist on PVC across sessions

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

# ─── Controller Hotplug (udevd) ──────────────────────────────────────────────
# Wolf creates virtual gamepad devices via uinput AFTER the app starts (~8s).
# SDL2 needs udevd to receive hotplug events and discover new controllers.
# Without this, ES-DE/RetroArch never see the Wolf virtual Xbox pad.
echo "Starting udevd for controller hotplug detection..."
if command -v udevd &>/dev/null; then
    udevd --daemon 2>/dev/null || udevadm daemon 2>/dev/null || true
    # Trigger existing input devices so SDL2 picks up anything already present
    udevadm trigger --subsystem-match=input --action=add 2>/dev/null || true
    echo "udevd started."
else
    echo "WARNING: udevd not found, controller hotplug will not work"
fi

# ─── Launch ES-DE ─────────────────────────────────────────────────────────────
echo "Launching ES-DE frontend..."
exec es-de --resolution 1920 1080 "$@"
