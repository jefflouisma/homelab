#!/usr/bin/env python3
import ctypes as c
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


RESOLUTION_KEYS = {
    "ppsspp": ("ppsspp_internal_resolution",),
    "dolphin": ("dolphin_efb_scale",),
    "pcsx2": ("pcsx2_upscale_multiplier",),
    "mednafen_psx_hw": ("beetle_psx_hw_internal_resolution",),
    "mupen64plus_next": ("mupen64plus-43screensize", "mupen64plus-169screensize"),
    "citra": ("citra_resolution_factor",),
    "flycast": ("reicast_internal_resolution",),
    "melonds": ("melonds_opengl_resolution",),
}


class OptionValue(c.Structure):
    _fields_ = [("value", c.c_char_p), ("label", c.c_char_p)]


class OptionV1(c.Structure):
    _fields_ = [("key", c.c_char_p), ("desc", c.c_char_p), ("info", c.c_char_p),
                ("values", OptionValue * 128), ("default", c.c_char_p)]


class OptionV2(c.Structure):
    _fields_ = [("key", c.c_char_p), ("desc", c.c_char_p), ("desc_category", c.c_char_p),
                ("info", c.c_char_p), ("info_category", c.c_char_p), ("category", c.c_char_p),
                ("values", OptionValue * 128), ("default", c.c_char_p)]


class OptionsV2(c.Structure):
    _fields_ = [("categories", c.c_void_p), ("definitions", c.POINTER(OptionV2))]


class Variable(c.Structure):
    _fields_ = [("key", c.c_char_p), ("value", c.c_char_p)]


def probe(library: Path) -> None:
    options = {}
    system_directory = b""

    @c.CFUNCTYPE(None, c.c_int, c.c_char_p)
    def log_message(level, message):
        print(f"Core log level {level}: {message.decode(errors='replace')}", file=sys.stderr)

    @c.CFUNCTYPE(c.c_bool, c.c_uint, c.c_void_p)
    def environment(command, data):
        if command == 9 and system_directory:
            c.cast(data, c.POINTER(c.c_char_p))[0] = system_directory
            return True
        if command == 27:
            c.cast(data, c.POINTER(c.c_void_p))[0] = c.cast(log_message, c.c_void_p).value
            return True
        if command == 52:
            c.cast(data, c.POINTER(c.c_uint))[0] = 2
            return True
        if command == 39:
            c.cast(data, c.POINTER(c.c_uint))[0] = 0
            return True
        if command in (53, 54, 67, 68):
            if command in (54, 68):
                data = c.cast(data, c.POINTER(c.c_void_p))[0]
            if command in (67, 68):
                definitions = c.cast(data, c.POINTER(OptionsV2)).contents.definitions
            else:
                definitions = c.cast(data, c.POINTER(OptionV1))
            index = 0
            while definitions[index].key:
                item = definitions[index]
                options[item.key.decode()] = [value.value.decode() for value in item.values if value.value]
                index += 1
            return True
        if command == 16:
            variables = c.cast(data, c.POINTER(Variable))
            index = 0
            while variables[index].key:
                item = variables[index]
                options[item.key.decode()] = item.value.decode().split("; ", 1)[-1].split("|")
                index += 1
            return True
        return False

    core = c.CDLL(str(library))
    core.retro_set_environment.argtypes = [type(environment)]
    core.retro_set_environment.restype = None
    core.retro_set_environment(environment)
    if library.name == "pcsx2_libretro.so" and not options:
        scratch = Path(os.environ.get("TMPDIR", "/Volumes/4TB_Drive/tmp")).resolve()
        if not scratch.is_relative_to(Path("/Volumes/4TB_Drive/tmp").resolve()):
            sys.exit("Core option probe TMPDIR must be under /Volumes/4TB_Drive/tmp")
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as directory:
            system_directory = directory.encode()
            core.retro_init.argtypes = []
            core.retro_init.restype = None
            core.retro_init()
        print("PCSX2 options registered during metadata-only retro_init with isolated empty BIOS directory", file=sys.stderr)
    print("CORE_OPTIONS_JSON=" + json.dumps(options))


def collect(directory: Path, destination: Path) -> None:
    schemas = {}
    for core, keys in RESOLUTION_KEYS.items():
        library = directory / f"{core}_libretro.so"
        try:
            result = subprocess.run([sys.executable, __file__, "--core", str(library)],
                                    capture_output=True, text=True, timeout=30, check=False)
        except subprocess.TimeoutExpired:
            sys.exit(f"Core option probe timed out after 30 seconds for {library}")
        if result.returncode:
            sys.exit(f"Core option probe failed for {library}: exit {result.returncode}: {result.stderr}")
        records = [line.removeprefix("CORE_OPTIONS_JSON=") for line in result.stdout.splitlines()
                   if line.startswith("CORE_OPTIONS_JSON=")]
        if len(records) != 1:
            sys.exit(f"Core option probe returned no unique schema for {library}: {result.stdout}")
        options = json.loads(records[0])
        for key in keys:
            if not options.get(key):
                sys.exit(f"Installed core {library} did not advertise expected resolution option {key}")
            schemas[key] = options[key]
    destination.write_text(json.dumps(schemas, indent=2) + "\n")
    print(f"Recorded {len(schemas)} resolution options from {len(RESOLUTION_KEYS)} installed cores")
    for library in sorted(directory.glob("*_libretro.so")):
        if library.name.removesuffix("_libretro.so") not in RESOLUTION_KEYS:
            print(f"{library.name}: fullscreen output scaling; internal scaling not configured")


if __name__ == "__main__":
    if sys.argv[1] == "--core":
        probe(Path(sys.argv[2]))
    else:
        collect(Path(sys.argv[1]), Path(sys.argv[2]))
