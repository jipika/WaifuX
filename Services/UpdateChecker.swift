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
import Foundation
import AppKit

/// 自动更新管理器 - 处理下载和安装（参考 AltTab 实现）
@MainActor
final class UpdateManager: ObservableObject {
    static let shared = UpdateManager()
    
    // MARK: - 发布的状态
    @Published var state: UpdateState = .idle
    @Published var progress: Double = 0
    
    enum UpdateState: Equatable {
        case idle
        case checking
        case downloading(Double)
        case downloaded(URL)
        case installing
        case completed
        case error(String)
        
        var isIdle: Bool {
            if case .idle = self { return true }
            return false
        }
        
        var isDownloading: Bool {
            if case .downloading = self { return true }
            return false
        }
        
        var isDownloaded: Bool {
            if case .downloaded = self { return true }
            return false
        }
        
        var isInstalling: Bool {
            if case .installing = self { return true }
            return false
        }
        
        var progressValue: Double {
            switch self {
            case .downloading(let p): return p
            case .downloaded: return 1.0
            default: return 0
            }
        }
    }
    
    // MARK: - 配置
    private let owner = "jipika"
    private let repo = "WaifuX"
    
    private init() {}
    
    // MARK: - 下载更新
    
    func downloadUpdate(version: String) async {
        guard !state.isDownloading else { return }
        
        state = .downloading(0)
        progress = 0
        
        // 构建下载链接（使用 GitHub Releases 的直链）
        let downloadURL = "https://github.com/\(owner)/\(repo)/releases/download/v\(version)/WaifuX-\(version).dmg"
        
        guard let url = URL(string: downloadURL) else {
            state = .error("无效的下载链接")
            return
        }
        
        print("[UpdateManager] Downloading from: \(downloadURL)")
        
        // 创建临时下载路径
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("WaifuX_\(version)_update.dmg")
        
        // 清理已存在的临时文件
        if FileManager.default.fileExists(atPath: tempFile.path) {
            try? FileManager.default.removeItem(at: tempFile)
        }
        
        // 使用 URLSession 下载
        var request = URLRequest(url: url)
        request.setValue("WallHaven-App/\(UpdateChecker.shared.currentVersion)", forHTTPHeaderField: "User-Agent")
        
        do {
            let (downloadURL, response) = try await downloadWithProgress(request: request) { [weak self] p in
                Task { @MainActor in
                    self?.progress = p
                    self?.state = .downloading(p)
                }
            }
            
            guard let httpResponse = response as? HTTPURLResponse else {
                state = .error("无效的服务器响应")
                return
            }
            
            if httpResponse.statusCode == 404 {
                // 尝试备用链接格式
                let altURL = "https://github.com/\(owner)/\(repo)/releases/download/v\(version)/WaifuX.dmg"
                print("[UpdateManager] Trying alternate URL: \(altURL)")
                
                guard let altDownloadURL = URL(string: altURL) else {
                    state = .error("下载链接不存在 (404)")
                    return
                }
                
                let (altFile, altResponse) = try await downloadWithProgress(request: URLRequest(url: altDownloadURL)) { [weak self] p in
                    Task { @MainActor in
                        self?.progress = p
                        self?.state = .downloading(p)
                    }
                }
                
                try FileManager.default.moveItem(at: altFile, to: tempFile)
                state = .downloaded(tempFile)
                
            } else if httpResponse.statusCode != 200 {
                state = .error("下载失败 (HTTP \(httpResponse.statusCode))")
                return
            } else {
                // 移动文件到临时位置
                try FileManager.default.moveItem(at: downloadURL, to: tempFile)
                state = .downloaded(tempFile)
                print("[UpdateManager] Downloaded to: \(tempFile.path)")
            }
            
        } catch {
            print("[UpdateManager] Download error: \(error)")
            state = .error("下载失败: \(error.localizedDescription)")
        }
    }
    
    // MARK: - 安装更新
    
