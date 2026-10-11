import Foundation
import CryptoKit

#if WAIFUX_HELPER

// MARK: - 通过汇编 .incbin 嵌入在 WaifuXHelper 二进制中的 ZIP 材质包
//（运行时解压后传给 wallpaper-wgpu --assets）
//
// zip_data.o / zip_accessor.o 是 universal object（含 arm64 + x86_64 切片），
// arm64 与 x86_64 包都在链接命令里传入（见 scripts/package.sh），两个架构共用同一份
// 材质数据（assets 与架构无关）。

@_silgen_name("get_zip_data_ptr")
func getZipDataPtr() -> UnsafePointer<UInt8>

@_silgen_name("get_zip_data_size")
func getZipDataSize() -> UInt

enum WallpaperEngineEmbeddedAssets {
    private static let prepLock = NSLock()
    private static nonisolated(unsafe) var cachedAssetsRoot: String?
    /// 后台解压完成后的路径，通过 continuation 通知等待方
    private static nonisolated(unsafe) var preparationTask: Task<String?, Never>?

    /// 供渲染器使用的 **assets 根目录**（内含 materials、shaders 等）。
    /// 仅返回已缓存/已解压的路径，**不做任何 I/O**，可安全在主线程调用。
    static func materializedAssetsRootIfPresent() -> String? {
        prepLock.lock()
        defer { prepLock.unlock() }

        if let cached = cachedAssetsRoot,
           FileManager.default.fileExists(atPath: cached) {
            return cached
        }

        // 检查磁盘上是否已有解压产物（上次启动时解压的）
        if let diskPath = findExistingExtractOnDisk() {
            cachedAssetsRoot = diskPath
            return diskPath
        }

        return nil
    }

    /// Materialize only for consumers that need scene assets. Concurrent callers
    /// await one task instead of repeatedly hashing the payload during polling.
    static func prepareAssetsInBackground() { _ = ensurePreparation() }

    static func awaitAssetsReady() async -> String? {
        return await ensurePreparation().value
    }

    private static func ensurePreparation() -> Task<String?, Never> {
        prepLock.lock()
        defer { prepLock.unlock() }
        if let pending = preparationTask { return pending }
        if let ready = cachedAssetsRoot, FileManager.default.fileExists(atPath: ready) {
            return Task { ready }
        }
        let task = Task.detached(priority: .utility) {
            let result = findExistingExtractOnDisk() ?? extractAssets()
            finishPreparation(result)
            return result
        }
        preparationTask = task
        return task
    }

    private static func finishPreparation(_ root: String?) {
        prepLock.lock()
        cachedAssetsRoot = root
        preparationTask = nil
        prepLock.unlock()
    }

    private static let embeddedCacheKey: String? = {
        guard let data = readEmbeddedZip() else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }()

    private static let extractionCacheBase: URL? = {
        if BackgroundRuntimeRole.isIsolatedTest, let root = ProcessInfo.processInfo.environment["WAIFUX_HELPER_TEST_ROOT"] {
            return URL(fileURLWithPath: root).appendingPathComponent("AssetsCache")
        }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    }()

    // MARK: - Private

    /// 在磁盘缓存目录中查找已存在的解压产物
    private static func findExistingExtractOnDisk() -> String? {
        guard let cacheKey = embeddedCacheKey else { return nil }
        guard let cacheBase = extractionCacheBase else {
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
            return assetsDir.path
        }
        return nil
    }

