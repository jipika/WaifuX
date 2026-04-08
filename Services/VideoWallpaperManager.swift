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

    private let defaults = UserDefaults.standard
    private let stateKey = "video_wallpaper_state_v1"
    private let showPosterOnLockKey = "video_wallpaper_show_poster_on_lock"
    private let originalWallpaperKey = "video_wallpaper_original_desktop"
    
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
    
    // 防止重复重建
    private var isRebuilding = false
    private var pendingRebuildWorkItem: DispatchWorkItem?
    private let rebuildLock = NSLock()

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

    func applyVideoWallpaper(from localFileURL: URL, posterURL: URL? = nil, muted: Bool = true) throws {
        guard localFileURL.isFileURL else {
            throw NSError(domain: "VideoWallpaper", code: 1001, userInfo: [NSLocalizedDescriptionKey: "动态壁纸必须使用本地视频文件。"])
        }

        guard FileManager.default.fileExists(atPath: localFileURL.path) else {
            throw NSError(domain: "VideoWallpaper", code: 1002, userInfo: [NSLocalizedDescriptionKey: "视频文件不存在。"])
        }

        let expectedScreenIDs = Set(NSScreen.screens.map(\.wallpaperScreenIdentifier))
        let activeScreenIDs = Set(windows.keys)

        if currentVideoURL == localFileURL, expectedScreenIDs == activeScreenIDs, !windows.isEmpty {
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

        // 保存用户原始壁纸（如果是首次设置）
        if currentVideoURL == nil {
            saveOriginalWallpaper()
        }
        
        // 如果有预览图，设置为桌面壁纸（锁屏会显示这个）
        if let posterURL = posterURL {
            setPosterAsDesktopWallpaper(posterURL)
        }
        
        currentVideoURL = localFileURL
        currentPosterURL = posterURL
        isMuted = muted
        isPaused = false

        try rebuildWindows()
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

    func pauseWallpaper() {
        isPaused = true
        for player in players.values {
            player.pause()
        }
        persistState()
    }

    func resumeWallpaper() {
        guard currentVideoURL != nil else { return }
        isPaused = false
        // 直接恢复播放，不走延迟检测路径
        for (screenID, player) in players {
            player.play()
            hidePosterImage(for: screenID)
        }
        persistState()
    }
    
    // MARK: - 锁屏处理
    
    private var isScreenLocked = false
    
    @objc private func handleScreenLocked() {
        print("[VideoWallpaperManager] Screen locked, pausing wallpaper")
        isScreenLocked = true
        // 锁屏时暂停视频，显示预览图（预览图已设为桌面壁纸）
        for (screenID, player) in players {
            player.pause()
            showPosterImage(for: screenID)
        }
    }
    
    @objc private func handleScreenUnlocked() {
        print("[VideoWallpaperManager] Screen unlocked, resuming wallpaper")
        isScreenLocked = false
        // 解锁时恢复播放（如果不是手动暂停）
        guard !isPaused else { return }
        for (screenID, player) in players {
            player.play()
            hidePosterImage(for: screenID)
        }
    }

    func stopWallpaper() {
        teardownAllWindows()
        currentVideoURL = nil
        currentPosterURL = nil
        isPaused = false
        // 不删除保存的状态，以便下次可以恢复
        
        // 恢复用户原始桌面壁纸
        restoreOriginalWallpaper()
    }
    
    // MARK: - 锁屏壁纸管理
    
    /// 保存用户当前的桌面壁纸（锁屏显示的是桌面壁纸）
    private func saveOriginalWallpaper() {
        let workspace = NSWorkspace.shared
        var originalWallpapers: [String: String] = [:]
        
        for screen in NSScreen.screens {
            if let desktopURL = workspace.desktopImageURL(for: screen) {
                let screenID = screen.wallpaperScreenIdentifier
                originalWallpapers[screenID] = desktopURL.absoluteString
            }
        }
        
        if !originalWallpapers.isEmpty,
           let data = try? JSONEncoder().encode(originalWallpapers) {
            defaults.set(data, forKey: originalWallpaperKey)
            print("[VideoWallpaperManager] Saved original wallpaper: \(originalWallpapers)")
        }
    }
    
    /// 将预览图设为桌面壁纸（锁屏会显示这个）
    private func setPosterAsDesktopWallpaper(_ posterURL: URL) {
        let workspace = NSWorkspace.shared
        
        // 先下载预览图到本地
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: posterURL)
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("wallpaper_poster_\(posterURL.lastPathComponent)")
                try data.write(to: tempURL)
                
                // 设置为桌面壁纸
                for screen in NSScreen.screens {
                    try workspace.setDesktopImageURL(tempURL, for: screen, options: [:])
                }
                print("[VideoWallpaperManager] Set poster as desktop wallpaper")
            } catch {
                print("[VideoWallpaperManager] Failed to set poster: \(error)")
            }
        }
    }
    
    /// 恢复用户原始桌面壁纸
    private func restoreOriginalWallpaper() {
        guard let data = defaults.data(forKey: originalWallpaperKey),
              let originalWallpapers = try? JSONDecoder().decode([String: String].self, from: data) else {
            print("[VideoWallpaperManager] No original wallpaper to restore")
            return
        }
        
        let workspace = NSWorkspace.shared
        
        for screen in NSScreen.screens {
            let screenID = screen.wallpaperScreenIdentifier
            guard let originalPath = originalWallpapers[screenID],
                  let originalURL = URL(string: originalPath) else { continue }
            
            // 检查文件是否存在
            guard FileManager.default.fileExists(atPath: originalURL.path) else {
                print("[VideoWallpaperManager] Original wallpaper not found: \(originalPath)")
                continue
            }
            
            do {
                try workspace.setDesktopImageURL(originalURL, for: screen, options: [:])
                print("[VideoWallpaperManager] Restored wallpaper for screen: \(screenID)")
            } catch {
                print("[VideoWallpaperManager] Failed to restore wallpaper: \(error)")
            }
        }
        
        // 清除保存的原始壁纸
        defaults.removeObject(forKey: originalWallpaperKey)
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
            try applyVideoWallpaper(from: url, posterURL: posterURL, muted: savedState.isMuted)
            if savedState.isPaused {
                pauseWallpaper()
            }
        } catch {
            defaults.removeObject(forKey: stateKey)
        }
    }

    @objc private func handleScreenParametersChanged() {
        guard currentVideoURL != nil else { return }
        
        // 防抖：延迟 300ms 执行，避免屏幕参数变化时的频繁重建
        pendingRebuildWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, self.currentVideoURL != nil else { return }
            do {
                try self.rebuildWindows()
            } catch {
                NSLog("[VideoWallpaperManager] Failed to rebuild windows: \(error.localizedDescription)")
            }
        }
        pendingRebuildWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
    }

    @objc private func handleScreensDidSleep() {
        for player in players.values {
            player.pause()
        }
    }

    @objc private func handleScreensDidWake() {
        // 屏幕唤醒时防抖重建
        pendingRebuildWorkItem?.cancel()
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
        pendingRebuildWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    private func rebuildWindows() throws {
        guard let currentVideoURL else { return }
        
        // 使用锁防止并发重建
        rebuildLock.lock()
        defer { rebuildLock.unlock() }
        
        // 如果正在重建，跳过此次请求
        guard !isRebuilding else {
            NSLog("[VideoWallpaperManager] Rebuild already in progress, skipping...")
            return
        }
        
        isRebuilding = true
        defer { isRebuilding = false }

        NSLog("[VideoWallpaperManager] Rebuilding windows for \(NSScreen.screens.count) screen(s)")
        teardownAllWindows()

        for screen in NSScreen.screens {
            try createWindow(for: screen, videoURL: currentVideoURL, muted: isMuted)
        }

        NSLog("[VideoWallpaperManager] Windows rebuilt successfully")
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
        window.ignoresMouseEvents = true
        window.isMovable = false

        let containerView = WallpaperVideoContainerView(frame: CGRect(origin: .zero, size: frame.size))
        containerView.autoresizingMask = [.width, .height]
        window.contentView = containerView

        let playerItem = AVPlayerItem(url: videoURL)
        let queuePlayer = AVQueuePlayer()
        queuePlayer.actionAtItemEnd = .none
        queuePlayer.isMuted = muted
        queuePlayer.volume = muted ? 0 : 1
        queuePlayer.automaticallyWaitsToMinimizeStalling = false
        queuePlayer.preventsDisplaySleepDuringVideoPlayback = false

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
        for looper in loopers.values {
            looper.disableLooping()
        }
        loopers.removeAll()

        for player in players.values {
            player.pause()
            player.removeAllItems()
        }
        players.removeAll()

        for window in windows.values {
            if let contentView = window.contentView as? WallpaperVideoContainerView {
                contentView.playerLayer.player = nil
            }
            window.orderOut(nil)
            window.contentView = nil
        }
        windows.removeAll()
    }

    private func persistState() {
        guard let currentVideoURL else { return }

        let state = SavedVideoWallpaperState(
            fileURL: currentVideoURL.absoluteString,
            posterURL: currentPosterURL?.absoluteString,
            isMuted: isMuted,
            isPaused: isPaused
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
