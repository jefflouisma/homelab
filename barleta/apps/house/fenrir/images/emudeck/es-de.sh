#!/bin/sh
set -eu

export ESDE_APPDATA_DIR="${ESDE_APPDATA_DIR:-$HOME/ES-DE}"
mkdir -p "$ESDE_APPDATA_DIR"
if [ ! -e "$ESDE_APPDATA_DIR/resources" ]; then
    ln -s /opt/es-de/usr/bin/resources "$ESDE_APPDATA_DIR/resources"
fi
mkdir -p "$ESDE_APPDATA_DIR/themes"
for theme in /opt/es-de/usr/bin/themes/*; do
    if [ ! -e "$ESDE_APPDATA_DIR/themes/${theme##*/}" ]; then
        ln -s "$theme" "$ESDE_APPDATA_DIR/themes/${theme##*/}"
    fi
done

cd /opt/es-de
exec /lib64/ld-linux-x86-64.so.2 --library-path "/opt/es-de/usr/lib:${LD_LIBRARY_PATH:-}" /opt/es-de/AppRun "$@"
