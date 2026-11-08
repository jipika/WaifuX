import Foundation
import AVFoundation
import AppKit
import CryptoKit
import ImageIO
import Kingfisher

/// 串行化高成本的 AVFoundation 抽帧，并将同一输出文件的请求合并为一个任务。
/// 海报生成会解码高分辨率视频帧，允许多个任务同时运行会迅速耗尽 CPU 和内存。
private actor VideoPosterGenerationCoordinator {
    static let shared = VideoPosterGenerationCoordinator()

    private let maxConcurrentGenerations = 1
    private var activeGenerations = 0
    private var waitingGenerations: [CheckedContinuation<Void, Never>] = []
    private var tasks: [String: Task<URL?, Never>] = [:]

    func generate(
        key: String,
        operation: @escaping @Sendable () async -> URL?
    ) async -> URL? {
        if let task = tasks[key] {
            return await task.value
        }

        let task = Task.detached(priority: .utility) { [operation] () -> URL? in
            await self.acquireSlot()
            let result = await operation()
            await self.releaseSlot()
            return result
        }
        tasks[key] = task

        let result = await task.value
        tasks.removeValue(forKey: key)
        return result
    }

    private func acquireSlot() async {
        if activeGenerations < maxConcurrentGenerations {
            activeGenerations += 1
            return
        }
        await withCheckedContinuation { continuation in
            waitingGenerations.append(continuation)
        }
    }

    private func releaseSlot() {
        if let next = waitingGenerations.first {
            waitingGenerations.removeFirst()
            next.resume()
        } else {
            activeGenerations = max(0, activeGenerations - 1)
        }
    }
}

/// 列表小图抽帧限并发（外置卡上同时 N 路 AVAsset 会全卡死）。
private actor VideoListThumbnailGenerationCoordinator {
    static let shared = VideoListThumbnailGenerationCoordinator()
    private let maxConcurrentGenerations = 2
    private var activeGenerations = 0
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }
    private struct Job {
        let token: UUID
        let task: Task<URL?, Never>
        var consumers: Set<UUID>
    }
    private var waitingGenerations: [Waiter] = []
    private var tasks: [String: Job] = [:]

    func generate(key: String, operation: @escaping @Sendable () async -> URL?) async -> URL? {
        guard !Task.isCancelled else { return nil }
        let consumer = UUID()
        let job: Job
        if var current = tasks[key] {
            current.consumers.insert(consumer)
            tasks[key] = current
            job = current
        } else {
            let token = UUID()
            let task = Task.detached(priority: .utility) { [operation] () -> URL? in
                guard await self.acquireSlot() else { return nil }
                guard !Task.isCancelled else {
                    await self.releaseSlot()
                    return nil
                }
                let result = await operation()
                await self.releaseSlot()
                return Task.isCancelled ? nil : result
            }
            job = Job(token: token, task: task, consumers: [consumer])
            tasks[key] = job
        }
        let result = await withTaskCancellationHandler {
            await job.task.value
        } onCancel: {
            Task { await self.removeConsumer(key: key, token: job.token, consumer: consumer) }
        }
        removeConsumer(key: key, token: job.token, consumer: consumer)
        return Task.isCancelled ? nil : result
    }

    private func removeConsumer(key: String, token: UUID, consumer: UUID) {
        guard var job = tasks[key], job.token == token, job.consumers.remove(consumer) != nil else { return }
        if job.consumers.isEmpty {
            tasks.removeValue(forKey: key)
            job.task.cancel()
        } else { tasks[key] = job }
    }

    private func acquireSlot() async -> Bool {
        guard !Task.isCancelled else { return false }
        if activeGenerations < maxConcurrentGenerations {
            activeGenerations += 1
            return true
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: false) }
                else { waitingGenerations.append(Waiter(id: id, continuation: continuation)) }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waitingGenerations.firstIndex(where: { $0.id == id }) else { return }
        waitingGenerations.remove(at: index).continuation.resume(returning: false)
    }

    private func releaseSlot() {
        if !waitingGenerations.isEmpty {
            waitingGenerations.removeFirst().continuation.resume(returning: true)
        } else { activeGenerations = max(0, activeGenerations - 1) }
    }
}

/// UI 只传不可变路径快照；这里不持有服务单例，也不解析 security-scoped bookmark。
struct LibraryThumbnailLookupContext: Hashable, Sendable {
    let root: URL
    let videoCache: URL
    let imageCache: URL

    var covers: URL { root.appendingPathComponent("Covers", isDirectory: true) }
}

struct LibraryThumbnailLookupRequest: Hashable, Sendable {
    let itemID: String
    let localFileURL: URL?
    let bakedVideoURL: URL?
    let bakedArtifact: SceneBakeArtifact?
    let posterURL: URL?
    let thumbnailURL: URL
    let context: LibraryThumbnailLookupContext
    let isFolderPreview: Bool
}

struct LibraryThumbnailResolution: Sendable {
    var thumbnailURL: URL? = nil
    var videoURL: URL? = nil
    var hasListThumbnail = false
    var localGIFURL: URL? = nil
    var lookupRequest: LibraryThumbnailLookupRequest? = nil
    var lookupToken: UUID? = nil
    var isDeferred = false
}

/// 只在自己的串行 utility 队列访问索引；慢卷最多一路读，不会随几千张列表一起抽帧。
/// 索引只读文件名/日期，图片解码只针对被请求的那一项，而不是把整个 Covers 都打开一遍。
final class LibraryThumbnailDiskReader: @unchecked Sendable {
    static let shared = LibraryThumbnailDiskReader()
    private let queue = DispatchQueue(label: "com.waifux.library-thumbnail-lookup", qos: .utility)
    private struct Poster {
        let url: URL
        let date: Date
    }
    private struct Index {
        let builtAt: Date
        let posters: [String: [Poster]]
    }
    private var indexes: [LibraryThumbnailLookupContext: Index] = [:]

