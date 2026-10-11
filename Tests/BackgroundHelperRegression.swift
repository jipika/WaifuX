import AppKit
import Foundation

private final class Observer: NSObject, BackgroundAgentObserver, @unchecked Sendable {
    func snapshotChanged(_ data: NSData) {}
    func openUI(_ action: String) {}
}

@main struct HelperRegression {
    private static let observer = Observer()
    static var connection: NSXPCConnection!
    static func check(_ passed: Bool, _ message: String) throws {
        guard passed else { throw NSError(domain: "HelperRegression", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        print("PASS \(message)")
    }
    static func rpc(_ operation: String, _ arguments: [String: Any] = [:], requestID: String = UUID().uuidString) async throws -> [String: Any] {
        let command = BackgroundAgentCommand(operation: operation, arguments: try BackgroundPropertyList.encode(arguments), requestID: requestID)
        let bytes = try JSONEncoder().encode(command)
        let result: Data = try await withCheckedThrowingContinuation { continuation in
            let proxy = connection.remoteObjectProxyWithErrorHandler { continuation.resume(throwing: $0) } as! BackgroundAgentXPC
            proxy.perform(bytes as NSData) { continuation.resume(returning: $0 as Data) }
        }
        let reply = try JSONDecoder().decode(BackgroundAgentReply.self, from: result)
        guard reply.requestID == requestID else { throw CocoaError(.coderInvalidValue) }
        if let error = reply.error { throw NSError(domain: "HelperRegression", code: 2, userInfo: [NSLocalizedDescriptionKey: error]) }
        return try BackgroundPropertyList.decode(reply.result ?? Data())
    }
    static func hello() async throws -> BackgroundAgentHello {
        let result: Data = try await withCheckedThrowingContinuation { continuation in
            let proxy = connection.remoteObjectProxyWithErrorHandler { continuation.resume(throwing: $0) } as! BackgroundAgentXPC
            proxy.hello { continuation.resume(returning: $0 as Data) }
        }
        return try JSONDecoder().decode(BackgroundAgentHello.self, from: result)
    }
    static func video(_ values: [String: Any]) throws -> [String: Any] {
        try BackgroundPropertyList.decode(values["snapshot"] as! Data)["video"] as! [String: Any]
    }
    static func main() async {
        do {
            let arguments = CommandLine.arguments
            let service = arguments[1]
            let fixture = URL(fileURLWithPath: arguments[2])
            connection = NSXPCConnection(machServiceName: service)
            connection.remoteObjectInterface = NSXPCInterface(with: BackgroundAgentXPC.self)
            connection.exportedInterface = NSXPCInterface(with: BackgroundAgentObserver.self)
            connection.exportedObject = observer
            connection.resume()
            let identity = try await hello()
            try check(identity.buildIdentity == BackgroundAgentBuildIdentity.executable(URL(fileURLWithPath: arguments[3])), "loaded Helper matches embedded executable UUID")
            let preferences: [String: Any] = ["system_wallpaper_sync_enabled": false, "dynamic_lock_screen_enabled": false, "external_video_renderer_enabled": false, "wallpaper_transition_animation_enabled": false, "pause_when_other_app_foreground": false, "pause_when_fullscreen_covers": false, "pause_when_window_coverage": false]
            var state = try await rpc("bootstrap", ["preferences": preferences])
            let snapshot = try BackgroundPropertyList.decode(state["snapshot"] as! Data)
            try check(snapshot["ready"] as? Bool == true, "independent Helper runtime starts")
            print("HELPER_PID \(snapshot["pid"]!)")
            let writer = UUID().uuidString
            let initialAppearance = snapshot["appearance"] as? [String: Any] ?? [:]
            try check(initialAppearance["appearance"] as? String == "NSAppearanceNameDarkAqua", "Helper restores default dark appearance before presenting menus")
            for (sequence, mode, appearance) in [(1, "浅色", "NSAppearanceNameAqua"), (2, "深色", "NSAppearanceNameDarkAqua"), (3, "跟随系统", "system")] {
                let mutation = try BackgroundPropertyList.encode(["key": "theme_mode", "writerID": writer, "sequence": sequence, "value": mode, "removed": false])
                let result = try await rpc("preferences.set", ["mutation": mutation])
                let theme = try BackgroundPropertyList.decode(result["snapshot"] as! Data)["appearance"] as? [String: Any] ?? [:]
                try check(theme["mode"] as? String == mode && theme["appearance"] as? String == appearance, "preference RPC updates Helper appearance to \(mode)")
            }
            for sequence in [2, 1, 3] {
                let mutation = try BackgroundPropertyList.encode(["key": "regression_key", "writerID": writer, "sequence": sequence, "value": sequence, "removed": false])
                let result = try await rpc("preferences.set", ["mutation": mutation])
                try check((result["sequence"] as? NSNumber)?.intValue == sequence, "preference acknowledgement \(sequence)")
            }
            let ordered = try await rpc("test.preference", ["key": "regression_key"])
            try check((ordered["value"] as? NSNumber)?.intValue == 3, "out-of-order preferences cannot overwrite latest value")
            let source = fixture.deletingLastPathComponent().appendingPathComponent("migration-source")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            let original = source.appendingPathComponent("probe.txt")
            try Data("preserve".utf8).write(to: original)
            let migration = try await rpc("directory.migrate.wait", ["old": source.absoluteString, "new": source.appendingPathComponent("nested").absoluteString])
            let result = try JSONSerialization.jsonObject(with: migration["result"] as! Data) as! [String: Any]
            try check(result["failure"] != nil && FileManager.default.fileExists(atPath: original.path), "nested directory migration is rejected before touching files")
            async let assetsA = rpc("assets.prepare.wait")
            async let assetsB = rpc("assets.prepare.wait")
            let assets = try await (assetsA, assetsB)
            let rootA = try JSONDecoder().decode(String.self, from: assets.0["root"] as! Data)
            let rootB = try JSONDecoder().decode(String.self, from: assets.1["root"] as! Data)
            try check(rootA == rootB && rootA.hasPrefix(fixture.deletingLastPathComponent().path + "/") && FileManager.default.fileExists(atPath: rootA + "/materials"), "concurrent scene assets prepare in isolated cache")
            let waitID = UUID().uuidString
            async let firstWait = rpc("test.delay.wait", requestID: waitID)
            async let duplicateWait = rpc("test.delay.wait", requestID: waitID)
            let controls = try await rpc("test.snapshot")
            try check(controls["snapshot"] is Data, "long task does not block playback controls")
            let waitResults = try await (firstWait, duplicateWait)
            try check((waitResults.0["count"] as? NSNumber)?.intValue == 1 && (waitResults.1["count"] as? NSNumber)?.intValue == 1, "concurrent duplicate long task executes once")
            do { _ = try await rpc("unknown.operation"); throw CocoaError(.coderInvalidValue) }
            catch let error as NSError { try check(error.code == 2, "unknown command returns a recoverable error") }
            do { _ = try await rpc("video.apply", ["url": fixture.absoluteString, "screens": ["missing-display"], "muted": true]); throw CocoaError(.coderInvalidValue) }
            catch let error as NSError { try check(error.code == 2, "disconnected target never falls back to all displays") }
            state = try await rpc("video.apply", ["url": fixture.absoluteString, "muted": true])
            var values = try video(state)
            try check(values["external"] as? Bool == false && (values["nativePlayerCount"] as? Int ?? 0) > 0 && (values["nativeWindowCount"] as? Int ?? 0) > 0, "default AVPlayer remains inside Helper")
            try check(!(values["active"] as? [String] ?? []).isEmpty, "native video owns active displays")
            state = try await rpc("video.pause", ["persistAsUserRequest": true])
            values = try video(state)
            try check(values["paused"] as? Bool == true, "native pause acknowledged")
            _ = try await rpc("test.event", ["event": "displaySleep"])
            _ = try await rpc("test.event", ["event": "displayWake"])
            try await Task.sleep(for: .seconds(2))
            state = try await rpc("test.snapshot")
            try check(try video(state)["paused"] as? Bool == true, "manual pause survives display sleep and wake")
            state = try await rpc("video.resume", ["persistAsUserRequest": true])
            try check(try video(state)["paused"] as? Bool == false, "native resume acknowledged")
            let repeatID = UUID().uuidString
            _ = try await rpc("video.muted", ["muted": false], requestID: repeatID)
            state = try await rpc("video.muted", ["muted": true], requestID: repeatID)
            try check(try video(state)["muted"] as? Bool == false, "duplicate request is executed once")
            _ = try await rpc("video.stopNative")
            state = try await rpc("video.apply", ["url": fixture.absoluteString, "muted": true])
            connection.invalidate()
            connection = nil
            try await Task.sleep(for: .seconds(2))
            connection = NSXPCConnection(machServiceName: service)
            connection.remoteObjectInterface = NSXPCInterface(with: BackgroundAgentXPC.self)
            connection.exportedInterface = NSXPCInterface(with: BackgroundAgentObserver.self)
            connection.exportedObject = observer
            connection.resume()
            state = try await rpc("bootstrap")
            try check(!(try video(state)["active"] as? [String] ?? []).isEmpty, "video survives UI connection loss")
            _ = try await rpc("video.stopNative")
            state = try await rpc("video.setExternal", ["enabled": true])
            state = try await rpc("video.apply", ["url": fixture.absoluteString, "muted": true])
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/ps")
            process.arguments = ["-axo", "ppid,command"]
            process.standardOutput = pipe
            try process.run()
            let children = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            let childFound = children.split(separator: "\n").contains { line in line.trimmingCharacters(in: .whitespaces).hasPrefix("\(identity.processIdentifier) ") && line.contains("wallpaper-video-renderer") }
            try check(try video(state)["external"] as? Bool == true && childFound, "Beta renderer is a child of Helper")
            state = try await rpc("video.pause", ["persistAsUserRequest": true])
            try check(try video(state)["paused"] as? Bool == true, "Beta renderer pause acknowledged")
            _ = try await rpc("test.event", ["event": "displaySleep"])
            _ = try await rpc("test.event", ["event": "displayWake"])
            try await Task.sleep(for: .seconds(2))
            state = try await rpc("test.snapshot")
            try check(try video(state)["paused"] as? Bool == true, "Beta manual pause survives display sleep and wake")
            state = try await rpc("video.resume", ["persistAsUserRequest": true])
            try check(try video(state)["paused"] as? Bool == false, "Beta renderer resume acknowledged")
            _ = try await rpc("video.stopNative")
            let beforeUpgrade = try await hello()
            let _: Data = try await withCheckedThrowingContinuation { continuation in
                let proxy = connection.remoteObjectProxyWithErrorHandler { continuation.resume(throwing: $0) } as! BackgroundAgentXPC
                proxy.prepareForUpgrade { continuation.resume(returning: $0 as Data) }
            }
            connection.invalidate()
            try await Task.sleep(for: .seconds(11))
            connection = NSXPCConnection(machServiceName: service)
            connection.remoteObjectInterface = NSXPCInterface(with: BackgroundAgentXPC.self)
            connection.resume()
            let afterUpgrade = try await hello()
            try check(beforeUpgrade.processIdentifier != afterUpgrade.processIdentifier, "launchd restarts Helper after acknowledged upgrade")
            let saved = try await rpc("test.preference", ["key": "regression_key"])
            try check((saved["value"] as? NSNumber)?.intValue == 3, "upgrade preserves acknowledged settings")
            _ = try await rpc("bootstrap")
            _ = try await rpc("runtime.stop")
            connection.invalidate()
            print("BACKGROUND_HELPER_REGRESSION_PASSED")
        } catch {
            fputs("FAIL \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
