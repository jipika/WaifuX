import Foundation
import Combine

@MainActor
final class MediaLibraryService: ObservableObject {
    static let shared = MediaLibraryService()

    @Published private(set) var favoriteRecords: [MediaFavoriteRecord] = []
    @Published private(set) var downloadRecords: [MediaDownloadRecord] = []
    @Published private(set) var recentItems: [MediaItem] = []

    private let favoriteRecordsKey = "media_favorite_records_v2"
    private let downloadRecordsKey = "media_download_records_v2"
    private let recentsKey = "media_recents_v1"
    private let legacyFavoritesKey = "media_favorites_v1"
    private let legacyDownloadsKey = "media_downloads_v1"
    private let defaults = UserDefaults.standard

    private init() {
        // ⚠️ 不在 init 中读 UserDefaults，避免 _CFXPreferences 递归栈溢出
    }
    
    /// 延迟恢复持久化数据（必须在 AppDelegate.applicationDidFinishLaunching 中调用）
    func restoreSavedData() {
        loadPersistedState()
    }

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
        if let index = favoriteRecords.firstIndex(where: { $0.item.id == item.id }) {
            favoriteRecords[index].item = item
            favoriteRecords[index].metadata.markLocalMutation(deleted: favoriteRecords[index].isActive)
        } else {
            favoriteRecords.insert(MediaFavoriteRecord(item: item), at: 0)
        }

