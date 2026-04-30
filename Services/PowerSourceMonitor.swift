import Foundation
import IOKit.ps

// MARK: - 电源状态变化通知
extension Notification.Name {
    static let powerSourceDidChange = Notification.Name("powerSourceDidChange")
}

// MARK: - IOKit 回调（C 函数指针）
private func handlePowerSourceChange(context: UnsafeMutableRawPointer?) {
    guard let ctx = context else { return }
    let monitor = Unmanaged<PowerSourceMonitor>.fromOpaque(ctx).takeUnretainedValue()
    Task { @MainActor in
        monitor.onPowerSourceChanged()
    }
}

/// 电源状态监控器
/// 使用 IOKit 通知驱动方式监听电源状态变化（AC / 电池切换）
@MainActor
final class PowerSourceMonitor: ObservableObject {
    static let shared = PowerSourceMonitor()

    @Published private(set) var isOnBatteryPower: Bool = false

    private var runLoopSource: CFRunLoopSource?
    private var lastKnownState: Bool = false

    private init() {
        self.isOnBatteryPower = Self.checkBatteryState()
        self.lastKnownState = self.isOnBatteryPower
    }

    /// 开始监控电源状态变化（IOKit 通知驱动，无需轮询）
    func startMonitoring() {
        // 如果已有 source，先移除
        stopMonitoring()

        // 立即检测一次当前状态
        let current = Self.checkBatteryState()
        if current != lastKnownState {
            lastKnownState = current
            isOnBatteryPower = current
            postNotification()
        }

        // 注册 IOKit 电源状态变化通知
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let callback: @convention(c) (UnsafeMutableRawPointer?) -> Void = handlePowerSourceChange
        runLoopSource = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue()

        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }

    /// 停止监控
    func stopMonitoring() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
    }

    /// 立即刷新当前状态（不触发通知）
    func refreshState() {
        let current = Self.checkBatteryState()
        isOnBatteryPower = current
        lastKnownState = current
    }

    // MARK: - 内部

    /// 由 IOKit 回调触发（已在 Task @MainActor 中）
    nonisolated func onPowerSourceChanged() {
        let current = PowerSourceMonitor.checkBatteryState()
        Task { @MainActor in
            if current != self.lastKnownState {
                self.lastKnownState = current
                self.isOnBatteryPower = current
                self.postNotification()
            }
        }
    }

    private func postNotification() {
        NotificationCenter.default.post(
            name: .powerSourceDidChange,
            object: nil,
            userInfo: ["isOnBatteryPower": isOnBatteryPower]
        )
    }

    /// 使用 IOKit 检测当前是否使用电池供电
    private static nonisolated func checkBatteryState() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return false
        }
        guard let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return false
        }

        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                  let powerSourceState = info[kIOPSPowerSourceStateKey] as? String else {
                continue
            }
            if powerSourceState == kIOPSBatteryPowerValue {
                return true
            }
        }

        return false
    }
}
