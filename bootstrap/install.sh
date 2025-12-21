#!/bin/bash
set -euo pipefail

LOG_FILE="/var/log/homelab-bootstrap.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=== Homelab Bootstrap Started at $(date) ==="

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

echo "Script running from: $SCRIPT_DIR"
echo "Repo directory: $REPO_DIR"

# --- 1. PREP SYSTEM ---
apt-get update && apt-get install -y curl git open-iscsi nfs-common

# Create data directories with correct ownership
# Nexus runs as UID 200 (nexus user)
mkdir -p /mnt/data/nexus
chown -R 200:200 /mnt/data/nexus
chmod 755 /mnt/data/nexus

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

# Make kubectl available without k3s prefix
mkdir -p /root/.kube
rm -f /root/.kube/config 2>/dev/null || true
ln -sf /etc/rancher/k3s/k3s.yaml /root/.kube/config

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

# Wait for Cilium to be ready (use k8s-app label which is set immediately)
echo "Waiting for Cilium to be ready..."
# First wait for the daemonset to create pods
sleep 10
# Then wait for pods to be ready using the correct label
kubectl wait --for=condition=Ready pods -l k8s-app=cilium -n kube-system --timeout=300s || \
  kubectl wait --for=condition=Ready pods -l app.kubernetes.io/name=cilium-agent -n kube-system --timeout=300s

# --- 5. INSTALL METALLB (Load Balancer) ---
helm repo add metallb https://metallb.github.io/metallb
helm upgrade --install metallb metallb/metallb --namespace metallb-system --create-namespace

# Wait for MetalLB controller and CRDs to be ready
echo "Waiting for MetalLB controller..."
sleep 5
kubectl wait --for=condition=Ready pods -l app.kubernetes.io/component=controller -n metallb-system --timeout=120s
kubectl wait --for=condition=Established crd/ipaddresspools.metallb.io --timeout=60s
kubectl wait --for=condition=Established crd/l2advertisements.metallb.io --timeout=60s

# Apply MetalLB configuration (from local repo)
kubectl apply -f "$REPO_DIR/infrastructure/metallb-config.yaml"

# --- 6. INSTALL ARGOCD (GitOps) ---
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for ArgoCD to be ready
echo "Waiting for ArgoCD server..."
sleep 10
kubectl wait --for=condition=Ready pods -l app.kubernetes.io/name=argocd-server -n argocd --timeout=300s

# Expose ArgoCD via LoadBalancer
kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "LoadBalancer"}}'

# --- 7. APPLY NAMESPACES (from local repo) ---
kubectl apply -f "$REPO_DIR/infrastructure/namespaces.yaml"

# --- 8. CONFIGURE ARGOCD FOR PRIVATE REPO ---
# Check if deploy key secret template exists and has been configured
DEPLOY_KEY_FILE="$REPO_DIR/infrastructure/argocd-repo-secret.yaml"
if [ -f "$DEPLOY_KEY_FILE" ]; then
  # Check if the file has a real key (not placeholder)
  if grep -q "REPLACE_WITH_BASE64_ENCODED_PRIVATE_KEY" "$DEPLOY_KEY_FILE"; then
    echo ""
    echo "⚠️  WARNING: ArgoCD deploy key not configured!"
    echo "   Edit $DEPLOY_KEY_FILE with your GitHub deploy key."
    echo "   Then run: kubectl apply -f $DEPLOY_KEY_FILE"
    echo ""
  else
    echo "Applying ArgoCD repository secret..."
    kubectl apply -f "$DEPLOY_KEY_FILE"
  fi
fi

# --- 9. TRIGGER THE GITOPS SYNC (from local repo) ---
# This connects the cluster back to YOUR repo
kubectl apply -f "$REPO_DIR/apps/argocd-root.yaml"

# --- 10. INSTALL CERT-MANAGER (ARC Dependency) ---
echo "Installing cert-manager (required for ARC)..."
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.4/cert-manager.yaml

# Wait for cert-manager to be ready
echo "Waiting for cert-manager..."
sleep 15
kubectl wait --for=condition=Ready pods -l app.kubernetes.io/instance=cert-manager -n cert-manager --timeout=120s

# --- 11. INSTALL ACTIONS RUNNER CONTROLLER (ARC) ---
echo "Installing GitHub Actions Runner Controller..."

# Add the ARC Helm repo
helm repo add actions-runner-controller https://actions-runner-controller.github.io/actions-runner-controller
helm repo update

# Create namespace for runners
kubectl create namespace actions-runner-system --dry-run=client -o yaml | kubectl apply -f -

