import Foundation

/// 当前仅保留本地收藏来源，占位以兼容旧代码结构。
enum FavoriteSource: String, Codable {
    case local
}

enum SyncOrigin: String, Codable {
    case local
    case cloud
}

enum SyncState: String, Codable {
    case localOnly
    case pendingUpload
    case synced
    case pendingDeletion
}

/// 为后续 CloudKit/苹果云同步预留的稳定本地元数据。
/// `recordID` 可以直接映射到未来的 `CKRecord.ID(recordName:)`。
struct SyncMetadata: Codable, Hashable {
    let recordID: String
    let entityType: String
    var createdAt: Date
    var updatedAt: Date
    var lastSyncedAt: Date?
    var changeTag: String?
    var origin: SyncOrigin
    var syncState: SyncState
    var isDeleted: Bool

    init(
        recordID: String,
        entityType: String,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        lastSyncedAt: Date? = nil,
        changeTag: String? = nil,
        origin: SyncOrigin = .local,
        syncState: SyncState = .localOnly,
        isDeleted: Bool = false
    ) {
        self.recordID = recordID
        self.entityType = entityType
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastSyncedAt = lastSyncedAt
        self.changeTag = changeTag
        self.origin = origin
        self.syncState = syncState
        self.isDeleted = isDeleted
    }

    mutating func markLocalMutation(deleted: Bool? = nil, at date: Date = .now) {
        updatedAt = date
        origin = .local

        if let deleted {
            isDeleted = deleted
        }

        syncState = isDeleted ? .pendingDeletion : .pendingUpload
    }

    mutating func markSynced(changeTag: String? = nil, at date: Date = .now) {
        updatedAt = date
        lastSyncedAt = date
        self.changeTag = changeTag
        syncState = .synced
    }
}

struct DataSourceCatalog: Codable, Hashable {
    var schemaVersion: String
    var profiles: [DataSourceProfile]
}

struct DataSourceProfile: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var description: String?
    var wallpaper: WallpaperSourceProfile
    var media: MediaSourceProfile
    var anime: AnimeSourceProfile?
}

struct WallpaperSourceProfile: Codable, Hashable {
    var provider: String
    var displayName: String
    var apiBaseURL: String
    var searchPath: String
    var wallpaperPath: String
    var imageURLTemplate: String
    var authHeaderName: String?
}

struct MediaSourceProfile: Codable, Hashable {
    var provider: String
    var displayName: String
    var baseURL: String
    var headers: [String: String]
    var routes: MediaRouteProfile
    var parsing: MediaParsingProfile
}

struct MediaRouteProfile: Codable, Hashable {
    var home: String
    var mobile: String
    var tag: String
    var search: String
    var detail: String
}

struct MediaParsingProfile: Codable, Hashable {
    // XPath 解析规则 (替代原来的正则表达式)
    var searchList: String        // 搜索结果列表 XPath，如 "//div[@class='item']"
    var searchName: String        // 标题提取 XPath，如 ".//h2/text()"
    var searchResult: String      // 链接提取 XPath，如 ".//a/@href"
    var searchCover: String?      // 封面图提取 XPath，如 ".//img/@src"
    var nextPage: String?         // 下一页链接 XPath，如 "//a[@rel='next']/@href"
    var detailList: String?       // 详情页列表 XPath
    var detailName: String?       // 详情页名称 XPath
    var detailLink: String?       // 详情页链接 XPath
    var tagList: String?          // 标签列表 XPath
    var tagName: String?          // 标签名称 XPath
    var downloadPattern: String?  // 下载选项正则 (带回退方案)
    var durationPattern: String?  // 时长正则 (带回退方案)
}

// MARK: - Anime Source Profile (参考 Kazumi 插件格式)
struct AnimeSourceProfile: Codable, Hashable {
    var enabled: Bool
    var provider: String
    var displayName: String
    var baseURL: String
    var headers: [String: String]?
    var userAgent: String?
    var searchURL: String          // 搜索 URL，使用 @keyword 占位符
    var parsing: AnimeParsingProfile
}

