import Foundation
import AppKit
import AVFoundation
import CryptoKit
import CoreGraphics
import QuartzCore
import CoreAudio
import Vision

// MARK: - Per-wallpaper video optimization pipeline state

@MainActor
final class VideoOptimizationPipelineStateService: ObservableObject {
    enum Stage: Equatable {
        case idle
        case restoringOriginal
        case loopQueued
        case loopAnalyzing
        case checkingInterpolation
        case frameQueued
        case interpolating
        case failed(String)
    }

    @Published private(set) var stages: [String: Stage] = [:]

    static let shared = VideoOptimizationPipelineStateService()

    private init() {}

    func stage(for itemID: String) -> Stage {
        stages[itemID] ?? .idle
    }

    func set(_ stage: Stage, for itemID: String) {
        stages[itemID] = stage
    }

    func reset(itemID: String) {
        stages.removeValue(forKey: itemID)
    }
}

enum FrameInterpolationTargetFPSResolver {
    static let defaultsKey = "frame_interpolation_target_fps"
    static let allowedFixedFPSValues: [Int] = [30, 60, 90, 120]

    static var storedRawValue: Double {
        UserDefaults.standard.object(forKey: defaultsKey) as? Double ?? 60
    }

    static func targetFPS(for screen: NSScreen?) -> Int {
        nearestAllowedFixedFPS(Int(storedRawValue.rounded()))
    }

    static func targetFPSForManualAction() -> Int {
        return targetFPS(for: NSScreen.main ?? NSScreen.screens.first)
    }

    static func nearestAllowedFixedFPS(_ fps: Int) -> Int {
        allowedFixedFPSValues.min { lhs, rhs in
            abs(lhs - fps) < abs(rhs - fps)
        } ?? 60
    }
}

private final class SharedGlobalPlayerReplacementContext: @unchecked Sendable {
    let components: (player: AVQueuePlayer, looper: AVPlayerLooper?, item: AVPlayerItem)
    let videoURL: URL
    let targets: [(NSScreen, WallpaperVideoContainerView)]
    let primaryScreen: NSScreen
    let isOnEndMode: Bool

    init(
        components: (player: AVQueuePlayer, looper: AVPlayerLooper?, item: AVPlayerItem),
        videoURL: URL,
        targets: [(NSScreen, WallpaperVideoContainerView)],
        primaryScreen: NSScreen,
        isOnEndMode: Bool
    ) {
        self.components = components
        self.videoURL = videoURL
        self.targets = targets
        self.primaryScreen = primaryScreen
        self.isOnEndMode = isOnEndMode
    }
}

// MARK: - Video Loop Analysis Queue

@MainActor
final class LoopPointAnalysisQueueService: ObservableObject {
    static let shared = LoopPointAnalysisQueueService()

    struct QueueItem: Identifiable {
        enum Status {
            case waiting
            case analyzing
        }

        let id: UUID
        let videoURL: URL
        let title: String
        var force: Bool
        var progress: Double
        var status: Status
    }

    @Published private(set) var items: [QueueItem] = []

    private var runningTask: Task<Void, Never>?
    // A video path can be reset and enqueued again before the cancelled worker
    // has observed cancellation. Keep callbacks scoped to the queue item, not
    // the path, so the stale worker cannot complete the replacement request.
    private var completionHandlers: [UUID: [(URL, Bool) -> Void]] = [:]

    private init() {}

    var activeProcessingItem: QueueItem? {
        items.first { item in
            if case .analyzing = item.status { return true }
            return false
        }
    }

    var remainingWorkCount: Int {
        let activeID = activeProcessingItem?.id
        return items.filter { $0.id != activeID }.count
    }

    func isQueued(videoURL: URL) -> Bool {
        let key = videoURL.standardizedFileURL.path
        return items.contains { $0.videoURL.standardizedFileURL.path == key }
    }

    func reset(videoURL: URL) {
        let key = videoURL.standardizedFileURL.path
        let matchingItems = items.filter {
            $0.videoURL.standardizedFileURL.path == key
        }
        let isResettingActiveItem = matchingItems.contains {
            $0.id == activeProcessingItem?.id
        }
        for item in matchingItems {
            // Reset is a replacement operation, not a failed analysis result.
            // Drop old completions so a cancelled worker cannot mark the new
            // pipeline as failed after the same file is queued again.
            completionHandlers[item.id] = nil
        }
        items.removeAll { $0.videoURL.standardizedFileURL.path == key }
        if isResettingActiveItem {
            // Keep the lane occupied until the cancelled worker exits. Starting
            // another analysis before that happens can mutate the same file twice.
            runningTask?.cancel()
        }
    }

    @discardableResult
    func enqueue(
        videoURL: URL,
        title: String? = nil,
        force: Bool = false,
        onCompleted: ((URL, Bool) -> Void)? = nil
    ) -> UUID {
        let key = videoURL.standardizedFileURL.path
        if let index = items.firstIndex(where: { $0.videoURL.standardizedFileURL.path == key }) {
            items[index].force = items[index].force || force
            if let onCompleted {
                completionHandlers[items[index].id, default: []].append(onCompleted)
            }
            return items[index].id
        }

        let id = UUID()
        items.append(QueueItem(
            id: id,
            videoURL: videoURL,
            title: title?.isEmpty == false ? title! : videoURL.deletingPathExtension().lastPathComponent,
            force: force,
            progress: 0,
            status: .waiting
        ))
        VideoOptimizationRecordService.shared.append(.loopQueued, for: videoURL)
        if let onCompleted {
            completionHandlers[id, default: []].append(onCompleted)
        }
        scheduleNext()
        return id
    }

