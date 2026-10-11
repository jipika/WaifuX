// Consecutive playback failures retry slowly and stop at a finite limit.
// Successful media delivery resets the budget; an empty/failed reader does not.
struct VideoPlaybackRecoveryPolicy: Sendable {
    enum Decision: Equatable, Sendable {
        case retry(after: Double)
        case stop
    }

    private(set) var consecutiveFailures = 0
    let maximumRetries: Int

    init(maximumRetries: Int = 5) { self.maximumRetries = maximumRetries }

    static func canContinueLoop(completed: Bool, deliveredValidFrame: Bool, timelineAdvanced: Bool) -> Bool {
        completed && deliveredValidFrame && timelineAdvanced
    }

    mutating func recordFailure() -> Decision {
        consecutiveFailures += 1
        guard consecutiveFailures <= maximumRetries else { return .stop }
        return .retry(after: 0.5 * Double(1 << min(4, max(0, consecutiveFailures - 1))))
    }

    mutating func recordSuccessfulFrame() { consecutiveFailures = 0 }
}
