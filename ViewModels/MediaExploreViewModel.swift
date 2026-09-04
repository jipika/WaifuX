import SwiftUI
import Combine
import AppKit

@MainActor
final class MediaExploreViewModel: ObservableObject {
    @Published private(set) var items: [MediaItem] = []
    @Published private(set) var homeItems: [MediaItem] = []
    @Published private(set) var currentTitle = "Featured"
    @Published var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published var errorMessage: String?
    @Published private(set) var hasMorePages = true
    @Published private(set) var currentQuery = ""

    // MARK: - Network State
    @Published var networkStatus: NetworkStatus = .unknown
    private let networkMonitor = NetworkMonitor.shared

    /// 内存保护：列表缓存上限，超出上限时丢弃最旧条目触发 grid reload。
    /// 设为 2000 使普通浏览不会触达，避免 suffix 裁剪导致瀑布流就地重排、内容跳到顶部。
    private static let maxCachedItems = 2000
    /// 详情预抓队列上限，避免快速滚动时待处理 MediaItem 长时间堆积。
    private static let maxPendingDetailPrefetchItems = 48

    private let mediaService = MediaService.shared
    private let mediaLibrary = MediaLibraryService.shared
    private let networkService = NetworkService.shared
    private let cacheService = CacheService.shared
    private let videoWallpaperManager = VideoWallpaperManager.shared
    private let downloadTaskService = DownloadTaskService.shared
    private let downloadPathManager = DownloadPathManager.shared
    let workshopService = WorkshopService.shared
    private let workshopSourceManager = WorkshopSourceManager.shared
    private let dynamicWallpaperService = DynamicWallpaperService.shared
    private let wallsflowService = WallsflowService.shared

    private var currentSource: MediaRouteSource = .home
    private var nextPagePath: String?
    private var detailTasks: [String: Task<MediaItem, Error>] = [:]
    private var pendingDetailPrefetchItems: [MediaItem] = []
    private var pendingDetailPrefetchIDs = Set<String>()
    private var detailPrefetchCoordinatorTask: Task<Void, Never>?
    private var networkRecoveryTask: Task<Void, Never>?
    private var sourceSwitchTask: Task<Void, Never>?
    private var networkMonitorSetupTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - 预加载支持
    private enum PreloadedPage {
        case motionBG(pagePath: String, items: [MediaItem], nextPagePath: String?)
        case workshop(page: Int, items: [MediaItem], hasMore: Bool)
        case dongtai(page: Int, items: [MediaItem], hasMore: Bool)
        case wallsflow(page: Int, items: [MediaItem], nextPagePath: String?)
    }

    private var preloadTask: Task<Void, Never>?
    private var preloadedPage: PreloadedPage?
    private var preloadGeneration: UInt = 0

    /// 详情页导航期间的探索列表快照。用于防止 SwiftUI 视图重建、前台释放或过期加载
    /// 把已滚动出来的分页列表清空/回退到第一页。
    private var preservedExploreFeedSnapshot: ExploreFeedSnapshot?

    private struct ExploreFeedSnapshot {
        let activeSource: WorkshopSourceManager.SourceType
        let items: [MediaItem]
        let currentTitle: String
        let currentQuery: String
        let currentSource: MediaRouteSource
        let nextPagePath: String?
        let hasMorePages: Bool
        let preloadedPage: PreloadedPage?
        let workshopCurrentPage: Int
        let workshopHasMore: Bool
        let workshopSearchQuery: String
        let workshopCurrentTags: [String]
        let workshopCurrentType: WorkshopSourceManager.WorkshopTypeFilter
        let workshopCurrentContentLevel: WorkshopSourceManager.WorkshopContentLevel?
        let workshopCurrentResolution: String?
        let workshopSortBy: WorkshopSearchParams.SortOption
        let workshopDays: Int?
        let dongtaiCurrentPage: Int
        let dongtaiHasMore: Bool
        let dongtaiSearchQuery: String
        let dongtaiCurrentCategories: Set<DynamicWallpaperCategory>
        let dongtaiCurrentListType: DynamicWallpaperListType
        let dongtaiSortBy: DynamicWallpaperSortOption
        let dongtaiFilterAudio: Bool?
        let dongtaiFilterFourK: Bool?
        let wallsflowCurrentPage: Int
        let wallsflowHasMore: Bool
        let wallsflowSearchQuery: String
        let wallsflowCurrentCategorySlug: String
    }

    /// 本地媒体缓存重建任务（带防抖）
    private var rebuildLocalMediaCacheTask: Task<Void, Never>?
    private var localMediaCacheRebuildID: UUID?
    /// 仅在主窗口释放前台资源后置为 true；空数组本身仍可能是一个有效的库快照。
    private var localMediaCacheNeedsRestore = false

    // MARK: - Workshop 分页状态
    private var workshopCurrentPage = 1
    private var workshopHasMore = true
    private(set) var workshopSearchQuery = ""
    private var workshopCurrentTags: [String] = []
    private var workshopCurrentType: WorkshopSourceManager.WorkshopTypeFilter = .all
    /// 默认 SFW（Steam `requiredtags[]=Everyone`），避免未选级别时混入全年龄未分级内容
    private var workshopCurrentContentLevel: WorkshopSourceManager.WorkshopContentLevel? = .everyone
    /// Workshop 分辨率/比例筛选
    private var workshopCurrentResolution: String? = nil
    /// Workshop 排序方式（用户选择过则跨启动持久化）
    private(set) var workshopSortBy: WorkshopSearchParams.SortOption = .ranked
    /// Workshop 热门趋势时间范围（仅对 trend 排序有效），nil = 全部时间
    private(set) var workshopDays: Int? = nil
    /// UI 层 Workshop 排序菜单 rawValue（含 trend_7 等细分）
    private(set) var workshopSortMenuRawValue: String = "trend_7"

    // MARK: - Dynamic Wallpaper (DongTai) 分页状态
    private var dongtaiCurrentPage = 1
    private var dongtaiHasMore = true
    private var dongtaiSearchQuery = ""
    private var dongtaiCurrentCategories: Set<DynamicWallpaperCategory> = []
    private var dongtaiCurrentListType: DynamicWallpaperListType = .all
    private(set) var dongtaiSortBy: DynamicWallpaperSortOption = .popular
    private var dongtaiFilterAudio: Bool? = nil
    private var dongtaiFilterFourK: Bool? = nil
    /// 加载世代计数器，用于丢弃旧请求的结果
    private var dongtaiLoadGeneration: UInt = 0

    // MARK: - Explore 排序持久化
    // ⚠️ 不在 init 读 UserDefaults（macOS 26+ _CFXPreferences 栈溢出风险），由 restoreExploreSortPreferences() 延迟恢复
    private static let workshopSortMenuDefaultsKey = "explore.media.workshopSortMenu"
    private static let dongtaiSortDefaultsKey = "explore.media.dongtaiSort"
    private var hasRestoredExploreSort = false

    // MARK: - Wallsflow 分页状态
    private var wallsflowCurrentPage = 1
    private var wallsflowHasMore = true
    private var wallsflowSearchQuery = ""
    private var wallsflowCurrentCategorySlug: String = "live-wallpapers"

    /// 与 WallpaperViewModel.libraryContentRevision 相同用途：保证列表上的收藏/下载状态随库更新而刷新。
    @Published private(set) var libraryContentRevision: UInt = 0

    // MARK: - 计算属性

    /// 当前 Feed 标题（用于 UI 展示）
    var currentFeedTitle: String {
        currentTitle
    }

    /// 缓存的本地媒体列表，避免每次 body 重绘时重复计算和文件 I/O
    @Published var cachedAllLocalMedia: [UnifiedLocalMedia] = []

    /// 内存压力通知 observer token；deinit 时移除。
    /// ⚠️ token 一旦丢弃，NotificationCenter 会永久持有 observer block。
    /// nonisolated(unsafe)：deinit 需要访问；removeObserver 线程安全。
    private nonisolated(unsafe) var memoryPressureObserver: NSObjectProtocol?

    init() {
        // 缓存 UserDefaults 值，避免后台线程访问触发 _CFXPreferences 递归崩溃
        // 注意：此读取本身也有风险，但为既有路径；探索排序改为 restoreExploreSortPreferences() 延迟恢复
        persistDownloadedMediaToAppLibrary = UserDefaults.standard.object(forKey: DownloadPathManager.persistDownloadsToAppLibraryDefaultsKey) as? Bool ?? true

        // 注册内存压力通知（由 WaifuXApp.configureKingfisher 中的 DispatchSource 触发）
        // ⚠️ 外层闭包必须 [weak self]，否则 observer block 强捕获 self → 实例永不释放。
        memoryPressureObserver = NotificationCenter.default.addObserver(
            forName: .appDidReceiveMemoryPressure,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleMemoryPressure()
            }
        }

        // MARK: - 优化后的 Service 数据变更监听：保护主线程免受 I/O 阻塞
        Publishers.Merge(
            mediaLibrary.$favoriteRecords.map { _ in () },
            mediaLibrary.$downloadRecords.map { _ in () }
        )
        // 1. ⚙️ 不要在主线程接收原始通知，直接在当前的后台或默认管道处理
        .sink { [weak self] _ in
            guard let self else { return }

            // 2. 🚀 调度缓存重建（scheduleLocalMediaCacheRebuild 本身只是取消旧 Task + 创建新 Task，
            // 核心重算 rebuildLocalMediaCache 内部已用 Task.detached 投到后台 Utility 线程，
            // 此处仅需轻量调度，不会阻塞主线程。）
            Task { @MainActor [weak self] in
                self?.scheduleLocalMediaCacheRebuild(delayNanoseconds: 100_000_000)
            }

            // 3. 🎨 仅仅将极其轻量的版本号递增（O(1) 状态变更）交还给主线程驱动 UI
            Task { @MainActor [weak self] in
                self?.libraryContentRevision &+= 1
            }
        }
        .store(in: &cancellables)

