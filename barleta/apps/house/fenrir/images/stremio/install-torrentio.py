#!/usr/bin/env python3
"""Install Torrentio once per persistent profile using Stremio's own addon API."""
import json
import time
from pathlib import Path
from urllib.request import urlopen

import websocket

MARKER = Path.home() / ".config/fenrir/torrentio-installed"
EXPRESSION = r"""
(async () => {
  if (!window.angular) return 'waiting';
  const injector = angular.element(document.documentElement).injector();
  if (!injector) return 'waiting';
  const api = injector.get('API');
  const id = 'com.stremio.torrentio.addon';
  if (!api.addons.getAddons().some(a => a.manifest.id === id)) {
    const url = 'https://torrentio.strem.fun/manifest.json';
    const response = await fetch(url);
    if (!response.ok) throw new Error('Torrentio manifest unavailable');
    const manifest = await response.json();
    if (manifest.id !== id) throw new Error('Unexpected Torrentio manifest');
    api.addons.add({transportUrl: url, manifest, flags: {}});
    await api.pushAddonCollection();
  }
  const stored = JSON.parse(localStorage.getItem('addons') || '[]');
  return stored.some(a => a.manifest.id === id) ? 'installed' : 'waiting';
})()
"""


def install():
    if MARKER.exists():
        return
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        try:
            with urlopen('http://127.0.0.1:9222/json', timeout=3) as response:
                pages = json.load(response)
            for page in pages:
                if page.get('type') != 'page' or 'app.strem.io' not in page.get('url', ''):
                    continue
                ws = websocket.create_connection(page['webSocketDebuggerUrl'], timeout=15)
                try:
                    ws.send(json.dumps({'id': 1, 'method': 'Runtime.evaluate', 'params': {
                        'expression': EXPRESSION, 'awaitPromise': True, 'returnByValue': True,
                    }}))
                    while True:
                        result = json.loads(ws.recv())
                        if result.get('id') == 1:
                            break
                finally:
                    ws.close()
                if result.get('result', {}).get('result', {}).get('value') == 'installed':
                    MARKER.parent.mkdir(parents=True, exist_ok=True)
                    MARKER.write_text('https://torrentio.strem.fun/manifest.json\n')
                    print('Torrentio installed and verified in the saved Stremio profile', flush=True)
                    return
        except (OSError, ValueError, websocket.WebSocketException):
            pass
        time.sleep(2)
    raise SystemExit('Torrentio setup did not finish; it will retry on the next launch')


if __name__ == '__main__':
    install()
