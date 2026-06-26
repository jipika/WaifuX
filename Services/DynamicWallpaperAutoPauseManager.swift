import Foundation
import AppKit
import CoreGraphics
import Combine

/// 动态壁纸自动暂停管理器
/// 根据用户设置，在以下场景自动暂停/恢复动态壁纸：
/// 1. 前台存在其他应用时（排除 Finder，按屏幕独立判定）
/// 2. 检测到有全屏窗口覆盖桌面时（按屏幕独立暂停）
/// 3. 切换到电池供电时
@MainActor
final class DynamicWallpaperAutoPauseManager {
    static let shared = DynamicWallpaperAutoPauseManager()

    private var checkTimer: Timer?
    private var checkTimerCancellable: AnyCancellable?
    private var cancellables = Set<AnyCancellable>()
    /// 当前因前台存在其他应用而需要暂停的屏幕 ID 集合（按屏幕追踪）
    private var foregroundPausedScreenIDs: Set<String> = []
    /// 当前是否存在"电池供电"这一自动暂停原因。
    private var batteryPauseRequested = false
    /// 全局自动暂停（电池）前，原生视频壁纸里真实处于播放中的屏幕。
    private var globalAutoPausedNativePlayingScreenIDs: Set<String> = []
    /// 触发全局自动暂停（电池）前，原生视频里已经处于手动暂停状态的屏幕。
    private var globalAutoPausedNativeManuallyPausedScreenIDs: Set<String> = []
    /// 全局自动暂停（电池）前，Wallpaper Engine 的全局暂停状态。
    private var globalAutoPausedExternalEngine = false
    /// 当前被全屏窗口覆盖的屏幕 ID 列表。
    private var fullscreenCoveredScreenIDs: Set<String> = []
    /// 全屏检测后台队列（避免 CGWindowListCopyWindowInfo 阻塞主线程）
    private let fullscreenDetectionQueue = DispatchQueue(label: "com.waifux.fullscreen-detection", qos: .utility)
    /// 因全屏覆盖而被自动暂停的原生视频屏幕。
    private var fullscreenAutoPausedScreenIDs: Set<String> = []
    /// 是否因全屏覆盖而自动暂停过 Wallpaper Engine。
    private var fullscreenAutoPausedExternalEngine = false
    private var pendingFullscreenCoveredScreenIDs: Set<String>?
    private var pendingFullscreenSampleCount = 0
    private let requiredStableFullscreenSamples = 2
    /// 因窗口覆盖比例触发而被自动暂停的屏幕 ID
    private var windowCoveragePausedScreenIDs: Set<String> = []
    /// 当前满足"窗口覆盖比例 ≥ 阈值"的屏幕 ID
    private var windowCoverageCoveredScreenIDs: Set<String> = []
    /// 覆盖比例触发的稳定性采样
    private var pendingWindowCoverageScreenIDs: Set<String>?
    private var pendingWindowCoverageSampleCount = 0
    /// 前台应用变化观察者（用于替代 1s 轮询）
    private var appActivationObserver: Any?
    /// 前台应用切换防抖 Task，避免用户连击 Cmd-Tab 时连续触发暂停/恢复
    private var appSwitchDebounceTask: Task<Void, Never>?
    /// 主窗口收起到状态栏时会触发一次前台应用切换；这不是用户希望暂停壁纸的信号。
    private var suppressForegroundPauseUntil: Date?

    // AXObserver for window tracking (event-driven coverage detection)
    private var axObserver: AXObserver?
    private var axObserverRunLoopSource: CFRunLoopSource?
    private var currentAXElement: AXUIElement?
    private let windowCoverageDebouncer = Debouncer(delay: 0.5)
    private static let axCallbackLock = NSLock()
    private static var lastAXCallbackTime: CFAbsoluteTime = 0

    private let pauseWhenOtherAppKey = "pause_when_other_app_foreground"
    private let pauseWhenFullscreenKey = "pause_when_fullscreen_covers"
    private let pauseOnBatteryKey = "pause_on_battery_power"
    private let pauseWhenWindowCoverageKey = "pause_when_window_coverage"
    private let windowCoverageThresholdKey = "window_coverage_pause_threshold"

    /// 前台存在其他应用时自动暂停动态壁纸（排除 Finder）
    var pauseWhenOtherAppForeground: Bool {
        get { UserDefaults.standard.bool(forKey: pauseWhenOtherAppKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: pauseWhenOtherAppKey)
            updateTimer()
        }
    }

    /// 检测到有全屏窗口覆盖时自动暂停动态壁纸
    var pauseWhenFullscreenCovers: Bool {
        get { UserDefaults.standard.bool(forKey: pauseWhenFullscreenKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: pauseWhenFullscreenKey)
            updateTimer()
        }
    }

    /// 切换到电池供电时自动暂停动态壁纸
    var pauseOnBatteryPower: Bool {
        get { UserDefaults.standard.bool(forKey: pauseOnBatteryKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: pauseOnBatteryKey)
            handleBatterySettingChange()
        }
    }

    /// 非本应用窗口对某屏的累计覆盖比例 ≥ 阈值时，按屏暂停该屏壁纸
    var pauseWhenWindowCoverage: Bool {
        get { UserDefaults.standard.bool(forKey: pauseWhenWindowCoverageKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: pauseWhenWindowCoverageKey)
            updateTimer()
        }
    }

    /// 覆盖比例阈值（百分比 30~100）。setter 兼容 0.30~1.0 与 30~100 两种入参。
    var windowCoveragePauseThreshold: Double {
        get {
            let raw = UserDefaults.standard.double(forKey: windowCoverageThresholdKey)
            let percent = raw > 0 ? raw : 50
            return max(30, min(100, percent))
        }
        set {
            let percent = newValue > 1.0 ? newValue : newValue * 100
            let clamped = max(30, min(100, percent))
            UserDefaults.standard.set(clamped, forKey: windowCoverageThresholdKey)
            // 阈值变化时若开关已开，立即重算
            if pauseWhenWindowCoverage {
                checkAndApply()
            }
        }
    }

