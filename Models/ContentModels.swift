import Foundation

// MARK: - 内容类型

enum ContentType: String, CaseIterable, Codable {
    case wallpaper = "wallpaper"
    case video = "video"
    case anime = "anime"

    var displayName: String {
        switch self {
        case .wallpaper: return LocalizationService.shared.t("content.wallpaper")
        case .video: return LocalizationService.shared.t("content.video")
        case .anime: return LocalizationService.shared.t("content.anime")
        }
    }

    var icon: String {
        switch self {
        case .wallpaper: return "photo"
        case .video: return "film"
        case .anime: return "play.tv"
        }
    }
}

// MARK: - 通用内容项（壁纸 + 动漫 + 视频）

struct UniversalContentItem: Identifiable, Codable {
    let id: String
    let contentType: ContentType

    // 通用字段
    let title: String
    let thumbnailURL: String
    let coverURL: String?
    let description: String?
    let tags: [String]

    // 来源信息
    let sourceType: String
    let sourceURL: String
    let sourceName: String

    // 类型特定数据
    let metadata: ContentMetadata

    // 时间戳
    let createdAt: Date?
    let updatedAt: Date?
}

// MARK: - 内容元数据（根据类型不同）

enum ContentMetadata: Codable {
    case wallpaper(WallpaperMetadata)
    case anime(AnimeMetadata)
    case video(VideoMetadata)

    struct WallpaperMetadata: Codable {
        let fullImageURL: String
        let resolution: String?
        let fileSize: String?
        let fileType: String?
        let purity: String?
        let uploader: String?
        let category: String?
    }

    struct AnimeMetadata: Codable {
        let episodes: [AnimeEpisode]
        let currentEpisode: Int?
        let totalEpisodes: Int?
        let status: String?
        let aired: String?
        let rating: String?
    }

    struct VideoMetadata: Codable {
        let videoURL: String
        let duration: String?
        let resolution: String?
        let fileSize: String?
        let format: String?
    }

    // MARK: - Coding

    enum CodingKeys: String, CodingKey {
        case type, data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        let data = try container.decode(Data.self, forKey: .data)
        let decoder = JSONDecoder()

        switch type {
        case "wallpaper":
            self = .wallpaper(try decoder.decode(WallpaperMetadata.self, from: data))
        case "anime":
            self = .anime(try decoder.decode(AnimeMetadata.self, from: data))
        case "video":
            self = .video(try decoder.decode(VideoMetadata.self, from: data))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown type: \(type)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let encoder = JSONEncoder()

        switch self {
        case .wallpaper(let metadata):
            try container.encode("wallpaper", forKey: .type)
            try container.encode(encoder.encode(metadata), forKey: .data)
        case .anime(let metadata):
            try container.encode("anime", forKey: .type)
            try container.encode(encoder.encode(metadata), forKey: .data)
        case .video(let metadata):
            try container.encode("video", forKey: .type)
            try container.encode(encoder.encode(metadata), forKey: .data)
        }
    }
}

// MARK: - 动漫剧集

struct AnimeEpisode: Identifiable, Codable {
    let id: String
    let episodeNumber: Int
    let title: String?
    let thumbnailURL: String?
    let videoURLs: [VideoSource]
    let duration: String?
}

struct VideoSource: Codable {
    let quality: String
    let url: String
    let type: String
    let label: String?
}

// MARK: - 观看进度

struct WatchProgress: Codable {
    let animeId: String
    var currentEpisode: Int
    var episodeProgress: Double
    var lastWatchedAt: Date
}
