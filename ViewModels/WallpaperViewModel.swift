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
    
    // MARK: - 内存优化：限制最大数据量，防止无限滚动导致内存占满
    private let maxDataCount = 200  // 最多保留200条数据，超过时清理早期数据
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
    private var preloadedWallpapers: [Wallpaper] = []
    private var preloadedPage: Int = 0
    
    // MARK: - 防抖搜索
    private var debounceTask: Task<Void, Never>?
    private let debounceInterval: TimeInterval = 0.3 // 300ms 防抖
    private var currentRandomSeed: String?



    // 分类开关
    @Published var categoryGeneral = true
    @Published var categoryAnime = true
    @Published var categoryPeople = true

    // 纯度开关
    @Published var puritySFW = true
    @Published var puritySketchy = false
    @Published var purityNSFW = false

    // 排序选项
    @Published var sortingOption: SortingOption = .dateAdded
    @Published var orderDescending = true

    // TopRange (用于 toplist 排序)
    @Published var topRange: TopRange = .oneMonth

    // 附加筛选
    @Published var selectedResolutions: [String] = []
    @Published var selectedRatios: [String] = []
    @Published var selectedColors: [String] = []
    @Published var atleastResolution: String? = nil  // 最小分辨率，如 "3840x2160"
    @Published var selected4KCategorySlug: String? = nil  // 4K 源的分类 slug（如 "anime", "nature"）
    @Published var selected4KSorting: FourKSortingOption = .latest  // 4K 源的排序方式

    // MARK: - 本地收藏与下载记录
    private let wallpaperLibrary = WallpaperLibraryService.shared
    private let downloadTaskService = DownloadTaskService.shared
    private let downloadPathManager = DownloadPathManager.shared
    private let localScanner = LocalWallpaperScanner.shared
    private var cancellables = Set<AnyCancellable>()

    /// 收藏/下载库变更时递增；与 `cachedAllLocalWallpapers` 一起驱动依赖 `isFavorite` / 列表的视图刷新。
    @Published private(set) var libraryContentRevision: UInt = 0

    // MARK: - 调度器服务
    private let schedulerService = WallpaperSchedulerService.shared

    private let networkService = NetworkService.shared
    private let cacheService = CacheService.shared
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
        // 监听 Service 数据变化：重建缓存并递增 revision（@Published 会触发 ObservableObject 刷新）
        Publishers.Merge3(
            wallpaperLibrary.$favoriteRecords.map { _ in () },
            wallpaperLibrary.$downloadRecords.map { _ in () },
            localScanner.$scanRevision.map { _ in () }
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            self?.rebuildLocalWallpaperCache()
            self?.libraryContentRevision &+= 1
            // 不额外 `objectWillChange.send()`：`cachedAllLocalWallpapers` 与 `libraryContentRevision` 的 @Published 已会触发依赖视图更新
        }
        .store(in: &cancellables)
        
        // 初始重建一次缓存
        rebuildLocalWallpaperCache()
        
        // 监听网络状态变化
        networkMonitor.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.networkStatus = status
                // 网络恢复时自动刷新
                if status.connectionState.isConnected && self?.wallpapers.isEmpty == true {
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
    
    /// 本地扫描的壁纸（用户手动复制到目录的文件）
    var localWallpapers: [LocalWallpaperItem] {
        localScanner.getLocalWallpapers()
    }
    
    /// 所有可显示的本地壁纸（下载记录 + 扫描到的本地文件）
    /// 用于库页面显示。现在返回内存缓存，避免重复文件 I/O。
    var allLocalWallpapers: [UnifiedLocalWallpaper] {
        cachedAllLocalWallpapers
    }
    
    /// 重建本地壁纸缓存（在 downloadRecords / favoriteRecords / scanRevision 变化时自动调用）
    private func rebuildLocalWallpaperCache() {
        let downloads = wallpaperLibrary.downloadedWallpapers
        let locals = localScanner.getLocalWallpapers()
        
        var result: [UnifiedLocalWallpaper] = []
        
        // 添加下载记录
        for record in downloads {
            result.append(UnifiedLocalWallpaper(
                id: record.wallpaper.id,
                wallpaper: record.wallpaper,
                localItem: nil,
                downloadRecord: record,
                fileURL: record.localFileURL,
                isLocalFile: false
            ))
        }
        
        // 添加扫描到的本地文件（排除已在下载记录中的）
        let downloadedPaths = Set(downloads.compactMap { URL(string: $0.localFilePath)?.path })
            .map { ($0 as NSString).standardizingPath as String }
        for item in locals where !downloadedPaths.contains((item.fileURL.path as NSString).standardizingPath as String) {
            result.append(UnifiedLocalWallpaper(
                id: item.id,
                wallpaper: item.toWallpaper(),
                localItem: item,
                downloadRecord: nil,
                fileURL: item.fileURL,
                isLocalFile: true
            ))
        }
        
        // 按下载/创建时间排序
        cachedAllLocalWallpapers = result.sorted { a, b in
            let dateA = a.downloadRecord?.downloadedAt ?? a.localItem?.createdAt.flatMap { parseISO8601($0) } ?? Date.distantPast
            let dateB = b.downloadRecord?.downloadedAt ?? b.localItem?.createdAt.flatMap { parseISO8601($0) } ?? Date.distantPast
            return dateA > dateB
        }
    }
    
    /// 显式清理无效下载记录（文件不存在的记录），不应在 computed property 中自动调用
    func cleanupInvalidDownloadRecords() {
        wallpaperLibrary.cleanupInvalidDownloadRecords()
        rebuildLocalWallpaperCache()
    }

    var favoriteSyncRecords: [WallpaperFavoriteRecord] {
        wallpaperLibrary.favoriteRecords
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

        // 重置预加载状态
        preloadTask?.cancel()
        preloadedWallpapers = []
        preloadedPage = 0

        // 创建新的搜索任务
        searchTask = Task {
            do {
                // 检查是否被取消
                try Task.checkCancellation()

                let results = try await fetchWallpapers(query: searchQuery, page: 1)

                // 再次检查是否被取消
                try Task.checkCancellation()

                // ⚠️ 分批更新数据，避免一次性大量更新阻塞主线程
                currentRandomSeed = sortingOption == .random ? results.meta.seed : nil
                
                // 先更新壁纸库（后台操作）
                // ⚠️ 使用批量更新，减少持久化次数
                wallpaperLibrary.upsertBatch(results.data)
                
                // 分批更新 UI，每 10 个让出一次主线程
                let batchSize = 10
                let total = results.data.count
                for i in stride(from: 0, to: total, by: batchSize) {
                    let end = min(i + batchSize, total)
                    let batch = Array(results.data[i..<end])
                    
                    // 如果是第一批，立即更新显示
                    if i == 0 {
                        wallpapers = batch
                    } else {
                        // 后续批次追加
                        wallpapers.append(contentsOf: batch)
                    }
                    
                    // 让出主线程给 UI 渲染
                    if end < total {
                        await Task.yield()
                    }
                }
                
                hasMorePages = 1 < results.meta.lastPage

                if results.data.isEmpty {
                    errorMessage = "No wallpapers found. Check your API key and network connection."
                } else {
                    // 预加载前几张图片
                    preloadImages(for: Array(results.data.prefix(6)))
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
        response.data.forEach { wallpaperLibrary.upsert($0) }
        return Array(response.data.prefix(limit))
    }

    // MARK: - 加载更多（支持 Task Cancellation + 预加载）
    func loadMore() async {
        // 取消之前的加载任务
        loadMoreTask?.cancel()

        guard !isLoading, hasMorePages else { return }
        isLoading = true

        loadMoreTask = Task {
            do {
                try Task.checkCancellation()
                
                let nextPage = currentPage + 1
                let results: WallpaperSearchResponse
                
                // 检查是否有预加载的数据
                if preloadedPage == nextPage && !preloadedWallpapers.isEmpty {
                    results = WallpaperSearchResponse(
                        meta: .init(
                            query: searchQuery,
                            currentPage: nextPage,
                            perPage: .int(24),
                            total: preloadedWallpapers.count,
                            lastPage: preloadedWallpapers.count >= 24 ? nextPage + 10 : nextPage,
                            seed: currentRandomSeed
                        ),
                        data: preloadedWallpapers
                    )
                    // 清空预加载数据
                    preloadedWallpapers = []
                } else {
                    // 正常加载
                    results = try await fetchWallpapers(query: searchQuery, page: nextPage)
                }

                try Task.checkCancellation()

                currentRandomSeed = sortingOption == .random ? (results.meta.seed ?? currentRandomSeed) : nil
                results.data.forEach { wallpaperLibrary.upsert($0) }

                var existingIDs = Set(wallpapers.map(\.id))
                let appended = results.data.filter { existingIDs.insert($0.id).inserted }
                wallpapers.append(contentsOf: appended)
                
                // 移除数据上限，避免滚动时出现空白
                // 内存优化通过降低 Kingfisher 缓存实现
                currentPage = nextPage
                hasMorePages = currentPage < results.meta.lastPage

                // 预加载新加载的图片
                preloadImages(for: Array(appended.prefix(4)))
                
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

            isLoading = false
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
                
                // 存储预加载的数据
                preloadedPage = nextPageToPreload
                preloadedWallpapers = results.data
            } catch {
                // 预加载失败静默忽略
            }
        }
    }

    // MARK: - 取消所有任务
    func cancelAllTasks() {
        searchTask?.cancel()
        loadMoreTask?.cancel()
    }

    // MARK: - 图片预加载
    func preloadImages(for wallpapers: [Wallpaper]) {
        let urls = wallpapers.compactMap(\.thumbURL)
        ImagePrefetcher(urls: urls).start()
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
        }
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
        sourceManager.currentSourceSupportsNSFW
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

    private func normalizedCategoryMask() -> String {
        let mask = "\(categoryGeneral ? 1 : 0)\(categoryAnime ? 1 : 0)\(categoryPeople ? 1 : 0)"
        return mask == "000" ? "111" : mask
    }

    private func normalizedPurityMask() -> String {
        // 位掩码格式: 1=包含, 0=排除
        // 第一位=SFW, 第二位=Sketchy, 第三位=NSFW
        let sfw = puritySFW ? 1 : 0
        let sketchy = (apiKeyConfigured && puritySketchy) ? 1 : 0
        let nsfw = (apiKeyConfigured && purityNSFW) ? 1 : 0

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
    func downloadWallpaper(_ wallpaper: Wallpaper) async throws {
        // 确保下载权限
        guard await downloadPathManager.ensureDirectoryStructure() else {
            throw DownloadError.permissionDenied
        }
        
        let task = downloadTaskService.addTask(wallpaper: wallpaper)

        do {
            let imageData = try await downloadWallpaperData(wallpaper, taskID: task.id)

            guard let originalURL = wallpaper.fullImageURL else {
                throw NetworkError.invalidResponse
            }

            updateDownloadProgress(taskID: task.id, progress: 0.92)
            try await cacheService.cacheImage(imageData, for: originalURL)

            // 使用 DownloadPathManager 获取正确的保存路径
            let fileURL = downloadPathManager.wallpaperFileURL(
                id: wallpaper.id,
                fileExtension: wallpaper.fileExtension
            )

            // 确保目标目录存在
            let directory = fileURL.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }

            // 写入文件
            try imageData.write(to: fileURL)
            
            // 验证文件是否成功写入
            if FileManager.default.fileExists(atPath: fileURL.path) {
                wallpaperLibrary.recordDownload(wallpaper, fileURL: fileURL)
                downloadTaskService.markCompleted(id: task.id)
            } else {
                throw DownloadError.writeFailed(NSError(domain: "WaifuX", code: -1, userInfo: [NSLocalizedDescriptionKey: "File not found after write"]))
            }
        } catch {
            downloadTaskService.markFailed(id: task.id)
            throw error
        }
    }

    func downloadWallpaperData(_ wallpaper: Wallpaper, taskID: String? = nil) async throws -> Data {
        var downloadURL: URL?

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

        return try await networkService.fetchImage(from: downloadURL) { progress in
            guard let taskID else { return }
            Task { @MainActor in
                DownloadTaskService.shared.updateProgress(id: taskID, progress: min(progress * 0.9, 0.9))
            }
        }
    }

    private func updateDownloadProgress(taskID: String, progress: Double) {
        downloadTaskService.updateProgress(id: taskID, progress: progress)
    }

    // MARK: - 设置壁纸
    func setWallpaper(from imageURL: URL, option: WallpaperOption) async throws {
        WallpaperEngineXBridge.shared.ensureStoppedForNonCLIWallpaper()
        VideoWallpaperManager.shared.stopNativeVideoWallpaperOnly()

        let workspace = NSWorkspace.shared
        let screens = NSScreen.screens

        for screen in screens {
            switch option {
            case .desktop:
                try workspace.setDesktopImageURLForAllSpaces(imageURL, for: screen)
            case .lockScreen:
                // macOS 锁屏壁纸设置需要更复杂的实现
                // 这里使用简化版本
                try setLockScreenWallpaper(imageURL)
            case .both:
                try workspace.setDesktopImageURLForAllSpaces(imageURL, for: screen)
                try setLockScreenWallpaper(imageURL)
            }
        }

        // 注册壁纸以便跨 Space 同步
        DesktopWallpaperSyncManager.shared.registerWallpaperSet(imageURL)
    }
    
    // MARK: - 设置壁纸到指定屏幕
    func setWallpaper(from imageURL: URL, option: WallpaperOption, for targetScreen: NSScreen?) async throws {
        let workspace = NSWorkspace.shared
        
        // 如果指定了特定屏幕，只设置到该屏幕
        if let targetScreen = targetScreen {
            // 只停目标屏幕的动态壁纸，避免影响其他屏幕
            VideoWallpaperManager.shared.stopNativeVideoWallpaperOnly(for: targetScreen)
            switch option {
            case .desktop:
                try workspace.setDesktopImageURLForAllSpaces(imageURL, for: targetScreen)
            case .lockScreen:
                try setLockScreenWallpaper(imageURL)
            case .both:
                try workspace.setDesktopImageURLForAllSpaces(imageURL, for: targetScreen)
                try setLockScreenWallpaper(imageURL)
            }
            DesktopWallpaperSyncManager.shared.registerWallpaperSet(imageURL, for: targetScreen)
        } else {
            try await setWallpaper(from: imageURL, option: option)
        }
    }

    // MARK: - 设为壁纸（通过 Wallpaper 对象）
    func setAsWallpaper(_ wallpaper: Wallpaper) async throws {
        guard let imageURL = wallpaper.fullImageURL else {
            throw NSError(domain: "WaifuX", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid image URL"])
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async {
                do {
                    guard let screen = NSScreen.main else {
                        continuation.resume(throwing: NSError(domain: "WaifuX", code: 2, userInfo: [NSLocalizedDescriptionKey: "No screen available"]))
                        return
                    }
                    // 只停主屏幕的动态壁纸，避免影响其他屏幕
                    VideoWallpaperManager.shared.stopNativeVideoWallpaperOnly(for: screen)

                    let workspace = NSWorkspace.shared
                    try workspace.setDesktopImageURLForAllSpaces(imageURL, for: screen)
                    DesktopWallpaperSyncManager.shared.registerWallpaperSet(imageURL, for: screen)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func setLockScreenWallpaper(_ imageURL: URL) throws {
        // macOS 锁屏壁纸设置
        // 注意：macOS 不像 iOS 那样提供直接的锁屏壁纸 API
        // 锁屏壁纸通常与桌面壁纸相同，或者通过系统偏好设置中的"屏幕保护程序"设置
        // 这里我们尝试使用 defaults 命令设置锁屏壁纸（如果系统支持）

        // 方法1：尝试设置桌面壁纸（macOS 锁屏通常显示桌面壁纸）
        let workspace = NSWorkspace.shared
        for screen in NSScreen.screens {
            try workspace.setDesktopImageURLForAllSpaces(imageURL, for: screen)
        }

        // 方法2：尝试通过 defaults 命令设置锁屏图片（仅适用于某些 macOS 版本）
        // 注意：这不会在所有 macOS 版本上都有效
        let task = Process()
        task.launchPath = "/usr/bin/defaults"
        task.arguments = [
            "write",
            "/Library/Preferences/com.apple.loginwindow",
            "DesktopPicture",
            "-string",
            imageURL.path
        ]
        // 忽略错误，因为此方法可能需要管理员权限
        try? task.run()
    }

    // MARK: - 获取精选壁纸（用于轮播）- 日榜，仅横版
    func fetchFeaturedWallpapers() async throws -> [Wallpaper] {
        let sourceManager = WallpaperSourceManager.shared
        switch sourceManager.activeSource {
        case .fourKWallpapers:
            return try await FourKWallpapersService.shared.fetchFeatured(limit: 24)
        case .wallhaven:
            return try await featuredFromMainSource()
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
