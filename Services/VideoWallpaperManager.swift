import Foundation
import AppKit
import AVFoundation
import CoreGraphics

@MainActor
final class VideoWallpaperManager: ObservableObject {
    static let shared = VideoWallpaperManager()

    @Published private(set) var currentVideoURL: URL?
    /// 已废弃：多屏场景下请使用 `posterURL(for:)` 获取指定屏幕的 poster
    @Published private(set) var currentPosterURL: URL?
    @Published private(set) var isMuted = true
    @Published private(set) var isPaused = false
    @Published private(set) var volume: Double = 1.0

    /// 每个屏幕的独立 poster（key 为 screenID），解决多屏自动更换时 poster 被覆盖的问题
    private var posterURLByScreen: [String: URL] = [:]
    /// 用于取消上一次未完成的 poster 设置任务，避免旧 poster 覆盖新壁纸
    private var posterTask: Task<Void, Never>?
    /// 每个屏幕的独立音量（key 为 screenID），未设置时回退到全局 `volume`
    private var volumeByScreen: [String: Double] = [:]

    private var windows: [String: WallpaperVideoWindow] = [:]
    private var players: [String: AVQueuePlayer] = [:]
    private var loopers: [String: AVPlayerLooper] = [:]
    /// 延迟释放的工作项，用于取消上一次未执行的清理，避免快速切换时多组 AVPlayer 并发驻留
    private var pendingPlayerCleanups: [DispatchWorkItem] = []
    private var pendingWindowCleanups: [DispatchWorkItem] = []

    /// 应挂载 MP4 壁纸层的屏幕 ID（`NSScreen.wallpaperScreenIdentifier`）。唤醒 / 分辨率变化时全局 `rebuildWindows()` 只重建这些屏，避免「只设一块屏动态」却给所有显示器都建了视频窗。
    private var videoTargetScreenIDs = Set<String>()
    
    /// 用于 poster 文件名的交替槽位，避免 macOS 桌面壁纸缓存旧图
    private var posterSlot = 0

    private let defaults = UserDefaults.standard
    private let stateKey = "video_wallpaper_state_v1"
    private let showPosterOnLockKey = "video_wallpaper_show_poster_on_lock"
    private let originalWallpaperKey = "video_wallpaper_original_desktop_v2"  // v2: 支持多屏幕配置
    
