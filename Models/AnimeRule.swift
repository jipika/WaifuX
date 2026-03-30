import Foundation

// MARK: - 动漫解析规则 (参考 Kazumi 简化格式)

// 简化规则格式，核心仅需 ~15 行配置
// 支持 CSS Selector 解析

struct AnimeRule: Identifiable, Codable, Hashable {
    let id: String
    let api: String      // "1" = 基础版
    let type: String      // "anime"
    let name: String
    let version: String
    let deprecated: Bool

    // 站点配置
    let baseURL: String
    let headers: [String: String]?
    let timeout: Int?

    // 搜索解析
    let searchURL: String
    let searchList: String      // CSS Selector: 搜索结果列表容器
    let searchName: String      // CSS Selector: 标题
    let searchCover: String      // CSS Selector: 封面图
    let searchDetail: String     // CSS Selector: 详情链接
    let searchId: String?        // CSS Selector: ID (可选)

    // 详情解析
    let detailTitle: String?     // CSS Selector: 详情页标题
    let detailCover: String?    // CSS Selector: 详情页封面
    let detailDesc: String?     // CSS Selector: 描述
    let detailStatus: String?   // CSS Selector: 状态
    let detailRating: String?   // CSS Selector: 评分

    // 剧集列表
    let episodeList: String?    // CSS Selector: 剧集列表容器
    let episodeName: String?    // CSS Selector: 剧集名称
    let episodeLink: String?    // CSS Selector: 剧集链接
    let episodeThumb: String?   // CSS Selector: 剧集缩略图

    // 视频解析
    let videoSelector: String?  // CSS Selector: 视频 iframe 或 video 标签
    let videoSourceAttr: String? // 属性名: "src" 或 "data-src"
    let useWebview: Bool        // 是否需要 WebView 加载

    // 多源支持
    let multiSources: Bool

    enum CodingKeys: String, CodingKey {
        case id, api, type, name, version, deprecated
        case baseURL, headers, timeout
        case searchURL, searchList, searchName, searchCover, searchDetail, searchId
        case detailTitle, detailCover, detailDesc, detailStatus, detailRating
        case episodeList, episodeName, episodeLink, episodeThumb
        case videoSelector, videoSourceAttr, useWebview
        case multiSources
    }

    // 方便创建默认值的初始化器
    init(
        id: String,
        api: String = "1",
        type: String = "anime",
        name: String,
        version: String = "1.0.0",
        deprecated: Bool = false,
        baseURL: String,
        headers: [String: String]? = nil,
        timeout: Int? = 30,
        searchURL: String,
        searchList: String,
        searchName: String,
        searchCover: String,
        searchDetail: String,
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
        useWebview: Bool = false,
        multiSources: Bool = false
    ) {
        self.id = id
        self.api = api
        self.type = type
        self.name = name
        self.version = version
        self.deprecated = deprecated
        self.baseURL = baseURL
        self.headers = headers
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
    }

    // Hashable conformance
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: AnimeRule, rhs: AnimeRule) -> Bool {
        lhs.id == rhs.id
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
