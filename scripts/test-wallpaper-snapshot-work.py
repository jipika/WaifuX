#!/usr/bin/env python3
"""Check snapshot work and unattached crop layers without windows, players or IOSurfaces."""
from pathlib import Path
import argparse
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source-only', action='store_true', help='only read production source; do not launch Swift')
args = parser.parse_args()

snapshot = (ROOT / 'WaifuXWallpaperExtension/SnapshotCreation.swift').read_text()
bmp = (ROOT / 'WaifuXWallpaperExtension/BMPCache.swift').read_text()
handler = (ROOT / 'WaifuXWallpaperExtension/WallpaperXPCHandler.swift').read_text()
extension = (ROOT / 'WaifuXWallpaperExtension/WaifuXWallpaperExtension.swift').read_text()
coordinator = (ROOT / 'WaifuXWallpaperExtension/LatestWallpaperSnapshotWork.swift').read_text()
lock_screen = (ROOT / 'Services/LockScreenWallpaperService.swift').read_text()

assert 'cacheLifetime: { $0.value == nil ? 5 : .infinity }' in snapshot
assert 'maximumCachedKeys: 1' in snapshot and 'key: { $0.displayID ?? 0 }' in snapshot
assert 'wallpaperSnapshotDecodeGate.perform' in snapshot and 'wallpaperSnapshotDecodeGate.perform' in bmp
assert 'maximumKeys: 16' in bmp and 'key: { $0.displayID }' in bmp
assert 'generator.maximumSize' in snapshot and 'generator.maximumSize' in bmp
assert 'IOSurfaceGetPropertyAlignment(kIOSurfaceBytesPerRow)' in snapshot
assert 'surface.allocationSize <= WallpaperSnapshotPixelBudget.maximumPixelBytes' in snapshot
assert 'class_getInstanceSize(snapshotClass) >= 8 + MemoryLayout<UnsafeMutableRawPointer>.size' in snapshot
assert 'CGImageSourceCreateImageAtIndex' not in snapshot and 'CGImageSourceCreateImageAtIndex' not in bmp
assert bmp.index('try bmp.write(to: bmpURL') < bmp.index('try? FileManager.default.removeItem(at: file)')
assert 'let matchingCachePrefix = "\\(hashHex)-\\(displayPixelWidth)-\\(displayPixelHeight)-"' in bmp
assert 'file.lastPathComponent.hasPrefix(matchingCachePrefix)' in bmp
assert 'ProcessInfo.processInfo.systemUptime' in coordinator
for source in [handler, extension]:
    for line in source.splitlines():
        if 'writeSnapshotCacheIfPossible(videoURL:' in line:
            assert 'displayID:' in line, line
snapshot_method = handler.split('func snapshot(withId', 1)[1].split('\n    }', 1)[0]
assert 'requestSnapshotViaRuntime' in snapshot_method and 'Task {' not in snapshot_method
assert 'activeContext(wallpaperID:' in snapshot_method
assert 'requestSnapshotViaRuntime(displayID: context?.displayID' in snapshot_method
assert 'NSKeyedArchiver.archivedData' not in snapshot_method
print('PASS production snapshot/BMP bounds and single-flight wiring')

prepare_static = lock_screen.split('static func prepareStaticLockScreenImageData(', 1)[1].split('static func encodeLockScreenImage(', 1)[0]
assert prepare_static.index('CGImageSourceCopyPropertiesAtIndex') < prepare_static.index('CGImageSourceCreateImageAtIndex')
assert prepare_static.index('Self.staticImageFitsPixelBudget') < prepare_static.index('CGImageSourceCreateImageAtIndex')
assert 'return (data, fallbackExtension)' in prepare_static
scan_static = lock_screen.split('static func detectBlackBorderCropRect(', 1)[1].split('// MARK: - Display Instances', 1)[0]
assert scan_static.index('scanPixelBytes <= staticImagePixelByteLimit') < scan_static.index('var pixels = [UInt8]')
assert 'image.bytesPerRow.multipliedReportingOverflow' in scan_static
thumbnail_static = lock_screen.split('static func writeThumbnail(', 1)[1].split('private func copyVideoThumbnailToDisplayThumbnails', 1)[0]
assert 'NSImage' not in thumbnail_static and 'CGImageSourceCreateImageAtIndex' not in thumbnail_static
assert 'CGImageSourceCreateThumbnailAtIndex' in thumbnail_static
assert 'kCGImageSourceThumbnailMaxPixelSize: thumbnailMaximumDimension' in thumbnail_static
assert 'pixelBytes <= thumbnailPixelByteLimit' in thumbnail_static
print('PASS lock-screen static crop preserves oversized originals and thumbnails have a pixel budget')

