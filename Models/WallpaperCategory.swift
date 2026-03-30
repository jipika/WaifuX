import Foundation

// MARK: - 壁纸分类
enum WallpaperCategory: String, CaseIterable, Identifiable {
    case favorites
    case general
    case anime
    case people
    case nature
    case technology

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .favorites: return "收藏"
        case .general: return "通用"
        case .anime: return "动漫"
        case .people: return "人物"
        case .nature: return "自然"
        case .technology: return "科技"
        }
    }

    var icon: String {
        switch self {
        case .favorites: return "heart.fill"
        case .general: return "star.fill"
        case .anime: return "face.smiling"
        case .people: return "person.2"
        case .nature: return "leaf"
        case .technology: return "cpu"
        }
    }

    var apiCategory: String {
        switch self {
        case .favorites: return ""
        case .general: return "100"
        case .anime: return "010"
        case .people: return "001"
        case .nature: return "001"
        case .technology: return "001"
        }
    }

    var searchTag: String? {
        switch self {
        case .favorites: return nil
        case .general: return nil
        case .anime: return "anime"
        case .people: return "people"
        case .nature: return "nature"
        case .technology: return "technology"
        }
    }
}
