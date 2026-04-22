import Foundation

// MARK: - Workshop 壁纸模型
///
/// 表示 Wallpaper Engine Steam 创意工坊中的一个壁纸项目
struct WorkshopWallpaper: Identifiable, Codable {
    let id: String              // Steam Workshop ID
    let title: String
    let description: String?
    let previewURL: URL?        // 预览图 URL
    let author: WorkshopAuthor
    let fileSize: Int64?        // 文件大小（字节）
    let fileURL: URL?           // 下载链接（需要 SteamCMD 获取）
    
    // Steam 相关数据
    let steamAppID: String      // 通常是 431960 (Wallpaper Engine)
    let subscriptions: Int?     // 订阅数
    let favorites: Int?         // 收藏数
    let views: Int?             // 浏览数
    let rating: Double?         // 评分 0-5
    
    // 壁纸类型
    let type: WallpaperType
    let tags: [String]
    let isAnimatedImage: Bool?
    
    // 时间戳
    let createdAt: Date?
    let updatedAt: Date?
    
    enum WallpaperType: String, Codable {
        case video = "video"
        case scene = "scene"           // Unity WebGL
        case web = "web"               // HTML/JS
        case application = "application"
        case image = "image"
        case pkg = "pkg"               // 打包格式
        case unknown = "unknown"
    }
}

// MARK: - Workshop 作者信息
struct WorkshopAuthor: Codable {
    let steamID: String
    let name: String
    let avatarURL: URL?
}

// MARK: - Workshop 搜索响应
struct WorkshopSearchResponse: Codable {
    let items: [WorkshopWallpaper]
    let total: Int
    let page: Int
    let hasMore: Bool
}

// MARK: - Steam Workshop Browse JSON API 响应模型

/// Steam 内部 Workshop Browse JSON API 响应
struct SteamWorkshopBrowseResponse: Codable {
    let current_page: Int
    let total_pages: Int
    let total_count: Int
    let next_cursor: String?
    let results: [SteamWorkshopItem]
}

struct SteamWorkshopItem: Codable {
    let publishedfileid: String
    let creator: String
    let consumer_appid: Int
    let file_type: Int
    let preview_url: String?
    let title: String
    let short_description: String?
    let workshop_accepted: Bool
    let flags: Int
    let reactions: [SteamWorkshopReaction]?
    let num_children: Int
    let children: [SteamWorkshopChild]?
    let previews: [SteamWorkshopPreview]?
    let time_created: Int
    let time_updated: Int
    let file_size: String?
    let tags: [SteamWorkshopTag]?
    let subscriptions: Int?
    let favorited: Int?
    let lifetime_subscriptions: Int?
    let lifetime_favorited: Int?
    let views: Int?
    let star_rating: Double?
    let total_votes: Int?
}

struct SteamWorkshopTag: Codable {
    let tag: String
    let display_name: String
}

struct SteamWorkshopReaction: Codable {}

struct SteamWorkshopChild: Codable {}

struct SteamWorkshopPreview: Codable {}

// MARK: - Steam Web API 响应模型 (旧版，保留兼容)

/// Steam Web API 返回的创意工坊项目列表
struct SteamPublishedFileResponse: Codable {
    let response: SteamPublishedFileQuery
}

struct SteamPublishedFileQuery: Codable {
    let result: Int?
    let resultcount: Int?
    let publishedfiledetails: [SteamPublishedFileDetail]?
}

struct SteamPublishedFileVoteData: Codable {
    let score: Double?
    let votes_up: Int?
    let votes_down: Int?
}

struct SteamPublishedFileDetail: Codable {
    let publishedfileid: String
    let title: String
    let description: String?
    let preview_url: String?
    let file_url: String?
    let filename: String?
    let file_size: String?
    let creator: String
    let creator_app_id: Int?
    let consumer_app_id: Int?
    let subscriptions: Int?
    let favorited: Int?
    let lifetime_subscriptions: Int?
    let lifetime_favorited: Int?
    let views: Int?
    let score: Double?  // 旧版兼容，新版 API 使用 vote_data.score
    let vote_data: SteamPublishedFileVoteData?
    let time_created: Int?
    let time_updated: Int?
    let tags: [SteamTag]?
    let app_name: String?  // 旧版兼容，新版 API 不返回此字段
}

