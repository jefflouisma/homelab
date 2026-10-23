#!/bin/sh
set -eu

frontend="$(package-path emudeck --pin)"
generate-ps5-shortcuts /Emulation/roms/ps5 /Emulation/storage/ps5-games >&2
generate-ps5-shortcuts /Emulation/roms/ps5 /Emulation/storage/ps5plus-games >&2

resolution="$(prepare-console-display)"
set -- $resolution "$@"

export ESDE_APPDATA_DIR="${ESDE_APPDATA_DIR:-$HOME/ES-DE}"
mkdir -p "$ESDE_APPDATA_DIR"
if [ -L "$ESDE_APPDATA_DIR/resources" ] || [ ! -e "$ESDE_APPDATA_DIR/resources" ]; then
    ln -sfn "$frontend/usr/bin/resources" "$ESDE_APPDATA_DIR/resources"
fi
mkdir -p "$ESDE_APPDATA_DIR/themes"
for theme in "$frontend"/usr/bin/themes/*; do
    if [ -L "$ESDE_APPDATA_DIR/themes/${theme##*/}" ] || [ ! -e "$ESDE_APPDATA_DIR/themes/${theme##*/}" ]; then
        ln -sfn "$theme" "$ESDE_APPDATA_DIR/themes/${theme##*/}"
    fi
done

cd "$frontend"
exec /lib64/ld-linux-x86-64.so.2 --library-path "$frontend/usr/lib:${LD_LIBRARY_PATH:-}" "$frontend/AppRun" --resolution "$@"
