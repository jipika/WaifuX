import Foundation
import AppKit
import CoreGraphics

/// 动态壁纸自动暂停管理器
/// 根据用户设置，在以下场景自动暂停/恢复动态壁纸：
/// 1. 前台存在其他应用时（排除 Finder）
/// 2. 检测到有全屏窗口覆盖桌面时
/// 3. 切换到电池供电时
@MainActor
final class DynamicWallpaperAutoPauseManager {
    static let shared = DynamicWallpaperAutoPauseManager()

    private var checkTimer: Timer?
    private var wasAutoPaused = false
    private var batteryAutoPaused = false

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
    }

    func restoreSettings() {
        updateTimer()
        // 如果电池暂停设置已开启，启动电源监控
        if pauseOnBatteryPower {
            PowerSourceMonitor.shared.startMonitoring()
        }
    }

    private func updateTimer() {
        let needsTimer = pauseWhenOtherAppForeground || pauseWhenFullscreenCovers
        if needsTimer {
            startTimer()
        } else {
            stopTimer()
            if wasAutoPaused {
                resumeIfNeeded()
                wasAutoPaused = false
            }
        }
    }

    private func startTimer() {
        checkTimer?.invalidate()
        checkTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
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
            wasAutoPaused = false
            return
        }

        // 锁屏/解锁期间由 VideoWallpaperManager 自行管理播放状态，AutoPause 不介入，避免竞态
        guard !VideoWallpaperManager.shared.isScreenLocked else { return }

        let shouldPause = (pauseWhenOtherAppForeground && isOtherAppInForeground()) ||
                          (pauseWhenFullscreenCovers && isFullscreenCovering())

        if shouldPause {
            if !isCurrentlyPaused() {
                pauseAll()
                wasAutoPaused = true
            }
        } else {
            if wasAutoPaused && isCurrentlyPaused() {
                resumeAll()
            }
            wasAutoPaused = false
        }
    }
    
    // MARK: - 电池供电处理
    
    private func handleBatterySettingChange() {
        if pauseOnBatteryPower {
            PowerSourceMonitor.shared.startMonitoring()
            // 如果当前已在电池上且壁纸在播放，立即暂停
            if PowerSourceMonitor.shared.isOnBatteryPower {
                handleBatterySwitchedToBattery()
            }
        } else {
            // 关闭设置时，如果之前是电池自动暂停的，恢复播放
            if batteryAutoPaused {
                resumeIfNeeded()
                batteryAutoPaused = false
            }
        }
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
        let hasNative = VideoWallpaperManager.shared.currentVideoURL != nil
        let hasExternal = WallpaperEngineXBridge.shared.isControllingExternalEngine
        guard hasNative || hasExternal else { return }
        
        if !isCurrentlyPaused() {
            pauseAll()
            batteryAutoPaused = true
        }
    }
    
    /// 切换回 AC 电源：如果之前是电池自动暂停的，恢复播放
    private func handleBatterySwitchedToAC() {
        if batteryAutoPaused && isCurrentlyPaused() {
            resumeAll()
        }
        batteryAutoPaused = false
    }

    // MARK: - 检测逻辑

    /// 检查前台是否是非本应用且非 Finder 的其他应用
    private func isOtherAppInForeground() -> Bool {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else { return false }
        let bundleID = frontmostApp.bundleIdentifier
        let ourBundleID = Bundle.main.bundleIdentifier
        let finderBundleID = "com.apple.finder"
        return bundleID != ourBundleID && bundleID != finderBundleID
    }

    /// 检查当前是否有全屏窗口覆盖桌面
    /// 通过 CGWindowList 检测 layer 0 且覆盖屏幕绝大部分区域的窗口
    private func isFullscreenCovering() -> Bool {
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }

        let screens = NSScreen.screens

        for window in windowList {
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let alpha = window[kCGWindowAlpha as String] as? Double, alpha > 0 else { continue }
            guard let boundsDict = window[kCGWindowBounds as String] as? [String: CGFloat] else { continue }

            let bounds = CGRect(
                x: boundsDict["X"] ?? 0,
                y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0,
                height: boundsDict["Height"] ?? 0
            )

            // 检查是否覆盖任一屏幕的绝大部分区域（>= 95%）
            for screen in screens {
                let screenFrame = screen.frame
                if bounds.width >= screenFrame.width * 0.95 &&
                   bounds.height >= screenFrame.height * 0.95 {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - 暂停/恢复

    private func isCurrentlyPaused() -> Bool {
        let weBridge = WallpaperEngineXBridge.shared
        if weBridge.isControllingExternalEngine {
            return weBridge.isExternalPaused
        }
        return VideoWallpaperManager.shared.isPaused
    }

    private func pauseAll() {
        let weBridge = WallpaperEngineXBridge.shared
        if weBridge.isControllingExternalEngine && !weBridge.isExternalPaused {
            weBridge.pauseWallpaper()
        } else if VideoWallpaperManager.shared.currentVideoURL != nil && !VideoWallpaperManager.shared.isPaused {
            VideoWallpaperManager.shared.pauseWallpaper()
        }
    }

    private func resumeAll() {
        let weBridge = WallpaperEngineXBridge.shared
        if weBridge.isControllingExternalEngine && weBridge.isExternalPaused {
            weBridge.resumeWallpaper()
        } else if VideoWallpaperManager.shared.currentVideoURL != nil && VideoWallpaperManager.shared.isPaused {
            VideoWallpaperManager.shared.resumeWallpaper()
        }
    }

    private func resumeIfNeeded() {
        if isCurrentlyPaused() {
            resumeAll()
        }
    }
}
