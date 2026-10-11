import Foundation

@main struct CloudSyncFileEngineRegression {
    static func check(_ value: Bool, _ message: String) throws {
        guard value else { throw NSError(domain: "CloudFileRegression", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]) }
        print("PASS \(message)")
    }

    static func main() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("waifux-cloud-files-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let engine = CloudSyncFileEngine.shared
            let media = root.appendingPathComponent("Media")
            try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
            let bytes = Data("production cloud engine fixture".utf8)
            let file = media.appendingPathComponent("nested/fixture.mp4")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: file)
            let manifest = try await engine.scanLocalDirectory(basePath: "Media", directoryURL: media)
            try check(Set(manifest.keys) == ["Media/nested/fixture.mp4"], "cloud scanner preserves canonical relative path across /var aliases")
            let entry = manifest["Media/nested/fixture.mp4"]!
            try check(entry.hash.count == 64 && entry.size == bytes.count, "cloud manifest contains the actual SHA-256 and file size")
            let versionRoot = root.appendingPathComponent("WaifuXSync/v1")
            try await engine.ensureSyncDirectory(at: versionRoot)
            let objects = versionRoot.appendingPathComponent("objects")
            try check(FileManager.default.fileExists(atPath: objects.path) &&
                      !FileManager.default.fileExists(atPath: versionRoot.appendingPathComponent("v1").path),
                      "cloud directory creation uses the supplied version root once")
            try await engine.uploadFile(localURL: file, hash: entry.hash, objectsDir: objects)
            let object = objects.appendingPathComponent(String(entry.hash.prefix(2))).appendingPathComponent(entry.hash)
            try check((try Data(contentsOf: object)) == bytes, "cloud upload uses one objects directory and preserves exact bytes")
            let restored = root.appendingPathComponent("restored/fixture.mp4")
            try await engine.downloadFile(hash: entry.hash, objectsDir: objects, destinationURL: restored)
            try check((try Data(contentsOf: restored)) == bytes, "cloud restore verifies and copies the canonical object")
            let legacy = objects.appendingPathComponent("objects").appendingPathComponent(String(entry.hash.prefix(2))).appendingPathComponent(entry.hash)
            try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: object, to: legacy)
            try FileManager.default.removeItem(at: restored)
            try await engine.downloadFile(hash: entry.hash, objectsDir: objects, destinationURL: restored)
            try check((try Data(contentsOf: restored)) == bytes, "cloud restore retains compatibility with the old duplicated objects layout")
            try Data("corrupt".utf8).write(to: legacy)
            do {
                try await engine.downloadFile(hash: entry.hash, objectsDir: objects, destinationURL: restored)
                try check(false, "cloud rejects an object whose bytes no longer match its hash")
            } catch CloudSyncError.fileHashFailed {
                try check((try Data(contentsOf: restored)) == bytes, "corrupt cloud object leaves the existing restored file intact")
            }
            print("CLOUD_SYNC_FILE_ENGINE_REGRESSION_PASSED")
        } catch {
            fputs("FAIL \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
