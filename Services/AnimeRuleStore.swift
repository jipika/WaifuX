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
        let supportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.rulesDirectory = supportDir
            .appendingPathComponent("WallHaven", isDirectory: true)
            .appendingPathComponent("AnimeRules", isDirectory: true)

        // 创建目录
        try? fileManager.createDirectory(at: rulesDirectory, withIntermediateDirectories: true)
    }

    /// 确保默认规则已复制完成
    /// 用户要求直接加载所有可用规则，因此自动安装全部 Kazumi 规则
    func ensureDefaultRulesCopied() async {
        do {
            let index = try await KazumiRuleLoader.shared.fetchRuleIndex()
            for item in index {
                if !isRuleInstalled(item.name.lowercased()) {
                    _ = await installRuleByName(item.name)
                }
            }
            print("[AnimeRuleStore] 自动安装规则完成，共 \(allRules().count) 个")
        } catch {
            print("[AnimeRuleStore] 自动安装规则失败: \(error)")
        }
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
            return index.map { $0.asRuleInfo }
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

        return loadedRules.sorted { $0.name < $1.name }
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

    /// 批量安装 Kazumi 动漫规则
    func installKazumiAnimeRules() async throws -> [AnimeRule] {
        // 首先获取索引文件
        let indexData = try await fetchIndexData()

        guard let index = try? JSONDecoder().decode(KazumiAnimeIndex.self, from: indexData) else {
            throw AnimeRuleStoreError.invalidIndex
        }

        var installedRules: [AnimeRule] = []

        for item in index {
            do {
                let rule = try await installRule(from: item.ruleURL)
                installedRules.append(rule)
            } catch {
                print("[AnimeRuleStore] Failed to install \(item.name): \(error)")
            }
        }

        return installedRules
    }

    /// 从 Kazumi 官方仓库获取索引
    private func fetchIndexData() async throws -> Data {
        let kazumiIndexURL = "https://raw.githubusercontent.com/Predidit/KazumiRules/main/index.json"
        guard let url = URL(string: kazumiIndexURL) else {
            throw AnimeRuleStoreError.invalidURL
        }

        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw AnimeRuleStoreError.downloadFailed
        }

        return data
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

    /// 获取所有规则
    func allRules() -> [AnimeRule] {
        return Array(rules.values).sorted { $0.name < $1.name }
    }

    /// 获取可用规则（未弃用）
    func availableRules() -> [AnimeRule] {
        return rules.values
            .filter { !$0.deprecated }
            .sorted { $0.name < $1.name }
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

    /// 检查并更新规则
    func checkForUpdates() async throws -> [String] {
        let indexData = try await fetchIndexData()

        guard let index = try? JSONDecoder().decode(KazumiAnimeIndex.self, from: indexData) else {
            throw AnimeRuleStoreError.invalidIndex
        }

        var updatedRules: [String] = []

        for item in index {
            if let localRule = rules[item.name.lowercased()],
               let remoteVersion = item.version,
               remoteVersion != localRule.version {
                do {
                    _ = try await installRule(from: item.ruleURL)
                    updatedRules.append(item.name)
                } catch {
                    print("[AnimeRuleStore] Failed to update \(item.name): \(error)")
                }
            }
        }

        return updatedRules
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
