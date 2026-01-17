# Home Automation & AI Assistant Stack

This document outlines the deployment of Home Assistant and Agent Zero AI assistant on the Barleta Harvester platform with Keycloak SSO integration.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          Barleta House Stack                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐           │
│  │  Home Assistant  │  │   Agent Zero     │  │    Jellyfin      │           │
│  │   (Smart Home)   │  │  (AI Assistant)  │  │  (Media Server)  │           │
│  │ - Keycloak SSO   │  │ - LLM Integration│  │ - NVIDIA GPU     │           │
│  │ - HACS           │  │ - Task Automation│  │ - HW Transcoding │           │
│  └────────┬─────────┘  └────────┬─────────┘  └────────┬─────────┘           │
│           │                     │                     │                     │
│  ┌────────┴─────────┐  ┌────────┴─────────┐           │                     │
│  │    Prowlarr      │  │   FlareSolverr   │           │                     │
│  │ (Indexer Manager)│  │ (Cloudflare Bypass)          │                     │
│  └──────────────────┘  └──────────────────┘           │                     │
│           │                     │                     │                     │
│           └─────────────────────┼─────────────────────┘                     │
│                                 │                                           │
│                          ┌──────┴──────┐                                    │
│                          │  Keycloak   │                                    │
│                          │    SSO      │                                    │
│                          └─────────────┘                                    │
│                                                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │                    NVIDIA GPU (Harvester Node)                        │   │
│  │                    Driver: 470.xx+ | CUDA 12.x                        │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
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

### 3. Jellyfin Media Server

**Purpose**: Open-source media server for streaming movies, TV shows, music, and photos with hardware-accelerated transcoding.

**Version**: 10.11.5 (latest stable as of December 2025)

**Docker Image**: `jellyfin/jellyfin:10.11.5` (with NVIDIA GPU support)

**Key Features**:
- Live TV & DVR support
- Hardware-accelerated transcoding (NVENC/NVDEC)
- Multiple user profiles with parental controls
- Mobile apps (iOS, Android)
- Chromecast, Roku, Apple TV support
- No subscription fees (fully open-source)

**NVIDIA GPU Acceleration**:
- **NVENC**: Hardware encoding for transcoding output
- **NVDEC**: Hardware decoding for transcoding input
- **Supported Codecs**: H.264, HEVC, VP9, AV1 (Turing+ GPUs)
- **Requirements**: NVIDIA Driver 470.xx+, NVIDIA Container Toolkit

**Storage Requirements**:
- Config: 1Gi (metadata, thumbnails)
- Media: External NFS/SMB mount or large PVC

---

### 4. Prowlarr + FlareSolverr Stack

**Purpose**: Indexer manager and Cloudflare bypass proxy for media automation.

**Components**:
- **Prowlarr**: Indexer manager that aggregates torrent/Usenet indexers and syncs with *arr apps (Sonarr, Radarr, etc.)
- **FlareSolverr**: Headless Chrome proxy that bypasses Cloudflare protection for indexers

**Docker Images**:
- `lscr.io/linuxserver/prowlarr:latest`
- `ghcr.io/flaresolverr/flaresolverr:latest`

**Key Features**:
- Unified indexer management across all *arr apps
- Automatic Cloudflare bypass for protected indexers
- Tag-based proxy routing (only uses FlareSolverr when needed)
- Health monitoring with liveness/readiness probes

**Access URLs**:
| Service | Direct IP | Hostname |
|---------|-----------|----------|
| Prowlarr | `http://192.168.1.10:30696` | `http://prowlarr.barleta.local:31664` |
| FlareSolverr | `http://192.168.1.10:30191` | Internal only |

**Configuring FlareSolverr in Prowlarr**:
1. Go to Settings → Indexers → Add Proxy
2. Select "FlareSolverr" type
3. URL: `http://flaresolverr:8191` (internal service)
4. Add a tag (e.g., `cloudflare`)
5. Apply same tag to Cloudflare-protected indexers

**Storage Requirements**:
- Config: 2Gi (Prowlarr configuration and database)

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

### Phase 4: Deploy Jellyfin with NVIDIA GPU

1. **Verify NVIDIA GPU availability** on Harvester node:
   ```bash
   kubectl get nodes -o=custom-columns='NAME:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu'
   ```

