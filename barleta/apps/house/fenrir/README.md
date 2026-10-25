# Fenrir game streaming for Kubernetes

## Overview

Fenrir is a Kubernetes-native adaptation of [Wolf (games-on-whales)](https://games-on-whales.github.io) for multi-user game streaming via Moonlight.

## Components

| Component | Description |
|-----------|-------------|
| `direwolf.games-on-whales.github.io_*.yaml` | Custom Resource Definitions (App, Session, Pairing, User) |
| `wolf-operator.yaml` | Fenrir operator and session image configuration |
| `moonlight-proxy.yaml` | Entry point for Moonlight clients |
| `emudeck-app.yaml` | ES-DE, standalone emulators, and bundled RetroArch cores |
| `cove-app.yaml` | Cove TV interface with Torrentio and persistent per-user settings |
| `storage.yaml` | PVCs for games and saves |
| `packages.yaml` | Independent ES-DE, KytyPS5 and PS5Plus package staging, activation and rollback |

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
   - Select "EmuDeck" for ES-DE; games launch through standalone emulators or its bundled RetroArch cores
   - Select "Cove" for the media app; Torrentio is installed automatically in each new user profile

## ArgoCD Applications

| App | Purpose |
|-----|---------|
| `metallb` | LoadBalancer IP allocation |
| `metallb-config` | IP pool configuration |
| `gateway-api-crds` | Gateway API CRDs |
| `envoy-gateway` | Gateway controller |
| `house` | Fenrir and other applications in the house namespace |

## Container Images

The `fenrir-emudeck.yml` GitHub workflow builds an image after runtime changes to its image directory reach `main`, or on manual dispatch. Test-only and workflow-only changes do not rebuild the image. The workflow publishes a commit-tagged image and updates `emudeck-app.yaml` after a successful push. EmuDeck's image includes RetroArch cores and seeds the shared Dolphin and PPSSPP assets; there is no separate RetroArch application or image workflow.

RetroArch and libretro cores come from the upstream nightly buildbot. DuckStation and RPCS3 use their upstream rolling releases. ES-DE, PCSX2, PPSSPP, and shadPS4 use the explicit upstream release versions in the EmuDeck Dockerfile. Each CI run changes `UPSTREAM_REFRESH` so rolling downloads refresh while dependency layers can remain cached.

For local Moonlight tests, use portable mode so logs, cache, and pairing data respect the temporary-file rule:

```bash
export TMPDIR=/Volumes/4TB_Drive/tmp/
./scripts/moonlight-client.sh stream --1080 --fps 60 --display-mode windowed 192.168.1.221 EmuDeck
```

## Cove and Torrentio

Choose **Cove** in Moonlight on the Fenrir server (`192.168.1.221`). The official [Cove](https://github.com/coveninja/cove) 1.6.0 Linux release runs with its TV shell and real Kotlin backend. Complete or skip the first-run setup; signing in is optional.

The Apple TV Siri Remote works through the stock Moonlight client:

| Remote action | Cove action |
| --- | --- |
| Direction buttons or swipe on the touch surface | Move the highlighted selection |
| Click center | Select the highlighted item, regardless of pointer position |
| Hold center for about 1–2 seconds | Open remote controls; choose **Back** to return to the previous screen |
| Focus a search/text field, hold center, choose **On-screen keyboard** | Enter letters/numbers with the remote; **Done** replaces the field's text; **Cancel** preserves it |

Moonlight reserves the remote's Play/Pause and double Back/Menu presses to disconnect; single Back/Menu is not forwarded. Use Cove's on-screen player controls for playback and the hold-center menu for Back. Arrows, Enter and Escape still work on a keyboard. F8 toggles normal mouse input for desktop clients; set `COVE_REMOTE_INPUT=0` in the Cove container environment to disable the adapter at launch.

`images/cove/remote` builds a small Java launcher alongside the pinned upstream release. `patch-remote-launcher.py` adds it to Cove's launcher classpath, validates the original main class and wraps that entry point without requiring instrumentation modules absent from the bundled Java runtime. It translates only this Cove process's pointer events into its existing TV key controls, hides the pointer, limits swipe repeat and restores relative swipes at screen edges. Recenter acknowledgement tolerates coalesced pointer events and expires after 120 ms, so a dropped event cannot permanently stop swipes. Direction changes discard unused motion from the previous direction. A held click opens a remote-operated Back/text-entry overlay and cannot also activate an item when released. A native init sidecar primes the session with one pixel of relative pointer motion after the Cove window appears, so the first center click works without a swipe. It uses only the pod's private Wolf socket and X11 runtime mounts, with a read-only filesystem and dropped capabilities; it has no profile, host-device or game-storage mounts. It remains idle after initialization. The adapter leaves the player and GPU decoding unchanged; it does not change Wolf, Moonlight, EmuDeck or other sessions' input handling. The `desktop-back.patch` changes wire the previously empty desktop Back handler into the TV root after child controls handle their own Back actions, and allow Up/Down to leave single-line text fields. The small desktop compatibility class is compiled against the bundled Compose ABI; `build-tv-back.py` compiles the two TV sources against that same bundle with hash-verified Kotlin 2.4.10 and upstream sources pinned to commit `1db340a93cdad0e61822fd892f7d178132a54da1`. Gesture tests, UI compatibility compilation, archive checks, and Xvfb interaction checks run in the validation workflow.

The official tarball includes its Java runtime and is checked against its published SHA-256 digest. The image applies the documented `images/cove/video-alpha.patch` compatibility change to Cove 1.6.0: the libmpv software-render target requests opaque BGRA pixels, preventing washed-out video in Compose. GPU decoding remains enabled. `patch-video-alpha.py` applies the equivalent single JVM constant change to the pinned unsigned desktop JAR and fails the build if its layout changes. Corresponding upstream source is [Cove v1.6.0](https://github.com/coveninja/cove/tree/v1.6.0). Xwayland and Openbox bridge Compose Desktop's X11 window to Wolf's Wayland display and maximize it at the negotiated stream resolution. Audio uses the session's PulseAudio sink. The `fenrir-cove.yml` workflow validates the project, publishes a separate image and updates `cove-app.yaml`; it does not rebuild EmuDeck.

Fenrir creates a separate `<user>-cove` PVC and mounts the persistent profile at `/home/retro`. Cove stores its settings, database, library and addon configuration in `/home/retro/.config/cove`. First launch installs the default `https://torrentio.strem.fun/manifest.json` through Cove's loopback API and reads it back before writing a profile marker. Existing Torrentio configurations are preserved, and the marker prevents reinstallation after a user deliberately removes it. Change providers or an optional debrid configuration in Cove's addon settings. No paid-service credentials are bundled.

Cove's loopback API is not exposed by a Kubernetes Service. Its app template does not mount EmuDeck's games, BIOS or shared saves. The Stremio tile, image source and publication workflow have been replaced; old `<user>-stremio` PVCs are retained unchanged rather than deleted or reused as Cove profiles.

## Game Storage

The `fenrir-games` PVC appears at `/Emulation/roms` in EmuDeck. Use the system directories (`ps3`, `ps4`, `psp`, `wii`, and so on). PS3 disc directories should end in `.ps3dir` and contain `PS3_GAME`. PS4 directories must contain `eboot.bin` and `sce_sys/param.sfo`; startup generates named shortcuts that resolve to the actual executable.

The `fenrir-bios` PVC supplies system files. Put a PS3 firmware PUP in `ps3/PS3UPDAT.PUP` and dumped PS4 firmware libraries in `ps4/sys_modules`. Startup installs missing PS3 firmware into the user's persistent profile without opening a GUI. RPCS3 0.0.43 can abort during installer teardown after writing the firmware; the preparation script checks the installed version and required libraries before allowing startup to continue. First PS3 game launches compile shaders and PPU modules, which can take several minutes.

Profiles, configuration, emulator caches, and RPCS3/shadPS4 saves persist on each user's application PVC. EmuDeck's RetroArch cores save to `fenrir-saves/retroarch/saves` and `fenrir-saves/retroarch/states`.

The standalone RetroArch Moonlight application is retired. Existing `<user>-retroarch` profile PVCs and shared save files are retained; retirement does not delete or automatically migrate game progress. Preserve those volumes when cleaning up application resources.

## EmuDeck, KytyPS5 and PS5Plus updates

Open **[Updates](http://192.168.1.221:47989/updates)** from the pairing dashboard. The EmuDeck control updates its ES-DE frontend; KytyPS5 and PS5Plus have separate controls. Other bundled emulators and the base runtime remain managed by the image workflows.

The package manager checks official GitLab ES-DE x64 AppImages, official GitHub KytyPS5 Linux releases and [PS5Plus](https://github.com/jefflouisma/PS5Plus) Linux releases on startup and every six hours. Checks resolve actual release assets and their upstream SHA-256 digests, download and extract into a staging directory, and run a bounded CLI/dependency check. Only verified packages appear as staged. **Check now** performs the same operation immediately. This launch check does not certify a game's compatibility or performance.

The original ES-DE 3.5.0 package is copied from the pinned bootstrap image into the package volume before updates start. Rollback therefore retains its original bytes even when a later container image changes its bundled frontend. Superseded staged packages are removed; the active version, current stage, queue and previous three versions are retained.

Choose **Update** to queue activation. It waits for Session resources and EmuDeck pods, including terminating pods, to disappear; Kubernetes lookup failures pause activation and appear on the page. **Cancel queued update** keeps the installed version. **Roll back** queues a retained version through the same idle-session guard. The active version, staged release, queue and previous three versions persist on `fenrir-packages`; installation directories are immutable and mounted read-only by EmuDeck. A session captures its package selection once at frontend launch. Updates never replace files in a running package. Failed downloads, checks or state transactions preserve the working selection. This runtime-managed state is deliberately separate from GitOps-managed container image versions.

Put extracted PS5 game directories containing `eboot.bin` and `sce_sys/param.json`, or `.zar` game dumps, in `fenrir-games/ps5`. At launch, EmuDeck generates named PS5 entries and invokes `kytyps5` with the negotiated Moonlight width/height and fullscreen presentation. Existing stream, GPU and controller device configuration is reused. These presentation flags do not force a game's internal rendering resolution.

Kyty's writable working directory is `$HOME/.local/share/kytyps5` on the user's persistent EmuDeck profile. Its `_SaveData` and other guest data remain separate from the versioned executable and survive program rollback. Scratch files use `/Volumes/4TB_Drive/tmp/kytyps5`; the package PVC is mounted under `/Volumes/4TB_Drive/tmp/fenrir-packages`, and updater scratch uses the same approved temporary root. The upstream GUI self-updater is not used for these read-only, centrally selected installations.

PS5Plus is a KytyPS5 fork developed on macOS and merged with upstream nightly; its repository describes that workflow. Each push to its `main` publishes a Linux release in the same tarball layout and command-line contract as KytyPS5. It is a separate `ps5plus` component with its own staging, activation and rollback. ES-DE lists the same `fenrir-games/ps5` titles under **Sony PlayStation 5 (PS5Plus)**, launched through `ps5plus`. That launcher shares the KytyPS5 wrapper but selects the PS5Plus package and keeps guest data and saves in `$HOME/.local/share/ps5plus`, with scratch files in `/Volumes/4TB_Drive/tmp/ps5plus`. Experimental builds therefore never touch KytyPS5 saves. Both launchers add the options listed for a game's `titleId` in `images/emudeck/config/title-options` (God of War Ragnarök gets `--tessellation`, which draws its terrain). PS5Plus's `scripts/validate-g913.sh` waits for a release, then stages and queues it through this page's API.

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

The 2026-10-18 resolution rollout reproduced the old 720p cropping and verified full menus and streamed controller navigation at 1280x720, 1920x1080, and 3840x2160 in EmuDeck and the now-retired standalone RetroArch app. At 4K, Street Fighter reached training gameplay with attacks and pause (RPCS3 revision 20334, 300% rendering, window at 0,0 with size 3840x2160). DOA5 reached controller-operated title/play-style menus with FSR enabled; God of War reached a controller-operated title/menu with the PPSSPP core reporting 3840x2160 geometry; Spider-Man rendered its intro/title and responded to Home-menu input with Dolphin configured for 6x EFB. These checks do not certify full gameplay or frame rate for every title. Other cores passed installed-binary option/load checks and scaling regression tests, without game testing where assets were unavailable. The physical Google TV device was not directly tested because network debugging was disabled; these were native Moonlight 6.1.0 sessions against g913.

At that rollout, the final EmuDeck and RetroArch images were `8cfe7a2`, and operator/proxy/agent were `f956543`. Their scaler/core binaries matched the images used for the game checks; those images also passed fresh native launches. The Wolf image remains pinned to the controller-verified `546a17d` digest. Test evidence and screenshots are stored under `/Volumes/4TB_Drive/tmp/fenrir-resolution-20261018/qa.md`.

## Controllers

The EmuDeck template includes g913's host `input` group (GID 996) so the non-root emulator can read Wolf controllers created after the init containers finish. If moving to another host, check `getent group input` and update the supplemental group. Init-time device chmod alone does not cover newly connected controllers.

EmuDeck sets `SDL_JOYSTICK_DISABLE_UDEV=1` to watch the shared `/dev/input` devices directly. Host udev notifications do not cross the pod network namespace. No in-container udev daemon or synthetic hotplug relay is required. Existing controller mappings remain on the user profile PVC.

EmuDeck seeds a missing RPCS3 global `Default.yml` input profile with the SDL handler and `Xbox One S Controller 1`, matching Wolf's streamed Xbox controller. RPCS3 supplies the standard button and axis mappings. Existing global and per-game profiles are preserved. Restart the EmuDeck session to initialize a profile that has no saved RPCS3 pad configuration.

## Host GPU

g913 runs Ubuntu with apt-managed NVIDIA drivers and NVIDIA Container Toolkit. The unused Harvester installer has been retired. Keep the kernel module and userspace NVIDIA package versions aligned. The active device initialization DaemonSet and streaming pod privileges remain required by the tested GPU setup.

Install `scripts/fenrir-modules.conf` as `/etc/modules-load.d/fenrir.conf` on g913 so NVIDIA DRM, UVM, and uinput are available after boot. Verify `nvidia-smi` and `/dev/dri/renderD128` before diagnosing emulator startup failures.
