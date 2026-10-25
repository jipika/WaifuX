#if WAIFUX_HELPER
import AppKit
import Security

private final class AgentEndpoint: NSObject, BackgroundAgentXPC, @unchecked Sendable {
    let connection: NSXPCConnection
    init(connection: NSXPCConnection) { self.connection = connection }

    func hello(_ reply: @escaping @Sendable (NSData) -> Void) {
        Task { @MainActor in
            var identity = BackgroundAgentBuildIdentity.running()
            #if DEBUG
            if BackgroundRuntimeRole.isIsolatedTest && BackgroundAgentRuntime.shared.regressionStaleIdentity { identity = "regression-stale-helper" }
            #endif
            let status = BackgroundAgentHello(protocolVersion: BackgroundAgentWire.protocolVersion, bundleIdentifier: Bundle.main.bundleIdentifier ?? "", processIdentifier: ProcessInfo.processInfo.processIdentifier, runtimeReady: BackgroundAgentRuntime.shared.isReady, buildIdentity: identity)
            reply((try? JSONEncoder().encode(status) as NSData) ?? NSData())
        }
    }
    func prepareForUpgrade(_ reply: @escaping @Sendable (NSData) -> Void) {
        let identity = ObjectIdentifier(connection)
        Task { @MainActor in UIClientExitMonitor.shared.markAnnouncedExit(identity) }
        Task { @MainActor in
            await BackgroundAgentRuntime.shared.prepareForUpgrade()
            reply(NSData())
            // Give XPC the acknowledgement before launchd replaces this process.
            try? await Task.sleep(for: .milliseconds(100))
            BackgroundAgentRuntime.shared.finishProcessExit()
            exit(75)
        }
    }
    func perform(_ command: NSData, reply: @escaping @Sendable (NSData) -> Void) {
        let bytes = command as Data
        // UI 的「告别」命令到达即记帐（与回复无关，mach 消息在发送者退出
        // 后仍会投递）：界面退出（cloud.syncOnUIExit）与完整退出
        // （runtime.stop）都不算「意外消失」。
        if let dictionary = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
           let operation = dictionary["operation"] as? String,
           operation == "cloud.syncOnUIExit" || operation == "runtime.stop" {
            let identity = ObjectIdentifier(connection)
            Task { @MainActor in UIClientExitMonitor.shared.markAnnouncedExit(identity) }
        }
        Task { @MainActor in
            let result = await BackgroundAgentRuntime.shared.perform(bytes)
            reply(result as NSData)
            BackgroundAgentRuntime.shared.completeAcknowledgedCommand()
        }
    }
    func subscribe(_ reply: @escaping @Sendable (NSData) -> Void) {
        Task { @MainActor in
            BackgroundAgentRuntime.shared.subscribe(connection)
            reply(BackgroundAgentRuntime.shared.snapshot() as NSData)
        }
    }
}

/// UI 主进程是否仍在运行。Helper 用它区分「UI 临时断连（会重连）」与
/// 「UI 进程已经消失（强退 / 崩溃）」——只有后者才触发 Helper 收尾自退。
@MainActor
private enum HostUIProcessProbe {
    static func hostUIProcessIsRunning() -> Bool {
        let executable = WaifuXHostBundle.bundleURL
            .appendingPathComponent("Contents/MacOS/WaifuX")
            .resolvingSymlinksInPath()
        var pidBuffer = [Int32](repeating: 0, count: 8192)
        let count = proc_listallpids(&pidBuffer, Int32(pidBuffer.count))
        guard count > 0 else { return false }
        for pid in pidBuffer[..<Int(count)] where pid > 0 && pid != getpid() {
            var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 else { continue }
            if URL(fileURLWithPath: String(cString: pathBuffer)).resolvingSymlinksInPath() == executable {
                return true
            }
        }
        return false
    }
}

/// UI 客户端「未告别即消失」监测。UI 正常退出都会先发告别命令：
/// 关窗口/界面退出 = `cloud.syncOnUIExit`，完整退出 = `runtime.stop`，
/// 升级 = `prepareForUpgrade`。没有告别而连接失效，且 UI 主进程确实
/// 不在进程表里（强退 / 崩溃），Helper 就收尾 worker 并退出——不能让
/// 渲染器与后台服务在用户强退主程序后继续留在桌面上。
@MainActor
private final class UIClientExitMonitor {
    static let shared = UIClientExitMonitor()
    /// connection identity → 是否已收到告别命令。
    private var announcedExits: [ObjectIdentifier: Bool] = [:]
    private var exitCheckTask: Task<Void, Never>?

    func connectionAccepted(_ identity: ObjectIdentifier) {
        announcedExits[identity] = false
        // 新连接取消挂起的自退检查（UI 退出后立刻重启的场景）。
        exitCheckTask?.cancel()
        exitCheckTask = nil
    }

    func markAnnouncedExit(_ identity: ObjectIdentifier) {
        if announcedExits[identity] != nil { announcedExits[identity] = true }
    }

