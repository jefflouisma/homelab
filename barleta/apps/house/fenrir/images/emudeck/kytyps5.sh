#!/bin/sh
set -eu

# Installed as both kytyps5 and ps5plus; each selects its own package and guest data.
component="$(basename "$0" .sh)"
case "$component" in kytyps5|ps5plus) ;; *) echo "Unknown PS5 emulator: $component" >&2; exit 1;; esac
package="$(package-path "$component")"
game="$(readlink -f "$1")"
width="${GAMESCOPE_WIDTH:-1920}"
height="${GAMESCOPE_HEIGHT:-1080}"
case "$width:$height" in *[!0-9:]*|:*|*:) echo 'Invalid stream dimensions' >&2; exit 1;; esac

# Kyty stores guest data relative to its working directory, independently of its executable.
data="$HOME/.local/share/$component"
scratch="/Volumes/4TB_Drive/tmp/$component"
mkdir -p "$data" "$scratch/temp" "$scratch/logs"
if [ ! -e "$data/_TempData" ]; then ln -s "$scratch/temp" "$data/_TempData"; fi
export TMPDIR="$scratch/temp"
export LD_LIBRARY_PATH="$package/lib:${LD_LIBRARY_PATH:-}"
export SDL_VIDEODRIVER=wayland
export SDL_JOYSTICK_DISABLE_UDEV=1
cd "$data"
exec "$package/kyty_emulator" --game "$game" --fullscreen \
    --screen-width "$width" --screen-height "$height" --hide-cursor \
    --shader-log-folder "$scratch/logs/shaders" \
    --command-buffer-dump-folder "$scratch/logs/buffers" \
    --printf-output-file "$scratch/logs/guest.txt"
