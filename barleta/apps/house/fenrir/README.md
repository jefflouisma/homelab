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
| `packages.yaml` | Independent ES-DE and KytyPS5 package staging, activation and rollback |

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

## EmuDeck and KytyPS5 updates

Open **[Updates](http://192.168.1.221:47989/updates)** from the pairing dashboard. The EmuDeck control updates its ES-DE frontend; KytyPS5 has a separate control. Other bundled emulators and the base runtime remain managed by the image workflows.

The package manager checks official GitLab ES-DE x64 AppImages and official GitHub KytyPS5 Linux releases on startup and every six hours. Checks resolve actual release assets and their upstream SHA-256 digests, download and extract into a staging directory, and run a bounded CLI/dependency check. Only verified packages appear as staged. **Check now** performs the same operation immediately. This launch check does not certify a game's compatibility or performance.

The original ES-DE 3.5.0 package is copied from the pinned bootstrap image into the package volume before updates start. Rollback therefore retains its original bytes even when a later container image changes its bundled frontend. Superseded staged packages are removed; the active version, current stage, queue and previous three versions are retained.

Choose **Update** to queue activation. It waits for Session resources and EmuDeck pods, including terminating pods, to disappear; Kubernetes lookup failures pause activation and appear on the page. **Cancel queued update** keeps the installed version. **Roll back** queues a retained version through the same idle-session guard. The active version, staged release, queue and previous three versions persist on `fenrir-packages`; installation directories are immutable and mounted read-only by EmuDeck. A session captures its package selection once at frontend launch. Updates never replace files in a running package. Failed downloads, checks or state transactions preserve the working selection. This runtime-managed state is deliberately separate from GitOps-managed container image versions.

Put extracted PS5 game directories containing `eboot.bin` and `sce_sys/param.json`, or `.zar` game dumps, in `fenrir-games/ps5`. At launch, EmuDeck generates named PS5 entries and invokes `kytyps5` with the negotiated Moonlight width/height and fullscreen presentation. Existing stream, GPU and controller device configuration is reused. These presentation flags do not force a game's internal rendering resolution.

Kyty's writable working directory is `$HOME/.local/share/kytyps5` on the user's persistent EmuDeck profile. Its `_SaveData` and other guest data remain separate from the versioned executable and survive program rollback. Scratch files use `/Volumes/4TB_Drive/tmp/kytyps5`; the package PVC is mounted under `/Volumes/4TB_Drive/tmp/fenrir-packages`, and updater scratch uses the same approved temporary root. The upstream GUI self-updater is not used for these read-only, centrally selected installations.

EmuDeck selects Qt's PulseAudio backend explicitly to match the streaming audio service. RPCS3 build 0.0.43-20344 crashes in Qt Multimedia during game startup when this setting is omitted in this container.

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

The 2026-10-18 resolution rollout reproduced the old 720p cropping and verified full menus and streamed controller navigation at 1280x720, 1920x1080, and 3840x2160 in both EmuDeck and the separate RetroArch app. At 4K, Street Fighter reached training gameplay with attacks and pause (RPCS3 revision 20334, 300% rendering, window at 0,0 with size 3840x2160). DOA5 reached controller-operated title/play-style menus with FSR enabled; God of War reached a controller-operated title/menu with the PPSSPP core reporting 3840x2160 geometry; Spider-Man rendered its intro/title and responded to Home-menu input with Dolphin configured for 6x EFB. These checks do not certify full gameplay or frame rate for every title. Other cores passed installed-binary option/load checks and scaling regression tests, without game testing where assets were unavailable. The physical Google TV device was not directly tested because network debugging was disabled; these were native Moonlight 6.1.0 sessions against g913.

The final EmuDeck and RetroArch images are `8cfe7a2`, and operator/proxy/agent are `f956543`. Their scaler/core binaries match the images used for the game checks; the final images also passed fresh native launches. The Wolf image remains pinned to the controller-verified `546a17d` digest. Test evidence and screenshots are stored under `/Volumes/4TB_Drive/tmp/fenrir-resolution-20261018/qa.md`.

## Controllers

Both app templates include g913's host `input` group (GID 996) so the non-root emulator can read Wolf controllers created after the init containers finish. If moving to another host, check `getent group input` and update the supplemental group. Init-time device chmod alone does not cover newly connected controllers.

The apps set `SDL_JOYSTICK_DISABLE_UDEV=1` to watch the shared `/dev/input` devices directly. Host udev notifications do not cross the pod network namespace. No in-container udev daemon or synthetic hotplug relay is required. Existing controller mappings remain on the user profile PVC.

EmuDeck seeds a missing RPCS3 global `Default.yml` input profile with the SDL handler and `Xbox One S Controller 1`, matching Wolf's streamed Xbox controller. RPCS3 supplies the standard button and axis mappings. Existing global and per-game profiles are preserved. Restart the EmuDeck session to initialize a profile that has no saved RPCS3 pad configuration.

## Host GPU

g913 runs Ubuntu with apt-managed NVIDIA drivers and NVIDIA Container Toolkit. The unused Harvester installer has been retired. Keep the kernel module and userspace NVIDIA package versions aligned. The active device initialization DaemonSet and streaming pod privileges remain required by the tested GPU setup.

Install `scripts/fenrir-modules.conf` as `/etc/modules-load.d/fenrir.conf` on g913 so NVIDIA DRM, UVM, and uinput are available after boot. Verify `nvidia-smi` and `/dev/dri/renderD128` before diagnosing emulator startup failures.
