"""Exercise the bundled TV player and desktop remote adapter together in Xvfb."""
import os
from pathlib import Path
import subprocess
import sys
import zipfile

app, output = (Path(value).resolve() for value in sys.argv[1:3])
compiler = output / "compiler/kotlinc"
jars = sorted(app.glob("*.jar"))
ui = []
for path in jars:
    with zipfile.ZipFile(path) as archive:
        if "com/coveninja/cove/ui/tv/player/TvPlayerLayerKt.class" in archive.namelist():
            ui.append(path)
if len(ui) != 1:
    raise ValueError("Expected one bundled TV player")
classes = output / "playback-test"
classes.mkdir(exist_ok=True)
classpath = ":".join(map(str, jars + [output / "cove-remote.jar"]))
env = dict(os.environ)
env["JAVA_TOOL_OPTIONS"] = f"-Djava.io.tmpdir={output} -Dskiko.renderApi=SOFTWARE"
subprocess.run([
    "java", "-cp", str(compiler / "lib/*"), "org.jetbrains.kotlin.cli.jvm.K2JVMCompiler",
    "-no-stdlib", "-no-reflect", "-jvm-target", "21", "-module-name", "ui",
    "-classpath", classpath, "-Xfriend-paths=" + str(ui[0]),
    "-Xplugin=" + str(compiler / "lib/compose-compiler-plugin.jar"),
    "-d", str(classes), str(Path(__file__).parent / "tests/PlaybackControlsTest.kt"),
], check=True, env=env)
env["COVE_REMOTE_INPUT"] = "1"
subprocess.run([
    "xvfb-run", "-a", "java", "-cp",
    ":".join(map(str, [classes, output / "cove-remote.jar", app, app / "*"])),
    "games.fenrir.cove.PlaybackControlsTestKt",
], check=True, timeout=60, env=env)