2. **Install NVIDIA Device Plugin** (if not present):
   ```bash
   kubectl apply -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.14.3/nvidia-device-plugin.yml
   ```

3. **Create Jellyfin manifests**:
   - Deployment with NVIDIA GPU resources
   - PersistentVolumeClaims for config and cache
   - Media volume mount (NFS or local path)
   - Service (ClusterIP)
   - Traefik IngressRoute

4. **Configure hardware acceleration** in Jellyfin:
   - Admin Dashboard → Playback → Transcoding
   - Hardware acceleration: NVIDIA NVENC
   - Enable hardware decoding for all supported codecs

### Phase 5: Integration & Verification

1. Test Home Assistant OIDC login via Keycloak
2. Test Agent Zero web UI access
3. Configure Home Assistant automations
4. Test Agent Zero task execution
5. Test Jellyfin playback with hardware transcoding
6. Verify GPU utilization during transcoding: `nvidia-smi`

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

### Jellyfin Deployment (with NVIDIA GPU)

```yaml
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: jellyfin-config
  namespace: house
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: 5Gi
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: jellyfin-cache
  namespace: house
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: 20Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: jellyfin
  namespace: house
spec:
  replicas: 1
  selector:
    matchLabels:
      app: jellyfin
  template:
    metadata:
      labels:
        app: jellyfin
    spec:
      # GPU access via NVIDIA device plugin (no runtimeClassName needed with Harvester add-ons)
      containers:
        - name: jellyfin
          image: jellyfin/jellyfin:10.11.5
          ports:
            - containerPort: 8096
              name: http
            - containerPort: 8920
              name: https
            - containerPort: 7359
              name: discovery
              protocol: UDP
          env:
            - name: NVIDIA_VISIBLE_DEVICES
              value: "all"
            - name: NVIDIA_DRIVER_CAPABILITIES
              value: "compute,utility,video"
            - name: TZ
              value: "America/Los_Angeles"
          volumeMounts:
            - name: config
              mountPath: /config
            - name: cache
              mountPath: /cache
            - name: media
              mountPath: /media
              readOnly: true
          resources:
            requests:
              cpu: 500m
              memory: 1Gi
            limits:
              cpu: 4000m
              memory: 8Gi
              nvidia.com/gpu: 1  # Request 1 NVIDIA GPU
          livenessProbe:
            httpGet:
              path: /health
              port: 8096
            initialDelaySeconds: 30
            periodSeconds: 30
          readinessProbe:
            httpGet:
              path: /health
              port: 8096
            initialDelaySeconds: 15
            periodSeconds: 10
      volumes:
        - name: config
          persistentVolumeClaim:
            claimName: jellyfin-config
        - name: cache
          persistentVolumeClaim:
            claimName: jellyfin-cache
        - name: media
          hostPath:
            path: /mnt/media  # Adjust to your media storage path
            type: Directory
---
apiVersion: v1
kind: Service
metadata:
  name: jellyfin
  namespace: house
spec:
  selector:
    app: jellyfin
  ports:
    - name: http
      port: 8096
      targetPort: 8096
    - name: https
      port: 8920
      targetPort: 8920
  type: ClusterIP
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: jellyfin
  namespace: house
spec:
  entryPoints:
    - web
  routes:
    - match: Host(`jellyfin.barleta.local`)
      kind: Rule
      services:
        - name: jellyfin
          port: 8096
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
| Jellyfin | `http://jellyfin.barleta.local:31664` | Built-in (local users) |

---

## Dependencies

- **Keycloak**: Already deployed in identity namespace
- **Longhorn**: Storage class for persistence
- **Traefik**: Ingress controller with NodePort 31664
- **Harvester Add-ons** (for Jellyfin GPU transcoding):
  - `pcidevices-controller` - PCI device discovery and passthrough
  - `nvidia-driver-toolkit` - NVIDIA driver installation and vGPU support
- **NVIDIA Device Plugin**: Kubernetes plugin for GPU resource scheduling

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

3. **Jellyfin**:
   - Access web UI at `http://jellyfin.barleta.local:31664`
   - Complete setup wizard (create admin user)
   - Add media libraries (Movies, TV Shows, Music)
   - Configure hardware acceleration:
     - Admin → Dashboard → Playback → Transcoding
     - Hardware acceleration: **NVIDIA NVENC**
     - Enable hardware decoding for: H.264, HEVC, VP9, AV1
   - Verify GPU transcoding with `nvidia-smi` during playback

