#!/bin/sh
# Extract AppImage contents without executing the binary.
# Needed for cross-arch Docker builds (ARM Mac → x86_64 container).
# Supports both squashfs (standard) and DwarFS (used by some newer AppImages).
# Usage: extract-appimage.sh <appimage-file> <dest-dir>
set -e

APPIMAGE="$1"
DEST="$2"

if [ -z "$APPIMAGE" ] || [ -z "$DEST" ]; then
    echo "Usage: $0 <appimage-file> <dest-dir>" >&2
    exit 1
fi

echo "Analyzing $APPIMAGE..."

# Detect filesystem type and find offset using Python
RESULT=$(python3 -c "
import struct, sys

with open(sys.argv[1], 'rb') as f:
    data = f.read()

# 1) Check for DwarFS magic (DWARFS followed by version bytes)
elf_end = 0
if len(data) > 64:
    e_shoff = struct.unpack_from('<Q', data, 40)[0]
    e_shentsize = struct.unpack_from('<H', data, 58)[0]
    e_shnum = struct.unpack_from('<H', data, 60)[0]
    elf_end = e_shoff + e_shentsize * e_shnum

# Check at ELF end for DwarFS magic
if elf_end > 0 and elf_end + 6 <= len(data):
    if data[elf_end:elf_end+6] == b'DWARFS':
        print(f'dwarfs:{elf_end}')
        sys.exit(0)

# 2) Search for valid squashfs superblock
pos = 0
while True:
    idx = data.find(b'hsqs', pos)
    if idx < 0:
        break
    if idx + 24 <= len(data):
        inode_count = struct.unpack_from('<I', data, idx + 4)[0]
        block_size  = struct.unpack_from('<I', data, idx + 12)[0]
        comp_type   = struct.unpack_from('<H', data, idx + 20)[0]
        block_log   = struct.unpack_from('<H', data, idx + 22)[0]
        if (inode_count > 0
            and 4096 <= block_size <= 1048576
            and (block_size & (block_size - 1)) == 0
            and 1 <= comp_type <= 6
            and 12 <= block_log <= 20):
            print(f'squashfs:{idx}')
            sys.exit(0)
    pos = idx + 1

# 3) Fallback: search for DwarFS anywhere past 64KB
idx = data.find(b'DWARFS', 65536)
if idx >= 0:
    print(f'dwarfs:{idx}')
    sys.exit(0)

sys.exit(1)
" "$APPIMAGE" 2>/dev/null)

if [ -z "$RESULT" ]; then
    echo "ERROR: Could not detect filesystem in $APPIMAGE" >&2
    exit 1
fi

FS_TYPE=$(echo "$RESULT" | cut -d: -f1)
OFFSET=$(echo "$RESULT" | cut -d: -f2)

case "$FS_TYPE" in
    squashfs)
        echo "Found squashfs at offset $OFFSET, extracting with unsquashfs..."
        unsquashfs -d "$DEST" -offset "$OFFSET" "$APPIMAGE"
        ;;
    dwarfs)
        echo "Found DwarFS at offset $OFFSET, extracting with dwarfsextract..."
        if ! command -v dwarfsextract >/dev/null 2>&1; then
            echo "ERROR: dwarfsextract not found. Install it first." >&2
            exit 1
        fi
        mkdir -p "$DEST"
        dwarfsextract -i "$APPIMAGE" -o "$DEST" --image-offset "$OFFSET"
        ;;
    *)
        echo "ERROR: Unknown filesystem type: $FS_TYPE" >&2
        exit 1
        ;;
esac

echo "Extraction complete: $DEST"