    /// 持久化预览图存储目录（避免被系统清理）
    /// 注意：放在 WallHaven 目录下，与 Cache 分开，避免被清理缓存误删
    private var persistedPosterDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: "/tmp")
        let dir = appSupport.appendingPathComponent("WallHaven", isDirectory: true)
            .appendingPathComponent("WallpaperPosters", isDirectory: true)
        // 确保目录存在
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    
    /// 获取指定屏幕的 poster URL（多屏场景下的正确入口）
    func posterURL(for screen: NSScreen) -> URL? {
        posterURLByScreen[screen.wallpaperScreenIdentifier]
    }

    /// 当前持久化的预览图路径（兼容旧代码，返回第一个找到的 poster）
    private var persistedPosterURL: URL? {
        guard let posterURL = posterURLByScreen.values.first else { return nil }
        let fileName = "poster_\(posterURL.lastPathComponent)"
        return persistedPosterDirectory.appendingPathComponent(fileName)
    }
    
    /// 是否在锁屏时显示预览图
    var showPosterOnLock: Bool {
        get {
            // 默认启用：未设置过此 key 时返回 true
            if defaults.object(forKey: showPosterOnLockKey) == nil {
                return true
            }
            return defaults.bool(forKey: showPosterOnLockKey)
        }
        set {
            defaults.set(newValue, forKey: showPosterOnLockKey)
            // 如果关闭此选项，隐藏所有预览图
            if !newValue {
                for screenID in windows.keys {
                    hidePosterImage(for: screenID)
                }
            }
        }
    }
    
    // 防止重复重建（@MainActor 保证串行访问，无需 NSLock）
    private var isRebuilding = false
    private var pendingRebuildWorkItem: DispatchWorkItem?

    private init() {
        setupNotificationObservers()
    }
    
    private func setupNotificationObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleScreensDidSleep),
            name: NSWorkspace.screensDidSleepNotification,
            object: nil
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleScreensDidWake),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
        
        // 监听锁屏/解锁通知
        DistributedNotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenLocked),
            name: Notification.Name("com.apple.screenIsLocked"),
            object: nil
        )
        
        DistributedNotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenUnlocked),
            name: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil
        )
    }
    
    @MainActor
    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default.removeObserver(self)
        pendingRebuildWorkItem?.cancel()
        pendingRebuildWorkItem = nil
    }

    func applyVideoWallpaper(from localFileURL: URL, posterURL: URL? = nil, muted: Bool = true, targetScreens: [NSScreen]?) throws {
        if let screens = targetScreens, !screens.isEmpty {
            for screen in screens {
                try applyVideoWallpaper(from: localFileURL, posterURL: posterURL, muted: muted, targetScreen: screen)
            }
        } else {
            try applyVideoWallpaper(from: localFileURL, posterURL: posterURL, muted: muted, targetScreen: nil)
        }
    }

    func applyVideoWallpaper(from localFileURL: URL, posterURL: URL? = nil, muted: Bool = true, targetScreen: NSScreen? = nil) throws {
        guard localFileURL.isFileURL else {
            throw NSError(domain: "VideoWallpaper", code: 1001, userInfo: [NSLocalizedDescriptionKey: "动态壁纸必须使用本地视频文件。"])
        }

        guard FileManager.default.fileExists(atPath: localFileURL.path) else {
            throw NSError(domain: "VideoWallpaper", code: 1002, userInfo: [NSLocalizedDescriptionKey: "视频文件不存在。"])
        }

        // 本机视频不经过 CLI：切换前始终向 CLI 发 stop，避免叠层或桥接状态与进程不同步
        WallpaperEngineXBridge.shared.ensureStoppedForNonCLIWallpaper()

        let isNewVideo = currentVideoURL != localFileURL
        let activeScreenIDs = Set(windows.keys)
        let screenIDsNow = Set(NSScreen.screens.map(\.wallpaperScreenIdentifier))

        if !isNewVideo,
           currentVideoURL == localFileURL,
           !windows.isEmpty,
           activeScreenIDs == videoTargetScreenIDs,
           videoTargetScreenIDs.isSubset(of: screenIDsNow) {
            currentVideoURL = localFileURL
            setMuted(muted)
            isPaused = false
            for player in players.values {
                if player.rate == 0 {
                    player.play()
                }
            }
            return
        }

        if isNewVideo {
            if let targetScreen {
                videoTargetScreenIDs = [targetScreen.wallpaperScreenIdentifier]
            } else {
                videoTargetScreenIDs = screenIDsNow
            }
        } else if let targetScreen {
            videoTargetScreenIDs.insert(targetScreen.wallpaperScreenIdentifier)
        } else {
            videoTargetScreenIDs = screenIDsNow
        }

        // 保存用户原始壁纸（如果是首次设置）
        if currentVideoURL == nil {
            saveOriginalWallpaper()
        }
        
        // 如果有预览图，设置为桌面壁纸（锁屏会显示这个）
        // 注意：此处 fire-and-forget，不阻塞主线程；poster 为 nil 时不恢复原始壁纸，
        // 避免切换时出现「闪回原始壁纸」的中间态。视频窗口会覆盖在桌面壁纸上方。
        if let posterURL = posterURL {
            setPosterAsDesktopWallpaper(posterURL, targetScreen: targetScreen)
        }

        currentVideoURL = localFileURL
        // 按屏幕记录 poster，防止多屏自动更换时互相覆盖
        if let targetScreen {
            posterURLByScreen[targetScreen.wallpaperScreenIdentifier] = posterURL
        } else {
            for screen in NSScreen.screens {
                posterURLByScreen[screen.wallpaperScreenIdentifier] = posterURL
            }
        }
        currentPosterURL = posterURL  // 兼容旧代码
        isMuted = muted
        isPaused = false

        try rebuildWindows(targetScreen: targetScreen)
        persistState()
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        for (screenID, player) in players {
            player.isMuted = muted
            let screenVolume = volumeByScreen[screenID] ?? volume
            player.volume = muted ? 0 : Float(screenVolume)
        }
        persistState()
    }

    func setVolume(_ newVolume: Double, for targetScreen: NSScreen? = nil) {
        let clamped = max(0, min(1, newVolume))
        if let targetScreen = targetScreen {
            let screenID = targetScreen.wallpaperScreenIdentifier
            volumeByScreen[screenID] = clamped
            players[screenID]?.volume = isMuted ? 0 : Float(clamped)
        } else {
            volume = clamped
            volumeByScreen.removeAll()
            for player in players.values {
                player.volume = isMuted ? 0 : Float(clamped)
            }
        }
        persistState()
    }

    /// 获取指定屏幕的音量（优先使用独立设置，否则回退全局）
    func volume(for screen: NSScreen) -> Double {
        let screenID = screen.wallpaperScreenIdentifier
        return volumeByScreen[screenID] ?? volume
    }

    func pauseWallpaper(for targetScreen: NSScreen? = nil) {
        if let targetScreen = targetScreen {
            // 暂停特定屏幕的壁纸
            let screenID = targetScreen.wallpaperScreenIdentifier
            players[screenID]?.pause()
            // 将 rate 设为 0 确保完全停止渲染，但保持 player 连接
            players[screenID]?.rate = 0
            showPosterImage(for: screenID)
        } else {
            // 暂停所有屏幕的壁纸
            isPaused = true
            for player in players.values {
                player.pause()
                // 将 rate 设为 0 确保完全停止渲染
                player.rate = 0
            }
        }
        persistState()
    }

    func resumeWallpaper(for targetScreen: NSScreen? = nil) {
        guard currentVideoURL != nil else { return }
        
        if let targetScreen = targetScreen {
            // 恢复特定屏幕的壁纸
            let screenID = targetScreen.wallpaperScreenIdentifier
            players[screenID]?.play()
            hidePosterImage(for: screenID)
        } else {
            // 恢复所有屏幕的壁纸
            isPaused = false
            for (screenID, player) in players {
                player.play()
                hidePosterImage(for: screenID)
            }
        }
        persistState()
    }
    
    /// 获取当前正在播放动态壁纸的显示器
    var activeScreens: [NSScreen] {
        let activeScreenIDs = Set(players.keys)
        return NSScreen.screens.filter { screen in
            activeScreenIDs.contains(screen.wallpaperScreenIdentifier)
        }
    }
    
    /// 检测指定屏幕是否有正在播放的动态壁纸
    func hasActiveWallpaper(on screen: NSScreen) -> Bool {
        let screenID = screen.wallpaperScreenIdentifier
        return players[screenID] != nil
    }
    
    // MARK: - 锁屏处理
    
    /// 当前是否处于锁屏状态（供 AutoPauseManager 等外部模块查询）
    private(set) var isScreenLocked = false
    
    @objc private func handleScreenLocked() {
        // ⚠️ DistributedNotificationCenter 回调不在主线程！必须 dispatch 到主线程
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            print("[VideoWallpaperManager] Screen locked, pausing wallpaper")
            self.isScreenLocked = true
            // 锁屏时暂停视频，显示预览图（预览图已设为桌面壁纸）
            for player in self.players.values {
                player.pause()
                player.rate = 0
            }
            // 所有屏幕显示预览图
            for screenID in self.windows.keys {
                self.showPosterImage(for: screenID)
            }
        }
    }
    
    @objc private func handleScreenUnlocked() {
        // ⚠️ DistributedNotificationCenter 回调不在主线程！必须 dispatch 到主线程
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            print("[VideoWallpaperManager] Screen unlocked, resuming wallpaper")
            self.isScreenLocked = false
            // 解锁时恢复播放（如果不是手动暂停）
            guard !self.isPaused else { return }
            for (screenID, player) in self.players {
                player.play()
                self.hidePosterImage(for: screenID)
            }
        }
    }

    func stopWallpaper(for targetScreen: NSScreen? = nil) {
        guard let targetScreen = targetScreen else {
            // 全局停止（原有逻辑）
            WallpaperEngineXBridge.shared.ensureStoppedForNonCLIWallpaper()

            let wasPlayingVideo = currentVideoURL != nil
            teardownAllWindows()
            currentVideoURL = nil
            currentPosterURL = nil
            posterURLByScreen.removeAll()
            isPaused = false
            videoTargetScreenIDs = []
            // 不删除保存的状态，以便下次可以恢复

            if wasPlayingVideo {
                restoreOriginalWallpaper()
            }
            return
        }

        // 单屏停止：只有该屏幕确实有视频在播放时才恢复原始壁纸
        let screenID = targetScreen.wallpaperScreenIdentifier
        guard windows[screenID] != nil || players[screenID] != nil else {
            // 该屏幕没有视频壁纸在播放，无需操作
            return
        }

        teardownWindow(for: screenID)
        videoTargetScreenIDs.remove(screenID)
        posterURLByScreen.removeValue(forKey: screenID)
        restoreOriginalWallpaper(for: targetScreen)

        if players.isEmpty {
            currentVideoURL = nil
            currentPosterURL = nil
            posterURLByScreen.removeAll()
            isPaused = false
            videoTargetScreenIDs = []
            WallpaperEngineXBridge.shared.ensureStoppedForNonCLIWallpaper()
        }
    }

    /// 仅拆掉本机 AVPlayer 视频壁纸，**不**调用 `WallpaperEngineXBridge.stopWallpaper()`。
    /// 在即将通过 CLI 设置 scene / web 等 WE 壁纸前调用，否则会误停 CLI 且把 `isControllingExternalEngine` 清掉，菜单栏暂停恢复会走错视频分支。
    func stopNativeVideoWallpaperOnly(for targetScreen: NSScreen? = nil) {
        guard let targetScreen = targetScreen else {
            // 全局停止（原有逻辑）
            let wasPlayingVideo = currentVideoURL != nil
            teardownAllWindows()
            currentVideoURL = nil
            currentPosterURL = nil
            posterURLByScreen.removeAll()
            isPaused = false
            videoTargetScreenIDs = []
            defaults.removeObject(forKey: stateKey)

            if wasPlayingVideo {
                restoreOriginalWallpaper()
            }
            return
        }

        // 单屏停止：只有该屏幕确实有视频在播放时才恢复原始壁纸
        let screenID = targetScreen.wallpaperScreenIdentifier
        guard windows[screenID] != nil || players[screenID] != nil else {
            // 该屏幕没有视频壁纸在播放，无需操作（避免自动切换时误恢复旧壁纸导致闪烁）
            return
        }

        teardownWindow(for: screenID)
        videoTargetScreenIDs.remove(screenID)
        posterURLByScreen.removeValue(forKey: screenID)
        restoreOriginalWallpaper(for: targetScreen)

        if players.isEmpty {
            currentVideoURL = nil
            currentPosterURL = nil
            posterURLByScreen.removeAll()
            isPaused = false
            videoTargetScreenIDs = []
            defaults.removeObject(forKey: stateKey)
        }
    }

    /// 拆除单个屏幕的视频窗口、player 和 looper
    private func teardownWindow(for screenID: String) {
        if let window = windows[screenID] {
            if let contentView = window.contentView as? WallpaperVideoContainerView {
                contentView.playerLayer.player = nil
            }
            window.contentView = nil
            window.orderOut(nil)
            windows.removeValue(forKey: screenID)
            let windowWork = DispatchWorkItem { _ = window }
            pendingWindowCleanups.append(windowWork)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: windowWork)
        }
        if let player = players[screenID] {
            player.pause()
            player.removeAllItems()
            players.removeValue(forKey: screenID)
            let playerWork = DispatchWorkItem { _ = player }
            pendingPlayerCleanups.append(playerWork)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: playerWork)
        }
        if let looper = loopers[screenID] {
            looper.disableLooping()
            loopers.removeValue(forKey: screenID)
        }
    }
    
    // MARK: - 锁屏壁纸管理
    
    /// 保存用户当前的桌面壁纸（锁屏显示的是桌面壁纸）
    /// v2: 支持多屏幕配置，保存每个屏幕的壁纸
    private func saveOriginalWallpaper() {
        let workspace = NSWorkspace.shared
        var screenConfigs: [ScreenWallpaperConfig] = []
        
        for screen in NSScreen.screens {
            if let desktopURL = workspace.desktopImageURL(for: screen) {
                // 检查是否是我们自己的预览图（如果是，不要保存）
                if isOurPosterImage(desktopURL) {
                    print("[VideoWallpaperManager] Skipping our own poster image: \(desktopURL.lastPathComponent)")
                    continue
                }
                
                let config = ScreenWallpaperConfig(
                    screenID: screen.wallpaperScreenIdentifier,
                    screenName: screen.localizedName,
                    wallpaperURL: desktopURL.absoluteString,
                    isMainScreen: screen == NSScreen.main
                )
                screenConfigs.append(config)
            }
        }
        
        guard !screenConfigs.isEmpty else {
            print("[VideoWallpaperManager] No valid original wallpaper to save")
            return
        }
        
        let savedState = SavedOriginalWallpaperState(
            configs: screenConfigs,
            savedAt: Date(),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        )
        
        if let data = try? JSONEncoder().encode(savedState) {
            defaults.set(data, forKey: originalWallpaperKey)
            print("[VideoWallpaperManager] Saved original wallpaper for \(screenConfigs.count) screen(s)")
        }
    }
    
    /// 检查是否是我们自己的预览图
    private func isOurPosterImage(_ url: URL) -> Bool {
        // 检查路径是否包含我们的预览图目录
        let path = url.path
        return path.contains("WallpaperPosters") && path.contains("poster_")
    }
    
    /// 将预览图设为桌面壁纸，同时显式写入锁屏壁纸。
    /// 使用持久化存储，避免被系统清理。
    /// - Note: 如需同步等待完成，请直接调用 `applyPosterAsDesktopWallpaper`；此方法内部 fire-and-forget。
    private func setPosterAsDesktopWallpaper(_ posterURL: URL, targetScreen: NSScreen? = nil) {
        // 取消上一次未完成的 poster 设置，避免旧 poster 覆盖新壁纸
        posterTask?.cancel()
        posterTask = Task { @MainActor in
            await applyPosterAsDesktopWallpaper(posterURL, targetScreen: targetScreen)
        }
    }

    /// 恢复场景专用的同步 poster 设置，确保桌面/锁屏底图在视频窗口重建前已就绪
    private func applyPosterAsDesktopWallpaperSync(_ posterURL: URL, targetScreen: NSScreen? = nil) {
        let workspace = NSWorkspace.shared
        do {
            let data = try Data(contentsOf: posterURL)
            // 使用交替槽位避免 macOS 桌面壁纸缓存旧图
            posterSlot = 1 - posterSlot
            let slotPrefix = posterSlot == 0 ? "poster_0_" : "poster_1_"
            let persistentURL = persistedPosterDirectory
                .appendingPathComponent("\(slotPrefix)\(posterURL.lastPathComponent)")
            cleanupOldPosters(keeping: persistentURL)
            try data.write(to: persistentURL)
            print("[VideoWallpaperManager] [sync] Saved poster to persistent location: \(persistentURL.path)")

            let screensToSet: [NSScreen]
            if let targetScreen = targetScreen {
                screensToSet = [targetScreen]
            } else {
                screensToSet = NSScreen.screens
            }

            let fillOptions: [NSWorkspace.DesktopImageOptionKey: Any] = [
                .imageScaling: NSNumber(value: NSImageScaling.scaleProportionallyUpOrDown.rawValue),
                .allowClipping: true
            ]
            for screen in screensToSet {
                try workspace.setDesktopImageURLForAllSpaces(persistentURL, for: screen, options: fillOptions)
            }
            print("[VideoWallpaperManager] [sync] Set poster as desktop wallpaper for \(screensToSet.count) screen(s)")
        } catch {
            print("[VideoWallpaperManager] [sync] Failed to set poster: \(error)")
        }
    }

    /// 异步可等待的 poster 设置核心逻辑
    private func applyPosterAsDesktopWallpaper(_ posterURL: URL, targetScreen: NSScreen? = nil) async {
        // 检查是否已被取消（快速连续切换壁纸时，旧任务应放弃）
        try? await Task.sleep(nanoseconds: 0)
        guard !Task.isCancelled else { return }
        let workspace = NSWorkspace.shared
        do {
            // 1. 读取预览图（本地文件或网络）
            let data: Data
            if posterURL.isFileURL {
                data = try Data(contentsOf: posterURL)
            } else {
                let (d, _) = try await URLSession.shared.data(from: posterURL)
                data = d
            }

            // 2. 保存到持久化目录（而不是临时目录）
            // 使用交替槽位避免 macOS 桌面壁纸缓存旧图
            posterSlot = 1 - posterSlot
            let slotPrefix = posterSlot == 0 ? "poster_0_" : "poster_1_"
            let persistentURL = persistedPosterDirectory
                .appendingPathComponent("\(slotPrefix)\(posterURL.lastPathComponent)")

            // 清理旧的预览图文件（保留最近5个）
            cleanupOldPosters(keeping: persistentURL)

            try data.write(to: persistentURL)
            print("[VideoWallpaperManager] Saved poster to persistent location: \(persistentURL.path)")

            // 3. 设置为桌面壁纸
            let screensToSet: [NSScreen]
            if let targetScreen = targetScreen {
                screensToSet = [targetScreen]
            } else {
                screensToSet = NSScreen.screens
            }

            // 使用 "充满屏幕" 缩放模式，避免锁屏出现填充色（与手动设置行为一致）
            let fillOptions: [NSWorkspace.DesktopImageOptionKey: Any] = [
                .imageScaling: NSNumber(value: NSImageScaling.scaleProportionallyUpOrDown.rawValue),
                .allowClipping: true
            ]
            for screen in screensToSet {
                try workspace.setDesktopImageURLForAllSpaces(persistentURL, for: screen, options: fillOptions)
            }
            print("[VideoWallpaperManager] Set poster as desktop wallpaper for \(screensToSet.count) screen(s)")
            // macOS 锁屏壁纸默认跟随桌面壁纸，无需额外设置
        } catch {
            print("[VideoWallpaperManager] Failed to set poster: \(error)")
        }
    }
    
    /// 清理旧的预览图文件，只保留最近的几个（同步版本）
    private func cleanupOldPosters(keeping keepURL: URL) {
        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: persistedPosterDirectory,
                includingPropertiesForKeys: [.creationDateKey],
                options: .skipsHiddenFiles
            )
            
            // 按创建时间排序，保留最新的5个
            let sortedFiles = files
                .filter { $0.lastPathComponent.hasPrefix("poster_") }
                .compactMap { url -> (URL, Date)? in
                    guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                          let date = attrs[.creationDate] as? Date else { return nil }
                    return (url, date)
                }
                .sorted { $0.1 > $1.1 }
            
            // 删除旧的（保留5个 + 当前要保存的）
            let filesToDelete = sortedFiles.dropFirst(5)
            for (url, _) in filesToDelete {
                if url != keepURL {
                    try? FileManager.default.removeItem(at: url)
                    print("[VideoWallpaperManager] Cleaned up old poster: \(url.lastPathComponent)")
                }
            }
        } catch {
            print("[VideoWallpaperManager] Failed to cleanup old posters: \(error)")
        }
    }
    
    /// 恢复用户原始桌面壁纸
    /// v2: 支持屏幕配置变化，优先匹配主屏幕，支持跨屏幕恢复
    private func restoreOriginalWallpaper() {
        guard let data = defaults.data(forKey: originalWallpaperKey),
              let savedState = try? JSONDecoder().decode(SavedOriginalWallpaperState.self, from: data) else {
            print("[VideoWallpaperManager] No original wallpaper to restore")
            return
        }
        
        print("[VideoWallpaperManager] Restoring wallpaper from state saved at \(savedState.savedAt)")
        
        let workspace = NSWorkspace.shared
        let currentScreens = NSScreen.screens
        
        // 1. 尝试精确匹配：找到与当前屏幕ID相同的配置
        var restoredCount = 0
        var unmatchedScreens: [NSScreen] = []
        
        for screen in currentScreens {
            let screenID = screen.wallpaperScreenIdentifier
            
            if let config = savedState.configs.first(where: { $0.screenID == screenID }),
               let originalURL = URL(string: config.wallpaperURL),
               FileManager.default.fileExists(atPath: originalURL.path) {
                do {
                    try workspace.setDesktopImageURLForAllSpaces(originalURL, for: screen)
                    print("[VideoWallpaperManager] Restored wallpaper for screen \(screen.localizedName) (exact match)")
                    restoredCount += 1
                } catch {
                    print("[VideoWallpaperManager] Failed to restore wallpaper for screen \(screenID): \(error)")
                    unmatchedScreens.append(screen)
                }
            } else {
                unmatchedScreens.append(screen)
            }
        }
        
        // 2. 对于未匹配的屏幕，尝试使用主屏幕的配置（如果主屏幕配置存在且有效）
        if !unmatchedScreens.isEmpty,
           let mainConfig = savedState.configs.first(where: { $0.isMainScreen }),
           let mainURL = URL(string: mainConfig.wallpaperURL),
           FileManager.default.fileExists(atPath: mainURL.path) {
            for screen in unmatchedScreens {
                do {
                    try workspace.setDesktopImageURLForAllSpaces(mainURL, for: screen)
                    print("[VideoWallpaperManager] Restored wallpaper for screen \(screen.localizedName) (fallback to main screen)")
                    restoredCount += 1
                } catch {
                    print("[VideoWallpaperManager] Failed to restore wallpaper for screen \(screen.localizedName): \(error)")
                }
            }
        }
        
        // 3. 对于仍然未匹配的屏幕，尝试使用任意可用的配置
        if restoredCount == 0 && !savedState.configs.isEmpty {
            for config in savedState.configs {
                if let url = URL(string: config.wallpaperURL),
                   FileManager.default.fileExists(atPath: url.path) {
                    for screen in unmatchedScreens {
                        do {
                            try workspace.setDesktopImageURLForAllSpaces(url, for: screen)
                            print("[VideoWallpaperManager] Restored wallpaper for screen \(screen.localizedName) (fallback to any available)")
                        } catch {
                            print("[VideoWallpaperManager] Failed to restore wallpaper: \(error)")
                        }
                    }
                    break
                }
            }
        }
        
        // 4. 清理：删除持久化的预览图文件
        cleanupPersistedPosters()
        
        // 清除保存的原始壁纸状态
        defaults.removeObject(forKey: originalWallpaperKey)
        print("[VideoWallpaperManager] Original wallpaper restore completed")
    }

    /// 恢复单个屏幕的原始桌面壁纸
    private func restoreOriginalWallpaper(for screen: NSScreen) {
        guard let data = defaults.data(forKey: originalWallpaperKey),
              let savedState = try? JSONDecoder().decode(SavedOriginalWallpaperState.self, from: data) else {
            print("[VideoWallpaperManager] No original wallpaper to restore for screen \(screen.localizedName)")
            return
        }

        let screenID = screen.wallpaperScreenIdentifier
        let workspace = NSWorkspace.shared

        // 1. 尝试精确匹配
        if let config = savedState.configs.first(where: { $0.screenID == screenID }),
           let originalURL = URL(string: config.wallpaperURL),
           FileManager.default.fileExists(atPath: originalURL.path) {
            do {
                try workspace.setDesktopImageURLForAllSpaces(originalURL, for: screen)
                print("[VideoWallpaperManager] Restored wallpaper for screen \(screen.localizedName) (exact match)")
            } catch {
                print("[VideoWallpaperManager] Failed to restore wallpaper for screen \(screenID): \(error)")
            }
            return
        }

        // 2. fallback 到主屏幕配置
        if let mainConfig = savedState.configs.first(where: { $0.isMainScreen }),
           let mainURL = URL(string: mainConfig.wallpaperURL),
           FileManager.default.fileExists(atPath: mainURL.path) {
            do {
                try workspace.setDesktopImageURLForAllSpaces(mainURL, for: screen)
                print("[VideoWallpaperManager] Restored wallpaper for screen \(screen.localizedName) (fallback to main screen)")
            } catch {
                print("[VideoWallpaperManager] Failed to restore wallpaper for screen \(screen.localizedName): \(error)")
            }
            return
        }

        // 3. fallback 到任意可用配置
        if let config = savedState.configs.first(where: {
            guard let url = URL(string: $0.wallpaperURL) else { return false }
            return FileManager.default.fileExists(atPath: url.path)
        }),
           let url = URL(string: config.wallpaperURL) {
            do {
                try workspace.setDesktopImageURLForAllSpaces(url, for: screen)
                print("[VideoWallpaperManager] Restored wallpaper for screen \(screen.localizedName) (fallback to any available)")
            } catch {
                print("[VideoWallpaperManager] Failed to restore wallpaper for screen \(screen.localizedName): \(error)")
            }
        }
    }

    /// 清理所有持久化的预览图文件
    private func cleanupPersistedPosters() {
        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: persistedPosterDirectory,
                includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles
            )
            for file in files where file.lastPathComponent.hasPrefix("poster_") {
                try? FileManager.default.removeItem(at: file)
                print("[VideoWallpaperManager] Cleaned up persisted poster: \(file.lastPathComponent)")
            }
        } catch {
            print("[VideoWallpaperManager] Failed to cleanup persisted posters: \(error)")
        }
    }

    func restoreIfNeeded() {
        guard
            let data = defaults.data(forKey: stateKey),
            let savedState = try? JSONDecoder().decode(SavedVideoWallpaperState.self, from: data),
            let url = URL(string: savedState.fileURL),
            FileManager.default.fileExists(atPath: url.path)
        else {
            defaults.removeObject(forKey: stateKey)
            return
        }

        // 恢复预览图 URL（兼容旧版单例 poster）
        let globalPosterURL = savedState.posterURL.flatMap { URL(string: $0) }
        // 恢复 per-screen poster（新版）
        let restoredPosterURLs = savedState.posterURLs?.compactMapValues { URL(string: $0) } ?? [:]
        posterURLByScreen = restoredPosterURLs
        // 兼容旧数据：如果 per-screen 为空但有全局 poster，平铺到所有目标屏
        if posterURLByScreen.isEmpty, let globalPosterURL, let ids = savedState.videoScreenIDs {
            for screenID in ids {
                posterURLByScreen[screenID] = globalPosterURL
            }
        }

        do {
            if let ids = savedState.videoScreenIDs, !ids.isEmpty {
                if currentVideoURL == nil {
                    saveOriginalWallpaper()
                }
                currentVideoURL = url
                currentPosterURL = globalPosterURL  // 兼容旧代码
                isMuted = savedState.isMuted
                volume = savedState.volume ?? (savedState.isMuted ? 0 : 1)
                volumeByScreen = savedState.volumeByScreen ?? [:]
                isPaused = false
                videoTargetScreenIDs = Set(ids)
                // 恢复场景下异步设置 poster，不阻塞主线程；视频窗口会覆盖在 poster 上方
                for screen in screensForVideoWallpaperTargets() {
                    let screenID = screen.wallpaperScreenIdentifier
                    if let posterURL = posterURLByScreen[screenID] {
                        setPosterAsDesktopWallpaper(posterURL, targetScreen: screen)
                        DesktopWallpaperSyncManager.shared.registerWallpaperSet(posterURL, for: screen)
                    }
                }
                try rebuildWindows()
                if savedState.isPaused {
                    pauseWallpaper()
                }
                persistState()
            } else {
                try applyVideoWallpaper(from: url, posterURL: globalPosterURL, muted: savedState.isMuted)
                volume = savedState.volume ?? (savedState.isMuted ? 0 : 1)
                volumeByScreen = savedState.volumeByScreen ?? [:]
                for screen in NSScreen.screens {
                    let screenVolume = volume(for: screen)
                    let screenID = screen.wallpaperScreenIdentifier
                    players[screenID]?.volume = isMuted ? 0 : Float(screenVolume)
                }
                if savedState.isPaused {
                    pauseWallpaper()
                }
            }
        } catch {
            defaults.removeObject(forKey: stateKey)
        }
    }

    /// 批量更新持久化状态中的文件路径（目录迁移后调用）
    func bulkUpdatePaths(oldPrefix: String, newPrefix: String) {
        guard let data = defaults.data(forKey: stateKey),
              var savedState = try? JSONDecoder().decode(SavedVideoWallpaperState.self, from: data) else {
            return
        }
        var changed = false
        if savedState.fileURL.hasPrefix(oldPrefix) {
            savedState = SavedVideoWallpaperState(
                fileURL: newPrefix + String(savedState.fileURL.dropFirst(oldPrefix.count)),
                posterURL: savedState.posterURL.flatMap { url in
                    url.hasPrefix(oldPrefix) ? newPrefix + String(url.dropFirst(oldPrefix.count)) : url
                },
                isMuted: savedState.isMuted,
                isPaused: savedState.isPaused,
                volume: savedState.volume,
                volumeByScreen: savedState.volumeByScreen,
                videoScreenIDs: savedState.videoScreenIDs,
                posterURLs: savedState.posterURLs?.mapValues { url in
                    url.hasPrefix(oldPrefix) ? newPrefix + String(url.dropFirst(oldPrefix.count)) : url
                }
            )
            changed = true
        }
        if changed, let encoded = try? JSONEncoder().encode(savedState) {
            defaults.set(encoded, forKey: stateKey)
            print("[VideoWallpaperManager] Updated persisted paths from \(oldPrefix) to \(newPrefix)")
        }
    }

    @objc private func handleScreenParametersChanged() {
        // ⚠️ NSNotification 回调可能不在主线程，dispatch 到主线程
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard self.currentVideoURL != nil else { return }
            
            // 防抖：延迟 300ms 执行，避免屏幕参数变化时的频繁重建
            self.pendingRebuildWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self, self.currentVideoURL != nil else { return }

                // 清理已断开显示器的残留状态
                let currentScreenIDs = Set(NSScreen.screens.map { $0.wallpaperScreenIdentifier })
                for screenID in Set(self.posterURLByScreen.keys).subtracting(currentScreenIDs) {
                    self.posterURLByScreen.removeValue(forKey: screenID)
                }
                for screenID in Set(self.volumeByScreen.keys).subtracting(currentScreenIDs) {
                    self.volumeByScreen.removeValue(forKey: screenID)
                }
                self.videoTargetScreenIDs = self.videoTargetScreenIDs.intersection(currentScreenIDs)

                do {
                    try self.rebuildWindows()
                } catch {
                    NSLog("[VideoWallpaperManager] Failed to rebuild windows: \(error.localizedDescription)")
                }
            }
            self.pendingRebuildWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
        }
    }

    @objc private func handleScreensDidSleep() {
        // ⚠️ NSWorkspace 通知可能不在主线程，dispatch 到主线程
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            for player in self.players.values {
                player.pause()
                player.rate = 0
            }
        }
    }

    @objc private func handleScreensDidWake() {
        // ⚠️ NSWorkspace 通知可能不在主线程，dispatch 到主线程
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // 屏幕唤醒时防抖重建
            self.pendingRebuildWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                if self.currentVideoURL != nil, self.windows.isEmpty {
                    try? self.rebuildWindows()
                }
                // 只有非手动暂停时才恢复播放
                if !self.isPaused {
                    for (screenID, player) in self.players {
                        player.play()
                        self.hidePosterImage(for: screenID)
                    }
                }
            }
            self.pendingRebuildWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
        }
    }

    private func rebuildWindows(targetScreen: NSScreen? = nil) throws {
        guard let currentVideoURL else { return }
        
        // 如果正在重建，跳过此次请求
        // 注意：@MainActor 保证串行执行，无需额外加锁
        guard !isRebuilding else {
            NSLog("[VideoWallpaperManager] Rebuild already in progress, skipping...")
            return
        }
        
        isRebuilding = true
        defer { isRebuilding = false }

        // 如果指定了目标屏幕，只重建该屏幕的窗口
        let screensToRebuild: [NSScreen]
        if let targetScreen = targetScreen {
            screensToRebuild = [targetScreen]
            // 保留其他屏幕的窗口
            let targetScreenID = targetScreen.wallpaperScreenIdentifier
            for (screenID, _) in windows {
                if screenID != targetScreenID {
                    // 保留非目标窗口，稍后重新添加
                    // 注意：这里我们简单地保留所有窗口，只更新目标屏幕
                }
            }
        } else {
            screensToRebuild = screensForVideoWallpaperTargets()
        }

        NSLog("[VideoWallpaperManager] Rebuilding windows for \(screensToRebuild.count) screen(s)")
        
        // 如果只更新特定屏幕，不要 teardown 所有窗口——优先复用现有窗口，只替换 player，实现无感切换
        if targetScreen == nil {
            teardownAllWindows()
            for screen in screensToRebuild {
                Task { @MainActor in
                    do {
                        try createWindow(for: screen, videoURL: currentVideoURL, muted: isMuted)
                    } catch {
                        NSLog("[VideoWallpaperManager] Failed to create window: \(error.localizedDescription)")
                    }
                }
            }
        } else {
            guard let targetScreen = targetScreen else { return }
            let targetScreenID = targetScreen.wallpaperScreenIdentifier
            if let existingWindow = windows[targetScreenID],
               let containerView = existingWindow.contentView as? WallpaperVideoContainerView {
                // 复用窗口：无缝替换 player，避免窗口闪烁和重新初始化感
                // 1. 停止旧 player/looper（延迟释放，避免 MediaToolbox 崩溃）
                if let oldPlayer = players[targetScreenID] {
                    oldPlayer.pause()
                    oldPlayer.removeAllItems()
                    players.removeValue(forKey: targetScreenID)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { _ = oldPlayer }
                }
                if let oldLooper = loopers[targetScreenID] {
                    oldLooper.disableLooping()
                    loopers.removeValue(forKey: targetScreenID)
                }
                
                // 2. 创建新 player
                let components = makePlayerComponents(for: targetScreen, videoURL: currentVideoURL, muted: isMuted)
                self.loopers[targetScreenID] = components.looper
                
                // 3. 无缝替换：直接修改 playerLayer.player，窗口始终停留在桌面层级
                containerView.playerLayer.player = components.player
                containerView.playerLayer.videoGravity = AVLayerVideoGravity.resizeAspectFill
                components.player.play()
                
                // 更新噪点纹理叠加（桌面壁纸颗粒蒙层，由 Settings 开关独立控制）
                let grainEnabled = ArcBackgroundSettings.shared.grainTextureEnabled
                if grainEnabled {
                    containerView.showGrainOverlay(intensity: ArcBackgroundSettings.shared.grainIntensity)
                } else {
                    containerView.hideGrainOverlay()
                }
                
                // 4. 更新字典
                players[targetScreenID] = components.player
                
                NSLog("[VideoWallpaperManager] Seamlessly replaced player for screen \(targetScreenID)")
            } else {
                // 没有现有窗口，创建新窗口
                do {
                    try createWindow(for: targetScreen, videoURL: currentVideoURL, muted: isMuted)
                } catch {
                    NSLog("[VideoWallpaperManager] Failed to create window: \(error.localizedDescription)")
                }
            }
        }

        NSLog("[VideoWallpaperManager] Windows rebuilt successfully")
    }

    /// 全局重建时只返回应显示 MP4 的 `NSScreen`（与 `videoTargetScreenIDs` 对齐）
    private func screensForVideoWallpaperTargets() -> [NSScreen] {
        if videoTargetScreenIDs.isEmpty {
            return NSScreen.screens
        }
        let matched = NSScreen.screens.filter { videoTargetScreenIDs.contains($0.wallpaperScreenIdentifier) }
        if matched.isEmpty {
            // 睡眠唤醒后偶发 NSScreenNumber 变化，单屏目标退回到主屏；多屏则退回全部以免无窗口
            if videoTargetScreenIDs.count == 1, let main = NSScreen.main {
                return [main]
            }
            return NSScreen.screens
        }
        return matched
    }

    /// 创建一个带首尾 crossfade dissolve 的 composition player item。
    /// 播放结束后需 seek 到 fadeDuration 处继续循环，实现首尾帧无缝衔接。
    private func makeLoopingCompositionItem(videoURL: URL, fadeDuration: Double = 1.0) async throws -> AVPlayerItem {
        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)

        guard let videoTrack = videoTracks.first else {
            throw NSError(domain: "VideoWallpaper", code: 2001, userInfo: [NSLocalizedDescriptionKey: "No video track"])
        }

        let fadeCMTime = CMTime(seconds: fadeDuration, preferredTimescale: 600)

        // 视频太短无法做 crossfade，直接返回原始 item
        guard duration > CMTimeMultiply(fadeCMTime, multiplier: 2) else {
            return AVPlayerItem(url: videoURL)
        }

        let composition = AVMutableComposition()

        // Track 1: 原视频完整播放（底层）
        guard let track1 = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw NSError(domain: "VideoWallpaper", code: 2002)
        }
        try track1.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: videoTrack, at: .zero)

        // Track 2: 原视频开头 fadeDuration 秒，插入到 (duration - fadeDuration) 处（上层）
        guard let track2 = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw NSError(domain: "VideoWallpaper", code: 2003)
        }
        let track2InsertTime = duration - fadeCMTime
        try track2.insertTimeRange(CMTimeRange(start: .zero, duration: fadeCMTime), of: videoTrack, at: track2InsertTime)

        // 音频：简单复制完整音频（不做 crossfade，壁纸通常静音）
        if let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first,
           let compositionAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try? compositionAudioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: audioTrack, at: .zero)
        }

        // Video composition: opacity ramps
        let naturalSize = try await videoTrack.load(.naturalSize)
        let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
        let frameRate = nominalFrameRate > 0 ? nominalFrameRate : 30

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = naturalSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)

        let layerInstruction1 = AVMutableVideoCompositionLayerInstruction(assetTrack: track1)
        let layerInstruction2 = AVMutableVideoCompositionLayerInstruction(assetTrack: track2)

        let fadeStart = duration - fadeCMTime

        // Track 1: 在结尾 fadeDuration 区间从 opacity 1→0（淡出）
        layerInstruction1.setOpacityRamp(
            fromStartOpacity: 1.0,
            toEndOpacity: 0.0,
            timeRange: CMTimeRange(start: fadeStart, duration: fadeCMTime)
        )

        // Track 2: 在结尾 fadeDuration 区间从 opacity 0→1（淡入）
        layerInstruction2.setOpacityRamp(
            fromStartOpacity: 0.0,
            toEndOpacity: 1.0,
            timeRange: CMTimeRange(start: fadeStart, duration: fadeCMTime)
        )

        // layerInstructions 从下到上
        instruction.layerInstructions = [layerInstruction1, layerInstruction2]
        videoComposition.instructions = [instruction]

        let playerItem = AVPlayerItem(asset: composition)
        playerItem.videoComposition = videoComposition
        return playerItem
    }

    @objc private func handleCompositionLoop(_ notification: Notification) {
        guard let item = notification.object as? AVPlayerItem else { return }
        let fadeDuration = CMTime(seconds: 1.0, preferredTimescale: 600)
        for (_, player) in players {
            if player.currentItem === item {
                player.seek(to: fadeDuration, toleranceBefore: .zero, toleranceAfter: .zero)
                player.play()
                return
            }
        }
    }

    /// 创建并配置 AVPlayer + AVPlayerLooper，供 `createWindow` 与窗口复用路径共享。
    private func makePlayerComponents(for screen: NSScreen, videoURL: URL, muted: Bool) -> (player: AVQueuePlayer, looper: AVPlayerLooper, item: AVPlayerItem) {
        let playerItem = AVPlayerItem(url: videoURL)

        // 配置高质量播放设置
        playerItem.preferredPeakBitRate = 0
        if #available(macOS 10.15, *) {
            playerItem.appliesPerFrameHDRDisplayMetadata = true
        }
        let screenSize = screen.frame.size
        playerItem.preferredMaximumResolution = CGSize(
            width: screenSize.width * screen.backingScaleFactor,
            height: screenSize.height * screen.backingScaleFactor
        )
        if #available(macOS 10.15, *) {
            playerItem.seekingWaitsForVideoCompositionRendering = false
        }
        playerItem.audioTimePitchAlgorithm = .timeDomain
        if videoURL.isFileURL {
            // 限制为 30 秒预缓冲，避免大视频文件无限占用内存
            playerItem.preferredForwardBufferDuration = 30.0
        }

        let queuePlayer = AVQueuePlayer()
        queuePlayer.actionAtItemEnd = .none
        let screenVolume = volume(for: screen)
        queuePlayer.isMuted = muted
        queuePlayer.volume = muted ? 0 : Float(screenVolume)
        // 本地文件设为 false：循环切换时不等待缓冲，立即切到下一副本，减少停顿感
        queuePlayer.automaticallyWaitsToMinimizeStalling = !videoURL.isFileURL
        queuePlayer.preventsDisplaySleepDuringVideoPlayback = false

        let looper = AVPlayerLooper(player: queuePlayer, templateItem: playerItem)
        queuePlayer.insert(playerItem, after: nil)

        return (queuePlayer, looper, playerItem)
    }

    private func createWindow(for screen: NSScreen, videoURL: URL, muted: Bool) throws {
        let screenID = screen.wallpaperScreenIdentifier
        let frame = screen.frame

        let window = WallpaperVideoWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.setFrame(frame, display: true)
        window.level = .init(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.isReleasedWhenClosed = false  // ⚠️ 防止 close() 时自动释放（由我们手动管理生命周期）
        window.ignoresMouseEvents = true
        window.isMovable = false

        let containerView = WallpaperVideoContainerView(frame: CGRect(origin: .zero, size: frame.size))
        containerView.autoresizingMask = [.width, .height]
        window.contentView = containerView

        // 统一使用 AVPlayerLooper 简单循环播放原视频，不做 crossfade composition。
        // 复杂的首尾帧 crossfade 渲染逻辑已保留在 makeLoopingCompositionItem / exportLoopedVideo 中，
        // 待后续增加用户手动开关后再决定是否恢复调用。
        let components = makePlayerComponents(for: screen, videoURL: videoURL, muted: muted)
        self.loopers[screenID] = components.looper

        containerView.playerLayer.player = components.player
        containerView.playerLayer.videoGravity = .resizeAspectFill
        
        // 应用噪点纹理叠加（桌面壁纸颗粒蒙层，由 Settings 开关独立控制）
        let grainEnabled = UserDefaults.standard.object(forKey: "grain_texture_enabled") as? Bool ?? true
        if grainEnabled {
            containerView.showGrainOverlay(intensity: ArcBackgroundSettings.shared.grainIntensity)
        }

        components.player.play()
        window.orderBack(nil)

        windows[screenID] = window
        players[screenID] = components.player
    }

    private func teardownAllWindows() {
        // 0. 取消上一次未执行的延迟释放，避免快速切换时多组 AVPlayer 并发驻留
        pendingPlayerCleanups.forEach { $0.cancel() }
        pendingPlayerCleanups.removeAll()
        pendingWindowCleanups.forEach { $0.cancel() }
        pendingWindowCleanups.removeAll()

        // 1. 先断开所有 playerLayer 与 player 的关联，避免渲染层持有已释放的 player
        for window in windows.values {
            if let contentView = window.contentView as? WallpaperVideoContainerView {
                contentView.playerLayer.player = nil
            }
        }

        // 2. 停止 looper
        for looper in loopers.values {
            looper.disableLooping()
        }
        loopers.removeAll()

        // 3. 暂停 player 并清空 items
        // ⚠️ 关键：不要立即释放 player！
        // macOS 26.5 beta 的 MediaToolbox 中 FigNotificationCenterRemoveWeakListener
        // 在后台线程异步清理 AVPlayerItem 的通知监听器，如果 player 在此期间被释放，
        // 后台线程访问已释放对象 → 主线程 autorelease pool drain 时 objc_release 已死对象 → SIGSEGV
        // 修复：先暂停+清空，然后延迟释放，让后台清理完成
        let playersToDelay = players.values.map { $0 }
        for player in playersToDelay {
            player.pause()
            player.removeAllItems()
        }
        players.removeAll()

        // 延迟释放 player，让 MediaToolbox 后台线程完成 FigNotificationCenter 清理
        let playerWork = DispatchWorkItem { _ = playersToDelay }
        pendingPlayerCleanups.append(playerWork)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: playerWork)

        // 4. 关闭窗口
        // ⚠️ macOS 26.5 beta 会为 orderOut/close 自动创建 _NSWindowTransformAnimation 退出动画
        // 这些动画对象被 autoreleased，如果窗口在动画完成前被释放 → 动画对象引用悬垂指针
        // → CA::Transaction::commit 时 autorelease pool drain → objc_release 已死对象 → SIGSEGV
        // 修复：先将窗口从屏幕移除 + 清空内容，然后延迟释放窗口（同 player 策略）
        let windowsToDelay = windows.values.map { $0 }
        for window in windowsToDelay {
            window.contentView = nil
            window.orderOut(nil)
        }
        windows.removeAll()

        // 延迟释放窗口，让 AppKit 的 _NSWindowTransformAnimation 退出动画完成
        let windowWork = DispatchWorkItem { _ = windowsToDelay }
        pendingWindowCleanups.append(windowWork)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: windowWork)
    }

    private func persistState() {
        guard let currentVideoURL else { return }

        let state = SavedVideoWallpaperState(
            fileURL: currentVideoURL.absoluteString,
            posterURL: currentPosterURL?.absoluteString,
            isMuted: isMuted,
            isPaused: isPaused,
            volume: volume,
            volumeByScreen: volumeByScreen.isEmpty ? nil : volumeByScreen,
            videoScreenIDs: videoTargetScreenIDs.isEmpty ? nil : videoTargetScreenIDs.sorted(),
            posterURLs: posterURLByScreen.isEmpty ? nil : posterURLByScreen.mapValues { $0.absoluteString }
        )

        if let encoded = try? JSONEncoder().encode(state) {
            defaults.set(encoded, forKey: stateKey)
        }
    }
    
    // MARK: - 预览图管理
    
    /// 显示预览图（用于锁屏或无权限时）
    private func showPosterImage(for screenID: String) {
        // 检查用户是否启用了此功能
        guard showPosterOnLock else { return }

        guard let posterURL = posterURLByScreen[screenID],
              let window = windows[screenID],
              let containerView = window.contentView as? WallpaperVideoContainerView else { return }
        
        // 如果已经显示了预览图，不再重复加载
        guard !containerView.isShowingPoster else { return }
        
        // 异步加载预览图
        Task {
            if let image = await loadPosterImage(from: posterURL) {
                await MainActor.run {
                    containerView.showPoster(image)
                }
            }
        }
    }
    
    /// 隐藏预览图
    private func hidePosterImage(for screenID: String) {
        guard let window = windows[screenID],
              let containerView = window.contentView as? WallpaperVideoContainerView else { return }
        
        containerView.hidePoster()
    }
    
    /// 从 URL 加载预览图
    private func loadPosterImage(from url: URL) async -> NSImage? {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return NSImage(data: data)
        } catch {
            print("[VideoWallpaperManager] Failed to load poster image: \(error)")
            return nil
        }
    }
}

