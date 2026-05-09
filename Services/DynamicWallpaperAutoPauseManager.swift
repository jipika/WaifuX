import Foundation
import AppKit
import CoreGraphics

/// 动态壁纸自动暂停管理器
/// 根据用户设置，在以下场景自动暂停/恢复动态壁纸：
/// 1. 前台存在其他应用时（排除 Finder）
/// 2. 检测到有全屏窗口覆盖桌面时（按屏幕独立暂停）
/// 3. 切换到电池供电时
@MainActor
final class DynamicWallpaperAutoPauseManager {
    static let shared = DynamicWallpaperAutoPauseManager()

    private var checkTimer: Timer?
    /// 当前是否存在“前台应用”这一自动暂停原因。
    private var foregroundPauseRequested = false
    /// 当前是否存在“电池供电”这一自动暂停原因。
    private var batteryPauseRequested = false
    /// 全局自动暂停前，原生视频壁纸里真实处于播放中的屏幕。
    private var globalAutoPausedNativePlayingScreenIDs: Set<String> = []
    /// 触发全局自动暂停前，原生视频里已经处于手动暂停状态的屏幕。
    private var globalAutoPausedNativeManuallyPausedScreenIDs: Set<String> = []
    /// 全局自动暂停前，Wallpaper Engine 是否处于播放状态。
    private var globalAutoPausedExternalEngine = false
    /// 当前被全屏窗口覆盖的屏幕 ID 列表。
    private var fullscreenCoveredScreenIDs: Set<String> = []
    /// 因全屏覆盖而被自动暂停的原生视频屏幕。
    private var fullscreenAutoPausedScreenIDs: Set<String> = []
    /// 是否因全屏覆盖而自动暂停过 Wallpaper Engine。
    private var fullscreenAutoPausedExternalEngine = false
    private var pendingFullscreenCoveredScreenIDs: Set<String>?
    private var pendingFullscreenSampleCount = 0
    private let requiredStableFullscreenSamples = 2
    /// 前台应用变化观察者（用于替代 1s 轮询）
    private var appActivationObserver: Any?
    /// 前台应用切换防抖 Task，避免用户连击 Cmd-Tab 时连续触发暂停/恢复
    private var appSwitchDebounceTask: Task<Void, Never>?
    /// 主窗口收起到状态栏时会触发一次前台应用切换；这不是用户希望暂停壁纸的信号。
    private var suppressForegroundPauseUntil: Date?

    private let pauseWhenOtherAppKey = "pause_when_other_app_foreground"
    private let pauseWhenFullscreenKey = "pause_when_fullscreen_covers"
    private let pauseOnBatteryKey = "pause_on_battery_power"

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

