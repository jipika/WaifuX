import Foundation

// MARK: - 动漫解析规则 (参考 Kazumi 简化格式)

// 简化规则格式，核心仅需 ~15 行配置
// 支持 CSS Selector 解析

struct AnimeRule: Identifiable, Codable, Hashable {
    let id: String
    let api: String      // Kazumi capability level, independent of selector mode
    let type: String      // "anime"
    let name: String
    let version: String
    let deprecated: Bool

    let searchMode: AnimeRuleMode
    let chapterMode: AnimeRuleMode
    let searchApiConfig: AnimeAPISearch?
    let chapterApiConfig: AnimeAPIChapter?

    // 站点配置
    let baseURL: String
    let headers: [String: String]?
    let userAgent: String?
    let referer: String?  // Kazumi 规则中的 referer 字段
    let timeout: Int?

    // API v1: 简化 CSS Selector 格式
    let searchURL: String
    let searchList: String?
    let searchName: String?
    let searchCover: String?
    let searchDetail: String?
    let searchId: String?

    let detailTitle: String?
    let detailCover: String?
    let detailDesc: String?
    let detailStatus: String?
    let detailRating: String?

    let episodeList: String?
    let episodeName: String?
    let episodeLink: String?
    let episodeThumb: String?

    let videoSelector: String?
    let videoSourceAttr: String?
    let useWebview: Bool?
    let multiSources: Bool?
    /// Kazumi 规则字段：老式播放器站点从 iframe src 的 query 参数提取媒体直链。
    let useLegacyParser: Bool?
    /// Kazumi 规则字段：站点声明需要广告拦截（提取 WebView 的基础拦截始终开启）。
    let adBlocker: Bool?

    // API v2: XPath 格式 (兼容 Kazumi)
    let xpath: AnimeXPathRules?

    // 反爬虫配置 (参考 Kazumi antiCrawlerConfig)
    let antiCrawlerConfig: AntiCrawlerConfig?

    enum CodingKeys: String, CodingKey {
        case id, api, type, name, version, deprecated
        case baseURL, headers, userAgent, referer, timeout
        case searchURL, searchList, searchName, searchCover, searchDetail, searchId
        case detailTitle, detailCover, detailDesc, detailStatus, detailRating
        case episodeList, episodeName, episodeLink, episodeThumb
        case videoSelector, videoSourceAttr, useWebview, multiSources, useLegacyParser, adBlocker
        case xpath
        case antiCrawlerConfig
        case searchMode, chapterMode, searchApiConfig, chapterApiConfig
    }

