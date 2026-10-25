import fnmatch
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import unittest

import yaml

from emulator_test_support import stage_display_helpers


SOURCE = Path(__file__).parent


class LaunchPathTests(unittest.TestCase):
    def test_streaming_apps_are_published_and_embedded_cores_remain(self) -> None:
        app_directory = SOURCE.parents[1]
        repository = SOURCE.parents[5]
        documents = [document for path in app_directory.glob("*.yaml")
                     for document in yaml.safe_load_all(path.read_text())
                     if isinstance(document, dict)]
        apps = [document["metadata"]["name"] for document in documents
                if document.get("kind") == "App"]
        self.assertCountEqual(apps, ["emudeck", "stremio"])
        configmaps = {document["metadata"]["name"] for document in documents
                      if document.get("kind") == "ConfigMap"}
        self.assertTrue(configmaps.isdisjoint({"retroarch-config", "wolf-session-config"}))
        self.assertFalse((app_directory / "retroarch-apps.yaml").exists())
        self.assertFalse((SOURCE.parent / "retroarch").exists())
        self.assertFalse((repository / ".github/workflows/fenrir-retroarch.yml").exists())
        workflow = (repository / ".github/workflows/fenrir-emudeck.yml").read_text()
        self.assertNotIn("retroarch-apps", workflow)
        dockerfile = (SOURCE / "Dockerfile").read_text()
        for core in ("ppsspp_libretro.so", "dolphin_libretro.so"):
            self.assertIn(core, dockerfile)
        self.assertTrue((SOURCE / "config/retroarch.cfg").is_file())
        self.assertTrue((SOURCE / "autoconfig/sdl2/Wolf_X-Box_One_virtual_pad.cfg").is_file())

    def test_image_build_ignores_test_only_and_workflow_only_changes(self) -> None:
        repository = SOURCE.parents[5]
        workflow_path = ".github/workflows/fenrir-emudeck.yml"
        workflow = yaml.load((repository / workflow_path).read_text(), Loader=yaml.BaseLoader)
        paths = workflow["on"]["push"]["paths"]

        def triggers_build(path: str) -> bool:
            selected = False
            for pattern in paths:
                if fnmatch.fnmatchcase(path, pattern.removeprefix("!")):
                    selected = not pattern.startswith("!")
            return selected

        prefix = "barleta/apps/house/fenrir/images/emudeck/"
        for runtime_file in ("Dockerfile", "startup.sh", "stream_scaling.py", "config/retroarch.cfg"):
            self.assertTrue(triggers_build(prefix + runtime_file), runtime_file)
        for non_runtime in (workflow_path, prefix + "test_launch_paths.py",
                            prefix + "emulator_test_support.py"):
            self.assertFalse(triggers_build(non_runtime), non_runtime)
        self.assertIn("workflow_dispatch", workflow["on"])

    def test_both_launch_paths_use_stream_dimensions(self) -> None:
        manifest = SOURCE.parent.parent / "emudeck-app.yaml"
        if not manifest.exists():
            manifest = SOURCE / "emudeck-app.yaml"
        app = yaml.safe_load(manifest.read_text())
        launches = {
            "manifest": app["spec"]["template"]["spec"]["containers"][0]["command"][2],
            "startup": (SOURCE / "startup.sh").read_text(),
        }
        for name, script in launches.items():
            for width, height in ((1280, 720), (1920, 1080), (3840, 2160)):
                with self.subTest(path=name, width=width, height=height):
                    self.run_launch(script, (width, height))

    def run_launch(self, script: str, dimensions: tuple[int, int]) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            home = root / "home"
            binaries = root / "bin"
            install = root / "opt/es-de"
            config = root / "etc"
            runtime = root / "run"
            for path in (home, binaries, runtime, config / "es-de/custom_systems",
                         install / "usr/bin/resources", install / "usr/bin/themes/default"):
                path.mkdir(parents=True, exist_ok=True)
            (config / "es-de/es_settings.xml").write_text("<settings/>\n")
            (config / "es-de/custom_systems/es_systems.xml").write_text("<systems/>\n")
            (config / "retroarch.cfg").write_text('input_driver = "wayland"\n')
            capture = root / "args.txt"
            loader = binaries / "loader"
            loader.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$CAPTURE_ARGS"\n')
            loader.chmod(0o755)
            for name in ("sleep", "pactl", "sed", "prepare-ps3-firmware", "udevd", "udevadm"):
                stub = binaries / name
                stub.write_text("#!/bin/sh\nexit 0\n")
                stub.chmod(0o755)
            stage_display_helpers(binaries)
            translations = {
                "/home/retro": str(home), "/Emulation": str(root / "Emulation"),
                "/opt/es-de": str(install), "/etc/": str(config) + "/",
                "/lib64/ld-linux-x86-64.so.2": str(loader),
            }
            wrapper = (SOURCE / "es-de.sh").read_text()
            for original, replacement in translations.items():
                script = script.replace(original, replacement)
                wrapper = wrapper.replace(original, replacement)
            launcher = binaries / "es-de"
            launcher.write_text(wrapper)
            launcher.chmod(0o755)
            entrypoint = root / "entrypoint.sh"
            entrypoint.write_text(script)
            width, height = dimensions
            env = dict(os.environ, HOME=str(home), XDG_RUNTIME_DIR=str(runtime),
                       WAYLAND_DISPLAY="wayland-0", CAPTURE_ARGS=str(capture),
                       GAMESCOPE_WIDTH=str(width), GAMESCOPE_HEIGHT=str(height),
                       PATH=str(binaries) + os.pathsep + os.environ["PATH"],
                       PYTHONDONTWRITEBYTECODE="1")
            with socket.socket(socket.AF_UNIX) as wayland, socket.socket(socket.AF_UNIX) as pulse:
                wayland.bind(str(runtime / "wayland-0"))
                pulse.bind(str(runtime / "pulse-socket"))
                result = subprocess.run(["bash", str(entrypoint)], env=env,
                                        capture_output=True, text=True, timeout=10, check=False)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(capture.read_text().splitlines()[3:],
                             ["--resolution", str(width), str(height)])


if __name__ == "__main__":
    unittest.main()
