# Homelab Refactor: Proxmox to Harvester Migration

## Overview

This document outlines the phased migration plan from the current Proxmox-based homelab infrastructure to Harvester HCI with native Kubernetes (RKE2).

### Migration Summary

| Current | Target |
|---------|--------|
| **Host**: Proxmox VE | **Host**: Harvester HCI |
| **HomePractice**: K3s on VM | **Barleta**: Harvester native RKE2 |
| **HomeProd**: K3s on VM | Deprecated |
| **OPNsense**: Proxmox VM | Deprecated |
| **Identity Stack** | Fresh deployment (no data migration) |

### What's Being Migrated

| Component | Current Location | Migration Target | Notes |
|-----------|------------------|------------------|-------|
| K3s Cluster | `homepractice/infrastructure` (VM 201) | **Native Harvester RKE2** | No separate guest cluster needed |
| FreeIPA | `homepractice/infrastructure` (VM 202) | Harvester VM | Fresh deployment |
| ArgoCD | K3s workload | Native RKE2 | GitOps controller |
| Cilium | K3s CNI | Canal (Harvester default) | Native CNI |
| cert-manager | K3s workload | Native RKE2 | Certificate management |
| PostgreSQL | K3s workload | Native RKE2 | Fresh deployment |
| Keycloak | K3s workload | Native RKE2 | Fresh deployment |
| MidPoint | K3s workload | Native RKE2 | Fresh deployment |
| GitHub Runners | K3s (ARC) | Native RKE2 | Self-hosted runners |
| Traefik/Caddy | K3s ingress | Native RKE2 | Ingress controller |

### What's NOT Being Migrated

| Component | Reason |
|-----------|--------|
| OPNsense Firewall | Being deprecated |
| HomeProd environment | Being deprecated |
| AdGuard Home | Not needed in new setup |
| NetBird VPN | Not needed in new setup |
| step-ca | Not needed in new setup |
| Existing identity data | Fresh deployments instead |
| Proxmox-specific modules | Will be replaced with Harvester equivalents |

---

## Current Architecture

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                              Proxmox VE Host (192.168.1.30)                       │
│                                                                                   │
│  ┌─────────────────────────────────────────────────────────────────────────────┐ │
│  │                         HomePractice Environment                             │ │
│  │                                                                               │ │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐      │ │
│  │  │  OPNsense    │  │  K3s VM      │  │  FreeIPA VM  │  │  AdGuard LXC │      │ │
│  │  │  VM 200      │  │  VM 201      │  │  VM 202      │  │  VM 203      │      │ │
│  │  │  10.10.10.1  │  │  10.10.10.10 │  │  10.10.10.212│  │  192.168.1.x │      │ │
│  │  │  (firewall)  │  │  (k8s node)  │  │  (identity)  │  │  (dns)       │      │ │
│  │  └──────────────┘  └──────────────┘  └──────────────┘  └──────────────┘      │ │
│  │                                                                               │ │
│  │  K3s Workloads: ArgoCD, Cilium, MetalLB, cert-manager, Keycloak, MidPoint,   │ │
│  │                 PostgreSQL, Traefik, step-ca, NetBird, GitHub Runners        │ │
│  └─────────────────────────────────────────────────────────────────────────────┘ │
│                                                                                   │
│  ┌─────────────────────────────────────────────────────────────────────────────┐ │
│  │                         HomeProd Environment (DEPRECATED)                    │ │
│  │  ┌──────────────┐                                                            │ │
│  │  │  K3s VM      │                                                            │ │
│  │  │  VM 100      │                                                            │ │
│  │  │  192.168.1.50│                                                            │ │
│  │  └──────────────┘                                                            │ │
│  └─────────────────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## Target Architecture (Barleta)

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                              Harvester HCI Host                                   │
│                                                                                   │
│  ┌─────────────────────────────────────────────────────────────────────────────┐ │
│  │                     Harvester Management Cluster                             │ │
│  │                     (RKE2 control plane, Longhorn, etc.)                     │ │
│  └─────────────────────────────────────────────────────────────────────────────┘ │
│                                                                                   │
│  ┌─────────────────────────────────────────────────────────────────────────────┐ │
│  │                         Barleta Environment                                  │ │
│  │                                                                               │ │
│  │  ┌───────────────────────────────────────────────────────────────────────┐   │ │
│  │  │                    Barleta Guest Cluster (RKE2)                        │   │ │
│  │  │                                                                         │   │ │
│  │  │  Workloads:                                                             │   │ │
│  │  │  - ArgoCD (GitOps)                                                      │   │ │
│  │  │  - cert-manager                                                         │   │ │
│  │  │  - PostgreSQL (Database)                                                │   │ │
│  │  │  - Keycloak (SSO/IAM)                                                   │   │ │
│  │  │  - MidPoint (IGA)                                                       │   │ │
│  │  │  - Traefik (Ingress)                                                    │   │ │
│  │  │  - GitHub Runners (ARC)                                                 │   │ │
│  │  └───────────────────────────────────────────────────────────────────────┘   │ │
│  │                                                                               │ │
│  │  ┌──────────────┐                                                            │ │
│  │  │  FreeIPA VM  │  (Only VM needed - requires systemd)                       │ │
│  │  │  (Harvester) │                                                            │ │
│  │  └──────────────┘                                                            │ │
│  └─────────────────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────────────┘

                    Network: Home LAN (192.168.1.0/24)
                    Gateway: 192.168.1.254 (Home Router)
