import Foundation
import CryptoKit

// MARK: - 嵌入在 wallpaperengine-cli 尾部的 ZIP 材质包（主 App 不再携带 assets 目录）

enum WallpaperEngineEmbeddedAssets {
    private static let footerByteCount = 8
    private static let prepLock = NSLock()
    private static var cachedAssetsRoot: String?

    /// 供渲染器使用的 **assets 根目录**（内含 materials、shaders 等）；首次调用时从可执行文件尾部解压。
    static func materializedAssetsRootIfPresent() -> String? {
        prepLock.lock()
        defer { prepLock.unlock() }

        if let cached = cachedAssetsRoot,
           FileManager.default.fileExists(atPath: cached) {
            return cached
        }

        guard let zipData = readZipPayloadFromSelfExecutable() else {
            return nil
        }

        let digest = SHA256.hash(data: zipData)
        let cacheKey = digest.map { String(format: "%02x", $0) }.joined()

        guard let cacheBase = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let extractRoot = cacheBase
            .appendingPathComponent("com.waifux.wallpaperengine", isDirectory: true)
            .appendingPathComponent("embedded-assets", isDirectory: true)
            .appendingPathComponent(cacheKey, isDirectory: true)

        let assetsDir = extractRoot.appendingPathComponent("assets", isDirectory: true)
        let readyURL = extractRoot.appendingPathComponent(".extracted", isDirectory: false)

        if FileManager.default.fileExists(atPath: readyURL.path),
           FileManager.default.fileExists(atPath: assetsDir.path) {
            cachedAssetsRoot = assetsDir.path
            return assetsDir.path
        }

        let fm = FileManager.default
        try? fm.removeItem(at: extractRoot)
        do {
            try fm.createDirectory(at: extractRoot, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        let zipURL = extractRoot.appendingPathComponent("_payload.zip")
        do {
            try zipData.write(to: zipURL)
        } catch {
            try? fm.removeItem(at: extractRoot)
            return nil
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-q", "-o", zipURL.path, "-d", extractRoot.path]
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            try? fm.removeItem(at: extractRoot)
            return nil
        }

        try? fm.removeItem(at: zipURL)

        guard proc.terminationStatus == 0,
              fm.fileExists(atPath: assetsDir.path) else {
            try? fm.removeItem(at: extractRoot)
            return nil
        }

        try? "ok".write(to: readyURL, atomically: true, encoding: .utf8)
        cachedAssetsRoot = assetsDir.path
        return assetsDir.path
    }

    private static func readZipPayloadFromSelfExecutable() -> Data? {
        let exePath = CommandLine.arguments[0]
        let url = URL(fileURLWithPath: exePath)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: exePath),
              let sizeNum = attrs[.size] as? NSNumber else { return nil }
        let totalSize = sizeNum.intValue
        guard totalSize > footerByteCount else { return nil }

        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }

        do {
            try fh.seek(toOffset: UInt64(totalSize - footerByteCount))
        } catch {
            return nil
        }
        let footer = fh.readData(ofLength: footerByteCount)
        guard footer.count == footerByteCount else { return nil }

        let zipStart = Int(footer.withUnsafeBytes { raw in
            UInt64(littleEndian: raw.load(as: UInt64.self))
        })
        guard zipStart >= 0,
              zipStart < totalSize - footerByteCount else {
            return nil
        }

        let zipLength = totalSize - footerByteCount - zipStart
        guard zipLength > 100 else { return nil }

        do {
            try fh.seek(toOffset: UInt64(zipStart))
        } catch {
            return nil
        }
        let data = fh.readData(ofLength: zipLength)
        guard data.count == zipLength,
              data.starts(with: [0x50, 0x4B, 0x03, 0x04]) || data.starts(with: [0x50, 0x4B, 0x05, 0x06]) else {
            return nil
        }
        return data
    }
}
