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

// MARK: - Steam API 响应模型

/// Steam Web API 返回的创意工坊项目列表
struct SteamPublishedFileResponse: Codable {
    let response: SteamPublishedFileQuery
}

struct SteamPublishedFileQuery: Codable {
    let total: Int
    let publishedfiledetails: [SteamPublishedFileDetail]?
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
    let subscriptions: String?
    let favorited: String?
    let views: String?
    let score: String?           // 评分
    let time_created: String?
    let time_updated: String?
    let tags: [SteamTag]?
    let app_name: String?
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
    
    enum SortOption: String {
        case ranked = "ranked"           // 综合排序
        case subscriptions = "subscribed" // 订阅数
        case updated = "updated"         // 最近更新
        case created = "created"         // 最新发布
    }
}

// MARK: - 扩展 WorkshopWallpaper

extension WorkshopWallpaper {
    /// 从 Steam API 响应创建
    init?(from detail: SteamPublishedFileDetail) {
        guard let appName = detail.app_name, appName.contains("Wallpaper") else {
            // 确保是 Wallpaper Engine 的内容
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
            name: "Unknown",  // 需要通过另一个 API 获取
            avatarURL: nil
        )
        
        self.steamAppID = "431960"
        self.subscriptions = Int(detail.subscriptions ?? "0")
        self.favorites = Int(detail.favorited ?? "0")
        self.views = Int(detail.views ?? "0")
        self.rating = Double(detail.score ?? "0")
        
        // 检测类型
        self.type = Self.detectType(from: detail)
        self.tags = detail.tags?.map { $0.tag } ?? []
        
        // 解析时间
        let formatter = ISO8601DateFormatter()
        self.createdAt = detail.time_created.flatMap { formatter.date(from: $0) }
        self.updatedAt = detail.time_updated.flatMap { formatter.date(from: $0) }
    }
    
    /// 根据文件名和内容检测壁纸类型
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
            createdAt: Date(),
            updatedAt: Date()
        )
    }
}
