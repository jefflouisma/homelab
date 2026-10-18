#!/usr/bin/env python3
import json
import os
from pathlib import Path
import socket
import sys

BUTTONS = {
    "a": 0, "b": 1, "x": 2, "y": 3, "back": 4, "select": 4,
    "guide": 5, "start": 6, "ls": 7, "left_stick": 7,
    "rs": 8, "right_stick": 8, "lb": 9, "left_bumper": 9,
    "rb": 10, "right_bumper": 10, "dpad_up": 11,
    "dpad_down": 12, "dpad_left": 13, "dpad_right": 14,
}
AXES = ("left_stick_x", "left_stick_y", "right_stick_x", "right_stick_y")


def main() -> None:
    request = json.load(sys.stdin)
    directory = Path(os.environ.get(
        "FENRIR_NATIVE_DIR", f"/Volumes/4TB_Drive/tmp/fenrir-native-{os.getuid()}"
    )).resolve()
    if not directory.is_relative_to(Path("/Volumes/4TB_Drive/tmp")):
        raise ValueError("FENRIR_NATIVE_DIR must be under /Volumes/4TB_Drive/tmp/")
    state = json.loads((directory / "session.json").read_text())
    if request.get("host") != state["host"]:
        raise ValueError("Requested host does not match the running native client")
    commands = []
    if request.get("type") != "gamepad":
        raise ValueError("This native provider currently supports gamepad input only")
    if request.get("button") is not None:
        button = BUTTONS[request["button"].lower()]
        action = request.get("button_action") or "tap"
        match action:
            case "tap":
                commands.append(f"tap {button}")
            case "press" | "down":
                commands.append(f"button {button} 1")
            case "release" | "up":
                commands.append(f"button {button} 0")
            case _:
                raise ValueError(f"Unknown button action: {action}")
    for axis, field in enumerate(AXES):
        value = request.get(field)
        if value is not None:
            if type(value) is not int or not -32768 <= value <= 32767:
                raise ValueError(f"Invalid axis value for {field}")
            commands.append(f"axis {axis} {value}")
    for axis, field in ((4, "left_trigger"), (5, "right_trigger")):
        value = request.get(field)
        if value is not None:
            if type(value) is not int or not 0 <= value <= 255:
                raise ValueError(f"Invalid trigger value for {field}")
            commands.append(f"axis {axis} {value * 65535 // 255 - 32768}")
    if not commands:
        raise ValueError("No gamepad input was requested")
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(5)
        client.connect(str(directory / "controller.sock"))
        with client.makefile("rwb", buffering=0) as stream:
            for command in commands:
                stream.write((command + "\n").encode())
                response = json.loads(stream.readline())
                if response.get("acknowledged") is not True:
                    raise RuntimeError(f"Native SDL controller rejected {command}: {response}")
    print(json.dumps({"acknowledged": True}))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, RuntimeError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
