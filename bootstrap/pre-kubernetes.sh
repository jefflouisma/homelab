#!/bin/bash
# Pre-Kubernetes Bootstrap Script
# This script prepares the OS and installs K3s before Terraform can run.
# Run this ONCE on a fresh Ubuntu 24.04 system.

set -euo pipefail

LOG_FILE="/var/log/homelab-bootstrap.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=== Pre-Kubernetes Bootstrap Started at $(date) ==="

# --- 1. INSTALL REQUIRED PACKAGES ---
echo "Installing required packages..."
apt-get update && apt-get install -y curl git open-iscsi nfs-common wget gnupg lsb-release

# --- 2. INSTALL TERRAFORM ---
echo "Installing Terraform..."
wget -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor | tee /usr/share/keyrings/hashicorp-archive-keyring.gpg >/dev/null
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
  | tee /etc/apt/sources.list.d/hashicorp.list >/dev/null
apt-get update && apt-get install -y terraform

# --- 3. CREATE DATA DIRECTORIES ---
# Nexus runs as UID 200 (nexus user)
echo "Creating data directories..."
mkdir -p /mnt/data/nexus
chown -R 200:200 /mnt/data/nexus
chmod 755 /mnt/data/nexus

# --- 4. INSTALL K3S ---
# Disabling built-in components that Terraform will replace:
# - Flannel (replaced by Cilium)
# - Kube-Proxy (replaced by Cilium eBPF)
# - ServiceLB (replaced by MetalLB)
# - Traefik (not used)
echo "Installing K3s..."
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server \
  --flannel-backend=none \
  --disable-network-policy \
  --disable-kube-proxy \
  --disable servicelb \
  --disable traefik \
  --write-kubeconfig-mode 644" sh -

# --- 5. WAIT FOR K3S API ---
echo "Waiting for K3s API to be ready..."
until k3s kubectl get node &>/dev/null; do 
  sleep 5
done
echo "K3s API is ready."

# --- 6. SETUP KUBECONFIG ---
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
mkdir -p /root/.kube
rm -f /root/.kube/config 2>/dev/null || true
ln -sf /etc/rancher/k3s/k3s.yaml /root/.kube/config

# Also setup for the current user if not root
if [ -n "${SUDO_USER:-}" ]; then
  USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
  mkdir -p "$USER_HOME/.kube"
  cp /etc/rancher/k3s/k3s.yaml "$USER_HOME/.kube/config"
  chown -R "$SUDO_USER:$SUDO_USER" "$USER_HOME/.kube"
  echo "Kubeconfig copied to $USER_HOME/.kube/config"
fi

# --- 7. INSTALL HELM ---
echo "Installing Helm..."
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# --- 8. VERIFY ---
echo ""
echo "==========================================="
echo "=== Pre-Kubernetes Setup Complete ==="
echo "==========================================="
echo ""
echo "K3s version: $(k3s --version | head -1)"
echo "Helm version: $(helm version --short)"
echo "Node status:"
kubectl get nodes
echo ""
echo "Next step: Run Terraform to install Cilium, MetalLB, and ArgoCD"
echo ""
echo "  cd terraform"
echo "  terraform init"
echo "  terraform apply"
echo ""
