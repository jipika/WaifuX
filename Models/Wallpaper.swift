import Foundation

struct Wallpaper: Identifiable, Codable, Hashable {
    let id: String
    var url: String
    let shortUrl: String?
    let views: Int
    let favorites: Int
    // downloads 字段仅在壁纸详情接口返回，搜索接口不返回
    let downloads: Int?
    let source: String?
    let purity: String
    let category: String
    let dimensionX: Int
    let dimensionY: Int
    let resolution: String
    let ratio: String
    let fileSize: Int?
    let fileType: String?
    let createdAt: String?
    let colors: [String]
    var path: String
    var thumbs: Thumbs
    let tags: [Tag]?
    let uploader: Uploader?

    var fullURL: URL? { URL(string: url) }
    var thumbURL: URL? { Self.normalizedImageURL(from: thumbs.large) }
    var originalThumbURL: URL? { Self.normalizedImageURL(from: thumbs.original) }
    var smallThumbURL: URL? { Self.normalizedImageURL(from: thumbs.small) }

    /// 探索网格封面候选：缩略图失败时继续尝试原图/路径，避免部分源返回 404 后直接空白。
    var gridPreviewURLs: [URL] {
        Self.deduplicatedURLs([
            thumbURL,
            originalThumbURL,
            smallThumbURL,
            Self.normalizedImageURL(from: path),
            fullImageURL
        ])
    }

    var gridPreviewURL: URL? {
        gridPreviewURLs.first
    }
    var fileExtension: String {
        let pathExtension = (path as NSString).pathExtension.lowercased()
        if !pathExtension.isEmpty {
            return pathExtension
        }

        switch fileType?.lowercased() {
        case "image/png":
            return "png"
        case "image/webp":
            return "webp"
        default:
            return "jpg"
        }
    }
    var aspectRatioValue: Double? {
        if let parsed = Double(ratio), parsed > 0 {
            return parsed
        }

        if let parsed = Self.parseAspectRatioLabel(ratio), parsed > 0 {
            return parsed
        }

        if dimensionX > 100, dimensionY > 100 {
            return Double(dimensionX) / Double(dimensionY)
        }

        if let dimensions = Self.parseDimensions(from: resolution) {
            return Double(dimensions.width) / Double(dimensions.height)
        }

        if let dimensions = inferredOriginalDimensions {
            return Double(dimensions.width) / Double(dimensions.height)
        }

        if dimensionX > 0, dimensionY > 0 {
            return Double(dimensionX) / Double(dimensionY)
        }

        return nil
    }

    var effectiveDimensions: (width: Int, height: Int) {
        if dimensionX > 100, dimensionY > 100 {
            return (dimensionX, dimensionY)
        }

        if let dimensions = Self.parseDimensions(from: resolution) {
            return dimensions
        }

        if let dimensions = inferredOriginalDimensions {
            return dimensions
        }

        if dimensionX > 0, dimensionY > 0 {
            return (dimensionX, dimensionY)
        }

        return (1920, 1080)
    }

    var effectiveAspectRatioValue: Double {
        if let aspectRatioValue, aspectRatioValue > 0 {
            return aspectRatioValue
        }

        let dimensions = effectiveDimensions
        return Double(dimensions.width) / Double(max(1, dimensions.height))
    }

    var effectiveResolutionLabel: String {
        let trimmed = resolution.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.parseDimensions(from: trimmed) != nil {
            return trimmed
        }

        let dimensions = effectiveDimensions
        return "\(dimensions.width)x\(dimensions.height)"
    }

    var fullImageURL: URL? {
        // 本地文件：path 是 file:// URL
        if id.hasPrefix("local_"), let pathURL = Self.normalizedImageURL(from: path) {
            return pathURL
        }
        // 网络文件：path 是 http(s) URL
        if let pathURL = Self.normalizedImageURL(from: path), ["http", "https"].contains(pathURL.scheme?.lowercased() ?? "") {
            return pathURL
        }
        return WallhavenAPI.imageURL(wallpaperId: id, ext: fileExtension)
    }

    var categoryDisplayName: String {
        switch category.lowercased() {
        case "general":
            return t("general")
        case "anime":
            return t("anime")
        case "people":
            return t("people")
        default:
            return category.capitalized
        }
    }

    var purityDisplayName: String {
        switch purity.lowercased() {
        case "sfw":
            return "SFW"
        case "sketchy":
            return "Sketchy"
        case "nsfw":
            return "NSFW"
        default:
            return purity.uppercased()
        }
    }

    var purityDetailLabel: String {
        switch purity.lowercased() {
        case "sfw":
            return t("purity.sfw.detail")
        case "sketchy":
            return t("purity.sketchy.detail")
        case "nsfw":
            return t("purity.nsfw.detail")
        default:
            return purity.uppercased()
        }
    }