    // 初始化器支持两种格式
    init(
        id: String,
        api: String = "1",
        type: String = "anime",
        name: String,
        version: String = "1.0.0",
        deprecated: Bool = false,
        baseURL: String,
        headers: [String: String]? = nil,
        userAgent: String? = nil,
        referer: String? = nil,
        timeout: Int? = 30,
        // API v1 字段
        searchURL: String,
        searchList: String? = nil,
        searchName: String? = nil,
        searchCover: String? = nil,
        searchDetail: String? = nil,
        searchId: String? = nil,
        detailTitle: String? = nil,
        detailCover: String? = nil,
        detailDesc: String? = nil,
        detailStatus: String? = nil,
        detailRating: String? = nil,
        episodeList: String? = nil,
        episodeName: String? = nil,
        episodeLink: String? = nil,
        episodeThumb: String? = nil,
        videoSelector: String? = nil,
        videoSourceAttr: String? = "src",
        useWebview: Bool? = false,
        multiSources: Bool? = false,
        useLegacyParser: Bool? = nil,
        adBlocker: Bool? = nil,
        // API v2 字段
        xpath: AnimeXPathRules? = nil,
        antiCrawlerConfig: AntiCrawlerConfig? = nil,
        searchMode: AnimeRuleMode? = nil,
        chapterMode: AnimeRuleMode? = nil,
        searchApiConfig: AnimeAPISearch? = nil,
        chapterApiConfig: AnimeAPIChapter? = nil
    ) {
        self.id = Self.normalizedID(id)
        self.api = api
        self.type = type
        self.name = name
        self.version = version
        self.deprecated = deprecated
        self.baseURL = baseURL
        self.headers = headers
        self.userAgent = userAgent
        self.referer = referer
        self.timeout = timeout
        
        self.searchURL = searchURL
        self.searchList = searchList
        self.searchName = searchName
        self.searchCover = searchCover
        self.searchDetail = searchDetail
        self.searchId = searchId
        
        self.detailTitle = detailTitle
        self.detailCover = detailCover
        self.detailDesc = detailDesc
        self.detailStatus = detailStatus
        self.detailRating = detailRating
        
        self.episodeList = episodeList
        self.episodeName = episodeName
        self.episodeLink = episodeLink
        self.episodeThumb = episodeThumb
        
        self.videoSelector = videoSelector
        self.videoSourceAttr = videoSourceAttr
        self.useWebview = useWebview
        self.multiSources = multiSources
        self.useLegacyParser = useLegacyParser
        self.adBlocker = adBlocker

        self.xpath = xpath
        self.antiCrawlerConfig = antiCrawlerConfig
        self.searchMode = searchMode ?? (xpath?.search == nil ? .css : .xpath)
        self.chapterMode = chapterMode ?? (xpath?.detail == nil ? .css : .xpath)
        self.searchApiConfig = searchApiConfig
        self.chapterApiConfig = chapterApiConfig
    }

