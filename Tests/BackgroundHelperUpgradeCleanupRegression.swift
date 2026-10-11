import AppKit
import Darwin

@MainActor
private final class DetachedBakeWorkerDelegate: NSObject, NSApplicationDelegate {
    private var child: Process?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try! process.run()
        child = process
        // A killed/timed-out driver must not leave this launchd-owned fixture
        // behind indefinitely. This is a test-only upper bound, not cleanup
        // that could make the two-second production teardown check pass.
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) { exit(0) }
    }
}

@main
struct HelperUpgradeCleanupRegression {
    static var connection: NSXPCConnection!
    struct Worker {
        let pid: Int32
        let seconds: UInt64
        let microseconds: UInt64
        func cleanup() {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
               info.pbi_uid == getuid(), info.pbi_start_tvsec == seconds,
               info.pbi_start_tvusec == microseconds { kill(pid, SIGKILL) }
        }
    }
    static func workers(_ parent: Int32) -> [Worker] {
        var pids = [Int32](repeating: 0, count: 256)
        let count = pids.withUnsafeMutableBytes { proc_listchildpids(parent, $0.baseAddress, Int32($0.count)) }
        return pids.prefix(max(0, min(Int(count), pids.count))).flatMap { pid -> [Worker] in
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard pid > 1, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
                  info.pbi_ppid == UInt32(parent), info.pbi_uid == getuid() else { return [] }
            return workers(pid) + [Worker(pid: pid, seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)]
        }
    }
    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw NSError(domain: "UpgradeCleanupRegression", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        print("PASS \(message)")
        fflush(stdout)
    }
    static func connect(_ service: String) {
        connection = NSXPCConnection(machServiceName: service)
        connection.remoteObjectInterface = NSXPCInterface(with: BackgroundAgentXPC.self)
        connection.resume()
    }
    static func hello() async throws -> BackgroundAgentHello {
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            let proxy = connection.remoteObjectProxyWithErrorHandler { continuation.resume(throwing: $0) } as! BackgroundAgentXPC
            proxy.hello { continuation.resume(returning: $0 as Data) }
        }
        return try JSONDecoder().decode(BackgroundAgentHello.self, from: data)
    }
    static func rpc(_ operation: String, _ arguments: [String: Any] = [:]) async throws -> [String: Any] {
        let command = BackgroundAgentCommand(operation: operation, arguments: try BackgroundPropertyList.encode(arguments))
        let data = try JSONEncoder().encode(command)
        let result: Data = try await withCheckedThrowingContinuation { continuation in
            let proxy = connection.remoteObjectProxyWithErrorHandler { continuation.resume(throwing: $0) } as! BackgroundAgentXPC
            proxy.perform(data as NSData) { continuation.resume(returning: $0 as Data) }
        }
        let reply = try JSONDecoder().decode(BackgroundAgentReply.self, from: result)
        if let error = reply.error { throw NSError(domain: "UpgradeCleanupRegression", code: 2, userInfo: [NSLocalizedDescriptionKey: error]) }
        return try BackgroundPropertyList.decode(reply.result ?? Data())
    }
    @MainActor static func main() {
        if CommandLine.arguments.contains("--detached-bake-worker") {
            signal(SIGTERM, SIG_IGN)
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let delegate = DetachedBakeWorkerDelegate()
            app.delegate = delegate
            withExtendedLifetime(delegate) { app.run() }
            return
        }
        Task { await runRegression(); exit(0) }
        dispatchMain()
    }

    static func runRegression() async {
        do {
            let args = CommandLine.arguments
            connect(args[1])
            _ = try await rpc("bootstrap", ["preferences": ["system_wallpaper_sync_enabled": false, "dynamic_lock_screen_enabled": false, "external_video_renderer_enabled": false]])
            let original = try await hello().processIdentifier
            let marker = UUID().uuidString
            let mutation = try BackgroundPropertyList.encode(["key": "background_helper_active_session_v1", "value": marker, "writerID": UUID().uuidString, "sequence": 1, "removed": false])
            _ = try await rpc("preferences.set", ["mutation": mutation])
            _ = try await rpc("video.apply", ["url": URL(fileURLWithPath: args[2]).absoluteString, "muted": true])
            _ = try await rpc("test.spawnChild")
            _ = try await rpc("test.spawnChild", ["nested": true, "paused": true])
            var children = workers(original)
            if CommandLine.arguments.last == "detached-upgrade" {
                let result = try await rpc("test.spawnDetachedBake", ["paused": true, "cancel": true,
                    "executable": URL(fileURLWithPath: CommandLine.arguments[0]).absoluteString])
                let pid = (result["pid"] as! NSNumber).int32Value
                var info = proc_bsdinfo()
                let size = Int32(MemoryLayout<proc_bsdinfo>.size)
                try check(proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size && info.pbi_ppid != UInt32(original), "real NSWorkspace bake wrapper is outside the Helper child tree")
                children += workers(pid) + [Worker(pid: pid, seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)]
            }
            defer { children.forEach { $0.cleanup() } }
            try check(children.count >= 3, "upgrade has real ordinary and suspended nested workers")
            let _: Data = try await withCheckedThrowingContinuation { continuation in
                let proxy = connection.remoteObjectProxyWithErrorHandler { continuation.resume(throwing: $0) } as! BackgroundAgentXPC
                proxy.prepareForUpgrade { continuation.resume(returning: $0 as Data) }
            }
            connection.invalidate()
            try await Task.sleep(for: .seconds(2))
            try check(kill(original, 0) != 0, "acknowledged old Helper exits during upgrade")
            try check(children.allSatisfy { kill($0.pid, 0) != 0 }, "upgrade leaves no ordinary or suspended nested workers")
            try await Task.sleep(for: .seconds(9))
            connect(args[1])
            let replacement = try await hello()
            try check(replacement.processIdentifier != original, "launchd starts replacement Helper")
            let preferences = UserDefaults(suiteName: ProcessInfo.processInfo.environment["WAIFUX_HELPER_TEST_SUITE"]!)!
            preferences.synchronize()
            try check(preferences.string(forKey: "background_helper_active_session_v1") == marker, "upgrade preserves the active-session marker")
            let saved = try JSONSerialization.jsonObject(with: preferences.data(forKey: "video_wallpaper_state_v1") ?? Data()) as! [String: Any]
            try check(saved["fileURL"] as? String == URL(fileURLWithPath: args[2]).absoluteString, "upgrade preserves desired wallpaper")
            _ = try await rpc("bootstrap")
            _ = try await rpc("runtime.stop")
            connection.invalidate()
            print("BACKGROUND_HELPER_UPGRADE_CLEANUP_PASSED")
        } catch { fputs("FAIL \(error.localizedDescription)\n", stderr); exit(1) }
    }
}
