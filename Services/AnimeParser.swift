import Foundation
import SwiftSoup

// MARK: - 动漫解析服务

/// 动漫内容解析服务
/// 支持多解析源自动切换：遍历多个规则，成功即返回
actor AnimeParser {
    static let shared = AnimeParser()

    private let htmlParser = HTMLParser.shared

    // MARK: - 搜索动漫

    /// 搜索动漫
    func search(
        query: String,
        rules: [AnimeRule]
    ) async throws -> [AnimeSearchResult] {
        for rule in rules where !rule.deprecated {
            do {
                let results = try await searchWithRule(query: query, rule: rule)
                if !results.isEmpty {
                    print("[AnimeParser] Found \(results.count) results using rule: \(rule.name)")
                    return results
                }
            } catch {
                print("[AnimeParser] Rule \(rule.name) failed: \(error)")
                continue
            }
        }
        return []
    }

    /// 使用指定规则搜索
    private func searchWithRule(query: String, rule: AnimeRule) async throws -> [AnimeSearchResult] {
        print("\n[AnimeParser] ========== 开始搜索 ========"=")
        print("[AnimeParser] 规则: \(rule.name) (id: \(rule.id), api: \(rule.api))")
        print("[AnimeParser] 关键词: \(query)")
        
        var url = rule.searchURL
        
        // 处理 XPath 格式 (API v2)
        if rule.api == "2", let xpath = rule.xpath, let search = xpath.search {
            url = search.url
            print("[AnimeParser] 使用 XPath 格式 URL: \(url)")
        }
        
        url = url
            .replacingOccurrences(of: "{keyword}", with: query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)
            .replacingOccurrences(of: "{page}", with: "1")
        
        print("[AnimeParser] 最终 URL: \(url)")

        let html = try await fetchHTML(url: url, rule: rule)
        print("[AnimeParser] HTML 长度: \(html.count) 字符")
        
        let results = try parseSearchResults(html: html, rule: rule)
        print("[AnimeParser] 解析结果: \(results.count) 条")
        print("[AnimeParser] ========== 搜索结束 ==========\n")
        
        return results
    }

    // MARK: - 获取详情

    func fetchDetail(
        detailURL: String,
        rule: AnimeRule
    ) async throws -> AnimeDetail {
        print("\n[AnimeParser] ========== 获取详情 ==========")
        print("[AnimeParser] 规则: \(rule.name)")
        print("[AnimeParser] URL: \(detailURL)")
        
        let html = try await fetchHTML(url: detailURL, rule: rule)
        print("[AnimeParser] HTML 长度: \(html.count) 字符")
        
        let detail = try parseDetail(html: html, detailURL: detailURL, rule: rule)
        
        print("[AnimeParser] 详情解析成功:")
        print("  标题: \(detail.title)")
        print("  剧集数: \(detail.episodes.count)")
        print("[AnimeParser] ========== 详情结束 ==========\n")
        
        return detail
    }

    // MARK: - 获取视频链接

    func fetchVideoSources(
        episodeURL: String,
        rule: AnimeRule
    ) async throws -> [VideoSource] {
        let html = try await fetchHTML(url: episodeURL, rule: rule)

        guard let selector = rule.videoSelector else {
            return try extractVideoFromHTML(html: html, baseURL: rule.baseURL)
        }

        let document = try SwiftSoup.parse(html)
        let elements = try document.select(selector)

        var sources: [VideoSource] = []

        for element in elements {
            let attrName = rule.videoSourceAttr ?? "src"

            var videoURL = (try? element.attr(attrName)) ?? ""
            if videoURL.isEmpty && attrName != "data-src" {
                videoURL = (try? element.attr("data-src")) ?? ""
            }

            guard !videoURL.isEmpty else { continue }

            if !videoURL.hasPrefix("http") {
                videoURL = HTMLParser.shared.makeAbsoluteURL(videoURL, baseURL: rule.baseURL) ?? videoURL
            }

            if isVideoURL(videoURL) {
                let quality = extractQuality(from: videoURL) ?? "embed"
                sources.append(VideoSource(
                    quality: quality,
                    url: videoURL,
                    type: "embed",
                    label: nil
                ))
            }
        }

        return sources
    }

    // MARK: - 多源自动切换

    func multiSourceSearch(
        query: String,
        rules: [AnimeRule]
    ) async -> [AnimeSearchResult] {
        var allResults: [AnimeSearchResult] = []

        await withTaskGroup(of: [AnimeSearchResult].self) { group in
            for rule in rules where !rule.deprecated {
                group.addTask {
                    do {
                        return try await self.searchWithRule(query: query, rule: rule)
                    } catch {
                        return []
                    }
                }
            }

            for await results in group {
                allResults.append(contentsOf: results)
            }
        }

        return allResults
    }

    // MARK: - HTML 获取

    private func fetchHTML(url: String, rule: AnimeRule) async throws -> String {
        guard let requestURL = URL(string: url) else {
            throw AnimeParserError.invalidURL(url)
        }

        var request = URLRequest(url: requestURL)
        request.timeoutInterval = TimeInterval(rule.timeout ?? 30)

        if let headers = rule.headers {
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }

        let (data, _) = try await URLSession.shared.data(for: request)
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - 搜索结果解析

    private func parseSearchResults(html: String, rule: AnimeRule) throws -> [AnimeSearchResult] {
        let document = try SwiftSoup.parse(html)
        
        // 根据规则 API 版本选择解析方式
        if rule.api == "2" {
            return try parseSearchResultsV2(html: html, rule: rule, document: document)
        } else {
            return try parseSearchResultsV1(html: html, rule: rule, document: document)
        }
    }
    
    /// API v1: 简化 CSS Selector 解析
    private func parseSearchResultsV1(html: String, rule: AnimeRule, document: Document) throws -> [AnimeSearchResult] {
        let listSelector = rule.searchList ?? "a"
        print("[AnimeParser] V1 解析 - 列表选择器: \(listSelector)")
        
        let elements = try document.select(listSelector)
        print("[AnimeParser] 找到 \(elements.count) 个元素")

        var results: [AnimeSearchResult] = []

        for element in elements {
            // 提取标题
            var title: String? = nil
            if let nameSelector = rule.searchName, !nameSelector.isEmpty {
                title = try? element.select(nameSelector).first()?.text()
            }
            if title == nil {
                title = try? element.text()
            }
            let finalTitle = (title ?? "Untitled").trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

            // 提取封面
            var cover: String? = nil
            if let coverSelector = rule.searchCover, !coverSelector.isEmpty {
                cover = extractAttr(element: element, selector: coverSelector, attr: "src")
                    ?? extractAttr(element: element, selector: coverSelector, attr: "data-src")
            }
            if cover == nil {
                // 默认从 img 标签提取
                cover = try? element.select("img").first()?.attr("src")
                    ?? element.select("img").first()?.attr("data-src")
            }

            // 提取详情链接
            var detail: String? = nil
            if let detailSelector = rule.searchDetail, !detailSelector.isEmpty {
                detail = extractAttr(element: element, selector: detailSelector, attr: "href")
            }
            if detail == nil {
                // 默认从 a 标签提取
                detail = try? element.select("a").first()?.attr("href")
            }
            
            guard let detailURL = detail, !detailURL.isEmpty else { 
                print("[AnimeParser] ⚠️ 跳过元素: 无详情链接")
                continue 
            }

            // 提取 ID
            let id = rule.searchId.flatMap { extractAttr(element: element, selector: $0, attr: "href") }
                ?? detailURL

            let fullDetailURL = HTMLParser.shared.makeAbsoluteURL(detailURL, baseURL: rule.baseURL) ?? detailURL
            let fullCoverURL = HTMLParser.shared.makeAbsoluteURL(cover, baseURL: rule.baseURL)
            
            print("[AnimeParser] ✓ 解析成功: \(finalTitle)")
            print("         详情: \(fullDetailURL)")
            print("         封面: \(fullCoverURL ?? "无")")

            results.append(AnimeSearchResult(
                id: id,
                title: finalTitle,
                coverURL: fullCoverURL,
                detailURL: fullDetailURL,
                sourceId: rule.id,
                sourceName: rule.name,
                latestEpisode: nil
            ))
        }

        return results
    }
    
    /// API v2: XPath 解析 (兼容 Kazumi)
    private func parseSearchResultsV2(html: String, rule: AnimeRule, document: Document) throws -> [AnimeSearchResult] {
        guard let xpath = rule.xpath, let searchXPath = xpath.search else {
            throw AnimeParserError.parseError("Missing xpath.search configuration")
        }
        
        // 使用 HTMLParser 的 XPath 转 CSS 功能
        let listSelector = HTMLParser.shared.convertXPathToCSS(searchXPath.list) ?? searchXPath.list
        let elements = try document.select(listSelector)
        
        var results: [AnimeSearchResult] = []
        
        for element in elements {
            // 提取标题
            let title = try? HTMLParser.shared.extractText(element: element, xpath: searchXPath.title)
                ?? element.text()
            
            // 提取封面
            let cover = HTMLParser.shared.extractAttr(
                element: element,
                xpath: searchXPath.cover,
                attr: "src"
            ) ?? HTMLParser.shared.extractAttr(
                element: element,
                xpath: searchXPath.cover,
                attr: "data-src"
            )
            
            // 提取详情链接
            let detail = HTMLParser.shared.extractAttr(
                element: element,
                xpath: searchXPath.detail,
                attr: "href"
            )
            
            guard let detailURL = detail, !detailURL.isEmpty else { continue }
            
            let id = searchXPath.id.flatMap { 
                HTMLParser.shared.extractAttr(element: element, xpath: $0, attr: "href") 
            } ?? detailURL
            
            let fullDetailURL = HTMLParser.shared.makeAbsoluteURL(detailURL, baseURL: rule.baseURL) ?? detailURL
            let fullCoverURL = HTMLParser.shared.makeAbsoluteURL(cover, baseURL: rule.baseURL)
            
            results.append(AnimeSearchResult(
                id: id,
                title: (title ?? "Untitled").trimmingCharacters(in: .whitespacesAndNewlines),
                coverURL: fullCoverURL,
                detailURL: fullDetailURL,
                sourceId: rule.id,
                sourceName: rule.name,
                latestEpisode: nil
            ))
        }
        
        return results
    }

    // MARK: - 详情解析

    private func parseDetail(html: String, detailURL: String, rule: AnimeRule) throws -> AnimeDetail {
        let document = try SwiftSoup.parse(html)
        
        // 根据规则 API 版本选择解析方式
        if rule.api == "2" {
            return try parseDetailV2(html: html, detailURL: detailURL, rule: rule, document: document)
        } else {
            return try parseDetailV1(html: html, detailURL: detailURL, rule: rule, document: document)
        }
    }
    
    /// API v1: 简化 CSS Selector 解析
    private func parseDetailV1(html: String, detailURL: String, rule: AnimeRule, document: Document) throws -> AnimeDetail {
        // 提取标题
        var title: String? = nil
        if let titleSelector = rule.detailTitle, !titleSelector.isEmpty {
            title = try? document.select(titleSelector).first()?.text()
        }
        let finalTitle = title ?? "Unknown"
        
        // 提取封面
        var cover: String? = nil
        if let coverSelector = rule.detailCover, !coverSelector.isEmpty {
            cover = extractAttr(element: document, selector: coverSelector, attr: "src")
                ?? extractAttr(element: document, selector: coverSelector, attr: "data-src")
        }
        
        // 提取描述、状态、评分
        let description = rule.detailDesc.flatMap { try? document.select($0).first()?.text() }
        let status = rule.detailStatus.flatMap { try? document.select($0).first()?.text() }
        let rating = rule.detailRating.flatMap { try? document.select($0).first()?.text() }

        // 解析剧集列表
        var episodes: [AnimeDetail.AnimeEpisodeItem] = []
        if let listSelector = rule.episodeList, !listSelector.isEmpty {
            let episodeElements = try document.select(listSelector)
            for (index, element) in episodeElements.array().enumerated() {
                // 提取剧集链接
                var episodeLink: String? = nil
                if let linkSelector = rule.episodeLink, !linkSelector.isEmpty {
                    episodeLink = extractAttr(element: element, selector: linkSelector, attr: "href")
                }
                if episodeLink == nil {
                    // 默认从 a 标签提取
                    episodeLink = try? element.select("a").first()?.attr("href")
                }
                
                guard let link = episodeLink, !link.isEmpty else { continue }

                // 提取剧集名称
                var name: String? = nil
                if let nameSelector = rule.episodeName, !nameSelector.isEmpty {
                    name = try? element.select(nameSelector).first()?.text()
                }
                if name == nil {
                    name = try? element.text()
                }
                
                // 提取剧集缩略图
                var thumb: String? = nil
                if let thumbSelector = rule.episodeThumb, !thumbSelector.isEmpty {
                    thumb = extractAttr(element: element, selector: thumbSelector, attr: "src")
                        ?? extractAttr(element: element, selector: thumbSelector, attr: "data-src")
                }

                let fullLink = HTMLParser.shared.makeAbsoluteURL(link, baseURL: rule.baseURL) ?? link
                let fullThumb = HTMLParser.shared.makeAbsoluteURL(thumb, baseURL: rule.baseURL)

                episodes.append(AnimeDetail.AnimeEpisodeItem(
                    id: fullLink,
                    name: name?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines),
                    episodeNumber: index + 1,
                    url: fullLink,
                    thumbnailURL: fullThumb
                ))
            }
        }

        let fullCoverURL = HTMLParser.shared.makeAbsoluteURL(cover, baseURL: rule.baseURL)

        return AnimeDetail(
            id: detailURL,
            title: finalTitle,
            coverURL: fullCoverURL,
            description: description,
            status: status,
            rating: rating,
            episodes: episodes,
            sourceId: rule.id
        )
    }
    
    /// API v2: XPath 解析 (兼容 Kazumi)
    private func parseDetailV2(html: String, detailURL: String, rule: AnimeRule, document: Document) throws -> AnimeDetail {
        guard let xpath = rule.xpath, let detailXPath = xpath.detail else {
            throw AnimeParserError.parseError("Missing xpath.detail configuration")
        }
        
        // 提取标题
        let title = detailXPath.title.flatMap { selector in
            try? document.select(selector).first()?.text()
        } ?? "Unknown"
        
        // 提取封面
        let cover = detailXPath.cover.flatMap { selector in
            extractAttr(element: document, selector: selector, attr: "src")
                ?? extractAttr(element: document, selector: selector, attr: "data-src")
        }
        
        // 提取描述
        let description = detailXPath.description.flatMap { selector in
            try? document.select(selector).first()?.text()
        }
        
        // 解析剧集列表
        var episodes: [AnimeDetail.AnimeEpisodeItem] = []
        if let episodesSelector = detailXPath.episodes {
            let cssSelector = HTMLParser.shared.convertXPathToCSS(episodesSelector) ?? episodesSelector
            let episodeElements = try document.select(cssSelector)
            
            for (index, element) in episodeElements.array().enumerated() {
                // 提取剧集链接
                let link = detailXPath.episodeLink.flatMap { linkPattern in
                    extractAttr(element: element, selector: linkPattern, attr: "href")
                }
                
                guard let episodeLink = link, !episodeLink.isEmpty else { continue }
                
                // 提取剧集名称
                let name = detailXPath.episodeName.flatMap { namePattern in
                    try? element.select(namePattern).first()?.text()
                }
                
                // 提取剧集缩略图
                let thumb = detailXPath.episodeThumb.flatMap { thumbPattern in
                    extractAttr(element: element, selector: thumbPattern, attr: "src")
                        ?? extractAttr(element: element, selector: thumbPattern, attr: "data-src")
                }
                
                let fullLink = HTMLParser.shared.makeAbsoluteURL(episodeLink, baseURL: rule.baseURL) ?? episodeLink
                let fullThumb = HTMLParser.shared.makeAbsoluteURL(thumb, baseURL: rule.baseURL)
                
                episodes.append(AnimeDetail.AnimeEpisodeItem(
                    id: fullLink,
                    name: name?.trimmingCharacters(in: .whitespacesAndNewlines),
                    episodeNumber: index + 1,
                    url: fullLink,
                    thumbnailURL: fullThumb
                ))
            }
        }
        
        let fullCoverURL = HTMLParser.shared.makeAbsoluteURL(cover, baseURL: rule.baseURL)
        
        return AnimeDetail(
            id: detailURL,
            title: title,
            coverURL: fullCoverURL,
            description: description,
            status: nil,
            rating: nil,
            episodes: episodes,
            sourceId: rule.id
        )
    }

    // MARK: - 通用视频提取

    private func extractVideoFromHTML(html: String, baseURL: String) throws -> [VideoSource] {
        let document = try SwiftSoup.parse(html)
        var sources: [VideoSource] = []

        // 提取 video 标签
        let videos = try document.select("video")
        for video in videos {
            let src = (try? video.attr("src")) ?? (try? video.attr("data-src")) ?? ""
            if isVideoURL(src) {
                let fullURL = HTMLParser.shared.makeAbsoluteURL(src, baseURL: baseURL) ?? src
                sources.append(VideoSource(
                    quality: "auto",
                    url: fullURL,
                    type: "video",
                    label: nil
                ))
            }

            let videoSources = try video.select("source")
            for vs in videoSources {
                let src = (try? vs.attr("src")) ?? ""
                if isVideoURL(src) {
                    let fullURL = HTMLParser.shared.makeAbsoluteURL(src, baseURL: baseURL) ?? src
                    let quality = (try? vs.attr("label")) ?? (try? vs.attr("data-quality")) ?? "auto"
                    sources.append(VideoSource(
                        quality: quality,
                        url: fullURL,
                        type: "source",
                        label: try? vs.attr("label")
                    ))
                }
            }
        }

        // 提取 iframe (嵌入播放器)
        let iframes = try document.select("iframe")
        for iframe in iframes {
            let src = (try? iframe.attr("src")) ?? (try? iframe.attr("data-src")) ?? ""
            if isEmbedURL(src) {
                let fullURL = HTMLParser.shared.makeAbsoluteURL(src, baseURL: baseURL) ?? src
                sources.append(VideoSource(
                    quality: "embed",
                    url: fullURL,
                    type: "embed",
                    label: nil
                ))
            }
        }

        return sources
    }

    // MARK: - 辅助方法

    private func extractAttr(element: SwiftSoup.Element, selector: String, attr: String) -> String? {
        guard let el = try? element.select(selector).first() else { return nil }
        let val = (try? el.attr(attr)) ?? ""
        return val.isEmpty ? nil : val
    }

    private func extractAttr(element: SwiftSoup.Document, selector: String, attr: String) -> String? {
        guard let el = try? element.select(selector).first() else { return nil }
        let val = (try? el.attr(attr)) ?? ""
        return val.isEmpty ? nil : val
    }

    private func isVideoURL(_ url: String) -> Bool {
        let videoExtensions = ["mp4", "m3u8", "webm", "mkv", "avi", "mov"]
        let lowercased = url.lowercased()
        return videoExtensions.contains { lowercased.contains($0) }
    }

    private func isEmbedURL(_ url: String) -> Bool {
        let embedHosts = ["player", "embed", "stream", "video", "watch"]
        let lowercased = url.lowercased()
        return embedHosts.contains { lowercased.contains($0) } && url.contains("://")
    }

    private func extractQuality(from url: String) -> String? {
        let patterns = ["(\\d{3,4})p", "(\\d{3,4})_", "quality=(\\w+)", "(\\d{3,4})\\."]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)),
               let range = Range(match.range(at: 1), in: url) {
                return String(url[range])
            }
        }
        return nil
    }
}

// MARK: - 解析错误

enum AnimeParserError: Error, LocalizedError {
    case invalidURL(String)
    case parseError(String)
    case noRulesAvailable
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "Invalid URL: \(url)"
        case .parseError(let msg):
            return "Parse error: \(msg)"
        case .noRulesAvailable:
            return "No anime rules available"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        }
    }
}
