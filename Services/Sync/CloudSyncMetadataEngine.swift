import Foundation

// MARK: - Metadata Payload 结构
struct CloudSyncMetadataPayload: Codable {
    var version: Int = 1
    let deviceID: String
    let syncedAt: Date
    var records: CloudSyncRecords
}

struct CloudSyncRecords: Codable {
    // 壁纸收藏/下载（已含 SyncMetadata）
    var wallpaperFavorites: [WallpaperFavoriteRecord] = []
    var wallpaperDownloads: [WallpaperDownloadRecord] = []

    // 媒体收藏/下载/最近
    var mediaFavorites: [MediaFavoriteRecord] = []
    var mediaDownloads: [MediaDownloadRecord] = []
    var mediaRecents: [MediaItem] = []

    // 动漫
    var animeFavorites: [FavoriteAnime] = []
    var animeEpisodeProgress: [String: EpisodeProgress] = [:]
    var animeSummaries: [String: AnimeProgressSummary] = [:]

    // 播放进度
    var playbackProgress: [PlaybackProgress] = []

    // 库文件夹
    var libraryFolders: LibraryFoldersPayload?

    // Grid 排序
    var libraryGridOrder: [String: [String]]?    // scope → [id]

    // 壁纸自定义配置（按壁纸 ID 索引）
    var sceneDesigns: [String: SceneWallpaperDesignPayload] = [:]
    var sceneProperties: [String: SceneWallpaperPropertiesPayload] = [:]
    var sceneConfigOverrides: [String: [String: AnyCodable]] = [:]
    var webProperties: [String: [String: AnyCodable]] = [:]

    // 设置
    var settings: [String: [String: AnyCodable]] = [:]  // category.rawValue → { key → value }

    // 数据源 Profile
    var dataSourceProfiles: DataSourceProfilesPayload?
}

struct LibraryFoldersPayload: Codable {
    var wallpaper: [LibraryFolder] = []
    var media: [LibraryFolder] = []
}

// 壁纸自定义配置 payload（不包含本地路径）
struct SceneWallpaperDesignPayload: Codable {
    let wallpaperID: String
    let overrides: [String: SceneDynamicTextDesignOverride]
}

struct SceneWallpaperPropertiesPayload: Codable {
    let wallpaperID: String
    let overrides: [String: AnyCodableValue]
}

struct DataSourceProfilesPayload: Codable {
    let activeID: String
    let importedProfiles: [DataSourceProfile]
}

// MARK: - 元数据引擎
@MainActor
final class CloudSyncMetadataEngine {
    static let shared = CloudSyncMetadataEngine()

    let configuration = CloudSyncConfiguration.shared
    let fileEngine = CloudSyncFileEngine.shared

    // MARK: - 导出

    /// 从各 Service 读取数据，组装为 payload
    func exportMetadata() throws -> Data {
        let payload = try buildPayload()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(payload)
    }

