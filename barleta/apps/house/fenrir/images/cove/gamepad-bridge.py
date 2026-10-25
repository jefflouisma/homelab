"""Read this Wolf pod's gamepads and send TV actions to the parent Cove launcher.

stdout is a private action pipe; diagnostics go to stderr. Device ownership comes
from wolf-agent's pre-stream subscription, never a scan of host-wide input nodes.
"""
import json
import os
from pathlib import Path
import re
import selectors
import ssl
import stat
import sys
import time
import urllib.request
import urllib.error

EV_KEY, EV_ABS, EV_SYN = 1, 3, 0
SYN_REPORT, SYN_DROPPED = 0, 3
HAT_X, HAT_Y = 16, 17
BUTTONS = {304: "SELECT", 305: "BACK", 314: "BACK",
           544: "UP", 545: "DOWN", 546: "LEFT", 547: "RIGHT"}
DIRECTIONS = ("UP", "DOWN", "LEFT", "RIGHT")
DEVICE_PATH = re.compile(r"/dev/input/event[0-9]+\Z")


class Actions:
    def __init__(self, emit):
        self.emit = emit
        self.active = set()
        self.blocked = set()
        self.repeat = {}
        self.release_at = None

    def cancel(self, held=()):
        self.emit("CANCEL")
        self.active.clear()
        self.repeat.clear()
        self.release_at = None
        self.blocked = set(held) & {"SELECT", "BACK"}

    def flush_release(self, now):
        if self.release_at is not None and now >= self.release_at:
            self.emit("SELECT_UP")
            self.release_at = None

    def update(self, held, now):
        held = set(held)
        self.blocked.intersection_update(held)
        held.difference_update(self.blocked)
        for pair in ({"UP", "DOWN"}, {"LEFT", "RIGHT"}):
            if pair <= held:
                held.difference_update(pair)
        if "SELECT" in self.active - held:
            # uinput sends a final button-up just before destroying a controller.
            # Stop the hold timer immediately, but confirm device liveness before
            # turning that release into a selection on the next event-loop turn.
            self.emit("SELECT_RELEASE")
            self.release_at = now + .04
        if "SELECT" in held - self.active:
            if self.release_at is not None:
                self.emit("SELECT_UP")
                self.release_at = None
            self.emit("SELECT_DOWN")
        if "BACK" in held - self.active:
            self.release_at = None
            self.emit("CANCEL")
            self.emit("BACK")
        for direction in DIRECTIONS:
            if direction not in held:
                self.repeat.pop(direction, None)
            elif direction not in self.active:
                self.emit(direction)
                self.repeat[direction] = now + .4
            elif now >= self.repeat[direction]:
                self.emit(direction)
                self.repeat[direction] = now + .12
        self.active = held


class PadState:
    def __init__(self):
        self.keys = set()
        self.hats = {HAT_X: 0, HAT_Y: 0}
        self.dropped = False

    def sync(self, device):
        self.keys = set(device.active_keys()) & BUTTONS.keys()
        for code in self.hats:
            try:
                info = device.absinfo(code)
                self.hats[code] = info.value if info else 0
            except OSError:
                self.hats[code] = 0
        self.dropped = False

    def event(self, event, device):
        if event.type == EV_SYN and event.code == SYN_DROPPED:
            self.dropped = True
            return
        if self.dropped:
            if event.type == EV_SYN and event.code == SYN_REPORT:
                self.sync(device)
            return
        if event.type == EV_KEY and event.code in BUTTONS:
            if event.value == 1:
                self.keys.add(event.code)
            elif event.value == 0:
                self.keys.discard(event.code)
        elif event.type == EV_ABS and event.code in self.hats:
            self.hats[event.code] = event.value

    def actions(self):
        result = {BUTTONS[code] for code in self.keys}
        if self.hats[HAT_X] == -1:
            result.add("LEFT")
        elif self.hats[HAT_X] == 1:
            result.add("RIGHT")
        if self.hats[HAT_Y] == -1:
            result.add("UP")
        elif self.hats[HAT_Y] == 1:
            result.add("DOWN")
        return result


