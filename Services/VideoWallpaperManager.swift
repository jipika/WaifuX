import Foundation
import AppKit
import AVFoundation
import CoreGraphics

@MainActor
final class VideoWallpaperManager: ObservableObject {
    static let shared = VideoWallpaperManager()

    /// 记录最近一次成功挂载视频壁纸时的目标显示器配置。
    /// 某些窗口激活/隐藏路径会误触发 `didChangeScreenParametersNotification`，
    /// 但桌面显示器的实际 frame / scale 并没有变化；这类通知不应重建播放器。
    private struct ScreenConfigurationSignature: Equatable {
        let screenID: String
        let originX: Int
        let originY: Int
        let width: Int
        let height: Int
        let scale: Int

        init(screen: NSScreen) {
            let frame = screen.frame
            self.screenID = screen.wallpaperScreenIdentifier
            self.originX = Self.quantize(frame.origin.x)
            self.originY = Self.quantize(frame.origin.y)
            self.width = Self.quantize(frame.width)
            self.height = Self.quantize(frame.height)
            self.scale = Self.quantize(screen.backingScaleFactor)
        }

        private static func quantize(_ value: CGFloat) -> Int {
            Int((value * 1000).rounded())
        }
    }

    @Published private(set) var currentVideoURL: URL?
    /// 是否有任何屏幕正在播放视频壁纸（外部使用）
    var isVideoWallpaperActive: Bool {
        !videoURLByScreen.isEmpty || !videoURLByScreenFingerprint.isEmpty
    }
    /// 已废弃：多屏场景下请使用 `posterURL(for:)` 获取指定屏幕的 poster
    @Published private(set) var currentPosterURL: URL?
    @Published private(set) var isMuted = true
    @Published private(set) var isPaused = false
    @Published private(set) var volume: Double = 1.0

    /// 每个屏幕的独立 poster（key 为 screenID），解决多屏自动更换时 poster 被覆盖的问题
    private var posterURLByScreen: [String: URL] = [:]
    /// 同一 poster 的物理显示器指纹索引，用于外接屏重连后 screenID 变化时恢复。
    private var posterURLByScreenFingerprint: [String: URL] = [:]
    /// 每个屏幕独立的视频文件路径；解决多屏分别设置不同视频后重启只能恢复最后一块屏的问题。
    private var videoURLByScreen: [String: URL] = [:]
    /// 每个物理显示器对应的视频文件路径，用于 screenID 变化后的恢复。
    private var videoURLByScreenFingerprint: [String: URL] = [:]
    /// 每个屏幕独立的 poster 设置任务，避免一块屏的新任务取消掉另一块屏的恢复。
    private var posterTasks: [String: Task<Void, Never>] = [:]
    /// 每个屏幕的独立音量（key 为 screenID），未设置时回退到全局 `volume`
    private var volumeByScreen: [String: Double] = [:]
    /// 音量的物理显示器指纹索引，用于 screenID 变化后的恢复。
    private var volumeByScreenFingerprint: [String: Double] = [:]

    private var windows: [String: WallpaperVideoWindow] = [:]
    private var players: [String: AVQueuePlayer] = [:]
    private var loopers: [String: AVPlayerLooper] = [:]
    /// 延迟释放的工作项，用于取消上一次未执行的清理，避免快速切换时多组 AVPlayer 并发驻留
    private var pendingPlayerCleanups: [DispatchWorkItem] = []
    private var pendingWindowCleanups: [DispatchWorkItem] = []
    /// 启动时等待视频首帧就绪的 KVO 观察器（key: screenID）
    private var playerItemObservers: [String: NSKeyValueObservation] = [:]
    /// 启动淡入超时工作项（key: screenID）
    private var fadeInTimeouts: [String: DispatchWorkItem] = [:]

    /// 应挂载 MP4 壁纸层的屏幕 ID（`NSScreen.wallpaperScreenIdentifier`）。唤醒 / 分辨率变化时全局 `rebuildWindows()` 只重建这些屏，避免「只设一块屏动态」却给所有显示器都建了视频窗。
    private var videoTargetScreenIDs = Set<String>()
    /// 应挂载 MP4 壁纸层的物理显示器指纹。不要在显示器断开时清理，重连后靠它找回目标屏。
    private var videoTargetScreenFingerprints = Set<String>()
    
    /// 用于 poster 文件名的交替槽位，避免 macOS 桌面壁纸缓存旧图
    private var posterSlot = 0

