import Foundation
import AppKit
import Combine
import ImageIO

private let legacyCLIWebCapturePath = "/tmp/wallpaperengine-cli-capture.png"

/// CLI daemon 的 per-screen 截图路径（与 wallpaperengine-cli.swift 中 primaryCapturePath(for:) 保持一致）
private func legacyCLICapturePath(for screen: Int) -> String {
    return "/tmp/wallpaperengine-cli-capture-s\(screen).png"
}

/// Web daemon 写出的全屏媒体内容尺寸。路径与 wallpaperengine-cli.swift 保持一致。
private func legacyCLIWebContentSizePath(for screen: Int) -> String {
    return "/tmp/wallpaperengine-cli-web-content-size-s\(screen).json"
}

/// Web 实时壁纸预热期间采集的海报候选。
///
/// 分数只用于避开全黑、过曝开场和低信息量转场帧；它不影响实时渲染本身。
private struct WebPosterCaptureCandidate: Sendable {
    let url: URL
    let score: Double
    let meanLuma: Double
    let lumaVariance: Double
}

/// 与 wallpaperengine-cli daemon IPC 的音频控制消息
private struct WebDaemonAudioMessage: Codable {
    let command: String
    let muted: Bool?
    let volume: Double?
    let screen: Int?
}

/// 与 wallpaperengine-cli daemon IPC 的音频频谱数据消息。
/// 协议：command="audioData", spectrum=[128 floats]（0..63=L, 64..127=R）；daemon 不回响应。
private struct WebDaemonAudioDataMessage: Codable {
    let command: String
    let spectrum: [Float]
}

/// Web 壁纸裁切参数。crop/viewport 都是原点左上、y 向下的归一化矩形。
private struct WebCropParameters: Codable {
    let crop: [Double]?
    let viewport: [Double]?
    let letterboxColorHex: String?
    /// 每屏单调递增；daemon 用它丢弃乱序的拖拽更新。
    let cropRevision: UInt64
}

private struct WebContentSizePayload: Codable {
    let width: Double
    let height: Double
}

/// Host → daemon：Web 壁纸可视区域。
private struct WebDaemonCropMessage: Codable {
    let command: String
    let crop: [Double]?
    let viewport: [Double]?
    let letterboxColorHex: String?
    let cropRevision: UInt64
    let screen: Int
    let expectsResponse: Bool
}

/// Host → daemon：系统 Now Playing 元数据（低频，fire-and-forget）。
private struct WebDaemonMediaUpdateMessage: Codable {
    let command: String
    let enabled: Bool
    let title: String
    let artist: String
    let albumTitle: String
    let state: Int
    let position: Double
    let duration: Double
    let rate: Double
}

/// Host → daemon：封面 data URL。
private struct WebDaemonMediaThumbnailMessage: Codable {
    let command: String
    let thumbnail: String
}

/// Host → daemon：整首歌词就绪 / 清空（Web 只收 JSON，无 token）。
private struct WebDaemonMediaLyricsMessage: Codable {
    let command: String
    let hasLyrics: Bool
    let title: String
    let artist: String
    let songId: String
    let storefront: String
    let source: String
    let lineCount: Int
    let lines: [WebDaemonLyricLine]
}

private struct WebDaemonLyricLine: Codable {
    let start: Double
    let end: Double?
    let text: String
}

/// Host → daemon：当前歌词行（行变化 / 进度）。
private struct WebDaemonMediaLyricsLineMessage: Codable {
    let command: String
    let index: Int
    let text: String
    let nextText: String
    let previousText: String
    let start: Double
    let end: Double?
    let progress: Double
    let elapsedTime: Double
    let hasLine: Bool
}

/// 进程终止事件（线程安全，通过 os_unfair_lock 传递到 @MainActor）
private struct TerminationEvent: @unchecked Sendable {
    let pid: pid_t
    let generation: UInt64
    let status: Int32
    let reason: Process.TerminationReason
}

// MARK: - CGS 私有 API 桥接（桌面层级/标签设置）
// macOS 26 已移除 CGSWindowByID，且 `--wallpaper`/`--background` 参数已自带后台壁纸渲染能力，
// 因此不再使用 CGS API。窗口标签（Stationary/CanJoinAllSpaces）由二进制处理。

/// 单个屏幕的 wallpaper-wgpu 进程信息
private struct ScreenProcessInfo {
    let pid: pid_t
    let process: Process
    let generation: UInt64
    let screenID: String
    let logFile: FileHandle?
    let audioControlURL: URL?
    /// `--crop-control` JSON 文件路径（wgpu 每 200ms 轮询，热更新 self.crop）。
    /// 拖拽 / 提交时 Bridge 重写此文件，进程无需重启即可应用新裁切。
    let cropControlURL: URL?
    /// `--canvas-size-file` JSON 文件路径（wgpu scene 就绪后写出 ortho 尺寸，App 读取做 crop 计算）。
    let canvasSizeURL: URL?
    /// `--wallpaper-control` JSON 文件路径（wgpu 每 200ms 轮询，热切换壁纸/更新属性）。
    /// 首次启动时传入此参数，后续切换壁纸只写此文件，不杀进程。
    let wallpaperControlURL: URL?
    /// 进程启动时的屏幕尺寸（points）。热切换时与当前 NSScreen.frame 比对，
    /// 若不一致（旋转/分辨率变化）则跳过热切换、走重启路径以更新 --screen 参数。
    let launchedScreenWidth: Int
    let launchedScreenHeight: Int
}

private struct RendererAudioControlState: Codable {
    let muted: Bool
    let paused: Bool
    let volume: Double
}

/// `--crop-control` JSON 体：与 wgpu 端 `CropControlFileState` 对应。
/// crop = nil 等价于全图（移除裁切），viewport = nil/全屏 等价于无 letterbox。
private struct RendererCropControlState: Codable {
    /// 归一化裁切框 [x, y, w, h]，原点左上，y 向下。
    let crop: [Float]?
    /// 屏幕可视框（surface 空间归一化），框外为黑色 letterbox。
    let viewport: [Float]?
}

/// 负责与 wallpaper-wgpu 渲染器通信的桥接层
///
/// **设计变化（相对于旧 wallpaperengine-cli，已废弃）：**
/// - 旧版：通过 Unix Socket IPC 与 daemon 进程通信，支持 set/stop/pause/resume 命令
/// - 新版：直接管理 wallpaper-wgpu 进程，通过 SIGSTOP/SIGCONT 暂停/恢复，terminate() 停止
///
/// **scene** 均由 wallpaper-wgpu 渲染，与本机视频壁纸一样属于「动态壁纸」：
/// `isControllingExternalEngine` 为真时菜单栏应走 pause/resume/stop 走此桥接层，
/// 而非 `VideoWallpaperManager`。
@MainActor
final class WallpaperEngineXBridge: ObservableObject {
    static let shared = WallpaperEngineXBridge()

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

    // MARK: - Published State

    /// 当前是否由 wallpaper-wgpu 接管桌面壁纸
    @Published private(set) var isControllingExternalEngine = false
    @Published private(set) var isExternalPaused = false
    /// 每次每屏渲染状态变化时递增，供依赖具体壁纸路径的 UI 刷新。
    @Published private(set) var renderStateChangeCount: UInt64 = 0

    // MARK: - 进程管理

    /// 每个屏幕的 wallpaper-wgpu 进程信息（key = screenID）
    private var screenProcesses: [String: ScreenProcessInfo] = [:]
    /// 从系统进程表发现的桌面 Scene renderer。它们可能来自上一次崩溃的
    /// WaifuX，已经不在 `screenProcesses` 中，但窗口仍能重新抢占桌面层。
    private struct DiscoveredDesktopRenderer {
        let pid: pid_t
        let parentPID: pid_t
        let command: String
    }
    private enum RenderKind: String, Codable {
        case scene
        case web
    }
    private struct ScreenRenderState: Codable {
        let screenID: String
        let screenFingerprint: String
        let path: String
        let renderKind: RenderKind
        let userProperties: String?
        /// wallpaperengine-cli daemon 使用的屏幕索引；断开后 NSScreen 已消失，
        /// 仍需靠此索引发 `stop-screen` 收掉 orphan web 渲染。
        let cliScreenIndex: Int?

        init(
            screenID: String,
            screenFingerprint: String,
            path: String,
            renderKind: RenderKind,
            userProperties: String?,
            cliScreenIndex: Int? = nil
        ) {
            self.screenID = screenID
            self.screenFingerprint = screenFingerprint
            self.path = path
            self.renderKind = renderKind
            self.userProperties = userProperties
            self.cliScreenIndex = cliScreenIndex
        }

        private enum CodingKeys: String, CodingKey {
            case screenID, screenFingerprint, path, renderKind, userProperties, cliScreenIndex
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            screenID = try container.decode(String.self, forKey: .screenID)
            screenFingerprint = try container.decode(String.self, forKey: .screenFingerprint)
            path = try container.decode(String.self, forKey: .path)
            renderKind = try container.decode(RenderKind.self, forKey: .renderKind)
            userProperties = try container.decodeIfPresent(String.self, forKey: .userProperties)
            cliScreenIndex = try container.decodeIfPresent(Int.self, forKey: .cliScreenIndex)
        }
    }

    /// Keep the current renderer visible while a replacement warms up behind it.
    private struct PreservedRenderer {
        let info: ScreenProcessInfo
        let state: ScreenRenderState?
    }
    private var activeRenderKind: RenderKind?
    private var screenRenderStates: [String: ScreenRenderState] = [:] {
        didSet {
            renderStateChangeCount &+= 1
        }
    }
    /// 每个进程的终止 watchdog（key = pid）
    private var screenWatchdogs: [pid_t: DispatchWorkItem] = [:]
    /// crop 等待 Task（key = screenID），新的 setWallpaper 开始前先 cancel 旧的
    private var cropWaitTasks: [String: Task<Void, Never>] = [:]
    /// Scene 路径 → orthogonalprojection 尺寸；nil 表示读过但没有。
    private var sceneCanvasSizeCache: [String: CGSize?] = [:]
    /// 每屏最近一次读到的 scene canvas 尺寸。热切换会删 canvas-size 文件，新文件没写出前用它重算 crop。
    private var lastCanvasSizeByScreenID: [String: CGSize] = [:]
    /// 非隔离存储所有活跃 PID，供 deinit 中安全清理
    private nonisolated(unsafe) var _deinitPIDs: Set<pid_t> = []
    /// 启动批次号，防止旧进程的 terminationHandler 污染新进程状态
    private var launchGeneration: UInt64 = 0
    /// 烘焙静态资源同步代次：新的 setWallpaper 会递增，旧后台任务自动作废
    private var bakedStaticUpdateGeneration: UInt64 = 0
    /// 交替写烘焙静态图，避免 macOS 因路径不变缓存旧图
    private var bakedStaticDesktopSlot = 0

    // MARK: - 线程安全的进程终止事件管道

    /// terminationHandler 在后台线程执行，不能用任何闭包方式传递到 @MainActor（Swift 6 断言拦截）。
    /// 改用 os_unfair_lock 指针保护的标志位，由 @MainActor 方法择机消费。
    private nonisolated(unsafe) let terminationLockPtr: UnsafeMutablePointer<os_unfair_lock> = {
        let ptr = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        ptr.initialize(to: os_unfair_lock())
        return ptr
    }()
    private nonisolated(unsafe) var pendingTerminations: [pid_t: TerminationEvent] = [:]
    private nonisolated(unsafe) var terminationPendingFlag = false

    // MARK: - 防重复启动锁

    /// 正在设置壁纸中（防止 `restoreIfNeeded` 等场景重复调用 `setWallpaper`）
    private(set) var isSettingWallpaper = false
    /// 跨类型切换代次：新的 apply/static/video 请求会递增，旧 setWallpaper 收尾直接退出。
    private var wallpaperSwitchGeneration: UInt64 = 0
    /// 视频 -> Scene/Web 的准备态。旧视频由 VideoWallpaperManager 保持到这里
    /// 完成；状态按屏幕记录，避免多屏中一块屏超时影响其它屏。
    private struct PendingCrossTypeTransition {
        let generation: UInt64
        let path: String
        let renderKind: RenderKind
        let screenIDs: Set<String>
        let startedAt: Date
    }
    private var pendingCrossTypeTransition: PendingCrossTypeTransition?

    // MARK: - 持久化状态

    private var lastWallpaperPath: String?
    private var targetScreenIDs = Set<String>()
    private var targetScreenFingerprints = Set<String>()
    private var cancellables = Set<AnyCancellable>()
    /// 每个 daemon 屏幕索引的最新 Web crop 版本；用于抵御并发 socket 到达乱序。
    private var webCropRevisionByScreenIndex: [Int: UInt64] = [:]

    /// WE Web 壁纸音频中继当前是否对应于活跃壁纸（基于 project.json audio 标志）
    private var audioRelayActiveForCurrentWallpaper = false
    /// 暂停前的 relay 状态，恢复时还原
    private var wasAudioRelayActiveBeforePause = false
    /// WE Web 壁纸 Media Integration 中继是否活跃（任意 web 壁纸）
    private var mediaRelayActiveForCurrentWallpaper = false
    /// 暂停前 media relay 是否活跃
    private var wasMediaRelayActiveBeforePause = false

    private let lastWallpaperPathKey = "we_last_wallpaper_path_v1"
    private let controllingExternalKey = "we_controlling_external_v1"
    private let targetScreenIDsKey = "we_target_screen_ids_v1"
    private let targetScreenFingerprintsKey = "we_target_screen_fingerprints_v1"
    private let screenRenderStatesKey = "we_screen_render_states_v2"

    // MARK: - 屏幕变化观察

    /// 屏幕参数变化（分辨率、显示器热插拔等）时重启渲染进程
    private var screenChangeRestartWorkItem: DispatchWorkItem?
    private var lastAppliedScreenConfigurations: [ScreenConfigurationSignature] = []
    /// 合盖唤醒后的 renderer 重建任务。scene 的 Metal surface 与 Web 的 WKWebView
    /// 都可能在深度睡眠后保持进程存活却不再出帧，不能只依赖 AutoPause 的 resume。
    private var wakeRecoveryTask: Task<Void, Never>?
    private var wakeRecoveryGeneration: UInt64 = 0

    // MARK: - 初始化

