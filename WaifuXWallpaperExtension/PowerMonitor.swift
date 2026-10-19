//  系统电源状态监控
//
//  追踪热状态、电池状态、显示亮度和游戏模式，用于控制视频壁纸播放策略。
//  热状态通过 ProcessInfo.thermalStateDidChangeNotification 事件驱动；
//  电池状态通过 IOKit API 轮询 (NSBackgroundActivityScheduler)；
//  亮度通过 IORegistry 读取内建显示屏背光值。
//
//  消费者通过 `stateChanges()` AsyncStream 订阅状态变化。
//
//  参考 Phosphene (MIT) 的实现。

import Foundation
import IOKit.ps
import os

final class PowerMonitor: Sendable {
    static let shared = PowerMonitor()

    private let state = OSAllocatedUnfairLock(initialState: PowerState())
    private let continuations = OSAllocatedUnfairLock(initialState: [UUID: AsyncStream<PowerState>.Continuation]())
    nonisolated(unsafe) private var _batteryScheduler: NSBackgroundActivityScheduler?
    /// IOKit 电源变化通知源：30s 轮询兜底之外的即时通道。
    /// 挂主 runloop，不依赖渲染/喂帧循环，因此 `.paused` 停掉解码后仍然有效。
    nonisolated(unsafe) private var _powerSourceRunLoopSource: CFRunLoopSource?
    nonisolated(unsafe) private var _lowPowerModeObserver: NSObjectProtocol?

    struct PowerState: Sendable, Equatable {
        var thermalState: ProcessInfo.ThermalState = .nominal
        var isOnBattery = false
        var batteryLevel: Int = 100
        var isGameModeActive: Bool = false
        /// 系统「低功耗模式」是否开启。与电池状态独立，插电时也可能开启。
        var isLowPowerMode = false
        /// 内建显示屏背光亮度，0.0–1.0。无法读取时默认为 1.0（外接显示器、无头 Mac 等）。
        var displayBrightness: Float = 1.0

        var shouldPause: Bool {
            if thermalState == .critical || thermalState == .serious { return true }
            if isOnBattery, batteryLevel < 20 { return true }
            if displayBrightness < Self.brightnessPauseThreshold { return true }
            return false
        }

        /// 低于此亮度时屏幕对用户不可见（即使 screensDidSleepNotification 未触发），
        /// 视为已暂停以节省电量。
        static let brightnessPauseThreshold: Float = 0.05
    }

    private init() {}

    /// 当前电源状态快照
    var currentState: PowerState {
        state.withLock { $0 }
    }

    /// 电源条件是否需要暂停播放
    var shouldPause: Bool {
        state.withLock { $0.shouldPause }
    }

    /// AsyncStream，在电源状态任何组件变化时发送新值。
    /// 订阅时立即发送当前值。
    func stateChanges() -> AsyncStream<PowerState> {
        let (stream, continuation) = AsyncStream.makeStream(of: PowerState.self)
        let id = UUID()
        continuations.withLock { $0[id] = continuation }

        continuation.onTermination = { [weak self] _ in
            self?.continuations.withLock { $0[id] = nil }
        }

        continuation.yield(currentState)
        return stream
    }

    /// 启动电源监控。在扩展初始化时调用一次。
    func startMonitoring() {
        state.withLock {
            $0.thermalState = ProcessInfo.processInfo.thermalState
        }
        refreshNow()

        // 热状态 — 事件驱动
        NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: nil
        ) { [weak self] _ in
            self?.handleThermalChange()
        }

