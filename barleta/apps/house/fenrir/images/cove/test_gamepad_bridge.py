import importlib.util
from pathlib import Path
from types import SimpleNamespace
import unittest

spec = importlib.util.spec_from_file_location("gamepad_bridge", Path(__file__).with_name("gamepad-bridge.py"))
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


class GamepadBridgeTest(unittest.TestCase):
    def test_remote_hat_and_center_events(self):
        state = bridge.PadState()
        state.event(SimpleNamespace(type=3, code=17, value=-1), None)
        state.event(SimpleNamespace(type=1, code=304, value=1), None)
        self.assertEqual(state.actions(), {"UP", "SELECT"})
        state.event(SimpleNamespace(type=3, code=17, value=0), None)
        state.event(SimpleNamespace(type=1, code=304, value=0), None)
        self.assertEqual(state.actions(), set())

    def test_press_repeat_release_and_reverse(self):
        sent = []
        actions = bridge.Actions(sent.append)
        actions.update({"DOWN"}, 0)
        actions.update({"DOWN"}, .2)
        actions.update({"DOWN"}, .4)
        actions.update({"DOWN"}, .53)
        actions.update({"UP"}, .54)
        actions.update(set(), .55)
        actions.update(set(), 2)
        self.assertEqual(sent, ["DOWN", "DOWN", "DOWN", "UP"])

    def test_select_hold_and_cancellation_never_select_on_disconnect(self):
        sent = []
        actions = bridge.Actions(sent.append)
        actions.update({"SELECT"}, 0)
        actions.update({"SELECT"}, 2)
        self.assertEqual(sent, ["SELECT_DOWN"])
        actions.cancel({"SELECT"})
        actions.update({"SELECT"}, 3)
        actions.update(set(), 4)
        self.assertEqual(sent, ["SELECT_DOWN", "CANCEL"])
        actions.update({"SELECT"}, 5)
        actions.update(set(), 6)
        self.assertEqual(sent[-2:], ["SELECT_DOWN", "SELECT_RELEASE"])
        actions.flush_release(6.05)
        self.assertEqual(sent[-1], "SELECT_UP")

    def test_kernel_disconnect_button_up_is_not_a_click(self):
        sent = []
        actions = bridge.Actions(sent.append)
        actions.update({"SELECT"}, 0)
        actions.update(set(), .1)
        actions.flush_release(.12)
        self.assertNotIn("SELECT_UP", sent)
        actions.cancel()
        actions.flush_release(.2)
        self.assertEqual(sent, ["SELECT_DOWN", "SELECT_RELEASE", "CANCEL"])

    def test_unplugged_device_cannot_select_while_kernel_descriptor_lingers(self):
        path, identity = "/dev/input/event14", (13, 78, 1)
        for owned in ({}, {path: (13, 78, 2)}, {path: identity}):
            with self.subTest(owned=owned):
                sent = []
                actions = bridge.Actions(sent.append)
                actions.update({"SELECT"}, 0)
                actions.update(set(), .1)
                # The regression: the removed uinput device still answers ioctls.
                pads = {path: (SimpleNamespace(active_keys=lambda: []), None, identity)}
                def remove(device_path):
                    pads.pop(device_path)
                    actions.cancel()
                bridge.confirm_release(actions, pads, owned, remove, .2)
                if owned.get(path) == identity:
                    self.assertEqual(sent[-1], "SELECT_UP")
                else:
                    self.assertNotIn("SELECT_UP", sent)
                    self.assertEqual(sent[-1], "CANCEL")

    def test_back_is_not_repeated_and_opposing_directions_cancel(self):
        sent = []
        actions = bridge.Actions(sent.append)
        actions.update({"BACK", "LEFT", "RIGHT"}, 0)
        actions.update({"BACK", "LEFT", "RIGHT"}, 2)
        self.assertEqual(sent, ["CANCEL", "BACK"])

    def test_dropped_evdev_packet_resynchronizes_device_state(self):
        state = bridge.PadState()
        device = SimpleNamespace(active_keys=lambda: [], absinfo=lambda code: SimpleNamespace(value=0))
        state.event(SimpleNamespace(type=1, code=304, value=1), device)
        state.event(SimpleNamespace(type=0, code=3, value=0), device)
        state.event(SimpleNamespace(type=1, code=305, value=1), device)
        self.assertEqual(state.actions(), {"SELECT"})
        state.event(SimpleNamespace(type=0, code=0, value=0), device)
        self.assertEqual(state.actions(), set())

    def test_inventory_is_an_explicit_device_allowlist(self):
        entry = dict(path="/dev/input/event42", session_id="session-a", major=13, minor=106, generation=1)
        self.assertEqual(bridge.inventory({"devices": [entry]}), {"/dev/input/event42": (13, 106, 1)})
        for changes in ({"path": "/dev/input/../event42"}, {"path": "/dev/input/js0"},
                        {"major": 1}, {"minor": True}, {"generation": 0}, {"session_id": ""}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                bridge.inventory({"devices": [entry | changes]})
        with self.assertRaises(ValueError):
            bridge.inventory({"devices": [entry, entry]})


if __name__ == "__main__":
    unittest.main()
