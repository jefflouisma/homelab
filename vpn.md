# NetBird VPN Integration for HomePractice

## Overview

NetBird is a WireGuard-based mesh VPN that provides zero-config connectivity with identity-based access control. Users authenticate via SSO (Keycloak) and automatically connect to the mesh network without manual configuration.

## Architecture Options

### Option 1: NetBird Cloud + OPNsense Gateway (Recommended for Simplicity)

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           Internet                                       │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                    ┌───────────────┴───────────────┐
                    │                               │
                    ▼                               ▼
        ┌───────────────────┐           ┌───────────────────┐
        │  NetBird Cloud    │           │   Mobile/Laptop   │
        │  (Management +    │◄─────────►│   NetBird Client  │
        │   Signal + Relay) │   OIDC    │                   │
        └───────────────────┘           └───────────────────┘
                    │                               │
                    │ Setup Key                     │ WireGuard P2P
                    ▼                               ▼
        ┌───────────────────────────────────────────────────────────────┐
        │                    OPNsense (192.168.1.1)                      │
        │                    os-netbird plugin                           │
        │                    Gateway for 10.0.0.0/8                      │
        └───────────────────────────────────────────────────────────────┘
                                    │
                    ┌───────────────┴───────────────┐
                    │                               │
                    ▼                               ▼
        ┌───────────────────┐           ┌───────────────────┐
        │   K3s Cluster     │           │   Other 10.x      │
        │   10.10.10.10     │           │   Hosts           │
        └───────────────────┘           └───────────────────┘
```

**Pros:**
- Fastest to deploy (minutes)
- No infrastructure to maintain
- Free tier: unlimited peers, 5 users
- Signal and relay servers globally distributed

**Cons:**
- Relies on external service
- Authentication via NetBird's SSO integration (redirects to Keycloak)
- Less control over management plane

**Steps:**
1. Sign up at app.netbird.io
2. Configure Keycloak as IdP in NetBird dashboard
3. Install os-netbird plugin on OPNsense
4. Create setup key and configure OPNsense as routing peer
5. Users install NetBird client and authenticate

---

### Option 2: Self-Hosted NetBird on K3s + OPNsense Gateway (Recommended for Control)

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           Internet                                       │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
        ┌───────────────────────────────────────────────────────────────┐
        │                    OPNsense (192.168.1.1)                      │
        │                    NAT + os-netbird plugin                     │
        │                    Gateway for 10.0.0.0/8                      │
        └───────────────────────────────────────────────────────────────┘
                                    │
                    ┌───────────────┼───────────────┐
                    │               │               │
                    ▼               ▼               ▼
        ┌─────────────────┐ ┌─────────────────┐ ┌─────────────────┐
        │   K3s Cluster   │ │   Keycloak      │ │   Other 10.x    │
        │   10.10.10.10   │ │   (IdP)         │ │   Hosts         │
        │                 │ │                 │ │                 │
        │ ┌─────────────┐ │ └─────────────────┘ └─────────────────┘
        │ │  NetBird    │ │
        │ │  - Mgmt     │ │
        │ │  - Signal   │ │
        │ │  - Dashboard│ │
        │ │  - Relay    │ │
        │ └─────────────┘ │
        └─────────────────┘
                    │
                    ▼
        ┌───────────────────┐
        │   Mobile/Laptop   │
        │   NetBird Client  │◄──── Authenticates via Keycloak
        └───────────────────┘      Connects to self-hosted NetBird
```

**Pros:**
- Full control and data sovereignty
- No external dependencies
- Unlimited users/devices (no licensing)
- Uses existing Keycloak infrastructure
- All traffic stays local when on-premises

**Cons:**
- More complex to deploy
- Requires exposing NetBird services externally (via NAT)
- Need to manage TURN/relay for NAT traversal

**Components to Deploy:**
1. **netbird-management** - Control plane API
2. **netbird-signal** - WebRTC signaling
3. **netbird-dashboard** - Web UI
4. **coturn** - TURN/relay server for NAT traversal
5. **PostgreSQL** - Database for management

---

## OPNsense os-netbird Plugin Configuration

### Installation

```bash
# Via OPNsense UI
System > Firmware > Plugins > os-netbird
```

### Configuration Steps

1. **Get Setup Key** from NetBird dashboard (cloud or self-hosted)
   - Navigate to Setup Keys in NetBird dashboard
   - Create a reusable key with appropriate expiration

