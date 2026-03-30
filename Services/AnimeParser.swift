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
        let url = rule.searchURL
            .replacingOccurrences(of: "{keyword}", with: query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)
            .replacingOccurrences(of: "{page}", with: "1")

        let html = try await fetchHTML(url: url, rule: rule)
        return try parseSearchResults(html: html, rule: rule)
    }

    // MARK: - 获取详情

    func fetchDetail(
        detailURL: String,
        rule: AnimeRule
    ) async throws -> AnimeDetail {
        let html = try await fetchHTML(url: detailURL, rule: rule)
        return try parseDetail(html: html, detailURL: detailURL, rule: rule)
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
        let listSelector = rule.searchList
        let elements = try document.select(listSelector)

        var results: [AnimeSearchResult] = []

        for element in elements {
            // 提取标题 (使用 CSS 选择器提取文本)
            let title = try? element.select(rule.searchName).first()?.text()
                ?? (try? element.text())
                ?? "Untitled"

            // 提取封面
            let cover = extractAttr(element: element, selector: rule.searchCover, attr: "src")
                ?? extractAttr(element: element, selector: rule.searchCover, attr: "data-src")

            // 提取详情链接
            let detail = extractAttr(element: element, selector: rule.searchDetail, attr: "href")

            guard let detailURL = detail else { continue }

            // 提取 ID
            let id = extractAttr(element: element, selector: rule.searchId ?? rule.searchDetail, attr: "href")
                ?? detailURL

            let fullDetailURL = HTMLParser.shared.makeAbsoluteURL(detailURL, baseURL: rule.baseURL) ?? detailURL
            let fullCoverURL = HTMLParser.shared.makeAbsoluteURL(cover, baseURL: rule.baseURL)

            results.append(AnimeSearchResult(
                id: id,
                title: (title ?? "Untitled").trimmingCharacters(in: CharacterSet.whitespacesAndNewlines),
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

        let title = try (document.select(rule.detailTitle ?? "h1").first()?.text())
            ?? "Unknown"

        let cover = extractAttr(element: document, selector: rule.detailCover ?? "img", attr: "src")
            ?? extractAttr(element: document, selector: rule.detailCover ?? "img", attr: "data-src")

        let description = try? document.select(rule.detailDesc ?? "p").first()?.text()
        let status = try? document.select(rule.detailStatus ?? "span").first()?.text()
        let rating = try? document.select(rule.detailRating ?? "span").first()?.text()

        // 解析剧集列表
        var episodes: [AnimeDetail.AnimeEpisodeItem] = []
        if let listSelector = rule.episodeList {
            let episodeElements = try document.select(listSelector)
            for (index, element) in episodeElements.array().enumerated() {
                let episodeLink = extractAttr(element: element, selector: rule.episodeLink ?? "a", attr: "href")
                guard let link = episodeLink, !link.isEmpty else { continue }

                let name = try? element.text()
                let thumb = extractAttr(element: element, selector: rule.episodeThumb ?? "img", attr: "src")

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
            title: title,
            coverURL: fullCoverURL,
            description: description,
            status: status,
            rating: rating,
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
