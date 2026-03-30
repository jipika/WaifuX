import Foundation

/// Kazumi 规则加载器
/// 从 Kazumi 的规则仓库加载动漫源规则
actor KazumiRuleLoader {
    static let shared = KazumiRuleLoader()
    
    // Kazumi 规则仓库地址
    private let ruleRepositoryURL = "https://raw.githubusercontent.com/Predidit/KazumiRules/main/"
    private let indexURL = "https://raw.githubusercontent.com/Predidit/KazumiRules/main/index.json"
    
    // 缓存
    private var cachedRules: [String: AnimeRule] = [:]
    private var cachedIndex: [KazumiRuleIndex] = []
    
    /// Kazumi 规则索引
    struct KazumiRuleIndex: Codable {
        let name: String
        let version: String
        let useNativePlayer: Bool
        let useAntiCrawler: Bool
        let lastUpdate: Int64 // Unix 时间戳 (毫秒)
    }
    
    /// 获取规则索引列表
    func fetchRuleIndex() async throws -> [KazumiRuleIndex] {
        guard let url = URL(string: indexURL) else {
            throw URLError(.badURL)
        }
        
        let (data, _) = try await URLSession.shared.data(from: url)
        let index = try JSONDecoder().decode([KazumiRuleIndex].self, from: data)
        cachedIndex = index
        return index
    }
    
    /// 加载指定规则
    func loadRule(name: String) async throws -> AnimeRule {
        // 检查缓存
        if let cached = cachedRules[name] {
            return cached
        }
        
        // 从远程加载
        let ruleURL = "\(ruleRepositoryURL)\(name.uppercased()).json"
        guard let url = URL(string: ruleURL) else {
            throw URLError(.badURL)
        }
        
        print("[KazumiRuleLoader] 加载规则: \(name) from \(ruleURL)")
        let (data, _) = try await URLSession.shared.data(from: url)
        
        // 解析 Kazumi 规则格式
        let kazumiRule = try JSONDecoder().decode(KazumiRule.self, from: data)
        
        // 转换为我们的 AnimeRule 格式
        let animeRule = convertKazumiRuleToAnimeRule(kazumiRule)
        
        // 缓存
        cachedRules[name] = animeRule
        
        return animeRule
    }
    
    /// 加载所有可用规则
    func loadAllRules() async throws -> [AnimeRule] {
        let index = try await fetchRuleIndex()
        var rules: [AnimeRule] = []
        
        for ruleIndex in index {
            do {
                let rule = try await loadRule(name: ruleIndex.name)
                rules.append(rule)
                print("[KazumiRuleLoader] ✓ 成功加载: \(ruleIndex.name) v\(ruleIndex.version)")
            } catch {
                print("[KazumiRuleLoader] ✗ 加载失败: \(ruleIndex.name) - \(error)")
            }
        }
        
        return rules
    }
    
    /// Kazumi 规则格式
    struct KazumiRule: Codable {
        let name: String
        let type: String?
        let version: Double?
        let api: Int?
        let baseURL: String?
        let searchURL: String?
        let searchList: String?
        let searchName: String?
        let searchResult: String?
        let chapterRoads: String?
        let chapterResult: String?
        let chapterName: String?
        let useWebview: Bool?
        let useNativePlayer: Bool?
        let multiSource: Bool?
        let userAgent: String?
        let headers: [String: String]?
        let antiCrawler: Bool?
        
        enum CodingKeys: String, CodingKey {
            case name, type, version, api, baseURL, searchURL
            case searchList, searchName, searchResult
            case chapterRoads, chapterResult, chapterName
            case useWebview, useNativePlayer, multiSource
            case userAgent, headers, antiCrawler
        }
    }
    
    /// 将 Kazumi 规则转换为我们的 AnimeRule 格式
    private func convertKazumiRuleToAnimeRule(_ kazumiRule: KazumiRule) -> AnimeRule {
        // 构建搜索 XPath 配置
        let xpathSearch = AnimeSearchXPath(
            url: kazumiRule.searchURL?.replacingOccurrences(of: "@keyword", with: "{keyword}") ?? "",
            list: kazumiRule.searchList ?? "",
            title: kazumiRule.searchName ?? "",
            cover: "",  // Kazumi 规则中没有单独的封面选择器
            detail: kazumiRule.searchResult ?? "",
            id: nil
        )
        
        // 构建详情 XPath 配置
        let xpathDetail = AnimeDetailXPath(
            title: nil,
            cover: nil,
            description: nil,
            episodes: kazumiRule.chapterRoads,
            episodeName: kazumiRule.chapterName,
            episodeLink: nil,
            episodeThumb: nil,
            fullImage: nil,
            resolution: nil,
            fileSize: nil
        )
        
        // 构建列表 XPath 配置
        let xpathList = AnimeListXPath(
            url: "",
            list: kazumiRule.chapterResult ?? "",
            title: "",
            cover: "",
            detail: "",
            nextPage: nil
        )
        
        let xpath = AnimeXPathRules(
            search: xpathSearch,
            detail: xpathDetail,
            list: xpathList
        )
        
        // 构建 AnimeRule
        return AnimeRule(
            id: kazumiRule.name.lowercased(),
            api: "\(kazumiRule.api ?? 2)",  // Kazumi 使用 api 版本,转为字符串
            type: kazumiRule.type ?? "anime",
            name: kazumiRule.name,
            version: kazumiRule.version != nil ? "\(kazumiRule.version!)" : "1.0.0",
            deprecated: false,
            baseURL: kazumiRule.baseURL ?? "",
            headers: kazumiRule.headers,
            timeout: 30,
            searchURL: kazumiRule.searchURL?.replacingOccurrences(of: "@keyword", with: "{keyword}") ?? "",
            searchList: nil,  // 使用 XPath 格式
            searchName: nil,
            searchCover: nil,
            searchDetail: nil,
            searchId: nil,
            detailTitle: nil,
            detailCover: nil,
            detailDesc: nil,
            episodeList: nil,
            episodeName: nil,
            episodeLink: nil,
            episodeThumb: nil,
            useWebview: kazumiRule.useWebview ?? false,
            multiSources: kazumiRule.multiSource ?? false,
            xpath: xpath
        )
    }
}
