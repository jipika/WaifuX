import Foundation
import AppKit
import Combine
import WebKit

private let webPrimaryCapturePath = "/tmp/wallpaperengine-web-capture.png"
private let webDeskCapturePath0 = "/tmp/wallpaperengine-web-desk-0.png"
private let webDeskCapturePath1 = "/tmp/wallpaperengine-web-desk-1.png"
private let legacyCLIWebCapturePath = "/tmp/wallpaperengine-cli-capture.png"

private struct SavedOriginalWallpaperState: Codable {
    let configs: [ScreenWallpaperConfig]
    let savedAt: Date
    let appVersion: String
}

private struct ScreenWallpaperConfig: Codable {
    let screenID: String
    let screenName: String
    let wallpaperURL: String
    let isMainScreen: Bool
}

/// 与 wallpaperengine-cli daemon IPC 的音频控制消息
private struct WebDaemonAudioMessage: Codable {
    let command: String
    let muted: Bool?
    let volume: Double?
}

/// 与 wallpaperengine-cli daemon IPC 的音频频谱数据消息。
/// 协议：command="audioData", spectrum=[128 floats]（0..63=L, 64..127=R）；daemon 不回响应。
private struct WebDaemonAudioDataMessage: Codable {
    let command: String
    let spectrum: [Float]
}

/// 进程终止事件（线程安全，通过 os_unfair_lock 传递到 @MainActor）
private struct TerminationEvent: @unchecked Sendable {
    let pid: pid_t
    let generation: UInt64
    let status: Int32
    let reason: Process.TerminationReason
}

/// 检查是否有屏幕录制权限（同步，禁止调用时直接崩溃）
private func checkScreenCapturePermission() -> Bool {
    if #available(macOS 10.15, *) {
        return CGPreflightScreenCaptureAccess()
    }
    return true
}

