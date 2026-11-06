#!/usr/bin/env python3
"""Check generated signing and Helper boundaries against the XcodeGen source."""
from pathlib import Path
import argparse
import hashlib
import json
import plistlib
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--app', type=Path, help='Also verify the built host and embedded Helper use identical icons')
args = parser.parse_args()
spec = (ROOT / 'project.yml').read_text()
expected_team = re.search(r'^    DEVELOPMENT_TEAM: (\S+)$', spec, re.M).group(1)
objects = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(ROOT / 'WaifuX.xcodeproj/project.pbxproj')]))['objects']
project = next(value for value in objects.values() if value.get('isa') == 'PBXProject')
project_settings = {objects[config]['name']: objects[config]['buildSettings']
                    for config in objects[project['buildConfigurationList']]['buildConfigurations']}
expected = {
    'WaifuX': ('com.waifux.app', 'WaifuX.entitlements'),
    'WaifuXHelper': ('com.waifux.app.helper', 'BackgroundAgent/BackgroundAgent.entitlements'),
    'WaifuXWallpaperExtension': ('com.waifux.app.wallpaperextension', 'WaifuXWallpaperExtension/WaifuXWallpaperExtension.entitlements'),
    'WaifuXScreenSaver': ('com.waifux.app.screensaver', None),
}
seen = set()
for target in objects.values():
    if target.get('isa') != 'PBXNativeTarget' or target['name'] not in expected:
        continue
    name = target['name']
    seen.add(name)
    identifier, entitlements = expected[name]
    for config_id in objects[target['buildConfigurationList']]['buildConfigurations']:
        config = objects[config_id]
        values = project_settings[config['name']] | config['buildSettings']
        assert values['DEVELOPMENT_TEAM'] == expected_team, (name, config['name'], 'team')
        assert values['CODE_SIGN_STYLE'] == 'Automatic', (name, config['name'], 'signing style')
        assert values['PRODUCT_BUNDLE_IDENTIFIER'] == identifier, (name, config['name'], 'bundle identifier')
        if entitlements:
            assert values['CODE_SIGN_ENTITLEMENTS'] == entitlements, (name, 'entitlements path')
            assert values['REGISTER_APP_GROUPS'] == 'YES', (name, 'App Group provisioning')
        if name == 'WaifuXHelper':
            assert 'WAIFUX_HELPER' in str(values['SWIFT_ACTIVE_COMPILATION_CONDITIONS'])
            assert 'zip_data.o' in str(values['OTHER_LDFLAGS'])
        if name == 'WaifuX':
            assert 'zip_data.o' not in str(values.get('OTHER_LDFLAGS', ''))
        if name in ('WaifuX', 'WaifuXHelper'):
            assert values['ASSETCATALOG_COMPILER_APPICON_NAME'] == 'AppIcon', (name, 'product icon')
    if name in ('WaifuX', 'WaifuXHelper'):
        source_paths = {
            objects[objects[file]['fileRef']].get('path', '')
            for phase in target['buildPhases'] if objects[phase]['isa'] == 'PBXSourcesBuildPhase'
            for file in objects[phase]['files']
        }
        assert any(path.endswith('BackgroundChildProcessCleanup.swift') for path in source_paths), (name, 'owned child cleanup source')
        for source in ('OwnedProcessIdentity.swift', 'WallpaperBatteryPauseOwnership.swift', 'WallpaperAutoPauseApplicationIdentity.swift',
                       'VideoFreezeFrameBudget.swift', 'VideoPosterCacheBudget.swift', 'DeferredResourceCleanup.swift'):
            assert any(path.endswith(source) for path in source_paths), (name, 'shared lifecycle/policy source', source)
        # The host validates staged lock-screen images with the extension's exact decoder and budget.
        for source in ('WallpaperBoundedImageDecoder.swift', 'LockScreenImagePublication.swift', 'WallpaperSnapshotPixelBudget.swift'):
            assert any(path.endswith(source) for path in source_paths), (name, 'shared static-image source', source)
        resource_paths = {
            objects[objects[file]['fileRef']].get('path')
            for phase in target['buildPhases'] if objects[phase]['isa'] == 'PBXResourcesBuildPhase'
            for file in objects[phase]['files']
        }
        assert 'Assets.xcassets' in resource_paths, (name, 'shared icon catalog')
    if entitlements:
        permissions = plistlib.loads((ROOT / entitlements).read_bytes())
        assert 'group.com.waifux.app' in permissions['com.apple.security.application-groups'], name
    if name == 'WaifuXWallpaperExtension':
        # pkd ignores unsandboxed plug-ins, so every configuration must sign with the sandbox.
        assert permissions.get('com.apple.security.app-sandbox') is True, (name, 'extension must be sandboxed')
        assert re.search(r'^\s+com\.apple\.security\.app-sandbox: true$', spec, re.M), \
            (name, 'project.yml must keep the extension sandbox entitlement')
        source_paths = {
            objects[objects[file]['fileRef']].get('path', '')
            for phase in target['buildPhases'] if objects[phase]['isa'] == 'PBXSourcesBuildPhase'
            for file in objects[phase]['files']
        }
        for source in ('WallpaperContextGeneration.swift', 'VideoPlaybackRecoveryPolicy.swift',
                       'LatestWallpaperSnapshotWork.swift', 'WallpaperSnapshotPixelBudget.swift',
                       'WallpaperBoundedImageDecoder.swift'):
            assert any(path.endswith(source) for path in source_paths), (name, 'memory lifecycle source', source)