    func installUpdate() {
        guard case .downloaded(let dmgPath) = state else {
            print("[UpdateManager] No downloaded file to install")
            return
        }
        
        state = .installing
        
        // 创建 AppleScript 安装脚本（参考 AltTab 方式）
        let script = createAppleScript(dmgPath: dmgPath.path)
        
        var errorInfo: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else {
            state = .error("无法创建安装脚本")
            return
        }
        
        // 执行安装脚本
        appleScript.executeAndReturnError(&errorInfo)
        
        if let error = errorInfo {
            print("[UpdateManager] Install script error: \(error)")
            // 错误可能是正常的，因为脚本会杀掉当前进程
        }
        
        // 延迟后退出
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApplication.shared.terminate(nil)
        }
    }
    
    // MARK: - 辅助方法
    
    func reset() {
        state = .idle
        progress = 0
    }
    
    // MARK: - 私有方法
    
    private func downloadWithProgress(
        request: URLRequest,
        progressHandler: @escaping (Double) -> Void
    ) async throws -> (URL, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let session = URLSession(configuration: .default)
            let task = session.downloadTask(with: request) { url, response, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let url = url, let response = response else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                    return
                }
                continuation.resume(returning: (url, response))
            }
            
            // 监听下载进度
            let progressObserver = task.progress.observe(\.fractionCompleted, options: [.new]) { progress, _ in
                progressHandler(progress.fractionCompleted)
            }
            
            // 保持 observer 存活
            objc_setAssociatedObject(task, "observer", progressObserver, .OBJC_ASSOCIATION_RETAIN)
            
            task.resume()
        }
    }
    
    private func createAppleScript(dmgPath: String) -> String {
        let appName = "WaifuX"
        let bundleId = Bundle.main.bundleIdentifier ?? "com.waifux.app"
        
        // 创建 bash 脚本文件并执行（参考 AltTab 实现）
        let scriptContent = """
#!/bin/bash
set -e

DMG_PATH="\(dmgPath)"
APP_NAME="\(appName)"

# 等待原应用退出
sleep 1

# 强制退出应用
pkill -9 -x "$APP_NAME" 2>/dev/null || true
osascript -e 'quit app "$APP_NAME"' 2>/dev/null || true
sleep 2

# 创建临时挂载点
MOUNT_POINT="/tmp/WaifuX_Update_$$"
mkdir -p "$MOUNT_POINT"

# 挂载 DMG
hdiutil attach "$DMG_PATH" -mountpoint "$MOUNT_POINT" -nobrowse -quiet

# 查找应用
APP_PATH=$(find "$MOUNT_POINT" -name "*.app" -maxdepth 1 | head -n 1)

if [ -z "$APP_PATH" ]; then
    echo "Error: No app found in DMG"
    hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true
    exit 1
fi

# 复制到 Applications
DEST_PATH="/Applications/$APP_NAME.app"

if [ -d "$DEST_PATH" ]; then
    rm -rf "$DEST_PATH"
fi

cp -R "$APP_PATH" "$DEST_PATH"

# 卸载 DMG
hdiutil detach "$MOUNT_POINT" -quiet
rmdir "$MOUNT_POINT" 2>/dev/null || true

# 移除隔离属性
xattr -rd com.apple.quarantine "$DEST_PATH" 2>/dev/null || true

# 启动新版本
open "$DEST_PATH"

# 清理下载文件
rm -f "$DMG_PATH"
"""
        
        // 写入临时脚本文件
        let tempDir = FileManager.default.temporaryDirectory
        let scriptPath = tempDir.appendingPathComponent("waifux_update_\(UUID().uuidString).sh")
        
        do {
            try scriptContent.write(toFile: scriptPath.path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)
        } catch {
            print("[UpdateManager] Failed to create install script: \(error)")
        }
        
        // 使用 AppleScript 执行脚本（请求管理员权限）
        return """
        do shell script "bash '\(scriptPath.path)'" with administrator privileges
        """
    }
}
