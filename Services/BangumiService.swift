import Foundation

// MARK: - Bangumi API 配置 (参考 Kazumi)

enum BangumiAPI {
    /// 主 API Domain
    static let baseURL = "https://api.bgm.tv"
    /// 新 API Domain (Next)
    static let nextBaseURL = "https://next.bgm.tv"
    
    /// 番剧趋势 (热门)
    static let trending = "/p1/trending/subjects"
    
    /// 条目搜索
    static func search(limit: Int = 12, offset: Int = 0) -> String {
        return "/v0/search/subjects?limit=\(limit)&offset=\(offset)"
    }
    
    /// 番剧详情
    static func subjectDetail(id: String) -> String {
        return "/v0/subjects/\(id)"
    }

    /// 章节列表
    static func episodes(subjectId: Int, limit: Int = 100, offset: Int = 0) -> String {
        return "/v0/episodes?subject_id=\(subjectId)&limit=\(limit)&offset=\(offset)"
    }

    /// 每日放送
    static let calendar = "/p1/calendar"
}

// MARK: - Bangumi 数据模型

struct BangumiTrendingResponse: Codable {
    let data: [BangumiTrendingItem]
    let total: Int?
}

struct BangumiTrendingItem: Codable {
    let subject: BangumiSubject
}

struct BangumiSubject: Codable, Identifiable {
    let id: Int
    let type: Int
    let name: String
    let nameCN: String?
    let images: BangumiImages?
    let summary: String?
    let rating: BangumiRating?
    let rank: Int?
    let airDate: String?
    let airWeekday: Int?
    let tags: [BangumiTag]?
    let info: String?
    
    /// 获取显示标题（优先中文）
    var displayTitle: String {
        return nameCN?.isEmpty == false ? nameCN! : name
    }
    
    /// 获取列表封面 URL（中等尺寸）
    var coverURL: String? {
        return images?.common ?? images?.medium ?? images?.large
    }
    
    /// 获取高清封面 URL（大尺寸）- 用于详情页
    var largeCoverURL: String? {
        return images?.large ?? images?.common ?? images?.medium
    }

    /// 类型显示名称
    var typeDisplayName: String {
        switch type {
        case 1: return t("bangumi.book")
        case 2: return t("bangumi.animation")
        case 3: return t("bangumi.music")
        case 4: return t("bangumi.game")
        case 6: return t("bangumi.real")
        default: return t("bangumi.other")
        }
    }
    