struct AnimeParsingProfile: Codable, Hashable {
    var searchList: String         // 搜索结果列表 XPath
    var searchName: String         // 标题 XPath
    var searchResult: String       // 详情链接 XPath
    var searchCover: String?       // 封面图 XPath
    var chapterRoads: String?      // 剧集列表页 XPath (进入详情页后)
    var chapterResult: String?     // 剧集链接 XPath
    var chapterName: String?       // 剧集名称 XPath
    var detailCover: String?       // 详情页封面 XPath
    var detailDescription: String? // 详情页描述 XPath
}

enum DataSourceProfileError: LocalizedError {
    case invalidFile
    case emptyProfiles
    case invalidProfile(String)

    var errorDescription: String? {
        switch self {
        case .invalidFile:
            return "Invalid data source profile file."
        case .emptyProfiles:
            return "No profiles found in imported file."
        case .invalidProfile(let reason):
            return reason
        }
    }
}

enum DataSourceProfileStore {
    static let schemaVersion = "1.0.0"
    static let importedProfilesKey = "data_source_profiles_v1"
    static let activeProfileIDKey = "data_source_active_profile_id_v1"

    /// 从 Resources/DataSourceProfile.json 加载内置配置
    static var builtinCatalog: DataSourceCatalog {
        loadBuiltinCatalog()
    }

    /// 内置默认配置（从 Bundle 加载，失败时使用 fallback）
    static var builtinProfile: DataSourceProfile {
        builtinCatalog.profiles.first ?? fallbackProfile
    }

    /// Fallback 配置（当 JSON 文件缺失或损坏时使用）
    private static var fallbackProfile: DataSourceProfile {
        DataSourceProfile(
            id: "wallhaven-default",
            name: "WallHaven (Fallback)",
            description: "Fallback configuration when built-in config is unavailable.",
            wallpaper: WallpaperSourceProfile(
                provider: "wallhaven_api",
                displayName: "WallHaven",
                apiBaseURL: "https://wallhaven.cc/api/v1",
                searchPath: "/search",
                wallpaperPath: "/w/{id}",
                imageURLTemplate: "https://w.wallhaven.cc/full/{prefix}/wallhaven-{id}.{ext}",
                authHeaderName: "X-API-Key"
            ),
            media: MediaSourceProfile(
                provider: "fallback",
                displayName: "Fallback",
                baseURL: "https://example.com",
                headers: [:],
                routes: MediaRouteProfile(
                    home: "/",
                    mobile: "/",
                    tag: "/",
                    search: "/",
                    detail: "/"
                ),
                parsing: MediaParsingProfile(
                    searchList: "//div",
                    searchName: ".//text()",
                    searchResult: "@href",
                    searchCover: nil,
                    nextPage: nil,
                    detailList: nil,
                    detailName: nil,
                    detailLink: nil,
                    tagList: nil,
                    tagName: nil
                )
            ),
            anime: nil
        )
    }

