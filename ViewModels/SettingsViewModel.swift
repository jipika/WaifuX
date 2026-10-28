import SwiftUI
import Combine
import ServiceManagement
import Kingfisher

@MainActor
class SettingsViewModel: ObservableObject {
    // ⚠️ 不使用 @AppStorage！macOS 26+ beta 上 @AppStorage 在属性包装器 init 时
    // 直接读 UserDefaults，如果 SettingsViewModel 在 AppDelegate 属性初始化阶段被创建，
    // 会触发 _CFXPreferences 递归栈溢出（EXC_BAD_ACCESS SIGSEGV）。
    // 改用 @Published + 手动 UserDefaults 同步 + restoreSavedSettings() 延迟恢复。
    private var systemWallpaperSyncTransitionGeneration: UInt64 = 0

    @Published var saveToDownloads = true {
        didSet { WaifuXPreferences.shared.set(saveToDownloads, forKey: DownloadPathManager.persistDownloadsToAppLibraryDefaultsKey) }
    }
    @Published private var themeModeRawValue: String = ThemeMode.dark.rawValue
    @Published var launchAtLogin = false { didSet { WaifuXPreferences.shared.set(launchAtLogin, forKey: "launch_at_login") } }
    @Published var swapMenuBarClickActions = false {
        didSet { WaifuXPreferences.shared.set(swapMenuBarClickActions, forKey: "menu_bar_swap_click_actions") }
    }
    /// 永不休眠：持有 IOPM assertion，阻止空闲息屏 / 系统睡眠，锁屏时桌面可继续显示。
    @Published var preventSystemSleep = false {
        didSet {
            guard !isBatchUpdating else { return }
            WaifuXPreferences.shared.set(preventSystemSleep, forKey: "prevent_system_sleep")
            SleepPreventer.shared.setPreventingSleep(preventSystemSleep, reason: .userSetting)
        }
    }
    @Published var grainTextureEnabled = false {
        didSet {
            guard !isBatchUpdating else { return }
            WaifuXPreferences.shared.set(grainTextureEnabled, forKey: "grain_texture_enabled")
            ArcBackgroundSettings.shared.grainTextureEnabled = grainTextureEnabled
            VideoWallpaperManager.shared.refreshGrainOverlay()
        }
    }
    @Published var grainTextureQuality = "high" { didSet { WaifuXPreferences.shared.set(grainTextureQuality, forKey: "grain_texture_quality") } }
    /// 颗粒度强度 0.0~1.0，同步到 ArcBackgroundSettings.grainIntensity
    @Published var grainIntensity: Double = 0.5 {
        didSet {
            guard !isBatchUpdating else { return }
            WaifuXPreferences.shared.set(grainIntensity, forKey: "arc_grain_intensity")
            ArcBackgroundSettings.shared.grainIntensity = grainIntensity
            VideoWallpaperManager.shared.refreshGrainOverlay()
        }
    }
    /// 隐藏刘海（菜单栏纯黑覆盖）
    @Published var hideNotch = false {
        didSet {
            guard !isBatchUpdating else { return }
            WaifuXPreferences.shared.set(hideNotch, forKey: "hide_notch")
            NotchOverlayManager.shared.setEnabled(hideNotch)
        }
    }
    @Published var pauseWhenOtherAppForeground = false { didSet { WaifuXPreferences.shared.set(pauseWhenOtherAppForeground, forKey: "pause_when_other_app_foreground") } }
    @Published var pauseInactiveDisplays = false { didSet { WaifuXPreferences.shared.set(pauseInactiveDisplays, forKey: "pause_inactive_displays") } }
    @Published var pauseWhenFullscreenCovers = false { didSet { WaifuXPreferences.shared.set(pauseWhenFullscreenCovers, forKey: "pause_when_fullscreen_covers") } }
    @Published var pauseOnBatteryPower = false { didSet { WaifuXPreferences.shared.set(pauseOnBatteryPower, forKey: "pause_on_battery_power") } }
    /// 电池供电时暂停自动轮换（默认开启）。与「暂停播放」分开：
    /// 轮换会重新加载视频壁纸、把电池策略刚暂停的渲染重新激活（issue #119）。
    @Published var pauseRotationOnBattery = true {
        didSet {
            guard !isBatchUpdating else { return }
            WaifuXPreferences.shared.set(pauseRotationOnBattery, forKey: "pause_rotation_on_battery")
            BackgroundRuntimeBridge.send("scheduler.reevaluateBattery", [:])
        }
    }
    /// 电池供电时播放策略（继续播放 / 暂停），落到 DynamicWallpaperAutoPauseManager 持久化
    @Published var batteryPlaybackPolicy: WallpaperPlaybackTriggerPolicy = .keepRunning {
        didSet {
            guard !isBatchUpdating, batteryPlaybackPolicy != oldValue else { return }
            DynamicWallpaperAutoPauseManager.shared.batteryPolicy = batteryPlaybackPolicy
        }
    }
    /// 显示器休眠时播放策略（继续播放 / 暂停）
    @Published var displaySleepPlaybackPolicy: WallpaperPlaybackTriggerPolicy = .pause {
        didSet {
            guard !isBatchUpdating, displaySleepPlaybackPolicy != oldValue else { return }
            DynamicWallpaperAutoPauseManager.shared.displaySleepPolicy = displaySleepPlaybackPolicy
        }
    }
    @Published var pauseWhenWindowCoverage = false { didSet { WaifuXPreferences.shared.set(pauseWhenWindowCoverage, forKey: "pause_when_window_coverage") } }
    @Published var windowCoveragePauseThreshold: Double = 50 { didSet { WaifuXPreferences.shared.set(windowCoveragePauseThreshold, forKey: "window_coverage_pause_threshold") } }
    /// 默认关闭：桌面 AVPlayerLayer 开启逐帧 HDR 元数据时，在部分 15.x + XDR 上会偶发整层 tone-map 闪暗。
    /// 用户仍可在设置里手动打开；仅影响新创建的 AVPlayerItem。
    @Published var hdrEnabled = false { didSet { WaifuXPreferences.shared.set(hdrEnabled, forKey: "hdr_enabled") } }
    /// 使用独立视频渲染子进程；默认关闭，使用 App 内置播放器。
    @Published var externalVideoRendererEnabled = false {
        didSet {
            guard !isBatchUpdating else { return }
            WaifuXPreferences.shared.set(
                externalVideoRendererEnabled,
                forKey: VideoWallpaperManager.externalVideoRendererDefaultsKey
            )
            VideoWallpaperManager.shared.setExternalVideoRendererEnabled(externalVideoRendererEnabled)
        }
    }
    @Published var autoRemoveVideoLetterbox = false {
        didSet {
            guard !isBatchUpdating else { return }
            WaifuXPreferences.shared.set(autoRemoveVideoLetterbox, forKey: "auto_remove_video_letterbox")
            VideoWallpaperManager.shared.refreshAutoRemoveVideoLetterbox()
            StaticImageWallpaperOverlayManager.shared.refreshAutoRemoveImageLetterbox()
        }
    }
    /// 为竖向静态图生成适配显示器比例的模糊延伸版本；原图保持不变。
    @Published var portraitBlurFillEnabled = false {
        didSet {
            guard !isBatchUpdating else { return }
            WaifuXPreferences.shared.set(portraitBlurFillEnabled, forKey: "portrait_blur_fill_enabled")
        }
    }
    /// Wallhaven 探索页默认隐藏竖图。
    @Published var hidePortraitWallpapersByDefault = true {
        didSet {
            guard !isBatchUpdating else { return }
            WaifuXPreferences.shared.set(
                hidePortraitWallpapersByDefault,
                forKey: WallhavenBrowsePreferences.hidePortraitByDefaultKey
            )
            NotificationCenter.default.post(name: .wallhavenDefaultFiltersChanged, object: nil)
        }
    }
    /// Wallhaven 探索页默认隐藏人物分类。
    @Published var hidePeopleWallpapersByDefault = true {
        didSet {
            guard !isBatchUpdating else { return }
            WaifuXPreferences.shared.set(
                hidePeopleWallpapersByDefault,
                forKey: WallhavenBrowsePreferences.hidePeopleByDefaultKey
            )
            NotificationCenter.default.post(name: .wallhavenDefaultFiltersChanged, object: nil)
        }
    }
    @Published var frameInterpolationTargetFPS: Double = 60 {
        didSet {
            guard !isBatchUpdating else { return }
            let normalized = Double(FrameInterpolationTargetFPSResolver.nearestAllowedFixedFPS(Int(frameInterpolationTargetFPS.rounded())))
            if frameInterpolationTargetFPS != normalized {
                frameInterpolationTargetFPS = normalized
                return
            }
            WaifuXPreferences.shared.set(frameInterpolationTargetFPS, forKey: "frame_interpolation_target_fps")
            VideoWallpaperManager.shared.refreshFrameInterpolationSettings()
            applyVideoOptimizationSettings()
        }
    }
    /// 视频下载或烘焙完成后，自动「优化视频」（先循环分析再补帧）。
    /// 与详情页 / 我的库手动「优化视频」同一流水线；手动入口不依赖此开关。
    @Published var autoOptimizeVideosAfterDownload = false {
        didSet {
            guard !isBatchUpdating else { return }
            WaifuXPreferences.shared.set(autoOptimizeVideosAfterDownload, forKey: "frame_interpolation_auto_on_download")
            // 旧双开关一并同步，避免分叉。
            WaifuXPreferences.shared.set(autoOptimizeVideosAfterDownload, forKey: "auto_analyze_loop_point")
            // 旧 key 清理，防止被当成「切换时自动补帧」读回。
            WaifuXPreferences.shared.set(false, forKey: "frame_interpolation_auto_enqueue")
            // 清理已废弃的总开关，避免其它路径误读。
            WaifuXPreferences.shared.set(true, forKey: "frame_interpolation_enabled")
            WaifuXPreferences.shared.set(true, forKey: "loop_point_analysis_enabled")
            applyVideoOptimizationSettings()
        }
    }
    @Published var showAllWorkshopContent = false { didSet { WaifuXPreferences.shared.set(showAllWorkshopContent, forKey: "show_all_workshop_content") } }
    /// 场景壁纸实时渲染模式开关
    /// 开启后，设置场景壁纸将使用 wallpaper-wgpu 实时渲染桌面，而非烘焙视频
    /// 与桌面动态元素（时钟、音频柱状图等）互斥
    @Published var sceneRealtimeRenderingEnabled = true {
        didSet {
            guard !isBatchUpdating else { return }
            WaifuXPreferences.shared.set(sceneRealtimeRenderingEnabled, forKey: "scene_realtime_rendering_enabled")
            // 与桌面动态元素互斥
            if sceneRealtimeRenderingEnabled {
                LiquidGlassClockSettings.shared.update { $0.enabled = false }
            }
        }
    }

