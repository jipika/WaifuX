import Foundation
import AppKit
import AVFoundation
import CoreGraphics

@MainActor
final class VideoWallpaperManager: ObservableObject {
    static let shared = VideoWallpaperManager()

    @Published private(set) var currentVideoURL: URL?
    @Published private(set) var currentPosterURL: URL?
    @Published private(set) var isMuted = true
    @Published private(set) var isPaused = false

    private var windows: [String: WallpaperVideoWindow] = [:]
    private var players: [String: AVQueuePlayer] = [:]
    private var loopers: [String: AVPlayerLooper] = [:]

    /// 应挂载 MP4 壁纸层的屏幕 ID（`NSScreen.wallpaperScreenIdentifier`）。唤醒 / 分辨率变化时全局 `rebuildWindows()` 只重建这些屏，避免「只设一块屏动态」却给所有显示器都建了视频窗。
    private var videoTargetScreenIDs = Set<String>()

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
    
    /// 当前持久化的预览图路径
    private var persistedPosterURL: URL? {
        guard let posterURL = currentPosterURL else { return nil }
        let fileName = "poster_\(posterURL.lastPathComponent)"
        return persistedPosterDirectory.appendingPathComponent(fileName)
    }
    
    /// 是否在锁屏时显示预览图
    var showPosterOnLock: Bool {
        get { defaults.bool(forKey: showPosterOnLockKey) }
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
        if let posterURL = posterURL {
            setPosterAsDesktopWallpaper(posterURL, targetScreen: targetScreen)
        }
        
        currentVideoURL = localFileURL
        currentPosterURL = posterURL
        isMuted = muted
        isPaused = false

        try rebuildWindows(targetScreen: targetScreen)
        persistState()
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        for player in players.values {
            player.isMuted = muted
            player.volume = muted ? 0 : 1
        }
        persistState()
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
    
    private var isScreenLocked = false
    
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

    func stopWallpaper() {
        WallpaperEngineXBridge.shared.ensureStoppedForNonCLIWallpaper()

        teardownAllWindows()
        currentVideoURL = nil
        currentPosterURL = nil
        isPaused = false
        videoTargetScreenIDs = []
        // 不删除保存的状态，以便下次可以恢复

        // 恢复用户原始桌面壁纸
        restoreOriginalWallpaper()
    }

    /// 仅拆掉本机 AVPlayer 视频壁纸，**不**调用 `WallpaperEngineXBridge.stopWallpaper()`。
    /// 在即将通过 CLI 设置 scene / web 等 WE 壁纸前调用，否则会误停 CLI 且把 `isControllingExternalEngine` 清掉，菜单栏暂停恢复会走错视频分支。
    func stopNativeVideoWallpaperOnly() {
        teardownAllWindows()
        currentVideoURL = nil
        currentPosterURL = nil
        isPaused = false
        videoTargetScreenIDs = []
        defaults.removeObject(forKey: stateKey)
        restoreOriginalWallpaper()
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
    
    /// 将预览图设为桌面壁纸（锁屏会显示这个）
    /// 使用持久化存储，避免被系统清理
    private func setPosterAsDesktopWallpaper(_ posterURL: URL, targetScreen: NSScreen? = nil) {
        let workspace = NSWorkspace.shared
        
        Task { @MainActor in
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
                let persistentURL = persistedPosterDirectory
                    .appendingPathComponent("poster_\(posterURL.lastPathComponent)")
                
                // 清理旧的预览图文件（保留最近5个）
                await cleanupOldPosters(keeping: persistentURL)
                
                try data.write(to: persistentURL)
                print("[VideoWallpaperManager] Saved poster to persistent location: \(persistentURL.path)")
                
                // 3. 设置为桌面壁纸
                let screensToSet: [NSScreen]
                if let targetScreen = targetScreen {
                    screensToSet = [targetScreen]
                } else {
                    screensToSet = NSScreen.screens
                }
                
                for screen in screensToSet {
                    try workspace.setDesktopImageURL(persistentURL, for: screen, options: [:])
                }
                print("[VideoWallpaperManager] Set poster as desktop wallpaper for \(screensToSet.count) screen(s)")
            } catch {
                print("[VideoWallpaperManager] Failed to set poster: \(error)")
            }
        }
    }
    
    /// 清理旧的预览图文件，只保留最近的几个
    private func cleanupOldPosters(keeping keepURL: URL) async {
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
                    try workspace.setDesktopImageURL(originalURL, for: screen, options: [:])
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
                    try workspace.setDesktopImageURL(mainURL, for: screen, options: [:])
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
                            try workspace.setDesktopImageURL(url, for: screen, options: [:])
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

        // 恢复预览图 URL
        let posterURL = savedState.posterURL.flatMap { URL(string: $0) }

        do {
            if let ids = savedState.videoScreenIDs, !ids.isEmpty {
                if currentVideoURL == nil {
                    saveOriginalWallpaper()
                }
                currentVideoURL = url
                currentPosterURL = posterURL
                isMuted = savedState.isMuted
                isPaused = false
                videoTargetScreenIDs = Set(ids)
                if let posterURL {
                    for screen in screensForVideoWallpaperTargets() {
                        setPosterAsDesktopWallpaper(posterURL, targetScreen: screen)
                    }
                }
                try rebuildWindows()
                if savedState.isPaused {
                    pauseWallpaper()
                }
                persistState()
            } else {
                try applyVideoWallpaper(from: url, posterURL: posterURL, muted: savedState.isMuted)
                if savedState.isPaused {
                    pauseWallpaper()
                }
            }
        } catch {
            defaults.removeObject(forKey: stateKey)
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
        
        // 如果只更新特定屏幕，不要 teardown 所有窗口
        if targetScreen == nil {
            teardownAllWindows()
        } else {
            // 只移除目标屏幕的窗口
            guard let targetScreen = targetScreen else { return }
            let targetScreenID = targetScreen.wallpaperScreenIdentifier
            if let window = windows[targetScreenID] {
                if let contentView = window.contentView as? WallpaperVideoContainerView {
                    contentView.playerLayer.player = nil
                }
                // ⚠️ 用 orderOut 替代 close()，避免 macOS 26.5 的 _NSWindowTransformAnimation 崩溃
                // close() 可能触发窗口退出动画，动画对象引用可能在窗口释放后成为悬垂指针
                window.contentView = nil
                window.orderOut(nil)
                windows.removeValue(forKey: targetScreenID)
                // 延迟释放窗口，让退出动画完成
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    _ = window
                }
            }
            if let player = players[targetScreenID] {
                player.pause()
                player.removeAllItems()
                players.removeValue(forKey: targetScreenID)
                // 延迟释放 player（同 teardownAllWindows 的修复）
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    _ = player
                }
            }
            if let looper = loopers[targetScreenID] {
                looper.disableLooping()
                loopers.removeValue(forKey: targetScreenID)
            }
        }

        for screen in screensToRebuild {
            try createWindow(for: screen, videoURL: currentVideoURL, muted: isMuted)
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

        let playerItem = AVPlayerItem(url: videoURL)
        
        // 配置高质量播放设置
        // 1. 不限制码率，使用视频原始码率
        playerItem.preferredPeakBitRate = 0
        
        // 2. 启用 HDR 元数据（如果视频支持）
        if #available(macOS 10.15, *) {
            playerItem.appliesPerFrameHDRDisplayMetadata = true
        }
        
        // 3. 设置首选渲染尺寸为屏幕尺寸，避免降采样
        let screenSize = screen.frame.size
        playerItem.preferredMaximumResolution = CGSize(
            width: screenSize.width * screen.backingScaleFactor,
            height: screenSize.height * screen.backingScaleFactor
        )
        
        let queuePlayer = AVQueuePlayer()
        queuePlayer.actionAtItemEnd = .none
        queuePlayer.isMuted = muted
        queuePlayer.volume = muted ? 0 : 1
        queuePlayer.automaticallyWaitsToMinimizeStalling = false
        queuePlayer.preventsDisplaySleepDuringVideoPlayback = false
        
        // 4. 设置更高的视频输出质量
        if #available(macOS 10.15, *) {
            queuePlayer.currentItem?.seekingWaitsForVideoCompositionRendering = true
        }

