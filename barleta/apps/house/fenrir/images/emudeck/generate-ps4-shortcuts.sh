#!/bin/bash
# Generate named symlinks for PS4 games by reading param.sfo
# This resolves CUSA* folder names → human-readable game titles
#
# Input:  /Emulation/roms/ps4/CUSA*/sce_sys/param.sfo
# Output: /Emulation/storage/ps4-games/<Game Title>.ps4 → /Emulation/roms/ps4/CUSA*/eboot.bin
#
# IMPORTANT: Symlinks point to eboot.bin (a file), NOT to the CUSA directory.
# ES-DE traverses directory symlinks but treats file symlinks as ROM entries.

set -euo pipefail

PS4_ROMS="${1:-/Emulation/roms/ps4}"
PS4_LINKS="${2:-/Emulation/storage/ps4-games}"

mkdir -p "$PS4_LINKS"

# Parse TITLE from param.sfo (Sony SFO binary format)
extract_sfo_title() {
    local sfo_file="$1"

    python3 -c "
import struct, sys

with open('$sfo_file', 'rb') as f:
    data = f.read()

# Validate magic
if data[:4] != b'\\x00PSF':
    sys.exit(1)

_, _, key_table_off, data_table_off, n_entries = struct.unpack_from('<IIIII', data, 0)

for i in range(n_entries):
    entry_off = 20 + i * 16
    key_off, fmt, data_len, data_max, d_off = struct.unpack_from('<HHIII', data, entry_off)

    # Read key name
    key_end = data.index(b'\\x00', key_table_off + key_off)
    key = data[key_table_off + key_off : key_end].decode('utf-8')

    if key == 'TITLE':
        val = data[data_table_off + d_off : data_table_off + d_off + data_len]
        title = val.rstrip(b'\\x00').decode('utf-8')
        print(title)
        break
" 2>/dev/null
}

count=0
skipped=0

for game_dir in "$PS4_ROMS"/*/; do
    [ -d "$game_dir" ] || continue

    # Skip our symlink directory if it's inside the roms dir
    [ "$(basename "$game_dir")" = "ps4-games" ] && continue

    sfo_file="$game_dir/sce_sys/param.sfo"
    if [ ! -f "$sfo_file" ]; then
        echo "WARN: No param.sfo in $(basename "$game_dir"), skipping"
        skipped=$((skipped + 1))
        continue
    fi

    eboot_file="$game_dir/eboot.bin"
    if [ ! -f "$eboot_file" ]; then
        echo "WARN: No eboot.bin in $(basename "$game_dir"), skipping"
        skipped=$((skipped + 1))
        continue
    fi

    title=$(extract_sfo_title "$sfo_file")
    if [ -z "$title" ]; then
        echo "WARN: Could not parse title from $(basename "$game_dir")/sce_sys/param.sfo"
        skipped=$((skipped + 1))
        continue
    fi

    # Sanitize title for filesystem (remove problematic chars)
    safe_title=$(echo "$title" | tr '/:*?"<>|\\' '_' | sed 's/  */ /g' | sed 's/^ *//;s/ *$//')

    # Create symlink: <Game Title>.ps4 -> eboot.bin (FILE symlink, not directory)
    # ES-DE treats file symlinks as ROM entries but traverses directory symlinks
    link_path="$PS4_LINKS/${safe_title}.ps4"

    # Remove stale symlink if target changed
    if [ -L "$link_path" ]; then
        existing_target=$(readlink "$link_path")
        if [ "$existing_target" = "$(realpath "$eboot_file")" ]; then
            count=$((count + 1))
            continue
        fi
        rm -f "$link_path"
    fi

    ln -sfn "$(realpath "$eboot_file")" "$link_path"
    echo "PS4: '${safe_title}' → $(basename "$game_dir")"
    count=$((count + 1))
done

echo "PS4 shortcuts: $count games linked, $skipped skipped"
