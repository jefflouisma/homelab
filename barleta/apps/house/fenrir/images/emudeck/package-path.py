#!/usr/bin/env python3
import json
import os
from pathlib import Path
import re
import sys
from typing import Final

ROOT: Final = Path("/Volumes/4TB_Drive/tmp/fenrir-packages")
SELECTION: Final = Path("/Volumes/4TB_Drive/tmp/fenrir-session/packages.json")


def main() -> None:
    component = sys.argv[1]
    if component not in {"emudeck", "kytyps5"}:
        sys.exit("Unknown package")
    if len(sys.argv) > 2 and sys.argv[2] == "--pin":
        SELECTION.parent.mkdir(parents=True, exist_ok=True)
        source = ROOT / "state.json"
        SELECTION.write_text(source.read_text() if source.exists() else '{"components":{}}')
    data = json.loads(SELECTION.read_text())
    version = data.get("components", {}).get(component, {}).get("active", "")
    if component == "emudeck" and version in {"", "bundled-3.5.0"}:
        print("/opt/es-de")
        return
    if not isinstance(version, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,100}", version):
        sys.exit("KytyPS5 is not installed. Open Fenrir Updates and activate a verified release.")
    path = ROOT / component / version
    if not (path / ".verified").is_file():
        sys.exit(f"Selected {component} package is unavailable: {version}")
    print(os.fspath(path))


if __name__ == "__main__":
    main()
