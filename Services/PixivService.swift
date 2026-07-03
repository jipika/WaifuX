import Foundation

// MARK: - Pixiv 壁纸数据源服务
///
/// Pixiv (https://www.pixiv.net/) 是日本最大的插画社区，以 ACG 插画为主。
/// 本 Service 负责：
///   1. 调用 Pixiv Web AJAX API 获取数据（排行榜 / 搜索 / 详情）
///   2. 将 Pixiv 数据映射为标准 Wallpaper 模型
///   3. 图片下载（i.pximg.net 必须携带 Referer）
///
/// API 参考：
///   - 排行榜：/ranking.php?format=json
///   - 搜索：/ajax/search/artworks/{word}
///   - 详情：/ajax/illust/{id}
actor PixivService {
    static let shared = PixivService()

    private let networkService = NetworkService.shared

    /// 基础 URL
    private let baseURL = "https://www.pixiv.net"

    /// 请求限速：两次请求之间至少间隔的时间（对齐 KonachanService 模式）
    private let minimumRequestInterval: TimeInterval = 0.5
    private var lastRequestTime: Date = .distantPast

    // MARK: - 公开 API

    /// 排行榜
    /// - Parameters:
    ///   - mode: 排行模式（daily/weekly/monthly/rookie/male/female/daily_r18/...）
    ///   - page: 页码，从 1 开始
    ///   - date: 可选，历史排行日期（格式 YYYYMMDD）
    /// - Returns: 标准 WallpaperSearchResponse
    func ranking(
        mode: String = "daily",
        page: Int = 1,
        date: String? = nil,
        content: String = "illust"
    ) async throws -> WallpaperSearchResponse {
        guard var components = URLComponents(string: baseURL) else {
            throw NetworkError.invalidResponse
        }
        components.path = "/ranking.php"
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "mode", value: mode),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "content", value: "illust"),
            URLQueryItem(name: "p", value: "\(page)")
        ]
        if let date = date {
            queryItems.append(URLQueryItem(name: "date", value: date))
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            throw NetworkError.invalidResponse
        }

        print("📊 [PixivService] ========== Ranking Request ==========")
        print("📊 [PixivService] URL: \(url.absoluteString)")
        print("📊 [PixivService] Mode: \(mode), Page: \(page), Content: \(content)")
        await enforceRateLimit()

        let response: PixivRankingResponse
        do {
            response = try await networkService.fetch(
                PixivRankingResponse.self,
                from: url,
                headers: defaultHeaders
            )
            print("✅ [PixivService] Success: \(response.contents.count) items, rankTotal=\(response.rankTotal)")
        } catch {
            print("❌ [PixivService] Error fetching ranking: \(error)")
            throw error
        }

        let wallpapers = response.contents.map { $0.toWallpaper() }
        let hasMore = response.next != nil
        let total = response.rankTotal
        let lastPage = hasMore ? (total / response.contents.count + 1) : page

        let meta = WallpaperSearchResponse.Meta(
            query: nil,
            currentPage: page,
            perPage: .int(response.contents.count),
            total: total,
            lastPage: lastPage,
            seed: nil
        )

        return WallpaperSearchResponse(meta: meta, data: wallpapers)
    }

    /// 搜索
    /// - Parameters:
    ///   - word: 搜索词
    ///   - page: 页码，从 1 开始
    ///   - sort: 排序（date_d/date/popular_d/popular_male_d/popular_female_d）
    ///   - mode: 内容分级（all/safe/r18）
    ///   - type: 作品类型（illust_and_ugoira/illust/manga/ugoira）
    /// - Returns: 标准 WallpaperSearchResponse
    func search(
        word: String,
        page: Int = 1,
        sort: String = "date_d",
        mode: String = "all",
        type: String = "illust_and_ugoira",
        aiType: Int? = nil
    ) async throws -> (WallpaperSearchResponse, relatedTags: [String]) {
        guard var components = URLComponents(string: baseURL) else {
            throw NetworkError.invalidResponse
        }
        // URLComponents 会自动对 path 进行编码，不需要手动编码
        components.path = "/ajax/search/artworks/\(word)"
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "word", value: word),
            URLQueryItem(name: "order", value: sort),
            URLQueryItem(name: "mode", value: mode),
            URLQueryItem(name: "p", value: "\(page)"),
            URLQueryItem(name: "s_mode", value: "s_tag"),
            URLQueryItem(name: "type", value: type)
        ]
        if let aiType = aiType, aiType > 0 {
            queryItems.append(URLQueryItem(name: "ai_type", value: "\(aiType)"))
        }

        guard let url = components.url else {
            throw NetworkError.invalidResponse
        }

        print("🔍 [PixivService] ========== Search Request ==========")
        print("🔍 [PixivService] URL: \(url.absoluteString)")
        print("🔍 [PixivService] Params: word=\(word), type=\(type), mode=\(mode), sort=\(sort), page=\(page)")
        print("🔍 [PixivService] Headers: \(defaultHeaders)")
        await enforceRateLimit()

        // 先获取原始数据用于调试
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            
            // 打印原始响应
            if let httpResponse = response as? HTTPURLResponse {
                print("🔍 [PixivService] HTTP Status: \(httpResponse.statusCode)")
            }
            
            // 尝试打印部分 JSON 响应（前 500 字符）
            if let jsonString = String(data: data, encoding: .utf8) {
                let preview = String(jsonString.prefix(500))
                print("🔍 [PixivService] Response preview: \(preview)...")
            }
            
            // 尝试解码
            let decoded = try JSONDecoder().decode(PixivSearchResponse.self, from: data)
            
            if decoded.error {
                print("❌ [PixivService] API returned error: \(decoded.body)")
                throw NetworkError.invalidResponse
            }

            print("✅ [PixivService] Search success: \(decoded.body.illustManga.data.count) items, total=\(decoded.body.illustManga.total)")
            let wallpapers = decoded.body.illustManga.data.map { $0.toWallpaper() }
            let block = decoded.body.illustManga
            let relatedTags = decoded.body.relatedTags ?? []

            let meta = WallpaperSearchResponse.Meta(
                query: word,
                currentPage: page,
                perPage: .int(block.data.count),
                total: block.total,
                lastPage: block.lastPage,
                seed: nil
            )

            return (WallpaperSearchResponse(meta: meta, data: wallpapers), relatedTags: relatedTags)
        } catch {
            print("❌ [PixivService] Search failed with error: \(error)")
            print("❌ [PixivService] Error description: \(String(describing: error))")
            if let decodingError = error as? DecodingError {
                print("❌ [PixivService] Decoding error details: \(decodingError.localizedDescription)")
                switch decodingError {
                case .keyNotFound(let key, let context):
                    print("❌ [PixivService] Missing key: \(key.stringValue) in \(context.debugDescription)")
                case .typeMismatch(let type, let context):
                    print("❌ [PixivService] Type mismatch: expected \(type) in \(context.debugDescription)")
                case .valueNotFound(let type, let context):
                    print("❌ [PixivService] Value missing: expected \(type) in \(context.debugDescription)")
                case .dataCorrupted(let context):
                    print("❌ [PixivService] Data corrupted: \(context.debugDescription)")
                @unknown default:
                    print("❌ [PixivService] Unknown decoding error")
                }
            }
            throw error
        }
    }

    /// 作品详情
    /// - Parameter id: 作品 ID
    /// - Returns: 详情 body
    func illustDetail(id: String) async throws -> PixivIllustDetailBody {
        guard let url = URL(string: "\(baseURL)/ajax/illust/\(id)") else {
            throw NetworkError.invalidResponse
        }

        await enforceRateLimit()

        let response = try await networkService.fetch(
            PixivIllustDetailResponse.self,
            from: url,
            headers: defaultHeaders
        )

        guard !response.error else {
            throw NetworkError.invalidResponse
        }

        return response.body
    }

    /// 关联作品
    /// - Parameters:
    ///   - id: 作品 ID
    ///   - limit: 返回数量
    /// - Returns: 关联作品列表
    func relatedIllusts(id: String, limit: Int = 18) async throws -> [PixivSearchItem] {
        guard let url = URL(string: "\(baseURL)/ajax/illust/\(id)/recommend/init?limit=\(limit)") else {
            throw NetworkError.invalidResponse
        }

        await enforceRateLimit()

        let response = try await networkService.fetch(
            PixivRelatedResponse.self,
            from: url,
            headers: defaultHeaders
        )

        guard !response.error else {
            throw NetworkError.invalidResponse
        }

        return response.body.illusts
    }

    /// 用户全部作品
    /// - Parameter userId: 用户 ID
    /// - Returns: 用户作品列表
    func userAllIllusts(userId: String) async throws -> PixivUserProfileBody {
        guard let url = URL(string: "\(baseURL)/ajax/user/\(userId)/profile/all") else {
            throw NetworkError.invalidResponse
        }

        await enforceRateLimit()

        let response = try await networkService.fetch(
            PixivUserProfileResponse.self,
            from: url,
            headers: defaultHeaders
        )

        guard !response.error else {
            throw NetworkError.invalidResponse
        }

        return response.body
    }

    /// 下载图片（i.pximg.net 必须携带 Referer）
    /// - Parameter url: 图片 URL
    /// - Returns: 图片数据
    func downloadImage(url: String) async throws -> Data {
        guard let imageURL = URL(string: url) else {
            throw NetworkError.invalidResponse
        }

        await enforceRateLimit()

        return try await networkService.fetchData(
            from: imageURL,
            headers: ["Referer": "https://www.pixiv.net/"]
        )
    }

    // MARK: - 便捷方法

    /// 获取日榜（首页）
    func fetchDaily(limit: Int = 24) async throws -> [Wallpaper] {
        let response = try await ranking(mode: "daily", page: 1)
        return Array(response.data.prefix(limit))
    }

    /// 获取周榜
    func fetchWeekly(limit: Int = 24) async throws -> [Wallpaper] {
        let response = try await ranking(mode: "weekly", page: 1)
        return Array(response.data.prefix(limit))
    }

    /// 获取月榜
    func fetchMonthly(limit: Int = 24) async throws -> [Wallpaper] {
        let response = try await ranking(mode: "monthly", page: 1)
        return Array(response.data.prefix(limit))
    }

    /// 获取热门（日榜，用于首页精选）
    func fetchFeatured(limit: Int = 24) async throws -> [Wallpaper] {
        return try await fetchDaily(limit: limit)
    }

    /// 获取最新（日榜，用于首页最新）
    func fetchLatest(limit: Int = 8) async throws -> [Wallpaper] {
        return try await fetchDaily(limit: limit)
    }

    /// 获取 Top（周榜，用于首页 Top）
    func fetchTop(limit: Int = 8) async throws -> [Wallpaper] {
        return try await fetchWeekly(limit: limit)
    }

    /// 获取热门标签（从日榜前 50 名中提取高频标签）
    /// - Parameter limit: 返回数量，默认 6
    func fetchHotTags(limit: Int = 6) async throws -> [PixivHotTag] {
        // 从日榜前 50 名中提取标签
        let response = try await ranking(mode: "daily", page: 1, content: "illust")
        
        // 取前 50 名的标签
        let topItems = Array(response.data.prefix(50))
        
        // 统计标签出现频率
        var tagCounts: [String: Int] = [:]
        for wallpaper in topItems {
            if let tags = wallpaper.tags {
                for tag in tags {
                    tagCounts[tag.name, default: 0] += 1
                }
            }
        }
        
        // 按频率排序，取前 limit 个
        let sortedTags = tagCounts
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map { PixivHotTag(name: $0.key, count: $0.value) }
        
        return Array(sortedTags)
    }

    // MARK: - Private

    /// 默认请求头 — 使用真实浏览器 UA + Referer 避免 403
    private var defaultHeaders: [String: String] {
        [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15",
            "Referer": "https://www.pixiv.net/",
            "Accept": "application/json",
            "Accept-Language": "en-US,en;q=0.9,zh-CN;q=0.8,zh;q=0.7,ja;q=0.6"
        ]
    }

    /// 限速控制：保证两次请求之间至少有 minimumRequestInterval 间隔
    private func enforceRateLimit() async {
        let elapsed = Date().timeIntervalSince(lastRequestTime)
        if elapsed < minimumRequestInterval {
            let delay = minimumRequestInterval - elapsed
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        lastRequestTime = Date()
    }
}