2. **Configure Plugin** (VPN > NetBird > Settings)
   ```
   Enabled: ✓
   Setup Key: nb-XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX
   Management URL: https://api.netbird.io (cloud) or https://netbird.practice.local (self-hosted)
   Admin URL: (leave empty for cloud, set for self-hosted)
   Hostname: opnsense-gateway
   Log Level: info
   Disable Server Routes: ✗ (so OPNsense advertises local routes)
   ```

3. **Assign Interface**
   - Interfaces > Assignments > Add `wt0` (NetBird WireGuard interface)
   - Enable interface, no IP needed
   - Prevent interface removal: ✓

4. **Firewall Rules** (Firewall > Rules > wt0)
   ```
   Action: Pass
   Interface: wt0
   Protocol: Any
   Source: wt0 net (NetBird peers)
   Destination: 10.0.0.0/8
   Description: Allow NetBird peers to access internal network
   ```

5. **NAT Outbound** (Firewall > NAT > Outbound)
   - Mode: Hybrid
   - Add rule:
     ```
     Interface: WAN
     Source: wt0 net
     Translation: Interface Address
     Description: NAT NetBird traffic to WAN
     ```

6. **Verify Routes**
   - Check VPN > NetBird > Log File
   - Verify peers can reach 10.x hosts

---

## Keycloak Integration

### OIDC Clients Required

#### 1. Dashboard Client (browser login)
```yaml
clientId: netbird-dashboard
name: NetBird Dashboard
protocol: openid-connect
publicClient: false
standardFlowEnabled: true
redirectUris:
  - https://netbird.practice.local/*
  - https://netbird.practice.local/callback
webOrigins:
  - https://netbird.practice.local
defaultClientScopes:
  - openid
  - profile
  - email
```

#### 2. Backend/Management Client (service account)
```yaml
clientId: netbird-backend
name: NetBird Backend
protocol: openid-connect
publicClient: false
serviceAccountsEnabled: true
standardFlowEnabled: false
# Assign realm roles: view-users, manage-users
```

#### 3. Device/CLI Client (native app)
```yaml
clientId: netbird-client
name: NetBird Client
protocol: openid-connect
publicClient: true
standardFlowEnabled: true
directAccessGrantsEnabled: true
# Enable OAuth 2.0 Device Authorization Grant for device flow
attributes:
  oauth2.device.authorization.grant.enabled: true
```

---

## Self-Hosted Deployment on K3s

### Namespace and Prerequisites

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: netbird
---
apiVersion: v1
kind: Secret
metadata:
  name: netbird-secrets
  namespace: netbird
type: Opaque
stringData:
  NETBIRD_MGMT_IDP_OIDC_CLIENT_SECRET: "keycloak-client-secret"
  NETBIRD_STORE_POSTGRES_PASSWORD: "postgres-password"
  TURN_PASSWORD: "turn-secret"
```

### Helm Values (conceptual - using jaconi chart or similar)

```yaml
# values.yaml for netbird-backend chart
management:
  image: netbirdio/management:latest
  env:
    NETBIRD_MGMT_API_ENDPOINT: "https://netbird-api.practice.local"
    NETBIRD_MGMT_DASHBOARD_URL: "https://netbird.practice.local"
    
    # Database
    NETBIRD_STORE_ENGINE: postgres
    NETBIRD_STORE_POSTGRES_HOST: postgresql.netbird.svc.cluster.local
    NETBIRD_STORE_POSTGRES_PORT: "5432"
    NETBIRD_STORE_POSTGRES_USER: netbird
    NETBIRD_STORE_POSTGRES_DB: netbird
    
    # OIDC / Keycloak
    NETBIRD_MGMT_IDP_MANAGER_TYPE: keycloak
    NETBIRD_MGMT_IDP_OIDC_ISSUER: "https://keycloak.practice.local/realms/practice"
    NETBIRD_MGMT_IDP_OIDC_CLIENT_ID: netbird-backend
    NETBIRD_MGMT_IDP_ADMIN_ENDPOINT: "https://keycloak.practice.local/admin/realms/practice"
    NETBIRD_MGMT_IDP_TOKEN_ENDPOINT: "https://keycloak.practice.local/realms/practice/protocol/openid-connect/token"
    NETBIRD_MGMT_IDP_GRANT_TYPE: client_credentials
    
    # TURN
    NETBIRD_MGMT_TURN_URL: "turn:turn.practice.local:3478?transport=udp"
    NETBIRD_MGMT_TURN_USERNAME: netbird

