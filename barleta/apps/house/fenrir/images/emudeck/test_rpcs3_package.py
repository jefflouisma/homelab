import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from emulator_test_support import stage_display_helpers


SOURCE = Path(__file__).parent


class RPCS3PackageTests(unittest.TestCase):
    def stage(self, directory: Path) -> None:
        directory.mkdir(parents=True)
        (directory / ".verified").write_text("digest")
        app = directory / "AppRun"
        app.write_text('#!/bin/sh\nprintf "%s\\n" "$PWD" "$LD_LIBRARY_PATH" "$@" > "$CAPTURE"\n')
        app.chmod(0o755)

    def launch(self, root: Path, *args: str) -> list[str]:
        capture = root / "args"
        env = dict(os.environ, CAPTURE=str(capture), PATH=str(root / "bin") + os.pathsep + os.environ["PATH"])
        subprocess.run(["sh", str(SOURCE / "rpcs3.sh"), *args], env=env, check=True)
        return capture.read_text().splitlines()

    def test_launch_uses_the_build_pinned_for_the_session(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            stage_display_helpers(root / "bin")
            packages = root / "bin/packages"
            for version in ("v0.0.44-20400-1b336f41", "v0.0.44-20401-2c447f52"):
                self.stage(packages / "rpcs3" / version)
            (packages / "state.json").write_text(json.dumps({"components": {"rpcs3": {"active": "v0.0.44-20400-1b336f41"}}}))
            subprocess.run([str(root / "bin/package-path"), "emudeck", "--pin"], check=True, capture_output=True)
            (packages / "state.json").write_text(json.dumps({"components": {"rpcs3": {"active": "v0.0.44-20401-2c447f52"}}}))
            args = self.launch(root, "--no-gui", "--fullscreen", "/roms/ps3/game.ps3")
            package = packages / "rpcs3/v0.0.44-20400-1b336f41"
            self.assertEqual(args[0], str(package))
            self.assertTrue(args[1].startswith(str(package / "usr/lib") + ":"))
            self.assertEqual(args[2:], ["--no-gui", "--fullscreen", "/roms/ps3/game.ps3"])

    def test_firmware_setup_before_es_de_pins_uses_the_live_selection(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            stage_display_helpers(root / "bin")
            self.stage(root / "bin/packages/rpcs3/v0.0.44-20400-1b336f41")
            (root / "bin/packages/state.json").write_text(json.dumps({"components": {"rpcs3": {"active": "v0.0.44-20400-1b336f41"}}}))
            args = self.launch(root, "--headless", "--installfw", "PS3UPDAT.PUP")
            self.assertEqual(args[0], str(root / "bin/packages/rpcs3/v0.0.44-20400-1b336f41"))
            self.assertFalse((root / "bin/selection.json").exists())

    def test_state_before_rpcs3_updates_falls_back_to_the_image_copy(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            stage_display_helpers(root / "bin")
            self.stage(root / "opt/rpcs3")
            args = self.launch(root, "--headless", "--version")
            self.assertEqual(args[0], str(root / "opt/rpcs3"))

    def test_image_installs_the_package_launcher(self) -> None:
        dockerfile = (SOURCE / "Dockerfile").read_text()
        self.assertIn("COPY --chmod=755 rpcs3.sh /usr/local/bin/rpcs3", dockerfile)
        self.assertNotIn("> /usr/local/bin/rpcs3", dockerfile)


if __name__ == "__main__":
    unittest.main()