```

---

## Phase 0: Pre-Migration Preparation

**Duration**: 1-2 days  
**Status**: ✅ Completed

### 0.1 Documentation & Backup

- [x] Document all current IP addresses and network configuration
- [x] Export all Kubernetes manifests from HomePractice cluster (reference only)
- [x] Save all secrets and credentials securely → Key paths documented

**Note:** Identity stack (FreeIPA, Keycloak, MidPoint, PostgreSQL) will be **fresh deployments** - no data migration required.

### 0.2 Hardware Requirements Assessment

- [x] Verify hardware meets Harvester minimum requirements:
  - CPU: 8+ cores (16 recommended)
  - RAM: 32GB minimum (64GB recommended)
  - Storage: 500GB+ SSD for OS and data
  - Network: 10GbE recommended, 1GbE minimum
- [x] Plan storage configuration (Longhorn volumes)
- [x] Plan network configuration (VLANs, bridges)

### 0.3 Repository Restructure Planning

Current structure:
```
homelab/
├── homepractice/          # To be deprecated
├── homeprod/              # To be deprecated
├── modules/
│   ├── proxmox-vm/        # To be replaced
│   ├── proxmox-lxc/       # To be replaced
│   └── ...
└── ...
```

Target structure:
```
homelab/
├── barleta/               # NEW: Main environment
│   ├── infrastructure/    # Harvester Terraform
│   ├── kubernetes/        # RKE2 bootstrap
│   ├── apps/              # ArgoCD applications
│   └── ansible/           # Configuration playbooks
├── modules/
│   ├── harvester-vm/      # NEW: Harvester VM module
│   ├── harvester-cluster/ # NEW: Guest cluster module
│   └── ...
├── homepractice/          # DEPRECATED (kept for reference)
└── homeprod/              # DEPRECATED (kept for reference)
```

---

## Phase 1: Harvester Installation

**Duration**: 1 day  
**Status**: ✅ Completed  
**Dependencies**: Phase 0

### Installed Configuration

| Setting | Value |
|---------|-------|
| **Version** | v1.7.0 |
| **Node IP** | 192.168.1.10 |
| **Management UI** | https://192.168.1.152 |
| **Hostname** | harvester-barleta |
| **RKE2 Version** | v1.34.2+rke2r1 |
| **Kubeconfig** | `~/.kube/harvester.yaml` |

### Harvester Version Selection (Reference)

| Version | Status | EOL | Recommendation |
|---------|--------|-----|----------------|
| **v1.4.3** | Stable (SUSE Supported) | Nov 2025 | Production environments |
| **v1.6.1** | Latest Stable | TBD | Newer features, stable |
| **v1.7.0** | Latest Release | TBD | ✅ **Installed** |

### Hardware Requirements

| Component | Minimum (Testing) | Production |
|-----------|-------------------|------------|
| **CPU** | 8 cores (x86_64 with VT-x/AMD-V) | 16+ cores |
| **RAM** | 32 GB | 64 GB+ |
| **Disk** | 200 GB SSD (5000+ IOPS) | 500 GB+ SSD/NVMe |
| **Network** | 1 Gbps NIC | 10 Gbps NIC |
| **Nodes** | 1 (single-node) | 3+ (HA cluster) |

### 1.1 Harvester ISO Installation

#### Download Links

**v1.4.3 (Stable):**
```bash
# Full ISO (~3.5GB)
wget https://releases.rancher.com/harvester/v1.4.3/harvester-v1.4.3-amd64.iso

