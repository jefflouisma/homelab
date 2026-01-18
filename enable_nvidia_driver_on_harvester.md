# Enabling NVIDIA GPU Drivers on Harvester HCI

Complete guide to configuring NVIDIA GPU passthrough and hardware encoding for Wolf game streaming on Harvester HCI v1.7.

---

## Prerequisites

- Harvester HCI v1.7+ with NVIDIA GPU
- GPU visible in host (`lspci | grep NVIDIA`)
- SSH access to Harvester node

---

## Step 1: Enable nvidia-drm.modeset=1 via grubenv

This is critical for `drmGetDevice` to work in containers.

```bash
# SSH to Harvester
ssh rancher@192.168.1.10

# Add nvidia-drm.modeset=1 to kernel cmdline
sudo grub2-editenv /oem/grubenv set third_party_kernel_args='multipath=off nvidia-drm.modeset=1'

# Verify the change
cat /oem/grubenv
# Should show: third_party_kernel_args=multipath=off nvidia-drm.modeset=1

# Reboot to apply
sudo reboot
```

### Why This Approach Works

Harvester uses COS (Container OS) with an immutable filesystem. Standard approaches fail:

| Approach | Result |
|----------|--------|
| `/etc/modprobe.d/nvidia.conf` | ❌ NVIDIA .run installer uses insmod, bypasses modprobe.d |
| `/oem/*.yaml` kernel_args | ❌ Not processed correctly by Harvester |
| GRUB_CMDLINE_LINUX_DEFAULT | ❌ Not persisted on immutable filesystem |
| **`/oem/grubenv` third_party_kernel_args** | **✅ Works - native Harvester method** |

---

## Step 2: Enable NVIDIA Driver Toolkit Addon

Via Harvester UI or kubectl:

```bash
# Label the node to enable driver deployment
sudo /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml \
  label nodes harvester-barleta sriovgpu.harvesterhci.io/driver-needed=true

# Enable the addon
sudo /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml \
  patch addon -n harvester-system nvidia-driver-toolkit \
  --type=merge -p '{"spec":{"enabled":true,"valuesContent":"image:\n  tag: v1.7-20251222\n  repo: rancher/harvester-nvidia-driver-toolkit\ndriverLocation: \"https://download.nvidia.com/XFree86/Linux-x86_64/580.119.02/NVIDIA-Linux-x86_64-580.119.02.run\"\nfullnameOverride: nvidia-driver-runtime\n"}}'
```

> [!NOTE]
> The driver container (nvidia-driver-runtime) will show CrashLoopBackOff because its entrypoint expects nvidia-vgpud. This is harmless - the driver installs and loads successfully before the container exits.

---

## Step 3: Verify Host Configuration

After reboot and driver load:

```bash
# 1. Check kernel cmdline includes nvidia-drm.modeset=1
cat /proc/cmdline | grep nvidia
# Expected: ... nvidia-drm.modeset=1

# 2. Check nvidia modules are loaded
lsmod | grep nvidia
# Expected:
# nvidia_drm            139264  0
# nvidia_modeset       2265088  1 nvidia_drm
# nvidia              15872000  1 nvidia_modeset

# 3. Check modeset is enabled
sudo cat /sys/module/nvidia_drm/parameters/modeset
# Expected: Y

# 4. Check DRI devices exist
ls -la /dev/dri/
# Expected:
# renderD128 (AMD GPU)
# renderD129 (NVIDIA GPU)

# 5. Check nvidia-smi works
nvidia-smi
```

---

## Step 4: Fenrir Operator Container Configuration

The Fenrir operator creates Wolf pods with the following GPU access:

### Volume Mounts

```yaml
volumes:
  - name: dev
    hostPath:
      path: /dev
      type: Directory
  - name: nvidia-libs
    emptyDir: {}

volumeMounts:
  - name: dev
    mountPath: /dev
  - name: nvidia-libs
    mountPath: /nvidia-libs
```

