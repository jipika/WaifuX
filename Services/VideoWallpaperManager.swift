import Foundation
import AppKit
import AVFoundation
import CryptoKit
import CoreGraphics
import QuartzCore
import CoreAudio
import Vision

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

@MainActor
final class VideoWallpaperManager: ObservableObject {
    static let shared = VideoWallpaperManager()
    static let externalVideoRendererDefaultsKey = "external_video_renderer_enabled"

    // MARK: - 子进程渲染开关（P1：验证 Screen Time 隔离）
    //
    // 开启时，视频壁纸渲染走独立子进程 wallpaper-video-renderer，
    // 主进程不再持有可见窗口，从而不被 Screen Time 计入使用时长。
    // 关闭时，走原有的主进程内渲染路径（VideoWallpaperManager.createWindow 等）。
    // 默认使用主进程内置播放器；用户可在设置中切换到独立子进程。
    private(set) var useExternalVideoRenderer: Bool =
        UserDefaults.standard.object(forKey: externalVideoRendererDefaultsKey) as? Bool ?? false

    /// 子进程控制器（仅 useExternalVideoRenderer=true 时使用）
    private let externalRenderer = VideoRendererProcessController.shared

    /// 是否正在通过子进程渲染（用于区分"无壁纸"与"子进程渲染中"）
    private var externalRenderingActive = false
    /// 只读诊断访问器（状态栏路由打点用）
    var externalRenderingActiveForDiagnostics: Bool { externalRenderingActive }
    /// External renderer 的暂停状态不依赖主进程 AVPlayer。
    private var externalPausedScreenIDs = Set<String>()
    /// 首帧事件对应的物理屏幕 ID。external renderer 的 `set` 返回 OK
    /// 只代表播放器/窗口已创建，跨类型交接必须等这里确认后才能拆旧内容。
    private var externalFirstFrameReadyScreenIDs = Set<String>()
    /// 每屏当前有效的 renderer 请求。迟到的旧首帧/结束事件必须被丢弃。
    private var externalRequestIDByScreenID: [String: String] = [:]
    /// 已至少提交过一帧的 external 视频屏。正在后方预热的新窗口不能被当作旧内容置顶。
    private var externalPresentedScreenIDs = Set<String>()
    /// 子进程已为该屏建过桌面窗。视频→视频交接只看这个集合，不要求首帧已到。
    private var externalOwnedScreenIDs = Set<String>()
    /// 该屏已经有可保的旧视频画面：要么首帧已提交，要么子进程窗还在。
    private var externalLiveVideoScreenIDs: Set<String> {
        externalPresentedScreenIDs.union(externalOwnedScreenIDs)
    }
    private var externalCropRevisionByScreenID: [String: UInt64] = [:]
    /// 屏幕仍在等待主进程提交跨类型/视频交叉淡入；提交前不能触发菜单栏条带暴露。
    private var externalPendingCommitScreenIDs = Set<String>()
    /// 共享解码首帧超时后已降级为独立解码重试过的屏。每次 apply 重置，防死循环。
    private var externalFallbackAttemptedScreenIDs = Set<String>()
    /// 取消过期的 Scene/Web -> video 交接任务。
    private var externalTransitionGeneration: UInt64 = 0
    private var externalRendererRestartAttempt = 0
    private var externalRendererRestartWorkItem: DispatchWorkItem?
    /// IPC 改为 async 后，连续的 set / 显示器重连可能在等待 socket 回包时交错，
    /// 从而覆盖彼此的 per-screen 映射。只串行实际修改 renderer 状态的短事务；
    /// 首帧交接仍由独立任务等待，不持有这个门。
    private var externalRendererTransactionActive = false
    private var externalRendererTransactionWaiters: [CheckedContinuation<Void, Never>] = []
    /// 事务代际：watchdog 强制释放或卡死持有者晚到释放时递增，防止误放新事务。
    private var externalRendererTransactionEpoch: UInt64 = 0

    /// 切换视频渲染后端，并重建当前视频壁纸。
    /// 设置变化发生在运行中时，先保存每屏视频映射，再停掉旧路径，最后逐屏恢复。
    func setExternalVideoRendererEnabled(_ enabled: Bool) {
        guard useExternalVideoRenderer != enabled else { return }

        useExternalVideoRenderer = enabled
        UserDefaults.standard.set(enabled, forKey: Self.externalVideoRendererDefaultsKey)

        guard hasActiveVideoWallpaper else {
            if !enabled, externalRenderer.isRunning {
                externalRenderer.stopDaemon()
            }
            externalRenderingActive = false
            return
        }

        let targetScreens = screensForVideoWallpaperTargets()
        let snapshots = targetScreens.compactMap { screen -> (
            screen: NSScreen,
            videoURL: URL,
            posterURL: URL?,
            muted: Bool
        )? in
            guard let videoURL = videoURL(for: screen),
                  FileManager.default.fileExists(atPath: videoURL.path) else {
                return nil
            }
            return (
                screen: screen,
                videoURL: videoURL,
                posterURL: posterURL(for: screen),
                muted: isMuted
            )
        }
        let wasPaused = isPaused

        // stopWallpaper clears the old renderer state and leaves the selected
        // source files available in this local snapshot for reapplication.
        stopWallpaper()

        Task { @MainActor [weak self] in
            guard let self else { return }
            for snapshot in snapshots {
                do {
                    try await self.applyVideoWallpaper(
                        from: snapshot.videoURL,
                        posterURL: snapshot.posterURL,
                        muted: snapshot.muted,
                        targetScreen: snapshot.screen,
                        animatedTransition: false,
                        usesSharedVideoDecoder: false,
                        forceRebuild: true
                    )
                } catch {
                    AppLogger.error(.wallpaper, "切换视频渲染后端时恢复壁纸失败", metadata: [
                        "screen": snapshot.screen.localizedName,
                        "video": snapshot.videoURL.lastPathComponent,
                        "enabled": enabled,
                        "error": error.localizedDescription
                    ])
                }
            }
            if wasPaused, self.hasActiveVideoWallpaper {
                self.pauseWallpaper()
            }
        }
    }

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
    /// 仅状态栏「暂停动态壁纸」会置位。前台遮挡/全屏/电池等自动暂停不得写入此标记，
    /// 否则长期遮挡后的 persist/restore 会把自动暂停当成用户暂停，再也无法自动恢复。
    private var userRequestedPause = false
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
    /// 本地 poster 同步缓存（fileURL path → image），播完即换时必须立刻盖住结束帧，不能等 URLSession。
    private var posterImageCache: [String: NSImage] = [:]
    /// 每个屏幕的独立音量（key 为 screenID），未设置时回退到全局 `volume`
    private var volumeByScreen: [String: Double] = [:]
    /// 音量的物理显示器指纹索引，用于 screenID 变化后的恢复。
    private var volumeByScreenFingerprint: [String: Double] = [:]

    private var windows: [String: WallpaperVideoWindow] = [:]
    private var players: [String: AVQueuePlayer] = [:]
    private var loopers: [String: AVPlayerLooper] = [:]
    /// Explicit global multi-display sync: one AVQueuePlayer for all target screens.
    /// Opportunistic same-file sharing across a subset of screens also reuses player
    /// instances via `findReusablePlayerComponents` without requiring this flag.
    private var usesSharedVideoDecoder = false
    private var sharedVideoPlayer: AVQueuePlayer?
    private var sharedVideoLooper: AVPlayerLooper?
    private var sharedVideoItem: AVPlayerItem?
    /// 解码管线的不可变文件锚点。不能用 `currentVideoURL` 判断 player 归属：
    /// 单屏切换会在新 player 创建前更新全局 URL，从而把旧共享管线误认成新文件。
    /// 一个 player 从创建到释放始终锚定同一个物理文件；屏幕引用由 `players` 映射管理。
    private var anchoredVideoPathByPlayerID: [ObjectIdentifier: String] = [:]
    /// AVPlayerLooper 可能在下一个 run loop 才把 template item 复制进队列。
    /// 保留每条管线的源 item，让另一块同时创建的屏幕即使在
    /// `currentItem == nil` 的窗口期也能立即复用这条解码管线。
    private var sourceVideoItemByPlayerID: [ObjectIdentifier: AVPlayerItem] = [:]
    /// 同一文件同时创建多屏时，其它屏幕不立即挂到尚未起播的
    /// 共享 player。等领头屏首帧后已经连续播放，再逐屏附加。
    private var pendingSharedFollowerScreenIDsByPlayerID: [ObjectIdentifier: Set<String>] = [:]
    private var sharedFollowerAttachmentTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    /// 全局同源视频切换采用双代管线：旧共享 player 保持可见，新共享 player
    /// 在每屏隐藏 layer 中预热；所有 layer 都有首帧后再统一交叉淡入。
    private var globalTransitionGeneration: UInt64 = 0
    private var globalTransitionObservers: [NSKeyValueObservation] = []
    private var globalTransitionTimeout: DispatchWorkItem?
    private var globalTransitionReadyScreenIDs = Set<String>()
    private var globalTransitionDidBeginCommit = false
    private var globalTransitionPendingCompletionScreenIDs = Set<String>()
    private var pendingGlobalTransitionPlayer: AVQueuePlayer?
    private var pendingGlobalTransitionLooper: AVPlayerLooper?
    /// 单屏异步交接期间，旧 player 已从 `players` 映射摘除但仍是主层可见画面。
    /// 显式保活，防止 rebuild 末尾的 orphan 清扫提前把旧画面断开。
    private var transitionRetainedPlayers: [ObjectIdentifier: AVQueuePlayer] = [:]
    private var transitionRetainedPlayerOwners: [ObjectIdentifier: Set<String>] = [:]
    private struct ScreenTransitionSourceRollback {
        let videoURL: URL
        let posterURL: URL?
        let fingerprint: String
    }
    private var screenTransitionSourceRollbacks: [String: ScreenTransitionSourceRollback] = [:]
    /// Scene/Web/独立静态图 → 视频：旧内容保留到新 AVPlayerLayer 首帧可显示。
    private var pendingCrossTypeVideoScreenIDs = Set<String>()
    /// 只有已经完成首帧提交的窗口才是“可保留的旧视频”。正在后方预热的窗口
    /// 不能被下一次 Scene/Web 切换提到前台，否则其黑色 freeze layer 会形成长黑场。
    private var presentedVideoScreenIDs = Set<String>()
    private struct GlobalTransitionSourceRollback {
        let currentVideoURL: URL?
        let currentPosterURL: URL?
        let videoURLByScreen: [String: URL]
        let videoURLByScreenFingerprint: [String: URL]
        let posterURLByScreen: [String: URL]
        let posterURLByScreenFingerprint: [String: URL]
    }
    private var globalTransitionSourceRollback: GlobalTransitionSourceRollback?
    private struct ExternalTransitionSourceRollback {
        let currentVideoURL: URL?
        let currentPosterURL: URL?
        let isMuted: Bool
        let isPaused: Bool
        let usesSharedVideoDecoder: Bool
        let externalRenderingActive: Bool
        let videoURLByScreen: [String: URL]
        let videoURLByScreenFingerprint: [String: URL]
        let posterURLByScreen: [String: URL]
        let posterURLByScreenFingerprint: [String: URL]
        let videoTargetScreenIDs: Set<String>
        let videoTargetScreenFingerprints: Set<String>
        let externalPausedScreenIDs: Set<String>
        let externalRequestIDByScreenID: [String: String]
        let externalPresentedScreenIDs: Set<String>
        let externalOwnedScreenIDs: Set<String>
        let externalFirstFrameReadyScreenIDs: Set<String>
        let externalPendingCommitScreenIDs: Set<String>
        let externalCropRevisionByScreenID: [String: UInt64]
        let videoSizes: [String: CGSize]
        let videoLetterboxContentCrops: [String: VideoLetterboxCrop]
        let frameInterpolationDecisionsByScreen: [String: VideoFrameInterpolationDecision]
        let frameInterpolatedPlaybackURLByScreen: [String: URL]
    }
    /// 每屏视频真实尺寸缓存（naturalSize），供 crop 计算用。设置壁纸时填充。
    private var videoSizes: [String: CGSize] = [:]
    /// 每屏视频源文件自带黑边的内容裁切框。只在全屏自动铺满模式下叠加。
    private var videoLetterboxContentCrops: [String: VideoLetterboxCrop] = [:]
    private var videoLetterboxAnalysisTasks: [String: Task<VideoLetterboxCrop?, Never>] = [:]
    private var videoLetterboxAnalysisRevisionByScreen: [String: String] = [:]
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

    /// 同步给 web daemon（wallpaperengine-cli）的热更新控制文件路径。
    /// daemon 长驻进程读此文件，避免仅依赖启动时 env。
    static let systemWallpaperSyncControlPath = "/tmp/waifux-system-wallpaper-sync.json"

    /// 把当前「系统壁纸同步」状态写到控制文件，供 web daemon 即时遵守。
    func publishSystemWallpaperSyncControlToWebDaemon() {
        let enabled = isSystemWallpaperSyncEnabled
        let payload: [String: Any] = [
            "enabled": enabled,
            "updatedAt": Date().timeIntervalSince1970,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) else { return }
        try? data.write(to: URL(fileURLWithPath: Self.systemWallpaperSyncControlPath), options: .atomic)
        print("[VideoWallpaperManager] 🧊 已发布系统壁纸同步状态到 web daemon: enabled=\(enabled)")
    }

    private var autoRemoveVideoLetterboxEnabled: Bool {
        UserDefaults.standard.object(forKey: "auto_remove_video_letterbox") as? Bool ?? false
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
    /// 外置盘视频缓冲：慢速外置盘 IO 带宽有限，需要更大的前向缓冲防止 stall。
    private let externalVolumeVideoForwardBufferDuration: TimeInterval = 12.0
    /// 外置盘大文件（>1GB）缓冲：在大缓冲基础上再上调，应对 4K 120Hz 高码率。
    private let externalVolumeLargeVideoForwardBufferDuration: TimeInterval = 20.0
    /// 机会式共享解码的最大屏幕数上限。
    /// 超过此数时为新屏创建独立 player，避免单 player 驱动多块高刷屏时 VSync 对齐压力导致卡顿。
    /// 显式全局同步（usesSharedVideoDecoder）路径不受此限制，尊重用户主动选择。
    private let maxOpportunisticShareScreenCount = 2
    private let automaticSwitchTransitionDuration: TimeInterval = 0.28
    private let automaticSwitchReadyTimeout: TimeInterval = 1.2
    /// 自动切换时 poster 写入系统桌面的短延迟。
    /// 视频窗已覆盖桌面，无需等 2s；过长会让「动态壁纸静帧」体感极慢。
    /// 仅保留极短 settle，避免切换瞬间 setDesktopImage 与窗口重建抢同一时刻。
    private let deferredPosterSyncDelay: TimeInterval = 0.35
    private let displaySwitchStableDelay: TimeInterval = 1.0
    private let displaySwitchTimeout: TimeInterval = 8.0

    /// 桌面层 NSWindow / CALayer 隐式动画在 App 非活跃时经常不推进，
    /// 表现就是「自动切换已经 apply 了，但画面要点一下 / 锁屏 / 开设置才更新」。
    /// 前台可做淡入；后台/未激活时必须瞬时提交。
    private static var shouldAnimateDesktopPresentation: Bool {
        NSApp.isActive && NSApp.isRunning
    }

    /// 立刻把桌面壁纸窗提到可见态（无 animator），并强制 flush 合成。
    private static func revealDesktopWallpaperWindow(_ window: NSWindow) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // alpha 固定 0.99999（近乎不透明）+ isOpaque=false：窗口按半透明层合成，
        // 必须与壁纸层混合 → 壁纸层不被视频层遮挡挂起 → 菜单栏 backdrop
        // 懒采样能采到新 poster（alpha=1 时壁纸层被挂起，菜单栏永不更新，
        // 实测验证）。0.99999 与 1 视觉无差别。
        window.alphaValue = 0.99999
        // desktop 层不能只 orderBack：菜单栏/非 key 时 WindowServer 可能推迟合帧，
        // 表现为“逻辑上已切换，要点一下别的 App 画面才更新”。
        window.orderFrontRegardless()
        window.orderBack(nil)
        window.displayIfNeeded()
        if let view = window.contentView {
            view.needsDisplay = true
            view.layer?.setNeedsDisplay()
            view.displayIfNeeded()
            if let playerLayer = (view as? WallpaperVideoContainerView)?.playerLayer {
                playerLayer.setNeedsDisplay()
            }
        }
        CATransaction.commit()
        CATransaction.flush()
        // 再跑一圈 runloop，让桌面层在后台 timer 触发路径上也能立刻合帧。
        CFRunLoopWakeUp(CFRunLoopGetMain())
        // 注意：不要在这里触发任何菜单栏刷新。reveal 会被 forceCommit / 首帧 /
        // 重排频繁调用；菜单栏 backdrop 采样依赖窗口 alpha=0.99999 半透明（壁纸层
        // 不被视频层挂起）+ poster 写入后的系统懒重采样（~10s）。
    }

    /// 新建窗口首帧就绪后的呈现。
    /// 桌面层 NSWindow 的 animator 在 App 非 key / 菜单栏路径上经常不推进，
    /// 会造成“已经 apply 了，要点一下其它软件才变”。统一瞬时提交。
    private func presentDesktopWallpaperWindow(_ window: NSWindow, animated: Bool) {
        _ = animated
        Self.revealDesktopWallpaperWindow(window)
    }

    /// 状态栏/菜单栏切换后强制把已有桌面视频窗重新提交给 WindowServer。
    /// 菜单 tracking 结束后合帧常被推迟，表现为“逻辑已切，桌面仍是旧采样，要点一下才变”。
    func forceCommitDesktopPresentation(on screens: [NSScreen]? = nil) {
        let targets: [NSScreen]
        if let screens, !screens.isEmpty {
            targets = screens
        } else {
            targets = NSScreen.screens
        }

        if externalRenderingActive {
            for screen in targets {
                let screenID = screen.wallpaperScreenIdentifier
                if externalPendingCommitScreenIDs.contains(screenID) {
                    continue
                }
                guard let screenIndex = externalScreenIndex(for: screen) else { continue }
                externalRenderer.sendCommandFireAndForget(
                    .forceCommit(screen: screenIndex)
                )
            }
            StaticImageWallpaperOverlayManager.shared.keepPresentationFront(on: targets)
            CATransaction.flush()
            CFRunLoopWakeUp(CFRunLoopGetMain())
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for screen in targets {
            let screenID = screen.wallpaperScreenIdentifier
            if let entry = existingVideoWindowEntry(for: screen) {
                synchronizeWindow(entry.window, to: screen)
                Self.revealDesktopWallpaperWindow(entry.window)
                if let container = entry.window.contentView as? WallpaperVideoContainerView,
                   let player = players[entry.screenID] ?? players[screenID] {
                    // 再踢一次 layer 绑定，避免菜单栏路径上 AVPlayerLayer 停在旧帧。
                    if container.playerLayer.player !== player {
                        container.attachPlayer(player)
                    }
                    if !isPaused, player.rate == 0 {
                        player.play()
                    }
                    container.playerLayer.setNeedsDisplay()
                    container.needsDisplay = true
                    container.displayIfNeeded()
                }
                presentedVideoScreenIDs.insert(entry.screenID)
                presentedVideoScreenIDs.insert(screenID)
            }
            StaticImageWallpaperOverlayManager.shared.keepPresentationFront(on: [screen])
        }
        CATransaction.commit()
        CATransaction.flush()
        CFRunLoopWakeUp(CFRunLoopGetMain())

        // 菜单关闭后再提交一次：tracking mode 退出后 WindowServer 才肯刷新 desktop 层。
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for screen in targets {
                if let entry = self.existingVideoWindowEntry(for: screen) {
                    Self.revealDesktopWallpaperWindow(entry.window)
                }
            }
            StaticImageWallpaperOverlayManager.shared.keepPresentationFront(on: targets)
            CATransaction.flush()
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            for screen in targets {
                if let entry = self.existingVideoWindowEntry(for: screen) {
                    Self.revealDesktopWallpaperWindow(entry.window)
                    if let player = self.players[entry.screenID], !self.isPaused, player.rate == 0 {
                        player.play()
                    }
                }
            }
            CATransaction.flush()
        }
    }

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

    /// 仅更新指定屏幕的静态 poster（不重建播放器）。
    /// 用于调度器先切换视频、后台补齐封面后写回系统桌面底图。
    func updatePosterURL(
        _ posterURL: URL,
        for screen: NSScreen,
        expectedVideoURL: URL? = nil
    ) {
        if let expectedVideoURL {
            guard videoURL(for: screen)?.standardizedFileURL == expectedVideoURL.standardizedFileURL else {
                return
            }
        }
        let screenID = screen.wallpaperScreenIdentifier
        posterURLByScreen[screenID] = posterURL
        posterURLByScreenFingerprint[screen.wallpaperScreenFingerprint] = posterURL
        currentPosterURL = posterURL
        _ = loadPosterImageSync(from: posterURL)
        if posterURL.isFileURL {
            applyPosterAsDesktopWallpaperSync(posterURL, targetScreen: screen)
        } else {
            setPosterAsDesktopWallpaper(posterURL, targetScreen: screen)
        }
        syncExternalPosterPath(for: screen, posterURL: posterURL)
        persistState()
    }

    private func syncExternalPosterPath(for screen: NSScreen, posterURL: URL?) {
        guard externalRenderingActive,
              let screenIndex = externalScreenIndex(for: screen) else {
            return
        }

        if let posterURL, posterURL.isFileURL {
            externalRenderer.sendCommandFireAndForget(
                .updatePoster(screen: screenIndex, path: posterURL.path)
            )
            return
        }

        guard let posterURL else {
            externalRenderer.sendCommandFireAndForget(
                .updatePoster(screen: screenIndex, path: nil)
            )
            return
        }

        let expectedScreenID = screen.wallpaperScreenIdentifier
        Task { @MainActor [weak self] in
            guard let self,
                  let localURL = await self.materializeExternalPoster(
                      posterURL,
                      screenID: expectedScreenID
                  ),
                  self.externalRenderingActive,
                  let currentScreen = NSScreen.screens.first(where: {
                      $0.wallpaperScreenIdentifier == expectedScreenID
                  }),
                  self.posterURL(for: currentScreen)?.standardizedFileURL == posterURL.standardizedFileURL,
                  let screenIndex = self.externalScreenIndex(for: currentScreen) else {
                return
            }
            self.externalRenderer.sendCommandFireAndForget(
                .updatePoster(screen: screenIndex, path: localURL.path)
            )
        }
    }

    private func materializeExternalPoster(
        _ url: URL,
        screenID: String
    ) async -> URL? {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let cacheKey = digest.map { String(format: "%02x", $0) }.joined()
        let cacheName = "renderer_poster_\(cacheKey).jpg"
        let destination = persistedPosterDirectory.appendingPathComponent(cacheName)
        if FileManager.default.fileExists(atPath: destination.path) {
            return destination
        }
        guard let image = await loadPosterImage(from: url),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(
                  using: .jpeg,
                  properties: [.compressionFactor: 0.92]
              ) else {
            AppLogger.error(.wallpaper, "外部视频 poster 素材化失败", metadata: [
                "screenID": screenID,
                "url": url.absoluteString
            ])
            return nil
        }
        do {
            try data.write(to: destination, options: .atomic)
            return destination
        } catch {
            AppLogger.error(.wallpaper, "外部视频 poster 写入失败", metadata: [
                "screenID": screenID,
                "error": error.localizedDescription
            ])
            return nil
        }
    }

    /// 返回明确分配给指定屏幕的视频，不回退到旧的全局状态。
    ///
    /// 用于需要严格按屏聚合状态的调用方，避免某一屏的视频被误判到其它屏幕。
    func assignedVideoURL(for screen: NSScreen) -> URL? {
        videoURLByScreen[screen.wallpaperScreenIdentifier] ??
        videoURLByScreenFingerprint[screen.wallpaperScreenFingerprint]
    }

    /// 获取指定屏幕应播放的视频 URL。
    /// 保留 `currentVideoURL` 回退以兼容尚未迁移到每屏状态的旧调用方。
    func videoURL(for screen: NSScreen) -> URL? {
        assignedVideoURL(for: screen) ?? currentVideoURL
    }

    /// 外接屏重连时按物理指纹恢复之前分配给这块屏的视频壁纸。
    func restorePreviousVideoWallpaperIfAvailable(for screen: NSScreen) async -> Bool {
        let screenID = screen.wallpaperScreenIdentifier
        let fingerprint = screen.wallpaperScreenFingerprint
        let hasPreviousState = videoTargetScreenIDs.contains(screenID)
            || videoTargetScreenFingerprints.contains(fingerprint)
            || videoURLByScreen[screenID] != nil
            || videoURLByScreenFingerprint[fingerprint] != nil
        guard hasPreviousState else { return false }

        relinkDisplayStateForCurrentScreens()
        videoTargetScreenIDs.insert(screenID)
        videoTargetScreenFingerprints.insert(fingerprint)

        guard videoURLByScreen[screenID] != nil
            || videoURLByScreenFingerprint[fingerprint] != nil
            || currentVideoURL != nil else {
            return false
        }

        do {
            if useExternalVideoRenderer {
                guard let videoURL = videoURL(for: screen) else { return false }
                try await applyVideoWallpaperViaExternalRenderer(
                    from: videoURL,
                    posterURL: posterURL(for: screen),
                    muted: isMuted,
                    targetScreen: screen,
                    usesSharedVideoDecoder: usesSharedVideoDecoder,
                    animatedTransition: false,
                    forceRebuild: false
                )
            } else {
                try rebuildWindows(targetScreen: screen)
            }
            persistState()
            print("[VideoWallpaperManager] Restored previous video wallpaper for reconnected display: \(screen.localizedName)")
            return true
        } catch {
            print("[VideoWallpaperManager] Failed to restore previous video wallpaper for \(screen.localizedName): \(error.localizedDescription)")
            return false
        }
    }

    /// Drops only the disconnected display's persisted association. This must not
    /// stop players or alter mappings for any remaining display.
    func discardPersistedWallpaperState(screenID: String, fingerprint: String) {
        videoTargetScreenIDs.remove(screenID)
        videoTargetScreenFingerprints.remove(fingerprint)
        videoURLByScreen.removeValue(forKey: screenID)
        videoURLByScreenFingerprint.removeValue(forKey: fingerprint)
        posterURLByScreen.removeValue(forKey: screenID)
        posterURLByScreenFingerprint.removeValue(forKey: fingerprint)
        volumeByScreen.removeValue(forKey: screenID)
        volumeByScreenFingerprint.removeValue(forKey: fingerprint)
        onEndModeScreens.remove(screenID)
        syncCurrentVideoURL()
        currentPosterURL = posterURLByScreen.values.first ?? posterURLByScreenFingerprint.values.first
        persistState()
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
    private var externalWakeRecoveryTask: Task<Void, Never>?
    private var externalWakeRecoveryGeneration: UInt64 = 0
    private var externalPlaybackSuspendedAt: Date?
    private var externalWakeNeedsDisplayReconfigure = false
    private var externalWakeNeedsPipelineRecovery = false
    private var lastAppliedScreenConfigurations: [ScreenConfigurationSignature] = []
    /// Pause/resume commands used to be fire-and-forget. A rapid "pause, then
    /// next" could let the old pause arrive after the next renderer `set`,
    /// freezing the incoming pipeline before it produced a drawable.
    private var externalPlaybackControlTask: Task<Void, Never>?
    private var externalPlaybackControlGeneration: UInt64 = 0

    private init() {
        // 恢复静音偏好（独立于视频壁纸状态，场景/Web 壁纸同样生效）
        if UserDefaults.standard.object(forKey: "wallpaper_is_muted") != nil {
            isMuted = UserDefaults.standard.bool(forKey: "wallpaper_is_muted")
        }
        externalRenderer.eventHandler = { [weak self] event in
            self?.handleExternalRendererEvent(event)
        }
        // 尽早建立锁屏/睡眠状态源，确保 helper 晚启动时能从共享文件读到
        // 当前状态，而不是在首次 set 时短暂误播。
        _ = LockScreenWallpaperService.shared
        setupNotificationObservers()
        configureAudioSession()
    }

    private func handleExternalRendererEvent(_ event: VideoRendererEvent) {
        switch event {
        case .ready:
            externalRendererRestartAttempt = 0
            externalRendererRestartWorkItem?.cancel()
            externalRendererRestartWorkItem = nil
        case .windowCreated(_, let stableScreenID, let requestID):
            if let screen = externalScreen(
                for: -1,
                stableScreenID: stableScreenID
            ) {
                let screenID = screen.wallpaperScreenIdentifier
                if requestID == nil || externalRequestIDByScreenID[screenID] == requestID {
                    rememberExternalOwnedScreen(screen)
                }
            } else if let stableScreenID {
                externalOwnedScreenIDs.insert(stableScreenID)
            }
        case .stopped(_, let stableScreenID, _):
            if let screen = externalScreen(
                for: -1,
                stableScreenID: stableScreenID
            ) {
                let screenID = screen.wallpaperScreenIdentifier
                externalOwnedScreenIDs.remove(screenID)
                externalPresentedScreenIDs.remove(screenID)
                externalFirstFrameReadyScreenIDs.remove(screenID)
            } else if let stableScreenID {
                externalOwnedScreenIDs.remove(stableScreenID)
                externalPresentedScreenIDs.remove(stableScreenID)
                externalFirstFrameReadyScreenIDs.remove(stableScreenID)
            }
        case .firstFrameReady(let screenIndex, let stableScreenID, let requestID):
            guard let screen = externalScreen(
                for: screenIndex,
                stableScreenID: stableScreenID
            ) else {
                AppLogger.error(.wallpaper, "video-renderer 首帧事件屏幕索引无效: \(screenIndex)")
                return
            }
            let screenID = screen.wallpaperScreenIdentifier
            guard let requestID,
                  externalRequestIDByScreenID[screenID] == requestID else {
                AppLogger.debug(.wallpaper, "忽略过期 video-renderer 首帧事件", metadata: [
                    "screenID": screenID,
                    "requestID": requestID ?? "nil",
                    "currentRequestID": externalRequestIDByScreenID[screenID] ?? "nil"
                ])
                return
            }
            rememberExternalPresentedScreen(screen)
            AppLogger.info(.wallpaper, "video-renderer 首帧就绪", metadata: [
                "screenID": screenID,
                "screenIndex": screenIndex,
                "requestID": requestID
            ])
            // A cross-type video may report its first drawable while its
            // window remains intentionally hidden behind Scene/Web/static.
            // Keep its poster installed until the snapshot-backed commit
            // reveals that window, so no compositor frame can expose black.
            if !externalPendingCommitScreenIDs.contains(screenID),
               !externalIsPaused(screenID: screen.wallpaperScreenIdentifier) {
                hidePosterImage(for: screen.wallpaperScreenIdentifier)
            }
            scheduleDisplaySwitchStableRelease(
                screenID: screenID,
                reason: "externalFirstFrameReady"
            )
        case .playbackEnded(let screenIndex, let stableScreenID, let requestID):
            guard let screen = externalScreen(
                for: screenIndex,
                stableScreenID: stableScreenID
            ) else {
                AppLogger.error(.wallpaper, "video-renderer 播放结束事件屏幕索引无效: \(screenIndex)")
                return
            }
            guard requestID == externalRequestIDByScreenID[screen.wallpaperScreenIdentifier] else {
                return
            }
            // renderer 已在发送结束事件前同步盖住 poster。这里不能再异步补发
            // showPoster，否则旧视频的命令可能在新视频 set 后晚到并覆盖新画面。
            DistributedNotificationCenter.default().postNotificationName(
                WallpaperSchedulerService.videoPlaybackEndedNotification,
                object: nil,
                userInfo: [
                    "screenID": screen.wallpaperScreenIdentifier
                ],
                deliverImmediately: true
            )
        case .error(let screenIndex, let stableScreenID, let requestID, let message):
            AppLogger.error(
                .wallpaper,
                "video-renderer error screen=\(screenIndex.map(String.init) ?? "nil") id=\(stableScreenID ?? "nil") request=\(requestID ?? "nil"): \(message)"
            )
            // 共享解码首帧超时的保险丝：该屏降级为独立解码器重试一次。
            // 交接中的屏也走这里，避免 10s 黑窗后还要再等 30s rollback。
            if message.contains("first frame timeout"),
               let requestID,
               let screen = externalScreen(
                   for: screenIndex ?? -1,
                   stableScreenID: stableScreenID
               ) {
                Task { @MainActor [weak self] in
                    await self?.retryExternalScreenWithDedicatedDecoder(
                        screen: screen,
                        failedRequestID: requestID
                    )
                }
            }
        case .terminated(let status, let expected):
            guard !expected else { return }
            externalFirstFrameReadyScreenIDs.removeAll()
            externalPresentedScreenIDs.removeAll()
            externalOwnedScreenIDs.removeAll()
            scheduleExternalRendererRestart(afterExitStatus: status)
        }
    }

    /// 共享解码首帧超时后的保险丝：对该屏单独重发 set（forceNewPipeline + 新 requestID）。
    /// 子进程 findReusablePlayerComponents 的 requestID 过滤会让它拿到独立 player，
    /// `shared` 字段保持原值，不扰乱其他屏的共享语义。
    /// 交接中的屏同样重试：新 set 会保住旧窗，避免黑场后空等 rollback。
    private func retryExternalScreenWithDedicatedDecoder(
        screen: NSScreen,
        failedRequestID: String
    ) async {
        let screenID = screen.wallpaperScreenIdentifier
        guard externalRenderingActive,
              externalRenderer.isRunning,
              externalRequestIDByScreenID[screenID] == failedRequestID,
              !externalFallbackAttemptedScreenIDs.contains(screenID),
              let videoURL = videoURLByScreen[screenID],
              let screenIndex = externalScreenIndex(for: screen) else {
            return
        }
        externalFallbackAttemptedScreenIDs.insert(screenID)

        let newRequestID = UUID().uuidString
        let posterURL = posterURLByScreen[screenID]
        let schedulerConfig = WallpaperSchedulerService.shared.config
            .resolvedDisplayConfig(for: screenID)
        let isOnEndMode = schedulerConfig.isEnabled && schedulerConfig.isOnEndMode
        let hdrMetadataEnabled = UserDefaults.standard
            .object(forKey: "hdr_enabled") as? Bool ?? false
        let playbackURL = resolvedExternalPlaybackURL(for: videoURL, screen: screen)

        externalRequestIDByScreenID[screenID] = newRequestID
        let cmd = VideoRendererProcessController.Command.set(
            screen: screenIndex,
            screenID: screenID,
            requestID: newRequestID,
            path: playbackURL.path,
            posterPath: posterURL?.isFileURL == true ? posterURL?.path : nil,
            frame: screen.frame,
            muted: isMuted,
            volume: volume(for: screen),
            looping: !isOnEndMode,
            shared: usesSharedVideoDecoder,
            forceNewPipeline: true,
            hdrMetadataEnabled: hdrMetadataEnabled,
            deferredPresentation: externalLiveVideoScreenIDs.contains(screenID),
            transitionDuration: 0,
            globalPaused: isPaused,
            screenPaused: externalPausedScreenIDs.contains(screenID),
            globalDisplaySyncEnabled: WallpaperSchedulerService.shared.isGlobalDisplaySyncEnabled
        )
        let response = await externalRenderer.sendCommand(
            cmd,
            screen: screenIndex,
            timeout: Self.externalRendererSetCommandTimeout
        )
        AppLogger.info(.wallpaper, "外部视频首帧超时，已降级独立解码重试", metadata: [
            "screenID": screenID,
            "screenIndex": screenIndex,
            "response": response ?? "nil"
        ])
    }

    private func scheduleExternalRendererRestart(afterExitStatus status: Int32) {
        guard externalRenderingActive, hasActiveVideoWallpaper else { return }
        externalRendererRestartWorkItem?.cancel()
        externalRendererRestartAttempt += 1
        // First crash: restart immediately. Later crashes stay under 2s so a
        // flapping helper cannot leave the desktop black for 10 seconds.
        let delay = min(2.0, Double(max(0, externalRendererRestartAttempt - 1)) * 0.25)
        AppLogger.error(.wallpaper, "video-renderer 意外退出，准备重启", metadata: [
            "status": status,
            "attempt": externalRendererRestartAttempt,
            "delay": delay
        ])

        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.externalRenderingActive,
                  self.hasActiveVideoWallpaper,
                  !self.externalRenderer.isRunning else {
                return
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard await self.externalRenderer.startDaemon() else {
                    self.scheduleExternalRendererRestart(afterExitStatus: status)
                    return
                }
                await self.reconfigureExternalRendererForCurrentScreens(
                    reason: "rendererRestart",
                    clearExistingRendererState: false
                )
            }
        }
        externalRendererRestartWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func cancelExternalRendererRestart() {
        externalRendererRestartWorkItem?.cancel()
        externalRendererRestartWorkItem = nil
        externalRendererRestartAttempt = 0
    }

    /// renderer「活而不答」（进程存活但 IPC 无响应）时强制换代：杀掉重启并
    /// 清空随 daemon 生命周期的交接状态。旧逻辑只在进程真正退出后才重启，
    /// 卡而不死的 daemon 永远不会被替换，导致所有切换静默失败、只能手动
    /// 杀进程——这里是该楔死态的根治点。
    @discardableResult
    private func forceRecycleExternalRenderer(reason: String) async -> Bool {
        AppLogger.error(.wallpaper, "video-renderer 无响应，强制换代重启", metadata: [
            "reason": reason
        ])
        externalRenderer.stopDaemon()
        externalFirstFrameReadyScreenIDs.removeAll()
        externalPresentedScreenIDs.removeAll()
        externalOwnedScreenIDs.removeAll()
        externalPendingCommitScreenIDs.removeAll()
        cancelExternalRendererRestart()
        return await externalRenderer.startDaemon()
    }

    /// `wallpaper-video-renderer` 使用 NSScreen.screens 的索引作为 IPC 屏幕标识。
    /// screenID 短暂变化时按物理指纹回退，避免副屏重连后命令打到错误窗口。
    private func externalScreenIndex(for screen: NSScreen) -> Int? {
        if let index = WallpaperScreenIdentity.stableIndex(of: screen) {
            return index
        }
        return NSScreen.screensOrderedForDisplay.firstIndex(where: {
            $0.wallpaperScreenFingerprint == screen.wallpaperScreenFingerprint
        })
    }

    private func externalScreen(for index: Int) -> NSScreen? {
        let orderedScreens = NSScreen.screensOrderedForDisplay
        guard orderedScreens.indices.contains(index) else { return nil }
        return orderedScreens[index]
    }

    private func externalScreen(
        for index: Int,
        stableScreenID: String?
    ) -> NSScreen? {
        if let stableScreenID {
            if let screen = NSScreen.screensOrderedForDisplay.first(where: {
                $0.wallpaperScreenIdentifier == stableScreenID
            }) {
                return screen
            }
            if let screen = NSScreen.screensOrderedForDisplay.first(where: {
                $0.wallpaperScreenFingerprint == stableScreenID
            }) {
                return screen
            }
            if let existingID = externalOwnedScreenIDs.first(where: {
                $0 == stableScreenID
            }),
               let screen = NSScreen.screensOrderedForDisplay.first(where: {
                   $0.wallpaperScreenIdentifier == existingID
                       || $0.wallpaperScreenFingerprint == existingID
               }) {
                return screen
            }
        }
        if index >= 0, let screen = externalScreen(for: index) {
            return screen
        }
        return nil
    }

    private func externalTargetScreens() -> [NSScreen] {
        let targets = screensForVideoWallpaperTargets()
        if !targets.isEmpty {
            return targets
        }
        let hasExplicitTargets = !videoTargetScreenIDs.isEmpty
            || !videoTargetScreenFingerprints.isEmpty
        return externalRenderingActive && !hasExplicitTargets
            ? NSScreen.screensOrderedForDisplay
            : []
    }

    private func rememberExternalOwnedScreen(_ screen: NSScreen) {
        externalOwnedScreenIDs.insert(screen.wallpaperScreenIdentifier)
        externalOwnedScreenIDs.insert(screen.wallpaperScreenFingerprint)
    }

    private func rememberExternalPresentedScreen(_ screen: NSScreen) {
        rememberExternalOwnedScreen(screen)
        externalPresentedScreenIDs.insert(screen.wallpaperScreenIdentifier)
        externalPresentedScreenIDs.insert(screen.wallpaperScreenFingerprint)
        externalFirstFrameReadyScreenIDs.insert(screen.wallpaperScreenIdentifier)
        externalFirstFrameReadyScreenIDs.insert(screen.wallpaperScreenFingerprint)
    }

    private func externalIsPaused(screenID: String) -> Bool {
        isPaused || externalPausedScreenIDs.contains(screenID)
    }

    /// 播完即换：把调度器预演出的下一条视频推给 renderer 预建解码管线
    /// （preroll 暖机），让切换时的首帧等待完全藏进当前视频的播放期内。
    /// 延迟一拍发射：applyItem 返回后调度器才写入 lastChangedItemIDs，
    /// 立即预演会拿到旧状态、把「当前这张」误当成下一张。
    private func prewarmNextOnEndWallpaperForExternalRenderer() {
        guard useExternalVideoRenderer else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.externalRenderer.isRunning else { return }
            let scheduler = WallpaperSchedulerService.shared
            let hdrMetadataEnabled = UserDefaults.standard
                .object(forKey: "hdr_enabled") as? Bool ?? false
            for screen in self.externalTargetScreens() {
                let screenID = screen.wallpaperScreenIdentifier
                guard self.videoTargetScreenIDs.contains(screenID),
                      let screenIndex = self.externalScreenIndex(for: screen),
                      let nextURL = scheduler.peekNextOnEndPlaybackURL(for: screenID)
                else { continue }
                let playbackURL = self.resolvedExternalPlaybackURL(
                    for: nextURL,
                    screen: screen
                )
                self.externalRenderer.sendCommandFireAndForget(.prewarm(
                    screen: screenIndex,
                    path: playbackURL.path,
                    volume: self.volume(for: screen),
                    hdrMetadataEnabled: hdrMetadataEnabled
                ))
            }
        }
    }

