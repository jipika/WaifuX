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

    private var frameInterpolationEnabled: Bool {
        UserDefaults.standard.object(forKey: "frame_interpolation_enabled") as? Bool ?? false
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
        setPosterAsDesktopWallpaper(posterURL, targetScreen: screen)
        DesktopWallpaperSyncManager.shared.registerWallpaperSet(posterURL, for: screen)
        persistState()
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
    func restorePreviousVideoWallpaperIfAvailable(for screen: NSScreen) -> Bool {
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
            try rebuildWindows(targetScreen: screen)
            persistState()
            print("[VideoWallpaperManager] Restored previous video wallpaper for reconnected display: \(screen.localizedName)")
            return true
        } catch {
            print("[VideoWallpaperManager] Failed to restore previous video wallpaper for \(screen.localizedName): \(error.localizedDescription)")
            return false
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
        reloadPlaybackAfterInPlaceInterpolation(videoURL: videoURL)
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
        return "\(url.standardizedFileURL.path)|\(size)|\(modified)"
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

    private func replacePlayerWithInterpolatedVideoIfNeeded(screenID: String, sourceURL: URL, outputURL: URL) {
        guard frameInterpolationEnabled,
              frameInterpolatedPlaybackURLByScreen[screenID]?.standardizedFileURL != outputURL.standardizedFileURL,
              let screen = NSScreen.screens.first(where: { $0.wallpaperScreenIdentifier == screenID }),
              windows[screenID] != nil,
              videoURLByScreen[screenID]?.standardizedFileURL == sourceURL.standardizedFileURL,
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

    private func replacePlayerWithOriginalVideoIfNeeded(screenID: String, sourceURL: URL) {
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
        frameInterpolationDebugPrint("删除补帧后已切回原视频：屏幕=\(screen.localizedName)，视频=\(sourceURL.lastPathComponent)")
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
            guard !self.isPaused else {
                // 即便全局手动暂停，也要让 AutoPause 重新对齐追踪状态
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
            teardownAllWindows()
            for screen in screensToRebuild {
                do {
                    guard let videoURL = self.videoURL(for: screen) else { continue }
                    try createWindow(for: screen, videoURL: videoURL, muted: isMuted)
                } catch {
                    NSLog("[VideoWallpaperManager] Failed to create window: \(error.localizedDescription)")
                }
            }
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
                        containerView: containerView
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
                            containerView.crossfadeToPlayer(
                                components.player,
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
                        containerView.crossfadeToPlayer(
                            components.player,
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

        // 检查该屏幕是否使用"播完即换"模式
        let schedulerConfig = WallpaperSchedulerService.shared.config.resolvedDisplayConfig(for: screenID)
        let isOnEndMode = schedulerConfig.isEnabled && schedulerConfig.isOnEndMode

        // 统一使用 AVPlayerLooper 简单循环播放原视频。
        let hdrMetadataEnabled = UserDefaults.standard.object(forKey: "hdr_enabled") as? Bool ?? true
        let playbackURL = videoURL
        let components = makePlayerComponents(
            for: screen,
            videoURL: playbackURL,
            muted: muted,
            hdrMetadataEnabled: hdrMetadataEnabled,
            enableLooping: !isOnEndMode
        )
        if let looper = components.looper {
            self.loopers[screenID] = looper
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
        prepareFrameInterpolation(
            screenID: screenID,
            screen: screen,
            videoURL: videoURL,
            player: components.player,
            item: components.item,
            containerView: containerView
        )

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
        if isOnEndMode {
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
        let playersToDelay = players.values.map { $0 }
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
private final class WallpaperVideoContainerView: NSView {
    private var storedPosterLayer: CALayer?
    private var grainOverlayView: NSView?
    private var transitionPlayerLayer: AVPlayerLayer?
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
            transitionPlayerLayer?.frame = avPlayerLayer.bounds
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
        transitionPlayerLayer?.frame = avPlayerLayer.bounds

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
        transitionPlayerLayer?.player = nil
        transitionPlayerLayer?.removeFromSuperlayer()
        transitionPlayerLayer = nil
        blackTransitionLayer?.removeAllAnimations()
        blackTransitionLayer?.removeFromSuperlayer()
        blackTransitionLayer = nil
    }

    func crossfadeToPlayer(_ newPlayer: AVQueuePlayer, duration: TimeInterval, completion: @escaping () -> Void) {
        cancelPlayerTransitionIfNeeded()
        _ = newPlayer

        let blackLayer = CALayer()
        blackLayer.backgroundColor = NSColor.black.cgColor
        blackLayer.frame = bounds
        blackLayer.opacity = 0
        layer?.addSublayer(blackLayer)
        blackTransitionLayer = blackLayer
        let fadeDuration = max(0.12, duration)

        CATransaction.begin()
        CATransaction.setAnimationDuration(fadeDuration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        CATransaction.setCompletionBlock { [weak self, weak blackLayer] in
            guard let self, let blackLayer, self.blackTransitionLayer === blackLayer else {
                completion()
                return
            }

            completion()

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            blackLayer.opacity = 1
            blackLayer.removeFromSuperlayer()
            self.layer?.addSublayer(blackLayer)
            blackLayer.frame = self.bounds
            CATransaction.commit()

            CATransaction.begin()
            CATransaction.setAnimationDuration(fadeDuration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
            CATransaction.setCompletionBlock { [weak self, weak blackLayer] in
                guard let self, let blackLayer, self.blackTransitionLayer === blackLayer else { return }
                blackLayer.removeFromSuperlayer()
                self.blackTransitionLayer = nil
            }
            blackLayer.opacity = 0
            CATransaction.commit()
        }
        blackLayer.opacity = 1
        CATransaction.commit()
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
        transitionPlayerLayer?.frame = avPlayerLayer.bounds
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
