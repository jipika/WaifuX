import SwiftUI
import ServiceManagement

@MainActor
class SettingsViewModel: ObservableObject {
    @AppStorage("auto_download_original") var autoDownloadOriginal = false
    @AppStorage("save_to_downloads") var saveToDownloads = true
    @AppStorage("theme_mode") private var themeModeRawValue = ThemeMode.system.rawValue
    @AppStorage("launch_at_login") var launchAtLogin = false
    @AppStorage("grain_texture_enabled") var grainTextureEnabled = true
    @AppStorage("video_wallpaper_show_poster_on_lock") var showPosterOnLock = true

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

    // MARK: - 调度器相关
    @Published var schedulerViewModel = WallpaperSchedulerViewModel()
    @Published var downloadTaskViewModel = DownloadTaskViewModel()

    // API Key - 本地存储（UserDefaults 为主，与 WallpaperViewModel 保持同步）
    private let apiKeyUserDefaultsKey = "wallhaven_api_key"
    var apiKey: String {
        get { UserDefaults.standard.string(forKey: apiKeyUserDefaultsKey) ?? "" }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: apiKeyUserDefaultsKey)
        }
    }

    private let maxCacheSize: Int64 = 500_000_000 // 500MB 预估最大值

    init() {
        Task { await updateCacheSize() }
        refreshDataSourceProfiles()
        Task { await loadRuleRepository() }
        // 同步动态壁纸设置
        syncVideoWallpaperSettings()
    }
    
    /// 同步动态壁纸设置到 VideoWallpaperManager
    func syncVideoWallpaperSettings() {
        VideoWallpaperManager.shared.showPosterOnLock = showPosterOnLock
    }

    // MARK: - 更新检测

    /// 存储最新的 commit 信息
    @Published var latestCommit: GitHubCommit?

    func checkForUpdates() async {
        isCheckingUpdate = true
        updateCheckError = nil
        latestCommit = nil

        let result = await updateChecker.checkForUpdates()
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
        let urlCacheURL = cacheURL.appendingPathComponent("com.wallhaven.app/WallHavenCache")
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
        let urlCacheURL = cacheURL.appendingPathComponent("com.wallhaven.app/WallHavenCache")
        try? FileManager.default.removeItem(at: urlCacheURL)
        try? FileManager.default.createDirectory(at: cacheURL.appendingPathComponent("com.wallhaven.app"), withIntermediateDirectories: true)

        await updateCacheSize()
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
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

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
