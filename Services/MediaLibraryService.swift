import Foundation
import Combine

extension Notification.Name {
    /// 本地媒体高清静帧已生成。`object` 为 `String`（itemID），`userInfo["posterURL"]` 为 `URL`。
    static let localMediaPosterDidUpdate = Notification.Name("localMediaPosterDidUpdate")
}

private func mergedByStableID<Record>(
    primary: [Record],
    fallback: [Record],
    id: (Record) -> String
) -> [Record] {
    var seen = Set<String>()
    var merged: [Record] = []
    for record in primary + fallback where seen.insert(id(record)).inserted {
        merged.append(record)
    }
    return merged
}

@MainActor
final class MediaLibraryService: ObservableObject {
    static let shared = MediaLibraryService()

    @Published private(set) var favoriteRecords: [MediaFavoriteRecord] = [] {
        didSet { rebuildFavoriteIndex() }
    }
    @Published private(set) var downloadRecords: [MediaDownloadRecord] = [] {
        didSet { rebuildDownloadIndex() }
    }
    @Published private(set) var recentItems: [MediaItem] = []

    // MARK: - 持久化（Cache 替代 UserDefaults）

    private let cache = CachePersistenceService.shared
    private let favCategory = "media/fav"
    private let dlCategory = "media/dl"

    /// UserDefaults keys — 仅迁移用
    private let favoriteRecordsKey = "media_favorite_records_v2"
    private let downloadRecordsKey = "media_download_records_v2"
    private let recentsKey = "media_recents_v1"
    private let legacyFavoritesKey = "media_favorites_v1"
    private let legacyDownloadsKey = "media_downloads_v1"
    private let defaults = WaifuXPreferences.shared

    /// ⚡ 快速查找索引：活跃收藏/下载的 ID 集合，避免主线程线性扫描
    private var favoriteIDSet: Set<String> = []
    private var downloadIDSet: Set<String> = []
    /// 下载记录字典索引（item.id → record），O(1) 查找替代 O(n) first(where:)
    private var downloadRecordIndex: [String: MediaDownloadRecord] = [:]
    /// 文件存在性缓存，避免主线程反复 FileManager.fileExists(atPath:)
    private let fileCache = FileExistenceCache.shared

    func backgroundLibrarySnapshot() -> Data {
        (try? BackgroundPropertyList.encode([
            "favorites": JSONEncoder().encode(favoriteRecords),
            "downloads": JSONEncoder().encode(downloadRecords),
            "recents": JSONEncoder().encode(recentItems)
        ])) ?? Data()
    }

    private init() {
        if BackgroundRuntimeRole.isRemoteUI {
            BackgroundRuntimeBridge.observeLibrary { [weak self] values in
                guard let self, let data = values["media"] as? Data, let snapshot = try? BackgroundPropertyList.decode(data) else { return }
                if let bytes = snapshot["favorites"] as? Data, let records = try? JSONDecoder().decode([MediaFavoriteRecord].self, from: bytes) { self.favoriteRecords = records }
                if let bytes = snapshot["downloads"] as? Data, let records = try? JSONDecoder().decode([MediaDownloadRecord].self, from: bytes) { self.downloadRecords = records }
                if let bytes = snapshot["recents"] as? Data, let records = try? JSONDecoder().decode([MediaItem].self, from: bytes) { self.recentItems = records }
            }
            return
        }

        // ⚠️ 不在 init 中读 UserDefaults，避免 _CFXPreferences 递归栈溢出
        // 注册内存压力通知，自动清空文件存在性缓存
        // 用静态数组持有 observer token（非 Sendable），避免 deinit 中访问 actor 隔离属性
        Self.registerMemoryPressureObserver(service: self)
    }

    /// 持有所有 observer tokens，避免被 dealloc 导致 observer 自动移除
    private static var _observerTokens: [Any] = []
    private static func registerMemoryPressureObserver(service: MediaLibraryService) {
        let token = NotificationCenter.default.addObserver(
            forName: .appDidReceiveMemoryPressure,
            object: nil,
            queue: nil,
            using: { _ in
                Task { @MainActor in
                    service.fileCache.clearAll()
                }
            }
        )
        _observerTokens.append(token)
    }

    /// 延迟恢复持久化数据（必须在 AppDelegate.applicationDidFinishLaunching 中调用）
    func restoreSavedData() {
        guard BackgroundRuntimeRole.isHelper else { return }
        loadPersistedState()
    }

    private func rebuildFavoriteIndex() {
        favoriteIDSet = Set(favoriteRecords.filter(\.isActive).map(\.item.id))
    }

    private func rebuildDownloadIndex() {
        downloadIDSet = Set(downloadRecords.filter(\.isActive).map(\.item.id))
        downloadRecordIndex = Dictionary(
            downloadRecords.filter(\.isActive).map { ($0.item.id, $0) },
            uniquingKeysWith: { current, _ in current }
        )
    }

    var favoriteItems: [MediaItem] {
        favoriteRecords
            .filter(\.isActive)
            .map(\.item)
    }

/// 获取指定文件夹内的收藏项目
    func favoriteItems(inFolder folderID: String?) -> [MediaItem] {
        let target = Self.normalizedFolderID(folderID)
        return favoriteRecords
            .filter { $0.isActive && Self.normalizedFolderID($0.folderID) == target }
            .map(\.item)
    }

    /// 获取指定文件夹内的下载项目
    func downloadedItems(inFolder folderID: String?) -> [MediaDownloadRecord] {
        let target = Self.normalizedFolderID(folderID)
        return downloadRecords.filter {
            $0.isActive && Self.normalizedFolderID($0.folderID) == target
        }
    }

    var downloadedItems: [MediaDownloadRecord] {
        downloadRecords.filter(\.isActive)
    }

    /// 根目录下载项目（无 folderID）
    func rootDownloadedItems() -> [MediaDownloadRecord] {
        downloadRecords.filter {
            $0.isActive && Self.normalizedFolderID($0.folderID) == nil
        }
    }

    var pendingSyncFavorites: [MediaFavoriteRecord] {
        favoriteRecords.filter { $0.metadata.syncState != .synced || $0.metadata.isDeleted }
    }

    var pendingSyncDownloads: [MediaDownloadRecord] {
        downloadRecords.filter { $0.metadata.syncState != .synced || $0.metadata.isDeleted }
    }

