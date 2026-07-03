import Foundation
import CryptoKit

/// WebDAV 远程同步引擎：与 CloudSyncFileEngine 接口对标，操作远程 WebDAV 服务器
final actor CloudSyncWebDAVEngine {
    static let shared = CloudSyncWebDAVEngine()

    private let client = CloudSyncWebDAVClient.shared
    private let localFileManager = FileManager.default

    private init() {}

    // MARK: - Hash

    /// 计算远程文件的 SHA-256（下载到临时文件后计算）
    func computeRemoteFileHash(
        url: URL,
        credentials: WebDAVCredentials
    ) async throws -> String {
        let data = try await client.get(url: url, credentials: credentials)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 计算本地文件的 SHA-256（与 FileEngine 相同）
    func computeLocalFileHash(at url: URL) throws -> String {
        guard let fileHandle = try? FileHandle(forReadingFrom: url) else {
            throw CloudSyncError.fileHashFailed(path: url.path)
        }
        defer { try? fileHandle.close() }

        var hasher = SHA256()
        let bufferSize = 1024 * 1024
        while autoreleasepool(invoking: {
            let data = fileHandle.readData(ofLength: bufferSize)
            guard !data.isEmpty else { return false }
            hasher.update(data: data)
            return true
        }) {}
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 扫描远程目录

    /// 递归扫描远程目录，返回相对路径到 ManifestEntry 的映射
    func scanRemoteDirectory(
        baseURL: URL,
        basePath: String,
        credentials: WebDAVCredentials
    ) async throws -> [String: CloudSyncManifest.CloudSyncManifestEntry] {
        var entries: [String: CloudSyncManifest.CloudSyncManifestEntry] = [:]

        let resources = try await client.recursivePropFind(
            url: baseURL,
            credentials: credentials
        )

        for resource in resources where !resource.isCollection {
            // 从 href 计算相对路径
            let decodedHref = resource.href.removingPercentEncoding ?? resource.href
            let relativePath = basePath + "/" + decodedHref
                .replacingOccurrences(of: baseURL.path, with: "")

            let hash = try await computeRemoteFileHash(
                url: buildResourceURL(base: baseURL, href: resource.href),
                credentials: credentials
            )

            entries[relativePath] = CloudSyncManifest.CloudSyncManifestEntry(
                hash: hash,
                size: resource.contentLength ?? 0,
                mtime: resource.lastModified ?? Date()
            )
        }

        return entries
    }

    // MARK: - 上传/下载

    /// 上传本地文件到 WebDAV objects 目录
    func uploadFile(
        localURL: URL,
        hash: String,
        objectsBaseURL: URL,
        credentials: WebDAVCredentials
    ) async throws {
        let objectPath = CloudSyncDirectoryLayout.objectSubpath(hash: hash)
        let objectURL = objectsBaseURL.appendingPathComponent(objectPath)

        // 检查远程是否已存在相同 hash 的文件
        do {
            let remoteHash = try await computeRemoteFileHash(url: objectURL, credentials: credentials)
            if remoteHash == hash { return }
        } catch let error as CloudSyncError {
            if case .webDAVNotFound = error { /* 继续上传 */ }
            else { throw error }
        }

        // 确保子目录存在
        let dirURL = objectURL.deletingLastPathComponent()
        try await client.mkcol(url: dirURL, credentials: credentials)

        // 读取本地文件并上传
        guard localFileManager.fileExists(atPath: localURL.path) else {
            throw CloudSyncError.fileReadFailed(path: localURL.path)
        }
        let fileData = try Data(contentsOf: localURL)

        try await client.put(
            url: objectURL,
            data: fileData,
            credentials: credentials
        )
    }

    /// 从 WebDAV objects 下载文件到本地
    func downloadFile(
        hash: String,
        objectsBaseURL: URL,
        destinationURL: URL,
        credentials: WebDAVCredentials
    ) async throws {
        let objectPath = CloudSyncDirectoryLayout.objectSubpath(hash: hash)
        let objectURL = objectsBaseURL.appendingPathComponent(objectPath)

        // 下载远程文件
        let data = try await client.get(url: objectURL, credentials: credentials)

        // 验证 hash
        let digest = SHA256.hash(data: data)
        let actualHash = digest.map { String(format: "%02x", $0) }.joined()
        guard actualHash == hash else {
            throw CloudSyncError.fileHashFailed(path: objectURL.path)
        }

        // 如果本地已存在且 hash 相同，跳过
        if localFileManager.fileExists(atPath: destinationURL.path) {
            let existingHash = try? computeLocalFileHash(at: destinationURL)
            if existingHash == hash { return }
            try localFileManager.removeItem(at: destinationURL)
        }

        // 确保目标目录存在
        try localFileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        try data.write(to: destinationURL)
    }

    // MARK: - Manifest

    /// 读取远程 manifest
    func readManifest(
        baseURL: URL,
        credentials: WebDAVCredentials
    ) async throws -> CloudSyncManifest {
        let manifestURL = baseURL.appendingPathComponent(CloudSyncDirectoryLayout.manifestFileName)

        do {
            let data = try await client.get(url: manifestURL, credentials: credentials)
            let manifest = try JSONDecoder().decode(CloudSyncManifest.self, from: data)
            return manifest
        } catch let error as CloudSyncError {
            if case .webDAVNotFound = error {
                return CloudSyncManifest(files: [:], updatedAt: Date())
            }
            throw error
        }
    }

    /// 写入远程 manifest
    func writeManifest(
        _ manifest: CloudSyncManifest,
        baseURL: URL,
        credentials: WebDAVCredentials
    ) async throws {
        let manifestURL = baseURL.appendingPathComponent(CloudSyncDirectoryLayout.manifestFileName)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)

        try await client.put(
            url: manifestURL,
            data: data,
            contentType: "application/json",
            credentials: credentials
        )
    }

    // MARK: - GC

    /// 清理远程 objects 中未被引用的文件
    func garbageCollect(
        objectsBaseURL: URL,
        referencedHashes: Set<String>,
        credentials: WebDAVCredentials
    ) async throws {
        let resources = try await client.recursivePropFind(
            url: objectsBaseURL,
            credentials: credentials
        )

        for resource in resources where !resource.isCollection {
            let fileName = URL(string: resource.href)?.lastPathComponent ?? ""
            if !referencedHashes.contains(fileName) {
                let fileURL = buildResourceURL(base: objectsBaseURL, href: resource.href)
                try await client.delete(url: fileURL, credentials: credentials)
            }
        }
    }

    // MARK: - 确保目录结构

    /// 创建远程同步目录结构
    func ensureSyncDirectory(
        baseURL: URL,
        credentials: WebDAVCredentials
    ) async throws {
        // 递归创建 WaifuXSync/v1/objects
        let rootDir = baseURL.appendingPathComponent(CloudSyncDirectoryLayout.rootName)
        let versionDir = rootDir.appendingPathComponent(CloudSyncDirectoryLayout.versionDir)
        let objectsDir = versionDir.appendingPathComponent(CloudSyncDirectoryLayout.objectsDirName)

        try await client.mkcol(url: rootDir, credentials: credentials)
        try await client.mkcol(url: versionDir, credentials: credentials)
        try await client.mkcol(url: objectsDir, credentials: credentials)
    }

    // MARK: - 工具

    private func buildResourceURL(base: URL, href: String) -> URL {
        if href.hasPrefix("http") {
            return URL(string: href) ?? base
        }
        if href.hasPrefix("/") {
            guard let components = URLComponents(url: base, resolvingAgainstBaseURL: false),
                  let baseHost = components.host,
                  let scheme = components.scheme else {
                return base
            }
            var result = "\(scheme)://\(baseHost)"
            if let port = components.port {
                result += ":\(port)"
            }
            let path = href.hasPrefix("/") ? href : "/" + href
            return URL(string: result + path) ?? base
        }
        return URL(string: href, relativeTo: base)?.absoluteURL ?? base
    }
}
