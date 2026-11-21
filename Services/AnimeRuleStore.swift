import Foundation

/// A full snapshot is the durable commit unit. Network awaits never expose a partial rule set.
actor AnimeRuleStore {
    static let shared = AnimeRuleStore()
    private var rules: [String: AnimeRule] = [:]
    private var loaded = false
    private let rulesDirectory: URL
    private let loader: KazumiRuleLoader
    private let session: URLSession
    private let fileManager = FileManager.default
    private var synchronization: Task<Void, Error>?
    private var launchCheckStarted = false
    private var ruleRevisions: [String: Int] = [:]
    private func beginRuleOperation(_ id: String) -> Int {
        ruleRevisions[id, default: 0] += 1
        return ruleRevisions[id]!
    }
    private enum Mutation { case save(AnimeRule), remove }
    /// Mutations committed while a remote transaction is suspended win over its older view.
    private var pendingMutations: [String: Mutation] = [:]
    private var snapshotURL: URL { rulesDirectory.appendingPathComponent("rules.snapshot") }

    /// Directory and transport injection keep regression tests away from production caches.
    init(directory: URL? = nil, loader: KazumiRuleLoader = .shared, session: URLSession = .shared) {
        rulesDirectory = directory ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("WaifuX", isDirectory: true).appendingPathComponent("AnimeRules", isDirectory: true)
        self.loader = loader
        self.session = session
    }
    func ensureDefaultRulesCopied() async {
        do { try await replaceAllRulesFromKazumiRemote() }
        catch { print("[AnimeRuleStore] Sync failed; retaining complete cache: \(error)") }
    }
    /// Call once from AppDelegate's asynchronous restore phase, even with a nonempty cache.
    /// Concurrent startup/view/market requests join the same transaction.
    func syncOnLaunchInBackground() async {
        if launchCheckStarted {
            if let task = synchronization { _ = try? await task.value }
            return
        }
        launchCheckStarted = true
        await ensureDefaultRulesCopied()
    }
    func clearInMemoryCache() { rules.removeAll(); loaded = false }

    func replaceAllRulesFromKazumiRemote() async throws {
        if let task = synchronization { return try await task.value }
        try loadCacheIfNeeded()
        pendingMutations.removeAll()
        let task = Task { try await self.synchronizeSnapshot() }
        synchronization = task
        defer { synchronization = nil; pendingMutations.removeAll() }
        try await task.value
    }
    private func synchronizeSnapshot() async throws {
        let index = try await loader.fetchRuleIndex()
        var staged: [String: AnimeRule] = [:]
        for entry in index where entry.deprecated != true {
            try Task.checkCancellation()
            let rule = try await loader.loadRule(name: entry.name, forceRefresh: true)
            guard rule.id == entry.id, entry.version == nil || entry.version == rule.version else {
                throw AnimeRuleCompatibilityError(reason: "Index/version mismatch: \(entry.name)")
            }
            try AnimeAPIRuleEngine.validateRule(rule)
            guard staged.updateValue(rule, forKey: rule.id) == nil else { throw AnimeRuleStoreError.invalidIndex }
        }
        guard !staged.isEmpty else { throw AnimeRuleStoreError.invalidIndex }
        // No await between merging concurrent user edits and the durable/in-memory commit.
        for (id, mutation) in pendingMutations {
            switch mutation { case .save(let rule): staged[id] = rule; case .remove: staged.removeValue(forKey: id) }
        }
        try commit(staged)
    }
    private func loadCacheIfNeeded() throws {
        guard !loaded else { return }
        var candidate: [String: AnimeRule] = [:]
        if fileManager.fileExists(atPath: snapshotURL.path) {
            let values = try JSONDecoder().decode([AnimeRule].self, from: Data(contentsOf: snapshotURL))
            for rule in values { candidate[rule.id] = rule }
        } else if fileManager.fileExists(atPath: rulesDirectory.path) {
            // Read-only migration: original individual JSON files remain an untouched fallback.
            for file in try fileManager.contentsOfDirectory(at: rulesDirectory, includingPropertiesForKeys: nil)
                .filter({ $0.pathExtension.lowercased() == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard let rule = try? loadRule(from: file) else { continue }
                if let old = candidate[rule.id], !Self.isNewer(rule.version, than: old.version) { continue }
                candidate[rule.id] = rule
            }
        }
        rules = candidate
        loaded = true
    }
    private func commit(_ candidate: [String: AnimeRule]) throws {
        let ordered = candidate.values.sorted { $0.id < $1.id }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let stagedData = try encoder.encode(ordered)
        let verified = try JSONDecoder().decode([AnimeRule].self, from: stagedData)
        guard verified.count == candidate.count, Set(verified.map(\.id)).count == verified.count else { throw AnimeRuleStoreError.invalidIndex }
        try fileManager.createDirectory(at: rulesDirectory, withIntermediateDirectories: true)
        // Foundation stages a sibling file then renames it atomically on this filesystem.
        // Any encode/validation/write failure leaves both the old snapshot and memory intact.
        try stagedData.write(to: snapshotURL, options: .atomic)
        rules = candidate
        loaded = true
    }
    nonisolated static func isNewer(_ version: String, than installed: String) -> Bool {
        version.compare(installed, options: .numeric) == .orderedDescending
    }
    func fetchAvailableRules() async -> [AnimeRuleInfo] {
        do {
            return try await loader.fetchRuleIndex().filter { $0.deprecated != true }.map {
                AnimeRuleInfo(id: $0.id, name: $0.name, version: $0.version ?? "1.0", description: nil, antiCrawlerEnabled: $0.antiCrawlerEnabled ?? false)
            }
        } catch { print("[AnimeRuleStore] Index fetch failed: \(error)"); return [] }
    }
    func installRuleByName(_ name: String) async -> AnimeRule? {
        let id = AnimeRule.normalizedID(name)
        let revision = beginRuleOperation(id)
        do {
            let rule = try await loader.loadRule(name: name, forceRefresh: true)
            guard ruleRevisions[id] == revision else { return nil }
            try saveRule(rule)
            return rule
        } catch { print("[AnimeRuleStore] Install failed \(name): \(error)"); return nil }
    }
    func uninstallRule(_ ruleId: String) throws { try removeRule(id: ruleId) }
    func isRuleInstalled(_ ruleId: String) -> Bool {
        try? loadCacheIfNeeded()
        return rules[AnimeRule.normalizedID(ruleId)] != nil
    }
    func loadRulesFromRemote() async throws -> [AnimeRule] { try await loader.loadAllRules() }
    func loadAllRules() async -> [AnimeRule] {
        do { try loadCacheIfNeeded() }
        catch { print("[AnimeRuleStore] Cache read failed: \(error)") }
        return allRules()
    }
    func loadRule(from url: URL) throws -> AnimeRule {
        // Legacy caches may contain rules requiring capabilities this client cannot execute yet;
        // decoding keeps them visible so the market can offer a compatible replacement.
        try JSONDecoder().decode(AnimeRule.self, from: Data(contentsOf: url))
    }
    func installRule(from urlString: String) async throws -> AnimeRule {
        guard let url = URL(string: urlString), ["http", "https"].contains(url.scheme ?? "") else { throw AnimeRuleStoreError.invalidURL }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 30)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { throw AnimeRuleStoreError.downloadFailed }
        let rule = try KazumiRuleLoader.decodeRule(data)
        try saveRule(rule)
        return rule
    }
    func installRuleFromGitHub(owner: String, repo: String, path: String, branch: String = "main") async throws -> AnimeRule {
        try await installRule(from: "https://raw.githubusercontent.com/\(owner)/\(repo)/\(branch)/\(path)")
    }
    func installKazumiAnimeRules() async throws -> [AnimeRule] {
        try await replaceAllRulesFromKazumiRemote()
        return allRules()
    }
    func saveRule(_ rule: AnimeRule) throws {
        try AnimeAPIRuleEngine.validateRule(rule)
        try loadCacheIfNeeded()
        var candidate = rules
        candidate[rule.id] = rule
        try commit(candidate)
        _ = beginRuleOperation(rule.id)
        if synchronization != nil { pendingMutations[rule.id] = .save(rule) }
    }
    func rule(for id: String) -> AnimeRule? {
        try? loadCacheIfNeeded()
        return rules[AnimeRule.normalizedID(id)]
    }
    func allRules() -> [AnimeRule] { rules.values.filter { !$0.deprecated }.sorted { $0.name < $1.name } }
    func availableRules() -> [AnimeRule] { allRules() }
    func removeRule(id: String) throws {
        try loadCacheIfNeeded()
        let key = AnimeRule.normalizedID(id)
        var candidate = rules
        candidate.removeValue(forKey: key)
        try commit(candidate)
        _ = beginRuleOperation(key)
        if synchronization != nil { pendingMutations[key] = .remove }
    }
    func checkForUpdates() async throws -> [String] {
        let previous = Dictionary(uniqueKeysWithValues: (await loadAllRules()).map { ($0.id, $0.version) })
        try await replaceAllRulesFromKazumiRemote()
        return allRules().filter { previous[$0.id] != $0.version }.map(\.name)
    }
    func updateRule(id: String) async throws -> AnimeRule? {
        try loadCacheIfNeeded()
        let key = AnimeRule.normalizedID(id)
        guard rules[key] != nil else { return nil }
        let revision = beginRuleOperation(key)
        // Resolve case-sensitive filenames from the canonical Kazumi index, never the old Profiles repo.
        let index = try await loader.fetchRuleIndex()
        guard let entry = index.first(where: { $0.id == key && $0.deprecated != true }) else { throw AnimeRuleStoreError.ruleNotFound(id) }
        let rule = try await loader.loadRule(name: entry.name, forceRefresh: true)
        guard ruleRevisions[key] == revision else { return nil }
        guard entry.version == nil || entry.version == rule.version else { throw AnimeRuleStoreError.invalidIndex }
        try saveRule(rule)
        return rule
    }
    func exportRule(id: String) throws -> Data? {
        try loadCacheIfNeeded()
        guard let rule = rules[AnimeRule.normalizedID(id)] else { return nil }
        return try JSONEncoder().encode(rule)
    }
    func exportAllRules() throws -> Data { try loadCacheIfNeeded(); return try JSONEncoder().encode(allRules()) }
    func importRule(from data: Data) throws -> AnimeRule {
        let rule = try KazumiRuleLoader.decodeRule(data)
        try saveRule(rule)
        return rule
    }
    func rulesDirectoryPath() -> URL { rulesDirectory }
}

struct AnimeRuleInfo: Identifiable {
    let id: String
    /// Case-sensitive upstream filename stem, distinct from normalized identity.
    let name: String
    let version: String
    let description: String?
    let antiCrawlerEnabled: Bool
}

enum AnimeRuleStoreError: Error, LocalizedError {
    case invalidURL, downloadFailed, invalidIndex
    case ruleNotFound(String), saveFailed(String)
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .downloadFailed: return "Failed to download rule"
        case .invalidIndex: return "Invalid rules index"
        case .ruleNotFound(let id): return "Rule not found: \(id)"
        case .saveFailed(let reason): return "Failed to save rule: \(reason)"
        }
    }
}
