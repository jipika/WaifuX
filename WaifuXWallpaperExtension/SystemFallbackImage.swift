//  系统桌面图兜底（永不空白链的最后一级）
//
//  BMP 缓存与视频首帧都不可用时（首次启动、解码器异常、库文件缺失），
//  用 /System/Library/Desktop Pictures 下的系统图垫底，保证锁屏/桌面不纯黑。
//  参考 Mirage (GPL-3.0) 的 systemFallbackImage 兜底链。
//
//  本文件保持自包含（仅 Foundation/AppKit/ImageIO），供回归脚本单独编译。

import AppKit
import ImageIO
import os

enum SystemFallbackImage {
    private static let directoryURL = URL(
        fileURLWithPath: "/System/Library/Desktop Pictures", isDirectory: true
    )

    private static let cache = FallbackImageCache()

    /// 结果进程内缓存：系统目录内容在运行期不变，扫描失败也缓存（避免每次 acquire 重扫）。
    static func image() -> CGImage? {
        cache.image()
    }

    static func loadFirstDecodableImage() -> CGImage? {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: .skipsHiddenFiles
        )) ?? []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            // Desktop Pictures 下混有系统动态壁纸的 .mov 资源，跳过视频扩展名
            if ["mov", "mp4", "m4v"].contains(entry.pathExtension.lowercased()) { continue }
            if let image = decode(entry) { return image }
        }
        return nil
    }

    private static func decode(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        // A system HEIC can be much larger than a display. The emergency
        // placeholder only needs a small thumbnail, including HDR sources.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldAllowFloat: false,
            kCGImageSourceThumbnailMaxPixelSize: 1024,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              image.width > 0, image.width <= 1024, image.height > 0, image.height <= 1024 else { return nil }
        let (bytes, overflow) = image.bytesPerRow.multipliedReportingOverflow(by: image.height)
        return !overflow && bytes > 0 && bytes <= 16 * 1024 * 1024 ? image : nil
    }
}

/// 一次性加载缓存，串行合并并发首次请求（CGImage 非 Sendable）。
private final class FallbackImageCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cachedImage: CGImage?
    private var resolved = false

    func image() -> CGImage? {
        lock.lock()
        if resolved {
            defer { lock.unlock() }
            return cachedImage
        }
        // Compute once while holding the lock. Concurrent acquire requests must
        // not each scan and decode the same fallback before resolved is set.
        let computed = SystemFallbackImage.loadFirstDecodableImage()
        if !resolved {
            cachedImage = computed
            resolved = true
        }
        defer { lock.unlock() }
        return cachedImage
    }
}
