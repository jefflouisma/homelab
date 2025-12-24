# Homelab Infrastructure

Multi-environment Kubernetes homelab with OPNsense firewalls, GitOps, and CI/CD automation.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              ENVIRONMENTS                                    │
├─────────────────────────────────┬───────────────────────────────────────────┤
│         HomePractice            │              HomeProd                      │
│    (Isolated Sandbox)           │         (Production)                       │
├─────────────────────────────────┼───────────────────────────────────────────┤
│  OPNsense (VM 200)              │                                           │
│    WAN: 192.168.1.x (DHCP)      │  K3s (VM 100)                             │
│    LAN: 10.10.10.1/24           │    IP: 192.168.1.50                       │
│         │                       │    Direct on home LAN                     │
│         ▼                       │                                           │
│  K3s (VM 201)                   │                                           │
│    IP: 10.10.10.10              │                                           │
│    Behind NAT                   │                                           │
└─────────────────────────────────┴───────────────────────────────────────────┘
                              │
                              ▼
                    Proxmox (192.168.1.30)
                      VM Host for all VMs
```

## Directory Structure

```
homelab/
├── homepractice/              # Isolated sandbox environment
│   ├── infrastructure/        # Terraform: OPNsense + K3s VMs
│   ├── kubernetes/            # Terraform: Cilium, MetalLB, ArgoCD
│   ├── ansible/               # Configuration management
│   └── apps/                  # ArgoCD applications
│
├── homeprod/                  # Production environment  
│   ├── infrastructure/        # Terraform: K3s VM
│   ├── kubernetes/            # Terraform: Cilium, MetalLB, ArgoCD
│   ├── ansible/               # Configuration management
│   └── apps/                  # ArgoCD applications
│
├── modules/                   # Shared Terraform modules
│   └── proxmox-vm/            # Reusable VM provisioning
│
├── .github/workflows/         # CI/CD pipelines
│   └── ci.yaml                # Main pipeline
│
└── scripts/                   # Utility scripts
```

---

## 🚀 Quick Start

### Prerequisites

| Requirement | Details |
|-------------|---------|
| **Proxmox** | Host at 192.168.1.30 with API token |
| **SSH Keys** | `~/.ssh/id_rsa` for VMs |
| **Terraform** | >= 1.5.0 |
| **Ansible** | >= 2.15 |
| **GitHub** | Repo with Actions enabled |

---

## 📋 Deployment Phases

### Phase 1: Manual Bootstrap (from Workstation)

> **Run once** to create initial infrastructure and self-hosted runners.

#### Step 1: Create terraform.tfvars

```bash
# HomePractice
cat > homepractice/infrastructure/terraform.tfvars << 'EOF'
proxmox_api_url          = "https://192.168.1.30:8006"
proxmox_api_token_id     = "root@pam!terraform"
proxmox_api_token_secret = "your-token-here"
proxmox_node             = "g913-proxmox"
datastore_id             = "local-lvm"
ubuntu_cloud_image_id    = "local:iso/noble-server-cloudimg-amd64.img"
opnsense_template_id     = 9000
ssh_public_keys          = ["ssh-rsa AAAA... your-key"]
EOF

# HomeProd (similar, adjust as needed)
cp homepractice/infrastructure/terraform.tfvars homeprod/infrastructure/
```

#### Step 2: Deploy Infrastructure

```bash
# HomePractice: OPNsense + K3s VMs
cd homepractice/infrastructure
terraform init && terraform apply

# HomeProd: K3s VM only
cd ../../homeprod/infrastructure  
terraform init && terraform apply
```

#### Step 3: Configure OPNsense (HomePractice only)

```bash
cd homepractice/ansible

# Configure firewall via API (through Proxmox jump host)
ansible-playbook -i inventory.yml playbooks/opnsense-configure.yml
```

#### Step 4: Deploy Kubernetes Components

```bash
# HomePractice
cd homepractice/kubernetes
terraform init && terraform apply

# HomeProd
cd ../../homeprod/kubernetes
terraform init && terraform apply
```

#### Step 5: Verify Self-Hosted Runners

```bash
# Check runners are registered
kubectl get pods -n actions-runner-system

