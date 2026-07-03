import Foundation

// MARK: - Pixiv 数据模型
// 基于实际 HTTP 请求验证的 JSON 结构

/// Pixiv 内容类型（细粒度分级）
struct PixivContentType: Decodable, Hashable {
    let sexual: Int
    let lo: Bool
    let grotesque: Bool
    let violent: Bool
    let homosexual: Bool
    let drug: Bool
    let thoughts: Bool
    let antisocial: Bool
    let religion: Bool
    let original: Bool
    let furry: Bool
    let bl: Bool
    let yuri: Bool

    /// 内容分级系统（3 级）
    /// Pixiv 分级：sexual 0=无, 1=轻度(擦边/Sketchy), 2=露骨(R18/NSFW)
    /// lo=R18标记, grotesque=R18G, violent=暴力
    
    /// 是否为 NSFW 内容（露骨色情）
    var isNSFW: Bool {
        sexual >= 2 || lo || grotesque || violent
    }
    
    /// 是否为 Sketchy 内容（轻度擦边/suggestive）
    var isSketchy: Bool {
        sexual == 1 && !isNSFW
    }
    
    /// 是否为 SFW 内容（完全安全）
    var isSFW: Bool {
        sexual == 0 && !isNSFW
    }
    
    /// 映射为 Wallhaven 风格的 purity 字符串
    var purityString: String {
        if isNSFW { return "nsfw" }
        if isSketchy { return "sketchy" }
        return "sfw"
    }
    
    /// 默认安全内容类型
    static let defaultSFW = PixivContentType(
        sexual: 0, lo: false, grotesque: false, violent: false,
        homosexual: false, drug: false, thoughts: false,
        antisocial: false, religion: false, original: false,
        furry: false, bl: false, yuri: false
    )
}

/// 排行榜响应（ranking.php?format=json）
struct PixivRankingResponse: Decodable {
    let contents: [PixivRankingItem]
    let mode: String
    let content: String
    let page: Int
    let prev: PixivIntOrBool?
    let next: PixivIntOrBool?
    let date: String
    let prevDate: PixivDateOrBool?
    let nextDate: PixivDateOrBool?
    let rankTotal: Int

    enum CodingKeys: String, CodingKey {
        case contents, mode, content, page, prev, next, date
        case prevDate = "prev_date"
        case nextDate = "next_date"
        case rankTotal = "rank_total"
    }
}

/// 整数或布尔值（prev/next 字段可以是 Int 或 false）
enum PixivIntOrBool: Decodable {
    case int(Int)
    case boolFalse

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intValue = try? container.decode(Int.self) {
            self = .int(intValue)
        } else {
            self = .boolFalse
        }
    }
}

/// 日期或布尔值（next_date/prev_date 可能是日期字符串或 false）
enum PixivDateOrBool: Decodable {
    case date(String)
    case boolFalse

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let dateString = try? container.decode(String.self) {
            self = .date(dateString)
        } else {
            self = .boolFalse
        }
    }
}

/// 排行榜项
struct PixivRankingItem: Decodable {
    let illustId: Int
    let title: String
    let date: String
    let tags: [String]
    let url: String
    let illustType: Int
    let illustBookStyle: Int
    let illustPageCount: Int
    let userName: String
    let profileImg: String
    let illustContentType: PixivContentType
    let illustSeries: Bool
    let width: Int
    let height: Int
    let userId: Int
    let rank: Int
    let yesRank: Int
    let ratingCount: Int
    let viewCount: Int
    let illustUploadTimestamp: Int
    let attr: String
    let isMasked: Bool

