import Foundation

// MARK: - Konachan 壁纸数据源服务
///
/// Konachan (https://konachan.com/) 是一个以 ACG / 二次元插画壁纸为主的 Moebooru 系站点。
/// 本 Service 负责：
///   1. 调用 Konachan JSON API (post.json / tag.json) 获取数据
///   2. 将 KonachanPost 映射为标准 Wallpaper 模型
///   3. 提供标签建议接口
///
/// API 参考: https://konachan.com/help/api
actor KonachanService {
    static let shared = KonachanService()

    private let networkService = NetworkService.shared

    /// 基础 URL
    private let primaryBaseURL = "https://konachan.net"
    private let fallbackBaseURL = "https://konachan.com"

    /// 请求限速：两次请求之间至少间隔的时间
    private let minimumRequestInterval: TimeInterval = 0.5
    private var lastRequestTime: Date = .distantPast

    // MARK: - 公开 API

    /// 搜索壁纸
    /// - Parameters:
    ///   - query: 搜索关键词（标签）
    ///   - page: 页码，从 1 开始
    ///   - perPage: 每页数量，最大 100
    ///   - purity: 内容分级选择
    ///   - sorting: 排序方式
    /// - Returns: 标准 WallpaperSearchResponse
    func search(
        query: String = "",
        page: Int = 1,
        perPage: Int = 24,
        purity: KonachanPuritySelection = .safeOnly,
        sorting: KonachanSorting = .dateAdded
    ) async throws -> WallpaperSearchResponse {
        // 构造 tags 参数
        var tags: [String] = []

        // 添加用户查询
        if !query.isEmpty {
            tags.append(query)
        }

        // 添加 purity 筛选
        let purityTags = purity.ratingTags
        if purityTags.count == 1 {
            // 单个 rating 直接添加
            tags.append(contentsOf: purityTags)
        } else if purityTags.count > 1 {
            // 多个 rating: Moebooru 标签是 AND 语义，rating:s rating:q 可能无结果
            // 保守策略：取第一个 rating 或使用默认 safe
            tags.append("rating:s")
        }

        // 添加排序
        if sorting.requiresOrderTag {
            tags.append(sorting.orderTag)
        }

        guard let primaryURL = buildURL(
            baseURL: primaryBaseURL,
            path: "/post.json",
            queryItems: [
                URLQueryItem(name: "limit", value: "\(perPage)"),
                URLQueryItem(name: "page", value: "\(page)"),
                URLQueryItem(name: "tags", value: tags.joined(separator: " "))
            ]
        ), let fallbackURL = buildURL(
            baseURL: fallbackBaseURL,
            path: "/post.json",
            queryItems: [
                URLQueryItem(name: "limit", value: "\(perPage)"),
                URLQueryItem(name: "page", value: "\(page)"),
                URLQueryItem(name: "tags", value: tags.joined(separator: " "))
            ]
        ) else {
            throw NetworkError.invalidResponse
        }

        // 限速
        await enforceRateLimit()

        let posts: [KonachanPost] = try await fetchWithFallback(
            [KonachanPost].self,
            primaryURL: primaryURL,
            fallbackURL: fallbackURL
        )

        // 映射为 Wallpaper
        let wallpapers = posts.map { $0.toWallpaper() }

        // 构造 Meta 信息
        // Konachan 不返回总数，根据返回数量判断是否有更多页
        let hasMore = posts.count >= perPage
        let estimatedLastPage = hasMore ? page + 10 : page
        let estimatedTotal = hasMore ? page * perPage + perPage : wallpapers.count

        let meta = WallpaperSearchResponse.Meta(
            query: query.isEmpty ? nil : query,
            currentPage: page,
            perPage: .int(perPage),
            total: estimatedTotal,
            lastPage: estimatedLastPage,
            seed: nil
        )

        return WallpaperSearchResponse(meta: meta, data: wallpapers)
    }

    /// 获取热门/精选壁纸（高分排序）
    func fetchFeatured(limit: Int = 24) async throws -> [Wallpaper] {
        let response = try await search(
            page: 1,
            perPage: limit,
            purity: .safeOnly,
            sorting: .score
        )
        return response.data
    }

    /// 获取最新壁纸
    func fetchLatest(limit: Int = 8) async throws -> [Wallpaper] {
        let response = try await search(
            page: 1,
            perPage: limit,
            purity: .safeOnly,
            sorting: .dateAdded
        )
        return response.data
    }

    /// 获取 Top 壁纸
    func fetchTop(limit: Int = 8) async throws -> [Wallpaper] {
        let response = try await search(
            page: 1,
            perPage: limit,
            purity: .safeOnly,
            sorting: .score
        )
        return Array(response.data.prefix(limit))
    }

    /// 标签建议
    /// - Parameters:
    ///   - query: 标签前缀
    ///   - limit: 返回数量
    /// - Returns: 匹配的标签列表
    func suggestTags(query: String, limit: Int = 10) async throws -> [KonachanTag] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return []
        }

        guard let primaryURL = buildURL(
            baseURL: primaryBaseURL,
            path: "/tag.json",
            queryItems: [
                URLQueryItem(name: "limit", value: "\(limit)"),
                URLQueryItem(name: "page", value: "1"),
                URLQueryItem(name: "name", value: query)
            ]
        ), let fallbackURL = buildURL(
            baseURL: fallbackBaseURL,
            path: "/tag.json",
            queryItems: [
                URLQueryItem(name: "limit", value: "\(limit)"),
                URLQueryItem(name: "page", value: "1"),
                URLQueryItem(name: "name", value: query)
            ]
        ) else {
            throw NetworkError.invalidResponse
        }

        await enforceRateLimit()

        let tags: [KonachanTag] = try await fetchWithFallback(
            [KonachanTag].self,
            primaryURL: primaryURL,
            fallbackURL: fallbackURL
        )

        // 按 count 降序排序，热门标签在前
        return tags.sorted { $0.count > $1.count }
    }

    /// 获取热门标签（按使用次数降序，仅 General 类型）
    /// - Parameter limit: 返回数量，默认 6
    func fetchHotTags(limit: Int = 6) async throws -> [KonachanTag] {
        guard let primaryURL = buildURL(
            baseURL: primaryBaseURL,
            path: "/tag.json",
            queryItems: [
                URLQueryItem(name: "limit", value: "\(limit)"),
                URLQueryItem(name: "page", value: "1"),
                URLQueryItem(name: "order", value: "count"),
                URLQueryItem(name: "type", value: "0")
            ]
        ), let fallbackURL = buildURL(
            baseURL: fallbackBaseURL,
            path: "/tag.json",
            queryItems: [
                URLQueryItem(name: "limit", value: "\(limit)"),
                URLQueryItem(name: "page", value: "1"),
                URLQueryItem(name: "order", value: "count"),
                URLQueryItem(name: "type", value: "0")
            ]
        ) else {
            throw NetworkError.invalidResponse
        }
        await enforceRateLimit()
        return try await fetchWithFallback(
            [KonachanTag].self,
            primaryURL: primaryURL,
            fallbackURL: fallbackURL
        )
    }
    // MARK: - Private

    /// 默认请求头与 Konachan 登录 WebView 共享同一个 User-Agent。
    ///
    /// Cloudflare 的 `cf_clearance` 会绑定浏览器标识；两端不一致会导致
    /// 用户完成验证后 API 仍被 challenge。
    private var defaultHeaders: [String: String] {
        KonachanRequestConfiguration.apiHeaders
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

    private func buildURL(baseURL: String, path: String, queryItems: [URLQueryItem]) -> URL? {
        guard var components = URLComponents(string: baseURL) else {
            return nil
        }
        components.path = path
        components.queryItems = queryItems
        return components.url
    }

    /// 带域名回退的请求方法：优先使用 konachan.net，失败时再尝试 konachan.com。
    private func fetchWithFallback<T: Decodable & Sendable>(
        _ type: T.Type,
        primaryURL: URL,
        fallbackURL: URL
    ) async throws -> T {
        do {
            return try await networkService.fetch(
                T.self,
                from: primaryURL,
                headers: defaultHeaders
            )
        } catch {
            print("[KonachanService] Primary API failed (\(primaryURL.host ?? "unknown")): \(error). Retrying fallback...")
            do {
                return try await networkService.fetch(
                    T.self,
                    from: fallbackURL,
                    headers: defaultHeaders
                )
            } catch let fallbackError as NetworkError {
                if case .loginRequired = fallbackError {
                    throw NetworkError.loginRequired(
                        message: "Konachan 请求被 Cloudflare 拦截。请在「设置 → Konachan」完成登录或人机验证后重试。"
                    )
                }
                throw fallbackError
            }
        }
    }
}

