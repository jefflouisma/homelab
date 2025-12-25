# AdGuard Home DNS Server

GitOps-managed DNS server for the HomePractice environment using **Hairpin NAT** strategy.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                       Home Network (192.168.1.0/24)                         │
│                                                                             │
│  ┌──────────────┐      DNS       ┌─────────────────┐                       │
│  │ Home Devices │ ─────────────► │  AdGuard Home   │                       │
│  │ (phones, PCs)│                │  192.168.1.10   │                       │
│  └──────────────┘                └────────┬────────┘                       │
│         │                                 │                                 │
│         │                    ┌────────────┴────────────┐                   │
│         │                    │                         │                   │
│         │                    ▼                         ▼                   │
│         │         ┌─────────────────┐      ┌─────────────────┐            │
│         │         │ practice.local  │      │ Other domains   │            │
│         │         │ → 192.168.1.40  │      │ → 192.168.1.254 │            │
│         │         │ (DNS rewrite)   │      │ (Home Router)   │            │
│         │         └────────┬────────┘      └─────────────────┘            │
│         │                  │                                               │
│         │    HTTPS :443    │                                               │
│         └──────────────────┼───────────────────────────────────────────┐  │
│                            ▼                                           │  │
│                   ┌─────────────────┐                                  │  │
│                   │    OPNsense     │◄── Hairpin NAT / Reflection      │  │
│                   │  192.168.1.40   │    (allows LAN to access WAN IP) │  │
│                   │     (WAN)       │                                  │  │
│                   └────────┬────────┘                                  │  │
│                            │ NAT: 443 → 10.10.10.230:443               │  │
└────────────────────────────┼───────────────────────────────────────────┘  │
                             │                                               │
┌────────────────────────────┼───────────────────────────────────────────────┘
│                            ▼
│              HomePractice LAN (10.10.10.0/24)
│
│                   ┌─────────────────┐
│                   │    Traefik      │
│                   │  10.10.10.230   │
│                   │  (Ingress)      │
│                   └────────┬────────┘
│                            │
│           ┌────────────────┼────────────────┐
│           ▼                ▼                ▼
│    ┌──────────┐     ┌──────────┐     ┌──────────┐
│    │ Keycloak │     │ TestApp  │     │  step-ca │
│    └──────────┘     └──────────┘     └──────────┘
└─────────────────────────────────────────────────────────────────────────────┘
```

## How It Works (Hairpin NAT)

1. **DNS Resolution**: AdGuard resolves `keycloak.practice.local` → `192.168.1.40`
2. **Client Connection**: Home device connects to `192.168.1.40:443`
3. **NAT Reflection**: OPNsense recognizes traffic to its own WAN IP and applies NAT
4. **Port Forward**: Traffic is forwarded to `10.10.10.230:443` (Traefik)
5. **Response**: Traefik serves the request, response flows back through OPNsense

## DNS Configuration

| Domain Pattern | Resolves To | Purpose |
|----------------|-------------|---------|
| `*.practice.local` | 192.168.1.40 | OPNsense WAN (NAT to Traefik) |
| `keycloak.practice.local` | 192.168.1.40 | Keycloak SSO |
| `testapp.practice.local` | 192.168.1.40 | Test Application |
| `ca.practice.local` | 192.168.1.40 | step-ca PKI |
| Everything else | 192.168.1.254 | Home Router (Internet) |

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

1. Access Web UI: http://192.168.1.10:3000
   - Default login: admin / admin (change on first login)

2. Test DNS resolution:
   ```bash
   # From any device on 192.168.1.X
   nslookup keycloak.practice.local 192.168.1.10
   nslookup google.com 192.168.1.10
   ```

## Configure Home Devices

### Option A: Router DHCP (Recommended)
Set 192.168.1.10 as the DNS server in your home router's DHCP settings.
All devices will automatically use AdGuard Home.

### Option B: Per-Device
Manually set DNS to 192.168.1.10 on individual devices.

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
ssh root@192.168.1.10 systemctl status AdGuardHome
```

### View logs
```bash
ssh root@192.168.1.10 journalctl -u AdGuardHome -f
```

### Test upstream connectivity
```bash
ssh root@192.168.1.10 dig @192.168.1.40 keycloak.practice.local
ssh root@192.168.1.10 dig @192.168.1.254 google.com
```
