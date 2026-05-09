import Foundation
import AppKit

/// 线程安全的 LRU 图片内存缓存
/// 参考 FlowVision 的 CustomCache 实现，用于替代 Kingfisher 的内存缓存
final class ExploreGridImageCache: @unchecked Sendable {

    static let shared = ExploreGridImageCache()

    private var cache: [String: NSImage] = [:]
    private var keys: [String] = []
    private var costs: [String: Int] = [:]
    private var totalCost: Int = 0
    private let lock = NSLock()

    /// 最大缓存数量
    var countLimit: Int = 150
    /// 最大像素内存成本，按 RGBA 4 bytes/pixel 估算。
    var totalCostLimit: Int = 160 * 1024 * 1024

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return keys.count
    }

    func object(forKey key: String) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }

        if let image = cache[key] {
            // 移到末尾 = 最近使用
            if let index = keys.firstIndex(of: key) {
                keys.remove(at: index)
                keys.append(key)
            }
            return image
        }
        return nil
    }

    func setObject(_ image: NSImage, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }

        let cost = estimatedCost(for: image)
        if cache[key] != nil {
            if let index = keys.firstIndex(of: key) {
                keys.remove(at: index)
            }
            totalCost -= costs[key] ?? 0
        }

        trimLocked(toCount: max(0, countLimit - 1), preservingAdditionalCost: cost)
        keys.append(key)
        cache[key] = image
        costs[key] = cost
        totalCost += cost
        trimLocked(toCount: countLimit, preservingAdditionalCost: 0)
    }

    func removeObject(forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        removeLocked(key)
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        cache.removeAll()
        keys.removeAll()
        costs.removeAll()
        totalCost = 0
    }

    /// 裁剪到指定数量（内存紧张时调用）
    func trim(to count: Int) {
        lock.lock()
        defer { lock.unlock() }

        while keys.count > count {
            guard let oldest = keys.first else { break }
            removeLocked(oldest)
        }
    }

    private func trimLocked(toCount count: Int, preservingAdditionalCost additionalCost: Int) {
        while keys.count > count || totalCost + additionalCost > totalCostLimit {
            guard let oldest = keys.first else { break }
            removeLocked(oldest)
        }
    }

    private func removeLocked(_ key: String) {
        cache.removeValue(forKey: key)
        totalCost -= costs.removeValue(forKey: key) ?? 0
        keys.removeAll { $0 == key }
        if totalCost < 0 { totalCost = 0 }
    }

    private func estimatedCost(for image: NSImage) -> Int {
        let rep = image.representations.max {
            ($0.pixelsWide * $0.pixelsHigh) < ($1.pixelsWide * $1.pixelsHigh)
        }
        let pixelsWide = max(1, rep?.pixelsWide ?? Int(ceil(image.size.width)))
        let pixelsHigh = max(1, rep?.pixelsHigh ?? Int(ceil(image.size.height)))
        return pixelsWide * pixelsHigh * 4
    }
}
