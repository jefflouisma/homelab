#!/usr/bin/env python3
import configparser
import json
from pathlib import Path

from stream_scaling import prepare_scaling, stream_dimensions


def prepare(home: Path, dimensions: tuple[int, int] = (1920, 1080)) -> None:
    width, height = dimensions
    # Wolf's compositor can leave fullscreen clients at their initial window size.
    rpcs3 = home / ".config/rpcs3/GuiConfigs/CurrentSettings.ini"
    settings = configparser.ConfigParser(interpolation=None)
    settings.optionxform = str
    if rpcs3.exists():
        settings.read(rpcs3)
    if not settings.has_section("main_window"):
        settings.add_section("main_window")
    for key in (
        "infoBoxEnabledWelcome",
        "infoBoxEnabledInstallPUP",
        "infoBoxEnabledInstallPKG",
        "confirmationBoxExitGame",
        "confirmationBoxBootGame",
    ):
        settings["main_window"].setdefault(key, "false")
    if not settings.has_section("GSFrame"):
        settings.add_section("GSFrame")
    settings["GSFrame"].update(
        resize="true", resizeManual="true", width=str(width), height=str(height)
    )
    rpcs3.parent.mkdir(parents=True, exist_ok=True)
    with rpcs3.open("w") as output:
        settings.write(output, space_around_delimiters=False)

    shadps4 = home / ".local/share/shadPS4/config.json"
    config = json.loads(shadps4.read_text()) if shadps4.exists() else {}
    config.setdefault("GPU", {}).update(window_width=width, window_height=height, fsr_enabled=True)
    shadps4.parent.mkdir(parents=True, exist_ok=True)
    shadps4.write_text(json.dumps(config, indent=2) + "\n")
    for path in (shadps4.parent / "custom_configs").glob("*.json"):
        config = json.loads(path.read_text())
        gpu = config.get("GPU", {})
        for key, value in {"window_width": width, "window_height": height, "fsr_enabled": True}.items():
            if key in gpu:
                gpu[key] = value
        path.write_text(json.dumps(config, indent=2) + "\n")


if __name__ == "__main__":
    dimensions = stream_dimensions()
    prepare_scaling(Path.home(), dimensions)
    prepare(Path.home(), dimensions)
    print(*dimensions)