    /// 在当前线程执行解压（应在线程池调用，不在主线程）
    private static func extractAssets() -> String? {
        guard let zipData = readEmbeddedZip() else {
            print("[WallpaperEngineEmbeddedAssets] ⚠️ 无内嵌 ZIP 数据（readEmbeddedZip 返回 nil）")
            return nil
        }
        print("[WallpaperEngineEmbeddedAssets] 内嵌 ZIP 数据大小: \(zipData.count) bytes")

        guard let cacheKey = embeddedCacheKey else { return nil }

        guard let cacheBase = extractionCacheBase else {
            print("[WallpaperEngineEmbeddedAssets] ❌ 无法获取 cachesDirectory")
            return nil
        }
        let extractRoot = cacheBase
            .appendingPathComponent("com.waifux.wallpaperengine", isDirectory: true)
            .appendingPathComponent("embedded-assets", isDirectory: true)
            .appendingPathComponent(cacheKey, isDirectory: true)

        let assetsDir = extractRoot.appendingPathComponent("assets", isDirectory: true)
        let readyURL = extractRoot.appendingPathComponent(".extracted", isDirectory: false)

        // 二次检查（其他线程可能已解压完成）
        if FileManager.default.fileExists(atPath: readyURL.path),
           FileManager.default.fileExists(atPath: assetsDir.path) {
            print("[WallpaperEngineEmbeddedAssets] 使用已解压的 assets: \(assetsDir.path)")
            return assetsDir.path
        }

        let fm = FileManager.default
        try? fm.removeItem(at: extractRoot)
        do {
            try fm.createDirectory(at: extractRoot, withIntermediateDirectories: true)
        } catch {
            print("[WallpaperEngineEmbeddedAssets] ❌ 创建解压目录失败: \(error.localizedDescription)")
            return nil
        }

        let zipURL = extractRoot.appendingPathComponent("_payload.zip")
        do {
            try zipData.write(to: zipURL)
        } catch {
            print("[WallpaperEngineEmbeddedAssets] ❌ 写入 ZIP 文件失败: \(error.localizedDescription)")
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
            print("[WallpaperEngineEmbeddedAssets] ❌ 启动 unzip 失败: \(error.localizedDescription)")
            try? fm.removeItem(at: extractRoot)
            return nil
        }

        if proc.terminationStatus != 0 {
            print("[WallpaperEngineEmbeddedAssets] ❌ unzip 退出码 \(proc.terminationStatus)")
            try? fm.removeItem(at: extractRoot)
            return nil
        }

        try? fm.removeItem(at: zipURL)

        guard proc.terminationStatus == 0,
              fm.fileExists(atPath: assetsDir.path) else {
            print("[WallpaperEngineEmbeddedAssets] ❌ unzip 完成但 assets 目录不存在: \(assetsDir.path)")
            try? fm.removeItem(at: extractRoot)
            return nil
        }

        try? "ok".write(to: readyURL, atomically: true, encoding: .utf8)
        print("[WallpaperEngineEmbeddedAssets] ✅ assets 解压成功: \(assetsDir.path)")
        return assetsDir.path
    }

    private static func readEmbeddedZip() -> Data? {
        let ptr = getZipDataPtr()
        let size = getZipDataSize()
        guard size > 100 else {
            print("[WallpaperEngineEmbeddedAssets] 内嵌 ZIP 数据过小 (\(size) bytes)，跳过")
            return nil
        }
        let data = Data(bytes: ptr, count: Int(size))
        guard data.starts(with: [0x50, 0x4B, 0x03, 0x04]) || data.starts(with: [0x50, 0x4B, 0x05, 0x06]) else {
            print("[WallpaperEngineEmbeddedAssets] 内嵌数据不是有效的 ZIP 格式（缺少 PK 魔术头）")
            return nil
        }
        return data
    }
}

#else
/// The UI never maps or extracts the embedded asset payload.
enum WallpaperEngineEmbeddedAssets {
    private static let lock = NSLock()
    private static nonisolated(unsafe) var cachedRoot: String?
    static func materializedAssetsRootIfPresent() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return cachedRoot
    }
    static func prepareAssetsInBackground() {
        Task { _ = await awaitAssetsReady() }
    }
    static func awaitAssetsReady() async -> String? {
        if let cached = materializedAssetsRootIfPresent() { return cached }
        let root = try? await BackgroundRuntimeBridge.requestCodable("assets.prepare.wait", arguments: Data(), resultKey: "root", as: String.self)
        cache(root)
        return root
    }
    private static func cache(_ root: String?) {
        lock.lock()
        cachedRoot = root
        lock.unlock()
    }
}
#endif
