#!/bin/bash
# Install Realtek r8126 5GbE driver on Proxmox VE 9.x
# Run this script on the Proxmox host as root

set -euo pipefail

echo "=== Installing Realtek RTL8126 5GbE Driver ==="
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "Error: Please run as root"
  exit 1
fi

# Install prerequisites
echo "Installing prerequisites..."
apt update
apt install -y pve-headers-$(uname -r) dkms git build-essential

# Clone the driver repository
echo "Cloning r8126-dkms driver..."
cd /tmp
rm -rf realtek-r8126-dkms
git clone https://github.com/awesometic/realtek-r8126-dkms.git
cd realtek-r8126-dkms

# Install the DKMS driver
echo "Installing DKMS driver..."
./dkms-install.sh

# Blacklist the r8169 driver to prevent conflicts
echo "Blacklisting r8169 driver..."
cat > /etc/modprobe.d/blacklist-r8169.conf << 'EOF'
# Blacklist r8169 to use r8126 for RTL8126 5GbE
blacklist r8169
EOF

# Update initramfs
echo "Updating initramfs..."
update-initramfs -u

echo ""
echo "=== Installation Complete ==="
echo ""
echo "The RTL8126 5GbE driver has been installed."
echo "A REBOOT is required to activate the driver."
echo ""
echo "After reboot, verify with:"
echo "  ip link show"
echo "  ethtool <interface_name>"
echo ""
echo "Would you like to reboot now? (y/n)"
read -r response
if [[ "$response" =~ ^[Yy]$ ]]; then
  echo "Rebooting..."
  reboot
else
  echo "Please reboot manually when ready."
fi