    private func updateTimer() {
        let needsFullscreenTimer = pauseWhenFullscreenCovers
        if needsFullscreenTimer {
            // 全屏检测需要轮询（CGWindowList 无法用通知替代），间隔降为 3s
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
                    resumeScreens(byIDs: screenIDs)
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
    }

    private func startTimer(interval: TimeInterval) {
        checkTimer?.invalidate()
        checkTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkAndApply()
            }
        }
        checkAndApply()
    }

    private func stopTimer() {
        checkTimer?.invalidate()
        checkTimer = nil
    }

    private func checkAndApply() {
        let hasNative = VideoWallpaperManager.shared.currentVideoURL != nil
        let hasExternal = WallpaperEngineXBridge.shared.isControllingExternalEngine
        guard hasNative || hasExternal else {
            foregroundPauseRequested = false
            batteryPauseRequested = false
            globalAutoPausedNativePlayingScreenIDs.removeAll()
            globalAutoPausedNativeManuallyPausedScreenIDs.removeAll()
            globalAutoPausedExternalEngine = false
            fullscreenCoveredScreenIDs.removeAll()
            fullscreenAutoPausedScreenIDs.removeAll()
            fullscreenAutoPausedExternalEngine = false
            pendingFullscreenCoveredScreenIDs = nil
            pendingFullscreenSampleCount = 0
            return
        }

        // 锁屏/解锁期间由 VideoWallpaperManager 自行管理播放状态，AutoPause 不介入，避免竞态
        guard !VideoWallpaperManager.shared.isScreenLocked else { return }

        // Timer 驱动的检测仅处理全屏覆盖（前台应用检测已由通知驱动）
        guard pauseWhenFullscreenCovers else { return }

        // 获取被全屏覆盖的屏幕列表
        let fullscreenCoveredScreens = getFullscreenCoveredScreens()
        let newFullscreenIDs = Set(fullscreenCoveredScreens.map { $0.wallpaperScreenIdentifier })
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
            if !hasActiveGlobalPauseReason {
                resumeScreens(byIDs: screenIDsToResume)
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

    // MARK: - 检测逻辑

    /// 前台应用切换时由通知驱动，无需轮询
    private func handleAppActivationChange() {
        guard pauseWhenOtherAppForeground else { return }
        guard !isForegroundPauseSuppressed else { return }
        let hasNative = VideoWallpaperManager.shared.currentVideoURL != nil
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
            let shouldPause = self.isOtherAppInForeground()
            if shouldPause {
                self.foregroundPauseRequested = true
                self.applyGlobalPauseIfNeeded()
            } else {
                self.foregroundPauseRequested = false
                self.resumeFromGlobalPauseIfPossible()
            }
        }
    }

    /// 检查前台是否是非本应用且非 Finder 的其他应用
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
    /// 通过 CGWindowList 检测 layer 0 且覆盖屏幕绝大部分区域的窗口
    private func isFullscreenCovering() -> Bool {
        return !getFullscreenCoveredScreens().isEmpty
    }

    /// 获取被全屏窗口覆盖的屏幕列表
    /// 通过 CGWindowList 检测 layer 0 且覆盖屏幕绝大部分区域的窗口
    private func getFullscreenCoveredScreens() -> [NSScreen] {
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        let screens = NSScreen.screens
        let desktopFrame = screens.reduce(CGRect.null) { $0.union($1.frame) }
        var coveredScreens: [NSScreen] = []

        for window in windowList {
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let alpha = window[kCGWindowAlpha as String] as? Double, alpha > 0 else { continue }
            guard let boundsDict = window[kCGWindowBounds as String] as? [String: CGFloat] else { continue }

            let rawBounds = CGRect(
                x: boundsDict["X"] ?? 0,
                y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0,
                height: boundsDict["Height"] ?? 0
            )
            let bounds = normalizedWindowBounds(rawBounds, screens: screens, desktopFrame: desktopFrame)

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

    private func normalizedWindowBounds(_ bounds: CGRect, screens: [NSScreen], desktopFrame: CGRect) -> CGRect {
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
            if videoManager.currentVideoURL != nil,
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
        guard videoManager.currentVideoURL != nil else { return }

        for screen in NSScreen.screens where screenIDs.contains(screen.wallpaperScreenIdentifier) {
            videoManager.resumeWallpaper(for: screen)
        }
    }

    private func syncForegroundPauseRequest() {
        guard pauseWhenOtherAppForeground else {
            foregroundPauseRequested = false
            resumeFromGlobalPauseIfPossible()
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

    private func applyGlobalPauseIfNeeded() {
        guard hasActiveGlobalPauseReason else { return }

        let videoManager = VideoWallpaperManager.shared
        let weBridge = WallpaperEngineXBridge.shared

        if weBridge.isControllingExternalEngine {
            guard !weBridge.isExternalPaused else { return }
            weBridge.pauseWallpaper()
            globalAutoPausedExternalEngine = true
            globalAutoPausedNativePlayingScreenIDs.removeAll()
            globalAutoPausedNativeManuallyPausedScreenIDs.removeAll()
            return
        }

        guard videoManager.currentVideoURL != nil else { return }
        guard globalAutoPausedNativePlayingScreenIDs.isEmpty else { return }

        let managedScreenIDs = Set(videoManager.activeScreens.map(\.wallpaperScreenIdentifier))
        let playingScreenIDs = videoManager.playingScreenIDs
        guard !playingScreenIDs.isEmpty else { return }

        globalAutoPausedNativePlayingScreenIDs = playingScreenIDs
        globalAutoPausedNativeManuallyPausedScreenIDs = managedScreenIDs
            .subtracting(playingScreenIDs)
            .subtracting(fullscreenAutoPausedScreenIDs)
        globalAutoPausedExternalEngine = false
        if !videoManager.isPaused {
            videoManager.pauseWallpaper()
        }
    }

    private func resumeFromGlobalPauseIfPossible() {
        guard !hasActiveGlobalPauseReason else { return }

        let videoManager = VideoWallpaperManager.shared
        let weBridge = WallpaperEngineXBridge.shared

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
            return
        }

        guard !globalAutoPausedNativePlayingScreenIDs.isEmpty else {
            globalAutoPausedNativeManuallyPausedScreenIDs.removeAll()
            return
        }
        guard videoManager.currentVideoURL != nil else {
            globalAutoPausedNativePlayingScreenIDs.removeAll()
            globalAutoPausedNativeManuallyPausedScreenIDs.removeAll()
            return
        }

        let managedScreenIDs = Set(videoManager.activeScreens.map(\.wallpaperScreenIdentifier))
        let coveredManagedScreenIDs = fullscreenCoveredScreenIDs.intersection(managedScreenIDs)
        let screenIDsToKeepPaused = globalAutoPausedNativeManuallyPausedScreenIDs.union(coveredManagedScreenIDs)

        if videoManager.isPaused {
            videoManager.resumeWallpaper()
        }

        for screen in NSScreen.screens where screenIDsToKeepPaused.contains(screen.wallpaperScreenIdentifier) {
            videoManager.pauseWallpaper(for: screen)
        }

        fullscreenAutoPausedScreenIDs = coveredManagedScreenIDs
            .subtracting(globalAutoPausedNativeManuallyPausedScreenIDs)
        globalAutoPausedNativePlayingScreenIDs.removeAll()
        globalAutoPausedNativeManuallyPausedScreenIDs.removeAll()
    }

    private var hasActiveGlobalPauseReason: Bool {
        foregroundPauseRequested || batteryPauseRequested
    }
}