private struct SavedVideoWallpaperState: Codable {
    let fileURL: String
    let posterURL: String?
    let isMuted: Bool
    let isPaused: Bool
    let volume: Double?
    /// 每个屏幕的独立音量；旧版持久化无此字段
    let volumeByScreen: [String: Double]?
    /// 应显示 MP4 的屏幕 ID；旧版持久化无此字段时表示「当时逻辑等价于全部屏幕」
    let videoScreenIDs: [String]?
    /// 每个屏幕的独立 poster；旧版持久化无此字段（兼容旧数据时回退到全局 posterURL）
    let posterURLs: [String: String]?

    // 兼容旧版解码（posterURLs 可能不存在）
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fileURL = try container.decode(String.self, forKey: .fileURL)
        posterURL = try container.decodeIfPresent(String.self, forKey: .posterURL)
        isMuted = try container.decode(Bool.self, forKey: .isMuted)
        isPaused = try container.decode(Bool.self, forKey: .isPaused)
        volume = try container.decodeIfPresent(Double.self, forKey: .volume)
        volumeByScreen = try container.decodeIfPresent([String: Double].self, forKey: .volumeByScreen)
        videoScreenIDs = try container.decodeIfPresent([String].self, forKey: .videoScreenIDs)
        posterURLs = try container.decodeIfPresent([String: String].self, forKey: .posterURLs)
    }

    init(
        fileURL: String,
        posterURL: String?,
        isMuted: Bool,
        isPaused: Bool,
        volume: Double?,
        volumeByScreen: [String: Double]?,
        videoScreenIDs: [String]?,
        posterURLs: [String: String]? = nil
    ) {
        self.fileURL = fileURL
        self.posterURL = posterURL
        self.isMuted = isMuted
        self.isPaused = isPaused
        self.volume = volume
        self.volumeByScreen = volumeByScreen
        self.videoScreenIDs = videoScreenIDs
        self.posterURLs = posterURLs
    }

    enum CodingKeys: String, CodingKey {
        case fileURL, posterURL, isMuted, isPaused, volume
        case volumeByScreen, videoScreenIDs, posterURLs
    }
}

