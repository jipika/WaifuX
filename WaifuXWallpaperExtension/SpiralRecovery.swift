//  SpiralRecovery.swift
//  WallpaperAgent 死亡螺旋自愈信号（移植自 Phosphene 的同名设计）
//
//  背景（macOS 27 实测）：WallpaperAgent 偶发进入「空连接螺旋」——不断接受
//  XPC 连接却不发任何方法调用就断开（2026-09-24 18:03 同时观察到 snapshot
//  连续 NSCocoaErrorDomain 4101）。连续空连接可作为健康检查线索；服务过实际
//  方法的连接会把计数清零。达到阈值并不等于已确认系统宿主失效。
//
//  动作：发 Darwin 通知给后台 Helper 的 WallpaperExtensionAgentHealer，
//  由它执行带存活检查与退避的安全健康检查。不会重启 WallpaperAgent，
//  也不会因本信号重注册仍存活的扩展；系统是否重新 acquire 由系统决定。
//
//  参考：kageroumado/phosphene PhospheneExtension/SpiralRecovery.swift (MIT)

import Foundation
import os

enum SpiralRecovery {
    /// Helper 的 WallpaperExtensionAgentHealer 监听此通知并执行安全健康检查。
    static let agentStuckNotification = "com.waifux.app.wallpaper.agentStuck"

    /// 发出健康检查信号的连续空连接数。
    private static let emptyThreshold = 4

    /// 两次健康检查信号的最小间隔，避免连续空连接造成通知风暴。
    private static let recoveryCooldown: TimeInterval = 20.0

    /// 连续空连接计数。withLock 返回自增后的值，决策放锁外。
    private static let counter = OSAllocatedUnfairLock(initialState: 0)

    private static var lastRecoveryURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("waifux-last-agent-recovery")
    }

    /// 连接至少服务过一个方法 → agent 在正常对话，清零计数。
    static func noteHealthyConnection() {
        counter.withLock { $0 = 0 }
    }

    /// 连接被接受但没调用任何方法就断开。达到阈值时同步发出自愈信号。
    static func noteEmptyConnection(pid: Int32) {
        let count = counter.withLock { n -> Int in n += 1; return n }
        guard count >= emptyThreshold else { return }
        recover(pid: pid, count: count)
    }

    private static func recover(pid: Int32, count: Int) {
        if let data = try? Data(contentsOf: lastRecoveryURL),
           let last = Double((String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) {
            let since = Date().timeIntervalSince1970 - last
            if since < recoveryCooldown {
                extLog("  [spiral] STUCK (agent pid \(pid), \(count) empty) but signaled \(Int(since))s ago (< \(Int(recoveryCooldown))s cooldown) — holding off")
                return
            }
        }
        try? Data("\(Date().timeIntervalSince1970)".utf8).write(to: lastRecoveryURL)
        extLog("  [spiral] \(count) consecutive empty connections from agent pid \(pid), no acquire. Requesting a safe Helper health check.")
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(agentStuckNotification as CFString),
            nil, nil, true,
        )
    }
}
