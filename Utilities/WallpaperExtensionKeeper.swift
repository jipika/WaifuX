//  壁纸扩展守护（Wallpaper Extension Keeper）
//
//  背景（2026-09-23 日志实锤，见 AGENTS.md「壁纸扩展守护」）：
//  pkd (pluginkit daemon) 会以 "remove all extension instances: caller = pkd" 让
//  launchd 对 WaifuXWallpaperExtension 发 SIGTERM，两类场景：
//    1) App 启动 repair 的注册操作触发（已由注册指纹 + elected 闸门收敛，见
//       WaifuXApp.swift 的健康闸门）；
//    2) **App 完全退出后**，新起的 pkd 实例自发清点插件数据库，把宿主 App 不在
//       运行的第三方 appex 全部 remove（实测 2026-09-22 23:33 / 09-23 17:24，
//       后者杀掉了已连续渲染 91 分钟的健康扩展）。
//  扩展被杀后 WallpaperAgent ≥30 分钟不重新拉载（runtime-resolver 判
//  "Computed lifecycle action nothing"），桌面静默回落系统 aerials。
//
//  keeper 以主二进制 `--wallpaper-keeper` CLI 模式由 LaunchAgent 常驻：
//    用户在系统壁纸中选择了我们的扩展（Index.plist Provider 判定）
//    && 扩展进程不存在 && 主 App 未运行
//    → 执行与 App 启动 repair 相同的注册序列（lsregister -f / pluginkit -a /
//      pluginkit -e use），触发 WallpaperAgent 重新拉载，把桌面黑窗压到秒级。
//
//  铁律：
//    * 不写 Index.plist（系统壁纸库只读，见 WallpaperStoreSelectionProbe 禁令）
//    * 不 killall WallpaperAgent
//    * 扩展进程还活着时绝不执行注册操作——注册会触发 pkd remove 存活实例，
//      正是本案凶器；因此 revive 前有二次确认 + revive 前最后一道进程复查
//
//  keeper 进程刻意不读 UserDefaults（macOS 26+ 主线程 _CFXPreferences 隐式
//  递归陷阱；且 CLI 模式无 App 的延迟恢复机制），所有判定只依赖文件与进程表。

import Darwin
import Foundation
import os

enum WallpaperExtensionKeeper {
    // MARK: - 常量

    /// keeper CLI 模式参数（LaunchAgent ProgramArguments 的第二个元素）
    static let keeperModeArgument = "--wallpaper-keeper"
    static let extensionBundleID = "com.waifux.app.wallpaperextension"
    /// LaunchAgent 开关的持久化 key（仅 App 进程读写，keeper 进程不读）
    static let launchAgentDefaultsKey = "wallpaper_extension_keeper_enabled"
    static let launchAgentLabel = "com.waifux.wallpaperkeeper"

    private static let extensionExecutableSuffix =
        "/WaifuXWallpaperExtension.appex/Contents/MacOS/WaifuXWallpaperExtension"
    private static let mainExecutableName = "WaifuX"
    private static let log = OSLog(subsystem: "com.waifux.app", category: "WallpaperKeeper")

    /// 正常巡检间隔
    private static let pollIntervalSeconds: UInt32 = 10
    /// 启动宽限期：登录/切会话后 WallpaperAgent 拉载扩展需要时间，期间只观察不动作
    private static let startupGraceSeconds: UInt32 = 60
    /// 判定「需要 revive」后的二次确认间隔（防 proc 表瞬时抖动误判）
    private static let confirmIntervalSeconds: UInt32 = 5
    /// revive 后等待 WallpaperAgent 拉载扩展的验证窗口。
    /// 实测 LS 注册变更 → WallpaperAgent 重拉载延迟约 75–90s（2026-09-23 19:00 链路），
    /// 窗口必须覆盖它：误判失败后的重试注册会经 pkd remove 掉刚拉载的实例。
    private static let reviveVerifyWindowSeconds: UInt32 = 150
    /// revive 失败退避序列（秒），越界后维持最后一档
    private static let reviveBackoffSeconds: [UInt32] = [30, 60, 120, 300, 600]

    // MARK: - CLI 入口（keeper 模式主循环，不返回）

