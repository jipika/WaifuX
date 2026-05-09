import Foundation
import AppKit
import Combine

/// 保证 CLI 命令按顺序执行的串行队列（文件级常量，避免 @MainActor 隔离）
private let weCLIQueue = DispatchQueue(
    label: "com.waifux.we.cli",
    qos: .userInitiated
)

/// 负责与 Wallpaper Engine CLI 通信的桥接层
/// 通过调用 wallpaperengine-cli 二进制控制壁纸引擎。
/// **scene** 与 **web** 均由 CLI 渲染，与本机视频壁纸一样属于「动态壁纸」：`isControllingExternalEngine` 为真时菜单栏应走 pause/resume/stop CLI，而非 `VideoWallpaperManager`。
@MainActor
final class WallpaperEngineXBridge: ObservableObject {
    static let shared = WallpaperEngineXBridge()

    /// 当前是否由 Wallpaper Engine CLI 接管桌面壁纸
    @Published private(set) var isControllingExternalEngine = false
    @Published private(set) var isExternalPaused = false

    private var lastWallpaperPath: String?
    private var targetScreenIDs = Set<String>()
    private var targetScreenFingerprints = Set<String>()
    private var cancellables = Set<AnyCancellable>()

    private let lastWallpaperPathKey = "we_last_wallpaper_path_v1"
    private let controllingExternalKey = "we_controlling_external_v1"
    private let targetScreenIDsKey = "we_target_screen_ids_v1"
    private let targetScreenFingerprintsKey = "we_target_screen_fingerprints_v1"

