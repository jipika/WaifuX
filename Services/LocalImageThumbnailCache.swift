import Foundation
import AppKit
import ImageIO
import CryptoKit

/// 串行化本地静图缩略图生成，避免列表滚动时对慢速卷（TF/SD/USB）并发读全图。
private actor LocalImageThumbnailGenerationCoordinator {
    static let shared = LocalImageThumbnailGenerationCoordinator()

    private let maxConcurrentGenerations = 2
    private var activeGenerations = 0
    private var waitingGenerations: [CheckedContinuation<Void, Never>] = []
    private var tasks: [String: Task<URL?, Never>] = [:]

    func generate(
        key: String,
        operation: @escaping @Sendable () async -> URL?
    ) async -> URL? {
        if let task = tasks[key] {
            return await task.value
        }

        let task = Task.detached(priority: .utility) { [operation] () -> URL? in
            await self.acquireSlot()
            let result = await operation()
            await self.releaseSlot()
            return result
        }
        tasks[key] = task

        let result = await task.value
        tasks.removeValue(forKey: key)
        return result
    }

    private func acquireSlot() async {
        if activeGenerations < maxConcurrentGenerations {
            activeGenerations += 1
            return
        }
        await withCheckedContinuation { continuation in
            waitingGenerations.append(continuation)
        }
    }

    private func releaseSlot() {
        if let next = waitingGenerations.first {
            waitingGenerations.removeFirst()
            next.resume()
        } else {
            activeGenerations = max(0, activeGenerations - 1)
        }
    }
}

/// 「我的库」静图列表缩略图缓存。
///
/// 外置卡/U 盘上的原图常为数 MB～数十 MB；若卡片直接 `KFImage(localFullFile)`，
/// Kingfisher 的 Downsampling 仍要从慢卷完整读入才能缩放。
/// 本缓存把列表封面落到本机 SSD（Caches/WaifuX/LocalImageThumbnails），列表只读小 JPEG。
@MainActor
final class LocalImageThumbnailCache {
    static let shared = LocalImageThumbnailCache()

    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    /// 同步存在性缓存：key = path_md5，value = 缓存文件是否可用
    private let existenceCache = NSCache<NSString, NSNumber>()

    /// 列表封面目标边长。512px 在 Retina 网格卡上实测偏糊（用户 2026-10-27 反馈），
    /// 提到 768 对齐 GIF 中间帧链；尺寸编进缓存文件名，旧 512px 产物自然失效。
    private let maxPixelSize: CGFloat = 768
    private let jpegQuality: CGFloat = 0.82
    private let minUsableBytes = 400

    /// 缓存文件名尺寸段：格式变更 = 旧产物整体失效重生成。
    private let sizeToken = "768"

    /// 可生成静态列表 JPEG 的扩展（**不含 gif**：动图必须保留原文件给 hover 播放）。
    nonisolated private static let rasterExtensions: Set<String> = [
        "jpg", "jpeg", "png", "webp", "heic", "heif", "avif", "bmp", "tiff", "tif"
    ]

    private init() {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
        cacheDirectory = caches[0].appendingPathComponent("WaifuX/LocalImageThumbnails", isDirectory: true)
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        existenceCache.countLimit = 4000
    }

    // MARK: - Public

    /// 是否适合走本缓存（本地**静图**文件；GIF 返回 false，避免压成 JPEG 后无法 hover 播放）。
    nonisolated static func isRasterImageFile(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        return rasterExtensions.contains(url.pathExtension.lowercased())
    }

    /// 本地 GIF（含 Workshop preview.gif）应直接用于列表动画源，不要经本缓存。
    nonisolated static func isGIFFile(_ url: URL) -> Bool {
        url.isFileURL && url.pathExtension.lowercased() == "gif"
    }

    /// 仅返回已存在的列表缩略图（不触发磁盘生成、不访问源文件）。
    func cachedThumbnailURLIfExists(forLocalFile sourceURL: URL) -> URL? {
        guard sourceURL.isFileURL else { return nil }
        let pathKey = sourceURL.standardizedFileURL.path
        let key = pathKey.md5 as NSString
        if let cached = existenceCache.object(forKey: key), !cached.boolValue {
            return nil
        }
        let out = cacheFileURL(forPathKey: pathKey)
        if isUsableCachedImage(at: out) {
            existenceCache.setObject(NSNumber(value: true), forKey: key)
            return out
        }
        existenceCache.setObject(NSNumber(value: false), forKey: key)
        return nil
    }

