import AppKit
import Foundation
import Darwin

/// Drives the production UI client and AppKit delegate with a private Mach job.
/// Checkpoints delay only this UI's control task; production Helper is untouched.
@main @MainActor struct HelperClientLifecycleRegression {
    static var connection: NSXPCConnection!

    static func check(_ value: Bool, _ message: String) throws {
        guard value else { throw NSError(domain: "HelperClientLifecycle", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]) }
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

    static func preference(_ key: String) async throws -> Any? {
        let command = BackgroundAgentCommand(operation: "test.preference",
            arguments: try BackgroundPropertyList.encode(["key": key]))
        let payload = try JSONEncoder().encode(command)
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            let proxy = connection.remoteObjectProxyWithErrorHandler { continuation.resume(throwing: $0) } as! BackgroundAgentXPC
            proxy.perform(payload as NSData) { continuation.resume(returning: $0 as Data) }
        }
        let reply = try JSONDecoder().decode(BackgroundAgentReply.self, from: data)
        if let error = reply.error { throw NSError(domain: "HelperClientLifecycle", code: 2, userInfo: [NSLocalizedDescriptionKey: error]) }
        return try BackgroundPropertyList.decode(reply.result ?? Data())["value"]
    }

    static func wait(until condition: () -> Bool) async throws {
        for _ in 0..<600 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "HelperClientLifecycle", code: 3, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for isolated UI checkpoint"])
    }

    static func jobHasPID(_ service: String) throws -> Bool {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "gui/\(getuid())/\(service)"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return text.range(of: "(?m)^\\s*pid = [0-9]+", options: .regularExpression) != nil
    }

    static func run(service: String, helper: URL, scenario: String) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard service.hasPrefix("com.waifux.test.helper."),
              environment["WAIFUX_HELPER_TEST_SUITE"] == service + ".preferences",
              let root = environment["WAIFUX_HELPER_TEST_ROOT"],
              ["startup-quit", "reconnect-replay", "reconnect-quit", "acknowledged-stop-quit", "reset-preflight", "reset-timeout"].contains(scenario) else {
            throw CocoaError(.featureUnsupported)
        }
        let directory = URL(fileURLWithPath: root)
        connect(service)
        let original = try await hello().processIdentifier
        var contents = helper
        for _ in 0..<5 { contents.deleteLastPathComponent() }
        let ui = contents.appendingPathComponent("MacOS/WaifuX")
        try check(FileManager.default.fileExists(atPath: contents.appendingPathComponent("MacOS/WaifuX.debug.dylib").path), "lifecycle fault injection uses a Debug UI")
        let log = directory.appendingPathComponent("client-lifecycle-ui.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        let process = Process()
        process.executableURL = ui
        process.arguments = ["--helper-ui-exit-probe"]
        let value = scenario + "." + UUID().uuidString
        var uiEnvironment = environment
        uiEnvironment["WAIFUX_UI_CLIENT_PROBE_SCENARIO"] = scenario
        uiEnvironment["WAIFUX_UI_EXIT_PROBE_VALUE"] = value
        let usesCheckpoint = ["startup-quit", "reconnect-replay", "reconnect-quit"].contains(scenario)
        if usesCheckpoint {
            uiEnvironment["WAIFUX_UI_CLIENT_PROBE_CHECKPOINT"] = scenario == "startup-quit" ? "startup.identified" : "reconnect.identified"
        }
        process.environment = uiEnvironment
        process.standardOutput = output
        process.standardError = output
        try process.run()
        defer {
            if process.isRunning { process.terminate(); process.waitUntilExit() }
            try? output.close()
            connection?.invalidate()
        }
        if usesCheckpoint {
            try await wait { FileManager.default.fileExists(atPath: directory.appendingPathComponent("client.ready").path) || !process.isRunning }
            try check(process.isRunning, "UI reaches the controlled \(scenario) checkpoint")
            if scenario == "reconnect-replay" {
                try Data().write(to: directory.appendingPathComponent("reconnect.identified.release"))
            } else {
                // Remove the driver's connection before quitting; no later
                // Mach request is made, so it cannot accidentally restart a job.
                connection.invalidate()
                try Data().write(to: directory.appendingPathComponent("client.quit.request"))
                if scenario == "startup-quit" {
                    try await Task.sleep(for: .milliseconds(250))
                    try check(process.isRunning, "Cmd+Q drains admitted startup instead of terminating underneath it")
                    try Data().write(to: directory.appendingPathComponent("startup.identified.release"))
                }
                // reconnect-quit deliberately leaves its checkpoint unreleased.
                // A cancelled reconnect must not hold up or restart full quit.
            }
        } else {
            connection.invalidate()
        }
        try await wait { !process.isRunning }
        let proof = try String(contentsOf: log, encoding: .utf8)
        print("CLIENT_LIFECYCLE_UI scenario=\(scenario) status=\(process.terminationStatus)\n\(proof)")
        try check(process.terminationStatus == 0 && proof.contains("UI_APPKIT_EXIT_PROBE_PASSED"), "\(scenario) completes the real AppKit delegate exit")
        if scenario == "reconnect-replay" {
            try check(proof.contains("UI_CLIENT_REPLAY_PASSED"), "automatic reconnect commits latest preferences, ACKs the overlay and ignores old callbacks")
            try check(try await hello().processIdentifier == original, "UI-only close keeps the original Helper")
            try check(try await preference("regression_client_latest") as? String == value, "replayed preference is durable after UI closes")
        } else {
            try check(kill(original, 0) != 0 && errno == ESRCH, "full quit ends the originally acknowledged Helper PID")
            let preferences = UserDefaults(suiteName: service + ".preferences")!
            preferences.synchronize()
            if scenario == "reset-preflight" {
                try check(preferences.string(forKey: "regression_client_latest") == nil && proof.contains("UI_RESET_PREFLIGHT_PASSED"), "successful reset clears the actual isolated shared domain before AppKit quits")
            } else {
                try check(preferences.string(forKey: "regression_client_latest") == value, "full quit preserves the latest unacknowledged preference")
            }
            if scenario == "reset-timeout" {
                try check(proof.contains("UI_RESET_TIMEOUT_PASSED"), "production reset preflight deadline refuses deletion and preserves settings before retry")
            }
            if scenario.hasPrefix("reset-") {
                try check(try String(contentsOf: directory.appendingPathComponent("reset-sentinel.txt"), encoding: .utf8) == value, "isolated reset probe preserves its file sentinel and does not call production cache deletion")
            }
            if scenario == "startup-quit" {
                try check(preferences.string(forKey: "regression_client_queued") == value, "full quit acknowledges the command admitted before startup completed")
            }
            if scenario == "acknowledged-stop-quit" {
                try check(proof.contains("UI_CLIENT_STOP_ACKNOWLEDGED"), "a caller can acknowledge Helper exit before NSApp.terminate")
            }
            try check(try !jobHasPID(service), "successful Helper job remains registered without a running PID")
            try await Task.sleep(for: .seconds(11))
            try check(try !jobHasPID(service), "cancelled startup/reconnect and repeated quit do not revive Helper after launchd throttle")
        }
    }

    static func main() async {
        do {
            guard CommandLine.arguments.count == 5 else { throw CocoaError(.coderInvalidValue) }
            try await run(service: CommandLine.arguments[1], helper: URL(fileURLWithPath: CommandLine.arguments[3]), scenario: CommandLine.arguments[4])
        } catch {
            fputs("CLIENT_LIFECYCLE_REGRESSION_FAILED \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
