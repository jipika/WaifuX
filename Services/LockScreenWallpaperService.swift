//  LockScreenWallpaperService.swift
//  WaifuX
//
//  管理锁屏镜像实例的共享状态与偏好同步。
//  仅在 macOS 26.0+ 生效，通过 WallpaperExtensionKit 私有框架实现。
//
//  支持多显示器：每个显示器可以部署不同的视频，扩展根据 choiceConfiguration 选择对应视频。

import AVFoundation
import Combine
import Foundation
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import notify

/// 锁屏镜像实例管理服务
///
/// 真实业务模型是：
/// 1. 扩展为每个显示器暴露一个固定的锁屏实例，用户在系统设置中手动选择一次
/// 2. 主 App 维护“显示器 -> 当前桌面视频源”映射
/// 3. 实例激活后，主 App 仅向对应显示器实例推送桌面帧，不自动切换系统壁纸选择
@MainActor
final class LockScreenWallpaperService: ObservableObject {
    static let shared = LockScreenWallpaperService()

    /// P3 锁屏/显示器睡眠状态契约。
    ///
    /// `notificationName` 使用 Foundation 通知供 App 内订阅；
    /// `distributedNotificationName` 使用 NSDistributedNotificationCenter 供
    /// 外部 video renderer 跨进程订阅。状态同时写入 `stateFileURL`，这样
    /// renderer 在启动晚于锁屏通知时仍能读取当前状态，而不会误播或误恢复。
    struct PlaybackState: Codable, Equatable, Sendable {
        let isScreenLocked: Bool
        let isDisplayAsleep: Bool
        let shouldPauseVideo: Bool
        let shouldShowPoster: Bool
        let transitionGeneration: UInt64
        let source: String

        var shouldHidePoster: Bool {
            !shouldShowPoster && !shouldPauseVideo
        }
    }

    static let playbackStateNotification = Notification.Name(
        "com.waifux.wallpaper.lockScreenPlaybackStateDidChange"
    )
    static let distributedPlaybackStateNotification = Notification.Name(
        "com.waifux.wallpaper.lockScreenPlaybackStateDidChange"
    )
    static let stateUserInfoKey = "state"
    static let generationUserInfoKey = "transitionGeneration"
    static let lockedUserInfoKey = "isScreenLocked"
    static let displayAsleepUserInfoKey = "isDisplayAsleep"
    static let shouldPauseUserInfoKey = "shouldPauseVideo"
    static let shouldShowPosterUserInfoKey = "shouldShowPoster"
    static let sourceUserInfoKey = "source"

    struct DisplayInstance: Codable, Sendable {
        let id: String
        let displayID: UInt32
        let name: String
        let thumbnailPath: String?
    }

    /// 功能是否可用（macOS 26.0+ 且已配置 App Group）
    var isAvailable: Bool {
        guard #available(macOS 26.0, *) else { return false }
        return sharedContainerURL != nil
    }

    /// 当前写入共享容器的镜像帧源路径
    private(set) var currentMirroringSourcePath: String?

    /// 动态锁屏扩展当前显示的静态图原始来源。扩展实际使用的是共享容器内的副本，
    /// UI 需要这里的原始 URL 才能反查到资料库条目。
    @Published private(set) var staticImageSourceChangeSignal = 0
    private var staticImageSourceURLByDisplayID: [UInt32: URL] = [:]

    /// 已写入共享容器的视频 ID 集合（兼容旧缓存清理）
    private var deployedVideoIDs: Set<String> = []

    /// 当前系统锁屏/显示器可见性状态，供主进程和外部 renderer 共同读取。
    private(set) var playbackState = PlaybackState(
        isScreenLocked: false,
        isDisplayAsleep: false,
        shouldPauseVideo: false,
        shouldShowPoster: false,
        transitionGeneration: 0,
        source: "initial"
    )
    private var playbackStateReconciliationTask: Task<Void, Never>?
    /// The unlock notification can arrive before CGSessionCopyCurrentDictionary()
    /// reflects the new session state. Keep the explicit notification authoritative
    /// for a short grace period so a stale `locked=true` read cannot re-pause video
    /// immediately after the user unlocks the Mac.
    private var explicitUnlockObservedAt: Date?
    private let staleSessionLockGracePeriod: TimeInterval = 3.0

    private let appGroupID = "group.com.waifux.app"
    private let prefsFileName = "waifux-wallpaper-prefs.json"
    private let videoDirName = "WallpaperVideos"
    private let imageDirName = "WallpaperImages"
    private let displayInstancesFileName = "waifux-display-instances.json"
    private let playbackStateFileName = "waifux-video-renderer-lock-state.json"

    private var sharedContainerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    private init() {
        restoreStaticImageSourceURLs()
        restoreInitialPlaybackState()
        observeSystemPlaybackState()
        publishPlaybackState(source: "initial")
    }

    deinit {
        playbackStateReconciliationTask?.cancel()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default.removeObserver(self)
    }

    // MARK: - External Renderer Playback State

    private func restoreInitialPlaybackState() {
        let persisted: PlaybackState? = {
            guard let url = playbackStateURL,
                  let data = try? Data(contentsOf: url) else {
                return nil
            }
            return try? JSONDecoder().decode(PlaybackState.self, from: data)
        }()
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let isLocked = (session?["CGSSessionScreenIsLocked"] as? Bool) ?? false
        playbackState = PlaybackState(
            isScreenLocked: isLocked,
            // App 能初始化并运行到这里时显示器通常已醒；不要沿用上次异常退出
            // 留下的 stale asleep=true。
            isDisplayAsleep: false,
            shouldPauseVideo: isLocked,
            shouldShowPoster: isLocked,
            transitionGeneration: (persisted?.transitionGeneration ?? 0) &+ 1,
            source: "sessionRestore"
        )
    }

