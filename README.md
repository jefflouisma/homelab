# Homelab Kubernetes Infrastructure

Production-grade Kubernetes cluster with eBPF security, observability, and automated GitOps.

## Architecture

| Component | Technology |
|-----------|------------|
| Hardware | PowerSpec G913 (Ryzen 9 / RTX 5080) |
| OS | Ubuntu 24.04.3 LTS |
| K8s Distribution | K3s (lightweight Kubernetes) |
| CNI | Cilium (eBPF-based networking) |
| Load Balancer | MetalLB (L2 mode) |
| GitOps | ArgoCD |
| Artifact Registry | Nexus Repository Manager |

## Directory Structure

```
.
├── bootstrap/
│   ├── install.sh            # Legacy: full bootstrap (deprecated)
│   └── pre-kubernetes.sh     # NEW: minimal OS + K3s setup
├── terraform/
│   ├── main.tf               # Cilium, MetalLB, ArgoCD
│   ├── variables.tf          # Configuration variables
│   └── outputs.tf            # Post-apply instructions
├── infrastructure/
│   ├── namespaces.yaml       # Kubernetes namespaces
│   └── metallb-config.yaml   # MetalLB IP pool (for reference)
├── apps/
│   ├── argocd-root.yaml      # ArgoCD "App of Apps"
│   ├── cert-manager.yaml     # TLS certificate management
│   ├── arc.yaml              # GitHub Actions Runner Controller
│   ├── github-runner.yaml    # Runner ScaleSet configuration
│   └── nexus.yaml            # Nexus artifact repository
├── autoinstall/
│   ├── user-data             # Ubuntu autoinstall configuration
│   └── meta-data             # Cloud-init metadata
└── plan.md                   # Detailed implementation plan
```

## Quick Start

### Prerequisites

1. **Hardware**: Server with Ubuntu 24.04 LTS support
2. **USB Drive**: For Ubuntu autoinstall
3. **Network**: Static IP range for MetalLB (default: `192.168.1.40-50`)

### Setup Steps

#### 1. Clone the Repository

```bash
git clone https://github.com/jefflouisma/homelab.git
cd homelab
```

#### 2. Run Pre-Kubernetes Script (on fresh Ubuntu)

```bash
sudo ./bootstrap/pre-kubernetes.sh
```

This installs: OS packages, K3s, Helm CLI, and sets up kubeconfig.

#### 3. Run Terraform (installs cluster components)

```bash
cd terraform
terraform init
terraform apply
```

This installs: Cilium (CNI), MetalLB, ArgoCD, and triggers GitOps sync.

#### 4. ArgoCD Takes Over

ArgoCD automatically syncs the `apps/` directory, installing:
- cert-manager
- Actions Runner Controller
- Nexus
- All future applications

All configuration values are already set:
- ✅ GitHub repo URL: `jefflouisma/homelab`
- ✅ SSH public key configured
- ✅ Password hash configured
- ✅ MetalLB IP range: `192.168.1.40-50`

#### 2. Verify Network Configuration

Ensure MetalLB IP range (`192.168.1.40-50`) is:
- Outside your router's DHCP scope
- Reserved in your router to prevent conflicts

#### 3. Create Bootable USB

**Option A: Using Ventoy (Recommended)**
1. Install [Ventoy](https://www.ventoy.net/) on a USB drive
2. Copy Ubuntu 24.04 Server ISO to the USB
3. Create `/ventoy/ventoy.json` for autoinstall configuration

**Option B: Repack ISO**
1. Extract Ubuntu ISO
2. Place `user-data` and `meta-data` in `/nocloud/` directory
3. Repack the ISO

#### 5. Install

1. Configure BIOS:
   - Enable XMP/EXPO for RAM
   - Disable Secure Boot (or set to "Other OS")
   - Set USB as boot priority

2. Boot from USB and walk away (~15-20 minutes)

3. Verify installation:
   ```bash
   # Check bootstrap logs
   ssh admin-user@g913-k8s-prod
   journalctl -u homelab-bootstrap.service
   
   # Verify services
   kubectl get pods -A
   ```

## Accessing Services

### ArgoCD

```bash
# Port forward
kubectl port-forward svc/argocd-server -n argocd 8080:443

# Get admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d

# Access at https://localhost:8080
# Username: admin
```

### Nexus

```bash
# Access at http://192.168.1.40:8081 (or your MetalLB IP)
# Default admin password location: /mnt/data/nexus/admin.password
```

## GPU Setup (Optional)

For NVIDIA GPU workloads:

```bash
# Install drivers
apt-get install -y nvidia-driver-565

# Install GPU Operator for Kubernetes
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
helm install gpu-operator nvidia/gpu-operator \
  --namespace gpu-operator \
  --create-namespace \
  --set driver.enabled=false
```

## Network Configuration

| Service | IP/Port |
|---------|---------|
| MetalLB Pool | 192.168.1.40-50 |
| Nexus | 192.168.1.40:8081 |
| ArgoCD | Port-forward :8080 |
| K3s API | 6443 |

## Troubleshooting

### Bootstrap Failed

```bash
# Check logs
journalctl -u homelab-bootstrap.service -f

# Re-run bootstrap manually
/opt/homelab-ops/bootstrap/install.sh
```

### Pods Not Starting

```bash
# Check Cilium status
kubectl -n kube-system exec -it ds/cilium -- cilium status

# Check node status
kubectl describe node g913-k8s-prod
```

### MetalLB Not Assigning IPs

```bash
# Verify MetalLB pods
kubectl get pods -n metallb-system

# Check IP pool
kubectl get ipaddresspools -n metallb-system
```

## Security Notes

- SSH password authentication is disabled
- Only SSH key authentication is allowed
- ArgoCD uses automated sync with prune and self-heal
- Cilium provides eBPF-based network policies

## License

See [LICENSE](LICENSE) file.


