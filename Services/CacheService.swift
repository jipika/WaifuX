import Foundation

actor CacheService {
    static let shared = CacheService()

    private let fileManager = FileManager.default
    private let cacheDirectory: URL

    private init() {
        if BackgroundRuntimeRole.isIsolatedTest, let root = ProcessInfo.processInfo.environment["WAIFUX_HELPER_TEST_ROOT"] {
            cacheDirectory = URL(fileURLWithPath: root).appendingPathComponent("MediaCache", isDirectory: true)
            try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            return
        }
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            // 使用临时目录作为回退
            cacheDirectory = fileManager.temporaryDirectory.appendingPathComponent("WaifuX/Cache", isDirectory: true)
            try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            return
        }
        cacheDirectory = appSupport.appendingPathComponent("WaifuX/Cache", isDirectory: true)
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    func cacheFile(_ data: Data, named fileName: String, in directoryName: String) async throws -> URL {
        let directoryURL = cacheDirectory.appendingPathComponent(directoryName, isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let fileURL = directoryURL.appendingPathComponent(fileName)
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    func cachedFileURL(named fileName: String, in directoryName: String) -> URL? {
        let fileURL = cacheDirectory
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(fileName)

        return fileManager.fileExists(atPath: fileURL.path) ? fileURL : nil
    }

    /// 删除一个由 CacheService 创建的临时文件。
    /// 只接受 cacheDirectory 内的路径，避免调用方误删资料库文件。
    func removeCachedFile(at fileURL: URL) throws {
        let cachePath = cacheDirectory.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        guard filePath.hasPrefix(cachePath + "/") else { return }
        guard fileManager.fileExists(atPath: filePath) else { return }
        try fileManager.removeItem(atPath: filePath)
    }

    func removeCachedFile(named fileName: String, in directoryName: String) throws {
        let fileURL = cacheDirectory
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(fileName)
        try removeCachedFile(at: fileURL)
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