    /// 超分辨率模式开关
    /// 开启后，动态壁纸将以低分辨率运行，利用 Apple MetalFX 超分辨率技术提升性能
    @Published var upscalingEnabled = true {
        didSet { WaifuXPreferences.shared.set(upscalingEnabled, forKey: "upscaling_enabled") }
    }

    /// 超分辨率缩放比例 (30% ~ 100%)
    @Published var upscalingPercent: Double = 70 {
        didSet { WaifuXPreferences.shared.set(upscalingPercent, forKey: "upscaling_percent") }
    }

    /// 性能模式（--effect-reduction）：压缩次级采样等 effect 中间 RT 精度
    /// 仅在超分模式启用时生效；默认关闭以避免静默损失 effect 精度
    @Published var effectReductionEnabled = false {
        didSet {
            WaifuXPreferences.shared.set(effectReductionEnabled, forKey: "effect_reduction_enabled")
            // 与 perfMode 同通道：effect 压缩变化即时热推给运行中的渲染器。
            WallpaperEngineXBridge.shared.applyPerfModeChange(wallpaperPerfMode)
        }
    }

    /// 壁纸引擎实时渲染帧率上限 (60 ~ 显示器最大刷新率)
    @Published var wallpaperEngineFPS: Double = 60 {
        didSet { WaifuXPreferences.shared.set(wallpaperEngineFPS, forKey: "wallpaper_engine_fps") }
    }

    /// 渲染性能模式：只影响 effect RT 精度，不影响帧率（帧率由 wallpaperEngineFPS 单独控制）。
    /// high/balanced = effectRT 全尺寸（等价），power = effectRT 宽高减半（省 GPU）。
    @Published var wallpaperPerfMode: String = "balanced" {
        didSet {
            let allowed = ["high", "balanced", "power"]
            let value = allowed.contains(wallpaperPerfMode) ? wallpaperPerfMode : "balanced"
            if value != wallpaperPerfMode { wallpaperPerfMode = value; return }
            WaifuXPreferences.shared.set(value, forKey: "wallpaper_engine_perf_mode")
            if oldValue != value {
                WallpaperEngineXBridge.shared.applyPerfModeChange(value)
            }
        }
    }

    /// Web 壁纸画布分辨率比例；100% 保持原画质，降低后减少 WebGL 像素占用。
    @Published var webWallpaperRenderScalePercent: Double = 100 {
        didSet {
            WaifuXPreferences.shared.set(webWallpaperRenderScalePercent, forKey: "web_wallpaper_render_scale_percent")
        }
    }

