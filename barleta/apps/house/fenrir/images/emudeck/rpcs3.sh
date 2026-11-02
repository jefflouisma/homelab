#!/bin/sh
set -eu

# Runs the RPCS3 build this session pinned from Fenrir Updates.
# Guest data stays in $HOME/.config/rpcs3, separate from the read-only package.
package="$(package-path rpcs3)"
export LD_LIBRARY_PATH="$package/usr/lib:${LD_LIBRARY_PATH:-}"
cd "$package"
exec ./AppRun "$@"