    enum CodingKeys: String, CodingKey {
        case illustId = "illust_id"
        case title, date, tags, url
        case illustType = "illust_type"
        case illustBookStyle = "illust_book_style"
        case illustPageCount = "illust_page_count"
        case userName = "user_name"
        case profileImg = "profile_img"
        case illustContentType = "illust_content_type"
        case illustSeries = "illust_series"
        case width, height
        case userId = "user_id"
        case rank
        case yesRank = "yes_rank"
        case ratingCount = "rating_count"
        case viewCount = "view_count"
        case illustUploadTimestamp = "illust_upload_timestamp"
        case attr
        case isMasked = "is_masked"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        illustId = try container.decode(Int.self, forKey: .illustId)
        title = try container.decode(String.self, forKey: .title)
        date = try container.decode(String.self, forKey: .date)
        tags = try container.decode([String].self, forKey: .tags)
        url = try container.decode(String.self, forKey: .url)
        // Pixiv API 返回字符串形式的整数（"0" / "1"）
        illustType = try Self.decodeIntOrString(container, forKey: .illustType)
        illustBookStyle = try Self.decodeIntOrString(container, forKey: .illustBookStyle)
        illustPageCount = try Self.decodeIntOrString(container, forKey: .illustPageCount)
        userName = try container.decode(String.self, forKey: .userName)
        profileImg = try container.decode(String.self, forKey: .profileImg)
        // illust_content_type 可能是数组或字典（API 行为不稳定，两者都兼容）
        if let contentTypes = try? container.decodeIfPresent([PixivContentType].self, forKey: .illustContentType) {
            illustContentType = contentTypes.first ?? PixivContentType.defaultSFW
        } else if let contentType = try? container.decodeIfPresent(PixivContentType.self, forKey: .illustContentType) {
            illustContentType = contentType
        } else {
            illustContentType = PixivContentType.defaultSFW
        }
        illustSeries = try container.decode(Bool.self, forKey: .illustSeries)
        width = try container.decode(Int.self, forKey: .width)
        height = try container.decode(Int.self, forKey: .height)
        userId = try container.decode(Int.self, forKey: .userId)
        rank = try container.decode(Int.self, forKey: .rank)
        yesRank = try container.decode(Int.self, forKey: .yesRank)
        ratingCount = try container.decode(Int.self, forKey: .ratingCount)
        viewCount = try container.decode(Int.self, forKey: .viewCount)
        illustUploadTimestamp = try container.decode(Int.self, forKey: .illustUploadTimestamp)
        attr = try container.decode(String.self, forKey: .attr)
        isMasked = try container.decode(Bool.self, forKey: .isMasked)
    }

    private static func decodeIntOrString(_ container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) throws -> Int {
        if let intValue = try? container.decode(Int.self, forKey: key) {
            return intValue
        }
        let stringValue = try container.decode(String.self, forKey: key)
        guard let intValue = Int(stringValue) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "Expected int or string-int, got '\(stringValue)'")
        }
        return intValue
    }
}

/// 作品详情响应（/ajax/illust/{id}）
struct PixivIllustDetailResponse: Decodable {
    let error: Bool
    let message: String
    let body: PixivIllustDetailBody
}

struct PixivIllustDetailBody: Decodable {
    let illustId: String
    let illustTitle: String
    let illustComment: String
    let description: String
    let illustType: Int
    let createDate: String
    let uploadDate: String
    let restrict: Int
    let xRestrict: Int
    let sl: Int
    let urls: PixivIllustURLs
    let tags: PixivTagContainer
    let userId: String
    let userName: String
    let userAccount: String
    let width: Int
    let height: Int
    let pageCount: Int
    let bookmarkCount: Int
    let likeCount: Int
    let viewCount: Int
    let commentCount: Int
    let aiType: Int
    let seriesNavData: PixivSeriesNavData?
}

struct PixivIllustURLs: Decodable {
    let mini: String
    let thumb: String
    let small: String
    let regular: String
    let original: String
}

struct PixivTagContainer: Decodable {
    let authorId: String
    let isLocked: Bool
    let tags: [PixivTagItem]

    enum CodingKeys: String, CodingKey {
        case authorId = "authorId"
        case isLocked = "isLocked"
        case tags = "tags"
    }
}

struct PixivTagItem: Decodable {
    let tag: String
    let locked: Bool
    let deletable: Bool
    let userId: String?
    let userName: String?
}

struct PixivSeriesNavData: Decodable {
    let seriesId: String?
    let title: String?
    let order: Int?
}

/// 搜索响应（/ajax/search/artworks/{word}）
struct PixivSearchResponse: Decodable {
    let error: Bool
    let body: PixivSearchBody
}

struct PixivSearchBody: Decodable {
    let illustManga: PixivSearchResultBlock
    let relatedTags: [String]?
}

struct PixivSearchResultBlock: Decodable {
    let data: [PixivSearchItem]
    let total: Int
    let lastPage: Int
    let bookmarkRanges: [PixivBookmarkRange]?
}

struct PixivSearchItem: Decodable {
    let id: String
    let title: String
    let illustType: Int
    let xRestrict: Int
    let restrict: Int
    let sl: Int
    let url: String
    let tags: [String]
    let userId: String
    let userName: String
    let width: Int
    let height: Int
    let pageCount: Int
    let isBookmarkable: Bool
    let aiType: Int
    let profileImageUrl: String
    let isOriginal: Bool
    let createDate: String
    let isMasked: Bool
    let alt: String

    enum CodingKeys: String, CodingKey {
        case id, title
        case illustType = "illustType"
        case xRestrict = "xRestrict"
        case restrict = "restrict"
        case sl = "sl"
        case url = "url"
        case tags = "tags"
        case userId = "userId"
        case userName = "userName"
        case width, height
        case pageCount = "pageCount"
        case isBookmarkable = "isBookmarkable"
        case aiType = "aiType"
        case profileImageUrl = "profileImageUrl"
        case isOriginal = "isOriginal"
        case createDate = "createDate"
        case isMasked = "isMasked"
        case alt = "alt"
    }
    