    /// 从 Bundle 的 Resources/DataSourceProfile.json 加载配置
    private static func loadBuiltinCatalog() -> DataSourceCatalog {
        // 首先尝试从应用 Bundle 加载（生产环境）
        if let url = Bundle.main.url(forResource: "DataSourceProfile", withExtension: "json", subdirectory: "Resources"),
           let data = try? Data(contentsOf: url),
           let catalog = try? JSONDecoder().decode(DataSourceCatalog.self, from: data) {
            print("[DataSourceProfileStore] Loaded built-in config from Bundle Resources")
            return catalog
        }

        // 尝试从 Bundle 根目录加载（备用）
        if let url = Bundle.main.url(forResource: "DataSourceProfile", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let catalog = try? JSONDecoder().decode(DataSourceCatalog.self, from: data) {
            print("[DataSourceProfileStore] Loaded built-in config from Bundle root")
            return catalog
        }

        // 开发环境：尝试从当前工作目录的 Resources 目录加载
        #if DEBUG
        let fileManager = FileManager.default
        if let currentPath = fileManager.currentDirectoryPath as String?,
           let projectURL = URL(string: "file://\(currentPath)/Resources/DataSourceProfile.json"),
           fileManager.fileExists(atPath: projectURL.path),
           let data = try? Data(contentsOf: projectURL),
           let catalog = try? JSONDecoder().decode(DataSourceCatalog.self, from: data) {
            print("[DataSourceProfileStore] Loaded built-in config from current directory")
            return catalog
        }
        #endif

        // 失败时返回空 catalog
        print("[DataSourceProfileStore] Failed to load built-in config, using empty catalog")
        return DataSourceCatalog(schemaVersion: schemaVersion, profiles: [])
    }

    static func allProfiles(defaults: UserDefaults = .standard) -> [DataSourceProfile] {
        [builtinProfile] + importedProfiles(defaults: defaults)
    }

    static func importedProfiles(defaults: UserDefaults = .standard) -> [DataSourceProfile] {
        guard
            let data = defaults.data(forKey: importedProfilesKey),
            let profiles = try? JSONDecoder().decode([DataSourceProfile].self, from: data)
        else {
            return []
        }
        return profiles
    }

    static func activeProfile(defaults: UserDefaults = .standard) -> DataSourceProfile {
        let profiles = allProfiles(defaults: defaults)
        let activeID = defaults.string(forKey: activeProfileIDKey) ?? builtinProfile.id
        print("[DataSourceProfileStore] activeProfile: activeID=\(activeID), availableProfiles=\(profiles.map { $0.id })")
        let profile = profiles.first(where: { $0.id == activeID }) ?? builtinProfile
        print("[DataSourceProfileStore] activeProfile: resolvedProfile=\(profile.id)")
        return profile
    }

    static func activeProfileID(defaults: UserDefaults = .standard) -> String {
        activeProfile(defaults: defaults).id
    }

    static func setActiveProfileID(_ id: String, defaults: UserDefaults = .standard) {
        defaults.set(id, forKey: activeProfileIDKey)
    }

    static func reset(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: importedProfilesKey)
        defaults.set(builtinProfile.id, forKey: activeProfileIDKey)
    }

    static func importProfiles(from data: Data, defaults: UserDefaults = .standard) throws -> [DataSourceProfile] {
        let decodedProfiles = try decodeProfiles(from: data)
        guard !decodedProfiles.isEmpty else {
            throw DataSourceProfileError.emptyProfiles
        }

        let validated = try decodedProfiles.map(validate)
        var merged: [DataSourceProfile] = importedProfiles(defaults: defaults)
        for profile in validated {
            if let index = merged.firstIndex(where: { $0.id == profile.id }) {
                merged[index] = profile
            } else {
                merged.append(profile)
            }
        }
        try saveImportedProfiles(merged, defaults: defaults)

        if defaults.string(forKey: activeProfileIDKey) == nil {
            defaults.set(builtinProfile.id, forKey: activeProfileIDKey)
        }

        return allProfiles(defaults: defaults)
    }

    static func saveImportedProfiles(_ profiles: [DataSourceProfile], defaults: UserDefaults = .standard) throws {
        let encoded = try JSONEncoder().encode(profiles)
        defaults.set(encoded, forKey: importedProfilesKey)
    }

    static func removeImportedProfile(id: String, defaults: UserDefaults = .standard) throws {
        let remaining = importedProfiles(defaults: defaults).filter { $0.id != id }
        try saveImportedProfiles(remaining, defaults: defaults)
        if activeProfileID(defaults: defaults) == id {
            defaults.set(builtinProfile.id, forKey: activeProfileIDKey)
        }
    }