signal:
  image: netbirdio/signal:latest
  env:
    NETBIRD_SIGNAL_ENDPOINT: "https://netbird-signal.practice.local"

dashboard:
  image: netbirdio/dashboard:latest
  env:
    NETBIRD_MGMT_API_ENDPOINT: "https://netbird-api.practice.local"
    AUTH_AUTHORITY: "https://keycloak.practice.local/realms/practice"
    AUTH_CLIENT_ID: netbird-dashboard
    AUTH_REDIRECT_URI: "https://netbird.practice.local/callback"

ingress:
  enabled: true
  className: traefik
  annotations:
    cert-manager.io/cluster-issuer: stepca
  hosts:
    - host: netbird.practice.local
      service: dashboard
    - host: netbird-api.practice.local
      service: management
    - host: netbird-signal.practice.local
      service: signal
  tls:
    - secretName: netbird-tls
      hosts:
        - netbird.practice.local
        - netbird-api.practice.local
        - netbird-signal.practice.local
```

---

## Network Ports Required

### For Self-Hosted NetBird Server

| Port | Protocol | Service | Direction |
|------|----------|---------|-----------|
| 443 | TCP | Dashboard/API (HTTPS) | Inbound |
| 80 | TCP | HTTP redirect | Inbound |
| 33073 | TCP | gRPC Management | Inbound |
| 10000 | TCP | Signal (gRPC) | Inbound |
| 3478 | UDP | TURN/STUN | Inbound |
| 49152-65535 | UDP | TURN relay range | Inbound |

### For NetBird Clients

| Port | Protocol | Service | Direction |
|------|----------|---------|-----------|
| 51820 | UDP | WireGuard | Outbound |
| 443 | TCP | Management API | Outbound |

---

## User Experience

### What Users Need to Do

1. **Install NetBird Client**
   - Download from https://netbird.io/download
   - Available for Windows, macOS, Linux, iOS, Android

2. **Authenticate**
   - Open NetBird client
   - Click "Login" → Redirects to Keycloak
   - Authenticate with passkey or password
   - Client automatically connects

3. **Access Resources**
   - All 10.x hosts accessible immediately
   - No manual configuration needed
   - Traffic routes through OPNsense gateway

### What Users DON'T Need to Do

- Configure WireGuard keys
- Set up routing tables
- Configure firewall rules
- Enter IP addresses or ports

---

## Comparison Summary

| Feature | Option 1: Cloud | Option 2: Self-Hosted |
|---------|-----------------|----------------------|
| **Setup Time** | 30 minutes | 2-4 hours |
| **Maintenance** | None | Moderate |
| **Cost** | Free (5 users) | Free (unlimited) |
| **Data Sovereignty** | External | Full control |
| **Keycloak Integration** | Via SSO settings | Direct OIDC |
| **Reliability** | High (managed) | Depends on your infra |
| **External Dependency** | Yes | No |

## Recommendation

For HomePractice, **Option 2 (Self-Hosted)** is recommended because:

1. Already have K3s cluster with capacity
2. Already have Keycloak for identity
3. Full control and no external dependencies
4. Aligns with homelab learning objectives
5. No user/device limits

### Implementation Order

1. Deploy PostgreSQL for NetBird (can use existing if available)
2. Create Keycloak OIDC clients for NetBird
3. Deploy Coturn (TURN server) for NAT traversal
4. Deploy NetBird management, signal, dashboard
5. Configure OPNsense os-netbird plugin as gateway
6. Test with mobile device

---

## Files to Create

```
homepractice/apps/networking/netbird/
├── kustomization.yaml
├── namespace.yaml
├── secrets.yaml (sealed)
├── postgresql/
│   ├── deployment.yaml
│   └── service.yaml
├── coturn/
│   ├── deployment.yaml
│   └── service.yaml
├── management/
│   ├── deployment.yaml
│   ├── service.yaml
│   └── configmap.yaml
├── signal/
│   ├── deployment.yaml
│   └── service.yaml
├── dashboard/
│   ├── deployment.yaml
│   └── service.yaml
└── ingress.yaml
```

## Next Steps

1. [ ] Create Keycloak OIDC clients for NetBird
2. [ ] Deploy PostgreSQL for NetBird state
3. [ ] Deploy Coturn TURN server
4. [ ] Deploy NetBird services on K3s
5. [ ] Configure Ingress and TLS
6. [ ] Install os-netbird on OPNsense
7. [ ] Create setup key and configure gateway
8. [ ] Test client connectivity
9. [ ] Document user onboarding process
