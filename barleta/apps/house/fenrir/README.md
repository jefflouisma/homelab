# Fenrir game streaming for Kubernetes

## Overview

Fenrir is a Kubernetes-native adaptation of [Wolf (games-on-whales)](https://games-on-whales.github.io) for multi-user game streaming via Moonlight.

## Components

| Component | Description |
|-----------|-------------|
| `direwolf.games-on-whales.github.io_*.yaml` | Custom Resource Definitions (App, Session, Pairing, User) |
| `wolf-operator.yaml` | Fenrir operator and session image configuration |
| `moonlight-proxy.yaml` | Entry point for Moonlight clients |
| `retroarch-apps.yaml` | RetroArch game definitions |
| `storage.yaml` | PVCs for games and saves |

## Quick Start (GitOps)

Fenrir is deployed automatically via ArgoCD when manifests are committed.

1. **Commit and push** all Fenrir manifests to `main` branch
2. **ArgoCD syncs automatically** from the explicit application Kustomization. MetalLB allocates the shared streaming address; session traffic does not use Gateway API routes.
3. **Get the IP** for Apple TV:
   ```bash
   make fenrir-ip
   # or
   kubectl get svc moonlight-proxy -n house -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
   ```
4. **Connect from Moonlight**:
   - Open Moonlight on Apple TV
   - Add server by **IP address** (hostname not supported on Apple TV)
   - Open http://192.168.1.221:47989/ on another device and enter the Apple TV's PIN
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

## Stream resolution and scaling

Moonlight's requested stream resolution controls the display, ES-DE menu, emulator windows, and game scaling. A Google TV device's 4K display mode does not set Moonlight's stream resolution: select **3840x2160** in Moonlight's video settings for a 4K stream. The server also accepts 1280x720 and 1920x1080 and configures applications for the requested size.

Quit the running application from Moonlight before changing stream resolution, then launch it again. A resume request with a different resolution, changed encryption keys, or a stopped Wolf stream returns a conflict and leaves the application untouched. The pinned Wolf integration cannot rotate stream keys or restore a stream after disconnect; quit and relaunch in Moonlight instead of retrying a stale resume. Only a matching, confirmed live stream returns a successful resume response.

Games retain their aspect ratio. Emulators with internal resolution controls render at the supported scale nearest the stream size; fixed-resolution games scale their output to fit. RetroArch core choices come from option schemas queried from the installed binaries during image builds. Startup updates the resolution options in existing global and game profiles while preserving controls and unrelated preferences. Higher rendering resolutions increase GPU load; game compatibility and frame rate still depend on the emulator and title.

| Emulator | Automatic scaling |
|----------|-------------------|
| RPCS3 | Internal resolution percentage relative to 720p; 300% for 4K |
| shadPS4 | Stream-sized presentation window and FSR upscale; preserves the guest's display mode |
| PCSX2 | Internal rendering multiplier |
| PPSSPP | Internal rendering multiplier |
| DuckStation | Automatic internal resolution based on the output window |
| RetroArch 3D cores | Supported internal resolution or rendering multiplier from the installed core |
| RetroArch fixed-resolution cores | Fullscreen output scaled to fit the stream |

## Verified Games

Real Moonlight sessions on g913 reached gameplay in PS3 Super Street Fighter IV Arcade Edition (RPCS3 0.0.43), PS4 Dead or Alive 5 Last Round (shadPS4 0.20.0), PSP God of War: Chains of Olympus, and Wii Spider-Man: Edge of Time (upstream RetroArch nightly 1.22.2). PS3 attacks and pause, PS4 menus and pause, PSP attacks and pause, and Wii Nunchuk setup were exercised. The reliability rollout also verified controller navigation with upstream RPCS3 revision 20332-cbfcf1f6 and the pinned Wolf image. PS3 firmware 4.92 and dumped PS4 system modules are installed. Physical controllers and compatibility with other PS3/PS4 games were not verified.

## Controllers

Both app templates include g913's host `input` group (GID 996) so the non-root emulator can read Wolf controllers created after the init containers finish. If moving to another host, check `getent group input` and update the supplemental group. Init-time device chmod alone does not cover newly connected controllers.

The apps set `SDL_JOYSTICK_DISABLE_UDEV=1` to watch the shared `/dev/input` devices directly. Host udev notifications do not cross the pod network namespace. No in-container udev daemon or synthetic hotplug relay is required. Existing controller mappings remain on the user profile PVC.

EmuDeck seeds a missing RPCS3 global `Default.yml` input profile with the SDL handler and `Xbox One S Controller 1`, matching Wolf's streamed Xbox controller. RPCS3 supplies the standard button and axis mappings. Existing global and per-game profiles are preserved. Restart the EmuDeck session to initialize a profile that has no saved RPCS3 pad configuration.

## Host GPU

g913 runs Ubuntu with apt-managed NVIDIA drivers and NVIDIA Container Toolkit. The unused Harvester installer has been retired. Keep the kernel module and userspace NVIDIA package versions aligned. The active device initialization DaemonSet and streaming pod privileges remain required by the tested GPU setup.

Install `scripts/fenrir-modules.conf` as `/etc/modules-load.d/fenrir.conf` on g913 so NVIDIA DRM, UVM, and uinput are available after boot. Verify `nvidia-smi` and `/dev/dri/renderD128` before diagnosing emulator startup failures.