struct SteamTag: Codable {
    let tag: String
}

// MARK: - 搜索参数
struct WorkshopSearchParams {
    var query: String = ""
    var sortBy: SortOption = .ranked
    var page: Int = 1
    var pageSize: Int = 20
    var tags: [String] = []
    var type: WorkshopWallpaper.WallpaperType?
    var contentLevel: String?
    /// 分辨率/比例筛选（通过 requiredtags[] 发送，如 "1920 x 1080"）
    var resolution: String?
    /// 时间范围（仅对 trend 排序有效），nil 表示全部时间
    var days: Int?
    
    enum SortOption: String {
        case ranked = "ranked"           // 热门趋势
        case updated = "updated"         // 最新更新
        case created = "created"         // 最近发布
        case topRated = "toprated"       // 最受好评
    }
}

// MARK: - 扩展 WorkshopWallpaper

extension WorkshopWallpaper {
    /// 从 Steam Workshop Browse JSON API 响应创建
    init(from item: SteamWorkshopItem) {
        self.id = item.publishedfileid
        self.title = item.title
        self.description = item.short_description
        self.previewURL = item.preview_url.flatMap { URL(string: $0) }
        self.fileURL = nil  // JSON API 不直接返回下载链接
        self.fileSize = Int64(item.file_size ?? "0")
        
        self.author = WorkshopAuthor(
            steamID: item.creator,
            name: "Unknown",  // JSON API 不返回作者名称
            avatarURL: nil
        )
        
        self.steamAppID = String(item.consumer_appid)
        self.subscriptions = item.subscriptions
        self.favorites = item.favorited ?? item.lifetime_favorited
        self.views = item.views
        self.rating = item.star_rating.flatMap { $0 >= 0 ? $0 : nil }
        
        // 检测类型（优先从 tags 推断）
        self.type = Self.detectType(from: item)
        self.tags = item.tags?.map { $0.tag } ?? []
        self.isAnimatedImage = Self.detectAnimatedImage(from: item.preview_url)
        
        // 解析时间
        self.createdAt = Date(timeIntervalSince1970: TimeInterval(item.time_created))
        self.updatedAt = Date(timeIntervalSince1970: TimeInterval(item.time_updated))
    }
    
    /// 从 Steam Web API 响应创建（旧版兼容）
    init?(from detail: SteamPublishedFileDetail) {
        guard let appName = detail.app_name, appName.contains("Wallpaper") else {
            return nil
        }
        
        self.id = detail.publishedfileid
        self.title = detail.title
        self.description = detail.description
        self.previewURL = detail.preview_url.flatMap { URL(string: $0) }
        self.fileURL = detail.file_url.flatMap { URL(string: $0) }
        self.fileSize = Int64(detail.file_size ?? "0")
        
        self.author = WorkshopAuthor(
            steamID: detail.creator,
            name: "Unknown",
            avatarURL: nil
        )
        
        self.steamAppID = String(detail.consumer_app_id ?? 431960)
        self.subscriptions = detail.subscriptions
        self.favorites = detail.favorited
        self.views = detail.views
        self.rating = detail.vote_data?.score ?? detail.score
        
        self.type = Self.detectType(from: detail)
        self.tags = detail.tags?.map { $0.tag } ?? []
        self.isAnimatedImage = Self.detectAnimatedImage(from: detail.preview_url)
        
        self.createdAt = detail.time_created.flatMap { Date(timeIntervalSince1970: TimeInterval($0)) }
        self.updatedAt = detail.time_updated.flatMap { Date(timeIntervalSince1970: TimeInterval($0)) }
    }
    