    static func run() {
        signal(SIGPIPE, SIG_IGN)
        signal(SIGTERM, { _ in exit(0) })
        signal(SIGINT, { _ in exit(0) })

        keeperLog("keeper started pid=\(getpid())")
        // 宽限期：登录风暴中 Index.plist / 扩展拉载都可能未就绪，先观察
        sleep(startupGraceSeconds)

        var consecutiveFailures = 0
        while true {
            var needRevive = false
            if shouldGuard() {
                sleep(confirmIntervalSeconds)
                needRevive = shouldGuard()
            }

            if needRevive {
                keeperLog("extension missing while selected — revive attempt \(consecutiveFailures + 1)")
                if reviveExtension() {
                    keeperLog("revive succeeded (extension relaunched)")
                    consecutiveFailures = 0
                } else {
                    consecutiveFailures += 1
                    let backoff = reviveBackoffSeconds[
                        min(consecutiveFailures - 1, reviveBackoffSeconds.count - 1)
                    ]
                    keeperLog("revive failed, backing off \(backoff)s")
                    sleep(backoff)
                }
            } else {
                consecutiveFailures = 0
                sleep(pollIntervalSeconds)
            }
        }
    }

    // MARK: - 判定

    /// 守卫条件全部满足才允许动手：
    /// 1) 用户把桌面壁纸选成了我们的扩展（否则扩展死了与我们无关，桌面本就是系统壁纸）
    /// 2) 扩展进程不存在
    /// 3) 主 App 未运行（App 在跑时由 App 侧 repair/健康检查负责，keeper 让位）
    static func shouldGuard() -> Bool {
        guard WallpaperStoreSelectionProbe.currentSelection() == .selected else { return false }
        guard processPids { $0.hasSuffix(extensionExecutableSuffix) }.isEmpty else { return false }
        guard mainAppPids().isEmpty else { return false }
        return true
    }

    /// 主 App（含任何路径的 WaifuX 可执行，Xcode 调试实例也算）是否在运行。
    /// keeper 与主 App 是同一个可执行文件，必须排除自身 pid。
    static func mainAppPids() -> [pid_t] {
        processPids(matching: { path in
            (path as NSString).lastPathComponent == mainExecutableName
        }, excludingPID: getpid())
    }

    /// Registration wakes pkd and can remove a healthy extension instance.
    static func isExtensionProcessRunning() -> Bool {
        !processPids(matching: { $0.hasSuffix(extensionExecutableSuffix) }).isEmpty
    }

