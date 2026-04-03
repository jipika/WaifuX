import SwiftUI
import Combine
import AppKit

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
    private var imageLoadTasks: [String: Task<Void, Never>] = [:]
    
    // MARK: - 防抖搜索
    private var debounceTask: Task<Void, Never>?
    private let debounceInterval: TimeInterval = 0.3 // 300ms 防抖
    private var currentRandomSeed: String?

    // MARK: - 图片加载限制（使用 ImageLoader 的 LoadLimiter，避免忙等待）
    private let imageLoadLimiter = ImageLoader.shared.makeLoadLimiter(slots: 3)

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

    // MARK: - 本地收藏与下载记录
    private let wallpaperLibrary = WallpaperLibraryService.shared
    private let downloadTaskService = DownloadTaskService.shared
    private let downloadPathManager = DownloadPathManager.shared
    private var cancellables = Set<AnyCancellable>()

    /// 收藏/下载库变更时递增。探索页等仅依赖 `isFavorite`/`isDownloaded` 时，单靠转发 `objectWillChange` 在部分 SwiftUI 路径下不刷新。
    @Published private(set) var libraryContentRevision: UInt = 0

    // MARK: - 调度器服务
    private let schedulerService = WallpaperSchedulerService.shared

    private let networkService = NetworkService.shared
    private let cacheService = CacheService.shared

    // API Key - 本地存储
    private let apiKeyUserDefaultsKey = "wallhaven_api_key"
    private var apiKey: String {
        get { UserDefaults.standard.string(forKey: apiKeyUserDefaultsKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: apiKeyUserDefaultsKey) }
    }
    private var normalizedAPIKey: String? {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var apiKeyConfigured: Bool {
        normalizedAPIKey != nil
    }

    init() {
        Publishers.Merge(
            wallpaperLibrary.$favoriteRecords.map { _ in () },
            wallpaperLibrary.$downloadRecords.map { _ in () }
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in
            self?.libraryContentRevision &+= 1
        }
        .store(in: &cancellables)
        
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
        apiKeyConfigured  // 只有配置了 API Key 才能查看 NSFW 内容
    }

    // MARK: - 收藏相关
    var favorites: [Wallpaper] {
        wallpaperLibrary.favoriteWallpapers
    }

    var downloadedWallpapers: [WallpaperDownloadRecord] {
        wallpaperLibrary.downloadedWallpapers
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

    func toggleFavorite(_ wallpaper: Wallpaper) {
        wallpaperLibrary.toggleFavorite(wallpaper)
    }

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

        // 创建新的搜索任务
        searchTask = Task {
            do {
                // 检查是否被取消
                try Task.checkCancellation()

                let results = try await fetchWallpapers(query: searchQuery, page: 1)

                // 再次检查是否被取消
                try Task.checkCancellation()

                results.data.forEach { wallpaperLibrary.upsert($0) }
                currentRandomSeed = sortingOption == .random ? results.meta.seed : nil
                print("✅ Search success: \(results.data.count) wallpapers loaded, total: \(results.meta.total), lastPage: \(results.meta.lastPage)")
                wallpapers = results.data
                hasMorePages = 1 < results.meta.lastPage

                if results.data.isEmpty {
                    errorMessage = "No wallpapers found. Check your API key and network connection."
                } else {
                    // 预加载前几张图片
                    preloadImages(for: Array(results.data.prefix(6)))
                }
            } catch is CancellationError {
                print("ℹ️ Search was cancelled")
                isLoading = false
                return
            } catch let error as URLError where error.code == .cancelled {
                // 请求被取消（如快速切换筛选条件），不显示错误
                print("ℹ️ Search request cancelled")
                isLoading = false
                return
            } catch {
                errorMessage = error.localizedDescription
                print("❌ Search error: \(error)")
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
            resolutions: normalizedResolutions(),
            ratios: normalizedRatios(),
            colors: normalizedColors()
        )

        let response = try await fetchWallpapers(parameters: parameters)
        response.data.forEach { wallpaperLibrary.upsert($0) }
        return Array(response.data.prefix(limit))
    }

    // MARK: - 加载更多（支持 Task Cancellation）
    func loadMore() async {
        // 取消之前的加载任务
        loadMoreTask?.cancel()

        guard !isLoading, hasMorePages else { return }
        isLoading = true

        loadMoreTask = Task {
            do {
                try Task.checkCancellation()

                let results = try await fetchWallpapers(query: searchQuery, page: currentPage + 1)

                try Task.checkCancellation()

                currentRandomSeed = sortingOption == .random ? (results.meta.seed ?? currentRandomSeed) : nil
                results.data.forEach { wallpaperLibrary.upsert($0) }

                var existingIDs = Set(wallpapers.map(\.id))
                let appended = results.data.filter { existingIDs.insert($0.id).inserted }
                wallpapers.append(contentsOf: appended)
                currentPage += 1
                hasMorePages = currentPage < results.meta.lastPage

                // 预加载新加载的图片
                preloadImages(for: Array(appended.prefix(4)))
            } catch is CancellationError {
                print("ℹ️ Load more was cancelled")
                return
            } catch let error as URLError where error.code == .cancelled {
                // 请求被取消，不显示错误
                print("ℹ️ Load more request cancelled")
                return
            } catch {
                errorMessage = error.localizedDescription
                print("Load more error: \(error)")
            }

            isLoading = false
        }

        await loadMoreTask?.value
    }

    // MARK: - 取消所有任务
    func cancelAllTasks() {
        searchTask?.cancel()
        loadMoreTask?.cancel()
        for (_, task) in imageLoadTasks {
            task.cancel()
        }
        imageLoadTasks.removeAll()
        ImageLoader.shared.cancelAllLoads()
    }

    // MARK: - 图片预加载（限制并发数量）
    func preloadImages(for wallpapers: [Wallpaper]) {
        let imageLoader = ImageLoader.shared

        for wallpaper in wallpapers {
            guard let thumbURL = wallpaper.thumbURL else { continue }

            let task = Task(priority: .low) {
                _ = await imageLoader.loadImage(from: thumbURL, priority: .low)
            }

            imageLoadTasks[wallpaper.id] = task
        }
    }

    // MARK: - 加载单张图片（带并发限制）
    func loadImage(for wallpaper: Wallpaper, priority: TaskPriority = .medium) async -> NSImage? {
        guard let thumbURL = wallpaper.thumbURL else { return nil }

        // 使用 ImageLoader 的 LoadLimiter 进行并发控制
        await imageLoadLimiter.acquire()
        defer { Task { await imageLoadLimiter.release() } }

        return await ImageLoader.shared.loadImage(from: thumbURL, priority: priority)
    }

    // MARK: - 加载原图（用于轮播大图显示）
    func loadFullImage(for wallpaper: Wallpaper) async -> NSImage? {
        // 先尝试加载原图
        if let fullURL = wallpaper.fullImageURL {
            if let image = await ImageLoader.shared.loadImage(from: fullURL, priority: .high) {
                return image
            }
        }
        
        // 回退到缩略图
        return await loadImage(for: wallpaper, priority: .high)
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
            resolutions: normalizedResolutions(),
            ratios: normalizedRatios(),
            colors: normalizedColors(),
            seed: sortingOption == .random ? currentRandomSeed : nil
        )

        // 打印请求参数用于调试
        print("[WallpaperViewModel] Search params:")
        print("  - categories: \(parameters.categories)")
        print("  - purity: \(parameters.purity)")
        print("  - sorting: \(parameters.sorting)")
        print("  - order: \(parameters.order)")
        print("  - topRange: \(parameters.topRange ?? "nil")")
        print("  - seed: \(parameters.seed ?? "nil")")
        print("  - query: '\(parameters.query)'")
        print("  - resolutions: \(parameters.resolutions)")
        print("  - ratios: \(parameters.ratios)")
        print("  - colors: \(parameters.colors)")

        return try await fetchWallpapers(parameters: parameters)
    }

    private func fetchWallpapers(parameters: WallhavenAPI.SearchParameters) async throws -> WallpaperSearchResponse {
        guard let url = WallhavenAPI.url(for: .search(parameters)) else {
            throw NetworkError.invalidResponse
        }

        return try await networkService.fetch(
            WallpaperSearchResponse.self,
            from: url,
            headers: WallhavenAPI.authenticationHeaders(apiKey: normalizedAPIKey)
        )
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
            downloadPathManager.createDirectoryStructure()

            try imageData.write(to: fileURL)
            wallpaperLibrary.recordDownload(wallpaper, fileURL: fileURL)
            downloadTaskService.markCompleted(id: task.id)

            print("Saved to: \(fileURL)")
        } catch {
            downloadTaskService.markFailed(id: task.id)
            throw error
        }
    }

    func downloadWallpaperData(_ wallpaper: Wallpaper, taskID: String? = nil) async throws -> Data {
        guard let downloadURL = wallpaper.fullImageURL ?? wallpaper.thumbURL else {
            throw NetworkError.invalidResponse
        }

        print("Downloading from: \(downloadURL)")

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
        let workspace = NSWorkspace.shared
        let screens = NSScreen.screens

        for screen in screens {
            switch option {
            case .desktop:
                try workspace.setDesktopImageURL(imageURL, for: screen, options: [:])
            case .lockScreen:
                // macOS 锁屏壁纸设置需要更复杂的实现
                // 这里使用简化版本
                try setLockScreenWallpaper(imageURL)
            case .both:
                try workspace.setDesktopImageURL(imageURL, for: screen, options: [:])
                try setLockScreenWallpaper(imageURL)
            }
        }
    }

    // MARK: - 设为壁纸（通过 Wallpaper 对象）
    func setAsWallpaper(_ wallpaper: Wallpaper) async throws {
        guard let imageURL = wallpaper.fullImageURL else {
            throw NSError(domain: "WallHaven", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid image URL"])
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async {
                do {
                    let workspace = NSWorkspace.shared
                    guard let screen = NSScreen.main else {
                        continuation.resume(throwing: NSError(domain: "WallHaven", code: 2, userInfo: [NSLocalizedDescriptionKey: "No screen available"]))
                        return
                    }
                    try workspace.setDesktopImageURL(imageURL, for: screen, options: [:])
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
            try workspace.setDesktopImageURL(imageURL, for: screen, options: [:])
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
            featuredWallpapers = try await fetchFeaturedWallpapers()
        } catch {
            print("Failed to fetch featured: \(error)")
        }
    }

    private func fetchTopAndUpdate() async {
        do {
            topWallpapers = try await fetchTopWallpapers()
        } catch {
            print("Failed to fetch top: \(error)")
        }
    }

    private func fetchLatestAndUpdate() async {
        do {
            latestWallpapers = try await fetchLatestWallpapers()
        } catch {
            print("Failed to fetch latest: \(error)")
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
