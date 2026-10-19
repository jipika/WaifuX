import Foundation

@main
struct ExtensionHostPlaybackPolicyRegression {
    static func main() {
        let appManagedDesktop = PlaybackPolicy.compute(
            presentationMode: "active",
            activityState: "active",
            userPaused: false,
            alwaysPauseDesktop: true,
            pauseWhenOccluded: false,
            desktopOccluded: false,
            thermalState: .nominal,
            isOnBattery: false,
            batteryLevel: 100,
            isGameModeActive: false,
            displayBrightness: 1.0
        )
        precondition(appManagedDesktop == .paused)

        let extensionOwnedDesktop = PlaybackPolicy.compute(
            presentationMode: "active",
            activityState: "active",
            userPaused: false,
            alwaysPauseDesktop: false,
            pauseWhenOccluded: false,
            desktopOccluded: false,
            thermalState: .nominal,
            isOnBattery: false,
            batteryLevel: 100,
            isGameModeActive: false,
            displayBrightness: 1.0
        )
        precondition(extensionOwnedDesktop == .full)

        let lockedWallpaper = PlaybackPolicy.compute(
            presentationMode: "locked",
            activityState: "active",
            userPaused: false,
            alwaysPauseDesktop: true,
            pauseWhenOccluded: false,
            desktopOccluded: false,
            thermalState: .nominal,
            isOnBattery: false,
            batteryLevel: 100,
            isGameModeActive: false,
            displayBrightness: 1.0
        )
        precondition(lockedWallpaper == .full)

        // WallpaperAgent may update the covered desktop instance immediately
        // after the lock-screen instance. That update must not pause the lock.
        let modeAfterDesktopUpdate = PlaybackPolicy.effectivePresentationMode(
            agentMode: "default", isScreenLocked: true, hostUnavailable: false
        )
        precondition(modeAfterDesktopUpdate == "locked")
        let policyAfterDesktopUpdate = PlaybackPolicy.compute(
            presentationMode: modeAfterDesktopUpdate,
            activityState: "active",
            userPaused: false,
            alwaysPauseDesktop: true,
            pauseWhenOccluded: false,
            desktopOccluded: false,
            thermalState: .nominal,
            isOnBattery: false,
            batteryLevel: 100,
            isGameModeActive: false,
            displayBrightness: 1.0
        )
        precondition(policyAfterDesktopUpdate == .full)
        precondition(PlaybackPolicy.effectivePresentationMode(
            agentMode: "default", isScreenLocked: false, hostUnavailable: false
        ) == "default")
        precondition(PlaybackPolicy.effectivePresentationMode(
            agentMode: "locked", isScreenLocked: false, hostUnavailable: false
        ) == "default")
        precondition(PlaybackPolicy.effectivePresentationMode(
            agentMode: "idle", isScreenLocked: false, hostUnavailable: true
        ) == "active")

        // 「使用电池时暂停」开关镜像：只有用户开启后才允许电池/低功耗模式暂停。
        let batteryPauseOnBattery = PlaybackPolicy.compute(
            presentationMode: "active",
            activityState: "active",
            userPaused: false,
            alwaysPauseDesktop: false,
            pauseWhenOccluded: false,
            desktopOccluded: false,
            thermalState: .nominal,
            isOnBattery: true,
            batteryLevel: 100,
            isGameModeActive: false,
            displayBrightness: 1.0,
            pauseOnBattery: true
        )
        precondition(batteryPauseOnBattery == .paused)

        let batteryPauseOffBattery = PlaybackPolicy.compute(
            presentationMode: "active",
            activityState: "active",
            userPaused: false,
            alwaysPauseDesktop: false,
            pauseWhenOccluded: false,
            desktopOccluded: false,
            thermalState: .nominal,
            isOnBattery: true,
            batteryLevel: 100,
            isGameModeActive: false,
            displayBrightness: 1.0,
            pauseOnBattery: false
        )
        precondition(batteryPauseOffBattery == .reduced)

        // 低功耗模式与电源来源独立：插电但开启 LPM 时，用户开关同样生效。
        let lowPowerModePause = PlaybackPolicy.compute(
            presentationMode: "active",
            activityState: "active",
            userPaused: false,
            alwaysPauseDesktop: false,
            pauseWhenOccluded: false,
            desktopOccluded: false,
            thermalState: .nominal,
            isOnBattery: false,
            batteryLevel: 100,
            isGameModeActive: false,
            displayBrightness: 1.0,
            isLowPowerMode: true,
            pauseOnBattery: true
        )
        precondition(lowPowerModePause == .paused)

        // 开关打开但插电且未开 LPM：保持原行为（不暂停）。
        let batteryPauseOnAC = PlaybackPolicy.compute(
            presentationMode: "active",
            activityState: "active",
            userPaused: false,
            alwaysPauseDesktop: false,
            pauseWhenOccluded: false,
            desktopOccluded: false,
            thermalState: .nominal,
            isOnBattery: false,
            batteryLevel: 100,
            isGameModeActive: false,
            displayBrightness: 1.0,
            pauseOnBattery: true
        )
        precondition(batteryPauseOnAC == .full)

        print("Extension host playback policy regression passed")
    }
}