    var fileSizeLabel: String {
        guard let size = fileSize else { return "" }
        let kb = Double(size) / 1024
        if kb >= 1024 {
            return String(format: "%.1f MB", kb / 1024)
        }
        return String(format: "%.0f KB", kb)
    }

    var normalizedColorHexes: [String] {
        colors.map { $0.replacingOccurrences(of: "#", with: "").uppercased() }
    }

    var primaryColorHex: String? {
        normalizedColorHexes.first
    }

    var primaryTagName: String? {
        tags?
            .lazy
            .map(\.name)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty && $0.lowercased() != "wallpaper" })
    }

    func matchesAspectRatio(_ identifier: String, tolerance: Double = 0.03) -> Bool {
        guard
            let currentRatio = aspectRatioValue,
            let targetRatio = Self.aspectRatioTargets[identifier]
        else {
            return false
        }

        return abs(currentRatio - targetRatio) <= tolerance
    }

    enum CodingKeys: String, CodingKey {
        case id, url
        case shortUrl = "short_url"
        case views, favorites, downloads, source, purity, category
        case dimensionX = "dimension_x"
        case dimensionY = "dimension_y"
        case resolution, ratio
        case fileSize = "file_size"
        case fileType = "file_type"
        case createdAt = "created_at"
        case colors, path, thumbs, tags, uploader
    }

    struct Thumbs: Codable, Hashable {
        var large: String
        var original: String
        var small: String
    }

    struct Uploader: Codable, Hashable {
        let username: String
        let group: String
        let avatar: Avatar
    }

    struct Avatar: Codable, Hashable {
        let px200: String
        let px128: String
        let px32: String
        let px20: String

        enum CodingKeys: String, CodingKey {
            case px200 = "200px"
            case px128 = "128px"
            case px32 = "32px"
            case px20 = "20px"
        }
    }

    struct Tag: Codable, Hashable {
        let id: Int
        let name: String
        let alias: String?

        enum CodingKeys: String, CodingKey {
            case id, name, alias
        }
    }

    private static let aspectRatioTargets: [String: Double] = [
        "1x1": 1.0,
        "4x3": 4.0 / 3.0,
        "3x2": 3.0 / 2.0,
        "16x10": 16.0 / 10.0,
        "16x9": 16.0 / 9.0,
        "21x9": 21.0 / 9.0,
        "32x9": 32.0 / 9.0,
        "9x16": 9.0 / 16.0,
        "10x16": 10.0 / 16.0
    ]

    private var inferredOriginalDimensions: (width: Int, height: Int)? {
        for value in [thumbs.original, path, thumbs.large, thumbs.small, url] {
            if let dimensions = Self.parseDimensions(from: value) {
                return dimensions
            }
        }
        return nil
    }

    private static func normalizedImageURL(from value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("//") {
            return URL(string: "https:" + trimmed)
        }

        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed)
        }

        guard let parsed = URL(string: trimmed),
              let scheme = parsed.scheme?.lowercased(),
              ["http", "https", "file"].contains(scheme) else {
            return nil
        }

        return parsed
    }

    private static func deduplicatedURLs(_ urls: [URL?]) -> [URL] {
        var seen: Set<String> = []
        var result: [URL] = []

        for url in urls.compactMap({ $0 }) {
            let key = url.absoluteString
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(url)
        }

        return result
    }

    private static func parseDimensions(from value: String) -> (width: Int, height: Int)? {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "%C3%97", with: "x", options: .caseInsensitive)
            .replacingOccurrences(of: "×", with: "x")
        guard !normalized.isEmpty else { return nil }

        let pattern = #"(?<!\d)(\d{3,5})\s*[xX]\s*(\d{3,5})(?!\d)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        guard let match = regex.firstMatch(in: normalized, range: nsRange),
              match.numberOfRanges >= 3,
              let widthRange = Range(match.range(at: 1), in: normalized),
              let heightRange = Range(match.range(at: 2), in: normalized),
              let width = Int(normalized[widthRange]),
              let height = Int(normalized[heightRange]),
              width > 0,
              height > 0 else {
            return nil
        }

        return (width, height)
    }

    private static func parseAspectRatioLabel(_ value: String) -> Double? {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "：", with: ":")
        guard !normalized.isEmpty else { return nil }

        let parts = normalized.split(separator: ":").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
        return parts[0] / parts[1]
    }
}

struct WallpaperSearchResponse: Codable {
    let meta: Meta
    let data: [Wallpaper]

    struct Meta: Codable {
        let query: String?
        let currentPage: Int
        let perPage: StringOrInt  // API 有时返回字符串有时返回整数
        let total: Int
        let lastPage: Int
        let seed: String?

        enum CodingKeys: String, CodingKey {
            case query
            case currentPage = "current_page"
            case perPage = "per_page"
            case total
            case lastPage = "last_page"
            case seed
        }
    }
}

