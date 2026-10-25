#!/usr/bin/env python3
"""Apply the pinned Cove 1.6.0 BGRA compatibility change without rebuilding its JVM.

Equivalent source change: video-alpha.patch. Both packed formats are four bytes
per pixel, but BGRA makes libmpv initialize alpha to 255 instead of leaving it
undefined; Compose's image bridge can otherwise blend it over the background.
"""
from pathlib import Path
import sys
import zipfile

root = Path(sys.argv[1])
jars = list((root / 'lib/app').glob('desktop-*.jar'))
assert len(jars) == 1, 'Expected the pinned Cove desktop artifact'
jar = jars[0]
entry = 'com/coveninja/cove/desktop/player/SoftwareRenderParameters.class'
old = b'\x00\x04bgr0'
new = b'\x00\x04bgra'
target = jar.with_suffix('.alpha-tmp')
with zipfile.ZipFile(jar) as source, zipfile.ZipFile(target, 'w') as dest:
    assert entry in source.namelist(), 'Cove software renderer layout changed'
    assert not any(n.upper().endswith(('.SF', '.RSA', '.DSA', '.EC'))
                   for n in source.namelist()), 'Do not rewrite a signed artifact'
    for item in source.infolist():
        data = source.read(item.filename)
        if item.filename == entry:
            assert data.count(old) == 1, 'Cove pixel format changed; review the workaround'
            data = data.replace(old, new)
        dest.writestr(item, data)
with zipfile.ZipFile(target) as patched:
    assert patched.testzip() is None
    assert patched.read(entry).count(new) == 1
target.replace(jar)
print('Cove: applied opaque BGRA software-video compatibility patch')
