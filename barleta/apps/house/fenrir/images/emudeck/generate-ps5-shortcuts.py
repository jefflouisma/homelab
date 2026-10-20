#!/usr/bin/env python3
import json
from pathlib import Path
import re
import sys


def game_title(metadata: Path, fallback: str) -> str:
    if not metadata.is_file():
        return fallback
    try:
        info = json.loads(metadata.read_text())
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        print(f"Cannot read PS5 title metadata {metadata}: {error}", file=sys.stderr)
        return fallback
    if not isinstance(info, dict):
        print(f"PS5 title metadata is not an object: {metadata}", file=sys.stderr)
        return fallback
    localized = info.get("localizedParameters", {})
    language = localized.get("en-US", {}) if isinstance(localized, dict) else {}
    title = language.get("titleName") if isinstance(language, dict) else None
    title = title or info.get("titleName", fallback)
    return title if isinstance(title, str) else fallback


def main() -> None:
    roms = Path(sys.argv[1])
    output = Path(sys.argv[2])
    output.mkdir(parents=True, exist_ok=True)
    expected: set[str] = set()
    for game in sorted(roms.iterdir()) if roms.exists() else []:
        if game.is_dir() and (game / "eboot.bin").is_file():
            title = game_title(game / "sce_sys/param.json", game.name)
            title = re.sub(r"[/\\\x00-\x1f]", "_", title).strip()[:100] or game.name
        elif game.is_file() and game.suffix.lower() == ".zar":
            title = game.stem
        else:
            continue
        name = f"{title} [{game.stem}].ps5"
        expected.add(name)
        link = output / name
        if link.is_symlink():
            link.unlink()
        link.symlink_to(game.resolve(), target_is_directory=game.is_dir())
    for old in output.glob("*.ps5"):
        if old.is_symlink() and old.name not in expected:
            old.unlink()
    print(f"PS5 shortcuts: {len(expected)} games")


if __name__ == "__main__":
    main()
