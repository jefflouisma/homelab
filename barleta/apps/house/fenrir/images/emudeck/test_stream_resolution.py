import configparser
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from emulator_test_support import stage_display_helpers


SOURCE = Path(__file__).parent


class StreamResolutionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.home = Path(self.directory.name)
        self.env = dict(os.environ, HOME=str(self.home), PYTHONDONTWRITEBYTECODE="1")
        self.env.pop("GAMESCOPE_WIDTH", None)
        self.env.pop("GAMESCOPE_HEIGHT", None)
        self.ini = self.home / ".config/rpcs3/GuiConfigs/CurrentSettings.ini"
        self.config = self.home / ".local/share/shadPS4/config.json"
        self.helper = stage_display_helpers(self.home / "bin")

    def prepare(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(self.helper)],
            env=self.env, capture_output=True, text=True, check=False,
        )

    def assert_profiles(self, width: int, height: int) -> None:
        settings = configparser.ConfigParser()
        settings.read(self.ini)
        self.assertEqual(settings.getint("GSFrame", "width"), width)
        self.assertEqual(settings.getint("GSFrame", "height"), height)
        gpu = json.loads(self.config.read_text())["GPU"]
        self.assertEqual((gpu["window_width"], gpu["window_height"]), (width, height))

    def test_profiles_follow_resolution_across_restarts(self) -> None:
        self.ini.parent.mkdir(parents=True)
        self.ini.write_text("[main_window]\ninfoBoxEnabledWelcome=true\n[Meta]\ncustom=keep\n")
        self.config.parent.mkdir(parents=True)
        self.config.write_text('{"GPU":{"vblank_divider":2},"Input":{"custom":"keep"}}')
        for width, height in ((1280, 720), (3840, 2160), (1920, 1080), (1280, 720)):
            with self.subTest(width=width, height=height):
                self.env.update(GAMESCOPE_WIDTH=str(width), GAMESCOPE_HEIGHT=str(height))
                result = self.prepare()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assert_profiles(width, height)
                settings = configparser.ConfigParser()
                settings.read(self.ini)
                self.assertTrue(settings.getboolean("main_window", "infoBoxEnabledWelcome"))
                self.assertEqual(settings["Meta"]["custom"], "keep")
                config = json.loads(self.config.read_text())
                self.assertEqual(config["Input"], {"custom": "keep"})
                self.assertEqual(config["GPU"]["vblank_divider"], 2)

    def test_absent_dimensions_use_1080p(self) -> None:
        result = self.prepare()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_profiles(1920, 1080)

    def test_invalid_dimensions_leave_profiles_unchanged(self) -> None:
        self.assertEqual(self.prepare().returncode, 0)
        before = (self.ini.read_bytes(), self.config.read_bytes())
        for width, height in (("1280", None), (None, "720"), ("", ""), ("0", "720"),
                              ("-1", "720"), ("1280", "bad"), ("1280.0", "720")):
            with self.subTest(width=width, height=height):
                self.env.pop("GAMESCOPE_WIDTH", None)
                self.env.pop("GAMESCOPE_HEIGHT", None)
                if width is not None:
                    self.env["GAMESCOPE_WIDTH"] = width
                if height is not None:
                    self.env["GAMESCOPE_HEIGHT"] = height
                result = self.prepare()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual((self.ini.read_bytes(), self.config.read_bytes()), before)

    def test_es_de_passes_stream_dimensions_to_the_loader(self) -> None:
        # Remap only installed filesystem locations; run the real wrapper and helper.
        install = self.home / "opt/es-de"
        (install / "usr/bin/themes/default").mkdir(parents=True)
        (install / "usr/bin/resources").mkdir()
        loader = self.home / "loader"
        loader.write_text('#!/bin/sh\nprintf "%s\\n" "$@"\n')
        loader.chmod(0o755)
        wrapper = self.home / "launcher.sh"
        wrapper.write_text(
            (SOURCE / "es-de.sh").read_text()
            .replace("/opt/es-de", str(install))
            .replace("/lib64/ld-linux-x86-64.so.2", str(loader))
        )
        self.env["PATH"] = str(self.helper.parent) + os.pathsep + self.env["PATH"]
        for width, height in ((1280, 720), (1920, 1080), (3840, 2160)):
            with self.subTest(width=width, height=height):
                self.env.update(GAMESCOPE_WIDTH=str(width), GAMESCOPE_HEIGHT=str(height))
                result = subprocess.run(
                    ["sh", str(wrapper), "--debug"], env=self.env,
                    capture_output=True, text=True, check=False,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.splitlines()[3:],
                                 ["--resolution", str(width), str(height), "--debug"])
                self.assert_profiles(width, height)


if __name__ == "__main__":
    unittest.main()