        // 电源来源 — IOKit 通知驱动，插拔电源即时重算策略；
        // 30s 轮询（下方 scheduler）仍然保留作为兜底。
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let callback: @convention(c) (UnsafeMutableRawPointer?) -> Void = { context in
            guard let context else { return }
            Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue().handlePowerSourceNotification()
        }
        if let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            _powerSourceRunLoopSource = source
        }

        // 系统低功耗模式 — 与电池状态独立（插电也可能开启）。
        _lowPowerModeObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil, queue: nil
        ) { [weak self] _ in
            self?.handleLowPowerModeChange()
        }

        // 电池 + 亮度 — OS 管理的定期轮询。
        // 亮度需要轮询因为 IODisplay 在用户拖动滑块时不会广播通知，
        // 且手动将亮度拖到零时 screensDidSleep 不会触发。
        let scheduler = NSBackgroundActivityScheduler(
            identifier: "com.waifux.app.powerCheck"
        )
        scheduler.interval = 30
        scheduler.tolerance = 15
        scheduler.repeats = true
        scheduler.qualityOfService = .utility
        nonisolated(unsafe) let capturedScheduler = scheduler
        scheduler.schedule { [weak self] completion in
            guard let self else {
                completion(.finished)
                return
            }
            if capturedScheduler.shouldDefer {
                completion(.deferred)
                return
            }
            updateBatteryState()
            updateBrightnessState()
            completion(.finished)
        }
        _batteryScheduler = scheduler

        let thermal = ProcessInfo.processInfo.thermalState.rawValue
        extLog("[PowerMonitor] 已启动 (thermal: \(thermal))")
    }

    /// 设备从睡眠恢复时，亮度和电源来源可能在通知到达前后发生变化。
    /// 立即刷新，避免睡眠期间读取到的 0 亮度一直把壁纸策略锁在暂停状态。
    func refreshNow() {
        updateBatteryState()
        updateBrightnessState()
        updateLowPowerModeState()
    }

    // MARK: - Private

    /// IOKit 电源变化（C 回调，主 runloop）。
    private func handlePowerSourceNotification() {
        updateBatteryState()
    }

    private func handleLowPowerModeChange() {
        updateLowPowerModeState()
    }

    private func updateLowPowerModeState() {
        let isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        let previous = state.withLock { $0 }
        state.withLock { $0.isLowPowerMode = isLowPowerMode }
        let current = state.withLock { $0 }
        guard previous != current else { return }
        extLog("[PowerMonitor] 低功耗模式 → \(isLowPowerMode)")
        yieldToSubscribers(current)
    }

    private func handleThermalChange() {
        let previous = state.withLock { $0 }
        state.withLock { $0.thermalState = ProcessInfo.processInfo.thermalState }
        let current = state.withLock { $0 }
        guard previous != current else { return }
        extLog("[PowerMonitor] 热状态 → shouldPause: \(current.shouldPause)")
        yieldToSubscribers(current)
    }

    private func updateBatteryState() {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [Any],
              let first = sources.first,
              let desc = IOPSGetPowerSourceDescription(snapshot, first as CFTypeRef)?.takeUnretainedValue() as? [String: Any]
        else { return }

        let isOnBattery: Bool = if let powerSource = desc[kIOPSPowerSourceStateKey] as? String {
            powerSource == kIOPSBatteryPowerValue
        } else {
            false
        }
        let batteryLevel = desc[kIOPSCurrentCapacityKey] as? Int ?? 100

        let previous = state.withLock { $0 }
        state.withLock { s in
            s.isOnBattery = isOnBattery
            s.batteryLevel = batteryLevel
        }
        let current = state.withLock { $0 }
        guard previous != current else { return }
        extLog("[PowerMonitor] 电池 → shouldPause: \(current.shouldPause)")
        yieldToSubscribers(current)
    }

    /// 通过 IORegistry 读取内建显示屏背光亮度。
    /// 无背光的系统（Mac mini、Mac Studio、纯外接显示）返回 1.0，策略不会降级到暂停。
    private func updateBrightnessState() {
        let brightness = Self.readBuiltInBrightness() ?? 1.0
        let previous = state.withLock { $0 }
        state.withLock { $0.displayBrightness = brightness }
        let current = state.withLock { $0 }
        guard previous != current else { return }
        extLog("[PowerMonitor] 亮度 → \(brightness), shouldPause: \(current.shouldPause)")
        yieldToSubscribers(current)
    }

    private static func readBuiltInBrightness() -> Float? {
        let matching = IOServiceMatching("AppleBacklightDisplay")
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iter) }

        var brightness: Float?
        while case let service = IOIteratorNext(iter), service != IO_OBJECT_NULL {
            defer { IOObjectRelease(service) }
            guard let propsRef = IORegistryEntryCreateCFProperty(
                service,
                "IODisplayParameters" as CFString,
                kCFAllocatorDefault,
                0
            ) else { continue }
            guard let params = propsRef.takeRetainedValue() as? [String: Any],
                  let brightnessParam = params["brightness"] as? [String: Any],
                  let value = brightnessParam["value"] as? Int,
                  let min = brightnessParam["min"] as? Int,
                  let max = brightnessParam["max"] as? Int,
                  max > min
            else { continue }
            brightness = Float(value - min) / Float(max - min)
            break
        }
        return brightness
    }

    private func yieldToSubscribers(_ value: PowerState) {
        continuations.withLock { dict in
            for continuation in dict.values {
                continuation.yield(value)
            }
        }
    }
}
