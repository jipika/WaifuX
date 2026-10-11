import Foundation
import IOKit.pwr_mgt

/// 阻止系统息屏 / 空闲休眠。
///
/// 支持多来源叠加：用户「永不休眠」设置与媒体播放可同时持有。
/// 仅当全部来源释放后，才恢复系统默认息屏策略。
@MainActor
final class SleepPreventer {
    static let shared = SleepPreventer()

    enum Reason: Hashable {
        /// 通用设置中的「永不休眠」开关
        case userSetting
        /// 番剧 / 视频播放期间
        case mediaPlayback
    }

    private var activeReasons: Set<Reason> = []
    private var displayAssertionID: IOPMAssertionID = 0
    private var idleAssertionID: IOPMAssertionID = 0

    private init() {}

    // MARK: - Public API

    /// 按来源开启 / 关闭阻止休眠。同一来源重复调用是幂等的。
    func setPreventingSleep(_ enabled: Bool, reason: Reason) {
        if BackgroundRuntimeRole.isRemoteUI, reason == .userSetting {
            BackgroundRuntimeBridge.send("sleep.userSetting", ["enabled": enabled]); return
        }

        if enabled {
            activeReasons.insert(reason)
        } else {
            activeReasons.remove(reason)
        }
        syncAssertions()
    }

    /// 播放视频时调用（兼容既有调用点）
    func startPreventingSleep() {
        setPreventingSleep(true, reason: .mediaPlayback)
    }

    /// 停止播放时调用（兼容既有调用点；不会影响用户设置持有的 assertion）
    func stopPreventingSleep() {
        setPreventingSleep(false, reason: .mediaPlayback)
    }

    // MARK: - Assertion lifecycle

    private func syncAssertions() {
        if activeReasons.isEmpty {
            releaseAssertions()
        } else {
            acquireAssertionsIfNeeded()
        }
    }

    private func acquireAssertionsIfNeeded() {
        guard displayAssertionID == 0, idleAssertionID == 0 else { return }

        let reasonText = assertionReasonText() as CFString

        // 1. 阻止显示器关闭（锁屏 / 壁纸持续显示）
        let displayResult = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reasonText,
            &displayAssertionID
        )

        // 2. 阻止系统因空闲进入睡眠
        let idleResult = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoIdleSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reasonText,
            &idleAssertionID
        )

        if displayResult == kIOReturnSuccess || idleResult == kIOReturnSuccess {
            print("[SleepPreventer] ✅ 已阻止系统息屏/休眠 reasons=\(activeReasons)")
        } else {
            displayAssertionID = 0
            idleAssertionID = 0
            print("[SleepPreventer] ⚠️ 创建电源 assertion 失败")
        }
    }

    private func releaseAssertions() {
        var released = false

        if displayAssertionID != 0 {
            if IOPMAssertionRelease(displayAssertionID) == kIOReturnSuccess {
                released = true
            }
            displayAssertionID = 0
        }

        if idleAssertionID != 0 {
            if IOPMAssertionRelease(idleAssertionID) == kIOReturnSuccess {
                released = true
            }
            idleAssertionID = 0
        }

        if released {
            print("[SleepPreventer] ✅ 已恢复系统息屏/休眠")
        }
    }

    private func assertionReasonText() -> String {
        if activeReasons.contains(.userSetting) {
            return "WaifuX 永不休眠"
        }
        return "WaifuX 正在播放视频"
    }
}
