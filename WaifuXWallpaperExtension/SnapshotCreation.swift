//  IOSurface snapshot creation for WallpaperAgent.

@preconcurrency import AVFoundation
import CoreMedia
import ImageIO
@preconcurrency import IOSurface

struct WallpaperSnapshotFileRevision: Sendable, Equatable {
    let url: URL
    let modified: Date?
    let fileSize: Int?

    init(_ url: URL, readMetadata: Bool = true) {
        self.url = url
        let values = readMetadata ? (try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])) : nil
        modified = values?.contentModificationDate
        fileSize = values?.fileSize
    }
}

private struct SnapshotRequest: Sendable, Equatable {
    let displayID: UInt32?
    let images: [WallpaperSnapshotFileRevision]
    let video: WallpaperSnapshotFileRevision?
    let playbackTime: Double?
    let prefsRevision: WallpaperSnapshotFileRevision?
    let thumbnailsRevision: WallpaperSnapshotFileRevision?
    let selectedVideoID: String?

    // A cached image/surface remains valid for unchanged media. The timebase
    // continues across loops and is not a reason to allocate another surface.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.displayID == rhs.displayID && lhs.images == rhs.images && lhs.video == rhs.video && lhs.prefsRevision == rhs.prefsRevision
            && lhs.thumbnailsRevision == rhs.thumbnailsRevision && lhs.selectedVideoID == rhs.selectedVideoID
    }
}

private final class SnapshotResult: @unchecked Sendable {
    let value: AnyObject?
    init(_ value: AnyObject?) { self.value = value }
}

// Pending requests are independent per display, while only one completed
// IOSurface is retained by our cache across all displays.
private let snapshotWork = LatestWallpaperSnapshotWork<SnapshotRequest, SnapshotResult>(maximumKeys: 16, maximumCachedKeys: 1,
                                                                                       key: { $0.displayID ?? 0 },
                                                                                       cacheLifetime: { $0.value == nil ? 5 : .infinity }) { request in
    await wallpaperSnapshotDecodeGate.perform { SnapshotResult(await buildSnapshot(request)) }
}

func requestSnapshotViaRuntime(displayID: UInt32? = nil, currentTime: CMTime? = nil, reply: @escaping @Sendable (AnyObject?) -> Void) {
    let images: [WallpaperSnapshotFileRevision]
    let prefsRevision: WallpaperSnapshotFileRevision?
    let thumbnailsRevision: WallpaperSnapshotFileRevision?
    if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.waifux.app") {
        images = sharedSnapshotCandidateURLs(in: container, displayID: displayID).map {
            WallpaperSnapshotFileRevision($0, readMetadata: $0.path.hasPrefix(container.path + "/"))
        }
        prefsRevision = WallpaperSnapshotFileRevision(container.appendingPathComponent("waifux-wallpaper-prefs.json"))
        thumbnailsRevision = WallpaperSnapshotFileRevision(container.appendingPathComponent("WallpaperCache/thumbnails"))
    } else {
        images = []
        prefsRevision = nil
        thumbnailsRevision = nil
    }
    // External media stat/decode stays inside the single worker. Snapshot's
    // XPC entry point reads only the small shared configuration/cache metadata.
    let video = currentPrefsPath("currentVideoPath", displayID: displayID).map {
        WallpaperSnapshotFileRevision(URL(fileURLWithPath: $0), readMetadata: false)
    }
    let time = currentTime.flatMap { $0.isNumeric && $0.seconds.isFinite ? $0.seconds : nil }
    snapshotWork.submit(SnapshotRequest(displayID: displayID, images: images, video: video, playbackTime: time,
                                       prefsRevision: prefsRevision, thumbnailsRevision: thumbnailsRevision,
                                       selectedVideoID: WallpaperState.shared.currentVideoID)) { result in
        reply(result?.value)
    }
}

