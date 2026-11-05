//  IOSurface snapshot creation for WallpaperAgent.

@preconcurrency import AVFoundation
import CoreMedia
import ImageIO
@preconcurrency import IOSurface
import os

private final class SnapshotResult: @unchecked Sendable {
    let value: AnyObject?
    let invalidationRevision: UInt64
    let failureCacheLifetime: TimeInterval

    init(_ value: AnyObject?, request: SnapshotRequest) {
        self.value = value
        invalidationRevision = request.invalidationRevision
        failureCacheLifetime = request.failureCacheLifetime
    }
}

private let runtimeSnapshotRevision = OSAllocatedUnfairLock(initialState: UInt64(0))

/// Invalidates on the next submission without changing the shared coordinator
/// or increasing its one-successful-surface cache. Late replies are rejected too.
func invalidateRuntimeSnapshots() {
    runtimeSnapshotRevision.withLock { $0 &+= 1 }
}

// Pending requests are independent per display, while only one completed
// IOSurface is retained by our cache across all displays.
private let snapshotWork = LatestWallpaperSnapshotWork<SnapshotRequest, SnapshotResult>(maximumKeys: 16, maximumCachedKeys: 1,
                                                                                       key: { $0.displayID ?? 0 },
                                                                                       cacheLifetime: { $0.value == nil ? $0.failureCacheLifetime : .infinity }) { request in
    await wallpaperSnapshotDecodeGate.perform { await buildSnapshot(request) }
}

func requestSnapshotViaRuntime(
    displayID: UInt32? = nil, currentTime: CMTime? = nil,
    reply: @escaping @Sendable (AnyObject?) -> Void
) {
    let targetDisplayID = displayID ?? CGMainDisplayID()
    let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.waifux.app")
    let sources: WallpaperSnapshotSources
    if let container {
        let paths = currentPrefsPaths(in: container, displayID: displayID)
        sources = WallpaperSnapshotSources.resolve(
            in: container, currentImagePath: paths.image, currentVideoPath: paths.video)
    } else {
        sources = WallpaperSnapshotSources(images: [], video: nil)
    }
    let prefsRevision = container.map { WallpaperSnapshotFileRevision($0.appendingPathComponent("waifux-wallpaper-prefs.json")) }
    let thumbnailsRevision = container.map { WallpaperSnapshotFileRevision($0.appendingPathComponent("WallpaperCache/thumbnails")) }
    let cropPreferences = WallpaperSnapshotCropPreferences(in: container)
    let invalidationRevision = runtimeSnapshotRevision.withLock { $0 }
    let selectedVideoID = WallpaperState.shared.currentVideoID
    let time = currentTime.flatMap { $0.isNumeric && $0.seconds.isFinite ? $0.seconds : nil }
    // Only layer geometry is read on main. XPC does not synchronously wait for
    // it, and all image/video decoding still uses the existing single-flight gate.
    let submit: @Sendable () -> Void = {
        let geometry = snapshotTargetGeometry(for: targetDisplayID)
        let request = SnapshotRequest(
            displayID: displayID, targetDisplayID: targetDisplayID, sources: sources, playbackTime: time,
            prefsRevision: prefsRevision, thumbnailsRevision: thumbnailsRevision, selectedVideoID: selectedVideoID,
            targetGeometry: geometry, cropPreferences: cropPreferences, invalidationRevision: invalidationRevision)
        snapshotWork.submit(request) { result in
            guard let result, result.invalidationRevision == runtimeSnapshotRevision.withLock({ $0 }) else { reply(nil); return }
            reply(result.value)
        }
    }
    if Thread.isMainThread { submit() } else { DispatchQueue.main.async(execute: submit) }
}

/// Caller is on main; never read a CALayer from a detached snapshot worker.
private func snapshotTargetGeometry(for displayID: UInt32) -> WallpaperSnapshotTargetGeometry? {
    dispatchPrecondition(condition: .onQueue(.main))
    if let active = WallpaperState.shared.activeContext(for: displayID),
       let geometry = WallpaperSnapshotTargetGeometry(size: active.rootLayer.bounds.size, scale: active.rootLayer.contentsScale) {
        return geometry
    }
    return WallpaperSnapshotTargetGeometry(size: CGDisplayBounds(displayID).size)
}

private func buildSnapshot(_ request: SnapshotRequest) async -> SnapshotResult {
    let empty = SnapshotResult(nil, request: request)
    guard !Task.isCancelled, request.invalidationRevision == runtimeSnapshotRevision.withLock({ $0 }) else { return empty }
    for revision in request.sources.images {
        guard !Task.isCancelled else { return empty }
        if let image = loadBudgetedSnapshotImage(revision.url),
           let snapshot = renderSnapshotToIOSurface(image: image, request: request) { return SnapshotResult(snapshot, request: request) }
    }
    guard !Task.isCancelled else { return empty }
    // A raw live surface bypasses target/crop geometry and can represent older
    // media. Use only the current video's thumbnail above or a budgeted frame.
    guard let videoURL = request.sources.video?.url ?? (request.displayID == nil ? findVideoURL() : nil) else { return empty }
    let asset = AVURLAsset(url: videoURL)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    if #available(macOS 15.0, *) { generator.dynamicRangePolicy = .forceSDR }
    generator.maximumSize = CGSize(width: WallpaperSnapshotPixelBudget.maximumVideoImageDimension,
                                   height: WallpaperSnapshotPixelBudget.maximumVideoImageDimension)

    let requestTime: CMTime
    let duration = try? await withTaskCancellationHandler(operation: {
        try await asset.load(.duration)
    }, onCancel: { asset.cancelLoading() })
    guard !Task.isCancelled else { return empty }
    if let duration, duration.isNumeric, duration.seconds.isFinite, duration.seconds > 0 {
        let time = max(0, request.playbackTime ?? 0).truncatingRemainder(dividingBy: duration.seconds)
        requestTime = CMTime(seconds: time, preferredTimescale: 600)
    } else {
        requestTime = .zero
    }

    let image: CGImage
    do {
        let result = try await withTaskCancellationHandler(operation: {
            try await generator.image(at: requestTime)
        }, onCancel: { generator.cancelAllCGImageGeneration() })
        guard !Task.isCancelled else { return empty }
        image = result.image
    } catch {
        extLog("  [Snapshot] Failed to get video frame: \(error)")
        return empty
    }
    guard let snapshotXPC = renderSnapshotToIOSurface(image: image, request: request) else { return empty }
    extLog("  [Snapshot] Created WallpaperSnapshotXPC \(image.width)x\(image.height)")
    return SnapshotResult(snapshotXPC, request: request)
}

