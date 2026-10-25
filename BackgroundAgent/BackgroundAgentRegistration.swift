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
        }
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
    static func repairLaunchdRegistration(
        _ service: some BackgroundAgentServiceRegistration,
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

        // 2. 重新注册，并等到 BTM 真的记回 .enabled。
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
