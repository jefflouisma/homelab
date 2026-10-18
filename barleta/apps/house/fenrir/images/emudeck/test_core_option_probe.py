import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from emulator_test_support import SOURCE


FIXTURE = r"""
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
typedef bool (*environment_t)(unsigned, void *);
struct value { const char *value, *label; };
struct option_v1 { const char *key, *desc, *info; struct value values[128]; const char *def; };
struct option_v2 { const char *key, *desc, *desc_cat, *info, *info_cat, *category; struct value values[128]; const char *def; };
struct options_v2 { const void *categories; const struct option_v2 *definitions; };
struct variable { const char *key, *value; };
static struct option_v1 v1[] = {{"test_resolution", "Resolution", 0, {{"1x", 0}, {"2x", 0}}, "1x"}, {0}};
static struct option_v2 v2[] = {{"test_resolution", "Resolution", 0, 0, 0, "video", {{"1x", 0}, {"2x", 0}}, "1x"}, {0}};
static struct options_v2 options = {0, v2};
static struct variable variables[] = {{"test_resolution", "Resolution; 1x|2x"}, {0}};
static environment_t environment;
void retro_set_environment(environment_t cb) {
    environment = cb;
    unsigned version = 0, language = 99;
    if (!cb(52, &version) || version != 2 || !cb(39, &language) || language != 0) exit(19);
    const void *intl[2];
    switch (MODE) {
        case 16: cb(16, variables); break;
        case 53: cb(53, v1); break;
        case 54: intl[0] = v1; intl[1] = 0; cb(54, intl); break;
        case 67: cb(67, &options); break;
        case 68: intl[0] = &options; intl[1] = 0; cb(68, intl); break;
        case 99: exit(23);
    }
}
void retro_init(void) {
    if (MODE != 100) exit(25);
    const char *directory = 0;
    if (!environment(9, &directory) || !directory || access(directory, F_OK)) exit(26);
    if (strstr(directory, "/Volumes/4TB_Drive/tmp/") != directory) exit(27);
    environment(67, &options);
}
"""


class CoreOptionProbeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.source = self.root / "core.c"
        self.source.write_text(FIXTURE)

    def compile(self, mode: int) -> Path:
        library = self.root / f"core-{mode}.so"
        result = subprocess.run(["cc", "-shared", "-fPIC", f"-DMODE={mode}", str(self.source), "-o", str(library)], capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        return library

    def test_real_library_callbacks_support_legacy_v1_v2_and_international_options(self) -> None:
        for mode in (16, 53, 54, 67, 68):
            with self.subTest(interface=mode):
                library = self.compile(mode)
                result = subprocess.run([sys.executable, str(SOURCE / "probe-core-options.py"), "--core", str(library)], capture_output=True, text=True, check=False, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout.removeprefix("CORE_OPTIONS_JSON=")), {"test_resolution": ["1x", "2x"]})

    def test_missing_expected_option_and_child_failure_stop_schema_publication(self) -> None:
        for mode, message in [(67, "did not advertise expected resolution option ppsspp_internal_resolution"), (99, "exit 23")]:
            with self.subTest(mode=mode):
                library = self.compile(mode)
                target = self.root / "ppsspp_libretro.so"
                if target.exists():
                    target.unlink()
                target.symlink_to(library)
                destination = self.root / "schema.json"
                result = subprocess.run([sys.executable, str(SOURCE / "probe-core-options.py"), str(self.root), str(destination)], capture_output=True, text=True, check=False, timeout=10)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)
                self.assertIn("ppsspp_libretro.so", result.stderr)
                self.assertFalse(destination.exists())

    def test_pcsx2_deferred_options_register_with_isolated_bios_directory(self) -> None:
        library = self.compile(100)
        target = self.root / "pcsx2_libretro.so"
        target.symlink_to(library)
        result = subprocess.run([sys.executable, str(SOURCE / "probe-core-options.py"), "--core", str(target)], capture_output=True, text=True, check=False, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("metadata-only retro_init", result.stderr)
        self.assertEqual(json.loads(result.stdout.removeprefix("CORE_OPTIONS_JSON=")), {"test_resolution": ["1x", "2x"]})

    def test_pcsx2_probe_rejects_unapproved_scratch_directory(self) -> None:
        target = self.root / "pcsx2_libretro.so"
        target.symlink_to(self.compile(100))
        result = subprocess.run([sys.executable, str(SOURCE / "probe-core-options.py"), "--core", str(target)], env=dict(os.environ, TMPDIR="/tmp"), capture_output=True, text=True, check=False, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("TMPDIR must be under /Volumes/4TB_Drive/tmp", result.stderr)


if __name__ == "__main__":
    unittest.main()
