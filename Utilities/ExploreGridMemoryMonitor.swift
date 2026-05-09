import Foundation
import AppKit

/// 内存监控器，定时检查内存使用并主动清理图片缓存
/// 防止长时间浏览导致内存持续增长
final class ExploreGridMemoryMonitor: @unchecked Sendable {

    static let shared = ExploreGridMemoryMonitor()

    private var timer: Timer?
    private let checkInterval: TimeInterval = 5.0

    /// 内存上限（MB），超过此值触发缓存清理
    var memoryLimitMB: Double = 800

    /// 缓存图片数量上限
    var cacheCountLimit: Int = 150

    func startMonitoring() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            self?.checkMemory()
        }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    private func checkMemory() {
        let usageMB = currentMemoryUsageMB()
        let cacheCount = ExploreGridImageCache.shared.count

        // 策略 1：内存超限，减半缓存
        if usageMB > memoryLimitMB {
            ExploreGridImageCache.shared.trim(to: cacheCountLimit / 2)
        }
        // 策略 2：缓存数量超限，裁剪 20%
        else if cacheCount > cacheCountLimit {
            let targetCount = Int(Double(cacheCount) * 0.8)
            ExploreGridImageCache.shared.trim(to: targetCount)
        }
    }

    private func currentMemoryUsageMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4

        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }

        if result == KERN_SUCCESS {
            return Double(info.resident_size) / 1024 / 1024
        }
        return 0
    }
}
