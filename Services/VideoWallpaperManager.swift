import Foundation
import AppKit
import AVFoundation
import CoreGraphics
import QuartzCore
import CoreAudio

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
    /// 每个屏幕独立的 poster 设置任务，避免一块屏的新任务取消掉另一块屏的恢复。
    private var posterTasks: [String: Task<Void, Never>] = [:]
    /// 每个屏幕的独立音量（key 为 screenID），未设置时回退到全局 `volume`
    private var volumeByScreen: [String: Double] = [:]
    /// 音量的物理显示器指纹索引，用于 screenID 变化后的恢复。
    private var volumeByScreenFingerprint: [String: Double] = [:]

    private var windows: [String: WallpaperVideoWindow] = [:]
    private var players: [String: AVQueuePlayer] = [:]
    private var loopers: [String: AVPlayerLooper] = [:]
    /// 每屏视频真实尺寸缓存（naturalSize），供 crop 计算用。设置壁纸时填充。
    private var videoSizes: [String: CGSize] = [:]
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
    private let localVideoForwardBufferDuration: TimeInterval = 3.0
    private let automaticSwitchTransitionDuration: TimeInterval = 0.28
    private let automaticSwitchReadyTimeout: TimeInterval = 1.2

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
        guard localFileURL.isFileURL else {
            throw NSError(domain: "VideoWallpaper", code: 1001, userInfo: [NSLocalizedDescriptionKey: "动态壁纸必须使用本地视频文件。"])
        }

        guard FileManager.default.fileExists(atPath: localFileURL.path) else {
            throw NSError(domain: "VideoWallpaper", code: 1002, userInfo: [NSLocalizedDescriptionKey: "视频文件不存在。"])
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
            containerView.applyCropLayout(nil)
            window.backgroundColor = .black
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

    @objc private func handleCropDidChange(_ note: Notification) {
        guard let screenID = note.userInfo?["screenID"] as? String,
              let screen = NSScreen.screens.first(where: { $0.wallpaperScreenIdentifier == screenID }) else { return }
        applyCropToScreen(screen)
    }

    /// 供 overlay 预览取视频真实尺寸（naturalSize）。
    func videoSize(for screen: NSScreen) -> CGSize? {
        videoSizes[screen.wallpaperScreenIdentifier]
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
        lastAppliedScreenConfigurations.removeAll()
    }

    /// 仅拆掉本机 AVPlayer 视频壁纸，**不**调用 `WallpaperEngineXBridge.stopWallpaper()`。
    /// 在即将通过 CLI 设置 scene / web 等 WE 壁纸前调用，否则会误停 CLI 且把 `isControllingExternalEngine` 清掉，菜单栏暂停恢复会走错视频分支。
    func stopNativeVideoWallpaperOnly(for targetScreen: NSScreen? = nil) {
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
                    LockScreenWallpaperService.shared.clearMirroringSourceCache()
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
        if let looper = loopers[screenID] {
            looper.disableLooping()
            loopers.removeValue(forKey: screenID)
        }
        videoSizes.removeValue(forKey: screenID)
        playerItemObservers[screenID]?.invalidate()
        playerItemObservers.removeValue(forKey: screenID)
        playerItemObserverTokens.removeValue(forKey: screenID)
        fadeInTimeouts[screenID]?.cancel()
        fadeInTimeouts.removeValue(forKey: screenID)
        // 清理播放结束观察者
        if let observer = playbackEndObservers[screenID] {
            NotificationCenter.default.removeObserver(observer)
            playbackEndObservers.removeValue(forKey: screenID)
        }
        onEndModeScreens.remove(screenID)
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
                // 恢复场景下异步设置 poster，不阻塞主线程；视频窗口会覆盖在 poster 上方。
                // 动态锁屏启用时跳过，避免触发 setDesktopImageURL 导致系统重置扩展选择。
                let shouldSkipPosterForRestore = shouldSkipStaticPosterForDynamicLockScreen
                for screen in screensForVideoWallpaperTargets() {
                    if let posterURL = posterURL(for: screen) {
                        if !shouldSkipPosterForRestore {
                            setPosterAsDesktopWallpaper(posterURL, targetScreen: screen)
                            DesktopWallpaperSyncManager.shared.registerWallpaperSet(posterURL, for: screen)
                        } else {
                            print("[VideoWallpaperManager] 🔒 动态锁屏已启用，恢复时跳过静态 poster 写入")
                        }
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
                if #available(macOS 26.0, *) {
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
                let components = makePlayerComponents(
                    for: targetScreen,
                    videoURL: videoURL,
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

                let finalizeReplacement: @MainActor @Sendable () -> Void = { [weak self, weak containerView] in
                    guard let self, let containerView else { return }
                    containerView.playerLayer.player = components.player
                    containerView.playerLayer.videoGravity = .resizeAspectFill
                    self.applyCropToScreen(targetScreen)

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

                    let observer = components.item.observe(\.status, options: [.initial]) { item, _ in
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
            // 桌面壁纸只需要持续顺序播放。较短的本地缓冲能降低大码率 MP4 对内存和磁盘 I/O 的占用，
            // 避免前台 SwiftUI 列表滚动时与视频解码争抢资源。
            let effectiveBufferDuration: TimeInterval = {
                // 对于超大文件（>1GB），进一步缩减缓冲以降低持续性磁盘 I/O 和 page cache 压力
                if let attrs = try? FileManager.default.attributesOfItem(atPath: videoURL.path),
                   let fileSize = attrs[.size] as? UInt64,
                   fileSize > 1_000_000_000 {
                    return 1.0
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
        // 本地文件设为 false：循环切换时不等待缓冲，立即切到下一副本，减少停顿感
        queuePlayer.automaticallyWaitsToMinimizeStalling = !videoURL.isFileURL
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

        // 统一使用 AVPlayerLooper 简单循环播放原视频，不做 crossfade composition。
        // 复杂的首尾帧 crossfade 渲染逻辑已保留在 makeLoopingCompositionItem / exportLoopedVideo 中，
        // 待后续增加用户手动开关后再决定是否恢复调用。
        let hdrMetadataEnabled = UserDefaults.standard.object(forKey: "hdr_enabled") as? Bool ?? true
        let components = makePlayerComponents(
            for: screen,
            videoURL: videoURL,
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
        applyCropToScreen(screen)

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
                self.playerItemObserverTokens.removeValue(forKey: screenID)
                self.fadeInTimeouts[screenID]?.cancel()
                self.fadeInTimeouts.removeValue(forKey: screenID)
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
        ) { _ in
            // 立即将播放器 seek 到第一帧并暂停，作为静态占位帧。
            // 避免异步切换新壁纸期间（triggerNextWallpaper → applyItem）屏幕无内容导致黑屏。
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            player.pause()
            // 发送视频播放完成通知
            DistributedNotificationCenter.default().postNotificationName(
                notificationName,
                object: nil,
                userInfo: ["screenID": screenID],
                deliverImmediately: true
            )
        }
        playbackEndObservers[screenID] = observer
    }

    private func teardownAllWindows() {
        // 0. 取消上一次未执行的延迟释放，避免快速切换时多组 AVPlayer 并发驻留
        pendingPlayerCleanups.forEach { $0.cancel() }
        pendingPlayerCleanups.removeAll()
        pendingWindowCleanups.forEach { $0.cancel() }
        pendingWindowCleanups.removeAll()
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
    private var storedPosterLayer: CALayer?
    private var grainOverlayView: NSView?
    private var transitionPlayerLayer: AVPlayerLayer?

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
    }

    func cancelPlayerTransitionIfNeeded() {
        transitionPlayerLayer?.player = nil
        transitionPlayerLayer?.removeFromSuperlayer()
        transitionPlayerLayer = nil
    }

    func crossfadeToPlayer(_ newPlayer: AVQueuePlayer, duration: TimeInterval, completion: @escaping () -> Void) {
        cancelPlayerTransitionIfNeeded()

        let overlayLayer = AVPlayerLayer()
        overlayLayer.player = newPlayer
        overlayLayer.videoGravity = playerLayer.videoGravity
        overlayLayer.needsDisplayOnBoundsChange = true
        overlayLayer.frame = playerLayer.bounds   // 跟随 playerLayer（含 crop）几何
        overlayLayer.opacity = 0
        playerLayer.addSublayer(overlayLayer)
        transitionPlayerLayer = overlayLayer

        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        CATransaction.setCompletionBlock { [weak self, weak overlayLayer] in
            guard let self else {
                completion()
                return
            }
            // 先让调用方把底层 player 切到新视频，再移除过渡层，避免在完成瞬间闪回旧帧。
            completion()
            overlayLayer?.player = nil
            overlayLayer?.removeFromSuperlayer()
            if self.transitionPlayerLayer === overlayLayer {
                self.transitionPlayerLayer = nil
            }
        }
        overlayLayer.opacity = 1
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