    /// Keep the lock/sleep state in one place so the in-process manager and the
    /// external video renderer observe the same transitions.
    private func observeSystemPlaybackState() {
        DistributedNotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSystemScreenLocked),
            name: Notification.Name("com.apple.screenIsLocked"),
            object: nil
        )
        DistributedNotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSystemScreenUnlocked),
            name: Notification.Name("com.apple.screenIsUnlocked"),
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
    }

    @objc private func handleSystemScreenLocked() {
        explicitUnlockObservedAt = nil
        updatePlaybackVisibility(isScreenLocked: true, source: "screenLocked")
    }

    @objc private func handleSystemScreenUnlocked() {
        explicitUnlockObservedAt = Date()
        updatePlaybackVisibility(isScreenLocked: false, source: "screenUnlocked")
        schedulePlaybackStateReconciliation(source: "screenUnlocked")
    }

    @objc private func handleScreensDidSleep() {
        updatePlaybackVisibility(isDisplayAsleep: true, source: "screensDidSleep")
    }

    @objc private func handleScreensDidWake() {
        updatePlaybackVisibility(isDisplayAsleep: false, source: "screensDidWake")
        schedulePlaybackStateReconciliation(source: "screensDidWake")
    }

    @objc private func handleSystemWillSleep() {
        updatePlaybackVisibility(isDisplayAsleep: true, source: "systemWillSleep")
    }

    @objc private func handleSystemDidWake() {
        updatePlaybackVisibility(isDisplayAsleep: false, source: "systemDidWake")
        schedulePlaybackStateReconciliation(source: "systemDidWake")
    }

    /// Reconcile after wake/unlock instead of trusting one notification.
    /// macOS can deliver the notification before the login session has
    /// finished changing, or occasionally drop one of the wake notifications.
    func reconcilePlaybackStateAfterWake(source: String) {
        if source.localizedCaseInsensitiveContains("unlock") {
            explicitUnlockObservedAt = Date()
            // Do not synchronously consult CGSession here. On a lid unlock the
            // session dictionary can still report the old locked state.
            updatePlaybackVisibility(isScreenLocked: false, source: source)
        } else {
            // A display wake only clears the sleep component; preserve the
            // explicit lock state until the delayed session reconciliation.
            updatePlaybackVisibility(isDisplayAsleep: false, source: source)
        }
        schedulePlaybackStateReconciliation(source: source)
    }

    private func schedulePlaybackStateReconciliation(source: String) {
        playbackStateReconciliationTask?.cancel()
        playbackStateReconciliationTask = Task { @MainActor [weak self] in
            let delays: [UInt64] = [
                250_000_000,
                750_000_000,
                1_500_000_000
            ]
            for delay in delays {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled, let self else { return }
                self.reconcilePlaybackStateWithCurrentSession(
                    source: "\(source)-reconcile"
                )
            }
            self?.playbackStateReconciliationTask = nil
        }
    }

    private func reconcilePlaybackStateWithCurrentSession(source: String) {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              let isScreenLocked = session["CGSSessionScreenIsLocked"] as? Bool else {
            return
        }

        if isScreenLocked,
           !playbackState.isScreenLocked,
           let explicitUnlockObservedAt,
           Date().timeIntervalSince(explicitUnlockObservedAt) < staleSessionLockGracePeriod {
            print("[LockScreenWallpaper] defer stale locked session result after unlock")
            return
        }
        if !isScreenLocked {
            explicitUnlockObservedAt = nil
        }

        updatePlaybackVisibility(
            isScreenLocked: isScreenLocked,
            isDisplayAsleep: false,
            source: source
        )
    }

    private func updatePlaybackVisibility(
        isScreenLocked: Bool? = nil,
        isDisplayAsleep: Bool? = nil,
        source: String
    ) {
        let current = playbackState
        let next = PlaybackState(
            isScreenLocked: isScreenLocked ?? current.isScreenLocked,
            isDisplayAsleep: isDisplayAsleep ?? current.isDisplayAsleep,
            shouldPauseVideo: (isScreenLocked ?? current.isScreenLocked)
                || (isDisplayAsleep ?? current.isDisplayAsleep),
            shouldShowPoster: (isScreenLocked ?? current.isScreenLocked)
                || (isDisplayAsleep ?? current.isDisplayAsleep),
            transitionGeneration: current.transitionGeneration &+ 1,
            source: source
        )
        guard next != current else { return }
        playbackState = next
        publishPlaybackState(source: source)
    }

    /// Persist scalar-only state for a renderer that starts after the original
    /// notification, then publish the same state through both notification
    /// centers for a renderer that is already alive.
    private func publishPlaybackState(source: String) {
        let state = PlaybackState(
            isScreenLocked: playbackState.isScreenLocked,
            isDisplayAsleep: playbackState.isDisplayAsleep,
            shouldPauseVideo: playbackState.shouldPauseVideo,
            shouldShowPoster: playbackState.shouldShowPoster,
            transitionGeneration: playbackState.transitionGeneration,
            source: source
        )
        playbackState = state

        if let url = playbackStateURL,
           let data = try? JSONEncoder().encode(state) {
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                print("[LockScreenWallpaper] Failed to persist playback state: \(error)")
            }
        }

        let userInfo: [AnyHashable: Any] = [
            Self.stateUserInfoKey: [
                Self.lockedUserInfoKey: state.isScreenLocked,
                Self.displayAsleepUserInfoKey: state.isDisplayAsleep,
                Self.shouldPauseUserInfoKey: state.shouldPauseVideo,
                Self.shouldShowPosterUserInfoKey: state.shouldShowPoster,
                Self.generationUserInfoKey: NSNumber(value: state.transitionGeneration),
                Self.sourceUserInfoKey: state.source
            ],
            Self.lockedUserInfoKey: state.isScreenLocked,
            Self.displayAsleepUserInfoKey: state.isDisplayAsleep,
            Self.shouldPauseUserInfoKey: state.shouldPauseVideo,
            Self.shouldShowPosterUserInfoKey: state.shouldShowPoster,
            Self.generationUserInfoKey: NSNumber(value: state.transitionGeneration),
            Self.sourceUserInfoKey: state.source
        ]
        NotificationCenter.default.post(
            name: Self.playbackStateNotification,
            object: self,
            userInfo: userInfo
        )
        DistributedNotificationCenter.default().postNotificationName(
            Self.distributedPlaybackStateNotification,
            object: nil,
            userInfo: userInfo,
            deliverImmediately: true
        )
    }

    var displayInstancesURL: URL? {
        sharedContainerURL?.appendingPathComponent(displayInstancesFileName)
    }

    /// 外部 renderer 可读取的共享状态文件。
    var playbackStateURL: URL? {
        sharedContainerURL?.appendingPathComponent(playbackStateFileName)
    }

    /// 外部 renderer 的稳定状态/通知契约说明。
    /// userInfo 中的值均为 Property List 标量，避免跨进程解码 Swift 类型。
    static var externalRendererPlaybackContract: [String: String] {
        [
            "notification": distributedPlaybackStateNotification.rawValue,
            "lockedKey": lockedUserInfoKey,
            "displayAsleepKey": displayAsleepUserInfoKey,
            "pauseKey": shouldPauseUserInfoKey,
            "showPosterKey": shouldShowPosterUserInfoKey,
            "generationKey": generationUserInfoKey,
            "sourceKey": sourceUserInfoKey
        ]
    }

    /// 返回扩展当前在指定屏幕上渲染的静态图原始来源。
    func staticImageSourceURL(for screen: NSScreen) -> URL? {
        guard let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else {
            return nil
        }
        return staticImageSourceURLByDisplayID[displayID]
    }

    // MARK: - Public API

    /// 将指定桌面视频源写入共享容器，供锁屏实例在需要时读取缩略图/兜底内容。
    /// - Parameters:
    ///   - videoURL: 本地视频文件路径（MP4/MOV）
    ///   - videoID: 壁纸唯一标识（用于区分不同壁纸）
    ///   - displayIDs: 使用该视频的显示器集合。若提供，则写入 per-display 路径映射，
    ///     使扩展在冷启动 acquire 时为每块屏选到各自的视频。若为空，则仅写 legacy 全局路径。
    ///   - notify: 是否触发 Extension 重新加载
    func cacheMirroringSource(videoURL: URL, videoID: String, displayIDs: [UInt32] = [], notify: Bool = true) async throws {
        guard isAvailable else {
            print("[LockScreenWallpaper] 功能不可用（需 macOS 26+）")
            return
        }

        guard UserDefaults.standard.object(forKey: "dynamic_lock_screen_enabled") as? Bool ?? true else {
            print("[LockScreenWallpaper] 动态锁屏已关闭，跳过")
            return
        }

        guard videoURL.isFileURL, FileManager.default.fileExists(atPath: videoURL.path) else {
            throw LockScreenError.fileNotFound
        }

        guard let container = sharedContainerURL else {
            throw LockScreenError.appGroupNotAvailable
        }

        let videoDir = container.appendingPathComponent(videoDirName, isDirectory: true)
        try FileManager.default.createDirectory(at: videoDir, withIntermediateDirectories: true)

        // 清理不再需要的旧视频（保留当前部署的和新视频）
        var keepIDs = deployedVideoIDs
        keepIDs.insert(videoID)
        cleanupOldVideos(in: videoDir, keeping: keepIDs)

        // 用 hard link 将视频放到共享容器（同一卷不占额外空间）
        let destURL = videoDir.appendingPathComponent("\(videoID).mp4")
        if FileManager.default.fileExists(atPath: destURL.path) {
            try? FileManager.default.removeItem(at: destURL)
        }
        do {
            try FileManager.default.linkItem(at: videoURL, to: destURL)
        } catch {
            try FileManager.default.copyItem(at: videoURL, to: destURL)
        }

        deployedVideoIDs.insert(videoID)

        // 合并写入 prefs（不覆盖其它 displayID 的路径）：
        // 读取现有 prefs → 更新 legacy 全局路径 + 本批 displayIDs 的 per-display 路径 → 原子写回
        let prefsURL = container.appendingPathComponent(prefsFileName)
        var prefs = (try? JSONDecoder().decode(PrefsFile.self, from: Data(contentsOf: prefsURL))) ?? PrefsFile()
        prefs.userPaused = false
        prefs.alwaysPauseDesktop = false
        // Legacy global: 取最近写入的一路（向后兼容旧扩展）。
        prefs.currentVideoPath = destURL.path
        prefs.currentImagePath = nil
        prefs.currentRealtimeSourceKind = nil
        // Per-display: 本批 displayIDs 全部指向该视频
        if !displayIDs.isEmpty {
            var map = prefs.currentVideoPaths ?? [:]
            for did in displayIDs {
                map["display-\(did)"] = destURL.path
            }
            prefs.currentVideoPaths = map
            // 该视频覆盖这些屏的图片路径
            prefs.currentImagePaths = prefs.currentImagePaths?.filter { key, _ in
                !displayIDs.contains { "display-\($0)" == key }
            }
            prefs.currentImageSourceURLs = prefs.currentImageSourceURLs?.filter { key, _ in
                !displayIDs.contains { "display-\($0)" == key }
            }
            for displayID in displayIDs {
                staticImageSourceURLByDisplayID.removeValue(forKey: displayID)
            }
            staticImageSourceChangeSignal &+= 1
        }
        let data = try JSONEncoder().encode(prefs)
        try data.write(to: prefsURL, options: .atomic)

        currentMirroringSourcePath = destURL.path

        // 先生成缩略图，再同步实例目录，确保封面路径在新目录中立即生效
        generateThumbnail(for: destURL, videoID: videoID)
        // 更新显示器实例目录（此时缩略图已就绪，posterThumbnailPath 能查到最新文件）
        syncInstanceCatalogToSocketServer(notify: notify)
        WallpaperExtensionSocketServer.shared.registerLocalDecodeVideo(videoID: videoID, videoURL: destURL)

        // 再通知 Extension 刷新（此时 SocketServer 已有最新数据）
        if notify {
            notifyExtensionPrefsChanged()
        }

        print("[LockScreenWallpaper] ✅ 已更新锁屏镜像帧源缓存: \(destURL.lastPathComponent) display=\(displayIDs)")
    }

    /// 将静态图片写入共享容器，并绑定到每个显示器实例。
    /// 静态壁纸不再退回系统锁屏选择写入；扩展直接渲染这里部署的图片。
    func cacheStaticImageSource(imageURL: URL, displayIDs: [UInt32]) async throws {
        guard isAvailable else {
            print("[LockScreenWallpaper] 功能不可用（需 macOS 26+）")
            return
        }

        guard UserDefaults.standard.object(forKey: "dynamic_lock_screen_enabled") as? Bool ?? true else {
            print("[LockScreenWallpaper] 动态锁屏已关闭，跳过静态图同步")
            return
        }

        guard let container = sharedContainerURL else {
            throw LockScreenError.appGroupNotAvailable
        }

        let originalImageData: Data
        if imageURL.isFileURL {
            guard FileManager.default.fileExists(atPath: imageURL.path) else {
                throw LockScreenError.fileNotFound
            }
            originalImageData = try Data(contentsOf: imageURL)
        } else {
            let (data, _) = try await URLSession.shared.data(from: imageURL)
            originalImageData = data
        }

        let imageDir = container.appendingPathComponent(imageDirName, isDirectory: true)
        try FileManager.default.createDirectory(at: imageDir, withIntermediateDirectories: true)

        let preparedImage = prepareStaticLockScreenImageData(originalImageData, sourceURL: imageURL)
        let imageData = preparedImage.data
        let ext = preparedImage.fileExtension
        var lastPath: String?
        var deployedImagePaths: [UInt32: String] = [:]
        for displayID in displayIDs {
            let sourceID = Self.displayInstanceID(displayID)
            let destURL = imageDir.appendingPathComponent("\(sourceID).\(ext)")
            cleanupCachedImages(sourceID: sourceID, in: imageDir)
            try imageData.write(to: destURL, options: .atomic)
            writeThumbnail(imageData: imageData, thumbnailID: sourceID)
            WallpaperExtensionSocketServer.shared.registerLocalDecodeVideo(videoID: sourceID, videoURL: destURL)
            lastPath = destURL.path
            deployedImagePaths[displayID] = destURL.path
            print("[LockScreenWallpaper] 🖼️ 已部署静态图 display=\(displayID) source=\(destURL.lastPathComponent)")
        }

        if let lastPath {
            // 先持久化再发送热切换命令。若扩展此时刚好重启或 context 尚未创建，
            // 后续 acquire 也会从 prefs 读取到这张静态图，而不会回退到旧视频。
            let prefsURL = container.appendingPathComponent(prefsFileName)
            var prefs = (try? JSONDecoder().decode(PrefsFile.self, from: Data(contentsOf: prefsURL))) ?? PrefsFile()
            prefs.userPaused = false
            prefs.alwaysPauseDesktop = false
            // Legacy global: 取最后写入的一路（向后兼容旧扩展）
            prefs.currentVideoPath = nil
            prefs.currentImagePath = lastPath
            prefs.currentRealtimeSourceKind = nil
            // Per-display: 本批 displayIDs 全部指向该图片
            var imageMap = prefs.currentImagePaths ?? [:]
            var sourceMap = prefs.currentImageSourceURLs ?? [:]
            for (displayID, path) in deployedImagePaths {
                imageMap["display-\(displayID)"] = path
                sourceMap["display-\(displayID)"] = imageURL.absoluteString
                staticImageSourceURLByDisplayID[displayID] = imageURL
            }
            prefs.currentImagePaths = imageMap
            prefs.currentImageSourceURLs = sourceMap
            // 该图片覆盖这些屏的视频路径
            prefs.currentVideoPaths = prefs.currentVideoPaths?.filter { key, _ in
                !displayIDs.contains { "display-\($0)" == key }
            }
            let data = try JSONEncoder().encode(prefs)
            try data.write(to: prefsURL, options: .atomic)
            currentMirroringSourcePath = lastPath
            staticImageSourceChangeSignal &+= 1
        }

        // 实例目录刷新和命令消费之间不要提前广播 prefsChanged，确保扩展轮询命令时
        // Socket 路径注册与 per-display prefs 都已经完整可见。
        syncInstanceCatalogToSocketServer(notify: false)
        for displayID in deployedImagePaths.keys.sorted() {
            let sourceID = Self.displayInstanceID(displayID)
            WallpaperExtensionSocketServer.shared.enqueueCommand(
                IPCCommand(action: "switch_image", videoID: sourceID, displayID: displayID)
            )
        }
        notifyExtensionPrefsChanged()
    }

    /// 让已激活的锁屏实例切换到当前桌面视频。扩展侧本地解码该视频，不再等待 App 逐帧推送。
    /// 让已激活的锁屏实例切换到当前桌面视频。扩展侧本地解码该视频，不再等待 App 逐帧推送。
    /// - Parameter generation: 视频同步世代号，用于丢弃过期 Task 的命令。
    func switchActiveInstancesToLocalDecode(videoURL: URL, videoID: String, displayIDs: [UInt32], generation: UInt64 = 0) async {
        // 快速检查：如果世代已过期，跳过整个流程
        guard generation == 0 || WallpaperExtensionSocketServer.isCurrentGeneration(generation) else {
            print("[LockScreenWallpaper] ⏭️ switchActiveInstancesToLocalDecode 跳过过期世代 (gen=\(generation)) display=\(displayIDs)")
            return
        }

        do {
            // 把 displayIDs 传给 cacheMirroringSource，写入 per-display 路径映射，
            // 使扩展在冷启动 acquire 时能按屏各自选到正确的视频。
            try await cacheMirroringSource(videoURL: videoURL, videoID: videoID, displayIDs: displayIDs, notify: false)
        } catch {
            print("[LockScreenWallpaper] ❌ 本地解码视频缓存失败: \(error.localizedDescription)")
            return
        }

        copyVideoThumbnailToDisplayThumbnails(videoID: videoID, displayIDs: displayIDs)
        syncInstanceCatalogToSocketServer(notify: false)

        // 再次检查世代（file I/O 期间可能又有新切换）
        guard generation == 0 || WallpaperExtensionSocketServer.isCurrentGeneration(generation) else {
            print("[LockScreenWallpaper] ⏭️ switchActiveInstancesToLocalDecode 跳过过期命令 (gen=\(generation)) display=\(displayIDs) video=\(videoID)")
            return
        }

        for displayID in displayIDs {
            WallpaperExtensionSocketServer.shared.enqueueCommand(
                IPCCommand(action: "switch_video", videoID: videoID, displayID: displayID),
                generation: generation
            )
        }
        notifyExtensionPrefsChanged()
        print("[LockScreenWallpaper] 🔁 已请求扩展自解码切换 display=\(displayIDs) video=\(videoID) gen=\(generation)")
    }

    /// 清掉历史版本写入的实时帧源标记。当前 Web 锁屏只走静态图链路。
    func clearRealtimeSourceIfNeeded(notify: Bool = true) {
        guard isAvailable, let container = sharedContainerURL else { return }
        let prefsURL = container.appendingPathComponent(prefsFileName)
        guard let data = try? Data(contentsOf: prefsURL),
              var prefs = try? JSONDecoder().decode(PrefsFile.self, from: data),
              prefs.currentRealtimeSourceKind != nil else {
            return
        }
        prefs.currentRealtimeSourceKind = nil
        if let encoded = try? JSONEncoder().encode(prefs) {
            try? encoded.write(to: prefsURL, options: .atomic)
        }
        if notify {
            notifyExtensionPrefsChanged()
        }
        print("[LockScreenWallpaper] ✅ 已清理实时锁屏帧源标记")
    }

    /// 清空当前锁屏镜像帧源缓存。
    /// 不触碰用户在系统设置里手动选择的显示器实例。
    func clearMirroringSourceCache(notify: Bool = true) {
        guard isAvailable else { return }

        guard let container = sharedContainerURL else { return }

        // 清空视频目录
        let videoDir = container.appendingPathComponent(videoDirName, isDirectory: true)
        try? FileManager.default.removeItem(at: videoDir)
        let imageDir = container.appendingPathComponent(imageDirName, isDirectory: true)
        try? FileManager.default.removeItem(at: imageDir)

        // 更新偏好设置
        let prefs = PrefsFile(userPaused: false, alwaysPauseDesktop: false, currentVideoPath: nil, currentImagePath: nil, currentRealtimeSourceKind: nil)
        let prefsURL = container.appendingPathComponent(prefsFileName)
        if let data = try? JSONEncoder().encode(prefs) {
            try? data.write(to: prefsURL, options: .atomic)
        }

        currentMirroringSourcePath = nil
        deployedVideoIDs.removeAll()
        staticImageSourceURLByDisplayID.removeAll()
        staticImageSourceChangeSignal &+= 1
        if #available(macOS 26.0, *) {
            WallpaperExtensionSocketServer.shared.clearDisplayVideos()
        }

        if notify {
            notifyExtensionPrefsChanged()
        }

        print("[LockScreenWallpaper] ✅ 已清空锁屏镜像帧源缓存")
    }

    /// 暂停/恢复锁屏壁纸播放（用户手动控制）
    func setPaused(_ paused: Bool) {
        guard isAvailable else { return }
        guard let container = sharedContainerURL else { return }

        let prefsURL = container.appendingPathComponent(prefsFileName)
        var prefs = (try? JSONDecoder().decode(PrefsFile.self, from: Data(contentsOf: prefsURL))) ?? PrefsFile()
        prefs.userPaused = paused
        if let data = try? JSONEncoder().encode(prefs) {
            try? data.write(to: prefsURL, options: .atomic)
        }
        notifyExtensionPrefsChanged()
    }

    /// 设置是否仅在锁屏时播放（桌面暂停）
    func setAlwaysPauseDesktop(_ pause: Bool) {
        guard isAvailable else { return }
        guard let container = sharedContainerURL else { return }

        let prefsURL = container.appendingPathComponent(prefsFileName)
        var prefs = (try? JSONDecoder().decode(PrefsFile.self, from: Data(contentsOf: prefsURL))) ?? PrefsFile()
        prefs.alwaysPauseDesktop = pause
        if let data = try? JSONEncoder().encode(prefs) {
            try? data.write(to: prefsURL, options: .atomic)
        }
        notifyExtensionPrefsChanged()
    }

    /// 设置指定显示器的暂停状态（per-display pause）
    func setDisplayPaused(_ paused: Bool, forDisplayID displayID: UInt32) {
        guard isAvailable else { return }
        guard let container = sharedContainerURL else { return }

        let prefsURL = container.appendingPathComponent(prefsFileName)
        var prefs = (try? JSONDecoder().decode(PrefsFile.self, from: Data(contentsOf: prefsURL))) ?? PrefsFile()
        if paused {
            if prefs.pausedDisplayIDs == nil { prefs.pausedDisplayIDs = [] }
            prefs.pausedDisplayIDs?.insert(displayID)
        } else {
            prefs.pausedDisplayIDs?.remove(displayID)
        }
        if let data = try? JSONEncoder().encode(prefs) {
            try? data.write(to: prefsURL, options: .atomic)
        }
        notifyExtensionPrefsChanged()
    }

    /// 查询指定显示器是否处于暂停状态
    func isDisplayPaused(_ displayID: UInt32) -> Bool {
        guard isAvailable else { return false }
        guard let container = sharedContainerURL else { return false }
        let prefsURL = container.appendingPathComponent(prefsFileName)
        guard let data = try? Data(contentsOf: prefsURL),
              let prefs = try? JSONDecoder().decode(PrefsFile.self, from: data) else { return false }
        return prefs.pausedDisplayIDs?.contains(displayID) ?? false
    }

    /// 设置指定显示器的静音状态（per-display mute）
    func setDisplayMuted(_ muted: Bool, forDisplayID displayID: UInt32) {
        guard isAvailable else { return }
        guard let container = sharedContainerURL else { return }

        let prefsURL = container.appendingPathComponent(prefsFileName)
        var prefs = (try? JSONDecoder().decode(PrefsFile.self, from: Data(contentsOf: prefsURL))) ?? PrefsFile()
        if muted {
            if prefs.mutedDisplayIDs == nil { prefs.mutedDisplayIDs = [] }
            prefs.mutedDisplayIDs?.insert(displayID)
        } else {
            prefs.mutedDisplayIDs?.remove(displayID)
        }
        if let data = try? JSONEncoder().encode(prefs) {
            try? data.write(to: prefsURL, options: .atomic)
        }
        notifyExtensionPrefsChanged()
    }

    // MARK: - Notification Helpers

    /// 通知 Extension 偏好设置已变更
        func notifyExtensionPrefsChanged() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName("com.waifux.app.wallpaper.prefsChanged" as CFString),
            nil, nil, true
        )
    }

    /// 清理不再需要的旧视频，保留 keepIDs 中的所有视频
    private func cleanupOldVideos(in directory: URL, keeping keepIDs: Set<String>) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files {
            let name = file.deletingPathExtension().lastPathComponent
            if !keepIDs.contains(name) {
                try? fm.removeItem(at: file)
                print("[LockScreenWallpaper] 🗑️ 清理旧视频: \(name)")
            }
        }
    }

    private func prepareStaticLockScreenImageData(_ data: Data, sourceURL: URL) -> (data: Data, fileExtension: String) {
        let fallbackExtension = normalizedImageExtension(from: sourceURL)
        guard UserDefaults.standard.object(forKey: "auto_remove_video_letterbox") as? Bool ?? false,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let cropRect = detectBlackBorderCropRect(in: image) else {
            return (data, fallbackExtension)
        }

        guard let croppedImage = image.cropping(to: cropRect),
              let encodedData = encodeLockScreenImage(croppedImage, preferredExtension: fallbackExtension) else {
            return (data, fallbackExtension)
        }

        print("[LockScreenWallpaper] 🖼️ 静态锁屏图已自动去黑边 crop=\(Int(cropRect.width))x\(Int(cropRect.height))")
        return (encodedData, normalizedOutputExtension(fallbackExtension))
    }

    private func encodeLockScreenImage(_ image: CGImage, preferredExtension: String) -> Data? {
        let outputUTI: CFString
        switch preferredExtension.lowercased() {
        case "jpg", "jpeg":
            outputUTI = UTType.jpeg.identifier as CFString
        default:
            outputUTI = UTType.png.identifier as CFString
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, outputUTI, 1, nil) else {
            return nil
        }

        let options: [CFString: Any] = outputUTI == UTType.jpeg.identifier as CFString
            ? [kCGImageDestinationLossyCompressionQuality: 0.95]
            : [:]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return data as Data
    }

    private func normalizedOutputExtension(_ preferredExtension: String) -> String {
        switch preferredExtension.lowercased() {
        case "jpg", "jpeg":
            return "jpg"
        default:
            return "png"
        }
    }

    private func detectBlackBorderCropRect(in image: CGImage) -> CGRect? {
        let width = image.width
        let height = image.height
        guard width > 16, height > 16 else { return nil }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        let didDraw = pixels.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress,
                  let ctx = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard didDraw else { return nil }

        let blackLumaThreshold: UInt8 = 28
        let edgeBlackRatioThreshold = 0.94
        let maxRemovedArea = 0.36
        let minRemovedArea = 0.01
        let minPairInsetRatio = 0.012
        let overscanPixels = 2

        func isBlackPixel(at index: Int) -> Bool {
            guard index + 2 < pixels.count else { return false }
            let r = pixels[index]
            let g = pixels[index + 1]
            let b = pixels[index + 2]
            let luma = (UInt16(r) * 54 + UInt16(g) * 183 + UInt16(b) * 19) >> 8
            return luma <= blackLumaThreshold
        }

        func blackRatioInRow(_ y: Int) -> Double {
            let step = max(1, width / 360)
            var black = 0
            var total = 0
            let row = y * bytesPerRow
            var x = 0
            while x < width {
                if isBlackPixel(at: row + x * 4) { black += 1 }
                total += 1
                x += step
            }
            return total > 0 ? Double(black) / Double(total) : 0
        }

        func blackRatioInColumn(_ x: Int) -> Double {
            let step = max(1, height / 360)
            var black = 0
            var total = 0
            var y = 0
            while y < height {
                if isBlackPixel(at: y * bytesPerRow + x * 4) { black += 1 }
                total += 1
                y += step
            }
            return total > 0 ? Double(black) / Double(total) : 0
        }

        func edgeInset(limit: Int, ratioAt: (Int) -> Double) -> Int {
            var inset = 0
            for i in 0..<limit {
                if ratioAt(i) >= edgeBlackRatioThreshold {
                    inset += 1
                } else {
                    break
                }
            }
            return inset
        }

        let top = edgeInset(limit: height / 2) { blackRatioInRow($0) }
        let bottom = edgeInset(limit: height / 2) { blackRatioInRow(height - 1 - $0) }
        let left = edgeInset(limit: width / 2) { blackRatioInColumn($0) }
        let right = edgeInset(limit: width / 2) { blackRatioInColumn(width - 1 - $0) }

        let horizontalPair = Double(top + bottom) / Double(height) >= minPairInsetRatio
            && top > 0 && bottom > 0
        let verticalPair = Double(left + right) / Double(width) >= minPairInsetRatio
            && left > 0 && right > 0
        guard horizontalPair || verticalPair else { return nil }

        let rawCropTop = horizontalPair ? top : 0
        let rawCropBottom = horizontalPair ? bottom : 0
        let rawCropLeft = verticalPair ? left : 0
        let rawCropRight = verticalPair ? right : 0
        let rawCropW = max(1, width - rawCropLeft - rawCropRight)
        let rawCropH = max(1, height - rawCropTop - rawCropBottom)
        let removedArea = 1.0 - (Double(rawCropW * rawCropH) / Double(width * height))
        guard removedArea >= minRemovedArea, removedArea <= maxRemovedArea else { return nil }

        let cropTop = horizontalPair ? min(height - 1, rawCropTop + overscanPixels) : 0
        let cropBottom = horizontalPair ? min(height - cropTop - 1, rawCropBottom + overscanPixels) : 0
        let cropLeft = verticalPair ? min(width - 1, rawCropLeft + overscanPixels) : 0
        let cropRight = verticalPair ? min(width - cropLeft - 1, rawCropRight + overscanPixels) : 0
        let cropW = max(1, width - cropLeft - cropRight)
        let cropH = max(1, height - cropTop - cropBottom)

        return CGRect(x: cropLeft, y: cropTop, width: cropW, height: cropH)
    }

    // MARK: - Display Instances

    /// 当前显示器对应的锁屏实例目录。
    /// 用户在系统设置里手动为每块显示器选择一次这些实例，之后实例只负责接收对应显示器的推帧。
    func currentDisplayInstances() -> [DisplayInstance] {
        NSScreen.screens.compactMap { screen in
            guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            let displayID = screenNumber.uint32Value
            let instanceID = "display-\(displayID)"
            let thumbnailPath = posterThumbnailPath(for: screen)
            return DisplayInstance(
                id: instanceID,
                displayID: displayID,
                name: screen.localizedName,
                thumbnailPath: thumbnailPath
            )
        }
        .sorted { lhs, rhs in
            if lhs.name == rhs.name { return lhs.displayID < rhs.displayID }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    func syncDisplayInstancesToSocketServer() {
        guard #available(macOS 26.0, *), isAvailable else { return }

        let instances = currentDisplayInstances()
        persistDisplayInstances(instances)

        let videos = instances.map { instance in
            IPCVideoInfo(
                id: instance.id,
                name: instance.name,
                videoPath: "",
                thumbnailPath: instance.thumbnailPath ?? ""
            )
        }
        WallpaperExtensionSocketServer.shared.updateVideos(videos)
        notifyExtensionPrefsChanged()
        print("[LockScreenWallpaper] 🖥️ 已同步 \(instances.count) 个显示器实例到 Socket 服务端")
    }

    func loadDisplayInstances() -> [DisplayInstance] {
        guard let url = displayInstancesURL,
              let data = try? Data(contentsOf: url),
              let instances = try? JSONDecoder().decode([DisplayInstance].self, from: data) else {
            return currentDisplayInstances()
        }
        return instances
    }

    /// 彻底清理锁屏实例：清除视频缓存、偏好设置、显示器实例列表、推送管线。
    /// 用户不再使用锁屏动态壁纸时调用。
    func clearLockScreenInstances() {
        guard isAvailable else { return }

        // 1. 清空视频缓存和偏好，但先不要通知扩展，避免扩展在“半清理状态”下抢先刷新。
        clearMirroringSourceCache(notify: false)

        // 2. 清空 Socket 服务端所有注册状态
        WallpaperExtensionSocketServer.shared.clearLocalDecodeVideos()
        WallpaperExtensionSocketServer.shared.clearSurfaces()
        WallpaperExtensionSocketServer.shared.updateVideos([])

        // 3. 删除显示器实例列表文件
        if let url = displayInstancesURL {
            try? FileManager.default.removeItem(at: url)
        }

        // 4. 重置 VideoWallpaperManager 的扩展活跃状态
        VideoWallpaperManager.shared.clearExtensionState()

        // 5. 自动关闭设置中的动态锁屏开关
        UserDefaults.standard.set(false, forKey: "dynamic_lock_screen_enabled")

        // 6. 最后统一通知扩展刷新（此时所有状态已清理完毕）
        notifyExtensionPrefsChanged()

        print("[LockScreenWallpaper] ✅ 已彻底清理锁屏实例")
    }

    private func persistDisplayInstances(_ instances: [DisplayInstance]) {
        guard let url = displayInstancesURL,
              let data = try? JSONEncoder().encode(instances) else {
            return
        }
        try? data.write(to: url, options: .atomic)
    }

    private func posterThumbnailPath(for screen: NSScreen) -> String? {
        let thumbDir = sharedContainerURL?.appendingPathComponent("WallpaperCache/thumbnails")
        guard let thumbDir else { return nil }

        // 1. 按显示器实例查找。文件名带版本，避免系统设置按相同 path 缓存旧预览。
        let screenPrefixes = [
            "display-\(screen.wallpaperScreenIdentifier)",
            "\(screen.wallpaperScreenIdentifier)"
        ]
        for prefix in screenPrefixes {
            if let path = latestThumbnailPath(in: thumbDir, prefix: prefix) {
                return path
            }
        }

        // 2. 按当前桌面视频的 videoID 查找（generateThumbnail 使用 videoID 命名）
        if let videoURL = VideoWallpaperManager.shared.videoURL(for: screen),
           videoURL.isFileURL {
            let videoID = videoURL.deletingPathExtension().lastPathComponent
            let videoThumbURL = thumbDir.appendingPathComponent("\(videoID).jpg")
            if FileManager.default.fileExists(atPath: videoThumbURL.path) {
                return videoThumbURL.path
            }
        }

        return nil
    }

    // MARK: - 缩略图

    /// 生成视频的 JPEG 缩略图并写入共享容器供扩展读取
    private func generateThumbnail(for videoURL: URL, videoID: String) {
        guard let container = sharedContainerURL else { return }
        let thumbDir = container.appendingPathComponent("WallpaperCache/thumbnails")
        try? FileManager.default.createDirectory(at: thumbDir, withIntermediateDirectories: true)
        let thumbURL = thumbDir.appendingPathComponent("\(videoID).jpg")

        if FileManager.default.fileExists(atPath: thumbURL.path) { return }

        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 270)

        var actualTime: CMTime = .zero
        guard let cgImage = try? generator.copyCGImage(at: .zero, actualTime: &actualTime) else {
            print("[LockScreenWallpaper] ⚠️ 缩略图生成失败: \(videoURL.lastPathComponent)")
            return
        }

        guard let dest = CGImageDestinationCreateWithURL(thumbURL as CFURL, "public.jpeg" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        if CGImageDestinationFinalize(dest) {
            print("[LockScreenWallpaper] ✅ 缩略图已生成: \(thumbURL.lastPathComponent)")
        }
    }

    private static func displayInstanceID(_ displayID: UInt32) -> String {
        "display-\(displayID)"
    }

    private func restoreStaticImageSourceURLs() {
        guard let container = sharedContainerURL else { return }

        let prefsURL = container.appendingPathComponent(prefsFileName)
        guard let data = try? Data(contentsOf: prefsURL),
              let prefs = try? JSONDecoder().decode(PrefsFile.self, from: data),
              let sourceURLs = prefs.currentImageSourceURLs else {
            return
        }

        staticImageSourceURLByDisplayID = sourceURLs.reduce(into: [:]) { result, entry in
            let (key, value) = entry
            guard key.hasPrefix("display-"),
                  let displayID = UInt32(key.dropFirst("display-".count)),
                  let url = URL(string: value) else {
                return
            }
            result[displayID] = url
        }
    }

    private func normalizedImageExtension(from url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if ["jpg", "jpeg", "png", "heic", "webp", "tiff", "bmp"].contains(ext) {
            return ext == "jpeg" ? "jpg" : ext
        }
        return "jpg"
    }

    private func cleanupCachedImages(sourceID: String, in imageDir: URL) {
        for ext in ["jpg", "jpeg", "png", "heic", "webp", "tiff", "bmp"] {
            try? FileManager.default.removeItem(at: imageDir.appendingPathComponent("\(sourceID).\(ext)"))
        }
    }

    private func thumbnailDirectory() -> URL? {
        guard let container = sharedContainerURL else { return nil }
        let thumbDir = container.appendingPathComponent("WallpaperCache/thumbnails")
        try? FileManager.default.createDirectory(at: thumbDir, withIntermediateDirectories: true)
        return thumbDir
    }

    private func writeThumbnail(imageData: Data, thumbnailID: String) {
        guard let thumbDir = thumbnailDirectory(),
              let image = NSImage(data: imageData),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let dest = CGImageDestinationCreateWithURL(
                versionedThumbnailURL(prefix: thumbnailID, in: thumbDir) as CFURL,
                "public.jpeg" as CFString,
                1,
                nil
              ) else {
            print("[LockScreenWallpaper] ⚠️ 静态图缩略图生成失败: \(thumbnailID)")
            return
        }
        cleanupCachedThumbnails(prefix: thumbnailID, in: thumbDir)
        CGImageDestinationAddImage(dest, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        if CGImageDestinationFinalize(dest) {
            print("[LockScreenWallpaper] ✅ 静态图缩略图已写入: \(thumbnailID)")
        }
    }

    private func copyVideoThumbnailToDisplayThumbnails(videoID: String, displayIDs: [UInt32]) {
        guard let thumbDir = thumbnailDirectory() else { return }
        let sourceURL = thumbDir.appendingPathComponent("\(videoID).jpg")
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { return }

        for displayID in displayIDs {
            let prefix = Self.displayInstanceID(displayID)
            cleanupCachedThumbnails(prefix: prefix, in: thumbDir)
            let destURL = versionedThumbnailURL(prefix: prefix, in: thumbDir)
            do {
                try FileManager.default.copyItem(at: sourceURL, to: destURL)
                print("[LockScreenWallpaper] ✅ 已刷新显示器实例缩略图: \(destURL.lastPathComponent)")
            } catch {
                print("[LockScreenWallpaper] ⚠️ 显示器实例缩略图复制失败: \(error.localizedDescription)")
            }
        }
    }

    private func versionedThumbnailURL(prefix: String, in thumbDir: URL) -> URL {
        let milliseconds = Int(Date().timeIntervalSince1970 * 1000)
        let suffix = UUID().uuidString.prefix(8)
        return thumbDir.appendingPathComponent("\(prefix)-\(milliseconds)-\(suffix).jpg")
    }

    private func cleanupCachedThumbnails(prefix: String, in thumbDir: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: thumbDir, includingPropertiesForKeys: nil) else {
            return
        }
        for file in files where isThumbnail(file, matching: prefix) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func latestThumbnailPath(in thumbDir: URL, prefix: String) -> String? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: thumbDir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            return nil
        }
        let matches = files.filter { isThumbnail($0, matching: prefix) }
        let latest = matches.max { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if lhsDate == rhsDate {
                return lhs.lastPathComponent < rhs.lastPathComponent
            }
            return lhsDate < rhsDate
        }
        return latest?.path
    }

    private func isThumbnail(_ url: URL, matching prefix: String) -> Bool {
        guard url.pathExtension.lowercased() == "jpg" else { return false }
        let name = url.deletingPathExtension().lastPathComponent
        return name == prefix || name.hasPrefix("\(prefix)-")
    }

    // MARK: - Socket IPC 集成

    /// 将当前显示器实例目录同步到 Socket IPC 服务端。
    func syncInstanceCatalogToSocketServer(notify: Bool = true) {
        guard #available(macOS 26.0, *) else { return }
        guard UserDefaults.standard.object(forKey: "dynamic_lock_screen_enabled") as? Bool ?? true else {
            print("[LockScreenWallpaper] syncInstanceCatalogToSocketServer: 动态锁屏已关闭，跳过")
            return
        }
        // 始终使用 currentDisplayInstances() 获取最新缩略图路径，而非从缓存文件读取
        let instances = currentDisplayInstances()
        persistDisplayInstances(instances)
        let instanceInfos = instances.map { instance in
            IPCVideoInfo(
                id: instance.id,
                name: instance.name,
                videoPath: "",
                thumbnailPath: instance.thumbnailPath ?? ""
            )
        }
        WallpaperExtensionSocketServer.shared.updateVideos(instanceInfos)
        if notify {
            notifyExtensionPrefsChanged()
        }
        print("[LockScreenWallpaper] 📋 已同步 \(instanceInfos.count) 个显示器实例到 Socket 服务端")
    }

    // MARK: - Types

    private struct PrefsFile: Codable {
        var userPaused: Bool = false
        var alwaysPauseDesktop: Bool = false
        /// Legacy global video path — kept for backward compat with older extensions.
        /// Extension reads per-display paths first, falls back to this.
        var currentVideoPath: String?
        /// Legacy global image path — same as above.
        var currentImagePath: String?
        var currentRealtimeSourceKind: String?
        /// Per-display pause: displayID 集合
        var pausedDisplayIDs: Set<UInt32>?
        /// Per-display mute: displayID 集合
        var mutedDisplayIDs: Set<UInt32>?
        /// Per-display video paths: key = "display-<displayID>", value = file path.
        /// Extension picks the path for its own displayID during acquire, supporting
        /// each screen rendering a different video on cold start.
        var currentVideoPaths: [String: String]?
        /// Per-display image paths: same scheme as currentVideoPaths.
        var currentImagePaths: [String: String]?
        /// Original static image URLs for UI state recovery. The extension ignores this metadata.
        var currentImageSourceURLs: [String: String]?
    }
}

enum LockScreenError: LocalizedError {
    case fileNotFound
    case appGroupNotAvailable
    case copyFailed(String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound: return "视频文件不存在"
        case .appGroupNotAvailable: return "App Group 共享容器不可用"
        case .copyFailed(let msg): return "复制失败: \(msg)"
        }
    }
}