    private func scheduleNext() {
        guard runningTask == nil,
              let index = items.firstIndex(where: {
                  if case .waiting = $0.status { return true }
                  return false
              }) else { return }

        items[index].status = .analyzing
        let itemID = items[index].id
        let videoURL = items[index].videoURL
        let force = items[index].force
        runningTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let progressTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    if let index = self?.items.firstIndex(where: { $0.id == itemID }) {
                        self?.items[index].progress = VideoLoopPreprocessingService.shared.progress(for: videoURL)
                    }
                    try? await Task.sleep(nanoseconds: 120_000_000)
                }
            }

            let succeeded = await VideoLoopPreprocessingService.shared.analyzeIfNeeded(videoURL, force: force)
            progressTask.cancel()

            if let index = self.items.firstIndex(where: { $0.id == itemID }) {
                self.items[index].progress = succeeded ? 1 : VideoLoopPreprocessingService.shared.progress(for: videoURL)
            }
            self.completionHandlers[itemID]?.forEach { $0(videoURL, succeeded) }
            self.completionHandlers[itemID] = nil
            self.items.removeAll { $0.id == itemID }
            self.runningTask = nil
            self.scheduleNext()
        }
    }
}

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
        return !videoURLByScreen.isEmpty || !videoURLByScreenFingerprint.isEmpty
    }
    /// 已废弃：多屏场景下请使用 `posterURL(for:)` 获取指定屏幕的 poster
    @Published private(set) var currentPosterURL: URL?
    @Published private(set) var isMuted = true
    @Published private(set) var isPaused = false
    @Published private(set) var volume: Double = 1.0
    /// 壁纸变更计数器（每次 applyVideoWallpaper 成功切换后自增）。
    /// 外部订阅此属性可感知任意壁纸切换事件，不受 `currentVideoURL` 值是否变化影响。
    @Published private(set) var wallpaperChangeCount: UInt64 = 0

    /// 每个屏幕的独立 poster（key 为 screenID），解决多屏自动更换时 poster 被覆盖的问题
    private var posterURLByScreen: [String: URL] = [:]
    /// 同一 poster 的物理显示器指纹索引，用于外接屏重连后 screenID 变化时恢复。
    private var posterURLByScreenFingerprint: [String: URL] = [:]
    /// 每个屏幕独立的视频文件路径；解决多屏分别设置不同视频后重启只能恢复最后一块屏的问题。
    private var videoURLByScreen: [String: URL] = [:]
    /// 每个物理显示器对应的视频文件路径，用于 screenID 变化后的恢复。
    private var videoURLByScreenFingerprint: [String: URL] = [:]
    private struct PendingDisplayVideoSwitch {
        let videoURL: URL
        let posterURL: URL?
        let muted: Bool
        let screenID: String
        let fingerprint: String
        let screenName: String
        let requestedAt: Date
    }
    /// 多屏自动切换串行门控：一块屏稳定前，其它屏的切换先缓存，避免三路 AVPlayer/海报写入一起抢资源。
    private var activeDisplaySwitchScreenID: String?
    private var pendingDisplaySwitches: [String: PendingDisplayVideoSwitch] = [:]
    private var displaySwitchReleaseWorkItem: DispatchWorkItem?
    /// 每个屏幕独立的 poster 设置任务，避免一块屏的新任务取消掉另一块屏的恢复。
    private var posterTasks: [String: Task<Void, Never>] = [:]
    /// 每个屏幕当前有效的 poster 加载令牌，防止旧封面在异步加载完成后盖回新播放器。
    private var posterDisplayTokens: [String: UUID] = [:]
    /// 每个屏幕的独立音量（key 为 screenID），未设置时回退到全局 `volume`
    private var volumeByScreen: [String: Double] = [:]
    /// 音量的物理显示器指纹索引，用于 screenID 变化后的恢复。
    private var volumeByScreenFingerprint: [String: Double] = [:]

    private var windows: [String: WallpaperVideoWindow] = [:]
    private var players: [String: AVQueuePlayer] = [:]
    private var loopers: [String: AVPlayerLooper] = [:]
    /// 每屏视频真实尺寸缓存（naturalSize），供 crop 计算用。设置壁纸时填充。
    private var videoSizes: [String: CGSize] = [:]
    /// 每屏视频源文件自带黑边的内容裁切框。只在全屏自动铺满模式下叠加。
    private var videoLetterboxContentCrops: [String: VideoLetterboxCrop] = [:]
    private var videoLetterboxAnalysisTasks: [String: Task<VideoLetterboxCrop?, Never>] = [:]
    private var videoLetterboxCropCache: [String: VideoLetterboxCrop] = [:]
    private var videoLetterboxNoCropCache = Set<String>()
    /// 每屏原生视频补帧判断结果。补帧完成后会直接替换源视频文件。
    private var frameInterpolationDecisionsByScreen: [String: VideoFrameInterpolationDecision] = [:]
    private var frameInterpolationAnalysisTasks: [String: Task<VideoFrameInterpolationDecision, Never>] = [:]
    private var frameInterpolatedPlaybackURLByScreen: [String: URL] = [:]
    /// 延迟释放的工作项，用于取消上一次未执行的清理，避免快速切换时多组 AVPlayer 并发驻留
    private var pendingPlayerCleanups: [DispatchWorkItem] = []
    private var pendingWindowCleanups: [DispatchWorkItem] = []
    /// 启动时等待视频首帧就绪的 KVO 观察器（key: screenID）
    private var playerItemObservers: [String: NSKeyValueObservation] = [:]
    /// KVO 回调对应的稳定令牌，避免旧回调清理掉新的淡入流程。
    private var playerItemObserverTokens: [String: UUID] = [:]
    /// 启动淡入超时工作项（key: screenID）
    private var fadeInTimeouts: [String: DispatchWorkItem] = [:]
    /// 全局共享播放器切换期间保留新 item 的观察器，确保旧视频持续播放到新首帧就绪。
    private var sharedReplacementObserver: NSKeyValueObservation?
    private var sharedReplacementReadyTimeout: DispatchWorkItem?
    private var sharedReplacementToken: UUID?
    private var sharedReplacementPreparingVideoURL: URL?

    /// "播完即换"模式下的播放器播放结束观察者（key: screenID）
    private var playbackEndObservers: [String: Any] = [:]

    /// macOS 26+：WallpaperExtensionKit 锁屏实例是否处于活跃状态。
    /// 这里仅表示锁屏镜像链路已建立，不代表扩展接管桌面渲染。
    /// 桌面动态壁纸仍由主应用自己的视频窗口负责。
    /// 非 macOS 26 系统始终为 false。
    private(set) var isLockScreenExtensionActive = false

    /// 锁屏镜像是否实际可用（结合文件状态和 Socket 管线活跃度）。
    /// `isLockScreenExtensionActive` 由扩展写入的 state JSON 驱动，
    /// 但该文件可能因时序未及时写出；额外检查 `hasActivePipeline` 确保不遗漏已注册 surface 的活跃实例。
    /// 同时受 `dynamic_lock_screen_enabled` 开关控制 — 关闭时返回 false。
    ///
    /// ⚠️ 此属性仅在锁屏扩展**当前正在运行**时返回 true（即屏幕已锁定）。
    /// 桌面场景下扩展未运行，始终返回 false。
    /// 如需判断用户是否已启用动态锁屏功能（持久化设置），请使用 `isLockScreenEnabled`。
    var isLockScreenMirroringActive: Bool {
        if #available(macOS 26.0, *) {
            // 用户在设置中关闭了动态锁屏 → 视作未激活
            guard UserDefaults.standard.object(forKey: "dynamic_lock_screen_enabled") as? Bool ?? true else {
                return false
            }
            // 先检查内存标志（避免不必要的文件 I/O）
            guard isLockScreenExtensionActive || WallpaperExtensionSocketServer.shared.hasActivePipeline else {
                // 内存标志为 false 时主动回退读 state 文件，
                // 防止 clearExtensionState 后未收到通知导致标志过期
                checkExtensionState()
                guard isLockScreenExtensionActive || WallpaperExtensionSocketServer.shared.hasActivePipeline else {
                    return false
                }
                return true
            }
            return true
        }
        return false
    }

    /// 用户是否已启用动态锁屏功能（持久化 UserDefaults 设置，与扩展当前是否运行无关）。
    /// 用于在切换桌面壁纸时保护锁屏实例状态不被清除。
    /// - 返回 true：用户已在设置中开启动态锁屏 → 不清除锁屏镜像帧源缓存
    /// - 返回 false：用户已关闭或从未配置 → 正常清理
    var isLockScreenEnabled: Bool {
        if #available(macOS 26.0, *) {
            return UserDefaults.standard.object(forKey: "dynamic_lock_screen_enabled") as? Bool ?? false
        }
        return false
    }

    /// 系统壁纸同步是否启用（默认开启）。关闭后冻结 setDesktopImageURL 链路，
    /// App 不再写入系统桌面/锁屏静态壁纸；mp4/场景/web 动态壁纸引擎不受影响。
    var isSystemWallpaperSyncEnabled: Bool {
        UserDefaults.standard.object(forKey: "system_wallpaper_sync_enabled") as? Bool ?? true
    }

    private var autoRemoveVideoLetterboxEnabled: Bool {
        UserDefaults.standard.object(forKey: "auto_remove_video_letterbox") as? Bool ?? false
    }

    private var frameInterpolationEnabled: Bool {
        UserDefaults.standard.object(forKey: "frame_interpolation_enabled") as? Bool ?? false
    }

    /// 全局显示器同步不是“所有屏幕播放同一路文件”这么简单：必须共用同一个
    /// AVPlayerItem/AVQueuePlayer，才能让 VideoToolbox 仅保留一条硬件解码管线。
    private var usesSharedGlobalVideoPlayer: Bool {
        WallpaperSchedulerService.shared.config.syncAllDisplays && NSScreen.screens.count > 1
    }

    var isPreparingSharedGlobalReplacement: Bool {
        sharedReplacementToken != nil
    }

    private func frameInterpolationTargetFPS(for screen: NSScreen?) -> Int {
        FrameInterpolationTargetFPSResolver.targetFPS(for: screen)
    }

    /// 动态锁屏启用后，任何静态 poster 写入都会通过 macOS 桌面壁纸接口覆盖用户手动选择的锁屏实例。
    /// 因此这里看“用户设置是否启用”，而不是看扩展此刻是否正在锁屏运行。
    private var shouldSkipStaticPosterForDynamicLockScreen: Bool {
        if #available(macOS 26.0, *) {
            return isLockScreenEnabled
        }
        return false
    }

    /// 应挂载 MP4 壁纸层的屏幕 ID（`NSScreen.wallpaperScreenIdentifier`）。唤醒 / 分辨率变化时全局 `rebuildWindows()` 只重建这些屏，避免「只设一块屏动态」却给所有显示器都建了视频窗。
    private var videoTargetScreenIDs = Set<String>()
    /// 应挂载 MP4 壁纸层的物理显示器指纹。不要在显示器断开时清理，重连后靠它找回目标屏。
    private var videoTargetScreenFingerprints = Set<String>()

    /// 标记哪些屏幕使用"播完即换"模式（key: screenID）
    private var onEndModeScreens = Set<String>()

    /// 用于 poster 文件名的交替槽位，避免 macOS 桌面壁纸缓存旧图
    private var posterSlot = 0

    private let defaults = UserDefaults.standard
    private let stateKey = "video_wallpaper_state_v1"
    private let originalWallpaperKey = "video_wallpaper_original_desktop_v2"  // 旧版原始壁纸快照 key，仅用于清理遗留数据
    private let delayedCleanupRetention: TimeInterval = 0.5
    private let localVideoForwardBufferDuration: TimeInterval = 5.0
    private let largeLocalVideoForwardBufferDuration: TimeInterval = 2.0
    private let automaticSwitchTransitionDuration: TimeInterval = 0.28
    private let automaticSwitchReadyTimeout: TimeInterval = 1.2
    private let deferredPosterSyncDelay: TimeInterval = 2.0
    private let displaySwitchStableDelay: TimeInterval = 1.0
    private let displaySwitchTimeout: TimeInterval = 8.0

    // MARK: - 音频设备管理

    /// 缓存 Built-in Speaker（或非蓝牙输出设备）的 UID，
    /// 用于静音时将 AVPlayer 音频强制路由到此设备，防止 macOS 因检测到本 App 的音频会话而自动连接 AirPods。
    private var cachedBuiltInOutputDeviceUID: String? = nil

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
    func videoURL(for screen: NSScreen) -> URL? {
        videoURLByScreen[screen.wallpaperScreenIdentifier] ??
        videoURLByScreenFingerprint[screen.wallpaperScreenFingerprint] ??
        currentVideoURL
    }

    /// 外接屏重连时按物理指纹恢复之前分配给这块屏的视频壁纸。
    func restorePreviousVideoWallpaperIfAvailable(for screen: NSScreen) -> Bool {
        let screenID = screen.wallpaperScreenIdentifier
        let fingerprint = screen.wallpaperScreenFingerprint
        let hasPreviousState = videoTargetScreenIDs.contains(screenID)
            || videoTargetScreenFingerprints.contains(fingerprint)
            || videoURLByScreen[screenID] != nil
            || videoURLByScreenFingerprint[fingerprint] != nil

        // 单屏关闭时会移除内存中的播放器映射，但会保留持久化状态以供再次开启。
        // 因此不能只看当前内存，必须先尝试恢复该物理显示器自己的已保存视频。
        if !hasPreviousState {
            guard let data = defaults.data(forKey: stateKey),
                  let savedState = try? JSONDecoder().decode(SavedVideoWallpaperState.self, from: data) else {
                return false
            }

            let isSavedForScreen = !savedState.hasExplicitScreenTargets
                || savedState.videoScreenIDs?.contains(screenID) == true
                || savedState.videoScreenFingerprints?.contains(fingerprint) == true
            guard isSavedForScreen else { return false }

            let videoLocation = savedState.videoURLs?[screenID]
                ?? savedState.videoURLsByFingerprint?[fingerprint]
                ?? savedState.fileURL
            guard let videoURL = URL(string: videoLocation),
                  FileManager.default.fileExists(atPath: videoURL.path) else {
                return false
            }
            let posterLocation = savedState.posterURLs?[screenID]
                ?? savedState.posterURLsByFingerprint?[fingerprint]
                ?? savedState.posterURL
            let posterURL = posterLocation.flatMap(URL.init(string:))

            do {
                try applyVideoWallpaper(
                    from: videoURL,
                    posterURL: posterURL,
                    muted: savedState.isMuted,
                    targetScreen: screen
                )
                if let savedVolume = savedState.volumeByScreen?[screenID]
                    ?? savedState.volumeByScreenFingerprint?[fingerprint]
                    ?? savedState.volume {
                    setVolume(savedVolume, for: screen)
                }
                if savedState.isPaused {
                    pauseWallpaper(for: screen)
                }
                print("[VideoWallpaperManager] Restored saved video wallpaper for (screen.localizedName)")
                return true
            } catch {
                print("[VideoWallpaperManager] Failed to restore saved video wallpaper for (screen.localizedName): (error.localizedDescription)")
                return false
            }
        }

        relinkDisplayStateForCurrentScreens()
        videoTargetScreenIDs.insert(screenID)
        videoTargetScreenFingerprints.insert(fingerprint)

        guard videoURLByScreen[screenID] != nil
            || videoURLByScreenFingerprint[fingerprint] != nil
            || currentVideoURL != nil else {
            return false
        }

        do {
            try rebuildWindows(targetScreen: screen)
            persistState()
            print("[VideoWallpaperManager] Restored previous video wallpaper for reconnected display: \(screen.localizedName)")
            return true
        } catch {
            print("[VideoWallpaperManager] Failed to restore previous video wallpaper for \(screen.localizedName): \(error.localizedDescription)")
            return false
        }
    }

    /// 删除一块未被用户标记为“保留”的外接显示器的恢复记录。
    /// 该方法只清理目标屏，不会影响其他显示器正在使用的视频。
    func discardPersistedWallpaperState(screenID: String, fingerprint: String) {
        videoTargetScreenIDs.remove(screenID)
        videoTargetScreenFingerprints.remove(fingerprint)
        videoURLByScreen.removeValue(forKey: screenID)
        videoURLByScreenFingerprint.removeValue(forKey: fingerprint)
        posterURLByScreen.removeValue(forKey: screenID)
        posterURLByScreenFingerprint.removeValue(forKey: fingerprint)
        volumeByScreen.removeValue(forKey: screenID)
        volumeByScreenFingerprint.removeValue(forKey: fingerprint)
        resetVideoLetterboxState(for: screenID)
        resetFrameInterpolationState(for: screenID)

        if hasActiveVideoWallpaper {
            syncCurrentVideoURL()
            persistState()
        } else {
            defaults.removeObject(forKey: stateKey)
        }
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
    /// 独立于 screenParametersChanged 的唤醒重建 work item，防止唤醒时序竞争
    private var pendingWakeRebuildWorkItem: DispatchWorkItem?
    private var lastAppliedScreenConfigurations: [ScreenConfigurationSignature] = []

    private init() {
        // 恢复静音偏好（独立于视频壁纸状态，场景/Web 壁纸同样生效）
        if UserDefaults.standard.object(forKey: "wallpaper_is_muted") != nil {
            isMuted = UserDefaults.standard.bool(forKey: "wallpaper_is_muted")
        }
        setupNotificationObservers()
        configureAudioSession()
    }

    private func setupNotificationObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        // 可视区域 crop 变更（菜单调节 / overlay 拖拽）
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCropDidChange),
            name: DisplayCropSettingsStore.cropDidChangeNotification,
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

        // macOS 26+：监听 WallpaperExtension 锁屏镜像实例状态变化
        if #available(macOS 26.0, *) {
            observeExtensionStateChanges()
        }
    }

    @MainActor
    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default.removeObserver(self)
        pendingRebuildWorkItem?.cancel()
        pendingRebuildWorkItem = nil
        pendingWakeRebuildWorkItem?.cancel()
        pendingWakeRebuildWorkItem = nil
    }

    // MARK: - Audio Session Management

    /// 获取系统 Built-in Speaker（或第一个非蓝牙输出设备）的 UID。
    /// 用于静音时通过 `AVPlayer.audioOutputDeviceUniqueID` 将音频强制路由到该设备，
    /// 使 macOS 不会因检测到本 App 的音频会话而自动连接 AirPods 等蓝牙设备。
    private func findBuiltInOutputDeviceUID() -> String? {
        if let cached = cachedBuiltInOutputDeviceUID { return cached }

        var propertySize: UInt32 = 0
        var devicesProperty = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesProperty,
            0, nil,
            &propertySize
        ) == noErr, propertySize > 0 else { return nil }

        let deviceCount = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesProperty,
            0, nil,
            &propertySize, &deviceIDs
        ) == noErr else { return nil }

        for deviceID in deviceIDs {
            guard deviceID != kAudioObjectUnknown else { continue }

            // 确保设备有输出能力
            var outputStreamProperty = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var outputStreamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(
                deviceID,
                &outputStreamProperty,
                0, nil,
                &outputStreamSize
            ) == noErr, outputStreamSize > 0 else { continue }

            // 获取设备 UID（CFStringRef）
            var uidProperty = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uidRef: Unmanaged<CFString>?
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(
                deviceID,
                &uidProperty,
                0, nil,
                &uidSize, &uidRef
            ) == noErr, let retainedUID = uidRef?.takeRetainedValue() as String? else { continue }

            let uid = retainedUID

            // 优先选择 Built-In Speaker（非蓝牙设备）
            if uid.localizedCaseInsensitiveContains("built") || uid.localizedCaseInsensitiveContains("speaker") {
                cachedBuiltInOutputDeviceUID = uid
                return uid
            }

            // 兜底：跳过蓝牙设备，选择第一个可用输出设备
            if !uid.localizedCaseInsensitiveContains("bluetooth")
                && !uid.localizedCaseInsensitiveContains("airpods")
                && !uid.localizedCaseInsensitiveContains("beats") {
                if cachedBuiltInOutputDeviceUID == nil {
                    cachedBuiltInOutputDeviceUID = uid
                }
            }
        }

        return cachedBuiltInOutputDeviceUID
    }

    /// 配置音频会话：初始化时缓存 Built-in Speaker UID。
    private func configureAudioSession() {
        // 预缓存内置扬声器 UID，便于后续静音时快速使用
        _ = findBuiltInOutputDeviceUID()
    }

    /// 根据静音状态更新每个 AVPlayer 的音频输出设备路由：
    /// - 静音时：将所有 AVPlayer 的音频强制路由到 Built-in Speaker（非蓝牙设备），
    ///   使 macOS 不会因本 App 的音频会话而自动连接蓝牙耳机。
    /// - 取消静音时：恢复为系统默认输出设备（`audioOutputDeviceUniqueID = nil`）。
    private func updateAudioSession() {
        guard hasActiveVideoWallpaper else { return }

        if isMuted {
            let builtInUID = findBuiltInOutputDeviceUID()
            for player in players.values {
                player.audioOutputDeviceUniqueID = builtInUID
            }
        } else {
            for player in players.values {
                player.audioOutputDeviceUniqueID = nil
            }
        }
    }

    /// 停用音频会话：恢复所有 AVPlayer 的音频输出为系统默认，清理缓存。
    private func deactivateAudioSession() {
        for player in players.values {
            player.audioOutputDeviceUniqueID = nil
        }
    }

    // MARK: - macOS 26+ Extension State Monitoring

    /// 监听 WallpaperExtension 的状态变化（通过 Darwin 通知 + 共享容器 JSON）
    /// 这里只表示锁屏镜像实例是否活跃，不影响桌面本地播放器生命周期。
    @available(macOS 26.0, *)
    private func observeExtensionStateChanges() {
        // 1. 监听 Darwin 通知（扩展 post 的 stateChanged）
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let manager = Unmanaged<VideoWallpaperManager>.fromOpaque(observer).takeUnretainedValue()
                Task { @MainActor in
                    manager.checkExtensionState()
                }
            },
            "com.waifux.app.wallpaper.stateChanged" as CFString,
            nil,
            .deliverImmediately
        )

        // 2. 初始检查一次
        checkExtensionState()
    }

    /// 从共享容器读取扩展状态，判断锁屏镜像实例是否活跃。
    @available(macOS 26.0, *)
    private func checkExtensionState() {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.waifux.app"
        ) else { return }

        let stateURL = container.appendingPathComponent("waifux-wallpaper-state.json")
        guard let data = try? Data(contentsOf: stateURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let isActive = json["isActive"] as? Bool else {
            // 无法读取状态 → 认为扩展未激活
            if isLockScreenExtensionActive {
                isLockScreenExtensionActive = false
                print("[VideoWallpaperManager] Lock screen extension state unreadable → inactive")
            }
            return
        }

        let wasActive = isLockScreenExtensionActive
        isLockScreenExtensionActive = isActive

        if isActive && !wasActive {
            print("[VideoWallpaperManager] Lock screen extension became active")
            if hasActiveVideoWallpaper {
                syncAllDisplayVideosToExtension()
            }
        } else if !isActive && wasActive {
            print("[VideoWallpaperManager] Lock screen extension became inactive")
        }

        // 检测 videoID 变化（表示扩展已完成视频切换）
        // 延迟 3 秒再发一次 prefsChanged 通知，让扩展再次调用 updateSettingsViewModels()
        // 通知系统刷新壁纸设置，更新系统 UI 的壁纸颜色缓存
        let currentVideoID = json["currentVideoID"] as? String
        let previousVideoID = Self.lastCheckedExtensionVideoID
        Self.lastCheckedExtensionVideoID = currentVideoID

        if isActive, let newID = currentVideoID, newID != previousVideoID {
            print("[VideoWallpaperManager] 🎨 检测到扩展视频切换: \(previousVideoID ?? "nil") → \(newID)，延迟 3 秒通知系统刷新 UI")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self, self.isLockScreenExtensionActive else { return }
                print("[VideoWallpaperManager] 🎨 发送延迟 prefsChanged 通知，触发系统刷新壁纸颜色")
                LockScreenWallpaperService.shared.notifyExtensionPrefsChanged()
            }
        }
    }

    /// 上次检查到的扩展 videoID，用于检测视频切换
    private static var lastCheckedExtensionVideoID: String?

    /// 将所有显示器的当前视频源同步到锁屏扩展。
    /// 用户在系统设置中手动为每个显示器选择一次 WaifuX 实例后，
    /// 锁屏侧使用扩展本地解码播放当前桌面视频，不再依赖 App 逐帧推送。
    @available(macOS 26.0, *)
    private func syncAllDisplayVideosToExtension() {
        guard UserDefaults.standard.object(forKey: "dynamic_lock_screen_enabled") as? Bool ?? true else {
            print("[VideoWallpaperManager] syncAllDisplayVideosToExtension: 动态锁屏已关闭，跳过")
            return
        }
        var displayVideoPairs: [(displayID: UInt32, videoURL: URL)] = []

        for screen in NSScreen.screens {
            guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                continue
            }
            guard let videoURL = videoURL(for: screen), FileManager.default.fileExists(atPath: videoURL.path) else {
                continue
            }
            displayVideoPairs.append((displayID: screenNumber.uint32Value, videoURL: videoURL))
        }

        if displayVideoPairs.isEmpty, let globalURL = currentVideoURL,
           FileManager.default.fileExists(atPath: globalURL.path) {
            for screen in NSScreen.screens {
                guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                    continue
                }
                displayVideoPairs.append((displayID: screenNumber.uint32Value, videoURL: globalURL))
            }
        }

        guard !displayVideoPairs.isEmpty else {
            print("[VideoWallpaperManager] syncAllDisplayVideosToExtension: 没有可同步的显示器视频源，跳过")
            return
        }

        print("[VideoWallpaperManager] syncAllDisplayVideosToExtension: 同步 \(displayVideoPairs.count) 个显示器自解码源到锁屏扩展")

        // 递增世代号并清空旧命令，防止前一次异步 Task 入队的过期命令被扩展执行
        let generation = WallpaperExtensionSocketServer.nextVideoSyncGeneration()
        WallpaperExtensionSocketServer.shared.clearCommands()

        // ⚠️ 关键时序修复：先不同步实例到 Socket（不同步也就不会发 prefsChanged 通知），
        // 等视频缓存+注册完成后，在 switchActiveInstancesToLocalDecode 末尾统一发通知。
        // 这样扩展收到通知时 localDecodeVideoLock 中已有视频路径，不会出现时序窗口。
        // 同步实例目录到 Socket（纯同步，不发送通知 — 避免在视频注册前就触发扩展的 prefsChanged）
        // 确保扩展调用 list_videos 时能立即拿到最新的显示器实例列表（即使视频还未部署到共享容器）
        LockScreenWallpaperService.shared.syncInstanceCatalogToSocketServer(notify: false)
        WallpaperExtensionSocketServer.shared.clearDisplayVideos()

        let grouped = Dictionary(grouping: displayVideoPairs, by: { $0.videoURL })
        // ⚠️ 必须串行 await 每个视频组，不能并行启动多个 Task：
        // switchActiveInstancesToLocalDecode 会写入共享 prefs 文件（cacheMirroringSource），
        // 并发写入会导致：1) prefs 文件互相覆盖，只剩最后一路；2) deployedVideoIDs 集合
        // 有 ABA 问题，可能误删另一路正在使用的视频文件。
        // 串行执行代价很小（每个调用主要耗时在 hard link + 通知，非视频解码），但能彻底消除竞态。
        Task {
            for (videoURL, pairs) in grouped {
                let videoID = videoURL.deletingPathExtension().lastPathComponent
                let displayIDs = pairs.map(\.displayID)
                await LockScreenWallpaperService.shared.switchActiveInstancesToLocalDecode(
                    videoURL: videoURL,
                    videoID: videoID,
                    displayIDs: displayIDs,
                    generation: generation
                )
                print("[VideoWallpaperManager] 📺 请求锁屏自解码 display=\(displayIDs) video=\(videoID)")
            }
        }
    }

    /// 扩展已注册 IOSurface 时从 socket 侧反向触发同步。
    /// 这条路径不依赖扩展 state 文件，避免 state 写入缺失时 App 永远不启动 FramePusher。
    @available(macOS 26.0, *)
    func syncCurrentVideosToActiveLockScreenPipeline(reason: String) {
        guard hasActiveVideoWallpaper else {
            print("[VideoWallpaperManager] \(reason): 当前没有桌面视频源，暂不同步锁屏帧源")
            return
        }
        print("[VideoWallpaperManager] \(reason): 扩展管线就绪，主动同步锁屏帧源")
        syncAllDisplayVideosToExtension()
    }

    /// 锁屏镜像模式下的全局暂停/恢复切换（仅更新本地 isPaused 状态，prefs 由调用方写入）
    func toggleExtensionGlobalPause() {
        isPaused.toggle()
    }

    /// 清除锁屏镜像活跃状态（供外部调用方在清空镜像帧源后调用）
    func clearExtensionState() {
        isLockScreenExtensionActive = false
    }

    func applyVideoWallpaper(
        from localFileURL: URL,
        posterURL: URL? = nil,
        muted: Bool = true,
        targetScreens: [NSScreen]?,
        animatedTransition: Bool = false
    ) throws {
        if usesSharedGlobalVideoPlayer {
            try applyVideoWallpaper(
                from: localFileURL,
                posterURL: posterURL,
                muted: muted,
                targetScreen: nil,
                animatedTransition: animatedTransition
            )
            return
        }

        if let screens = targetScreens, !screens.isEmpty {
            for screen in screens {
                try applyVideoWallpaper(
                    from: localFileURL,
                    posterURL: posterURL,
                    muted: muted,
                    targetScreen: screen,
                    animatedTransition: animatedTransition
                )
            }
        } else {
            try applyVideoWallpaper(
                from: localFileURL,
                posterURL: posterURL,
                muted: muted,
                targetScreen: nil,
                animatedTransition: animatedTransition
            )
        }
    }

    func applyVideoWallpaper(
        from localFileURL: URL,
        posterURL: URL? = nil,
        muted: Bool = true,
        targetScreen: NSScreen? = nil,
        animatedTransition: Bool = false
    ) throws {
        // 全局同步时，单屏入口也必须提升为全屏入口；否则调用方虽传入同一路视频，
        // 仍会分别创建两个 AVPlayerItem，导致 VTDecoderXPCService 启动多路解码。
        if targetScreen != nil, usesSharedGlobalVideoPlayer {
            try applyVideoWallpaper(
                from: localFileURL,
                posterURL: posterURL,
                muted: muted,
                targetScreen: nil,
                animatedTransition: animatedTransition
            )
            return
        }

        AppLogger.error(.wallpaper, "applyVideoWallpaper 开始", metadata: [
            "video": localFileURL.lastPathComponent,
            "targetScreen": targetScreen?.localizedName ?? "nil(全部)"
        ])
        guard localFileURL.isFileURL else {
            throw NSError(domain: "VideoWallpaper", code: 1001, userInfo: [NSLocalizedDescriptionKey: "动态壁纸必须使用本地视频文件。"])
        }

        guard FileManager.default.fileExists(atPath: localFileURL.path) else {
            throw NSError(domain: "VideoWallpaper", code: 1002, userInfo: [NSLocalizedDescriptionKey: "视频文件不存在。"])
        }

        if let targetScreen,
           animatedTransition,
           cacheDisplaySwitchIfNeeded(
               videoURL: localFileURL,
               posterURL: posterURL,
               muted: muted,
               targetScreen: targetScreen
           ) {
            return
        }

        // 设视频壁纸时关闭并清除静态图 overlay（视频窗口本身覆盖桌面，静态 overlay 无意义且浪费窗口）
        StaticImageWallpaperOverlayManager.shared.clearState()

        // 本机视频不经过 CLI：如果设到全局或目标屏幕恰好被 CLI 管理时 stop CLI。
        // 多屏场景下，如果 CLI 正在渲染另一块屏的壁纸而本屏不需要 CLI，不杀 CLI 进程。
        if let targetScreen {
            if WallpaperEngineXBridge.shared.isManaging(screen: targetScreen) {
                WallpaperEngineXBridge.shared.ensureStoppedForNonCLIWallpaper(for: targetScreen)
            }
        } else {
            WallpaperEngineXBridge.shared.ensureStoppedForNonCLIWallpaper()
        }

        let isNewVideo = currentVideoURL != localFileURL
        let activeScreenIDs = Set(windows.keys)
        let screenIDsNow = Set(NSScreen.screens.map(\.wallpaperScreenIdentifier))
        let targetScreenID = targetScreen?.wallpaperScreenIdentifier
        let isSameVideoForTarget = targetScreen.flatMap { videoURL(for: $0) } == localFileURL
        let targetScreenAlreadyActive = targetScreenID.map { windows[$0] != nil && videoTargetScreenIDs.contains($0) } ?? true
        let targetDisplayConfigurationChanged = hasEffectiveTargetDisplayChange()

        if !isNewVideo,
           currentVideoURL == localFileURL,
           !windows.isEmpty,
           (targetScreen == nil || (isSameVideoForTarget && targetScreenAlreadyActive)),
           activeScreenIDs == videoTargetScreenIDs,
           videoTargetScreenIDs.isSubset(of: screenIDsNow),
           !targetDisplayConfigurationChanged {
            synchronizeExistingWindowFramesToCurrentScreens()
            currentVideoURL = localFileURL
            setMuted(muted)
            isPaused = false
            for player in players.values {
                if player.rate == 0 {
                    player.play()
                }
            }
            DynamicWallpaperAutoPauseManager.shared.clearForegroundPauseForWallpaperSwitch()
            DynamicWallpaperAutoPauseManager.shared.reevaluateCurrentState()

            // 即使复用已有播放器，也要同步锁屏镜像的 per-display 帧源。
            if #available(macOS 26.0, *) {
                LockScreenWallpaperService.shared.syncInstanceCatalogToSocketServer()
                syncAllDisplayVideosToExtension()
            }
            if let targetScreenID {
                scheduleDisplaySwitchStableRelease(screenID: targetScreenID, reason: "reuseExisting")
            }
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

        // 如果有预览图，设置为桌面壁纸（锁屏默认会沿用桌面 poster 作静态兜底）。
        // 动态锁屏启用时必须跳过；否则 setDesktopImageURLForAllSpaces 会覆盖用户选择的锁屏实例。
        if shouldSkipStaticPosterForDynamicLockScreen {
            print("[VideoWallpaperManager] 🔒 动态锁屏已启用，跳过设置静态桌面 poster")
        } else if let posterURL = posterURL {
            if animatedTransition {
                schedulePosterAsDesktopWallpaperAfterPlaybackSettles(
                    posterURL,
                    targetScreen: targetScreen,
                    expectedVideoURL: localFileURL
                )
            } else {
                setPosterAsDesktopWallpaper(posterURL, targetScreen: targetScreen)
            }
        }

        currentVideoURL = localFileURL
        // 按屏幕记录 poster，防止多屏自动更换时互相覆盖
        if let targetScreen {
            let screenID = targetScreen.wallpaperScreenIdentifier
            resetVideoLetterboxState(for: screenID)
            resetFrameInterpolationState(for: screenID)
            posterURLByScreen[screenID] = posterURL
            posterURLByScreenFingerprint[targetScreen.wallpaperScreenFingerprint] = posterURL
            videoURLByScreen[screenID] = localFileURL
            videoURLByScreenFingerprint[targetScreen.wallpaperScreenFingerprint] = localFileURL
        } else {
            for screen in NSScreen.screens {
                let screenID = screen.wallpaperScreenIdentifier
                resetVideoLetterboxState(for: screenID)
                resetFrameInterpolationState(for: screenID)
                posterURLByScreen[screenID] = posterURL
                posterURLByScreenFingerprint[screen.wallpaperScreenFingerprint] = posterURL
                videoURLByScreen[screenID] = localFileURL
                videoURLByScreenFingerprint[screen.wallpaperScreenFingerprint] = localFileURL
            }
        }
        currentPosterURL = posterURL  // 兼容旧代码
        isMuted = muted
        isPaused = false

        try rebuildWindows(
            targetScreen: targetScreenID.flatMap { id in
                NSScreen.screens.first { $0.wallpaperScreenIdentifier == id }
            },
            animatedTransition: animatedTransition
        )
        updateAudioSession()
        syncCurrentVideoURL()
        persistState()
        wallpaperChangeCount &+= 1
        DynamicWallpaperAutoPauseManager.shared.clearForegroundPauseForWallpaperSwitch()
        DynamicWallpaperAutoPauseManager.shared.reevaluateCurrentState()

        // 同步到锁屏镜像实例（macOS 26+）
        if #available(macOS 26.0, *) {
            LockScreenWallpaperService.shared.syncInstanceCatalogToSocketServer()
            syncAllDisplayVideosToExtension()
        }
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        UserDefaults.standard.set(muted, forKey: "wallpaper_is_muted")
        for (screenID, player) in players {
            let screenVolume = volumeByScreen[screenID] ?? volume
            // 工具栏静音需要同时处理播放器音量和已排队 item 的音频轨，避免只静音音量仍唤醒 AirPods。
            applyPlayerAudioPolicy(player, muted: muted, volume: screenVolume)
        }
        updateAudioSession()
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

    func refreshGrainOverlay() {
        let grainEnabled = ArcBackgroundSettings.shared.grainTextureEnabled
        let grainIntensity = ArcBackgroundSettings.shared.grainIntensity

        for window in windows.values {
            guard let containerView = window.contentView as? WallpaperVideoContainerView else { continue }
            if grainEnabled && grainIntensity > 0.01 {
                containerView.showGrainOverlay(intensity: grainIntensity)
            } else {
                containerView.hideGrainOverlay()
            }
        }
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

    /// Restores the just-finished video when the scheduler cannot apply any valid
    /// successor in "Play to End" mode. The poster stays visible until the first frame
    /// is ready, so a failed rotation cannot leave the desktop black.
    func resumeOnEndVideoAfterFailedSwitch(for targetScreen: NSScreen) {
        let screenID = targetScreen.wallpaperScreenIdentifier
        guard let player = players[screenID] else { return }

        showPosterImage(for: screenID)
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak player] _ in
            guard let player else { return }
            DispatchQueue.main.async {
                guard let self, self.players[screenID] === player else { return }
                guard !self.isPaused else { return }

                player.play()
                self.hidePosterImage(for: screenID)
            }
        }
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

    /// 对指定屏应用当前可视区域 crop 配置。在设置壁纸、布局变化、crop 变更时调用。
    /// 注：CropLayoutEngine 实际只用 screenSize（壁纸 crop 是归一化值，由 contentsRect 处理），
    /// 因此无需异步等待视频 track 加载完成。
    func applyCropToScreen(_ screen: NSScreen) {
        let screenID = screen.wallpaperScreenIdentifier
        guard let window = windows[screenID],
              let containerView = window.contentView as? WallpaperVideoContainerView,
              players[screenID] != nil else { return }

        let settings = DisplayCropSettingsStore.shared.settings(for: screen)
        guard settings.shouldApplyCrop else {
            window.backgroundColor = .black
            if autoRemoveVideoLetterboxEnabled,
               let contentCrop = videoLetterboxContentCrops[screenID] {
                let layout = CropLayout(
                    wallpaperCropRect: contentCrop.cropRect,
                    viewportRect: .full,
                    letterboxColor: CGColor(gray: 0, alpha: 1)
                )
                containerView.applyCropLayout(layout)
            } else {
                containerView.applyCropLayout(nil)
            }
            return
        }
        // wallpaperSize 用视频真实 naturalSize（取不到 fallback 屏尺寸，保证不崩）。
        let wallpaperSize = videoSizes[screenID] ?? screen.frame.size
        let layout = CropLayoutEngine.compute(
            wallpaperSize: wallpaperSize,
            screenSize: screen.frame.size,
            settings: settings)
        containerView.applyCropLayout(layout)
        window.backgroundColor = NSColor(cgColor: layout.letterboxColor) ?? .black
    }

    func refreshAutoRemoveVideoLetterbox() {
        guard autoRemoveVideoLetterboxEnabled else {
            for task in videoLetterboxAnalysisTasks.values { task.cancel() }
            videoLetterboxAnalysisTasks.removeAll()
            videoLetterboxContentCrops.removeAll()
            for screen in activeScreens {
                applyCropToScreen(screen)
            }
            return
        }

        for screen in activeScreens {
            let screenID = screen.wallpaperScreenIdentifier
            guard let videoURL = videoURLByScreen[screenID]
                ?? videoURLByScreenFingerprint[screen.wallpaperScreenFingerprint] else {
                continue
            }
            scheduleVideoLetterboxAnalysis(screenID: screenID, videoURL: videoURL)
        }
    }

    func refreshFrameInterpolationSettings() {
        for task in frameInterpolationAnalysisTasks.values { task.cancel() }
        frameInterpolationAnalysisTasks.removeAll()
        frameInterpolationDecisionsByScreen.removeAll()

        for screen in activeScreens {
            let screenID = screen.wallpaperScreenIdentifier
            guard let window = windows[screenID],
                  let containerView = window.contentView as? WallpaperVideoContainerView,
                  let player = players[screenID],
                  let item = player.currentItem,
                  let videoURL = videoURLByScreen[screenID]
                    ?? videoURLByScreenFingerprint[screen.wallpaperScreenFingerprint]
                    ?? currentVideoURL else {
                continue
            }
            prepareFrameInterpolation(
                screenID: screenID,
                screen: screen,
                videoURL: videoURL,
                player: player,
                item: item,
                containerView: containerView
            )
        }
    }

    @objc private func handleCropDidChange(_ note: Notification) {
        guard let screenID = note.userInfo?["screenID"] as? String,
              let screen = NSScreen.screens.first(where: { $0.wallpaperScreenIdentifier == screenID }) else { return }
        applyCropToScreen(screen)
    }

    /// 供 overlay 预览取视频真实尺寸（naturalSize）。
    func videoSize(for screen: NSScreen) -> CGSize? {
        videoSizes[screen.wallpaperScreenIdentifier]
    }

    private func scheduleVideoLetterboxAnalysis(screenID: String, videoURL: URL) {
        guard autoRemoveVideoLetterboxEnabled else { return }
        guard videoLetterboxAnalysisTasks[screenID] == nil else { return }

        let cacheKey = videoLetterboxCacheKey(for: videoURL)
        if let cached = videoLetterboxCropCache[cacheKey] {
            let targetScreenIDs = videoLetterboxTargetScreenIDs(for: screenID)
            for targetScreenID in targetScreenIDs {
                videoLetterboxContentCrops[targetScreenID] = cached
                if let screen = NSScreen.screens.first(where: { $0.wallpaperScreenIdentifier == targetScreenID }) {
                    applyCropToScreen(screen)
                }
            }
            return
        }
        if videoLetterboxNoCropCache.contains(cacheKey) {
            let targetScreenIDs = videoLetterboxTargetScreenIDs(for: screenID)
            for targetScreenID in targetScreenIDs {
                videoLetterboxContentCrops.removeValue(forKey: targetScreenID)
                if let screen = NSScreen.screens.first(where: { $0.wallpaperScreenIdentifier == targetScreenID }) {
                    applyCropToScreen(screen)
                }
            }
            return
        }

        let task = Task.detached(priority: .utility) {
            await VideoLetterboxAnalyzer.analyze(url: videoURL)
        }
        videoLetterboxAnalysisTasks[screenID] = task

        Task { @MainActor [weak self] in
            let crop = await task.value
            guard let self else { return }
            self.videoLetterboxAnalysisTasks.removeValue(forKey: screenID)
            guard self.autoRemoveVideoLetterboxEnabled else { return }
            let currentScreen = NSScreen.screens.first(where: { $0.wallpaperScreenIdentifier == screenID })
            let currentVideoURL = self.videoURLByScreen[screenID]
                ?? currentScreen.flatMap { self.videoURLByScreenFingerprint[$0.wallpaperScreenFingerprint] }
            guard currentVideoURL?.standardizedFileURL == videoURL.standardizedFileURL else {
                return
            }

            let targetScreenIDs = self.videoLetterboxTargetScreenIDs(for: screenID)
            if let crop {
                self.videoLetterboxCropCache[cacheKey] = crop
                for targetID in targetScreenIDs {
                    self.videoLetterboxContentCrops[targetID] = crop
                }
            } else {
                self.videoLetterboxNoCropCache.insert(cacheKey)
                for targetID in targetScreenIDs {
                    self.videoLetterboxContentCrops.removeValue(forKey: targetID)
                }
            }

            for targetID in targetScreenIDs {
                if let screen = NSScreen.screens.first(where: { $0.wallpaperScreenIdentifier == targetID }) {
                    self.applyCropToScreen(screen)
                }
            }
        }
    }

    /// 全局共享播放器的去黑边结果按所有当前显示器保存。不能只依赖已创建的 window，
    /// 否则在新屏窗口尚未完成挂载时命中缓存，会遗漏该屏的裁切状态。
    private func videoLetterboxTargetScreenIDs(for screenID: String) -> [String] {
        guard usesSharedGlobalVideoPlayer else { return [screenID] }
        let screenIDs = NSScreen.screens.map(\.wallpaperScreenIdentifier)
        return screenIDs.isEmpty ? Array(windows.keys) : screenIDs
    }

    private func videoLetterboxCacheKey(for url: URL) -> String {
        guard url.isFileURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return url.standardizedFileURL.path
        }
        let size = attrs[.size] as? UInt64 ?? 0
        let modified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(url.standardizedFileURL.path)|\(size)|\(modified)"
    }

    private func prepareFrameInterpolation(
        screenID: String,
        screen: NSScreen,
        videoURL: URL,
        player: AVQueuePlayer,
        item: AVPlayerItem,
        containerView: WallpaperVideoContainerView,
        triggeredByWallpaperSetup: Bool = false
    ) {
        // 新的视频优化顺序固定为：循环点分析（原始帧）→ 补帧。
        // 循环点队列完成后以 false 再次进入本方法，避免补帧完成后反向触发循环点分析。
        if triggeredByWallpaperSetup,
           scheduleAutomaticLoopPointAnalysis(videoURL: videoURL, onFinished: { [weak self, weak player, weak item, weak containerView] in
               guard let self, let player, let item, let containerView else { return }
               self.prepareFrameInterpolation(
                   screenID: screenID,
                   screen: screen,
                   videoURL: videoURL,
                   player: player,
                   item: item,
                   containerView: containerView,
                   triggeredByWallpaperSetup: false
               )
           }) {
            return
        }

        let targetFPS = frameInterpolationTargetFPS(for: screen)
        guard frameInterpolationEnabled else {
            if frameInterpolatedPlaybackURLByScreen[screenID] != nil {
                frameInterpolationDebugPrint("设置已关闭：当前视频补帧状态已重置。视频：\(videoURL.path)")
                replacePlayerWithOriginalVideoIfNeeded(screenID: screenID, sourceURL: videoURL)
            } else {
                resetFrameInterpolation(for: screenID, player: player, item: item)
            }
            frameInterpolationDebugPrint("设置未开启：跳过补帧。视频：\(videoURL.path)")
            return
        }
        guard targetFPS > 0 else {
            resetFrameInterpolation(for: screenID, player: player, item: item)
            frameInterpolationDebugPrint("目标 FPS 无效：跳过补帧。目标 FPS：\(targetFPS)，视频：\(videoURL.path)")
            return
        }

        if let record = FrameInterpolationQueueService.shared.completedRecord(videoURL: videoURL, satisfying: targetFPS) {
            resetFrameInterpolation(for: screenID, player: player, item: item)
            frameInterpolationDebugPrint("已有补帧完成记录覆盖当前目标 FPS：记录 FPS=\(record.targetFPS)，目标 FPS=\(targetFPS)，跳过补帧。视频：\(videoURL.path)")
            return
        }

        if let activeTargetFPS = FrameInterpolationQueueService.shared.activeInterpolationTargetFPS(videoURL: videoURL),
           activeTargetFPS >= targetFPS {
            frameInterpolationDebugPrint("已有补帧任务覆盖当前目标 FPS：任务 FPS=\(activeTargetFPS)，目标 FPS=\(targetFPS)，跳过重复分析。视频：\(videoURL.path)")
            return
        }

        let targetMode = "固定档位"
        frameInterpolationDebugPrint("开始准备补帧：目标 FPS=\(targetFPS)，模式=\(targetMode)，屏幕=\(screen.localizedName)，视频：\(videoURL.path)")

        guard frameInterpolationAnalysisTasks[screenID] == nil else {
            frameInterpolationDebugPrint("FPS 分析已在进行中：本次不重复启动。")
            return
        }

        frameInterpolationDebugPrint("后台读取视频原始 FPS...")
        let task = Task.detached(priority: .utility) {
            await VideoFrameInterpolationAnalyzer.decision(for: videoURL, targetFPS: targetFPS)
        }
        frameInterpolationAnalysisTasks[screenID] = task

        Task { @MainActor [weak self, weak player, weak item, weak containerView] in
            let decision = await task.value
            guard let self else { return }
            self.frameInterpolationAnalysisTasks.removeValue(forKey: screenID)

            let currentScreen = NSScreen.screens.first(where: { $0.wallpaperScreenIdentifier == screenID })
            let currentVideoURL = self.videoURLByScreen[screenID]
                ?? currentScreen.flatMap { self.videoURLByScreenFingerprint[$0.wallpaperScreenFingerprint] }
                ?? self.currentVideoURL
            guard currentVideoURL?.standardizedFileURL == videoURL.standardizedFileURL,
                  let player,
                  let item,
                  let containerView else {
                return
            }
            self.applyFrameInterpolationDecision(
                decision,
                screenID: screenID,
                videoURL: videoURL,
                player: player,
                item: item,
                containerView: containerView,
                triggeredByWallpaperSetup: triggeredByWallpaperSetup
            )
        }
    }

    private func applyFrameInterpolationDecision(
        _ decision: VideoFrameInterpolationDecision,
        screenID: String,
        videoURL: URL,
        player: AVQueuePlayer,
        item: AVPlayerItem,
        containerView: WallpaperVideoContainerView,
        triggeredByWallpaperSetup: Bool
    ) {
        frameInterpolationDecisionsByScreen[screenID] = decision
        let sourceFPS = decision.sourceFPS.map { String(format: "%.2f", $0) } ?? "未知"
        frameInterpolationDebugPrint("FPS 分析完成：原始 FPS=\(sourceFPS)，目标 FPS=\(decision.targetFPS)，是否需要补帧=\(decision.shouldInterpolate ? "是" : "否")，原因：\(decision.reason)")

        guard decision.shouldInterpolate else {
            if decision.reason.contains("已达到或高于目标 FPS"),
               FrameInterpolationQueueService.shared.completedRecord(videoURL: videoURL) != nil {
                FrameInterpolationQueueService.shared.markCompleted(
                    videoURL: videoURL,
                    title: videoURL.deletingPathExtension().lastPathComponent,
                    targetFPS: decision.targetFPS
                )
                frameInterpolationDebugPrint("当前文件已满足目标 FPS：已修复补帧完成记录。目标 FPS=\(decision.targetFPS)，视频：\(videoURL.path)")
            }
            resetFrameInterpolation(for: screenID, player: player, item: item)
            return
        }

        guard !FrameInterpolationQueueService.shared.isBlacklisted(videoURL: videoURL) else {
            frameInterpolationDebugPrint("视频需要补帧：该视频已加入补帧黑名单，跳过自动入队。视频=\(videoURL.lastPathComponent)")
            return
        }

        guard FrameInterpolationQueueService.shared.autoEnqueueEnabled else {
            frameInterpolationDebugPrint("视频需要补帧：自动加入队列未开启，继续播放原视频。")
            if triggeredByWallpaperSetup { scheduleAutomaticLoopPointAnalysis(videoURL: videoURL) }
            return
        }

        frameInterpolationDebugPrint("视频需要补帧：自动加入补帧队列，补完后会原地替换源视频。")
        FrameInterpolationQueueService.shared.enqueue(
            videoURL: videoURL,
            title: videoURL.deletingPathExtension().lastPathComponent,
            targetFPS: decision.targetFPS,
            source: .automatic,
            onCompleted: { [weak self] sourceURL, outputURL in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.frameInterpolationDecisionsByScreen[screenID]?.shouldInterpolate == true,
                   self.isVideoSourceStillActive(sourceURL, onScreenID: screenID) {
                    self.replacePlayerWithInterpolatedVideoIfNeeded(screenID: screenID, sourceURL: sourceURL, outputURL: outputURL)
                } else {
                    frameInterpolationDebugPrint("补帧完成时壁纸已切换，保留已优化文件但不刷新当前播放器。源视频：\(sourceURL.lastPathComponent)")
                }
                frameInterpolationDebugPrint("补帧队列完成：已将补帧结果写回源视频。视频：\(outputURL.path)")
            }
        })
    }

    private var autoAnalyzeLoopPointEnabled: Bool {
        (UserDefaults.standard.object(forKey: "loop_point_analysis_enabled") as? Bool ?? true)
            && (UserDefaults.standard.object(forKey: "auto_analyze_loop_point") as? Bool ?? false)
    }

    /// Runs the same automatic optimization policy for a freshly baked Scene MP4
    /// without requiring that MP4 to become the active desktop player first.
    ///
    /// A realtime Scene keeps its renderer after baking, but its companion video
    /// still needs the normal "loop analysis -> interpolation" pipeline. Playback
    /// refreshes remain guarded by the active-source check inside the queue service.
    func enqueueAutomaticOptimizationForBakedScene(
        videoURL: URL,
        title: String? = nil,
        pipelineItemID: String? = nil
    ) {
        guard FileManager.default.fileExists(atPath: videoURL.path) else { return }

        let effectiveTitle = title?.isEmpty == false
            ? title!
            : videoURL.deletingPathExtension().lastPathComponent

        let enqueueFrameInterpolation: @MainActor (URL) -> Void = { [weak self] processedURL in
            guard let self else { return }

            guard self.frameInterpolationEnabled,
                  FrameInterpolationQueueService.shared.autoEnqueueEnabled else {
                if let pipelineItemID {
                    VideoOptimizationPipelineStateService.shared.set(.idle, for: pipelineItemID)
                }
                return
            }

            let targetFPS = self.frameInterpolationTargetFPS(for: NSScreen.main ?? NSScreen.screens.first)
            guard targetFPS > 0,
                  !FrameInterpolationQueueService.shared.isBlacklisted(videoURL: processedURL) else {
                if let pipelineItemID {
                    VideoOptimizationPipelineStateService.shared.set(.idle, for: pipelineItemID)
                }
                return
            }

            if FrameInterpolationQueueService.shared.completedRecord(
                videoURL: processedURL,
                satisfying: targetFPS
            ) != nil {
                if let pipelineItemID {
                    VideoOptimizationPipelineStateService.shared.set(.idle, for: pipelineItemID)
                }
                return
            }

            // A duplicate bake completion can attach to the same loop callback.
            // Preserve the first task's visible state instead of clearing it.
            guard !FrameInterpolationQueueService.shared.hasActiveInterpolation(
                videoURL: processedURL,
                satisfying: targetFPS
            ) else {
                return
            }

            if let pipelineItemID {
                VideoOptimizationPipelineStateService.shared.set(.checkingInterpolation, for: pipelineItemID)
            }

            Task { @MainActor [weak self] in
                let needsInterpolation = await FrameInterpolationQueueService.shared.needsInterpolation(
                    videoURL: processedURL,
                    targetFPS: targetFPS
                )
                guard let self,
                      FileManager.default.fileExists(atPath: processedURL.path),
                      self.frameInterpolationEnabled,
                      FrameInterpolationQueueService.shared.autoEnqueueEnabled else {
                    return
                }

                guard needsInterpolation else {
                    VideoOptimizationRecordService.shared.append(
                        .frameNotNeeded,
                        for: processedURL,
                        detail: "Source FPS already satisfies the automatic target",
                        metadata: ["targetFPS": String(targetFPS)]
                    )
                    if let pipelineItemID {
                        VideoOptimizationPipelineStateService.shared.set(.idle, for: pipelineItemID)
                    }
                    return
                }

                let taskID = FrameInterpolationQueueService.shared.enqueue(
                    videoURL: processedURL,
                    title: effectiveTitle,
                    targetFPS: targetFPS,
                    source: .automatic,
                    onFinished: { succeeded in
                        guard let pipelineItemID else { return }
                        VideoOptimizationPipelineStateService.shared.set(
                            succeeded ? .idle : .failed("视频补帧失败"),
                            for: pipelineItemID
                        )
                    }
                )
                if taskID != nil, let pipelineItemID {
                    VideoOptimizationPipelineStateService.shared.set(.frameQueued, for: pipelineItemID)
                } else if let pipelineItemID {
                    VideoOptimizationPipelineStateService.shared.set(.idle, for: pipelineItemID)
                }
            }
        }

        guard autoAnalyzeLoopPointEnabled,
              !VideoLoopPreprocessingService.shared.hasCompletedAnalysis(videoURL) else {
            enqueueFrameInterpolation(videoURL)
            return
        }

        if let pipelineItemID {
            VideoOptimizationPipelineStateService.shared.set(.loopQueued, for: pipelineItemID)
        }
        LoopPointAnalysisQueueService.shared.enqueue(videoURL: videoURL, title: effectiveTitle) { completedURL, succeeded in
            if !succeeded {
                frameInterpolationDebugPrint("Scene 烘焙视频循环点分析失败，继续按补帧开关处理：\(completedURL.lastPathComponent)")
            }
            enqueueFrameInterpolation(completedURL)
        }
    }

    @discardableResult
    private func scheduleAutomaticLoopPointAnalysis(
        videoURL: URL,
        onFinished: @escaping () -> Void = {}
    ) -> Bool {
        guard autoAnalyzeLoopPointEnabled,
              FileManager.default.fileExists(atPath: videoURL.path),
              !VideoLoopPreprocessingService.shared.hasCompletedAnalysis(videoURL) else { return false }

        LoopPointAnalysisQueueService.shared.enqueue(videoURL: videoURL) { [weak self] completedURL, succeeded in
            if let self {
                if succeeded {
                    self.reloadPlaybackAfterLoopPointAnalysis(videoURL: completedURL)
                    // 全局共享播放器的刷新是异步黑场热替换。替换提交后会由新播放器
                    // 再次进入 prepareFrameInterpolation，届时才开始补帧，保证任务严格串行。
                    if self.usesSharedGlobalVideoPlayer {
                        return
                    }
                } else {
                    frameInterpolationDebugPrint("循环点分析失败：\(completedURL.lastPathComponent)")
                }
            }
            onFinished()
        }
        return true
    }

    private func replacePlayerWithInterpolatedVideoIfNeeded(screenID: String, sourceURL: URL, outputURL: URL) {
        guard isVideoSourceStillActive(sourceURL, onScreenID: screenID) else {
            frameInterpolationDebugPrint("跳过补帧播放器刷新：当前屏幕已切换到其他壁纸。源视频：\(sourceURL.lastPathComponent)")
            return
        }
        if usesSharedGlobalVideoPlayer {
            guard screenID == NSScreen.screens.first?.wallpaperScreenIdentifier else { return }
            try? rebuildWindows(animatedTransition: true)
            return
        }
        guard frameInterpolationEnabled,
              frameInterpolatedPlaybackURLByScreen[screenID]?.standardizedFileURL != outputURL.standardizedFileURL,
              let screen = NSScreen.screens.first(where: { $0.wallpaperScreenIdentifier == screenID }),
              let window = windows[screenID],
              let containerView = window.contentView as? WallpaperVideoContainerView else {
            return
        }

        let oldPlayer = players[screenID]
        let oldLooper = loopers[screenID]
        let schedulerConfig = WallpaperSchedulerService.shared.config.resolvedDisplayConfig(for: screenID)
        let isOnEndMode = schedulerConfig.isEnabled && schedulerConfig.isOnEndMode
        let hdrMetadataEnabled = UserDefaults.standard.object(forKey: "hdr_enabled") as? Bool ?? true
        let components = makePlayerComponents(
            for: screen,
            videoURL: outputURL,
            muted: isMuted,
            hdrMetadataEnabled: hdrMetadataEnabled,
            enableLooping: !isOnEndMode
        )

        if let looper = components.looper {
            loopers[screenID] = looper
        } else {
            loopers.removeValue(forKey: screenID)
        }

        players[screenID] = components.player
        frameInterpolatedPlaybackURLByScreen[screenID] = outputURL
        containerView.playerLayer.player = components.player
        containerView.playerLayer.videoGravity = .resizeAspectFill
        applyCropToScreen(screen)
        applyPlayerAudioPolicy(components.player, muted: isMuted, volume: volumeByScreen[screenID] ?? volume)
        if !isPaused {
            components.player.play()
        }

        if isOnEndMode {
            onEndModeScreens.insert(screenID)
            setupPlaybackEndObserver(for: screenID, player: components.player, item: components.item)
        }

        oldLooper?.disableLooping()
        if let oldPlayer, oldPlayer !== components.player {
            oldPlayer.pause()
            oldPlayer.removeAllItems()
            retainPlayersTemporarily([oldPlayer])
        }
        frameInterpolationDebugPrint("播放器已刷新：补帧源视频=\(sourceURL.lastPathComponent)，播放文件=\(outputURL.lastPathComponent)")
    }

    func restoreOriginalVideoAfterDeletingFrameInterpolation(videoURL: URL, targetFPSs: Set<Int>) {
        for screen in NSScreen.screens {
            let screenID = screen.wallpaperScreenIdentifier
            let currentSourceURL = videoURLByScreen[screenID]
                ?? videoURLByScreenFingerprint[screen.wallpaperScreenFingerprint]
                ?? currentVideoURL
            guard currentSourceURL?.standardizedFileURL == videoURL.standardizedFileURL,
                  targetFPSs.contains(frameInterpolationTargetFPS(for: screen)),
                  frameInterpolatedPlaybackURLByScreen[screenID] != nil else {
                continue
            }
            replacePlayerWithOriginalVideoIfNeeded(screenID: screenID, sourceURL: videoURL)
        }
    }

    func reloadPlaybackAfterInPlaceInterpolation(videoURL: URL) {
        if sharedReplacementPreparingVideoURL?.standardizedFileURL == videoURL.standardizedFileURL {
            return
        }
        for screen in NSScreen.screens {
            let screenID = screen.wallpaperScreenIdentifier
            let currentSourceURL = videoURLByScreen[screenID]
                ?? videoURLByScreenFingerprint[screen.wallpaperScreenFingerprint]
                ?? currentVideoURL
            guard currentSourceURL?.standardizedFileURL == videoURL.standardizedFileURL else {
                continue
            }
            replacePlayerWithInterpolatedVideoIfNeeded(screenID: screenID, sourceURL: videoURL, outputURL: videoURL)
        }
    }

    func reloadPlaybackAfterLoopPointAnalysis(videoURL: URL) {
        if sharedReplacementPreparingVideoURL?.standardizedFileURL == videoURL.standardizedFileURL {
            return
        }
        for screen in NSScreen.screens {
            let screenID = screen.wallpaperScreenIdentifier
            let currentSourceURL = videoURLByScreen[screenID]
                ?? videoURLByScreenFingerprint[screen.wallpaperScreenFingerprint]
                ?? currentVideoURL
            guard currentSourceURL?.standardizedFileURL == videoURL.standardizedFileURL else {
                continue
            }
            replacePlayerWithOriginalVideoIfNeeded(screenID: screenID, sourceURL: videoURL)
        }
    }

    private func replacePlayerWithOriginalVideoIfNeeded(screenID: String, sourceURL: URL) {
        guard isVideoSourceStillActive(sourceURL, onScreenID: screenID) else {
            frameInterpolationDebugPrint("跳过循环点分析后的播放器刷新：当前屏幕已切换到其他壁纸。源视频：\(sourceURL.lastPathComponent)")
            return
        }
        if usesSharedGlobalVideoPlayer {
            guard screenID == NSScreen.screens.first?.wallpaperScreenIdentifier else { return }
            try? rebuildWindows(animatedTransition: true)
            return
        }
        guard let screen = NSScreen.screens.first(where: { $0.wallpaperScreenIdentifier == screenID }),
              let window = windows[screenID],
              let containerView = window.contentView as? WallpaperVideoContainerView else {
            return
        }

        let oldPlayer = players[screenID]
        let oldLooper = loopers[screenID]
        let schedulerConfig = WallpaperSchedulerService.shared.config.resolvedDisplayConfig(for: screenID)
        let isOnEndMode = schedulerConfig.isEnabled && schedulerConfig.isOnEndMode
        let hdrMetadataEnabled = UserDefaults.standard.object(forKey: "hdr_enabled") as? Bool ?? true
        let components = makePlayerComponents(
            for: screen,
            videoURL: sourceURL,
            muted: isMuted,
            hdrMetadataEnabled: hdrMetadataEnabled,
            enableLooping: !isOnEndMode
        )

        if let looper = components.looper {
            loopers[screenID] = looper
        } else {
            loopers.removeValue(forKey: screenID)
        }

        players[screenID] = components.player
        frameInterpolatedPlaybackURLByScreen.removeValue(forKey: screenID)
        containerView.playerLayer.player = components.player
        containerView.playerLayer.videoGravity = .resizeAspectFill
        applyCropToScreen(screen)
        applyPlayerAudioPolicy(components.player, muted: isMuted, volume: volumeByScreen[screenID] ?? volume)
        if !isPaused {
            components.player.play()
        }

        if isOnEndMode {
            onEndModeScreens.insert(screenID)
            setupPlaybackEndObserver(for: screenID, player: components.player, item: components.item)
        }

        oldLooper?.disableLooping()
        if let oldPlayer, oldPlayer !== components.player {
            oldPlayer.pause()
            oldPlayer.removeAllItems()
            retainPlayersTemporarily([oldPlayer])
        }
        frameInterpolationDebugPrint("播放器已刷新为当前源视频：屏幕=\(screen.localizedName)，视频=\(sourceURL.lastPathComponent)")
    }

    /// 优化导出在后台运行时，调度器可能已将该屏切换到其它壁纸。
    /// 只有源视频仍是该屏正在播放的资源时，才允许优化完成回调重建播放器。
    private func isVideoSourceStillActive(_ sourceURL: URL, onScreenID screenID: String) -> Bool {
        guard let screen = NSScreen.screens.first(where: {
            $0.wallpaperScreenIdentifier == screenID
        }), let activeURL = videoURL(for: screen) else {
            return false
        }
        return activeURL.standardizedFileURL == sourceURL.standardizedFileURL
    }

    private func resetFrameInterpolation(for screenID: String, player: AVQueuePlayer, item: AVPlayerItem) {
        frameInterpolatedPlaybackURLByScreen.removeValue(forKey: screenID)
        item.videoComposition = nil
        for queuedItem in player.items() {
            queuedItem.videoComposition = nil
        }
    }

    private func clearVideoLetterboxState() {
        for task in videoLetterboxAnalysisTasks.values { task.cancel() }
        videoLetterboxAnalysisTasks.removeAll()
        videoLetterboxContentCrops.removeAll()
    }

    private func clearFrameInterpolationState() {
        for task in frameInterpolationAnalysisTasks.values { task.cancel() }
        frameInterpolationAnalysisTasks.removeAll()
        frameInterpolationDecisionsByScreen.removeAll()
        frameInterpolatedPlaybackURLByScreen.removeAll()
    }

    private func resetVideoLetterboxState(for screenID: String) {
        videoLetterboxAnalysisTasks[screenID]?.cancel()
        videoLetterboxAnalysisTasks.removeValue(forKey: screenID)
        videoLetterboxContentCrops.removeValue(forKey: screenID)
    }

    private func resetFrameInterpolationState(for screenID: String) {
        frameInterpolationAnalysisTasks[screenID]?.cancel()
        frameInterpolationAnalysisTasks.removeValue(forKey: screenID)
        frameInterpolationDecisionsByScreen.removeValue(forKey: screenID)
        frameInterpolatedPlaybackURLByScreen.removeValue(forKey: screenID)
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

            // macOS 26+：仅当用户未启用动态锁屏时才清空帧源映射。
            // 使用持久化设置 isLockScreenEnabled 而非 isLockScreenMirroringActive，
            // 因为后者在桌面场景（屏幕未锁定）下始终为 false。
            if #available(macOS 26.0, *) {
                if !isLockScreenEnabled {
                    LockScreenWallpaperService.shared.clearMirroringSourceCache()
                }
            }

            teardownAllWindows()
            // 对称关闭静态图 overlay（保持久化，便于用户再次开启时恢复，与 stopWallpaper 保留 video 状态语义一致）
            StaticImageWallpaperOverlayManager.shared.hideAll()
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
            // 停止所有壁纸 → 停用音频会话，释放音频设备
            deactivateAudioSession()
            // 不删除保存的状态，以便下次可以恢复
            return
        }

        // 单屏停止：只拆掉该屏幕的视频层，不回退到旧静态壁纸
        let screenID = targetScreen.wallpaperScreenIdentifier
        let screenFingerprint = targetScreen.wallpaperScreenFingerprint
        // 对称关闭该屏静态图 overlay（保持久化，便于再次开启时恢复）
        StaticImageWallpaperOverlayManager.shared.hide(for: targetScreen)

        // 锁屏镜像实例活跃时，也只需要清理该屏帧源追踪；动态锁屏开启时不能回退到静态 poster。
        if isLockScreenExtensionActive {
            videoTargetScreenIDs.remove(screenID)
            videoTargetScreenFingerprints.remove(screenFingerprint)
            videoURLByScreen.removeValue(forKey: screenID)
            videoURLByScreenFingerprint.removeValue(forKey: screenFingerprint)
            if let posterURL = posterURLByScreen.removeValue(forKey: screenID) {
                if shouldSkipStaticPosterForDynamicLockScreen {
                    print("[VideoWallpaperManager] 🔒 动态锁屏已启用，停止单屏时跳过静态 poster 回退")
                } else {
                    setPosterAsDesktopWallpaper(posterURL, targetScreen: targetScreen)
                    DesktopWallpaperSyncManager.shared.registerWallpaperSet(posterURL, for: targetScreen)
                }
            }
            posterURLByScreenFingerprint.removeValue(forKey: screenFingerprint)

            if videoURLByScreen.isEmpty {
                // 所有屏幕都停止了；仅在动态锁屏关闭时清空锁屏镜像帧源映射。
                if #available(macOS 26.0, *) {
                    if !isLockScreenEnabled {
                        LockScreenWallpaperService.shared.clearMirroringSourceCache()
                    }
                }
                currentVideoURL = nil
                currentPosterURL = nil
                isPaused = false
                videoTargetScreenIDs = []
                videoTargetScreenFingerprints = []
            }
            persistState()
            syncCurrentVideoURL()
            return
        }

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
            // 最后一块屏停止 → 停用音频会话，释放音频设备，防止 macOS 因本 App 残留音频会话而自动连接蓝牙设备
            deactivateAudioSession()
        } else {
            lastAppliedScreenConfigurations = currentTargetScreenConfigurations()
        }
        if #available(macOS 26.0, *),
           let screenNumber = targetScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            WallpaperExtensionSocketServer.shared.unregisterDisplayVideo(displayID: screenNumber.uint32Value)
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

        // 退出前为每个目标屏幕持久化其 poster。动态锁屏启用时跳过，避免覆盖锁屏实例选择。
        if shouldSkipStaticPosterForDynamicLockScreen {
            print("[VideoWallpaperManager] 🔒 动态锁屏已启用，退出前跳过静态 poster 写入")
        } else {
            for screen in screensForVideoWallpaperTargets() {
                if let posterURL = posterURL(for: screen) {
                    applyPosterAsDesktopWallpaperSync(posterURL, targetScreen: screen)
                    DesktopWallpaperSyncManager.shared.registerWallpaperSet(posterURL, for: screen)
                }
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
        playerItemObserverTokens.removeAll()
        fadeInTimeouts.values.forEach { $0.cancel() }
        fadeInTimeouts.removeAll()
        // 清理播放结束观察者（播完即换模式）
        for observer in playbackEndObservers.values {
            NotificationCenter.default.removeObserver(observer)
        }
        playbackEndObservers.removeAll()
        onEndModeScreens.removeAll()

        for window in windows.values {
            if let contentView = window.contentView as? WallpaperVideoContainerView {
                contentView.cancelPlayerTransitionIfNeeded()
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
        videoSizes.removeAll()
        clearVideoLetterboxState()
        clearFrameInterpolationState()
        lastAppliedScreenConfigurations.removeAll()
    }

    /// 仅拆掉本机 AVPlayer 视频壁纸，**不**调用 `WallpaperEngineXBridge.stopWallpaper()`。
    /// 在即将通过 CLI 设置 scene / web 等 WE 壁纸前调用，否则会误停 CLI 且把 `isControllingExternalEngine` 清掉，菜单栏暂停恢复会走错视频分支。
    func stopNativeVideoWallpaperOnly(for targetScreen: NSScreen? = nil) {
        AppLogger.error(.wallpaper, "stopNativeVideoWallpaperOnly", metadata: [
            "targetScreen": targetScreen?.localizedName ?? "nil(全部)",
            "windows": windows.count,
            "players": players.count,
            "isLockScreenExtensionActive": isLockScreenExtensionActive
        ])
        guard let targetScreen = targetScreen else {
            // 全局停止（原有逻辑）
            teardownAllWindows()
            currentVideoURL = nil
            wallpaperChangeCount &+= 1
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
            // macOS 26+：仅当用户未启用动态锁屏时才清空锁屏镜像帧源缓存。
            // 使用持久化设置 isLockScreenEnabled 而非 isLockScreenMirroringActive，
            // 因为后者在桌面场景（屏幕未锁定）下始终为 false。
            if #available(macOS 26.0, *) {
                if !isLockScreenEnabled {
                    LockScreenWallpaperService.shared.clearMirroringSourceCache()
                }
            }
            // 停止所有本机视频壁纸 → 停用音频会话，释放音频设备，防止 macOS 因本 App 残留音频会话而自动连接蓝牙设备
            deactivateAudioSession()
            return
        }

        // 单屏停止：只拆掉该屏幕的视频层，不回退到旧静态壁纸
        let screenID = targetScreen.wallpaperScreenIdentifier
        let screenFingerprint = targetScreen.wallpaperScreenFingerprint

        // 锁屏镜像实例活跃时，也只需要清理 per-screen 帧源追踪。
        if isLockScreenExtensionActive {
            videoTargetScreenIDs.remove(screenID)
            videoTargetScreenFingerprints.remove(screenFingerprint)
            videoURLByScreen.removeValue(forKey: screenID)
            videoURLByScreenFingerprint.removeValue(forKey: screenFingerprint)
            posterURLByScreen.removeValue(forKey: screenID)
            posterURLByScreenFingerprint.removeValue(forKey: screenFingerprint)

            if videoURLByScreen.isEmpty {
                if #available(macOS 26.0, *) {
                    if !isLockScreenEnabled {
                        LockScreenWallpaperService.shared.clearMirroringSourceCache()
                    }
                }
                currentVideoURL = nil
                currentPosterURL = nil
                isPaused = false
                videoTargetScreenIDs = []
                videoTargetScreenFingerprints = []
                defaults.removeObject(forKey: stateKey)
                // 最后一块屏停止 → 停用音频会话，释放音频设备，防止 macOS 因本 App 残留音频会话而自动连接蓝牙设备
                deactivateAudioSession()
            }
            syncCurrentVideoURL()
            return
        }

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
        if #available(macOS 26.0, *),
           let screenNumber = targetScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            WallpaperExtensionSocketServer.shared.unregisterDisplayVideo(displayID: screenNumber.uint32Value)
        }
        syncCurrentVideoURL()
    }

    private func retainPlayersTemporarily(_ retainedPlayers: [AVQueuePlayer]) {
        guard !retainedPlayers.isEmpty else { return }

        var cleanup: DispatchWorkItem?
        cleanup = DispatchWorkItem { [weak self, retainedPlayers] in
            _ = retainedPlayers
            if let cleanup {
                self?.pendingPlayerCleanups.removeAll { $0 === cleanup }
            }
        }

        guard let cleanup else { return }
        pendingPlayerCleanups.append(cleanup)
        DispatchQueue.main.asyncAfter(deadline: .now() + delayedCleanupRetention, execute: cleanup)
    }

    private func retainWindowsTemporarily(_ retainedWindows: [WallpaperVideoWindow]) {
        guard !retainedWindows.isEmpty else { return }

        var cleanup: DispatchWorkItem?
        cleanup = DispatchWorkItem { [weak self, retainedWindows] in
            _ = retainedWindows
            if let cleanup {
                self?.pendingWindowCleanups.removeAll { $0 === cleanup }
            }
        }

        guard let cleanup else { return }
        pendingWindowCleanups.append(cleanup)
        DispatchQueue.main.asyncAfter(deadline: .now() + delayedCleanupRetention, execute: cleanup)
    }

    /// 拆除单个屏幕的视频窗口、player 和 looper
    private func teardownWindow(for screenID: String) {
        AppLogger.error(.wallpaper, "Video teardown single window", metadata: [
            "screenID": screenID,
            "hasWindow": windows[screenID] != nil,
            "hasPlayer": players[screenID] != nil,
            "hasLooper": loopers[screenID] != nil,
            "hasItemObserver": playerItemObservers[screenID] != nil,
            "hasPlaybackEndObserver": playbackEndObservers[screenID] != nil
        ])

        playerItemObservers[screenID]?.invalidate()
        playerItemObservers.removeValue(forKey: screenID)
        playerItemObserverTokens.removeValue(forKey: screenID)
        fadeInTimeouts[screenID]?.cancel()
        fadeInTimeouts.removeValue(forKey: screenID)
        if let observer = playbackEndObservers[screenID] {
            NotificationCenter.default.removeObserver(observer)
            playbackEndObservers.removeValue(forKey: screenID)
        }
        onEndModeScreens.remove(screenID)

        if let looper = loopers[screenID] {
            looper.disableLooping()
            loopers.removeValue(forKey: screenID)
        }
        if let window = windows[screenID] {
            if let contentView = window.contentView as? WallpaperVideoContainerView {
                contentView.cancelPlayerTransitionIfNeeded()
                contentView.playerLayer.player = nil
            }
            window.contentView = nil
            window.orderOut(nil)
            windows.removeValue(forKey: screenID)
            retainWindowsTemporarily([window])
        }
        if let player = players[screenID] {
            player.pause()
            player.removeAllItems()
            players.removeValue(forKey: screenID)
            retainPlayersTemporarily([player])
        }
        videoSizes.removeValue(forKey: screenID)
        videoLetterboxContentCrops.removeValue(forKey: screenID)
        videoLetterboxAnalysisTasks[screenID]?.cancel()
        videoLetterboxAnalysisTasks.removeValue(forKey: screenID)
        resetFrameInterpolationState(for: screenID)
        pendingDisplaySwitches.removeValue(forKey: screenID)
        if activeDisplaySwitchScreenID == screenID {
            releaseDisplaySwitchGate(screenID: screenID, reason: "teardownWindow")
        }
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

    private func schedulePosterAsDesktopWallpaperAfterPlaybackSettles(
        _ posterURL: URL,
        targetScreen: NSScreen?,
        expectedVideoURL: URL
    ) {
        let expectedURL = expectedVideoURL.standardizedFileURL
        let delayNanoseconds = UInt64(deferredPosterSyncDelay * 1_000_000_000)
        let targets: [(screenID: String, fingerprint: String)] = (targetScreen.map { [$0] } ?? NSScreen.screens)
            .map { ($0.wallpaperScreenIdentifier, $0.wallpaperScreenFingerprint) }

        for target in targets {
            posterTasks[target.screenID]?.cancel()
            posterTasks[target.screenID] = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: delayNanoseconds)
                guard let self else { return }
                defer { self.posterTasks.removeValue(forKey: target.screenID) }
                guard !Task.isCancelled else { return }
                guard let currentScreen = NSScreen.screens.first(where: { screen in
                    screen.wallpaperScreenIdentifier == target.screenID ||
                    screen.wallpaperScreenFingerprint == target.fingerprint
                }) else {
                    return
                }
                guard self.videoURL(for: currentScreen)?.standardizedFileURL == expectedURL else {
                    return
                }
                await self.applyPosterAsDesktopWallpaper(posterURL, targetScreen: currentScreen)
            }
        }
    }

    private func cacheDisplaySwitchIfNeeded(
        videoURL: URL,
        posterURL: URL?,
        muted: Bool,
        targetScreen: NSScreen
    ) -> Bool {
        let screenID = targetScreen.wallpaperScreenIdentifier
        let pending = PendingDisplayVideoSwitch(
            videoURL: videoURL,
            posterURL: posterURL,
            muted: muted,
            screenID: screenID,
            fingerprint: targetScreen.wallpaperScreenFingerprint,
            screenName: targetScreen.localizedName,
            requestedAt: Date()
        )

        if let activeDisplaySwitchScreenID {
            pendingDisplaySwitches[screenID] = pending
            AppLogger.debug(.wallpaper, "Video switch cached while another display is stabilizing", metadata: [
                "activeScreenID": activeDisplaySwitchScreenID,
                "queuedScreenID": screenID,
                "queuedScreen": targetScreen.localizedName,
                "video": videoURL.lastPathComponent,
                "queueSize": pendingDisplaySwitches.count
            ])
            return true
        }

        activeDisplaySwitchScreenID = screenID
        scheduleDisplaySwitchRelease(screenID: screenID, delay: displaySwitchTimeout, reason: "timeout")
        AppLogger.debug(.wallpaper, "Video switch gate acquired", metadata: [
            "screenID": screenID,
            "screen": targetScreen.localizedName,
            "video": videoURL.lastPathComponent
        ])
        return false
    }

    private func scheduleDisplaySwitchStableRelease(screenID: String, reason: String) {
        guard activeDisplaySwitchScreenID == screenID else { return }
        scheduleDisplaySwitchRelease(screenID: screenID, delay: displaySwitchStableDelay, reason: reason)
    }

    private func scheduleDisplaySwitchRelease(screenID: String, delay: TimeInterval, reason: String) {
        displaySwitchReleaseWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.releaseDisplaySwitchGate(screenID: screenID, reason: reason)
        }
        displaySwitchReleaseWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func releaseDisplaySwitchGate(screenID: String, reason: String) {
        guard activeDisplaySwitchScreenID == screenID else { return }
        displaySwitchReleaseWorkItem?.cancel()
        displaySwitchReleaseWorkItem = nil
        activeDisplaySwitchScreenID = nil

        AppLogger.debug(.wallpaper, "Video switch gate released", metadata: [
            "screenID": screenID,
            "reason": reason,
            "queueSize": pendingDisplaySwitches.count
        ])

        applyNextCachedDisplaySwitchIfPossible()
    }

    private func applyNextCachedDisplaySwitchIfPossible() {
        guard activeDisplaySwitchScreenID == nil else { return }
        guard let next = pendingDisplaySwitches.values.sorted(by: { $0.requestedAt < $1.requestedAt }).first else {
            return
        }

        pendingDisplaySwitches.removeValue(forKey: next.screenID)
        guard let screen = NSScreen.screens.first(where: { screen in
            screen.wallpaperScreenIdentifier == next.screenID ||
            screen.wallpaperScreenFingerprint == next.fingerprint
        }) else {
            AppLogger.error(.wallpaper, "Dropped cached video switch because display is gone", metadata: [
                "screenID": next.screenID,
                "fingerprint": next.fingerprint,
                "screen": next.screenName,
                "video": next.videoURL.lastPathComponent
            ])
            applyNextCachedDisplaySwitchIfPossible()
            return
        }

        AppLogger.debug(.wallpaper, "Applying cached video switch", metadata: [
            "screenID": screen.wallpaperScreenIdentifier,
            "screen": screen.localizedName,
            "video": next.videoURL.lastPathComponent,
            "remainingQueue": pendingDisplaySwitches.count
        ])

        do {
            try applyVideoWallpaper(
                from: next.videoURL,
                posterURL: next.posterURL,
                muted: next.muted,
                targetScreen: screen,
                animatedTransition: true
            )
        } catch {
            AppLogger.error(.wallpaper, "Cached video switch failed", metadata: [
                "screenID": screen.wallpaperScreenIdentifier,
                "screen": screen.localizedName,
                "video": next.videoURL.lastPathComponent,
                "error": error.localizedDescription
            ])
            if activeDisplaySwitchScreenID == screen.wallpaperScreenIdentifier {
                releaseDisplaySwitchGate(screenID: screen.wallpaperScreenIdentifier, reason: "cachedSwitchFailed")
            } else {
                applyNextCachedDisplaySwitchIfPossible()
            }
        }
    }

    /// 恢复场景专用的同步 poster 设置，确保桌面/锁屏底图在视频窗口重建前已就绪
    private func applyPosterAsDesktopWallpaperSync(_ posterURL: URL, targetScreen: NSScreen? = nil) {
        // 安全兜底：动态锁屏启用时绝不设置静态桌面壁纸。
        if shouldSkipStaticPosterForDynamicLockScreen {
            print("[VideoWallpaperManager] 🔒 [sync poster safety] 动态锁屏已启用，跳过静态桌面 poster 设置")
            return
        }

        // 系统壁纸同步关闭时，冻结 setDesktopImageURL 链路（mp4/场景/web 动态壁纸不受影响）
        if !isSystemWallpaperSyncEnabled {
            print("[VideoWallpaperManager] 🧊 [sync poster safety] 系统壁纸同步已关闭，跳过静态桌面 poster 设置")
            return
        }

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

        // 安全兜底：动态锁屏启用时绝不设置静态桌面壁纸，避免覆盖用户手动选择的锁屏实例。
        if shouldSkipStaticPosterForDynamicLockScreen {
            print("[VideoWallpaperManager] 🔒 [poster safety] 动态锁屏已启用，跳过静态桌面 poster 设置")
            return
        }

        // 系统壁纸同步关闭时，冻结 setDesktopImageURL 链路（mp4/场景/web 动态壁纸不受影响）
        if !isSystemWallpaperSyncEnabled {
            print("[VideoWallpaperManager] 🧊 [poster safety] 系统壁纸同步已关闭，跳过静态桌面 poster 设置")
            return
        }

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
            AppLogger.error(.wallpaper, "Video restore begin", metadata: [
                "explicitTargets": savedState.hasExplicitScreenTargets,
                "screenIDs": (savedState.videoScreenIDs ?? []).joined(separator: ","),
                "currentScreens": NSScreen.screens.map(\.wallpaperScreenIdentifier).joined(separator: ",")
            ])

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

                // 启动恢复时不要重写系统静态 poster。上次退出前的系统壁纸已经是兜底图，
                // 此处只登记状态；避免三屏同时启动播放器时再触发 WindowServer/桌面壁纸写入。
                for screen in screensForVideoWallpaperTargets() {
                    if let posterURL = posterURL(for: screen) {
                        DesktopWallpaperSyncManager.shared.registerWallpaperSet(posterURL, for: screen)
                    }
                }
                try rebuildWindows()
                updateAudioSession()
                if savedState.isPaused {
                    pauseWallpaper()
                }
                persistState()

                // 恢复完成后,如果扩展已激活,需要同步视频源到扩展
                // 开机时扩展可能先于 App 视频源恢复而启动,此时 checkExtensionState() 因 hasActiveVideoWallpaper=false 未触发同步
                if #available(macOS 26.0, *), isLockScreenEnabled {
                    if isLockScreenExtensionActive {
                        print("[VideoWallpaperManager] 📺 视频源恢复完成,扩展已激活,同步视频源到锁屏扩展")
                        syncAllDisplayVideosToExtension()
                    } else {
                        // 扩展未激活，可能是开机后系统未自动启动扩展
                        // 延迟 2 秒后发送系统桌面通知，尝试触发系统刷新壁纸设置从而启动扩展
                        print("[VideoWallpaperManager] ⏳ 扩展未激活，延迟触发系统壁纸刷新")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                            guard let self else { return }
                            print("[VideoWallpaperManager] 📢 发送 com.apple.desktop 通知，尝试触发扩展启动")
                            // 发送系统桌面壁纸刷新通知，可能触发系统重新启动扩展
                            DistributedNotificationCenter.default().postNotificationName(
                                NSNotification.Name("com.apple.desktop"),
                                object: nil,
                                userInfo: nil,
                                deliverImmediately: true
                            )
                            // 再延迟 3 秒后检查扩展是否被启动
                            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                                guard let self else { return }
                                self.checkExtensionState()
                                if self.isLockScreenExtensionActive {
                                    print("[VideoWallpaperManager] 📺 系统通知触发后扩展已激活，同步视频源")
                                    self.syncAllDisplayVideosToExtension()
                                } else {
                                    print("[VideoWallpaperManager] ⚠️ 系统通知未能触发扩展启动，等待用户手动打开设置")
                                }
                            }
                        }
                    }
                }
            } else {
                discardOriginalWallpaperSnapshot()
                currentVideoURL = url
                currentPosterURL = globalPosterURL
                isMuted = savedState.isMuted
                volume = savedState.volume ?? (savedState.isMuted ? 0 : 1)
                volumeByScreen = savedState.volumeByScreen ?? [:]
                volumeByScreenFingerprint = savedState.volumeByScreenFingerprint ?? [:]
                isPaused = false
                let screens = NSScreen.screens
                videoTargetScreenIDs = Set(screens.map(\.wallpaperScreenIdentifier))
                videoTargetScreenFingerprints = Set(screens.map(\.wallpaperScreenFingerprint))
                videoURLByScreen.removeAll()
                videoURLByScreenFingerprint.removeAll()
                posterURLByScreen.removeAll()
                posterURLByScreenFingerprint.removeAll()

                for screen in NSScreen.screens {
                    let screenID = screen.wallpaperScreenIdentifier
                    resetVideoLetterboxState(for: screenID)
                    resetFrameInterpolationState(for: screenID)
                    videoURLByScreen[screenID] = url
                    videoURLByScreenFingerprint[screen.wallpaperScreenFingerprint] = url
                    posterURLByScreen[screenID] = globalPosterURL
                    posterURLByScreenFingerprint[screen.wallpaperScreenFingerprint] = globalPosterURL
                    if let globalPosterURL {
                        DesktopWallpaperSyncManager.shared.registerWallpaperSet(globalPosterURL, for: screen)
                    }
                }

                try rebuildWindows()
                updateAudioSession()
                syncCurrentVideoURL()
                persistState()

                for screen in screens {
                    let screenVolume = volume(for: screen)
                    let screenID = screen.wallpaperScreenIdentifier
                    players[screenID]?.volume = isMuted ? 0 : Float(screenVolume)
                }
                if savedState.isPaused {
                    pauseWallpaper()
                }

                if #available(macOS 26.0, *), isLockScreenEnabled {
                    LockScreenWallpaperService.shared.syncInstanceCatalogToSocketServer()
                    syncAllDisplayVideosToExtension()
                }
            }
            AppLogger.error(.wallpaper, "Video restore completed", metadata: [
                "windows": String(windows.count),
                "players": String(players.count)
            ])
        } catch {
            AppLogger.error(.wallpaper, "Video restore failed", metadata: [
                "error": error.localizedDescription
            ])
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
            AppLogger.error(.wallpaper, "Video wallpaper screen parameters changed", metadata: [
                "active": self.hasActiveVideoWallpaper,
                "windows": self.windows.keys.sorted().joined(separator: ","),
                "targetIDs": self.videoTargetScreenIDs.sorted().joined(separator: ","),
                "currentScreens": NSScreen.screens.map(\.wallpaperScreenIdentifier).joined(separator: ",")
            ])
            if #available(macOS 26.0, *) {
                LockScreenWallpaperService.shared.syncDisplayInstancesToSocketServer()
            }
            guard self.hasActiveVideoWallpaper else { return }

            // 防抖：延迟 300ms 执行，避免屏幕参数变化时的频繁重建
            self.pendingRebuildWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self, self.hasActiveVideoWallpaper else { return }

                self.relinkDisplayStateForCurrentScreens()

                guard self.hasEffectiveTargetDisplayChange() else {
                    if self.synchronizeExistingWindowFramesToCurrentScreens() {
                        NSLog("[VideoWallpaperManager] Synchronized existing window frames after screen parameter notification")
                    }
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
            if #available(macOS 26.0, *) {
                LockScreenWallpaperService.shared.syncDisplayInstancesToSocketServer()
            }

            // 屏幕唤醒时防抖重建
            self.pendingWakeRebuildWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                if self.hasActiveVideoWallpaper {
                    self.repairWindowsForCurrentDisplayConfiguration(reason: "screensWake")
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

                // 二次延迟重建：外接显示器可能 1~3 秒后才被 macOS 完全枚举
                // 记录当前缺失指纹的屏幕，稍后重试
                let missingFingerprints = self.videoTargetScreenFingerprints.subtracting(
                    Set(NSScreen.screens.map { $0.wallpaperScreenFingerprint })
                )
                if !missingFingerprints.isEmpty {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                        guard let self = self, self.hasActiveVideoWallpaper else { return }
                        self.relinkDisplayStateForCurrentScreens()
                        let retryScreens = NSScreen.screens.filter { screen in
                            missingFingerprints.contains(screen.wallpaperScreenFingerprint) &&
                            self.windows[screen.wallpaperScreenIdentifier] == nil
                        }
                        for screen in retryScreens {
                            try? self.rebuildWindows(targetScreen: screen)
                        }
                        if !retryScreens.isEmpty {
                            NSLog("[VideoWallpaperManager] Retry rebuild for \\(retryScreens.count) late-appearing screen(s) after screensWake")
                        }
                    }
                }
            }
            self.pendingWakeRebuildWorkItem = workItem
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
            if #available(macOS 26.0, *) {
                LockScreenWallpaperService.shared.syncDisplayInstancesToSocketServer()
            }

            self.pendingWakeRebuildWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                if self.hasActiveVideoWallpaper {
                    self.repairWindowsForCurrentDisplayConfiguration(reason: "systemWake")
                }
                if !self.isPaused {
                    for (screenID, player) in self.players {
                        player.play()
                        self.hidePosterImage(for: screenID)
                    }
                }
                // 唤醒后立即重新评估自动暂停状态，避免 AutoPause 之前暂停的屏幕被错误恢复导致闪烁
                DynamicWallpaperAutoPauseManager.shared.reevaluateCurrentState()

                // 二次延迟重建：外接显示器可能 1~3 秒后才被 macOS 完全枚举
                let missingFingerprints = self.videoTargetScreenFingerprints.subtracting(
                    Set(NSScreen.screens.map { $0.wallpaperScreenFingerprint })
                )
                if !missingFingerprints.isEmpty {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                        guard let self = self, self.hasActiveVideoWallpaper else { return }
                        self.relinkDisplayStateForCurrentScreens()
                        let retryScreens = NSScreen.screens.filter { screen in
                            missingFingerprints.contains(screen.wallpaperScreenFingerprint) &&
                            self.windows[screen.wallpaperScreenIdentifier] == nil
                        }
                        for screen in retryScreens {
                            try? self.rebuildWindows(targetScreen: screen)
                        }
                        if !retryScreens.isEmpty {
                            NSLog("[VideoWallpaperManager] Retry rebuild for \\(retryScreens.count) late-appearing screen(s) after systemWake")
                        }
                    }
                }
            }
            self.pendingWakeRebuildWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
        }
    }

    private func relinkDisplayStateForCurrentScreens() {
        let currentScreenIDs = Set(NSScreen.screens.map(\.wallpaperScreenIdentifier))
        videoTargetScreenIDs = videoTargetScreenIDs.intersection(currentScreenIDs)

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

        migrateSingleActiveVideoWallpaperToCurrentScreenIfNeeded()
        syncCurrentVideoURL()
    }

    private func migrateSingleActiveVideoWallpaperToCurrentScreenIfNeeded() {
        guard NSScreen.screens.count == 1,
              let currentScreen = NSScreen.screens.first,
              hasActiveVideoWallpaper else {
            return
        }

        let currentScreenID = currentScreen.wallpaperScreenIdentifier
        let currentFingerprint = currentScreen.wallpaperScreenFingerprint
        let matchedCurrentTarget =
        videoTargetScreenIDs.contains(currentScreenID) ||
        videoTargetScreenFingerprints.contains(currentFingerprint)

        guard !matchedCurrentTarget else { return }

        let candidateVideoURLs = ([currentVideoURL] + Array(videoURLByScreen.values) + Array(videoURLByScreenFingerprint.values))
            .compactMap { $0 }
        let uniqueVideoURLKeys = Set(candidateVideoURLs.map { $0.standardizedFileURL.absoluteString })
        guard uniqueVideoURLKeys.count <= 1 else {
            NSLog("[VideoWallpaperManager] Skipped single-display migration because multiple video sources are active")
            return
        }

        let activeVideoURL =
        currentVideoURL ??
        videoURLByScreen.values.first ??
        videoURLByScreenFingerprint.values.first
        guard let activeVideoURL else { return }

        let activePosterURL =
        posterURLByScreen.values.first ??
        posterURLByScreenFingerprint.values.first ??
        currentPosterURL

        videoTargetScreenIDs = [currentScreenID]
        videoTargetScreenFingerprints = [currentFingerprint]
        videoURLByScreen[currentScreenID] = activeVideoURL
        videoURLByScreenFingerprint[currentFingerprint] = activeVideoURL

        if let activePosterURL {
            posterURLByScreen[currentScreenID] = activePosterURL
            posterURLByScreenFingerprint[currentFingerprint] = activePosterURL
        }

        if let currentVolume = volumeByScreen.values.first ?? volumeByScreenFingerprint.values.first {
            volumeByScreen[currentScreenID] = currentVolume
            volumeByScreenFingerprint[currentFingerprint] = currentVolume
        }

        NSLog("[VideoWallpaperManager] Migrated active video wallpaper to current single display after display topology change")
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

    private func repairWindowsForCurrentDisplayConfiguration(reason: String) {
        relinkDisplayStateForCurrentScreens()

        if hasEffectiveTargetDisplayChange() {
            do {
                try rebuildWindows()
            } catch {
                NSLog("[VideoWallpaperManager] Failed to rebuild windows after \(reason): \(error.localizedDescription)")
            }
            return
        }

        if synchronizeExistingWindowFramesToCurrentScreens() {
            NSLog("[VideoWallpaperManager] Synchronized existing window frames after \(reason)")
        }

        let targetScreens = screensForVideoWallpaperTargets()
        for screen in targetScreens {
            let screenID = screen.wallpaperScreenIdentifier
            if windows[screenID] == nil {
                try? rebuildWindows(targetScreen: screen)
            }
        }
    }

    @discardableResult
    private func synchronizeExistingWindowFramesToCurrentScreens() -> Bool {
        let targetScreens = screensForVideoWallpaperTargets()
        var didAdjustAnyWindow = false

        for screen in targetScreens {
            let screenID = screen.wallpaperScreenIdentifier
            guard let window = windows[screenID] else { continue }
            if synchronizeWindow(window, to: screen) {
                didAdjustAnyWindow = true
            }
        }

        let targetScreenIDs = Set(targetScreens.map(\.wallpaperScreenIdentifier))
        if !targetScreenIDs.isEmpty, Set(windows.keys) == targetScreenIDs {
            lastAppliedScreenConfigurations = currentTargetScreenConfigurations()
        }

        return didAdjustAnyWindow
    }

    @discardableResult
    private func synchronizeWindow(_ window: WallpaperVideoWindow, to screen: NSScreen) -> Bool {
        let targetFrame = screen.frame
        var didAdjust = false

        if rectsDiffer(window.frame, targetFrame) {
            window.setFrame(targetFrame, display: true)
            didAdjust = true
        }

        if let containerView = window.contentView as? WallpaperVideoContainerView {
            let targetContentFrame = NSRect(origin: .zero, size: targetFrame.size)
            if rectsDiffer(containerView.frame, targetContentFrame) {
                containerView.frame = targetContentFrame
                containerView.setFrameSize(targetFrame.size)
                didAdjust = true
            }
            containerView.needsLayout = true
            containerView.layoutSubtreeIfNeeded()
        }

        return didAdjust
    }

    private func rectsDiffer(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
        let tolerance: CGFloat = 0.5
        return abs(lhs.origin.x - rhs.origin.x) > tolerance ||
        abs(lhs.origin.y - rhs.origin.y) > tolerance ||
        abs(lhs.size.width - rhs.size.width) > tolerance ||
        abs(lhs.size.height - rhs.size.height) > tolerance
    }

    private func rebuildWindows(targetScreen: NSScreen? = nil, animatedTransition: Bool = false) throws {
        guard hasActiveVideoWallpaper else { return }

        // 屏幕参数变化、裁切刷新等内部调用可能直接请求重建单屏。全局同步下若允许
        // 该路径继续，会为目标屏幕创建第二个 AVPlayerItem，破坏单解码不变量。
        if targetScreen != nil, usesSharedGlobalVideoPlayer {
            try rebuildWindows(targetScreen: nil, animatedTransition: animatedTransition)
            return
        }

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
            let targetScreenID = targetScreen.wallpaperScreenIdentifier
            let targetFingerprint = targetScreen.wallpaperScreenFingerprint
            guard NSScreen.screens.contains(where: { screen in
                screen.wallpaperScreenIdentifier == targetScreenID ||
                screen.wallpaperScreenFingerprint == targetFingerprint
            }) else {
                AppLogger.error(.wallpaper, "Video rebuild skipped because target screen disconnected", metadata: [
                    "targetScreenID": targetScreenID,
                    "targetFingerprint": targetFingerprint,
                    "currentScreens": NSScreen.screens.map(\.wallpaperScreenIdentifier).joined(separator: ",")
                ])
                NSLog("[VideoWallpaperManager] Skipped rebuild because target screen is disconnected: \(targetScreenID)")
                return
            }
            screensToRebuild = [targetScreen]
            // 保留其他屏幕的窗口
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
            if usesSharedGlobalVideoPlayer,
               animatedTransition,
               !windows.isEmpty,
               try scheduleSharedGlobalPlayerReplacement(for: screensToRebuild) {
                lastAppliedScreenConfigurations = currentTargetScreenConfigurations()
                NSLog("[VideoWallpaperManager] Shared player replacement scheduled after preroll")
                return
            }

            teardownAllWindows()
            let sharedComponents: (player: AVQueuePlayer, looper: AVPlayerLooper?, item: AVPlayerItem)?
            let sharedOwnerScreenID: String?
            if usesSharedGlobalVideoPlayer,
               let primaryScreen = screensToRebuild.first,
               let primaryVideoURL = videoURL(for: primaryScreen) {
                let schedulerConfig = WallpaperSchedulerService.shared.config.resolvedDisplayConfig(
                    for: primaryScreen.wallpaperScreenIdentifier
                )
                let hdrMetadataEnabled = UserDefaults.standard.object(forKey: "hdr_enabled") as? Bool ?? true
                sharedComponents = makePlayerComponents(
                    for: primaryScreen,
                    videoURL: primaryVideoURL,
                    muted: isMuted,
                    hdrMetadataEnabled: hdrMetadataEnabled,
                    enableLooping: !(schedulerConfig.isEnabled && schedulerConfig.isOnEndMode)
                )
                sharedOwnerScreenID = primaryScreen.wallpaperScreenIdentifier
                NSLog("[VideoWallpaperManager] Global display sync: one AVPlayer shared by \(screensToRebuild.count) displays")
            } else {
                sharedComponents = nil
                sharedOwnerScreenID = nil
            }

            for screen in screensToRebuild {
                do {
                    guard let videoURL = self.videoURL(for: screen) else { continue }
                    try createWindow(
                        for: screen,
                        videoURL: videoURL,
                        muted: isMuted,
                        sharedComponents: sharedComponents,
                        sharedOwnerScreenID: sharedOwnerScreenID
                    )
                } catch {
                    NSLog("[VideoWallpaperManager] Failed to create window: \(error.localizedDescription)")
                }
            }
            validateSharedPlayerInvariant(reason: "freshGlobalRebuild")
        } else {
            guard let targetScreen = targetScreen else { return }
            let targetScreenID = targetScreen.wallpaperScreenIdentifier
            if let existingWindow = windows[targetScreenID],
               let containerView = existingWindow.contentView as? WallpaperVideoContainerView {
                synchronizeWindow(existingWindow, to: targetScreen)
                // 复用窗口：尽量保留旧层直到新层首帧就绪，避免自动切换时硬闪。
                let oldPlayer = players[targetScreenID]
                let oldLooper = loopers[targetScreenID]

                // 1. 创建新 player
                guard let videoURL = videoURL(for: targetScreen) else {
                    NSLog("[VideoWallpaperManager] Missing video URL for target screen \(targetScreenID)")
                    return
                }

                // 检查该屏幕是否使用"播完即换"模式
                let schedulerConfig = WallpaperSchedulerService.shared.config.resolvedDisplayConfig(for: targetScreenID)
                let isOnEndMode = schedulerConfig.isEnabled && schedulerConfig.isOnEndMode

                let hdrMetadataEnabled = UserDefaults.standard.object(forKey: "hdr_enabled") as? Bool ?? true
                let playbackURL = videoURL
                let components = makePlayerComponents(
                    for: targetScreen,
                    videoURL: playbackURL,
                    muted: isMuted,
                    hdrMetadataEnabled: hdrMetadataEnabled,
                    enableLooping: !isOnEndMode
                )
                if let looper = components.looper {
                    self.loopers[targetScreenID] = looper
                } else {
                    loopers.removeValue(forKey: targetScreenID)
                }

                // 更新噪点纹理叠加（桌面壁纸颗粒蒙层，由 Settings 开关独立控制）
                let grainEnabled = ArcBackgroundSettings.shared.grainTextureEnabled
                if grainEnabled {
                    containerView.showGrainOverlay(intensity: ArcBackgroundSettings.shared.grainIntensity)
                } else {
                    containerView.hideGrainOverlay()
                }

                // 2. 更新字典
                players[targetScreenID] = components.player
                // 播放器替换后，先让已在途的旧 poster 加载失效；现有封面保留到淡入结束再移除。
                invalidatePosterDisplay(for: targetScreenID)

                let finalizeReplacement: @MainActor @Sendable () -> Void = { [weak self, weak containerView] in
                    guard let self, let containerView else { return }
                    containerView.playerLayer.player = components.player
                    containerView.playerLayer.videoGravity = .resizeAspectFill
                    self.hidePosterImage(for: targetScreenID)
                    self.applyCropToScreen(targetScreen)
                    self.scheduleVideoLetterboxAnalysis(screenID: targetScreenID, videoURL: videoURL)
                    self.prepareFrameInterpolation(
                        screenID: targetScreenID,
                        screen: targetScreen,
                        videoURL: videoURL,
                        player: components.player,
                        item: components.item,
                        containerView: containerView,
                        triggeredByWallpaperSetup: true
                    )

                    if let oldLooper {
                        oldLooper.disableLooping()
                    }
                    if let oldPlayer, oldPlayer !== components.player {
                        oldPlayer.pause()
                        oldPlayer.removeAllItems()
                        self.retainPlayersTemporarily([oldPlayer])
                    }

                    if isOnEndMode {
                        self.onEndModeScreens.insert(targetScreenID)
                        self.setupPlaybackEndObserver(for: targetScreenID, player: components.player, item: components.item)
                    } else {
                        self.onEndModeScreens.remove(targetScreenID)
                        if let observer = self.playbackEndObservers[targetScreenID] {
                            NotificationCenter.default.removeObserver(observer)
                            self.playbackEndObservers.removeValue(forKey: targetScreenID)
                        }
                    }
                }

                let shouldAnimateReplacement = animatedTransition && oldPlayer != nil && oldPlayer !== components.player
                if shouldAnimateReplacement {
                    playerItemObservers[targetScreenID]?.invalidate()
                    playerItemObservers.removeValue(forKey: targetScreenID)
                    playerItemObserverTokens.removeValue(forKey: targetScreenID)
                    fadeInTimeouts[targetScreenID]?.cancel()
                    fadeInTimeouts.removeValue(forKey: targetScreenID)

                    let readinessToken = UUID()
                    playerItemObserverTokens[targetScreenID] = readinessToken

                    let observer = components.item.observe(\.status, options: [.initial]) { [weak self, weak containerView] item, _ in
                        guard item.status == .readyToPlay else { return }
                        DispatchQueue.main.async { [weak self, weak containerView] in
                            guard let self, let containerView else { return }
                            guard self.playerItemObserverTokens[targetScreenID] == readinessToken else { return }
                            self.playerItemObservers[targetScreenID]?.invalidate()
                            self.playerItemObservers.removeValue(forKey: targetScreenID)
                            self.playerItemObserverTokens.removeValue(forKey: targetScreenID)
                            self.fadeInTimeouts[targetScreenID]?.cancel()
                            self.fadeInTimeouts.removeValue(forKey: targetScreenID)

                            // AVPlayerLooper 可能在 ready 前后插入新的循环 item，播放前重新应用音频策略。
                            let screenVolume = self.volumeByScreen[targetScreenID] ?? self.volume
                            self.applyPlayerAudioPolicy(components.player, muted: self.isMuted, volume: screenVolume)
                            if !self.isPaused {
                                components.player.play()
                            }
                            containerView.transitionThroughBlack(
                                duration: self.automaticSwitchTransitionDuration
                            ) {
                                finalizeReplacement()
                                self.scheduleDisplaySwitchStableRelease(screenID: targetScreenID, reason: "replacementReady")
                            }
                        }
                    }
                    playerItemObservers[targetScreenID] = observer

                    let timeout = DispatchWorkItem { [weak self, weak containerView] in
                        guard let self, let containerView else { return }
                        guard self.playerItemObserverTokens[targetScreenID] == readinessToken else { return }
                        self.playerItemObservers[targetScreenID]?.invalidate()
                        self.playerItemObservers.removeValue(forKey: targetScreenID)
                        self.playerItemObserverTokens.removeValue(forKey: targetScreenID)
                        self.fadeInTimeouts[targetScreenID]?.cancel()
                        self.fadeInTimeouts.removeValue(forKey: targetScreenID)

                        // 超时兜底路径也要在 play() 前重新禁用静音状态下的音频轨。
                        let screenVolume = self.volumeByScreen[targetScreenID] ?? self.volume
                        self.applyPlayerAudioPolicy(components.player, muted: self.isMuted, volume: screenVolume)
                        if !self.isPaused {
                            components.player.play()
                        }
                        containerView.transitionThroughBlack(
                            duration: self.automaticSwitchTransitionDuration
                        ) {
                            finalizeReplacement()
                            self.scheduleDisplaySwitchStableRelease(screenID: targetScreenID, reason: "replacementTimeout")
                        }
                    }
                    fadeInTimeouts[targetScreenID] = timeout
                    DispatchQueue.main.asyncAfter(deadline: .now() + automaticSwitchReadyTimeout, execute: timeout)
                } else {
                    containerView.cancelPlayerTransitionIfNeeded()
                    containerView.playerLayer.player = components.player
                    containerView.playerLayer.videoGravity = .resizeAspectFill
                    applyCropToScreen(targetScreen)
                    // 非动画替换会立即播放，新播放器绑定到 layer 后先同步静音音频轨状态。
                    let screenVolume = volumeByScreen[targetScreenID] ?? volume
                    applyPlayerAudioPolicy(components.player, muted: isMuted, volume: screenVolume)
                    if !isPaused {
                        components.player.play()
                    }
                    finalizeReplacement()
                    scheduleDisplaySwitchStableRelease(screenID: targetScreenID, reason: "replacementImmediate")
                }

                NSLog("[VideoWallpaperManager] Replaced player for screen \(targetScreenID) with animated=\(shouldAnimateReplacement)")
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

    /// 全局同步切换：先按单屏条件加载原视频；接管后再串行执行循环点分析与补帧。
    @discardableResult
    private func scheduleSharedGlobalPlayerReplacement(for screens: [NSScreen]) throws -> Bool {
        guard let primaryScreen = screens.first,
              let videoURL = videoURL(for: primaryScreen) else { return false }

        let targetContainers: [(NSScreen, WallpaperVideoContainerView)] = screens.compactMap { screen in
            guard let window = windows[screen.wallpaperScreenIdentifier],
                  let container = window.contentView as? WallpaperVideoContainerView else { return nil }
            return (screen, container)
        }
        guard targetContainers.count == screens.count else { return false }

        sharedReplacementObserver?.invalidate()
        sharedReplacementObserver = nil
        sharedReplacementReadyTimeout?.cancel()
        sharedReplacementReadyTimeout = nil

        let primaryID = primaryScreen.wallpaperScreenIdentifier
        let schedulerConfig = WallpaperSchedulerService.shared.config.resolvedDisplayConfig(for: primaryID)
        let isOnEndMode = schedulerConfig.isEnabled && schedulerConfig.isOnEndMode
        let token = UUID()
        sharedReplacementToken = token
        sharedReplacementPreparingVideoURL = videoURL

        startPreparedSharedGlobalPlayerReplacement(
            videoURL: videoURL,
            targets: targetContainers,
            primaryScreen: primaryScreen,
            isOnEndMode: isOnEndMode,
            token: token
        )
        return true
    }

    private func startPreparedSharedGlobalPlayerReplacement(
        videoURL: URL,
        targets: [(NSScreen, WallpaperVideoContainerView)],
        primaryScreen: NSScreen,
        isOnEndMode: Bool,
        token: UUID
    ) {
        guard sharedReplacementToken == token else { return }
        let hdrMetadataEnabled = UserDefaults.standard.object(forKey: "hdr_enabled") as? Bool ?? true
        let components = makePlayerComponents(
            for: primaryScreen,
            videoURL: videoURL,
            muted: isMuted,
            hdrMetadataEnabled: hdrMetadataEnabled,
            enableLooping: !isOnEndMode
        )
        components.player.pause()
        let context = SharedGlobalPlayerReplacementContext(
            components: components,
            videoURL: videoURL,
            targets: targets,
            primaryScreen: primaryScreen,
            isOnEndMode: isOnEndMode
        )

        let commitReplacement: @MainActor () -> Void = { [weak self, context] in
            guard let self, self.sharedReplacementToken == token else { return }
            self.sharedReplacementObserver?.invalidate()
            self.sharedReplacementObserver = nil
            self.sharedReplacementReadyTimeout?.cancel()
            self.sharedReplacementReadyTimeout = nil
            self.sharedReplacementToken = nil
            self.sharedReplacementPreparingVideoURL = nil
            self.performSharedGlobalPlayerReplacement(
                components: context.components,
                videoURL: context.videoURL,
                targets: context.targets,
                primaryScreen: context.primaryScreen,
                isOnEndMode: context.isOnEndMode
            )
        }

        sharedReplacementObserver = components.item.observe(\.status, options: [.initial, .new]) { [weak self, context] item, _ in
            guard item.status == .readyToPlay else {
                if item.status == .failed {
                    let errorMessage = item.error?.localizedDescription ?? "unknown"
                    Task { @MainActor [weak self, context] in
                        guard let self, self.sharedReplacementToken == token else { return }
                        self.sharedReplacementObserver?.invalidate()
                        self.sharedReplacementObserver = nil
                        self.sharedReplacementReadyTimeout?.cancel()
                        self.sharedReplacementReadyTimeout = nil
                        self.sharedReplacementToken = nil
                        self.sharedReplacementPreparingVideoURL = nil
                        AppLogger.error(.wallpaper, "Prepared global replacement failed", metadata: [
                            "video": context.videoURL.lastPathComponent,
                            "error": errorMessage
                        ])
                    }
                }
                return
            }
            Task { @MainActor [weak self] in
                guard let self, self.sharedReplacementToken == token else { return }
                commitReplacement()
            }
        }

        // 与单屏切换一致：正常等待 readyToPlay，同时保留同样的就绪超时兜底，
        // 防止异常媒体永远停在 unknown 状态并锁死后续自动/手动切换。
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.sharedReplacementToken == token else { return }
            commitReplacement()
        }
        sharedReplacementReadyTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + automaticSwitchReadyTimeout, execute: timeout)
    }

    private func performSharedGlobalPlayerReplacement(
        components: (player: AVQueuePlayer, looper: AVPlayerLooper?, item: AVPlayerItem),
        videoURL: URL,
        targets: [(NSScreen, WallpaperVideoContainerView)],
        primaryScreen: NSScreen,
        isOnEndMode: Bool
    ) {
        let oldPlayers = uniquePlayers(from: players.values)
        let oldLoopers = Array(loopers.values)
        let primaryID = primaryScreen.wallpaperScreenIdentifier
        var coveredCount = 0

        for (_, container) in targets {
            container.fadeToBlack(duration: automaticSwitchTransitionDuration) { [weak self] in
                guard let self else { return }
                coveredCount += 1
                guard coveredCount == targets.count else { return }

                for (screen, targetContainer) in targets {
                    let screenID = screen.wallpaperScreenIdentifier
                    targetContainer.playerLayer.player = components.player
                    targetContainer.playerLayer.videoGravity = .resizeAspectFill
                    self.players[screenID] = components.player
                    self.applyCropToScreen(screen)
                }

                self.loopers.removeAll()
                if let looper = components.looper {
                    self.loopers[primaryID] = looper
                }
                self.applyPlayerAudioPolicy(
                    components.player,
                    muted: self.isMuted,
                    volume: self.volumeByScreen[primaryID] ?? self.volume
                )
                if !self.isPaused {
                    components.player.play()
                }

                if isOnEndMode {
                    self.onEndModeScreens = [primaryID]
                    self.setupPlaybackEndObserver(for: primaryID, player: components.player, item: components.item)
                } else {
                    self.onEndModeScreens.removeAll()
                    for observer in self.playbackEndObservers.values {
                        NotificationCenter.default.removeObserver(observer)
                    }
                    self.playbackEndObservers.removeAll()
                }

                self.scheduleVideoLetterboxAnalysis(screenID: primaryID, videoURL: videoURL)
                if let primaryContainer = targets.first(where: {
                    $0.0.wallpaperScreenIdentifier == primaryID
                })?.1 {
                    self.prepareFrameInterpolation(
                        screenID: primaryID,
                        screen: primaryScreen,
                        videoURL: videoURL,
                        player: components.player,
                        item: components.item,
                        containerView: primaryContainer,
                        triggeredByWallpaperSetup: true
                    )
                }
                targets.forEach { $0.1.revealFromBlack(duration: self.automaticSwitchTransitionDuration) }

                for looper in oldLoopers where looper !== components.looper {
                    looper.disableLooping()
                }
                let obsoletePlayers = oldPlayers.filter { $0 !== components.player }
                for player in obsoletePlayers {
                    player.pause()
                    player.removeAllItems()
                }
                self.retainPlayersTemporarily(obsoletePlayers)
                self.validateSharedPlayerInvariant(reason: "preparedGlobalReplacement")
            }
        }
    }

    private func uniquePlayers<S: Sequence>(from sequence: S) -> [AVQueuePlayer] where S.Element == AVQueuePlayer {
        var identifiers = Set<ObjectIdentifier>()
        return sequence.filter { identifiers.insert(ObjectIdentifier($0)).inserted }
    }

    private func validateSharedPlayerInvariant(reason: String) {
        guard usesSharedGlobalVideoPlayer else { return }
        let playerCount = uniquePlayers(from: players.values).count
        if playerCount != 1 {
            AppLogger.error(.wallpaper, "Global display sync player invariant violated", metadata: [
                "reason": reason,
                "distinctPlayers": String(playerCount),
                "displayWindows": String(windows.count)
            ])
        }
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

    /// 创建并配置 AVPlayer + AVPlayerLooper，供 `createWindow` 与窗口复用路径共享。
    /// - Parameters:
    ///   - screen: 目标屏幕
    ///   - videoURL: 视频文件 URL
    ///   - muted: 是否静音
    ///   - hdrMetadataEnabled: 是否应用源视频逐帧 HDR 显示元数据；这是 AVPlayerItem 原生属性，不引入 videoComposition。
    ///   - enableLooping: 是否启用循环播放（"播完即换"模式下为 false）
    private func makePlayerComponents(
        for screen: NSScreen,
        videoURL: URL,
        muted: Bool,
        hdrMetadataEnabled: Bool = true,
        enableLooping: Bool = true
    ) -> (player: AVQueuePlayer, looper: AVPlayerLooper?, item: AVPlayerItem) {
        let playerItem = AVPlayerItem(url: videoURL)
        if #available(macOS 11.0, *) {
            playerItem.appliesPerFrameHDRDisplayMetadata = hdrMetadataEnabled
        }

        // 计算屏幕物理像素分辨率，用于后续所有与分辨率/码率相关的限制
        let scaleFactor = screen.backingScaleFactor
        let screenPixelWidth = screen.frame.width * scaleFactor
        let screenPixelHeight = screen.frame.height * scaleFactor

        // 1) 动态峰值码率限制
        // 根据屏幕分辨率计算合理的峰值码率上限，避免超大码率视频导致持续性磁盘 I/O 和内存带宽压力。
        // 桌面壁纸通常远距离观看，可容忍较低码率。
        let totalPixels = screenPixelWidth * screenPixelHeight
        // 估算：~0.05 bits/pixel/s（H.265 良好质量），
        // 4K@30fps → ~20 Mbps, 5K → ~37 Mbps, 6K → ~51 Mbps
        let estimatedBitrate = Double(totalPixels) * 0.05
        let maxBitrate: Double = 50_000_000 // 50 Mbps 硬上限
        playerItem.preferredPeakBitRate = min(estimatedBitrate, maxBitrate)

        // 2) 解码分辨率上限
        playerItem.preferredMaximumResolution = CGSize(width: screenPixelWidth, height: screenPixelHeight)

        if #available(macOS 10.15, *) {
            playerItem.seekingWaitsForVideoCompositionRendering = false
        }
        playerItem.audioTimePitchAlgorithm = .timeDomain
        if videoURL.isFileURL {
            // 三屏同时切换时，如果本地文件一 ready 就立即播放，外屏更容易在前几秒边读边解码而卡顿。
            // 这里给普通文件稍多缓冲；超大文件仍收紧，避免 page cache 压力过高。
            let effectiveBufferDuration: TimeInterval = {
                // 对于超大文件（>1GB），进一步缩减缓冲以降低持续性磁盘 I/O 和 page cache 压力
                if let attrs = try? FileManager.default.attributesOfItem(atPath: videoURL.path),
                   let fileSize = attrs[.size] as? UInt64,
                   fileSize > 1_000_000_000 {
                    return largeLocalVideoForwardBufferDuration
                }
                return localVideoForwardBufferDuration
            }()
            playerItem.preferredForwardBufferDuration = effectiveBufferDuration
        }

        let queuePlayer = AVQueuePlayer()
        queuePlayer.actionAtItemEnd = .none
        let screenVolume = volume(for: screen)
        // 先设置播放器级音量；此时队列通常为空，所以还需要单独处理模板 item。
        applyPlayerAudioPolicy(queuePlayer, muted: muted, volume: screenVolume)
        // AVPlayerLooper 会基于 templateItem 复制循环 item，模板本身必须先禁用音频轨。
        applyPlayerItemAudioPolicy(playerItem, muted: muted)
        // 本地文件也等待最小缓冲，避免外接屏在切换后的 5-10 秒内反复等待磁盘/解码。
        queuePlayer.automaticallyWaitsToMinimizeStalling = true
        queuePlayer.preventsDisplaySleepDuringVideoPlayback = false

        var looper: AVPlayerLooper? = nil
        if enableLooping {
            looper = AVPlayerLooper(player: queuePlayer, templateItem: playerItem)
        } else {
            queuePlayer.insert(playerItem, after: nil)
        }

        return (queuePlayer, looper, playerItem)
    }

    private func applyPlayerAudioPolicy(_ player: AVQueuePlayer, muted: Bool, volume: Double) {
        // 播放器级策略负责系统可见的静音/音量，以及当前已进入队列的 item。
        player.isMuted = muted
        player.volume = muted ? 0 : Float(volume)
        for item in player.items() {
            applyPlayerItemAudioPolicy(item, muted: muted)
        }
    }

    private func applyPlayerItemAudioPolicy(_ item: AVPlayerItem, muted: Bool) {
        // item 级策略负责直接禁用音频轨，避免静音壁纸仍建立音频输出链路。
        setLoadedAudioTracksEnabled(!muted, for: item)

        if muted {
            Task { @MainActor [weak self, weak item] in
                guard let self, let item else { return }
                _ = try? await item.asset.loadTracks(withMediaType: .audio)
                guard self.isMuted else { return }
                // asset 音频轨可能稍后才加载完成，异步返回后再禁用一次 item tracks。
                setLoadedAudioTracksEnabled(false, for: item)
            }
        }
    }

    private func setLoadedAudioTracksEnabled(_ enabled: Bool, for item: AVPlayerItem) {
        // 只切换音频轨，不影响视频轨播放，确保静音壁纸仍能正常渲染画面。
        for track in item.tracks where track.assetTrack?.mediaType == .audio {
            track.isEnabled = enabled
        }
    }

    private func createWindow(
        for screen: NSScreen,
        videoURL: URL,
        muted: Bool,
        sharedComponents: (player: AVQueuePlayer, looper: AVPlayerLooper?, item: AVPlayerItem)? = nil,
        sharedOwnerScreenID: String? = nil
    ) throws {
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

        // 检查该屏幕是否使用"播完即换"模式
        let schedulerConfigID = sharedOwnerScreenID ?? screenID
        let schedulerConfig = WallpaperSchedulerService.shared.config.resolvedDisplayConfig(for: schedulerConfigID)
        let isOnEndMode = schedulerConfig.isEnabled && schedulerConfig.isOnEndMode

        // 统一使用 AVPlayerLooper 简单循环播放原视频。
        let hdrMetadataEnabled = UserDefaults.standard.object(forKey: "hdr_enabled") as? Bool ?? true
        let playbackURL = videoURL
        let components = sharedComponents ?? makePlayerComponents(
            for: screen,
            videoURL: playbackURL,
            muted: muted,
            hdrMetadataEnabled: hdrMetadataEnabled,
            enableLooping: !isOnEndMode
        )
        let ownsSharedPlayer = sharedOwnerScreenID == nil || sharedOwnerScreenID == screenID
        if let looper = components.looper {
            if ownsSharedPlayer {
                self.loopers[screenID] = looper
            }
        } else {
            loopers.removeValue(forKey: screenID)
        }

        containerView.playerLayer.player = components.player
        containerView.playerLayer.videoGravity = .resizeAspectFill

        // 异步加载视频真实尺寸并缓存，加载完后重算 crop（首次用 fallback 屏尺寸）。
        Task { [weak self, videoURL] in
            let asset = AVURLAsset(url: videoURL)
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let size = try? await track.load(.naturalSize),
                  size.width > 0, size.height > 0 else { return }
            await MainActor.run {
                guard let self = self, self.players[screenID] != nil else { return }
                self.videoSizes[screenID] = size
                self.applyCropToScreen(screen)
            }
        }

        // 应用噪点纹理叠加（桌面壁纸颗粒蒙层，由 Settings 开关独立控制）
        let grainEnabled = ArcBackgroundSettings.shared.grainTextureEnabled
        if grainEnabled {
            containerView.showGrainOverlay(intensity: ArcBackgroundSettings.shared.grainIntensity)
        }

        windows[screenID] = window
        players[screenID] = components.player
        applyCropToScreen(screen)
        scheduleVideoLetterboxAnalysis(screenID: screenID, videoURL: videoURL)
        if ownsSharedPlayer {
            prepareFrameInterpolation(
                screenID: screenID,
                screen: screen,
                videoURL: videoURL,
                player: components.player,
                item: components.item,
                containerView: containerView,
                triggeredByWallpaperSetup: true
            )
        }

        // 先隐藏窗口，等视频首帧就绪后再淡入，避免启动时闪黑
        window.alphaValue = 0
        window.orderBack(nil)

        // 视频加载期间先显示封面图，避免黑屏（同步关闭时尤为关键）
        showPosterImage(for: screenID)

        // 观察 playerItem 状态，就绪后播放并淡入
        let player = components.player
        let observer = components.item.observe(\.status, options: [.initial]) { [weak self] item, _ in
            guard let self, item.status == .readyToPlay else { return }
            Task { @MainActor in
                // 清理 observer 和超时
                self.playerItemObservers[screenID]?.invalidate()
                self.playerItemObservers.removeValue(forKey: screenID)
                self.playerItemObserverTokens.removeValue(forKey: screenID)
                self.fadeInTimeouts[screenID]?.cancel()
                self.fadeInTimeouts.removeValue(forKey: screenID)
                // 视频就绪，隐藏封面图
                self.hidePosterImage(for: screenID)
                // 首帧 ready 后、真正播放前再次同步音频策略，覆盖 looper 后续插入的 item。
                let screenVolume = self.volumeByScreen[screenID] ?? self.volume
                self.applyPlayerAudioPolicy(player, muted: self.isMuted, volume: screenVolume)
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
                self.scheduleDisplaySwitchStableRelease(screenID: screenID, reason: "windowReady")
            }
        }
        playerItemObservers[screenID] = observer

        // 超时保护：3 秒后如果视频仍未就绪，强制淡入
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.playerItemObservers[screenID] != nil else { return }
            self.playerItemObservers[screenID]?.invalidate()
            self.playerItemObservers.removeValue(forKey: screenID)
            self.playerItemObserverTokens.removeValue(forKey: screenID)
            self.fadeInTimeouts.removeValue(forKey: screenID)
            // 超时兜底，隐藏封面图
            self.hidePosterImage(for: screenID)
            // ready 超时时也会直接播放，所以这里同样要先禁用静音状态下的音频轨。
            let screenVolume = self.volumeByScreen[screenID] ?? self.volume
            self.applyPlayerAudioPolicy(player, muted: self.isMuted, volume: screenVolume)
            if !self.isPaused {
                player.play()
            }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                window.animator().alphaValue = 1
            }
            self.scheduleDisplaySwitchStableRelease(screenID: screenID, reason: "windowReadyTimeout")
        }
        fadeInTimeouts[screenID] = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: timeout)

        // 如果是"播完即换"模式，添加视频播放完成的观察者
        if isOnEndMode && ownsSharedPlayer {
            onEndModeScreens.insert(screenID)
            setupPlaybackEndObserver(for: screenID, player: components.player, item: components.item)
        } else {
            onEndModeScreens.remove(screenID)
            // 清理旧的播放结束观察者
            if let observer = playbackEndObservers[screenID] {
                NotificationCenter.default.removeObserver(observer)
                playbackEndObservers.removeValue(forKey: screenID)
            }
        }
    }

    /// 为"播完即换"模式设置视频播放完成观察者
    private func setupPlaybackEndObserver(for screenID: String, player: AVQueuePlayer, item: AVPlayerItem) {
        // 移除旧的观察者
        if let oldObserver = playbackEndObservers[screenID] {
            NotificationCenter.default.removeObserver(oldObserver)
            playbackEndObservers.removeValue(forKey: screenID)
        }

        let notificationName = WallpaperSchedulerService.videoPlaybackEndedNotification
        let observer = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self, weak player] _ in
            Task { @MainActor [weak self, weak player] in
                guard let self, let player, self.players[screenID] === player else { return }

                // 结束帧的 AVPlayerLayer 可能清空为黑色。先盖上 poster，再等待 seek
                // 真正完成后派发切换事件；不能在异步 seek 发起后立即暂停。
                self.showPosterImage(for: screenID)
                player.pause()
                player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak player] _ in
                    guard let player else { return }
                    DispatchQueue.main.async {
                        guard let self, self.players[screenID] === player else { return }
                        player.pause()
                        // 发送视频播放完成通知
                        DistributedNotificationCenter.default().postNotificationName(
                            notificationName,
                            object: nil,
                            userInfo: ["screenID": screenID],
                            deliverImmediately: true
                        )
                    }
                }
            }
        }
        playbackEndObservers[screenID] = observer
    }

    private func teardownAllWindows() {
        // 0. 取消上一次未执行的延迟释放，避免快速切换时多组 AVPlayer 并发驻留
        pendingPlayerCleanups.forEach { $0.cancel() }
        pendingPlayerCleanups.removeAll()
        pendingWindowCleanups.forEach { $0.cancel() }
        pendingWindowCleanups.removeAll()
        displaySwitchReleaseWorkItem?.cancel()
        displaySwitchReleaseWorkItem = nil
        activeDisplaySwitchScreenID = nil
        pendingDisplaySwitches.removeAll()
        sharedReplacementToken = nil
        sharedReplacementPreparingVideoURL = nil
        sharedReplacementObserver?.invalidate()
        sharedReplacementObserver = nil
        sharedReplacementReadyTimeout?.cancel()
        sharedReplacementReadyTimeout = nil
        // 清理启动淡入相关的 observer 和超时
        playerItemObservers.values.forEach { $0.invalidate() }
        playerItemObservers.removeAll()
        playerItemObserverTokens.removeAll()
        fadeInTimeouts.values.forEach { $0.cancel() }
        fadeInTimeouts.removeAll()
        // 清理播放结束观察者
        for observer in playbackEndObservers.values {
            NotificationCenter.default.removeObserver(observer)
        }
        playbackEndObservers.removeAll()
        onEndModeScreens.removeAll()

        // 1. 先断开所有 playerLayer 与 player 的关联，避免渲染层持有已释放的 player
        for window in windows.values {
            if let contentView = window.contentView as? WallpaperVideoContainerView {
                contentView.cancelPlayerTransitionIfNeeded()
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
        let playersToDelay = uniquePlayers(from: players.values)
        for player in playersToDelay {
            player.pause()
            player.removeAllItems()
        }
        players.removeAll()
        videoSizes.removeAll()
        clearVideoLetterboxState()
        clearFrameInterpolationState()

        // 延迟释放 player，让 MediaToolbox 后台线程完成 FigNotificationCenter 清理。
        // 延迟完成后必须移除 work item，否则闭包会继续持有旧 player。
        retainPlayersTemporarily(playersToDelay)

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

        // 延迟释放窗口，让 AppKit 的 _NSWindowTransformAnimation 退出动画完成。
        // 延迟完成后必须移除 work item，否则闭包会继续持有旧 window。
        retainWindowsTemporarily(windowsToDelay)

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

        let token = UUID()
        posterDisplayTokens[screenID] = token

        // 异步加载预览图
        Task { [weak self, weak containerView] in
            guard let self,
                  let image = await self.loadPosterImage(from: posterURL),
                  self.posterDisplayTokens[screenID] == token,
                  let containerView,
                  self.windows[screenID]?.contentView === containerView else {
                return
            }
            containerView.showPoster(image)
        }
    }

    /// 隐藏预览图
    private func hidePosterImage(for screenID: String) {
        invalidatePosterDisplay(for: screenID)
        guard let window = windows[screenID],
              let containerView = window.contentView as? WallpaperVideoContainerView else { return }

        containerView.hidePoster()
    }

    private func invalidatePosterDisplay(for screenID: String) {
        posterDisplayTokens[screenID] = UUID()
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

private struct VideoLetterboxCrop {
    let cropRect: UnitRect
    let horizontalBlackRatio: Double
    let verticalBlackRatio: Double

    /// 去黑边的额外放大倍率。上下黑边按行数占比算，左右黑边按列数占比算。
    var zoomMultiplier: Double {
        let dominantRatio = max(horizontalBlackRatio, verticalBlackRatio)
        guard dominantRatio > 0, dominantRatio < 1 else { return 1 }
        return 1.0 / (1.0 - dominantRatio)
    }
}

private enum VideoLetterboxAnalyzer {
    private static let blackLumaThreshold: UInt8 = 28
    private static let edgeBlackRatioThreshold = 0.94
    private static let maxRemovedArea = 0.20
    private static let minRemovedArea = 0.01
    private static let minPairInsetRatio = 0.012
    private static let overscanPixels = 2

    static func analyze(url: URL) async -> VideoLetterboxCrop? {
        await Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 640, height: 640)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero

            let duration = (try? await asset.load(.duration)) ?? .zero
            let seconds = duration.seconds.isFinite && duration.seconds > 1 ? duration.seconds : 1
            let times = [0.25, 0.5, 0.75].map {
                CMTime(seconds: max(0.1, seconds * $0), preferredTimescale: 600)
            }

            var candidates: [VideoLetterboxCrop] = []
            for time in times {
                guard !Task.isCancelled,
                      let image = try? generator.copyCGImage(at: time, actualTime: nil),
                      let rect = detectCropRect(in: image) else {
                    continue
                }
                candidates.append(rect)
            }

            guard !candidates.isEmpty else { return nil }
            if candidates.count == 1 { return candidates[0] }
            return medianRect(candidates)
        }.value
    }

    private static func detectCropRect(in image: CGImage) -> VideoLetterboxCrop? {
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

        let top = edgeInset(limit: height / 2) { y in
            blackRatioInRow(y, width: width, bytesPerRow: bytesPerRow, pixels: pixels)
        }
        let bottom = edgeInset(limit: height / 2) { offset in
            blackRatioInRow(height - 1 - offset, width: width, bytesPerRow: bytesPerRow, pixels: pixels)
        }
        let left = edgeInset(limit: width / 2) { x in
            blackRatioInColumn(x, height: height, bytesPerRow: bytesPerRow, pixels: pixels)
        }
        let right = edgeInset(limit: width / 2) { offset in
            blackRatioInColumn(width - 1 - offset, height: height, bytesPerRow: bytesPerRow, pixels: pixels)
        }

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
        let horizontalBlackRatio = horizontalPair ? Double(rawCropTop + rawCropBottom) / Double(height) : 0
        let verticalBlackRatio = verticalPair ? Double(rawCropLeft + rawCropRight) / Double(width) : 0

        // 按黑边像素占比反推倍率：zoom = 1 / (1 - 黑边占比)。
        // cropRect 的宽/高就是该倍率的倒数；overscan 只用于多吃掉边缘 1-2 行残留黑线。
        let cropRect = UnitRect(
            x: Double(cropLeft) / Double(width),
            y: Double(cropTop) / Double(height),
            w: Double(cropW) / Double(width),
            h: Double(cropH) / Double(height)
        )

        return VideoLetterboxCrop(
            cropRect: cropRect,
            horizontalBlackRatio: horizontalBlackRatio,
            verticalBlackRatio: verticalBlackRatio
        )
    }

    private static func edgeInset(limit: Int, ratioAt: (Int) -> Double) -> Int {
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

    private static func blackRatioInRow(_ y: Int, width: Int, bytesPerRow: Int, pixels: [UInt8]) -> Double {
        let step = max(1, width / 360)
        var black = 0
        var total = 0
        let row = y * bytesPerRow
        var x = 0
        while x < width {
            let offset = row + x * 4
            if isBlack(r: pixels[offset], g: pixels[offset + 1], b: pixels[offset + 2]) {
                black += 1
            }
            total += 1
            x += step
        }
        return total > 0 ? Double(black) / Double(total) : 0
    }

    private static func blackRatioInColumn(_ x: Int, height: Int, bytesPerRow: Int, pixels: [UInt8]) -> Double {
        let step = max(1, height / 360)
        var black = 0
        var total = 0
        var y = 0
        while y < height {
            let offset = y * bytesPerRow + x * 4
            if isBlack(r: pixels[offset], g: pixels[offset + 1], b: pixels[offset + 2]) {
                black += 1
            }
            total += 1
            y += step
        }
        return total > 0 ? Double(black) / Double(total) : 0
    }

    private static func isBlack(r: UInt8, g: UInt8, b: UInt8) -> Bool {
        let luma = (UInt16(r) * 77 + UInt16(g) * 150 + UInt16(b) * 29) >> 8
        return luma <= blackLumaThreshold
    }

    private static func medianRect(_ crops: [VideoLetterboxCrop]) -> VideoLetterboxCrop? {
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }
        let x = median(crops.map(\.cropRect.x))
        let y = median(crops.map(\.cropRect.y))
        let w = median(crops.map(\.cropRect.w))
        let h = median(crops.map(\.cropRect.h))
        let horizontalBlackRatio = median(crops.map(\.horizontalBlackRatio))
        let verticalBlackRatio = median(crops.map(\.verticalBlackRatio))
        let removedArea = 1.0 - max(0, min(1, (1.0 - horizontalBlackRatio) * (1.0 - verticalBlackRatio)))
        guard removedArea >= minRemovedArea, removedArea <= maxRemovedArea else { return nil }
        return VideoLetterboxCrop(
            cropRect: UnitRect(x: x, y: y, w: w, h: h),
            horizontalBlackRatio: horizontalBlackRatio,
            verticalBlackRatio: verticalBlackRatio
        )
    }
}

private struct VideoFrameInterpolationDecision: Sendable {
    let sourceFPS: Double?
    let targetFPS: Int
    let shouldInterpolate: Bool
    let reason: String
}

private enum VideoFrameInterpolationAnalyzer {
    static func decision(for url: URL, targetFPS: Int) async -> VideoFrameInterpolationDecision {
        guard targetFPS > 0 else {
            return VideoFrameInterpolationDecision(sourceFPS: nil, targetFPS: targetFPS, shouldInterpolate: false, reason: "目标 FPS 无效")
        }

        guard let sourceFPS = await sourceFrameRate(for: url), sourceFPS > 0 else {
            return VideoFrameInterpolationDecision(sourceFPS: nil, targetFPS: targetFPS, shouldInterpolate: false, reason: "无法读取原始 FPS")
        }

        let shouldInterpolate = sourceFPS < Double(targetFPS)
        return VideoFrameInterpolationDecision(
            sourceFPS: sourceFPS,
            targetFPS: targetFPS,
            shouldInterpolate: shouldInterpolate,
            reason: shouldInterpolate ? "原始 FPS 低于目标 FPS" : "原始 FPS 已达到或高于目标 FPS"
        )
    }

    static func sourceFrameRate(for url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
            return nil
        }

        if let nominalFrameRate = try? await track.load(.nominalFrameRate),
           nominalFrameRate > 0 {
            return Double(nominalFrameRate)
        }

        if let minFrameDuration = try? await track.load(.minFrameDuration),
           minFrameDuration.isValid,
           minFrameDuration.seconds.isFinite,
           minFrameDuration.seconds > 0 {
            return 1.0 / minFrameDuration.seconds
        }

        return nil
    }
}

