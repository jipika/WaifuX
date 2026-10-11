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

private final class AgentConnectionListener: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == getuid(), trustedClient(connection) else { return false }
        connection.exportedInterface = NSXPCInterface(with: BackgroundAgentXPC.self)
        connection.remoteObjectInterface = NSXPCInterface(with: BackgroundAgentObserver.self)
        connection.exportedObject = AgentEndpoint(connection: connection)
        let identity = ObjectIdentifier(connection)
        connection.invalidationHandler = { @Sendable in
            Task { @MainActor in BackgroundAgentRuntime.shared.unsubscribe(identity) }
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
