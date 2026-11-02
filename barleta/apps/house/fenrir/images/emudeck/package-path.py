#!/usr/bin/env python3
import json
import os
from pathlib import Path
import re
import sys
from typing import Final

ROOT: Final = Path("/Volumes/4TB_Drive/tmp/fenrir-packages")
SELECTION: Final = Path("/Volumes/4TB_Drive/tmp/fenrir-session/packages.json")
NAMES: Final = {"emudeck": "EmuDeck", "kytyps5": "KytyPS5", "ps5plus": "PS5Plus", "shadps4": "shadPS4",
                 "rpcs3": "RPCS3", "eden": "Eden", "eglantine": "Eglantine"}
# Package state that predates these components keeps the image's copy.
IMAGE_COPIES: Final = {"shadps4": "/opt/shadps4", "rpcs3": "/opt/rpcs3"}


def main() -> None:
    component = sys.argv[1]
    if component not in NAMES:
        sys.exit("Unknown package")
    if len(sys.argv) > 2 and sys.argv[2] == "--pin":
        SELECTION.parent.mkdir(parents=True, exist_ok=True)
        source = ROOT / "state.json"
        SELECTION.write_text(source.read_text() if source.exists() else '{"components":{}}')
    # Setup that runs before ES-DE pins the session, such as PS3 firmware installation, uses the live selection.
    selection = SELECTION if SELECTION.exists() else ROOT / "state.json"
    data = json.loads(selection.read_text() if selection.exists() else '{"components":{}}')
    version = data.get("components", {}).get(component, {}).get("active", "")
    if component == "emudeck" and version in {"", "bundled-3.5.0"}:
        print("/opt/es-de")
        return
    if component in IMAGE_COPIES and version == "":
        print(IMAGE_COPIES[component])
        return
    if not isinstance(version, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,100}", version):
        sys.exit(f"{NAMES[component]} is not installed. Open Fenrir Updates and activate a verified release.")
    path = ROOT / component / version
    if not (path / ".verified").is_file():
        sys.exit(f"Selected {component} package is unavailable: {version}")
    print(os.fspath(path))


if __name__ == "__main__":
    main()
