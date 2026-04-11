import Foundation
import SwiftSoup

actor MediaService {
    static let shared = MediaService()

    private let networkService = NetworkService.shared
    private let htmlParser = HTMLParser.shared

    // MARK: - LRU Cache with Size Limit
    private final class LRUCache<Key: Hashable, Value> {
        private let maxSize: Int
        private var cache: [Key: Value] = [:]
        private var accessOrder: [Key] = []
        private let lock = NSLock()

        init(maxSize: Int) {
            self.maxSize = maxSize
        }

        func get(_ key: Key) -> Value? {
            lock.lock()
            defer { lock.unlock() }

            guard let value = cache[key] else { return nil }

            // Move to front (most recently used)
            if let index = accessOrder.firstIndex(of: key) {
                accessOrder.remove(at: index)
            }
            accessOrder.append(key)

            return value
        }

        func set(_ key: Key, _ value: Value) {
            lock.lock()
            defer { lock.unlock() }

            // If key exists, update and move to front
            if cache[key] != nil {
                cache[key] = value
                if let index = accessOrder.firstIndex(of: key) {
                    accessOrder.remove(at: index)
                }
                accessOrder.append(key)
                return
            }

            // Evict oldest if at capacity
            if cache.count >= maxSize, let oldestKey = accessOrder.first {
                cache.removeValue(forKey: oldestKey)
                accessOrder.removeFirst()
            }

            cache[key] = value
            accessOrder.append(key)
        }

        func remove(_ key: Key) -> Value? {
            lock.lock()
            defer { lock.unlock() }

            if let index = accessOrder.firstIndex(of: key) {
                accessOrder.remove(at: index)
            }
            return cache.removeValue(forKey: key)
        }

        func removeAll() {
            lock.lock()
            defer { lock.unlock() }

            cache.removeAll()
            accessOrder.removeAll()
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return cache.count
        }
    }

    private let listCache = LRUCache<String, MediaListPage>(maxSize: 50)
    private let detailCache = LRUCache<String, MediaItem>(maxSize: 100)

    private var config: MediaSourceProfile {
        DataSourceProfileStore.activeProfile().media
    }

    private var baseURL: URL {
        URL(string: config.baseURL) ?? URL(string: "https://motionbgs.com")!
    }

    private var htmlHeaders: [String: String] {
        config.headers
    }

    func clearCache() async {
        listCache.removeAll()
        detailCache.removeAll()
        print("[MediaService] 🗑️ 缓存已清除")
    }

    /// 清除特定 URL 的缓存
    func clearCache(for url: URL) async {
        let cacheKey = url.absoluteString
        if listCache.remove(cacheKey) != nil {
            print("[MediaService] 🗑️ 已清除缓存: \(cacheKey)")
        }
    }

    func fetchPage(source: MediaRouteSource, pagePath: String? = nil) async throws -> MediaListPage {
        print("[MediaService] fetchPage ENTERED: source=\(source)")
        print("[MediaService] config: baseURL=\(config.baseURL)")
        print("[MediaService] config: routes home=\(config.routes.home)")
        print("[MediaService] activeProfile: \(DataSourceProfileStore.activeProfile().name)")

        let url = try makePageURL(source: source, pagePath: pagePath)
        let cacheKey = url.absoluteString

        print("[MediaService] fetchPage: source=\(source), url=\(url)")

        if let cached = listCache.get(cacheKey) {
            print("[MediaService] fetchPage: returning cached data")
            return cached
        }

        print("[MediaService] fetchPage: headers=\(htmlHeaders)")

        // 添加超时保护
        let html: String
        do {
            html = try await withTimeout(seconds: 30) {
                try await self.networkService.fetchString(from: url, headers: self.htmlHeaders)
            }
        } catch {
            print("[MediaService] fetchPage: network request failed: \(error)")
            throw error
        }

        print("[MediaService] fetchPage: received html length=\(html.count)")
        let page = parseListPage(html: html, source: source, pageURL: url)
        listCache.set(cacheKey, page)
        return page
    }

    // 添加超时辅助函数
    private func withTimeout<T: Sendable>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw NetworkError.timeout
            }
            
            do {
                let result = try await group.next()
                group.cancelAll()
                guard let result = result else {
                    throw NetworkError.timeout
                }
                return result
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    func fetchDetail(slug: String) async throws -> MediaItem {
        if let cached = detailCache.get(slug) {
            return cached
        }

        let url = absoluteURL(for: resolvedRoute(config.routes.detail, substitutions: ["slug": slug]))
        let html = try await networkService.fetchString(from: url, headers: htmlHeaders)
        let item = try parseDetailPage(html: html, slug: slug, pageURL: url)
        detailCache.set(slug, item)
        return item
    }

    private func makePageURL(source: MediaRouteSource, pagePath: String?) throws -> URL {
        print("[MediaService] makePageURL: source=\(source), pagePath=\(pagePath ?? "nil")")
        if let rawPagePath = pagePath?.trimmingCharacters(in: .whitespacesAndNewlines), !rawPagePath.isEmpty {
            if let absolute = URL(string: rawPagePath), absolute.scheme != nil {
                print("[MediaService] makePageURL: using absolute URL=\(absolute)")
                return absolute
            }

            if rawPagePath.hasPrefix("/") {
                let url = absoluteURL(for: rawPagePath)
                print("[MediaService] makePageURL: using absoluteURL=\(url)")
                return url
            }

            if rawPagePath.contains("search?") || rawPagePath.contains("tag:") || rawPagePath.contains("hx2/") {
                let url = absoluteURL(for: rawPagePath.hasPrefix("/") ? rawPagePath : "/\(rawPagePath)")
                print("[MediaService] makePageURL: using special handler, url=\(url)")
                return url
            }

            switch source {
            case .home:
                let url = absoluteURL(for: rawPagePath.hasPrefix("?") || rawPagePath.hasPrefix("&") ? rawPagePath : "/\(rawPagePath)")
                print("[MediaService] makePageURL: home path, url=\(url)")
                return url
            case .mobile:
                let url = absoluteURL(for: "/mobile/\(trimmedPathComponent(rawPagePath))")
                print("[MediaService] makePageURL: mobile path, url=\(url)")
                return url
            case .tag(let slug):
                let url = absoluteURL(for: "/tag:\(slug)/\(trimmedPathComponent(rawPagePath))")
                print("[MediaService] makePageURL: tag path, url=\(url)")
                return url
            case .search(let query):
                let url = try makeSearchPageURL(query: query, pagePath: rawPagePath)
                print("[MediaService] makePageURL: search path, url=\(url)")
                return url
            }
        }

        switch source {
        case .home:
            let url = absoluteURL(for: resolvedRoute(config.routes.home))
            print("[MediaService] makePageURL: default home, url=\(url)")
            return url
        case .mobile:
            let url = absoluteURL(for: resolvedRoute(config.routes.mobile))
            print("[MediaService] makePageURL: default mobile, url=\(url)")
            return url
        case .tag(let slug):
            let url = absoluteURL(for: resolvedRoute(config.routes.tag, substitutions: ["slug": slug]))
            print("[MediaService] makePageURL: default tag, url=\(url)")
            return url
        case .search(let query):
            let url = try makeSearchPageURL(query: query, pagePath: nil)
            print("[MediaService] makePageURL: default search, url=\(url)")
            return url
        }
    }

    private func absoluteURL(for pathOrURL: String) -> URL {
        if let absolute = URL(string: pathOrURL), absolute.scheme != nil {
            return absolute
        }

        let trimmed = pathOrURL.trimmingCharacters(in: .whitespacesAndNewlines)

        // 保持路径原始格式（不删除尾部斜杠）
        let pathPart: String
        if trimmed.hasPrefix("/") {
            pathPart = String(trimmed.dropFirst()) // 去掉开头的 /
        } else {
            pathPart = trimmed
        }

        if pathPart.isEmpty {
            return baseURL
        }

        if let components = URLComponents(string: trimmed),
           let query = components.query {
            // 保持路径格式（不删除尾部斜杠）
            let rawPath = components.path
            let cleanPath = rawPath.hasPrefix("/") ? String(rawPath.dropFirst()) : rawPath
            let joinedBase = baseURL.absoluteString.hasSuffix("/") ? baseURL.absoluteString : baseURL.absoluteString + "/"
            return URL(string: joinedBase + cleanPath + "?" + query) ?? baseURL
        }

        let joinedBase = baseURL.absoluteString.hasSuffix("/") ? baseURL.absoluteString : baseURL.absoluteString + "/"
        return URL(string: joinedBase + pathPart) ?? baseURL
    }

    private func parseListPage(html: String, source: MediaRouteSource, pageURL: URL) -> MediaListPage {
        let title = parsePageTitle(html: html) ?? source.defaultTitle
        var seen = Set<String>()
        var items: [MediaItem] = []

        print("[MediaService] parseListPage: url=\(pageURL), htmlLength=\(html.count)")

        do {
            let document = try SwiftSoup.parse(html)
            let listSelector = config.parsing.searchList
            let elements = try document.select(listSelector)

            print("[MediaService] parseListPage: listSelector=\(listSelector), found \(elements.count) elements")

            for element in elements {
                // 提取标题
                let titleSelector = config.parsing.searchName
                var titleText = ""
                if titleSelector == "href" || titleSelector == "src" {
                    // 如果是属性名，直接从元素获取
                    titleText = (try? element.attr(titleSelector)) ?? ""
                } else {
                    titleText = (try? element.select(titleSelector).first()?.text()) ?? ""
                }
                guard !titleText.isEmpty else { continue }

                // 提取封面图
                let coverSelector = config.parsing.searchCover ?? "img"
                var coverLink: String? = nil
                if coverSelector == "img" {
                    coverLink = try? element.select("img").first()?.attr("src")
                        ?? element.select("img").first()?.attr("data-src")
                } else {
                    coverLink = try? element.select(coverSelector).first()?.attr("src")
                        ?? element.select(coverSelector).first()?.attr("data-src")
                }

                guard let imageSrc = coverLink, !imageSrc.isEmpty else { continue }

                // 从图片路径中提取 ID 和 slug
                guard let (id, slug, resolution) = extractIdSlugResolution(from: imageSrc) else {
                    continue
                }

                guard !slug.isEmpty, seen.insert(slug).inserted else {
                    continue
                }

                let cleanTitle = cleanListTitle(titleText)
                let collectionTag = title == source.defaultTitle ? nil : title
                let detailPath = "/media/\(id)/\(slug)/"

                items.append(
                    MediaItem(
                        slug: slug,
                        title: cleanTitle,
                        pageURL: absoluteURL(for: detailPath),
                        thumbnailURL: absoluteURL(for: imageSrc),
                        resolutionLabel: resolution,
                        collectionTitle: collectionTag,
                        tags: collectionTag.map { [$0] } ?? []
                    )
                )
            }
        } catch {
            print("[MediaService] parseListPage: SwiftSoup parse error: \(error)")
        }

        print("[MediaService] parseListPage: total items parsed=\(items.count)")

        return MediaListPage(
            items: items,
            nextPagePath: parseNextPagePath(html: html, source: source, pageURL: pageURL),
            sectionTitle: title
        )
    }

    /// 从图片 src 路径中提取 ID、slug 和分辨率
    /// 路径格式: /i/c/364x205/media/9147/yuji-itadori-city.3840x2160.jpg 或 ...jpg.webp
    private func extractIdSlugResolution(from src: String) -> (id: String, slug: String, resolution: String)? {
        // 匹配 /i/c/.../media/{id}/{slug}.{resolution}.[^.]+(\.webp)?$ 格式
        // 支持双扩展名如 .jpg.webp 或单扩展名如 .jpg
        let pattern = #"/media/(\d+)/([^/]+)\.([0-9]+x[0-9]+)\.[^.]+(\.webp)?$"#

        guard let regex = compileRegex(pattern) else {
            return nil
        }

        let range = NSRange(src.startIndex..., in: src)
        guard let match = regex.firstMatch(in: src, options: [], range: range) else {
            return nil
        }

        guard
            let idRange = Range(match.range(at: 1), in: src),
            let slugRange = Range(match.range(at: 2), in: src),
            let resolutionRange = Range(match.range(at: 3), in: src)
        else {
            return nil
        }

        let id = String(src[idRange])
        let slug = String(src[slugRange])
        let resolution = String(src[resolutionRange])

        return (id, slug, resolution)
    }

    private func parseDetailPage(html: String, slug: String, pageURL: URL) throws -> MediaItem {
        let title = cleanListTitle(parseMetaContent(in: html, property: "og:title") ?? parseTagContent(in: html, tag: "title") ?? slug)

        let posterCandidate = parseMetaContent(in: html, property: "og:image")
            ?? captureFirst(in: html, pattern: #"<video[^>]*poster="?([^">\s]+)"?"#)

        guard
            let imageURLString = posterCandidate,
            let thumbnailURL = URL(string: imageURLString, relativeTo: baseURL)?.absoluteURL
        else {
            throw NetworkError.invalidResponse
        }

        let previewURL = (
            parseMetaContent(in: html, property: "og:video")
            ?? captureFirst(in: html, pattern: #"<video[^>]*>\s*<source[^>]*src="?([^">\s]+)"?"#)
        )
            .flatMap { URL(string: $0, relativeTo: baseURL)?.absoluteURL }
        let summary = parseMetaContent(in: html, metaName: "description")?.htmlDecoded
        let tags = parseTags(html: html)
        let downloadOptions = parseDownloadOptions(html: html)
        let exactResolution = downloadOptions.first?.detailText.components(separatedBy: " ").first
        let durationSeconds = parseDurationSeconds(html: html)
        let resolutionLabel = downloadOptions.first?.label ?? "Live"

        return MediaItem(
            slug: slug,
            title: title,
            pageURL: pageURL,
            thumbnailURL: thumbnailURL,
            resolutionLabel: resolutionLabel,
            collectionTitle: tags.first,
            summary: summary,
            previewVideoURL: previewURL,
            posterURL: thumbnailURL,
            tags: tags,
            exactResolution: exactResolution,
            durationSeconds: durationSeconds,
            downloadOptions: downloadOptions
        )
    }

    private func parsePageTitle(html: String) -> String? {
        if let heading = captureFirst(in: html, pattern: #"<h1[^>]*><span[^>]*>(.*?)</span>\s*Live Wallpapers</h1>"#) {
            return heading.htmlDecoded
        }

        guard let rawTitle = parseTagContent(in: html, tag: "title")?.htmlDecoded else {
            return nil
        }

        if rawTitle.contains("Live Wallpapers") {
            let cleaned = rawTitle
                .replacingOccurrences(of: #"^\d+\+\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"Live Wallpapers.*$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            return cleaned.isEmpty ? "Featured" : cleaned
        }

        return rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseNextPagePath(html: String, source: MediaRouteSource, pageURL: URL) -> String? {
        func pathPreservingQuery(from rawValue: String) -> String {
            let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)

            guard let url = URL(string: trimmed), url.scheme != nil else {
                return normalizeRelativePagePath(trimmed, source: source, pageURL: pageURL)
            }

            var path = url.path.isEmpty ? "/" : url.path
            if let query = url.query, !query.isEmpty {
                path += "?\(query)"
            }
            if let fragment = url.fragment, !fragment.isEmpty {
                path += "#\(fragment)"
            }
            return path
        }

        do {
            let document = try SwiftSoup.parse(html)

            // 策略 1：使用配置的选择器（仅当 nextPage 非空时）
            if let nextPageXPath = config.parsing.nextPage, !nextPageXPath.isEmpty {
                let cssSelector = htmlParser.convertXPathToCSS(nextPageXPath) ?? nextPageXPath
                let matchedLinks = try? document.select(cssSelector)

                // 优先找包含"View More"或"Next"文字的链接（真正的分页链接）
                if let paginationLink = matchedLinks?.array().first(where: { link in
                    let text = ((try? link.text()) ?? "").lowercased()
                    return text.contains("view more") || text.contains("next")
                }), let href = try? paginationLink.attr("href"), !href.isEmpty {
                    print("[MediaService] parseNextPagePath: 配置选择器匹配成功 (pagination): '\(href)'")
                    return pathPreservingQuery(from: href)
                }

                // 兜底：找 href 匹配数字页码格式的链接（包括 /tag:xxx/N/ 和 /N/ 格式）
                if let numericLink = matchedLinks?.array().first(where: { link in
                    let href = ((try? link.attr("href")) ?? "")
                    return href.matches(regex: #"^/(tag:[^/]+/)?\d+/?$"#)
                }), let href = try? numericLink.attr("href"), !href.isEmpty {
                    print("[MediaService] parseNextPagePath: 配置选择器匹配成功 (numeric): '\(href)'")
                    return pathPreservingQuery(from: href)
                }

                // 最后才用 first()（可能是分类链接）
                if let firstLink = matchedLinks?.first(),
                   let href = try? firstLink.attr("href"), !href.isEmpty {
                    print("[MediaService] parseNextPagePath: 配置选择器匹配成功 (first): '\(href)'")
                    return pathPreservingQuery(from: href)
                }
            }

            // 策略 2：后备匹配 - 查找 "Next" 文本链接
            let allLinks = try document.select("a")
            for link in allLinks.array() {
                let text = (try? link.text().trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
                let href = (try? link.attr("href")) ?? ""

                // 匹配 text 为 "Next" 且 href 包含数字路径的链接
                if text.lowercased() == "next" && href.matches(regex: #"/\d+/?$"#) {
                    print("[MediaService] parseNextPagePath: 后备匹配成功 (text='Next'): '\(href)'")
                    return pathPreservingQuery(from: href)
                }
            }

            // 策略 3：匹配 href 格式为 /tag:xxx/N/ 或 /N/
            for link in allLinks.array() {
                let href = (try? link.attr("href")) ?? ""
                let text = (try? link.text()) ?? ""

                // 匹配 MotionBGs 分页格式: /tag:anime/2/ 或 /2/
                if href.matches(regex: #"^/(tag:[^/]+/)?\d+/?$"#) {
                    // 排除导航链接（Guides, About 等）
                    let isNav = text.lowercased().matches(regex: #"^(guides?|about|privacy|dmca|contact)$"#)
                    if !isNav {
                        print("[MediaService] parseNextPagePath: 后备匹配成功 (href pattern): '\(href)'")
                        return pathPreservingQuery(from: href)
                    }
                }
            }

            print("[MediaService] parseNextPagePath: 未找到分页链接")

        } catch {
            print("[MediaService] parseNextPagePath: 解析失败: \(error)")
        }

        return nil
    }

    private func parseMetaContent(in html: String, property: String? = nil, metaName: String? = nil) -> String? {
        if let property {
            return captureFirst(
                in: html,
                pattern: #"<meta content="?([^">]+)"? property=\#(property.replacingOccurrences(of: ".", with: #"\\."#))>"#
            )
        }

        if let metaName {
            return captureFirst(
                in: html,
                pattern: #"<meta content="?([^">]+)"? name=\#(metaName.replacingOccurrences(of: ".", with: #"\\."#))>"#
            )
        }

        return nil
    }

    private func parseTagContent(in html: String, tag: String) -> String? {
        captureFirst(in: html, pattern: #"<\#(tag)[^>]*>(.*?)</\#(tag)>"#)
    }

    private func parseTags(html: String) -> [String] {
        guard let tagListSelector = config.parsing.tagList else {
            return []
        }

        var seen = Set<String>()
        var tags: [String] = []

        do {
            let document = try SwiftSoup.parse(html)
            let cssSelector = htmlParser.convertXPathToCSS(tagListSelector) ?? tagListSelector
            let tagElements = try document.select(cssSelector)

            for tagEl in tagElements {
                var tagText: String?
                if let tagNameSelector = config.parsing.tagName {
                    let nameCss = htmlParser.convertXPathToCSS(tagNameSelector) ?? tagNameSelector
                    tagText = try? tagEl.select(nameCss).first()?.text()
                }
                let value = tagText ?? (try? tagEl.text()) ?? ""
                let normalized = value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

                guard !normalized.isEmpty, seen.insert(normalized).inserted else {
                    continue
                }
                tags.append(normalized)
            }
        } catch {
            print("[MediaService] parseTags: error: \(error)")
        }

        return tags
    }

    private func parseDownloadOptions(html: String) -> [MediaDownloadOption] {
        guard let pattern = config.parsing.downloadPattern,
              let regex = compileRegex(pattern) else {
            return []
        }
        let range = NSRange(html.startIndex..., in: html)

        return regex.matches(in: html, options: [], range: range).compactMap { match in
            guard
                let href = capture(match: match, in: html, at: 1),
                let label = capture(match: match, in: html, at: 2)?.htmlDecoded,
                let fileSize = capture(match: match, in: html, at: 3)?.htmlDecoded,
                let detailText = capture(match: match, in: html, at: 4)?.htmlDecoded
            else {
                return nil
            }

            return MediaDownloadOption(
                label: label.trimmingCharacters(in: .whitespacesAndNewlines),
                fileSizeLabel: fileSize.trimmingCharacters(in: .whitespacesAndNewlines),
                detailText: detailText.trimmingCharacters(in: .whitespacesAndNewlines),
                remoteURL: absoluteURL(for: href)
            )
        }
    }

    private func parseDurationSeconds(html: String) -> Double? {
        guard let pattern = config.parsing.durationPattern,
              let durationString = captureFirst(in: html, pattern: pattern) else {
            return nil
        }

        let trimmed = durationString.replacingOccurrences(of: "PT", with: "")
        if let seconds = Double(trimmed.replacingOccurrences(of: "S", with: "")) {
            return seconds
        }

        let minuteParts = trimmed.components(separatedBy: "M")
        if minuteParts.count == 2,
           let minutes = Double(minuteParts[0]),
           let seconds = Double(minuteParts[1].replacingOccurrences(of: "S", with: "")) {
            return (minutes * 60) + seconds
        }

        return nil
    }

    private func cleanListTitle(_ value: String) -> String {
        value
            .replacingOccurrences(of: " live wallpaper", with: "", options: [.caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .htmlDecoded
    }

    private func capture(match: NSTextCheckingResult, in text: String, at index: Int) -> String? {
        guard
            let range = Range(match.range(at: index), in: text)
        else {
            return nil
        }
        return String(text[range])
    }

    private func captureFirst(in text: String, pattern: String) -> String? {
        guard let regex = compileRegex(pattern) else {
            return nil
        }

        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else {
            return nil
        }

        return capture(match: match, in: text, at: 1)
    }

    private func makeSearchPageURL(query: String, pagePath: String?) throws -> URL {
        let resolvedSearchURL = absoluteURL(for: resolvedRoute(config.routes.search, substitutions: ["query": query]))
        guard var components = URLComponents(url: resolvedSearchURL, resolvingAgainstBaseURL: false) else {
            throw NetworkError.invalidResponse
        }

        var queryItems = components.queryItems ?? []
        if !queryItems.contains(where: { $0.name == "q" }) {
            queryItems.append(URLQueryItem(name: "q", value: query))
        }

        if let pagePath, !pagePath.isEmpty {
            let pageQuery = pagePath
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "?&"))

            if !pageQuery.isEmpty {
                let helperURL = URL(string: "\(resolvedSearchURL.absoluteString.split(separator: "?").first ?? "")?\(pageQuery)")
                let extraItems = URLComponents(url: helperURL ?? resolvedSearchURL, resolvingAgainstBaseURL: false)?
                    .queryItems?
                    .filter { $0.name != "q" } ?? []
                queryItems.append(contentsOf: extraItems)
            }
        }

        components.queryItems = queryItems

        guard let url = components.url else {
            throw NetworkError.invalidResponse
        }
        return url
    }

    private func trimmedPathComponent(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.hasSuffix("/") ? trimmed : "\(trimmed)/"
    }

    private func normalizeRelativePagePath(_ rawValue: String, source: MediaRouteSource, pageURL: URL) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        if trimmed.hasPrefix("/") || trimmed.hasPrefix("?") || trimmed.hasPrefix("&") {
            return trimmed
        }

        switch source {
        case .home:
            return "/\(trimmedPathComponent(trimmed))"
        case .mobile:
            return resolvedRoute(config.routes.mobile) + trimmedPathComponent(trimmed)
        case .tag(let slug):
            return resolvedRoute(config.routes.tag, substitutions: ["slug": slug]) + trimmedPathComponent(trimmed)
        case .search:
            if trimmed.contains("=") || trimmed.contains("&") {
                return trimmed.hasPrefix("?") ? trimmed : "?\(trimmed)"
            }
            let pageNumber = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !pageNumber.isEmpty,
               CharacterSet.decimalDigits.isSuperset(of: CharacterSet(charactersIn: pageNumber)) {
                return "?page=\(pageNumber)"
            }
            return pageURL.appendingPathComponent(pageNumber).absoluteURL.path
        }
    }

    private func listItemRegexes() -> [NSRegularExpression] {
        return []
    }

    private func compileRegex(_ pattern: String) -> NSRegularExpression? {
        do {
            let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
            return regex
        } catch {
            print("[MediaService] compileRegex error: \(error)")
            return nil
        }
    }

    private func resolvedRoute(_ template: String, substitutions: [String: String] = [:]) -> String {
        substitutions.reduce(template) { partial, item in
            let encoded: String
            if item.key == "query" {
                let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=?+"))
                encoded = item.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? item.value
            } else {
                encoded = item.value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? item.value
            }
            return partial.replacingOccurrences(of: "{\(item.key)}", with: encoded)
        }
    }
}

private extension String {
    /// 高效的 HTML 实体解码（不使用 NSAttributedString）
    var htmlDecoded: String {
        // 常见的 HTML 实体映射表
        let entities: [String: String] = [
            "&amp;": "&",
            "&lt;": "<",
            "&gt;": ">",
            "&quot;": "\"",
            "&#39;": "'",
            "&apos;": "'",
            "&nbsp;": " ",
            "&copy;": "©",
            "&reg;": "®",
            "&trade;": "™",
            "&hellip;": "…",
            "&mdash;": "—",
            "&ndash;": "–",
            "&ldquo;": "\"",
            "&rdquo;": "\"",
            "&lsquo;": "'",
            "&rsquo;": "'"
        ]

        var result = self

        // 处理命名实体
        for (entity, char) in entities {
            result = result.replacingOccurrences(of: entity, with: char)
        }

        // 处理数字实体（如 &#123; 或 &#x7B;）
        result = decodeNumericEntities(result)

        return result
    }

    private func decodeNumericEntities(_ input: String) -> String {
        var result = input

        // 匹配十进制实体: &#123;
        let decimalPattern = #"&#(\d+);"#
        if let regex = try? NSRegularExpression(pattern: decimalPattern) {
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                guard let numRange = Range(match.range(at: 1), in: result),
                      let num = Int(result[numRange]),
                      let scalar = UnicodeScalar(num) else { continue }
                let char = String(Character(scalar))
                if let fullRange = Range(match.range, in: result) {
                    result.replaceSubrange(fullRange, with: char)
                }
            }
        }

        // 匹配十六进制实体: &#x7B;
        let hexPattern = #"&#x([0-9A-Fa-f]+);"#
        if let regex = try? NSRegularExpression(pattern: hexPattern) {
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                guard let hexRange = Range(match.range(at: 1), in: result),
                      let num = Int(result[hexRange], radix: 16),
                      let scalar = UnicodeScalar(num) else { continue }
                let char = String(Character(scalar))
                if let fullRange = Range(match.range, in: result) {
                    result.replaceSubrange(fullRange, with: char)
                }
            }
        }

        return result
    }

    /// 检查字符串是否匹配正则表达式
    func matches(regex pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return false
        }
        let range = NSRange(self.startIndex..., in: self)
        return regex.firstMatch(in: self, options: [], range: range) != nil
    }
}
