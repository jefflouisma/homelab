import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from emulator_test_support import stage_display_helpers


SOURCE = Path(__file__).parent


class PS5PackageTests(unittest.TestCase):
    def test_malformed_game_metadata_preserves_the_launch_entry(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            game = root / "roms/PPSA12345"
            (game / "sce_sys").mkdir(parents=True)
            (game / "eboot.bin").touch()
            (game / "sce_sys/param.json").write_text("{invalid")
            output = root / "shortcuts"
            result = subprocess.run([sys.executable, str(SOURCE / "generate-ps5-shortcuts.py"),
                                     str(root / "roms"), str(output)], capture_output=True, check=False)
            self.assertEqual(result.returncode, 0)
            self.assertEqual([link.resolve() for link in output.glob("*.ps5")], [game])
            self.assertTrue(result.stderr)

    def test_package_selection_stays_pinned_until_next_session(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            stage_display_helpers(root / "bin")
            packages = root / "bin/packages"
            for version in ("daily1", "daily2"):
                path = packages / "kytyps5" / version
                path.mkdir(parents=True)
                (path / ".verified").write_text("digest")
            state = packages / "state.json"
            state.write_text(json.dumps({"components": {"kytyps5": {"active": "daily1"}}}))
            selector = root / "bin/package-path"
            subprocess.run([str(selector), "emudeck", "--pin"], check=True, capture_output=True)
            state.write_text(json.dumps({"components": {"kytyps5": {"active": "daily2"}}}))
            selected = subprocess.check_output([str(selector), "kytyps5"], text=True).strip()
            self.assertEqual(selected, str(packages / "kytyps5/daily1"))
            subprocess.run([str(selector), "emudeck", "--pin"], check=True, capture_output=True)
            selected = subprocess.check_output([str(selector), "kytyps5"], text=True).strip()
            self.assertEqual(selected, str(packages / "kytyps5/daily2"))

    def test_ps5_shortcuts_support_directories_and_zarchives(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            game = root / "roms/PPSA12345"
            (game / "sce_sys").mkdir(parents=True)
            (game / "eboot.bin").write_bytes(b"fixture")
            (game / "sce_sys/param.json").write_text(json.dumps({
                "localizedParameters": {"en-US": {"titleName": "A Game / Name"}},
            }))
            archive = root / "roms/Second Game.zar"
            archive.write_bytes(b"fixture")
            output = root / "shortcuts"
            subprocess.run([sys.executable, str(SOURCE / "generate-ps5-shortcuts.py"),
                            str(root / "roms"), str(output)], check=True, capture_output=True)
            links = list(output.glob("*.ps5"))
            self.assertEqual({link.resolve() for link in links}, {game, archive})
            self.assertTrue(any(link.name.startswith("A Game _ Name") for link in links))

    def test_kyty_launch_uses_stream_dimensions_and_separate_data(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            stage_display_helpers(root / "bin")
            package = root / "bin/packages/kytyps5/daily"
            package.mkdir(parents=True)
            (package / ".verified").write_text("digest")
            capture = root / "args"
            binary = package / "kyty_emulator"
            binary.write_text('#!/bin/sh\nprintf "%s\\n" "$PWD" "$@" > "$CAPTURE"\n')
            binary.chmod(0o755)
            (root / "bin/packages/state.json").write_text(json.dumps({
                "components": {"kytyps5": {"active": "daily"}},
            }))
            subprocess.run([str(root / "bin/package-path"), "emudeck", "--pin"],
                           check=True, capture_output=True)
            game = root / "A Game.zar"
            game.touch()
            wrapper = root / "kytyps5.sh"
            wrapper.write_text((SOURCE / "kytyps5.sh").read_text().replace(
                "/Volumes/4TB_Drive/tmp/kytyps5", str(root / "runtime"),
            ))
            env = dict(os.environ, HOME=str(root / "profile"), CAPTURE=str(capture),
                       GAMESCOPE_WIDTH="3840", GAMESCOPE_HEIGHT="2160",
                       PATH=str(root / "bin") + os.pathsep + os.environ["PATH"])
            subprocess.run(["sh", str(wrapper), str(game)], env=env, check=True)
            args = capture.read_text().splitlines()
            self.assertEqual(args[0], str(root / "profile/.local/share/kytyps5"))
            self.assertEqual(args[1:8], ["--game", str(game), "--fullscreen",
                                      "--screen-width", "3840", "--screen-height", "2160"])
            self.assertTrue((root / "profile/.local/share/kytyps5/_TempData").is_symlink())


if __name__ == "__main__":
    unittest.main()