// MARK: - Konachan 分类与热门标签

extension KonachanService {
    /// 分类标签（类似 4K 的分类，按作品/风格分类）
    struct KonachanCategory: Identifiable, Hashable {
        let id: String
        let name: String
        /// 发送给 API 的查询字符串
        let query: String

        /// SF Symbol 图标名
        var icon: String {
            switch id {
            case "genshin": return "sparkles"
            case "honkai": return "star.fill"
            case "zzz": return "bolt.fill"
            case "fgo": return "shield.fill"
            case "touhou": return "cloud.fill"
            case "blue_archive": return "book.fill"
            case "azur_lane": return "ferry.fill"
            case "vocaloid": return "music.mic"
            case "landscape": return "mountain.2.fill"
            case "cyberpunk": return "cpu.fill"
            default: return "square.grid.2x2.fill"
            }
        }

        /// 渐变强调色
        var accentColors: [String] {
            switch id {
            case "genshin": return ["4FC3F7", "29B6F6"]
            case "honkai": return ["CE93D8", "AB47BC"]
            case "zzz": return ["FFE082", "FFA726"]
            case "fgo": return ["EF5350", "C62828"]
            case "touhou": return ["81D4FA", "4FC3F7"]
            case "blue_archive": return ["81C784", "388E3C"]
            case "azur_lane": return ["64B5F6", "1976D2"]
            case "vocaloid": return ["F06292", "EC407A"]
            case "landscape": return ["A5D6A7", "43A047"]
            case "cyberpunk": return ["FF8A65", "E64A19"]
            default: return ["FF9B58", "F54E42"]
            }
        }
    }

