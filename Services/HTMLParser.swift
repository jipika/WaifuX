import Foundation
import SwiftSoup

// MARK: - HTML 解析服务

/// 基于 SwiftSoup 的 HTML 解析引擎
/// 支持 CSS Selector 和简化的 XPath 解析
actor HTMLParser {
    static let shared = HTMLParser()

    // MARK: - 解析列表页

    /// 从列表页 HTML 中解析内容列表
    func parseList(
        html: String,
        rule: DataSourceRule,
        listXPath: ListXPath
    ) throws -> [UniversalContentItem] {
        let document = try SwiftSoup.parse(html)
        guard let listSelector = convertXPathToCSS(listXPath.list) else {
            throw HTMLParserError.invalidSelector("list selector: \(listXPath.list)")
        }

        let elements = try document.select(listSelector)
        var items: [UniversalContentItem] = []

        for element in elements {
            guard let item = try? parseListItem(
                element: element,
                rule: rule,
                listXPath: listXPath
            ) else { continue }
            items.append(item)
        }

        print("[HTMLParser] Parsed \(items.count) items from list, selector: \(listSelector)")
        return items
    }

    // MARK: - 解析搜索结果

    /// 从搜索页 HTML 中解析内容列表
    func parseSearch(
        html: String,
        rule: DataSourceRule,
        searchXPath: SearchXPath
    ) throws -> [UniversalContentItem] {
        let document = try SwiftSoup.parse(html)
        guard let listSelector = convertXPathToCSS(searchXPath.list) else {
            throw HTMLParserError.invalidSelector("search selector: \(searchXPath.list)")
        }

        let elements = try document.select(listSelector)
        var items: [UniversalContentItem] = []

        for element in elements {
            guard let item = try? parseListItem(
                element: element,
                rule: rule,
                titleSelector: searchXPath.title,
                coverSelector: searchXPath.cover,
                detailSelector: searchXPath.detail
            ) else { continue }
            items.append(item)
        }

        print("[HTMLParser] Parsed \(items.count) items from search, selector: \(listSelector)")
        return items
    }

    // MARK: - 解析详情页

    /// 解析壁纸详情页
    func parseWallpaperDetail(
        html: String,
        rule: DataSourceRule,
        detailXPath: DetailXPath,
        baseItem: UniversalContentItem
    ) throws -> UniversalContentItem {
        let document = try SwiftSoup.parse(html)

        let title = try? evaluateSelector(document, selector: detailXPath.title)
            .first?.text()
            ?? baseItem.title

        let cover = try? evaluateSelector(document, selector: detailXPath.cover ?? "")
            .first?
            .attr("src")

        let fullImage = try? evaluateSelector(document, selector: detailXPath.fullImage ?? "")
            .first?
            .attr("src")

        let resolution = try? evaluateSelector(document, selector: detailXPath.resolution ?? "")
            .first?.text()

        let metadata = ContentMetadata.WallpaperMetadata(
            fullImageURL: fullImage ?? cover ?? baseItem.thumbnailURL,
            resolution: resolution,
            fileSize: nil,
            fileType: nil,
            purity: nil,
            uploader: nil,
            category: nil
        )

        return UniversalContentItem(
            id: baseItem.id,
            contentType: baseItem.contentType,
            title: title ?? baseItem.title,
            thumbnailURL: baseItem.thumbnailURL,
            coverURL: cover ?? fullImage ?? baseItem.coverURL,
            description: nil,
            tags: baseItem.tags,
            sourceType: baseItem.sourceType,
            sourceURL: baseItem.sourceURL,
            sourceName: baseItem.sourceName,
            metadata: .wallpaper(metadata),
            createdAt: baseItem.createdAt,
            updatedAt: Date()
        )
    }

    /// 解析动漫详情页
    func parseAnimeDetail(
        html: String,
        rule: DataSourceRule,
        detailXPath: DetailXPath,
        baseItem: UniversalContentItem
    ) throws -> UniversalContentItem {
        let document = try SwiftSoup.parse(html)

        let title = try? evaluateSelector(document, selector: detailXPath.title)
            .first?.text()
            ?? baseItem.title

        let cover = try? evaluateSelector(document, selector: detailXPath.cover ?? "")
            .first?
            .attr("src")

        let description = try? evaluateSelector(document, selector: detailXPath.description ?? "")
            .first?.text()

        // 解析剧集列表
        var episodes: [AnimeEpisode] = []
        if let episodesSelector = detailXPath.episodes,
           let selector = convertXPathToCSS(episodesSelector) {
            episodes = try parseEpisodes(
                document: document,
                containerSelector: selector,
                namePattern: detailXPath.episodeName ?? "",
                linkPattern: detailXPath.episodeLink ?? "",
                thumbPattern: detailXPath.episodeThumb,
                baseURL: rule.baseURL
            )
        }

        let metadata = ContentMetadata.AnimeMetadata(
            episodes: episodes,
            currentEpisode: nil,
            totalEpisodes: episodes.count,
            status: nil,
            aired: nil,
            rating: nil
        )

        return UniversalContentItem(
            id: baseItem.id,
            contentType: baseItem.contentType,
            title: title ?? baseItem.title,
            thumbnailURL: baseItem.thumbnailURL,
            coverURL: cover ?? baseItem.coverURL,
            description: description,
            tags: baseItem.tags,
            sourceType: baseItem.sourceType,
            sourceURL: baseItem.sourceURL,
            sourceName: baseItem.sourceName,
            metadata: .anime(metadata),
            createdAt: baseItem.createdAt,
            updatedAt: Date()
        )
    }

    // MARK: - 解析剧集列表

    private func parseEpisodes(
        document: Document,
        containerSelector: String,
        namePattern: String,
        linkPattern: String,
        thumbPattern: String?,
        baseURL: String
    ) throws -> [AnimeEpisode] {
        let episodeElements = try document.select(containerSelector)
        var episodes: [AnimeEpisode] = []

        for (index, element) in episodeElements.array().enumerated() {
            // 提取链接
            let elements = (try? evaluateXPathInContext(element, xpath: linkPattern)) ?? Elements()
            let link = try? elements.first()?.attr("href")

            guard let link = link, !link.isEmpty else { continue }

            // 提取名称
            let nameEls = (try? evaluateXPathInContext(element, xpath: namePattern)) ?? Elements()
            let name = (try? nameEls.first()?.text()) ?? "Episode \(index + 1)"

            // 提取缩略图（可选）
            var thumb: String? = nil
            if let thumbPattern = thumbPattern {
                let thumbEls = (try? evaluateXPathInContext(element, xpath: thumbPattern)) ?? Elements()
                thumb = try? thumbEls.first()?.attr("src")
            }

            let fullLink = makeAbsoluteURL(link, baseURL: baseURL) ?? link

            let episode = AnimeEpisode(
                id: fullLink,
                episodeNumber: index + 1,
                title: name.trimmingCharacters(in: .whitespacesAndNewlines),
                thumbnailURL: thumb,
                videoURLs: [],
                duration: nil
            )
            episodes.append(episode)
        }

        return episodes
    }

    // MARK: - XPath 到 CSS 选择器的转换

    /// 将简化的 XPath 表达式转换为 CSS Selector
    /// 支持常见的 XPath 模式:
    /// - //tag          -> tag
    /// - //tag[@class='x'] -> tag.class-x
    /// - //tag[@class*='x'] -> tag.class* (contains)
    /// - .//tag         -> descendant tag
    /// - /@attr         -> 从上下文中提取属性
    /// - /text()        -> 从上下文中提取文本
    /// - | 组合          -> 多选择器组合
    nonisolated func convertXPathToCSS(_ xpath: String) -> String? {
        let trimmed = xpath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        // 处理多选择器组合 (|)
        if trimmed.contains("|") {
            let parts = trimmed.split(separator: "|").map { String($0) }
            let cssParts = parts.compactMap { convertXPathToCSS($0) }
            return cssParts.joined(separator: ", ")
        }

        var result = trimmed

        // .//tag -> tag (CSS 不需要 .// 前缀, select() 默认就是 descendants)
        result = result.replacingOccurrences(of: ".//", with: "")

        // //tag -> tag
        result = result.replacingOccurrences(of: "^//", with: "", options: .regularExpression)

        // [contains(@class, 'name')] -> [class*="name"]
        let containsClassPattern = #"\[contains\(@class,\s*['"]([^'"]+)['"]\)\]"#
        if let regex = try? NSRegularExpression(pattern: containsClassPattern),
           let match = regex.firstMatch(in: result, range: NSRange(result.startIndex..., in: result)),
           let range = Range(match.range(at: 1), in: result) {
            let className = String(result[range])
            result = result.replacingOccurrences(
                of: "[contains(@class, '\(className)')]",
                with: ".\(className)"
            )
            result = result.replacingOccurrences(
                of: "[contains(@class, \"\(className)\")]",
                with: ".\(className)"
            )
        }

        // [contains(@class, 'name')] -> [class*="name"] (重复处理, 因为上一个可能没匹配到)
        if let regex = try? NSRegularExpression(pattern: containsClassPattern),
           regex.firstMatch(in: result, range: NSRange(result.startIndex..., in: result)) != nil {
            result = (try? regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "[class*=\"$1\"]"
            )) ?? result
        }

        // [@class='name'] -> .name
        let exactClassPattern = #"\[@class=['"]([^'"]+)['"]\]"#
        if let regex = try? NSRegularExpression(pattern: exactClassPattern),
           let match = regex.firstMatch(in: result, range: NSRange(result.startIndex..., in: result)),
           let range = Range(match.range(at: 1), in: result) {
            let className = String(result[range])
            // 先移除原始的 [@class='name']
            result = result.replacingOccurrences(of: "[@class='\(className)']", with: "")
            result = result.replacingOccurrences(of: "[@class=\"\(className)\"]", with: "")
            // 如果 tag 在前面, 把 class 加到 tag 上
            if result.contains("<tag>") {
                // shouldn't happen with our patterns
            }
            // 插入 class
            let insertIndex = result.firstIndex(where: { $0 == "[" || $0 == "]" || $0 == "/" || $0 == Character("") }) ?? result.endIndex
            // 简单策略: 在 tag 后插入 .className
            if !result.contains(".\(className)") && !result.hasSuffix(".\(className)") {
                // 已经移除的 [@class='name'] 不再添加
            }
        }

        // [@id='name'] -> #name
        let idPattern = #"\[@id=['"]([^'"]+)['"]\]"#
        if let regex = try? NSRegularExpression(pattern: idPattern),
           let match = regex.firstMatch(in: result, range: NSRange(result.startIndex..., in: result)),
           let range = Range(match.range(at: 1), in: result) {
            let id = String(result[range])
            result = (try? regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "#\(id)"
            )) ?? result
        }

        // [@attr='value'] -> [attr="value"]
        let attrPattern = #"\[@([a-zA-Z-]+)=['"]([^'"]+)['"]\]"#
        if let regex = try? NSRegularExpression(pattern: attrPattern),
           let match = regex.firstMatch(in: result, range: NSRange(result.startIndex..., in: result)),
           let attrRange = Range(match.range(at: 1), in: result),
           let valRange = Range(match.range(at: 2), in: result) {
            let attr = String(result[attrRange])
            let val = String(result[valRange])
            if attr != "class" && attr != "id" {
                result = (try? regex.stringByReplacingMatches(
                    in: result,
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: "[\(attr)=\"\(val)\"]"
                )) ?? result
            }
        }

        // text() 和 /@attr 结尾的处理 (这些用于属性/文本提取, 不是选择器)
        // 移除末尾的 /text() 或 /@xxx
        let trailingExtraction = #"(/text\(\)|/@[a-zA-Z]+)$"#
        if let regex = try? NSRegularExpression(pattern: trailingExtraction) {
            result = (try? regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )) ?? result
        }

        return result.isEmpty ? nil : result
    }

    // MARK: - 元素选择与值提取

    /// 在文档级别执行选择器 (支持 CSS Selector)
    private func evaluateSelector(_ document: Document, selector: String) throws -> Elements {
        let cssSelector = convertXPathToCSS(selector) ?? selector
        return try document.select(cssSelector)
    }

    /// 在元素上下文中执行简化的 XPath 提取
    /// 处理 .//tag, .//@attr, .//text() 等模式
    private func evaluateXPathInContext(_ element: Element, xpath: String) throws -> Elements {
        let trimmed = xpath.trimmingCharacters(in: .whitespacesAndNewlines)

        // 处理组合选择器 |
        if trimmed.contains("|") {
            let parts = trimmed.split(separator: "|").map { String($0) }
            var allElements: [Element] = []
            for part in parts {
                allElements.append(contentsOf: try evaluateXPathInContext(element, xpath: part).array())
            }
            return Elements(allElements)
        }

        // .//text() -> 提取直接文本节点
        if trimmed == ".//text()" {
            var texts: [Element] = []
            for textNode in element.getChildNodes() {
                if let tn = textNode as? TextNode {
                    let dummy = try? SwiftSoup.parse(tn.getWholeText()).body()
                    if let el = dummy?.children().first() {
                        texts.append(el)
                    }
                }
            }
            return Elements(texts)
        }

        // 处理 .// 开头
        if trimmed.hasPrefix(".//") {
            let inner = String(trimmed.dropFirst(3))
            // .//text()
            if inner == "text()" {
                var texts: [Element] = []
                for textNode in element.getChildNodes() {
                    if let tn = textNode as? TextNode {
                        let text = tn.getWholeText().trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty {
                            if let dummy = try? SwiftSoup.parse("<span>\(text)</span>").body(),
                               let el = dummy.children().array().first {
                                texts.append(el)
                            }
                        }
                    }
                }
                return Elements(texts)
            }

            // .//@href 等属性提取
            if inner.hasPrefix("@") {
                let attrName = String(inner.dropFirst())
                let attrValue = (try? element.attr(attrName)) ?? ""
                if !attrValue.isEmpty {
                    if let dummy = try? SwiftSoup.parse("<dummy attr=\"\(attrValue)\"></dummy>").body() {
                        return Elements([dummy])
                    }
                }
                return Elements([])
            }

            // .//tag[@attr='value']/text() 或 .//tag/text()
            return try extractFromDescendants(element, selector: inner)
        }

        // 处理 // 开头 (根级)
        if trimmed.hasPrefix("//") {
            let inner = String(trimmed.dropFirst(2))

            if inner.hasPrefix("@") {
                let attrName = String(inner.dropFirst())
                let attrValue = (try? element.attr(attrName)) ?? ""
                if !attrValue.isEmpty {
                    if let dummy = try? SwiftSoup.parse("<dummy attr=\"\(attrValue)\"></dummy>").body() {
                        return Elements([dummy])
                    }
                }
                return Elements([])
            }

            // //tag/text() 或 //tag/@attr
            if inner.contains("/text()") || inner.contains("/@") {
                let parts = inner.split(separator: "/")
                if parts.count >= 2 {
                    let tagPart = String(parts[0])
                    let lastPart = String(parts[parts.count - 1])
                    let selector = convertXPathToCSS(tagPart) ?? tagPart
                    let found = try element.select(selector)
                    var results: [Element] = []
                    for el in found {
                        if lastPart == "text()" {
                            let text = try el.text()
                            if !text.isEmpty, let dummy = try? SwiftSoup.parse("<span>\(text)</span>").body()?.children().first() {
                                results.append(dummy)
                            }
                        } else if lastPart.hasPrefix("@") {
                            let attrName = String(lastPart.dropFirst())
                            let val = try el.attr(attrName)
                            if !val.isEmpty, let dummy = try? SwiftSoup.parse("<dummy attr=\"\(val)\"></dummy>").body() {
                                results.append(dummy)
                            }
                        }
                    }
                    return Elements(results)
                }
            }

            return try element.select(convertXPathToCSS(inner) ?? inner)
        }

        // 纯选择器
        return try element.select(convertXPathToCSS(trimmed) ?? trimmed)
    }

    private func extractFromDescendants(_ element: Element, selector: String) throws -> Elements {
        // 处理 /text()
        if selector.contains("/text()") {
            let parts = selector.split(separator: "/")
            let tagSelector = parts.dropLast().joined(separator: "/")
            let cssSelector = convertXPathToCSS(tagSelector) ?? tagSelector
            let found = try element.select(cssSelector)
            var results: [Element] = []
            for el in found {
                let text = try el.text()
                if !text.isEmpty, let dummy = try? SwiftSoup.parse("<span>\(text)</span>").body()?.children().first() {
                    results.append(dummy)
                }
            }
            return Elements(results)
        }

        // 处理 /@attr
        if selector.contains("/@") {
            let parts = selector.split(separator: "/@")
            if parts.count == 2 {
                let tagSelector = String(parts[0])
                let attrName = String(parts[1])
                let cssSelector = convertXPathToCSS(tagSelector) ?? tagSelector
                let found = try element.select(cssSelector)
                var results: [Element] = []
                for el in found {
                    let val = try el.attr(attrName)
                    if !val.isEmpty, let dummy = try? SwiftSoup.parse("<dummy attr=\"\(val)\"></dummy>").body() {
                        results.append(dummy)
                    }
                }
                return Elements(results)
            }
        }

        // 处理 [contains(@class, 'x')]
        let cssSelector = convertXPathToCSS(selector) ?? selector
        return try element.select(cssSelector)
    }

    // MARK: - 解析列表项

    private func parseListItem(
        element: Element,
        rule: DataSourceRule,
        listXPath: ListXPath
    ) throws -> UniversalContentItem {
        return try parseListItem(
            element: element,
            rule: rule,
            titleSelector: listXPath.title,
            coverSelector: listXPath.cover,
            detailSelector: listXPath.detail
        )
    }

    private func parseListItem(
        element: Element,
        rule: DataSourceRule,
        titleSelector: String,
        coverSelector: String,
        detailSelector: String
    ) throws -> UniversalContentItem {
        // 提取标题
        let title = try extractText(element: element, xpath: titleSelector)
            ?? (try? element.text())
            ?? "Untitled"

        // 提取封面
        let cover = extractAttr(element: element, xpath: coverSelector, attr: "src")
            ?? extractAttr(element: element, xpath: coverSelector, attr: "data-src")
            ?? (try? element.select("img").first()?.attr("src"))

        // 提取详情链接
        let detail = extractAttr(element: element, xpath: detailSelector, attr: "href")

        let fullDetailURL = makeAbsoluteURL(detail, baseURL: rule.baseURL)
        let fullCoverURL = makeAbsoluteURL(cover, baseURL: rule.baseURL)

        let itemId = fullDetailURL ?? UUID().uuidString

        return UniversalContentItem(
            id: itemId,
            contentType: rule.contentType,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            thumbnailURL: fullCoverURL ?? "",
            coverURL: fullCoverURL,
            description: nil,
            tags: [],
            sourceType: rule.sourceType,
            sourceURL: fullDetailURL ?? "",
            sourceName: rule.name,
            metadata: defaultMetadata(for: rule.contentType),
            createdAt: nil,
            updatedAt: nil
        )
    }

    // MARK: - 辅助提取方法

    /// 从元素上下文中提取文本 (使用 XPath 模式)
    private func extractText(element: Element, xpath: String) throws -> String? {
        let trimmed = xpath.trimmingCharacters(in: .whitespacesAndNewlines)

        // 处理 | 组合
        if trimmed.contains("|") {
            for part in trimmed.split(separator: "|") {
                if let text = try? extractText(element: element, xpath: String(part)) {
                    if !text.isEmpty { return text }
                }
            }
            return nil
        }

        // .//text()
        if trimmed.hasSuffix(".//text()") || trimmed == ".//text()" {
            var allText = ""
            for node in element.getChildNodes() {
                if let tn = node as? TextNode {
                    allText += tn.getWholeText()
                }
            }
            return allText.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // //tag/text()
        if trimmed.contains("/text()") {
            let tagPart = trimmed.replacingOccurrences(of: "/text()", with: "")
            let cssSelector = convertXPathToCSS(tagPart) ?? tagPart
            if let selected = try? element.select(cssSelector).first() {
                return try selected.text()
            }
            return nil
        }

        // 其他选择器
        let cssSelector = convertXPathToCSS(trimmed) ?? trimmed
        return try? element.select(cssSelector).first()?.text()
    }

    /// 从元素上下文中提取属性值
    private func extractAttr(element: Element, xpath: String, attr: String) -> String? {
        let trimmed = xpath.trimmingCharacters(in: .whitespacesAndNewlines)

        // 处理 | 组合
        if trimmed.contains("|") {
            for part in trimmed.split(separator: "|") {
                if let val = extractAttr(element: element, xpath: String(part), attr: attr) {
                    return val
                }
            }
            return nil
        }

        // .//tag/@attr
        if trimmed.hasPrefix(".//") {
            var inner = String(trimmed.dropFirst(3))

            // .//@src -> 直接从当前元素提取属性
            if inner.hasPrefix("@") {
                let attrName = String(inner.dropFirst())
                let val = (try? element.attr(attrName)) ?? ""
                return val.isEmpty ? nil : val
            }

            // .//tag/@attr
            if inner.contains("/@") {
                let parts = inner.split(separator: "/@")
                if parts.count >= 2 {
                    let tagSelector = String(parts[0])
                    let attrName = String(parts[1])
                    let cssSelector = convertXPathToCSS(tagSelector) ?? tagSelector
                    return try? element.select(cssSelector).first()?.attr(attrName)
                }
            }

            // .//tag[contains(@class,'x')]/@attr
            if inner.contains("]/@") {
                let bracketIdx = inner.firstIndex(of: "]")
                if let idx = bracketIdx {
                    let tagSelector = String(inner[..<idx])
                    let attrPart = String(inner[inner.index(after: idx)...])
                    if attrPart.hasPrefix("/@") {
                        let attrName = String(attrPart.dropFirst(2))
                        let cssSelector = convertXPathToCSS(tagSelector) ?? tagSelector
                        return try? element.select(cssSelector).first()?.attr(attrName)
                    }
                }
            }

            // .//tag/@attr -> 末尾就是属性提取
            if inner.hasSuffix("@") {
                // 不可能... just skip
            }
            let attrName = String(inner.dropFirst(inner.distance(from: inner.startIndex, to: inner.lastIndex(of: "/") ?? inner.startIndex) + 1))
            if attrName.hasPrefix("@") {
                let actualAttr = String(attrName.dropFirst())
                let tagSelector = String(inner.dropLast(attrName.count))
                let cssSelector = convertXPathToCSS(tagSelector) ?? tagSelector
                return try? element.select(cssSelector).first()?.attr(actualAttr)
            }

            let cssSelector = convertXPathToCSS(inner) ?? inner
            return try? element.select(cssSelector).first()?.attr(attr)
        }

        // //tag/@attr
        if trimmed.hasPrefix("//") {
            let inner = String(trimmed.dropFirst(2))
            if inner.contains("/@") {
                let parts = inner.split(separator: "/@")
                if parts.count >= 2 {
                    let tagSelector = String(parts[0])
                    let attrName = String(parts[1])
                    let cssSelector = convertXPathToCSS(tagSelector) ?? tagSelector
                    return try? element.select(cssSelector).first()?.attr(attrName)
                }
            }
            let cssSelector = convertXPathToCSS(inner) ?? inner
            return try? element.select(cssSelector).first()?.attr(attr)
        }

        return nil
    }

    // MARK: - 工具方法

    /// 将相对 URL 转换为绝对 URL
    nonisolated func makeAbsoluteURL(_ url: String?, baseURL: String) -> String? {
        guard let url = url, !url.isEmpty else { return nil }

        if url.hasPrefix("http://") || url.hasPrefix("https://") {
            return url
        }

        var base = baseURL
        if base.hasSuffix("/") {
            base.removeLast()
        }

        var path = url
        if path.hasPrefix("//") {
            // //domain.com/path -> https://domain.com/path
            return "https:" + path
        }
        if path.hasPrefix("/") {
            // /path -> base/path
            path.removeFirst()
        }

        return "\(base)/\(path)"
    }

    private func defaultMetadata(for contentType: ContentType) -> ContentMetadata {
        switch contentType {
        case .wallpaper:
            return .wallpaper(.init(fullImageURL: "", resolution: nil, fileSize: nil, fileType: nil, purity: nil, uploader: nil, category: nil))
        case .anime:
            return .anime(.init(
                episodes: [],
                currentEpisode: nil,
                totalEpisodes: nil,
                status: nil,
                aired: nil,
                rating: nil
            ))
        case .video:
            return .video(.init(videoURL: "", duration: nil, resolution: nil, fileSize: nil, format: nil))
        }
    }
}

// MARK: - 解析错误

enum HTMLParserError: Error, LocalizedError {
    case invalidSelector(String)
    case parseFailed(String)
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .invalidSelector(let msg):
            return "Invalid selector: \(msg)"
        case .parseFailed(let msg):
            return "Parse failed: \(msg)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        }
    }
}

// MARK: - Elements 扩展

extension Elements {
    func attrValue(for attr: String) -> String? {
        guard let first = self.first() else { return nil }
        let val = (try? first.attr(attr)) ?? ""
        return val.isEmpty ? nil : val
    }
}
