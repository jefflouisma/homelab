#!/bin/bash
# Phase 0: Backup Script for Barleta Migration
# Run this before starting the Harvester migration

set -euo pipefail

BACKUP_DIR="$(dirname "$0")/../backups/$(date +%Y%m%d_%H%M%S)"
KUBECONFIG_PRACTICE="$(dirname "$0")/../kubeconfig-homepractice.yaml"

echo "=== Barleta Migration - Phase 0 Backup ==="
echo "Backup directory: ${BACKUP_DIR}"
mkdir -p "${BACKUP_DIR}"

# -----------------------------------------------------------------------------
# 1. Document Current Network Configuration
# -----------------------------------------------------------------------------
echo ""
echo "--- Documenting Network Configuration ---"

cat > "${BACKUP_DIR}/network-config.md" << 'EOF'
# HomePractice Network Configuration

## Network Topology

| Network | CIDR | Gateway | Description |
|---------|------|---------|-------------|
| Home LAN | 192.168.1.0/24 | 192.168.1.254 | Home network |
| Practice LAN | 10.10.10.0/24 | 10.10.10.1 | Isolated HomePractice network |

## VM IP Addresses

| VM | IP Address | Network | Purpose |
|----|------------|---------|---------|
| Proxmox Host | 192.168.1.30 | Home LAN | Hypervisor |
| OPNsense WAN | 192.168.1.40 | Home LAN | Firewall WAN |
| OPNsense LAN | 10.10.10.1 | Practice LAN | Firewall LAN/Gateway |
| K3s Node | 10.10.10.10 | Practice LAN | Kubernetes |
| FreeIPA | 10.10.10.212 | Practice LAN | Identity |
| AdGuard Home | 192.168.1.10 | Home LAN | DNS |

## MetalLB IP Pool

| Range | Purpose |
|-------|---------|
| 10.10.10.200-10.10.10.250 | LoadBalancer services |

## Key Service IPs (MetalLB)

| Service | IP | Port |
|---------|-----|------|
| ArgoCD | 10.10.10.200 | 443 |
| Keycloak | 10.10.10.210 | 443 |
| MidPoint | 10.10.10.211 | 443 |
| PostgreSQL | 10.10.10.213 | 5432 |

## DNS Configuration

- AdGuard Home at 192.168.1.10 forwards `*.practice.local` to OPNsense (10.10.10.1)
- OPNsense Unbound handles practice.local zone
EOF

echo "Network configuration documented"

# -----------------------------------------------------------------------------
# 2. Export Kubernetes Manifests
# -----------------------------------------------------------------------------
echo ""
echo "--- Exporting Kubernetes Manifests ---"

if [ -f "${KUBECONFIG_PRACTICE}" ]; then
  export KUBECONFIG="${KUBECONFIG_PRACTICE}"
  
  mkdir -p "${BACKUP_DIR}/k8s-manifests"
  
  # Export all namespaces
  kubectl get namespaces -o yaml > "${BACKUP_DIR}/k8s-manifests/namespaces.yaml" 2>/dev/null || echo "Could not export namespaces"
  
  # Export key resources per namespace
  for ns in argocd identity devops metallb-system cert-manager actions-runner-system; do
    if kubectl get namespace "${ns}" &>/dev/null; then
      mkdir -p "${BACKUP_DIR}/k8s-manifests/${ns}"
      kubectl get all -n "${ns}" -o yaml > "${BACKUP_DIR}/k8s-manifests/${ns}/all.yaml" 2>/dev/null || true
      kubectl get configmaps -n "${ns}" -o yaml > "${BACKUP_DIR}/k8s-manifests/${ns}/configmaps.yaml" 2>/dev/null || true
      kubectl get secrets -n "${ns}" -o yaml > "${BACKUP_DIR}/k8s-manifests/${ns}/secrets.yaml" 2>/dev/null || true
      kubectl get pvc -n "${ns}" -o yaml > "${BACKUP_DIR}/k8s-manifests/${ns}/pvc.yaml" 2>/dev/null || true
      echo "Exported ${ns} namespace"
    fi
  done
  
  # Export CRDs
  kubectl get applications.argoproj.io -A -o yaml > "${BACKUP_DIR}/k8s-manifests/argocd-applications.yaml" 2>/dev/null || true
  kubectl get ipaddresspools.metallb.io -A -o yaml > "${BACKUP_DIR}/k8s-manifests/metallb-pools.yaml" 2>/dev/null || true
  
  echo "Kubernetes manifests exported"