    func connectionInvalidated(_ identity: ObjectIdentifier) {
        let announced = announcedExits.removeValue(forKey: identity) ?? false
        guard !BackgroundRuntimeRole.isIsolatedTest, !announced, announcedExits.isEmpty else { return }
        exitCheckTask?.cancel()
        exitCheckTask = Task { @MainActor in
            // 缓冲窗口：覆盖「连接刚失效、UI 立刻重连」与进程表抖动。
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, announcedExits.isEmpty else { return }
            // UI 进程还活着 = 只是断连（重连/修复中），保持现有语义。
            guard !HostUIProcessProbe.hostUIProcessIsRunning() else { return }
            AppLogger.error(.general, "UI 进程未告别即消失（强退/崩溃），Helper 收尾 worker 并退出", metadata: [:])
            await BackgroundAgentRuntime.shared.stopAll()
        }
    }
}

private final class AgentConnectionListener: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == getuid(), trustedClient(connection) else { return false }
        connection.exportedInterface = NSXPCInterface(with: BackgroundAgentXPC.self)
        connection.remoteObjectInterface = NSXPCInterface(with: BackgroundAgentObserver.self)
        connection.exportedObject = AgentEndpoint(connection: connection)
        let identity = ObjectIdentifier(connection)
        Task { @MainActor in UIClientExitMonitor.shared.connectionAccepted(identity) }
        connection.invalidationHandler = { @Sendable in
            Task { @MainActor in
                BackgroundAgentRuntime.shared.unsubscribe(identity)
                UIClientExitMonitor.shared.connectionInvalidated(identity)
            }
        }
        connection.resume()
        return true
    }

    private func trustedClient(_ connection: NSXPCConnection) -> Bool {
        #if DEBUG
        if BackgroundRuntimeRole.isIsolatedTest { return true }
        // Development builds can be unsigned. Still require the exact host executable.
        var path = [CChar](repeating: 0, count: 4096)
        if proc_pidpath(connection.processIdentifier, &path, UInt32(path.count)) > 0,
           let expected = Bundle(url: WaifuXHostBundle.bundleURL)?.executableURL {
            return URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath() == expected.resolvingSymlinksInPath()
        }
        return false
        #else
        var guest: SecCode?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: connection.processIdentifier)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest) == errSecSuccess, let guest else { return false }
        var own: SecCode?
        guard SecCodeCopySelf([], &own) == errSecSuccess, let own else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(own, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String else { return false }
        let text = "identifier \"com.waifux.app\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else { return false }
        return SecCodeCheckValidity(guest, [], requirement) == errSecSuccess
        #endif
    }
}

@MainActor
private final class AgentApplicationDelegate: NSObject, NSApplicationDelegate {
    private let connectionListener = AgentConnectionListener()
    private var xpcListener: NSXPCListener?
    private var instanceLock: Int32 = -1

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = WaifuXHostBundle.bundleURL
        let directory: URL
        if BackgroundRuntimeRole.isIsolatedTest {
            guard let root = ProcessInfo.processInfo.environment["WAIFUX_HELPER_TEST_ROOT"],
                  !root.isEmpty else { exit(2) }
            directory = URL(fileURLWithPath: root).appendingPathComponent("HelperRuntime", isDirectory: true)
        } else {
            directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("WaifuX")
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suffix = BackgroundRuntimeRole.isIsolatedTest ? ".test" : ""
        instanceLock = open(directory.appendingPathComponent("background-helper\(suffix).lock").path, O_CREAT | O_RDWR, 0o600)
        guard instanceLock >= 0, flock(instanceLock, LOCK_EX | LOCK_NB) == 0 else { exit(0) }
        let listener = NSXPCListener(machServiceName: ProcessInfo.processInfo.environment["WAIFUX_HELPER_TEST_SERVICE"] ?? BackgroundAgentWire.machServiceName)
        listener.delegate = connectionListener
        listener.resume()
        xpcListener = listener
        Task { await BackgroundAgentRuntime.shared.startAtLoginIfNeeded() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        BackgroundAgentRuntime.shared.prepareForTermination()
        BackgroundAgentRuntime.shared.finishProcessExit()
        if instanceLock >= 0 { close(instanceLock) }
    }
}

@main
private enum AgentMain {
    @MainActor static func main() {
        signal(SIGPIPE, SIG_IGN)
        if CommandLine.arguments.contains("--host-bundle-probe") { print(WaifuXHostBundle.bundleURL.path); return }
        if CommandLine.arguments.contains("--identity-probe") {
            let status = BackgroundAgentHello(protocolVersion: BackgroundAgentWire.protocolVersion, bundleIdentifier: Bundle.main.bundleIdentifier ?? "", processIdentifier: ProcessInfo.processInfo.processIdentifier, runtimeReady: false, buildIdentity: BackgroundAgentBuildIdentity.running())
            if let data = try? JSONEncoder().encode(status), let line = String(data: data, encoding: .utf8) { print(line) }
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AgentApplicationDelegate()
        app.delegate = delegate
        app.run()
    }
}
#endif
