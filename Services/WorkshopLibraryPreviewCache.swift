import Foundation

/// 缓存「我的库」对 Wallpaper Engine 本地工程的轻量元数据查询。
///
/// 外置卡上 `contentsOfDirectory` / 读 `project.json` / 递归找视频极慢；
/// 列表 `updateMediaItems` 会对每一项同步调用这些路径。本缓存把结果
/// 留在内存里，滚动与列表重建只打一次慢卷 I/O。
final class WorkshopLibraryPreviewCache: @unchecked Sendable {
    static let shared = WorkshopLibraryPreviewCache()

    /// 解析策略变更时递增，避免旧版「有 pkg 就不找视频」等负结果永久卡住。
    private static let videoLookupGeneration = 2

    private let lock = NSLock()
    private var projectTypeByPath: [String: String?] = [:]
    private var previewImageByPath: [String: URL?] = [:]
    private var previewGIFByPath: [String: URL?] = [:]
    private var videoFileByPath: [String: URL?] = [:]
    private let maxEntries = 4000

    private init() {}

    func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        projectTypeByPath.removeAll(keepingCapacity: false)
        previewImageByPath.removeAll(keepingCapacity: false)
        previewGIFByPath.removeAll(keepingCapacity: false)
        videoFileByPath.removeAll(keepingCapacity: false)
    }

    func invalidate(path: String) {
        let key = (path as NSString).standardizingPath
        lock.lock()
        defer { lock.unlock() }
        projectTypeByPath.removeValue(forKey: key)
        previewImageByPath.removeValue(forKey: key)
        previewGIFByPath.removeValue(forKey: key)
        videoFileByPath.removeValue(forKey: videoCacheKey(for: key))
    }

    func projectType(for url: URL, compute: () -> String?) -> String? {
        let key = url.standardizedFileURL.path
        lock.lock()
        if let cached = projectTypeByPath[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let value = compute()
        lock.lock()
        trimIfNeededLocked()
        projectTypeByPath[key] = value
        lock.unlock()
        return value
    }

    func previewImage(for url: URL, compute: () -> URL?) -> URL? {
        let key = url.standardizedFileURL.path
        lock.lock()
        if let cached = previewImageByPath[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let value = compute()
        lock.lock()
        trimIfNeededLocked()
        previewImageByPath[key] = value
        lock.unlock()
        return value
    }

    func previewGIF(for url: URL, compute: () -> URL?) -> URL? {
        let key = url.standardizedFileURL.path
        lock.lock()
        if let cached = previewGIFByPath[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let value = compute()
        lock.lock()
        trimIfNeededLocked()
        previewGIFByPath[key] = value
        lock.unlock()
        return value
    }

    func videoFile(for url: URL, compute: () -> URL?) -> URL? {
        let path = url.standardizedFileURL.path
        let key = videoCacheKey(for: path)
        lock.lock()
        if let cached = videoFileByPath[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let value = compute()
        lock.lock()
        trimIfNeededLocked()
        videoFileByPath[key] = value
        lock.unlock()
        return value
    }

    private func videoCacheKey(for path: String) -> String {
        "v\(Self.videoLookupGeneration):\(path)"
    }

    private func trimIfNeededLocked() {
        // 简单容量保护：超限时整表清空（比 LRU 实现成本低，库列表场景够用）
        if projectTypeByPath.count > maxEntries
            || previewImageByPath.count > maxEntries
            || previewGIFByPath.count > maxEntries
            || videoFileByPath.count > maxEntries {
            projectTypeByPath.removeAll(keepingCapacity: true)
            previewImageByPath.removeAll(keepingCapacity: true)
            previewGIFByPath.removeAll(keepingCapacity: true)
            videoFileByPath.removeAll(keepingCapacity: true)
        }
    }
}
