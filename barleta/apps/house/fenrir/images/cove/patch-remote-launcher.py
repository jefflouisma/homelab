"""Install the TV input bootstrap without requiring java.instrument in Cove's jlink runtime."""
from pathlib import Path
import sys
import zipfile
import hashlib


def patch(installation: Path, jar: str = "/usr/local/lib/fenrir/cove-remote.jar",
          back_class: str = "/usr/local/lib/fenrir/cove-back.class",
          tv_classes: str = "/usr/local/lib/fenrir/cove-tv") -> None:
    config = installation / "lib/app/Cove.cfg"
    text = config.read_text()
    original = "app.mainclass=com.coveninja.cove.desktop.MainKt"
    if text.count(original) != 1 or "games.fenrir.cove" in text:
        raise ValueError("Cove launcher layout changed; inspect before applying the remote bootstrap")
    entry = "com/coveninja/cove/ui/platform/PlaybackBackHandler_desktopKt.class"
    matches = []
    for candidate in (installation / "lib/app").glob("*.jar"):
        with zipfile.ZipFile(candidate) as archive:
            if entry in archive.namelist():
                matches.append(candidate)
    if len(matches) != 1:
        raise ValueError("Expected one desktop Back implementation")
    replacement = Path(back_class).read_bytes()
    if not replacement.startswith(b"\xca\xfe\xba\xbe") or entry.removesuffix(".class").encode() not in replacement:
        raise ValueError("Invalid desktop Back replacement class")
    target = matches[0]
    tv = {str(path.relative_to(tv_classes)): path.read_bytes()
          for path in Path(tv_classes).rglob("*.class")}
    root = "com/coveninja/cove/ui/tv/CoveTvAppKt.class"
    if root not in tv or any(not name.startswith("com/coveninja/cove/ui/tv/") or
                            ("CoveTvAppKt" not in name and "TvTextFieldKt" not in name and "TvPlayerLayerKt" not in name and
                             not name.endswith("/TvBackAction.class")) for name in tv):
        raise ValueError("Expected only the compiled Cove TV root classes")
    replacements = {entry: replacement, **tv}
    staged = target.with_suffix(".remote-tmp")
    with zipfile.ZipFile(target) as source, zipfile.ZipFile(staged, "w") as output:
        if hashlib.sha256(source.read(entry)).hexdigest() != "88843728637e4ace03809393387b1bb5c2fcdcfc61f7c418216959b183e39d17":
            raise ValueError("Desktop Back implementation changed; review the compatibility patch")
        if any(name.upper().endswith((".SF", ".RSA", ".DSA")) for name in source.namelist()):
            raise ValueError("Refusing to modify a signed Cove UI artifact")
        for item in source.infolist():
            if any(part in item.filename for part in ("CoveTvAppKt", "TvTextFieldKt", "TvPlayerLayerKt")) and item.filename not in replacements:
                continue
            output.writestr(item, replacements.pop(item.filename, source.read(item.filename)))
        for name, data in replacements.items():
            output.writestr(name, data)
    with zipfile.ZipFile(staged) as archive:
        if archive.testzip() is not None:
            raise ValueError("Patched Cove UI artifact failed ZIP verification")
    staged.replace(target)
    config.write_text(text.replace(original,
        "app.mainclass=games.fenrir.cove.CoveRemoteLauncher\napp.classpath=" + jar))


if __name__ == "__main__":
    patch(Path(sys.argv[1]), *sys.argv[2:])
