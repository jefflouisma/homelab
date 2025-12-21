#!/bin/bash
set -euo pipefail

LOG_FILE="/var/log/homelab-bootstrap.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=== Homelab Bootstrap Started at $(date) ==="

# --- 1. PREP SYSTEM ---
apt-get update && apt-get install -y curl git open-iscsi nfs-common

# Create data directories
mkdir -p /mnt/data/nexus

# --- 2. INSTALL K3S (Production Config) ---
# Disabling Flannel (CNI), Kube-Proxy, Network Policy, and Traefik
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server \
  --flannel-backend=none \
  --disable-network-policy \
  --disable-kube-proxy \
  --disable servicelb \
  --disable traefik \
  --write-kubeconfig-mode 644" sh -

# Wait for K3s API to be ready
echo "Waiting for K3s API..."
until k3s kubectl get node &>/dev/null; do sleep 5; done
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# --- 3. INSTALL HELM ---
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# --- 4. INSTALL CILIUM (CNI & Security) ---
helm repo add cilium https://helm.cilium.io/
helm repo update
helm upgrade --install cilium cilium/cilium --version 1.17.0 \
   --namespace kube-system \
   --set kubeProxyReplacement=true \
   --set k8sServiceHost=127.0.0.1 \
   --set k8sServicePort=6443 \
   --set hubble.enabled=true \
   --set hubble.relay.enabled=true \
   --set hubble.ui.enabled=true

# Wait for Cilium to be ready
echo "Waiting for Cilium to be ready..."
kubectl wait --for=condition=Ready pods -l app.kubernetes.io/name=cilium-agent -n kube-system --timeout=300s

# --- 5. INSTALL METALLB (Load Balancer) ---
helm repo add metallb https://metallb.github.io/metallb
helm upgrade --install metallb metallb/metallb --namespace metallb-system --create-namespace

# Wait for MetalLB controller and CRDs to be ready
echo "Waiting for MetalLB controller..."
kubectl wait --for=condition=Ready pods -l app.kubernetes.io/component=controller -n metallb-system --timeout=120s
kubectl wait --for=condition=Established crd/ipaddresspools.metallb.io --timeout=60s
kubectl wait --for=condition=Established crd/l2advertisements.metallb.io --timeout=60s

# Apply MetalLB configuration
kubectl apply -f https://raw.githubusercontent.com/jefflouisma/homelab/main/infrastructure/metallb-config.yaml

# --- 6. INSTALL ARGOCD (GitOps) ---
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for ArgoCD to be ready
echo "Waiting for ArgoCD server..."
kubectl wait --for=condition=Ready pods -l app.kubernetes.io/name=argocd-server -n argocd --timeout=300s

# --- 7. APPLY NAMESPACES ---
kubectl apply -f https://raw.githubusercontent.com/jefflouisma/homelab/main/infrastructure/namespaces.yaml

# --- 8. TRIGGER THE GITOPS SYNC ---
# This connects the cluster back to YOUR repo
kubectl apply -f https://raw.githubusercontent.com/jefflouisma/homelab/main/apps/argocd-root.yaml

echo ""
echo "=== Bootstrap Complete at $(date) ==="
echo ""
echo "ArgoCD Initial Admin Password:"
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
echo ""
echo ""
echo "Access ArgoCD with: kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "Then visit: https://localhost:8080"

