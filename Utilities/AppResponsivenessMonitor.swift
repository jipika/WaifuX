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
    nonisolated(unsafe) private static var stallWasObserved = false
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
            if stallWasObserved {
                InteractionPerformanceLog.record(.mainThreadStall,
                    milliseconds: Date().timeIntervalSince(lastHeartbeatTime) * 1000,
                    metadata: ["phase": "recovered", "tab": state.currentTab])
                stallWasObserved = false
            }
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
        stallWasObserved = false
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

        stallWasObserved = true
        InteractionPerformanceLog.record(.mainThreadStall, milliseconds: elapsed * 1000, metadata: [
            "phase": "detected",
            "heartbeat": String(snapshot.heartbeat),
            "ackedHeartbeat": String(snapshot.lastAckedHeartbeat),
            "tab": snapshot.currentTab,
            "detailDepth": String(snapshot.detailDepth),
            "windowVisible": snapshot.windowVisible ? "1" : "0",
            "appActive": snapshot.appActive ? "1" : "0",
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
    /// 会放大负载。这里 10 分钟最多采一次；其余观测并入限频性能摘要。
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
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            let callGraphStart = lines.firstIndex { $0.contains("Call graph") } ?? 0
            let stack = condensedMainThreadStack(Array(lines.dropFirst(callGraphStart)))
            try? FileManager.default.removeItem(atPath: samplePath)
            AppLogger.error(.ui, "Main thread stall sample", metadata: [
                "stallMS": String(format: "%.0f", stallMS),
                "stack": stack
            ])
        }
    }

    /// 把 `sample` 的树状 Call graph 压成「权重 + 帧名」的线性链，保留最深的诊断帧。
    ///
    /// 旧实现取前 60 行再按 3000 字符硬截。sample 的树前缀（`+ ! : |` 缩进）随深度
    /// 线性增长，加上 dyld / NSApplication / CFRunLoop / mach_msg 这些无信息量的样板帧，
    /// 3000 字符恰好耗尽在真正有用的帧之前：#130/#132/#133 三份用户栈全部停在
    /// `_layoutViewTree` 或 `mshMIGPerform`，看不到下层是约束循环还是无障碍 XPC。
    ///
    /// 这里剥掉树前缀与地址、丢掉样板帧，只留 `权重 帧名 (模块)`，同样的预算能多
    /// 容纳数倍深度；并按权重剪掉噪声分支，优先保留采样占比高的那条路径。
    static func condensedMainThreadStack(_ lines: [String], budget: Int = 3000) -> String {
        struct Frame {
            let weight: Int
            let label: String
            let depth: Int
        }

        // 只取主线程段：遇到下一个 Thread_ 标题即停。
        var frames: [Frame] = []
        var sawThread = false
        for raw in lines {
            let line = String(raw)
            if line.contains("Thread_") {
                if sawThread { break }
                sawThread = true
                continue
            }
            if line.hasPrefix("Total number") || line.hasPrefix("Binary Images") { break }
            // 树前缀只由空格与 + ! : | 组成；帧正文从第一个字母/符号开始。
            guard let bodyStart = line.firstIndex(where: { !$0.isWhitespace && !"+!:|".contains($0) }) else { continue }
            let prefix = line[line.startIndex..<bodyStart]
            let body = String(line[bodyStart...])
            // 权重是正文开头的十进制数（可能带 ",N" 形式的叶子计数）。
            let digits = body.prefix { $0.isNumber }
            guard let weight = Int(digits), !digits.isEmpty else { continue }
            var label = String(body.dropFirst(digits.count)).trimmingCharacters(in: .whitespaces)
            if let comma = label.firstIndex(of: ","), label[comma...].dropFirst().first?.isNumber == true {
                label = String(label[label.startIndex..<comma])
            }
            // 去掉十六进制地址尾巴，保留符号名与所属模块。
            if let bracket = label.lastIndex(of: "[") { label = String(label[label.startIndex..<bracket]) }
            label = label.trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty else { continue }
            frames.append(Frame(weight: weight, label: label, depth: prefix.count))
        }

        // 剪掉样板帧：它们每份栈都一样，占预算却不提供定位信息。
        let boilerplate = [
            "start ", "main ", "static WaifuXApp.main()", "-[NSApplication run]",
            "_nextEventMatchingEventMask", "_DPSNextEvent", "_BlockUntilNextEventMatchingListInModeWithFilter",
            "ReceiveNextEventCommon", "RunCurrentEventLoopInMode", "CFRunLoopRunSpecific",
            "__CFRunLoopRun ", "__CFRunLoopServiceMachPort", "mach_msg", "voucher_mach_msg_adopt",
            "_dispatch_set_priority_and_mach_voucher_slow", "_pthread_set_properties_self", "__bsdthread_ctl",
            "_voucher_create_with_mach_voucher", "_os_object_alloc_realized",
        ]
        let kept = frames.filter { frame in
            !boilerplate.contains { frame.label.hasPrefix($0) }
        }
        guard !kept.isEmpty else { return "(no main-thread frames parsed)" }

        // 不做权重剪枝：sample 树里深层帧权重天然递减（分支收窄），但诊断价值最高
        // ——`_XCopyAttributeValue` 只占 3% 采样，却是「卡在无障碍 XPC」的唯一证据。
        // 剥掉树前缀/地址/样板帧后按原序保留全部帧；若仍超预算，从**浅层**开始丢，
        // 因为根因永远在最深处（旧实现恰好相反：留头丢尾，把根因全丢了）。
        let entries = kept.map { "\($0.weight) \($0.label)" }
        var start = 0
        var used = entries.reduce(0) { $0 + $1.count + 1 }
        while used > budget, start < entries.count - 1 {
            used -= entries[start].count + 1
            start += 1
        }
        var out = Array(entries[start...])
        if start > 0 { out.insert("(+\(start) shallower frames omitted)", at: 0) }
        // 单帧本身超预算的极端情况：硬截并显式标注，不静默丢证据。
        var text = out.joined(separator: " <- ")
        if text.count > budget {
            text = String(text.suffix(budget - 24))
            text = "(truncated head)… " + text
        }
        return text
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
