#!/bin/bash
set -euo pipefail
output=${1:?Usage: build.sh OUTPUT_DIRECTORY}
source_dir=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$output/classes"
javac --release 17 -encoding UTF-8 -Xlint:all -d "$output/classes" "$source_dir"/*.java
java -Djava.awt.headless=true -cp "$output/classes" games.fenrir.cove.RemoteInputTest
printf 'Premain-Class: games.fenrir.cove.CoveRemoteLauncher\n\n' > "$output/MANIFEST.MF"
jar cfm "$output/cove-remote.jar" "$output/MANIFEST.MF" -C "$output/classes" .
if [[ $# -ge 2 ]]; then
    mkdir -p "$output/back"
    javac --release 17 -encoding UTF-8 -Xlint:all -cp "$2/*:$output/cove-remote.jar" -d "$output/back" "$source_dir"/back/*.java
fi
