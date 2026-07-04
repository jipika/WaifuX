import Foundation

// MARK: - Konachan Post (JSON: post.json)

/// Konachan 帖子 API 响应模型
/// 端点: GET https://konachan.com/post.json
struct KonachanPost: Decodable, Sendable {
    let id: Int
    let tags: String
    let createdAt: Int?
    let updatedAt: Int?
    let creatorId: Int?
    let author: String?
    let source: String?
    let score: Int?
    let md5: String?
    let fileSize: Int?
    let fileURL: String?
    let fileExt: String?
    let width: Int
    let height: Int
    let sampleURL: String?
    let sampleWidth: Int?
    let sampleHeight: Int?
    let previewURL: String?
    let previewWidth: Int?
    let previewHeight: Int?
    let jpegURL: String?
    let jpegWidth: Int?
    let jpegHeight: Int?
    let rating: String
    let status: String?
    let hasChildren: Bool?
    let parentId: Int?

    enum CodingKeys: String, CodingKey {
        case id, tags, author, source, score, md5, width, height, rating, status
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case creatorId = "creator_id"
        case fileSize = "file_size"
        case fileURL = "file_url"
        case fileExt = "file_ext"
        case sampleURL = "sample_url"
        case sampleWidth = "sample_width"
        case sampleHeight = "sample_height"
        case previewURL = "preview_url"
        case previewWidth = "preview_width"
        case previewHeight = "preview_height"
        case jpegURL = "jpeg_url"
        case jpegWidth = "jpeg_width"
        case jpegHeight = "jpeg_height"
        case hasChildren = "has_children"
        case parentId = "parent_id"
    }
}

// MARK: - Konachan Tag (JSON: tag.json)

/// Konachan 标签 API 响应模型
/// 端点: GET https://konachan.com/tag.json
struct KonachanTag: Decodable, Sendable, Identifiable {
    let id: Int
    let name: String
    let count: Int
    let type: Int?
    let ambiguous: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name, count, type, ambiguous
    }
}

// MARK: - Konachan Purity Selection

/// Konachan 内容分级选择
struct KonachanPuritySelection: OptionSet, Sendable {
    let rawValue: Int

    static let safe = KonachanPuritySelection(rawValue: 1 << 0)      // rating:s
    static let questionable = KonachanPuritySelection(rawValue: 1 << 1) // rating:q
    static let explicit = KonachanPuritySelection(rawValue: 1 << 2)   // rating:e

    static let all: KonachanPuritySelection = [.safe, .questionable, .explicit]
    static let safeOnly: KonachanPuritySelection = [.safe]

    /// 转换为请求 tags 中的 rating 筛选标签数组
    var ratingTags: [String] {
        var tags: [String] = []
        if contains(.safe) { tags.append("rating:s") }
        if contains(.questionable) { tags.append("rating:q") }
        if contains(.explicit) { tags.append("rating:e") }
        return tags
    }
}

// MARK: - Konachan Sorting

/// Konachan 排序选项（通过 order: 元标签实现）
enum KonachanSorting: String, CaseIterable, Sendable {
    case dateAdded = "id"          // 默认按 ID（新旧）
    case score = "score"           // 高分排序
    case tagcount = "tagcount" // 标签数排序
    case landscape = "landscape"   // 横屏优先
    case portrait = "portrait"     // 竖屏优先
    case random = "random"         // 随机
    case mpixels = "mpixels"       // 分辨率优先

    /// 对应的 order: 元标签值
    var orderTag: String {
        "order:\(rawValue)"
    }

    /// 是否需要在 tags 中追加
    var requiresOrderTag: Bool {
        switch self {
        case .dateAdded:
            return false  // 默认排序，不需要追加
        default:
            return true
        }
    }
}

// MARK: - Wallpaper 模型映射

extension KonachanPost {
    /// 将 KonachanPost 映射为 Wallpaper 模型
    func toWallpaper() -> Wallpaper {
        // 从文件扩展名推断 fileType
        let detectedFileType: String
        switch fileExt?.lowercased() {
        case "png":
            detectedFileType = "image/png"
        case "webp":
            detectedFileType = "image/webp"
        case "gif":
            detectedFileType = "image/gif"
        default:
            detectedFileType = "image/jpeg"
        }

        // 确定图片 URL 优先级: file_url > jpeg_url > sample_url > preview_url
        let imagePath = fileURL ?? jpegURL ?? sampleURL ?? previewURL ?? ""
        let samplePath = sampleURL ?? previewURL ?? ""
        let previewPath = previewURL ?? sampleURL ?? ""

        // 分辨率字符串
        let resolution = "\(width)x\(height)"
        let ratio = height > 0 ? String(format: "%.2f", Double(width) / Double(height)) : "1.78"

        // 时间字符串
        let createdAtString: String?
        if let timestamp = createdAt {
            let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
            let formatter = ISO8601DateFormatter()
            createdAtString = formatter.string(from: date)
        } else {
            createdAtString = nil
        }

        // 标签拆分
        let tagNames = tags
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty }

        let wallpaperTags: [Wallpaper.Tag] = tagNames.enumerated().map { index, name in
            Wallpaper.Tag(id: index, name: name.replacingOccurrences(of: "_", with: " "), alias: nil)
        }

        // 纯度映射
        let purity: String
        switch rating.lowercased() {
        case "s":
            purity = "sfw"
        case "q":
            purity = "sketchy"
        case "e":
            purity = "nsfw"
        default:
            purity = "sfw"
        }

        // URL normalizer 辅助
        func normalizeURL(_ urlString: String?) -> String {
            guard let value = urlString, !value.isEmpty else { return "" }
            if value.hasPrefix("//") {
                return "https:" + value
            }
            return value
        }

        let thumbs = Wallpaper.Thumbs(
            large: normalizeURL(samplePath),
            original: normalizeURL(imagePath),
            small: normalizeURL(previewPath)
        )

        return Wallpaper(
            id: "konachan-\(id)",
            title: nil,
            url: "https://konachan.net/post/show/\(id)",
            shortUrl: nil,
            views: 0,
            favorites: score ?? 0,
            downloads: nil,
            source: source,
            purity: purity,
            category: "anime",
            dimensionX: width,
            dimensionY: height,
            resolution: resolution,
            ratio: ratio,
            fileSize: fileSize,
            fileType: detectedFileType,
            createdAt: createdAtString,
            colors: [],
            path: normalizeURL(imagePath),
            thumbs: thumbs,
            tags: wallpaperTags.isEmpty ? nil : wallpaperTags,
            uploader: nil
        )
    }
}
