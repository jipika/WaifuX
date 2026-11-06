import Foundation

// MARK: - MediaItem 我的库列表封面

extension Notification.Name {
    static let libraryMediaThumbnailsDidChange = Notification.Name("WaifuX.libraryMediaThumbnailsDidChange")
    static let libraryMediaThumbnailWorkDidSuspend = Notification.Name("WaifuX.libraryMediaThumbnailWorkDidSuspend")
    static let libraryMediaThumbnailWorkDidResume = Notification.Name("WaifuX.libraryMediaThumbnailWorkDidResume")
}

/// 列表只读 URL 快照。首次命中和过期刷新都排到慢卷专用队列，不在 body/map 内做 I/O。
/// 任务有上限、同一请求合并、离页撤销；后台结果按 itemID 合并通知，不触发整库重建。
@MainActor
final class LibraryMediaThumbnailCache {
    static let shared = LibraryMediaThumbnailCache()
    private struct Entry {
        let result: LibraryThumbnailResolution
        let resolvedAt: Date
    }
    private struct Flight {
        let token: UUID
        let task: Task<LibraryThumbnailResolution, Never>
    }
    private var entries: [LibraryThumbnailLookupRequest: Entry] = [:]
    private var flights: [LibraryThumbnailLookupRequest: Flight] = [:]
    private var generation: UInt64 = 0
    private var changedItemIDs: Set<String> = []
    private var notificationTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private let maximumEntries = 4096
    private let maximumPendingRequests = 128

