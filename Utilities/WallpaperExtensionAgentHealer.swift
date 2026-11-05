//  WallpaperExtensionAgentHealer.swift
//  扩展断线恢复（Helper 内置，无额外常驻服务）
//
//  pkd 会以「remove all extension instances」按 bundle ID 终止所有扩展实例
//  （2026-11-01 实锤：GamePolicyAgent 补全一份授权损坏的旧副本注册，pkd 卸载其
//  旧 UUID 时连健康的 Debug 实例一起杀掉）。WallpaperAgent 之后可能长时间不重拉载。
//
//  判定依据是「状态文件声明正在渲染（isActive + contexts），但声明者 PID 已不存在」：
//  被杀的实例来不及写 isActive=false；空闲断开或正常停用不会留下这种证据。
//
//  铁律：扩展进程存在（或进程表读不到）时绝不注册；不写 Index.plist；
//  只注册当前宿主内、签名与沙盒授权有效的 appex。
//  2026-11-05 用户批准窄例外：真实持续 missing_context 时受控重启当前用户的
//  单一 Apple WallpaperAgent；首次即时恢复，仅失败短退避，不沿用注册十分钟限频。

import Foundation
import os

/// 纯决策逻辑，由 scripts/test-wallpaper-extension-recovery-policy.py 抽出单测。
enum WallpaperExtensionRecoveryPolicy {
    static let pollInterval: TimeInterval = 10
    /// 登录/Helper 启动后 WallpaperAgent 自行拉载扩展需要时间，期间只观察。
    static let startupGrace: TimeInterval = 90
    /// 证据出现后进程持续缺失多久才动手（给 WallpaperAgent 自行重拉载留时间）。
    static let missingConfirmation: TimeInterval = 20
    /// 注册后等待 WallpaperAgent 重拉载（实测 65–90s）。
    static let verifyWindow: TimeInterval = 150
    /// pkd 清点可能在数秒内杀掉刚拉起的实例，必须稳定一段时间才算数。
    static let stableWindow: TimeInterval = 30
    /// 任意两次注册至少间隔 10 分钟，防止注册本身形成 remove 循环。
    static let minimumAttemptInterval: TimeInterval = 600
    static let maximumBackoff: TimeInterval = 3600

    static func shouldMonitor(dynamicLockScreenEnabled: Bool) -> Bool {
        dynamicLockScreenEnabled
    }

    /// PlugInKit 会拒绝的 appex 不能注册：注册它只会触发 remove 而拉不起实例。
    static func registrationRejectionReason(
        signatureValid: Bool, signingIdentifier: String?, entitlements: [String: Any]?
    ) -> String? {
        guard signatureValid else { return "invalid code signature" }
        guard signingIdentifier == "com.waifux.app.wallpaperextension" else { return "unexpected signing identifier" }
        guard let entitlements else { return "entitlements unavailable" }
        guard entitlements["com.apple.security.app-sandbox"] as? Bool == true else { return "missing app-sandbox" }
        guard (entitlements["com.apple.security.application-groups"] as? [String])?.contains("group.com.waifux.app") == true else {
            return "missing application group"
        }
        return nil
    }

    /// 外置卷的 appex 扫描仅允许已确认的 Spotlight -10811 非致命错误；
    /// 启动失败、其它 lsregister 错误或任何 PlugInKit 失败都必须中止。
    static func registrationToolAccepted(label: String, status: Int32, output: String) -> Bool {
        if status == 0 { return true }
        return label == "lsregister" && status == 1
            && output.contains("failed to scan ")
            && output.contains(": -10811 ")
            && output.contains("from spotlight")
    }

    /// 扩展状态文件里「正在渲染」的声明；isActive=false 或没有 contexts 时不构造。
    struct ActiveRecord: Equatable {
        let pid: Int32
        let updatedAt: TimeInterval
    }

    enum Action: Equatable {
        case none
        case register
        /// 新实例上报活跃上下文并稳定 30s。
        case recovered
        /// 新实例已拉起并稳定，但系统尚未分配上下文；不重复注册。
        case awaitingContexts
        /// 验证窗口内没有稳定实例，退避后对同一证据重试。
        case verificationFailed
    }

    struct State {
        private(set) var pendingSince: TimeInterval?
        private(set) var retryNotBefore: TimeInterval = 0
        private(set) var failureCount = 0
        private var pendingWallStart: TimeInterval = 0
        private var pendingEvidence: ActiveRecord?
        private var handledEvidence: ActiveRecord?
        private var observingSince: TimeInterval?
        private var missingSince: TimeInterval?
        private var missingSamples = 0
        private var livePID: Int32?
        private var liveSince: TimeInterval = 0
        private var launchedStable = false
        private var contextPID: Int32?
        private var contextSince: TimeInterval = 0

