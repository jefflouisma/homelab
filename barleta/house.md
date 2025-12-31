# Home Automation & AI Assistant Stack

This document outlines the deployment of Home Assistant and Agent Zero AI assistant on the Barleta Harvester platform with Keycloak SSO integration.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          Barleta House Stack                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌──────────────────────┐         ┌──────────────────────┐                  │
│  │    Home Assistant    │         │     Agent Zero       │                  │
│  │    (Smart Home)      │         │   (AI Assistant)     │                  │
│  │                      │         │                      │                  │
│  │  - hass-oidc-auth    │         │  - LLM Integration   │                  │
│  │  - Keycloak SSO      │         │  - Task Automation   │                  │
│  │  - HACS Integrations │         │  - Code Execution    │                  │
│  └──────────┬───────────┘         └──────────┬───────────┘                  │
│             │                                │                               │
│             └────────────┬───────────────────┘                              │
│                          │                                                   │
│                   ┌──────┴──────┐                                           │
│                   │  Keycloak   │                                           │
│                   │    SSO      │                                           │
│                   └─────────────┘                                           │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Components

### 1. Home Assistant

**Purpose**: Smart home automation platform for controlling IoT devices, automations, and dashboards.

**Version**: Latest stable (2024.12.x as of December 2025)

**SSO Integration**: hass-oidc-auth v0.6.3-alpha
- Custom HACS integration for OIDC authentication
- Redirects login to Keycloak at `/auth/oidc/welcome`
- Callback at `/auth/oidc/callback`
- Public client (no client_secret required)

**Deployment Method**: Helm chart (`pajikos/helm-hass/home-assistant` v0.3.36)

**Key Features**:
- Persistent configuration storage
- Traefik ingress integration
- HACS for custom integrations
- Keycloak OIDC via hass-oidc-auth

---

### 2. Agent Zero AI Assistant

**Purpose**: General-purpose AI framework for autonomous task execution, code generation, and multi-agent cooperation.

**Version**: v0.9.7 (latest as of December 2025)

**Docker Image**: `agent0ai/agent-zero:latest`

**Key Features**:
- Autonomous task execution
- Persistent memory across sessions
- Multi-agent cooperation (hierarchical agents)
- Real-time interaction via web UI
- Project isolation with per-project secrets
- Docker-based execution environment

**LLM Integration**: Configured via web UI
- Supports Ollama, OpenAI, and other providers
- Can use local LLMs for privacy

---

## Deployment Plan

### Phase 1: Keycloak Client Setup

1. **Create Home Assistant client** in Keycloak (barleta realm)
   - Client ID: `homeassistant`
   - Client type: Public (no secret)
   - Valid redirect URIs: `http://homeassistant.barleta.local:31664/*`
   - Web origins: `http://homeassistant.barleta.local:31664`

2. **Create Agent Zero client** in Keycloak (if needed for future SSO)
   - Client ID: `agent-zero`
   - Note: Agent Zero doesn't have native OIDC; may need reverse proxy auth

### Phase 2: Deploy Home Assistant

1. **Add Helm repository**
   ```bash
   helm repo add helm-hass https://pajikos.github.io/helm-hass
   helm repo update
   ```

2. **Create namespace**
   ```bash
   kubectl create namespace house
   ```

3. **Deploy with Helm** using custom values:
   - Persistence enabled (Longhorn)
   - Traefik IngressRoute
   - Initial configuration with OIDC settings

4. **Post-deployment setup**:
   - Install HACS via UI
   - Install hass-oidc-auth integration via HACS
   - Configure `configuration.yaml` with Keycloak OIDC settings

### Phase 3: Deploy Agent Zero

1. **Create Kubernetes manifests**:
   - Deployment with `agent0ai/agent-zero:latest`
   - PersistentVolumeClaim for `/a0/usr` data
   - Service (ClusterIP)
   - Traefik IngressRoute

2. **Configure LLM provider**:
   - Option A: Use Ollama (requires Ollama deployment)
   - Option B: Use OpenAI API (requires API key)

3. **Access web UI** and complete configuration

### Phase 4: Integration & Verification

1. Test Home Assistant OIDC login via Keycloak
2. Test Agent Zero web UI access
3. Configure Home Assistant automations
4. Test Agent Zero task execution

---

## Kubernetes Manifests

### Namespace

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: house
```

### Home Assistant Helm Values

```yaml
# homeassistant-values.yaml
image:
  repository: ghcr.io/home-assistant/home-assistant
  tag: stable

persistence:
  enabled: true
  storageClass: longhorn
  size: 10Gi

ingress:
  enabled: false  # Using Traefik IngressRoute instead