/// v2: 单个屏幕的壁纸配置
private struct ScreenWallpaperConfig: Codable {
    let screenID: String
    let screenName: String
    let wallpaperURL: String
    let isMainScreen: Bool
}

/// v2: 保存的原始壁纸状态（支持多屏幕配置）
private struct SavedOriginalWallpaperState: Codable {
    let configs: [ScreenWallpaperConfig]
    let savedAt: Date
    let appVersion: String
}

private final class WallpaperVideoWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class WallpaperVideoContainerView: NSView {
    private var posterImageView: NSImageView?
    private var grainOverlayView: NSView?
    
    var isShowingPoster: Bool {
        posterImageView != nil
    }
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = AVPlayerLayer()
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.needsDisplayOnBoundsChange = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var playerLayer: AVPlayerLayer {
        guard let layer = layer as? AVPlayerLayer else {
            let replacementLayer = AVPlayerLayer()
            replacementLayer.videoGravity = .resizeAspectFill
            self.layer = replacementLayer
            return replacementLayer
        }
        return layer
    }
    
    /// 显示预览图（锁屏或无权限时使用）
    func showPoster(_ image: NSImage) {
        hidePoster()
        
        let imageView = NSImageView(frame: bounds)
        imageView.image = image
        imageView.imageScaling = .scaleAxesIndependently
        imageView.autoresizingMask = [.width, .height]
        addSubview(imageView)
        posterImageView = imageView
    }
    