        // 临时 Scene 静帧不修改下载记录，但会改变「我的库」的封面来源。
        // 推进同一个 revision，让 MyLibraryContentView 重建 AnyMediaItem 快照。
        NotificationCenter.default.publisher(for: .sceneOfflineBakeThumbnailDidUpdate)
            .compactMap { $0.object as? String }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.libraryContentRevision &+= 1
            }
            .store(in: &cancellables)

        // 初始重建一次缓存
        scheduleLocalMediaCacheRebuild(delayNanoseconds: 0)

        // 监听网络状态变化
        networkMonitor.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.networkStatus = status
                // 网络恢复时自动刷新，根据当前源加载正确数据
                // 媒体模块关闭时跳过，避免禁用后仍触发远程源请求
                if status.connectionState.isConnected
                    && self?.items.isEmpty == true
                    && ModuleAvailability.shared.mediaEnabled {
                    self?.networkRecoveryTask?.cancel()
                    self?.networkRecoveryTask = Task { [weak self] in
                        guard let self else { return }
                        switch self.workshopSourceManager.activeSource {
                        case .wallpaperEngine:
                            await self.loadWorkshopFeed()
                        case .dongtai:
                            await self.loadDongTaiFeed()
                        default:
                            await self.loadHomeFeed()
                        }
                    }
                }
            }
            .store(in: &cancellables)

        // 监听 Workshop 数据源变化
        workshopSourceManager.$activeSource
            .receive(on: DispatchQueue.main)
            .sink { [weak self] source in
                guard let self = self else { return }
                // 清空旧数据，避免切换时新旧内容混在一起
                // 1. 取消所有进行中的异步任务，防止旧任务完成后写回 items
                self.sourceSwitchTask?.cancel()
                self.sourceSwitchTask = nil
                self.cancelPreload()
                self.networkRecoveryTask?.cancel()
                self.networkRecoveryTask = nil
                self.detailTasks.values.forEach { $0.cancel() }
                self.detailTasks.removeAll()
                self.cancelDetailPrefetchQueue()
                self.invalidatePreservedExploreFeed()
                // 2. 清空预加载缓存
                // 3. 重置 isLoading/isLoadingMore 防止旧任务的 isLoading 阻塞新源的加载
                self.isLoading = false
                self.isLoadingMore = false
                // 4. 清空列表
                self.items.removeAll()
                switch source {
                case .wallpaperEngine:
                    // 切换到 Workshop 数据源
                    self.sourceSwitchTask = Task { [weak self] in
                        guard let self else { return }
                        await self.loadWorkshopFeed()
                        await self.refreshHomeItems()
                    }
                case .dongtai:
                    // 切换到 Dynamic Wallpaper 数据源
                    self.sourceSwitchTask = Task { [weak self] in
                        guard let self else { return }
                        await self.loadDongTaiFeed()
                        await self.refreshHomeItems()
                    }
                case .wallsflow:
                    // 切换到 Wallsflow 数据源
                    self.sourceSwitchTask = Task { [weak self] in
                        guard let self else { return }
                        await self.loadWallsflowFeed()
                        await self.refreshHomeItems()
                    }
                default:
                    // 切换回 MotionBG 数据源，重置状态
                    self.workshopCurrentPage = 1
                    self.workshopHasMore = true
                    self.workshopSearchQuery = ""
                    self.dongtaiCurrentPage = 1
                    self.dongtaiHasMore = true
                    self.dongtaiSearchQuery = ""
                    self.wallsflowCurrentPage = 1
                    self.wallsflowHasMore = true
                    self.wallsflowSearchQuery = ""
                    self.sourceSwitchTask = Task { [weak self] in
                        guard let self else { return }
                        await self.loadHomeFeed()
                        await self.refreshHomeItems()
                    }
                }
            }
            .store(in: &cancellables)

        // 启动网络监测
        networkMonitor.startMonitoring()

        // 设置网络监测器到网络服务
        networkMonitorSetupTask = Task { [networkService, networkMonitor] in
            await networkService.setNetworkMonitor(networkMonitor)
        }
    }

    deinit {
        if let observer = memoryPressureObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    var favoriteItems: [MediaItem] {
        mediaLibrary.favoriteItems
    }

    var favoriteSyncRecords: [MediaFavoriteRecord] {
        mediaLibrary.favoriteRecords
    }

    var downloadedItems: [MediaDownloadRecord] {
        mediaLibrary.downloadedItems
    }

    /// 所有可显示的本地媒体。导入和下载都会同步创建持久化记录，
    /// 因此库页面只读该记录缓存，不再枚举下载目录。
    var allLocalMedia: [UnifiedLocalMedia] {
        cachedAllLocalMedia
    }

    /// 确保本地媒体索引可供库页面使用。
    /// 缓存失效时会合并并发请求，避免多个视图重复从持久化记录重建同一份快照。
    func ensureLocalMediaIndex() async {
        guard localMediaCacheNeedsRestore else { return }
        if let task = rebuildLocalMediaCacheTask {
            await task.value
            return
        }
        await startLocalMediaCacheRebuild(delayNanoseconds: 0).value
    }

    /// 重建本地媒体缓存（在 downloadRecords / favoriteRecords 变化时自动调用）
    private func scheduleLocalMediaCacheRebuild(delayNanoseconds: UInt64) {
        _ = startLocalMediaCacheRebuild(delayNanoseconds: delayNanoseconds)
    }

    @discardableResult
    private func startLocalMediaCacheRebuild(delayNanoseconds: UInt64) -> Task<Void, Never> {
        rebuildLocalMediaCacheTask?.cancel()
        let rebuildID = UUID()
        localMediaCacheRebuildID = rebuildID

        let task = Task { @MainActor [weak self] in
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard let self, !Task.isCancelled else { return }
            await self.rebuildLocalMediaCache()
            guard self.localMediaCacheRebuildID == rebuildID else { return }
            self.rebuildLocalMediaCacheTask = nil
            self.localMediaCacheRebuildID = nil
        }
        rebuildLocalMediaCacheTask = task
        return task
    }

    /// 从持久化下载记录重建库页面缓存。此路径不访问文件系统。
    private func rebuildLocalMediaCache() async {
        let downloads = mediaLibrary.downloadedItems

        let result = await Task.detached(priority: .utility) {
            downloads.map { record in
                UnifiedLocalMedia(
                    id: record.item.id,
                    mediaItem: record.item,
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
        cachedAllLocalMedia = result
        localMediaCacheNeedsRestore = false
        // 缓存重建完成后递增版本号，触发 MyLibraryContentView 的
        // .onChange → debouncedUpdateMediaItems()，让依赖缓存的
        // 标签页（如「下载」）在拖拽入库等操作后能读到新鲜数据。
        libraryContentRevision &+= 1
    }

    /// 显式清理无效下载记录（文件不存在的记录），不应在 computed property 中自动调用
    func cleanupInvalidDownloadRecords() {
        mediaLibrary.cleanupInvalidDownloadRecords()
        scheduleLocalMediaCacheRebuild(delayNanoseconds: 0)
    }

    var downloadSyncRecords: [MediaDownloadRecord] {
        mediaLibrary.downloadRecords
    }

    var pendingSyncFavorites: [MediaFavoriteRecord] {
        mediaLibrary.pendingSyncFavorites
    }

    var pendingSyncDownloads: [MediaDownloadRecord] {
        mediaLibrary.pendingSyncDownloads
    }

    var recentItems: [MediaItem] {
        mediaLibrary.recentItems
    }

    func initialLoadIfNeeded() async {
        print("[MediaExploreViewModel] initialLoadIfNeeded called, items.count=\(items.count)")
        // 兜底：确保探索排序在首次加载前已从 UserDefaults 恢复
        restoreExploreSortPreferences()
        if restoreExploreFeedIfNeededAfterDetailReturn() {
            print("[MediaExploreViewModel] restored preserved explore feed, skipping initial load")
            return
        }
        guard items.isEmpty else {
            print("[MediaExploreViewModel] items not empty, skipping initial load")
            return
        }
        switch workshopSourceManager.activeSource {
        case .wallpaperEngine:
            await loadWorkshopFeed()
        case .dongtai:
            await loadDongTaiFeed()
        case .wallsflow:
            await loadWallsflowFeed()
        default:
            await load(source: .home)
        }
    }

    func preserveExploreFeedForDetailNavigation() {
        guard !items.isEmpty else { return }

        preservedExploreFeedSnapshot = ExploreFeedSnapshot(
            activeSource: workshopSourceManager.activeSource,
            items: items,
            currentTitle: currentTitle,
            currentQuery: currentQuery,
            currentSource: currentSource,
            nextPagePath: nextPagePath,
            hasMorePages: hasMorePages,
            preloadedPage: preloadedPage,
            workshopCurrentPage: workshopCurrentPage,
            workshopHasMore: workshopHasMore,
            workshopSearchQuery: workshopSearchQuery,
            workshopCurrentTags: workshopCurrentTags,
            workshopCurrentType: workshopCurrentType,
            workshopCurrentContentLevel: workshopCurrentContentLevel,
            workshopCurrentResolution: workshopCurrentResolution,
            workshopSortBy: workshopSortBy,
            workshopDays: workshopDays,
            dongtaiCurrentPage: dongtaiCurrentPage,
            dongtaiHasMore: dongtaiHasMore,
            dongtaiSearchQuery: dongtaiSearchQuery,
            dongtaiCurrentCategories: dongtaiCurrentCategories,
            dongtaiCurrentListType: dongtaiCurrentListType,
            dongtaiSortBy: dongtaiSortBy,
            dongtaiFilterAudio: dongtaiFilterAudio,
            dongtaiFilterFourK: dongtaiFilterFourK,
            wallsflowCurrentPage: wallsflowCurrentPage,
            wallsflowHasMore: wallsflowHasMore,
            wallsflowSearchQuery: wallsflowSearchQuery,
            wallsflowCurrentCategorySlug: wallsflowCurrentCategorySlug
        )
    }

    @discardableResult
    func restoreExploreFeedIfNeededAfterDetailReturn() -> Bool {
        guard let snapshot = preservedExploreFeedSnapshot else { return false }
        guard snapshot.activeSource == workshopSourceManager.activeSource else {
            invalidatePreservedExploreFeed()
            return false
        }
        guard shouldRestoreExploreFeed(from: snapshot) else {
            if !items.isEmpty {
                invalidatePreservedExploreFeed()
            }
            return false
        }

        let currentItemsByID = items.reduce(into: [String: MediaItem]()) { result, item in
            result[item.id] = item
        }
        items = snapshot.items.map { currentItemsByID[$0.id] ?? $0 }
        currentTitle = snapshot.currentTitle
        currentQuery = snapshot.currentQuery
        currentSource = snapshot.currentSource
        nextPagePath = snapshot.nextPagePath
        hasMorePages = snapshot.hasMorePages
        preloadedPage = snapshot.preloadedPage
        workshopCurrentPage = snapshot.workshopCurrentPage
        workshopHasMore = snapshot.workshopHasMore
        workshopSearchQuery = snapshot.workshopSearchQuery
        workshopCurrentTags = snapshot.workshopCurrentTags
        workshopCurrentType = snapshot.workshopCurrentType
        workshopCurrentContentLevel = snapshot.workshopCurrentContentLevel
        workshopCurrentResolution = snapshot.workshopCurrentResolution
        workshopSortBy = snapshot.workshopSortBy
        workshopDays = snapshot.workshopDays
        dongtaiCurrentPage = snapshot.dongtaiCurrentPage
        dongtaiHasMore = snapshot.dongtaiHasMore
        dongtaiSearchQuery = snapshot.dongtaiSearchQuery
        dongtaiCurrentCategories = snapshot.dongtaiCurrentCategories
        dongtaiCurrentListType = snapshot.dongtaiCurrentListType
        dongtaiSortBy = snapshot.dongtaiSortBy
        dongtaiFilterAudio = snapshot.dongtaiFilterAudio
        dongtaiFilterFourK = snapshot.dongtaiFilterFourK
        wallsflowCurrentPage = snapshot.wallsflowCurrentPage
        wallsflowHasMore = snapshot.wallsflowHasMore
        wallsflowSearchQuery = snapshot.wallsflowSearchQuery
        wallsflowCurrentCategorySlug = snapshot.wallsflowCurrentCategorySlug
        errorMessage = nil
        isLoading = false
        isLoadingMore = false
        invalidatePreservedExploreFeed()
        return true
    }

    func invalidatePreservedExploreFeed() {
        preservedExploreFeedSnapshot = nil
    }

    private func shouldRestoreExploreFeed(from snapshot: ExploreFeedSnapshot) -> Bool {
        guard !snapshot.items.isEmpty else { return false }

        if items.isEmpty {
            return true
        }

        guard items.count < snapshot.items.count else { return false }
        let currentIDs = items.map(\.id)
        let snapshotPrefixIDs = snapshot.items.prefix(items.count).map(\.id)
        return currentIDs.elementsEqual(snapshotPrefixIDs)
    }

    func load(source: MediaRouteSource) async {
        print("[MediaExploreViewModel] load called with source=\(source), current isLoading=\(isLoading)")

        guard !isLoading else {
            print("[MediaExploreViewModel] already loading, skipping")
            return
        }

        invalidatePreservedExploreFeed()
        isLoading = true
        print("[MediaExploreViewModel] isLoading set to true")

        defer {
            print("[MediaExploreViewModel] defer executed, resetting isLoading")
            isLoading = false
        }

        errorMessage = nil

        // 重置分页状态
        nextPagePath = nil
        hasMorePages = true

        // 重置预加载状态
        cancelPreload()
        cancelDetailPrefetchQueue()

        print("[MediaExploreViewModel] about to call fetchPage")

        do {
            let page = try await withTimeout(seconds: 30) {
                try await self.mediaService.fetchPage(source: source)
            }

            print("[MediaExploreViewModel] received page with \(page.items.count) items")
            // 源一致性检查：如果切换了源，丢弃这个过期结果
            guard workshopSourceManager.activeSource == .motionBG else { return }
            currentSource = source
            currentTitle = page.sectionTitle
            page.items.forEach { mediaLibrary.upsert($0) }
            items = page.items
            nextPagePath = page.nextPagePath
            hasMorePages = page.nextPagePath != nil
            if hasMorePages {
                triggerMotionBGPreload()
            }
            print("[MediaExploreViewModel] load completed successfully")
        } catch {
            print("[MediaExploreViewModel] load failed with error: \(error)")
            errorMessage = error.localizedDescription
        }
    }

    // 添加超时辅助函数
    private func withTimeout<T: Sendable>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw NetworkError.timeout
            }
            guard let result = try await group.next() else {
                throw NetworkError.timeout
            }
            group.cancelAll()
            return result
        }
    }

    func loadMore() async {
        guard !isLoading, !isLoadingMore, let nextPagePath else { return }
        isLoadingMore = true
        let requestedPagePath = nextPagePath

        defer {
            isLoadingMore = false
        }

        do {
            let page: MediaListPage

            // 先等待正在进行的下一页预取，避免触底时再次请求同一页。
            if let preloadTask {
                await preloadTask.value
            }

            if case let .motionBG(pagePath, cachedItems, cachedNextPath) = preloadedPage,
               pagePath == requestedPagePath {
                print("[MediaExploreViewModel] Using preloaded page")
                page = MediaListPage(
                    items: cachedItems,
                    nextPagePath: cachedNextPath,
                    sectionTitle: currentTitle
                )
                preloadedPage = nil
            } else {
                // 正常加载
                page = try await mediaService.fetchPage(source: currentSource, pagePath: requestedPagePath)
            }

            // 源一致性检查：如果切换了源，丢弃这个过期结果
            guard workshopSourceManager.activeSource == .motionBG else { return }

            let existingIDs = Set(items.map(\.id))
            let appended = page.items.filter { !existingIDs.contains($0.id) }
            page.items.forEach { mediaLibrary.upsert($0) }
            items.append(contentsOf: appended)
            enqueueDetailPrefetch(for: appended, prioritizeVisible: false)

            self.nextPagePath = page.nextPagePath
            hasMorePages = page.nextPagePath != nil
            if hasMorePages {
                triggerMotionBGPreload()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - 预加载下一页
    private func cancelPreload() {
        preloadGeneration &+= 1
        preloadTask?.cancel()
        preloadTask = nil
        preloadedPage = nil
    }

    private func beginPreload() -> UInt {
        preloadTask?.cancel()
        preloadTask = nil
        preloadedPage = nil
        preloadGeneration &+= 1
        return preloadGeneration
    }

    private func triggerMotionBGPreload() {
        guard let nextPath = nextPagePath else {
            cancelPreload()
            return
        }

        let generation = beginPreload()
        let source = currentSource
        preloadTask = Task(priority: .low) { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self, !Task.isCancelled else { return }

            do {
                let page = try await self.mediaService.fetchPage(source: source, pagePath: nextPath)
                guard !Task.isCancelled,
                      self.preloadGeneration == generation,
                      self.workshopSourceManager.activeSource == .motionBG else { return }
                self.preloadedPage = .motionBG(
                    pagePath: nextPath,
                    items: page.items,
                    nextPagePath: page.nextPagePath
                )
                print("[MediaExploreViewModel] Preloaded MotionBG page at path \(nextPath)")
            } catch {
                print("[MediaExploreViewModel] MotionBG preload failed: \(error)")
            }
        }
    }

    /// 将待补抓详情的媒体项放入稳定队列，统一做有限并发抓取与回填。
    func enqueueDetailPrefetch(
        for items: [MediaItem],
        prioritizeVisible: Bool
    ) {
        guard workshopSourceManager.activeSource != .wallpaperEngine,
              workshopSourceManager.activeSource != .dongtai,
              workshopSourceManager.activeSource != .wallsflow else { return }

        let candidates = items.filter(shouldPrefetchDetail(for:))

        guard !candidates.isEmpty else { return }

        if prioritizeVisible {
            for item in candidates.reversed() {
                guard pendingDetailPrefetchIDs.insert(item.id).inserted else { continue }
                pendingDetailPrefetchItems.insert(item, at: 0)
            }
        } else {
            for item in candidates {
                guard pendingDetailPrefetchIDs.insert(item.id).inserted else { continue }
                pendingDetailPrefetchItems.append(item)
            }
        }

        trimPendingDetailPrefetchQueue()
        startDetailPrefetchCoordinatorIfNeeded()
    }

    private func startDetailPrefetchCoordinatorIfNeeded() {
        guard detailPrefetchCoordinatorTask == nil else { return }

        detailPrefetchCoordinatorTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.runDetailPrefetchCoordinator()
        }
    }

    private func runDetailPrefetchCoordinator(maxConcurrent: Int = 4) async {
        defer { detailPrefetchCoordinatorTask = nil }

        while !Task.isCancelled {
            let batch = nextDetailPrefetchBatch(limit: maxConcurrent)
            guard !batch.isEmpty else { break }

            await withTaskGroup(of: Void.self) { group in
                for item in batch {
                    group.addTask { [weak self] in
                        guard let self else { return }
                        _ = try? await self.loadDetail(for: item)
                    }
                }
            }
        }
    }

    private func nextDetailPrefetchBatch(limit: Int) -> [MediaItem] {
        guard limit > 0, !pendingDetailPrefetchItems.isEmpty else { return [] }

        var batch: [MediaItem] = []
        batch.reserveCapacity(limit)

        while batch.count < limit, !pendingDetailPrefetchItems.isEmpty {
            let item = pendingDetailPrefetchItems.removeFirst()
            pendingDetailPrefetchIDs.remove(item.id)
            if shouldPrefetchDetail(for: item) {
                batch.append(item)
            }
        }

        return batch
    }

    private func shouldPrefetchDetail(for item: MediaItem) -> Bool {
        guard item.posterURL == nil else { return false }
        let alreadyHasPlaybackDetail = !item.downloadOptions.isEmpty || item.previewVideoURL != nil
        if alreadyHasPlaybackDetail, item.posterURL != nil {
            return false
        }
        return detailTasks[item.id] == nil
    }

    private func cancelDetailPrefetchQueue() {
        detailPrefetchCoordinatorTask?.cancel()
        detailPrefetchCoordinatorTask = nil
        pendingDetailPrefetchItems.removeAll()
        pendingDetailPrefetchIDs.removeAll()
    }

    private func trimPendingDetailPrefetchQueue() {
        guard pendingDetailPrefetchItems.count > Self.maxPendingDetailPrefetchItems else { return }
        pendingDetailPrefetchItems = Array(pendingDetailPrefetchItems.prefix(Self.maxPendingDetailPrefetchItems))
        pendingDetailPrefetchIDs = Set(pendingDetailPrefetchItems.map(\.id))
    }

    private func enforceExploreItemLimit() {
        guard items.count > Self.maxCachedItems else { return }

        items = Array(items.suffix(Self.maxCachedItems))
        let retainedIDs = Set(items.map(\.id))

        pendingDetailPrefetchItems.removeAll { !retainedIDs.contains($0.id) }
        pendingDetailPrefetchIDs = Set(pendingDetailPrefetchItems.map(\.id))

        for id in Array(detailTasks.keys) where !retainedIDs.contains(id) {
            detailTasks[id]?.cancel()
            detailTasks[id] = nil
        }
    }

    // MARK: - 便捷加载方法

    /// 加载首页内容
    @MainActor
    func loadHomeFeed() async {
        print("[MediaExploreViewModel] loadHomeFeed called")
        currentQuery = ""
        await load(source: .home)
    }

    /// 重置 MotionBG 浏览状态并强制加载默认首页。
    @MainActor
    func resetAndLoadDefaultHomeFeed() async {
        invalidatePreservedExploreFeed()
        cancelPreload()
        cancelDetailPrefetchQueue()
        nextPagePath = nil
        currentQuery = ""
        currentSource = .home
        hasMorePages = true
        isLoading = false
        isLoadingMore = false
        errorMessage = nil
        await load(source: .home)
    }

    /// 独立刷新首页推荐数据（与 Explore 列表数据分离）
    @MainActor
    func refreshHomeItems() async {
        print("[MediaExploreViewModel] refreshHomeItems called")
        let source = workshopSourceManager.activeSource
        do {
            switch source {
            case .wallpaperEngine:
                let wallpaperType: WorkshopWallpaper.WallpaperType? = (workshopCurrentType == .all) ? nil : {
                    switch workshopCurrentType {
                    case .scene: return .scene
                    case .video: return .video
                    case .web: return .web
                    case .all: return nil
                    }
                }()
                let params = WorkshopSearchParams(
                    query: "",
                    sortBy: .ranked,
                    page: 1,
                    pageSize: 10,
                    tags: workshopCurrentTags,
                    type: wallpaperType,
                    contentLevel: workshopCurrentContentLevel?.rawValue
                )
                let response = try await workshopService.search(params: params)
                homeItems = workshopService.convertToMediaItems(response.items)
            case .dongtai:
                let params = DynamicWallpaperSearchParams(
                    query: "",
                    listType: .all,
                    sortBy: .popular,
                    page: 1,
                    pageSize: 10
                )
                let result = dynamicWallpaperService.queryItems(params: params)
                homeItems = result.items
            case .wallsflow:
                let page = try await wallsflowService.fetchCategory(slug: wallsflowCurrentCategorySlug, page: 1)
                homeItems = Array(page.items.prefix(10))
            default:
                let page = try await mediaService.fetchPage(source: .home)
                page.items.forEach { mediaLibrary.upsert($0) }
                homeItems = Array(page.items.prefix(10))
            }
            print("[MediaExploreViewModel] refreshHomeItems completed: \(homeItems.count) items")
        } catch {
            print("[MediaExploreViewModel] refreshHomeItems failed: \(error)")
        }
    }

    /// 加载指定标签的内容
    /// - Parameters:
    ///   - slug: 标签 slug
    ///   - title: 页面标题
    @MainActor
    func loadTagFeed(slug: String, title: String) async {
        print("[MediaExploreViewModel] loadTagFeed called: slug=\(slug)")
        currentQuery = ""

        let shouldProceed: Bool = {
            guard !isLoading else { return false }
            isLoading = true
            return true
        }()

        guard shouldProceed else {
            print("[MediaExploreViewModel] loadTagFeed: already loading, skipping")
            return
        }

        cancelPreload()
        // ⚠️ 不再清空 items，新数据到达前保持旧列表可见，
        // 防止 SwiftUI 全量销毁→重建视图树导致的 AttributeGraph 主线程卡死。

        defer { isLoading = false }
        errorMessage = nil

        do {
            let source = MediaRouteSource.tag(slug)
            let page = try await mediaService.fetchPage(source: source)
            currentSource = source
            currentTitle = page.sectionTitle.isEmpty ? title : page.sectionTitle
            // 源一致性检查：如果切换了源，丢弃这个过期结果
            guard workshopSourceManager.activeSource == .motionBG else { return }
            page.items.forEach { mediaLibrary.upsert($0) }
            items = page.items
            nextPagePath = page.nextPagePath
            hasMorePages = page.nextPagePath != nil
            if hasMorePages {
                triggerMotionBGPreload()
            }
            print("[MediaExploreViewModel] loadTagFeed completed: \(items.count) items")
        } catch {
            print("[MediaExploreViewModel] loadTagFeed failed: \(error)")
            errorMessage = error.localizedDescription
        }
    }

    /// 搜索内容
    /// - Parameter query: 搜索关键词
    func search(query: String) async {
        print("[MediaExploreViewModel] search called: query='\(query)'")
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            await loadHomeFeed()
            return
        }

        currentQuery = trimmedQuery

        let shouldProceed: Bool = {
            guard !isLoading else { return false }
            isLoading = true
            return true
        }()

        guard shouldProceed else {
            print("[MediaExploreViewModel] search: already loading, skipping")
            return
        }

        cancelPreload()
        // ⚠️ 不再清空 items，新数据到达前保持旧列表可见。

        defer { isLoading = false }
        errorMessage = nil

        do {
            let source = MediaRouteSource.search(trimmedQuery)
            let page = try await mediaService.fetchPage(source: source)
            currentSource = source
            currentTitle = page.sectionTitle.isEmpty ? trimmedQuery : page.sectionTitle
            // 源一致性检查：如果切换了源，丢弃这个过期结果
            guard workshopSourceManager.activeSource == .motionBG else { return }
            page.items.forEach { mediaLibrary.upsert($0) }
            items = page.items
            nextPagePath = page.nextPagePath
            hasMorePages = page.nextPagePath != nil
            if hasMorePages {
                triggerMotionBGPreload()
            }
            print("[MediaExploreViewModel] search completed: \(items.count) items")
        } catch {
            print("[MediaExploreViewModel] search failed: \(error)")
            errorMessage = error.localizedDescription
        }
    }

    func previewSearch(query: String, limit: Int = 8) async throws -> [MediaItem] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return [] }

        let page = try await mediaService.fetchPage(source: .search(trimmedQuery))
        page.items.forEach { mediaLibrary.upsert($0) }
        return Array(page.items.prefix(limit))
    }

    func loadDetail(for item: MediaItem) async throws -> MediaItem {
        if let runningTask = detailTasks[item.id] {
            return try await runningTask.value
        }

        if shouldHydrateWorkshopMetadata(for: item) {
            let workshopID = String(item.id.dropFirst("workshop_".count))
            let task = Task<MediaItem, Error> {
                let remoteItem = try await self.workshopService.resolveWorkshopItemByURL(
                    "https://steamcommunity.com/sharedfiles/filedetails/?id=\(workshopID)"
                )
                return remoteItem.preservingPersistedMetadata(from: item)
            }
            detailTasks[item.id] = task

            defer {
                detailTasks[item.id] = nil
            }

            let resolvedItem = try await task.value
            replaceItem(with: resolvedItem)
            mediaLibrary.upsert(resolvedItem)
            return resolvedItem
        }

        // Wallsflow：列表页已有 video/download 时仍可能缺 poster/标签，
        // 且绝不能走 MotionBG 的 mediaService.fetchDetail(slug:)。
        if WallsflowService.isWallsflowItem(item) {
            let alreadyHasPlaybackDetail = !item.downloadOptions.isEmpty || item.previewVideoURL != nil
            if alreadyHasPlaybackDetail, item.posterURL != nil {
                mediaLibrary.upsert(item)
                return item
            }

            let task = Task<MediaItem, Error> {
                let detail = try await self.wallsflowService.enrichListItem(item)
                return detail.preservingPersistedMetadata(from: item)
            }
            detailTasks[item.id] = task
            defer { detailTasks[item.id] = nil }

            let resolvedItem = try await task.value
            replaceItem(with: resolvedItem)
            mediaLibrary.upsert(resolvedItem)
            return resolvedItem
        }

        let alreadyHasPlaybackDetail = !item.downloadOptions.isEmpty || item.previewVideoURL != nil
        if alreadyHasPlaybackDetail, item.posterURL != nil {
            mediaLibrary.upsert(item)
            return item
        }

        let task = Task<MediaItem, Error> {
            try await self.mediaService.fetchDetail(slug: item.slug)
        }
        detailTasks[item.id] = task

        defer {
            detailTasks[item.id] = nil
        }

        let resolvedItem = try await task.value
        replaceItem(with: resolvedItem)
        mediaLibrary.upsert(resolvedItem)
        return resolvedItem
    }

    private func shouldHydrateWorkshopMetadata(for item: MediaItem) -> Bool {
        guard item.id.hasPrefix("workshop_") else { return false }

        let lacksAuthorIdentity = item.authorSteamID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty ?? true
        let normalizedAuthorName = item.authorName?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let lacksAuthorDisplayName = normalizedAuthorName.isEmpty
            || normalizedAuthorName.caseInsensitiveCompare("unknown") == .orderedSame
        let lacksAllWorkshopStats = item.subscriptionCount == nil
            && item.favoriteCount == nil
            && item.viewCount == nil
            && item.ratingScore == nil
            && item.fileSize == nil
        return lacksAuthorIdentity || lacksAuthorDisplayName || lacksAllWorkshopStats
    }

    func toggleFavorite(_ item: MediaItem) {
        mediaLibrary.toggleFavorite(item)
    }

    /// 刷新收藏和下载数据（删除操作后调用）
    func refreshLibraryContent() {
        libraryContentRevision &+= 1
    }

    func isFavorite(_ item: MediaItem) -> Bool {
        mediaLibrary.isFavorite(item)
    }

    func isDownloaded(_ item: MediaItem) -> Bool {
        mediaLibrary.isDownloaded(item)
    }

    func recordViewed(_ item: MediaItem) {
        mediaLibrary.recordViewed(item)
    }

    /// 是否与设置一致：下载后写入应用内媒体库（而非仅临时缓存）。与系统「下载」文件夹无关。
    /// 缓存值在 init 时读取，避免后台线程访问 UserDefaults.standard 触发 _CFXPreferences 递归崩溃。
    private let persistDownloadedMediaToAppLibrary: Bool

    func download(_ item: MediaItem, preferredOption: MediaDownloadOption? = nil) async throws {
        _ = try await downloadMedia(item, option: preferredOption)
    }

    // MARK: - 便捷方法（用于 MediaDetailSheet）

    /// 确保获取到详细数据（用于详情页）
    /// - Parameter item: 媒体项
    /// - Returns: 包含详细数据的媒体项
    func ensureDetail(for item: MediaItem) async -> MediaItem {
        // 如果已经有详细数据，直接返回
        if item.hasDetailPayload {
            return item
        }

        // 否则加载详情
        do {
            return try await loadDetail(for: item)
        } catch {
            errorMessage = error.localizedDescription
            return item
        }
    }

    /// 下载媒体文件
    /// - Parameters:
    ///   - item: 媒体项
    ///   - option: 下载选项
    /// - Returns: 下载后的本地文件 URL
    /// - Parameter folderID: 下载入库时一并写入的库文件夹归属（作者批量下载用）。
    ///   为 nil 时不改动已有 folderID；新建记录则落在根目录。
    func downloadMedia(_ item: MediaItem, option: MediaDownloadOption?, folderID: String? = nil) async throws -> URL {
        let saveToLibrary = persistDownloadedMediaToAppLibrary
            || MediaLibraryService.normalizedFolderID(folderID) != nil
        return try await PersistentDownloadQueueService.shared.enqueueMediaAndWait(
            item,
            option: option,
            saveToLibrary: saveToLibrary,
            folderID: folderID,
            using: self
        )
    }

    /// 只执行媒体文件下载；队列统一管理任务生命周期。
    func executeQueuedMediaDownload(
        _ item: MediaItem,
        option: MediaDownloadOption?,
        saveToLibrary: Bool,
        folderID: String?,
        taskID: String
    ) async throws -> URL {
        return try await ensureLocalVideoFile(
            for: item,
            preferredOption: option,
            saveToDownloads: saveToLibrary,
            taskID: taskID,
            folderID: folderID
        )
    }

    /// 只执行 Workshop 下载；SteamCMD 复用本地缓存会话，不接收密码或 Guard 码。
    func executeQueuedWorkshopDownload(
        _ item: MediaItem,
        folderID: String?,
        taskID: String
    ) async throws -> URL {
        guard item.id.hasPrefix("workshop_") else {
            throw WorkshopError.workshopNotSupported
        }

        let workshopID = String(item.id.dropFirst("workshop_".count))
        let localURL = try await workshopService.downloadWorkshopItem(
            workshopID: workshopID,
            progressHandler: { progress in
                Task { @MainActor in
                    DownloadTaskService.shared.updateProgress(id: taskID, progress: progress)
                }
            }
        )
        let normalizedURL = normalizeWorkshopDownloadLocation(localURL, workshopID: workshopID)
        mediaLibrary.recordDownload(item: item, localFileURL: normalizedURL, folderID: folderID)
        return normalizedURL
    }

    func applyDynamicWallpaper(
        _ item: MediaItem,
        muted: Bool,
        targetScreen: NSScreen? = nil,
        targetScreens: [NSScreen]? = nil,
        usesSharedVideoDecoder: Bool = false
    ) async throws {
        let resolvedTargetScreens = targetScreens ?? targetScreen.map { [$0] }
        SceneOfflineBakeService.cancelRealtimeCompanionBake(reason: "applyDynamicWallpaper")
        // Workshop 项：优先查找本地已下载的视频文件
        if item.id.hasPrefix("workshop_"),
           let localVideoURL = findLocalWorkshopVideo(for: item) {
            print("[MediaExploreViewModel] Using downloaded Workshop video: \(localVideoURL.path)")
            mediaLibrary.ensureDownloadRecord(item: item, localFileURL: localVideoURL)
            let posterURL = await VideoThumbnailCache.shared.lockScreenPosterURL(forLocalVideo: localVideoURL, fallbackPosterURL: nil)
            // 用户可见切换：首帧预热 + 短黑场交接，避免视频/跨类型切换露黑。
            try await videoWallpaperManager.applyVideoWallpaper(
                from: localVideoURL,
                posterURL: posterURL,
                muted: muted,
                targetScreens: resolvedTargetScreens,
                animatedTransition: true,
                usesSharedVideoDecoder: usesSharedVideoDecoder
            )
            return
        }

        // 本地媒体文件：直接使用本地文件路径
        if item.id.hasPrefix("local_") {
            let localURL = item.previewVideoURL ?? item.pageURL
            if localURL.isFileURL && FileManager.default.fileExists(atPath: localURL.path) {
                print("[MediaExploreViewModel] Using local media file: \(localURL.path)")
                mediaLibrary.ensureDownloadRecord(item: item, localFileURL: localURL)
                let posterURL = await VideoThumbnailCache.shared.lockScreenPosterURL(forLocalVideo: localURL, fallbackPosterURL: nil)
                try await videoWallpaperManager.applyVideoWallpaper(
                    from: localURL,
                    posterURL: posterURL,
                    muted: muted,
                    targetScreens: resolvedTargetScreens,
                    animatedTransition: true,
                    usesSharedVideoDecoder: usesSharedVideoDecoder
                )
                return
            }
        }

        // 网络媒体文件：下载后使用
        let localVideoURL = try await PersistentDownloadQueueService.shared.enqueueMediaAndWait(
            item,
            option: preferredWallpaperOption(for: item),
            saveToLibrary: true,
            folderID: nil,
            using: self
        )
        let posterURL = await VideoThumbnailCache.shared.lockScreenPosterURL(forLocalVideo: localVideoURL, fallbackPosterURL: nil)
        try await videoWallpaperManager.applyVideoWallpaper(
            from: localVideoURL,
            posterURL: posterURL,
            muted: muted,
            targetScreens: resolvedTargetScreens,
            animatedTransition: true,
            usesSharedVideoDecoder: usesSharedVideoDecoder
        )
    }

    /// Registers an already-local item before it is applied from the detail sheet.
    /// This covers Workshop folders that were downloaded by an earlier build or restored from disk.
    func ensureMediaIsInLibrary(_ item: MediaItem, localFileURL: URL) {
        guard localFileURL.isFileURL,
              FileManager.default.fileExists(atPath: localFileURL.path) else {
            return
        }
        mediaLibrary.ensureDownloadRecord(item: item, localFileURL: localFileURL)
    }

    /// Workshop 内容类型
    private enum WorkshopContentType {
        case video        // 纯视频类型，WaifuX 可直接播放
        case scene        // 场景/应用类型，需要 Wallpaper Engine CLI 渲染
        case web          // Web 类型，由 WKWebView daemon 渲染
        case unknown
    }

    /// 确定 Workshop 内容类型（通过 project.json 判断）
    private func determineWorkshopContentType(at contentDir: URL) -> WorkshopContentType {
        let projectURL = contentDir.appendingPathComponent("project.json")
        guard let data = try? Data(contentsOf: projectURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let typeString = json["type"] as? String else {
            return .unknown
        }
        let type = typeString.lowercased()
        if type == "video" {
            return .video
        } else if type == "scene" {
            return .scene
        } else if type == "web" {
            return .web
        }
        return .unknown
    }

    /// 递归查找目录中的视频文件。
    /// AVPlayer 对 h264/h265 (mp4/mov) 兼容性最好，vp9 (webm) 可能无法打开；
    /// Workshop 壁纸常同时自带预烘焙 mp4 + webm，优先 mp4/mov，webm 仅兜底。
    private func findVideoFile(in directory: URL) -> URL? {
        let preferredExts = ["mp4", "mov", "m4v"]
        if let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) {
            for case let fileURL as URL in enumerator where preferredExts.contains(fileURL.pathExtension.lowercased()) {
                return fileURL
            }
        }
        if let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) {
            for case let fileURL as URL in enumerator where fileURL.pathExtension.lowercased() == "webm" {
                return fileURL
            }
        }
        return nil
    }

    /// 查找 Workshop 项本地已下载的视频文件（仅返回 video 类型的内容）
    private func findLocalWorkshopVideo(for item: MediaItem) -> URL? {
        guard item.id.hasPrefix("workshop_") else { return nil }
        let workshopID = String(item.id.dropFirst("workshop_".count))
        let fm = FileManager.default
        let mediaFolder = downloadPathManager.mediaFolderURL

        let candidatePaths = [
            mediaFolder.appendingPathComponent("workshop_\(workshopID)/steamapps/workshop/content/431960/\(workshopID)"),
            mediaFolder.appendingPathComponent("workshop_\(workshopID)")
        ]

        for path in candidatePaths {
            guard fm.fileExists(atPath: path.path) else { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path.path, isDirectory: &isDir) else { continue }

            if isDir.boolValue {
                let resolved = WorkshopService.resolveWallpaperEngineProjectRoot(startingAt: path)
                let rootContents = try? fm.contentsOfDirectory(at: resolved, includingPropertiesForKeys: nil)
                let hasPkgFile = rootContents?.contains(where: { $0.pathExtension.lowercased() == "pkg" }) ?? false

                // 如果有 .pkg 文件，这是 scene 类型，跳过
                if hasPkgFile {
                    continue
                }

                // 先检查 project.json 确定内容类型
                let contentType = determineWorkshopContentType(at: resolved)
                if contentType == .scene || contentType == .web {
                    // scene / web 类型跳过（web 由 WKWebView daemon 渲染，
                    // 自带预烘焙视频不应走视频路径）
                    continue
                }

                // video 或 unknown 类型：查找视频文件
                if let videoURL = findVideoFile(in: resolved) {
                    return videoURL
                }
            } else if ["mp4", "mov", "webm"].contains(path.pathExtension.lowercased()) {
                return path
            }
        }

        // 回退到 MediaLibrary 记录
        if let record = mediaLibrary.downloadRecords.first(where: { $0.item.id == item.id && $0.isActive }),
           !record.localFilePath.isEmpty {
            let recordedPath = URL(fileURLWithPath: record.localFilePath)
            guard fm.fileExists(atPath: recordedPath.path) else { return nil }
            var isDir: ObjCBool = false
            fm.fileExists(atPath: recordedPath.path, isDirectory: &isDir)
            if isDir.boolValue {
                let resolved = WorkshopService.resolveWallpaperEngineProjectRoot(startingAt: recordedPath)
                let rootContents = try? fm.contentsOfDirectory(at: resolved, includingPropertiesForKeys: nil)
                let hasPkgFile = rootContents?.contains(where: { $0.pathExtension.lowercased() == "pkg" }) ?? false

                if hasPkgFile {
                    return nil
                }

                let contentType = determineWorkshopContentType(at: resolved)
                if contentType == .scene || contentType == .web {
                    // scene / web 类型不应走视频路径（web 由 daemon 渲染）
                    return nil
                }
                if let videoURL = findVideoFile(in: resolved) {
                    return videoURL
                }
            } else if ["mp4", "mov", "webm"].contains(recordedPath.pathExtension.lowercased()) {
                return recordedPath
            }
        }

        return nil
    }

    /// 查找 Workshop 项本地已下载的内容路径（用于 CLI 渲染）
    private func findLocalWorkshopContentPath(for item: MediaItem) -> URL? {
        guard item.id.hasPrefix("workshop_") else { return nil }
        let workshopID = String(item.id.dropFirst("workshop_".count))
        let fm = FileManager.default
        let mediaFolder = downloadPathManager.mediaFolderURL

        let candidatePaths = [
            mediaFolder.appendingPathComponent("workshop_\(workshopID)/steamapps/workshop/content/431960/\(workshopID)"),
            mediaFolder.appendingPathComponent("workshop_\(workshopID)")
        ]

        for path in candidatePaths {
            guard fm.fileExists(atPath: path.path) else { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path.path, isDirectory: &isDir) else { continue }

            if isDir.boolValue {
                let resolved = WorkshopService.resolveWallpaperEngineProjectRoot(startingAt: path)
                // 检查是否有 .pkg 文件
                if let contents = try? fm.contentsOfDirectory(at: resolved, includingPropertiesForKeys: nil) {
                    if contents.contains(where: { $0.pathExtension.lowercased() == "pkg" }) {
                        return resolved
                    }
                }
                // 检查是否有 project.json
                if fm.fileExists(atPath: resolved.appendingPathComponent("project.json").path) {
                    return resolved
                }
            } else if path.pathExtension.lowercased() == "pkg" {
                return path
            }
        }

        return nil
    }

    private func replaceItem(with updatedItem: MediaItem) {
        if let index = items.firstIndex(where: { $0.id == updatedItem.id }) {
            // 保留列表 thumbnailURL，避免回填详情后整卡因基础缩略图 URL 变化闪烁；
            // 但必须接纳详情页解析出的 posterURL，否则列表会一直停留在 364x205 小图。
            let original = items[index]
            items[index] = mergedListItem(original: original, detail: updatedItem)
        }

        guard let snapshot = preservedExploreFeedSnapshot,
              let snapshotIndex = snapshot.items.firstIndex(where: { $0.id == updatedItem.id }) else { return }

        var snapshotItems = snapshot.items
        snapshotItems[snapshotIndex] = mergedListItem(original: snapshotItems[snapshotIndex], detail: updatedItem)
        preservedExploreFeedSnapshot = ExploreFeedSnapshot(
            activeSource: snapshot.activeSource,
            items: snapshotItems,
            currentTitle: snapshot.currentTitle,
            currentQuery: snapshot.currentQuery,
            currentSource: snapshot.currentSource,
            nextPagePath: snapshot.nextPagePath,
            hasMorePages: snapshot.hasMorePages,
            preloadedPage: snapshot.preloadedPage,
            workshopCurrentPage: snapshot.workshopCurrentPage,
            workshopHasMore: snapshot.workshopHasMore,
            workshopSearchQuery: snapshot.workshopSearchQuery,
            workshopCurrentTags: snapshot.workshopCurrentTags,
            workshopCurrentType: snapshot.workshopCurrentType,
            workshopCurrentContentLevel: snapshot.workshopCurrentContentLevel,
            workshopCurrentResolution: snapshot.workshopCurrentResolution,
            workshopSortBy: snapshot.workshopSortBy,
            workshopDays: snapshot.workshopDays,
            dongtaiCurrentPage: snapshot.dongtaiCurrentPage,
            dongtaiHasMore: snapshot.dongtaiHasMore,
            dongtaiSearchQuery: snapshot.dongtaiSearchQuery,
            dongtaiCurrentCategories: snapshot.dongtaiCurrentCategories,
            dongtaiCurrentListType: snapshot.dongtaiCurrentListType,
            dongtaiSortBy: snapshot.dongtaiSortBy,
            dongtaiFilterAudio: snapshot.dongtaiFilterAudio,
            dongtaiFilterFourK: snapshot.dongtaiFilterFourK,
            wallsflowCurrentPage: snapshot.wallsflowCurrentPage,
            wallsflowHasMore: snapshot.wallsflowHasMore,
            wallsflowSearchQuery: snapshot.wallsflowSearchQuery,
            wallsflowCurrentCategorySlug: snapshot.wallsflowCurrentCategorySlug
        )
    }

    private func mergedListItem(original: MediaItem, detail updatedItem: MediaItem) -> MediaItem {
        let resolvedTitle = updatedItem.title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty ? original.title : updatedItem.title

        return MediaItem(
            slug: original.slug,
            title: resolvedTitle,
            pageURL: updatedItem.pageURL,
            thumbnailURL: original.thumbnailURL,
            resolutionLabel: original.resolutionLabel,
            collectionTitle: original.collectionTitle,
            summary: updatedItem.summary,
            previewVideoURL: updatedItem.previewVideoURL ?? original.previewVideoURL,
            posterURL: updatedItem.posterURL ?? original.posterURL,
            tags: original.tags,
            exactResolution: original.exactResolution,
            durationSeconds: updatedItem.durationSeconds,
            downloadOptions: updatedItem.downloadOptions,
            sourceName: original.sourceName,
            isAnimatedImage: updatedItem.isAnimatedImage,
            subscriptionCount: updatedItem.subscriptionCount,
            favoriteCount: updatedItem.favoriteCount,
            viewCount: updatedItem.viewCount,
            ratingScore: updatedItem.ratingScore,
            authorName: updatedItem.authorName ?? original.authorName,
            authorSteamID: updatedItem.authorSteamID ?? original.authorSteamID,
            authorAvatarURL: updatedItem.authorAvatarURL ?? original.authorAvatarURL,
            fileSize: updatedItem.fileSize,
            createdAt: updatedItem.createdAt,
            updatedAt: updatedItem.updatedAt
        )
    }

    private func preferredWallpaperOption(for item: MediaItem) -> MediaDownloadOption? {
        item.downloadOptions.max { lhs, rhs in
            if lhs.qualityRank == rhs.qualityRank {
                return lhs.fileSizeMegabytes < rhs.fileSizeMegabytes
            }
            return lhs.qualityRank < rhs.qualityRank
        }
    }

    private func ensureLocalVideoFile(
        for item: MediaItem,
        preferredOption: MediaDownloadOption?,
        saveToDownloads: Bool,
        taskID: String? = nil,
        folderID: String? = nil
    ) async throws -> URL {
        let resolvedItem = try await loadDetail(for: item)
        if let taskID {
            downloadTaskService.updateMediaItem(resolvedItem, id: taskID)
        }
        guard let downloadOption = preferredOption ?? resolvedItem.downloadOptions.max(by: {
            if $0.qualityRank == $1.qualityRank {
                return $0.fileSizeMegabytes < $1.fileSizeMegabytes
            }
            return $0.qualityRank < $1.qualityRank
        }) else {
            throw NetworkError.invalidResponse
        }

        let fileExtension = downloadOption.remoteURL.pathExtension.isEmpty ? "mp4" : downloadOption.remoteURL.pathExtension

        // 使用 DownloadPathManager 获取文件路径（包含路径检测）
        let fileLocation = downloadPathManager.locateMediaFile(
            slug: resolvedItem.slug,
            label: downloadOption.label,
            fileExtension: fileExtension
        )

        // 如果文件已存在（在新位置或旧位置），直接返回
        if fileLocation.foundIn != .notFound {
            // 历史坏下载：Wallsflow 无 Referer 时会把 HTML 当 mp4 落盘，需作废重下。
            if Self.localMediaFileLooksCorrupt(fileLocation.url) {
                print("[MediaExploreViewModel] Corrupt media file detected, re-downloading: \(fileLocation.url.path)")
                try? FileManager.default.removeItem(at: fileLocation.url)
                FileExistenceCache.shared.invalidate(atPath: fileLocation.url.path)
                // 同步清掉“已下载”假阳性记录，避免 UI 显示勾选但文件是 HTML
                if mediaLibrary.downloadRecord(for: resolvedItem.id) != nil {
                    mediaLibrary.removeDownloadRecord(withID: resolvedItem.id)
                }
            } else {
                print("[MediaExploreViewModel] File found at: \(fileLocation.url.path) (location: \(fileLocation.foundIn))")
                if let taskID {
                    updateDownloadProgress(taskID: taskID, progress: saveToDownloads ? 0.72 : 1.0)
                }

                if saveToDownloads {
                    mediaLibrary.ensureDownloadRecord(
                        item: resolvedItem,
                        localFileURL: fileLocation.url,
                        folderID: folderID
                    )
                    try? await cacheService.removeCachedFile(
                        named: fileLocation.url.lastPathComponent,
                        in: "Media"
                    )
                }

                return fileLocation.url
            }
        }

        // 文件不存在，需要下载
        let fileURL = fileLocation.url

        // 确保目录存在（先检查沙盒权限再创建目录）
        guard await downloadPathManager.ensureDirectoryStructure() else {
            throw DownloadError.permissionDenied
        }

        let cachedURL: URL?
        let downloadedData: Data?
        if let existingCachedURL = await cacheService.cachedFileURL(named: fileURL.lastPathComponent, in: "Media"),
           !Self.localMediaFileLooksCorrupt(existingCachedURL) {
            cachedURL = existingCachedURL
            downloadedData = nil
            if let taskID {
                updateDownloadProgress(taskID: taskID, progress: saveToDownloads ? 0.72 : 1.0)
            }
        } else {
            if let stale = await cacheService.cachedFileURL(named: fileURL.lastPathComponent, in: "Media") {
                try? FileManager.default.removeItem(at: stale)
                FileExistenceCache.shared.invalidate(atPath: stale.path)
            }
            // Wallsflow cloud CDN 无 Referer 会 302 成 HTML；且 Range 不可用，必须整文件 GET。
            let wallsflowHeaders = WallsflowService.mediaRequestHeaders(
                for: downloadOption.remoteURL,
                pageURL: resolvedItem.pageURL
            ) ?? [:]
            let data = try await networkService.fetchData(
                from: downloadOption.remoteURL,
                headers: wallsflowHeaders
            ) { progress in
                guard let taskID else { return }
                Task { @MainActor in
                    DownloadTaskService.shared.updateProgress(id: taskID, progress: min(progress * 0.86, 0.86))
                }
            }
            // 防御：若仍拿到 HTML（鉴权/跳转失败）或非媒体载荷，勿落盘污染缓存。
            if WallsflowService.isProtectedMediaURL(downloadOption.remoteURL) {
                if Self.looksLikeHTMLPayload(data)
                    || data.count < 64_000
                    || !Self.looksLikeISOBMFF(data) {
                    print("[MediaExploreViewModel] Rejected Wallsflow payload: size=\(data.count) html=\(Self.looksLikeHTMLPayload(data)) ftyp=\(Self.looksLikeISOBMFF(data))")
                    throw NetworkError.invalidResponse
                }
            } else if Self.looksLikeHTMLPayload(data) {
                throw NetworkError.invalidResponse
            }
            if saveToDownloads {
                cachedURL = nil
                downloadedData = data
            } else {
                cachedURL = try await cacheService.cacheFile(data, named: fileURL.lastPathComponent, in: "Media")
                downloadedData = nil
            }
            if let taskID {
                updateDownloadProgress(taskID: taskID, progress: saveToDownloads ? 0.9 : 1.0)
            }
        }

        if saveToDownloads {
            // 复制到应用内媒体库目录（含自定义根目录下的 WaifuX/Media）
            do {
                let directory = fileURL.deletingLastPathComponent()
                if !FileManager.default.fileExists(atPath: directory.path) {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    print("[MediaExploreViewModel] Created directory: \(directory.path)")
                }

                // 目标若仍是旧坏文件，必须覆盖，不能 early-return
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    let incomingSize = downloadedData.map { Int64($0.count) }
                        ?? ((try? FileManager.default.attributesOfItem(atPath: cachedURL?.path ?? "")[.size] as? NSNumber)?
                            .int64Value)
                    if Self.localMediaFileLooksCorrupt(fileURL)
                        || (incomingSize != nil
                            && (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?
                                .int64Value != incomingSize) {
                        try? FileManager.default.removeItem(at: fileURL)
                        FileExistenceCache.shared.invalidate(atPath: fileURL.path)
                    }
                }

                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    if let downloadedData {
                        try await downloadedData.writeAsync(to: fileURL, options: .atomic)
                    } else if let cachedURL {
                        let cachedData = try await cachedURL.readDataAsync()
                        try await cachedData.writeAsync(to: fileURL, options: .atomic)
                    } else {
                        throw DownloadError.writeFailed(NSError(
                            domain: "WaifuX",
                            code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "Missing media download source"]
                        ))
                    }
                }

                guard FileManager.default.fileExists(atPath: fileURL.path),
                      !Self.localMediaFileLooksCorrupt(fileURL) else {
                    try? FileManager.default.removeItem(at: fileURL)
                    FileExistenceCache.shared.invalidate(atPath: fileURL.path)
                    print("[MediaExploreViewModel] ❌ Library file missing or corrupt after write: \(fileURL.path)")
                    throw DownloadError.writeFailed(NSError(
                        domain: "WaifuX",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "File missing or corrupt after write"]
                    ))
                }
                print("[MediaExploreViewModel] ✅ File saved successfully: \(fileURL.path)")
            } catch let error as DownloadError {
                throw error
            } catch {
                print("[MediaExploreViewModel] ❌ Failed to write file to app media library: \(error)")
                throw DownloadError.writeFailed(error)
            }

            if let taskID {
                updateDownloadProgress(taskID: taskID, progress: 0.96)
            }
            // 作者批量下载把 folderID 和落盘登记绑在同一步
            mediaLibrary.recordDownload(
                item: resolvedItem,
                localFileURL: fileURL,
                folderID: folderID
            )
            if let cachedURL {
                await removeMediaCacheIfPresent(for: cachedURL)
            }
            return fileURL
        }

        guard let cachedURL else {
            throw DownloadError.writeFailed(NSError(
                domain: "WaifuX",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Missing cached media file"]
            ))
        }
        return cachedURL
    }

    /// 入库完成后，删除同一下载产生的临时中转文件。
    /// `saveToDownloads == false` 的普通下载仍保留 Cache 复用能力。
    private func removeMediaCacheIfPresent(for cachedURL: URL) async {
        try? await cacheService.removeCachedFile(at: cachedURL)
    }

    private func updateDownloadProgress(taskID: String, progress: Double) {
        downloadTaskService.updateProgress(id: taskID, progress: progress)
    }

    func retryDownload(task: DownloadTask) async throws {
        switch task.kind {
        case .media:
            guard task.mediaItem != nil else {
                throw NetworkError.invalidResponse
            }
            try await PersistentDownloadQueueService.shared.retryAndWait(task)

        case .workshop:
            guard task.workshopItem != nil || task.mediaItem != nil else {
                throw NetworkError.invalidResponse
            }
            try await PersistentDownloadQueueService.shared.retryAndWait(task)

        case .wallpaper:
            throw NetworkError.invalidResponse
        }
    }

    // MARK: - 批量删除

    /// 批量删除媒体收藏
    /// - Parameter ids: 要删除的项目 ID 集合
    func removeFavorites(withIDs ids: Set<String>) {
        mediaLibrary.removeFavoriteRecords(withIDs: ids)
    }

    /// 批量删除媒体下载记录
    /// - Parameter ids: 要删除的项目 ID 集合
    func removeDownloads(withIDs ids: Set<String>) {
        mediaLibrary.removeDownloadRecords(withIDs: ids)
    }

    /// 批量删除指定 ID 的项目
    /// - Parameter ids: 要删除的项目 ID 集合
    func removeItems(withIDs ids: Set<String>) {
        items.removeAll { ids.contains($0.id) }
    }

    /// 批量删除最近播放记录
    /// - Parameter ids: 要删除的项目 ID 集合
    func removeRecentItems(withIDs ids: Set<String>) {
        mediaLibrary.removeRecentItems(withIDs: ids)
    }

    /// 清空所有项目（用于数据源切换时）
    func clearItems() {
        cancelDetailPrefetchQueue()
        invalidatePreservedExploreFeed()
        items.removeAll()
        hasMorePages = true
    }

    // MARK: - 内存压力处理

    /// 系统内存压力时自动触发：释放可重建的预取/详情任务，不丢弃探索列表分页状态。
    /// Kingfisher / VideoThumbnailCache 等由 WaifuXApp 的 DispatchSource 统一清理。
    private func handleMemoryPressure() {
        print("[MediaExploreViewModel] 内存压力，释放缓存: items=\(items.count)")
        networkRecoveryTask?.cancel()
        cancelPreload()
        cancelDetailPrefetchQueue()
        detailTasks.values.forEach { $0.cancel() }
        detailTasks.removeAll()
    }

    /// 释放前台浏览态内存：取消前台任务并使本地库索引失效，持久化库数据与设置状态保持不变。
    func releaseForegroundMemory() {
        networkRecoveryTask?.cancel()
        sourceSwitchTask?.cancel()
        networkMonitorSetupTask?.cancel()
        networkRecoveryTask = nil
        sourceSwitchTask = nil
        networkMonitorSetupTask = nil
        cancelPreload()
        nextPagePath = nil
        cancelDetailPrefetchQueue()
        detailTasks.values.forEach { $0.cancel() }
        detailTasks.removeAll()

        items.removeAll()
        homeItems.removeAll()
        rebuildLocalMediaCacheTask?.cancel()
        rebuildLocalMediaCacheTask = nil
        localMediaCacheRebuildID = nil
        cachedAllLocalMedia.removeAll()
        localMediaCacheNeedsRestore = true
        errorMessage = nil
        isLoading = false
        isLoadingMore = false
        hasMorePages = true
        workshopHasMore = true
        workshopCurrentPage = 1
        dongtaiHasMore = true
        dongtaiCurrentPage = 1
        wallsflowHasMore = true
        wallsflowCurrentPage = 1
    }

    // MARK: - 统一调度（不感知具体源类型）

    /// 重置并加载当前源的默认 Feed。新增数据源只需在 `switch` 中添加分支。
    @MainActor
    func resetAndLoadDefaultFeed() async {
        switch workshopSourceManager.activeSource {
        case .wallpaperEngine: await resetAndLoadDefaultWorkshopFeed()
        case .dongtai:         await resetAndLoadDefaultDongTaiFeed()
        case .wallsflow:       await resetAndLoadDefaultWallsflowFeed()
        default:               await resetAndLoadDefaultHomeFeed()
        }
    }

    /// 加载更多当前源的数据。新增数据源只需在 `switch` 中添加分支。
    func loadMoreFeed() async {
        switch workshopSourceManager.activeSource {
        case .wallpaperEngine: await loadMoreWorkshop()
        case .dongtai:         await loadMoreDongTai()
        case .wallsflow:       await loadMoreWallsflow()
        default:               await loadMore()
        }
    }

    /// 搜索当前源。新增数据源只需在 `switch` 中添加分支。
    func searchFeed(query: String) async {
        switch workshopSourceManager.activeSource {
        case .wallpaperEngine: await searchWorkshop(query: query)
        case .dongtai:         await searchDongTai(query: query)
        case .wallsflow:       await searchWallsflow(query: query)
        default:               await search(query: query)
        }
    }

    // MARK: - Workshop 数据加载

    /// 检查当前是否使用 Workshop 数据源
    var isUsingWorkshop: Bool {
        workshopSourceManager.activeSource == .wallpaperEngine
    }

    /// 加载 Workshop 首页/搜索内容（沿用当前类型 / 标签 / 内容级别，默认含 SFW）
    func loadWorkshopFeed() async {
        await loadWorkshopFeedInternal(
            query: workshopSearchQuery,
            tags: workshopCurrentTags,
            type: workshopCurrentType,
            contentLevel: workshopCurrentContentLevel,
            resolution: workshopCurrentResolution
        )
    }

    /// 重置 Workshop 浏览状态并加载列表（保留用户持久化的排序）。
    @MainActor
    func resetAndLoadDefaultWorkshopFeed() async {
        invalidatePreservedExploreFeed()
        workshopSearchQuery = ""
        currentQuery = ""
        workshopCurrentTags = []
        workshopCurrentType = .all
        workshopCurrentContentLevel = .everyone
        workshopCurrentResolution = nil
        // 保留用户持久化过的排序，不强制回默认 trend_7
        workshopCurrentPage = 1
        workshopHasMore = true
        hasMorePages = true
        isLoading = false
        isLoadingMore = false
        errorMessage = nil
        await loadWorkshopFeedInternal(
            query: "",
            tags: [],
            type: .all,
            contentLevel: .everyone,
            resolution: nil
        )
    }

    /// Workshop 搜索（与 Explore 搜索栏提交一致：清空标签/类型并回到默认 SFW）
    func searchWorkshop(query: String) async {
        invalidatePreservedExploreFeed()
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        workshopSearchQuery = trimmedQuery
        currentQuery = trimmedQuery
        workshopCurrentTags = []
        workshopCurrentType = .all
        workshopCurrentContentLevel = .everyone

        await loadWorkshopFeedInternal(
            query: trimmedQuery,
            tags: [],
            type: .all,
            contentLevel: .everyone,
            resolution: nil
        )
    }

    /// 按标签筛选 Workshop 内容
    func loadWorkshopWithTags(_ tags: [String]) async {
        invalidatePreservedExploreFeed()
        workshopCurrentTags = tags
        await loadWorkshopFeedInternal(query: "", tags: tags, resolution: workshopCurrentResolution)
    }

    /// 带完整筛选条件加载 Workshop 内容
    func loadWorkshopWithFilters(
        query: String = "",
        tags: [String] = [],
        type: WorkshopSourceManager.WorkshopTypeFilter = .all,
        contentLevel: WorkshopSourceManager.WorkshopContentLevel? = nil,
        resolution: String? = nil
    ) async {
        invalidatePreservedExploreFeed()
        workshopSearchQuery = query
        workshopCurrentTags = tags
        workshopCurrentType = type
        workshopCurrentContentLevel = contentLevel
        workshopCurrentResolution = resolution
        await loadWorkshopFeedInternal(query: query, tags: tags, type: type, contentLevel: contentLevel, resolution: resolution)
    }

    /// 设置 Workshop 排序方式
    /// - Parameter menuRawValue: UI 菜单项 rawValue（如 `trend_7`），用于跨启动恢复细分趋势
    func setWorkshopSort(
        sortBy: WorkshopSearchParams.SortOption,
        days: Int? = nil,
        menuRawValue: String? = nil
    ) async {
        invalidatePreservedExploreFeed()
        workshopSortBy = sortBy
        workshopDays = days
        if let menuRawValue {
            workshopSortMenuRawValue = menuRawValue
            UserDefaults.standard.set(menuRawValue, forKey: Self.workshopSortMenuDefaultsKey)
        }
        await loadWorkshopFeedInternal(
            query: workshopSearchQuery,
            tags: workshopCurrentTags,
            type: workshopCurrentType,
            contentLevel: workshopCurrentContentLevel,
            resolution: workshopCurrentResolution
        )
    }

    /// 从 UserDefaults 恢复媒体探索排序；仅在用户曾选择过时覆盖默认值。
    /// 必须在 applicationDidFinishLaunching 之后调用，不可在 init 中调用。
    func restoreExploreSortPreferences() {
        guard !hasRestoredExploreSort else { return }
        hasRestoredExploreSort = true

        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: Self.workshopSortMenuDefaultsKey) {
            applyWorkshopSortMenuRawValue(raw)
        }
        if let raw = defaults.string(forKey: Self.dongtaiSortDefaultsKey),
           let option = DynamicWallpaperSortOption(rawValue: raw) {
            dongtaiSortBy = option
        }
    }

    /// 将 Workshop 排序菜单 rawValue 映射到 API 参数（与 MediaExploreContentView.WorkshopSortOption 对齐）
    private func applyWorkshopSortMenuRawValue(_ raw: String) {
        workshopSortMenuRawValue = raw
        switch raw {
        case "trend_1":
            workshopSortBy = .ranked
            workshopDays = 1
        case "trend_7":
            workshopSortBy = .ranked
            workshopDays = 7
        case "trend_30":
            workshopSortBy = .ranked
            workshopDays = 30
        case "trend_90":
            workshopSortBy = .ranked
            workshopDays = 90
        case "trend_365":
            workshopSortBy = .ranked
            workshopDays = 365
        case "trend":
            workshopSortBy = .ranked
            workshopDays = nil
        case "updated":
            workshopSortBy = .updated
            workshopDays = nil
        case "created":
            workshopSortBy = .created
            workshopDays = nil
        case "toprated":
            workshopSortBy = .topRated
            workshopDays = nil
        default:
            workshopSortBy = .ranked
            workshopDays = 7
            workshopSortMenuRawValue = "trend_7"
        }
    }

    /// 内部方法：加载 Workshop 数据
    private func workshopWallpaperType(
        for type: WorkshopSourceManager.WorkshopTypeFilter
    ) -> WorkshopWallpaper.WallpaperType? {
        guard type != .all else { return nil }
        switch type {
        case .scene: return .scene
        case .video: return .video
        case .web: return .web
        case .all: return nil
        }
    }

    private func workshopSearchParams(page: Int) -> WorkshopSearchParams {
        WorkshopSearchParams(
            query: workshopSearchQuery,
            sortBy: workshopSortBy,
            page: page,
            pageSize: 20,
            tags: workshopCurrentTags,
            type: workshopWallpaperType(for: workshopCurrentType),
            contentLevel: workshopCurrentContentLevel?.rawValue,
            resolution: workshopCurrentResolution,
            days: workshopDays
        )
    }

    private func loadWorkshopFeedInternal(
        query: String,
        tags: [String],
        type: WorkshopSourceManager.WorkshopTypeFilter = .all,
        contentLevel: WorkshopSourceManager.WorkshopContentLevel? = nil,
        resolution: String? = nil
    ) async {
        guard !isLoading else { return }

        cancelPreload()
        isLoading = true
        errorMessage = nil

        // ⚠️ 不再清空 items，新数据到达前保持旧列表可见。

        defer { isLoading = false }

        // 重置分页状态
        workshopCurrentPage = 1
        workshopHasMore = true

        let wallpaperType: WorkshopWallpaper.WallpaperType? = (type == .all) ? nil : {
            switch type {
            case .scene: return .scene
            case .video: return .video
            case .web: return .web
            case .all: return nil
            }
        }()

        let resolvedContentLevel = contentLevel ?? workshopCurrentContentLevel
        let resolvedResolution = resolution ?? workshopCurrentResolution

        let params = WorkshopSearchParams(
            query: query,
            sortBy: workshopSortBy,
            page: 1,
            pageSize: 20,
            tags: tags,
            type: wallpaperType,
            contentLevel: resolvedContentLevel?.rawValue,
            resolution: resolvedResolution,
            days: workshopDays
        )

        do {
            let response = try await workshopService.search(params: params)
            let mediaItems = workshopService.convertToMediaItems(response.items)
            // 源一致性检查：如果切换了源，丢弃这个过期结果
            guard workshopSourceManager.activeSource == .wallpaperEngine else { return }
            items = mediaItems
            workshopHasMore = response.hasMore
            hasMorePages = response.hasMore
            currentTitle = query.isEmpty ? "Workshop" : "搜索: \(query)"
            if workshopHasMore {
                triggerWorkshopPreload()
            }
            print("[MediaExploreViewModel] loadWorkshopFeedInternal completed: \(items.count) items, sort=\(workshopSortBy.rawValue), days=\(workshopDays.map(String.init) ?? "all")")
        } catch {
            errorMessage = error.localizedDescription
            print("[MediaExploreViewModel] loadWorkshopFeedInternal failed: \(error)")
        }
    }

    /// Workshop 加载更多
    func loadMoreWorkshop() async {
        guard !isLoading, !isLoadingMore, workshopHasMore else { return }

        isLoadingMore = true
        errorMessage = nil

        defer { isLoadingMore = false }

        let nextPage = workshopCurrentPage + 1

        do {
            // 先等待正在进行的下一页预取，避免触底时重复请求同一页。
            if let preloadTask {
                await preloadTask.value
            }

            let mediaItems: [MediaItem]
            let pageHasMore: Bool
            if case let .workshop(page, cachedItems, cachedHasMore) = preloadedPage,
               page == nextPage {
                mediaItems = cachedItems
                pageHasMore = cachedHasMore
                preloadedPage = nil
                print("[MediaExploreViewModel] Using preloaded Workshop page \(nextPage)")
            } else {
                let response = try await workshopService.search(
                    params: workshopSearchParams(page: nextPage)
                )
                mediaItems = workshopService.convertToMediaItems(response.items)
                pageHasMore = response.hasMore
            }

            // 源一致性检查：如果切换了源，丢弃这个过期结果
            guard workshopSourceManager.activeSource == .wallpaperEngine else { return }

            let existingIDs = Set(items.map(\.id))
            let newItems = mediaItems.filter { !existingIDs.contains($0.id) }
            items.append(contentsOf: newItems)

            workshopCurrentPage = nextPage
            workshopHasMore = pageHasMore
            hasMorePages = pageHasMore
            if workshopHasMore {
                triggerWorkshopPreload()
            }
            print("[MediaExploreViewModel] loadMoreWorkshop completed: +\(newItems.count) items, total: \(items.count)")
        } catch {
            errorMessage = error.localizedDescription
            print("[MediaExploreViewModel] loadMoreWorkshop failed: \(error)")
        }
    }

    private func triggerWorkshopPreload() {
        guard workshopHasMore else {
            cancelPreload()
            return
        }

        let nextPage = workshopCurrentPage + 1
        let params = workshopSearchParams(page: nextPage)
        let generation = beginPreload()

        preloadTask = Task(priority: .low) { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self, !Task.isCancelled else { return }

            do {
                let response = try await self.workshopService.search(params: params)
                let mediaItems = self.workshopService.convertToMediaItems(response.items)
                guard !Task.isCancelled,
                      self.preloadGeneration == generation,
                      self.workshopSourceManager.activeSource == .wallpaperEngine,
                      self.workshopCurrentPage + 1 == nextPage else { return }
                self.preloadedPage = .workshop(
                    page: nextPage,
                    items: mediaItems,
                    hasMore: response.hasMore
                )
                print("[MediaExploreViewModel] Preloaded Workshop page \(nextPage)")
            } catch {
                print("[MediaExploreViewModel] Workshop preload failed: \(error)")
            }
        }
    }

    // MARK: - Dynamic Wallpaper (DongTai) 数据加载

    /// ✅ O(1) 收藏 ID 集合，供视图在 ForEach 中直接读取。
    var favoriteIDSet: Set<String> {
        Set(mediaLibrary.favoriteItems.map(\.id))
    }

    /// 检查当前是否使用 DongTai 数据源
    var isUsingDongTai: Bool {
        workshopSourceManager.activeSource == .dongtai
    }

    /// 加载 DongTai 首页/搜索内容
    func loadDongTaiFeed() async {
        await loadDongTaiFeedInternal(
            query: dongtaiSearchQuery,
            categories: dongtaiCurrentCategories,
            listType: dongtaiCurrentListType,
            sortBy: dongtaiSortBy,
            hasAudio: dongtaiFilterAudio,
            isFourK: dongtaiFilterFourK
        )
    }

    /// 重置 DongTai 浏览状态并强制加载默认列表
    @MainActor
    func resetAndLoadDefaultDongTaiFeed() async {
        invalidatePreservedExploreFeed()
        dongtaiSearchQuery = ""
        currentQuery = ""
        dongtaiCurrentCategories = []
        dongtaiCurrentListType = .all
        // 保留用户持久化过的排序，不强制回默认 popular
        dongtaiFilterAudio = nil
        dongtaiFilterFourK = nil
        dongtaiCurrentPage = 1
        dongtaiHasMore = true
        hasMorePages = true
        isLoading = false
        isLoadingMore = false
        errorMessage = nil

        // 确保数据已加载
        if !dynamicWallpaperService.isDataReady {
            _ = await dynamicWallpaperService.loadData()
        }

        await loadDongTaiFeedInternal(
            query: "",
            categories: [],
            listType: .all,
            sortBy: dongtaiSortBy,
            hasAudio: nil,
            isFourK: nil
        )
    }

    /// DongTai 搜索
    func searchDongTai(query: String) async {
        invalidatePreservedExploreFeed()
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        dongtaiSearchQuery = trimmedQuery
        currentQuery = trimmedQuery
        dongtaiCurrentCategories = []
        dongtaiCurrentListType = .all

        await loadDongTaiFeedInternal(
            query: trimmedQuery,
            categories: [],
            listType: .all,
            sortBy: dongtaiSortBy,
            hasAudio: dongtaiFilterAudio,
            isFourK: dongtaiFilterFourK
        )
    }

    /// 按分类筛选 DongTai 内容
    func loadDongTaiWithCategories(_ categories: Set<DynamicWallpaperCategory>) async {
        invalidatePreservedExploreFeed()
        dongtaiCurrentCategories = categories
        await loadDongTaiFeedInternal(
            query: dongtaiSearchQuery,
            categories: categories,
            listType: dongtaiCurrentListType,
            sortBy: dongtaiSortBy,
            hasAudio: dongtaiFilterAudio,
            isFourK: dongtaiFilterFourK
        )
    }

    /// 按列表类型筛选
    func loadDongTaiWithListType(_ listType: DynamicWallpaperListType) async {
        invalidatePreservedExploreFeed()
        dongtaiCurrentListType = listType
        await loadDongTaiFeedInternal(
            query: dongtaiSearchQuery,
            categories: dongtaiCurrentCategories,
            listType: listType,
            sortBy: dongtaiSortBy,
            hasAudio: dongtaiFilterAudio,
            isFourK: dongtaiFilterFourK
        )
    }

    /// 设置 DongTai 排序方式
    func setDongTaiSort(sortBy: DynamicWallpaperSortOption) async {
        invalidatePreservedExploreFeed()
        dongtaiSortBy = sortBy
        UserDefaults.standard.set(sortBy.rawValue, forKey: Self.dongtaiSortDefaultsKey)
        await loadDongTaiFeedInternal(
            query: dongtaiSearchQuery,
            categories: dongtaiCurrentCategories,
            listType: dongtaiCurrentListType,
            sortBy: sortBy,
            hasAudio: dongtaiFilterAudio,
            isFourK: dongtaiFilterFourK
        )
    }

    /// 以全部筛选条件加载 DongTai 数据（UI 层统一入口）
    func loadDongTaiWithAllFilters(
        query: String,
        categories: Set<DynamicWallpaperCategory>,
        listType: DynamicWallpaperListType,
        sortBy: DynamicWallpaperSortOption,
        hasAudio: Bool?,
        isFourK: Bool?
    ) async {
        invalidatePreservedExploreFeed()
        dongtaiSearchQuery = query
        currentQuery = query
        dongtaiCurrentCategories = categories
        dongtaiCurrentListType = listType
        dongtaiSortBy = sortBy
        dongtaiFilterAudio = hasAudio
        dongtaiFilterFourK = isFourK

        await loadDongTaiFeedInternal(
            query: query,
            categories: categories,
            listType: listType,
            sortBy: sortBy,
            hasAudio: hasAudio,
            isFourK: isFourK
        )
    }

    /// 设置 DongTai 筛选（音频/4K）
    func setDongTaiFilters(hasAudio: Bool? = nil, isFourK: Bool? = nil) async {
        invalidatePreservedExploreFeed()
        dongtaiFilterAudio = hasAudio
        dongtaiFilterFourK = isFourK
        await loadDongTaiFeedInternal(
            query: dongtaiSearchQuery,
            categories: dongtaiCurrentCategories,
            listType: dongtaiCurrentListType,
            sortBy: dongtaiSortBy,
            hasAudio: hasAudio,
            isFourK: isFourK
        )
    }

    /// 内部方法：加载 DongTai 数据
    private func dongtaiSearchParams(page: Int) -> DynamicWallpaperSearchParams {
        DynamicWallpaperSearchParams(
            query: dongtaiSearchQuery,
            listType: dongtaiCurrentListType,
            categories: dongtaiCurrentCategories,
            sortBy: dongtaiSortBy,
            page: page,
            pageSize: 20,
            hasAudio: dongtaiFilterAudio,
            isFourK: dongtaiFilterFourK
        )
    }

    private func loadDongTaiFeedInternal(
        query: String,
        categories: Set<DynamicWallpaperCategory>,
        listType: DynamicWallpaperListType = .all,
        sortBy: DynamicWallpaperSortOption = .popular,
        hasAudio: Bool? = nil,
        isFourK: Bool? = nil
    ) async {
        guard !isLoading else { return }

        // 确保数据已加载
        if !dynamicWallpaperService.isDataReady {
            let loaded = await dynamicWallpaperService.loadData()
            guard loaded else {
                errorMessage = dynamicWallpaperService.errorMessage ?? "动态桌面数据加载失败"
                return
            }
        }

        cancelPreload()
        let generation = dongtaiLoadGeneration &+ 1
        dongtaiLoadGeneration = generation

        isLoading = true
        errorMessage = nil
        // ⚠️ 不再清空 items，新数据到达前保持旧列表可见。

        defer {
            // 只有当前世代（未被更新的请求覆盖）才清除加载状态
            if dongtaiLoadGeneration == generation {
                isLoading = false
            }
        }

        // 重置分页状态
        dongtaiCurrentPage = 1
        dongtaiHasMore = true

        let params = DynamicWallpaperSearchParams(
            query: query,
            listType: listType,
            categories: categories,
            sortBy: sortBy,
            page: 1,
            pageSize: 20,
            hasAudio: hasAudio,
            isFourK: isFourK
        )

        let result = dynamicWallpaperService.queryItems(params: params)

        // 丢弃旧世代的结果（被取消/过期的请求）
        guard dongtaiLoadGeneration == generation else { return }
        // 源一致性检查：如果切换了源，丢弃这个过期结果
        guard workshopSourceManager.activeSource == .dongtai else { return }

        items = result.items
        dongtaiHasMore = result.hasMore
        hasMorePages = result.hasMore
        currentTitle = query.isEmpty ? t("dongtai") : "搜索: \(query)"
        if dongtaiHasMore {
            triggerDongTaiPreload()
        }
        print("[MediaExploreViewModel] loadDongTaiFeedInternal completed: \(items.count) items, total=\(result.totalCount)")
    }

    /// DongTai 加载更多
    func loadMoreDongTai() async {
        guard !isLoading, !isLoadingMore, dongtaiHasMore else { return }

        isLoadingMore = true
        errorMessage = nil

        defer { isLoadingMore = false }

        let nextPage = dongtaiCurrentPage + 1
        if let preloadTask {
            await preloadTask.value
        }

        let pageItems: [MediaItem]
        let pageHasMore: Bool
        if case let .dongtai(page, cachedItems, cachedHasMore) = preloadedPage,
           page == nextPage {
            pageItems = cachedItems
            pageHasMore = cachedHasMore
            preloadedPage = nil
            print("[MediaExploreViewModel] Using preloaded DongTai page \(nextPage)")
        } else {
            let result = dynamicWallpaperService.queryItems(params: dongtaiSearchParams(page: nextPage))
            pageItems = result.items
            pageHasMore = result.hasMore
        }

        // 源一致性检查：如果切换了源，丢弃这个过期结果
        guard workshopSourceManager.activeSource == .dongtai else { return }

        let existingIDs = Set(items.map(\.id))
        let newItems = pageItems.filter { !existingIDs.contains($0.id) }
        items.append(contentsOf: newItems)

        dongtaiCurrentPage = nextPage
        dongtaiHasMore = pageHasMore
        hasMorePages = pageHasMore
        if dongtaiHasMore {
            triggerDongTaiPreload()
        }
        print("[MediaExploreViewModel] loadMoreDongTai completed: +\(newItems.count) items, total: \(items.count)")
    }

    private func triggerDongTaiPreload() {
        guard dongtaiHasMore else {
            cancelPreload()
            return
        }

        let nextPage = dongtaiCurrentPage + 1
        let params = dongtaiSearchParams(page: nextPage)
        let generation = beginPreload()

        preloadTask = Task(priority: .low) { [weak self] in
            // 给当前页的可见 Cell 一个 run loop，避免首屏刚出现就立刻做本地排序。
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, !Task.isCancelled else { return }

            let result = self.dynamicWallpaperService.queryItems(params: params)
            guard !Task.isCancelled,
                  self.preloadGeneration == generation,
                  self.workshopSourceManager.activeSource == .dongtai,
                  self.dongtaiCurrentPage + 1 == nextPage else { return }
            self.preloadedPage = .dongtai(
                page: nextPage,
                items: result.items,
                hasMore: result.hasMore
            )
            print("[MediaExploreViewModel] Preloaded DongTai page \(nextPage)")
        }
    }

    // MARK: - Wallsflow 数据加载

    /// 检查当前是否使用 Wallsflow 数据源
    var isUsingWallsflow: Bool {
        workshopSourceManager.activeSource == .wallsflow
    }

    /// 加载 Wallsflow 首页/分类内容
    func loadWallsflowFeed() async {
        await loadWallsflowFeedInternal(
            query: wallsflowSearchQuery,
            categorySlug: wallsflowCurrentCategorySlug
        )
    }

    /// 重置 Wallsflow 浏览状态并强制加载默认首页
    @MainActor
    func resetAndLoadDefaultWallsflowFeed() async {
        invalidatePreservedExploreFeed()
        wallsflowSearchQuery = ""
        currentQuery = ""
        wallsflowCurrentCategorySlug = "live-wallpapers"
        wallsflowCurrentPage = 1
        wallsflowHasMore = true
        hasMorePages = true
        isLoading = false
        isLoadingMore = false
        errorMessage = nil
        await loadWallsflowFeedInternal(query: "", categorySlug: "live-wallpapers")
    }

    /// Wallsflow 搜索
    func searchWallsflow(query: String) async {
        invalidatePreservedExploreFeed()
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        wallsflowSearchQuery = trimmedQuery
        currentQuery = trimmedQuery
        wallsflowCurrentCategorySlug = "live-wallpapers"

        await loadWallsflowFeedInternal(query: trimmedQuery, categorySlug: nil)
    }

    /// 按分类浏览 Wallsflow
    func loadWallsflowCategory(slug: String) async {
        invalidatePreservedExploreFeed()
        wallsflowCurrentCategorySlug = slug
        await loadWallsflowFeedInternal(query: "", categorySlug: slug)
    }

    /// 内部方法：加载 Wallsflow 数据
    private func fetchWallsflowPage(_ page: Int) async throws -> WallsflowListPage {
        if !wallsflowSearchQuery.isEmpty {
            return try await wallsflowService.search(query: wallsflowSearchQuery, page: page)
        }
        return try await wallsflowService.fetchCategory(slug: wallsflowCurrentCategorySlug, page: page)
    }

    private func loadWallsflowFeedInternal(query: String?, categorySlug: String?) async {
        guard !isLoading else { return }

        cancelPreload()
        isLoading = true
        errorMessage = nil
        // ⚠️ 不再清空 items，新数据到达前保持旧列表可见。

        defer { isLoading = false }

        // 重置分页状态
        wallsflowCurrentPage = 1
        wallsflowHasMore = true

        do {
            let page: WallsflowListPage

            if let query = query, !query.isEmpty {
                // 搜索模式
                page = try await wallsflowService.search(query: query, page: 1)
                currentTitle = "搜索: \(query)"
            } else if let slug = categorySlug {
                // 分类模式
                page = try await wallsflowService.fetchCategory(slug: slug, page: 1)
                let categoryName = WallsflowCategory.allCategories.first(where: { $0.slug == slug })?.name ?? slug
                currentTitle = categoryName
            } else {
                // 默认首页
                page = try await wallsflowService.fetchCategory(slug: wallsflowCurrentCategorySlug, page: 1)
                currentTitle = "Wallsflow"
            }

            // 源一致性检查：如果切换了源，丢弃这个过期结果
            guard workshopSourceManager.activeSource == .wallsflow else { return }
            items = page.items
            wallsflowHasMore = page.nextPagePath != nil
            hasMorePages = page.nextPagePath != nil
            if wallsflowHasMore {
                triggerWallsflowPreload()
            }
            print("[MediaExploreViewModel] loadWallsflowFeedInternal completed: \(items.count) items")
        } catch {
            errorMessage = error.localizedDescription
            print("[MediaExploreViewModel] loadWallsflowFeedInternal failed: \(error)")
        }
    }

    /// Wallsflow 加载更多
    func loadMoreWallsflow() async {
        guard !isLoading, !isLoadingMore, wallsflowHasMore else { return }

        isLoadingMore = true
        errorMessage = nil

        defer { isLoadingMore = false }

        let nextPage = wallsflowCurrentPage + 1

        do {
            if let preloadTask {
                await preloadTask.value
            }

            let pageItems: [MediaItem]
            let pageNextPath: String?
            if case let .wallsflow(page, cachedItems, cachedNextPath) = preloadedPage,
               page == nextPage {
                pageItems = cachedItems
                pageNextPath = cachedNextPath
                preloadedPage = nil
                print("[MediaExploreViewModel] Using preloaded Wallsflow page \(nextPage)")
            } else {
                let page = try await fetchWallsflowPage(nextPage)
                pageItems = page.items
                pageNextPath = page.nextPagePath
            }

            // 源一致性检查：如果切换了源，丢弃这个过期结果
            guard workshopSourceManager.activeSource == .wallsflow else { return }

            let existingIDs = Set(items.map(\.id))
            let newItems = pageItems.filter { !existingIDs.contains($0.id) }
            items.append(contentsOf: newItems)

            wallsflowCurrentPage = nextPage
            wallsflowHasMore = pageNextPath != nil
            hasMorePages = pageNextPath != nil
            if wallsflowHasMore {
                triggerWallsflowPreload()
            }
            print("[MediaExploreViewModel] loadMoreWallsflow completed: +\(newItems.count) items, total: \(items.count)")
        } catch {
            errorMessage = error.localizedDescription
            print("[MediaExploreViewModel] loadMoreWallsflow failed: \(error)")
        }
    }

    private func triggerWallsflowPreload() {
        guard wallsflowHasMore else {
            cancelPreload()
            return
        }

        let nextPage = wallsflowCurrentPage + 1
        let generation = beginPreload()

        preloadTask = Task(priority: .low) { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self, !Task.isCancelled else { return }

            do {
                let page = try await self.fetchWallsflowPage(nextPage)
                guard !Task.isCancelled,
                      self.preloadGeneration == generation,
                      self.workshopSourceManager.activeSource == .wallsflow,
                      self.wallsflowCurrentPage + 1 == nextPage else { return }
                self.preloadedPage = .wallsflow(
                    page: nextPage,
                    items: page.items,
                    nextPagePath: page.nextPagePath
                )
                print("[MediaExploreViewModel] Preloaded Wallsflow page \(nextPage)")
            } catch {
                print("[MediaExploreViewModel] Wallsflow preload failed: \(error)")
            }
        }
    }

    // MARK: - 按作者获取 Workshop 物品

    /// 作者媒体分页结果。hasMore 不依赖固定 30 条假设（Steam 可能忽略 numperpage）。
    struct AuthorMediaPageResult {
        let items: [MediaItem]
        let hasMore: Bool
    }

    /// 获取指定作者的所有 Workshop 壁纸
    /// - Parameters:
    ///   - steamID: Steam 64位数字 ID
    ///   - page: 页码
    /// - Returns: 本页媒体 + 是否还有下一页
    func fetchMediaByAuthor(steamID: String, page: Int = 1) async throws -> AuthorMediaPageResult {
        let wallpapers = try await workshopService.fetchByAuthor(steamID: steamID, page: page)
        let mediaItems = workshopService.convertToMediaItems(wallpapers)

        // 缓存到本地库
        for item in mediaItems {
            mediaLibrary.upsert(item)
        }

        // 作者页实测可按 numperpage=30 翻页；满页继续，未满/空页结束。
        // 不用「非空即 hasMore」，否则最后一页仍会多请求一次空页。
        let hasMore = mediaItems.count >= 30
        return AuthorMediaPageResult(items: mediaItems, hasMore: hasMore)
    }

    // MARK: - Workshop 下载

    /// 下载 Workshop 壁纸（通过 SteamCMD）
    /// - Parameter folderID: 下载入库时一并写入的库文件夹归属（作者批量下载用）。
    func downloadWorkshopWallpaper(_ item: MediaItem, folderID: String? = nil) async throws {
        guard item.id.hasPrefix("workshop_") else {
            throw WorkshopError.workshopNotSupported
        }

        AppLogger.info(.download, "downloadWorkshopWallpaper", metadata: [
            "item.id": item.id,
            "workshopID": String(item.id.dropFirst("workshop_".count)),
            "title": item.title
        ])
        try await PersistentDownloadQueueService.shared.enqueueWorkshopAndWait(
            item,
            folderID: folderID,
            using: self
        )
    }

    private func normalizeWorkshopDownloadLocation(_ url: URL, workshopID: String) -> URL {
        // downloadWorkshopItem 返回的 url 已经是完整的 content 路径：
        // {downloadDir}/steamapps/workshop/content/431960/{workshopID}
        // 直接使用即可，无需再叠加路径
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            return url
        }
        // 兜底：如果返回的是 downloadDir 本身（而非 content 子目录），尝试拼接
        let appContentPath = url.appendingPathComponent("steamapps/workshop/content/431960/\(workshopID)")
        if fm.fileExists(atPath: appContentPath.path) {
            return appContentPath
        }
        return url
    }

    // MARK: - Workshop 更新检测 / 重下

    /// 检查已下载 Workshop 条目是否有远端更新。
    /// - Returns: `(hasUpdate, remoteUpdatedAt)`；网络失败时返回 `nil`（保持当前 UI）。
    func checkWorkshopUpdateAvailability(for item: MediaItem) async -> (hasUpdate: Bool, remoteUpdatedAt: Date?)? {
        guard item.id.hasPrefix("workshop_") else { return nil }
        guard let record = mediaLibrary.downloadRecord(for: item.id), record.isActive else {
            return (false, nil)
        }

        let workshopID = String(item.id.dropFirst("workshop_".count))
        do {
            guard let remote = try await workshopService.fetchWorkshopRemoteUpdateInfo(workshopID: workshopID) else {
                return (false, nil)
            }

            // 优先对比下载时记录的 Steam time_updated；老记录无此字段时退回 downloadedAt。
            let baseline = record.item.updatedAt ?? record.downloadedAt
            let hasUpdate = remote.updatedAt > baseline.addingTimeInterval(1)

            if !hasUpdate, record.item.updatedAt == nil || record.item.fileSize == nil {
                // 历史记录补齐元数据，后续比较更稳
                let patched = mediaItemByUpdatingRemoteMetadata(
                    record.item,
                    updatedAt: remote.updatedAt,
                    fileSize: remote.fileSize
                )
                mediaLibrary.upsert(patched)
            }

            return (hasUpdate, remote.updatedAt)
        } catch {
            AppLogger.info(.download, "Workshop 更新检查失败", metadata: [
                "id": item.id,
                "error": error.localizedDescription
            ])
            return nil
        }
    }

    /// 删除本地 Workshop 包后重新下载（覆盖为最新版）。
    /// 调用方应先停掉正在播放的该壁纸。
    func updateWorkshopWallpaper(_ item: MediaItem) async throws {
        guard item.id.hasPrefix("workshop_") else {
            throw WorkshopError.workshopNotSupported
        }

        let folderID = mediaLibrary.downloadRecord(for: item.id)?.folderID
        // 先拉远端元数据，下载成功后写入最新 updatedAt
        var itemToDownload = item
        let workshopID = String(item.id.dropFirst("workshop_".count))
        if let remote = try? await workshopService.fetchWorkshopRemoteUpdateInfo(workshopID: workshopID) {
            itemToDownload = mediaItemByUpdatingRemoteMetadata(
                item,
                updatedAt: remote.updatedAt,
                fileSize: remote.fileSize
            )
        }

        mediaLibrary.removeDownloadRecord(withID: item.id)
        try await downloadWorkshopWallpaper(itemToDownload, folderID: folderID)

        // 双保险：下载记录复活时若队列 Job 路径未写回归属（并发路径可能以 nil 复活
        // 软删记录），按删前捕获的 folderID 强制恢复，与「重新下载」流程保持一致；
        // 根目录（nil）也照此处理，不误改用户已手动移动的归属。
        if let record = mediaLibrary.downloadRecord(for: item.id),
           MediaLibraryService.normalizedFolderID(record.folderID)
               != MediaLibraryService.normalizedFolderID(folderID) {
            mediaLibrary.moveMediaToFolder(
                mediaID: item.id,
                folderID: MediaLibraryService.normalizedFolderID(folderID),
                scope: .downloads
            )
        }
    }

    private func mediaItemByUpdatingRemoteMetadata(
        _ item: MediaItem,
        updatedAt: Date?,
        fileSize: Int64?
    ) -> MediaItem {
        MediaItem(
            slug: item.slug,
            title: item.title,
            pageURL: item.pageURL,
            thumbnailURL: item.thumbnailURL,
            resolutionLabel: item.resolutionLabel,
            collectionTitle: item.collectionTitle,
            summary: item.summary,
            previewVideoURL: item.previewVideoURL,
            posterURL: item.posterURL,
            tags: item.tags,
            exactResolution: item.exactResolution,
            durationSeconds: item.durationSeconds,
            downloadOptions: item.downloadOptions,
            sourceName: item.sourceName,
            isAnimatedImage: item.isAnimatedImage,
            subscriptionCount: item.subscriptionCount,
            favoriteCount: item.favoriteCount,
            viewCount: item.viewCount,
            ratingScore: item.ratingScore,
            authorName: item.authorName,
            authorSteamID: item.authorSteamID,
            authorAvatarURL: item.authorAvatarURL,
            fileSize: fileSize ?? item.fileSize,
            createdAt: item.createdAt,
            updatedAt: updatedAt ?? item.updatedAt
        )
    }

    // MARK: - 通过 URL 解析项目

    /// 解析 Steam Workshop 链接并返回 MediaItem，失败时抛出错误
    func resolveWorkshopItemByURL(_ urlString: String) async throws -> MediaItem {
        let item = try await workshopService.resolveWorkshopItemByURL(urlString)
        print("[MediaExploreViewModel] resolveWorkshopItemByURL success: \(item.id) - \(item.title)")
        return item
    }

    /// 解析 MotionBG 链接并返回 MediaItem，失败时抛出错误
    func resolveMotionBGItemByURL(_ urlString: String) async throws -> MediaItem {
        guard let url = URL(string: urlString),
              url.host?.contains("motionbgs") == true else {
            throw WorkshopError.invalidURL
        }
        let slug = url.lastPathComponent
        guard !slug.isEmpty, slug != "/" else {
            throw WorkshopError.invalidURL
        }
        let item = try await mediaService.fetchDetail(slug: slug)
        print("[MediaExploreViewModel] resolveMotionBGItemByURL success: \(item.id) - \(item.title)")
        return item
    }

    /// 解析动态桌面（DongTai）OSS 视频链接并返回 MediaItem
    func resolveDongTaiItemByURL(_ urlString: String) async throws -> MediaItem {
        let item = try await dynamicWallpaperService.resolveItemByOSSURL(urlString)
        print("[MediaExploreViewModel] resolveDongTaiItemByURL success: \(item.id) - \(item.title)")
        return item
    }

    /// 解析 Wallsflow 详情页链接并返回 MediaItem
    func resolveWallsflowItemByURL(_ urlString: String) async throws -> MediaItem {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let host = url.host?.lowercased(),
              host.contains("wallsflow.com") else {
            throw WorkshopError.invalidURL
        }
        let item = try await wallsflowService.fetchDetail(url: url)
        print("[MediaExploreViewModel] resolveWallsflowItemByURL success: \(item.id) - \(item.title)")
        return item
    }

    /// 检测 CDN 鉴权失败时返回的 HTML 伪装响应（避免落盘坏文件）。
    /// 注意：wallsflow 热链失败页可达 ~200KB+，绝不能只按体积阈值扫描。
    private static func looksLikeHTMLPayload(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        let prefixCount = min(data.count, 512)
        let raw = data.prefix(prefixCount)
        // BOM / 前导空白后的 HTML
        if let head = String(data: raw, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() {
            if head.hasPrefix("<!doctype html")
                || head.hasPrefix("<html")
                || head.hasPrefix("<head")
                || head.contains("<head")
                || head.contains("utm_source=redirect")
                || head.contains("just a moment") {
                return true
            }
        }
        // 非 UTF-8 时仍可能以 ASCII 标签开头
        let lower = raw.map { ($0 >= 65 && $0 <= 90) ? $0 + 32 : $0 }
        if let s = String(bytes: lower.prefix(64), encoding: .ascii) {
            if s.hasPrefix("<!doctype") || s.hasPrefix("<html") {
                return true
            }
        }
        return false
    }

    /// 是否像 ISO BMFF / MP4（`....ftyp`）。
    private static func looksLikeISOBMFF(_ data: Data) -> Bool {
        guard data.count >= 8 else { return false }
        return data[4..<8] == Data("ftyp".utf8)
    }

    /// 本地“媒体”文件是否其实是 HTML 或无法播放的坏文件。
    /// 任意体积都读文件头：历史坏文件常为 200KB+ HTML，旧逻辑（仅 <64KB）会漏检。
    private static func localMediaFileLooksCorrupt(_ url: URL) -> Bool {
        let path = url.path
        guard FileManager.default.fileExists(atPath: path) else { return false }
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let ext = url.pathExtension.lowercased()
        let videoExts: Set<String> = ["mp4", "mov", "webm", "m4v", "mkv"]

        if size <= 0 { return true }

        guard let handle = try? FileHandle(forReadingFrom: url) else { return true }
        defer { try? handle.close() }
        let head = handle.readData(ofLength: 512)

        if looksLikeHTMLPayload(head) {
            return true
        }

        // 过小的“视频”几乎一定是坏文件（热链 HTML 也常 < 512KB）
        if videoExts.contains(ext), size < 64_000 {
            return true
        }

        if videoExts.contains(ext) {
            // webm/mkv 为 EBML (0x1A45DFA3)；mp4/mov/m4v 为 ISO BMFF `ftyp`
            if ext == "webm" || ext == "mkv" {
                if head.count >= 4,
                   head[0] == 0x1A, head[1] == 0x45, head[2] == 0xDF, head[3] == 0xA3 {
                    return false
                }
                return true
            }
            if looksLikeISOBMFF(head) {
                return false
            }
            // 非 ftyp 且非 HTML 的伪装扩展名 → 仍视为损坏，强制重下
            return true
        }

        return false
    }

    // MARK: - 同步 Steam 订阅

    /// 同步已下载列表的 Workshop ID 集合
    private var downloadedWorkshopIDs: Set<String> {
        Set(mediaLibrary.downloadRecords.compactMap { record -> String? in
            guard record.id.hasPrefix("workshop_") else { return nil }
            return String(record.id.dropFirst("workshop_".count))
        })
    }

    /// 获取已订阅但未下载的 Workshop 物品列表（用于 UI 选择）
    /// - Parameter steamID: Steam 64位数字 ID
    /// - Returns: 未下载的订阅物品列表
    func fetchSubscribedItems(steamID: String) async throws -> [WorkshopWallpaper] {
        let subscribed = try await workshopService.fetchAllSubscriptions(steamID: steamID)

        // 从下载记录中提取已下载的 workshop ID
        let alreadyDownloaded = downloadedWorkshopIDs

        // 同时扫描磁盘上已有的 workshop 目录，覆盖下载记录缺失或记录 ID 异常的情况
        let fm = FileManager.default
        let mediaURL = DownloadPathManager.shared.mediaFolderURL
        var diskDownloadedIDs = Set<String>()
        if let contents = try? fm.contentsOfDirectory(at: mediaURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
            for url in contents {
                let name = url.lastPathComponent
                guard name.hasPrefix("workshop_") else { continue }
                let id = String(name.dropFirst("workshop_".count))
                diskDownloadedIDs.insert(id)
            }
        }

        return subscribed.filter { item in
            guard !alreadyDownloaded.contains(item.id) else { return false }
            guard !diskDownloadedIDs.contains(item.id) else { return false }
            return true
        }
    }

    /// 下载指定的 Workshop 物品列表
    /// - Parameter mediaItems: 要下载的媒体项
    func downloadWorkshopItems(_ mediaItems: [MediaItem]) async throws -> Int {
        // 并发提交所有下载任务，SteamCMD 下载限制器会自动控制并发（最多 2 个同时下载）
        return await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for item in mediaItems {
                group.addTask { [weak self] in
                    guard let self else { return false }
                    guard !Task.isCancelled else { return false }
                    do {
                        try await self.downloadWorkshopWallpaper(item)
                        return true
                    } catch {
                        AppLogger.error(.media, "batch download failed", metadata: ["id": item.id, "error": "\(error)"])
                        return false
                    }
                }
            }
            
            var successCount = 0
            for await success in group {
                if success { successCount += 1 }
            }
            return successCount
        }
    }

    /// 同步用户已订阅的 Workshop 壁纸（获取列表后排队下载）
    /// - Returns: (新增下载数, 总订阅数)
    func syncSubscribedWorkshopItems() async throws -> (newDownloads: Int, totalSubscribed: Int) {
        let steamID = workshopSourceManager.steamProfileID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !steamID.isEmpty else {
            throw WorkshopError.invalidCredentials
        }

        // 1. 获取所有已订阅壁纸
        let subscribed = try await workshopService.fetchAllSubscriptions(steamID: steamID)
        let totalSubscribed = subscribed.count
        AppLogger.info(.media, "syncSubscribedWorkshopItems: found \(totalSubscribed) subscribed items")

        // 2. 过滤出未下载的（下载记录 + 磁盘目录双重检查）
        let alreadyDownloaded = downloadedWorkshopIDs
        let fm = FileManager.default
        let mediaURL = DownloadPathManager.shared.mediaFolderURL
        var diskDownloadedIDs = Set<String>()
        if let contents = try? fm.contentsOfDirectory(at: mediaURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
            for url in contents {
                let name = url.lastPathComponent
                guard name.hasPrefix("workshop_") else { continue }
                let id = String(name.dropFirst("workshop_".count))
                diskDownloadedIDs.insert(id)
            }
        }
        let toDownload = subscribed.filter { item in
            guard !alreadyDownloaded.contains(item.id) else { return false }
            guard !diskDownloadedIDs.contains(item.id) else { return false }
            return true
        }
        AppLogger.info(.media, "syncSubscribedWorkshopItems: \(toDownload.count) new, \(alreadyDownloaded.count) already downloaded")

        // 3. 转换为 MediaItem 并并发提交到下载队列
        // SteamCMD 下载限制器会自动控制并发（最多 2 个同时下载），超出的会排队等待
        let mediaItems = workshopService.convertToMediaItems(toDownload)
        
        return await withTaskGroup(of: Bool.self, returning: (Int, Int).self) { group in
            for item in mediaItems {
                group.addTask { [weak self] in
                    guard let self else { return false }
                    guard !Task.isCancelled else { return false }
                    do {
                        try await self.downloadWorkshopWallpaper(item)
                        return true
                    } catch {
                        AppLogger.error(.media, "syncSubscribedWorkshopItems download failed", metadata: ["id": item.id, "error": "\(error)"])
                        return false
                    }
                }
            }
            
            var newCount = 0
            for await success in group {
                if success { newCount += 1 }
            }
            
            AppLogger.info(.media, "syncSubscribedWorkshopItems completed: \(newCount) new downloads")
            return (newCount, totalSubscribed)
        }
    }
}

