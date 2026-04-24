import Foundation
import IOKit.pwr_mgt

/// 播放期间阻止系统息屏/休眠
@MainActor
final class SleepPreventer {
    static let shared = SleepPreventer()
    
    private var displayAssertionID: IOPMAssertionID = 0
    private var idleAssertionID: IOPMAssertionID = 0
    
    private init() {}
    
    /// 开始阻止息屏和休眠（播放视频时调用）
    func startPreventingSleep() {
        guard displayAssertionID == 0, idleAssertionID == 0 else { return }
        
        // 1. 阻止显示器关闭（核心：看视频不能黑屏）
        let displayResult = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "WaifuX 正在播放视频" as CFString,
            &displayAssertionID
        )
        
        // 2. 阻止系统因空闲进入睡眠（防止播到一半电脑睡了）
        let idleResult = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoIdleSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "WaifuX 正在播放视频" as CFString,
            &idleAssertionID
        )
        
        if displayResult == kIOReturnSuccess || idleResult == kIOReturnSuccess {
            print("[SleepPreventer] ✅ 已阻止系统息屏/休眠")
        }
    }
    
    /// 恢复系统正常息屏策略（停止播放时调用）
    func stopPreventingSleep() {
        var released = false
        
        if displayAssertionID != 0 {
            if IOPMAssertionRelease(displayAssertionID) == kIOReturnSuccess {
                displayAssertionID = 0
                released = true
            }
        }
        
        if idleAssertionID != 0 {
            if IOPMAssertionRelease(idleAssertionID) == kIOReturnSuccess {
                idleAssertionID = 0
                released = true
            }
        }
        
        if released {
            print("[SleepPreventer] ✅ 已恢复系统息屏/休眠")
        }
    }
}