    private static func processPids(
        matching predicate: (String) -> Bool,
        excludingPID excluded: pid_t? = nil
    ) -> [pid_t] {
        let needed = proc_listallpids(nil, 0)
        guard needed > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(needed) + 8)
        // buffersize 单位是字节（libproc 语义），返回值是实际填充的 pid 个数
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }

        var result: [pid_t] = []
        result.reserveCapacity(Int(count))
        for pid in pids.prefix(Int(count)) {
            if let excluded, pid == excluded { continue }
            // PROC_PIDPATHINFO_MAXSIZE
            var buf = [CChar](repeating: 0, count: 4096)
            let len = proc_pidpath(pid, &buf, UInt32(buf.count))
            guard len > 0 else { continue }
            if predicate(String(cString: buf)) {
                result.append(pid)
            }
        }
        return result
    }

    // MARK: - 自愈

    /// 重新注册内嵌扩展，触发 WallpaperAgent 重新拉载。
    /// 与 WaifuXApp 启动 repair 的注册序列一致（lsregister -f → pluginkit -a → -e use）。
    static func reviveExtension() -> Bool {
        let extensionURL = WaifuXHostBundle.bundleURL
            .appendingPathComponent("Contents/PlugIns/WaifuXWallpaperExtension.appex", isDirectory: true)
        return reviveExtension(at: extensionURL)
    }

    static func reviveExtension(at extensionURL: URL, shouldContinue: @Sendable () -> Bool = { true }) -> Bool {
        guard !BackgroundRuntimeRole.isIsolatedTest, shouldContinue() else { return false }
        guard FileManager.default.fileExists(atPath: extensionURL.path) else {
            keeperLog("embedded appex missing at \(extensionURL.path)")
            return false
        }

        guard WallpaperStoreSelectionProbe.currentSelection() == .selected else {
            keeperLog("extension no longer selected — skip registration")
            return false
        }

        // revive 前最后一道闸：注册操作会触发 pkd remove all instances，
        // 对存活扩展执行等于亲手触发本案凶器，因此此刻仍确认扩展不在才动手。
        guard !isExtensionProcessRunning() else {
            keeperLog("extension appeared just before revive — skip registration")
            return true
        }
        guard shouldContinue() else { return false }

        runTool(
            "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
            arguments: ["-f", extensionURL.path],
            label: "lsregister"
        )
        guard shouldContinue(), WallpaperStoreSelectionProbe.currentSelection() == .selected else { return false }
        guard !isExtensionProcessRunning() else { return true }
        runTool("/usr/bin/pluginkit", arguments: ["-a", extensionURL.path], label: "pluginkit add")
        guard shouldContinue(), WallpaperStoreSelectionProbe.currentSelection() == .selected else { return false }
        guard !isExtensionProcessRunning() else { return true }
        runTool(
            "/usr/bin/pluginkit",
            arguments: ["-e", "use", "-i", extensionBundleID],
            label: "pluginkit enable"
        )

        var waited: UInt32 = 0
        while waited < reviveVerifyWindowSeconds {
            guard shouldContinue(), WallpaperStoreSelectionProbe.currentSelection() == .selected else { return false }
            sleep(5)
            waited += 5
            if !processPids(matching: { $0.hasSuffix(extensionExecutableSuffix) }).isEmpty {
                return true
            }
        }
        keeperLog("extension not relaunched within \(reviveVerifyWindowSeconds)s")
        return false
    }

    @discardableResult
    private static func runTool(_ launchPath: String, arguments: [String], label: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            keeperLog("\(label) failed to launch: \(error.localizedDescription)")
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        let tail = output.isEmpty ? "" : " output=\(output.prefix(400))"
        keeperLog("\(label) exit=\(process.terminationStatus)\(tail)")
        return output
    }

    // MARK: - LaunchAgent 管理（仅 App 进程调用）

    static var launchAgentPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(launchAgentLabel).plist")
    }

    static var keeperLogFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/WaifuXKeeper.log")
    }

    static func isLaunchAgentInstalled() -> Bool {
        FileManager.default.fileExists(atPath: launchAgentPlistURL.path)
    }

    /// 按开关标志对齐 LaunchAgent 实际状态。
    /// App 启动与开关切换时调用；文件被清理工具/BTM 异常移除时自动补装。
    static func syncLaunchAgentWithEnabledFlag(_ enabled: Bool) {
        if enabled {
            if !isLaunchAgentInstalled() {
                installLaunchAgent()
            }
        } else {
            uninstallLaunchAgent()
        }
    }

    @discardableResult
    static func installLaunchAgent() -> Bool {
        guard let exePath = Bundle.main.executableURL?.path else {
            keeperLog("install: cannot resolve main executable")
            return false
        }
        // 旧配置先下线（plist 指向的 exe 路径可能已因更新变化）
        bootoutLaunchAgent()

        let logPath = keeperLogFileURL.path
        try? FileManager.default.createDirectory(
            at: keeperLogFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let plist: [String: Any] = [
            "Label": launchAgentLabel,
            "ProgramArguments": [exePath, keeperModeArgument],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Background",
            "ThrottleInterval": 30,
            "StandardOutPath": logPath,
            "StandardErrorPath": logPath,
        ]
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0
        ) else {
            keeperLog("install: plist serialization failed")
            return false
        }
        do {
            try data.write(to: launchAgentPlistURL)
        } catch {
            keeperLog("install: write plist failed: \(error.localizedDescription)")
            return false
        }

        guard bootstrapLaunchAgent() else {
            // 常见原因：BTM/系统设置里用户拒绝了该登录项。文件保留，
            // 用户在系统设置 → 登录项里允许后下次登录生效。
            keeperLog("install: bootstrap rejected (check System Settings > Login Items)")
            return false
        }
        keeperLog("installed and bootstrapped: \(launchAgentPlistURL.path)")
        return true
    }

    static func uninstallLaunchAgent() {
        bootoutLaunchAgent()
        try? FileManager.default.removeItem(at: launchAgentPlistURL)
        keeperLog("uninstalled")
    }

    private static func bootstrapLaunchAgent() -> Bool {
        runTool(
            "/bin/launchctl",
            arguments: ["bootstrap", "gui/\(getuid())", launchAgentPlistURL.path],
            label: "launchctl bootstrap"
        )
        // 最终以 launchd 里的 job 状态为准（BTM 拒绝、重复加载等都归结到这里）
        return isLaunchAgentJobLoaded()
    }

    private static func bootoutLaunchAgent() {
        runTool(
            "/bin/launchctl",
            arguments: ["bootout", "gui/\(getuid())/\(launchAgentLabel)"],
            label: "launchctl bootout"
        )
    }

    static func isLaunchAgentJobLoaded() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "gui/\(getuid())/\(launchAgentLabel)"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    // MARK: - 日志

    private static func keeperLog(_ message: String) {
        print("[WallpaperKeeper] \(message)")
        os_log(.info, log: log, "%{public}@", message)
    }
}
