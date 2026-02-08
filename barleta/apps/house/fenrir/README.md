# Fenrir README
# Multi-user game streaming for Kubernetes

## Overview

Fenrir is a Kubernetes-native adaptation of [Wolf (games-on-whales)](https://games-on-whales.github.io) for multi-user game streaming via Moonlight.

## Components

| Component | Description |
|-----------|-------------|
| `crds.yaml` | Custom Resource Definitions (App, Session, Pairing, User) |
| `wolf-operator.yaml` | Fenrir operator + Wolf streaming server |
| `moonlight-proxy.yaml` | Entry point for Moonlight clients |
| `retroarch-apps.yaml` | RetroArch game definitions |
| `storage.yaml` | PVCs for games and saves |

## Quick Start (GitOps)

Fenrir is deployed automatically via ArgoCD when manifests are committed.

1. **Commit and push** all Fenrir manifests to `main` branch
2. **ArgoCD syncs automatically** - deploys MetalLB → Gateway API → Fenrir
3. **Get the IP** for Apple TV:
   ```bash
   make fenrir-ip
   # or
   kubectl get svc moonlight-proxy -n house -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
   ```
4. **Connect from Moonlight**:
   - Open Moonlight on Apple TV
   - Add server by **IP address** (hostname not supported on Apple TV)
   - Pair with PIN code
   - Select "Game Library" to launch Pegasus

## ArgoCD Applications

| App | Purpose |
|-----|---------|
| `metallb` | LoadBalancer IP allocation |
| `metallb-config` | IP pool configuration |
| `gateway-api-crds` | Gateway API CRDs |
| `envoy-gateway` | Gateway controller |
| `fenrir` | Game streaming operator |

## Container Images

Build the Pegasus + emulators image:

```bash
cd images/pegasus-emulators
docker build -t ghcr.io/jefflouisma/pegasus-emulators:latest .
docker push ghcr.io/jefflouisma/pegasus-emulators:latest
```

## Game Storage

Mount your game ROMs to:
- **PS4 games**: `/mnt/games/ps4`
- **RetroArch ROMs**: `/mnt/games/roms`
- **Saves**: `/mnt/saves/`
