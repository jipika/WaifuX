import SwiftUI
import Combine
import AppKit
import Kingfisher

@MainActor
class WallpaperViewModel: ObservableObject {
    @Published var wallpapers: [Wallpaper] = []
    @Published var featuredWallpapers: [Wallpaper] = []
    @Published var topWallpapers: [Wallpaper] = []
    @Published var latestWallpapers: [Wallpaper] = []
    @Published var availableTags: [APITag] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var currentPage = 1
    @Published var hasMorePages = true
    @Published var searchQuery = ""
    @Published var selectedPurity: String = "sfw"  // sfw, sketchy, nsfw
    @Published var selectedCategory = "111" // 所有分类

    // MARK: - Network State
    @Published var networkStatus: NetworkStatus = .unknown
    private let networkMonitor = NetworkMonitor.shared

    // MARK: - Task Cancellation Support
    private var searchTask: Task<Void, Never>?
    private var loadMoreTask: Task<Void, Never>?

    // MARK: - 预加载支持
    private var preloadTask: Task<Void, Never>?
    private var preloadedResponse: WallpaperSearchResponse?

    // MARK: - 防抖搜索
    private var debounceTask: Task<Void, Never>?
    private let debounceInterval: TimeInterval = 0.3 // 300ms 防抖

    /// 本地壁纸缓存重建任务（带防抖）
    private var rebuildLocalWallpaperCacheTask: Task<Void, Never>?
    private var localWallpaperCacheRebuildID: UUID?
    /// 仅在主窗口释放前台资源后置为 true；空数组本身仍可能是一个有效的库快照。
    private var localWallpaperCacheNeedsRestore = false
    private var currentRandomSeed: String?



    // 分类开关
    @Published var categoryGeneral = true
    @Published var categoryAnime = true
    @Published var categoryPeople = true

    // 纯度开关
    @Published var puritySFW = true
    @Published var puritySketchy = false
    @Published var purityNSFW = false

    // 排序选项（用户选择过则跨启动持久化；恢复阶段通过 isRestoringExploreSort 跳过写入）
    @Published var sortingOption: SortingOption = .dateAdded {
        didSet {
            persistExploreSortIfNeeded(sortingOption.rawValue, key: Self.sortingOptionDefaultsKey, changed: sortingOption != oldValue)
        }
    }
    @Published var orderDescending = true

    // TopRange (用于 toplist 排序)
    @Published var topRange: TopRange = .oneMonth {
        didSet {
            persistExploreSortIfNeeded(topRange.rawValue, key: Self.topRangeDefaultsKey, changed: topRange != oldValue)
        }
    }

    // 附加筛选
    @Published var selectedResolutions: [String] = []
    @Published var selectedRatios: [String] = []
    @Published var selectedColors: [String] = []
    @Published var atleastResolution: String? = nil  // 最小分辨率，如 "3840x2160"
    @Published var selected4KCategorySlug: String? = nil  // 4K 源的分类 slug（如 "anime", "nature"）
    @Published var selected4KSorting: FourKSortingOption = .latest {  // 4K 源的排序方式
        didSet {
            persistExploreSortIfNeeded(selected4KSorting.rawValue, key: Self.fourKSortingDefaultsKey, changed: selected4KSorting != oldValue)
        }
    }
    @Published var selectedKonachanSorting: KonachanSorting = .dateAdded {  // Konachan 源的排序方式
        didSet {
            persistExploreSortIfNeeded(selectedKonachanSorting.rawValue, key: Self.konachanSortingDefaultsKey, changed: selectedKonachanSorting != oldValue)
        }
    }
    @Published var selectedPixivRankingMode: PixivRankingMode = .weekly {  // Pixiv 源的排行模式（默认周榜）
        didSet {
            persistExploreSortIfNeeded(selectedPixivRankingMode.rawValue, key: Self.pixivRankingModeDefaultsKey, changed: selectedPixivRankingMode != oldValue)
        }
    }
    @Published var selectedPixivWorkType: PixivWorkType = .all  // Pixiv 作品类型筛选
    @Published var selectedPixivSearchSort: PixivSearchSort = .dateD  // Pixiv 搜索排序
    @Published var pixivHideAI: Bool = false  // Pixiv 屏蔽 AI 作品
    @Published var pixivRelatedTags: [String] = []  // Pixiv 搜索相关标签

    // MARK: - Explore 排序持久化
    // ⚠️ 不在 init 读 UserDefaults（macOS 26+ _CFXPreferences 栈溢出风险），由 restoreExploreSortPreferences() 延迟恢复
    private static let sortingOptionDefaultsKey = "explore.wallpaper.sortingOption"
    private static let topRangeDefaultsKey = "explore.wallpaper.topRange"
    private static let fourKSortingDefaultsKey = "explore.wallpaper.fourKSorting"
    private static let konachanSortingDefaultsKey = "explore.wallpaper.konachanSorting"
    private static let pixivRankingModeDefaultsKey = "explore.wallpaper.pixivRankingMode"
    private var isRestoringExploreSort = false
    private var hasRestoredExploreSort = false

    private func persistExploreSortIfNeeded(_ value: String, key: String, changed: Bool) {
        guard changed, !isRestoringExploreSort else { return }
        UserDefaults.standard.set(value, forKey: key)
    }