else
  echo "WARNING: kubeconfig-homepractice.yaml not found, skipping K8s export"
fi

# -----------------------------------------------------------------------------
# 3. Backup Credentials and Keys
# -----------------------------------------------------------------------------
echo ""
echo "--- Backing up Credentials ---"

mkdir -p "${BACKUP_DIR}/credentials"

# Copy SSH keys (public only for reference)
cp "$(dirname "$0")/../id_rsa.pub" "${BACKUP_DIR}/credentials/" 2>/dev/null || true
cp "$(dirname "$0")/../argocd-deploy-key.pub" "${BACKUP_DIR}/credentials/" 2>/dev/null || true

# Document key locations (don't copy private keys to backup)
cat > "${BACKUP_DIR}/credentials/key-locations.md" << 'EOF'
# Key Locations

## SSH Keys
- User SSH Key: `id_rsa` / `id_rsa.pub` (project root)
- ArgoCD Deploy Key: `argocd-deploy-key` / `argocd-deploy-key.pub` (project root)

## GitHub App
- Private Key: `g913-k8s-prod-arc.2025-12-21.private-key.pem` (project root)
- App ID: 2512413
- Installation ID: 100583737

## OPNsense API
- API credentials in `homepractice/infrastructure/terraform.tfvars`
- Also in `homepractice/ansible/inventory.yml`

## Proxmox API
- Token: `root@pam!root-api`
- Endpoint: https://192.168.1.30:8006/api2/json
EOF

echo "Credentials documented"

# -----------------------------------------------------------------------------
# 4. Backup Terraform State
# -----------------------------------------------------------------------------
echo ""
echo "--- Backing up Terraform State ---"

mkdir -p "${BACKUP_DIR}/terraform-state"

for dir in homepractice/infrastructure homepractice/kubernetes homeprod/infrastructure; do
  if [ -f "$(dirname "$0")/../${dir}/terraform.tfstate" ]; then
    mkdir -p "${BACKUP_DIR}/terraform-state/$(dirname ${dir})"
    cp "$(dirname "$0")/../${dir}/terraform.tfstate" "${BACKUP_DIR}/terraform-state/${dir}/" 2>/dev/null || true
    echo "Backed up ${dir}/terraform.tfstate"
  fi
done

# -----------------------------------------------------------------------------
# 5. Create FreeIPA Backup Command Reference
# -----------------------------------------------------------------------------
echo ""
echo "--- FreeIPA Backup Instructions ---"

cat > "${BACKUP_DIR}/freeipa-backup.md" << 'EOF'
# FreeIPA Backup Instructions

SSH to FreeIPA VM and run:

```bash
# Full backup (data + configuration)
sudo ipa-backup

# Data-only backup
sudo ipa-backup --data

# Backups stored in /var/lib/ipa/backup/
ls -la /var/lib/ipa/backup/
```

Copy backup files:
```bash
scp fedora@10.10.10.212:/var/lib/ipa/backup/ipa-full-* ./
```

## Restore (on new FreeIPA)

```bash
sudo ipa-restore /var/lib/ipa/backup/ipa-full-XXXX-XX-XX-XX-XX-XX
```
EOF

echo "FreeIPA backup instructions created"

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo ""
echo "=== Phase 0 Backup Complete ==="
echo ""
echo "Backup location: ${BACKUP_DIR}"
echo ""
echo "Contents:"
ls -la "${BACKUP_DIR}"
echo ""
echo "IMPORTANT: Manual steps required:"
echo "1. SSH to FreeIPA (10.10.10.212) and run: sudo ipa-backup"
echo "2. Copy the backup: scp fedora@10.10.10.212:/var/lib/ipa/backup/ipa-full-* ${BACKUP_DIR}/"
echo "3. Export Keycloak realm: Admin Console → Realm Settings → Export"
echo "4. Backup PostgreSQL: pg_dump -h 10.10.10.213 -U postgres keycloak > keycloak.sql"
echo ""