    private final class Ticket: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }
        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }
    }

    private enum Work: Sendable {
        case item(LibraryThumbnailLookupRequest)
        case poster(String, LibraryThumbnailLookupContext)
    }
    private struct Job: Sendable {
        let submittedAt = ProcessInfo.processInfo.systemUptime
        let id: UUID
        let ticket: Ticket
        let work: Work
        var prioritizeVisible: Bool
        let complete: @Sendable (LibraryThumbnailResolution) -> Void
    }
    private let pendingLock = NSLock()
    private var pending: [Job] = []
    private var draining = false
    private var indexInvalidationPending = false
    private let maximumPendingJobs = 128

    func resolve(_ request: LibraryThumbnailLookupRequest, prioritizeVisible: Bool = false) async -> LibraryThumbnailResolution {
        await submit(.item(request), prioritizeVisible: prioritizeVisible)
    }

    func realtimePoster(itemID: String, context: LibraryThumbnailLookupContext) async -> URL? {
        let result = await submit(.poster(itemID, context), prioritizeVisible: true)
        return result.thumbnailURL
    }

    /// 主线程只改有界队列表；不会等待磁盘队列，也不会再为每代128项累积dispatch闭包。
    func promote(_ request: LibraryThumbnailLookupRequest) {
        pendingLock.lock()
        if let index = pending.firstIndex(where: {
            if case .item(let candidate) = $0.work { return candidate == request }
            return false
        }) {
            var job = pending.remove(at: index)
            job.prioritizeVisible = true
            pending.insert(job, at: 0)
        }
        pendingLock.unlock()
    }

    private func submit(_ work: Work, prioritizeVisible: Bool) async -> LibraryThumbnailResolution {
        let id = UUID()
        let ticket = Ticket()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let job = Job(id: id, ticket: ticket, work: work, prioritizeVisible: prioritizeVisible,
                    complete: { continuation.resume(returning: $0) })
                var evicted: Job?
                pendingLock.lock()
                if ticket.isCancelled {
                    pendingLock.unlock()
                    continuation.resume(returning: LibraryThumbnailResolution())
                    return
                }
                if pending.count >= maximumPendingJobs, prioritizeVisible,
                   let index = pending.firstIndex(where: { !$0.prioritizeVisible }) {
                    evicted = pending.remove(at: index)
                }
                guard pending.count < maximumPendingJobs else {
                    pendingLock.unlock()
                    continuation.resume(returning: LibraryThumbnailResolution(isDeferred: true))
                    return
                }
                if prioritizeVisible { pending.insert(job, at: 0) } else { pending.append(job) }
                let shouldStart = !draining
                draining = true
                pendingLock.unlock()
                evicted?.ticket.cancel()
                evicted?.complete(LibraryThumbnailResolution(isDeferred: true))
                if shouldStart { queue.async { self.drain() } }
            }
        } onCancel: {
            ticket.cancel()
            self.cancelPendingJob(id: id)
        }
    }

    private func cancelPendingJob(id: UUID) {
        pendingLock.lock()
        let job = pending.firstIndex(where: { $0.id == id }).map { pending.remove(at: $0) }
        pendingLock.unlock()
        job?.complete(LibraryThumbnailResolution())
    }

    private func drain() {
        while true {
            pendingLock.lock()
            guard !pending.isEmpty else {
                draining = false
                pendingLock.unlock()
                return
            }
            let job = pending.removeFirst()
            let remaining = pending.count
            let invalidateIndex = indexInvalidationPending
            indexInvalidationPending = false
            pendingLock.unlock()
            if invalidateIndex { indexes.removeAll() }
            guard !job.ticket.isCancelled else {
                job.complete(LibraryThumbnailResolution())
                continue
            }
            let readStart = ProcessInfo.processInfo.systemUptime
            let kind: String
            switch job.work {
            case .item(let request):
                kind = "item"
                job.complete(read(request, ticket: job.ticket))
            case .poster(let itemID, let context):
                kind = "poster"
                let poster = latestRealtimePoster(itemID: itemID, context: context, ticket: job.ticket)
                job.complete(LibraryThumbnailResolution(thumbnailURL: poster))
            }
            InteractionPerformanceLog.record(.thumbnailIO, since: job.submittedAt, metadata: [
                "kind": kind,
                "queueMS": String(Int((readStart - job.submittedAt) * 1000)),
                "readMS": String(Int((ProcessInfo.processInfo.systemUptime - readStart) * 1000)),
                "pending": String(remaining),
                "cancelled": job.ticket.isCancelled ? "1" : "0"
            ])
        }
    }

    func invalidateRealtimeIndex() {
        pendingLock.lock()
        indexInvalidationPending = true
        pendingLock.unlock()
    }

    private func read(_ request: LibraryThumbnailLookupRequest, ticket: Ticket) -> LibraryThumbnailResolution {
        let context = request.context
        let fm = FileManager.default
        let gifPreview: URL?
        if let local = request.localFileURL, local.isFileURL {
            let ext = local.pathExtension.lowercased()
            if ext == "gif" {
                gifPreview = fm.fileExists(atPath: local.path) ? local : nil
            } else if !["mp4", "mov", "webm", "m4v", "mkv"].contains(ext),
                      !LocalImageThumbnailCache.isRasterImageFile(local) {
                gifPreview = MediaItem.resolveLocalWorkshopPreviewGIF(from: local)
            } else { gifPreview = nil }
        } else { gifPreview = nil }
        func result(_ url: URL?, video: URL? = nil, list: Bool = false) -> LibraryThumbnailResolution {
            LibraryThumbnailResolution(thumbnailURL: url, videoURL: request.bakedVideoURL ?? video,
                hasListThumbnail: list && (request.bakedVideoURL == nil || video == request.bakedVideoURL), localGIFURL: gifPreview)
        }
        func staticMetadata() -> URL? {
            [request.posterURL, Optional(request.thumbnailURL)].compactMap { $0 }.first {
                !MediaItem.urlLooksLikeGIF($0) && (!$0.isFileURL || fm.fileExists(atPath: $0.path))
            }
        }
        func videoThumbnail(_ video: URL) -> LibraryThumbnailResolution? {
            let path = video.standardizedFileURL.path
            let list = context.videoCache.appendingPathComponent("list_\(path.md5).jpg", isDirectory: false)
            if Self.isUsableImage(at: list) { return result(list, video: video, list: true) }
            let rootPath = context.root.standardizedFileURL.path
            let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            let relativeKey = path.hasPrefix(prefix) ? "lib:" + String(path.dropFirst(prefix.count)) : path
            let posters = [
                context.covers.appendingPathComponent("poster_wallpaper_\(relativeKey.md5).jpg", isDirectory: false),
                context.videoCache.appendingPathComponent("poster_wallpaper_\(path.md5).jpg", isDirectory: false)
            ]
            if let poster = posters.first(where: { Self.isUsableImage(at: $0) }) {
                return result(poster, video: video)
            }
            return nil
        }
        func bakePoster() -> URL? {
            let name = "scene_bake_\(request.itemID.md5).jpg"
            return [context.covers, context.videoCache]
                .map { $0.appendingPathComponent(name, isDirectory: false) }
                .first { Self.isUsableImage(at: $0) }
        }

        if let baked = request.bakedVideoURL {
            let path = baked.standardizedFileURL.path
            let list = context.videoCache.appendingPathComponent("list_\(path.md5).jpg", isDirectory: false)
            if Self.isUsableImage(at: list) { return result(list, video: baked, list: true) }
            if let poster = bakePoster() { return result(poster, video: baked) }
        }
        // Web截图也写scene_bake poster而没有MP4；grid与folder都必须保留该高清优先级。
        if let poster = bakePoster() { return result(poster, video: request.bakedVideoURL) }
        guard !ticket.isCancelled else { return result(nil) }
        if let poster = latestRealtimePoster(itemID: request.itemID, context: context, ticket: ticket) {
            return result(poster, video: request.bakedVideoURL)
        }
        guard !ticket.isCancelled else { return result(nil) }
        let fallback = staticMetadata()
        guard let local = request.localFileURL, local.isFileURL,
              fm.fileExists(atPath: local.path) else {
            return result(fallback, video: request.bakedVideoURL)
        }
        let ext = local.pathExtension.lowercased()
        if ext == "gif" {
            var resolved = result(fallback ?? local)
            resolved.localGIFURL = local
            return resolved
        }
        if LocalImageThumbnailCache.isRasterImageFile(local) {
            return result(Self.localImageThumbnail(for: local, context: context) ?? fallback ?? local)
        }
        if ["mp4", "mov", "webm", "m4v", "mkv"].contains(ext) {
            return videoThumbnail(local) ?? result(fallback, video: local)
        }
        guard !ticket.isCancelled else { return result(nil) }
        // Workshop 解析只在后台按需进行，列表 map/滚动 configure 不再递归读整个工程。
        let video = MediaItem.resolveLocalVideoFile(from: local)
        if let video, let cached = videoThumbnail(video) { return cached }
        guard !ticket.isCancelled else { return result(nil) }
        if let preview = MediaItem.resolveLocalWorkshopPreviewImage(from: local) {
            if MediaItem.urlLooksLikeGIF(preview) {
                var resolved = result(fallback ?? preview, video: request.bakedVideoURL ?? video)
                resolved.localGIFURL = preview
                return resolved
            }
            if LocalImageThumbnailCache.isRasterImageFile(preview) {
                return result(Self.localImageThumbnail(for: preview, context: context) ?? fallback ?? preview, video: request.bakedVideoURL ?? video)
            }
            return result(preview, video: request.bakedVideoURL ?? video)
        }
        return result(fallback, video: request.bakedVideoURL ?? video)
    }

    private func latestRealtimePoster(itemID: String, context: LibraryThumbnailLookupContext, ticket: Ticket) -> URL? {
        let snapshot: Index
        if let cached = indexes[context], Date().timeIntervalSince(cached.builtAt) < 10 {
            snapshot = cached
        } else {
            var posters: [String: [Poster]] = [:]
            let fm = FileManager.default
            let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
            for directory in [context.covers, context.videoCache] {
                guard let files = fm.enumerator(at: directory, includingPropertiesForKeys: keys,
                    options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else { continue }
                for case let file as URL in files {
                    guard !ticket.isCancelled else { return nil }
                    let name = file.lastPathComponent
                    let prefix = "scene_realtime_"
                    guard name.hasPrefix(prefix), file.pathExtension.lowercased() == "jpg" else { continue }
                    let body = name.dropFirst(prefix.count)
                    guard let separator = body.firstIndex(of: "_") else { continue }
                    let itemKey = String(body[..<separator])
                    let values = try? file.resourceValues(forKeys: Set(keys))
                    guard !itemKey.isEmpty, values?.isRegularFile != false else { continue }
                    posters[itemKey, default: []].append(Poster(url: file, date: values?.contentModificationDate ?? .distantPast))
                }
            }
            // TTL 从完成时计时；慢卷扫描超过 TTL 不会导致下一条请求立即重新全扫。
            snapshot = Index(builtAt: Date(), posters: posters)
            if indexes.count >= 4 { indexes.removeAll() }
            indexes[context] = snapshot
        }
        return snapshot.posters[itemID.md5, default: []].sorted { $0.date > $1.date }
            .first { !ticket.isCancelled && Self.isUsableImage(at: $0.url) }?.url
    }

    static func isUsableImage(at url: URL, minimumBytes: Int = 500) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber, size.intValue > minimumBytes,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetStatus(source) == .statusComplete else { return false }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 1,
            kCGImageSourceShouldCache: false
        ] as CFDictionary) != nil
    }

    private static func localImageThumbnail(for source: URL, context: LibraryThumbnailLookupContext) -> URL? {
        let path = source.standardizedFileURL.path
        let output = context.imageCache.appendingPathComponent("img_\(path.md5)_768.jpg", isDirectory: false)
        if isUsableImage(at: output, minimumBytes: 400) { return output }
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 768,
                kCGImageSourceShouldCache: false
              ] as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        do {
            try FileManager.default.createDirectory(at: context.imageCache, withIntermediateDirectories: true)
            try (data as Data).write(to: output, options: .atomic)
            return output
        } catch { return nil }
    }
}

/// 视频缩略图缓存服务
/// 为本地视频文件生成并缓存缩略图
@MainActor
final class VideoThumbnailCache {
    static let shared = VideoThumbnailCache()

    /// 只读取已保存的展示路径，不触发 rootFolderURL 的书签解析、stat 或建目录。
    /// 真正写入/应用壁纸仍使用 DownloadPathManager 的授权与可用性校验。
    static func libraryLookupContext() -> LibraryThumbnailLookupContext {
        let fm = FileManager.default
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        if BackgroundRuntimeRole.isIsolatedTest,
           let path = ProcessInfo.processInfo.environment["WAIFUX_HELPER_TEST_ROOT"] {
            let root = URL(fileURLWithPath: path, isDirectory: true)
            return LibraryThumbnailLookupContext(root: root.appendingPathComponent("WaifuX", isDirectory: true),
                videoCache: root.appendingPathComponent("VideoThumbnails", isDirectory: true),
                imageCache: root.appendingPathComponent("LocalImageThumbnails", isDirectory: true))
        }
        let root: URL
        if let snapshot = DownloadPathManager.shared.libraryRootFolderURLSnapshot {
            root = snapshot
        } else if let path = WaifuXPreferences.shared.string(forKey: DownloadPathManager.customDownloadRootPathKey),
           !path.isEmpty {
            root = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("WaifuX", isDirectory: true)
        } else {
            root = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("WaifuX", isDirectory: true)
        }
        return LibraryThumbnailLookupContext(root: root,
            videoCache: caches.appendingPathComponent("WaifuX/VideoThumbnails", isDirectory: true),
            imageCache: caches.appendingPathComponent("WaifuX/LocalImageThumbnails", isDirectory: true))
    }

    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    private let memoryCache = NSCache<NSString, NSImage>()
    