// 支持字符串或整数
enum StringOrInt: Codable {
    case string(String)
    case int(Int)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intValue = try? container.decode(Int.self) {
            self = .int(intValue)
        } else if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
        } else {
            throw DecodingError.typeMismatch(StringOrInt.self, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected String or Int"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        }
    }
}

struct WallpaperDetailResponse: Codable {
    let data: Wallpaper
}

// MARK: - 标签响应 (用于标签详情接口)
struct TagResponse: Codable {
    let data: APITag
}

// MARK: - API 标签
struct APITag: Codable, Identifiable {
    let id: Int
    let name: String
    let alias: String?
    let categoryId: Int?
    let category: String?
    let purity: String?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, name, alias
        case categoryId = "category_id"
        case category, purity
        case createdAt = "created_at"
    }
}

struct WallhavenUserSettingsResponse: Codable {
    let data: WallhavenUserSettings
}

struct WallhavenUserSettings: Codable {
    let thumbSize: String
    let perPage: String
    let purity: [String]
    let categories: [String]
    let resolutions: [String]
    let aspectRatios: [String]
    let toplistRange: String
    let tagBlacklist: [String]
    let userBlacklist: [String]

    enum CodingKeys: String, CodingKey {
        case thumbSize = "thumb_size"
        case perPage = "per_page"
        case purity, categories, resolutions
        case aspectRatios = "aspect_ratios"
        case toplistRange = "toplist_range"
        case tagBlacklist = "tag_blacklist"
        case userBlacklist = "user_blacklist"
    }
}

struct WallhavenCollectionsResponse: Codable {
    let data: [WallhavenCollection]
}

struct WallhavenCollection: Codable, Identifiable, Hashable {
    let id: Int
    let label: String
    let views: Int
    let `public`: Int
    let count: Int
}

struct WallpaperFavoriteRecord: Identifiable, Codable, Hashable {
    let id: String
    var wallpaper: Wallpaper
    var metadata: SyncMetadata
    var folderID: String?

    init(wallpaper: Wallpaper, metadata: SyncMetadata? = nil, folderID: String? = nil) {
        self.id = wallpaper.id
        self.wallpaper = wallpaper
        self.metadata = metadata ?? SyncMetadata(
            recordID: "wallpaper.favorite.\(wallpaper.id)",
            entityType: "wallpaper.favorite"
        )
        self.folderID = folderID
    }

    var isActive: Bool {
        !metadata.isDeleted
    }

    enum CodingKeys: String, CodingKey {
        case id, wallpaper, metadata, folderID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        wallpaper = try container.decode(Wallpaper.self, forKey: .wallpaper)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? wallpaper.id
        metadata = try container.decodeIfPresent(SyncMetadata.self, forKey: .metadata)
            ?? SyncMetadata(recordID: "wallpaper.favorite.\(wallpaper.id)", entityType: "wallpaper.favorite")
        folderID = try container.decodeIfPresent(String.self, forKey: .folderID)
    }
}

struct WallpaperDownloadRecord: Identifiable, Codable, Hashable {
    let id: String
    var wallpaper: Wallpaper
    var localFilePath: String
    var downloadedAt: Date
    var metadata: SyncMetadata
    var folderID: String?
    /// 是否已完成 crossfade 循环预处理（替换原始文件后标记为 true）
    var isLooped: Bool?

    init(
        wallpaper: Wallpaper,
        localFilePath: String,
        downloadedAt: Date = .now,
        metadata: SyncMetadata? = nil,
        folderID: String? = nil,
        isLooped: Bool? = nil
    ) {
        self.id = wallpaper.id
        self.wallpaper = wallpaper
        self.localFilePath = localFilePath
        self.downloadedAt = downloadedAt
        self.metadata = metadata ?? SyncMetadata(
            recordID: "wallpaper.download.\(wallpaper.id)",
            entityType: "wallpaper.download"
        )
        self.folderID = folderID
        self.isLooped = isLooped
    }

    var localFileURL: URL {
        URL(fileURLWithPath: localFilePath)
    }

    var isActive: Bool {
        !metadata.isDeleted
    }

    enum CodingKeys: String, CodingKey {
        case id, wallpaper, localFilePath, downloadedAt, metadata, folderID, isLooped
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        wallpaper = try container.decode(Wallpaper.self, forKey: .wallpaper)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? wallpaper.id
        localFilePath = try container.decode(String.self, forKey: .localFilePath)
        downloadedAt = try container.decodeIfPresent(Date.self, forKey: .downloadedAt) ?? .now
        metadata = try container.decodeIfPresent(SyncMetadata.self, forKey: .metadata)
            ?? SyncMetadata(recordID: "wallpaper.download.\(wallpaper.id)", entityType: "wallpaper.download")
        folderID = try container.decodeIfPresent(String.self, forKey: .folderID)
        isLooped = try container.decodeIfPresent(Bool.self, forKey: .isLooped)
    }
}
