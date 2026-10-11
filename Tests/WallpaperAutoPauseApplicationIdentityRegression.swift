@main
struct WallpaperAutoPauseApplicationIdentityRegression {
    static func main() {
        let identity = WallpaperAutoPauseApplicationIdentity.self
        precondition(!identity.shouldInspectForeground("com.waifux.app"))
        precondition(!identity.shouldInspectForeground("com.waifux.app.helper"))
        print("PASS main UI and Helper remain one application for foreground pause")
        precondition(!identity.shouldInspectForeground("com.apple.finder"))
        precondition(identity.shouldInspectForeground("com.apple.Safari"))
        precondition(identity.shouldInspectForeground(nil))
        precondition(identity.shouldInspectForeground("com.waifux.app.other"))
        print("PASS Finder exclusion and unrelated or unknown app detection are preserved")

        let applications: [(bundleIdentifier: String?, processIdentifier: Int32)] = [
            ("com.waifux.app", 101), ("com.waifux.app", 102),
            ("com.waifux.app.helper", 201), ("com.apple.Safari", 301),
            (nil, 401), ("com.waifux.app.other", 501), ("com.waifux.app", -1)
        ]
        let excluded = identity.excludedProcessIDs(applications: applications, currentProcessIdentifier: 202)
        precondition(excluded == [101, 102, 201, 202])
        print("PASS a process snapshot excludes exact host and Helper identities only")
        for pid: Int32 in [101, 102, 201, 202] {
            precondition(!identity.isForeignContentWindow(ownerPID: pid, layer: 0, alpha: 1, excluding: excluded))
        }
        print("PASS main UI windows cannot trigger coverage pause or a false reliable snapshot")
        for pid: Int32 in [301, 401, 501] {
            precondition(identity.isForeignContentWindow(ownerPID: pid, layer: 0, alpha: 1, excluding: excluded))
        }
        precondition(!identity.isForeignContentWindow(ownerPID: 301, layer: -1, alpha: 1, excluding: excluded))
        precondition(!identity.isForeignContentWindow(ownerPID: 301, layer: 0, alpha: 0, excluding: excluded))
        print("PASS visible foreign content windows still count and desktop or transparent windows do not")
        let afterUIExit = identity.excludedProcessIDs(applications: [("com.apple.Safari", 101)], currentProcessIdentifier: 202)
        precondition(identity.isForeignContentWindow(ownerPID: 101, layer: 0, alpha: 1, excluding: afterUIExit))
        print("PASS later snapshots accept a reused former UI PID belonging to another app")
    }
}
