import Foundation

// MARK: - 动漫解析规则 (参考 Kazumi 简化格式)

// 简化规则格式，核心仅需 ~15 行配置
// 支持 CSS Selector 解析

struct AnimeRule: Identifiable, Codable, Hashable {
    let id: String
    let api: String      // "1" = 简化版(CSS), "2" = XPath版
    let type: String      // "anime"
    let name: String
    let version: String
    let deprecated: Bool

    // 站点配置
    let baseURL: String
    let headers: [String: String]?
    let userAgent: String?
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

    // API v2: XPath 格式 (兼容 Kazumi)
    let xpath: AnimeXPathRules?

    // 反爬虫配置 (参考 Kazumi antiCrawlerConfig)
    let antiCrawlerConfig: AntiCrawlerConfig?

    enum CodingKeys: String, CodingKey {
        case id, api, type, name, version, deprecated
        case baseURL, headers, userAgent, timeout
        case searchURL, searchList, searchName, searchCover, searchDetail, searchId
        case detailTitle, detailCover, detailDesc, detailStatus, detailRating
        case episodeList, episodeName, episodeLink, episodeThumb
        case videoSelector, videoSourceAttr, useWebview, multiSources
        case xpath
        case antiCrawlerConfig
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
        // API v2 字段
        xpath: AnimeXPathRules? = nil,
        antiCrawlerConfig: AntiCrawlerConfig? = nil
    ) {
        self.id = id
        self.api = api
        self.type = type
        self.name = name
        self.version = version
        self.deprecated = deprecated
        self.baseURL = baseURL
        self.headers = headers
        self.userAgent = userAgent
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

        self.xpath = xpath
        self.antiCrawlerConfig = antiCrawlerConfig
    }

    // 辅助计算属性: 获取实际的搜索列表选择器
    func getSearchListSelector() -> String {
        if api == "2", let xpath = xpath, let search = xpath.search {
            return search.list
        }
        return searchList ?? "a"
    }
    
    func getSearchNameSelector() -> String {
        if api == "2", let xpath = xpath, let search = xpath.search {
            return search.title
        }
        return searchName ?? ""
    }
    
    func getSearchCoverSelector() -> String {
        if api == "2", let xpath = xpath, let search = xpath.search, let cover = search.cover {
            return cover
        }
        return searchCover ?? "img"
    }
    
    func getSearchDetailSelector() -> String {
        if api == "2", let xpath = xpath, let search = xpath.search {
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

struct AntiCrawlerConfig: Codable {
    let enabled: Bool
    let captchaImage: String
    let captchaButton: String

    init(enabled: Bool = false, captchaImage: String = "", captchaButton: String = "") {
        self.enabled = enabled
        self.captchaImage = captchaImage
        self.captchaButton = captchaButton
    }

    static func empty() -> AntiCrawlerConfig {
        AntiCrawlerConfig(enabled: false, captchaImage: "", captchaButton: "")
    }
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

struct AnimeSearchResult: Identifiable, Codable {
    let id: String
    let title: String
    let coverURL: String?
    let detailURL: String
    let sourceId: String
    let sourceName: String
    let latestEpisode: String?
    let rating: String?
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
