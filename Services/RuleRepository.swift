import Foundation

// MARK: - 规则仓库服务

/// 统一的规则仓库管理服务
/// 用户只需填入 GitHub 仓库地址，应用自动从仓库加载所有规则
actor RuleRepository {
    static let shared = RuleRepository()

    private let ruleLoader = RuleLoader.shared

    // 当前配置的仓库
    private var currentRepoURL: String?
    private var currentOwner: String?
    private var currentRepo: String?

    // 仓库索引缓存
    private var cachedIndex: RepositoryIndex?

    // MARK: - 配置仓库

    /// 从 GitHub URL 配置仓库
    /// 支持格式:
    /// - https://github.com/owner/repo
    /// - https://github.com/owner/repo/
    /// - github.com/owner/repo
    /// - owner/repo
    func configure(repoURL: String) async throws {
        let (owner, repo) = try parseGitHubURL(repoURL)
        self.currentOwner = owner
        self.currentRepo = repo
        self.currentRepoURL = "https://github.com/\(owner)/\(repo)"
        self.cachedIndex = nil

        // 保存到 UserDefaults
        UserDefaults.standard.set("https://github.com/\(owner)/\(repo)", forKey: "rule_repository_url")

        print("[RuleRepository] Configured repository: \(owner)/\(repo)")
    }

    /// 从保存的配置加载仓库
    func loadConfiguredRepository() async {
        guard let savedURL = UserDefaults.standard.string(forKey: "rule_repository_url") else {
            print("[RuleRepository] 未配置规则仓库 URL，请在设置中配置")
            return
        }

        print("[RuleRepository] 加载已配置的仓库: \(savedURL)")

        do {
            try await configure(repoURL: savedURL)
            try await syncAllRules()
        } catch {
            print("[RuleRepository] 加载仓库失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 解析 GitHub URL

    private func parseGitHubURL(_ urlString: String) throws -> (owner: String, repo: String) {
        var input = urlString.trimmingCharacters(in: .whitespacesAndNewlines)

        // 移除协议前缀
        if input.hasPrefix("https://") {
            input = String(input.dropFirst(8))
        } else if input.hasPrefix("http://") {
            input = String(input.dropFirst(7))
        }

        // 移除 github.com/
        if input.hasPrefix("github.com/") {
            input = String(input.dropFirst(11))
        }

        // 移除末尾斜杠
        if input.hasSuffix("/") {
            input = String(input.dropLast())
        }

        // 分割 owner/repo
        let parts = input.split(separator: "/")
        guard parts.count >= 2 else {
            throw RuleRepositoryError.invalidURL("Invalid GitHub URL: \(urlString)")
        }

        let owner = String(parts[0])
        let repo = String(parts[1])

        // 移除 .git 后缀
        let cleanRepo = repo.replacingOccurrences(of: ".git", with: "")

        guard !owner.isEmpty, !cleanRepo.isEmpty else {
            throw RuleRepositoryError.invalidURL("Invalid GitHub URL: \(urlString)")
        }

        return (owner, cleanRepo)
    }

    // MARK: - 获取仓库索引

    /// 获取仓库索引
    func fetchIndex() async throws -> RepositoryIndex {
        guard let owner = currentOwner, let repo = currentRepo else {
            throw RuleRepositoryError.notConfigured
        }

        // 如果有缓存且未过期，返回缓存
        if let cached = cachedIndex {
            return cached
        }

        // 尝试获取主 index.json
        let indexURL = "https://raw.githubusercontent.com/\(owner)/\(repo)/main/index.json"
        let data = try await fetchData(from: indexURL)

        let index = try JSONDecoder().decode(RepositoryIndex.self, from: data)
        self.cachedIndex = index

        return index
    }

    // MARK: - 同步规则

    /// 同步所有规则（壁纸 + 媒体，不包括动漫）
    /// 动漫规则完全由 AnimeRuleStore/KazumiRuleLoader 独立管理
    func syncAllRules() async throws {
        print("[RuleRepository] Syncing all rules...")

        // 同步媒体配置（壁纸+媒体源）
        try await syncMediaRules()

        // 同步壁纸规则
        try await syncWallpaperRules()

        // 注意：动漫规则不由 RuleRepository 管理
        // 动漫规则由 AnimeRuleStore 独立从 Kazumi 仓库加载

        print("[RuleRepository] Sync completed")
    }

    /// 同步媒体配置（壁纸+媒体源）
    func syncMediaRules() async throws {
        guard let owner = currentOwner, let repo = currentRepo else {
            throw RuleRepositoryError.notConfigured
        }

        print("[RuleRepository] Syncing media rules...")

        do {
            let index = try await fetchIndex()

            if let media = index.categories?.media?.items {
                for item in media {
                    let url = item.url ?? "https://raw.githubusercontent.com/\(owner)/\(repo)/main/\(item.name).json"
                    do {
                        let data = try await fetchData(from: url)
                        // 保存到 UserDefaults
                        UserDefaults.standard.set(data, forKey: "data_source_profiles_v1")
                        print("[RuleRepository] Installed media profile: \(item.name)")
                    } catch {
                        print("[RuleRepository] Failed to install media profile \(item.name): \(error)")
                    }
                }
            }
        } catch {
            // 尝试下载 DataSourceProfile.json
            let url = "https://raw.githubusercontent.com/\(owner)/\(repo)/main/DataSourceProfile.json"
            do {
                let data = try await fetchData(from: url)
                UserDefaults.standard.set(data, forKey: "data_source_profiles_v1")
                print("[RuleRepository] Installed DataSourceProfile.json")
            } catch {
                print("[RuleRepository] Failed to install DataSourceProfile.json: \(error)")
            }
        }
    }

    /// 同步壁纸规则
    func syncWallpaperRules() async throws {
        guard let owner = currentOwner, let repo = currentRepo else {
            throw RuleRepositoryError.notConfigured
        }

        print("[RuleRepository] Syncing wallpaper rules...")

        // 尝试从 index.json 获取壁纸规则
        do {
            let index = try await fetchIndex()

            if let wallpaper = index.categories?.wallpaper?.items {
                for item in wallpaper {
                    do {
                        _ = try await ruleLoader.installRuleFromGitHub(
                            owner: owner,
                            repo: repo,
                            path: "wallpaper/\(item.name).json"
                        )
                        print("[RuleRepository] Installed wallpaper rule: \(item.name)")
                    } catch {
                        // 尝试根目录
                        do {
                            _ = try await ruleLoader.installRuleFromGitHub(
                                owner: owner,
                                repo: repo,
                                path: "\(item.name).json"
                            )
                        } catch {
                            print("[RuleRepository] Failed to install \(item.name): \(error)")
                        }
                    }
                }
            }
        } catch {
            // 尝试常见文件名
            let commonFiles = ["DataSourceProfile.json", "wallhaven.json", "motionbgs.json"]
            for file in commonFiles {
                do {
                    _ = try await ruleLoader.installRuleFromGitHub(
                        owner: owner,
                        repo: repo,
                        path: file
                    )
                    print("[RuleRepository] Installed rule from: \(file)")
                    break
                } catch {
                    continue
                }
            }
        }
    }

    // MARK: - 辅助方法

    private func fetchData(from urlString: String) async throws -> Data {
        guard let url = URL(string: urlString) else {
            throw RuleRepositoryError.invalidURL(urlString)
        }

        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw RuleRepositoryError.downloadFailed
        }

        return data
    }

    // MARK: - 获取当前状态

    func getCurrentRepo() -> String? {
        return currentRepoURL
    }

    func isConfigured() -> Bool {
        return currentOwner != nil && currentRepo != nil
    }
}

// MARK: - 数据模型

struct RepositoryIndex: Codable {
    let schemaVersion: String?
    let lastUpdated: String?
    let categories: RuleCategories?

    struct RuleCategories: Codable {
        let wallpaper: WallpaperCategory?
        let media: MediaCategory?
        // 注意：anime 类别不由 RuleRepository 管理
        // 动漫规则由 AnimeRuleStore/KazumiRuleLoader 独立管理
    }

    struct WallpaperCategory: Codable {
        let description: String?
        let items: [WallpaperRuleInfo]?
    }

    struct MediaCategory: Codable {
        let description: String?
        let items: [WallpaperRuleInfo]?
    }

    struct WallpaperRuleInfo: Codable {
        let name: String
        let version: String?
        let deprecated: Bool?
        let url: String?
    }
}

// MARK: - 错误类型

enum RuleRepositoryError: Error, LocalizedError {
    case invalidURL(String)
    case notConfigured
    case downloadFailed
    case indexNotFound
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "Invalid GitHub URL: \(url)"
        case .notConfigured:
            return "Repository not configured"
        case .downloadFailed:
            return "Failed to download from repository"
        case .indexNotFound:
            return "index.json not found in repository"
        case .parseError(let msg):
            return "Parse error: \(msg)"
        }
    }
}