    private func resolvedExternalPlaybackURL(
        for sourceURL: URL,
        screen: NSScreen
    ) -> URL {
        let targetFPS = frameInterpolationTargetFPS(for: screen)
        guard let record = VideoOptimizationQueueService.shared.completedRecord(
            videoURL: sourceURL,
            satisfying: targetFPS
        ) else {
            return sourceURL
        }
        let candidate = URL(fileURLWithPath: record.videoPath)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : sourceURL
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

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleVideoOptimizationFileReplacement(_:)),
            name: .videoOptimizationFileDidReplace,
            object: nil
        )

        // macOS 26+：监听 WallpaperExtension 锁屏镜像实例状态变化
        if #available(macOS 26.0, *) {
            observeExtensionStateChanges()
        }
    }

    /// 队列只报告文件被原地替换；播放器在这里确认该路径仍属于当前屏幕后才刷新。
    @objc private func handleVideoOptimizationFileReplacement(_ notification: Notification) {
        guard let videoURL = notification.object as? URL else { return }
        let replacementKind = (notification.userInfo?[VideoOptimizationFileReplacementKind.userInfoKey] as? String)
            .flatMap(VideoOptimizationFileReplacementKind.init(rawValue:))
        reloadPlaybackAfterInPlaceReplacement(
            videoURL: videoURL,
            markAsInterpolated: replacementKind == .frameInterpolation
        )
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
        externalWakeRecoveryTask?.cancel()
        externalWakeRecoveryTask = nil
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


    /// Enables or disables shared-decoder playback for multi-display sync.
    /// When enabled, all target screens attach the same AVQueuePlayer so they
    /// stay frame-aligned and only one decode pipeline is active.
    func setSharedDecoderPlaybackEnabled(
        _ enabled: Bool,
        sourceScreen: NSScreen? = nil
    ) {
        guard usesSharedVideoDecoder != enabled else { return }
        let sourceVideoURL = sourceScreen.flatMap(videoURL(for:)) ?? currentVideoURL
        let sourcePosterURL = sourceScreen.flatMap(posterURL(for:)) ?? currentPosterURL
        guard let sourceVideoURL,
              FileManager.default.fileExists(atPath: sourceVideoURL.path) else {
            usesSharedVideoDecoder = enabled
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.applyVideoWallpaper(
                    from: sourceVideoURL,
                    posterURL: sourcePosterURL,
                    muted: self.isMuted,
                    targetScreen: nil,
                    animatedTransition: false,
                    usesSharedVideoDecoder: enabled
                )
            } catch {
                AppLogger.error(.wallpaper, "Failed to change shared video decoder mode", metadata: [
                    "enabled": enabled,
                    "error": error.localizedDescription,
                ])
            }
        }
    }

    /// Rebind a globally synchronized video to the current screen set after
    /// connect/disconnect. The original global apply can start on one display,
    /// where a shared decoder is unnecessary; when another display appears we
    /// must still rebuild as shared instead of returning early.
    func refreshSharedDecoderTargets() {
        guard let currentVideoURL,
              FileManager.default.fileExists(atPath: currentVideoURL.path) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await self.applyVideoWallpaper(
                from: currentVideoURL,
                posterURL: currentPosterURL,
                muted: self.isMuted,
                targetScreens: NSScreen.screens,
                animatedTransition: false,
                usesSharedVideoDecoder: NSScreen.screens.count > 1,
                forceRebuild: true
            )
        }
    }

    func applyVideoWallpaper(
        from localFileURL: URL,
        posterURL: URL? = nil,
        muted: Bool = true,
        targetScreens: [NSScreen]?,
        animatedTransition: Bool = false,
        usesSharedVideoDecoder: Bool = false,
        forceRebuild: Bool = false
    ) async throws {
        if usesSharedVideoDecoder {
            try await applyVideoWallpaper(
                from: localFileURL,
                posterURL: posterURL,
                muted: muted,
                targetScreen: nil,
                animatedTransition: animatedTransition,
                usesSharedVideoDecoder: true,
                forceRebuild: forceRebuild
            )
            return
        }
        if let screens = targetScreens, !screens.isEmpty {
            for screen in screens {
                try await applyVideoWallpaper(
                    from: localFileURL,
                    posterURL: posterURL,
                    muted: muted,
                    targetScreen: screen,
                    animatedTransition: animatedTransition,
                    usesSharedVideoDecoder: false,
                    forceRebuild: forceRebuild
                )
            }
        } else {
            try await applyVideoWallpaper(
                from: localFileURL,
                posterURL: posterURL,
                muted: muted,
                targetScreen: nil,
                animatedTransition: animatedTransition,
                usesSharedVideoDecoder: false,
                forceRebuild: forceRebuild
            )
        }
    }

    func applyVideoWallpaper(
        from localFileURL: URL,
        posterURL: URL? = nil,
        muted: Bool = true,
        targetScreen: NSScreen? = nil,
        animatedTransition: Bool = false,
        usesSharedVideoDecoder: Bool = false,
        forceRebuild: Bool = false
    ) async throws {
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

        WallpaperCrossTypeTransitionCoordinator.shared.invalidatePendingRequests(
            on: targetScreen.map { [$0] } ?? NSScreen.screens
        )

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

        if useExternalVideoRenderer {
            try await applyVideoWallpaperViaExternalRenderer(
                from: localFileURL,
                posterURL: posterURL,
                muted: muted,
                targetScreen: targetScreen,
                usesSharedVideoDecoder: usesSharedVideoDecoder,
                animatedTransition: animatedTransition,
                forceRebuild: forceRebuild
            )
            return
        }

        // A newer apply supersedes a still-warming global generation. Roll its
        // logical source mapping back before capturing the next transition state.
        if pendingGlobalTransitionPlayer != nil {
            restoreGlobalTransitionSourceState()
            cancelPendingGlobalVideoTransition(reason: "supersededByNewApply")
        }

        let captureScreens: [NSScreen]
        if let targetScreen {
            captureScreens = [targetScreen]
        } else {
            captureScreens = NSScreen.screens
        }
        WallpaperEngineXBridge.shared.prepareForNonExternalWallpaperSwitch(
            on: captureScreens,
            reason: "applyVideoWallpaper"
        )
        DesktopWallpaperSyncManager.shared.captureOriginalSystemWallpaperIfNeeded(for: captureScreens)

        // Scene/Web/独立静态图 → 视频：旧内容保留到新视频首帧就绪后再无黑场提交。
        // 视频 → 视频不走跨类型标记：由 per-screen replacement / global stage 保留旧 AVPlayer 窗口。
        // 若误把旧视频标成 cross-type，stage 失败 teardown 后 createWindow 会 alpha=1 露黑窗。
        for screen in captureScreens {
            let screenID = screen.wallpaperScreenIdentifier
            let hasExternalRenderer = WallpaperEngineXBridge.shared.hasLivePresentation(on: screen)
            let hasStaticOverlay = StaticImageWallpaperOverlayManager.shared.hasActiveWallpaper(on: [screen])
            if animatedTransition && (hasExternalRenderer || hasStaticOverlay) {
                pendingCrossTypeVideoScreenIDs.insert(screenID)
                if hasStaticOverlay {
                    StaticImageWallpaperOverlayManager.shared.keepPresentationFront(on: [screen])
                }
                if windows[screenID] != nil {
                    // 同屏仍有视频窗时也顶在前，避免新 Scene 窗抢到最前闪一帧。
                    keepNativeVideoPresentationFront(on: [screen])
                }
                continue
            }

            pendingCrossTypeVideoScreenIDs.remove(screenID)
            StaticImageWallpaperOverlayManager.shared.clearState(for: screen)
            if hasExternalRenderer {
                WallpaperEngineXBridge.shared.ensureStoppedForNonCLIWallpaper(for: screen)
            }
        }

        let playbackModeChanged = self.usesSharedVideoDecoder != usesSharedVideoDecoder
        let isNewVideo = currentVideoURL != localFileURL
        let activeScreenIDs = Set(windows.keys)
        let screenIDsNow = Set(NSScreen.screens.map(\.wallpaperScreenIdentifier))
        let targetScreenID = targetScreen?.wallpaperScreenIdentifier
        let isSameVideoForTarget = targetScreen.flatMap { videoURL(for: $0) } == localFileURL
        let targetScreenAlreadyActive = targetScreenID.map { windows[$0] != nil && videoTargetScreenIDs.contains($0) } ?? true
        let targetDisplayConfigurationChanged = hasEffectiveTargetDisplayChange()
        // 不能只看 currentVideoURL：两屏先播不同文件时，全局 current 可能已是目标文件，
        // 但另一屏仍挂着旧 AVQueuePlayer（lsof 会看到两个 mp4，VTDecoder 也会残留）。
        // 只有「相关目标屏」全都已经是 localFileURL 才允许 early-return。
        let targetScreensAlreadyUniform: Bool = {
            let expected = localFileURL.standardizedFileURL
            if let targetScreen {
                return videoURL(for: targetScreen)?.standardizedFileURL == expected
            }
            // 全屏应用：当前所有视频目标屏 + 已有窗口屏都必须是同一文件。
            let candidateIDs = videoTargetScreenIDs.union(activeScreenIDs)
            guard !candidateIDs.isEmpty else { return false }
            for screen in NSScreen.screens where candidateIDs.contains(screen.wallpaperScreenIdentifier) {
                if videoURL(for: screen)?.standardizedFileURL != expected {
                    return false
                }
            }
            // 还要确认没有「地图已是目标文件、但 player 实际挂着别的 asset」的脏状态。
            for (screenID, player) in players where candidateIDs.contains(screenID) {
                if let assetURL = (player.currentItem?.asset as? AVURLAsset)?.url.standardizedFileURL,
                   assetURL != expected {
                    return false
                }
            }
            return true
        }()

        if !forceRebuild,
           !isNewVideo,
           currentVideoURL == localFileURL,
           !windows.isEmpty,
           targetScreensAlreadyUniform,
           (targetScreen == nil || (isSameVideoForTarget && targetScreenAlreadyActive)),
           activeScreenIDs == videoTargetScreenIDs,
           videoTargetScreenIDs.isSubset(of: screenIDsNow),
           !targetDisplayConfigurationChanged,
           !playbackModeChanged {
            print("[VideoWallpaperManager] Taking early-return path (reusing existing players). forceRebuild=\(forceRebuild), playbackModeChanged=\(playbackModeChanged)")
            // 已起播同一视频但每屏各有一路解码时，把多份 AVQueuePlayer 合并成一路。
            // 否则「再设一次同样壁纸」会 early-return，VTDecoderXPCService 仍是多份。
            let coalesced = coalesceDuplicateDecodersForSameVideos()
            if usesSharedVideoDecoder && !self.usesSharedVideoDecoder {
                self.usesSharedVideoDecoder = true
            }
            purgeOrphanedVideoPlayers(reason: coalesced ? "reuseExistingCoalesced" : "reuseExisting")
            synchronizeExistingWindowFramesToCurrentScreens()
            currentVideoURL = localFileURL
            setMuted(muted)
            if !isPaused {
                var seenPlayers = Set<ObjectIdentifier>()
                for player in players.values {
                    let id = ObjectIdentifier(player)
                    guard seenPlayers.insert(id).inserted else { continue }
                    if player.rate == 0 {
                        player.play()
                    }
                }
            }
            DynamicWallpaperAutoPauseManager.shared.clearForegroundPauseForWallpaperSwitch()
            DynamicWallpaperAutoPauseManager.shared.reevaluateCurrentState()

            // 即使复用已有播放器，也要同步锁屏镜像的 per-display 帧源。
            if #available(macOS 26.0, *) {
                LockScreenWallpaperService.shared.syncInstanceCatalogToSocketServer()
                syncAllDisplayVideosToExtension()
            }
            // 复用路径也要补齐静帧 map：上次 apply 时可能还没有 HD poster（调度器
            // 先起播再后台抽帧），后台生成完成后 cache 已有，再点一次/再调度到
            // 同一视频时需要把 poster 写进 map 并推系统桌面底图。
            if let posterURL {
                if let targetScreen {
                    let existing = self.posterURL(for: targetScreen)
                    if existing?.standardizedFileURL != posterURL.standardizedFileURL {
                        updatePosterURL(posterURL, for: targetScreen, expectedVideoURL: localFileURL)
                    }
                } else {
                    for screen in NSScreen.screens {
                        let existing = self.posterURL(for: screen)
                        if existing?.standardizedFileURL != posterURL.standardizedFileURL {
                            updatePosterURL(posterURL, for: screen, expectedVideoURL: localFileURL)
                        }
                    }
                }
            }
            if let targetScreenID {
                scheduleDisplaySwitchStableRelease(screenID: targetScreenID, reason: coalesced ? "reuseExistingCoalesced" : "reuseExisting")
            }
            return
        }

        if let targetScreen,
           animatedTransition,
           windows[targetScreen.wallpaperScreenIdentifier] != nil,
           let previousVideoURL = videoURL(for: targetScreen) {
            screenTransitionSourceRollbacks[targetScreen.wallpaperScreenIdentifier] = ScreenTransitionSourceRollback(
                videoURL: previousVideoURL,
                posterURL: self.posterURL(for: targetScreen),
                fingerprint: targetScreen.wallpaperScreenFingerprint
            )
        } else if targetScreen == nil,
                  animatedTransition,
                  // 单屏全局切换不会开 shared decoder，同样需要旧画面回滚。
                  (usesSharedVideoDecoder || NSScreen.screens.count == 1),
                  !windows.isEmpty {
            globalTransitionSourceRollback = GlobalTransitionSourceRollback(
                currentVideoURL: currentVideoURL,
                currentPosterURL: currentPosterURL,
                videoURLByScreen: videoURLByScreen,
                videoURLByScreenFingerprint: videoURLByScreenFingerprint,
                posterURLByScreen: posterURLByScreen,
                posterURLByScreenFingerprint: posterURLByScreenFingerprint
            )
        }

        self.usesSharedVideoDecoder = usesSharedVideoDecoder

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
                registerPendingPosterBackplate(
                    posterURL,
                    targetScreen: targetScreen
                )
                // 动画切换：等新视频起播/首帧就绪后再写系统底图，避免加载期
                // 系统墙纸刷新与 desktop-level 动态窗抢合成、拉长可见黑场。
                schedulePosterAsDesktopWallpaperAfterPlaybackSettles(
                    posterURL,
                    targetScreen: targetScreen,
                    expectedVideoURL: localFileURL
                )
            } else if posterURL.isFileURL {
                // 与直接设置静态图保持相同顺序：先提交系统桌面底图并发出
                // com.apple.desktop 刷新，再创建/显示 desktop-level 视频窗口。
                applyPosterAsDesktopWallpaperSync(posterURL, targetScreen: targetScreen)
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
        // 预热 poster 缓存：播完即换结束瞬间需要同步盖图，不能再走 URLSession。
        if let posterURL {
            _ = loadPosterImageSync(from: posterURL)
        }
        currentPosterURL = posterURL  // 兼容旧代码
        isMuted = muted

        // 直接沿用调用方传入的 NSScreen，避免再按 screenID 反查失败时
        // 误走 targetScreen == nil 分支、teardown 所有视频窗（副屏会表现为“软件壁纸退出”）。
        try rebuildWindows(
            targetScreen: targetScreen,
            animatedTransition: animatedTransition
        )
        // 切换后扫掉 layer/过渡层仍挂着的旧 player，避免 VTDecoder 随每次设置累积。
        purgeOrphanedVideoPlayers(reason: "afterRebuild")
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

    // MARK: - 子进程渲染路径

    private func canReuseExternalVideoWallpaper(
        _ localFileURL: URL,
        on screens: [NSScreen],
        targetScreen: NSScreen?,
        usesSharedVideoDecoder: Bool
    ) -> Bool {
            guard externalRenderingActive,
              externalRenderer.isRunning,
              self.usesSharedVideoDecoder == usesSharedVideoDecoder,
              externalPendingCommitScreenIDs.isDisjoint(
                  with: screens.map(\.wallpaperScreenIdentifier)
              ),
              lastAppliedScreenConfigurations
                  == currentTargetScreenConfigurations() else {
            return false
        }

        let expectedSource = localFileURL.standardizedFileURL
        let screenIDs = Set(screens.map(\.wallpaperScreenIdentifier))
        if targetScreen == nil {
            let liveTargetIDs = Set(
                externalTargetScreens().map(\.wallpaperScreenIdentifier)
            )
            guard liveTargetIDs == screenIDs,
                  screenIDs.isSubset(of: externalLiveVideoScreenIDs) else {
                return false
            }
        }

        for screen in screens {
            let screenID = screen.wallpaperScreenIdentifier
            guard assignedVideoURL(for: screen)?.standardizedFileURL
                    == expectedSource,
                  externalLiveVideoScreenIDs.contains(screenID),
                  externalRequestIDByScreenID[screenID] != nil else {
                return false
            }
            let desiredPlaybackURL = resolvedExternalPlaybackURL(
                for: localFileURL,
                screen: screen
            ).standardizedFileURL
            let currentPlaybackURL = (
                frameInterpolatedPlaybackURLByScreen[screenID]
                    ?? assignedVideoURL(for: screen)
            )?.standardizedFileURL
            guard currentPlaybackURL == desiredPlaybackURL else {
                return false
            }
        }
        return true
    }

    private func reuseExternalVideoWallpaper(
        _ localFileURL: URL,
        posterURL: URL?,
        muted: Bool,
        on screens: [NSScreen],
        targetScreen: NSScreen?,
        usesSharedVideoDecoder: Bool
    ) {
        self.usesSharedVideoDecoder = usesSharedVideoDecoder
        currentVideoURL = localFileURL
        setMuted(muted)

        if !isPaused {
            if targetScreen == nil {
                externalRenderer.sendCommandFireAndForget(.resume(screen: nil))
                externalPausedScreenIDs.subtract(
                    screens.map(\.wallpaperScreenIdentifier)
                )
            }

            for screen in screens {
                let screenID = screen.wallpaperScreenIdentifier
                if targetScreen != nil, let screenIndex = externalScreenIndex(for: screen) {
                    externalRenderer.sendCommandFireAndForget(.resume(screen: screenIndex))
                    externalPausedScreenIDs.remove(screenID)
                }
                hidePosterImage(for: screenID)
            }
        }

        for screen in screens {
            let screenID = screen.wallpaperScreenIdentifier
            if isPaused {
                showPosterImage(for: screenID)
            }
            if let posterURL,
               self.posterURL(for: screen)?.standardizedFileURL
                    != posterURL.standardizedFileURL {
                updatePosterURL(
                    posterURL,
                    for: screen,
                    expectedVideoURL: localFileURL
                )
            }
            applyCropToScreen(screen)
            prepareExternalFrameInterpolation(
                screenID: screenID,
                screen: screen,
                videoURL: localFileURL
            )
        }

        if let posterURL {
            currentPosterURL = posterURL
        }
        lastAppliedScreenConfigurations = currentTargetScreenConfigurations()
        persistState()
        DynamicWallpaperAutoPauseManager.shared
            .clearForegroundPauseForWallpaperSwitch()
        DynamicWallpaperAutoPauseManager.shared.reevaluateCurrentState()

        if let targetScreen {
            scheduleDisplaySwitchStableRelease(
                screenID: targetScreen.wallpaperScreenIdentifier,
                reason: "reuseExternalVideo"
            )
        }
        if #available(macOS 26.0, *) {
            LockScreenWallpaperService.shared.syncInstanceCatalogToSocketServer()
            syncAllDisplayVideosToExtension()
        }
        AppLogger.info(.wallpaper, "复用现有 external video 播放管线", metadata: [
            "video": localFileURL.lastPathComponent,
            "screens": screens.map(\.wallpaperScreenIdentifier)
                .sorted()
                .joined(separator: ",")
        ])

        // 播完即换：复用路径同样为下一次切换预暖解码管线
        prewarmNextOnEndWallpaperForExternalRenderer()
    }

    /// 通过 wallpaper-video-renderer 子进程设置视频壁纸。
    /// 主进程只保留状态、系统 poster 和布局计算；可见窗口及 AVPlayer
    /// 全部由子进程持有。
    private func applyVideoWallpaperViaExternalRenderer(
        from localFileURL: URL,
        posterURL: URL?,
        muted: Bool,
        targetScreen: NSScreen?,
        usesSharedVideoDecoder: Bool,
        animatedTransition: Bool,
        forceRebuild: Bool
    ) async throws {
        try await withExternalRendererTransaction {
            try await self.applyVideoWallpaperViaExternalRendererLocked(
                from: localFileURL,
                posterURL: posterURL,
                muted: muted,
                targetScreen: targetScreen,
                usesSharedVideoDecoder: usesSharedVideoDecoder,
                animatedTransition: animatedTransition,
                forceRebuild: forceRebuild
            )
        }
    }

    private func applyVideoWallpaperViaExternalRendererLocked(
        from localFileURL: URL,
        posterURL: URL?,
        muted: Bool,
        targetScreen: NSScreen?,
        usesSharedVideoDecoder: Bool,
        animatedTransition: Bool,
        forceRebuild: Bool
    ) async throws {
        AppLogger.info(.wallpaper, "applyVideoWallpaperViaExternalRenderer", metadata: [
            "video": localFileURL.lastPathComponent,
            "targetScreen": targetScreen?.localizedName ?? "nil(全部)"
        ])
        // Drop any queued pause/resume first. Waiting for an in-flight pause
        // after the user already asked for the next wallpaper is what let the
        // old pause land on the incoming player.
        invalidateExternalPlaybackControl(reason: "applyVideoWallpaper")
        await waitForExternalPlaybackControl()

        let captureScreens: [NSScreen] = {
            if let targetScreen {
                return [targetScreen]
            }
            return NSScreen.screensOrderedForDisplay
        }()
        guard !captureScreens.isEmpty else {
            throw NSError(
                domain: "VideoWallpaper",
                code: 2002,
                userInfo: [NSLocalizedDescriptionKey: "没有可用的显示器来承载视频壁纸"]
            )
        }

        if !forceRebuild,
           canReuseExternalVideoWallpaper(
               localFileURL,
               on: captureScreens,
               targetScreen: targetScreen,
               usesSharedVideoDecoder: usesSharedVideoDecoder
           ) {
            reuseExternalVideoWallpaper(
                localFileURL,
                posterURL: posterURL,
                muted: muted,
                on: captureScreens,
                targetScreen: targetScreen,
                usesSharedVideoDecoder: usesSharedVideoDecoder
            )
            return
        }

        // Scene/Web and static overlays stay alive until the child renderer
        // reports a real first drawable. This snapshot is captured before any
        // external state is changed.
        let oldExternalScreens = captureScreens.filter { screen in
            WallpaperEngineXBridge.shared.hasLivePresentation(on: screen)
                || WallpaperEngineXBridge.shared.isManaging(screen: screen)
                || StaticImageWallpaperOverlayManager.shared.hasActiveWallpaper(on: [screen])
        }
        let oldVideoScreens = captureScreens.filter {
            externalLiveVideoScreenIDs.contains($0.wallpaperScreenIdentifier)
        }
        // Any visible video replacement is staged, even when the caller does
        // not request animation. A zero-duration commit still preserves the
        // old player until every replacement layer has a drawable and gives
        // synchronous/timeout failures a real rollback path.
        let deferredVideoScreens = oldVideoScreens
        let externalRollback = ExternalTransitionSourceRollback(
            currentVideoURL: currentVideoURL,
            currentPosterURL: currentPosterURL,
            isMuted: isMuted,
            isPaused: isPaused,
            usesSharedVideoDecoder: self.usesSharedVideoDecoder,
            externalRenderingActive: externalRenderingActive,
            videoURLByScreen: videoURLByScreen,
            videoURLByScreenFingerprint: videoURLByScreenFingerprint,
            posterURLByScreen: posterURLByScreen,
            posterURLByScreenFingerprint: posterURLByScreenFingerprint,
            videoTargetScreenIDs: videoTargetScreenIDs,
            videoTargetScreenFingerprints: videoTargetScreenFingerprints,
            externalPausedScreenIDs: externalPausedScreenIDs,
            externalRequestIDByScreenID: externalRequestIDByScreenID,
            externalPresentedScreenIDs: externalPresentedScreenIDs,
            externalOwnedScreenIDs: externalOwnedScreenIDs,
            externalFirstFrameReadyScreenIDs: externalFirstFrameReadyScreenIDs,
            externalPendingCommitScreenIDs: externalPendingCommitScreenIDs,
            externalCropRevisionByScreenID: externalCropRevisionByScreenID,
            videoSizes: videoSizes,
            videoLetterboxContentCrops: videoLetterboxContentCrops,
            frameInterpolationDecisionsByScreen: frameInterpolationDecisionsByScreen,
            frameInterpolatedPlaybackURLByScreen: frameInterpolatedPlaybackURLByScreen
        )
        externalTransitionGeneration &+= 1
        let transitionGeneration = externalTransitionGeneration
        externalPendingCommitScreenIDs.formUnion(
            oldExternalScreens.map(\.wallpaperScreenIdentifier)
        )
        externalPendingCommitScreenIDs.formUnion(
            deferredVideoScreens.map(\.wallpaperScreenIdentifier)
        )
        externalFirstFrameReadyScreenIDs.subtract(
            captureScreens.map(\.wallpaperScreenIdentifier)
        )

        // 确保子进程已启动
        if !externalRenderer.isRunning {
            guard await externalRenderer.startDaemon() else {
                restoreExternalTransitionSourceState(externalRollback)
                releaseExternalDisplaySwitchGate(
                    for: captureScreens,
                    reason: "externalRendererLaunchFailed"
                )
                throw NSError(domain: "VideoWallpaper", code: 2001,
                              userInfo: [NSLocalizedDescriptionKey: "视频渲染子进程启动失败"])
            }
        } else {
            // Setting a new video normally reuses the healthy daemon, so the
            // launch path is not entered. Reconcile here as well: an older
            // child from a raced stop/restart can otherwise keep rendering
            // the previous wallpaper underneath the current one.
            await externalRenderer.reconcileChildRenderers()
        }

        // 停掉主进程内可能残留的旧视频窗口（从旧路径切换过来的场景）。
        teardownAllWindows(preserveDisplaySwitchGate: true)

        // 清理 Scene/Web 渲染器（与原 applyVideoWallpaper 一致）
        WallpaperEngineXBridge.shared.prepareForNonExternalWallpaperSwitch(
            on: captureScreens,
            reason: "applyVideoWallpaperViaExternalRenderer"
        )
        DesktopWallpaperSyncManager.shared.captureOriginalSystemWallpaperIfNeeded(for: captureScreens)

        // 不要在视频 -> 视频切换前 stop all。renderer 会按屏复用现有桌面窗口，
        // 先冻结旧帧，再替换 AVPlayer，直到新首帧就绪才揭开；提前 stop 会把
        // 这条无黑闪交接路径完全绕掉。显示器拓扑变化由专门的 reconfigure 路径清理。

        // 更新状态。用户点过「暂停动态壁纸」后，换片必须继续暂停，
        // 直到状态栏恢复。这里只清本轮 set 目标屏的瞬时暂停记账，
        // 不把全局/手动暂停冲掉。
        isMuted = muted
        let keepPaused = userRequestedPause
        let keepPausedScreenIDs = keepPaused ? externalPausedScreenIDs : []
        self.usesSharedVideoDecoder = usesSharedVideoDecoder
        externalRenderingActive = true
        resetExternalWakeRecoveryTracking(suspended: isScreenLocked)
        deactivateAudioSession()
        invalidateExternalPlaybackControl(reason: "applyVideoWallpaper")
        externalFallbackAttemptedScreenIDs.removeAll()

        if targetScreen == nil {
            videoURLByScreen.removeAll()
            videoURLByScreenFingerprint.removeAll()
            posterURLByScreen.removeAll()
            posterURLByScreenFingerprint.removeAll()
        }

        // 为每个目标屏发送 set 命令。
        // 主进程与 standalone renderer 必须共享同一套稳定顺序；不能直接
        // 使用 NSScreen.screens，因为睡眠/重连和不同进程的 AppKit 主屏判定
        // 都可能让原始枚举顺序发生变化。
        let requestID = UUID().uuidString
        let hdrMetadataEnabled = UserDefaults.standard.object(forKey: "hdr_enabled") as? Bool ?? false
        var failedScreens: [String] = []
        var didRecycleRendererDuringApply = false
        for screen in captureScreens {
            var screenIndex = externalScreenIndex(for: screen)
            if screenIndex == nil {
                // 显示器热插拔过渡期稳定身份可能短暂不可解析：等一拍再试
                try? await Task.sleep(nanoseconds: 300_000_000)
                screenIndex = externalScreenIndex(for: screen)
            }
            guard let screenIndex else {
                failedScreens.append(screen.wallpaperScreenIdentifier)
                continue
            }

            let screenID = screen.wallpaperScreenIdentifier
            externalRequestIDByScreenID[screenID] = requestID
            resetVideoLetterboxState(for: screenID)
            resetFrameInterpolationState(for: screenID)
            videoSizes.removeValue(forKey: screenID)
            if !keepPaused {
                externalPausedScreenIDs.remove(screenID)
            }
            let playbackURL = resolvedExternalPlaybackURL(for: localFileURL, screen: screen)
            if playbackURL.standardizedFileURL != localFileURL.standardizedFileURL {
                frameInterpolatedPlaybackURLByScreen[screenID] = playbackURL
            }

            // 先更新视频映射，再更新 poster。否则 updatePosterURL 的
            // expectedVideoURL 校验会看到旧视频并拒绝新 poster。
            videoURLByScreen[screenID] = localFileURL
            videoURLByScreenFingerprint[screen.wallpaperScreenFingerprint] = localFileURL
            if let posterURL {
                posterURLByScreen[screenID] = posterURL
                posterURLByScreenFingerprint[screen.wallpaperScreenFingerprint] = posterURL
                _ = loadPosterImageSync(from: posterURL)
            } else {
                posterURLByScreen.removeValue(forKey: screenID)
                posterURLByScreenFingerprint.removeValue(forKey: screen.wallpaperScreenFingerprint)
            }

            // 检查是否为"播完即换"模式
            let schedulerConfig = WallpaperSchedulerService.shared.config.resolvedDisplayConfig(for: screenID)
            let isOnEndMode = schedulerConfig.isEnabled && schedulerConfig.isOnEndMode

            let cmd = VideoRendererProcessController.Command.set(
                screen: screenIndex,
                screenID: screenID,
                requestID: requestID,
                path: playbackURL.path,
                posterPath: posterURL?.isFileURL == true ? posterURL?.path : nil,
                frame: screen.frame,
                muted: muted,
                volume: volume(for: screen),
                looping: !isOnEndMode,
                shared: usesSharedVideoDecoder,
                forceNewPipeline: false,
                hdrMetadataEnabled: hdrMetadataEnabled,
                deferredPresentation: oldExternalScreens.contains(where: {
                    $0.wallpaperScreenIdentifier == screenID
                }) || deferredVideoScreens.contains(where: {
                    $0.wallpaperScreenIdentifier == screenID
                }),
                transitionDuration: animatedTransition ? automaticSwitchTransitionDuration : 0,
                globalPaused: keepPaused,
                screenPaused: keepPaused || keepPausedScreenIDs.contains(screenID),
                globalDisplaySyncEnabled: WallpaperSchedulerService.shared.isGlobalDisplaySyncEnabled
            )
            var response = await externalRenderer.sendCommand(
                cmd,
                screen: screenIndex,
                timeout: Self.externalRendererSetCommandTimeout
            )
            if response?.hasPrefix("OK") != true {
                // 自愈重试：daemon「活而不答」是 set 超时的主因。健康探测失败
                // → 换代重启后重试；探测正常 → 视为瞬时竞态直接重试一次。
                // 两条路都失败才走失败路径（文件确缺等真错误）。
                if await externalRenderer.isDaemonResponsive() != true {
                    if await forceRecycleExternalRenderer(reason: "setUnresponsive") {
                        didRecycleRendererDuringApply = true
                        response = await externalRenderer.sendCommand(
                            cmd,
                            screen: screenIndex,
                            timeout: Self.externalRendererSetCommandTimeout
                        )
                    }
                } else {
                    response = await externalRenderer.sendCommand(
                        cmd,
                        screen: screenIndex,
                        timeout: Self.externalRendererSetCommandTimeout
                    )
                }
            }
            if response?.hasPrefix("OK") != true {
                AppLogger.error(.wallpaper, "子进程 set 命令失败", metadata: [
                    "screenID": screenID,
                    "screenIndex": screenIndex,
                    "response": response ?? "nil",
                    "requestID": requestID,
                    "targetScreens": captureScreens.map(\.wallpaperScreenIdentifier)
                        .joined(separator: ",")
                ])
                if externalRequestIDByScreenID[screenID] == requestID {
                    externalRequestIDByScreenID.removeValue(forKey: screenID)
                }
                failedScreens.append(screenID)
                continue
            }
            syncExternalPosterPath(for: screen, posterURL: posterURL)
            rememberExternalOwnedScreen(screen)

            // Crop after the incoming video size is known. Applying it immediately
            // would reshape the outgoing freeze frame to the new clip's geometry
            // and flash black letterbox during an A→B handoff.
            if !deferredVideoScreens.contains(where: {
                $0.wallpaperScreenIdentifier == screenID
            }) {
                applyCropToScreen(screen)
            }
            scheduleVideoLetterboxAnalysis(screenID: screenID, videoURL: playbackURL)
            prepareExternalFrameInterpolation(
                screenID: screenID,
                screen: screen,
                videoURL: localFileURL
            )

            // 供 crop/letterbox 使用真实视频尺寸；首帧路径不依赖这个异步结果。
            Task { [weak self, videoURL = playbackURL, screenID, requestID] in
                let asset = AVURLAsset(url: videoURL)
                guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                      let size = try? await track.load(.naturalSize),
                      size.width > 0, size.height > 0 else { return }
                await MainActor.run {
                    guard let self,
                          self.externalRenderingActive,
                          self.externalRequestIDByScreenID[screenID] == requestID,
                          (
                              self.frameInterpolatedPlaybackURLByScreen[screenID]
                                  ?? self.videoURLByScreen[screenID]
                          )?.standardizedFileURL == videoURL.standardizedFileURL else {
                        return
                    }
                    self.videoSizes[screenID] = size
                    if !self.externalPendingCommitScreenIDs.contains(screenID),
                       let currentScreen = self.externalScreen(for: screenIndex) {
                        self.applyCropToScreen(currentScreen)
                    }
                }
            }
        }

        guard failedScreens.isEmpty else {
            AppLogger.error(.wallpaper, "外部视频至少一块屏幕设置失败", metadata: [
                "screens": failedScreens.sorted().joined(separator: ",")
            ])
            await rollbackExternalVideoTransaction(
                requestID: requestID,
                rollback: externalRollback,
                targetScreens: captureScreens,
                preservedVideoScreens: deferredVideoScreens,
                reason: "setCommandFailed"
            )
            throw NSError(
                domain: "VideoWallpaper",
                code: 2003,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "视频渲染子进程无法为所有目标显示器建立播放管线"
                ]
            )
        }

        if !shouldSkipStaticPosterForDynamicLockScreen, let posterURL {
            for screen in captureScreens {
                if animatedTransition {
                    registerPendingPosterBackplate(
                        posterURL,
                        targetScreen: screen
                    )
                    schedulePosterAsDesktopWallpaperAfterPlaybackSettles(
                        posterURL,
                        targetScreen: screen,
                        expectedVideoURL: localFileURL
                    )
                } else if posterURL.isFileURL {
                    applyPosterAsDesktopWallpaperSync(posterURL, targetScreen: screen)
                } else {
                    setPosterAsDesktopWallpaper(posterURL, targetScreen: screen)
                }
            }
        }

        let grainEnabled = ArcBackgroundSettings.shared.grainTextureEnabled
        let grainIntensity = grainEnabled
            ? ArcBackgroundSettings.shared.grainIntensity
            : 0
        externalRenderer.sendCommandFireAndForget(
            .setGrainOverlay(screen: nil, intensity: grainIntensity)
        )

        // 更新持久化状态
        if targetScreen == nil {
            videoTargetScreenIDs = Set(captureScreens.map(\.wallpaperScreenIdentifier))
            videoTargetScreenFingerprints = Set(captureScreens.map(\.wallpaperScreenFingerprint))
        } else {
            videoTargetScreenIDs.formUnion(captureScreens.map(\.wallpaperScreenIdentifier))
            videoTargetScreenFingerprints.formUnion(captureScreens.map(\.wallpaperScreenFingerprint))
        }
        currentVideoURL = localFileURL
        currentPosterURL = posterURL
        wallpaperChangeCount &+= 1
        discardOriginalWallpaperSnapshot()
        lastAppliedScreenConfigurations = currentTargetScreenConfigurations()
        persistState()
        syncCurrentVideoURL()
        DynamicWallpaperAutoPauseManager.shared.clearForegroundPauseForWallpaperSwitch()
        DynamicWallpaperAutoPauseManager.shared.reevaluateCurrentState()

        if !oldExternalScreens.isEmpty || !deferredVideoScreens.isEmpty {
            scheduleExternalTransitionCommit(
                crossTypeScreens: oldExternalScreens,
                videoReplacementScreens: deferredVideoScreens,
                allTargetScreens: captureScreens,
                generation: transitionGeneration,
                requestID: requestID,
                rollback: externalRollback,
                animated: animatedTransition
            )
        }

        if didRecycleRendererDuringApply {
            // 换代重启会连带丢失未包含在本批 target 内的其他屏播放窗口；
            // 延迟重建它们（等本批 commit 流程先走完）。
            let coveredIDs = Set(captureScreens.map(\.wallpaperScreenIdentifier))
            let hasUncovered = externalTargetScreens().contains {
                !coveredIDs.contains($0.wallpaperScreenIdentifier)
            }
            if hasUncovered {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                    Task { @MainActor [weak self] in
                        await self?.reconfigureExternalRendererForCurrentScreens(
                            reason: "postRecycleRebuild",
                            clearExistingRendererState: false
                        )
                    }
                }
            }
        }

        if #available(macOS 26.0, *) {
            LockScreenWallpaperService.shared.syncInstanceCatalogToSocketServer()
            syncAllDisplayVideosToExtension()
        }

        // 播完即换：为下一次切换预暖下一条视频的解码管线
        prewarmNextOnEndWallpaperForExternalRenderer()

        AppLogger.info(.wallpaper, "applyVideoWallpaperViaExternalRenderer 完成")
    }

    /// `set` only confirms player/window creation. A mixed multi-display
    /// transaction can contain both video replacements and Scene/Web/static
    /// handoffs, so all pending screens must become drawable before either side
    /// is committed. This keeps a global switch atomic across renderer types.
    private func scheduleExternalTransitionCommit(
        crossTypeScreens: [NSScreen],
        videoReplacementScreens: [NSScreen],
        allTargetScreens: [NSScreen],
        generation: UInt64,
        requestID: String,
        rollback: ExternalTransitionSourceRollback,
        animated: Bool
    ) {
        let uniqueCrossTypeScreens = uniqueScreens(crossTypeScreens)
        let uniqueVideoScreens = uniqueScreens(videoReplacementScreens)
        let pendingScreens = uniqueScreens(uniqueCrossTypeScreens + uniqueVideoScreens)
        guard !pendingScreens.isEmpty else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.waitForExternalPresentationReady(
                    on: pendingScreens,
                    generation: generation,
                    timeout: uniqueVideoScreens.isEmpty ? 12 : 30
                )
                guard self.externalTransitionGeneration == generation else { return }

                if !uniqueVideoScreens.isEmpty {
                    let response = await self.externalRenderer.sendCommand(
                        .commitTransition(requestID: requestID),
                        screen: nil,
                        timeout: 2.0
                    )
                    guard response?.hasPrefix("OK") == true else {
                        throw NSError(
                            domain: "VideoWallpaper",
                            code: 2007,
                            userInfo: [NSLocalizedDescriptionKey: "视频交叉淡入提交失败"]
                        )
                    }
                }

                if !uniqueCrossTypeScreens.isEmpty {
                    await self.finishCrossTypeVideoHandoff(on: uniqueCrossTypeScreens)
                }

                guard self.externalTransitionGeneration == generation else { return }
                for screen in pendingScreens {
                    let screenID = screen.wallpaperScreenIdentifier
                    self.externalPendingCommitScreenIDs.remove(screenID)
                    // 播完即换结束时 renderer 已盖 poster；pendingCommit 期间
                    // firstFrameReady 会跳过 hidePoster，commit 成功后这里必须
                    // 补发一次，否则新视频被 poster 永久遮挡（与子进程 commit
                    // 回调互为双保险）。
                    if !self.externalIsPaused(screenID: screenID) {
                        self.hidePosterImage(for: screenID)
                    }
                    if let liveScreen = self.externalScreen(
                        for: self.externalScreenIndex(for: screen) ?? -1,
                        stableScreenID: screenID
                    ) {
                        self.applyCropToScreen(liveScreen)
                    }
                    self.scheduleDisplaySwitchStableRelease(
                        screenID: screenID,
                        reason: "externalTransitionCommitted"
                    )
                }
            } catch {
                guard self.externalTransitionGeneration == generation else { return }
                // Scene/Web 已经让位给视频 apply。首帧超时也不能把旧 Scene
                // 留在桌面上盖住 0.02 的预热视频窗。
                if !uniqueCrossTypeScreens.isEmpty {
                    AppLogger.error(.wallpaper, "跨类型视频交接超时，仍揭开视频并拆掉旧 Scene/Web", metadata: [
                        "requestID": requestID,
                        "error": error.localizedDescription
                    ])
                    if !uniqueVideoScreens.isEmpty {
                        _ = await self.externalRenderer.sendCommand(
                            .commitTransition(requestID: requestID),
                            screen: nil,
                            timeout: 2.0
                        )
                    }
                    await self.finishCrossTypeVideoHandoff(on: uniqueCrossTypeScreens)
                    for screen in pendingScreens {
                        self.externalPendingCommitScreenIDs.remove(
                            screen.wallpaperScreenIdentifier
                        )
                    }
                    return
                }
                // daemon 活而不答时 rollback 的 IPC 命令全部无效（旧内容已随
                // 死 daemon 消失）：直接换代重启并按最新状态重建，跳过回滚。
                if await self.externalRenderer.isDaemonResponsive() != true {
                    AppLogger.error(.wallpaper, "外部视频事务失败且 renderer 无响应，换代重建", metadata: [
                        "requestID": requestID,
                        "error": error.localizedDescription
                    ])
                    if await self.forceRecycleExternalRenderer(reason: "commitFailed"),
                       self.externalRenderer.isRunning {
                        await self.reconfigureExternalRendererForCurrentScreens(
                            reason: "stuckRendererRecovery",
                            clearExistingRendererState: false
                        )
                    }
                    return
                }
                await self.rollbackExternalVideoTransaction(
                    requestID: requestID,
                    rollback: rollback,
                    targetScreens: allTargetScreens,
                    preservedVideoScreens: uniqueVideoScreens,
                    reason: "firstFrameOrCommitFailed"
                )
                AppLogger.error(.wallpaper, "外部视频事务失败，已保留旧内容", metadata: [
                    "requestID": requestID,
                    "error": error.localizedDescription,
                    "screens": pendingScreens.map(\.wallpaperScreenIdentifier)
                        .sorted()
                        .joined(separator: ",")
                ])
            }
        }
    }

    private func finishCrossTypeVideoHandoff(on screens: [NSScreen]) async {
        let unique = uniqueScreens(screens)
        guard !unique.isEmpty else { return }
        await WallpaperCrossTypeTransitionCoordinator.shared.commitPreparedContent(
            on: unique,
            revealPreparedContent: {
                for screen in unique {
                    guard let screenIndex = self.externalScreenIndex(for: screen) else {
                        continue
                    }
                    let response = await self.externalRenderer.sendCommand(
                        .revealPreparedWindow(screen: screenIndex),
                        screen: screenIndex,
                        timeout: 2.0
                    )
                    if response?.hasPrefix("OK") != true {
                        AppLogger.error(.wallpaper, "跨类型视频窗口揭示失败", metadata: [
                            "screenID": screen.wallpaperScreenIdentifier,
                            "response": response ?? "nil"
                        ])
                    }
                }
            }
        ) {
            for screen in unique {
                await WallpaperEngineXBridge.shared
                    .ensureStoppedForNonCLIWallpaperForTransition(for: screen)
                StaticImageWallpaperOverlayManager.shared.clearState(for: screen)
                self.pendingCrossTypeVideoScreenIDs.remove(
                    screen.wallpaperScreenIdentifier
                )
            }
        }
    }

    private func uniqueScreens(_ screens: [NSScreen]) -> [NSScreen] {
        Array(
            Dictionary(
                screens.map { ($0.wallpaperScreenIdentifier, $0) },
                uniquingKeysWith: { first, _ in first }
            ).values
        )
    }

    private func rollbackExternalVideoTransaction(
        requestID: String,
        rollback: ExternalTransitionSourceRollback,
        targetScreens: [NSScreen],
        preservedVideoScreens: [NSScreen],
        reason: String
    ) async {
        let preservedScreenIDs = Set(
            preservedVideoScreens.map(\.wallpaperScreenIdentifier)
        )

        if externalRenderer.isRunning, !preservedScreenIDs.isEmpty {
            externalRenderer.sendCommandFireAndForget(
                .cancelTransition(requestID: requestID)
            )
        }

        if externalRenderer.isRunning {
            for screen in targetScreens
                where !preservedScreenIDs.contains(screen.wallpaperScreenIdentifier) {
                guard let screenIndex = externalScreenIndex(for: screen) else { continue }
                externalRenderer.sendCommandFireAndForget(.stop(screen: screenIndex))
            }
        }

        for screen in targetScreens {
            resetVideoLetterboxState(for: screen.wallpaperScreenIdentifier)
            resetFrameInterpolationState(for: screen.wallpaperScreenIdentifier)
        }
        restoreExternalTransitionSourceState(rollback)

        if externalRenderer.isRunning, rollback.externalRenderingActive {
            externalRenderer.sendCommandFireAndForget(.setMuted(rollback.isMuted))
            for screen in targetScreens {
                let screenID = screen.wallpaperScreenIdentifier
                let hasRestoredVideo =
                    rollback.videoURLByScreen[screenID] != nil
                    || rollback.videoURLByScreenFingerprint[
                        screen.wallpaperScreenFingerprint
                    ] != nil
                guard hasRestoredVideo,
                      let screenIndex = externalScreenIndex(for: screen) else {
                    continue
                }
                externalRenderer.sendCommandFireAndForget(
                    .setVolume(
                        screen: screenIndex,
                        volume: volume(for: screen)
                    )
                )
                if rollback.isPaused
                    || rollback.externalPausedScreenIDs.contains(screenID) {
                    externalRenderer.sendCommandFireAndForget(.pause(screen: screenIndex))
                    showPosterImage(for: screenID)
                } else {
                    externalRenderer.sendCommandFireAndForget(.resume(screen: screenIndex))
                    hidePosterImage(for: screenID)
                }
                applyCropToScreen(screen)
                if let playbackURL = rollback.frameInterpolatedPlaybackURLByScreen[screenID]
                    ?? rollback.videoURLByScreen[screenID]
                    ?? rollback.videoURLByScreenFingerprint[
                        screen.wallpaperScreenFingerprint
                    ] {
                    scheduleVideoLetterboxAnalysis(
                        screenID: screenID,
                        videoURL: playbackURL
                    )
                }
            }
        } else if externalRenderer.isRunning {
            externalRenderer.stopDaemon()
        }

        if !shouldSkipStaticPosterForDynamicLockScreen {
            for screen in targetScreens {
                if let posterURL = rollback.posterURLByScreen[
                    screen.wallpaperScreenIdentifier
                ] ?? rollback.posterURLByScreenFingerprint[
                    screen.wallpaperScreenFingerprint
                ] {
                    applyPosterAsDesktopWallpaperSync(
                        posterURL,
                        targetScreen: screen
                    )
                }
            }
        }

        releaseExternalDisplaySwitchGate(for: targetScreens, reason: reason)
    }

    private func restoreExternalTransitionSourceState(
        _ rollback: ExternalTransitionSourceRollback
    ) {
        currentVideoURL = rollback.currentVideoURL
        currentPosterURL = rollback.currentPosterURL
        isMuted = rollback.isMuted
        isPaused = rollback.isPaused
        usesSharedVideoDecoder = rollback.usesSharedVideoDecoder
        externalRenderingActive = rollback.externalRenderingActive
        videoURLByScreen = rollback.videoURLByScreen
        videoURLByScreenFingerprint = rollback.videoURLByScreenFingerprint
        posterURLByScreen = rollback.posterURLByScreen
        posterURLByScreenFingerprint = rollback.posterURLByScreenFingerprint
        videoTargetScreenIDs = rollback.videoTargetScreenIDs
        videoTargetScreenFingerprints = rollback.videoTargetScreenFingerprints
        externalPausedScreenIDs = rollback.externalPausedScreenIDs
        externalRequestIDByScreenID = rollback.externalRequestIDByScreenID
            externalPresentedScreenIDs = rollback.externalPresentedScreenIDs
            externalOwnedScreenIDs = rollback.externalOwnedScreenIDs
            externalFirstFrameReadyScreenIDs =
                rollback.externalFirstFrameReadyScreenIDs
        externalPendingCommitScreenIDs = rollback.externalPendingCommitScreenIDs
        externalCropRevisionByScreenID = rollback.externalCropRevisionByScreenID
        videoSizes = rollback.videoSizes
        videoLetterboxContentCrops = rollback.videoLetterboxContentCrops
        frameInterpolationDecisionsByScreen =
            rollback.frameInterpolationDecisionsByScreen
        frameInterpolatedPlaybackURLByScreen =
            rollback.frameInterpolatedPlaybackURLByScreen
        persistState()
    }

    private func releaseExternalDisplaySwitchGate(
        for screens: [NSScreen],
        reason: String
    ) {
        let screenIDs = Set(screens.map(\.wallpaperScreenIdentifier))
        guard let activeDisplaySwitchScreenID,
              screenIDs.contains(activeDisplaySwitchScreenID) else {
            return
        }
        releaseDisplaySwitchGate(
            screenID: activeDisplaySwitchScreenID,
            reason: reason
        )
    }

    private func clearExternalDisplaySwitchState(
        for targetScreen: NSScreen?,
        reason: String
    ) {
        if let targetScreen {
            let screenID = targetScreen.wallpaperScreenIdentifier
            pendingDisplaySwitches.removeValue(forKey: screenID)
            if activeDisplaySwitchScreenID == screenID {
                releaseDisplaySwitchGate(
                    screenID: screenID,
                    reason: reason
                )
            }
            return
        }

        displaySwitchReleaseWorkItem?.cancel()
        displaySwitchReleaseWorkItem = nil
        activeDisplaySwitchScreenID = nil
        pendingDisplaySwitches.removeAll()
    }

    private func waitForExternalPresentationReady(
        on screens: [NSScreen],
        generation: UInt64,
        timeout: TimeInterval
    ) async throws {
        let expectedIDs = Set(screens.map(\.wallpaperScreenIdentifier))
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            guard externalTransitionGeneration == generation else {
                throw NSError(
                    domain: "VideoWallpaper",
                    code: 2004,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "视频首帧交接已被新的壁纸请求取代"
                    ]
                )
            }
            guard externalRenderingActive, externalRenderer.isRunning else {
                throw NSError(
                    domain: "VideoWallpaper",
                    code: 2005,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "视频渲染子进程在首帧前退出"
                    ]
                )
            }
            if expectedIDs.isSubset(of: externalFirstFrameReadyScreenIDs) {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw NSError(
            domain: "VideoWallpaper",
            code: 2006,
            userInfo: [NSLocalizedDescriptionKey: "视频渲染子进程首帧等待超时"]
        )
    }

    /// Scene/Web/static requests call this before preparing their replacement.
    /// It prevents an older video-first-frame task from stopping the newer
    /// renderer after a rapid cross-type switch.
    func cancelPendingExternalVideoTransition(reason: String) {
        guard externalRenderingActive else { return }
        externalTransitionGeneration &+= 1
        let pendingScreens = externalTargetScreens().filter {
            !externalPresentedScreenIDs.contains($0.wallpaperScreenIdentifier)
                || externalPendingCommitScreenIDs.contains($0.wallpaperScreenIdentifier)
        }
        let pendingRequestIDs = Set(
            pendingScreens.compactMap { externalRequestIDByScreenID[$0.wallpaperScreenIdentifier] }
        )
        for requestID in pendingRequestIDs {
            externalRenderer.sendCommandFireAndForget(
                .cancelTransition(requestID: requestID)
            )
        }
        for screen in pendingScreens {
            if let screenIndex = externalScreenIndex(for: screen) {
                externalRenderer.sendCommandFireAndForget(.stop(screen: screenIndex))
            }
            let screenID = screen.wallpaperScreenIdentifier
            externalRequestIDByScreenID.removeValue(forKey: screenID)
            externalFirstFrameReadyScreenIDs.remove(screenID)
            externalPresentedScreenIDs.remove(screenID)
            externalOwnedScreenIDs.remove(screenID)
            externalPausedScreenIDs.remove(screenID)
            externalPendingCommitScreenIDs.remove(screenID)
            videoTargetScreenIDs.remove(screenID)
            videoTargetScreenFingerprints.remove(screen.wallpaperScreenFingerprint)
            videoURLByScreen.removeValue(forKey: screenID)
            videoURLByScreenFingerprint.removeValue(forKey: screen.wallpaperScreenFingerprint)
            posterURLByScreen.removeValue(forKey: screenID)
            posterURLByScreenFingerprint.removeValue(forKey: screen.wallpaperScreenFingerprint)
            resetVideoLetterboxState(for: screenID)
            resetFrameInterpolationState(for: screenID)
        }
        if videoTargetScreenIDs.isEmpty && videoTargetScreenFingerprints.isEmpty {
            cancelExternalRendererRestart()
            externalRenderer.stopDaemon()
            externalRenderingActive = false
            currentVideoURL = nil
            currentPosterURL = nil
        } else if !pendingScreens.isEmpty {
            syncCurrentVideoURL()
            currentPosterURL = posterURLByScreen.values.first
                ?? posterURLByScreenFingerprint.values.first
            persistState()
        }
        releaseExternalDisplaySwitchGate(
            for: pendingScreens,
            reason: "cancelPendingExternalTransition"
        )
        AppLogger.debug(.wallpaper, "取消 external video 跨类型交接", metadata: [
            "reason": reason,
            "generation": externalTransitionGeneration,
            "discardedScreens": pendingScreens
                .map(\.wallpaperScreenIdentifier)
                .sorted()
                .joined(separator: ",")
        ])
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        UserDefaults.standard.set(muted, forKey: "wallpaper_is_muted")
        if externalRenderingActive {
            deactivateAudioSession()
            externalRenderer.sendCommandFireAndForget(.setMuted(muted))
            persistState()
            return
        }
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
        let sharedPlayerTargets: [NSScreen]
        if usesSharedVideoDecoder, targetScreen != nil {
            sharedPlayerTargets = externalRenderingActive
                ? externalTargetScreens()
                : screensForVideoWallpaperTargets()
        } else {
            sharedPlayerTargets = []
        }

        if externalRenderingActive {
            deactivateAudioSession()
            let commandScreen = sharedPlayerTargets.isEmpty
                ? targetScreen.flatMap(externalScreenIndex(for:))
                : nil
            if targetScreen != nil,
               sharedPlayerTargets.isEmpty,
               commandScreen == nil {
                AppLogger.error(.wallpaper, "外部视频音量目标屏已离线", metadata: [
                    "screenID": targetScreen?.wallpaperScreenIdentifier ?? "nil"
                ])
                return
            }
            if targetScreen == nil || !sharedPlayerTargets.isEmpty {
                volume = clamped
            }
            externalRenderer.sendCommandFireAndForget(
                .setVolume(screen: commandScreen, volume: clamped),
            )
        }
        if !sharedPlayerTargets.isEmpty {
            for screen in sharedPlayerTargets {
                let screenID = screen.wallpaperScreenIdentifier
                volumeByScreen[screenID] = clamped
                volumeByScreenFingerprint[screen.wallpaperScreenFingerprint] = clamped
                players[screenID]?.volume = isMuted ? 0 : Float(clamped)
            }
        } else if let targetScreen = targetScreen {
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

        if externalRenderingActive {
            externalRenderer.sendCommandFireAndForget(
                .setGrainOverlay(
                    screen: nil,
                    intensity: grainEnabled ? grainIntensity : 0
                )
            )
            return
        }

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

    func pauseWallpaper(
        for targetScreen: NSScreen? = nil,
        persistAsUserRequest: Bool = true
    ) {
        if persistAsUserRequest {
            userRequestedPause = true
        }
        if externalRenderingActive {
            if let targetScreen,
               externalPendingCommitScreenIDs.contains(targetScreen.wallpaperScreenIdentifier) {
                AppLogger.debug(.wallpaper, "外部视频暂停推迟到交接完成", metadata: [
                    "screenID": targetScreen.wallpaperScreenIdentifier
                ])
                return
            }
            if targetScreen == nil, !externalPendingCommitScreenIDs.isEmpty {
                AppLogger.debug(.wallpaper, "外部视频全局暂停推迟到交接完成")
                return
            }
            let screenIdx = targetScreen.flatMap(externalScreenIndex(for:))
            AppLogger.debug(.wallpaper, "外部视频暂停入口", metadata: [
                "target": targetScreen?.localizedName ?? "all",
                "screenIdx": screenIdx.map(String.init) ?? "nil",
                "rendererRunning": String(externalRenderer.isRunning)
            ])
            if let targetScreen, screenIdx == nil {
                AppLogger.error(.wallpaper, "外部视频暂停目标屏已离线", metadata: [
                    "screenID": targetScreen.wallpaperScreenIdentifier
                ])
                return
            }
            if let targetScreen {
                externalPausedScreenIDs.insert(targetScreen.wallpaperScreenIdentifier)
                let activeScreenIDs = Set(externalTargetScreens().map(\.wallpaperScreenIdentifier))
                isPaused = !activeScreenIDs.isEmpty
                    && activeScreenIDs.isSubset(of: externalPausedScreenIDs)
            } else {
                isPaused = true
                externalPausedScreenIDs.formUnion(videoTargetScreenIDs)
            }
            // Put the cover in front before pausing the child. This closes the
            // small handoff window where AVPlayerLayer can clear its drawable
            // before the awaited pause response returns.
            let screensToPause = targetScreen.map { [$0] } ?? externalTargetScreens()
            for screen in screensToPause {
                showPosterImage(for: screen.wallpaperScreenIdentifier)
            }
            queueExternalPauseWithPoster(
                screenIndex: screenIdx,
                targetScreen: targetScreen
            )
            persistState()
            return
        }
        if let targetScreen = targetScreen {
            let screenID = targetScreen.wallpaperScreenIdentifier
            if let player = players[screenID] {
                // 同文件多屏共用一条解码管线时，单屏暂停只能遮住该屏画面，
                // 不能暂停共享 player，否则仍引用它的其它屏也会一起停止。
                if screenIDsReferencingPlayer(player).count == 1 {
                    player.pause()
                    player.rate = 0
                }
            }
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

    func resumeWallpaper(
        for targetScreen: NSScreen? = nil,
        persistAsUserRequest: Bool = true
    ) {
        guard hasActiveVideoWallpaper else { return }
        if persistAsUserRequest {
            userRequestedPause = false
        } else if userRequestedPause {
            return
        }

        if externalRenderingActive {
            if let targetScreen,
               externalPendingCommitScreenIDs.contains(targetScreen.wallpaperScreenIdentifier) {
                scheduleDeferredResume(
                    for: targetScreen,
                    persistAsUserRequest: persistAsUserRequest
                )
                return
            }
            if targetScreen == nil, !externalPendingCommitScreenIDs.isEmpty {
                scheduleDeferredResume(
                    for: nil,
                    persistAsUserRequest: persistAsUserRequest
                )
                return
            }
            let screenIdx = targetScreen.flatMap(externalScreenIndex(for:))
            if let targetScreen, screenIdx == nil {
                AppLogger.error(.wallpaper, "外部视频恢复目标屏已离线", metadata: [
                    "screenID": targetScreen.wallpaperScreenIdentifier
                ])
                return
            }
            if let targetScreen {
                externalPausedScreenIDs.remove(targetScreen.wallpaperScreenIdentifier)
                let activeScreenIDs = Set(externalTargetScreens().map(\.wallpaperScreenIdentifier))
                isPaused = !activeScreenIDs.isEmpty
                    && activeScreenIDs.isSubset(of: externalPausedScreenIDs)
            } else {
                isPaused = false
                externalPausedScreenIDs.removeAll()
            }
            queueExternalResumeAndHidePoster(
                screenIndex: screenIdx,
                targetScreen: targetScreen
            )
            persistState()
            return
        }

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

    private func scheduleDeferredResume(
        for targetScreen: NSScreen?,
        persistAsUserRequest: Bool
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            if persistAsUserRequest {
                guard !self.userRequestedPause || self.isPaused else { return }
            } else if self.userRequestedPause {
                return
            }
            self.resumeWallpaper(
                for: targetScreen,
                persistAsUserRequest: persistAsUserRequest
            )
        }
    }

    /// Drop in-flight pause/resume so a stale pause cannot land on the incoming
    /// player after `set`. Generation bump makes the queued task no-op.
    private func invalidateExternalPlaybackControl(reason: String) {
        guard externalPlaybackControlTask != nil else { return }
        externalPlaybackControlGeneration &+= 1
        externalPlaybackControlTask?.cancel()
        externalPlaybackControlTask = nil
        AppLogger.debug(.wallpaper, "作废排队中的外部播放控制", metadata: [
            "reason": reason
        ])
    }

    /// 等待排队的暂停/恢复任务完成；异常卡死时最多等 15s，避免拖住事务门
    /// （卡死的任务链会随 renderer 重启自然失效）。
    private func waitForExternalPlaybackControl() async {
        let waitStart = Date()
        while let task = externalPlaybackControlTask {
            let remaining = 15.0 - Date().timeIntervalSince(waitStart)
            guard remaining > 0 else {
                AppLogger.error(.wallpaper, "外部播放控制任务超时，跳过等待")
                return
            }
            let lock = NSLock()
            var didResume = false
            let finished = await withCheckedContinuation { continuation in
                let resumeOnce: (Bool) -> Void = { value in
                    lock.lock()
                    guard !didResume else {
                        lock.unlock()
                        return
                    }
                    didResume = true
                    lock.unlock()
                    continuation.resume(returning: value)
                }
                Task { @MainActor in
                    await task.value
                    resumeOnce(true)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + remaining) {
                    resumeOnce(false)
                }
            }
            guard finished else {
                AppLogger.error(.wallpaper, "外部播放控制任务超时，跳过等待")
                return
            }
        }
    }

    private func enqueueExternalPlaybackControl(
        _ operation: @escaping @MainActor (VideoWallpaperManager) async -> Void
    ) {
        externalPlaybackControlGeneration &+= 1
        let generation = externalPlaybackControlGeneration
        let previousTask = externalPlaybackControlTask
        let task = Task { @MainActor [weak self] in
            if let previousTask {
                await previousTask.value
            }
            guard let self,
                  self.externalPlaybackControlGeneration == generation else {
                return
            }
            await operation(self)
            if self.externalPlaybackControlGeneration == generation {
                self.externalPlaybackControlTask = nil
            }
        }
        externalPlaybackControlTask = task
    }

    private func queueExternalPauseWithPoster(
        screenIndex: Int?,
        targetScreen: NSScreen?
    ) {
        enqueueExternalPlaybackControl { manager in
            if let targetScreen,
               manager.externalPendingCommitScreenIDs.contains(
                   targetScreen.wallpaperScreenIdentifier
               ) {
                AppLogger.debug(.wallpaper, "外部视频暂停已过期：交接进行中", metadata: [
                    "screenID": targetScreen.wallpaperScreenIdentifier
                ])
                return
            }
            guard manager.externalRenderingActive,
                  manager.externalRenderer.isRunning else {
                AppLogger.error(.wallpaper, "外部视频暂停被丢弃：renderer 未运行", metadata: [
                    "extActive": String(manager.externalRenderingActiveForDiagnostics),
                    "screen": screenIndex.map(String.init) ?? "all"
                ])
                return
            }

            let response = await manager.sendExternalPlaybackControl(
                .pause(screen: screenIndex),
                screen: screenIndex
            )
            guard response?.hasPrefix("OK") == true else {
                AppLogger.error(.wallpaper, "外部视频暂停命令失败", metadata: [
                    "screen": screenIndex.map(String.init) ?? "all",
                    "response": response ?? "nil"
                ])
                return
            }
            AppLogger.debug(.wallpaper, "外部视频暂停命令成功 ✓", metadata: [
                "screen": screenIndex.map(String.init) ?? "all",
                "response": response ?? ""
            ])

            let screens = targetScreen.map { [$0] } ?? manager.externalTargetScreens()
            for screen in screens {
                await manager.showExternalPosterAwaitingCommand(for: screen)
            }
        }
    }

    private func queueExternalResumeAndHidePoster(
        screenIndex: Int?,
        targetScreen: NSScreen?
    ) {
        enqueueExternalPlaybackControl { manager in
            if let targetScreen,
               manager.externalPendingCommitScreenIDs.contains(
                   targetScreen.wallpaperScreenIdentifier
               ) {
                return
            }
            guard manager.externalRenderingActive,
                  manager.externalRenderer.isRunning else {
                AppLogger.error(.wallpaper, "外部视频恢复被丢弃：renderer 未运行", metadata: [
                    "extActive": String(manager.externalRenderingActiveForDiagnostics),
                    "screen": screenIndex.map(String.init) ?? "all"
                ])
                return
            }

            let response = await manager.sendExternalPlaybackControl(
                .resume(screen: screenIndex),
                screen: screenIndex
            )
            guard response?.hasPrefix("OK") == true else {
                AppLogger.error(.wallpaper, "外部视频恢复命令失败", metadata: [
                    "screen": screenIndex.map(String.init) ?? "all",
                    "response": response ?? "nil"
                ])
                if let targetScreen {
                    let screenID = targetScreen.wallpaperScreenIdentifier
                    manager.externalPausedScreenIDs.insert(screenID)
                    let activeScreenIDs = Set(
                        manager.externalTargetScreens().map(\.wallpaperScreenIdentifier)
                    )
                    manager.isPaused = !activeScreenIDs.isEmpty
                        && activeScreenIDs.isSubset(
                            of: manager.externalPausedScreenIDs
                        )
                } else {
                    manager.isPaused = true
                    manager.externalPausedScreenIDs.formUnion(
                        manager.videoTargetScreenIDs
                    )
                }
                return
            }

            let screens = targetScreen.map { [$0] } ?? manager.externalTargetScreens()
            for screen in screens {
                await manager.hideExternalPosterAwaitingCommand(for: screen)
            }
        }
    }

    /// Playback control can time out while a previous renderer command is
    /// still unwinding on the child main actor. Retry once behind that command
    /// so the host state does not diverge from the actual player state.
    private func sendExternalPlaybackControl(
        _ command: VideoRendererProcessController.Command,
        screen: Int?
    ) async -> String? {
        var response = await externalRenderer.sendCommand(
            command,
            screen: screen,
            timeout: Self.externalRendererPlaybackControlTimeout
        )
        guard response?.hasPrefix("OK") != true else {
            return response
        }
        try? await Task.sleep(for: .milliseconds(150))
        response = await externalRenderer.sendCommand(
            command,
            screen: screen,
            timeout: Self.externalRendererPlaybackControlTimeout
        )
        return response
    }

    private func showExternalPosterAwaitingCommand(for screen: NSScreen) async {
        let screenID = screen.wallpaperScreenIdentifier
        guard externalRenderingActive,
              let currentScreen = NSScreen.screens.first(where: {
                  $0.wallpaperScreenIdentifier == screenID
              }),
              let requestedPosterURL = posterURL(for: currentScreen) else {
            return
        }

        let localURL: URL?
        if requestedPosterURL.isFileURL,
           FileManager.default.fileExists(atPath: requestedPosterURL.path) {
            localURL = requestedPosterURL
        } else {
            localURL = await materializeExternalPoster(
                requestedPosterURL,
                screenID: screenID
            )
        }
        guard let localURL,
              externalRenderingActive,
              posterURL(for: currentScreen)?.standardizedFileURL
                  == requestedPosterURL.standardizedFileURL,
              let currentIndex = externalScreenIndex(for: currentScreen) else {
            return
        }

        let response = await externalRenderer.sendCommand(
            .showPoster(screen: currentIndex, path: localURL.path),
            screen: currentIndex,
            timeout: Self.externalRendererPlaybackControlTimeout
        )
        guard response?.hasPrefix("OK") == true else {
            AppLogger.error(.wallpaper, "外部视频 poster 显示命令失败", metadata: [
                "screen": currentIndex,
                "response": response ?? "nil"
            ])
            return
        }
    }

    private func hideExternalPosterAwaitingCommand(for screen: NSScreen) async {
        let screenID = screen.wallpaperScreenIdentifier
        guard externalRenderingActive,
              !externalPendingCommitScreenIDs.contains(screenID),
              !externalIsPaused(screenID: screenID),
              let currentScreen = NSScreen.screens.first(where: {
                  $0.wallpaperScreenIdentifier == screenID
              }),
              let screenIndex = externalScreenIndex(for: currentScreen) else {
            return
        }

        let response = await externalRenderer.sendCommand(
            .hidePoster(screen: screenIndex),
            screen: screenIndex,
            timeout: Self.externalRendererPlaybackControlTimeout
        )
        guard response?.hasPrefix("OK") == true else {
            AppLogger.error(.wallpaper, "外部视频 poster 隐藏命令失败", metadata: [
                "screen": screenIndex,
                "response": response ?? "nil"
            ])
            return
        }
    }

    /// Restores the just-finished video when the scheduler cannot apply any valid
    /// successor in "Play to End" mode. The poster stays visible until the first frame
    /// is ready, so a failed rotation cannot leave the desktop black.
    func resumeOnEndVideoAfterFailedSwitch(for targetScreen: NSScreen) {
        if externalRenderingActive {
            guard let screenIndex = externalScreenIndex(for: targetScreen) else { return }
            showPosterImage(for: targetScreen.wallpaperScreenIdentifier)
            externalRenderer.sendCommandFireAndForget(
                .seek(screen: screenIndex, time: 0)
            )
            guard !isPaused else { return }
            externalRenderer.sendCommandFireAndForget(.resume(screen: screenIndex))
            externalPausedScreenIDs.remove(targetScreen.wallpaperScreenIdentifier)
            hidePosterImage(for: targetScreen.wallpaperScreenIdentifier)
            return
        }
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

    /// Global sync can attach one player to several display windows. When a
    /// rotation fails, restore every poster layer that observed that player.
    func resumeOnEndVideosAfterFailedGlobalSwitch(for targetScreens: [NSScreen]) {
        if externalRenderingActive {
            for screen in targetScreens {
                resumeOnEndVideoAfterFailedSwitch(for: screen)
            }
            return
        }
        var playerGroups: [(player: AVQueuePlayer, screenIDs: [String])] = []

        for screen in targetScreens {
            let screenID = screen.wallpaperScreenIdentifier
            guard let player = players[screenID] else { continue }

            if let index = playerGroups.firstIndex(where: { $0.player === player }) {
                playerGroups[index].screenIDs.append(screenID)
            } else {
                playerGroups.append((player: player, screenIDs: [screenID]))
            }
            showPosterImage(for: screenID)
        }

        for group in playerGroups {
            group.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak player = group.player] _ in
                guard let player else { return }
                DispatchQueue.main.async {
                    guard let self, !self.isPaused else { return }
                    player.play()
                    for screenID in group.screenIDs where self.players[screenID] === player {
                        self.hidePosterImage(for: screenID)
                    }
                }
            }
        }
    }

    /// 获取当前正在播放动态壁纸的显示器
    var activeScreens: [NSScreen] {
        if externalRenderingActive {
            return externalTargetScreens()
        }
        let activeScreenIDs = Set(players.keys)
        return NSScreen.screens.filter { screen in
            activeScreenIDs.contains(screen.wallpaperScreenIdentifier)
        }
    }

    /// 当前仍在输出帧的屏幕集合；已被暂停（rate == 0）的屏幕不包含在内。
    var playingScreenIDs: Set<String> {
        if externalRenderingActive {
            return Set(externalTargetScreens().compactMap { screen in
                let screenID = screen.wallpaperScreenIdentifier
                return externalIsPaused(screenID: screenID) ? nil : screenID
            })
        }
        return Set(players.compactMap { screenID, player in
            player.rate != 0 ? screenID : nil
        })
    }

    /// 检测指定屏幕是否有正在播放的动态壁纸
    func hasActiveWallpaper(on screen: NSScreen) -> Bool {
        let screenID = screen.wallpaperScreenIdentifier
        if externalRenderingActive {
            return videoTargetScreenIDs.contains(screenID)
                || videoTargetScreenFingerprints.contains(screen.wallpaperScreenFingerprint)
        }
        return players[screenID] != nil
    }

    /// 跨类型切换在新内容准备期间需要保留旧视频窗口。调用方用这个快照决定
    /// 是立即 teardown，还是等新内容首帧就绪后再提交。
    func hasNativeVideoWallpaper(on screens: [NSScreen]) -> Bool {
        // 子进程渲染路径：检查是否有目标屏正在通过子进程渲染
        if externalRenderingActive {
            return screens.contains {
                externalLiveVideoScreenIDs.contains($0.wallpaperScreenIdentifier)
            }
        }
        return screens.contains { screen in
            let screenID = screen.wallpaperScreenIdentifier
            return presentedVideoScreenIDs.contains(screenID) && windows[screenID] != nil
        }
    }

    /// Scene/Web 会在旧视频仍播放时创建同级 desktop window。加载窗口默认会被
    /// WindowServer 放到同层最前，造成“新第一帧提前闪一下”。准备阶段周期性
    /// 把旧视频窗提回最前即可让新内容在后方持续播放、完全不可见地预热。
    func keepNativeVideoPresentationFront(on screens: [NSScreen]) {
        // 子进程窗口不属于主进程的 NSWindow 集合。它在设置新 Scene/Web
        // 期间保持自己的桌面层；真正的交接由 ready/timeout 状态机在提交点
        // 调用 stopNativeVideoWallpaperOnly 完成。
        if externalRenderingActive {
            for screen in screens {
                guard externalPresentedScreenIDs.contains(
                    screen.wallpaperScreenIdentifier
                ) else {
                    continue
                }
                guard let screenIndex = externalScreenIndex(for: screen) else { continue }
                externalRenderer.sendCommandFireAndForget(.bringToFront(screen: screenIndex))
            }
            return
        }
        for screen in screens {
            guard presentedVideoScreenIDs.contains(screen.wallpaperScreenIdentifier) else { continue }
            guard let entry = existingVideoWindowEntry(for: screen) else { continue }
            entry.window.orderFrontRegardless()
            entry.window.displayIfNeeded()
        }
        CATransaction.flush()
    }

    /// 对指定屏应用当前可视区域 crop 配置。在设置壁纸、布局变化、crop 变更时调用。
    /// 注：CropLayoutEngine 实际只用 screenSize（壁纸 crop 是归一化值，由 contentsRect 处理），
    /// 因此无需异步等待视频 track 加载完成。
    func applyCropToScreen(_ screen: NSScreen) {
        let screenID = screen.wallpaperScreenIdentifier
        if externalRenderingActive {
            guard let screenIndex = externalScreenIndex(for: screen) else { return }
            let settings = DisplayCropSettingsStore.shared.settings(for: screen)
            let wallpaperSize = videoSizes[screenID] ?? screen.frame.size

            let layout: CropLayout?
            if settings.shouldApplyCrop {
                layout = CropLayoutEngine.compute(
                    wallpaperSize: wallpaperSize,
                    screenSize: screen.frame.size,
                    settings: settings
                )
            } else if autoRemoveVideoLetterboxEnabled,
                      let contentCrop = videoLetterboxContentCrops[screenID] {
                layout = CropLayout(
                    wallpaperCropRect: contentCrop.cropRect,
                    viewportRect: .full,
                    letterboxColor: CGColor(gray: 0, alpha: 1)
                )
            } else {
                layout = nil
            }

            let crop = layout.map {
                CGRect(
                    x: $0.wallpaperCropRect.x,
                    y: $0.wallpaperCropRect.y,
                    width: $0.wallpaperCropRect.w,
                    height: $0.wallpaperCropRect.h
                )
            }
            let viewport = layout.map {
                CGRect(
                    x: $0.viewportRect.x,
                    y: $0.viewportRect.y,
                    width: $0.viewportRect.w,
                    height: $0.viewportRect.h
                )
            }
            let letterboxColor: String? = layout == nil
                ? settings.letterboxColorHex
                : (settings.shouldApplyCrop ? settings.letterboxColorHex : "000000")
            let revision = (externalCropRevisionByScreenID[screenID] ?? 0) &+ 1
            externalCropRevisionByScreenID[screenID] = revision
            externalRenderer.sendCommandFireAndForget(
                .setCrop(
                    screen: screenIndex,
                    crop: crop,
                    viewport: viewport,
                    letterboxColor: letterboxColor,
                    revision: revision
                )
            )
            return
        }

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

        if externalRenderingActive {
            refreshExternalFrameInterpolationPlayback()
            for screen in activeScreens {
                guard let videoURL = assignedVideoURL(for: screen)
                    ?? currentVideoURL else {
                    continue
                }
                prepareExternalFrameInterpolation(
                    screenID: screen.wallpaperScreenIdentifier,
                    screen: screen,
                    videoURL: videoURL
                )
            }
            return
        }

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
            videoLetterboxContentCrops[screenID] = cached
            if let screen = NSScreen.screens.first(where: { $0.wallpaperScreenIdentifier == screenID }) {
                applyCropToScreen(screen)
            }
            return
        }
        if videoLetterboxNoCropCache.contains(cacheKey) {
            videoLetterboxContentCrops.removeValue(forKey: screenID)
            if let screen = NSScreen.screens.first(where: { $0.wallpaperScreenIdentifier == screenID }) {
                applyCropToScreen(screen)
            }
            return
        }

        let task = Task.detached(priority: .utility) {
            await VideoLetterboxAnalyzer.analyze(url: videoURL)
        }
        let analysisRevision = "\(cacheKey)|\(UUID().uuidString)"
        videoLetterboxAnalysisRevisionByScreen[screenID] = analysisRevision
        videoLetterboxAnalysisTasks[screenID] = task

        Task { @MainActor [weak self] in
            let crop = await task.value
            guard let self else { return }
            guard self.videoLetterboxAnalysisRevisionByScreen[screenID] == analysisRevision else {
                return
            }
            self.videoLetterboxAnalysisTasks.removeValue(forKey: screenID)
            self.videoLetterboxAnalysisRevisionByScreen.removeValue(forKey: screenID)
            guard self.autoRemoveVideoLetterboxEnabled else { return }
            let currentScreen = NSScreen.screens.first(where: { $0.wallpaperScreenIdentifier == screenID })
            let currentVideoURL = self.frameInterpolatedPlaybackURLByScreen[screenID]
                ?? self.videoURLByScreen[screenID]
                ?? currentScreen.flatMap { self.videoURLByScreenFingerprint[$0.wallpaperScreenFingerprint] }
            guard let currentVideoURL,
                  currentVideoURL.standardizedFileURL == videoURL.standardizedFileURL,
                  self.videoLetterboxCacheKey(for: currentVideoURL) == cacheKey else {
                return
            }

            if let crop {
                self.videoLetterboxCropCache[cacheKey] = crop
                self.videoLetterboxContentCrops[screenID] = crop
            } else {
                self.videoLetterboxNoCropCache.insert(cacheKey)
                self.videoLetterboxContentCrops.removeValue(forKey: screenID)
            }

            if let screen = currentScreen {
                self.applyCropToScreen(screen)
            }
        }
    }

    private func videoLetterboxCacheKey(for url: URL) -> String {
        guard url.isFileURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return url.standardizedFileURL.path
        }
        let size = attrs[.size] as? UInt64 ?? 0
        let modified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        return "\(url.standardizedFileURL.path)|\(inode)|\(size)|\(modified)"
    }

    private func prepareFrameInterpolation(
        screenID: String,
        screen: NSScreen,
        videoURL: URL,
        player: AVQueuePlayer,
        item: AVPlayerItem,
        containerView: WallpaperVideoContainerView
    ) {
        let targetFPS = frameInterpolationTargetFPS(for: screen)
        // 手动补帧始终可用；设壁纸路径只做 FPS 探测与记录修复，不会自动入队。
        guard targetFPS > 0 else {
            resetFrameInterpolation(for: screenID, player: player, item: item)
            frameInterpolationDebugPrint("目标 FPS 无效：跳过补帧。目标 FPS：\(targetFPS)，视频：\(videoURL.path)")
            return
        }

        if let record = VideoOptimizationQueueService.shared.completedRecord(videoURL: videoURL, satisfying: targetFPS) {
            resetFrameInterpolation(for: screenID, player: player, item: item)
            frameInterpolationDebugPrint("已有补帧完成记录覆盖当前目标 FPS：记录 FPS=\(record.targetFPS)，目标 FPS=\(targetFPS)，跳过补帧。视频：\(videoURL.path)")
            return
        }

        if let activeTargetFPS = VideoOptimizationQueueService.shared.activeInterpolationTargetFPS(videoURL: videoURL),
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
                containerView: containerView
            )
        }
    }

    private func prepareExternalFrameInterpolation(
        screenID: String,
        screen: NSScreen,
        videoURL: URL
    ) {
        let targetFPS = frameInterpolationTargetFPS(for: screen)
        guard targetFPS > 0 else {
            frameInterpolationDecisionsByScreen.removeValue(forKey: screenID)
            return
        }

        if VideoOptimizationQueueService.shared.completedRecord(
            videoURL: videoURL,
            satisfying: targetFPS
        ) != nil {
            frameInterpolationDecisionsByScreen.removeValue(forKey: screenID)
            return
        }

        if let activeTargetFPS =
            VideoOptimizationQueueService.shared.activeInterpolationTargetFPS(
                videoURL: videoURL
            ),
           activeTargetFPS >= targetFPS {
            return
        }
        guard frameInterpolationAnalysisTasks[screenID] == nil else { return }

        let task = Task.detached(priority: .utility) {
            await VideoFrameInterpolationAnalyzer.decision(
                for: videoURL,
                targetFPS: targetFPS
            )
        }
        frameInterpolationAnalysisTasks[screenID] = task

        Task { @MainActor [weak self] in
            let decision = await task.value
            guard let self else { return }
            self.frameInterpolationAnalysisTasks.removeValue(forKey: screenID)
            guard let currentScreen = NSScreen.screens.first(where: {
                $0.wallpaperScreenIdentifier == screenID
            }),
            self.assignedVideoURL(for: currentScreen)?.standardizedFileURL
                == videoURL.standardizedFileURL else {
                return
            }
            self.frameInterpolationDecisionsByScreen[screenID] = decision
            let sourceFPS = decision.sourceFPS.map {
                String(format: "%.2f", $0)
            } ?? "未知"
            frameInterpolationDebugPrint(
                "External FPS 分析完成：原始 FPS=\(sourceFPS)，目标 FPS=\(decision.targetFPS)，是否需要补帧=\(decision.shouldInterpolate ? "是" : "否")，原因：\(decision.reason)"
            )
        }
    }

    private func applyFrameInterpolationDecision(
        _ decision: VideoFrameInterpolationDecision,
        screenID: String,
        videoURL: URL,
        player: AVQueuePlayer,
        item: AVPlayerItem,
        containerView: WallpaperVideoContainerView
    ) {
        frameInterpolationDecisionsByScreen[screenID] = decision
        let sourceFPS = decision.sourceFPS.map { String(format: "%.2f", $0) } ?? "未知"
        frameInterpolationDebugPrint("FPS 分析完成：原始 FPS=\(sourceFPS)，目标 FPS=\(decision.targetFPS)，是否需要补帧=\(decision.shouldInterpolate ? "是" : "否")，原因：\(decision.reason)")

        guard decision.shouldInterpolate else {
            if decision.reason.contains("已达到或高于目标 FPS"),
               VideoOptimizationQueueService.shared.completedRecord(videoURL: videoURL) != nil {
                VideoOptimizationQueueService.shared.markCompleted(
                    videoURL: videoURL,
                    title: videoURL.deletingPathExtension().lastPathComponent,
                    targetFPS: decision.targetFPS
                )
                frameInterpolationDebugPrint("当前文件已满足目标 FPS：已修复补帧完成记录。目标 FPS=\(decision.targetFPS)，视频：\(videoURL.path)")
            }
            resetFrameInterpolation(for: screenID, player: player, item: item)
            return
        }

        // 禁止任何自动补帧：调度/设壁纸只读现成资源。
        // 补帧只能由用户在队列里手动添加；完成后由队列原地替换源文件，
        // 若当前仍在播该路径，再统一走 reloadPlaybackAfterInPlaceInterpolation。
        frameInterpolationDebugPrint("视频需要补帧：已禁用自动入队，继续播放原资源。视频=\(videoURL.lastPathComponent)")
        resetFrameInterpolation(for: screenID, player: player, item: item)
    }

    private func replacePlayerWithInterpolatedVideoIfNeeded(
        screenID: String,
        sourceURL: URL,
        outputURL: URL,
        forceReload: Bool = false,
        markAsInterpolated: Bool = true
    ) {
        // 原地补帧完成后的播放切换不再依赖已废弃的「启用视频补帧」总开关。
        guard let screen = NSScreen.screens.first(where: { $0.wallpaperScreenIdentifier == screenID }),
              windows[screenID] != nil,
              let window = windows[screenID],
              let containerView = window.contentView as? WallpaperVideoContainerView else {
            return
        }

        // Keep the same source resolution as reloadPlaybackAfterInPlaceReplacement:
        // after sleep/reconnect a screen may only be keyed by fingerprint.
        let activeSourceURL = videoURLByScreen[screenID]
            ?? videoURLByScreenFingerprint[screen.wallpaperScreenFingerprint]
            ?? currentVideoURL
        guard activeSourceURL?.standardizedFileURL == sourceURL.standardizedFileURL else {
            return
        }
        guard forceReload
            || frameInterpolatedPlaybackURLByScreen[screenID]?.standardizedFileURL
                != outputURL.standardizedFileURL else {
            return
        }

        let oldPlayer = players[screenID]
        let oldLooper = loopers[screenID]
        let schedulerConfig = WallpaperSchedulerService.shared.config.resolvedDisplayConfig(for: screenID)
        let isOnEndMode = schedulerConfig.isEnabled && schedulerConfig.isOnEndMode
        print("[VideoWallpaperManager] Screen \(screenID): schedulerConfig.isEnabled=\(schedulerConfig.isEnabled), schedulerConfig.isOnEndMode=\(schedulerConfig.isOnEndMode), computed isOnEndMode=\(isOnEndMode), will set enableLooping=\(!isOnEndMode)")
        // Drop this screen's map entry first so resolve can reuse another screen's player,
        // but not this screen's about-to-be-replaced instance.
        players.removeValue(forKey: screenID)
        if oldLooper != nil {
            loopers.removeValue(forKey: screenID)
        }
        let components = resolvePlayerComponents(
            for: screen,
            videoURL: outputURL,
            muted: isMuted,
            enableLooping: !isOnEndMode
        )
        assignPlayerComponents(components, to: screenID)

        // Re-anchor both maps so later hot reloads do not depend on fingerprint alone.
        videoURLByScreen[screenID] = sourceURL
        videoURLByScreenFingerprint[screen.wallpaperScreenFingerprint] = sourceURL
        if markAsInterpolated {
            frameInterpolatedPlaybackURLByScreen[screenID] = outputURL
        } else {
            frameInterpolatedPlaybackURLByScreen.removeValue(forKey: screenID)
        }
        containerView.playerLayer.videoGravity = .resizeAspectFill
        containerView.attachPlayer(components.player)
        applyCropToScreen(screen)
        applyPlayerAudioPolicy(components.player, muted: isMuted, volume: volumeByScreen[screenID] ?? volume)
        if !isPaused {
            components.player.play()
        }

        if isOnEndMode {
            onEndModeScreens.insert(screenID)
            setupPlaybackEndObserver(for: screenID, player: components.player, item: components.item)
        }

        if let oldPlayer, oldPlayer !== components.player {
            releasePlayerIfUnreferenced(oldPlayer, looper: oldLooper)
            rehomePlaybackEndObserverIfNeeded(for: oldPlayer, preferredScreenID: nil)
        }
        frameInterpolationDebugPrint("播放器已刷新：优化源视频=\(sourceURL.lastPathComponent)，播放文件=\(outputURL.lastPathComponent)")
    }

    /// Rebinds the external renderer to an already completed interpolation
    /// artifact. The optimization queue replaces files in place, so the
    /// artifact is commonly the same URL; sending `set` is still required to
    /// make the child process rebuild its AVPlayer item.
    private func refreshExternalFrameInterpolationPlayback() {
        guard externalRenderingActive, externalRenderer.isRunning else { return }
        let requestID = UUID().uuidString

        for screen in externalTargetScreens() {
            let screenID = screen.wallpaperScreenIdentifier
            guard let sourceURL = videoURLByScreen[screenID]
                ?? videoURLByScreenFingerprint[screen.wallpaperScreenFingerprint]
                ?? currentVideoURL,
                  FileManager.default.fileExists(atPath: sourceURL.path),
                  let record = VideoOptimizationQueueService.shared.completedRecord(
                    videoURL: sourceURL,
                    satisfying: frameInterpolationTargetFPS(for: screen)
                  ) else {
                continue
            }

            let playbackURL = URL(fileURLWithPath: record.videoPath)
            guard FileManager.default.fileExists(atPath: playbackURL.path) else { continue }
            Task { @MainActor [weak self] in
                await self?.reloadExternalPlayback(
                    on: screen,
                    sourceURL: sourceURL,
                    playbackURL: playbackURL,
                    markAsInterpolated: true,
                    requestID: requestID
                )
            }
        }
    }

    private func reloadExternalPlayback(
        on screen: NSScreen,
        sourceURL: URL,
        playbackURL: URL,
        markAsInterpolated: Bool,
        requestID: String? = nil
    ) async {
        guard externalRenderingActive,
              externalRenderer.isRunning,
              FileManager.default.fileExists(atPath: sourceURL.path) else {
            return
        }

        _ = playbackURL
        _ = markAsInterpolated
        _ = requestID
        if cacheDisplaySwitchIfNeeded(
            videoURL: sourceURL,
            posterURL: posterURL(for: screen),
            muted: isMuted,
            targetScreen: screen
        ) {
            return
        }
        let wasGloballyPaused = isPaused
        let wasScreenPaused = externalPausedScreenIDs.contains(
            screen.wallpaperScreenIdentifier
        )
        do {
            // Route in-place optimization through the same staged replacement
            // transaction as a normal video switch. Directly replacing the
            // child player would discard the old drawable and reintroduce a
            // black flash exactly when the interpolation artifact is loaded.
            try await applyVideoWallpaperViaExternalRenderer(
                from: sourceURL,
                posterURL: posterURL(for: screen),
                muted: isMuted,
                targetScreen: screen,
                usesSharedVideoDecoder: usesSharedVideoDecoder,
                animatedTransition: true,
                forceRebuild: true
            )
            let screenID = screen.wallpaperScreenIdentifier
            if wasGloballyPaused || wasScreenPaused {
                isPaused = wasGloballyPaused
                externalPausedScreenIDs.insert(screenID)
                if let screenIndex = externalScreenIndex(for: screen) {
                    externalRenderer.sendCommandFireAndForget(
                        .pause(screen: screenIndex)
                    )
                }
                showPosterImage(for: screenID)
            }
        } catch {
            AppLogger.error(.wallpaper, "外部视频补帧产物重载失败", metadata: [
                "screenID": screen.wallpaperScreenIdentifier,
                "source": sourceURL.lastPathComponent,
                "playback": playbackURL.lastPathComponent,
                "error": error.localizedDescription
            ])
        }
    }

    func reloadPlaybackAfterInPlaceInterpolation(videoURL: URL) {
        reloadPlaybackAfterInPlaceReplacement(videoURL: videoURL, markAsInterpolated: true)
    }

    /// Alias used by redownload/restore flows after an in-place source replacement.
    func reloadPlaybackAfterInPlaceOptimization(videoURL: URL) {
        reloadPlaybackAfterInPlaceReplacement(videoURL: videoURL, markAsInterpolated: false)
    }

    private func reloadPlaybackAfterInPlaceReplacement(videoURL: URL, markAsInterpolated: Bool) {
        if externalRenderingActive {
            let requestID = UUID().uuidString
            for screen in externalTargetScreens() {
                let currentSourceURL = videoURLByScreen[screen.wallpaperScreenIdentifier]
                    ?? videoURLByScreenFingerprint[screen.wallpaperScreenFingerprint]
                    ?? currentVideoURL
                guard currentSourceURL?.standardizedFileURL == videoURL.standardizedFileURL else {
                    continue
                }
                Task { @MainActor [weak self] in
                    await self?.reloadExternalPlayback(
                        on: screen,
                        sourceURL: videoURL,
                        playbackURL: videoURL,
                        markAsInterpolated: markAsInterpolated,
                        requestID: requestID
                    )
                }
            }
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
            replacePlayerWithInterpolatedVideoIfNeeded(
                screenID: screenID,
                sourceURL: videoURL,
                outputURL: videoURL,
                forceReload: true,
                markAsInterpolated: markAsInterpolated
            )
        }
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
        videoLetterboxAnalysisRevisionByScreen.removeAll()
        videoLetterboxContentCrops.removeAll()
        // 修复：清空持久缓存，防止自动切换时无限累积
        videoLetterboxCropCache.removeAll()
        videoLetterboxNoCropCache.removeAll()
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
        videoLetterboxAnalysisRevisionByScreen.removeValue(forKey: screenID)
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
        if externalRenderingActive {
            return !hasActiveWallpaper(on: screen) || externalIsPaused(screenID: screenID)
        }
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
            if self.externalRenderingActive {
                // 外部 renderer 直接订阅统一的锁屏状态文件/分布式通知。
                // 主进程不得再发全局 pause，否则会覆盖 helper 的每屏手动暂停状态。
                self.markExternalRendererSuspended()
                return
            }
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
            if #available(macOS 26.0, *) {
                LockScreenWallpaperService.shared.reconcilePlaybackStateAfterWake(
                    source: "videoManagerScreenUnlocked"
                )
            }
            if #available(macOS 26.0, *), self.externalRenderingActive {
                self.scheduleExternalRendererWakeRecovery(
                    reason: "screenUnlocked",
                    reconfigureDisplays: false
                )
            }
            // 解锁时恢复播放（如果不是手动暂停）
            guard !self.isPaused else {
                // 即便全局手动暂停，也要让 AutoPause 重新对齐追踪状态
                DynamicWallpaperAutoPauseManager.shared.reevaluateCurrentState()
                return
            }
            if self.externalRenderingActive {
                // helper 会按 systemPlaybackPaused + global/manual pause 合并恢复；
                // 这里再 resumeAll 会错误清掉单屏暂停。
                DynamicWallpaperAutoPauseManager.shared.reevaluateCurrentState()
                return
            }
            for (screenID, player) in self.players {
                player.play()
                self.hidePosterImage(for: screenID)
            }
            // 解锁后会先全量 play；立刻把仍有效的覆盖/前台/全屏暂停重新施加，
            // 避免窗口列表尚未恢复时 AutoPause 误以为桌面已可见。
            DynamicWallpaperAutoPauseManager.shared.reevaluateCurrentState()
        }
    }

    func stopWallpaper(for targetScreen: NSScreen? = nil) {
        // 子进程渲染路径
        if externalRenderingActive {
            externalTransitionGeneration &+= 1
            if let targetScreen {
                let screenIdx = externalScreenIndex(for: targetScreen)
                if let screenIdx {
                    externalRenderer.sendCommandFireAndForget(.stop(screen: screenIdx))
                } else {
                    AppLogger.error(.wallpaper, "外部视频单屏停止时目标屏已离线", metadata: [
                        "screenID": targetScreen.wallpaperScreenIdentifier
                    ])
                }
                let sid = targetScreen.wallpaperScreenIdentifier
                externalRequestIDByScreenID.removeValue(forKey: sid)
                externalPresentedScreenIDs.remove(sid)
                externalOwnedScreenIDs.remove(sid)
                externalFirstFrameReadyScreenIDs.remove(sid)
                externalPendingCommitScreenIDs.remove(sid)
                videoURLByScreen.removeValue(forKey: sid)
                videoURLByScreenFingerprint.removeValue(forKey: targetScreen.wallpaperScreenFingerprint)
                videoTargetScreenIDs.remove(sid)
                videoTargetScreenFingerprints.remove(targetScreen.wallpaperScreenFingerprint)
                posterURLByScreen.removeValue(forKey: sid)
                posterURLByScreenFingerprint.removeValue(forKey: targetScreen.wallpaperScreenFingerprint)
                externalPausedScreenIDs.remove(sid)
                externalCropRevisionByScreenID.removeValue(forKey: sid)
                resetVideoLetterboxState(for: sid)
                resetFrameInterpolationState(for: sid)
                clearExternalDisplaySwitchState(
                    for: targetScreen,
                    reason: "stopWallpaper"
                )
                if #available(macOS 26.0, *),
                   let screenNumber = targetScreen.deviceDescription[
                       NSDeviceDescriptionKey("NSScreenNumber")
                   ] as? NSNumber {
                    WallpaperExtensionSocketServer.shared.unregisterDisplayVideo(
                        displayID: screenNumber.uint32Value
                    )
                }

                // 子进程是多屏共享 daemon；单屏提交后只移除该屏状态。
                // 最后一块屏才允许关闭 daemon，避免副屏视频被交接路径误杀。
                if videoTargetScreenIDs.isEmpty && videoTargetScreenFingerprints.isEmpty {
                    cancelExternalRendererRestart()
                    externalRenderer.sendCommandFireAndForget(.stop(screen: nil))
                    externalRenderer.stopDaemon()
                    externalRenderingActive = false
                    currentVideoURL = nil
                    currentPosterURL = nil
                    isPaused = false
                    externalPausedScreenIDs.removeAll()
                    externalRequestIDByScreenID.removeAll()
                    externalPresentedScreenIDs.removeAll()
                    externalOwnedScreenIDs.removeAll()
                    externalFirstFrameReadyScreenIDs.removeAll()
                    externalPendingCommitScreenIDs.removeAll()
                    externalCropRevisionByScreenID.removeAll()
                    if #available(macOS 26.0, *), !isLockScreenEnabled {
                        LockScreenWallpaperService.shared.clearMirroringSourceCache()
                    }
                } else {
                    lastAppliedScreenConfigurations =
                        currentTargetScreenConfigurations()
                }
            } else {
                clearExternalDisplaySwitchState(
                    for: nil,
                    reason: "stopWallpaper"
                )
                cancelExternalRendererRestart()
                externalRenderer.sendCommandFireAndForget(.stop(screen: nil))
                externalRenderer.stopDaemon()
                externalRenderingActive = false
                currentVideoURL = nil
                currentPosterURL = nil
                posterURLByScreen.removeAll()
                posterURLByScreenFingerprint.removeAll()
                videoURLByScreen.removeAll()
                videoURLByScreenFingerprint.removeAll()
                isPaused = false
                videoTargetScreenIDs = []
                videoTargetScreenFingerprints = []
                externalPausedScreenIDs.removeAll()
                externalFirstFrameReadyScreenIDs.removeAll()
                externalRequestIDByScreenID.removeAll()
                externalPresentedScreenIDs.removeAll()
                externalOwnedScreenIDs.removeAll()
                externalPendingCommitScreenIDs.removeAll()
                externalCropRevisionByScreenID.removeAll()
                clearVideoLetterboxState()
                clearFrameInterpolationState()
                if #available(macOS 26.0, *), !isLockScreenEnabled {
                    LockScreenWallpaperService.shared.clearMirroringSourceCache()
                }
            }
            wallpaperChangeCount &+= 1
            persistState()
            syncCurrentVideoURL()
            if !externalRenderingActive {
                deactivateAudioSession()
            }
            return
        }

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
        // Do this before checking manager state. A stale/untracked helper can
        // still be visible even when the in-memory wallpaper state is empty.
        externalRenderer.terminateAllChildRenderersForAppTermination()
        guard hasActiveVideoWallpaper else { return }

        // 子进程渲染路径：停止子进程并保留持久化状态
        if externalRenderingActive {
            externalTransitionGeneration &+= 1
            cancelExternalRendererRestart()
            clearExternalDisplaySwitchState(
                for: nil,
                reason: "appTermination"
            )
            discardOriginalWallpaperSnapshot()
            posterTasks.values.forEach { $0.cancel() }
            posterTasks.removeAll()

            // 退出前为每个目标屏写 poster 到系统桌面
            if !shouldSkipStaticPosterForDynamicLockScreen {
                for screen in screensForVideoWallpaperTargets() {
                    if let posterURL = posterURL(for: screen) {
                        applyPosterAsDesktopWallpaperSync(posterURL, targetScreen: screen)
                    }
                }
            }

            externalRenderer.stopDaemon()
            externalRenderingActive = false
            externalFirstFrameReadyScreenIDs.removeAll()
            externalRequestIDByScreenID.removeAll()
            externalPresentedScreenIDs.removeAll()
            externalOwnedScreenIDs.removeAll()
            externalPendingCommitScreenIDs.removeAll()
            externalCropRevisionByScreenID.removeAll()
            persistState()
            return
        }

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
                contentView.attachPlayer(nil)
            }
            window.contentView = nil
            window.orderOut(nil)
        }
        for looper in loopers.values {
            looper.disableLooping()
        }
        // 共享解码时多屏指向同一 AVQueuePlayer，按实例去重后再 pause/removeAllItems。
        var uniquePlayers: [AVQueuePlayer] = []
        var seenPlayerIDs = Set<ObjectIdentifier>()
        for player in players.values {
            let id = ObjectIdentifier(player)
            guard seenPlayerIDs.insert(id).inserted else { continue }
            uniquePlayers.append(player)
        }
        for player in uniquePlayers {
            player.pause()
            player.removeAllItems()
        }
        windows.removeAll()
        players.removeAll()
        presentedVideoScreenIDs.removeAll()
        loopers.removeAll()
        sharedFollowerAttachmentTasks.values.forEach { $0.cancel() }
        sharedFollowerAttachmentTasks.removeAll()
        pendingSharedFollowerScreenIDsByPlayerID.removeAll()
        anchoredVideoPathByPlayerID.removeAll()
        sourceVideoItemByPlayerID.removeAll()
        sharedVideoLooper?.disableLooping()
        sharedVideoLooper = nil
        sharedVideoItem = nil
        sharedVideoPlayer = nil
        usesSharedVideoDecoder = false
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
        // 子进程渲染路径：只停止子进程，不触发 WallpaperEngineXBridge 链式停止
        if externalRenderingActive {
            externalTransitionGeneration &+= 1
            if let targetScreen {
                let screenIdx = externalScreenIndex(for: targetScreen)
                if let screenIdx {
                    externalRenderer.sendCommandFireAndForget(.stop(screen: screenIdx))
                } else {
                    AppLogger.error(.wallpaper, "外部视频 stop-only 目标屏已离线", metadata: [
                        "screenID": targetScreen.wallpaperScreenIdentifier
                    ])
                }
                let screenID = targetScreen.wallpaperScreenIdentifier
                posterTasks[screenID]?.cancel()
                posterTasks.removeValue(forKey: screenID)
                externalRequestIDByScreenID.removeValue(forKey: screenID)
                externalPresentedScreenIDs.remove(screenID)
                externalOwnedScreenIDs.remove(screenID)
                externalFirstFrameReadyScreenIDs.remove(screenID)
                externalPendingCommitScreenIDs.remove(screenID)
                videoTargetScreenIDs.remove(screenID)
                videoTargetScreenFingerprints.remove(targetScreen.wallpaperScreenFingerprint)
                videoURLByScreen.removeValue(forKey: screenID)
                videoURLByScreenFingerprint.removeValue(forKey: targetScreen.wallpaperScreenFingerprint)
                posterURLByScreen.removeValue(forKey: screenID)
                posterURLByScreenFingerprint.removeValue(forKey: targetScreen.wallpaperScreenFingerprint)
                externalPausedScreenIDs.remove(screenID)
                externalCropRevisionByScreenID.removeValue(forKey: screenID)
                resetVideoLetterboxState(for: screenID)
                resetFrameInterpolationState(for: screenID)
                clearExternalDisplaySwitchState(
                    for: targetScreen,
                    reason: "stopNativeVideoWallpaperOnly"
                )
                if #available(macOS 26.0, *),
                   let screenNumber = targetScreen.deviceDescription[
                       NSDeviceDescriptionKey("NSScreenNumber")
                   ] as? NSNumber {
                    WallpaperExtensionSocketServer.shared.unregisterDisplayVideo(
                        displayID: screenNumber.uint32Value
                    )
                }

                if videoTargetScreenIDs.isEmpty && videoTargetScreenFingerprints.isEmpty {
                    cancelExternalRendererRestart()
                    externalRenderer.sendCommandFireAndForget(.stop(screen: nil))
                    externalRenderer.stopDaemon()
                    externalRenderingActive = false
                    currentVideoURL = nil
                    currentPosterURL = nil
                    isPaused = false
                    externalPausedScreenIDs.removeAll()
                    externalRequestIDByScreenID.removeAll()
                    externalPresentedScreenIDs.removeAll()
                    externalOwnedScreenIDs.removeAll()
                    externalPendingCommitScreenIDs.removeAll()
                    externalFirstFrameReadyScreenIDs.removeAll()
                    externalCropRevisionByScreenID.removeAll()
                    defaults.removeObject(forKey: stateKey)
                    if #available(macOS 26.0, *), !isLockScreenEnabled {
                        LockScreenWallpaperService.shared.clearMirroringSourceCache()
                    }
                    deactivateAudioSession()
                } else {
                    syncCurrentVideoURL()
                    currentPosterURL = posterURLByScreen.values.first
                        ?? posterURLByScreenFingerprint.values.first
                    persistState()
                }
            } else {
                clearExternalDisplaySwitchState(
                    for: nil,
                    reason: "stopNativeVideoWallpaperOnly"
                )
                posterTasks.values.forEach { $0.cancel() }
                posterTasks.removeAll()
                cancelExternalRendererRestart()
                externalRenderer.sendCommandFireAndForget(.stop(screen: nil))
                externalRenderer.stopDaemon()
                externalRenderingActive = false
                currentVideoURL = nil
                currentPosterURL = nil
                posterURLByScreen.removeAll()
                posterURLByScreenFingerprint.removeAll()
                videoURLByScreen.removeAll()
                videoURLByScreenFingerprint.removeAll()
                videoTargetScreenIDs.removeAll()
                videoTargetScreenFingerprints.removeAll()
                externalPausedScreenIDs.removeAll()
                externalFirstFrameReadyScreenIDs.removeAll()
                externalRequestIDByScreenID.removeAll()
                externalPresentedScreenIDs.removeAll()
                externalOwnedScreenIDs.removeAll()
                externalPendingCommitScreenIDs.removeAll()
                externalCropRevisionByScreenID.removeAll()
                isPaused = false
                defaults.removeObject(forKey: stateKey)
                if #available(macOS 26.0, *), !isLockScreenEnabled {
                    LockScreenWallpaperService.shared.clearMirroringSourceCache()
                }
                clearVideoLetterboxState()
                clearFrameInterpolationState()
                deactivateAudioSession()
            }
            wallpaperChangeCount &+= 1
            persistState()
            syncCurrentVideoURL()
            return
        }
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

        // 单屏停止：只拆掉该屏幕的视频层，不回退到旧静态壁纸。
        // 注意：即使锁屏镜像扩展活跃，桌面 AVPlayer 窗口仍可能存在，
        // 切到 web/scene 时必须一并拆除，否则会出现「web 已切上、视频层还在渲染」。
        let screenID = targetScreen.wallpaperScreenIdentifier
        let screenFingerprint = targetScreen.wallpaperScreenFingerprint

        // 取消该屏尚未应用的切换队列、poster 任务与补帧任务，避免 stop 后异步回调把视频窗重建回来。
        pendingDisplaySwitches.removeValue(forKey: screenID)
        if activeDisplaySwitchScreenID == screenID {
            releaseDisplaySwitchGate(screenID: screenID, reason: "stopNativeOnly")
        }
        posterTasks[screenID]?.cancel()
        posterTasks.removeValue(forKey: screenID)
        resetFrameInterpolationState(for: screenID)

        // 兼容 screenID 变化：按 fingerprint 找回旧 key 上的窗口/播放器。
        let windowKey = windows[screenID] != nil
            ? screenID
            : windows.keys.first(where: { key in
                NSScreen.screens.first(where: { $0.wallpaperScreenIdentifier == key })?
                    .wallpaperScreenFingerprint == screenFingerprint
            })
        let playerKey = players[screenID] != nil
            ? screenID
            : players.keys.first(where: { key in
                NSScreen.screens.first(where: { $0.wallpaperScreenIdentifier == key })?
                    .wallpaperScreenFingerprint == screenFingerprint
            })
        let teardownKey = windowKey ?? playerKey

        if let teardownKey {
            teardownWindow(for: teardownKey)
        } else if windows[screenID] != nil || players[screenID] != nil {
            teardownWindow(for: screenID)
        }

        videoTargetScreenIDs.remove(screenID)
        videoTargetScreenFingerprints.remove(screenFingerprint)
        posterURLByScreen.removeValue(forKey: screenID)
        posterURLByScreenFingerprint.removeValue(forKey: screenFingerprint)
        videoURLByScreen.removeValue(forKey: screenID)
        videoURLByScreenFingerprint.removeValue(forKey: screenFingerprint)
        // 清理可能残留的旧 screenID 映射
        if let windowKey, windowKey != screenID {
            videoTargetScreenIDs.remove(windowKey)
            videoURLByScreen.removeValue(forKey: windowKey)
            posterURLByScreen.removeValue(forKey: windowKey)
        }
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
            deactivateAudioSession()
        } else {
            lastAppliedScreenConfigurations = currentTargetScreenConfigurations()
            persistState()
        }
        if #available(macOS 26.0, *),
           let screenNumber = targetScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            WallpaperExtensionSocketServer.shared.unregisterDisplayVideo(displayID: screenNumber.uint32Value)
            if !isLockScreenEnabled {
                // 动态锁屏关闭时，切走视频也清掉该屏镜像源，避免扩展继续推旧帧
                // （动态锁屏开启时保留实例映射，由 LockScreenWallpaperService 自己管理）
            }
        }
        wallpaperChangeCount &+= 1
        syncCurrentVideoURL()
        AppLogger.error(.wallpaper, "stopNativeVideoWallpaperOnly done", metadata: [
            "screenID": screenID,
            "teardownKey": teardownKey ?? "none",
            "remainingWindows": windows.count,
            "remainingPlayers": players.count
        ])
    }

    private func retainPlayersTemporarily(_ retainedPlayers: [AVQueuePlayer]) {
        guard !retainedPlayers.isEmpty else { return }

        // 入队前再冲一次 item，尽量让 VTDecoder 会话在延迟窗口内开始 teardown。
        for player in retainedPlayers {
            player.pause()
            player.rate = 0
            player.removeAllItems()
            player.replaceCurrentItem(with: nil)
        }

        var cleanup: DispatchWorkItem?
        cleanup = DispatchWorkItem { [weak self, retainedPlayers] in
            // 延迟到期：最后一次清空，再丢弃强引用，让 AVFoundation 真正释放解码会话。
            for player in retainedPlayers {
                player.pause()
                player.rate = 0
                player.removeAllItems()
                player.replaceCurrentItem(with: nil)
            }
            _ = retainedPlayers
            if let cleanup {
                self?.pendingPlayerCleanups.removeAll { $0 === cleanup }
            }
        }

        guard let cleanup else { return }
        pendingPlayerCleanups.append(cleanup)
        DispatchQueue.main.asyncAfter(deadline: .now() + delayedCleanupRetention, execute: cleanup)
    }

    /// 从所有视频窗（含 crossfade 过渡层）断开对指定 player 的 layer 引用。
    private func detachPlayerFromAllLayers(_ player: AVQueuePlayer) {
        for window in windows.values {
            guard let contentView = window.contentView as? WallpaperVideoContainerView else { continue }
            contentView.detach(player: player)
        }
    }

    /// 彻底拆掉一条不再被任何屏引用的解码管线（looper + items + layer）。
    /// 用于切换壁纸时避免 VTDecoderXPCService 随每次设置累积。
    private func disposePlayerPipeline(_ player: AVQueuePlayer, looper: AVPlayerLooper? = nil) {
        let playerID = ObjectIdentifier(player)
        sharedFollowerAttachmentTasks.removeValue(forKey: playerID)?.cancel()
        pendingSharedFollowerScreenIDsByPlayerID.removeValue(forKey: playerID)
        detachPlayerFromAllLayers(player)
        looper?.disableLooping()
        if player === sharedVideoPlayer {
            sharedVideoLooper?.disableLooping()
            sharedVideoLooper = nil
            sharedVideoItem = nil
            sharedVideoPlayer = nil
            if players.isEmpty {
                usesSharedVideoDecoder = false
            }
        }
        player.pause()
        player.rate = 0
        // looper 可能还往 queue 里插 item：先 disable 再清队列。
        player.removeAllItems()
        player.replaceCurrentItem(with: nil)
        anchoredVideoPathByPlayerID.removeValue(forKey: playerID)
        sourceVideoItemByPlayerID.removeValue(forKey: playerID)
        retainPlayersTemporarily([player])
    }

    /// 扫掉 maps 里已不存在、但 layer/延迟队列可能仍间接拖住的脏 player。
    /// 仅保留 `players` 字典中仍被引用的实例。
    private func purgeOrphanedVideoPlayers(reason: String) {
        var live = Set<ObjectIdentifier>()
        for player in players.values {
            live.insert(ObjectIdentifier(player))
        }
        if let sharedVideoPlayer {
            live.insert(ObjectIdentifier(sharedVideoPlayer))
        }
        if let pendingGlobalTransitionPlayer {
            live.insert(ObjectIdentifier(pendingGlobalTransitionPlayer))
        }
        live.formUnion(transitionRetainedPlayers.keys)

        // 过渡层若仍挂着已不在 map 里的 player，强制摘掉。
        for window in windows.values {
            guard let contentView = window.contentView as? WallpaperVideoContainerView else { continue }
            contentView.purgeDetachedPlayers(keeping: live)
        }

        // 延迟队列里可能积压多次切换留下的 player；只保留仍 live 的引用已无意义，
        // 这里不 cancel 全部 cleanup（避免破坏 0.5s SIGSEGV 防护），仅打日志便于确认。
        if !pendingPlayerCleanups.isEmpty {
            NSLog("[VideoWallpaperManager] purgeOrphanedVideoPlayers(\(reason)): pendingCleanups=\(pendingPlayerCleanups.count) livePlayers=\(live.count)")
        }
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
        screenTransitionSourceRollbacks.removeValue(forKey: screenID)
        pendingCrossTypeVideoScreenIDs.remove(screenID)
        presentedVideoScreenIDs.remove(screenID)

        let playerBeforeRemoval = players[screenID]
        if let playerBeforeRemoval {
            pendingSharedFollowerScreenIDsByPlayerID[ObjectIdentifier(playerBeforeRemoval)]?.remove(screenID)
        }
        let ownedPlaybackEndObserver = playbackEndObservers[screenID]
        if let observer = ownedPlaybackEndObserver {
            NotificationCenter.default.removeObserver(observer)
            playbackEndObservers.removeValue(forKey: screenID)
        }
        onEndModeScreens.remove(screenID)

        // 不要在共享引用还在时 disableLooping；把 looper 交给 releasePlayerIfUnreferenced 决策。
        let looper = loopers[screenID]
        loopers.removeValue(forKey: screenID)

        if let window = windows[screenID] {
            if let contentView = window.contentView as? WallpaperVideoContainerView {
                contentView.cancelPlayerTransitionIfNeeded()
                contentView.attachPlayer(nil)
            }
            window.contentView = nil
            window.orderOut(nil)
            windows.removeValue(forKey: screenID)
            retainWindowsTemporarily([window])
        }
        if let player = playerBeforeRemoval {
            // 先从 map 摘掉本屏引用，再判断其它屏是否仍共享该 player。
            players.removeValue(forKey: screenID)
            // 若本屏持有「播完即换」observer 且 player 仍被共享，迁到剩余任一 on-end 屏。
            if ownedPlaybackEndObserver != nil {
                rehomePlaybackEndObserverIfNeeded(for: player, preferredScreenID: nil)
            }
            releasePlayerIfUnreferenced(player, looper: looper)
        } else {
            looper?.disableLooping()
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
            let expectedVideoURL = videoURL(for: screen)?.standardizedFileURL
            posterTasks[screenID]?.cancel()
            posterTasks[screenID] = Task { @MainActor [weak self] in
                await self?.applyPosterAsDesktopWallpaper(
                    posterURL,
                    targetScreen: screen,
                    expectedVideoURL: expectedVideoURL
                )
                self?.posterTasks.removeValue(forKey: screenID)
            }
        }
    }

    /// Publish the upcoming poster before an animated video transition reaches its
    /// deferred desktop write. Registers the poster so Space-switch resync and
    /// bookkeeping already reference the new image while the first frame settles.
    private func registerPendingPosterBackplate(
        _ posterURL: URL,
        targetScreen: NSScreen?
    ) {
        AppLogger.debug(.wallpaper, "posterSync: 注册 backplate（延迟 \(Int(deferredPosterSyncDelay * 1000))ms 后落桌面）", metadata: [
            "poster": posterURL.lastPathComponent,
            "screen": targetScreen?.localizedName ?? "all"
        ])
        guard isSystemWallpaperSyncEnabled, !shouldSkipStaticPosterForDynamicLockScreen else {
            return
        }

        let fillOptions: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSNumber(value: NSImageScaling.scaleProportionallyUpOrDown.rawValue),
            .allowClipping: true
        ]
        let screens = targetScreen.map { [$0] } ?? NSScreen.screens
        for screen in screens {
            DesktopWallpaperSyncManager.shared.registerWallpaperSet(
                posterURL,
                for: screen,
                options: fillOptions
            )
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
                await self.applyPosterAsDesktopWallpaper(
                    posterURL,
                    targetScreen: currentScreen,
                    expectedVideoURL: expectedURL
                )
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
            // 同屏连续切换（自动下一张 / 菜单栏手动）：直接覆盖门控并立即应用最新请求，
            // 否则会把请求塞进 pending，界面看起来像“点了没反应”。
            if activeDisplaySwitchScreenID == screenID {
                pendingDisplaySwitches.removeValue(forKey: screenID)
                scheduleDisplaySwitchRelease(screenID: screenID, delay: displaySwitchTimeout, reason: "sameScreenSupersede")
                AppLogger.debug(.wallpaper, "Video switch supersedes active gate on same display", metadata: [
                    "screenID": screenID,
                    "screen": targetScreen.localizedName,
                    "video": videoURL.lastPathComponent
                ])
                return false
            }

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

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.applyVideoWallpaper(
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
                if self.activeDisplaySwitchScreenID == screen.wallpaperScreenIdentifier {
                    self.releaseDisplaySwitchGate(
                        screenID: screen.wallpaperScreenIdentifier,
                        reason: "cachedSwitchFailed"
                    )
                } else if self.activeDisplaySwitchScreenID == nil {
                    self.applyNextCachedDisplaySwitchIfPossible()
                }
            }
        }
    }

    private func applyPosterAsDesktopWallpaperSync(_ posterURL: URL, targetScreen: NSScreen? = nil) {
        AppLogger.debug(.wallpaper, "posterSync: 同步设置桌面壁纸", metadata: [
            "poster": posterURL.lastPathComponent,
            "screen": targetScreen?.localizedName ?? "all"
        ])
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
                DesktopWallpaperSyncManager.shared.registerWallpaperSet(
                    persistentURL,
                    for: screen,
                    options: fillOptions
                )
            }
            print("[VideoWallpaperManager] [sync] Set poster as desktop wallpaper for \(screensToSet.count) screen(s)")
        } catch {
            print("[VideoWallpaperManager] [sync] Failed to set poster: \(error)")
        }
    }

    /// 异步可等待的 poster 设置核心逻辑
    private func applyPosterAsDesktopWallpaper(
        _ posterURL: URL,
        targetScreen: NSScreen? = nil,
        expectedVideoURL: URL? = nil
    ) async {
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
            guard !Task.isCancelled else { return }

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
                if let expectedVideoURL,
                   videoURL(for: screen)?.standardizedFileURL
                    != expectedVideoURL.standardizedFileURL {
                    return
                }
                try workspace.setDesktopImageURLForAllSpaces(persistentURL, for: screen, options: fillOptions)
                DesktopWallpaperSyncManager.shared.registerWallpaperSet(
                    persistentURL,
                    for: screen,
                    options: fillOptions
                )
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

    /// Mixed-source restore still applies per display, but later screens must
    /// not treat earlier live windows as missing. Same-source restore already
    /// uses a single `targetScreen: nil` apply above.
    private func restoreExternalVideoWallpapersByScreen(
        _ targetScreens: [NSScreen],
        fallbackURL: URL,
        muted: Bool
    ) async throws {
        for screen in targetScreens {
            try await applyVideoWallpaperViaExternalRenderer(
                from: videoURL(for: screen) ?? fallbackURL,
                posterURL: posterURL(for: screen),
                muted: muted,
                targetScreen: screen,
                usesSharedVideoDecoder: false,
                animatedTransition: false,
                forceRebuild: false
            )
        }
    }

    func restoreIfNeeded() async {
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
        usesSharedVideoDecoder = savedState.usesSharedVideoDecoder ?? false
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
        videoTargetScreenIDs = Set(savedState.videoScreenIDs ?? [])
        videoTargetScreenFingerprints = Set(savedState.videoScreenFingerprints ?? [])

        do {
            AppLogger.error(.wallpaper, "Video restore begin", metadata: [
                "explicitTargets": savedState.hasExplicitScreenTargets,
                "screenIDs": (savedState.videoScreenIDs ?? []).joined(separator: ","),
                "currentScreens": NSScreen.screens.map(\.wallpaperScreenIdentifier).joined(separator: ",")
            ])

            // P1: 子进程渲染路径——启动恢复也走子进程
            if useExternalVideoRenderer {
                AppLogger.info(.wallpaper, "Video restore 走子进程渲染路径")
                isMuted = savedState.isMuted
                volume = savedState.volume ?? (savedState.isMuted ? 0 : 1)
                volumeByScreen = savedState.volumeByScreen ?? [:]
                volumeByScreenFingerprint = savedState.volumeByScreenFingerprint ?? [:]
                currentPosterURL = globalPosterURL
                externalRenderingActive = true
                resetExternalWakeRecoveryTracking(suspended: isScreenLocked)
                isPaused = savedState.isPaused
                userRequestedPause = savedState.isPaused
                let savedScreenIDs = Set(savedState.videoScreenIDs ?? [])
                let savedFingerprints = Set(savedState.videoScreenFingerprints ?? [])
                let targetScreens = savedState.hasExplicitScreenTargets
                    ? NSScreen.screens.filter {
                        savedScreenIDs.contains($0.wallpaperScreenIdentifier)
                            || savedFingerprints.contains($0.wallpaperScreenFingerprint)
                    }
                    : NSScreen.screens
                if !targetScreens.isEmpty {
                    let uniqueSourceURLs = Set(
                        targetScreens.map {
                            (videoURL(for: $0) ?? url).standardizedFileURL
                        }
                    )
                    if uniqueSourceURLs.count == 1 {
                        try await applyVideoWallpaperViaExternalRenderer(
                            from: uniqueSourceURLs.first ?? url,
                            posterURL: globalPosterURL ?? posterURL(for: targetScreens[0]),
                            muted: savedState.isMuted,
                            targetScreen: nil,
                            usesSharedVideoDecoder: self.usesSharedVideoDecoder
                                || targetScreens.count > 1,
                            animatedTransition: false,
                            forceRebuild: false
                        )
                    } else {
                        try await restoreExternalVideoWallpapersByScreen(
                            targetScreens,
                            fallbackURL: url,
                            muted: savedState.isMuted
                        )
                    }
                }
                if targetScreens.isEmpty {
                    syncCurrentVideoURL()
                    AppLogger.info(.wallpaper, "视频恢复等待目标显示器重新出现")
                } else if savedState.isPaused {
                    pauseWallpaper()
                }
                return
            }

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
                usesSharedVideoDecoder: savedState.usesSharedVideoDecoder,
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
            if self.externalRenderingActive {
                guard self.hasActiveVideoWallpaper else { return }
                self.pendingRebuildWorkItem?.cancel()
                let workItem = DispatchWorkItem { [weak self] in
                    guard let self,
                          self.externalRenderingActive,
                          self.hasActiveVideoWallpaper else {
                        return
                    }
                    Task { @MainActor [weak self] in
                        await self?.reconfigureExternalRendererForCurrentScreens(
                            reason: "screenParametersChanged"
                        )
                    }
                }
                self.pendingRebuildWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: workItem)
                return
            }
            // 立刻拆掉已断屏窗口，避免 1.5s 防抖窗口内残留 AVPlayer/窗口
            self.teardownOrphanedVideoWindowsPreservingRestoreState()
            guard self.hasActiveVideoWallpaper else { return }

            // 防抖：延迟执行，避免屏幕参数变化时的频繁重建
            self.pendingRebuildWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self, self.hasActiveVideoWallpaper else { return }

                self.relinkDisplayStateForCurrentScreens()
                self.teardownOrphanedVideoWindowsPreservingRestoreState()

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

    /// 拆掉已断开显示器上的视频窗口/播放器，但保留 fingerprint 级 URL 映射供重插恢复。
    /// 与 `discardPersistedWallpaperState` 不同：后者会忘掉该屏关联。
    private func teardownOrphanedVideoWindowsPreservingRestoreState() {
        let currentScreenIDs = Set(NSScreen.screens.map(\.wallpaperScreenIdentifier))
        let orphanWindowIDs = windows.keys.filter { !currentScreenIDs.contains($0) }
        guard !orphanWindowIDs.isEmpty else {
            // 目标 ID 仍可能指着已断屏；收敛到在线集合，fingerprint 映射保留
            videoTargetScreenIDs = videoTargetScreenIDs.intersection(currentScreenIDs)
            for screen in NSScreen.screens {
                if videoTargetScreenFingerprints.contains(screen.wallpaperScreenFingerprint) {
                    videoTargetScreenIDs.insert(screen.wallpaperScreenIdentifier)
                }
            }
            return
        }

        AppLogger.error(.wallpaper, "Video tearing down orphaned windows after disconnect", metadata: [
            "orphanScreens": orphanWindowIDs.sorted().joined(separator: ","),
            "currentScreens": currentScreenIDs.sorted().joined(separator: ",")
        ])

        for screenID in orphanWindowIDs {
            teardownWindow(for: screenID)
            // 运行时 screenID 映射可清；fingerprint 级保留以便重插
            videoURLByScreen.removeValue(forKey: screenID)
            posterURLByScreen.removeValue(forKey: screenID)
            volumeByScreen.removeValue(forKey: screenID)
            videoTargetScreenIDs.remove(screenID)
            onEndModeScreens.remove(screenID)
        }

        for screen in NSScreen.screens {
            if videoTargetScreenFingerprints.contains(screen.wallpaperScreenFingerprint) {
                videoTargetScreenIDs.insert(screen.wallpaperScreenIdentifier)
            }
        }
        syncCurrentVideoURL()
        currentPosterURL = posterURLByScreen.values.first ?? posterURLByScreenFingerprint.values.first
    }

    @objc private func handleScreensDidSleep() {
        // ⚠️ NSWorkspace 通知可能不在主线程，dispatch 到主线程
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.externalRenderingActive {
                // helper 直接消费 LockScreenWallpaperService 的统一状态。
                self.markExternalRendererSuspended()
                return
            }
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
                LockScreenWallpaperService.shared.reconcilePlaybackStateAfterWake(
                    source: "videoManagerScreensWake"
                )
            }
            if #available(macOS 26.0, *), self.externalRenderingActive {
                self.scheduleExternalRendererWakeRecovery(
                    reason: "screensWake",
                    reconfigureDisplays: true
                )
            }

            // 屏幕唤醒时防抖重建
            self.pendingWakeRebuildWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                if self.hasActiveVideoWallpaper {
                    if self.externalRenderingActive {
                        DynamicWallpaperAutoPauseManager.shared.reevaluateCurrentState()
                        if #available(macOS 26.0, *) {
                            // The serialized wake recovery task owns external
                            // renderer health checks and reconfiguration.
                            return
                        }
                        Task { @MainActor [weak self] in
                            await self?.reconfigureExternalRendererForCurrentScreens(
                                reason: "screensWake"
                            )
                        }
                        return
                    }
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
                        if self.externalRenderingActive {
                            Task { @MainActor [weak self] in
                                await self?.reconfigureExternalRendererForCurrentScreens(
                                    reason: "screensWakeDelayed"
                                )
                            }
                            return
                        }
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
            if self.externalRenderingActive {
                // helper 直接消费 LockScreenWallpaperService 的统一状态。
                self.markExternalRendererSuspended()
                return
            }
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
                LockScreenWallpaperService.shared.reconcilePlaybackStateAfterWake(
                    source: "videoManagerSystemWake"
                )
            }
            if #available(macOS 26.0, *), self.externalRenderingActive {
                self.scheduleExternalRendererWakeRecovery(
                    reason: "systemWake",
                    reconfigureDisplays: true
                )
            }

            self.pendingWakeRebuildWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                if self.hasActiveVideoWallpaper {
                    if self.externalRenderingActive {
                        DynamicWallpaperAutoPauseManager.shared.reevaluateCurrentState()
                        if #available(macOS 26.0, *) {
                            // The serialized wake recovery task owns external
                            // renderer health checks and reconfiguration.
                            return
                        }
                        Task { @MainActor [weak self] in
                            await self?.reconfigureExternalRendererForCurrentScreens(
                                reason: "systemWake"
                            )
                        }
                        return
                    }
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

        rematerializeExternalScreenIdentitySets()
        migrateSingleActiveVideoWallpaperToCurrentScreenIfNeeded()
        syncCurrentVideoURL()
    }

    /// Sleep/replug can mint a new NSScreenNumber for the same physical display.
    /// Move live/owned/pending sets onto the current identifier so the next set
    /// still treats the child window as a replacement instead of a new black window.
    private func rematerializeExternalScreenIdentitySets() {
        func rematerialize(_ ids: Set<String>) -> Set<String> {
            var next = ids
            for screen in NSScreen.screens {
                let screenID = screen.wallpaperScreenIdentifier
                let fingerprint = screen.wallpaperScreenFingerprint
                if ids.contains(screenID) || ids.contains(fingerprint) {
                    next.insert(screenID)
                }
            }
            return next
        }

        func remapKeyed<Value>(_ map: [String: Value]) -> [String: Value] {
            var next = map
            for screen in NSScreen.screens {
                let screenID = screen.wallpaperScreenIdentifier
                let fingerprint = screen.wallpaperScreenFingerprint
                if next[screenID] == nil, let value = map[fingerprint] {
                    next[screenID] = value
                }
            }
            return next
        }

        externalOwnedScreenIDs = rematerialize(externalOwnedScreenIDs)
        externalPresentedScreenIDs = rematerialize(externalPresentedScreenIDs)
        externalFirstFrameReadyScreenIDs = rematerialize(externalFirstFrameReadyScreenIDs)
        externalPendingCommitScreenIDs = rematerialize(externalPendingCommitScreenIDs)
        externalPausedScreenIDs = remapKeyed(Dictionary(
            uniqueKeysWithValues: externalPausedScreenIDs.map { ($0, true) }
        )).filter(\.value).keys.reduce(into: Set<String>()) { $0.insert($1) }
        externalRequestIDByScreenID = remapKeyed(externalRequestIDByScreenID)
        externalCropRevisionByScreenID = remapKeyed(externalCropRevisionByScreenID)
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
        if externalRenderingActive {
            Task { @MainActor [weak self] in
                await self?.reconfigureExternalRendererForCurrentScreens(reason: reason)
            }
            return
        }

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

    /// Rebinds the child renderer after a display reconnect or a resolution
    /// change. The parent process never calls `rebuildWindows()` in this mode.
    private func reconfigureExternalRendererForCurrentScreens(
        reason: String,
        clearExistingRendererState: Bool = true,
        forceNewPipeline: Bool = false,
        recoverUnresponsiveRenderer: Bool = false
    ) async {
        await withExternalRendererTransaction {
            await self.reconfigureExternalRendererForCurrentScreensLocked(
                reason: reason,
                clearExistingRendererState: clearExistingRendererState,
                forceNewPipeline: forceNewPipeline,
                recoverUnresponsiveRenderer: recoverUnresponsiveRenderer
            )
        }
    }

    private func reconfigureExternalRendererForCurrentScreensLocked(
        reason: String,
        clearExistingRendererState: Bool,
        forceNewPipeline: Bool,
        recoverUnresponsiveRenderer: Bool
    ) async {
        guard externalRenderingActive else { return }
        guard externalPendingCommitScreenIDs.isEmpty else {
            AppLogger.info(.wallpaper, "外部视频事务提交中，延后显示器重配置", metadata: [
                "reason": reason,
                "pendingScreens": externalPendingCommitScreenIDs.sorted()
                    .joined(separator: ",")
            ])
            scheduleDelayedExternalRendererReconfigure(
                reason: "\(reason)-afterTransition"
            )
            return
        }

        relinkDisplayStateForCurrentScreens()
        let targets = externalTargetScreens()
        guard !targets.isEmpty else {
            AppLogger.error(.wallpaper, "外部视频重连时没有可用目标屏", metadata: ["reason": reason])
            return
        }
        if !externalRenderer.isRunning {
            guard await externalRenderer.startDaemon() else {
                scheduleExternalRendererRestart(afterExitStatus: -1)
                return
            }
        } else {
            await externalRenderer.reconcileChildRenderers()
            if recoverUnresponsiveRenderer,
               !(await externalRenderer.isDaemonResponsive(
                   timeout: Self.externalRendererHealthCheckTimeout
               )) {
                AppLogger.error(.wallpaper, "唤醒时 video-renderer 探活失败，准备换代", metadata: [
                    "reason": reason
                ])
                guard await forceRecycleExternalRenderer(reason: "\(reason)-unresponsive") else {
                    scheduleExternalRendererRestart(afterExitStatus: -1)
                    return
                }
            }
        }

        let wasPaused = isPaused
        let pausedIDs = externalPausedScreenIDs
        let desiredScreenIDs = videoTargetScreenIDs
        let desiredFingerprints = videoTargetScreenFingerprints
        externalFirstFrameReadyScreenIDs.subtract(
            targets.map(\.wallpaperScreenIdentifier)
        )
        if clearExistingRendererState {
            // Keep owned + presented IDs so the following set can freeze the
            // last frame and host still treats this as a live video replacement.
            // Reconfigure itself is auto-committed by the helper when the fresh
            // pipeline produces a drawable.
            externalFirstFrameReadyScreenIDs.subtract(
                targets.map(\.wallpaperScreenIdentifier)
            )
        }
        var reboundIDs = Set<String>()
        var reboundFingerprints = Set<String>()
        let maximumAttempts = recoverUnresponsiveRenderer ? 2 : 1
        reconfigureAttempts: for attempt in 0..<maximumAttempts {
            let requestID = UUID().uuidString
            for screen in targets {
                let screenID = screen.wallpaperScreenIdentifier
                externalRequestIDByScreenID[screenID] = requestID
                guard let sourceURL = videoURL(for: screen) ?? currentVideoURL,
                      FileManager.default.fileExists(atPath: sourceURL.path),
                      let screenIndex = externalScreenIndex(for: screen) else {
                    continue
                }
                let playbackURL = frameInterpolatedPlaybackURLByScreen[screenID]
                    ?? resolvedExternalPlaybackURL(for: sourceURL, screen: screen)
                let schedulerConfig = WallpaperSchedulerService.shared.config
                    .resolvedDisplayConfig(for: screenID)
                let looping = !(schedulerConfig.isEnabled && schedulerConfig.isOnEndMode)
                let command = VideoRendererProcessController.Command.set(
                    screen: screenIndex,
                    screenID: screenID,
                    requestID: requestID,
                    path: playbackURL.path,
                    posterPath: posterURL(for: screen)?.isFileURL == true
                        ? posterURL(for: screen)?.path
                        : nil,
                    frame: screen.frame,
                    muted: isMuted,
                    volume: volume(for: screen),
                    looping: looping,
                    shared: usesSharedVideoDecoder,
                    forceNewPipeline: forceNewPipeline,
                    hdrMetadataEnabled: UserDefaults.standard.object(
                        forKey: "hdr_enabled"
                    ) as? Bool ?? false,
                    // Reconfigure has no host-side transition commit. The
                    // helper preserves the old drawable itself and commits
                    // the replacement when the fresh pipeline has a frame.
                    deferredPresentation: false,
                    transitionDuration: 0,
                    globalPaused: wasPaused,
                    screenPaused: pausedIDs.contains(screenID),
                    globalDisplaySyncEnabled: WallpaperSchedulerService.shared
                        .isGlobalDisplaySyncEnabled
                )
                let setCommandTimeout = recoverUnresponsiveRenderer
                    ? Self.externalRendererWakeSetCommandTimeout
                    : Self.externalRendererSetCommandTimeout
                var response = await externalRenderer.sendCommand(
                    command,
                    screen: screenIndex,
                    timeout: setCommandTimeout
                )
                if response?.hasPrefix("OK") != true, recoverUnresponsiveRenderer {
                    let responsive = await externalRenderer.isDaemonResponsive(
                        timeout: Self.externalRendererHealthCheckTimeout
                    )
                    if !responsive {
                        guard attempt + 1 < maximumAttempts,
                              await forceRecycleExternalRenderer(
                                  reason: "\(reason)-setUnresponsive"
                              ) else {
                            scheduleExternalRendererRestart(afterExitStatus: -1)
                            return
                        }
                        // Recycling drops every child-owned window, including
                        // screens already rebound in this attempt. Restart the
                        // complete target set instead of resuming mid-list.
                        reboundIDs.removeAll()
                        reboundFingerprints.removeAll()
                        continue reconfigureAttempts
                    }
                    // The set can race display enumeration or a just-finished
                    // decoder teardown. A healthy daemon gets one direct
                    // retry before the screen is marked failed.
                    response = await externalRenderer.sendCommand(
                        command,
                        screen: screenIndex,
                        timeout: setCommandTimeout
                    )
                }
                guard response?.hasPrefix("OK") == true else {
                    AppLogger.error(.wallpaper, "外部视频显示器重连 set 失败", metadata: [
                        "screenID": screenID,
                        "reason": reason,
                        "response": response ?? "nil"
                    ])
                    continue
                }

                reboundIDs.insert(screenID)
                reboundFingerprints.insert(screen.wallpaperScreenFingerprint)
                rememberExternalOwnedScreen(screen)
                syncExternalPosterPath(
                    for: screen,
                    posterURL: posterURL(for: screen)
                )
                if wasPaused || pausedIDs.contains(screenID) {
                    showPosterImage(for: screenID)
                }
                if !externalLiveVideoScreenIDs.contains(screenID) {
                    applyCropToScreen(screen)
                }
                scheduleVideoLetterboxAnalysis(screenID: screenID, videoURL: playbackURL)
                prepareExternalFrameInterpolation(
                    screenID: screenID,
                    screen: screen,
                    videoURL: sourceURL
                )
            }
            break
        }

        // Keep matching child-owned windows alive while displays reconfigure.
        // A global stop tears every desktop-level window down before the new
        // pipelines can present a frame, which is the source of the visible
        // black desktop during monitor wake/rearrange. The child reuses each
        // matching stable screenID and only removes states for displays that
        // are no longer part of this live target set.
        let pruneIDs = Set(
            targets.flatMap {
                [$0.wallpaperScreenIdentifier, $0.wallpaperScreenFingerprint]
            }
        )
        externalRenderer.sendCommandFireAndForget(
            .pruneInactiveScreens(screenIDs: Array(pruneIDs))
        )

        let liveScreenIDs = Set(NSScreen.screens.map(\.wallpaperScreenIdentifier))
        videoTargetScreenIDs = desiredScreenIDs.intersection(liveScreenIDs)
            .union(reboundIDs)
        videoTargetScreenFingerprints = desiredFingerprints.union(reboundFingerprints)
        externalPausedScreenIDs = pausedIDs.intersection(videoTargetScreenIDs)
        if wasPaused {
            externalRenderer.sendCommandFireAndForget(.pause(screen: nil))
        }
        let grainIntensity = ArcBackgroundSettings.shared.grainTextureEnabled
            ? ArcBackgroundSettings.shared.grainIntensity
            : 0
        externalRenderer.sendCommandFireAndForget(
            .setGrainOverlay(screen: nil, intensity: grainIntensity)
        )
        lastAppliedScreenConfigurations = currentTargetScreenConfigurations()
        persistState()
        if #available(macOS 26.0, *) {
            LockScreenWallpaperService.shared.syncInstanceCatalogToSocketServer()
            syncAllDisplayVideosToExtension()
        }
    }

    /// Player/AVPlayerLooper 的创建在高分辨率外接盘和多屏共享模式下可能
    /// 阻塞 renderer 主线程数秒；set 只等待窗口/player 建立，不等待首帧。
    private static let externalRendererSetCommandTimeout: TimeInterval = 30
    /// 唤醒恢复不允许被一个失效的 AVFoundation 管线拖住。健康 renderer 的
    /// `set` 通常几十毫秒返回；超过 3 秒直接探活并换代，比等待通用 30 秒可靠。
    private static let externalRendererWakeSetCommandTimeout: TimeInterval = 3
    /// 播放控制类命令（pause/resume/poster）的超时。
    /// 健康 daemon 毫秒级响应；楔死时必须快速失败让上层触发换代自愈，
    /// 不能让一次点击串行阻塞 15-30s（旧值 15s 曾让菜单暂停"点了没反应"）。
    private static let externalRendererPlaybackControlTimeout: TimeInterval = 2.5
    /// 唤醒探活只发送 ping，不应被解码/窗口初始化拖到 2.5s 以上。
    private static let externalRendererHealthCheckTimeout: TimeInterval = 1.5
    private func resetExternalWakeRecoveryTracking(suspended: Bool) {
        externalWakeRecoveryGeneration &+= 1
        externalWakeRecoveryTask?.cancel()
        externalWakeRecoveryTask = nil
        externalWakeNeedsDisplayReconfigure = false
        externalWakeNeedsPipelineRecovery = false
        externalPlaybackSuspendedAt = suspended ? Date() : nil
    }

    private func markExternalRendererSuspended() {
        guard externalRenderingActive, externalPlaybackSuspendedAt == nil else {
            return
        }
        externalPlaybackSuspendedAt = Date()
        // A healthy renderer process can still hold an invalid AVPlayer /
        // VideoToolbox session after clamshell sleep. Treat every sleep as a
        // pipeline boundary; a later play/seek is not a reliable recovery.
        externalWakeNeedsPipelineRecovery = true
    }

    /// Refreshes the helper's shared lock state.
    /// - Returns: true when the helper was recycled and needs a full rebind.
    @discardableResult
    private func refreshExternalRendererPlaybackState(reason: String) async -> Bool {
        guard externalRenderingActive else { return false }
        guard externalRenderer.isRunning else {
            AppLogger.error(.wallpaper, "外部视频唤醒时 renderer 已退出", metadata: [
                "reason": reason
            ])
            if await externalRenderer.startDaemon() {
                return true
            }
            scheduleExternalRendererRestart(afterExitStatus: -1)
            return false
        }
        guard await externalRenderer.isDaemonResponsive(
            timeout: Self.externalRendererHealthCheckTimeout
        ) else {
            AppLogger.error(.wallpaper, "外部视频唤醒探活失败，回收 renderer", metadata: [
                "reason": reason
            ])
            if await forceRecycleExternalRenderer(reason: "\(reason)-unresponsive") {
                AppLogger.info(.wallpaper, "外部视频 renderer 已换代，等待唤醒重配置", metadata: [
                    "reason": reason
                ])
                return true
            } else {
                scheduleExternalRendererRestart(afterExitStatus: -1)
            }
            return false
        }
        let response = await externalRenderer.sendCommand(
            .refreshPlaybackState,
            screen: nil,
            timeout: Self.externalRendererPlaybackControlTimeout
        )
        guard response?.hasPrefix("OK") == true else {
            AppLogger.error(.wallpaper, "外部视频唤醒状态刷新失败", metadata: [
                "reason": reason,
                "response": response ?? "nil"
            ])
            return false
        }
        AppLogger.debug(.wallpaper, "外部视频唤醒状态已刷新", metadata: [
            "reason": reason
        ])
        return false
    }

    private func scheduleExternalRendererWakeRecovery(
        reason: String,
        reconfigureDisplays: Bool
    ) {
        guard externalRenderingActive else { return }
        externalWakeNeedsDisplayReconfigure =
            externalWakeNeedsDisplayReconfigure || reconfigureDisplays
        // `screensDidWake`/`didWake` can arrive without a matching sleep
        // notification on a notebook lid cycle. The display wake itself is
        // enough evidence that the old decoder must not be reused.
        if reconfigureDisplays {
            externalWakeNeedsPipelineRecovery = true
        }
        if let suspendedAt = externalPlaybackSuspendedAt {
            let suspendedDuration = Date().timeIntervalSince(suspendedAt)
            externalPlaybackSuspendedAt = nil
            externalWakeNeedsPipelineRecovery = true
            AppLogger.info(.wallpaper, "锁屏/睡眠后启用视频解码管线重建", metadata: [
                "reason": reason,
                "duration": String(format: "%.1f", suspendedDuration)
            ])
        }
        externalWakeRecoveryGeneration &+= 1
        let generation = externalWakeRecoveryGeneration
        externalWakeRecoveryTask?.cancel()
        externalWakeRecoveryTask = Task { @MainActor [weak self] in
            var didRebuildPipeline = false
            let delays: [UInt64] = [
                0,
                350_000_000,
                900_000_000,
                1_500_000_000,
                3_000_000_000
            ]
            for (pass, delay) in delays.enumerated() {
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: delay)
                }
                guard !Task.isCancelled,
                      let self,
                      self.externalWakeRecoveryGeneration == generation,
                      self.externalRenderingActive else {
                    return
                }
                if pass == 2,
                   !didRebuildPipeline,
                   (
                       self.externalWakeNeedsDisplayReconfigure
                        || self.externalWakeNeedsPipelineRecovery
                   ) {
                    let forceNewPipeline = self.externalWakeNeedsPipelineRecovery
                    await self.reconfigureExternalRendererForCurrentScreens(
                        reason: "\(reason)-pipelineRecovery",
                        forceNewPipeline: forceNewPipeline,
                        recoverUnresponsiveRenderer: true
                    )
                    guard self.externalWakeRecoveryGeneration == generation else {
                        return
                    }
                    self.externalWakeNeedsDisplayReconfigure = false
                    self.externalWakeNeedsPipelineRecovery = false
                    didRebuildPipeline = true
                } else if (pass == 3 || pass == 4),
                          self.currentTargetScreenConfigurations()
                            != self.lastAppliedScreenConfigurations {
                    // External displays can be enumerated a few seconds after
                    // wake. Only rebind again when the target topology really
                    // changed; do not cancel a healthy replacement pipeline.
                    await self.reconfigureExternalRendererForCurrentScreens(
                        reason: "\(reason)-lateDisplayRecovery",
                        recoverUnresponsiveRenderer: true
                    )
                    didRebuildPipeline = true
                } else {
                    let didRecycle = await self.withExternalRendererTransaction {
                        guard self.externalWakeRecoveryGeneration == generation,
                              self.externalRenderingActive else {
                            return false
                        }
                        return await self.refreshExternalRendererPlaybackState(
                            reason: "\(reason)-pass\(pass)"
                        )
                    }
                    if didRecycle,
                       self.externalWakeRecoveryGeneration == generation,
                       self.externalRenderingActive {
                        await self.reconfigureExternalRendererForCurrentScreens(
                            reason: "\(reason)-rebindAfterRecycle",
                            forceNewPipeline: true,
                            recoverUnresponsiveRenderer: true
                        )
                        guard self.externalWakeRecoveryGeneration == generation else {
                            return
                        }
                        self.externalWakeNeedsDisplayReconfigure = false
                        self.externalWakeNeedsPipelineRecovery = false
                        didRebuildPipeline = true
                    }
                }
            }
            if self?.externalWakeRecoveryGeneration == generation {
                self?.externalWakeRecoveryTask = nil
            }
        }
    }

    /// 外部视频事务门最长持有时间。允许多屏 set 串行初始化后再进入
    /// 首帧等待，避免 watchdog 在正常的高分辨率重建期间释放事务门。
    private static let externalRendererTransactionWatchdog: TimeInterval = 90

    private func withExternalRendererTransaction<T>(
        _ operation: () async throws -> T
    ) async rethrows -> T {
        await acquireExternalRendererTransaction()
        externalRendererTransactionEpoch &+= 1
        let epoch = externalRendererTransactionEpoch

        // 保险丝：持有者 90s 未完成时强制释放事务门。实测曾出现持有者卡死
        // 13 分钟、所有后续视频切换静默排队（scene 切换不受影响）的故障，
        // 这里保证最坏 90s 内自愈；epoch 防止卡死持有者晚到的 defer 误放
        // 新事务的门。
        let watchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(Self.externalRendererTransactionWatchdog * 1_000_000_000)
            )
            guard let self,
                  self.externalRendererTransactionEpoch == epoch,
                  self.externalRendererTransactionActive else {
                return
            }
            AppLogger.error(
                .wallpaper,
                "外部视频渲染事务超过 \(Int(Self.externalRendererTransactionWatchdog))s 未完成，强制释放事务门"
            )
            self.externalTransitionGeneration &+= 1
            let pendingRequestIDs = Set(self.externalRequestIDByScreenID.values)
            for requestID in pendingRequestIDs {
                self.externalRenderer.sendCommandFireAndForget(
                    .cancelTransition(requestID: requestID)
                )
            }
            self.externalPendingCommitScreenIDs.removeAll()
            self.externalRendererTransactionEpoch &+= 1
            self.releaseExternalRendererTransaction()
        }
        defer {
            watchdog.cancel()
            if externalRendererTransactionEpoch == epoch {
                releaseExternalRendererTransaction()
            }
        }
        return try await operation()
    }

    private func acquireExternalRendererTransaction() async {
        let waitStart = Date()
        var loggedWait = false
        while externalRendererTransactionActive {
            if !loggedWait, Date().timeIntervalSince(waitStart) > 3.0 {
                loggedWait = true
                AppLogger.error(.wallpaper, "等待外部视频事务门释放超过 3s")
            }
            await withCheckedContinuation { continuation in
                externalRendererTransactionWaiters.append(continuation)
            }
        }
        externalRendererTransactionActive = true
    }

    private func releaseExternalRendererTransaction() {
        externalRendererTransactionActive = false
        guard !externalRendererTransactionWaiters.isEmpty else { return }
        externalRendererTransactionWaiters.removeFirst().resume()
    }

    private func scheduleDelayedExternalRendererReconfigure(reason: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self,
                  self.externalRenderingActive,
                  self.hasActiveVideoWallpaper else {
                return
            }
            Task { @MainActor [weak self] in
                await self?.reconfigureExternalRendererForCurrentScreens(reason: reason)
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

        // 全局同源视频切换不能 teardown：旧共享解码必须一直播放到新共享解码首帧就绪。
        if targetScreen == nil {
            // 单显示器的“全局切换”不会开启 shared decoder，但同样必须保留旧
            // player 到新视频 preroll 完成。此前这里强制要求 shared=true，导致
            // 单屏全局路径先 teardown 旧窗口，慢视频的整个加载期都暴露纯黑。
            let canStageGlobalTransition = animatedTransition
                && (usesSharedVideoDecoder || screensToRebuild.count == 1)
                && !windows.isEmpty
                && screensToRebuild.allSatisfy {
                    presentedVideoScreenIDs.contains($0.wallpaperScreenIdentifier)
                }
                && screensToRebuild.allSatisfy { windows[$0.wallpaperScreenIdentifier]?.contentView is WallpaperVideoContainerView }

            if canStageGlobalTransition,
               stageGlobalSharedVideoTransition(for: screensToRebuild) {
                NSLog("[VideoWallpaperManager] Staged global shared-player transition for \(screensToRebuild.count) screen(s)")
            } else {
                // Scene/Web -> 全屏视频没有旧的本机视频窗口，不能走 shared-player
                // staging；但 teardownAllWindows 会清理跨类型标记。先保存目标屏标记，
                // 否则后面 createWindow 会按普通视频路径提前 reveal，旧 Scene 也不会
                // 在首帧就绪后退出。
                let rebuildingScreenIDs = Set(screensToRebuild.map(\.wallpaperScreenIdentifier))
                let crossTypeScreenIDs = pendingCrossTypeVideoScreenIDs.intersection(rebuildingScreenIDs)
                let requestedSharedDecoder = usesSharedVideoDecoder
                globalTransitionSourceRollback = nil
                cancelPendingGlobalVideoTransition(reason: "globalImmediateRebuild")
                teardownAllWindows()
                pendingCrossTypeVideoScreenIDs.formUnion(crossTypeScreenIDs)
                // teardown 只是在释放旧窗口，不应改写本次 apply 已决定的解码模式。
                usesSharedVideoDecoder = requestedSharedDecoder
                for screen in screensToRebuild {
                    do {
                        guard let videoURL = self.videoURL(for: screen) else { continue }
                        try createWindow(for: screen, videoURL: videoURL, muted: isMuted)
                    } catch {
                        NSLog("[VideoWallpaperManager] Failed to create window: \(error.localizedDescription)")
                    }
                }
            }
        } else {
            guard let targetScreen = targetScreen else { return }
            let targetScreenID = targetScreen.wallpaperScreenIdentifier
            // 优先按 screenID 命中；失败时再按窗口 frame 匹配，防止 screenID 短暂变化时
            // 副屏误走 createWindow（alpha=0）路径，看起来像软件壁纸退出。
            let resolvedWindowEntry = existingVideoWindowEntry(for: targetScreen)
            if let resolvedWindowEntry,
               let containerView = resolvedWindowEntry.window.contentView as? WallpaperVideoContainerView {
                if resolvedWindowEntry.screenID != targetScreenID {
                    rekeyVideoWindowState(from: resolvedWindowEntry.screenID, to: targetScreenID)
                }
                let existingWindow = resolvedWindowEntry.window
                synchronizeWindow(existingWindow, to: targetScreen)
                // 复用窗口：尽量保留旧层直到新层首帧就绪，避免自动切换时硬闪。
                let oldPlayer = players[targetScreenID]
                let oldLooper = loopers[targetScreenID]

                // 1. 创建新 player（同文件可机会式复用其它屏的解码管线）
                guard let videoURL = videoURL(for: targetScreen) else {
                    NSLog("[VideoWallpaperManager] Missing video URL for target screen \(targetScreenID)")
                    return
                }

                // 检查该屏幕是否使用"播完即换"模式
                let schedulerConfig = WallpaperSchedulerService.shared.config.resolvedDisplayConfig(for: targetScreenID)
                let isOnEndMode = schedulerConfig.isEnabled && schedulerConfig.isOnEndMode

                let playbackURL = videoURL
                // 先从 map 摘掉旧引用，再 resolve，避免本屏旧 player 被当成可复用源。
                players.removeValue(forKey: targetScreenID)
                if oldLooper != nil {
                    loopers.removeValue(forKey: targetScreenID)
                }
                let components = resolvePlayerComponents(
                    for: targetScreen,
                    videoURL: playbackURL,
                    muted: isMuted,
                    enableLooping: !isOnEndMode
                )
                assignPlayerComponents(components, to: targetScreenID)

                // 更新噪点纹理叠加（桌面壁纸颗粒蒙层，由 Settings 开关独立控制）
                let grainEnabled = ArcBackgroundSettings.shared.grainTextureEnabled
                if grainEnabled {
                    containerView.showGrainOverlay(intensity: ArcBackgroundSettings.shared.grainIntensity)
                } else {
                    containerView.hideGrainOverlay()
                }

                // 异步切换期间让旧 player 继续可见；不能提前盖 poster 或停旧解码。
                let shouldAnimateReplacement = animatedTransition && oldPlayer != nil && oldPlayer !== components.player
                invalidatePosterDisplay(for: targetScreenID)
                if shouldAnimateReplacement, let oldPlayer {
                    retainPlayerDuringTransition(oldPlayer, for: targetScreenID)
                }

                let finalizeReplacement: @MainActor @Sendable () -> Void = { [weak self, weak containerView] in
                    guard let self, let containerView else { return }
                    self.screenTransitionSourceRollbacks.removeValue(forKey: targetScreenID)
                    // crossfade 完成时已把 player 写进主层；这里再写一次保持非动画路径一致。
                    containerView.playerLayer.videoGravity = .resizeAspectFill
                    containerView.attachPlayer(components.player)
                    self.hidePosterImage(for: targetScreenID)
                    self.applyCropToScreen(targetScreen)
                    self.scheduleVideoLetterboxAnalysis(screenID: targetScreenID, videoURL: videoURL)
                    self.prepareFrameInterpolation(
                        screenID: targetScreenID,
                        screen: targetScreen,
                        videoURL: videoURL,
                        player: components.player,
                        item: components.item,
                        containerView: containerView
                    )
                    self.presentedVideoScreenIDs.insert(targetScreenID)

                    // 仅当旧 player 不再被任何屏引用时才停解/清队列（共享解码时另一屏可能仍在用）。
                    if let oldPlayer, oldPlayer !== components.player {
                        self.endPlayerTransitionRetention(oldPlayer, for: targetScreenID)
                        self.releasePlayerIfUnreferenced(oldPlayer, looper: oldLooper)
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
                    // 如果目标屏原先持有旧共享管线唯一的 end observer，切走后把
                    // observer 迁给仍引用旧文件的屏幕，不能让旧管线失去播完事件。
                    if let oldPlayer, oldPlayer !== components.player {
                        self.rehomePlaybackEndObserverIfNeeded(for: oldPlayer, preferredScreenID: nil)
                    }
                }

                if shouldAnimateReplacement {
                    playerItemObservers[targetScreenID]?.invalidate()
                    playerItemObservers.removeValue(forKey: targetScreenID)
                    playerItemObserverTokens.removeValue(forKey: targetScreenID)
                    fadeInTimeouts[targetScreenID]?.cancel()
                    fadeInTimeouts.removeValue(forKey: targetScreenID)

                    let readinessToken = UUID()
                    playerItemObserverTokens[targetScreenID] = readinessToken
                    let incomingLayer = containerView.preparePlayerForCrossfade(components.player)

                    // Hidden warm-up layer must be attached before decoding. Do not
                    // start playback yet: first preroll the Looper's real queue item,
                    // then start it immediately before the crossfade.
                    // 提前 play 会让慢视频在切换前抢占主层输出，表现为半截空窗。
                    let screenVolume = volumeByScreen[targetScreenID] ?? volume
                    applyPlayerAudioPolicy(components.player, muted: isMuted, volume: screenVolume)

                    let beginAnimatedSwap: @MainActor @Sendable (String) -> Void = { [weak self, weak containerView] reason in
                        guard let self, let containerView else { return }
                        guard self.playerItemObserverTokens[targetScreenID] == readinessToken else { return }
                        self.playerItemObservers[targetScreenID]?.invalidate()
                        self.playerItemObservers.removeValue(forKey: targetScreenID)
                        self.playerItemObserverTokens.removeValue(forKey: targetScreenID)
                        self.fadeInTimeouts[targetScreenID]?.cancel()
                        self.fadeInTimeouts.removeValue(forKey: targetScreenID)

                        // AVPlayerLooper 可能在预热期间插入新的循环 item，交接前再应用一次音频策略。
                        let screenVolume = self.volumeByScreen[targetScreenID] ?? self.volume
                        self.applyPlayerAudioPolicy(components.player, muted: self.isMuted, volume: screenVolume)
                        if !self.isPaused {
                            components.player.play()
                        }

                        containerView.crossfadePreparedPlayer(
                            components.player,
                            duration: self.automaticSwitchTransitionDuration
                        ) {
                            finalizeReplacement()
                            if let window = self.windows[targetScreenID] {
                                Self.revealDesktopWallpaperWindow(window)
                            }
                            self.scheduleDisplaySwitchStableRelease(screenID: targetScreenID, reason: reason)
                        }
                    }

                    let observer = incomingLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { _, change in
                        guard change.newValue == true else { return }
                        DispatchQueue.main.async {
                            beginAnimatedSwap("replacementReady")
                        }
                    }
                    playerItemObservers[targetScreenID] = observer

                    // AVPlayerLooper 的 template item 可能一直是 unknown；应等待其
                    // currentItem 副本 ready 后 preroll。该条件不依赖隐藏 layer 是否
                    // 被 WindowServer 合成，慢视频只会让旧壁纸多显示一会，不会提前暴露新层。
                    Task { @MainActor [weak self, weak player = components.player, weak containerView] in
                        guard let self, let player, containerView != nil else { return }
                        let deadline = Date().addingTimeInterval(30)
                        while Date() < deadline {
                            guard self.playerItemObserverTokens[targetScreenID] == readinessToken else { return }
                            if let currentItem = player.currentItem {
                                if currentItem.status == .failed { return }
                                if currentItem.status == .readyToPlay {
                                    self.applyPlayerAudioPolicy(player, muted: self.isMuted, volume: screenVolume)
                                    player.preroll(atRate: 1.0) { success in
                                        guard success else { return }
                                        Task { @MainActor in
                                            beginAnimatedSwap("replacementPrerolled")
                                        }
                                    }
                                    return
                                }
                            }
                            try? await Task.sleep(nanoseconds: 25_000_000)
                        }
                    }

                    let timeout = DispatchWorkItem { [weak self, weak containerView] in
                        guard let self, let containerView,
                              self.playerItemObserverTokens[targetScreenID] == readinessToken else { return }
                        self.playerItemObservers[targetScreenID]?.invalidate()
                        self.playerItemObservers.removeValue(forKey: targetScreenID)
                        self.playerItemObserverTokens.removeValue(forKey: targetScreenID)
                        self.fadeInTimeouts.removeValue(forKey: targetScreenID)
                        containerView.discardPreparedPlayerTransition()
                        if let oldPlayer {
                            self.players[targetScreenID] = oldPlayer
                            if let oldLooper {
                                self.loopers[targetScreenID] = oldLooper
                            }
                            self.endPlayerTransitionRetention(oldPlayer, for: targetScreenID)
                        }
                        if let rollback = self.screenTransitionSourceRollbacks.removeValue(forKey: targetScreenID) {
                            self.videoURLByScreen[targetScreenID] = rollback.videoURL
                            self.videoURLByScreenFingerprint[rollback.fingerprint] = rollback.videoURL
                            self.posterURLByScreen[targetScreenID] = rollback.posterURL
                            self.posterURLByScreenFingerprint[rollback.fingerprint] = rollback.posterURL
                            self.syncCurrentVideoURL()
                            self.persistState()
                        }
                        self.releasePlayerIfUnreferenced(components.player, looper: components.looper)
                        NSLog("[VideoWallpaperManager] Replacement first-frame timeout on \(targetScreenID); old video kept playing")
                        self.scheduleDisplaySwitchStableRelease(screenID: targetScreenID, reason: "replacementFirstFrameTimeout")
                    }
                    fadeInTimeouts[targetScreenID] = timeout
                    // 与 createWindow 跨类型预热上限对齐；慢视频宁可多显示旧画面也不提前揭黑。
                    DispatchQueue.main.asyncAfter(deadline: .now() + 30.0, execute: timeout)
                } else {
                    screenTransitionSourceRollbacks.removeValue(forKey: targetScreenID)
                    containerView.cancelPlayerTransitionIfNeeded()
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    containerView.playerLayer.videoGravity = .resizeAspectFill
                    containerView.attachPlayer(components.player)
                    CATransaction.commit()
                    applyCropToScreen(targetScreen)
                    // 非动画替换会立即播放，新播放器绑定到 layer 后先同步静音音频轨状态。
                    let screenVolume = volumeByScreen[targetScreenID] ?? volume
                    applyPlayerAudioPolicy(components.player, muted: isMuted, volume: screenVolume)
                    if !isPaused {
                        components.player.play()
                    }
                    finalizeReplacement()
                    Self.revealDesktopWallpaperWindow(existingWindow)
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

    /// Build exactly one incoming AVQueuePlayer for a global same-video apply.
    /// Existing windows/layers and their old player remain untouched until every
    /// hidden incoming layer reports a decoded frame ready for display.
    @discardableResult
    /// 全局同源视频切换：先只预热 leader 屏的新 shared player，确认时间轴推进后再
    /// 串行挂 follower 预热层，全部 ready 后才统一 black commit。
    /// 避免多屏同时 attach 未起播的 AVQueuePlayer 导致部分层永远 isReadyForDisplay=false。
    private func stageGlobalSharedVideoTransition(for screens: [NSScreen]) -> Bool {
        guard let firstScreen = screens.first,
              let videoURL = videoURL(for: firstScreen) else { return false }
        let expectedPath = videoURL.standardizedFileURL.path
        guard screens.allSatisfy({ self.videoURL(for: $0)?.standardizedFileURL.path == expectedPath }) else {
            return false
        }

        let oldPlayersByScreen = players
        guard !oldPlayersByScreen.isEmpty else { return false }
        let oldLoopersByScreen = loopers

        cancelPendingGlobalVideoTransition(reason: "superseded")
        globalTransitionGeneration &+= 1
        let generation = globalTransitionGeneration

        let schedulerConfig = WallpaperSchedulerService.shared.config.resolvedDisplayConfig(
            for: firstScreen.wallpaperScreenIdentifier
        )
        let isOnEndMode = schedulerConfig.isEnabled && schedulerConfig.isOnEndMode

        let components = makePlayerComponents(
            for: firstScreen,
            videoURL: videoURL,
            muted: isMuted,
            enableLooping: !isOnEndMode
        )
        pendingGlobalTransitionPlayer = components.player
        pendingGlobalTransitionLooper = components.looper
        applyPlayerAudioPolicy(components.player, muted: isMuted, volume: volume)

        var containersByScreen: [String: WallpaperVideoContainerView] = [:]
        for screen in screens {
            let screenID = screen.wallpaperScreenIdentifier
            guard let window = windows[screenID],
                  let container = window.contentView as? WallpaperVideoContainerView else {
                cancelPendingGlobalVideoTransition(reason: "missingWindow")
                return false
            }
            synchronizeWindow(window, to: screen)
            containersByScreen[screenID] = container
        }

        let incomingScreenIDs = Set(containersByScreen.keys)
        let leaderScreenID = firstScreen.wallpaperScreenIdentifier
        guard let leaderContainer = containersByScreen[leaderScreenID] else {
            cancelPendingGlobalVideoTransition(reason: "missingLeader")
            return false
        }

        // 只先挂 leader 的隐藏预热层；follower 等 leader 真起播后再挂。
        let leaderLayer = leaderContainer.preparePlayerForCrossfade(components.player)
        let warmupStartedAt = Date()
        globalTransitionReadyScreenIDs.removeAll()
        globalTransitionDidBeginCommit = false

        let beginCommitIfReady: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self,
                  self.globalTransitionGeneration == generation,
                  !self.globalTransitionDidBeginCommit,
                  self.globalTransitionReadyScreenIDs.count == incomingScreenIDs.count else { return }
            self.globalTransitionDidBeginCommit = true
            AppLogger.debug(.wallpaper, "Global video warmup completed", metadata: [
                "screens": incomingScreenIDs.sorted().joined(separator: ","),
                "warmupMS": Int(Date().timeIntervalSince(warmupStartedAt) * 1_000)
            ])
            self.commitGlobalSharedVideoTransition(
                generation: generation,
                screens: screens,
                videoURL: videoURL,
                components: components,
                oldPlayersByScreen: oldPlayersByScreen,
                oldLoopersByScreen: oldLoopersByScreen,
                isOnEndMode: isOnEndMode
            )
        }

        var didBeginFollowerAttachment = false
        let beginFollowerAttachment: @MainActor @Sendable () -> Void = { [weak self, weak player = components.player] in
            guard let self, let player,
                  self.globalTransitionGeneration == generation,
                  !self.globalTransitionDidBeginCommit,
                  !didBeginFollowerAttachment else { return }
            didBeginFollowerAttachment = true

            // 首屏首帧完成后立即播放。先确认时间轴开始推进，
            // 再挂剩余 layer，避免“同时创建”整组停在未解码状态。
            let initialSeconds = player.currentTime().seconds
            if !self.isPaused {
                player.play()
            }

            // 单屏全局切换：没有 follower，leader ready 即可 commit。
            if screens.count == 1 {
                beginCommitIfReady()
                return
            }

            Task { @MainActor [weak self, weak player] in
                guard let self, let player else { return }
                let playbackDeadline = Date().addingTimeInterval(2.0)
                var playbackAdvanced = self.isPaused
                while !playbackAdvanced, Date() < playbackDeadline {
                    guard self.globalTransitionGeneration == generation,
                          !self.globalTransitionDidBeginCommit else { return }
                    let currentSeconds = player.currentTime().seconds
                    playbackAdvanced = player.rate > 0
                        && initialSeconds.isFinite
                        && currentSeconds.isFinite
                        && abs(currentSeconds - initialSeconds) >= 1.0 / 30.0
                    if !playbackAdvanced {
                        try? await Task.sleep(for: .milliseconds(16))
                    }
                }
                guard playbackAdvanced else {
                    AppLogger.error(.wallpaper, "Global shared video leader did not start before follower attach", metadata: [
                        "initialSeconds": initialSeconds,
                        "currentSeconds": player.currentTime().seconds,
                        "rate": player.rate,
                        "timeControlStatus": player.timeControlStatus.rawValue
                    ])
                    // 不在这里 teardown：留给 timeout 回滚旧画面，避免半截新 layer 暴露。
                    return
                }

                for screen in screens where screen.wallpaperScreenIdentifier != leaderScreenID {
                    let screenID = screen.wallpaperScreenIdentifier
                    guard self.globalTransitionGeneration == generation,
                          !self.globalTransitionDidBeginCommit,
                          let container = containersByScreen[screenID] else { return }
                    let layer = container.preparePlayerForCrossfade(player)
                    let layerDeadline = Date().addingTimeInterval(5.0)
                    while Date() < layerDeadline {
                        guard self.globalTransitionGeneration == generation,
                              !self.globalTransitionDidBeginCommit else { return }
                        if layer.isReadyForDisplay {
                            self.globalTransitionReadyScreenIDs.insert(screenID)
                            break
                        }
                        try? await Task.sleep(for: .milliseconds(16))
                    }
                    guard self.globalTransitionReadyScreenIDs.contains(screenID) else {
                        AppLogger.error(.wallpaper, "Global shared video follower layer not ready", metadata: [
                            "screenID": screenID,
                            "rate": player.rate
                        ])
                        // 单屏失败则整次不 commit，timeout 回滚。
                        return
                    }
                }
                beginCommitIfReady()
            }
        }

        let leaderObserver = leaderLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { _, change in
            guard change.newValue == true else { return }
            DispatchQueue.main.async {
                guard self.globalTransitionGeneration == generation else { return }
                self.globalTransitionReadyScreenIDs.insert(leaderScreenID)
                beginFollowerAttachment()
            }
        }
        globalTransitionObservers.append(leaderObserver)

        // 被旧壁纸遮住时 layer KVO 可能不发，用 preroll 作为 leader 准备信号。
        // 成功后先起播，再分阶段挂 follower，不在此处 play 全屏。
        Task { @MainActor [weak self, weak player = components.player] in
            guard let self, let player else { return }
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                guard self.globalTransitionGeneration == generation,
                      !self.globalTransitionDidBeginCommit,
                      self.pendingGlobalTransitionPlayer === player else { return }
                if let currentItem = player.currentItem, currentItem.status == .readyToPlay {
                    self.applyPlayerAudioPolicy(player, muted: self.isMuted, volume: self.volume)
                    player.preroll(atRate: 1.0) { success in
                        guard success else { return }
                        Task { @MainActor in
                            guard self.globalTransitionGeneration == generation,
                                  !self.globalTransitionDidBeginCommit,
                                  self.pendingGlobalTransitionPlayer === player else { return }
                            self.globalTransitionReadyScreenIDs.insert(leaderScreenID)
                            beginFollowerAttachment()
                        }
                    }
                    return
                }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
        }

        let timeout = DispatchWorkItem { [weak self] in
            guard let self,
                  self.globalTransitionGeneration == generation,
                  !self.globalTransitionDidBeginCommit else { return }
            NSLog("[VideoWallpaperManager] Global transition timed out before all screens had a first frame; keeping old video")
            self.restoreGlobalTransitionSourceState()
            self.cancelPendingGlobalVideoTransition(reason: "firstFrameTimeout")
        }
        globalTransitionTimeout = timeout
        // 多屏分阶段预热可能比「同时挂层」更久；与 createWindow 跨类型上限对齐。
        DispatchQueue.main.asyncAfter(deadline: .now() + 30.0, execute: timeout)
        return true
    }

    private func commitGlobalSharedVideoTransition(
        generation: UInt64,
        screens: [NSScreen],
        videoURL: URL,
        components: (player: AVQueuePlayer, looper: AVPlayerLooper?, item: AVPlayerItem),
        oldPlayersByScreen: [String: AVQueuePlayer],
        oldLoopersByScreen: [String: AVPlayerLooper],
        isOnEndMode: Bool
    ) {
        guard globalTransitionGeneration == generation,
              pendingGlobalTransitionPlayer === components.player else { return }
        let crossfadeCommitStartedAt = Date()

        globalTransitionObservers.forEach { $0.invalidate() }
        globalTransitionObservers.removeAll()
        globalTransitionTimeout?.cancel()
        globalTransitionTimeout = nil
        globalTransitionReadyScreenIDs.removeAll()

        // Promote the one warmed decode pipeline only after every screen has joined it.
        let previousSharedPlayer = sharedVideoPlayer
        let previousSharedLooper = sharedVideoLooper
        for observer in playbackEndObservers.values {
            NotificationCenter.default.removeObserver(observer)
        }
        playbackEndObservers.removeAll()
        loopers.removeAll()
        for screen in screens {
            players[screen.wallpaperScreenIdentifier] = components.player
        }
        sharedVideoPlayer = components.player
        sharedVideoLooper = components.looper
        sharedVideoItem = components.item
        pendingGlobalTransitionPlayer = nil
        pendingGlobalTransitionLooper = nil
        globalTransitionSourceRollback = nil

        if isOnEndMode {
            onEndModeScreens = Set(screens.map(\.wallpaperScreenIdentifier))
            if let first = screens.first {
                setupPlaybackEndObserver(
                    for: first.wallpaperScreenIdentifier,
                    player: components.player,
                    item: components.item
                )
            }
        } else {
            onEndModeScreens.subtract(screens.map(\.wallpaperScreenIdentifier))
        }

        globalTransitionPendingCompletionScreenIDs = Set(screens.map(\.wallpaperScreenIdentifier))
        let finishOne: @MainActor @Sendable (NSScreen) -> Void = { [weak self] screen in
            guard let self, self.globalTransitionGeneration == generation else { return }
            let screenID = screen.wallpaperScreenIdentifier
            guard self.globalTransitionPendingCompletionScreenIDs.remove(screenID) != nil else { return }
            self.hidePosterImage(for: screenID)
            self.applyCropToScreen(screen)
            self.scheduleVideoLetterboxAnalysis(screenID: screenID, videoURL: videoURL)
            if let window = self.windows[screenID],
               let container = window.contentView as? WallpaperVideoContainerView {
                self.prepareFrameInterpolation(
                    screenID: screenID,
                    screen: screen,
                    videoURL: videoURL,
                    player: components.player,
                    item: components.item,
                    containerView: container
                )
                Self.revealDesktopWallpaperWindow(window)
                self.presentedVideoScreenIDs.insert(screenID)
            }
            guard self.globalTransitionPendingCompletionScreenIDs.isEmpty else { return }

            var released = Set<ObjectIdentifier>()
            for (oldScreenID, oldPlayer) in oldPlayersByScreen where oldPlayer !== components.player {
                let id = ObjectIdentifier(oldPlayer)
                guard released.insert(id).inserted else { continue }
                let oldLooper = oldLoopersByScreen[oldScreenID]
                    ?? (oldPlayer === previousSharedPlayer ? previousSharedLooper : nil)
                self.releasePlayerIfUnreferenced(oldPlayer, looper: oldLooper)
            }
            self.purgeOrphanedVideoPlayers(reason: "globalCrossfadeComplete")
            self.persistState()
            AppLogger.debug(.wallpaper, "Global video crossfade completed", metadata: [
                "screens": screens.map(\.wallpaperScreenIdentifier).sorted().joined(separator: ","),
                "transitionMS": Int(Date().timeIntervalSince(crossfadeCommitStartedAt) * 1_000)
            ])
            NSLog("[VideoWallpaperManager] Global shared-player crossfade completed")
        }

        for screen in screens {
            let screenID = screen.wallpaperScreenIdentifier
            guard let window = windows[screenID],
                  let container = window.contentView as? WallpaperVideoContainerView else {
                finishOne(screen)
                continue
            }
            container.crossfadePreparedPlayer(
                components.player,
                duration: automaticSwitchTransitionDuration
            ) {
                finishOne(screen)
            }
        }

        // Refresh natural size once and apply it to every screen sharing this asset.
        Task { [weak self] in
            let asset = AVURLAsset(url: videoURL)
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let size = try? await track.load(.naturalSize),
                  size.width > 0, size.height > 0 else { return }
            await MainActor.run {
                guard let self, self.globalTransitionGeneration == generation else { return }
                for screen in screens {
                    self.videoSizes[screen.wallpaperScreenIdentifier] = size
                    self.applyCropToScreen(screen)
                }
            }
        }
    }

    private func cancelPendingGlobalVideoTransition(reason: String) {
        globalTransitionGeneration &+= 1
        globalTransitionObservers.forEach { $0.invalidate() }
        globalTransitionObservers.removeAll()
        globalTransitionTimeout?.cancel()
        globalTransitionTimeout = nil
        globalTransitionReadyScreenIDs.removeAll()
        globalTransitionDidBeginCommit = false
        globalTransitionPendingCompletionScreenIDs.removeAll()
        for window in windows.values {
            (window.contentView as? WallpaperVideoContainerView)?.discardPreparedPlayerTransition()
        }
        if let player = pendingGlobalTransitionPlayer {
            pendingGlobalTransitionLooper?.disableLooping()
            player.pause()
            player.removeAllItems()
            player.replaceCurrentItem(with: nil)
            anchoredVideoPathByPlayerID.removeValue(forKey: ObjectIdentifier(player))
            retainPlayersTemporarily([player])
            NSLog("[VideoWallpaperManager] Cancelled pending global transition: \(reason)")
        }
        pendingGlobalTransitionPlayer = nil
        pendingGlobalTransitionLooper = nil
    }

    private func restoreGlobalTransitionSourceState() {
        guard let rollback = globalTransitionSourceRollback else { return }
        currentVideoURL = rollback.currentVideoURL
        currentPosterURL = rollback.currentPosterURL
        videoURLByScreen = rollback.videoURLByScreen
        videoURLByScreenFingerprint = rollback.videoURLByScreenFingerprint
        posterURLByScreen = rollback.posterURLByScreen
        posterURLByScreenFingerprint = rollback.posterURLByScreenFingerprint
        globalTransitionSourceRollback = nil
        persistState()
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

    private struct ExistingVideoWindowEntry {
        let screenID: String
        let window: WallpaperVideoWindow
    }

    /// 查找目标屏已有的视频窗：先 screenID，再按 frame 容差匹配（处理 screenID 抖动）。
    private func existingVideoWindowEntry(for screen: NSScreen) -> ExistingVideoWindowEntry? {
        let screenID = screen.wallpaperScreenIdentifier
        if let window = windows[screenID] {
            return ExistingVideoWindowEntry(screenID: screenID, window: window)
        }

        let targetFrame = screen.frame
        for (existingID, window) in windows {
            if framesApproximatelyEqual(window.frame, targetFrame) {
                return ExistingVideoWindowEntry(screenID: existingID, window: window)
            }
        }
        return nil
    }

    private func framesApproximatelyEqual(_ lhs: NSRect, _ rhs: NSRect, tolerance: CGFloat = 2) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= tolerance
            && abs(lhs.origin.y - rhs.origin.y) <= tolerance
            && abs(lhs.size.width - rhs.size.width) <= tolerance
            && abs(lhs.size.height - rhs.size.height) <= tolerance
    }

    /// 把运行时窗口/播放器字典从旧 screenID 迁到新 screenID，避免副屏切换时误重建窗口。
    private func rekeyVideoWindowState(from oldScreenID: String, to newScreenID: String) {
        guard oldScreenID != newScreenID else { return }

        if let window = windows.removeValue(forKey: oldScreenID) {
            windows[newScreenID] = window
        }
        if let player = players.removeValue(forKey: oldScreenID) {
            players[newScreenID] = player
        }
        if let looper = loopers.removeValue(forKey: oldScreenID) {
            loopers[newScreenID] = looper
        }
        if let observer = playbackEndObservers.removeValue(forKey: oldScreenID) {
            playbackEndObservers[newScreenID] = observer
        }
        if let itemObserver = playerItemObservers.removeValue(forKey: oldScreenID) {
            playerItemObservers[newScreenID] = itemObserver
        }
        if let token = playerItemObserverTokens.removeValue(forKey: oldScreenID) {
            playerItemObserverTokens[newScreenID] = token
        }
        if let timeout = fadeInTimeouts.removeValue(forKey: oldScreenID) {
            fadeInTimeouts[newScreenID] = timeout
        }
        if let posterToken = posterDisplayTokens.removeValue(forKey: oldScreenID) {
            posterDisplayTokens[newScreenID] = posterToken
        }
        if let size = videoSizes.removeValue(forKey: oldScreenID) {
            videoSizes[newScreenID] = size
        }
        if let crop = videoLetterboxContentCrops.removeValue(forKey: oldScreenID) {
            videoLetterboxContentCrops[newScreenID] = crop
        }
        if let task = videoLetterboxAnalysisTasks.removeValue(forKey: oldScreenID) {
            videoLetterboxAnalysisTasks[newScreenID] = task
        }
        if let decision = frameInterpolationDecisionsByScreen.removeValue(forKey: oldScreenID) {
            frameInterpolationDecisionsByScreen[newScreenID] = decision
        }
        if let analysisTask = frameInterpolationAnalysisTasks.removeValue(forKey: oldScreenID) {
            frameInterpolationAnalysisTasks[newScreenID] = analysisTask
        }
        if let interpolatedURL = frameInterpolatedPlaybackURLByScreen.removeValue(forKey: oldScreenID) {
            frameInterpolatedPlaybackURLByScreen[newScreenID] = interpolatedURL
        }
        if onEndModeScreens.remove(oldScreenID) != nil {
            onEndModeScreens.insert(newScreenID)
        }
        if let volume = volumeByScreen.removeValue(forKey: oldScreenID) {
            volumeByScreen[newScreenID] = volume
        }
        if let videoURL = videoURLByScreen.removeValue(forKey: oldScreenID) {
            videoURLByScreen[newScreenID] = videoURL
        }
        if let posterURL = posterURLByScreen.removeValue(forKey: oldScreenID) {
            posterURLByScreen[newScreenID] = posterURL
        }
        if videoTargetScreenIDs.remove(oldScreenID) != nil {
            videoTargetScreenIDs.insert(newScreenID)
        }
        if pendingCrossTypeVideoScreenIDs.remove(oldScreenID) != nil {
            pendingCrossTypeVideoScreenIDs.insert(newScreenID)
        }
        if presentedVideoScreenIDs.remove(oldScreenID) != nil {
            presentedVideoScreenIDs.insert(newScreenID)
        }
        if activeDisplaySwitchScreenID == oldScreenID {
            activeDisplaySwitchScreenID = newScreenID
        }
        if let pending = pendingDisplaySwitches.removeValue(forKey: oldScreenID) {
            pendingDisplaySwitches[newScreenID] = PendingDisplayVideoSwitch(
                videoURL: pending.videoURL,
                posterURL: pending.posterURL,
                muted: pending.muted,
                screenID: newScreenID,
                fingerprint: pending.fingerprint,
                screenName: pending.screenName,
                requestedAt: pending.requestedAt
            )
        }
        if let posterTask = posterTasks.removeValue(forKey: oldScreenID) {
            posterTasks[newScreenID] = posterTask
        }

        NSLog("[VideoWallpaperManager] Rekeyed runtime video state \(oldScreenID) → \(newScreenID)")
    }

    /// 创建并配置 AVPlayer + AVPlayerLooper，供 `createWindow` 与窗口复用路径共享。
    /// - Parameters:
    ///   - screen: 目标屏幕
    ///   - videoURL: 视频文件 URL
    ///   - muted: 是否静音
    ///   - hdrMetadataEnabled: 是否应用源视频逐帧 HDR 显示元数据；这是 AVPlayerItem 原生属性，不引入 videoComposition。
    ///   - enableLooping: 是否启用循环播放（"播完即换"模式下为 false）

    /// Merge per-screen AVQueuePlayers that are already decoding the same file.
    /// Used when re-applying the same wallpaper would otherwise early-return with N decoders.
    /// - Returns: true if any player instance was released as a result.
    @discardableResult
    private func coalesceDuplicateDecodersForSameVideos() -> Bool {
        // Group active screens by (video path, on-end mode). Different loop modes cannot share.
        var groups: [String: [String]] = [:]
        for (screenID, player) in players {
            // 合并依据必须是 player 自身锚定的文件，不能读可能已被下一次
            // 单屏 apply 提前改写的 screen/global URL 映射。
            let path = anchoredVideoPath(for: player)
            guard let path, !path.isEmpty else { continue }
            let onEnd = onEndModeScreens.contains(screenID)
            let key = "\(path)|onEnd=\(onEnd)"
            groups[key, default: []].append(screenID)
        }

        var didCoalesce = false
        for (_, screenIDs) in groups where screenIDs.count > 1 {
            // Prefer the existing shared player, else the first screen's player as canonical.
            let canonicalScreenID: String
            let canonicalPlayer: AVQueuePlayer
            if let sharedVideoPlayer,
               let sharedOwner = screenIDs.first(where: { players[$0] === sharedVideoPlayer }) {
                canonicalScreenID = sharedOwner
                canonicalPlayer = sharedVideoPlayer
            } else if let first = screenIDs.first, let player = players[first] {
                canonicalScreenID = first
                canonicalPlayer = player
            } else {
                continue
            }

            let canonicalLooper = loopers[canonicalScreenID]
                ?? (canonicalPlayer === sharedVideoPlayer ? sharedVideoLooper : nil)
            let canonicalItem = (canonicalPlayer === sharedVideoPlayer ? sharedVideoItem : nil)
                ?? canonicalPlayer.currentItem
                ?? canonicalPlayer.items().first
                ?? sourceVideoItemByPlayerID[ObjectIdentifier(canonicalPlayer)]

            for screenID in screenIDs where screenID != canonicalScreenID {
                guard let window = windows[screenID],
                      let containerView = window.contentView as? WallpaperVideoContainerView,
                      let oldPlayer = players[screenID] else {
                    continue
                }
                if oldPlayer === canonicalPlayer { continue }

                let oldLooper = loopers[screenID]
                let hadEndObserver = playbackEndObservers[screenID] != nil
                if hadEndObserver, let observer = playbackEndObservers.removeValue(forKey: screenID) {
                    NotificationCenter.default.removeObserver(observer)
                }
                players[screenID] = canonicalPlayer
                loopers.removeValue(forKey: screenID)
                containerView.playerLayer.videoGravity = .resizeAspectFill
                containerView.attachPlayer(canonicalPlayer)
                if let screen = NSScreen.screens.first(where: { $0.wallpaperScreenIdentifier == screenID }) {
                    applyCropToScreen(screen)
                    if let canonicalItem {
                        expandPreferredMaximumResolutionIfNeeded(for: canonicalItem, screen: screen)
                    }
                }
                // Drop the now-unreferenced duplicate decoder.
                releasePlayerIfUnreferenced(oldPlayer, looper: oldLooper)
                // Keep a single on-end observer on the shared player.
                rehomePlaybackEndObserverIfNeeded(for: canonicalPlayer, preferredScreenID: canonicalScreenID)
                didCoalesce = true
                NSLog("[VideoWallpaperManager] Coalesced duplicate decoder on \(screenID) → \(canonicalScreenID)")
            }

            // Ensure looper ownership stays under the canonical screen for opportunistic share.
            if let canonicalLooper,
               canonicalPlayer !== sharedVideoPlayer,
               !loopers.values.contains(where: { $0 === canonicalLooper }) {
                loopers[canonicalScreenID] = canonicalLooper
            }

            // If explicit shared mode is on, promote this canonical instance.
            if usesSharedVideoDecoder, sharedVideoPlayer == nil {
                sharedVideoPlayer = canonicalPlayer
                sharedVideoLooper = canonicalLooper
                sharedVideoItem = canonicalItem
            }
        }
        return didCoalesce
    }

    /// Resolve a player for a screen, reusing an existing decode pipeline when possible.
    /// - Explicit global shared mode (`usesSharedVideoDecoder`) always reuses `sharedVideoPlayer`.
    /// - Opportunistic: another screen already playing the same file (same loop mode) shares that player,
    ///   so multi-display same-video setups only keep one VTDecoderXPCService.
    private func resolvePlayerComponents(
        for screen: NSScreen,
        videoURL: URL,
        muted: Bool,
        enableLooping: Bool
    ) -> (player: AVQueuePlayer, looper: AVPlayerLooper?, item: AVPlayerItem) {
        // 默认关闭逐帧 HDR：XDR + macOS 15.x 上偶发桌面层 tone-map 闪暗（窗口 UI 不受影响）。
        // 仅当用户在设置里显式打开 HDR 时才启用。
        let hdrMetadataEnabled = UserDefaults.standard.object(forKey: "hdr_enabled") as? Bool ?? false
        let screenID = screen.wallpaperScreenIdentifier
        if let reusable = findReusablePlayerComponents(
            for: videoURL,
            enableLooping: enableLooping,
            excludingScreenID: screenID,
            attachingScreen: screen
        ) {
            return reusable
        }
        let components = makePlayerComponents(
            for: screen,
            videoURL: videoURL,
            muted: muted,
            hdrMetadataEnabled: hdrMetadataEnabled,
            enableLooping: enableLooping
        )
        if usesSharedVideoDecoder {
            sharedVideoPlayer = components.player
            sharedVideoLooper = components.looper
            sharedVideoItem = components.item
        }
        return components
    }

    /// Look up an existing AVQueuePlayer already decoding `videoURL` that can be attached to another layer.
    private func findReusablePlayerComponents(
        for videoURL: URL,
        enableLooping: Bool,
        excludingScreenID: String?,
        attachingScreen: NSScreen
    ) -> (player: AVQueuePlayer, looper: AVPlayerLooper?, item: AVPlayerItem)? {
        let targetPath = videoURL.standardizedFileURL.path

        if usesSharedVideoDecoder,
           let sharedVideoPlayer,
           let sharedVideoItem,
           playerMatchesVideoURL(
               sharedVideoPlayer,
               targetPath: targetPath
           ) {
            expandPreferredMaximumResolutionIfNeeded(for: sharedVideoItem, screen: attachingScreen)
            return (sharedVideoPlayer, sharedVideoLooper, sharedVideoItem)
        }

        for (existingScreenID, player) in players {
            if let excludingScreenID, existingScreenID == excludingScreenID { continue }
            guard playerMatchesVideoURL(player, targetPath: targetPath) else {
                continue
            }
            let existingIsOnEnd = onEndModeScreens.contains(existingScreenID)
            // Loop vs 播完即换 需要不同的 queue/observer 行为，不可混用同一 player。
            // existingIsOnEnd == true  ⇒ enableLooping 必须 false；反之亦然。
            guard existingIsOnEnd == !enableLooping else { continue }
            // Looper 刚创建时 queue 可能还是空的。以前这里直接
            // continue，导致“同时设置两屏同文件”各建一条解码管线；
            // 等第一屏已播放后再加入却正常，就是这个时序窗口。
            guard let item = player.currentItem
                    ?? player.items().first
                    ?? sourceVideoItemByPlayerID[ObjectIdentifier(player)] else { continue }

            // 机会式复用限制：统计该 player 已挂载的、与目标屏刷新率相同的屏幕数。
            // 相同刷新率的屏 VSync 信号频率一致，单 player 同时对齐多路时竞争更激烈：
            //   实测：3块 4K 120Hz 共享 1 路 player → 卡顿；各自独立 → 不卡。
            // 不同刷新率（如 60Hz + 120Hz）的屏 VSync 信号天然错开，共享无竞争，不限制。
            // 显式全局同步（usesSharedVideoDecoder）路径已在上方优先返回，不受此限制。
            let attachingRate = attachingScreen.maximumFramesPerSecond
            let sameRateShareCount = players
                .compactMap { screenID, p -> NSScreen? in
                    guard p === player, screenID != excludingScreenID else { return nil }
                    return NSScreen.screens.first { $0.wallpaperScreenIdentifier == screenID }
                }
                .filter { $0.maximumFramesPerSecond == attachingRate }
                .count
            guard sameRateShareCount < maxOpportunisticShareScreenCount else {
                NSLog("[VideoWallpaperManager] Opportunistic share skipped for \(attachingScreen.localizedName) (\(attachingRate)Hz): player already shared by \(sameRateShareCount) same-rate screens (limit \(maxOpportunisticShareScreenCount))")
                continue
            }

            let looper: AVPlayerLooper?
            if player === sharedVideoPlayer {
                looper = sharedVideoLooper
            } else {
                looper = loopers[existingScreenID]
            }
            expandPreferredMaximumResolutionIfNeeded(for: item, screen: attachingScreen)
            NSLog("[VideoWallpaperManager] Reusing existing player for \(videoURL.lastPathComponent) on \(attachingScreen.localizedName) (from \(existingScreenID))")
            return (player, looper, item)
        }
        return nil
    }

    private func anchoredVideoPath(for player: AVQueuePlayer) -> String? {
        let playerID = ObjectIdentifier(player)
        if let anchoredPath = anchoredVideoPathByPlayerID[playerID] {
            return anchoredPath
        }

        // 兼容锚点机制引入前已存在的 player：优先从活跃 item 反查并补建锚点。
        if let assetURL = (player.currentItem?.asset as? AVURLAsset)?.url
            ?? (player.items().first?.asset as? AVURLAsset)?.url {
            let assetPath = assetURL.standardizedFileURL.path
            anchoredVideoPathByPlayerID[playerID] = assetPath
            return assetPath
        }
        return nil
    }

    private func playerMatchesVideoURL(_ player: AVQueuePlayer, targetPath: String) -> Bool {
        // 锚点一旦存在就是该解码管线的唯一事实源。
        // 不允许已被单屏切换改写的全局/每屏 URL 覆盖它。
        anchoredVideoPath(for: player) == targetPath
    }

    private func screenIDsReferencingPlayer(_ player: AVQueuePlayer) -> [String] {
        players.compactMap { screenID, candidate in
            candidate === player ? screenID : nil
        }
    }

    private func enqueueSharedFollowerAttachment(screenID: String, player: AVQueuePlayer) {
        let playerID = ObjectIdentifier(player)
        pendingSharedFollowerScreenIDsByPlayerID[playerID, default: []].insert(screenID)
        scheduleSharedFollowerAttachments(for: player)
    }

    /// 严格复制“单屏已播放后再加入屏幕”的成功路径。
    /// 共享 player 时间轴未推进前不附加 follower layer；每加一屏
    /// 都等它首帧 ready 后再加下一屏，避免同一 run loop 批量挂层。
    private func scheduleSharedFollowerAttachments(for player: AVQueuePlayer) {
        let playerID = ObjectIdentifier(player)
        guard sharedFollowerAttachmentTasks[playerID] == nil else { return }

        let task = Task { @MainActor [weak self, weak player] in
            guard let self, let player else { return }
            let initialSeconds = player.currentTime().seconds
            let playbackDeadline = Date().addingTimeInterval(30)
            var playbackAdvanced = self.isPaused
            while !playbackAdvanced, Date() < playbackDeadline {
                guard self.screenIDsReferencingPlayer(player).count >= 2 else {
                    self.pendingSharedFollowerScreenIDsByPlayerID.removeValue(forKey: playerID)
                    self.sharedFollowerAttachmentTasks.removeValue(forKey: playerID)
                    return
                }
                let currentSeconds = player.currentTime().seconds
                playbackAdvanced = player.rate > 0
                    && initialSeconds.isFinite
                    && currentSeconds.isFinite
                    && currentSeconds - initialSeconds >= 1.0 / 30.0
                if !playbackAdvanced {
                    try? await Task.sleep(for: .milliseconds(16))
                }
            }

            guard playbackAdvanced else {
                AppLogger.error(.wallpaper, "Shared video leader did not start before follower attach", metadata: [
                    "owners": self.screenIDsReferencingPlayer(player).sorted().joined(separator: ","),
                    "rate": player.rate,
                    "timeControlStatus": player.timeControlStatus.rawValue
                ])
                self.sharedFollowerAttachmentTasks.removeValue(forKey: playerID)
                return
            }

            while let screenID = self.pendingSharedFollowerScreenIDsByPlayerID[playerID]?.sorted().first {
                self.pendingSharedFollowerScreenIDsByPlayerID[playerID]?.remove(screenID)
                guard self.players[screenID] === player,
                      let window = self.windows[screenID],
                      let container = window.contentView as? WallpaperVideoContainerView else {
                    continue
                }

                container.attachPlayer(player)
                CATransaction.flush()
                AppLogger.debug(.wallpaper, "Shared video follower attached after leader playback", metadata: [
                    "screenID": screenID,
                    "currentSeconds": player.currentTime().seconds,
                    "rate": player.rate
                ])

                let layerDeadline = Date().addingTimeInterval(5)
                while Date() < layerDeadline, !container.playerLayer.isReadyForDisplay {
                    guard self.players[screenID] === player else { break }
                    try? await Task.sleep(for: .milliseconds(16))
                }
                guard self.players[screenID] === player,
                      container.playerLayer.isReadyForDisplay else {
                    AppLogger.error(.wallpaper, "Shared video follower layer did not become ready", metadata: [
                        "screenID": screenID,
                        "currentSeconds": player.currentTime().seconds
                    ])
                    break
                }
            }

            if self.pendingSharedFollowerScreenIDsByPlayerID[playerID]?.isEmpty != false {
                self.pendingSharedFollowerScreenIDsByPlayerID.removeValue(forKey: playerID)
            }
            self.sharedFollowerAttachmentTasks.removeValue(forKey: playerID)
            if self.pendingSharedFollowerScreenIDsByPlayerID[playerID]?.isEmpty == false {
                self.scheduleSharedFollowerAttachments(for: player)
            }
        }
        sharedFollowerAttachmentTasks[playerID] = task
    }

    /// When a larger display attaches to a shared decode pipeline, raise the item's
    /// preferredMaximumResolution so decode isn't stuck at the smaller screen's limit.
    private func expandPreferredMaximumResolutionIfNeeded(for item: AVPlayerItem, screen: NSScreen) {
        let scale = screen.backingScaleFactor
        let width = screen.frame.width * scale
        let height = screen.frame.height * scale
        let current = item.preferredMaximumResolution
        let nextWidth = max(current.width, width)
        let nextHeight = max(current.height, height)
        if nextWidth > current.width || nextHeight > current.height {
            item.preferredMaximumResolution = CGSize(width: nextWidth, height: nextHeight)
        }
    }

    private func retainPlayerDuringTransition(_ player: AVQueuePlayer, for screenID: String) {
        let id = ObjectIdentifier(player)
        transitionRetainedPlayers[id] = player
        transitionRetainedPlayerOwners[id, default: []].insert(screenID)
    }

    private func endPlayerTransitionRetention(_ player: AVQueuePlayer, for screenID: String) {
        let id = ObjectIdentifier(player)
        transitionRetainedPlayerOwners[id]?.remove(screenID)
        if transitionRetainedPlayerOwners[id]?.isEmpty != false {
            transitionRetainedPlayerOwners.removeValue(forKey: id)
            transitionRetainedPlayers.removeValue(forKey: id)
        }
    }

    /// Pause/clear a player only when no window still references it (shared multi-display case).
    /// When other screens still share the player, rehome any looper ownership so looping stays alive.
    private func releasePlayerIfUnreferenced(
        _ player: AVQueuePlayer,
        looper: AVPlayerLooper? = nil
    ) {
        // It may already be absent from `players` while one or more screens still
        // show it as the outgoing frame during their independent black transitions.
        guard transitionRetainedPlayers[ObjectIdentifier(player)] == nil else { return }
        let remainingOwners = screenIDsReferencingPlayer(player)
        if !remainingOwners.isEmpty {
            // Opportunistic share: first owner may have held the looper entry.
            // Rehome it under a remaining screen so ARC doesn't kill seamless looping.
            if let looper,
               player !== sharedVideoPlayer,
               !loopers.values.contains(where: { $0 === looper }),
               let newOwner = remainingOwners.first {
                loopers[newOwner] = looper
            }
            return
        }

        disposePlayerPipeline(player, looper: looper)
    }

    /// After the screen that owned AVPlayerItemDidPlayToEndTime is torn down,
    /// attach the observer to another screen that still shares the same player.
    private func rehomePlaybackEndObserverIfNeeded(
        for player: AVQueuePlayer,
        preferredScreenID: String?
    ) {
        let alreadyObserved = playbackEndObservers.keys.contains { id in
            players[id] === player
        }
        guard !alreadyObserved else { return }

        let candidates = screenIDsReferencingPlayer(player).filter(onEndModeScreens.contains)
        guard let newOwner = preferredScreenID.flatMap({ candidates.contains($0) ? $0 : nil })
                ?? candidates.first,
              let item = player.currentItem ?? player.items().first else {
            return
        }
        setupPlaybackEndObserver(for: newOwner, player: player, item: item)
    }

    private func assignPlayerComponents(
        _ components: (player: AVQueuePlayer, looper: AVPlayerLooper?, item: AVPlayerItem),
        to screenID: String
    ) {
        let isSharedInstance = usesSharedVideoDecoder
            || components.player === sharedVideoPlayer
            || players.contains { id, player in id != screenID && player === components.player }
        if isSharedInstance {
            // Shared pipeline: keep a single looper entry under one owner screen
            // (or none when global sharedVideoLooper owns the lifecycle).
            if usesSharedVideoDecoder || components.player === sharedVideoPlayer {
                loopers.removeValue(forKey: screenID)
            } else if let looper = components.looper {
                if !loopers.values.contains(where: { $0 === looper }) {
                    loopers[screenID] = looper
                } else {
                    loopers.removeValue(forKey: screenID)
                }
            } else {
                loopers.removeValue(forKey: screenID)
            }
        } else if let looper = components.looper {
            loopers[screenID] = looper
        } else {
            loopers.removeValue(forKey: screenID)
        }
        players[screenID] = components.player
    }

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

        // 计算屏幕物理像素分辨率，用于后续所有与分辨率/码率相关的限制。
        // 共享解码时按全部目标屏中最大物理分辨率设上限，避免外屏糊/内屏过解。
        let sizingScreens = usesSharedVideoDecoder ? screensForVideoWallpaperTargets() : [screen]
        var screenPixelWidth: CGFloat = 0
        var screenPixelHeight: CGFloat = 0
        for s in sizingScreens {
            let scale = s.backingScaleFactor
            screenPixelWidth = max(screenPixelWidth, s.frame.width * scale)
            screenPixelHeight = max(screenPixelHeight, s.frame.height * scale)
        }

        // 1) 动态峰值码率限制（仅对网络流有意义）
        // preferredPeakBitRate 是 AVFoundation 自适应码率选轨的 hint，对本地单码率
        // 文件（MP4/MOV）无效果，不设即可（默认 0 = 无限制）。
        // 网络流（HLS 等）才需要限制，按屏幕分辨率 + 30fps 估算合理上限：
        //   公式：totalPixels × fps × bitsPerPixelPerFrame
        //   H.265 良好质量约 0.05 bits/pixel/frame：
        //   4K@30fps → 3840×2160×30×0.05 ≈ 12.4 Mbps（合理）
        //   4K@120fps → 3840×2160×120×0.05 ≈ 49.8 Mbps
        if !videoURL.isFileURL {
            let totalPixels = screenPixelWidth * screenPixelHeight
            let estimatedBitrate = totalPixels * 30 * 0.05  // 保守按 30fps 估算，避免过限
            let maxBitrate: Double = 80_000_000             // 80 Mbps 硬上限
            playerItem.preferredPeakBitRate = min(estimatedBitrate, maxBitrate)
        }
        // 本地文件保持默认 0（无限制），让 AVFoundation 自行决定缓冲分配。

        // 2) 解码分辨率上限
        playerItem.preferredMaximumResolution = CGSize(width: screenPixelWidth, height: screenPixelHeight)

        if #available(macOS 10.15, *) {
            playerItem.seekingWaitsForVideoCompositionRendering = false
        }
        playerItem.audioTimePitchAlgorithm = .timeDomain
        if videoURL.isFileURL {
            // 外置盘（含慢速 USB HDD）IO 带宽有限，需要更大的前向缓冲防止 stall；
            // 内置盘超大文件收紧缓冲，避免 page cache 压力过高；
            // 内置盘普通文件使用标准缓冲。
            let isExternal = Self.isExternalVolume(videoURL)
            let effectiveBufferDuration: TimeInterval = {
                let fileSize = (try? FileManager.default.attributesOfItem(atPath: videoURL.path))?[.size] as? UInt64 ?? 0
                let isLargeFile = fileSize > 1_000_000_000
                if isExternal {
                    // 外置盘：大文件给更多缓冲，应对 4K 高码率 + 慢速 IO
                    return isLargeFile
                        ? externalVolumeLargeVideoForwardBufferDuration
                        : externalVolumeVideoForwardBufferDuration
                } else {
                    // 内置盘：大文件适当收紧，普通文件走标准
                    return isLargeFile
                        ? largeLocalVideoForwardBufferDuration
                        : localVideoForwardBufferDuration
                }
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
        // 外置盘：IO 带宽有限，开启防卡顿等待让系统在 stall 前提前缓冲。
        // 内置盘本地短环壁纸：关闭等待，避免 looper/IO 边界把 AVPlayerLayer 闪黑一帧。
        // 网络源仍走系统默认「尽量不卡顿」策略。
        if videoURL.isFileURL {
            queuePlayer.automaticallyWaitsToMinimizeStalling = Self.isExternalVolume(videoURL)
        } else {
            queuePlayer.automaticallyWaitsToMinimizeStalling = true
        }
        queuePlayer.preventsDisplaySleepDuringVideoPlayback = false

        var looper: AVPlayerLooper? = nil
        if enableLooping {
            looper = AVPlayerLooper(player: queuePlayer, templateItem: playerItem)
        } else {
            queuePlayer.insert(playerItem, after: nil)
        }

        let playerID = ObjectIdentifier(queuePlayer)
        anchoredVideoPathByPlayerID[playerID] = videoURL.standardizedFileURL.path
        sourceVideoItemByPlayerID[playerID] = playerItem

        return (queuePlayer, looper, playerItem)
    }

    /// 判断视频文件是否位于外置卷宗（如 USB HDD/SSD、NAS 等）。
    /// 用于决定播放缓冲策略：外置盘 IO 带宽受限，需要更大的前向缓冲。
    private static func isExternalVolume(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.volumeIsInternalKey])
        // volumeIsInternal 为 nil（无法读取）时保守按内置处理，避免误判
        return values?.volumeIsInternal == false
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

    private func createWindow(for screen: NSScreen, videoURL: URL, muted: Bool) throws {
        let screenID = screen.wallpaperScreenIdentifier
        // 全屏覆盖（含菜单栏条带下方）。窗口 alpha=0.99999 近乎不透明（reveal 时设置），
        // 壁纸层不被视频层挂起，菜单栏 backdrop 懒采样能跟随 poster 更新。
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
        // isOpaque=false + alpha=0.99999（reveal 时设置，常驻近乎不透明）：窗口按
        // 半透明层合成，必须与壁纸层混合 → 壁纸层不被视频层挂起 → 菜单栏
        // backdrop 懒采样能跟随 poster 更新（alpha=1 时壁纸层被挂起，菜单栏
        // 永不更新——实测验证）。0.99999 与 1 视觉无差别。
        window.isOpaque = false
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
        let schedulerConfig = WallpaperSchedulerService.shared.config.resolvedDisplayConfig(for: screenID)
        let isOnEndMode = schedulerConfig.isEnabled && schedulerConfig.isOnEndMode

        // 统一使用 AVPlayerLooper 简单循环播放原视频；同文件多屏机会式共享解码管线。
        let playbackURL = videoURL
        let components = resolvePlayerComponents(
            for: screen,
            videoURL: playbackURL,
            muted: muted,
            enableLooping: !isOnEndMode
        )
        // 同一次多屏应用会依次进入 createWindow，但所有屏拿到的是同一个
        // AVQueuePlayer。只有第一个引用者可以负责启动这条共享管线的 preroll；
        // 若每个屏都同时对同一个尚未启动的 player 调 preroll，部分视频会让
        // AVFoundation 的启动回调互相等待，表现为两个屏一起设置时永久卡首帧。
        // 后续屏只观察自己的 AVPlayerLayer，领头屏开始播放后自然收到首帧。
        let isSharedWarmupFollower = !screenIDsReferencingPlayer(components.player).isEmpty
        assignPlayerComponents(components, to: screenID)

        containerView.playerLayer.videoGravity = .resizeAspectFill
        if !isSharedWarmupFollower {
            containerView.attachPlayer(components.player)
        }

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
        prepareFrameInterpolation(
            screenID: screenID,
            screen: screen,
            videoURL: videoURL,
            player: components.player,
            item: components.item,
            containerView: containerView
        )

        // 跨类型启动放在旧 Web/Scene 后方预热。普通启动也不能用严格 alpha=0，
        // 否则桌面层窗口可能拿不到 WindowServer surface，AVPlayerLayer 的首帧
        // 就绪事件永远不来；用近透明值保持可合成，首帧到达后再正式 reveal。
        // 菜单栏/非 key 时只 orderBack 仍可能拿不到 surface，需 orderFrontRegardless
        // 再压回 desktop 层，否则 isReadyForDisplay 一直不来，表现为“要点一下才变”。
        let isCrossTypeWarmup = pendingCrossTypeVideoScreenIDs.contains(screenID)
        window.alphaValue = isCrossTypeWarmup ? 1 : 0.02
        window.orderFrontRegardless()
        window.orderBack(nil)
        window.displayIfNeeded()
        CATransaction.flush()

        // 视频加载期间先显示封面图，避免黑屏（同步关闭时尤为关键）
        showPosterImage(for: screenID)

        // AVPlayerLooper 会复制 templateItem 放进队列；传入 Looper 的原始 item
        // 可能永远保持 .unknown，即使队列里的副本已经能够解码。因此不能等待
        // components.item.status 再调用 play。先在旧壁纸后方启动解码，并直接以
        // AVPlayerLayer 的首个可显示帧作为提交条件。
        let player = components.player
        // 同一屏幕可能在前一个 AVPlayerItem 尚未 ready 时再次收到“下一张/设置”请求。
        // 旧 KVO 回调和旧超时不能仅凭 screenID 操作，否则会误删后一次请求刚创建的
        // window / observer，最终表现为连续点击后当前壁纸再也切不走。
        let readinessToken = UUID()
        playerItemObserverTokens[screenID] = readinessToken
        let presentPreparedVideo: @MainActor @Sendable () async -> Void = { [weak self, weak window] in
            guard let self, let window,
                  self.playerItemObserverTokens[screenID] == readinessToken,
                  self.windows[screenID] === window else { return }
            // 清理 observer 和超时
            self.playerItemObservers[screenID]?.invalidate()
            self.playerItemObservers.removeValue(forKey: screenID)
            self.playerItemObserverTokens.removeValue(forKey: screenID)
            self.fadeInTimeouts[screenID]?.cancel()
            self.fadeInTimeouts.removeValue(forKey: screenID)
            // 预卷或真实 layer 首帧已经完成，此时才移除封面并提交切换。
            self.hidePosterImage(for: screenID)
            // Looper 可能在预热期间插入新的循环 item，提交前再次同步音频策略。
            let screenVolume = self.volumeByScreen[screenID] ?? self.volume
            self.applyPlayerAudioPolicy(player, muted: self.isMuted, volume: screenVolume)
            if !self.isPaused {
                player.play()
            }
            if self.screenIDsReferencingPlayer(player).count > 1 {
                self.scheduleSharedFollowerAttachments(for: player)
            }

            if self.pendingCrossTypeVideoScreenIDs.contains(screenID) {
                self.pendingCrossTypeVideoScreenIDs.remove(screenID)
                guard let transitionScreen = NSScreen.screens.first(where: {
                    $0.wallpaperScreenIdentifier == screenID
                }) else {
                    self.teardownWindow(for: screenID)
                    return
                }
                await WallpaperCrossTypeTransitionCoordinator.shared.commitPreparedContent(on: [transitionScreen]) {
                    await WallpaperEngineXBridge.shared.ensureStoppedForNonCLIWallpaperForTransition(
                        for: transitionScreen
                    )
                    StaticImageWallpaperOverlayManager.shared.clearState(for: transitionScreen)
                    Self.revealDesktopWallpaperWindow(window)
                    window.orderFrontRegardless()
                }
                self.presentedVideoScreenIDs.insert(screenID)
                self.scheduleDisplaySwitchStableRelease(screenID: screenID, reason: "crossTypeVideoReady")
                return
            }

            self.presentDesktopWallpaperWindow(window, animated: Self.shouldAnimateDesktopPresentation)
            self.presentedVideoScreenIDs.insert(screenID)
            self.scheduleDisplaySwitchStableRelease(screenID: screenID, reason: "windowReady")
        }

        let observer = containerView.playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { _, change in
            guard change.newValue == true else { return }
            Task { @MainActor in
                await presentPreparedVideo()
            }
        }
        playerItemObservers[screenID] = observer

        // Looper 异步把 templateItem 的副本放入队列。窗口在旧 Scene/Web 后方时，
        // WindowServer 可能对完全遮挡的 AVPlayerLayer 做合成裁剪，导致 layer 的
        // isReadyForDisplay 永远不变。等待真实 currentItem 后用 AVPlayer.preroll；
        // preroll 完成代表媒体已准备播放，不依赖窗口可见性，随后才开始短黑场。
        let warmupVolume = volumeByScreen[screenID] ?? volume
        applyPlayerAudioPolicy(player, muted: isMuted, volume: warmupVolume)
        if !isSharedWarmupFollower {
            // 菜单栏切换时 isReadyForDisplay / preroll 回调可能长期不来。
            // 短延迟强制 reveal，避免一直停在旧采样直到用户点一下其它 App。
            if !isCrossTypeWarmup {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                    Task { @MainActor in
                        await presentPreparedVideo()
                    }
                }
            }
            Task { @MainActor [weak self, weak player, weak window] in
                guard let self, let player, let window else { return }
                let deadline = Date().addingTimeInterval(30)
                while Date() < deadline {
                    guard self.playerItemObserverTokens[screenID] == readinessToken,
                          self.windows[screenID] === window else { return }
                    if let currentItem = player.currentItem {
                        if currentItem.status == .failed {
                            AppLogger.error(.wallpaper, "Video warmup item failed", metadata: [
                                "screenID": screenID,
                                "video": videoURL.lastPathComponent,
                                "error": currentItem.error?.localizedDescription ?? "nil"
                            ])
                            return
                        }
                        if currentItem.status == .readyToPlay {
                            self.applyPlayerAudioPolicy(player, muted: self.isMuted, volume: warmupVolume)
                            if !self.isPaused {
                                player.play()
                            }
                            player.preroll(atRate: 1.0) { success in
                                Task { @MainActor in
                                    // preroll 失败也强制 reveal：菜单栏路径上 success=false 很常见，
                                    // 继续等 isReadyForDisplay 会卡到用户点一下才动。
                                    await presentPreparedVideo()
                                    if !success {
                                        AppLogger.debug(.wallpaper, "Video preroll reported failure; forced reveal", metadata: [
                                            "screenID": screenID,
                                            "video": videoURL.lastPathComponent
                                        ])
                                    }
                                }
                            }
                            return
                        }
                    }
                    try? await Task.sleep(nanoseconds: 25_000_000)
                }
            }
        } else {
            AppLogger.debug(.wallpaper, "Shared video follower waiting for leader warmup", metadata: [
                "screenID": screenID,
                "video": videoURL.lastPathComponent,
                "owners": screenIDsReferencingPlayer(player).filter { $0 != screenID }.sorted().joined(separator: ",")
            ])
            enqueueSharedFollowerAttachment(screenID: screenID, player: player)
        }
        AppLogger.debug(.wallpaper, "Video first-frame warmup started", metadata: [
            "screenID": screenID,
            "video": videoURL.lastPathComponent,
            "crossType": isCrossTypeWarmup,
            "sharedFollower": isSharedWarmupFollower,
            "queueItems": player.items().count,
            "templateStatus": components.item.status.rawValue
        ])

        // 这里只是损坏文件/解码器无响应的最终保护。正常提交完全由真实首帧触发，
        // 不再依赖 templateItem.status 或人为延时。
        let itemReadyTimeout: TimeInterval = (isCrossTypeWarmup || isSharedWarmupFollower) ? 30.0 : 12.0
        let timeout = DispatchWorkItem { [weak self] in
            guard let self,
                  self.playerItemObserverTokens[screenID] == readinessToken,
                  self.windows[screenID] === window,
                  self.playerItemObservers[screenID] != nil else { return }
            self.playerItemObservers[screenID]?.invalidate()
            self.playerItemObservers.removeValue(forKey: screenID)
            self.playerItemObserverTokens.removeValue(forKey: screenID)
            self.fadeInTimeouts.removeValue(forKey: screenID)
            if self.pendingCrossTypeVideoScreenIDs.remove(screenID) != nil {
                AppLogger.error(.wallpaper, "Cross-type video first-frame timeout", metadata: [
                    "screenID": screenID,
                    "video": videoURL.lastPathComponent,
                    "timeout": itemReadyTimeout,
                    "templateStatus": components.item.status.rawValue,
                    "currentItemStatus": player.currentItem?.status.rawValue ?? -1,
                    "itemError": player.currentItem?.error?.localizedDescription
                        ?? components.item.error?.localizedDescription
                        ?? "nil"
                ])
                self.teardownWindow(for: screenID)
                NSLog("[VideoWallpaperManager] Cross-type video first-frame timeout on \(screenID); old wallpaper kept visible")
                return
            }
            // 超时兜底，隐藏封面图
            self.hidePosterImage(for: screenID)
            // ready 超时时也会直接播放，所以这里同样要先禁用静音状态下的音频轨。
            let screenVolume = self.volumeByScreen[screenID] ?? self.volume
            self.applyPlayerAudioPolicy(player, muted: self.isMuted, volume: screenVolume)
            if !self.isPaused {
                player.play()
            }
            // 超时路径一律瞬时显现，避免后台再卡在 animator 上。
            self.presentDesktopWallpaperWindow(window, animated: false)
            self.presentedVideoScreenIDs.insert(screenID)
            self.scheduleDisplaySwitchStableRelease(screenID: screenID, reason: "windowReadyTimeout")
        }
        fadeInTimeouts[screenID] = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + itemReadyTimeout, execute: timeout)

        // 如果是"播完即换"模式，添加视频播放完成的观察者。
        // 共享同一 AVQueuePlayer 时只挂一个 observer，避免 end 事件被重复派发。
        if isOnEndMode {
            onEndModeScreens.insert(screenID)
            let hasSharedPlaybackObserver = playbackEndObservers.keys.contains { existingScreenID in
                existingScreenID != screenID && players[existingScreenID] === components.player
            }
            if !hasSharedPlaybackObserver {
                setupPlaybackEndObserver(for: screenID, player: components.player, item: components.item)
            }
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

                let attachedOnEndScreenIDs = self.screenIDsReferencingPlayer(player)
                    .filter(self.onEndModeScreens.contains)
                guard !attachedOnEndScreenIDs.isEmpty else { return }

                // 结束帧的 AVPlayerLayer 可能清空为黑色。先盖上 poster，再等待 seek
                // 真正完成后派发切换事件；不能在异步 seek 发起后立即暂停。
                // 同一文件共享播放时，所有引用屏会同时到达结尾；先给每屏盖图，
                // 独立调度模式再分别派发切换，不能只处理 observer 的持有屏。
                for attachedScreenID in attachedOnEndScreenIDs {
                    self.showPosterImage(for: attachedScreenID)
                }
                player.pause()
                player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak player] _ in
                    guard let player else { return }
                    DispatchQueue.main.async {
                        guard let self else { return }
                        let liveScreenIDs = self.screenIDsReferencingPlayer(player)
                            .filter(self.onEndModeScreens.contains)
                        guard !liveScreenIDs.isEmpty else { return }
                        player.pause()
                        // 全局同步只需要一个逻辑事件；独立调度则每个引用屏都要收到事件。
                        let notificationScreenIDs = WallpaperSchedulerService.shared.isGlobalDisplaySyncEnabled
                            ? Array(liveScreenIDs.prefix(1))
                            : liveScreenIDs
                        for liveScreenID in notificationScreenIDs {
                            DistributedNotificationCenter.default().postNotificationName(
                                notificationName,
                                object: nil,
                                userInfo: ["screenID": liveScreenID],
                                deliverImmediately: true
                            )
                        }
                    }
                }
            }
        }
        playbackEndObservers[screenID] = observer
    }

    private func teardownAllWindows(preserveDisplaySwitchGate: Bool = false) {
        cancelPendingGlobalVideoTransition(reason: "teardownAllWindows")
        // 0. 取消上一次未执行的延迟释放，避免快速切换时多组 AVPlayer 并发驻留
        pendingPlayerCleanups.forEach { $0.cancel() }
        pendingPlayerCleanups.removeAll()
        pendingWindowCleanups.forEach { $0.cancel() }
        pendingWindowCleanups.removeAll()
        if !preserveDisplaySwitchGate {
            displaySwitchReleaseWorkItem?.cancel()
            displaySwitchReleaseWorkItem = nil
            activeDisplaySwitchScreenID = nil
            pendingDisplaySwitches.removeAll()
        }
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
        pendingCrossTypeVideoScreenIDs.removeAll()
        presentedVideoScreenIDs.removeAll()

        // 1. 先断开所有 playerLayer 与 player 的关联，避免渲染层持有已释放的 player
        for window in windows.values {
            if let contentView = window.contentView as? WallpaperVideoContainerView {
                contentView.cancelPlayerTransitionIfNeeded()
                contentView.attachPlayer(nil)
            }
        }

        // 2. 停止 looper
        for looper in loopers.values {
            looper.disableLooping()
        }
        loopers.removeAll()

        // 3. 暂停 player 并清空 items（按实例去重：共享解码时多屏指向同一 AVQueuePlayer）
        // ⚠️ 关键：不要立即释放 player！
        // macOS 26.5 beta 的 MediaToolbox 中 FigNotificationCenterRemoveWeakListener
        // 在后台线程异步清理 AVPlayerItem 的通知监听器，如果 player 在此期间被释放，
        // 后台线程访问已释放对象 → 主线程 autorelease pool drain 时 objc_release 已死对象 → SIGSEGV
        // 修复：先暂停+清空，然后延迟释放，让后台清理完成
        var uniquePlayers: [AVQueuePlayer] = []
        var seenPlayerIDs = Set<ObjectIdentifier>()
        for player in players.values {
            let id = ObjectIdentifier(player)
            guard seenPlayerIDs.insert(id).inserted else { continue }
            uniquePlayers.append(player)
        }
        for player in transitionRetainedPlayers.values {
            let id = ObjectIdentifier(player)
            guard seenPlayerIDs.insert(id).inserted else { continue }
            uniquePlayers.append(player)
        }
        for player in uniquePlayers {
            // layer 已在上方断开；这里再清 looper 队列与 currentItem。
            player.pause()
            player.rate = 0
            player.removeAllItems()
            player.replaceCurrentItem(with: nil)
        }
        players.removeAll()
        transitionRetainedPlayers.removeAll()
        transitionRetainedPlayerOwners.removeAll()
        sharedFollowerAttachmentTasks.values.forEach { $0.cancel() }
        sharedFollowerAttachmentTasks.removeAll()
        pendingSharedFollowerScreenIDsByPlayerID.removeAll()
        anchoredVideoPathByPlayerID.removeAll()
        sourceVideoItemByPlayerID.removeAll()
        screenTransitionSourceRollbacks.removeAll()
        sharedVideoLooper?.disableLooping()
        sharedVideoLooper = nil
        sharedVideoItem = nil
        sharedVideoPlayer = nil
        usesSharedVideoDecoder = false
        videoSizes.removeAll()
        clearVideoLetterboxState()
        clearFrameInterpolationState()

        // 延迟释放 player，让 MediaToolbox 后台线程完成 FigNotificationCenter 清理。
        // 延迟完成后必须移除 work item，否则闭包会继续持有旧 player。
        retainPlayersTemporarily(uniquePlayers)

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
            isPaused: userRequestedPause,
            volume: volume,
            volumeByScreen: volumeByScreen.isEmpty ? nil : volumeByScreen,
            volumeByScreenFingerprint: volumeByScreenFingerprint.isEmpty ? nil : volumeByScreenFingerprint,
            usesSharedVideoDecoder: usesSharedVideoDecoder,
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

    /// 显示预览图（用于锁屏、播完即换结束帧覆盖等）。
    /// 本地 fileURL 优先同步加载，避免结束瞬间 AVPlayerLayer 清空时露出桌面。
    private func showPosterImage(for screenID: String) {
        guard let posterURL = posterURLByScreen[screenID]
            ?? NSScreen.screens.first(where: {
                $0.wallpaperScreenIdentifier == screenID
            }).flatMap(posterURL(for:)) else { return }

        if externalRenderingActive {
            guard NSScreen.screens.contains(where: {
                $0.wallpaperScreenIdentifier == screenID
            }) else {
                return
            }

            let showLocalPoster: (URL) -> Void = { [weak self] localURL in
                guard let self,
                      self.externalRenderingActive,
                      let currentScreen = NSScreen.screens.first(where: {
                          $0.wallpaperScreenIdentifier == screenID
                      }),
                      self.posterURL(for: currentScreen)?.standardizedFileURL
                          == posterURL.standardizedFileURL,
                      let currentIndex = self.externalScreenIndex(for: currentScreen) else {
                    return
                }
                self.externalRenderer.sendCommandFireAndForget(
                    .showPoster(screen: currentIndex, path: localURL.path),
                )
            }

            if posterURL.isFileURL, FileManager.default.fileExists(atPath: posterURL.path) {
                showLocalPoster(posterURL)
            } else {
                Task { @MainActor [weak self] in
                    guard let self,
                          let localURL = await self.materializeExternalPoster(
                              posterURL,
                              screenID: screenID
                          ) else { return }
                    showLocalPoster(localURL)
                }
            }
            return
        }

        guard let window = windows[screenID],
              let containerView = window.contentView as? WallpaperVideoContainerView else { return }

        // 如果已经显示了预览图，不再重复加载
        guard !containerView.isShowingPoster else { return }

        let token = UUID()
        posterDisplayTokens[screenID] = token

        if let cached = loadPosterImageSync(from: posterURL) {
            guard posterDisplayTokens[screenID] == token,
                  windows[screenID]?.contentView === containerView else {
                return
            }
            containerView.showPoster(cached)
            return
        }

        // 非本地 / 同步失败时再异步兜底
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
        if externalRenderingActive {
            guard !externalPendingCommitScreenIDs.contains(screenID),
                  !externalIsPaused(screenID: screenID),
                  let screen = NSScreen.screens.first(where: {
                      $0.wallpaperScreenIdentifier == screenID
                  }),
                  let screenIndex = externalScreenIndex(for: screen) else {
                return
            }
            externalRenderer.sendCommandFireAndForget(
                .hidePoster(screen: screenIndex)
            )
            return
        }

        invalidatePosterDisplay(for: screenID)
        guard let window = windows[screenID],
              let containerView = window.contentView as? WallpaperVideoContainerView else { return }

        containerView.hidePoster()
    }

    private func invalidatePosterDisplay(for screenID: String) {
        posterDisplayTokens[screenID] = UUID()
    }

    /// 同步读取本地 poster（fileURL）。失败返回 nil，由调用方决定是否异步回退。
    private func loadPosterImageSync(from url: URL) -> NSImage? {
        let cacheKey = url.standardizedFileURL.path
        if let cached = posterImageCache[cacheKey] {
            return cached
        }
        guard url.isFileURL else { return nil }
        guard let image = NSImage(contentsOf: url) else { return nil }
        posterImageCache[cacheKey] = image
        // 简单上限：避免长期轮换把整份 poster 都留在内存。
        if posterImageCache.count > 24 {
            let overflow = posterImageCache.count - 24
            for key in posterImageCache.keys.prefix(overflow) {
                posterImageCache.removeValue(forKey: key)
            }
        }
        return image
    }

    /// 从 URL 加载预览图
    private func loadPosterImage(from url: URL) async -> NSImage? {
        if let cached = loadPosterImageSync(from: url) {
            return cached
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let image = NSImage(data: data) else { return nil }
            posterImageCache[url.standardizedFileURL.path] = image
            return image
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
    /// 显式全局共享解码模式；旧版无此字段时按 false 恢复。
    let usesSharedVideoDecoder: Bool?
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
        usesSharedVideoDecoder = try container.decodeIfPresent(Bool.self, forKey: .usesSharedVideoDecoder)
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
        usesSharedVideoDecoder: Bool? = nil,
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
        self.usesSharedVideoDecoder = usesSharedVideoDecoder
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
        case usesSharedVideoDecoder
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

/// 视频切到照片 / Scene / Web 时的提交协调器。
///
/// 新内容必须先在旧视频后方完成准备。提交时使用旧桌面快照覆盖 teardown 空档，
/// 再淡出快照露出新内容，既避免黑场也保留跨类型转场的连续感。
@MainActor
final class WallpaperCrossTypeTransitionCoordinator {
    static let shared = WallpaperCrossTypeTransitionCoordinator()

    struct RequestToken: Sendable {
        fileprivate let generationsByScreen: [String: UInt64]
    }

    private var transitionGenerationByScreen: [String: UInt64] = [:]
    private var snapshotWindowsByScreen: [String: NSWindow] = [:]
    private let crossTypeFadeDuration: TimeInterval = 0.28

    private init() {}

    func beginRequest(on screens: [NSScreen]) -> RequestToken {
        var generations: [String: UInt64] = [:]
        for screenID in Set(screens.map(\.wallpaperScreenIdentifier)) {
            removeSnapshotWindow(for: screenID)
            let generation = (transitionGenerationByScreen[screenID] ?? 0) &+ 1
            transitionGenerationByScreen[screenID] = generation
            generations[screenID] = generation
        }
        return RequestToken(generationsByScreen: generations)
    }

    func invalidatePendingRequests(on screens: [NSScreen]) {
        _ = beginRequest(on: screens)
    }

    func isCurrent(_ token: RequestToken) -> Bool {
        isCurrent(generations: token.generationsByScreen)
    }

    func commitPreparedContent(
        on screens: [NSScreen],
        requestToken: RequestToken? = nil,
        snapshotFallback: (@MainActor (NSScreen) -> NSImage?)? = nil,
        revealPreparedContent: (@MainActor () async -> Void)? = nil,
        teardownOldContent: @MainActor () async -> Void
    ) async {
        let transitionStartedAt = Date()
        let uniqueScreens = Dictionary(
            screens.map { ($0.wallpaperScreenIdentifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        guard !uniqueScreens.isEmpty else {
            await teardownOldContent()
            return
        }

        let activeToken = requestToken ?? beginRequest(on: Array(uniqueScreens.values))
        guard isCurrent(activeToken) else { return }
        let generations = activeToken.generationsByScreen
        guard Set(generations.keys) == Set(uniqueScreens.keys) else { return }
        var snapshots: [String: NSWindow] = [:]
        for (screenID, screen) in uniqueScreens {
            removeSnapshotWindow(for: screenID)
            let snapshot = captureDesktopSnapshot(for: screen)
                ?? snapshotFallback?(screen)
            if let snapshot {
                let window = makeSnapshotWindow(for: screen, image: snapshot)
                snapshotWindowsByScreen[screenID] = window
                snapshots[screenID] = window
                window.orderFrontRegardless()
                window.displayIfNeeded()
            }
        }

        guard isCurrent(generations: generations) else {
            removeMatchingSnapshotWindows(snapshots)
            return
        }
        // Reveal the prepared replacement while the old desktop content (or
        // its captured snapshot) still covers it. This avoids a black
        // compositor frame even when desktop screenshot permission is absent.
        if let revealPreparedContent {
            await revealPreparedContent()
        }

        guard isCurrent(generations: generations) else {
            removeMatchingSnapshotWindows(snapshots)
            return
        }
        if snapshots.isEmpty {
            // 无快照遮罩（未授予屏幕录制权限且无 fallback）：拆除旧内容
            // 期间唯一遮蔽是新窗口本身，必须确保揭示帧已真正合成上屏。
            AppLogger.debug(.wallpaper, "跨类型切换无快照遮罩，依赖新内容先行覆盖", metadata: [
                "screens": uniqueScreens.keys.sorted().joined(separator: ",")
            ])
        }
        // 等待合成器把揭示帧真正呈现出来再拆除旧内容，
        // 否则旧窗口先消失的瞬间会露出黑帧（teardown 可达 1s+）。
        CATransaction.flush()
        CFRunLoopWakeUp(CFRunLoopGetMain())
        try? await Task.sleep(nanoseconds: 80_000_000)

        guard isCurrent(generations: generations) else {
            removeMatchingSnapshotWindows(snapshots)
            return
        }
        let teardownStartedAt = Date()
        await teardownOldContent()

        guard isCurrent(generations: generations) else {
            removeMatchingSnapshotWindows(snapshots)
            return
        }
        // 新内容已在提交前就绪。快照保持旧画面直到同级 desktop window 完成
        // orderFront/orderOut，再通过独立 CA 动画淡出。
        CATransaction.flush()
        CFRunLoopWakeUp(CFRunLoopGetMain())
        await Task.yield()
        fadeOutSnapshotWindows(Array(snapshots.values), duration: crossTypeFadeDuration)
        try? await Task.sleep(nanoseconds: UInt64(crossTypeFadeDuration * 1_000_000_000))

        guard isCurrent(generations: generations) else {
            removeMatchingSnapshotWindows(snapshots)
            return
        }
        removeMatchingSnapshotWindows(snapshots)
        AppLogger.debug(.wallpaper, "Cross-type wallpaper crossfade completed", metadata: [
            "screens": uniqueScreens.keys.sorted().joined(separator: ","),
            "snapshotScreens": snapshots.keys.sorted().joined(separator: ","),
            "teardownMS": Int(Date().timeIntervalSince(teardownStartedAt) * 1_000),
            "totalMS": Int(Date().timeIntervalSince(transitionStartedAt) * 1_000)
        ])
    }

    private func isCurrent(generations: [String: UInt64]) -> Bool {
        generations.allSatisfy { screenID, generation in
            transitionGenerationByScreen[screenID] == generation
        }
    }

    /// 仅在已有屏幕录制权限时捕获；不主动请求权限，拿不到快照就降级为无黑场直切。
    private func captureDesktopSnapshot(for screen: NSScreen) -> NSImage? {
        guard CGPreflightScreenCaptureAccess(),
              let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
              ] as? NSNumber else {
            return nil
        }
        let displayBounds = CGDisplayBounds(number.uint32Value)
        guard let image = CGWindowListCreateImage(
            displayBounds,
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.boundsIgnoreFraming, .bestResolution]
        ) else {
            return nil
        }
        return NSImage(cgImage: image, size: screen.frame.size)
    }

    private func makeSnapshotWindow(for screen: NSScreen, image: NSImage) -> NSWindow {
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.level = .init(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.setFrame(screen.frame, display: false)

        let contentView = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
        let imageView = NSImageView(frame: contentView.bounds)
        imageView.image = image
        imageView.imageScaling = .scaleAxesIndependently
        imageView.imageAlignment = .alignCenter
        imageView.autoresizingMask = [.width, .height]
        contentView.addSubview(imageView)
        window.contentView = contentView
        return window
    }

    private func fadeOutSnapshotWindows(_ windows: [NSWindow], duration: TimeInterval) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for window in windows {
            guard let layer = window.contentView?.layer else { continue }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = layer.presentation()?.opacity ?? layer.opacity
            fade.toValue = 0
            fade.duration = duration
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(fade, forKey: "wallpaperCrossTypeCrossfade")
            layer.opacity = 0
        }
        CATransaction.commit()
        CATransaction.flush()
    }

    private func removeMatchingSnapshotWindows(_ windows: [String: NSWindow]) {
        for (screenID, window) in windows {
            removeSnapshotWindow(for: screenID, ifMatching: window)
        }
    }

    private func removeSnapshotWindow(for screenID: String, ifMatching expected: NSWindow? = nil) {
        guard let window = snapshotWindowsByScreen[screenID],
              expected == nil || window === expected else { return }
        window.orderOut(nil)
        window.close()
        snapshotWindowsByScreen.removeValue(forKey: screenID)
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
private final class WallpaperVideoContainerView: NSView {
    private var storedPosterLayer: CALayer?
    private var grainOverlayView: NSView?
    private var transitionPlayerLayer: AVPlayerLayer?

    /// 是否有已预热的过渡层（交叉淡入准备中/进行中）。
    /// 过渡窗口存在时不执行桌面层提交，避免"旧→新→旧→新"跳变。
    var hasPreparedPlayerTransitionInFlight: Bool { transitionPlayerLayer != nil }

    /// 实际播放视频的 AVPlayerLayer。作为容器 backing layer 的子层，
    /// 通过修改它的 frame 实现 pan/zoom 裁切（容器 backing layer masksToBounds 自然裁剪）。
    /// 交叉淡入结束时可晋升已预热的 transition layer，故为 var。
    private var avPlayerLayer = AVPlayerLayer()
    /// 垫在 AVPlayerLayer 下方：当 `isReadyForDisplay == false`（looper 切 item / 解码空帧）
    /// 时用最近一帧挡住 window 纯黑底，避免桌面「暗闪一下」而 UI 窗口不受影响。
    private let freezeFrameLayer = CALayer()
    private var readyForDisplayObservation: NSKeyValueObservation?
    private var lastFreezeCaptureTime: CFTimeInterval = 0
    private let freezeCaptureMinInterval: CFTimeInterval = 0.35

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

        freezeFrameLayer.contentsGravity = .resizeAspectFill
        freezeFrameLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        freezeFrameLayer.frame = bounds
        freezeFrameLayer.isHidden = false
        container.addSublayer(freezeFrameLayer)

        avPlayerLayer.videoGravity = .resizeAspectFill
        avPlayerLayer.needsDisplayOnBoundsChange = true
        avPlayerLayer.backgroundColor = CGColor(gray: 0, alpha: 0)
        avPlayerLayer.frame = bounds
        container.addSublayer(avPlayerLayer)

        startReadyForDisplayObservation()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        readyForDisplayObservation?.invalidate()
    }

    var playerLayer: AVPlayerLayer { avPlayerLayer }

    /// 统一挂 player，并在 ready 前/空帧时用 freeze 层兜底。
    func attachPlayer(_ player: AVQueuePlayer?) {
        if avPlayerLayer.player !== player {
            avPlayerLayer.player = player
        }
        // 新 player 尚未出帧时先露 freeze（若有上一帧则更稳），避免挂载瞬间黑闪。
        if player == nil {
            freezeFrameLayer.isHidden = false
        } else if !avPlayerLayer.isReadyForDisplay {
            freezeFrameLayer.isHidden = false
        }
        // KVO 在 init 已挂上；player 替换后 status 会再推一次。
        refreshFreezeFrameVisibility()
    }

    private func startReadyForDisplayObservation() {
        readyForDisplayObservation?.invalidate()
        // KVO 回调非 MainActor：只跨隔离传递 Sendable 的 Bool（不捕获 layer），再在主 actor 上更新 UI。
        readyForDisplayObservation = avPlayerLayer.observe(
            \.isReadyForDisplay,
            options: [.initial, .new]
        ) { [weak self] _, change in
            let readyFromChange = change.newValue // Bool? 为 Sendable；.initial 时可能为 nil
            Task { @MainActor [weak self] in
                guard let self else { return }
                let isReady = readyFromChange ?? self.avPlayerLayer.isReadyForDisplay
                self.handleReadyForDisplayChanged(isReady)
            }
        }
    }

    @MainActor
    private func handleReadyForDisplayChanged(_ isReady: Bool) {
        if isReady {
            captureFreezeFrameIfNeeded(force: false)
            // 延迟半帧再藏 freeze，避免 ready 瞬间 layer 仍提交空缓冲。
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.avPlayerLayer.isReadyForDisplay {
                    self.freezeFrameLayer.isHidden = true
                }
            }
        } else {
            freezeFrameLayer.isHidden = false
        }
    }

    @MainActor
    private func refreshFreezeFrameVisibility() {
        handleReadyForDisplayChanged(avPlayerLayer.isReadyForDisplay)
    }

    /// 从当前 AVPlayerLayer 抓一帧作为空帧垫层。失败时保留旧 contents。
    private func captureFreezeFrameIfNeeded(force: Bool) {
        guard avPlayerLayer.isReadyForDisplay else { return }
        let now = CACurrentMediaTime()
        if !force, now - lastFreezeCaptureTime < freezeCaptureMinInterval {
            return
        }
        lastFreezeCaptureTime = now

        let targetFrame = currentLayerFrame ?? avPlayerLayer.frame
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let sourceLayer = avPlayerLayer.presentation() ?? avPlayerLayer

        // 1) 优先直接复用 layer.contents（AVPlayer 出帧后有时可用，且比 render 便宜）。
        if let contents = sourceLayer.contents {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            freezeFrameLayer.contents = contents
            freezeFrameLayer.contentsScale = sourceLayer.contentsScale > 0 ? sourceLayer.contentsScale : scale
            freezeFrameLayer.contentsGravity = sourceLayer.contentsGravity
            freezeFrameLayer.frame = targetFrame
            CATransaction.commit()
            return
        }

        // 2) 回退：render 到 bitmap（部分系统上对 AVPlayerLayer 可能得到空图，失败则保留旧 contents）。
        let bounds = avPlayerLayer.bounds
        guard bounds.width > 1, bounds.height > 1 else { return }
        let pixelSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        guard pixelSize.width > 1, pixelSize.height > 1 else { return }

        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(pixelSize.width.rounded()),
            pixelsHigh: Int(pixelSize.height.rounded()),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let rep else { return }
        rep.size = bounds.size
        NSGraphicsContext.saveGraphicsState()
        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = ctx
            let cgCtx = ctx.cgContext
            cgCtx.saveGState()
            cgCtx.translateBy(x: 0, y: bounds.height)
            cgCtx.scaleBy(x: 1, y: -1)
            sourceLayer.render(in: cgCtx)
            cgCtx.restoreGState()
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let cgImage = rep.cgImage else { return }
        // 全黑抓帧没有意义，丢掉以免用黑图盖住旧 freeze。
        if isMostlyBlack(cgImage) { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        freezeFrameLayer.contents = cgImage
        freezeFrameLayer.contentsScale = scale
        freezeFrameLayer.contentsGravity = .resizeAspectFill
        freezeFrameLayer.frame = targetFrame
        CATransaction.commit()
    }

    private func isMostlyBlack(_ image: CGImage) -> Bool {
        let width = min(image.width, 32)
        let height = min(image.height, 32)
        guard width > 0, height > 0 else { return true }
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return false
        }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = ctx.data else { return false }
        let ptr = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var sum = 0
        let sampleCount = width * height
        var i = 0
        while i < sampleCount {
            let o = i * 4
            sum += Int(ptr[o]) + Int(ptr[o + 1]) + Int(ptr[o + 2])
            i += 1
        }
        // 平均每通道 < 6 视为黑帧
        return Double(sum) / Double(sampleCount * 3) < 6
    }

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
            freezeFrameLayer.frame = viewBounds
            // 过渡层与主视频层同坐标系（父 layer），必须用 frame 而非 bounds。
            transitionPlayerLayer?.frame = avPlayerLayer.frame
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
        freezeFrameLayer.frame = computedLayerFrame
        currentLayerFrame = computedLayerFrame
        transitionPlayerLayer?.frame = avPlayerLayer.frame

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
    }

    func cancelPlayerTransitionIfNeeded() {
        transitionPlayerLayer?.player = nil
        transitionPlayerLayer?.removeFromSuperlayer()
        transitionPlayerLayer = nil
    }

    /// Attach an incoming shared player to an almost-transparent layer so AVFoundation
    /// actually decodes a presentable frame while the old main layer remains visible.
    @discardableResult
    func preparePlayerForCrossfade(_ player: AVQueuePlayer) -> AVPlayerLayer {
        cancelPlayerTransitionIfNeeded()
        let incoming = AVPlayerLayer(player: player)
        incoming.videoGravity = avPlayerLayer.videoGravity
        incoming.needsDisplayOnBoundsChange = true
        incoming.frame = avPlayerLayer.frame
        // A literal zero opacity layer can be culled and never become readyForDisplay.
        incoming.opacity = 0.001
        layer?.addSublayer(incoming)
        transitionPlayerLayer = incoming
        return incoming
    }

    func discardPreparedPlayerTransition() {
        transitionPlayerLayer?.player = nil
        transitionPlayerLayer?.removeFromSuperlayer()
        transitionPlayerLayer = nil
    }

    /// 将已经预热的图层淡入旧图层上方。提交时直接晋升同一个
    /// `AVPlayerLayer`，避免把同一 player 重新挂到新 layer 时重建输出并闪黑。
    func crossfadePreparedPlayer(
        _ newPlayer: AVQueuePlayer,
        duration: TimeInterval,
        completion: @escaping () -> Void
    ) {
        guard let incoming = transitionPlayerLayer, incoming.player === newPlayer else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            attachPlayer(newPlayer)
            CATransaction.commit()
            completion()
            return
        }

        // 保留旧帧作为 output 重绑期间的最后兜底。正常路径里旧主层会一直留在
        // incoming 下方，直到淡入结束，因此不会露出 window 的黑色底图。
        captureFreezeFrameIfNeeded(force: true)

        var didComplete = false
        var didPromote = false
        var didBeginFade = false
        let finish: () -> Void = {
            guard !didComplete else { return }
            didComplete = true
            completion()
        }

        let promoteIncoming: () -> Bool = { [weak self, weak incoming] in
            guard !didPromote else { return true }
            didPromote = true
            guard let self, let incoming else {
                finish()
                return false
            }

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let outgoing = self.avPlayerLayer
            self.readyForDisplayObservation?.invalidate()
            incoming.opacity = 1
            self.avPlayerLayer = incoming
            if self.transitionPlayerLayer === incoming {
                self.transitionPlayerLayer = nil
            }
            outgoing.player = nil
            outgoing.removeFromSuperlayer()
            self.startReadyForDisplayObservation()
            self.refreshFreezeFrameVisibility()
            CATransaction.commit()
            CATransaction.flush()
            return true
        }

        let beginFade: () -> Void = { [weak self, weak incoming] in
            guard !didBeginFade, !didComplete, let self, let incoming,
                  self.transitionPlayerLayer === incoming,
                  incoming.player === newPlayer else { return }
            didBeginFade = true

            let fadeDuration = max(0.12, duration)
            if duration <= 0.01 {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                incoming.opacity = 1
                CATransaction.commit()
                _ = promoteIncoming()
                finish()
                return
            }

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = incoming.presentation()?.opacity ?? incoming.opacity
            fade.toValue = 1
            fade.duration = fadeDuration
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            incoming.add(fade, forKey: "wallpaperCrossfade")
            incoming.opacity = 1
            CATransaction.commit()
            CATransaction.flush()

            // 显式 CA 动画不依赖 App 是否前台；收尾仍使用固定时序而非 completion。
            // 整个动画期间旧图层仍在下方，所以不会暴露黑底。
            DispatchQueue.main.asyncAfter(deadline: .now() + fadeDuration) {
                guard !didComplete else { return }
                _ = promoteIncoming()
                finish()
            }
        }

        waitForPreparedPlayerToAdvance(
            player: newPlayer,
            layer: incoming,
            timeout: 1.5,
            completion: beginFade
        )
    }

    /// `AVPlayerItem.readyToPlay` 不代表该 layer 已有可合成帧；仅在预热 layer
    /// 已显示且播放时间推进后才开始淡入，防止把尚未产出的首帧放到最上层。
    private func waitForPreparedPlayerToAdvance(
        player: AVQueuePlayer,
        layer: AVPlayerLayer,
        timeout: TimeInterval,
        completion: @escaping () -> Void
    ) {
        let startedAt = CACurrentMediaTime()
        let initialSeconds = player.currentTime().seconds
        let expectsPlaybackProgress = player.rate > 0 || player.timeControlStatus != .paused
        Task { @MainActor [weak self, weak player, weak layer] in
            guard let self, let player, let layer else { return }
            let deadline = startedAt + timeout
            while CACurrentMediaTime() < deadline {
                guard self.transitionPlayerLayer === layer, layer.player === player else { return }
                let currentSeconds = player.currentTime().seconds
                let advanced = !expectsPlaybackProgress
                    || (initialSeconds.isFinite && currentSeconds.isFinite
                        && abs(currentSeconds - initialSeconds) >= 1.0 / 30.0)
                if CACurrentMediaTime() - startedAt >= 0.05,
                   layer.isReadyForDisplay,
                   advanced {
                    completion()
                    return
                }
                try? await Task.sleep(for: .milliseconds(16))
            }

            guard self.transitionPlayerLayer === layer, layer.player === player else { return }
            AppLogger.warn(
                .wallpaper,
                "Prepared video layer did not advance before crossfade timeout",
                metadata: [
                    "layerReady": layer.isReadyForDisplay,
                    "rate": player.rate,
                    "timeControlStatus": player.timeControlStatus.rawValue,
                    "currentSeconds": player.currentTime().seconds,
                    "initialSeconds": initialSeconds
                ]
            )
            completion()
        }
    }

    /// 若主层或过渡层仍引用指定 player，则断开（旧解码管线释放前必须调用）。
    func detach(player: AVQueuePlayer) {
        if transitionPlayerLayer?.player === player {
            transitionPlayerLayer?.player = nil
            transitionPlayerLayer?.removeFromSuperlayer()
            transitionPlayerLayer = nil
        }
        if avPlayerLayer.player === player {
            attachPlayer(nil)
        }
    }

    /// 清掉所有不在 keep 集合里的 layer 引用，避免切换壁纸后旧 AVQueuePlayer 被 layer 拖住不释放。
    func purgeDetachedPlayers(keeping livePlayerIDs: Set<ObjectIdentifier>) {
        if let tp = transitionPlayerLayer?.player as? AVQueuePlayer,
           !livePlayerIDs.contains(ObjectIdentifier(tp)) {
            transitionPlayerLayer?.player = nil
            transitionPlayerLayer?.removeFromSuperlayer()
            transitionPlayerLayer = nil
        }
        if let main = avPlayerLayer.player as? AVQueuePlayer,
           !livePlayerIDs.contains(ObjectIdentifier(main)) {
            attachPlayer(nil)
        }
    }

    /// 双层交叉淡入：旧 AVPlayerLayer 保持可见，新 player 在上层从透明淡入。
    /// 绝不能走纯黑中间帧，否则系统壁纸同步关闭时会露出桌面，副屏表现为“软件壁纸退出”。
    func crossfadeToPlayer(_ newPlayer: AVQueuePlayer, duration: TimeInterval, completion: @escaping () -> Void) {
        cancelPlayerTransitionIfNeeded()
        // 切层前尽量留住旧画面，防止 incoming 未 ready 时露黑。
        captureFreezeFrameIfNeeded(force: true)
        freezeFrameLayer.isHidden = false

        let incoming = AVPlayerLayer(player: newPlayer)
        incoming.videoGravity = avPlayerLayer.videoGravity
        incoming.needsDisplayOnBoundsChange = true
        // 与当前主层同 frame（含 crop/pan/zoom），避免 letterbox 区域闪黑。
        incoming.frame = avPlayerLayer.frame
        // 始终盖在 poster / 旧 player 之上，淡入过程可见；黑场中间帧已去掉。
        layer?.addSublayer(incoming)
        transitionPlayerLayer = incoming

        // App 非活跃时 CA 动画 completion 可能永不触发（自动切换常见场景）。
        // 瞬时切换，保证后台 timer 路径也能立刻看到新壁纸。
        let appActive = NSApp.isActive && NSApp.isRunning
        if !appActive || duration <= 0.01 {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            incoming.opacity = 1
            avPlayerLayer.videoGravity = incoming.videoGravity
            attachPlayer(newPlayer)
            incoming.player = nil
            incoming.removeFromSuperlayer()
            if transitionPlayerLayer === incoming {
                transitionPlayerLayer = nil
            }
            CATransaction.commit()
            completion()
            return
        }

        incoming.opacity = 0
        let fadeDuration = max(0.12, duration)
        var didComplete = false
        let finish: () -> Void = { [weak self, weak incoming] in
            guard let self, let incoming, self.transitionPlayerLayer === incoming else {
                if !didComplete {
                    didComplete = true
                    completion()
                }
                return
            }
            guard !didComplete else { return }
            didComplete = true

            // 新层已盖住旧层：把主 playerLayer 切到新 player，再卸下过渡层。
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.avPlayerLayer.videoGravity = incoming.videoGravity
            self.attachPlayer(newPlayer)
            incoming.player = nil
            incoming.removeFromSuperlayer()
            if self.transitionPlayerLayer === incoming {
                self.transitionPlayerLayer = nil
            }
            CATransaction.commit()

            completion()
        }

        CATransaction.begin()
        CATransaction.setAnimationDuration(fadeDuration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        CATransaction.setCompletionBlock {
            finish()
        }
        incoming.opacity = 1
        CATransaction.commit()

        // 兜底：若 CA completion 被系统挂起，超时后强制完成，避免永远卡在旧画面。
        DispatchQueue.main.asyncAfter(deadline: .now() + fadeDuration + 0.35) {
            finish()
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

        // 同步一份到底层 freeze：hidePoster 后若 AVPlayerLayer 仍空帧，不致露 window 黑底。
        if freezeFrameLayer.contents == nil {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            freezeFrameLayer.contents = cg
            freezeFrameLayer.contentsGravity = .resizeAspectFill
            freezeFrameLayer.frame = currentLayerFrame ?? bounds
            CATransaction.commit()
        }
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
            freezeFrameLayer.frame = bounds
        } else {
            freezeFrameLayer.frame = currentLayerFrame ?? avPlayerLayer.frame
        }
        transitionPlayerLayer?.frame = avPlayerLayer.frame

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
