import Foundation

// MARK: - 4KWallpapers 备用数据源服务
///
/// 当 Wallhaven 主站不可用时，4KWallpapers 作为第二级回退源。
/// 4KWallpapers.com 没有 JSON API，需要通过 HTML 抓取 + SwiftSoup 解析获取数据。
/// 本 Service 负责：
///   1. 调用 4KWallpapers.com 获取 HTML
///   2. 使用 FourKWallpapersParser 解析 HTML
///   3. 将 Wallpaper4K 映射为标准 Wallpaper 模型（下游 UI 完全无感知）
actor FourKWallpapersService {
    static let shared = FourKWallpapersService()

    private let networkService = NetworkService.shared
    private let parser = FourKWallpapersParser()

    /// 详情页 → 原图 URL 的进程内缓存。
    /// 列表阶段已不再猜测原图尺寸，下载/设为壁纸时都会走一次详情页解析；
    /// 同一张图可能被「预览 → 下载 → 设为壁纸」多次触达，缓存避免重复抓取同一页。
    private var originalURLCache: [String: String] = [:]
    private let originalURLCacheLimit = 200

    // MARK: - 公开 API

    /// 搜索壁纸（映射为标准 WallpaperSearchResponse 格式）
    func search(
        query: String = "",
        page: Int = 1,
        perPage: Int = 24,
        category: String? = nil,
        purity: String = "sfw",
        usePopular: Bool = false
    ) async throws -> WallpaperSearchResponse {
        let url: String
        if !query.isEmpty {
            url = parser.buildSearchURL(query: query, page: page)
        } else if usePopular {
            if let category = category {
                // 4K 没有 popular+category 组合，回退到分类页（最新）
                url = parser.buildListURL(category: category, page: page)
            } else {
                url = parser.buildPopularURL(page: page)
            }
        } else if let category = category {
            url = parser.buildListURL(category: category, page: page)
        } else {
            url = parser.buildListURL(page: page)
        }

        let html = try await fetchHTML(from: url)
        let result = try parser.parseWallpaperList(html: html, url: url)

        let wallpapers = result.wallpapers.map { mapToWallpaper($0) }

        // 构造兼容的 meta 信息
        let meta = WallpaperSearchResponse.Meta(
            query: query.isEmpty ? nil : query,
            currentPage: result.currentPage,
            perPage: .int(perPage),
            total: result.totalPages * perPage,   // 估算总数
            lastPage: result.totalPages,
            seed: nil
        )

        return WallpaperSearchResponse(meta: meta, data: wallpapers)
    }

    /// 获取精选/热门壁纸（首页轮播用）
    func fetchFeatured(limit: Int = 24) async throws -> [Wallpaper] {
        let url = parser.buildPopularURL(page: 1)
        let html = try await fetchHTML(from: url)
        let result = try parser.parseWallpaperList(html: html, url: url)
        return result.wallpapers.prefix(limit).map { mapToWallpaper($0) }
    }

    /// 获取最新壁纸
    func fetchLatest(limit: Int = 8) async throws -> [Wallpaper] {
        let url = parser.buildListURL(page: 1)
        let html = try await fetchHTML(from: url)
        let result = try parser.parseWallpaperList(html: html, url: url)
        return result.wallpapers.prefix(limit).map { mapToWallpaper($0) }
    }

    /// 获取 Top 壁纸（热门排序）
    func fetchTop(limit: Int = 8) async throws -> [Wallpaper] {
        let url = parser.buildPopularURL(page: 1)
        let html = try await fetchHTML(from: url)
        let result = try parser.parseWallpaperList(html: html, url: url)
        return result.wallpapers.prefix(limit).map { mapToWallpaper($0) }
    }

    /// 获取指定分类的壁纸
    func fetchCategory(_ category: String, page: Int = 1) async throws -> WallpaperSearchResponse {
        try await search(page: page, category: category)
    }

    /// 获取可用分类列表
    func getCategories() -> [FourKCategory] {
        FourKWallpapersParser.categories
    }

    /// 从详情页解析原图下载 URL
    /// 4KWallpapers 的原图 URL（/images/wallpapers/{name}-{W}x{H}-{id}.jpg）只能从详情页获取
    /// - Parameter wallpaper: 标准 Wallpaper 模型（需要包含 url 字段即详情页链接）
    /// - Returns: 原图 URL 字符串，失败返回 nil
    func fetchOriginalImageURL(for wallpaper: Wallpaper) async -> String? {
        // 4K 壁纸的 url 字段存的是详情页链接
        let detailURLString = wallpaper.url
        guard !detailURLString.isEmpty else {
            return nil
        }

        // 列表阶段已确认过原图（contentUrl 自带分辨率）时直接复用，不必再抓详情页
        let knownOriginal = wallpaper.thumbs.original
        if knownOriginal.contains("/images/wallpapers/") {
            return knownOriginal
        }

        if let cached = originalURLCache[detailURLString] {
            return cached
        }

        do {
            let html = try await fetchHTML(from: detailURLString)
            guard let resolved = parser.parseOriginalImageURL(from: html) else {
                return nil
            }
            if originalURLCache.count >= originalURLCacheLimit {
                originalURLCache.removeAll(keepingCapacity: true)
            }
            originalURLCache[detailURLString] = resolved
            return resolved
        } catch {
            return nil
        }
    }

    // MARK: - HTML 获取

    private func fetchHTML(from urlString: String) async throws -> String {
        guard let url = URL(string: urlString) else {
            throw NetworkError.invalidResponse
        }

        // ⚠️ 必须显式伪装成浏览器。
        //
        // 2026-11-02 实测（同一台机、同一出口、同一个 URL 反复 12 次）：
        //   · 不发 User-Agent（URLSession 默认发 `WaifuX/38.0.154 CFNetwork/1496.0.7 Darwin/…`）
        //     → Cloudflare 直接 **403**，正文是 4909B 的挑战页，`#pics-list` 不存在。
        //   · 发任意浏览器 UA → **200**，正文 45KB，`#pics-list` 齐全。
        // 这就是「源看着是通的，但 App 里一加载就空」的真凶：命令行用 curl/裸 URLSession
        // 测会得到 200（curl 自带 UA 不在黑名单里），只有 App 进程内的默认 CFNetwork UA 被拦。
        //
        // 头部对齐真实 Chrome 文档请求；`sec-ch-ua` 一律不发（与 Wallsflow 的
        // 诱饵页教训相同，带占位品牌会换回 200 的假页面）。
        let html: String = try await networkService.fetchString(
            from: url,
            headers: Self.browserLikeHeaders
        )

        return html
    }

    /// 伪装浏览器所需的请求头。UA 与 Wallsflow 共用同一份常量，避免各处漂移。
    static var browserLikeHeaders: [String: String] {
        [
            "User-Agent": WallsflowService.browserUserAgent,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.9",
            "sec-fetch-dest": "document",
            "sec-fetch-mode": "navigate",
            "sec-fetch-site": "none",
            "sec-fetch-user": "?1",
            "upgrade-insecure-requests": "1",
            "sec-ch-ua-mobile": "?0",
            "sec-ch-ua-platform": "\"macOS\"",
        ]
    }

    // MARK: - 字段映射：Wallpaper4K → Wallpaper

    private func mapToWallpaper(_ w: Wallpaper4K) -> Wallpaper {
        // 缩略图 — 使用实际可访问的 URL
        // thumbs_2t (~800px) 用于网格卡片首选（384×216pt@2x 需求红线 691px，够且省 5–10 倍带宽）
        // thumbs_3t (~1280px) 用于详情页/轮播图/全屏高清预览（path 保持 3t 档）
        // thumbs (~400px) 用于列表小缩略图
        // 判断 originalURL 是否是站点确认过的原图 URL（/images/wallpapers/{name}-{W}x{H}-{id}）
        // ⚠️ 只有 contentUrl 自带分辨率时解析器才会拼这个 URL（见 parseWallpaperItem）。
        //    靠着关键词猜测拼出来的错误尺寸站点也返回 200，会静默给出裁切图，必须排除。
        let isConfirmedOriginal = w.originalURL.contains("/images/wallpapers/") && w.originalURL.contains("x")
        let thumbs = Wallpaper.Thumbs(
            large: w.mediumThumbnailURL.isEmpty ? w.hdThumbnailURL : w.mediumThumbnailURL,  // 网格卡片首选（2t，800px）
            original: isConfirmedOriginal ? w.originalURL : w.hdThumbnailURL,  // 原图 URL（用于下载），未确认时退 3t 高清
            small: w.thumbnailURL                                           // 列表小缩略图（~400px）
        )

        // 从关键词推断分类
        let category = inferCategory(from: w.keywords, tags: w.tags)

        // 分辨率
        let width = max(w.width, 100)
        let height = max(w.height, 100)
        let resolution = "\(width)x\(height)"
        let ratio = height > 0 ? String(format: "%.2f", Double(width) / Double(height)) : "1.78"

        // 标签
        let wallpaperTags = w.tags.enumerated().map { index, tag in
            Wallpaper.Tag(id: index, name: tag.name, alias: nil)
        }

        // path 用于 fullImageURL（详情页/全屏查看/设为壁纸），优先原图 URL（4K+），回退 hdThumbnailURL
        let imagePath = isConfirmedOriginal ? w.originalURL : w.hdThumbnailURL

        // 文件类型推断
        let detectedFileType: String
        if w.originalURL.hasSuffix(".png") {
            detectedFileType = "image/png"
        } else if w.originalURL.hasSuffix(".webp") {
            detectedFileType = "image/webp"
        } else {
            detectedFileType = "image/jpeg"
        }

        return Wallpaper(
            id: "4k_\(w.id)",
            title: nil,
            url: w.detailURL,
            shortUrl: nil,
            views: 0,
            favorites: 0,
            downloads: nil,
            source: "4kwallpapers",
            purity: "sfw",   // 4KWallpapers 默认都是 SFW
            category: category,
            dimensionX: width,
            dimensionY: height,
            resolution: resolution,
            ratio: ratio,
            fileSize: nil,
            fileType: detectedFileType,
            createdAt: nil,
            colors: [],
            path: imagePath,
            thumbs: thumbs,
            tags: wallpaperTags.isEmpty ? nil : wallpaperTags,
            uploader: nil
        )
    }

    // MARK: - 辅助方法

    /// 从关键词和标签推断分类（映射到 Wallhaven 的 general/anime/people）
    private func inferCategory(from keywords: [String], tags: [Wallpaper4K.Wallpaper4KTag]) -> String {
        let allText = (keywords + tags.map(\.name)).joined(separator: " ").lowercased()

        // 动漫相关
        let animeKeywords = ["anime", "manga", "otaku", "waifu", "kawaii", "cute", "kawaii"]
        if animeKeywords.contains(where: { allText.contains($0) }) {
            return "anime"
        }

        // 人物相关
        let peopleKeywords = ["people", "girl", "woman", "man", "boy", "portrait", "model"]
        if peopleKeywords.contains(where: { allText.contains($0) }) {
            return "people"
        }

        // 默认 general
        return "general"
    }
}
