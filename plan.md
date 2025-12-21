This is the "Golden Image" plan. It connects every piece of the puzzle into a single executable workflow.

### **The Architecture**

* **Hardware:** PowerSpec G913 (Ryzen 9 / RTX 5080)
* **OS:** Ubuntu 24.04.3 LTS (Automated Install)
* **K8s Core:** K3s (No Flannel, No Traefik, No Kube-Proxy)
* **Networking:** Cilium (eBPF CNI) + MetalLB (L2 LoadBalancer)
* **GitOps:** ArgoCD
* **Services:** Nexus, GitHub Actions Runner

---

### **Step 1: The "Control Tower" (Your GitHub Repo)**

Before touching the hardware, set up the "Source of Truth." The server will pull this repo immediately upon booting.

**1. Create a public/private GitHub repo** (e.g., `github.com/jefflouisma/homelab`).
**2. Create this directory structure:**

```text
/homelab-ops
├── bootstrap/
│   └── install.sh            # The "God Script" that runs on first boot
├── infrastructure/
│   ├── metallb-config.yaml   # IP Pool configuration
│   ├── namespaces.yaml       # Namespace definitions
│   └── cilium-values.yaml    # Cilium Helm values (optional)
└── apps/
    ├── nexus.yaml            # Nexus Artifact Registry
    └── argocd-root.yaml      # The "App of Apps"
```

**3. Define the Namespaces (`infrastructure/namespaces.yaml`):**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: devops
---
apiVersion: v1
kind: Namespace
metadata:
  name: argocd
```

**4. Define the MetalLB Config (`infrastructure/metallb-config.yaml`):**
*Update the IP range to match your home network. Ensure this range is OUTSIDE your router's DHCP scope.*

```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: production-pool
  namespace: metallb-system
spec:
  addresses:
  - 192.168.1.40-192.168.1.50
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: production-l2
  namespace: metallb-system
spec:
  ipAddressPools:
  - production-pool
```

**5. Define the ArgoCD Root App (`apps/argocd-root.yaml`):**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/jefflouisma/homelab.git
    targetRevision: HEAD
    path: apps
    directory:
      recurse: false
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

---

### **Step 2: The "God Script" (Bootstrap Logic)**

This script transforms a naked Ubuntu OS into a Production K8s Node.
**File:** `bootstrap/install.sh`

```bash
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
```

---

### **Step 3: The "Ignition Key" (USB Autoinstall)**

You will modify the Ubuntu Server ISO `user-data` file.

**1. Download Ubuntu 24.04 Server ISO.**
**2. Create your `user-data` file:**

```yaml
#cloud-config
autoinstall:
  version: 1
  identity:
    hostname: g913-k8s-prod
    username: admin-user
    password: "$6$pxsJ45EKlo6eAS9n$mOSz4ddb13uLZILARA0Ba8Q..." # (configured)
  ssh:
    install-server: true
    allow-pw: false
    authorized-keys:
      - "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQ..." # (configured - jefflouisma@me.com)
  storage:
    layout:
      name: direct # Wipes the 2TB SSD automatically
  late-commands:
    # Clone the repo to the target system
    - curtin in-target -- git clone https://github.com/jefflouisma/homelab.git /opt/homelab-ops
    - curtin in-target -- chmod +x /opt/homelab-ops/bootstrap/install.sh
    # Create systemd service for first-boot execution
    - |
      cat <<EOF > /target/etc/systemd/system/homelab-bootstrap.service
      [Unit]
      Description=Homelab Bootstrap (First Boot)
      After=network-online.target
      Wants=network-online.target
      ConditionPathExists=!/opt/homelab-bootstrap-done

      [Service]
      Type=oneshot
      ExecStart=/opt/homelab-ops/bootstrap/install.sh
      ExecStartPost=/usr/bin/touch /opt/homelab-bootstrap-done
      RemainAfterExit=yes
      StandardOutput=journal+console
      StandardError=journal+console

      [Install]
      WantedBy=multi-user.target
      EOF
    - curtin in-target -- systemctl enable homelab-bootstrap.service
