import Foundation
import SwiftSoup

// MARK: - Data Models

struct Wallpaper4K: Identifiable, Codable, Equatable {
    let id: String
    let title: String
    let thumbnailURL: String
    let hdThumbnailURL: String
    let originalURL: String
    let detailURL: String
    let keywords: [String]
    let tags: [Wallpaper4KTag]
    let width: Int
    let height: Int
    let resolution: String?      // 5K, 8K, etc.
    let aspectRatio: String      // "16:9"

    struct Wallpaper4KTag: Codable, Equatable {
        let name: String
        let url: String
    }
}

/// 页面类型枚举
enum FourKPageType: String, Codable {
    case recent
    case popular
    case featured
    case random
    case category
    case tag
    case search
    case collections
}

/// 4K 源的排序选项
enum FourKSortingOption: String, CaseIterable, Identifiable {
    case latest
    case popular

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .latest: return t("sort.latest")
        case .popular: return t("sort.popular")
        }
    }
}

/// 分类模型
struct FourKCategory: Identifiable, Codable, Equatable {
    let id: String       // URL slug，如 "abstract"
    let name: String     // 显示名，如 "Abstract"
    let url: String      // 完整URL

    /// SF Symbol 图标名
    var icon: String {
        switch id {
        case "abstract": return "square.on.square.intersection.dashed"
        case "animals": return "pawprint.fill"
        case "anime": return "person.crop.rectangle.stack.fill"
        case "architecture": return "building.columns.fill"
        case "bikes": return "bicycle"
        case "black-dark": return "moon.stars.fill"
        case "cars": return "car.side.fill"
        case "celebrations": return "gift.fill"
        case "cute": return "heart.fill"
        case "fantasy": return "wand.and.stars"
        case "flowers": return "camera.macro"
        case "food": return "takeoutbag.and.cup.and.straw.fill"
        case "games": return "gamecontroller.fill"
        case "gradients": return "paintpalette.fill"
        case "graphics-cgi": return "cpu.fill"
        case "lifestyle": return "house.fill"
        case "love": return "heart.circle.fill"
        case "military": return "shield.fill"
        case "minimal": return "square.dashed"
        case "movies": return "film.stack.fill"
        case "music": return "music.note"
        case "nature": return "leaf.fill"
        case "people": return "person.fill"
        case "photography": return "camera.fill"
        case "quotes": return "text.quote"
        case "sci-fi": return "sparkles.tv"
        case "space": return "globe.americas.fill"
        case "sports": return "sportscourt.fill"
        case "technology": return "desktopcomputer"
        case "world": return "globe.europe.africa.fill"
        default: return "square.grid.2x2.fill"
        }
    }

    /// 渐变强调色（两个 hex 值）
    var accentColors: [String] {
        switch id {
        case "abstract": return ["FF6B6B", "C850C0"]
        case "animals": return ["C8A876", "8B7355"]
        case "anime": return ["FF88C7", "7747FF"]
        case "architecture": return ["63A3FF", "6D42FF"]
        case "bikes": return ["FFD66E", "FF8B3D"]
        case "black-dark": return ["8B0000", "4A0000"]
        case "cars": return ["FFB15B", "E14949"]
        case "celebrations": return ["FF6B6B", "EE5A6E"]
        case "cute": return ["FF9ED2", "C069FF"]
        case "fantasy": return ["F17CF5", "5F67FF"]
        case "flowers": return ["F6B5D4", "E85D75"]
        case "food": return ["FFD66E", "FF8B3D"]
        case "games": return ["62D4FF", "4E66FF"]
        case "gradients": return ["B1C9FF", "5B75FF"]
        case "graphics-cgi": return ["4FF4D6", "1AB9A5"]
        case "lifestyle": return ["98E978", "3AA565"]
        case "love": return ["FF69B4", "FF1493"]
        case "military": return ["7B8794", "3E4C59"]
        case "minimal": return ["A8B8C8", "6B7B8D"]
        case "movies": return ["63A3FF", "6D42FF"]
        case "music": return ["F17CF5", "5F67FF"]
        case "nature": return ["98E978", "3AA565"]
        case "people": return ["F6E0D3", "AA785F"]
        case "photography": return ["FFD66E", "FF8B3D"]
        case "quotes": return ["B1C9FF", "5B75FF"]
        case "sci-fi": return ["62D4FF", "4E66FF"]
        case "space": return ["B1C9FF", "5B75FF"]
        case "sports": return ["4CAF50", "2E7D32"]
        case "technology": return ["4FF4D6", "1AB9A5"]
        case "world": return ["5A7CFF", "20C1FF"]
        default: return ["FF9B58", "F54E42"]
        }
    }
}