def inventory(payload):
    if not isinstance(payload, dict):
        raise ValueError("invalid session device inventory")
    devices = payload.get("devices")
    if not isinstance(devices, list):
        raise ValueError("missing session device inventory")
    result = {}
    for device in devices:
        if not isinstance(device, dict):
            raise ValueError("invalid input device record")
        path = device.get("path", "")
        if not isinstance(path, str) or not DEVICE_PATH.fullmatch(path):
            raise ValueError("invalid input device path")
        if not isinstance(device.get("session_id"), str) or not device["session_id"]:
            raise ValueError("missing device owner")
        for field in ("major", "minor", "generation"):
            if type(device.get(field)) is not int or device[field] < 0:
                raise ValueError("invalid input device identity")
        if device["major"] != 13 or device["generation"] < 1 or path in result:
            raise ValueError("invalid input device identity")
        result[path] = (device["major"], device["minor"], device["generation"])
    return result


def confirm_release(actions, pads, owned, remove, now):
    invalid = {}
    for path in list(pads):
        identity = pads[path][2]
        try:
            if owned.get(path) != identity:
                raise ConnectionError("controller no longer belongs to this stream")
            pads[path][0].active_keys()
        except OSError:
            remove(path)
            invalid[path] = identity
    actions.flush_release(now)
    return invalid


def main():
    from evdev import InputDevice

    # The agent uses a pod-local, self-signed certificate. Never follow redirects
    # or send this request to a client-selected host.
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *args, **kwargs):
            return None
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect(),
                                        urllib.request.HTTPSHandler(context=context))
    selector = selectors.DefaultSelector()
    pads, ignored = {}, {}
    actions = Actions(lambda action: print(action, flush=True))
    next_inventory = next_warning = 0.0

    def load_inventory():
        with opener.open("https://127.0.0.1:8443/input-devices", timeout=1) as response:
            return inventory(json.load(response))

    def held():
        return set().union(*(state.actions() for _, state, _ in pads.values()))

    def remove(path):
        device, _, _ = pads.pop(path)
        selector.unregister(device.fd)
        device.close()
        actions.cancel(held())

    print("Cove gamepad: waiting for session-owned controllers", file=sys.stderr, flush=True)
    try:
        while True:
            now = time.monotonic()
            if now >= next_inventory:
                next_inventory = now + .25
                try:
                    owned = load_inventory()
                    for path in list(pads):
                        if owned.get(path) != pads[path][2]:
                            remove(path)
                    ignored = {path: identity for path, identity in ignored.items() if owned.get(path) == identity}
                    for path, identity in owned.items():
                        if path in pads or ignored.get(path) == identity:
                            continue
                        device = None
                        try:
                            info = Path(path).stat()
                            if not stat.S_ISCHR(info.st_mode) or (os.major(info.st_rdev), os.minor(info.st_rdev)) != identity[:2]:
                                continue
                            device = InputDevice(path)
                            # Verify the descriptor too, closing a node-replacement race.
                            info = os.fstat(device.fd)
                            if (os.major(info.st_rdev), os.minor(info.st_rdev)) != identity[:2]:
                                device.close()
                                continue
                            capabilities = device.capabilities()
                            if 304 not in capabilities.get(EV_KEY, []):
                                device.close()
                                ignored[path] = identity
                                continue
                            state = PadState()
                            state.sync(device)
                            actions.blocked.update(state.actions() & {"SELECT", "BACK"})
                            pads[path] = (device, state, identity)
                            selector.register(device.fd, selectors.EVENT_READ, path)
                            print("Cove gamepad: attached " + path, file=sys.stderr, flush=True)
                        except OSError:
                            if device is not None:
                                device.close()
                except (OSError, ValueError, urllib.error.URLError):
                    for path in list(pads):
                        remove(path)
                    if now >= next_warning:
                        print("Cove gamepad: session inventory unavailable; input suspended", file=sys.stderr, flush=True)
                        next_warning = now + 30
            for key, _ in selector.select(.02):
                path = key.data
                if path not in pads:
                    continue
                device, state, identity = pads[path]
                try:
                    for event in device.read():
                        state.event(event, device)
                        if event.type == EV_SYN and event.code == SYN_REPORT:
                            actions.update(held(), time.monotonic())
                except BlockingIOError:
                    pass
                except OSError:
                    remove(path)
                    ignored[path] = identity
            actions.update(held(), time.monotonic())
            if actions.release_at is not None and time.monotonic() >= actions.release_at:
                try:
                    # Wolf announces unplug before its final button-up, while the
                    # kernel device can linger. Descriptor liveness alone is not
                    # enough to distinguish that release from a deliberate click.
                    owned = load_inventory()
                except (OSError, ValueError, urllib.error.URLError):
                    owned = {}
                ignored.update(confirm_release(actions, pads, owned, remove, time.monotonic()))
    finally:
        actions.cancel()
        for path in list(pads):
            remove(path)


if __name__ == "__main__":
    main()
