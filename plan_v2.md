# Homelab V2: Multi-Environment Proxmox Cluster

This plan establishes a professional-grade homelab hosted on **Proxmox VE 9.1**. It splits infrastructure into:
- **HomeProd** - Stable production environment for home services
- **HomePractice** - Isolated sandbox for learning enterprise networking/security

---

## Architecture Overview

| Feature | HomeProd (Production) | HomePractice (Enterprise Lab) |
|---------|----------------------|------------------------------|
| **Purpose** | Stable home services (DNS, Media, IoT) | Learning, Testing, "Enterprise Mirror" |
| **Network** | Flat Home Network (192.168.1.x) | Isolated Virtual Network (10.10.10.x) |
| **Gateway** | Physical Home Router | Virtual OPNsense Firewall |
| **Compute** | K3s VM (Direct Bridge) | K3s VM (Behind OPNsense) |
| **Tier 0 (Infra)** | Terraform (bpg/proxmox) | Terraform (bpg/proxmox) |
| **Tier 1 (K8s)** | Terraform (Cilium/MetalLB/Argo) | Terraform (Cilium/MetalLB/Argo) |
| **Access** | Direct LAN | WireGuard VPN via OPNsense |
| **Runners** | Self-hosted (direct) | Self-hosted (OPNsense NAT) |

---

## Key Decisions

- **Terraform Provider**: `bpg/proxmox` (actively maintained, best cloud-init support)
- **VPN Access**: WireGuard running on OPNsense for HomePractice access
- **ArgoCD**: One instance per environment, shared deploy key
- **GitHub Runners**: Separate per environment; HomePractice uses OPNsense NAT
- **CI/CD**: No approval gates, separate secrets per cluster
- **GPU**: Not needed
- **Terraform State**: Local (per environment)

---

## Repository Structure

```
.
├── homepractice/                    # [Environment 1] Enterprise Sandbox
│   ├── infrastructure/              # Tier 0: Proxmox VMs (bpg/proxmox)
│   │   ├── main.tf                  # OPNsense + K3s VM definitions
│   │   ├── variables.tf
│   │   └── terraform.tfvars         # (gitignored) Proxmox credentials
│   ├── kubernetes/                  # Tier 1: Cluster config (Terraform)
│   │   ├── main.tf                  # Cilium/MetalLB/ArgoCD
│   │   ├── variables.tf
│   │   └── terraform.tfvars         # (gitignored) GitHub App credentials
│   └── apps/                        # Tier 2: ArgoCD Applications
│       ├── argocd-root.yaml
│       ├── arc.yaml
│       ├── github-runner.yaml
│       └── nexus.yaml
│
├── homeprod/                        # [Environment 2] Stable Production
│   ├── infrastructure/              # Tier 0: Proxmox VMs
│   │   ├── main.tf                  # Single K3s VM definition
│   │   ├── variables.tf
│   │   └── terraform.tfvars         # (gitignored)
│   ├── kubernetes/                  # Tier 1: Cluster config
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── terraform.tfvars         # (gitignored)
│   └── apps/                        # Tier 2: ArgoCD Applications
│       ├── argocd-root.yaml
│       ├── arc.yaml
│       ├── github-runner.yaml
│       └── pihole.yaml
│
├── modules/                         # Shared Terraform Modules
│   ├── proxmox-vm/                  # Reusable VM definition
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   └── k8s-bootstrap/               # K3s bootstrap script + cloud-init
│       └── pre-kubernetes.sh
│
├── scripts/
│   └── prep-proxmox.sh              # Proxmox host setup (bridges, ISOs)
│
└── README.md
```

---

## Network Topology

Proxmox Linux Bridges manage connectivity for both environments:

```
┌─────────────────────────────────────────────────────────────────┐
│                        PROXMOX HOST                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  vmbr0 (Physical Bridge)          vmbr1 (Virtual Isolated)      │
│  ├── Physical NIC (enp*)          ├── No physical port          │
│  ├── HomeProd K3s (192.168.1.50)  ├── OPNsense LAN (10.10.10.1) │
│  └── OPNsense WAN (DHCP)          └── HomePractice K3s          │
│                                       (10.10.10.10)              │
└─────────────────────────────────────────────────────────────────┘
```

| Bridge | Connection | Purpose |
|--------|-----------|---------|
| **vmbr0** | Physical Ethernet | Home LAN access (192.168.1.x) |
| **vmbr1** | Virtual only | Isolated lab network (10.10.10.x) |

---

## Implementation Plan

### Phase 1: Host Preparation (Manual)

1. **Install Proxmox VE 9.1** on G913 hardware
2. **Create API Token**: Datacenter → Permissions → API Tokens
3. **Upload ISOs**: Ubuntu 24.04 cloud image, OPNsense DVD
4. **Create vmbr1**: Network settings → Add Linux Bridge (no physical ports)
   - Optional: Assign IP `10.10.10.254/24` for host access to lab network

### Phase 2: Deploy HomePractice (Enterprise Sandbox)