    private init() {
        // 监听 VideoWallpaperManager 恢复自己播放时，清空外部接管标记。
        // 显式 @MainActor 标注闭包，不加 Task { @MainActor } 包装（包装本身也会触发断言）
        VideoWallpaperManager.shared.$currentVideoURL
            .receive(on: DispatchQueue.main)
            .sink { @MainActor [weak self] url in
                guard let self = self else { return }
                if url != nil {
                    self.updateControlStateFromScreenStates()
                }
            }
            .store(in: &cancellables)

        // 监听屏幕参数变化（分辨率变更、显示器连接/断开）
        // 用 Combine publisher 替代 addObserver（后者不接受 @MainActor 闭包）
        NotificationCenter.default.publisher(
            for: NSApplication.didChangeScreenParametersNotification
        )
        .receive(on: DispatchQueue.main)
        .sink { @MainActor [weak self] _ in
            guard let self = self else { return }
            self.handleScreenParametersChanged()
        }
        .store(in: &self.cancellables)

        // 监听可视区域 crop 变更（菜单调节 / overlay 拖拽）→ 重启该屏 wallpaper-wgpu 进程
        NotificationCenter.default.publisher(
            for: DisplayCropSettingsStore.cropDidChangeNotification
        )
        .receive(on: DispatchQueue.main)
        .sink { @MainActor [weak self] note in
            guard let self = self else { return }
            self.handleCropDidChange(note)
        }
        .store(in: &self.cancellables)

        // 合盖后的系统唤醒有时只发 didWake，有时还会补发 screensDidWake。
        // 两者统一防抖到一次 renderer 重建，避免 scene Metal / WebView 保留失效表面而黑屏。
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: DispatchQueue.main)
            .sink { @MainActor [weak self] _ in
                self?.scheduleWakeRecovery(reason: "systemWake")
            }
            .store(in: &self.cancellables)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.screensDidWakeNotification)
            .receive(on: DispatchQueue.main)
            .sink { @MainActor [weak self] _ in
                self?.scheduleWakeRecovery(reason: "screensWake")
            }
            .store(in: &self.cancellables)

        // Web 烘焙完成后，若该工程正作为实时 Web 壁纸运行，立刻将新 MP4 同步给锁屏。
        // 不能等首次静帧兜底的 6 秒定时器，否则会出现已有 MP4 仍短暂走静态帧的竞态。
        NotificationCenter.default.publisher(for: .sceneOfflineBakeDidComplete)
            .compactMap { $0.object as? SceneBakeArtifact }
            .filter { $0.renderer == .wallpaperEngineWeb }
            .receive(on: DispatchQueue.main)
            .sink { @MainActor [weak self] artifact in
                self?.syncCompletedWebBakeIfActive(artifact)
            }
            .store(in: &self.cancellables)
    }

    deinit {
        for pid in _deinitPIDs {
            if kill(pid, 0) == 0 {
                kill(pid, SIGKILL)
            }
        }
    }

    // MARK: - App 可用性

    var isWallpaperEngineXInstalled: Bool {
        WorkshopService.isWallpaperEngineAppInstalled()
    }

    var isWallpaperEngineXRunning: Bool {
        let bundleId = "com.WallpaperEngineX.app"
        return NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleId }
    }

    var currentWallpaperPathForDesign: String? {
        lastWallpaperPath ?? screenRenderStates.values.first?.path
    }

    /// 返回指定屏幕上正在渲染的壁纸文件路径（scene/web）
    func currentWallpaperPath(for screen: NSScreen) -> String? {
        renderState(for: screen)?.path
    }

    func reloadCurrentSceneWallpaperForDesign() {
        guard isCurrentWallpaperScene, let path = currentWallpaperPathForDesign else { return }
        Task { @MainActor in
            try? await setWallpaper(path: path)
        }
    }

    var isCurrentWallpaperWeb: Bool {
        isControllingExternalEngine && activeRenderKind == .web
    }

    var isCurrentWallpaperScene: Bool {
        isControllingExternalEngine && activeRenderKind == .scene
    }

    func prepareForNonExternalWallpaperSwitch(on screens: [NSScreen], reason: String) {
        wallpaperSwitchGeneration &+= 1
        bakedStaticUpdateGeneration &+= 1
        if pendingCrossTypeTransition != nil {
            pendingCrossTypeTransition = nil
            AppLogger.debug(.wallpaper, "作废未完成的跨类型交接", metadata: [
                "reason": reason,
                "generation": wallpaperSwitchGeneration
            ])
        }
        let screenIDs = Set(screens.map(\.wallpaperScreenIdentifier))
        let reaped = terminateUntrackedDesktopRenderers(
            targetScreenIDs: screenIDs,
            reason: reason
        )
        if isSettingWallpaper || !reaped.isEmpty {
            AppLogger.error(.wallpaper, "Non-external wallpaper superseded pending renderer", metadata: [
                "reason": reason,
                "generation": wallpaperSwitchGeneration,
                "isSettingWallpaper": isSettingWallpaper,
                "reapedPIDs": reaped.map(String.init).joined(separator: ","),
                "screens": screens.map(\.wallpaperScreenIdentifier).sorted().joined(separator: ",")
            ])
        }
    }

    // MARK: - 设置壁纸

    /// 使用 wallpaper-wgpu 设置动态壁纸
    /// - Parameters:
    ///   - path: 壁纸目录或 scene.pkg 路径
    ///   - assetsPath: assets-pc 资源目录路径（nil 时从内嵌 assets 解压）
    ///   - targetScreens: 目标屏幕列表（nil 表示所有屏幕）
    ///   - userProperties: 用户属性覆盖 JSON（nil 时不传 --user-properties）
    ///   - forceRestart: 强制重启进程（例如屏幕分辨率变化时），默认 false 走热切换
    ///   - preserveExistingRendererUntilReady: 强制重启时保留旧 renderer 到新 renderer
    ///     完成首帧准备，避免桌面出现黑场或缩放闪动
    ///   - requireAllTargetScreens: 全局同步事务必须在每个目标屏成功完成；任一屏失败时交由调用方回滚。
    func setWallpaper(
        path: String,
        assetsPath: String? = nil,
        targetScreens: [NSScreen]? = nil,
        userProperties: String? = nil,
        forceRestart: Bool = false,
        preserveAutoPauseState: Bool = false,
        preserveExistingRendererUntilReady: Bool = false,
        requireAllTargetScreens: Bool = false
    ) async throws {
        VideoWallpaperManager.shared.cancelPendingExternalVideoTransition(
            reason: "WallpaperEngineXBridge.setWallpaper"
        )
        print("[WallpaperEngineXBridge] >>> setWallpaper START path=\(path)")
        let lockScreenInfo: String
        if #available(macOS 26.0, *) {
            lockScreenInfo = "isLockScreenEnabled=\(VideoWallpaperManager.shared.isLockScreenEnabled) isLockScreenExtensionActive=\(VideoWallpaperManager.shared.isLockScreenExtensionActive)"
        } else {
            lockScreenInfo = "N/A"
        }
        AppLogger.error(.wallpaper, "setWallpaper 开始", metadata: [
            "path": path,
            "targetScreens": targetScreens == nil ? "nil(全部)" : "\(targetScreens!.count)屏",
            "isControllingExternalEngine": isControllingExternalEngine,
            "screenProcesses": screenProcesses.count,
            "screenRenderStates": screenRenderStates.count,
            "isExternalPaused": isExternalPaused,
            "lockScreen": lockScreenInfo
        ])

        // 记录当前焦点应用，渲染器启动后恢复焦点（避免新进程窗口抢焦点）
        let previousApp = NSWorkspace.shared.frontmostApplication

        // 处理之前堆积的进程终止事件
        processPendingTermination()

        // 防重复启动：恢复桌面时可能多次触发，串行化处理
        guard !isSettingWallpaper else {
            AppLogger.error(.wallpaper, "setWallpaper 被防重入拦截: 已有壁纸设置任务进行中", metadata: ["path": path])
            throw WallpaperEngineError.executionFailed("已有壁纸设置任务进行中，请稍后重试")
        }
        isSettingWallpaper = true
        wallpaperSwitchGeneration &+= 1
        let switchGeneration = wallpaperSwitchGeneration
        var ownsSettingFlag = true
        func releaseSettingFlag() {
            guard ownsSettingFlag else { return }
            ownsSettingFlag = false
            isSettingWallpaper = false
        }
        defer {
            releaseSettingFlag()
            print("[WallpaperEngineXBridge] <<< setWallpaper END")
        }

        let effectiveScreens: [NSScreen]
        if let screens = targetScreens, !screens.isEmpty {
            effectiveScreens = Self.uniqueLiveScreens(preferred: screens)
        } else {
            effectiveScreens = Self.uniqueLiveScreens(preferred: NSScreen.screens)
        }
        guard !effectiveScreens.isEmpty else {
            throw WallpaperEngineError.executionFailed("没有可用的壁纸目标显示器")
        }
        var preservedRenderers: [String: PreservedRenderer] = [:]
        WallpaperCrossTypeTransitionCoordinator.shared.invalidatePendingRequests(
            on: effectiveScreens
        )
        terminateUntrackedDesktopRenderers(
            targetScreenIDs: Set(effectiveScreens.map(\.wallpaperScreenIdentifier)),
            reason: "setWallpaper"
        )
        let preservesStaticOverlayUntilReady = StaticImageWallpaperOverlayManager.shared
            .hasActiveWallpaper(on: effectiveScreens)

        // 设场景/web 壁纸时只清理目标屏的静态图 overlay。单屏自动轮换不能
        // 误删其他显示器在“系统壁纸同步关闭”时维护的独立静态图。
        // 有可见 overlay 时延后到新内容 ready 后的黑场内清理。
        if !preservesStaticOverlayUntilReady {
            if let screens = targetScreens, !screens.isEmpty {
                for screen in screens {
                    StaticImageWallpaperOverlayManager.shared.clearState(for: screen)
                }
            } else {
                StaticImageWallpaperOverlayManager.shared.clearState()
            }
        }

	// 壁纸切换时使设计面板的缓存失效
	WebWallpaperDesignService.shared.invalidateAllCaches()

		let resolvedPath = WorkshopService.resolveWallpaperEngineProjectRoot(startingAt: URL(fileURLWithPath: path)).path
		let renderKind: RenderKind = isWebWallpaper(path: resolvedPath) ? .web : .scene

        // 视频 -> Scene/Web 的交接期间，旧视频必须是唯一可见的桌面层。此时写系统
        // poster 会触发 WindowServer 重合成，打断交叉淡入并造成视频层轻微跳动；等交接
        // 完成后由 scheduleBakedCoverSync 统一写入。没有旧视频时仍可提前提交高清 poster。
        let preservesNativeVideoUntilReady = VideoWallpaperManager.shared
            .hasNativeVideoWallpaper(on: effectiveScreens)
        if !preservesNativeVideoUntilReady {
            await commitExistingBakedCoverBeforeRendererStart(
                path: resolvedPath,
                targetScreens: effectiveScreens
            )
        }
        guard wallpaperSwitchGeneration == switchGeneration else { return }
	
        // 跨类型切换不能先拆视频窗。先让 Scene/Web 在旧视频后方完整加载，
        // 最后才在短黑场内提交并释放旧解码器。
        let preservesOldWallpaperUntilReady = preservesNativeVideoUntilReady || preservesStaticOverlayUntilReady
        if preservesNativeVideoUntilReady {
            pendingCrossTypeTransition = PendingCrossTypeTransition(
                generation: switchGeneration,
                path: resolvedPath,
                renderKind: renderKind,
                screenIDs: Set(effectiveScreens.map(\.wallpaperScreenIdentifier)),
                startedAt: Date()
            )
        }
        let oldWallpaperPresentationHold: Task<Void, Never>? = preservesOldWallpaperUntilReady
            ? Task { @MainActor in
                while !Task.isCancelled {
                    VideoWallpaperManager.shared.keepNativeVideoPresentationFront(on: effectiveScreens)
                    StaticImageWallpaperOverlayManager.shared.keepPresentationFront(on: effectiveScreens)
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
            }
            : nil
        defer { oldWallpaperPresentationHold?.cancel() }

        if !preservesNativeVideoUntilReady {
            print("[WallpaperEngineXBridge] step 1: 无旧视频需要保留，清理本机视频层")
            if let screens = targetScreens, !screens.isEmpty {
                for screen in screens {
                    VideoWallpaperManager.shared.stopNativeVideoWallpaperOnly(for: screen)
                }
            } else {
                VideoWallpaperManager.shared.stopNativeVideoWallpaperOnly()
            }
        } else {
            print("[WallpaperEngineXBridge] step 1: 保留旧视频，等待 \(renderKind.rawValue) 首帧就绪")
        }

        // macOS 26+：清空旧的锁屏镜像帧源缓存。
        // wallpaper-wgpu 渲染的壁纸不参与锁屏镜像推帧，但若用户已在设置中启用
        // 动态锁屏，则不应清除其缓存，否则锁屏会退化回静态壁纸。
        // 使用持久化设置 isLockScreenEnabled 而非 isLockScreenMirroringActive。
        if #available(macOS 26.0, *) {
            if !VideoWallpaperManager.shared.isLockScreenEnabled {
                LockScreenWallpaperService.shared.clearMirroringSourceCache()
            }
        }

        // 2. 处理目标屏幕：已有进程 → 控制文件热切换；无进程 → 清理后启动
        if #available(macOS 26.0, *) {
            LockScreenWallpaperService.shared.clearRealtimeSourceIfNeeded(notify: renderKind != .web)
        }
        let effectiveScreenIDs = Set(effectiveScreens.map(\.wallpaperScreenIdentifier))
        // 新壁纸接管目标屏幕后，旧的自动按屏暂停状态不应泄漏到新进程。
        // 仅清 Set 不够：Scene 进程可能仍处于真实的 SIGSTOP(T) 状态，无法读取
        // wallpaper-control 热切换文件，也无法处理稍后的 SIGTERM。切换开始时必须
        // 先 SIGCONT；完成后 AutoPauseManager 会按当前前台状态重新评估。
        for screen in effectiveScreens {
            if let info = screenProcesses[screen.wallpaperScreenIdentifier] {
                kill(info.pid, SIGCONT)
            }
        }
        perScreenPausedScreenIDs.subtract(effectiveScreenIDs)
        // FIX: 壁纸切换时强制恢复全局暂停状态。如果 isExternalPaused 仍为 true，
        // 新启动的 wallpaper-wgpu 进程会收到 --paused 参数，导致启动即暂停。
        isExternalPaused = false
        updateRendererAudioControls(paused: false)

        let targetWebStates = screenRenderStates.values.filter { state in
            state.renderKind == .web && effectiveScreenIDs.contains(state.screenID)
        }
        let shouldStopWebForTargets = !targetWebStates.isEmpty
            || (screenRenderStates.isEmpty && activeRenderKind == .web)

        // 如果目标屏幕原先有 Web 壁纸，通过 daemon IPC 停掉这些屏幕的 web 壁纸（不影响其它屏幕）
        if renderKind != .web && shouldStopWebForTargets {
            print("[WallpaperEngineXBridge] 目标屏幕原有 Web 壁纸，通过 daemon IPC 逐屏停止")
            for state in targetWebStates {
                guard let screen = screenForPersistedState(state),
                      let screenIdx = Self.legacyCLIScreenIndex(for: screen) else {
                    print("[WallpaperEngineXBridge] ⚠️ Web 目标屏已变化，跳过按屏停止: \(state.screenID)")
                    continue
                }
                if let status = try? await Self.runLegacyCLIClientCommand(["stop-screen", String(screenIdx)]),
                   status != 0 {
                    print("[WallpaperEngineXBridge] ⚠️ 按屏停止 Web 壁纸失败 screen=\(screenIdx) exit=\(status)")
                }
                guard wallpaperSwitchGeneration == switchGeneration else { return }
            }
            for state in targetWebStates {
                screenRenderStates.removeValue(forKey: state.screenID)
            }
        }

        // 切到 Web 壁纸前，停掉目标屏幕上正在运行的 scene (wallpaper-wgpu) 进程（不影响其它屏幕）
        if renderKind == .web {
            let targetScreenIDs = Set(effectiveScreens.map(\.wallpaperScreenIdentifier))
            let sceneScreenIDsToStop = screenProcesses.keys.filter { targetScreenIDs.contains($0) }
            if !sceneScreenIDsToStop.isEmpty {
                print("[WallpaperEngineXBridge] 切换到 Web 壁纸，清理目标屏幕 \(sceneScreenIDsToStop.count) 个 scene 渲染进程")
                for screenID in sceneScreenIDsToStop {
                    await stopScreenProcess(screenID)
                    guard wallpaperSwitchGeneration == switchGeneration else { return }
                }
            }
        }

        if renderKind == .web {
            try await setWebWallpaper(path: resolvedPath, targetScreens: effectiveScreens)
            // daemon 已接受 set；属性/海报等收尾不应继续占用全局设置锁，
            // 否则用户快速再切视频/Scene 会被「已有设置任务」挡住。
            guard wallpaperSwitchGeneration == switchGeneration else { return }
            recordRenderState(path: resolvedPath, renderKind: renderKind, screens: effectiveScreens, userProperties: userProperties)
            releaseSettingFlag()
            if preservesOldWallpaperUntilReady {
                do {
                    try await waitForWebPresentationReady(
                        path: resolvedPath,
                        screens: effectiveScreens,
                        generation: switchGeneration
                    )
                } catch {
                    guard wallpaperSwitchGeneration == switchGeneration else {
                        return
                    }
                    await discardPreparedRenderer(on: effectiveScreens)
                    pendingCrossTypeTransition = nil
                    throw error
                }
                guard wallpaperSwitchGeneration == switchGeneration else { return }
                oldWallpaperPresentationHold?.cancel()
                await commitPreparedRendererOverNativeVideo(on: effectiveScreens)
                pendingCrossTypeTransition = nil
            }
            if !preserveAutoPauseState {
                DynamicWallpaperAutoPauseManager.shared.clearForegroundPauseForWallpaperSwitch()
            }
            DynamicWallpaperAutoPauseManager.shared.reevaluateCurrentState()
            ensureAudioRelayMatchesActiveWallpaper(projectRoot: resolvedPath)
            // poster 的桌面写入/菜单栏采样必须晚于旧视频交接结束；否则会在
            // crossfade 中间触发一次 WindowServer 重合成。
            scheduleWebPosterCapture(path: resolvedPath, targetScreens: effectiveScreens)
            return
        }
        // 切到非 web 壁纸：根据其它屏剩余 web 壁纸重新评估是否仍需音频中继
        ensureAudioRelayMatchesActiveWallpaper()

        // 3. 解析 assets 路径（如果内嵌 assets 未解压完成，异步等待后台解压）
        let resolvedAssets: String
        if let ap = assetsPath, !ap.isEmpty {
            resolvedAssets = ap
        } else if let embedded = await WallpaperEngineEmbeddedAssets.awaitAssetsReady() {
            resolvedAssets = embedded
        } else {
            resolvedAssets = ""
            AppLogger.error(.wallpaper, "内嵌 assets 解压失败或超时，wallpaper-wgpu 可能无法正常渲染")
        }

        // 4. 准备 wallpaper-wgpu 二进制路径
        guard let cliURL = Self.resolvedCLIExecutableURL() else {
            print("[WallpaperEngineXBridge] ❌ wallpaper-wgpu 二进制未找到，已搜索所有路径")
            throw WallpaperEngineError.cliNotFound
        }
        print("[WallpaperEngineXBridge] wallpaper-wgpu 路径: \(cliURL.path)")

        // 基础参数（共享给所有屏幕）
        var baseArgs = [resolvedPath]
        if !resolvedAssets.isEmpty {
            baseArgs += ["--assets", resolvedAssets]
            print("[WallpaperEngineXBridge] assets 路径: \(resolvedAssets)")
        } else {
            print("[WallpaperEngineXBridge] ⚠️ assets 为空，未传入 --assets 参数")
        }
        baseArgs += ["--wallpaper", "--background"]

        // 超分辨率模式
        if UserDefaults.standard.bool(forKey: "upscaling_enabled") {
            let percent = UserDefaults.standard.double(forKey: "upscaling_percent")
            let clamped = percent > 0 ? max(30, min(100, Int(percent))) : 70
            baseArgs += ["--upscaling", "\(clamped)"]
            print("[WallpaperEngineXBridge] 超分辨率模式已启用，缩放比例: \(clamped)%")
            if UserDefaults.standard.bool(forKey: "effect_reduction_enabled") {
                baseArgs += ["--effect-reduction"]
                print("[WallpaperEngineXBridge] 性能模式（effect-reduction）已启用")
            }
        }

        // 用户属性覆盖
        let effectiveUserProperties = Self.mergeSceneConfigOverrides(userProperties, wallpaperPath: resolvedPath)
        if let effectiveUserProperties, !effectiveUserProperties.isEmpty {
            print("[WallpaperEngineXBridge] 用户属性已传入")
        }

        // 是否需要启动新进程？（至少有一个屏幕无现有进程才生成新 launchGeneration）
        let needsFreshLaunch = effectiveScreens.contains { screenProcesses[$0.wallpaperScreenIdentifier] == nil }
        let needsPreservedReplacement = preserveExistingRendererUntilReady
            && effectiveScreens.contains { screenProcesses[$0.wallpaperScreenIdentifier] != nil }
        if needsFreshLaunch || needsPreservedReplacement {
            launchGeneration &+= 1
        }

        // 5. 遍历目标屏幕 — 每条路径都先尝试热切换，失败或首次则启动新进程
        var anyLaunchFailed = false
        var failedScreenIDs = Set<String>()
        var lastLaunchError: Error?

        for screen in effectiveScreens {
            guard wallpaperSwitchGeneration == switchGeneration else { return }
            // 全屏覆盖（含菜单栏条带下方）。wgpu 窗口 setOpaque=false +
            // alpha=0.99999 常驻近乎不透明（Rust 侧），壁纸层不被挂起，菜单栏
            // backdrop 懒采样能跟随 poster 更新。
            let f = screen.frame
            let scale = screen.backingScaleFactor
            let screenX = Int(f.origin.x.rounded())
            let screenY = Int(f.origin.y.rounded())
            let screenW = Int(f.width.rounded())
            let screenH = Int(f.height.rounded())
            let screenID = screen.wallpaperScreenIdentifier

            // ── 情况 A：已有活跃进程且非强制重启 → 写控制文件热切换（不杀进程） ──
            // 若屏幕尺寸已变化（旋转/分辨率切换），跳过热切换，走重启路径更新 --screen。
            if !forceRestart, let existingInfo = screenProcesses[screenID],
               let wcURL = existingInfo.wallpaperControlURL,
               existingInfo.process.isRunning,
               kill(existingInfo.pid, 0) == 0,
               screenW == existingInfo.launchedScreenWidth,
               screenH == existingInfo.launchedScreenHeight {
                print("[WallpaperEngineXBridge] 屏幕 \(screenID) 已有活跃进程 (pid=\(existingInfo.pid))，通过控制文件热切换")

                // ── 调试：打印热切换完整参数 ──
                print("[WallpaperEngineXBridge] 📋 HOT-SWITCH PARAMS:")
                print("[WallpaperEngineXBridge] 📋   screenID=\(screenID) pid=\(existingInfo.pid)")
                print("[WallpaperEngineXBridge] 📋   screen=\(screenX),\(screenY),\(screenW),\(screenH),\(Int(scale))")
                print("[WallpaperEngineXBridge] 📋   setWallpaper=\(resolvedPath)")
                print("[WallpaperEngineXBridge] 📋   assets=\(resolvedAssets)")
                print("[WallpaperEngineXBridge] 📋   upscaling=\(UserDefaults.standard.bool(forKey: "upscaling_enabled") ? "enabled" : "disabled")")
                if UserDefaults.standard.bool(forKey: "upscaling_enabled") {
                    let percent = UserDefaults.standard.double(forKey: "upscaling_percent")
                    let clamped = percent > 0 ? max(30, min(100, Int(percent))) : 70
                    print("[WallpaperEngineXBridge] 📋   upscaling_percent=\(clamped)%")
                    print("[WallpaperEngineXBridge] 📋   effect_reduction=\(UserDefaults.standard.bool(forKey: "effect_reduction_enabled"))")
                }
                print("[WallpaperEngineXBridge] 📋   userProperties=\(effectiveUserProperties ?? "nil")")
                // crop/audio 控制文件路径
                print("[WallpaperEngineXBridge] 📋   cropControlURL=\(existingInfo.cropControlURL?.path ?? "nil")")
                print("[WallpaperEngineXBridge] 📋   audioControlURL=\(existingInfo.audioControlURL?.path ?? "nil")")
                print("[WallpaperEngineXBridge] 📋   canvasSizeURL=\(existingInfo.canvasSizeURL?.path ?? "nil")")
                print("[WallpaperEngineXBridge] 📋   wallpaperControlURL=\(wcURL.path)")

                // 准备热切换控制参数（包含超分辨率/性能模式参数）
                let upscalingEnabled = UserDefaults.standard.bool(forKey: "upscaling_enabled")
                let upscalingPercentValue: Int? = upscalingEnabled ? {
                    let percent = UserDefaults.standard.double(forKey: "upscaling_percent")
                    return percent > 0 ? max(30, min(100, Int(percent))) : 70
                }() : nil
                let effectReductionEnabled = upscalingEnabled ? UserDefaults.standard.bool(forKey: "effect_reduction_enabled") : false

                // 热切换必须先清除旧裁切和旧 canvas-size，再通知 renderer 加载新壁纸。
                // 否则等待新画布尺寸的任务会把仍可读取的旧文件误判为新场景尺寸，
                // 在固定比例（如 16:9）下写入错误的 crop。
                let cropSettings = DisplayCropSettingsStore.shared.settings(for: screen)
                if let csURL = existingInfo.canvasSizeURL,
                   let known = readCanvasSize(url: csURL) {
                    lastCanvasSizeByScreenID[screenID] = known
                }
                if let ccURL = existingInfo.cropControlURL {
                    writeCropControl(url: ccURL, crop: nil, viewport: nil)
                }
                if let csURL = existingInfo.canvasSizeURL {
                    invalidateCanvasSizeFile(at: csURL)
                }

                guard writeWallpaperControl(
                    url: wcURL,
                    setWallpaper: resolvedPath,
                    assets: resolvedAssets.isEmpty ? nil : resolvedAssets,
                    setProperties: effectiveUserProperties,
                    upscaling: upscalingEnabled,
                    upscalingPercent: upscalingPercentValue,
                    effectReduction: effectReductionEnabled
                ) else {
                    let error = WallpaperEngineError.executionFailed(
                        "无法写入 Scene 壁纸控制文件"
                    )
                    print("[WallpaperEngineXBridge] ❌ 屏幕 \(screenID) 热切换失败: \(error.localizedDescription)")
                    anyLaunchFailed = true
                    failedScreenIDs.insert(screenID)
                    lastLaunchError = error
                    continue
                }

                // 只有控制文件写入成功后才能标记该屏已切到新壁纸。
                screenRenderStates[screenID] = ScreenRenderState(
                    screenID: screenID,
                    screenFingerprint: screen.wallpaperScreenFingerprint,
                    path: resolvedPath,
                    renderKind: renderKind,
                    userProperties: userProperties,
                    cliScreenIndex: renderKind == .web ? Self.legacyCLIScreenIndex(for: screen) : nil
                )
                if let acURL = existingInfo.audioControlURL {
                    writeAudioControl(
                        url: acURL,
                        muted: VideoWallpaperManager.shared.isMuted,
                        paused: isExternalPaused,
                        volume: VideoWallpaperManager.shared.volume(for: screen)
                    )
                }

                // 新壁纸 canvas 尺寸可能不同，等真实尺寸写出后更新 crop。
                if cropSettings.shouldApplyCrop,
                   existingInfo.cropControlURL != nil,
                   let csURL = existingInfo.canvasSizeURL {
                    let canvasSizeURLCopy = csURL
                    let screenIDCopy = screenID
                    cropWaitTasks[screenIDCopy]?.cancel()
                    cropWaitTasks[screenIDCopy] = Task { @MainActor [weak self] in
                        defer { self?.cropWaitTasks.removeValue(forKey: screenIDCopy) }
                        let deadline = Date().addingTimeInterval(5.0)
                        while Date() < deadline {
                            try? await Task.sleep(nanoseconds: 100_000_000)
                            if Task.isCancelled { return }
                            guard let self else { return }
                            guard self.screenProcesses[screenIDCopy]?.pid == existingInfo.pid else { return }
                            if let realSize = self.readCanvasSize(url: canvasSizeURLCopy) {
                                self.lastCanvasSizeByScreenID[screenIDCopy] = realSize
                                if let screen = NSScreen.screens.first(where: {
                                    $0.wallpaperScreenIdentifier == screenIDCopy
                                }) {
                                    self.applyPersistedCrop(for: screen)
                                }
                                print("[WallpaperEngineXBridge] 屏幕 \(screenIDCopy) 热切换后 canvas_size 就绪，crop 已重算")
                                return
                            }
                        }
                        print("[WallpaperEngineXBridge] ⚠️ 屏幕 \(screenIDCopy) 热切换等待 canvas_size 超时，用缓存尺寸恢复 crop")
                        if let screen = NSScreen.screens.first(where: {
                            $0.wallpaperScreenIdentifier == screenIDCopy
                        }) {
                            self.applyPersistedCrop(for: screen)
                        }
                    }
                }

                print("[WallpaperEngineXBridge] ✅ 屏幕 \(screenID) 热切换完成 (pid=\(existingInfo.pid))")
                continue
            }

            // ── 情况 B：首次启动该屏幕 → 清理旧状态后启动新进程 ──
            if let existingInfo = screenProcesses[screenID],
               (screenW != existingInfo.launchedScreenWidth || screenH != existingInfo.launchedScreenHeight) {
                print("[WallpaperEngineXBridge] 屏幕 \(screenID) 尺寸已变化 (\(existingInfo.launchedScreenWidth)x\(existingInfo.launchedScreenHeight) → \(screenW)x\(screenH))，跳过热切换，重启进程")
            }
            print("[WallpaperEngineXBridge] 屏幕 \(screenID) 无活跃进程，准备首次启动")

            // ── 调试：打印首次启动完整参数 ──
            print("[WallpaperEngineXBridge] 📋 FRESH-LAUNCH PARAMS:")
            print("[WallpaperEngineXBridge] 📋   screenID=\(screenID)")
            print("[WallpaperEngineXBridge] 📋   screen=\(screenX),\(screenY),\(screenW),\(screenH),\(Int(scale))")
            print("[WallpaperEngineXBridge] 📋   path=\(resolvedPath)")
            print("[WallpaperEngineXBridge] 📋   assets=\(resolvedAssets)")
            print("[WallpaperEngineXBridge] 📋   upscaling=\(UserDefaults.standard.bool(forKey: "upscaling_enabled") ? "enabled" : "disabled")")
            if UserDefaults.standard.bool(forKey: "upscaling_enabled") {
                let up = UserDefaults.standard.double(forKey: "upscaling_percent")
                let cl = up > 0 ? max(30, min(100, Int(up))) : 70
                print("[WallpaperEngineXBridge] 📋   upscaling_percent=\(cl)%")
                print("[WallpaperEngineXBridge] 📋   effect_reduction=\(UserDefaults.standard.bool(forKey: "effect_reduction_enabled"))")
            }
            print("[WallpaperEngineXBridge] 📋   userProperties=\(effectiveUserProperties ?? "nil")")

            if let existingInfo = screenProcesses[screenID] {
                let canPreserve = preserveExistingRendererUntilReady
                    && existingInfo.process.isRunning
                    && kill(existingInfo.pid, 0) == 0
                if canPreserve {
                    preservedRenderers[screenID] = PreservedRenderer(
                        info: existingInfo,
                        state: screenRenderStates[screenID]
                    )
                    if let audioControlURL = existingInfo.audioControlURL {
                        writeAudioControl(
                            url: audioControlURL,
                            muted: true,
                            paused: true,
                            volume: 0
                        )
                    }
                    print("[WallpaperEngineXBridge] 屏幕 \(screenID) 保留旧 renderer (pid=\(existingInfo.pid))，等待新 renderer 就绪后切换")
                } else {
                    await stopScreenProcess(screenID)
                    guard wallpaperSwitchGeneration == switchGeneration else { return }
                }
            }

            var perScreenArgs = baseArgs
            perScreenArgs += ["--screen", "\(screenX),\(screenY),\(screenW),\(screenH),\(scale)"]

            // 渲染帧率
            let userFPS = UserDefaults.standard.double(forKey: "wallpaper_engine_fps")
            let userFPSClamped = max(30, min(240, userFPS))
            let screenMaxFPS = screen.maxRefreshRate
            let effectiveFPS = min(Int(userFPSClamped), screenMaxFPS)
            perScreenArgs += ["--fps", String(effectiveFPS)]

            // 控制文件路径（首次启动就创建，后续热切换复用）
            let cropControlURL = createCropControlURL(screenID: screenID)
            let canvasSizeURL = createCanvasSizeURL(screenID: screenID)
            let audioControlURL = createAudioControlURL(screenID: screenID)
            let wallpaperControlURL = createWallpaperControlURL(screenID: screenID)

            // 初始裁切。优先用画布/视频真实尺寸算居中 cover，避免渲染器默认 Cover 偏一侧。
            let cropSettings = DisplayCropSettingsStore.shared.settings(for: screen)
            let initialLayout: (crop: UnitRect, viewport: UnitRect)? = {
                guard cropSettings.shouldApplyCrop else { return nil }
                let wallpaperSize = cropWallpaperSize(
                    screen: screen,
                    path: resolvedPath,
                    canvasSizeURL: canvasSizeURL,
                    allowCachedCanvas: false
                )
                if wallpaperSize == nil,
                   cropSettings.aspectPreset == .autoFill
                    || (cropSettings.aspectPreset == .custom && cropSettings.customAspect == nil) {
                    return nil
                }
                let layout = CropLayoutEngine.compute(
                    wallpaperSize: wallpaperSize ?? CGSize(width: screenW, height: screenH),
                    screenSize: CGSize(width: screenW, height: screenH),
                    settings: cropSettings)
                return (crop: layout.wallpaperCropRect, viewport: layout.viewportRect)
            }()
            if let l = initialLayout {
                let cr = l.crop
                perScreenArgs += ["--crop", "\(cr.x),\(cr.y),\(cr.w),\(cr.h)"]
                let vp = l.viewport
                let isFullVp = abs(vp.x) < 1e-4 && abs(vp.y) < 1e-4 && abs(vp.w - 1) < 1e-4 && abs(vp.h - 1) < 1e-4
                if !isFullVp {
                    perScreenArgs += ["--crop-viewport", "\(vp.x),\(vp.y),\(vp.w),\(vp.h)"]
                }
                print("[WallpaperEngineXBridge] 初始 crop=\(cr.x),\(cr.y),\(cr.w),\(cr.h) viewport=\(vp.x),\(vp.y),\(vp.w),\(vp.h)")
            }
            writeCropControl(url: cropControlURL, crop: initialLayout?.crop, viewport: initialLayout?.viewport)
            perScreenArgs += ["--crop-control", cropControlURL.path]
            perScreenArgs += ["--canvas-size-file", canvasSizeURL.path]

            // 音频控制
            let audioVolume = VideoWallpaperManager.shared.volume(for: screen)
            writeAudioControl(url: audioControlURL, muted: VideoWallpaperManager.shared.isMuted, paused: isExternalPaused, volume: audioVolume)
            perScreenArgs += ["--audio-control", audioControlURL.path, "--volume", String(format: "%.4f", audioVolume)]
            if VideoWallpaperManager.shared.isMuted { perScreenArgs += ["--muted"] }
            if isExternalPaused { perScreenArgs += ["--paused"] }

            // ⭐ 壁纸控制文件（热切换入口，必传）
            perScreenArgs += ["--wallpaper-control", wallpaperControlURL.path]
            if preservedRenderers[screenID] != nil {
                perScreenArgs += ["--startup-fade"]
            }

            if let effectiveUserProperties, !effectiveUserProperties.isEmpty {
                perScreenArgs += ["--user-properties", effectiveUserProperties]
            }

            print("[WallpaperEngineXBridge] 启动屏幕 \(screenID) 进程: \(cliURL.lastPathComponent) \(perScreenArgs.joined(separator: " "))")

            do {
                let process = try launchRendererProcess(
                    executableURL: cliURL,
                    arguments: perScreenArgs,
                    generation: launchGeneration,
                    screenID: screenID
                )
                let launchedPID = process.process.processIdentifier
                screenProcesses[screenID] = ScreenProcessInfo(
                    pid: launchedPID,
                    process: process.process,
                    generation: launchGeneration,
                    screenID: screenID,
                    logFile: process.logFile,
                    audioControlURL: audioControlURL,
                    cropControlURL: cropControlURL,
                    canvasSizeURL: canvasSizeURL,
                    wallpaperControlURL: wallpaperControlURL,
                    launchedScreenWidth: screenW,
                    launchedScreenHeight: screenH
                )
                screenRenderStates[screenID] = ScreenRenderState(
                    screenID: screenID,
                    screenFingerprint: screen.wallpaperScreenFingerprint,
                    path: resolvedPath,
                    renderKind: renderKind,
                    userProperties: userProperties,
                    cliScreenIndex: renderKind == .web ? Self.legacyCLIScreenIndex(for: screen) : nil
                )
                _deinitPIDs.insert(launchedPID)
                print("[WallpaperEngineXBridge] ✅ 屏幕 \(screenID) wallpaper-wgpu 已启动 (pid=\(launchedPID))")
                AppLogger.error(.wallpaper, "wallpaper-wgpu 进程已启动", metadata: ["screenID": screenID, "pid": launchedPID, "renderKind": renderKind.rawValue, "screenProcesses": screenProcesses.count])

                // 异步等待 canvas_size 就绪后重算 crop
                if cropSettings.shouldApplyCrop {
                    let canvasSizeURLCopy = canvasSizeURL
                    let genCopy = self.launchGeneration
                    let screenIDCopy = screenID
                    cropWaitTasks[screenIDCopy]?.cancel()
                    cropWaitTasks[screenIDCopy] = Task { @MainActor [weak self] in
                        defer { self?.cropWaitTasks.removeValue(forKey: screenIDCopy) }
                        let deadline = Date().addingTimeInterval(5.0)
                        while Date() < deadline {
                            try? await Task.sleep(nanoseconds: 100_000_000)
                            if Task.isCancelled { return }
                            guard let self else { return }
                            guard self.launchGeneration == genCopy,
                                  self.screenProcesses[screenIDCopy]?.generation == genCopy else { return }
                            if let realSize = self.readCanvasSize(url: canvasSizeURLCopy) {
                                self.lastCanvasSizeByScreenID[screenIDCopy] = realSize
                                if let screen = NSScreen.screens.first(where: {
                                    $0.wallpaperScreenIdentifier == screenIDCopy
                                }) {
                                    self.applyPersistedCrop(for: screen)
                                }
                                print("[WallpaperEngineXBridge] 屏幕 \(screenIDCopy) canvas_size 就绪 (\(Int(realSize.width))×\(Int(realSize.height)))，crop 已按真实尺寸重算并热更新")
                                return
                            }
                        }
                        print("[WallpaperEngineXBridge] ⚠️ 屏幕 \(screenIDCopy) 等待 canvas_size 超时，用缓存尺寸恢复 crop")
                        if let self,
                           let screen = NSScreen.screens.first(where: {
                               $0.wallpaperScreenIdentifier == screenIDCopy
                           }) {
                            self.applyPersistedCrop(for: screen)
                        }
                    }
                }
            } catch {
                print("[WallpaperEngineXBridge] ❌ 屏幕 \(screenID) 启动失败: \(error.localizedDescription)")
                // 过渡模式下旧 renderer 仍然是当前可见内容，不能因为新进程
                // 启动失败而把它的管理记录和控制文件一起删掉。
                if preservedRenderers[screenID] == nil {
                    removeScreenProcess(screenID)
                    screenRenderStates.removeValue(forKey: screenID)
                }
                anyLaunchFailed = true
                failedScreenIDs.insert(screenID)
                lastLaunchError = error
            }
        }

        if anyLaunchFailed && !preservedRenderers.isEmpty {
            await discardPreparedRenderersPreservingOld(preservedRenderers)
            releaseSettingFlag()
            throw lastLaunchError
                ?? WallpaperEngineError.executionFailed("唤醒后 renderer 启动失败")
        }
        // 全局同步不能把“一块屏成功”当成成功：必须让全局协调器回滚到上一张，
        // 否则会留下部分屏新 Scene、部分屏旧 Scene 的分裂状态。
        if anyLaunchFailed && requireAllTargetScreens {
            updateControlStateFromScreenStates()
            persistState()
            throw WallpaperEngineError.executionFailed(
                "Scene 壁纸未能同步到所有显示器: \(failedScreenIDs.sorted().joined(separator: ","))"
            )
        }

        // 独立屏模式保留部分成功，避免单屏失败影响其它独立显示器。
        if anyLaunchFailed && screenProcesses.isEmpty {
            updateControlStateFromScreenStates()
            persistState()
            throw WallpaperEngineError.executionFailed("所有屏幕 wallpaper-wgpu 启动均失败: \(lastLaunchError!.localizedDescription)")
        } else if anyLaunchFailed {
            print("[WallpaperEngineXBridge] ⚠️ 部分屏幕启动失败，但至少有一个屏幕成功")
        }

        if effectiveScreens.count > 1 {
            print("[WallpaperEngineXBridge] 多显示器模式: \(effectiveScreens.count) 个屏幕")
        }

        // wallpaper-wgpu 的热切换是异步读取控制文件。全局同步必须等待每块屏
        // 写出新 canvas_size，才能确认 Scene 已真正完成加载而不是仅写入了意图。
        let verifiedSceneReadiness = requireAllTargetScreens && renderKind == .scene
        if verifiedSceneReadiness {
            try await waitForScenePresentationReady(
                path: resolvedPath,
                screens: effectiveScreens,
                generation: switchGeneration
            )
        }

        let preservesExistingRendererUntilReady = !preservedRenderers.isEmpty
        // renderer 已完成热切换或进程启动。保留旧 renderer 的唤醒恢复还要
        // 完成一次无黑场交接，因此先保持设置锁，避免新的设置请求抢走进程所有权。
        if !preservesExistingRendererUntilReady {
            releaseSettingFlag()
        }
        guard wallpaperSwitchGeneration == switchGeneration else {
            if preservesExistingRendererUntilReady {
                await discardPreparedRenderersPreservingOld(preservedRenderers)
                releaseSettingFlag()
            }
            return
        }

        if preservesOldWallpaperUntilReady {
            do {
                if !verifiedSceneReadiness {
                    try await waitForScenePresentationReady(
                        path: resolvedPath,
                        screens: effectiveScreens,
                        generation: switchGeneration
                    )
                }
            } catch {
                guard wallpaperSwitchGeneration == switchGeneration else { return }
                // 新 Scene 没有形成稳定首帧时继续保留旧视频，并清掉藏在后方的
                // 半初始化 renderer，避免下一次设置误把它当作可热切换的活跃场景。
                for screen in effectiveScreens {
                    await stopScreenProcess(screen.wallpaperScreenIdentifier)
                }
                pendingCrossTypeTransition = nil
                throw error
            }
            guard wallpaperSwitchGeneration == switchGeneration else { return }
            oldWallpaperPresentationHold?.cancel()
            await commitPreparedRendererOverNativeVideo(on: effectiveScreens)
            pendingCrossTypeTransition = nil
        }

        if preservesExistingRendererUntilReady {
            do {
                if !verifiedSceneReadiness {
                    try await waitForScenePresentationReady(
                        path: resolvedPath,
                        screens: effectiveScreens,
                        generation: switchGeneration
                    )
                }
            } catch {
                await discardPreparedRenderersPreservingOld(preservedRenderers)
                releaseSettingFlag()
                throw error
            }
            guard wallpaperSwitchGeneration == switchGeneration else {
                await discardPreparedRenderersPreservingOld(preservedRenderers)
                releaseSettingFlag()
                return
            }
            await commitPreparedRenderersReplacingOld(preservedRenderers)
            releaseSettingFlag()
        }

        guard wallpaperSwitchGeneration == switchGeneration else { return }

        updateControlStateFromScreenStates(preferredPath: resolvedPath, preferredKind: renderKind)
        persistState()
        AppLogger.error(.wallpaper, "setWallpaper 完成", metadata: [
            "isControllingExternalEngine": isControllingExternalEngine,
            "activeRenderKind": activeRenderKind?.rawValue ?? "nil",
            "screenProcesses": screenProcesses.count,
            "screenRenderStates": screenRenderStates.keys.sorted().joined(separator: ",")
        ])
        for screen in effectiveScreens {
            applyPersistedCrop(for: screen)
        }
        // 清除旧的前台暂停状态，避免 reevaluateCurrentState() 对新启动的渲染器误发 SIGSTOP。
        // 用户之后切走应用时，NSWorkspace app activation 通知会重新施加前台暂停。
        if !preserveAutoPauseState {
            DynamicWallpaperAutoPauseManager.shared.clearForegroundPauseForWallpaperSwitch()
        }
        DynamicWallpaperAutoPauseManager.shared.reevaluateCurrentState()

        // 真实渲染已经启动，UI 可立即结束“设置中”状态。
        // 只允许已有烘焙资源更新静态桌面/锁屏；没有烘焙资源时不生成任何替代截图。
        let bakedStaticScreens = effectiveScreens.filter { screen in
            screenRenderStates[screen.wallpaperScreenIdentifier]?.path == resolvedPath
        }
        scheduleBakedCoverSync(
            path: resolvedPath,
            targetScreens: bakedStaticScreens
        )

        // 强制恢复之前的焦点应用（wallpaper-wgpu 启动会抢占焦点）
        // 多次延迟尝试确保焦点恢复
        func restoreFocus() {
            if let app = previousApp, !app.isTerminated {
                app.activate(options: [.activateIgnoringOtherApps])
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            restoreFocus()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                restoreFocus()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    restoreFocus()
                }
            }
        }
    }

    /// 刷新当前壁纸的用户属性（通过重启 wallpaper-wgpu 进程）
    /// - Parameter userProperties: 用户属性覆盖 JSON
    func refreshWallpaperProperties(userProperties: String?) async throws {
        guard let path = lastWallpaperPath else {
            print("[WallpaperEngineXBridge] ❌ refreshWallpaperProperties: lastWallpaperPath 为空，没有正在运行的壁纸")
            throw WallpaperEngineError.executionFailed("没有正在运行的壁纸")
        }
        guard isControllingExternalEngine, activeRenderKind == .scene else {
            print("[WallpaperEngineXBridge] ❌ refreshWallpaperProperties: 当前壁纸不是场景类型 (isControllingExternalEngine=\(isControllingExternalEngine), activeRenderKind=\(String(describing: activeRenderKind)))")
            throw WallpaperEngineError.executionFailed("当前壁纸不是场景类型")
        }
        print("[WallpaperEngineXBridge] refreshWallpaperProperties: 刷新壁纸属性 path=\(path)")
        // 改为写壁纸控制文件热更新属性，不再重启进程
        let screens = activeTargetScreens().filter { screen in
            let screenID = screen.wallpaperScreenIdentifier
            let fingerprint = screen.wallpaperScreenFingerprint
            let state = screenRenderStates[screenID] ?? screenRenderStates.values.first { $0.screenFingerprint == fingerprint }
            return state?.path == path || screenRenderStates.isEmpty
        }
        var anyWritten = false
        for screen in screens {
            let screenID = screen.wallpaperScreenIdentifier
            guard let info = screenProcesses[screenID], let wcURL = info.wallpaperControlURL else {
                print("[WallpaperEngineXBridge] ⚠️ 屏幕 \(screenID) 无 wallpaperControlURL，无法热更新属性")
                continue
            }
            // 合并用户属性（含场景配置覆盖 __-prefixed）
            let effectiveProperties = Self.mergeSceneConfigOverrides(userProperties, wallpaperPath: path)
            writeWallpaperControl(url: wcURL, setWallpaper: nil, assets: nil, setProperties: effectiveProperties)
            print("[WallpaperEngineXBridge] ✅ 屏幕 \(screenID) 属性已通过控制文件热更新")
            anyWritten = true
        }
        if !anyWritten {
            print("[WallpaperEngineXBridge] ⚠️ refreshWallpaperProperties: 无活跃进程可更新，回退到重启方式")
            try await setWallpaper(
                path: path,
                targetScreens: screens.isEmpty ? nil : screens,
                userProperties: userProperties
            )
        }
    }

    // MARK: - 暂停 / 恢复 / 停止

    /// 暂停渲染（发送 SIGSTOP）
    func pauseWallpaper() {
        if screenRenderStates.values.contains(where: { $0.renderKind == .web }) || activeRenderKind == .web {
            // web 渲染由旧 CLI 的 daemon 持有，必须通过其 IPC 暂停
            sendLegacyWebPlaybackCommand("pause", to: webRenderScreenIDs)
        }
        guard isControllingExternalEngine else { return }
        isExternalPaused = true
        perScreenPausedScreenIDs.formUnion(managedRenderScreenIDs)
        updateRendererAudioControls(paused: true)
        // 暂停时释放 SCK / MediaRemote；恢复时由 resumeWallpaper 根据当前壁纸重启
        if audioRelayActiveForCurrentWallpaper {
            wasAudioRelayActiveBeforePause = true
            stopAudioRelayIfActive()
        }
        if mediaRelayActiveForCurrentWallpaper {
            wasMediaRelayActiveBeforePause = true
            stopMediaRelayIfActive()
        }
        // FIX: 使用 PID 快照立即发送 SIGSTOP，避免与 setWallpaper 竞争导致新进程被误暂停。
        // 原代码使用 asyncAfter(delay: 0.15) 延迟发送 SIGSTOP，如果在此期间 setWallpaper
        // 启动了新进程，延迟闭包中的 self.screenProcesses 可能包含新进程，导致新进程被错误暂停。
        let currentPIDs = screenProcesses.mapValues { $0.pid }
        for (screenID, pid) in currentPIDs {
            kill(pid, SIGSTOP)
            print("[WallpaperEngineXBridge] 暂停渲染 屏幕 \(screenID) (pid=\(pid))")
        }
    }

    /// 恢复渲染（发送 SIGCONT）
    func resumeWallpaper() {
        if screenRenderStates.values.contains(where: { $0.renderKind == .web }) || activeRenderKind == .web {
            sendLegacyWebPlaybackCommand("resume", to: webRenderScreenIDs)
        }
        guard isControllingExternalEngine else { return }
        for (screenID, info) in screenProcesses {
            kill(info.pid, SIGCONT)
            print("[WallpaperEngineXBridge] 恢复渲染 屏幕 \(screenID) (pid=\(info.pid))")
        }
        perScreenPausedScreenIDs.removeAll()
        isExternalPaused = false
        updateRendererAudioControls(paused: false)
        // 恢复前是否启用过 relay → 根据当前壁纸的 project.json 重新检测启动
        if wasAudioRelayActiveBeforePause || wasMediaRelayActiveBeforePause, let path = lastWallpaperPath {
            ensureAudioRelayMatchesActiveWallpaper(projectRoot: path)
        } else if wasAudioRelayActiveBeforePause || wasMediaRelayActiveBeforePause {
            ensureAudioRelayMatchesActiveWallpaper()
        }
        wasAudioRelayActiveBeforePause = false
        wasMediaRelayActiveBeforePause = false
    }

    /// 按屏幕暂停追踪：通过 per-screen API 暂停的屏幕 ID
    /// 与全局 `isExternalPaused` 独立，用于支持 AutoPauseManager 按屏幕暂停/恢复外部引擎
    private var perScreenPausedScreenIDs: Set<String> = []

    private var managedRenderScreenIDs: Set<String> {
        let onlineIDs = Set(NSScreen.screens.map(\.wallpaperScreenIdentifier))
        let onlineFingerprints = Set(NSScreen.screens.map(\.wallpaperScreenFingerprint))
        let fromStates = Set(screenRenderStates.compactMap { screenID, state -> String? in
            if onlineIDs.contains(screenID) { return screenID }
            if onlineFingerprints.contains(state.screenFingerprint) {
                return NSScreen.screens.first {
                    $0.wallpaperScreenFingerprint == state.screenFingerprint
                }?.wallpaperScreenIdentifier
            }
            return nil
        })
        let screenIDs = Set(screenProcesses.keys).union(fromStates).intersection(onlineIDs)
        if !screenIDs.isEmpty { return screenIDs }
        return targetScreenIDs.intersection(onlineIDs)
    }

    private var webRenderScreenIDs: Set<String> {
        let onlineIDs = Set(NSScreen.screens.map(\.wallpaperScreenIdentifier))
        let onlineFingerprints = Set(NSScreen.screens.map(\.wallpaperScreenFingerprint))
        let screenIDs = Set(screenRenderStates.compactMap { screenID, state -> String? in
            guard state.renderKind == .web else { return nil }
            if onlineIDs.contains(screenID) { return screenID }
            if onlineFingerprints.contains(state.screenFingerprint),
               let liveID = NSScreen.screens.first(where: {
                   $0.wallpaperScreenFingerprint == state.screenFingerprint
               })?.wallpaperScreenIdentifier {
                return liveID
            }
            return nil
        })
        if !screenIDs.isEmpty {
            return screenIDs
        }
        return activeRenderKind == .web ? targetScreenIDs.intersection(onlineIDs) : []
    }

    private func sendLegacyWebPlaybackCommand(_ command: String, to screenIDs: Set<String>) {
        for screenID in screenIDs {
            guard let screen = NSScreen.screens.first(where: { $0.wallpaperScreenIdentifier == screenID }),
                  let screenIndex = Self.legacyCLIScreenIndex(for: screen) else {
                continue
            }
            Task {
                try? await Self.runLegacyCLIClientCommand([command, String(screenIndex)])
            }
        }
    }

    private func updateExternalPausedStateFromPerScreenPauses() {
        let managedScreenIDs = managedRenderScreenIDs
        guard !managedScreenIDs.isEmpty else { return }

        let allManagedScreensPaused = managedScreenIDs.isSubset(of: perScreenPausedScreenIDs)
        guard isExternalPaused != allManagedScreensPaused else { return }

        isExternalPaused = allManagedScreensPaused
        updateRendererAudioControls(paused: allManagedScreensPaused)

        if allManagedScreensPaused {
            if audioRelayActiveForCurrentWallpaper {
                wasAudioRelayActiveBeforePause = true
                stopAudioRelayIfActive()
            }
            if mediaRelayActiveForCurrentWallpaper {
                wasMediaRelayActiveBeforePause = true
                stopMediaRelayIfActive()
            }
        } else if wasAudioRelayActiveBeforePause || wasMediaRelayActiveBeforePause, let path = lastWallpaperPath {
            ensureAudioRelayMatchesActiveWallpaper(projectRoot: path)
            wasAudioRelayActiveBeforePause = false
            wasMediaRelayActiveBeforePause = false
        }
    }

    /// 暂停指定屏幕的渲染（scene：SIGSTOP；web：按屏 IPC）
    func pauseWallpaper(for screenID: String) {
        guard isControllingExternalEngine else { return }

        // scene：有独立 wallpaper-wgpu 进程，按屏 SIGSTOP
        if let info = screenProcesses[screenID] {
            kill(info.pid, SIGSTOP)
            perScreenPausedScreenIDs.insert(screenID)
            print("[WallpaperEngineXBridge] 暂停渲染 屏幕 \(screenID) (pid=\(info.pid))")
            updateExternalPausedStateFromPerScreenPauses()
            return
        }

        // web：无独立 scene 进程，但 targetScreenIDs / screenRenderStates 标记该屏有 web 壁纸
        guard isManaging(screenID: screenID) else { return }
        let isWebOnScreen = screenRenderStates[screenID]?.renderKind == .web
            || (activeRenderKind == .web && targetScreenIDs.contains(screenID))
        guard isWebOnScreen else { return }

        perScreenPausedScreenIDs.insert(screenID)
        print("[WallpaperEngineXBridge] 暂停 web 渲染 屏幕 \(screenID)")
        if let screen = NSScreen.screens.first(where: { $0.wallpaperScreenIdentifier == screenID }),
           let screenIndex = Self.legacyCLIScreenIndex(for: screen) {
            Task {
                try? await Self.runLegacyCLIClientCommand(["pause", String(screenIndex)])
            }
        }
        updateExternalPausedStateFromPerScreenPauses()
    }

    /// 恢复指定屏幕的渲染（scene：SIGCONT；web：按屏 IPC）
    func resumeWallpaper(for screenID: String) {
        guard isControllingExternalEngine else { return }

        if let info = screenProcesses[screenID] {
            kill(info.pid, SIGCONT)
            perScreenPausedScreenIDs.remove(screenID)
            print("[WallpaperEngineXBridge] 恢复渲染 屏幕 \(screenID) (pid=\(info.pid))")
            updateExternalPausedStateFromPerScreenPauses()
            return
        }

        guard isManaging(screenID: screenID) else { return }
        perScreenPausedScreenIDs.remove(screenID)
        print("[WallpaperEngineXBridge] 恢复 web 渲染 屏幕 \(screenID)")

        if let screen = NSScreen.screens.first(where: { $0.wallpaperScreenIdentifier == screenID }),
           let screenIndex = Self.legacyCLIScreenIndex(for: screen) {
            Task {
                try? await Self.runLegacyCLIClientCommand(["resume", String(screenIndex)])
            }
        }
        updateExternalPausedStateFromPerScreenPauses()
    }

    /// 指定屏幕当前是否已由全局或按屏策略暂停。
    func isPaused(screenID: String) -> Bool {
        isExternalPaused || perScreenPausedScreenIDs.contains(screenID)
    }

    /// 检查指定 screenID 是否被外部引擎管理（有 scene 进程，或在 target / renderStates 中）
    func isManaging(screenID: String) -> Bool {
        if screenProcesses[screenID] != nil { return true }
        if targetScreenIDs.contains(screenID) { return true }
        if screenRenderStates[screenID] != nil { return true }
        return false
    }

    func setMuted(_ muted: Bool) {
        updateRendererAudioControls(muted: muted)
        if isCurrentWallpaperWeb {
            let vol = muted ? nil : VideoWallpaperManager.shared.volume
            sendAudioControlToWebDaemon(muted: muted, volume: vol)
        }
    }

    func setVolume(_ volume: Double, for targetScreen: NSScreen? = nil) {
        updateRendererAudioControls(volume: volume, targetScreen: targetScreen)
        if isCurrentWallpaperWeb {
            sendAudioControlToWebDaemon(muted: nil, volume: volume)
        }
    }

    /// 通过 Unix Socket 直接向 wallpaperengine-cli daemon 发送音频控制 IPC
    private func sendAudioControlToWebDaemon(muted: Bool?, volume: Double?, screen: Int? = nil) {
        let socketPath = "/tmp/wallpaperengine-cli.sock"
        let msg = WebDaemonAudioMessage(command: "audioControl", muted: muted, volume: volume, screen: screen)
        guard let data = try? JSONEncoder().encode(msg) else { return }

        // 整段 socket I/O 丢到后台队列：
        // 1) 必须 recv "OK" 再 close（否则 daemon sendResponse 会触发 SIGPIPE 干掉整个 daemon），
        // 2) 但 @MainActor 上调用 recv 会阻塞 UI（最坏 2s），所以离开主线程执行。
        // 静音/音量切换的 IPC 是 fire-and-forget 语义，调用方不需要立即知道结果。
        DispatchQueue.global(qos: .userInitiated).async {
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            strncpy(&addr.sun_path, socketPath, MemoryLayout.size(ofValue: addr.sun_path) - 1)

            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return }
            defer { close(fd) }

            // 给 recv 设短超时，daemon 正常会立即回 "OK"（<1ms）；2s 兜底防止后台队列长期占用线程
            var rcvTimeout = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &rcvTimeout, socklen_t(MemoryLayout<timeval>.size))

            let size = MemoryLayout<sockaddr_un>.size
            let connected = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(size))
                }
            }
            guard connected == 0 else { return }

            var length = UInt32(data.count)
            let payload = Data(bytes: &length, count: MemoryLayout<UInt32>.size) + data
            let sent = payload.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, payload.count, 0) }
            guard sent == payload.count else { return }

            // 必须读完 daemon 的 "OK" 再 close，否则对端 sendResponse 会写到已关闭的 socket：
            // 触发 EPIPE → SIGPIPE → 干掉整个 wallpaperengine-cli daemon（连带 Web 壁纸窗口消失）。
            // 即使 daemon 已加 signal(SIGPIPE, SIG_IGN) 兜底，App 这边也保持"半双工读完再关"的礼貌行为，
            // 防止旧版本 daemon 二进制（无 SIGPIPE 防护）的用户升级 App 后继续踩坑。
            var responseBuf = Data(repeating: 0, count: 64)
            _ = responseBuf.withUnsafeMutableBytes { recv(fd, $0.baseAddress, 64, 0) }
        }
    }

    /// 通过 Unix Socket 把 WE 128-frame 频谱 fire-and-forget 推给 daemon。
    /// 不读响应、不阻塞：daemon 端 `.audioData` 路由明确不写响应（避免 30fps × OK 塞爆 socket）。
    /// 协议帧格式：[UInt32 length, host byte order][JSON body]，与现有命令保持一致。
    func sendAudioDataToWebDaemon(_ spectrum128: [Float]) {
        guard isCurrentWallpaperWeb else { return }
        guard spectrum128.count == 128 else { return }
        let msg = WebDaemonAudioDataMessage(command: "audioData", spectrum: spectrum128)
        guard let data = try? JSONEncoder().encode(msg) else { return }
        sendFireAndForgetToWebDaemon(data)
    }

    /// 推送系统 Now Playing 到 daemon Web Media Integration。
    func sendMediaUpdateToWebDaemon(
        enabled: Bool,
        title: String,
        artist: String,
        albumTitle: String,
        state: Int,
        position: Double,
        duration: Double,
        rate: Double
    ) {
        guard isCurrentWallpaperWeb || mediaRelayActiveForCurrentWallpaper else { return }
        let msg = WebDaemonMediaUpdateMessage(
            command: "mediaUpdate",
            enabled: enabled,
            title: title,
            artist: artist,
            albumTitle: albumTitle,
            state: state,
            position: position,
            duration: duration,
            rate: rate
        )
        guard let data = try? JSONEncoder().encode(msg) else { return }
        sendFireAndForgetToWebDaemon(data)
    }

    /// 推送封面 data URL（或空字符串清空）。
    func sendMediaThumbnailToWebDaemon(dataURL: String) {
        guard isCurrentWallpaperWeb || mediaRelayActiveForCurrentWallpaper else { return }
        let msg = WebDaemonMediaThumbnailMessage(command: "mediaThumbnail", thumbnail: dataURL)
        guard let data = try? JSONEncoder().encode(msg) else { return }
        sendFireAndForgetToWebDaemon(data)
    }

    /// 推送整首歌词（或 hasLyrics=false 清空）。Web 无 token。
    func sendMediaLyricsToWebDaemon(
        hasLyrics: Bool,
        title: String,
        artist: String,
        songId: String,
        storefront: String,
        source: String,
        lines: [(start: Double, end: Double?, text: String)]
    ) {
        guard isCurrentWallpaperWeb || mediaRelayActiveForCurrentWallpaper else { return }
        let msg = WebDaemonMediaLyricsMessage(
            command: "mediaLyrics",
            hasLyrics: hasLyrics,
            title: title,
            artist: artist,
            songId: songId,
            storefront: storefront,
            source: source,
            lineCount: lines.count,
            lines: lines.map { WebDaemonLyricLine(start: $0.start, end: $0.end, text: $0.text) }
        )
        guard let data = try? JSONEncoder().encode(msg) else { return }
        sendFireAndForgetToWebDaemon(data)
    }

    /// 推送当前歌词行。
    func sendMediaLyricsLineToWebDaemon(
        index: Int,
        text: String,
        nextText: String,
        previousText: String,
        start: Double,
        end: Double?,
        progress: Double,
        elapsedTime: Double,
        hasLine: Bool
    ) {
        guard isCurrentWallpaperWeb || mediaRelayActiveForCurrentWallpaper else { return }
        let msg = WebDaemonMediaLyricsLineMessage(
            command: "mediaLyricsLine",
            index: index,
            text: text,
            nextText: nextText,
            previousText: previousText,
            start: start,
            end: end,
            progress: progress,
            elapsedTime: elapsedTime,
            hasLine: hasLine
        )
        guard let data = try? JSONEncoder().encode(msg) else { return }
        sendFireAndForgetToWebDaemon(data)
    }

    /// 通用 fire-and-forget Unix socket 发送（audio / media 共用）。
    private func sendFireAndForgetToWebDaemon(_ data: Data) {
        let socketPath = "/tmp/wallpaperengine-cli.sock"
        DispatchQueue.global(qos: .userInitiated).async {
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            strncpy(&addr.sun_path, socketPath, MemoryLayout.size(ofValue: addr.sun_path) - 1)

            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return }
            defer { close(fd) }

            let size = MemoryLayout<sockaddr_un>.size
            let connected = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(size))
                }
            }
            guard connected == 0 else { return }

            var length = UInt32(data.count)
            let payload = Data(bytes: &length, count: MemoryLayout<UInt32>.size) + data
            _ = payload.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, payload.count, 0) }
            // 不 recv：daemon 对 audio/media 不发响应；shutdown 让对端 EOF。
            shutdown(fd, SHUT_WR)
        }
    }

    /// 拖拽期间的高频 Web crop 更新：daemon 不响应，避免 30fps 下 socket 读写堆积。
    private func sendWebCropToWebDaemon(for screen: NSScreen) {
        guard let data = webCropMessageData(for: screen, expectsResponse: false) else { return }
        sendFireAndForgetToWebDaemon(data)
    }

    private func webCropMessageData(for screen: NSScreen, expectsResponse: Bool) -> Data? {
        guard let target = nextWebCropParameters(for: screen) else { return nil }
        let message = WebDaemonCropMessage(
            command: "crop",
            crop: target.parameters.crop,
            viewport: target.parameters.viewport,
            letterboxColorHex: target.parameters.letterboxColorHex,
            cropRevision: target.parameters.cropRevision,
            screen: target.screenIndex,
            expectsResponse: expectsResponse
        )
        return try? JSONEncoder().encode(message)
    }

    private func nextWebCropParameters(for screen: NSScreen) -> (screenIndex: Int, parameters: WebCropParameters)? {
        guard let screenIndex = Self.legacyCLIScreenIndex(for: screen) else { return nil }
        let revision = (webCropRevisionByScreenIndex[screenIndex] ?? 0) &+ 1
        webCropRevisionByScreenIndex[screenIndex] = revision

        let settings = DisplayCropSettingsStore.shared.settings(for: screen)
        let wallpaperSize = webContentSize(
            forScreenIndex: screenIndex
        ) ?? screen.frame.size
        let layout = CropLayoutEngine.compute(
            wallpaperSize: wallpaperSize,
            screenSize: screen.frame.size,
            settings: settings
        )
        let shouldApplyCrop = settings.shouldApplyCrop
        let viewport = layout.viewportRect
        let isFullViewport = abs(viewport.x) < 0.0001 && abs(viewport.y) < 0.0001
            && abs(viewport.w - 1) < 0.0001 && abs(viewport.h - 1) < 0.0001
        let parameters = WebCropParameters(
            crop: shouldApplyCrop
                ? [layout.wallpaperCropRect.x, layout.wallpaperCropRect.y, layout.wallpaperCropRect.w, layout.wallpaperCropRect.h]
                : nil,
            viewport: shouldApplyCrop && !isFullViewport
                ? [viewport.x, viewport.y, viewport.w, viewport.h]
                : nil,
            letterboxColorHex: settings.letterboxColorHex,
            cropRevision: revision
        )
        return (screenIndex, parameters)
    }

    /// Web 壁纸的真实内容尺寸由 daemon 从当前可见的 video/canvas/img 推断。
    /// 未识别到时回退屏幕尺寸，保持普通 Web 壁纸原有行为。
    func webContentSize(for screen: NSScreen) -> CGSize? {
        guard isWebWallpaperOn(screen: screen) else { return nil }
        guard let screenIndex = Self.legacyCLIScreenIndex(for: screen) else { return nil }
        return webContentSize(forScreenIndex: screenIndex)
    }

    private func webContentSize(forScreenIndex screenIndex: Int) -> CGSize? {
        let url = URL(fileURLWithPath: legacyCLIWebContentSizePath(for: screenIndex))
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(WebContentSizePayload.self, from: data),
              payload.width.isFinite, payload.height.isFinite,
              payload.width > 0, payload.height > 0 else {
            return nil
        }
        return CGSize(width: payload.width, height: payload.height)
    }

    private func invalidateWebContentSize(for screenIndex: Int) {
        try? FileManager.default.removeItem(
            atPath: legacyCLIWebContentSizePath(for: screenIndex)
        )
    }

    private func waitForWebContentSize(
        for screen: NSScreen,
        timeout: TimeInterval = 1.5
    ) async -> CGSize? {
        guard let screenIndex = Self.legacyCLIScreenIndex(for: screen) else {
            return nil
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let size = webContentSize(forScreenIndex: screenIndex) {
                return size
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return webContentSize(forScreenIndex: screenIndex)
    }

    /// 解析 WE project.json 判断是否需要实时音频频谱。
    /// 命中规则任一为真：`audio.enabled == true` 或 `general.supportsaudioprocessing == true`。
    /// JSON 损坏 / 字段缺失 / 类型错误 → false（不抛）。
    static func wallpaperRequiresAudio(projectJSONURL: URL) -> Bool {
        guard let data = try? Data(contentsOf: projectJSONURL) else { return false }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        if let audio = obj["audio"] as? [String: Any],
           let enabled = audio["enabled"] as? Bool, enabled {
            return true
        }
        if let general = obj["general"] as? [String: Any],
           let supports = general["supportsaudioprocessing"] as? Bool, supports {
            return true
        }
        return false
    }

    /// project.json `type` 是否为 Web（大小写不敏感）
    static func wallpaperIsWebType(projectJSONURL: URL) -> Bool {
        guard let data = try? Data(contentsOf: projectJSONURL) else { return false }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        guard let type = obj["type"] as? String else { return false }
        return type.lowercased() == "web"
    }

    /// 单点真相：扫描所有屏幕当前 web 壁纸的 project.json，
    /// 只要有任意一块屏正在跑需要音频的 web 壁纸，就启 audio relay；
    /// 只要有任意一块在线 web 壁纸，就启 media relay（Media Integration）。
    /// 任何会改变 `screenRenderStates` 或新增/停止 web 渲染的路径都应该在尾部调用一次。
    func ensureAudioRelayMatchesActiveWallpaper(projectRoot: String? = nil) {
        var needsAudio = false
        var needsMedia = false
        // 只扫描当前在线屏上的 web 壁纸；断线保留的 orphan state 不得继续占用中继
        let onlineIDs = Set(NSScreen.screens.map(\.wallpaperScreenIdentifier))
        let onlineFingerprints = Set(NSScreen.screens.map(\.wallpaperScreenFingerprint))
        for state in screenRenderStates.values where state.renderKind == .web {
            let stillOnline = onlineIDs.contains(state.screenID)
                || onlineFingerprints.contains(state.screenFingerprint)
            guard stillOnline else { continue }
            needsMedia = true
            let projectJSON = URL(fileURLWithPath: state.path).appendingPathComponent("project.json")
            if Self.wallpaperRequiresAudio(projectJSONURL: projectJSON) {
                needsAudio = true
            }
            if needsAudio && needsMedia { break }
        }
        // 兜底：调用方明确传入的 projectRoot（刚 setWebWallpaper 完，可能 recordRenderState 还未到）
        // 仅当 project.json type=Web 时才计入，避免 scene 路径误启 media relay
        if let projectRoot {
            let projectJSON = URL(fileURLWithPath: projectRoot).appendingPathComponent("project.json")
            if Self.wallpaperIsWebType(projectJSONURL: projectJSON) {
                needsMedia = true
                if !needsAudio, Self.wallpaperRequiresAudio(projectJSONURL: projectJSON) {
                    needsAudio = true
                }
            }
        }

        if needsAudio && !audioRelayActiveForCurrentWallpaper {
            WallpaperWebAudioRelay.shared.start()
            audioRelayActiveForCurrentWallpaper = true
        } else if !needsAudio && audioRelayActiveForCurrentWallpaper {
            WallpaperWebAudioRelay.shared.stop()
            audioRelayActiveForCurrentWallpaper = false
        }

        // 先置标志再 start：start() 内会立刻 force 推一帧，需放行 sendMedia*
        if needsMedia && !mediaRelayActiveForCurrentWallpaper {
            mediaRelayActiveForCurrentWallpaper = true
            WallpaperWebMediaRelay.shared.start()
        } else if !needsMedia && mediaRelayActiveForCurrentWallpaper {
            WallpaperWebMediaRelay.shared.stop()
            mediaRelayActiveForCurrentWallpaper = false
        } else if needsMedia && mediaRelayActiveForCurrentWallpaper {
            // 换了一张 web 壁纸：强制重推，避免新页错过首帧
            WallpaperWebMediaRelay.shared.forcePush()
        }
    }

    /// 任何"完全停止外部引擎/暂停"的路径必须调用，确保 relay 不残留 SCK。
    func stopAudioRelayIfActive() {
        guard audioRelayActiveForCurrentWallpaper else { return }
        WallpaperWebAudioRelay.shared.stop()
        audioRelayActiveForCurrentWallpaper = false
    }

    func stopMediaRelayIfActive() {
        guard mediaRelayActiveForCurrentWallpaper else { return }
        WallpaperWebMediaRelay.shared.stop()
        mediaRelayActiveForCurrentWallpaper = false
    }

    /// 切换暂停/恢复
    func toggleWallpaper() {
        guard isControllingExternalEngine else {
            print("[WallpaperEngineXBridge] toggleWallpaper: 跳过，当前未控制外部引擎")
            return
        }
        let currentState = isExternalPaused ? "已暂停" : "运行中"
        print("[WallpaperEngineXBridge] toggleWallpaper: 切换渲染状态 (当前=\(currentState))")
        if isExternalPaused {
            resumeWallpaper()
        } else {
            pauseWallpaper()
        }
    }

    /// 停止渲染（终止进程）
    func stopWallpaper() {
        print("[WallpaperEngineXBridge] stopWallpaper: 停止所有实时渲染 (进程数=\(screenProcesses.count))")
        ensureStoppedForNonCLIWallpaper()
    }

    /// 用户从状态栏关闭动态壁纸时调用：停止当前 renderer，但保留持久化状态，方便再次点击开启恢复。
    func disableWallpaperKeepingRestoreState() {
        print("[WallpaperEngineXBridge] disableWallpaperKeepingRestoreState: 关闭渲染并保留恢复状态 (进程数=\(screenProcesses.count))")
        // 对称关闭静态图 overlay（保持久化，与保留 WE 恢复状态语义一致）
        StaticImageWallpaperOverlayManager.shared.hideAll()
        let statesToRestore = Array(screenRenderStates.values)
        stopRenderProcess()
        Task { try? await Self.runLegacyCLIClientCommand(["stop"]) }
        stopAudioRelayIfActive()
        stopMediaRelayIfActive()
        isControllingExternalEngine = false
        isExternalPaused = false
        perScreenPausedScreenIDs.removeAll()
        closeRendererLogs()
        screenProcesses.removeAll()
        _deinitPIDs.removeAll()
        targetScreenIDs.removeAll()
        targetScreenFingerprints.removeAll()
        screenRenderStates.removeAll()
        lastAppliedScreenConfigurations.removeAll()
        preserveRestoreState(statesToRestore)
    }

    /// 切换为**非** wallpaper-wgpu 壁纸时必须调用
    func ensureStoppedForNonCLIWallpaper() {
        let processCount = screenProcesses.count
        AppLogger.error(.wallpaper, "ensureStoppedForNonCLIWallpaper(全局)", metadata: ["processCount": processCount])
        print("[WallpaperEngineXBridge] ensureStoppedForNonCLIWallpaper: 开始清理 \(processCount) 个渲染进程")
        terminateUntrackedDesktopRenderers(reason: "ensureStoppedGlobal")
        if #available(macOS 26.0, *) {
            LockScreenWallpaperService.shared.clearRealtimeSourceIfNeeded()
        }
        stopRenderProcess()
        // 同步杀掉旧 CLI daemon（fire-and-forget 的 client 命令在 App 退出场景来不及发出，
        // 且 stop client 自己还会再 fork daemon — 直接按 PID kill 最稳妥）
        Task { await Self.killLegacyDaemonIfRunning(waitForExit: false) }
        activeRenderKind = nil
        stopAudioRelayIfActive()
        stopMediaRelayIfActive()
        isControllingExternalEngine = false
        isExternalPaused = false
        perScreenPausedScreenIDs.removeAll()
        closeRendererLogs()
        screenProcesses.removeAll()
        _deinitPIDs.removeAll()
        targetScreenIDs.removeAll()
        targetScreenFingerprints.removeAll()
        lastAppliedScreenConfigurations.removeAll()
        UserDefaults.standard.removeObject(forKey: controllingExternalKey)
        UserDefaults.standard.removeObject(forKey: targetScreenIDsKey)
        UserDefaults.standard.removeObject(forKey: targetScreenFingerprintsKey)
        UserDefaults.standard.removeObject(forKey: screenRenderStatesKey)
        screenRenderStates.removeAll()
        print("[WallpaperEngineXBridge] ensureStoppedForNonCLIWallpaper: 清理完成")
    }

    /// 切换指定屏幕为非 wallpaper-wgpu 壁纸时调用，避免误杀其他屏幕的实时渲染。
    func ensureStoppedForNonCLIWallpaper(for targetScreen: NSScreen?) {
        guard let targetScreen else {
            AppLogger.error(.wallpaper, "ensureStoppedForNonCLIWallpaper(for:): targetScreen 为 nil，转为全量清理")
            ensureStoppedForNonCLIWallpaper()
            return
        }

        let screenID = targetScreen.wallpaperScreenIdentifier
        terminateUntrackedDesktopRenderers(
            targetScreenIDs: Set([screenID]),
            reason: "ensureStoppedForScreen"
        )
        guard isManaging(screen: targetScreen) else {
            AppLogger.error(.wallpaper, "ensureStoppedForNonCLIWallpaper(for:): 屏幕不受外部引擎管理，跳过", metadata: ["screenID": screenID])
            return
        }
        AppLogger.error(.wallpaper, "ensureStoppedForNonCLIWallpaper(for:)", metadata: ["screenID": screenID, "screenProcesses": screenProcesses.count])

        if #available(macOS 26.0, *) {
            LockScreenWallpaperService.shared.clearRealtimeSourceIfNeeded()
        }
        let targetState = renderState(for: targetScreen)
        if targetState?.renderKind == .web || (targetState == nil && activeRenderKind == .web) {
            if let screenIndex = Self.legacyCLIScreenIndex(for: targetScreen) {
                Task {
                    do {
                        let status = try await Self.runLegacyCLIClientCommand([
                            "stop-screen",
                            String(screenIndex)
                        ])
                        if status != 0 {
                            print("[WallpaperEngineXBridge] ⚠️ 按屏停止 Web 壁纸失败 screen=\(screenIndex) exit=\(status)")
                        }
                    } catch {
                        print("[WallpaperEngineXBridge] ⚠️ 按屏停止 Web 壁纸失败: \(error.localizedDescription)")
                    }
                }
            }
        }

        if let info = screenProcesses[screenID] {
            screenWatchdogs[info.pid]?.cancel()
            screenWatchdogs.removeValue(forKey: info.pid)
            // 先终止 afplay 音频子进程（SIGTERM handler 可能来不及执行）
            killAllAudioChildren(pid: info.pid)
            terminateRenderer(pid: info.pid)
            let pid = info.pid
            let watchdog = DispatchWorkItem {
                if kill(pid, 0) == 0 {
                    print("[WallpaperEngineXBridge] 目标屏 renderer 未响应 terminate，发送 SIGKILL (pid=\(pid))")
                    kill(pid, SIGKILL)
                }
            }
            screenWatchdogs[pid] = watchdog
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: watchdog)
            removeScreenProcess(screenID)
            _deinitPIDs.remove(pid)
        }

        removeRenderState(for: targetScreen)
        perScreenPausedScreenIDs.remove(screenID)
        updateControlStateFromScreenStates()
        // 这块屏被切走后，全局可能不再有需要音频的 web 壁纸了
        ensureAudioRelayMatchesActiveWallpaper()
        persistState()
    }

    /// 黑场交接专用：Web renderer 必须确认 stop-screen IPC 已完成后才能揭开
    /// 新壁纸。普通同步入口为了兼容旧调用仍是 fire-and-forget；过渡路径不能用它，
    /// 否则黑场退去时旧 WKWebView 仍可能盖在新视频/照片上。
    func ensureStoppedForNonCLIWallpaperForTransition(for targetScreen: NSScreen) async {
        let screenID = targetScreen.wallpaperScreenIdentifier
        terminateUntrackedDesktopRenderers(
            targetScreenIDs: Set([screenID]),
            reason: "crossTypeTransition"
        )
        guard isManaging(screen: targetScreen) else { return }

        let targetState = renderState(for: targetScreen)
        if targetState?.renderKind == .web || (targetState == nil && activeRenderKind == .web) {
            if let screenIndex = Self.legacyCLIScreenIndex(for: targetScreen) {
                do {
                    let status = try await Self.runLegacyCLIClientCommand([
                        "stop-screen",
                        String(screenIndex)
                    ])
                    if status != 0 {
                        print("[WallpaperEngineXBridge] ⚠️ 黑场交接 stop-screen 失败 screen=\(screenIndex) exit=\(status)")
                    }
                } catch {
                    print("[WallpaperEngineXBridge] ⚠️ 黑场交接 stop-screen 异常: \(error.localizedDescription)")
                }
            }
        }

        // IPC 已返回后直接清理本地管理状态和可能存在的 Scene 进程。
        // 不再调用同步版本：它会再次异步发送 stop-screen，最后一块 Web 屏退出时
        // 甚至可能重新拉起 daemon client，造成旧窗口重新排到新壁纸前面。
        if #available(macOS 26.0, *) {
            LockScreenWallpaperService.shared.clearRealtimeSourceIfNeeded()
        }
        if let info = screenProcesses[screenID] {
            screenWatchdogs[info.pid]?.cancel()
            screenWatchdogs.removeValue(forKey: info.pid)
            killAllAudioChildren(pid: info.pid)
            perScreenPausedScreenIDs.remove(screenID)
            terminateRenderer(pid: info.pid)
            let pid = info.pid
            // Scene 进程可能刚从 SIGSTOP 恢复。黑场必须等它的窗口真正退出，
            // 不能像普通清理那样安排一个 2 秒后的 watchdog 就立刻揭开。
            let gracefulDeadline = Date().addingTimeInterval(0.45)
            while kill(pid, 0) == 0 && Date() < gracefulDeadline {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            if kill(pid, 0) == 0 {
                kill(pid, SIGKILL)
                let killDeadline = Date().addingTimeInterval(0.30)
                while kill(pid, 0) == 0 && Date() < killDeadline {
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }
            }
            removeScreenProcess(screenID)
            _deinitPIDs.remove(pid)
        }
        removeRenderState(for: targetScreen)
        perScreenPausedScreenIDs.remove(screenID)
        updateControlStateFromScreenStates()
        ensureAudioRelayMatchesActiveWallpaper()
        persistState()
    }

    /// 应用退出前调用：立即杀死所有渲染进程，不等待退出，避免阻塞主线程导致 App 卡死。
    func prepareForAppTermination() {
        // `stopScreenProcess` 会先移除字典记录，再等待 watchdog。若用户恰好在
        // 这段窗口退出 App，只遍历 screenProcesses 会漏掉仍活着的子进程。
        let discoveredPIDs = Set(Self.discoverDesktopRenderers().map(\.pid))
        let pidsToKill = discoveredPIDs.union(screenProcesses.values.map(\.pid))
        let processCount = pidsToKill.count
        let pids = pidsToKill.map(String.init).joined(separator: ", ")
        print("[WallpaperEngineXBridge] prepareForAppTermination: 应用退出，立即终止 \(processCount) 个渲染进程 pids=[\(pids)]")
        // 直接 SIGKILL 所有屏幕渲染进程，不做 graceful terminate + 等待
        for pid in pidsToKill {
            kill(pid, SIGCONT)
            kill(pid, SIGKILL)
        }
        // 同步杀掉旧 CLI daemon
        Self.killLegacyDaemonSync()
        closeRendererLogs()
        screenProcesses.removeAll()
        _deinitPIDs.removeAll()
        screenWatchdogs.values.forEach { $0.cancel() }
        screenWatchdogs.removeAll()
        stopAudioRelayIfActive()
        stopMediaRelayIfActive()
        isControllingExternalEngine = false
        isExternalPaused = false
        targetScreenIDs.removeAll()
        targetScreenFingerprints.removeAll()
        lastAppliedScreenConfigurations.removeAll()
    }

    /// 同步终止 `/tmp/wallpaperengine-cli.pid` 指向的 daemon 进程（无视 `activeRenderKind`）。
    /// App 退出 / 切换壁纸时使用，避免遗留 daemon 持续渲染 web 壁纸。
    private static func killLegacyDaemonIfRunning(waitForExit: Bool) async {
        let pidPath = "/tmp/wallpaperengine-cli.pid"
        guard let pidStr = try? String(contentsOfFile: pidPath, encoding: .utf8) else {
            return
        }
        let trimmed = pidStr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = pid_t(trimmed), pid > 0, kill(pid, 0) == 0 else {
            // 进程已经不在了，顺手清掉过期的 PID 文件
            try? FileManager.default.removeItem(atPath: pidPath)
            return
        }

        print("[WallpaperEngineXBridge] 终止旧 CLI daemon (pid=\(pid)) waitForExit=\(waitForExit)")
        kill(pid, SIGTERM)

        if waitForExit {
            let deadline = Date().addingTimeInterval(1.5)
            while kill(pid, 0) == 0 && Date() < deadline {
                try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
            }
            if kill(pid, 0) == 0 {
                print("[WallpaperEngineXBridge] daemon 未响应 SIGTERM，改发 SIGKILL")
                kill(pid, SIGKILL)
                let killDeadline = Date().addingTimeInterval(0.5)
                while kill(pid, 0) == 0 && Date() < killDeadline {
                    try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
                }
            }
        }

        try? FileManager.default.removeItem(atPath: pidPath)
    }

    /// App 退出时同步杀死旧 CLI daemon，不等待退出，避免阻塞主线程。
    private static func killLegacyDaemonSync() {
        let pidPath = "/tmp/wallpaperengine-cli.pid"
        guard let pidStr = try? String(contentsOfFile: pidPath, encoding: .utf8) else { return }
        let trimmed = pidStr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = pid_t(trimmed), pid > 0 else {
            try? FileManager.default.removeItem(atPath: pidPath)
            return
        }
        if kill(pid, 0) == 0 {
            kill(pid, SIGKILL)
        }
        try? FileManager.default.removeItem(atPath: pidPath)
    }

    /// Scene renderer writes canvas-size after the current project has initialized.
    /// WindowServer does not reliably expose backing-store metadata for desktop-level
    /// windows, so readiness must not depend on CGWindowList (that can hold the whole
    /// wallpaper switch busy until timeout). Require the new canvas generation and a
    /// live process to remain stable briefly, then leave several display intervals for
    /// the first drawable before entering the black commit.
    private func waitForScenePresentationReady(
        path: String,
        screens: [NSScreen],
        generation: UInt64
    ) async throws {
        let expectedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let deadline = Date().addingTimeInterval(10)
        var stableSince: Date?
        while Date() < deadline {
            guard wallpaperSwitchGeneration == generation else {
                throw WallpaperEngineError.executionFailed("Scene 交接已被更新请求作废")
            }
            let liveScreens = Self.uniqueLiveScreens(preferred: screens)
            guard liveScreens.count == screens.count else {
                throw WallpaperEngineError.executionFailed("Scene 交接目标显示器已变化")
            }
            let allReady = liveScreens.allSatisfy { screen in
                let screenID = screen.wallpaperScreenIdentifier
                guard let state = screenRenderStates[screenID],
                      URL(fileURLWithPath: state.path).standardizedFileURL.path == expectedPath,
                      let process = screenProcesses[screenID],
                      process.process.isRunning,
                      let canvasURL = process.canvasSizeURL else { return false }
                return readCanvasSize(url: canvasURL) != nil
            }
            if allReady {
                if stableSince == nil {
                    stableSince = Date()
                } else if Date().timeIntervalSince(stableSince!) >= 0.24 {
                    // The old video remains in front during this settle period.
                    try? await Task.sleep(nanoseconds: 160_000_000)
                    return
                }
            } else {
                stableSince = nil
            }
            try await Task.sleep(nanoseconds: 80_000_000)
        }
        throw WallpaperEngineError.executionFailed("Scene 实时渲染首帧准备超时，已保留原视频壁纸")
    }

    /// Web 没有 wallpaper-wgpu 的 canvas-size 文件；capture IPC 是 daemon
    /// 真正把 WKWebView 当前 drawable 交给 WindowServer 的边界。连续两次
    /// 有效截图才允许提交，避免 set 命令返回后仍处于空白/加载页。
    private func waitForWebPresentationReady(
        path: String,
        screens: [NSScreen],
        generation: UInt64
    ) async throws {
        let expectedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let deadline = Date().addingTimeInterval(12)
        var stablePasses = 0
        while Date() < deadline {
            guard wallpaperSwitchGeneration == generation else {
                throw WallpaperEngineError.executionFailed("Web 交接已被更新请求作废")
            }
            let liveScreens = Self.uniqueLiveScreens(preferred: screens)
            guard liveScreens.count == screens.count else {
                throw WallpaperEngineError.executionFailed("Web 交接目标显示器已变化")
            }

            var allReady = true
            for screen in liveScreens {
                let screenID = screen.wallpaperScreenIdentifier
                guard screenRenderStates[screenID]?.renderKind == .web,
                      URL(fileURLWithPath: screenRenderStates[screenID]?.path ?? "")
                        .standardizedFileURL.path == expectedPath,
                      let screenIndex = Self.legacyCLIScreenIndex(for: screen) else {
                    allReady = false
                    break
                }
                let captureURL = URL(fileURLWithPath: legacyCLICapturePath(for: screenIndex))
                try? FileManager.default.removeItem(at: captureURL)
                let status = (try? await Self.runLegacyCLIClientCommand(["capture", String(screenIndex)])) ?? -1
                guard status == 0,
                      let source = CGImageSourceCreateWithURL(captureURL as CFURL, nil),
                      CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
                    allReady = false
                    break
                }
            }
            if allReady {
                stablePasses += 1
                if stablePasses >= 2 {
                    return
                }
            } else {
                stablePasses = 0
            }
            try await Task.sleep(nanoseconds: 120_000_000)
        }
        throw WallpaperEngineError.executionFailed("Web 实时渲染首帧准备超时，已保留原视频壁纸")
    }

    private func discardPreparedRenderer(on screens: [NSScreen]) async {
        for screen in Self.uniqueLiveScreens(preferred: screens) {
            await ensureStoppedForNonCLIWallpaperForTransition(for: screen)
        }
    }

    private func commitPreparedRendererOverNativeVideo(on screens: [NSScreen]) async {
        await WallpaperCrossTypeTransitionCoordinator.shared.commitPreparedContent(
            on: screens,
            snapshotFallback: { screen in
                guard let posterURL = VideoWallpaperManager.shared.posterURL(for: screen),
                      posterURL.isFileURL,
                      FileManager.default.fileExists(atPath: posterURL.path) else {
                    return nil
                }
                return NSImage(contentsOf: posterURL)
            }
        ) {
            for screen in screens {
                VideoWallpaperManager.shared.stopNativeVideoWallpaperOnly(for: screen)
                StaticImageWallpaperOverlayManager.shared.clearState(for: screen)
            }
        }
    }

    private func setWebWallpaper(path: String, targetScreens: [NSScreen]?) async throws {
        let screens = targetScreens?.isEmpty == false ? targetScreens! : NSScreen.screens
        guard !screens.isEmpty else {
            throw WallpaperEngineError.executionFailed("没有可用的 Web 壁纸目标显示器")
        }

        let targetIndexes = screens.compactMap(Self.legacyCLIScreenIndex(for:))
        guard targetIndexes.count == screens.count else {
            throw WallpaperEngineError.executionFailed("Web 壁纸目标显示器已变化，请重试")
        }

        // wallpaperengine-cli 的 set 命令一次只处理一个屏幕索引。必须逐屏发送，
        // 否则全局多屏轮换会让副屏被记录为已管理、实际却没有 WebView。
        print("[WallpaperEngineXBridge] 使用旧 wallpaperengine-cli 设置 Web 壁纸: \(path) screenIdx=\(targetIndexes)")
        // 清理旧的 legacy 路径和 per-screen 路径（CLI daemon 写入 per-screen 路径）
        try? FileManager.default.removeItem(atPath: legacyCLIWebCapturePath)
        // 旧版离线 Web 烘焙曾错误写入隐藏 screen=-1 的 PNG；设 Web 时顺手清除遗留。
        try? FileManager.default.removeItem(atPath: legacyCLICapturePath(for: -1))
        for i in 0..<NSScreen.screens.count {
            try? FileManager.default.removeItem(atPath: legacyCLICapturePath(for: i))
        }

        for screen in screens {
            if let screenIndex = Self.legacyCLIScreenIndex(for: screen) {
                invalidateWebContentSize(for: screenIndex)
            }
            guard let initialCrop = nextWebCropParameters(for: screen) else {
                throw WallpaperEngineError.executionFailed("Web 壁纸目标显示器已变化，请重试")
            }
            guard let cropData = try? JSONEncoder().encode(initialCrop.parameters) else {
                throw WallpaperEngineError.executionFailed("Web 壁纸裁切参数编码失败")
            }
            let result = try await Self.runLegacyCLIClientCommandDetailed([
                "set", path, String(initialCrop.screenIndex), "--initial-crop", cropData.base64EncodedString()
            ])
            guard result.status == 0 else {
                let detail = result.output.isEmpty ? "" : ": \(result.output)"
                throw WallpaperEngineError.executionFailed(
                    "wallpaperengine-cli set 失败 (screen=\(initialCrop.screenIndex), exit=\(result.status))\(detail)"
                )
            }

            // 首次 set 时 WebView 还未完成媒体元数据探测，initial crop 只能
            // 使用屏幕尺寸。等 daemon 写出真实内容尺寸后补发一次最终 crop，
            // 避免 16:9 媒体在 16:10 屏幕上永久丢失左右区域。
            _ = await waitForWebContentSize(for: screen)
            if webContentSize(forScreenIndex: initialCrop.screenIndex) != nil {
                sendWebCropToWebDaemon(for: screen)
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
        }

        // 初始 crop 已随 `set` 在窗口显示前应用。海报、锁屏和系统静态帧仍保持原始 Web 截图。

        if let propertiesJSON = try? WebWallpaperDesignService.shared.effectivePropertiesJSON(for: path),
           !propertiesJSON.isEmpty {
            for screenIndex in targetIndexes {
                let status = try await Self.runLegacyCLIClientCommand([
                    "apply-properties",
                    propertiesJSON,
                    String(screenIndex)
                ])
                if status != 0 {
                    print("[WallpaperEngineXBridge] ⚠️ Web 属性初始化失败 screen=\(screenIndex) exit=\(status)")
                }
            }
        }

        // 初始化 Web 壁纸的音频状态（同步当前 mute/volume）
        let isMuted = VideoWallpaperManager.shared.isMuted
        let volume = VideoWallpaperManager.shared.volume
        for screenIndex in targetIndexes {
            sendAudioControlToWebDaemon(
                muted: isMuted,
                volume: isMuted ? nil : volume,
                screen: screenIndex
            )
        }
    }

    private static func uniqueLiveScreens(preferred: [NSScreen]) -> [NSScreen] {
        let live = NSScreen.screens
        var byID: [String: NSScreen] = [:]
        var byFingerprint: [String: NSScreen] = [:]
        for screen in live {
            byID[screen.wallpaperScreenIdentifier] = screen
            byFingerprint[screen.wallpaperScreenFingerprint] = screen
        }
        var seen = Set<String>()
        return preferred.compactMap { screen in
            let resolved = byID[screen.wallpaperScreenIdentifier]
                ?? byFingerprint[screen.wallpaperScreenFingerprint]
            guard let resolved, seen.insert(resolved.wallpaperScreenIdentifier).inserted else {
                return nil
            }
            return resolved
        }
    }

    /// Web daemon 可直接通过其 WKWebView 截图，无需生成临时 MP4 或音轨。
    ///
    /// 仅在没有可播放离线烘焙视频时，先预热页面并采样多张无声截图，避开开场/转场帧后写入 canonical poster。
    private func scheduleWebPosterCapture(path: String, targetScreens: [NSScreen]) {
        let contentRoot = WorkshopService.resolveWallpaperEngineProjectRoot(
            startingAt: URL(fileURLWithPath: path)
        )
        let record = webPosterRecord(for: contentRoot)
        if let record,
           let artifact = SceneOfflineBakeService.usableArtifact(from: record) {
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.isCurrentWebWallpaper(
                    path: path,
                    on: Set(targetScreens.map(\.wallpaperScreenIdentifier))
                ) else {
                    return
                }

                let bakedVideoURL = URL(fileURLWithPath: artifact.videoPath)
                if #available(macOS 26.0, *),
                   VideoWallpaperManager.shared.isLockScreenEnabled {
                    let displayIDs = targetScreens.compactMap {
                        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
                    }
                    if !displayIDs.isEmpty {
                        await LockScreenWallpaperService.shared.switchActiveInstancesToLocalDecode(
                            videoURL: bakedVideoURL,
                            videoID: record.item.id,
                            displayIDs: displayIDs
                        )
                        print("[WallpaperEngineXBridge] 🎬 已将 Web 烘焙 MP4 同步到锁屏扩展: display=\(displayIDs) video=\(record.item.id)")
                    }

                    // 锁屏已经使用 MP4；poster 仅用于详情页/封面缓存，绝不降级覆盖为静态锁屏源。
                    _ = await ensureSceneBakePosterAndNotify(
                        itemID: record.item.id,
                        videoURL: bakedVideoURL
                    )
                    return
                }

                guard let posterURL = await ensureSceneBakePosterAndNotify(
                    itemID: record.item.id,
                    videoURL: bakedVideoURL
                ) else {
                    print("[WallpaperEngineXBridge] Web 烘焙 MP4 poster 补抽失败: \(artifact.videoPath)")
                    return
                }
                await self.syncWebPosterToStaticTargets(
                    posterURL,
                    path: path,
                    targetScreens: targetScreens
                )
            }
            return
        }

        let cacheItemID = record?.item.id
            ?? SceneOfflineBakeService.stableOrphanCacheItemID(contentRootPath: contentRoot.path)
        if let cachedPoster = VideoThumbnailCache.shared.cachedSceneBakePosterFileURLIfExists(
            itemID: cacheItemID
        ) {
            Task { @MainActor [weak self] in
                guard let self,
                      self.isCurrentWebWallpaper(
                          path: path,
                          on: Set(targetScreens.map(\.wallpaperScreenIdentifier))
                      ) else {
                    return
                }
                await self.syncWebPosterToStaticTargets(
                    cachedPoster,
                    path: path,
                    targetScreens: targetScreens
                )
            }
            return
        }

        guard let posterScreen = targetScreens.first(where: { $0 == NSScreen.main }) ?? targetScreens.first,
              let screenIndex = Self.legacyCLIScreenIndex(for: posterScreen) else {
            return
        }

        // 不复用短 MP4 烘焙：海报不需要音频，直接向正在运行的 daemon 截图即可。
        // 某些 Web 壁纸前数秒是白场/黑场/片头，预热后连续采样并选信息量最佳的一张。
        let captureWarmup: UInt64 = 7_000_000_000
        let sampleInterval: UInt64 = 1_500_000_000
        let sampleCount = 4
        let targetScreenIDs = Set(targetScreens.map(\.wallpaperScreenIdentifier))
        Task(priority: .utility) { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: captureWarmup)
            } catch {
                return
            }

            guard let self,
                  self.isCurrentWebWallpaper(path: path, on: targetScreenIDs) else {
                return
            }

            let currentRecord = self.webPosterRecord(for: contentRoot)
            guard SceneOfflineBakeService.usableArtifact(from: currentRecord) == nil else {
                return
            }

            let fileManager = FileManager.default
            let sampleDirectory = fileManager.temporaryDirectory
                .appendingPathComponent("WaifuX/WebPosterSamples", isDirectory: true)
            let samplePrefix = "web-poster-\(UUID().uuidString)"
            var sampleURLs: [URL] = []
            defer {
                for url in sampleURLs {
                    try? fileManager.removeItem(at: url)
                }
            }

            do {
                try fileManager.createDirectory(at: sampleDirectory, withIntermediateDirectories: true)
            } catch {
                print("[WallpaperEngineXBridge] Web poster sample directory failed: \(error.localizedDescription)")
                return
            }

            var bestCandidate: WebPosterCaptureCandidate?
            for sampleIndex in 0..<sampleCount {
                guard self.isCurrentWebWallpaper(path: path, on: targetScreenIDs),
                      SceneOfflineBakeService.usableArtifact(
                          from: self.webPosterRecord(for: contentRoot)
                      ) == nil else {
                    return
                }

                do {
                    let status = try await Self.runLegacyCLIClientCommand(["capture", String(screenIndex)])
                    guard status == 0 else {
                        print("[WallpaperEngineXBridge] Web poster sample failed screen=\(screenIndex) exit=\(status)")
                        continue
                    }

                    let captureURL = URL(fileURLWithPath: legacyCLICapturePath(for: screenIndex))
                    guard fileManager.fileExists(atPath: captureURL.path) else {
                        print("[WallpaperEngineXBridge] Web poster sample missing screen=\(screenIndex)")
                        continue
                    }

                    let sampleURL = sampleDirectory.appendingPathComponent(
                        "\(samplePrefix)-\(sampleIndex).png"
                    )
                    try? fileManager.removeItem(at: sampleURL)
                    try fileManager.copyItem(at: captureURL, to: sampleURL)
                    sampleURLs.append(sampleURL)

                    let candidate = await Task.detached(priority: .utility) {
                        Self.webPosterCaptureCandidate(for: sampleURL)
                    }.value ?? WebPosterCaptureCandidate(
                        url: sampleURL,
                        score: 0,
                        meanLuma: 0,
                        lumaVariance: 0
                    )
                    if bestCandidate == nil || candidate.score > bestCandidate!.score {
                        bestCandidate = candidate
                    }
                    print(
                        "[WallpaperEngineXBridge] Web poster sample \(sampleIndex + 1)/\(sampleCount) "
                            + "luma=\(String(format: "%.1f", candidate.meanLuma)) "
                            + "variance=\(String(format: "%.1f", candidate.lumaVariance)) "
                            + "score=\(String(format: "%.3f", candidate.score))"
                    )
                } catch {
                    print("[WallpaperEngineXBridge] Web poster sample failed: \(error.localizedDescription)")
                }

                if sampleIndex + 1 < sampleCount {
                    do {
                        try await Task.sleep(nanoseconds: sampleInterval)
                    } catch {
                        return
                    }
                }
            }

            let finalRecord = self.webPosterRecord(for: contentRoot)
            guard self.isCurrentWebWallpaper(path: path, on: targetScreenIDs),
                  SceneOfflineBakeService.usableArtifact(from: finalRecord) == nil,
                  let bestCandidate,
                  let posterURL = await VideoThumbnailCache.shared.wallpaperEnginePosterJPEGFileURL(
                      forImageFile: bestCandidate.url,
                      itemID: cacheItemID,
                      forceRegenerate: true
                  ) else {
                print("[WallpaperEngineXBridge] Web poster capture exhausted without a usable frame")
                return
            }

            if let itemID = finalRecord?.item.id ?? currentRecord?.item.id ?? record?.item.id {
                NotificationCenter.default.post(
                    name: .sceneOfflineBakeThumbnailDidUpdate,
                    object: itemID,
                    userInfo: ["thumbnailURL": posterURL]
                )
            }
            await self.syncWebPosterToStaticTargets(
                posterURL,
                path: path,
                targetScreens: targetScreens
            )
            print(
                "[WallpaperEngineXBridge] Web poster cached screen=\(screenIndex) "
                    + "score=\(String(format: "%.3f", bestCandidate.score)): \(posterURL.path)"
            )
        }
    }

    /// 对低分辨率副本计算亮度与方差。分数会惩罚几乎纯黑/纯白的片头、闪白和转场帧。
    private nonisolated static func webPosterCaptureCandidate(for url: URL) -> WebPosterCaptureCandidate? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 160,
            kCGImageSourceShouldCacheImmediately: false
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions as CFDictionary
        ) else {
            return nil
        }

        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let didRender = pixels.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress,
                  let context = CGContext(
                      data: baseAddress,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: bytesPerRow,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                          | CGBitmapInfo.byteOrder32Big.rawValue
                  ) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard didRender else { return nil }

        var lumaTotal = 0.0
        var lumaSquaredTotal = 0.0
        let pixelCount = width * height
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let luma = 0.299 * Double(pixels[index])
                + 0.587 * Double(pixels[index + 1])
                + 0.114 * Double(pixels[index + 2])
            lumaTotal += luma
            lumaSquaredTotal += luma * luma
        }

        let meanLuma = lumaTotal / Double(pixelCount)
        let lumaVariance = max(0, lumaSquaredTotal / Double(pixelCount) - meanLuma * meanLuma)
        let contrastScore = min(1, sqrt(lumaVariance) / 56)
        let darknessPenalty = min(1, max(0, (18 - meanLuma) / 18))
        let brightnessPenalty = min(1, max(0, (meanLuma - 242) / 13))
        let score = contrastScore * (1 - darknessPenalty) * (1 - brightnessPenalty)

        return WebPosterCaptureCandidate(
            url: url,
            score: score,
            meanLuma: meanLuma,
            lumaVariance: lumaVariance
        )
    }

    private func webPosterRecord(for contentRoot: URL) -> MediaDownloadRecord? {
        let library = MediaLibraryService.shared
        if let exact = library.downloadRecord(forLocalFilePath: contentRoot.path) {
            return exact
        }
        return library.downloadedItems.first { record in
            record.hasSameLocalContent(as: contentRoot)
                || WorkshopService.resolveWallpaperEngineProjectRoot(
                    startingAt: URL(fileURLWithPath: record.localFilePath)
                ).path == contentRoot.path
        }
    }

    /// Web MP4 烘焙完成时立即复用成片；实时渲染无需重启，锁屏只切换其本地解码源。
    private func syncCompletedWebBakeIfActive(_ artifact: SceneBakeArtifact) {
        guard activeRenderKind == .web else { return }
        guard let record = MediaLibraryService.shared.downloadedItems.first(where: {
            $0.sceneBakeArtifact?.videoPath == artifact.videoPath
                && $0.sceneBakeArtifact?.renderer == .wallpaperEngineWeb
        }) else {
            return
        }

        let contentRoot = WorkshopService.resolveWallpaperEngineProjectRoot(
            startingAt: URL(fileURLWithPath: record.localFilePath)
        )
        let matchingStates = screenRenderStates.values.filter { state in
            guard state.renderKind == .web else { return false }
            return WorkshopService.resolveWallpaperEngineProjectRoot(
                startingAt: URL(fileURLWithPath: state.path)
            ).path == contentRoot.path
        }
        guard !matchingStates.isEmpty else { return }

        let targetScreenIDs = Set(matchingStates.map(\.screenID))
        let targetScreens = NSScreen.screens.filter {
            targetScreenIDs.contains($0.wallpaperScreenIdentifier)
        }
        guard !targetScreens.isEmpty else { return }

        scheduleWebPosterCapture(
            path: matchingStates[0].path,
            targetScreens: targetScreens
        )
    }

    /// Web/MP4 共用 canonical poster；锁屏与系统桌面只消费该文件，不直接引用 daemon 的 /tmp 截图。
    private func syncWebPosterToStaticTargets(
        _ posterURL: URL,
        path: String,
        targetScreens: [NSScreen]
    ) async {
        guard FileManager.default.fileExists(atPath: posterURL.path) else { return }

        if #available(macOS 26.0, *),
           VideoWallpaperManager.shared.isLockScreenEnabled {
            let displayIDs = targetScreens.compactMap {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            }
            guard !displayIDs.isEmpty else { return }
            do {
                try await LockScreenWallpaperService.shared.cacheStaticImageSource(
                    imageURL: posterURL,
                    displayIDs: displayIDs
                )
                print("[WallpaperEngineXBridge] 🖼️ 已将 Web canonical poster 同步到锁屏扩展: \(posterURL.lastPathComponent)")
            } catch {
                print("[WallpaperEngineXBridge] ⚠️ Web canonical poster 锁屏同步失败: \(error.localizedDescription)")
            }
            return
        }

        _ = applyBakedStaticImage(
            posterURL,
            for: path,
            targetScreens: targetScreens,
            updateGeneration: nil
        )
    }

    private func isCurrentWebWallpaper(path: String, on screenIDs: Set<String>) -> Bool {
        guard activeRenderKind == .web else { return false }
        return screenIDs.allSatisfy { screenID in
            guard let state = screenRenderStates[screenID] else { return false }
            return state.renderKind == .web && state.path == path
        }
    }

    /// 启动旧 `wallpaperengine-cli` 的客户端子命令（set/pause/resume/stop-screen）。
    /// 这些命令仅作为 IPC 客户端，向 daemon 发完消息就退出；真正的 web 渲染由 daemon 持有。
    @discardableResult
    private static func runLegacyCLIClientCommand(_ arguments: [String]) async throws -> Int32 {
        let result = try await runLegacyCLIClientCommandDetailed(arguments)
        return result.status
    }

    /// 同 `runLegacyCLIClientCommand`，额外捕获 stdout/stderr，便于把 daemon ERROR 文案回传给 UI。
    private static func runLegacyCLIClientCommandDetailed(
        _ arguments: [String]
    ) async throws -> (status: Int32, output: String) {
        guard let cli = Self.resolvedLegacyCLIExecutableURL() else {
            print("[WallpaperEngineXBridge] ❌ wallpaperengine-cli 二进制未找到，已搜索所有路径")
            throw WallpaperEngineError.legacyCliNotFound
        }
        let env = legacyCLILaunchEnvironment(for: cli)
        return try await Task.detached(priority: .userInitiated) { () throws -> (Int32, String) in
            let process = Process()
            process.executableURL = cli
            process.arguments = arguments
            process.environment = env
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (process.terminationStatus, output)
        }.value
    }

    func applyWebWallpaperProperties(_ propertiesJSON: String) async throws {
        guard isCurrentWallpaperWeb else {
            throw WallpaperEngineError.executionFailed("当前没有运行中的 Web 壁纸")
        }

        let targetIndexes = NSScreen.screensOrderedForDisplay.enumerated().compactMap { index, screen -> Int? in
            isWebWallpaperOn(screen: screen) ? index : nil
        }
        guard !targetIndexes.isEmpty else {
            throw WallpaperEngineError.executionFailed("当前没有可更新属性的 Web 显示器")
        }

        for screenIndex in targetIndexes {
            let status = try await Self.runLegacyCLIClientCommand([
                "apply-properties",
                propertiesJSON,
                String(screenIndex)
            ])
            guard status == 0 else {
                throw WallpaperEngineError.executionFailed(
                    "Web 壁纸属性热更新失败 (screen=\(screenIndex), exit=\(status))"
                )
            }
        }
    }

    /// 给旧 CLI 客户端进程拼装环境变量（仅 web 壁纸 daemon 使用）。
    private static func legacyCLILaunchEnvironment(for cli: URL) -> [String: String] {
        // 每次拉起/调用 CLI 前刷新控制文件，保证长驻 daemon 读到最新开关
        VideoWallpaperManager.shared.publishSystemWallpaperSyncControlToWebDaemon()
        var env = ProcessInfo.processInfo.environment
        env["LSUIElement"] = "1"
        if #available(macOS 26.0, *) {
            env["WAIFUX_DYNAMIC_LOCK_SCREEN_ENABLED"] = VideoWallpaperManager.shared.isLockScreenEnabled ? "1" : "0"
        } else {
            env["WAIFUX_DYNAMIC_LOCK_SCREEN_ENABLED"] = "0"
        }
        // 与 App 内「系统壁纸同步」一致：关闭时 daemon 不得 setDesktopImageURL
        env["WAIFUX_SYSTEM_WALLPAPER_SYNC_ENABLED"] = VideoWallpaperManager.shared.isSystemWallpaperSyncEnabled ? "1" : "0"
        return env
    }

    private static func rendererLaunchEnvironment(for rendererURL: URL) -> [String: String] {
        let rendererDirectory = rendererURL.deletingLastPathComponent()
        let resourceDirectory = rendererDirectory.lastPathComponent == "Resources"
            ? rendererDirectory
            : rendererDirectory.appendingPathComponent("Resources")
        var environment = ProcessInfo.processInfo.environment

        let searchPaths = [
            rendererDirectory.path,
            resourceDirectory.path,
            environment["PATH"] ?? "",
        ].filter { !$0.isEmpty }
        environment["PATH"] = searchPaths.joined(separator: ":")
        environment["DYLD_LIBRARY_PATH"] = [
            rendererDirectory.appendingPathComponent("lib").path,
            resourceDirectory.appendingPathComponent("lib").path,
            environment["DYLD_LIBRARY_PATH"] ?? ""
        ].filter { !$0.isEmpty }.joined(separator: ":")
        environment["LSUIElement"] = "1"
        return environment
    }

    private struct RendererLaunch {
        let process: Process
        let logFile: FileHandle?
    }

    private static func rendererLogURL(screenID: String) -> URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = caches.appendingPathComponent("com.waifux.wallpaperengine/renderer-logs", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let safeID = screenID.map { ch -> Character in
                ch.isLetter || ch.isNumber || ch == "-" || ch == "_" ? ch : "_"
            }
            return directory.appendingPathComponent("screen-\(String(safeID)).log")
        } catch {
            print("[WallpaperEngineXBridge] renderer 日志目录创建失败: \(error.localizedDescription)")
            return nil
        }
    }

    private static func rendererLogFile(screenID: String) -> FileHandle? {
        guard let url = rendererLogURL(screenID: screenID) else { return nil }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        do {
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: 0)
            let header = "=== wallpaper-wgpu screen=\(screenID) \(Date()) ===\n"
            if let data = header.data(using: .utf8) {
                handle.write(data)
            }
            return handle
        } catch {
            print("[WallpaperEngineXBridge] renderer 日志文件打开失败: \(error.localizedDescription)")
            return nil
        }
    }

    private func launchRendererProcess(executableURL: URL, arguments: [String], generation: UInt64, screenID: String) throws -> RendererLaunch {
        print("[WallpaperEngineXBridge] launchRendererProcess: 启动渲染进程 screen=\(screenID) executable=\(executableURL.lastPathComponent)")
        // 脱敏参数日志：排除 --user-properties 后的长 JSON，避免日志过大
        let safeArgs = arguments.map { arg in
            arg.count > 200 ? String(arg.prefix(100)) + "...(truncated \(arg.count - 200) chars)" : arg
        }
        print("[WallpaperEngineXBridge] launchRendererProcess: 参数 \(safeArgs.joined(separator: " "))")

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = executableURL.deletingLastPathComponent()
        process.environment = Self.rendererLaunchEnvironment(for: executableURL)
        let logFile = Self.rendererLogFile(screenID: screenID)
        process.standardOutput = logFile ?? FileHandle.nullDevice
        process.standardError = logFile ?? FileHandle.nullDevice
        process.terminationHandler = { [weak self] process in
            let event = TerminationEvent(
                pid: process.processIdentifier,
                generation: generation,
                status: process.terminationStatus,
                reason: process.terminationReason
            )
            self?.enqueueTermination(event)
        }
        do {
            try process.run()
            print("[WallpaperEngineXBridge] ✅ launchRendererProcess: 渲染进程已启动 screen=\(screenID) pid=\(process.processIdentifier)")
            return RendererLaunch(process: process, logFile: logFile)
        } catch {
            print("[WallpaperEngineXBridge] ❌ launchRendererProcess: 渲染进程启动失败 screen=\(screenID) error=\(error.localizedDescription)")
            print("[WallpaperEngineXBridge] ❌ launchRendererProcess: executableURL=\(executableURL.path) cwd=\(executableURL.deletingLastPathComponent().path)")
            throw error
        }
    }

    private nonisolated func enqueueTermination(_ event: TerminationEvent) {
        os_unfair_lock_lock(terminationLockPtr)
        pendingTerminations[event.pid] = event
        terminationPendingFlag = true
        os_unfair_lock_unlock(terminationLockPtr)
    }

    // MARK: - 进程生命周期管理

    private func terminateRenderer(pid: pid_t) {
        // SIGTERM sent to a SIGSTOP'ed renderer remains pending and its desktop
        // window stays visible. SIGCONT is harmless for a running process and makes
        // termination deterministic for auto-paused Scene wallpapers.
        kill(pid, SIGCONT)
        kill(pid, SIGTERM)
    }

    /// 只识别带 WaifuX wallpaper-control 文件的桌面 Scene 进程，避免误伤
    /// SceneOfflineBake/BakeService 启动的离线渲染任务。
    private nonisolated static func discoverDesktopRenderers() -> [DiscoveredDesktopRenderer] {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,command="]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        return output.split(separator: "\n").compactMap { line in
            let columns = line.split(
                maxSplits: 2,
                omittingEmptySubsequences: true,
                whereSeparator: { $0 == " " || $0 == "\t" }
            )
            guard columns.count == 3,
                  let pid = pid_t(columns[0]),
                  let parentPID = pid_t(columns[1]),
                  pid > 0 else {
                return nil
            }
            let command = String(columns[2])
            guard command.contains("/wallpaper-wgpu "),
                  command.contains(" --wallpaper-control "),
                  command.contains("waifux-wallpaper-wgpu-wallpaper-") else {
                return nil
            }
            return DiscoveredDesktopRenderer(
                pid: pid,
                parentPID: parentPID,
                command: command
            )
        }
    }

    private static func rendererControlMarker(for screenID: String) -> String {
        let safeID = screenID.map { ch -> Character in
            ch.isLetter || ch.isNumber || ch == "-" || ch == "_" ? ch : "_"
        }
        return "waifux-wallpaper-wgpu-wallpaper-\(String(safeID))-"
    }

    /// 清除不在当前 `screenProcesses` 登记中的桌面 renderer。先 SIGCONT 是为
    /// 了解除自动暂停留下的 SIGSTOP；孤儿没有任何状态需要保存，随后直接
    /// SIGKILL，确保它的窗口在新壁纸揭开前从 WindowServer 消失。
    @discardableResult
    private func terminateUntrackedDesktopRenderers(
        targetScreenIDs: Set<String>? = nil,
        reason: String
    ) -> [pid_t] {
        let managedPIDs = Set(screenProcesses.values.map(\.pid))
        let targetMarkers = targetScreenIDs.map { ids in
            ids.map(Self.rendererControlMarker(for:))
        }
        let candidates = Self.discoverDesktopRenderers().filter { renderer in
            guard !managedPIDs.contains(renderer.pid) else { return false }
            guard let targetMarkers else { return true }
            return targetMarkers.contains { renderer.command.contains($0) }
        }
        guard !candidates.isEmpty else { return [] }

        for renderer in candidates {
            kill(renderer.pid, SIGCONT)
            kill(renderer.pid, SIGTERM)
            if kill(renderer.pid, 0) == 0 {
                kill(renderer.pid, SIGKILL)
            }
        }
        let pids = candidates.map(\.pid)
        AppLogger.error(.wallpaper, "Reaped untracked wallpaper-wgpu desktop renderers", metadata: [
            "reason": reason,
            "pids": pids.map(String.init).joined(separator: ","),
            "parents": candidates.map { "\($0.pid):\($0.parentPID)" }.joined(separator: ","),
            "targets": targetScreenIDs?.sorted().joined(separator: ",") ?? "all"
        ])
        return pids
    }

    /// 终止 wallpaper-wgpu 渲染器启动的 afplay 子进程（音频播放）。
    ///
    /// 切换壁纸时，wallpaper-wgpu 收到 SIGTERM 后会通过 ctrlc handler 调用 `stop_all_owned()` 清理 afplay，
    /// 但 SIGTERM → handler → exit 需要时间；若 watchdog 在 handler 完成前发送 SIGKILL，
    /// afplay 会成为孤儿进程继续播放音频。
    /// 此方法在 SIGTERM 之前主动终止 afplay 子进程，确保音频立即停止。
    private func killAllAudioChildren(pid: pid_t) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        task.arguments = ["-f", "afplay.*wallpaper-wgpu-audio-\(pid)"]
        try? task.run()
        task.waitUntilExit()
    }

    /// 终止所有渲染进程
    private func stopRenderProcess(waitForExit: Bool = false) {
        // 先处理已堆积的终止事件，避免与新进程状态混淆
        processPendingTermination()

        screenChangeRestartWorkItem?.cancel()
        screenChangeRestartWorkItem = nil
        for (_, item) in screenWatchdogs { item.cancel() }
        screenWatchdogs.removeAll()
        activeRenderKind = activeRenderKind == .scene ? nil : activeRenderKind

        let processCount = screenProcesses.count
        guard !screenProcesses.isEmpty else {
            print("[WallpaperEngineXBridge] stopRenderProcess: 无活跃进程，跳过 (waitForExit=\(waitForExit))")
            return
        }
        print("[WallpaperEngineXBridge] stopRenderProcess: 终止 \(processCount) 个渲染进程 (waitForExit=\(waitForExit))")
        // 列出所有要终止的 PID
        let pidList = screenProcesses.values.map { "\($0.pid)(screen=\($0.screenID))" }.joined(separator: ", ")
        print("[WallpaperEngineXBridge] stopRenderProcess: 终止目标 pids=[\(pidList)]")

        // 终止所有屏幕进程（先清理 afplay 子进程，确保音频立即停止）
        for (_, info) in screenProcesses {
            killAllAudioChildren(pid: info.pid)
            terminateRenderer(pid: info.pid)
        }

        if waitForExit {
            let deadline = Date().addingTimeInterval(2.0)
            while !screenProcesses.isEmpty && Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
                processPendingTermination()
            }
            for (_, info) in screenProcesses where kill(info.pid, 0) == 0 {
                print("[WallpaperEngineXBridge] 退出前 renderer 未及时退出，发送 SIGKILL (pid=\(info.pid))")
                kill(info.pid, SIGKILL)
            }
            if !screenProcesses.isEmpty {
                let killDeadline = Date().addingTimeInterval(0.5)
                while !screenProcesses.isEmpty && Date() < killDeadline {
                    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
                    processPendingTermination()
                }
            }
        }

        // 设置 watchdog：2 秒后强制 SIGKILL
        if !waitForExit {
            let currentPIDs = screenProcesses.values.map(\.pid)
            for pid in currentPIDs {
                let watchdog = DispatchWorkItem {
                    if kill(pid, 0) == 0 {
                        print("[WallpaperEngineXBridge] 进程未响应 terminate，发送 SIGKILL (pid=\(pid))")
                        kill(pid, SIGKILL)
                    }
                }
                screenWatchdogs[pid] = watchdog
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: watchdog)
            }
        }

        closeRendererLogs()
        let removedCount = screenProcesses.count
        screenProcesses.removeAll()
        _deinitPIDs.removeAll()
        if activeRenderKind == .scene {
            activeRenderKind = nil
        }
        print("[WallpaperEngineXBridge] stopRenderProcess: 完成清理 (共移除 \(removedCount) 个进程记录)")
    }

    /// 启动新 renderer 前必须确认旧 renderer 已退出，避免“旧进程还在收尾，新进程又被启动”的闪烁和竞态。
    private func stopRenderProcessBeforeLaunch() async {
        processPendingTermination()

        screenChangeRestartWorkItem?.cancel()
        screenChangeRestartWorkItem = nil
        for (_, item) in screenWatchdogs { item.cancel() }
        screenWatchdogs.removeAll()

        let processCount = screenProcesses.count
        guard !screenProcesses.isEmpty else {
            print("[WallpaperEngineXBridge] stopRenderProcessBeforeLaunch: 无旧渲染进程，跳过")
            return
        }
        print("[WallpaperEngineXBridge] stopRenderProcessBeforeLaunch: 启动前清理 \(processCount) 个旧渲染进程")

        // 终止所有屏幕进程（先清理 afplay 子进程，确保音频立即停止）
        for (_, info) in screenProcesses {
            killAllAudioChildren(pid: info.pid)
            terminateRenderer(pid: info.pid)
        }

        let deadline = Date().addingTimeInterval(2.0)
        while !screenProcesses.isEmpty && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
            processPendingTermination()
        }

        // 强制 SIGKILL 剩余进程
        let remaining = screenProcesses
        for (_, info) in remaining where kill(info.pid, 0) == 0 {
            print("[WallpaperEngineXBridge] 旧 renderer 未及时退出，发送 SIGKILL (pid=\(info.pid))")
            kill(info.pid, SIGKILL)
        }
        let killDeadline = Date().addingTimeInterval(0.5)
        while screenProcesses.contains(where: { kill($0.value.pid, 0) == 0 }) && Date() < killDeadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
            processPendingTermination()
        }

        closeRendererLogs()
        screenProcesses.removeAll()
        _deinitPIDs.removeAll()
        processPendingTermination()
    }

    /// 停止指定屏幕的渲染进程（用于 per-screen 更新，不影响其他屏幕）
    private func stopScreenProcess(_ screenID: String) async {
        guard let info = screenProcesses[screenID] else {
            print("[WallpaperEngineXBridge] stopScreenProcess: 屏幕 \(screenID) 无活跃进程，跳过")
            return
        }
        print("[WallpaperEngineXBridge] stopScreenProcess: 停止屏幕 \(screenID) 渲染进程 (pid=\(info.pid))")

        screenWatchdogs[info.pid]?.cancel()
        screenWatchdogs.removeValue(forKey: info.pid)
        // 先终止 afplay 音频子进程（SIGTERM handler 可能来不及执行）
        killAllAudioChildren(pid: info.pid)
        terminateRenderer(pid: info.pid)

        let pid = info.pid
        let watchdog = DispatchWorkItem {
            if kill(pid, 0) == 0 {
                print("[WallpaperEngineXBridge] 目标屏旧 renderer 未及时退出，发送 SIGKILL (pid=\(pid))")
                kill(pid, SIGKILL)
            }
        }
        screenWatchdogs[pid] = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: watchdog)

        // 切换实时壁纸时不等待旧进程自然退出：当前屏幕的状态立即释放，新 renderer 立即启动。
        // 旧进程若还在收尾，由上面的 watchdog 兜底清理。
        removeScreenProcess(screenID)
        screenRenderStates.removeValue(forKey: screenID)
        _deinitPIDs.remove(pid)
        updateControlStateFromScreenStates()
        persistState()
        processPendingTermination()
    }

    /// 读取渲染器日志的最后 N 行，调试异常退出时输出
    private func tailRendererLog(screenID: String, maxLines: Int = 50, maxBytes: Int = 4096) -> String {
        guard let url = Self.rendererLogURL(screenID: screenID),
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return ""
        }
        let totalSize = data.count
        let readOffset = max(0, totalSize - maxBytes)
        let tailData = data.dropFirst(readOffset)
        guard let content = String(data: tailData, encoding: .utf8) else { return "" }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        let tailLines = lines.suffix(maxLines)
        return tailLines.joined(separator: "\n")
    }

    /// 消费线程安全的进程终止事件（@MainActor 方法，仅供其他 @MainActor 方法调用）
    private func processPendingTermination() {
        let events: [TerminationEvent] = {
            os_unfair_lock_lock(terminationLockPtr)
            defer { os_unfair_lock_unlock(terminationLockPtr) }
            let e = Array(pendingTerminations.values)
            pendingTerminations.removeAll()
            terminationPendingFlag = false
            return e
        }()

        for event in events {
            // 找到对应屏幕的进程，检查 generation 是否匹配
            guard let screenEntry = screenProcesses.first(where: { $0.value.pid == event.pid }) else {
                // 进程已不在 screenProcesses 中（已被 stopScreenProcess 清理），跳过
                _deinitPIDs.remove(event.pid)
                continue
            }
            let screenID = screenEntry.key
            try? screenEntry.value.logFile?.close()
            let expectedGen = screenEntry.value.generation
            guard event.generation == expectedGen else { continue }

            // 捕获并输出完整的退出原因
            let reasonDesc: String
            let isError: Bool
            switch event.reason {
            case .exit:
                if event.status == 0 {
                    reasonDesc = "正常退出 (exit code=0)"
                    isError = false
                } else {
                    reasonDesc = "异常退出 (exit code=\(event.status))"
                    isError = true
                }
            case .uncaughtSignal:
                let sigName = String(cString: Darwin.strsignal(Int32(event.status)))
                if event.status == SIGTERM {
                    reasonDesc = "被正常终止 (signal=SIGTERM/\(event.status): \(sigName))"
                    isError = false
                } else {
                    reasonDesc = "被异常信号终止 (signal=\(event.status): \(sigName))"
                    isError = true
                }
            @unknown default:
                reasonDesc = "未知终止原因 (reason=\(event.reason), status=\(event.status))"
                isError = true
            }

            let icon = isError ? "❌" : "✅"
            print("[WallpaperEngineXBridge] \(icon) wallpaper-wgpu 进程已退出 屏幕 \(screenID) (pid=\(event.pid), 退出原因: \(reasonDesc))")
            if isError {
                AppLogger.error(.wallpaper, "wallpaper-wgpu 进程异常退出", metadata: ["screenID": screenID, "pid": event.pid, "reason": reasonDesc])
            }

            // 异常退出时回读渲染器日志尾部内容，输出到主日志方便排障
            if isError {
                let tail = tailRendererLog(screenID: screenID)
                if !tail.isEmpty {
                    print("[WallpaperEngineXBridge] ════ wallpaper-wgpu 渲染器日志 (尾部) ════")
                    for line in tail.split(separator: "\n") {
                        print("[WallpaperEngineXBridge]   | \(line)")
                    }
                    print("[WallpaperEngineXBridge] ════ 日志结束 ════")
                } else {
                    print("[WallpaperEngineXBridge] ⚠️ wallpaper-wgpu 渲染器日志为空或无法读取")
                }
            }

            removeScreenProcess(screenID)
            screenRenderStates.removeValue(forKey: screenID)
            _deinitPIDs.remove(event.pid)
        }

        if !events.isEmpty {
            updateControlStateFromScreenStates()
            // ⚠️ 此处不调用 persistState()：终止事件的消费不应擦除 preserveRestoreState
            // 刚刚保存的恢复状态（否则关闭后重新开启时，clearPersistedState 会清空 UserDefaults
            // 中的 restore 数据，导致实时壁纸无法恢复）。所有调用方都已自行处理持久化。
        }
    }

    // MARK: - 状态恢复

    func restoreIfNeeded() async {
        // 已在控制中（上一个 restore 已完成），跳过避免重复启动
        guard !isControllingExternalEngine else {
            print("[WallpaperEngineXBridge] restoreIfNeeded: 已处于控制状态，跳过")
            return
        }

        if let restoredStates = persistedScreenRenderStates(), !restoredStates.isEmpty {
            for state in restoredStates {
                guard FileManager.default.fileExists(atPath: state.path) else {
                    print("[WallpaperEngineXBridge] 持久化的壁纸路径已不存在，跳过恢复: \(state.path)")
                    continue
                }
                guard let screen = screenForPersistedState(state) else {
                    print("[WallpaperEngineXBridge] 未找到持久化目标显示器，跳过恢复: \(state.screenID)")
                    continue
                }
                let userProps = state.userProperties ?? SceneWallpaperPropertiesService.propertiesOverrideJSON(for: state.path)
                try? await setWallpaper(path: state.path, targetScreens: [screen], userProperties: userProps)
            }
            if screenRenderStates.isEmpty {
                clearPersistedState()
            }
            return
        }

        if let path = UserDefaults.standard.string(forKey: lastWallpaperPathKey) {
            lastWallpaperPath = path
        }
        targetScreenIDs = Set(UserDefaults.standard.stringArray(forKey: targetScreenIDsKey) ?? [])
        targetScreenFingerprints = Set(UserDefaults.standard.stringArray(forKey: targetScreenFingerprintsKey) ?? [])

        guard UserDefaults.standard.bool(forKey: controllingExternalKey) else { return }
        guard let path = lastWallpaperPath else { return }

        // ✅ 检查路径是否存在，不存在则清除持久化状态，避免启动已失效的渲染器
        guard FileManager.default.fileExists(atPath: path) else {
            print("[WallpaperEngineXBridge] 持久化的壁纸路径已不存在，清除状态: \(path)")
            clearPersistedState()
            lastWallpaperPath = nil
            targetScreenIDs.removeAll()
            targetScreenFingerprints.removeAll()
            return
        }

        let hasPersistedTargets = !targetScreenIDs.isEmpty || !targetScreenFingerprints.isEmpty
        let screens = hasPersistedTargets ? activeTargetScreens() : []
        // 恢复用户属性覆盖
        let userProps = SceneWallpaperPropertiesService.propertiesOverrideJSON(for: path)
        try? await setWallpaper(path: path, targetScreens: hasPersistedTargets && !screens.isEmpty ? screens : nil, userProperties: userProps)
    }

    // MARK: - 持久化

    private func recordRenderState(path: String, renderKind: RenderKind, screens: [NSScreen], userProperties: String?) {
        for screen in screens {
            let screenID = screen.wallpaperScreenIdentifier
            screenRenderStates[screenID] = ScreenRenderState(
                screenID: screenID,
                screenFingerprint: screen.wallpaperScreenFingerprint,
                path: path,
                renderKind: renderKind,
                userProperties: userProperties,
                cliScreenIndex: renderKind == .web ? Self.legacyCLIScreenIndex(for: screen) : nil
            )
        }
        updateControlStateFromScreenStates(preferredPath: path, preferredKind: renderKind)
        persistState()
    }

    private func renderState(for screen: NSScreen) -> ScreenRenderState? {
        screenRenderStates[screen.wallpaperScreenIdentifier]
            ?? screenRenderStates.values.first { $0.screenFingerprint == screen.wallpaperScreenFingerprint }
    }

    private func preserveRestoreState(_ states: [ScreenRenderState]) {
        guard !states.isEmpty else { return }
        if let data = try? JSONEncoder().encode(states) {
            UserDefaults.standard.set(data, forKey: screenRenderStatesKey)
        }
        if let path = states.first?.path {
            UserDefaults.standard.set(path, forKey: lastWallpaperPathKey)
        }
        UserDefaults.standard.set(true, forKey: controllingExternalKey)
        UserDefaults.standard.set(Array(states.map(\.screenID)), forKey: targetScreenIDsKey)
        UserDefaults.standard.set(Array(states.map(\.screenFingerprint)), forKey: targetScreenFingerprintsKey)
    }

    private func createAudioControlURL(screenID: String) -> URL {
        let safeID = screenID.map { ch -> Character in
            ch.isLetter || ch.isNumber || ch == "-" || ch == "_" ? ch : "_"
        }
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("waifux-wallpaper-wgpu-audio-\(String(safeID))-\(UUID().uuidString).json")
    }

    private func createCropControlURL(screenID: String) -> URL {
        let safeID = screenID.map { ch -> Character in
            ch.isLetter || ch.isNumber || ch == "-" || ch == "_" ? ch : "_"
        }
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("waifux-wallpaper-wgpu-crop-\(String(safeID))-\(UUID().uuidString).json")
    }

    private func createCanvasSizeURL(screenID: String) -> URL {
        let safeID = screenID.map { ch -> Character in
            ch.isLetter || ch.isNumber || ch == "-" || ch == "_" ? ch : "_"
        }
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("waifux-wallpaper-wgpu-canvas-size-\(String(safeID))-\(UUID().uuidString).json")
    }

    private func createWallpaperControlURL(screenID: String) -> URL {
        let safeID = screenID.map { ch -> Character in
            ch.isLetter || ch.isNumber || ch == "-" || ch == "_" ? ch : "_"
        }
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("waifux-wallpaper-wgpu-wallpaper-\(String(safeID))-\(UUID().uuidString).json")
    }

    /// 热切换前删除上一张场景写出的 canvas 尺寸，避免被误用作新场景的裁切依据。
    private func invalidateCanvasSizeFile(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            print("[WallpaperEngineXBridge] ⚠️ 清除旧 canvas_size 文件失败: \(error.localizedDescription)")
        }
    }

    /// 读取 wgpu 写出的 canvas 尺寸 JSON。读不到/解析失败返回 nil（调用方 fallback 屏尺寸）。
    private func readCanvasSize(url: URL?) -> CGSize? {
        guard let url = url else { return nil }
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let w = obj["width"] as? Double, let h = obj["height"] as? Double,
              w > 0, h > 0 else { return nil }
        return CGSize(width: w, height: h)
    }

    /// 供 overlay 预览取 wgpu canvas 尺寸（scene 就绪后才有值；未就绪时用 scene.json 画布）。
    func canvasSize(for screen: NSScreen) -> CGSize? {
        let screenID = screen.wallpaperScreenIdentifier
        let info = screenProcesses[screenID]
            ?? screenProcesses.values.first(where: { $0.screenID == screenID })
        return cropWallpaperSize(
            screen: screen,
            path: renderState(for: screen)?.path,
            canvasSizeURL: info?.canvasSizeURL,
            allowCachedCanvas: true
        )
    }

    /// 铺满裁切用的壁纸尺寸：真实画布 > scene ortho / Web 内容 > 缓存。
    private func cropWallpaperSize(
        screen: NSScreen,
        path: String?,
        canvasSizeURL: URL?,
        allowCachedCanvas: Bool
    ) -> CGSize? {
        if let size = readCanvasSize(url: canvasSizeURL) {
            return size
        }
        if let path, let size = sceneCanvasSize(forPath: path) {
            return size
        }
        if let size = webContentSize(for: screen) {
            return size
        }
        if allowCachedCanvas {
            return lastCanvasSizeByScreenID[screen.wallpaperScreenIdentifier]
        }
        return nil
    }

    private func sceneCanvasSize(forPath path: String) -> CGSize? {
        if let cached = sceneCanvasSizeCache[path] { return cached }
        let size = SceneConfigOverrideService.sceneOrthogonalSize(for: path)
        sceneCanvasSizeCache[path] = size
        return size
    }

    private func writeAudioControl(url: URL, muted: Bool, paused: Bool, volume: Double) {
        let state = RendererAudioControlState(
            muted: muted,
            paused: paused,
            volume: max(0, min(1, volume))
        )
        do {
            let data = try JSONEncoder().encode(state)
            try data.write(to: url, options: .atomic)
        } catch {
            print("[WallpaperEngineXBridge] ⚠️ 写入音频控制文件失败: \(error.localizedDescription)")
        }
    }

    /// 把屏幕的最新裁切参数写入 `--crop-control` JSON 文件；wgpu 端 50ms 内拉取生效。
    /// crop=nil 表示移除裁切（即全图）；viewport=nil/全屏 = 无 letterbox。
    private func writeCropControl(url: URL, crop: UnitRect?, viewport: UnitRect?) {
        let cropArr: [Float]? = crop.map { [Float($0.x), Float($0.y), Float($0.w), Float($0.h)] }
        let vpArr: [Float]? = viewport.map { [Float($0.x), Float($0.y), Float($0.w), Float($0.h)] }
        let state = RendererCropControlState(crop: cropArr, viewport: vpArr)
        do {
            let data = try JSONEncoder().encode(state)
            try data.write(to: url, options: .atomic)
        } catch {
            print("[WallpaperEngineXBridge] ⚠️ 写入裁切控制文件失败: \(error.localizedDescription)")
        }
    }

    /// 写入 `--wallpaper-control` JSON 文件，通知 wallpaper-wgpu 热切换壁纸或更新属性。
    /// setWallpaper=nil 时不切换壁纸，只更新属性。assets=nil 时 wgpu 自动 fallback。
    @discardableResult
    private func writeWallpaperControl(
        url: URL,
        setWallpaper: String?,
        assets: String?,
        setProperties: String?,
        upscaling: Bool? = nil,
        upscalingPercent: Int? = nil,
        effectReduction: Bool? = nil,
        presentationAlpha: Double? = nil
    ) -> Bool {
        var dict: [String: Any] = [:]
        if let sw = setWallpaper {
            dict["setWallpaper"] = sw
        }
        if let a = assets {
            dict["assets"] = a
        }
        if let sp = setProperties, !sp.isEmpty,
           let data = sp.data(using: .utf8),
           let props = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            dict["setProperties"] = props
        }
        // 超分辨率 / 性能模式参数
        if let upscaling = upscaling {
            dict["upscaling"] = upscaling
        }
        if let upscalingPercent = upscalingPercent {
            dict["upscaling_percent"] = upscalingPercent
        }
        if let effectReduction = effectReduction {
            dict["effect_reduction"] = effectReduction
        }
        if let presentationAlpha = presentationAlpha {
            dict["presentationAlpha"] = max(0, min(1, presentationAlpha))
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: dict, options: [])
            try data.write(to: url, options: .atomic)
            let desc: String
            if setWallpaper != nil {
                desc = "切换壁纸"
            } else if upscaling != nil || effectReduction != nil {
                desc = "更新渲染设置"
            } else {
                desc = "仅更新属性"
            }
            print("[WallpaperEngineXBridge] 已写入壁纸控制文件: \(desc)")
            return true
        } catch {
            print("[WallpaperEngineXBridge] ⚠️ 写入壁纸控制文件失败: \(error.localizedDescription)")
            return false
        }
    }

    private func updateRendererAudioControls(
        muted: Bool? = nil,
        paused: Bool? = nil,
        volume: Double? = nil,
        targetScreen: NSScreen? = nil
    ) {
        let mutedValue = muted ?? VideoWallpaperManager.shared.isMuted
        let pausedValue = paused ?? isExternalPaused

        if let targetScreen {
            let screenID = targetScreen.wallpaperScreenIdentifier
            guard let info = screenProcesses[screenID] ?? screenProcesses.values.first(where: { $0.screenID == screenID }) else { return }
            guard let audioControlURL = info.audioControlURL else { return }
            writeAudioControl(
                url: audioControlURL,
                muted: mutedValue,
                paused: pausedValue,
                volume: volume ?? VideoWallpaperManager.shared.volume(for: targetScreen)
            )
            return
        }

        for info in screenProcesses.values {
            guard let audioControlURL = info.audioControlURL else { continue }
            let screen = NSScreen.screens.first { $0.wallpaperScreenIdentifier == info.screenID }
            let screenVolume = volume ?? screen.map { VideoWallpaperManager.shared.volume(for: $0) } ?? 1.0
            writeAudioControl(
                url: audioControlURL,
                muted: mutedValue,
                paused: pausedValue,
                volume: screenVolume
            )
        }
    }

    private func removeRenderState(for screen: NSScreen) {
        let screenID = screen.wallpaperScreenIdentifier
        let state = renderState(for: screen)
        if let state {
            screenRenderStates.removeValue(forKey: state.screenID)
        } else {
            screenRenderStates.removeValue(forKey: screenID)
        }
    }

    /// Stop a renderer that has been detached from `screenProcesses` while its
    /// replacement was warming up behind it.
    private func stopDetachedRenderer(_ preserved: PreservedRenderer) async {
        let info = preserved.info
        screenWatchdogs[info.pid]?.cancel()
        screenWatchdogs.removeValue(forKey: info.pid)
        killAllAudioChildren(pid: info.pid)
        terminateRenderer(pid: info.pid)

        let gracefulDeadline = Date().addingTimeInterval(0.45)
        while kill(info.pid, 0) == 0 && Date() < gracefulDeadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        if kill(info.pid, 0) == 0 {
            kill(info.pid, SIGKILL)
            let killDeadline = Date().addingTimeInterval(0.30)
            while kill(info.pid, 0) == 0 && Date() < killDeadline {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }

        cleanupRendererResources(info)
        _deinitPIDs.remove(info.pid)
    }

    /// Remove the replacement and put the still-visible old renderer back into
    /// the live dictionaries. Used when the replacement never becomes ready.
    private func discardPreparedRenderersPreservingOld(
        _ preservedRenderers: [String: PreservedRenderer]
    ) async {
        for (screenID, preserved) in preservedRenderers {
            guard let current = screenProcesses[screenID],
                  current.pid != preserved.info.pid else {
                continue
            }
            await stopScreenProcess(screenID)
        }

        for (screenID, preserved) in preservedRenderers {
            screenProcesses[screenID] = preserved.info
            if let state = preserved.state {
                screenRenderStates[screenID] = state
            }
            let screen = NSScreen.screens.first {
                $0.wallpaperScreenIdentifier == screenID
            }
            if let audioControlURL = preserved.info.audioControlURL {
                writeAudioControl(
                    url: audioControlURL,
                    muted: VideoWallpaperManager.shared.isMuted,
                    paused: isExternalPaused,
                    volume: screen.map { VideoWallpaperManager.shared.volume(for: $0) } ?? 1.0
                )
            }
            _deinitPIDs.insert(preserved.info.pid)
        }
        updateControlStateFromScreenStates()
        persistState()
    }

    /// The new renderer is ready and ordered behind the old one. Stop the old
    /// process only now so WindowServer can reveal the prepared replacement
    /// without exposing a black desktop frame.
    private func commitPreparedRenderersReplacingOld(
        _ preservedRenderers: [String: PreservedRenderer]
    ) async {
        // Trigger the old renderer's in-process alpha animation. Older
        // wallpaper-wgpu binaries ignore this unknown control field and still
        // fall back to the same no-black-frame handoff.
        for preserved in preservedRenderers.values {
            if let controlURL = preserved.info.wallpaperControlURL {
                _ = writeWallpaperControl(
                    url: controlURL,
                    setWallpaper: nil,
                    assets: nil,
                    setProperties: nil,
                    presentationAlpha: 0.001
                )
            }
        }
        try? await Task.sleep(nanoseconds: 380_000_000)
        for preserved in preservedRenderers.values {
            await stopDetachedRenderer(preserved)
        }
    }

    private func cleanupRendererResources(_ info: ScreenProcessInfo) {
        try? info.logFile?.close()
        if let audioControlURL = info.audioControlURL {
            try? FileManager.default.removeItem(at: audioControlURL)
        }
        if let cropControlURL = info.cropControlURL {
            try? FileManager.default.removeItem(at: cropControlURL)
        }
        if let canvasSizeURL = info.canvasSizeURL {
            try? FileManager.default.removeItem(at: canvasSizeURL)
        }
        if let wallpaperControlURL = info.wallpaperControlURL {
            try? FileManager.default.removeItem(at: wallpaperControlURL)
        }
    }

    private static func legacyCLIScreenIndex(for screen: NSScreen) -> Int? {
        // 与 wallpaperengine-cli daemon 使用同一套稳定顺序，避免系统枚举打乱后
        // App 与 daemon 的 screen 索引指向不同物理显示器。
        WallpaperScreenIdentity.stableIndex(of: screen)
    }

    private func removeScreenProcess(_ screenID: String) {
        if let info = screenProcesses.removeValue(forKey: screenID) {
            cleanupRendererResources(info)
        }
    }

    private func closeRendererLogs() {
        for info in screenProcesses.values {
            try? info.logFile?.close()
            if let audioControlURL = info.audioControlURL {
                try? FileManager.default.removeItem(at: audioControlURL)
            }
            if let cropControlURL = info.cropControlURL {
                try? FileManager.default.removeItem(at: cropControlURL)
            }
            if let canvasSizeURL = info.canvasSizeURL {
                try? FileManager.default.removeItem(at: canvasSizeURL)
            }
        }
    }

    private func updateControlStateFromScreenStates(preferredPath: String? = nil, preferredKind: RenderKind? = nil) {
        let onlineScreens = NSScreen.screens
        let onlineIDs = Set(onlineScreens.map(\.wallpaperScreenIdentifier))
        let onlineFingerprints = Set(onlineScreens.map(\.wallpaperScreenFingerprint))

        // 断屏后仍可能保留 orphan render state 供重插恢复；
        // 控制标志与 target ID 只看当前在线屏 + 存活进程。
        let onlineStates = screenRenderStates.values.filter { state in
            onlineIDs.contains(state.screenID) || onlineFingerprints.contains(state.screenFingerprint)
        }
        targetScreenIDs = Set(onlineStates.map(\.screenID)).union(Set(screenProcesses.keys))
        targetScreenFingerprints = Set(screenRenderStates.values.map(\.screenFingerprint))
        isControllingExternalEngine = !onlineStates.isEmpty || !screenProcesses.isEmpty

        if let preferredPath {
            lastWallpaperPath = preferredPath
        } else {
            lastWallpaperPath = onlineStates.first?.path
                ?? screenRenderStates.values.first?.path
        }
        if let preferredKind {
            activeRenderKind = preferredKind
        } else {
            activeRenderKind = onlineStates.first?.renderKind
                ?? screenRenderStates.values.first?.renderKind
        }
        if !isControllingExternalEngine {
            isExternalPaused = false
            if screenRenderStates.isEmpty {
                activeRenderKind = nil
                lastAppliedScreenConfigurations.removeAll()
            } else {
                // 仅剩断屏恢复态：清几何签名，避免误用旧多屏配置
                lastAppliedScreenConfigurations = currentTargetScreenConfigurations()
            }
        } else {
            lastAppliedScreenConfigurations = currentTargetScreenConfigurations()
        }
    }

    private func persistedScreenRenderStates() -> [ScreenRenderState]? {
        guard let data = UserDefaults.standard.data(forKey: screenRenderStatesKey),
              let states = try? JSONDecoder().decode([ScreenRenderState].self, from: data) else {
            return nil
        }
        return states
    }

    private func screenForPersistedState(_ state: ScreenRenderState) -> NSScreen? {
        NSScreen.screens.first { $0.wallpaperScreenIdentifier == state.screenID }
            ?? NSScreen.screens.first { $0.wallpaperScreenFingerprint == state.screenFingerprint }
    }

    private func persistState() {
        if !screenRenderStates.isEmpty {
            if let data = try? JSONEncoder().encode(Array(screenRenderStates.values)) {
                UserDefaults.standard.set(data, forKey: screenRenderStatesKey)
            }
            if let path = lastWallpaperPath ?? screenRenderStates.values.first?.path {
                UserDefaults.standard.set(path, forKey: lastWallpaperPathKey)
            }
            UserDefaults.standard.set(true, forKey: controllingExternalKey)
            UserDefaults.standard.set(Array(targetScreenIDs), forKey: targetScreenIDsKey)
            UserDefaults.standard.set(Array(targetScreenFingerprints), forKey: targetScreenFingerprintsKey)
        } else if let path = lastWallpaperPath, isControllingExternalEngine {
            UserDefaults.standard.set(path, forKey: lastWallpaperPathKey)
            UserDefaults.standard.set(isControllingExternalEngine, forKey: controllingExternalKey)
            UserDefaults.standard.set(Array(targetScreenIDs), forKey: targetScreenIDsKey)
            UserDefaults.standard.set(Array(targetScreenFingerprints), forKey: targetScreenFingerprintsKey)
        } else {
            clearPersistedState()
        }
    }

    private func clearPersistedState() {
        UserDefaults.standard.removeObject(forKey: lastWallpaperPathKey)
        UserDefaults.standard.removeObject(forKey: controllingExternalKey)
        UserDefaults.standard.removeObject(forKey: targetScreenIDsKey)
        UserDefaults.standard.removeObject(forKey: targetScreenFingerprintsKey)
        UserDefaults.standard.removeObject(forKey: screenRenderStatesKey)
    }

    /// 检查 wallpaper-wgpu 是否正在管理指定屏幕
    func isManaging(screen: NSScreen) -> Bool {
        screenRenderStates[screen.wallpaperScreenIdentifier] != nil ||
        screenRenderStates.values.contains { $0.screenFingerprint == screen.wallpaperScreenFingerprint } ||
        targetScreenIDs.contains(screen.wallpaperScreenIdentifier) ||
        targetScreenFingerprints.contains(screen.wallpaperScreenFingerprint)
    }

    /// 过渡预热只应保留当前真正可见的 renderer，不能把用于重启恢复的持久化
    /// target/render state 当作活跃窗口。Scene 进程退出后状态可能短暂滞留；若仍
    /// 按跨类型处理，新视频的黑色预热窗会直接暴露在桌面上，看起来像长黑场。
    func hasLivePresentation(on screen: NSScreen) -> Bool {
        processPendingTermination()
        let state = renderState(for: screen)
        if state?.renderKind == .web {
            return isControllingExternalEngine
                && activeRenderKind == .web
                && Self.isLegacyDaemonRunning
        }

        let screenID = screen.wallpaperScreenIdentifier
        let processInfo = screenProcesses[screenID]
            ?? state.flatMap { screenProcesses[$0.screenID] }
            ?? screenProcesses.values.first(where: { $0.screenID == screenID })
            ?? screenProcesses.values.first(where: {
                $0.screenID == state?.screenID
            })
        guard let processInfo else { return false }
        // SIGSTOP'd Scene processes still own a desktop window. `isRunning`
        // can briefly lie after a stop/restart race; the pid check is enough.
        return kill(processInfo.pid, 0) == 0
    }

    /// Web 的管理状态会持久化用于启动恢复，不能单靠它判断桌面上是否仍有窗口。
    /// daemon PID 不存在时应按“无旧 renderer”处理，否则新视频会误走跨类型预热，
    /// 将尚未提交的黑色窗口直接留在桌面上。
    private static var isLegacyDaemonRunning: Bool {
        let pidPath = "/tmp/wallpaperengine-cli.pid"
        guard let pidText = try? String(contentsOfFile: pidPath, encoding: .utf8),
              let pid = pid_t(pidText.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0 else { return false }
        return kill(pid, 0) == 0
    }

    /// 该屏的外部引擎是否为 web 壁纸（web 暂不支持可视区域调节）。
    func isWebWallpaperOn(screen: NSScreen) -> Bool {
        guard isManaging(screen: screen) else { return false }
        let id = screen.wallpaperScreenIdentifier
        if let state = screenRenderStates[id], state.renderKind == .web { return true }
        if let state = screenRenderStates.values.first(where: { $0.screenFingerprint == screen.wallpaperScreenFingerprint }),
           state.renderKind == .web { return true }
        return false
    }

    /// 检查一组屏幕 ID 中是否有被外部引擎管理的屏幕
    func shouldPauseForFullscreenCoveredScreenIDs(_ coveredIDs: Set<String>) -> Bool {
        !coveredIDs.isDisjoint(with: targetScreenIDs)
    }

    /// 批量更新持久化状态中的壁纸路径（目录迁移后调用）
    func bulkUpdatePaths(oldPrefix: String, newPrefix: String) {
        if var states = persistedScreenRenderStates(), !states.isEmpty {
            var changed = false
            states = states.map { state in
                guard state.path.hasPrefix(oldPrefix) else { return state }
                changed = true
                return ScreenRenderState(
                    screenID: state.screenID,
                    screenFingerprint: state.screenFingerprint,
                    path: newPrefix + String(state.path.dropFirst(oldPrefix.count)),
                    renderKind: state.renderKind,
                    userProperties: state.userProperties,
                    cliScreenIndex: state.cliScreenIndex
                )
            }
            if changed, let data = try? JSONEncoder().encode(states) {
                UserDefaults.standard.set(data, forKey: screenRenderStatesKey)
            }
        }
        guard let path = UserDefaults.standard.string(forKey: lastWallpaperPathKey) else { return }
        if path.hasPrefix(oldPrefix) {
            let newPath = newPrefix + String(path.dropFirst(oldPrefix.count))
            UserDefaults.standard.set(newPath, forKey: lastWallpaperPathKey)
            lastWallpaperPath = newPath
            print("[WallpaperEngineXBridge] Updated persisted path from \(oldPrefix) to \(newPrefix)")
        }
    }


    /// 检查是否有可恢复的持久化实时渲染壁纸状态
    func hasPersistedRestoreState() -> Bool {
        if let data = UserDefaults.standard.data(forKey: screenRenderStatesKey),
           let states = try? JSONDecoder().decode([ScreenRenderState].self, from: data),
           !states.isEmpty {
            return true
        }
        return UserDefaults.standard.bool(forKey: controllingExternalKey)
            && UserDefaults.standard.string(forKey: lastWallpaperPathKey) != nil
    }

    func hasPersistedRestoreState(for screen: NSScreen) -> Bool {
        let screenID = screen.wallpaperScreenIdentifier
        let fingerprint = screen.wallpaperScreenFingerprint
        if let data = UserDefaults.standard.data(forKey: screenRenderStatesKey),
           let states = try? JSONDecoder().decode([ScreenRenderState].self, from: data),
           states.contains(where: { $0.screenID == screenID || $0.screenFingerprint == fingerprint }) {
            return true
        }

        guard UserDefaults.standard.bool(forKey: controllingExternalKey),
              UserDefaults.standard.string(forKey: lastWallpaperPathKey) != nil else {
            return false
        }
        let targetIDs = Set(UserDefaults.standard.stringArray(forKey: targetScreenIDsKey) ?? [])
        let targetFingerprints = Set(UserDefaults.standard.stringArray(forKey: targetScreenFingerprintsKey) ?? [])
        return targetIDs.contains(screenID) || targetFingerprints.contains(fingerprint)
    }

    func restorePreviousWallpaperIfAvailable(for screen: NSScreen) async -> Bool {
        guard hasPersistedRestoreState(for: screen) || isManaging(screen: screen) else {
            return false
        }

        let screenID = screen.wallpaperScreenIdentifier
        let fingerprint = screen.wallpaperScreenFingerprint

        // 断线清理会停掉运行时但保留 restore state；重插时必须真正重新 setWallpaper，
        // 不能仅因 isManaging（state 仍在）就当作已恢复。
        let existingState = screenRenderStates[screenID]
            ?? screenRenderStates.values.first { $0.screenFingerprint == fingerprint }
            ?? persistedScreenRenderStates()?.first {
                $0.screenID == screenID || $0.screenFingerprint == fingerprint
            }

        if let state = existingState, FileManager.default.fileExists(atPath: state.path) {
            let hasLiveRuntime: Bool = {
                if state.renderKind == .scene {
                    return screenProcesses[screenID] != nil
                        || screenProcesses.values.contains { $0.screenID == screenID }
                }
                // web：无独立进程字典，以 render state + 控制标志近似；重插一律重新 set 更稳妥
                return false
            }()

            if !hasLiveRuntime {
                let userProps = state.userProperties
                    ?? SceneWallpaperPropertiesService.propertiesOverrideJSON(for: state.path)
                do {
                    try await setWallpaper(
                        path: state.path,
                        targetScreens: [screen],
                        userProperties: userProps,
                        forceRestart: true
                    )
                    print("[WallpaperEngineXBridge] Restored previous live wallpaper for reconnected display: \(screen.localizedName)")
                    return isManaging(screen: screen)
                } catch {
                    print("[WallpaperEngineXBridge] ⚠️ 重插恢复失败 \(screen.localizedName): \(error.localizedDescription)")
                    return false
                }
            }
            return true
        }

        if !isManaging(screen: screen) {
            await restoreIfNeeded()
        }
        let restored = isManaging(screen: screen)
        if restored {
            print("[WallpaperEngineXBridge] Restored previous live wallpaper for reconnected display: \(screen.localizedName)")
        }
        return restored
    }

    /// Forget a disconnected display while leaving every other Scene/Web render
    /// and the shared Web daemon intact. Stopping the daemon here would blank
    /// unrelated Web wallpaper screens.
    ///
    /// 仅在调用方明确要求“忘掉”该屏（例如用户选择不用壁纸）时使用。
    /// 显示器热拔插的运行时回收请走 `cleanupOrphanedScreenRuntimes`，
    /// 以便保留 fingerprint 状态供重插恢复。
    func discardPersistedWallpaperState(screenID: String, fingerprint: String) async {
        // 先停掉该屏的运行时（scene 进程 / web daemon），再清持久化
        await stopRuntimeForDisconnectedScreen(screenID: screenID, fingerprint: fingerprint, preferredCLIIndex: nil)

        screenRenderStates = screenRenderStates.filter {
            $0.value.screenID != screenID && $0.value.screenFingerprint != fingerprint
        }
        targetScreenIDs.remove(screenID)
        targetScreenFingerprints.remove(fingerprint)
        perScreenPausedScreenIDs.remove(screenID)
        updateControlStateFromScreenStates()
        ensureAudioRelayMatchesActiveWallpaper()
        persistState()
    }

    /// 显示器断开后：停掉已不在 `NSScreen.screens` 上的 scene/web 运行时。
    /// 持久化 `screenRenderStates` 按 fingerprint 保留，便于重插后 restore。
    /// 不得 stop 整 daemon，避免误伤其它仍在线屏上的 web 壁纸。
    @discardableResult
    private func cleanupOrphanedScreenRuntimes() async -> Bool {
        let currentScreenIDs = Set(NSScreen.screens.map(\.wallpaperScreenIdentifier))
        let currentFingerprints = Set(NSScreen.screens.map(\.wallpaperScreenFingerprint))

        var orphanStates: [ScreenRenderState] = []
        var seenKeys = Set<String>()
        for state in screenRenderStates.values {
            let stillOnline = currentScreenIDs.contains(state.screenID)
                || currentFingerprints.contains(state.screenFingerprint)
            guard !stillOnline else { continue }
            let key = "\(state.screenID)|\(state.screenFingerprint)"
            guard seenKeys.insert(key).inserted else { continue }
            orphanStates.append(state)
        }

        // 进程字典里也可能残留已断屏的 scene 进程（state 已丢但进程还在）
        let orphanProcessIDs = screenProcesses.keys.filter { !currentScreenIDs.contains($0) }

        guard !orphanStates.isEmpty || !orphanProcessIDs.isEmpty else { return false }

        AppLogger.error(.wallpaper, "WallpaperEngineX cleaning orphaned screen runtimes", metadata: [
            "orphanStates": orphanStates.map { "\($0.screenID):\($0.renderKind.rawValue)" }.joined(separator: ","),
            "orphanProcesses": orphanProcessIDs.sorted().joined(separator: ","),
            "currentScreens": currentScreenIDs.sorted().joined(separator: ",")
        ])

        for state in orphanStates {
            await stopRuntimeForDisconnectedScreen(
                screenID: state.screenID,
                fingerprint: state.screenFingerprint,
                preferredCLIIndex: state.cliScreenIndex
            )
            perScreenPausedScreenIDs.remove(state.screenID)
        }

        for screenID in orphanProcessIDs where screenProcesses[screenID] != nil {
            await stopScreenProcessKeepingRestoreState(screenID)
            perScreenPausedScreenIDs.remove(screenID)
        }

        // 目标 ID 集合去掉已不在线的 screenID（fingerprint 保留供重插）
        targetScreenIDs = targetScreenIDs.intersection(currentScreenIDs)
        // 仅用仍在线屏 + 保留的 orphan 持久化 state 刷新控制标志
        updateControlStateFromScreenStates()
        ensureAudioRelayMatchesActiveWallpaper()
        // 注意：不 persist 删除 orphan state；persist 只同步当前控制标志与仍在线映射
        persistStateKeepingDisconnectedRestoreStates()
        return true
    }

    /// 停掉已断开屏的 scene 进程或 web 渲染，保留 `screenRenderStates` 供恢复。
    private func stopRuntimeForDisconnectedScreen(
        screenID: String,
        fingerprint: String,
        preferredCLIIndex: Int?
    ) async {
        // scene: wallpaper-wgpu 每屏独立进程
        if screenProcesses[screenID] != nil {
            await stopScreenProcessKeepingRestoreState(screenID)
        } else if let matched = screenProcesses.first(where: { entry in
            entry.value.screenID == screenID
                || screenRenderStates[entry.key]?.screenFingerprint == fingerprint
        }) {
            await stopScreenProcessKeepingRestoreState(matched.key)
        }

        // web: 通过 daemon 按屏 stop；断线后 NSScreen 已不在，优先用记录的 cliScreenIndex
        let wasWeb = screenRenderStates[screenID]?.renderKind == .web
            || screenRenderStates.values.contains {
                $0.screenFingerprint == fingerprint && $0.renderKind == .web
            }
            || (activeRenderKind == .web && (
                targetScreenIDs.contains(screenID) || targetScreenFingerprints.contains(fingerprint)
            ))

        if wasWeb {
            let indices = resolvedCLIScreenIndicesForDisconnectedScreen(
                screenID: screenID,
                fingerprint: fingerprint,
                preferredCLIIndex: preferredCLIIndex
            )
            for index in indices {
                do {
                    let status = try await Self.runLegacyCLIClientCommand(["stop-screen", String(index)])
                    if status != 0 {
                        print("[WallpaperEngineXBridge] ⚠️ 断屏 stop-screen 失败 screen=\(index) exit=\(status)")
                    } else {
                        print("[WallpaperEngineXBridge] ✅ 断屏已 stop-screen index=\(index) (screenID=\(screenID))")
                    }
                } catch {
                    print("[WallpaperEngineXBridge] ⚠️ 断屏 stop-screen 异常 index=\(index): \(error.localizedDescription)")
                }
            }
        }
    }

    /// 断线后无法再通过 NSScreen 映射索引；综合持久化记录与进程字典推断 cli index。
    private func resolvedCLIScreenIndicesForDisconnectedScreen(
        screenID: String,
        fingerprint: String,
        preferredCLIIndex: Int?
    ) -> [Int] {
        var indices: [Int] = []
        if let preferredCLIIndex, preferredCLIIndex >= 0 {
            indices.append(preferredCLIIndex)
        }
        if let stored = screenRenderStates[screenID]?.cliScreenIndex, stored >= 0 {
            indices.append(stored)
        }
        for state in screenRenderStates.values where state.screenFingerprint == fingerprint {
            if let idx = state.cliScreenIndex, idx >= 0 {
                indices.append(idx)
            }
        }
        // 旧状态无 cliScreenIndex：daemon 以 0..<N 索引屏，断开后
        // index >= 当前 NSScreen.count 的槽位必为 orphan，best-effort 停掉。
        if indices.isEmpty {
            let onlineCount = NSScreen.screens.count
            let maxProbe = max(onlineCount + 3, 4)
            if onlineCount < maxProbe {
                indices.append(contentsOf: onlineCount..<maxProbe)
            }
        }
        // 去重保序
        var seen = Set<Int>()
        return indices.filter { seen.insert($0).inserted }
    }

    /// 停止指定屏 scene 进程，但不从 `screenRenderStates` 删除（断屏保留恢复态）。
    private func stopScreenProcessKeepingRestoreState(_ screenID: String) async {
        guard let info = screenProcesses[screenID] else {
            print("[WallpaperEngineXBridge] stopScreenProcessKeepingRestoreState: 屏幕 \(screenID) 无活跃进程，跳过")
            return
        }
        print("[WallpaperEngineXBridge] stopScreenProcessKeepingRestoreState: 停止屏幕 \(screenID) 渲染进程 (pid=\(info.pid))，保留恢复状态")

        screenWatchdogs[info.pid]?.cancel()
        screenWatchdogs.removeValue(forKey: info.pid)
        killAllAudioChildren(pid: info.pid)
        terminateRenderer(pid: info.pid)

        let pid = info.pid
        let watchdog = DispatchWorkItem {
            if kill(pid, 0) == 0 {
                print("[WallpaperEngineXBridge] 断屏 renderer 未及时退出，发送 SIGKILL (pid=\(pid))")
                kill(pid, SIGKILL)
            }
        }
        screenWatchdogs[pid] = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: watchdog)

        removeScreenProcess(screenID)
        _deinitPIDs.remove(pid)
        processPendingTermination()
    }

    /// 持久化时保留已断屏的 render state（仅按 fingerprint 识别的历史屏），
    /// 以便外接屏重插后 `restorePreviousWallpaperIfAvailable` 能找回 path。
    private func persistStateKeepingDisconnectedRestoreStates() {
        // 合并：内存中的全量 screenRenderStates（含 orphan）+ 目标集合
        if !screenRenderStates.isEmpty {
            if let data = try? JSONEncoder().encode(Array(screenRenderStates.values)) {
                UserDefaults.standard.set(data, forKey: screenRenderStatesKey)
            }
            if let path = lastWallpaperPath ?? screenRenderStates.values.first?.path {
                UserDefaults.standard.set(path, forKey: lastWallpaperPathKey)
            }
            UserDefaults.standard.set(!screenRenderStates.isEmpty, forKey: controllingExternalKey)
            // target IDs 只写当前在线的；fingerprint 写全量以便重插匹配
            let onlineIDs = Set(NSScreen.screens.map(\.wallpaperScreenIdentifier))
            let onlineTargetIDs = targetScreenIDs.intersection(onlineIDs)
            let allFingerprints = Set(screenRenderStates.values.map(\.screenFingerprint))
                .union(targetScreenFingerprints)
            UserDefaults.standard.set(Array(onlineTargetIDs), forKey: targetScreenIDsKey)
            UserDefaults.standard.set(Array(allFingerprints), forKey: targetScreenFingerprintsKey)
            targetScreenFingerprints = allFingerprints
        } else {
            clearPersistedState()
        }
    }

    // MARK: - 二进制查找

    /// 解析 bundled `wallpaper-wgpu` 可执行文件路径
    nonisolated static func resolvedCLIExecutableURL() -> URL? {
        // 1. Bundle 内（folder reference 场景）
        if let url = Bundle.main.url(forResource: "wallpaper-wgpu", withExtension: nil) {
            print("[WallpaperEngineXBridge] 找到 wallpaper-wgpu: Bundle.main.url")
            return url
        }

        // 2. Contents/Resources/wallpaper-wgpu
        let bundleResources = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/wallpaper-wgpu")
        if FileManager.default.fileExists(atPath: bundleResources.path) {
            print("[WallpaperEngineXBridge] 找到 wallpaper-wgpu: Contents/Resources")
            return bundleResources
        } else {
            print("[WallpaperEngineXBridge] 未找到: \(bundleResources.path)")
        }

        // 3. Contents/Resources/Resources/wallpaper-wgpu（folder reference 嵌套）
        let nestedResources = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Resources/wallpaper-wgpu")
        if FileManager.default.fileExists(atPath: nestedResources.path) {
            print("[WallpaperEngineXBridge] 找到 wallpaper-wgpu: Resources/Resources")
            return nestedResources
        } else {
            print("[WallpaperEngineXBridge] 未找到: \(nestedResources.path)")
        }

        // 4. resourceURL
        if let resourceURL = Bundle.main.resourceURL {
            let resourcePath = resourceURL.appendingPathComponent("wallpaper-wgpu")
            if FileManager.default.fileExists(atPath: resourcePath.path) {
                print("[WallpaperEngineXBridge] 找到 wallpaper-wgpu: resourceURL")
                return resourcePath
            } else {
                print("[WallpaperEngineXBridge] 未找到: \(resourcePath.path)")
            }
        }

        // 5. bundle 同级目录（开发/调试）
        let siblingPath = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("wallpaper-wgpu")
        if FileManager.default.fileExists(atPath: siblingPath.path) {
            print("[WallpaperEngineXBridge] 找到 wallpaper-wgpu: bundle 同级")
            return siblingPath
        } else {
            print("[WallpaperEngineXBridge] 未找到: \(siblingPath.path)")
        }

        // 6. 项目开发路径
        let projectPaths = [
            ("/Volumes/mac/CodeLibrary/Claude/WallHaven/wallpaper-wgpu", "项目根目录"),
            ("/Volumes/mac/CodeLibrary/Claude/WallHaven/Resources/wallpaper-wgpu", "项目 Resources")
        ]
        for (path, label) in projectPaths {
            if FileManager.default.fileExists(atPath: path) {
                print("[WallpaperEngineXBridge] 找到 wallpaper-wgpu: \(label)")
                return URL(fileURLWithPath: path)
            } else {
                print("[WallpaperEngineXBridge] 未找到: \(path) (\(label))")
            }
        }

        print("[WallpaperEngineXBridge] ❌ wallpaper-wgpu 在所有路径中均未找到")
        return nil
    }

    /// 解析 `wallpaperengine-cli` 可执行文件路径（web 壁纸 daemon）
    nonisolated static func resolvedLegacyCLIExecutableURL() -> URL? {
        // 1. Bundle 内（folder reference 场景）
        if let url = Bundle.main.url(forResource: "wallpaperengine-cli", withExtension: nil) {
            print("[WallpaperEngineXBridge] 找到 wallpaperengine-cli: Bundle.main.url")
            return url
        }

        // 2. Contents/Resources/wallpaperengine-cli
        let bundleResources = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/wallpaperengine-cli")
        if FileManager.default.fileExists(atPath: bundleResources.path) {
            print("[WallpaperEngineXBridge] 找到 wallpaperengine-cli: Contents/Resources")
            return bundleResources
        } else {
            print("[WallpaperEngineXBridge] 未找到: \(bundleResources.path)")
        }

        // 3. Contents/Resources/Resources/wallpaperengine-cli（folder reference 嵌套）
        // 与 resolvedCLIExecutableURL() 对齐：Xcode folder reference 实际会把 Resources/
        // 整目录复制到 .app/Contents/Resources/Resources/，少了这一级会导致用户机器找不到二进制。
        let nestedResources = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Resources/wallpaperengine-cli")
        if FileManager.default.fileExists(atPath: nestedResources.path) {
            print("[WallpaperEngineXBridge] 找到 wallpaperengine-cli: Resources/Resources")
            return nestedResources
        } else {
            print("[WallpaperEngineXBridge] 未找到: \(nestedResources.path)")
        }

        // 4. resourceURL
        if let resourceURL = Bundle.main.resourceURL {
            let resourcePath = resourceURL.appendingPathComponent("wallpaperengine-cli")
            if FileManager.default.fileExists(atPath: resourcePath.path) {
                print("[WallpaperEngineXBridge] 找到 wallpaperengine-cli: resourceURL")
                return resourcePath
            } else {
                print("[WallpaperEngineXBridge] 未找到: \(resourcePath.path)")
            }
        }

        // 5. bundle 同级目录（开发/调试）
        let siblingPath = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("wallpaperengine-cli")
        if FileManager.default.fileExists(atPath: siblingPath.path) {
            print("[WallpaperEngineXBridge] 找到 wallpaperengine-cli: bundle 同级")
            return siblingPath
        } else {
            print("[WallpaperEngineXBridge] 未找到: \(siblingPath.path)")
        }

        // 6. 项目开发路径
        let projectPaths = [
            "/Volumes/mac/CodeLibrary/Claude/WallHaven/wallpaperengine-cli",
            "/Volumes/mac/CodeLibrary/Claude/WallHaven/Resources/wallpaperengine-cli"
        ]
        for path in projectPaths {
            if FileManager.default.fileExists(atPath: path) {
                print("[WallpaperEngineXBridge] 找到 wallpaperengine-cli: \(path)")
                return URL(fileURLWithPath: path)
            } else {
                print("[WallpaperEngineXBridge] 未找到: \(path)")
            }
        }

        print("[WallpaperEngineXBridge] ❌ wallpaperengine-cli 在所有路径中均未找到")
        return nil
    }

    /// 合并用户属性 JSON 与场景配置覆盖（__-prefixed system keys）
    /// 场景配置覆盖由 SceneConfigOverrideService 管理，两者合并为单一 JSON 传给 --user-properties
    private static func mergeSceneConfigOverrides(_ userProperties: String?, wallpaperPath: String) -> String? {
        SceneConfigOverrideService.mergedPropertiesJSON(
            userPropertiesJSON: userProperties,
            for: wallpaperPath
        )
    }

    // MARK: - 烘焙静态资源同步

    /// 壁纸路径的缓存 key，用于记录最近一次使用的烘焙静态资源路径。
    private static func bakedStaticCacheKey(for path: String) -> String {
        let hash = abs(path.hashValue)
        return "baked_static_\(hash)"
    }

    /// 后台同步已有 scene 烘焙封面。
    /// 封面读不到就不更新；没有抽帧 poster 时保持当前系统背板，避免回写上一张壁纸。
    private func scheduleBakedCoverSync(
        path: String,
        targetScreens: [NSScreen]
    ) {
        // 每次设壁纸都先作废上一轮异步同步；动态锁屏接管后绝不能让旧任务回写桌面。
        bakedStaticUpdateGeneration &+= 1
        let generation = bakedStaticUpdateGeneration

        guard !targetScreens.isEmpty else {
            print("[WallpaperEngineXBridge] ⚠️ 无可用目标屏幕，跳过烘焙静态资源同步")
            return
        }

        if #available(macOS 26.0, *),
           VideoWallpaperManager.shared.isLockScreenEnabled {
            print("[WallpaperEngineXBridge] 🔒 动态锁屏已接管，跳过 Scene 烘焙封面的桌面同步")
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.bakedStaticUpdateGeneration == generation else { return }
            guard self.lastWallpaperPath == path || self.screenRenderStates.values.contains(where: { $0.path == path }) else {
                return
            }

            guard let existing = await self.existingBakedCoverURL(forScenePath: path) else {
                print("[WallpaperEngineXBridge] Scene 烘焙封面读取不到，不更新系统桌面/锁屏")
                return
            }
            if self.applyBakedStaticImage(
                existing,
                for: path,
                targetScreens: targetScreens,
                updateGeneration: generation
            ) {
                print("[WallpaperEngineXBridge] ✅ 已使用烘焙静态资源: \(existing.lastPathComponent)")
            }
        }
    }

    /// 在外部 renderer 启动前同步写入已有的高清烘焙封面。没有可用 poster 时不阻塞
    /// Scene/Web 的实时渲染，后续仍由异步抽帧完成通知接管。
    private func commitExistingBakedCoverBeforeRendererStart(
        path: String,
        targetScreens: [NSScreen]
    ) async {
        guard !targetScreens.isEmpty else { return }
        guard let existing = await existingBakedCoverURL(forScenePath: path) else {
            return
        }
        if applyBakedStaticImage(
            existing,
            for: path,
            targetScreens: targetScreens,
            updateGeneration: nil
        ) {
            print("[WallpaperEngineXBridge] ✅ renderer 启动前已提交烘焙静态底图: \(existing.lastPathComponent)")
        }
    }

    /// 读取已有烘焙静态资源。Scene 只有在存在真实烘焙产物时才使用通用
    /// `scene_bake_*` 封面；关闭自动烘焙后的按屏静帧由 companion poster 路径处理。
    /// Web 的在线截图仍使用通用稳定封面。
    private func existingBakedCoverURL(forScenePath path: String) async -> URL? {
        let contentRoot = WorkshopService.resolveWallpaperEngineProjectRoot(startingAt: URL(fileURLWithPath: path))
        let record = MediaLibraryService.shared.downloadRecord(forLocalFilePath: contentRoot.path)
            ?? MediaLibraryService.shared.downloadedItems.first { record in
                record.hasSameLocalContent(as: contentRoot)
                    || WorkshopService.resolveWallpaperEngineProjectRoot(
                        startingAt: URL(fileURLWithPath: record.localFilePath)
                    ).path == contentRoot.path
            }

        let isWebProject = isWebWallpaper(path: contentRoot.path)
        if isWebProject,
           let itemID = record?.item.id,
           let scenePoster = VideoThumbnailCache.shared.cachedSceneBakePosterFileURLIfExists(itemID: itemID) {
            return scenePoster
        }

        if let itemID = record?.item.id,
           let artifact = SceneOfflineBakeService.usableArtifact(from: record) {
            let bakedVideoURL = URL(fileURLWithPath: artifact.videoPath)
            return await ensureSceneBakePosterAndNotify(itemID: itemID, videoURL: bakedVideoURL)
        }

        if isWebProject, let artifact = record?.sceneBakeArtifact {
            let bakedVideoURL = URL(fileURLWithPath: artifact.videoPath)
            if let poster = VideoThumbnailCache.shared.cachedPosterJPEGFileURLIfExists(forLocalVideo: bakedVideoURL) {
                return poster
            }
        }

        return nil
    }

    /// 把已有烘焙封面设为系统桌面壁纸。
    private func applyBakedStaticImage(
        _ imageURL: URL,
        for path: String,
        targetScreens: [NSScreen]?,
        updateGeneration: UInt64?
    ) -> Bool {
        if let updateGeneration, bakedStaticUpdateGeneration != updateGeneration {
            return false
        }
        guard FileManager.default.fileExists(atPath: imageURL.path) else { return false }

        if #available(macOS 26.0, *), VideoWallpaperManager.shared.isLockScreenEnabled {
            print("[WallpaperEngineXBridge] 🔒 动态锁屏已启用，跳过烘焙封面的系统桌面写入")
            return true
        }

        let cacheKey = Self.bakedStaticCacheKey(for: path)
        UserDefaults.standard.set(imageURL.path, forKey: cacheKey)

        // 系统壁纸同步关闭时：动态 scene 仍由 wgpu 渲染，但不得写系统桌面静态图。
        guard VideoWallpaperManager.shared.isSystemWallpaperSyncEnabled else {
            print("[WallpaperEngineXBridge] 🧊 系统壁纸同步已关闭，跳过烘焙封面写入")
            return true
        }

        let fillOptions: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSNumber(value: NSImageScaling.scaleProportionallyUpOrDown.rawValue),
            .allowClipping: true
        ]
        // 交替复制一份再 setDesktop，避免系统缓存固定路径旧图
        bakedStaticDesktopSlot = 1 - bakedStaticDesktopSlot
        let cacheDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Caches/com.waifux.wallpaperengine/baked-static-wallpapers")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let slotURL = cacheDir.appendingPathComponent("\(cacheKey)_s\(bakedStaticDesktopSlot)\(imageURL.pathExtension.isEmpty ? ".jpg" : ".\(imageURL.pathExtension)")")
        try? FileManager.default.removeItem(at: slotURL)
        do {
            try FileManager.default.copyItem(at: imageURL, to: slotURL)
        } catch {
            // 复制失败则直接用原文件
            print("[WallpaperEngineXBridge] ⚠️ 复制烘焙封面到交替路径失败，改用原路径: \(error.localizedDescription)")
        }
        let applyURL = FileManager.default.fileExists(atPath: slotURL.path) ? slotURL : imageURL

        var didApply = false
        let screens: [NSScreen]
        if let targetScreens, !targetScreens.isEmpty {
            screens = targetScreens
        } else {
            let active = activeTargetScreens()
            screens = active.isEmpty ? NSScreen.screens : active
        }
        for screen in screens {
            do {
                try NSWorkspace.shared.setDesktopImageURLForAllSpaces(applyURL, for: screen, options: fillOptions)
                DesktopWallpaperSyncManager.shared.registerWallpaperSet(applyURL, for: screen, options: fillOptions)
                print("[WallpaperEngineXBridge] ✅ 烘焙封面壁纸已设置 (screen: \(screen.localizedName)) source=\(applyURL.lastPathComponent)")
                didApply = true
            } catch {
                print("[WallpaperEngineXBridge] ⚠️ 设置静态壁纸失败 (screen: \(screen.localizedName)): \(error.localizedDescription)")
            }
        }
        if didApply {
            // Scene/Web 的 poster 已写入系统壁纸：wgpu / engine-cli 窗口
            // 常驻近乎不透明（alpha=0.99999，各自进程内设置），壁纸层不被挂起，
            // 菜单栏 backdrop 懒采样（~10s）自动采到新 poster。
        }
        return didApply
    }

    // MARK: - 辅助方法

    private func activeTargetScreens() -> [NSScreen] {
        if targetScreenIDs.isEmpty && targetScreenFingerprints.isEmpty {
            return NSScreen.screens
        }
        relinkTargetScreens()
        return NSScreen.screens.filter { screen in
            targetScreenIDs.contains(screen.wallpaperScreenIdentifier) ||
            targetScreenFingerprints.contains(screen.wallpaperScreenFingerprint)
        }
    }

    // MARK: - System Wake Recovery

    /// scene 进程和 Web daemon 在长睡眠后都可能仍存活，但其图形上下文已经失效。
    /// 因此不把“PID 还在”当成健康信号；在显示器恢复稳定后按屏重新创建运行时。
    private func scheduleWakeRecovery(reason: String) {
        let hasManagedState = isControllingExternalEngine
            || !screenRenderStates.isEmpty
            || !screenProcesses.isEmpty
        guard hasManagedState else { return }

        wakeRecoveryGeneration &+= 1
        let generation = wakeRecoveryGeneration
        wakeRecoveryTask?.cancel()
        wakeRecoveryTask = Task { @MainActor [weak self] in
            do {
                // 给 WindowServer、Metal 和 daemon 充分恢复时间；didWake 与
                // screensDidWake 会被 generation 防抖成最后一次通知的一轮重建。
                try await Task.sleep(for: .milliseconds(650))
            } catch {
                return
            }

            guard let self, !Task.isCancelled,
                  self.wakeRecoveryGeneration == generation else {
                return
            }
            await self.rebuildRenderersAfterSystemWake(reason: reason, generation: generation)
            if self.wakeRecoveryGeneration == generation {
                self.wakeRecoveryTask = nil
            }
        }
    }

    private func rebuildRenderersAfterSystemWake(reason: String, generation: UInt64) async {
        guard wakeRecoveryGeneration == generation, !isSettingWallpaper else { return }
        processPendingTermination()

        let targets = activeTargetScreens().compactMap { screen -> (NSScreen, ScreenRenderState)? in
            let screenID = screen.wallpaperScreenIdentifier
            guard !isPaused(screenID: screenID),
                  let state = renderState(for: screen),
                  FileManager.default.fileExists(atPath: state.path) else {
                return nil
            }
            return (screen, state)
        }
        guard !targets.isEmpty else {
            DynamicWallpaperAutoPauseManager.shared.reevaluateCurrentState()
            return
        }

        AppLogger.error(.wallpaper, "WallpaperEngineX recovering renderers after system wake", metadata: [
            "reason": reason,
            "screens": targets.map { "\($0.0.wallpaperScreenIdentifier):\($0.1.renderKind.rawValue)" }.joined(separator: ","),
            "pausedScreens": perScreenPausedScreenIDs.sorted().joined(separator: ",")
        ])

        for (screen, state) in targets {
            guard wakeRecoveryGeneration == generation, !isSettingWallpaper else { return }
            let userProperties = state.userProperties
                ?? SceneWallpaperPropertiesService.propertiesOverrideJSON(for: state.path)
            do {
                // forceRestart 会重建 scene 的 Metal 进程；web 路径会重新 set 到
                // daemon，从而创建新的 WKWebView。保留 AutoPause 记账，避免醒来
                // 后错误恢复本应暂停的其它屏幕。
                try await setWallpaper(
                    path: state.path,
                    targetScreens: [screen],
                    userProperties: userProperties,
                    forceRestart: true,
                    preserveAutoPauseState: true,
                    preserveExistingRendererUntilReady: state.renderKind == .scene
                )
                print("[WallpaperEngineXBridge] 已恢复唤醒后渲染器 screen=\(screen.wallpaperScreenIdentifier) kind=\(state.renderKind.rawValue)")
            } catch {
                AppLogger.error(.wallpaper, "WallpaperEngineX wake recovery failed", metadata: [
                    "screen": screen.wallpaperScreenIdentifier,
                    "kind": state.renderKind.rawValue,
                    "error": error.localizedDescription
                ])
                print("[WallpaperEngineXBridge] ⚠️ 唤醒后重建失败 screen=\(screen.wallpaperScreenIdentifier): \(error.localizedDescription)")
            }
        }

        DynamicWallpaperAutoPauseManager.shared.reevaluateCurrentState()
    }

    private func relinkTargetScreens() {
        for screen in NSScreen.screens where targetScreenFingerprints.contains(screen.wallpaperScreenFingerprint) {
            targetScreenIDs.insert(screen.wallpaperScreenIdentifier)
        }
    }

    /// 可视区域 crop 变更：scene 写入 `--crop-control` JSON，web 走 daemon IPC；
    /// 两者都支持拖拽期间实时热更新，无需重启渲染器。
    @MainActor
    private func handleCropDidChange(_ note: Notification) {
        guard !isSettingWallpaper else { return }
        guard let screenID = note.userInfo?["screenID"] as? String,
              let screen = NSScreen.screens.first(where: { $0.wallpaperScreenIdentifier == screenID }) else { return }
        applyPersistedCrop(for: screen)
    }

    /// 把当前屏已保存的可视区域写回正在跑的 Scene / Web 渲染器。
    /// 画布尺寸文件被热切换清掉时，用 `lastCanvasSizeByScreenID` 兜底，避免 crop 丢成全图 Cover。
    @MainActor
    private func applyPersistedCrop(for screen: NSScreen) {
        guard isManaging(screen: screen) else { return }
        if isWebWallpaperOn(screen: screen) {
            sendWebCropToWebDaemon(for: screen)
            return
        }
        guard isControllingExternalEngine else { return }
        let screenID = screen.wallpaperScreenIdentifier
        let info = screenProcesses[screenID]
            ?? screenProcesses.values.first(where: { $0.screenID == screenID })
        guard let cropControlURL = info?.cropControlURL else { return }

        let cropSettings = DisplayCropSettingsStore.shared.settings(for: screen)
        let f = screen.frame
        let screenW = Int(f.width.rounded())
        let screenH = Int(f.height.rounded())
        let freshSize = readCanvasSize(url: info?.canvasSizeURL)
        if let freshSize {
            lastCanvasSizeByScreenID[screenID] = freshSize
        }
        let knownSize = cropWallpaperSize(
            screen: screen,
            path: renderState(for: screen)?.path,
            canvasSizeURL: info?.canvasSizeURL,
            allowCachedCanvas: true
        )
        let nextCrop: UnitRect?
        let nextViewport: UnitRect?
        if cropSettings.shouldApplyCrop {
            let wallpaperSize = knownSize ?? CGSize(width: screenW, height: screenH)
            let isFillWithoutSize = knownSize == nil
                && (cropSettings.aspectPreset == .autoFill
                    || (cropSettings.aspectPreset == .custom && cropSettings.customAspect == nil))
            if isFillWithoutSize {
                nextCrop = nil
                nextViewport = nil
            } else {
                let layout = CropLayoutEngine.compute(
                    wallpaperSize: wallpaperSize,
                    screenSize: CGSize(width: screenW, height: screenH),
                    settings: cropSettings)
                nextCrop = layout.wallpaperCropRect
                let vp = layout.viewportRect
                let isFullVp = abs(vp.x) < 1e-4 && abs(vp.y) < 1e-4
                    && abs(vp.w - 1) < 1e-4 && abs(vp.h - 1) < 1e-4
                nextViewport = isFullVp ? nil : vp
            }
        } else {
            nextCrop = nil
            nextViewport = nil
        }
        writeCropControl(url: cropControlURL, crop: nextCrop, viewport: nextViewport)
    }

    private func handleScreenParametersChanged() {
        // 即使当前未接管，也可能只是静态/视频路径；这里仅处理外部引擎。
        // 但若仍有残留 render state / 进程，也要允许 orphan 清理。
        let hasManagedState = isControllingExternalEngine
            || !screenRenderStates.isEmpty
            || !screenProcesses.isEmpty
        guard hasManagedState else { return }

        AppLogger.error(.wallpaper, "WallpaperEngineX screen parameters changed", metadata: [
            "isSettingWallpaper": isSettingWallpaper,
            "processScreens": screenProcesses.keys.sorted().joined(separator: ","),
            "stateScreens": screenRenderStates.keys.sorted().joined(separator: ","),
            "targetIDs": targetScreenIDs.sorted().joined(separator: ","),
            "currentScreens": NSScreen.screens.map(\.wallpaperScreenIdentifier).joined(separator: ",")
        ])
        guard !isSettingWallpaper else {
            print("[WallpaperEngineXBridge] 忽略屏幕参数通知：壁纸正在设置中")
            return
        }

        let previousConfigurations = lastAppliedScreenConfigurations
        let statesBeforeRestart = screenRenderStates

        relinkTargetScreens()

        screenChangeRestartWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard !self.isSettingWallpaper else { return }

            Task { @MainActor in
                // 1) 先回收已断屏的 scene 进程 / web daemon（保留 restore 状态）
                let didCleanOrphans = await self.cleanupOrphanedScreenRuntimes()

                self.relinkTargetScreens()
                let currentConfigurations = self.currentTargetScreenConfigurations()

                // 2) 仅重启「仍在线且几何签名变了 / 应有运行时却缺失」的屏。
                //    拔掉副屏时主屏 scene 几何常不变 → 不 forceRestart。
                let previousByID = Dictionary(uniqueKeysWithValues: previousConfigurations.map { ($0.screenID, $0) })
                let screensNeedingRestart = self.activeTargetScreens().filter { screen in
                    let screenID = screen.wallpaperScreenIdentifier
                    let fingerprint = screen.wallpaperScreenFingerprint
                    let currentSig = ScreenConfigurationSignature(screen: screen)
                    // 与 launchedScreenWidth/Height 基准一致（全屏窗口尺寸）。
                    let wallpaperFrame = screen.frame
                    let frameW = Int(wallpaperFrame.width.rounded())
                    let frameH = Int(wallpaperFrame.height.rounded())

                    let state = statesBeforeRestart[screenID]
                        ?? statesBeforeRestart.values.first { $0.screenFingerprint == fingerprint }
                        ?? self.screenRenderStates[screenID]
                        ?? self.screenRenderStates.values.first { $0.screenFingerprint == fingerprint }

                    if let state, state.renderKind == .scene {
                        let hasProcess = self.screenProcesses[screenID] != nil
                            || self.screenProcesses.values.contains { $0.screenID == screenID }
                        if !hasProcess {
                            return true
                        }
                        if let info = self.screenProcesses[screenID]
                            ?? self.screenProcesses.values.first(where: { $0.screenID == screenID }),
                           info.launchedScreenWidth != frameW || info.launchedScreenHeight != frameH {
                            return true
                        }
                    }

                    if let previousSig = previousByID[screenID] {
                        return previousSig != currentSig
                    }

                    // screenID 变化（fingerprint relink）：进程在且尺寸一致则跳过
                    if let info = self.screenProcesses[screenID]
                        ?? self.screenProcesses.first(where: {
                            self.screenRenderStates[$0.key]?.screenFingerprint == fingerprint
                        })?.value,
                       info.launchedScreenWidth == frameW,
                       info.launchedScreenHeight == frameH {
                        return false
                    }

                    // 有 restore state 但无运行时 → 需要拉起（多为重插，正常由 ExternalDisplay 走 restore）
                    return state != nil && self.screenProcesses[screenID] == nil
                }

                if screensNeedingRestart.isEmpty {
                    self.lastAppliedScreenConfigurations = currentConfigurations
                    if didCleanOrphans {
                        print("[WallpaperEngineXBridge] 断屏 orphan 已清理，在线屏配置未变，跳过重启")
                    } else {
                        print("[WallpaperEngineXBridge] 忽略屏幕参数通知：目标显示器配置未变化")
                    }
                    return
                }

                guard self.isControllingExternalEngine || !self.screenRenderStates.isEmpty else { return }

                AppLogger.error(.wallpaper, "WallpaperEngineX restarting after screen change", metadata: [
                    "restartScreens": screensNeedingRestart.map(\.wallpaperScreenIdentifier).joined(separator: ","),
                    "statesBeforeRestart": statesBeforeRestart.keys.sorted().joined(separator: ","),
                    "didCleanOrphans": didCleanOrphans,
                    "hasLastPath": self.lastWallpaperPath != nil
                ])

                print("[WallpaperEngineXBridge] 屏幕参数已变更，重启受影响渲染进程")
                if !statesBeforeRestart.isEmpty {
                    for screen in screensNeedingRestart {
                        let screenID = screen.wallpaperScreenIdentifier
                        let fingerprint = screen.wallpaperScreenFingerprint
                        guard let state = statesBeforeRestart[screenID]
                                ?? statesBeforeRestart.values.first(where: { $0.screenFingerprint == fingerprint })
                                ?? self.screenRenderStates[screenID]
                                ?? self.screenRenderStates.values.first(where: { $0.screenFingerprint == fingerprint })
                        else {
                            continue
                        }
                        let userProps = state.userProperties
                            ?? SceneWallpaperPropertiesService.propertiesOverrideJSON(for: state.path)
                        try? await self.setWallpaper(
                            path: state.path,
                            targetScreens: [screen],
                            userProperties: userProps,
                            forceRestart: true
                        )
                    }
                } else if let path = self.lastWallpaperPath {
                    let userProps = SceneWallpaperPropertiesService.propertiesOverrideJSON(for: path)
                    try? await self.setWallpaper(
                        path: path,
                        targetScreens: screensNeedingRestart,
                        userProperties: userProps,
                        forceRestart: true
                    )
                }

                self.lastAppliedScreenConfigurations = self.currentTargetScreenConfigurations()
            }
        }
        screenChangeRestartWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: workItem)
    }

    private func currentTargetScreenConfigurations() -> [ScreenConfigurationSignature] {
        activeTargetScreens()
            .map(ScreenConfigurationSignature.init(screen:))
            .sorted { lhs, rhs in
                lhs.screenID < rhs.screenID
            }
    }
}

