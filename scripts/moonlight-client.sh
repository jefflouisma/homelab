#!/bin/bash
set -euo pipefail

umask 077
moonlight_dir=/Volumes/4TB_Drive/tmp/fenrir/moonlight
mkdir -p "$moonlight_dir"
touch "$moonlight_dir/portable.dat"
export TMPDIR="$moonlight_dir"
cd "$moonlight_dir"

exec /Applications/Moonlight.app/Contents/MacOS/Moonlight "$@"