    private init() {
        // 监听 VideoWallpaperManager 恢复自己播放时，清空外部接管标记
        VideoWallpaperManager.shared.$currentVideoURL
            .receive(on: DispatchQueue.main)
            .sink { [weak self] url in
                if url != nil {
                    self?.isControllingExternalEngine = false
                    self?.isExternalPaused = false
                    self?.targetScreenIDs.removeAll()
                    self?.targetScreenFingerprints.removeAll()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - App 可用性

    var isWallpaperEngineXInstalled: Bool {
        WorkshopService.isWallpaperEngineAppInstalled()
    }

    var isWallpaperEngineXRunning: Bool {
        let bundleId = "com.WallpaperEngineX.app"
        return NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleId }
    }

    // MARK: - 控制接口

    func setWallpaper(path: String, posterURL: URL? = nil, targetScreens: [NSScreen]? = nil) throws {
        // 只停本机视频层；切勿调用 VideoWallpaperManager.stopWallpaper()（会恢复静态桌面，干扰后续 CLI set）。
        VideoWallpaperManager.shared.stopNativeVideoWallpaperOnly()

        // 每次应用 CLI 壁纸：先 stop 销毁上一轮 daemon/会话，再 set 重建，避免状态残留。
        try? executeCLI(arguments: ["stop"])

        lastWallpaperPath = path
        isExternalPaused = false
        isControllingExternalEngine = true
        if let screens = targetScreens, !screens.isEmpty {
            targetScreenIDs = Set(screens.map(\.wallpaperScreenIdentifier))
            targetScreenFingerprints = Set(screens.map(\.wallpaperScreenFingerprint))
        } else {
            targetScreenIDs = Set(NSScreen.screens.map(\.wallpaperScreenIdentifier))
            targetScreenFingerprints = Set(NSScreen.screens.map(\.wallpaperScreenFingerprint))
        }
        persistState()

        if let screens = targetScreens, !screens.isEmpty {
            for screen in screens {
                guard let index = NSScreen.screens.firstIndex(of: screen) else { continue }
                try executeCLI(arguments: ["set", path, String(index)])
            }
        } else {
            try executeCLI(arguments: ["set", path])
        }

        DynamicWallpaperAutoPauseManager.shared.reevaluateCurrentState()
    }

    /// 切换为**非 CLI**壁纸（静态 / 本机视频等）时必须调用：向 CLI 发 `stop` 并清空桥接状态；可重复调用。
    func ensureStoppedForNonCLIWallpaper() {
        Self.runCLIFireAndForget(arguments: ["stop"])
        isControllingExternalEngine = false
        isExternalPaused = false
        targetScreenIDs.removeAll()
        targetScreenFingerprints.removeAll()
        // 保留 lastWallpaperPath 与持久化路径，以便「关闭后再启用」时能恢复
        UserDefaults.standard.removeObject(forKey: controllingExternalKey)
        UserDefaults.standard.removeObject(forKey: targetScreenIDsKey)
        UserDefaults.standard.removeObject(forKey: targetScreenFingerprintsKey)
    }

    func stopWallpaper() {
        ensureStoppedForNonCLIWallpaper()
    }

    func pauseWallpaper() {
        guard isControllingExternalEngine else { return }
        isExternalPaused = true
        Self.runCLIFireAndForget(arguments: ["pause"])
    }

    func resumeWallpaper() {
        guard isControllingExternalEngine else { return }
        isExternalPaused = false
        Self.runCLIFireAndForget(arguments: ["resume"])
    }

    func toggleWallpaper() {
        guard isControllingExternalEngine else { return }
        if isExternalPaused {
            resumeWallpaper()
        } else {
            pauseWallpaper()
        }
    }

    func shouldPauseForFullscreenCoveredScreenIDs(_ coveredScreenIDs: Set<String>) -> Bool {
        let activeTargets = activeTargetScreens()
        guard !activeTargets.isEmpty else { return false }
        let activeTargetIDs = Set(activeTargets.map(\.wallpaperScreenIdentifier))
        return activeTargetIDs.isSubset(of: coveredScreenIDs)
    }

    func restoreIfNeeded() {
        // 从 UserDefaults 恢复上次状态（不在 init 中读取，避免 macOS 26+ _CFXPreferences 递归崩溃）
        if !isControllingExternalEngine {
            if let path = UserDefaults.standard.string(forKey: lastWallpaperPathKey) {
                lastWallpaperPath = path
            }
            targetScreenIDs = Set(UserDefaults.standard.stringArray(forKey: targetScreenIDsKey) ?? [])
            targetScreenFingerprints = Set(UserDefaults.standard.stringArray(forKey: targetScreenFingerprintsKey) ?? [])
        }

        // 只有上次确实在使用 WE 壁纸（controllingExternalKey == true）时才恢复。
        // 切换到静态壁纸时 lastWallpaperPath 会被故意保留以便未来手动重启用，
        // 但 controllingExternalKey 已被清除，借此区分「上次正在使用」与「曾经使用过」。
        guard UserDefaults.standard.bool(forKey: controllingExternalKey) else { return }

        guard let path = lastWallpaperPath else { return }
        isControllingExternalEngine = true
        isExternalPaused = false
        let hasPersistedTargets = !targetScreenIDs.isEmpty || !targetScreenFingerprints.isEmpty
        let screens = hasPersistedTargets ? activeTargetScreens() : []
        try? setWallpaper(path: path, targetScreens: hasPersistedTargets && !screens.isEmpty ? screens : nil)
    }

    private func persistState() {
        if let path = lastWallpaperPath {
            UserDefaults.standard.set(path, forKey: lastWallpaperPathKey)
            UserDefaults.standard.set(isControllingExternalEngine, forKey: controllingExternalKey)
            UserDefaults.standard.set(Array(targetScreenIDs), forKey: targetScreenIDsKey)
            UserDefaults.standard.set(Array(targetScreenFingerprints), forKey: targetScreenFingerprintsKey)
        } else {
            clearPersistedState()
        }
    }

    private func clearPersistedState() {
        UserDefaults.standard.removeObject(forKey: lastWallpaperPathKey)
        UserDefaults.standard.removeObject(forKey: controllingExternalKey)
        UserDefaults.standard.removeObject(forKey: targetScreenIDsKey)
        UserDefaults.standard.removeObject(forKey: targetScreenFingerprintsKey)
    }

    /// 批量更新持久化状态中的壁纸路径（目录迁移后调用）
    func bulkUpdatePaths(oldPrefix: String, newPrefix: String) {
        guard let path = UserDefaults.standard.string(forKey: lastWallpaperPathKey) else { return }
        if path.hasPrefix(oldPrefix) {
            let newPath = newPrefix + String(path.dropFirst(oldPrefix.count))
            UserDefaults.standard.set(newPath, forKey: lastWallpaperPathKey)
            lastWallpaperPath = newPath
            print("[WallpaperEngineXBridge] Updated persisted path from \(oldPrefix) to \(newPrefix)")
        }
    }

    // MARK: - 私有方法

    /// 与 `executeCLI` 相同规则解析 bundled `wallpaperengine-cli`（供离线烘焙子进程使用）。
    nonisolated static func resolvedCLIExecutableURL() -> URL? {
        if let url = Bundle.main.url(forResource: "wallpaperengine-cli", withExtension: nil) {
            return url
        }
        let bundleResources = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/wallpaperengine-cli")
        if FileManager.default.fileExists(atPath: bundleResources.path) {
            return bundleResources
        }
        // 兼容 Xcode folder reference 导致 Resources 文件夹整体被打进 Contents/Resources/ 内，
        // 实际路径为 Contents/Resources/Resources/wallpaperengine-cli（与 steamcmd 布局一致）
        let nestedResources = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Resources/wallpaperengine-cli")
        if FileManager.default.fileExists(atPath: nestedResources.path) {
            return nestedResources
        }
        if let resourceURL = Bundle.main.resourceURL {
            let resourcePath = resourceURL.appendingPathComponent("wallpaperengine-cli")
            if FileManager.default.fileExists(atPath: resourcePath.path) {
                return resourcePath
            }
        }
        let siblingPath = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("wallpaperengine-cli")
        if FileManager.default.fileExists(atPath: siblingPath.path) {
            return siblingPath
        }
        let projectPaths = [
            "/Volumes/mac/CodeLibrary/Claude/WallHaven/wallpaperengine-cli",
            "/Volumes/mac/CodeLibrary/Claude/WallHaven/Resources/wallpaperengine-cli"
        ]
        for path in projectPaths {
            if FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    private func resolveCLIPath() -> URL? {
        Self.resolvedCLIExecutableURL()
    }

    private func activeTargetScreens() -> [NSScreen] {
        if targetScreenIDs.isEmpty && targetScreenFingerprints.isEmpty {
            return NSScreen.screens
        }
        relinkTargetScreens()
        return NSScreen.screens.filter { screen in
            targetScreenIDs.contains(screen.wallpaperScreenIdentifier) ||
            targetScreenFingerprints.contains(screen.wallpaperScreenFingerprint)
        }
    }

    private func relinkTargetScreens() {
        for screen in NSScreen.screens where targetScreenFingerprints.contains(screen.wallpaperScreenFingerprint) {
            targetScreenIDs.insert(screen.wallpaperScreenIdentifier)
        }
    }

    // MARK: - CLI 执行

    /// 核心 CLI 执行。nonisolated 确保可在任意线程/队列调用，不阻塞主线程。
    nonisolated private static func _runCLI(arguments: [String]) throws {
        guard let cliPath = resolvedCLIExecutableURL()?.path else {
            throw WallpaperEngineError.cliNotFound
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: cliPath)
        task.arguments = arguments

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            task.waitUntilExit()
            if task.terminationStatus != 0 {
                let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    throw WallpaperEngineError.executionFailed(trimmed)
                }
                let status = task.terminationStatus
                var signalHint = ""
                if #available(macOS 10.15, *) {
                    if task.terminationReason == .uncaughtSignal {
                        if status == 9 {
                            signalHint = "（多为 SIGKILL：内存压力、活动监视器「强制退出」、或其它进程强杀；可查看 /tmp/wallpaperengine-cli-daemon.log）"
                        } else {
                            signalHint = "（未捕获信号终止）"
                        }
                    }
                } else if status == 9 {
                    signalHint = "（若未打印错误信息，退出码 9 常为 SIGKILL）"
                }
                throw WallpaperEngineError.cliExitCode(status, signalHint)
            }
        } catch let error as WallpaperEngineError {
            throw error
        } catch {
            throw WallpaperEngineError.executionFailed(error.localizedDescription)
        }
    }

    /// 后台串行 fire-and-forget。用于 pause/resume/stop 等高频自动触发场景，主线程不阻塞。
    nonisolated private static func runCLIFireAndForget(arguments: [String]) {
        weCLIQueue.async {
            try? Self._runCLI(arguments: arguments)
        }
    }

    /// 同步执行并传递错误。仅在用户主动 setWallpaper 这种低频操作中使用。
    private func executeCLI(arguments: [String]) throws {
        var capturedError: WallpaperEngineError?
        weCLIQueue.sync {
            do {
                try Self._runCLI(arguments: arguments)
            } catch let error as WallpaperEngineError {
                capturedError = error
            } catch {
                capturedError = .executionFailed(error.localizedDescription)
            }
        }
        if let error = capturedError { throw error }
    }
}

enum WallpaperEngineError: LocalizedError {
    case notInstalled
    case cliNotFound
    /// 第二个参数为补充说明（例如 SIGKILL 提示），可为空字符串。
    case cliExitCode(Int32, String)
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled: return "Wallpaper Engine 未安装"
        case .cliNotFound: return "未找到 wallpaperengine-cli 二进制文件"
        case .cliExitCode(let code, let hint):
            if hint.isEmpty {
                return "CLI 退出码: \(code)"
            }
            return "CLI 退出码: \(code) \(hint)"
        case .executionFailed(let msg): return msg
        }
    }
}
