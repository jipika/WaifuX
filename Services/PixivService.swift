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
    ///   - content: 可选，内容类型（illust/manga/ugoira）。传 nil 时走 API 默认（illust+manga 混合）
    /// - Returns: 标准 WallpaperSearchResponse
    func ranking(
        mode: String = "daily",
        page: Int = 1,
        date: String? = nil,
        content: String? = "illust"
    ) async throws -> WallpaperSearchResponse {
        guard var components = URLComponents(string: baseURL) else {
            throw NetworkError.invalidResponse
        }
        components.path = "/ranking.php"
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "mode", value: mode),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "p", value: "\(page)")
        ]
        if let content = content {
            queryItems.append(URLQueryItem(name: "content", value: content))
        }
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
            // Pixiv 对 R18 排行榜在未登录时返回 403：明确转译为"需要登录"，便于 UI 引导用户
            if case NetworkError.httpError(403) = error, mode.lowercased().contains("r18") {
                print("⚠️ [PixivService] R18 排行榜 403：需要登录 Pixiv 账号")
                throw NetworkError.loginRequired(message: "Pixiv R18 排行榜需要登录后才能查看，请先在设置中登录 Pixiv 账号")
            }
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
    ///   - workType: 作品类型（映射到 URL path 而非 query 参数）
    ///     - `.all` / `.illust` / `.illust_and_ugoira` → /ajax/search/artworks/{word}（插画+漫画混合）
    ///     - `.manga` → /ajax/search/manga/{word}（仅漫画）
    ///     - `.ugoira` → /ajax/search/artworks/{word} + 客户端按 illustType==2 过滤（无独立 endpoint，分页不精确）
    ///   - aiType: Pixiv Web 搜索 ai_type 参数。0=全部（默认）；1=屏蔽 AI（仅传此值有效）
    /// - Note: Pixiv Web 搜索 API 不支持 query 形式的 `type` 参数过滤；必须通过 URL path 前缀区分类型。
    /// - Returns: 标准 WallpaperSearchResponse
    func search(
        word: String,
        page: Int = 1,
        sort: String = "date_d",
        mode: String = "all",
        workType: PixivWorkType = .all,
        aiType: Int? = nil
    ) async throws -> (WallpaperSearchResponse, relatedTags: [String]) {
        // Pixiv Web 搜索 API 没有 ugoira 端点（/ajax/search/ugoira/{word} 404），
        // 且 /ajax/search/artworks/{word} 返回数据中不含 illustType==2 的 ugoira 作品。
        // 因此在搜索模式下遇到 ugoira 直接返回空结果，引导用户改用排行榜的 ugoira 分类。
        if workType == .ugoira {
            print("⚠️ [PixivService] 搜索模式下选择 ugoira：Pixiv Web 搜索 API 不支持 ugoira 类型，返回空结果。请改用排行榜模式。")
            let empty = WallpaperSearchResponse(
                meta: WallpaperSearchResponse.Meta(
                    query: word, currentPage: page, perPage: .int(0), total: 0, lastPage: 1, seed: nil),
                data: []
            )
            return (empty, relatedTags: [])
        }

        guard var components = URLComponents(string: baseURL) else {
            throw NetworkError.invalidResponse
        }
        // URLComponents 会自动对 path 进行编码，不需要手动编码
        // Pixiv Web 搜索按 path 前缀区分类型：
        //   - /ajax/search/artworks/{word} → 全部（插画+漫画混合；不含 ugoira）
        //   - /ajax/search/manga/{word}    → 仅漫画
        //   - /ajax/search/ugoira/{word}   → 不存在（404）
        let searchPath: String
        switch workType {
        case .manga:
            searchPath = "/ajax/search/manga/\(word)"
        case .ugoira:
            // 上面的 early-return 已经拦截，此分支保留为防御性代码
            searchPath = "/ajax/search/artworks/\(word)"
        case .all, .illust:
            searchPath = "/ajax/search/artworks/\(word)"
        }
        components.path = searchPath
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "word", value: word),
            URLQueryItem(name: "order", value: sort),
            URLQueryItem(name: "mode", value: mode),
            URLQueryItem(name: "p", value: "\(page)"),
            URLQueryItem(name: "s_mode", value: "s_tag")
        ]
        // Pixiv Web：ai_type=1 表示屏蔽 AI 作品；其余值（包括 0/2）均视为不过滤
        if let aiType = aiType, aiType == 1 {
            queryItems.append(URLQueryItem(name: "ai_type", value: "1"))
        }

        guard let url = components.url else {
            throw NetworkError.invalidResponse
        }

        print("🔍 [PixivService] ========== Search Request ==========")
        print("🔍 [PixivService] URL: \(url.absoluteString)")
        print("🔍 [PixivService] Params: word=\(word), workType=\(workType.rawValue), mode=\(mode), sort=\(sort), page=\(page)")
        print("🔍 [PixivService] Headers: \(defaultHeaders)")
        await enforceRateLimit()

        // 使用 networkService 发起请求（携带 defaultHeaders），与 ranking/illustDetail 等方法保持一致
        do {
            let data = try await networkService.fetchData(from: url, headers: defaultHeaders)

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
            let rawItems = decoded.body.illustManga.data
            // 客户端类型过滤：Pixiv Web 搜索 API 不按 query 参数 `type` 返回过滤结果，需在客户端按 illustType 再筛一次
            //   illustType: 0 = illust, 1 = manga, 2 = ugoira
            //   注意：.ugoira 已在方法入口 early-return，这里仅处理 illust / manga / all
            let filteredItems: [PixivSearchItem]
            switch workType {
            case .illust:
                filteredItems = rawItems.filter { $0.illustType == 0 }
            case .manga:
                // 已通过 URL path 在服务端过滤，这里兜底
                filteredItems = rawItems.filter { $0.illustType == 1 }
            case .all, .ugoira:
                filteredItems = rawItems
            }
            let wallpapers = filteredItems.map { $0.toWallpaper() }
            let block = decoded.body.illustManga
            let relatedTags = decoded.body.relatedTags ?? []

            let meta = WallpaperSearchResponse.Meta(
                query: word,
                currentPage: page,
                perPage: .int(filteredItems.count),
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

    /// 漫画分镜页列表（多页漫画专用）
    /// - Parameter id: 作品 ID
    /// - Returns: 每页 URL 集合
    func mangaPages(id: String) async throws -> [PixivMangaPageEntry] {
        guard let url = URL(string: "\(baseURL)/ajax/illust/\(id)/pages") else {
            throw NetworkError.invalidResponse
        }

        await enforceRateLimit()

        let response = try await networkService.fetch(
            PixivMangaPagesResponse.self,
            from: url,
            headers: defaultHeaders
        )

        guard !response.error else {
            throw NetworkError.invalidResponse
        }

        return response.body
    }

    /// 漫画系列章节列表
    /// - Parameter seriesId: 系列 ID
    /// - Returns: 系列元信息 + 章节列表
    func seriesChapters(seriesId: String) async throws -> PixivSeriesBody {
        guard let url = URL(string: "\(baseURL)/ajax/series/\(seriesId)") else {
            throw NetworkError.invalidResponse
        }

        await enforceRateLimit()

        let response = try await networkService.fetch(
            PixivSeriesResponse.self,
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
    /// Accept 字段故意仿 Safari 真实浏览器格式（含 image/* 等），降低 Cloudflare
    /// 把请求识别为脚本的概率；Pixiv 的 JSON API 也接受该 Accept。
    private var defaultHeaders: [String: String] {
        [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15",
            "Referer": "https://www.pixiv.net/",
            "Origin": "https://www.pixiv.net",
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7",
            "Accept-Language": "en-US,en;q=0.9,zh-CN;q=0.8,zh;q=0.7,ja;q=0.6",
            "Accept-Encoding": "gzip, deflate, br",
            "Sec-Fetch-Dest": "document",
            "Sec-Fetch-Mode": "navigate",
            "Sec-Fetch-Site": "same-origin",
            "Sec-Ch-Ua": "\"Chromium\";v=\"130\", \"Not(A:Brand\";v=\"24\"",
            "Sec-Ch-Ua-Mobile": "?0",
            "Sec-Ch-Ua-Platform": "\"macOS\"",
            "Upgrade-Insecure-Requests": "1"
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
