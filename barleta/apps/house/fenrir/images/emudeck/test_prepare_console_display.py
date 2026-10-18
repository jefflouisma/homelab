import configparser
import importlib.util
from pathlib import Path
import tempfile
import unittest


spec = importlib.util.spec_from_file_location(
    "prepare_console_display", Path(__file__).with_name("prepare-console-display.py")
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ConsoleProfileTests(unittest.TestCase):
    def test_fresh_and_partial_profiles_launch_without_welcome(self):
        for initial in ("", "[GSFrame]\nwidth=1280\n[Meta]\nattachCommandLine=false\n"):
            with self.subTest(initial=initial), tempfile.TemporaryDirectory() as directory:
                home = Path(directory)
                ini = home / ".config/rpcs3/GuiConfigs/CurrentSettings.ini"
                ini.parent.mkdir(parents=True)
                ini.write_text(initial)
                module.prepare(home)
                settings = configparser.ConfigParser()
                settings.read(ini)
                self.assertFalse(settings.getboolean("main_window", "infoBoxEnabledWelcome"))
                self.assertEqual(settings.getint("GSFrame", "width"), 1920)
                if initial:
                    self.assertFalse(settings.getboolean("Meta", "attachCommandLine"))
                once = ini.read_text()
                module.prepare(home)
                self.assertEqual(ini.read_text(), once)

    def test_existing_dialog_preferences_and_other_settings_survive(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            ini = home / ".config/rpcs3/GuiConfigs/CurrentSettings.ini"
            ini.parent.mkdir(parents=True)
            ini.write_text(
                "[main_window]\ninfoBoxEnabledWelcome=true\ncustomSetting=keep\n"
                "[Meta]\nattachCommandLine=false\n"
            )
            module.prepare(home)
            settings = configparser.ConfigParser()
            settings.read(ini)
            self.assertTrue(settings.getboolean("main_window", "infoBoxEnabledWelcome"))
            self.assertEqual(settings["main_window"]["customSetting"], "keep")
            self.assertFalse(settings.getboolean("main_window", "confirmationBoxBootGame"))


if __name__ == "__main__":
    unittest.main()
