import Foundation

enum MediaRouteSource: Equatable {
    case home
    case mobile
    case tag(String)
    case search(String)

    var defaultTitle: String {
        switch self {
        case .home:
            return "Featured"
        case .mobile:
            return "Mobile"
        case .tag(let slug):
            return slug
                .replacingOccurrences(of: "-", with: " ")
                .capitalized
        case .search(let query):
            return query
        }
    }
}
