import configparser
import json
import os
from collections.abc import Mapping
from pathlib import Path
import re
import sys

import yaml


CORE_BASES = {
    "ppsspp_internal_resolution": (480, 272),
    "dolphin_efb_scale": (640, 360),
    "pcsx2_upscale_multiplier": (640, 360),
    "beetle_psx_hw_internal_resolution": (320, 240),
    "mupen64plus-43screensize": (320, 240),
    "mupen64plus-169screensize": (640, 360),
    "citra_resolution_factor": (400, 240),
    "reicast_internal_resolution": (640, 480),
    "melonds_opengl_resolution": (256, 192),
}


def stream_dimensions() -> tuple[int, int]:
    width = os.environ.get("GAMESCOPE_WIDTH")
    height = os.environ.get("GAMESCOPE_HEIGHT")
    if width is None and height is None:
        return 1920, 1080
    if width is None or height is None or not all(
        re.fullmatch(r"[0-9]+", value) and int(value) > 0
        for value in (width, height)
    ):
        sys.exit("GAMESCOPE_WIDTH and GAMESCOPE_HEIGHT must both be positive integers")
    return int(width), int(height)


def update_ini(path: Path, changes: Mapping[str, Mapping[str, str]], existing_only: bool = False) -> None:
    config = configparser.ConfigParser(interpolation=None)
    config.optionxform = str
    if path.exists():
        config.read(path)
    for section, values in changes.items():
        if not config.has_section(section):
            if existing_only:
                continue
            config.add_section(section)
        for key, value in values.items():
            if not existing_only or key in config[section]:
                config[section][key] = value
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w") as output:
        config.write(output, space_around_delimiters=False)


def update_flat(path: Path, changes: Mapping[str, str], existing_only: bool = False) -> None:
    pending = dict(changes)
    lines = path.read_text().splitlines() if path.exists() else []
    for index, line in enumerate(lines):
        key = line.partition("=")[0].strip()
        if key in changes:
            lines[index] = f"{key} = {json.dumps(changes[key])}"
            pending.pop(key, None)
    if not existing_only:
        lines.extend(f"{key} = {json.dumps(value)}" for key, value in pending.items())
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n")


def core_values(schema: Mapping[str, list[str]], dimensions: tuple[int, int]) -> Mapping[str, str]:
    width, height = dimensions
    selected = {}
    for key, (base_width, base_height) in CORE_BASES.items():
        target = min(width / base_width, height / base_height)
        choices = []
        for value in schema[key]:
            pixels = re.fullmatch(r"(\d+)x(\d+)", value)
            factor = re.match(r"^(\d+)(?:x|$)", value)
            if pixels:
                scale = int(pixels[2]) / base_height
            elif factor:
                scale = int(factor[1])
            else:
                continue
            if scale > 0:
                choices.append((abs(scale - target), scale, value))
        if not choices:
            raise RuntimeError(f"No numeric resolution values advertised for {key}")
        selected[key] = min(choices)[2]
    return selected


def prepare_scaling(home: Path, dimensions: tuple[int, int],
                    schema_path: Path = Path("/etc/stream-core-options.json")) -> None:
    width, height = dimensions
    prepare_retroarch(home, dimensions, schema_path)
    percent = max(100, min(800, round(min(width / 1280, height / 720) * 100)))
    rpcs3 = home / ".config/rpcs3"
    for path in [rpcs3 / "config.yml", *sorted((rpcs3 / "custom_configs").glob("*.yml"))]:
        update_rpcs3_scale(path, percent)

    psp_scale = max(1, min(10, round(min(width / 480, height / 272))))
    psp = home / ".config/ppsspp/PSP/SYSTEM"
    psp_changes = {"Graphics": {"InternalResolution": str(psp_scale)}}
    update_ini(psp / "ppsspp.ini", psp_changes)
    for path in psp.glob("*_ppsspp.ini"):
        update_ini(path, psp_changes, existing_only=True)

    ps2_scale = max(1, min(12, round(min(width / 640, height / 360))))
    ps2 = home / ".config/PCSX2"
    ps2_changes = {"EmuCore/GS": {"upscale_multiplier": str(ps2_scale)}}
    update_ini(ps2 / "inis/PCSX2.ini", ps2_changes)
    for path in (ps2 / "gamesettings").glob("*.ini"):
        update_ini(path, ps2_changes, existing_only=True)

    ps1 = home / ".local/share/duckstation"
    ps1_changes = {"GPU": {"ResolutionScale": "0"}}
    update_ini(ps1 / "settings.ini", ps1_changes)
    for path in (ps1 / "gamesettings").glob("*.ini"):
        update_ini(path, ps1_changes, existing_only=True)


def update_rpcs3_scale(path: Path, percent: int) -> None:
    source = path.read_text() if path.exists() else ""
    root = yaml.compose(source, Loader=yaml.BaseLoader)
    video = next((value for key, value in root.value if key.value == "Video"), None) if root else None
    if video is None:
        source = source.rstrip() + f"\nVideo:\n  Resolution Scale: {percent}\n"
    else:
        scale = next((value for key, value in video.value if key.value == "Resolution Scale"), None)
        if scale is not None:
            source = source[:scale.start_mark.index] + str(percent) + source[scale.end_mark.index:]
        elif video.flow_style:
            offset = video.end_mark.index - 1
            source = source[:offset] + (", " if video.value else "") + f"Resolution Scale: {percent}" + source[offset:]
        else:
            offset = video.end_mark.index
            indent = video.value[0][0].start_mark.column if video.value else 2
            source = source[:offset] + " " * indent + f"Resolution Scale: {percent}\n" + source[offset:]
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(source)


def prepare_retroarch(home: Path, dimensions: tuple[int, int],
                      schema_path: Path = Path("/etc/stream-core-options.json"),
                      config_path: Path | None = None) -> None:
    width, height = dimensions
    selected = core_values(json.loads(schema_path.read_text()), dimensions)
    retroarch = home / ".config/retroarch"
    config_path = config_path or retroarch / "retroarch.cfg"
    output = {
        "video_fullscreen": "true", "video_windowed_fullscreen": "true",
        "video_fullscreen_x": str(width), "video_fullscreen_y": str(height),
        "video_scale_integer": "false",
    }
    update_flat(config_path, output)
    options = config_path.parent / "retroarch-core-options.cfg"
    settings = configparser.ConfigParser(interpolation=None, strict=False)
    settings.read_string("[settings]\n" + config_path.read_text())
    configured_path = settings["settings"].get("core_options_path", '""').strip('"')
    if configured_path and configured_path != "default":
        options = Path(configured_path.replace("~/", str(home) + "/", 1))
    update_flat(options, selected)
    override_dir = settings["settings"].get("rgui_config_directory", '""').strip('"')
    directories = {retroarch / "config", config_path.parent / "config"}
    if override_dir and override_dir != "default":
        directories.add(Path(override_dir.replace("~/", str(home) + "/", 1)))
    for directory in directories:
        for path in directory.rglob("*.opt"):
            update_flat(path, selected, existing_only=True)
        for path in directory.rglob("*.cfg"):
            update_flat(path, output, existing_only=True)


if __name__ == "__main__":
    config = None
    if len(sys.argv) > 1:
        if len(sys.argv) != 3 or sys.argv[1] != "--config":
            sys.exit("Usage: stream_scaling.py [--config path]")
        config = Path(sys.argv[2])
    prepare_retroarch(Path.home(), stream_dimensions(), config_path=config)