/// 搜索热门标签
struct FourKSearchSuggestion: Codable {
    let keyword: String
    let url: String
    let popularity: Int  // 1-5，对应 size-1 到 size-5
}

/// 壁纸列表响应
struct Wallpaper4KList: Codable {
    let wallpapers: [Wallpaper4K]
    let currentPage: Int
    let totalPages: Int
    let hasNextPage: Bool
    let hasPreviousPage: Bool
    let pageType: FourKPageType
    let category: String?
    let searchQuery: String?
}

// MARK: - Parser Error

enum FourKWallpapersParserError: Error, LocalizedError {
    case invalidHTML
    case parsingFailed(String)
    case elementNotFound(String)

    var errorDescription: String? {
        t("error.parse.failed")
    }
}

// MARK: - Parser

final class FourKWallpapersParser {

    // MARK: - Constants

    private struct Selectors {
        // 壁纸列表
        static let picsList = "#pics-list"
        static let packsList = "#packs-list"
        static let wallpaperItem = "p.wallpapers__item"
        static let featuredItem = "p.wallpapers__item.featured"
        static let thumbnail = "img[itemprop=thumbnail]"
        static let contentUrl = "link[itemprop=contentUrl]"
        static let keywords = "meta[itemprop=keywords]"
        static let detailLink = "a.wallpapers__canvas_image"
        static let tagLink = "span.title2 a"
        static let packTitle = "span.packtitle"

        // 分页
        static let pagination = "p.pages"
        static let activePage = "strong.active"
        static let pageLinks = "p.pages a[data-ripples]"
        static let prevLink = "a.ctrl-left"
        static let nextLink = "a.ctrl-right"

        // 分类导航
        static let categoryDropdown = ".section-dropdown a"
        static let quickLinks = "#cats-list ul.cats a"

        // 搜索
        static let searchTitle = ".col-right h1"
        static let popularSearchTags = ".tags-list .tags-right a"

        // 页面标题
        static let pageTitle = "span.main h1"

        // 广告（需要过滤）
        static let ads = ".banner, .adsbygoogle"
    }

    let baseURL = "https://4kwallpapers.com"

    // MARK: - 预定义分类列表

