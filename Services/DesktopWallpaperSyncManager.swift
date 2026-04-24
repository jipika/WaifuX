import Foundation
import AppKit

/// 桌面壁纸跨 Space 同步管理器
///
/// macOS 的 `NSWorkspace.setDesktopImageURL` 默认只更新当前 active Space 的壁纸。
/// 即使在 options 中传入 `allSpaces: true`，已有 Spaces 仍可能不同步。
///
/// 解决思路：
/// 1. 监听 `activeSpaceDidChangeNotification`，当用户切换到另一个 Space 时，
///    自动将每个屏幕最后设置的壁纸重新应用到新的 active Space。
/// 2. 作为备用，在应用重新变为活跃时（applicationDidBecomeActive）也执行一次同步，
///    因为 `activeSpaceDidChangeNotification` 在应用后台时可能不可靠。
@MainActor
final class DesktopWallpaperSyncManager {
    static let shared = DesktopWallpaperSyncManager()

    /// 每个屏幕最后通过 WaifuX 设置的静态壁纸 URL（key 为 screenID）
    private var lastSetImageURLByScreen: [String: URL] = [:]

    /// 每个屏幕最后设置的选项
    private var lastOptionsByScreen: [String: [NSWorkspace.DesktopImageOptionKey: Any]] = [:]

    /// 记录最后一次尝试同步的时间，避免过于频繁的重复同步
    private var lastSyncTime: Date?
    private let minimumSyncInterval: TimeInterval = 1.0

    private init() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleActiveSpaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
    }

    /// 注册一次静态壁纸设置，后续 Space 切换时会自动同步
    /// - Parameters:
    ///   - url: 壁纸图片 URL
    ///   - screen: 目标屏幕；nil 表示注册到所有当前屏幕
    ///   - options: 设置选项
    func registerWallpaperSet(_ url: URL, for screen: NSScreen? = nil, options: [NSWorkspace.DesktopImageOptionKey: Any] = [:]) {
        let targetScreens: [NSScreen]
        if let screen = screen {
            targetScreens = [screen]
        } else {
            targetScreens = NSScreen.screens
        }

        for targetScreen in targetScreens {
            let screenID = targetScreen.wallpaperScreenIdentifier
            lastSetImageURLByScreen[screenID] = url
            lastOptionsByScreen[screenID] = options
        }
    }

    /// 清除静态壁纸注册（例如用户手动在系统设置里改了壁纸）
    /// - Parameter screen: 目标屏幕；nil 表示清除所有屏幕
    func clearRegistration(for screen: NSScreen? = nil) {
        if let screen = screen {
            let screenID = screen.wallpaperScreenIdentifier
            lastSetImageURLByScreen.removeValue(forKey: screenID)
            lastOptionsByScreen.removeValue(forKey: screenID)
        } else {
            lastSetImageURLByScreen.removeAll()
            lastOptionsByScreen.removeAll()
        }
    }

    /// 应用变为活跃时的备用同步入口（处理 activeSpaceDidChangeNotification 丢失的情况）
    func syncOnAppActivation() {
        performSync(source: "appActivation")
    }

    @objc private func handleActiveSpaceChanged() {
        // 延迟再同步，确保 Space 切换动画完全结束、系统桌面状态稳定后再执行
        // 0.3s 不够可靠，实测在 Sonoma+ 上需要 1.0s 左右
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.performSync(source: "spaceChange")
        }
    }

    /// 执行实际同步逻辑
    private func performSync(source: String) {
        // 防抖动：避免短时间内多次同步
        if let last = lastSyncTime, Date().timeIntervalSince(last) < minimumSyncInterval {
            print("[DesktopWallpaperSyncManager] Skipping sync from '\(source)' (too soon)")
            return
        }
        lastSyncTime = Date()

        let videoManager = VideoWallpaperManager.shared
        let workspace = NSWorkspace.shared
        let currentScreens = NSScreen.screens

        // 1. 对每个当前屏幕，优先同步该屏幕自己的壁纸状态
        for screen in currentScreens {
            let screenID = screen.wallpaperScreenIdentifier

            // 如果该屏幕属于视频壁纸目标，同步其 poster
            if videoManager.hasActiveWallpaper(on: screen),
               let posterURL = videoManager.currentPosterURL,
               videoManager.currentVideoURL != nil {
                do {
                    try workspace.setDesktopImageURLForAllSpaces(posterURL, for: screen)
                    print("[DesktopWallpaperSyncManager] [\(source)] Synced video poster for screen \(screen.localizedName)")
                } catch {
                    print("[DesktopWallpaperSyncManager] [\(source)] Failed to sync poster for screen \(screen.localizedName): \(error)")
                }
                continue
            }

            // 否则同步该屏幕最后注册的静态壁纸
            guard let url = lastSetImageURLByScreen[screenID] else {
                continue
            }

            do {
                var merged = lastOptionsByScreen[screenID] ?? [:]
                merged[NSWorkspace.DesktopImageOptionKey(rawValue: "allSpaces")] = NSNumber(value: true)
                try workspace.setDesktopImageURL(url, for: screen, options: merged)
                print("[DesktopWallpaperSyncManager] [\(source)] Synced static wallpaper for screen \(screen.localizedName)")
            } catch {
                print("[DesktopWallpaperSyncManager] [\(source)] Failed to sync wallpaper for screen \(screen.localizedName): \(error)")
            }
        }

        triggerWallpaperAgentRefresh()
    }

    private func triggerWallpaperAgentRefresh() {
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("com.apple.desktop"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }
}

private extension NSScreen {
    var wallpaperScreenIdentifier: String {
        if let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return screenNumber.stringValue
        }
        return localizedName
    }
}
