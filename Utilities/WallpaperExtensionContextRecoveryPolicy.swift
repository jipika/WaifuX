import Foundation

/// Pure decisions for a live extension which acknowledged the current source as pending,
/// but has no context. The caller alone supplies real, matching source_pending evidence;
/// a timeout, an idle extension or an old state file must never manufacture Evidence.
/// No registration, process control, preferences, clocks or system selection occurs here.
enum WallpaperExtensionContextRecoveryPolicy {
    static let startupGrace: TimeInterval = 0
    static let confirmationWindow: TimeInterval = 1
    static let verifyWindow: TimeInterval = 20
    static let stableWindow: TimeInterval = 2
    static let minimumAttemptInterval: TimeInterval = 0
    static let maximumBackoff: TimeInterval = 60
    static let failureBackoffs: [TimeInterval] = [2, 5, 15, 30, 60]
    /// Only the first two attempts of an unverified episode may be close together.
    static let repeatedFailureMinimumBackoff: TimeInterval = 15

    struct Evidence: Equatable, Sendable {
        let displayID: UInt32
        let requestID: String
        let pid: Int32
        /// Monotonic time when the caller first received matching source_pending.
        /// Preserve this value for the same evidence; do not refresh it on every poll.
        let firstObserved: TimeInterval
    }

    /// Capture this token with .restartAgent before invoking the controlled restart executor.
    /// Evidence alone is insufficient: a retry may use exactly the same evidence.
    struct Submission: Equatable, Sendable {
        let id: UInt64
        let evidence: Evidence
    }

    enum Action: Equatable, Sendable {
        case none
        case restartAgent(Evidence)
        case recovered
        case verificationFailed
    }

    struct State: Sendable {
        private(set) var observingSince: TimeInterval?
        private(set) var retryNotBefore: TimeInterval
        private(set) var failureCount = 0
        private(set) var pendingSince: TimeInterval?
        private(set) var pendingSubmission: Submission?
        private var submittedAt: TimeInterval?
        private var nextSubmissionID: UInt64 = 0
        private var lastNow: TimeInterval?
        private var candidate: Evidence?
        private var candidateSince: TimeInterval?
        private var candidateSamples = 0
        private var candidateLastSample: TimeInterval?
        private var verificationPID: Int32?
        private var verificationSince: TimeInterval?
        private var verificationSamples = 0
        private var verificationLastSample: TimeInterval?

        /// The injected deadline must already be in this process's monotonic clock domain.
        /// Convert any persisted wall-clock deadline outside this pure policy.
        init(retryNotBefore: TimeInterval = 0) {
            self.retryNotBefore = retryNotBefore.isNaN ? .infinity : max(0, retryNotBefore)
        }

        /// Call at Helper monitoring startup; first observe also begins this grace lazily.
        mutating func beginObservation(at now: TimeInterval) {
            guard validTime(now), observingSince == nil else { return }
            observingSince = now
        }

        /// nil livePIDs means unknown, not empty. Only one definite, matching PID can
        /// confirm missing context. During verification the PID may change, but stability
        /// must restart. hasActiveContext must mean fresh contexts written after this attempt;
        /// sourceReady must come from the current request's real source_ready receipt. The
        /// caller must not supply cached flags or stale callbacks as new observations.
        /// Evidence may become nil after source_ready; call requestChanged() synchronously
        /// when the current request changes even if its new source_pending has not arrived.
        mutating func observe(
            evidence: Evidence?, selected: Bool, livePIDs: [Int32]?,
            hasActiveContext: Bool, sourceReady: Bool, now: TimeInterval,
            recoveryInProgress: Bool
        ) -> Action {
            guard acceptTime(now) else { return .none }
            beginObservation(at: now)
            guard selected else {
                requestChanged()
                return .none
            }

            if let pending = pendingSubmission, let evidence,
               !sameRequest(pending.evidence, evidence) {
                requestChanged()
            }
            if let pendingSince {
                // Submission time cannot extend the window, and late samples cannot
                // inherit stability from an already-expired verification.
                if now > pendingSince + WallpaperExtensionContextRecoveryPolicy.verifyWindow {
                    return failPending(now: now)
                }
                if let submittedAt, now > submittedAt, !recoveryInProgress,
                   evidence.map({ validEvidence($0, now: now) }) ?? true,
                   let pid = singlePID(livePIDs), hasActiveContext, sourceReady {
                    if verificationPID != pid {
                        resetVerification()
                        verificationPID = pid
                        verificationSince = now
                    }
                    if verificationLastSample.map({ now > $0 }) ?? true {
                        verificationLastSample = now
                        verificationSamples = min(2, verificationSamples + 1)
                    }
                    if verificationSamples >= 2, let verificationSince,
                       now - verificationSince >= WallpaperExtensionContextRecoveryPolicy.stableWindow {
                        failureCount = 0
                        retryNotBefore = 0
                        endPending()
                        resetCandidate()
                        return .recovered
                    }
                } else {
                    resetVerification()
                }
                if now - pendingSince >= WallpaperExtensionContextRecoveryPolicy.verifyWindow {
                    return failPending(now: now)
                }
                return .none
            }

            guard !recoveryInProgress, !hasActiveContext, !sourceReady,
                  let evidence, validEvidence(evidence, now: now),
                  singlePID(livePIDs) == evidence.pid else {
                resetCandidate()
                return .none
            }
            if candidate != evidence {
                resetCandidate()
                candidate = evidence
                candidateSince = now
            }
            if candidateLastSample.map({ now > $0 }) ?? true {
                candidateLastSample = now
                candidateSamples = min(2, candidateSamples + 1)
            }
            guard candidateSamples >= 2, let candidateSince, let observingSince,
                  now - candidateSince >= WallpaperExtensionContextRecoveryPolicy.confirmationWindow,
                  now - observingSince >= WallpaperExtensionContextRecoveryPolicy.startupGrace,
                  now >= retryNotBefore else { return .none }

            nextSubmissionID &+= 1
            pendingSubmission = Submission(id: nextSubmissionID, evidence: evidence)
            pendingSince = now
            submittedAt = nil
            resetCandidate()
            resetVerification()
            return .restartAgent(evidence)
        }