    // 提供灵活的初始化器，处理 API 可能缺失的字段
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        illustType = try container.decode(Int.self, forKey: .illustType)
        xRestrict = try container.decodeIfPresent(Int.self, forKey: .xRestrict) ?? 0
        restrict = try container.decodeIfPresent(Int.self, forKey: .restrict) ?? 0
        sl = try container.decodeIfPresent(Int.self, forKey: .sl) ?? 0
        url = try container.decode(String.self, forKey: .url)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        userId = try container.decode(String.self, forKey: .userId)
        userName = try container.decode(String.self, forKey: .userName)
        width = try container.decodeIfPresent(Int.self, forKey: .width) ?? 0
        height = try container.decodeIfPresent(Int.self, forKey: .height) ?? 0
        pageCount = try container.decodeIfPresent(Int.self, forKey: .pageCount) ?? 1
        isBookmarkable = try container.decodeIfPresent(Bool.self, forKey: .isBookmarkable) ?? true
        aiType = try container.decodeIfPresent(Int.self, forKey: .aiType) ?? 0
        profileImageUrl = try container.decodeIfPresent(String.self, forKey: .profileImageUrl) ?? ""
        isOriginal = try container.decodeIfPresent(Bool.self, forKey: .isOriginal) ?? false
        createDate = try container.decodeIfPresent(String.self, forKey: .createDate) ?? ""
        isMasked = try container.decodeIfPresent(Bool.self, forKey: .isMasked) ?? false
        alt = try container.decodeIfPresent(String.self, forKey: .alt) ?? ""
    }
}

struct PixivBookmarkRange: Decodable {
    let min: Int?
    let max: Int?
}

/// 关联作品响应（/ajax/illust/{id}/recommend/init）
struct PixivRelatedResponse: Decodable {
    let error: Bool
    let body: PixivRelatedBody
}

struct PixivRelatedBody: Decodable {
    let illusts: [PixivSearchItem]
}

/// 用户作品响应（/ajax/user/{id}/profile/all）
struct PixivUserProfileResponse: Decodable {
    let error: Bool
    let body: PixivUserProfileBody
}

struct PixivUserProfileBody: Decodable {
    let illusts: [String: PixivUserIllustMeta?]?
    let manga: [String: PixivUserIllustMeta?]?
}

struct PixivUserIllustMeta: Decodable {
    let id: String
}

// MARK: - Pixiv → Wallpaper 转换扩展

extension PixivRankingItem {
    /// 转换为标准 Wallpaper 模型
    /// 注意：path/thumbs 使用预览图 URL（i.pximg.net），下载时会通过 illustDetail 解析原图。
    func toWallpaper() -> Wallpaper {
        let resolution = "\(width)x\(height)"
        let ratio = Self.calculateAspectRatio(width: width, height: height)

        return Wallpaper(
            id: "pixiv_\(illustId)",
            url: "https://www.pixiv.net/artworks/\(illustId)",
            shortUrl: nil,
            views: viewCount,
            favorites: ratingCount,
            downloads: nil,
            source: "pixiv",
            purity: illustContentType.purityString,
            category: illustType == 1 ? "anime" : "general",
            dimensionX: width,
            dimensionY: height,
            resolution: resolution,
            ratio: ratio,
            fileSize: nil,
            fileType: "image/jpeg",
            createdAt: nil,
            colors: [],
            path: url,
            thumbs: Wallpaper.Thumbs(
                large: url,
                original: url,
                small: url
            ),
            tags: tags.map { Wallpaper.Tag(id: 0, name: $0, alias: nil) },
            uploader: nil
        )
    }

    private static func calculateAspectRatio(width: Int, height: Int) -> String {
        guard width > 0, height > 0 else { return "16:9" }
        let gcd = Self.gcd(width, height)
        return "\(width / gcd):\(height / gcd)"
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        return b == 0 ? a : gcd(b, a % b)
    }
}

extension PixivSearchItem {
    /// 转换为标准 Wallpaper 模型
    func toWallpaper() -> Wallpaper {
        let resolution = "\(width)x\(height)"
        let ratio = Self.calculateAspectRatio(width: width, height: height)
        
        // xRestrict: 0=SFW, 1=R18(NSFW)
        // 注意：搜索 API 不返回详细的 sexual 分级，只能区分 SFW/NSFW
        let purity = xRestrict > 0 ? "nsfw" : "sfw"

        return Wallpaper(
            id: "pixiv_\(id)",
            url: "https://www.pixiv.net/artworks/\(id)",
            shortUrl: nil,
            views: 0,
            favorites: 0,
            downloads: nil,
            source: "pixiv",
            purity: purity,
            category: illustType == 1 ? "anime" : "general",
            dimensionX: width,
            dimensionY: height,
            resolution: resolution,
            ratio: ratio,
            fileSize: nil,
            fileType: "image/jpeg",
            createdAt: createDate,
            colors: [],
            path: url,
            thumbs: Wallpaper.Thumbs(
                large: url,
                original: url,
                small: url
            ),
            tags: tags.map { Wallpaper.Tag(id: 0, name: $0, alias: nil) },
            uploader: nil
        )
    }