    private let defaults = UserDefaults.standard
    private let stateKey = "video_wallpaper_state_v1"
    private let originalWallpaperKey = "video_wallpaper_original_desktop_v2"  // 旧版原始壁纸快照 key，仅用于清理遗留数据
    
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
        posterURLByScreen[screen.wallpaperScreenIdentifier] ?? posterURLByScreenFingerprint[screen.wallpaperScreenFingerprint]
    }

    /// 获取指定屏幕应播放的视频 URL。
    private func videoURL(for screen: NSScreen) -> URL? {
        videoURLByScreen[screen.wallpaperScreenIdentifier] ??
        videoURLByScreenFingerprint[screen.wallpaperScreenFingerprint] ??
        currentVideoURL
    }

    /// 是否有任何屏幕正在运行视频壁纸（内部 guard 使用，不依赖全局单例）
    private var hasActiveVideoWallpaper: Bool {
        !videoURLByScreen.isEmpty || !videoURLByScreenFingerprint.isEmpty
    }

    /// 将 `currentVideoURL` 与每屏视频状态同步，
    /// 确保 UI 层通过 `@Published` 观察到的值与实际状态一致。
    private func syncCurrentVideoURL() {
        if videoURLByScreen.isEmpty && videoURLByScreenFingerprint.isEmpty {
            currentVideoURL = nil
        } else {
            currentVideoURL = videoURLByScreen.values.first ?? videoURLByScreenFingerprint.values.first
        }
    }

    /// 当前持久化的预览图路径（兼容旧代码，返回第一个找到的 poster）
    private var persistedPosterURL: URL? {
        guard let posterURL = posterURLByScreen.values.first else { return nil }
        let fileName = "poster_\(posterURL.lastPathComponent)"
        return persistedPosterDirectory.appendingPathComponent(fileName)
    }
    
    // 防止重复重建（@MainActor 保证串行访问，无需 NSLock）
    private var isRebuilding = false
    private var pendingRebuildWorkItem: DispatchWorkItem?
    private var lastAppliedScreenConfigurations: [ScreenConfigurationSignature] = []

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

        // 系统休眠（合盖、Apple 菜单 > 睡眠）
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSystemWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSystemDidWake),
            name: NSWorkspace.didWakeNotification,
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
        let targetScreenID = targetScreen?.wallpaperScreenIdentifier
        let isSameVideoForTarget = targetScreen.flatMap { videoURL(for: $0) } == localFileURL

        if !isNewVideo,
           currentVideoURL == localFileURL,
           !windows.isEmpty,
           (targetScreen == nil || isSameVideoForTarget),
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
            DynamicWallpaperAutoPauseManager.shared.reevaluateCurrentState()
            return
        }

        if let targetScreen {
            videoTargetScreenIDs.insert(targetScreen.wallpaperScreenIdentifier)
            videoTargetScreenFingerprints.insert(targetScreen.wallpaperScreenFingerprint)
        } else {
            videoTargetScreenIDs = screenIDsNow
            videoTargetScreenFingerprints = Set(NSScreen.screens.map(\.wallpaperScreenFingerprint))
            videoURLByScreen.removeAll()
            videoURLByScreenFingerprint.removeAll()
        }

        discardOriginalWallpaperSnapshot()
        
        // 如果有预览图，设置为桌面壁纸（锁屏会显示这个）
        // 注意：此处 fire-and-forget，不阻塞主线程；poster 为 nil 时保持当前桌面不变。
        // 视频窗口会覆盖在桌面壁纸上方。
        if let posterURL = posterURL {
            setPosterAsDesktopWallpaper(posterURL, targetScreen: targetScreen)
        }

        currentVideoURL = localFileURL
        // 按屏幕记录 poster，防止多屏自动更换时互相覆盖
        if let targetScreen {
            posterURLByScreen[targetScreen.wallpaperScreenIdentifier] = posterURL
            posterURLByScreenFingerprint[targetScreen.wallpaperScreenFingerprint] = posterURL
            videoURLByScreen[targetScreen.wallpaperScreenIdentifier] = localFileURL
            videoURLByScreenFingerprint[targetScreen.wallpaperScreenFingerprint] = localFileURL
        } else {
            for screen in NSScreen.screens {
                posterURLByScreen[screen.wallpaperScreenIdentifier] = posterURL
                posterURLByScreenFingerprint[screen.wallpaperScreenFingerprint] = posterURL
                videoURLByScreen[screen.wallpaperScreenIdentifier] = localFileURL
                videoURLByScreenFingerprint[screen.wallpaperScreenFingerprint] = localFileURL
            }
        }
        currentPosterURL = posterURL  // 兼容旧代码
        isMuted = muted
        isPaused = false

        try rebuildWindows(targetScreen: targetScreenID.flatMap { id in
            NSScreen.screens.first { $0.wallpaperScreenIdentifier == id }
        })
        syncCurrentVideoURL()
        persistState()
        DynamicWallpaperAutoPauseManager.shared.reevaluateCurrentState()
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
            volumeByScreenFingerprint[targetScreen.wallpaperScreenFingerprint] = clamped
            players[screenID]?.volume = isMuted ? 0 : Float(clamped)
        } else {
            volume = clamped
            volumeByScreen.removeAll()
            volumeByScreenFingerprint.removeAll()
            for player in players.values {
                player.volume = isMuted ? 0 : Float(clamped)
            }
        }
        persistState()
    }

    /// 获取指定屏幕的音量（优先使用独立设置，否则回退全局）
    func volume(for screen: NSScreen) -> Double {
        let screenID = screen.wallpaperScreenIdentifier
        return volumeByScreen[screenID] ?? volumeByScreenFingerprint[screen.wallpaperScreenFingerprint] ?? volume
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
        guard hasActiveVideoWallpaper else { return }
        
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

    /// 当前仍在输出帧的屏幕集合；已被暂停（rate == 0）的屏幕不包含在内。
    var playingScreenIDs: Set<String> {
        Set(players.compactMap { screenID, player in
            player.rate != 0 ? screenID : nil
        })
    }
    
    /// 检测指定屏幕是否有正在播放的动态壁纸
    func hasActiveWallpaper(on screen: NSScreen) -> Bool {
        let screenID = screen.wallpaperScreenIdentifier
        return players[screenID] != nil
    }

    /// 检测指定屏幕当前是否处于暂停状态。
    func isPaused(on screen: NSScreen) -> Bool {
        let screenID = screen.wallpaperScreenIdentifier
        guard let player = players[screenID] else { return true }
        return player.rate == 0
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

            teardownAllWindows()
            currentVideoURL = nil
            currentPosterURL = nil
            posterURLByScreen.removeAll()
            posterURLByScreenFingerprint.removeAll()
            videoURLByScreen.removeAll()
            videoURLByScreenFingerprint.removeAll()
            isPaused = false
            videoTargetScreenIDs = []
            videoTargetScreenFingerprints = []
            discardOriginalWallpaperSnapshot()
            syncCurrentVideoURL()
            // 不删除保存的状态，以便下次可以恢复
            return
        }

        // 单屏停止：只拆掉该屏幕的视频层，不回退到旧静态壁纸
        let screenID = targetScreen.wallpaperScreenIdentifier
        let screenFingerprint = targetScreen.wallpaperScreenFingerprint
        guard windows[screenID] != nil || players[screenID] != nil else {
            // 该屏幕没有视频壁纸在播放，无需操作
            return
        }

        teardownWindow(for: screenID)
        videoTargetScreenIDs.remove(screenID)
        videoTargetScreenFingerprints.remove(screenFingerprint)
        posterURLByScreen.removeValue(forKey: screenID)
        posterURLByScreenFingerprint.removeValue(forKey: screenFingerprint)
        videoURLByScreen.removeValue(forKey: screenID)
        videoURLByScreenFingerprint.removeValue(forKey: screenFingerprint)
        discardOriginalWallpaperSnapshot()

        if players.isEmpty {
            currentVideoURL = nil
            currentPosterURL = nil
            posterURLByScreen.removeAll()
            posterURLByScreenFingerprint.removeAll()
            videoURLByScreen.removeAll()
            videoURLByScreenFingerprint.removeAll()
            isPaused = false
            videoTargetScreenIDs = []
            videoTargetScreenFingerprints = []
            WallpaperEngineXBridge.shared.ensureStoppedForNonCLIWallpaper()
        } else {
            lastAppliedScreenConfigurations = currentTargetScreenConfigurations()
        }
        syncCurrentVideoURL()
    }

    /// 应用退出前调用：只清理视频窗口和播放器，不回退到旧静态壁纸。
    /// 与 `stopWallpaper()` 不同，此方法不清理保存的状态（`stateKey`），下次启动仍可恢复视频壁纸。
    func prepareForAppTermination() {
        guard hasActiveVideoWallpaper else { return }

        discardOriginalWallpaperSnapshot()
        posterTasks.values.forEach { $0.cancel() }
        posterTasks.removeAll()

        // 退出前为每个目标屏幕持久化其 poster，确保拆掉视频窗口后
        // 每块屏的桌面壁纸（含锁屏底图）仍显示各自对应的 poster，而不是所有屏同步为主屏。
        for screen in screensForVideoWallpaperTargets() {
            if let posterURL = posterURL(for: screen) {
                applyPosterAsDesktopWallpaperSync(posterURL, targetScreen: screen)
                DesktopWallpaperSyncManager.shared.registerWallpaperSet(posterURL, for: screen)
            }
        }

        // 同步清理窗口和播放器（应用即将退出，不需要延迟释放）
        pendingPlayerCleanups.forEach { $0.cancel() }
        pendingPlayerCleanups.removeAll()
        pendingWindowCleanups.forEach { $0.cancel() }
        pendingWindowCleanups.removeAll()
        // 清理启动淡入相关的 observer 和 timeout
        playerItemObservers.values.forEach { $0.invalidate() }
        playerItemObservers.removeAll()
        fadeInTimeouts.values.forEach { $0.cancel() }
        fadeInTimeouts.removeAll()

        for window in windows.values {
            if let contentView = window.contentView as? WallpaperVideoContainerView {
                contentView.playerLayer.player = nil
            }
            window.contentView = nil
            window.orderOut(nil)
        }
        for looper in loopers.values {
            looper.disableLooping()
        }
        for player in players.values {
            player.pause()
            player.removeAllItems()
        }
        windows.removeAll()
        players.removeAll()
        loopers.removeAll()
        lastAppliedScreenConfigurations.removeAll()
    }

    /// 仅拆掉本机 AVPlayer 视频壁纸，**不**调用 `WallpaperEngineXBridge.stopWallpaper()`。
    /// 在即将通过 CLI 设置 scene / web 等 WE 壁纸前调用，否则会误停 CLI 且把 `isControllingExternalEngine` 清掉，菜单栏暂停恢复会走错视频分支。
    func stopNativeVideoWallpaperOnly(for targetScreen: NSScreen? = nil) {
        guard let targetScreen = targetScreen else {
            // 全局停止（原有逻辑）
            teardownAllWindows()
            currentVideoURL = nil
            currentPosterURL = nil
            posterURLByScreen.removeAll()
            posterURLByScreenFingerprint.removeAll()
            videoURLByScreen.removeAll()
            videoURLByScreenFingerprint.removeAll()
            isPaused = false
            videoTargetScreenIDs = []
            videoTargetScreenFingerprints = []
            discardOriginalWallpaperSnapshot()
            defaults.removeObject(forKey: stateKey)
            syncCurrentVideoURL()
            return
        }

        // 单屏停止：只拆掉该屏幕的视频层，不回退到旧静态壁纸
        let screenID = targetScreen.wallpaperScreenIdentifier
        let screenFingerprint = targetScreen.wallpaperScreenFingerprint
        guard windows[screenID] != nil || players[screenID] != nil else {
            // 该屏幕没有视频壁纸在播放，无需操作（避免自动切换时误恢复旧壁纸导致闪烁）
            return
        }

        teardownWindow(for: screenID)
        videoTargetScreenIDs.remove(screenID)
        videoTargetScreenFingerprints.remove(screenFingerprint)
        posterURLByScreen.removeValue(forKey: screenID)
        posterURLByScreenFingerprint.removeValue(forKey: screenFingerprint)
        videoURLByScreen.removeValue(forKey: screenID)
        videoURLByScreenFingerprint.removeValue(forKey: screenFingerprint)
        discardOriginalWallpaperSnapshot()

        if players.isEmpty {
            currentVideoURL = nil
            currentPosterURL = nil
            posterURLByScreen.removeAll()
            posterURLByScreenFingerprint.removeAll()
            videoURLByScreen.removeAll()
            videoURLByScreenFingerprint.removeAll()
            isPaused = false
            videoTargetScreenIDs = []
            videoTargetScreenFingerprints = []
            defaults.removeObject(forKey: stateKey)
        } else {
            lastAppliedScreenConfigurations = currentTargetScreenConfigurations()
        }
        syncCurrentVideoURL()
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
        playerItemObservers[screenID]?.invalidate()
        playerItemObservers.removeValue(forKey: screenID)
        fadeInTimeouts[screenID]?.cancel()
        fadeInTimeouts.removeValue(forKey: screenID)
    }
    
    // MARK: - 锁屏壁纸管理

    private func discardOriginalWallpaperSnapshot() {
        defaults.removeObject(forKey: originalWallpaperKey)
    }
    
    /// 将预览图设为桌面壁纸，同时显式写入锁屏壁纸。
    /// 使用持久化存储，避免被系统清理。
    /// - Note: 如需同步等待完成，请直接调用 `applyPosterAsDesktopWallpaper`；此方法内部 fire-and-forget。
    private func setPosterAsDesktopWallpaper(_ posterURL: URL, targetScreen: NSScreen? = nil) {
        let targetScreens = targetScreen.map { [$0] } ?? NSScreen.screens
        for screen in targetScreens {
            let screenID = screen.wallpaperScreenIdentifier
            posterTasks[screenID]?.cancel()
            posterTasks[screenID] = Task { @MainActor [weak self] in
                await self?.applyPosterAsDesktopWallpaper(posterURL, targetScreen: screen)
                self?.posterTasks.removeValue(forKey: screenID)
            }
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
        let restoredPosterURLsByFingerprint = savedState.posterURLsByFingerprint?.compactMapValues { URL(string: $0) } ?? [:]
        let restoredVideoURLs = savedState.videoURLs?.compactMapValues { URL(string: $0) } ?? [:]
        let restoredVideoURLsByFingerprint = savedState.videoURLsByFingerprint?.compactMapValues { URL(string: $0) } ?? [:]
        posterURLByScreen = restoredPosterURLs
        posterURLByScreenFingerprint = restoredPosterURLsByFingerprint
        videoURLByScreen = restoredVideoURLs
        videoURLByScreenFingerprint = restoredVideoURLsByFingerprint
        // 兼容旧数据：如果 per-screen 为空但有全局 poster，平铺到所有目标屏
        if posterURLByScreen.isEmpty, let globalPosterURL, let ids = savedState.videoScreenIDs {
            for screenID in ids {
                posterURLByScreen[screenID] = globalPosterURL
            }
        }
        if posterURLByScreenFingerprint.isEmpty, let globalPosterURL, let fingerprints = savedState.videoScreenFingerprints {
            for fingerprint in fingerprints {
                posterURLByScreenFingerprint[fingerprint] = globalPosterURL
            }
        }
        if videoURLByScreen.isEmpty, let ids = savedState.videoScreenIDs {
            for screenID in ids {
                videoURLByScreen[screenID] = url
            }
        }
        if videoURLByScreenFingerprint.isEmpty, let fingerprints = savedState.videoScreenFingerprints {
            for fingerprint in fingerprints {
                videoURLByScreenFingerprint[fingerprint] = url
            }
        }

        do {
            if savedState.hasExplicitScreenTargets {
                discardOriginalWallpaperSnapshot()
                syncCurrentVideoURL()
                currentPosterURL = globalPosterURL  // 兼容旧代码
                isMuted = savedState.isMuted
                volume = savedState.volume ?? (savedState.isMuted ? 0 : 1)
                volumeByScreen = savedState.volumeByScreen ?? [:]
                volumeByScreenFingerprint = savedState.volumeByScreenFingerprint ?? [:]
                isPaused = false
                videoTargetScreenIDs = Set(savedState.videoScreenIDs ?? [])
                videoTargetScreenFingerprints = Set(savedState.videoScreenFingerprints ?? [])
                // 恢复场景下异步设置 poster，不阻塞主线程；视频窗口会覆盖在 poster 上方
                for screen in screensForVideoWallpaperTargets() {
                    if let posterURL = posterURL(for: screen) {
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
                volumeByScreenFingerprint = savedState.volumeByScreenFingerprint ?? [:]
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
                volumeByScreenFingerprint: savedState.volumeByScreenFingerprint,
                videoScreenIDs: savedState.videoScreenIDs,
                videoScreenFingerprints: savedState.videoScreenFingerprints,
                videoURLs: savedState.videoURLs?.mapValues { url in
                    url.hasPrefix(oldPrefix) ? newPrefix + String(url.dropFirst(oldPrefix.count)) : url
                },
                videoURLsByFingerprint: savedState.videoURLsByFingerprint?.mapValues { url in
                    url.hasPrefix(oldPrefix) ? newPrefix + String(url.dropFirst(oldPrefix.count)) : url
                },
                posterURLs: savedState.posterURLs?.mapValues { url in
                    url.hasPrefix(oldPrefix) ? newPrefix + String(url.dropFirst(oldPrefix.count)) : url
                },
                posterURLsByFingerprint: savedState.posterURLsByFingerprint?.mapValues { url in
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
            guard self.hasActiveVideoWallpaper else { return }
            
            // 防抖：延迟 300ms 执行，避免屏幕参数变化时的频繁重建
            self.pendingRebuildWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self, self.hasActiveVideoWallpaper else { return }

                self.relinkDisplayStateForCurrentScreens()

                guard self.hasEffectiveTargetDisplayChange() else {
                    NSLog("[VideoWallpaperManager] Ignored screen parameter notification because target display configuration is unchanged")
                    return
                }

                do {
                    try self.rebuildWindows()
                } catch {
                    NSLog("[VideoWallpaperManager] Failed to rebuild windows: \(error.localizedDescription)")
                }
            }
            self.pendingRebuildWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: workItem)
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
                if self.hasActiveVideoWallpaper, self.windows.isEmpty {
                    try? self.rebuildWindows()
                }
                // 只有非手动暂停时才恢复播放
                if !self.isPaused {
                    for (screenID, player) in self.players {
                        player.play()
                        self.hidePosterImage(for: screenID)
                    }
                }
                // 重新评估自动暂停状态，避免 AutoPause 之前暂停的屏幕被错误恢复
                DynamicWallpaperAutoPauseManager.shared.reevaluateCurrentState()
            }
            self.pendingRebuildWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
        }
    }

    @objc private func handleSystemWillSleep() {
        // 系统休眠前暂停所有播放
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            for player in self.players.values {
                player.pause()
                player.rate = 0
            }
        }
    }

    @objc private func handleSystemDidWake() {
        // 系统唤醒后防抖重建并恢复播放
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.pendingRebuildWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                if self.hasActiveVideoWallpaper, self.windows.isEmpty {
                    try? self.rebuildWindows()
                }
                if !self.isPaused {
                    for (screenID, player) in self.players {
                        player.play()
                        self.hidePosterImage(for: screenID)
                    }
                }
                // 唤醒后立即重新评估自动暂停状态，避免 AutoPause 之前暂停的屏幕被错误恢复导致闪烁
                DynamicWallpaperAutoPauseManager.shared.reevaluateCurrentState()
            }
            self.pendingRebuildWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
        }
    }

    private func relinkDisplayStateForCurrentScreens() {
        for screen in NSScreen.screens {
            let screenID = screen.wallpaperScreenIdentifier
            let fingerprint = screen.wallpaperScreenFingerprint

            if videoTargetScreenFingerprints.contains(fingerprint) {
                videoTargetScreenIDs.insert(screenID)
            }
            if let videoURL = videoURLByScreenFingerprint[fingerprint] {
                videoURLByScreen[screenID] = videoURL
            }
            if let posterURL = posterURLByScreenFingerprint[fingerprint] {
                posterURLByScreen[screenID] = posterURL
            }
            if let screenVolume = volumeByScreenFingerprint[fingerprint] {
                volumeByScreen[screenID] = screenVolume
            }
        }
        syncCurrentVideoURL()
    }

    private func currentTargetScreenConfigurations() -> [ScreenConfigurationSignature] {
        screensForVideoWallpaperTargets()
            .map(ScreenConfigurationSignature.init(screen:))
            .sorted { $0.screenID < $1.screenID }
    }

    private func hasEffectiveTargetDisplayChange() -> Bool {
        let currentConfigurations = currentTargetScreenConfigurations()

        if windows.isEmpty {
            return true
        }

        let currentScreenIDs = Set(currentConfigurations.map(\.screenID))
        if Set(windows.keys) != currentScreenIDs {
            return true
        }

        return currentConfigurations != lastAppliedScreenConfigurations
    }

    private func rebuildWindows(targetScreen: NSScreen? = nil) throws {
        guard hasActiveVideoWallpaper else { return }
        
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
                        guard let videoURL = self.videoURL(for: screen) else { return }
                        try createWindow(for: screen, videoURL: videoURL, muted: isMuted)
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
                guard let videoURL = videoURL(for: targetScreen) else {
                    NSLog("[VideoWallpaperManager] Missing video URL for target screen \(targetScreenID)")
                    return
                }
                let components = makePlayerComponents(for: targetScreen, videoURL: videoURL, muted: isMuted)
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
                    guard let videoURL = videoURL(for: targetScreen) else {
                        NSLog("[VideoWallpaperManager] Missing video URL for target screen \(targetScreenID)")
                        return
                    }
                    try createWindow(for: targetScreen, videoURL: videoURL, muted: isMuted)
                } catch {
                    NSLog("[VideoWallpaperManager] Failed to create window: \(error.localizedDescription)")
                }
            }
        }

        lastAppliedScreenConfigurations = currentTargetScreenConfigurations()
        NSLog("[VideoWallpaperManager] Windows rebuilt successfully")
    }

    /// 全局重建时只返回应显示 MP4 的 `NSScreen`（与 `videoTargetScreenIDs` 对齐）
    private func screensForVideoWallpaperTargets() -> [NSScreen] {
        relinkDisplayStateForCurrentScreens()

        if videoTargetScreenIDs.isEmpty && videoTargetScreenFingerprints.isEmpty {
            return NSScreen.screens
        }
        let matched = NSScreen.screens.filter { screen in
            videoTargetScreenIDs.contains(screen.wallpaperScreenIdentifier) ||
            videoTargetScreenFingerprints.contains(screen.wallpaperScreenFingerprint)
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

        // 配置播放设置
        playerItem.preferredPeakBitRate = 0
        // 使用视频原始分辨率，避免 Retina 屏下因物理像素分辨率过高导致 GPU 过载
        playerItem.preferredMaximumResolution = CGSize.zero
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
        window.animationBehavior = .none  // 禁止系统自动触发动画（避免激活策略变化时误触发）

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

        windows[screenID] = window
        players[screenID] = components.player

        // 先隐藏窗口，等视频首帧就绪后再淡入，避免启动时闪黑
        window.alphaValue = 0
        window.orderBack(nil)

        // 观察 playerItem 状态，就绪后播放并淡入
        let player = components.player
        let observer = components.item.observe(\.status, options: [.initial]) { [weak self] item, _ in
            guard let self, item.status == .readyToPlay else { return }
            Task { @MainActor in
                // 清理 observer 和超时
                self.playerItemObservers[screenID]?.invalidate()
                self.playerItemObservers.removeValue(forKey: screenID)
                self.fadeInTimeouts[screenID]?.cancel()
                self.fadeInTimeouts.removeValue(forKey: screenID)
                // 仅在非暂停状态下播放（restoreIfNeeded 中可能已设为暂停）
                if !self.isPaused {
                    player.play()
                }
                // 使用 NSAnimationContext 淡入，animationBehavior = .none 确保
                // 只有此处显式触发的动画才会执行，系统不会误触发
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.3
                    window.animator().alphaValue = 1
                }
            }
        }
        playerItemObservers[screenID] = observer

        // 超时保护：3 秒后如果视频仍未就绪，强制淡入
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.playerItemObservers[screenID] != nil else { return }
            self.playerItemObservers[screenID]?.invalidate()
            self.playerItemObservers.removeValue(forKey: screenID)
            self.fadeInTimeouts.removeValue(forKey: screenID)
            if !self.isPaused {
                player.play()
            }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                window.animator().alphaValue = 1
            }
        }
        fadeInTimeouts[screenID] = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: timeout)
    }

    private func teardownAllWindows() {
        posterTasks.values.forEach { $0.cancel() }
        posterTasks.removeAll()
        // 0. 取消上一次未执行的延迟释放，避免快速切换时多组 AVPlayer 并发驻留
        pendingPlayerCleanups.forEach { $0.cancel() }
        pendingPlayerCleanups.removeAll()
        pendingWindowCleanups.forEach { $0.cancel() }
        pendingWindowCleanups.removeAll()
        // 清理启动淡入相关的 observer 和超时
        playerItemObservers.values.forEach { $0.invalidate() }
        playerItemObservers.removeAll()
        fadeInTimeouts.values.forEach { $0.cancel() }
        fadeInTimeouts.removeAll()

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

        lastAppliedScreenConfigurations.removeAll()
    }

    private func persistState() {
        guard hasActiveVideoWallpaper else { return }

        let globalFileURL = currentVideoURL?.absoluteString
            ?? videoURLByScreen.values.first?.absoluteString
            ?? videoURLByScreenFingerprint.values.first?.absoluteString
            ?? ""

        let state = SavedVideoWallpaperState(
            fileURL: globalFileURL,
            posterURL: currentPosterURL?.absoluteString,
            isMuted: isMuted,
            isPaused: isPaused,
            volume: volume,
            volumeByScreen: volumeByScreen.isEmpty ? nil : volumeByScreen,
            volumeByScreenFingerprint: volumeByScreenFingerprint.isEmpty ? nil : volumeByScreenFingerprint,
            videoScreenIDs: videoTargetScreenIDs.isEmpty ? nil : videoTargetScreenIDs.sorted(),
            videoScreenFingerprints: videoTargetScreenFingerprints.isEmpty ? nil : videoTargetScreenFingerprints.sorted(),
            videoURLs: videoURLByScreen.isEmpty ? nil : videoURLByScreen.mapValues { $0.absoluteString },
            videoURLsByFingerprint: videoURLByScreenFingerprint.isEmpty ? nil : videoURLByScreenFingerprint.mapValues { $0.absoluteString },
            posterURLs: posterURLByScreen.isEmpty ? nil : posterURLByScreen.mapValues { $0.absoluteString },
            posterURLsByFingerprint: posterURLByScreenFingerprint.isEmpty ? nil : posterURLByScreenFingerprint.mapValues { $0.absoluteString }
        )

        if let encoded = try? JSONEncoder().encode(state) {
            defaults.set(encoded, forKey: stateKey)
        }
    }
    
    // MARK: - 预览图管理
    
    /// 显示预览图（用于锁屏或无权限时）
    private func showPosterImage(for screenID: String) {
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
    /// 每个物理显示器指纹的独立音量；用于 screenID 重连变化恢复
    let volumeByScreenFingerprint: [String: Double]?
    /// 应显示 MP4 的屏幕 ID；旧版持久化无此字段时表示「当时逻辑等价于全部屏幕」
    let videoScreenIDs: [String]?
    /// 应显示 MP4 的物理显示器指纹；用于外接屏重连后找回目标屏
    let videoScreenFingerprints: [String]?
    /// 每个屏幕的独立视频文件；旧版持久化无此字段时回退到全局 fileURL
    let videoURLs: [String: String]?
    /// 每个物理显示器指纹对应的视频文件；用于 screenID 重连变化恢复
    let videoURLsByFingerprint: [String: String]?
    /// 每个屏幕的独立 poster；旧版持久化无此字段（兼容旧数据时回退到全局 posterURL）
    let posterURLs: [String: String]?
    /// 每个物理显示器指纹的独立 poster；用于 screenID 重连变化恢复
    let posterURLsByFingerprint: [String: String]?

    var hasExplicitScreenTargets: Bool {
        !(videoScreenIDs?.isEmpty ?? true) || !(videoScreenFingerprints?.isEmpty ?? true)
    }

    // 兼容旧版解码（posterURLs 可能不存在）
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fileURL = try container.decode(String.self, forKey: .fileURL)
        posterURL = try container.decodeIfPresent(String.self, forKey: .posterURL)
        isMuted = try container.decode(Bool.self, forKey: .isMuted)
        isPaused = try container.decode(Bool.self, forKey: .isPaused)
        volume = try container.decodeIfPresent(Double.self, forKey: .volume)
        volumeByScreen = try container.decodeIfPresent([String: Double].self, forKey: .volumeByScreen)
        volumeByScreenFingerprint = try container.decodeIfPresent([String: Double].self, forKey: .volumeByScreenFingerprint)
        videoScreenIDs = try container.decodeIfPresent([String].self, forKey: .videoScreenIDs)
        videoScreenFingerprints = try container.decodeIfPresent([String].self, forKey: .videoScreenFingerprints)
        videoURLs = try container.decodeIfPresent([String: String].self, forKey: .videoURLs)
        videoURLsByFingerprint = try container.decodeIfPresent([String: String].self, forKey: .videoURLsByFingerprint)
        posterURLs = try container.decodeIfPresent([String: String].self, forKey: .posterURLs)
        posterURLsByFingerprint = try container.decodeIfPresent([String: String].self, forKey: .posterURLsByFingerprint)
    }

    init(
        fileURL: String,
        posterURL: String?,
        isMuted: Bool,
        isPaused: Bool,
        volume: Double?,
        volumeByScreen: [String: Double]?,
        volumeByScreenFingerprint: [String: Double]?,
        videoScreenIDs: [String]?,
        videoScreenFingerprints: [String]?,
        videoURLs: [String: String]? = nil,
        videoURLsByFingerprint: [String: String]? = nil,
        posterURLs: [String: String]? = nil,
        posterURLsByFingerprint: [String: String]? = nil
    ) {
        self.fileURL = fileURL
        self.posterURL = posterURL
        self.isMuted = isMuted
        self.isPaused = isPaused
        self.volume = volume
        self.volumeByScreen = volumeByScreen
        self.volumeByScreenFingerprint = volumeByScreenFingerprint
        self.videoScreenIDs = videoScreenIDs
        self.videoScreenFingerprints = videoScreenFingerprints
        self.videoURLs = videoURLs
        self.videoURLsByFingerprint = videoURLsByFingerprint
        self.posterURLs = posterURLs
        self.posterURLsByFingerprint = posterURLsByFingerprint
    }

    enum CodingKeys: String, CodingKey {
        case fileURL, posterURL, isMuted, isPaused, volume
        case volumeByScreen, volumeByScreenFingerprint
        case videoScreenIDs, videoScreenFingerprints
        case videoURLs, videoURLsByFingerprint
        case posterURLs, posterURLsByFingerprint
    }
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
