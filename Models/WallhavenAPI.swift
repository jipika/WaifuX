import Foundation

/// Wallhaven API 配置和端点构建器
///
/// API Rate Limits: 45 requests per minute
/// For more details, see: https://wallhaven.cc/help/api
enum WallhavenAPI {
    static var baseURL: String {
        DataSourceProfileStore.activeProfile().wallpaper.apiBaseURL
    }

    struct ColorPreset: Identifiable, Hashable {
        let hex: String
        let displayName: String

        var id: String { hex }
        var displayHex: String { "#\(hex.uppercased())" }
    }

    struct SearchParameters {
        var query: String = ""
        var page: Int = 1
        var perPage: Int = 8  // 减少每页数量，提高加载速度
        var categories: String = "111"
        var purity: String = "100"
        var sorting: String = "date_added"
        var order: String = "desc"
        var topRange: String?
        var atleast: String?
        var resolutions: [String] = []
        var ratios: [String] = []
        var colors: [String] = []
        var seed: String?
        // Note: includeFields is not documented in the official Wallhaven API v1
        // Keeping for backward compatibility but may be removed in future
        var includeFields: [String] = ["uploader", "tags", "colors"]
    }

    enum Endpoint {
        case search(SearchParameters)
        case wallpaper(id: String)
    }

    static func url(for endpoint: Endpoint, apiKey: String? = nil) -> URL? {
        let profile = DataSourceProfileStore.activeProfile().wallpaper
        switch endpoint {
        case .search(let parameters):
            return buildSearchURL(parameters: parameters, apiKey: apiKey)
        case .wallpaper(let id):
            return makeURL(baseURL: profile.apiBaseURL, path: profile.wallpaperPath.replacingOccurrences(of: "{id}", with: id))
        }
    }

    static func authenticationHeaders(apiKey: String?) -> [String: String] {
        let authHeaderName = DataSourceProfileStore.activeProfile().wallpaper.authHeaderName ?? "X-API-Key"
        guard let apiKey = normalizedAPIKey(apiKey) else {
            return ["Accept": "application/json"]
        }

        return [
            "Accept": "application/json",
            authHeaderName: apiKey
        ]
    }

    /// 获取认证用的 query item (当 header 被拦截时作为备选)
    static func authenticationQueryItem(apiKey: String?) -> URLQueryItem? {
        guard let apiKey = normalizedAPIKey(apiKey) else { return nil }
        return URLQueryItem(name: "apikey", value: apiKey)
    }

    static let officialColorPalette: [ColorPreset] = [
        .init(hex: "660000", displayName: "Lonestar"),
        .init(hex: "990000", displayName: "Red Berry"),
        .init(hex: "cc0000", displayName: "Guardsman Red"),
        .init(hex: "cc3333", displayName: "Persian Red"),
        .init(hex: "ea4c88", displayName: "French Rose"),
        .init(hex: "993399", displayName: "Plum"),
        .init(hex: "663399", displayName: "Royal Purple"),
        .init(hex: "333399", displayName: "Sapphire"),
        .init(hex: "0066cc", displayName: "Science Blue"),
        .init(hex: "0099cc", displayName: "Pacific Blue"),
        .init(hex: "66cccc", displayName: "Downy"),
        .init(hex: "77cc33", displayName: "Atlantis"),
        .init(hex: "669900", displayName: "Limeade"),
        .init(hex: "336600", displayName: "Verdun Green"),
        .init(hex: "666600", displayName: "Verdun Olive"),
        .init(hex: "999900", displayName: "Olive"),
        .init(hex: "cccc33", displayName: "Earls Green"),
        .init(hex: "ffff00", displayName: "Yellow"),
        .init(hex: "ffcc33", displayName: "Sunglow"),
        .init(hex: "ff9900", displayName: "Orange Peel"),
        .init(hex: "ff6600", displayName: "Blaze Orange"),
        .init(hex: "cc6633", displayName: "Tuscany"),
        .init(hex: "996633", displayName: "Potters Clay"),
        .init(hex: "663300", displayName: "Nutmeg"),
        .init(hex: "000000", displayName: "Black"),
        .init(hex: "999999", displayName: "Dusty Gray"),
        .init(hex: "cccccc", displayName: "Silver"),
        .init(hex: "ffffff", displayName: "White"),
        .init(hex: "424153", displayName: "Gun Powder")
    ]

    static func colorPreset(for hex: String) -> ColorPreset? {
        let normalized = hex.replacingOccurrences(of: "#", with: "").lowercased()
        return officialColorPalette.first { $0.hex.lowercased() == normalized }
    }

