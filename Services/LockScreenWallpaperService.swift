//  LockScreenWallpaperService.swift
//  WaifuX
//
//  管理锁屏镜像实例的共享状态与偏好同步。
//  仅在 macOS 26.0+ 生效，通过 WallpaperExtensionKit 私有框架实现。
//
//  支持多显示器：每个显示器可以部署不同的视频，扩展根据 choiceConfiguration 选择对应视频。

import AVFoundation
import Combine
import CryptoKit
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
    // One predecessor per display, never an unbounded history. Publication can
    // still fail after caching/thumbnail work; its rollback source needs a lease.
    private var rollbackVideoLeases: [UInt32: (path: String, expires: TimeInterval)] = [:]

    /// 已写入共享容器的视频 ID 集合（兼容旧缓存清理）
    private var deployedVideoIDs: Set<String> = []
    private var sourceRequestIDs: [UInt32: UUID] = [:]

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
        guard !BackgroundRuntimeRole.isIsolatedTest else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    private init() {
        guard BackgroundRuntimeRole.isHelper, !BackgroundRuntimeRole.isIsolatedTest else { return }
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
        guard !BackgroundRuntimeRole.isIsolatedTest else { return }
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
    @discardableResult
    func cacheMirroringSource(videoURL: URL, videoID: String, displayIDs: [UInt32] = [], notify: Bool = true, generation: UInt64 = 0, isCurrent: @escaping @MainActor () -> Bool = { true }) async throws -> UUID? {
        if BackgroundRuntimeRole.isRemoteUI { _ = try await BackgroundRuntimeBridge.request("lock.cacheVideo", ["video": videoURL, "id": videoID, "displays": displayIDs, "notify": notify]); return nil }
        guard isCurrent(), !Task.isCancelled else { throw CancellationError() }

        guard isAvailable else {
            throw LockScreenError.appGroupNotAvailable
        }

        guard WaifuXPreferences.shared.object(forKey: "dynamic_lock_screen_enabled") as? Bool ?? true else {
            throw CancellationError()
        }

        guard videoURL.isFileURL, FileManager.default.fileExists(atPath: videoURL.path) else {
            throw LockScreenError.fileNotFound
        }

        guard let container = sharedContainerURL else {
            throw LockScreenError.appGroupNotAvailable
        }

        let videoDir = container.appendingPathComponent(videoDirName, isDirectory: true)
        let destURL = videoDir.appendingPathComponent("\(videoID).mp4")
        let requestID = UUID()
        let requestDisplays = displayIDs.isEmpty ? [UInt32(0)] : displayIDs
        for displayID in requestDisplays { sourceRequestIDs[displayID] = requestID }
        @MainActor func checkCurrentRequest() async throws {
            try Task.checkCancellation()
            guard await isCurrent(), requestDisplays.allSatisfy({ sourceRequestIDs[$0] == requestID }),
                  generation == 0 || WallpaperExtensionSocketServer.isCurrentGeneration(generation),
                  WaifuXPreferences.shared.object(forKey: "dynamic_lock_screen_enabled") as? Bool ?? true else {
                throw CancellationError()
            }
        }
        // Cross-volume copies can take seconds. Keep them off Helper's UI and
        // playback thread; only publish the complete file if this request wins.
        let stagedURL = try await Task.detached(priority: .utility) {
            try Self.stageMirroringVideo(videoURL, destination: destURL)
        }.value
        defer {
            if stagedURL != destURL { try? FileManager.default.removeItem(at: stagedURL) }
        }
        try await checkCurrentRequest()
        if stagedURL != destURL {
            if FileManager.default.fileExists(atPath: destURL.path) {
                _ = try FileManager.default.replaceItemAt(destURL, withItemAt: stagedURL)
            } else {
                try FileManager.default.moveItem(at: stagedURL, to: destURL)
            }
        }

        deployedVideoIDs.insert(videoID)

        // 合并写入 prefs（不覆盖其它 displayID 的路径）：
        // 读取现有 prefs → 更新 legacy 全局路径 + 本批 displayIDs 的 per-display 路径 → 原子写回
        let prefsURL = container.appendingPathComponent(prefsFileName)
        var prefs = (try? JSONDecoder().decode(PrefsFile.self, from: Data(contentsOf: prefsURL))) ?? PrefsFile()
        retainRollbackVideoSources(prefs: prefs, displayIDs: requestDisplays)
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
            prefs.precomposedImagePaths = prefs.precomposedImagePaths?.intersection(Set((prefs.currentImagePaths ?? [:]).values))
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

        // 新副本已落盘且已被 prefs 引用（受保护）→ 此时淘汰历史副本最安全：
        // 绝不会删掉扩展正在读的那一份，也不会删掉刚写进去的这一份。
        let protected = Self.applyAppGroupVideoBudget(in: videoDir, prefs: prefs,
            displayInstances: loadDisplayInstances(), rollbackPaths: protectedRollbackVideoPaths(in: container))

        // 先生成缩略图，再同步实例目录，确保封面路径在新目录中立即生效。
        // 缩略图解码在后台线程执行，避免阻塞 MainActor。
        // 缩略图淘汰与生成同批在后台完成：这一目录只按 videoID 命名、跨 ID 永不回收，
        // 上千壁纸轮换时会一直涨，必须和视频副本一样封顶。
        let protectedThumbnails = protected
        await Task.detached(priority: .userInitiated) {
            Self.generateThumbnail(in: container, videoURL: destURL, videoID: videoID)
            Self.applyAppGroupThumbnailBudget(in: container, protectedPaths: protectedThumbnails)
        }.value
        try await checkCurrentRequest()
        // 更新显示器实例目录（此时缩略图已就绪，posterThumbnailPath 能查到最新文件）
        syncInstanceCatalogToSocketServer(notify: notify)
        WallpaperExtensionSocketServer.shared.registerLocalDecodeVideo(videoID: videoID, videoURL: destURL)

        // 再通知 Extension 刷新（此时 SocketServer 已有最新数据）
        if notify {
            notifyExtensionPrefsChanged()
        }

        print("[LockScreenWallpaper] ✅ 已更新锁屏镜像帧源缓存: \(destURL.lastPathComponent) display=\(displayIDs)")
        return requestID
    }

    // Swift 6.4 crashes splitting the throwing detached coroutine in Release.
    // Keep all throwing work synchronous and out of the nonthrowing worker's body.
    @inline(never)
    private nonisolated static func prepareStaticImagePublication(
        originalImageData: Data, sourceURL: URL, alreadyCropped: Bool,
        displayIDs: [UInt32], directory: URL, requestID: UUID
    ) -> Result<(staged: LockScreenImagePublication.Staged, thumbnailData: Data?), Error> {
        Result {
            // Scene transition frames already include their viewport/letterbox.
            // Trimming black borders or applying crop again would change the frame.
            let image: (data: Data, fileExtension: String)
            if alreadyCropped {
                image = (originalImageData, sourceURL.pathExtension.lowercased() == "png" ? "png" : "jpg")
            } else {
                image = prepareStaticLockScreenImageData(originalImageData, sourceURL: sourceURL)
            }
            let staged = try LockScreenImagePublication.stage(
                data: image.data, fileExtension: image.fileExtension, displayIDs: displayIDs,
                directory: directory, requestID: requestID)
            return (staged: staged, thumbnailData: staticThumbnailJPEGData(imageData: image.data))
        }
    }

    /// Existing video/Web/static callers still require actual source readiness when requested.
    func cacheStaticImageSource(
        imageURL: URL, displayIDs: [UInt32], alreadyCropped: Bool = false,
        waitForReady: Bool = false, readyTimeout: TimeInterval = 12,
        isCurrent: @escaping @MainActor () -> Bool = { true }
    ) async throws {
        // Preserve the legacy UI proxy's delegation-only contract; it never had frame evidence.
        if BackgroundRuntimeRole.isRemoteUI {
            _ = try await BackgroundRuntimeBridge.request("lock.cacheImage", ["image": imageURL, "displays": displayIDs])
            return
        }
        let results = try await publishStaticImageSource(
            imageURL: imageURL, displayIDs: displayIDs, alreadyCropped: alreadyCropped,
            waitForReady: waitForReady, readyTimeout: readyTimeout, isCurrent: isCurrent)
        if waitForReady {
            guard results.values.allSatisfy({ $0 == .ready }) else { throw LockScreenError.sourceReadyTimeout }
            VideoWallpaperManager.shared.holdDesktopSamplingAfterExtensionPush(displayIDs: displayIDs)
        }
    }

    /// Publish durably; pending means the system has not consumed this source, not rendered success.
    func publishStaticImageSource(
        imageURL: URL, displayIDs: [UInt32], alreadyCropped: Bool = false,
        waitForReady: Bool = false, readyTimeout: TimeInterval = 12,
        isCurrent: @escaping @MainActor () -> Bool = { true }
    ) async throws -> [UInt32: WallpaperSourceReadiness] {
        if BackgroundRuntimeRole.isRemoteUI {
            _ = try await BackgroundRuntimeBridge.request("lock.cacheImage", ["image": imageURL, "displays": displayIDs])
            return Dictionary(uniqueKeysWithValues: Set(displayIDs).map { ($0, .pending) })
        }
        guard isCurrent(), !Task.isCancelled else { throw CancellationError() }

        guard isAvailable else {
            if waitForReady { throw LockScreenError.appGroupNotAvailable }
            print("[LockScreenWallpaper] 功能不可用（需 macOS 26+）")
            return [:]
        }

        guard WaifuXPreferences.shared.object(forKey: "dynamic_lock_screen_enabled") as? Bool ?? true else {
            if waitForReady { throw CancellationError() }
            print("[LockScreenWallpaper] 动态锁屏已关闭，跳过静态图同步")
            return [:]
        }

        guard let container = sharedContainerURL else {
            throw LockScreenError.appGroupNotAvailable
        }

        // Supersede pending video copies for these displays before yielding.
        let requestID = UUID()
        for displayID in displayIDs { sourceRequestIDs[displayID] = requestID }
        @MainActor func checkCurrentRequest() async throws {
            try Task.checkCancellation()
            guard await isCurrent(), displayIDs.allSatisfy({ sourceRequestIDs[$0] == requestID }),
                  WaifuXPreferences.shared.object(forKey: "dynamic_lock_screen_enabled") as? Bool ?? true else {
                throw CancellationError()
            }
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

        guard !displayIDs.isEmpty else { return [:] }
        let imageDir = container.appendingPathComponent(imageDirName, isDirectory: true)
        let targetDisplayIDs = Set(displayIDs).sorted()
        // Crop, stage and decode the actual written bytes off main. The same
        // decoder is used by the extension; unsupported input cannot replace prefs.
        // Pass errors across the suspension as values, not a throwing coroutine.
        let preparation = await Task.detached(priority: .userInitiated) {
            Self.prepareStaticImagePublication(
                originalImageData: originalImageData, sourceURL: imageURL,
                alreadyCropped: alreadyCropped, displayIDs: targetDisplayIDs,
                directory: imageDir, requestID: requestID)
        }.value
        let prepared = try preparation.get()
        var committed = false
        defer { if !committed { LockScreenImagePublication.discard(prepared.staged) } }
        // No await from the final request check through prefs publication and
        // registration: another display's latest map must never be overwritten.
        try await checkCurrentRequest()
        let prefsURL = container.appendingPathComponent(prefsFileName)
        // Same recovery as the video path: an unreadable file must not block
        // every later publication; validated files are still staged first.
        var prefs = (try? JSONDecoder().decode(PrefsFile.self, from: Data(contentsOf: prefsURL))) ?? PrefsFile()
        retainRollbackVideoSources(prefs: prefs, displayIDs: targetDisplayIDs)
        var protectedPaths = Set((prefs.currentImagePaths ?? [:]).values)
        if let previous = prefs.currentImagePath { protectedPaths.insert(previous) }
        var imageMap = prefs.currentImagePaths ?? [:]
        var sourceMap = prefs.currentImageSourceURLs ?? [:]
        var precomposedPaths = prefs.precomposedImagePaths ?? []
        for displayID in targetDisplayIDs {
            if let previous = imageMap["display-\(displayID)"] { precomposedPaths.remove(previous) }
            guard let url = prepared.staged.filesByDisplay[displayID] else { continue }
            imageMap["display-\(displayID)"] = url.path
            sourceMap["display-\(displayID)"] = imageURL.absoluteString
            if alreadyCropped { precomposedPaths.insert(url.path) }
        }
        prefs.userPaused = false
        prefs.alwaysPauseDesktop = false
        prefs.currentVideoPath = nil
        prefs.currentImagePath = targetDisplayIDs.last.flatMap { prepared.staged.filesByDisplay[$0]?.path }
        prefs.currentRealtimeSourceKind = nil
        prefs.currentImagePaths = imageMap
        prefs.currentImageSourceURLs = sourceMap
        prefs.precomposedImagePaths = precomposedPaths.intersection(Set(imageMap.values))
        prefs.currentVideoPaths = prefs.currentVideoPaths?.filter { key, _ in
            !targetDisplayIDs.contains { "display-\($0)" == key }
        }
        try JSONEncoder().encode(prefs).write(to: prefsURL, options: .atomic)
        committed = true
        currentMirroringSourcePath = prefs.currentImagePath
        let thumbDir = thumbnailDirectory()
        for displayID in targetDisplayIDs {
            if let data = prepared.thumbnailData, let thumbDir {
                Self.writeThumbnailData(data, thumbnailID: Self.displayInstanceID(displayID), thumbDir: thumbDir)
            }
            staticImageSourceURLByDisplayID[displayID] = imageURL
            guard let url = prepared.staged.filesByDisplay[displayID] else { continue }
            WallpaperExtensionSocketServer.shared.registerLocalDecodeVideo(
                videoID: Self.displayInstanceID(displayID), videoURL: url)
            print("[LockScreenWallpaper] 🖼️ 已验证并部署静态图 display=\(displayID) source=\(url.lastPathComponent)")
        }
        staticImageSourceChangeSignal &+= 1
        syncInstanceCatalogToSocketServer(notify: false)
        let readyRequestID = UUID().uuidString
        for displayID in targetDisplayIDs {
            WallpaperExtensionSocketServer.shared.enqueueCommand(
                IPCCommand(action: "switch_image", videoID: Self.displayInstanceID(displayID),
                           displayID: displayID, requestID: readyRequestID))
        }
        notifyExtensionPrefsChanged()
        var results = Dictionary(uniqueKeysWithValues: targetDisplayIDs.map { ($0, WallpaperSourceReadiness.pending) })
        if waitForReady {
            for displayID in targetDisplayIDs {
                try await checkCurrentRequest()
                results[displayID] = await WallpaperExtensionSocketServer.shared.waitForSourceResult(
                    displayID: displayID, requestID: readyRequestID, timeout: readyTimeout)
                try await checkCurrentRequest()
            }
        }
        protectedPaths.formUnion(imageMap.values)
        // Preserve previous/current files and a reader grace period; never unlink
        // the old image before the new source is validated and durably published.
        LockScreenImagePublication.prune(directory: imageDir, displayIDs: targetDisplayIDs, protectedPaths: protectedPaths)
        return results
    }

    /// Returns the exact cache identity, without reconstructing the content-path
    /// digest at a second call site. This is not a frame-ready acknowledgement.
    func publishedVideoIdentity(videoURL: URL, videoID: String) -> String {
        let digest = SHA256.hash(data: Data(videoURL.standardizedFileURL.path.utf8))
        let suffix = digest.prefix(12).map { String(format: "%02x", $0) }.joined()
        return "\(videoID)-\(suffix)"
    }

    /// 让已激活的锁屏实例切换到当前桌面视频。
    /// waitForReady=true 时等待扩展应用完成回执；false 只保证资源已缓存且命令已入队。
    /// - Parameter generation: 视频同步世代号，用于丢弃过期 Task 的命令。
    @discardableResult
    func switchActiveInstancesToLocalDecode(
        videoURL: URL, videoID: String, displayIDs: [UInt32], generation: UInt64 = 0,
        waitForReady: Bool = false, readyTimeout: TimeInterval = 12,
        isCurrent: @escaping @MainActor () -> Bool = { true }
    ) async -> Bool {
        guard let results = await publishLocalDecodeSource(
            videoURL: videoURL, videoID: videoID, displayIDs: displayIDs, generation: generation,
            waitForReady: waitForReady, readyTimeout: readyTimeout, isCurrent: isCurrent) else { return false }
        if waitForReady {
            guard results.values.allSatisfy({ $0 == .ready }) else { return false }
            VideoWallpaperManager.shared.holdDesktopSamplingAfterExtensionPush(displayIDs: displayIDs)
        }
        return true
    }

    func publishLocalDecodeSource(
        videoURL: URL, videoID: String, displayIDs: [UInt32], generation: UInt64 = 0,
        waitForReady: Bool = false, readyTimeout: TimeInterval = 12,
        isCurrent: @escaping @MainActor () -> Bool = { true }
    ) async -> [UInt32: WallpaperSourceReadiness]? {
        guard isCurrent(), !Task.isCancelled, !displayIDs.isEmpty,
              generation == 0 || WallpaperExtensionSocketServer.isCurrentGeneration(generation) else { return nil }
        // Same filenames in different library items must retain distinct cache identities.
        let sourceID = publishedVideoIdentity(videoURL: videoURL, videoID: videoID)
        if BackgroundRuntimeRole.isRemoteUI {
            do {
                _ = try await BackgroundRuntimeBridge.request("lock.cacheVideo", ["video": videoURL, "id": sourceID, "displays": displayIDs, "notify": true])
                return Dictionary(uniqueKeysWithValues: Set(displayIDs).map { ($0, .pending) })
            } catch { return nil }
        }
        let publicationID: UUID
        do {
            guard let cachedRequest = try await cacheMirroringSource(
                videoURL: videoURL, videoID: sourceID, displayIDs: displayIDs,
                notify: false, generation: generation, isCurrent: isCurrent) else { return nil }
            publicationID = cachedRequest
        } catch is CancellationError {
            return nil
        } catch {
            print("[LockScreenWallpaper] ❌ 本地解码视频缓存失败: \(error.localizedDescription)")
            return nil
        }
        @MainActor func publicationIsCurrent() -> Bool {
            isCurrent() && !Task.isCancelled
                && displayIDs.allSatisfy({ sourceRequestIDs[$0] == publicationID })
                && (generation == 0 || WallpaperExtensionSocketServer.isCurrentGeneration(generation))
        }
        guard publicationIsCurrent() else { return nil }
        copyVideoThumbnailToDisplayThumbnails(videoID: sourceID, displayIDs: displayIDs)
        syncInstanceCatalogToSocketServer(notify: false)

        let requestID = UUID().uuidString
        let targetDisplayIDs = Set(displayIDs).sorted()
        for displayID in targetDisplayIDs {
            WallpaperExtensionSocketServer.shared.enqueueCommand(
                IPCCommand(action: "switch_video", videoID: sourceID,
                           displayID: displayID, requestID: requestID), generation: generation)
        }
        notifyExtensionPrefsChanged()
        var results = Dictionary(uniqueKeysWithValues: targetDisplayIDs.map { ($0, WallpaperSourceReadiness.pending) })
        if waitForReady {
            for displayID in targetDisplayIDs {
                guard publicationIsCurrent() else { return nil }
                results[displayID] = await WallpaperExtensionSocketServer.shared.waitForSourceResult(
                    displayID: displayID, requestID: requestID, timeout: readyTimeout)
                guard publicationIsCurrent() else { return nil }
            }
        }
        print("[LockScreenWallpaper] 🔁 已发布扩展自解码源 display=\(displayIDs) video=\(sourceID) gen=\(generation) results=\(results)")
        return results
    }

    /// 清掉历史版本写入的实时帧源标记。当前 Web 锁屏只走静态图链路。
    func clearRealtimeSourceIfNeeded(notify: Bool = true) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("lock.clearRealtime", ["notify": notify]); return }

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
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("lock.clearCache", ["notify": notify]); return }

        sourceRequestIDs.removeAll()

        guard isAvailable else { return }

        guard let container = sharedContainerURL else { return }

        // 清空视频目录
        let videoDir = container.appendingPathComponent(videoDirName, isDirectory: true)
        try? FileManager.default.removeItem(at: videoDir)
        let imageDir = container.appendingPathComponent(imageDirName, isDirectory: true)
        try? FileManager.default.removeItem(at: imageDir)

        // 更新偏好设置。
        // 保留 pauseOnBattery：它是用户开关的镜像，不属于锁屏实例状态，
        // 全量重建时丢弃会让扩展在后续电池供电时继续满帧播放。
        let prefsURL = container.appendingPathComponent(prefsFileName)
        let previousPauseOnBattery = (try? JSONDecoder().decode(PrefsFile.self, from: Data(contentsOf: prefsURL)))?.pauseOnBattery
        var prefs = PrefsFile(userPaused: false, alwaysPauseDesktop: false, currentVideoPath: nil, currentImagePath: nil, currentRealtimeSourceKind: nil)
        prefs.pauseOnBattery = previousPauseOnBattery
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
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("lock.paused", ["paused": paused]); return }

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

    /// 同步「使用电池时暂停动态壁纸」开关给壁纸扩展。
    ///
    /// 只镜像用户开关，不写电池状态：扩展侧的 `PowerMonitor` 自己读取电源与低功耗模式，
    /// 因此 Helper 不在电源切换瞬间时也不会留下 stale 暂停，插电后由扩展自愈。
    /// `forceNotify` 用于电源切换时即使开关值未变也唤醒扩展重算策略。
    func setPauseOnBattery(_ enabled: Bool, forceNotify: Bool = false) {
        guard !BackgroundRuntimeRole.isIsolatedTest else { return }
        if BackgroundRuntimeRole.isRemoteUI {
            BackgroundRuntimeBridge.send("lock.pauseOnBattery", ["enabled": enabled, "forceNotify": forceNotify])
            return
        }
        guard let container = sharedContainerURL else { return }

        let prefsURL = container.appendingPathComponent(prefsFileName)
        // 共享 prefs 不存在时说明扩展还没有被配置过：此时不要创建一份缺字段的文件，
        // 否则会用 App 侧默认值覆盖扩展侧的默认行为（例如 alwaysPauseDesktop）。
        guard FileManager.default.fileExists(atPath: prefsURL.path) else { return }
        var prefs = (try? JSONDecoder().decode(PrefsFile.self, from: Data(contentsOf: prefsURL))) ?? PrefsFile()
        let changed = (prefs.pauseOnBattery ?? false) != enabled
        if changed {
            prefs.pauseOnBattery = enabled
            if let data = try? JSONEncoder().encode(prefs) {
                try? data.write(to: prefsURL, options: .atomic)
            }
        }
        guard changed || forceNotify else { return }
        notifyExtensionPrefsChanged()
    }

    /// 设置是否仅在锁屏时播放（桌面暂停）
    func setAlwaysPauseDesktop(_ pause: Bool) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("lock.desktopPaused", ["paused": pause]); return }

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
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("lock.displayPause", ["paused": paused, "display": displayID]); return }

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
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("lock.displayMuted", ["muted": muted, "display": displayID]); return }

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
        guard !BackgroundRuntimeRole.isIsolatedTest else { return }
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName("com.waifux.app.wallpaper.prefsChanged" as CFString),
            nil, nil, true
        )
    }

    private func retainRollbackVideoSources(prefs: PrefsFile, displayIDs: [UInt32]) {
        let now = ProcessInfo.processInfo.systemUptime
        let live = Set(NSScreen.screens.compactMap {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        }).union([UInt32(0)])
        rollbackVideoLeases = rollbackVideoLeases.filter { $0.value.expires > now && live.contains($0.key) }
        for id in displayIDs {
            let path = id == 0 ? prefs.currentVideoPath : prefs.currentVideoPaths?["display-\(id)"]
            if let path, !path.isEmpty {
                rollbackVideoLeases[id] = (path, now + 300)
            } else {
                rollbackVideoLeases.removeValue(forKey: id)
            }
        }
    }

    private func protectedRollbackVideoPaths(in container: URL) -> Set<String> {
        let now = ProcessInfo.processInfo.systemUptime
        rollbackVideoLeases = rollbackVideoLeases.filter { $0.value.expires > now }
        var paths = Set<String>()
        for lease in rollbackVideoLeases.values {
            let url = URL(fileURLWithPath: lease.path).standardizedFileURL
            paths.insert(url.path)
            paths.insert(container.appendingPathComponent(AppGroupCacheBudget.thumbnailDirectoryName, isDirectory: true)
                .appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".jpg").standardizedFileURL.path)
        }
        return paths
    }

    /// 按总量上限淘汰共享容器里的历史视频副本（清理老的、保留新的）。
    ///
    /// 为什么不能再用「本次会话设过的 ID」当白名单：`deployedVideoIDs` 只在
    /// 进程内累积、跨会话不持久化，于是**常驻 App + 自动轮换**的用户每换一张
    /// 壁纸就多一份真副本（跨卷无法 hard link），上千张壁纸轮换一圈就是几十 G。
    ///
    /// 这里改为语义化保护 + 按 mtime 淘汰：
    /// - `prefs` 引用的路径（当前锁屏/桌面镜像源）**绝不动**，删了扩展立刻黑屏；
    /// - 显示器实例目录引用的缩略图同理；
    /// - 其余按总量上限从最旧的开始删，直到落回上限以内。
    private static func applyAppGroupVideoBudget(
        in videoDir: URL,
        prefs: PrefsFile,
        displayInstances: [DisplayInstance],
        rollbackPaths: Set<String> = []
    ) -> Set<String> {
        let entries = AppGroupCacheBudget.entries(
            in: videoDir,
            extensions: ["mp4", "mov", "m4v"]
        )

        let protected = AppGroupCacheBudget.protectedPaths(
            legacyVideoPath: prefs.currentVideoPath,
            legacyImagePath: prefs.currentImagePath,
            perDisplayVideoPaths: prefs.currentVideoPaths,
            perDisplayImagePaths: prefs.currentImagePaths,
            displayThumbnailPaths: displayInstances.compactMap(\.thumbnailPath)
        ).union(rollbackPaths)
        guard !entries.isEmpty else { return protected }

        let plan = AppGroupCacheBudget.plan(
            entries: entries,
            protectedPaths: protected,
            limitBytes: AppGroupCacheBudget.defaultLimitBytes
        )
        guard !plan.isEmpty else { return protected }

        let fm = FileManager.default
        for entry in plan.evicted {
            // 二次确认：计划生成与实际删除之间可能刚好被 prefs 引用上。
            if protected.contains(entry.url.standardizedFileURL.path) { continue }
            do {
                try fm.removeItem(at: entry.url)
                print("[LockScreenWallpaper] 🗑️ 淘汰旧镜像副本: \(entry.url.lastPathComponent) (\(entry.size) bytes)")
            } catch {
                print("[LockScreenWallpaper] ⚠️ 淘汰旧镜像副本失败 \(entry.url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        print("[LockScreenWallpaper] 📦 共享容器视频缓存: \(entries.count) 项 → 淘汰 \(plan.evicted.count) 项，保留 \(plan.keptBytes) bytes（上限 \(AppGroupCacheBudget.defaultLimitBytes)）")
        return protected
    }

    /// 按缩略图上限淘汰旧缩略图（清理老的、保留新的）。
    ///
    /// `WallpaperCache/thumbnails` 里的文件按 `<videoID>.jpg` 命名，只按 videoID
    /// 去重 —— 换一张壁纸就是一个新文件名，旧文件永不回收。容器实测 204 张里有
    /// 198 张属于这一类，是仅次于视频副本的第二个增长点。
    ///
    /// 保护集合沿用视频那份（含当前显示器实例的 `thumbnailPath`）：
    /// 扩展会通过实例目录取 poster，删掉正在用的那张会让锁屏封面失效。
    private nonisolated static func applyAppGroupThumbnailBudget(in container: URL, protectedPaths: Set<String>) {
        let thumbDir = container.appendingPathComponent(AppGroupCacheBudget.thumbnailDirectoryName, isDirectory: true)
        let entries = AppGroupCacheBudget.entries(in: thumbDir, extensions: ["jpg", "jpeg", "png"])
        guard !entries.isEmpty else { return }

        let plan = AppGroupCacheBudget.plan(
            entries: entries,
            protectedPaths: protectedPaths,
            limitBytes: AppGroupCacheBudget.thumbnailLimitBytes
        )
        guard !plan.isEmpty else { return }

        let fm = FileManager.default
        var removed = 0
        for entry in plan.evicted {
            if protectedPaths.contains(entry.url.standardizedFileURL.path) { continue }
            do {
                try fm.removeItem(at: entry.url)
                removed += 1
            } catch {
                print("[LockScreenWallpaper] ⚠️ 淘汰旧缩略图失败 \(entry.url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        print("[LockScreenWallpaper] 🖼️ 共享容器缩略图: \(entries.count) 项 → 淘汰 \(removed) 项（上限 \(AppGroupCacheBudget.thumbnailLimitBytes)）")
    }

    // MARK: - 纯图像处理（nonisolated：可从后台线程调用，不触碰任何实例状态）

    /// Returns the existing identical cache file or a completed private staging
    /// file. The caller alone may publish it after checking request ownership.
    private nonisolated static func stageMirroringVideo(_ source: URL, destination: URL) throws -> URL {
        let fm = FileManager.default
        let attributes = try fm.attributesOfItem(atPath: source.path)
        guard let size = attributes[.size] as? NSNumber, size.int64Value > 0,
              let modified = attributes[.modificationDate] as? Date else {
            throw CocoaError(.fileReadCorruptFile)
        }
        if let cached = try? fm.attributesOfItem(atPath: destination.path),
           cached[.size] as? NSNumber == size,
           cached[.modificationDate] as? Date == modified {
            return destination
        }
        let directory = destination.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).partial")
        do {
            do { try fm.linkItem(at: source, to: temporary) }
            catch { try fm.copyItem(at: source, to: temporary) }
            let copied = try fm.attributesOfItem(atPath: temporary.path)
            let current = try fm.attributesOfItem(atPath: source.path)
            guard copied[.size] as? NSNumber == size,
                  current[.size] as? NSNumber == size,
                  current[.modificationDate] as? Date == modified else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return temporary
        } catch {
            try? fm.removeItem(at: temporary)
            throw error
        }
    }

    private nonisolated static let staticImagePixelByteLimit = 32 * 1024 * 1024
    private nonisolated static let staticImageMaximumDimension = 8192
    private nonisolated static let thumbnailMaximumDimension = 1024
    private nonisolated static let thumbnailPixelByteLimit = 16 * 1024 * 1024

    private nonisolated static func staticImageFitsPixelBudget(width: Int, height: Int, bytesPerPixel: Int) -> Bool {
        guard width > 16, height > 16,
              width <= staticImageMaximumDimension, height <= staticImageMaximumDimension,
              bytesPerPixel >= 4, bytesPerPixel <= 16 else { return false }
        let (rowBytes, rowOverflow) = width.multipliedReportingOverflow(by: bytesPerPixel)
        guard !rowOverflow else { return false }
        // Reserve common decoder row padding before the full source is decoded.
        let (paddedRowBytes, paddingOverflow) = rowBytes.addingReportingOverflow(255)
        guard !paddingOverflow else { return false }
        let (pixelBytes, pixelOverflow) = (paddedRowBytes & ~255).multipliedReportingOverflow(by: height)
        return !pixelOverflow && pixelBytes > 0 && pixelBytes <= staticImagePixelByteLimit
    }

    private nonisolated static func prepareStaticLockScreenImageData(_ data: Data, sourceURL: URL) -> (data: Data, fileExtension: String) {
        let fallbackExtension = Self.normalizedImageExtension(from: sourceURL)
        guard WaifuXPreferences.shared.object(forKey: "auto_remove_video_letterbox") as? Bool ?? false,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pixelWidth = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let pixelHeight = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            return (data, fallbackExtension)
        }
        let width = pixelWidth.doubleValue
        let height = pixelHeight.doubleValue
        let depth = (properties[kCGImagePropertyDepth] as? NSNumber)?.doubleValue ?? 32
        guard width.isFinite, height.isFinite, depth.isFinite,
              width > 16, height > 16, width <= Double(staticImageMaximumDimension), height <= Double(staticImageMaximumDimension),
              width.rounded(.down) == width, height.rounded(.down) == height,
              depth > 0, depth <= 32,
              Self.staticImageFitsPixelBudget(width: Int(width), height: Int(height), bytesPerPixel: max(4, Int(ceil(depth / 8)) * 4)),
              Self.staticImageFitsPixelBudget(width: Int(width), height: Int(height), bytesPerPixel: 4),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let cropRect = Self.detectBlackBorderCropRect(in: image) else {
            // Keep the original full-quality lock-screen image when cropping
            // would exceed the decode/scan budget; only thumbnails are resized.
            return (data, fallbackExtension)
        }

        guard let croppedImage = image.cropping(to: cropRect),
              let encodedData = Self.encodeLockScreenImage(croppedImage, preferredExtension: fallbackExtension) else {
            return (data, fallbackExtension)
        }

        print("[LockScreenWallpaper] 🖼️ 静态锁屏图已自动去黑边 crop=\(Int(cropRect.width))x\(Int(cropRect.height))")
        return (encodedData, Self.normalizedOutputExtension(fallbackExtension))
    }

    private nonisolated static func encodeLockScreenImage(_ image: CGImage, preferredExtension: String) -> Data? {
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

    private nonisolated static func normalizedOutputExtension(_ preferredExtension: String) -> String {
        switch preferredExtension.lowercased() {
        case "jpg", "jpeg":
            return "jpg"
        default:
            return "png"
        }
    }

    private nonisolated static func detectBlackBorderCropRect(in image: CGImage) -> CGRect? {
        let width = image.width
        let height = image.height
        guard Self.staticImageFitsPixelBudget(width: width, height: height, bytesPerPixel: 4) else { return nil }
        let (decodedPixelBytes, decodedOverflow) = image.bytesPerRow.multipliedReportingOverflow(by: height)
        guard !decodedOverflow, decodedPixelBytes > 0, decodedPixelBytes <= staticImagePixelByteLimit else { return nil }

        let bytesPerPixel = 4
        let (bytesPerRow, rowOverflow) = width.multipliedReportingOverflow(by: bytesPerPixel)
        let (scanPixelBytes, scanOverflow) = height.multipliedReportingOverflow(by: bytesPerRow)
        guard !rowOverflow, !scanOverflow, scanPixelBytes > 0, scanPixelBytes <= staticImagePixelByteLimit else { return nil }
        var pixels = [UInt8](repeating: 0, count: scanPixelBytes)
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
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("lock.syncDisplays", [:]); return }

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
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("lock.clearInstances", [:]); return }

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
        WaifuXPreferences.shared.set(false, forKey: "dynamic_lock_screen_enabled")

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

    /// 生成视频的 JPEG 缩略图并写入共享容器供扩展读取。
    /// nonisolated：AVAssetImageGenerator 同步解码整帧很重，由调用方放到后台线程执行。
    private nonisolated static func generateThumbnail(in container: URL, videoURL: URL, videoID: String) {
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

    private nonisolated static func normalizedImageExtension(from url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if ["jpg", "jpeg", "png", "heic", "webp", "tiff", "bmp"].contains(ext) {
            return ext == "jpeg" ? "jpg" : ext
        }
        return "jpg"
    }

    private func thumbnailDirectory() -> URL? {
        guard let container = sharedContainerURL else { return nil }
        let thumbDir = container.appendingPathComponent("WallpaperCache/thumbnails")
        try? FileManager.default.createDirectory(at: thumbDir, withIntermediateDirectories: true)
        return thumbDir
    }

    private nonisolated static func staticThumbnailJPEGData(imageData: Data) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldAllowFloat: false,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailMaximumDimension,
        ]
        guard let source = CGImageSourceCreateWithData(imageData as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              cgImage.width > 0, cgImage.height > 0,
              cgImage.width <= thumbnailMaximumDimension, cgImage.height <= thumbnailMaximumDimension else { return nil }
        let (pixelBytes, pixelOverflow) = cgImage.bytesPerRow.multipliedReportingOverflow(by: cgImage.height)
        let output = NSMutableData()
        guard !pixelOverflow, pixelBytes > 0, pixelBytes <= thumbnailPixelByteLimit,
              let dest = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return output as Data
    }

    private nonisolated static func writeThumbnailData(_ data: Data, thumbnailID: String, thumbDir: URL) {
        let url = Self.versionedThumbnailURL(prefix: thumbnailID, in: thumbDir)
        do {
            try data.write(to: url, options: .atomic)
            Self.cleanupCachedThumbnails(prefix: thumbnailID, in: thumbDir, keeping: url)
        } catch {
            print("[LockScreenWallpaper] ⚠️ 静态图缩略图写入失败: \(thumbnailID): \(error.localizedDescription)")
        }
    }

    private func copyVideoThumbnailToDisplayThumbnails(videoID: String, displayIDs: [UInt32]) {
        guard let thumbDir = thumbnailDirectory() else { return }
        let sourceURL = thumbDir.appendingPathComponent("\(videoID).jpg")
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { return }

        for displayID in displayIDs {
            let prefix = Self.displayInstanceID(displayID)
            let destURL = Self.versionedThumbnailURL(prefix: prefix, in: thumbDir)
            do {
                try Data(contentsOf: sourceURL).write(to: destURL, options: .atomic)
                Self.cleanupCachedThumbnails(prefix: prefix, in: thumbDir, keeping: destURL)
                print("[LockScreenWallpaper] ✅ 已刷新显示器实例缩略图: \(destURL.lastPathComponent)")
            } catch {
                print("[LockScreenWallpaper] ⚠️ 显示器实例缩略图复制失败: \(error.localizedDescription)")
            }
        }
    }

    private nonisolated static func versionedThumbnailURL(prefix: String, in thumbDir: URL) -> URL {
        let milliseconds = Int(Date().timeIntervalSince1970 * 1000)
        let suffix = UUID().uuidString.prefix(8)
        return thumbDir.appendingPathComponent("\(prefix)-\(milliseconds)-\(suffix).jpg")
    }

    private nonisolated static func cleanupCachedThumbnails(prefix: String, in thumbDir: URL, keeping: URL? = nil) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: thumbDir, includingPropertiesForKeys: nil) else {
            return
        }
        for file in files where isThumbnail(file, matching: prefix) && file.standardizedFileURL != keeping?.standardizedFileURL {
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
        let matches = files.filter { Self.isThumbnail($0, matching: prefix) }
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

    private nonisolated static func isThumbnail(_ url: URL, matching prefix: String) -> Bool {
        guard url.pathExtension.lowercased() == "jpg" else { return false }
        let name = url.deletingPathExtension().lastPathComponent
        return name == prefix || name.hasPrefix("\(prefix)-")
    }

    // MARK: - Socket IPC 集成

    /// 将当前显示器实例目录同步到 Socket IPC 服务端。
    func syncInstanceCatalogToSocketServer(notify: Bool = true) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("lock.syncCatalog", ["notify": notify]); return }

        guard #available(macOS 26.0, *) else { return }
        guard WaifuXPreferences.shared.object(forKey: "dynamic_lock_screen_enabled") as? Bool ?? true else {
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
        /// 用户「使用电池时暂停动态壁纸」开关的镜像。
        /// 扩展自己读取电源与低功耗模式，这里只同步开关，避免 Helper 不在电源切换
        /// 瞬间时产生 stale 暂停。optional 保证旧扩展/旧 prefs 文件解码兼容。
        var pauseOnBattery: Bool? = nil
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
        /// Exact Scene frames: their viewport/letterbox and crop are already composed.
        var precomposedImagePaths: Set<String>?
        /// Original static image URLs for UI state recovery. The extension ignores this metadata.
        var currentImageSourceURLs: [String: String]?
    }
}

enum LockScreenError: LocalizedError {
    case fileNotFound
    case appGroupNotAvailable
    case sourceReadyTimeout
    case copyFailed(String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound: return "视频文件不存在"
        case .appGroupNotAvailable: return "App Group 共享容器不可用"
        case .sourceReadyTimeout: return "壁纸扩展未回报换图完成"
        case .copyFailed(let msg): return "复制失败: \(msg)"
        }
    }
}
