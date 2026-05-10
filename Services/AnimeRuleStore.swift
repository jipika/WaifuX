import Foundation

// MARK: - 动漫规则商店

/// 动漫规则管理服务
/// 管理动漫规则的加载、安装、更新、删除
actor AnimeRuleStore {
    static let shared = AnimeRuleStore()

    private var rules: [String: AnimeRule] = [:]
    private let rulesDirectory: URL
    private let fileManager = FileManager.default
    
    // 注意：动漫规则固定从 Kazumi 官方仓库加载
    // 与壁纸/媒体规则完全分离，不走用户配置的 Profiles 仓库

    init() {
        guard let supportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            // 使用临时目录作为回退
            self.rulesDirectory = fileManager.temporaryDirectory
                .appendingPathComponent("WaifuX", isDirectory: true)
                .appendingPathComponent("AnimeRules", isDirectory: true)
            return
        }
        self.rulesDirectory = supportDir
            .appendingPathComponent("WaifuX", isDirectory: true)
            .appendingPathComponent("AnimeRules", isDirectory: true)

        // 创建目录
        try? fileManager.createDirectory(at: rulesDirectory, withIntermediateDirectories: true)
    }

    /// 本地仅作缓存：与远程索引对齐，清空磁盘上的动漫规则后按 Kazumi 全量重新下载（非弃用项）
    func ensureDefaultRulesCopied() async {
        do {
            try await replaceAllRulesFromKazumiRemote()
            print("[AnimeRuleStore] Kazumi 全量覆盖完成，共 \(allRules().count) 个")
        } catch {
            print("[AnimeRuleStore] Kazumi 全量同步失败（保留上次本地缓存）: \(error)")
        }
    }

    /// 应用启动时在后台执行一次：始终以远程为准覆盖本地缓存（不合并、不以本地版本为准）
    func syncOnLaunchInBackground() async {
        print("[AnimeRuleStore] [启动同步] 开始从 Kazumi 远程仓库同步规则…")
        print("[AnimeRuleStore] [启动同步] 规则存储目录: \(rulesDirectory.path)")

        // 确保目录存在
        do {
            try fileManager.createDirectory(at: rulesDirectory, withIntermediateDirectories: true)
            print("[AnimeRuleStore] [启动同步] 规则目录已确保存在")
        } catch {
            print("[AnimeRuleStore] [启动同步] 创建规则目录失败: \(error.localizedDescription)")
        }

        do {
            try await replaceAllRulesFromKazumiRemote()
            let rules = await loadAllRules()
            print("[AnimeRuleStore] [启动同步] Kazumi 全量覆盖完成，共 \(rules.count) 个规则")
        } catch {
            print("[AnimeRuleStore] [启动同步] 全量同步失败: \(error.localizedDescription)")
            // 同步失败时，尝试加载本地缓存
            let cachedRules = await loadAllRules()
            print("[AnimeRuleStore] [启动同步] 使用本地缓存: \(cachedRules.count) 个规则")
        }
    }

    /// 删除 `AnimeRules` 目录下所有 `.json` 并清空内存字典（成功拉取索引后再调用）
    private func clearAllLocalRuleFiles() throws {
        rules.removeAll()
        guard let files = try? fileManager.contentsOfDirectory(at: rulesDirectory, includingPropertiesForKeys: nil) else {
            return
        }
        for file in files where file.pathExtension == "json" {
            try? fileManager.removeItem(at: file)
        }
    }

    /// 后台释放前台资源时只清内存，不删除本地规则文件。
    func clearInMemoryCache() {
        rules.removeAll(keepingCapacity: false)
    }

    /// 从 Kazumi 官方索引全量同步：远程成功后再清空本地并逐条下载覆盖（与索引一致，弃用项不安装）
    func replaceAllRulesFromKazumiRemote() async throws {
        print("[AnimeRuleStore] 开始获取 Kazumi 远程索引…")
        let indexData = try await fetchIndexData()
        print("[AnimeRuleStore] 索引数据获取成功，大小: \(indexData.count) bytes")

        guard let index = try? JSONDecoder().decode(KazumiAnimeIndex.self, from: indexData) else {
            print("[AnimeRuleStore] 索引数据解码失败")
            throw AnimeRuleStoreError.invalidIndex
        }
        print("[AnimeRuleStore] 索引解码成功，共 \(index.count) 个规则")

        await KazumiRuleLoader.shared.clearCache()
        try clearAllLocalRuleFiles()

        var installedCount = 0
        var skippedCount = 0
        for item in index {
            if item.deprecated == true {
                skippedCount += 1
                continue
            }
            let rule = await installRuleByName(item.name)
            if rule != nil {
                installedCount += 1
            }
        }
        print("[AnimeRuleStore] 全量同步完成: 安装 \(installedCount) 个, 跳过弃用 \(skippedCount) 个")
    }

    // MARK: - 初始化

    /// 获取远程可用规则列表（不自动安装）
    /// 与 Kazumi 对齐：显示全部可用规则，让用户手动选择安装
    func fetchAvailableRules() async -> [AnimeRuleInfo] {
        do {
            let indexData = try await fetchIndexData()
            guard let index = try? JSONDecoder().decode(KazumiAnimeIndex.self, from: indexData) else {
                return []
            }
            return index
                .filter { $0.deprecated != true }
                .map { $0.asRuleInfo }
        } catch {
            print("[AnimeRuleStore] 获取可用规则列表失败: \(error)")
            return []
        }
    }

    /// 安装指定规则
    func installRuleByName(_ name: String) async -> AnimeRule? {
        do {
            let rule = try await KazumiRuleLoader.shared.loadRule(name: name)
            try saveRule(rule)
            print("[AnimeRuleStore] 安装规则成功: \(name)")
            return rule
        } catch {
            print("[AnimeRuleStore] 安装规则失败 \(name): \(error)")
            return nil
        }
    }

    /// 卸载指定规则
    func uninstallRule(_ ruleId: String) throws {
        rules.removeValue(forKey: ruleId)
        let filePath = rulesDirectory.appendingPathComponent("\(ruleId).json")
        if fileManager.fileExists(atPath: filePath.path) {
            try fileManager.removeItem(at: filePath)
            print("[AnimeRuleStore] 卸载规则: \(ruleId)")
        }
    }

    /// 检查规则是否已安装
    func isRuleInstalled(_ ruleId: String) -> Bool {
        return rules[ruleId] != nil || fileManager.fileExists(atPath: rulesDirectory.appendingPathComponent("\(ruleId).json").path)
    }

    // MARK: - 加载规则
    
    /// 从 Kazumi 官方仓库加载所有规则
    /// 注意：动漫规则固定从 Predidit/KazumiRules 加载，与壁纸/媒体规则完全分离
    func loadRulesFromRemote() async throws -> [AnimeRule] {
        return try await KazumiRuleLoader.shared.loadAllRules()
    }
    
    /// 加载所有本地规则
    func loadAllRules() async -> [AnimeRule] {
        guard let files = try? fileManager.contentsOfDirectory(at: rulesDirectory, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "json" }) else {
            return []
        }

        var loadedRules: [AnimeRule] = []

        for file in files {
            if let rule = try? loadRule(from: file) {
                rules[rule.id] = rule
                loadedRules.append(rule)
            }
        }

        return loadedRules
            .filter { !$0.deprecated }
            .sorted { $0.name < $1.name }
    }

    /// 从文件加载规则
    func loadRule(from url: URL) throws -> AnimeRule {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(AnimeRule.self, from: data)
    }

    // MARK: - 安装规则

    /// 从 URL 安装规则
    func installRule(from urlString: String) async throws -> AnimeRule {
        guard let remoteURL = URL(string: urlString) else {
            throw AnimeRuleStoreError.invalidURL
        }

        let (data, response) = try await URLSession.shared.data(from: remoteURL)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw AnimeRuleStoreError.downloadFailed
        }

        let rule = try JSONDecoder().decode(AnimeRule.self, from: data)
        try saveRule(rule)

        return rule
    }

    /// 从 GitHub 仓库安装规则
    func installRuleFromGitHub(
        owner: String,
        repo: String,
        path: String,
        branch: String = "main"
    ) async throws -> AnimeRule {
        let rawURL = "https://raw.githubusercontent.com/\(owner)/\(repo)/\(branch)/\(path)"
        return try await installRule(from: rawURL)
    }

    /// 批量安装 Kazumi 动漫规则（与全量覆盖一致）
    func installKazumiAnimeRules() async throws -> [AnimeRule] {
        try await replaceAllRulesFromKazumiRemote()
        return await loadAllRules()
    }

    /// 从 Kazumi 官方仓库获取索引
    private func fetchIndexData() async throws -> Data {
        let kazumiIndexURL = "https://raw.githubusercontent.com/Predidit/KazumiRules/main/index.json"
        print("[AnimeRuleStore] 获取索引: \(kazumiIndexURL)")

        guard let url = URL(string: kazumiIndexURL) else {
            print("[AnimeRuleStore] 索引 URL 无效")
            throw AnimeRuleStoreError.invalidURL
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse else {
                print("[AnimeRuleStore] 响应类型无效")
                throw AnimeRuleStoreError.downloadFailed
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                print("[AnimeRuleStore] HTTP 错误: \(httpResponse.statusCode)")
                throw AnimeRuleStoreError.downloadFailed
            }

            print("[AnimeRuleStore] 索引获取成功: HTTP \(httpResponse.statusCode)")
            return data
        } catch {
            print("[AnimeRuleStore] 网络请求失败: \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - 保存规则

    /// 保存规则到本地
    func saveRule(_ rule: AnimeRule) throws {
        let data = try JSONEncoder().encode(rule)
        let filePath = rulesDirectory.appendingPathComponent("\(rule.id).json")
        try data.write(to: filePath)
        rules[rule.id] = rule
        print("[AnimeRuleStore] Saved rule: \(rule.id)")
    }

    // MARK: - 获取规则

    /// 获取指定规则
    func rule(for id: String) -> AnimeRule? {
        return rules[id]
    }

    /// 获取所有规则（弃用项不返回，避免占列表空间）
    func allRules() -> [AnimeRule] {
        return rules.values
            .filter { !$0.deprecated }
            .sorted { $0.name < $1.name }
    }

    /// 获取可用规则（未弃用）
    func availableRules() -> [AnimeRule] {
        return allRules()
    }

    // MARK: - 删除规则

    /// 删除规则
    func removeRule(id: String) throws {
        rules.removeValue(forKey: id)
        let filePath = rulesDirectory.appendingPathComponent("\(id).json")
        if fileManager.fileExists(atPath: filePath.path) {
            try fileManager.removeItem(at: filePath)
            print("[AnimeRuleStore] Removed rule: \(id)")
        }
    }

    // MARK: - 更新规则

    /// 与「全量覆盖」一致：始终以远程索引为准覆盖本地
    func checkForUpdates() async throws -> [String] {
        try await replaceAllRulesFromKazumiRemote()
        return allRules().map(\.name)
    }

    /// 更新单个规则
    func updateRule(id: String) async throws -> AnimeRule? {
        guard rules[id] != nil else {
            return nil
        }

        // 重新下载并覆盖
        return try await installRule(from: "https://raw.githubusercontent.com/jipika/WallHaven-Profiles/main/anime/\(id).json")
    }

    // MARK: - 导出规则

    /// 导出规则为 Data
    func exportRule(id: String) throws -> Data? {
        guard let rule = rules[id] else { return nil }
        return try JSONEncoder().encode(rule)
    }

    /// 导出所有规则
    func exportAllRules() throws -> Data {
        return try JSONEncoder().encode(allRules())
    }

    // MARK: - 导入规则

    /// 从 Data 导入规则
    func importRule(from data: Data) throws -> AnimeRule {
        let rule = try JSONDecoder().decode(AnimeRule.self, from: data)
        try saveRule(rule)
        return rule
    }

    // MARK: - 规则目录

    /// 获取规则目录路径
    func rulesDirectoryPath() -> URL {
        return rulesDirectory
    }
}

// MARK: - 规则索引 (Kazumi 格式)

/// KazumiRules index.json 格式（直接是数组）
private typealias KazumiAnimeIndex = [KazumiRuleItem]

private struct KazumiRuleItem: Codable {
    let name: String
    let version: String?
    let useNativePlayer: Bool?
    let antiCrawlerEnabled: Bool?
    let author: String?
    let lastUpdate: Int64?
    /// Kazumi / 自建索引可选字段：为 true 时不展示、不自动安装
    let deprecated: Bool?
}

// MARK: - 公开规则信息类型

struct AnimeRuleInfo: Identifiable {
    let id: String
    let name: String
    let version: String
    let description: String?
    let antiCrawlerEnabled: Bool
}

// 扩展 KazumiRuleItem 转换为 AnimeRuleInfo
extension KazumiRuleItem {
    var asRuleInfo: AnimeRuleInfo {
        AnimeRuleInfo(
            id: name,
            name: name,
            version: version ?? "1.0",
            description: nil,
            antiCrawlerEnabled: antiCrawlerEnabled ?? false
        )
    }

    /// 构造规则文件的 URL
    var ruleURL: String {
        "https://raw.githubusercontent.com/Predidit/KazumiRules/main/\(name).json"
    }
}

// MARK: - 错误类型

enum AnimeRuleStoreError: Error, LocalizedError {
    case invalidURL
    case downloadFailed
    case invalidIndex
    case ruleNotFound(String)
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .downloadFailed:
            return "Failed to download rule"
        case .invalidIndex:
            return "Invalid rules index"
        case .ruleNotFound(let id):
            return "Rule not found: \(id)"
        case .saveFailed(let reason):
            return "Failed to save rule: \(reason)"
        }
    }
}
