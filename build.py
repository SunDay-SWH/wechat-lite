#!/usr/bin/env python3
"""Build 微信轻转 with Command Line Tools and install it to /Applications; no third-party packages.

Running `python3 build.py` tests the core, quits the running copy, rebuilds /Applications/微信轻转.app in
place, registers its share entries and relaunches it. Only that one copy may exist: another bundle with the
same share-extension IDs can silently take WeChat's shares.
"""
from pathlib import Path
import os
import platform
import plistlib
import shutil
import subprocess
import struct
import sys
import time

ROOT = Path(__file__).resolve().parent
BUILD = ROOT / 'build'
DEST = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path('/Applications/微信轻转.app')
APP_ID = 'local.sunwenhao.wechatlite'
EXT_ID = APP_ID + '.share'
SDK = subprocess.check_output(['xcrun', '--show-sdk-path'], text=True).strip()
ARCH = platform.machine()
BUILD.mkdir(exist_ok=True)

def run(*args):
    print('Running:', str(args[0]), str(args[-1]), flush=True)
    subprocess.run([str(x) for x in args], check=True)

def plist(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(plistlib.dumps(value, sort_keys=False))

common = ['swiftc', '-swift-version', '5', '-Onone', '-sdk', SDK,
          '-target', f'{ARCH}-apple-macos14.0', '-module-cache-path', str(BUILD / 'ModuleCache'),
          '-parse-as-library']

# Test the core before touching the installed app.
run(*common, ROOT / 'Sources/Core.swift', ROOT / 'Tests/CoreTests.swift', '-o', BUILD / 'core-tests')
run(BUILD / 'core-tests', BUILD / 'test-data')
run(*common, '-framework', 'AppKit', ROOT / 'Sources/Core.swift', ROOT / 'Sources/InputFocus.swift',
    ROOT / 'Tests/InputFocusTests.swift', '-o', BUILD / 'input-focus-tests')
run(BUILD / 'input-focus-tests')

# Compile before stopping the installed app: a compile error must leave the working copy intact.
run(*common, '-module-name', 'WeChatLite', '-framework', 'AppKit', '-framework', 'SwiftUI',
    ROOT / 'Sources/Core.swift', ROOT / 'Sources/InputFocus.swift', ROOT / 'Sources/App.swift',
    '-o', BUILD / 'WeChatLite')

# Quit the running copy (this also hides its share entries until the relaunch below), then rebuild from scratch.
subprocess.run(['osascript', '-e', f'tell application id "{APP_ID}" to quit'], capture_output=True)
for _ in range(50):
    if subprocess.run(['pgrep', '-x', 'WeChatLite'], capture_output=True).returncode != 0:
        break
    time.sleep(0.1)
shutil.rmtree(DEST, ignore_errors=True)

app_contents = DEST / 'Contents'
ext = app_contents / 'PlugIns' / 'WeChatLiteShare.appex'
for folder in [app_contents / 'MacOS', app_contents / 'Resources', ext / 'Contents/MacOS']:
    folder.mkdir(parents=True, exist_ok=True)

shutil.copy2(BUILD / 'WeChatLite', app_contents / 'MacOS/WeChatLite')
run(*common, '-module-name', 'WeChatLiteShare', '-application-extension',
    '-framework', 'AppKit', '-framework', 'UniformTypeIdentifiers',
    '-Xlinker', '-e', '-Xlinker', '_NSExtensionMain',
    ROOT / 'Sources/Core.swift', ROOT / 'Sources/ShareViewController.swift',
    '-o', ext / 'Contents/MacOS/WeChatLiteShare')

base = {'CFBundleInfoDictionaryVersion': '6.0', 'CFBundleShortVersionString': '0.1.1',
        'CFBundleVersion': '2', 'CFBundleDevelopmentRegion': 'zh_CN', 'LSMinimumSystemVersion': '14.0'}
plist(app_contents / 'Info.plist', dict(base, **{
    'CFBundleIdentifier': APP_ID, 'CFBundleName': '微信轻转', 'CFBundleDisplayName': '微信轻转',
    'CFBundleExecutable': 'WeChatLite', 'CFBundlePackageType': 'APPL', 'LSUIElement': True,
    'NSHighResolutionCapable': True, 'CFBundleIconFile': 'AppIcon',
    'NSHumanReadableCopyright': '本机自用版 · 2026 · 本地整理，由用户在 Codex 中确认发送。',
    'CFBundleURLTypes': [{'CFBundleURLName': APP_ID, 'CFBundleURLSchemes': ['wechatlite']}]
}))
def share_plist(bundle_id, target, name):
    # Short names: WeChat's share menu truncates long ones.
    return dict(base, **{
    'CFBundleIdentifier': bundle_id, 'CFBundleName': name,
    'CFBundleDisplayName': name, 'CFBundleExecutable': 'WeChatLiteShare',
    'CFBundlePackageType': 'XPC!', 'WeChatLiteTarget': target,
    'NSExtension': {
        'NSExtensionPointIdentifier': 'com.apple.share-services',
        'NSExtensionPrincipalClass': 'WeChatLiteShareController',
        'NSExtensionAttributes': {'NSExtensionActivationRule': {
            'NSExtensionActivationDictionaryVersion': 2,
            'NSExtensionActivationSupportsFileWithMaxCount': 32,
            'NSExtensionActivationSupportsImageWithMaxCount': 32,
            'NSExtensionActivationSupportsMovieWithMaxCount': 32,
            'NSExtensionActivationSupportsText': True,
            'NSExtensionActivationSupportsWebURLWithMaxCount': 32
        }}
    }
    })

# The Codex entry keeps its original bundle ID so the existing share-menu enablement survives.
SHARES = [(ext, EXT_ID, 'codex', 'Codex'),
          (app_contents / 'PlugIns' / 'WeChatLiteShareClaude.appex', EXT_ID + '.claude', 'claude', 'Claude')]
for bundle, bundle_id, target, name in SHARES:
    if bundle != ext:
        shutil.rmtree(bundle, ignore_errors=True)
        (bundle / 'Contents/MacOS').mkdir(parents=True)
        shutil.copy2(ext / 'Contents/MacOS/WeChatLiteShare', bundle / 'Contents/MacOS/WeChatLiteShare')
    plist(bundle / 'Contents/Info.plist', share_plist(bundle_id, target, name))
plist(BUILD / 'Share.entitlements', {
    'com.apple.security.app-sandbox': True,
    'com.apple.security.files.user-selected.read-only': True,
    # A narrow shared folder is used instead of an App Group that requires a developer team.
    'com.apple.security.temporary-exception.files.home-relative-path.read-write': [
        '/Library/Application Support/WeChatLite/'
    ]
})
run('swiftc', '-module-cache-path', BUILD / 'ModuleCache', ROOT / 'Resources/MakeIcon.swift', '-o', BUILD / 'make-icon')
iconset = BUILD / 'AppIcon.iconset'
iconset.mkdir(exist_ok=True)
run(BUILD / 'make-icon', iconset)
# ICNS accepts PNG payloads directly. Avoid iconutil's dependence on GUI image services.
def write_icns(iconset, target):
    icon_parts = []
    for kind, name in [('icp4', '16x16'), ('icp5', '32x32'), ('icp6', '32x32@2x'),
                       ('ic07', '128x128'), ('ic08', '256x256'), ('ic09', '512x512'), ('ic10', '512x512@2x')]:
        payload = (iconset / f'icon_{name}.png').read_bytes()
        icon_parts.append(kind.encode() + struct.pack('>I', len(payload) + 8) + payload)
    payload = b''.join(icon_parts)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(b'icns' + struct.pack('>I', len(payload) + 8) + payload)

write_icns(iconset, app_contents / 'Resources/AppIcon.icns')
for bundle, bundle_id, _, _ in SHARES:
    run('codesign', '--force', '--sign', '-', '--identifier', bundle_id,
        '--entitlements', BUILD / 'Share.entitlements', bundle)
# Ad-hoc signatures otherwise tie the Accessibility grant to this exact build's hash; pin it to the bundle ID instead.
run('codesign', '--force', '--sign', '-', '--identifier', APP_ID,
    '--requirements', f'=designated => identifier "{APP_ID}"', DEST)
run('codesign', '--verify', '--deep', '--strict', DEST)

LSREGISTER = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
run(LSREGISTER, '-f', DEST)
for bundle, _, _, _ in SHARES:
    run('pluginkit', '-a', bundle)
run('open', DEST)  # launching re-enables the share entries the user has ticked
print(f'Built, installed and launched: {DEST}')
