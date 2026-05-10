import Foundation
import AppKit
import Kingfisher

/// 轻量图片加载器，替代 Kingfisher
/// 特点：
/// 1. CGImageSource 硬件加速降采样
/// 2. LRU 内存缓存（可控上限）
/// 3. 任务取消支持（滑出屏幕立即取消）
actor ExploreGridImageLoader {
    private struct OngoingTaskEntry {
        let id: UUID
        let task: Task<NSImage?, Never>
        var consumers: Int
    }

    static let shared = ExploreGridImageLoader()
    private nonisolated static let remoteRetryStrategy = DelayRetryStrategy(
        maxRetryCount: 2,
        retryInterval: .accumulated(1.0)
    )

    private var ongoingTasks: [String: OngoingTaskEntry] = [:]
    private let cache = ExploreGridImageCache.shared

    /// 加载图片（主入口）
    func load(url: URL?, targetSize: CGSize) async -> NSImage? {
        guard let url else { return nil }
        guard let normalizedTargetSize = Self.normalizedDecodeSize(from: targetSize) else { return nil }

        let key = cacheKey(url: url, size: normalizedTargetSize)

        // 1. 内存缓存命中
        if let cached = cache.object(forKey: key) {
            return cached
        }

        // 2. 已有相同任务
        if var existing = ongoingTasks[key] {
            existing.consumers += 1
            ongoingTasks[key] = existing
            return await existing.task.value
        }

        // 3. 创建新任务
        let taskID = UUID()
        let task = Task<NSImage?, Never> { [weak self] in
            let image = await Self.decodeImage(url: url, maxSize: normalizedTargetSize)
            guard !Task.isCancelled else {
                Task { await self?.removeTask(forKey: key, matchingID: taskID) }
                return nil
            }
            if let image {
                ExploreGridImageCache.shared.setObject(image, forKey: key)
            }
            Task { await self?.removeTask(forKey: key, matchingID: taskID) }
            return image
        }

        ongoingTasks[key] = OngoingTaskEntry(id: taskID, task: task, consumers: 1)
        return await task.value
    }

    /// 取消指定 URL 的加载
    func cancel(url: URL?, targetSize: CGSize) {
        guard let url else { return }
        guard let normalizedTargetSize = Self.normalizedDecodeSize(from: targetSize) else { return }
        let key = cacheKey(url: url, size: normalizedTargetSize)

        guard var existing = ongoingTasks[key] else { return }
        existing.consumers -= 1

        if existing.consumers <= 0 {
            existing.task.cancel()
            ongoingTasks.removeValue(forKey: key)
        } else {
            ongoingTasks[key] = existing
        }
    }

    /// 更新可见区域（用于未来优先级调度）
    func setVisibleIndexPaths(_ indexPaths: Set<IndexPath>) {
        // 当前实现：仅存储，未来可用于优先级排序
    }

    /// 主窗口长期隐藏后取消前台图片解码任务并清空列表图片内存。
    func cancelAll() {
        for entry in ongoingTasks.values {
            entry.task.cancel()
        }
        ongoingTasks.removeAll()
        cache.removeAll()
    }

    private func removeTask(forKey key: String, matchingID taskID: UUID) {
        guard let existing = ongoingTasks[key], existing.id == taskID else { return }
        ongoingTasks.removeValue(forKey: key)
    }

    /// 后台解码 + 降采样（CGImageSource 硬件加速）
    private nonisolated static func decodeImage(url: URL, maxSize: CGSize) async -> NSImage? {
        if !url.isFileURL {
            return await retrieveRemoteImage(url: url, maxSize: maxSize)
        }

        return await Task.detached(priority: .utility) { () -> NSImage? in
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return nil
            }

            guard let source = CGImageSourceCreateWithURL(url as CFURL, [
                kCGImageSourceShouldCache: false
            ] as CFDictionary) else {
                return nil
            }

            let maxPixelSize = max(64, Int(max(maxSize.width, maxSize.height).rounded(.up)))

            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
            ] as CFDictionary) else {
                return nil
            }

            return NSImage(cgImage: cgImage, size: NSSize(
                width: cgImage.width,
                height: cgImage.height
            ))
        }.value
    }

    private nonisolated static func retrieveRemoteImage(url: URL, maxSize: CGSize) async -> NSImage? {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let attempts: [[KingfisherOptionsInfoItem]] = [
            [
                .processor(DownsamplingImageProcessor(size: maxSize)),
                .scaleFactor(scale),
                .backgroundDecode,
                .retryStrategy(remoteRetryStrategy),
                .requestModifier(AnyModifier { request in
                    var request = request
                    request.timeoutInterval = max(request.timeoutInterval, 45)
                    if let host = request.url?.host?.lowercased(),
                       host.contains("steam") || host.contains("akamaihd") {
                        request.setValue("https://steamcommunity.com/", forHTTPHeaderField: "Referer")
                    }
                    return request
                })
            ],
            [
                .scaleFactor(scale),
                .backgroundDecode,
                .retryStrategy(remoteRetryStrategy),
                .requestModifier(AnyModifier { request in
                    var request = request
                    request.timeoutInterval = max(request.timeoutInterval, 45)
                    if let host = request.url?.host?.lowercased(),
                       host.contains("steam") || host.contains("akamaihd") {
                        request.setValue("https://steamcommunity.com/", forHTTPHeaderField: "Referer")
                    }
                    return request
                })
            ]
        ]

        for options in attempts {
            guard !Task.isCancelled else { return nil }
            do {
                let result = try await KingfisherManager.shared.retrieveImage(
                    with: .network(url),
                    options: options
                )
                return result.image
            } catch {
                guard !Task.isCancelled else { return nil }
                continue
            }
        }

        return nil
    }

    private nonisolated static func normalizedDecodeSize(from size: CGSize) -> CGSize? {
        guard size.width.isFinite, size.height.isFinite else { return nil }
        // 8K / 9K 长边在壁纸源里是可能出现的，这里只防异常值，不人为压低高分图。
        let width = min(max(size.width.rounded(.up), 64), 12288)
        let height = min(max(size.height.rounded(.up), 64), 12288)
        guard width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }

    private func cacheKey(url: URL, size: CGSize) -> String {
        "\(url.absoluteString)_\(Int(size.width))x\(Int(size.height))"
    }
}