    /// 星期几显示名称
    var airWeekdayDisplay: String? {
        guard let weekday = airWeekday else { return nil }
        switch weekday {
        case 1: return t("bangumi.sunday")
        case 2: return t("bangumi.monday")
        case 3: return t("bangumi.tuesday")
        case 4: return t("bangumi.wednesday")
        case 5: return t("bangumi.thursday")
        case 6: return t("bangumi.friday")
        case 7: return t("bangumi.saturday")
        default: return nil
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        id = try container.decode(Int.self, forKey: .id)
        type = try container.decode(Int.self, forKey: .type)
        name = try container.decode(String.self, forKey: .name)
        images = try container.decodeIfPresent(BangumiImages.self, forKey: .images)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        rating = try container.decodeIfPresent(BangumiRating.self, forKey: .rating)
        rank = try container.decodeIfPresent(Int.self, forKey: .rank)
        airDate = try container.decodeIfPresent(String.self, forKey: .airDate)
        airWeekday = try container.decodeIfPresent(Int.self, forKey: .airWeekday)
        tags = try container.decodeIfPresent([BangumiTag].self, forKey: .tags)
        info = try container.decodeIfPresent(String.self, forKey: .info)
        
        if let nameCNValue = try? container.decode(String.self, forKey: .nameCN) {
            nameCN = nameCNValue
        } else if let nameCnValue = try? container.decode(String.self, forKey: .name_cn) {
            nameCN = nameCnValue
        } else {
            nameCN = nil
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(type, forKey: .type)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(nameCN, forKey: .nameCN)
        try container.encodeIfPresent(images, forKey: .images)
        try container.encodeIfPresent(summary, forKey: .summary)
        try container.encodeIfPresent(rating, forKey: .rating)
        try container.encodeIfPresent(rank, forKey: .rank)
        try container.encodeIfPresent(airDate, forKey: .airDate)
        try container.encodeIfPresent(airWeekday, forKey: .airWeekday)
        try container.encodeIfPresent(tags, forKey: .tags)
        try container.encodeIfPresent(info, forKey: .info)
    }
    
    enum CodingKeys: String, CodingKey {
        case id, type, name, images, summary, rating, rank, tags, info
        case nameCN
        case name_cn
        case airDate
        case airWeekday
    }
}

struct BangumiImages: Codable {
    let large: String?
    let common: String?
    let medium: String?
    let small: String?
    let grid: String?
}

struct BangumiRating: Codable {
    let rank: Int?
    let total: Int
    let score: Double
    // count 可能是数组或字典，使用 AnyCodable 处理或忽略
    // Bangumi API 的 rating.count 有时是 { "1": n, "2": n, ... } 格式
    
    enum CodingKeys: String, CodingKey {
        case rank, total, score
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rank = try container.decodeIfPresent(Int.self, forKey: .rank)
        total = try container.decode(Int.self, forKey: .total)
        score = try container.decode(Double.self, forKey: .score)
        // 忽略 count 字段，因为它格式不固定
    }
}

struct BangumiTag: Codable {
    let name: String
    let count: Int
}

struct BangumiEpisodeItem: Codable, Identifiable {
    let id: Int
    let ep: Int
    let name: String?
    let nameCN: String?
    let duration: String?
    let airDate: String?
    let subjectID: Int

    enum CodingKeys: String, CodingKey {
        case id, ep, name, nameCN = "name_cn", duration
        case airDate = "date"
        case subjectID = "subject_id"
    }

    var displayName: String {
        return nameCN?.isEmpty == false ? nameCN! : (name ?? "\(t("anime.episode"))\(ep)")
    }
}

struct BangumiEpisodesResponse: Codable {
    let data: [BangumiEpisodeItem]
    let total: Int?
    let limit: Int?
    let offset: Int?
}

struct BangumiSubjectDetail: Codable {
    let id: Int
    let type: Int
    let name: String
    let nameCN: String?
    let summary: String?
    let airDate: String?
    let images: BangumiImages?
    let rating: BangumiRating?
    let rank: Int?
    let totalEpisodes: Int?
    let volumes: Int?
    let series: Bool?

    enum CodingKeys: String, CodingKey {
        case id, type, name, summary, images, rating, rank, volumes, series
        case nameCN = "name_cn"
        case airDate = "date"
        case totalEpisodes = "total_episodes"
    }
}

struct BangumiSearchRequest: Codable {
    let keyword: String
    let sort: String
    let filter: BangumiFilter
}

struct BangumiFilter: Codable {
    let type: [Int]?
    let tag: [String]?
    let airDate: [String]?
    let rank: [String]?
    let nsfw: Bool?
    
    enum CodingKeys: String, CodingKey {
        case type, tag, rank, nsfw
        case airDate = "air_date"
    }
}

struct BangumiSearchResponse: Codable {
    let data: [BangumiSubject]
    let total: Int?
    let limit: Int?
    let offset: Int?
}

// MARK: - Bangumi 服务

actor BangumiService {
    static let shared = BangumiService()
    
    private let session: URLSession
    private let decoder: JSONDecoder
    
    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
        
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }
    
    // MARK: - 获取热门番组

    func getTrendingList(limit: Int = 24, offset: Int = 0) async throws -> (items: [BangumiSubject], total: Int?) {
        let urlString = "\(BangumiAPI.nextBaseURL)\(BangumiAPI.trending)?type=2&limit=\(limit)&offset=\(offset)"

        guard let url = URL(string: urlString) else {
            throw BangumiError.invalidURL
        }

        print("[BangumiService] Fetching trending: \(urlString)")

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("User-Agent", forHTTPHeaderField: "WallHaven/1.0")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw BangumiError.invalidResponse
        }

        let trendingResponse = try decoder.decode(BangumiTrendingResponse.self, from: data)
        print("[BangumiService] Fetched \(trendingResponse.data.count) trending items, total: \(trendingResponse.total ?? -1)")

        return (trendingResponse.data.map { $0.subject }, trendingResponse.total)
    }