    func toggleFavorite(_ item: MediaItem) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("library.media.toggleFavorite0", ["item": try? JSONEncoder().encode(item)]); return }

        // ⚡ 先用 Set 快速判断是否存在，避免全表 firstIndex 线性扫描
        if let index = favoriteRecords.firstIndex(where: { $0.item.id == item.id && $0.isActive }) {
            favoriteRecords[index].item = item
            favoriteRecords[index].metadata.markLocalMutation(deleted: true)
        } else if let index = favoriteRecords.firstIndex(where: { $0.item.id == item.id }) {
            favoriteRecords[index].item = item
            favoriteRecords[index].metadata.markLocalMutation(deleted: false)
        } else {
            favoriteRecords.insert(MediaFavoriteRecord(item: item), at: 0)
        }

        favoriteRecords = deduplicated(favoriteRecords)
        // 单条写入 Cache
        if let record = favoriteRecords.first(where: { $0.item.id == item.id }) {
            saveFavToCache(record)
        }
        syncFavIndex()
    }

    func isFavorite(_ item: MediaItem) -> Bool {
        // ⚡ O(1) Set 查找，替代线性扫描
        favoriteIDSet.contains(item.id)
    }

    func isFavorite(id: String) -> Bool {
        favoriteIDSet.contains(id)
    }

    func favoriteRecord(for itemID: String) -> MediaFavoriteRecord? {
        guard favoriteIDSet.contains(itemID) else { return nil }
        return favoriteRecords.first { $0.item.id == itemID && $0.isActive }
    }

    func downloadRecord(for itemID: String) -> MediaDownloadRecord? {
        guard downloadIDSet.contains(itemID) else { return nil }
        return downloadRecordIndex[itemID]
    }

    func downloadRecord(forLocalFilePath path: String) -> MediaDownloadRecord? {
        downloadRecords.first { $0.localFilePath == path && $0.isActive }
    }

    func markAsLooped(localFilePath path: String) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("library.media.markAsLooped0", ["path": path]); return }

        guard let index = downloadRecords.firstIndex(where: { $0.localFilePath == path }) else { return }
        downloadRecords[index].isLooped = true
        saveDlToCache(downloadRecords[index])
        syncDlIndex()
    }

    func isDownloaded(_ item: MediaItem) -> Bool {
        // ⚡ 先通过 Set 快速判断（O(1)），再通过字典索引 O(1) 获取记录
        guard downloadIDSet.contains(item.id),
              let record = downloadRecordIndex[item.id] else {
            return false
        }
        // 使用缓存检查文件存在性，避免主线程 FileManager.fileExists(atPath:)
        let fileExists = fileCache.fileExists(atPath: record.localFilePath)
        if !fileExists {
            print("[MediaLibraryService] File not found for downloaded item: \(item.id) at \(record.localFilePath)")
            return false
        }
        // Wallsflow 等热链失败会把 HTML 落成 .mp4；存在≠可播放。
        // 仅对常见视频扩展名做轻量文件头探测，避免把坏文件当成“已下载”。
        let path = record.localFilePath
        let ext = (path as NSString).pathExtension.lowercased()
        let videoExts: Set<String> = ["mp4", "mov", "webm", "m4v", "mkv"]
        if videoExts.contains(ext), Self.localVideoFileLooksUnplayable(atPath: path) {
            print("[MediaLibraryService] Corrupt/unplayable media treated as not downloaded: \(item.id) at \(path)")
            return false
        }
        return true
    }

    /// 轻量检测：HTML 伪装页 / 无 ftyp 的 mp4 等（任意体积，含 ~200KB 热链失败页）。
    private static func localVideoFileLooksUnplayable(atPath path: String) -> Bool {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        if size < 64_000 { return true }
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return true
        }
        defer { try? handle.close() }
        let head = handle.readData(ofLength: 256)
        if let text = String(data: head, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() {
            if text.hasPrefix("<!doctype") || text.hasPrefix("<html") || text.contains("<head") {
                return true
            }
        }
        let ext = (path as NSString).pathExtension.lowercased()
        if ext == "webm" || ext == "mkv" {
            return !(head.count >= 4 && head[0] == 0x1A && head[1] == 0x45 && head[2] == 0xDF && head[3] == 0xA3)
        }
        // mp4/mov/m4v：ISO BMFF 应为 ....ftyp
        if head.count >= 8, head[4..<8] == Data("ftyp".utf8) {
            return false
        }
        return true
    }

    /// 已下载媒体在磁盘上的文件 URL（存在且可读时）
    func localFileURLIfAvailable(for item: MediaItem) -> URL? {
        guard downloadIDSet.contains(item.id),
              let record = downloadRecordIndex[item.id] else {
            return nil
        }
        let url = URL(fileURLWithPath: record.localFilePath)
        guard fileCache.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// 已下载媒体的视频文件 URL（优先烘焙产物，其次目录内视频文件）；用于封面抽帧
    func resolvedVideoFileURLIfAvailable(for item: MediaItem) -> URL? {
        guard downloadIDSet.contains(item.id),
              let record = downloadRecords.first(where: { $0.item.id == item.id && $0.isActive }) else {
            return nil
        }
        return record.resolvedVideoFileURL
    }

    /// 登记下载记录。
    /// - Parameter folderID: 可选目标文件夹。
    ///   - 活跃记录：非 nil 时写入/覆盖归属；nil 表示调用方不关心，保留现有 folderID
    ///     （避免二次 record 把作者批量下载归夹冲掉）。
    ///   - 软删除复活（重新下载）：以本次传入的 folderID 为权威归属（含 nil=根目录），
    ///     并清掉已随物理文件删除的烘焙/循环状态，避免脏 sidecar。
    func recordDownload(item: MediaItem, localFileURL: URL, folderID: String? = nil) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("library.media.recordDownload0", ["item": try? JSONEncoder().encode(item), "localFileURL": localFileURL, "folderID": folderID]); return }

        let targetFolderID = Self.normalizedFolderID(folderID)
        var persistedItem = item
        if let index = downloadRecords.firstIndex(where: { $0.item.id == item.id }) {
            let wasDeleted = downloadRecords[index].metadata.isDeleted
            persistedItem = item.preservingPersistedMetadata(from: downloadRecords[index].item)
            downloadRecords[index].item = persistedItem
            downloadRecords[index].localFilePath = localFileURL.path
            downloadRecords[index].downloadedAt = .now
            downloadRecords[index].metadata.markLocalMutation(deleted: false)
            if wasDeleted {
                // 重新下载：队列 Job 上的 folderID 是删前捕获的权威归属
                downloadRecords[index].folderID = targetFolderID
                downloadRecords[index].sceneBakeArtifact = nil
                downloadRecords[index].sceneBakeEligibility = nil
                downloadRecords[index].isLooped = nil
            } else if let targetFolderID {
                // 活跃记录仅在显式指定时改归属
                downloadRecords[index].folderID = targetFolderID
            }
        } else {
            downloadRecords.insert(
                MediaDownloadRecord(
                    item: persistedItem,
                    localFilePath: localFileURL.path,
                    folderID: targetFolderID
                ),
                at: 0
            )
        }

        // 预缓存文件存在性，后续 isDownloaded() 不再走 FileManager
        fileCache.markExisting(atPath: localFileURL.path)

        // 单条写入 Cache；强制数组重赋值以触发 didSet / downloadIDSet 重建
        if let record = downloadRecords.first(where: { $0.item.id == item.id }) {
            saveDlToCache(record)
        }
        syncDlIndex()
        downloadRecords = Array(downloadRecords)
        upsert(persistedItem)

        SceneBakeEligibilityAnalyzer.scheduleAnalysisIfSceneProject(itemID: persistedItem.id, localFileURL: localFileURL)
        WebOfflineBakeService.scheduleAutoBakeAfterDownload(itemID: persistedItem.id, localFileURL: localFileURL)

        // 视频文件下载完成后异步生成**高清** poster（锁屏/桌面用，最大 3840×2160）；
        // 列表 800×600 小图由 UI 侧按需 generateThumbnail，二者隔离。
        // 若开启「下载后自动优化视频」，按循环分析 → 补帧入队（不走调度切换路径）。
        let videoExts: Set<String> = ["mp4", "mov", "webm", "m4v", "mkv"]
        let videoFileURL: URL? = if videoExts.contains(localFileURL.pathExtension.lowercased()) {
            localFileURL
        } else {
            // 目录类型（壁纸引擎源）：解析其中的视频文件
            MediaItem.resolveLocalVideoFile(from: localFileURL)
        }
        if let videoFileURL {
            let title = persistedItem.title
            let pageURL = persistedItem.pageURL
            Task { @MainActor in
                if let posterURL = await VideoThumbnailCache.shared.posterJPEGFileURL(forLocalVideo: videoFileURL) {
                    NotificationCenter.default.post(
                        name: .localMediaPosterDidUpdate,
                        object: persistedItem.id,
                        userInfo: ["posterURL": posterURL]
                    )
                }
                VideoOptimizationQueueService.shared.registerDownloadedSource(
                    videoURL: videoFileURL,
                    sourceURL: pageURL
                )
                VideoOptimizationQueueService.shared.enqueueAfterDownloadIfNeeded(
                    videoURL: videoFileURL,
                    title: title
                )
            }
        }
    }

    /// Ensure an existing local media file has a persistent library record.
    /// Applying a wallpaper is an explicit user action, so it must not remain cache-only.
    /// - Parameter folderID: 可选目标文件夹；已有同内容记录时也会补写归属。
    func ensureDownloadRecord(item: MediaItem, localFileURL: URL, folderID: String? = nil) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("library.media.ensureDownloadRecord0", ["item": try? JSONEncoder().encode(item), "localFileURL": localFileURL, "folderID": folderID]); return }

        // 优先走 O(1) 索引：下载刚完成再点「设为壁纸」时几乎总能命中，
        // 避免对整表线性扫描 + 昂贵路径规范化把主线程卡住。
        let existing: MediaDownloadRecord? = {
            if let indexed = downloadRecordIndex[item.id], indexed.isActive {
                return indexed
            }
            return downloadRecords.first(where: { $0.item.id == item.id && $0.isActive })
        }()

        if let existing {
            // 路径字符串直接相等时跳过 hasSameLocalContent（最常见：下载后立即设置）
            let existingPath = (existing.localFilePath as NSString).standardizingPath
            let candidatePath = (localFileURL.path as NSString).standardizingPath
            let sameContent = existingPath == candidatePath || existing.hasSameLocalContent(as: localFileURL)
            if sameContent {
                if let targetFolderID = Self.normalizedFolderID(folderID),
                   Self.normalizedFolderID(existing.folderID) != targetFolderID {
                    moveMediaToFolder(mediaID: item.id, folderID: targetFolderID, scope: .downloads)
                }
                return
            }
        }
        recordDownload(item: item, localFileURL: localFileURL, folderID: folderID)
    }

    /// 以用户当前下载根为准重建媒体库。目录迁移完成后，`DownloadPathManager` 指向的
    /// Media 目录是唯一权威数据源；不移动文件，也不把 Cache 当成下载库。
    private func rebuildManagedMediaLibrary() async {
        let fileManager = FileManager.default
        let mediaFolder = DownloadPathManager.shared.mediaFolderURL.standardizedFileURL
        guard fileManager.fileExists(atPath: mediaFolder.path) else { return }

        var restored = 0

        // 1. 已存在于当前数据源中的旧记录即使曾被错误地标为删除，也重新激活。
        for record in downloadRecords {
            let recordedURL = record.localFileURL.standardizedFileURL
            guard fileManager.fileExists(atPath: recordedURL.path), !record.isActive else { continue }
            restoreDownloadRecord(recordID: record.item.id, localFileURL: recordedURL)
            restored += 1
        }

        // 2. 恢复无索引的顶层视频和 Wallpaper Engine 工程。每 24 项让出一次主线程，
        // 避免包含数百个 Workshop 项的用户目录拖慢启动首帧。
        let entries = (try? fileManager.contentsOfDirectory(
            at: mediaFolder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let recordIDsByFileName = Dictionary(grouping: downloadRecords.compactMap { record -> (String, String)? in
                let fileName = record.localFileURL.lastPathComponent
                return fileName.isEmpty ? nil : (fileName, record.item.id)
            }, by: { $0.0 })
        var recoveredFromDisk = 0
        for (offset, url) in entries.enumerated() {
            if offset > 0, offset.isMultiple(of: 24) {
                await Task.yield()
            }

            let normalizedPath = url.standardizedFileURL.path
            if downloadRecords.contains(where: {
                ($0.localFilePath as NSString).standardizingPath == normalizedPath
            }) {
                continue
            }

            // 文件名在下载时由各来源决定；迁移后路径改变时用它回连原有记录，
            // 以完整保留 MotionBGs、DongTai、Wallsflow、导入等来源的详情与 ID。
            if let matches = recordIDsByFileName[url.lastPathComponent],
               matches.count == 1,
               let recordID = matches.first?.1 {
                restoreDownloadRecord(recordID: recordID, localFileURL: url)
                attachRecoveredBakeArtifactIfNeeded(itemID: recordID)
                restored += 1
                continue
            }

            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }

            if isDirectory.boolValue,
               url.lastPathComponent.hasPrefix("workshop_"),
               let record = downloadRecords.first(where: { $0.item.id == url.lastPathComponent }) {
                restoreDownloadRecord(recordID: record.item.id, localFileURL: url)
                attachRecoveredBakeArtifactIfNeeded(itemID: record.item.id)
                restored += 1
                continue
            }

            let item: MediaItem?
            if isDirectory.boolValue, url.lastPathComponent.hasPrefix("workshop_") {
                item = recoveredWorkshopItem(at: url)
            } else if !isDirectory.boolValue, Self.recoverableVideoExtensions.contains(url.pathExtension.lowercased()) {
                item = recoveredVideoItem(at: url)
            } else {
                item = nil
            }

            guard let item else { continue }
            if downloadRecords.contains(where: { $0.item.id == item.id }) {
                // Workshop 等目录路径可能从 Steam 的 content 子目录变成 workshop 根目录；
                // ID 一致时只修路径，不能用低保真磁盘元数据覆盖原始来源详情。
                restoreDownloadRecord(recordID: item.id, localFileURL: url)
            } else {
                recordDownload(item: item, localFileURL: url)
            }
            attachRecoveredBakeArtifactIfNeeded(itemID: item.id)
            recoveredFromDisk += 1
        }

        // 已有记录也可能来自早期版本，彼时烘焙文件没有回写 artifact。
        for record in downloadedItems {
            attachRecoveredBakeArtifactIfNeeded(itemID: record.item.id)
        }

        if restored > 0 || recoveredFromDisk > 0 {
            print("[MediaLibraryService] Rebuilt media library: restored=\(restored), recoveredFromDisk=\(recoveredFromDisk)")
        }
    }

    private static let recoverableVideoExtensions: Set<String> = ["mp4", "mov", "webm", "m4v", "mkv"]

    private func recoveredWorkshopItem(at directoryURL: URL) -> MediaItem? {
        let projectRoot = WorkshopService.resolveWallpaperEngineProjectRoot(startingAt: directoryURL)
        let projectURL = projectRoot.appendingPathComponent("project.json")
        guard let data = try? Data(contentsOf: projectURL),
              let project = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let slug = directoryURL.lastPathComponent
        let workshopID = String(slug.dropFirst("workshop_".count))
        let hasSteamID = !workshopID.isEmpty && workshopID.allSatisfy(\.isNumber)
        let title = (project["title"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let type = ((project["type"] as? String) ?? "scene")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let previewURL = recoveredWorkshopPreviewURL(in: projectRoot)
        let fallbackURL = previewURL ?? projectRoot.appendingPathComponent("preview.gif")
        let pageURL = hasSteamID
            ? URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(workshopID)")!
            : directoryURL

        return MediaItem(
            slug: slug,
            title: title?.isEmpty == false ? title! : slug.replacingOccurrences(of: "_", with: " "),
            pageURL: pageURL,
            thumbnailURL: fallbackURL,
            resolutionLabel: type.capitalized,
            collectionTitle: "Wallpaper Engine",
            summary: nil,
            previewVideoURL: nil,
            posterURL: previewURL,
            tags: ["workshop", type],
            exactResolution: nil,
            durationSeconds: nil,
            downloadOptions: [],
            sourceName: "Wallpaper Engine",
            isAnimatedImage: previewURL?.pathExtension.lowercased() == "gif"
        )
    }

    private func recoveredWorkshopPreviewURL(in projectRoot: URL) -> URL? {
        let fileManager = FileManager.default
        let projectURL = projectRoot.appendingPathComponent("project.json")
        if let data = try? Data(contentsOf: projectURL),
           let project = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let previewName = project["preview"] as? String {
            let candidate = projectRoot.appendingPathComponent(previewName)
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        for name in ["preview.jpg", "preview.jpeg", "preview.png", "preview.webp", "preview.gif"] {
            let candidate = projectRoot.appendingPathComponent(name)
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private func recoveredVideoItem(at fileURL: URL) -> MediaItem {
        let fileName = fileURL.deletingPathExtension().lastPathComponent
        let components = fileName.split(separator: "-").map(String.init)
        let slug: String
        let sourceName: String

        if components.count >= 5,
           components[0] == "motionbgs", components[1] == "dongtai",
           ["col", "exc"].contains(components[2]), components[3].allSatisfy(\.isNumber) {
            slug = "dongtai_\(components[2])_\(components[3])"
            sourceName = "DongTai"
        } else if components.count >= 4,
                  components[0] == "motionbgs", components[1] == "wf",
                  components[2].allSatisfy(\.isNumber) {
            slug = "wf_\(components[2])"
            sourceName = "Wallsflow"
        } else if fileName.hasPrefix("motionbgs-") {
            var value = String(fileName.dropFirst("motionbgs-".count))
            for suffix in ["-4k", "-hd", "-original"] where value.hasSuffix(suffix) {
                value.removeLast(suffix.count)
                break
            }
            slug = value
            sourceName = "MotionBGs"
        } else {
            slug = "local_\(fileName)_\(fileURL.pathExtension.lowercased())"
            sourceName = "Local"
        }

        // 磁盘恢复的视频：异步补高清 poster，避免调度/设壁纸时只有列表小图
        Task { @MainActor in
            _ = await VideoThumbnailCache.shared.posterJPEGFileURL(forLocalVideo: fileURL)
        }

        return MediaItem(
            slug: slug,
            title: fileName.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " "),
            pageURL: fileURL,
            thumbnailURL: fileURL,
            resolutionLabel: "Video",
            collectionTitle: sourceName,
            summary: nil,
            previewVideoURL: fileURL,
            posterURL: VideoThumbnailCache.shared.cachedPosterJPEGFileURLIfExists(forLocalVideo: fileURL),
            tags: ["local", fileURL.pathExtension.lowercased()],
            exactResolution: nil,
            durationSeconds: nil,
            downloadOptions: [],
            sourceName: sourceName,
            isAnimatedImage: false
        )
    }

    private func attachRecoveredBakeArtifactIfNeeded(itemID: String) {
        guard let record = downloadRecords.first(where: { $0.item.id == itemID && $0.isActive }),
              itemID.hasPrefix("workshop_") else {
            return
        }

        if let existingArtifact = record.sceneBakeArtifact,
           SceneOfflineBakeService.isUsableBakedVideo(at: URL(fileURLWithPath: existingArtifact.videoPath)) {
            return
        }

        let bakeDirectory = DownloadPathManager.shared.sceneBakesFolderURL
            .appendingPathComponent(itemID, isDirectory: true)
        let fileManager = FileManager.default
        guard let candidates = try? fileManager.contentsOfDirectory(
            at: bakeDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let isWeb = WebOfflineBakeService.isWebProject(at: record.localFileURL)
        // 优先标准 bake 命名（新格式无 wallpaperWgpu 段；旧格式仍含 renderer 段；再退 web_v* / 任意 mp4）。
        let ranked = candidates
            .filter {
                $0.pathExtension.lowercased() == "mp4"
                    && !$0.lastPathComponent.hasPrefix(".")
                    && ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 1_024
            }
            .sorted { lhs, rhs in
                let lName = lhs.lastPathComponent
                let rName = rhs.lastPathComponent
                let lPreferred = isPreferredBakeFileName(lName, isWeb: isWeb)
                let rPreferred = isPreferredBakeFileName(rName, isWeb: isWeb)
                if lPreferred != rPreferred { return lPreferred && !rPreferred }
                let lDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lDate > rDate
            }
        guard let videoURL = ranked.first else { return }

        let attributes = try? fileManager.attributesOfItem(atPath: videoURL.path)
        let bakedAt = attributes?[.creationDate] as? Date ?? .now
        let name = videoURL.lastPathComponent
        let renderer: SceneBakeRenderer = {
            if name.contains("_\(SceneBakeRenderer.wallpaperEngineWeb.rawValue)_")
                || name.hasPrefix("web_v") {
                return .wallpaperEngineWeb
            }
            // 历史 Scene：`_wallpaperWgpu_`；新 Scene：UUID + 分辨率段且不含 web renderer 标记
            if name.contains("_\(SceneBakeRenderer.wallpaperWgpu.rawValue)_") {
                return .wallpaperWgpu
            }
            if !isWeb, SceneOfflineBakeService.looksLikeBakeProductFilename(name) {
                return .wallpaperWgpu
            }
            return isWeb ? .wallpaperEngineWeb : .wallpaperWgpu
        }()
        let analysisId: UUID = {
            if let eligibilityId = record.sceneBakeEligibility?.analysisId {
                return eligibilityId
            }
            if isWeb {
                return WebOfflineBakeService.stableAnalysisId(for: record.localFileURL)
            }
            // 新旧文件名均以前缀 UUID 为准
            return SceneOfflineBakeService.parseLeadingAnalysisId(from: name) ?? UUID()
        }()
        let artifact = SceneBakeArtifact(
            analysisId: analysisId,
            videoPath: videoURL.path,
            width: 0,
            height: 0,
            fps: 0,
            durationSeconds: 0,
            bakedAt: bakedAt,
            renderer: renderer
        )
        attachSceneBakeArtifact(itemID: itemID, artifact: artifact, regeneratePoster: true)
    }

    /// 标准 bake 命名优先于杂散 mp4。Web 认 wallpaperEngineWeb / web_v*；Scene 认新格式与历史 wallpaperWgpu。
    private func isPreferredBakeFileName(_ name: String, isWeb: Bool) -> Bool {
        if isWeb {
            return name.contains("_\(SceneBakeRenderer.wallpaperEngineWeb.rawValue)_")
                || name.hasPrefix("web_v")
        }
        return SceneOfflineBakeService.looksLikeBakeProductFilename(name)
    }

    private func restoreDownloadRecord(recordID: String, localFileURL: URL) {
        guard let index = downloadRecords.firstIndex(where: { $0.item.id == recordID }) else { return }

        downloadRecords[index].localFilePath = localFileURL.path
        downloadRecords[index].metadata.markLocalMutation(deleted: false)
        fileCache.markExisting(atPath: localFileURL.path)
        saveDlToCache(downloadRecords[index])
        syncDlIndex()
        downloadRecords = Array(downloadRecords)
    }

    /// 由 `SceneBakeEligibilityAnalyzer` 在后台线程完成后调用，写入带 UUID 的分析快照。
    /// - Parameter triggerAutoBake: 为 false 时不在此触发后台自动烘焙（例如用户正在「设为壁纸」流程里同步烘焙）。
    func attachSceneBakeEligibility(itemID: String, snapshot: SceneBakeEligibilitySnapshot, triggerAutoBake: Bool = true) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("library.media.attachSceneBakeEligibility0", ["itemID": itemID, "snapshot": try? JSONEncoder().encode(snapshot), "triggerAutoBake": triggerAutoBake]); return }

        guard let index = downloadRecords.firstIndex(where: { $0.item.id == itemID && $0.isActive }) else {
            return
        }
        let record = downloadRecords[index]

        // 同一工程、同一 analysisId：只刷新 notes/score 时间戳类字段，不触发重复 auto-bake。
        if let existing = record.sceneBakeEligibility,
           existing.analysisId == snapshot.analysisId,
           SceneBakeEligibilityAnalyzer.isSameContentRoot(existing.contentRootPath, snapshot.contentRootPath) {
            downloadRecords[index].sceneBakeEligibility = snapshot
            saveDlToCache(downloadRecords[index])
            syncDlIndex()
            downloadRecords = Array(downloadRecords)
            if triggerAutoBake,
               WaifuXPreferences.shared.bool(forKey: "auto_bake_scene"),
               snapshot.isEligibleForOfflineBake,
               SceneOfflineBakeService.usableArtifact(from: downloadRecords[index]) == nil {
                SceneOfflineBakeService.scheduleAutoBakeAfterEligibility(itemID: itemID)
            }
            return
        }

        if let artifact = record.sceneBakeArtifact, artifact.analysisId != snapshot.analysisId {
            let isRecoveringLegacyAssociation = record.sceneBakeEligibility == nil
                && record.hasSameLocalContent(as: URL(fileURLWithPath: snapshot.contentRootPath))
                && SceneOfflineBakeService.isUsableBakedVideo(at: URL(fileURLWithPath: artifact.videoPath))
            if isRecoveringLegacyAssociation {
                var reboundArtifact = artifact
                reboundArtifact.analysisId = snapshot.analysisId
                downloadRecords[index].sceneBakeArtifact = reboundArtifact
                print("[MediaLibraryService] Rebound recovered scene bake artifact for \(itemID)")
            } else {
                // 指针先清；磁盘旧文件在新 bake 成功后由 cleanupStaleBakeFiles 统一删除
                downloadRecords[index].sceneBakeArtifact = nil
            }
        }
        downloadRecords[index].sceneBakeEligibility = snapshot
        saveDlToCache(downloadRecords[index])
        syncDlIndex()
        downloadRecords = Array(downloadRecords)

        if triggerAutoBake, WaifuXPreferences.shared.bool(forKey: "auto_bake_scene"), snapshot.isEligibleForOfflineBake {
            SceneOfflineBakeService.scheduleAutoBakeAfterEligibility(itemID: itemID)
        }
    }

    func attachSceneBakeArtifact(
        itemID: String,
        artifact: SceneBakeArtifact,
        regeneratePoster: Bool = true
    ) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("library.media.attachSceneBakeArtifact0", ["itemID": itemID, "artifact": try? JSONEncoder().encode(artifact), "regeneratePoster": regeneratePoster]); return }

        guard let index = downloadRecords.firstIndex(where: { $0.item.id == itemID && $0.isActive }) else {
            return
        }
        downloadRecords[index].sceneBakeArtifact = artifact
        saveDlToCache(downloadRecords[index])
        syncDlIndex()
        downloadRecords = Array(downloadRecords)

        // 绑定新成片时清掉同目录历史随机 UUID 残留
        let videoURL = URL(fileURLWithPath: artifact.videoPath)
        SceneOfflineBakeService.cleanupStaleBakeFiles(
            inDirectory: videoURL.deletingLastPathComponent(),
            keeping: videoURL
        )

        // 确保烘焙视频有抽帧封面
        if regeneratePoster {
            let bakedVideoURL = videoURL
            Task { @MainActor in
                await regenerateSceneBakePosterAndNotify(
                    itemID: itemID,
                    videoURL: bakedVideoURL
                )
            }
        }
    }

    func upsert(_ item: MediaItem) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("library.media.upsert0", ["item": try? JSONEncoder().encode(item)]); return }

        var persistedItem = item

        if let favoriteIndex = favoriteRecords.firstIndex(where: { $0.item.id == item.id }) {
            persistedItem = persistedItem.preservingPersistedMetadata(from: favoriteRecords[favoriteIndex].item)
        }
        if let recentIndex = recentItems.firstIndex(where: { $0.id == item.id }) {
            persistedItem = persistedItem.preservingPersistedMetadata(from: recentItems[recentIndex])
        }
        if let downloadIndex = downloadRecords.firstIndex(where: { $0.item.id == item.id }) {
            persistedItem = persistedItem.preservingPersistedMetadata(from: downloadRecords[downloadIndex].item)
        }

        if let favoriteIndex = favoriteRecords.firstIndex(where: { $0.item.id == item.id }) {
            favoriteRecords[favoriteIndex].item = persistedItem
            saveFavToCache(favoriteRecords[favoriteIndex])
            syncFavIndex()
            favoriteRecords = Array(favoriteRecords)
        }

        if let recentIndex = recentItems.firstIndex(where: { $0.id == item.id }) {
            recentItems[recentIndex] = persistedItem
            persistRecents()
        }

        if let downloadIndex = downloadRecords.firstIndex(where: { $0.item.id == item.id }) {
            downloadRecords[downloadIndex].item = persistedItem
            saveDlToCache(downloadRecords[downloadIndex])
            syncDlIndex()
            downloadRecords = Array(downloadRecords)
        }
    }

    /// 更新下载记录的本地文件路径
    /// 当路径检测发现文件移动到新位置时调用
    /// - Parameters:
    ///   - itemID: 媒体项ID
    ///   - newURL: 新的文件URL
    func updateDownloadPath(for itemID: String, newURL: URL) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("library.media.updateDownloadPath0", ["itemID": itemID, "newURL": newURL]); return }

        if let index = downloadRecords.firstIndex(where: { $0.item.id == itemID }) {
            downloadRecords[index].localFilePath = newURL.path
            saveDlToCache(downloadRecords[index])
            syncDlIndex()
            downloadRecords = Array(downloadRecords)
            print("[MediaLibraryService] Updated download path for \(itemID) to \(newURL.path)")
        }
    }

    /// 批量替换下载记录中的路径前缀（用于目录迁移）
    func bulkUpdateDownloadPaths(oldPrefix: String, newPrefix: String) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("library.media.bulkUpdateDownloadPaths0", ["oldPrefix": oldPrefix, "newPrefix": newPrefix]); return }

        var changed = false
        // 更新下载记录
        for index in downloadRecords.indices {
            let oldPath = downloadRecords[index].localFilePath
            if oldPath.hasPrefix(oldPrefix) {
                let newPath = newPrefix + String(oldPath.dropFirst(oldPrefix.count))
                downloadRecords[index].localFilePath = newPath
                changed = true
            }
            // 更新 item 内部的路径（详情页背景使用这些字段）
            let itemPath = downloadRecords[index].item.pageURL.path
            if itemPath.hasPrefix(oldPrefix) {
                let newPath = newPrefix + String(itemPath.dropFirst(oldPrefix.count))
                downloadRecords[index].item.pageURL = URL(fileURLWithPath: newPath)
                changed = true
            }
            if let previewPath = downloadRecords[index].item.previewVideoURL?.path,
               previewPath.hasPrefix(oldPrefix) {
                let newPath = newPrefix + String(previewPath.dropFirst(oldPrefix.count))
                downloadRecords[index].item.previewVideoURL = URL(fileURLWithPath: newPath)
                changed = true
            }
            if var artifact = downloadRecords[index].sceneBakeArtifact,
               artifact.videoPath.hasPrefix(oldPrefix) {
                artifact.videoPath = newPrefix + String(artifact.videoPath.dropFirst(oldPrefix.count))
                downloadRecords[index].sceneBakeArtifact = artifact
                changed = true
            }
            if var eligibility = downloadRecords[index].sceneBakeEligibility,
               eligibility.contentRootPath.hasPrefix(oldPrefix) {
                eligibility.contentRootPath = newPrefix + String(eligibility.contentRootPath.dropFirst(oldPrefix.count))
                downloadRecords[index].sceneBakeEligibility = eligibility
                changed = true
            }
        }
        // 更新收藏记录（详情页背景同样使用 item 内部路径）
        var favoritesChanged = false
        for index in favoriteRecords.indices {
            let itemPath = favoriteRecords[index].item.pageURL.path
            if itemPath.hasPrefix(oldPrefix) {
                let newPath = newPrefix + String(itemPath.dropFirst(oldPrefix.count))
                favoriteRecords[index].item.pageURL = URL(fileURLWithPath: newPath)
                favoritesChanged = true
            }
            if let previewPath = favoriteRecords[index].item.previewVideoURL?.path,
               previewPath.hasPrefix(oldPrefix) {
                let newPath = newPrefix + String(previewPath.dropFirst(oldPrefix.count))
                favoriteRecords[index].item.previewVideoURL = URL(fileURLWithPath: newPath)
                favoritesChanged = true
            }
        }
        if changed {
            rebuildDlCache()
            downloadRecords = Array(downloadRecords)
        }
        if favoritesChanged {
            rebuildFavCache()
            favoriteRecords = Array(favoriteRecords)
        }
        if changed || favoritesChanged {
            print("[MediaLibraryService] Bulk updated paths from \(oldPrefix) to \(newPrefix)")
        }
    }

    func recordViewed(_ item: MediaItem) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("library.media.recordViewed0", ["item": try? JSONEncoder().encode(item)]); return }

        recentItems.removeAll { $0.id == item.id }
        recentItems.insert(item, at: 0)
        recentItems = Array(recentItems.prefix(18))
        persistRecents()
        upsert(item)
    }

    // MARK: - 批量删除

    /// 批量删除收藏记录
    /// - Parameter ids: 要删除的项目 ID 集合
    func removeFavoriteRecords(withIDs ids: Set<String>) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("library.media.removeFavoriteRecords0", ["ids": try? JSONEncoder().encode(ids)]); return }

        for (index, record) in favoriteRecords.enumerated() {
            if ids.contains(record.item.id) {
                favoriteRecords[index].metadata.markLocalMutation(deleted: true)
                saveFavToCache(favoriteRecords[index])
            }
        }
        syncFavIndex()
        favoriteRecords = Array(favoriteRecords)
    }

    /// 删除单个下载记录（含物理文件）
    /// - Parameter ids: 要删除的项目 ID 集合
    func removeDownloadRecord(withID id: String) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("library.media.removeDownloadRecord0", ["id": id]); return }

        if let index = downloadRecords.firstIndex(where: { $0.item.id == id }) {
            let record = downloadRecords[index]
            let filePath = record.localFilePath
            // 标记软删除
            downloadRecords[index].metadata.markLocalMutation(deleted: true)
            saveDlToCache(downloadRecords[index])
            syncDlIndex()
            downloadRecords = Array(downloadRecords)
            // 删除物理文件
            deletePhysicalFile(at: filePath)
            // 删除对应的烘焙产物
            deleteSceneBakeArtifacts(for: record)
            VideoThumbnailCache.shared.removeSceneBakePoster(
                itemID: record.item.id,
                videoPath: record.sceneBakeArtifact?.videoPath
            )
        }
    }

    /// 批量删除下载记录（含物理文件）
    /// - Parameter ids: 要删除的项目 ID 集合
    func removeDownloadRecords(withIDs ids: Set<String>) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("library.media.removeDownloadRecords0", ["ids": try? JSONEncoder().encode(ids)]); return }

        var recordsToDelete: [MediaDownloadRecord] = []
        for (index, record) in downloadRecords.enumerated() {
            if ids.contains(record.item.id) {
                recordsToDelete.append(record)
                downloadRecords[index].metadata.markLocalMutation(deleted: true)
                saveDlToCache(downloadRecords[index])
            }
        }
        syncDlIndex()
        downloadRecords = Array(downloadRecords)
        // 删除所有对应的物理文件及烘焙产物
        for record in recordsToDelete {
            deletePhysicalFile(at: record.localFilePath)
            deleteSceneBakeArtifacts(for: record)
            VideoThumbnailCache.shared.removeSceneBakePoster(
                itemID: record.item.id,
                videoPath: record.sceneBakeArtifact?.videoPath
            )
        }
    }

    /// 安全删除物理文件
    private func deletePhysicalFile(at path: String) {
        guard !path.isEmpty else { return }
        let fm = FileManager.default
        // 如果是 Workshop 下载的内容，删除整个 workshop_xxx 文件夹
        if let workshopRoot = workshopRootDirectory(for: path),
           fm.fileExists(atPath: workshopRoot) {
            do {
                try fm.removeItem(atPath: workshopRoot)
                print("[MediaLibraryService] ✅ Deleted workshop folder: \(workshopRoot)")
            } catch {
                print("[MediaLibraryService] ⚠️ Failed to delete workshop folder \(workshopRoot): \(error)")
            }
            return
        }
        if fm.fileExists(atPath: path) {
            do {
                try fm.removeItem(atPath: path)
                print("[MediaLibraryService] ✅ Deleted physical file: \(path)")
            } catch {
                print("[MediaLibraryService] ⚠️ Failed to delete file \(path): \(error)")
            }
        }
    }

    /// 公开方法：清除指定下载记录的 Scene 烘焙缓存（删除文件 + 重置 artifact），供重新烘焙使用
    func clearSceneBakeArtifact(itemID: String) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("library.media.clearSceneBakeArtifact0", ["itemID": itemID]); return }

        guard let index = downloadRecords.firstIndex(where: { $0.item.id == itemID }) else { return }
        let record = downloadRecords[index]
        deleteSceneBakeArtifacts(for: record)
        VideoThumbnailCache.shared.removeSceneBakePoster(
            itemID: record.item.id,
            videoPath: record.sceneBakeArtifact?.videoPath
        )
        objectWillChange.send()
        downloadRecords[index].sceneBakeArtifact = nil
        saveDlToCache(downloadRecords[index])
        syncDlIndex()
        downloadRecords = Array(downloadRecords)
        NotificationCenter.default.post(
            name: .sceneOfflineBakeThumbnailDidUpdate,
            object: record.item.id,
            userInfo: [:]
        )
    }

    /// 公开方法：清除烘焙 MP4 + 重置 artifact，但**保留** Scene 烘焙静态预览图 (poster)。
    /// 用户在「更多」菜单点「删除烘焙产物」时使用，便于删除后立即用 poster 重设锁屏/桌面。
    /// sceneBakeEligibility 保留，用户后续仍可重新烘焙。
    func clearSceneBakeArtifactKeepingPoster(itemID: String) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("library.media.clearSceneBakeArtifactKeepingPoster0", ["itemID": itemID]); return }

        guard let index = downloadRecords.firstIndex(where: { $0.item.id == itemID }) else { return }
        let record = downloadRecords[index]
        deleteSceneBakeArtifacts(for: record)
        // 注意：故意不调用 VideoThumbnailCache.removeSceneBakePoster，
        // 保留 scene_bake_<itemID.md5>.jpg 供调用方用于锁屏/桌面重设
        objectWillChange.send()
        downloadRecords[index].sceneBakeArtifact = nil
        saveDlToCache(downloadRecords[index])
        syncDlIndex()
        downloadRecords = Array(downloadRecords)
        NotificationCenter.default.post(
            name: .sceneOfflineBakeThumbnailDidUpdate,
            object: record.item.id,
            userInfo: [:]
        )
    }

    /// 删除与下载记录关联的 Scene 烘焙产物
    private func deleteSceneBakeArtifacts(for record: MediaDownloadRecord) {
        let fm = FileManager.default
        let existenceCache = FileExistenceCache.shared

        // 1. 删除烘焙视频文件（如果存在）
        if let artifact = record.sceneBakeArtifact,
           !artifact.videoPath.isEmpty {
            let videoPath = artifact.videoPath
            if fm.fileExists(atPath: videoPath) {
                do {
                    try fm.removeItem(atPath: videoPath)
                    print("[MediaLibraryService] ✅ Deleted scene bake video: \(videoPath)")
                } catch {
                    print("[MediaLibraryService] ⚠️ Failed to delete scene bake video \(videoPath): \(error)")
                }
            }
            // 详情页 previewVideoURL 依赖存在性缓存；删后必须失效，否则仍当文件在
            existenceCache.invalidate(atPath: videoPath)
            let standardized = (videoPath as NSString).standardizingPath
            if standardized != videoPath {
                existenceCache.invalidate(atPath: standardized)
            }
        }
        // 2. 删除该 item 对应的烘焙目录（清理空目录或残留文件）
        let safeID = record.item.id.replacingOccurrences(of: "/", with: "_")
        let bakeDir = DownloadPathManager.shared.sceneBakesFolderURL
            .appendingPathComponent(safeID, isDirectory: true)
        if fm.fileExists(atPath: bakeDir.path) {
            do {
                try fm.removeItem(at: bakeDir)
                print("[MediaLibraryService] ✅ Deleted scene bake directory: \(bakeDir.path)")
            } catch {
                print("[MediaLibraryService] ⚠️ Failed to delete scene bake directory \(bakeDir.path): \(error)")
            }
            existenceCache.invalidate(atPath: bakeDir.path)
        }
    }

    /// 检测并返回 Workshop 下载的根文件夹路径
    private func workshopRootDirectory(for path: String) -> String? {
        let components = path.components(separatedBy: "/")
        if let steamappsIndex = components.firstIndex(of: "steamapps"),
           steamappsIndex > 0 {
            let workshopRoot = components[0..<steamappsIndex].joined(separator: "/")
            let folderName = components[steamappsIndex - 1]
            if folderName.hasPrefix("workshop_") {
                return workshopRoot
            }
        }
        return nil
    }

    /// 批量删除最近播放记录
    /// - Parameter ids: 要删除的项目 ID 集合
    func removeRecentItems(withIDs ids: Set<String>) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("library.media.removeRecentItems0", ["ids": try? JSONEncoder().encode(ids)]); return }

        recentItems.removeAll { ids.contains($0.id) }
        persistRecents()
    }

    // MARK: - 文件夹移动

    /// 库文件夹归属作用域。
    /// 收藏与下载各自维护独立的 folderID，绝不能互相污染，
    /// 否则会出现“下载归夹后收藏里的项消失 / 反过来突然冒出来”的假象。
    enum FolderMembershipScope {
        case favorites
        case downloads
    }

    /// 将空字符串 / 空白 folderID 规范为 nil（根目录）。
    static func normalizedFolderID(_ folderID: String?) -> String? {
        guard let folderID else { return nil }
        let trimmed = folderID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 将媒体项移动到指定文件夹。
    /// - Parameters:
    ///   - mediaID: 媒体项 ID
    ///   - folderID: 目标文件夹 ID；传 nil 表示移回根目录
    ///   - scope: 只改收藏或只改下载，禁止跨集合写 folderID
    ///   - fallback: 用于「扫描进来但还没有 DownloadRecord 的项」的回退信息。
    ///     当 scope=.downloads 且 favorite/download 都不命中时，先调 `recordDownload` 把该项补登成下载记录，
    ///     再写 folderID，避免拖入文件夹后看起来无效。
    func moveMediaToFolder(
        mediaID: String,
        folderID: String?,
        scope: FolderMembershipScope,
        fallback: (item: MediaItem, fileURL: URL)? = nil
    ) {
        let targetFolderID = Self.normalizedFolderID(folderID)

        switch scope {
        case .favorites:
            if let index = favoriteRecords.firstIndex(where: { $0.item.id == mediaID }) {
                favoriteRecords[index].folderID = targetFolderID
                saveFavToCache(favoriteRecords[index])
                syncFavIndex()
                favoriteRecords = Array(favoriteRecords)
            }
        case .downloads:
            var hit = false
            if let index = downloadRecords.firstIndex(where: { $0.item.id == mediaID }) {
                downloadRecords[index].folderID = targetFolderID
                saveDlToCache(downloadRecords[index])
                syncDlIndex()
                downloadRecords = Array(downloadRecords)
                hit = true
            }
            // 都没命中：尝试从 fallback 补登记，再写 folderID
            if !hit, let fallback {
                recordDownload(item: fallback.item, localFileURL: fallback.fileURL)
                if let index = downloadRecords.firstIndex(where: { $0.item.id == mediaID }) {
                    downloadRecords[index].folderID = targetFolderID
                    saveDlToCache(downloadRecords[index])
                    syncDlIndex()
                    downloadRecords = Array(downloadRecords)
                }
            }
        }
    }

    func moveItemsToRoot(fromFolder folderID: String) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("library.media.moveItemsToRoot0", ["folderID": folderID]); return }

        guard let folderID = Self.normalizedFolderID(folderID) else { return }
        var favoritesChanged = false
        for index in favoriteRecords.indices where favoriteRecords[index].folderID == folderID {
            favoriteRecords[index].folderID = nil
            favoritesChanged = true
        }
        var downloadsChanged = false
        for index in downloadRecords.indices where downloadRecords[index].folderID == folderID {
            downloadRecords[index].folderID = nil
            downloadsChanged = true
        }
        if favoritesChanged {
            rebuildFavCache()
            favoriteRecords = Array(favoriteRecords)
        }
        if downloadsChanged {
            rebuildDlCache()
            downloadRecords = Array(downloadRecords)
        }
    }

    /// 审计无效 folderID：空字符串、指向不存在文件夹、或跨集合引用。
    ///
    /// 重要：该方法保持历史名称以兼容现有调用方，但现在只读并报告，
    /// 永远不会把 folderID 改成 nil，也不会重建或覆盖库缓存。
    /// 用户明确执行“移到根目录”或删除文件夹时，仍由 moveItemsToRoot()
    /// 负责执行实际变更。
    @discardableResult
    func sanitizeFolderMembership(
        validFavoriteFolderIDs: Set<String>,
        validDownloadFolderIDs: Set<String>
    ) -> Int {
        let favoriteAudit = LibraryFolderMembershipPolicy.audit(
            folderIDs: favoriteRecords.map(\.folderID),
            validFolderIDs: validFavoriteFolderIDs
        )
        let downloadAudit = LibraryFolderMembershipPolicy.audit(
            folderIDs: downloadRecords.map(\.folderID),
            validFolderIDs: validDownloadFolderIDs
        )
        let invalidCount = favoriteAudit.invalidCount + downloadAudit.invalidCount

        if invalidCount > 0 {
            let invalidIDs = favoriteAudit.invalidFolderIDs
                .union(downloadAudit.invalidFolderIDs)
                .sorted()
                .joined(separator: ",")
            print(
                "[MediaLibraryService] Preserved \(invalidCount) invalid folder "
                    + "membership field(s); folderIDs=\(invalidIDs)"
            )
        }
        return invalidCount
    }

    /// 清理无效下载记录（文件不存在的记录）
    /// - Returns: 清理的记录数量
    @discardableResult
    func cleanupInvalidDownloadRecords() -> Int {
        guard BackgroundRuntimeRole.isHelper else { return 0 }
        var cleanedCount = 0

        for (index, record) in downloadRecords.enumerated() {
            // 检查文件是否存在（如果是活跃记录）
            if record.isActive && !FileManager.default.fileExists(atPath: record.localFilePath) {
                print("[MediaLibraryService] Cleaning up invalid record: \(record.item.id), file not found at \(record.localFilePath)")
                downloadRecords[index].metadata.markLocalMutation(deleted: true)
                cleanedCount += 1
            }
        }

        if cleanedCount > 0 {
            rebuildDlCache()
            downloadRecords = Array(downloadRecords)
            print("[MediaLibraryService] Cleaned up \(cleanedCount) invalid download records")
        }

        return cleanedCount
    }

    /// 修复指定记录的路径（由 DirectoryMigrationService 调用）
    func repairDownloadPath(itemID: String, newPath: String) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("library.media.repairDownloadPath0", ["itemID": itemID, "newPath": newPath]); return }

        guard let index = downloadRecords.firstIndex(where: { $0.item.id == itemID }) else { return }
        let oldPath = downloadRecords[index].localFilePath
        let oldPrefix = (oldPath as NSString).deletingLastPathComponent
        let newPrefix = (newPath as NSString).deletingLastPathComponent
        downloadRecords[index].localFilePath = newPath
        // 同步更新 item 内部路径
        let itemPath = downloadRecords[index].item.pageURL.path
        if itemPath.hasPrefix(oldPrefix) {
            downloadRecords[index].item.pageURL = URL(fileURLWithPath: newPrefix + String(itemPath.dropFirst(oldPrefix.count)))
        }
        if let previewPath = downloadRecords[index].item.previewVideoURL?.path, previewPath.hasPrefix(oldPrefix) {
            downloadRecords[index].item.previewVideoURL = URL(fileURLWithPath: newPrefix + String(previewPath.dropFirst(oldPrefix.count)))
        }
        if var artifact = downloadRecords[index].sceneBakeArtifact, artifact.videoPath.hasPrefix(oldPrefix) {
            artifact.videoPath = newPrefix + String(artifact.videoPath.dropFirst(oldPrefix.count))
            downloadRecords[index].sceneBakeArtifact = artifact
        }
        if var eligibility = downloadRecords[index].sceneBakeEligibility, eligibility.contentRootPath.hasPrefix(oldPrefix) {
            eligibility.contentRootPath = newPrefix + String(eligibility.contentRootPath.dropFirst(oldPrefix.count))
            downloadRecords[index].sceneBakeEligibility = eligibility
        }
        saveDlToCache(downloadRecords[index])
        syncDlIndex()
    }

    /// 将指定记录标记为已删除（由 DirectoryMigrationService 调用）
    func deactivateDownloadRecord(itemID: String) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("library.media.deactivateDownloadRecord0", ["itemID": itemID]); return }

        guard let index = downloadRecords.firstIndex(where: { $0.item.id == itemID }) else { return }
        downloadRecords[index].metadata.markLocalMutation(deleted: true)
        saveDlToCache(downloadRecords[index])
        syncDlIndex()
    }

    private func loadPersistedState() {
        let decoder = JSONDecoder()

        // 1) 优先从 Cache 加载，同时把旧 UserDefaults 作为一次性补缺来源
        let cachedFavs: [MediaFavoriteRecord] = cache.loadAll(category: favCategory)
        var migratedFavs: [MediaFavoriteRecord] = []
        var favKeysToRemove: [String] = []

        if let data = defaults.data(forKey: favoriteRecordsKey),
           let decoded = try? decoder.decode([MediaFavoriteRecord].self, from: data) {
            migratedFavs.append(contentsOf: decoded)
            favKeysToRemove.append(favoriteRecordsKey)
        }
        if let data = defaults.data(forKey: legacyFavoritesKey),
           let decoded = try? decoder.decode([MediaItem].self, from: data) {
            migratedFavs.append(contentsOf: decoded.map { MediaFavoriteRecord(item: $0) })
            favKeysToRemove.append(legacyFavoritesKey)
        }

        favoriteRecords = deduplicated(mergedByStableID(
            primary: cachedFavs,
            fallback: migratedFavs,
            id: \.id
        ))
        if !migratedFavs.isEmpty, rebuildFavCache() {
            favKeysToRemove.forEach { defaults.removeObject(forKey: $0) }
        }

        // --- 下载 ---
        let cachedDls: [MediaDownloadRecord] = cache.loadAll(category: dlCategory)
        var migratedDls: [MediaDownloadRecord] = []
        var dlKeysToRemove: [String] = []

        if let data = defaults.data(forKey: downloadRecordsKey),
           let decoded = try? decoder.decode([MediaDownloadRecord].self, from: data) {
            migratedDls.append(contentsOf: decoded)
            dlKeysToRemove.append(downloadRecordsKey)
        }
        if let data = defaults.data(forKey: legacyDownloadsKey),
           let decoded = try? decoder.decode([MediaDownloadRecord].self, from: data) {
            migratedDls.append(contentsOf: decoded)
            dlKeysToRemove.append(legacyDownloadsKey)
        }

        downloadRecords = mergedByStableID(
            primary: cachedDls,
            fallback: migratedDls,
            id: \.id
        )
        if !migratedDls.isEmpty, rebuildDlCache() {
            dlKeysToRemove.forEach { defaults.removeObject(forKey: $0) }
        }

        // --- 孤儿记录恢复 ---
        // 扫描缓存目录，找回索引丢失但文件仍在磁盘上的记录（版本更新/异常退出可能导致索引不同步）
        let orphanedData = cache.recoverOrphanedRecordData(for: [favCategory, dlCategory])
        var favFixed = false
        var dlFixed = false

        if let favOrphans = orphanedData[favCategory], !favOrphans.isEmpty {
            let recovered = favOrphans.compactMap { try? decoder.decode(MediaFavoriteRecord.self, from: $0) }
            if !recovered.isEmpty {
                let existingIDs = Set(favoriteRecords.map(\.id))
                let newRecords = recovered.filter { !existingIDs.contains($0.id) }
                if !newRecords.isEmpty {
                    favoriteRecords.append(contentsOf: newRecords)
                    favFixed = true
                    print("[MediaLibraryService] Recovered \(newRecords.count) orphaned favorite records from disk")
                }
            }
        }
        if let dlOrphans = orphanedData[dlCategory], !dlOrphans.isEmpty {
            let recovered = dlOrphans.compactMap { try? decoder.decode(MediaDownloadRecord.self, from: $0) }
            if !recovered.isEmpty {
                let existingIDs = Set(downloadRecords.map(\.id))
                let newRecords = recovered.filter { !existingIDs.contains($0.id) }
                if !newRecords.isEmpty {
                    downloadRecords.append(contentsOf: newRecords)
                    dlFixed = true
                    print("[MediaLibraryService] Recovered \(newRecords.count) orphaned download records from disk")
                }
            }
        }
        if favFixed { rebuildFavCache() }
        if dlFixed { rebuildDlCache() }

        // --- 最近浏览（量小，保留 UserDefaults）---
        if let data = defaults.data(forKey: recentsKey),
           let decoded = try? JSONDecoder().decode([MediaItem].self, from: data) {
            recentItems = Array(deduplicated(decoded).prefix(18))
        }
    }

    // MARK: - 最近浏览持久化（量小仍用 UserDefaults）

    private var persistRecentsWork: DispatchWorkItem?
    private static let persistQueue = DispatchQueue(label: "com.waifux.media.persist", qos: .utility)

    private static func schedulePersist<Value: Encodable & Sendable>(
        value: Value,
        key: String,
        assigningTo storage: inout DispatchWorkItem?
    ) {
        storage?.cancel()
        let work = DispatchWorkItem(block: { @Sendable in
            if let data = try? JSONEncoder().encode(value) {
                WaifuXPreferences.shared.set(data, forKey: key)
            }
        })
        storage = work
        persistQueue.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func persistRecents() {
        Self.schedulePersist(
            value: recentItems,
            key: recentsKey,
            assigningTo: &persistRecentsWork
        )
    }

    /// 外部调用入口：批量重建下载 Cache（由 DirectoryMigrationService 等调用）
    func persistDownloads() {
        guard BackgroundRuntimeRole.isHelper else { return }
        rebuildDlCache()
    }

    // MARK: - 云同步导入方法

    /// 同步导入收藏记录（合并模式）
    func syncImportFavorites(_ records: [MediaFavoriteRecord]) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("library.media.syncImportFavorites0", ["records": try? JSONEncoder().encode(records)]); return }

        for record in records {
            let id = record.id
            if let existingIndex = favoriteRecords.firstIndex(where: { $0.id == id }) {
                favoriteRecords[existingIndex] = record
                _ = saveFavToCache(record)
            } else {
                favoriteRecords.append(record)
                _ = saveFavToCache(record)
            }
        }
        _ = syncFavIndex()
    }

    /// 同步导入下载记录（合并模式）
    func syncImportDownloads(_ records: [MediaDownloadRecord]) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("library.media.syncImportDownloads0", ["records": try? JSONEncoder().encode(records)]); return }

        for record in records {
            let id = record.id
            if let existingIndex = downloadRecords.firstIndex(where: { $0.id == id }) {
                downloadRecords[existingIndex] = record
                _ = saveDlToCache(record)
            } else {
                downloadRecords.append(record)
                _ = saveDlToCache(record)
            }
        }
        rebuildDlCache()
    }

    /// 同步导入最近浏览记录
    func syncImportRecents(_ items: [MediaItem]) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("library.media.syncImportRecents0", ["items": try? JSONEncoder().encode(items)]); return }

        recentItems = Array(deduplicated(items).prefix(18))
        persistRecents()
    }

    /// 同步删除收藏（按 ID 集合）
    func syncRemoveFavorites(ids: Set<String>) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("library.media.syncRemoveFavorites0", ["ids": try? JSONEncoder().encode(ids)]); return }

        favoriteRecords.removeAll { ids.contains($0.id) }
        for id in ids {
            _ = deleteFavFromCache(id)
        }
        _ = syncFavIndex()
    }

    /// 同步删除下载（按 ID 集合）
    func syncRemoveDownloads(ids: Set<String>) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("library.media.syncRemoveDownloads0", ["ids": try? JSONEncoder().encode(ids)]); return }

        downloadRecords.removeAll { ids.contains($0.id) }
        for id in ids {
            _ = deleteDlFromCache(id)
        }
        rebuildDlCache()
    }

    // MARK: - Cache 辅助方法

    @discardableResult
    private func saveFavToCache(_ record: MediaFavoriteRecord) -> Bool {
        cache.save(record, key: "\(favCategory)/\(record.id)")
    }

    @discardableResult
    private func deleteFavFromCache(_ id: String) -> Bool {
        cache.delete(key: "\(favCategory)/\(id)")
    }

    @discardableResult
    private func saveDlToCache(_ record: MediaDownloadRecord) -> Bool {
        cache.save(record, key: "\(dlCategory)/\(record.id)")
    }

    @discardableResult
    private func deleteDlFromCache(_ id: String) -> Bool {
        cache.delete(key: "\(dlCategory)/\(id)")
    }

    @discardableResult
    private func syncFavIndex() -> Bool {
        let ids = favoriteRecords.map(\.id)
        return cache.saveIndex(ids, key: "index/\(favCategory)")
    }

    @discardableResult
    private func syncDlIndex() -> Bool {
        let ids = downloadRecords.map(\.id)
        return cache.saveIndex(ids, key: "index/\(dlCategory)")
    }

    @discardableResult
    private func rebuildFavCache() -> Bool {
        for record in favoriteRecords {
            guard saveFavToCache(record) else { return false }
        }
        return syncFavIndex()
    }

    @discardableResult
    private func rebuildDlCache() -> Bool {
        for record in downloadRecords {
            guard saveDlToCache(record) else { return false }
        }
        return syncDlIndex()
    }

    private func deduplicated(_ items: [MediaItem]) -> [MediaItem] {
        var seen = Set<String>()
        return items.filter { item in
            seen.insert(item.id).inserted
        }
    }

    private func deduplicated(_ records: [MediaFavoriteRecord]) -> [MediaFavoriteRecord] {
        var seen = Set<String>()
        return records.filter { record in
            seen.insert(record.id).inserted
        }
    }
}

