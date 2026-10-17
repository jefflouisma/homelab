#!/bin/bash
set -euo pipefail

firmware_dir="${HOME}/.config/rpcs3/dev_flash"
firmware_pup=/Emulation/bios/ps3/PS3UPDAT.PUP

firmware_ready() {
    [ -s "$firmware_dir/vsh/etc/version.txt" ] &&
        [ -s "$firmware_dir/sys/external/liblv2.sprx" ] &&
        [ -s "$firmware_dir/sys/external/libsysmodule.sprx" ]
}

if firmware_ready || [ ! -f "$firmware_pup" ]; then
    exit 0
fi

echo "Installing PS3 firmware into the persistent profile..."
installer_status=0
(ulimit -c 0; QT_QPA_PLATFORM=offscreen timeout 120 rpcs3 --headless --installfw "$firmware_pup") || installer_status=$?

# RPCS3 0.0.43 can abort during installer teardown after writing the firmware.
if ! firmware_ready; then
    echo "ERROR: PS3 firmware files are incomplete (installer status $installer_status)." >&2
    exit 1
fi
if [ "$installer_status" -ne 0 ]; then
    echo "RPCS3 installer exited with status $installer_status; installed firmware files verified."
fi
