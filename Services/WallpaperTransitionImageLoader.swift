import AppKit
import Kingfisher

/// A single selected wallpaper, decoded for the destination viewport while the liquid aperture
/// forms. Uses Kingfisher's shared processed cache and cancellation-aware async download path.
@MainActor
enum WallpaperTransitionImageLoader {
    static func targetPixelSize(viewportSize: CGSize, displayScale: CGFloat) -> CGSize {
        let width = max(1, viewportSize.width) * max(1, displayScale)
        let height = max(1, viewportSize.height) * max(1, displayScale)
        let reduction = min(1, 4096 / max(width, height), sqrt(8_000_000 / (width * height)))
        return CGSize(width: (width * reduction).rounded(.down), height: (height * reduction).rounded(.down))
    }

    private struct MediaIdentity: Equatable {
        let itemID: String
        let coverURL: URL
        let localPath: String?
        let downloadedAt: Date?
        let updatedAt: Date?
        let artifact: SceneBakeArtifact?
        let isBaking: Bool
        let context: LibraryThumbnailLookupContext
    }
    private struct WarmImage {
        let identity: MediaIdentity
        let size: CGSize
        let url: URL
        let image: NSImage
        let createdAt = ProcessInfo.processInfo.systemUptime
    }
    // One hovered item only; never retain a viewport image for every visible card.
    private static var warmImage: WarmImage?
    private static var warmTask: Task<Void, Never>?
    private static var warmingItemID: String?
    private static var warmingIdentity: MediaIdentity?
    private static var warmingSize: CGSize = .zero
    private static var warmGeneration: UInt = 0
    private static var observers: [NSObjectProtocol] = []
    private final class DecodedVariant {
        let itemID: String?
        let url: URL
        let size: CGSize
        var isValid = true
        init(itemID: String?, url: URL, size: CGSize) {
            self.itemID = itemID; self.url = url; self.size = size
        }
    }
    private static var decodedVariants: [DecodedVariant] = []

    private static func imageProcessor(url: URL, size: CGSize) -> any ImageProcessor {
        if url.pathExtension.lowercased() == "gif" {
            return GIFAwareMiddleFrameImageProcessor(targetSize: size, scaleFactor: 1)
        }
        return DownsamplingImageProcessor(size: size)
    }

    private static func evict(_ variant: DecodedVariant) {
        variant.isValid = false
        KingfisherManager.shared.cache.removeImage(forKey: variant.url.cacheKey,
            processorIdentifier: imageProcessor(url: variant.url, size: variant.size).identifier)
    }

    private static func identity(item: MediaItem, record: MediaDownloadRecord?, isBaking: Bool) -> MediaIdentity {
        MediaIdentity(itemID: item.id, coverURL: item.coverImageURL, localPath: record?.localFilePath,
                      downloadedAt: record?.downloadedAt, updatedAt: record?.metadata.updatedAt,
                      artifact: record?.sceneBakeArtifact, isBaking: isBaking,
                      context: VideoThumbnailCache.libraryLookupContext())
    }