    /// 隐藏预览图
    func hidePoster() {
        posterImageView?.removeFromSuperview()
        posterImageView = nil
    }
    
    /// 显示噪点纹理叠加（Arc 磨砂质感，平铺实现）
    func showGrainOverlay(intensity: Double) {
        hideGrainOverlay()
        guard intensity > 0.01 else { return }

        let overlayView = GrainPatternOverlayView(frame: bounds)
        overlayView.intensity = intensity
        overlayView.autoresizingMask = [.width, .height]
        addSubview(overlayView)
        grainOverlayView = overlayView
    }
    
    /// 隐藏噪点纹理
    func hideGrainOverlay() {
        grainOverlayView?.removeFromSuperview()
        grainOverlayView = nil
    }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
        posterImageView?.frame = bounds
        grainOverlayView?.frame = bounds
    }
}

/// 视频壁纸颗粒蒙层视图
///
/// NSWindow overlay：半透明黑色噪点 + 普通 alpha 混合。
private final class GrainPatternOverlayView: NSView {
    var intensity: Double = 0.5 {
        didSet { updateOpacity() }
    }

    private var grainImage: CGImage?
    private let tileSize = CGSize(width: 2048, height: 2048)

    override var isOpaque: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        if window != nil { setupGrain() }
    }

    private func setupGrain() {
        guard let layer = self.layer else { return }

        if grainImage == nil {
            grainImage = generateFilmGrainTexture(size: tileSize)
        }
        layer.contents = grainImage
        layer.contentsGravity = .resizeAspectFill
        updateOpacity()
    }

    private func updateOpacity() {
        layer?.opacity = Float(intensity * 0.10)
    }

    override func resize(withOldSuperviewSize oldSize: NSSize) {
        super.resize(withOldSuperviewSize: oldSize)
        layer?.frame = bounds
    }

    /// 生成暗色噪点纹理（黑色为主，用于 alpha 混合压暗）
    private func generateFilmGrainTexture(size: CGSize) -> CGImage? {
        guard size.width > 0, size.height > 0 else { return nil }

        let context = CIContext(options: [.workingColorSpace: NSNull()])

        // 1. 基础白噪声
        guard let noiseFilter = CIFilter(name: "CIRandomGenerator") else { return nil }
        let margin: CGFloat = 4
        let noiseSize = CGSize(width: size.width + margin * 2, height: size.height + margin * 2)
        let baseNoise = noiseFilter.outputImage?.cropped(to: CGRect(origin: .zero, size: noiseSize))
            ?? CIImage(color: CIColor(red: 0.0, green: 0.0, blue: 0.0))

        // 2. 柔化：0.6px 让单像素噪点变成有机颗粒簇
        guard let blurFilter = CIFilter(name: "CIGaussianBlur") else { return nil }
        blurFilter.setValue(baseNoise, forKey: kCIInputImageKey)
        blurFilter.setValue(0.6, forKey: kCIInputRadiusKey)
        let blurred = blurFilter.outputImage ?? baseNoise

        // 3. 颜色矩阵：映射到 0.0~0.15 暗色范围
        guard let matrixFilter = CIFilter(name: "CIColorMatrix") else { return nil }
        matrixFilter.setValue(blurred, forKey: kCIInputImageKey)
        matrixFilter.setValue(CIVector(x: 0.10, y: 0, z: 0, w: 0), forKey: "inputRVector")
        matrixFilter.setValue(CIVector(x: 0, y: 0.10, z: 0, w: 0), forKey: "inputGVector")
        matrixFilter.setValue(CIVector(x: 0, y: 0, z: 0.10, w: 0), forKey: "inputBVector")
        matrixFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
        matrixFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputBiasVector")
        let grain = matrixFilter.outputImage ?? blurred

        let final = grain.cropped(to: CGRect(origin: CGPoint(x: margin, y: margin), size: size))
        return context.createCGImage(final, from: final.extent)
    }
}



