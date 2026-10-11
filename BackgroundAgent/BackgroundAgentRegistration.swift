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

    var errorDescription: String? {
        switch self {
        case .approvalRequired:
            return "请在系统设置 → 通用 → 登录项中允许 WaifuX 后台服务"
        case .missingComponent(let path):
            return "WaifuX 后台服务组件缺失或无效，请重新安装应用：\(path)"
        case .unavailable(let status):
            return "WaifuX 后台服务注册失败（状态 \(status)），请重试或重新安装应用"
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
    static func repairLaunchdRegistration(_ service: some BackgroundAgentServiceRegistration) async throws {
        try? await service.unregister()
        // 注销/注册经由 smd 异步落地，等状态与 launchd 域稳定后再继续。
        try? await Task.sleep(for: .milliseconds(600))
        try ensureEnabled(service)
        // register 返回时 launchd 可能还没加载完 job 与 mach service 端口。
        try? await Task.sleep(for: .milliseconds(600))
        guard service.status == .enabled else {
            throw BackgroundAgentRegistrationError.unavailable(service.status.rawValue)
        }
    }
}
