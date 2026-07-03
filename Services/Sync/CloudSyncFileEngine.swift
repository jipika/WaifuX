import Foundation
import CryptoKit

/// 文件同步引擎：负责本地文件扫描、hash 计算、objects 读写、manifest 维护
final actor CloudSyncFileEngine {
    static let shared = CloudSyncFileEngine()

    private let fileManager = FileManager.default

    // MARK: - 公共 API

    /// 计算文件的 SHA-256 hash
    func computeFileHash(at url: URL) throws -> String {
        guard let fileHandle = try? FileHandle(forReadingFrom: url) else {
            throw CloudSyncError.fileHashFailed(path: url.path)
        }
        defer { try? fileHandle.close() }

        var hasher = SHA256()
        let bufferSize = 1024 * 1024 // 1MB buffer
        while autoreleasepool(invoking: {
            let data = fileHandle.readData(ofLength: bufferSize)
            guard !data.isEmpty else { return false }
            hasher.update(data: data)
            return true
        }) {}
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 扫描本地下载目录，生成当前 manifest
    /// - parameter basePath: 基础路径（如 Wallpapers/、Media/、SceneBakes/）
    /// - parameter directoryURL: 对应的完整目录 URL（来自 DownloadPathManager）
    func scanLocalDirectory(
        basePath: String,
        directoryURL: URL
    ) throws -> [String: CloudSyncManifest.CloudSyncManifestEntry] {
        var entries: [String: CloudSyncManifest.CloudSyncManifestEntry] = [:]

        guard fileManager.fileExists(atPath: directoryURL.path),
              let enumerator = fileManager.enumerator(
                at: directoryURL,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
              ) else {
            return entries
        }

        for case let fileURL as URL in enumerator {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }

            let resourceValues = try fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard let fileSize = resourceValues.fileSize,
                  let mtime = resourceValues.contentModificationDate else { continue }

            // 计算相对路径
            let relativePath = basePath + "/" + fileURL.path
                .replacingOccurrences(of: directoryURL.path + "/", with: "")

            let hash = try computeFileHash(at: fileURL)

            entries[relativePath] = CloudSyncManifest.CloudSyncManifestEntry(
                hash: hash,
                size: Int64(fileSize),
                mtime: mtime
            )
        }

        return entries
    }

    /// 同步文件：将本地文件拷贝到 objects 目录（如果 hash 相同则跳过）
    func uploadFile(
        localURL: URL,
        hash: String,
        objectsDir: URL
    ) throws {
        let objectPath = CloudSyncDirectoryLayout.objectSubpath(hash: hash)
        let objectURL = objectsDir.appendingPathComponent(objectPath)

        // 如果 object 已存在且 hash 正确，跳过
        if fileManager.fileExists(atPath: objectURL.path) {
            let existingHash = try? computeFileHash(at: objectURL)
            if existingHash == hash { return }
        }

        // 确保子目录存在
        try fileManager.createDirectory(
            at: objectURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // 拷贝文件
        do {
            try fileManager.copyItem(at: localURL, to: objectURL)
        } catch {
            throw CloudSyncError.fileCopyFailed(source: localURL.path, destination: objectURL.path)
        }
    }

    /// 从 objects 恢复文件到本地
    func downloadFile(
        hash: String,
        objectsDir: URL,
        destinationURL: URL
    ) throws {
        let objectPath = CloudSyncDirectoryLayout.objectSubpath(hash: hash)
        let objectURL = objectsDir.appendingPathComponent(objectPath)

        guard fileManager.fileExists(atPath: objectURL.path) else {
            throw CloudSyncError.fileReadFailed(path: objectURL.path)
        }

        // 验证 hash
        let actualHash = try computeFileHash(at: objectURL)
        guard actualHash == hash else {
            throw CloudSyncError.fileHashFailed(path: objectURL.path)
        }

        // 确保目标目录存在
        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // 拷贝（如果已存在且 hash 相同，跳过）
        if fileManager.fileExists(atPath: destinationURL.path) {
            let existingHash = try? computeFileHash(at: destinationURL)
            if existingHash == hash { return }
            try fileManager.removeItem(at: destinationURL)
        }

        try fileManager.copyItem(at: objectURL, to: destinationURL)
    }

    /// 读取云端 manifest
    func readManifest(from url: URL) throws -> CloudSyncManifest {
        guard fileManager.fileExists(atPath: url.path) else {
            return CloudSyncManifest(files: [:], updatedAt: Date())
        }

        let data = try Data(contentsOf: url)
        do {
            let manifest = try JSONDecoder().decode(CloudSyncManifest.self, from: data)
            return manifest
        } catch {
            throw CloudSyncError.manifestCorrupted
        }
    }

    /// 写入云端 manifest
    func writeManifest(_ manifest: CloudSyncManifest, to url: URL) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)

        try data.write(to: url)
    }

    /// GC：删除 objects 中未被任何 manifest 引用的文件
    func garbageCollect(objectsDir: URL, referencedHashes: Set<String>) throws {
        guard fileManager.fileExists(atPath: objectsDir.path) else { return }

        guard let enumerator = fileManager.enumerator(
            at: objectsDir,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }

        for case let fileURL as URL in enumerator {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }

            let fileName = fileURL.lastPathComponent
            if !referencedHashes.contains(fileName) {
                try fileManager.removeItem(at: fileURL)
            }
        }

        // 清理空子目录
        try removeEmptyDirectories(at: objectsDir)
    }

    /// 清理空目录
    private func removeEmptyDirectories(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }

        let contents = try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        )

        for dirURL in contents {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: dirURL.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }

            try removeEmptyDirectories(at: dirURL)
            let subContents = try fileManager.contentsOfDirectory(
                at: dirURL,
                includingPropertiesForKeys: nil
            )
            if subContents.isEmpty {
                try fileManager.removeItem(at: dirURL)
            }
        }
    }

    /// 确保同步目录结构存在
    func ensureSyncDirectory(at rootURL: URL) throws {
        let versionDir = rootURL.appendingPathComponent(CloudSyncDirectoryLayout.versionDir)
        let objectsDir = versionDir.appendingPathComponent(CloudSyncDirectoryLayout.objectsDirName)

        try fileManager.createDirectory(
            at: objectsDir,
            withIntermediateDirectories: true
        )
    }
}
