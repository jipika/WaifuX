//  WallpaperExtensionAgentHealer.swift
//  扩展保活（App 内置，无额外常驻服务）
//
//  背景（2026-09-24 18:23 日志实锤）：macOS 27 的 pkd 会自发
//  「remove all extension instances: caller = pkd」，杀掉
//  WaifuXWallpaperExtension（宿主 App 在跑也会发生）；WallpaperAgent 收到
//  interruption 后 runtime-resolver 判「Computed lifecycle action nothing」，
//  ≥3 小时不重新拉载，桌面静默死掉。
//
//  仅当系统选中我们的扩展，且扩展进程连续缺失时，用 Keeper 的安全注册
//  序列尝试恢复。绝不重启 WallpaperAgent，也不碰仍然存活的扩展实例。

import Foundation
import os

/// @unchecked Sendable：全部可变状态由 stateLock 保护；Darwin 回调可能从
/// 任意线程触发 heal，锁已覆盖。
final class WallpaperExtensionAgentHealer: @unchecked Sendable {
    static let shared = WallpaperExtensionAgentHealer()

    /// 与扩展侧 SpiralRecovery.agentStuckNotification 保持一致。
    private static let agentStuckDarwinNotification = "com.waifux.app.wallpaper.agentStuck"

    private let log = OSLog(subsystem: "com.waifux.app", category: "ExtensionHealer")

    // MARK: 参数（对齐 Phosphene SpiralRecovery 与 keeper 实测值）
    private let pollInterval: TimeInterval = 30
    private let confirmTicks = 2                 // 连续 2 个周期进程都缺失才动手（防 proc 表抖动）
    private let healCooldown: TimeInterval = 20  // Phosphene 同款最小信号间隔
    private let verifyWindow: TimeInterval = 150 // 与 Keeper 的拉载验证窗口一致
    private let backoffBase: TimeInterval = 30
    private let backoffCap: TimeInterval = 600

    // MARK: 状态
    private let stateLock = NSLock()
    private var started = false
    private var pollTimer: Timer?
    private var consecutiveMissing = 0
    private var lastHealAt: Date?
    private var pendingVerifySince: Date?
    private var backoffDelay: TimeInterval = 0
    private var healInProgress = false
    private var embeddedExtensionURL: URL?
    private var lifecycleGeneration: UInt64 = 0

    private init() {}

    // MARK: - 启动（幂等；主线程调用，Timer 挂 main RunLoop）

    func start() {
        guard BackgroundRuntimeRole.isHelper, !BackgroundRuntimeRole.isIsolatedTest else { return }
        stateLock.lock()
        if started {
            stateLock.unlock()
            return
        }
        started = true
        lifecycleGeneration &+= 1
        embeddedExtensionURL = WaifuXHostBundle.bundleURL
            .appendingPathComponent("Contents/PlugIns/WaifuXWallpaperExtension.appex", isDirectory: true)
        stateLock.unlock()

        installDarwinObserver()

        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        pollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        os_log(.info, log: log, "ExtensionHealer started (poll=%{public}llds)", Int(pollInterval))
    }

