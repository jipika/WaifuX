import Foundation

// MARK: - DanDanPlay API 服务

/// DanDanPlay 弹幕服务（参考 Kazumi 实现）
@MainActor
class DanmakuService {
    static let shared = DanmakuService()

    private let baseURL = "https://api.dandanplay.net/api/v2"
    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.httpAdditionalHeaders = [
            "Accept": "application/json",
            "User-Agent": "WallHaven/1.0"
        ]
        self.session = URLSession(configuration: config)
    }

    // MARK: - 搜索动漫

    /// 根据动漫名称搜索弹幕源
    /// - Parameters:
    ///   - keyword: 搜索关键词（动漫名称）
    /// - Returns: 匹配的动漫列表
    func searchAnime(keyword: String) async throws -> [DanmakuAnime] {
        let encodedKeyword = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        let urlString = "\(baseURL)/search/anime?keyword=\(encodedKeyword)"

        guard let url = URL(string: urlString) else {
            throw DanmakuError.invalidURL
        }

        print("[DanmakuService] 搜索动漫: \(keyword)")

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw DanmakuError.serverError
        }

        let searchResponse = try JSONDecoder().decode(DanmakuSearchResponse.self, from: data)
        print("[DanmakuService] 找到 \(searchResponse.animes.count) 个结果")

        return searchResponse.animes
    }

    /// 根据 Bangumi ID 获取弹幕源
    /// - Parameter bangumiId: Bangumi 条目 ID
    /// - Returns: 匹配的动漫信息
    func getDanmakuSourceByBangumiId(bangumiId: Int) async throws -> DanmakuAnime? {
        let urlString = "\(baseURL)/bangumi/\(bangumiId)"

        guard let url = URL(string: urlString) else {
            throw DanmakuError.invalidURL
        }

        print("[DanmakuService] 通过 Bangumi ID 获取弹幕源: \(bangumiId)")

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DanmakuError.serverError
        }

        if httpResponse.statusCode == 404 {
            print("[DanmakuService] 未找到 Bangumi ID \(bangumiId) 的弹幕源")
            return nil
        }

        guard httpResponse.statusCode == 200 else {
            throw DanmakuError.serverError
        }

        // 解析返回的动漫详情
        struct BangumiResponse: Codable {
            let animeId: Int
            let animeTitle: String
            let type: String
            let typeDescription: String
            let episodes: [DanmakuEpisode]
        }

        let bangumiResponse = try JSONDecoder().decode(BangumiResponse.self, from: data)

        return DanmakuAnime(
            animeId: bangumiResponse.animeId,
            animeTitle: bangumiResponse.animeTitle,
            type: bangumiResponse.type,
            typeDescription: bangumiResponse.typeDescription,
            episodes: bangumiResponse.episodes
        )
    }

    // MARK: - 获取弹幕

    /// 获取指定集数的弹幕
    /// - Parameters:
    ///   - episodeId: 集数 ID
    ///   - withRelated: 是否包含相关视频的弹幕
    /// - Returns: 弹幕列表
    func getDanmaku(episodeId: Int, withRelated: Bool = true) async throws -> [Danmaku] {
        let urlString = "\(baseURL)/comment/\(episodeId)?withRelated=\(withRelated)"

        guard let url = URL(string: urlString) else {
            throw DanmakuError.invalidURL
        }

        print("[DanmakuService] 获取弹幕: episodeId=\(episodeId), withRelated=\(withRelated)")

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw DanmakuError.serverError
        }

        let commentResponse = try JSONDecoder().decode(DanmakuCommentResponse.self, from: data)
        print("[DanmakuService] 获取到 \(commentResponse.count) 条弹幕")

        // 转换为内部模型
        return commentResponse.comments.map { Danmaku(from: $0) }
    }

    /// 获取指定集数的弹幕（使用动漫 ID 和集数号）
    /// - Parameters:
    ///   - animeId: 动漫 ID
    ///   - episodeNumber: 集数号
    /// - Returns: 弹幕列表
    func getDanmaku(animeId: Int, episodeNumber: Int) async throws -> [Danmaku] {
        // 首先获取动漫详情，找到对应集数的 episodeId
        let urlString = "\(baseURL)/bangumi/\(animeId)"

        guard let url = URL(string: urlString) else {
            throw DanmakuError.invalidURL
        }

        print("[DanmakuService] 获取动漫详情: animeId=\(animeId)")

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw DanmakuError.serverError
        }

        struct BangumiDetail: Codable {
            let episodes: [DanmakuEpisode]
        }

        let detail = try JSONDecoder().decode(BangumiDetail.self, from: data)

        // 找到匹配的集数
        let targetEpisode = detail.episodes.first { episode in
            if let epNum = Int(episode.episodeNumber) {
                return epNum == episodeNumber
            }
            return episode.episodeNumber == "\(episodeNumber)"
        }

        guard let episode = targetEpisode else {
            print("[DanmakuService] 未找到第 \(episodeNumber) 集的弹幕")
            return []
        }

        return try await getDanmaku(episodeId: episode.episodeId, withRelated: true)
    }

    // MARK: - 便捷方法

    /// 智能获取弹幕（先搜索，再获取）
    /// - Parameters:
    ///   - animeTitle: 动漫标题
    ///   - episodeNumber: 集数号
    /// - Returns: 弹幕列表
    func fetchDanmakuSmart(animeTitle: String, episodeNumber: Int) async throws -> [Danmaku] {
        // 1. 搜索动漫
        let animes = try await searchAnime(keyword: animeTitle)

        // 2. 找到最匹配的结果
        guard let bestMatch = findBestMatch(animes: animes, title: animeTitle) else {
            print("[DanmakuService] 未找到匹配的动漫: \(animeTitle)")
            return []
        }

        // 3. 找到对应集数
        let targetEpisode = bestMatch.episodes.first { episode in
            if let epNum = Int(episode.episodeNumber) {
                return epNum == episodeNumber
            }
            // 支持 "第X集" 格式
            return episode.episodeTitle.contains("\(episodeNumber)") ||
                   episode.episodeNumber == "\(episodeNumber)"
        }

        guard let episode = targetEpisode else {
            print("[DanmakuService] 未找到第 \(episodeNumber) 集")
            return []
        }

        // 4. 获取弹幕
        var danmaku = try await getDanmaku(episodeId: episode.episodeId, withRelated: true)

        // 5. 去重
        danmaku = danmaku.deduplicated(timeWindow: 5.0)

        return danmaku
    }

    /// 通过 Bangumi ID 智能获取弹幕
    /// - Parameters:
    ///   - bangumiId: Bangumi 条目 ID
    ///   - episodeNumber: 集数号
    /// - Returns: 弹幕列表
    func fetchDanmakuByBangumiId(bangumiId: Int, episodeNumber: Int) async throws -> [Danmaku] {
        // 1. 获取弹幕源
        guard let anime = try await getDanmakuSourceByBangumiId(bangumiId: bangumiId) else {
            print("[DanmakuService] 未找到 Bangumi ID \(bangumiId) 的弹幕源")
            return []
        }

        // 2. 找到对应集数
        let targetEpisode = anime.episodes.first { episode in
            if let epNum = Int(episode.episodeNumber) {
                return epNum == episodeNumber
            }
            return episode.episodeTitle.contains("\(episodeNumber)") ||
                   episode.episodeNumber == "\(episodeNumber)"
        }

        guard let episode = targetEpisode else {
            print("[DanmakuService] 未找到第 \(episodeNumber) 集")
            return []
        }

        // 3. 获取弹幕
        var danmaku = try await getDanmaku(episodeId: episode.episodeId, withRelated: true)

        // 4. 去重
        danmaku = danmaku.deduplicated(timeWindow: 5.0)

        return danmaku
    }

    // MARK: - 私有方法

    /// 找到最匹配的动漫
    private func findBestMatch(animes: [DanmakuAnime], title: String) -> DanmakuAnime? {
        let lowerTitle = title.lowercased()

        // 1. 优先完全匹配
        if let exactMatch = animes.first(where: { $0.animeTitle.lowercased() == lowerTitle }) {
            return exactMatch
        }

        // 2. 包含匹配
        if let containsMatch = animes.first(where: { $0.animeTitle.lowercased().contains(lowerTitle) }) {
            return containsMatch
        }

        // 3. 返回第一个结果
        return animes.first
    }
}

// MARK: - 错误类型

enum DanmakuError: Error, LocalizedError {
    case invalidURL
    case serverError
    case noData
    case decodingError
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "无效的 URL"
        case .serverError:
            return "服务器错误"
        case .noData:
            return "没有数据"
        case .decodingError:
            return "数据解析错误"
        case .networkError(let error):
            return "网络错误: \(error.localizedDescription)"
        }
    }
}
