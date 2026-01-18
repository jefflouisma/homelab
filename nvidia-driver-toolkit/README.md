# NVIDIA Driver Toolkit - Unified

A unified container image for managing NVIDIA GPU drivers on Kubernetes, specifically designed for Harvester HCI.

## Features

- **Unified Solution**: Consolidates driver installation, module loading, library extraction, and device creation into one container
- **CUDA Support**: Explicitly loads `nvidia-uvm` module required for CUDA context creation
- **Persistence**: Persists kernel modules and libraries to survive container/pod restarts
- **Hot Reload**: Persisted modules enable fast reload on node reboot

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│           ghcr.io/jefflouisma/nvidia-driver-toolkit             │
├─────────────────────────────────────────────────────────────────┤
│  entrypoint.sh init:                                            │
│  1. Download & install NVIDIA driver                            │
│  2. Build ALL 5 kernel modules                                  │
│  3. Load: nvidia, nvidia-modeset, nvidia-drm, nvidia-uvm        │
│  4. Persist .ko files to /var/lib/nvidia/modules/               │
│  5. Extract userspace libraries to /var/lib/nvidia/lib/         │
│  6. Create device nodes with 666 permissions                    │
│  7. Generate EGL/Vulkan ICD files                               │
└─────────────────────────────────────────────────────────────────┘
```

## Usage

### Kubernetes DaemonSet

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: nvidia-driver-toolkit
  namespace: kube-system
spec:
  selector:
    matchLabels:
      app: nvidia-driver-toolkit
  template:
    spec:
      hostPID: true
      containers:
        - name: nvidia-driver
          image: ghcr.io/jefflouisma/nvidia-driver-toolkit:580.119.02
          securityContext:
            privileged: true
          volumeMounts:
            - name: dev
              mountPath: /dev
            - name: lib-modules
              mountPath: /lib/modules
            - name: nvidia
              mountPath: /var/lib/nvidia
      volumes:
        - name: dev
          hostPath: { path: /dev }
        - name: lib-modules
          hostPath: { path: /lib/modules }
        - name: nvidia
          hostPath:
            path: /var/lib/nvidia
            type: DirectoryOrCreate
```

### Consumer Configuration

Workloads can consume NVIDIA resources via:

```yaml
env:
  - name: LD_LIBRARY_PATH
    value: /var/lib/nvidia/lib:/usr/lib
  - name: __EGL_VENDOR_LIBRARY_DIRS
    value: /var/lib/nvidia/json

volumeMounts:
  - name: nvidia
    mountPath: /var/lib/nvidia
    readOnly: true
  - name: dev
    mountPath: /dev

volumes:
  - name: nvidia
    hostPath:
      path: /var/lib/nvidia
```

## Loaded Modules

| Module | Purpose | Required For |
|--------|---------|--------------|
| nvidia | Core driver | Everything |
| nvidia-modeset | Mode setting | Display output |
| nvidia-drm | DRM integration | Wayland, EGL |
| nvidia-uvm | Unified memory | **CUDA** |
| nvidia-peermem | RDMA | GPU Direct (optional) |

## Verification

```bash
# Check modules
lsmod | grep nvidia

# Check nvidia-uvm specifically (required for CUDA)
lsmod | grep nvidia_uvm

# Check devices
ls -la /dev/nvidia* /dev/nvidia-uvm*

# Check CUDA readiness
nvidia-smi
```

## License

MIT