helper_info = plistlib.loads((ROOT / 'BackgroundAgent/Info.plist').read_bytes())
for key in ['NSAudioCaptureUsageDescription', 'NSScreenCaptureDescription', 'NSAppleMusicUsageDescription', 'NSAppleEventsUsageDescription']:
    assert helper_info.get(key), ('Helper privacy description', key)
assert helper_info['NSAppTransportSecurity']['NSAllowsLocalNetworking'] is True
assert helper_info['CFBundleIconName'] == 'AppIcon'
agent = plistlib.loads((ROOT / 'BackgroundAgent/com.waifux.app.helper.plist').read_bytes())
assert agent['KeepAlive'] == {'SuccessfulExit': False}, 'Explicit quit must not restart a successfully stopped Helper'
assert agent['RunAtLoad'] is True, 'Login launch must remain available'
# 「修复后台服务」的备用注册：除 Label 外必须与默认注册一致，且两份都要拷进主 App 的 LaunchAgents。
relinked = plistlib.loads((ROOT / 'BackgroundAgent/com.waifux.app.helper.relinked.plist').read_bytes())
assert relinked['Label'] == 'com.waifux.app.helper.relinked' != agent['Label'], 'Relinked agent needs its own launchd label'
assert {k: v for k, v in relinked.items() if k != 'Label'} == {k: v for k, v in agent.items() if k != 'Label'}, \
    'Relinked agent must match the bundled agent except for Label'
launch_agent_copies = set()
for target in objects.values():
    if target.get('isa') != 'PBXNativeTarget' or target['name'] != 'WaifuX':
        continue
    for phase in target['buildPhases']:
        if objects[phase]['isa'] == 'PBXCopyFilesBuildPhase' and objects[phase].get('dstPath') == 'Contents/Library/LaunchAgents':
            for file in objects[phase]['files']:
                launch_agent_copies.add(Path(objects[objects[file]['fileRef']].get('path', '')).name)
assert {'com.waifux.app.helper.plist', 'com.waifux.app.helper.relinked.plist'} <= launch_agent_copies, \
    ('Both Helper agent plists must be copied into Contents/Library/LaunchAgents', launch_agent_copies)
seen_expected = set(expected)
assert seen == seen_expected, (seen, seen_expected)
print(f'PROJECT_CONFIGURATION_PASSED team={expected_team} targets={len(seen)} Debug/Release')
if args.app:
    host = args.app.resolve()
    icons = []
    for app in (host, host / 'Contents/Helpers/WaifuXHelper.app'):
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        assert info['CFBundleIconName'] == 'AppIcon', (app, 'icon name')
        icon_name = info['CFBundleIconFile']
        icon_file = app / 'Contents/Resources' / (icon_name if icon_name.endswith('.icns') else icon_name + '.icns')
        assert icon_file.is_file(), (app, 'compiled icon')
        assert (app / 'Contents/Resources/Assets.car').is_file(), (app, 'compiled asset catalog')
        icons.append(icon_file.read_bytes())
    assert icons[0] == icons[1], 'Host and Helper product icons differ'
    print('BUILT_HELPER_PRODUCT_ICON_PASSED sha256=' + hashlib.sha256(icons[0]).hexdigest())
