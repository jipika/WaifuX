import Foundation
import AppKit

/// GitHub Commit 信息
struct GitHubCommit: Codable {
    let sha: String
    let commit: CommitDetails
    
    struct CommitDetails: Codable {
        let message: String
        let author: AuthorInfo
        
        struct AuthorInfo: Codable {
            let name: String
            let date: String
        }
    }
    
    /// 格式化的 commit message（第一行）
    var shortMessage: String {
        let lines = commit.message.components(separatedBy: .newlines)
        return lines.first ?? commit.message
    }
    
    /// 完整的 commit message
    var fullMessage: String {
        commit.message
    }
    
    /// 短 SHA（7位）
    var shortSHA: String {
        String(sha.prefix(7))
    }
}

/// GitHub Release 信息
struct GitHubRelease: Codable {
    let tagName: String
    let name: String
    let body: String?
    let htmlUrl: String
    let publishedAt: String
    let prerelease: Bool
    let draft: Bool
    let targetCommitish: String
    
    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlUrl = "html_url"
        case publishedAt = "published_at"
        case prerelease
        case draft
        case targetCommitish = "target_commitish"
    }
    
    /// 版本号（去掉 v 前缀）
    var version: String {
        tagName.replacingOccurrences(of: "v", with: "", options: .anchored)
    }
    
    /// 短 SHA（7位）
    var shortSHA: String {
        String(targetCommitish.prefix(7))
    }
}

/// 更新检查结果
enum UpdateCheckResult {
    case noUpdate(current: String)
    case updateAvailable(current: String, latest: GitHubRelease, commit: GitHubCommit?)
    case error(String)
}

/// GitHub 更新检测服务
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    @Published var isChecking = false
    @Published var lastCheckDate: Date?
    @Published var currentRelease: GitHubRelease?
    @Published var currentCommit: GitHubCommit?

    // GitHub 仓库配置
    private let owner = "jipika"
    private let repo = "WaifuX"
    private let apiURL = "https://api.github.com/repos/jipika/WaifuX/releases/latest"

    // UserDefaults keys
    private let lastCheckKey = "update_checker_last_check"
    private let cachedReleaseKey = "update_checker_cached_release"
    private let cachedCommitKey = "update_checker_cached_commit"

    private init() {
        // ⚠️ 不在 init 中读 UserDefaults，避免 _CFXPreferences 递归栈溢出
        // 缓存的检查结果通过 restoreCachedState() 延迟恢复
    }

    /// 延迟恢复缓存的更新检查状态（必须在 applicationDidFinishLaunching 中调用）
    func restoreCachedState() {
        if let date = UserDefaults.standard.object(forKey: lastCheckKey) as? Date {
            lastCheckDate = date
        }
        if let data = UserDefaults.standard.data(forKey: cachedReleaseKey) {
            currentRelease = try? JSONDecoder().decode(GitHubRelease.self, from: data)
        }
        if let data = UserDefaults.standard.data(forKey: cachedCommitKey) {
            currentCommit = try? JSONDecoder().decode(GitHubCommit.self, from: data)
        }
    }

    /// 获取当前应用版本
    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    /// 获取构建号
    var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    /// 完整版本字符串
    var fullVersionString: String {
        "\(currentVersion) (\(buildNumber))"
    }

    /// 检查更新
    func checkForUpdates() async -> UpdateCheckResult {
        isChecking = true
        defer { isChecking = false }

        guard let url = URL(string: apiURL) else {
            return .error("无效的 API URL")
        }

        var request = URLRequest(url: url)
        request.setValue("WallHaven-App/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return .error("无效的服务器响应")
            }

            if httpResponse.statusCode == 403 {
                // API 速率限制
                return .error("GitHub API 速率限制，请稍后重试")
            }

            guard httpResponse.statusCode == 200 else {
                return .error("服务器返回错误 (\(httpResponse.statusCode))")
            }

            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)

            // 过滤掉草稿和预发布版本
            guard !release.draft, !release.prerelease else {
                return .noUpdate(current: currentVersion)
            }

            // 获取 commit 信息
            let commit = await fetchCommit(sha: release.targetCommitish)

            // 缓存结果
            currentRelease = release
            currentCommit = commit
            lastCheckDate = Date()
            cacheResult(release: release, commit: commit)

            // 比较版本号
            if isReleaseNewer(release, than: currentVersion) {
                return .updateAvailable(current: currentVersion, latest: release, commit: commit)
            } else {
                return .noUpdate(current: currentVersion)
            }

        } catch let decodingError as DecodingError {
            return .error("解析响应失败: \(decodingError.localizedDescription)")
        } catch {
            return .error("检查失败: \(error.localizedDescription)")
        }
    }

    /// 获取指定 SHA 的 commit 信息
    private func fetchCommit(sha: String) async -> GitHubCommit? {
        let commitURL = "https://api.github.com/repos/\(owner)/\(repo)/commits/\(sha)"
        
        guard let url = URL(string: commitURL) else {
            return nil
        }

        var request = URLRequest(url: url)
        request.setValue("WallHaven-App/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return nil
            }

            return try JSONDecoder().decode(GitHubCommit.self, from: data)
        } catch {
            print("[UpdateChecker] Failed to fetch commit: \(error)")
            return nil
        }
    }

    /// 打开下载页面
    func openDownloadPage(for release: GitHubRelease? = nil) {
        let urlString: String
        if let release = release ?? currentRelease {
            urlString = release.htmlUrl
        } else {
            urlString = "https://github.com/\(owner)/\(repo)/releases"
        }

        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    /// 打开项目主页
    func openProjectPage() {
        if let url = URL(string: "https://github.com/\(owner)/\(repo)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 格式化上次检查时间
    func formattedLastCheckDate() -> String {
        guard let date = lastCheckDate else {
            return "从未检查"
        }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "上次检查: \(formatter.localizedString(for: date, relativeTo: Date()))"
    }

    // MARK: - Private

    private func cacheResult(release: GitHubRelease, commit: GitHubCommit?) {
        UserDefaults.standard.set(lastCheckDate, forKey: lastCheckKey)
        if let data = try? JSONEncoder().encode(release) {
            UserDefaults.standard.set(data, forKey: cachedReleaseKey)
        }
        if let commit = commit, let data = try? JSONEncoder().encode(commit) {
            UserDefaults.standard.set(data, forKey: cachedCommitKey)
        }
    }

    /// 比较版本号
    /// - Returns: true 如果 version1 比 version2 新
    private func isVersion(_ version1: String, newerThan version2: String) -> Bool {
        let components1 = version1.split(separator: ".").compactMap { Int($0) }
        let components2 = version2.split(separator: ".").compactMap { Int($0) }

        let maxLength = max(components1.count, components2.count)

        for i in 0..<maxLength {
            let v1 = i < components1.count ? components1[i] : 0
            let v2 = i < components2.count ? components2[i] : 0

            if v1 > v2 {
                return true
            } else if v1 < v2 {
                return false
            }
        }

        return false // 版本相同
    }

    /// 判断 GitHub Release 是否比本地版本新
    /// 支持语义化版本号比较（如 38.0.11 vs 38.0.12）
    private func isReleaseNewer(_ release: GitHubRelease, than localVersion: String) -> Bool {
        // 直接使用语义化版本比较
        return isVersion(release.version, newerThan: localVersion)
    }
}