struct FrameInterpolationQueueItem: Identifiable, Equatable {
    enum Status: Equatable {
        case waiting
        case analyzing
        case running
        case completed
        case failed(String)

        var label: String {
            switch self {
            case .waiting: return t("frameInterpolationStatusWaiting")
            case .analyzing: return t("frameInterpolationStatusAnalyzing")
            case .running: return t("frameInterpolationStatusRunning")
            case .completed: return t("frameInterpolationStatusCompleted")
            case .failed: return t("frameInterpolationStatusFailed")
            }
        }
    }

    enum Source: String {
        case automatic = "自动"
        case manual = "手动"
    }

    let id: UUID
    let videoURL: URL
    let title: String
    let targetFPS: Int
    let source: Source
    var sourceFPS: Double?
    var status: Status
    var progress: Double
    var writtenFrames: Int64
    var totalFrames: Int64?
    var opticalFlowFrames: Int64
    var elapsedSeconds: TimeInterval
    var remainingSeconds: TimeInterval?
    var currentStage: String
    var outputURL: URL?
    var addedAt: Date

    var statusText: String {
        if case let .failed(message) = status {
            return message.isEmpty ? status.label : "\(status.label)：\(message)"
        }
        return status.label
    }

    var isTerminalForCleanup: Bool {
        switch status {
        case .completed, .failed:
            return true
        case .waiting, .analyzing, .running:
            return false
        }
    }
}

