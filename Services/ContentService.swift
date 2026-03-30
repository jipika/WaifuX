import Foundation

// MARK: - 统一内容服务

actor ContentService {
    static let shared = ContentService()

    private let ruleLoader = RuleLoader.shared
    private let networkService = NetworkService.shared
    private let htmlParser = HTMLParser.shared

    // 缓存
    private var searchCache: [String: [UniversalContentItem]] = [:]
    private var detailCache: [String: UniversalContentItem] = [:]

    // MARK: - 搜索内容

    func search(
        query: String,
        contentType: ContentType,
        source: String? = nil,
        page: Int = 1
    ) async throws -> [UniversalContentItem] {
        let rules = source != nil
            ? [await ruleLoader.rule(for: source!)].compactMap { $0 }
            : await ruleLoader.rules(for: contentType)

        guard !rules.isEmpty else {
            throw ContentError.noRulesAvailable
        }

        var allItems: [UniversalContentItem] = []

        // 并行搜索所有源
        await withTaskGroup(of: [UniversalContentItem].self) { group in
            for rule in rules {
                group.addTask {
                    do {
                        return try await self.searchWithRule(rule: rule, query: query, page: page)
                    } catch {
                        print("[ContentService] Search failed for \(rule.id): \(error)")
                        return []
                    }
                }
            }

            for await items in group {
                allItems.append(contentsOf: items)
            }
        }

        return allItems
    }

    // MARK: - 获取列表

    func fetchList(
        from source: String,
        route: ListRoute,
        page: Int = 1
    ) async throws -> [UniversalContentItem] {
        guard let rule = await ruleLoader.rule(for: source) else {
            throw ContentError.ruleNotFound(source)
        }

        guard let listXPath = rule.xpath.list else {
            throw ContentError.noListRoute
        }

        let url = listXPath.url
            .replacingOccurrences(of: "{page}", with: String(page))

        let html = try await fetchHTML(url: url, headers: rule.headers, useWebview: rule.useWebview)

        // 使用 HTMLParser 进行真实解析
        let items = try await htmlParser.parseList(
            html: html,
            rule: rule,
            listXPath: listXPath
        )

        return items
    }

    // MARK: - 使用规则搜索

    private func searchWithRule(rule: DataSourceRule, query: String, page: Int) async throws -> [UniversalContentItem] {
        guard let searchXPath = rule.xpath.search else {
            return []
        }

        let url = searchXPath.url
            .replacingOccurrences(of: "{keyword}", with: query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)
            .replacingOccurrences(of: "{page}", with: String(page))

        let html = try await fetchHTML(url: url, headers: rule.headers, useWebview: rule.useWebview)

        // 使用 HTMLParser 进行真实解析
        let items = try await htmlParser.parseSearch(
            html: html,
            rule: rule,
            searchXPath: searchXPath
        )

        return items
    }

    // MARK: - 获取详情

    func fetchDetail(item: UniversalContentItem) async throws -> UniversalContentItem {
        guard let rule = await ruleLoader.rule(for: item.sourceType) else {
            throw ContentError.ruleNotFound(item.sourceType)
        }

        let html = try await fetchHTML(url: item.sourceURL, headers: rule.headers, useWebview: rule.useWebview)

        guard let detailXPath = rule.xpath.detail else {
            return item
        }

        switch item.contentType {
        case .wallpaper:
            return try await htmlParser.parseWallpaperDetail(
                html: html,
                rule: rule,
                detailXPath: detailXPath,
                baseItem: item
            )
        case .anime:
            return try await htmlParser.parseAnimeDetail(
                html: html,
                rule: rule,
                detailXPath: detailXPath,
                baseItem: item
            )
        case .video:
            return item
        }
    }

    // MARK: - 获取特定集数视频

    func fetchEpisodeVideo(
        animeId: String,
        episodeNumber: Int,
        sourceType: String
    ) async throws -> [VideoSource] {
        // 获取动漫详情
        guard let rule = await ruleLoader.rule(for: sourceType) else {
            throw ContentError.ruleNotFound(sourceType)
        }

        // 从缓存或网络获取详情
        let detailURL = animeId
        _ = try await fetchHTML(url: detailURL, headers: rule.headers, useWebview: rule.useWebview)

        // 解析剧集视频链接
        // 不同的源可能有不同的视频提取逻辑
        // 这里需要根据具体规则实现视频链接提取
        return []
    }

    // MARK: - 私有方法：获取 HTML

    private func fetchHTML(url: String, headers: [String: String]?, useWebview: Bool) async throws -> String {
        guard let url = URL(string: url) else {
            throw ContentError.invalidURL
        }

        if useWebview {
            // 使用 WebView 加载（需要实现 WebViewLoader）
            return ""
        } else {
            var request = URLRequest(url: url)
            request.timeoutInterval = 30

            if let headers = headers {
                for (key, value) in headers {
                    request.setValue(value, forHTTPHeaderField: key)
                }
            }

            let (data, _) = try await URLSession.shared.data(for: request)
            return String(data: data, encoding: .utf8) ?? ""
        }
    }

    // MARK: - 缓存管理

    func clearCache() {
        searchCache.removeAll()
        detailCache.removeAll()
    }
}

// MARK: - 列表路由

enum ListRoute {
    case home
    case latest
    case popular
    case category(String)
    case tag(String)
}

// MARK: - 内容错误

enum ContentError: Error, LocalizedError {
    case noRulesAvailable
    case ruleNotFound(String)
    case noListRoute
    case invalidURL
    case parseError(String)
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .noRulesAvailable:
            return "No data source rules available"
        case .ruleNotFound(let id):
            return "Rule not found: \(id)"
        case .noListRoute:
            return "No list route configured"
        case .invalidURL:
            return "Invalid URL"
        case .parseError(let msg):
            return "Parse error: \(msg)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        }
    }
}
