import Foundation
import AppKit

/// 桌面壁纸跨 Space 同步管理器
///
/// macOS 的 `NSWorkspace.setDesktopImageURL` 默认只更新当前 active Space 的壁纸。
/// 即使在 options 中传入 `allSpaces: true`，已有 Spaces 仍可能不同步。
///
/// 解决思路：
/// 1. 监听 `activeSpaceDidChangeNotification`，当用户切换到另一个 Space 时，
///    自动将最后设置的壁纸重新应用到新的 active Space。
/// 2. 作为备用，在应用重新变为活跃时（applicationDidBecomeActive）也执行一次同步，
///    因为 `activeSpaceDidChangeNotification` 在应用后台时可能不可靠。
@MainActor
final class DesktopWallpaperSyncManager {
    static let shared = DesktopWallpaperSyncManager()

    /// 最后通过 WaifuX 设置的静态壁纸 URL
    private var lastSetImageURL: URL?

    /// 最后设置的选项（用于恢复时保持一致）
    private var lastOptions: [NSWorkspace.DesktopImageOptionKey: Any] = [:]

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
    func registerWallpaperSet(_ url: URL, options: [NSWorkspace.DesktopImageOptionKey: Any] = [:]) {
        lastSetImageURL = url
        lastOptions = options
    }

    /// 清除静态壁纸注册（例如用户手动在系统设置里改了壁纸）
    func clearRegistration() {
        lastSetImageURL = nil
        lastOptions = [:]
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

        // 优先同步动态壁纸的预览图（poster），因为动态壁纸有视频窗口覆盖，
        // 但预览图作为桌面底图也需要在所有 Space 保持一致
        if let posterURL = videoManager.currentPosterURL,
           videoManager.currentVideoURL != nil {
            print("[DesktopWallpaperSyncManager] [\(source)] Syncing video poster: \(posterURL.path)")
            for screen in NSScreen.screens {
                do {
                    try NSWorkspace.shared.setDesktopImageURLForAllSpaces(posterURL, for: screen)
                } catch {
                    print("[DesktopWallpaperSyncManager] [\(source)] Failed to sync poster for screen \(screen.localizedName): \(error)")
                }
            }
            triggerWallpaperAgentRefresh()
            return
        }

        // 否则同步最后注册的静态壁纸
        guard let url = lastSetImageURL else {
            print("[DesktopWallpaperSyncManager] [\(source)] No wallpaper registered, skipping")
            return
        }

        print("[DesktopWallpaperSyncManager] [\(source)] Syncing static wallpaper: \(url.path)")
        for screen in NSScreen.screens {
            do {
                var merged = lastOptions
                merged[NSWorkspace.DesktopImageOptionKey(rawValue: "allSpaces")] = NSNumber(value: true)
                try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: merged)
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