// MARK: - NSWorkspace 扩展：设置壁纸到所有 Spaces

extension NSWorkspace {
    /// 设置桌面壁纸到指定屏幕的**所有 Spaces**（而不仅是当前 active Space）。
    /// 这是 `setDesktopImageURL(_:for:options:)` 的包装，自动注入半私有的 `allSpaces` 选项，
    /// 并通过 DistributedNotificationCenter 触发系统壁纸刷新，使已有 Spaces 也能同步更新。
    func setDesktopImageURLForAllSpaces(_ url: URL, for screen: NSScreen, options: [DesktopImageOptionKey: Any] = [:]) throws {
        var merged = options
        merged[DesktopImageOptionKey(rawValue: "allSpaces")] = NSNumber(value: true)
        try setDesktopImageURL(url, for: screen, options: merged)

        // 触发系统桌面壁纸刷新通知，促使所有已有 Spaces 同步新壁纸
        // 同时帮助状态栏根据新壁纸重新计算深色/浅色外观
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("com.apple.desktop"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }
}


// MARK: - Video Loop Preprocessing Service

/// 负责视频壁纸的离线 crossfade 预处理。
/// 只在用户**设置壁纸时**触发，不会在下载时自动处理，也不做批量扫描。
/// 处理完成后直接替换原始文件，并在对应下载记录中标记 `isLooped = true`。
@MainActor
final class VideoLoopPreprocessingService: ObservableObject {
    static let shared = VideoLoopPreprocessingService()