@MainActor
final class WallpaperLibraryService: ObservableObject {
    static let shared = WallpaperLibraryService()

    @Published private(set) var favoriteRecords: [WallpaperFavoriteRecord] = [] {
        didSet { rebuildFavoriteIndex() }
    }
    @Published private(set) var downloadRecords: [WallpaperDownloadRecord] = [] {
        didSet { rebuildDownloadIndex() }
    }

    // MARK: - 持久化（Cache 替代 UserDefaults）

    private let cache = CachePersistenceService.shared
    private let favCategory = "wallpaper/fav"
    private let dlCategory = "wallpaper/dl"

    /// UserDefaults key — 仅迁移用
    private let favoriteRecordsKey = "wallpaper_favorite_records_v2"
    private let downloadRecordsKey = "wallpaper_download_records_v2"
    private let legacyFavoritesKey = "local_favorites"
    private let legacyCloudFavoritesKey = "cloud_favorites"
    private let legacyDownloadsKey = "wallpaper_downloads_v1"
    private let defaults = WaifuXPreferences.shared

    /// ⚡ 快速查找索引：活跃收藏/下载的 ID 集合，避免主线程线性扫描
    private var favoriteIDSet: Set<String> = []
    private var downloadIDSet: Set<String> = []
    /// 下载记录字典索引（wallpaper.id → record），O(1) 查找替代 O(n) first(where:)
    private var downloadRecordIndex: [String: WallpaperDownloadRecord] = [:]
    /// 文件存在性缓存，避免主线程反复 FileManager.fileExists(atPath:)
    private let fileCache = FileExistenceCache.shared