    static func normalizedID(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decodeIfPresent(String.self, forKey: .id) ?? "",
            api: try c.decodeIfPresent(String.self, forKey: .api) ?? "1",
            type: try c.decodeIfPresent(String.self, forKey: .type) ?? "anime",
            name: try c.decodeIfPresent(String.self, forKey: .name) ?? "",
            version: try c.decodeIfPresent(String.self, forKey: .version) ?? "1.0",
            deprecated: try c.decodeIfPresent(Bool.self, forKey: .deprecated) ?? false,
            baseURL: try c.decodeIfPresent(String.self, forKey: .baseURL) ?? "",
            headers: try c.decodeIfPresent([String: String].self, forKey: .headers),
            userAgent: try c.decodeIfPresent(String.self, forKey: .userAgent),
            referer: try c.decodeIfPresent(String.self, forKey: .referer),
            timeout: try c.decodeIfPresent(Int.self, forKey: .timeout),
            searchURL: try c.decodeIfPresent(String.self, forKey: .searchURL) ?? "",
            searchList: try c.decodeIfPresent(String.self, forKey: .searchList),
            searchName: try c.decodeIfPresent(String.self, forKey: .searchName),
            searchCover: try c.decodeIfPresent(String.self, forKey: .searchCover),
            searchDetail: try c.decodeIfPresent(String.self, forKey: .searchDetail),
            searchId: try c.decodeIfPresent(String.self, forKey: .searchId),
            detailTitle: try c.decodeIfPresent(String.self, forKey: .detailTitle),
            detailCover: try c.decodeIfPresent(String.self, forKey: .detailCover),
            detailDesc: try c.decodeIfPresent(String.self, forKey: .detailDesc),
            detailStatus: try c.decodeIfPresent(String.self, forKey: .detailStatus),
            detailRating: try c.decodeIfPresent(String.self, forKey: .detailRating),
            episodeList: try c.decodeIfPresent(String.self, forKey: .episodeList),
            episodeName: try c.decodeIfPresent(String.self, forKey: .episodeName),
            episodeLink: try c.decodeIfPresent(String.self, forKey: .episodeLink),
            episodeThumb: try c.decodeIfPresent(String.self, forKey: .episodeThumb),
            videoSelector: try c.decodeIfPresent(String.self, forKey: .videoSelector),
            videoSourceAttr: try c.decodeIfPresent(String.self, forKey: .videoSourceAttr),
            useWebview: try c.decodeIfPresent(Bool.self, forKey: .useWebview),
            multiSources: try c.decodeIfPresent(Bool.self, forKey: .multiSources),
            useLegacyParser: try c.decodeIfPresent(Bool.self, forKey: .useLegacyParser),
            adBlocker: try c.decodeIfPresent(Bool.self, forKey: .adBlocker),
            xpath: try c.decodeIfPresent(AnimeXPathRules.self, forKey: .xpath),
            antiCrawlerConfig: try c.decodeIfPresent(AntiCrawlerConfig.self, forKey: .antiCrawlerConfig),
            searchMode: try c.decodeIfPresent(AnimeRuleMode.self, forKey: .searchMode),
            chapterMode: try c.decodeIfPresent(AnimeRuleMode.self, forKey: .chapterMode),
            searchApiConfig: try c.decodeIfPresent(AnimeAPISearch.self, forKey: .searchApiConfig),
            chapterApiConfig: try c.decodeIfPresent(AnimeAPIChapter.self, forKey: .chapterApiConfig)
        )
    }

    var compatibilityIssue: String? {
        guard let level = Int(api), (1...9).contains(level) else { return "Unsupported Kazumi API level: \(api)" }
        if searchMode == .api && searchApiConfig == nil { return "Missing API search configuration" }
        if chapterMode == .api && chapterApiConfig == nil { return "Missing API chapter configuration" }
        return nil
    }

    // 辅助计算属性: 获取实际的搜索列表选择器
    func getSearchListSelector() -> String {
        if searchMode == .xpath, let xpath = xpath, let search = xpath.search {
            return search.list
        }
        return searchList ?? "a"
    }
    
    func getSearchNameSelector() -> String {
        if searchMode == .xpath, let xpath = xpath, let search = xpath.search {
            return search.title
        }
        return searchName ?? ""
    }
    
    func getSearchCoverSelector() -> String {
        if searchMode == .xpath, let xpath = xpath, let search = xpath.search, let cover = search.cover {
            return cover
        }
        return searchCover ?? "img"
    }
    
    func getSearchDetailSelector() -> String {
        if searchMode == .xpath, let xpath = xpath, let search = xpath.search {
            return search.detail
        }
        return searchDetail ?? "a[href]"
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: AnimeRule, rhs: AnimeRule) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - XPath 规则结构 (API v2)

struct AnimeXPathRules: Codable {
    let search: AnimeSearchXPath?
    let detail: AnimeDetailXPath?
    let list: AnimeListXPath?
}

struct AnimeSearchXPath: Codable {
    let url: String
    let list: String
    let title: String
    let cover: String?
    let detail: String
    let id: String?
}

struct AnimeDetailXPath: Codable {
    let title: String?
    let cover: String?
    let description: String?
    let episodes: String?
    let episodeName: String?
    let episodeLink: String?
    let episodeThumb: String?
    let fullImage: String?
    let resolution: String?
    let fileSize: String?
}

struct AnimeListXPath: Codable {
    let url: String
    let list: String
    let title: String
    let cover: String
    let detail: String
    let nextPage: String?
}

// MARK: - 反爬虫配置 (参考 Kazumi AntiCrawlerConfig)

/// Values are retained for compatibility; verification always stays user driven.
enum CaptchaType: Int, Codable {
    case imageCaptcha = 1
    case autoClickButton = 2
    case customJavaScript = 3
    case unknown = 0
    init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(Int.self)) ?? .unknown
    }
}

