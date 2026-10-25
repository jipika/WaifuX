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

                // 先判定，再决定回执还是重设基线：顺序不能反，否则「活跃期已经开始、
                // 随后才失活」的卡顿会在重设基线时被洗掉。
                evaluateStall()

                // 只有应用真正活跃时，主队列回执迟到才算主线程卡顿。
                // 失活/后台状态下系统会节流应用或让主 runloop 停在嵌套事件循环里，
                // 回执迟到是预期行为：实测 244 条 stall 记录里 204 条处于 appActive=false，
                // 栈样本 846 帧全部停在 mach_msg2_trap（等事件，不是在算）。
                if isStallSamplingEligible {
                    DispatchQueue.main.async {
                        acknowledgeHeartbeat(token)
                    }
                } else {
                    resetHeartbeatBaseline(token: token)
                }
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
            if !visible {
                // 隐窗前最后判一次，避免把「隐窗后主队列不再被排空」的等待算成卡顿。
                evaluateStall()
            }
            resetHeartbeatBaseline()
            flushSnapshotIfNeeded(trigger: "windowVisible", force: true)
        }
    }

    static func noteAppActive(_ active: Bool) {
        queue.async {
            state.appActive = active
            if !active {
                // 失活前最后判一次：活跃期已开始的卡顿不能被基线重设洗掉。
                evaluateStall()
            }
            // 恢复活跃时也重设：清掉失活期间累积的差值，避免整段后台时间
            // 在回到前台后被算成一次「卡顿」。
            resetHeartbeatBaseline()
            flushSnapshotIfNeeded(trigger: "appActive", force: true)
        }
    }

    static func noteForegroundActivation(reason: String) {
        queue.async {
            lastForegroundActivationTime = Date()
            flushSnapshotIfNeeded(trigger: "foregroundActivation", force: true)
        }
        AppLogger.throttled(.debug, .ui, key: "ui.foregroundActivation", interval: 60,
                            "Foreground activation noted", metadata: [
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

    /// 是否允许把「主队列回执迟到」判定为主线程卡顿。
    ///
    /// 失活/后台时（`didResignActive`、窗口不在前台），系统会节流应用或把主 runloop
    /// 停在嵌套事件循环里，主队列回执迟到是预期行为而非卡顿。只有应用活跃、
    /// 且不处于失活瞬间时才采样。
    private static var isStallSamplingEligible: Bool {
        state.appActive && state.scenePhase != "didResignActive"
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
        captureMainThreadSample(stallMS: elapsed * 1000)
    }

    /// stall 时用系统 sample 对自己抓 1 秒采样，把主线程调用栈顶帧写进日志。
    /// 没有这一步，「卡在哪」只能靠猜（stat 外置卷 / 同步写壁纸 / body 重算
    /// 的日志特征完全相同）；有了栈帧，一次导出即可定案根因。
    /// 采样期间主线程若已恢复，栈顶会显示 idle 等待——同样是有价值的证据。
    ///
    /// 每次采样都会 spawn 一个 `/usr/bin/sample` 子进程并抓 1 秒栈，连续卡顿时
    /// 会放大负载。这里 10 分钟最多采一次；其余卡顿仍由 `logSnapshot` 记录。
    private static func captureMainThreadSample(stallMS: Double) {
        guard AppLogger.shouldThrottle(key: "ui.stallSample", interval: 600) else { return }
        let samplePath = "/tmp/waifux-stall-sample-\(Int(Date().timeIntervalSince1970)).txt"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        task.arguments = [
            String(ProcessInfo.processInfo.processIdentifier),
            "1", "-mayDie", "-file", samplePath
        ]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        DispatchQueue.global(qos: .utility).async {
            task.waitUntilExit()
            guard let text = try? String(contentsOfFile: samplePath, encoding: .utf8) else {
                AppLogger.error(.ui, "Main thread stall sample unavailable", metadata: [
                    "stallMS": String(format: "%.0f", stallMS),
                    "sampleExit": Int(task.terminationStatus)
                ])
                return
            }
            // 报告头部的 Call graph 段即主线程（Thread_0）调用栈，截取足够定位的头部。
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            let callGraphStart = lines.firstIndex { $0.contains("Call graph") } ?? 0
            let stackLines = lines.dropFirst(callGraphStart)
                .prefix(60)
                .joined(separator: "\n")
            try? FileManager.default.removeItem(atPath: samplePath)
            AppLogger.error(.ui, "Main thread stall sample", metadata: [
                "stallMS": String(format: "%.0f", stallMS),
                "stack": String(stackLines.prefix(3000))
            ])
        }
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
