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

if args.source_only:
    print('NATIVE_VIDEO_SOURCE_CHECK_PASSED no_swift_launched=true no_desktop_rendering=true')
    raise SystemExit(0)

with tempfile.TemporaryDirectory(prefix='waifux-native-video-resource-', dir='/tmp') as folder:
    binary = Path(folder) / 'native-video-resources'
    subprocess.run(['swiftc', '-swift-version', '6',
                    *[str(ROOT / source) for source in SOURCES],
                    '-o', str(binary)], check=True, timeout=90)
    subprocess.run([str(binary)], check=True, timeout=10)