/// 请求屏幕录制权限。真实截取外部 renderer 窗口必须走系统授权，不能用预览图替代。
private func requestScreenCapturePermission() async -> Bool {
    if #available(macOS 10.15, *) {
        if CGPreflightScreenCaptureAccess() { return true }
        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume(returning: CGRequestScreenCaptureAccess())
            }
        }
    }
    return true
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

    // MARK: - 进程管理

    /// 每个屏幕的 wallpaper-wgpu 进程信息（key = screenID）
    private var screenProcesses: [String: ScreenProcessInfo] = [:]
    private let webRenderer = WebRendererBridge.shared
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
    }
    private var activeRenderKind: RenderKind?
    private var screenRenderStates: [String: ScreenRenderState] = [:]
    /// 每个进程的终止 watchdog（key = pid）
    private var screenWatchdogs: [pid_t: DispatchWorkItem] = [:]
    /// 非隔离存储所有活跃 PID，供 deinit 中安全清理
    private nonisolated(unsafe) var _deinitPIDs: Set<pid_t> = []
    /// 启动批次号，防止旧进程的 terminationHandler 污染新进程状态
    private var launchGeneration: UInt64 = 0

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
    private var isSettingWallpaper = false

    // MARK: - 持久化状态

    private var lastWallpaperPath: String?
    private var targetScreenIDs = Set<String>()
    private var targetScreenFingerprints = Set<String>()
    private var cancellables = Set<AnyCancellable>()

    /// WE Web 壁纸音频中继当前是否对应于活跃壁纸（基于 project.json audio 标志）
    private var audioRelayActiveForCurrentWallpaper = false
    /// 暂停前的 relay 状态，恢复时还原
    private var wasAudioRelayActiveBeforePause = false

    private let lastWallpaperPathKey = "we_last_wallpaper_path_v1"
    private let controllingExternalKey = "we_controlling_external_v1"
    private let targetScreenIDsKey = "we_target_screen_ids_v1"
    private let targetScreenFingerprintsKey = "we_target_screen_fingerprints_v1"
    private let screenRenderStatesKey = "we_screen_render_states_v2"

    // MARK: - 屏幕变化观察

    /// 屏幕参数变化（分辨率、显示器热插拔等）时重启渲染进程
    private var screenChangeRestartWorkItem: DispatchWorkItem?
    private var lastAppliedScreenConfigurations: [ScreenConfigurationSignature] = []

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

    // MARK: - 设置壁纸

    /// 使用 wallpaper-wgpu 设置动态壁纸
    /// - Parameters:
    ///   - path: 壁纸目录或 scene.pkg 路径
    ///   - assetsPath: assets-pc 资源目录路径（nil 时从内嵌 assets 解压）
    ///   - targetScreens: 目标屏幕列表（nil 表示所有屏幕）
    ///   - userProperties: 用户属性覆盖 JSON（nil 时不传 --user-properties）
    ///   - forceRestart: 强制重启进程（例如屏幕分辨率变化时），默认 false 走热切换
    func setWallpaper(path: String, assetsPath: String? = nil, targetScreens: [NSScreen]? = nil, userProperties: String? = nil, forceRestart: Bool = false) async throws {
        print("[WallpaperEngineXBridge] >>> setWallpaper START path=\(path)")

        // 记录当前焦点应用，渲染器启动后恢复焦点（避免新进程窗口抢焦点）
        let previousApp = NSWorkspace.shared.frontmostApplication

        // 处理之前堆积的进程终止事件
        processPendingTermination()

        // 防重复启动：恢复桌面时可能多次触发，串行化处理
        guard !isSettingWallpaper else {
            print("[WallpaperEngineXBridge] ⚠️ 已有壁纸设置任务进行中，跳过")
            return
        }
        isSettingWallpaper = true
        defer {
            isSettingWallpaper = false
            print("[WallpaperEngineXBridge] <<< setWallpaper END")
        }

        // 设场景/web 壁纸时关闭并清除静态图 overlay（renderer 窗口本身覆盖桌面，静态 overlay 无意义且浪费窗口）
        StaticImageWallpaperOverlayManager.shared.clearState()

	// 壁纸切换时使设计面板的缓存失效
	WebWallpaperDesignService.shared.invalidateAllCaches()

	let resolvedPath = WorkshopService.resolveWallpaperEngineProjectRoot(startingAt: URL(fileURLWithPath: path)).path
	let renderKind: RenderKind = isWebWallpaper(path: resolvedPath) ? .web : .scene

        print("[WallpaperEngineXBridge] step 1: 停止本机视频层")

        // 1. 只停本机视频层；切勿调用 `VideoWallpaperManager.stopWallpaper()`（会恢复静态桌面）
        if let screens = targetScreens, !screens.isEmpty {
            for screen in screens {
                VideoWallpaperManager.shared.stopNativeVideoWallpaperOnly(for: screen)
            }
        } else {
            VideoWallpaperManager.shared.stopNativeVideoWallpaperOnly()
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
        let effectiveScreens: [NSScreen]
        if let screens = targetScreens, !screens.isEmpty {
            effectiveScreens = screens
        } else {
            effectiveScreens = NSScreen.screens
        }
        let effectiveScreenIDs = Set(effectiveScreens.map(\.wallpaperScreenIdentifier))

        let targetWebStates = screenRenderStates.values.filter { state in
            state.renderKind == .web && effectiveScreenIDs.contains(state.screenID)
        }
        let shouldStopWebForTargets = !targetWebStates.isEmpty
            || (screenRenderStates.isEmpty && activeRenderKind == .web)

        // 如果目标屏幕原先由旧 Web daemon 管理，需要停掉 daemon；不要误伤其他屏幕的 Web 壁纸。
        if renderKind != .web && shouldStopWebForTargets {
            await Self.killLegacyDaemonIfRunning(waitForExit: true)
            webRenderer.stop()
            screenRenderStates = screenRenderStates.filter { $0.value.renderKind != .web }
        }

        if renderKind == .web {
            try await setWebWallpaper(path: resolvedPath, targetScreens: targetScreens)
            recordRenderState(path: resolvedPath, renderKind: renderKind, screens: effectiveScreens, userProperties: userProperties)
            DynamicWallpaperAutoPauseManager.shared.clearForegroundPauseForWallpaperSwitch()
            DynamicWallpaperAutoPauseManager.shared.reevaluateCurrentState()
            ensureAudioRelayMatchesActiveWallpaper(projectRoot: resolvedPath)
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
        if needsFreshLaunch {
            launchGeneration &+= 1
        }

        // 5. 遍历目标屏幕 — 每条路径都先尝试热切换，失败或首次则启动新进程
        var anyLaunchFailed = false
        var lastLaunchError: Error?

        for screen in effectiveScreens {
            let f = screen.frame
            let scale = screen.backingScaleFactor
            let screenX = Int(f.origin.x.rounded())
            let screenY = Int(f.origin.y.rounded())
            let screenW = Int(f.width.rounded())
            let screenH = Int(f.height.rounded())
            let screenID = screen.wallpaperScreenIdentifier

            // ── 情况 A：已有活跃进程且非强制重启 → 写控制文件热切换（不杀进程） ──
            if !forceRestart, let existingInfo = screenProcesses[screenID],
               let wcURL = existingInfo.wallpaperControlURL {
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

                // 更新持久化状态
                screenRenderStates[screenID] = ScreenRenderState(
                    screenID: screenID,
                    screenFingerprint: screen.wallpaperScreenFingerprint,
                    path: resolvedPath,
                    renderKind: renderKind,
                    userProperties: userProperties
                )

                // 写壁纸控制文件触发热切换
                writeWallpaperControl(
                    url: wcURL,
                    setWallpaper: resolvedPath,
                    assets: resolvedAssets.isEmpty ? nil : resolvedAssets,
                    setProperties: effectiveUserProperties
                )

                // 热切换时必须重置 crop-control 文件
                // 注意：此时 canvas-size 文件还是旧壁纸的尺寸，不能 readCanvasSize！
                // - 无裁切 → 写 null 清空
                // - 有裁切 → 跳过初始写入，等异步 Task 拿到新 canvas_size 后重算
                let cropSettings = DisplayCropSettingsStore.shared.settings(for: screen)
                if let ccURL = existingInfo.cropControlURL {
                    if cropSettings.shouldApplyCrop {
                        // 等 canvas_size 就绪后由下方的异步 Task 重算，这里先写 null 避免旧数据污染
                        writeCropControl(url: ccURL, crop: nil, viewport: nil)
                    } else {
                        writeCropControl(url: ccURL, crop: nil, viewport: nil)
                    }
                }
                if let acURL = existingInfo.audioControlURL {
                    writeAudioControl(
                        url: acURL,
                        muted: VideoWallpaperManager.shared.isMuted,
                        paused: isExternalPaused,
                        volume: VideoWallpaperManager.shared.volume(for: screen)
                    )
                }

                // 新壁纸 canvas 尺寸可能不同，等真实尺寸写出后更新 crop
                if let ccURL = existingInfo.cropControlURL,
                   let csURL = existingInfo.canvasSizeURL {
                    let cropSettingsCopy = cropSettings
                    let cropControlURLCopy = ccURL
                    let canvasSizeURLCopy = csURL
                    let screenW_c = screenW
                    let screenH_c = screenH
                    let screenIDCopy = screenID
                    Task { @MainActor [weak self] in
                        let deadline = Date().addingTimeInterval(5.0)
                        while Date() < deadline {
                            try? await Task.sleep(nanoseconds: 100_000_000)
                            guard let self else { return }
                            guard self.screenProcesses[screenIDCopy]?.pid == existingInfo.pid else { return }
                            if let realSize = self.readCanvasSize(url: canvasSizeURLCopy) {
                                let layout = CropLayoutEngine.compute(
                                    wallpaperSize: realSize,
                                    screenSize: CGSize(width: screenW_c, height: screenH_c),
                                    settings: cropSettingsCopy)
                                let vp = layout.viewportRect
                                let isFullVp = abs(vp.x) < 1e-4 && abs(vp.y) < 1e-4
                                    && abs(vp.w - 1) < 1e-4 && abs(vp.h - 1) < 1e-4
                                self.writeCropControl(url: cropControlURLCopy, crop: layout.wallpaperCropRect, viewport: isFullVp ? nil : vp)
                                print("[WallpaperEngineXBridge] 屏幕 \(screenIDCopy) 热切换后 canvas_size 就绪，crop 已重算")
                                return
                            }
                        }
                    }
                }

                print("[WallpaperEngineXBridge] ✅ 屏幕 \(screenID) 热切换完成 (pid=\(existingInfo.pid))")
                continue
            }

            // ── 情况 B：首次启动该屏幕 → 清理旧状态后启动新进程 ──
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

            if screenProcesses[screenID] != nil {
                await stopScreenProcess(screenID)
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

            // 初始裁切
            let cropSettings = DisplayCropSettingsStore.shared.settings(for: screen)
            let initialLayout: (crop: UnitRect, viewport: UnitRect)? = {
                guard cropSettings.shouldApplyCrop else { return nil }
                let wallpaperSize = readCanvasSize(url: canvasSizeURL) ?? CGSize(width: screenW, height: screenH)
                let layout = CropLayoutEngine.compute(
                    wallpaperSize: wallpaperSize,
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
                    wallpaperControlURL: wallpaperControlURL
                )
                screenRenderStates[screenID] = ScreenRenderState(
                    screenID: screenID,
                    screenFingerprint: screen.wallpaperScreenFingerprint,
                    path: resolvedPath,
                    renderKind: renderKind,
                    userProperties: userProperties
                )
                _deinitPIDs.insert(launchedPID)
                print("[WallpaperEngineXBridge] ✅ 屏幕 \(screenID) wallpaper-wgpu 已启动 (pid=\(launchedPID))")

                // 异步等待 canvas_size 就绪后重算 crop
                if cropSettings.shouldApplyCrop {
                    let cropSettingsCopy = cropSettings
                    let cropControlURLCopy = cropControlURL
                    let canvasSizeURLCopy = canvasSizeURL
                    let screenW_c = screenW
                    let screenH_c = screenH
                    let genCopy = self.launchGeneration
                    let screenIDCopy = screenID
                    Task { @MainActor [weak self] in
                        let deadline = Date().addingTimeInterval(5.0)
                        while Date() < deadline {
                            try? await Task.sleep(nanoseconds: 100_000_000)
                            guard let self else { return }
                            guard self.launchGeneration == genCopy,
                                  self.screenProcesses[screenIDCopy]?.generation == genCopy else { return }
                            if let realSize = self.readCanvasSize(url: canvasSizeURLCopy) {
                                let layout = CropLayoutEngine.compute(
                                    wallpaperSize: realSize,
                                    screenSize: CGSize(width: screenW_c, height: screenH_c),
                                    settings: cropSettingsCopy)
                                let vp = layout.viewportRect
                                let isFullVp = abs(vp.x) < 1e-4 && abs(vp.y) < 1e-4
                                    && abs(vp.w - 1) < 1e-4 && abs(vp.h - 1) < 1e-4
                                self.writeCropControl(url: cropControlURLCopy, crop: layout.wallpaperCropRect, viewport: isFullVp ? nil : vp)
                                print("[WallpaperEngineXBridge] 屏幕 \(screenIDCopy) canvas_size 就绪 (\(Int(realSize.width))×\(Int(realSize.height)))，crop 已按真实尺寸重算并热更新")
                                return
                            }
                        }
                        print("[WallpaperEngineXBridge] ⚠️ 屏幕 \(screenIDCopy) 等待 canvas_size 超时，沿用 fallback crop")
                    }
                }
            } catch {
                print("[WallpaperEngineXBridge] ❌ 屏幕 \(screenID) 启动失败: \(error.localizedDescription)")
                removeScreenProcess(screenID)
                screenRenderStates.removeValue(forKey: screenID)
                anyLaunchFailed = true
                lastLaunchError = error
            }
        }

        // 所有屏幕都失败才抛异常；部分成功则继续
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

        updateControlStateFromScreenStates(preferredPath: resolvedPath, preferredKind: renderKind)
        persistState()
        // 清除旧的前台暂停状态，避免 reevaluateCurrentState() 对新启动的渲染器误发 SIGSTOP。
        // 用户之后切走应用时，NSWorkspace app activation 通知会重新施加前台暂停。
        DynamicWallpaperAutoPauseManager.shared.clearForegroundPauseForWallpaperSwitch()
        DynamicWallpaperAutoPauseManager.shared.reevaluateCurrentState()

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
            Task { try? await Self.runLegacyCLIClientCommand(["pause"]) }
            webRenderer.pause()
        }
        guard isControllingExternalEngine else { return }
        isExternalPaused = true
        updateRendererAudioControls(paused: true)
        // 暂停时释放 SCK；恢复时由 resumeWallpaper 根据当前壁纸重启
        if audioRelayActiveForCurrentWallpaper {
            wasAudioRelayActiveBeforePause = true
            stopAudioRelayIfActive()
        }
        let generation = launchGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.isExternalPaused, self.launchGeneration == generation else { return }
            for (screenID, info) in self.screenProcesses {
                kill(info.pid, SIGSTOP)
                print("[WallpaperEngineXBridge] 暂停渲染 屏幕 \(screenID) (pid=\(info.pid))")
            }
        }
    }

    /// 恢复渲染（发送 SIGCONT）
    func resumeWallpaper() {
        if screenRenderStates.values.contains(where: { $0.renderKind == .web }) || activeRenderKind == .web {
            Task { try? await Self.runLegacyCLIClientCommand(["resume"]) }
            webRenderer.resume()
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
        if wasAudioRelayActiveBeforePause, let path = lastWallpaperPath {
            ensureAudioRelayMatchesActiveWallpaper(projectRoot: path)
        }
        wasAudioRelayActiveBeforePause = false
    }

    /// 按屏幕暂停追踪：通过 per-screen API 暂停的屏幕 ID
    /// 与全局 `isExternalPaused` 独立，用于支持 AutoPauseManager 按屏幕暂停/恢复外部引擎
    private var perScreenPausedScreenIDs: Set<String> = []

    /// 暂停指定屏幕的渲染（发送 SIGSTOP，按屏幕粒度）
    func pauseWallpaper(for screenID: String) {
        guard isControllingExternalEngine, let info = screenProcesses[screenID] else { return }
        kill(info.pid, SIGSTOP)
        perScreenPausedScreenIDs.insert(screenID)
        print("[WallpaperEngineXBridge] 暂停渲染 屏幕 \(screenID) (pid=\(info.pid))")

        // 如果所有进程都已被按屏幕暂停，同步全局暂停标志
        if perScreenPausedScreenIDs.count == screenProcesses.count {
            isExternalPaused = true
            updateRendererAudioControls(paused: true)
        }
    }

    /// 恢复指定屏幕的渲染（发送 SIGCONT，按屏幕粒度）
    func resumeWallpaper(for screenID: String) {
        guard isControllingExternalEngine, let info = screenProcesses[screenID] else { return }
        kill(info.pid, SIGCONT)
        perScreenPausedScreenIDs.remove(screenID)
        print("[WallpaperEngineXBridge] 恢复渲染 屏幕 \(screenID) (pid=\(info.pid))")
        // 只要有任意屏幕恢复，清除全局暂停标志
        if isExternalPaused {
            isExternalPaused = false
            updateRendererAudioControls(paused: false)
        }
    }

    /// 检查指定 screenID 是否被外部引擎管理且有活跃渲染进程
    func isManaging(screenID: String) -> Bool {
        screenProcesses[screenID] != nil
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
    private func sendAudioControlToWebDaemon(muted: Bool?, volume: Double?) {
        let socketPath = "/tmp/wallpaperengine-cli.sock"
        let msg = WebDaemonAudioMessage(command: "audioControl", muted: muted, volume: volume)
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
        let socketPath = "/tmp/wallpaperengine-cli.sock"
        let msg = WebDaemonAudioDataMessage(command: "audioData", spectrum: spectrum128)
        guard let data = try? JSONEncoder().encode(msg) else { return }

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
            // 不 recv：daemon 不发响应；shutdown(SHUT_WR) 让对端读到 EOF 后干净关闭，
            // 避免半开连接堆积。daemon 已 SIGPIPE IGN，残留写不会 KILL 进程。
            shutdown(fd, SHUT_WR)
        }
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

    /// 单点真相：扫描所有屏幕当前 web 壁纸的 project.json，
    /// 只要有任意一块屏正在跑需要音频的 web 壁纸，就启 relay；否则停。
    /// 任何会改变 `screenRenderStates` 或新增/停止 web 渲染的路径都应该在尾部调用一次。
    func ensureAudioRelayMatchesActiveWallpaper(projectRoot: String? = nil) {
        var needsAudio = false
        // 扫描已记录的 per-screen 状态
        for state in screenRenderStates.values where state.renderKind == .web {
            let projectJSON = URL(fileURLWithPath: state.path).appendingPathComponent("project.json")
            if Self.wallpaperRequiresAudio(projectJSONURL: projectJSON) {
                needsAudio = true
                break
            }
        }
        // 兜底：调用方明确传入的 projectRoot（刚 setWebWallpaper 完，可能 recordRenderState 还未到）
        if !needsAudio, let projectRoot {
            let projectJSON = URL(fileURLWithPath: projectRoot).appendingPathComponent("project.json")
            if Self.wallpaperRequiresAudio(projectJSONURL: projectJSON) {
                needsAudio = true
            }
        }

        if needsAudio && !audioRelayActiveForCurrentWallpaper {
            WallpaperWebAudioRelay.shared.start()
            audioRelayActiveForCurrentWallpaper = true
        } else if !needsAudio && audioRelayActiveForCurrentWallpaper {
            WallpaperWebAudioRelay.shared.stop()
            audioRelayActiveForCurrentWallpaper = false
        }
    }

    /// 任何"完全停止外部引擎/暂停"的路径必须调用，确保 relay 不残留 SCK。
    func stopAudioRelayIfActive() {
        guard audioRelayActiveForCurrentWallpaper else { return }
        WallpaperWebAudioRelay.shared.stop()
        audioRelayActiveForCurrentWallpaper = false
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
        webRenderer.stop()
        Task { try? await Self.runLegacyCLIClientCommand(["stop"]) }
        stopAudioRelayIfActive()
        isControllingExternalEngine = false
        isExternalPaused = false
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
        print("[WallpaperEngineXBridge] ensureStoppedForNonCLIWallpaper: 开始清理 \(processCount) 个渲染进程")
        if #available(macOS 26.0, *) {
            LockScreenWallpaperService.shared.clearRealtimeSourceIfNeeded()
        }
        stopRenderProcess()
        // 同步杀掉旧 CLI daemon（fire-and-forget 的 client 命令在 App 退出场景来不及发出，
        // 且 stop client 自己还会再 fork daemon — 直接按 PID kill 最稳妥）
        Task { await Self.killLegacyDaemonIfRunning(waitForExit: false) }
        webRenderer.stop()
        activeRenderKind = nil
        stopAudioRelayIfActive()
        isControllingExternalEngine = false
        isExternalPaused = false
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
            print("[WallpaperEngineXBridge] ensureStoppedForNonCLIWallpaper(for:): targetScreen 为 nil，转为全量清理")
            ensureStoppedForNonCLIWallpaper()
            return
        }

        let screenID = targetScreen.wallpaperScreenIdentifier
        guard isManaging(screen: targetScreen) else {
            print("[WallpaperEngineXBridge] ensureStoppedForNonCLIWallpaper(for:): 屏幕 \(screenID) 不受外部引擎管理，跳过")
            return
        }
        print("[WallpaperEngineXBridge] ensureStoppedForNonCLIWallpaper(for:): 清理屏幕 \(screenID) 的渲染进程")

        if #available(macOS 26.0, *) {
            LockScreenWallpaperService.shared.clearRealtimeSourceIfNeeded()
        }
        let targetState = renderState(for: targetScreen)
        if targetState?.renderKind == .web || (targetState == nil && activeRenderKind == .web) {
            webRenderer.stop()
            Task { await Self.killLegacyDaemonIfRunning(waitForExit: false) }
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
        updateControlStateFromScreenStates()
        // 这块屏被切走后，全局可能不再有需要音频的 web 壁纸了
        ensureAudioRelayMatchesActiveWallpaper()
        persistState()
    }

    /// 应用退出前调用：立即杀死所有渲染进程，不等待退出，避免阻塞主线程导致 App 卡死。
    func prepareForAppTermination() {
        let processCount = screenProcesses.count
        let pids = screenProcesses.values.map { "\($0.pid)" }.joined(separator: ", ")
        print("[WallpaperEngineXBridge] prepareForAppTermination: 应用退出，立即终止 \(processCount) 个渲染进程 pids=[\(pids)]")
        // 直接 SIGKILL 所有屏幕渲染进程，不做 graceful terminate + 等待
        for (_, info) in screenProcesses {
            kill(info.pid, SIGKILL)
        }
        // 同步杀掉旧 CLI daemon
        Self.killLegacyDaemonSync()
        closeRendererLogs()
        screenProcesses.removeAll()
        _deinitPIDs.removeAll()
        screenWatchdogs.values.forEach { $0.cancel() }
        screenWatchdogs.removeAll()
        webRenderer.stop()
        stopAudioRelayIfActive()
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

    private func setWebWallpaper(path: String, targetScreens: [NSScreen]?) async throws {
        let screenIndex: Int?
        if let screen = targetScreens?.first {
            screenIndex = NSScreen.screens.firstIndex(of: screen)
        } else {
            screenIndex = nil
        }

        // ✅ Web 壁纸改走旧 wallpaperengine-cli：daemon 自带 WKWebView 桥，能正确处理 web 类型项目。
        //    原内置 WebRendererBridge 在新流程中已不参与启动，仅作为停止时的清场调用保留。
        var args = ["set", path]
        if let idx = screenIndex {
            args.append(String(idx))
        }

        print("[WallpaperEngineXBridge] 使用旧 wallpaperengine-cli 设置 Web 壁纸: \(path) screenIdx=\(screenIndex.map(String.init) ?? "all")")
        try? FileManager.default.removeItem(atPath: legacyCLIWebCapturePath)
        let status = try await Self.runLegacyCLIClientCommand(args)
        guard status == 0 else {
            throw WallpaperEngineError.executionFailed("wallpaperengine-cli set 失败 (exit=\(status))")
        }

        if let propertiesJSON = try? WebWallpaperDesignService.shared.effectivePropertiesJSON(for: path),
           !propertiesJSON.isEmpty {
            try? await applyWebWallpaperProperties(propertiesJSON)
        }

        let captureURL = await captureWebFallbackFrameForLockScreenIfNeeded()
        await syncWebStaticFrameToLockScreenIfNeeded(imageURL: captureURL, targetScreens: targetScreens)

        // 初始化 Web 壁纸的音频状态（同步当前 mute/volume）
        let isMuted = VideoWallpaperManager.shared.isMuted
        let volume = VideoWallpaperManager.shared.volume
        sendAudioControlToWebDaemon(muted: isMuted, volume: isMuted ? nil : volume)
    }

    private func syncWebStaticFrameToLockScreenIfNeeded(imageURL: URL?, targetScreens: [NSScreen]?) async {
        guard #available(macOS 26.0, *) else { return }
        guard VideoWallpaperManager.shared.isLockScreenEnabled else { return }
        guard UserDefaults.standard.object(forKey: "dynamic_lock_screen_enabled") as? Bool ?? true else { return }
        guard let imageURL, FileManager.default.fileExists(atPath: imageURL.path) else {
            print("[WallpaperEngineXBridge] ⚠️ Web 锁屏静态帧未生成，跳过扩展静态图同步")
            return
        }

        let screens = targetScreens?.isEmpty == false ? targetScreens! : NSScreen.screens
        let displayIDs = screens.compactMap { screen -> UInt32? in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        }
        guard !displayIDs.isEmpty else {
            print("[WallpaperEngineXBridge] ⚠️ 未找到目标显示器，Web 锁屏静态帧同步已跳过")
            return
        }

        do {
            try await LockScreenWallpaperService.shared.cacheStaticImageSource(imageURL: imageURL, displayIDs: displayIDs)
            print("[WallpaperEngineXBridge] 🖼️ 已将 Web 首帧按静态图同步到锁屏扩展 display=\(displayIDs)")
        } catch {
            print("[WallpaperEngineXBridge] ⚠️ Web 锁屏静态帧同步失败: \(error.localizedDescription)")
        }
    }

    private func captureWebFallbackFrameForLockScreenIfNeeded() async -> URL? {
        guard #available(macOS 26.0, *) else { return nil }
        guard VideoWallpaperManager.shared.isLockScreenEnabled else { return nil }
        guard UserDefaults.standard.object(forKey: "dynamic_lock_screen_enabled") as? Bool ?? true else { return nil }

        if FileManager.default.fileExists(atPath: legacyCLIWebCapturePath) {
            return URL(fileURLWithPath: legacyCLIWebCapturePath)
        }

        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 120_000_000)
            if FileManager.default.fileExists(atPath: legacyCLIWebCapturePath) {
                return URL(fileURLWithPath: legacyCLIWebCapturePath)
            }
        }

        return nil
    }

    /// 启动旧 `wallpaperengine-cli` 的客户端子命令（set/pause/resume/stop）。
    /// 这些命令仅作为 IPC 客户端，向 daemon 发完消息就退出；真正的 web 渲染由 daemon 持有。
    @discardableResult
    private static func runLegacyCLIClientCommand(_ arguments: [String]) async throws -> Int32 {
        guard let cli = SceneOfflineBakeService.resolvedLegacyCLIExecutableURL() else {
            throw WallpaperEngineError.cliNotFound
        }
        let env = legacyCLILaunchEnvironment(for: cli)
        let processTask = Task.detached(priority: .userInitiated) { () throws -> Int32 in
            let process = Process()
            process.executableURL = cli
            process.arguments = arguments
            process.environment = env
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
        return try await processTask.value
    }

    func applyWebWallpaperProperties(_ propertiesJSON: String) async throws {
        guard isCurrentWallpaperWeb else {
            throw WallpaperEngineError.executionFailed("当前没有运行中的 Web 壁纸")
        }
        let status = try await Self.runLegacyCLIClientCommand(["apply-properties", propertiesJSON])
        guard status == 0 else {
            throw WallpaperEngineError.executionFailed("Web 壁纸属性热更新失败 (exit=\(status))")
        }
    }

    /// 给旧 CLI 客户端进程拼装 DYLD 路径，复用 `bakeWithLegacyCLI` 的搜索策略。
    private static func legacyCLILaunchEnvironment(for cli: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["LSUIElement"] = "1"
        if #available(macOS 26.0, *) {
            env["WAIFUX_DYNAMIC_LOCK_SCREEN_ENABLED"] = VideoWallpaperManager.shared.isLockScreenEnabled ? "1" : "0"
        } else {
            env["WAIFUX_DYNAMIC_LOCK_SCREEN_ENABLED"] = "0"
        }
        let execDir = cli.deletingLastPathComponent()
        let dylibCandidates = [
            execDir.path,
            execDir.appendingPathComponent("lib").path,
            execDir.appendingPathComponent("Resources").path,
            execDir.appendingPathComponent("Resources/lib").path,
            execDir.deletingLastPathComponent().appendingPathComponent("Resources/lib").path,
            execDir.deletingLastPathComponent().appendingPathComponent("Frameworks").path
        ]
        var libPaths: [String] = []
        if let existing = env["DYLD_LIBRARY_PATH"], !existing.isEmpty {
            libPaths.append(existing)
        }
        for candidate in dylibCandidates {
            let p = candidate + "/liblinux-wallpaperengine-renderer.dylib"
            if FileManager.default.fileExists(atPath: p) {
                libPaths.append(candidate)
            }
        }
        if !libPaths.isEmpty {
            env["DYLD_LIBRARY_PATH"] = libPaths.joined(separator: ":")
        }
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
        kill(pid, SIGTERM)
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
                userProperties: userProperties
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

    /// 读取 wgpu 写出的 canvas 尺寸 JSON。读不到/解析失败返回 nil（调用方 fallback 屏尺寸）。
    private func readCanvasSize(url: URL?) -> CGSize? {
        guard let url = url else { return nil }
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let w = obj["width"] as? Double, let h = obj["height"] as? Double,
              w > 0, h > 0 else { return nil }
        return CGSize(width: w, height: h)
    }

    /// 供 overlay 预览取 wgpu canvas 尺寸（scene 就绪后才有值）。
    func canvasSize(for screen: NSScreen) -> CGSize? {
        let screenID = screen.wallpaperScreenIdentifier
        let info = screenProcesses[screenID]
            ?? screenProcesses.values.first(where: { $0.screenID == screenID })
        return readCanvasSize(url: info?.canvasSizeURL)
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
    private func writeWallpaperControl(url: URL, setWallpaper: String?, assets: String?, setProperties: String?) {
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
        do {
            let data = try JSONSerialization.data(withJSONObject: dict, options: [])
            try data.write(to: url, options: .atomic)
            print("[WallpaperEngineXBridge] 已写入壁纸控制文件: \(setWallpaper != nil ? "切换壁纸" : "仅更新属性")")
        } catch {
            print("[WallpaperEngineXBridge] ⚠️ 写入壁纸控制文件失败: \(error.localizedDescription)")
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
        if state?.renderKind == .web {
            screenRenderStates = screenRenderStates.filter { $0.value.renderKind != .web }
        } else if let state {
            screenRenderStates.removeValue(forKey: state.screenID)
        } else {
            screenRenderStates.removeValue(forKey: screenID)
        }
    }

    private func removeScreenProcess(_ screenID: String) {
        if let info = screenProcesses.removeValue(forKey: screenID) {
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
        targetScreenIDs = Set(screenRenderStates.values.map(\.screenID))
        targetScreenFingerprints = Set(screenRenderStates.values.map(\.screenFingerprint))
        isControllingExternalEngine = !screenRenderStates.isEmpty
        if let preferredPath {
            lastWallpaperPath = preferredPath
        } else {
            lastWallpaperPath = screenRenderStates.values.first?.path
        }
        if let preferredKind {
            activeRenderKind = preferredKind
        } else {
            activeRenderKind = screenRenderStates.values.first?.renderKind
        }
        if screenRenderStates.isEmpty {
            isExternalPaused = false
            activeRenderKind = nil
            lastAppliedScreenConfigurations.removeAll()
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
                    userProperties: state.userProperties
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

    /// 合并用户属性 JSON 与场景配置覆盖（__-prefixed system keys）
    /// 场景配置覆盖由 SceneConfigOverrideService 管理，两者合并为单一 JSON 传给 --user-properties
    private static func mergeSceneConfigOverrides(_ userProperties: String?, wallpaperPath: String) -> String? {
        SceneConfigOverrideService.mergedPropertiesJSON(
            userPropertiesJSON: userProperties,
            for: wallpaperPath
        )
    }

    /// 使用 CoreGraphics 查找指定进程的窗口，返回 CGWindowID
    /// ⚠️ 调用方需确保已有屏幕录制权限，否则 macOS 26 会 EXC_BREAKPOINT
    private func findWindowForProcess(pid: pid_t) -> CGWindowID? {
        guard let windowList = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for window in windowList {
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? Int, ownerPID == pid else { continue }
            guard let windowID = window[kCGWindowNumber as String] as? CGWindowID else { continue }
            guard let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let width = Int(bounds["Width"] ?? 0)
            let height = Int(bounds["Height"] ?? 0)
            guard width >= 100, height >= 100 else { continue }
            return windowID
        }
        return nil
    }

    // MARK: - 首帧捕获（锁屏 / 静态 fallback）

    /// 壁纸路径的缓存 key，用于判断是否已捕过帧
    private static func frameCacheKey(for path: String) -> String {
        let hash = abs(path.hashValue)
        return "cached_frame_\(hash)"
    }

    /// 捕获首帧并设为静态桌面壁纸（锁屏显示 + wallpaper-wgpu 未运行时的 fallback）
    private func captureStaticFallbackFrame(path: String, expectedPID: pid_t? = nil) async -> Bool {
        // 权限检查（CGWindowListCreateImage 无权限时会 EXC_BREAKPOINT）
        guard checkScreenCapturePermission() else {
            print("[WallpaperEngineXBridge] ❌ 无屏幕录制权限，无法捕获真实首帧")
            return false
        }

        let cacheKey = Self.frameCacheKey(for: path)
        print("[WallpaperEngineXBridge] 每次设置 Scene 壁纸都重新捕获静态帧: \(cacheKey)")

        guard let pid = expectedPID ?? screenProcesses.values.first?.pid else { return false }
        guard expectedPID == nil || screenProcesses.values.contains(where: { $0.pid == expectedPID }) else { return false }

        // 查找渲染窗口
        guard let windowID = findWindowForProcess(pid: pid) else {
            print("[WallpaperEngineXBridge] ⚠️ 未找到渲染窗口，无法捕获真实首帧")
            return false
        }

        // 轮询等待非黑帧
        let minimumCaptureWarmup: TimeInterval = 8.0
        let timeout: TimeInterval = 25
        let pollInterval: TimeInterval = 0.5
        let startTime = Date()
        var lastFrame: CGImage?

        while Date().timeIntervalSince(startTime) < timeout {
            guard screenProcesses.values.contains(where: { $0.pid == pid }), kill(pid, 0) == 0 else { return false } // 进程已退出或已切换

            if let image = captureWindowFrame(windowID: windowID) {
                // 至少等待更久让场景完成暗到亮的加载，避免缓存黑屏/暗场帧
                if Date().timeIntervalSince(startTime) >= minimumCaptureWarmup, isNonBlackFrame(image) {
                    // 找到有效帧，保存并设静态壁纸
                    return saveAndApplyStaticFrame(image, for: path, cacheKey: cacheKey)
                }
                lastFrame = image
            }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }

        // 超时：用最后一帧（即使可能偏黑）
        if let frame = lastFrame {
            print("[WallpaperEngineXBridge] ⚠️ 首帧捕获超时，使用最后一帧")
            return saveAndApplyStaticFrame(frame, for: path, cacheKey: cacheKey)
        } else {
            print("[WallpaperEngineXBridge] ❌ 首帧捕获失败（无任何帧）")
            return false
        }
    }

    /// 保存帧到缓存并设为静态壁纸
    private func saveAndApplyStaticFrame(_ image: CGImage, for path: String, cacheKey: String) -> Bool {
        // 保存到缓存目录
        let cacheDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Caches/com.waifux.wallpaperengine/captured-frames")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let fileURL = cacheDir.appendingPathComponent("\(cacheKey).jpg")

        // 写入 JPEG
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
            print("[WallpaperEngineXBridge] ⚠️ JPEG 编码失败")
            return false
        }
        do {
            try jpegData.write(to: fileURL)
            print("[WallpaperEngineXBridge] ✅ 首帧已保存: \(fileURL.path)")
        } catch {
            print("[WallpaperEngineXBridge] ⚠️ 首帧写入失败: \(error.localizedDescription)")
            return false
        }

        // 标记已缓存
        UserDefaults.standard.set(fileURL.path, forKey: cacheKey)

        if #available(macOS 26.0, *), VideoWallpaperManager.shared.isLockScreenEnabled {
            print("[WallpaperEngineXBridge] 🔒 动态锁屏已启用，跳过静态 fallback 壁纸设置以保护用户锁屏选择")
            return false
        }

        // 设为静态桌面壁纸（锁屏会跟随使用此壁纸）
        let fillOptions: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSImageScaling.scaleAxesIndependently.rawValue,
            .fillColor: NSColor.black
        ]
        var didApply = false
        let screens = activeTargetScreens()
        for screen in screens.isEmpty ? NSScreen.screens : screens {
            do {
                try NSWorkspace.shared.setDesktopImageURLForAllSpaces(fileURL, for: screen, options: fillOptions)
                DesktopWallpaperSyncManager.shared.registerWallpaperSet(fileURL, for: screen, options: fillOptions)
                print("[WallpaperEngineXBridge] ✅ 静态 fallback 壁纸已设置 (screen: \(screen.localizedName))")
                didApply = true
            } catch {
                print("[WallpaperEngineXBridge] ⚠️ 设置静态壁纸失败 (screen: \(screen.localizedName)): \(error.localizedDescription)")
            }
        }
        return didApply
    }

    /// 使用 CoreGraphics 捕获窗口帧
    /// ⚠️ 调用方需确保已有屏幕录制权限，否则 macOS 26 会 EXC_BREAKPOINT
    private func captureWindowFrame(windowID: CGWindowID) -> CGImage? {
        CGWindowListCreateImage(
            .infinite,
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming, .nominalResolution]
        )
    }

    /// 判断帧是否为非黑的有效帧
    private func isNonBlackFrame(_ image: CGImage) -> Bool {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return false }

        // 采样中心 1/4 区域
        let sampleRect = CGRect(
            x: width / 4,
            y: height / 4,
            width: width / 2,
            height: height / 2
        )
        guard let cropped = image.cropping(to: sampleRect) else { return false }
        guard let dataProvider = cropped.dataProvider else { return false }
        guard let pixelData = dataProvider.data else { return false }
        let data: UnsafePointer<UInt8> = CFDataGetBytePtr(pixelData)
        let bytesPerRow = cropped.bytesPerRow

        var totalBrightness: UInt64 = 0
        var pixelCount: UInt64 = 0

        for y in 0..<cropped.height {
            let rowOffset = y * bytesPerRow
            for x in 0..<cropped.width {
                let offset = rowOffset + x * 4
                let r = UInt64(data[offset + 1])
                let g = UInt64(data[offset + 2])
                let b = UInt64(data[offset + 3])
                totalBrightness += (r + g + b) / 3
                pixelCount += 1
            }
        }

        guard pixelCount > 0 else { return false }
        let avgBrightness = Double(totalBrightness) / Double(pixelCount)
        return avgBrightness > 10.0
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

    private func relinkTargetScreens() {
        for screen in NSScreen.screens where targetScreenFingerprints.contains(screen.wallpaperScreenFingerprint) {
            targetScreenIDs.insert(screen.wallpaperScreenIdentifier)
        }
    }

    /// 可视区域 crop 变更：把最新裁切写入该屏的 `--crop-control` JSON，wgpu 50ms 内热更新。
    /// 不再重启进程；拖拽和落定都共享同一通路，避免进程频繁起停。
    @MainActor
    private func handleCropDidChange(_ note: Notification) {
        guard isControllingExternalEngine else { return }
        guard !isSettingWallpaper else { return }
        guard let screenID = note.userInfo?["screenID"] as? String,
              let screen = NSScreen.screens.first(where: { $0.wallpaperScreenIdentifier == screenID }),
              isManaging(screen: screen),
              !isWebWallpaperOn(screen: screen) else { return }
        // 找到该屏（或同 fingerprint）的运行进程及其 cropControlURL
        let info = screenProcesses[screenID]
            ?? screenProcesses.values.first(where: { $0.screenID == screenID })
        guard let cropControlURL = info?.cropControlURL else { return }

        let cropSettings = DisplayCropSettingsStore.shared.settings(for: screen)
        let f = screen.frame
        let screenW = Int(f.width.rounded())
        let screenH = Int(f.height.rounded())
        let nextCrop: UnitRect?
        let nextViewport: UnitRect?
        if cropSettings.shouldApplyCrop {
            // 读 wgpu 写出的 canvas 尺寸；读不到 fallback 屏尺寸。
            let wallpaperSize = readCanvasSize(url: info?.canvasSizeURL) ?? CGSize(width: screenW, height: screenH)
            let layout = CropLayoutEngine.compute(
                wallpaperSize: wallpaperSize,
                screenSize: CGSize(width: screenW, height: screenH),
                settings: cropSettings)
            nextCrop = layout.wallpaperCropRect
            // 全屏 viewport 等价于 None
            let vp = layout.viewportRect
            let isFullVp = abs(vp.x) < 1e-4 && abs(vp.y) < 1e-4
                && abs(vp.w - 1) < 1e-4 && abs(vp.h - 1) < 1e-4
            nextViewport = isFullVp ? nil : vp
        } else {
            nextCrop = nil
            nextViewport = nil
        }
        writeCropControl(url: cropControlURL, crop: nextCrop, viewport: nextViewport)
    }

    private func handleScreenParametersChanged() {
        guard isControllingExternalEngine else { return }
        guard !isSettingWallpaper else {
            print("[WallpaperEngineXBridge] 忽略屏幕参数通知：壁纸正在设置中")
            return
        }
        let statesBeforeRestart = screenRenderStates

        relinkTargetScreens()
        let currentConfigurations = currentTargetScreenConfigurations()
        guard currentConfigurations != lastAppliedScreenConfigurations else {
            print("[WallpaperEngineXBridge] 忽略屏幕参数通知：目标显示器配置未变化")
            return
        }

        screenChangeRestartWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.isControllingExternalEngine, !self.isSettingWallpaper else { return }
            self.relinkTargetScreens()
            guard self.currentTargetScreenConfigurations() != self.lastAppliedScreenConfigurations else {
                print("[WallpaperEngineXBridge] 跳过屏幕变化重启：目标显示器配置已恢复一致")
                return
            }

            let screens = self.activeTargetScreens()
            Task {
                print("[WallpaperEngineXBridge] 屏幕参数已变更，重启渲染进程")
                if !statesBeforeRestart.isEmpty {
                    for screen in screens {
                        let screenID = screen.wallpaperScreenIdentifier
                        let fingerprint = screen.wallpaperScreenFingerprint
                        guard let state = statesBeforeRestart[screenID] ?? statesBeforeRestart.values.first(where: { $0.screenFingerprint == fingerprint }) else {
                            continue
                        }
                        let userProps = state.userProperties ?? SceneWallpaperPropertiesService.propertiesOverrideJSON(for: state.path)
                        try? await self.setWallpaper(path: state.path, targetScreens: [screen], userProperties: userProps, forceRestart: true)
                    }
                } else if let path = self.lastWallpaperPath {
                    let userProps = SceneWallpaperPropertiesService.propertiesOverrideJSON(for: path)
                    try? await self.setWallpaper(path: path, targetScreens: screens.isEmpty ? nil : screens, userProperties: userProps, forceRestart: true)
                }
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

// MARK: - Web 壁纸旧流程（WKWebView）

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
        print("[WebRendererBridge] extractPKG failed: \(error.localizedDescription)")
        return nil
    }
}

private func steamWorkshopContentInstallRootIfApplicable(forProjectDir projectDir: URL) -> URL? {
    let comps = projectDir.standardizedFileURL.pathComponents
    guard let idx = comps.firstIndex(of: "431960"), idx + 1 < comps.count else {
        return nil
    }
    let prefix = comps.prefix(through: idx + 1)
    let path = "/" + prefix.dropFirst().joined(separator: "/")
    let url = URL(fileURLWithPath: path, isDirectory: true)
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
        return nil
    }
    return url
}

private func webWallpaperFileReadAccessURL(projectContentDir: URL, wallpaperPath: String) -> URL {
    if wallpaperPath.contains("/steamapps/workshop/content/"),
       let root = steamWorkshopContentInstallRootIfApplicable(forProjectDir: projectContentDir) {
        return root
    }
    return projectContentDir
}

private func resolveWallpaperDependencyPath(from contentDir: URL, dependencyID: String) -> URL? {
    let fm = FileManager.default
    let sibling = contentDir.deletingLastPathComponent().appendingPathComponent(dependencyID)
    if fm.fileExists(atPath: sibling.path) { return sibling }

    var current = contentDir
    for _ in 0..<6 {
        current = current.deletingLastPathComponent()
        let candidate = current.appendingPathComponent("steamapps/workshop/content/431960/\(dependencyID)")
        if fm.fileExists(atPath: candidate.path) { return candidate }
    }
    return nil
}

private func mergeWallpaperWithDependency(contentDir: URL, dependencyDir: URL) -> URL? {
    let fm = FileManager.default
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("wallpaperengine_merged_\(contentDir.lastPathComponent)_\(dependencyDir.lastPathComponent)_\(UUID().uuidString.prefix(8))")
    do {
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        if let depEntries = try? fm.contentsOfDirectory(at: dependencyDir, includingPropertiesForKeys: nil) {
            for entry in depEntries {
                let dest = tempDir.appendingPathComponent(entry.lastPathComponent)
                if !fm.fileExists(atPath: dest.path) {
                    try? fm.copyItem(at: entry, to: dest)
                }
            }
        }
        if let entries = try? fm.contentsOfDirectory(at: contentDir, includingPropertiesForKeys: nil) {
            for entry in entries {
                let dest = tempDir.appendingPathComponent(entry.lastPathComponent)
                if fm.fileExists(atPath: dest.path) {
                    try? fm.removeItem(at: dest)
                }
                try? fm.copyItem(at: entry, to: dest)
            }
        }
        return tempDir
    } catch {
        print("[WebRendererBridge] dependency merge failed: \(error.localizedDescription)")
        return nil
    }
}

private func resolveWebWallpaperEntry(path: String) -> (baseURL: URL, indexFile: String)? {
    let url = URL(fileURLWithPath: path)
    let contentDir: URL
    if url.pathExtension.lowercased() == "pkg" {
        guard let extracted = extractPKG(at: url) else { return nil }
        contentDir = extracted
    } else {
        contentDir = WorkshopService.resolveWallpaperEngineProjectRoot(startingAt: url)
    }

    let projectJSON = contentDir.appendingPathComponent("project.json")
    guard FileManager.default.fileExists(atPath: projectJSON.path),
          let data = try? Data(contentsOf: projectJSON),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        if url.pathExtension.lowercased() == "html" || url.pathExtension.lowercased() == "htm" {
            return (url.deletingLastPathComponent(), url.lastPathComponent)
        }
        let index = contentDir.appendingPathComponent("index.html")
        return FileManager.default.fileExists(atPath: index.path) ? (contentDir, "index.html") : nil
    }

    let file = json["file"] as? String ?? "index.html"
    if let dependency = json["dependency"] as? String, !dependency.isEmpty,
       let depDir = resolveWallpaperDependencyPath(from: contentDir, dependencyID: dependency),
       let merged = mergeWallpaperWithDependency(contentDir: contentDir, dependencyDir: depDir) {
        if FileManager.default.fileExists(atPath: merged.appendingPathComponent(file).path) {
            return (merged, file)
        }
        if FileManager.default.fileExists(atPath: merged.appendingPathComponent("index.html").path) {
            return (merged, "index.html")
        }
        try? FileManager.default.removeItem(at: merged)
    }

    if FileManager.default.fileExists(atPath: contentDir.appendingPathComponent(file).path) {
        return (contentDir, file)
    }
    if FileManager.default.fileExists(atPath: contentDir.appendingPathComponent("index.html").path) {
        return (contentDir, "index.html")
    }
    return nil
}

