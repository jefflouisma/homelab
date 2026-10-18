#!/bin/bash
set -euo pipefail

export TMPDIR=/Volumes/4TB_Drive/tmp/
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
export FENRIR_NATIVE_DIR="${FENRIR_NATIVE_DIR:-/Volumes/4TB_Drive/tmp/fenrir-native-$(id -u)}"
script_dir=$(cd "$(dirname "$0")" && pwd)
mode=${1:?Usage: run.sh pair HOST PIN or run.sh stream HOST APP [OPTIONS...]}
host=${2:?Host is required}
value=${3:?PIN or app is required}
shift 3

python3 -c 'import os; from pathlib import Path; p=Path(os.environ["FENRIR_NATIVE_DIR"]).resolve(); assert p.is_relative_to(Path("/Volumes/4TB_Drive/tmp")), "Native state must be on the temporary drive"; p.mkdir(parents=True, exist_ok=True)'
if [ -f "$FENRIR_NATIVE_DIR/client.pid" ] && kill -0 "$(cat "$FENRIR_NATIVE_DIR/client.pid")" 2>/dev/null; then
    echo "The native test client is already running." >&2
    exit 1
fi
if [ ! -d "$FENRIR_NATIVE_DIR/Moonlight.app" ]; then
    ditto /Applications/Moonlight.app "$FENRIR_NATIVE_DIR/Moonlight.app"
    codesign --force --deep --sign - "$FENRIR_NATIVE_DIR/Moonlight.app"
fi
touch "$FENRIR_NATIVE_DIR/portable.dat"
cd "$FENRIR_NATIVE_DIR"
case "$mode" in
    pair)
        exec ./Moonlight.app/Contents/MacOS/Moonlight pair --pin "$value" "$host"
        ;;
    stream)
        /Library/Developer/CommandLineTools/usr/bin/clang \
            -isysroot /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk \
            -arch arm64 -Wall -Wextra -Werror -dynamiclib \
            -F "$FENRIR_NATIVE_DIR/Moonlight.app/Contents/Frameworks" -framework SDL2 \
            -Wl,-rpath,"$FENRIR_NATIVE_DIR/Moonlight.app/Contents/Frameworks" \
            "$script_dir/controller.c" -o "$FENRIR_NATIVE_DIR/controller.dylib"
        python3 -c 'import json,sys,os; from pathlib import Path; p=Path(os.environ["FENRIR_NATIVE_DIR"]); (p/"session.json").write_text(json.dumps({"host":sys.argv[1]})); (p/"controller.sock").unlink(missing_ok=True)' "$host"
        echo $$ > "$FENRIR_NATIVE_DIR/client.pid"
        export DYLD_INSERT_LIBRARIES="$FENRIR_NATIVE_DIR/controller.dylib"
        export SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS=1
        exec ./Moonlight.app/Contents/MacOS/Moonlight stream "$@" "$host" "$value"
        ;;
    *)
        echo "Unknown mode: $mode" >&2
        exit 1
        ;;
esac
