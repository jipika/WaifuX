import Foundation
import Combine

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
    private let defaults = UserDefaults.standard

    /// ⚡ 快速查找索引：活跃收藏/下载的 ID 集合，避免主线程线性扫描
    private var favoriteIDSet: Set<String> = []
    private var downloadIDSet: Set<String> = []
    /// 下载记录字典索引（item.id → record），O(1) 查找替代 O(n) first(where:)
    private var downloadRecordIndex: [String: MediaDownloadRecord] = [:]
    /// 文件存在性缓存，避免主线程反复 FileManager.fileExists(atPath:)
    private let fileCache = FileExistenceCache.shared

    private init() {
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
        loadPersistedState()
        Task { [weak self] in
            await self?.rebuildManagedMediaLibrary()
        }
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

    /// 供 ViewModel 缓存重建时快速排除已下载项目的 ID 集合
    var downloadIDSetForRebuild: Set<String> { downloadIDSet }

    var favoriteItems: [MediaItem] {
        favoriteRecords
            .filter(\.isActive)
            .map(\.item)
    }

    /// 获取指定文件夹内的收藏项目
    func favoriteItems(inFolder folderID: String?) -> [MediaItem] {
        favoriteRecords
            .filter { $0.isActive && $0.folderID == folderID }
            .map(\.item)
    }

    /// 获取指定文件夹内的下载项目
    func downloadedItems(inFolder folderID: String?) -> [MediaDownloadRecord] {
        downloadRecords.filter { $0.isActive && $0.folderID == folderID }
    }

    var downloadedItems: [MediaDownloadRecord] {
        downloadRecords.filter(\.isActive)
    }

    /// 根目录下载项目（无 folderID）
    var rootDownloadedItems: [MediaDownloadRecord] {
        downloadRecords.filter { $0.isActive && $0.folderID == nil }
    }

    var pendingSyncFavorites: [MediaFavoriteRecord] {
        favoriteRecords.filter { $0.metadata.syncState != .synced || $0.metadata.isDeleted }
    }

    var pendingSyncDownloads: [MediaDownloadRecord] {
        downloadRecords.filter { $0.metadata.syncState != .synced || $0.metadata.isDeleted }
    }

    func toggleFavorite(_ item: MediaItem) {
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
        guard let index = downloadRecords.firstIndex(where: { $0.localFilePath == path }) else { return }
        downloadRecords[index].isLooped = true
        saveDlToCache(downloadRecords[index])
        syncDlIndex()
    }

    func clearLooped(localFilePath path: String) {
        guard let index = downloadRecords.firstIndex(where: { $0.localFilePath == path }) else { return }
        downloadRecords[index].isLooped = false
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
        }
        return fileExists
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

    func recordDownload(item: MediaItem, localFileURL: URL) {
        if let index = downloadRecords.firstIndex(where: { $0.item.id == item.id }) {
            downloadRecords[index].item = item
            downloadRecords[index].localFilePath = localFileURL.path
            downloadRecords[index].downloadedAt = .now
            downloadRecords[index].metadata.markLocalMutation(deleted: false)
        } else {
            downloadRecords.insert(
                MediaDownloadRecord(item: item, localFilePath: localFileURL.path),
                at: 0
            )
        }

        // 预缓存文件存在性，后续 isDownloaded() 不再走 FileManager
        fileCache.markExisting(atPath: localFileURL.path)

        // 单条写入 Cache
        if let record = downloadRecords.first(where: { $0.item.id == item.id }) {
            saveDlToCache(record)
        }
        syncDlIndex()
        upsert(item)

        SceneBakeEligibilityAnalyzer.scheduleAnalysisIfSceneProject(itemID: item.id, localFileURL: localFileURL)

        // 视频文件下载完成后异步生成抽帧，供封面展示使用
        let videoExts: Set<String> = ["mp4", "mov", "webm", "m4v", "mkv"]
        let videoFileURL: URL? = if videoExts.contains(localFileURL.pathExtension.lowercased()) {
            localFileURL
        } else {
            // 目录类型（壁纸引擎源）：解析其中的视频文件
            MediaItem.resolveLocalVideoFile(from: localFileURL)
        }
        if let videoFileURL {
            Task { @MainActor in
                _ = await VideoThumbnailCache.shared.posterJPEGFileURL(forLocalVideo: videoFileURL)
            }
        }
    }

    /// Ensure an existing local media file has a persistent library record.
    /// Applying a wallpaper is an explicit user action, so it must not remain cache-only.
    func ensureDownloadRecord(item: MediaItem, localFileURL: URL) {
        if let existing = downloadRecords.first(where: { $0.item.id == item.id && $0.isActive }),
           existing.hasSameLocalContent(as: localFileURL) {
            return
        }
        recordDownload(item: item, localFileURL: localFileURL)
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

        return MediaItem(
            slug: slug,
            title: fileName.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " "),
            pageURL: fileURL,
            thumbnailURL: fileURL,
            resolutionLabel: "Video",
            collectionTitle: sourceName,
            summary: nil,
            previewVideoURL: fileURL,
            posterURL: nil,
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

        let videoURL = candidates
            .filter {
                $0.pathExtension.lowercased() == "mp4"
                    && !$0.lastPathComponent.hasPrefix(".")
                    && ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 1_024
            }
            .max {
                ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                    < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
            }
        guard let videoURL else { return }

        let attributes = try? fileManager.attributesOfItem(atPath: videoURL.path)
        let bakedAt = attributes?[.creationDate] as? Date ?? .now
        let artifact = SceneBakeArtifact(
            analysisId: record.sceneBakeEligibility?.analysisId ?? UUID(),
            videoPath: videoURL.path,
            width: 0,
            height: 0,
            fps: 0,
            durationSeconds: 0,
            bakedAt: bakedAt,
            renderer: .wallpaperWgpu
        )
        attachSceneBakeArtifact(itemID: itemID, artifact: artifact, regeneratePoster: false)
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
        guard let index = downloadRecords.firstIndex(where: { $0.item.id == itemID && $0.isActive }) else {
            return
        }
        let record = downloadRecords[index]
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
                downloadRecords[index].sceneBakeArtifact = nil
            }
        }
        downloadRecords[index].sceneBakeEligibility = snapshot
        saveDlToCache(downloadRecords[index])
        syncDlIndex()
        downloadRecords = Array(downloadRecords)

        if triggerAutoBake, UserDefaults.standard.bool(forKey: "auto_bake_scene"), snapshot.isEligibleForOfflineBake {
            SceneOfflineBakeService.scheduleAutoBakeAfterEligibility(itemID: itemID)
        }
    }

    func attachSceneBakeArtifact(
        itemID: String,
        artifact: SceneBakeArtifact,
        regeneratePoster: Bool = true
    ) {
        guard let index = downloadRecords.firstIndex(where: { $0.item.id == itemID && $0.isActive }) else {
            return
        }
        downloadRecords[index].sceneBakeArtifact = artifact
        saveDlToCache(downloadRecords[index])
        syncDlIndex()
        downloadRecords = Array(downloadRecords)

        // 确保烘焙视频有抽帧封面
        if regeneratePoster {
            let bakedVideoURL = URL(fileURLWithPath: artifact.videoPath)
            Task { @MainActor in
                await regenerateSceneBakePosterAndNotify(
                    itemID: itemID,
                    videoURL: bakedVideoURL
                )
            }
        }
    }

    func upsert(_ item: MediaItem) {
        if let favoriteIndex = favoriteRecords.firstIndex(where: { $0.item.id == item.id }) {
            favoriteRecords[favoriteIndex].item = item
            saveFavToCache(favoriteRecords[favoriteIndex])
            syncFavIndex()
            favoriteRecords = Array(favoriteRecords)
        }

        if let recentIndex = recentItems.firstIndex(where: { $0.id == item.id }) {
            recentItems[recentIndex] = item
            persistRecents()
        }

        if let downloadIndex = downloadRecords.firstIndex(where: { $0.item.id == item.id }) {
            downloadRecords[downloadIndex].item = item
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
        }
    }

    /// 批量删除下载记录（含物理文件）
    /// - Parameter ids: 要删除的项目 ID 集合
    func removeDownloadRecords(withIDs ids: Set<String>) {
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
        }
    }

    /// 安全删除物理文件
    private func deletePhysicalFile(at path: String) {
        guard !path.isEmpty else { return }
        let fm = FileManager.default
        // 如果是 SteamCMD Workshop 下载的内容，删除整个 workshop_xxx 文件夹
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

        // 1. 删除烘焙视频文件（如果存在）
        if let artifact = record.sceneBakeArtifact,
           !artifact.videoPath.isEmpty,
           fm.fileExists(atPath: artifact.videoPath) {
            do {
                try fm.removeItem(atPath: artifact.videoPath)
                print("[MediaLibraryService] ✅ Deleted scene bake video: \(artifact.videoPath)")
            } catch {
                print("[MediaLibraryService] ⚠️ Failed to delete scene bake video \(artifact.videoPath): \(error)")
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
        }
    }

    /// 检测并返回 SteamCMD Workshop 下载的根文件夹路径
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
        recentItems.removeAll { ids.contains($0.id) }
        persistRecents()
    }

    // MARK: - 文件夹移动

    /// 将媒体项移动到指定文件夹。
    /// - Parameters:
    ///   - mediaID: 媒体项 ID
    ///   - folderID: 目标文件夹 ID；传 nil 表示移回根目录
    ///   - fallback: 用于「扫描进来但还没有 DownloadRecord 的项」的回退信息。
    ///     当传入且 favorite/download 都不命中时，先调 `recordDownload` 把该项补登成下载记录，
    ///     再写 folderID，避免拖入文件夹后看起来无效。
    func moveMediaToFolder(
        mediaID: String,
        folderID: String?,
        fallback: (item: MediaItem, fileURL: URL)? = nil
    ) {
        var hit = false
        // 更新收藏记录
        if let index = favoriteRecords.firstIndex(where: { $0.item.id == mediaID }) {
            favoriteRecords[index].folderID = folderID
            saveFavToCache(favoriteRecords[index])
            syncFavIndex()
            favoriteRecords = Array(favoriteRecords)
            hit = true
        }
        // 更新下载记录
        if let index = downloadRecords.firstIndex(where: { $0.item.id == mediaID }) {
            downloadRecords[index].folderID = folderID
            saveDlToCache(downloadRecords[index])
            syncDlIndex()
            downloadRecords = Array(downloadRecords)
            hit = true
        }
        // 都没命中：尝试从 fallback 补登记，再写 folderID
        if !hit, let fallback {
            recordDownload(item: fallback.item, localFileURL: fallback.fileURL)
            if let index = downloadRecords.firstIndex(where: { $0.item.id == mediaID }) {
                downloadRecords[index].folderID = folderID
                saveDlToCache(downloadRecords[index])
                syncDlIndex()
                downloadRecords = Array(downloadRecords)
            }
        }
    }

    func moveItemsToRoot(fromFolder folderID: String) {
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

    /// 清理无效下载记录（文件不存在的记录）
    /// - Returns: 清理的记录数量
    @discardableResult
    func cleanupInvalidDownloadRecords() -> Int {
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
                UserDefaults.standard.set(data, forKey: key)
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
        rebuildDlCache()
    }

    // MARK: - 云同步导入方法

    /// 同步导入收藏记录（合并模式）
    func syncImportFavorites(_ records: [MediaFavoriteRecord]) {
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
        recentItems = Array(deduplicated(items).prefix(18))
        persistRecents()
    }

    /// 同步删除收藏（按 ID 集合）
    func syncRemoveFavorites(ids: Set<String>) {
        favoriteRecords.removeAll { ids.contains($0.id) }
        for id in ids {
            _ = deleteFavFromCache(id)
        }
        _ = syncFavIndex()
    }

    /// 同步删除下载（按 ID 集合）
    func syncRemoveDownloads(ids: Set<String>) {
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
    private let defaults = UserDefaults.standard

    /// ⚡ 快速查找索引：活跃收藏/下载的 ID 集合，避免主线程线性扫描
    private var favoriteIDSet: Set<String> = []
    private var downloadIDSet: Set<String> = []
    /// 下载记录字典索引（wallpaper.id → record），O(1) 查找替代 O(n) first(where:)
    private var downloadRecordIndex: [String: WallpaperDownloadRecord] = [:]
    /// 文件存在性缓存，避免主线程反复 FileManager.fileExists(atPath:)
    private let fileCache = FileExistenceCache.shared

    private init() {
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

    /// 供 ViewModel 缓存重建时快速排除已下载项目的 ID 集合
    var downloadIDSetForRebuild: Set<String> { downloadIDSet }

    var favoriteWallpapers: [Wallpaper] {
        favoriteRecords
            .filter(\.isActive)
            .map(\.wallpaper)
    }

    /// 获取指定文件夹内的收藏壁纸
    func favoriteWallpapers(inFolder folderID: String?) -> [Wallpaper] {
        favoriteRecords
            .filter { $0.isActive && $0.folderID == folderID }
            .map(\.wallpaper)
    }

    /// 获取指定文件夹内的下载壁纸
    func downloadedWallpapers(inFolder folderID: String?) -> [WallpaperDownloadRecord] {
        downloadRecords.filter { $0.isActive && $0.folderID == folderID }
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
        guard let index = downloadRecords.firstIndex(where: { $0.localFilePath == path }) else { return }
        downloadRecords[index].isLooped = true
        saveDlToCache(downloadRecords[index])
        syncDlIndex()
    }

    func clearLooped(localFilePath path: String) {
        guard let index = downloadRecords.firstIndex(where: { $0.localFilePath == path }) else { return }
        downloadRecords[index].isLooped = false
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

    func recordDownload(_ wallpaper: Wallpaper, fileURL: URL) {
        if let index = downloadRecords.firstIndex(where: { $0.wallpaper.id == wallpaper.id }) {
            downloadRecords[index].wallpaper = wallpaper
            downloadRecords[index].localFilePath = fileURL.path
            downloadRecords[index].downloadedAt = .now
            downloadRecords[index].metadata.markLocalMutation(deleted: false)
        } else {
            downloadRecords.insert(
                WallpaperDownloadRecord(wallpaper: wallpaper, localFilePath: fileURL.path),
                at: 0
            )
        }

        // 预缓存文件存在性，后续 isDownloaded() 不再走 FileManager
        fileCache.markExisting(atPath: fileURL.path)

        // 单条写入 Cache
        let record = downloadRecords.first { $0.wallpaper.id == wallpaper.id }
        if let record { saveDlToCache(record) }
        syncDlIndex()
        upsert(wallpaper)
    }

    func upsert(_ wallpaper: Wallpaper) {
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
        // 如果是 SteamCMD Workshop 下载的内容，删除整个 workshop_xxx 文件夹
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

    /// 检测并返回 SteamCMD Workshop 下载的根文件夹路径
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
        guard let index = downloadRecords.firstIndex(where: { $0.id == recordID }) else { return }
        downloadRecords[index].localFilePath = newPath
        saveDlToCache(downloadRecords[index])
        syncDlIndex()
    }

    /// 将指定记录标记为已删除（由 DirectoryMigrationService 调用）
    func deactivateDownloadRecord(recordID: String) {
        guard let index = downloadRecords.firstIndex(where: { $0.id == recordID }) else { return }
        downloadRecords[index].metadata.markLocalMutation(deleted: true)
        saveDlToCache(downloadRecords[index])
        syncDlIndex()
    }

    // MARK: - 文件夹移动

    /// 将壁纸移动到指定文件夹。
    /// - Parameters:
    ///   - wallpaperID: 壁纸 ID
    ///   - folderID: 目标文件夹 ID；传 nil 表示移回根目录
    ///   - fallback: 用于「扫描进来但还没有 DownloadRecord 的项」的回退信息。
    ///     当传入且 favorite/download 都不命中时，先调 `recordDownload` 把该项补登成下载记录，
    ///     再写 folderID，避免拖入文件夹后看起来无效。
    func moveWallpaperToFolder(
        wallpaperID: String,
        folderID: String?,
        fallback: (wallpaper: Wallpaper, fileURL: URL)? = nil
    ) {
        var hit = false
        // 更新收藏记录
        if let index = favoriteRecords.firstIndex(where: { $0.wallpaper.id == wallpaperID }) {
            favoriteRecords[index].folderID = folderID
            saveFavToCache(favoriteRecords[index])
            syncFavIndex()
            favoriteRecords = Array(favoriteRecords)
            hit = true
        }
        // 更新下载记录
        if let index = downloadRecords.firstIndex(where: { $0.wallpaper.id == wallpaperID }) {
            downloadRecords[index].folderID = folderID
            saveDlToCache(downloadRecords[index])
            syncDlIndex()
            downloadRecords = Array(downloadRecords)
            hit = true
        }
        // 都没命中：尝试从 fallback 补登记，再写 folderID
        if !hit, let fallback {
            recordDownload(fallback.wallpaper, fileURL: fallback.fileURL)
            if let index = downloadRecords.firstIndex(where: { $0.wallpaper.id == wallpaperID }) {
                downloadRecords[index].folderID = folderID
                saveDlToCache(downloadRecords[index])
                syncDlIndex()
                downloadRecords = Array(downloadRecords)
            }
        }
    }

    func moveItemsToRoot(fromFolder folderID: String) {
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
        rebuildDlCache()
    }

    // MARK: - 云同步导入方法

    /// 同步导入收藏记录（合并模式，不覆盖本地已有记录除非云端更新）
    func syncImportFavorites(_ records: [WallpaperFavoriteRecord]) {
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
        favoriteRecords.removeAll { ids.contains($0.id) }
        for id in ids {
            _ = deleteFavFromCache(id)
        }
        _ = syncFavIndex()
    }

    /// 同步删除下载（按 ID 集合）
    func syncRemoveDownloads(ids: Set<String>) {
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