    private init() {
        // 设置缓存目录
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
        if BackgroundRuntimeRole.isIsolatedTest, let root = ProcessInfo.processInfo.environment["WAIFUX_HELPER_TEST_ROOT"] {
            cacheDirectory = URL(fileURLWithPath: root).appendingPathComponent("VideoThumbnails", isDirectory: true)
        } else {
            cacheDirectory = caches[0].appendingPathComponent("WaifuX/VideoThumbnails", isDirectory: true)
        }
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        memoryCache.countLimit = 50
        memoryCache.totalCostLimit = 50 * 1024 * 1024 // 50MB
    }

    /// 清理内存缓存，用于内存压力响应
    func clearMemoryCache() {
        memoryCache.removeAllObjects()
    }
    
    /// 「我的库」等列表封面用的静帧查找。
    ///
    /// **仅服务 UI 列表展示**，不得用于桌面/锁屏静态底图。
    /// 优先级：列表小图（`generateThumbnail` 写入，完整画幅）→ 高清 poster（仅兜底）。
    ///
    /// 注意：高清 poster 会做 letterbox 去黑边，竖屏/带边视频会被裁窄；若列表优先用它，
    /// 再叠加 KF `Downsampling(512×512)` + `scaledToFill`，封面会像被放大裁切。
    /// 因此列表必须优先未裁切的 800×600 列表帧。
    func cachedStaticThumbnailFileURLIfExists(forLocalFile mediaURL: URL) -> URL? {
        guard mediaURL.isFileURL else { return nil }
        // 列表热路径：只查本机 SSD 上的抽帧缓存，不要 fileExists 外置原片

        let thumb = cacheURL(for: mediaURL)
        if isUsableCachedImage(at: thumb) { return thumb }

        // 无列表小图时才回退 poster（旧缓存/仅生成过高清帧的路径）
        let path = mediaURL.standardizedFileURL.path
        // 列表不做壁纸级来源证明，避免在热路径打开外置视频；严格入口仍逐源验证。
        for poster in [posterCacheURL(forPathKey: path), legacyPosterCacheURL(forPathKey: path)] {
            if isUsableCachedImage(at: poster) { return poster }
        }
        return nil
    }

    /// Scene 烘焙封面使用稳定的 item 级缓存文件，避免每次重新烘焙因为 MP4 文件名变化而堆出多张抽帧图。
    func cachedSceneBakePosterFileURLIfExists(itemID: String, forLocalVideo videoURL: URL? = nil) -> URL? {
        let candidates = [sceneBakePosterCacheURL(itemID: itemID), legacySceneBakePosterURL(itemID: itemID)]
        // 无源上下文的旧调用只供列表展示；桌面/锁屏必须传入当前 MP4。
        return candidates.first { isUsableCachedImage(at: $0) }
    }

    /// 桌面/锁屏高清缓存按 itemID 直接命中，不做内容/属性/裁剪身份校验。
    func cachedSceneBakePosterFileURLIfMatchingCurrentIdentity(itemID: String, contentRoot: URL) -> URL? {
        _ = contentRoot
        return cachedSceneBakePosterFileURLIfExists(itemID: itemID)
    }

    /// 实时 Scene 在关闭自动烘焙时生成的按目标尺寸静帧。
    /// 与真正烘焙产物的 `scene_bake_*` 隔离，避免横屏主屏 poster 污染竖屏副屏。
    func cachedSceneRealtimePosterFileURLIfExists(
        itemID: String,
        variantKey: String
    ) -> URL? {
        let candidates = [sceneRealtimePosterCacheURL(itemID: itemID, variantKey: variantKey),
                          legacySceneRealtimePosterURL(itemID: itemID, variantKey: variantKey)]
        return candidates.first { url in
            guard isUsableCachedImage(at: url) else { return false }
            return true
        }
    }

    /// 详情/菜单同步入口也只读内存，目录扫描与图片解码复用后台读取器。
    private static var realtimePosterIndex: [String: URL] = [:]
    private var realtimePosterCheckedAt: [String: Date] = [:]
    private var realtimePosterTasks: [String: Task<Void, Never>] = [:]
    private var realtimePosterGeneration: UInt64 = 0
    private var realtimePosterContext: LibraryThumbnailLookupContext?

    func latestSceneRealtimePosterFileURLIfExists(itemID: String) -> URL? {
        let context = Self.libraryLookupContext()
        if realtimePosterContext != context {
            invalidateRealtimePosterIndex()
            Self.realtimePosterIndex.removeAll()
            realtimePosterContext = context
        }
        let key = itemID.md5
        if realtimePosterTasks[key] == nil,
           Date().timeIntervalSince(realtimePosterCheckedAt[key] ?? .distantPast) >= 10,
           realtimePosterTasks.count < 128 {
            let generation = realtimePosterGeneration
            realtimePosterTasks[key] = Task { @MainActor [weak self] in
                let poster = await LibraryThumbnailDiskReader.shared.realtimePoster(itemID: itemID, context: context)
                guard let self, !Task.isCancelled, self.realtimePosterGeneration == generation,
                      self.realtimePosterContext == context else { return }
                self.realtimePosterTasks.removeValue(forKey: key)
                let previous = Self.realtimePosterIndex[key]
                Self.realtimePosterIndex[key] = poster
                self.realtimePosterCheckedAt[key] = Date()
                if self.realtimePosterCheckedAt.count > 4096,
                   let victim = self.realtimePosterCheckedAt.keys.first {
                    self.realtimePosterCheckedAt.removeValue(forKey: victim)
                    Self.realtimePosterIndex.removeValue(forKey: victim)
                }
                if let poster, previous != poster {
                    NotificationCenter.default.post(name: .sceneOfflineBakeThumbnailDidUpdate, object: itemID,
                        userInfo: ["thumbnailURL": poster, "lookupOnly": true])
                }
            }
        }
        return Self.realtimePosterIndex[key]
    }

    /// 写入/删除后失效，但不丢弃旧画面；过期任务不可覆盖下一代结果。
    private func invalidateRealtimePosterIndex() {
        realtimePosterGeneration &+= 1
        for task in realtimePosterTasks.values { task.cancel() }
        realtimePosterTasks.removeAll(keepingCapacity: true)
        realtimePosterCheckedAt.removeAll(keepingCapacity: true)
        LibraryThumbnailDiskReader.shared.invalidateRealtimeIndex()
    }

    /// 仅返回已缓存的**高清**动态壁纸 poster，不触发 AVFoundation 抽帧。
    /// 调度器切换下一张时优先走这里，避免串行抽帧把切换卡住。
    ///
    /// **绝不返回** `generateThumbnail` 的列表小图（800×600）。
    func cachedPosterJPEGFileURLIfExists(forLocalVideo videoURL: URL) -> URL? {
        guard videoURL.isFileURL else { return nil }
        let pathKey = videoURL.standardizedFileURL.path
        guard fileManager.fileExists(atPath: pathKey) else { return nil }
        return usablePosterURL(forPathKey: pathKey)
    }

    /// 桌面/锁屏静态底图：只读**高清** poster 缓存，绝不触发抽帧，也**绝不回退列表缩略图**。
    ///
    /// 优先级：
    /// 1. scene 烘焙稳定封面 `scene_bake_<itemID>.jpg`（烘焙完成时写入，高清）
    /// 2. 下载/设壁纸生成的高清 poster `poster_wallpaper_<path>.jpg`（最大 3840×2160）
    /// 3. 调用方显式 fallback（必须是 file URL 且可用）
    ///
    /// **不用** `generateThumbnail` 的列表小图（800×600，仅供库列表/网格 UI）。
    /// **不用** Workshop 工程自带的 `preview.*`（商店缩略图，不适合桌面/锁屏）。
    ///
    /// 锁屏/桌面若需要强制生成高清帧，请走 `posterJPEGFileURL` / `sceneBakePosterJPEGFileURL`
    /// 或 `LocalWallpaperApplyService.Options.generatePosterFromVideoIfNeeded`。
    func existingWallpaperPosterURL(
        forLocalVideo videoURL: URL?,
        sceneBakeItemID: String? = nil,
        projectRoot: URL? = nil,
        fallbackPosterURL: URL? = nil
    ) -> URL? {
        _ = projectRoot // 兼容旧调用；不再从工程目录取 preview.*

        if let sceneBakeItemID, let videoURL,
           let scenePoster = cachedSceneBakePosterFileURLIfExists(itemID: sceneBakeItemID, forLocalVideo: videoURL) {
            return scenePoster
        }

        if let videoURL,
           let poster = cachedPosterJPEGFileURLIfExists(forLocalVideo: videoURL) {
            return poster
        }

        if let fallbackPosterURL,
           fallbackPosterURL.isFileURL,
           !fallbackPosterURL.lastPathComponent.hasPrefix("list_"),
           !fallbackPosterURL.deletingPathExtension().lastPathComponent.lowercased().hasPrefix("preview"),
           isUsableCachedImage(at: fallbackPosterURL) {
            return fallbackPosterURL
        }

        return nil
    }

    /// 列表缩略图磁盘缓存（`generateThumbnail` 写入，最大 800×600），不触发生成。
    /// **仅供列表/网格 UI**，禁止作为桌面/锁屏静态底图。
    func cachedListThumbnailFileURLIfExists(forLocalVideo videoURL: URL) -> URL? {
        guard videoURL.isFileURL else { return nil }
        let thumb = cacheURL(for: videoURL)
        guard isUsableCachedImage(at: thumb) else { return nil }
        return thumb
    }