    private init() {
        let center = NotificationCenter.default
        for name in [Notification.Name.sceneOfflineBakeThumbnailDidUpdate, .localMediaPosterDidUpdate] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let itemID = note.object as? String
                Task { @MainActor [weak self] in
                    if let itemID { self?.invalidate(itemID: itemID) }
                }
            })
        }
        for name in [Notification.Name.downloadPathChanged, .appDidReceiveMemoryPressure] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let notify = note.name == .downloadPathChanged
                Task { @MainActor [weak self] in self?.invalidateAll(notify: notify) }
            })
        }
    }

    func request(for item: MediaItem, localFileURL: URL?, isFolderPreview: Bool = false) -> LibraryThumbnailLookupRequest {
        let artifact = MediaLibraryService.shared.downloadRecord(for: item.id)?.sceneBakeArtifact
        let bakedPath = artifact?.videoPath
        return LibraryThumbnailLookupRequest(
            itemID: item.id, localFileURL: localFileURL,
            bakedVideoURL: bakedPath.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: false) },
            bakedArtifact: artifact, posterURL: item.posterURL, thumbnailURL: item.thumbnailURL,
            context: VideoThumbnailCache.libraryLookupContext(), isFolderPreview: isFolderPreview
        )
    }

    func thumbnailURL(for item: MediaItem, localFileURL: URL?, isFolderPreview: Bool = false, enqueueIfNeeded: Bool = true) -> URL {
        let request = request(for: item, localFileURL: localFileURL, isFolderPreview: isFolderPreview)
        if let entry = entries[request] {
            if enqueueIfNeeded, Date().timeIntervalSince(entry.resolvedAt) >= 10 { _ = enqueue(request) }
            return entry.result.thumbnailURL ?? Self.fallback(for: item)
        }
        if enqueueIfNeeded { _ = enqueue(request) }
        return Self.fallback(for: item)
    }

    func cachedResolution(for item: MediaItem, localFileURL: URL?) -> LibraryThumbnailResolution? {
        entries[request(for: item, localFileURL: localFileURL)]?.result
    }

    func resolve(for item: MediaItem, localFileURL: URL?, isFolderPreview: Bool = false) async -> LibraryThumbnailResolution {
        let epoch = generation
        while !Task.isCancelled, generation == epoch {
            let request = request(for: item, localFileURL: localFileURL, isFolderPreview: isFolderPreview)
            if let entry = entries[request], Date().timeIntervalSince(entry.resolvedAt) < 10 {
                return entry.result
            }
            if let task = enqueue(request, prioritizeVisible: !isFolderPreview) {
                // 离屏的等待者必须撤销共享读取；新可见等待者会重试，而不是永远停在占位。
                let result = await withTaskCancellationHandler {
                    await task.value
                } onCancel: { task.cancel() }
                guard !Task.isCancelled, generation == epoch,
                      request == self.request(for: item, localFileURL: localFileURL, isFolderPreview: isFolderPreview) else {
                    return LibraryThumbnailResolution()
                }
                if !result.isDeferred, let token = result.lookupToken,
                   entries[request]?.result.lookupToken == token { return result }
            }
            // 名额满或上一消费者已撤销：异步让位重试，不在主线程等待，也不丢弃可见请求。
            do { try await Task.sleep(nanoseconds: 40_000_000) } catch { break }
        }
        return LibraryThumbnailResolution()
    }

    func isCurrent(_ result: LibraryThumbnailResolution, for item: MediaItem, localFileURL: URL?, isFolderPreview: Bool = false) -> Bool {
        let current = request(for: item, localFileURL: localFileURL, isFolderPreview: isFolderPreview)
        guard result.lookupRequest == current, let token = result.lookupToken else { return false }
        return entries[current]?.result.lookupToken == token
    }

    private static func fallback(for item: MediaItem) -> URL {
        // 路径只作为加载候选，存在性由后台解析/Kingfisher 处理，不能 read-through stat。
        [item.posterURL, Optional(item.thumbnailURL)].compactMap { $0 }
            .first { !MediaItem.urlLooksLikeGIF($0) } ?? item.coverImageURL
    }

    @discardableResult
    private func enqueue(_ request: LibraryThumbnailLookupRequest, prioritizeVisible: Bool = false) -> Task<LibraryThumbnailResolution, Never>? {
        if let flight = flights[request] {
            if prioritizeVisible { LibraryThumbnailDiskReader.shared.promote(request) }
            return flight.task
        }
        if prioritizeVisible, flights.count >= maximumPendingRequests,
           let backgroundKey = flights.keys.first(where: { $0.isFolderPreview }) {
            flights.removeValue(forKey: backgroundKey)?.task.cancel()
        }
        guard flights.count < maximumPendingRequests else { return nil }
        let token = UUID()
        let epoch = generation
        let task = Task { @MainActor [weak self] () -> LibraryThumbnailResolution in
            var result = await LibraryThumbnailDiskReader.shared.resolve(request, prioritizeVisible: prioritizeVisible)
            guard let self else { return LibraryThumbnailResolution() }
            defer {
                if self.flights[request]?.token == token { self.flights.removeValue(forKey: request) }
            }
            guard !Task.isCancelled, self.generation == epoch,
                  self.flights[request]?.token == token else { return LibraryThumbnailResolution() }
            guard !result.isDeferred else { return result }
            result.lookupRequest = request
            result.lookupToken = token
            let previous = self.entries[request]?.result.thumbnailURL
            if self.entries.count >= self.maximumEntries, self.entries[request] == nil,
               let victim = self.entries.keys.first { self.entries.removeValue(forKey: victim) }
            self.entries[request] = Entry(result: result, resolvedAt: Date())
            if previous != result.thumbnailURL { self.noteChange(itemID: request.itemID) }
            return result
        }
        flights[request] = Flight(token: token, task: task)
        return task
    }

    private func noteChange(itemID: String) {
        changedItemIDs.insert(itemID)
        guard notificationTask == nil else { return }
        notificationTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 80_000_000) } catch { return }
            guard let self else { return }
            self.notificationTask = nil
            let itemIDs = Array(self.changedItemIDs)
            self.changedItemIDs.removeAll(keepingCapacity: true)
            NotificationCenter.default.post(name: .libraryMediaThumbnailsDidChange, object: nil,
                                             userInfo: ["itemIDs": itemIDs])
        }
    }

    func invalidate(itemID: String, realtimeIndexChanged: Bool = true) {
        for key in Array(entries.keys) where key.itemID == itemID { entries.removeValue(forKey: key) }
        for key in Array(flights.keys) where key.itemID == itemID {
            flights.removeValue(forKey: key)?.task.cancel()
        }
        if realtimeIndexChanged { LibraryThumbnailDiskReader.shared.invalidateRealtimeIndex() }
        noteChange(itemID: itemID)
    }

    func resumeVisibleWork() {
        NotificationCenter.default.post(name: .libraryMediaThumbnailWorkDidResume, object: nil)
    }

    func cancelPendingRequests(suspendVisibleWork: Bool = false) {
        generation &+= 1
        for flight in flights.values { flight.task.cancel() }
        flights.removeAll(keepingCapacity: true)
        notificationTask?.cancel()
        notificationTask = nil
        changedItemIDs.removeAll(keepingCapacity: true)
        NotificationCenter.default.post(name: .libraryMediaThumbnailWorkDidSuspend, object: nil,
            userInfo: ["untilVisible": suspendVisibleWork])
    }

    private func invalidateAll(notify: Bool) {
        let affected: Set<String> = notify ? Set(entries.keys.map(\.itemID)).union(flights.keys.map(\.itemID)) : []
        cancelPendingRequests()
        entries.removeAll(keepingCapacity: false)
        LibraryThumbnailDiskReader.shared.invalidateRealtimeIndex()
        for itemID in affected { noteChange(itemID: itemID) }
    }
}