### Init Container (nvidia-libs-init)

Copies NVIDIA libraries from host to container:

```yaml
initContainers:
  - name: nvidia-libs-init
    image: busybox
    command: ["sh", "-c"]
    args:
      - |
        cp -a /host-usr/lib/x86_64-linux-gnu/libnvidia*.so* /nvidia-libs/ 2>/dev/null || true
        cp -a /host-usr/lib/libnvidia*.so* /nvidia-libs/ 2>/dev/null || true
        cp -a /host-usr/lib64/libnvidia*.so* /nvidia-libs/ 2>/dev/null || true
    volumeMounts:
      - name: host-usr-lib
        mountPath: /host-usr/lib
        readOnly: true
      - name: nvidia-libs
        mountPath: /nvidia-libs
```

### Environment Variables

```yaml
env:
  - name: WOLF_RENDER_NODE
    value: /dev/dri/renderD129  # NVIDIA GPU
  - name: LD_LIBRARY_PATH
    value: /nvidia-libs:/usr/lib/x86_64-linux-gnu
```

### Security Context

```yaml
securityContext:
  privileged: true
  runAsUser: 0
  runAsGroup: 0
  capabilities:
    add: ["SYS_ADMIN"]
```

---

## Step 5: Create Persistent modprobe.d Config (Optional)

For future-proofing, also create a persistent modprobe.d config via OEM:

```bash
sudo tee /oem/99_nvidia.yaml << 'EOF'
name: NVIDIA DRM Modeset Configuration
stages:
    initramfs:
        - files:
            - path: /etc/modprobe.d/nvidia.conf
              permissions: 420
              owner: 0
              group: 0
              content: |
                options nvidia-drm modeset=1
EOF
```

---

## Troubleshooting

### modeset=N after reboot

```bash
# Verify grubenv is correct
cat /oem/grubenv | grep third_party

# If not set, re-apply:
sudo grub2-editenv /oem/grubenv set third_party_kernel_args='multipath=off nvidia-drm.modeset=1'
sudo reboot
```

### nvidia modules not loading

```bash
# Check nvidia-driver-runtime pod
sudo /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml \
  logs -n harvester-system -l app=nvidia-driver-daemonset --tail=50

# Check if driver is being built (takes ~2-3 minutes after boot)
dmesg | grep -i nvidia
```

### drmGetDevice errors in Wolf

```bash
# Verify modeset=Y
sudo cat /sys/module/nvidia_drm/parameters/modeset

# Verify renderD129 exists with correct permissions
ls -la /dev/dri/renderD129

# Check Wolf is mounting /dev correctly
kubectl exec -n house <wolf-pod> -- ls -la /dev/dri/
```

### Container can't find NVIDIA libraries

```bash
# Verify nvidia-libs-init copied libraries
kubectl exec -n house <wolf-pod> -- ls -la /nvidia-libs/

# Check LD_LIBRARY_PATH
kubectl exec -n house <wolf-pod> -- env | grep LD_LIBRARY_PATH
```

---

## GitOps Configuration (Argo CD)

For reproducible NVIDIA setup via Argo CD, deploy the following manifests.

### nvidia-userspace-libs DaemonSet

This DaemonSet installs all NVIDIA user-space libraries to a persistent host path that survives Harvester's immutable filesystem:

**Path:** `barleta/infrastructure/nvidia-userspace-libs.yaml`

```yaml
# Applies via Argo CD: infrastructure app
# Installs 62 NVIDIA libraries + EGL/Vulkan ICD configs
# Target: /var/lib/nvidia-userspace/ on host
```

Key features:
- Downloads and extracts NVIDIA driver 580.119.02
- Copies ALL `.so` files (62 libraries total)
- Creates critical symlinks (libcuda.so, libnvidia-ml.so, etc.)
- Generates EGL vendor ICD (`10_nvidia.json`)
- Generates Vulkan ICD (`nvidia_icd.json`)