    /// 从 UserDefaults 恢复探索排序；仅在用户曾选择过时覆盖默认值。
    /// 必须在 applicationDidFinishLaunching 之后调用，不可在 init 中调用。
    func restoreExploreSortPreferences() {
        guard !hasRestoredExploreSort else { return }
        hasRestoredExploreSort = true
        isRestoringExploreSort = true
        defer { isRestoringExploreSort = false }

        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: Self.sortingOptionDefaultsKey),
           let option = SortingOption(rawValue: raw) {
            sortingOption = option
        }
        if let raw = defaults.string(forKey: Self.topRangeDefaultsKey),
           let range = TopRange(rawValue: raw) {
            topRange = range
        }
        if let raw = defaults.string(forKey: Self.fourKSortingDefaultsKey),
           let option = FourKSortingOption(rawValue: raw) {
            selected4KSorting = option
        }
        if let raw = defaults.string(forKey: Self.konachanSortingDefaultsKey),
           let option = KonachanSorting(rawValue: raw) {
            selectedKonachanSorting = option
        }
        if let raw = defaults.string(forKey: Self.pixivRankingModeDefaultsKey),
           let mode = PixivRankingMode(rawValue: raw) {
            selectedPixivRankingMode = mode
        }
    }

    // MARK: - 本地收藏与下载记录
    private let wallpaperLibrary = WallpaperLibraryService.shared
    private let downloadTaskService = DownloadTaskService.shared
    private let downloadPathManager = DownloadPathManager.shared
    private var cancellables = Set<AnyCancellable>()

    /// 收藏/下载库变更时递增；与 `cachedAllLocalWallpapers` 一起驱动依赖 `isFavorite` / 列表的视图刷新。
    @Published private(set) var libraryContentRevision: UInt = 0

    // MARK: - 调度器服务
    private let schedulerService = WallpaperSchedulerService.shared

    private let networkService = NetworkService.shared
    private let sourceManager = WallpaperSourceManager.shared

    /// 壁纸源切换消息（供 UI 层显示 Toast）
    var sourceSwitchMessage: String? {
        sourceManager.lastSwitchMessage
    }

    // API Key - 使用 Keychain 安全存储（优化：内存缓存 + 异步访问）
    private let apiKeyService = "com.waifux.wallhaven.apikey"
    private let apiKeyAccount = "wallhaven_api_key"

    // 内存缓存，避免重复 Keychain 访问
    @Published private var cachedAPIKey: String?
    private var apiKeyLoaded = false

    /// ⚠️ 启动时缓存的 effectiveAPIKey（从 UserDefaults 延迟读取，避免 _CFXPreferences 栈溢出）
    /// 使用 static 保证所有实例共享（必须在 AppDelegate 中调用 restoreAPIKeyState() 初始化）
    private static var _launchCachedEffectiveKey: String? = nil

    /// 异步加载 API Key（在后台线程执行 Keychain 操作）
    private func loadAPIKeyAsync() async -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: apiKeyService,
            kSecAttrAccount as String: apiKeyAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        return await Task.detached(priority: .utility) {
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)

            guard status == errSecSuccess,
                  let data = result as? Data,
                  let key = String(data: data, encoding: .utf8) else {
                return nil
            }
            return key.trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }

    /// 异步保存 API Key
    private func saveAPIKeyAsync(_ value: String) async {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: apiKeyService,
            kSecAttrAccount as String: apiKeyAccount
        ]

        await Task.detached(priority: .utility) {
            // 先删除已存在的项
            SecItemDelete(query as CFDictionary)

            // 添加新值
            guard !value.isEmpty else { return }

            let attributes: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: self.apiKeyService,
                kSecAttrAccount as String: self.apiKeyAccount,
                kSecValueData as String: value.data(using: .utf8)!
            ]

            SecItemAdd(attributes as CFDictionary, nil)
        }.value
    }

    /// 获取 API Key（优先从内存缓存读取）
    var apiKey: String {
        get {
            // 如果已经加载过，直接返回缓存值
            if apiKeyLoaded {
                return cachedAPIKey ?? ""
            }
            // 首次访问时同步返回空字符串，异步加载
            Task {
                await loadAPIKeyIfNeeded()
            }
            return ""
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            cachedAPIKey = trimmed.isEmpty ? nil : trimmed
            apiKeyLoaded = true
            // 异步保存到 Keychain
            Task {
                await saveAPIKeyAsync(trimmed)
            }
        }
    }

    /// 异步加载 API Key 到内存缓存
    @MainActor
    private func loadAPIKeyIfNeeded() async {
        guard !apiKeyLoaded else { return }
        cachedAPIKey = await loadAPIKeyAsync()
        apiKeyLoaded = true
    }

    private var normalizedAPIKey: String? {
        // 使用统一的有效 API Key 检查逻辑
        effectiveAPIKey
    }

    var apiKeyConfigured: Bool {
        // 使用统一的检查逻辑：优先 UserDefaults，其次 Keychain
        canShowNSFW
    }

    /// 缓存的本地壁纸列表，避免每次 body 重绘时重复计算和文件 I/O
    @Published var cachedAllLocalWallpapers: [UnifiedLocalWallpaper] = []

    init() {
        // ⚠️ 不在 init 读 UserDefaults；探索排序由 restoreExploreSortPreferences() 延迟恢复
        // 注册内存压力通知
        NotificationCenter.default.addObserver(
            forName: .appDidReceiveMemoryPressure,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor [weak self] in
                self?.handleMemoryPressure()
            }
        }

        // MARK: - 优化后的 Service 数据变更监听：保护主线程免受 I/O 阻塞
        Publishers.Merge(
            wallpaperLibrary.$favoriteRecords.map { _ in () },
            wallpaperLibrary.$downloadRecords.map { _ in () }
        )
        // 1. ⚙️ 不要在主线程接收原始通知，直接在当前的后台或默认管道处理
        .sink { [weak self] _ in
            guard let self else { return }

            // 2. 🚀 调度缓存重建（scheduleLocalWallpaperCacheRebuild 本身只是取消旧 Task + 创建新 Task，
            // 核心重算 rebuildLocalWallpaperCache 内部已用 Task.detached 投到后台 Utility 线程，
            // 此处仅需轻量调度，不会阻塞主线程。）
            Task { @MainActor [weak self] in
                self?.scheduleLocalWallpaperCacheRebuild(delayNanoseconds: 100_000_000)
            }

            // 3. 🎨 仅仅将极其轻量的版本号递增（O(1) 状态变更）交还给主线程驱动 UI
            Task { @MainActor [weak self] in
                self?.libraryContentRevision &+= 1
            }
        }
        .store(in: &cancellables)

        // 初始重建一次缓存
        scheduleLocalWallpaperCacheRebuild(delayNanoseconds: 0)

        // 监听网络状态变化
        networkMonitor.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.networkStatus = status
                // 网络恢复时自动刷新（壁纸模块关闭时跳过，避免禁用后仍触发 Wallhaven 请求）
                if status.connectionState.isConnected
                    && self?.wallpapers.isEmpty == true
                    && ModuleAvailability.shared.wallpaperEnabled {
                    Task { await self?.search() }
                }
            }
            .store(in: &cancellables)

        // 启动网络监测
        networkMonitor.startMonitoring()

        // 设置网络监测器到网络服务
        Task {
            await networkService.setNetworkMonitor(networkMonitor)
        }
    }

    // MARK: - 是否可以显示 NSFW 内容
    var canShowNSFW: Bool {
        // ⚠️ 绝对不能直接读 UserDefaults.standard！macOS 26+ 会触发 _CFXPreferences 递归栈溢出
        // 使用启动时缓存的值（由 AppDelegate.restoreAPIKeyState() 初始化）
        if let cached = Self._launchCachedEffectiveKey {
            return !cached.isEmpty
        }
        // 启动恢复之前：回退到 Keychain 缓存（不触发 UserDefaults）
        return !(cachedAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    /// 获取有效的 API Key（统一从 UserDefaults 优先，兼容 Keychain）
    /// 设置页通过 UserDefaults 写入，业务逻辑从这里读取，保证一致性
    var effectiveAPIKey: String? {
        // ⚠️ 绝对不能直接读 UserDefaults.standard！使用启动缓存
        if let cached = Self._launchCachedEffectiveKey, !cached.isEmpty {
            return cached
        }
        // 启动恢复之前：回退到 Keychain 缓存
        if apiKeyLoaded, let cached = cachedAPIKey, !cached.isEmpty { return cached }
        return nil
    }

    /// ⚠️ 延迟恢复 API Key 状态（必须在 AppDelegate.applicationDidFinishLaunching 中调用）
    /// 从 UserDefaults 安全地读取 API Key 并缓存到内存中（static，所有实例共享）
    func restoreAPIKeyState() {
        let settingsKey = UserDefaults.standard.string(forKey: "wallhaven_api_key")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        Self._launchCachedEffectiveKey = settingsKey.isEmpty ? nil : settingsKey

        // 同步加载 Keychain 到内存缓存
        Task {
            await loadAPIKeyIfNeeded()
        }
    }

    /// 供外部（如 SettingsViewModel）调用以实时更新 API Key 缓存
    static func updateSharedAPIKeyCache(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        Self._launchCachedEffectiveKey = trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - 收藏相关
    var favorites: [Wallpaper] {
        wallpaperLibrary.favoriteWallpapers
    }

    var downloadedWallpapers: [WallpaperDownloadRecord] {
        wallpaperLibrary.downloadedWallpapers
    }

    /// 所有可显示的本地壁纸。导入和下载都会同步创建持久化记录，
    /// 因此库页面只读该记录缓存，不再枚举下载目录。
    var allLocalWallpapers: [UnifiedLocalWallpaper] {
        cachedAllLocalWallpapers
    }

    /// 确保本地壁纸索引可供库页面使用。
    /// 缓存失效时会合并并发请求，避免多个视图重复从持久化记录重建同一份快照。
    func ensureLocalWallpaperIndex() async {
        guard localWallpaperCacheNeedsRestore else { return }
        if let task = rebuildLocalWallpaperCacheTask {
            await task.value
            return
        }
        await startLocalWallpaperCacheRebuild(delayNanoseconds: 0).value
    }

    /// 重建本地壁纸缓存（在 downloadRecords / favoriteRecords 变化时自动调用）
    private func scheduleLocalWallpaperCacheRebuild(delayNanoseconds: UInt64) {
        _ = startLocalWallpaperCacheRebuild(delayNanoseconds: delayNanoseconds)
    }

    @discardableResult
    private func startLocalWallpaperCacheRebuild(delayNanoseconds: UInt64) -> Task<Void, Never> {
        rebuildLocalWallpaperCacheTask?.cancel()
        let rebuildID = UUID()
        localWallpaperCacheRebuildID = rebuildID

        let task = Task { @MainActor [weak self] in
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard let self, !Task.isCancelled else { return }
            await self.rebuildLocalWallpaperCache()
            guard self.localWallpaperCacheRebuildID == rebuildID else { return }
            self.rebuildLocalWallpaperCacheTask = nil
            self.localWallpaperCacheRebuildID = nil
        }
        rebuildLocalWallpaperCacheTask = task
        return task
    }

    /// 从持久化下载记录重建库页面缓存。此路径不访问文件系统。
    private func rebuildLocalWallpaperCache() async {
        let downloads = wallpaperLibrary.downloadedWallpapers

        let result = await Task.detached(priority: .utility) {
            downloads.map { record in
                UnifiedLocalWallpaper(
                    id: record.wallpaper.id,
                    wallpaper: record.wallpaper,
                    localItem: nil,
                    downloadRecord: record,
                    fileURL: record.localFileURL,
                    isLocalFile: false
                )
            }
            .sorted {
                ($0.downloadRecord?.downloadedAt ?? .distantPast)
                    > ($1.downloadRecord?.downloadedAt ?? .distantPast)
            }
        }.value

        guard !Task.isCancelled else { return }
        cachedAllLocalWallpapers = result
        localWallpaperCacheNeedsRestore = false
        // 缓存重建完成后递增版本号，触发 MyLibraryContentView 的
        // .onChange → debouncedUpdateWallpaperItems()，让依赖缓存的
        // 标签页（如「下载」）在拖拽入库等操作后能读到新鲜数据。
        libraryContentRevision &+= 1
    }

    /// 显式清理无效下载记录（文件不存在的记录），不应在 computed property 中自动调用
    func cleanupInvalidDownloadRecords() {
        wallpaperLibrary.cleanupInvalidDownloadRecords()
        scheduleLocalWallpaperCacheRebuild(delayNanoseconds: 0)
    }

    var favoriteSyncRecords: [WallpaperFavoriteRecord] {
        wallpaperLibrary.favoriteRecords
    }

    /// ✅ O(1) 收藏 ID 集合，供视图在 ForEach 中直接读取。
    /// 依赖 `libraryContentRevision` 驱动 SwiftUI 自动重算，无需额外的 @State 中转。
    var favoriteIDSet: Set<String> {
        Set(favoriteSyncRecords.lazy.filter(\.isActive).map(\.wallpaper.id))
    }

    var downloadSyncRecords: [WallpaperDownloadRecord] {
        wallpaperLibrary.downloadRecords
    }

    func isFavorite(_ wallpaper: Wallpaper) -> Bool {
        wallpaperLibrary.isFavorite(wallpaper)
    }

    func isDownloaded(_ wallpaper: Wallpaper) -> Bool {
        wallpaperLibrary.isDownloaded(wallpaper)
    }

    /// 获取已下载壁纸的本地文件 URL（如果存在）
    func localFileURLIfAvailable(for wallpaper: Wallpaper) -> URL? {
        wallpaperLibrary.localFileURLIfAvailable(for: wallpaper)
    }

    func toggleFavorite(_ wallpaper: Wallpaper) {
        wallpaperLibrary.toggleFavorite(wallpaper)
    }

    /// 刷新收藏和下载数据（删除操作后调用）
    func loadFavorites() {
        libraryContentRevision &+= 1
    }

    // MARK: - 壁纸批量删除

    /// 批量删除壁纸收藏
    /// - Parameter ids: 要删除的项目 ID 集合
    func removeWallpaperFavorites(withIDs ids: Set<String>) {
        wallpaperLibrary.removeWallpaperFavorites(withIDs: ids)
    }

    /// 批量删除壁纸下载记录
    /// - Parameter ids: 要删除的项目 ID 集合
    func removeWallpaperDownloads(withIDs ids: Set<String>) {
        wallpaperLibrary.removeWallpaperDownloads(withIDs: ids)
    }

    /// 详情页删除本地壁纸。正常导入内容始终存在下载记录；
    /// 路径兜底保留给旧版本遗留数据。
    @discardableResult
    func deleteLocalWallpaper(_ wallpaper: Wallpaper) -> Bool {
        var idsToRemove = Set<String>()
        var pathsToDelete = Set<String>()

        // 1) 按 ID 命中下载记录（含导入的 local_import_*）
        if let record = wallpaperLibrary.downloadRecord(for: wallpaper.id) {
            idsToRemove.insert(record.wallpaper.id)
            pathsToDelete.insert((record.localFilePath as NSString).standardizingPath as String)
        }

        // 2) 解析本地文件路径：下载缓存 / fullImageURL / path 字段
        var candidateURLs: [URL] = []
        if let u = wallpaperLibrary.localFileURLIfAvailable(for: wallpaper) {
            candidateURLs.append(u)
        }
        if let u = wallpaper.fullImageURL, u.isFileURL {
            candidateURLs.append(u)
        }
        if let u = URL(string: wallpaper.path), u.isFileURL {
            candidateURLs.append(u)
        } else if wallpaper.path.hasPrefix("/") {
            candidateURLs.append(URL(fileURLWithPath: wallpaper.path))
        }

        for url in candidateURLs where url.isFileURL {
            let path = (url.path as NSString).standardizingPath as String
            guard !path.isEmpty else { continue }
            pathsToDelete.insert(path)

            // 扫描 ID 与导入 ID 可能不一致，再按路径反查下载记录
            if let byPath = wallpaperLibrary.downloadRecord(forLocalFilePath: path)
                ?? wallpaperLibrary.downloadRecords.first(where: {
                    $0.isActive && (($0.localFilePath as NSString).standardizingPath as String) == path
                }) {
                idsToRemove.insert(byPath.wallpaper.id)
                pathsToDelete.insert((byPath.localFilePath as NSString).standardizingPath as String)
            }
        }

        // 3) 软删下载记录（内部会尽量删物理文件）
        if !idsToRemove.isEmpty {
            wallpaperLibrary.removeWallpaperDownloads(withIDs: idsToRemove)
        }

        // 4) 兜底删物理文件（旧版本记录删完文件仍在）
        var deletedFile = false
        let derivedWallpapersDirectory = DownloadPathManager.shared.derivedWallpapersFolderURL
        for path in pathsToDelete {
            let sourceURL = URL(fileURLWithPath: path)
            Task {
                await PortraitBlurFillWallpaperService.shared.removeArtifacts(
                    for: sourceURL,
                    derivedWallpapersDirectory: derivedWallpapersDirectory
                )
            }
            guard FileManager.default.fileExists(atPath: path) else { continue }
            do {
                try FileManager.default.removeItem(atPath: path)
                print("[WallpaperViewModel] ✅ Deleted local wallpaper file: \(path)")
                deletedFile = true
            } catch {
                print("[WallpaperViewModel] ⚠️ Failed to delete local wallpaper file \(path): \(error)")
            }
        }

        let didSomething = !idsToRemove.isEmpty || deletedFile
        if didSomething {
            scheduleLocalWallpaperCacheRebuild(delayNanoseconds: 0)
        }
        return didSomething
    }

    // MARK: - 通过 URL 解析壁纸

    /// 提取 Wallhaven 壁纸 ID。
    /// 支持：
    /// - `https://wallhaven.cc/w/{id}` / `.../wallpaper/{id}`
    /// - 短链 `https://whvn.cc/{id}`（详情页「复制链接」常见格式，会 301 到 wallhaven.cc/w/{id}）
    /// - 裸 ID（如 `po71m9`）
    static func extractWallhavenID(from urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 裸 ID：Wallhaven 壁纸 ID 为 5–7 位字母数字（常见 6 位）
        if Self.isWallhavenWallpaperID(trimmed) {
            return trimmed
        }

        guard let url = URL(string: trimmed), let host = url.host?.lowercased() else { return nil }
        let pathComponents = url.pathComponents.filter { $0 != "/" }

        // 短链：whvn.cc/{id}（也可能是 whvn.cc/w/{id}）
        if host == "whvn.cc" || host.hasSuffix(".whvn.cc") {
            if pathComponents.count == 1, Self.isWallhavenWallpaperID(pathComponents[0]) {
                return pathComponents[0]
            }
            if let idIndex = pathComponents.firstIndex(where: { $0 == "w" || $0 == "wallpaper" }),
               idIndex + 1 < pathComponents.count,
               Self.isWallhavenWallpaperID(pathComponents[idIndex + 1]) {
                return pathComponents[idIndex + 1]
            }
            return nil
        }

        // 正式站：wallhaven.cc/w/{id} 或 /wallpaper/{id}
        guard host.contains("wallhaven") else { return nil }
        if let idIndex = pathComponents.firstIndex(where: { $0 == "w" || $0 == "wallpaper" }),
           idIndex + 1 < pathComponents.count,
           Self.isWallhavenWallpaperID(pathComponents[idIndex + 1]) {
            return pathComponents[idIndex + 1]
        }
        return nil
    }

    /// Wallhaven 壁纸 ID：仅字母数字，长度 5–7（官方短链 /w/ 与 whvn.cc 一致）。
    private static func isWallhavenWallpaperID(_ value: String) -> Bool {
        let id = value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard (5...7).contains(id.count) else { return false }
        return id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
    }

    /// 提取 4KWallpapers 详情页 URL（4kwallpapers.com/.../{name}-{id}.html）
    static func extract4KWallpapersDetailURL(from urlString: String) -> URL? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let host = url.host?.lowercased(),
              host.contains("4kwallpapers.com") else { return nil }
        let path = url.path.lowercased()
        guard path.hasSuffix(".html"), path.contains("-") else { return nil }
        return url
    }

    /// 提取 Konachan post ID（konachan.com|net/post/show/{id}）
    static func extractKonachanID(from urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let host = url.host?.lowercased(),
              host.contains("konachan") else { return nil }
        let components = url.pathComponents
        // /post/show/{id}
        if let showIndex = components.firstIndex(of: "show"),
           showIndex + 1 < components.count {
            let id = components[showIndex + 1]
            if id.allSatisfy(\.isNumber) { return id }
        }
        // 兜底：路径末段为纯数字
        if let last = components.last, last.allSatisfy(\.isNumber) {
            return last
        }
        return nil
    }

    /// 提取 Pixiv 作品 ID（pixiv.net/artworks/{id} 或 /i/{id}）
    static func extractPixivID(from urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let host = url.host?.lowercased(),
              host.contains("pixiv.net") else { return nil }
        let components = url.pathComponents
        if let artworksIndex = components.firstIndex(of: "artworks"),
           artworksIndex + 1 < components.count {
            let id = components[artworksIndex + 1]
            if id.allSatisfy(\.isNumber) { return id }
        }
        // 旧式 /i/{id}
        if let iIndex = components.firstIndex(of: "i"),
           iIndex + 1 < components.count {
            let id = components[iIndex + 1]
            if id.allSatisfy(\.isNumber) { return id }
        }
        // 查询参数 illust_id=
        if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let illustID = comps.queryItems?.first(where: { $0.name == "illust_id" })?.value,
           illustID.allSatisfy(\.isNumber) {
            return illustID
        }
        return nil
    }

    /// 通过链接解析壁纸，支持 Wallhaven / 4KWallpapers / Konachan / Pixiv
    func resolveWallpaperByURL(_ urlString: String) async throws -> Wallpaper {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)

        if let wallpaperID = Self.extractWallhavenID(from: trimmed) {
            return try await resolveWallhavenWallpaperByID(wallpaperID)
        }
        if let detailURL = Self.extract4KWallpapersDetailURL(from: trimmed) {
            return try await resolve4KWallpaperByDetailURL(detailURL)
        }
        if let konachanID = Self.extractKonachanID(from: trimmed) {
            return try await resolveKonachanWallpaperByID(konachanID)
        }
        if let pixivID = Self.extractPixivID(from: trimmed) {
            return try await resolvePixivWallpaperByID(pixivID)
        }

        throw NSError(
            domain: "WaifuX",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "无法解析此链接，仅支持 Wallhaven / 4KWallpapers / Konachan / Pixiv 详情页链接"]
        )
    }

    /// 通过 Wallhaven API 按 ID 获取壁纸详情
    private func resolveWallhavenWallpaperByID(_ id: String) async throws -> Wallpaper {
        guard let url = WallhavenAPI.url(for: .wallpaper(id: id)) else {
            throw NetworkError.invalidResponse
        }
        let response = try await networkService.fetch(
            WallpaperDetailResponse.self,
            from: url,
            headers: WallhavenAPI.authenticationHeaders(apiKey: normalizedAPIKey)
        )
        return response.data
    }

    /// 通过 4KWallpapers 详情页 URL 构造可打开的 Wallpaper
    private func resolve4KWallpaperByDetailURL(_ detailURL: URL) async throws -> Wallpaper {
        // 先用详情页 URL 构造最小可用模型，再尝试解析原图
        let fileName = detailURL.deletingPathExtension().lastPathComponent
        let idPart = fileName.split(separator: "-").last.map(String.init) ?? fileName
        var wallpaper = Wallpaper(
            id: "4k_\(idPart)",
            title: nil,
            url: detailURL.absoluteString,
            shortUrl: nil,
            views: 0,
            favorites: 0,
            downloads: nil,
            source: "4kwallpapers",
            purity: "sfw",
            category: "general",
            dimensionX: 3840,
            dimensionY: 2160,
            resolution: "3840x2160",
            ratio: "1.78",
            fileSize: nil,
            fileType: "image/jpeg",
            createdAt: nil,
            colors: [],
            path: detailURL.absoluteString,
            thumbs: Wallpaper.Thumbs(
                large: detailURL.absoluteString,
                original: detailURL.absoluteString,
                small: detailURL.absoluteString
            ),
            tags: nil,
            uploader: nil
        )

        if let originalURL = await FourKWallpapersService.shared.fetchOriginalImageURL(for: wallpaper),
           !originalURL.isEmpty {
            wallpaper = Wallpaper(
                id: wallpaper.id,
                title: wallpaper.title,
                url: wallpaper.url,
                shortUrl: wallpaper.shortUrl,
                views: wallpaper.views,
                favorites: wallpaper.favorites,
                downloads: wallpaper.downloads,
                source: wallpaper.source,
                purity: wallpaper.purity,
                category: wallpaper.category,
                dimensionX: wallpaper.dimensionX,
                dimensionY: wallpaper.dimensionY,
                resolution: wallpaper.resolution,
                ratio: wallpaper.ratio,
                fileSize: wallpaper.fileSize,
                fileType: wallpaper.fileType,
                createdAt: wallpaper.createdAt,
                colors: wallpaper.colors,
                path: originalURL,
                thumbs: Wallpaper.Thumbs(
                    large: originalURL,
                    original: originalURL,
                    small: originalURL
                ),
                tags: wallpaper.tags,
                uploader: wallpaper.uploader
            )
        }
        return wallpaper
    }

    /// 通过 Konachan post ID 获取壁纸
    private func resolveKonachanWallpaperByID(_ id: String) async throws -> Wallpaper {
        // .all 不附加 rating 标签，并让服务从包含 explicit 帖子的 .com 查询。
        let response = try await KonachanService.shared.search(
            query: "id:\(id)",
            page: 1,
            perPage: 1,
            purity: .all,
            sorting: .dateAdded
        )
        if let wallpaper = response.data.first {
            return wallpaper
        }
        throw NSError(
            domain: "WaifuX",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "未找到 Konachan 壁纸（id=\(id)）"]
        )
    }

    /// 通过 Pixiv 作品 ID 获取壁纸
    private func resolvePixivWallpaperByID(_ id: String) async throws -> Wallpaper {
        let detail = try await PixivService.shared.illustDetail(id: id)
        return detail.toWallpaper()
    }

    /// 对外公开的壁纸详情获取接口（供 WallpaperDetailSheet 调用以补充 uploader 数据）
    /// - Parameter id: Wallhaven 壁纸 ID
    /// - Returns: 壁纸详情数据（含 uploader）
    func fetchWallpaperDetail(byID id: String) async throws -> Wallpaper {
        try await resolveWallhavenWallpaperByID(id)
    }

    // MARK: - 分享
    func shareWallpaper(_ wallpaper: Wallpaper, from view: NSView? = nil) {
        guard let url = URL(string: wallpaper.url) else { return }
        let picker = NSSharingServicePicker(items: [url])
        if let view = view {
            picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        } else {
            // 如果没有提供view，至少复制到剪贴板
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(wallpaper.url, forType: .string)
        }
    }

    /// 分享已下载到本地的壁纸文件（静图尽量用 `NSImage`，视频用文件 URL）
    /// - Parameter anchorView: 传入时分享面板相对该视图定位（通常为按钮背后的锚定 `NSView`）
    func shareDownloadedWallpaperIfAvailable(_ wallpaper: Wallpaper, anchorView: NSView? = nil) {
        guard let fileURL = wallpaperLibrary.localFileURLIfAvailable(for: wallpaper) else { return }
        let items = SystemShareSupport.itemsForLocalFile(at: fileURL)
        SystemShareSupport.presentPicker(items: items, anchorView: anchorView)
    }

    // MARK: - 防抖搜索
    func searchDebounced() {
        debounceTask?.cancel()

        debounceTask = Task { [weak self] in
            guard let self = self else { return }

            // 等待防抖间隔
            try? await Task.sleep(nanoseconds: UInt64(self.debounceInterval * 1_000_000_000))

            // 检查是否被取消
            guard !Task.isCancelled else { return }

            await self.search()
        }
    }

    // MARK: - 搜索（支持 Task Cancellation）
    func search() async {
        // 取消之前的搜索任务和防抖任务
        searchTask?.cancel()
        debounceTask?.cancel()

        // 等待当前搜索任务完成或取消，避免竞态条件
        if isLoading {
            // 给当前任务一个取消的机会
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            // 如果仍然加载中，继续执行（新搜索优先）
        }

        isLoading = true
        errorMessage = nil
        currentPage = 1
        currentRandomSeed = nil

        // ⚠️ 不再在此处清空 wallpapers：
        // 旧数据继续保留到本次搜索结果到达后被一次性替换（见 wallpapers = results.data）。
        // 这样可避免"加载中 → 暂无数据 → 数据出现"的中间闪烁：
        // View 层判断 `isLoading && visibleWallpapers.isEmpty` 才会显示加载指示器，
        // 若清空则有一帧会走到 else 分支展示 emptyState。
        // 真正的"清空"语义在 reset()/deinit 里已保留。

        // 重置预加载状态
        preloadTask?.cancel()
        preloadedResponse = nil

        // 创建新的搜索任务
        searchTask = Task {
            do {
                // 检查是否被取消
                try Task.checkCancellation()

                let results = try await fetchWallpapers(query: searchQuery, page: 1)

                // 再次检查是否被取消
                try Task.checkCancellation()

                currentRandomSeed = sortingOption == .random ? results.meta.seed : nil

                // 先更新壁纸库（后台操作）
                wallpaperLibrary.upsertBatch(results.data)

                // 一次性替换 wallpapers
                wallpapers = results.data

                hasMorePages = 1 < results.meta.lastPage

                if results.data.isEmpty {
                    errorMessage = t("explore.noResults")
                } else {
                    // 预加载前几张图片
                    preloadImages(for: Array(results.data.prefix(4)))
                }
            } catch is CancellationError {
                isLoading = false
                return
            } catch let error as URLError where error.code == .cancelled {
                isLoading = false
                return
            } catch {
                errorMessage = error.localizedDescription
            }

            isLoading = false
        }

        await searchTask?.value
    }

    func previewSearch(query: String, limit: Int = 8) async throws -> [Wallpaper] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return [] }

        let parameters = WallhavenAPI.SearchParameters(
            query: trimmedQuery,
            page: 1,
            categories: normalizedCategoryMask(),
            purity: normalizedPurityMask(),
            sorting: SortingOption.relevance.rawValue,
            order: "desc",
            topRange: nil,
            atleast: atleastResolution,
            resolutions: normalizedResolutions(),
            ratios: normalizedRatios(),
            colors: normalizedColors()
        )

        let response = try await fetchWallpapers(parameters: parameters)
        wallpaperLibrary.upsertBatch(response.data)
        return Array(response.data.prefix(limit))
    }

    // MARK: - 按作者搜索壁纸

    /// 获取指定作者的所有壁纸（使用 Wallhaven API 的 `@username` 语法）
    /// - Parameters:
    ///   - username: 作者用户名
    ///   - page: 页码，从 1 开始
    /// 作者列表分页结果。hasMore 由服务端/切片语义决定，避免转换过滤后误判。
    struct AuthorPageResult {
        let items: [Wallpaper]
        let hasMore: Bool
    }

    ///   - limit: 每页数量，默认 24
    /// - Returns: 本页壁纸 + 是否还有下一页
    func fetchWallpapersByAuthor(username: String, page: Int = 1, limit: Int = 24) async throws -> AuthorPageResult {
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUsername.isEmpty else {
            return AuthorPageResult(items: [], hasMore: false)
        }

        let parameters = WallhavenAPI.SearchParameters(
            query: "@\(trimmedUsername)",
            page: page,
            perPage: limit,
            categories: "111",      // 不限分类，查全量
            purity: "111",          // 作者列表不过滤内容分级（SFW + Sketchy + NSFW）
            sorting: SortingOption.dateAdded.rawValue,
            order: "desc",
            topRange: nil,
            atleast: nil,           // 不限分辨率
            resolutions: [],        // 不限分辨率列表
            ratios: [],             // 不限比例
            colors: []              // 不限颜色
        )

        // 作者列表固定走 Wallhaven，不受探索页 activeSource 影响
        let response = try await fetchFromWallhaven(parameters: parameters)
        wallpaperLibrary.upsertBatch(response.data)
        // 优先用 API lastPage；异常源没有可靠 meta 时回退到满页启发式。
        let hasMore = response.meta.lastPage > 0
            ? page < response.meta.lastPage
            : response.data.count >= limit
        return AuthorPageResult(items: response.data, hasMore: hasMore)
    }

    /// Pixiv 作者作品 ID 列表缓存，避免每页重复请求 profile/all。
    private var pixivAuthorIllustIDCache: [String: [String]] = [:]

    /// 获取指定 Pixiv 作者的插画作品。Pixiv 先返回用户的全部插画 ID，再批量补齐当前页的作品信息。
    func fetchPixivWallpapersByAuthor(userID: String, page: Int = 1, limit: Int = 24) async throws -> AuthorPageResult {
        let trimmedUserID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUserID.isEmpty, page > 0, limit > 0 else {
            return AuthorPageResult(items: [], hasMore: false)
        }

        // Pixiv /profile/illusts 单次最多 24 个 ids[]
        let pageLimit = min(limit, 24)

        let orderedIDs: [String]
        if let cached = pixivAuthorIllustIDCache[trimmedUserID] {
            orderedIDs = cached
        } else {
            let profile = try await PixivService.shared.userAllIllusts(userId: trimmedUserID)
            // 漫画由 MangaDetailSheet 的独立路由处理，不能在当前壁纸详情面板内原地切换。
            let artworkIDs = Array((profile.illusts ?? [:]).keys)
            orderedIDs = Array(Set(artworkIDs)).sorted {
                (Int64($0) ?? 0) > (Int64($1) ?? 0)
            }
            pixivAuthorIllustIDCache[trimmedUserID] = orderedIDs
        }

        let startIndex = (page - 1) * pageLimit
        guard startIndex < orderedIDs.count else {
            return AuthorPageResult(items: [], hasMore: false)
        }

        let endIndex = min(startIndex + pageLimit, orderedIDs.count)
        let pageIDs = Array(orderedIDs[startIndex..<endIndex])
        // hasMore 按 ID 切片判断，不依赖转换后数量（部分 ID 可能解析失败）
        let hasMore = endIndex < orderedIDs.count

        let works = try await PixivService.shared.userIllusts(userId: trimmedUserID, illustIDs: pageIDs)
        let worksByID = Dictionary(uniqueKeysWithValues: works.map { ($0.id, $0) })
        let items = pageIDs.compactMap { worksByID[$0]?.toWallpaper() }
        return AuthorPageResult(items: items, hasMore: hasMore)
    }

    // MARK: - 加载更多（支持 Task Cancellation + 预加载）
    func loadMore() async {
        guard !isLoading, hasMorePages else { return }
        isLoading = true

        loadMoreTask = Task {
            defer {
                isLoading = false
                loadMoreTask = nil
            }

            do {
                try Task.checkCancellation()

                let nextPage = currentPage + 1
                let results: WallpaperSearchResponse

                // 检查是否有预加载的数据
                if let cached = preloadedResponse,
                   cached.meta.currentPage == nextPage,
                   !cached.data.isEmpty {
                    results = cached
                    // 清空预加载数据
                    preloadedResponse = nil
                } else {
                    // 正常加载
                    results = try await fetchWallpapers(query: searchQuery, page: nextPage)
                }

                try Task.checkCancellation()

                currentRandomSeed = sortingOption == .random ? (results.meta.seed ?? currentRandomSeed) : nil
                wallpaperLibrary.upsertBatch(results.data)

                var existingIDs = Set(wallpapers.map(\.id))
                let appended = results.data.filter { existingIDs.insert($0.id).inserted }

                // ⚡ 批量追加，减少中间 @Published 通知次数
                // 如果追加数量较大，分批追加以避免单次 AttributeGraph 更新过重
                if appended.count > 40 {
                    let batchSize = 20
                    for i in stride(from: 0, to: appended.count, by: batchSize) {
                        let batch = Array(appended[i..<min(i + batchSize, appended.count)])
                        wallpapers.append(contentsOf: batch)
                        // 让出主线程，允许 SwiftUI 在批次间处理事件
                        await Task.yield()
                    }
                } else {
                    wallpapers.append(contentsOf: appended)
                }

                // 注意：正常 loadMore 不做顶部裁剪。
                // 列表元数据本身不大；真正的 10GB+/70GB 来自全高 NSCollectionView
                // 把所有 cell 当可见。顶部裁剪会在底部滚动时把 contentSize 从上方抽走，
                // 造成滚动位置跳动。内存压力路径会主动裁列表。

                currentPage = nextPage
                hasMorePages = currentPage < results.meta.lastPage

                // 预加载新加载的图片
                preloadImages(for: Array(appended.prefix(2)))

                // 预加载下一页数据
                if hasMorePages {
                    triggerPreloadNextPage()
                }
            } catch is CancellationError {
                return
            } catch let error as URLError where error.code == .cancelled {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }

        await loadMoreTask?.value
    }

    // MARK: - 预加载下一页
    private func triggerPreloadNextPage() {
        preloadTask?.cancel()

        let nextPageToPreload = currentPage + 1
        let currentQuery = searchQuery

        preloadTask = Task(priority: .low) {
            // 延迟一下再开始预加载，避免影响当前页的图片加载
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5秒

            guard !Task.isCancelled else { return }

            do {
                let results = try await fetchWallpapers(query: currentQuery, page: nextPageToPreload)

                guard !Task.isCancelled else { return }

                // 存储完整响应，避免丢失不同数据源自己的 perPage / lastPage 判断。
                preloadedResponse = results
            } catch {
                // 预加载失败静默忽略
            }
        }
    }

    // MARK: - 内存压力处理

    /// 系统内存压力时：只取消网络/预取并清图片缓存面，**不裁剪 wallpapers 数据**。
    /// 探索列表按虚拟滚动处理：数据保留，滚回去必须还能显示；
    /// 真正占内存的是可见视图与图片缓存，不是元数据数组本身。
    private func handleMemoryPressure() {
        print("[WallpaperViewModel] 内存压力，取消网络请求（保留列表数据）: wallpapers=\(wallpapers.count)")
        searchTask?.cancel()
        loadMoreTask?.cancel()
        debounceTask?.cancel()
        preloadTask?.cancel()
        preloadedResponse = nil
        ForegroundPrefetchManager.shared.stop(namespace: "wallpaper-view-model")
    }

    // MARK: - 取消所有任务
    func cancelAllTasks() {
        searchTask?.cancel()
        loadMoreTask?.cancel()
    }

    /// 释放前台浏览态内存：取消任务并使本地库索引失效，持久化库数据保持不变。
    func releaseForegroundMemory() {
        searchTask?.cancel()
        loadMoreTask?.cancel()
        debounceTask?.cancel()
        preloadTask?.cancel()
        ForegroundPrefetchManager.shared.stop(namespace: "wallpaper-view-model")

        searchTask = nil
        loadMoreTask = nil
        debounceTask = nil
        preloadTask = nil

        wallpapers.removeAll()
        featuredWallpapers.removeAll()
        topWallpapers.removeAll()
        latestWallpapers.removeAll()
        availableTags.removeAll()
        rebuildLocalWallpaperCacheTask?.cancel()
        rebuildLocalWallpaperCacheTask = nil
        localWallpaperCacheRebuildID = nil
        cachedAllLocalWallpapers.removeAll()
        localWallpaperCacheNeedsRestore = true
        errorMessage = nil
        isLoading = false
        hasMorePages = true
        currentPage = 1
        currentRandomSeed = nil
        preloadedResponse = nil
    }

    // MARK: - 图片预加载
    func preloadImages(for wallpapers: [Wallpaper]) {
        let urls = wallpapers.compactMap(\.gridPreviewURL)
        let targetSize = CGSize(width: 512, height: 512)
        ForegroundPrefetchManager.shared.start(
            urls: urls,
            options: [
                .processor(DownsamplingImageProcessor(size: targetSize)),
                .scaleFactor(NSScreen.main?.backingScaleFactor ?? 2),
            ],
            namespace: "wallpaper-view-model"
        )
    }

    private func fetchWallpapers(query: String, page: Int) async throws -> WallpaperSearchResponse {
        let parameters = WallhavenAPI.SearchParameters(
            query: query,
            page: page,
            categories: normalizedCategoryMask(),
            purity: normalizedPurityMask(),
            sorting: sortingOption.rawValue,
            order: orderDescending ? "desc" : "asc",
            topRange: sortingOption == .toplist ? topRange.rawValue : nil,
            atleast: atleastResolution,
            resolutions: normalizedResolutions(),
            ratios: normalizedRatios(),
            colors: normalizedColors(),
            seed: sortingOption == .random ? currentRandomSeed : nil
        )

        return try await fetchWallpapers(parameters: parameters)
    }

    /// Wallhaven 请求最大重试次数（⚠️ VM 层不再重试，交给 NetworkService 统一重试）
    private let maxWallhavenRetries = 0

    private func fetchWallpapers(parameters: WallhavenAPI.SearchParameters) async throws -> WallpaperSearchResponse {
        let sourceManager = WallpaperSourceManager.shared

        // 根据当前活跃源决定从哪个数据源获取
        // ⚠️ 注意：运行时不再自动切换数据源，切换只在应用启动时的健康检查中决定
        switch sourceManager.activeSource {
        case .wallhaven:
            return try await fetchFromWallhaven(parameters: parameters)
        case .fourKWallpapers:
            return try await fetchFromFallbackSource(.fourKWallpapers, parameters: parameters)
        case .konachan:
            return try await fetchFromKonachan(parameters: parameters)
        case .pixiv:
            return try await fetchFromPixiv(parameters: parameters)
        }
    }

    private func fetchFromWallhaven(parameters: WallhavenAPI.SearchParameters) async throws -> WallpaperSearchResponse {
        guard let url = WallhavenAPI.url(for: .search(parameters)) else {
            throw NetworkError.invalidResponse
        }

        // 单次请求 + 10s 超时保护，重试由 NetworkService 内部处理
        do {
            let result = try await withWallhavenTimeout(seconds: 10) {
                try await self.networkService.fetch(
                    WallpaperSearchResponse.self,
                    from: url,
                    headers: WallhavenAPI.authenticationHeaders(apiKey: self.normalizedAPIKey)
                )
            }
            return result
        } catch {
            throw error
        }
    }

    /// 从指定的回退源获取数据
    private func fetchFromFallbackSource(_ source: WallpaperSourceManager.SourceType, parameters: WallhavenAPI.SearchParameters) async throws -> WallpaperSearchResponse {
        switch source {
        case .fourKWallpapers:
            do {
                // 4K 分类映射：优先使用用户在探索页选择的 4K 分类，否则尝试从 WallHaven 分类推断
                let categorySlug: String?
                if let selected4K = selected4KCategorySlug {
                    categorySlug = selected4K
                } else if !parameters.categories.isEmpty && parameters.categories != "111" {
                    // 从 WallHaven 分类掩码推断
                    // "100" = general, "010" = anime, "001" = people
                    if parameters.categories == "010" {
                        categorySlug = "anime"
                    } else if parameters.categories == "001" {
                        categorySlug = "people"
                    } else {
                        categorySlug = nil
                    }
                } else {
                    categorySlug = nil
                }

                // 决定使用 Popular 还是 Latest URL
                let usePopular: Bool
                switch selected4KSorting {
                case .popular:
                    usePopular = true
                case .latest:
                    usePopular = false
                }

                return try await FourKWallpapersService.shared.search(
                    query: parameters.query,
                    page: parameters.page,
                    perPage: parameters.perPage,
                    category: categorySlug,
                    purity: "sfw",
                    usePopular: usePopular
                )
            } catch {
                throw error
            }

        case .wallhaven:
            // 不应该走到这里，但以防万一
            fatalError("fetchFromFallbackSource called with wallhaven source")

        case .konachan:
            // Konachan 不作为回退源的一部分
            throw NetworkError.invalidResponse

        case .pixiv:
            // Pixiv 不作为回退源的一部分
            throw NetworkError.invalidResponse
        }
    }

    /// 从 Konachan 源获取数据
    private func fetchFromKonachan(parameters: WallhavenAPI.SearchParameters) async throws -> WallpaperSearchResponse {
        // 映射 purity: Wallhaven 位掩码 → KonachanPuritySelection
        var puritySelection: KonachanPuritySelection = []
        if parameters.purity.first == "1" { puritySelection.insert(.safe) }
        if parameters.purity.count > 1 && parameters.purity[parameters.purity.index(parameters.purity.startIndex, offsetBy: 1)] == "1" { puritySelection.insert(.questionable) }
        if parameters.purity.count > 2 && parameters.purity[parameters.purity.index(parameters.purity.startIndex, offsetBy: 2)] == "1" { puritySelection.insert(.explicit) }

        if puritySelection.isEmpty {
            puritySelection = .safeOnly
        }

        return try await KonachanService.shared.search(
            query: parameters.query,
            page: parameters.page,
            perPage: parameters.perPage,
            purity: puritySelection,
            sorting: selectedKonachanSorting
        )
    }

    /// 从 Pixiv 源获取数据
    private func fetchFromPixiv(parameters: WallhavenAPI.SearchParameters) async throws -> WallpaperSearchResponse {
        print("[WallpaperVM] fetchFromPixiv called, query='\(parameters.query)', page=\(parameters.page), puritySFW=\(puritySFW), puritySketchy=\(puritySketchy), purityNSFW=\(purityNSFW)")
        
        // 每次请求前检查登录状态（从 WKWebView cookie 恢复到 HTTPCookieStorage）
        await PixivAuthService.shared.checkLoginState()
        
        // 将 App 的 3 级纯度筛选映射为 Pixiv API 参数
        // Pixiv API 只有 2 种模式：safe / r18 / all
        // Sketchy 需要通过客户端过滤实现
        let pixivMode: String = {
            if puritySFW && !puritySketchy && !purityNSFW {
                // 仅 SFW
                return "safe"
            } else if purityNSFW && !puritySFW && !puritySketchy {
                // 仅 NSFW
                return "r18"
            } else {
                // 其他组合（SFW+Sketchy, SFW+NSFW, Sketchy+NSFW, 全部）
                return "all"
            }
        }()

        // Pixiv Web 搜索 ai_type 仅接受 1（屏蔽 AI）；其余值（包括 0/2）均视为不过滤
        let aiTypeParam: Int? = pixivHideAI ? 1 : nil

        // 清空旧的相关标签
        pixivRelatedTags = []

        // 如果有搜索词，使用搜索 API
        if !parameters.query.isEmpty {
            let (response, relatedTags) = try await PixivService.shared.search(
                word: parameters.query,
                page: parameters.page,
                sort: selectedPixivSearchSort.apiValue,
                mode: pixivMode,
                workType: selectedPixivWorkType,
                aiType: aiTypeParam
            )
            // 存储相关标签供 UI 显示
            pixivRelatedTags = relatedTags
            
            // 客户端过滤：根据纯度筛选结果
            return filterPixivResponseByPurity(response)
        }

        // 排行榜：根据纯度选择对应的 R18/非R18 模式
        let rankingMode: String
        if purityNSFW && !puritySFW && !puritySketchy {
            // 仅 NSFW：使用 R18 排行榜
            switch selectedPixivRankingMode {
            case .daily: rankingMode = "daily_r18"
            case .weekly: rankingMode = "weekly_r18"
            case .monthly: rankingMode = "monthly_r18"
            case .rookie: rankingMode = "rookie_r18"
            case .original: rankingMode = "original_r18"
            case .male: rankingMode = "male_r18"
            case .female: rankingMode = "female_r18"
            }
        } else {
            // 其他组合：使用普通排行榜
            rankingMode = selectedPixivRankingMode.rawValue
        }

        // 作品类型映射为 content 参数（排行榜 API）
        //   - .all   → 不传 content（API 默认返回 illust+manga 混合，无 ugoira）
        //   - .illust → content=illust
        //   - .manga  → content=manga
        //   - .ugoira → content=ugoira（独立 ugoira 排行榜）
        let contentParam: String?
        switch selectedPixivWorkType {
        case .all: contentParam = nil
        case .illust: contentParam = "illust"
        case .manga: contentParam = "manga"
        case .ugoira: contentParam = "ugoira"
        }

        let response = try await PixivService.shared.ranking(
            mode: rankingMode,
            page: parameters.page,
            date: nil,
            content: contentParam
        )

        // 客户端过滤：根据纯度筛选结果
        return filterPixivResponseByPurity(response)
    }
    
    /// 根据纯度设置过滤 Pixiv 响应
    private func filterPixivResponseByPurity(_ response: WallpaperSearchResponse) -> WallpaperSearchResponse {
        let filtered = response.data.filter { wallpaper in
            switch wallpaper.purity {
            case "sfw":
                return puritySFW
            case "sketchy":
                return puritySketchy
            case "nsfw":
                return purityNSFW
            default:
                return true
            }
        }
        
        return WallpaperSearchResponse(
            meta: response.meta,
            data: filtered
        )
    }

    /// 给 WallHaven 请求加上短超时保护，超时后立即取消并抛错以便触发降级
    private func withWallhavenTimeout<T: Sendable>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw URLError(.timedOut)
            }

            guard let result = try await group.next() else {
                throw URLError(.timedOut)
            }
            group.cancelAll()
            return result
        }
    }

    /// 当前数据源是否支持 NSFW 筛选
    var currentSourceSupportsNSFW: Bool {
        // Pixiv 需要登录后才能使用 NSFW 筛选
        if sourceManager.activeSource == .pixiv {
            return PixivAuthService.shared.isLoggedIn
        }
        return sourceManager.currentSourceSupportsNSFW
    }

    /// 只有 Wallhaven 的 NSFW 开关依赖 Wallhaven API Key。
    var currentSourceRequiresAPIKeyForNSFW: Bool {
        sourceManager.activeSource == .wallhaven
    }

    /// 当前数据源是否支持 WallHaven 风格排序
    var currentSourceSupportsWallhavenSorting: Bool {
        sourceManager.currentSourceSupportsWallhavenSorting
    }

    /// 当前数据源是否支持比例筛选
    var currentSourceSupportsRatioFilter: Bool {
        sourceManager.currentSourceSupportsRatioFilter
    }

    /// 当前数据源是否支持颜色筛选
    var currentSourceSupportsColorFilter: Bool {
        sourceManager.currentSourceSupportsColorFilter
    }

    /// 当前数据源是否使用 WallHaven 风格分类（general/anime/people）
    var currentSourceSupportsWallhavenCategories: Bool {
        sourceManager.currentSourceSupportsWallhavenCategories
    }

    /// 当前数据源是否支持分类筛选
    var currentSourceSupportsCategories: Bool {
        sourceManager.currentSourceSupportsCategories
    }

    private func normalizedCategoryMask() -> String {
        let mask = "\(categoryGeneral ? 1 : 0)\(categoryAnime ? 1 : 0)\(categoryPeople ? 1 : 0)"
        return mask == "000" ? "111" : mask
    }

    private func normalizedPurityMask() -> String {
        // 位掩码格式: 1=包含, 0=排除
        // 第一位=SFW, 第二位=Sketchy, 第三位=NSFW
        let sfw = puritySFW ? 1 : 0
        let sketchy = puritySketchy ? 1 : 0
        let canIncludeNSFW = !currentSourceRequiresAPIKeyForNSFW || apiKeyConfigured
        let nsfw = (canIncludeNSFW && purityNSFW) ? 1 : 0

        // 确保至少选择一个
        if sfw == 0 && sketchy == 0 && nsfw == 0 {
            return "100" // 默认只显示SFW
        }

        return "\(sfw)\(sketchy)\(nsfw)"
    }

    private func normalizedResolutions() -> [String] {
        selectedResolutions
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func normalizedRatios() -> [String] {
        selectedRatios
            .map { $0.replacingOccurrences(of: ":", with: "x") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func normalizedColors() -> [String] {
        selectedColors
            .map { $0.replacingOccurrences(of: "#", with: "") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }

    // MARK: - 下载壁纸
    /// - Parameter folderID: 下载入库时一并写入的库文件夹归属（作者批量下载用）。
    ///   为 nil 时不改动已有 folderID；新建记录则落在根目录。
    func downloadWallpaper(_ wallpaper: Wallpaper, folderID: String? = nil) async throws {
        try await PersistentDownloadQueueService.shared.enqueueWallpaperAndWait(
            wallpaper,
            folderID: folderID,
            using: self
        )
    }

    /// 只执行落盘逻辑；队列统一负责状态、取消、重试与并发槽位。
    func executeQueuedWallpaperDownload(
        _ wallpaper: Wallpaper,
        folderID: String?,
        taskID: String
    ) async throws {
        guard await downloadPathManager.ensureDirectoryStructure() else {
            throw DownloadError.permissionDenied
        }

        let imageData = try await downloadWallpaperData(wallpaper, taskID: taskID)
        try Task.checkCancellation()

        updateDownloadProgress(taskID: taskID, progress: 0.92)

        let fileURL = downloadPathManager.wallpaperFileURL(
            id: wallpaper.id,
            fileExtension: wallpaper.fileExtension
        )
        let directory = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        try await imageData.writeAsync(to: fileURL)
        try Task.checkCancellation()

        guard await fileURL.fileExistsAsync() else {
            throw DownloadError.writeFailed(
                NSError(
                    domain: "WaifuX",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "File not found after write"]
                )
            )
        }

        wallpaperLibrary.recordDownload(wallpaper, fileURL: fileURL, folderID: folderID)
    }

    /// 为「设为壁纸」准备一个持久化的本地文件。
    /// 直接设置网络壁纸属于明确的用户保存动作，不能只落到临时目录。
    func localWallpaperFileURLForApplication(_ wallpaper: Wallpaper) async throws -> URL {
        if let localURL = wallpaperLibrary.localFileURLIfAvailable(for: wallpaper) {
            return localURL
        }

        if wallpaper.id.hasPrefix("local_"),
           let localURL = wallpaper.fullImageURL,
           localURL.isFileURL,
           FileManager.default.fileExists(atPath: localURL.path) {
            wallpaperLibrary.recordDownload(wallpaper, fileURL: localURL)
            return localURL
        }

        try await downloadWallpaper(wallpaper)
        guard let localURL = wallpaperLibrary.localFileURLIfAvailable(for: wallpaper) else {
            throw DownloadError.writeFailed(
                NSError(
                    domain: "WaifuX",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Wallpaper was downloaded but not added to the library"]
                )
            )
        }
        return localURL
    }

    func downloadWallpaperData(_ wallpaper: Wallpaper, taskID: String? = nil) async throws -> Data {
        var downloadURL: URL?

        // Pixiv 源壁纸：先解析原图 URL，再用 PixivService.downloadImage 下载
        if wallpaper.source == "pixiv" {
            // 从 wallpaper.id 提取 illust ID: "pixiv_12345" → "12345"
            let rawID = wallpaper.id.replacingOccurrences(of: "pixiv_", with: "")
            do {
                let detail = try await PixivService.shared.illustDetail(id: rawID)
                return try await PixivService.shared.downloadImage(url: detail.urls.original)
            } catch {
                AppLogger.warn(.wallpaper, "Pixiv 原图解析失败，使用预览图降级", metadata: ["id": rawID, "error": "\(error)"])
                return try await PixivService.shared.downloadImage(url: wallpaper.path)
            }
        }

        // 4K 源壁纸：优先使用 thumbs.original（真正的原图 URL）
        // 因为 fullImageURL（path）现在存的是缩略图 URL，用于展示而非下载
        if wallpaper.source == "4kwallpapers",
           !wallpaper.thumbs.original.isEmpty,
           wallpaper.thumbs.original.contains("/images/wallpapers/"),
           let originalURL = URL(string: wallpaper.thumbs.original) {
            downloadURL = originalURL
        } else {
            downloadURL = wallpaper.fullImageURL ?? wallpaper.thumbURL
        }

        // 4K 源壁纸兜底：如果原图 URL 不是有效图片链接，从详情页解析原图
        if wallpaper.source == "4kwallpapers",
           let currentURL = downloadURL,
           !currentURL.isFileURL,
           !currentURL.pathExtension.isEmpty,
           !["jpg", "jpeg", "png", "webp", "gif"].contains(currentURL.pathExtension.lowercased()) {
            let originalURL = await FourKWallpapersService.shared.fetchOriginalImageURL(for: wallpaper)
            if let originalURLString = originalURL, let url = URL(string: originalURLString) {
                downloadURL = url
            } else {
                downloadURL = wallpaper.thumbURL  // 最终兜底用缩略图
            }
        }

        guard let downloadURL else {
            throw NetworkError.invalidResponse
        }

        // 本地文件：直接读取数据
        if downloadURL.isFileURL {
            guard FileManager.default.fileExists(atPath: downloadURL.path) else {
                throw DownloadError.fileNotFound
            }
            return try Data(contentsOf: downloadURL)
        }

        let headers = wallpaper.source == "konachan"
            ? KonachanRequestConfiguration.imageHeaders(for: downloadURL)
            : [:]

        return try await networkService.fetchImage(from: downloadURL, headers: headers) { progress in
            guard let taskID else { return }
            Task { @MainActor in
                DownloadTaskService.shared.updateProgress(id: taskID, progress: min(progress * 0.9, 0.9))
            }
        }
    }

    private func updateDownloadProgress(taskID: String, progress: Double) {
        downloadTaskService.updateProgress(id: taskID, progress: progress)
    }

    func retryDownload(task: DownloadTask) async throws {
        guard task.wallpaper != nil else {
            throw NetworkError.invalidResponse
        }
        try await PersistentDownloadQueueService.shared.retryAndWait(task)
    }

    // MARK: - 设置壁纸
    /// - Note: macOS 的锁屏壁纸即桌面壁纸，没有独立的锁屏壁纸 API。
    ///   `.lockScreen` 和 `.both` 最终都等同于设置桌面壁纸，避免重复操作。
    func setWallpaper(from imageURL: URL, option: WallpaperOption) async throws {
        VideoWallpaperManager.shared.cancelPendingExternalVideoTransition(
            reason: "WallpaperViewModel.setWallpaper"
        )
        let screens = NSScreen.screens
        let transitionToken = WallpaperCrossTypeTransitionCoordinator.shared
            .beginRequest(on: screens)
        let imageURLByScreen = try await preparedStaticImageURLs(
            from: imageURL,
            for: screens
        )
        guard WallpaperCrossTypeTransitionCoordinator.shared.isCurrent(
            transitionToken
        ) else {
            return
        }
        WallpaperEngineXBridge.shared.prepareForNonExternalWallpaperSwitch(
            on: screens,
            reason: "applyStaticWallpaper"
        )

        let preservesDynamicWallpaperUntilReady = VideoWallpaperManager.shared
            .hasNativeVideoWallpaper(on: screens)
            || screens.contains { WallpaperEngineXBridge.shared.isManaging(screen: $0) }
        if !preservesDynamicWallpaperUntilReady {
            WallpaperEngineXBridge.shared.ensureStoppedForNonCLIWallpaper()
            VideoWallpaperManager.shared.stopNativeVideoWallpaperOnly()
        }

        // macOS 26+：仅当用户未启用动态锁屏时才清空锁屏扩展状态。
        // 使用持久化设置 isLockScreenEnabled 而非 isLockScreenMirroringActive。
        let shouldClearExtension: Bool = {
            if #available(macOS 26.0, *) {
                return !VideoWallpaperManager.shared.isLockScreenEnabled
            }
            return true
        }()
        if #available(macOS 26.0, *), shouldClearExtension {
            LockScreenWallpaperService.shared.clearMirroringSourceCache()
            VideoWallpaperManager.shared.clearExtensionState()
        }

        // macOS 26+：动态锁屏启用时，不走系统静态壁纸写入（setDesktopImageURL 会
        // 覆盖用户在系统设置中手动选择的 WaifuX 锁屏实例）。锁屏侧把静态图源直接
        // 部署给 WaifuX 显示器实例；桌面侧改走独立静态图 overlay 窗口显示，
        // 保证静态壁纸在每块屏上都真实可见。
        if #available(macOS 26.0, *), VideoWallpaperManager.shared.isLockScreenEnabled {
            for screen in screens {
                guard let displayID = (screen.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber")
                ] as? NSNumber)?.uint32Value else {
                    continue
                }
                let resolvedImageURL = imageURLByScreen[screen.wallpaperScreenIdentifier] ?? imageURL
                try await LockScreenWallpaperService.shared.cacheStaticImageSource(
                    imageURL: resolvedImageURL,
                    displayIDs: [displayID]
                )
                guard WallpaperCrossTypeTransitionCoordinator.shared.isCurrent(
                    transitionToken
                ) else {
                    return
                }
            }
            // 桌面：不写系统壁纸，用独立 overlay 显示（与系统壁纸同步关闭路径一致）
            for screen in screens {
                let resolvedImageURL = imageURLByScreen[screen.wallpaperScreenIdentifier] ?? imageURL
                await StaticImageWallpaperOverlayManager.shared.showPrepared(
                    imageURL: resolvedImageURL,
                    for: screen
                )
                guard WallpaperCrossTypeTransitionCoordinator.shared.isCurrent(
                    transitionToken
                ) else {
                    return
                }
            }
            StaticWallpaperGrainManager.shared.updateOverlay()
            print("[WallpaperViewModel] 🔒 动态锁屏已启用，静态图已同步到 WaifuX 锁屏实例 + 桌面 overlay")
            await finishStaticWallpaperTransitionIfNeeded(
                screens: screens,
                preservesDynamicWallpaperUntilReady: preservesDynamicWallpaperUntilReady,
                requestToken: transitionToken
            )
            return
        }

        let workspace = NSWorkspace.shared

        // 系统壁纸同步关闭时，冻结 setDesktopImageURL 链路，改走独立静态图 overlay 显示。
        // mp4/场景/web 动态壁纸不受影响（它们通过 overlay 窗口或 CLI 进程覆盖桌面）。
        // 颗粒蒙层独立于系统壁纸，仍正常更新。
        if !VideoWallpaperManager.shared.isSystemWallpaperSyncEnabled {
            print("[WallpaperViewModel] 🧊 系统壁纸同步已关闭，走独立静态图 overlay 显示")
            for screen in screens {
                let resolvedImageURL = imageURLByScreen[screen.wallpaperScreenIdentifier] ?? imageURL
                await StaticImageWallpaperOverlayManager.shared.showPrepared(
                    imageURL: resolvedImageURL,
                    for: screen
                )
                guard WallpaperCrossTypeTransitionCoordinator.shared.isCurrent(
                    transitionToken
                ) else {
                    return
                }
            }
            StaticWallpaperGrainManager.shared.updateOverlay()
            await finishStaticWallpaperTransitionIfNeeded(
                screens: screens,
                preservesDynamicWallpaperUntilReady: preservesDynamicWallpaperUntilReady,
                requestToken: transitionToken
            )
            return
        }

        let fillOptions: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSNumber(value: NSImageScaling.scaleProportionallyUpOrDown.rawValue),
            .allowClipping: true
        ]
        for screen in screens {
            let resolvedImageURL = imageURLByScreen[screen.wallpaperScreenIdentifier] ?? imageURL
            let systemWallpaperURL = await StaticImageWallpaperOverlayManager.shared.preparedSystemWallpaperURL(
                for: resolvedImageURL
            )
            guard WallpaperCrossTypeTransitionCoordinator.shared.isCurrent(
                transitionToken
            ) else {
                return
            }
            try workspace.setDesktopImageURLForAllSpaces(systemWallpaperURL, for: screen, options: fillOptions)
            DesktopWallpaperSyncManager.shared.registerWallpaperSet(systemWallpaperURL, for: screen)
        }

        // 互斥：走系统壁纸时关闭并清除静态图 overlay 持久化状态
        StaticImageWallpaperOverlayManager.shared.clearState()

        // 更新静态壁纸颗粒蒙层（独立窗口，不受壁纸切换影响）
        StaticWallpaperGrainManager.shared.updateOverlay()
        await finishStaticWallpaperTransitionIfNeeded(
            screens: screens,
            preservesDynamicWallpaperUntilReady: preservesDynamicWallpaperUntilReady,
            requestToken: transitionToken
        )
    }

    // MARK: - 设置壁纸到指定屏幕
    /// - Note: macOS 的锁屏壁纸即桌面壁纸，没有独立的锁屏壁纸 API。
    ///   `.lockScreen` 和 `.both` 最终都等同于设置桌面壁纸。
    func setWallpaper(from imageURL: URL, option: WallpaperOption, for targetScreen: NSScreen?) async throws {
        VideoWallpaperManager.shared.cancelPendingExternalVideoTransition(
            reason: "WallpaperViewModel.setWallpaperForScreen"
        )
        let workspace = NSWorkspace.shared

        // 如果指定了特定屏幕，只设置到该屏幕
        if let targetScreen = targetScreen {
            let transitionToken = WallpaperCrossTypeTransitionCoordinator.shared
                .beginRequest(on: [targetScreen])
            let resolvedImageURL = try await preparedStaticImageURL(
                from: imageURL,
                for: targetScreen
            )
            guard WallpaperCrossTypeTransitionCoordinator.shared.isCurrent(
                transitionToken
            ) else {
                return
            }
            WallpaperEngineXBridge.shared.prepareForNonExternalWallpaperSwitch(
                on: [targetScreen],
                reason: "applyStaticWallpaperForScreen"
            )

            let preservesDynamicWallpaperUntilReady = VideoWallpaperManager.shared
                .hasNativeVideoWallpaper(on: [targetScreen])
                || WallpaperEngineXBridge.shared.isManaging(screen: targetScreen)

            // 切到静态图前如果目标屏幕被 CLI 管理则停 CLI 引擎
            if !preservesDynamicWallpaperUntilReady {
                if WallpaperEngineXBridge.shared.isManaging(screen: targetScreen) {
                    WallpaperEngineXBridge.shared.ensureStoppedForNonCLIWallpaper(for: targetScreen)
                }
                // 只停目标屏幕的动态壁纸，避免影响其他屏幕
                VideoWallpaperManager.shared.stopNativeVideoWallpaperOnly(for: targetScreen)
            }
            // macOS 26+：仅当用户未启用动态锁屏时才清空锁屏镜像帧源缓存。
            // 使用持久化设置 isLockScreenEnabled 而非 isLockScreenMirroringActive。
            let shouldClearExtension: Bool = {
                if #available(macOS 26.0, *) {
                    return !VideoWallpaperManager.shared.isLockScreenEnabled
                }
                return true
            }()
            if #available(macOS 26.0, *), shouldClearExtension {
                LockScreenWallpaperService.shared.clearMirroringSourceCache()
            }

            // macOS 26+：动态锁屏启用时，不走系统静态壁纸写入（会覆盖用户手动
            // 选择的锁屏实例）。锁屏侧部署给该显示器的 WaifuX 实例；桌面侧走
            // 独立静态图 overlay 显示，保证目标屏真实可见。
            if #available(macOS 26.0, *), VideoWallpaperManager.shared.isLockScreenEnabled {
                if let displayID = (targetScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value {
                    try await LockScreenWallpaperService.shared.cacheStaticImageSource(
                        imageURL: resolvedImageURL,
                        displayIDs: [displayID]
                    )
                    guard WallpaperCrossTypeTransitionCoordinator.shared.isCurrent(
                        transitionToken
                    ) else {
                        return
                    }
                    await StaticImageWallpaperOverlayManager.shared.showPrepared(
                        imageURL: resolvedImageURL,
                        for: targetScreen
                    )
                    guard WallpaperCrossTypeTransitionCoordinator.shared.isCurrent(
                        transitionToken
                    ) else {
                        return
                    }
                    StaticWallpaperGrainManager.shared.updateOverlay()
                    print("[WallpaperViewModel] 🔒 动态锁屏已启用，单屏静态图已同步到 WaifuX 实例 + 桌面 overlay")
                }
                await finishStaticWallpaperTransitionIfNeeded(
                    screens: [targetScreen],
                    preservesDynamicWallpaperUntilReady: preservesDynamicWallpaperUntilReady,
                    requestToken: transitionToken
                )
                return
            }

            // 系统壁纸同步关闭时，冻结 setDesktopImageURL 链路，改走独立静态图 overlay 显示。
            // mp4/场景/web 动态壁纸不受影响；颗粒蒙层独立于系统壁纸，仍正常更新。
            if !VideoWallpaperManager.shared.isSystemWallpaperSyncEnabled {
                print("[WallpaperViewModel] 🧊 系统壁纸同步已关闭，走单屏独立静态图 overlay 显示")
                await StaticImageWallpaperOverlayManager.shared.showPrepared(
                    imageURL: resolvedImageURL,
                    for: targetScreen
                )
                guard WallpaperCrossTypeTransitionCoordinator.shared.isCurrent(
                    transitionToken
                ) else {
                    return
                }
                StaticWallpaperGrainManager.shared.updateOverlay()
                await finishStaticWallpaperTransitionIfNeeded(
                    screens: [targetScreen],
                    preservesDynamicWallpaperUntilReady: preservesDynamicWallpaperUntilReady,
                    requestToken: transitionToken
                )
                return
            }

            let fillOptions: [NSWorkspace.DesktopImageOptionKey: Any] = [
                .imageScaling: NSNumber(value: NSImageScaling.scaleProportionallyUpOrDown.rawValue),
                .allowClipping: true
            ]
            let systemWallpaperURL = await StaticImageWallpaperOverlayManager.shared.preparedSystemWallpaperURL(
                for: resolvedImageURL
            )
            guard WallpaperCrossTypeTransitionCoordinator.shared.isCurrent(
                transitionToken
            ) else {
                return
            }
            try workspace.setDesktopImageURLForAllSpaces(systemWallpaperURL, for: targetScreen, options: fillOptions)
            DesktopWallpaperSyncManager.shared.registerWallpaperSet(systemWallpaperURL, for: targetScreen)

            // 互斥：走系统壁纸时关闭并清除静态图 overlay 持久化状态
            StaticImageWallpaperOverlayManager.shared.clearState()
            await finishStaticWallpaperTransitionIfNeeded(
                screens: [targetScreen],
                preservesDynamicWallpaperUntilReady: preservesDynamicWallpaperUntilReady,
                requestToken: transitionToken
            )
        } else {
            try await setWallpaper(from: imageURL, option: option)
        }
    }

    private func finishStaticWallpaperTransitionIfNeeded(
        screens: [NSScreen],
        preservesDynamicWallpaperUntilReady: Bool,
        requestToken: WallpaperCrossTypeTransitionCoordinator.RequestToken
    ) async {
        guard preservesDynamicWallpaperUntilReady else { return }
        guard WallpaperCrossTypeTransitionCoordinator.shared.isCurrent(
            requestToken
        ) else {
            return
        }
        let liveScreens = Self.uniqueLiveScreens(preferred: screens)
        guard !liveScreens.isEmpty else { return }
        // 独立静态 overlay 与视频窗处于同一 desktop level。overlay 准备完成时
        // 先把仍在播放的旧视频提回前方，避免新图片在黑场出现前闪一帧。
        VideoWallpaperManager.shared.keepNativeVideoPresentationFront(on: liveScreens)
        await WallpaperCrossTypeTransitionCoordinator.shared.commitPreparedContent(
            on: liveScreens,
            requestToken: requestToken
        ) {
            for screen in liveScreens {
                guard WallpaperCrossTypeTransitionCoordinator.shared.isCurrent(
                    requestToken
                ) else {
                    return
                }
                await WallpaperEngineXBridge.shared.ensureStoppedForNonCLIWallpaperForTransition(
                    for: screen
                )
                guard WallpaperCrossTypeTransitionCoordinator.shared.isCurrent(
                    requestToken
                ) else {
                    return
                }
                VideoWallpaperManager.shared.stopNativeVideoWallpaperOnly(for: screen)
            }
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

    /// 仅在设置打开时为竖图生成派生壁纸。结果按显示器像素尺寸独立映射，
    /// 同一原图在不同宽高比的显示器上不会相互覆盖。
    private func preparedStaticImageURLs(
        from sourceURL: URL,
        for screens: [NSScreen]
    ) async throws -> [String: URL] {
        guard UserDefaults.standard.bool(forKey: "portrait_blur_fill_enabled") else {
            return Dictionary(uniqueKeysWithValues: screens.map {
                ($0.wallpaperScreenIdentifier, sourceURL)
            })
        }

        let derivedDirectory = DownloadPathManager.shared.derivedWallpapersFolderURL
        var imageURLs: [String: URL] = [:]
        for screen in screens {
            let pixelSize = CGSize(
                width: max(1, (screen.frame.width * screen.backingScaleFactor).rounded()),
                height: max(1, (screen.frame.height * screen.backingScaleFactor).rounded())
            )
            imageURLs[screen.wallpaperScreenIdentifier] = try await PortraitBlurFillWallpaperService.shared
                .preparedWallpaperURL(
                    for: sourceURL,
                    targetPixelSize: pixelSize,
                    derivedWallpapersDirectory: derivedDirectory
                )
        }
        return imageURLs
    }

    private func preparedStaticImageURL(
        from sourceURL: URL,
        for screen: NSScreen
    ) async throws -> URL {
        let imageURLs = try await preparedStaticImageURLs(from: sourceURL, for: [screen])
        return imageURLs[screen.wallpaperScreenIdentifier] ?? sourceURL
    }

    // MARK: - 设为壁纸（通过 Wallpaper 对象）
    func setAsWallpaper(_ wallpaper: Wallpaper, targetScreen: NSScreen? = nil) async throws {
        let imageURL = try await localWallpaperFileURLForApplication(wallpaper)
        let screen = targetScreen ?? NSScreen.main
        guard let screen else {
            throw NSError(domain: "WaifuX", code: 2, userInfo: [NSLocalizedDescriptionKey: "No screen available"])
        }
        // 直通到统一的 setWallpaper，确保手动设置和自动更换完全共用同一条路径
        try await setWallpaper(from: imageURL, option: .desktop, for: screen)
    }

    // MARK: - 获取精选壁纸（用于轮播）- 日榜，仅横版
    func fetchFeaturedWallpapers() async throws -> [Wallpaper] {
        let sourceManager = WallpaperSourceManager.shared
        switch sourceManager.activeSource {
        case .fourKWallpapers:
            return try await FourKWallpapersService.shared.fetchFeatured(limit: 24)
        case .wallhaven:
            return try await featuredFromMainSource()
        case .konachan:
            return try await KonachanService.shared.fetchFeatured(limit: 24)
        case .pixiv:
            return try await PixivService.shared.fetchFeatured(limit: 24)
        }
    }

    private func featuredFromMainSource() async throws -> [Wallpaper] {
        let response = try await fetchWallpapers(
            parameters: WallhavenAPI.SearchParameters(
                page: 1,
                categories: "111",
                purity: "100",
                sorting: SortingOption.toplist.rawValue,
                order: "desc",
                topRange: TopRange.oneDay.rawValue,
                ratios: ["16x9", "16x10", "21x9", "32x9", "48x9"]
            )
        )
        return response.data
    }

    // MARK: - 获取 Top 列表
    func fetchTopWallpapers() async throws -> [Wallpaper] {
        let sourceManager = WallpaperSourceManager.shared
        switch sourceManager.activeSource {
        case .fourKWallpapers:
            return try await FourKWallpapersService.shared.fetchTop(limit: 8)
        case .wallhaven:
            return try await topFromMainSource()
        case .konachan:
            return try await KonachanService.shared.fetchTop(limit: 8)
        case .pixiv:
            return try await PixivService.shared.fetchTop(limit: 8)
        }
    }

    private func topFromMainSource() async throws -> [Wallpaper] {
        let response = try await fetchWallpapers(
            parameters: WallhavenAPI.SearchParameters(
                page: 1,
                categories: "111",
                purity: "100",
                sorting: SortingOption.toplist.rawValue,
                order: "desc",
                topRange: TopRange.oneMonth.rawValue
            )
        )
        return Array(response.data.prefix(8))
    }

    // MARK: - 获取 Latest 列表
    func fetchLatestWallpapers() async throws -> [Wallpaper] {
        let sourceManager = WallpaperSourceManager.shared
        switch sourceManager.activeSource {
        case .fourKWallpapers:
            return try await FourKWallpapersService.shared.fetchLatest(limit: 8)
        case .wallhaven:
            return try await latestFromMainSource()
        case .konachan:
            return try await KonachanService.shared.fetchLatest(limit: 8)
        case .pixiv:
            return try await PixivService.shared.fetchLatest(limit: 8)
        }
    }

    private func latestFromMainSource() async throws -> [Wallpaper] {
        let response = try await fetchWallpapers(
            parameters: WallhavenAPI.SearchParameters(
                page: 1,
                categories: "111",
                purity: "100",
                sorting: SortingOption.dateAdded.rawValue,
                order: "desc"
            )
        )
        return Array(response.data.prefix(8))
    }

    // MARK: - 初始化加载（支持取消和延迟加载）
    func initialLoad() async {
        // 兜底：确保探索排序在首次 search 前已从 UserDefaults 恢复
        restoreExploreSortPreferences()

        // 1. 立即加载收藏（本地数据，很快）
        loadFavorites()

        // 2. 优先加载关键数据（首屏需要的数据）
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await self.search()
            }
            group.addTask {
                await self.fetchFeaturedAndUpdate()
            }
        }

        // 3. 延迟加载非关键数据（2秒后）
        Task(priority: .low) {
            try? await Task.sleep(nanoseconds: 2 * 1_000_000_000)
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await self.fetchTopAndUpdate()
                }
                group.addTask {
                    await self.fetchLatestAndUpdate()
                }
            }
        }
    }

    // MARK: - 下拉刷新（支持取消）
    func refresh() async {
        // 取消所有现有任务
        cancelAllTasks()

        // 使用 TaskGroup 并行刷新
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await self.search()
            }
            group.addTask {
                await self.fetchFeaturedAndUpdate()
            }
            group.addTask {
                await self.fetchTopAndUpdate()
            }
            group.addTask {
                await self.fetchLatestAndUpdate()
            }
        }
    }

    private func fetchFeaturedAndUpdate() async {
        do {
            let results = try await fetchFeaturedWallpapers()
            // ⚠️ 分批更新，避免一次性大量更新阻塞主线程
            let batchSize = 8
            let total = results.count
            for i in stride(from: 0, to: total, by: batchSize) {
                let end = min(i + batchSize, total)
                let batch = Array(results[i..<end])

                if i == 0 {
                    featuredWallpapers = batch
                } else {
                    featuredWallpapers.append(contentsOf: batch)
                }

                if end < total {
                    await Task.yield()
                }
            }
        } catch {
            // 静默忽略
        }
    }

    private func fetchTopAndUpdate() async {
        do {
            topWallpapers = try await fetchTopWallpapers()
        } catch {
            // 静默忽略
        }
    }

    private func fetchLatestAndUpdate() async {
        do {
            latestWallpapers = try await fetchLatestWallpapers()
        } catch {
            // 静默忽略
        }
    }
}