        /// - pids: nil 表示进程表读不到；读不到不是死亡证据。
        /// - now: 单调时钟；wallNow: 与状态文件 updatedAt 同源的墙钟。
        mutating func observe(
            selected: Bool, pids: [Int32]?, record: ActiveRecord?,
            now: TimeInterval, wallNow: TimeInterval, registrationInProgress: Bool
        ) -> Action {
            if observingSince == nil { observingSince = now }
            guard selected else {
                // 用户换走壁纸：放弃本次验证，保留限频、失败计数与已处理证据。
                endPending()
                resetMissing()
                return .none
            }
            guard let pids else {
                // 未知样本既不是死亡也不是连续存活证据，不能跨过它累计稳定时间。
                resetMissing()
                resetVerificationObservation()
                return .none
            }
            if let pendingSince {
                trackVerification(pids: pids, record: record, now: now)
                if !registrationInProgress, contextPID != nil,
                   now - contextSince >= WallpaperExtensionRecoveryPolicy.stableWindow {
                    handledEvidence = pendingEvidence
                    failureCount = 0
                    endPending()
                    return .recovered
                }
                guard now - pendingSince >= WallpaperExtensionRecoveryPolicy.verifyWindow else { return .none }
                return verificationTimeout(now: now, registrationInProgress: registrationInProgress)
            }
            guard pids.isEmpty, let record, !pids.contains(record.pid), record != handledEvidence else {
                resetMissing()
                return .none
            }
            if missingSince == nil { missingSince = now }
            missingSamples += 1
            guard missingSamples >= 2, let missingSince,
                  now - missingSince >= WallpaperExtensionRecoveryPolicy.missingConfirmation,
                  let observingSince, now - observingSince >= WallpaperExtensionRecoveryPolicy.startupGrace,
                  !registrationInProgress, now >= retryNotBefore else { return .none }
            pendingSince = now
            pendingWallStart = wallNow
            pendingEvidence = record
            retryNotBefore = now + WallpaperExtensionRecoveryPolicy.minimumAttemptInterval
            resetMissing()
            launchedStable = false
            return .register
        }

        /// 注册命令被拒绝或执行失败：不标记证据已处理，按退避对同一证据重试。
        mutating func registrationFailed(now: TimeInterval) {
            guard pendingSince != nil else { return }
            endPending()
            failureCount = min(failureCount + 1, 6)
            let delay = min(
                WallpaperExtensionRecoveryPolicy.minimumAttemptInterval * pow(2, Double(failureCount - 1)),
                WallpaperExtensionRecoveryPolicy.maximumBackoff
            )
            retryNotBefore = max(retryNotBefore, now + delay)
        }

        /// 关闭开关或 Helper 停止：放弃进行中的验证，重新计启动宽限；
        /// 限频与已处理证据保留，stop/start 不能绕过它们。
        mutating func suspend() {
            endPending()
            resetMissing()
            observingSince = nil
        }

        private mutating func verificationTimeout(now: TimeInterval, registrationInProgress: Bool) -> Action {
            guard let pendingSince, !registrationInProgress,
                  now - pendingSince >= WallpaperExtensionRecoveryPolicy.verifyWindow else { return .none }
            if launchedStable {
                handledEvidence = pendingEvidence
                failureCount = 0
                endPending()
                return .awaitingContexts
            }
            // 窗口末尾刚拉起的实例：再给它一个稳定窗口，避免误判失败后重复注册。
            if livePID != nil,
               now - pendingSince < WallpaperExtensionRecoveryPolicy.verifyWindow + WallpaperExtensionRecoveryPolicy.stableWindow {
                return .none
            }
            registrationFailed(now: now)
            return .verificationFailed
        }

        private mutating func trackVerification(pids: [Int32], record: ActiveRecord?, now: TimeInterval) {
            if let livePID, pids.contains(livePID) {
                // 同一实例持续存活
            } else if let first = pids.first {
                livePID = first
                liveSince = now
            } else {
                livePID = nil
            }
            // 必须是当前仍存活的同一 PID 连续稳定，过去曾经稳定不能沿用。
            launchedStable = livePID != nil && now - liveSince >= WallpaperExtensionRecoveryPolicy.stableWindow
            if let record, record.updatedAt >= pendingWallStart, pids.contains(record.pid) {
                if contextPID != record.pid {
                    contextPID = record.pid
                    contextSince = now
                }
            } else {
                contextPID = nil
            }
        }