### Fenrir Operator Configuration

The operator automatically configures Wolf pods with NVIDIA access:

```yaml
env:
  - name: __EGL_VENDOR_LIBRARY_DIRS
    value: /nvidia-userspace:/usr/share/glvnd/egl_vendor.d
  - name: LD_LIBRARY_PATH
    value: /nvidia-userspace:/nvidia-libs:/usr/local/nvidia/lib:/usr/local/nvidia/lib64:/usr/local/lib
  - name: WOLF_RENDER_NODE
    value: /dev/dri/renderD129

volumeMounts:
  - name: nvidia-userspace
    mountPath: /nvidia-userspace

volumes:
  - name: nvidia-userspace
    hostPath:
      path: /var/lib/nvidia-userspace
      type: DirectoryOrCreate
```

### DRI Permissions Init Container

Wolf pods include an init container to fix DRI device permissions:

```yaml
initContainers:
  - name: dri-permissions
    image: busybox
    command: ["sh", "-c"]
    args:
      - |
        chmod 666 /dev/dri/renderD* 2>/dev/null || true
        chmod 666 /dev/dri/card* 2>/dev/null || true
    securityContext:
      privileged: true
    volumeMounts:
      - name: dev
        mountPath: /dev
```

### Deployment Order

1. **Infrastructure App** → Deploys `nvidia-userspace-libs` DaemonSet
2. **Fenrir Operator** → Deploys with nvidia volume mounts
3. **Session Pods** → Auto-created by operator with full GPU access

---

## Verification Checklist

After GitOps deployment, verify:

```bash
# 1. nvidia-userspace-libs pod completed
kubectl get pods -n kube-system | grep nvidia-userspace

# 2. Libraries installed on host
ls /var/lib/nvidia-userspace/*.so* | wc -l  # Expected: 62+

# 3. EGL/Vulkan ICD files created
ls /var/lib/nvidia-userspace/*.json  # Expected: 10_nvidia.json, nvidia_icd.json

# 4. Wolf detects NVIDIA GPU
kubectl logs -n house <wolf-pod> | grep "Using zero copy pipeline"
# Expected: Using zero copy pipeline on Nvidia (/dev/dri/renderD129)
```

---

## Known Limitations

| Issue | Status | Workaround |
|-------|--------|------------|
| CUDA context warning | Known | Streaming works via non-CUDA fallback |
| DRI permissions reset on reboot | Manual | dri-permissions init container fixes on pod start |
| nvidia-driver-runtime CrashLoopBackOff | Expected | Driver installs before container exits |

---

## Quick Setup Script

For fresh Harvester installation:

```bash
#!/bin/bash
# Enable nvidia-drm.modeset=1 on Harvester HCI

# 1. Set kernel cmdline parameter
sudo grub2-editenv /oem/grubenv set third_party_kernel_args='multipath=off nvidia-drm.modeset=1'

# 2. Create persistent modprobe.d config
sudo tee /oem/99_nvidia.yaml << 'EOF'
name: NVIDIA DRM Modeset Configuration
stages:
    initramfs:
        - files:
            - path: /etc/modprobe.d/nvidia.conf
              permissions: 420
              owner: 0
              group: 0
              content: |
                options nvidia-drm modeset=1
EOF

# 3. Reboot
echo "Configuration complete. Run 'sudo reboot' to apply."
```

---

## References

- [Harvester NVIDIA Driver Toolkit](https://docs.harvesterhci.io/v1.7/advanced/addons/nvidiadrivertoolkit)
- [Harvester Configuration](https://docs.harvesterhci.io/v1.7/install/harvester-configuration)
- [NVIDIA DRM Modesetting](https://wiki.archlinux.org/title/NVIDIA#DRM_kernel_mode_setting)
- [barleta/infrastructure/nvidia-userspace-libs.yaml](file:///Volumes/4TB_Drive/Documents/homelab/barleta/infrastructure/nvidia-userspace-libs.yaml)
