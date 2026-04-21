import Foundation
import AppKit
import Combine

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
    private var cancellables = Set<AnyCancellable>()

    private init() {
        // 监听 VideoWallpaperManager 恢复自己播放时，清空外部接管标记
        VideoWallpaperManager.shared.$currentVideoURL
            .receive(on: DispatchQueue.main)
            .sink { [weak self] url in
                if url != nil {
                    self?.isControllingExternalEngine = false
                    self?.isExternalPaused = false
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
        isControllingExternalEngine = false
        isExternalPaused = false
        lastWallpaperPath = nil

        lastWallpaperPath = path
        isExternalPaused = false
        isControllingExternalEngine = true

        if let screens = targetScreens, !screens.isEmpty {
            for screen in screens {
                guard let index = NSScreen.screens.firstIndex(of: screen) else { continue }
                try executeCLI(arguments: ["set", path, String(index)])
            }
        } else {
            try executeCLI(arguments: ["set", path])
        }
    }

    /// 切换为**非 CLI**壁纸（静态 / 本机视频等）时必须调用：向 CLI 发 `stop` 并清空桥接状态；可重复调用。
    func ensureStoppedForNonCLIWallpaper() {
        try? executeCLI(arguments: ["stop"])
        isControllingExternalEngine = false
        isExternalPaused = false
        lastWallpaperPath = nil
    }

    func stopWallpaper() {
        ensureStoppedForNonCLIWallpaper()
    }

    func pauseWallpaper() {
        guard isControllingExternalEngine else { return }
        isExternalPaused = true
        try? executeCLI(arguments: ["pause"])
    }

    func resumeWallpaper() {
        guard isControllingExternalEngine else { return }
        isExternalPaused = false
        try? executeCLI(arguments: ["resume"])
    }

    func toggleWallpaper() {
        guard isControllingExternalEngine else { return }
        if isExternalPaused {
            resumeWallpaper()
        } else {
            pauseWallpaper()
        }
    }

    func restoreIfNeeded() {
        guard isControllingExternalEngine, let path = lastWallpaperPath else { return }
        try? setWallpaper(path: path)
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

    private func executeCLI(arguments: [String]) throws {
        guard let cliPath = resolveCLIPath()?.path else {
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
                // 在 macOS 上，被 SIGKILL 等信号终止时 terminationStatus 常为信号编号（9 = SIGKILL），
                // 与「程序主动 exit(9)」不同；结合 terminationReason 更易理解。
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
