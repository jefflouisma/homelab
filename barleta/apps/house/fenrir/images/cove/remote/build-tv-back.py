"""Recompile TV input/focus fixes against the exact bundled Compose/Kotlin ABI."""
import hashlib
from pathlib import Path
import subprocess
import sys
import urllib.request
import zipfile


KOTLIN_VERSION = "2.4.10"
COMPILER_SHA256 = "473dd66c7a3ef4b182065b3da670466c1bf2773a9dbb0ed8b33a39fe9d4f876d"
SOURCE_COMMIT = "1db340a93cdad0e61822fd892f7d178132a54da1"
SOURCE_SHA256 = "ab57b9e14590555448737c8bc191e938c2f27c1d244e77546b4d367abe7cb834"
SOURCE_PATH = "app/ui/src/commonMain/kotlin/com/coveninja/cove/ui/tv/CoveTvApp.kt"
FIELD_PATH = "app/ui/src/commonMain/kotlin/com/coveninja/cove/ui/tv/components/TvTextField.kt"
FIELD_SHA256 = "d569ec7fe22d3d3836730374173b7f7bf921aa83f7fc2e744b56c5e21b6e0a50"
PLAYER_PATH = "app/ui/src/commonMain/kotlin/com/coveninja/cove/ui/tv/player/TvPlayerLayer.kt"
PLAYER_SHA256 = "86335956b3344a5797fbb7435b2723c28be3de19630b6f08c5f47f8be5b0f3e2"


def download(url: str, path: Path, digest: str) -> None:
    if not path.exists():
        with urllib.request.urlopen(url, timeout=90) as response, path.open("wb") as output:
            while chunk := response.read(1024 * 1024):
                output.write(chunk)
    if hashlib.sha256(path.read_bytes()).hexdigest() != digest:
        raise ValueError(f"SHA-256 mismatch for {path.name}")


