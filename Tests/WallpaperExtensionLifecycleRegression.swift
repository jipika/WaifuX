@main
struct WallpaperExtensionLifecycleRegression {
    static func main() {
        var contexts = WallpaperContextGeneration()
        let desktop = contexts.begin(11)
        let lockScreen = contexts.begin(12)
        precondition(contexts.isCurrent(desktop, for: 11) && contexts.isCurrent(lockScreen, for: 12))
        print("PASS desktop and lock screen contexts remain independently valid")

        contexts.remove(11)
        precondition(!contexts.isCurrent(desktop, for: 11) && contexts.isCurrent(lockScreen, for: 12))
        print("PASS connection invalidation rejects late setup without invalidating another connection")

        let reused = contexts.begin(11)
        precondition(reused != desktop && !contexts.isCurrent(desktop, for: 11) && contexts.isCurrent(reused, for: 11))
        print("PASS a reused context ID cannot admit a previous generation")

        let firstVideo = contexts.begin(11)
        let newerVideo = contexts.begin(11)
        precondition(!contexts.isCurrent(firstVideo, for: 11) && contexts.isCurrent(newerVideo, for: 11))
        print("PASS out of order video setup admits only the latest request")

        let staticImage = contexts.begin(11)
        precondition(!contexts.isCurrent(newerVideo, for: 11) && contexts.isCurrent(staticImage, for: 11))
        print("PASS switching to an image invalidates a pending video setup")

        contexts.finish(newerVideo, for: 11)
        precondition(contexts.isPending(staticImage, for: 11))
        print("PASS an obsolete completion cannot mark the newer setup finished")

        contexts.finish(staticImage, for: 11)
        precondition(!contexts.isPending(staticImage, for: 11) && contexts.isCurrent(staticImage, for: 11))
        print("PASS completion before task retention leaves no retained completed task")

        contexts.removeAll()
        precondition(!contexts.isCurrent(staticImage, for: 11) && !contexts.isCurrent(lockScreen, for: 12))
        print("PASS clearing all contexts rejects every outstanding completion")

        let restarted = contexts.begin(11)
        precondition(restarted != staticImage && !contexts.isCurrent(staticImage, for: 11))
        print("PASS restart after clearing cannot revive a previous token")

        let owner = contexts.admit(21)
        let replacement = contexts.begin(21)
        precondition(contexts.isOwned(by: owner, contextID: 21) && contexts.isCurrent(replacement, for: 21))
        print("PASS media replacement preserves the creating connection ownership")
        let replacementOwner = contexts.admit(21)
        precondition(!contexts.isOwned(by: owner, contextID: 21) && contexts.isOwned(by: replacementOwner, contextID: 21))
        print("PASS an obsolete connection cannot reclaim another connection's reused ID")
        contexts.remove(21)
        precondition(!contexts.isOwned(by: replacementOwner, contextID: 21))
        print("PASS releasing a context clears its connection ownership")

        var recovery = VideoPlaybackRecoveryPolicy()
        for expected in [0.5, 1.0, 2.0, 4.0, 8.0] {
            precondition(recovery.recordFailure() == .retry(after: expected))
        }
        precondition(recovery.recordFailure() == .stop)
        print("PASS persistent playback failures have five retries with exponential backoff")

        for _ in 0..<100 { precondition(recovery.recordFailure() == .stop) }
        print("PASS further failure callbacks cannot restart an exhausted retry budget")

        recovery.recordSuccessfulFrame()
        precondition(recovery.recordFailure() == .retry(after: 0.5))
        print("PASS actual successful rendering restores the recovery budget")

        precondition(!VideoPlaybackRecoveryPolicy.canContinueLoop(completed: false, deliveredValidFrame: true, timelineAdvanced: true))
        print("PASS failed and cancelled readers cannot enter a seamless loop")
        precondition(!VideoPlaybackRecoveryPolicy.canContinueLoop(completed: true, deliveredValidFrame: false, timelineAdvanced: false))
        print("PASS an empty or entirely invalid sample stream cannot spin through loops")
        precondition(!VideoPlaybackRecoveryPolicy.canContinueLoop(completed: true, deliveredValidFrame: true, timelineAdvanced: false))
        print("PASS a non advancing timeline cannot repeatedly create readers")
        precondition(VideoPlaybackRecoveryPolicy.canContinueLoop(completed: true, deliveredValidFrame: true, timelineAdvanced: true))
        print("PASS a completed valid timeline retains seamless looping")

        var noRetries = VideoPlaybackRecoveryPolicy(maximumRetries: 0)
        precondition(noRetries.recordFailure() == .stop)
        print("PASS a zero retry budget stops on the first failure")
    }
}
