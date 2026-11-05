// Pure snapshot inputs and CoreGraphics drawing. No remote context, player or surface allocation.
import CoreGraphics
import Foundation

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

struct WallpaperSnapshotTargetGeometry: Sendable, Equatable {
    let width: Double
    let height: Double

    init?(size: CGSize, scale: CGFloat = 1) {
        let pixelSize = CGSize(width: size.width * scale, height: size.height * scale)
        guard scale.isFinite, scale > 0, ExtDisplayGeometry.isValid(size: pixelSize) else { return nil }
        width = Double(pixelSize.width)
        height = Double(pixelSize.height)
    }

    var size: CGSize { CGSize(width: width, height: height) }
}

/// Capture crop bytes as well as the revision: settings changed in-place must
/// invalidate a successful cache even when filesystem timestamps are coarse.
struct WallpaperSnapshotCropPreferences: Sendable, Equatable {
    let revision: WallpaperSnapshotFileRevision?
    let data: Data?

    init(in container: URL?) {
        guard let container else {
            revision = nil
            data = nil
            return
        }
        let file = WallpaperSnapshotFileRevision(container.appendingPathComponent("waifux-crop-prefs.json"))
        revision = file
        if let size = file.fileSize, size >= 0, size <= 131_072 {
            data = try? Data(contentsOf: file.url)
        } else {
            data = nil
        }
    }

    func settings(forDisplayID displayID: UInt32) -> ExtCropSettings {
        guard let data,
              let settings = try? JSONDecoder().decode([String: ExtCropSettings].self, from: data) else { return .default }
        return settings["display-\(displayID)"] ?? .default
    }
}

struct WallpaperSnapshotSources: Sendable, Equatable {
    let images: [WallpaperSnapshotFileRevision]
    let video: WallpaperSnapshotFileRevision?

    static func resolve(
        in container: URL, currentImagePath: String?, currentVideoPath: String?
    ) -> WallpaperSnapshotSources {
        let imageURLs = imageCandidateURLs(in: container, currentImagePath: currentImagePath, currentVideoPath: currentVideoPath)
        let root = container.standardizedFileURL.path + "/"
        return WallpaperSnapshotSources(
            images: imageURLs.map { WallpaperSnapshotFileRevision($0, readMetadata: $0.standardizedFileURL.path.hasPrefix(root)) },
            video: currentVideoPath.flatMap { $0.isEmpty ? nil : WallpaperSnapshotFileRevision(URL(fileURLWithPath: $0), readMetadata: false) }
        )
    }

    static func imageCandidateURLs(in container: URL, currentImagePath: String?, currentVideoPath: String?) -> [URL] {
        var candidates: [URL] = []
        if let currentImagePath, !currentImagePath.isEmpty { candidates.append(URL(fileURLWithPath: currentImagePath)) }
        if let currentVideoPath, !currentVideoPath.isEmpty {
            let videoID = URL(fileURLWithPath: currentVideoPath).deletingPathExtension().lastPathComponent
            candidates.append(container.appendingPathComponent("WallpaperCache/thumbnails/\(videoID).jpg"))
        }
        // Never select an unrelated old JPG merely because its name starts
        // with display-N. Only the current video's basename identifies its JPG.
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

}

/// Kept independent from the IOSurface implementation so the real cache-key
/// equality and drawing can be regression tested without allocating a surface.
struct SnapshotRequest: Sendable, Equatable {
    let displayID: UInt32?
    let targetDisplayID: UInt32
    let sources: WallpaperSnapshotSources
    let playbackTime: Double?
    let prefsRevision: WallpaperSnapshotFileRevision?
    let thumbnailsRevision: WallpaperSnapshotFileRevision?
    let selectedVideoID: String?
    let targetGeometry: WallpaperSnapshotTargetGeometry?
    let cropPreferences: WallpaperSnapshotCropPreferences
    let invalidationRevision: UInt64

    // Same-token readiness may fail transiently while the runtime snapshot
    // class/context becomes available. Bound retries to four per second rather
    // than poisoning the host's short readiness budget with a five-second miss.
    // Ordinary system requests keep their existing failure throttle.
    var failureCacheLifetime: TimeInterval { 5 }

    // A moving timebase is not a new snapshot. Geometry, crop and poster file
    // revisions are: none may reuse a successful surface for different pixels.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.displayID == rhs.displayID && lhs.targetDisplayID == rhs.targetDisplayID
            && lhs.sources == rhs.sources && lhs.prefsRevision == rhs.prefsRevision
            && lhs.thumbnailsRevision == rhs.thumbnailsRevision && lhs.selectedVideoID == rhs.selectedVideoID
            && lhs.targetGeometry == rhs.targetGeometry && lhs.cropPreferences == rhs.cropPreferences
            && lhs.invalidationRevision == rhs.invalidationRevision
    }
}

enum WallpaperSnapshotCropDrawing {
    /// Use the same bottom-left layer geometry as the live crop path. Filling
    /// before clipping preserves letterbox color; clipping prevents pan/zoom
    /// overflow from painting into the bars. The CGContext owns no extra bitmap.
    @discardableResult
    static func draw(
        image: CGImage, in context: CGContext, targetSize: CGSize,
        settings: ExtCropSettings, alreadyCropped: Bool = false
    ) -> Bool {
        let canvas = CGRect(x: 0, y: 0, width: context.width, height: context.height)
        guard ExtDisplayGeometry.isValid(size: targetSize),
              WallpaperSnapshotPixelBudget.accepts(width: context.width, height: context.height, bytesPerRow: context.bytesPerRow),
              WallpaperSnapshotPixelBudget.acceptsDecodedImage(width: image.width, height: image.height, bytesPerRow: image.bytesPerRow) else { return false }
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: canvas)
        if alreadyCropped {
            // Scene posters already contain the exact target canvas, including
            // crop and bars. Scaling that canvas must not apply crop a second time.
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(canvas)
            context.draw(image, in: canvas)
            return true
        }
        let effectiveSettings = settings.shouldApplyCrop ? settings : .default
        let layout = ExtCropEngine.compute(
            wallpaperSize: CGSize(width: image.width, height: image.height),
            screenSize: targetSize, settings: effectiveSettings)
        let geometry = ExtCropGeometry.layerGeometry(layout: layout, in: canvas)
        context.setFillColor(layout.letterboxColor)
        context.fill(canvas)
        context.clip(to: geometry.viewportRect)
        context.draw(image, in: geometry.videoFrame)
        return true
    }
}
