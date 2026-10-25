#!/usr/bin/env python3
"""Seed Torrentio once through Cove's local API, preserving user configuration."""
import json
import os
import time
from pathlib import Path
from urllib.error import URLError
from urllib.request import Request, urlopen

BASE = 'http://127.0.0.1:6969/api/v1/addons'
MARKER = Path(os.environ['COVE_DATA_DIR']) / '.fenrir-torrentio-installed'
ADDON_ID = 'com.stremio.torrentio.addon'


def request(method='GET', payload=None):
    data = None if payload is None else json.dumps(payload).encode()
    req = Request(BASE, data=data, method=method, headers={'Content-Type': 'application/json'})
    with urlopen(req, timeout=20) as response:
        return json.load(response)


def install():
    if MARKER.exists():
        return
    deadline = time.monotonic() + 180
    while time.monotonic() < deadline:
        try:
            addons = request()
            if not any(a.get('id') == ADDON_ID for a in addons):
                request('POST', {'url': 'https://torrentio.strem.fun/manifest.json'})
            if any(a.get('id') == ADDON_ID and a.get('enabled', True) for a in request()):
                MARKER.write_text('https://torrentio.strem.fun/manifest.json\n')
                print('Cove: Torrentio installed and verified through the local API', flush=True)
                return
        except (OSError, URLError, ValueError):
            pass
        time.sleep(2)
    raise SystemExit('Cove: Torrentio setup will retry on the next launch')


if __name__ == '__main__':
    install()
