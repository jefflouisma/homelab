#!/bin/bash
# Upload cloud images and ISOs to Proxmox
# Run this script from your local machine (requires curl and wget)

set -euo pipefail

# Configuration - update these if needed
PROXMOX_HOST="192.168.1.228:8006"
PROXMOX_NODE="g913-proxmox"
API_TOKEN="root@pam!root-api=e45c5f37-8b74-472e-9c42-1a991ef421af"

DOWNLOAD_DIR="/tmp/proxmox-images"
mkdir -p "$DOWNLOAD_DIR"

echo "=== Proxmox Image Upload Script ==="
echo ""

# --- 1. Download Ubuntu Cloud Image ---
UBUNTU_IMG="ubuntu-24.04-server-cloudimg-amd64.img"
UBUNTU_URL="https://cloud-images.ubuntu.com/releases/24.04/release/$UBUNTU_IMG"

if [ ! -f "$DOWNLOAD_DIR/$UBUNTU_IMG" ]; then
  echo "Downloading Ubuntu 24.04 cloud image..."
  wget -O "$DOWNLOAD_DIR/$UBUNTU_IMG" "$UBUNTU_URL"
else
  echo "Ubuntu cloud image already downloaded."
fi

# --- 2. Upload Ubuntu Cloud Image to Proxmox ---
echo "Uploading Ubuntu cloud image to Proxmox..."
curl -k -X POST "https://$PROXMOX_HOST/api2/json/nodes/$PROXMOX_NODE/storage/local/upload" \
  -H "Authorization: PVEAPIToken=$API_TOKEN" \
  -F "content=iso" \
  -F "filename=@$DOWNLOAD_DIR/$UBUNTU_IMG"

echo ""
echo "Ubuntu cloud image uploaded successfully!"

# --- 3. OPNsense ISO ---
echo ""
echo "=== OPNsense ISO ==="
echo "Download OPNsense manually from: https://opnsense.org/download/"
echo "Select: Architecture=amd64, Image Type=dvd, Mirror=closest"
echo ""
echo "After download, upload with:"
echo "  curl -k -X POST \"https://$PROXMOX_HOST/api2/json/nodes/$PROXMOX_NODE/storage/local/upload\" \\"
echo "    -H \"Authorization: PVEAPIToken=$API_TOKEN\" \\"
echo "    -F \"content=iso\" \\"
echo "    -F \"filename=@/path/to/OPNsense-24.7-dvd-amd64.iso\""
echo ""

# --- 4. Verify uploads ---
echo "=== Current ISO Storage Contents ==="
curl -k -s "https://$PROXMOX_HOST/api2/json/nodes/$PROXMOX_NODE/storage/local/content" \
  -H "Authorization: PVEAPIToken=$API_TOKEN" | python3 -m json.tool

echo ""
echo "=== Done ==="
