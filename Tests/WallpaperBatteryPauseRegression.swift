@main
struct WallpaperBatteryPauseRegression {
    static func main() {
        var policy = WallpaperBatteryPauseOwnership()
        var enginePaused = false
        var pauseCommands = 0
        for _ in 0..<10 {
            if policy.requestPause(isManagingEngine: true, isPaused: enginePaused) {
                pauseCommands += 1
                enginePaused = true
            }
        }
        precondition(enginePaused && pauseCommands == 1 && policy.ownsPause)
        print("PASS repeated battery checks retain pause ownership without extra commands")
        if policy.release() { enginePaused = false }
        precondition(!enginePaused)
        print("PASS AC power resumes the engine paused by the battery policy")
        precondition(!policy.release())
        print("PASS repeated AC checks do not issue another resume")

        enginePaused = true
        for _ in 0..<10 {
            precondition(!policy.requestPause(isManagingEngine: true, isPaused: enginePaused))
        }
        precondition(!policy.release() && enginePaused)
        print("PASS a preexisting manual or other policy pause survives AC power")

        enginePaused = false
        precondition(policy.requestPause(isManagingEngine: true, isPaused: enginePaused))
        precondition(!policy.requestPause(isManagingEngine: false, isPaused: true))
        precondition(!policy.release())
        print("PASS a removed external engine clears stale pause ownership")
        precondition(!policy.requestPause(isManagingEngine: true, isPaused: true))
        precondition(!policy.release())
        print("PASS a replacement engine already paused is not accidentally resumed")

        precondition(policy.requestPause(isManagingEngine: true, isPaused: false))
        precondition(policy.requestPause(isManagingEngine: true, isPaused: false))
        precondition(policy.release())
        print("PASS a wake recovery that resumes playback can be paused again and later restored")
    }
}