    private static func observeInvalidation() {
        guard observers.isEmpty else { return }
        for name in [Notification.Name.sceneOfflineBakeThumbnailDidUpdate, .localMediaPosterDidUpdate,
                     .appDidReceiveMemoryPressure] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { notification in
                guard (notification.userInfo?["lookupOnly"] as? Bool) != true else { return }
                let pressure = notification.name == .appDidReceiveMemoryPressure
                let itemID = notification.object as? String
                let url = notification.userInfo?["thumbnailURL"] as? URL
                MainActor.assumeIsolated {
                    let affectsWarm = pressure || warmImage?.identity.itemID == itemID || warmingItemID == itemID
                    if affectsWarm {
                        warmGeneration &+= 1
                        warmTask?.cancel()
                        warmTask = nil
                        warmingItemID = nil
                        warmImage = nil
                    }
                    decodedVariants.removeAll { variant in
                        let affected = pressure || (itemID != nil && variant.itemID == itemID) || (url != nil && variant.url == url)
                        if affected { evict(variant) }
                        return affected
                    }
                }
            })
        }
    }

    /// Hover prepares existing images only; a speculative request must never queue AVFoundation work.
    static func prewarmMedia(item: MediaItem, viewportSize: CGSize, displayScale: CGFloat) {
        observeInvalidation()
        let record = MediaLibraryService.shared.downloadRecord(for: item.id)
        let baking = SceneOfflineBakeProgressTracker.shared.progress(for: item.id) != nil
        let key = identity(item: item, record: record, isBaking: baking)
        let size = targetPixelSize(viewportSize: viewportSize, displayScale: displayScale)
        if let cached = warmImage, cached.identity == key, cached.size == size,
           ProcessInfo.processInfo.systemUptime - cached.createdAt < 15 { return }
        if warmTask != nil, warmingIdentity == key, warmingSize == size { return }
        warmGeneration &+= 1
        let token = warmGeneration
        warmTask?.cancel()
        warmImage = nil
        warmingItemID = item.id
        warmingIdentity = key
        warmingSize = size
        warmTask = Task { @MainActor in
            defer {
                if warmGeneration == token { warmTask = nil; warmingItemID = nil }
            }
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled,
                  let url = await mediaImageURL(item: item, record: record, isBaking: baking,
                                               allowPosterGeneration: false), !Task.isCancelled,
                  let image = await load(url: url, viewportSize: viewportSize, displayScale: displayScale, itemID: item.id),
                  !Task.isCancelled, warmGeneration == token else { return }
            warmImage = WarmImage(identity: key, size: size, url: url, image: image)
            warmTask = nil
        }
    }

    static func cancelPrewarm(itemID: String) {
        guard warmingItemID == itemID else { return }
        warmGeneration &+= 1
        warmTask?.cancel()
        warmTask = nil
        warmingItemID = nil
    }

    /// Resolve selected media at detail quality before using its catalog/list cover.
    /// A ready hover image bypasses source validation, disk lookup and image decoding on click.
    static func loadMedia(item: MediaItem, record: MediaDownloadRecord?, isBaking: Bool,
                          viewportSize: CGSize, displayScale: CGFloat) async -> NSImage? {
        observeInvalidation()
        guard !Task.isCancelled else { return nil }
        let key = identity(item: item, record: record, isBaking: isBaking)
        let size = targetPixelSize(viewportSize: viewportSize, displayScale: displayScale)
        if let cached = warmImage, cached.identity == key, cached.size == size,
           ProcessInfo.processInfo.systemUptime - cached.createdAt < 15 { return cached.image }
        let token = warmGeneration
        guard let url = await mediaImageURL(item: item, record: record, isBaking: isBaking),
              !Task.isCancelled else { return nil }
        var loadedURL = url
        var image = await load(url: url, viewportSize: viewportSize, displayScale: displayScale, itemID: item.id)
        if image == nil, !Task.isCancelled, url != item.coverImageURL {
            loadedURL = item.coverImageURL
            image = await load(url: loadedURL, viewportSize: viewportSize, displayScale: displayScale, itemID: item.id)
        }
        guard !Task.isCancelled, let image else { return nil }
        if warmGeneration == token {
            warmImage = WarmImage(identity: key, size: size, url: loadedURL, image: image)
        }
        return image
    }

    /// The destination resolves exactly the same source, so its first layout cannot downgrade
    /// the HD reveal to a catalog thumbnail when the overlay hands off.
    static func mediaImageURL(item: MediaItem, record: MediaDownloadRecord?, isBaking: Bool,
                              allowPosterGeneration: Bool = true) async -> URL? {
        guard !Task.isCancelled else { return nil }
        let key = identity(item: item, record: record, isBaking: isBaking)
        if let cached = warmImage, cached.identity == key,
           ProcessInfo.processInfo.systemUptime - cached.createdAt < 15 { return cached.url }
        guard let record else { return item.coverImageURL }
        let cache = VideoThumbnailCache.shared
        let local = record.localFileURL
        let raster = ["jpg", "jpeg", "png", "webp", "gif", "heic", "heif", "avif", "bmp", "tiff", "tif"]
        // Originals and ordinary videos must not queue behind a scene-only directory scan.
        if raster.contains(local.pathExtension.lowercased()) {
            return FileExistenceCache.shared.fileExists(atPath: local.path) ? local : item.coverImageURL
        }
        let directVideo = ["mp4", "mov", "webm", "m4v", "mkv"].contains(local.pathExtension.lowercased())
        if !directVideo {
            if let poster = cache.cachedSceneBakePosterFileURLIfExists(itemID: item.id) { return poster }
            if let poster = cache.latestSceneRealtimePosterFileURLIfExists(itemID: item.id) { return poster }
        }
        let videoURL = localMediaVideoURL(record: record, isBaking: isBaking)
        if let videoURL, let poster = cache.cachedPosterJPEGFileURLIfExists(forLocalVideo: videoURL) {
            return poster
        }
        // Await realtime lookup only for projects without a finished playable source.
        if !directVideo, videoURL == nil {
            let poster = await LibraryThumbnailDiskReader.shared.realtimePoster(
                itemID: item.id, context: VideoThumbnailCache.libraryLookupContext())
            guard !Task.isCancelled else { return nil }
            if let poster { return poster }
        }
        if !allowPosterGeneration, videoURL != nil { return nil }
        if allowPosterGeneration, let videoURL {
            let poster = await cache.posterJPEGFileURL(forLocalVideo: videoURL)
            guard !Task.isCancelled else { return nil }
            if let poster { return poster }
        }
        guard !Task.isCancelled else { return nil }
        let imageURL = await Task.detached(priority: .userInitiated) {
            MediaItem.resolveLocalWorkshopPreviewImage(from: local)
        }.value
        guard !Task.isCancelled else { return nil }
        return imageURL ?? item.coverImageURL
    }

    /// Shared with the destination's early playback gate. Do not recursively choose an arbitrary
    /// MP4 from a scene/web project: those are composition assets rather than the finished picture.
    static func localMediaVideoURL(record: MediaDownloadRecord?, isBaking: Bool) -> URL? {
        guard let record else { return nil }
        if !isBaking, let artifact = SceneOfflineBakeService.usableArtifact(from: record) {
            return URL(fileURLWithPath: artifact.videoPath)
        }
        let local = record.localFileURL
        let videoExtensions: Set<String> = ["mp4", "mov", "webm", "m4v", "mkv"]
        if videoExtensions.contains(local.pathExtension.lowercased()),
           FileExistenceCache.shared.fileExists(atPath: local.path) { return local }
        guard MediaItem.localWorkshopProjectType(from: local) == "video" else { return nil }
        return MediaItem.resolveLocalVideoFile(from: local)
    }

    static func load(url: URL?, viewportSize: CGSize, displayScale: CGFloat, itemID: String? = nil) async -> NSImage? {
        guard let url, !Task.isCancelled else { return nil }
        observeInvalidation()
        let size = targetPixelSize(viewportSize: viewportSize, displayScale: displayScale)
        let variant: DecodedVariant
        if let existing = decodedVariants.first(where: { $0.itemID == itemID && $0.url == url && $0.size == size }) {
            variant = existing
        } else {
            if decodedVariants.count >= 2 { evict(decodedVariants.removeFirst()) }
            variant = DecodedVariant(itemID: itemID, url: url, size: size)
            decodedVariants.append(variant)
        }
        do {
            let source: Source = url.isFileURL
                ? .provider(LocalFileImageDataProvider(fileURL: url)) : .network(KF.ImageResource(downloadURL: url))
            let result = try await KingfisherManager.shared.retrieveImage(with: source, options: [
                .processor(imageProcessor(url: url, size: size)),
                .scaleFactor(1), .backgroundDecode, .onlyLoadFirstFrame,
                .cacheMemoryOnly, .downloadPriority(0.8)
            ])
            guard variant.isValid else { evict(variant); return nil }
            guard !Task.isCancelled else { return nil }
            return result.image
        } catch {
            // The existing cover remains the reveal seed; the real detail can retry normally.
            return nil
        }
    }
}
