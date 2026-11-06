import Foundation
import ServiceManagement

@MainActor
protocol BackgroundAgentServiceRegistration {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() async throws
}

extension SMAppService: BackgroundAgentServiceRegistration {}

enum BackgroundAgentRegistrationError: LocalizedError {
    case approvalRequired
    case missingComponent(String)
    case unavailable(Int)
    /// 注册记录已落库，但 launchd 里启动不起来或 mach service 连不上。
    /// 与 `.unavailable` 区分：这里 BTM 状态可能已是「已启用」，旧校验会把它
    /// 当成正常，实际客户端一连就 4099。
    case launchdJobNotReady(String)
    /// 连接成功，但对方是旧构建或协议版本落后。
    ///
    /// 用户用新包替换旧版本后，launchd 的 KeepAlive 可能仍持有旧 helper 进程；
    /// 原地升级（`prepareForUpgrade`）失败时只能注销重注册，让 launchd 从当前
    /// bundle 重新拉起。没有这条，界面只会停在「版本不匹配，请重试连接」。
    case helperOutdated(String)
    /// launchd 一直拉不起 Helper（`spawn failed` + exit 78），常规注销/重注册也救不回来：
    /// 当前注册的 BTM 记录损坏。界面给「修复后台服务」按钮，改用备用 Label 重建记录。
    case launchdSpawnRejected(String)
    /// 已经换到备用注册，launchd 仍拉不起 Helper。
    case registrationRepairFailed(String)

    var errorDescription: String? {
        switch self {
        case .approvalRequired:
            return "请在系统设置 → 通用 → 登录项中允许 WaifuX 后台服务"
        case .missingComponent(let path):
            return "WaifuX 后台服务组件缺失或无效，请重新安装应用：\(path)"
        case .unavailable(let status):
            return "WaifuX 后台服务注册失败（状态 \(status)），请重试或重新安装应用"
        case .launchdJobNotReady(let detail):
            return "WaifuX 后台服务已注册但未能启动（\(detail)）。请在系统设置 → 通用 → 登录项中允许 WaifuX 后台服务；仍失败请重装应用"
        case .helperOutdated(let detail):
            return "WaifuX 后台服务仍是旧版本（\(detail)），正在重新注册后台服务；若反复出现请重新安装应用"
        case .launchdSpawnRejected:
            return "WaifuX 后台服务的系统登录项记录已损坏，系统无法启动它。请点「修复后台服务」，只重建 WaifuX 自己的记录，不影响其他应用"
        case .registrationRepairFailed:
            return "WaifuX 已重建后台服务记录，系统仍无法启动它。请在设置 → 日志诊断里导出全部日志发给我们"
        }
    }
}

/// Helper 当前用哪一份 LaunchAgent 注册。默认 `.bundled`；只有用户点了
/// 「修复后台服务」才会换到 `.relinked`（原因见 `BackgroundAgentWire.relinkedPlistName`）。
enum BackgroundAgentRegistrationMode: String, Sendable {
    case bundled
    case relinked

    var plistName: String {
        self == .bundled ? BackgroundAgentWire.plistName : BackgroundAgentWire.relinkedPlistName
    }

    var launchdLabel: String {
        self == .bundled ? BackgroundAgentWire.bundleIdentifier : BackgroundAgentWire.relinkedLabel
    }
}