service:
  type: ClusterIP
  port: 8123

resources:
  requests:
    cpu: 250m
    memory: 512Mi
  limits:
    cpu: 2000m
    memory: 2Gi

# Configuration will be added post-deployment via ConfigMap
env:
  - name: TZ
    value: "America/Los_Angeles"
```

### Agent Zero Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: agent-zero
  namespace: house
spec:
  replicas: 1
  selector:
    matchLabels:
      app: agent-zero
  template:
    metadata:
      labels:
        app: agent-zero
    spec:
      containers:
        - name: agent-zero
          image: agent0ai/agent-zero:latest
          ports:
            - containerPort: 80
          volumeMounts:
            - name: data
              mountPath: /a0/usr
          resources:
            requests:
              cpu: 500m
              memory: 1Gi
            limits:
              cpu: 2000m
              memory: 4Gi
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: agent-zero-data
```

### Traefik IngressRoutes

```yaml
# Home Assistant
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: homeassistant
  namespace: house
spec:
  entryPoints:
    - web
  routes:
    - match: Host(`homeassistant.barleta.local`)
      kind: Rule
      services:
        - name: homeassistant
          port: 8123
---
# Agent Zero
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: agent-zero
  namespace: house
spec:
  entryPoints:
    - web
  routes:
    - match: Host(`agent-zero.barleta.local`)
      kind: Rule
      services:
        - name: agent-zero
          port: 80
```

---

## SSO Configuration

### Home Assistant OIDC (hass-oidc-auth)

After installing hass-oidc-auth via HACS, add to `configuration.yaml`:

```yaml
auth_oidc:
  client_id: "homeassistant"
  discovery_url: "http://keycloak.identity.svc.cluster.local:8080/realms/barleta/.well-known/openid-configuration"
```

**Login URL**: `http://homeassistant.barleta.local:31664/auth/oidc/welcome`

### Agent Zero

Agent Zero doesn't have native OIDC support. Options:
1. **Traefik Forward Auth** with Keycloak (recommended for SSO)
2. **Basic Auth** via Traefik middleware
3. **No auth** (internal network only)

---

## Access URLs

| Service | URL | Authentication |
|---------|-----|----------------|
| Home Assistant | `http://homeassistant.barleta.local:31664` | Keycloak OIDC |
| Agent Zero | `http://agent-zero.barleta.local:31664` | Web UI (internal) |

---

## Dependencies

- **Keycloak**: Already deployed in identity namespace
- **Longhorn**: Storage class for persistence
- **Traefik**: Ingress controller with NodePort 31664

---

## Post-Deployment Tasks

1. **Home Assistant**:
   - Complete onboarding wizard
   - Install HACS from Settings → Add-ons
   - Install hass-oidc-auth from HACS → Integrations
   - Restart Home Assistant
   - Configure OIDC in Settings → Integrations

2. **Agent Zero**:
   - Access web UI
   - Configure LLM provider (Ollama or OpenAI)
   - Set up first project
   - Test task execution

---

## Notes

- **hass-oidc-auth is alpha software** - use with caution in production
- Agent Zero requires significant resources for AI operations
- Consider deploying Ollama for local LLM support
- Both services benefit from GPU acceleration (optional)

---

## Current Deployment Status (December 2025)

### Running Services

| Service | URL | Status |
|---------|-----|--------|
| **Home Assistant** | `http://homeassistant.barleta.local:31664` | ✅ Running |
| **Agent Zero** | `http://agent-zero.barleta.local:31664` | ✅ Running |

### Keycloak Client

| Client ID | Type | Realm |
|-----------|------|-------|
| `homeassistant` | Public (OIDC) | barleta |

### Post-Deployment Steps Required

1. **Home Assistant OIDC Setup**:
   - Access `http://homeassistant.barleta.local:31664`
   - Complete initial onboarding
   - Install HACS (Home Assistant Community Store)
   - Install `hass-oidc-auth` integration from HACS
   - Add to `configuration.yaml`:
     ```yaml
     auth_oidc:
       client_id: "homeassistant"
       discovery_url: "http://keycloak.identity.svc.cluster.local:8080/realms/barleta/.well-known/openid-configuration"
     ```
   - Restart Home Assistant
   - Access OIDC login at `/auth/oidc/welcome`

2. **Agent Zero Setup**:
   - Access `http://agent-zero.barleta.local:31664`
   - Go to Settings → Agent Settings
   - Configure LLM provider (Ollama or OpenAI)
   - Create first project

---

## Files

- `apps/house/homeassistant-deployment.yaml` - Home Assistant K8s manifests
- `apps/house/agent-zero-deployment.yaml` - Agent Zero K8s manifests
