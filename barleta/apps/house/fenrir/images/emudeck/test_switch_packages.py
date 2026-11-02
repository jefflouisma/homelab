import configparser
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from xml.etree import ElementTree

from emulator_test_support import stage_display_helpers


SOURCE = Path(__file__).parent


class SwitchPackageTests(unittest.TestCase):
    def setUp(self) -> None:
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.emulation = self.root / "Emulation"
        self.home = self.root / "home"
        stage_display_helpers(self.root / "bin")
        packages = self.root / "bin/packages"
        capture = 'printf "%s\\n" "$PWD" "${I_WANT_A_BROKEN_WAYLAND_UI:-}" "$@" > "$CAPTURE"\n'
        for component, executable in (("eden", "AppRun"), ("eglantine", "usr/bin/eden-cli")):
            package = packages / component / "v1"
            (package / executable).parent.mkdir(parents=True)
            (package / ".verified").write_text("digest")
            (package / executable).write_text("#!/bin/sh\n" + capture)
            (package / executable).chmod(0o755)
            launcher = self.root / "bin" / component
            launcher.write_text((SOURCE / "switch.sh").read_text().replace("/Emulation", str(self.emulation)))
            launcher.chmod(0o755)
        (packages / "state.json").write_text(json.dumps({"components": {"eden": {"active": "v1"}, "eglantine": {"active": "v1"}}}))
        subprocess.run([str(self.root / "bin/package-path"), "emudeck", "--pin"], check=True, capture_output=True)

    def launch(self, component: str, game: str) -> list[str]:
        capture = self.root / "args"
        env = dict(os.environ, CAPTURE=str(capture), HOME=str(self.home),
                   PATH=str(self.root / "bin") + os.pathsep + os.environ["PATH"])
        env.pop("I_WANT_A_BROKEN_WAYLAND_UI", None)
        subprocess.run([str(self.root / "bin" / component), game], env=env, check=True)
        return capture.read_text().splitlines()

    def test_eden_runs_portably_with_keys_and_firmware_from_bios(self) -> None:
        bios = self.emulation / "bios/eden"
        (bios / "keys").mkdir(parents=True)
        (bios / "keys/prod.keys").write_text("header_key = 00\n")
        (bios / "firmware").mkdir()
        (bios / "firmware/a.nca").write_text("firmware 1")
        args = self.launch("eden", "/roms/switch/Game [0100000000010000].nsp")
        data = self.home / ".local/share/eden"
        self.assertEqual(args, [str(data), "1", "-f", "-g", "/roms/switch/Game [0100000000010000].nsp"])
        self.assertEqual((data / "user/keys/prod.keys").read_text(), "header_key = 00\n")
        registered = data / "user/nand/system/Contents/registered"
        self.assertEqual((registered / "a.nca").read_text(), "firmware 1")
        # An unchanged dump is not copied again; a new dump replaces the old firmware.
        (registered / "a.nca").write_text("installed")
        self.launch("eden", "game.nsp")
        self.assertEqual((registered / "a.nca").read_text(), "installed")
        (bios / "firmware/a.nca").unlink()
        (bios / "firmware/b.nca").write_text("firmware 2")
        self.launch("eden", "game.nsp")
        self.assertEqual(sorted(path.name for path in registered.iterdir()), ["b.nca"])

    def test_eglantine_keeps_separate_data_and_uses_controllers_set_up_in_eden(self) -> None:
        eden = self.home / ".local/share/eden/user/config/qt-config.ini"
        eden.parent.mkdir(parents=True)
        eden.write_text('[Controls]\nplayer_0_button_a\\default=false\n'
                        'player_0_button_a="engine:sdl,port:0,guid:0300,button:1"\n[UI]\ntheme=dark\n')
        eglantine = self.home / ".local/share/eglantine/user/config/sdl2-config.ini"
        eglantine.parent.mkdir(parents=True)
        eglantine.write_text('[Controls]\nplayer_0_button_a="engine:keyboard,code:4"\n[Renderer]\nbackend=1\n')
        args = self.launch("eglantine", "/roms/switch2/Game.nup")
        self.assertEqual(args, [str(self.home / ".local/share/eglantine"), "", "-f", "-g", "/roms/switch2/Game.nup"])
        config = configparser.RawConfigParser(interpolation=None)
        config.optionxform = str
        config.read(eglantine)
        self.assertEqual(dict(config["Controls"]), {"player_0_button_a\\default": "false",
                                                    "player_0_button_a": '"engine:sdl,port:0,guid:0300,button:1"'})
        self.assertEqual(config["Renderer"]["backend"], "1")
        self.assertFalse(config.has_section("UI"))
        self.assertFalse((self.home / ".local/share/eden/user/keys").exists())

    def test_unactivated_emulator_explains_how_to_install_it(self) -> None:
        packages = self.root / "bin/packages"
        (packages / "state.json").write_text(json.dumps({"components": {}}))
        subprocess.run([str(self.root / "bin/package-path"), "emudeck", "--pin"], check=True, capture_output=True)
        result = subprocess.run([str(self.root / "bin/eden"), "game.nsp"], capture_output=True, text=True,
                                env=dict(os.environ, HOME=str(self.home), PATH=str(self.root / "bin") + os.pathsep + os.environ["PATH"]))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Eden is not installed. Open Fenrir Updates", result.stderr)

    def test_es_de_launches_switch_games_through_the_package_launchers(self) -> None:
        systems = {system.findtext("name"): system for system in
                   ElementTree.parse(SOURCE / "config/custom_systems/es_systems.xml").getroot()}
        self.assertEqual(systems["switch"].findtext("command"), "/usr/local/bin/eden %ROM%")
        self.assertEqual(systems["switch2"].findtext("command"), "/usr/local/bin/eglantine %ROM%")
        self.assertIn(".nup", systems["switch2"].findtext("extension").split())
        dockerfile = (SOURCE / "Dockerfile").read_text()
        for name in ("eden", "eglantine"):
            self.assertIn(f"COPY --chmod=755 switch.sh /usr/local/bin/{name}", dockerfile)


if __name__ == "__main__":
    unittest.main()