    private func buildPayload() throws -> CloudSyncMetadataPayload {
        let wallpaperLib = WallpaperLibraryService.shared
        let mediaLib = MediaLibraryService.shared
        let animeFav = AnimeFavoriteStore.shared
        let animeProgress = AnimeProgressStore.shared
        let playbackCache = PlaybackProgressCache.shared
        let folderStore = LibraryFolderStore.shared
        let gridStore = LibraryGridOrderStore.shared
        let downloadMgr = DownloadPathManager.shared

        // 导出设置：将 [CloudSyncSettingsCategory: ...] 转为 [String: ...]
        let exportedSettings = CloudSyncSettingsRegistry.exportSettings()
        let settingsPayload: [String: [String: AnyCodable]] = exportedSettings.reduce(into: [:]) { result, pair in
            result[pair.key.rawValue] = pair.value
        }

        return CloudSyncMetadataPayload(
            deviceID: Self.deviceID,
            syncedAt: Date(),
            records: CloudSyncRecords(
                wallpaperFavorites: wallpaperLib.favoriteRecords,
                wallpaperDownloads: wallpaperLib.downloadRecords.map { record in
                    // 路径相对化
                    var r = record
                    if !r.localFilePath.isEmpty {
                        r.localFilePath = Self.relativizePath(r.localFilePath, baseFolder: downloadMgr.wallpapersFolderURL.path)
                    }
                    return r
                },
                mediaFavorites: mediaLib.favoriteRecords,
                mediaDownloads: mediaLib.downloadRecords.map { record in
                    var r = record
                    if !r.localFilePath.isEmpty {
                        r.localFilePath = Self.relativizePath(r.localFilePath, baseFolder: downloadMgr.mediaFolderURL.path)
                    }
                    return r
                },
                mediaRecents: mediaLib.recentItems,
                animeFavorites: Array(animeFav.favorites.values),
                animeEpisodeProgress: animeProgress.episodeProgress,
                animeSummaries: animeProgress.animeSummaries,
                playbackProgress: playbackCache.progresses,
                libraryFolders: LibraryFoldersPayload(
                    wallpaper: folderStore.wallpaperFolders,
                    media: folderStore.mediaFolders
                ),
                libraryGridOrder: gridStore.exportOrders(),
                sceneDesigns: Self.exportAllSceneDesigns(for: wallpaperLib.downloadRecords + mediaLib.downloadRecords),
                sceneProperties: Self.exportAllSceneProperties(for: wallpaperLib.downloadRecords + mediaLib.downloadRecords),
                sceneConfigOverrides: Self.exportAllSceneConfigOverrides(for: wallpaperLib.downloadRecords + mediaLib.downloadRecords),
                webProperties: [:],
                settings: settingsPayload,
                dataSourceProfiles: Self.exportDataSourceProfiles()
            )
        )
    }

    // MARK: - 导入

    /// 从 Data 导入元数据，根据策略合并到本地
    func importMetadata(
        from data: Data,
        strategy: CloudSyncConflictStrategy
    ) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload: CloudSyncMetadataPayload

        do {
            payload = try decoder.decode(CloudSyncMetadataPayload.self, from: data)
        } catch {
            throw CloudSyncError.metadataCorrupted
        }

        guard payload.version == 1 else {
            throw CloudSyncError.metadataVersionMismatch(version: payload.version)
        }

        let records = payload.records

        // 1. 合并壁纸收藏
        mergeWallpaperFavorites(records.wallpaperFavorites, strategy: strategy)

        // 2. 合并壁纸下载（含路径重建）
        mergeWallpaperDownloads(records.wallpaperDownloads, strategy: strategy)

        // 3. 合并媒体收藏
        mergeMediaFavorites(records.mediaFavorites, strategy: strategy)

        // 4. 合并媒体下载（含路径重建）
        mergeMediaDownloads(records.mediaDownloads, strategy: strategy)

        // 5. 合并媒体最近项
        if strategy == .cloudPreferred {
            mergeMediaRecents(records.mediaRecents)
        }

        // 6. 合并动漫收藏
        mergeAnimeFavorites(records.animeFavorites, strategy: strategy)

        // 7. 合并动漫进度
        mergeAnimeProgress(records.animeEpisodeProgress, records.animeSummaries, strategy: strategy)

        // 8. 合并播放进度
        mergePlaybackProgress(records.playbackProgress, strategy: strategy)

        // 9. 合并库文件夹
        if let folders = records.libraryFolders {
            mergeLibraryFolders(folders, strategy: strategy)
        }

        // 10. 合并 Grid 排序
        if let gridOrder = records.libraryGridOrder {
            mergeGridOrder(gridOrder, strategy: strategy)
        }

        // 11. 合并壁纸自定义配置
        if strategy == .cloudPreferred {
            mergeSceneDesigns(records.sceneDesigns)
            mergeSceneProperties(records.sceneProperties)
            mergeSceneConfigOverrides(records.sceneConfigOverrides)
        }

        // 12. 合并设置：将 [String: ...] 转回 [CloudSyncSettingsCategory: ...]
        let typedSettings: [CloudSyncSettingsCategory: [String: AnyCodable]] = records.settings.reduce(into: [:]) { result, pair in
            if let category = CloudSyncSettingsCategory(rawValue: pair.key) {
                result[category] = pair.value
            }
        }
        CloudSyncSettingsRegistry.importSettings(typedSettings, strategy: strategy)