crop = (ROOT / 'WaifuXWallpaperExtension/ExtensionCropSupport.swift').read_text()
video = (ROOT / 'WaifuXWallpaperExtension/VideoRenderer.swift').read_text()
surface = (ROOT / 'WaifuXWallpaperExtension/IOSurfaceFrameRenderer.swift').read_text()
geometry_update = handler.split('private static func applyDisplayGeometryUpdate(', 1)[1].split('// MARK: - Lifecycle', 1)[0]
assert 'activeContextsSnapshot().filter' in geometry_update and 'ExtDisplayGeometry.matches(' in geometry_update
assert 'activeContext(wallpaperID:' not in geometry_update
assert 'relayoutContent(active, displayID: targetDisplayID)' in geometry_update
assert 'applyStaticCrop(rootLayer: active.rootLayer' in geometry_update
assert '(hasTarget ? requestedSize : nil)' in geometry_update
assert 'contextDisplayIDs.count == 1' in geometry_update
assert 'contextDisplayIsActive:' in geometry_update
assert 'WallpaperXPCHandler.refreshActiveCropLayouts()' in extension
acquire = handler.split('func acquire(withId', 1)[1].split('private static func startLocalVideoFallbackTask', 1)[0]
assert 'requestDisplayGeometry(from: request)' in acquire and 'ExtDisplayGeometry.isValid(size: destSize)' in acquire
assert 'CGSize(width: 1920, height: 1080)' not in acquire
assert 'viewportLayer.masksToBounds = true' in crop
assert 'layer.contentsGravity = .resizeAspectFill' in crop
assert 'CFGetTypeID(object) == CGImage.typeID' in crop
assert 'ExtCropLayers.setStaticImage(image, in: rootLayer' in handler
assert 'ExtCropLayers.apply(' in video
assert 'viewportLayer.addSublayer(stillFrameLayer)' in video
assert 'applyAspectFillLayout(videoSize: videoSize)\n        generateBackgroundFrame(for: asset)' in video
assert 'displayLayer.videoGravity = .resize\n' not in surface
relayout = video.split('func relayoutForCurrentDisplayGeometry(', 1)[1].split('private func applyAspectFillLayout(videoSize:', 1)[0]
assert 'displaySizeSync' not in relayout and 'applyAspectFillLayout(for:' not in relayout
print('PASS source wiring: static/video crop refresh, all matching contexts, validated display geometry')

if not args.source_only:
    with tempfile.TemporaryDirectory(prefix='waifux-snapshot-work-') as folder:
        binary = Path(folder) / 'snapshot-work-regression'
        sources = [
            'WaifuXWallpaperExtension/LatestWallpaperSnapshotWork.swift',
            'WaifuXWallpaperExtension/WallpaperSnapshotPixelBudget.swift',
            'Tests/WallpaperSnapshotWorkRegression.swift',
        ]
        subprocess.run(['swiftc', '-swift-version', '6',
                        *[str(ROOT / source) for source in sources],
                        '-o', str(binary)], check=True, timeout=60)
        subprocess.run([str(binary)], check=True, timeout=15)
        crop_binary = Path(folder) / 'extension-crop-regression'
        subprocess.run(['swiftc', '-swift-version', '6',
                        str(ROOT / 'WaifuXWallpaperExtension/ExtensionCropSupport.swift'),
                        str(ROOT / 'Tests/ExtensionCropLayoutRegression.swift'),
                        '-o', str(crop_binary)], check=True, timeout=60)
        subprocess.run([str(crop_binary)], check=True, timeout=15)
