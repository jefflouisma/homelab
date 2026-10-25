"""Prime this pod's Wayland pointer after Cove maps its window, before remote clicks."""
import http.client
import json
from pathlib import Path
import socket
import struct
import subprocess
import time


class WolfConnection(http.client.HTTPConnection):
    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect("/etc/wolf/wolf.sock")


def request(method, path, body=None):
    connection = WolfConnection("localhost", timeout=3)
    try:
        connection.request(method, path, None if body is None else json.dumps(body),
                           {"Content-Type": "application/json"})
        response = connection.getresponse()
        payload = json.loads(response.read())
        if response.status != 200 or payload.get("success") is not True:
            raise ValueError("Wolf input API is not ready")
        return payload
    finally:
        connection.close()


def prime(transport=request):
    sessions = transport("GET", "/api/v1/sessions").get("sessions", [])
    # A Fenrir pod owns one Wolf stream. Never guess if that invariant changes.
    if len(sessions) != 1:
        return False
    session_id = str(sessions[0].get("client_id", ""))
    if not session_id.isascii() or not session_id.isdigit():
        return False
    # Wolf's API expects the control envelope too: INPUT_DATA and payload length,
    # then the Moonlight input body's BE size, LE type and BE signed deltas.
    packet = struct.pack("<HH", 0x0206, 12) + struct.pack(">I", 8) + struct.pack("<I", 7) + struct.pack(">hh", 1, 1)
    transport("POST", "/api/v1/sessions/input", {
        "session_id": session_id, "input_packet_hex": packet.hex(),
    })
    return True


def main():
    deadline = time.monotonic() + 180
    while time.monotonic() < deadline:
        try:
            if Path("/etc/wolf/wolf.sock").is_socket():
                window = subprocess.run(
                    ["xdotool", "search", "--onlyvisible", "--name", "Cove TV"],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=2,
                )
                if window.returncode == 0 and prime():
                    print("Cove remote: initialized pointer focus", flush=True)
                    break
        except (OSError, ValueError, http.client.HTTPException, subprocess.TimeoutExpired):
            pass
        time.sleep(0.25)
    else:
        print("Cove remote: pointer initialization timed out", flush=True)
    # This is a native sidecar: remain idle instead of restarting and moving focus again.
    while True:
        time.sleep(3600)


if __name__ == "__main__":
    main()
