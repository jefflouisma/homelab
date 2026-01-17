# Fenrir RetroArch Container

Custom RetroArch container image for the Fenrir game streaming platform.

## Features

- **Base Image**: `gameonwhales/gst-wayland-display` (Wolf-compatible Wayland display)
- **GPU**: NVIDIA/Vulkan support via environment variables
- **Audio**: PulseAudio streaming
- **Controllers**: udev input driver

## Included Cores

| Core | System |
|------|--------|
| beetle-psx-hw | PlayStation |
| mupen64plus-next | Nintendo 64 |
| mgba | Game Boy Advance |
| snes9x | Super Nintendo |
| nestopia | NES |
| desmume | Nintendo DS |
| ppsspp | PSP |
| flycast | Dreamcast |
| bsnes-mercury | Super Nintendo (accuracy) |
| gambatte | Game Boy |
| genesis-plus-gx | Sega Genesis |

## Build

```bash
docker build -t ghcr.io/jefflouisma/fenrir-retroarch:latest .
```

## Run (standalone testing)

```bash
docker run --rm -it \
  --gpus all \
  -e DISPLAY=$DISPLAY \
  -v /tmp/.X11-unix:/tmp/.X11-unix \
  -v /path/to/roms:/roms \
  ghcr.io/jefflouisma/fenrir-retroarch:latest
```

## Directories

| Path | Purpose |
|------|---------|
| `/roms` | ROM files |
| `/roms/system` | BIOS files |
| `/saves` | Save files and states |
| `/screenshots` | Screenshots |
| `/config` | Configuration overrides |
