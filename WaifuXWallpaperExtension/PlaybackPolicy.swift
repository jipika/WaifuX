//  播放策略决策器 — 完整的阶梯式策略系统
//
//  参考 Phosphene (MIT) 的实现，增加了亮度阈值、游戏模式检测、
//  FPS 阶梯生成和 PowerMonitor 集成。

import Foundation

/// 壁纸播放行为策略枚举。
/// rawValue 越大越严格，支持 Comparable 比较。
enum PlaybackPolicy: Int, Sendable, Comparable {
    case full = 0
    case reduced = 1
    case minimal = 2
    case paused = 3

    static func < (lhs: PlaybackPolicy, rhs: PlaybackPolicy) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// WallpaperAgent updates the desktop and lock-screen instances separately.
    /// A covered desktop update must not replace the visible lock-screen policy.
    static func effectivePresentationMode(
        agentMode: String,
        isScreenLocked: Bool,
        hostUnavailable: Bool
    ) -> String {
        if hostUnavailable { return "active" }
        if isScreenLocked { return "locked" }
        // Unlock notifications can arrive before the agent updates its last
        // locked instance; do not keep playing that stale lock-screen mode.
        return agentMode == "locked" ? "default" : agentMode
    }

    /// 综合评估所有条件并返回最严格的适用策略。
    ///
    /// `alwaysPauseDesktop`: 为 true 时壁纸仅在锁屏播放。
    /// 桌面（解锁状态）时暂停并播放渐入/渐出动画。
    ///
    /// 锁屏页面不会自行降低 FPS — 只有电源/热条件才会。
    static func compute(
        presentationMode: String,
        activityState: String,
        userPaused: Bool,
        alwaysPauseDesktop: Bool,
        pauseWhenOccluded: Bool,
        desktopOccluded: Bool,
        thermalState: ProcessInfo.ThermalState,
        isOnBattery: Bool,
        batteryLevel: Int,
        isGameModeActive: Bool = false,
        displayBrightness: Float = 1.0,
        isLowPowerMode: Bool = false,
        pauseOnBattery: Bool = false
    ) -> PlaybackPolicy {
        var worst: PlaybackPolicy = .full

        // --- paused 层级 ---
        if userPaused { worst = max(worst, .paused) }
        if thermalState == .critical { worst = max(worst, .paused) }
        if batteryLevel < 10 { worst = max(worst, .paused) }
        if activityState.contains("suspended") { worst = max(worst, .paused) }
        if presentationMode == "idle" { worst = max(worst, .paused) }
        if isGameModeActive { worst = max(worst, .paused) }
        // 用户主动开启「使用电池时暂停」后，电池供电与系统低功耗模式都直接暂停。
        // 这是用户已经打开的省电开关的语义，扩展此前只做 .reduced（且没有实际降帧）。
        if pauseOnBattery, isOnBattery || isLowPowerMode { worst = max(worst, .paused) }
        // 用户将背光调到 ~0。显示器技术上仍"唤醒"所以 screensDidSleep 不会触发，
        // WallpaperAgent 也不会切换到 "idle"，但用户看不到任何画面。
        if displayBrightness < PowerMonitor.PowerState.brightnessPauseThreshold {
            worst = max(worst, .paused)
        }
        // 桌面遮挡与锁屏无关 — 锁屏上壁纸始终完全可见。
        if pauseWhenOccluded, desktopOccluded, presentationMode != "locked" { worst = max(worst, .paused) }
        if alwaysPauseDesktop, presentationMode != "locked" { worst = max(worst, .paused) }

        // --- minimal 层级 ---
        if thermalState == .serious { worst = max(worst, .minimal) }
        if isOnBattery, batteryLevel < 20 { worst = max(worst, .minimal) }

        // --- reduced 层级 ---
        if thermalState == .fair { worst = max(worst, .reduced) }
        if isOnBattery { worst = max(worst, .reduced) }

        return worst
    }

    /// 从源帧率生成 FPS 阶梯。
    ///
    /// 反复减半直到结果 ≤ 15 fps。始终生成至少 2 个阶梯。
    /// 示例: 120 → [120, 60, 30, 15], 60 → [60, 30, 15], 30 → [30, 15], 24 → [24, 12]
    static func fpsTiers(from sourceFPS: Int) -> [Int] {
        guard sourceFPS > 0 else { return [] }
        var tiers = [sourceFPS]
        var current = sourceFPS
        while current > 15 {
            current /= 2
            tiers.append(current)
        }
        if tiers.count < 2 {
            tiers.append(current / 2)
        }
        return tiers
    }

    /// 便捷重载，解包 `PowerMonitor.PowerState`。
    static func compute(
        presentationMode: String,
        activityState: String,
        userPaused: Bool,
        alwaysPauseDesktop: Bool,
        pauseWhenOccluded: Bool,
        desktopOccluded: Bool,
        powerState: PowerMonitor.PowerState,
        pauseOnBattery: Bool = false
    ) -> PlaybackPolicy {
        compute(
            presentationMode: presentationMode,
            activityState: activityState,
            userPaused: userPaused,
            alwaysPauseDesktop: alwaysPauseDesktop,
            pauseWhenOccluded: pauseWhenOccluded,
            desktopOccluded: desktopOccluded,
            thermalState: powerState.thermalState,
            isOnBattery: powerState.isOnBattery,
            batteryLevel: powerState.batteryLevel,
            isGameModeActive: powerState.isGameModeActive,
            displayBrightness: powerState.displayBrightness,
            isLowPowerMode: powerState.isLowPowerMode,
            pauseOnBattery: pauseOnBattery
        )
    }
}