    static let categories: [FourKCategory] = [
        FourKCategory(id: "abstract", name: "Abstract", url: "https://4kwallpapers.com/abstract/"),
        FourKCategory(id: "animals", name: "Animals", url: "https://4kwallpapers.com/animals/"),
        FourKCategory(id: "anime", name: "Anime", url: "https://4kwallpapers.com/anime/"),
        FourKCategory(id: "architecture", name: "Architecture", url: "https://4kwallpapers.com/architecture/"),
        FourKCategory(id: "bikes", name: "Bikes", url: "https://4kwallpapers.com/bikes/"),
        FourKCategory(id: "black-dark", name: "Black/Dark", url: "https://4kwallpapers.com/black-dark/"),
        FourKCategory(id: "cars", name: "Cars", url: "https://4kwallpapers.com/cars/"),
        FourKCategory(id: "celebrations", name: "Celebrations", url: "https://4kwallpapers.com/celebrations/"),
        FourKCategory(id: "cute", name: "Cute", url: "https://4kwallpapers.com/cute/"),
        FourKCategory(id: "fantasy", name: "Fantasy", url: "https://4kwallpapers.com/fantasy/"),
        FourKCategory(id: "flowers", name: "Flowers", url: "https://4kwallpapers.com/flowers/"),
        FourKCategory(id: "food", name: "Food", url: "https://4kwallpapers.com/food/"),
        FourKCategory(id: "games", name: "Games", url: "https://4kwallpapers.com/games/"),
        FourKCategory(id: "gradients", name: "Gradients", url: "https://4kwallpapers.com/gradients/"),
        FourKCategory(id: "graphics-cgi", name: "CGI", url: "https://4kwallpapers.com/graphics-cgi/"),
        FourKCategory(id: "lifestyle", name: "Lifestyle", url: "https://4kwallpapers.com/lifestyle/"),
        FourKCategory(id: "love", name: "Love", url: "https://4kwallpapers.com/love/"),
        FourKCategory(id: "military", name: "Military", url: "https://4kwallpapers.com/military/"),
        FourKCategory(id: "minimal", name: "Minimal", url: "https://4kwallpapers.com/minimal/"),
        FourKCategory(id: "movies", name: "Movies", url: "https://4kwallpapers.com/movies/"),
        FourKCategory(id: "music", name: "Music", url: "https://4kwallpapers.com/music/"),
        FourKCategory(id: "nature", name: "Nature", url: "https://4kwallpapers.com/nature/"),
        FourKCategory(id: "people", name: "People", url: "https://4kwallpapers.com/people/"),
        FourKCategory(id: "photography", name: "Photography", url: "https://4kwallpapers.com/photography/"),
        FourKCategory(id: "quotes", name: "Quotes", url: "https://4kwallpapers.com/quotes/"),
        FourKCategory(id: "sci-fi", name: "Sci-Fi", url: "https://4kwallpapers.com/sci-fi/"),
        FourKCategory(id: "space", name: "Space", url: "https://4kwallpapers.com/space/"),
        FourKCategory(id: "sports", name: "Sports", url: "https://4kwallpapers.com/sports/"),
        FourKCategory(id: "technology", name: "Technology", url: "https://4kwallpapers.com/technology/"),
        FourKCategory(id: "world", name: "World", url: "https://4kwallpapers.com/world/"),
    ]

    // MARK: - Public: Parse Wallpaper List

    /// 解析壁纸列表页面（自动识别 #pics-list / #packs-list）
    func parseWallpaperList(html: String, url: String? = nil) throws -> Wallpaper4KList {
        let document = try SwiftSoup.parse(html)

        // 判断页面类型
        let pageType = detectPageType(from: url, document: document)

        // 选择正确的列表容器
        // 注意：popular 页面也用 #pics-list（实测确认），只有 collections 页面用 #packs-list
        let containerSelector: String
        switch pageType {
        case .collections:
            containerSelector = Selectors.packsList
        default:
            containerSelector = Selectors.picsList
        }

        guard let container = try document.select(containerSelector).first() else {
            throw FourKWallpapersParserError.elementNotFound(containerSelector)
        }

        // 移除广告元素
        try removeAds(from: container)

        // 解析壁纸项
        let wallpaperElements = try container.select(Selectors.wallpaperItem)
        var wallpapers: [Wallpaper4K] = []

        for element in wallpaperElements {
            // 跳过广告残留
            let className = try? element.className()
            if let cls = className, cls.contains("banner") || cls.contains("adsbygoogle") {
                continue
            }

            if let wallpaper = try? parseWallpaperItem(element, pageType: pageType) {
                wallpapers.append(wallpaper)
            }
        }

        // 解析分页信息
        let pagination = try parsePagination(document)

        // 提取搜索关键词（仅搜索页）
        var searchQuery: String?
        if pageType == .search {
            searchQuery = extractSearchQuery(from: document)
        }

        // 推断分类名
        var category: String?
        if pageType == .category {
            category = extractCategoryFromURL(url) ?? extractCategoryFromTitle(document)
        }

        return Wallpaper4KList(
            wallpapers: wallpapers,
            currentPage: pagination.currentPage,
            totalPages: pagination.totalPages,
            hasNextPage: pagination.hasNextPage,
            hasPreviousPage: pagination.hasPreviousPage,
            pageType: pageType,
            category: category,
            searchQuery: searchQuery
        )
    }

    // MARK: - Public: Parse Categories

    /// 从 HTML 解析分类列表（如果页面结构变更，可以动态解析）
    func parseCategories(html: String) throws -> [FourKCategory] {
        let document = try SwiftSoup.parse(html)
        let links = try document.select(Selectors.categoryDropdown)

        return links.compactMap { element -> FourKCategory? in
            guard let href = try? element.attr("href"),
                  let title = try? element.text(),
                  !href.isEmpty, !title.isEmpty else { return nil }

            let slug = extractSlug(from: href)
            return FourKCategory(
                id: slug,
                name: title,
                url: href.hasPrefix("http") ? href : "\(baseURL)\(href)"
            )
        }
    }