    private static func buildSearchURL(parameters: SearchParameters, apiKey: String? = nil) -> URL? {
        let wallpaper = DataSourceProfileStore.activeProfile().wallpaper
        guard let searchURL = makeURL(baseURL: wallpaper.apiBaseURL, path: wallpaper.searchPath) else {
            return nil
        }
        var components = URLComponents(url: searchURL, resolvingAgainstBaseURL: false)

        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "page", value: String(max(parameters.page, 1))),
            URLQueryItem(name: "per_page", value: String(parameters.perPage)),
            URLQueryItem(name: "categories", value: parameters.categories),
            URLQueryItem(name: "purity", value: parameters.purity),
            URLQueryItem(name: "sorting", value: parameters.sorting),
            URLQueryItem(name: "order", value: parameters.order)
        ]

        let trimmedQuery = parameters.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedQuery.isEmpty {
            queryItems.append(URLQueryItem(name: "q", value: trimmedQuery))
        }

        // toplist 排序时必须提供 topRange
        if parameters.sorting == "toplist" {
            let range = parameters.topRange?.isEmpty == false ? parameters.topRange! : "1M"
            queryItems.append(URLQueryItem(name: "topRange", value: range))
        }

        if let atleast = parameters.atleast, !atleast.isEmpty {
            queryItems.append(URLQueryItem(name: "atleast", value: atleast))
        }

        let resolutions = parameters.resolutions.filter { !$0.isEmpty }
        if !resolutions.isEmpty {
            queryItems.append(URLQueryItem(name: "resolutions", value: resolutions.joined(separator: ",")))
        }

        let ratios = parameters.ratios.filter { !$0.isEmpty }
        if !ratios.isEmpty {
            queryItems.append(URLQueryItem(name: "ratios", value: ratios.joined(separator: ",")))
        }

        if let firstColor = parameters.colors.first(where: { !$0.isEmpty }) {
            queryItems.append(URLQueryItem(name: "colors", value: firstColor))
        }

        // random 排序时可选 seed，用于 consistent pagination
        if parameters.sorting == "random", let seed = parameters.seed, !seed.isEmpty {
            queryItems.append(URLQueryItem(name: "seed", value: seed))
        }

        // API Key 认证 (query 参数方式，当 header 被拦截时使用)
        if let authItem = authenticationQueryItem(apiKey: apiKey) {
            queryItems.append(authItem)
        }

        if !parameters.includeFields.isEmpty {
            queryItems.append(URLQueryItem(name: "includeFields", value: parameters.includeFields.joined(separator: ",")))
        }

        components?.queryItems = queryItems

        // 打印完整的请求 URL 用于调试
        if let finalURL = components?.url {
            print("[WallhavenAPI] Request URL: \(finalURL.absoluteString)")
        }

        return components?.url
    }

    private static func normalizedAPIKey(_ apiKey: String?) -> String? {
        guard let apiKey else { return nil }
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 构建图片直链 URL
    static func imageURL(wallpaperId: String, ext: String = "jpg") -> URL? {
        let prefix = String(wallpaperId.prefix(2))
        let template = DataSourceProfileStore.activeProfile().wallpaper.imageURLTemplate
            .replacingOccurrences(of: "{prefix}", with: prefix)
            .replacingOccurrences(of: "{id}", with: wallpaperId)
            .replacingOccurrences(of: "{ext}", with: ext)
        return makeURL(baseURL: DataSourceProfileStore.activeProfile().wallpaper.apiBaseURL, path: template)
    }

    /// 构建缩略图 URL
    static func thumbURL(from thumbs: Wallpaper.Thumbs, size: ThumbSize = .large) -> URL? {
        switch size {
        case .small:
            return URL(string: thumbs.small)
        case .original:
            return URL(string: thumbs.original)
        case .large:
            return URL(string: thumbs.large)
        }
    }

    enum ThumbSize {
        case small
        case original
        case large
    }

    private static func makeURL(baseURL: String, path: String) -> URL? {
        if let absolute = URL(string: path), absolute.scheme != nil {
            return absolute
        }

        guard let base = URL(string: baseURL) else {
            return nil
        }
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let relativePath = trimmedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        if relativePath.isEmpty {
            return base
        }

        if let components = URLComponents(string: trimmedPath),
           let query = components.query {
            let pathOnly = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let joinedBase = base.absoluteString.hasSuffix("/") ? base.absoluteString : base.absoluteString + "/"
            return URL(string: joinedBase + pathOnly + "?" + query)
        }

        let joinedBase = base.absoluteString.hasSuffix("/") ? base.absoluteString : base.absoluteString + "/"
        return URL(string: joinedBase + relativePath)
    }
}

extension WallhavenAPI.Endpoint: CustomStringConvertible {
    var description: String {
        switch self {
        case .search(let parameters):
            return "search(q=\(parameters.query), page=\(parameters.page))"
        case .wallpaper(let id):
            return "wallpaper(id=\(id))"
        }
    }
}
