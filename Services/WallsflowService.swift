import Foundation
import SwiftSoup

// MARK: - Wallsflow 数据模型

struct WallsflowCategory: Hashable, Codable {
    let id: Int
    let name: String
    let slug: String
}

struct WallsflowListItem: Hashable, Codable {
    let id: String
    let title: String
    let detailURL: URL
    let categoryName: String
    let categorySlug: String?
    let posterURL: URL?
    let videoURL: URL?
    let rating: Int?
    let commentsCount: Int?
    let author: String?
    let authorURL: URL?
}

struct WallsflowDetail: Hashable, Codable {
    let id: String
    let title: String
    let canonicalURL: URL
    let description: String?
    let publishedAt: Date?
    let author: String?
    let authorURL: URL?
    let categoryName: String?
    let categorySlug: String?
    let posterURL: URL?
    let videoURL: URL?
    let tags: [String]
    let sourceName: String?
    let sourceURL: URL?
    let resolution: String?
    let width: Int?
    let height: Int?
    let fileSizeText: String?
    let fileSizeBytes: Int64?
    let rating: Int?
    let commentsCount: Int?
    let downloadURL: URL?
    let downloadId: String?
}

// MARK: - 分页结果

struct WallsflowListPage: Equatable {
    let items: [MediaItem]
    let nextPagePath: String?
    let totalPages: Int?
}

// MARK: - Wallsflow 分类定义

extension WallsflowCategory {
    static let allCategories: [WallsflowCategory] = [
        WallsflowCategory(id: 1,  name: "Live Wallpapers",           slug: "live-wallpapers"),
        WallsflowCategory(id: 28, name: "Winter Live Wallpapers",    slug: "winter"),
        WallsflowCategory(id: 2,  name: "Games Live Wallpapers",     slug: "games"),
        WallsflowCategory(id: 3,  name: "Cars Live Wallpapers",      slug: "cars"),
        WallsflowCategory(id: 4,  name: "Anime Live Wallpapers",     slug: "anime"),
        WallsflowCategory(id: 5,  name: "Minimalist Live Wallpapers",slug: "minimalist"),
        WallsflowCategory(id: 6,  name: "Graphics Live Wallpapers",  slug: "graphics"),
        WallsflowCategory(id: 7,  name: "Animals Live Wallpapers",   slug: "animals"),
        WallsflowCategory(id: 8,  name: "Nature Live Wallpapers",    slug: "nature"),
        WallsflowCategory(id: 9,  name: "Space Live Wallpapers",     slug: "space"),
        WallsflowCategory(id: 10, name: "Movies Live Wallpapers",    slug: "movies"),
        WallsflowCategory(id: 11, name: "People Live Wallpapers",    slug: "people"),
        WallsflowCategory(id: 12, name: "Pixel Art Live Wallpapers", slug: "pixel-art"),
        WallsflowCategory(id: 13, name: "Other Live Wallpapers",     slug: "other"),
    ]
}

// MARK: - Wallsflow 服务

