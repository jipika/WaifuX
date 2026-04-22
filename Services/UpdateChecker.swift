import Foundation
import AppKit

/// 线程安全的多线程下载进度跟踪
private actor DownloadProgressTracker {
    private var received: Int64 = 0
    private var lastReported: Double = 0
    private let total: Int64
    private let handler: @Sendable (Double) -> Void
    
    init(total: Int64, handler: @escaping @Sendable (Double) -> Void) {
        self.total = total
        self.handler = handler
    }
    
    func add(_ bytes: Int64) {
        received += bytes
        let progress = Double(received) / Double(total)
        if progress - lastReported >= 0.01 || received >= total {
            lastReported = progress
            handler(min(progress, 1.0))
        }
    }
}

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
    private let rateLimitUntilKey = "update_checker_rate_limit_until"
    
    // 最小检查间隔（秒）- 5分钟
    private let minCheckInterval: TimeInterval = 300
    // 遇到 403 后的冷却时间（秒）- 15分钟
    private let rateLimitCooldown: TimeInterval = 900

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
    /// - Parameter force: 是否强制检查，忽略时间间隔限制
    func checkForUpdates(force: Bool = false) async -> UpdateCheckResult {
        isChecking = true
        defer { isChecking = false }
        
        // 检查是否在冷却期内
        if !force, let rateLimitUntil = UserDefaults.standard.object(forKey: rateLimitUntilKey) as? Date,
           Date() < rateLimitUntil {
            let remaining = Int(rateLimitUntil.timeIntervalSince(Date()))
            let minutes = remaining / 60
            return .error("GitHub API 速率限制，请\(minutes)分钟后重试")
        }
        
        // 检查是否过于频繁（非强制模式下）
        if !force, let lastCheck = lastCheckDate {
            let elapsed = Date().timeIntervalSince(lastCheck)
            if elapsed < minCheckInterval {
                let remaining = Int(minCheckInterval - elapsed)
                let minutes = remaining / 60
                let seconds = remaining % 60
                if minutes > 0 {
                    return .error("检查过于频繁，请\(minutes)分\(seconds)秒后再试")
                } else {
                    return .error("检查过于频繁，请\(seconds)秒后再试")
                }
            }
        }

        guard let url = URL(string: apiURL) else {
            return .error("无效的 API URL")
        }

        var request = URLRequest(url: url)
        request.setValue("WaifuX-App/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return .error("无效的服务器响应")
            }

            if httpResponse.statusCode == 403 {
                // API 速率限制 - 设置冷却期
                let cooldownUntil = Date().addingTimeInterval(rateLimitCooldown)
                UserDefaults.standard.set(cooldownUntil, forKey: rateLimitUntilKey)
                return .error("GitHub API 速率限制，请15分钟后重试")
            }
            
            // 清除冷却期
            UserDefaults.standard.removeObject(forKey: rateLimitUntilKey)

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
        request.setValue("WaifuX-App/\(currentVersion)", forHTTPHeaderField: "User-Agent")
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
        guard !state.isDownloading else { 
            print("[UpdateManager] Download already in progress")
            return 
        }
        
        // 强制重置状态，防止进度条跳变
        progress = 0
        state = .downloading(0)
        
        // 尝试多个可能的下载链接格式
        let possibleURLs = [
            "https://github.com/\(owner)/\(repo)/releases/download/v\(version)/WaifuX-\(version).dmg",
            "https://github.com/\(owner)/\(repo)/releases/download/v\(version)/WaifuX.dmg",
            "https://github.com/\(owner)/\(repo)/releases/latest/download/WaifuX.dmg"
        ]
        
        print("[UpdateManager] Starting download for version: \(version)")
        
        for (index, urlString) in possibleURLs.enumerated() {
            print("[UpdateManager] Trying URL [\(index)]: \(urlString)")
            
            guard let url = URL(string: urlString) else {
                continue
            }
            
            do {
                try await downloadFromURL(url, version: version)
                return // 下载成功
            } catch {
                print("[UpdateManager] URL [\(index)] failed: \(error)")
                continue // 尝试下一个链接
            }
        }
        
        state = .error("所有下载链接都失败了")
    }
    
    private func downloadFromURL(_ url: URL, version: String) async throws {
        print("[UpdateManager] Downloading from: \(url.absoluteString)")
        
        // 创建最终下载路径
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("WaifuX_\(version)_update.dmg")
        
        // 清理已存在的临时文件
        if FileManager.default.fileExists(atPath: tempFile.path) {
            try? FileManager.default.removeItem(at: tempFile)
        }
        
        // 配置 URLSession
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 600
        let session = URLSession(configuration: config)
        
        var request = URLRequest(url: url)
        request.setValue("WaifuX-App/\(UpdateChecker.shared.currentVersion)", forHTTPHeaderField: "User-Agent")
        
        // 先尝试多线程并行下载，失败则回退到单线程
        let (downloadedFileURL, response): (URL, URLResponse)
        do {
            print("[UpdateManager] Attempting parallel chunked download...")
            (downloadedFileURL, response) = try await downloadParallelWithProgress(session: session, request: request) { [weak self] p in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    guard case .downloading = self.state else { return }
                    guard p > self.progress else { return }
                    self.progress = p
                    self.state = .downloading(p)
                }
            }
            print("[UpdateManager] Parallel download succeeded")
        } catch {
            print("[UpdateManager] Parallel download failed: \(error.localizedDescription), falling back to single connection")
            (downloadedFileURL, response) = try await downloadWithProgress(session: session, request: request) { [weak self] p in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    guard case .downloading = self.state else { return }
                    guard p > self.progress else { return }
                    self.progress = p
                    self.state = .downloading(p)
                }
            }
        }
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        
        print("[UpdateManager] HTTP Status: \(httpResponse.statusCode)")
        
        guard httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        
        // 移动到最终路径（如果路径不同）
        if downloadedFileURL != tempFile {
            // 如果目标已存在，先删除
            if FileManager.default.fileExists(atPath: tempFile.path) {
                try? FileManager.default.removeItem(at: tempFile)
            }
            try FileManager.default.moveItem(at: downloadedFileURL, to: tempFile)
        }
        
        await MainActor.run {
            progress = 1.0
            state = .downloaded(tempFile)
        }
        
        print("[UpdateManager] Downloaded to: \(tempFile.path)")
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
    
    /// 多线程分片并行下载，利用 HTTP Range 请求加速
    /// GitHub/S3 CDN 通常支持 Range，4-6 个并发可显著提升下载速度
    private func downloadParallelWithProgress(
        session: URLSession,
        request: URLRequest,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws -> (URL, URLResponse) {
        // 1. HEAD 请求获取文件大小并确认服务器支持 Range
        var headRequest = request
        headRequest.httpMethod = "HEAD"
        let (_, headResponse) = try await session.data(for: headRequest)
        
        guard let httpResponse = headResponse as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        
        let totalSize = headResponse.expectedContentLength
        guard totalSize > 0 else {
            throw URLError(.badServerResponse)
        }
        
        let acceptRanges = httpResponse.value(forHTTPHeaderField: "Accept-Ranges")
        guard acceptRanges?.lowercased() == "bytes" else {
            throw URLError(.unsupportedURL)
        }
        
        // 2. 分片配置：4 个并发，每个 chunk 至少 2MB
        let minChunkSize: Int64 = 2 * 1024 * 1024
        let preferredChunkCount = 4
        let chunkCount = max(1, min(preferredChunkCount, Int(totalSize / minChunkSize)))
        let chunkSize = Int(totalSize) / chunkCount
        
        let tempDir = FileManager.default.temporaryDirectory
        let finalFile = tempDir.appendingPathComponent("WaifuX_update_\(UUID().uuidString).dmg")
        FileManager.default.createFile(atPath: finalFile.path, contents: nil)
        
        let progress = DownloadProgressTracker(total: totalSize, handler: progressHandler)
        
        // 3. 并发下载每个 chunk 到独立临时文件
        struct ChunkInfo {
            let index: Int
            let file: URL
            let startOffset: Int64
        }
        
        let chunks = try await withThrowingTaskGroup(of: ChunkInfo.self) { group -> [ChunkInfo] in
            for i in 0..<chunkCount {
                let start = Int64(i * chunkSize)
                let end = (i == chunkCount - 1) ? (totalSize - 1) : (Int64((i + 1) * chunkSize - 1))
                
                group.addTask {
                    var chunkRequest = request
                    chunkRequest.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
                    chunkRequest.timeoutInterval = 300
                    
                    let (asyncBytes, chunkResponse) = try await session.bytes(for: chunkRequest)
                    guard let chunkHTTP = chunkResponse as? HTTPURLResponse,
                          (chunkHTTP.statusCode == 200 || chunkHTTP.statusCode == 206) else {
                        throw URLError(.badServerResponse)
                    }
                    
                    // 写入独立临时文件
                    let chunkFile = tempDir.appendingPathComponent("WaifuX_chunk_\(i)_\(UUID().uuidString).tmp")
                    FileManager.default.createFile(atPath: chunkFile.path, contents: nil)
                    let chunkHandle = try FileHandle(forWritingTo: chunkFile)
                    defer { try? chunkHandle.close() }
                    
                    var buffer = Data(capacity: 256 * 1024)
                    for try await byte in asyncBytes {
                        buffer.append(byte)
                        if buffer.count >= 256 * 1024 {
                            chunkHandle.write(buffer)
                            await progress.add(Int64(buffer.count))
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }
                    if !buffer.isEmpty {
                        chunkHandle.write(buffer)
                        await progress.add(Int64(buffer.count))
                    }
                    
                    return ChunkInfo(index: i, file: chunkFile, startOffset: start)
                }
            }
            
            var results: [ChunkInfo] = []
            for try await result in group {
                results.append(result)
            }
            return results
        }
        
        // 4. 串行合并所有 chunk 到最终文件（单线程，避免多写竞态）
        let finalHandle = try FileHandle(forWritingTo: finalFile)
        defer { try? finalHandle.close() }
        
        for chunk in chunks.sorted(by: { $0.index < $1.index }) {
            let readHandle = try FileHandle(forReadingFrom: chunk.file)
            defer { try? readHandle.close() }
            
            finalHandle.seek(toFileOffset: UInt64(chunk.startOffset))
            
            // 流式读取 chunk 文件并写入最终文件，避免一次性读入内存
            while true {
                let data = readHandle.readData(ofLength: 256 * 1024)
                if data.isEmpty { break }
                finalHandle.write(data)
            }
            
            // 清理 chunk 临时文件
            try? FileManager.default.removeItem(at: chunk.file)
        }
        
        progressHandler(1.0)
        return (finalFile, headResponse)
    }
    
    /// 使用 URLSession bytes API 精确跟踪下载进度
    /// 解决 downloadTask + KVO 在 GitHub 重定向时进度跳变的问题
    private func downloadWithProgress(
        session: URLSession,
        request: URLRequest,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws -> (URL, URLResponse) {
        let (asyncBytes, response) = try await session.bytes(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        
        // 获取文件总大小
        let expectedLength = response.expectedContentLength
        guard expectedLength > 0 else {
            // 无法获取大小，直接下载不报告进度
            let tempDir = FileManager.default.temporaryDirectory
            let tempFile = tempDir.appendingPathComponent("WaifuX_update_\(UUID().uuidString).dmg")
            var data = Data()
            for try await byte in asyncBytes {
                data.append(byte)
            }
            try data.write(to: tempFile)
            return (tempFile, response)
        }
        
        // 流式下载 + 精确进度报告
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("WaifuX_update_\(UUID().uuidString).dmg")
        
        // 确保临时文件不存在
        if FileManager.default.fileExists(atPath: tempFile.path) {
            try? FileManager.default.removeItem(at: tempFile)
        }
        
        // 创建输出文件句柄
        FileManager.default.createFile(atPath: tempFile.path, contents: nil)
        let fileHandle = try FileHandle(forWritingTo: tempFile)
        
        defer {
            try? fileHandle.close()
        }
        
        var receivedBytes: Int64 = 0
        var lastReportedProgress: Double = 0
        let bufferSize = 64 * 1024 // 64KB 缓冲区
        
        var buffer = Data(capacity: bufferSize)
        
        for try await byte in asyncBytes {
            buffer.append(byte)
            receivedBytes += 1
            
            // 缓冲区满了才写入磁盘
            if buffer.count >= bufferSize {
                fileHandle.write(buffer)
                buffer.removeAll(keepingCapacity: true)
            }
            
            // 每 1% 更新一次进度，减少 UI 更新频率
            let currentProgress = Double(receivedBytes) / Double(expectedLength)
            if currentProgress - lastReportedProgress >= 0.01 || receivedBytes == expectedLength {
                lastReportedProgress = currentProgress
                progressHandler(min(currentProgress, 1.0))
            }
        }
        
        // 写入剩余数据
        if !buffer.isEmpty {
            fileHandle.write(buffer)
        }
        
        // 最终进度
        progressHandler(1.0)
        
        return (tempFile, response)
    }
    
    private func createAppleScript(dmgPath: String) -> String {
        let appName = "WaifuX"
        _ = Bundle.main.bundleIdentifier ?? "com.waifux.app"
        
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