# Checksum
wget https://releases.rancher.com/harvester/v1.4.3/harvester-v1.4.3-amd64.sha512
sha512sum -c harvester-v1.4.3-amd64.sha512
```

**v1.6.1 (Latest Stable):**
```bash
# Full ISO
wget https://releases.rancher.com/harvester/v1.6.1/harvester-v1.6.1-amd64.iso

# Checksum  
wget https://releases.rancher.com/harvester/v1.6.1/harvester-v1.6.1-amd64.sha512
sha512sum -c harvester-v1.6.1-amd64.sha512
```

#### Create Bootable USB

```bash
# On macOS (replace diskN with your USB disk)
diskutil list
diskutil unmountDisk /dev/diskN
sudo dd if=harvester-v1.4.3-amd64.iso of=/dev/rdiskN bs=4m status=progress
diskutil eject /dev/diskN
```

```bash
# On Linux
lsblk
sudo dd if=harvester-v1.4.3-amd64.iso of=/dev/sdX bs=4M status=progress
sync
```

#### Installation Steps

1. **Boot from USB** - Set BIOS/UEFI to boot from USB
2. **Select "Create a new Harvester cluster"**
3. **Configure Installation:**
   - Installation Target: Select disk to install Harvester
   - Data Disk: Same disk or separate disk for VM storage
   - Hostname: `harvester-barleta`
   - Management Network:
     - Interface: Select primary NIC
     - IP Method: Static recommended
     - IP: `192.168.1.30/24` (or new IP)
     - Gateway: `192.168.1.254`
     - DNS: `192.168.1.254`
   - VIP: `192.168.1.31` (for HA access)
   - Cluster Token: Generate secure token
   - Password: Set rancher user password
4. **Wait for installation** (~10-20 minutes)
5. **Access UI** at `https://192.168.1.30` or VIP

### 1.2 Initial Harvester Configuration

- [x] Access Harvester UI at https://192.168.1.152
- [x] Configure storage settings (Longhorn - default)
- [x] Download kubeconfig to `~/.kube/harvester.yaml`
- [ ] Configure VM network for workloads (in progress via Terraform)
- [ ] Set up authentication (local or OIDC) - optional

### 1.3 Create Terraform Provider Configuration

**File**: `barleta/infrastructure/providers.tf`

```hcl
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    harvester = {
      source  = "harvester/harvester"
      version = "~> 0.6"
    }
  }
}

provider "harvester" {
  kubeconfig = var.harvester_kubeconfig
}
```

---

## Phase 2: FreeIPA VM Deployment

**Duration**: 1 day  
**Status**: In Progress  
**Dependencies**: Phase 1

### 2.1 IP Address Scheme

| Resource | IP Address | Notes |
|----------|------------|-------|
| Harvester Node | 192.168.1.10 | Physical host |
| Harvester Management | 192.168.1.152 | UI/API access |
| FreeIPA VM | 192.168.1.212 | Identity server |
| Gateway | 192.168.1.254 | Home network gateway |

### 2.2 Terraform Resources

**File**: `barleta/infrastructure/main.tf`

- [x] Fedora Cloud 41 image for FreeIPA
- [x] SSH key from project root (`id_rsa.pub`)
- [x] VM network (`barleta-lan`)
- [x] FreeIPA VM definition with cloud-init
- [x] Terraform initialized and plan validated

### 2.3 Deploy FreeIPA VM

```bash
cd barleta/infrastructure
terraform apply
```