    // MARK: - Public: Parse Search Suggestions

    /// 从搜索结果页解析热门搜索标签
    func parseSearchSuggestions(html: String) throws -> [FourKSearchSuggestion] {
        let document = try SwiftSoup.parse(html)
        let tagLinks = try document.select(Selectors.popularSearchTags)

        return tagLinks.compactMap { element -> FourKSearchSuggestion? in
            guard let href = try? element.attr("href"),
                  let text = try? element.text(),
                  !text.isEmpty else { return nil }

            // 从 class 推断热度：size-1 到 size-5
            let className = (try? element.attr("class")) ?? ""
            let popularity = extractPopularity(from: className)

            return FourKSearchSuggestion(
                keyword: text,
                url: href.hasPrefix("http") ? href : "\(baseURL)\(href)",
                popularity: popularity
            )
        }
    }

    // MARK: - Private: Parse Single Item

    private func parseWallpaperItem(_ element: Element, pageType: FourKPageType) throws -> Wallpaper4K {
        // 获取图片 ID
        let thumbnailElement = try element.select(Selectors.thumbnail).first()
        guard let thumbnailSrc = try? thumbnailElement?.attr("src"),
              let thumbnailURL = URL(string: thumbnailSrc),
              let id = extractID(from: thumbnailURL) else {
            throw FourKWallpapersParserError.parsingFailed("无法获取图片ID")
        }

        // 从缩略图 URL 或 contentUrl 中提取实际文件扩展名（原图可能是 .jpg 或 .jpeg）
        let thumbnailExt = (thumbnailSrc as NSString).pathExtension.lowercased()
        let actualExt = thumbnailExt.isEmpty ? "jpg" : thumbnailExt

        // 缩略图 URL 优先使用 HTML 里的真实 src，避免站点少数条目的路径/扩展名和推断规则不一致。
        let resolvedThumbnailURLString = thumbnailSrc.hasPrefix("http") ? thumbnailSrc : "\(baseURL)\(thumbnailSrc)"
        let thumbnailURLString = resolvedThumbnailURLString.isEmpty
            ? "\(baseURL)/images/walls/thumbs/\(id).\(actualExt)"
            : resolvedThumbnailURLString
        let hdThumbnailURLString = "\(baseURL)/images/walls/thumbs_3t/\(id).\(actualExt)"

        // 详情页链接 & 标题（提前解析，originalURL 需要 detailURL）
        let detailLinkElement = try element.select(Selectors.detailLink).first()
        let detailURLString: String
        if let href = try? detailLinkElement?.attr("href"), !href.isEmpty {
            detailURLString = href.hasPrefix("http") ? href : "\(baseURL)\(href)"
        } else {
            detailURLString = ""
        }

        // ⚠️ 注意：/images/walls/{id}.jpg 返回 404！原图在 /images/wallpapers/{name}-{W}x{H}-{id}.jpg
        // originalURL 先用占位，等 width/height 计算完再构建
        var originalURLString = ""

        // 高清图 URL（从 contentUrl 获取，优先于推断的 URL）
        // contentUrl href 是 thumbs_2t (800px)，替换为 thumbs_3t (1280px) 保证详情页清晰
        let contentUrlElement = try element.select(Selectors.contentUrl).first()
        let resolvedHDURL: String
        if let href = try? contentUrlElement?.attr("href"), !href.isEmpty {
            let fullHref = href.hasPrefix("http") ? href : "\(baseURL)\(href)"
            resolvedHDURL = fullHref.replacingOccurrences(of: "/thumbs_2t/", with: "/thumbs_3t/")
        } else {
            resolvedHDURL = hdThumbnailURLString
        }

        // 关键词
        let keywordsElement = try element.select(Selectors.keywords).first()
        let keywordsString = (try? keywordsElement?.attr("content")) ?? ""
        let keywords = keywordsString.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // 标题
        var title = (try? detailLinkElement?.attr("title")) ?? ""
        title = title.replacingOccurrences(of: " Wallpaper", with: "")

        // Collections 页面使用 .packtitle
        if title.isEmpty, pageType == .collections {
            let packTitleEl = try? element.select(Selectors.packTitle).first()
            if let packText = try? packTitleEl?.text() {
                title = packText
            }
        }

        // 标签
        let tagElements = try element.select(Selectors.tagLink)
        var tags: [Wallpaper4K.Wallpaper4KTag] = []
        for tagElement in tagElements {
            if let name = try? tagElement.text(), let href = try? tagElement.attr("href"),
               !name.isEmpty, !href.isEmpty {
                tags.append(Wallpaper4K.Wallpaper4KTag(
                    name: name,
                    url: href.hasPrefix("http") ? href : "\(baseURL)\(href)"
                ))
            }
        }

        // 图片尺寸 — 优先从 contentUrl 的 href 中提取原图分辨率
        // contentUrl 格式示例: /images/walls/preview/xxx_3840x2160.jpg 或 /images/walls/xxx_3840x2160.jpg
        let contentUrlHref = (try? contentUrlElement?.attr("href")) ?? ""
        let originalDimensions = extractDimensionsFromURL(contentUrlHref)
        
        let width: Int
        let height: Int
        if let dims = originalDimensions {
            width = dims.width
            height = dims.height
        } else {
            // 回退：从缩略图标签中读取（这是缩略图尺寸，不准确）
            let widthStr = (try? thumbnailElement?.attr("width")) ?? "0"
            let heightStr = (try? thumbnailElement?.attr("height")) ?? "0"
            let thumbWidth = Int(widthStr) ?? 0
            let thumbHeight = Int(heightStr) ?? 0
            // 从关键词中推断原图分辨率
            let inferred = inferOriginalResolution(from: keywords, thumbWidth: thumbWidth, thumbHeight: thumbHeight)
            width = inferred.width
            height = inferred.height
        }

        // 从关键词中提取分辨率
        let resolution = keywords.first { $0.matches(pattern: "^\\d+K$") }

        // 计算宽高比
        let aspectRatio = calculateAspectRatio(width: width, height: height)

        // 构建原图 URL：从详情页 URL（/{category}/{name}-{id}.html）+ width/height 直接推断
        // 格式：/images/wallpapers/{name}-{W}x{H}-{id}.{ext}
        // 优先从 contentUrl href 提取扩展名（更可靠），回退到缩略图扩展名
        let contentUrlExt = (contentUrlHref as NSString).pathExtension.lowercased()
        let originalExt = contentUrlExt.isEmpty ? actualExt : contentUrlExt

        if !detailURLString.isEmpty, width > 0, height > 0 {
            let builtURL = buildOriginalURL(from: detailURLString, width: width, height: height, fileExtension: originalExt)
            if !builtURL.isEmpty {
                originalURLString = builtURL
            } else {
                // 构建失败，存详情页链接，下载时再解析
                originalURLString = detailURLString
            }
        } else if !detailURLString.isEmpty {
            originalURLString = detailURLString
        } else {
            originalURLString = hdThumbnailURLString
        }

        return Wallpaper4K(
            id: id,
            title: title,
            thumbnailURL: thumbnailURLString,
            hdThumbnailURL: resolvedHDURL,
            originalURL: originalURLString,
            detailURL: detailURLString,
            keywords: keywords,
            tags: tags,
            width: width,
            height: height,
            resolution: resolution,
            aspectRatio: aspectRatio
        )
    }

