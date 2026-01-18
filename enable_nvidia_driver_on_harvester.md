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
