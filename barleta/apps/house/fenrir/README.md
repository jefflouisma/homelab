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
   - Select "EmuDeck" for ES-DE or "RetroArch" for the standalone core browser

## ArgoCD Applications

| App | Purpose |
|-----|---------|
| `metallb` | LoadBalancer IP allocation |
| `metallb-config` | IP pool configuration |
| `gateway-api-crds` | Gateway API CRDs |
| `envoy-gateway` | Gateway controller |
| `house` | Fenrir and other applications in the house namespace |

## Container Images

The `fenrir-emudeck.yml` and `fenrir-retroarch.yml` GitHub workflows build images after changes to their image directories reach `main`. Each workflow publishes a commit-tagged image and updates the GitOps manifests after a successful push. EmuDeck's image also seeds the shared Dolphin and PPSSPP assets in both applications.

RetroArch and libretro cores come from the upstream nightly buildbot. DuckStation and RPCS3 use their upstream rolling releases. ES-DE, PCSX2, PPSSPP, and shadPS4 use the explicit upstream release versions in the EmuDeck Dockerfile. Each CI run changes `UPSTREAM_REFRESH` so rolling downloads refresh while dependency layers can remain cached.

For local Moonlight tests, use portable mode so logs, cache, and pairing data respect the temporary-file rule:

```bash
export TMPDIR=/Volumes/4TB_Drive/tmp/
./scripts/moonlight-client.sh stream --1080 --fps 60 --display-mode windowed 192.168.1.221 EmuDeck
```

## Game Storage

The `fenrir-games` PVC appears at `/Emulation/roms` in EmuDeck and `/roms` in RetroArch. Use the system directories (`ps3`, `ps4`, `psp`, `wii`, and so on). PS3 disc directories should end in `.ps3dir` and contain `PS3_GAME`. PS4 directories must contain `eboot.bin` and `sce_sys/param.sfo`; startup generates named shortcuts that resolve to the actual executable.

The `fenrir-bios` PVC supplies system files. Put a PS3 firmware PUP in `ps3/PS3UPDAT.PUP` and dumped PS4 firmware libraries in `ps4/sys_modules`. Startup installs missing PS3 firmware into the user's persistent profile without opening a GUI. RPCS3 0.0.43 can abort during installer teardown after writing the firmware; the preparation script checks the installed version and required libraries before allowing startup to continue. First PS3 game launches compile shaders and PPU modules, which can take several minutes.

Profiles, configuration, and emulator caches persist on each user's application PVC; shared saves persist on `fenrir-saves`.

Console launchers request fullscreen and initialize RPCS3/shadPS4 presentation windows at 1920x1080 to match ES-DE's stream. Wolf can retain the initial window size despite a fullscreen request. This changes window dimensions, preserving internal rendering resolution and other emulator settings.

## Verified Games (2026-10-17)

Real Moonlight sessions on g913 reached gameplay in PS3 Super Street Fighter IV Arcade Edition (RPCS3 0.0.43-20331-73854171), PS4 Dead or Alive 5 Last Round (shadPS4 0.20.0), PSP God of War: Chains of Olympus, and Wii Spider-Man: Edge of Time (upstream RetroArch nightly 1.22.2, b35eb19). PS3 attacks and pause, PS4 menus and pause, PSP attacks and pause, and Wii Nunchuk setup were exercised. PS3 firmware 4.92 and dumped PS4 system modules are installed. Physical controllers and compatibility with other PS3/PS4 games were not verified.

## Controllers

Both app templates include g913's host `input` group (GID 996) so the non-root emulator can read Wolf controllers created after the init containers finish. If moving to another host, check `getent group input` and update the supplemental group. Init-time device chmod alone does not cover newly connected controllers.

The apps set `SDL_JOYSTICK_DISABLE_UDEV=1` to watch the shared `/dev/input` devices directly. Host udev notifications do not cross the pod network namespace. No in-container udev daemon or synthetic hotplug relay is required. Existing controller mappings remain on the user profile PVC.

EmuDeck seeds a missing RPCS3 global `Default.yml` input profile with the SDL handler and `Xbox One S Controller 1`, matching Wolf's streamed Xbox controller. RPCS3 supplies the standard button and axis mappings. Existing global and per-game profiles are preserved. Restart the EmuDeck session to initialize a profile that has no saved RPCS3 pad configuration.

## Host GPU

g913 runs Ubuntu with apt-managed NVIDIA drivers and NVIDIA Container Toolkit. The legacy Harvester installer DaemonSet only schedules on nodes labeled `barleta.local/nvidia-driver-managed-by=harvester`; do not apply that label to g913. Keep the kernel module and userspace NVIDIA package versions aligned.

Install `scripts/fenrir-modules.conf` as `/etc/modules-load.d/fenrir.conf` on g913 so NVIDIA DRM, UVM, and uinput are available after boot. Verify `nvidia-smi` and `/dev/dri/renderD128` before diagnosing emulator startup failures.