// MARK: - 统一的本地媒体表示

/// 统一的本地媒体表示
/// 用于混合显示下载记录和用户手动复制到目录的本地文件
struct UnifiedLocalMedia: Identifiable {
    let id: String
    let mediaItem: MediaItem
    let localItem: LocalMediaItem?
    let downloadRecord: MediaDownloadRecord?
    let fileURL: URL
    let isLocalFile: Bool

    /// 标题
    var title: String {
        localItem?.title ?? mediaItem.title
    }

    /// 分辨率
    var resolution: String? {
        localItem?.resolution ?? mediaItem.exactResolution
    }

    /// 文件大小标签
    var fileSizeLabel: String? {
        localItem?.fileSizeLabel ?? downloadRecord.flatMap { _ in
            // 从文件获取大小
            (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int).flatMap { size in
                let mb = Double(size) / 1024 / 1024
                return String(format: "%.1f MB", mb)
            }
        }
    }

    /// 时长标签
    var durationLabel: String? {
        localItem?.durationLabel ?? mediaItem.durationLabel
    }

    /// 创建/下载时间
    var dateLabel: String? {
        if let record = downloadRecord {
            return formatMediaDate(record.downloadedAt)
        }
        if let localItem = localItem, let createdAt = localItem.createdAt {
            return formatMediaDate(parseISO8601Media(createdAt))
        }
        return nil
    }

    /// 是否为竖屏；优先使用烘焙产物尺寸，其次 exactResolution，再次本地文件分辨率
    var isPortrait: Bool? {
        if let artifact = downloadRecord?.sceneBakeArtifact {
            return artifact.height > artifact.width
        }
        if let portrait = mediaItem.isPortrait {
            return portrait
        }
        if let resolution = localItem?.resolution {
            let trimmed = resolution
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "X", with: "x")
            let parts = trimmed.split(separator: "x")
            guard parts.count == 2,
                  let w = Double(parts[0]),
                  let h = Double(parts[1]),
                  h > 0 else { return nil }
            return h > w
        }
        return nil
    }
}

// MARK: - 辅助函数

private func parseISO8601Media(_ string: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    return formatter.date(from: string)
}

private func formatMediaDate(_ date: Date?) -> String? {
    guard let date = date else { return nil }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return formatter.localizedString(for: date, relativeTo: Date())
}