    @Published private(set) var isProcessing = false
    @Published private(set) var currentProcessingFile: String?

    private let tempDirectory: URL

    private init() {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WaifuXLoopExport", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Query

    /// 通过下载记录判断指定路径的视频是否已做 loop 预处理
    func isProcessed(_ fileURL: URL) -> Bool {
        let path = fileURL.path
        if let record = WallpaperLibraryService.shared.downloadRecord(forLocalFilePath: path) {
            return record.isLooped == true
        }
        if let record = MediaLibraryService.shared.downloadRecord(forLocalFilePath: path) {
            return record.isLooped == true
        }
        return false
    }

    // MARK: - Preprocessing

    /// 异步预处理指定视频。如果已处理则直接返回。
    /// 处理完成后替换原始文件，并更新对应下载记录的 `isLooped` 标记。
    func preprocessIfNeeded(_ originalURL: URL) async {
        guard !isProcessed(originalURL) else { return }

        isProcessing = true
        currentProcessingFile = originalURL.lastPathComponent
        defer {
            isProcessing = false
            currentProcessingFile = nil
        }

        do {
            let tempURL = tempDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
            try await exportLoopedVideo(from: originalURL, to: tempURL)

            guard FileManager.default.fileExists(atPath: tempURL.path) else {
                throw NSError(domain: "VideoLoop", code: 6, userInfo: [NSLocalizedDescriptionKey: "Exported file not found"])
            }

            // 原子替换原始文件
            _ = try FileManager.default.replaceItemAt(originalURL, withItemAt: tempURL)

            // 更新下载记录标记
            let path = originalURL.path
            WallpaperLibraryService.shared.markAsLooped(localFilePath: path)
            MediaLibraryService.shared.markAsLooped(localFilePath: path)

            print("[VideoLoopPreprocessing] Replaced original with looped version: \(originalURL.lastPathComponent)")
        } catch {
            print("[VideoLoopPreprocessing] Failed for \(originalURL.lastPathComponent): \(error)")
            let tempURL = tempDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
            try? FileManager.default.removeItem(at: tempURL)
        }
    }

    // MARK: - Export

    private func exportLoopedVideo(from originalURL: URL, to outputURL: URL) async throws {
        let asset = AVURLAsset(url: originalURL)
        let duration = try await asset.load(.duration)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)

        guard let videoTrack = videoTracks.first else {
            throw NSError(domain: "VideoLoop", code: 1, userInfo: [NSLocalizedDescriptionKey: "No video track"])
        }

        let fadeDuration: Double = 1.0
        let fadeCMTime = CMTime(seconds: fadeDuration, preferredTimescale: 600)

        // 视频太短不做 crossfade，直接复制原文件
        guard duration > CMTimeMultiply(fadeCMTime, multiplier: 2) else {
            try? FileManager.default.copyItem(at: originalURL, to: outputURL)
            return
        }

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let composition = AVMutableComposition()

        // Track 1: 原视频完整播放（底层）
        guard let track1 = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw NSError(domain: "VideoLoop", code: 2)
        }
        try track1.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: videoTrack, at: .zero)

