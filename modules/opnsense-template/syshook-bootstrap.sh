#!/bin/sh
# OPNsense Syshook Bootstrap Script
# Location: /usr/local/etc/rc.syshook.d/early/20-instance-config
#
# Golden template has SSH + root API key pre-baked.
# This script imports INSTANCE-SPECIFIC config from seed disk:
# - Network settings (IPs, interfaces, gateway)
# - Hostname
# - Firewall rules (optional)
#
# The seed disk contains a partial config that gets MERGED, not replaced.

MARKER="/conf/.instance-configured"
SEED_DEVICES="da1 da2 da3"
MOUNT_POINT="/tmp/seedmnt"
LOG="/var/log/instance-config.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [instance-config] $1" >> "$LOG"
    echo "[instance-config] $1"
}

# Skip if already configured for this instance
if [ -f "$MARKER" ]; then
    log "Instance already configured, skipping"
    exit 0
fi

log "First boot of cloned instance, searching for seed config..."
mkdir -p "$MOUNT_POINT"

for dev in $SEED_DEVICES; do
    for part in "/dev/${dev}s1" "/dev/${dev}p1" "/dev/${dev}"; do
        if [ -c "$part" ] || [ -b "$part" ]; then
            log "Trying $part..."
            
            if mount -t msdosfs "$part" "$MOUNT_POINT" 2>/dev/null; then
                log "Mounted $part"
                
                # Look for instance config
                if [ -f "$MOUNT_POINT/instance.xml" ]; then
                    log "Found instance.xml - applying instance config"
                    
                    # Use OPNsense's config system to merge
                    # This preserves SSH/API settings from golden template
                    /usr/local/sbin/pluginctl -c config_import "$MOUNT_POINT/instance.xml" 2>&1 | tee -a "$LOG"
                    
                    touch "$MARKER"
                    log "Instance configuration applied"
                    umount "$MOUNT_POINT"
                    exit 0
                fi
                
                # Fallback: full config.xml replacement
                if [ -f "$MOUNT_POINT/conf/config.xml" ]; then
                    log "Found full config.xml - replacing config"
                    cp /conf/config.xml /conf/config.xml.template-backup
                    cp "$MOUNT_POINT/conf/config.xml" /conf/config.xml
                    chmod 600 /conf/config.xml
                    touch "$MARKER"
                    log "Full config imported"
                    umount "$MOUNT_POINT"
                    exit 0
                fi
                
                umount "$MOUNT_POINT"
            fi
        fi
    done
done

log "No seed config found, using golden template defaults"
rmdir "$MOUNT_POINT" 2>/dev/null
exit 0
