import Foundation
import AppKit
import AVFoundation
import CoreGraphics
import ScreenCaptureKit

@MainActor
final class VideoWallpaperManager: ObservableObject {
    static let shared = VideoWallpaperManager()

    @Published private(set) var currentVideoURL: URL?
    @Published private(set) var isMuted = true
    @Published private(set) var isPaused = false

    private var windows: [String: WallpaperVideoWindow] = [:]
    private var players: [String: AVQueuePlayer] = [:]
    private var loopers: [String: AVPlayerLooper] = [:]
    private var pausedScreenIDs: Set<String> = []
    private var playbackRefreshWorkItem: DispatchWorkItem?

    private let defaults = UserDefaults.standard
    private let stateKey = "video_wallpaper_state_v1"

    private init() {
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

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWorkspaceContextChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWorkspaceContextChanged),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    func applyVideoWallpaper(from localFileURL: URL, muted: Bool = true) throws {
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
            for player in players.values {
                if player.rate == 0 {
                    player.play()
                }
            }
            schedulePlaybackStateRefresh()
            return
        }

        currentVideoURL = localFileURL
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
        schedulePlaybackStateRefresh()
        persistState()
    }

    func stopWallpaper() {
        teardownAllWindows()
        currentVideoURL = nil
        isPaused = false
        defaults.removeObject(forKey: stateKey)
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

        do {
            try applyVideoWallpaper(from: url, muted: savedState.isMuted)
            if savedState.isPaused {
                pauseWallpaper()
            }
        } catch {
            defaults.removeObject(forKey: stateKey)
        }
    }

    @objc private func handleScreenParametersChanged() {
        guard currentVideoURL != nil else { return }
        do {
            try rebuildWindows()
        } catch {
            NSLog("[VideoWallpaperManager] Failed to rebuild windows: \(error.localizedDescription)")
        }
    }

    @objc private func handleWorkspaceContextChanged() {
        schedulePlaybackStateRefresh()
    }

    @objc private func handleScreensDidSleep() {
        for player in players.values {
            player.pause()
        }
    }

    @objc private func handleScreensDidWake() {
        if currentVideoURL != nil, windows.isEmpty {
            try? rebuildWindows()
        }
        if !isPaused {
            schedulePlaybackStateRefresh()
        }
    }

    private func rebuildWindows() throws {
        guard let currentVideoURL else { return }

        teardownAllWindows()

        for screen in NSScreen.screens {
            try createWindow(for: screen, videoURL: currentVideoURL, muted: isMuted)
        }

        schedulePlaybackStateRefresh()
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
        loopers[screenID] = looper
    }

    private func teardownAllWindows() {
        playbackRefreshWorkItem?.cancel()
        playbackRefreshWorkItem = nil
        pausedScreenIDs.removeAll()

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
            isMuted: isMuted,
            isPaused: isPaused
        )

        if let encoded = try? JSONEncoder().encode(state) {
            defaults.set(encoded, forKey: stateKey)
        }
    }

    private func schedulePlaybackStateRefresh() {
        playbackRefreshWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.refreshPlaybackState()
        }
        playbackRefreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
    }

    private func refreshPlaybackState() {
        guard !players.isEmpty else { return }

        if isPaused {
            for player in players.values {
                player.pause()
            }
            return
        }

        // 使用 ScreenCaptureKit 替代废弃的 CGWindowListCopyWindowInfo
        Task {
            await checkScreenCoverageWithScreenCaptureKit()
        }
    }

    @available(macOS 14.0, *)
    private func checkScreenCoverageWithScreenCaptureKit() async {
        do {
            // 使用 ScreenCaptureKit 获取窗口信息
            let content = try await SCShareableContent.current
            let currentPID = ProcessInfo.processInfo.processIdentifier

            for screen in NSScreen.screens {
                let screenID = screen.wallpaperScreenIdentifier
                guard let player = players[screenID] else { continue }

                let covered = await isScreenMostlyCoveredWithSCContent(
                    screenFrame: screen.frame,
                    windows: content.windows,
                    excludingPID: currentPID
                )

                await MainActor.run {
                    if covered {
                        if !pausedScreenIDs.contains(screenID) {
                            player.pause()
                            pausedScreenIDs.insert(screenID)
                        }
                    } else {
                        if pausedScreenIDs.contains(screenID) {
                            pausedScreenIDs.remove(screenID)
                        }
                        if player.rate == 0 {
                            player.play()
                        }
                    }
                }
            }
        } catch {
            // 如果 ScreenCaptureKit 失败，回退到基于可见性的简单逻辑
            // 在 macOS 14 以下版本使用 CGWindowListCopyWindowInfo（仍然可用）
            await fallbackScreenCoverageCheck()
        }
    }

    @available(macOS 14.0, *)
    private func isScreenMostlyCoveredWithSCContent(
        screenFrame: CGRect,
        windows: [SCWindow],
        excludingPID: Int32
    ) async -> Bool {
        var largeCoverCount = 0
        var totalCoveredRatio: CGFloat = 0

        for window in windows {
            // 跳过当前应用的窗口
            guard window.owningApplication?.processID != excludingPID else { continue }

            // 只考虑正常层级的窗口（layer 0 等效）
            guard window.windowLayer == 0 else { continue }

            let bounds = window.frame
            guard !bounds.isEmpty else { continue }

            let intersection = screenFrame.intersection(bounds)
            guard !intersection.isNull, !intersection.isEmpty else { continue }

            let ratio = (intersection.width * intersection.height) / max(screenFrame.width * screenFrame.height, 1)
            if ratio >= 0.88 {
                return true
            }
            if ratio >= 0.42 {
                largeCoverCount += 1
            }
            totalCoveredRatio += ratio
        }

        if largeCoverCount >= 2 {
            return true
        }

        return totalCoveredRatio >= 0.96
    }

    /// 回退方案：使用 CGWindowListCopyWindowInfo（在 macOS 15+ 被标记为废弃但仍可用）
    @available(macOS, deprecated: 15.0, message: "Use ScreenCaptureKit instead")
    private func fallbackScreenCoverageCheck() async {
        let windowInfo = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        let currentPID = ProcessInfo.processInfo.processIdentifier

        for screen in NSScreen.screens {
            let screenID = screen.wallpaperScreenIdentifier
            guard let player = players[screenID] else { continue }

            let covered = isScreenMostlyCoveredLegacy(
                screenFrame: screen.frame,
                windows: windowInfo,
                excludingPID: currentPID
            )

            await MainActor.run {
                if covered {
                    if !pausedScreenIDs.contains(screenID) {
                        player.pause()
                        pausedScreenIDs.insert(screenID)
                    }
                } else {
                    if pausedScreenIDs.contains(screenID) {
                        pausedScreenIDs.remove(screenID)
                    }
                    if player.rate == 0 {
                        player.play()
                    }
                }
            }
        }
    }

    @available(macOS, deprecated: 15.0)
    private func isScreenMostlyCoveredLegacy(
        screenFrame: CGRect,
        windows: [[String: Any]],
        excludingPID: Int32
    ) -> Bool {
        var largeCoverCount = 0
        var totalCoveredRatio: CGFloat = 0

        for window in windows {
            guard
                let ownerPID = window[kCGWindowOwnerPID as String] as? Int32,
                ownerPID != excludingPID,
                let layer = window[kCGWindowLayer as String] as? Int,
                layer == 0,
                let alpha = window[kCGWindowAlpha as String] as? Double,
                alpha > 0.01,
                let boundsValue = window[kCGWindowBounds as String]
            else {
                continue
            }

            guard
                let boundsDictionary = boundsValue as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsDictionary)
            else {
                continue
            }

            let intersection = screenFrame.intersection(bounds)
            guard !intersection.isNull, !intersection.isEmpty else { continue }

            let ratio = (intersection.width * intersection.height) / max(screenFrame.width * screenFrame.height, 1)
            if ratio >= 0.88 {
                return true
            }
            if ratio >= 0.42 {
                largeCoverCount += 1
            }
            totalCoveredRatio += ratio
        }

        if largeCoverCount >= 2 {
            return true
        }

        return totalCoveredRatio >= 0.96
    }
}

private struct SavedVideoWallpaperState: Codable {
    let fileURL: String
    let isMuted: Bool
    let isPaused: Bool
}

private final class WallpaperVideoWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class WallpaperVideoContainerView: NSView {
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

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
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