# Verify in GitHub: Settings → Actions → Runners
```

---

### Phase 2: CI/CD Operations (Automated)

> Once runners are deployed, all future changes go through CI/CD.

#### What CI/CD Handles

| Change Type | Trigger | Action |
|-------------|---------|--------|
| `homepractice/apps/*` | Push to main | ArgoCD auto-sync |
| `homeprod/apps/*` | Push to main | ArgoCD auto-sync |
| `**/ansible/**` | Push to main | Ansible playbook run |
| `modules/**` | Push to main | Affects both environments |

#### Manual Workflow Dispatch

```bash
# Via GitHub Actions UI or CLI
gh workflow run ci.yaml -f environment=homepractice -f action=ansible-only
```

---

## 🔧 Configuration Files

### HomePractice Ansible Inventory

```yaml
# homepractice/ansible/inventory.yml
all:
  children:
    opnsense:
      hosts:
        perimeter-fw:
          ansible_host: "10.10.10.1"
          ansible_user: root
          ansible_password: "opnsense"
          # API access from runner (on same LAN)
          opn_api_key: "your-api-key"
          opn_api_secret: "your-api-secret"
    k3s:
      hosts:
        practice-k3s:
          ansible_host: 10.10.10.10
          ansible_user: ubuntu
```

### GitHub Secrets Required

| Secret | Description |
|--------|-------------|
| `PROXMOX_API_TOKEN` | Proxmox API token |
| `OPNSENSE_API_KEY` | OPNsense API key |
| `OPNSENSE_API_SECRET` | OPNsense API secret |
| `GH_APP_ID` | GitHub App ID for ARC |
| `GH_APP_PRIVATE_KEY` | GitHub App private key |

---

## 🌐 Network Configuration

### HomePractice (Isolated)

| Component | IP | Notes |
|-----------|-----|-------|
| OPNsense WAN | DHCP (192.168.1.x) | Gateway to internet |
| OPNsense LAN | 10.10.10.1/24 | Internal network |
| K3s Node | 10.10.10.10 | Behind NAT |
| MetalLB Pool | 10.10.10.40-50 | LoadBalancer IPs |
| WireGuard | 10.10.20.0/24 | VPN access |

### HomeProd (Direct)

| Component | IP | Notes |
|-----------|-----|-------|
| K3s Node | 192.168.1.50 | On home LAN |
| MetalLB Pool | 192.168.1.40-50 | LoadBalancer IPs |

---

## 📊 Accessing Services

### ArgoCD

```bash
# HomePractice (via WireGuard or port-forward)
kubectl --kubeconfig=kubeconfig-homepractice.yaml port-forward svc/argocd-server -n argocd 8080:443

# HomeProd
kubectl --kubeconfig=kubeconfig-homeprod.yaml port-forward svc/argocd-server -n argocd 8081:443

# Get password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

---

## 🔄 CI/CD Pipeline

The pipeline (`.github/workflows/ci.yaml`) runs on self-hosted runners:

```
Push to main
     │
     ├─► Detect changes (paths-filter)
     │
     ├─► HomePractice (if changed)
     │   ├─► Validate manifests
     │   ├─► Run Ansible (if ansible/ changed)
     │   └─► ArgoCD auto-syncs apps/
     │
     └─► HomeProd (if changed)
         ├─► Validate manifests
         ├─► Run Ansible (if ansible/ changed)
         └─► ArgoCD auto-syncs apps/
```

### Runner Requirements

Self-hosted runners need:
- `kubectl` with cluster access
- `ansible` for configuration management
- Access to OPNsense API (10.10.10.1 for HomePractice)

---

## 🛠️ Troubleshooting

### VMs Not Starting

```bash
# Check Proxmox
ssh root@192.168.1.30 "qm list"

# Check VM console
ssh root@192.168.1.30 "qm terminal 200"
```

### OPNsense API Not Responding

```bash
# Test from Proxmox (can reach LAN)
ssh root@192.168.1.30 "curl -sk https://10.10.10.1/api/core/firmware/status"
```

### K3s Not Ready

```bash
# Check cloud-init status
ssh ubuntu@10.10.10.10 "cloud-init status"

# Check K3s service
ssh ubuntu@10.10.10.10 "sudo systemctl status k3s"
```

### Runner Not Registering

```bash
# Check ARC controller
kubectl -n actions-runner-system logs -l app.kubernetes.io/name=gha-runner-scale-set-controller

# Check runner pods
kubectl -n actions-runner-system get pods
```

---

## 📁 Key Files

| File | Purpose |
|------|---------|
| `kubeconfig-homepractice.yaml` | K3s access (gitignored) |
| `kubeconfig-homeprod.yaml` | K3s access (gitignored) |
| `*/infrastructure/terraform.tfvars` | VM configs (gitignored) |
| `*/kubernetes/terraform.tfvars` | K8s configs (gitignored) |

---

## License

See [LICENSE](LICENSE) file.