    /// 列表封面 URL：优先 SSD 缩略图；缺失时异步生成并立即返回安全 fallback（远程 thumb / 源路径）。
    /// - Parameters:
    ///   - sourceURL: 本地原图
    ///   - fallbackURL: 缓存未就绪时展示的 URL（通常为站点 thumb，避免直接读大图）
    /// - Returns: 应用应立刻用于 `KFImage` 的 URL
    func listThumbnailURL(
        forLocalFile sourceURL: URL,
        fallbackURL: URL?
    ) -> URL {
        if let cached = cachedThumbnailURLIfExists(forLocalFile: sourceURL) {
            return cached
        }

        if Self.isRasterImageFile(sourceURL) {
            Task { @MainActor in
                _ = await ensureThumbnail(forLocalFile: sourceURL)
            }
        }

        // 优先远程/已有小图，绝不在列表热路径返回大原图路径
        if let fallbackURL {
            return fallbackURL
        }
        return sourceURL
    }

    /// 确保本地静图在 SSD 上有列表缩略图；命中则立即返回。
    @discardableResult
    func ensureThumbnail(forLocalFile sourceURL: URL) async -> URL? {
        guard sourceURL.isFileURL, Self.isRasterImageFile(sourceURL) else { return nil }
        let pathKey = sourceURL.standardizedFileURL.path
        let out = cacheFileURL(forPathKey: pathKey)
        if isUsableCachedImage(at: out) {
            existenceCache.setObject(NSNumber(value: true), forKey: pathKey.md5 as NSString)
            return out
        }

        let maxPixel = maxPixelSize
        let quality = jpegQuality
        let generated = await LocalImageThumbnailGenerationCoordinator.shared.generate(key: out.path) {
            await Self.generateThumbnailFile(
                sourcePath: pathKey,
                outputURL: out,
                maxPixelSize: maxPixel,
                jpegQuality: quality
            )
        }
        guard let url = generated else { return nil }
        existenceCache.setObject(NSNumber(value: true), forKey: pathKey.md5 as NSString)
        FileExistenceCache.shared.markExisting(atPath: url.path)
        return url
    }

    func invalidate(forLocalFile sourceURL: URL) {
        guard sourceURL.isFileURL else { return }
        let pathKey = sourceURL.standardizedFileURL.path
        let out = cacheFileURL(forPathKey: pathKey)
        try? fileManager.removeItem(at: out)
        existenceCache.removeObject(forKey: pathKey.md5 as NSString)
    }

    func clearMemoryHints() {
        existenceCache.removeAllObjects()
    }

    // MARK: - Private

    private func cacheFileURL(forPathKey pathKey: String) -> URL {
        cacheDirectory.appendingPathComponent("img_\(pathKey.md5)_\(sizeToken).jpg")
    }

    private func isUsableCachedImage(at url: URL) -> Bool {
        guard fileManager.fileExists(atPath: url.path),
              let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let sz = attrs[.size] as? NSNumber,
              sz.intValue > minUsableBytes else {
            return false
        }
        return true
    }

    /// 后台用 ImageIO 缩略图，只读必要数据，避免把整张 4K/8K 解码进内存。
    nonisolated private static func generateThumbnailFile(
        sourcePath: String,
        outputURL: URL,
        maxPixelSize: CGFloat,
        jpegQuality: CGFloat
    ) async -> URL? {
        await Task.detached(priority: .utility) {
            let sourceURL = URL(fileURLWithPath: sourcePath)
            guard FileManager.default.fileExists(atPath: sourcePath) else { return nil }

            let options: [CFString: Any] = [
                kCGImageSourceShouldCache: false,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(maxPixelSize)
            ]

            guard let imageSource = CGImageSourceCreateWithURL(sourceURL as CFURL, [
                kCGImageSourceShouldCache: false
            ] as CFDictionary),
                  let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary),
                  let jpeg = encodeJPEG(cgImage, quality: jpegQuality) else {
                return nil
            }

            do {
                try jpeg.write(to: outputURL, options: .atomic)
                return outputURL
            } catch {
                print("[LocalImageThumbnailCache] Write failed: \(error)")
                return nil
            }
        }.value
    }

    nonisolated private static func encodeJPEG(_ image: CGImage, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData,
            "public.jpeg" as CFString,
            1,
            nil
        ) else {
            return nil
        }
        let props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
