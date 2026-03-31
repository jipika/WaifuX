import Foundation
import SwiftSoup

actor MediaService {
    static let shared = MediaService()

    private let networkService = NetworkService.shared
    private let htmlParser = HTMLParser.shared
    private var listCache: [String: MediaListPage] = [:]
    private var detailCache: [String: MediaItem] = [:]

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
    }

    func fetchPage(source: MediaRouteSource, pagePath: String? = nil) async throws -> MediaListPage {
        print("[MediaService] fetchPage ENTERED: source=\(source)")
        print("[MediaService] config: baseURL=\(config.baseURL)")
        print("[MediaService] config: routes home=\(config.routes.home)")
        print("[MediaService] activeProfile: \(DataSourceProfileStore.activeProfile().name)")

        let url = try makePageURL(source: source, pagePath: pagePath)
        let cacheKey = url.absoluteString

        print("[MediaService] fetchPage: source=\(source), url=\(url)")

        if let cached = listCache[cacheKey] {
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
        listCache[cacheKey] = page
        return page
    }

    // 添加超时辅助函数
    private func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw NetworkError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    func fetchDetail(slug: String) async throws -> MediaItem {
        if let cached = detailCache[slug] {
            return cached
        }

        let url = absoluteURL(for: resolvedRoute(config.routes.detail, substitutions: ["slug": slug]))
        let html = try await networkService.fetchString(from: url, headers: htmlHeaders)
        let item = try parseDetailPage(html: html, slug: slug, pageURL: url)
        detailCache[slug] = item
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
        let relativePath = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        if relativePath.isEmpty {
            return baseURL
        }

        if let components = URLComponents(string: trimmed),
           let query = components.query {
            let pathOnly = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let joinedBase = baseURL.absoluteString.hasSuffix("/") ? baseURL.absoluteString : baseURL.absoluteString + "/"
            return URL(string: joinedBase + pathOnly + "?" + query) ?? baseURL
        }

        let joinedBase = baseURL.absoluteString.hasSuffix("/") ? baseURL.absoluteString : baseURL.absoluteString + "/"
        return URL(string: joinedBase + relativePath) ?? baseURL
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

                // 提取详情链接 - 直接从当前元素获取 href 属性
                let detailLink = try? element.attr("href")

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
    /// 路径格式: /i/c/364x205/media/9147/yuji-itadori-city.3840x2160.jpg
    private func extractIdSlugResolution(from src: String) -> (id: String, slug: String, resolution: String)? {
        // 匹配 /i/c/.../media/{id}/{slug}.{resolution}.jpg 格式
        let pattern = #"/media/(\d+)/([^/]+)\.([0-9]+x[0-9]+)\.[^.]+$"#

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

        // 🔍 诊断日志：输出所有可能的分页链接
        print("[MediaService] parseNextPagePath: 🔍 开始诊断分页元素 (source=\(source))")
        do {
            let document = try SwiftSoup.parse(html)
            
            // 检查所有 a 标签
            let allLinks = try document.select("a")
            print("[MediaService] parseNextPagePath: 页面共找到 \(allLinks.count) 个 <a> 标签")
            
            // 查找包含 "next"、"more"、或数字路径的链接
            var candidateLinks: [(href: String, rel: String, text: String, className: String)] = []
            
            for link in allLinks.array() {
                let href = (try? link.attr("href")) ?? ""
                let rel = (try? link.attr("rel")) ?? ""
                let text = (try? link.text()) ?? ""
                let className = (try? link.attr("class")) ?? ""
                
                // 收集可能的分页链接
                let lowerText = text.lowercased()
                let lowerHref = href.lowercased()
                
                // 扩展匹配条件：包含分页关键词，或 href 以 /数字/ 结尾
                let isPaginationKeyword = lowerText.contains("next") || lowerText.contains("more") || 
                                          lowerText.contains("›") || lowerText.contains(">") ||
                                          lowerHref.contains("page") || lowerHref.contains("next") ||
                                          rel.contains("next") || className.contains("next") || 
                                          className.contains("pagination") || className.contains("arrowed")
                
                let isNumericPath = href.matches(regex: #"^/(\d+/|tag:[^/]+/\d+/)$"#)
                
                if isPaginationKeyword || isNumericPath {
                    candidateLinks.append((href: href, rel: rel, text: text, className: className))
                }
            }
            
            print("[MediaService] parseNextPagePath: 找到 \(candidateLinks.count) 个候选分页链接:")
            for (index, candidate) in candidateLinks.enumerated() {
                print("  [\(index + 1)] href='\(candidate.href)' rel='\(candidate.rel)' class='\(candidate.className)' text='\(candidate.text.prefix(30))'")
            }
            
            // 检查配置的选择器
            if let nextPageXPath = config.parsing.nextPage {
                print("[MediaService] parseNextPagePath: 配置的选择器: '\(nextPageXPath)'")
                let cssSelector = htmlParser.convertXPathToCSS(nextPageXPath) ?? nextPageXPath
                print("[MediaService] parseNextPagePath: 转换后的 CSS 选择器: '\(cssSelector)'")
                
                let matchingElements = try document.select(cssSelector)
                print("[MediaService] parseNextPagePath: 匹配到 \(matchingElements.count) 个元素")
                
                for (index, element) in matchingElements.array().enumerated() {
                    let href = (try? element.attr("href")) ?? ""
                    let text = (try? element.text()) ?? ""
                    print("  [\(index + 1)] href='\(href)' text='\(text.prefix(30))'")
                }
            } else {
                print("[MediaService] parseNextPagePath: ⚠️ 未配置 nextPage 选择器")
            }
            
        } catch {
            print("[MediaService] parseNextPagePath: 解析 HTML 失败: \(error)")
        }

        // 原有的解析逻辑
        if let nextPageXPath = config.parsing.nextPage {
            do {
                let document = try SwiftSoup.parse(html)
                let cssSelector = htmlParser.convertXPathToCSS(nextPageXPath) ?? nextPageXPath
                if let nextLink = try? document.select(cssSelector).first()?.attr("href"),
                   !nextLink.isEmpty {
                    print("[MediaService] parseNextPagePath: ✅ 成功提取分页链接: '\(nextLink)'")
                    return pathPreservingQuery(from: nextLink)
                } else {
                    print("[MediaService] parseNextPagePath: ❌ 未能提取到分页链接")
                }
            } catch {
                print("[MediaService] parseNextPagePath: error: \(error)")
            }
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
    var htmlDecoded: String {
        guard let data = data(using: .utf8) else { return self }

        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]

        return (try? NSAttributedString(data: data, options: options, documentAttributes: nil).string) ?? self
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
