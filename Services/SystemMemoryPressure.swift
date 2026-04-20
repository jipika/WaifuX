import Darwin
import Foundation

/// 基于 `host_statistics64` 的近似可回收内存，用于避免在内存紧张时启动 Scene 分析 / 离线烘焙。
enum SystemMemoryPressure {
    private static func kernelPageSize() -> vm_size_t {
        var sz: vm_size_t = 0
        let kr = host_page_size(mach_host_self(), &sz)
        if kr != KERN_SUCCESS || sz == 0 {
            return 4096
        }
        return sz
    }

    /// 近似「可被系统较快拨给新分配」的页：free + inactive + speculative + purgeable（字节）。
    static func approximateReclaimableBytes() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            UInt32(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        )
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let page = UInt64(kernelPageSize())
        let pages =
            UInt64(stats.free_count)
            + UInt64(stats.inactive_count)
            + UInt64(stats.speculative_count)
            + UInt64(stats.purgeable_count)
        return pages &* page
    }

    /// `SceneBakeEligibilityAnalyzer` 可能整包读入 `scene.pkg`。
    static let minBytesForEligibilityAnalysis: UInt64 = 480 * 1024 * 1024

    /// CLI 烘焙子进程与编码峰值。
    static let minBytesForOfflineBake: UInt64 = 1024 * 1024 * 1024

    static func hasRoomForSceneEligibilityAnalysis() -> Bool {
        approximateReclaimableBytes() >= minBytesForEligibilityAnalysis
    }

    static func hasRoomForSceneOfflineBake() -> Bool {
        approximateReclaimableBytes() >= minBytesForOfflineBake
    }
}
