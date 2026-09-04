import Foundation

enum AppResponsivenessMonitor {
    private struct State {
        var heartbeat: UInt64 = 0
        var lastAckedHeartbeat: UInt64 = 0
        var currentTab: String = "unknown"
        var detailDepth: Int = 0
        var windowVisible: Bool = false
        var appActive: Bool = false
        var scenePhase: String = "launching"
    }

    private static let queue = DispatchQueue(label: "com.waifux.responsiveness-monitor", qos: .utility)
    private static let interval: TimeInterval = 1.0
    private static let stallThreshold: TimeInterval = 2.5
    nonisolated(unsafe) private static var timer: DispatchSourceTimer?
    nonisolated(unsafe) private static var state = State()
    nonisolated(unsafe) private static var started = false
    nonisolated(unsafe) private static var lastHeartbeatTime = Date()
    nonisolated(unsafe) private static var lastSnapshotTime = Date.distantPast
    nonisolated(unsafe) private static var lastStallLogTime = Date.distantPast
    nonisolated(unsafe) private static var lastForegroundActivationTime = Date.distantPast
    private static let foregroundSettleInterval: TimeInterval = 1.2

    static func startIfNeeded() {
        queue.async {
            guard !started else { return }
            started = true

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + interval, repeating: interval)
            timer.setEventHandler {
                state.heartbeat &+= 1
                let token = state.heartbeat

                // A hidden accessory app can be throttled or have its main run
                // loop parked by the system. Do not turn that expected state
                // into an ever-growing "main thread stall".
                if state.windowVisible || state.appActive {
                    DispatchQueue.main.async {
                        acknowledgeHeartbeat(token)
                    }
                } else {
                    resetHeartbeatBaseline(token: token)
                }

                evaluateStall()
            }
            self.timer = timer
            timer.resume()

            AppLogger.info(.general, "Responsiveness monitor started")
        }
    }

    static func noteTabChange(_ tab: String) {
        queue.async {
            state.currentTab = tab
            flushSnapshotIfNeeded(trigger: "tabChange", force: true)
        }
    }

    static func noteDetailDepth(_ depth: Int) {
        queue.async {
            state.detailDepth = depth
            flushSnapshotIfNeeded(trigger: "detailDepth")
        }
    }

    static func noteWindowVisible(_ visible: Bool) {
        queue.async {
            state.windowVisible = visible
            if !visible, !state.appActive {
                resetHeartbeatBaseline()
            }
            flushSnapshotIfNeeded(trigger: "windowVisible", force: true)
        }
    }

    static func noteAppActive(_ active: Bool) {
        queue.async {
            state.appActive = active
            if !active, !state.windowVisible {
                resetHeartbeatBaseline()
            }
            flushSnapshotIfNeeded(trigger: "appActive", force: true)
        }
    }

    static func noteForegroundActivation(reason: String) {
        queue.async {
            lastForegroundActivationTime = Date()
            flushSnapshotIfNeeded(trigger: "foregroundActivation", force: true)
        }
        AppLogger.debug(.ui, "Foreground activation noted", metadata: [
            "reason": reason
        ])
    }

    static var isForegroundSettling: Bool {
        queue.sync {
            Date().timeIntervalSince(lastForegroundActivationTime) < foregroundSettleInterval
        }
    }

    static func waitUntilForegroundSettles() async {
        while isForegroundSettling {
            try? await Task.sleep(nanoseconds: 60_000_000)
            guard !Task.isCancelled else { return }
        }
    }

    static func noteScenePhase(_ phase: String) {
        queue.async {
            state.scenePhase = phase
            flushSnapshotIfNeeded(trigger: "scenePhase", force: true)
        }
    }

    private static func acknowledgeHeartbeat(_ token: UInt64) {
        queue.async {
            state.lastAckedHeartbeat = token
            lastHeartbeatTime = Date()
        }
    }

    private static func resetHeartbeatBaseline(token: UInt64? = nil) {
        if let token {
            state.lastAckedHeartbeat = token
        } else {
            state.lastAckedHeartbeat = state.heartbeat
        }
        lastHeartbeatTime = Date()
        lastStallLogTime = Date()
    }

    private static func evaluateStall() {
        let now = Date()
        let snapshot = state
        let elapsed = now.timeIntervalSince(lastHeartbeatTime)

        guard snapshot.lastAckedHeartbeat != snapshot.heartbeat,
              elapsed >= stallThreshold else {
            if now.timeIntervalSince(lastSnapshotTime) >= 10 {
                lastSnapshotTime = now
                logSnapshot(trigger: "heartbeat", state: snapshot, elapsed: elapsed)
            }
            return
        }

        guard now.timeIntervalSince(lastStallLogTime) >= stallThreshold else { return }
        lastStallLogTime = now

        AppLogger.error(.ui, "Main thread stall suspected", metadata: [
            "stallMS": String(format: "%.0f", elapsed * 1000),
            "heartbeat": snapshot.heartbeat,
            "ackedHeartbeat": snapshot.lastAckedHeartbeat,
            "currentTab": snapshot.currentTab,
            "detailDepth": snapshot.detailDepth,
            "windowVisible": snapshot.windowVisible,
            "appActive": snapshot.appActive,
            "scenePhase": snapshot.scenePhase
        ])
    }

    private static func flushSnapshotIfNeeded(trigger: String, force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastSnapshotTime) >= 2 else { return }
        lastSnapshotTime = now
        let snapshot = state
        let elapsed = now.timeIntervalSince(lastHeartbeatTime)
        logSnapshot(trigger: trigger, state: snapshot, elapsed: elapsed)
    }

    private static func logSnapshot(trigger: String, state: State, elapsed: TimeInterval) {
        // AppLogger.debug(.ui, "Responsiveness snapshot", metadata: [
        //     "trigger": trigger,
        //     "heartbeat": state.heartbeat,
        //     "ackedHeartbeat": state.lastAckedHeartbeat,
        //     "mainThreadLagMS": String(format: "%.0f", elapsed * 1000),
        //     "currentTab": state.currentTab,
        //     "detailDepth": state.detailDepth,
        //     "windowVisible": state.windowVisible,
        //     "appActive": state.appActive,
        //     "scenePhase": state.scenePhase
        // ])
    }
}