    // MARK: - Private: Parse Pagination

    private func parsePagination(_ document: Document) throws -> (currentPage: Int, totalPages: Int, hasNextPage: Bool, hasPreviousPage: Bool) {
        let paginationElement = try? document.select(Selectors.pagination).first()

        // 没有分页元素时，默认第1页/共1页
        guard let pagination = paginationElement else {
            return (1, 1, false, false)
        }

        // 当前页
        let activePageElement = try? pagination.select(Selectors.activePage).first()
        let currentPageStr = (try? activePageElement?.attr("data-page")) ?? "1"
        let currentPage = Int(currentPageStr) ?? 1

        // 总页数：取所有页码链接中最大的数字
        // ⚠️ 不能取 last()，因为省略号后面的页码未必是最后一页
        let pageLinks = try? pagination.select(Selectors.pageLinks)
        var totalPages = currentPage
        if let links = pageLinks {
            for link in links {
                if let text = try? link.text(), let num = Int(text) {
                    totalPages = max(totalPages, num)
                }
                // 也从 href 提取（某些链接文本可能是省略号）
                if let href = try? link.attr("href"), let num = extractPageNumber(from: href) {
                    totalPages = max(totalPages, num)
                }
            }
        }

        // 是否有上/下一页
        let hasNextPage = (try? pagination.select(Selectors.nextLink).first()) != nil || currentPage < totalPages
        let hasPreviousPage = currentPage > 1

        return (currentPage, totalPages, hasNextPage, hasPreviousPage)
    }

