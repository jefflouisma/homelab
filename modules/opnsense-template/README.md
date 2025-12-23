# OPNsense Golden Template

## Overview

CI/CD pattern for fully automated OPNsense deployment:

```
┌─────────────────────────────────────────────────────────────────────────┐
│  GOLDEN TEMPLATE (VM ID 9000)                                           │
│  ├── OPNsense installed to disk                                         │
│  ├── SSH enabled (all interfaces, root login)                          │
│  ├── Root API key pre-configured                                        │
│  ├── Syshook: /usr/local/etc/rc.syshook.d/early/20-instance-config     │
│  └── Default firewall: allow SSH/HTTPS management                       │
└─────────────────────────────────────────────────────────────────────────┘
                              │ clone
                              ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  CLONED INSTANCE + SEED DISK                                            │
│  ├── Terraform clones template                                          │
│  ├── Attaches seed disk with instance.xml (IPs, hostname, rules)       │
│  ├── Syshook imports instance config on first boot                     │
│  └── Immediately accessible via SSH/API                                 │
└─────────────────────────────────────────────────────────────────────────┘
                              │ API
                              ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  GITOPS LAYER (Terraform/OPNsense Provider)                             │
│  ├── Manage aliases, rules declaratively                                │
│  ├── API: POST /api/firewall/filter/savepoint                          │
│  ├── Apply changes with auto-rollback on failure                        │
│  └── Safe apply pattern prevents lockouts                               │
└─────────────────────────────────────────────────────────────────────────┘
```

## What's Baked Into Golden Template

| Feature | Setting | Purpose |
|---------|---------|---------|
| SSH | Enabled on wan,lan | Immediate access after clone |
| Root login | Permitted | Infrastructure automation |
| API key | Pre-configured | Terraform/API access without GUI |
| Firewall | Allow SSH/HTTPS from any | Management access |
| Syshook | 20-instance-config | Auto-import seed config |

## Creating the Golden Template (One-time)

### Step 1: Create VM and Install OPNsense

```bash
# On Proxmox host
qm create 9000 --name opnsense-golden --memory 2048 --cores 2 \
  --net0 virtio,bridge=vmbr0 \
  --net1 virtio,bridge=vmbr1 \
  --scsihw virtio-scsi-pci \
  --scsi0 local-lvm:8,ssd=1 \
  --ide2 local:iso/OPNsense-25.1-dvd-amd64.iso,media=cdrom \
  --boot order=ide2

qm start 9000
# Console: Install OPNsense (UFS), reboot, then shutdown
```

### Step 2: Generate API Credentials

```bash
# Generate credentials for golden template
export GOLDEN_API_KEY=$(openssl rand -hex 20)
export GOLDEN_API_SECRET=$(openssl rand -hex 20)
export GOLDEN_API_SECRET_HASH=$(openssl passwd -6 "$GOLDEN_API_SECRET")

echo "Save these credentials:"
echo "API Key:    $GOLDEN_API_KEY"
echo "API Secret: $GOLDEN_API_SECRET"
echo "API Hash:   $GOLDEN_API_SECRET_HASH"
```

### Step 3: Bake SSH + API + Syshook

```bash
# Start VM temporarily to configure
qm start 9000
# Wait for boot, get DHCP IP from console

# SSH in (default password: opnsense)
ssh root@<dhcp-ip>

# Create syshook directory and script
mkdir -p /usr/local/etc/rc.syshook.d/early
cat > /usr/local/etc/rc.syshook.d/early/20-instance-config << 'SYSHOOK'
#!/bin/sh
# Instance config import - see syshook-bootstrap.sh for full version
MARKER="/conf/.instance-configured"
[ -f "$MARKER" ] && exit 0

for dev in da1 da2; do
  for part in "/dev/${dev}s1" "/dev/${dev}"; do
    mkdir -p /tmp/seed
    if mount -t msdosfs "$part" /tmp/seed 2>/dev/null; then
      if [ -f /tmp/seed/conf/config.xml ]; then
        cp /conf/config.xml /conf/config.xml.golden-backup
        cp /tmp/seed/conf/config.xml /conf/config.xml
        touch "$MARKER"
        umount /tmp/seed
        exit 0
      fi
      umount /tmp/seed
    fi
  done
done
SYSHOOK
chmod +x /usr/local/etc/rc.syshook.d/early/20-instance-config

# Verify SSH is enabled (should be by default after install)
grep -A5 '<ssh>' /conf/config.xml

# Add API key to root user (edit /conf/config.xml)
# Find <user><name>root</name> section and add:
#   <apikeys>
#     <item>
#       <key>YOUR_GOLDEN_API_KEY</key>
#       <secret>YOUR_GOLDEN_API_SECRET_HASH</secret>
#     </item>
#   </apikeys>

# Or use the web UI: System > Access > Users > root > API keys

# Clean up instance-specific state
rm -f /conf/.instance-configured
rm -f /conf/config.xml.*backup

# Shutdown
poweroff
```

### Step 4: Convert to Template

```bash
# Remove CD-ROM
qm set 9000 --delete ide2

# Convert to template (makes it read-only, clonable)
qm template 9000
```

## Seed Disk Structure

The seed disk is a FAT-formatted image with instance-specific config:

```
/conf/config.xml    # Full OPNsense config (replaces golden defaults)
```

## Terraform Usage

```hcl
# Clone golden template
resource "proxmox_virtual_environment_vm" "opnsense" {
  name      = "practice-opnsense"
  node_name = "pve"
  
  clone {
    vm_id = 9000  # Golden template
  }
  
  # Instance-specific NICs
  network_device { bridge = "vmbr0" }  # WAN
  network_device { bridge = "vmbr1" }  # LAN
}

# Attach seed disk with instance config
resource "null_resource" "attach_seed" {
  depends_on = [proxmox_virtual_environment_vm.opnsense]
  # ... create FAT disk, copy config.xml, attach via qm
}
```

## GitOps: Firewall Rules via API

After deployment, manage rules via OPNsense API with safe apply:

```bash
# Create savepoint before changes
curl -X POST "https://opnsense/api/firewall/filter/savepoint" \
  -u "key:secret" -k

# Add rule
curl -X POST "https://opnsense/api/firewall/filter/addRule" \
  -u "key:secret" -k \
  -d '{"rule":{"interface":"lan","descr":"Allow HTTP"}}'

# Apply with auto-rollback (60s timeout)
curl -X POST "https://opnsense/api/firewall/filter/apply/REVISION" \
  -u "key:secret" -k

# If locked out, changes auto-revert after timeout
```

## Files

| File | Purpose |
|------|---------|
| `golden-config.xml` | Reference config for golden template |
| `syshook-bootstrap.sh` | Full syshook script with logging |
| `README.md` | This documentation |
