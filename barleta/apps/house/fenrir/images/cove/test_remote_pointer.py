import importlib.util
from pathlib import Path
import struct
import unittest


spec = importlib.util.spec_from_file_location("remote_pointer", Path(__file__).with_name("init-remote-pointer.py"))
pointer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pointer)


class RemotePointerTests(unittest.TestCase):
    def test_initializes_only_the_single_local_stream(self):
        calls = []

        def transport(method, path, body=None):
            calls.append((method, path, body))
            return {"sessions": [{"client_id": "12345"}], "success": True}

        self.assertTrue(pointer.prime(transport))
        self.assertEqual(calls[1][:2], ("POST", "/api/v1/sessions/input"))
        self.assertEqual(calls[1][2]["session_id"], "12345")
        packet = bytes.fromhex(calls[1][2]["input_packet_hex"])
        self.assertEqual(struct.unpack("<HH", packet[:4]), (0x0206, len(packet) - 4))
        self.assertEqual(struct.unpack(">I", packet[4:8])[0], len(packet) - 8)
        self.assertEqual(struct.unpack("<I", packet[8:12])[0], 7)
        self.assertEqual(struct.unpack(">hh", packet[12:]), (1, 1))

    def test_does_not_inject_into_missing_ambiguous_or_invalid_streams(self):
        for sessions in [[], [{"client_id": "1"}, {"client_id": "2"}], [{}], [{"client_id": "not-a-stream"}]]:
            with self.subTest(sessions=sessions):
                calls = []

                def transport(method, path, body=None):
                    calls.append(method)
                    return {"sessions": sessions}

                self.assertFalse(pointer.prime(transport))
                self.assertEqual(calls, ["GET"])