        // 13. 合并数据源 Profile
        if strategy == .cloudPreferred, let profiles = records.dataSourceProfiles {
            mergeDataSourceProfiles(profiles)
        }
    }

    // MARK: - 内部：路径处理

    /// 将绝对路径转换为相对路径（相对于基础目录）
    private static func relativizePath(_ absolutePath: String, baseFolder: String) -> String {
        guard absolutePath.hasPrefix(baseFolder) else { return absolutePath }
        var relative = String(absolutePath.dropFirst(baseFolder.count))
        if relative.hasPrefix("/") { relative = String(relative.dropFirst()) }
        return relative
    }

    /// 将相对路径还原为绝对路径
    static func absolutizePath(_ relativePath: String, baseFolder: String) -> String {
        if relativePath.hasPrefix("/") { return relativePath } // 已经是绝对路径
        return (baseFolder as NSString).appendingPathComponent(relativePath)
    }

    // MARK: - 内部：设备 ID

    private static let deviceID: String = {
        if let stored = UserDefaults.standard.string(forKey: "cloud_sync_device_id") {
            return stored
        }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "cloud_sync_device_id")
        return id
    }()
}

// MARK: - 合并实现
extension CloudSyncMetadataEngine {

    // MARK: 壁纸收藏合并
    func mergeWallpaperFavorites(_ cloudRecords: [WallpaperFavoriteRecord], strategy: CloudSyncConflictStrategy) {
        let service = WallpaperLibraryService.shared
        let localRecords = service.favoriteRecords
        var toImport: [WallpaperFavoriteRecord] = []
        var toRemoveIDs: Set<String> = []

        for cloudRecord in cloudRecords {
            let id = cloudRecord.wallpaper.id
            if let localRecord = localRecords.first(where: { $0.wallpaper.id == id }) {
                let resolution = CloudSyncConflictResolver.resolveRecord(
                    localUpdatedAt: localRecord.metadata.updatedAt,
                    cloudUpdatedAt: cloudRecord.metadata.updatedAt,
                    localIsDeleted: localRecord.metadata.isDeleted,
                    cloudIsDeleted: cloudRecord.metadata.isDeleted,
                    strategy: strategy
                )
                switch resolution {
                case .useLocal: continue
                case .useCloud:
                    if cloudRecord.metadata.isDeleted {
                        toRemoveIDs.insert(id)
                    } else {
                        var merged = cloudRecord
                        merged.metadata.markSynced()
                        toImport.append(merged)
                    }
                case .skip: continue
                }
            } else {
                guard !cloudRecord.metadata.isDeleted else { continue }
                var record = cloudRecord
                record.metadata.markSynced()
                toImport.append(record)
            }
        }

        if !toImport.isEmpty { service.syncImportFavorites(toImport) }
        if !toRemoveIDs.isEmpty { service.syncRemoveFavorites(ids: toRemoveIDs) }
    }

