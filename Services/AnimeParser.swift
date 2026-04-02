import Foundation
import SwiftSoup
import Kanna

// MARK: - 动漫解析服务

/// 动漫内容解析服务
/// 支持多解析源自动切换：遍历多个规则，成功即返回
actor AnimeParser {
    static let shared = AnimeParser()

    private let htmlParser = HTMLParser.shared

    // MARK: - 搜索动漫

    /// 搜索动漫（多源自动切换）
    func search(
        query: String,
        rules: [AnimeRule],
        page: Int = 1
    ) async throws -> [AnimeSearchResult] {
        for rule in rules where !rule.deprecated {
            do {
                let results = try await searchWithRule(query: query, rule: rule, page: page)
                if !results.isEmpty {
                    print("[AnimeParser] Found \(results.count) results using rule: \(rule.name)")
                    return results
                }
            } catch let error as AnimeParserError {
                // captcha、noResult 直接抛出，不尝试其他源
                switch error {
                case .captchaRequired, .noResult:
                    throw error
                default:
                    print("[AnimeParser] Rule \(rule.name) failed: \(error)")
                    continue
                }
            } catch {
                print("[AnimeParser] Rule \(rule.name) failed: \(error)")
                continue
            }
        }
        return []
    }

    // MARK: - 查询 Bangumi 详情页播放列表 (Kazumi querychapterRoads)

    /// 使用规则的 chapterRoads 选择器解析 Bangumi 详情页的播放列表
    /// 参考 Kazumi Plugin.querychapterRoads
    func querychapterRoads(detailURL: String, rule: AnimeRule) async throws -> [AnimeDetail] {
        print("\n[AnimeParser] ========== 查询 Bangumi 详情页 ==========")
        print("[AnimeParser] 规则: \(rule.name) (id: \(rule.id), api: \(rule.api))")
        print("[AnimeParser] 详情页 URL: \(detailURL)")

        // 构建完整 URL（处理相对路径）
        var url = detailURL
        if !url.hasPrefix("http") && !url.hasPrefix("https") {
            if url.hasPrefix("//") {
                url = "https:" + url
            } else if url.hasPrefix("/") {
                url = rule.baseURL.trimmingCharacters(in: .whitespacesAndNewlines) + url
            }
        }

        print("[AnimeParser] 最终 URL: \(url)")

        let html: String
        do {
            html = try await fetchHTML(url: url, rule: rule)
        } catch {
            print("[AnimeParser] 获取详情页失败: \(error)")
            throw AnimeParserError.networkError(error)
        }

        print("[AnimeParser] HTML 长度: \(html.count) 字符")

        // 检测验证码
        if let antiCrawler = rule.antiCrawlerConfig, antiCrawler.enabled {
            if detectCaptcha(in: html, config: antiCrawler) {
                print("[AnimeParser] ⚠️ 检测到验证码")
                throw AnimeParserError.captchaRequired
            }
        }

        if detectCommonCaptcha(in: html) {
            print("[AnimeParser] ⚠️ 检测到验证码（关键词）")
            throw AnimeParserError.captchaRequired
        }

        // 判断使用 XPath 还是 CSS 选择器
        if rule.api != "1", let detailXPath = rule.xpath?.detail {
            // 使用 XPath 解析 (Kazumi v2 规则)
            return try await parseChapterRoadsWithXPath(html: html, url: url, rule: rule, detailXPath: detailXPath)
        } else {
            // 使用 CSS 选择器解析 (v1 规则)
            return try await parseChapterRoadsWithCSS(html: html, url: url, rule: rule)
        }
    }

    /// 使用 XPath 解析剧集列表 (Kazumi v2 规则)
    private func parseChapterRoadsWithXPath(html: String, url: String, rule: AnimeRule, detailXPath: AnimeDetailXPath) async throws -> [AnimeDetail] {
        let chapterRoads = detailXPath.episodes ?? ""
        let chapterResult = rule.xpath?.list?.list ?? ""

        print("[AnimeParser] 使用 XPath 解析")
        print("[AnimeParser] chapterRoads: \(chapterRoads)")
        print("[AnimeParser] chapterResult: \(chapterResult)")

        let roads = try HTMLXPathParser.parseChapterRoads(
            html: html,
            chapterRoads: chapterRoads,
            chapterResult: chapterResult
        )

        print("[AnimeParser] 找到 \(roads.count) 个播放列表")

        var details: [AnimeDetail] = []
        for (index, road) in roads.enumerated() {
            let episodes = road.episodes.map { ep in
                AnimeDetail.AnimeEpisodeItem(
                    id: ep.url,
                    name: ep.name,
                    episodeNumber: 0, // 将在后面设置
                    url: ep.url,
                    thumbnailURL: nil
                )
            }

            // 处理相对路径并设置剧集编号
            let processedEpisodes = episodes.enumerated().map { (index, ep) -> AnimeDetail.AnimeEpisodeItem in
                var finalURL = ep.url
                if !finalURL.hasPrefix("http") {
                    if finalURL.hasPrefix("//") {
                        finalURL = "https:" + finalURL
                    } else if finalURL.hasPrefix("/") {
                        finalURL = rule.baseURL + finalURL
                    } else {
                        finalURL = rule.baseURL + "/" + finalURL
                    }
                }
                return AnimeDetail.AnimeEpisodeItem(
                    id: finalURL,
                    name: ep.name,
                    episodeNumber: index + 1,  // 使用索引作为剧集编号
                    url: finalURL,
                    thumbnailURL: nil
                )
            }

            let detail = AnimeDetail(
                id: url + "#\(index)",
                title: road.roadName,
                coverURL: nil,
                description: nil,
                status: nil,
                rating: nil,
                episodes: processedEpisodes,
                sourceId: rule.id
            )
            details.append(detail)
        }

        print("[AnimeParser] 解析完成: 共 \(details.count) 个播放列表")
        print("[AnimeParser] ========== 查询结束 ==========\n")

        if details.isEmpty {
            throw AnimeParserError.noResult
        }

        return details
    }

    /// 使用 CSS 选择器解析剧集列表 (v1 规则)
    private func parseChapterRoadsWithCSS(html: String, url: String, rule: AnimeRule) async throws -> [AnimeDetail] {
        let document = try SwiftSoup.parse(html)
        let roadElements = try document.select(rule.episodeList ?? "")
        print("[AnimeParser] 使用 CSS 选择器解析，找到 \(roadElements.count) 个播放列表")

        var details: [AnimeDetail] = []
        var count = 1

        for element in roadElements {
            let roadName = (try? element.text().trimmingCharacters(in: .whitespacesAndNewlines)) ?? "播放列表\(count)"

            let episodes: [AnimeDetail.AnimeEpisodeItem] = (try? element.select("a").array().compactMap { epElement in
                guard let href = try? epElement.attr("href"), !href.isEmpty,
                      let name = try? epElement.text().trimmingCharacters(in: .whitespacesAndNewlines) else {
                    return nil
                }
                var finalURL = href
                if !finalURL.hasPrefix("http") {
                    finalURL = rule.baseURL + (finalURL.hasPrefix("/") ? "" : "/") + finalURL
                }
                return AnimeDetail.AnimeEpisodeItem(
                    id: finalURL,
                    name: name,
                    episodeNumber: count,
                    url: finalURL,
                    thumbnailURL: nil
                )
            }) ?? []

            if !episodes.isEmpty {
                details.append(AnimeDetail(
                    id: url,
                    title: roadName,
                    coverURL: nil,
                    description: nil,
                    status: nil,
                    rating: nil,
                    episodes: episodes,
                    sourceId: rule.id
                ))
                count += 1
            }
        }

        if details.isEmpty {
            throw AnimeParserError.noResult
        }

        return details
    }

    // MARK: - 使用指定规则搜索 (Kazumi 风格)

    /// 使用指定规则搜索（参考 Kazumi Plugin.queryBangumi）
    /// 支持 XPath (v2) 和 CSS (v1) 两种规则格式
    func searchWithRule(query: String, rule: AnimeRule, page: Int = 1) async throws -> [AnimeSearchResult] {
        print("\n[AnimeParser] ========== 开始搜索 ==========")
        print("[AnimeParser] 规则: \(rule.name) (id: \(rule.id), api: \(rule.api))")
        print("[AnimeParser] 关键词: \(query), 页码: \(page)")

        var url = rule.searchURL

        // 处理 XPath 格式 (API v2)
        if rule.api != "1", let xpath = rule.xpath, let search = xpath.search {
            url = search.url
            print("[AnimeParser] 使用 XPath 格式 URL: \(url)")
        }

        // Kazumi 风格：对关键词进行百分编码
        // 注意：中文需要编码才能作为 URL 参数
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        url = url
            .replacingOccurrences(of: "{keyword}", with: encodedQuery)
            .replacingOccurrences(of: "{page}", with: "\(page)")
            .replacingOccurrences(of: "@keyword", with: encodedQuery)

        print("[AnimeParser] 最终 URL: \(url)")

        let html: String
        do {
            html = try await fetchHTML(url: url, rule: rule)
        } catch {
            print("[AnimeParser] 网络请求失败: \(error)")
            throw AnimeParserError.networkError(error)
        }

        print("[AnimeParser] HTML 长度: \(html.count) 字符")

        // 检测验证码
        if let antiCrawler = rule.antiCrawlerConfig, antiCrawler.enabled {
            if detectCaptcha(in: html, config: antiCrawler) {
                print("[AnimeParser] ⚠️ 检测到验证码")
                throw AnimeParserError.captchaRequired
            }
        }

        if detectCommonCaptcha(in: html) {
            print("[AnimeParser] ⚠️ 检测到验证码（关键词）")
            throw AnimeParserError.captchaRequired
        }

        // 根据 API 版本选择解析方式
        let results: [AnimeSearchResult]
        if rule.api != "1", let search = rule.xpath?.search {
            // 使用 XPath 解析 (v2 规则)
            results = try await parseSearchResultsWithXPath(html: html, rule: rule, search: search, searchQuery: query)
        } else {
            // 使用 CSS 选择器解析 (v1 规则)
            results = try await parseSearchResults(html: html, rule: rule, searchQuery: query)
        }

        print("[AnimeParser] 解析结果: \(results.count) 条")
        for (index, result) in results.prefix(3).enumerated() {
            print("[AnimeParser]   [\(index + 1)] \(result.title)")
        }
        print("[AnimeParser] ========== 搜索结束 ==========\n")

        if results.isEmpty {
            throw AnimeParserError.noResult
        }

        return results
    }

    /// 使用 XPath 解析搜索结果 (v2 规则)
    private func parseSearchResultsWithXPath(html: String, rule: AnimeRule, search: AnimeSearchXPath, searchQuery: String? = nil) async throws -> [AnimeSearchResult] {
        print("[AnimeParser] 使用 XPath 解析搜索")
        print("[AnimeParser] searchList: \(search.list)")
        print("[AnimeParser] searchName: \(search.title)")
        print("[AnimeParser] searchResult: \(search.detail)")

        let items = try HTMLXPathParser.parseSearchResults(
            html: html,
            searchList: search.list,
            searchName: search.title,
            searchResult: search.detail,
            searchQuery: searchQuery
        )

        print("[AnimeParser] XPath 解析到 \(items.count) 个结果")

        return items.map { item in
            let fullURL = item.src.hasPrefix("http") ? item.src : rule.baseURL + item.src
            return AnimeSearchResult(
                id: fullURL,
                title: item.name,
                coverURL: nil,
                detailURL: item.src,
                sourceId: rule.id,
                sourceName: rule.name,
                latestEpisode: nil,
                rating: nil
            )
        }
    }

    /// 检测验证码（参考 Kazumi）
    private func detectCaptcha(in html: String, config: AntiCrawlerConfig) -> Bool {
        let document = try? SwiftSoup.parse(html)

        // 检查验证码图片选择器
        if !config.captchaImage.isEmpty {
            if let _ = try? document?.select(config.captchaImage).first() {
                return true
            }
        }

        // 检查验证码按钮选择器
        if !config.captchaButton.isEmpty {
            if let _ = try? document?.select(config.captchaButton).first() {
                return true
            }
        }

        return false
    }

    /// 检测常见验证码关键词
    private func detectCommonCaptcha(in html: String) -> Bool {
        let lowercased = html.lowercased()
        let captchaKeywords = [
            "captcha", "验证码", "验证", "人机验证", "安全验证",
            "请点击", "请滑动", "请勾选", "i'm not a robot"
        ]
        return captchaKeywords.contains { lowercased.contains($0) }
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
        print("[AnimeParser] ========== 提取视频源 ==========")
        print("[AnimeParser] URL: \(episodeURL)")
        print("[AnimeParser] 规则: \(rule.name)")
        print("[AnimeParser] videoSelector: \(rule.videoSelector ?? "nil")")

        let html = try await fetchHTML(url: episodeURL, rule: rule)
        print("[AnimeParser] HTML 长度: \(html.count) 字符")

        guard let selector = rule.videoSelector else {
            print("[AnimeParser] 无 videoSelector，尝试通用提取")
            let sources = try extractVideoFromHTML(html: html, baseURL: rule.baseURL)
            print("[AnimeParser] 通用提取找到 \(sources.count) 个源")
            return sources
        }

        let document = try SwiftSoup.parse(html)
        let elements = try document.select(selector)
        print("[AnimeParser] 选择器 '\(selector)' 找到 \(elements.count) 个元素")

        var sources: [VideoSource] = []

        for (index, element) in elements.enumerated() {
            let attrName = rule.videoSourceAttr ?? "src"

            var videoURL = (try? element.attr(attrName)) ?? ""
            if videoURL.isEmpty && attrName != "data-src" {
                videoURL = (try? element.attr("data-src")) ?? ""
            }

            print("[AnimeParser]   [\(index)] attr(\(attrName)): \(videoURL.prefix(100))")

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
                print("[AnimeParser]   ✓ 有效视频源: \(videoURL.prefix(80))...")
            } else {
                print("[AnimeParser]   ✗ 无效 URL: \(videoURL.prefix(80))...")
            }
        }

        print("[AnimeParser] 总共找到 \(sources.count) 个视频源")
        print("[AnimeParser] ========== 提取结束 ==========")

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

        if let userAgent = rule.userAgent, !userAgent.isEmpty {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }

        let (data, _) = try await URLSession.shared.data(for: request)
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - 搜索结果解析

    private func parseSearchResults(html: String, rule: AnimeRule, searchQuery: String? = nil) async throws -> [AnimeSearchResult] {
        // 如果 api == "2" 且有 xpath 配置，使用 XPath 解析
        if rule.api != "1", let search = rule.xpath?.search {
            print("[AnimeParser] 使用 XPath 解析搜索 (v2)")
            return try await parseSearchResultsWithXPath(html: html, rule: rule, search: search, searchQuery: searchQuery)
        }

        // 否则使用 CSS 选择器 (v1)
        print("[AnimeParser] 使用 CSS 选择器解析 (v1)")
        return try parseSearchResultsV1(html: html, rule: rule, searchQuery: searchQuery)
    }

    /// API v1: 简化 CSS Selector 解析
    private func parseSearchResultsV1(html: String, rule: AnimeRule, searchQuery: String? = nil) throws -> [AnimeSearchResult] {
        let document = try SwiftSoup.parse(html)
        let listSelector = rule.searchList ?? "a"
        print("[AnimeParser] V1 解析 - 列表选择器: \(listSelector)")

        let elements = try document.select(listSelector)
        print("[AnimeParser] 找到 \(elements.count) 个元素")

        var results: [AnimeSearchResult] = []

        // 无效标题列表（导航、页脚等常见非内容链接）
        let invalidTitles = ["首页", "主页", "home", "上一页", "下一页", "尾页", "关于我们", "联系我们", "帮助", "登录", "注册"]
        // 无效 URL 路径
        let invalidPaths = ["/", "/index.html", "/index.php", "#", ""]

        // 搜索查询关键词（用于匹配度评分）
        let queryKeywords = searchQuery?.lowercased().components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)).filter { !$0.isEmpty } ?? []

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

            // 跳过无效标题
            let lowerTitle = finalTitle.lowercased()
            if invalidTitles.contains(where: { lowerTitle == $0.lowercased() || lowerTitle.hasPrefix($0.lowercased()) }) {
                print("[AnimeParser] ⚠️ 跳过导航项: \(finalTitle)")
                continue
            }

            // Kazumi 风格：标题匹配度检查
            // 如果搜索结果标题与查询词完全不相关，可能是无效结果
            if !queryKeywords.isEmpty {
                let titleKeywords = lowerTitle.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)).filter { !$0.isEmpty }
                let hasMatchingKeyword = queryKeywords.contains { queryWord in
                    titleKeywords.contains { titleWord in
                        titleWord.contains(queryWord) || queryWord.contains(titleWord)
                    }
                }
                // 如果没有匹配的关键词且标题很短（可能是广告/推荐），跳过
                if !hasMatchingKeyword && finalTitle.count < 10 {
                    print("[AnimeParser] ⚠️ 跳过低匹配度结果: \(finalTitle)")
                    continue
                }
            }

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

            // 过滤无效链接
            let invalidPrefixes = ["javascript:", "mailto:", "tel:", "data:"]
            if invalidPrefixes.contains(where: { detailURL.lowercased().hasPrefix($0) }) {
                print("[AnimeParser] ⚠️ 跳过无效链接: \(detailURL)")
                continue
            }

            // 跳过指向首页的链接
            let lowerDetailURL = detailURL.lowercased()
            if invalidPaths.contains(lowerDetailURL) ||
               invalidPaths.contains(where: { lowerDetailURL.hasSuffix($0) && $0 != "#" }) {
                print("[AnimeParser] ⚠️ 跳过首页链接: \(detailURL) (标题: \(finalTitle))")
                continue
            }

            // 跳过纯锚点链接
            if detailURL.hasPrefix("#") {
                print("[AnimeParser] ⚠️ 跳过锚点链接: \(detailURL)")
                continue
            }

            let fullDetailURL = HTMLParser.shared.makeAbsoluteURL(detailURL, baseURL: rule.baseURL) ?? detailURL
            let fullCoverURL = HTMLParser.shared.makeAbsoluteURL(cover, baseURL: rule.baseURL)

            // 生成唯一 ID：使用 URL + 标题组合（避免相同 URL 但不同标题的情况）
            let uniqueId = fullDetailURL + "|" + finalTitle

            // 检查是否已存在（去重）
            if results.contains(where: { $0.id == uniqueId }) {
                print("[AnimeParser] ⚠️ 跳过重复结果: \(finalTitle)")
                continue
            }

            print("[AnimeParser] ✓ 解析成功: \(finalTitle)")

            results.append(AnimeSearchResult(
                id: uniqueId,
                title: finalTitle,
                coverURL: fullCoverURL,
                detailURL: fullDetailURL,
                sourceId: rule.id,
                sourceName: rule.name,
                latestEpisode: nil,
                rating: nil
            ))
        }

        return results
    }

    // MARK: - 详情解析

    private func parseDetail(html: String, detailURL: String, rule: AnimeRule) throws -> AnimeDetail {
        let document = try SwiftSoup.parse(html)
        
        // 根据规则 API 版本选择解析方式
        if rule.api != "1" {
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
    case captchaRequired
    case noResult

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
        case .captchaRequired:
            return "Captcha verification required"
        case .noResult:
            return "No search results found"
        }
    }
}