    func backgroundLibrarySnapshot() -> Data {
        (try? BackgroundPropertyList.encode([
            "favorites": JSONEncoder().encode(favoriteRecords),
            "downloads": JSONEncoder().encode(downloadRecords)
        ])) ?? Data()
    }

    private init() {
        if BackgroundRuntimeRole.isRemoteUI {
            BackgroundRuntimeBridge.observeLibrary { [weak self] values in
                guard let self, let data = values["wallpaper"] as? Data, let snapshot = try? BackgroundPropertyList.decode(data) else { return }
                if let bytes = snapshot["favorites"] as? Data, let records = try? JSONDecoder().decode([WallpaperFavoriteRecord].self, from: bytes) { self.favoriteRecords = records }
                if let bytes = snapshot["downloads"] as? Data, let records = try? JSONDecoder().decode([WallpaperDownloadRecord].self, from: bytes) { self.downloadRecords = records }
            }
            return
        }

        // ⚠️ 不在 init 中读 UserDefaults，避免 _CFXPreferences 递归栈溢出
        // 用静态数组持有 observer token（非 Sendable），避免 deinit 中访问 actor 隔离属性
        Self.registerMemoryPressureObserver(service: self)
    }

    /// 持有所有 observer tokens，避免被 dealloc 导致 observer 自动移除
    private static var _observerTokens: [Any] = []
    private static func registerMemoryPressureObserver(service: WallpaperLibraryService) {
        let token = NotificationCenter.default.addObserver(
            forName: .appDidReceiveMemoryPressure,
            object: nil,
            queue: nil,
            using: { _ in
                Task { @MainActor in
                    service.fileCache.clearAll()
                }
            }
        )
        _observerTokens.append(token)
    }

