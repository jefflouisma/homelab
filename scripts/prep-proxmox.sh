#!/bin/bash
# Proxmox Host Preparation Script
# Run this on a fresh Proxmox VE 9.1 installation

set -euo pipefail

echo "=== Proxmox Host Preparation ==="
echo ""

# --- 1. CREATE ISOLATED BRIDGE (vmbr1) ---
echo "Checking for vmbr1..."
if ! grep -q "vmbr1" /etc/network/interfaces; then
  echo "Creating vmbr1 (isolated bridge for HomePractice)..."
  cat >> /etc/network/interfaces << 'EOF'

auto vmbr1
iface vmbr1 inet static
    address 10.10.10.254/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    # Isolated bridge for HomePractice lab network
EOF
  echo "vmbr1 added. Applying network config..."
  ifreload -a || systemctl restart networking
else
  echo "vmbr1 already exists."
fi

# --- 2. DOWNLOAD CLOUD IMAGES ---
ISO_DIR="/var/lib/vz/template/iso"
mkdir -p "$ISO_DIR"

UBUNTU_IMG="ubuntu-24.04-server-cloudimg-amd64.img"
UBUNTU_URL="https://cloud-images.ubuntu.com/releases/24.04/release/$UBUNTU_IMG"

if [ ! -f "$ISO_DIR/$UBUNTU_IMG" ]; then
  echo "Downloading Ubuntu 24.04 cloud image..."
  wget -O "$ISO_DIR/$UBUNTU_IMG" "$UBUNTU_URL"
else
  echo "Ubuntu cloud image already exists."
fi

echo ""
echo "Note: Download OPNsense ISO manually from https://opnsense.org/download/"
echo "Upload to: $ISO_DIR/OPNsense-24.7-dvd-amd64.iso"

# --- 3. CREATE API TOKEN ---
echo ""
echo "=== API Token Setup ==="
echo ""
echo "Create an API token for Terraform:"
echo "  1. Go to Datacenter -> Permissions -> API Tokens"
echo "  2. Add token for 'root@pam' user"
echo "  3. Token ID: terraform"
echo "  4. Uncheck 'Privilege Separation'"
echo "  5. Save the token secret!"
echo ""

# --- 4. SUMMARY ---
echo "=== Preparation Complete ==="
echo ""
echo "Resources created/verified:"
echo "  - vmbr1 (isolated bridge): 10.10.10.254/24"
echo "  - Ubuntu cloud image: $ISO_DIR/$UBUNTU_IMG"
echo ""
echo "Next steps:"
echo "  1. Create API token (see above)"
echo "  2. Upload OPNsense ISO"
echo "  3. Run: cd homepractice/infrastructure && terraform apply"
echo ""