    private static func calculateAspectRatio(width: Int, height: Int) -> String {
        guard width > 0, height > 0 else { return "16:9" }
        let gcd = Self.gcd(width, height)
        return "\(width / gcd):\(height / gcd)"
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        return b == 0 ? a : gcd(b, a % b)
    }
}

extension PixivIllustDetailBody {
    /// 转换为标准 Wallpaper 模型
    func toWallpaper() -> Wallpaper {
        let resolution = "\(width)x\(height)"
        let ratio = Self.calculateAspectRatio(width: width, height: height)
        
        // xRestrict: 0=SFW, 1=R18(NSFW)
        // 注意：详情 API 不返回详细的 sexual 分级，只能区分 SFW/NSFW
        let purity = xRestrict > 0 ? "nsfw" : "sfw"

        return Wallpaper(
            id: "pixiv_\(illustId)",
            url: "https://www.pixiv.net/artworks/\(illustId)",
            shortUrl: nil,
            views: viewCount,
            favorites: bookmarkCount,
            downloads: nil,
            source: "pixiv",
            purity: purity,
            category: illustType == 1 ? "anime" : "general",
            dimensionX: width,
            dimensionY: height,
            resolution: resolution,
            ratio: ratio,
            fileSize: nil,
            fileType: "image/jpeg",
            createdAt: createDate,
            colors: [],
            path: urls.regular,
            thumbs: Wallpaper.Thumbs(
                large: urls.regular,
                original: urls.original,
                small: urls.thumb
            ),
            tags: tags.tags.map { Wallpaper.Tag(id: 0, name: $0.tag, alias: nil) },
            uploader: nil
        )
    }

    private static func calculateAspectRatio(width: Int, height: Int) -> String {
        guard width > 0, height > 0 else { return "16:9" }
        let gcd = Self.gcd(width, height)
        return "\(width / gcd):\(height / gcd)"
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        return b == 0 ? a : gcd(b, a % b)
    }
}

// MARK: - Pixiv 排行模式

/// Pixiv 排行榜模式（用于排序菜单）
enum PixivRankingMode: String, CaseIterable, Sendable {
    case daily = "daily"
    case weekly = "weekly"
    case monthly = "monthly"
    case rookie = "rookie"
    case original = "original"
    case male = "male"
    case female = "female"

    /// 显示名称
    var displayName: String {
        switch self {
        case .daily: return "日榜"
        case .weekly: return "周榜"
        case .monthly: return "月榜"
        case .rookie: return "新人"
        case .original: return "原创"
        case .male: return "男性人気"
        case .female: return "女性人気"
        }
    }
}

// MARK: - Pixiv 作品类型筛选

/// Pixiv 作品类型（检索/排行时使用）
public enum PixivWorkType: String, CaseIterable, Sendable {
    case all = "illust_and_ugoira"
    case illust = "illust"
    case manga = "manga"
    case ugoira = "ugoira"

    var displayName: String {
        switch self {
        case .all: return "全部"
        case .illust: return "插画"
        case .manga: return "漫画"
        case .ugoira: return "动图"
        }
    }

    /// SF Symbols 图标
    var icon: String {
        switch self {
        case .all: return "sparkles"
        case .illust: return "photo.artframe"
        case .manga: return "book"
        case .ugoira: return "play.rectangle"
        }
    }

    /// 渐变色（HEX）
    var accentColors: [String] {
        switch self {
        case .all: return ["FF6B35", "F7931E"]     // 橙色
        case .illust: return ["00B4D8", "0077B6"]   // 蓝色
        case .manga: return ["E63946", "D62828"]    // 红色
        case .ugoira: return ["9B5DE5", "7B2CBF"]   // 紫色
        }
    }
}

// MARK: - Pixiv 搜索排序

/// Pixiv 搜索时的排序方式
enum PixivSearchSort: String, CaseIterable, Sendable {
    case dateD = "date_d"
    case popularD = "popular_d"
    case popularWeekD = "popular_week_d"
    case popularMonthD = "popular_month_d"

    var displayName: String {
        switch self {
        case .dateD: return "最新"
        case .popularD: return "日人气"
        case .popularWeekD: return "周人气"
        case .popularMonthD: return "月人气"
        }
    }
}

// MARK: - Pixiv 热门标签

/// Pixiv 热门标签（从排行榜数据中提取）
struct PixivHotTag: Identifiable, Hashable {
    let name: String
    let count: Int
    
    var id: String { name }
}
