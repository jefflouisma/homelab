# NetBird VPN - Self-Hosted Deployment

## Overview

NetBird provides zero-config WireGuard VPN with Keycloak SSO authentication. Users install the NetBird client, authenticate via Keycloak (with passkey support), and automatically connect to the mesh network.

## Architecture

```
Internet
    │
    ▼
OPNsense (192.168.1.1) ◄─── os-netbird plugin (gateway for 10.0.0.0/8)
    │
    ├── K3s Cluster (10.10.10.10)
    │   ├── netbird-management (control plane)
    │   ├── netbird-signal (WebRTC signaling)
    │   ├── netbird-dashboard (web UI)
    │   ├── coturn (TURN relay)
    │   └── postgresql (state)
    │
    └── Keycloak (IdP)
    
    ▲
    │ WireGuard P2P
    │
Mobile/Laptop (NetBird Client)
```

## Components

| Component | Image | Purpose |
|-----------|-------|---------|
| coturn | coturn/coturn:4.6.2-alpine | TURN/STUN relay for NAT traversal |
| management | netbirdio/management:latest | Control plane API |
| signal | netbirdio/signal:latest | WebRTC signaling |
| dashboard | netbirdio/dashboard:latest | Web UI |

**Note:** Uses existing PostgreSQL from `identity` namespace (`identity-postgres-postgresql.identity.svc.cluster.local`).

## Keycloak OIDC Clients

Created automatically by `keycloak-clients-job.yaml`:

1. **netbird-dashboard** - Browser login (confidential client)
2. **netbird-backend** - Service account with `view-users` role
3. **netbird-client** - Device/CLI (public client with PKCE + device flow)

## DNS Entries Required

Add to AdGuard Home DNS rewrites:

```yaml
- domain: netbird.practice.local
  answer: 192.168.1.40
- domain: netbird-api.practice.local
  answer: 192.168.1.40
- domain: netbird-signal.practice.local
  answer: 192.168.1.40
- domain: turn.practice.local
  answer: 192.168.1.40
```

## OPNsense Configuration

1. Install `os-netbird` plugin
2. Create setup key in NetBird dashboard
3. Configure plugin:
   - Management URL: `https://netbird-api.practice.local`
   - Setup Key: (from dashboard)
4. Assign `wt0` interface
5. Create firewall rule: Allow wt0 net → 10.0.0.0/8

## User Onboarding

1. Download NetBird client from https://netbird.io/download
2. Configure management URL: `https://netbird-api.practice.local`
3. Login → Keycloak auth (passkey supported)
4. Connected! Access all 10.x hosts

## Deployment Order

```bash
# 1. Apply NetBird manifests
kubectl apply -k homepractice/apps/networking/netbird/

# 2. Wait for PostgreSQL
kubectl wait --for=condition=ready pod -l app=netbird-postgresql -n netbird

# 3. Wait for all services
kubectl wait --for=condition=ready pod -l app.kubernetes.io/part-of=netbird -n netbird

# 4. Create OPNsense setup key from dashboard
# 5. Configure os-netbird on OPNsense
```

## Secrets

Update `secrets.yaml` before deployment:

- `POSTGRES_PASSWORD` - PostgreSQL password
- `IDP_CLIENT_SECRET` - Keycloak backend client secret
- `TURN_PASSWORD` - TURN server credential
- `DATASTORE_ENCRYPTION_KEY` - 32-byte base64 encryption key

Generate encryption key:
```bash
openssl rand -base64 32
```
