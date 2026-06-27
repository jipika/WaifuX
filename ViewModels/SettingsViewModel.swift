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

    @Published var saveToDownloads = true {
        didSet { UserDefaults.standard.set(saveToDownloads, forKey: DownloadPathManager.persistDownloadsToAppLibraryDefaultsKey) }
    }
    @Published private var themeModeRawValue: String = ThemeMode.system.rawValue { didSet { UserDefaults.standard.set(themeModeRawValue, forKey: "theme_mode") } }
    @Published var launchAtLogin = false { didSet { UserDefaults.standard.set(launchAtLogin, forKey: "launch_at_login") } }
    @Published var grainTextureEnabled = false {
        didSet {
            guard !isBatchUpdating else { return }
            UserDefaults.standard.set(grainTextureEnabled, forKey: "grain_texture_enabled")
            ArcBackgroundSettings.shared.grainTextureEnabled = grainTextureEnabled
            VideoWallpaperManager.shared.refreshGrainOverlay()
        }
    }
    @Published var grainTextureQuality = "high" { didSet { UserDefaults.standard.set(grainTextureQuality, forKey: "grain_texture_quality") } }
    /// 颗粒度强度 0.0~1.0，同步到 ArcBackgroundSettings.grainIntensity
    @Published var grainIntensity: Double = 0.5 {
        didSet {
            guard !isBatchUpdating else { return }
            UserDefaults.standard.set(grainIntensity, forKey: "arc_grain_intensity")
            ArcBackgroundSettings.shared.grainIntensity = grainIntensity
            VideoWallpaperManager.shared.refreshGrainOverlay()
        }
    }
    /// 隐藏刘海（菜单栏纯黑覆盖）
    @Published var hideNotch = false {
        didSet {
            guard !isBatchUpdating else { return }
            UserDefaults.standard.set(hideNotch, forKey: "hide_notch")
            NotchOverlayManager.shared.setEnabled(hideNotch)
        }
    }
    @Published var pauseWhenOtherAppForeground = false { didSet { UserDefaults.standard.set(pauseWhenOtherAppForeground, forKey: "pause_when_other_app_foreground") } }
    @Published var pauseWhenFullscreenCovers = false { didSet { UserDefaults.standard.set(pauseWhenFullscreenCovers, forKey: "pause_when_fullscreen_covers") } }
    @Published var pauseOnBatteryPower = false { didSet { UserDefaults.standard.set(pauseOnBatteryPower, forKey: "pause_on_battery_power") } }
    @Published var pauseWhenWindowCoverage = false { didSet { UserDefaults.standard.set(pauseWhenWindowCoverage, forKey: "pause_when_window_coverage") } }
    @Published var windowCoveragePauseThreshold: Double = 50 { didSet { UserDefaults.standard.set(windowCoveragePauseThreshold, forKey: "window_coverage_pause_threshold") } }
    @Published var hdrEnabled = true { didSet { UserDefaults.standard.set(hdrEnabled, forKey: "hdr_enabled") } }
    @Published var showAllWorkshopContent = false { didSet { UserDefaults.standard.set(showAllWorkshopContent, forKey: "show_all_workshop_content") } }
    /// 场景壁纸实时渲染模式开关
    /// 开启后，设置场景壁纸将使用 wallpaper-wgpu 实时渲染桌面，而非烘焙视频
    /// 与桌面动态元素（时钟、音频柱状图等）互斥
    @Published var sceneRealtimeRenderingEnabled = false {
        didSet {
            guard !isBatchUpdating else { return }
            UserDefaults.standard.set(sceneRealtimeRenderingEnabled, forKey: "scene_realtime_rendering_enabled")
            // 与桌面动态元素互斥
            if sceneRealtimeRenderingEnabled {
                LiquidGlassClockSettings.shared.update { $0.enabled = false }
            }
        }
    }

    /// 超分辨率模式开关
    /// 开启后，动态壁纸将以低分辨率运行，利用 Apple MetalFX 超分辨率技术提升性能
    @Published var upscalingEnabled = true {
        didSet { UserDefaults.standard.set(upscalingEnabled, forKey: "upscaling_enabled") }
    }

    /// 超分辨率缩放比例 (30% ~ 100%)
    @Published var upscalingPercent: Double = 70 {
        didSet { UserDefaults.standard.set(upscalingPercent, forKey: "upscaling_percent") }
    }

    /// 性能模式（--effect-reduction）：压缩次级采样等 effect 中间 RT 精度
    /// 仅在超分模式启用时生效；默认关闭以避免静默损失 effect 精度
    @Published var effectReductionEnabled = false {
        didSet { UserDefaults.standard.set(effectReductionEnabled, forKey: "effect_reduction_enabled") }
    }

    /// 壁纸引擎实时渲染帧率上限 (30 ~ 显示器最大刷新率)
    @Published var wallpaperEngineFPS: Double = 60 {
        didSet { UserDefaults.standard.set(wallpaperEngineFPS, forKey: "wallpaper_engine_fps") }
    }

    /// 壁纸引擎离线烘焙帧率 (15 ~ 60)
    @Published var sceneBakeFPS: Double = 30 {
        didSet { UserDefaults.standard.set(sceneBakeFPS, forKey: "scene_bake_fps") }
    }

    /// 壁纸引擎离线烘焙时长（秒）
    @Published var sceneBakeDuration: Double = 15 {
        didSet { UserDefaults.standard.set(sceneBakeDuration, forKey: "scene_bake_duration") }
    }

    /// 下载完成后自动烘焙场景壁纸
    @Published var autoBakeScene: Bool = true {
        didSet { UserDefaults.standard.set(autoBakeScene, forKey: "auto_bake_scene") }
    }

    /// 动态锁屏壁纸开关（仅 macOS 26+ 可用，关闭后走旧逻辑）
    @Published var dynamicLockScreenEnabled = false {
        didSet {
            // 非 macOS 26+ 系统强制关闭，不允许开启
            if #available(macOS 26.0, *) { } else {
                if dynamicLockScreenEnabled {
                    dynamicLockScreenEnabled = false
                    return
                }
            }
            UserDefaults.standard.set(dynamicLockScreenEnabled, forKey: "dynamic_lock_screen_enabled")
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
            UserDefaults.standard.set(systemWallpaperSyncEnabled, forKey: "system_wallpaper_sync_enabled")
            // 单向联动：关闭系统壁纸同步时，强制关闭动态锁屏并清理锁屏实例
            if !systemWallpaperSyncEnabled && dynamicLockScreenEnabled {
                dynamicLockScreenEnabled = false
                Task { @MainActor in
                    if #available(macOS 26.0, *) {
                        LockScreenWallpaperService.shared.clearLockScreenInstances()
                    }
                }
            }
            // 重新开启系统壁纸同步时，关闭并清除静态图 overlay（下次设壁纸走系统壁纸路径）
            if systemWallpaperSyncEnabled {
                StaticImageWallpaperOverlayManager.shared.clearState()
            }
        }
    }

    // MARK: - 功能模块开关（壁纸页 / 媒体页 / 动漫页）
    //
    // 三个开关默认开启。关闭后需重启生效：运行时门控读 `ModuleAvailability.shared` 启动快照，
    // 而非这三个标志——这样切换开关在当前会话不立即生效（避免 tab 树重建 / 管线半加载）。
    // `hasPendingModuleChanges` 对比快照判定"待应用"，UI 据此显示"立即重启"。
    @Published var wallpaperModuleEnabled: Bool = true {
        didSet { UserDefaults.standard.set(wallpaperModuleEnabled, forKey: "module_wallpaper_enabled") }
    }
    @Published var mediaModuleEnabled: Bool = true {
        didSet { UserDefaults.standard.set(mediaModuleEnabled, forKey: "module_media_enabled") }
    }
    @Published var animeModuleEnabled: Bool = true {
        didSet { UserDefaults.standard.set(animeModuleEnabled, forKey: "module_anime_enabled") }
    }

    @Published var proxyEnabled = false {
        didSet {
            guard !isBatchUpdating else { return }
            UserDefaults.standard.set(proxyEnabled, forKey: "proxy_enabled")
            syncProxySettings()
        }
    }
    @Published var proxyHost: String = "" {
        didSet {
            guard !isBatchUpdating else { return }
            UserDefaults.standard.set(proxyHost, forKey: "proxy_host")
            syncProxySettings()
        }
    }
    @Published var proxyPort: String = "" {
        didSet {
            guard !isBatchUpdating else { return }
            UserDefaults.standard.set(proxyPort, forKey: "proxy_port")
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
        UserDefaults.standard.set(grainTextureEnabled, forKey: "grain_texture_enabled")
        UserDefaults.standard.set(grainIntensity, forKey: "arc_grain_intensity")
        UserDefaults.standard.set(hideNotch, forKey: "hide_notch")
        UserDefaults.standard.set(sceneRealtimeRenderingEnabled, forKey: "scene_realtime_rendering_enabled")
        UserDefaults.standard.set(proxyEnabled, forKey: "proxy_enabled")
        UserDefaults.standard.set(proxyHost, forKey: "proxy_host")
        UserDefaults.standard.set(proxyPort, forKey: "proxy_port")

        // 单例级联副作用
        ArcBackgroundSettings.shared.grainTextureEnabled = grainTextureEnabled
        ArcBackgroundSettings.shared.grainIntensity = grainIntensity
        VideoWallpaperManager.shared.refreshGrainOverlay()
        NotchOverlayManager.shared.setEnabled(hideNotch)
        if sceneRealtimeRenderingEnabled {
            LiquidGlassClockSettings.shared.update { $0.enabled = false }
        }
        syncProxySettings()

        // 纯 UserDefaults 属性（批量期间 didSet 被跳过，统一补写）
        UserDefaults.standard.set(autoBakeScene, forKey: "auto_bake_scene")
        UserDefaults.standard.set(systemWallpaperSyncEnabled, forKey: "system_wallpaper_sync_enabled")
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
            UserDefaults.standard.set(trimmedValue, forKey: apiKeyUserDefaultsKey)

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
        let defaults = UserDefaults.standard
        withBatchUpdate {
            saveToDownloads = defaults.object(forKey: DownloadPathManager.persistDownloadsToAppLibraryDefaultsKey) as? Bool ?? true
            if let raw = defaults.string(forKey: "theme_mode"), let _ = ThemeMode(rawValue: raw) {
                themeModeRawValue = raw
            }
            launchAtLogin = defaults.bool(forKey: "launch_at_login")
            grainTextureEnabled = defaults.object(forKey: "grain_texture_enabled") as? Bool ?? false
            grainTextureQuality = defaults.string(forKey: "grain_texture_quality") ?? "high"
            let savedGrainIntensity = defaults.double(forKey: "arc_grain_intensity")
            grainIntensity = savedGrainIntensity > 0 ? savedGrainIntensity : 0.5
            hideNotch = defaults.bool(forKey: "hide_notch")
            pauseWhenOtherAppForeground = defaults.bool(forKey: "pause_when_other_app_foreground")
            pauseWhenFullscreenCovers = defaults.bool(forKey: "pause_when_fullscreen_covers")
            pauseOnBatteryPower = defaults.bool(forKey: "pause_on_battery_power")
            pauseWhenWindowCoverage = defaults.bool(forKey: "pause_when_window_coverage")
            let savedThreshold = defaults.double(forKey: "window_coverage_pause_threshold")
            windowCoveragePauseThreshold = savedThreshold > 0 ? savedThreshold : 50
            hdrEnabled = defaults.object(forKey: "hdr_enabled") as? Bool ?? true
            showAllWorkshopContent = defaults.bool(forKey: "show_all_workshop_content")
            sceneRealtimeRenderingEnabled = defaults.bool(forKey: "scene_realtime_rendering_enabled")
            upscalingEnabled = defaults.object(forKey: "upscaling_enabled") as? Bool ?? true
            upscalingPercent = defaults.object(forKey: "upscaling_percent") as? Double ?? 70
            effectReductionEnabled = defaults.object(forKey: "effect_reduction_enabled") as? Bool ?? false
            wallpaperEngineFPS = defaults.object(forKey: "wallpaper_engine_fps") as? Double ?? 60.0
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
    func syncAutoPauseSettings() {
        DynamicWallpaperAutoPauseManager.shared.pauseWhenOtherAppForeground = pauseWhenOtherAppForeground
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
        let urlCacheURL = cacheURL.appendingPathComponent("com.waifux.app/WaifuXCache")
        var urlCacheBytes = 0
        if let enumerator = FileManager.default.enumerator(at: urlCacheURL, includingPropertiesForKeys: [.fileSizeKey]) {
            while let fileURL = enumerator.nextObject() as? URL {
                let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                urlCacheBytes += size
            }
        }

        let totalBytes = cacheServiceBytes + urlCacheBytes
        let mb = Double(totalBytes) / 1_000_000
        cacheSize = String(format: "%.1f MB", mb)
        // 计算缓存进度（相对于 500MB 预估最大值）
        cacheProgress = min(Double(totalBytes) / Double(maxCacheSize), 1.0)
    }

    func clearCache() async {
        // 清除 CacheService 缓存
        try? await CacheService.shared.clearCache()

        // 清除 MediaService 缓存（包含分页数据）
        await MediaService.shared.clearCache()

        // 清除 URLCache 缓存
        guard let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            await updateCacheSize()
            return
        }
        let urlCacheURL = cacheURL.appendingPathComponent("com.waifux.app/WaifuXCache")
        try? FileManager.default.removeItem(at: urlCacheURL)
        try? FileManager.default.createDirectory(at: cacheURL.appendingPathComponent("com.wallhaven.app"), withIntermediateDirectories: true)

        await updateCacheSize()
    }

    /// 重置所有数据（缓存、UserDefaults、Application Support）
    func resetAllData() async {
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
                cacheURL.appendingPathComponent("com.waifux.app/WaifuXCache"),
                cacheURL.appendingPathComponent("WallHaven/ImageCache"),
                cacheURL.appendingPathComponent("com.waifux.app"),
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
        if let bundleId = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleId)
            UserDefaults.standard.synchronize()
        }

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
        if #available(macOS 14.0, *) {
            let service = SMAppService.mainApp
            do {
                if launchAtLogin {
                    try service.unregister()
                } else {
                    try service.register()
                }
                launchAtLogin.toggle()
            } catch {
                print("Failed to toggle launch at login: \(error)")
            }
        }
    }
}