        let looper = AVPlayerLooper(player: queuePlayer, templateItem: playerItem)
        containerView.playerLayer.player = queuePlayer
        containerView.playerLayer.videoGravity = .resizeAspectFill

        queuePlayer.play()
        window.orderBack(nil)

        windows[screenID] = window
        players[screenID] = queuePlayer
        self.loopers[screenID] = looper
    }

    private func teardownAllWindows() {
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            // playersToDelay 被闭包捕获，在此延迟后才释放
            // 此时 MediaToolbox 后台的 FigNotificationCenterRemoveWeakListener 应已完成
            _ = playersToDelay
        }

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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            // windowsToDelay 被闭包捕获，在此延迟后才由 ARC 释放
            // 此时 AppKit 的窗口退出动画应已完成
            _ = windowsToDelay
        }
    }

    private func persistState() {
        guard let currentVideoURL else { return }

        let state = SavedVideoWallpaperState(
            fileURL: currentVideoURL.absoluteString,
            posterURL: currentPosterURL?.absoluteString,
            isMuted: isMuted,
            isPaused: isPaused,
            videoScreenIDs: videoTargetScreenIDs.isEmpty ? nil : videoTargetScreenIDs.sorted()
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
        
        guard let posterURL = currentPosterURL,
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
    /// 应显示 MP4 的屏幕 ID；旧版持久化无此字段时表示「当时逻辑等价于全部屏幕」
    let videoScreenIDs: [String]?
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

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
        posterImageView?.frame = bounds
    }
}

private extension NSScreen {
    var wallpaperScreenIdentifier: String {
        if let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return screenNumber.stringValue
        }
        return localizedName + ":\(frame.origin.x):\(frame.origin.y)"
    }
}
