import Foundation

// MARK: - 主标签类型
public enum MainTab: String, CaseIterable {
    case home, wallpaperExplore, mediaExplore, animeExplore, myMedia

    var title: String {
        switch self {
        case .home: return t("nav.home")
        case .wallpaperExplore: return t("nav.wallpaper")
        case .animeExplore: return t("nav.anime")
        case .mediaExplore: return t("nav.media")
        case .myMedia: return t("nav.myMedia")
        }
    }

    var icon: String {
        switch self {
        case .home: return "house"
        case .wallpaperExplore: return "photo"
        case .animeExplore: return "play.tv"
        case .mediaExplore: return "film"
        case .myMedia: return "heart"
        }
    }
}

