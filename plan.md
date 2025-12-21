This is the "Golden Image" plan. It connects every piece of the puzzle into a single executable workflow.

### **The Architecture**

* **Hardware:** PowerSpec G913 (Ryzen 9 / RTX 5080)
* **OS:** Ubuntu 24.04.3 LTS (Manual Install - Private Repo)
* **K8s Core:** K3s (No Flannel, No Traefik, No Kube-Proxy)
* **Networking:** Cilium (eBPF CNI) + MetalLB (L2 LoadBalancer)
* **GitOps:** ArgoCD (with deploy key for private repo)
* **CI/CD:** GitHub Actions + Self-hosted Ephemeral Runners (ARC)
* **Services:** Nexus, GitHub Actions Runner

---

### **Security Model**

This implementation follows security best practices for self-hosted CI/CD:

| Security Feature | Implementation |
|-----------------|----------------|
| **Private Repository** | Repo is private - no public access to code/configs |
| **Deploy Keys** | ArgoCD uses SSH deploy key (read-only) |
| **Ephemeral Runners** | Runners destroyed after each job - no persistent state |
| **Push-Only Triggers** | CI only runs on push to main - no fork PR attacks |
| **GitHub Secrets** | All credentials stored in GitHub Secrets, not repo |
| **OOB Installation** | Install script copied manually - no network fetch during boot |

---

### **Step 1: The "Control Tower" (Your GitHub Repo)**

Before touching the hardware, set up the "Source of Truth." The server will pull this repo after manual setup.

**1. Create a PRIVATE GitHub repo** (e.g., `github.com/jefflouisma/homelab`).
**2. Directory structure:**

```text
/homelab
├── .github/
│   └── workflows/
│       └── ci.yaml               # CI/CD pipeline (push to main only)
├── bootstrap/
│   └── install.sh                # The bootstrap script (run manually)
├── infrastructure/
│   ├── metallb-config.yaml       # IP Pool configuration
│   ├── namespaces.yaml           # Namespace definitions
│   └── argocd-repo-secret.yaml   # Deploy key for private repo
└── apps/
    ├── nexus.yaml                # Nexus Artifact Registry
    ├── github-runner.yaml        # Ephemeral GitHub Actions runners
    └── argocd-root.yaml          # The "App of Apps"
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

### **Step 2: The Bootstrap Script**

This script transforms a naked Ubuntu OS into a Production K8s Node with full CI/CD.
**File:** `bootstrap/install.sh`

The script now:
- Uses local files (no raw GitHub URLs for private repo)
- Installs Actions Runner Controller (ARC) for self-hosted runners
- Configures ArgoCD with deploy key for private repo access
- Sets up ephemeral runners that scale 0→3 based on demand

**Key features:**
- Accepts GitHub credentials via environment variables
- Falls back gracefully if credentials not provided
- Outputs clear next-steps for manual configuration

---

### **Step 3: The Installation Process (Out-of-Band)**

Since the repo is private, you can't use autoinstall with network-based config fetching.

**1. Install Ubuntu 24.04 Server manually or with basic autoinstall:**
   - Use default Ubuntu installer
   - Set hostname: `g913-k8s-prod`
   - Create user: `admin-user`
   - Enable SSH server

**2. After Ubuntu is installed, SSH in:**
```bash
ssh admin-user@<new-server-ip>
```

**3. Clone the repo (requires authentication for private repo):**
```bash
# Option A: Use SSH (if you have SSH key set up)
git clone git@github.com:jefflouisma/homelab.git /opt/homelab-ops

# Option B: Use HTTPS with PAT
git clone https://<your-pat>@github.com/jefflouisma/homelab.git /opt/homelab-ops
```

**4. Run the bootstrap script:**
```bash
# Without GitHub runner credentials (configure later)
sudo /opt/homelab-ops/bootstrap/install.sh

# OR with GitHub App credentials
sudo GITHUB_APP_ID=123456 \
     GITHUB_APP_INSTALLATION_ID=789012 \
     GITHUB_APP_PRIVATE_KEY="$(cat /path/to/app.private-key.pem)" \
     /opt/homelab-ops/bootstrap/install.sh

# OR with Personal Access Token
sudo GITHUB_PAT=ghp_xxxxxxxxxxxx \
     /opt/homelab-ops/bootstrap/install.sh
```

---

### **Step 4: Configure ArgoCD for Private Repo**

After bootstrap completes, configure ArgoCD to access your private repo.

**1. Generate a deploy key:**
```bash
ssh-keygen -t ed25519 -C "argocd-deploy-key" -f argocd-deploy-key -N ""
```

**2. Add PUBLIC key to GitHub:**
   - Go to: `https://github.com/jefflouisma/homelab/settings/keys`
   - Click "Add deploy key"
   - Title: `ArgoCD Deploy Key`
   - Paste contents of `argocd-deploy-key.pub`
   - Leave "Allow write access" UNCHECKED (read-only is safer)

**3. Create the Kubernetes secret:**
```bash
kubectl create secret generic homelab-repo \
  -n argocd \
  --from-literal=type=git \
  --from-literal=url=git@github.com:jefflouisma/homelab.git \
  --from-file=sshPrivateKey=argocd-deploy-key

# Label it so ArgoCD recognizes it
kubectl label secret homelab-repo -n argocd argocd.argoproj.io/secret-type=repository
```

**4. Delete local key files:**
```bash
rm argocd-deploy-key argocd-deploy-key.pub
```

---

### **Step 5: Configure GitHub Actions Runners**

