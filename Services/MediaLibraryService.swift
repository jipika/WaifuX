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

    var downloadedItems: [MediaDownloadRecord] {
        downloadRecords.filter(\.isActive)
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
            let filePath = downloadRecords[index].localFilePath
            // 标记软删除
            downloadRecords[index].metadata.markLocalMutation(deleted: true)
            persistDownloads()
            downloadRecords = downloadRecords
            // 删除物理文件
            deletePhysicalFile(at: filePath)
        }
    }

    /// 批量删除下载记录（含物理文件）
    /// - Parameter ids: 要删除的项目 ID 集合
    func removeDownloadRecords(withIDs ids: Set<String>) {
        var filesToDelete: [String] = []
        for (index, record) in downloadRecords.enumerated() {
            if ids.contains(record.item.id) {
                filesToDelete.append(record.localFilePath)
                downloadRecords[index].metadata.markLocalMutation(deleted: true)
            }
        }
        persistDownloads()
        downloadRecords = downloadRecords
        // 删除所有对应的物理文件
        for path in filesToDelete {
            deletePhysicalFile(at: path)
        }
    }

    /// 安全删除物理文件
    private func deletePhysicalFile(at path: String) {
        guard !path.isEmpty else { return }
        let fm = FileManager.default
        if fm.fileExists(atPath: path) {
            do {
                try fm.removeItem(atPath: path)
                print("[MediaLibraryService] ✅ Deleted physical file: \(path)")
            } catch {
                print("[MediaLibraryService] ⚠️ Failed to delete file \(path): \(error)")
            }
        }
    }

    /// 批量删除最近播放记录
    /// - Parameter ids: 要删除的项目 ID 集合
    func removeRecentItems(withIDs ids: Set<String>) {
        recentItems.removeAll { ids.contains($0.id) }
        persistRecents()
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
        if fm.fileExists(atPath: path) {
            do {
                try fm.removeItem(atPath: path)
                print("[WallpaperLibraryService] ✅ Deleted physical file: \(path)")
            } catch {
                print("[WallpaperLibraryService] ⚠️ Failed to delete file \(path): \(error)")
            }
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
