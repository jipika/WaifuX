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

        // 首次启动：从 Bundle 复制默认规则
        Task {
            await copyDefaultRulesFromBundle()
        }
    }

    // MARK: - 初始化

    /// 从 Bundle 复制默认动漫规则
    private func copyDefaultRulesFromBundle() async {
        let copiedKey = "anime_rules_copied_v1"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: copiedKey) else { return }

        // 尝试从 Bundle 加载动漫规则目录
        guard let bundleRulesURL = Bundle.main.url(forResource: "AnimeRules", withExtension: nil) else {
            print("[AnimeRuleStore] AnimeRules directory not found in bundle")
            // 即使没有 Bundle 规则，也标记为已处理
            defaults.set(true, forKey: copiedKey)
            return
        }

        do {
            let files = try fileManager.contentsOfDirectory(at: bundleRulesURL, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }

            for file in files {
                let destination = rulesDirectory.appendingPathComponent(file.lastPathComponent)
                if !fileManager.fileExists(atPath: destination.path) {
                    try fileManager.copyItem(at: file, to: destination)
                    print("[AnimeRuleStore] Copied default anime rule: \(file.lastPathComponent)")
                }
            }

            defaults.set(true, forKey: copiedKey)
            print("[AnimeRuleStore] Default anime rules copied successfully")

            await loadAllRules()
        } catch {
            print("[AnimeRuleStore] Failed to copy default rules: \(error)")
        }
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

        for item in index.items where item.type == "anime" {
            do {
                let rule = try await installRule(from: item.url)
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

        for item in index.items where item.type == "anime" {
            if let localRule = rules[item.name],
               let remoteVersion = item.version,
               remoteVersion != localRule.version {
                do {
                    _ = try await installRule(from: item.url)
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
        guard let rule = rules[id] else {
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

private struct KazumiAnimeIndex: Codable {
    let api: String?
    let version: String?
    let lastUpdated: String?
    let items: [KazumiRuleItem]
}

private struct KazumiRuleItem: Codable {
    let name: String
    let type: String
    let version: String?
    let url: String
    let description: String?
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
