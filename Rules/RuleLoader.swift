import Foundation

actor RuleLoader {
    static let shared = RuleLoader()

    private let rulesDirectory: URL
    private var cachedRules: [DataSourceRule] = []

    init() {
        let fileManager = FileManager.default
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            // 使用临时目录作为回退
            rulesDirectory = fileManager.temporaryDirectory.appendingPathComponent("WaifuX/Rules", isDirectory: true)
            print("[RuleLoader] 使用临时目录: \(rulesDirectory.path)")
            return
        }
        rulesDirectory = appSupport.appendingPathComponent("WaifuX/Rules", isDirectory: true)
        print("[RuleLoader] 规则目录: \(rulesDirectory.path)")

        do {
            try fileManager.createDirectory(at: rulesDirectory, withIntermediateDirectories: true)
            print("[RuleLoader] 规则目录已创建/已存在")
        } catch {
            print("[RuleLoader] 创建规则目录失败: \(error.localizedDescription)")
        }
    }

    func allRules() -> [DataSourceRule] {
        if cachedRules.isEmpty {
            cachedRules = loadRulesFromDisk()
        }
        return cachedRules
    }

    func rules(for contentType: ContentType) -> [DataSourceRule] {
        allRules().filter { $0.contentType == contentType }
    }

    func rule(id: String) -> DataSourceRule? {
        allRules().first { $0.id == id }
    }

    func installRule(from urlString: String) async throws -> DataSourceRule {
        guard let url = URL(string: urlString) else {
            throw RuleError.invalidURL
        }

        let (data, _) = try await URLSession.shared.data(from: url)
        return try await installRule(data: data)
    }

    func installRuleFromGitHub(owner: String, repo: String, path: String, branch: String = "main") async throws -> DataSourceRule {
        let urlString = "https://raw.githubusercontent.com/\(owner)/\(repo)/\(branch)/\(path)"
        return try await installRule(from: urlString)
    }

    func installRule(data: Data) async throws -> DataSourceRule {
        let decoder = JSONDecoder()
        let rule = try decoder.decode(DataSourceRule.self, from: data)

        let fileURL = rulesDirectory.appendingPathComponent("\(rule.id).json")
        try data.write(to: fileURL)

        cachedRules.append(rule)
        return rule
    }

    func removeRule(id: String) async throws {
        let fileURL = rulesDirectory.appendingPathComponent("\(id).json")
        try FileManager.default.removeItem(at: fileURL)
        cachedRules.removeAll { $0.id == id }
    }

    private func loadRulesFromDisk() -> [DataSourceRule] {
        print("[RuleLoader] 从磁盘加载规则…")

        guard let files = try? FileManager.default.contentsOfDirectory(at: rulesDirectory, includingPropertiesForKeys: nil) else {
            print("[RuleLoader] 无法读取规则目录内容")
            return []
        }

        let jsonFiles = files.filter { $0.pathExtension == "json" }
        print("[RuleLoader] 找到 \(jsonFiles.count) 个 JSON 文件")

        let decoder = JSONDecoder()
        var loadedRules: [DataSourceRule] = []

        for url in jsonFiles {
            guard let data = try? Data(contentsOf: url) else {
                print("[RuleLoader] 无法读取文件: \(url.lastPathComponent)")
                continue
            }
            do {
                let rule = try decoder.decode(DataSourceRule.self, from: data)
                loadedRules.append(rule)
                print("[RuleLoader] ✓ 加载规则: \(rule.id)")
            } catch {
                print("[RuleLoader] ✗ 解码失败: \(url.lastPathComponent) - \(error.localizedDescription)")
            }
        }

        print("[RuleLoader] 共加载 \(loadedRules.count) 个规则")
        return loadedRules
    }
}

enum RuleError: Error {
    case invalidURL
    case invalidRule
    case networkError
}