/// Shared by the real UI startup and the signed registration regression.
@MainActor
enum BackgroundAgentRegistration {
    static func validateBundle(_ host: URL, plistName: String = BackgroundAgentWire.plistName,
                               machServiceName: String = BackgroundAgentWire.machServiceName) throws {
        let plist = host.appendingPathComponent("Contents/Library/LaunchAgents").appendingPathComponent(plistName)
        guard let data = try? Data(contentsOf: plist),
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let program = values["BundleProgram"] as? String, !program.hasPrefix("/"),
              (values["MachServices"] as? [String: Any])?[machServiceName] as? Bool == true else {
            throw BackgroundAgentRegistrationError.missingComponent(plist.path)
        }
        let root = host.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let executable = host.appendingPathComponent(program).resolvingSymlinksInPath().standardizedFileURL
        guard executable.path.hasPrefix(root), FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw BackgroundAgentRegistrationError.missingComponent(executable.path)
        }
    }

    static func ensureEnabled(_ service: some BackgroundAgentServiceRegistration) throws {
        switch service.status {
        case .enabled:
            return
        case .requiresApproval:
            throw BackgroundAgentRegistrationError.approvalRequired
        case .notRegistered, .notFound:
            // On a fresh install BTM may have no record and return notFound even
            // though the embedded plist and executable are present. Register once.
            do { try service.register() }
            catch {
                if service.status == .requiresApproval { throw BackgroundAgentRegistrationError.approvalRequired }
                throw error
            }
        @unknown default:
            throw BackgroundAgentRegistrationError.unavailable(service.status.rawValue)
        }
        switch service.status {
        case .enabled: return
        case .requiresApproval: throw BackgroundAgentRegistrationError.approvalRequired
        default: throw BackgroundAgentRegistrationError.unavailable(service.status.rawValue)
        }
    }

    /// BTM 记录还在（`status == .enabled`）、launchd 域里却没有 job 时的恢复路径。
    ///
    /// 这种脱节状态下 `ensureEnabled` 因为只看 `status` 而完全修不了：客户端连接
    /// mach service 会以 `NSCocoaErrorDomain` 4099（找不到帮助程序）失败，
    /// `backgroundtaskmanagementd` 自己也报 `copyJobWithLabel … error 113`。
    /// 唯一可靠的恢复是注销再注册一次，让 BTM 把 job 重新下发给 launchd。
    ///
    /// 2026-10-19 用户机日志复核：旧实现用固定 600ms 等待 + 只看 `status == .enabled`
    /// 收尾，会「报成功」而 launchd 里其实仍不可达；`try?` 还把注销失败吞掉，
    /// 此时 `ensureEnabled` 看到旧的 `.enabled` 直接 return，整轮 repair 等于空转。
    /// 现在每一步都改真轮询，并且必须由 `probe` 证明 mach service 真能连。
    ///
    /// - Parameter probe: 真实可达性探针（通常是一次短超时 XPC `hello`）。
    ///   为 nil 时只校验到 BTM 状态，供不做 XPC 的回归测试使用。
    /// 丢弃 launchd 域里缓存的 job，让下一次 register 重新导入并按当前二进制重算启动约束。
    ///
    /// `SMAppService` 的注销/注册走 smd → BTM，**不会**让 launchd 丢掉已经算好的
    /// 启动约束（LWCR）。当可执行文件的签名类别变了 —— 典型场景是 Developer ID
    /// 签的正式包与 Apple Development 签的 Xcode 构建在同一台开发机上交替运行 ——
    /// launchd 会拿旧约束校验新二进制，判 `Launch Constraint Violation` 后直接
    /// SIGKILL：进程活不到一秒、退出码 78（EX_CONFIG），而 BTM 状态始终显示
    /// enabled，整轮 repair 要走到最后 probe 才失败（2026-10-26 本机取证：
    /// DiagnosticReports 里 `termination.namespace = CODESIGNING`）。
    ///
    /// 必须在注销**之后**调用：BTM 记录还在时 smd 会把 job 重新下发，bootout 反而
    /// 立刻触发一次用旧约束的 spawn。bootout 到不存在的 job 返回非零属正常（幂等）。
    static func bootoutCachedJob(label: String = BackgroundAgentWire.bundleIdentifier) async {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["bootout", "gui/\(getuid())/\(label)"]
            // 丢了输出就不会有管道写满挂起的风险。
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return }
            // Process 没有内建超时，卡住会把这个 detached 任务永久挂起。
            let deadline = Date().addingTimeInterval(5)
            while process.isRunning, Date() < deadline {
                usleep(50_000)
            }
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }.value
    }

    /// - Parameter bootout: 注销之后、注册之前丢弃 launchd 里缓存的 job。
    ///   为 nil 时跳过，供不接触真实 launchd 的回归测试使用。
    static func repairLaunchdRegistration(
        _ service: some BackgroundAgentServiceRegistration,
        bootout: (@MainActor () async -> Void)? = nil,
        probe: (@MainActor () async -> Bool)? = nil
    ) async throws {
        // 1. 注销，并等到 BTM 记录真的离开 .enabled。
        //    unregister 经 smd 异步落地；不等它落地，后面的 ensureEnabled 会看到
        //    旧状态直接 return，把「没修」当成「已修」。
        do {
            try await service.unregister()
        } catch {
            // 注销失败但状态已经不在 .enabled，说明脱节已解除，继续走注册。
            if service.status == .enabled { throw error }
        }
        try await waitForStatus(service, leaving: .enabled, attempts: 10,
                                failure: { "注销后仍为已启用（状态 \($0)）" })

        // 2. 丢掉 launchd 侧残留的 job。BTM 记录已在第 1 步删除，smd 不会再把
        //    它下发回来，所以这里只清 launchd 缓存；第 3 步的 register 会重新导入
        //    job 并按当前二进制的签名类别重算约束。跳过这一步时，注销/注册会复用
        //    旧约束，新二进制被判 Launch Constraint Violation 后 SIGKILL（退出码 78）。
        if let bootout { await bootout() }

        // 3. 重新注册，并等到 BTM 真的记回 .enabled。
        try ensureEnabled(service)
        try await waitForStatus(service, equals: .enabled, attempts: 10,
                                failure: { "注册后状态为 \($0)" })

        // 3. BTM 说 enabled 不等于 launchd 里端口可连 —— 旧实现缺的就是这一步。
        guard let probe else { return }
        for _ in 0..<8 {
            try Task.checkCancellation()
            if await probe() { return }
            try await Task.sleep(for: .milliseconds(300))
        }
        try Task.checkCancellation()
        if await probe() { return }
        throw BackgroundAgentRegistrationError.launchdJobNotReady("mach service 不可达")
    }

    // MARK: - 旧「开机自启」退役

    enum LoginItemRetirement: Equatable {
        case notEnabled
        case retired
        case stillEnabled
    }

    /// 注销 38.0.153 及以前用 `SMAppService.mainApp` 注册的「开机自启」，
    /// **等它在 BTM 落地后**才返回，调用方之后再注册 Helper。
    ///
    /// 154 原来在 `applicationDidFinishLaunching` 里用同步 `unregister()` 发出去就不管，
    /// bootstrap 紧接着注册 Helper，两次写入落在 BTM 同一条 WaifuX 父记录上。
    /// 用户机（2026-11-05，153 开过自启后 Sparkle 升 154）留下「Helper 子记录指向父记录、
    /// 父记录不列子记录」，launchd 每次 spawn 都 `copy_bundle_path` 失败、exit 78。
    /// 注销经 smd 异步落地，所以要轮询到状态真的离开 `.enabled`。
    /// 尽力而为：没退掉只返回 `.stillEnabled` 让调用方记日志，不阻断启动；取消照常抛出。
    static func retireMainAppLoginItem(
        _ service: some BackgroundAgentServiceRegistration,
        attempts: Int = 15
    ) async throws -> LoginItemRetirement {
        guard service.status == .enabled else { return .notEnabled }
        do {
            try await service.unregister()
        } catch {
            // 注销报错不等于没生效，下面按真实状态判断。
            if error is CancellationError { throw error }
        }
        for _ in 0..<attempts {
            try Task.checkCancellation()
            if service.status != .enabled { return .retired }
            try await Task.sleep(for: .milliseconds(200))
        }
        try Task.checkCancellation()
        return service.status == .enabled ? .stillEnabled : .retired
    }

    // MARK: - 换 Label 重建 BTM 子记录（「修复后台服务」）

    /// 由 BTM 的真实状态推出当前注册，不另存文件：备用注册已启用（或等用户批准）
    /// 就是 `.relinked`，否则按默认注册走。
    static func currentMode(relinked: some BackgroundAgentServiceRegistration) -> BackgroundAgentRegistrationMode {
        switch relinked.status {
        case .enabled, .requiresApproval: return .relinked
        default: return .bundled
        }
    }

    /// 把 Helper 从 `current` 注册迁到 `replacement` 注册。
    ///
    /// 顺序：注销旧注册并等它离开 `.enabled` → `bootout`（丢掉 launchd 里旧 Label 的
    /// job、释放同名 Mach service）→ 注册新 Label 并等回 `.enabled`。两份注册的
    /// MachServices 相同，旧 job 不先下线，新 job 拿不到端口。
    static func relinkAgent(
        from current: some BackgroundAgentServiceRegistration,
        to replacement: some BackgroundAgentServiceRegistration,
        bootout: (@MainActor () async -> Void)? = nil
    ) async throws {
        do {
            try await current.unregister()
        } catch {
            if error is CancellationError || current.status == .enabled { throw error }
        }
        try await waitForStatus(current, leaving: .enabled, attempts: 10,
                                failure: { "旧注册注销后仍为已启用（状态 \($0)）" })
        if let bootout { await bootout() }
        try ensureEnabled(replacement)
        try await waitForStatus(replacement, equals: .enabled, attempts: 10,
                                failure: { "备用注册后状态为 \($0)" })
    }

    // MARK: - launchd 侧证据

    /// `launchctl print gui/<uid>/<label>` 的原文（最多 64 KiB，默认 3s 超时）；跑不起来返回 nil。
    /// 输出写临时文件再读回，不用管道，避免缓冲区写满把子进程卡住。
    nonisolated static func launchdJobDescription(label: String, timeout: TimeInterval = 3) async -> String? {
        await Task.detached(priority: .utility) { () -> String? in
            let manager = FileManager.default
            let capture = manager.temporaryDirectory.appendingPathComponent("waifux-launchctl-\(UUID().uuidString).txt")
            guard manager.createFile(atPath: capture.path, contents: nil),
                  let handle = try? FileHandle(forWritingTo: capture) else { return nil }
            defer { try? manager.removeItem(at: capture) }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["print", "gui/\(getuid())/\(label)"]
            process.standardOutput = handle
            process.standardError = handle
            guard (try? process.run()) != nil else {
                try? handle.close()
                return nil
            }
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning, Date() < deadline { usleep(50_000) }
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            try? handle.close()
            guard let data = try? Data(contentsOf: capture) else { return nil }
            return String(decoding: data.prefix(64 * 1024), as: UTF8.self)
        }.value
    }

    /// launchd 一直拉不起 Helper 的证据：顶层 `job state = spawn failed` 且
    /// `last exit code = 78`（EX_CONFIG）。命中返回一行摘要，否则 nil。
    ///
    /// 用户机原文（2026-11-05）：`job state = spawn failed`、`last exit code = 78: EX_CONFIG`、
    /// `runs = 61`，launchd 日志同时报 `copy_bundle_path(...) error 0x6f`。
    /// 只认这几行顶层字段，coalition 等嵌套块里的 `state = active` 不参与判断。
    nonisolated static func spawnRejectionSummary(_ description: String) -> String? {
        var jobState: String?
        var lastExit: String?
        var runs: String?
        for raw in description.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("job state = ") {
                jobState = String(line.dropFirst("job state = ".count))
            } else if line.hasPrefix("last exit code = ") {
                lastExit = String(line.dropFirst("last exit code = ".count))
            } else if line.hasPrefix("runs = ") {
                runs = String(line.dropFirst("runs = ".count))
            }
        }
        guard jobState == "spawn failed", let lastExit, lastExit.hasPrefix("78") else { return nil }
        return "job state=spawn failed, last exit=\(lastExit), runs=\(runs ?? "?")"
    }

    /// 轮询等待状态变化。用 `try await Task.sleep`（不是 `try?`）让调用方的
    /// 取消能真正打断等待 —— 否则被取消的那一轮会继续往下跑完注销/注册。
    private static func waitForStatus(
        _ service: some BackgroundAgentServiceRegistration,
        equals target: SMAppService.Status,
        attempts: Int,
        failure: (Int) -> String
    ) async throws {
        for _ in 0..<attempts {
            try Task.checkCancellation()
            if service.status == target { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        try Task.checkCancellation()
        guard service.status == target else {
            throw BackgroundAgentRegistrationError.launchdJobNotReady(failure(service.status.rawValue))
        }
    }

    private static func waitForStatus(
        _ service: some BackgroundAgentServiceRegistration,
        leaving unwanted: SMAppService.Status,
        attempts: Int,
        failure: (Int) -> String
    ) async throws {
        for _ in 0..<attempts {
            try Task.checkCancellation()
            if service.status != unwanted { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        try Task.checkCancellation()
        guard service.status != unwanted else {
            throw BackgroundAgentRegistrationError.launchdJobNotReady(failure(service.status.rawValue))
        }
    }
}