struct FrameInterpolationExportProgress: Sendable {
    let progress: Double
    let writtenFrames: Int64
    let totalFrames: Int64?
    let opticalFlowFrames: Int64
    let elapsedSeconds: TimeInterval
    let remainingSeconds: TimeInterval?
    let currentStage: String
}

struct FrameInterpolationRecordItem: Identifiable, Equatable, Codable {
    let id: String
    let videoPath: String
    let title: String
    let targetFPS: Int
    let recordedAt: Date

    var videoURL: URL {
        URL(fileURLWithPath: videoPath)
    }
}

@MainActor
final class FrameInterpolationQueueService: ObservableObject {
    static let shared = FrameInterpolationQueueService()

    @Published private(set) var items: [FrameInterpolationQueueItem] = []
    @Published var autoEnqueueEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoEnqueueEnabled, forKey: "frame_interpolation_auto_enqueue")
        }
    }

    private var runningTasks: [UUID: Task<Void, Never>] = [:]
    private var heartbeatTasks: [UUID: Task<Void, Never>] = [:]
    private var taskStartDates: [UUID: Date] = [:]
    private var completionHandlers: [UUID: [(URL, URL) -> Void]] = [:]
    private var terminalHandlers: [UUID: [(Bool) -> Void]] = [:]
    private var legacyInterpolationRecordsMigrated = false
    private var legacyCompletedInterpolationItems: [FrameInterpolationRecordItem] = []
    private var legacyBlacklistedInterpolationItems: [FrameInterpolationRecordItem] = []

    private static let completedInterpolationRecordsKey = "frame_interpolation_completed_records_v1"
    private static let blacklistedInterpolationRecordsKey = "frame_interpolation_blacklist_records_v1"

    private init() {
        // 不在单例初始化阶段读取 UserDefaults。macOS 26+ 上启动早期读偏好设置
        // 可能触发 _CFXPreferences 递归；真实设置由 SettingsViewModel 延迟恢复后同步过来。
        self.autoEnqueueEnabled = false
    }

    func hasPendingInterpolation(videoURL: URL, targetFPS: Int) -> Bool {
        items.contains { item in
            item.videoURL.standardizedFileURL == videoURL.standardizedFileURL
                && item.targetFPS == targetFPS
                && !item.isTerminalForCleanup
        }
    }

    func hasActiveInterpolation(videoURL: URL) -> Bool {
        items.contains { item in
            item.videoURL.standardizedFileURL == videoURL.standardizedFileURL
                && !item.isTerminalForCleanup
        }
    }

    func activeInterpolationTargetFPS(videoURL: URL) -> Int? {
        items
            .filter { item in
                item.videoURL.standardizedFileURL == videoURL.standardizedFileURL
                    && !item.isTerminalForCleanup
            }
            .map(\.targetFPS)
            .max()
    }

    func hasActiveInterpolation(videoURL: URL, satisfying targetFPS: Int) -> Bool {
        guard let activeTargetFPS = activeInterpolationTargetFPS(videoURL: videoURL) else {
            return false
        }
        return activeTargetFPS >= targetFPS
    }

    func needsInterpolation(videoURL: URL, targetFPS: Int) async -> Bool {
        await VideoFrameInterpolationAnalyzer.decision(for: videoURL, targetFPS: targetFPS).shouldInterpolate
    }

    func isCompleted(videoURL: URL) -> Bool {
        completedRecord(videoURL: videoURL) != nil
    }

    func completedRecord(videoURL: URL) -> FrameInterpolationRecordItem? {
        ensureInterpolationRecordsLoaded()
        return completedSidecarRecord(for: videoURL)
    }

    func completedRecord(videoURL: URL, satisfying targetFPS: Int) -> FrameInterpolationRecordItem? {
        guard let record = completedRecord(videoURL: videoURL),
              record.targetFPS >= targetFPS else {
            return nil
        }
        return record
    }

    func isBlacklisted(videoURL: URL) -> Bool {
        ensureInterpolationRecordsLoaded()
        if let event = VideoOptimizationRecordService.shared.latestFrameLifecycleEvent(for: videoURL) {
            switch event.kind {
            case .frameBlacklisted:
                return true
            case .optimizationReset, .frameReset, .frameQueued, .frameAnalysisStarted,
                    .frameInterpolationStarted, .frameApplied, .frameNotNeeded,
                    .frameFailed, .frameCancelled:
                return false
            default:
                break
            }
        }
        return false
    }

    /// Terminal export failures are persisted beside the video. The detail menu
    /// needs this after the queue item has been removed and after an app relaunch.
    func failureMessage(videoURL: URL) -> String? {
        guard let event = VideoOptimizationRecordService.shared.latestFrameLifecycleEvent(for: videoURL),
              event.kind == .frameFailed else {
            return nil
        }
        return event.detail
    }

    func markCompleted(videoURL: URL, title: String, targetFPS: Int) {
        ensureInterpolationRecordsLoaded()
        let existingRecord = completedRecord(videoURL: videoURL)
        let effectiveTargetFPS = max(targetFPS, existingRecord?.targetFPS ?? targetFPS)
        VideoOptimizationRecordService.shared.append(.frameApplied, for: videoURL, metadata: [
            "targetFPS": String(effectiveTargetFPS),
            "title": title.isEmpty ? (existingRecord?.title ?? videoURL.deletingPathExtension().lastPathComponent) : title
        ])
    }

    func removeCompleted(videoURL: URL) {
        ensureInterpolationRecordsLoaded()
        VideoOptimizationRecordService.shared.append(.frameReset, for: videoURL)
    }

    func markBlacklisted(videoURL: URL, title: String, targetFPS: Int) {
        ensureInterpolationRecordsLoaded()
        VideoOptimizationRecordService.shared.append(.frameBlacklisted, for: videoURL, metadata: [
            "targetFPS": String(targetFPS),
            "title": title
        ])
    }

    func removeBlacklisted(videoURL: URL) {
        ensureInterpolationRecordsLoaded()
        VideoOptimizationRecordService.shared.append(.frameReset, for: videoURL)
    }

    func reset(videoURL: URL) {
        ensureInterpolationRecordsLoaded()
        let standardizedURL = videoURL.standardizedFileURL
        let matchingIDs = items
            .filter { $0.videoURL.standardizedFileURL == standardizedURL }
            .map(\.id)
        for id in matchingIDs {
            let isRunning = runningTasks[id] != nil
            runningTasks[id]?.cancel()
            stopHeartbeat(id: id)
            // Keep a cancelled exporter in the running map until its worker
            // exits. Releasing the sole lane here allowed a second exporter to
            // start while the first one was still unwinding.
            if !isRunning {
                runningTasks[id] = nil
            }
            completionHandlers[id] = nil
            // A reset starts a replacement pipeline (redownload/rebake), so its
            // prior completion must not report an interpolation failure to the
            // replacement detail state while the old exporter is unwinding.
            terminalHandlers[id] = nil
        }
        items.removeAll { $0.videoURL.standardizedFileURL == standardizedURL }
        VideoOptimizationRecordService.shared.append(.frameReset, for: videoURL)
        scheduleNext()
    }

    @discardableResult
    func enqueue(
        videoURL: URL,
        title: String? = nil,
        targetFPS: Int,
        source: FrameInterpolationQueueItem.Source,
        onFinished: ((Bool) -> Void)? = nil,
        onCompleted: ((URL, URL) -> Void)? = nil
    ) -> UUID? {
        guard targetFPS > 0 else {
            onFinished?(false)
            return nil
        }
        guard !isBlacklisted(videoURL: videoURL) else {
            frameInterpolationDebugPrint("补帧队列：视频在黑名单中，跳过添加。视频=\(videoURL.lastPathComponent)")
            onFinished?(false)
            return nil
        }

        if let record = completedRecord(videoURL: videoURL, satisfying: targetFPS) {
            frameInterpolationDebugPrint("补帧队列：已有完成记录覆盖目标 FPS，跳过添加。记录 FPS=\(record.targetFPS)，目标 FPS=\(targetFPS)，视频=\(videoURL.lastPathComponent)")
            onFinished?(true)
            return nil
        }

        if let coveredIndex = items.firstIndex(where: {
            $0.videoURL.standardizedFileURL == videoURL.standardizedFileURL
                && $0.targetFPS >= targetFPS
                && !$0.isTerminalForCleanup
        }) {
            if let onCompleted {
                completionHandlers[items[coveredIndex].id, default: []].append(onCompleted)
            }
            if let onFinished {
                terminalHandlers[items[coveredIndex].id, default: []].append(onFinished)
            }
            frameInterpolationDebugPrint("补帧队列：已有任务覆盖目标 FPS，跳过重复添加。任务 FPS=\(items[coveredIndex].targetFPS)，目标 FPS=\(targetFPS)，视频=\(videoURL.lastPathComponent)")
            return items[coveredIndex].id
        }

        let lowerWaitingIDs = items.compactMap { item -> UUID? in
            guard item.videoURL.standardizedFileURL == videoURL.standardizedFileURL,
                  item.targetFPS < targetFPS,
                  case .waiting = item.status else {
                return nil
            }
            return item.id
        }
        for waitingID in lowerWaitingIDs {
            guard let index = items.firstIndex(where: { $0.id == waitingID }) else { continue }
            let removedItem = items.remove(at: index)
            completionHandlers[removedItem.id] = nil
            terminalHandlers[removedItem.id]?.forEach { $0(false) }
            terminalHandlers[removedItem.id] = nil
            frameInterpolationDebugPrint("补帧队列：目标 FPS 已提高，移除低目标等待任务。旧 FPS=\(removedItem.targetFPS)，新 FPS=\(targetFPS)，视频=\(videoURL.lastPathComponent)")
        }

        let id = UUID()
        let item = FrameInterpolationQueueItem(
            id: id,
            videoURL: videoURL,
            title: title?.isEmpty == false ? title! : videoURL.deletingPathExtension().lastPathComponent,
            targetFPS: targetFPS,
            source: source,
            sourceFPS: nil,
            status: .waiting,
            progress: 0,
            writtenFrames: 0,
            totalFrames: nil,
            opticalFlowFrames: 0,
            elapsedSeconds: 0,
            remainingSeconds: nil,
            currentStage: t("frameInterpolationStageWaiting"),
            outputURL: nil,
            addedAt: Date()
        )
        items.append(item)
        VideoOptimizationRecordService.shared.append(.frameQueued, for: videoURL, metadata: [
            "targetFPS": String(targetFPS),
            "source": source.rawValue
        ])
        if let onCompleted {
            completionHandlers[id, default: []].append(onCompleted)
        }
        if let onFinished {
            terminalHandlers[id, default: []].append(onFinished)
        }
        frameInterpolationDebugPrint("补帧队列：已添加任务。来源=\(source.rawValue)，目标 FPS=\(targetFPS)，视频=\(videoURL.path)")
        clearProgressForWaitingItems()
        scheduleNext()
        return id
    }

    private func scheduleNext() {
        clearProgressForWaitingItems()
        let runningCount = runningTasks.count
        let availableSlots = max(0, 1 - runningCount)
        guard availableSlots > 0 else { return }

        let waitingIDs = items
            .filter { item in
                guard runningTasks[item.id] == nil else { return false }
                if case .waiting = item.status { return true }
                return false
            }
            .sorted { $0.addedAt < $1.addedAt }
            .prefix(availableSlots)
            .map(\.id)

        for id in waitingIDs {
            startItem(id: id)
        }
    }

    private func startItem(id: UUID) {
        guard runningTasks[id] == nil,
              runningTasks.count < 1,
              let index = items.firstIndex(where: { $0.id == id }) else { return }

        items[index].status = .analyzing
        items[index].progress = 0
        items[index].writtenFrames = 0
        items[index].totalFrames = nil
        items[index].opticalFlowFrames = 0
        items[index].elapsedSeconds = 0
        items[index].remainingSeconds = nil
        items[index].currentStage = t("frameInterpolationStageReadingFPS")
        let videoURL = items[index].videoURL
        let targetFPS = items[index].targetFPS
        VideoOptimizationRecordService.shared.append(.frameAnalysisStarted, for: videoURL, metadata: [
            "targetFPS": String(targetFPS)
        ])
        startHeartbeat(id: id)
        frameInterpolationDebugPrint("补帧队列：开始任务。视频=\(videoURL.lastPathComponent)，目标 FPS=\(targetFPS)")

        let task = Task.detached(priority: .utility) { [weak self] in
            let decision = await VideoFrameInterpolationAnalyzer.decision(for: videoURL, targetFPS: targetFPS)
            await MainActor.run {
                guard let self,
                      let itemIndex = self.items.firstIndex(where: { $0.id == id }) else { return }
                self.items[itemIndex].sourceFPS = decision.sourceFPS
                self.items[itemIndex].status = .running
                self.items[itemIndex].currentStage = t("frameInterpolationStagePreparingExport")
                if decision.shouldInterpolate {
                    VideoOptimizationRecordService.shared.append(.frameInterpolationStarted, for: videoURL, metadata: [
                        "targetFPS": String(targetFPS),
                        "sourceFPS": decision.sourceFPS.map { String($0) } ?? "unknown"
                    ])
                }
            }

            guard !Task.isCancelled else {
                await MainActor.run {
                    self?.cancelItem(id: id, reason: "任务已取消")
                }
                return
            }
            guard decision.shouldInterpolate else {
                await MainActor.run {
                    self?.finishWithoutExport(id: id, reason: decision.reason)
                }
                return
            }

            let outputURL = await VideoFrameInterpolationExporter.exportIfNeeded(sourceURL: videoURL, targetFPS: targetFPS) { progress in
                Task { @MainActor in
                    FrameInterpolationQueueService.shared.updateProgress(id: id, progress: progress)
                }
            }

            let wasCancelled = Task.isCancelled
            await MainActor.run {
                guard !wasCancelled else {
                    self?.cancelItem(id: id, reason: "任务已取消")
                    return
                }
                self?.finishExport(id: id, sourceURL: videoURL, outputURL: outputURL)
            }
        }
        runningTasks[id] = task
    }

    private func startHeartbeat(id: UUID) {
        stopHeartbeat(id: id)
        taskStartDates[id] = Date()
        heartbeatTasks[id] = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.updateHeartbeat(id: id)
                }
            }
        }
    }

    private func stopHeartbeat(id: UUID) {
        heartbeatTasks[id]?.cancel()
        heartbeatTasks[id] = nil
        taskStartDates[id] = nil
    }

    private func updateHeartbeat(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              let startDate = taskStartDates[id] else {
            stopHeartbeat(id: id)
            return
        }

        switch items[index].status {
        case .analyzing, .running:
            break
        default:
            stopHeartbeat(id: id)
            return
        }

        let elapsed = Date().timeIntervalSince(startDate)
        items[index].elapsedSeconds = elapsed

        if let totalFrames = items[index].totalFrames,
           totalFrames > 0,
           items[index].writtenFrames > 0 {
            let speed = Double(items[index].writtenFrames) / max(elapsed, 0.001)
            let remainingFrames = max(0, totalFrames - items[index].writtenFrames)
            items[index].remainingSeconds = speed > 0 && remainingFrames > 0
                ? Double(remainingFrames) / speed
                : nil
        }

        let percent = Int((items[index].progress * 100).rounded())
        frameInterpolationDebugPrint(
            "补帧队列心跳：状态=\(items[index].statusText)，阶段=\(items[index].currentStage)，进度=\(percent)%，已写=\(items[index].writtenFrames)/\(items[index].totalFrames.map(String.init) ?? "未知")，光流帧=\(items[index].opticalFlowFrames)，耗时=\(Self.formatSeconds(elapsed))，剩余=\(items[index].remainingSeconds.map(Self.formatSeconds) ?? "未知")，视频=\(items[index].videoURL.lastPathComponent)"
        )
    }

    private func updateProgress(id: UUID, progress: FrameInterpolationExportProgress) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        guard runningTasks[id] != nil else {
            if case .waiting = items[index].status {
                clearProgress(at: index)
            }
            frameInterpolationDebugPrint("补帧队列：忽略非运行任务的进度回调。状态=\(items[index].statusText)，视频=\(items[index].videoURL.lastPathComponent)")
            return
        }
        switch items[index].status {
        case .analyzing, .running:
            break
        default:
            frameInterpolationDebugPrint("补帧队列：忽略状态不匹配的进度回调。状态=\(items[index].statusText)，视频=\(items[index].videoURL.lastPathComponent)")
            return
        }
        items[index].progress = progress.progress
        items[index].writtenFrames = progress.writtenFrames
        items[index].totalFrames = progress.totalFrames
        items[index].opticalFlowFrames = progress.opticalFlowFrames
        items[index].elapsedSeconds = progress.elapsedSeconds
        items[index].remainingSeconds = progress.remainingSeconds
        items[index].currentStage = progress.currentStage
    }

    private func clearProgressForWaitingItems() {
        for index in items.indices {
            if case .waiting = items[index].status {
                clearProgress(at: index)
            }
        }
    }

    private func clearProgress(at index: Array<FrameInterpolationQueueItem>.Index) {
        items[index].progress = 0
        items[index].writtenFrames = 0
        items[index].totalFrames = nil
        items[index].opticalFlowFrames = 0
        items[index].elapsedSeconds = 0
        items[index].remainingSeconds = nil
        items[index].currentStage = t("frameInterpolationStageWaiting")
    }

    private func finishWithoutExport(id: UUID, reason: String) {
        runningTasks[id] = nil
        stopHeartbeat(id: id)
        if let index = items.firstIndex(where: { $0.id == id }) {
            let videoName = items[index].videoURL.lastPathComponent
            let videoURL = items[index].videoURL
            let title = items[index].title
            let targetFPS = items[index].targetFPS
            let shouldRepairCompletedRecord = completedRecord(videoURL: videoURL) != nil
                && reason.contains("已达到或高于目标 FPS")
            items[index].status = .completed
            items[index].progress = 1
            items.remove(at: index)
            if shouldRepairCompletedRecord {
                markCompleted(videoURL: videoURL, title: title, targetFPS: targetFPS)
                frameInterpolationDebugPrint("补帧队列：本地文件已满足目标 FPS，已修复完成记录。目标 FPS=\(targetFPS)，视频=\(videoName)")
            }
            VideoOptimizationRecordService.shared.append(.frameNotNeeded, for: videoURL, detail: reason, metadata: [
                "targetFPS": String(targetFPS)
            ])
            frameInterpolationDebugPrint("补帧队列：无需补帧，任务已移除。原因=\(reason)，视频=\(videoName)")
        }
        completionHandlers[id] = nil
        terminalHandlers[id]?.forEach { $0(true) }
        terminalHandlers[id] = nil
        scheduleNext()
    }

    private func cancelItem(id: UUID, reason: String) {
        runningTasks[id] = nil
        stopHeartbeat(id: id)
        if let index = items.firstIndex(where: { $0.id == id }) {
            let videoName = items[index].videoURL.lastPathComponent
            let videoURL = items[index].videoURL
            items.remove(at: index)
            VideoOptimizationRecordService.shared.append(.frameCancelled, for: videoURL, detail: reason)
            frameInterpolationDebugPrint("补帧队列：任务已取消并移除。原因=\(reason)，视频=\(videoName)")
        }
        completionHandlers[id] = nil
        terminalHandlers[id]?.forEach { $0(false) }
        terminalHandlers[id] = nil
        scheduleNext()
    }

    private func finishExport(id: UUID, sourceURL: URL, outputURL: URL?) {
        runningTasks[id] = nil
        stopHeartbeat(id: id)
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            terminalHandlers[id]?.forEach { $0(false) }
            terminalHandlers[id] = nil
            scheduleNext()
            return
        }

        if let outputURL {
            let title = items[index].title
            let targetFPS = items[index].targetFPS
            items[index].status = .completed
            items[index].progress = 1
            items[index].outputURL = outputURL
            items.remove(at: index)
            markCompleted(videoURL: outputURL, title: title, targetFPS: targetFPS)
            frameInterpolationDebugPrint("补帧队列：任务完成，已替换源视频。路径=\(outputURL.path)")
            // 先让所有正在播放该视频的屏幕切换到补帧结果，完成后再通知串行优化任务。
            VideoWallpaperManager.shared.reloadPlaybackAfterInPlaceInterpolation(videoURL: outputURL)
            completionHandlers[id]?.forEach { $0(sourceURL, outputURL) }
            completionHandlers[id] = nil
            terminalHandlers[id]?.forEach { $0(true) }
            terminalHandlers[id] = nil
        } else {
            VideoOptimizationRecordService.shared.append(.frameFailed, for: sourceURL, detail: "optical-flow export failed")
            items[index].status = .failed("optical-flow 导出失败")
            items.remove(at: index)
            completionHandlers[id] = nil
            terminalHandlers[id]?.forEach { $0(false) }
            terminalHandlers[id] = nil
            frameInterpolationDebugPrint("补帧队列：任务失败。视频=\(sourceURL.lastPathComponent)")
        }
        scheduleNext()
    }

    private static func formatSeconds(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "未知" }
        if seconds < 60 { return "\(String(format: "%.1f", seconds))s" }
        return "\(Int(seconds) / 60)m\(Int(seconds) % 60)s"
    }

    var activeProcessingItem: FrameInterpolationQueueItem? {
        items.first { item in
            if case .analyzing = item.status { return true }
            if case .running = item.status { return true }
            return false
        }
    }

    var remainingWorkCount: Int {
        let activeID = activeProcessingItem?.id
        return items.filter { item in
            guard item.id != activeID else { return false }
            return !item.isTerminalForCleanup
        }.count
    }

    private func ensureInterpolationRecordsLoaded() {
        guard !legacyInterpolationRecordsMigrated else { return }
        legacyCompletedInterpolationItems = Self.loadInterpolationRecords(key: Self.completedInterpolationRecordsKey)
        legacyBlacklistedInterpolationItems = Self.loadInterpolationRecords(key: Self.blacklistedInterpolationRecordsKey)
        migrateLegacyInterpolationRecordsToSidecars()
        legacyCompletedInterpolationItems.removeAll()
        legacyBlacklistedInterpolationItems.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.completedInterpolationRecordsKey)
        UserDefaults.standard.removeObject(forKey: Self.blacklistedInterpolationRecordsKey)
        legacyInterpolationRecordsMigrated = true
    }

    /// Existing releases stored interpolation outcomes in UserDefaults. Import
    /// them once into each video's sidecar so future launches do not depend on
    /// that process-wide cache.
    private func migrateLegacyInterpolationRecordsToSidecars() {
        for record in legacyCompletedInterpolationItems
        where VideoOptimizationRecordService.shared.latestFrameLifecycleEvent(for: record.videoURL) == nil {
            VideoOptimizationRecordService.shared.append(.frameApplied, for: record.videoURL, metadata: [
                "targetFPS": String(record.targetFPS),
                "migrated": "true"
            ])
        }
        for record in legacyBlacklistedInterpolationItems
        where VideoOptimizationRecordService.shared.latestFrameLifecycleEvent(for: record.videoURL) == nil {
            VideoOptimizationRecordService.shared.append(.frameBlacklisted, for: record.videoURL, metadata: [
                "targetFPS": String(record.targetFPS),
                "migrated": "true"
            ])
        }
    }

    private func completedSidecarRecord(for videoURL: URL) -> FrameInterpolationRecordItem? {
        guard let event = VideoOptimizationRecordService.shared.latestFrameLifecycleEvent(for: videoURL),
              event.kind == .frameApplied,
              let targetFPS = event.metadata["targetFPS"].flatMap(Int.init),
              targetFPS > 0 else {
            return nil
        }
        return FrameInterpolationRecordItem(
            id: interpolationRecordID(for: videoURL),
            videoPath: videoURL.standardizedFileURL.path,
            title: event.metadata["title"] ?? videoURL.deletingPathExtension().lastPathComponent,
            targetFPS: targetFPS,
            recordedAt: event.date
        )
    }

    private func interpolationRecordID(for videoURL: URL) -> String {
        videoURL.standardizedFileURL.path
    }

    private static func loadInterpolationRecords(key: String) -> [FrameInterpolationRecordItem] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let records = try? JSONDecoder().decode([FrameInterpolationRecordItem].self, from: data) else {
            return []
        }
        return records.sorted { $0.recordedAt > $1.recordedAt }
    }

}