    /// 延迟恢复持久化数据（必须在 AppDelegate.applicationDidFinishLaunching 中调用）
    func restoreSavedData() {
        guard BackgroundRuntimeRole.isHelper else { return }
        loadPersistedState()
    }

    private func rebuildFavoriteIndex() {
        favoriteIDSet = Set(favoriteRecords.filter(\.isActive).map(\.wallpaper.id))
    }

    private func rebuildDownloadIndex() {
        downloadIDSet = Set(downloadRecords.filter(\.isActive).map(\.wallpaper.id))
        downloadRecordIndex = Dictionary(
            downloadRecords.filter(\.isActive).map { ($0.wallpaper.id, $0) },
            uniquingKeysWith: { current, _ in current }
        )
    }

    var favoriteWallpapers: [Wallpaper] {
        favoriteRecords
            .filter(\.isActive)
            .map(\.wallpaper)
    }

    /// 获取指定文件夹内的收藏壁纸
    func favoriteWallpapers(inFolder folderID: String?) -> [Wallpaper] {
        let target = Self.normalizedFolderID(folderID)
        return favoriteRecords
            .filter { $0.isActive && Self.normalizedFolderID($0.folderID) == target }
            .map(\.wallpaper)
    }

    /// 获取指定文件夹内的下载壁纸
    func downloadedWallpapers(inFolder folderID: String?) -> [WallpaperDownloadRecord] {
        let target = Self.normalizedFolderID(folderID)
        return downloadRecords.filter {
            $0.isActive && Self.normalizedFolderID($0.folderID) == target
        }
    }