    /// 合并 HTML 基础信息和 Steam Web API 详情
    init(base: WorkshopWallpaper, detail: SteamPublishedFileDetail) {
        self.id = detail.publishedfileid
        self.title = detail.title.isEmpty ? base.title : detail.title
        self.description = detail.description
        self.previewURL = detail.preview_url.flatMap { URL(string: $0) } ?? base.previewURL
        // API 返回 creator (Steam ID)，但不出作者显示名，保留 HTML 解析到的名字
        self.author = WorkshopAuthor(
            steamID: detail.creator,
            name: base.author.name != "Unknown" ? base.author.name : "Unknown",
            avatarURL: base.author.avatarURL
        )
        self.fileSize = Int64(detail.file_size ?? "0")
        self.fileURL = detail.file_url.flatMap { URL(string: $0) }
        self.steamAppID = String(detail.consumer_app_id ?? 431960)
        // API 可能返回 nil，优先用 API 值，其次保留 HTML 解析值，再次用 lifetime 累计值
        self.subscriptions = detail.subscriptions ?? base.subscriptions ?? detail.lifetime_subscriptions
        self.favorites = detail.favorited ?? base.favorites ?? detail.lifetime_favorited
        self.views = detail.views ?? base.views
        self.rating = detail.vote_data?.score ?? detail.score ?? base.rating
        self.type = WorkshopWallpaper.detectType(fromTags: detail.tags?.map(\.tag) ?? [])
        self.tags = detail.tags?.map(\.tag) ?? []
        self.isAnimatedImage = base.isAnimatedImage
        self.createdAt = detail.time_created.flatMap { Date(timeIntervalSince1970: TimeInterval($0)) }
        self.updatedAt = detail.time_updated.flatMap { Date(timeIntervalSince1970: TimeInterval($0)) }
    }
    
    /// 检测预览图是否为动态 GIF
    private static func detectAnimatedImage(from previewURL: String?) -> Bool {
        guard let url = previewURL?.lowercased() else { return false }
        return url.contains(".gif")
    }
    
    /// 从标签数组检测类型
    public static func detectType(fromTags tags: [String]) -> WallpaperType {
        let lowerTags = tags.map { $0.lowercased() }

        if lowerTags.contains("video") || lowerTags.contains("video wallpaper") {
            return .video
        } else if lowerTags.contains("web") || lowerTags.contains("web wallpaper") {
            return .web
        } else if lowerTags.contains("scene") {
            return .scene
        } else if lowerTags.contains("application") {
            return .application
        } else if lowerTags.contains("image") || lowerTags.contains("wallpaper") {
            // 默认 Wallpaper Engine 的大多数 "Wallpaper" 标签实际上是视频/动态壁纸
            return .video
        }

        return .unknown
    }

    /// 从 Workshop JSON Item 检测类型
    private static func detectType(from item: SteamWorkshopItem) -> WallpaperType {
        let tagStrings = item.tags?.map { $0.tag } ?? []
        let fromTags = detectType(fromTags: tagStrings)
        return fromTags == .unknown ? .video : fromTags
    }
    
    /// 根据文件名和内容检测壁纸类型（旧版 API）
    private static func detectType(from detail: SteamPublishedFileDetail) -> WallpaperType {
        let filename = detail.filename?.lowercased() ?? ""
        
        if filename.contains(".mp4") || filename.contains(".webm") || filename.contains(".mov") {
            return .video
        } else if filename.contains(".html") || filename.contains(".htm") {
            return .web
        } else if filename.contains(".unity") || filename.contains(".scene") {
            return .scene
        } else if filename.contains(".pkg") {
            return .pkg
        } else if filename.contains(".jpg") || filename.contains(".png") {
            return .image
        }
        
        return .unknown
    }
}

// MARK: - 示例数据
extension WorkshopWallpaper {
    static var preview: WorkshopWallpaper {
        WorkshopWallpaper(
            id: "1234567890",
            title: "Cyberpunk City Night",
            description: "A beautiful cyberpunk city at night with animated neon lights",
            previewURL: URL(string: "https://example.com/preview.jpg"),
            author: WorkshopAuthor(
                steamID: "76561198000000000",
                name: "CyberArtist",
                avatarURL: nil
            ),
            fileSize: 150_000_000,  // 150MB
            fileURL: nil,
            steamAppID: "431960",
            subscriptions: 15000,
            favorites: 3200,
            views: 50000,
            rating: 4.8,
            type: .video,
            tags: ["Cyberpunk", "City", "Night", "Neon", "Sci-Fi"],
            isAnimatedImage: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
    }
}