    /// 分类列表（≈ 10 个，类似 4K 源的分类）
    static let categories: [KonachanCategory] = [
        KonachanCategory(id: "genshin", name: "原神", query: "genshin_impact"),
        KonachanCategory(id: "honkai", name: "崩坏", query: "honkai_impact"),
        KonachanCategory(id: "zzz", name: "绝区零", query: "zenless_zone_zero"),
        KonachanCategory(id: "fgo", name: "Fate", query: "fate_(series)"),
        KonachanCategory(id: "touhou", name: "东方", query: "touhou"),
        KonachanCategory(id: "blue_archive", name: "蔚蓝档案", query: "blue_archive"),
        KonachanCategory(id: "azur_lane", name: "碧蓝航线", query: "azur_lane"),
        KonachanCategory(id: "vocaloid", name: "VOCALOID", query: "vocaloid"),
        KonachanCategory(id: "landscape", name: "风景", query: "landscape"),
        KonachanCategory(id: "cyberpunk", name: "赛博朋克", query: "cyberpunk_2077"),
    ]

    /// 标签名 → 中文显示名映射。未收录的标签自动将下划线替换为空格。
    private static let tagDisplayNames: [String: String] = [
        "long_hair": "长发",
        "blush": "脸红",
        "short_hair": "短发",
        "thighhighs": "过膝袜",
        "brown_hair": "棕发",
        "blonde_hair": "金发",
        "black_hair": "黑发",
        "blue_eyes": "蓝眼",
        "red_eyes": "红眼",
        "twintails": "双马尾",
        "dress": "连衣裙",
        "animal_ears": "兽耳",
        "skirt": "短裙",
        "school_uniform": "制服",
        "swimsuit": "泳装",
        "glasses": "眼镜",
        "smile": "微笑",
        "weapon": "武器",
        "wings": "翅膀",
        "hat": "帽子",
        "sky": "天空",
        "clouds": "云",
        "water": "水",
        "night": "夜晚",
        "rain": "雨",
        "snow": "雪",
        "building": "建筑",
        "city": "城市",
        "tree": "树",
        "maid": "女仆",
        "bikini": "比基尼",
        "kimono": "和服",
        "armor": "铠甲",
        "headphones": "耳机",
    ]

    /// 获取标签的中文显示名
    static func displayName(for tagName: String) -> String {
        if let localized = tagDisplayNames[tagName] { return localized }
        return tagName.replacingOccurrences(of: "_", with: " ")
    }
}