// MARK: - Wallpaper Engine Project Type Detection

private func isWebWallpaper(path: String) -> Bool {
    detectWallpaperProjectType(path: path)?.lowercased() == "web"
}

private func detectWallpaperProjectType(path: String) -> String? {
    let fm = FileManager.default
    let url = URL(fileURLWithPath: path)
    let contentDir: URL

    if url.pathExtension.lowercased() == "pkg" {
        guard let extracted = extractPKG(at: url) else { return nil }
        contentDir = extracted
    } else {
        contentDir = WorkshopService.resolveWallpaperEngineProjectRoot(startingAt: url)
    }

    let projectJSON = contentDir.appendingPathComponent("project.json")
    if fm.fileExists(atPath: projectJSON.path),
       let data = try? Data(contentsOf: projectJSON),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        if let type = json["type"] as? String, !type.isEmpty {
            return type
        }
        if json["preset"] != nil {
            return "web"
        }
        if let file = json["file"] as? String {
            let ext = (file as NSString).pathExtension.lowercased()
            if ext == "html" || ext == "htm" { return "web" }
            if ext == "json", file.lowercased().contains("scene") { return "scene" }
            if ["mp4", "mov", "webm", "avi"].contains(ext) { return "video" }
        }
    }

    guard let entries = try? fm.contentsOfDirectory(at: contentDir, includingPropertiesForKeys: nil) else {
        return nil
    }
    let names = entries.map { $0.lastPathComponent.lowercased() }
    let exts = entries.map { $0.pathExtension.lowercased() }
    if exts.contains("html") || exts.contains("htm") { return "web" }
    if names.contains(where: { $0.hasSuffix(".scene.pkg") || $0 == "scene.pkg" }) { return "scene" }
    if exts.contains("mp4") || exts.contains("mov") || exts.contains("webm") { return "video" }
    if exts.contains("pkg") { return "scene" }
    return nil
}

private func extractPKG(at url: URL) -> URL? {
    let fm = FileManager.default
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("wallpaperengine_pkg_\(url.deletingPathExtension().lastPathComponent)_\(UUID().uuidString.prefix(8))")
    try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    process.arguments = ["-o", "-q", url.path, "-d", tempDir.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice

    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? tempDir : nil
    } catch {
        print("[WallpaperEngineXBridge] extractPKG failed: \(error.localizedDescription)")
        return nil
    }
}

// MARK: - 错误类型

enum WallpaperEngineError: LocalizedError {
    case notInstalled
    case cliNotFound
    case legacyCliNotFound
    case screenCaptureDenied
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled: return "Wallpaper Engine 未安装"
        case .cliNotFound: return "未找到 wallpaper-wgpu 二进制文件"
        case .legacyCliNotFound: return "未找到 wallpaperengine-cli 二进制文件"
        case .screenCaptureDenied: return "屏幕录制权限被拒绝，请在「系统设置 → 隐私与安全性 → 屏幕录制」中允许本应用后重试"
        case .executionFailed(let msg): return msg
        }
    }
}