    var downloadedWallpapers: [WallpaperDownloadRecord] {
        downloadRecords.filter(\.isActive)
    }

    var pendingSyncFavorites: [WallpaperFavoriteRecord] {
        favoriteRecords.filter { $0.metadata.syncState != .synced || $0.metadata.isDeleted }
    }

    var pendingSyncDownloads: [WallpaperDownloadRecord] {
        downloadRecords.filter { $0.metadata.syncState != .synced || $0.metadata.isDeleted }
    }

    func toggleFavorite(_ wallpaper: Wallpaper) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("library.wallpaper.toggleFavorite0", ["wallpaper": try? JSONEncoder().encode(wallpaper)]); return }

        // ⚡ 先用 Set 快速判断是否存在，避免全表 firstIndex 线性扫描
        if let index = favoriteRecords.firstIndex(where: { $0.wallpaper.id == wallpaper.id && $0.isActive }) {
            favoriteRecords[index].wallpaper = wallpaper
            favoriteRecords[index].metadata.markLocalMutation(deleted: true)
        } else if let index = favoriteRecords.firstIndex(where: { $0.wallpaper.id == wallpaper.id }) {
            // 已存在但不活跃（软删除），重新激活
            favoriteRecords[index].wallpaper = wallpaper
            favoriteRecords[index].metadata.markLocalMutation(deleted: false)
        } else {
            favoriteRecords.insert(WallpaperFavoriteRecord(wallpaper: wallpaper), at: 0)
        }

        favoriteRecords = deduplicated(favoriteRecords)
        // 单条写入 Cache
        if let record = favoriteRecords.first(where: { $0.wallpaper.id == wallpaper.id }) {
            saveFavToCache(record)
        }
        syncFavIndex()
    }

    func isFavorite(_ wallpaper: Wallpaper) -> Bool {
        // ⚡ O(1) Set 查找，替代线性扫描
        favoriteIDSet.contains(wallpaper.id)
    }

    func isFavorite(id: String) -> Bool {
        favoriteIDSet.contains(id)
    }

    func favoriteRecord(for wallpaperID: String) -> WallpaperFavoriteRecord? {
        guard favoriteIDSet.contains(wallpaperID) else { return nil }
        return favoriteRecords.first { $0.wallpaper.id == wallpaperID && $0.isActive }
    }

    func downloadRecord(for wallpaperID: String) -> WallpaperDownloadRecord? {
        guard downloadIDSet.contains(wallpaperID) else { return nil }
        return downloadRecordIndex[wallpaperID]
    }

    func downloadRecord(forLocalFilePath path: String) -> WallpaperDownloadRecord? {
        downloadRecords.first { $0.localFilePath == path && $0.isActive }
    }

    /// 通过壁纸的远程 URL（path 字段）反查下载记录
    func downloadRecord(forRemoteURL url: URL) -> WallpaperDownloadRecord? {
        let urlString = url.absoluteString
        return downloadRecords.first { record in
            record.isActive && record.wallpaper.path == urlString
        }
    }

    func markAsLooped(localFilePath path: String) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("library.wallpaper.markAsLooped0", ["path": path]); return }

        guard let index = downloadRecords.firstIndex(where: { $0.localFilePath == path }) else { return }
        downloadRecords[index].isLooped = true
        saveDlToCache(downloadRecords[index])
        syncDlIndex()
    }

    func isDownloaded(_ wallpaper: Wallpaper) -> Bool {
        // ⚡ 先通过 Set 快速判断（O(1)），再通过字典索引 O(1) 获取记录
        guard downloadIDSet.contains(wallpaper.id),
              let record = downloadRecordIndex[wallpaper.id] else {
            return false
        }
        // 使用缓存检查文件存在性，避免主线程 FileManager.fileExists(atPath:)
        let fileExists = fileCache.fileExists(atPath: record.localFilePath)
        if !fileExists {
            print("[WallpaperLibraryService] File not found for downloaded wallpaper: \(wallpaper.id) at \(record.localFilePath)")
        }
        return fileExists
    }

    /// 已下载或本地导入壁纸的可分享文件 URL（文件需在磁盘上存在）
    func localFileURLIfAvailable(for wallpaper: Wallpaper) -> URL? {
        if wallpaper.id.hasPrefix("local_"),
           let u = wallpaper.fullImageURL,
           u.isFileURL,
           fileCache.fileExists(atPath: u.path) {
            return u
        }
        guard downloadIDSet.contains(wallpaper.id),
              let record = downloadRecordIndex[wallpaper.id] else {
            return nil
        }
        let url = URL(fileURLWithPath: record.localFilePath)
        guard fileCache.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// 登记下载记录。
    /// - Parameter folderID: 可选目标文件夹。传入时写入/覆盖归属；
    ///   不传时保留已有 folderID（避免二次 record 把作者批量下载归夹冲掉）。
    func recordDownload(_ wallpaper: Wallpaper, fileURL: URL, folderID: String? = nil) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("library.wallpaper.recordDownload0", ["wallpaper": try? JSONEncoder().encode(wallpaper), "fileURL": fileURL, "folderID": folderID]); return }

        let targetFolderID = Self.normalizedFolderID(folderID)
        if let index = downloadRecords.firstIndex(where: { $0.wallpaper.id == wallpaper.id }) {
            downloadRecords[index].wallpaper = wallpaper
            downloadRecords[index].localFilePath = fileURL.path
            downloadRecords[index].downloadedAt = .now
            downloadRecords[index].metadata.markLocalMutation(deleted: false)
            // 仅在显式指定时改归属；nil 表示调用方不关心，保留现有 folderID
            if let targetFolderID {
                downloadRecords[index].folderID = targetFolderID
            }
        } else {
            downloadRecords.insert(
                WallpaperDownloadRecord(
                    wallpaper: wallpaper,
                    localFilePath: fileURL.path,
                    folderID: targetFolderID
                ),
                at: 0
            )
        }

        // 预缓存文件存在性，后续 isDownloaded() 不再走 FileManager
        fileCache.markExisting(atPath: fileURL.path)

        // 单条写入 Cache；强制数组重赋值以触发 didSet / downloadIDSet 重建
        let record = downloadRecords.first { $0.wallpaper.id == wallpaper.id }
        if let record { saveDlToCache(record) }
        syncDlIndex()
        downloadRecords = Array(downloadRecords)
        upsert(wallpaper)
    }

    func upsert(_ wallpaper: Wallpaper) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("library.wallpaper.upsert0", ["wallpaper": try? JSONEncoder().encode(wallpaper)]); return }

        if let favoriteIndex = favoriteRecords.firstIndex(where: { $0.wallpaper.id == wallpaper.id }) {
            favoriteRecords[favoriteIndex].wallpaper = wallpaper
            saveFavToCache(favoriteRecords[favoriteIndex])
            syncFavIndex()
            favoriteRecords = Array(favoriteRecords)
        }

        if let downloadIndex = downloadRecords.firstIndex(where: { $0.wallpaper.id == wallpaper.id }) {
            downloadRecords[downloadIndex].wallpaper = wallpaper
            saveDlToCache(downloadRecords[downloadIndex])
            syncDlIndex()
            downloadRecords = Array(downloadRecords)
        }
    }

    /// 批量更新壁纸（性能优化：只持久化一次）
    func upsertBatch(_ wallpapers: [Wallpaper]) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("library.wallpaper.upsertBatch0", ["wallpapers": try? JSONEncoder().encode(wallpapers)]); return }

        var favoritesChanged = false
        var downloadsChanged = false

        for wallpaper in wallpapers {
            if let favoriteIndex = favoriteRecords.firstIndex(where: { $0.wallpaper.id == wallpaper.id }) {
                favoriteRecords[favoriteIndex].wallpaper = wallpaper
                favoritesChanged = true
            }

            if let downloadIndex = downloadRecords.firstIndex(where: { $0.wallpaper.id == wallpaper.id }) {
                downloadRecords[downloadIndex].wallpaper = wallpaper
                downloadsChanged = true
            }
        }

        // 批量持久化
        if favoritesChanged {
            rebuildFavCache()
            favoriteRecords = Array(favoriteRecords)
        }
        if downloadsChanged {
            rebuildDlCache()
            downloadRecords = Array(downloadRecords)
        }
    }

    /// 更新下载记录的本地文件路径
    /// 当路径检测发现文件移动到新位置时调用
    /// - Parameters:
    ///   - wallpaperID: 壁纸ID
    ///   - newURL: 新的文件URL
    func updateDownloadPath(for wallpaperID: String, newURL: URL) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("library.wallpaper.updateDownloadPath0", ["wallpaperID": wallpaperID, "newURL": newURL]); return }

        if let index = downloadRecords.firstIndex(where: { $0.wallpaper.id == wallpaperID }) {
            downloadRecords[index].localFilePath = newURL.path
            saveDlToCache(downloadRecords[index])
            syncDlIndex()
            downloadRecords = Array(downloadRecords)
            print("[WallpaperLibraryService] Updated download path for \(wallpaperID) to \(newURL.path)")
        }
    }

    /// 批量替换下载记录和收藏记录中的路径前缀（用于目录迁移）
    func bulkUpdateDownloadPaths(oldPrefix: String, newPrefix: String) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("library.wallpaper.bulkUpdateDownloadPaths0", ["oldPrefix": oldPrefix, "newPrefix": newPrefix]); return }

        var changed = false
        // 更新下载记录
        for index in downloadRecords.indices {
            let oldPath = downloadRecords[index].localFilePath
            if oldPath.hasPrefix(oldPrefix) {
                let newPath = newPrefix + String(oldPath.dropFirst(oldPrefix.count))
                downloadRecords[index].localFilePath = newPath
                changed = true
            }
            // 更新 wallpaper 内部的路径（详情页背景使用这些字段）
            var wallpaper = downloadRecords[index].wallpaper
            if updateWallpaperPaths(&wallpaper, oldPrefix: oldPrefix, newPrefix: newPrefix) {
                downloadRecords[index].wallpaper = wallpaper
                changed = true
            }
        }
        // 更新收藏记录（封面图和详情背景同样使用 wallpaper 内部路径）
        var favoritesChanged = false
        for index in favoriteRecords.indices {
            var wallpaper = favoriteRecords[index].wallpaper
            if updateWallpaperPaths(&wallpaper, oldPrefix: oldPrefix, newPrefix: newPrefix) {
                favoriteRecords[index].wallpaper = wallpaper
                favoritesChanged = true
            }
        }
        if changed {
            rebuildDlCache()
            downloadRecords = Array(downloadRecords)
        }
        if favoritesChanged {
            rebuildFavCache()
            favoriteRecords = Array(favoriteRecords)
        }
        if changed || favoritesChanged {
            print("[WallpaperLibraryService] Bulk updated paths from \(oldPrefix) to \(newPrefix)")
        }
    }

    /// 更新 Wallpaper 内部所有路径字段；支持 file:// 前缀和普通路径
    private func updateWallpaperPaths(_ wallpaper: inout Wallpaper, oldPrefix: String, newPrefix: String) -> Bool {
        var changed = false
        if let newPath = Self.replacePathPrefix(wallpaper.url, oldPrefix: oldPrefix, newPrefix: newPrefix) {
            wallpaper.url = newPath; changed = true
        }
        if let newPath = Self.replacePathPrefix(wallpaper.path, oldPrefix: oldPrefix, newPrefix: newPrefix) {
            wallpaper.path = newPath; changed = true
        }
        if let newPath = Self.replacePathPrefix(wallpaper.thumbs.large, oldPrefix: oldPrefix, newPrefix: newPrefix) {
            wallpaper.thumbs.large = newPath; changed = true
        }
        if let newPath = Self.replacePathPrefix(wallpaper.thumbs.original, oldPrefix: oldPrefix, newPrefix: newPrefix) {
            wallpaper.thumbs.original = newPath; changed = true
        }
        if let newPath = Self.replacePathPrefix(wallpaper.thumbs.small, oldPrefix: oldPrefix, newPrefix: newPrefix) {
            wallpaper.thumbs.small = newPath; changed = true
        }
        return changed
    }

    /// 替换路径前缀；支持 file:// 前缀和普通路径
    private static func replacePathPrefix(_ path: String, oldPrefix: String, newPrefix: String) -> String? {
        // 处理 file:// 前缀的路径
        if let url = URL(string: path), url.isFileURL {
            let filePath = url.path
            if filePath.hasPrefix(oldPrefix) {
                let newPath = newPrefix + String(filePath.dropFirst(oldPrefix.count))
                return URL(fileURLWithPath: newPath).absoluteString
            }
        }
        // 普通路径匹配
        if path.hasPrefix(oldPrefix) {
            return newPrefix + String(path.dropFirst(oldPrefix.count))
        }
        return nil
    }

    // MARK: - 壁纸批量删除

    /// 批量删除壁纸收藏
    /// - Parameter ids: 要删除的项目 ID 集合
    func removeWallpaperFavorites(withIDs ids: Set<String>) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("library.wallpaper.removeWallpaperFavorites0", ["ids": try? JSONEncoder().encode(ids)]); return }

        for (index, record) in favoriteRecords.enumerated() {
            if ids.contains(record.wallpaper.id) {
                favoriteRecords[index].metadata.markLocalMutation(deleted: true)
                saveFavToCache(favoriteRecords[index])
            }
        }
        syncFavIndex()
        favoriteRecords = Array(favoriteRecords)
    }

    /// 批量删除壁纸下载记录（含物理文件）
    /// - Parameter ids: 要删除的项目 ID 集合
    func removeWallpaperDownloads(withIDs ids: Set<String>) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("library.wallpaper.removeWallpaperDownloads0", ["ids": try? JSONEncoder().encode(ids)]); return }

        var filesToDelete: [String] = []
        for (index, record) in downloadRecords.enumerated() {
            if ids.contains(record.wallpaper.id) {
                filesToDelete.append(record.localFilePath)
                downloadRecords[index].metadata.markLocalMutation(deleted: true)
                saveDlToCache(downloadRecords[index])
            }
        }
        syncDlIndex()
        downloadRecords = Array(downloadRecords)
        // 删除所有对应的物理文件
        for path in filesToDelete {
            wallpaperDeletePhysicalFile(at: path)
        }
    }

    /// 安全删除壁纸物理文件
    private func wallpaperDeletePhysicalFile(at path: String) {
        guard !path.isEmpty else { return }
        let fm = FileManager.default
        // 如果是 Workshop 下载的内容，删除整个 workshop_xxx 文件夹
        if let workshopRoot = wallpaperWorkshopRootDirectory(for: path),
           fm.fileExists(atPath: workshopRoot) {
            do {
                try fm.removeItem(atPath: workshopRoot)
                print("[WallpaperLibraryService] ✅ Deleted workshop folder: \(workshopRoot)")
            } catch {
                print("[WallpaperLibraryService] ⚠️ Failed to delete workshop folder \(workshopRoot): \(error)")
            }
            return
        }
        if fm.fileExists(atPath: path) {
            do {
                try fm.removeItem(atPath: path)
                print("[WallpaperLibraryService] ✅ Deleted physical file: \(path)")
            } catch {
                print("[WallpaperLibraryService] ⚠️ Failed to delete file \(path): \(error)")
            }
        }
    }

    /// 检测并返回 Workshop 下载的根文件夹路径
    private func wallpaperWorkshopRootDirectory(for path: String) -> String? {
        let components = path.components(separatedBy: "/")
        if let steamappsIndex = components.firstIndex(of: "steamapps"),
           steamappsIndex > 0 {
            let workshopRoot = components[0..<steamappsIndex].joined(separator: "/")
            let folderName = components[steamappsIndex - 1]
            if folderName.hasPrefix("workshop_") {
                return workshopRoot
            }
        }
        return nil
    }

    /// 清理无效下载记录（文件不存在的记录）
    /// - Returns: 清理的记录数量
    @discardableResult
    func cleanupInvalidDownloadRecords() -> Int {
        guard BackgroundRuntimeRole.isHelper else { return 0 }
        var cleanedCount = 0

        for (index, record) in downloadRecords.enumerated() {
            // 检查文件是否存在（如果是活跃记录）
            if record.isActive && !FileManager.default.fileExists(atPath: record.localFilePath) {
                print("[WallpaperLibraryService] Cleaning up invalid record: \(record.wallpaper.id), file not found at \(record.localFilePath)")
                downloadRecords[index].metadata.markLocalMutation(deleted: true)
                cleanedCount += 1
            }
        }

        if cleanedCount > 0 {
            rebuildDlCache()
            downloadRecords = Array(downloadRecords)
            print("[WallpaperLibraryService] Cleaned up \(cleanedCount) invalid download records")
        }

        return cleanedCount
    }

    /// 修复指定记录的路径（由 DirectoryMigrationService 调用）
    func repairDownloadPath(recordID: String, newPath: String) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("library.wallpaper.repairDownloadPath0", ["recordID": recordID, "newPath": newPath]); return }

        guard let index = downloadRecords.firstIndex(where: { $0.id == recordID }) else { return }
        downloadRecords[index].localFilePath = newPath
        saveDlToCache(downloadRecords[index])
        syncDlIndex()
    }

    /// 将指定记录标记为已删除（由 DirectoryMigrationService 调用）
    func deactivateDownloadRecord(recordID: String) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("library.wallpaper.deactivateDownloadRecord0", ["recordID": recordID]); return }

        guard let index = downloadRecords.firstIndex(where: { $0.id == recordID }) else { return }
        downloadRecords[index].metadata.markLocalMutation(deleted: true)
        saveDlToCache(downloadRecords[index])
        syncDlIndex()
    }

    // MARK: - 文件夹移动

    /// 库文件夹归属作用域。
    /// 收藏与下载各自维护独立的 folderID，绝不能互相污染。
    enum FolderMembershipScope {
        case favorites
        case downloads
    }

    /// 将空字符串 / 空白 folderID 规范为 nil（根目录）。
    static func normalizedFolderID(_ folderID: String?) -> String? {
        guard let folderID else { return nil }
        let trimmed = folderID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 将壁纸移动到指定文件夹。
    /// - Parameters:
    ///   - wallpaperID: 壁纸 ID
    ///   - folderID: 目标文件夹 ID；传 nil 表示移回根目录
    ///   - scope: 只改收藏或只改下载，禁止跨集合写 folderID
    ///   - fallback: 用于「扫描进来但还没有 DownloadRecord 的项」的回退信息。
    ///     当 scope=.downloads 且都不命中时，先调 `recordDownload` 补登记再写 folderID。
    func moveWallpaperToFolder(
        wallpaperID: String,
        folderID: String?,
        scope: FolderMembershipScope,
        fallback: (wallpaper: Wallpaper, fileURL: URL)? = nil
    ) {
        let targetFolderID = Self.normalizedFolderID(folderID)

        switch scope {
        case .favorites:
            if let index = favoriteRecords.firstIndex(where: { $0.wallpaper.id == wallpaperID }) {
                favoriteRecords[index].folderID = targetFolderID
                saveFavToCache(favoriteRecords[index])
                syncFavIndex()
                favoriteRecords = Array(favoriteRecords)
            }
        case .downloads:
            var hit = false
            if let index = downloadRecords.firstIndex(where: { $0.wallpaper.id == wallpaperID }) {
                downloadRecords[index].folderID = targetFolderID
                saveDlToCache(downloadRecords[index])
                syncDlIndex()
                downloadRecords = Array(downloadRecords)
                hit = true
            }
            if !hit, let fallback {
                recordDownload(fallback.wallpaper, fileURL: fallback.fileURL)
                if let index = downloadRecords.firstIndex(where: { $0.wallpaper.id == wallpaperID }) {
                    downloadRecords[index].folderID = targetFolderID
                    saveDlToCache(downloadRecords[index])
                    syncDlIndex()
                    downloadRecords = Array(downloadRecords)
                }
            }
        }
    }

    func moveItemsToRoot(fromFolder folderID: String) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("library.wallpaper.moveItemsToRoot0", ["folderID": folderID]); return }

        guard let folderID = Self.normalizedFolderID(folderID) else { return }
        var favoritesChanged = false
        for index in favoriteRecords.indices where favoriteRecords[index].folderID == folderID {
            favoriteRecords[index].folderID = nil
            favoritesChanged = true
        }
        var downloadsChanged = false
        for index in downloadRecords.indices where downloadRecords[index].folderID == folderID {
            downloadRecords[index].folderID = nil
            downloadsChanged = true
        }
        if favoritesChanged {
            rebuildFavCache()
            favoriteRecords = Array(favoriteRecords)
        }
        if downloadsChanged {
            rebuildDlCache()
            downloadRecords = Array(downloadRecords)
        }
    }

    /// 审计无效 folderID：空字符串、指向不存在文件夹、或跨集合引用。
    ///
    /// 重要：该方法保持历史名称以兼容现有调用方，但现在只读并报告，
    /// 永远不会把 folderID 改成 nil，也不会重建或覆盖库缓存。
    /// 用户明确执行“移到根目录”或删除文件夹时，仍由 moveItemsToRoot()
    /// 负责执行实际变更。
    @discardableResult
    func sanitizeFolderMembership(
        validFavoriteFolderIDs: Set<String>,
        validDownloadFolderIDs: Set<String>
    ) -> Int {
        let favoriteAudit = LibraryFolderMembershipPolicy.audit(
            folderIDs: favoriteRecords.map(\.folderID),
            validFolderIDs: validFavoriteFolderIDs
        )
        let downloadAudit = LibraryFolderMembershipPolicy.audit(
            folderIDs: downloadRecords.map(\.folderID),
            validFolderIDs: validDownloadFolderIDs
        )
        let invalidCount = favoriteAudit.invalidCount + downloadAudit.invalidCount

        if invalidCount > 0 {
            let invalidIDs = favoriteAudit.invalidFolderIDs
                .union(downloadAudit.invalidFolderIDs)
                .sorted()
                .joined(separator: ",")
            print(
                "[WallpaperLibraryService] Preserved \(invalidCount) invalid folder "
                    + "membership field(s); folderIDs=\(invalidIDs)"
            )
        }
        return invalidCount
    }

    private func loadPersistedState() {
        let decoder = JSONDecoder()

        // 1) 优先从 Cache 加载，同时把旧 UserDefaults 作为一次性补缺来源
        let cachedFavs: [WallpaperFavoriteRecord] = cache.loadAll(category: favCategory)
        var migratedFavs: [WallpaperFavoriteRecord] = []
        var favKeysToRemove: [String] = []

        if let data = defaults.data(forKey: favoriteRecordsKey),
           let decoded = try? decoder.decode([WallpaperFavoriteRecord].self, from: data) {
            migratedFavs.append(contentsOf: decoded)
            favKeysToRemove.append(favoriteRecordsKey)
        }
        if let data = defaults.data(forKey: legacyFavoritesKey),
           let decoded = try? decoder.decode([Wallpaper].self, from: data) {
            migratedFavs.append(contentsOf: decoded.map { WallpaperFavoriteRecord(wallpaper: $0) })
            favKeysToRemove.append(legacyFavoritesKey)
        }
        if let data = defaults.data(forKey: legacyCloudFavoritesKey),
           let decoded = try? decoder.decode([Wallpaper].self, from: data) {
            migratedFavs.append(contentsOf: decoded.map { WallpaperFavoriteRecord(wallpaper: $0) })
            favKeysToRemove.append(legacyCloudFavoritesKey)
        }

        favoriteRecords = deduplicated(mergedByStableID(
            primary: cachedFavs,
            fallback: migratedFavs,
            id: \.id
        ))
        if !migratedFavs.isEmpty, rebuildFavCache() {
            favKeysToRemove.forEach { defaults.removeObject(forKey: $0) }
        }

        // --- 下载 ---
        let cachedDls: [WallpaperDownloadRecord] = cache.loadAll(category: dlCategory)
        var migratedDls: [WallpaperDownloadRecord] = []
        var dlKeysToRemove: [String] = []

        if let data = defaults.data(forKey: downloadRecordsKey),
           let decoded = try? decoder.decode([WallpaperDownloadRecord].self, from: data) {
            migratedDls.append(contentsOf: decoded)
            dlKeysToRemove.append(downloadRecordsKey)
        }
        if let data = defaults.data(forKey: legacyDownloadsKey),
           let decoded = try? decoder.decode([WallpaperDownloadRecord].self, from: data) {
            migratedDls.append(contentsOf: decoded)
            dlKeysToRemove.append(legacyDownloadsKey)
        }

        downloadRecords = mergedByStableID(
            primary: cachedDls,
            fallback: migratedDls,
            id: \.id
        )
        if !migratedDls.isEmpty, rebuildDlCache() {
            dlKeysToRemove.forEach { defaults.removeObject(forKey: $0) }
        }

        // --- 孤儿记录恢复 ---
        let orphanedData = cache.recoverOrphanedRecordData(for: [favCategory, dlCategory])
        var favFixed = false
        var dlFixed = false

        if let favOrphans = orphanedData[favCategory], !favOrphans.isEmpty {
            let recovered = favOrphans.compactMap { try? decoder.decode(WallpaperFavoriteRecord.self, from: $0) }
            if !recovered.isEmpty {
                let existingIDs = Set(favoriteRecords.map(\.id))
                let newRecords = recovered.filter { !existingIDs.contains($0.id) }
                if !newRecords.isEmpty {
                    favoriteRecords.append(contentsOf: newRecords)
                    favFixed = true
                    print("[WallpaperLibraryService] Recovered \(newRecords.count) orphaned favorite records from disk")
                }
            }
        }
        if let dlOrphans = orphanedData[dlCategory], !dlOrphans.isEmpty {
            let recovered = dlOrphans.compactMap { try? decoder.decode(WallpaperDownloadRecord.self, from: $0) }
            if !recovered.isEmpty {
                let existingIDs = Set(downloadRecords.map(\.id))
                let newRecords = recovered.filter { !existingIDs.contains($0.id) }
                if !newRecords.isEmpty {
                    downloadRecords.append(contentsOf: newRecords)
                    dlFixed = true
                    print("[WallpaperLibraryService] Recovered \(newRecords.count) orphaned download records from disk")
                }
            }
        }
        if favFixed { rebuildFavCache() }
        if dlFixed { rebuildDlCache() }
    }

    /// 外部调用入口：批量重建下载 Cache（由 DirectoryMigrationService 等调用）
    func persistDownloads() {
        guard BackgroundRuntimeRole.isHelper else { return }
        rebuildDlCache()
    }

    // MARK: - 云同步导入方法

    /// 同步导入收藏记录（合并模式，不覆盖本地已有记录除非云端更新）
    func syncImportFavorites(_ records: [WallpaperFavoriteRecord]) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("library.wallpaper.syncImportFavorites0", ["records": try? JSONEncoder().encode(records)]); return }

        for record in records {
            let id = record.id
            if let existingIndex = favoriteRecords.firstIndex(where: { $0.id == id }) {
                // 本地已存在，用云端更新覆盖
                favoriteRecords[existingIndex] = record
                _ = saveFavToCache(record)
            } else {
                // 本地不存在，新增
                favoriteRecords.append(record)
                _ = saveFavToCache(record)
            }
        }
        _ = syncFavIndex()
    }

    /// 同步导入下载记录（合并模式）
    func syncImportDownloads(_ records: [WallpaperDownloadRecord]) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("library.wallpaper.syncImportDownloads0", ["records": try? JSONEncoder().encode(records)]); return }

        for record in records {
            let id = record.id
            if let existingIndex = downloadRecords.firstIndex(where: { $0.id == id }) {
                downloadRecords[existingIndex] = record
                _ = saveDlToCache(record)
            } else {
                downloadRecords.append(record)
                _ = saveDlToCache(record)
            }
        }
        rebuildDlCache()
    }

    /// 同步删除收藏（按 ID 集合）
    func syncRemoveFavorites(ids: Set<String>) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("library.wallpaper.syncRemoveFavorites0", ["ids": try? JSONEncoder().encode(ids)]); return }

        favoriteRecords.removeAll { ids.contains($0.id) }
        for id in ids {
            _ = deleteFavFromCache(id)
        }
        _ = syncFavIndex()
    }

    /// 同步删除下载（按 ID 集合）
    func syncRemoveDownloads(ids: Set<String>) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("library.wallpaper.syncRemoveDownloads0", ["ids": try? JSONEncoder().encode(ids)]); return }

        downloadRecords.removeAll { ids.contains($0.id) }
        for id in ids {
            _ = deleteDlFromCache(id)
        }
        rebuildDlCache()
    }

    // MARK: - Cache 辅助方法

    /// 保存单条收藏记录到 Cache
    @discardableResult
    private func saveFavToCache(_ record: WallpaperFavoriteRecord) -> Bool {
        cache.save(record, key: "\(favCategory)/\(record.id)")
    }

    /// 删除单条收藏记录
    @discardableResult
    private func deleteFavFromCache(_ id: String) -> Bool {
        cache.delete(key: "\(favCategory)/\(id)")
    }

    /// 保存单条下载记录到 Cache
    @discardableResult
    private func saveDlToCache(_ record: WallpaperDownloadRecord) -> Bool {
        cache.save(record, key: "\(dlCategory)/\(record.id)")
    }

    /// 删除单条下载记录
    @discardableResult
    private func deleteDlFromCache(_ id: String) -> Bool {
        cache.delete(key: "\(dlCategory)/\(id)")
    }

    /// 同步收藏索引（活跃 ID 列表）
    @discardableResult
    private func syncFavIndex() -> Bool {
        let ids = favoriteRecords.map(\.id)
        return cache.saveIndex(ids, key: "index/\(favCategory)")
    }

    /// 同步下载索引
    @discardableResult
    private func syncDlIndex() -> Bool {
        let ids = downloadRecords.map(\.id)
        return cache.saveIndex(ids, key: "index/\(dlCategory)")
    }

    /// 全量重建收藏缓存（用于迁移/批量操作后）
    @discardableResult
    private func rebuildFavCache() -> Bool {
        for record in favoriteRecords {
            guard saveFavToCache(record) else { return false }
        }
        return syncFavIndex()
    }

    /// 全量重建下载缓存
    @discardableResult
    private func rebuildDlCache() -> Bool {
        for record in downloadRecords {
            guard saveDlToCache(record) else { return false }
        }
        return syncDlIndex()
    }

    private func deduplicated(_ records: [WallpaperFavoriteRecord]) -> [WallpaperFavoriteRecord] {
        var seen = Set<String>()
        return records.filter { record in
            seen.insert(record.id).inserted
        }
    }
}