private func readWebWallpaperUserPropertiesJSON(contentDir: URL) -> String? {
    let projectURL = contentDir.appendingPathComponent("project.json")
    guard let data = try? Data(contentsOf: projectURL),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let general = json["general"] as? [String: Any],
          let props = general["properties"] as? [String: Any],
          !props.isEmpty,
          let out = try? JSONSerialization.data(withJSONObject: props, options: []),
          let str = String(data: out, encoding: .utf8) else {
        return nil
    }
    return str
}

private final class WebRendererBridge: NSObject, WKNavigationDelegate {
    static let shared = WebRendererBridge()

    private struct WebInteractionEvent: @unchecked Sendable {
        let type: String
        let screenX: Double
        let screenY: Double
        let button: Int
        let buttons: Int
        let clickCount: Int
        let deltaX: Double
        let deltaY: Double
        let key: String
        let code: String
        let keyCode: Int
        let ctrlKey: Bool
        let altKey: Bool
        let shiftKey: Bool
        let metaKey: Bool
    }

    private static let wallpaperEngineWebAPIShim = WKUserScript(
        source: """
        (function() {
          try {
            window.wallpaperMediaIntegration = { playback: { PLAYING: 1, PAUSED: 2, STOPPED: 0 } };
            var __wxAudioCbs = [];
            var __wxAudioBuf = new Float32Array(128);
            window.wallpaperRegisterAudioListener = function(cb) {
              if (typeof cb === 'function') __wxAudioCbs.push(cb);
            };
            setInterval(function() {
              for (var j = 0; j < __wxAudioCbs.length; j++) {
                try { __wxAudioCbs[j](__wxAudioBuf); } catch (e) {}
              }
            }, 33);
            window.wallpaperRegisterMediaStatusListener = function(cb) {
              if (typeof cb === 'function') {
                try { cb({ enabled: false }); } catch (e) {}
              }
            };
            window.wallpaperRegisterMediaPropertiesListener = function(cb) {};
            window.wallpaperRegisterMediaThumbnailListener = function(cb) {};
            window.wallpaperRegisterMediaPlaybackListener = function(cb) {
              if (typeof cb === 'function') {
                try { cb({ state: window.wallpaperMediaIntegration.playback.STOPPED }); } catch (e) {}
              }
            };
            window.wallpaperRegisterMediaTimelineListener = function(cb) {};
          } catch (e) {}
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false
    )

    private static let localFileCompatScript = WKUserScript(
        source: """
        (function() {
          try {
            if (location.protocol !== "file:") return;
            var proto = HTMLImageElement.prototype;
            var srcDesc = Object.getOwnPropertyDescriptor(proto, "src");
            if (srcDesc && srcDesc.set) {
              Object.defineProperty(proto, "src", {
                set: function(value) {
                  try {
                    var s = String(value || "");
                    if (s.indexOf("http:") !== 0 && s.indexOf("https:") !== 0 && s.indexOf("data:") !== 0 && s.indexOf("blob:") !== 0) {
                      this.removeAttribute("crossorigin");
                    }
                  } catch (e) {}
                  srcDesc.set.call(this, value);
                },
                get: srcDesc.get,
                configurable: true
              });
            }
            var origFetch = window.fetch;
            if (typeof origFetch === "function") {
              window.fetch = function(input, init) {
                var url = typeof input === "string" ? input : (input && input.url) ? input.url : "";
                if (url && url.indexOf("http:") !== 0 && url.indexOf("https:") !== 0 && url.indexOf("data:") !== 0 && url.indexOf("blob:") !== 0) {
                  return new Promise(function(resolve, reject) {
                    var xhr = new XMLHttpRequest();
                    xhr.open("GET", url, true);
                    xhr.responseType = "arraybuffer";
                    xhr.onload = function() {
                      if (xhr.status === 200 || xhr.status === 0) {
                        var headers = new Headers();
                        try {
                          var contentType = xhr.getResponseHeader("Content-Type");
                          if (contentType) headers.set("Content-Type", contentType);
                        } catch (e) {}
                        resolve(new Response(xhr.response, {
                          status: xhr.status === 0 ? 200 : xhr.status,
                          statusText: xhr.statusText || "OK",
                          headers: headers
                        }));
                      } else {
                        reject(new Error("HTTP " + xhr.status));
                      }
                    };
                    xhr.onerror = function() { reject(new Error("network error")); };
                    xhr.send();
                  });
                }
                return origFetch.call(this, input, init);
              };
            }
          } catch (e) {}
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false
    )

    private static let interactionBridgeScript = WKUserScript(
        source: """
        (function() {
          if (window.__waifuXDispatchInput) return;
          function targetAt(x, y) {
            return document.elementFromPoint(x, y) || document.body || document.documentElement || document;
          }
          function mouseInit(e) {
            return {
              bubbles: true,
              cancelable: true,
              composed: true,
              view: window,
              clientX: e.x || 0,
              clientY: e.y || 0,
              screenX: e.screenX || 0,
              screenY: e.screenY || 0,
              button: e.button || 0,
              buttons: e.buttons || 0,
              ctrlKey: !!e.ctrlKey,
              altKey: !!e.altKey,
              shiftKey: !!e.shiftKey,
              metaKey: !!e.metaKey
            };
          }
          function firePointer(target, type, init) {
            try {
              if (window.PointerEvent) {
                target.dispatchEvent(new PointerEvent(type, Object.assign({}, init, {
                  pointerId: 1,
                  pointerType: "mouse",
                  isPrimary: true
                })));
              }
            } catch (e) {}
          }
          window.__waifuXDispatchInput = function(e) {
            try {
              if (!e || !e.type) return;
              if (e.type === "keydown" || e.type === "keyup") {
                var keyTarget = document.activeElement || document.body || document.documentElement || document;
                var keyInit = {
                  bubbles: true,
                  cancelable: true,
                  composed: true,
                  key: e.key || "",
                  code: e.code || "",
                  keyCode: e.keyCode || 0,
                  which: e.keyCode || 0,
                  ctrlKey: !!e.ctrlKey,
                  altKey: !!e.altKey,
                  shiftKey: !!e.shiftKey,
                  metaKey: !!e.metaKey
                };
                keyTarget.dispatchEvent(new KeyboardEvent(e.type, keyInit));
                if (keyTarget !== window) window.dispatchEvent(new KeyboardEvent(e.type, keyInit));
                return;
              }

              var target = targetAt(e.x || 0, e.y || 0);
              var init = mouseInit(e);
              if (e.type === "wheel") {
                target.dispatchEvent(new WheelEvent("wheel", Object.assign({}, init, {
                  deltaX: e.deltaX || 0,
                  deltaY: e.deltaY || 0,
                  deltaMode: 0
                })));
                return;
              }

              var pointerType = {
                mousemove: "pointermove",
                mousedown: "pointerdown",
                mouseup: "pointerup"
              }[e.type];
              if (pointerType) firePointer(target, pointerType, init);
              target.dispatchEvent(new MouseEvent(e.type, init));
              if (e.type === "mouseup") {
                target.dispatchEvent(new MouseEvent("click", init));
                if ((e.clickCount || 0) >= 2) {
                  target.dispatchEvent(new MouseEvent("dblclick", init));
                }
              }
            } catch (err) {}
          };
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false
    )

    private var window: NSWindow?
    private var webView: WKWebView?
    private var pendingCompletion: ((Bool) -> Void)?
    private var extractedPKGDir: URL?
    private var mergedDependencyDir: URL?
    private var injectedPropertiesJSON: String?
    private var firstFrameSettleGeneration: UInt64 = 0
    private var currentScreenIndex: Int?
    private var desktopCaptureSlot = 0
    private var interactionMonitors: [Any] = []
    private(set) var isLoaded = false

    private enum FirstFramePolicy {
        static let minElapsed: TimeInterval = 6.0
        static let maxElapsed: TimeInterval = 24
        static let pollInterval: TimeInterval = 0.5
        static let diffThreshold: Double = 0.014
        static let stablePassesRequired: Int = 2
        static let thumbDimension: Int = 48
    }

    func loadWallpaper(path: String, width: Int, height: Int, screen: Int? = nil, completion: ((Bool) -> Void)? = nil) {
        stop()
        pendingCompletion = completion
        injectedPropertiesJSON = nil
        currentScreenIndex = screen

        guard let (baseURL, indexFile) = resolveWebWallpaperEntry(path: path) else {
            print("[WebRendererBridge] 无法解析 Web 壁纸入口: \(path)")
            completion?(false)
            return
        }

        injectedPropertiesJSON = readWebWallpaperUserPropertiesJSON(contentDir: baseURL)
        if URL(fileURLWithPath: path).pathExtension.lowercased() == "pkg" {
            extractedPKGDir = baseURL
        } else if baseURL.path.contains("wallpaperengine_merged_") {
            mergedDependencyDir = baseURL
        }

        let screens = NSScreen.screens
        let targetScreen: NSScreen
        if let s = screen, screens.indices.contains(s) {
            targetScreen = screens[s]
        } else if let main = NSScreen.main {
            targetScreen = main
        } else if let first = screens.first {
            targetScreen = first
        } else {
            completion?(false)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.level = .init(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.setFrame(targetScreen.frame, display: true)
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false

        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        config.websiteDataStore = .nonPersistent()
        config.mediaTypesRequiringUserActionForPlayback = []
        if #available(macOS 14.0, *) {
            config.defaultWebpagePreferences.allowsContentJavaScript = true
        }
        let ucc = WKUserContentController()
        ucc.addUserScript(Self.wallpaperEngineWebAPIShim)
        ucc.addUserScript(Self.localFileCompatScript)
        ucc.addUserScript(Self.interactionBridgeScript)
        config.userContentController = ucc

        let webView = WKWebView(frame: window.contentView?.bounds ?? .zero, configuration: config)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        webView.wantsLayer = true
        webView.layer?.backgroundColor = NSColor.black.cgColor
        window.contentView?.addSubview(webView)

        self.window = window
        self.webView = webView
        startInteractionBridge()

        let fileURL = baseURL.appendingPathComponent(indexFile)
        let readAccessURL = webWallpaperFileReadAccessURL(projectContentDir: baseURL, wallpaperPath: path)
        autoFixSpineConfigIfNeeded(projectContentDir: baseURL)
        webView.loadFileURL(fileURL, allowingReadAccessTo: readAccessURL)
        window.orderBack(nil)

        let generation = firstFrameSettleGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.firstFrameSettleGeneration == generation, self.pendingCompletion != nil else { return }
            print("[WebRendererBridge] Web 壁纸加载超时: \(path)")
            self.pendingCompletion?(false)
            self.pendingCompletion = nil
        }
    }

    private func autoFixSpineConfigIfNeeded(projectContentDir: URL) {
        let fm = FileManager.default
        let imageDir = projectContentDir.appendingPathComponent("image")
        let configURL = imageDir.appendingPathComponent(".config.json")
        guard fm.fileExists(atPath: imageDir.path),
              !fm.fileExists(atPath: configURL.path),
              let skelFiles = try? fm.contentsOfDirectory(at: imageDir, includingPropertiesForKeys: [.fileSizeKey])
                .filter({ $0.pathExtension.lowercased() == "skel" }),
              !skelFiles.isEmpty else { return }

        let targetSkel = skelFiles.max { a, b in
            let sizeA = (try? fm.attributesOfItem(atPath: a.path)[.size] as? Int) ?? 0
            let sizeB = (try? fm.attributesOfItem(atPath: b.path)[.size] as? Int) ?? 0
            return sizeA < sizeB
        } ?? skelFiles[0]
        let config: [String: String] = ["skeleton": targetSkel.lastPathComponent]
        if let data = try? JSONSerialization.data(withJSONObject: config, options: []) {
            try? data.write(to: configURL, options: .atomic)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoaded = true
        runWebWallpaperBootstrap { [weak self] in
            self?.beginSettlingFirstFrame()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishLoad(success: false)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishLoad(success: false)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isLoaded = false
        finishLoad(success: false)
    }

    func pause() {
        window?.orderOut(nil)
        webView?.evaluateJavaScript("""
            document.querySelectorAll('video, audio').forEach(m => m.pause());
            document.querySelectorAll('*').forEach(el => {
                const st = window.getComputedStyle(el);
                if (st.animationName !== 'none') el.style.animationPlayState = 'paused';
            });
        """) { _, _ in }
    }

    func resume() {
        guard isLoaded else { return }
        window?.orderBack(nil)
        webView?.evaluateJavaScript("""
            document.querySelectorAll('video, audio').forEach(m => { if(m.paused) m.play().catch(()=>{}); });
            document.querySelectorAll('*').forEach(el => {
                if (el.style.animationPlayState === 'paused') el.style.animationPlayState = 'running';
            });
            window.dispatchEvent(new Event('resize'));
        """) { _, _ in }
    }

    func stop() {
        firstFrameSettleGeneration += 1
        pendingCompletion = nil
        stopInteractionBridge()
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        window?.close()
        window = nil
        isLoaded = false
        currentScreenIndex = nil
        if let dir = extractedPKGDir {
            try? FileManager.default.removeItem(at: dir)
            extractedPKGDir = nil
        }
        if let dir = mergedDependencyDir {
            try? FileManager.default.removeItem(at: dir)
            mergedDependencyDir = nil
        }
        injectedPropertiesJSON = nil
    }

    private func startInteractionBridge() {
        stopInteractionBridge()
        let mask: NSEvent.EventTypeMask = [
            .mouseMoved,
            .leftMouseDown,
            .leftMouseUp,
            .rightMouseDown,
            .rightMouseUp,
            .otherMouseDown,
            .otherMouseUp,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
            .scrollWheel,
            .keyDown,
            .keyUp
        ]

        if let globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            guard let payload = Self.webInteractionEvent(from: event) else { return }
            Task { @MainActor [weak self] in
                self?.dispatchInteractionEvent(payload)
            }
        }) {
            interactionMonitors.append(globalMonitor)
        }

        let localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let payload = Self.webInteractionEvent(from: event) else { return event }
            Task { @MainActor [weak self] in
                self?.dispatchInteractionEvent(payload)
            }
            return event
        }
        if let localMonitor {
            interactionMonitors.append(localMonitor)
        }
    }

    private func stopInteractionBridge() {
        for monitor in interactionMonitors {
            NSEvent.removeMonitor(monitor)
        }
        interactionMonitors.removeAll()
    }

    private static func webInteractionEvent(from event: NSEvent) -> WebInteractionEvent? {
        let type: String
        switch event.type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            type = "mousemove"
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            type = "mousedown"
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            type = "mouseup"
        case .scrollWheel:
            type = "wheel"
        case .keyDown:
            type = "keydown"
        case .keyUp:
            type = "keyup"
        default:
            return nil
        }

        let flags = event.modifierFlags
        let key = event.charactersIgnoringModifiers ?? event.characters ?? ""
        let location = NSEvent.mouseLocation
        let isRightButton = event.type == .rightMouseDown || event.type == .rightMouseUp || event.type == .rightMouseDragged
        let button = isRightButton ? 2 : (event.buttonNumber == 0 ? 0 : Int(event.buttonNumber))
        let buttons: Int
        switch event.type {
        case .leftMouseDown, .leftMouseDragged:
            buttons = 1
        case .rightMouseDown, .rightMouseDragged:
            buttons = 2
        case .otherMouseDown, .otherMouseDragged:
            buttons = 4
        default:
            buttons = 0
        }

        return WebInteractionEvent(
            type: type,
            screenX: Double(location.x),
            screenY: Double(location.y),
            button: button,
            buttons: buttons,
            clickCount: max(1, event.clickCount),
            deltaX: Double(event.scrollingDeltaX),
            deltaY: Double(event.scrollingDeltaY),
            key: key,
            code: Self.domCode(for: event),
            keyCode: Self.domKeyCode(for: event),
            ctrlKey: flags.contains(.control),
            altKey: flags.contains(.option),
            shiftKey: flags.contains(.shift),
            metaKey: flags.contains(.command)
        )
    }

    private static func domCode(for event: NSEvent) -> String {
        if let scalar = (event.charactersIgnoringModifiers ?? event.characters)?.unicodeScalars.first {
            if scalar.value >= 65 && scalar.value <= 90 {
                return "Key\(Character(scalar))"
            }
            if scalar.value >= 97 && scalar.value <= 122,
               let upper = UnicodeScalar(scalar.value - 32) {
                return "Key\(Character(upper))"
            }
            if scalar.value >= 48 && scalar.value <= 57 {
                return "Digit\(Character(scalar))"
            }
        }
        switch event.keyCode {
        case 36: return "Enter"
        case 48: return "Tab"
        case 49: return "Space"
        case 51: return "Backspace"
        case 53: return "Escape"
        case 123: return "ArrowLeft"
        case 124: return "ArrowRight"
        case 125: return "ArrowDown"
        case 126: return "ArrowUp"
        default: return "Unidentified"
        }
    }

    private static func domKeyCode(for event: NSEvent) -> Int {
        switch event.keyCode {
        case 36: return 13
        case 48: return 9
        case 49: return 32
        case 51: return 8
        case 53: return 27
        case 123: return 37
        case 124: return 39
        case 125: return 40
        case 126: return 38
        default:
            if let scalar = (event.charactersIgnoringModifiers ?? event.characters)?.unicodeScalars.first {
                return Int(scalar.value)
            }
            return Int(event.keyCode)
        }
    }

    private func dispatchInteractionEvent(_ event: WebInteractionEvent) {
        guard let webView, let window else { return }
        let frame = window.frame
        guard frame.width > 0, frame.height > 0 else { return }

        let screenPoint = CGPoint(x: CGFloat(event.screenX), y: CGFloat(event.screenY))
        guard frame.contains(screenPoint) || event.type == "keyup" else { return }

        let xInWindow = screenPoint.x - frame.minX
        let yInWindow = screenPoint.y - frame.minY
        let xScale = Double(webView.bounds.width / frame.width)
        let yScale = Double(webView.bounds.height / frame.height)
        let x = max(0, min(Double(webView.bounds.width), Double(xInWindow) * xScale))
        let y = max(0, min(Double(webView.bounds.height), (Double(frame.height) - Double(yInWindow)) * yScale))

        let payload: [String: Any] = [
            "type": event.type,
            "x": x,
            "y": y,
            "screenX": event.screenX,
            "screenY": event.screenY,
            "button": event.button,
            "buttons": event.buttons,
            "clickCount": event.clickCount,
            "deltaX": event.deltaX,
            "deltaY": event.deltaY,
            "key": event.key,
            "code": event.code,
            "keyCode": event.keyCode,
            "ctrlKey": event.ctrlKey,
            "altKey": event.altKey,
            "shiftKey": event.shiftKey,
            "metaKey": event.metaKey
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }

        webView.evaluateJavaScript("window.__waifuXDispatchInput && window.__waifuXDispatchInput(\(json));") { _, _ in }
    }

    private func runWebWallpaperBootstrap(completion: (() -> Void)? = nil) {
        var propsBlock = ""
        if let json = injectedPropertiesJSON,
           let data = json.data(using: .utf8) {
            let b64 = data.base64EncodedString()
            propsBlock = """
            try {
              var props = JSON.parse(atob("\(b64)"));
              if (window.wallpaperPropertyListener && typeof window.wallpaperPropertyListener.applyUserProperties === 'function') {
                window.wallpaperPropertyListener.applyUserProperties(props);
              }
            } catch(e) {}
            """
        }
        let source = """
        (function(){
          \(propsBlock)
          try {
            if (window.wallpaperPropertyListener && typeof window.wallpaperPropertyListener.applyGeneralProperties === 'function') {
              window.wallpaperPropertyListener.applyGeneralProperties({ fps: { value: 30, type: 'slider' } });
            }
            document.documentElement.style.cssText = 'width:100%;height:100%;margin:0;padding:0;background:transparent;overflow:hidden;';
            document.body.style.setProperty('background-image', 'none', 'important');
            document.body.style.setProperty('width', '100%');
            document.body.style.setProperty('height', '100%');
            document.body.style.setProperty('margin', '0');
            document.body.style.setProperty('overflow', 'hidden');
            var pc = document.getElementById('player-container');
            if (pc) { pc.style.width = '100%'; pc.style.height = '100%'; }
            window.dispatchEvent(new Event('resize'));
          } catch(e) {}
          return true;
        })();
        """
        webView?.evaluateJavaScript(source) { _, _ in
            DispatchQueue.main.async { completion?() }
        }
    }

    private func beginSettlingFirstFrame() {
        firstFrameSettleGeneration += 1
        let generation = firstFrameSettleGeneration
        let start = Date()

        final class SettleState {
            var lastThumb: [UInt8]?
            var stablePasses = 0
            var lastImage: NSImage?
        }
        let state = SettleState()

        func scheduleStep() {
            guard generation == firstFrameSettleGeneration, webView != nil else { return }
            let elapsed = Date().timeIntervalSince(start)
            if elapsed >= FirstFramePolicy.maxElapsed {
                finishFirstFrame(state.lastImage)
                return
            }

            snapshotWebView { [weak self] image in
                guard let self, generation == self.firstFrameSettleGeneration else { return }
                guard let image else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + FirstFramePolicy.pollInterval) { scheduleStep() }
                    return
                }
                state.lastImage = image
                let thumb = self.grayscaleThumb(from: image, dimension: FirstFramePolicy.thumbDimension)
                defer { if let thumb { state.lastThumb = thumb } }
                if let prev = state.lastThumb, let curr = thumb {
                    let diff = Self.meanAbsDiffGrayscale(prev, curr)
                    if diff < FirstFramePolicy.diffThreshold, elapsed >= FirstFramePolicy.minElapsed {
                        state.stablePasses += 1
                    } else {
                        state.stablePasses = 0
                    }
                    if state.stablePasses >= FirstFramePolicy.stablePassesRequired {
                        finishFirstFrame(image)
                        return
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + FirstFramePolicy.pollInterval) { scheduleStep() }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { scheduleStep() }
    }

    private func snapshotWebView(completion: @escaping (NSImage?) -> Void) {
        guard let webView else {
            completion(nil)
            return
        }
        if #available(macOS 11.0, *) {
            let config = WKSnapshotConfiguration()
            config.rect = CGRect(origin: .zero, size: webView.bounds.size)
            webView.takeSnapshot(with: config) { image, _ in
                DispatchQueue.main.async { completion(image) }
            }
        } else {
            completion(nil)
        }
    }

    private func finishFirstFrame(_ image: NSImage?) {
        let success = image.flatMap { saveImage($0) } ?? false
        if success {
            applyCaptureAsDesktopWallpaper()
        }
        finishLoad(success: success || isLoaded)
    }

    private func finishLoad(success: Bool) {
        guard let completion = pendingCompletion else { return }
        pendingCompletion = nil
        completion(success)
    }

    private func grayscaleThumb(from image: NSImage, dimension: Int) -> [UInt8]? {
        guard dimension > 0 else { return nil }
        let target = NSSize(width: dimension, height: dimension)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: dimension,
            pixelsHigh: dimension,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.clear.set()
        NSRect(origin: .zero, size: target).fill()
        image.draw(
            in: NSRect(origin: .zero, size: target),
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1.0,
            respectFlipped: false,
            hints: [.interpolation: NSImageInterpolation.low]
        )
        NSGraphicsContext.restoreGraphicsState()
        var out = [UInt8](repeating: 0, count: dimension * dimension)
        for y in 0..<dimension {
            for x in 0..<dimension {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                let g = UInt8(min(255, max(0, (c.redComponent * 0.299 + c.greenComponent * 0.587 + c.blueComponent * 0.114) * 255.0)))
                out[y * dimension + x] = g
            }
        }
        return out
    }

    private static func meanAbsDiffGrayscale(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        var sum = 0
        for i in 0..<a.count {
            sum += abs(Int(a[i]) - Int(b[i]))
        }
        return Double(sum) / Double(a.count * 255)
    }

    private func saveImage(_ image: NSImage) -> Bool {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return false }
        do {
            try png.write(to: URL(fileURLWithPath: webPrimaryCapturePath), options: .atomic)
            return true
        } catch {
            print("[WebRendererBridge] 首帧保存失败: \(error.localizedDescription)")
            return false
        }
    }

    private func applyCaptureAsDesktopWallpaper() {
        guard FileManager.default.fileExists(atPath: webPrimaryCapturePath) else { return }
        if #available(macOS 26.0, *), VideoWallpaperManager.shared.isLockScreenEnabled {
            print("[WebRendererBridge] 🔒 动态锁屏已启用，跳过 Web 捕获静态桌面写入")
            return
        }

        desktopCaptureSlot = 1 - desktopCaptureSlot
        let dstPath = desktopCaptureSlot == 0 ? webDeskCapturePath0 : webDeskCapturePath1
        let src = URL(fileURLWithPath: webPrimaryCapturePath)
        let dst = URL(fileURLWithPath: dstPath)
        try? FileManager.default.removeItem(at: dst)
        guard (try? FileManager.default.copyItem(at: src, to: dst)) != nil else { return }

        let screens: [NSScreen]
        if let idx = currentScreenIndex, NSScreen.screens.indices.contains(idx) {
            screens = [NSScreen.screens[idx]]
        } else {
            screens = NSScreen.screens
        }
        for screen in screens {
            try? NSWorkspace.shared.setDesktopImageURLForAllSpaces(dst, for: screen, options: [
                .imageScaling: NSNumber(value: NSImageScaling.scaleProportionallyUpOrDown.rawValue),
                .allowClipping: true
            ])
            DesktopWallpaperSyncManager.shared.registerWallpaperSet(dst, for: screen)
        }
    }
}

// MARK: - 错误类型

enum WallpaperEngineError: LocalizedError {
    case notInstalled
    case cliNotFound
    case screenCaptureDenied
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled: return "Wallpaper Engine 未安装"
        case .cliNotFound: return "未找到 wallpaper-wgpu 二进制文件"
        case .screenCaptureDenied: return "屏幕录制权限被拒绝，请在「系统设置 → 隐私与安全性 → 屏幕录制」中允许本应用后重试"
        case .executionFailed(let msg): return msg
        }
    }
}