        favoriteRecords = deduplicated(favoriteRecords)
        persistFavorites()
    }

    func isFavorite(_ item: MediaItem) -> Bool {
        favoriteRecords.contains { $0.item.id == item.id && $0.isActive }
    }
    
    func favoriteRecord(for itemID: String) -> MediaFavoriteRecord? {
        favoriteRecords.first { $0.item.id == itemID && $0.isActive }
    }
    
    func downloadRecord(for itemID: String) -> MediaDownloadRecord? {
        downloadRecords.first { $0.item.id == itemID && $0.isActive }
    }

    func downloadRecord(forLocalFilePath path: String) -> MediaDownloadRecord? {
        downloadRecords.first { $0.localFilePath == path && $0.isActive }
    }

    func markAsLooped(localFilePath path: String) {
        guard let index = downloadRecords.firstIndex(where: { $0.localFilePath == path }) else { return }
        downloadRecords[index].isLooped = true
        persistDownloads()
    }

    func isDownloaded(_ item: MediaItem) -> Bool {
        guard let record = downloadRecords.first(where: { $0.item.id == item.id && $0.isActive }) else {
            return false
        }
        // 验证文件实际存在
        let fileExists = FileManager.default.fileExists(atPath: record.localFilePath)
        if !fileExists {
            print("[MediaLibraryService] File not found for downloaded item: \(item.id) at \(record.localFilePath)")
        }
        return fileExists
    }

    /// 已下载媒体在磁盘上的文件 URL（存在且可读时）
    func localFileURLIfAvailable(for item: MediaItem) -> URL? {
        guard let record = downloadRecords.first(where: { $0.item.id == item.id && $0.isActive }) else {
            return nil
        }
        let url = URL(fileURLWithPath: record.localFilePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
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

        persistDownloads()
        upsert(item)

        SceneBakeEligibilityAnalyzer.scheduleAnalysisIfSceneProject(itemID: item.id, localFileURL: localFileURL)
    }

    /// 由 `SceneBakeEligibilityAnalyzer` 在后台线程完成后调用，写入带 UUID 的分析快照。
    /// - Parameter triggerAutoBake: 为 false 时不在此触发后台自动烘焙（例如用户正在「设为壁纸」流程里同步烘焙）。
    func attachSceneBakeEligibility(itemID: String, snapshot: SceneBakeEligibilitySnapshot, triggerAutoBake: Bool = true) {
        guard let index = downloadRecords.firstIndex(where: { $0.item.id == itemID && $0.isActive }) else {
            return
        }
        if let art = downloadRecords[index].sceneBakeArtifact, art.analysisId != snapshot.analysisId {
            downloadRecords[index].sceneBakeArtifact = nil
        }
        downloadRecords[index].sceneBakeEligibility = snapshot
        persistDownloads()
        downloadRecords = downloadRecords

        if triggerAutoBake, snapshot.isEligibleForOfflineBake {
            SceneOfflineBakeService.scheduleAutoBakeAfterEligibility(itemID: itemID)
        }
    }

    func attachSceneBakeArtifact(itemID: String, artifact: SceneBakeArtifact) {
        guard let index = downloadRecords.firstIndex(where: { $0.item.id == itemID && $0.isActive }) else {
            return
        }
        downloadRecords[index].sceneBakeArtifact = artifact
        persistDownloads()
        downloadRecords = downloadRecords
    }

    func upsert(_ item: MediaItem) {
        if let favoriteIndex = favoriteRecords.firstIndex(where: { $0.item.id == item.id }) {
            favoriteRecords[favoriteIndex].item = item
            persistFavorites()
            favoriteRecords = favoriteRecords
        }

        if let recentIndex = recentItems.firstIndex(where: { $0.id == item.id }) {
            recentItems[recentIndex] = item
            persistRecents()
        }

        if let downloadIndex = downloadRecords.firstIndex(where: { $0.item.id == item.id }) {
            downloadRecords[downloadIndex].item = item
            persistDownloads()
            downloadRecords = downloadRecords
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
            persistDownloads()
            downloadRecords = downloadRecords
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
            persistDownloads()
            downloadRecords = downloadRecords
        }
        if favoritesChanged {
            persistFavorites()
            favoriteRecords = favoriteRecords
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
            }
        }
        persistFavorites()
        favoriteRecords = favoriteRecords
    }

    /// 删除单个下载记录（含物理文件）
    /// - Parameter ids: 要删除的项目 ID 集合
    func removeDownloadRecord(withID id: String) {
        if let index = downloadRecords.firstIndex(where: { $0.item.id == id }) {
            let record = downloadRecords[index]
            let filePath = record.localFilePath
            // 标记软删除
            downloadRecords[index].metadata.markLocalMutation(deleted: true)
            persistDownloads()
            downloadRecords = downloadRecords
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
            }
        }
        persistDownloads()
        downloadRecords = downloadRecords
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
    
    func moveMediaToFolder(mediaID: String, folderID: String?) {
        // 更新收藏记录
        if let index = favoriteRecords.firstIndex(where: { $0.item.id == mediaID }) {
            favoriteRecords[index].folderID = folderID
            persistFavorites()
            favoriteRecords = favoriteRecords
        }
        // 更新下载记录
        if let index = downloadRecords.firstIndex(where: { $0.item.id == mediaID }) {
            downloadRecords[index].folderID = folderID
            persistDownloads()
            downloadRecords = downloadRecords
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
            persistFavorites()
            favoriteRecords = favoriteRecords
        }
        if downloadsChanged {
            persistDownloads()
            downloadRecords = downloadRecords
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
            persistDownloads()
            downloadRecords = downloadRecords
            print("[MediaLibraryService] Cleaned up \(cleanedCount) invalid download records")
        }
        
        return cleanedCount
    }

    private func loadPersistedState() {
        let decoder = JSONDecoder()

        if let data = defaults.data(forKey: favoriteRecordsKey),
           let decoded = try? decoder.decode([MediaFavoriteRecord].self, from: data) {
            favoriteRecords = deduplicated(decoded)
        } else if let data = defaults.data(forKey: legacyFavoritesKey),
                  let decoded = try? decoder.decode([MediaItem].self, from: data) {
            favoriteRecords = deduplicated(decoded.map { MediaFavoriteRecord(item: $0) })
            defaults.removeObject(forKey: legacyFavoritesKey)
            persistFavorites()
        }

        if let data = defaults.data(forKey: downloadRecordsKey),
           let decoded = try? decoder.decode([MediaDownloadRecord].self, from: data) {
            downloadRecords = decoded
        } else if let data = defaults.data(forKey: legacyDownloadsKey),
                  let decoded = try? decoder.decode([MediaDownloadRecord].self, from: data) {
            downloadRecords = decoded
            defaults.removeObject(forKey: legacyDownloadsKey)
            persistDownloads()
        }

        if let data = defaults.data(forKey: recentsKey),
           let decoded = try? decoder.decode([MediaItem].self, from: data) {
            recentItems = Array(deduplicated(decoded).prefix(18))
        }
    }

    private func persistFavorites() {
        if let data = try? JSONEncoder().encode(favoriteRecords) {
            defaults.set(data, forKey: favoriteRecordsKey)
        }
    }

    func persistDownloads() {
        if let data = try? JSONEncoder().encode(downloadRecords) {
            defaults.set(data, forKey: downloadRecordsKey)
        }
    }

    private func persistRecents() {
        if let data = try? JSONEncoder().encode(recentItems) {
            defaults.set(data, forKey: recentsKey)
        }
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

    @Published private(set) var favoriteRecords: [WallpaperFavoriteRecord] = []
    @Published private(set) var downloadRecords: [WallpaperDownloadRecord] = []

    private let favoriteRecordsKey = "wallpaper_favorite_records_v2"
    private let downloadRecordsKey = "wallpaper_download_records_v2"
    private let legacyFavoritesKey = "local_favorites"
    private let legacyCloudFavoritesKey = "cloud_favorites"
    private let legacyDownloadsKey = "wallpaper_downloads_v1"
    private let defaults = UserDefaults.standard

    private init() {
        // ⚠️ 不在 init 中读 UserDefaults，避免 _CFXPreferences 递归栈溢出
    }
    
    /// 延迟恢复持久化数据（必须在 AppDelegate.applicationDidFinishLaunching 中调用）
    func restoreSavedData() {
        loadPersistedState()
    }

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
        if let index = favoriteRecords.firstIndex(where: { $0.wallpaper.id == wallpaper.id }) {
            favoriteRecords[index].wallpaper = wallpaper
            favoriteRecords[index].metadata.markLocalMutation(deleted: favoriteRecords[index].isActive)
        } else {
            favoriteRecords.insert(WallpaperFavoriteRecord(wallpaper: wallpaper), at: 0)
        }

        favoriteRecords = deduplicated(favoriteRecords)
        persistFavorites()
    }

    func isFavorite(_ wallpaper: Wallpaper) -> Bool {
        favoriteRecords.contains { $0.wallpaper.id == wallpaper.id && $0.isActive }
    }
    
    func favoriteRecord(for wallpaperID: String) -> WallpaperFavoriteRecord? {
        favoriteRecords.first { $0.wallpaper.id == wallpaperID && $0.isActive }
    }
    
    func downloadRecord(for wallpaperID: String) -> WallpaperDownloadRecord? {
        downloadRecords.first { $0.wallpaper.id == wallpaperID && $0.isActive }
    }

    func downloadRecord(forLocalFilePath path: String) -> WallpaperDownloadRecord? {
        downloadRecords.first { $0.localFilePath == path && $0.isActive }
    }

    func markAsLooped(localFilePath path: String) {
        guard let index = downloadRecords.firstIndex(where: { $0.localFilePath == path }) else { return }
        downloadRecords[index].isLooped = true
        persistDownloads()
    }

    func isDownloaded(_ wallpaper: Wallpaper) -> Bool {
        guard let record = downloadRecords.first(where: { $0.wallpaper.id == wallpaper.id && $0.isActive }) else {
            return false
        }
        // 验证文件实际存在
        let fileExists = FileManager.default.fileExists(atPath: record.localFilePath)
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
           FileManager.default.fileExists(atPath: u.path) {
            return u
        }
        guard let record = downloadRecords.first(where: { $0.wallpaper.id == wallpaper.id && $0.isActive }) else {
            return nil
        }
        let url = URL(fileURLWithPath: record.localFilePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
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

        persistDownloads()
        upsert(wallpaper)
    }

    func upsert(_ wallpaper: Wallpaper) {
        if let favoriteIndex = favoriteRecords.firstIndex(where: { $0.wallpaper.id == wallpaper.id }) {
            favoriteRecords[favoriteIndex].wallpaper = wallpaper
            persistFavorites()
            favoriteRecords = favoriteRecords
        }

        if let downloadIndex = downloadRecords.firstIndex(where: { $0.wallpaper.id == wallpaper.id }) {
            downloadRecords[downloadIndex].wallpaper = wallpaper
            persistDownloads()
            downloadRecords = downloadRecords
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
            persistFavorites()
            favoriteRecords = favoriteRecords
        }
        if downloadsChanged {
            persistDownloads()
            downloadRecords = downloadRecords
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
            persistDownloads()
            downloadRecords = downloadRecords
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
            persistDownloads()
            downloadRecords = downloadRecords
        }
        if favoritesChanged {
            persistFavorites()
            favoriteRecords = favoriteRecords
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
            }
        }
        persistFavorites()
        favoriteRecords = favoriteRecords
    }

    /// 批量删除壁纸下载记录（含物理文件）
    /// - Parameter ids: 要删除的项目 ID 集合
    func removeWallpaperDownloads(withIDs ids: Set<String>) {
        var filesToDelete: [String] = []
        for (index, record) in downloadRecords.enumerated() {
            if ids.contains(record.wallpaper.id) {
                filesToDelete.append(record.localFilePath)
                downloadRecords[index].metadata.markLocalMutation(deleted: true)
            }
        }
        persistDownloads()
        downloadRecords = downloadRecords
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
            persistDownloads()
            downloadRecords = downloadRecords
            print("[WallpaperLibraryService] Cleaned up \(cleanedCount) invalid download records")
        }
        
        return cleanedCount
    }
    
    // MARK: - 文件夹移动
    
    func moveWallpaperToFolder(wallpaperID: String, folderID: String?) {
        // 更新收藏记录
        if let index = favoriteRecords.firstIndex(where: { $0.wallpaper.id == wallpaperID }) {
            favoriteRecords[index].folderID = folderID
            persistFavorites()
            favoriteRecords = favoriteRecords
        }
        // 更新下载记录
        if let index = downloadRecords.firstIndex(where: { $0.wallpaper.id == wallpaperID }) {
            downloadRecords[index].folderID = folderID
            persistDownloads()
            downloadRecords = downloadRecords
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
            persistFavorites()
            favoriteRecords = favoriteRecords
        }
        if downloadsChanged {
            persistDownloads()
            downloadRecords = downloadRecords
        }
    }

    private func loadPersistedState() {
        let decoder = JSONDecoder()

        if let data = defaults.data(forKey: favoriteRecordsKey),
           let decoded = try? decoder.decode([WallpaperFavoriteRecord].self, from: data) {
            favoriteRecords = deduplicated(decoded)
        } else {
            var migratedFavorites: [WallpaperFavoriteRecord] = []

            if let data = defaults.data(forKey: legacyFavoritesKey),
               let decoded = try? decoder.decode([Wallpaper].self, from: data) {
                migratedFavorites.append(contentsOf: decoded.map { WallpaperFavoriteRecord(wallpaper: $0) })
                defaults.removeObject(forKey: legacyFavoritesKey)
            }

            if let data = defaults.data(forKey: legacyCloudFavoritesKey),
               let decoded = try? decoder.decode([Wallpaper].self, from: data) {
                migratedFavorites.append(contentsOf: decoded.map { WallpaperFavoriteRecord(wallpaper: $0) })
                defaults.removeObject(forKey: legacyCloudFavoritesKey)
            }

            favoriteRecords = deduplicated(migratedFavorites)
            if !favoriteRecords.isEmpty {
                persistFavorites()
            }
        }

        if let data = defaults.data(forKey: downloadRecordsKey),
           let decoded = try? decoder.decode([WallpaperDownloadRecord].self, from: data) {
            downloadRecords = decoded
        } else if let data = defaults.data(forKey: legacyDownloadsKey),
                  let decoded = try? decoder.decode([WallpaperDownloadRecord].self, from: data) {
            downloadRecords = decoded
            defaults.removeObject(forKey: legacyDownloadsKey)
            persistDownloads()
        }
    }

    private func persistFavorites() {
        if let data = try? JSONEncoder().encode(favoriteRecords) {
            defaults.set(data, forKey: favoriteRecordsKey)
        }
    }

    func persistDownloads() {
        if let data = try? JSONEncoder().encode(downloadRecords) {
            defaults.set(data, forKey: downloadRecordsKey)
        }
    }

    private func deduplicated(_ records: [WallpaperFavoriteRecord]) -> [WallpaperFavoriteRecord] {
        var seen = Set<String>()
        return records.filter { record in
            seen.insert(record.id).inserted
        }
    }
}