        private mutating func endPending() {
            pendingSince = nil
            pendingEvidence = nil
            resetVerificationObservation()
        }

        private mutating func resetVerificationObservation() {
            launchedStable = false
            livePID = nil
            contextPID = nil
        }

        private mutating func resetMissing() {
            missingSince = nil
            missingSamples = 0
        }
    }
}

/// @unchecked Sendable：全部可变状态由 stateLock 保护，探测在私有串行队列执行。
/// init 与 Darwin 回调里不读偏好；开关在每次采样时读取。
final class WallpaperExtensionAgentHealer: @unchecked Sendable {
    static let shared = WallpaperExtensionAgentHealer()

    /// 与扩展侧 SpiralRecovery.agentStuckNotification 保持一致。
    private static let agentStuckDarwinNotification = "com.waifux.app.wallpaper.agentStuck"

    private let log = OSLog(subsystem: "com.waifux.app", category: "ExtensionHealer")
    private let queue = DispatchQueue(label: "com.waifux.app.extension-healer", qos: .utility)
    private let stateLock = NSLock()
    private var started = false
    private var monitoring = false
    private var timer: DispatchSourceTimer?
    private var state = WallpaperExtensionRecoveryPolicy.State()
    private var healInProgress = false
    private var embeddedExtensionURL: URL?
    private var stateURL: URL?
    private var lifecycleGeneration: UInt64 = 0
    private typealias ContextPolicy = WallpaperExtensionContextRecoveryPolicy
    private var contextStates: [UInt32: ContextPolicy.State] = [:]
    private var contextMonitoringSince: TimeInterval?
    private var contextWallStarts: [UInt32: TimeInterval] = [:]
    private var contextAccepted: [UInt32: ContextPolicy.Submission] = [:]
    private var contextReplayed: [UInt32: ContextPolicy.Submission] = [:]
    private var contextBusy: (displayID: UInt32, submission: ContextPolicy.Submission)?
    private var contextTickScheduled = false
    private var contextFollowupGeneration: UInt64?
    private var contextBudgetRestored = false
    private var contextGlobalFailureCount = 0
    private var contextGlobalRetryNotBefore: TimeInterval = 0
    private var contextLastAgentRestartWall: TimeInterval?
    private var contextGlobalReplayed: [UInt32: String] = [:]
    private var contextProbedPIDs: [UInt32: Int32] = [:]
    private var unlockObserver: NSObjectProtocol?
    private static let contextDeadlineKey = "wallpaper_context_recovery_retry_deadlines"

    private init() {}

    // MARK: - 启停（幂等）

    @MainActor
    func start() {
        guard BackgroundRuntimeRole.isHelper, !BackgroundRuntimeRole.isIsolatedTest else { return }
        let extensionURL = WaifuXHostBundle.bundleURL
            .appendingPathComponent("Contents/PlugIns/WaifuXWallpaperExtension.appex", isDirectory: true)
        let stateFile = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.waifux.app")?
            .appendingPathComponent("waifux-wallpaper-state.json")
        stateLock.lock()
        guard !started else { stateLock.unlock(); return }
        started = true
        lifecycleGeneration &+= 1
        embeddedExtensionURL = extensionURL
        stateURL = stateFile
        contextMonitoringSince = ProcessInfo.processInfo.systemUptime
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + WallpaperExtensionRecoveryPolicy.pollInterval,
                        repeating: WallpaperExtensionRecoveryPolicy.pollInterval, leeway: .seconds(2))
        // @Sendable 不能省：setEventHandler 的参数不是 @Sendable，闭包字面量会继承
        // start() 的 MainActor 隔离，而 timer 在 `queue` 上触发，运行时隔离自检
        // 直接 SIGTRAP（2026-11-02 实测：closure #1 in start() →
        // dispatch_assert_queue fail，Helper 每 10s 崩溃循环、launchd 反复拉起）。
        // queue.async 那几处参数自带 @Sendable，不受影响。
        source.setEventHandler { @Sendable [weak self] in self?.tick() }
        timer = source
        stateLock.unlock()