---

## Notes

- **hass-oidc-auth is alpha software** - use with caution in production
- Agent Zero requires significant resources for AI operations
- Consider deploying Ollama for local LLM support
- **Jellyfin GPU Requirements**:
  - NVIDIA GPU with NVENC/NVDEC support (GTX 10-series or newer)
  - For AV1 encoding: RTX 40-series required
  - For AV1 decoding: RTX 30-series or newer
  - Harvester add-ons handle driver installation automatically
  - Enable `pcidevices-controller` and `nvidia-driver-toolkit` in Harvester UI

---

## Current Deployment Status (December 2025)

### Running Services

| Service | URL | Status |
|---------|-----|--------|
| **Home Assistant** | `http://homeassistant.barleta.local:31664` | ✅ Running |
| **Agent Zero** | `http://agent-zero.barleta.local:31664` | ✅ Running |
| **Jellyfin** | `http://jellyfin.barleta.local:31664` | 🔲 Planned |

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

## Centralized Logging (Loki + Alloy)

Log aggregation for all house apps using Grafana Loki stack.

### Components

| Component | Purpose | Location |
|-----------|---------|----------|
| **Loki** | Log storage & indexing (7-day retention) | `analytics` namespace |
| **Grafana Alloy** | Log collection via Kubernetes API | `analytics` namespace (DaemonSet) |
| **Grafana** | Visualization & dashboards | `analytics` namespace |

### Access

- **Grafana**: `http://grafana.barleta.local:31664`
- **Dashboards**: Grafana → House Apps folder
  - Jellyfin Logs
  - Home Assistant Logs
  - Prowlarr Logs
  - Agent Zero Logs

### LogQL Queries

```logql
# All Jellyfin logs
{namespace="house", app="jellyfin"}

# Home Assistant errors
{namespace="house", pod=~"homeassistant.*"} |~ "(?i)error|exception"

# Prowlarr + FlareSolverr
{namespace="house", pod=~"prowlarr.*"}

# Agent Zero LLM interactions
{namespace="house", pod=~"agent-zero.*"} |~ "(?i)llm|completion"
```

### Files

- `apps/analytics/loki-deployment.yaml` - Loki with 7-day retention
- `apps/analytics/alloy-daemonset.yaml` - Alloy log collector
- `apps/analytics/grafana-loki-datasource.yaml` - Datasource provisioning
- `apps/analytics/grafana-dashboards-house.yaml` - Dashboard definitions

---

## Files

- `apps/house/homeassistant-deployment.yaml` - Home Assistant K8s manifests
- `apps/house/agent-zero-deployment.yaml` - Agent Zero K8s manifests
- `apps/house/jellyfin-deployment.yaml` - Jellyfin with NVIDIA GPU support
- `apps/house/prowlarr-deployment.yaml` - Prowlarr + FlareSolverr stack
- `apps/house/nvidia-device-init.yaml` - NVIDIA device node init DaemonSet

---

## NVIDIA GPU Setup for Harvester v1.7.0

### Consumer GPU Solution (RTX 5080)

Harvester uses SLE Micro (immutable OS) which prevents traditional NVIDIA driver installation. This solution uses a custom pattern that works with consumer GPUs.

| Component | Status | Method |
|-----------|--------|--------|
| Driver Installation | ✅ | nvidia-driver-toolkit with consumer driver URL |
| Kernel Modules | ✅ | Loaded via toolkit (nvidia, nvidia_drm, nvidia_modeset) |
| Device Nodes | ✅ | Created via nvidia-device-init DaemonSet |
| Userspace Libraries | ✅ | Init container extracts from CUDA image |
| Container GPU Access | ✅ | Privileged container with /dev mount |

### Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  Harvester Node (Immutable SLE Micro)                           │
├─────────────────────────────────────────────────────────────────┤
│  nvidia-driver-toolkit addon                                     │
│  └─ Downloads consumer driver from nvidia.com                   │
│  └─ Compiles kernel modules with matching headers               │
│  └─ Loads: nvidia.ko, nvidia_drm.ko, nvidia_modeset.ko          │
├─────────────────────────────────────────────────────────────────┤
│  nvidia-device-init DaemonSet                                   │
│  └─ Creates /dev/nvidia0, /dev/nvidiactl, /dev/nvidia-modeset   │
│  └─ Runs on boot to ensure devices persist                      │
├─────────────────────────────────────────────────────────────────┤
│  Jellyfin Pod                                                   │
│  ├─ Init: nvidia-libs-init (extracts CUDA libs to emptyDir)    │
│  └─ Main: jellyfin (LD_LIBRARY_PATH=/nvidia-libs, mounts /dev)  │
└─────────────────────────────────────────────────────────────────┘
```

---

### Step 1: Enable Harvester Add-ons

```bash
# Enable pcidevices-controller
kubectl --kubeconfig ~/.kube/harvester.yaml patch addon pcidevices-controller \
  -n harvester-system --type='merge' -p '{"spec":{"enabled":true}}'

# Enable sriovgpudevice for the GPU
kubectl --kubeconfig ~/.kube/harvester.yaml patch sriovgpudevice harvester-barleta-000001000 \
  --type='merge' -p '{"spec":{"enabled":true}}'

# Enable nvidia-driver-toolkit with CONSUMER driver URL
kubectl --kubeconfig ~/.kube/harvester.yaml patch addon nvidia-driver-toolkit \
  -n harvester-system --type='merge' -p '{
    "spec": {
      "enabled": true,
      "valuesContent": "image:\n  tag: v1.7-20251222\n  repo: rancher/harvester-nvidia-driver-toolkit\ndriverLocation: \"https://download.nvidia.com/XFree86/Linux-x86_64/580.119.02/NVIDIA-Linux-x86_64-580.119.02.run\"\nfullnameOverride: nvidia-driver-runtime\n"
    }
  }'
```

> **Note**: The toolkit pod will crash-loop after driver install (tries to run vgpud which doesn't exist for consumer GPUs). This is expected - the kernel modules remain loaded.

### Step 2: Deploy Device Init DaemonSet

```bash
kubectl --kubeconfig ~/.kube/harvester.yaml apply -f apps/house/nvidia-device-init.yaml
```

This creates `/dev/nvidia*` device nodes on each boot.

### Step 3: Verify GPU Setup

```bash
# Check kernel modules loaded
kubectl --kubeconfig ~/.kube/harvester.yaml run check --rm -it --restart=Never \
  --image=busybox --overrides='{"spec":{"hostPID":true,"containers":[{"name":"c","image":"busybox","command":["cat","/proc/modules"],"securityContext":{"privileged":true}}]}}' | grep nvidia

# Check device nodes exist
kubectl --kubeconfig ~/.kube/harvester.yaml run check --rm -it --restart=Never \
  --image=busybox --overrides='{"spec":{"containers":[{"name":"c","image":"busybox","command":["ls","-la","/dev/nvidia0","/dev/nvidiactl"],"securityContext":{"privileged":true},"volumeMounts":[{"name":"dev","mountPath":"/dev"}]}],"volumes":[{"name":"dev","hostPath":{"path":"/dev"}}]}}'
```

### Step 4: Deploy Jellyfin with GPU

```bash
kubectl --kubeconfig ~/.kube/harvester.yaml apply -f apps/house/jellyfin-deployment.yaml
```

### Troubleshooting

| Issue | Solution |
|-------|----------|
| Toolkit pod crash-loop | Expected for consumer GPU; modules still load |
| No /dev/nvidia* devices | Check nvidia-device-init DaemonSet logs |
| Jellyfin can't see GPU | Verify /dev mount in pod; check init container logs |
| Driver won't compile | Ensure toolkit image tag matches Harvester version |

```bash
# Check driver toolkit logs (will show install success before vgpud fail)
kubectl --kubeconfig ~/.kube/harvester.yaml logs -n harvester-system -l app=nvidia-driver-runtime --tail=50

# Check device init logs
kubectl --kubeconfig ~/.kube/harvester.yaml logs -n kube-system -l app=nvidia-device-init -c create-devices

# Verify GPU in Jellyfin pod
POD=$(kubectl --kubeconfig ~/.kube/harvester.yaml get pods -n house -l app=jellyfin -o jsonpath='{.items[0].metadata.name}')
kubectl --kubeconfig ~/.kube/harvester.yaml exec -n house $POD -- cat /proc/driver/nvidia/version
```
