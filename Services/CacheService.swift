import Foundation
import CryptoKit

actor CacheService {
    static let shared = CacheService()

    private let fileManager = FileManager.default
    private let cacheDirectory: URL

    private init() {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            // 使用临时目录作为回退
            cacheDirectory = fileManager.temporaryDirectory.appendingPathComponent("WallHaven/Cache", isDirectory: true)
            try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            return
        }
        cacheDirectory = appSupport.appendingPathComponent("WallHaven/Cache", isDirectory: true)
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    /// 生成基于完整 URL 的缓存键（使用 SHA256 哈希）
    private func cacheKey(for url: URL) -> String {
        let urlString = url.absoluteString
        // 使用 SHA256 生成唯一标识符
        let data = Data(urlString.utf8)
        let hash = SHA256.hash(data: data)
        // 取前 16 个字符作为文件名（足够唯一且避免文件名过长）
        let hashString = hash.compactMap { String(format: "%02x", $0) }.joined().prefix(16)
        // 保留原始扩展名（如果有）
        let ext = url.pathExtension.isEmpty ? "" : ".\(url.pathExtension)"
        return "\(hashString)\(ext)"
    }

    func cacheImage(_ data: Data, for url: URL) async throws {
        let fileName = cacheKey(for: url)
        let fileURL = cacheDirectory.appendingPathComponent(fileName)
        try data.write(to: fileURL)
    }

    func cacheFile(_ data: Data, named fileName: String, in directoryName: String) async throws -> URL {
        let directoryURL = cacheDirectory.appendingPathComponent(directoryName, isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let fileURL = directoryURL.appendingPathComponent(fileName)
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    func getCachedImage(for url: URL) -> Data? {
        let fileName = cacheKey(for: url)
        let fileURL = cacheDirectory.appendingPathComponent(fileName)
        return try? Data(contentsOf: fileURL)
    }

    func cachedFileURL(named fileName: String, in directoryName: String) -> URL? {
        let fileURL = cacheDirectory
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(fileName)

        return fileManager.fileExists(atPath: fileURL.path) ? fileURL : nil
    }

    func clearCache() async throws {
        let contents = try fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)
        for file in contents {
            try fileManager.removeItem(at: file)
        }
    }

    var cacheSize: Int {
        let contents = (try? fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return contents.reduce(0) { total, file in
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + size
        }
    }
}