        installDarwinObserver()
        unlockObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { @Sendable [weak self] _ in self?.sourceMissingContextReported() }
        source.resume()
        queue.async { [weak self] in self?.tick() }
        os_log(.info, log: log, "ExtensionHealer started (registration: poll=10s, grace=90s, min=600s; real context fault: immediate sample, confirm=1s, failure-only backoff)")
    }

    @MainActor
    func stop() {
        stateLock.lock()
        started = false
        monitoring = false
        lifecycleGeneration &+= 1
        state.suspend()
        suspendContextRecovery()
        // 正在执行的注册由其完成回调释放 healInProgress，避免 stop/start 后并发注册。
        let source = timer
        timer = nil
        stateLock.unlock()
        source?.cancel()
        if let unlockObserver { DistributedNotificationCenter.default().removeObserver(unlockObserver) }
        unlockObserver = nil
        CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque())
    }

    /// 关闭开关时同步撤销旧探测与注册资格，不能等队列中的下一次采样。
    @MainActor
    func preferencesChanged() {
        let enabled = recoveryEnabled()
        stateLock.lock()
        guard started else { stateLock.unlock(); return }
        if !enabled {
            lifecycleGeneration &+= 1
            monitoring = false
            state.suspend()
            suspendContextRecovery()
        }
        stateLock.unlock()
        queue.async { [weak self] in self?.tick() }
    }

    // MARK: - Darwin 通知（扩展 agentStuck）

    private func installDarwinObserver() {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let healer = Unmanaged<WallpaperExtensionAgentHealer>.fromOpaque(observer).takeUnretainedValue()
                // 信号只触发一次额外采样，不能绕过证据、缺失确认与限频。
                healer.queue.async { healer.tick() }
            },
            Self.agentStuckDarwinNotification as CFString,
            nil,
            .deliverImmediately
        )
    }

    // MARK: - 周期检查（私有串行队列）

    private func tick() {
        guard !BackgroundRuntimeRole.isIsolatedTest else { return }
        stateLock.lock()
        guard started else { stateLock.unlock(); return }
        let observingGeneration = lifecycleGeneration
        stateLock.unlock()
        let enabled = recoveryEnabled()

        stateLock.lock()
        guard started, lifecycleGeneration == observingGeneration else { stateLock.unlock(); return }
        let stateFile = stateURL
        if enabled != monitoring {
            monitoring = enabled
            if !enabled {
                lifecycleGeneration &+= 1
                state.suspend()
                suspendContextRecovery()
            } else {
                contextMonitoringSince = ProcessInfo.processInfo.systemUptime
            }
            stateLock.unlock()
            os_log(.info, log: log, "dynamic lock screen %{public}@ — extension recovery %{public}@",
                   enabled ? "on" : "off", enabled ? "monitoring" : "paused")
            guard enabled else { return }
        } else {
            stateLock.unlock()
            guard enabled else { return }
        }

        let selected = WallpaperStoreSelectionProbe.currentSelection() == .selected
        let pids: [pid_t]? = selected ? WallpaperExtensionKeeper.observedExtensionProcessPids() : []
        let reportedRecord = selected ? Self.activeRecord(at: stateFile) : nil
        let record: WallpaperExtensionRecoveryPolicy.ActiveRecord?
        if pids?.isEmpty == true, let reportedRecord,
           !ProcessLiveness.isDefinitelyDead(reportedRecord.pid) {
            // 路径探测失败、权限不足或 PID 复用都不能当作声明者已死。
            record = nil
        } else {
            record = reportedRecord
        }
        let now = ProcessInfo.processInfo.systemUptime
        let wallNow = Date().timeIntervalSince1970

        stateLock.lock()
        guard started, monitoring, lifecycleGeneration == observingGeneration else { stateLock.unlock(); return }
        let action = state.observe(selected: selected, pids: pids, record: record,
                                   now: now, wallNow: wallNow, registrationInProgress: healInProgress || contextBusy != nil
                || contextStates.values.contains(where: { $0.pendingSubmission != nil }))
        let generation = lifecycleGeneration
        let extensionURL = embeddedExtensionURL
        if action == .register { healInProgress = true }
        stateLock.unlock()

        switch action {
        case .none:
            break
        case .recovered:
            os_log(.info, log: log, "extension recovery verified: fresh active context stable for 30s")
        case .awaitingContexts:
            os_log(.info, log: log, "extension relaunched and stable; WallpaperAgent has not assigned a context yet — not registering again")
        case .verificationFailed:
            os_log(.error, log: log, "no stable extension within 150s after registration; backing off")
        case .register:
            os_log(.info, log: log, "extension pid %{public}d died while rendering; validating host appex before safe registration",
                   record?.pid ?? 0)
            guard let extensionURL else {
                finishRegistration(generation: generation, succeeded: false)
                return
            }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { return }
                let ok = WallpaperExtensionKeeper.reviveExtension(
                    at: extensionURL, waitForActivation: false,
                    shouldContinue: { [weak self] in self?.isCurrentHealingGeneration(generation) == true }
                )
                self.finishRegistration(generation: generation, succeeded: ok)
            }
        }
        scheduleContextRecovery(generation: generation)
    }

    /// A new request (including one which has not reported pending yet) invalidates
    /// the old token synchronously. Preserve cooldowns across A→B→A and stop/start.
    func sourceRequestChanged(displayID: UInt32) {
        stateLock.lock()
        contextStates[displayID]?.requestChanged()
        contextWallStarts[displayID] = nil
        contextAccepted[displayID] = nil
        contextReplayed[displayID] = nil
        contextGlobalReplayed[displayID] = nil
        stateLock.unlock()
    }

    /// A genuine peer-authenticated receipt requests an immediate coalesced sample;
    /// it does not wait for the separate ten-second registration watchdog.
    func sourceMissingContextReported() {
        stateLock.lock()
        let current = started
        let enabled = monitoring
        let generation = lifecycleGeneration
        stateLock.unlock()
        guard current else { return }
        if enabled { scheduleContextRecovery(generation: generation) }
        else { queue.async { [weak self] in self?.tick() } }
    }

    /// Caller holds stateLock. In-flight submissions release contextBusy in their
    /// own completion; restarting the Helper monitor cannot run two writes at once.
    private func suspendContextRecovery() {
        for display in Array(contextStates.keys) { contextStates[display]?.suspend() }
        contextMonitoringSince = nil
        contextFollowupGeneration = nil
        contextLastAgentRestartWall = nil
        contextWallStarts.removeAll()
        contextAccepted.removeAll()
        contextReplayed.removeAll()
        contextGlobalReplayed.removeAll()
        contextProbedPIDs.removeAll()
    }

    private func scheduleContextRecovery(generation: UInt64) {
        stateLock.lock()
        guard started, monitoring, lifecycleGeneration == generation, !contextTickScheduled else {
            stateLock.unlock(); return
        }
        contextTickScheduled = true
        stateLock.unlock()
        Task { @MainActor [weak self] in self?.sampleContextRecovery(generation: generation) }
    }

    @MainActor
    private func sampleContextRecovery(generation: UInt64) {
        stateLock.lock()
        contextTickScheduled = false
        guard started, monitoring, lifecycleGeneration == generation else { stateLock.unlock(); return }
        let file = stateURL
        let began = contextMonitoringSince ?? ProcessInfo.processInfo.systemUptime
        let knownDisplays = Set(contextStates.keys)
        stateLock.unlock()
        guard recoveryEnabled(), !VideoWallpaperManager.shared.isScreenLocked,
              WallpaperAgentRecoveryExecutor.sessionAllowsRecovery() else {
            stateLock.lock(); suspendContextRecovery(); stateLock.unlock()
            return
        }
        let server = WallpaperExtensionSocketServer.shared
        let evidence = Dictionary(uniqueKeysWithValues: server.contextRecoveryEvidence().map { ($0.displayID, $0) })
        let displays = knownDisplays.union(evidence.keys).union(server.contextRecoveryProbeDisplays())
        guard !displays.isEmpty else { return }
        let pids = WallpaperExtensionKeeper.observedExtensionProcessPids()
        let report = Self.contextReport(at: file)
        let now = ProcessInfo.processInfo.systemUptime
        let saved = WaifuXPreferences.shared.dictionary(forKey: Self.contextDeadlineKey) ?? [:]
        stateLock.lock()
        if !contextBudgetRestored {
            let wallDeadline = (saved["global"] as? NSNumber)?.doubleValue ?? 0
            let remaining = wallDeadline.isFinite ? min(ContextPolicy.maximumBackoff, max(0, wallDeadline - Date().timeIntervalSince1970)) : ContextPolicy.maximumBackoff
            contextGlobalRetryNotBefore = now + remaining
            contextGlobalFailureCount = min(5, max(0, (saved["failures"] as? NSNumber)?.intValue ?? 0))
            contextBudgetRestored = true
        }
        stateLock.unlock()
        for display in displays.sorted() {
            stateLock.lock()
            guard started, monitoring, lifecycleGeneration == generation else { stateLock.unlock(); return }
            if contextStates[display] == nil {
                let wallDeadline = (saved[String(display)] as? NSNumber)?.doubleValue ?? 0
                let remaining = wallDeadline.isFinite ? min(ContextPolicy.maximumBackoff, max(0, wallDeadline - Date().timeIntervalSince1970)) : ContextPolicy.maximumBackoff
                var policy = ContextPolicy.State(retryNotBefore: now + remaining)
                policy.beginObservation(at: began)
                contextStates[display] = policy
            }
            let pending = contextStates[display]?.pendingSubmission
            let wallStart = contextWallStarts[display]
            stateLock.unlock()
            let scope = WallpaperAgentRecoveryExecutor.currentScope(displayID: display)
            let selected = scope.map { WallpaperAgentRecoveryExecutor.isSelected($0) } ?? false
            if pending == nil, evidence[display] == nil, selected,
               let pids, pids.count == 1, let pid = pids.first, let report,
               report.pid != pid, report.activeDisplays.contains(display), ProcessLiveness.isDefinitelyDead(report.pid) {
                stateLock.lock()
                let needsProbe = contextProbedPIDs[display] != pid
                stateLock.unlock()
                if needsProbe, server.probeCompletedSourceForContextRecovery(displayID: display) {
                    stateLock.lock(); contextProbedPIDs[display] = pid; stateLock.unlock()
                    os_log(.info, log: log, "settings-only PID replacement: probing unchanged source display=%u pid=%d", display, pid)
                }
                continue
            }
            guard let request = pending?.evidence.requestID ?? evidence[display]?.requestID else { continue }
            let status = server.contextRecoveryStatus(displayID: display, requestID: request)
            // A fresh explicit no-context receipt wins over an older active-state file.
            // Verification still requires a new state written after this attempt.
            let requiredWall = wallStart ?? evidence[display].map {
                Date().timeIntervalSince1970 - max(0, now - $0.firstObserved)
            }
            let active = report.map { report in
                pids?.contains(report.pid) == true && report.activeDisplays.contains(display)
                    && (requiredWall == nil || report.updatedAt >= requiredWall!)
            } ?? false
            let observedPIDs = pids
            var action = ContextPolicy.Action.none
            var submission: ContextPolicy.Submission?
            var replay = false
            var deadline: TimeInterval = 0
            stateLock.lock()
            guard started, monitoring, lifecycleGeneration == generation else { stateLock.unlock(); return }
            let recoveryBusy = healInProgress || contextBusy != nil || now < contextGlobalRetryNotBefore
                || contextStates.contains(where: { $0.key != display && $0.value.pendingSubmission != nil })
            if !status.current {
                contextStates[display]?.requestChanged()
                contextAccepted[display] = nil
                contextReplayed[display] = nil
                contextWallStarts[display] = nil
            } else if status.failed, let pending {
                action = contextStates[display]?.requestFailed(pending, now: now) ?? .none
            } else {
                action = contextStates[display]?.observe(evidence: evidence[display], selected: selected,
                    livePIDs: observedPIDs, hasActiveContext: active, sourceReady: status.ready, now: now,
                    recoveryInProgress: recoveryBusy) ?? .none
            }
            if case .restartAgent = action, let pending = contextStates[display]?.pendingSubmission {
                submission = pending
                contextBusy = (display, pending)
                contextWallStarts[display] = Date().timeIntervalSince1970
                contextAccepted[display] = nil
                contextReplayed[display] = nil
            } else if let pending = contextStates[display]?.pendingSubmission,
                      contextAccepted[display] == pending, active, !status.ready, !status.failed,
                      contextReplayed[display] != pending {
                contextReplayed[display] = pending
                replay = true
            }
            if let restartedAt = contextLastAgentRestartWall, selected, status.current, !status.ready, !status.failed,
               let report, report.updatedAt >= restartedAt, report.activeDisplays.contains(display),
               pids?.contains(report.pid) == true, contextGlobalReplayed[display] != request {
                // One Agent restart can rebuild several displays. Replay each current
                // source once, not only the display whose fault triggered the restart.
                contextGlobalReplayed[display] = request
                replay = true
            }
            deadline = contextStates[display]?.retryNotBefore ?? 0
            stateLock.unlock()
            if replay { _ = server.replaySourceAfterContextRecovery(displayID: display, requestID: request) }
            switch action {
            case .none: break
            case .recovered:
                clearContextFailureBudget()
                os_log(.info, log: log, "context recovery verified display=%u: fresh context and current source_ready stable for 2s", display)
            case .verificationFailed:
                recordContextFailure(displayID: display, monotonicDeadline: deadline)
                os_log(.error, log: log, "context recovery not verified display=%u; short failure-only backoff", display)
            case .restartAgent:
                guard let submission else { continue }
                os_log(.info, log: log, "live extension pid=%d acknowledged missing context display=%u; requesting guarded current-user WallpaperAgent restart", submission.evidence.pid, display)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.contextSubmissionAllowed(displayID: display, submission: submission, generation: generation) else {
                        self.cancelContextSubmission(displayID: display, submission: submission)
                        return
                    }
                    let restartedAt = Date().timeIntervalSince1970
                    let accepted = WallpaperAgentRecoveryExecutor.restartCurrentUserAgent {
                        self.contextSubmissionAllowed(displayID: display, submission: submission, generation: generation)
                    }
                    if !accepted, !self.contextSubmissionAllowed(displayID: display, submission: submission, generation: generation) {
                        self.cancelContextSubmission(displayID: display, submission: submission)
                    } else {
                        self.finishContextSubmission(displayID: display, submission: submission, generation: generation, accepted: accepted, restartedAt: restartedAt)
                    }
                }
            }
        }
        stateLock.lock()
        let needsFollowup = !evidence.isEmpty || contextStates.values.contains(where: { $0.pendingSubmission != nil })
        stateLock.unlock()
        if needsFollowup { scheduleContextFollowup(generation: generation) }
    }

    private func scheduleContextFollowup(generation: UInt64) {
        stateLock.lock()
        guard started, monitoring, lifecycleGeneration == generation, contextFollowupGeneration != generation else {
            stateLock.unlock(); return
        }
        contextFollowupGeneration = generation
        stateLock.unlock()
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let current = self.contextFollowupGeneration == generation
            if current { self.contextFollowupGeneration = nil }
            self.stateLock.unlock()
            if current { self.scheduleContextRecovery(generation: generation) }
        }
    }

    @MainActor
    private func contextSubmissionAllowed(displayID: UInt32, submission: ContextPolicy.Submission, generation: UInt64) -> Bool {
        guard recoveryEnabled(), !VideoWallpaperManager.shared.isScreenLocked,
              WallpaperAgentRecoveryExecutor.sessionAllowsRecovery(),
              let scope = WallpaperAgentRecoveryExecutor.currentScope(displayID: displayID),
              WallpaperAgentRecoveryExecutor.isSelected(scope),
              WallpaperExtensionKeeper.observedExtensionProcessPids() == [submission.evidence.pid] else { return false }
        let server = WallpaperExtensionSocketServer.shared
        let status = server.contextRecoveryStatus(displayID: displayID, requestID: submission.evidence.requestID)
        guard status.current, !status.ready, !status.failed,
              server.contextRecoveryEvidence().contains(submission.evidence) else { return false }
        stateLock.lock()
        defer { stateLock.unlock() }
        guard started, monitoring, lifecycleGeneration == generation, !healInProgress,
              contextBusy?.displayID == displayID, contextBusy?.submission == submission,
              ProcessInfo.processInfo.systemUptime >= contextGlobalRetryNotBefore,
              contextStates[displayID]?.pendingSubmission == submission else { return false }
        let requiredWall = Date().timeIntervalSince1970 - max(0, ProcessInfo.processInfo.systemUptime - submission.evidence.firstObserved)
        if let report = Self.contextReport(at: stateURL), report.pid == submission.evidence.pid,
           report.updatedAt >= requiredWall, report.activeDisplays.contains(displayID) { return false }
        return true
    }

    private func cancelContextSubmission(displayID: UInt32, submission: ContextPolicy.Submission) {
        stateLock.lock()
        if contextBusy?.displayID == displayID, contextBusy?.submission == submission { contextBusy = nil }
        if contextStates[displayID]?.pendingSubmission == submission {
            contextStates[displayID]?.requestChanged()
            contextAccepted[displayID] = nil
            contextReplayed[displayID] = nil
            contextWallStarts[displayID] = nil
        }
        stateLock.unlock()
    }

    @MainActor
    private func finishContextSubmission(displayID: UInt32, submission: ContextPolicy.Submission, generation: UInt64, accepted: Bool, restartedAt: TimeInterval) {
        stateLock.lock()
        if contextBusy?.displayID == displayID, contextBusy?.submission == submission { contextBusy = nil }
        let current = started && monitoring && lifecycleGeneration == generation
        if accepted, current {
            contextLastAgentRestartWall = restartedAt
            contextGlobalReplayed.removeAll()
        }
        let action: ContextPolicy.Action
        if current {
            action = contextStates[displayID]?.finishSubmission(submission, succeeded: accepted, now: ProcessInfo.processInfo.systemUptime) ?? .none
            if accepted, contextStates[displayID]?.pendingSubmission == submission { contextAccepted[displayID] = submission }
        } else { action = .none }
        let deadline = contextStates[displayID]?.retryNotBefore ?? 0
        stateLock.unlock()
        if action == .verificationFailed { recordContextFailure(displayID: displayID, monotonicDeadline: deadline) }
        os_log(.info, log: log, "context recovery signal display=%u %{public}@; fresh context and source_ready are verified separately", displayID, accepted ? "sent" : "cancelled or failed")
        if accepted, current { scheduleContextFollowup(generation: generation) }
    }

    @MainActor
    private func recordContextFailure(displayID: UInt32, monotonicDeadline: TimeInterval) {
        stateLock.lock()
        contextGlobalFailureCount = min(5, contextGlobalFailureCount + 1)
        let delays: [TimeInterval] = [2, 15, 15, 30, 60]
        contextGlobalRetryNotBefore = max(contextGlobalRetryNotBefore,
            ProcessInfo.processInfo.systemUptime + delays[contextGlobalFailureCount - 1])
        stateLock.unlock()
        // The Agent is shared by all displays: changing displays cannot bypass backoff.
        persistContextDeadline(displayID: displayID, monotonicDeadline: monotonicDeadline)
    }

    @MainActor
    private func clearContextFailureBudget() {
        stateLock.lock()
        contextGlobalFailureCount = 0
        contextGlobalRetryNotBefore = 0
        stateLock.unlock()
        persistContextDeadline(displayID: nil)
    }

    private func persistContextDeadline(displayID: UInt32?, monotonicDeadline: TimeInterval = 0) {
        var values = WaifuXPreferences.shared.dictionary(forKey: Self.contextDeadlineKey) ?? [:]
        let wallNow = Date().timeIntervalSince1970
        let now = ProcessInfo.processInfo.systemUptime
        if let displayID { values[String(displayID)] = wallNow + max(0, monotonicDeadline - now) }
        stateLock.lock()
        values["global"] = wallNow + max(0, contextGlobalRetryNotBefore - now)
        values["failures"] = contextGlobalFailureCount
        stateLock.unlock()
        WaifuXPreferences.shared.set(values, forKey: Self.contextDeadlineKey)
    }

    private struct ContextReport {
        let pid: Int32
        let updatedAt: TimeInterval
        let activeDisplays: Set<UInt32>
    }

    private static func contextReport(at url: URL?) -> ContextReport? {
        guard let url, let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= 64 * 1024,
              let data = try? Data(contentsOf: url), data.count <= 64 * 1024,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = (json["pid"] as? NSNumber)?.int32Value, pid > 0,
              let updated = (json["updatedAt"] as? NSNumber)?.doubleValue, updated.isFinite,
              updated > 0, updated <= Date().timeIntervalSince1970 + 5,
              let active = json["isActive"] as? Bool,
              let contexts = json["contexts"] as? [[String: Any]] else { return nil }
        var displays = Set<UInt32>()
        for context in contexts {
            guard let display = (context["displayID"] as? NSNumber)?.uint32Value, display > 0 else { return nil }
            if active { displays.insert(display) }
        }
        return .init(pid: pid, updatedAt: updated, activeDisplays: displays)
    }

    private func finishRegistration(generation: UInt64, succeeded: Bool) {
        stateLock.lock()
        healInProgress = false
        let current = started && lifecycleGeneration == generation
        if current, !succeeded {
            state.registrationFailed(now: ProcessInfo.processInfo.systemUptime)
        }
        stateLock.unlock()
        let outcome = succeeded ? "accepted" : (current ? "failed — backing off" : "cancelled")
        os_log(.info, log: log, "registration commands %{public}@; activation is verified separately", outcome)
    }

    private func recoveryEnabled() -> Bool {
        WallpaperExtensionRecoveryPolicy.shouldMonitor(
            dynamicLockScreenEnabled: WaifuXPreferences.shared.object(forKey: "dynamic_lock_screen_enabled") as? Bool ?? true)
    }

    private func isCurrentHealingGeneration(_ generation: UInt64) -> Bool {
        // 也覆盖 Helper 内直接写偏好、没有触发 runtime.refreshSettings 的关闭路径。
        guard recoveryEnabled() else { return false }
        stateLock.lock()
        defer { stateLock.unlock() }
        return started && monitoring && lifecycleGeneration == generation
    }

    /// 状态文件归扩展所有，这里只读。只有 isActive 且带 contexts 的记录才算渲染声明。
    private static func activeRecord(at url: URL?) -> WallpaperExtensionRecoveryPolicy.ActiveRecord? {
        guard let url, let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["isActive"] as? Bool == true,
              let pid = (json["pid"] as? NSNumber)?.int32Value, pid > 0,
              let updated = (json["updatedAt"] as? NSNumber)?.doubleValue, updated.isFinite,
              let contexts = json["contexts"] as? [Any], !contexts.isEmpty else { return nil }
        return .init(pid: pid, updatedAt: updated)
    }
}