- [ ] Apply Terraform configuration
- [ ] Verify FreeIPA VM boots and gets IP
- [ ] Verify FreeIPA installation completes
- [ ] Test LDAP/Kerberos connectivity

---

## Phase 3: Native RKE2 Workload Deployment

**Duration**: 1-2 days  
**Status**: Not Started  
**Dependencies**: Phase 2

### Strategy: Use Native Harvester RKE2

Instead of creating a separate guest cluster, we deploy workloads directly to Harvester's native RKE2 cluster. This simplifies the architecture and reduces resource overhead.

**Benefits:**
- No additional VMs for K8s control plane
- Direct access to Longhorn storage
- Simpler networking
- Lower resource usage

### 3.1 Verify Cluster Access

```bash
export KUBECONFIG=~/.kube/harvester.yaml
kubectl get nodes
kubectl get sc  # Storage classes
```

### 3.2 Create Barleta Namespace

```bash
kubectl create namespace barleta
kubectl create namespace argocd
kubectl create namespace cert-manager
kubectl create namespace identity
```

### 3.3 Storage Configuration

Harvester uses Longhorn by default. Verify storage class:

```bash
kubectl get sc
# Should show: harvester-longhorn (default)
```

---

## Phase 4: Core Platform Services

**Duration**: 2-3 days  
**Status**: Not Started  
**Dependencies**: Phase 3

### 4.1 cert-manager Installation

- [ ] Deploy cert-manager via Helm
- [ ] Configure ClusterIssuer for step-ca
- [ ] Verify certificate issuance

### 4.2 ArgoCD Installation

- [ ] Deploy ArgoCD via Helm/Terraform
- [ ] Configure repository secret (deploy key)
- [ ] Create root Application pointing to `barleta/apps/`
- [ ] Verify GitOps sync

### 4.3 Ingress Controller

- [ ] Deploy Traefik or alternative ingress
- [ ] Configure TLS termination
- [ ] Set up default backend

### 4.4 Internal CA (step-ca)

- [ ] Deploy step-ca for internal certificates
- [ ] Configure cert-manager integration
- [ ] Migrate or regenerate root CA

---

## Phase 5: Application Migration

**Duration**: 3-5 days  
**Status**: Not Started  
**Dependencies**: Phase 4

### 5.1 Create Fresh Application Manifests

- [ ] Create `barleta/apps/` ArgoCD application structure
- [ ] Define namespaces and RBAC
- [ ] Configure storage classes (Longhorn)
- [ ] Set up ingress hosts (`*.barleta.local`)

### 5.2 Identity Stack (Fresh Deployment)

**Order of deployment:**
1. PostgreSQL (fresh database)
2. FreeIPA VM (fresh install via cloud-init)
3. Keycloak (fresh realm configuration)
4. MidPoint (fresh setup)

- [ ] Deploy PostgreSQL (CloudNativePG or Helm)
- [ ] Configure FreeIPA realm (`barleta.local`)
- [ ] Deploy Keycloak, create new realm
- [ ] Configure Keycloak → FreeIPA LDAP federation
- [ ] Deploy MidPoint, configure connectors
- [ ] Create initial users and groups
- [ ] Test authentication flows

### 5.3 GitHub Actions Runners

- [ ] Deploy ARC (Actions Runner Controller)
- [ ] Configure GitHub App credentials
- [ ] Deploy runner scale sets
- [ ] Verify workflow execution

---

## Phase 6: DNS & Network Configuration

**Duration**: 1 day  
**Status**: Not Started  
**Dependencies**: Phase 5

### 6.1 DNS Configuration

- [ ] Configure local DNS resolution for `*.barleta.local`
- [ ] Add entries to `/etc/hosts` or home router DNS:
  - `192.168.1.212 ipa.barleta.local`
  - `192.168.1.x keycloak.barleta.local`
  - `192.168.1.x argocd.barleta.local`
- [ ] Update any external DNS if applicable

### 6.2 Update Local Client Configurations

- [ ] Update kubeconfig files
- [ ] Update Ansible inventory
- [ ] Configure browser certificates (if using internal CA)

---

## Phase 7: Validation & Cleanup

**Duration**: 2-3 days  
**Status**: Not Started  
**Dependencies**: Phase 6