    private func isUsableCachedImage(at url: URL) -> Bool {
        guard fileManager.fileExists(atPath: url.path),
              let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let sz = attrs[.size] as? NSNumber,
              sz.intValue > 500 else {
            return false
        }
        // 只读 ImageIO 元数据 + 1px 缩略图，拒绝「够大但不可解码」的坏缓存。
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 1,
                kCGImageSourceShouldCache: false
              ] as CFDictionary) != nil else { return false }
        return true
    }

    /// 获取**列表**视频缩略图 URL（最大 800×600）。
    /// - Important: 仅供库列表/网格 UI，**禁止**作为桌面/锁屏静态底图。
    ///   锁屏/桌面请用 `posterJPEGFileURL` / `existingWallpaperPosterURL`。
    /// - Parameter videoURL: 视频文件 URL
    /// - Returns: 缩略图 URL（可能是缓存的文件 URL，也可能是原始视频 URL）
    func thumbnailURL(for videoURL: URL) -> URL {
        // 检查内存缓存
        let cacheKey = videoURL.absoluteString as NSString
        if memoryCache.object(forKey: cacheKey) != nil {
            return cacheURL(for: videoURL)
        }
        
        // 检查磁盘缓存
        let cachedURL = cacheURL(for: videoURL)
        if fileManager.fileExists(atPath: cachedURL.path) {
            return cachedURL
        }
        
        // 异步生成列表缩略图（非高清 poster）
        Task {
            await generateThumbnail(for: videoURL)
        }
        
        // 返回视频 URL（Kingfisher 会处理生成）
        return videoURL
    }
    
    /// 从本地视频抽一帧为**高清** JPEG（最大 3840×2160），用作动态壁纸的**静态桌面/锁屏**底图
    /// （与 `VideoWallpaperManager.setPosterAsDesktopWallpaper` 配套）。
    ///
    /// - Important: 这是锁屏/桌面唯一允许的抽帧生成入口；与列表 `generateThumbnail`（800×600）完全隔离。
    /// - Note: 输出在 `VideoThumbnails` 目录，文件名 `poster_wallpaper_<path_md5>.jpg`；失败时返回 `nil`。
    /// - Performance: 缓存命中时立即返回，letterbox 去黑边在后台异步修正，不阻塞设壁纸。
    func posterJPEGFileURL(forLocalVideo videoURL: URL) async -> URL? {
        guard videoURL.isFileURL else { return nil }
        let pathKey = videoURL.standardizedFileURL.path
        guard fileManager.fileExists(atPath: pathKey) else { return nil }

        let outURL = posterCacheURL(forPathKey: pathKey)
        if let existing = usablePosterURL(forPathKey: pathKey) {
            // 关键：不要 await 全分辨率 letterbox 扫描；已有高清 poster 直接返回
            scheduleCropExistingPosterIfNeeded(existing)
            return existing
        }

        let fileURL = URL(fileURLWithPath: pathKey)
        return await generatePosterJPEGFile(from: fileURL, outputURL: outURL)
    }

    /// 为 Wallpaper Engine 烘焙 MP4 生成稳定封面。`forceRegenerate` 为 true 时覆盖同一个 item 的旧抽帧。
    func sceneBakePosterJPEGFileURL(
        forLocalVideo videoURL: URL,
        itemID: String,
        forceRegenerate: Bool = false
    ) async -> URL? {
        guard videoURL.isFileURL else { return nil }
        let pathKey = videoURL.standardizedFileURL.path
        guard fileManager.fileExists(atPath: pathKey) else { return nil }

        let outURL = sceneBakePosterCacheURL(itemID: itemID)
        if !forceRegenerate,
           let existing = cachedSceneBakePosterFileURLIfExists(itemID: itemID, forLocalVideo: videoURL) {
            return existing
        }
        return await generatePosterJPEGFile(from: URL(fileURLWithPath: pathKey), outputURL: outURL,
            cropLetterbox: false, forceRegenerate: forceRegenerate)
    }

    /// 为实时 Scene 的临时 1 秒视频生成目标屏幕专用封面。
    /// `variantKey` 应包含内容版本与目标像素尺寸；不同横竖比例不会共享缓存。
    func sceneRealtimePosterJPEGFileURL(
        forLocalVideo videoURL: URL,
        itemID: String,
        variantKey: String,
        targetWidth: Int,
        targetHeight: Int,
        forceRegenerate: Bool = false
    ) async -> URL? {
        guard videoURL.isFileURL else { return nil }
        let pathKey = videoURL.standardizedFileURL.path
        guard fileManager.fileExists(atPath: pathKey) else { return nil }

        let outURL = sceneRealtimePosterCacheURL(itemID: itemID, variantKey: variantKey)
        if !forceRegenerate,
           let existing = cachedSceneRealtimePosterFileURLIfExists(
               itemID: itemID,
               variantKey: variantKey
           ) {
            return existing
        }

        invalidateRealtimePosterIndex()
        return await generatePosterJPEGFile(
            from: URL(fileURLWithPath: pathKey),
            outputURL: outURL,
            maximumSize: CGSize(
                width: max(1, targetWidth),
                height: max(1, targetHeight)
            ),
            cropLetterbox: false,
            forceRegenerate: forceRegenerate
        )
    }

    /// 将渲染器 `detect-static` 输出的单帧 PNG 写入实时 poster 缓存。
    ///
    /// 纯静态 scene 走"抽帧"路径时没有 1 秒 MP4 可供 AVAssetImageGenerator 抽帧，
    /// 渲染器直接产出整屏 PNG；这里按与临时抽帧一致的 `scene_realtime_` 键空间
    /// 落盘 JPEG，所有 UI/锁屏消费方无感。`variantKey` 语义与视频抽帧完全一致。
    func sceneRealtimePosterJPEGFileURL(
        forImageFile imageURL: URL,
        itemID: String,
        variantKey: String,
        targetWidth: Int,
        targetHeight: Int,
        forceRegenerate: Bool = false
    ) async -> URL? {
        guard imageURL.isFileURL else { return nil }
        let pathKey = imageURL.standardizedFileURL.path
        guard fileManager.fileExists(atPath: pathKey) else { return nil }

        let outURL = sceneRealtimePosterCacheURL(itemID: itemID, variantKey: variantKey)
        if !forceRegenerate,
           let existing = cachedSceneRealtimePosterFileURLIfExists(
               itemID: itemID,
               variantKey: variantKey
           ) {
            return existing
        }

        invalidateRealtimePosterIndex()
        return await generatePosterJPEGFile(
            fromImageFile: imageURL,
            outputURL: outURL,
            maximumSize: CGSize(
                width: max(1, targetWidth),
                height: max(1, targetHeight)
            ),
            cropLetterbox: false,
            forceRegenerate: forceRegenerate
        )
    }

    /// 将 Wallpaper Engine Web renderer 的直接截图写入稳定 poster 缓存。
    ///
    /// 截图源通常在 `/tmp`，不能直接作为详情页或锁屏长期引用；这里编码为与离线烘焙
    /// 共用的 item 级 JPEG poster，不创建任何 MP4。
    func wallpaperEnginePosterJPEGFileURL(
        forImageFile imageURL: URL,
        itemID: String,
        forceRegenerate: Bool = false
    ) async -> URL? {
        guard imageURL.isFileURL,
              fileManager.fileExists(atPath: imageURL.path) else {
            return nil
        }

        let outURL = sceneBakePosterCacheURL(itemID: itemID)
        if !forceRegenerate,
           let existing = cachedSceneBakePosterFileURLIfExists(itemID: itemID) {
            return existing
        }
        return await generatePosterJPEGFile(
            fromImageFile: imageURL, outputURL: outURL,
            forceRegenerate: forceRegenerate
        )
    }

    /// 删除 Scene 烘焙稳定封面，并顺手清掉旧的 path-based poster，避免历史重复缓存继续被列表命中。
    func removeSceneBakePoster(itemID: String, videoPath: String? = nil) {
        try? fileManager.removeItem(at: sceneBakePosterCacheURL(itemID: itemID))
        try? fileManager.removeItem(at: legacySceneBakePosterURL(itemID: itemID))
        let realtimePrefix = "scene_realtime_\(itemID.md5)_"
        let webPrefix = "scene_web_\(itemID.md5)_"
        var directories = [cacheDirectory]
        if let covers = sceneCoversDirectory(), covers != cacheDirectory { directories.append(covers) }
        for dir in directories {
            guard let files = try? fileManager.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for file in files
            where (file.lastPathComponent.hasPrefix(realtimePrefix)
                   || file.lastPathComponent.hasPrefix(webPrefix))
                && file.pathExtension.lowercased() == "jpg" {
            _ = try? fileManager.removeItem(at: file)
            }
        }
        if let videoPath, !videoPath.isEmpty {
            let videoURL = URL(fileURLWithPath: videoPath)
            try? fileManager.removeItem(at: posterCacheURL(forPathKey: videoURL.standardizedFileURL.path))
            try? fileManager.removeItem(at: legacyPosterCacheURL(forPathKey: videoURL.standardizedFileURL.path))
            removeListThumbnail(forLocalVideo: videoURL)
        }
        invalidateRealtimePosterIndex()
    }

    /// 删除视频对应的列表小图磁盘缓存 + 内存缓存（重新烘焙后必须调用，否则 path 不变会继续命中旧帧）。
    func removeListThumbnail(forLocalVideo videoURL: URL) {
        guard videoURL.isFileURL else { return }
        let pathKey = Self.stablePathKey(for: videoURL)
        let listURL = cacheURL(forPathKey: pathKey)
        try? fileManager.removeItem(at: listURL)
        // 兼容旧 absoluteString / 无 list_ 前缀键
        try? fileManager.removeItem(at: cacheDirectory.appendingPathComponent("\(videoURL.absoluteString.md5).jpg"))
        try? fileManager.removeItem(at: cacheDirectory.appendingPathComponent("\(pathKey.md5).jpg"))
        try? fileManager.removeItem(
            at: cacheDirectory.appendingPathComponent("\(URL(fileURLWithPath: pathKey).absoluteString.md5).jpg")
        )
        memoryCache.removeObject(forKey: pathKey as NSString)
        memoryCache.removeObject(forKey: videoURL.absoluteString as NSString)
    }

    /// 强制从当前视频重新抽列表小图（完整画幅），覆盖旧 `list_*.jpg`。
    @discardableResult
    func regenerateListThumbnailJPEGFileURL(forLocalVideo videoURL: URL) async -> URL? {
        guard videoURL.isFileURL else { return nil }
        removeListThumbnail(forLocalVideo: videoURL)
        return await listThumbnailJPEGFileURL(forLocalVideo: videoURL)
    }

    /// 强制从当前视频重新抽高清 poster（桌面/锁屏/详情背景用，最大 3840×2160），覆盖旧 `poster_wallpaper_*.jpg`。
    /// 详情页「重新抽帧」入口使用；与列表小图相互独立。
    @discardableResult
    func regeneratePosterJPEGFileURL(forLocalVideo videoURL: URL) async -> URL? {
        guard videoURL.isFileURL else { return nil }
        let pathKey = videoURL.standardizedFileURL.path
        guard fileManager.fileExists(atPath: pathKey) else { return nil }
        let outURL = posterCacheURL(forPathKey: pathKey)
        try? fileManager.removeItem(at: outURL)
        memoryCache.removeObject(forKey: pathKey as NSString)
        memoryCache.removeObject(forKey: videoURL.absoluteString as NSString)
        return await generatePosterJPEGFile(
            from: URL(fileURLWithPath: pathKey),
            outputURL: outURL
        )
    }

    /// 动态壁纸的锁屏/静态桌面底图：对 mp4/mov/webm/m4v **强制**从片源抽高清帧。
    /// 失败或未识别扩展名时才回退站点封面等；**绝不**使用列表 `generateThumbnail` 小图。
    func lockScreenPosterURL(forLocalVideo localVideoURL: URL, fallbackPosterURL: URL?) async -> URL? {
        let ext = localVideoURL.pathExtension.lowercased()
        guard ["mp4", "mov", "webm", "m4v"].contains(ext) else { return fallbackPosterURL }
        // 先读高清 poster 缓存；没有就抽一帧生成，绝不碰列表小图
        if let existing = cachedPosterJPEGFileURLIfExists(forLocalVideo: localVideoURL) {
            return existing
        }
        return await posterJPEGFileURL(forLocalVideo: localVideoURL) ?? fallbackPosterURL
    }

    /// 普通视频高清帧（桌面/锁屏/详情背景）：写在库目录 `Covers/`，键见 `coverPathKey`。
    private func posterCacheURL(forPathKey pathKey: String) -> URL {
        sceneCoverWriteDirectory.appendingPathComponent("poster_wallpaper_\(coverPathKey(forVideoPathKey: pathKey).md5).jpg")
    }

    /// 迁移前 Caches 里的旧高清帧（绝对路径哈希）。
    private func legacyPosterCacheURL(forPathKey pathKey: String) -> URL {
        cacheDirectory.appendingPathComponent("poster_wallpaper_\(pathKey.md5).jpg")
    }

    /// 读高清帧：新位置优先；只剩旧 Caches 那份时返回它并后台复制到新位置（不删源）。
    private func usablePosterURL(forPathKey pathKey: String) -> URL? {
        let poster = posterCacheURL(forPathKey: pathKey)
        if isUsableCachedImage(at: poster) { return poster }
        let legacy = legacyPosterCacheURL(forPathKey: pathKey)
        guard legacy != poster, isUsableCachedImage(at: legacy) else { return nil }
        Self.ensureParentDirectory(of: poster)
        if !fileManager.fileExists(atPath: poster.path) {
            try? fileManager.copyItem(at: legacy, to: poster)
        }
        return legacy
    }

    // MARK: 封面（真实壁纸数据，落库目录，不放 Caches）
    //
    // 动态壁纸的静态封面都在这里：`scene_bake_*`（烘焙封面）、`scene_realtime_*`（静态检测 / 临时抽帧）、
    // `poster_wallpaper_*`（普通视频的高清帧）。「我的库」卡片、详情页、锁屏/桌面底图都直接用它；
    // 放 Caches 会被系统/清理工具整目录清掉。现落在下载根目录 `Covers/`（与 Media/、SceneBakes/ 同级），
    // 切换存储目录时随库一起迁移。旧 Caches 里的文件只作兼容读取：scene 封面首次解析时整批复制过去，
    // 视频高清帧（文件名是绝对路径哈希，无法反推）在读到时逐张复制。都只复制不删。

    nonisolated static let sceneCoversFolderName = "Covers"
    private var sceneCoversDirectoryCache: (url: URL?, rootPath: String?, resolvedAt: Date) = (nil, nil, .distantPast)
    private var migratedLegacyCoversInto: Set<String> = []

    /// 库目录下的封面目录；库根不存在（外置盘未挂载）时返回 nil，调用方回退旧 Caches 位置，
    /// 避免在 /Volumes 下凭空建出同名目录。解析结果缓存 5s（书签解析不便宜，列表会逐条调用）。
    func sceneCoversDirectory() -> URL? {
        if BackgroundRuntimeRole.isIsolatedTest { return nil }
        let now = Date()
        if now.timeIntervalSince(sceneCoversDirectoryCache.resolvedAt) < 5 {
            return sceneCoversDirectoryCache.url
        }
        let root = DownloadPathManager.shared.rootFolderURL
        var url: URL?
        if fileManager.fileExists(atPath: root.path) {
            let dir = root.appendingPathComponent(Self.sceneCoversFolderName, isDirectory: true)
            if !fileManager.fileExists(atPath: dir.path) {
                try? fileManager.createDirectory(at: dir, withIntermediateDirectories: false)
            }
            url = fileManager.fileExists(atPath: dir.path) ? dir : nil
        }
        sceneCoversDirectoryCache = (url, url == nil ? nil : root.standardizedFileURL.path, now)
        if let url { migrateLegacyCoversIfNeeded(into: url) }
        return url
    }

    /// 视频高清帧的文件名键：库内视频用「相对库根的路径」，换存储目录后键不变，封面随库迁移无需重抽；
    /// 库外视频（用户导入的任意位置）仍用绝对路径。
    private func coverPathKey(forVideoPathKey pathKey: String) -> String {
        guard sceneCoversDirectory() != nil,
              let rootPath = sceneCoversDirectoryCache.rootPath else { return pathKey }
        let standardized = (pathKey as NSString).standardizingPath
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard standardized.hasPrefix(prefix) else { return pathKey }
        return "lib:" + String(standardized.dropFirst(prefix.count))
    }

    /// 一次性把旧 Caches 里的封面复制进库目录（目标已有同名文件则跳过；不删源）。
    private func migrateLegacyCoversIfNeeded(into covers: URL) {
        let key = covers.standardizedFileURL.path
        guard !migratedLegacyCoversInto.contains(key) else { return }
        migratedLegacyCoversInto.insert(key)
        let source = cacheDirectory
        Task.detached(priority: .utility) {
            let fm = FileManager.default
            let files = (try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            var copied = 0
            for file in files {
                let name = file.lastPathComponent
                guard name.hasPrefix("scene_bake_") || name.hasPrefix("scene_realtime_") || name.hasPrefix("scene_web_"),
                      file.pathExtension.lowercased() == "jpg" else { continue }
                let dest = covers.appendingPathComponent(name)
                guard !fm.fileExists(atPath: dest.path) else { continue }
                if (try? fm.copyItem(at: file, to: dest)) != nil {
                    copied += 1
                }
            }
            if copied > 0 {
                print("[VideoThumbnailCache] 旧 Caches 封面已复制进库目录: \(copied) 张 → \(covers.path)")
                await MainActor.run { VideoThumbnailCache.shared.invalidateRealtimePosterIndex() }
            }
        }
    }

    /// 封面写入/读取的首选目录：库目录可用时用库目录，否则回退旧 Caches。
    private var sceneCoverWriteDirectory: URL { sceneCoversDirectory() ?? cacheDirectory }

    private func sceneBakePosterCacheURL(itemID: String) -> URL {
        sceneCoverWriteDirectory.appendingPathComponent("scene_bake_\(itemID.md5).jpg")
    }

    private func sceneRealtimePosterCacheURL(itemID: String, variantKey: String) -> URL {
        sceneCoverWriteDirectory.appendingPathComponent(
            "scene_realtime_\(itemID.md5)_\(variantKey.md5).jpg"
        )
    }

    private func legacySceneBakePosterURL(itemID: String) -> URL {
        cacheDirectory.appendingPathComponent("scene_bake_\(itemID.md5).jpg")
    }

    private func legacySceneRealtimePosterURL(itemID: String, variantKey: String) -> URL {
        cacheDirectory.appendingPathComponent("scene_realtime_\(itemID.md5)_\(variantKey.md5).jpg")
    }

    /// 是否为本 App 生成的静态图（列表小图 / 封面），用于 UI 跳过 GIF 探测。
    nonisolated static func isGeneratedStaticImagePath(_ path: String) -> Bool {
        path.contains("/WaifuX/VideoThumbnails/")
            || path.contains("/WaifuX/LocalImageThumbnails/")
            || path.contains("/WaifuX/\(sceneCoversFolderName)/")
    }

    /// 只供过渡图复用：按 itemID 取同尺寸的烘焙／实时整图，不再做 JSON 身份校验。
    func reusableSceneHDPosters(itemID: String) -> [URL] {
        var directories = [cacheDirectory]
        if let covers = sceneCoversDirectory(), covers != cacheDirectory { directories.insert(covers, at: 0) }
        let bakeName = "scene_bake_\(itemID.md5).jpg"
        let realtimePrefix = "scene_realtime_\(itemID.md5)_"
        return directories.flatMap { directory in
            ((try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
                .filter { url in
                    let name = url.lastPathComponent
                    return (name == bakeName || (name.hasPrefix(realtimePrefix) && url.pathExtension == "jpg"))
                        && isUsableCachedImage(at: url)
                }
        }.sorted { (imagePixelSize(at: $0)?.width ?? 0) > (imagePixelSize(at: $1)?.width ?? 0) }
    }

    // MARK: Scene 过渡图（scene_transition_*）

    private func sceneTransitionPosterURL(spec: SceneTransitionPosterSpec) -> URL {
        cacheDirectory.appendingPathComponent("scene_transition_\(spec.cacheKey.md5).jpg")
    }

    /// 在当前壁纸的几何缓存键下按图片和像素尺寸命中，不读内容/属性来源侧车。
    func cachedSceneTransitionPoster(expected: SceneTransitionPosterSpec) -> URL? {
        let imageURL = sceneTransitionPosterURL(spec: expected)
        guard isUsableCachedImage(at: imageURL),
              let size = imagePixelSize(at: imageURL),
              Int(size.width) == expected.pixelWidth,
              Int(size.height) == expected.pixelHeight else { return nil }
        return imageURL
    }

    /// 从临时 1 秒视频抽取过渡图，仅写 JPEG。
    func storeSceneTransitionPoster(
        forLocalVideo videoURL: URL,
        spec: SceneTransitionPosterSpec
    ) async -> URL? {
        if let cached = cachedSceneTransitionPoster(expected: spec) { return cached }
        guard videoURL.isFileURL, fileManager.fileExists(atPath: videoURL.path) else { return nil }
        let imageURL = sceneTransitionPosterURL(spec: spec)
        try? fileManager.removeItem(at: imageURL)
        guard let written = await generatePosterJPEGFile(
            from: videoURL,
            outputURL: imageURL,
            maximumSize: CGSize(width: max(1, spec.pixelWidth), height: max(1, spec.pixelHeight)),
            cropLetterbox: false
        ), isUsableCachedImage(at: written) else {
            return nil
        }
        return written
    }

    /// 复用已有帧并沿用目标 crop/viewport 适配，不以原画布比例拒绝资源。
    func adoptSceneTransitionPoster(
        fromExistingPoster sourceURL: URL,
        spec: SceneTransitionPosterSpec,
        sourceCropSignature: String = "none"
    ) -> URL? {
        if let cached = cachedSceneTransitionPoster(expected: spec) { return cached }
        guard isUsableCachedImage(at: sourceURL),
              let pixels = imagePixelSize(at: sourceURL),
              spec.pixelWidth > 0, spec.pixelHeight > 0,
              spec.pixelWidth <= 8192, spec.pixelHeight <= 8192,
              Int64(spec.pixelWidth) * Int64(spec.pixelHeight) <= 33_554_432,
              pixels.width * pixels.height <= 33_554_432 else { return nil }
        let crop: CGRect
        let viewport: CGRect
        if sourceCropSignature == spec.cropSignature {
            crop = CGRect(x: 0, y: 0, width: 1, height: 1)
            viewport = crop
        } else {
            guard sourceCropSignature == "none",
                  let layout = Self.transitionCropLayout(signature: spec.cropSignature) else { return nil }
            crop = layout.crop
            viewport = layout.viewport
        }
        let imageURL = sceneTransitionPosterURL(spec: spec)
        guard sourceURL != imageURL else { return nil }
        if sourceCropSignature == spec.cropSignature,
           Int(pixels.width) == spec.pixelWidth, Int(pixels.height) == spec.pixelHeight {
            do {
                let data = try Data(contentsOf: sourceURL)
                Self.ensureParentDirectory(of: imageURL)
                try data.write(to: imageURL, options: .atomic)
                return imageURL
            } catch { return nil }
        }
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
              let cropped = image.cropping(to: CGRect(x: crop.minX * CGFloat(image.width),
                  y: crop.minY * CGFloat(image.height), width: crop.width * CGFloat(image.width),
                  height: crop.height * CGFloat(image.height))),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: spec.pixelWidth, height: spec.pixelHeight,
                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let width = CGFloat(spec.pixelWidth), height = CGFloat(spec.pixelHeight)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: viewport.minX * width, y: (1 - viewport.maxY) * height,
                                        width: viewport.width * width, height: viewport.height * height))
        guard let output = context.makeImage(), let jpeg = Self.encodeJPEG(output, quality: 0.90) else { return nil }
        do {
            Self.ensureParentDirectory(of: imageURL)
            try jpeg.write(to: imageURL, options: .atomic)
            return imageURL
        } catch {
            return nil
        }
    }

    /// 直接消费实时启动已算好的归一化 crop/viewport；不重新计算 cover、pan 或 zoom。
    nonisolated static func transitionCropLayout(signature: String) -> (crop: CGRect, viewport: CGRect)? {
        let args = signature.split(separator: " ").map(String.init)
        func rect(_ value: String) -> CGRect? {
            let components = value.split(separator: ",", omittingEmptySubsequences: false)
            guard components.count == 4 else { return nil }
            let numbers = components.compactMap { Double($0) }
            guard numbers.count == 4, numbers.allSatisfy(\.isFinite),
                  numbers[0] >= 0, numbers[1] >= 0, numbers[2] > 0, numbers[3] > 0,
                  numbers[0] + numbers[2] <= 1.000001, numbers[1] + numbers[3] <= 1.000001 else { return nil }
            return CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
        }
        guard args.count == 2 || args.count == 4, args[0] == "--crop", let crop = rect(args[1]) else { return nil }
        if args.count == 4 {
            guard args[2] == "--crop-viewport", let viewport = rect(args[3]) else { return nil }
            return (crop, viewport)
        }
        return (crop, CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// 像素尺寸（不解码整图）；用于判断已有抽帧与目标屏比例是否一致。
    func imagePixelSize(at url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0 else { return nil }
        return CGSize(width: w, height: h)
    }

    /// 缓存目录可能在运行期被外部清理（清理工具 / 手动删 Caches）；init 只建一次不够，
    /// 每次写入前补建父目录，否则 `.atomic` 写入全部失败、表现为「抽帧失败」。
    nonisolated static func ensureParentDirectory(of fileURL: URL) {
        let dir = fileURL.deletingLastPathComponent()
        guard !FileManager.default.fileExists(atPath: dir.path) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func generatePosterJPEGFile(
        from videoURL: URL,
        outputURL: URL,
        maximumSize: CGSize = CGSize(width: 3840, height: 2160),
        cropLetterbox: Bool = true,
        forceRegenerate: Bool = false
    ) async -> URL? {
        return await VideoPosterGenerationCoordinator.shared.generate(key: outputURL.path) {
            if !forceRegenerate, await self.isUsableCachedImage(at: outputURL) { return outputURL }

            return await Task.detached(priority: .userInitiated) {
                let startedAt = CFAbsoluteTimeGetCurrent()
                let asset = AVURLAsset(url: videoURL)
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                // 允许就近关键帧，显著快于精确 seek（尤其长 GOP / 4K）
                generator.requestedTimeToleranceBefore = CMTime(seconds: 0.35, preferredTimescale: 600)
                generator.requestedTimeToleranceAfter = CMTime(seconds: 0.35, preferredTimescale: 600)
                generator.maximumSize = maximumSize

                // 少候选 + 优先靠近片头的可读帧，避免 4K 中间帧随机 seek 过慢。
                // 中间帧只作为首轮失败后的备选，不再默认先抽 50%。
                var candidates: [Double] = [1.0, 0.5, 2.0]
                if let duration = try? await asset.load(.duration) {
                    let d = CMTimeGetSeconds(duration)
                    if d.isFinite, d > 0 {
                        let mid = d * 0.5
                        let early = min(max(d * 0.15, 0.3), 2.0)
                        candidates = [early, min(1.0, max(d * 0.05, 0.2)), mid]
                            .filter { $0 >= 0 && $0 < d }
                        var seen = Set<Double>()
                        candidates = candidates.compactMap {
                            let rounded = (($0 * 10).rounded() / 10)
                            guard !seen.contains(rounded) else { return nil }
                            seen.insert(rounded)
                            return $0
                        }
                    }
                }
                if candidates.isEmpty {
                    candidates = [0.0]
                }

                for seconds in candidates {
                    let t = CMTime(seconds: seconds, preferredTimescale: 600)
                    do {
                        let cgImage = try generator.copyCGImage(at: t, actualTime: nil)
                        // 生成阶段先不做全分辨率 letterbox 扫描（4K 全图像素扫描极慢），
                        // 直接编码 JPEG；后续由 scheduleCropExistingPosterIfNeeded 后台修正。
                        guard let jpeg = Self.encodeJPEG(cgImage, quality: 0.88) else {
                            continue
                        }
                        Self.ensureParentDirectory(of: outputURL)
                        try jpeg.write(to: outputURL, options: .atomic)
                        let elapsed = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
                        print("[VideoThumbnailCache] Poster frame at \(String(format: "%.1f", seconds))s in \(String(format: "%.0f", elapsed))ms → \(outputURL.lastPathComponent)")
                        if cropLetterbox {
                            Task.detached(priority: .utility) { await Self.cropExistingPosterIfNeeded(outputURL) }
                        }
                        return outputURL
                    } catch {
                        print("[VideoThumbnailCache] Poster try at \(String(format: "%.1f", seconds))s failed: \(error)")
                        continue
                    }
                }

                print("[VideoThumbnailCache] All poster frame attempts exhausted for \(videoURL.lastPathComponent)")
                return nil
            }.value
        }
    }

    private func generatePosterJPEGFile(
        fromImageFile imageURL: URL,
        outputURL: URL,
        maximumSize: CGSize = CGSize(width: 3840, height: 2160),
        cropLetterbox: Bool = true,
        forceRegenerate: Bool = false
    ) async -> URL? {
        return await VideoPosterGenerationCoordinator.shared.generate(key: outputURL.path) {
            if !forceRegenerate, await self.isUsableCachedImage(at: outputURL) { return outputURL }
            return await Task.detached(priority: .userInitiated) {
                let startedAt = CFAbsoluteTimeGetCurrent()
                guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil) else {
                    print("[VideoThumbnailCache] Failed to open Web capture: \(imageURL.lastPathComponent)")
                    return nil
                }

                let maxPixel = max(maximumSize.width, maximumSize.height)
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                    kCGImageSourceShouldCacheImmediately: false
                ]
                guard let image = CGImageSourceCreateThumbnailAtIndex(
                    source,
                    0,
                    options as CFDictionary
                ), let jpeg = Self.encodeJPEG(image, quality: 0.90) else {
                    print("[VideoThumbnailCache] Failed to encode Web capture: \(imageURL.lastPathComponent)")
                    return nil
                }

                do {
                    Self.ensureParentDirectory(of: outputURL)
                    try jpeg.write(to: outputURL, options: .atomic)
                    let elapsed = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
                    print("[VideoThumbnailCache] Web capture poster in \(String(format: "%.0f", elapsed))ms → \(outputURL.lastPathComponent)")
                    if cropLetterbox {
                        Task.detached(priority: .utility) { await Self.cropExistingPosterIfNeeded(outputURL) }
                    }
                    return outputURL
                } catch {
                    print("[VideoThumbnailCache] Failed to write Web capture poster: \(error)")
                    return nil
                }
            }.value
        }
    }

    /// 后台异步 letterbox 修正；调用方不得 await，避免阻塞设壁纸热路径。
    private func scheduleCropExistingPosterIfNeeded(_ url: URL) {
        Task.detached(priority: .utility) {
            await Self.cropExistingPosterIfNeeded(url)
        }
    }

    /// 用 ImageIO 直接编码 JPEG，避免 NSImage → TIFF → NSBitmapImageRep 的双份全分辨率拷贝。
    ///
    /// 编码前统一转 sRGB：AVAssetImageGenerator 输出的 CGImage 保留视频本源色域
    /// （实测 ICC=HDTV/Rec.709），写桌面后 WindowServer 按该 ICC 做色彩管理，
    /// 与 AVPlayerLayer 的合成链路不一致，表现为静态帧与视频“色域不同”。
    /// 桌面图统一 sRGB ICC 后，颜色走的转换与系统其它图像一致，手感对齐。
    nonisolated private static func encodeJPEG(_ image: CGImage, quality: CGFloat) -> Data? {
        let normalized = sRGBImage(image)
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData,
            "public.jpeg" as CFString,
            1,
            nil
        ) else {
            return nil
        }
        let props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(dest, normalized, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// 非 sRGB 色彩的图（视频本源 Rec.709/Display P3/HDR 映射结果）重绘到 sRGB 位图。
    /// 已是 sRGB 的图原样返回，不付出重绘成本。
    nonisolated private static func sRGBImage(_ image: CGImage) -> CGImage {
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else { return image }
        if let name = image.colorSpace?.name, name == sRGB.name {
            return image
        }
        guard let ctx = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: sRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return image }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage() ?? image
    }

    nonisolated private static func cropExistingPosterIfNeeded(_ url: URL) async {
        // 精确图与 Scene 整画布缓存不允许后台去黑边改变 crop 语义。
        guard !url.lastPathComponent.hasPrefix("scene_") else { return }
        await Task.detached(priority: .utility) {
            guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil),
                  let cropped = croppedImageLetterbox(cgImage),
                  cropped.width != cgImage.width || cropped.height != cgImage.height else {
                return
            }
            guard let jpeg = encodeJPEG(cropped, quality: 0.88) else { return }
            do {
                try jpeg.write(to: url, options: .atomic)
                print("[VideoThumbnailCache] Cropped existing poster letterbox: \(url.lastPathComponent)")
            } catch {
                print("[VideoThumbnailCache] Failed to rewrite cropped poster: \(error)")
            }
        }.value
    }

    nonisolated private static func croppingImageLetterboxIfNeeded(_ image: CGImage) -> CGImage {
        croppedImageLetterbox(image) ?? image
    }

    nonisolated private static func croppedImageLetterbox(_ image: CGImage) -> CGImage? {
        guard let crop = detectBlackBorderCropRect(in: image) else { return nil }
        return image.cropping(to: crop)
    }

    nonisolated private static func detectBlackBorderCropRect(in image: CGImage) -> CGRect? {
        let width = image.width
        let height = image.height
        guard width > 16, height > 16 else { return nil }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        let didDraw = pixels.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress,
                  let ctx = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard didDraw else { return nil }

        let blackLumaThreshold: UInt8 = 28
        let edgeBlackRatioThreshold = 0.94
        let maxRemovedArea = 0.36
        let minRemovedArea = 0.001
        let minPairInsetRatio = 0.001
        let overscanPixels = 2

        func isBlackPixel(at index: Int) -> Bool {
            guard index + 2 < pixels.count else { return false }
            let r = pixels[index]
            let g = pixels[index + 1]
            let b = pixels[index + 2]
            let luma = (UInt16(r) * 54 + UInt16(g) * 183 + UInt16(b) * 19) >> 8
            return luma <= blackLumaThreshold
        }

        func blackRatioInRow(_ y: Int) -> Double {
            let step = max(1, width / 720)
            var black = 0
            var total = 0
            let row = y * bytesPerRow
            var x = 0
            while x < width {
                if isBlackPixel(at: row + x * 4) { black += 1 }
                total += 1
                x += step
            }
            return total > 0 ? Double(black) / Double(total) : 0
        }

        func blackRatioInColumn(_ x: Int) -> Double {
            let step = max(1, height / 720)
            var black = 0
            var total = 0
            var y = 0
            while y < height {
                if isBlackPixel(at: y * bytesPerRow + x * 4) { black += 1 }
                total += 1
                y += step
            }
            return total > 0 ? Double(black) / Double(total) : 0
        }

        func edgeInset(limit: Int, ratioAt: (Int) -> Double) -> Int {
            var inset = 0
            for i in 0..<limit {
                if ratioAt(i) >= edgeBlackRatioThreshold {
                    inset += 1
                } else {
                    break
                }
            }
            return inset
        }

        let top = edgeInset(limit: height / 2) { blackRatioInRow($0) }
        let bottom = edgeInset(limit: height / 2) { blackRatioInRow(height - 1 - $0) }
        let left = edgeInset(limit: width / 2) { blackRatioInColumn($0) }
        let right = edgeInset(limit: width / 2) { blackRatioInColumn(width - 1 - $0) }

        let horizontalPair = Double(top + bottom) / Double(height) >= minPairInsetRatio
            && top > 0 && bottom > 0
        let verticalPair = Double(left + right) / Double(width) >= minPairInsetRatio
            && left > 0 && right > 0
        guard horizontalPair || verticalPair else { return nil }

        let rawCropTop = horizontalPair ? top : 0
        let rawCropBottom = horizontalPair ? bottom : 0
        let rawCropLeft = verticalPair ? left : 0
        let rawCropRight = verticalPair ? right : 0
        let rawCropW = max(1, width - rawCropLeft - rawCropRight)
        let rawCropH = max(1, height - rawCropTop - rawCropBottom)
        let removedArea = 1.0 - (Double(rawCropW * rawCropH) / Double(width * height))
        guard removedArea >= minRemovedArea, removedArea <= maxRemovedArea else { return nil }

        let cropTop = horizontalPair ? min(height - 1, rawCropTop + overscanPixels) : 0
        let cropBottom = horizontalPair ? min(height - cropTop - 1, rawCropBottom + overscanPixels) : 0
        let cropLeft = verticalPair ? min(width - 1, rawCropLeft + overscanPixels) : 0
        let cropRight = verticalPair ? min(width - cropLeft - 1, rawCropRight + overscanPixels) : 0
        let cropW = max(1, width - cropLeft - cropRight)
        let cropH = max(1, height - cropTop - cropBottom)

        return CGRect(x: cropLeft, y: cropTop, width: cropW, height: cropH)
    }

    /// 获取**列表**缩略图图片（最大 800×600）。
    /// - Important: 仅供 UI 列表，禁止用于锁屏/桌面。
    /// - Parameter videoURL: 视频文件 URL
    /// - Returns: 缩略图
    func thumbnailImage(for videoURL: URL) async -> NSImage? {
        let cacheKey = videoURL.absoluteString as NSString
        
        // 检查内存缓存
        if let cached = memoryCache.object(forKey: cacheKey) {
            return cached
        }
        
        // 检查磁盘缓存
        let cachedURL = cacheURL(for: videoURL)
        if fileManager.fileExists(atPath: cachedURL.path),
           let data = try? Data(contentsOf: cachedURL),
           let image = NSImage(data: data) {
            memoryCache.setObject(image, forKey: cacheKey)
            return image
        }
        
        // 生成缩略图
        return await generateThumbnail(for: videoURL)
    }
    
    /// 生成并缓存**列表**缩略图（最长边约 960，保持原始宽高比，**不做 letterbox 裁切**）。
    /// - Important: 仅供库列表/网格 UI。桌面/锁屏必须走 `generatePosterJPEGFile`（3840×2160）。
    @discardableResult
    private func generateThumbnail(for videoURL: URL) async -> NSImage? {
        // 统一用标准化 path 作为缓存键与读盘路径，避免 fileURL absoluteString 编码差异导致
        // 「生成写了 A.jpg、查找读 B.jpg」——外置卡上路径形态不一时表现为部分封面永远空白。
        let pathKey = Self.stablePathKey(for: videoURL)
        let sourceURL = URL(fileURLWithPath: pathKey)
        let outputURL = cacheURL(forPathKey: pathKey)
        let memoryKey = pathKey as NSString

        if let cached = memoryCache.object(forKey: memoryKey) {
            return cached
        }
        if isUsableCachedImage(at: outputURL),
           let data = try? Data(contentsOf: outputURL),
           let image = NSImage(data: data) {
            memoryCache.setObject(image, forKey: memoryKey)
            return image
        }

        let generated = await VideoListThumbnailGenerationCoordinator.shared.generate(key: pathKey) {
            await Self.extractListThumbnailJPEG(
                sourceURL: sourceURL,
                outputURL: outputURL
            )
        }
        guard generated != nil,
              let data = try? Data(contentsOf: outputURL),
              let image = NSImage(data: data) else {
            return nil
        }
        let cost = Int((image.size.width * image.size.height * 4).rounded())
        memoryCache.setObject(image, forKey: memoryKey, cost: max(cost, 1))
        return image
    }

    /// 后台抽列表帧并写入 `outputURL`；成功返回 outputURL。
    nonisolated private static func extractListThumbnailJPEG(
        sourceURL: URL,
        outputURL: URL
    ) async -> URL? {
        let task = Task.detached(priority: .utility) { () -> URL? in
            guard !Task.isCancelled else { return nil }
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                print("[VideoThumbnailCache] List thumb source missing: \(sourceURL.lastPathComponent)")
                return nil
            }

            let asset = AVURLAsset(url: sourceURL)
            let imageGenerator = AVAssetImageGenerator(asset: asset)
            imageGenerator.appliesPreferredTrackTransform = true
            // 列表专用上限：正方形 bounding box，按比例缩小，竖/横画幅都够用
            imageGenerator.maximumSize = CGSize(width: 960, height: 960)
            imageGenerator.requestedTimeToleranceBefore = CMTime(seconds: 0.35, preferredTimescale: 600)
            imageGenerator.requestedTimeToleranceAfter = CMTime(seconds: 0.35, preferredTimescale: 600)

            // 多候选：短视频 / 片头黑帧 / 外置卡 seek 失败
            var candidates: [Double] = [0.5, 1.0, 0.2, 0.0, 2.0]
            if let duration = try? await asset.load(.duration) {
                let d = CMTimeGetSeconds(duration)
                if d.isFinite, d > 0 {
                    candidates = [
                        min(max(d * 0.1, 0.15), 1.5),
                        min(0.5, max(d * 0.05, 0.1)),
                        min(1.0, d * 0.25),
                        min(d * 0.5, d - 0.05),
                        0.0
                    ]
                    .filter { $0 >= 0 && $0 < d }
                    var seen = Set<String>()
                    candidates = candidates.filter {
                        let k = String(format: "%.2f", $0)
                        return seen.insert(k).inserted
                    }
                    if candidates.isEmpty { candidates = [0.0] }
                }
            }

            for seconds in candidates {
                guard !Task.isCancelled else { return nil }
                let t = CMTime(seconds: seconds, preferredTimescale: 600)
                do {
                    let cgImage = try imageGenerator.copyCGImage(at: t, actualTime: nil)
                    guard let jpeg = encodeJPEG(cgImage, quality: 0.82) else { continue }
                    try jpeg.write(to: outputURL, options: .atomic)
                    print("[VideoThumbnailCache] List thumb @\(String(format: "%.1f", seconds))s \(cgImage.width)x\(cgImage.height) → \(outputURL.lastPathComponent)")
                    return outputURL
                } catch {
                    print("[VideoThumbnailCache] List thumb try @\(seconds)s failed: \(error)")
                    continue
                }
            }
            print("[VideoThumbnailCache] Failed to generate list thumbnail for \(sourceURL.lastPathComponent)")
            return nil
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: { task.cancel() }
    }

    /// 为列表 UI 生成/返回 列表小图 URL（完整画幅，无 letterbox 裁切）。
    /// 与 `posterJPEGFileURL`（高清+去黑边，桌面/锁屏用）隔离。
    func listThumbnailJPEGFileURL(forLocalVideo videoURL: URL) async -> URL? {
        let performanceStart = ProcessInfo.processInfo.systemUptime
        defer {
            InteractionPerformanceLog.record(.thumbnailGeneration, since: performanceStart, metadata: [
                "cancelled": Task.isCancelled ? "1" : "0"
            ])
        }
        guard videoURL.isFileURL else { return nil }
        let pathKey = Self.stablePathKey(for: videoURL)
        let thumb = cacheURL(forPathKey: pathKey)
        if isUsableCachedImage(at: thumb) {
            return thumb
        }
        // 也尝试旧 absoluteString 键（迁移前写入的缓存），命中则复制到新键
        if migrateLegacyListThumbIfNeeded(for: videoURL, pathKey: pathKey) {
            return thumb
        }
        _ = await generateThumbnail(for: URL(fileURLWithPath: pathKey))
        return isUsableCachedImage(at: thumb) ? thumb : nil
    }

    /// Menu previews use the existing generation budget without synchronous MainActor cache reads.
    nonisolated static func menuListThumbnail(for videoURL: URL, cacheDirectory: URL) async -> URL? {
        let path = stablePathKey(for: videoURL)
        let output = cacheDirectory.appendingPathComponent("list_\(path.md5).jpg")
        return await VideoListThumbnailGenerationCoordinator.shared.generate(key: path) {
            guard !Task.isCancelled else { return nil }
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            return await extractListThumbnailJPEG(sourceURL: URL(fileURLWithPath: path), outputURL: output)
        }
    }

    /// 标准化路径键：去掉 file URL 编码差异，统一 `/private` 前缀形态。
    nonisolated private static func stablePathKey(for videoURL: URL) -> String {
        var path = videoURL.standardizedFileURL.path
        // fileURLWithPath 与 absoluteString 解析后的 path 可能一个带 /private
        if path.hasPrefix("/private/var/"), path.count > "/private".count {
            // 保留原样；NSString.standardizingPath 已处理大部分
            path = (path as NSString).standardizingPath
        } else {
            path = (path as NSString).standardizingPath
        }
        return path
    }

    /// 获取缓存 URL（基于稳定 path，而非 absoluteString）
    private func cacheURL(for videoURL: URL) -> URL {
        cacheURL(forPathKey: Self.stablePathKey(for: videoURL))
    }

    private func cacheURL(forPathKey pathKey: String) -> URL {
        cacheDirectory.appendingPathComponent("list_\(pathKey.md5).jpg")
    }

    /// 兼容旧版 `\(absoluteString.md5).jpg` 与未加 `list_` 前缀的 path 键。
    @discardableResult
    private func migrateLegacyListThumbIfNeeded(for videoURL: URL, pathKey: String) -> Bool {
        let dest = cacheURL(forPathKey: pathKey)
        guard !isUsableCachedImage(at: dest) else { return true }

        let legacyCandidates = [
            cacheDirectory.appendingPathComponent("\(videoURL.absoluteString.md5).jpg"),
            cacheDirectory.appendingPathComponent("\(pathKey.md5).jpg"),
            // 某些路径会多/少 trailing slash
            cacheDirectory.appendingPathComponent("\(URL(fileURLWithPath: pathKey).absoluteString.md5).jpg")
        ]
        for legacy in legacyCandidates {
            guard isUsableCachedImage(at: legacy) else { continue }
            do {
                try fileManager.copyItem(at: legacy, to: dest)
                print("[VideoThumbnailCache] Migrated legacy list thumb → \(dest.lastPathComponent)")
                return true
            } catch {
                // 已存在或拷贝失败：若 dest 可用仍算成功
                if isUsableCachedImage(at: dest) { return true }
            }
        }
        return false
    }
    
    /// 迁移缓存键：将旧路径对应的缓存文件重命名为新路径对应的缓存文件名。
    /// 遍历所有下载记录中的视频文件，计算旧/新 MD5 缓存键并执行重命名。
    func migrateCacheKeys(fromOldPrefix oldPrefix: String, toNewPrefix newPrefix: String) {
        Task.detached(priority: .utility) { [cacheDirectory = self.cacheDirectory] in
            let fileManager = FileManager.default
            var movedCount = 0

            func moveIfNeeded(from old: URL, to new: URL) {
                guard fileManager.fileExists(atPath: old.path),
                      !fileManager.fileExists(atPath: new.path) else { return }
                try? fileManager.moveItem(at: old, to: new)
                movedCount += 1
            }

            func migrateListThumbs(oldPath: String, newPath: String) {
                let oldKey = (oldPath as NSString).standardizingPath
                let newKey = (newPath as NSString).standardizingPath
                let oldURL = URL(fileURLWithPath: oldKey)
                let newURL = URL(fileURLWithPath: newKey)

                // 新键 list_<path.md5>
                let oldList = cacheDirectory.appendingPathComponent("list_\(oldKey.md5).jpg")
                let newList = cacheDirectory.appendingPathComponent("list_\(newKey.md5).jpg")
                moveIfNeeded(from: oldList, to: newList)

                // 旧 absoluteString 键 / 裸 path.md5 键 → 新 list_ 键
                for legacy in [
                    cacheDirectory.appendingPathComponent("\(oldURL.absoluteString.md5).jpg"),
                    cacheDirectory.appendingPathComponent("\(oldKey.md5).jpg")
                ] {
                    moveIfNeeded(from: legacy, to: newList)
                }

                let oldPoster = cacheDirectory.appendingPathComponent("poster_wallpaper_\(oldKey.md5).jpg")
                let newPoster = cacheDirectory.appendingPathComponent("poster_wallpaper_\(newKey.md5).jpg")
                moveIfNeeded(from: oldPoster, to: newPoster)
            }

            let mediaRecords = await MainActor.run { MediaLibraryService.shared.downloadRecords }
            let wallpaperRecords = await MainActor.run { WallpaperLibraryService.shared.downloadRecords }

            for record in mediaRecords {
                let path = record.localFilePath
                guard path.hasPrefix(newPrefix) else { continue }
                let oldPath = oldPrefix + String(path.dropFirst(newPrefix.count))
                migrateListThumbs(oldPath: oldPath, newPath: path)
            }

            for record in wallpaperRecords {
                let path = record.localFilePath
                guard path.hasPrefix(newPrefix) else { continue }
                let oldPath = oldPrefix + String(path.dropFirst(newPrefix.count))
                migrateListThumbs(oldPath: oldPath, newPath: path)
            }

            print("[VideoThumbnailCache] Migrated \(movedCount) cache files from old paths to new paths")
        }
    }

    /// 清理过期缓存
    func cleanupCache() {
        Task.detached(priority: .utility) { [cacheDirectory = self.cacheDirectory] in
            let fileManager = FileManager.default
            let contents = (try? fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            
            // 删除超过 30 天的缓存
            let thirtyDaysAgo = Date().addingTimeInterval(-30 * 24 * 60 * 60)
            for file in contents {
                if let attrs = try? fileManager.attributesOfItem(atPath: file.path),
                   let date = attrs[.modificationDate] as? Date,
                   date < thirtyDaysAgo {
                    try? fileManager.removeItem(at: file)
                }
            }
        }
    }
}

// MARK: - String MD5 扩展

extension String {
    var md5: String {
        let data = Data(self.utf8)
        let hash = Insecure.MD5.hash(data: data)
        return hash.map { String(format: "%02hhx", $0) }.joined()
    }
}
