# AdGuard Home DNS Server

GitOps-managed DNS server for the HomePractice environment.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                 Home Network (192.168.1.0/24)                   │
│                                                                 │
│  ┌──────────────┐     DNS      ┌─────────────────┐             │
│  │ Home Devices │ ───────────► │ AdGuard Home    │             │
│  │ (phones, PCs)│              │ 192.168.1.53    │             │
│  └──────────────┘              └────────┬────────┘             │
│                                         │                       │
│                    ┌────────────────────┴────────────────┐     │
│                    │                                     │     │
│                    ▼                                     ▼     │
│         ┌─────────────────┐              ┌─────────────────┐  │
│         │ practice.local  │              │ Other domains   │  │
│         │ → OPNsense      │              │ → Home Router   │  │
│         │   192.168.1.40  │              │   192.168.1.254 │  │
│         └────────┬────────┘              └─────────────────┘  │
│                  │                                             │
│                  ▼                                             │
│         ┌─────────────────┐                                    │
│         │ HomePractice    │                                    │
│         │ 10.10.10.0/24   │                                    │
│         │ (keycloak, etc) │                                    │
│         └─────────────────┘                                    │
└─────────────────────────────────────────────────────────────────┘
```

## DNS Forwarding Rules

| Domain Pattern | Forwards To | Purpose |
|----------------|-------------|---------|
| `*.practice.local` | 192.168.1.40 (OPNsense) | HomePractice services |
| `10.10.10.in-addr.arpa` | 192.168.1.40 (OPNsense) | Reverse DNS for HomePractice |
| Everything else | 192.168.1.254 (Home Router) | Internet DNS |

## Deployment

### Prerequisites

1. Download Debian LXC template to Proxmox:
   ```bash
   pveam update
   pveam download local debian-12-standard_12.7-1_amd64.tar.zst
   ```

2. Set the template variable in `terraform.tfvars`:
   ```hcl
   debian_lxc_template_id = "local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst"
   ```

### Deploy

```bash
cd homepractice/infrastructure
terraform plan
terraform apply
```

### Verify

1. Access Web UI: http://192.168.1.53:3000
   - Default login: admin / admin (change on first login)

2. Test DNS resolution:
   ```bash
   # From any device on 192.168.1.X
   nslookup keycloak.practice.local 192.168.1.53
   nslookup google.com 192.168.1.53
   ```

## Configure Home Devices

### Option A: Router DHCP (Recommended)
Set 192.168.1.53 as the DNS server in your home router's DHCP settings.
All devices will automatically use AdGuard Home.

### Option B: Per-Device
Manually set DNS to 192.168.1.53 on individual devices.

## GitOps Configuration

The AdGuard Home config is stored in `AdGuardHome.yaml`. To update:

1. Edit `AdGuardHome.yaml`
2. Commit and push
3. Run `terraform apply` to re-provision

Key configuration sections:
- `dns.upstream_dns` - Conditional forwarding rules
- `filtering` - Ad blocking settings
- `filters` - Block lists

## Troubleshooting

### Check AdGuard Home status
```bash
ssh root@192.168.1.53 systemctl status AdGuardHome
```

### View logs
```bash
ssh root@192.168.1.53 journalctl -u AdGuardHome -f
```

### Test upstream connectivity
```bash
ssh root@192.168.1.53 dig @192.168.1.40 keycloak.practice.local
ssh root@192.168.1.53 dig @192.168.1.254 google.com
```
