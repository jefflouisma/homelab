# House services

The house stack runs on Ubuntu/k3s on **g913, `192.168.1.10`**. Its manifests are in [apps/house](apps/house/); Argo CD's `house` application deploys that directory recursively.

| Service | Entry point |
| --- | --- |
| Fenrir / Moonlight | `192.168.1.221`; pairing at <http://192.168.1.221:47989/> |
| Jellyfin | `http://jellyfin.barleta.local` |
| Home Assistant | `http://homeassistant.barleta.local` |
| Agent Zero | `http://agent-zero.barleta.local` |
| Mattermost | `http://mattermost.barleta.local` |
| Prowlarr | `http://prowlarr.barleta.local` |

See the [Fenrir guide](apps/house/fenrir/README.md) for streaming/controller behavior and [operations](../docs/operations.md) for deployment, health, and rollback.

GPU containers use the Ubuntu-installed NVIDIA driver and Container Toolkit. Keep their working privileges, GPU library/device mounts, input devices, and supplementary group 996 when changing manifests. `nvidia-device-init.yaml` remains active. Validate real game video and controller input after GPU-related changes.

Home Assistant keeps user configuration on its PVC and uses a `Recreate` strategy. Its proxy init container adds the declared HTTP proxy settings only when no HTTP section exists. It preserves automations, integrations, and an existing HTTP configuration.

Former Harvester instructions are historical and available in Git commit `5a22b7a`. The active host configuration is in `bootstrap/`.