    /// 初始化数据源配置，确保首次启动或重置后有有效的配置
    static func initialize(defaults: UserDefaults = .standard) {
        // 如果没有设置活跃配置ID，设置为内置配置
        if defaults.string(forKey: activeProfileIDKey) == nil {
            defaults.set(builtinProfile.id, forKey: activeProfileIDKey)
            print("[DataSourceProfileStore] 初始化默认配置: \(builtinProfile.id)")
        }

        // 验证当前活跃配置是否有效
        let activeID = defaults.string(forKey: activeProfileIDKey)
        let all = allProfiles(defaults: defaults)
        if let id = activeID, !all.contains(where: { $0.id == id }) {
            // 如果活跃配置ID对应的配置不存在，重置为内置配置
            defaults.set(builtinProfile.id, forKey: activeProfileIDKey)
            print("[DataSourceProfileStore] 重置为默认配置: \(builtinProfile.id)")
        }
    }

    static func exportBuiltinCatalogJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(builtinCatalog)
        guard let string = String(data: data, encoding: .utf8) else {
            throw DataSourceProfileError.invalidFile
        }
        return string
    }

    private static func decodeProfiles(from data: Data) throws -> [DataSourceProfile] {
        let decoder = JSONDecoder()
        if let catalog = try? decoder.decode(DataSourceCatalog.self, from: data) {
            return catalog.profiles
        }
        if let profile = try? decoder.decode(DataSourceProfile.self, from: data) {
            return [profile]
        }
        throw DataSourceProfileError.invalidFile
    }

    private static func validate(_ profile: DataSourceProfile) throws -> DataSourceProfile {
        guard !profile.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DataSourceProfileError.invalidProfile("Profile id cannot be empty.")
        }
        guard !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DataSourceProfileError.invalidProfile("Profile name cannot be empty.")
        }
        guard URL(string: profile.wallpaper.apiBaseURL) != nil else {
            throw DataSourceProfileError.invalidProfile("Wallpaper apiBaseURL is invalid for profile \(profile.name).")
        }
        guard URL(string: profile.media.baseURL) != nil else {
            throw DataSourceProfileError.invalidProfile("Media baseURL is invalid for profile \(profile.name).")
        }
        guard !profile.media.parsing.searchList.isEmpty else {
            throw DataSourceProfileError.invalidProfile("Media searchList XPath cannot be empty for profile \(profile.name).")
        }
        guard !profile.media.parsing.searchName.isEmpty else {
            throw DataSourceProfileError.invalidProfile("Media searchName XPath cannot be empty for profile \(profile.name).")
        }
        guard !profile.media.parsing.searchResult.isEmpty else {
            throw DataSourceProfileError.invalidProfile("Media searchResult XPath cannot be empty for profile \(profile.name).")
        }
        // 可选：验证 XPath 格式（简单检查是否以 // 或 . 开头）
        let xpathPatterns = [
            profile.media.parsing.searchList,
            profile.media.parsing.searchName,
            profile.media.parsing.searchResult,
            profile.media.parsing.searchCover,
            profile.media.parsing.nextPage,
            profile.media.parsing.detailList,
            profile.media.parsing.detailName,
            profile.media.parsing.detailLink,
            profile.media.parsing.tagList,
            profile.media.parsing.tagName
        ].compactMap { $0 }

        for pattern in xpathPatterns {
            if !pattern.isEmpty && !isValidXPath(pattern) {
                throw DataSourceProfileError.invalidProfile("Invalid XPath pattern: \(pattern)")
            }
        }
        return profile
    }

    /// 简单验证 XPath 格式（以 // 或 . 开头）
    private static func isValidXPath(_ xpath: String) -> Bool {
        let trimmed = xpath.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("//") ||
               trimmed.hasPrefix("./") ||
               trimmed.hasPrefix("@") ||
               trimmed.hasPrefix("(") ||
               trimmed == "."
    }
}
