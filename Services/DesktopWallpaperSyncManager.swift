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
    /// 每个物理显示器指纹最后设置的静态壁纸 URL，用于外接屏重连后 screenID 变化时恢复。
    private var lastSetImageURLByFingerprint: [String: URL] = [:]

    /// 每个屏幕最后设置的选项
    private var lastOptionsByScreen: [String: [NSWorkspace.DesktopImageOptionKey: Any]] = [:]
    /// 每个物理显示器指纹最后设置的选项。
    private var lastOptionsByFingerprint: [String: [NSWorkspace.DesktopImageOptionKey: Any]] = [:]

    /// 记录最后一次尝试同步的时间，避免过于频繁的重复同步
    private var lastSyncTime: Date?
    private let minimumSyncInterval: TimeInterval = 0.5
    /// 用于 Space 切换的 debounce，快速连续切换时只保留最后一次
    private var pendingSyncWorkItem: DispatchWorkItem?
    private var pendingScreenChangeWorkItem: DispatchWorkItem?

    private init() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleActiveSpaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
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
            let fingerprint = targetScreen.wallpaperScreenFingerprint
            lastSetImageURLByScreen[screenID] = url
            lastSetImageURLByFingerprint[fingerprint] = url
            lastOptionsByScreen[screenID] = options
            lastOptionsByFingerprint[fingerprint] = options
        }
    }

    /// 清除静态壁纸注册（例如用户手动在系统设置里改了壁纸）
    /// - Parameter screen: 目标屏幕；nil 表示清除所有屏幕
    func clearRegistration(for screen: NSScreen? = nil) {
        if let screen = screen {
            let screenID = screen.wallpaperScreenIdentifier
            let fingerprint = screen.wallpaperScreenFingerprint
            lastSetImageURLByScreen.removeValue(forKey: screenID)
            lastSetImageURLByFingerprint.removeValue(forKey: fingerprint)
            lastOptionsByScreen.removeValue(forKey: screenID)
            lastOptionsByFingerprint.removeValue(forKey: fingerprint)
        } else {
            lastSetImageURLByScreen.removeAll()
            lastSetImageURLByFingerprint.removeAll()
            lastOptionsByScreen.removeAll()
            lastOptionsByFingerprint.removeAll()
        }
    }

    /// 应用变为活跃时的备用同步入口（处理 activeSpaceDidChangeNotification 丢失的情况）
    func syncOnAppActivation() {
        performSync(source: "appActivation")
    }

    @objc private func handleActiveSpaceChanged() {
        // Debounce：快速连续切换 Space 时，取消之前的延迟任务，只保留最后一次
        pendingSyncWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.performSync(source: "spaceChange")
        }
        pendingSyncWorkItem = workItem
        // 延迟再同步，确保 Space 切换动画完全结束、系统桌面状态稳定后再执行
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
    }

    @objc private func handleScreenParametersChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // 防抖：延迟 0.5s 执行
            self.pendingScreenChangeWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.relinkScreenStateForCurrentDisplays()
            }
            self.pendingScreenChangeWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
        }
    }

    private func relinkScreenStateForCurrentDisplays() {
        var relinkedCount = 0
        for screen in NSScreen.screens {
            let screenID = screen.wallpaperScreenIdentifier
            let fingerprint = screen.wallpaperScreenFingerprint

            if lastSetImageURLByScreen[screenID] == nil,
               let url = lastSetImageURLByFingerprint[fingerprint] {
                lastSetImageURLByScreen[screenID] = url
                relinkedCount += 1
            }
            if lastOptionsByScreen[screenID] == nil,
               let options = lastOptionsByFingerprint[fingerprint] {
                lastOptionsByScreen[screenID] = options
            }
        }
        if relinkedCount > 0 {
            print("[DesktopWallpaperSyncManager] Relinked wallpaper registration for \(relinkedCount) reconnected screen(s)")
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// 执行实际同步逻辑
    private func performSync(source: String) {
        // 防抖动：避免短时间内多次同步（Space 切换通常不会连续触发）
        if let last = lastSyncTime, Date().timeIntervalSince(last) < minimumSyncInterval {
            print("[DesktopWallpaperSyncManager] Skipping sync from '\(source)' (too soon)")
            return
        }
        lastSyncTime = Date()

        let videoManager = VideoWallpaperManager.shared
        let workspace = NSWorkspace.shared
        let currentScreens = NSScreen.screens
        relinkScreenStateForCurrentDisplays()

        // 1. 对每个当前屏幕，优先同步该屏幕自己的壁纸状态
        for screen in currentScreens {
            let screenID = screen.wallpaperScreenIdentifier
            let fingerprint = screen.wallpaperScreenFingerprint

            // 如果该屏幕属于视频壁纸目标，同步其 poster（不再跳过，确保所有 Spaces 都正确）
            if videoManager.hasActiveWallpaper(on: screen),
               let posterURL = videoManager.posterURL(for: screen),
               videoManager.currentVideoURL != nil {
                do {
                    // 使用 "充满屏幕" 缩放模式，与初始设置保持一致
                    let fillOptions: [NSWorkspace.DesktopImageOptionKey: Any] = [
                        .imageScaling: NSNumber(value: NSImageScaling.scaleProportionallyUpOrDown.rawValue),
                        .allowClipping: true
                    ]
                    try workspace.setDesktopImageURLForAllSpaces(posterURL, for: screen, options: fillOptions)
                    print("[DesktopWallpaperSyncManager] [\(source)] Synced video poster for screen \(screen.localizedName)")
                } catch {
                    print("[DesktopWallpaperSyncManager] [\(source)] Failed to sync poster for screen \(screen.localizedName): \(error)")
                }
                continue
            }

            // 否则同步该屏幕最后注册的静态壁纸
            guard let url = lastSetImageURLByScreen[screenID] ?? lastSetImageURLByFingerprint[fingerprint] else {
                continue
            }

            // 跳过 CLI 壁纸的临时 capture 路径（应用重启后不存在，且 CLI daemon 自行管理桌面壁纸）
            if url.path.contains("wallpaperengine-cli-capture") {
                print("[DesktopWallpaperSyncManager] [\(source)] Skipping CLI capture path for screen \(screen.localizedName)")
                continue
            }

            do {
                // 使用 setDesktopImageURLForAllSpaces 确保所有 Spaces 同步，
                // 该方法内部已发送 com.apple.desktop 通知，无需额外触发
                let options = lastOptionsByScreen[screenID] ?? lastOptionsByFingerprint[fingerprint] ?? [:]
                try workspace.setDesktopImageURLForAllSpaces(url, for: screen, options: options)
                print("[DesktopWallpaperSyncManager] [\(source)] Synced static wallpaper for screen \(screen.localizedName)")
            } catch {
                print("[DesktopWallpaperSyncManager] [\(source)] Failed to sync wallpaper for screen \(screen.localizedName): \(error)")
            }
        }
    }
}

