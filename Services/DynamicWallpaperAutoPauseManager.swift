import Foundation
import AppKit
import CoreGraphics

/// 动态壁纸自动暂停管理器
/// 根据用户设置，在以下场景自动暂停/恢复动态壁纸：/// 1. 前台存在其他应用时（排除 Finder）
/// 2. 检测到有全屏窗口覆盖桌面时
@MainActor
final class DynamicWallpaperAutoPauseManager {
    static let shared = DynamicWallpaperAutoPauseManager()

    private var checkTimer: Timer?
    private var wasAutoPaused = false

    private let pauseWhenOtherAppKey = "pause_when_other_app_foreground"
    private let pauseWhenFullscreenKey = "pause_when_fullscreen_covers"

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

    private init() {}

    func restoreSettings() {
        updateTimer()
    }

    private func updateTimer() {
        if pauseWhenOtherAppForeground || pauseWhenFullscreenCovers {
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