extension MediaItem {
    private static let libraryLocalRasterExtensions: Set<String> = [
        "jpg", "jpeg", "png", "webp", "gif", "heic", "heif", "avif", "bmp", "tiff", "tif"
    ]

    private static let videoFileExtensions: Set<String> = ["mp4", "mov", "webm", "m4v", "mkv"]
    private static let workshopStaticPreviewFallbackNames = [
        "preview.jpg", "preview.jpeg", "preview.png", "preview.webp"
    ]
    private static let workshopGIFPreviewFallbackNames = ["preview.gif"]

    nonisolated static func urlLooksLikeGIF(_ url: URL) -> Bool {
        let value = url.absoluteString.lowercased()
        return value.hasSuffix(".gif")
            || value.contains(".gif?")
            || value.contains(".gif&")
            || url.pathExtension.lowercased() == "gif"
            || value.contains("format=gif")
            || value.contains("output-format=gif")
    }

    /// 读取 Wallpaper Engine `project.json` 的 type，用于区分 Web 壁纸和可抽帧的视频类内容。
    /// 结果经 `WorkshopLibraryPreviewCache` 缓存，避免列表重建时反复读外置卡。
    nonisolated static func localWorkshopProjectType(from url: URL) -> String? {
        WorkshopLibraryPreviewCache.shared.projectType(for: url) {
            let fm = FileManager.default
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return nil }

            let resolved = WorkshopService.resolveWallpaperEngineProjectRoot(startingAt: url)
            let projectURL = resolved.appendingPathComponent("project.json")
            guard let data = try? Data(contentsOf: projectURL),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String else {
                return nil
            }
            return type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }

    /// 若 `url` 是已下载的 Wallpaper Engine 项目录，优先寻找静态本地预览图。
    /// GIF 是 hover 动画源；只有没有其他静态候选时才作为列表封面保底。
    nonisolated static func resolveLocalWorkshopPreviewImage(from url: URL) -> URL? {
        WorkshopLibraryPreviewCache.shared.previewImage(for: url) {
            let fm = FileManager.default
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return nil }

            let resolved = WorkshopService.resolveWallpaperEngineProjectRoot(startingAt: url)
            let projectURL = resolved.appendingPathComponent("project.json")
            var projectGIFPreview: URL?
            if let data = try? Data(contentsOf: projectURL),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let previewName = json["preview"] as? String {
                let trimmed = previewName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    let candidate = resolved.appendingPathComponent(trimmed)
                    if fm.fileExists(atPath: candidate.path) {
                        if !Self.urlLooksLikeGIF(candidate) {
                            return candidate
                        }
                        projectGIFPreview = candidate
                    }
                }
            }

            for name in workshopStaticPreviewFallbackNames {
                let candidate = resolved.appendingPathComponent(name)
                if fm.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
            if let projectGIFPreview {
                return projectGIFPreview
            }
            for name in workshopGIFPreviewFallbackNames {
                let candidate = resolved.appendingPathComponent(name)
                if fm.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
            return nil
        }
    }