// MARK: - 排序选项
enum SortingOption: String {
    case dateAdded = "date_added"
    case relevance = "relevance"
    case random = "random"
    case views = "views"
    case favorites = "favorites"
    case toplist = "toplist"
}

enum TopRange: String {
    case oneDay = "1d"
    case threeDays = "3d"
    case oneWeek = "1w"
    case oneMonth = "1M"
    case threeMonths = "3M"
    case sixMonths = "6M"
    case oneYear = "1y"
}

// MARK: - 统一的本地壁纸表示

/// 统一的本地壁纸表示
/// 用于混合显示下载记录和用户手动复制到目录的本地文件
struct UnifiedLocalWallpaper: Identifiable {
    let id: String
    let wallpaper: Wallpaper
    let localItem: LocalWallpaperItem?
    let downloadRecord: WallpaperDownloadRecord?
    let fileURL: URL
    let isLocalFile: Bool

    /// 标题
    var title: String {
        localItem?.title ?? "Wallpaper"
    }

    /// 分辨率
    var resolution: String {
        wallpaper.resolution
    }

    /// 文件大小标签
    var fileSizeLabel: String {
        if let localItem = localItem, let size = localItem.fileSize {
            let mb = Double(size) / 1024 / 1024
            return String(format: "%.1f MB", mb)
        }
        return wallpaper.fileSizeLabel
    }