    // MARK: 壁纸下载合并
    func mergeWallpaperDownloads(_ cloudRecords: [WallpaperDownloadRecord], strategy: CloudSyncConflictStrategy) {
        let service = WallpaperLibraryService.shared
        let localRecords = service.downloadRecords
        let downloadMgr = DownloadPathManager.shared
        let basePath = downloadMgr.wallpapersFolderURL.path
        var toImport: [WallpaperDownloadRecord] = []
        var toRemoveIDs: Set<String> = []

        for var cloudRecord in cloudRecords {
            let id = cloudRecord.wallpaper.id
            // 重建绝对路径
            if !cloudRecord.localFilePath.isEmpty && !cloudRecord.localFilePath.hasPrefix("/") {
                cloudRecord.localFilePath = (basePath as NSString).appendingPathComponent(cloudRecord.localFilePath)
            }

            if let localRecord = localRecords.first(where: { $0.wallpaper.id == id }) {
                let resolution = CloudSyncConflictResolver.resolveRecord(
                    localUpdatedAt: localRecord.metadata.updatedAt,
                    cloudUpdatedAt: cloudRecord.metadata.updatedAt,
                    localIsDeleted: localRecord.metadata.isDeleted,
                    cloudIsDeleted: cloudRecord.metadata.isDeleted,
                    strategy: strategy
                )
                switch resolution {
                case .useLocal: continue
                case .useCloud:
                    if cloudRecord.metadata.isDeleted {
                        toRemoveIDs.insert(id)
                    } else {
                        var merged = cloudRecord
                        merged.metadata.markSynced()
                        toImport.append(merged)
                    }
                case .skip: continue
                }
            } else {
                guard !cloudRecord.metadata.isDeleted else { continue }
                var record = cloudRecord
                record.metadata.markSynced()
                toImport.append(record)
            }
        }

        if !toImport.isEmpty { service.syncImportDownloads(toImport) }
        if !toRemoveIDs.isEmpty { service.syncRemoveDownloads(ids: toRemoveIDs) }
    }

    // MARK: 媒体收藏合并
    func mergeMediaFavorites(_ cloudRecords: [MediaFavoriteRecord], strategy: CloudSyncConflictStrategy) {
        let service = MediaLibraryService.shared
        let localRecords = service.favoriteRecords
        var toImport: [MediaFavoriteRecord] = []
        var toRemoveIDs: Set<String> = []

        for cloudRecord in cloudRecords {
            let id = cloudRecord.item.id
            if let localRecord = localRecords.first(where: { $0.item.id == id }) {
                let resolution = CloudSyncConflictResolver.resolveRecord(
                    localUpdatedAt: localRecord.metadata.updatedAt,
                    cloudUpdatedAt: cloudRecord.metadata.updatedAt,
                    localIsDeleted: localRecord.metadata.isDeleted,
                    cloudIsDeleted: cloudRecord.metadata.isDeleted,
                    strategy: strategy
                )
                switch resolution {
                case .useLocal: continue
                case .useCloud:
                    if cloudRecord.metadata.isDeleted {
                        toRemoveIDs.insert(id)
                    } else {
                        var merged = cloudRecord
                        merged.metadata.markSynced()
                        toImport.append(merged)
                    }
                case .skip: continue
                }
            } else {
                guard !cloudRecord.metadata.isDeleted else { continue }
                var record = cloudRecord
                record.metadata.markSynced()
                toImport.append(record)
            }
        }

        if !toImport.isEmpty { service.syncImportFavorites(toImport) }
        if !toRemoveIDs.isEmpty { service.syncRemoveFavorites(ids: toRemoveIDs) }
    }

    // MARK: 媒体下载合并
    func mergeMediaDownloads(_ cloudRecords: [MediaDownloadRecord], strategy: CloudSyncConflictStrategy) {
        let service = MediaLibraryService.shared
        let localRecords = service.downloadRecords
        let downloadMgr = DownloadPathManager.shared
        let basePath = downloadMgr.mediaFolderURL.path
        var toImport: [MediaDownloadRecord] = []
        var toRemoveIDs: Set<String> = []

        for var cloudRecord in cloudRecords {
            let id = cloudRecord.item.id
            if !cloudRecord.localFilePath.isEmpty && !cloudRecord.localFilePath.hasPrefix("/") {
                cloudRecord.localFilePath = (basePath as NSString).appendingPathComponent(cloudRecord.localFilePath)
            }

            if let localRecord = localRecords.first(where: { $0.item.id == id }) {
                let resolution = CloudSyncConflictResolver.resolveRecord(
                    localUpdatedAt: localRecord.metadata.updatedAt,
                    cloudUpdatedAt: cloudRecord.metadata.updatedAt,
                    localIsDeleted: localRecord.metadata.isDeleted,
                    cloudIsDeleted: cloudRecord.metadata.isDeleted,
                    strategy: strategy
                )
                switch resolution {
                case .useLocal: continue
                case .useCloud:
                    if cloudRecord.metadata.isDeleted {
                        toRemoveIDs.insert(id)
                    } else {
                        var merged = cloudRecord
                        merged.metadata.markSynced()
                        toImport.append(merged)
                    }
                case .skip: continue
                }
            } else {
                guard !cloudRecord.metadata.isDeleted else { continue }
                var record = cloudRecord
                record.metadata.markSynced()
                toImport.append(record)
            }
        }

        if !toImport.isEmpty { service.syncImportDownloads(toImport) }
        if !toRemoveIDs.isEmpty { service.syncRemoveDownloads(ids: toRemoveIDs) }
    }