# Check if GitHub App credentials are provided via environment variables
if [ -n "${GITHUB_APP_ID:-}" ] && [ -n "${GITHUB_APP_INSTALLATION_ID:-}" ] && [ -n "${GITHUB_APP_PRIVATE_KEY:-}" ]; then
  echo "Installing ARC with GitHub App authentication..."
  
  # Create secret for GitHub App
  kubectl create secret generic controller-manager \
    -n actions-runner-system \
    --from-literal=github_app_id="$GITHUB_APP_ID" \
    --from-literal=github_app_installation_id="$GITHUB_APP_INSTALLATION_ID" \
    --from-literal=github_app_private_key="$GITHUB_APP_PRIVATE_KEY" \
    --dry-run=client -o yaml | kubectl apply -f -
  
  # Install ARC
  helm upgrade --install arc actions-runner-controller/actions-runner-controller \
    --namespace actions-runner-system \
    --set authSecret.create=false \
    --set authSecret.name=controller-manager
    
elif [ -n "${GITHUB_PAT:-}" ]; then
  echo "Installing ARC with Personal Access Token..."
  
  # Create secret for PAT
  kubectl create secret generic controller-manager \
    -n actions-runner-system \
    --from-literal=github_token="$GITHUB_PAT" \
    --dry-run=client -o yaml | kubectl apply -f -
  
  # Install ARC
  helm upgrade --install arc actions-runner-controller/actions-runner-controller \
    --namespace actions-runner-system \
    --set authSecret.create=false \
    --set authSecret.name=controller-manager
else
  echo ""
  echo "⚠️  WARNING: GitHub Actions Runner Controller installed without credentials!"
  echo "   Runners will NOT be able to register with GitHub."
  echo ""
  echo "   To configure later, create a secret with either:"
  echo "   1. GitHub App credentials (recommended):"
  echo "      kubectl create secret generic controller-manager \\"
  echo "        -n actions-runner-system \\"
  echo "        --from-literal=github_app_id=YOUR_APP_ID \\"
  echo "        --from-literal=github_app_installation_id=YOUR_INSTALL_ID \\"
  echo "        --from-literal=github_app_private_key=\"\$(cat your-app.private-key.pem)\""
  echo ""
  echo "   2. Personal Access Token:"
  echo "      kubectl create secret generic controller-manager \\"
  echo "        -n actions-runner-system \\"
  echo "        --from-literal=github_token=YOUR_PAT"
  echo ""
  
  # Install ARC without auth (user will configure later)
  helm upgrade --install arc actions-runner-controller/actions-runner-controller \
    --namespace actions-runner-system
fi

# Wait for ARC to be ready
echo "Waiting for Actions Runner Controller..."
sleep 10
kubectl wait --for=condition=Ready pods -l app.kubernetes.io/name=actions-runner-controller -n actions-runner-system --timeout=120s || \
  echo "ARC controller may still be starting..."

# Apply runner scale set if credentials are configured
if [ -n "${GITHUB_APP_ID:-}" ] || [ -n "${GITHUB_PAT:-}" ]; then
  echo "Applying GitHub Runner configuration..."
  kubectl apply -f "$REPO_DIR/apps/github-runner.yaml"
else
  echo ""
  echo "Skipping runner deployment until credentials are configured."
  echo "After configuring credentials, run:"
  echo "  kubectl apply -f $REPO_DIR/apps/github-runner.yaml"
fi

# --- 12. WAIT FOR NEXUS TO BE HEALTHY ---
echo "Waiting for Nexus deployment..."
sleep 30
kubectl wait --for=condition=Available deployment/nexus -n devops --timeout=300s || echo "Nexus may still be starting up..."

echo ""
echo "=========================================="
echo "=== Bootstrap Complete at $(date) ==="
echo "=========================================="
echo ""
echo "ArgoCD Initial Admin Password:"
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
echo ""
echo ""
echo "=== Access Information ==="
echo ""
echo "ArgoCD URL:"
kubectl get svc -n argocd argocd-server -o jsonpath="https://{.status.loadBalancer.ingress[0].ip}" 2>/dev/null || echo "https://<pending>"
echo ""
echo ""
echo "Nexus URL:"
kubectl get svc -n devops nexus -o jsonpath="http://{.status.loadBalancer.ingress[0].ip}:{.spec.ports[0].port}" 2>/dev/null || echo "http://<node-ip>:$(kubectl get svc -n devops nexus -o jsonpath='{.spec.ports[0].nodePort}')"
echo ""
echo ""
echo "=== Next Steps for Full CI/CD ==="
echo ""
echo "1. Make your GitHub repo private"
echo "2. Create a GitHub Deploy Key for ArgoCD:"
echo "   ssh-keygen -t ed25519 -C 'argocd-deploy-key' -f argocd-deploy-key"
echo "   Add the PUBLIC key to GitHub repo → Settings → Deploy Keys"
echo "   Base64 encode the PRIVATE key and add to argocd-repo-secret.yaml"
echo ""
echo "3. Create a GitHub App for Actions Runner:"
echo "   https://github.com/settings/apps/new"
echo "   Required permissions: Actions (read), Administration (read/write)"
echo "   Install the app on your repo"
echo ""
echo "4. Set up GitHub Secrets for CI workflows:"
echo "   NEXUS_URL, NEXUS_USERNAME, NEXUS_PASSWORD"
echo ""