private func buildSnapshot(_ request: SnapshotRequest) async -> AnyObject? {
    guard !Task.isCancelled else { return nil }
    for revision in request.images {
        guard !Task.isCancelled else { return nil }
        if let image = loadBudgetedSnapshotImage(revision.url),
           let snapshot = renderSnapshotToIOSurface(image: image) { return snapshot }
    }
    guard !Task.isCancelled else { return nil }
    let surfaceRenderer: IOSurfaceFrameRenderer?
    if let displayID = request.displayID {
        surfaceRenderer = WallpaperState.shared.ioSurfaceRenderer(for: displayID)
    } else {
        surfaceRenderer = WallpaperState.shared.anyIOSurfaceRenderer()
    }
    if let snapshot = surfaceRenderer?.makeSnapshotXPC() { return snapshot }
    guard let videoURL = request.video?.url ?? (request.displayID == nil ? findVideoURL() : nil) else { return nil }
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
    guard !Task.isCancelled else { return nil }
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
        guard !Task.isCancelled else { return nil }
        image = result.image
    } catch {
        extLog("  [Snapshot] Failed to get video frame: \(error)")
        return nil
    }
    guard let snapshotXPC = renderSnapshotToIOSurface(image: image) else { return nil }
    extLog("  [Snapshot] Created WallpaperSnapshotXPC \(image.width)x\(image.height)")
    return snapshotXPC
}

func loadBudgetedSnapshotImage(_ url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
          let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { return nil }
    let depth = min(32, max(8, (properties[kCGImagePropertyDepth] as? NSNumber)?.intValue ?? 16))
    guard let layout = WallpaperSnapshotPixelBudget.layout(width: width.doubleValue, height: height.doubleValue,
                                                          decodedBytesPerPixel: ((depth + 7) / 8) * 4) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceShouldAllowFloat: false,
        kCGImageSourceThumbnailMaxPixelSize: max(layout.width, layout.height),
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
          WallpaperSnapshotPixelBudget.acceptsDecodedImage(width: image.width, height: image.height, bytesPerRow: image.bytesPerRow) else { return nil }
    return image
}

private func sharedSnapshotCandidateURLs(in container: URL, displayID: UInt32?) -> [URL] {
    var candidates: [URL] = []

    if let imagePath = currentPrefsPath("currentImagePath", displayID: displayID) {
        candidates.append(URL(fileURLWithPath: imagePath))
    }

    let thumbDir = container.appendingPathComponent("WallpaperCache/thumbnails")
    if let latestDisplayThumb = latestDisplayThumbnail(in: thumbDir, displayID: displayID) {
        candidates.append(latestDisplayThumb)
    }

    if let videoPath = currentPrefsPath("currentVideoPath", displayID: displayID) {
        let videoID = URL(fileURLWithPath: videoPath).deletingPathExtension().lastPathComponent
        candidates.append(thumbDir.appendingPathComponent("\(videoID).jpg"))
    }

    var seen = Set<String>()
    return candidates.filter { seen.insert($0.path).inserted }
}

private func currentPrefsPath(_ key: String, displayID: UInt32?) -> String? {
    guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.waifux.app") else {
        return nil
    }
    let prefsURL = container.appendingPathComponent("waifux-wallpaper-prefs.json")
    guard let data = try? Data(contentsOf: prefsURL),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    if let displayID {
        return LockScreenSourceSelection.path(
            for: key == "currentVideoPath" ? .video : .image, displayID: displayID,
            videoPaths: object["currentVideoPaths"] as? [String: String],
            imagePaths: object["currentImagePaths"] as? [String: String],
            legacyVideoPath: object["currentVideoPath"] as? String,
            legacyImagePath: object["currentImagePath"] as? String
        )
    }
    guard let path = object[key] as? String, !path.isEmpty else { return nil }
    return path
}

private func latestDisplayThumbnail(in thumbDir: URL, displayID: UInt32?) -> URL? {
    guard let files = try? FileManager.default.contentsOfDirectory(
        at: thumbDir,
        includingPropertiesForKeys: [.contentModificationDateKey]
    ) else {
        return nil
    }

    return files
        .filter { file in
            guard file.pathExtension.lowercased() == "jpg" else { return false }
            let name = file.deletingPathExtension().lastPathComponent
            guard let displayID else { return name.hasPrefix("display-") }
            let prefix = "display-\(displayID)"
            return name == prefix || name.hasPrefix(prefix + "-")
        }
        .max { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if lhsDate == rhsDate {
                return lhs.lastPathComponent < rhs.lastPathComponent
            }
            return lhsDate < rhsDate
        }
}

private func renderSnapshotToIOSurface(image: CGImage) -> AnyObject? {
    guard !Task.isCancelled,
          WallpaperSnapshotPixelBudget.acceptsDecodedImage(width: image.width, height: image.height, bytesPerRow: image.bytesPerRow),
          let layout = WallpaperSnapshotPixelBudget.layout(width: Double(image.width), height: Double(image.height),
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
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    surface.unlock(options: [], seed: nil)

    guard !Task.isCancelled, let instance = class_createInstance(snapshotClass, 0) else {
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