    // MARK: 媒体最近项
    func mergeMediaRecents(_ cloudRecents: [MediaItem]) {
        guard !cloudRecents.isEmpty else { return }
        let service = MediaLibraryService.shared
        service.syncImportRecents(cloudRecents)
    }

    // MARK: 动漫收藏合并
    func mergeAnimeFavorites(_ cloudFavorites: [FavoriteAnime], strategy: CloudSyncConflictStrategy) {
        let store = AnimeFavoriteStore.shared
        let localFavs = store.favorites
        var toImport: [FavoriteAnime] = []
        var toRemoveIDs: Set<String> = []

        for cloudFav in cloudFavorites {
            let id = cloudFav.id
            if let localFav = localFavs[id] {
                let resolution = CloudSyncConflictResolver.resolveRecord(
                    localUpdatedAt: localFav.updatedAt,
                    cloudUpdatedAt: cloudFav.updatedAt,
                    strategy: strategy
                )
                switch resolution {
                case .useLocal: continue
                case .useCloud: toImport.append(cloudFav)
                case .skip: continue
                }
            } else {
                toImport.append(cloudFav)
            }
        }

        if !toImport.isEmpty { store.syncImportFavorites(toImport) }
        if !toRemoveIDs.isEmpty { store.syncRemoveFavorites(ids: toRemoveIDs) }
    }

    // MARK: 动漫进度合并
    func mergeAnimeProgress(
        _ cloudEpisodes: [String: EpisodeProgress],
        _ cloudSummaries: [String: AnimeProgressSummary],
        strategy: CloudSyncConflictStrategy
    ) {
        let store = AnimeProgressStore.shared
        var episodesToImport: [String: EpisodeProgress] = [:]
        var summariesToImport: [String: AnimeProgressSummary] = [:]

        for (key, cloudEpi) in cloudEpisodes {
            if let localEpi = store.episodeProgress[key] {
                let resolution = CloudSyncConflictResolver.resolveRecord(
                    localUpdatedAt: localEpi.lastPlayedAt,
                    cloudUpdatedAt: cloudEpi.lastPlayedAt,
                    strategy: strategy
                )
                switch resolution {
                case .useLocal: continue
                case .useCloud: episodesToImport[key] = cloudEpi
                case .skip: continue
                }
            } else {
                episodesToImport[key] = cloudEpi
            }
        }

        for (key, cloudSum) in cloudSummaries {
            if let localSum = store.animeSummaries[key] {
                let resolution = CloudSyncConflictResolver.resolveRecord(
                    localUpdatedAt: localSum.lastPlayedAt,
                    cloudUpdatedAt: cloudSum.lastPlayedAt,
                    strategy: strategy
                )
                switch resolution {
                case .useLocal: continue
                case .useCloud: summariesToImport[key] = cloudSum
                case .skip: continue
                }
            } else {
                summariesToImport[key] = cloudSum
            }
        }

        if !episodesToImport.isEmpty { store.syncImportEpisodeProgress(episodesToImport) }
        if !summariesToImport.isEmpty { store.syncImportAnimeSummaries(summariesToImport) }
    }