private actor VideoFrameInterpolationExportCoordinator {
    static let shared = VideoFrameInterpolationExportCoordinator()
    private let maxConcurrentExports = 1
    private var activeExportCount = 0
    private var exportWaiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []
    private var tasks: [String: Task<URL?, Never>] = [:]

    func export(
        key: String,
        sourceURL: URL,
        outputURL: URL,
        targetFPS: Int,
        progress: (@Sendable (FrameInterpolationExportProgress) -> Void)? = nil
    ) async -> URL? {
        if let task = tasks[key] {
            frameInterpolationDebugPrint("导出队列：同一个视频已有任务，复用当前任务。视频=\(sourceURL.lastPathComponent)")
            return await task.value
        }

        let task: Task<URL?, Never> = Task.detached(priority: .utility) { () -> URL? in
            let videoName = sourceURL.lastPathComponent
            do {
                try await VideoFrameInterpolationExportCoordinator.shared.acquireExportSlot(videoName: videoName)
            } catch {
                frameInterpolationDebugPrint("导出队列：等待补帧槽位时已取消。视频=\(videoName)")
                return nil
            }

            let result = await VideoFrameInterpolationExporter.performExport(
                sourceURL: sourceURL,
                outputURL: outputURL,
                targetFPS: targetFPS,
                progress: progress
            )
            await VideoFrameInterpolationExportCoordinator.shared.releaseExportSlot(videoName: videoName)
            return result
        }
        tasks[key] = task
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        tasks.removeValue(forKey: key)
        return result
    }

    private func acquireExportSlot(videoName: String) async throws {
        if activeExportCount < maxConcurrentExports {
            activeExportCount += 1
            frameInterpolationDebugPrint("导出队列：开始补帧。当前并发=\(activeExportCount)/\(maxConcurrentExports)，视频=\(videoName)")
            return
        }

        frameInterpolationDebugPrint("导出队列：补帧任务排队等待。当前并发=\(activeExportCount)/\(maxConcurrentExports)，视频=\(videoName)")
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                exportWaiters.append((id: waiterID, continuation: continuation))
            }
        } onCancel: {
            Task {
                await VideoFrameInterpolationExportCoordinator.shared.cancelExportWaiter(id: waiterID, videoName: videoName)
            }
        }
        try Task.checkCancellation()
        frameInterpolationDebugPrint("导出队列：排队任务获得补帧槽位。当前并发=\(activeExportCount)/\(maxConcurrentExports)，视频=\(videoName)")
    }

    private func releaseExportSlot(videoName: String) {
        if exportWaiters.isEmpty {
            activeExportCount = max(0, activeExportCount - 1)
        } else {
            let waiter = exportWaiters.removeFirst()
            waiter.continuation.resume()
        }
        frameInterpolationDebugPrint("导出队列：补帧任务结束。当前并发=\(activeExportCount)/\(maxConcurrentExports)，视频=\(videoName)")
    }

    private func cancelExportWaiter(id: UUID, videoName: String) {
        guard let index = exportWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = exportWaiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
        frameInterpolationDebugPrint("导出队列：已移除取消的排队任务。视频=\(videoName)")
    }
}

