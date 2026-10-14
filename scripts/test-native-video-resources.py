#!/usr/bin/env python3
"""Production resource lifetime and allocation arithmetic; no media or UI."""
from pathlib import Path
import argparse
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source-only', action='store_true', help='read ownership guards without launching Swift')
args = parser.parse_args()
SOURCES = [
    'Utilities/DeferredResourceCleanup.swift',
    'Services/VideoFreezeFrameBudget.swift',
    'Services/VideoPosterCacheBudget.swift',
    'Tests/NativeVideoResourceRegression.swift',
]

manager = (ROOT / 'Services/VideoWallpaperManager.swift').read_text()


def section(start, end):
    offset = manager.index(start)
    return manager[offset:manager.index(end, offset + len(start))]


apply = section('// A newer apply supersedes', 'let captureScreens: [NSScreen]')
assert 'pendingGlobalTransitionPlayer != nil || globalTransitionResourceCleanup != nil' in apply
rebuild = section('private func rebuildWindows(', 'private func stageGlobalSharedVideoTransition(')
assert rebuild.index('cancelPendingGlobalVideoTransition(reason: "supersededBySingleScreenRebuild")') < rebuild.index('assignPlayerComponents(components, to: targetScreenID)')
cancellation = section('let cancelReplacement: @MainActor', 'let finalizeReplacement: @MainActor')
for guard in [
    'if self.playerItemObserverTokens[targetScreenID] == readinessToken {',
    'self.playerItemObservers.removeValue(forKey: targetScreenID)?.invalidate()',
    'self.fadeInTimeouts.removeValue(forKey: targetScreenID)?.cancel()',
]:
    assert guard in cancellation, guard
readiness = section('let beginAnimatedSwap: @MainActor', 'let observer = incomingLayer.observe')
for guard in [
    'self.players[targetScreenID] === components.player',
    'self.windows[targetScreenID] === existingWindow',
    'existingWindow.contentView === containerView',
]:
    assert guard in readiness, guard
assert readiness.index('incomingLayer.player === components.player else {') < readiness.index('containerView.crossfadePreparedPlayer(')
print('PASS production transition cancellation ordering and late callback ownership guards')

# Helper owns the follow pipeline even while the UI is closed. These checks
# deliberately read source only: no player, desktop write or Swift invocation.
desktop = (ROOT / 'Services/DesktopWallpaperSyncManager.swift').read_text()
current = (ROOT / 'Services/CurrentWallpaperService.swift').read_text()
saver = (ROOT / 'Services/ScreenSaverService.swift').read_text()
scheduler = (ROOT / 'Services/WallpaperSchedulerService.swift').read_text()
lock_screen = (ROOT / 'Services/LockScreenWallpaperService.swift').read_text()
assert 'static let registrationDidChangeNotification' in desktop
assert 'post(name: Self.registrationDidChangeNotification' in desktop
assert 'publisher(for: DesktopWallpaperSyncManager.registrationDidChangeNotification)' in current
assert 'CurrentWallpaperService.shared.$activeURLByScreenID' in saver
assert 'DistributedNotificationCenter.default().publisher(for: Self.configurationChangedNotification)' in saver
rotation = scheduler.split('let generation = onEndSwitchGeneration', 1)[1].split('private func finishOnEndSwitch', 1)[0]
assert 'self.scheduleNextChange()' in rotation
assert 'self.lastChangeTimes[screenID] = Date()' in rotation
cache_video = lock_screen.split('func cacheMirroringSource(', 1)[1].split('func cacheStaticImageSource(', 1)[0]
assert 'Self.stageMirroringVideo(' in cache_video and 'Task.detached(priority: .utility)' in cache_video
assert 'FileManager.default.copyItem' not in cache_video
assert cache_video.index('try checkCurrentRequest()') < cache_video.index('prefs.currentVideoPath = destURL.path')
assert 'generation: generation' in lock_screen.split('func switchActiveInstancesToLocalDecode(', 1)[1].split('func clearRealtimeSourceIfNeeded', 1)[0]
print('PASS Helper follow notifications, rotation rearming and off-main video staging guards')

commit = section('func forceCommitDesktopPresentation(', '// MARK: - 音频设备管理')
assert 'if !container.references(player: player)' in commit
assert 'if container.playerLayer.player !== player' not in commit
preserve = section('var shouldPreserveLockScreenWallpaperSelection:', '/// 同步给 web daemon')
assert 'guard isLockScreenEnabled' in preserve
assert 'WallpaperStoreSelectionProbe.currentSelection(displayUUIDs: displayUUIDs) != .notSelected' in preserve
assert 'CGDisplayCreateUUIDFromDisplayID' in preserve
assert 'shouldPreserveLockScreenWallpaperSelection' in desktop
static_apply = (ROOT / 'Services/StaticWallpaperApplyService.swift').read_text()
assert static_apply.count('if #available(macOS 26.0, *), VideoWallpaperManager.shared.shouldPreserveLockScreenWallpaperSelection') == 2
probe = (ROOT / 'Services/WallpaperStoreSelectionProbe.swift').read_text()
assert 'cached.displays == displayUUIDs' in probe
assert 'displays.values.allSatisfy({ containsChoice($0) })' in probe
assert 'newDate > oldDate' in probe
assert 'extensionChoicesAreSuperseded(choice, by: displays[identifier])' in probe
renderer_apply = (ROOT / 'Services/LocalWallpaperApplyService.swift').read_text().split(
    'private static func syncSystemWallpaperPosterIfAvailable(', 1)[1].split('private static func hasWebSceneTimer', 1)[0]
assert '!BackgroundRuntimeRole.isIsolatedTest' in renderer_apply
assert '!VideoWallpaperManager.shared.shouldPreserveLockScreenWallpaperSelection' in renderer_apply
assert renderer_apply.index('setDesktopImageURLForAllSpaces') < renderer_apply.index('registerWallpaperSet')
static_migration = static_apply.split('static func migrateStaticWallpaperPresentation(', 1)[1]
assert '!VideoWallpaperManager.shared.shouldPreserveLockScreenWallpaperSelection' in static_migration
print('PASS prepared crossfade ownership and selected/unknown lock-screen choice protection')

if args.source_only:
    print('NATIVE_VIDEO_SOURCE_CHECK_PASSED no_swift_launched=true no_desktop_rendering=true')
    raise SystemExit(0)

with tempfile.TemporaryDirectory(prefix='waifux-native-video-resource-', dir='/tmp') as folder:
    binary = Path(folder) / 'native-video-resources'
    subprocess.run(['swiftc', '-swift-version', '6',
                    *[str(ROOT / source) for source in SOURCES],
                    '-o', str(binary)], check=True, timeout=90)
    subprocess.run([str(binary)], check=True, timeout=10)
