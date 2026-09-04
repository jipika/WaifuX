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

    // 简易内存缓存
    private var listCache: [String: WallsflowListPage] = [:]
    private var detailCache: [String: MediaItem] = [:]

    static let siteOrigin = "https://wallsflow.com/"
    static let browserUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    private let userAgent = WallsflowService.browserUserAgent

    private var defaultHeaders: [String: String] {
        [
            "User-Agent": userAgent,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.9",
            "Referer": Self.siteOrigin,
            "Cache-Control": "no-cache",
        ]
    }

    private init() {}

    /// `cloud.wallsflow.com` 的 mp4 热链保护：无 Referer 会 302 到首页 HTML。
    nonisolated static func isProtectedMediaURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host.contains("wallsflow.com")
    }

    /// 下载 / AVPlayer 请求 `cloud.wallsflow.com` 时必须带上的头。
    nonisolated static func mediaRequestHeaders(for url: URL, pageURL: URL? = nil) -> [String: String]? {
        guard isProtectedMediaURL(url) else { return nil }
        let referer: String = {
            if let pageURL,
               let host = pageURL.host?.lowercased(),
               host.contains("wallsflow.com") {
                return pageURL.absoluteString
            }
            return siteOrigin
        }()
        return [
            "User-Agent": browserUserAgent,
            "Referer": referer,
            "Accept": "*/*",
            "Accept-Language": "en-US,en;q=0.9",
            "Origin": "https://wallsflow.com",
        ]
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

        let html = try await networkService.fetchString(from: url, headers: defaultHeaders)
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
    func search(query: String, page: Int = 1) async throws -> WallsflowListPage {
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let url = URL(string: "https://wallsflow.com/index.php?do=search&subaction=search&search_start=\(page)&full_search=0&result_from=\(1 + (page - 1) * 10)&story=\(encodedQuery)")!

        let cacheKey = url.absoluteString
        if let cached = listCache[cacheKey] {
            return cached
        }

        let html = try await networkService.fetchString(from: url, headers: defaultHeaders)
        let page = try parseListPage(html: html, sourceURL: url)
        listCache[cacheKey] = page
        return page
    }

    // MARK: - 详情页获取

    /// 获取详情页数据
    func fetchDetail(url detailURL: URL) async throws -> MediaItem {
        let cacheKey = detailURL.absoluteString
        if let cached = detailCache[cacheKey] {
            return cached
        }

        let html = try await networkService.fetchString(from: detailURL, headers: defaultHeaders)
        guard let item = try? parseDetailPage(html: html, pageURL: detailURL) else {
            throw WallsflowError.parseFailed("详情页解析失败")
        }
        detailCache[cacheKey] = item
        return item
    }

    /// 从列表项补全详情（获取视频 URL、标签等）
    func enrichListItem(_ item: MediaItem) async throws -> MediaItem {
        // 如果已经有完整数据，直接返回
        if !item.downloadOptions.isEmpty || item.previewVideoURL != nil {
            return item
        }
        return try await fetchDetail(url: item.pageURL)
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
        let articleElements = try document.select("article.story")
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

        // 从视频 URL 创建下载选项（列表页仅有视频 URL，无文件大小信息）
        var downloadOptions: [MediaDownloadOption] = []
        if let videoURL {
            let option = MediaDownloadOption(
                label: "Original",
                fileSizeLabel: "",
                detailText: "Original MP4",
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
        // 1. 优先查找 span.page_next a（存在即表示有下一页）
        if let nextLink = try? document.select("span.page_next a").first(),
           let href = try? nextLink.attr("href"),
           !href.isEmpty {
            return href
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
           let href = try? nextLink.attr("href") {
            return href
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

    /// 构建下载选项：始终优先 `cloud.wallsflow.com` 直链 mp4。
    nonisolated static func makeDownloadOptions(
        videoURL: URL?,
        downloadURL: URL?,
        fileSizeText: String?,
        resolution: String?
    ) -> [MediaDownloadOption] {
        // download.php 往往回 HTML 页面，不能当媒体文件直链；仅作最后兜底。
        let preferred = videoURL ?? downloadURL
        guard let preferred else { return [] }
        return [
            MediaDownloadOption(
                label: "Original",
                fileSizeLabel: fileSizeText ?? "",
                detailText: resolution ?? "Original MP4",
                remoteURL: preferred
            )
        ]
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
