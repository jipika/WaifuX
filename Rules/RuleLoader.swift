import Foundation

actor RuleLoader {
    static let shared = RuleLoader()

    private let rulesDirectory: URL
    private var cachedRules: [DataSourceRule] = []

    init() {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        rulesDirectory = appSupport.appendingPathComponent("WallHaven/Rules", isDirectory: true)

        try? fileManager.createDirectory(at: rulesDirectory, withIntermediateDirectories: true)
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
        guard let files = try? FileManager.default.contentsOfDirectory(at: rulesDirectory, includingPropertiesForKeys: nil) else {
            return []
        }

        let decoder = JSONDecoder()
        return files.compactMap { url in
            guard url.pathExtension == "json" else { return nil }
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(DataSourceRule.self, from: data)
        }
    }
}

enum RuleError: Error {
    case invalidURL
    case invalidRule
    case networkError
}