    /// 壁纸引擎离线烘焙帧率 (15 ~ 显示器最高刷新率)
    @Published var sceneBakeFPS: Double = 30 {
        didSet { WaifuXPreferences.shared.set(sceneBakeFPS, forKey: "scene_bake_fps") }
    }

    /// 壁纸引擎离线烘焙时长（秒）
    @Published var sceneBakeDuration: Double = 15 {
        didSet { WaifuXPreferences.shared.set(sceneBakeDuration, forKey: "scene_bake_duration") }
    }

    /// 下载完成后自动烘焙场景壁纸
    @Published var autoBakeScene: Bool = true {
        didSet { WaifuXPreferences.shared.set(autoBakeScene, forKey: "auto_bake_scene") }
    }

    /// 动态锁屏壁纸开关（仅 macOS 26+ 可用，关闭后走旧逻辑）
    @Published var dynamicLockScreenEnabled = false {
        didSet {
            guard !isBatchUpdating else { return }
            // 非 macOS 26+ 系统强制关闭，不允许开启
            if #available(macOS 26.0, *) { } else {
                if dynamicLockScreenEnabled {
                    dynamicLockScreenEnabled = false
                    return
                }
            }
            WaifuXPreferences.shared.set(dynamicLockScreenEnabled, forKey: "dynamic_lock_screen_enabled")
            // 开启时立即同步显示器实例到共享容器，使系统锁屏设置能发现 WaifuX 实例
            if dynamicLockScreenEnabled {
                // 动态锁屏接管后，停止保留旧静态桌面同步登记，避免后续 Space 切换重放 poster。
                DesktopWallpaperSyncManager.shared.clearRegistration()
                LockScreenWallpaperService.shared.syncDisplayInstancesToSocketServer()
            }
        }
    }

    /// 用户是否在系统设置（壁纸 > 锁屏）中选择了 WaifuX 实例。
    /// 权威来源是系统壁纸 store 的 Index.plist（只读探测），而非扩展 state 行为推断。
    @Published var lockScreenSelectionStatus: WallpaperStoreSelectionProbe.Selection = .unknown

    /// 设置页出现/刷新时重探系统壁纸 store（探测内部按文件 mtime 缓存，代价低）
    func refreshLockScreenSelectionStatus() {
        guard #available(macOS 26.0, *) else {
            lockScreenSelectionStatus = .unknown
            return
        }
        lockScreenSelectionStatus = WallpaperStoreSelectionProbe.currentSelection()
    }

    /// 系统壁纸缓存是否「读不到」（主 App 缺完全磁盘访问权限时为非空）。
    /// 清理已改由主 App 执行，而目标在 wallpaper agent 的容器里、受 TCC 保护；
    /// 没有这行提示，用户永远看不到「为什么磁盘一直在涨」。
    @Published var wallpaperCacheInaccessibleRootCount = 0

    /// 同步探测：每个缓存根只做一次目录级 readdir（不递归、不看文件内容）。
    /// 实测代价：无权限时 25.8ms、有权限时 35.4ms（launchd 与 Terminal 两种上下文各跑一次），
    /// 所以放在设置页 onAppear 里不绕后台线程——顺带说明：Swift 6 下把 self 带进
    /// `Task.detached` 会直接报 sending 数据竞争诊断，这里也没必要为了 30ms 去跟它较劲。
    func refreshWallpaperCacheAccessStatus() {
        wallpaperCacheInaccessibleRootCount = WallpaperSystemCacheJanitor.inaccessibleRootsNow().count
    }

    /// 壁纸扩展守护（keeper）开关。默认开启：App 退出后由 LaunchAgent 常驻守卫，
    /// 扩展被 pkd 清杀时自动重新注册拉载（详见 WallpaperExtensionKeeper 顶部注释）。
    @Published var wallpaperExtensionKeeperEnabled = true {
        didSet {
            // 批量恢复期间抑制副作用，避免启动时无谓折腾 launchctl
            guard !isBatchUpdating else { return }
            WaifuXPreferences.shared.set(
                wallpaperExtensionKeeperEnabled,
                forKey: WallpaperExtensionKeeper.launchAgentDefaultsKey
            )
            BackgroundRuntimeBridge.send("runtime.refreshSettings")
        }
    }

    /// 系统壁纸同步开关（默认开启）。
    /// 关闭后冻结「系统壁纸」链路：App 不再调用 setDesktopImageURL 写入桌面/锁屏静态壁纸，
    /// 但 mp4/场景渲染器/web 壁纸等动态壁纸引擎不受影响（它们通过 overlay 窗口或 CLI 进程覆盖桌面）。
    /// 单向联动：关闭时强制关闭动态锁屏并清理锁屏实例，避免锁屏也被设置。
    @Published var systemWallpaperSyncEnabled = true {
        didSet {
            // 批量恢复期间抑制联动副作用，避免启动时误清实例
            guard !isBatchUpdating else { return }
            WaifuXPreferences.shared.set(systemWallpaperSyncEnabled, forKey: "system_wallpaper_sync_enabled")
            // 通知 web daemon：关同步后不得再 setDesktopImageURL
            VideoWallpaperManager.shared.publishSystemWallpaperSyncControlToWebDaemon()
            // 单向联动：关闭系统壁纸同步时，强制关闭动态锁屏并清理锁屏实例
            if !systemWallpaperSyncEnabled && dynamicLockScreenEnabled {
                dynamicLockScreenEnabled = false
                Task { @MainActor in
                    if #available(macOS 26.0, *) {
                        LockScreenWallpaperService.shared.clearLockScreenInstances()
                    }
                }
            }
            systemWallpaperSyncTransitionGeneration &+= 1
            let transitionGeneration = systemWallpaperSyncTransitionGeneration
            let enabled = systemWallpaperSyncEnabled
            Task { @MainActor [weak self] in
                await self?.migrateStaticWallpaperPresentation(
                    systemSyncEnabled: enabled,
                    generation: transitionGeneration
                )
            }
        }
    }

    /// Preserves each display's visible static image when the presentation
    /// backend changes between the system desktop and the in-app overlay.
    private func migrateStaticWallpaperPresentation(systemSyncEnabled: Bool, generation: UInt64) async {
        BackgroundRuntimeBridge.send("desktop.syncMode", ["enabled": systemSyncEnabled])
    }

    // MARK: - 功能模块开关（壁纸页 / 媒体页 / 动漫页）
    //
    // 三个开关默认开启。关闭后需重启生效：运行时门控读 `ModuleAvailability.shared` 启动快照，
    // 而非这三个标志——这样切换开关在当前会话不立即生效（避免 tab 树重建 / 管线半加载）。
    // `hasPendingModuleChanges` 对比快照判定"待应用"，UI 据此显示"立即重启"。
    @Published var wallpaperModuleEnabled: Bool = true {
        didSet { WaifuXPreferences.shared.set(wallpaperModuleEnabled, forKey: "module_wallpaper_enabled") }
    }
    @Published var mediaModuleEnabled: Bool = true {
        didSet { WaifuXPreferences.shared.set(mediaModuleEnabled, forKey: "module_media_enabled") }
    }
    @Published var animeModuleEnabled: Bool = true {
        didSet { WaifuXPreferences.shared.set(animeModuleEnabled, forKey: "module_anime_enabled") }
    }

    @Published var proxyEnabled = false {
        didSet {
            guard !isBatchUpdating else { return }
            WaifuXPreferences.shared.set(proxyEnabled, forKey: "proxy_enabled")
            syncProxySettings()
        }
    }
    @Published var proxyHost: String = "" {
        didSet {
            guard !isBatchUpdating else { return }
            WaifuXPreferences.shared.set(proxyHost, forKey: "proxy_host")
            syncProxySettings()
        }
    }
    @Published var proxyPort: String = "" {
        didSet {
            guard !isBatchUpdating else { return }
            WaifuXPreferences.shared.set(proxyPort, forKey: "proxy_port")
            syncProxySettings()
        }
    }

    @Published var cacheSize: String = "0 MB"
    @Published var cacheProgress: Double = 0.0
    @Published var dataSourceProfiles: [DataSourceProfile] = []
    @Published var activeDataSourceProfileID: String = DataSourceProfileStore.builtinProfile.id
    @Published var dataSourceStatusMessage: String?

    private var cancellables = Set<AnyCancellable>()

    /// 批量更新标志。为 true 时，各 @Published 的 didSet 跳过单例副作用与 UserDefaults 写入，
    /// 由 withBatchUpdate 结束时统一补齐，避免批量恢复设置时触发数十次级联 objectWillChange/单例调用。
    private var isBatchUpdating = false

    /// 在闭包内批量修改设置属性，期间所有 didSet 副作用被抑制；
    /// 闭包返回后统一应用被抑制的副作用（UserDefaults + 单例）。
    /// 用于 restoreSavedSettings() 等一次性恢复多个设置的场景。
    func withBatchUpdate(_ updates: () throws -> Void) rethrows {
        isBatchUpdating = true
        defer { isBatchUpdating = false }
        try updates()
        applyDeferredSideEffects()
    }

    /// 应用批量更新期间被抑制的副作用。只处理含单例级联的属性，
    /// 其余纯 UserDefaults 写入属性在批量期间已被跳过——这里统一补写一次即可。
    private func applyDeferredSideEffects() {
        // UserDefaults 补写（批量期间 didSet 未执行）
        WaifuXPreferences.shared.set(grainTextureEnabled, forKey: "grain_texture_enabled")
        WaifuXPreferences.shared.set(grainIntensity, forKey: "arc_grain_intensity")
        WaifuXPreferences.shared.set(hideNotch, forKey: "hide_notch")
        WaifuXPreferences.shared.set(autoRemoveVideoLetterbox, forKey: "auto_remove_video_letterbox")
        WaifuXPreferences.shared.set(portraitBlurFillEnabled, forKey: "portrait_blur_fill_enabled")
        WaifuXPreferences.shared.set(
            hidePortraitWallpapersByDefault,
            forKey: WallhavenBrowsePreferences.hidePortraitByDefaultKey
        )
        WaifuXPreferences.shared.set(
            hidePeopleWallpapersByDefault,
            forKey: WallhavenBrowsePreferences.hidePeopleByDefaultKey
        )
        NotificationCenter.default.post(name: .wallhavenDefaultFiltersChanged, object: nil)
        WaifuXPreferences.shared.set(frameInterpolationTargetFPS, forKey: "frame_interpolation_target_fps")
        // 手动优化始终可用；总开关已废弃，写 true 以免旧代码路径误判为关闭。
        WaifuXPreferences.shared.set(true, forKey: "frame_interpolation_enabled")
        WaifuXPreferences.shared.set(true, forKey: "loop_point_analysis_enabled")
        WaifuXPreferences.shared.set(autoOptimizeVideosAfterDownload, forKey: "auto_analyze_loop_point")
        applyVideoOptimizationSettings()
        WaifuXPreferences.shared.set(autoOptimizeVideosAfterDownload, forKey: "frame_interpolation_auto_on_download")
        WaifuXPreferences.shared.set(false, forKey: "frame_interpolation_auto_enqueue")
        WaifuXPreferences.shared.set(sceneRealtimeRenderingEnabled, forKey: "scene_realtime_rendering_enabled")
        WaifuXPreferences.shared.set(
            externalVideoRendererEnabled,
            forKey: VideoWallpaperManager.externalVideoRendererDefaultsKey
        )
        WaifuXPreferences.shared.set(proxyEnabled, forKey: "proxy_enabled")
        WaifuXPreferences.shared.set(proxyHost, forKey: "proxy_host")
        WaifuXPreferences.shared.set(proxyPort, forKey: "proxy_port")

        // 单例级联副作用
        ArcBackgroundSettings.shared.grainTextureEnabled = grainTextureEnabled
        ArcBackgroundSettings.shared.grainIntensity = grainIntensity
        VideoWallpaperManager.shared.refreshGrainOverlay()
        VideoWallpaperManager.shared.refreshAutoRemoveVideoLetterbox()
        StaticImageWallpaperOverlayManager.shared.refreshAutoRemoveImageLetterbox()
        VideoWallpaperManager.shared.refreshFrameInterpolationSettings()
        VideoOptimizationQueueService.shared.applySettings(autoOnDownload: autoOptimizeVideosAfterDownload)
        NotchOverlayManager.shared.setEnabled(hideNotch)
        VideoWallpaperManager.shared.setExternalVideoRendererEnabled(externalVideoRendererEnabled)
        if sceneRealtimeRenderingEnabled {
            LiquidGlassClockSettings.shared.update { $0.enabled = false }
        }
        syncProxySettings()

        // 纯 UserDefaults 属性（批量期间 didSet 被跳过，统一补写）
        WaifuXPreferences.shared.set(autoBakeScene, forKey: "auto_bake_scene")
        WaifuXPreferences.shared.set(systemWallpaperSyncEnabled, forKey: "system_wallpaper_sync_enabled")
        WaifuXPreferences.shared.set(preventSystemSleep, forKey: "prevent_system_sleep")
        // 启动恢复后同步给 web daemon，避免旧 daemon 仍按默认写系统桌面
        VideoWallpaperManager.shared.publishSystemWallpaperSyncControlToWebDaemon()
        // 恢复「永不休眠」电源 assertion（批量期间 didSet 被抑制）
        SleepPreventer.shared.setPreventingSleep(preventSystemSleep, reason: .userSetting)
    }

    // MARK: - 调度器相关（延迟初始化，避免启动时阻塞）
    private var _schedulerViewModel: WallpaperSchedulerViewModel?
    private var _downloadTaskViewModel: DownloadTaskViewModel?

    var schedulerViewModel: WallpaperSchedulerViewModel {
        if _schedulerViewModel == nil {
            _schedulerViewModel = WallpaperSchedulerViewModel()
            _schedulerViewModel!.objectWillChange
                .sink { [weak self] _ in
                    self?.objectWillChange.send()
                }
                .store(in: &cancellables)
        }
        return _schedulerViewModel!
    }

    var downloadTaskViewModel: DownloadTaskViewModel {
        if _downloadTaskViewModel == nil {
            _downloadTaskViewModel = DownloadTaskViewModel()
        }
        return _downloadTaskViewModel!
    }

    // API Key - 使用静态缓存，避免在 getter 中读 UserDefaults
    private let apiKeyUserDefaultsKey = "wallhaven_api_key"
    private static var _cachedAPIKey: String? = nil
    private static var _apiKeyRestored = false
    var apiKey: String {
        get {
            // ⚠️ 不直接读 UserDefaults！使用启动缓存
            if Self._apiKeyRestored { return Self._cachedAPIKey ?? "" }
            return ""
        }
        set {
            objectWillChange.send()
            let trimmedValue = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            Self._cachedAPIKey = trimmedValue.isEmpty ? nil : trimmedValue
            WaifuXPreferences.shared.set(trimmedValue, forKey: apiKeyUserDefaultsKey)

            // 同步更新 WallpaperViewModel 的 API Key 缓存，确保实时生效
            WallpaperViewModel.updateSharedAPIKeyCache(trimmedValue)
        }
    }

    private let maxCacheSize: Int64 = 500_000_000 // 500MB 预估最大值

    init() {
        // ⚠️ init 中不读 UserDefaults！所有持久化数据通过 restoreSavedSettings() 延迟恢复
        // refreshDataSourceProfiles() 等延后到 restore 中执行
    }

    /// ⚠️ 延迟恢复所有持久化设置（完全异步，避免阻塞主线程）
    /// 在 applicationDidFinishLaunching 完成后的 DispatchQueue.main.async 中调用
    func restoreSavedSettings() {
        // 第一步：快速恢复基本设置（UserDefaults 读取很快）
        // 用 withBatchUpdate 包裹：一次性赋值 20+ 个 @Published，期间 didSet 的
        // 单例副作用与 UserDefaults 写入被抑制，结束后统一补齐，避免启动时数十次级联。
        let defaults = WaifuXPreferences.shared
        withBatchUpdate {
            saveToDownloads = defaults.object(forKey: DownloadPathManager.persistDownloadsToAppLibraryDefaultsKey) as? Bool ?? true
            themeModeRawValue = ThemeManager.savedMode(in: defaults).rawValue
            launchAtLogin = defaults.bool(forKey: "launch_at_login")
            swapMenuBarClickActions = defaults.bool(forKey: "menu_bar_swap_click_actions")
            preventSystemSleep = defaults.bool(forKey: "prevent_system_sleep")
            grainTextureEnabled = defaults.object(forKey: "grain_texture_enabled") as? Bool ?? false
            grainTextureQuality = defaults.string(forKey: "grain_texture_quality") ?? "high"
            let savedGrainIntensity = defaults.double(forKey: "arc_grain_intensity")
            grainIntensity = savedGrainIntensity > 0 ? savedGrainIntensity : 0.5
            hideNotch = defaults.bool(forKey: "hide_notch")
            pauseWhenOtherAppForeground = defaults.bool(forKey: "pause_when_other_app_foreground")
            pauseInactiveDisplays = defaults.bool(forKey: "pause_inactive_displays")
            pauseWhenFullscreenCovers = defaults.bool(forKey: "pause_when_fullscreen_covers")
            pauseOnBatteryPower = defaults.bool(forKey: "pause_on_battery_power")
            pauseRotationOnBattery = defaults.object(forKey: "pause_rotation_on_battery") as? Bool ?? true
            // 策略值从 AutoPauseManager 读取（内含旧布尔开关的一次性迁移）
            batteryPlaybackPolicy = DynamicWallpaperAutoPauseManager.shared.batteryPolicy
            displaySleepPlaybackPolicy = DynamicWallpaperAutoPauseManager.shared.displaySleepPolicy
            pauseWhenWindowCoverage = defaults.bool(forKey: "pause_when_window_coverage")
            let savedThreshold = defaults.double(forKey: "window_coverage_pause_threshold")
            windowCoveragePauseThreshold = savedThreshold > 0 ? savedThreshold : 50
            hdrEnabled = defaults.object(forKey: "hdr_enabled") as? Bool ?? false
            externalVideoRendererEnabled = defaults.object(
                forKey: VideoWallpaperManager.externalVideoRendererDefaultsKey
            ) as? Bool ?? false
            autoRemoveVideoLetterbox = defaults.object(forKey: "auto_remove_video_letterbox") as? Bool ?? false
            portraitBlurFillEnabled = defaults.object(forKey: "portrait_blur_fill_enabled") as? Bool ?? false
            hidePortraitWallpapersByDefault = WallhavenBrowsePreferences.hidePortraitByDefault(from: defaults)
            hidePeopleWallpapersByDefault = WallhavenBrowsePreferences.hidePeopleByDefault(from: defaults)
            frameInterpolationTargetFPS = Double(FrameInterpolationTargetFPSResolver.nearestAllowedFixedFPS(Int((defaults.object(forKey: "frame_interpolation_target_fps") as? Double ?? 60.0).rounded())))
            // 统一为「下载后自动优化视频」。任一旧自动开关为 true 即迁移为开启。
            // 旧 key「切换时自动」不再迁移为开启。
            let legacyAutoInterpolate = defaults.object(forKey: "frame_interpolation_auto_on_download") as? Bool ?? false
            let legacyAutoLoop = defaults.object(forKey: "auto_analyze_loop_point") as? Bool ?? false
            autoOptimizeVideosAfterDownload = legacyAutoInterpolate || legacyAutoLoop
            defaults.set(true, forKey: "frame_interpolation_enabled")
            defaults.set(true, forKey: "loop_point_analysis_enabled")
            defaults.set(false, forKey: "frame_interpolation_auto_enqueue")
            defaults.set(autoOptimizeVideosAfterDownload, forKey: "frame_interpolation_auto_on_download")
            defaults.set(autoOptimizeVideosAfterDownload, forKey: "auto_analyze_loop_point")
            applyVideoOptimizationSettings()
            showAllWorkshopContent = defaults.bool(forKey: "show_all_workshop_content")
            // 未写过 key 时默认 true（与属性初始值一致）；bool(forKey:) 会把缺失当成 false
            sceneRealtimeRenderingEnabled = defaults.object(forKey: "scene_realtime_rendering_enabled") as? Bool ?? true
            upscalingEnabled = defaults.object(forKey: "upscaling_enabled") as? Bool ?? true
            upscalingPercent = defaults.object(forKey: "upscaling_percent") as? Double ?? 70
            effectReductionEnabled = defaults.object(forKey: "effect_reduction_enabled") as? Bool ?? false
            let savedWallpaperFPS = defaults.object(forKey: "wallpaper_engine_fps") as? Double ?? 60.0
            wallpaperEngineFPS = savedWallpaperFPS.isFinite
                ? max(60, min(240, savedWallpaperFPS)) : 60.0
            let savedPerfMode = defaults.object(forKey: "wallpaper_engine_perf_mode") as? String ?? "balanced"
            wallpaperPerfMode = ["high", "balanced", "power"].contains(savedPerfMode) ? savedPerfMode : "balanced"
            webWallpaperRenderScalePercent = defaults.object(forKey: "web_wallpaper_render_scale_percent") as? Double ?? 100.0
            sceneBakeFPS = defaults.object(forKey: "scene_bake_fps") as? Double ?? 30.0
            sceneBakeDuration = defaults.object(forKey: "scene_bake_duration") as? Double ?? 15
            autoBakeScene = defaults.object(forKey: "auto_bake_scene") as? Bool ?? true
            dynamicLockScreenEnabled = defaults.bool(forKey: "dynamic_lock_screen_enabled")
            // 非 macOS 26+ 系统强制关闭动态锁屏
            if #available(macOS 26.0, *) { } else {
                dynamicLockScreenEnabled = false
            }
            // 系统壁纸同步默认开启（未设值时 true）
            systemWallpaperSyncEnabled = defaults.object(forKey: "system_wallpaper_sync_enabled") as? Bool ?? true
            // 壁纸扩展守护默认开启（未设值时 true）
            wallpaperExtensionKeeperEnabled = defaults.object(forKey: WallpaperExtensionKeeper.launchAgentDefaultsKey) as? Bool ?? true

            // 功能模块开关恢复（默认 true）
            wallpaperModuleEnabled = defaults.object(forKey: "module_wallpaper_enabled") as? Bool ?? true
            mediaModuleEnabled = defaults.object(forKey: "module_media_enabled") as? Bool ?? true
            animeModuleEnabled = defaults.object(forKey: "module_anime_enabled") as? Bool ?? true

            proxyEnabled = defaults.bool(forKey: "proxy_enabled")
            proxyHost = defaults.string(forKey: "proxy_host") ?? ""
            proxyPort = defaults.string(forKey: "proxy_port") ?? ""

            // 恢复 API Key 缓存
            Self._cachedAPIKey = defaults.string(forKey: apiKeyUserDefaultsKey)
            Self._apiKeyRestored = true
        }

        // 第二步：后台异步执行耗时操作
        Task(priority: .background) { @MainActor in
            // 小延迟确保 UI 先响应
            try? await Task.sleep(nanoseconds: 50_000_000) // 0.05秒
            refreshDataSourceProfiles()

            // 缓存计算
            async let cacheTask: () = updateCacheSize()
            _ = await (cacheTask)
        }
    }

    /// 同步自动暂停设置到 DynamicWallpaperAutoPauseManager
    private func applyVideoOptimizationSettings() {
        VideoOptimizationQueueService.shared.applySettings(
            automaticPolicy: VideoOptimizationAutomaticPolicy(
                automaticallyOptimizeVideos: autoOptimizeVideosAfterDownload,
                targetFPS: FrameInterpolationTargetFPSResolver.nearestAllowedFixedFPS(Int(frameInterpolationTargetFPS.rounded()))
            )
        )
    }

    func syncAutoPauseSettings() {
        DynamicWallpaperAutoPauseManager.shared.pauseWhenOtherAppForeground = pauseWhenOtherAppForeground
        DynamicWallpaperAutoPauseManager.shared.pauseInactiveDisplays = pauseInactiveDisplays
        DynamicWallpaperAutoPauseManager.shared.pauseWhenFullscreenCovers = pauseWhenFullscreenCovers
        DynamicWallpaperAutoPauseManager.shared.pauseOnBatteryPower = pauseOnBatteryPower
        DynamicWallpaperAutoPauseManager.shared.pauseWhenWindowCoverage = pauseWhenWindowCoverage
        DynamicWallpaperAutoPauseManager.shared.windowCoveragePauseThreshold = windowCoveragePauseThreshold
    }

    /// 清理所有锁屏实例：清空视频缓存、显示器实例列表、推送管线
    func clearLockScreenInstances() {
        LockScreenWallpaperService.shared.clearLockScreenInstances()
        // 同步本地开关状态（clearLockScreenInstances 已将 UserDefaults 置为 false）
        dynamicLockScreenEnabled = false
    }

    /// 同步代理设置到 NetworkService
    func syncProxySettings() {
        Task {
            await NetworkService.shared.updateProxyConfiguration(
                enabled: proxyEnabled,
                host: proxyHost,
                port: proxyPort
            )
        }
    }

    // MARK: - 功能模块待应用状态

    /// 是否有待应用的模块开关改动（当前标志值 ≠ 启动快照值）。
    /// UI 据此显示"立即重启"区块。
    var hasPendingModuleChanges: Bool {
        wallpaperModuleEnabled != ModuleAvailability.shared.wallpaperEnabled
        || mediaModuleEnabled != ModuleAvailability.shared.mediaEnabled
        || animeModuleEnabled != ModuleAvailability.shared.animeEnabled
    }

    /// 列出将被开启/关闭的模块，如 "+壁纸页, -媒体页"。UI 据此展示待应用详情。
    var pendingModulesDescription: String {
        var parts: [String] = []
        if wallpaperModuleEnabled != ModuleAvailability.shared.wallpaperEnabled {
            parts.append(wallpaperModuleEnabled ? "+\(t("settings.modules.wallpaper"))" : "-\(t("settings.modules.wallpaper"))")
        }
        if mediaModuleEnabled != ModuleAvailability.shared.mediaEnabled {
            parts.append(mediaModuleEnabled ? "+\(t("settings.modules.media"))" : "-\(t("settings.modules.media"))")
        }
        if animeModuleEnabled != ModuleAvailability.shared.animeEnabled {
            parts.append(animeModuleEnabled ? "+\(t("settings.modules.anime"))" : "-\(t("settings.modules.anime"))")
        }
        return parts.joined(separator: ", ")
    }

    /// 关闭设置窗口"放弃更改"时回滚到启动快照值。
    func discardPendingModuleChanges() {
        wallpaperModuleEnabled = ModuleAvailability.shared.wallpaperEnabled
        mediaModuleEnabled = ModuleAvailability.shared.mediaEnabled
        animeModuleEnabled = ModuleAvailability.shared.animeEnabled
    }

    // MARK: - 更新检测

    func updateCacheSize() async {
        // 获取 CacheService 缓存大小
        let cacheServiceBytes = await CacheService.shared.cacheSize

        // 获取 URLCache 大小
        guard let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            cacheSize = "0 MB"
            cacheProgress = 0
            return
        }
        let urlCacheURL = cacheURL.appendingPathComponent("WaifuXImageCache")
        var urlCacheBytes: Int64 = 0
        if let enumerator = FileManager.default.enumerator(at: urlCacheURL, includingPropertiesForKeys: [.fileSizeKey]) {
            while let fileURL = enumerator.nextObject() as? URL {
                let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                urlCacheBytes += Int64(size)
            }
        }

        // App Group 共享容器：锁屏镜像副本、静态图、缩略图与扩展日志都落在这里。
        // 自动轮换会持续写入跨卷复制的视频副本（外置库 → 内置盘无法 hard link），
        // 是实际占用最大的一块 —— 必须计入，否则用户在设置页看不到真正的用量。
        let containerBytes = Self.appGroupCacheBytes()

        let totalBytes = Int64(cacheServiceBytes) + urlCacheBytes + containerBytes
        cacheSize = Self.formattedCacheSize(totalBytes)
        // 计算缓存进度（相对于 500MB 预估最大值）
        cacheProgress = min(Double(totalBytes) / Double(maxCacheSize), 1.0)
    }

    /// 共享容器缓存占用（不含用户设置与 socket，那些不是可清理对象）。
    private static func appGroupCacheBytes() -> Int64 {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.waifux.app"
        ) else { return 0 }
        return AppGroupCacheBudget.usage(ofContainer: container).total
    }

    /// 统一格式化：过 G 用 GB，否则 MB，避免「20480.0 MB」这种读不出来的数字。
    private static func formattedCacheSize(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_000_000_000
        if gb >= 1 {
            return String(format: "%.2f GB", gb)
        }
        return String(format: "%.1f MB", Double(bytes) / 1_000_000)
    }

    func clearCache() async {
        // 清除 CacheService 缓存
        try? await CacheService.shared.clearCache()

        // 清除 MediaService 缓存（包含分页数据）
        await MediaService.shared.clearCache()

        // 清除共享容器缓存（缩略图 + 不再被引用的镜像副本），保留当前正在用的那份：
        // 锁屏扩展在沙盒里只能读容器，删掉当前源 = 锁屏立刻黑屏。
        Self.clearAppGroupCache()

        // 清除 URLCache 缓存
        guard let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            await updateCacheSize()
            return
        }
        let urlCacheURL = cacheURL.appendingPathComponent("WaifuXImageCache")
        try? FileManager.default.removeItem(at: urlCacheURL)

        await updateCacheSize()
    }

    /// 清理共享容器里可安全重建的部分。
    ///
    /// 保守口径：**只删缩略图与未被引用的镜像副本**，不动
    /// `waifux-wallpaper-prefs.json` / `waifux-display-instances.json` /
    /// `waifux-wallpaper-state.json`（状态文件）与 `socket/`（IPC 端点）。
    /// 日志也不在这里删 —— 它是排障证据，由扩展侧自己的轮转负责。
    private static func clearAppGroupCache() {
        let fm = FileManager.default
        guard let container = fm.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.waifux.app"
        ) else { return }

        // 1. 缩略图：全部可重建（换壁纸/重新同步时会重新生成）。
        let thumbDir = container.appendingPathComponent(AppGroupCacheBudget.thumbnailDirectoryName, isDirectory: true)
        if let files = try? fm.contentsOfDirectory(at: thumbDir, includingPropertiesForKeys: nil) {
            for file in files {
                try? fm.removeItem(at: file)
            }
        }

        // 2. 镜像副本：只删不被 prefs 引用的那些，当前锁屏源必须留下。
        let videoDir = container.appendingPathComponent(AppGroupCacheBudget.videoDirectoryName, isDirectory: true)
        let prefsURL = container.appendingPathComponent("waifux-wallpaper-prefs.json")
        var protected = Set<String>()
        if let data = try? Data(contentsOf: prefsURL),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["currentVideoPath", "currentImagePath"] {
                if let path = object[key] as? String, !path.isEmpty {
                    protected.insert(URL(fileURLWithPath: path).standardizedFileURL.path)
                }
            }
            for key in ["currentVideoPaths", "currentImagePaths"] {
                for (_, value) in (object[key] as? [String: String]) ?? [:] where !value.isEmpty {
                    protected.insert(URL(fileURLWithPath: value).standardizedFileURL.path)
                }
            }
        }
        for entry in AppGroupCacheBudget.entries(in: videoDir, fileManager: fm, extensions: ["mp4", "mov", "m4v"]) {
            if protected.contains(entry.url.standardizedFileURL.path) { continue }
            try? fm.removeItem(at: entry.url)
        }
    }

    /// A reset may remove data only after a bounded, acknowledged Helper stop.
    /// Keeping this preflight separate allows an isolated AppKit regression to
    /// exercise failure without deleting the user's cache or media files.
    func prepareForDataReset() async -> Bool {
        let client = BackgroundAgentClient.shared
        client.beginApplicationQuit()
        var timedOut = false
        let preflight = Task {
            try await client.drainForUIExit()
            try Task.checkCancellation()
            try await client.stopForApplicationQuit()
            try Task.checkCancellation()
        }
        let deadline = Task {
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            timedOut = true
            preflight.cancel()
            client.applicationQuitFailed(NSError(domain: "WaifuXHelper", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "后台服务停止超时，未重置任何数据"]))
        }
        defer { deadline.cancel() }
        do {
            try await preflight.value
            deadline.cancel()
        } catch {
            if !timedOut { client.applicationQuitFailed(error) }
            return false
        }
        return true
    }

    /// 重置所有数据（缓存、UserDefaults、Application Support）
    func resetAllData() async {
        guard await prepareForDataReset() else { return }
        let fm = FileManager.default

        // 1. Kingfisher 内存 + 磁盘缓存
        ImageCache.default.clearMemoryCache()
        await ImageCache.default.clearDiskCache()

        // 2. 业务缓存
        try? await CacheService.shared.clearCache()
        await MediaService.shared.clearCache()

        // 3. URLCache 及旧缓存目录
        URLCache.shared.removeAllCachedResponses()
        if let cacheURL = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let targets = [
                cacheURL.appendingPathComponent("WaifuXImageCache"),
                cacheURL.appendingPathComponent("org.onevcat.Kingfisher.ImageCache.default")
            ]
            for url in targets {
                try? fm.removeItem(at: url)
            }
        }

        // 4. Application Support 下的应用数据
        if let supportURL = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let targets = [
                supportURL.appendingPathComponent("WaifuX"),
                supportURL.appendingPathComponent("WallHaven")
            ]
            for url in targets {
                try? fm.removeItem(at: url)
            }
        }

        // 5. UserDefaults
        WaifuXPreferences.shared.resetAfterHelperStopped()

        await updateCacheSize()

        // 6. 退出应用（用户需手动重启）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.terminate(nil)
        }
    }

    var themeMode: ThemeMode {
        get { ThemeMode(rawValue: themeModeRawValue) ?? .system }
        set {
            objectWillChange.send()
            themeModeRawValue = newValue.rawValue
            ThemeManager.shared.themeMode = newValue
        }
    }

    var appVersion: String {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return shortVersion ?? "1.0.0"
    }

    var activeDataSourceProfile: DataSourceProfile {
        dataSourceProfiles.first(where: { $0.id == activeDataSourceProfileID }) ?? DataSourceProfileStore.builtinProfile
    }

    func refreshDataSourceProfiles() {
        dataSourceProfiles = DataSourceProfileStore.allProfiles()
        activeDataSourceProfileID = DataSourceProfileStore.activeProfileID()
    }

    func selectDataSourceProfile(id: String) {
        DataSourceProfileStore.setActiveProfileID(id)
        refreshDataSourceProfiles()
        Task { await MediaService.shared.clearCache() }
        dataSourceStatusMessage = "已切换到 \(activeDataSourceProfile.name)"
    }

    func resetDataSourceProfiles() {
        DataSourceProfileStore.reset()
        refreshDataSourceProfiles()
        Task { await MediaService.shared.clearCache() }
        dataSourceStatusMessage = "已恢复内置默认数据源配置"
    }

    func removeImportedDataSourceProfile(id: String) {
        do {
            try DataSourceProfileStore.removeImportedProfile(id: id)
            refreshDataSourceProfiles()
            Task { await MediaService.shared.clearCache() }
            dataSourceStatusMessage = "已移除导入的数据源配置"
        } catch {
            dataSourceStatusMessage = error.localizedDescription
        }
    }

    func importDataSourceProfiles(from url: URL) {
        do {
            let data = try Data(contentsOf: url)
            _ = try DataSourceProfileStore.importProfiles(from: data)
            refreshDataSourceProfiles()
            Task { await MediaService.shared.clearCache() }
            dataSourceStatusMessage = "已导入数据源配置"
        } catch {
            dataSourceStatusMessage = error.localizedDescription
        }
    }

    func importDataSourceProfiles(fromRemoteURL remoteURL: URL) async {
        do {
            let (data, response) = try await URLSession.shared.data(from: remoteURL)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                dataSourceStatusMessage = "下载失败: 服务器返回错误"
                return
            }

            _ = try DataSourceProfileStore.importProfiles(from: data)
            refreshDataSourceProfiles()
            await MediaService.shared.clearCache()
            dataSourceStatusMessage = "已从远程 URL 导入数据源配置"
        } catch {
            dataSourceStatusMessage = "下载失败: \(error.localizedDescription)"
        }
    }

    func saveProfile(_ profile: DataSourceProfile) {
        do {
            // 获取当前所有导入的配置
            var profiles = DataSourceProfileStore.importedProfiles()

            // 检查是否已存在相同ID的配置
            if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
                // 更新现有配置
                profiles[index] = profile
                dataSourceStatusMessage = "已更新配置: \(profile.name)"
            } else {
                // 添加新配置
                profiles.append(profile)
                dataSourceStatusMessage = "已创建配置: \(profile.name)"
            }

            // 保存到 UserDefaults
            try DataSourceProfileStore.saveImportedProfiles(profiles)
            refreshDataSourceProfiles()
            Task { await MediaService.shared.clearCache() }
        } catch {
            dataSourceStatusMessage = "保存失败: \(error.localizedDescription)"
        }
    }

    func runDataSourceDiagnostics() async {
        var lines: [String] = []

        do {
            let latestURL = WallhavenAPI.url(
                for: .search(
                    .init(
                        page: 1,
                        categories: "111",
                        purity: "100",
                        sorting: "date_added",
                        order: "desc",
                        includeFields: ["uploader", "tags", "colors"]
                    )
                )
            )

            if let latestURL {
                let latest = try await NetworkService.shared.fetch(
                    WallpaperSearchResponse.self,
                    from: latestURL,
                    headers: WallhavenAPI.authenticationHeaders(apiKey: apiKey)
                )
                lines.append("Wallpaper latest: \(latest.data.count) items")
            }
        } catch {
            lines.append("Wallpaper latest failed: \(error.localizedDescription)")
        }

        do {
            let topURL = WallhavenAPI.url(
                for: .search(
                    .init(
                        page: 1,
                        categories: "111",
                        purity: "100",
                        sorting: "toplist",
                        order: "desc",
                        topRange: "1M",
                        includeFields: ["uploader", "tags", "colors"]
                    )
                )
            )

            if let topURL {
                let top = try await NetworkService.shared.fetch(
                    WallpaperSearchResponse.self,
                    from: topURL,
                    headers: WallhavenAPI.authenticationHeaders(apiKey: apiKey)
                )
                lines.append("Wallpaper toplist: \(top.data.count) items")
            }
        } catch {
            lines.append("Wallpaper toplist failed: \(error.localizedDescription)")
        }

        do {
            let home = try await MediaService.shared.fetchPage(source: .home)
            lines.append("Media home: \(home.items.count) items")
        } catch {
            lines.append("Media home failed: \(error.localizedDescription)")
        }

        do {
            let search = try await MediaService.shared.fetchPage(source: .search("goku"))
            lines.append("Media search(goku): \(search.items.count) items")
        } catch {
            lines.append("Media search failed: \(error.localizedDescription)")
        }

        do {
            let detail = try await MediaService.shared.fetchDetail(slug: "wuthering-waves-arcane-clash")
            lines.append("Media detail: preview=\(detail.previewVideoURL == nil ? "no" : "yes"), downloads=\(detail.downloadOptions.count)")
        } catch {
            lines.append("Media detail failed: \(error.localizedDescription)")
        }

        dataSourceStatusMessage = lines.joined(separator: "\n")
    }

    func toggleLaunchAtLogin() {
        // LaunchAgent owns login restoration; stop launching the full UI at login.
        if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() }
        BackgroundAgentClient.shared.start()
        launchAtLogin.toggle()
    }
}