    func stop() {
        stateLock.lock()
        started = false
        lifecycleGeneration &+= 1
        consecutiveMissing = 0
        pendingVerifySince = nil
        healInProgress = false
        let timer = pollTimer
        pollTimer = nil
        stateLock.unlock()
        timer?.invalidate()
        CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque())
    }

    // MARK: - Darwin 通知（扩展 agentStuck）

    private func installDarwinObserver() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let healer = Unmanaged<WallpaperExtensionAgentHealer>.fromOpaque(observer).takeUnretainedValue()
                healer.handleAgentStuckSignal()
            },
            Self.agentStuckDarwinNotification as CFString,
            nil,
            .deliverImmediately
        )
    }

    fileprivate func handleAgentStuckSignal() {
        // 扩展仍在运行时不能执行注册；这里只允许进程已消失时尝试恢复。
        heal(reason: "spiral-signal-from-extension")
    }

    // MARK: - 周期检查

    private func tick() {
        stateLock.lock()
        let isStarted = started
        stateLock.unlock()
        guard isStarted else { return }
        let selection = WallpaperStoreSelectionProbe.currentSelection()
        guard selection == .selected else {
            // 用户没选我们（或读不到 Index.plist），一切归零
            stateLock.lock()
            consecutiveMissing = 0
            stateLock.unlock()
            return
        }

        let pids = extensionProcessPids()
        if !pids.isEmpty {
            verifySuccessIfPending()
            stateLock.lock()
            consecutiveMissing = 0
            stateLock.unlock()
            return
        }

        verifyTimeoutIfPending()

        stateLock.lock()
        consecutiveMissing += 1
        let shouldHeal = consecutiveMissing >= confirmTicks
        stateLock.unlock()

        if shouldHeal {
            heal(reason: "extension-process-missing")
        }
    }

    // MARK: - 自愈动作

    private func heal(reason: String) {
        guard WallpaperStoreSelectionProbe.currentSelection() == .selected,
              extensionProcessPids().isEmpty else { return }
        stateLock.lock()
        if !started || healInProgress || pendingVerifySince != nil {
            stateLock.unlock()
            return
        }
        if let last = lastHealAt {
            let elapsed = Date().timeIntervalSince(last)
            let cooldown = healCooldown + backoffDelay
            if elapsed < cooldown {
                stateLock.unlock()
                os_log(.info, log: log, "heal skipped (%{public}@): cooldown %{public}lld/%{public}lld", reason, Int64(elapsed), Int64(cooldown))
                return
            }
        }
        let now = Date()
        guard let extensionURL = embeddedExtensionURL else {
            stateLock.unlock()
            return
        }
        lastHealAt = now
        pendingVerifySince = now
        healInProgress = true
        let generation = lifecycleGeneration
        stateLock.unlock()

        os_log(.info, log: log, "extension missing while selected (%{public}@) → safe registration", reason)
        DispatchQueue.global(qos: .utility).async { [weak self, extensionURL] in
            guard let self else { return }
            let ok = WallpaperExtensionKeeper.reviveExtension(at: extensionURL, shouldContinue: { [weak self] in
                self?.isCurrentHealingGeneration(generation) == true
            })
            self.stateLock.lock()
            if self.lifecycleGeneration == generation { self.healInProgress = false }
            self.stateLock.unlock()
            os_log(.info, log: self.log, "safe extension registration %{public}@", ok ? "succeeded" : "failed")
        }
    }

    private func isCurrentHealingGeneration(_ generation: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return started && lifecycleGeneration == generation
    }

    private func verifySuccessIfPending() {
        stateLock.lock()
        guard pendingVerifySince != nil else {
            stateLock.unlock()
            return
        }
        pendingVerifySince = nil
        backoffDelay = 0
        stateLock.unlock()
        os_log(.info, log: log, "extension relaunched after heal — backoff reset")
    }

    private func verifyTimeoutIfPending() {
        stateLock.lock()
        guard let since = pendingVerifySince else {
            stateLock.unlock()
            return
        }
        guard Date().timeIntervalSince(since) > verifyWindow else {
            stateLock.unlock()
            return
        }
        pendingVerifySince = nil
        backoffDelay = min(backoffDelay == 0 ? backoffBase : backoffDelay * 2, backoffCap)
        let delay = backoffDelay
        stateLock.unlock()
        os_log(.error, log: log, "extension NOT relaunched within %{public}llds — backing off %{public}llds", Int64(verifyWindow), Int64(delay))
    }

    // MARK: - 系统探查

    /// 扩展进程枚举（与 keeper 同款 libproc 实现）。桌面实例与锁屏实例共用同一
    /// 可执行名，任何实例存活都算活着——绝不误杀健康 agent。
    private func extensionProcessPids() -> [pid_t] {
        let needed = proc_listallpids(nil, 0)
        guard needed > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(needed) + 8)
        // buffersize 单位是字节（libproc 语义），返回值是实际填充的 pid 个数
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }

        var result: [pid_t] = []
        result.reserveCapacity(Int(count))
        for pid in pids.prefix(Int(count)) {
            var buf = [CChar](repeating: 0, count: 4096)
            let len = proc_pidpath(pid, &buf, UInt32(buf.count))
            guard len > 0 else { continue }
            if String(decoding: buf.prefix(Int(len)).map { UInt8(bitPattern: $0) }, as: UTF8.self).hasSuffix("WaifuXWallpaperExtension") {
                result.append(pid)
            }
        }
        return result
    }
}