/// Wallsflow.com 动态壁纸源服务
///
/// 通过 HTML 解析获取 wallsflow.com 的动态壁纸列表和详情。
/// 支持分类浏览、分页和搜索。
actor WallsflowService {
    static let shared = WallsflowService()

    private let networkService = NetworkService.shared
    private let baseURL = URL(string: "https://wallsflow.com")!
    /// WebKit follows the system route, which can differ from the app's custom proxy.
    /// Reuse that route together with its UA and cookies after a browser request succeeds.
    private let browserSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = HTTPCookieStorage.shared
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 900
        configuration.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: configuration)
    }()

    // 简易内存缓存
    private var listCache: [String: WallsflowListPage] = [:]
    private var detailCache: [String: MediaItem] = [:]

    static let siteOrigin = "https://wallsflow.com/"
    /// Cloudflare 按「出口 IP + 请求头特征」决定是否下发托管挑战：缺 Client Hints /
    /// Sec-Fetch 的稀疏头（旧版是 Safari UA + 四五个头）即使从家宽直连也会被 403 挑战。
    /// 这里对齐真实 Chrome 的文档请求头。
    static let browserUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/154.0.0.0 Safari/537.36"

    /// Chrome 的 UA 客户端提示三件套（浏览器指纹的关键部分）。
    static let clientHintHeaders: [String: String] = [
        "sec-ch-ua": "\"Chromium\";v=\"154\", \"Not:A-Brand\";v=\"24\", \"Google Chrome\";v=\"154\"",
        "sec-ch-ua-mobile": "?0",
        "sec-ch-ua-platform": "\"macOS\"",
    ]

    /// ⚠️ 文档请求严禁携带 `Sec-Fetch-*` 与 `Upgrade-Insecure-Requests`（2026-10-15 探针实测）：
    /// URLSession 直连 + 完整头 = 403 挑战页；删掉 Sec-Fetch 组立即 200（108KB 列表页）。
    /// 机制与媒体头 Origin 教训同构：CF 对「自称浏览器导航、TLS 指纹却不是浏览器」
    /// 的请求按伪装特征直接拦。裸头 + Chrome UA/CH 三件套均安全。
    private static let documentFetchHeaders: [String: String] = [:]

    private let userAgent = WallsflowService.browserUserAgent

    private var defaultHeaders: [String: String] {
        var headers: [String: String] = [
            "User-Agent": userAgent,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.9",
            "Referer": Self.siteOrigin,
            "Cache-Control": "no-cache",
        ]
        headers.merge(Self.clientHintHeaders) { _, new in new }
        headers.merge(Self.documentFetchHeaders) { _, new in new }
        return headers
    }

    private init() {}

    /// `cloud.wallsflow.com` 的 mp4 热链保护：无 Referer 会 302 到首页 HTML。
    nonisolated static func isProtectedMediaURL(_ url: URL) -> Bool {
        WallsflowMediaPolicy.owns(url)
    }

    /// 下载 / AVPlayer / 图片请求 `*.wallsflow.com` 时必须带上的头。
    ///
    /// ⚠️ 严禁同时发送 `Origin` 与 `Sec-Fetch-*`（2026-10-14 实测）：单独都 200，
    /// 组合会被 Cloudflare 当作伪装浏览器的非浏览器客户端直接 403 挑战页
    /// （与 UA/出口/代理无关，curl 直连与走代理一致复现）。媒体 CDN 零防护，裸头即通。
    nonisolated static func mediaRequestHeaders(for url: URL, pageURL: URL? = nil) -> [String: String]? {
        guard isProtectedMediaURL(url) else { return nil }
        let referer: String = {
            if let pageURL, isProtectedMediaURL(pageURL) {
                return pageURL.absoluteString
            }
            return siteOrigin
        }()
        // 图片与视频各自用对应的 Sec-Fetch-Dest；两者都保留 Client Hints 三件套。
        let isImage = ["webp", "jpg", "jpeg", "png", "gif", "avif"].contains(url.pathExtension.lowercased())
        var headers: [String: String] = [
            "User-Agent": browserUserAgent,
            "Referer": referer,
            "Accept": isImage
                ? "image/avif,image/webp,image/apng,image/*,*/*;q=0.8"
                : "*/*",
            "Accept-Language": "en-US,en;q=0.9",
            "Sec-Fetch-Dest": isImage ? "image" : "video",
            "Sec-Fetch-Mode": "no-cors",
            "Sec-Fetch-Site": "same-site",
        ]
        headers.merge(clientHintHeaders) { _, new in new }
        return headers
    }

    /// 是否为 Wallsflow 媒体项（slug / source / page host）。
    nonisolated static func isWallsflowItem(_ item: MediaItem) -> Bool {
        if item.slug.hasPrefix("wf_") || item.id.hasPrefix("wf_") {
            return true
        }
        if let host = item.pageURL.host?.lowercased(), host.contains("wallsflow.com") {
            return true
        }
        return item.sourceName.lowercased().contains("wallsflow")
    }

    // MARK: - 列表页获取

    /// 获取分类首页 / 最新列表
    func fetchCategory(slug: String, page: Int = 1) async throws -> WallsflowListPage {
        let url: URL
        if slug == "live-wallpapers" {
            // 顶级 "All" 分类，路径不含 slug
            if page <= 1 {
                url = baseURL.appendingPathComponent("live-wallpapers/")
            } else {
                url = baseURL.appendingPathComponent("live-wallpapers/page/\(page)/")
            }
        } else {
            if page <= 1 {
                url = baseURL.appendingPathComponent("live-wallpapers/\(slug)/")
            } else {
                url = baseURL.appendingPathComponent("live-wallpapers/\(slug)/page/\(page)/")
            }
        }

        let cacheKey = url.absoluteString
        if let cached = listCache[cacheKey] {
            return cached
        }

        let html = try await fetchHTML(from: url)
        let page = try parseListPage(html: html, sourceURL: url)
        listCache[cacheKey] = page
        return page
    }

    /// 获取首页 / 最新内容
    func fetchHome(page: Int = 1) async throws -> WallsflowListPage {
        // 首页没有分页，实际上首页是各分类的聚合，这里用 "live-wallpapers" 作为默认首页
        return try await fetchCategory(slug: "live-wallpapers", page: page)
    }

    // MARK: - 搜索

    /// 搜索动态壁纸
    ///
    /// 站点完整搜索只接受 **5 字段表单 POST** 到 `/index.php`
    /// （`do=search&subaction=search&search_start=N&full_search=0&story=<词>`，
    /// 2026-10-14 浏览器实测）：GET 形态与多字段 POST 均被 404/405 拒绝；
    /// 结果页卡片与列表页同构（`article` + `data-video-src`），分页靠 `search_start` 递增。
    func search(query: String, page: Int = 1) async throws -> WallsflowListPage {
        let cacheKey = "search|\(query)|\(page)"
        if let cached = listCache[cacheKey] {
            return cached
        }

        let html = try await fetchHTMLPost(
            from: URL(string: "https://wallsflow.com/index.php")!,
            formBody: [
                "do": "search",
                "subaction": "search",
                "search_start": "\(page)",
                "full_search": "0",
                "story": query,
            ]
        )
        let listPage = try parseListPage(html: html, sourceURL: baseURL)
        listCache[cacheKey] = listPage
        return listPage
    }

    // MARK: - 详情页获取

    /// 获取详情页数据
    func fetchDetail(url detailURL: URL) async throws -> MediaItem {
        let cacheKey = detailURL.absoluteString
        if let cached = detailCache[cacheKey] {
            return cached
        }

        let html = try await fetchHTML(from: detailURL)
        guard let item = try? parseDetailPage(html: html, pageURL: detailURL) else {
            throw WallsflowError.parseFailed("详情页解析失败")
        }
        detailCache[cacheKey] = item
        return item
    }

    /// 从列表项补全详情（获取视频 URL、标签等）
    ///
    /// ⚠️ 短路条件必须是「已有高清下载源（qualityRank >= 2）」而不是
    /// 「downloadOptions 非空」：列表项永远带 Preview 预览片选项，若在此短路，
    /// do=download 高清原片（Original HD）永远进不了选项池，
    /// 下载会静默落成 500K/1MB 预览片（2026-10-14 第四层闸门实锤）。
    func enrichListItem(_ item: MediaItem) async throws -> MediaItem {
        let hasHDSource = item.downloadOptions.contains { $0.qualityRank >= 2 }
        if hasHDSource {
            return item
        }
        return try await fetchDetail(url: item.pageURL)
    }

    // MARK: - 出口敏感的请求（直连优先）

    /// 抓取 HTML（列表 / 搜索 / 详情）。
    ///
    /// Wallsflow 的 Cloudflare 按**来访出口 IP 的实时信誉**决定是否下发挑战：
    /// 请求头再像浏览器也只是提高通过率（家宽动态 IP 重拨一次就可能从 200 翻成
    /// 403，2026-10-06 实测）。回退链共三级：
    /// 1. URLSession 直连（`connectionProxyDictionary = [:]`，绕开系统代理）
    /// 2. URLSession 走系统代理（覆盖"必须靠代理出网"的环境）
    /// 3. **`WallsflowWebFetcher`**：离屏 WKWebView 过挑战（非交互挑战 JS 自动
    ///    通过、用户无感），拿到 HTML 的同时把 `cf_clearance` 同步进共享 cookie
    ///    存储，后续请求可复用站点允许的会话；有效期由站点决定。
    /// 已取得浏览器会话后，页面和媒体优先使用同一 UA、Cookie 和系统代理路由。
    func fetchHTML(from url: URL) async throws -> String {
        let browserUserAgent = await WallsflowWebFetcher.shared.currentUserAgent
        var headers = defaultHeaders
        if let browserUserAgent {
            headers["User-Agent"] = browserUserAgent
            for key in Self.clientHintHeaders.keys { headers.removeValue(forKey: key) }
            var request = URLRequest(url: url)
            request.allHTTPHeaderFields = headers
            request.cachePolicy = .reloadIgnoringLocalCacheData
            do {
                let (data, response) = try await browserSession.data(for: request)
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                      http.value(forHTTPHeaderField: "cf-mitigated")?.lowercased() != "challenge" else {
                    throw WallsflowMediaPolicy.verificationRequired
                }
                return String(decoding: data, as: UTF8.self)
            } catch {
                try Task.checkCancellation()
                return try await WallsflowWebFetcher.shared.fetchHTML(from: url)
            }
        }
        do {
            return try await networkService.fetchString(
                from: url,
                headers: headers,
                bypassSystemProxy: true
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            print("[WallsflowService] 直连抓取失败，回退系统代理 | url=\(url.absoluteString) error=\(error.localizedDescription)")
            do {
                return try await networkService.fetchString(
                    from: url,
                    headers: headers,
                    bypassSystemProxy: false
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                print("[WallsflowService] 系统代理仍失败，走 WebView 过挑战 | url=\(url.absoluteString) error=\(error.localizedDescription)")
                return try await WallsflowWebFetcher.shared.fetchHTML(from: url)
            }
        }
    }

    /// POST 表单抓取（搜索专用）。
    ///
    /// 回退链与 `fetchHTML` 对齐，但 WKWebView 无法携带 HTTPBody（WebKit 已知限制），
    /// 所以第三级不是「WebView 直接 POST」，而是「WebView GET 任意页面取票
    /// （把 `cf_clearance` 与 WebView UA 同步进共享 cookie 存储）→ 重试 POST」。
    func fetchHTMLPost(from url: URL, formBody: [String: String]) async throws -> String {
        do {
            return try await postFormAttempt(url: url, formBody: formBody)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            print("[WallsflowService] 直连 POST 失败，回退系统代理 | url=\(url.absoluteString) error=\(error.localizedDescription)")
            do {
                return try await postFormAttempt(url: url, formBody: formBody, bypassSystemProxy: false)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                print("[WallsflowService] 系统代理 POST 仍失败，WebView 取票后重试 | url=\(url.absoluteString) error=\(error.localizedDescription)")
                _ = try await WallsflowWebFetcher.shared.fetchHTML(from: URL(string: Self.siteOrigin)!)
                return try await postFormAttempt(url: url, formBody: formBody)
            }
        }
    }

    /// 单次 POST 尝试：直连（`bypassSystemProxy: true`）或系统代理。
    /// 已有 WebView 取票时用同步的 UA 并去掉 Chrome 专属 Client Hints。
    private func postFormAttempt(
        url: URL,
        formBody: [String: String],
        bypassSystemProxy: Bool = true
    ) async throws -> String {
        let browserUserAgent = await WallsflowWebFetcher.shared.currentUserAgent
        var headers = defaultHeaders
        if let browserUserAgent {
            headers["User-Agent"] = browserUserAgent
            for key in Self.clientHintHeaders.keys { headers.removeValue(forKey: key) }
        }
        // 表单 POST 的真实浏览器指纹是 same-origin 文档导航
        headers["Sec-Fetch-Site"] = "same-origin"
        headers.removeValue(forKey: "Sec-Fetch-User")
        return try await networkService.fetchStringPost(
            from: url,
            formBody: formBody,
            headers: headers,
            bypassSystemProxy: bypassSystemProxy
        )
    }

    /// Images and videos share the browser identity and the same bounded WebKit fallback.
    func fetchMediaData(
        from url: URL,
        headers: [String: String],
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Data {
        try Task.checkCancellation()
        guard Self.isProtectedMediaURL(url) else { throw WallsflowError.invalidURL }
        progressHandler?(0.02)
        let userAgent = await WallsflowWebFetcher.shared.currentUserAgent
        var request = URLRequest(url: url)
        request.allHTTPHeaderFields = headers
        request = WallsflowMediaPolicy.applyingBrowserIdentity(to: request, userAgent: userAgent)
        request.cachePolicy = .reloadIgnoringLocalCacheData

        if userAgent != nil {
            do {
                let (file, response) = try await browserSession.download(for: request)
                defer { try? FileManager.default.removeItem(at: file) }
                try Task.checkCancellation()
                guard WallsflowMediaPolicy.accepts(response) else {
                    print("[WallsflowService] 媒体 browserSession 响应被拒 | status=\((response as? HTTPURLResponse)?.statusCode ?? -1) cf-mitigated=\((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "cf-mitigated") ?? "-") host=\(url.host ?? "")")
                    throw WallsflowMediaPolicy.verificationRequired
                }
                let data = try Data(contentsOf: file, options: [.mappedIfSafe])
                guard WallsflowMediaPolicy.isMedia(data) else {
                    print("[WallsflowService] 媒体 browserSession 内容非媒体 | head=\(String(data: data.prefix(80), encoding: .utf8) ?? "binary") host=\(url.host ?? "")")
                    throw WallsflowMediaPolicy.verificationRequired
                }
                progressHandler?(1)
                return data
            } catch {
                try Task.checkCancellation()
            }
        } else {
            let once = RetryConfiguration(maxRetries: 0, initialDelay: 0, maxDelay: 0,
                                          delayMultiplier: 1, allowRetryOnCellular: true)
            for bypassProxy in [true, false] {
                do {
                    let data = try await networkService.fetchData(
                        from: url, headers: request.allHTTPHeaderFields ?? [:],
                        retryConfig: once, bypassSystemProxy: bypassProxy
                    )
                    try Task.checkCancellation()
                    guard WallsflowMediaPolicy.isMedia(data) else {
                        print("[WallsflowService] 媒体 URLSession 内容非媒体 | bypass=\(bypassProxy) head=\(String(data: data.prefix(80), encoding: .utf8) ?? "binary") host=\(url.host ?? "")")
                        throw WallsflowMediaPolicy.verificationRequired
                    }
                    progressHandler?(1)
                    return data
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    print("[WallsflowService] 媒体 URLSession 失败 | bypass=\(bypassProxy) host=\(url.host ?? "") error=\(error.localizedDescription)")
                    try Task.checkCancellation()
                }
            }
        }
        try Task.checkCancellation()
        print("[WallsflowService] 媒体请求回退 WebKit | host=\(url.host ?? "")")
        let data = try await WallsflowWebFetcher.shared.fetchMediaData(for: request)
        try Task.checkCancellation()
        progressHandler?(1)
        return data
    }

    // MARK: - 清除缓存

    func clearCache() {
        listCache.removeAll()
        detailCache.removeAll()
    }
}

// MARK: - HTML 解析

private extension WallsflowService {

    /// 解析列表页 HTML
    func parseListPage(html: String, sourceURL: URL) throws -> WallsflowListPage {
        let document = try SwiftSoup.parse(html)
        // 列表卡片是 article.story；搜索结果卡片没有 story 类名但同样带 data-video-src
        // （2026-10-14 实测：搜索结果页 class="story" 计数为 0，不能用它判空）。
        let articleElements = try document.select("article.story, article[data-video-src]")
        var items: [MediaItem] = []

        for article in articleElements {
            guard let item = try? parseListItem(article: article) else { continue }
            items.append(item)
        }

        // 解析分页信息
        let totalPages = parsePagination(document: document)

        // 解析下一页路径
        let nextPagePath = parseNextPagePath(document: document, currentURL: sourceURL)

        return WallsflowListPage(
            items: items,
            nextPagePath: nextPagePath,
            totalPages: totalPages
        )
    }

    /// 解析单个列表卡片
    func parseListItem(article: Element) throws -> MediaItem? {
        // ID: 从详情链接或 data-ratig-layer-id 提取
        let detailLink = try article.select("a[href*=\"/live-wallpapers/\"][href$=\".html\"]").first()
            ?? article.select("a[href*=\"\\.html\"]").first()

        guard let link = detailLink else { return nil }

        let href = try link.attr("href")
        let fullURL: URL
        if href.hasPrefix("http") {
            guard let url = URL(string: href) else { return nil }
            fullURL = url
        } else {
            fullURL = baseURL.appendingPathComponent(href.hasPrefix("/") ? String(href.dropFirst()) : href)
        }

        // 从 URL 提取 ID
        let id = extractID(from: href) ?? fullURL.lastPathComponent.replacingOccurrences(of: ".html", with: "")

        // 标题：卡片的详情链接经常只包裹图片，名称实际放在 h2/h3、
        // aria-label、title 或 data-title 中；最后从详情 URL slug 回退。
        let title = extractListTitle(article: article, detailLink: link, pageURL: fullURL)

        // 海报/封面图
        let posterURL: URL? = {
            if let img = try? article.select("img[src*=\"cloud.wallsflow.com/posts/\"]").first(),
               let src = try? img.attr("src"),
               let url = URL(string: src) {
                return url
            }
            return nil
        }()

        // 视频 URL
        let videoURL: URL? = {
            if let videoDiv = try? article.select("[data-video-src]").first(),
               let src = try? videoDiv.attr("data-video-src"),
               let url = URL(string: src) {
                return url
            }
            // 尝试 video source[data-src]
            if let source = try? article.select("video source[data-src]").first(),
               let src = try? source.attr("data-src"),
               let url = URL(string: src) {
                return url
            }
            return nil
        }()

        // 分类
        let categoryName: String = {
            if let breadcrumb = try? article.select("a[href*=\"/live-wallpapers/\"][href$=\"/\"]").first(),
               let text = try? breadcrumb.text().trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                return text
            }
            return "Live Wallpapers"
        }()

        let _: String? = {
            if let breadcrumb = try? article.select("a[href*=\"/live-wallpapers/\"][href$=\"/\"]").first(),
               let href = try? breadcrumb.attr("href") {
                return href.trimmingCharacters(in: CharacterSet(charactersIn: "/")).split(separator: "/").last.map(String.init)
            }
            return nil
        }()

        // 评分
        let rating: Int? = {
            if let ratingSpan = try? article.select("span[data-ratig-layer-id] .ratingtypeplusminus").first(),
               let text = try? ratingSpan.text().trimmingCharacters(in: .whitespacesAndNewlines),
               let value = Int(text) {
                return value
            }
            return nil
        }()

        // 评论数
        let _: Int? = {
            if let commentsDiv = try? article.select("[title^=\"Comments:\"]").first(),
               let title = try? commentsDiv.attr("title"),
               let num = Int(title.replacingOccurrences(of: "Comments: ", with: "")) {
                return num
            }
            return nil
        }()

        // 作者
        let author: String? = {
            if let img = try? article.select("img[title^=\"Author:\"]").first(),
               let title = try? img.attr("title") {
                return title.replacingOccurrences(of: "Author: ", with: "")
            }
            return nil
        }()

        // 构建 MediaItem
        let slug = "wf_\(id)"
        let sourceNameValue = t("wallsflow")

        // 列表页仅有预览视频 URL（无高清 do=download 链接）——如实标注为 Preview。
        // 下载流程 ensureLocalVideoFile 会先 loadDetail 拿到含 Original HD 的完整选项。
        var downloadOptions: [MediaDownloadOption] = []
        if let videoURL {
            let option = MediaDownloadOption(
                label: "Preview",
                fileSizeLabel: "",
                detailText: "Preview MP4",
                remoteURL: videoURL
            )
            downloadOptions = [option]
        }

        let mediaItem = MediaItem(
            slug: slug,
            title: title,
            pageURL: fullURL,
            thumbnailURL: posterURL ?? fullURL,
            resolutionLabel: "动态壁纸",
            collectionTitle: categoryName,
            summary: nil,
            previewVideoURL: videoURL,
            posterURL: posterURL,
            tags: [categoryName].compactMap { $0 },
            exactResolution: nil,
            durationSeconds: nil,
            downloadOptions: downloadOptions,
            sourceName: sourceNameValue,
            isAnimatedImage: false,
            subscriptionCount: nil,
            favoriteCount: nil,
            viewCount: nil,
            ratingScore: rating.map(Double.init),
            authorName: author,
            authorSteamID: nil,
            authorAvatarURL: nil,
            fileSize: nil,
            createdAt: nil,
            updatedAt: nil
        )

        return mediaItem
    }

    /// 解析分页信息
    func parsePagination(document: Document) -> Int? {
        guard let pagesDiv = try? document.select("div.pages").first() else { return nil }
        let links = try? pagesDiv.select("a")
        guard let linkElements = links else { return nil }

        var maxPage = 1
        for link in linkElements {
            if let text = try? link.text(), let num = Int(text) {
                maxPage = max(maxPage, num)
            }
        }
        return maxPage > 1 ? maxPage : nil
    }

    /// 解析下一页路径
    func parseNextPagePath(document: Document, currentURL: URL) -> String? {
        // 搜索结果页的分页是 onclick=list_submit(N) 的 JS 桩（href="#"），
        // 返回 "#" 会让调用方拼出无效 URL，这里统一过滤。
        func isRealHref(_ href: String?) -> Bool {
            guard let href, !href.isEmpty, href != "#" else { return false }
            return href.hasPrefix("/") || href.hasPrefix("http")
        }

        // 1. 优先查找 span.page_next a（存在即表示有下一页）
        if let nextLink = try? document.select("span.page_next a").first(),
           isRealHref(try? nextLink.attr("href")) {
            return try? nextLink.attr("href")
        }

        // 2. fallback: 通过 pages 判断当前页和最大页
        guard let pagesDiv = try? document.select("div.pages").first() else { return nil }

        let currentPage: Int = {
            // 当前页用 span 高亮
            if let span = try? pagesDiv.select("span").first(),
               let text = try? span.text(),
               let page = Int(text) {
                return page
            }
            return 1
        }()

        let maxPage: Int = {
            var maxP = 1
            if let links = try? pagesDiv.select("a") {
                for link in links {
                    if let text = try? link.text(), let page = Int(text), page > maxP {
                        maxP = page
                    }
                }
            }
            return maxP
        }()

        // 如果当前页已经是最后一页，没有更多
        guard currentPage < maxPage else { return nil }

        // 查找下一页链接
        let nextPage = currentPage + 1
        if let nextLink = try? pagesDiv.select("a:contains(\(nextPage))").first(),
           isRealHref(try? nextLink.attr("href")) {
            return try? nextLink.attr("href")
        }

        return nil
    }

    // MARK: - 详情页解析

    /// 解析详情页 HTML
    func parseDetailPage(html: String, pageURL: URL) throws -> MediaItem? {
        let document = try SwiftSoup.parse(html)

        // 尝试 JSON-LD 解析
        var item: MediaItem? = try? parseJSONLD(document: document, pageURL: pageURL)
        if item == nil {
            // JSON-LD 失败，走 DOM 解析
            item = try? parseDetailPageDOM(document: document, pageURL: pageURL)
        }

        return item
    }

    /// JSON-LD 解析
    func parseJSONLD(document: Document, pageURL: URL) throws -> MediaItem? {
        guard let script = try? document.select("script[type=\"application/ld+json\"]").first(),
              let jsonText = try? script.html() else { return nil }

        guard let data = jsonText.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        // 可能是 @graph 数组
        let graph = json["@graph"] as? [[String: Any]] ?? (json["@graph"] == nil ? [json] : nil)
        guard let graphArray = graph else { return nil }

        // 找 Article 节点
        guard let article = graphArray.first(where: { ($0["@type"] as? String) == "Article" }) else { return nil }

        let headline = normalizedTitle(
            article["headline"] as? String ?? article["name"] as? String
        ) ?? extractDetailTitle(document: document, pageURL: pageURL)
        let description = article["description"] as? String
        // JSON-LD 的 image 可能是 String / [String] / [{url: ...}]
        let imageURL = Self.parseJSONLDImageURL(article["image"])

        // 作者
        let authorName: String? = {
            if let author = article["author"] as? [String: Any] {
                return author["name"] as? String
            }
            return nil
        }()

        let _: URL? = {
            if let author = article["author"] as? [String: Any],
               let urlStr = author["url"] as? String {
                return URL(string: urlStr).flatMap { $0.scheme != nil ? $0 : URL(string: "https://wallsflow.com\(urlStr)") }
            }
            return nil
        }()

        // 日期
        let publishedAt: Date? = {
            if let dateStr = article["datePublished"] as? String {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                return formatter.date(from: dateStr) ?? ISO8601DateFormatter().date(from: dateStr)
            }
            return nil
        }()

        // 从页面 DOM 补充视频 URL、标签等（JSON-LD 不包含这些）
        let (videoURL, tags, resolution, fileSizeText, _, _, downloadURL) = parseDetailSupplemental(document: document)

        // 从 URL 提取 ID
        let id = extractID(from: pageURL.absoluteString) ?? pageURL.lastPathComponent.replacingOccurrences(of: ".html", with: "")

        // 解析分辨率
        let (exactResolution, _, _): (String?, Int?, Int?) = parseResolution(resolution)

        // 解析文件大小
        let fileSizeBytes = parseFileSize(fileSizeText)

        // 分类
        let categoryName: String? = {
            if let breadcrumbList = graphArray.first(where: { ($0["@type"] as? String) == "BreadcrumbList" }),
               let itemListElement = breadcrumbList["itemListElement"] as? [[String: Any]],
               itemListElement.count >= 3,
               let item = itemListElement[2]["item"] as? [String: Any],
               let name = item["name"] as? String {
                return name
            }
            return nil
        }()

        let sourceNameValue = t("wallsflow")

        // 优先直链 mp4（cloud.wallsflow.com）；download.php 常回 HTML，不适合当媒体直链。
        let detailDownloadOptions = Self.makeDownloadOptions(
            videoURL: videoURL,
            downloadURL: downloadURL,
            fileSizeText: fileSizeText,
            resolution: resolution
        )

        let mediaItem = MediaItem(
            slug: "wf_\(id)",
            title: headline,
            pageURL: pageURL,
            thumbnailURL: imageURL ?? pageURL,
            resolutionLabel: resolution ?? "动态壁纸",
            collectionTitle: categoryName,
            summary: description,
            previewVideoURL: videoURL,
            posterURL: imageURL,
            tags: tags,
            exactResolution: exactResolution,
            durationSeconds: nil,
            downloadOptions: detailDownloadOptions,
            sourceName: sourceNameValue,
            isAnimatedImage: false,
            subscriptionCount: nil,
            favoriteCount: nil,
            viewCount: nil,
            ratingScore: nil,
            authorName: authorName,
            authorSteamID: nil,
            authorAvatarURL: nil,
            fileSize: fileSizeBytes,
            createdAt: publishedAt,
            updatedAt: nil
        )

        return mediaItem
    }

    /// DOM 详情页解析（JSON-LD 失败时的 fallback）
    func parseDetailPageDOM(document: Document, pageURL: URL) throws -> MediaItem? {
        // 标题：优先 h1，兼容站点改版后的 h2 / og:title，并从 URL 兜底。
        let title = extractDetailTitle(document: document, pageURL: pageURL)

        // OG 图片
        let imageURL: URL? = {
            if let meta = try? document.select("meta[property=\"og:image\"]").first(),
               let content = try? meta.attr("content"),
               let url = URL(string: content) {
                return url
            }
            return nil
        }()

        // 描述
        let description: String? = {
            if let meta = try? document.select("meta[name=\"description\"]").first(),
               let content = try? meta.attr("content"), !content.isEmpty {
                return content
            }
            if let shareData = try? document.select("[data-description]").first(),
               let desc = try? shareData.attr("data-description"), !desc.isEmpty {
                return desc
            }
            return nil
        }()

        // 补充字段
        let (videoURL, tags, resolution, fileSizeText, _, _, downloadURL) = parseDetailSupplemental(document: document)

        let id = extractID(from: pageURL.absoluteString) ?? pageURL.lastPathComponent.replacingOccurrences(of: ".html", with: "")
        let sourceNameValue = t("wallsflow")

        let (exactResolution, _, _) = parseResolution(resolution)
        let fileSizeBytes = parseFileSize(fileSizeText)

        let detailDownloadOptions = Self.makeDownloadOptions(
            videoURL: videoURL,
            downloadURL: downloadURL,
            fileSizeText: fileSizeText,
            resolution: resolution
        )

        return MediaItem(
            slug: "wf_\(id)",
            title: title,
            pageURL: pageURL,
            thumbnailURL: imageURL ?? pageURL,
            resolutionLabel: resolution ?? "动态壁纸",
            collectionTitle: nil,
            summary: description,
            previewVideoURL: videoURL,
            posterURL: imageURL,
            tags: tags,
            exactResolution: exactResolution,
            durationSeconds: nil,
            downloadOptions: detailDownloadOptions,
            sourceName: sourceNameValue,
            isAnimatedImage: false,
            subscriptionCount: nil,
            favoriteCount: nil,
            viewCount: nil,
            ratingScore: nil,
            authorName: nil,
            authorSteamID: nil,
            authorAvatarURL: nil,
            fileSize: fileSizeBytes,
            createdAt: nil,
            updatedAt: nil
        )
    }

    /// 解析详情页补充字段（视频、标签、分辨率、文件大小、来源、下载）
    func parseDetailSupplemental(document: Document) -> (videoURL: URL?, tags: [String], resolution: String?, fileSizeText: String?, sourceName: String?, sourceURL: URL?, downloadURL: URL?) {
        // 视频 URL
        let videoURL: URL? = {
            if let videoDiv = try? document.select("[data-video-src]").first(),
               let src = try? videoDiv.attr("data-video-src"),
               let url = URL(string: src) {
                return url
            }
            if let source = try? document.select("video source[data-src]").first(),
               let src = try? source.attr("data-src"),
               let url = URL(string: src) {
                return url
            }
            return nil
        }()

        // 标签（从 data-hashtags 或 /tags/ 链接）
        let tags: [String] = {
            if let hashtagEl = try? document.select("[data-hashtags]").first() {
                let html = (try? hashtagEl.attr("data-hashtags")) ?? ""
                // 提取 /tags/.../ 中的标签名
                let pattern = "/tags/([^/]+)/"
                if let regex = try? NSRegularExpression(pattern: pattern) {
                    let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
                    let matches = regex.matches(in: html, range: nsRange)
                    return matches.compactMap { match -> String? in
                        guard let range = Range(match.range(at: 1), in: html) else { return nil }
                        return String(html[range]).replacingOccurrences(of: "-", with: " ").capitalized
                    }
                }
            }
            return []
        }()

        // 分辨率
        let resolution: String? = {
            // 查找 Resolution 行
            let body = try? document.body()?.text() ?? ""
            if let bodyText = body {
                let pattern = "Resolution:\\s*([^\\n]+)"
                if let regex = try? NSRegularExpression(pattern: pattern),
                   let match = regex.firstMatch(in: bodyText, range: NSRange(bodyText.startIndex..<bodyText.endIndex, in: bodyText)),
                   let range = Range(match.range(at: 1), in: bodyText) {
                    return String(bodyText[range]).trimmingCharacters(in: .whitespaces)
                }
            }
            // 从 xfsearch/resolution/ 链接
            if let link = try? document.select("a[href*=\"/xfsearch/resolution/\"]").first(),
               let text = try? link.text().trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                return text
            }
            return nil
        }()

        // 文件大小
        let fileSizeText: String? = {
            let body = try? document.body()?.text() ?? ""
            if let bodyText = body {
                let pattern = "File size:\\s*([^\\n]+)"
                if let regex = try? NSRegularExpression(pattern: pattern),
                   let match = regex.firstMatch(in: bodyText, range: NSRange(bodyText.startIndex..<bodyText.endIndex, in: bodyText)),
                   let range = Range(match.range(at: 1), in: bodyText) {
                    return String(bodyText[range]).trimmingCharacters(in: .whitespaces)
                }
            }
            return nil
        }()

        // 来源
        let sourceName: String? = {
            let body = try? document.body()?.text() ?? ""
            if let bodyText = body {
                let pattern = "Source:\\s*([^\\n]+)"
                if let regex = try? NSRegularExpression(pattern: pattern),
                   let match = regex.firstMatch(in: bodyText, range: NSRange(bodyText.startIndex..<bodyText.endIndex, in: bodyText)),
                   let range = Range(match.range(at: 1), in: bodyText) {
                    return String(bodyText[range]).trimmingCharacters(in: .whitespaces)
                }
            }
            return nil
        }()

        // 来源 URL
        let sourceURL: URL? = {
            // Source 行通常包含链接
            if let link = try? document.select("a[href*=\"steamcommunity.com\"]").first(),
               let href = try? link.attr("href") {
                return URL(string: href)
            }
            return nil
        }()

        // 下载 URL
        let downloadURL: URL? = {
            if let link = try? document.select("a[href*=\"index.php?do=download&id=\"]").first(),
               let href = try? link.attr("href") {
                return URL(string: href.hasPrefix("http") ? href : "https://wallsflow.com\(href)")
            }
            return nil
        }()

        return (videoURL, tags, resolution, fileSizeText, sourceName, sourceURL, downloadURL)
    }

    // MARK: - 辅助方法

    /// 统一清理 Wallsflow 标题，避免列表和详情页出现不同的展示名称。
    func normalizedTitle(_ value: String?) -> String? {
        guard let value else { return nil }
        let collapsed = value
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }

        let cleaned = collapsed
            .replacingOccurrences(
                of: #"(?i)\s+live\s+wallpapers?$"#,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// 从详情 URL 的 slug 生成最后一级标题，确保卡片不会因为标题节点为空而留白。
    func titleFromURL(_ url: URL) -> String? {
        let filename = url.deletingPathExtension().lastPathComponent
        let slug = filename
            .replacingOccurrences(of: #"^\d+-"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)-wallsflow-com$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)-live-wallpapers?$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[-_]+"#, with: " ", options: .regularExpression)
        return normalizedTitle(slug)
    }

    /// 从列表卡片兼容多种标题落点。`detailLink` 的属性优先级高于普通卡片文本，
    /// 避免把分类 breadcrumb 或作者文本误当标题。
    func extractListTitle(article: Element, detailLink: Element, pageURL: URL) -> String {
        var candidates: [String] = []

        func appendAttribute(_ name: String, from element: Element) {
            if let value = try? element.attr(name), !value.isEmpty {
                candidates.append(value)
            }
        }

        // 设计文档中的主结构：h2 a；同时兼容 h3 和媒体 overlay。
        for selector in ["h2 a", "h3 a", "a[aria-label]", "[data-title]", "[data-name]"] {
            if let element = try? article.select(selector).first() {
                appendAttribute("aria-label", from: element)
                appendAttribute("data-title", from: element)
                appendAttribute("data-name", from: element)
                appendAttribute("title", from: element)
                if let text = try? element.text(), !text.isEmpty {
                    candidates.append(text)
                }
            }
        }

        appendAttribute("aria-label", from: detailLink)
        appendAttribute("data-title", from: detailLink)
        appendAttribute("data-name", from: detailLink)
        appendAttribute("title", from: detailLink)
        if let text = try? detailLink.text(), !text.isEmpty {
            candidates.append(text)
        }

        // 图片链接没有文字时，alt 往往仍保留资源名称。
        if let image = try? detailLink.select("img").first() {
            appendAttribute("alt", from: image)
            appendAttribute("title", from: image)
        }

        for candidate in candidates {
            if let title = normalizedTitle(candidate) {
                return title
            }
        }
        return titleFromURL(pageURL) ?? "Live Wallpaper"
    }

    /// 详情页标题统一从 h1/h2、OG 元数据和 URL slug 取值。
    func extractDetailTitle(document: Document, pageURL: URL) -> String {
        var candidates: [String] = []
        for selector in ["h1", "h2", "meta[property=\"og:title\"]", "meta[name=\"twitter:title\"]", "title"] {
            if let element = try? document.select(selector).first() {
                if selector.hasPrefix("meta[") {
                    if let content = try? element.attr("content"), !content.isEmpty {
                        candidates.append(content)
                    }
                } else if selector == "title" {
                    if let text = try? element.text(), !text.isEmpty {
                        candidates.append(text)
                    }
                } else if let text = try? element.text(), !text.isEmpty {
                    candidates.append(text)
                }
            }
        }

        for candidate in candidates {
            if let title = normalizedTitle(candidate) {
                return title
            }
        }
        return titleFromURL(pageURL) ?? "Live Wallpaper"
    }

    /// JSON-LD `image` 兼容 String / [String] / [{url}] 三种形态。
    nonisolated static func parseJSONLDImageURL(_ value: Any?) -> URL? {
        if let s = value as? String, let url = URL(string: s), !s.isEmpty {
            return url
        }
        if let arr = value as? [String] {
            for s in arr where !s.isEmpty {
                if let url = URL(string: s) { return url }
            }
        }
        if let arr = value as? [Any] {
            for entry in arr {
                if let s = entry as? String, let url = URL(string: s), !s.isEmpty {
                    return url
                }
                if let dict = entry as? [String: Any] {
                    if let s = dict["url"] as? String, let url = URL(string: s) {
                        return url
                    }
                    if let s = dict["contentUrl"] as? String, let url = URL(string: s) {
                        return url
                    }
                }
            }
        }
        if let dict = value as? [String: Any] {
            if let s = dict["url"] as? String, let url = URL(string: s) {
                return url
            }
            if let s = dict["contentUrl"] as? String, let url = URL(string: s) {
                return url
            }
        }
        return nil
    }

    /// 构建下载选项：`do=download` 是高清原片直链（2026-10-14 URLSession 实测直接回
    /// `video/mp4` + `attachment` 文件流：1254 号帖子 10,925,858 字节，匿名可下；
    /// 而 data-video-src 的 play.wallsflow.com 预览片仅 1,033,333 字节）。
    /// `videoURL`（预览片）只用于 hover 预览，作下载兜底。
    nonisolated static func makeDownloadOptions(
        videoURL: URL?,
        downloadURL: URL?,
        fileSizeText: String?,
        resolution: String?
    ) -> [MediaDownloadOption] {
        var options: [MediaDownloadOption] = []
        if let downloadURL {
            options.append(MediaDownloadOption(
                label: "Original HD",
                fileSizeLabel: fileSizeText ?? "",
                detailText: resolution ?? "Original MP4",
                remoteURL: downloadURL
            ))
        }
        if let videoURL {
            options.append(MediaDownloadOption(
                label: "Preview",
                fileSizeLabel: "",
                detailText: "Preview MP4",
                remoteURL: videoURL
            ))
        }
        return options
    }

    /// 从 URL 或 HTML 属性中提取数字 ID
    func extractID(from urlString: String) -> String? {
        // 模式: /{category}/{id}-{slug}.html
        let pattern = "/(\\d+)-[^/]+\\.html"
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: urlString, range: NSRange(urlString.startIndex..<urlString.endIndex, in: urlString)),
           let range = Range(match.range(at: 1), in: urlString) {
            return String(urlString[range])
        }
        return nil
    }

    /// 解析分辨率字符串
    func parseResolution(_ resolution: String?) -> (exactResolution: String?, width: Int?, height: Int?) {
        guard let res = resolution else { return (nil, nil, nil) }
        let cleaned = res
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "×", with: "x")
            .replacingOccurrences(of: "X", with: "x")
        let parts = cleaned.split(separator: "x")
        guard parts.count == 2,
              let w = Int(parts[0]),
              let h = Int(parts[1]) else {
            return (resolution, nil, nil)
        }
        return ("\(w)x\(h)", w, h)
    }

    /// 解析文件大小文本
    func parseFileSize(_ text: String?) -> Int64? {
        guard let text = text else { return nil }
        let cleaned = text.lowercased().trimmingCharacters(in: .whitespaces)
        let numberStr = cleaned.replacingOccurrences(of: #"[^0-9\.]+"#, with: "", options: .regularExpression)
        guard let value = Double(numberStr) else { return nil }

        if cleaned.contains("gb") {
            return Int64(value * 1_073_741_824)
        }
        if cleaned.contains("mb") {
            return Int64(value * 1_048_576)
        }
        if cleaned.contains("kb") {
            return Int64(value * 1_024)
        }
        return Int64(value)
    }
}

// MARK: - 错误类型

enum WallsflowError: LocalizedError {
    case parseFailed(String)
    case invalidURL
    case notFound

    var errorDescription: String? {
        switch self {
        case .parseFailed(let detail): return "Wallsflow 解析失败: \(detail)"
        case .invalidURL: return "无效的 Wallsflow URL"
        case .notFound: return "Wallsflow 内容未找到"
        }
    }
}

// Array safe subscript is provided elsewhere in the project
