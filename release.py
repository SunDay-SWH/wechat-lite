#!/usr/bin/env python3
"""Package the installed /Applications/微信轻转.app into build/微信轻转-<version>.dmg for a GitHub Release.

Run `python3 build.py` first so the installed copy is current. The DMG is built from a temporary staging
folder that is deleted right away and never registered, so no second copy of the share extensions exists.
"""
from pathlib import Path
import plistlib
import platform
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent
APP = Path('/Applications/微信轻转.app')
info = plistlib.loads((APP / 'Contents/Info.plist').read_bytes())
version = info['CFBundleShortVersionString']
dmg = ROOT / 'build' / f'微信轻转-{version}-{platform.machine()}.dmg'

subprocess.run(['codesign', '--verify', '--deep', '--strict', str(APP)], check=True)
dmg.unlink(missing_ok=True)
with tempfile.TemporaryDirectory() as tmp:
    stage = Path(tmp) / '微信轻转'
    stage.mkdir()
    # ditto keeps the signatures and extended attributes intact.
    subprocess.run(['ditto', str(APP), str(stage / APP.name)], check=True)
    (stage / 'Applications').symlink_to('/Applications')
    subprocess.run(['hdiutil', 'create', '-quiet', '-volname', f'微信轻转 {version}', '-srcfolder', str(stage),
                    '-fs', 'HFS+', '-format', 'UDZO', '-ov', str(dmg)], check=True)
subprocess.run(['hdiutil', 'verify', '-quiet', str(dmg)], check=True)
print(f'v{version}\n{dmg}')
