#!/usr/bin/env python3
"""Check the real isolation policy and guards without launching any App/window."""
from pathlib import Path
import argparse
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source-only', action='store_true', help='check guards and runner refusal without launching Swift')
args = parser.parse_args()


def function_body(source, declaration):
    start = source.index(declaration)
    opening = source.index('{', start)
    depth = 1
    cursor = opening + 1
    while depth:
        if source[cursor] == '{':
            depth += 1
        elif source[cursor] == '}':
            depth -= 1
        cursor += 1
    return source[opening + 1:cursor - 1]


guards = {
    'Services/WallpaperExtensionSocketServer.swift': [
        'private var socketURL:', 'private func notifyCommandsChanged()',
        'func notifyAppWillTerminate()', 'func notifyExtensionReload()',
        'func notifyExtensionReloadIfBundleChanged()',
    ],
    'Services/LockScreenWallpaperService.swift': [
        'func notifyExtensionPrefsChanged()', 'private func publishPlaybackState(',
    ],
    'Services/DisplayCropSettingsStore.swift': ['private nonisolated static func sharedContainerURL()', 'private func notifyChange('],
    'Services/LockScreenFramePusher.swift': ['func startPushing('],
    'Services/VideoWallpaperManager.swift': [
        'private func observeExtensionStateChanges()', 'private func checkExtensionState()',
        'private func scheduleStaleExtensionStateCleanup()',
        'private func writeExtensionStateInactive(', 'private func reconcileExtensionStateAfterUnlock()',
        'private func syncAllDisplayVideosToExtension()',
        'private func applyPosterAsDesktopWallpaperSync(', 'private func applyPosterAsDesktopWallpaper(',
    ],
}
for filename, declarations in guards.items():
    source = (ROOT / filename).read_text()
    for declaration in declarations:
        body = function_body(source, declaration).lstrip()
        assert body.startswith('guard !BackgroundRuntimeRole.isIsolatedTest else { return'), (filename, declaration)
        print('STATIC_GUARD_PASSED', filename, declaration)

source = (ROOT / 'Services/VideoWallpaperManager.swift').read_text()
assert 'guard BackgroundRuntimeRole.allowsDesktopRendering' in function_body(source, 'private func createWindow(')[:220]
assert 'guard !BackgroundRuntimeRole.isIsolatedTest' in function_body(source, 'func setDesktopImageURLForAllSpaces(')[:330]
assert 'guard !BackgroundRuntimeRole.isIsolatedTest' in function_body(source, 'func publishSystemWallpaperSyncControlToWebDaemon()')[:220]
runtime = (ROOT / 'BackgroundAgent/BackgroundAgentRuntime.swift').read_text()
assert function_body(runtime, 'private func execute(').lstrip().startswith('guard BackgroundRuntimeRole.permitsOperation(operation)')
print('STATIC_RENDERING_ENTRY_GUARDS_PASSED')

# A rendering scenario must fail at argument validation, before compilation,
# fixture generation, launchctl or a real UI/Helper can be started.
for scenario in [None, 'ui-exit', 'full-quit', 'startup-upgrade', 'detached-upgrade', 'lifecycle']:
    command = ['python3', str(ROOT / 'scripts/test-background-helper.py'), '--app', '/nonexistent/WaifuX.app']
    if scenario:
        command += ['--scenario', scenario]
    result = subprocess.run(command, capture_output=True, text=True, timeout=5)
    assert result.returncode == 2 and 'Rendering regression is disabled' in result.stderr, (scenario, result.stderr)
    print('RUNNER_REFUSAL_PASSED', scenario or 'default')

if args.source_only:
    print('BACKGROUND_ISOLATION_SOURCE_CHECK_PASSED no_apps_launched=true no_swift_launched=true')
    raise SystemExit(0)

with tempfile.TemporaryDirectory(prefix='waifux-isolation-policy-') as directory:
    for role in ['ui', 'helper']:
        binary = Path(directory) / role
        command = ['swiftc', '-swift-version', '6']
        if role == 'helper':
            command += ['-D', 'WAIFUX_HELPER']
        command += [str(ROOT / 'BackgroundAgent/BackgroundRuntimeRole.swift'),
                    str(ROOT / 'Tests/BackgroundIsolationPolicyRegression.swift'), '-o', str(binary)]
        subprocess.run(command, check=True)
        environment = dict(os.environ)
        environment.pop('WAIFUX_HELPER_TEST_SUITE', None)
        environment.pop('WAIFUX_HELPER_TEST_ALLOW_DESKTOP_RENDERING', None)
        subprocess.run([str(binary), 'rendering'], env=environment, check=True)
        environment['WAIFUX_HELPER_TEST_SUITE'] = 'com.waifux.test.isolation.preferences'
        subprocess.run([str(binary), 'blocked'], env=environment, check=True)
        environment['WAIFUX_HELPER_TEST_ALLOW_DESKTOP_RENDERING'] = '1'
        subprocess.run([str(binary), 'rendering'], env=environment, check=True)

print('BACKGROUND_ISOLATION_REGRESSION_PASSED no_apps_launched=true')
