import AppKit
import Foundation
import Darwin

@main struct HelperWorkflowRegression {
    static var connection: NSXPCConnection!
    static func check(_ passed: Bool, _ message: String) throws {
        guard passed else { throw NSError(domain: "HelperWorkflow", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        print("PASS \(message)")
        fflush(stdout)
    }
    static func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]) }
    static func rpc(_ operation: String, _ arguments: [String: Any] = [:]) async throws -> [String: Any] {
        let command = BackgroundAgentCommand(operation: operation, arguments: try BackgroundPropertyList.encode(arguments), requestID: UUID().uuidString)
        let bytes = try JSONEncoder().encode(command)
        let result: Data = try await withCheckedThrowingContinuation { continuation in
            let proxy = connection.remoteObjectProxyWithErrorHandler { continuation.resume(throwing: $0) } as! BackgroundAgentXPC
            proxy.perform(bytes as NSData) { continuation.resume(returning: $0 as Data) }
        }
        let reply = try JSONDecoder().decode(BackgroundAgentReply.self, from: result)
        if let error = reply.error { throw NSError(domain: "HelperWorkflow", code: 2, userInfo: [NSLocalizedDescriptionKey: error]) }
        return try BackgroundPropertyList.decode(reply.result ?? Data())
    }
    static func records(_ kind: String) async throws -> [[String: Any]] {
        let library = try await rpc("library.snapshot")
        let media = try BackgroundPropertyList.decode(library["media"] as! Data)
        return try JSONSerialization.jsonObject(with: media[kind] as! Data) as! [[String: Any]]
    }
    static func video(_ state: [String: Any]) throws -> [String: Any] {
        try BackgroundPropertyList.decode(state["snapshot"] as! Data)["video"] as! [String: Any]
    }
    static func item(_ id: String, file: URL) -> [String: Any] {
        ["id": id, "slug": id, "title": id, "pageURL": file.absoluteString,
         "thumbnailURL": file.absoluteString, "previewVideoURL": file.absoluteString,
         "resolutionLabel": "640x360", "tags": [], "downloadOptions": [], "sourceName": "Regression"]
    }
    static func setPreference(_ key: String, value: Any) async throws {
        let mutation = try BackgroundPropertyList.encode(["key": key, "value": value, "removed": false, "writerID": UUID().uuidString, "sequence": 1])
        _ = try await rpc("preferences.set", ["mutation": mutation])
    }
    static func recovery(root: URL, fixture: URL) async throws {
        let oldRoot = root.appendingPathComponent("recovery-source")
        let newRoot = root.appendingPathComponent("recovery-destination")
        let sourceFile = oldRoot.appendingPathComponent("Media/fixture.mp4")
        try FileManager.default.createDirectory(at: sourceFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture, to: sourceFile)
        let checkpoint = try json(["phase": "deleting", "oldPath": oldRoot.path, "newPath": newRoot.path, "copiedFileCount": 1])
        try await setPreference("migration_state_v1", value: checkpoint)
        _ = try await rpc("test.migrationRecover.wait")
        try check(FileManager.default.fileExists(atPath: sourceFile.path), "deletion recovery preserves source when destination is missing")
        let saved = try await rpc("test.preference", ["key": "migration_state_v1"])
        try check(saved["value"] is Data, "incomplete deletion keeps its recovery checkpoint")
        let destinationFile = newRoot.appendingPathComponent("Media/fixture.mp4")
        try FileManager.default.createDirectory(at: destinationFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        var changedBytes = try Data(contentsOf: fixture)
        changedBytes[0] ^= 0xff
        try changedBytes.write(to: destinationFile)
        _ = try await rpc("test.migrationRecover.wait")
        try check(FileManager.default.fileExists(atPath: sourceFile.path), "deletion recovery rejects a different copy of the same size")
        try FileManager.default.removeItem(at: destinationFile)
        try FileManager.default.createSymbolicLink(at: destinationFile, withDestinationURL: sourceFile)
        _ = try await rpc("test.migrationRecover.wait")
        try check(FileManager.default.fileExists(atPath: sourceFile.path), "deletion recovery rejects a symlink back to its source")
        try FileManager.default.removeItem(at: destinationFile)
        try FileManager.default.copyItem(at: fixture, to: destinationFile)
        _ = try await rpc("test.migrationRecover.wait")
        try check(!FileManager.default.fileExists(atPath: sourceFile.path) && FileManager.default.fileExists(atPath: destinationFile.path), "verified recovery finishes deleting the old copy")
        let cleared = try await rpc("test.preference", ["key": "migration_state_v1"])
        try check(!(cleared["value"] is Data), "verified recovery clears its checkpoint")
    }
    static func connect(_ service: String) {
        connection = NSXPCConnection(machServiceName: service)
        connection.remoteObjectInterface = NSXPCInterface(with: BackgroundAgentXPC.self)
        connection.resume()
    }
    static func hello() async throws -> BackgroundAgentHello {
        let result: Data = try await withCheckedThrowingContinuation { continuation in
            let proxy = connection.remoteObjectProxyWithErrorHandler { continuation.resume(throwing: $0) } as! BackgroundAgentXPC
            proxy.hello { continuation.resume(returning: $0 as Data) }
        }
        return try JSONDecoder().decode(BackgroundAgentHello.self, from: result)
    }
    static func startupUpgrade(fixture: URL, helper: URL, service: String) async throws {
        let original = try await hello().processIdentifier
        _ = try await rpc("test.staleIdentity")
        var contents = helper
        for _ in 0..<5 { contents.deleteLastPathComponent() }
        let ui = contents.appendingPathComponent("MacOS/WaifuX")
        let log = fixture.deletingLastPathComponent().appendingPathComponent("ui-startup-upgrade.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        let process = Process()
        process.executableURL = ui
        process.arguments = ["--helper-ui-exit-probe"]
        let value = "upgrade-" + UUID().uuidString
        var environment = ProcessInfo.processInfo.environment
        environment["WAIFUX_UI_EXIT_PROBE_VALUE"] = value
        process.environment = environment
        process.standardOutput = output
        process.standardError = output
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { _ in continuation.resume() }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        try output.close()
        let proof = try String(contentsOf: log, encoding: .utf8)
        print("UI_STARTUP_UPGRADE status=\(process.terminationStatus)\n\(proof)")
        try check(process.terminationStatus == 0 && proof.contains("UI_APPKIT_EXIT_PROBE_PASSED"), "real UI client finishes startup across Helper replacement without a competing reconnect")
        connection.invalidate()
        connect(service)
        let identity = try await hello()
        try check(identity.processIdentifier != original && identity.runtimeReady, "startup replacement yields a new ready Helper PID")
        try check(identity.buildIdentity == BackgroundAgentBuildIdentity.executable(helper), "replacement Helper code matches both embedded Debug images")
        let saved = try await rpc("test.preference", ["key": "regression_ui_exit_ack"])
        try check(saved["value"] as? String == value, "UI command queue remains usable after automatic Helper upgrade")
    }

    static func fullQuit(fixture: URL, helper: URL, service: String) async throws {
        var contents = helper
        for _ in 0..<5 { contents.deleteLastPathComponent() }
        let ui = contents.appendingPathComponent("MacOS/WaifuX")
        let suite = ProcessInfo.processInfo.environment["WAIFUX_HELPER_TEST_SUITE"]!
        let unrelated = Process()
        unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep")
        unrelated.arguments = ["120"]
        try unrelated.run()
        defer { if unrelated.isRunning { unrelated.terminate(); unrelated.waitUntilExit() } }
        func pids(_ parent: Int32) -> [Int32] {
            var list = [Int32](repeating: 0, count: 512)
            let count = list.withUnsafeMutableBytes { proc_listchildpids(parent, $0.baseAddress, Int32($0.count)) }
            return count > 0 ? Array(list.prefix(min(Int(count), list.count))).filter { $0 > 1 } : []
        }
        func descendants(_ parent: Int32) -> [Int32] {
            pids(parent).flatMap { descendants($0) + [$0] }
        }
        func jobHasPID() throws -> Bool {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["print", "gui/\(getuid())/\(service)"]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            return output.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("pid = ") }
        }
        let actions = ["quit", "main-menu-quit", "terminate", "escalate", "helper-quit", "helper-stopped", "quit"]
        for (cycle, action) in actions.enumerated() {
            if cycle > 0 {
                connection.invalidate()
                connect(service)
                _ = try await rpc("bootstrap")
            }
            _ = try await rpc("video.setExternal", ["enabled": cycle == 0])
            _ = try await rpc("video.apply", ["url": fixture.absoluteString, "muted": true])
            let original = try await hello().processIdentifier
            _ = try await rpc("test.spawnChild")
            _ = try await rpc("test.spawnChild", ["paused": true, "nested": true])
            let children = descendants(original)
            try check(children.count >= 3, "quit cycle \(cycle) has real ordinary, suspended and nested Helper workers")
            let state = try video(await rpc("test.snapshot"))
            try check(cycle == 0 ? state["external"] as? Bool == true : (state["nativeWindowCount"] as? Int ?? 0) > 0,
                      "quit cycle \(cycle) starts an actual \(cycle == 0 ? "Beta" : "native") wallpaper")
            let value = "quit-\(cycle)-" + UUID().uuidString
            let log = fixture.deletingLastPathComponent().appendingPathComponent("ui-full-quit-\(cycle).log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let output = try FileHandle(forWritingTo: log)
            let process = Process()
            process.executableURL = ui
            process.arguments = ["--helper-ui-exit-probe"]
            var environment = ProcessInfo.processInfo.environment
            environment["WAIFUX_UI_EXIT_PROBE_VALUE"] = value
            environment["WAIFUX_UI_EXIT_PROBE_ACTION"] = action
            environment["WAIFUX_UI_QUIT_PROBE_PREVIEW"] = "1"
            if cycle == actions.count - 1 {
                environment["WAIFUX_UI_EXIT_PROBE_UNRESPONSIVE_HELPER"] = "1"
                environment["WAIFUX_UI_QUIT_PROBE_RETRY"] = "1"
            }
            process.environment = environment
            process.standardOutput = output
            process.standardError = output
            let finished = Task {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    process.terminationHandler = { _ in continuation.resume() }
                    do { try process.run() } catch { continuation.resume(throwing: error) }
                }
            }
            if action == "helper-quit" || action == "helper-stopped" {
                var ready = false
                for _ in 0..<100 {
                    if (try? String(contentsOf: log, encoding: .utf8))?.contains("UI_QUIT_PROBE_WAITING_FOR_HELPER") == true { ready = true; break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                try check(ready, "\(action) waits for an open subscribed UI")
                _ = try await rpc(action == "helper-quit" ? "test.menuQuit" : "runtime.stop")
            }
            try await finished.value
            try output.close()
            let proof = try String(contentsOf: log, encoding: .utf8)
            print("FULL_QUIT_CYCLE \(cycle) action=\(action) status=\(process.terminationStatus)\n\(proof)")
            let previewPID = proof.split(separator: "\n").first { $0.hasPrefix("UI_QUIT_PREVIEW_PID=") }.flatMap { Int32($0.dropFirst("UI_QUIT_PREVIEW_PID=".count)) }
            let allWorkers = children + (previewPID.map { [$0] } ?? [])
            try check(process.terminationStatus == 0 && proof.contains("UI_APPKIT_EXIT_PROBE_PASSED"),
                      "\(action) exits the real UI through its production AppKit delegate")
            for _ in 0..<30 {
                if kill(original, 0) != 0 && allWorkers.allSatisfy({ kill($0, 0) != 0 }) { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            try check(kill(original, 0) != 0, "\(action) also exits the acknowledged Helper PID")
            try check(children.allSatisfy { kill($0, 0) != 0 }, "\(action) leaves no captured renderer or ordinary/suspended/nested workers")
            try check(previewPID != nil && kill(previewPID!, 0) != 0, "\(action) also cleans a suspended real ffmpeg worker owned by the UI")
            try check(unrelated.isRunning, "\(action) does not terminate an unrelated client-owned worker")
            let preferences = UserDefaults(suiteName: suite)!
            preferences.synchronize()
            try check(preferences.string(forKey: "regression_ui_exit_ack") == value, "\(action) persists the final UI setting before full exit")
            let saved = try JSONSerialization.jsonObject(with: preferences.data(forKey: "video_wallpaper_state_v1") ?? Data()) as! [String: Any]
            try check(saved["fileURL"] as? String == fixture.absoluteString, "\(action) preserves the selected wallpaper for the next launch")
            try check(try !jobHasPID(), "\(action) leaves the isolated launchd job stopped")
            if cycle == actions.count - 1 {
                try check(proof.contains("UI_QUIT_FAILURE_RETAINS_UI"), "unresponsive full quit keeps the UI until the Helper resumes and retry succeeds")
            }
        }
        // A UI relaunch uses the same explicit interface-only intent as the
        // relauncher, and must preserve a live wallpaper owner.
        connection.invalidate()
        connect(service)
        _ = try await rpc("bootstrap")
        _ = try await rpc("video.setExternal", ["enabled": false])
        _ = try await rpc("video.apply", ["url": fixture.absoluteString, "muted": true])
        let original = try await hello().processIdentifier
        let log = fixture.deletingLastPathComponent().appendingPathComponent("ui-relaunch-interface.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        let process = Process()
        process.executableURL = ui
        process.arguments = ["--helper-ui-exit-probe"]
        var environment = ProcessInfo.processInfo.environment
        environment["WAIFUX_UI_EXIT_PROBE_VALUE"] = "relaunch"
        environment["WAIFUX_UI_EXIT_PROBE_ACTION"] = "relaunch-interface"
        process.environment = environment
        process.standardOutput = output
        process.standardError = output
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { _ in continuation.resume() }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        try output.close()
        try check(process.terminationStatus == 0, "interface relaunch exits its UI successfully")
        try check(try await hello().processIdentifier == original, "interface relaunch preserves the same Helper PID")
        try check(try video(await rpc("test.snapshot"))["nativeWindowCount"] as? Int ?? 0 > 0, "interface relaunch preserves native wallpaper")
        _ = try await rpc("test.menuQuit")
        connection.invalidate()
        try await Task.sleep(for: .seconds(11))
        try check(kill(original, 0) != 0 && (try !jobHasPID()), "menu quit without an open UI exits Helper and does not restart after launchd throttling")
        try check(unrelated.isRunning, "Helper-only quit leaves unrelated processes alive")
    }

    static func uiExit(fixture: URL, helper: URL) async throws {
        // Walk from Contents/Helpers/Helper.app/Contents/MacOS/Helper to
        // the embedding App's Contents; execute its real UI process.
        var contents = helper
        for _ in 0..<5 { contents.deleteLastPathComponent() }
        let ui = contents.appendingPathComponent("MacOS/WaifuX")
        try check(FileManager.default.isExecutableFile(atPath: ui.path), "UI executable is available for the AppKit exit regression")
        _ = try await rpc("video.apply", ["url": fixture.absoluteString, "muted": true])
        try await Task.sleep(for: .milliseconds(500))
        let original = try await hello().processIdentifier
        let initial = try video(await rpc("test.snapshot"))
        let screenCount = initial["nativeWindowCount"] as! Int
        try check(screenCount > 0 && initial["uniqueNativePlayerCount"] as? Int == 1,
                  "Helper owns active native wallpaper before opening the UI probe")
        let syncDirectory = fixture.deletingLastPathComponent().appendingPathComponent("exit-cloud-sync")
        let mediaFile = fixture.deletingLastPathComponent().appendingPathComponent("WaifuX/Media/cloud-fixture.mp4")
        for cycle in 1...4 {
            if cycle == 2 {
                try await setPreference("cloud_sync_directory_path", value: syncDirectory.path)
                try await setPreference("cloud_sync_enabled", value: true)
                try FileManager.default.createDirectory(at: mediaFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: fixture, to: mediaFile)
                _ = try await rpc("library.media.recordDownload0", ["item": json(item("cloud-fixture", file: mediaFile)), "localFileURL": mediaFile.absoluteString])
                let favorite: [String: Any] = ["id": "cloud-anime", "title": "Regression anime", "addedAt": 0,
                    "updatedAt": 0, "tags": [], "watchStatus": "watching"]
                try await setPreference("anime_favorites_v1", value: json(["cloud-anime": favorite]))
                let episode: [String: Any] = ["animeId": "cloud-anime", "episodeId": "episode-1", "episodeNumber": "1",
                    "currentTime": 42.0, "totalDuration": 120.0, "progress": 0.35, "lastPlayedAt": 0, "isCompleted": false]
                try await setPreference("anime_episode_progress_v1", value: json(["episode-1": episode]))
                let playback: [String: Any] = ["id": "playback-1", "animeId": "cloud-anime", "animeTitle": "Regression anime",
                    "episodeId": "episode-1", "episodeNumber": 1, "sourceId": "fixture", "sourceName": "Regression",
                    "currentTime": 42.0, "duration": 120.0, "lastPlayedAt": 0]
                try await setPreference("playback_progress_cache", value: json([playback]))
            }
            if cycle == 3 {
                let episode: [String: Any] = ["animeId": "cloud-anime", "episodeId": "episode-1", "episodeNumber": "1",
                    "currentTime": 88.0, "totalDuration": 120.0, "progress": 88.0 / 120.0, "lastPlayedAt": 1, "isCompleted": false]
                try await setPreference("anime_episode_progress_v1", value: json(["episode-1": episode]))
                try await setPreference("library_grid_order_v1", value: json(["regression-scope": ["cloud-fixture"]]))
            }
            if cycle == 4 {
                let manifestURL = syncDirectory.appendingPathComponent("WaifuXSync/v1/manifest.json")
                let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
                let hash = (manifest["files"] as! [String: [String: Any]])["Media/cloud-fixture.mp4"]!["hash"] as! String
                let canonical = syncDirectory.appendingPathComponent("WaifuXSync/v1/objects/\(hash.prefix(2))/\(hash)")
                let legacy = syncDirectory.appendingPathComponent("WaifuXSync/v1/objects/objects/\(hash.prefix(2))/\(hash)")
                try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: canonical, to: legacy)
                try FileManager.default.removeItem(at: mediaFile)
            }
            let value = "close-\(cycle)-" + UUID().uuidString
            let log = fixture.deletingLastPathComponent().appendingPathComponent("ui-exit-\(cycle).log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let output = try FileHandle(forWritingTo: log)
            let process = Process()
            process.executableURL = ui
            process.arguments = ["--helper-ui-exit-probe"]
            var environment = ProcessInfo.processInfo.environment
            environment["WAIFUX_UI_EXIT_PROBE_VALUE"] = value
            if cycle == 2 { environment["WAIFUX_UI_EXIT_PROBE_CLOSE_FROM_TASK"] = "1" }
            if cycle == 3 { environment["WAIFUX_UI_EXIT_PROBE_CLOUD"] = "sync" }
            if cycle == 4 { environment["WAIFUX_UI_EXIT_PROBE_CLOUD"] = "restore" }
            process.environment = environment
            process.standardOutput = output
            process.standardError = output
            // AppKit exits asynchronously after the actual close delegate
            // response; keep the XPC client's executor unblocked while waiting.
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { _ in continuation.resume() }
                do { try process.run() } catch { continuation.resume(throwing: error) }
            }
            try output.close()
            let proof = try String(contentsOf: log, encoding: .utf8)
            print("UI_EXIT_CYCLE \(cycle) status=\(process.terminationStatus)\n\(proof)")
            try check(process.terminationStatus == 0 && !process.isRunning &&
                      proof.contains("UI_APPKIT_EXIT_PROBE_PASSED") &&
                      proof.contains("players=0 wallpaperWindows=0"),
                      "UI cycle \(cycle) exits its PID through actual AppKit close and deferred termination")
            let saved = try await rpc("test.preference", ["key": "regression_ui_exit_ack"])
            try check(saved["value"] as? String == value, "UI cycle \(cycle) drains its last preference write before exit")
            try check(try await hello().processIdentifier == original, "UI cycle \(cycle) leaves the original Helper PID running")
            let after = try video(await rpc("test.snapshot"))
            try check(after["nativeWindowCount"] as? Int == screenCount &&
                      after["uniqueNativePlayerCount"] as? Int == 1 &&
                      (after["nativePlayerRates"] as! [String: Double]).values.allSatisfy { $0 > 0 },
                      "UI cycle \(cycle) leaves native wallpaper playing without duplicate players or windows")
            if cycle == 2 {
                let metadata = syncDirectory.appendingPathComponent("WaifuXSync/v1/metadata.json")
                let manifest = syncDirectory.appendingPathComponent("WaifuXSync/v1/manifest.json")
                for _ in 0..<40 {
                    if FileManager.default.fileExists(atPath: metadata.path) && FileManager.default.fileExists(atPath: manifest.path) { break }
                    try await Task.sleep(for: .milliseconds(250))
                }
                let diagnostic = try BackgroundPropertyList.decode(try await rpc("test.snapshot")["snapshot"] as! Data)
                print("CLOUD_EXIT_STATE \(diagnostic["cloud"] ?? "missing")")
                try check(FileManager.default.fileExists(atPath: metadata.path) && FileManager.default.fileExists(atPath: manifest.path),
                          "enabled local cloud sync finishes in Helper after the UI process exits")
                let payload = try JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as! [String: Any]
                let savedRecords = payload["records"] as! [String: Any]
                try check((savedRecords["animeFavorites"] as! [[String: Any]]).contains { $0["id"] as? String == "cloud-anime" },
                          "Helper sync exports persisted anime favorites instead of an empty new store")
                let episodes = savedRecords["animeEpisodeProgress"] as! [String: [String: Any]]
                try check(episodes["episode-1"]?["currentTime"] as? Double == 42,
                          "Helper sync exports persisted episode progress")
                try check((savedRecords["playbackProgress"] as! [[String: Any]]).contains { $0["id"] as? String == "playback-1" && $0["currentTime"] as? Double == 42 },
                          "Helper sync exports persisted playback progress")
                let fileManifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as! [String: Any]
                let files = fileManifest["files"] as! [String: [String: Any]]
                let hash = files["Media/cloud-fixture.mp4"]?["hash"] as? String ?? ""
                let object = syncDirectory.appendingPathComponent("WaifuXSync/v1/objects/\(hash.prefix(2))/\(hash)")
                try check(!hash.isEmpty && (try? Data(contentsOf: object)) == (try Data(contentsOf: fixture)),
                          "Helper sync uploads the real media object with exact bytes and a manifest hash")
                try check((savedRecords["mediaDownloads"] as! [[String: Any]]).contains {
                    ($0["item"] as? [String: Any])?["id"] as? String == "cloud-fixture" && $0["localFilePath"] as? String == "cloud-fixture.mp4"
                }, "Helper sync preserves the media record with a portable relative path")
            }
            if cycle == 3 {
                try check(proof.contains("UI_CLOUD_PROXY_PASSED operation=sync"), "manual cloud sync uses the real UI proxy and Helper RPC")
                let data = try Data(contentsOf: syncDirectory.appendingPathComponent("WaifuXSync/v1/metadata.json"))
                let records = (try JSONSerialization.jsonObject(with: data) as! [String: Any])["records"] as! [String: Any]
                try check((records["animeEpisodeProgress"] as! [String: [String: Any]])["episode-1"]?["currentTime"] as? Double == 88,
                          "repeated Helper sync reloads the latest persisted episode progress")
                try check((records["libraryGridOrder"] as? [String: [String]])?["regression-scope"] == ["cloud-fixture"],
                          "repeated Helper sync exports the latest persisted library grid order")
            }
            if cycle == 4 {
                try check(proof.contains("UI_CLOUD_PROXY_PASSED operation=restore"), "manual cloud restore uses the real UI proxy and Helper RPC")
                try check((try Data(contentsOf: mediaFile)) == (try Data(contentsOf: fixture)),
                          "UI-requested Helper restore recovers exact media bytes from the legacy cloud object")
            }
        }
        // Pause only the isolated job after the real UI has connected. Its last
        // write cannot receive an ACK, so the production two-second fallback
        // must still release the UI process. Always resume the job afterwards.
        do {
            defer { _ = kill(original, SIGCONT) }
            let log = fixture.deletingLastPathComponent().appendingPathComponent("ui-exit-unresponsive.log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let output = try FileHandle(forWritingTo: log)
            defer { try? output.close() }
            let process = Process()
            process.executableURL = ui
            process.arguments = ["--helper-ui-exit-probe"]
            var environment = ProcessInfo.processInfo.environment
            environment["WAIFUX_UI_EXIT_PROBE_VALUE"] = "unresponsive-" + UUID().uuidString
            environment["WAIFUX_UI_EXIT_PROBE_UNRESPONSIVE_HELPER"] = "1"
            environment["WAIFUX_UI_EXIT_PROBE_CLOSE_FROM_TASK"] = "1"
            let debugging = environment["WAIFUX_UI_EXIT_LLDB"] == "1"
            if debugging {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/lldb")
                process.arguments = ["--batch", "-o", "run", "-k", "thread backtrace all", "-k", "process kill", "--", ui.path, "--helper-ui-exit-probe"]
            }
            process.environment = environment
            process.standardOutput = output
            process.standardError = output
            let started = Date()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { _ in continuation.resume() }
                do { try process.run() } catch { continuation.resume(throwing: error) }
            }
            let elapsed = Date().timeIntervalSince(started)
            let proof = try String(contentsOf: log, encoding: .utf8)
            print("UI_EXIT_UNRESPONSIVE elapsed=\(elapsed) status=\(process.terminationStatus)\n\(proof)")
            if debugging { throw NSError(domain: "UIExitDiagnostic", code: 1, userInfo: [NSLocalizedDescriptionKey: "LLDB diagnostic run; not a passing regression"]) }
            try check(process.terminationStatus == 0 && proof.contains("UI_EXIT_PROBE_HELPER_PAUSED") &&
                      proof.contains("UI_APPKIT_EXIT_PROBE_PASSED"), "UI exits normally even when the isolated Helper cannot acknowledge writes")
            try check(elapsed >= 1.8 && elapsed < 6, "unresponsive Helper activates the bounded two-second UI exit fallback")
        }
        try check(try await hello().processIdentifier == original, "exit fallback leaves the original isolated Helper alive after resuming it")
        _ = try await rpc("video.stopNative")
    }
    static func lifecycle(fixture: URL) async throws {
        _ = try await rpc("video.apply", ["url": fixture.absoluteString, "muted": true])
        try await Task.sleep(for: .milliseconds(800))
        var state = try video(await rpc("test.snapshot"))
        let screens = state["active"] as! [String]
        try check(!screens.isEmpty && state["leakAuditTimerRunning"] as? Bool == true, "native pipeline starts leak audit while video is active")
        if screens.count >= 2 {
            try check(state["uniqueNativePlayerCount"] as? Int == 1, "same video shares one decoder across active displays")
            _ = try await rpc("video.pause", ["targetScreen": screens[0], "persistAsUserRequest": false])
            state = try video(await rpc("test.snapshot"))
            let paused = state["pausedScreens"] as! [String]
            let rates = state["nativePlayerRates"] as! [String: Double]
            try check(paused.contains(screens[0]) && !paused.contains(screens[1]) && (rates[screens[1]] ?? 0) > 0, "automatic single-display pause keeps shared decoder playing for its other owner")
            _ = try await rpc("video.resume", ["targetScreen": screens[0], "persistAsUserRequest": false])
            state = try video(await rpc("test.snapshot"))
            try check((state["pausedScreens"] as! [String]).isEmpty, "automatic single-display resume clears only its pause")
        } else { print("SKIP shared decoder checks require two enumerated displays") }

        _ = try await rpc("video.pause", ["persistAsUserRequest": true])
        _ = try await rpc("video.resume", ["persistAsUserRequest": false])
        state = try video(await rpc("test.snapshot"))
        try check(state["paused"] as? Bool == true && (state["nativePlayerRates"] as! [String: Double]).values.allSatisfy { $0 == 0 }, "automatic resume cannot override manual pause or restart decoder")
        for event in ["sleep", "displaySleep", "wake", "displayWake", "wake"] {
            _ = try await rpc("test.event", ["event": event])
        }
        try await Task.sleep(for: .seconds(4))
        state = try video(await rpc("test.snapshot"))
        try check(state["paused"] as? Bool == true && (state["nativePlayerRates"] as! [String: Double]).values.allSatisfy { $0 == 0 }, "duplicate and reordered wake notifications preserve manual pause in actual players")
        try check(state["nativeWindowCount"] as? Int == screens.count && state["uniqueNativePlayerCount"] as? Int == 1, "wake notification storm leaves one mapped window per screen and shared decoder")
        _ = try await rpc("video.resume", ["persistAsUserRequest": true])
        try await Task.sleep(for: .milliseconds(500))
        state = try video(await rpc("test.snapshot"))
        try check((state["nativePlayerRates"] as! [String: Double]).values.allSatisfy { $0 > 0 }, "explicit manual resume restarts decoder after wake recovery")

        // A wake callback is delayed; stopping before it runs must keep the
        // Helper idle instead of rebuilding a wallpaper that was just stopped.
        _ = try await rpc("test.event", ["event": "wake"])
        _ = try await rpc("video.stopNative")
        try await Task.sleep(for: .seconds(4))
        state = try video(await rpc("test.snapshot"))
        try check(state["nativeWindowCount"] as? Int == 0 && state["nativePlayerCount"] as? Int == 0, "late wake callback does not resurrect stopped native wallpaper")
        try check(state["leakAuditEntryCount"] as? Int == 0 && state["leakAuditTimerRunning"] as? Bool == false, "stopped native wallpaper leaves no empty recurring leak audit timer")
        _ = try await rpc("video.apply", ["url": fixture.absoluteString, "muted": true])
        state = try video(await rpc("test.snapshot"))
        try check(state["leakAuditTimerRunning"] as? Bool == true, "native leak audit restarts when a new pipeline is created")
        _ = try await rpc("video.stopNative")
    }
    static func downloads(root: URL, fixture: URL, service: String, server: URL) async throws {
        try check(try Data(contentsOf: fixture).count < 64_000, "download fixture covers a valid video smaller than 64 KB")
        let id = "download-" + UUID().uuidString
        var media = item(id, file: fixture)
        media["posterURL"] = fixture.absoluteString
        let remote = server.appendingPathComponent("slow.mp4")
        media["pageURL"] = server.appendingPathComponent("page-" + id).absoluteString
        media["previewVideoURL"] = remote.absoluteString
        let option: [String: Any] = ["id": "fixture", "label": "HD", "fileSizeLabel": "1MB", "detailText": "640x360 mp4", "remoteURL": remote.absoluteString]
        media["downloadOptions"] = [option]
        let submission = ["item": try json(media), "option": try json(option), "save": true] as [String: Any]
        let first = try await rpc("download.submitMedia", submission)
        let duplicate = try await rpc("download.submitMedia", submission)
        let taskID = first["id"] as! String
        try check(duplicate["id"] as? String == taskID, "duplicate download submissions share one job")
        _ = try await rpc("video.apply", ["url": fixture.absoluteString, "muted": true])
        let controls = try await rpc("video.pause", ["persistAsUserRequest": true])
        try check(try video(controls)["paused"] as? Bool == true, "playback controls work during an active HTTP download")
        connection.invalidate()
        try await Task.sleep(for: .seconds(5))
        connect(service)
        let completed = try await rpc("download.wait", ["id": taskID])
        let file = URL(string: completed["url"] as! String)!
        try check(file.path.hasPrefix(root.path + "/WaifuX/Media/") && FileManager.default.fileExists(atPath: file.path), "HTTP download finishes in Helper while UI is disconnected")
        try check(try Data(contentsOf: file) == Data(contentsOf: fixture), "download preserves exact media bytes")
        try check(try await records("downloads").contains { ($0["item"] as? [String: Any])?["id"] as? String == id && $0["localFilePath"] as? String == file.path }, "completed download is registered in the library")
        let (statsData, _) = try await URLSession.shared.data(from: server.appendingPathComponent("stats"))
        let stats = try JSONSerialization.jsonObject(with: statsData) as! [String: Int]
        try check(stats["/slow.mp4"] == 1, "duplicate job sends a single HTTP media request")
        let checkpoint = root.appendingPathComponent("DownloadQueue/download-queue-v2.json")
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: checkpoint)) as! [String: Any]
        try check((saved["jobs"] as? [Any])?.isEmpty == true, "finished download leaves no runnable checkpoint job")

        let pauseID = "pause-" + UUID().uuidString
        var pausedItem = item(pauseID, file: fixture)
        pausedItem["posterURL"] = fixture.absoluteString
        pausedItem["pageURL"] = server.appendingPathComponent("page-" + pauseID).absoluteString
        var pausedOption = option
        pausedOption["remoteURL"] = server.appendingPathComponent("slow-pause.mp4").absoluteString
        pausedItem["downloadOptions"] = [pausedOption]
        let paused = try await rpc("download.submitMedia", ["item": json(pausedItem), "option": json(pausedOption), "save": true])
        let pausedID = paused["id"] as! String
        try await Task.sleep(for: .milliseconds(400))
        _ = try await rpc("download.pause", ["id": pausedID])
        let pausedCheckpoint = try JSONSerialization.jsonObject(with: Data(contentsOf: checkpoint)) as! [String: Any]
        let pausedJobs = pausedCheckpoint["jobs"] as! [[String: Any]]
        try check(pausedJobs.contains { $0["id"] as? String == pausedID && $0["state"] as? String == "paused" }, "pausing download persists a paused job")
        try await Task.sleep(for: .milliseconds(400))
        _ = try await rpc("download.resume", ["id": pausedID])
        let resumed = try await rpc("download.wait", ["id": pausedID])
        let resumedFile = URL(string: resumed["url"] as! String)!
        try check(try Data(contentsOf: resumedFile) == Data(contentsOf: fixture), "paused download resumes and completes with intact bytes")

        let cancelID = "cancel-" + UUID().uuidString
        var cancelledItem = item(cancelID, file: fixture)
        cancelledItem["posterURL"] = fixture.absoluteString
        cancelledItem["pageURL"] = server.appendingPathComponent("page-" + cancelID).absoluteString
        var cancelledOption = option
        cancelledOption["remoteURL"] = server.appendingPathComponent("slow-cancel.mp4").absoluteString
        cancelledItem["downloadOptions"] = [cancelledOption]
        let cancelled = try await rpc("download.submitMedia", ["item": json(cancelledItem), "option": json(cancelledOption), "save": true])
        try await Task.sleep(for: .milliseconds(400))
        _ = try await rpc("download.cancel", ["id": cancelled["id"] as! String])
        try await Task.sleep(for: .milliseconds(400))
        let cancelledFile = root.appendingPathComponent("WaifuX/Media/motionbgs-\(cancelID)-hd.mp4")
        try check(!FileManager.default.fileExists(atPath: cancelledFile.path), "cancelled transfer leaves no partial library video")
        try check(try await records("downloads").allSatisfy { ($0["item"] as? [String: Any])?["id"] as? String != cancelID }, "cancelled transfer does not register a download")

        let badID = "invalid-" + UUID().uuidString
        media = item(badID, file: fixture)
        media["posterURL"] = fixture.absoluteString
        media["pageURL"] = server.appendingPathComponent("page-" + badID).absoluteString
        media["previewVideoURL"] = server.appendingPathComponent("html.mp4").absoluteString
        var badOption = option
        badOption["remoteURL"] = server.appendingPathComponent("html.mp4").absoluteString
        media["downloadOptions"] = [badOption]
        let bad = try await rpc("download.submitMedia", ["item": json(media), "option": json(badOption), "save": true])
        do {
            _ = try await rpc("download.wait", ["id": bad["id"] as! String])
            throw CocoaError(.coderInvalidValue)
        } catch let error as NSError {
            try check(error.code == 2, "HTML disguised as video produces a recoverable download failure")
        }
        try check(try await records("downloads").allSatisfy { ($0["item"] as? [String: Any])?["id"] as? String != badID }, "failed payload does not become a downloaded library item")
        _ = try await rpc("download.cancel", ["id": bad["id"] as! String])
        _ = try await rpc("video.stopNative")
    }
    static func main() async {
        do {
            let args = CommandLine.arguments
            let root = URL(fileURLWithPath: args[2]).deletingLastPathComponent()
            let fixture = URL(fileURLWithPath: args[2])
            connect(args[1])
            _ = try await rpc("bootstrap", ["preferences": ["system_wallpaper_sync_enabled": false, "dynamic_lock_screen_enabled": false,
                "external_video_renderer_enabled": false, "wallpaper_transition_animation_enabled": false,
                "pause_when_other_app_foreground": false, "pause_when_fullscreen_covers": false, "pause_when_window_coverage": false]])
            if args.count > 4, args[4] == "recovery" {
                try await recovery(root: root, fixture: fixture)
                _ = try await rpc("runtime.stop")
                connection.invalidate()
                print("BACKGROUND_HELPER_RECOVERY_REGRESSION_PASSED")
                return
            }
            if args.count > 4, args[4] == "lifecycle" {
                try await lifecycle(fixture: fixture)
                _ = try await rpc("runtime.stop")
                connection.invalidate()
                print("BACKGROUND_HELPER_LIFECYCLE_SIMULATION_PASSED")
                return
            }
            if args.count > 4, args[4] == "audio-cancel" {
                let capture = try await rpc("test.audioStartStop.wait")
                try check(capture["attempts"] as? Int == 0 && capture["running"] as? Bool == false, "audio stop cancels pending tap startup before the capture backend is invoked")
                _ = try await rpc("runtime.stop")
                connection.invalidate()
                print("BACKGROUND_HELPER_AUDIO_CANCELLATION_PASSED")
                return
            }
            if args.count > 4, args[4] == "ui-exit" {
                try await uiExit(fixture: fixture, helper: URL(fileURLWithPath: args[3]))
                _ = try await rpc("runtime.stop")
                connection.invalidate()
                print("BACKGROUND_HELPER_UI_EXIT_REGRESSION_PASSED")
                return
            }
            if args.count > 4, args[4] == "startup-upgrade" {
                try await startupUpgrade(fixture: fixture, helper: URL(fileURLWithPath: args[3]), service: args[1])
                _ = try await rpc("runtime.stop")
                connection.invalidate()
                print("BACKGROUND_HELPER_STARTUP_UPGRADE_REGRESSION_PASSED")
                return
            }
            if args.count > 4, args[4] == "full-quit" {
                try await fullQuit(fixture: fixture, helper: URL(fileURLWithPath: args[3]), service: args[1])
                connection.invalidate()
                print("BACKGROUND_HELPER_FULL_QUIT_REGRESSION_PASSED")
                return
            }
            if args.count > 5, args[4] == "downloads" {
                try await downloads(root: root, fixture: fixture, service: args[1], server: URL(string: args[5])!)
                _ = try await rpc("runtime.stop")
                connection.invalidate()
                print("BACKGROUND_HELPER_DOWNLOAD_REGRESSION_PASSED")
                return
            }
            let id = "workflow-" + UUID().uuidString
            let source = root.appendingPathComponent("source")
            let sourceFile = source.appendingPathComponent("Media/fixture.mp4")
            try FileManager.default.createDirectory(at: sourceFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: fixture, to: sourceFile)
            let mediaItem = item(id, file: sourceFile)
            _ = try await rpc("library.media.recordDownload0", ["item": json(mediaItem), "localFileURL": sourceFile.absoluteString])
            try check(try await records("downloads").contains { ($0["item"] as? [String: Any])?["id"] as? String == id && $0["localFilePath"] as? String == sourceFile.path }, "Helper records a real local media file")
            _ = try await rpc("library.media.toggleFavorite0", ["item": json(mediaItem)])
            try check(try await records("favorites").contains { ($0["item"] as? [String: Any])?["id"] as? String == id }, "Helper persists favorite through XPC")
            _ = try await rpc("library.media.toggleFavorite0", ["item": json(mediaItem)])
            try check(try await records("favorites").allSatisfy { ($0["item"] as? [String: Any])?["id"] as? String != id || ($0["metadata"] as? [String: Any])?["isDeleted"] as? Bool == true }, "Helper removes favorite through XPC")

            let blocked = root.appendingPathComponent("blocked-destination")
            try Data("destination is a file".utf8).write(to: blocked)
            let failure = try await rpc("directory.migrate.wait", ["old": source.absoluteString, "new": blocked.absoluteString])
            let failureResult = try JSONSerialization.jsonObject(with: failure["result"] as! Data) as! [String: Any]
            try check(failureResult["partial"] != nil || failureResult["failure"] != nil, "migration reports destination copy failure")
            try check(FileManager.default.fileExists(atPath: sourceFile.path), "copy failure preserves source file")
            let recordAfterFailure = try await records("downloads").first { ($0["item"] as? [String: Any])?["id"] as? String == id }!
            print("MIGRATION_FAILED_RECORD_PATH \(recordAfterFailure["localFilePath"] ?? "missing")")
            try check(recordAfterFailure["localFilePath"] as? String == sourceFile.path, "copy failure preserves usable library path")

            let destination = root.appendingPathComponent("destination")
            let success = try await rpc("directory.migrate.wait", ["old": source.absoluteString, "new": destination.absoluteString])
            let successResult = try JSONSerialization.jsonObject(with: success["result"] as! Data) as! [String: Any]
            let destinationFile = destination.appendingPathComponent("Media/fixture.mp4")
            print("MIGRATION_RESULT \(successResult) destinationExists=\(FileManager.default.fileExists(atPath: destinationFile.path)) sourceExists=\(FileManager.default.fileExists(atPath: sourceFile.path))")
            try check(successResult["success"] != nil && FileManager.default.fileExists(atPath: destinationFile.path) && !FileManager.default.fileExists(atPath: sourceFile.path), "successful migration moves the media file")
            try check(try Data(contentsOf: destinationFile) == Data(contentsOf: fixture), "migration preserves exact video bytes")
            let migratedRecord = try await records("downloads").first { ($0["item"] as? [String: Any])?["id"] as? String == id }!
            try check(migratedRecord["localFilePath"] as? String == destinationFile.path, "successful migration rebases durable library path")

            let folderID = UUID().uuidString
            let folder: [String: Any] = ["id": folderID, "name": "Workflow folder", "contentType": "media", "createdAt": 0, "updatedAt": 0, "isLocked": false, "collection": "downloads"]
            _ = try await rpc("library.folder.create", ["folder": json(folder)])
            var library = try await rpc("library.snapshot")
            var folders = try JSONSerialization.jsonObject(with: library["mediaFolders"] as! Data) as! [[String: Any]]
            try check(folders.contains { $0["id"] as? String == folderID }, "Helper creates a library folder")
            _ = try await rpc("library.folder.renameFolder", ["id": folderID, "contentType": json("media"), "newName": "Renamed folder"])
            _ = try await rpc("library.folder.setFolderLock", ["id": folderID, "contentType": json("media"), "locked": true])
            library = try await rpc("library.snapshot")
            folders = try JSONSerialization.jsonObject(with: library["mediaFolders"] as! Data) as! [[String: Any]]
            try check(folders.contains { $0["id"] as? String == folderID && $0["name"] as? String == "Renamed folder" && $0["isLocked"] as? Bool == true }, "Helper renames and locks a library folder")
            _ = try await rpc("library.media.recordDownload0", ["item": json(mediaItem), "localFileURL": destinationFile.absoluteString, "folderID": folderID])
            _ = try await rpc("library.folder.deleteFolder", ["id": folderID, "contentType": json("media")])
            let rootedRecord = try await records("downloads").first { ($0["item"] as? [String: Any])?["id"] as? String == id }!
            try check(rootedRecord["folderID"] == nil && FileManager.default.fileExists(atPath: destinationFile.path), "deleting a folder retains its media and returns membership to root")

            try await recovery(root: root, fixture: fixture)

            _ = try await rpc("video.apply", ["url": destinationFile.absoluteString, "muted": true])
            for index in 0..<8 {
                let url = index.isMultiple(of: 2) ? fixture : destinationFile
                _ = try await rpc("video.apply", ["url": url.absoluteString, "muted": true])
            }
            var state = try await rpc("test.snapshot")
            var values = try video(state)
            let displays = values["active"] as? [String] ?? []
            try check(!displays.isEmpty && values["nativeWindowCount"] as? Int == displays.count && values["nativePlayerCount"] as? Int == displays.count, "repeated native switches leave one player and window per display")
            _ = try await rpc("video.pause", ["persistAsUserRequest": true])
            state = try await rpc("video.rate", ["newRate": 1.5])
            try check(try video(state)["paused"] as? Bool == true, "rate change preserves user pause")
            _ = try await rpc("video.resume", ["persistAsUserRequest": true])
            state = try await rpc("video.stopNative")
            values = try video(state)
            try check(values["nativeWindowCount"] as? Int == 0 && values["nativePlayerCount"] as? Int == 0 && (values["active"] as? [String] ?? []).isEmpty, "stop releases all native players and windows")
            _ = try await rpc("runtime.stop")
            connection.invalidate()
            print("BACKGROUND_HELPER_WORKFLOW_REGRESSION_PASSED")
        } catch {
            fputs("FAIL \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