    // MARK: - Private: Page Type Detection

    private func detectPageType(from url: String?, document: Document) -> FourKPageType {
        guard let url = url else { return .recent }

        if url.contains("/search/") || url.contains("/search?") {
            return .search
        }
        if url.contains("/most-popular-4k-wallpapers") {
            return .popular
        }
        if url.contains("/best-4k-wallpapers") {
            return .featured
        }
        if url.contains("/random-wallpapers") {
            return .random
        }
        if url.contains("/collections-packs") {
            return .collections
        }

        // 检查是否是分类/标签页（URL 中有子路径且非特殊页面）
        let path = URL(string: url)?.path ?? ""
        let segments = path.split(separator: "/").map(String.init)

        if segments.count == 1 {
            // 单层路径：可能是分类或标签
            let slug = segments[0]
            if Self.categories.contains(where: { $0.id == slug }) {
                return .category
            }
            return .tag
        }

        // 首页
        return .recent
    }

    // MARK: - Private: Helper Methods

    /// 从 URL 提取图片 ID
    private func extractID(from url: URL) -> String? {
        let path = url.path
        let filename = (path as NSString).lastPathComponent
        let id = (filename as NSString).deletingPathExtension
        return id.isEmpty ? nil : id
    }

    /// 从分页链接提取页码
    private func extractPageNumber(from href: String) -> Int? {
        guard let url = URL(string: href),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            return nil
        }
        return queryItems.first(where: { $0.name == "page" })?.value.flatMap { Int($0) }
    }

    /// 从 href 提取 slug（如 "/abstract/" → "abstract"）
    private func extractSlug(from href: String) -> String {
        let path = URL(string: href)?.path ?? href
        let components = path.split(separator: "/").map(String.init)
        return components.last ?? ""
    }

    /// 从 class 名提取热度（size-1 到 size-5）
    private func extractPopularity(from className: String) -> Int {
        // 匹配 size-N 模式
        guard let range = className.range(of: "size-(\\d)", options: .regularExpression) else {
            return 1
        }
        let numStr = String(className[range].suffix(1))
        return Int(numStr) ?? 1
    }

    /// 从搜索标题提取关键词
    private func extractSearchQuery(from document: Document) -> String? {
        guard let h1 = try? document.select(Selectors.searchTitle).first(),
              let text = try? h1.text() else {
            return nil
        }
        // 标题格式: "Search results for - {keyword}"
        if let range = text.range(of: "Search results for - ") {
            return String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    /// 从 URL 推断分类
    private func extractCategoryFromURL(_ url: String?) -> String? {
        guard let url = url else { return nil }
        let path = URL(string: url)?.path ?? ""
        let segments = path.split(separator: "/").map(String.init)
        guard let first = segments.first else { return nil }
        if Self.categories.contains(where: { $0.id == first }) {
            return first
        }
        return nil
    }

    /// 从页面标题推断分类
    private func extractCategoryFromTitle(_ document: Document) -> String? {
        guard let h1 = try? document.select(Selectors.pageTitle).first(),
              let text = try? h1.text() else {
            return nil
        }
        // 标题格式: "Anime Wallpapers"
        let categoryName = text.replacingOccurrences(of: " Wallpapers", with: "")
        return Self.categories.first(where: { $0.name == categoryName })?.id
    }

    /// 移除广告元素
    private func removeAds(from container: Element) throws {
        let ads = try container.select(Selectors.ads)
        for ad in ads {
            try? ad.remove()
        }
    }

    /// 从 URL 中提取分辨率（如 _3840x2160、-3840x2160-、3840x2160）
    private func extractDimensionsFromURL(_ urlString: String) -> (width: Int, height: Int)? {
        let normalized = urlString
            .replacingOccurrences(of: "%C3%97", with: "x", options: .caseInsensitive)
            .replacingOccurrences(of: "×", with: "x")
        let pattern = #"(?<!\d)(\d{3,5})[xX](\d{3,5})(?!\d)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        guard let match = regex.firstMatch(in: normalized, range: range),
              match.numberOfRanges >= 3,
              let widthRange = Range(match.range(at: 1), in: normalized),
              let heightRange = Range(match.range(at: 2), in: normalized),
              let width = Int(normalized[widthRange]),
              let height = Int(normalized[heightRange]),
              width > 0,
              height > 0 else {
            return nil
        }
        return (width, height)
    }

    /// 从关键词推断原图分辨率
    private func inferOriginalResolution(from keywords: [String], thumbWidth: Int, thumbHeight: Int) -> (width: Int, height: Int) {
        // 标准分辨率映射（宽×高）
        let resolutionMap: [(pattern: String, width: Int, height: Int)] = [
            ("8K", 7680, 4320),
            ("7K", 6400, 3600),
            ("6K", 5760, 3240),
            ("5K", 5120, 2880),
            ("4K", 3840, 2160),
            ("2K", 2560, 1440),
            ("1080P", 1920, 1080),
        ]

        // 从关键词匹配
        for keyword in keywords {
            let upper = keyword.uppercased()
            for entry in resolutionMap {
                if upper.contains(entry.pattern) {
                    // 如果缩略图有比例信息，用比例调整
                    if thumbWidth > 0 && thumbHeight > 0 {
                        let thumbRatio = Double(thumbWidth) / Double(thumbHeight)
                        let standardRatio = Double(entry.width) / Double(entry.height)
                        if abs(thumbRatio - standardRatio) < 0.2 {
                            return (entry.width, entry.height)
                        }
                    }
                    return (entry.width, entry.height)
                }
            }
        }

        // 没有分辨率关键词，根据缩略图比例推断为 4K 或默认
        let safeWidth = thumbWidth > 0 ? thumbWidth : 3840
        let safeHeight = thumbHeight > 0 ? thumbHeight : 2160

        if safeWidth < 100 || safeHeight < 100 {
            return (3840, 2160)
        }

        // 缩略图是缩小版，按比例放大到最近的 4K 分辨率
        let ratio = Double(safeWidth) / Double(safeHeight)
        if ratio > 2.0 {
            // 超宽屏 (32:9 等)
            return (5120, 1440)
        } else if ratio > 1.7 {
            // 16:9 等宽屏
            return (3840, 2160)
        } else if ratio > 1.5 {
            // 16:10
            return (2560, 1600)
        } else if ratio > 1.2 {
            // 4:3 或 3:2
            return (2880, 2160)
        } else {
            // 竖屏
            return (2160, 3840)
        }
    }

    /// 计算宽高比标签
    private func calculateAspectRatio(width: Int, height: Int) -> String {
        let gcd = Self.gcd(width, height)
        let w = width / gcd
        let h = height / gcd
        // 常见比例匹配
        let commonRatios: [(String, Int, Int)] = [
            ("16:9", 16, 9),
            ("16:10", 16, 10),
            ("21:9", 21, 9),
            ("32:9", 32, 9),
            ("4:3", 4, 3),
            ("3:2", 3, 2),
            ("9:16", 9, 16),
            ("10:16", 10, 16),
            ("1:1", 1, 1),
        ]
        // 允许 ±1 的误差
        for (label, rw, rh) in commonRatios {
            if abs(w * rh - h * rw) <= 1 {
                return label
            }
        }
        return "\(w):\(h)"
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var a = a, b = b
        while b != 0 { (a, b) = (b, a % b) }
        return a
    }

    // MARK: - URL Builders

    func buildListURL(category: String? = nil, page: Int = 1) -> String {
        var url = baseURL

        if let category = category {
            url += "/\(category)/"
        }

        if page > 1 {
            url += "?page=\(page)"
        }

        return url
    }

    func buildPopularURL(page: Int = 1) -> String {
        var url = "\(baseURL)/most-popular-4k-wallpapers/"
        if page > 1 { url += "?page=\(page)" }
        return url
    }

    func buildFeaturedURL(page: Int = 1) -> String {
        var url = "\(baseURL)/best-4k-wallpapers/"
        if page > 1 { url += "?page=\(page)" }
        return url
    }

    func buildRandomURL() -> String {
        "\(baseURL)/random-wallpapers/"
    }

    func buildCollectionsURL(page: Int = 1) -> String {
        var url = "\(baseURL)/collections-packs/"
        if page > 1 { url += "?page=\(page)" }
        return url
    }

    func buildSearchURL(query: String, page: Int = 1) -> String {
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        var url = "\(baseURL)/search/?q=\(encodedQuery)"
        if page > 1 {
            url += "&page=\(page)"
        }
        return url
    }

    // MARK: - Public: Parse Detail Page for Original Image URL

    /// 从详情页 HTML 中解析原图下载链接
    /// 优先返回 id="resolution" 的链接（当前选中的分辨率），其次返回最大分辨率的链接
    func parseOriginalImageURL(from html: String) -> String? {
        guard let document = try? SwiftSoup.parse(html) else { return nil }

        // 方案1：找 id="resolution" 的 <a> 标签
        if let resolutionLink = try? document.select("a#resolution").first(),
           let href = try? resolutionLink.attr("href"),
           !href.isEmpty {
            return href.hasPrefix("http") ? href : "\(baseURL)\(href)"
        }

        // 方案2：找所有 /images/wallpapers/ 链接，取最大分辨率
        let wallpaperLinks: Elements
        if let links = try? document.select("a[href^=/images/wallpapers/]") {
            wallpaperLinks = links
        } else {
            wallpaperLinks = Elements()
        }
        var bestURL: String?
        var bestPixels = 0

        for link in wallpaperLinks {
            guard let href = try? link.attr("href"), !href.isEmpty else { continue }
            let fullURL = href.hasPrefix("http") ? href : "\(baseURL)\(href)"

            // 提取分辨率
            if let dims = extractDimensionsFromURL(href) {
                let pixels = dims.width * dims.height
                if pixels > bestPixels {
                    bestPixels = pixels
                    bestURL = fullURL
                }
            } else if bestURL == nil {
                // 没有分辨率的链接，作为兜底
                bestURL = fullURL
            }
        }

        return bestURL
    }

    /// 从详情页 URL 推断原图下载 URL
    /// 详情页 URL 格式: https://4kwallpapers.com/{category}/{name}-{id}.html
    /// 原图 URL 格式:   https://4kwallpapers.com/images/wallpapers/{name}-{W}x{H}-{id}.{ext}
    private func buildOriginalURL(from detailURL: String, width: Int, height: Int, fileExtension: String = "jpg") -> String {
        // 从详情页 URL 提取路径部分
        guard let url = URL(string: detailURL) else { return "" }
        let path = url.path
        // 去掉 .html 后缀和开头的 /
        var slug = path
            .replacingOccurrences(of: ".html", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // slug 现在是 "{category}/{name}-{id}"，取最后一段
        if let lastSlash = slug.lastIndex(of: "/") {
            slug = String(slug[slug.index(after: lastSlash)...])
        }
        // slug 现在是 "{name}-{id}"，需要分离出 name 和 id
        // id 是最后一段数字（如 "26028"），name 是前面的部分
        // 用最后一个 "-" 分割
        guard let lastDash = slug.lastIndex(of: "-") else {
            return "\(baseURL)/images/wallpapers/\(slug)-\(width)x\(height).\(fileExtension)"
        }
        let namePart = String(slug[slug.startIndex..<lastDash])
        let idPart = String(slug[slug.index(after: lastDash)...])
        // 按正确格式拼接: {name}-{W}x{H}-{id}.{ext}
        return "\(baseURL)/images/wallpapers/\(namePart)-\(width)x\(height)-\(idPart).\(fileExtension)"
    }

    func buildOriginalImageURL(from wallpaper: Wallpaper4K) -> String {
        wallpaper.originalURL
    }
}

// MARK: - String Extensions

private extension String {
    func matches(pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return false
        }
        let range = NSRange(location: 0, length: utf16.count)
        return regex.firstMatch(in: self, options: [], range: range) != nil
    }
}
