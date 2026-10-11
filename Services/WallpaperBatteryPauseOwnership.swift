/// Tracks whether the battery policy paused the external engine. Repeated
/// policy checks must retain ownership of a pause they already requested.
struct WallpaperBatteryPauseOwnership {
    private(set) var ownsPause = false

    /// Returns true only when the caller needs to send a pause command.
    mutating func requestPause(isManagingEngine: Bool, isPaused: Bool) -> Bool {
        guard isManagingEngine else { reset(); return false }
        guard !isPaused else { return false }
        ownsPause = true
        return true
    }

    /// Returns true if this policy owns the pause being released. A preexisting
    /// manual pause is never claimed, so it is not resumed on AC power.
    mutating func release() -> Bool {
        let owned = ownsPause
        reset()
        return owned
    }

    mutating func reset() { ownsPause = false }
}