#### Step 2.1: Golden Template Setup (One-Time)
Create OPNsense golden template (VM 9000) with:
- 3 NICs: Management (vmbr0), WAN (vmbr0), Internal (vmbr1)
- All interfaces on DHCP for initial boot
- SSH enabled with root login
- API key pre-configured for automation

```bash
# Template created manually via Proxmox console:
# 1. Create VM 9000 with 3 NICs, boot from OPNsense ISO
# 2. Install OPNsense, enable SSH, add API key via web UI
# 3. Convert to template: qm template 9000
```

#### Step 2.2: Infrastructure Deployment (Tier 0)
```bash
cd homepractice/infrastructure
terraform init && terraform apply
```
**Creates:**
- `practice-opnsense` (VM 200): Cloned from template 9000
  - 2 vCPU, 4GB RAM
  - NICs: vtnet0 (Management), vtnet1 (WAN), vtnet2 (Internal)
  - Boots with DHCP, immediately accessible via API
- `practice-k3s` (VM 201): 4 vCPU, 32GB RAM, NIC: vmbr1, IP: 10.10.10.10

#### Step 2.3: OPNsense Configuration via Ansible + Web UI
After clone boots, configure OPNsense (API has limited support):
```bash
# Ansible for firewall rules, WireGuard, automation
cd homepractice/ansible
ansible-playbook -i inventory.yml playbooks/opnsense-configure.yml

# Web UI required for: Interface IPs, DHCP server (API doesn't support)
```
**Configures:**
- vtnet0 (Management): 192.168.1.41/24 - Admin access from home network
- vtnet1 (WAN): 192.168.1.1/24, Gateway: 192.168.1.254
- vtnet2 (Internal): 10.10.10.1/24 - Isolated lab network
- DHCP on Internal: 10.10.10.100-199
- WireGuard VPN for remote access (port 51820)
- NAT rules for outbound traffic
- Firewall rules: Allow LAN→WAN, Block WAN→LAN (except VPN)

#### Step 2.4: Kubernetes Bootstrap (Tier 1)
```bash
# SSH via WireGuard VPN or Proxmox console
ssh ubuntu@10.10.10.10
sudo /opt/homelab/modules/k8s-bootstrap/pre-kubernetes.sh

cd homepractice/kubernetes
terraform init && terraform apply
```
**Installs:** Cilium, MetalLB (10.10.10.200-250), ArgoCD

#### Step 2.5: Applications (Tier 2)
ArgoCD auto-syncs from `homepractice/apps/`:
- Actions Runner Controller + GitHub runners
- Nexus (artifact registry)

### Phase 3: Deploy HomeProd (Stable Production)

#### Step 3.1: Infrastructure (Tier 0)
```bash
cd homeprod/infrastructure
terraform init && terraform apply
```
**Creates:**
- `prod-k3s`: 4 vCPU, 16GB RAM, NIC: vmbr0, IP: 192.168.1.50

#### Step 3.2: Kubernetes Bootstrap (Tier 1)
```bash
ssh ubuntu@192.168.1.50
sudo /opt/homelab/modules/k8s-bootstrap/pre-kubernetes.sh

cd homeprod/kubernetes
terraform init && terraform apply
```
**Installs:** Cilium, MetalLB (192.168.1.60-70), ArgoCD

#### Step 3.3: Applications (Tier 2)
ArgoCD auto-syncs from `homeprod/apps/`:
- Actions Runner Controller + GitHub runners
- PiHole (DNS)
- Future: HomeAssistant, Plex

---

## Environment Comparison

| Config | HomePractice | HomeProd |
|--------|-------------|----------|
| **Subnet** | 10.10.10.0/24 | 192.168.1.0/24 |
| **MetalLB Range** | 10.10.10.200-250 | 192.168.1.60-70 |
| **K3s VM IP** | 10.10.10.10 | 192.168.1.50 |
| **Access** | WireGuard VPN | Direct LAN |
| **Upgrade Policy** | Bleeding edge | Stable / Manual |

---

## CI/CD Workflow

Update `.github/workflows/ci.yaml` for multi-environment:

```yaml
on:
  push:
    branches: [main]

jobs:
  deploy-practice:
    if: contains(github.event.head_commit.modified, 'homepractice/')
    runs-on: [self-hosted, homepractice]
    # ... deploy to practice cluster

  deploy-prod:
    if: contains(github.event.head_commit.modified, 'homeprod/')
    runs-on: [self-hosted, homeprod]
    # ... deploy to prod cluster
```

---

## Migration Checklist

- [ ] Backup existing `terraform.tfvars` and deploy keys
- [ ] Create Proxmox USB boot drive
- [ ] Install Proxmox VE 9.1 on G913
- [ ] Create API token and vmbr1 bridge
- [ ] Refactor repo to new structure
- [ ] Deploy HomePractice environment
- [ ] Configure OPNsense + WireGuard
- [ ] Deploy HomeProd environment
- [ ] Update CI/CD workflow
- [ ] Test runners in both environments