enum VideoFrameInterpolationExporter {
    static func exportIfNeeded(
        sourceURL: URL,
        targetFPS: Int,
        progress: (@Sendable (FrameInterpolationExportProgress) -> Void)? = nil
    ) async -> URL? {
        let outputURL = temporaryOutputURL(for: sourceURL)
        try? FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        frameInterpolationDebugPrint("导出服务：临时输出路径准备完成。输出：\(outputURL.path)")
        let key = exportTaskKey(for: sourceURL, targetFPS: targetFPS)
        return await VideoFrameInterpolationExportCoordinator.shared.export(
            key: key,
            sourceURL: sourceURL,
            outputURL: outputURL,
            targetFPS: targetFPS,
            progress: progress
        )
    }

    static func performExport(
        sourceURL: URL,
        outputURL: URL,
        targetFPS: Int,
        progress: (@Sendable (FrameInterpolationExportProgress) -> Void)? = nil
    ) async -> URL? {
        try? FileManager.default.removeItem(at: outputURL)
        guard !Task.isCancelled else {
            frameInterpolationDebugPrint("导出任务：启动前已取消。视频=\(sourceURL.lastPathComponent)")
            return nil
        }

        let asset = AVURLAsset(url: sourceURL)
        frameInterpolationDebugPrint("导出任务：离线补帧开始。当前只使用算法=optical-flow，不执行降级逻辑，目标 FPS=\(targetFPS)，视频=\(sourceURL.lastPathComponent)。")
        guard let exportInfo = await makeFrameInterpolationExportInfo(asset: asset, targetFPS: targetFPS) else {
            frameInterpolationDebugPrint("导出任务：读取视频轨道、尺寸、方向、码率或时长失败。")
            return nil
        }
        guard !Task.isCancelled else {
            frameInterpolationDebugPrint("导出任务：读取参数后已取消。视频=\(sourceURL.lastPathComponent)")
            return nil
        }
        guard SystemMemoryPressure.hasRoomForFrameInterpolationExport(width: exportInfo.width, height: exportInfo.height) else {
            let requiredBytes = SystemMemoryPressure.estimatedFrameInterpolationWorkingSetBytes(
                width: exportInfo.width,
                height: exportInfo.height
            )
            let availableBytes = SystemMemoryPressure.approximateReclaimableBytes()
            frameInterpolationDebugPrint(
                "导出任务：跳过补帧，当前可回收内存不足。需要≈\(formatBytes(requiredBytes))，可用≈\(formatBytes(availableBytes))，视频=\(sourceURL.lastPathComponent)。"
            )
            return nil
        }

        try? FileManager.default.removeItem(at: outputURL)
        frameInterpolationDebugPrint("导出任务：当前使用算法：optical-flow。")
        let succeeded = autoreleasepool {
            frameInterpolationExport(
                asset: asset,
                info: exportInfo,
                outputURL: outputURL,
                targetFPS: targetFPS,
                progress: progress
            )
        }

        guard succeeded else {
            frameInterpolationDebugPrint("导出任务：optical-flow 导出失败；本轮不降级，继续使用原视频播放。")
            try? FileManager.default.removeItem(at: outputURL)
            return nil
        }
        guard !Task.isCancelled else {
            frameInterpolationDebugPrint("导出任务：写入完成后已取消，保留原视频。视频=\(sourceURL.lastPathComponent)")
            try? FileManager.default.removeItem(at: outputURL)
            return nil
        }

        do {
            try replaceSourceVideo(sourceURL, with: outputURL)
            frameInterpolationDebugPrint("导出任务：补帧完成，已替换源视频。算法=optical-flow，路径=\(sourceURL.path)")
            return sourceURL
        } catch {
            frameInterpolationDebugPrint("导出任务：替换源视频失败。\(error.localizedDescription)")
            try? FileManager.default.removeItem(at: outputURL)
            return nil
        }
    }

    private struct FrameInterpolationExportInfo {
        let videoTrack: AVAssetTrack
        let width: Int
        let height: Int
        let preferredTransform: CGAffineTransform
        let duration: CMTime
        let sourceFPS: Double
        let bitrate: Double
    }

    private static func makeFrameInterpolationExportInfo(asset: AVURLAsset, targetFPS: Int) async -> FrameInterpolationExportInfo? {
        guard targetFPS > 0,
              let videoTrack = try? await asset.loadTracks(withMediaType: .video).first,
              let naturalSize = try? await videoTrack.load(.naturalSize),
              let preferredTransform = try? await videoTrack.load(.preferredTransform),
              let duration = try? await asset.load(.duration) else {
            return nil
        }

        let transformedRect = CGRect(origin: .zero, size: naturalSize)
            .applying(preferredTransform)
            .standardized
        let renderSize = CGSize(
            width: max(2, abs(transformedRect.width)),
            height: max(2, abs(transformedRect.height))
        )

        let nominalFPS = (try? await videoTrack.load(.nominalFrameRate)).map(Double.init) ?? 0
        let minFrameDuration = (try? await videoTrack.load(.minFrameDuration)) ?? .invalid
        let fallbackFPS = minFrameDuration.isValid && minFrameDuration.seconds.isFinite && minFrameDuration.seconds > 0
            ? 1.0 / minFrameDuration.seconds
            : 30.0
        let sourceFPS = nominalFPS > 0 ? nominalFPS : fallbackFPS
        let bitrate = Double((try? await videoTrack.load(.estimatedDataRate)) ?? 0)

        frameInterpolationDebugPrint("导出任务：离线补帧参数已准备，源 FPS=\(String(format: "%.2f", sourceFPS))，输出尺寸=\(Int(renderSize.width))x\(Int(renderSize.height))。")
        return FrameInterpolationExportInfo(
            videoTrack: videoTrack,
            width: Int(renderSize.width.rounded()),
            height: Int(renderSize.height.rounded()),
            preferredTransform: preferredTransform,
            duration: duration,
            sourceFPS: sourceFPS,
            bitrate: bitrate
        )
    }

    private static func frameInterpolationExport(
        asset: AVAsset,
        info: FrameInterpolationExportInfo,
        outputURL: URL,
        targetFPS: Int,
        progress: (@Sendable (FrameInterpolationExportProgress) -> Void)? = nil
    ) -> Bool {
        do {
            let reader = try AVAssetReader(asset: asset)
            let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
            writer.shouldOptimizeForNetworkUse = false

            let videoOutput = AVAssetReaderTrackOutput(
                track: info.videoTrack,
                outputSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferMetalCompatibilityKey as String: true,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:]
                ]
            )
            videoOutput.alwaysCopiesSampleData = false
            guard reader.canAdd(videoOutput) else {
                frameInterpolationDebugPrint("导出任务：无法添加视频读取输出。")
                return false
            }
            reader.add(videoOutput)