    private init() {
        // 监听电源状态变化通知
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePowerSourceChange(_:)),
            name: .powerSourceDidChange,
            object: nil
        )
        // 监听前台应用变化（用于替代 1s 轮询检测前台应用）
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleAppActivationChange()
            }
        }

        // 监听 Space 切换（进出全屏会触发），避免全屏检测仅依赖 3s 轮询导致的恢复延迟
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleActiveSpaceChange),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
    }

    func restoreSettings() {
        reevaluateCurrentState()
    }

    /// 当动态壁纸刚被重新应用或被用户手动恢复时，立刻重新计算自动暂停状态。
    func reevaluateCurrentState() {
        updateTimer()
    }

    func suppressForegroundPauseForMainWindowHide(duration: TimeInterval = 1.0) {
        suppressForegroundPauseUntil = Date().addingTimeInterval(duration)
    }

    /// 壁纸切换后清除前台暂停状态。
    /// 新启动的 wallpaper-wgpu 进程不应被旧的前台暂停状态误杀（SIGSTOP）。
    /// 当用户之后切走应用时，NSWorkspace app activation 通知会重新施加前台暂停。
    func clearForegroundPauseForWallpaperSwitch() {
        let pausedIDs = foregroundPausedScreenIDs
        foregroundPausedScreenIDs.removeAll()

        // 同理：壁纸切换后旧的 coverage 状态对新进程无意义，清掉等下一轮 checkAndApply 重建
        windowCoveragePausedScreenIDs.removeAll()
        windowCoverageCoveredScreenIDs.removeAll()
        pendingWindowCoverageScreenIDs = nil
        pendingWindowCoverageSampleCount = 0

        guard !pausedIDs.isEmpty else { return }

        let weBridge = WallpaperEngineXBridge.shared
        if weBridge.isControllingExternalEngine {
            for screenID in pausedIDs where weBridge.isManaging(screenID: screenID) {
                weBridge.resumeWallpaper(for: screenID)
            }
        }

        let videoManager = VideoWallpaperManager.shared
        if videoManager.isVideoWallpaperActive {
            for screen in NSScreen.screens where pausedIDs.contains(screen.wallpaperScreenIdentifier) {
                if !fullscreenAutoPausedScreenIDs.contains(screen.wallpaperScreenIdentifier) {
                    videoManager.resumeWallpaper(for: screen)
                }
            }
        }
    }

    private func updateTimer() {
        let needsPollingForFullscreenOrForeground = pauseWhenFullscreenCovers || pauseWhenOtherAppForeground
        let needsPollingForWindowCoverage = pauseWhenWindowCoverage && !AXIsProcessTrusted()
        let needsTimer = needsPollingForFullscreenOrForeground || needsPollingForWindowCoverage
        if needsTimer {
            // 共用一个 3s 轮询，覆盖两类无法仅靠通知捕获的状态变化：
            // - 全屏覆盖：CGWindowList 无法用通知替代
            // - 前台覆盖：app 已经是 frontmost 时（如最小化所有窗口后再从 dock
            //   还原），NSWorkspace.didActivateApplicationNotification 不会触发，
            //   仅靠通知会漏掉 "frontmost app 的窗口可见性变化" 这条事件流，
            //   必须用 timer 兜底重检 CGWindowList。
            // - 窗口覆盖比例：同样依赖 CGWindowList 周期性扫描
            startTimer(interval: 3.0)
        } else {
            stopTimer()
        }
        syncForegroundPauseRequest()
        syncBatteryPauseRequest()

        if !pauseWhenFullscreenCovers {
            pendingFullscreenCoveredScreenIDs = nil
            pendingFullscreenSampleCount = 0
            fullscreenCoveredScreenIDs.removeAll()

            if !fullscreenAutoPausedScreenIDs.isEmpty {
                let screenIDs = fullscreenAutoPausedScreenIDs
                fullscreenAutoPausedScreenIDs.removeAll()
                if !hasActiveGlobalPauseReason {
                    let stillPausedByOther = foregroundPausedScreenIDs.union(windowCoveragePausedScreenIDs)
                    let canResume = screenIDs.subtracting(stillPausedByOther)
                    if !canResume.isEmpty { resumeScreens(byIDs: canResume) }
                }
            }

            if fullscreenAutoPausedExternalEngine {
                fullscreenAutoPausedExternalEngine = false
                if !hasActiveGlobalPauseReason,
                   WallpaperEngineXBridge.shared.isControllingExternalEngine,
                   WallpaperEngineXBridge.shared.isExternalPaused {
                    WallpaperEngineXBridge.shared.resumeWallpaper()
                }
            }
        }

        if !pauseWhenWindowCoverage {
            pendingWindowCoverageScreenIDs = nil
            pendingWindowCoverageSampleCount = 0
            windowCoverageCoveredScreenIDs.removeAll()

            if !windowCoveragePausedScreenIDs.isEmpty {
                let screenIDs = windowCoveragePausedScreenIDs
                windowCoveragePausedScreenIDs.removeAll()
                if !hasActiveGlobalPauseReason {
                    let stillPausedByOther = foregroundPausedScreenIDs.union(fullscreenAutoPausedScreenIDs)
                    let canResume = screenIDs.subtracting(stillPausedByOther)
                    if !canResume.isEmpty {
                        resumeScreens(byIDs: canResume)
                        let weBridge = WallpaperEngineXBridge.shared
                        if weBridge.isControllingExternalEngine {
                            for sid in canResume where weBridge.isManaging(screenID: sid) {
                                weBridge.resumeWallpaper(for: sid)
                            }
                        }
                    }
                }
            }
        }

        // 窗口覆盖 + AX 可用：事件驱动模式，立即 setup AXObserver
        if pauseWhenWindowCoverage && AXIsProcessTrusted() {
            handleAppActivationChange()
        }

        // 窗口覆盖关闭时，停止 AXObserver
        if !pauseWhenWindowCoverage {
            stopAXObserver()
        }
    }

    private func startTimer(interval: TimeInterval) {
        stopTimer()
        // 使用 Combine Timer.publish 替代 Timer.scheduledTimer（后者闭包非 @MainActor，
        // 用 Task { @MainActor } 包装会触发 _dispatch_assert_queue_fail）
        checkTimerCancellable = Timer.publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .sink { @MainActor [weak self] _ in
                self?.checkAndApply()
            }
        checkAndApply()
    }

    private func stopTimer() {
        checkTimerCancellable?.cancel()
        checkTimerCancellable = nil
        checkTimer?.invalidate()
        checkTimer = nil
        stopAXObserver()
    }

    private func checkAndApply() {
        let hasNative = VideoWallpaperManager.shared.isVideoWallpaperActive
        let hasExternal = WallpaperEngineXBridge.shared.isControllingExternalEngine
        guard hasNative || hasExternal else {
            foregroundPausedScreenIDs.removeAll()
            batteryPauseRequested = false
            globalAutoPausedNativePlayingScreenIDs.removeAll()
            globalAutoPausedNativeManuallyPausedScreenIDs.removeAll()
            globalAutoPausedExternalEngine = false
            fullscreenCoveredScreenIDs.removeAll()
            fullscreenAutoPausedScreenIDs.removeAll()
            fullscreenAutoPausedExternalEngine = false
            pendingFullscreenCoveredScreenIDs = nil
            pendingFullscreenSampleCount = 0
            windowCoveragePausedScreenIDs.removeAll()
            windowCoverageCoveredScreenIDs.removeAll()
            pendingWindowCoverageScreenIDs = nil
            pendingWindowCoverageSampleCount = 0
            return
        }

        // 锁屏/解锁期间由 VideoWallpaperManager 自行管理播放状态，AutoPause 不介入，避免竞态
        guard !VideoWallpaperManager.shared.isScreenLocked else { return }

        // 前台覆盖检测兜底：当 frontmost app 没切换、但其窗口可见性变了
        // （例如所有窗口最小化后从 dock 重新还原），didActivate 不会触发，
        // 这里用 timer 周期同步重检。
        if pauseWhenOtherAppForeground {
            reevaluateForegroundCoverage()
        }

        // 窗口覆盖比例检测（按屏，独立稳定性采样）
        // 有 AX 权限时由 AXObserver 事件驱动，不走 timer 轮询
        if pauseWhenWindowCoverage && !AXIsProcessTrusted() {
            let thresholdRatio = CGFloat(windowCoveragePauseThreshold / 100.0)
            fullscreenDetectionQueue.async { [weak self] in
                guard let self else { return }
                let screens = self.getWindowCoverageCoveredScreens(threshold: thresholdRatio)
                let ids = Set(screens.map { $0.wallpaperScreenIdentifier })
                DispatchQueue.main.async { [weak self] in
                    self?.applyWindowCoverageDetectionResult(newIDs: ids, screens: screens)
                }
            }
        }

        // Timer 驱动的全屏覆盖检测
        guard pauseWhenFullscreenCovers else { return }

        // CGWindowListCopyWindowInfo 是重量级系统调用，移到后台线程避免阻塞主线程
        fullscreenDetectionQueue.async { [weak self] in
            guard let self else { return }
            let fullscreenCoveredScreens = self.getFullscreenCoveredScreens()
            let newFullscreenIDs = Set(fullscreenCoveredScreens.map { $0.wallpaperScreenIdentifier })

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.applyFullscreenDetectionResult(newFullscreenIDs: newFullscreenIDs, fullscreenCoveredScreens: fullscreenCoveredScreens)
            }
        }
    }

    /// 在主线程处理全屏检测结果
    private func applyFullscreenDetectionResult(newFullscreenIDs: Set<String>, fullscreenCoveredScreens: [NSScreen]) {
        guard newFullscreenIDs != fullscreenCoveredScreenIDs else {
            pendingFullscreenCoveredScreenIDs = nil
            pendingFullscreenSampleCount = 0
            return
        }
        guard isStableFullscreenTransition(to: newFullscreenIDs) else { return }

        let previouslyCoveredIDs = fullscreenCoveredScreenIDs
        fullscreenCoveredScreenIDs = newFullscreenIDs

        let screenIDsToResume = fullscreenAutoPausedScreenIDs.subtracting(newFullscreenIDs)
        if !screenIDsToResume.isEmpty {
            fullscreenAutoPausedScreenIDs.subtract(screenIDsToResume)
            // 排除当前被前台暂停或窗口覆盖比例暂停的屏幕（独立机制，不应被全屏恢复 override）
            let filteredResumeIDs = screenIDsToResume
                .subtracting(foregroundPausedScreenIDs)
                .subtracting(windowCoveragePausedScreenIDs)
            if !filteredResumeIDs.isEmpty, !hasActiveGlobalPauseReason {
                resumeScreens(byIDs: filteredResumeIDs)
            }
        }

        let screensToPause = fullscreenCoveredScreens.filter { screen in
            !previouslyCoveredIDs.contains(screen.wallpaperScreenIdentifier)
        }
        if !screensToPause.isEmpty {
            let pausedIDs = pauseScreens(screensToPause)
            fullscreenAutoPausedScreenIDs.formUnion(pausedIDs)
        }

        let weBridge = WallpaperEngineXBridge.shared
        let shouldPauseExternal = weBridge.isControllingExternalEngine &&
            weBridge.shouldPauseForFullscreenCoveredScreenIDs(newFullscreenIDs)
        if shouldPauseExternal {
            if !hasActiveGlobalPauseReason && !weBridge.isExternalPaused {
                weBridge.pauseWallpaper()
                fullscreenAutoPausedExternalEngine = true
            }
        } else if fullscreenAutoPausedExternalEngine {
            if !hasActiveGlobalPauseReason, weBridge.isExternalPaused {
                weBridge.resumeWallpaper()
            }
            fullscreenAutoPausedExternalEngine = false
        }
    }

    // MARK: - 电池供电处理

    private func handleBatterySettingChange() {
        if pauseOnBatteryPower {
            PowerSourceMonitor.shared.startMonitoring()
        } else {
            PowerSourceMonitor.shared.stopMonitoring()
        }
        syncBatteryPauseRequest()
    }

    @objc private func handlePowerSourceChange(_ notification: Notification) {
        guard pauseOnBatteryPower else { return }
        guard let userInfo = notification.userInfo,
              let isOnBattery = userInfo["isOnBatteryPower"] as? Bool else { return }

        if isOnBattery {
            handleBatterySwitchedToBattery()
        } else {
            handleBatterySwitchedToAC()
        }
    }

    /// 切换到电池供电：自动暂停壁纸（如果正在播放）
    private func handleBatterySwitchedToBattery() {
        batteryPauseRequested = true
        applyGlobalPauseIfNeeded()
    }

    /// 切换回 AC 电源：如果之前是电池自动暂停的，恢复播放
    private func handleBatterySwitchedToAC() {
        batteryPauseRequested = false
        resumeFromGlobalPauseIfPossible()
    }

    // MARK: - 前台应用检测（按屏幕）

    /// 前台应用切换时由通知驱动，无需轮询
    private func handleAppActivationChange() {
        guard pauseWhenOtherAppForeground || pauseWhenWindowCoverage else { return }
        guard !isForegroundPauseSuppressed else { return }
        let hasNative = VideoWallpaperManager.shared.isVideoWallpaperActive
        let hasExternal = WallpaperEngineXBridge.shared.isControllingExternalEngine
        guard hasNative || hasExternal else { return }
        guard !VideoWallpaperManager.shared.isScreenLocked else { return }

        appSwitchDebounceTask?.cancel()
        appSwitchDebounceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return // 被取消
            }
            guard let self else { return }

            // 前台覆盖检测（保持原逻辑）
            if self.pauseWhenOtherAppForeground {
                self.reevaluateForegroundCoverage()
            }

            // AXObserver 管理（窗口覆盖事件驱动）
            if self.pauseWhenWindowCoverage {
                let frontApp = NSWorkspace.shared.frontmostApplication
                let bundleID = frontApp?.bundleIdentifier
                let ourBundleID = Bundle.main.bundleIdentifier
                let finderBundleID = "com.apple.finder"

                if let pid = frontApp?.processIdentifier,
                   bundleID != ourBundleID && bundleID != finderBundleID {
                    // 非 Finder 且非本应用：启动 AXObserver + 立即检测一次
                    if AXIsProcessTrusted() {
                        self.setupAXObserver(for: pid)
                    }
                    self.checkWindowCoverage()
                } else {
                    // Finder 或本应用前台：停止 AXObserver + 清除窗口覆盖暂停
                    self.stopAXObserver()
                    self.clearWindowCoveragePause()
                }
            }
        }
    }

    /// 共享的前台覆盖重新评估逻辑：通知路径（防抖后）与 timer 兜底路径都调它，
    /// 计算当前 frontmost app 的可见窗口覆盖了哪些屏幕，与上一次状态做差量
    /// pause/resume。
    private func reevaluateForegroundCoverage() {
        guard pauseWhenOtherAppForeground else { return }
        guard !isForegroundPauseSuppressed else { return }
        let hasNative = VideoWallpaperManager.shared.isVideoWallpaperActive
        let hasExternal = WallpaperEngineXBridge.shared.isControllingExternalEngine
        guard hasNative || hasExternal else { return }
        guard !VideoWallpaperManager.shared.isScreenLocked else { return }

        let newlyCoveredScreens = getForegroundAppCoveredScreens()
        let newForegroundPausedIDs = Set(newlyCoveredScreens.map { $0.wallpaperScreenIdentifier })
        let previouslyPausedIDs = foregroundPausedScreenIDs

        guard newForegroundPausedIDs != previouslyPausedIDs else { return }
        foregroundPausedScreenIDs = newForegroundPausedIDs

        // 电池暂停期间：只记录前台状态变化，不实际暂停/恢复壁纸
        // 壁纸已由电池全局暂停，恢复时会根据当前 foregroundPausedScreenIDs 重新施加前台暂停
        guard !batteryPauseRequested else { return }

        // 恢复不再被前台应用覆盖的屏幕
        let screenIDsToResume = previouslyPausedIDs.subtracting(newForegroundPausedIDs)
        if !screenIDsToResume.isEmpty {
            applyPerScreenForegroundResume(screenIDs: screenIDsToResume)
        }

        // 暂停新被前台应用覆盖的屏幕
        let screenIDsToPause = newForegroundPausedIDs.subtracting(previouslyPausedIDs)
        if !screenIDsToPause.isEmpty {
            applyPerScreenForegroundPause(screenIDs: screenIDsToPause)
        }
    }

    /// 按屏幕施加前台暂停
    private func applyPerScreenForegroundPause(screenIDs: Set<String>) {
        let videoManager = VideoWallpaperManager.shared
        let weBridge = WallpaperEngineXBridge.shared

        for screenID in screenIDs {
            // 暂停原生视频壁纸
            if videoManager.isVideoWallpaperActive {
                for screen in NSScreen.screens where screen.wallpaperScreenIdentifier == screenID {
                    if !videoManager.isPaused(on: screen) &&
                        !fullscreenAutoPausedScreenIDs.contains(screenID) &&
                        !windowCoveragePausedScreenIDs.contains(screenID) {
                        videoManager.pauseWallpaper(for: screen)
                    }
                    break
                }
            }

            // 暂停外部引擎
            if weBridge.isControllingExternalEngine && weBridge.isManaging(screenID: screenID) {
                weBridge.pauseWallpaper(for: screenID)
            }
        }
    }

    /// 按屏幕恢复前台暂停
    private func applyPerScreenForegroundResume(screenIDs: Set<String>) {
        let videoManager = VideoWallpaperManager.shared
        let weBridge = WallpaperEngineXBridge.shared

        for screenID in screenIDs {
            // 恢复原生视频壁纸（排除全屏暂停 + 窗口覆盖比例暂停）
            if videoManager.isVideoWallpaperActive {
                for screen in NSScreen.screens where screen.wallpaperScreenIdentifier == screenID {
                    if !fullscreenAutoPausedScreenIDs.contains(screenID) &&
                        !windowCoveragePausedScreenIDs.contains(screenID) {
                        videoManager.resumeWallpaper(for: screen)
                    }
                    break
                }
            }

            // 恢复外部引擎（排除窗口覆盖比例暂停）
            if weBridge.isControllingExternalEngine &&
                weBridge.isManaging(screenID: screenID) &&
                !windowCoveragePausedScreenIDs.contains(screenID) {
                weBridge.resumeWallpaper(for: screenID)
            }
        }
    }

    /// 获取前台应用的窗口覆盖了哪些屏幕
    /// 通过 CGWindowListCopyWindowInfo 查找前台应用（非本应用、非 Finder）的窗口位置
    private func getForegroundAppCoveredScreens() -> [NSScreen] {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            return []
        }
        let frontmostPID = frontmostApp.processIdentifier

        let ourBundleID = Bundle.main.bundleIdentifier
        let finderBundleID = "com.apple.finder"
        let frontBundleID = frontmostApp.bundleIdentifier

        // 前台是本应用或 Finder → 没有"其他应用"覆盖
        guard frontBundleID != ourBundleID && frontBundleID != finderBundleID else {
            return []
        }

        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        let screens = NSScreen.screens
        let desktopFrame = screens.reduce(CGRect.null) { $0.union($1.frame) }
        var coveredScreens: [NSScreen] = []

        // 找到前台应用的所有可见窗口
        let appWindows = windowList.filter { window in
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? Int,
                  ownerPID == frontmostPID else { return false }
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0 else { return false }
            guard let alpha = window[kCGWindowAlpha as String] as? Double, alpha > 0 else { return false }
            return true
        }

        guard !appWindows.isEmpty else { return [] }

        // 检查这些窗口覆盖了哪些屏幕
        for screen in screens {
            let screenFrame = screen.frame
            let screenArea = screenFrame.width * screenFrame.height
            var isCovered = false

            for window in appWindows {
                guard let boundsDict = window[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
                let rawBounds = CGRect(
                    x: boundsDict["X"] ?? 0,
                    y: boundsDict["Y"] ?? 0,
                    width: boundsDict["Width"] ?? 0,
                    height: boundsDict["Height"] ?? 0
                )
                let bounds = Self.normalizedWindowBounds(rawBounds, screens: screens, desktopFrame: desktopFrame)

                // 检查窗口是否覆盖了该屏幕的大部分区域
                let intersection = bounds.intersection(screenFrame)
                guard !intersection.isNull, !intersection.isEmpty else { continue }

                let coveredArea = intersection.width * intersection.height
                // 窗口覆盖屏幕 >= 30% 面积视为"覆盖"（低于全屏检测的 95%，因为普通窗口通常不会全屏）
                if coveredArea >= screenArea * 0.3 {
                    isCovered = true
                    break
                }
            }

            if isCovered {
                coveredScreens.append(screen)
            }
        }

        return coveredScreens
    }

    @objc private func handleActiveSpaceChange() {
        guard !VideoWallpaperManager.shared.isScreenLocked else { return }

        // Space 切换时 frontmostApplication 可能不变（同一 app 在多个 Space 都有窗口），
        // 因此 NSWorkspace.didActivateApplicationNotification 不会触发；
        // 但每个 Space 可见的窗口集合不同，必须显式重跑前台覆盖检测，
        // 否则 Space 1 上"被前台 app 覆盖→暂停"的屏幕状态会一直挂着，
        // 切到 Space 2（无覆盖）也不恢复；反向也一样：Space 1 在播，
        // 切到 Space 2 有覆盖也不暂停。
        if pauseWhenOtherAppForeground {
            handleAppActivationChange()
        }

        // Space 切换（进出全屏）时立即重新检测，不等 3s 轮询
        if pauseWhenFullscreenCovers {
            checkAndApply()
        }

        // 覆盖比例同样依赖窗口几何，Space 切换需要立即重检
        if pauseWhenWindowCoverage && !pauseWhenFullscreenCovers && !pauseWhenOtherAppForeground {
            checkAndApply()
        }
    }

    /// 检查前台是否是非本应用且非 Finder 的其他应用（全局判断，供旧逻辑兼容）
    private func isOtherAppInForeground() -> Bool {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else { return false }
        let bundleID = frontmostApp.bundleIdentifier
        let ourBundleID = Bundle.main.bundleIdentifier
        let finderBundleID = "com.apple.finder"
        return bundleID != ourBundleID && bundleID != finderBundleID
    }

    private var isForegroundPauseSuppressed: Bool {
        guard let suppressForegroundPauseUntil else { return false }
        if Date() < suppressForegroundPauseUntil {
            return true
        }
        self.suppressForegroundPauseUntil = nil
        return false
    }

    /// 检查当前是否有全屏窗口覆盖桌面
    private func isFullscreenCovering() -> Bool {
        return !getFullscreenCoveredScreens().isEmpty
    }

    /// 获取被全屏窗口覆盖的屏幕列表（可在后台线程调用）
    /// 通过 CGWindowList 检测 layer 0 且覆盖屏幕绝大部分区域的窗口
    /// 排除本应用自身的渲染窗口（如 wallpaper-wgpu 的 Metal 窗口）
    nonisolated private func getFullscreenCoveredScreens() -> [NSScreen] {
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        let screens = NSScreen.screens
        let desktopFrame = screens.reduce(CGRect.null) { $0.union($1.frame) }
        let ourBundleID = Bundle.main.bundleIdentifier
        var coveredScreens: [NSScreen] = []

        for window in windowList {
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let alpha = window[kCGWindowAlpha as String] as? Double, alpha > 0 else { continue }
            guard let boundsDict = window[kCGWindowBounds as String] as? [String: CGFloat] else { continue }

            // 跳过本应用的窗口（wallpaper-wgpu 的 Metal 渲染窗口属于本应用）
            if let ownerPID = window[kCGWindowOwnerPID as String] as? Int,
               let app = NSRunningApplication(processIdentifier: pid_t(ownerPID)),
               app.bundleIdentifier == ourBundleID {
                continue
            }

            let rawBounds = CGRect(
                x: boundsDict["X"] ?? 0,
                y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0,
                height: boundsDict["Height"] ?? 0
            )
            let bounds = Self.normalizedWindowBounds(rawBounds, screens: screens, desktopFrame: desktopFrame)

            // 检查窗口实际覆盖了哪块屏幕。不能只比较宽高：两块同尺寸或外接屏
            // 大于内置屏时，会把未相交的屏幕也误判为被全屏覆盖。
            for screen in screens {
                let screenFrame = screen.frame
                let intersection = bounds.intersection(screenFrame)
                guard !intersection.isNull, !intersection.isEmpty else { continue }

                let coveredArea = intersection.width * intersection.height
                let screenArea = screenFrame.width * screenFrame.height
                if coveredArea >= screenArea * 0.95 &&
                   intersection.width >= screenFrame.width * 0.95 &&
                   intersection.height >= screenFrame.height * 0.95 {
                    if !coveredScreens.contains(where: { $0.wallpaperScreenIdentifier == screen.wallpaperScreenIdentifier }) {
                        coveredScreens.append(screen)
                    }
                }
            }
        }
        return coveredScreens
    }

    nonisolated private static func captureWindowSnapshot(screenFrames: [String: CGRect]) -> WindowSnapshot? {
        let screens = NSScreen.screens.filter { screenFrames[$0.wallpaperScreenIdentifier] != nil }
        let screenRects = Array(screenFrames.values)
        let desktopFrame = screenRects.reduce(CGRect.null) { $0.union($1) }

        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        let windows = windowList.compactMap { window -> WindowSnapshot.Window? in
            let pid: pid_t
            if let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t {
                pid = ownerPID
            } else if let ownerPID = window[kCGWindowOwnerPID as String] as? Int {
                pid = pid_t(ownerPID)
            } else {
                return nil
            }

            guard let layer = window[kCGWindowLayer as String] as? Int,
                  let alpha = window[kCGWindowAlpha as String] as? Double,
                  let boundsDict = window[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else {
                return nil
            }

            return WindowSnapshot.Window(
                pid: pid,
                layer: layer,
                alpha: alpha,
                bounds: normalizedWindowBounds(bounds, screens: screens, desktopFrame: desktopFrame)
            )
        }

        return WindowSnapshot(screenFrames: screenFrames, windows: windows)
    }

    nonisolated private static func windowCoverageScreens(
        in snapshot: WindowSnapshot,
        thresholdRatio: CGFloat
    ) -> Set<String> {
        var coveredScreens = Set<String>()
        let myPID = ProcessInfo.processInfo.processIdentifier
        let thresholdSamples = Int(ceil(CGFloat(CoverageSampling.sampleCount) * thresholdRatio))

        for (screenID, screenFrame) in snapshot.screenFrames {
            let candidateRects = snapshot.windows.compactMap { window -> CGRect? in
                guard window.isVisibleContentWindow(excluding: myPID) else { return nil }
                let intersection = window.bounds.intersection(screenFrame)
                guard !intersection.isNull, !intersection.isEmpty else { return nil }
                return intersection
            }

            if isGridCoverageAtOrAboveThreshold(
                screenFrame: screenFrame,
                candidateRects: candidateRects,
                thresholdSamples: thresholdSamples
            ) {
                coveredScreens.insert(screenID)
            }
        }

        return coveredScreens
    }

    nonisolated private static func isGridCoverageAtOrAboveThreshold(
        screenFrame: CGRect,
        candidateRects: [CGRect],
        thresholdSamples: Int
    ) -> Bool {
        guard thresholdSamples > 0 else { return true }
        guard !candidateRects.isEmpty, screenFrame.width > 0, screenFrame.height > 0 else { return false }

        let gridSize = CoverageSampling.gridSize
        let totalSamples = CoverageSampling.sampleCount
        let stepX = screenFrame.width / CGFloat(gridSize)
        let stepY = screenFrame.height / CGFloat(gridSize)
        var coveredSamples = 0
        var checkedSamples = 0

        for row in 0..<gridSize {
            let y = screenFrame.minY + (CGFloat(row) + 0.5) * stepY

            for column in 0..<gridSize {
                let x = screenFrame.minX + (CGFloat(column) + 0.5) * stepX
                let samplePoint = CGPoint(x: x, y: y)
                checkedSamples += 1

                for rect in candidateRects where rect.contains(samplePoint) {
                    coveredSamples += 1
                    if coveredSamples >= thresholdSamples {
                        return true
                    }
                    break
                }

                if coveredSamples + (totalSamples - checkedSamples) < thresholdSamples {
                    return false
                }
            }
        }

        return false
    }

    nonisolated private static func normalizedWindowBounds(_ bounds: CGRect, screens: [NSScreen], desktopFrame: CGRect) -> CGRect {
        guard !desktopFrame.isNull else { return bounds }
        let flippedBounds = CGRect(
            x: bounds.origin.x,
            y: desktopFrame.maxY - bounds.origin.y - bounds.height,
            width: bounds.width,
            height: bounds.height
        )

        func totalIntersectionArea(for candidate: CGRect) -> CGFloat {
            screens.reduce(CGFloat.zero) { total, screen in
                let intersection = candidate.intersection(screen.frame)
                guard !intersection.isNull, !intersection.isEmpty else { return total }
                return total + intersection.width * intersection.height
            }
        }

        return totalIntersectionArea(for: flippedBounds) > totalIntersectionArea(for: bounds) ? flippedBounds : bounds
    }

    private func isStableFullscreenTransition(to screenIDs: Set<String>) -> Bool {
        if pendingFullscreenCoveredScreenIDs == screenIDs {
            pendingFullscreenSampleCount += 1
        } else {
            pendingFullscreenCoveredScreenIDs = screenIDs
            pendingFullscreenSampleCount = 1
        }

        guard pendingFullscreenSampleCount >= requiredStableFullscreenSamples else {
            return false
        }

        pendingFullscreenCoveredScreenIDs = nil
        pendingFullscreenSampleCount = 0
        return true
    }

    /// 暂停指定屏幕的原生视频壁纸，仅返回这次真正由自动暂停器触发的屏幕。
    private func pauseScreens(_ screens: [NSScreen]) -> Set<String> {
        let videoManager = VideoWallpaperManager.shared
        var pausedScreenIDs = Set<String>()

        for screen in screens {
            let screenID = screen.wallpaperScreenIdentifier

            // 暂停原生视频壁纸
            if videoManager.isVideoWallpaperActive,
               !videoManager.isPaused(on: screen) {
                videoManager.pauseWallpaper(for: screen)
                pausedScreenIDs.insert(screenID)
            }
        }

        return pausedScreenIDs
    }

    /// 恢复指定屏幕 ID 列表的动态壁纸
    private func resumeScreens(byIDs screenIDs: Set<String>) {
        guard !screenIDs.isEmpty else { return }
        let videoManager = VideoWallpaperManager.shared
        guard videoManager.isVideoWallpaperActive else { return }

        for screen in NSScreen.screens where screenIDs.contains(screen.wallpaperScreenIdentifier) {
            videoManager.resumeWallpaper(for: screen)
        }
    }

    private func syncForegroundPauseRequest() {
        guard pauseWhenOtherAppForeground else {
            // 关闭前台暂停时：恢复所有被前台暂停的屏幕
            if !foregroundPausedScreenIDs.isEmpty {
                let pausedIDs = foregroundPausedScreenIDs
                foregroundPausedScreenIDs.removeAll()
                // 电池暂停期间不实际恢复（电池恢复时会处理）
                if !batteryPauseRequested {
                    applyPerScreenForegroundResume(screenIDs: pausedIDs)
                }
            }
            return
        }
        handleAppActivationChange()
    }

    private func syncBatteryPauseRequest() {
        if pauseOnBatteryPower {
            PowerSourceMonitor.shared.startMonitoring()
        } else {
            PowerSourceMonitor.shared.stopMonitoring()
        }

        guard pauseOnBatteryPower else {
            batteryPauseRequested = false
            resumeFromGlobalPauseIfPossible()
            return
        }
        batteryPauseRequested = PowerSourceMonitor.shared.isOnBatteryPower
        if batteryPauseRequested {
            applyGlobalPauseIfNeeded()
        } else {
            resumeFromGlobalPauseIfPossible()
        }
    }

    /// 应用全局暂停（目前仅电池供电触发）
    /// 暂停所有正在播放的壁纸（原生视频 + 外部引擎），保存恢复所需的状态
    private func applyGlobalPauseIfNeeded() {
        guard hasActiveGlobalPauseReason else { return }

        let videoManager = VideoWallpaperManager.shared
        let weBridge = WallpaperEngineXBridge.shared

        // ---- 外部引擎 ----
        if weBridge.isControllingExternalEngine {
            guard !weBridge.isExternalPaused else { return }
            globalAutoPausedExternalEngine = true
            weBridge.pauseWallpaper()
        } else {
            globalAutoPausedExternalEngine = false
        }

        // ---- 原生视频 ----
        guard videoManager.isVideoWallpaperActive else {
            globalAutoPausedNativePlayingScreenIDs.removeAll()
            globalAutoPausedNativeManuallyPausedScreenIDs.removeAll()
            return
        }
        guard globalAutoPausedNativePlayingScreenIDs.isEmpty else { return }

        let managedScreenIDs = Set(videoManager.activeScreens.map(\.wallpaperScreenIdentifier))
        let playingScreenIDs = videoManager.playingScreenIDs
        guard !playingScreenIDs.isEmpty else { return }

        globalAutoPausedNativePlayingScreenIDs = playingScreenIDs
        globalAutoPausedNativeManuallyPausedScreenIDs = managedScreenIDs
            .subtracting(playingScreenIDs)
            .subtracting(fullscreenAutoPausedScreenIDs)
            .subtracting(foregroundPausedScreenIDs.intersection(managedScreenIDs))

        if !videoManager.isPaused {
            videoManager.pauseWallpaper()
        }
    }

    /// 从全局暂停恢复（目前仅电池从 AC 恢复触发）
    /// 恢复时保留前台暂停的按屏幕状态
    private func resumeFromGlobalPauseIfPossible() {
        guard !hasActiveGlobalPauseReason else { return }

        let videoManager = VideoWallpaperManager.shared
        let weBridge = WallpaperEngineXBridge.shared

        // ---- 外部引擎恢复 ----
        if globalAutoPausedExternalEngine {
            if weBridge.isControllingExternalEngine {
                if weBridge.shouldPauseForFullscreenCoveredScreenIDs(fullscreenCoveredScreenIDs) {
                    fullscreenAutoPausedExternalEngine = true
                } else if weBridge.isExternalPaused {
                    weBridge.resumeWallpaper()
                    fullscreenAutoPausedExternalEngine = false
                } else {
                    fullscreenAutoPausedExternalEngine = false
                }
            } else {
                fullscreenAutoPausedExternalEngine = false
            }
            globalAutoPausedExternalEngine = false

            // 恢复外部引擎后，重新施加前台暂停（如果前台仍有应用覆盖）
            if !foregroundPausedScreenIDs.isEmpty,
               weBridge.isControllingExternalEngine {
                for screenID in foregroundPausedScreenIDs where weBridge.isManaging(screenID: screenID) {
                    weBridge.pauseWallpaper(for: screenID)
                }
            }

            // 恢复外部引擎后，重新施加窗口覆盖比例暂停（如果当前仍有屏幕被覆盖）
            if !windowCoveragePausedScreenIDs.isEmpty,
               weBridge.isControllingExternalEngine {
                for screenID in windowCoveragePausedScreenIDs where weBridge.isManaging(screenID: screenID) {
                    weBridge.pauseWallpaper(for: screenID)
                }
            }
        }

        // ---- 原生视频恢复 ----
        guard !globalAutoPausedNativePlayingScreenIDs.isEmpty else {
            globalAutoPausedNativeManuallyPausedScreenIDs.removeAll()
            return
        }
        guard videoManager.isVideoWallpaperActive else {
            globalAutoPausedNativePlayingScreenIDs.removeAll()
            globalAutoPausedNativeManuallyPausedScreenIDs.removeAll()
            return
        }

        let managedScreenIDs = Set(videoManager.activeScreens.map(\.wallpaperScreenIdentifier))
        let coveredManagedScreenIDs = fullscreenCoveredScreenIDs.intersection(managedScreenIDs)
        // 电池恢复时，保留：手动暂停的屏幕 + 全屏覆盖的屏幕 + 前台暂停的屏幕 + 窗口覆盖比例暂停的屏幕
        // 前台/窗口覆盖暂停使用当前状态（电池期间可能已变化）
        let currentForegroundNativePausedIDs = foregroundPausedScreenIDs.intersection(managedScreenIDs)
        let currentWindowCoverageNativePausedIDs = windowCoveragePausedScreenIDs.intersection(managedScreenIDs)
        let screenIDsToKeepPaused = globalAutoPausedNativeManuallyPausedScreenIDs
            .union(coveredManagedScreenIDs)
            .union(currentForegroundNativePausedIDs)
            .union(currentWindowCoverageNativePausedIDs)

        if videoManager.isPaused {
            videoManager.resumeWallpaper()
        }

        // 重新暂停需要保持暂停的屏幕
        for screen in NSScreen.screens where screenIDsToKeepPaused.contains(screen.wallpaperScreenIdentifier) {
            videoManager.pauseWallpaper(for: screen)
        }

        fullscreenAutoPausedScreenIDs = coveredManagedScreenIDs
            .subtracting(globalAutoPausedNativeManuallyPausedScreenIDs)
        globalAutoPausedNativePlayingScreenIDs.removeAll()
        globalAutoPausedNativeManuallyPausedScreenIDs.removeAll()
    }

    /// 是否存在全局暂停原因（电池供电）
    /// 注意：前台暂停现在是按屏幕的，不在这里判断
    private var hasActiveGlobalPauseReason: Bool {
        batteryPauseRequested
    }

    // MARK: - AXObserver for Window Moves/Resizes

    private func setupAXObserver(for pid: pid_t) {
        stopAXObserver()

        var observer: AXObserver?
        let err = AXObserverCreate(pid, { (axObserver, axElement, notification, refcon) in
            let now = CFAbsoluteTimeGetCurrent()
            DynamicWallpaperAutoPauseManager.axCallbackLock.lock()
            if now - DynamicWallpaperAutoPauseManager.lastAXCallbackTime < 0.2 {
                DynamicWallpaperAutoPauseManager.axCallbackLock.unlock()
                return
            }
            DynamicWallpaperAutoPauseManager.lastAXCallbackTime = now
            DynamicWallpaperAutoPauseManager.axCallbackLock.unlock()

            guard let refcon = refcon else { return }
            let manager = Unmanaged<DynamicWallpaperAutoPauseManager>.fromOpaque(refcon).takeUnretainedValue()

            var pidValue: pid_t = 0
            AXUIElementGetPid(axElement, &pidValue)
            let elementPid = pidValue

            // Hop to @MainActor before touching any manager state.
            // The AXObserver callback can fire on an arbitrary thread;
            // all mutable state (including windowCoverageDebouncer) is
            // isolated to the main actor.
            Task { @MainActor [weak manager] in
                guard let manager = manager else { return }
                manager.windowCoverageDebouncer.debounce {
                    Task { @MainActor in
                        manager.checkWindowCoverage()
                        if elementPid > 0 {
                            manager.checkForegroundCoverage(pid: elementPid)
                        }
                    }
                }
            }
        }, &observer)

        guard err == .success, let axObserver = observer else {
            return
        }

        let appElement = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        AXObserverAddNotification(axObserver, appElement, kAXMovedNotification as CFString, refcon)
        AXObserverAddNotification(axObserver, appElement, kAXResizedNotification as CFString, refcon)
        AXObserverAddNotification(axObserver, appElement, kAXWindowCreatedNotification as CFString, refcon)
        AXObserverAddNotification(axObserver, appElement, kAXUIElementDestroyedNotification as CFString, refcon)

        self.axObserver = axObserver
        self.currentAXElement = appElement

        let runLoopSource = AXObserverGetRunLoopSource(axObserver)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
        self.axObserverRunLoopSource = runLoopSource
    }

    private func stopAXObserver() {
        if let axObserver = axObserver, let appElement = currentAXElement {
            AXObserverRemoveNotification(axObserver, appElement, kAXMovedNotification as CFString)
            AXObserverRemoveNotification(axObserver, appElement, kAXResizedNotification as CFString)
            AXObserverRemoveNotification(axObserver, appElement, kAXWindowCreatedNotification as CFString)
            AXObserverRemoveNotification(axObserver, appElement, kAXUIElementDestroyedNotification as CFString)
        }

        if let runLoopSource = axObserverRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
        }

        self.axObserver = nil
        self.axObserverRunLoopSource = nil
        self.currentAXElement = nil
    }

    /// 由 AXObserver 事件驱动调用：检测窗口覆盖比例
    private func checkWindowCoverage() {
        guard pauseWhenWindowCoverage else { return }
        let thresholdRatio = CGFloat(windowCoveragePauseThreshold / 100.0)
        fullscreenDetectionQueue.async { [weak self] in
            guard let self else { return }
            let screens = self.getWindowCoverageCoveredScreens(threshold: thresholdRatio)
            let ids = Set(screens.map { $0.wallpaperScreenIdentifier })
            DispatchQueue.main.async { [weak self] in
                self?.applyWindowCoverageDetectionResult(newIDs: ids, screens: screens)
            }
        }
    }

    /// 由 AXObserver 事件驱动调用：用当前前台 app 重新评估前台覆盖
    private func checkForegroundCoverage(pid: pid_t) {
        guard pauseWhenOtherAppForeground else { return }
        reevaluateForegroundCoverage()
    }

    /// 当 Finder/本应用到前台时，清除窗口覆盖暂停状态（桌面可见 → 无需暂停）
    private func clearWindowCoveragePause() {
        guard !windowCoveragePausedScreenIDs.isEmpty else { return }
        let toResume = windowCoveragePausedScreenIDs
        windowCoveragePausedScreenIDs.removeAll()
        windowCoverageCoveredScreenIDs.removeAll()
        pendingWindowCoverageScreenIDs = nil
        pendingWindowCoverageSampleCount = 0
        guard !hasActiveGlobalPauseReason else { return }
        let stillPaused = foregroundPausedScreenIDs.union(fullscreenAutoPausedScreenIDs)
        let canResume = toResume.subtracting(stillPaused)
        if !canResume.isEmpty {
            resumeScreens(byIDs: canResume)
            let weBridge = WallpaperEngineXBridge.shared
            if weBridge.isControllingExternalEngine {
                for sid in canResume where weBridge.isManaging(screenID: sid) {
                    weBridge.resumeWallpaper(for: sid)
                }
            }
        }
    }

    // MARK: - 窗口覆盖比例暂停（独立机制，与前台/全屏覆盖并存）

    /// 扫描所有非本应用、layer 0、alpha>0 的窗口，对每屏做网格采样累计覆盖检测。
    /// 当某屏被窗口累计覆盖的采样点数量达到阈值时，认为该屏需要按比例暂停。
    nonisolated private func getWindowCoverageCoveredScreens(threshold: CGFloat) -> [NSScreen] {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return [] }

        let screenFrames = screens.reduce(into: [String: CGRect]()) { result, screen in
            result[screen.wallpaperScreenIdentifier] = screen.frame
        }
        guard let snapshot = Self.captureWindowSnapshot(screenFrames: screenFrames) else { return [] }

        let coveredIDs = Self.windowCoverageScreens(in: snapshot, thresholdRatio: threshold)
        return screens.filter { coveredIDs.contains($0.wallpaperScreenIdentifier) }
    }

    /// 应用窗口覆盖比例检测结果：稳定性采样 + 按屏 pause/resume
    private func applyWindowCoverageDetectionResult(newIDs: Set<String>, screens: [NSScreen]) {
        guard newIDs != windowCoverageCoveredScreenIDs else {
            pendingWindowCoverageScreenIDs = nil
            pendingWindowCoverageSampleCount = 0
            return
        }
        guard isStableWindowCoverageTransition(to: newIDs) else { return }

        let previous = windowCoverageCoveredScreenIDs
        windowCoverageCoveredScreenIDs = newIDs

        // 恢复：之前被本机制暂停、但现在已不在覆盖列表里的屏幕
        let toResume = windowCoveragePausedScreenIDs.subtracting(newIDs)
        if !toResume.isEmpty {
            windowCoveragePausedScreenIDs.subtract(toResume)
            // 排除仍被其他原因暂停的屏幕
            let stillPausedByOther = foregroundPausedScreenIDs.union(fullscreenAutoPausedScreenIDs)
            let canResume = toResume.subtracting(stillPausedByOther)
            if !canResume.isEmpty, !hasActiveGlobalPauseReason {
                resumeScreens(byIDs: canResume)
                let weBridge = WallpaperEngineXBridge.shared
                if weBridge.isControllingExternalEngine {
                    for sid in canResume where weBridge.isManaging(screenID: sid) {
                        weBridge.resumeWallpaper(for: sid)
                    }
                }
            }
        }

        // 暂停：新进入覆盖列表的屏幕
        let toPause = newIDs.subtracting(previous)
        guard !toPause.isEmpty, !hasActiveGlobalPauseReason else { return }

        let videoManager = VideoWallpaperManager.shared
        let weBridge = WallpaperEngineXBridge.shared
        let pauseScreens = screens.filter { toPause.contains($0.wallpaperScreenIdentifier) }

        for screen in pauseScreens {
            let sid = screen.wallpaperScreenIdentifier
            if videoManager.isVideoWallpaperActive, !videoManager.isPaused(on: screen) {
                videoManager.pauseWallpaper(for: screen)
            }
            if weBridge.isControllingExternalEngine, weBridge.isManaging(screenID: sid) {
                weBridge.pauseWallpaper(for: sid)
            }
            windowCoveragePausedScreenIDs.insert(sid)
        }
    }

    private func isStableWindowCoverageTransition(to ids: Set<String>) -> Bool {
        if pendingWindowCoverageScreenIDs == ids {
            pendingWindowCoverageSampleCount += 1
        } else {
            pendingWindowCoverageScreenIDs = ids
            pendingWindowCoverageSampleCount = 1
        }
        guard pendingWindowCoverageSampleCount >= requiredStableFullscreenSamples else {
            return false
        }
        pendingWindowCoverageScreenIDs = nil
        pendingWindowCoverageSampleCount = 0
        return true
    }
}

private enum CoverageSampling {
    static let gridSize = 50
    static let sampleCount = gridSize * gridSize
}

private struct WindowSnapshot: @unchecked Sendable {
    struct Window: @unchecked Sendable {
        let pid: pid_t
        let layer: Int
        let alpha: Double
        let bounds: CGRect

        func isVisibleContentWindow(excluding excludedPID: pid_t) -> Bool {
            pid != excludedPID && layer == 0 && alpha > 0
        }
    }

    let screenFrames: [String: CGRect]
    let windows: [Window]
}
