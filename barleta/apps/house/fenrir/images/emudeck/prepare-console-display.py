#!/usr/bin/env python3
import configparser
import json
from pathlib import Path


def prepare(home: Path) -> None:
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
        resize="true", resizeManual="true", width="1920", height="1080"
    )
    rpcs3.parent.mkdir(parents=True, exist_ok=True)
    with rpcs3.open("w") as output:
        settings.write(output, space_around_delimiters=False)

    shadps4 = home / ".local/share/shadPS4/config.json"
    config = json.loads(shadps4.read_text()) if shadps4.exists() else {}
    config.setdefault("GPU", {}).update(window_width=1920, window_height=1080)
    shadps4.parent.mkdir(parents=True, exist_ok=True)
    shadps4.write_text(json.dumps(config, indent=2) + "\n")


if __name__ == "__main__":
    prepare(Path.home())