    /// Wallpaper Engine 本地工程的真实 GIF 预览，只供 hover 播放使用。
    nonisolated static func resolveLocalWorkshopPreviewGIF(from url: URL) -> URL? {
        WorkshopLibraryPreviewCache.shared.previewGIF(for: url) {
            let fm = FileManager.default
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return nil }

            let resolved = WorkshopService.resolveWallpaperEngineProjectRoot(startingAt: url)
            let projectURL = resolved.appendingPathComponent("project.json")
            if let data = try? Data(contentsOf: projectURL),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let previewName = json["preview"] as? String {
                let candidate = resolved.appendingPathComponent(
                    previewName.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                if fm.fileExists(atPath: candidate.path), Self.urlLooksLikeGIF(candidate) {
                    return candidate
                }
            }

            for name in workshopGIFPreviewFallbackNames {
                let candidate = resolved.appendingPathComponent(name)
                if fm.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
            return nil
        }
    }

    /// 若 `url` 是目录（壁纸引擎 Workshop 项），递归查找其中的视频文件并返回；若是视频文件则直接返回。
    ///
    /// 注意：根目录有 `.pkg` 时仍可能带 `video.mp4`（混合工程），不能一票否决；
    /// 只跳过纯 scene（有 pkg 且无视频文件）的抽帧。
    nonisolated static func resolveLocalVideoFile(from url: URL) -> URL? {
        WorkshopLibraryPreviewCache.shared.videoFile(for: url) {
            let fm = FileManager.default
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }

            if !isDir.boolValue {
                return videoFileExtensions.contains(url.pathExtension.lowercased()) ? url : nil
            }

            let resolved = WorkshopService.resolveWallpaperEngineProjectRoot(startingAt: url)

            // 先浅扫工程根（常见 video.mp4 / 同级媒体）
            let rootContents = (try? fm.contentsOfDirectory(
                at: resolved,
                includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles
            )) ?? []
            if let rootVideo = rootContents.first(where: {
                videoFileExtensions.contains($0.pathExtension.lowercased())
            }) {
                return rootVideo
            }

            // 再递归（部分工程把视频放 materials/ 等子目录）
            if let enumerator = fm.enumerator(
                at: resolved,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) {
                for case let fileURL as URL in enumerator {
                    if videoFileExtensions.contains(fileURL.pathExtension.lowercased()) {
                        return fileURL
                    }
                }
            }
            return nil
        }
    }

    /// 列表派生只读内存；首次解析、外置盘存在性与图片校验由后台按需完成。
    @MainActor
    func libraryGridThumbnailURL(localFileURL: URL?) -> URL {
        LibraryMediaThumbnailCache.shared.thumbnailURL(for: self, localFileURL: localFileURL)
    }

    /// 文件夹只请求前三张叠图；与可见卡片共享去重、限流和后台解析。
    @MainActor
    func libraryFolderThumbnailURL(localFileURL: URL?) -> URL {
        LibraryMediaThumbnailCache.shared.thumbnailURL(for: self, localFileURL: localFileURL, isFolderPreview: true)
    }

    /// 文件夹预热复用后台结果，只在缺列表视频帧时走已有的限并发生成器。
    @MainActor
    @discardableResult
    func ensureFolderPreviewCache(localFileURL: URL?) async -> Bool {
        let resolved = await LibraryMediaThumbnailCache.shared.resolve(
            for: self, localFileURL: localFileURL, isFolderPreview: true
        )
        guard !Task.isCancelled, !resolved.hasListThumbnail, let video = resolved.videoURL,
              LibraryMediaThumbnailCache.shared.isCurrent(resolved, for: self, localFileURL: localFileURL, isFolderPreview: true) else { return false }
        guard await VideoThumbnailCache.shared.listThumbnailJPEGFileURL(forLocalVideo: video) != nil,
              !Task.isCancelled,
              LibraryMediaThumbnailCache.shared.isCurrent(resolved, for: self, localFileURL: localFileURL, isFolderPreview: true) else { return false }
        LibraryMediaThumbnailCache.shared.invalidate(itemID: id, realtimeIndexChanged: false)
        return true
    }
}
