import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from xml.etree import ElementTree

from emulator_test_support import stage_display_helpers


SOURCE = Path(__file__).parent


class ShadPS4PackageTests(unittest.TestCase):
    def launch(self, root: Path, state: dict, *args: str) -> list[str]:
        stage_display_helpers(root / "bin")
        packages = root / "bin/packages"
        packages.mkdir(exist_ok=True)
        (packages / "state.json").write_text(json.dumps(state))
        subprocess.run([str(root / "bin/package-path"), "emudeck", "--pin"], check=True, capture_output=True)
        capture = root / "args"
        env = dict(os.environ, CAPTURE=str(capture), PATH=str(root / "bin") + os.pathsep + os.environ["PATH"])
        subprocess.run(["sh", str(SOURCE / "shadps4.sh"), *args], env=env, check=True)
        return capture.read_text().splitlines()

    def stage(self, directory: Path) -> None:
        directory.mkdir(parents=True)
        (directory / ".verified").write_text("digest")
        app = directory / "AppRun"
        app.write_text('#!/bin/sh\nprintf "%s\\n" "$PWD" "$LD_LIBRARY_PATH" "$@" > "$CAPTURE"\n')
        app.chmod(0o755)

    def test_launch_uses_the_release_pinned_for_the_session(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for version in ("v.0.21.0", "v.0.22.0"):
                self.stage(root / "bin/packages/shadps4" / version)
            stage_display_helpers(root / "bin")
            (root / "bin/packages/state.json").write_text(json.dumps({"components": {"shadps4": {"active": "v.0.21.0"}}}))
            subprocess.run([str(root / "bin/package-path"), "emudeck", "--pin"], check=True, capture_output=True)
            # Activating another release mid-session must not change the running session's emulator.
            (root / "bin/packages/state.json").write_text(json.dumps({"components": {"shadps4": {"active": "v.0.22.0"}}}))
            capture = root / "args"
            env = dict(os.environ, CAPTURE=str(capture), PATH=str(root / "bin") + os.pathsep + os.environ["PATH"])
            subprocess.run(["sh", str(SOURCE / "shadps4.sh"), "-f", "true", "-g", "/roms/CUSA00001/eboot.bin"],
                           env=env, check=True)
            args = capture.read_text().splitlines()
            package = root / "bin/packages/shadps4/v.0.21.0"
            self.assertEqual(args[0], str(package))
            self.assertTrue(args[1].startswith(str(package / "usr/lib") + ":"))
            self.assertEqual(args[2:], ["-f", "true", "-g", "/roms/CUSA00001/eboot.bin"])

    def test_state_before_shadps4_updates_falls_back_to_the_image_copy(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.stage(root / "opt/shadps4")
            args = self.launch(root, {"components": {"kytyps5": {"active": "daily"}}}, "-g", "game")
            self.assertEqual(args[0], str(root / "opt/shadps4"))
            self.assertEqual(args[2:], ["-g", "game"])

    def test_unverified_release_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            stage_display_helpers(root / "bin")
            (root / "bin/packages/shadps4/v.0.21.0").mkdir(parents=True)
            (root / "bin/packages/state.json").write_text(json.dumps({"components": {"shadps4": {"active": "v.0.21.0"}}}))
            selector = root / "bin/package-path"
            subprocess.run([str(selector), "emudeck", "--pin"], check=True, capture_output=True)
            result = subprocess.run([str(selector), "shadps4"], capture_output=True, text=True, check=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("unavailable", result.stderr)

    def test_es_de_launches_ps4_games_through_the_package_launcher(self) -> None:
        systems = ElementTree.parse(SOURCE / "config/custom_systems/es_systems.xml").getroot()
        command = next(s.findtext("command") for s in systems if s.findtext("name") == "ps4")
        self.assertTrue(command.startswith("/usr/local/bin/shadps4 -f true -g "))
        dockerfile = (SOURCE / "Dockerfile").read_text()
        self.assertIn("COPY --chmod=755 shadps4.sh /usr/local/bin/shadps4", dockerfile)
        self.assertNotIn("> /usr/local/bin/shadps4", dockerfile)


if __name__ == "__main__":
    unittest.main()
