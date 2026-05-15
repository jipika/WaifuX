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
            UserDefaults.standard.set(grainTextureEnabled, forKey: "grain_texture_enabled")
            ArcBackgroundSettings.shared.grainTextureEnabled = grainTextureEnabled
        }
    }
    @Published var grainTextureQuality = "high" { didSet { UserDefaults.standard.set(grainTextureQuality, forKey: "grain_texture_quality") } }
    /// 颗粒度强度 0.0~1.0，同步到 ArcBackgroundSettings.grainIntensity
    @Published var grainIntensity: Double = 0.5 {
        didSet {
            UserDefaults.standard.set(grainIntensity, forKey: "arc_grain_intensity")
            ArcBackgroundSettings.shared.grainIntensity = grainIntensity
        }
    }
    @Published var pauseWhenOtherAppForeground = false { didSet { UserDefaults.standard.set(pauseWhenOtherAppForeground, forKey: "pause_when_other_app_foreground") } }
    @Published var pauseWhenFullscreenCovers = false { didSet { UserDefaults.standard.set(pauseWhenFullscreenCovers, forKey: "pause_when_fullscreen_covers") } }
    @Published var pauseOnBatteryPower = false { didSet { UserDefaults.standard.set(pauseOnBatteryPower, forKey: "pause_on_battery_power") } }
    @Published var hdrEnabled = true { didSet { UserDefaults.standard.set(hdrEnabled, forKey: "hdr_enabled") } }
    @Published var showAllWorkshopContent = false { didSet { UserDefaults.standard.set(showAllWorkshopContent, forKey: "show_all_workshop_content") } }
    @Published var proxyEnabled = false { didSet { UserDefaults.standard.set(proxyEnabled, forKey: "proxy_enabled"); syncProxySettings() } }
    @Published var proxyHost: String = "" { didSet { UserDefaults.standard.set(proxyHost, forKey: "proxy_host"); syncProxySettings() } }
    @Published var proxyPort: String = "" { didSet { UserDefaults.standard.set(proxyPort, forKey: "proxy_port"); syncProxySettings() } }

    @Published var cacheSize: String = "0 MB"
    @Published var cacheProgress: Double = 0.0
    @Published var dataSourceProfiles: [DataSourceProfile] = []
    @Published var activeDataSourceProfileID: String = DataSourceProfileStore.builtinProfile.id
    @Published var dataSourceStatusMessage: String?

    // MARK: - 规则仓库相关
    @Published var ruleRepositoryURL: String = ""
    @Published var isRuleRepositoryConfigured: Bool = false
    @Published var currentRuleRepository: String = ""

    // MARK: - 更新检测相关
    @Published var updateChecker = UpdateChecker.shared
    @Published var updateCheckResult: UpdateCheckResult?
    @Published var isCheckingUpdate = false
    @Published var updateCheckError: String?

    private let ruleRepository = RuleRepository.shared
    private var cancellables = Set<AnyCancellable>()

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
        let defaults = UserDefaults.standard
        saveToDownloads = defaults.object(forKey: DownloadPathManager.persistDownloadsToAppLibraryDefaultsKey) as? Bool ?? true
        if let raw = defaults.string(forKey: "theme_mode"), let _ = ThemeMode(rawValue: raw) {
            themeModeRawValue = raw
        }
        launchAtLogin = defaults.bool(forKey: "launch_at_login")
        grainTextureEnabled = defaults.object(forKey: "grain_texture_enabled") as? Bool ?? false
        grainTextureQuality = defaults.string(forKey: "grain_texture_quality") ?? "high"
        let savedGrainIntensity = defaults.double(forKey: "arc_grain_intensity")
        grainIntensity = savedGrainIntensity > 0 ? savedGrainIntensity : 0.5
        pauseWhenOtherAppForeground = defaults.bool(forKey: "pause_when_other_app_foreground")
        pauseWhenFullscreenCovers = defaults.bool(forKey: "pause_when_fullscreen_covers")
        pauseOnBatteryPower = defaults.bool(forKey: "pause_on_battery_power")
        hdrEnabled = defaults.object(forKey: "hdr_enabled") as? Bool ?? true
        showAllWorkshopContent = defaults.bool(forKey: "show_all_workshop_content")
        proxyEnabled = defaults.bool(forKey: "proxy_enabled")
        proxyHost = defaults.string(forKey: "proxy_host") ?? ""
        proxyPort = defaults.string(forKey: "proxy_port") ?? ""

        // 恢复 API Key 缓存
        Self._cachedAPIKey = defaults.string(forKey: apiKeyUserDefaultsKey)
        Self._apiKeyRestored = true

        // 第二步：后台异步执行耗时操作
        Task(priority: .background) { @MainActor in
            // 小延迟确保 UI 先响应
            try? await Task.sleep(nanoseconds: 50_000_000) // 0.05秒
            refreshDataSourceProfiles()

            // 缓存计算和规则仓库加载可以并行
            async let cacheTask: () = updateCacheSize()
            async let repoTask: () = loadRuleRepository()
            _ = await (cacheTask, repoTask)
        }
    }

    /// 同步自动暂停设置到 DynamicWallpaperAutoPauseManager
    func syncAutoPauseSettings() {
        DynamicWallpaperAutoPauseManager.shared.pauseWhenOtherAppForeground = pauseWhenOtherAppForeground
        DynamicWallpaperAutoPauseManager.shared.pauseWhenFullscreenCovers = pauseWhenFullscreenCovers
        DynamicWallpaperAutoPauseManager.shared.pauseOnBatteryPower = pauseOnBatteryPower
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

    // MARK: - 更新检测

    /// 存储最新的 commit 信息
    @Published var latestCommit: GitHubCommit?

    func checkForUpdates(force: Bool = false) async {
        isCheckingUpdate = true
        updateCheckError = nil
        latestCommit = nil

        let result = await updateChecker.checkForUpdates(force: force)
        updateCheckResult = result

        // 提取 commit 信息
        if case .updateAvailable(_, _, let commit) = result {
            latestCommit = commit
        }

        if case .error(let message) = result {
            updateCheckError = message
        }

        isCheckingUpdate = false
    }

    func openDownloadPage() {
        if case .updateAvailable(_, let release, _) = updateCheckResult {
            updateChecker.openDownloadPage(for: release)
        } else {
            updateChecker.openDownloadPage()
        }
    }

    var hasUpdate: Bool {
        if case .updateAvailable = updateCheckResult {
            return true
        }
        return false
    }

    var latestVersion: String? {
        if case .updateAvailable(_, let release, _) = updateCheckResult {
            return release.version
        }
        return updateChecker.currentRelease?.version
    }

    // MARK: - 规则仓库

    private func loadRuleRepository() async {
        if let savedURL = UserDefaults.standard.string(forKey: "rule_repository_url") {
            currentRuleRepository = savedURL
            ruleRepositoryURL = savedURL
            isRuleRepositoryConfigured = true
        }

    }

    func saveRuleRepository() async {
        guard !ruleRepositoryURL.isEmpty else { return }

        do {
            try await ruleRepository.configure(repoURL: ruleRepositoryURL)
            currentRuleRepository = ruleRepositoryURL
            isRuleRepositoryConfigured = true

            // 同步所有规则
            try await ruleRepository.syncAllRules()
            dataSourceStatusMessage = "规则仓库配置成功并已同步"
        } catch {
            dataSourceStatusMessage = "配置失败: \(error.localizedDescription)"
        }
    }

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