    // MARK: - 搜索番组 (按关键词)

    func searchByKeyword(keyword: String, limit: Int = 24, offset: Int = 0) async throws -> (items: [BangumiSubject], total: Int?) {
        let urlString = "\(BangumiAPI.baseURL)\(BangumiAPI.search(limit: limit, offset: offset))"

        guard let url = URL(string: urlString) else {
            throw BangumiError.invalidURL
        }

        print("[BangumiService] Searching by keyword '\(keyword)': \(urlString)")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("User-Agent", forHTTPHeaderField: "WallHaven/1.0")

        // 构建搜索参数 - 使用 keyword 进行搜索
        let searchRequest: [String: Any] = [
            "keyword": keyword,
            "sort": "rank",
            "filter": [
                "type": [2],  // 2 = 动画
                "rank": [">0", "<=99999"],
                "nsfw": false
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: searchRequest)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let errorString = String(data: data, encoding: .utf8) ?? "Unknown"
            print("[BangumiService] Search error: \(errorString)")
            throw BangumiError.invalidResponse
        }

        let searchResponse = try decoder.decode(BangumiSearchResponse.self, from: data)
        print("[BangumiService] Found \(searchResponse.data.count) items for keyword '\(keyword)', total: \(searchResponse.total ?? -1)")

        return (searchResponse.data, searchResponse.total)
    }

    // MARK: - 搜索番组 (按标签)

    func searchByTag(tag: String, limit: Int = 24, offset: Int = 0) async throws -> (items: [BangumiSubject], total: Int?) {
        let urlString = "\(BangumiAPI.baseURL)\(BangumiAPI.search(limit: limit, offset: offset))"

        guard let url = URL(string: urlString) else {
            throw BangumiError.invalidURL
        }

        print("[BangumiService] Searching by tag '\(tag)': \(urlString)")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("User-Agent", forHTTPHeaderField: "WallHaven/1.0")

        // 构建搜索参数 (参考 Kazumi) - 使用 tag 过滤
        let searchRequest: [String: Any] = [
            "keyword": "",
            "sort": "rank",
            "filter": [
                "type": [2],  // 2 = 动画
                "tag": [tag],
                "rank": [">0", "<=99999"],
                "nsfw": false
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: searchRequest)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let errorString = String(data: data, encoding: .utf8) ?? "Unknown"
            print("[BangumiService] Search error: \(errorString)")
            throw BangumiError.invalidResponse
        }

        let searchResponse = try decoder.decode(BangumiSearchResponse.self, from: data)
        print("[BangumiService] Found \(searchResponse.data.count) items for tag '\(tag)', total: \(searchResponse.total ?? -1)")

        return (searchResponse.data, searchResponse.total)
    }
    
    // MARK: - 获取番剧详情 (兼容 AnimeDetailViewModel)

    func getDetail(id: Int) async throws -> BangumiDetail {
        let urlString = "\(BangumiAPI.baseURL)\(BangumiAPI.subjectDetail(id: String(id)))"

        guard let url = URL(string: urlString) else {
            throw BangumiError.invalidURL
        }

        print("[BangumiService] Fetching detail: \(id)")

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("User-Agent", forHTTPHeaderField: "WallHaven/1.0")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw BangumiError.invalidResponse
        }

