#!/bin/sh
set -eu

# Installed as eden (Nintendo Switch) and eglantine (Nintendo Switch 2). Each runs the release this
# session pinned from Fenrir Updates and keeps its own data, keys and firmware.
component="$(basename "$0" .sh)"
case "$component" in eden|eglantine) ;; *) echo "Unknown Switch emulator: $component" >&2; exit 1;; esac
package="$(package-path "$component")"

# A user directory in the working directory selects portable mode, keeping each emulator's saves,
# NAND and settings apart; both would otherwise use ~/.local/share/eden and ~/.config/eden.
data="$HOME/.local/share/$component"
user="$data/user"
bios="/Emulation/bios/$component"
mkdir -p "$user/keys"
for keys in "$bios"/keys/*.keys; do
    if [ -f "$keys" ]; then cp -f "$keys" "$user/keys/"; fi
done

# Firmware is the NCA set dumped from the console; it is reinstalled when the dump changes.
registered="$user/nand/system/Contents/registered"
if [ -d "$bios/firmware" ]; then
    dump="$(cd "$bios/firmware" && ls -l -- *.nca 2>/dev/null || true)"
    if [ -n "$dump" ] && [ "$dump" != "$(cat "$data/firmware.list" 2>/dev/null || true)" ]; then
        rm -rf "$registered"
        mkdir -p "$registered"
        cp "$bios"/firmware/*.nca "$registered/"
        printf '%s\n' "$dump" > "$data/firmware.list"
    fi
fi

cd "$data"
if [ "$component" = eden ]; then
    # Eden's AppImage otherwise switches to X11, which Wolf's compositor does not provide.
    export I_WANT_A_BROKEN_WAYLAND_UI=1
    exec "$package/AppRun" -f -g "$@"
fi

# Eglantine's Qt frontend ships only the X11 platform plugin, so it runs its SDL frontend, which
# draws on Wayland. That frontend has no settings screen: it uses the controllers set up in Eden.
python3 - "$HOME/.local/share/eden/user/config/qt-config.ini" "$user/config/sdl2-config.ini" <<'EOF'
import configparser
from pathlib import Path
import sys


def load(path: Path) -> configparser.RawConfigParser:
    config = configparser.RawConfigParser(strict=False, interpolation=None)
    config.optionxform = str
    if path.is_file():
        config.read(path, encoding="utf-8")
    return config


source, target = map(Path, sys.argv[1:])
eden, eglantine = load(source), load(target)
if eden.has_section("Controls"):
    eglantine.remove_section("Controls")
    eglantine.add_section("Controls")
    for key, value in eden.items("Controls"):
        eglantine.set("Controls", key, value)
    target.parent.mkdir(parents=True, exist_ok=True)
    with target.open("w", encoding="utf-8") as output:
        eglantine.write(output, space_around_delimiters=False)
EOF
export LD_LIBRARY_PATH="$package/usr/lib:${LD_LIBRARY_PATH:-}"
exec "$package/usr/bin/eden-cli" -f -g "$@"
