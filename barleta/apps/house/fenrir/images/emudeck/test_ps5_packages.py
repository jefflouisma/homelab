import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from xml.etree import ElementTree

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
        for component in ("kytyps5", "ps5plus"):
            with self.subTest(component=component), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                stage_display_helpers(root / "bin")
                package = root / f"bin/packages/{component}/daily"
                package.mkdir(parents=True)
                (package / ".verified").write_text("digest")
                capture = root / "args"
                binary = package / "kyty_emulator"
                binary.write_text('#!/bin/sh\nprintf "%s\\n" "$PWD" "$@" > "$CAPTURE"\n')
                binary.chmod(0o755)
                (root / "bin/packages/state.json").write_text(json.dumps({
                    "components": {component: {"active": "daily"}},
                }))
                subprocess.run([str(root / "bin/package-path"), "emudeck", "--pin"],
                               check=True, capture_output=True)
                game = root / "A Game.zar"
                game.touch()
                wrapper = root / f"{component}.sh"
                wrapper.write_text((SOURCE / "kytyps5.sh").read_text().replace(
                    "/Volumes/4TB_Drive/tmp/", str(root / "runtime") + "/",
                ))
                env = dict(os.environ, HOME=str(root / "profile"), CAPTURE=str(capture),
                           GAMESCOPE_WIDTH="3840", GAMESCOPE_HEIGHT="2160",
                           PATH=str(root / "bin") + os.pathsep + os.environ["PATH"])
                subprocess.run(["sh", str(wrapper), str(game)], env=env, check=True)
                args = capture.read_text().splitlines()
                self.assertEqual(args[0], str(root / f"profile/.local/share/{component}"))
                self.assertEqual(args[1:8], ["--game", str(game), "--fullscreen",
                                          "--screen-width", "3840", "--screen-height", "2160"])
                self.assertTrue((root / f"profile/.local/share/{component}/_TempData").is_symlink())
                self.assertTrue((root / f"runtime/{component}/logs").is_dir())

    def test_title_options_are_added_for_listed_games_only(self) -> None:
        for title, expected in (("PPSA08332", ["--tessellation"]), ("PPSA00001", [])):
            with self.subTest(title=title), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                stage_display_helpers(root / "bin")
                package = root / "bin/packages/ps5plus/daily"
                package.mkdir(parents=True)
                (package / ".verified").write_text("digest")
                capture = root / "args"
                binary = package / "kyty_emulator"
                binary.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$CAPTURE"\n')
                binary.chmod(0o755)
                (root / "bin/packages/state.json").write_text(json.dumps({
                    "components": {"ps5plus": {"active": "daily"}},
                }))
                subprocess.run([str(root / "bin/package-path"), "emudeck", "--pin"],
                               check=True, capture_output=True)
                game = root / "roms/GAME"
                (game / "sce_sys").mkdir(parents=True)
                (game / "eboot.bin").touch()
                (game / "sce_sys/param.json").write_text(json.dumps({"titleId": title}))
                options = root / "title-options"
                options.write_text((SOURCE / "config/title-options").read_text())
                wrapper = root / "ps5plus.sh"
                wrapper.write_text((SOURCE / "kytyps5.sh").read_text()
                                   .replace("/Volumes/4TB_Drive/tmp/", str(root / "runtime") + "/")
                                   .replace("/etc/kytyps5/title-options", str(options)))
                env = dict(os.environ, HOME=str(root / "profile"), CAPTURE=str(capture),
                           PATH=str(root / "bin") + os.pathsep + os.environ["PATH"])
                subprocess.run(["sh", str(wrapper), str(game)], env=env, check=True)
                args = capture.read_text().splitlines()
                self.assertEqual(args[-len(expected):] if expected else args[-1:],
                                 expected or [str(root / "runtime/ps5plus/logs/guest.txt")])
                self.assertIn("COPY config/title-options /etc/kytyps5/title-options",
                              (SOURCE / "Dockerfile").read_text())

    def test_ps5plus_without_an_active_release_names_itself(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            stage_display_helpers(root / "bin")
            (root / "bin/packages").mkdir()
            (root / "bin/packages/state.json").write_text(json.dumps({
                "components": {"kytyps5": {"active": "daily"}, "ps5plus": {"active": ""}},
            }))
            selector = root / "bin/package-path"
            subprocess.run([str(selector), "emudeck", "--pin"], check=True, capture_output=True)
            result = subprocess.run([str(selector), "ps5plus"], capture_output=True, text=True, check=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("PS5Plus is not installed", result.stderr)

    def test_ps5plus_is_a_separate_es_de_system_for_the_same_games(self) -> None:
        systems = ElementTree.parse(SOURCE / "config/custom_systems/es_systems.xml").getroot()
        commands = {system.findtext("name"): system.findtext("command") for system in systems}
        self.assertEqual(commands["ps5"], "/usr/local/bin/kytyps5 %ROM%")
        self.assertEqual(commands["ps5plus"], "/usr/local/bin/ps5plus %ROM%")
        launcher = (SOURCE / "es-de.sh").read_text()
        for system in ("ps5", "ps5plus"):
            path = next(s.findtext("path") for s in systems if s.findtext("name") == system)
            self.assertIn(f"generate-ps5-shortcuts /Emulation/roms/ps5 {path}", launcher)
        self.assertIn("COPY --chmod=755 kytyps5.sh /usr/local/bin/ps5plus",
                      (SOURCE / "Dockerfile").read_text())

if __name__ == "__main__":
    unittest.main()
