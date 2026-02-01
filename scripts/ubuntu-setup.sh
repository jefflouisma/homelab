#!/bin/bash
# Barleta Homelab - Ubuntu Server Setup Script
# Run this after fresh Ubuntu Server 24.04 LTS installation
# Usage: curl -sSL https://raw.githubusercontent.com/jefflouisma/homelab/main/scripts/ubuntu-setup.sh | bash

set -e

echo "=== Barleta Homelab Setup ==="
echo "Setting up Ubuntu Server with Nix + Home Manager + K3s"
echo ""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ===========================================
# 1. SYSTEM UPDATES
# ===========================================
info "Updating system packages..."
sudo apt update && sudo apt upgrade -y

# ===========================================
# 2. INSTALL ESSENTIAL PACKAGES
# ===========================================
info "Installing essential packages..."
sudo apt install -y \
    build-essential \
    curl \
    wget \
    git \
    zsh \
    ca-certificates \
    gnupg \
    lsb-release

# ===========================================
# 3. INSTALL DOCKER
# ===========================================
info "Installing Docker..."
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com | sudo sh
    sudo usermod -aG docker $USER
    info "Docker installed. You'll need to log out and back in for group changes."
else
    info "Docker already installed."
fi

# ===========================================
# 4. INSTALL NVIDIA DRIVERS (if GPU present)
# ===========================================
if lspci | grep -i nvidia &> /dev/null; then
    info "NVIDIA GPU detected. Installing drivers..."
    sudo apt install -y nvidia-driver-570 nvidia-container-toolkit
    sudo nvidia-ctk runtime configure --runtime=docker
    sudo systemctl restart docker
else
    warn "No NVIDIA GPU detected, skipping driver installation."
fi

# ===========================================
# 5. INSTALL NIX PACKAGE MANAGER
# ===========================================
info "Installing Nix package manager..."
if ! command -v nix &> /dev/null; then
    curl -L https://nixos.org/nix/install | sh -s -- --daemon --yes
    
    # Enable flakes
    mkdir -p ~/.config/nix
    echo "experimental-features = nix-command flakes" >> ~/.config/nix/nix.conf
    
    # Source nix
    . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
else
    info "Nix already installed."
fi

# ===========================================
# 6. INSTALL HOME MANAGER
# ===========================================
info "Installing Home Manager..."
if ! command -v home-manager &> /dev/null; then
    nix-channel --add https://github.com/nix-community/home-manager/archive/release-24.11.tar.gz home-manager
    nix-channel --update
    nix-shell '<home-manager>' -A install
else
    info "Home Manager already installed."
fi

# ===========================================
# 7. CLONE HOMELAB REPO
# ===========================================
info "Cloning homelab repository..."
if [ ! -d ~/homelab ]; then
    git clone https://github.com/jefflouisma/homelab.git ~/homelab
else
    info "Homelab repo already exists, pulling latest..."
    cd ~/homelab && git pull
fi

# ===========================================
# 8. APPLY HOME MANAGER CONFIG
# ===========================================
info "Applying Home Manager configuration..."
cd ~/homelab/home-manager
home-manager switch --flake .#jeff

# ===========================================
# 9. INSTALL K3S
# ===========================================
info "Installing K3s Kubernetes..."
if ! command -v k3s &> /dev/null; then
    curl -sfL https://get.k3s.io | sh -s - \
        --write-kubeconfig-mode 644 \
        --disable traefik \
        --disable servicelb
    
    # Setup kubectl config
    mkdir -p ~/.kube
    sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
    sudo chown $USER:$USER ~/.kube/config
else
    info "K3s already installed."
fi

# ===========================================
# 10. SET ZSH AS DEFAULT SHELL
# ===========================================
info "Setting Zsh as default shell..."
if [ "$SHELL" != "$(which zsh)" ]; then
    chsh -s $(which zsh)
fi

# ===========================================
# DONE
# ===========================================
echo ""
echo "=========================================="
echo -e "${GREEN}Setup Complete!${NC}"
echo "=========================================="
echo ""
echo "Next steps:"
echo "  1. Log out and back in (for Docker group + Zsh)"
echo "  2. Verify K3s: kubectl get nodes"
echo "  3. Install ArgoCD: kubectl apply -k ~/homelab/barleta/argocd"
echo ""
echo "Your environment is now managed by Home Manager."
echo "To update: cd ~/homelab/home-manager && home-manager switch --flake .#jeff"
echo ""