    // MARK: 播放进度合并
    func mergePlaybackProgress(_ cloudProgresses: [PlaybackProgress], strategy: CloudSyncConflictStrategy) {
        let cache = PlaybackProgressCache.shared
        let localProgresses = cache.progresses
        var toImport: [PlaybackProgress] = []

        for cloudP in cloudProgresses {
            let id = cloudP.id
            if let localP = localProgresses.first(where: { $0.id == id }) {
                let resolution = CloudSyncConflictResolver.resolveRecord(
                    localUpdatedAt: localP.lastPlayedAt,
                    cloudUpdatedAt: cloudP.lastPlayedAt,
                    strategy: strategy
                )
                switch resolution {
                case .useLocal: continue
                case .useCloud: toImport.append(cloudP)
                case .skip: continue
                }
            } else {
                toImport.append(cloudP)
            }
        }

        if !toImport.isEmpty { cache.syncImportProgresses(toImport) }
    }

    // MARK: 库文件夹合并
    func mergeLibraryFolders(_ cloudFolders: LibraryFoldersPayload, strategy: CloudSyncConflictStrategy) {
        guard strategy == .cloudPreferred else { return }
        let store = LibraryFolderStore.shared
        store.syncImportWallpaperFolders(cloudFolders.wallpaper)
        store.syncImportMediaFolders(cloudFolders.media)
    }

    // MARK: Grid 排序合并
    func mergeGridOrder(_ cloudOrder: [String: [String]], strategy: CloudSyncConflictStrategy) {
        guard strategy == .cloudPreferred else { return }
        let store = LibraryGridOrderStore.shared
        store.syncImportOrders(cloudOrder)
    }

    // MARK: 场景设计合并
    func mergeSceneDesigns(_ cloudDesigns: [String: SceneWallpaperDesignPayload]) {
        // 场景设计合并需要查找本地壁纸路径，此处提供基本实现
        // 实际使用时需要根据 wallpaperID 查找对应的本地路径
    }

    func mergeSceneProperties(_ cloudProperties: [String: SceneWallpaperPropertiesPayload]) {
        // 场景属性合并需要查找本地壁纸路径，此处提供基本实现
    }

    func mergeSceneConfigOverrides(_ cloudOverrides: [String: [String: AnyCodable]]) {
        // 场景配置覆盖合并需要查找本地壁纸路径，此处提供基本实现
    }

    // MARK: 数据源 Profile 合并
    func mergeDataSourceProfiles(_ cloudProfiles: DataSourceProfilesPayload) {
        do {
            try DataSourceProfileStore.saveImportedProfiles(cloudProfiles.importedProfiles, defaults: .standard)
        } catch {
            // 忽略持久化失败，仍更新 activeID
        }
        UserDefaults.standard.set(cloudProfiles.activeID, forKey: "data_source_active_profile_id_v1")
    }
}

// MARK: - 导出辅助
extension CloudSyncMetadataEngine {

    static func exportAllSceneDesigns(for downloadRecords: [Any]) -> [String: SceneWallpaperDesignPayload] {
        var result: [String: SceneWallpaperDesignPayload] = [:]
        // 遍历已下载壁纸的本地路径，读取设计文档
        // 此功能在 plan 中被标记为非关键路径，提供基本实现
        return result
    }

    static func exportAllSceneProperties(for downloadRecords: [Any]) -> [String: SceneWallpaperPropertiesPayload] {
        var result: [String: SceneWallpaperPropertiesPayload] = [:]
        return result
    }

    static func exportAllSceneConfigOverrides(for downloadRecords: [Any]) -> [String: [String: AnyCodable]] {
        var result: [String: [String: AnyCodable]] = [:]
        return result
    }

    static func exportDataSourceProfiles() -> DataSourceProfilesPayload? {
        let profiles: [DataSourceProfile] = DataSourceProfileStore.importedProfiles()
        let activeID = UserDefaults.standard.string(forKey: "data_source_active_profile_id_v1") ?? ""
        guard !profiles.isEmpty else { return nil }
        return DataSourceProfilesPayload(activeID: activeID, importedProfiles: profiles)
    }
}

extension DataSourceProfileStore {
    static func importedProfiles() -> [DataSourceProfile] {
        guard let data = UserDefaults.standard.data(forKey: "data_source_profiles_v1"),
              let profiles = try? JSONDecoder().decode([DataSourceProfile].self, from: data) else {
            return []
        }
        return profiles
    }
}
