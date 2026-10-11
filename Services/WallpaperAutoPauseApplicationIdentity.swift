/// Auto-pause treats the main interface and background Helper as one app.
/// Bundle identity is used instead of process names, which can be ambiguous.
enum WallpaperAutoPauseApplicationIdentity {
    static func isWaifuX(_ bundleIdentifier: String?) -> Bool {
        bundleIdentifier == "com.waifux.app" || bundleIdentifier == "com.waifux.app.helper"
    }

    static func shouldInspectForeground(_ bundleIdentifier: String?) -> Bool {
        !isWaifuX(bundleIdentifier) && bundleIdentifier != "com.apple.finder"
    }

    static func excludedProcessIDs(
        applications: [(bundleIdentifier: String?, processIdentifier: Int32)],
        currentProcessIdentifier: Int32
    ) -> Set<Int32> {
        var result: Set<Int32> = [currentProcessIdentifier]
        for application in applications where isWaifuX(application.bundleIdentifier) && application.processIdentifier > 0 {
            result.insert(application.processIdentifier)
        }
        return result
    }

    static func isForeignContentWindow(
        ownerPID: Int32, layer: Int, alpha: Double, excluding processIDs: Set<Int32>
    ) -> Bool {
        !processIDs.contains(ownerPID) && layer == 0 && alpha > 0
    }
}