func loadBudgetedSnapshotImage(_ url: URL) -> CGImage? {
    guard case .success(let decoded) = WallpaperBoundedImageDecoder.decode(url: url) else { return nil }
    return decoded.image
}

private func currentPrefsPaths(in container: URL, displayID: UInt32?) -> (image: String?, video: String?) {
    let prefsURL = container.appendingPathComponent("waifux-wallpaper-prefs.json")
    guard let data = try? Data(contentsOf: prefsURL),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (nil, nil) }
    // Resolve both candidates from one configuration read; a concurrent switch
    // cannot pair the previous image with the next video's thumbnail.
    func path(_ kind: LockScreenSourceSelection.Kind) -> String? {
        if let displayID {
            return LockScreenSourceSelection.path(
                for: kind, displayID: displayID,
                videoPaths: object["currentVideoPaths"] as? [String: String],
                imagePaths: object["currentImagePaths"] as? [String: String],
                legacyVideoPath: object["currentVideoPath"] as? String,
                legacyImagePath: object["currentImagePath"] as? String)
        }
        let key = kind == .video ? "currentVideoPath" : "currentImagePath"
        guard let path = object[key] as? String, !path.isEmpty else { return nil }
        return path
    }
    return (path(.image), path(.video))
}

private func renderSnapshotToIOSurface(
    image: CGImage, request: SnapshotRequest, targetSize: CGSize? = nil, alreadyCropped: Bool = false
) -> AnyObject? {
    let canvasSize = targetSize ?? request.targetGeometry?.size ?? CGSize(width: image.width, height: image.height)
    guard !Task.isCancelled, request.invalidationRevision == runtimeSnapshotRevision.withLock({ $0 }),
          WallpaperSnapshotPixelBudget.acceptsDecodedImage(width: image.width, height: image.height, bytesPerRow: image.bytesPerRow),
          let layout = WallpaperSnapshotPixelBudget.layout(width: Double(canvasSize.width), height: Double(canvasSize.height),
                                                          rowAlignment: IOSurfaceGetPropertyAlignment(kIOSurfaceBytesPerRow),
                                                          allocationAlignment: IOSurfaceGetPropertyAlignment(kIOSurfaceAllocSize)),
          let snapshotClass = objc_getClass("WallpaperSnapshotXPC") as? AnyClass,
          class_getInstanceSize(snapshotClass) >= 8 + MemoryLayout<UnsafeMutableRawPointer>.size else { return nil }
    let width = layout.width
    let height = layout.height
    let surfaceProps: [IOSurfacePropertyKey: any Sendable] = [
        .width: width,
        .height: height,
        .bytesPerElement: 4,
        .bytesPerRow: layout.bytesPerRow,
        .allocSize: layout.allocationBytes,
        .pixelFormat: 0x4247_5241, // 'BGRA'
    ]
    guard let surface = IOSurface(properties: surfaceProps),
          WallpaperSnapshotPixelBudget.accepts(width: surface.width, height: surface.height, bytesPerRow: surface.bytesPerRow),
          surface.allocationSize <= WallpaperSnapshotPixelBudget.maximumPixelBytes else {
        extLog("  [Snapshot] Failed to create IOSurface")
        return nil
    }
    surface.lock(options: [], seed: nil)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: surface.baseAddress,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: surface.bytesPerRow,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    ) else {
        surface.unlock(options: [], seed: nil)
        return nil
    }
    let drewImage = WallpaperSnapshotCropDrawing.draw(
        image: image, in: ctx, targetSize: canvasSize,
        settings: request.cropPreferences.settings(forDisplayID: request.targetDisplayID), alreadyCropped: alreadyCropped)
    surface.unlock(options: [], seed: nil)

    guard drewImage, !Task.isCancelled, request.invalidationRevision == runtimeSnapshotRevision.withLock({ $0 }),
          let instance = class_createInstance(snapshotClass, 0) else {
        extLog("  [Snapshot] ❌ Failed to create WallpaperSnapshotXPC instance")
        return nil
    }

    // 诊断：输出类信息和实例大小，帮助检测 macOS 版本间的布局变化
    let instanceSize = class_getInstanceSize(snapshotClass)
    extLog("  [Snapshot] WallpaperSnapshotXPC instanceSize=\(instanceSize)")

    let surfaceRef = Unmanaged.passRetained(surface).toOpaque()
    let instancePtr = Unmanaged.passUnretained(instance as AnyObject).toOpaque()
    // The real class has a single `rawValue` ivar at offset 8 containing
    // a WallpaperSnapshot struct (8 bytes = IOSurface refcounted pointer).
    instancePtr.advanced(by: 8).storeBytes(of: surfaceRef, as: UnsafeMutableRawPointer.self)
    return instance as AnyObject
}
