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
    private var pendingActivationSyncWorkItem: DispatchWorkItem?
    /// 标记“应用重新激活时确实需要做一次恢复性同步”。
    /// 仅在显示器参数变化/系统唤醒等场景置为 true，避免普通前后台切换也去重写桌面壁纸。
    private var requiresActivationRecoverySync = false

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
        // 系统唤醒后同步壁纸到所有显示器（外接显示器可能延迟枚举）
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSystemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleScreensDidWake),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
    }

    /// 注册一次静态壁纸设置，后续 Space 切换时会自动同步
    /// - Parameters:
    ///   - url: 壁纸图片 URL
    ///   - screen: 目标屏幕；nil 表示注册到所有当前屏幕
    ///   - options: 设置选项
    func registerWallpaperSet(_ url: URL, for screen: NSScreen? = nil, options: [NSWorkspace.DesktopImageOptionKey: Any] = [:]) {
        // 系统壁纸同步关闭时禁止注册，防止后续 Space 切换时绕开关闭状态重新写入系统壁纸。
        guard VideoWallpaperManager.shared.isSystemWallpaperSyncEnabled else {
            print("[DesktopWallpaperSyncManager] 🧊 系统壁纸同步已关闭，跳过注册")
            return
        }

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
        let screenCount = NSScreen.screens.count
        if screenCount <= 1, !requiresActivationRecoverySync {
            AppLogger.debug(.ui, "Desktop wallpaper activation sync skipped", metadata: [
                "reason": "singleDisplayNoRecoveryNeeded",
                "screenCount": screenCount
            ])
            return
        }

        pendingActivationSyncWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.performSync(source: "appActivation")
            self.requiresActivationRecoverySync = false
        }
        pendingActivationSyncWorkItem = workItem
        // 激活应用的首帧优先给 UI；桌面跨 Space 同步延后一拍，避免把窗口唤醒卡在主线程上。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: workItem)
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
            self.requiresActivationRecoverySync = true
            // 防抖：延迟 0.5s 执行
            self.pendingScreenChangeWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.relinkScreenStateForCurrentDisplays()
                // 显示器变化后立即同步壁纸，确保新接入/重新枚举的显示器立即获得正确的壁纸
                self.performSync(source: "screenChange")
            }
            self.pendingScreenChangeWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
        }
    }

    @objc private func handleSystemDidWake() {
        // 系统唤醒后延迟同步，给 macOS 时间重新枚举所有显示器
        // 注意：不 cancel pendingScreenChangeWorkItem（那是 screenParametersChanged 的专用 work item），
        // 避免 screenParametersChanged 在唤醒期间触发时把唤醒重建任务连带后续二次重试一起 cancel 掉。
        // performSync 内部有 0.5s 防抖，重复同步会被自动跳过。
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.requiresActivationRecoverySync = true
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.relinkScreenStateForCurrentDisplays()
                self.performSync(source: "systemWake")
                // 二次延迟同步：外接显示器可能 1~2 秒后才被 macOS 完全枚举
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    guard let self else { return }
                    self.relinkScreenStateForCurrentDisplays()
                    self.performSync(source: "systemWakeRetry")
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)
        }
    }

    @objc private func handleScreensDidWake() {
        // 屏幕唤醒后延迟同步（不 cancel pendingScreenChangeWorkItem，理由同上）
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.requiresActivationRecoverySync = true
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.relinkScreenStateForCurrentDisplays()
                self.performSync(source: "screensWake")
                // 二次延迟同步：应对显示器延迟枚举
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    guard let self else { return }
                    self.relinkScreenStateForCurrentDisplays()
                    self.performSync(source: "screensWakeRetry")
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)
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
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    /// 执行实际同步逻辑
    private func performSync(source: String) {
        let start = Date()
        // 防抖动：避免短时间内多次同步（Space 切换通常不会连续触发）
        if let last = lastSyncTime, Date().timeIntervalSince(last) < minimumSyncInterval {
            print("[DesktopWallpaperSyncManager] Skipping sync from '\(source)' (too soon)")
            return
        }
        lastSyncTime = Date()

        let videoManager = VideoWallpaperManager.shared
        let hasStaticRegistrations = !lastSetImageURLByScreen.isEmpty || !lastSetImageURLByFingerprint.isEmpty
        let hasDynamicWallpaper = videoManager.isVideoWallpaperActive
        guard hasStaticRegistrations || hasDynamicWallpaper else {
            AppLogger.debug(.ui, "Desktop wallpaper sync skipped", metadata: [
                "source": source,
                "reason": "noRegisteredWallpaperState"
            ])
            return
        }

        let workspace = NSWorkspace.shared
        let currentScreens = NSScreen.screens
        relinkScreenStateForCurrentDisplays()
        let shouldSkipStaticDesktopWrites: Bool = {
            if #available(macOS 26.0, *) {
                return videoManager.isLockScreenEnabled
            }
            return false
        }()
        var syncWrites = 0

        // 1. 对每个当前屏幕，优先同步该屏幕自己的壁纸状态
        for screen in currentScreens {
            let screenID = screen.wallpaperScreenIdentifier
            let fingerprint = screen.wallpaperScreenFingerprint

            // 系统壁纸同步关闭时跳过本屏的同步，避免后续 Space 切换回写系统壁纸。
            guard videoManager.isSystemWallpaperSyncEnabled else {
                print("[DesktopWallpaperSyncManager] [\(source)] 🧊 系统壁纸同步已关闭，跳过同步 for screen \(screen.localizedName)")
                continue
            }

            // 如果该屏幕属于视频壁纸目标，同步其 poster（不再跳过，确保所有 Spaces 都正确）
            if videoManager.hasActiveWallpaper(on: screen),
               let posterURL = videoManager.posterURL(for: screen),
               videoManager.isVideoWallpaperActive {
                // ⚠️ 动态锁屏启用时跳过 poster 同步，避免触发 setDesktopImageURL 导致系统重置扩展选择
                if shouldSkipStaticDesktopWrites {
                    print("[DesktopWallpaperSyncManager] [\(source)] 🔒 动态锁屏已启用，跳过 poster 同步 for screen \(screen.localizedName)")
                } else {
                    do {
                        let writeStart = Date()
                        // 使用 "充满屏幕" 缩放模式，与初始设置保持一致
                        let fillOptions: [NSWorkspace.DesktopImageOptionKey: Any] = [
                            .imageScaling: NSNumber(value: NSImageScaling.scaleProportionallyUpOrDown.rawValue),
                            .allowClipping: true
                        ]
                        try workspace.setDesktopImageURLForAllSpaces(posterURL, for: screen, options: fillOptions)
                        syncWrites += 1
                        let elapsedMS = Date().timeIntervalSince(writeStart) * 1000
                        if elapsedMS >= 250 {
                            AppLogger.warn(.ui, "Desktop wallpaper sync write was slow", metadata: [
                                "source": source,
                                "screen": screen.localizedName,
                                "kind": "videoPoster",
                                "durationMS": String(format: "%.0f", elapsedMS)
                            ])
                        }
                        print("[DesktopWallpaperSyncManager] [\(source)] Synced video poster for screen \(screen.localizedName)")
                    } catch {
                        print("[DesktopWallpaperSyncManager] [\(source)] Failed to sync poster for screen \(screen.localizedName): \(error)")
                    }
                }
                continue
            }

            // 否则同步该屏幕最后注册的静态壁纸
            guard let url = lastSetImageURLByScreen[screenID] ?? lastSetImageURLByFingerprint[fingerprint] else {
                continue
            }

            // 跳过 wallpaper-wgpu 渲染的临时 capture 路径（应用重启后不存在）
            if url.path.contains("wallpaper-wgpu-capture") || url.path.contains("wallpaperengine-cli-capture") {
                print("[DesktopWallpaperSyncManager] [\(source)] Skipping wallpaper-wgpu capture path for screen \(screen.localizedName)")
                continue
            }

            if shouldSkipStaticDesktopWrites {
                print("[DesktopWallpaperSyncManager] [\(source)] 🔒 动态锁屏已启用，跳过静态壁纸同步 for screen \(screen.localizedName)")
                continue
            }

            do {
                let writeStart = Date()
                // 使用 setDesktopImageURLForAllSpaces 确保所有 Spaces 同步，
                // 该方法内部已发送 com.apple.desktop 通知，无需额外触发
                let options = lastOptionsByScreen[screenID] ?? lastOptionsByFingerprint[fingerprint] ?? [:]
                try workspace.setDesktopImageURLForAllSpaces(url, for: screen, options: options)
                syncWrites += 1
                let elapsedMS = Date().timeIntervalSince(writeStart) * 1000
                if elapsedMS >= 250 {
                    AppLogger.warn(.ui, "Desktop wallpaper sync write was slow", metadata: [
                        "source": source,
                        "screen": screen.localizedName,
                        "kind": "staticWallpaper",
                        "durationMS": String(format: "%.0f", elapsedMS)
                    ])
                }
                print("[DesktopWallpaperSyncManager] [\(source)] Synced static wallpaper for screen \(screen.localizedName)")
            } catch {
                print("[DesktopWallpaperSyncManager] [\(source)] Failed to sync wallpaper for screen \(screen.localizedName): \(error)")
            }
        }

        let totalMS = Date().timeIntervalSince(start) * 1000
        let logMetadata: [String: Any] = [
            "source": source,
            "screens": currentScreens.count,
            "writes": syncWrites,
            "durationMS": String(format: "%.0f", totalMS),
            "skipStaticWrites": shouldSkipStaticDesktopWrites
        ]
        if totalMS >= 500 {
            AppLogger.warn(.ui, "Desktop wallpaper sync completed slowly", metadata: logMetadata)
        } else {
            AppLogger.debug(.ui, "Desktop wallpaper sync completed", metadata: logMetadata)
        }
    }
}