    /// 创建/下载时间
    var dateLabel: String? {
        if let record = downloadRecord {
            return formatDate(record.downloadedAt)
        }
        if let localItem = localItem, let createdAt = localItem.createdAt {
            return formatDate(parseISO8601(createdAt))
        }
        return nil
    }
}

// MARK: - 辅助函数

private func parseISO8601(_ string: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    return formatter.date(from: string)
}

private func formatDate(_ date: Date?) -> String? {
    guard let date = date else { return nil }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return formatter.localizedString(for: date, relativeTo: Date())
}

// MARK: - 系统分享（详情页：已下载的本地文件）

@MainActor
enum SystemShareSupport {
    /// 统一使用本地文件 URL 作为分享项。
    /// 若传入 `NSImage`，部分第三方分享扩展与 PlugInKit（pkd）组合在 macOS 上会出现 XPC 中断、面板长时间转圈；文件 URL 路径更稳定。
    static func itemsForLocalFile(at url: URL) -> [Any] {
        [url]
    }

    /// - Parameter anchorView: 与 `relativeRect` 同属该视图的坐标系；默认用 `anchorView.bounds`
    static func presentPicker(items: [Any], anchorView: NSView? = nil, relativeRect: NSRect? = nil) {
        guard !items.isEmpty else { return }
        NSApp.activate(ignoringOtherApps: true)
        // 延后到下一 runloop，确保窗口已成为 key、布局完成；可降低偶发的分享服务枚举失败。
        DispatchQueue.main.async {
            Self.presentPickerOnMainNow(items: items, anchorView: anchorView, relativeRect: relativeRect)
        }
    }

    private static func presentPickerOnMainNow(items: [Any], anchorView: NSView?, relativeRect: NSRect?) {
        let picker = NSSharingServicePicker(items: items)
        if let v = anchorView, v.window != nil {
            let rect = relativeRect ?? v.bounds
            guard rect.width > 0.5, rect.height > 0.5 else {
                presentPickerCenteredFallback(picker: picker, items: items)
                return
            }
            picker.show(relativeTo: rect, of: v, preferredEdge: .maxY)
            return
        }
        presentPickerCenteredFallback(picker: picker, items: items)
    }

    private static func presentPickerCenteredFallback(picker: NSSharingServicePicker, items: [Any]) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow,
              let contentView = window.contentView else {
            writeFallbackPasteboard(items: items)
            return
        }
        let rect = NSRect(
            x: contentView.bounds.midX - 80,
            y: contentView.bounds.midY - 12,
            width: 160,
            height: 24
        )
        picker.show(relativeTo: rect, of: contentView, preferredEdge: .minY)
    }

    private static func writeFallbackPasteboard(items: [Any]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        for item in items {
            if let url = item as? URL {
                _ = pb.writeObjects([url as NSURL])
            } else if let image = item as? NSImage {
                pb.writeObjects([image])
            }
        }
    }
}