struct AntiCrawlerConfig: Codable {
    let enabled: Bool
    let captchaType: CaptchaType
    let captchaImage: String
    let captchaInput: String
    let captchaButton: String
    let captchaDetectType: Int
    let captchaDetectValue: String
    /// Stored losslessly; never executed by the parser.
    let captchaScript: String
    enum CodingKeys: String, CodingKey {
        case enabled, captchaType, captchaImage, captchaInput, captchaButton
        case captchaDetectType, captchaDetectValue, captchaScript
    }
    init(enabled: Bool = false, captchaType: CaptchaType = .imageCaptcha,
         captchaImage: String = "", captchaInput: String = "", captchaButton: String = "",
         captchaDetectType: Int = 1, captchaDetectValue: String = "", captchaScript: String = "") {
        self.enabled = enabled
        self.captchaType = captchaType
        self.captchaImage = captchaImage
        self.captchaInput = captchaInput
        self.captchaButton = captchaButton
        self.captchaDetectType = captchaDetectType
        self.captchaDetectValue = captchaDetectValue
        self.captchaScript = captchaScript
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false,
                  captchaType: try c.decodeIfPresent(CaptchaType.self, forKey: .captchaType) ?? .imageCaptcha,
                  captchaImage: try c.decodeIfPresent(String.self, forKey: .captchaImage) ?? "",
                  captchaInput: try c.decodeIfPresent(String.self, forKey: .captchaInput) ?? "",
                  captchaButton: try c.decodeIfPresent(String.self, forKey: .captchaButton) ?? "",
                  captchaDetectType: try c.decodeIfPresent(Int.self, forKey: .captchaDetectType) ?? 1,
                  captchaDetectValue: try c.decodeIfPresent(String.self, forKey: .captchaDetectValue) ?? "",
                  captchaScript: try c.decodeIfPresent(String.self, forKey: .captchaScript) ?? "")
    }
    static func empty() -> AntiCrawlerConfig { AntiCrawlerConfig() }
}

// MARK: - 动漫规则索引 (用于规则市场)

struct AnimeRuleIndex: Codable {
    let schemaVersion: String
    let lastUpdated: String
    let animeRules: [AnimeRuleInfo]

    struct AnimeRuleInfo: Codable, Identifiable {
        let id: String
        let name: String
        let version: String
        let api: String
        let deprecated: Bool
        let url: String
        let description: String?
        let tags: [String]?
    }
}

// MARK: - 动漫内容项

struct AnimeSearchResult: Identifiable, Codable, Hashable {
    let id: String
    let title: String
    let coverURL: String?
    let detailURL: String
    let sourceId: String
    let sourceName: String
    let latestEpisode: String?
    let rating: String?

    // 可选的详细字段（用于详情页）
    var summary: String?
    var rank: Int?
    var airDate: String?
    var airWeekday: Int?
    var tags: [AnimeTag]?
    var originalName: String?  // 日文原名

    // 计算属性：显示标题
    var displayTitle: String { title }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: AnimeSearchResult, rhs: AnimeSearchResult) -> Bool {
        lhs.id == rhs.id
    }
    
    // 星期几显示名称
    var airWeekdayDisplay: String? {
        guard let weekday = airWeekday else { return nil }
        switch weekday {
        case 1: return t("星期日")
        case 2: return t("星期一")
        case 3: return t("星期二")
        case 4: return t("星期三")
        case 5: return t("星期四")
        case 6: return t("星期五")
        case 7: return t("星期六")
        default: return nil
        }
    }
    
    // 类型显示名称
    var typeDisplayName: String { t("bangumi.animation") }
}

struct AnimeTag: Codable, Identifiable {
    let id = UUID()
    let name: String
    let count: Int?
    
    enum CodingKeys: String, CodingKey {
        case name, count
    }
}

struct AnimeDetail: Identifiable, Codable {
    let id: String
    let title: String
    let coverURL: String?
    let description: String?
    let status: String?
    let rating: String?
    let episodes: [AnimeEpisodeItem]
    let sourceId: String

    struct AnimeEpisodeItem: Identifiable, Codable {
        let id: String
        let name: String?
        let episodeNumber: Int
        let url: String
        let thumbnailURL: String?
    }
}
