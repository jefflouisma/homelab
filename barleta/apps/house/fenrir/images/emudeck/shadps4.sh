#!/bin/sh
set -eu

# Runs the shadPS4 release this session pinned from Fenrir Updates.
# Guest data stays in $HOME/.local/share/shadPS4, separate from the read-only package.
package="$(package-path shadps4)"
export LD_LIBRARY_PATH="$package/usr/lib:${LD_LIBRARY_PATH:-}"
cd "$package"
exec ./AppRun "$@"