        /// A receipt is accepted only once, for this exact attempt and before its deadline.
        /// Successful submission is not recovery; only later observe samples can prove it.
        /// An ignored late/stale/duplicate receipt returns .none without changing state.
        @discardableResult
        mutating func finishSubmission(
            _ submission: Submission, succeeded: Bool, now: TimeInterval
        ) -> Action {
            guard pendingSubmission == submission, submittedAt == nil,
                  let pendingSince, acceptTime(now) else { return .none }
            guard now < pendingSince + WallpaperExtensionContextRecoveryPolicy.verifyWindow else {
                return failPending(now: now)
            }
            guard succeeded else { return failPending(now: now) }
            submittedAt = now
            resetVerification()
            return .none
        }

        /// Executor or current-source rejection can arrive after successful submission.
        /// This is a terminal verification failure, not a second submission receipt.
        /// Cancelled/old tokens must not mutate the clock, count or failure deadline.
        @discardableResult
        mutating func requestFailed(_ submission: Submission, now: TimeInterval) -> Action {
            guard pendingSubmission == submission, acceptTime(now) else { return .none }
            return failPending(now: now)
        }

        /// Cancel on a new request, withdrawn source or display removal, including changes
        /// with no Evidence. Keep grace and rate limits; a new request cannot bypass them.
        mutating func requestChanged() {
            endPending()
            resetCandidate()
        }

        /// Disable/stop invalidates all receipts and starts fresh observation on resume.
        /// The deadline, failure count and submission serial deliberately survive.
        mutating func suspend() {
            requestChanged()
            observingSince = nil
            lastNow = nil
        }

        private func validTime(_ now: TimeInterval) -> Bool {
            now.isFinite && now >= 0
        }

        private mutating func acceptTime(_ now: TimeInterval) -> Bool {
            guard validTime(now), lastNow.map({ now >= $0 }) ?? true else {
                resetCandidate()
                resetVerification()
                return false
            }
            lastNow = now
            return true
        }

        private func validEvidence(_ evidence: Evidence, now: TimeInterval) -> Bool {
            evidence.pid > 0 && !evidence.requestID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && validTime(evidence.firstObserved) && evidence.firstObserved <= now
        }

        private func sameRequest(_ lhs: Evidence, _ rhs: Evidence) -> Bool {
            lhs.displayID == rhs.displayID && lhs.requestID == rhs.requestID
        }

        private func singlePID(_ pids: [Int32]?) -> Int32? {
            guard let pids, pids.count == 1, let pid = pids.first, pid > 0 else { return nil }
            return pid
        }

        private mutating func failPending(now: TimeInterval) -> Action {
            guard pendingSubmission != nil else { return .none }
            endPending()
            resetCandidate()
            let backoffs = WallpaperExtensionContextRecoveryPolicy.failureBackoffs
            failureCount = min(failureCount + 1, backoffs.count)
            let scheduledDelay = backoffs[failureCount - 1]
            // A second failed attempt exhausts the episode's two fast attempts. Raise
            // its nominal five-second delay to fifteen; request/suspend cannot reset it.
            let episodeFloor: TimeInterval = failureCount >= 2
                ? WallpaperExtensionContextRecoveryPolicy.repeatedFailureMinimumBackoff : 0
            let delay = min(max(scheduledDelay, episodeFloor), WallpaperExtensionContextRecoveryPolicy.maximumBackoff)
            retryNotBefore = max(retryNotBefore, now + delay)
            return .verificationFailed
        }

        private mutating func endPending() {
            pendingSince = nil
            pendingSubmission = nil
            submittedAt = nil
            resetVerification()
        }

        private mutating func resetCandidate() {
            candidate = nil
            candidateSince = nil
            candidateSamples = 0
            candidateLastSample = nil
        }

        private mutating func resetVerification() {
            verificationPID = nil
            verificationSince = nil
            verificationSamples = 0
            verificationLastSample = nil
        }
    }
}
