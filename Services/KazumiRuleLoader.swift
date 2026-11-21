import Foundation

/// Fetches and converts Kazumi rules without confusing the API capability level with selector syntax.
actor KazumiRuleLoader {
    static let shared = KazumiRuleLoader()
    static let repositoryURL = URL(string: "https://raw.githubusercontent.com/Predidit/KazumiRules/main/")!
    private let session: URLSession
    private let repository: URL
    private var cachedRules: [String: AnimeRule] = [:]
    private var cacheGeneration = 0
    private var ruleGenerations: [String: Int] = [:]

    init(session: URLSession = .shared, repository: URL = KazumiRuleLoader.repositoryURL) {
        self.session = session
        self.repository = repository
    }
    struct KazumiRuleIndex: Codable, Sendable {
        let name: String
        let version: String?
        let useNativePlayer: Bool?
        let antiCrawlerEnabled: Bool?
        let lastUpdate: Int64?
        let deprecated: Bool?
        var id: String { AnimeRule.normalizedID(name) }
    }
    func clearCache() {
        cacheGeneration += 1
        cachedRules.removeAll()
        ruleGenerations.removeAll()
    }
    private func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 30)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw AnimeRuleCompatibilityError(reason: "Rule download failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        return data
    }
    func fetchRuleIndex() async throws -> [KazumiRuleIndex] {
        let index = try JSONDecoder().decode([KazumiRuleIndex].self, from: await download(repository.appendingPathComponent("index.json")))
        let active = index.filter { $0.deprecated != true }
        guard !active.isEmpty, Set(active.map(\.id)).count == active.count,
              active.allSatisfy({ !$0.name.isEmpty && $0.id.range(of: "^[a-z0-9_-]+$", options: .regularExpression) != nil }) else {
            throw AnimeRuleCompatibilityError(reason: "Invalid or empty Kazumi index")
        }
        return index
    }
    func loadRule(name: String, forceRefresh: Bool = false) async throws -> AnimeRule {
        let id = AnimeRule.normalizedID(name)
        if !forceRefresh, let cached = cachedRules[id] { return cached }
        guard id.range(of: "^[a-z0-9_-]+$", options: .regularExpression) != nil else { throw URLError(.badURL) }
        let generation = cacheGeneration
        ruleGenerations[id, default: 0] += 1
        let requestGeneration = ruleGenerations[id]!
        let data = try await download(repository.appendingPathComponent(name + ".json"))
        let rule = try Self.decodeRule(data)
        guard rule.id == id else { throw AnimeRuleCompatibilityError(reason: "Rule name does not match requested entry: \(name)") }
        // An older request must not replace the cache after invalidation or a newer forced fetch.
        if generation == cacheGeneration && requestGeneration == ruleGenerations[id] { cachedRules[id] = rule }
        return rule
    }
    func loadAllRules() async throws -> [AnimeRule] {
        var result: [AnimeRule] = []
        for item in try await fetchRuleIndex() where item.deprecated != true {
            let rule = try await loadRule(name: item.name, forceRefresh: true)
            guard item.version == nil || item.version == rule.version else { throw AnimeRuleCompatibilityError(reason: "Index/version mismatch: \(item.name)") }
            result.append(rule)
        }
        return result
    }
    /// Supports both already-converted local caches and upstream Kazumi JSON.
    nonisolated static func decodeRule(_ data: Data) throws -> AnimeRule {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let rule: AnimeRule
        if object?["id"] != nil {
            rule = try JSONDecoder().decode(AnimeRule.self, from: data)
        } else {
            rule = try convert(JSONDecoder().decode(KazumiRule.self, from: data))
        }
        try AnimeAPIRuleEngine.validateRule(rule)
        return rule
    }
    struct KazumiRule: Decodable {
        let name: String
        let type: String?
        let version: String?
        let api: String?
        let baseURL: String?
        let searchURL: String?
        let searchList: String?
        let searchName: String?
        let searchResult: String?
        let chapterRoads: String?
        let chapterResult: String?
        let chapterName: String?
        let useWebview: Bool?
        let multiSource: Bool?
        let muliSources: Bool?
        let userAgent: String?
        let referer: String?
        let headers: [String: String]?
        let antiCrawler: Bool?
        let antiCrawlerConfig: AntiCrawlerConfig?
        let searchMode: AnimeRuleMode?
        let chapterMode: AnimeRuleMode?
        let searchApiConfig: AnimeAPISearch?
        let chapterApiConfig: AnimeAPIChapter?
    }
    private nonisolated static func convert(_ input: KazumiRule) throws -> AnimeRule {
        let xpath = AnimeXPathRules(
            search: AnimeSearchXPath(url: input.searchURL ?? "", list: input.searchList ?? "", title: input.searchName ?? "", cover: nil, detail: input.searchResult ?? "", id: nil),
            detail: AnimeDetailXPath(title: nil, cover: nil, description: nil, episodes: input.chapterRoads, episodeName: input.chapterName, episodeLink: nil, episodeThumb: nil, fullImage: nil, resolution: nil, fileSize: nil),
            list: AnimeListXPath(url: "", list: input.chapterResult ?? "", title: "", cover: "", detail: "", nextPage: nil))
        return AnimeRule(id: input.name, api: input.api ?? "1", type: input.type ?? "anime", name: input.name,
                         version: input.version ?? "1.0", baseURL: input.baseURL ?? "", headers: input.headers,
                         userAgent: input.userAgent, referer: input.referer, searchURL: input.searchURL ?? "",
                         useWebview: input.useWebview, multiSources: input.multiSource ?? input.muliSources ?? false,
                         xpath: xpath, antiCrawlerConfig: input.antiCrawlerConfig ?? AntiCrawlerConfig(enabled: input.antiCrawler ?? false),
                         searchMode: input.searchMode ?? .xpath, chapterMode: input.chapterMode ?? .xpath,
                         searchApiConfig: input.searchApiConfig, chapterApiConfig: input.chapterApiConfig)
    }
}
