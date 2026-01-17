# Jellyfin with NVIDIA GPU Support for Harvester

Custom solution for running Jellyfin with NVIDIA GPU transcoding on Harvester HCI's immutable OS.

## Problem

Harvester uses SLE Micro (immutable OS), which prevents installing NVIDIA Container Toolkit. Without the toolkit, containers can't access NVIDIA userspace libraries needed for GPU transcoding.

## Solution

This solution uses an **init container pattern**:
1. Init container extracts NVIDIA libraries from CUDA base image
2. Libraries are stored in a shared emptyDir volume
3. Jellyfin container mounts libraries via `LD_LIBRARY_PATH`
4. GPU devices mounted directly via hostPath

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Jellyfin Pod                                               │
├─────────────────────────────────────────────────────────────┤
│  Init Container (nvidia/cuda)                               │
│  - Copies /usr/local/cuda/lib64/* to /nvidia-libs           │
│  - Copies /usr/lib/x86_64-linux-gnu/libnv* to /nvidia-libs  │
├─────────────────────────────────────────────────────────────┤
│  Jellyfin Container                                         │
│  - LD_LIBRARY_PATH=/nvidia-libs                             │
│  - Mounts /dev/nvidia* from host                            │
│  - Has all NVIDIA libs available                            │
└─────────────────────────────────────────────────────────────┘
```

## Prerequisites

1. NVIDIA driver loaded on Harvester node (via nvidia-driver-toolkit addon)
2. Device nodes created: `/dev/nvidia0`, `/dev/nvidiactl`, `/dev/nvidia-modeset`
3. `sriovgpudevice` enabled for the GPU

## Deployment

```bash
kubectl apply -f jellyfin-deployment.yaml
```

## Verifying GPU Access

```bash
# Check if Jellyfin sees the GPU
kubectl exec -n house deployment/jellyfin -- ls -la /dev/nvidia*

# Check library loading
kubectl exec -n house deployment/jellyfin -- ldconfig -p | grep nvidia
```
