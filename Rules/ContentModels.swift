import Foundation

enum ContentType: String, CaseIterable, Codable {
    case wallpaper = "wallpaper"
    case anime = "anime"
    case video = "video"

    var displayName: String {
        switch self {
        case .wallpaper: return "壁纸"
        case .anime: return "动漫"
        case .video: return "视频"
        }
    }

    var icon: String {
        switch self {
        case .wallpaper: return "photo"
        case .anime: return "play.tv"
        case .video: return "film"
        }
    }
}

enum ContentMetadata: Codable {
    case wallpaper(WallpaperMetadata)
    case anime(AnimeMetadata)
    case video(VideoMetadata)
    case none

    struct WallpaperMetadata: Codable {
        let resolution: String?
        let fileSize: String?
        let fileType: String?
        let sourceId: String?
    }

    struct AnimeMetadata: Codable {
        let episodes: [Episode]
        let currentEpisode: Episode?
        let totalEpisodes: Int?
        let status: String?
        let aired: String?
        let rating: String?
    }

    struct VideoMetadata: Codable {
        let duration: String?
        let quality: String?
        let views: Int?
        let uploadDate: String?
    }

    struct Episode: Codable, Identifiable {
        let id: String
        let name: String
        let url: String
        let thumbnail: String?
    }
}

struct UniversalContentItem: Identifiable, Codable {
    let id: String
    let contentType: ContentType
    let title: String
    let thumbnailURL: String
    let coverURL: String?
    let description: String?
    let tags: [String]
    let sourceType: String
    let sourceURL: String
    let sourceName: String
    let metadata: ContentMetadata
    let createdAt: Date?
    let updatedAt: Date?
}
