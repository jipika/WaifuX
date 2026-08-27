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

        print("Extension host playback policy regression passed")
    }
}