            let fpsRatio = max(1.0, Double(targetFPS) / max(1.0, info.sourceFPS))
            let bitrate = Int(min(max(info.bitrate * fpsRatio, 4_000_000), 80_000_000))
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: info.width,
                AVVideoHeightKey: info.height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: bitrate,
                    AVVideoExpectedSourceFrameRateKey: targetFPS,
                    AVVideoMaxKeyFrameIntervalKey: targetFPS * 2,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                    AVVideoAllowFrameReorderingKey: false
                ] as [String: Any]
            ]

            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            videoInput.expectsMediaDataInRealTime = false
            videoInput.transform = info.preferredTransform
            guard writer.canAdd(videoInput) else {
                frameInterpolationDebugPrint("导出任务：无法添加视频写入输入。")
                return false
            }
            writer.add(videoInput)

            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: videoInput,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: info.width,
                    kCVPixelBufferHeightKey as String: info.height,
                    kCVPixelBufferMetalCompatibilityKey as String: true,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:]
                ]
            )
            let pixelBufferPool = adaptor.pixelBufferPool
            var exportCompleted = false
            defer {
                if !exportCompleted {
                    if reader.status == .reading {
                        reader.cancelReading()
                    }
                    if writer.status == .writing {
                        writer.cancelWriting()
                    }
                }
                if let pixelBufferPool {
                    CVPixelBufferPoolFlush(pixelBufferPool, CVPixelBufferPoolFlushFlags.excessBuffers)
                }
                FrameInterpolationMetalInterpolator.shared.flushTextureCache()
            }

            guard reader.startReading(), writer.startWriting() else {
                frameInterpolationDebugPrint("导出任务：reader/writer 启动失败。reader=\(reader.error?.localizedDescription ?? "nil") writer=\(writer.error?.localizedDescription ?? "nil")")
                return false
            }
            writer.startSession(atSourceTime: .zero)

            let targetFrameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFPS))
            let duration = info.duration
            let durationSeconds = duration.seconds.isFinite && duration.seconds > 0 ? duration.seconds : 0
            let totalTargetFrames = durationSeconds > 0
                ? max(1, Int64((durationSeconds * Double(targetFPS)).rounded(.up)))
                : 0
            let exportStartDate = Date()
            var outputFrameIndex: Int64 = 0
            var writtenFrameCount: Int64 = 0
            var opticalFlowFrameCount: Int64 = 0
            var sourcePairCount: Int64 = 0
            var lastProgressLogFrame: Int64 = -Int64(max(1, targetFPS))

            frameInterpolationDebugPrint(
                "导出任务：进度初始化。算法==Vision optical-flow + Metal GPU warp，目标总帧数=\(totalTargetFrames > 0 ? "\(totalTargetFrames)" : "未知")，视频时长=\(formatSeconds(durationSeconds))，源 FPS=\(String(format: "%.2f", info.sourceFPS))，目标 FPS=\(targetFPS)。"
            )
            frameInterpolationDebugPrint("导出任务：使用 Vision optical-flow + Metal GPU warp；Metal 不可用或 GPU 执行失败时终止本次补帧。")

            func outputTime(for index: Int64) -> CMTime {
                CMTimeMultiply(targetFrameDuration, multiplier: Int32(index))
            }

            func waitUntilReady() -> Bool {
                while !videoInput.isReadyForMoreMediaData {
                    if Task.isCancelled { return false }
                    if writer.status == .failed || reader.status == .failed || reader.status == .cancelled {
                        return false
                    }
                    Thread.sleep(forTimeInterval: 0.002)
                }
                return true
            }

            func emitProgress(
                stage: String,
                presentationTime: CMTime? = nil,
                shouldLog: Bool = true
            ) {
                let elapsed = Date().timeIntervalSince(exportStartDate)
                let speed = elapsed > 0 ? Double(writtenFrameCount) / elapsed : 0
                let remainingFrames = totalTargetFrames > 0 ? max(0, totalTargetFrames - writtenFrameCount) : 0
                let eta = speed > 0 && remainingFrames > 0 ? Double(remainingFrames) / speed : 0
                progress?(FrameInterpolationExportProgress(
                    progress: totalTargetFrames > 0 ? min(1, max(0, Double(writtenFrameCount) / Double(totalTargetFrames))) : 0,
                    writtenFrames: writtenFrameCount,
                    totalFrames: totalTargetFrames > 0 ? totalTargetFrames : nil,
                    opticalFlowFrames: opticalFlowFrameCount,
                    elapsedSeconds: elapsed,
                    remainingSeconds: eta > 0 ? eta : nil,
                    currentStage: stage
                ))

                guard shouldLog, let presentationTime, durationSeconds > 0 else { return }
                let seconds = presentationTime.seconds
                let percent = totalTargetFrames > 0
                    ? min(100, max(0, Double(writtenFrameCount) / Double(totalTargetFrames) * 100))
                    : min(100, max(0, seconds / durationSeconds * 100))
                frameInterpolationDebugPrint(
                    "导出进度：阶段=\(stage)，算法=optical-flow，\(String(format: "%.1f", percent))%，已写=\(writtenFrameCount)/\(totalTargetFrames > 0 ? "\(totalTargetFrames)" : "未知") 帧，光流帧=\(opticalFlowFrameCount)，源帧对=\(sourcePairCount)，视频时间=\(formatSeconds(seconds))/\(formatSeconds(durationSeconds))，耗时=\(formatSeconds(elapsed))，速度=\(String(format: "%.1f", speed)) 帧/秒，预计剩余=\(eta > 0 ? formatSeconds(eta) : "未知")。"
                )
            }

            func appendFrame(_ pixelBuffer: CVPixelBuffer, at presentationTime: CMTime) -> Bool {
                guard waitUntilReady() else { return false }
                guard !Task.isCancelled else { return false }
                guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
                    frameInterpolationDebugPrint("导出任务：追加帧失败。time=\(presentationTime.seconds)，error=\(writer.error?.localizedDescription ?? "未知错误")")
                    return false
                }
                writtenFrameCount += 1
                let progressLogInterval = Int64(max(1, targetFPS))
                if writtenFrameCount - lastProgressLogFrame >= progressLogInterval || writtenFrameCount == totalTargetFrames {
                    lastProgressLogFrame = writtenFrameCount
                    emitProgress(stage: "已写入第 \(writtenFrameCount) 帧", presentationTime: presentationTime)
                }
                return true
            }

            guard var currentSample = videoOutput.copyNextSampleBuffer(),
                  var currentPixelBuffer = CMSampleBufferGetImageBuffer(currentSample) else {
                frameInterpolationDebugPrint("导出任务：读取首帧失败。")
                writer.cancelWriting()
                reader.cancelReading()
                return false
            }
            defer {
                CMSampleBufferInvalidate(currentSample)
            }

            while let nextSample = videoOutput.copyNextSampleBuffer() {
                var didPromoteNextSample = false
                defer {
                    if !didPromoteNextSample {
                        CMSampleBufferInvalidate(nextSample)
                    }
                }
                if Task.isCancelled {
                    frameInterpolationDebugPrint("导出任务：收到取消请求，停止写入临时文件。")
                    writer.cancelWriting()
                    reader.cancelReading()
                    return false
                }
                sourcePairCount += 1
                let nextPTS = CMSampleBufferGetPresentationTimeStamp(nextSample)
                let currentPTS = CMSampleBufferGetPresentationTimeStamp(currentSample)
                guard let nextPixelBuffer = CMSampleBufferGetImageBuffer(nextSample) else {
                    continue
                }
                var opticalFlowBufferForPair: CVPixelBuffer?
                while outputTime(for: outputFrameIndex) < nextPTS {
                    let presentationTime = outputTime(for: outputFrameIndex)
                    let alpha = interpolationAlpha(currentPTS: currentPTS, nextPTS: nextPTS, outputPTS: presentationTime)
                    let pixelBuffer: CVPixelBuffer?
                    if alpha > 0.001, alpha < 0.999 {
                        opticalFlowFrameCount += 1
                        if opticalFlowBufferForPair == nil {
                            emitProgress(
                                stage: "正在计算源帧对 \(sourcePairCount) 的 optical-flow 场",
                                presentationTime: presentationTime
                            )
                            let flowStart = Date()
                            opticalFlowBufferForPair = autoreleasepool {
                                makeOpticalFlowBuffer(current: currentPixelBuffer, next: nextPixelBuffer)
                            }
                            let flowElapsed = Date().timeIntervalSince(flowStart)
                            guard opticalFlowBufferForPair != nil else {
                                frameInterpolationDebugPrint("导出任务：源帧对 \(sourcePairCount) 的 optical-flow 场计算失败，用时=\(formatSeconds(flowElapsed))。")
                                writer.cancelWriting()
                                reader.cancelReading()
                                return false
                            }
                            frameInterpolationDebugPrint("导出任务：源帧对 \(sourcePairCount) 的 optical-flow 场计算完成，用时=\(formatSeconds(flowElapsed))，将复用生成本组中间帧。")
                        }
                        emitProgress(
                            stage: "正在 warp 第 \(opticalFlowFrameCount) 个 optical-flow 中间帧（源帧对 \(sourcePairCount)，alpha=\(String(format: "%.2f", alpha))）",
                            presentationTime: presentationTime
                        )
                        pixelBuffer = autoreleasepool {
                            makeOpticalFlowWarpedPixelBuffer(
                                current: currentPixelBuffer,
                                next: nextPixelBuffer,
                                flow: opticalFlowBufferForPair!,
                                alpha: alpha,
                                adaptor: adaptor
                            )
                        }
                    } else {
                        pixelBuffer = alpha >= 0.999 ? nextPixelBuffer : currentPixelBuffer
                    }
                    guard let pixelBuffer else {
                        frameInterpolationDebugPrint("导出任务：算法 optical-flow 生成帧失败。time=\(presentationTime.seconds)")
                        writer.cancelWriting()
                        reader.cancelReading()
                        return false
                    }
                    guard appendFrame(pixelBuffer, at: presentationTime) else {
                        writer.cancelWriting()
                        reader.cancelReading()
                        return false
                    }
                    outputFrameIndex += 1
                }
                opticalFlowBufferForPair = nil
                CMSampleBufferInvalidate(currentSample)
                currentSample = nextSample
                currentPixelBuffer = nextPixelBuffer
                didPromoteNextSample = true
            }

            while outputTime(for: outputFrameIndex) < duration {
                if Task.isCancelled {
                    frameInterpolationDebugPrint("导出任务：收到取消请求，停止写入尾帧。")
                    writer.cancelWriting()
                    reader.cancelReading()
                    return false
                }
                let presentationTime = outputTime(for: outputFrameIndex)
                guard appendFrame(currentPixelBuffer, at: presentationTime) else {
                    writer.cancelWriting()
                    reader.cancelReading()
                    return false
                }
                outputFrameIndex += 1
            }

            videoInput.markAsFinished()
            let finishSemaphore = DispatchSemaphore(value: 0)
            writer.finishWriting { finishSemaphore.signal() }
            finishSemaphore.wait()

            guard writer.status == .completed else {
                frameInterpolationDebugPrint("导出任务：writer 完成状态异常。status=\(writer.status.rawValue)，error=\(writer.error?.localizedDescription ?? "未知错误")")
                return false
            }

            frameInterpolationDebugPrint("导出任务：算法 optical-flow 导出完成，输出 FPS=\(targetFPS)，总帧数=\(writtenFrameCount)。")
            exportCompleted = true
            return true
        } catch {
            frameInterpolationDebugPrint("导出任务：异常失败。\(error.localizedDescription)")
            return false
        }
    }

    private static func interpolationAlpha(currentPTS: CMTime, nextPTS: CMTime, outputPTS: CMTime) -> Double {
        let span = nextPTS - currentPTS
        guard span.seconds.isFinite, span.seconds > 0 else { return 0 }
        let offset = outputPTS - currentPTS
        guard offset.seconds.isFinite else { return 0 }
        return min(1, max(0, offset.seconds / span.seconds))
    }

    private static func makeOpticalFlowBuffer(
        current: CVPixelBuffer,
        next: CVPixelBuffer
    ) -> CVPixelBuffer? {
        guard CVPixelBufferGetWidth(current) == CVPixelBufferGetWidth(next),
              CVPixelBufferGetHeight(current) == CVPixelBufferGetHeight(next),
              CVPixelBufferGetPixelFormatType(current) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetPixelFormatType(next) == kCVPixelFormatType_32BGRA else {
            return nil
        }

        do {
            let request = VNGenerateOpticalFlowRequest(targetedCVPixelBuffer: next, options: [:])
            request.computationAccuracy = .medium
            request.outputPixelFormat = kCVPixelFormatType_TwoComponent32Float
            let handler = VNImageRequestHandler(cvPixelBuffer: current, options: [:])
            try handler.perform([request])
            return request.results?.first?.pixelBuffer
        } catch {
            frameInterpolationDebugPrint("导出任务：optical-flow 计算失败：\(error.localizedDescription)")
            return nil
        }
    }

    private static func makeOpticalFlowWarpedPixelBuffer(
        current: CVPixelBuffer,
        next: CVPixelBuffer,
        flow: CVPixelBuffer,
        alpha: Double,
        adaptor: AVAssetWriterInputPixelBufferAdaptor
    ) -> CVPixelBuffer? {
        guard let output = makePixelBuffer(from: adaptor) else { return nil }
        guard CVPixelBufferGetWidth(current) == CVPixelBufferGetWidth(flow),
              CVPixelBufferGetHeight(current) == CVPixelBufferGetHeight(flow),
              CVPixelBufferGetPixelFormatType(flow) == kCVPixelFormatType_TwoComponent32Float else {
            return nil
        }

        if FrameInterpolationMetalInterpolator.shared.interpolate(
            current: current,
            next: next,
            flow: flow,
            alpha: alpha,
            output: output
        ) {
            return output
        }

        frameInterpolationDebugPrint("导出任务：Metal GPU warp 失败，已按 GPU-only 策略终止本次补帧。")
        return nil
    }

    private static func makePixelBuffer(from adaptor: AVAssetWriterInputPixelBufferAdaptor) -> CVPixelBuffer? {
        guard let pool = adaptor.pixelBufferPool else { return nil }
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        guard status == kCVReturnSuccess else { return nil }
        return pixelBuffer
    }

    private static func formatSeconds(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "未知" }
        if seconds < 60 {
            return "\(String(format: "%.1f", seconds))s"
        }
        let minutes = Int(seconds) / 60
        let remainingSeconds = Int(seconds) % 60
        return "\(minutes)m\(remainingSeconds)s"
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        let gib = Double(bytes) / 1024.0 / 1024.0 / 1024.0
        return "\(String(format: "%.2f", gib))GB"
    }

    private static func temporaryOutputURL(for sourceURL: URL) -> URL {
        sourceURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(sourceURL.deletingPathExtension().lastPathComponent).waifux-interpolating-\(UUID().uuidString)")
            .appendingPathExtension("mp4")
    }

    private static func replaceSourceVideo(_ sourceURL: URL, with temporaryURL: URL) throws {
        let backupURL = sourceURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(sourceURL.lastPathComponent).waifux-original-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: sourceURL, to: backupURL)
            try FileManager.default.moveItem(at: temporaryURL, to: sourceURL)
            try? FileManager.default.removeItem(at: backupURL)
        } catch {
            if !FileManager.default.fileExists(atPath: sourceURL.path),
               FileManager.default.fileExists(atPath: backupURL.path) {
                try? FileManager.default.moveItem(at: backupURL, to: sourceURL)
            }
            throw error
        }
    }

    private static func exportTaskKey(for sourceURL: URL, targetFPS: Int) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let size = attrs?[.size] as? UInt64 ?? 0
        let modified = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let raw = "\(sourceURL.standardizedFileURL.path)|\(size)|\(modified)|fps=\(targetFPS)|algorithm=optical-flow-only-v1"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

private final class WallpaperVideoContainerView: NSView {
    private var storedPosterLayer: CALayer?
    private var grainOverlayView: NSView?
    private var blackTransitionLayer: CALayer?

    /// 实际播放视频的 AVPlayerLayer。作为容器 backing layer 的子层，
    /// 通过修改它的 frame 实现 pan/zoom 裁切（容器 backing layer masksToBounds 自然裁剪）。
    private let avPlayerLayer = AVPlayerLayer()

    /// 上一次 layout() 后的 viewport 矩形（容器 bounds 坐标系），用于 layout 时复用。
    private var currentViewportRect: CGRect?
    /// 上一次 layout() 后的壁纸图层 frame（含 pan/zoom 偏移），用于 poster 同步。
    private var currentLayerFrame: CGRect?
    /// 上一次 layout() 后的 wallpaperCropRect（归一化），用于 layout 时复用。
    private var currentWallpaperCropRect: UnitRect?