**Option A: GitHub App (Recommended)**

1. Create a GitHub App at `https://github.com/settings/apps/new`
2. Set permissions:
   - Repository: Actions (Read)
   - Repository: Administration (Read & Write)
   - Repository: Metadata (Read)
3. Install the app on your `homelab` repo
4. Download the private key
5. Create the Kubernetes secret:

```bash
kubectl create secret generic controller-manager \
  -n actions-runner-system \
  --from-literal=github_app_id=YOUR_APP_ID \
  --from-literal=github_app_installation_id=YOUR_INSTALLATION_ID \
  --from-file=github_app_private_key=/path/to/app.private-key.pem
```

**Option B: Personal Access Token**

1. Create a PAT at `https://github.com/settings/tokens`
2. Required scopes: `repo`, `workflow`
3. Create the secret:

```bash
kubectl create secret generic controller-manager \
  -n actions-runner-system \
  --from-literal=github_token=ghp_xxxxxxxxxxxx
```

**Apply the runner configuration:**
```bash
kubectl apply -f /opt/homelab-ops/apps/github-runner.yaml
```

---

### **Step 6: Configure GitHub Secrets for CI**

Add these secrets in GitHub: `https://github.com/jefflouisma/homelab/settings/secrets/actions`

| Secret | Description |
|--------|-------------|
| `NEXUS_URL` | Your Nexus registry URL (e.g., `192.168.1.40:8081`) |
| `NEXUS_USERNAME` | Nexus admin username |
| `NEXUS_PASSWORD` | Nexus admin password |

---

### **Step 7: Defining Nexus (The First App)**

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

### **Step 8: Execution Checklist**

1. **BIOS Setup:**
   * Plug Monitor/Keyboard into G913.
   * Boot and press **Delete**.
   * Enable **XMP/EXPO** (Get that 6000MHz RAM speed).
   * Set **Secure Boot** to "Other OS" (or disable) to ensure unsigned kernel modules (like NVIDIA drivers later) load easily.
   * Set USB as Boot Priority #1.

2. **Ubuntu Installation:**
   * Install Ubuntu 24.04 Server
   * Hostname: `g913-k8s-prod`
   * User: `admin-user`
   * Enable SSH

3. **Post-Boot Setup:**
   * SSH into server
   * Clone private repo (with authentication)
   * Run bootstrap script
   * Configure ArgoCD deploy key
   * Configure GitHub Actions runner credentials
   * Add GitHub Secrets for CI

4. **Verification:**
   * Wait **~15-20 minutes** (bootstrap runs full stack).
   * Check: `kubectl get pods -A` - All pods should be Running
   * Check: `kubectl get svc -A` - Services should have External IPs
   * Access ArgoCD UI at `https://<argocd-ip>`
   * Access Nexus at `http://<nexus-ip>:8081`

---

### **Step 9: GPU Setup (Optional)**

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

### **CI/CD Pipeline Flow**

```
┌─────────────────────────────────────────────────────────────────────┐
│                        FULL CI/CD PIPELINE                          │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│   Push to main ──► GitHub Actions ──► Self-hosted Runner            │
│        │                │                    │                      │
│        │                │                    ▼                      │
│        │                │              ┌──────────┐                 │
│        │                │              │ Validate │                 │
│        │                │              │ Manifests│                 │
│        │                │              └────┬─────┘                 │
│        │                │                   │                       │
│        │                │                   ▼                       │
│        │                │              ┌──────────┐                 │
│        │                │              │  Build   │ (future)        │
│        │                │              │  Images  │                 │
│        │                │              └────┬─────┘                 │
│        │                │                   │                       │
│        ▼                ▼                   ▼                       │
│   ┌─────────────────────────────────────────────┐                   │
│   │              ArgoCD (GitOps)                │                   │
│   │         Auto-sync from private repo         │                   │
│   └────────────────────┬────────────────────────┘                   │
│                        │                                            │
│                        ▼                                            │
│   ┌─────────────────────────────────────────────┐                   │
│   │           Kubernetes Cluster                │                   │
│   │   ┌────────┐  ┌────────┐  ┌──────────────┐ │                   │
│   │   │ Nexus  │  │ Cilium │  │ Other Apps   │ │                   │
│   │   └────────┘  └────────┘  └──────────────┘ │                   │
│   └─────────────────────────────────────────────┘                   │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

---

### **Pre-Flight Checklist**

Before running this plan, verify:

- [ ] GitHub repo created as **PRIVATE**
- [ ] All repo paths use `jefflouisma/homelab`
- [ ] SSH key generated for server access
- [ ] Verify MetalLB IP range (`192.168.1.40-50`) is outside router DHCP scope
- [ ] Reserve MetalLB IPs in router to prevent conflicts
- [ ] Have GitHub PAT or GitHub App credentials ready
- [ ] Push repo to GitHub (private)

---

### **Post-Installation Checklist**

- [ ] ArgoCD deploy key configured
- [ ] GitHub Actions runner credentials configured
- [ ] GitHub Secrets configured (NEXUS_URL, NEXUS_USERNAME, NEXUS_PASSWORD)
- [ ] Runners appearing in GitHub: `https://github.com/jefflouisma/homelab/settings/actions/runners`
- [ ] CI pipeline runs successfully on push to main
- [ ] ArgoCD shows all apps synced

---

You now have a **production-grade Kubernetes cluster** with:
- eBPF security (Cilium)
- Observability (Hubble)
- Automated GitOps (ArgoCD)
- Full CI/CD with ephemeral self-hosted runners
- Private repository with secure access