```

**3. Burn to USB:**

* **Easy Method:** Use **Ventoy**. Copy the ISO to the USB. Place the `user-data` file in a generic accessible location and use the Ventoy auto-install plugin config.
* **Pure Method:** Repack the ISO with the `user-data` file in the `/nocloud` directory.

---

### **Step 4: Defining Nexus (The First App)**

Add this to your repo at `apps/nexus.yaml` so ArgoCD picks it up.

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: nexus-pv
spec:
  capacity:
    storage: 50Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-storage
  local:
    path: /mnt/data/nexus
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - g913-k8s-prod
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: nexus-pvc
  namespace: devops
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: local-storage
  resources:
    requests:
      storage: 50Gi
---
apiVersion: v1
kind: Service
metadata:
  name: nexus
  namespace: devops
  annotations:
    metallb.io/allow-shared-ip: "nexus"
spec:
  selector:
    app: nexus
  ports:
    - port: 8081
      targetPort: 8081
  type: LoadBalancer # MetalLB will give this a Real IP (e.g., 192.168.1.40)
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nexus
  namespace: devops
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nexus
  template:
    metadata:
      labels:
        app: nexus
    spec:
      containers:
        - name: nexus
          image: sonatype/nexus3:3.72.0  # Pin to specific version
          ports:
            - containerPort: 8081
          volumeMounts:
            - name: nexus-data
              mountPath: /nexus-data
          resources:
            requests:
              memory: "2Gi"
              cpu: "500m"
            limits:
              memory: "4Gi"
              cpu: "2000m"
      volumes:
        - name: nexus-data
          persistentVolumeClaim:
            claimName: nexus-pvc
```

---

### **Step 5: Execution Checklist**

1. **BIOS Setup:**
   * Plug Monitor/Keyboard into G913.
   * Boot and press **Delete**.
   * Enable **XMP/EXPO** (Get that 6000MHz RAM speed).
   * Set **Secure Boot** to "Other OS" (or disable) to ensure unsigned kernel modules (like NVIDIA drivers later) load easily.
   * Set USB as Boot Priority #1.

2. **The Drop:**
   * Plug in the USB.
   * Reboot.
   * **Walk away.**

3. **Verification:**
   * Wait **~15-20 minutes** (first boot runs the full bootstrap).
   * Check your router: Look for a new device named `g913-k8s-prod`.
   * SSH in and check bootstrap logs: `journalctl -u homelab-bootstrap.service`
   * Run `ping 192.168.1.40` (or whatever your first MetalLB IP is). If it replies, Nexus is alive.

4. **Login:**
   * Visit `http://192.168.1.40:8081` → Nexus Login (default admin password in `/mnt/data/nexus/admin.password`).
   * Access ArgoCD: `kubectl port-forward svc/argocd-server -n argocd 8080:443`
   * Then visit `https://localhost:8080` → ArgoCD (user: `admin`, password from bootstrap output).

---

### **Step 6: GPU Setup (Optional)**

If you need GPU acceleration for ML workloads, add this to your bootstrap or run manually after installation:

```bash
# Install NVIDIA drivers (RTX 5080 requires 560+ series)
apt-get install -y nvidia-driver-565

# For Kubernetes GPU support, install NVIDIA GPU Operator
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
helm repo update
helm install gpu-operator nvidia/gpu-operator \
  --namespace gpu-operator \
  --create-namespace \
  --set driver.enabled=false  # We installed drivers via apt
```

---

### **Pre-Flight Checklist**

Before running this plan, verify:

- [x] GitHub repo created with correct structure
- [x] Replace all repo paths → `jefflouisma/homelab`
- [x] Generate SSH key and add public key to `user-data`
- [x] Generate password hash and add to `user-data`
- [ ] Verify MetalLB IP range (`192.168.1.40-50`) is outside router DHCP scope
- [ ] Reserve MetalLB IPs in router to prevent conflicts
- [ ] Push repo to GitHub

---

You now have a production-grade Kubernetes cluster with eBPF security, observability, and automated GitOps, running on high-performance hardware.