    var isShowingPoster: Bool {
        storedPosterLayer != nil
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // 容器 backing layer：CALayer + masksToBounds，作为 viewport 裁剪盒
        let container = CALayer()
        container.masksToBounds = true
        layer = container
        avPlayerLayer.videoGravity = .resizeAspectFill
        avPlayerLayer.needsDisplayOnBoundsChange = true
        avPlayerLayer.frame = bounds
        container.addSublayer(avPlayerLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var playerLayer: AVPlayerLayer { avPlayerLayer }

    /// 应用已算好的 CropLayout；nil 回现状 aspect-fill。
    /// 实现：
    /// 1. viewport（可视框）通过 avPlayerLayer.frame 限制到 viewport 区域；容器 backing layer
    ///    masksToBounds=true 让 viewport 之外可见 view 背景（letterbox 由 window.backgroundColor 提供）。
    /// 2. pan/zoom 通过把 avPlayerLayer.frame 在 viewport 内 放大并偏移 实现：
    ///    layer.frame.size = viewport.size / wallpaperCropRect.size
    ///    layer.frame.origin = viewport.origin - wallpaperCropRect.origin × layer.frame.size
    ///    然后 backing layer masksToBounds 把溢出的部分裁掉。
    ///    注意：CALayer y 向上、CropLayout y 向下，需做 y 翻转。
    func applyCropLayout(_ layout: CropLayout?) {
        let viewBounds = bounds
        guard let layout, viewBounds.width > 0, viewBounds.height > 0 else {
            currentViewportRect = nil
            currentLayerFrame = nil
            currentWallpaperCropRect = nil
            avPlayerLayer.videoGravity = .resizeAspectFill
            avPlayerLayer.frame = viewBounds
            blackTransitionLayer?.frame = viewBounds
            // 回退：mask 清除，poster/grain 恢复全 bounds
            layer?.mask = nil
            storedPosterLayer?.frame = viewBounds  // 无 crop 时 poster 也铺满
            grainOverlayView?.autoresizingMask = [.width, .height]
            grainOverlayView?.frame = viewBounds
            return
        }
        // 视频不变形 → aspect-fill 到 layer bounds
        avPlayerLayer.videoGravity = .resizeAspectFill

        // viewport 在 view 坐标系（y 向上）。CropLayout.viewportRect y 向下需翻转。
        let vpW = layout.viewportRect.w * viewBounds.width
        let vpH = layout.viewportRect.h * viewBounds.height
        let vpX = layout.viewportRect.x * viewBounds.width
        let vpY = (1.0 - layout.viewportRect.y - layout.viewportRect.h) * viewBounds.height
        let viewport = CGRect(x: vpX, y: vpY, width: vpW, height: vpH)
        currentViewportRect = viewport
        currentWallpaperCropRect = layout.wallpaperCropRect

        // layer frame：放大到 viewport.size / cropRect.size，再偏移使得 viewport 看到 cropRect
        let crop = layout.wallpaperCropRect
        let cropW = max(0.0001, crop.w)
        let cropH = max(0.0001, crop.h)
        let layerW = vpW / cropW
        let layerH = vpH / cropH
        // cropRect.y 向下 → 翻转：从 wallpaper 顶部移除 (1-y-h) 高度 ⇔ layer 上沿移动到 viewport 顶之上 crop.y × layerH
        let layerX = vpX - crop.x * layerW
        let layerY = vpY - (1.0 - crop.y - crop.h) * layerH
        let computedLayerFrame = CGRect(x: layerX, y: layerY, width: layerW, height: layerH)
        avPlayerLayer.frame = computedLayerFrame
        currentLayerFrame = computedLayerFrame

        // ⚠️ 关键：当 cropRect 不是正方形时（如 viewport 比例窗口），avPlayerLayer 在某个方向
        // 被放大后会超出 viewport 边界。容器 backing layer 的 masksToBounds 只裁到 view bounds（全屏），
        // 不会裁到 viewport，所以视频内容会"漏"进 letterbox 区域，盖掉 window.backgroundColor。
        // 解决方案：给容器 layer 装一个 viewport 矩形的 mask，把所有子层裁到 viewport 内。
        // viewport 等于 bounds（无 letterbox）时不装 mask，避免无谓开销。
        let isFullViewport = abs(vpX) < 0.5 && abs(vpY) < 0.5
            && abs(vpW - viewBounds.width) < 0.5 && abs(vpH - viewBounds.height) < 0.5
        if isFullViewport {
            layer?.mask = nil
        } else {
            let mask = (layer?.mask as? CALayer) ?? CALayer()
            mask.backgroundColor = CGColor(gray: 1, alpha: 1)
            mask.frame = viewport
            layer?.mask = mask
        }

        // poster 是 sublayer，和 avPlayerLayer 同级，容器 mask 自动裁剪。
        // poster frame 必须和 avPlayerLayer 完全一致（含 pan/zoom 偏移），这样被 mask 裁后才能显示相同区域。
        storedPosterLayer?.frame = computedLayerFrame
        grainOverlayView?.autoresizingMask = []
        grainOverlayView?.frame = viewport
        blackTransitionLayer?.frame = viewBounds
    }

    func cancelPlayerTransitionIfNeeded() {
        blackTransitionLayer?.removeAllAnimations()
        blackTransitionLayer?.removeFromSuperlayer()
        blackTransitionLayer = nil
    }

    func fadeToBlack(duration: TimeInterval, completion: @escaping () -> Void) {
        cancelPlayerTransitionIfNeeded()
        let blackLayer = CALayer()
        blackLayer.backgroundColor = NSColor.black.cgColor
        blackLayer.frame = bounds
        blackLayer.opacity = 0
        layer?.addSublayer(blackLayer)
        blackTransitionLayer = blackLayer

        CATransaction.begin()
        CATransaction.setAnimationDuration(max(0.12, duration))
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        CATransaction.setCompletionBlock(completion)
        blackLayer.opacity = 1
        CATransaction.commit()
    }

    func revealFromBlack(duration: TimeInterval) {
        guard let blackLayer = blackTransitionLayer else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(max(0.12, duration))
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        CATransaction.setCompletionBlock { [weak self, weak blackLayer] in
            guard let self, let blackLayer, self.blackTransitionLayer === blackLayer else { return }
            blackLayer.removeFromSuperlayer()
            self.blackTransitionLayer = nil
        }
        blackLayer.opacity = 0
        CATransaction.commit()
    }

    func transitionThroughBlack(duration: TimeInterval, completion: @escaping () -> Void) {
        fadeToBlack(duration: duration) { [weak self] in
            guard let self else {
                completion()
                return
            }
            completion()
            self.revealFromBlack(duration: duration)
        }
    }

    /// 显示预览图（锁屏或无权限时使用）
    /// 使用 CALayer（sublayer）而非 NSImageView（subview），确保被容器 layer mask 正确裁剪到 viewport。
    func showPoster(_ image: NSImage) {
        hidePoster()

        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let posterLayer = CALayer()
        posterLayer.contentsGravity = .resizeAspectFill
        posterLayer.contents = cg
        // poster 必须和 avPlayerLayer 使用完全相同的 frame（含 pan/zoom 偏移），
        // 这样被容器 mask 裁剪后才能显示一致的区域
        posterLayer.frame = currentLayerFrame ?? bounds
        layer?.addSublayer(posterLayer)
        storedPosterLayer = posterLayer
    }

    /// 隐藏预览图
    func hidePoster() {
        storedPosterLayer?.removeFromSuperlayer()
        storedPosterLayer = nil
    }

    /// 显示噪点纹理叠加（Arc 磨砂质感，平铺实现）
    func showGrainOverlay(intensity: Double) {
        hideGrainOverlay()
        guard intensity > 0.01 else { return }

        let targetFrame = currentViewportRect ?? bounds
        let overlayView = GrainPatternOverlayView(frame: targetFrame)
        overlayView.intensity = intensity
        // crop 模式下不能 autoresize（会被拉回 bounds），由 layout() 手动同步到 viewport
        overlayView.autoresizingMask = currentViewportRect != nil ? [] : [.width, .height]
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
        // 无 crop（或回退状态）：avPlayerLayer 铺满 bounds；
        // 有 crop：avPlayerLayer.frame 由 applyCropLayout 设定，layout 时不动它（外层会在
        // bounds 变化后调用 applyCropToScreen 重新计算）。
        if currentWallpaperCropRect == nil {
            avPlayerLayer.frame = bounds
        }
        blackTransitionLayer?.frame = bounds

        // poster 是 sublayer，和 avPlayerLayer 同级，容器 mask 自动裁剪。
        // poster frame 必须和 avPlayerLayer 一致（含 pan/zoom 偏移），不能用 viewport。
        if let lf = currentLayerFrame {
            storedPosterLayer?.frame = lf
        } else {
            storedPosterLayer?.frame = bounds
        }
        if let vp = currentViewportRect {
            grainOverlayView?.frame = vp
        } else {
            grainOverlayView?.frame = bounds
        }
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

/// 负责视频壁纸的循环点分析。
/// 分析完成后直接裁剪并替换原始文件，并在对应下载记录中标记 `isLooped = true`。
@MainActor
final class VideoLoopPreprocessingService: ObservableObject {
    static let shared = VideoLoopPreprocessingService()

    enum LoopPointState: Equatable {
        case idle
        case analyzing
        case applied
        case notNeeded
        case noReliablePoint
        case failed(String)
    }

    private enum CompletedOutcome: String, Codable {
        case applied
        case notNeeded
        case noReliablePoint
    }

    private struct CompletedAnalysisRecord: Codable {
        let signature: String
        let outcome: CompletedOutcome
    }

    @Published private(set) var isProcessing = false
    @Published private(set) var currentProcessingFile: String?
    @Published private(set) var analysisProgress: Double = 0
    @Published private(set) var state: LoopPointState = .idle
    @Published private(set) var statesByVideo: [String: LoopPointState] = [:]
    @Published private(set) var progressByVideo: [String: Double] = [:]

    private let tempDirectory: URL
    private let completedAnalysisDefaultsKey = "video_loop_completed_analysis_v1"
    private var completedAnalysisRecords: [String: CompletedAnalysisRecord] = [:]

    private init() {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WaifuXLoopExport", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        if let data = UserDefaults.standard.data(forKey: completedAnalysisDefaultsKey),
           let records = try? JSONDecoder().decode([String: CompletedAnalysisRecord].self, from: data) {
            completedAnalysisRecords = records
        }
        migrateLegacyCompletedAnalysisRecordsToSidecars()
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

    func hasCompletedAnalysis(_ fileURL: URL) -> Bool {
        if isProcessed(fileURL) { return true }
        return completedState(for: fileURL) != nil
    }

    func state(for fileURL: URL) -> LoopPointState {
        let key = fileURL.standardizedFileURL.path
        if let state = statesByVideo[key] { return state }
        if isProcessed(fileURL) { return .applied }
        return persistedLoopState(for: fileURL) ?? .idle
    }

    func progress(for fileURL: URL) -> Double {
        progressByVideo[fileURL.standardizedFileURL.path] ?? 0
    }

    // MARK: - Preprocessing

    /// 异步分析指定视频。如果已处理则直接返回。
    /// 处理完成后替换原始文件，并更新对应下载记录的 `isLooped` 标记。
    @discardableResult
    func analyzeIfNeeded(_ originalURL: URL, force: Bool = false) async -> Bool {
        let videoKey = originalURL.standardizedFileURL.path
        if !force, let completedState = completedState(for: originalURL) {
            state = completedState
            statesByVideo[videoKey] = completedState
            progressByVideo[videoKey] = 1
            return true
        }

        VideoOptimizationRecordService.shared.append(.loopAnalysisStarted, for: originalURL, metadata: [
            "force": force ? "true" : "false"
        ])

        isProcessing = true
        currentProcessingFile = originalURL.lastPathComponent
        analysisProgress = 0
        state = .analyzing
        statesByVideo[videoKey] = .analyzing
        progressByVideo[videoKey] = 0
        defer {
            isProcessing = false
            currentProcessingFile = nil
        }

        do {
            let tempURL = tempDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
            let analysisTask = Task.detached(priority: .userInitiated) {
                try await Self.exportAnalyzedLoopVideo(from: originalURL, to: tempURL) { progress in
                    Task { @MainActor in
                        VideoLoopPreprocessingService.shared.updateProgress(videoKey: videoKey, progress: progress)
                    }
                }
            }
            let decision = try await withTaskCancellationHandler {
                try await analysisTask.value
            } onCancel: {
                analysisTask.cancel()
            }
            try Task.checkCancellation()

            switch decision {
            case .trim(let result):
                guard FileManager.default.fileExists(atPath: tempURL.path) else {
                    throw NSError(domain: "VideoLoop", code: 6, userInfo: [NSLocalizedDescriptionKey: "Exported file not found"])
                }

                // 原子替换原始文件
                _ = try FileManager.default.replaceItemAt(originalURL, withItemAt: tempURL)

                // 更新下载记录标记
                let path = originalURL.path
                WallpaperLibraryService.shared.markAsLooped(localFilePath: path)
                MediaLibraryService.shared.markAsLooped(localFilePath: path)

                state = .applied
                statesByVideo[videoKey] = .applied
                VideoOptimizationRecordService.shared.append(.loopApplied, for: originalURL, metadata: [
                    "firstContentFrame": String(result.firstContentFrame),
                    "matchFrame": String(result.matchFrame)
                ])
                print("[VideoLoopPreprocessing] Applied loop point firstFrame=\(result.firstContentFrame) matchFrame=\(result.matchFrame) file=\(originalURL.lastPathComponent)")
            case .notNeeded:
                state = .notNeeded
                statesByVideo[videoKey] = .notNeeded
                VideoOptimizationRecordService.shared.append(.loopNotNeeded, for: originalURL)
                print("[VideoLoopPreprocessing] Video is already a seamless loop: \(originalURL.lastPathComponent)")
            case .noReliablePoint:
                state = .noReliablePoint
                statesByVideo[videoKey] = .noReliablePoint
                VideoOptimizationRecordService.shared.append(.loopNoReliablePoint, for: originalURL)
                print("[VideoLoopPreprocessing] No reliable loop point found; keeping original video: \(originalURL.lastPathComponent)")
            }
            analysisProgress = 1
            progressByVideo[videoKey] = 1
            return true
        } catch is CancellationError {
            // A queue reset is not an analysis failure. Do not recreate a failed
            // state after reset has already removed this video's transient state.
            progressByVideo.removeValue(forKey: videoKey)
            if currentProcessingFile == originalURL.lastPathComponent {
                state = .idle
                analysisProgress = 0
            }
            return false
        } catch {
            print("[VideoLoopPreprocessing] Failed for \(originalURL.lastPathComponent): \(error)")
            state = .failed(error.localizedDescription)
            statesByVideo[videoKey] = .failed(error.localizedDescription)
            VideoOptimizationRecordService.shared.append(.loopFailed, for: originalURL, detail: error.localizedDescription)
            return false
        }
    }

    private func updateProgress(videoKey: String, progress: Double) {
        let clamped = min(1, max(0, progress))
        analysisProgress = clamped
        progressByVideo[videoKey] = clamped
    }

    func resetState() {
        guard !isProcessing else { return }
        state = .idle
    }

    func resetState(for fileURL: URL) {
        let key = fileURL.standardizedFileURL.path
        statesByVideo.removeValue(forKey: key)
        progressByVideo.removeValue(forKey: key)
        if currentProcessingFile != fileURL.lastPathComponent {
            state = .idle
            analysisProgress = 0
        }
        WallpaperLibraryService.shared.clearLooped(localFilePath: fileURL.path)
        MediaLibraryService.shared.clearLooped(localFilePath: fileURL.path)
        VideoOptimizationRecordService.shared.append(.optimizationReset, for: fileURL)
    }

    private func completedState(for fileURL: URL) -> LoopPointState? {
        if isProcessed(fileURL) { return .applied }
        // Per-video sidecar is authoritative. A reset event must not be
        // overridden by the pre-sidecar UserDefaults compatibility cache.
        if let persistedState = persistedLoopState(for: fileURL) {
            switch persistedState {
            case .applied, .notNeeded, .noReliablePoint:
                return persistedState
            case .idle, .analyzing, .failed:
                break
            }
        }
        if let lifecycle = VideoOptimizationRecordService.shared.latestLoopLifecycleEvent(for: fileURL),
           lifecycle.kind == .optimizationReset {
            return nil
        }
        return nil
    }

    /// In-flight analysis cannot be resumed safely after a relaunch, but terminal
    /// outcomes and failures are restored from the video's sidecar record.
    private func persistedLoopState(for fileURL: URL) -> LoopPointState? {
        guard let event = VideoOptimizationRecordService.shared.latestLoopLifecycleEvent(for: fileURL) else {
            return nil
        }

        switch event.kind {
        case .loopApplied:
            return .applied
        case .loopNotNeeded:
            return .notNeeded
        case .loopNoReliablePoint:
            return .noReliablePoint
        case .loopFailed:
            return .failed(event.detail ?? "Loop point analysis failed")
        case .optimizationReset, .loopQueued, .loopAnalysisStarted:
            return nil
        default:
            return nil
        }
    }

    /// Import terminal outcomes from pre-sidecar releases once, then remove the
    /// process-wide cache. New optimization state is stored beside its video.
    private func migrateLegacyCompletedAnalysisRecordsToSidecars() {
        defer {
            completedAnalysisRecords.removeAll()
            UserDefaults.standard.removeObject(forKey: completedAnalysisDefaultsKey)
        }

        for (path, record) in completedAnalysisRecords {
            let videoURL = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: videoURL.path),
                  VideoOptimizationRecordService.shared.latestLoopLifecycleEvent(for: videoURL) == nil else {
                continue
            }

            let event: VideoOptimizationRecordService.EventKind
            switch record.outcome {
            case .applied:
                event = .loopApplied
            case .notNeeded:
                event = .loopNotNeeded
            case .noReliablePoint:
                event = .loopNoReliablePoint
            }
            VideoOptimizationRecordService.shared.append(event, for: videoURL, metadata: [
                "migratedFrom": "video_loop_completed_analysis_v1",
                "legacySignature": record.signature
            ])
        }
    }

    // MARK: - Export

    private struct LoopAnalysisResult: Sendable {
        let firstContentFrame: Int
        let matchFrame: Int
        let startTime: CMTime
        let endTime: CMTime
    }

    private enum LoopAnalysisDecision: Sendable {
        case trim(LoopAnalysisResult)
        case notNeeded
        case noReliablePoint
    }

    /// 带时间戳的低分辨率特征；用于在全局候选周围做局部边界精修。
    nonisolated private struct TimedFrameSignature: Sendable {
        let frame: Int
        let time: CMTime
        let signature: FrameSignature
    }

    nonisolated private struct RefinedLoopBoundary: Sendable {
        let start: TimedFrameSignature
        let end: TimedFrameSignature
        let difference: FrameWindowDifference
    }

    nonisolated private static func exportAnalyzedLoopVideo(
        from originalURL: URL,
        to outputURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> LoopAnalysisDecision {
        let asset = AVURLAsset(url: originalURL)
        let duration = try await asset.load(.duration)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)

        guard let videoTrack = videoTracks.first else {
            throw NSError(domain: "VideoLoop", code: 1, userInfo: [NSLocalizedDescriptionKey: "No video track"])
        }

        progress(0.04)

        // 先做轻量首尾窗口预检。大量视频本身就是完整循环，直接跳过后续全片扫描和重编码。
        if try await Self.isAlreadySeamlessLoop(asset: asset, videoTrack: videoTrack, duration: duration) {
            progress(0.98)
            return .notNeeded
        }

        let reader = try AVAssetReader(asset: asset)
        let videoOutput = makeLoopAnalysisVideoOutput(for: videoTrack)
        guard reader.canAdd(videoOutput) else {
            throw NSError(domain: "VideoLoop", code: 10, userInfo: [NSLocalizedDescriptionKey: "Unable to read video frames"])
        }
        reader.add(videoOutput)
        guard reader.startReading() else {
            throw reader.error ?? NSError(domain: "VideoLoop", code: 11, userInfo: [NSLocalizedDescriptionKey: "Unable to start video reader"])
        }

        var referenceFrames: [TimedFrameSignature] = []
        var activeCandidates: [PendingLoopCandidate] = []
        var verifiedCandidates: [LoopCandidate] = []
        var lastSignature: FrameSignature?
        var frameIndex = 0
        let durationSeconds = max(0.001, duration.seconds)
        let verificationFrameCount = 12
        let refinementFrameCount = 20
        let minimumLoopDuration: Double = 0.75

        // 顺序解码一次：以首个有效帧开始的连续窗口为参考，验证候选点后面的连续帧。
        // 单帧相近可能只是静止画面或运动恰好经过同一位置，连续窗口才能确认循环相位。
        while let sampleBuffer = videoOutput.copyNextSampleBuffer() {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                frameIndex += 1
                continue
            }
            let signature = try FrameSignature(pixelBuffer: pixelBuffer)
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            lastSignature = signature

            if referenceFrames.isEmpty {
                if !signature.isPureBlack {
                    referenceFrames.append(TimedFrameSignature(
                        frame: frameIndex,
                        time: presentationTime,
                        signature: signature
                    ))
                }
            } else if referenceFrames.count < refinementFrameCount {
                referenceFrames.append(TimedFrameSignature(
                    frame: frameIndex,
                    time: presentationTime,
                    signature: signature
                ))
            } else if let startTime = referenceFrames.first?.time {
                var remainingCandidates: [PendingLoopCandidate] = []
                remainingCandidates.reserveCapacity(activeCandidates.count)

                for var candidate in activeCandidates {
                    let referenceIndex = candidate.comparedFrameCount
                    candidate.append(signature, reference: referenceFrames[referenceIndex].signature)
                    if candidate.comparedFrameCount == verificationFrameCount {
                        if candidate.difference.isReliableLoopMatch {
                            verifiedCandidates.append(candidate.completed())
                        }
                    } else {
                        remainingCandidates.append(candidate)
                    }
                }
                activeCandidates = remainingCandidates

                let elapsedFromStart = max(0, CMTimeGetSeconds(CMTimeSubtract(presentationTime, startTime)))
                if elapsedFromStart >= minimumLoopDuration {
                    let difference = signature.difference(to: referenceFrames[0].signature)
                    if difference.isPotentialLoopMatch {
                        activeCandidates.append(PendingLoopCandidate(
                            frame: frameIndex,
                            time: presentationTime,
                            firstDifference: difference
                        ))
                    }
                }
            }

            if frameIndex % 12 == 0 {
                let elapsed = max(0, presentationTime.seconds)
                progress(0.05 + 0.70 * min(1, elapsed / durationSeconds))
            }
            frameIndex += 1
        }

        if reader.status == .failed {
            throw reader.error ?? NSError(domain: "VideoLoop", code: 12, userInfo: [NSLocalizedDescriptionKey: "Video frame reading failed"])
        }

        guard let firstReferenceFrame = referenceFrames.first else {
            throw NSError(domain: "VideoLoop", code: 7, userInfo: [NSLocalizedDescriptionKey: "No non-black frame found"])
        }

        guard !verifiedCandidates.isEmpty else {
            // 未出现可裁的重复尾帧时，只在首尾高度相似的情况下认定为天然循环。
            // 其余情况不是处理错误，保留文件并交给后续补帧流程。
            return lastSignature?.isLoopBoundarySimilar(to: firstReferenceFrame.signature) == true
                ? .notNeeded
                : .noReliablePoint
        }

        // 循环时长以首个有效画面为起点，避免片头黑帧影响判断。
        // 超过 10 秒的视频不接受短循环点；短视频只保留时间最靠后的循环点。
        let minimumAcceptedLoopDuration: Double = 10
        let candidatesForRefinement: [LoopCandidate]
        if durationSeconds <= minimumAcceptedLoopDuration {
            candidatesForRefinement = verifiedCandidates.max { lhs, rhs in
                CMTimeCompare(lhs.time, rhs.time) < 0
            }.map { [$0] } ?? []
        } else {
            candidatesForRefinement = verifiedCandidates.filter { candidate in
                CMTimeGetSeconds(CMTimeSubtract(candidate.time, firstReferenceFrame.time)) >= minimumAcceptedLoopDuration
            }
        }

        guard !candidatesForRefinement.isEmpty else {
            print("[VideoLoopPreprocessing] No loop candidates passed the 10s minimum duration filter")
            return .noReliablePoint
        }

        let fallbackCandidate = selectLastReliableCandidate(from: candidatesForRefinement)
        var refinedBoundaries: [RefinedLoopBoundary] = []
        refinedBoundaries.reserveCapacity(candidatesForRefinement.count)
        for (index, candidate) in candidatesForRefinement.enumerated() {
            do {
                if let refinedBoundary = try await refineLoopBoundary(
                    in: asset,
                    videoTrack: videoTrack,
                    duration: duration,
                    referenceFrames: referenceFrames,
                    candidate: candidate
                ) {
                    refinedBoundaries.append(refinedBoundary)
                }
            } catch {
                // 单个候选点读取失败不影响其他候选点。
                print("[VideoLoopPreprocessing] Candidate refinement skipped: frame=\(candidate.frame), error=\(error.localizedDescription)")
            }
            progress(0.70 + 0.07 * Double(index + 1) / Double(max(1, candidatesForRefinement.count)))
        }

        let bestRefinedBoundary = refinedBoundaries.min { lhs, rhs in
            if lhs.difference.qualityScore == rhs.difference.qualityScore {
                return lhs.end.time > rhs.end.time
            }
            return lhs.difference.qualityScore < rhs.difference.qualityScore
        }
        guard let selectedBoundary = bestRefinedBoundary ?? fallbackCandidate.map({
            RefinedLoopBoundary(
                start: firstReferenceFrame,
                end: TimedFrameSignature(frame: $0.frame, time: $0.time, signature: firstReferenceFrame.signature),
                difference: $0.difference
            )
        }),
        selectedBoundary.end.frame > selectedBoundary.start.frame,
        CMTimeCompare(selectedBoundary.end.time, selectedBoundary.start.time) > 0 else {
            return .noReliablePoint
        }

        let startFrame = selectedBoundary.start.frame
        let startTime = selectedBoundary.start.time
        let endFrame = selectedBoundary.end.frame
        let endTime = selectedBoundary.end.time
        print(
            "[VideoLoopPreprocessing] Loop candidate selected: frame=\(endFrame), " +
            "time=\(String(format: "%.3f", endTime.seconds))s, " +
            "windowMAE=\(String(format: "%.2f", selectedBoundary.difference.meanAbsoluteDifference)), " +
            "windowRMSE=\(String(format: "%.2f", selectedBoundary.difference.rootMeanSquareDifference)), " +
            "strongDelta=\(String(format: "%.2f%%", selectedBoundary.difference.strongDifferenceRatio * 100)), " +
            "verifiedCandidates=\(verifiedCandidates.count), eligibleCandidates=\(candidatesForRefinement.count), refinedCandidates=\(refinedBoundaries.count)"
        )

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let trimDuration = CMTimeSubtract(endTime, startTime)
        let sourceRange = CMTimeRange(start: startTime, duration: trimDuration)
        let composition = AVMutableComposition()

        guard let compositionVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw NSError(domain: "VideoLoop", code: 2)
        }
        try compositionVideoTrack.insertTimeRange(sourceRange, of: videoTrack, at: .zero)
        compositionVideoTrack.preferredTransform = try await videoTrack.load(.preferredTransform)

        // 音频按同一时间范围裁剪，保持与视频对齐。
        if let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first,
           let compositionAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try? compositionAudioTrack.insertTimeRange(sourceRange, of: audioTrack, at: .zero)
        }

        guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw NSError(domain: "VideoLoop", code: 4, userInfo: [NSLocalizedDescriptionKey: "Export session creation failed"])
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        exportSession.shouldOptimizeForNetworkUse = false
        progress(0.78)

        // 裁剪导出本身可能占据分析任务的大部分时间。将 AVFoundation 的实时导出进度
        // 映射到 78% - 99%，避免 UI 在 78% 停住后直接消失。
        let exportProgressObservation = exportSession.observe(\.progress, options: [.initial, .new]) { _, change in
            let exportProgress = min(1, max(0, Double(change.newValue ?? 0)))
            progress(0.78 + 0.21 * exportProgress)
        }
        defer { exportProgressObservation.invalidate() }
        await exportSession.export()

        if let error = exportSession.error {
            throw error
        }
        guard exportSession.status == .completed else {
            throw NSError(domain: "VideoLoop", code: 5, userInfo: [NSLocalizedDescriptionKey: "Export status: \(exportSession.status.rawValue)"])
        }

        progress(0.98)
        return .trim(LoopAnalysisResult(
            firstContentFrame: startFrame,
            matchFrame: endFrame,
            startTime: startTime,
            endTime: endTime
        ))
    }

    nonisolated private static func makeLoopAnalysisVideoOutput(for videoTrack: AVAssetTrack) -> AVAssetReaderTrackOutput {
        let output = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [
                // 循环点只比较亮度。直接读取解码器输出的 Y 平面，避免为每个 4K 帧做 BGRA 色彩转换。
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
        )
        output.alwaysCopiesSampleData = false
        return output
    }

    /// 读取视频首尾的小窗口，优先识别已经自然闭环的视频。
    /// 预检只用于跳过明显无需裁剪的文件，边界不确定时仍交给完整分析保证准确性。
    nonisolated private static func isAlreadySeamlessLoop(
        asset: AVAsset,
        videoTrack: AVAssetTrack,
        duration: CMTime
    ) async throws -> Bool {
        let durationSeconds = duration.seconds
        guard durationSeconds.isFinite, durationSeconds >= 1.0 else { return false }

        let frameRate = try await videoTrack.load(.nominalFrameRate)
        let fps = frameRate > 0 ? Double(frameRate) : 30
        // 读取更宽的首尾窗口：首段取最早有效帧，尾段取真正结束前的帧。
        // 之前只读 14 帧时，尾段实际比较的是“尾窗口的开头”，会漏掉真实循环边界。
        let windowDurationSeconds = min(max(0.75, 42.0 / fps), durationSeconds * 0.25)
        let windowDuration = CMTime(seconds: windowDurationSeconds, preferredTimescale: 600_000)
        let tailStart = CMTimeMaximum(.zero, CMTimeSubtract(duration, windowDuration))

        let firstFrames = Array(try readLoopSignatures(
            from: asset,
            videoTrack: videoTrack,
            timeRange: CMTimeRange(start: .zero, duration: windowDuration),
            maximumCount: 28
        ).filter { !$0.isPureBlack }.prefix(14))
        let lastFrames = Array(try readLoopSignatures(
            from: asset,
            videoTrack: videoTrack,
            timeRange: CMTimeRange(start: tailStart, duration: CMTimeSubtract(duration, tailStart)),
            maximumCount: 42
        ).filter { !$0.isPureBlack }.suffix(14))

        guard firstFrames.count >= 4, lastFrames.count >= 4 else { return false }

        let first = firstFrames[0]
        let next = firstFrames[1]
        let previousLast = lastFrames[lastFrames.count - 2]
        let last = lastFrames[lastFrames.count - 1]
        let boundaryDifference = last.difference(to: first)
        let incomingTransition = previousLast.difference(to: last)
        let outgoingTransition = first.difference(to: next)

        // 首尾画面需要接近，同时首尾运动幅度不能出现明显断层。
        let boundaryMatches = boundaryDifference.meanAbsoluteDifference <= 10
            && boundaryDifference.rootMeanSquareDifference <= 22
            && boundaryDifference.strongDifferenceRatio <= 0.08
        let transitionIsContinuous = abs(
            incomingTransition.meanAbsoluteDifference - outgoingTransition.meanAbsoluteDifference
        ) <= 8

        return boundaryMatches && transitionIsContinuous
    }

    nonisolated private static func readLoopSignatures(
        from asset: AVAsset,
        videoTrack: AVAssetTrack,
        timeRange: CMTimeRange,
        maximumCount: Int
    ) throws -> [FrameSignature] {
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = timeRange
        let output = makeLoopAnalysisVideoOutput(for: videoTrack)
        guard reader.canAdd(output) else {
            throw NSError(domain: "VideoLoop", code: 18, userInfo: [NSLocalizedDescriptionKey: "Unable to read loop preflight frames"])
        }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? NSError(domain: "VideoLoop", code: 19, userInfo: [NSLocalizedDescriptionKey: "Unable to start loop preflight reader"])
        }

        var signatures: [FrameSignature] = []
        signatures.reserveCapacity(maximumCount)
        while signatures.count < maximumCount,
              let sampleBuffer = output.copyNextSampleBuffer() {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }
            signatures.append(try FrameSignature(pixelBuffer: pixelBuffer))
        }
        if reader.status == .failed {
            throw reader.error ?? NSError(domain: "VideoLoop", code: 20, userInfo: [NSLocalizedDescriptionKey: "Loop preflight frame reading failed"])
        }
        if reader.status == .reading {
            reader.cancelReading()
        }
        return signatures
    }

    /// 全局扫描确定候选循环点后，在每个候选点前后各 20 帧里精修首尾边界。
    /// 首段使用首个有效帧后连续 20 帧，并与当前候选点周围的 40 帧逐一比对，最后使用所有候选点中误差最小的一对。
    /// 导出时采用 `[start, end)`，因此 end 匹配帧不会被包含，成片末帧自然是它的前一帧。
    nonisolated private static func refineLoopBoundary(
        in asset: AVAsset,
        videoTrack: AVAssetTrack,
        duration: CMTime,
        referenceFrames: [TimedFrameSignature],
        candidate: LoopCandidate
    ) async throws -> RefinedLoopBoundary? {
        let localFrameCount = min(20, referenceFrames.count)
        let starts = Array(referenceFrames.prefix(localFrameCount))
        guard starts.count >= 5 else { return nil }

        let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
        let framesPerSecond = nominalFrameRate > 0 ? Double(nominalFrameRate) : 30
        let frameDuration = CMTime(seconds: 1 / framesPerSecond, preferredTimescale: 600_000)
        let readerStart = CMTimeMaximum(
            .zero,
            CMTimeSubtract(candidate.time, CMTimeMultiply(frameDuration, multiplier: Int32(localFrameCount)))
        )
        let readerEnd = CMTimeMinimum(
            duration,
            CMTimeAdd(candidate.time, CMTimeMultiply(frameDuration, multiplier: Int32(localFrameCount + 1)))
        )
        guard CMTimeCompare(readerEnd, readerStart) > 0 else { return nil }

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(
            start: readerStart,
            duration: CMTimeSubtract(readerEnd, readerStart)
        )
        let output = makeLoopAnalysisVideoOutput(for: videoTrack)
        guard reader.canAdd(output) else {
            throw NSError(domain: "VideoLoop", code: 15, userInfo: [NSLocalizedDescriptionKey: "Unable to read loop refinement frames"])
        }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? NSError(domain: "VideoLoop", code: 16, userInfo: [NSLocalizedDescriptionKey: "Unable to start loop refinement reader"])
        }

        var candidateFrames: [TimedFrameSignature] = []
        while candidateFrames.count < localFrameCount * 2 + 1,
              let sampleBuffer = output.copyNextSampleBuffer() {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            candidateFrames.append(TimedFrameSignature(
                frame: candidate.frame - localFrameCount + candidateFrames.count,
                time: presentationTime,
                signature: try FrameSignature(pixelBuffer: pixelBuffer)
            ))
        }
        if reader.status == .failed {
            throw reader.error ?? NSError(domain: "VideoLoop", code: 17, userInfo: [NSLocalizedDescriptionKey: "Loop refinement frame reading failed"])
        }
        if reader.status == .reading {
            reader.cancelReading()
        }

        // 每个候选帧还用随后的五帧验证，避免偶然相似的单帧改变原本正确的循环相位。
        let validationFrameCount = 5
        var bestBoundary: RefinedLoopBoundary?
        var bestScore = Double.greatestFiniteMagnitude

        for startIndex in starts.indices {
            for endIndex in candidateFrames.indices {
                let availableFrames = min(starts.count - startIndex, candidateFrames.count - endIndex)
                guard availableFrames >= validationFrameCount else { continue }
                guard CMTimeCompare(candidateFrames[endIndex].time, starts[startIndex].time) > 0 else { continue }

                var difference = FrameWindowDifference()
                for offset in 0..<validationFrameCount {
                    difference.append(
                        starts[startIndex + offset].signature.difference(
                            to: candidateFrames[endIndex + offset].signature
                        )
                    )
                }
                guard difference.isReliableLoopMatch else { continue }

                // 同分时优先保留两个窗口中的相同相对帧序号，避免静态画面导致不必要的周期偏移。
                let phasePenalty = Double(abs(startIndex - endIndex)) * 0.015
                let score = difference.qualityScore + phasePenalty
                if score < bestScore {
                    bestScore = score
                    bestBoundary = RefinedLoopBoundary(
                        start: starts[startIndex],
                        end: candidateFrames[endIndex],
                        difference: difference
                    )
                }
            }
        }

        if let bestBoundary {
            print(
                "[VideoLoopPreprocessing] Candidate boundary refined: start=\(bestBoundary.start.frame) " +
                "(\(String(format: "%.3f", bestBoundary.start.time.seconds))s), end=\(bestBoundary.end.frame) " +
                "(\(String(format: "%.3f", bestBoundary.end.time.seconds))s), " +
                "MAE=\(String(format: "%.2f", bestBoundary.difference.meanAbsoluteDifference))"
            )
        }
        return bestBoundary
    }

    /// 连续窗口里的累计误差。这里使用亮度而不是 RGB，降低编码色彩噪声对匹配的影响。
    nonisolated private struct FrameWindowDifference: Sendable {
        private(set) var absoluteDifferenceTotal: Int = 0
        private(set) var squaredDifferenceTotal: Int = 0
        private(set) var strongDifferenceCount: Int = 0
        private(set) var sampleCount: Int = 0

        init() {}

        init(_ difference: FrameDifference) {
            append(difference)
        }

        mutating func append(_ difference: FrameDifference) {
            absoluteDifferenceTotal += difference.absoluteDifferenceTotal
            squaredDifferenceTotal += difference.squaredDifferenceTotal
            strongDifferenceCount += difference.strongDifferenceCount
            sampleCount += difference.sampleCount
        }

        var meanAbsoluteDifference: Double {
            Double(absoluteDifferenceTotal) / Double(max(1, sampleCount))
        }

        var rootMeanSquareDifference: Double {
            sqrt(Double(squaredDifferenceTotal) / Double(max(1, sampleCount)))
        }

        var strongDifferenceRatio: Double {
            Double(strongDifferenceCount) / Double(max(1, sampleCount))
        }

        /// 阈值按 H.264/HEVC 解码后的低分辨率亮度特征标定；
        /// 必须同时满足平均误差、峰值误差分布和 12 帧连续相位验证。
        var isReliableLoopMatch: Bool {
            meanAbsoluteDifference <= 7
                && rootMeanSquareDifference <= 16
                && strongDifferenceRatio <= 0.05
        }

        var qualityScore: Double {
            meanAbsoluteDifference / 7
                + rootMeanSquareDifference / 16
                + strongDifferenceRatio / 0.05
        }
    }

    nonisolated private struct FrameDifference: Sendable {
        let absoluteDifferenceTotal: Int
        let squaredDifferenceTotal: Int
        let strongDifferenceCount: Int
        let sampleCount: Int

        var meanAbsoluteDifference: Double {
            Double(absoluteDifferenceTotal) / Double(max(1, sampleCount))
        }

        var rootMeanSquareDifference: Double {
            sqrt(Double(squaredDifferenceTotal) / Double(max(1, sampleCount)))
        }

        var strongDifferenceRatio: Double {
            Double(strongDifferenceCount) / Double(max(1, sampleCount))
        }

        /// 单帧只作为候选预筛，不用于最终裁剪决策；阈值刻意宽于连续窗口验证。
        var isPotentialLoopMatch: Bool {
            meanAbsoluteDifference <= 11
                && rootMeanSquareDifference <= 28
                && strongDifferenceRatio <= 0.12
        }
    }

    nonisolated private struct PendingLoopCandidate: Sendable {
        let frame: Int
        let time: CMTime
        private(set) var comparedFrameCount: Int = 1
        private(set) var difference: FrameWindowDifference

        init(frame: Int, time: CMTime, firstDifference: FrameDifference) {
            self.frame = frame
            self.time = time
            self.difference = FrameWindowDifference(firstDifference)
        }

        mutating func append(_ signature: FrameSignature, reference: FrameSignature) {
            difference.append(signature.difference(to: reference))
            comparedFrameCount += 1
        }

        func completed() -> LoopCandidate {
            LoopCandidate(frame: frame, time: time, difference: difference)
        }
    }

    nonisolated private struct LoopCandidate: Sendable {
        let frame: Int
        let time: CMTime
        let difference: FrameWindowDifference
    }

    /// 同一个循环点附近会出现多帧候选；先把它们聚成簇并取簇内最佳相位，
    /// 再选择视频中最后一个可靠簇，避免“越靠后越差的相邻帧”破坏循环衔接。
    nonisolated private static func selectLastReliableCandidate(from candidates: [LoopCandidate]) -> LoopCandidate? {
        guard !candidates.isEmpty else { return nil }

        let clusterGap: Double = 0.75
        var clusters: [[LoopCandidate]] = []
        var currentCluster: [LoopCandidate] = []

        for candidate in candidates {
            if let previous = currentCluster.last,
               CMTimeGetSeconds(CMTimeSubtract(candidate.time, previous.time)) > clusterGap {
                clusters.append(currentCluster)
                currentCluster = [candidate]
            } else {
                currentCluster.append(candidate)
            }
        }
        if !currentCluster.isEmpty {
            clusters.append(currentCluster)
        }

        return clusters.last?.min { lhs, rhs in
            lhs.difference.qualityScore < rhs.difference.qualityScore
        }
    }

    nonisolated private struct FrameSignature: Sendable {
        let luma: [UInt8]
        let averageLuma: Double

        init(pixelBuffer: CVPixelBuffer) throws {
            CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

            let sampleWidth = 96
            let sampleHeight = 54
            var sampledLuma = [UInt8]()
            sampledLuma.reserveCapacity(sampleWidth * sampleHeight)
            var sum = 0

            let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
            switch pixelFormat {
            case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                 kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
                let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
                let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
                guard width > 0,
                      height > 0,
                      let baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
                    throw NSError(domain: "VideoLoop", code: 13, userInfo: [NSLocalizedDescriptionKey: "Invalid YUV video frame"])
                }
                let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
                let source = baseAddress.assumingMemoryBound(to: UInt8.self)
                for sampleY in 0..<sampleHeight {
                    let sourceY = min(height - 1, (sampleY * height + sampleHeight / 2) / sampleHeight)
                    let row = source.advanced(by: sourceY * bytesPerRow)
                    for sampleX in 0..<sampleWidth {
                        let sourceX = min(width - 1, (sampleX * width + sampleWidth / 2) / sampleWidth)
                        let value = row[sourceX]
                        sampledLuma.append(value)
                        sum += Int(value)
                    }
                }
            case kCVPixelFormatType_32BGRA:
                // 解码器无法交付 YUV 时保留 BGRA 回退，保证特殊编码视频仍可分析。
                let width = CVPixelBufferGetWidth(pixelBuffer)
                let height = CVPixelBufferGetHeight(pixelBuffer)
                guard width > 0,
                      height > 0,
                      let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
                    throw NSError(domain: "VideoLoop", code: 14, userInfo: [NSLocalizedDescriptionKey: "Unable to access BGRA video frame"])
                }
                let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
                let source = baseAddress.assumingMemoryBound(to: UInt8.self)
                for sampleY in 0..<sampleHeight {
                    let sourceY = min(height - 1, (sampleY * height + sampleHeight / 2) / sampleHeight)
                    let row = source.advanced(by: sourceY * bytesPerRow)
                    for sampleX in 0..<sampleWidth {
                        let sourceX = min(width - 1, (sampleX * width + sampleWidth / 2) / sampleWidth)
                        let pixel = row.advanced(by: sourceX * 4)
                        let value = UInt8((77 * Int(pixel[2]) + 150 * Int(pixel[1]) + 29 * Int(pixel[0]) + 128) >> 8)
                        sampledLuma.append(value)
                        sum += Int(value)
                    }
                }
            default:
                throw NSError(
                    domain: "VideoLoop",
                    code: 9,
                    userInfo: [NSLocalizedDescriptionKey: "Unsupported video pixel format: \(pixelFormat)"]
                )
            }
            luma = sampledLuma
            averageLuma = Double(sum) / Double(max(1, sampledLuma.count))
        }

        var isPureBlack: Bool {
            averageLuma <= 3
        }

        func difference(to other: FrameSignature) -> FrameDifference {
            guard luma.count == other.luma.count else {
                return FrameDifference(
                    absoluteDifferenceTotal: .max / 4,
                    squaredDifferenceTotal: .max / 4,
                    strongDifferenceCount: .max / 4,
                    sampleCount: 1
                )
            }

            var absoluteDifferenceTotal = 0
            var squaredDifferenceTotal = 0
            var strongDifferenceCount = 0
            for index in luma.indices {
                let delta = abs(Int(luma[index]) - Int(other.luma[index]))
                absoluteDifferenceTotal += delta
                squaredDifferenceTotal += delta * delta
                if delta > 36 {
                    strongDifferenceCount += 1
                }
            }
            return FrameDifference(
                absoluteDifferenceTotal: absoluteDifferenceTotal,
                squaredDifferenceTotal: squaredDifferenceTotal,
                strongDifferenceCount: strongDifferenceCount,
                sampleCount: luma.count
            )
        }

        /// 首尾画面非常接近但没有可裁的重复帧：保留视频并标记为天然循环。
        func isLoopBoundarySimilar(to other: FrameSignature) -> Bool {
            let difference = difference(to: other)
            return difference.meanAbsoluteDifference <= 7
                && difference.rootMeanSquareDifference <= 16
                && difference.strongDifferenceRatio <= 0.05
        }
    }
}