        let detail = try decoder.decode(BangumiDetail.self, from: data)
        print("[BangumiService] Detail loaded: \(detail.name)")
        return detail
    }

    // MARK: - 获取番剧详情 (旧版)

    func getSubjectDetail(id: Int) async throws -> BangumiSubjectDetail {
        let urlString = "\(BangumiAPI.baseURL)\(BangumiAPI.subjectDetail(id: String(id)))"

        guard let url = URL(string: urlString) else {
            throw BangumiError.invalidURL
        }

        print("[BangumiService] Fetching subject detail: \(id)")

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("User-Agent", forHTTPHeaderField: "WallHaven/1.0")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw BangumiError.invalidResponse
        }

        let subject = try decoder.decode(BangumiSubjectDetail.self, from: data)
        print("[BangumiService] Subject detail: \(subject.name), episodes: \(subject.totalEpisodes ?? 0)")
        return subject
    }

    // MARK: - 获取章节列表

    func getEpisodes(subjectId: Int, limit: Int = 100, offset: Int = 0) async throws -> (episodes: [BangumiEpisodeItem], total: Int?) {
        let urlString = "\(BangumiAPI.baseURL)\(BangumiAPI.episodes(subjectId: subjectId, limit: limit, offset: offset))"

        guard let url = URL(string: urlString) else {
            throw BangumiError.invalidURL
        }

        print("[BangumiService] Fetching episodes for subject: \(subjectId)")

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("User-Agent", forHTTPHeaderField: "WallHaven/1.0")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw BangumiError.invalidResponse
        }

        let episodesResponse = try decoder.decode(BangumiEpisodesResponse.self, from: data)
        print("[BangumiService] Fetched \(episodesResponse.data.count) episodes, total: \(episodesResponse.total ?? -1)")
        return (episodesResponse.data, episodesResponse.total)
    }
}

// MARK: - Bangumi 详情模型 (简化版，用于 AnimeDetailView)

struct BangumiDetail: Codable {
    let id: Int
    let name: String
    let nameCN: String?
    let summary: String?
    let rating: BangumiDetailRating?
    let images: BangumiImages?
    let totalEpisodes: Int?
    let airDate: String?
    let airWeekday: Int?

    /// 类型显示名称
    var typeDisplayName: String {
        return t("bangumi.animation")
    }
    
    /// 星期几显示名称
    var airWeekdayDisplay: String? {
        guard let weekday = airWeekday else { return nil }
        switch weekday {
        case 1: return t("bangumi.sunday")
        case 2: return t("bangumi.monday")
        case 3: return t("bangumi.tuesday")
        case 4: return t("bangumi.wednesday")
        case 5: return t("bangumi.thursday")
        case 6: return t("bangumi.friday")
        case 7: return t("bangumi.saturday")
        default: return nil
        }
    }
    
    /// 播出状态
    var airStatus: String {
        guard let airDate = airDate else { return t("bangumi.unknown") }
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        guard let date = dateFormatter.date(from: airDate) else { return t("bangumi.unknown") }
        
        if date > Date() {
            return t("bangumi.notStarted")
        } else if let total = totalEpisodes, total > 0 {
            return t("bangumi.finished")
        } else {
            return t("bangumi.airing")
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, name, summary, rating, images
        case nameCN = "name_cn"
        case totalEpisodes = "total_episodes"
        case airDate = "air_date"
        case airWeekday = "air_weekday"
    }
}

struct BangumiDetailRating: Codable {
    let score: Double
    let total: Int
}

enum BangumiError: Error {
    case invalidURL
    case invalidResponse
    case decodingError(Error)
    case networkError(Error)
}

// MARK: - BangumiSubject 到 AnimeSearchResult 转换

extension BangumiSubject {
    /// 转换为 AnimeSearchResult 用于 UI 显示
    func toAnimeSearchResult() -> AnimeSearchResult {
        // 使用大尺寸图片以提高清晰度
        let largeCoverURL = images?.large ?? images?.grid ?? images?.common ?? images?.medium
        // 格式化评分
        let ratingString = rating.map { String(format: "%.1f", $0.score) }
        return AnimeSearchResult(
            id: String(id),
            title: displayTitle,
            coverURL: largeCoverURL,
            detailURL: "https://bgm.tv/subject/\(id)",
            sourceId: "bangumi",
            sourceName: "Bangumi",
            latestEpisode: nil,
            rating: ratingString,
            summary: summary
        )
    }
}