def main() -> None:
    app, output = (Path(value).resolve() for value in sys.argv[1:3])
    output.mkdir(parents=True, exist_ok=True)
    compiler = Path(sys.argv[3]).resolve() if len(sys.argv) > 3 else output / "compiler/kotlinc"
    if len(sys.argv) <= 3:
        archive = output / "kotlin-compiler.zip"
        download(f"https://github.com/JetBrains/kotlin/releases/download/v{KOTLIN_VERSION}/kotlin-compiler-{KOTLIN_VERSION}.zip",
                 archive, COMPILER_SHA256)
        with zipfile.ZipFile(archive) as bundle:
            bundle.extractall(output / "compiler")
    original = output / "CoveTvApp.original.kt"
    download(f"https://raw.githubusercontent.com/coveninja/cove/{SOURCE_COMMIT}/{SOURCE_PATH}", original, SOURCE_SHA256)
    text = original.read_text()
    needle = "Box(modifier = Modifier.fillMaxSize()) {"
    if text.count(needle) != 1:
        raise ValueError("Cove TV root layout changed")
    source = output / "CoveTvApp.kt"
    source.write_text(text.replace(needle, """Box(modifier = Modifier.fillMaxSize().onKeyEvent { event ->
                    event.type == KeyEventType.KeyDown &&
                        tvKeyAction(event.key) == TvKeyAction.Back &&
                        games.fenrir.cove.CoveRemoteLauncher.handleBack()
                }) {"""))
    original_field = output / "TvTextField.original.kt"
    download(f"https://raw.githubusercontent.com/coveninja/cove/{SOURCE_COMMIT}/{FIELD_PATH}", original_field, FIELD_SHA256)
    field_text = original_field.read_text()
    field_needle = "modifier = Modifier.fillMaxWidth(),"
    if field_text.count(field_needle) != 1:
        raise ValueError("Cove TV text field layout changed")
    field = output / "TvTextField.kt"
    field_text = field_text.replace("import androidx.compose.ui.Modifier", """import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.focus.FocusDirection
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.type
import androidx.compose.ui.input.key.onPreviewKeyEvent""")
    field_text = field_text.replace("val interactionSource = remember", "val focusManager = LocalFocusManager.current\n    val interactionSource = remember")
    field.write_text(field_text.replace(field_needle, """modifier = Modifier.fillMaxWidth().onPreviewKeyEvent { event ->
                    if (event.type != KeyEventType.KeyDown) false else when (event.key) {
                        Key.DirectionDown -> focusManager.moveFocus(FocusDirection.Down)
                        Key.DirectionUp -> focusManager.moveFocus(FocusDirection.Up)
                        else -> false
                    }
                },"""))
    original_player = output / "TvPlayerLayer.original.kt"
    download(f"https://raw.githubusercontent.com/coveninja/cove/{SOURCE_COMMIT}/{PLAYER_PATH}", original_player, PLAYER_SHA256)
    player_text = original_player.read_text()
    anchor = "    val dimens = TvTheme.dimens"
    if player_text.count(anchor) != 1:
        raise ValueError("Cove TV player key handler changed")
    player_text = player_text.replace("import androidx.compose.runtime.Composable", """import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.rememberUpdatedState
import java.awt.event.KeyEvent as AwtKeyEvent""")
    player_text = player_text.replace(anchor, """    // Desktop remotes must still reach the active player if a covered page or
    // a video-surface transition has taken Compose focus. Focused transport
    // controls and player panels keep their normal D-pad/activation semantics.
    var remoteFocusPulse by remember { mutableStateOf(0) }
    LaunchedEffect(remoteFocusPulse) {
        if (remoteFocusPulse > 0) {
            withFrameNanos { }
            runCatching { playFocus.requestFocus() }.let { }
        }
    }
    val remoteKey = rememberUpdatedState(java.util.function.IntPredicate { key ->
        if (phase !is PlaybackPhase.Playing || !start.started || panelOpen ||
            (controlsVisible && barHasFocus)) {
            false
        } else when (key) {
            AwtKeyEvent.VK_LEFT, AwtKeyEvent.VK_RIGHT -> {
                activityPulse++
                jump(if (key == AwtKeyEvent.VK_RIGHT) seekStep else -seekStep)
                true
            }
            AwtKeyEvent.VK_ENTER -> { // Short OK pauses/resumes and reveals controls.
                activityPulse++
                host?.togglePause()
                controlsVisible = true
                remoteFocusPulse++
                true
            }
            AwtKeyEvent.VK_UP, AwtKeyEvent.VK_DOWN -> {
                activityPulse++
                controlsVisible = true
                remoteFocusPulse++
                true
            }
            else -> false
        }
    })
    DisposableEffect(session) {
        val remove = games.fenrir.cove.CoveRemoteLauncher.registerPlaybackHandler { key ->
            remoteKey.value.test(key)
        }
        onDispose { remove.run() }
    }

""" + anchor)
    player = output / "TvPlayerLayer.kt"
    player.write_text(player_text)
    classes = output / "tv"
    classes.mkdir(exist_ok=True)
    jars = sorted(app.glob("*.jar"))
    ui = []
    for path in jars:
        with zipfile.ZipFile(path) as archive:
            if "com/coveninja/cove/ui/tv/CoveTvAppKt.class" in archive.namelist():
                ui.append(path)
    if len(ui) != 1:
        raise ValueError("Expected the pinned Cove UI artifact")
    classpath = ":".join(str(path) for path in jars + [output / "cove-remote.jar"])
    subprocess.run([
        "java", "-cp", str(compiler / "lib/*"), "org.jetbrains.kotlin.cli.jvm.K2JVMCompiler",
        "-no-stdlib", "-no-reflect", "-jvm-target", "21", "-module-name", "ui",
        "-classpath", classpath, "-Xfriend-paths=" + str(ui[0]),
        "-Xplugin=" + str(compiler / "lib/compose-compiler-plugin.jar"),
        "-d", str(classes), str(source), str(field), str(player),
    ], check=True)


if __name__ == "__main__":
    main()