        // Track 2: 原视频开头 fadeDuration 秒，插入到 (duration - fadeDuration) 处（上层）
        guard let track2 = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw NSError(domain: "VideoLoop", code: 3)
        }
        let track2InsertTime = duration - fadeCMTime
        try track2.insertTimeRange(CMTimeRange(start: .zero, duration: fadeCMTime), of: videoTrack, at: track2InsertTime)

        // 音频：简单复制完整音频
        if let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first,
           let compositionAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try? compositionAudioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: audioTrack, at: .zero)
        }

        // Video composition: opacity ramps
        let naturalSize = try await videoTrack.load(.naturalSize)
        let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
        let frameRate = nominalFrameRate > 0 ? nominalFrameRate : 30

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = naturalSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)

        let layerInstruction1 = AVMutableVideoCompositionLayerInstruction(assetTrack: track1)
        let layerInstruction2 = AVMutableVideoCompositionLayerInstruction(assetTrack: track2)

        let fadeStart = duration - fadeCMTime
        layerInstruction1.setOpacityRamp(
            fromStartOpacity: 1.0, toEndOpacity: 0.0,
            timeRange: CMTimeRange(start: fadeStart, duration: fadeCMTime)
        )
        layerInstruction2.setOpacityRamp(
            fromStartOpacity: 0.0, toEndOpacity: 1.0,
            timeRange: CMTimeRange(start: fadeStart, duration: fadeCMTime)
        )

        instruction.layerInstructions = [layerInstruction1, layerInstruction2]
        videoComposition.instructions = [instruction]

        guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw NSError(domain: "VideoLoop", code: 4, userInfo: [NSLocalizedDescriptionKey: "Export session creation failed"])
        }

        exportSession.videoComposition = videoComposition
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        exportSession.shouldOptimizeForNetworkUse = false

        await exportSession.export()

        if let error = exportSession.error {
            throw error
        }
        guard exportSession.status == .completed else {
            throw NSError(domain: "VideoLoop", code: 5, userInfo: [NSLocalizedDescriptionKey: "Export status: \(exportSession.status.rawValue)"])
        }
    }
}