### 7.1 Comprehensive Testing

- [ ] Test all application endpoints
- [ ] Test authentication flows (Keycloak → FreeIPA)
- [ ] Test GitHub Actions workflows
- [ ] Test certificate issuance
- [ ] Test DNS resolution

### 7.2 Monitoring & Observability

- [ ] Verify logging is working
- [ ] Set up basic monitoring (if applicable)
- [ ] Verify Hubble (if using Cilium) or equivalent

### 7.3 Documentation Updates

- [ ] Update README.md
- [ ] Update architecture diagrams
- [ ] Update runbooks and playbooks
- [ ] Archive HomePractice/HomeProd docs

### 7.4 Cleanup

- [ ] Archive `homepractice/` directory (git tag/branch)
- [ ] Archive `homeprod/` directory
- [ ] Remove Proxmox-specific modules (or archive)
- [ ] Update Makefile for new structure
- [ ] Clean up old Terraform state

---

## Phase 8: Proxmox Decommission

**Duration**: 1 day  
**Status**: Not Started  
**Dependencies**: Phase 7 (after validation period)

### 8.1 Final Backup

- [ ] Take final snapshots of all Proxmox VMs
- [ ] Export any remaining data
- [ ] Document final state for reference

### 8.2 Proxmox Shutdown

- [ ] Shut down all HomePractice VMs
- [ ] Shut down all HomeProd VMs
- [ ] Optionally keep Proxmox available for rollback

### 8.3 Hardware Transition

- [ ] If same hardware: Wipe and install Harvester
- [ ] If different hardware: Proxmox can remain for testing

---

## Risk Assessment

### Risks

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Harvester compatibility issues | Medium | High | Test thoroughly before production use |
| Application incompatibility | Low | Medium | Test each app individually |
| Network connectivity issues | Medium | Medium | Document all IPs, test thoroughly |

### Notes

- **Fresh deployments** eliminate data migration risks
- **No rollback needed** - old Proxmox environment can remain until confident
- **Simplified architecture** - no VPN, no OPNsense reduces complexity

---

## File Changes Summary

### New Files to Create

```
barleta/
├── infrastructure/
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   ├── terraform.tfvars
│   └── freeipa-cloudinit.yaml
├── kubernetes/
│   ├── main.tf
│   ├── variables.tf
│   └── outputs.tf
├── apps/
│   ├── argocd-root.yaml
│   ├── identity/
│   ├── infrastructure/
│   ├── networking/
│   └── ...
└── ansible/
    ├── inventory.yml
    ├── ansible.cfg
    └── playbooks/

modules/
├── harvester-vm/
│   ├── main.tf
│   ├── variables.tf
│   └── outputs.tf
└── harvester-cluster/
    ├── main.tf
    ├── variables.tf
    └── outputs.tf
```

### Files to Archive/Deprecate

```
homepractice/           # Archive after migration
homeprod/               # Archive after migration
modules/proxmox-vm/     # Archive (keep for reference)
modules/proxmox-lxc/    # Archive (keep for reference)
modules/opnsense-template/  # Keep if OPNsense needs management
```

### Files to Update

```
Makefile                # Add barleta targets
README.md               # Update documentation
.gitignore              # Add Harvester-specific ignores
```

---

## Timeline Estimate

| Phase | Duration | Cumulative |
|-------|----------|------------|
| Phase 0: Preparation | 1-2 days | 2 days |
| Phase 1: Harvester Install | 1 day | 3 days |
| Phase 2: Network & VMs | 2-3 days | 6 days |
| Phase 3: Guest Cluster | 2-3 days | 9 days |
| Phase 4: Core Services | 2-3 days | 12 days |
| Phase 5: App Migration | 3-5 days | 17 days |
| Phase 6: Cutover | 1 day | 18 days |
| Phase 7: Validation | 2-3 days | 21 days |
| Phase 8: Decommission | 1 day | 22 days |

**Total estimated duration: 3-4 weeks**

---

## Next Steps

1. Review and approve this migration plan
2. Schedule maintenance windows if needed
3. Begin Phase 0: Backup and documentation
4. Proceed phase by phase, validating at each step
