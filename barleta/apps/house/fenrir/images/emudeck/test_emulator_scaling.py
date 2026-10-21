import configparser
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import yaml

from emulator_test_support import CORE_SCHEMA, SOURCE, stage_display_helpers


def read_ini(path: Path) -> configparser.ConfigParser:
    config = configparser.ConfigParser(interpolation=None, strict=False)
    config.optionxform = str
    config.read(path)
    return config


def read_flat(path: Path) -> configparser.SectionProxy:
    config = configparser.ConfigParser(interpolation=None, strict=False)
    config.read_string("[values]\n" + path.read_text())
    return config["values"]


class EmulatorScalingTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.home = Path(self.directory.name)
        self.helper = stage_display_helpers(self.home / "bin")

    def write(self, relative: str, content: str) -> Path:
        path = self.home / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        return path

    def launch(self, dimensions: tuple[int, int]) -> subprocess.CompletedProcess[str]:
        width, height = dimensions
        env = dict(os.environ, HOME=str(self.home), GAMESCOPE_WIDTH=str(width),
                   GAMESCOPE_HEIGHT=str(height), PYTHONDONTWRITEBYTECODE="1")
        return subprocess.run([sys.executable, str(self.helper)], env=env,
                              capture_output=True, text=True, check=False)

    def test_all_emulators_follow_resolution_changes_preserving_custom_settings(self) -> None:
        ps3 = self.write(".config/rpcs3/config.yml", "Video:\n  Aspect ratio: 4:3\n  Resolution Scale: 100\nCore:\n  PPU Decoder: Interpreter\n")
        ps3_game = self.write(".config/rpcs3/custom_configs/config_TEST.yml", "Video:\n  Strict Rendering Mode: true\n  Resolution Scale: 100\n")
        psp = self.write(".config/ppsspp/PSP/SYSTEM/ppsspp.ini", "[Graphics]\nInternalResolution=1\nStretchToDisplay=False\n[Control]\nCustom=keep\n")
        ps2 = self.write(".config/PCSX2/inis/PCSX2.ini", "[EmuCore/GS]\nAspectRatio=4:3\nupscale_multiplier=1\n[Pad1]\nCustom=keep\n")
        ps2_game = self.write(".config/PCSX2/gamesettings/TEST.ini", "[EmuCore/GS]\nupscale_multiplier=1\nUserHacks=true\n")
        ps1 = self.write(".local/share/duckstation/settings.ini", "[GPU]\nResolutionScale=1\n[Display]\nAspectRatio=4:3\n")
        ps4 = self.write(".local/share/shadPS4/config.json", '{"GPU":{"internal_screen_width":1920,"internal_screen_height":1080,"hdr_allowed":false},"Input":{"custom":"keep"}}')
        ps4_game = self.write(".local/share/shadPS4/custom_configs/CUSA00001.json", '{"GPU":{"window_width":1920,"window_height":1080,"fsr_enabled":false,"vblank_frequency":60},"Input":{"custom":"keep"}}')
        ra = self.write(".config/retroarch/retroarch.cfg", 'aspect_ratio_index = "22"\ninput_player1_joypad_index = "3"\n')
        override = self.write(".config/retroarch/config/PPSSPP/Test.opt", 'ppsspp_internal_resolution = "480x272"\nppsspp_cpu_core = "Interpreter"\n')
        cases = [(1280, 720, 100, 3, 2, "1440x816", "2", "960x720"),
                 (1920, 1080, 150, 4, 3, "1920x1088", "3", "1440x1080"),
                 (3840, 2160, 300, 8, 6, "3840x2176", "6", "2880x2160"),
                 (1280, 720, 100, 3, 2, "1440x816", "2", "960x720")]
        for width, height, percent, psp_scale, ps2_scale, psp_core, dolphin, dreamcast in cases:
            with self.subTest(dimensions=(width, height)):
                result = self.launch((width, height))
                self.assertEqual(result.returncode, 0, result.stderr)
                for path in (ps3, ps3_game):
                    self.assertEqual(yaml.safe_load(path.read_text())["Video"]["Resolution Scale"], percent)
                self.assertIn("  Aspect ratio: 4:3\n", ps3.read_text())
                self.assertTrue(yaml.safe_load(ps3_game.read_text())["Video"]["Strict Rendering Mode"])
                self.assertEqual(read_ini(psp).getint("Graphics", "InternalResolution"), psp_scale)
                self.assertEqual(read_ini(psp)["Control"]["Custom"], "keep")
                for path in (ps2, ps2_game):
                    self.assertEqual(read_ini(path).getint("EmuCore/GS", "upscale_multiplier"), ps2_scale)
                self.assertEqual(read_ini(ps2)["EmuCore/GS"]["AspectRatio"], "4:3")
                self.assertTrue(read_ini(ps2_game).getboolean("EmuCore/GS", "UserHacks"))
                self.assertEqual(read_ini(ps1).getint("GPU", "ResolutionScale"), 0)
                self.assertEqual(read_ini(ps1)["Display"]["AspectRatio"], "4:3")
                gpu = json.loads(ps4.read_text())["GPU"]
                self.assertEqual((gpu["window_width"], gpu["window_height"]), (width, height))
                self.assertEqual((gpu["internal_screen_width"], gpu["internal_screen_height"]), (1920, 1080))
                self.assertTrue(gpu["fsr_enabled"])
                self.assertEqual(json.loads(ps4.read_text())["Input"], {"custom": "keep"})
                game_config = json.loads(ps4_game.read_text())
                self.assertEqual(game_config["GPU"], {"window_width": width, "window_height": height, "fsr_enabled": True, "vblank_frequency": 60})
                self.assertEqual(game_config["Input"], {"custom": "keep"})
                self.assertEqual(read_flat(ra)["video_fullscreen_x"], f'"{width}"')
                self.assertEqual(read_flat(ra)["video_fullscreen_y"], f'"{height}"')
                self.assertEqual(read_flat(ra)["aspect_ratio_index"], '"22"')
                self.assertEqual(read_flat(ra)["input_player1_joypad_index"], '"3"')
                options = read_flat(self.home / ".config/retroarch/retroarch-core-options.cfg")
                self.assertEqual(json.loads(options["ppsspp_internal_resolution"]), psp_core)
                self.assertEqual(json.loads(options["dolphin_efb_scale"]), dolphin)
                self.assertEqual(json.loads(options["reicast_internal_resolution"]), dreamcast)
                for key, values in CORE_SCHEMA.items():
                    self.assertIn(json.loads(options[key]), values)
                self.assertEqual(read_flat(override)["ppsspp_internal_resolution"], json.dumps(psp_core))
                self.assertEqual(read_flat(override)["ppsspp_cpu_core"], '"Interpreter"')

    def test_custom_core_options_path_and_new_multiplier_schema_are_used(self) -> None:
        options = self.home / "custom options.cfg"
        self.write(".config/retroarch/retroarch.cfg", f'core_options_path = "{options}"\n')
        schema = dict(CORE_SCHEMA, reicast_internal_resolution=["1x", "2x", "4x", "8x"])
        (self.helper.parent / "core-options.json").write_text(json.dumps(schema))
        result = self.launch((3840, 2160))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(read_flat(options)["reicast_internal_resolution"], '"4x"')
        self.assertFalse((self.home / ".config/retroarch/retroarch-core-options.cfg").exists())

    def test_unknown_schema_fails_before_any_configuration_is_written(self) -> None:
        (self.helper.parent / "core-options.json").write_text('{"ppsspp_internal_resolution":["unrecognized"]}')
        result = self.launch((1280, 720))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.home / ".config").exists())

    def test_retroarch_cli_updates_selected_config_and_saved_overrides_only(self) -> None:
        custom = self.home / "external"
        config = self.write("external/retroarch.cfg", f'core_options_path = "{custom}/options.cfg"\nrgui_config_directory = "{custom}/overrides"\naspect_ratio_index = "22"\n')
        override = self.write("external/overrides/Dolphin/Game.cfg", 'video_fullscreen_x = "1920"\nvideo_fullscreen_y = "1080"\ninput_player1_joypad_index = "3"\n')
        core = self.write("external/overrides/Dolphin/Game.opt", 'dolphin_efb_scale = "1"\ndolphin_cpu_core = "Interpreter"\n')
        for width, height, factor in [(1280, 720, "2"), (1920, 1080, "3"), (3840, 2160, "6")]:
            env = dict(os.environ, HOME=str(self.home), GAMESCOPE_WIDTH=str(width), GAMESCOPE_HEIGHT=str(height))
            result = subprocess.run([sys.executable, str(self.helper.parent / "stream_scaling.py"), "--config", str(config)], env=env, capture_output=True, text=True, check=False)
            self.assertEqual(result.returncode, 0, result.stderr)
            for path in (config, override):
                self.assertEqual(read_flat(path)["video_fullscreen_x"], json.dumps(str(width)))
                self.assertEqual(read_flat(path)["video_fullscreen_y"], json.dumps(str(height)))
            self.assertEqual(read_flat(core)["dolphin_efb_scale"], json.dumps(factor))
            self.assertEqual(read_flat(core)["dolphin_cpu_core"], '"Interpreter"')
            self.assertEqual(read_flat(override)["input_player1_joypad_index"], '"3"')
            self.assertEqual(read_flat(config)["aspect_ratio_index"], '"22"')
            self.assertFalse((self.home / ".config").exists())

    def test_rpcs3_yaml_edits_preserve_unrelated_scalar_text_and_comments(self) -> None:
        samples = [
            ("Video:\n  Aspect ratio: 4:3 # custom\nCore:\n  Flag: off\n", "Video:\n  Aspect ratio: 4:3 # custom\n  Resolution Scale: 300\nCore:\n  Flag: off\n"),
            ("Video: {Aspect ratio: '4:3'}\n", "Video: {Aspect ratio: '4:3', Resolution Scale: 300}\n"),
            ("Video: {}\n", "Video: {Resolution Scale: 300}\n"),
        ]
        for original, expected in samples:
            with self.subTest(original=original):
                path = self.write(".config/rpcs3/config.yml", original)
                result = self.launch((3840, 2160))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(path.read_text(), expected)

    def test_emudeck_retroarch_config_with_duplicate_keys_is_supported(self) -> None:
        template = (SOURCE / "config/retroarch.cfg").read_text()
        config = self.write(".config/retroarch/retroarch.cfg", template + '\nvideo_driver = "vulkan"\n')
        result = self.launch((3840, 2160))
        self.assertEqual(result.returncode, 0, result.stderr)
        settings = read_flat(config)
        self.assertEqual(settings["video_fullscreen_x"], '"3840"')
        self.assertEqual(settings["video_fullscreen_y"], '"2160"')


if __name__ == "__main__":
    unittest.main()
