import json
from pathlib import Path


SOURCE = Path(__file__).parent
CORE_SCHEMA = {
    "ppsspp_internal_resolution": [f"{480 * scale}x{272 * scale}" for scale in range(1, 11)],
    "dolphin_efb_scale": [str(scale) for scale in range(1, 13)],
    "pcsx2_upscale_multiplier": ["1x (Native)", "2x", "4x", "8x"],
    "beetle_psx_hw_internal_resolution": ["1x(native)", "2x", "4x", "8x", "16x"],
    "mupen64plus-43screensize": ["320x240", "960x720", "1440x1080", "2880x2160"],
    "mupen64plus-169screensize": ["640x360", "1280x720", "1920x1080", "3840x2160"],
    "citra_resolution_factor": [str(scale) for scale in range(1, 11)],
    "reicast_internal_resolution": ["640x480", "960x720", "1440x1080", "2880x2160"],
    "melonds_opengl_resolution": [f"{scale}x native ({256 * scale}x{192 * scale})" for scale in range(1, 9)],
}


def stage_display_helpers(directory: Path) -> Path:
    directory.mkdir(parents=True, exist_ok=True)
    helper = directory / "prepare-console-display"
    helper.write_text((SOURCE / "prepare-console-display.py").read_text())
    helper.chmod(0o755)
    schema = directory / "core-options.json"
    schema.write_text(json.dumps(CORE_SCHEMA))
    scaling = SOURCE / "stream_scaling.py"
    if scaling.exists():
        (directory / scaling.name).write_text(
            scaling.read_text().replace("/etc/stream-core-options.json", str(schema))
        )
    return helper
