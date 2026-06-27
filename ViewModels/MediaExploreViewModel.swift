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
    private let localScanner = LocalWallpaperScanner.shared
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
    private var preloadTask: Task<Void, Never>?
    private var preloadedItems: [MediaItem] = []
    /// 预加载的页面路径（即被预加载的那个页面的 URL），用于和 nextPagePath 匹配。
    private var preloadedPagePath: String?
    /// 预加载页面的下一页路径（预加载页面返回的 nextPagePath）。
    private var preloadedNextPath: String?

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
        let preloadedItems: [MediaItem]
        let preloadedPagePath: String?
        let preloadedNextPath: String?
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
    /// Workshop 排序方式
    private(set) var workshopSortBy: WorkshopSearchParams.SortOption = .ranked
    /// Workshop 热门趋势时间范围（仅对 trend 排序有效），nil = 全部时间
    private(set) var workshopDays: Int? = nil

    // MARK: - Dynamic Wallpaper (DongTai) 分页状态
    private var dongtaiCurrentPage = 1
    private var dongtaiHasMore = true
    private var dongtaiSearchQuery = ""
    private var dongtaiCurrentCategories: Set<DynamicWallpaperCategory> = []
    private var dongtaiCurrentListType: DynamicWallpaperListType = .all
    private var dongtaiSortBy: DynamicWallpaperSortOption = .popular
    private var dongtaiFilterAudio: Bool? = nil
    private var dongtaiFilterFourK: Bool? = nil
    /// 加载世代计数器，用于丢弃旧请求的结果
    private var dongtaiLoadGeneration: UInt = 0

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

    init() {
        // 缓存 UserDefaults 值，避免后台线程访问触发 _CFXPreferences 递归崩溃
        persistDownloadedMediaToAppLibrary = UserDefaults.standard.object(forKey: DownloadPathManager.persistDownloadsToAppLibraryDefaultsKey) as? Bool ?? true

        // 注册内存压力通知（由 WaifuXApp.configureKingfisher 中的 DispatchSource 触发）
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
        Publishers.Merge3(
            mediaLibrary.$favoriteRecords.map { _ in () },
            mediaLibrary.$downloadRecords.map { _ in () },
            localScanner.$scanRevision.map { _ in () }
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
                self.preloadTask?.cancel()
                self.preloadTask = nil
                self.networkRecoveryTask?.cancel()
                self.networkRecoveryTask = nil
                self.detailTasks.values.forEach { $0.cancel() }
                self.detailTasks.removeAll()
                self.cancelDetailPrefetchQueue()
                self.invalidatePreservedExploreFeed()
                // 2. 清空预加载缓存
                self.preloadedItems = []
                self.preloadedPagePath = nil
                self.preloadedNextPath = nil
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

    var favoriteItems: [MediaItem] {
        mediaLibrary.favoriteItems
    }

    var favoriteSyncRecords: [MediaFavoriteRecord] {
        mediaLibrary.favoriteRecords
    }

    var downloadedItems: [MediaDownloadRecord] {
        mediaLibrary.downloadedItems
    }

    /// 本地扫描的媒体（用户手动复制到目录的文件）
    var localMediaItems: [LocalMediaItem] {
        localScanner.getLocalMedia()
    }

    /// 所有可显示的本地媒体（下载记录 + 扫描到的本地文件）
    /// 用于库页面显示。现在返回内存缓存，避免重复文件 I/O。
    var allLocalMedia: [UnifiedLocalMedia] {
        cachedAllLocalMedia
    }

    /// 重建本地媒体缓存（在 downloadRecords / favoriteRecords / scanRevision 变化时自动调用）
    private func scheduleLocalMediaCacheRebuild(delayNanoseconds: UInt64) {
        rebuildLocalMediaCacheTask?.cancel()
        rebuildLocalMediaCacheTask = Task { @MainActor [weak self] in
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard let self, !Task.isCancelled else { return }
            await self.rebuildLocalMediaCache()
        }
    }

    /// 主线程只取快照和发布结果；路径标准化、文件存在性检查和排序放到后台，避免上千条本地数据卡住 UI。
    private func rebuildLocalMediaCache() async {
        let downloads = mediaLibrary.downloadedItems
        let locals = localScanner.getLocalMedia()
        let downloadedIDs = mediaLibrary.downloadIDSetForRebuild

        let localMediaPairs = locals.map { item in
            (item, item.toMediaItem())
        }

        let result = await Task.detached(priority: .utility) {
            var result: [UnifiedLocalMedia] = downloads.map { record in
                UnifiedLocalMedia(
                    id: record.item.id,
                    mediaItem: record.item,
                    localItem: nil,
                    downloadRecord: record,
                    fileURL: record.localFileURL,
                    isLocalFile: false
                )
            }

            let downloadedPaths = Set(downloads.map {
                (($0.localFilePath as NSString).standardizingPath as String)
            })

            for (item, mediaItem) in localMediaPairs {
                guard !downloadedIDs.contains(item.id) else { continue }
                let itemPath = (item.fileURL.path as NSString).standardizingPath as String
                guard !downloadedPaths.contains(itemPath) else { continue }
                guard FileManager.default.fileExists(atPath: item.fileURL.path) else { continue }
                result.append(UnifiedLocalMedia(
                    id: item.id,
                    mediaItem: mediaItem,
                    localItem: item,
                    downloadRecord: nil,
                    fileURL: item.fileURL,
                    isLocalFile: true
                ))
            }

            return result.sorted { a, b in
                let dateA = a.downloadRecord?.downloadedAt ?? a.localItem?.createdAt.flatMap { parseISO8601Media($0) } ?? Date.distantPast
                let dateB = b.downloadRecord?.downloadedAt ?? b.localItem?.createdAt.flatMap { parseISO8601Media($0) } ?? Date.distantPast
                return dateA > dateB
            }
        }.value

        guard !Task.isCancelled else { return }
        cachedAllLocalMedia = result
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
            preloadedItems: preloadedItems,
            preloadedPagePath: preloadedPagePath,
            preloadedNextPath: preloadedNextPath,
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
        preloadedItems = snapshot.preloadedItems
        preloadedPagePath = snapshot.preloadedPagePath
        preloadedNextPath = snapshot.preloadedNextPath
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
        preloadTask?.cancel()
        preloadedItems = []
        preloadedPagePath = nil
        preloadedNextPath = nil
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

        defer {
            isLoadingMore = false
            // 加载完成后触发预加载
            if hasMorePages {
                triggerPreloadNextPage()
            }
        }

        do {
            let page: MediaListPage

            // 检查是否有预加载的数据
            if preloadedPagePath == nextPagePath && !preloadedItems.isEmpty {
                print("[MediaExploreViewModel] Using preloaded page")
                page = MediaListPage(items: preloadedItems, nextPagePath: preloadedNextPath ?? preloadedPagePath, sectionTitle: currentTitle)
                // 清空预加载数据
                preloadedItems = []
                preloadedPagePath = nil
                preloadedNextPath = nil
            } else {
                // 正常加载
                page = try await mediaService.fetchPage(source: currentSource, pagePath: nextPagePath)
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
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - 预加载下一页
    private func triggerPreloadNextPage() {
        preloadTask?.cancel()

        guard let nextPath = nextPagePath else { return }
        let source = currentSource

        preloadTask = Task(priority: .low) {
            // 延迟一下再开始预加载
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5秒

            guard !Task.isCancelled else { return }

            do {
                print("[MediaExploreViewModel] Preloading next page...")
                let page = try await mediaService.fetchPage(source: source, pagePath: nextPath)

                guard !Task.isCancelled else { return }

                // 存储预加载的数据：preloadedPagePath 是当前预加载的页面路径，
                // preloadedNextPath 是该页面返回的下一页路径。
                preloadedItems = Array(page.items.prefix(40))
                preloadedPagePath = nextPath
                preloadedNextPath = page.nextPagePath
                print("[MediaExploreViewModel] Preloaded \(page.items.count) items at path \(nextPath)")
            } catch {
                print("[MediaExploreViewModel] Preload failed: \(error)")
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
        preloadTask?.cancel()
        cancelDetailPrefetchQueue()
        preloadedItems = []
        preloadedPagePath = nil
        preloadedNextPath = nil
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
                    case .application: return .application
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
        let task = downloadTaskService.addTask(mediaItem: item)

        let downloadTask = Task { [weak self] in
            guard let self else { throw CancellationError() }

            _ = try await ensureLocalVideoFile(
                for: item,
                preferredOption: preferredOption,
                saveToDownloads: persistDownloadedMediaToAppLibrary,
                taskID: task.id
            )
            downloadTaskService.markCompleted(id: task.id)
        }

        // 注册任务以便支持取消
        downloadTaskService.registerDownloadTask(id: task.id, task: downloadTask)
        defer { downloadTaskService.unregisterDownloadTask(id: task.id) }

        do {
            try await downloadTask.value
        } catch {
            if !(error is CancellationError) {
                downloadTaskService.markFailed(id: task.id)
            }
            throw error
        }
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
    func downloadMedia(_ item: MediaItem, option: MediaDownloadOption) async throws -> URL {
        let task = downloadTaskService.addTask(mediaItem: item)

        // 创建真正执行下载逻辑的 Task（有返回值）
        let valueTask = Task { [weak self] () -> URL in
            guard let self else { throw CancellationError() }

            let localURL = try await ensureLocalVideoFile(
                for: item,
                preferredOption: option,
                saveToDownloads: persistDownloadedMediaToAppLibrary,
                taskID: task.id
            )
            downloadTaskService.markCompleted(id: task.id)
            return localURL
        }

        // 包装为 Void Task 用于注册（DownloadTaskStorage 要求 Task<Void, Error>）
        let downloadTask = Task<Void, Error> {
            _ = try await valueTask.value
        }

        // 注册任务以便支持取消
        downloadTaskService.registerDownloadTask(id: task.id, task: downloadTask)
        defer { downloadTaskService.unregisterDownloadTask(id: task.id) }

        do {
            return try await valueTask.value
        } catch {
            if !(error is CancellationError) {
                downloadTaskService.markFailed(id: task.id)
            }
            throw error
        }
    }

    func applyDynamicWallpaper(_ item: MediaItem, muted: Bool, targetScreen: NSScreen? = nil) async throws {
        // Workshop 项：优先查找本地已下载的视频文件
        if item.id.hasPrefix("workshop_"),
           let localVideoURL = findLocalWorkshopVideo(for: item) {
            print("[MediaExploreViewModel] Using downloaded Workshop video: \(localVideoURL.path)")
            let posterURL = await VideoThumbnailCache.shared.lockScreenPosterURL(forLocalVideo: localVideoURL, fallbackPosterURL: item.posterURL)
            let optimizedURL = await VideoTranscodeService.ensureSeekFriendly(localVideoURL)
            try videoWallpaperManager.applyVideoWallpaper(from: optimizedURL, posterURL: posterURL, muted: muted, targetScreens: targetScreen.map { [$0] })
            return
        }

        // 本地媒体文件：直接使用本地文件路径
        if item.id.hasPrefix("local_") {
            let localURL = item.previewVideoURL ?? item.pageURL
            if localURL.isFileURL && FileManager.default.fileExists(atPath: localURL.path) {
                print("[MediaExploreViewModel] Using local media file: \(localURL.path)")
                let posterURL = await VideoThumbnailCache.shared.lockScreenPosterURL(forLocalVideo: localURL, fallbackPosterURL: item.posterURL)
                let optimizedURL = await VideoTranscodeService.ensureSeekFriendly(localURL)
                try videoWallpaperManager.applyVideoWallpaper(from: optimizedURL, posterURL: posterURL, muted: muted, targetScreens: targetScreen.map { [$0] })
                return
            }
        }

        // 网络媒体文件：下载后使用
        let localVideoURL = try await ensureLocalVideoFile(
            for: item,
            preferredOption: preferredWallpaperOption(for: item),
            saveToDownloads: false
        )
        let posterURL = await VideoThumbnailCache.shared.lockScreenPosterURL(forLocalVideo: localVideoURL, fallbackPosterURL: item.posterURL)
        let optimizedURL = await VideoTranscodeService.ensureSeekFriendly(localVideoURL)
        try videoWallpaperManager.applyVideoWallpaper(from: optimizedURL, posterURL: posterURL, muted: muted, targetScreens: targetScreen.map { [$0] })
    }

    /// Workshop 内容类型
    private enum WorkshopContentType {
        case video        // 纯视频类型，WaifuX 可直接播放
        case scene        // 场景/应用类型，需要 Wallpaper Engine CLI 渲染
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
        }
        return .unknown
    }

    /// 递归查找目录中的视频文件
    private func findVideoFile(in directory: URL) -> URL? {
        let videoExts = ["mp4", "mov", "webm"]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return nil
        }
        for case let fileURL as URL in enumerator {
            if videoExts.contains(fileURL.pathExtension.lowercased()) {
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
                if contentType == .scene {
                    // scene 类型跳过
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
                if contentType == .scene {
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
            preloadedItems: snapshot.preloadedItems,
            preloadedPagePath: snapshot.preloadedPagePath,
            preloadedNextPath: snapshot.preloadedNextPath,
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
        MediaItem(
            slug: original.slug,
            title: original.title,
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
        taskID: String? = nil
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
            print("[MediaExploreViewModel] File found at: \(fileLocation.url.path) (location: \(fileLocation.foundIn))")
            if let taskID {
                updateDownloadProgress(taskID: taskID, progress: saveToDownloads ? 0.72 : 1.0)
            }

            // 如果在旧位置找到，更新下载记录的路径
            if fileLocation.foundIn == .legacyRootFolder && saveToDownloads {
                mediaLibrary.updateDownloadPath(for: resolvedItem.id, newURL: fileLocation.url)
            }

            return fileLocation.url
        }

        // 文件不存在，需要下载
        let fileURL = fileLocation.url

        // 确保目录存在（先检查沙盒权限再创建目录）
        guard await downloadPathManager.ensureDirectoryStructure() else {
            throw DownloadError.permissionDenied
        }

        let cachedURL: URL
        if let existingCachedURL = await cacheService.cachedFileURL(named: fileURL.lastPathComponent, in: "Media") {
            cachedURL = existingCachedURL
            if let taskID {
                updateDownloadProgress(taskID: taskID, progress: saveToDownloads ? 0.72 : 1.0)
            }
        } else {
            let data = try await networkService.fetchData(from: downloadOption.remoteURL) { progress in
                guard let taskID else { return }
                Task { @MainActor in
                    DownloadTaskService.shared.updateProgress(id: taskID, progress: min(progress * 0.86, 0.86))
                }
            }
            cachedURL = try await cacheService.cacheFile(data, named: fileURL.lastPathComponent, in: "Media")
            if let taskID {
                updateDownloadProgress(taskID: taskID, progress: saveToDownloads ? 0.9 : 1.0)
            }
        }

        if saveToDownloads {
            // 复制到应用内媒体库目录（Application Support 下 WaifuX/Media）
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                do {
                    // 确保目标目录存在
                    let directory = fileURL.deletingLastPathComponent()
                    if !FileManager.default.fileExists(atPath: directory.path) {
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        print("[MediaExploreViewModel] Created directory: \(directory.path)")
                    }

                    // 后台读取缓存文件 + 后台写入目标文件，避免 MainActor 阻塞
                    let cachedData = try await cachedURL.readDataAsync()
                    try await cachedData.writeAsync(to: fileURL, options: .atomic)

                    // 验证文件是否成功写入
                    if FileManager.default.fileExists(atPath: fileURL.path) {
                        print("[MediaExploreViewModel] ✅ File saved successfully: \(fileURL.path)")
                    } else {
                        print("[MediaExploreViewModel] ❌ File write appeared to succeed but file not found: \(fileURL.path)")
                        throw DownloadError.writeFailed(NSError(domain: "WaifuX", code: -1, userInfo: [NSLocalizedDescriptionKey: "File not found after write"]))
                    }
                } catch {
                    print("[MediaExploreViewModel] ❌ Failed to write file to app media library: \(error)")
                    throw DownloadError.writeFailed(error)
                }
            }

            if let taskID {
                updateDownloadProgress(taskID: taskID, progress: 0.96)
            }
            mediaLibrary.recordDownload(item: resolvedItem, localFileURL: fileURL)
            return fileURL
        }

        return cachedURL
    }

    private func updateDownloadProgress(taskID: String, progress: Double) {
        downloadTaskService.updateProgress(id: taskID, progress: progress)
    }

    func retryDownload(task: DownloadTask) async throws {
        switch task.kind {
        case .media:
            guard let item = task.mediaItem else {
                throw NetworkError.invalidResponse
            }
            let resolvedItem = try await loadDetail(for: item)
            guard let option = preferredWallpaperOption(for: resolvedItem) else {
                throw NetworkError.invalidResponse
            }
            downloadTaskService.removeTask(id: task.id)
            _ = try await downloadMedia(resolvedItem, option: option)

        case .workshop:
            guard let item = task.workshopItem ?? task.mediaItem else {
                throw NetworkError.invalidResponse
            }
            downloadTaskService.removeTask(id: task.id)
            try await downloadWorkshopWallpaper(item)

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
        preloadTask?.cancel()
        preloadedItems.removeAll()
        preloadedPagePath = nil
        preloadedNextPath = nil
        cancelDetailPrefetchQueue()
        detailTasks.values.forEach { $0.cancel() }
        detailTasks.removeAll()
    }

    /// 释放前台浏览态内存：取消当前前台任务并清空列表/本地列表快照，保留持久化库数据与设置状态。
    func releaseForegroundMemory() {
        networkRecoveryTask?.cancel()
        sourceSwitchTask?.cancel()
        networkMonitorSetupTask?.cancel()
        preloadTask?.cancel()
        networkRecoveryTask = nil
        sourceSwitchTask = nil
        networkMonitorSetupTask = nil
        preloadTask = nil
        preloadedItems.removeAll()
        preloadedPagePath = nil
        preloadedNextPath = nil
        nextPagePath = nil
        cancelDetailPrefetchQueue()
        detailTasks.values.forEach { $0.cancel() }
        detailTasks.removeAll()

        items.removeAll()
        homeItems.removeAll()
        cachedAllLocalMedia.removeAll()
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

    /// 重置 Workshop 浏览状态并强制加载默认趋势列表。
    @MainActor
    func resetAndLoadDefaultWorkshopFeed() async {
        invalidatePreservedExploreFeed()
        workshopSearchQuery = ""
        currentQuery = ""
        workshopCurrentTags = []
        workshopCurrentType = .all
        workshopCurrentContentLevel = .everyone
        workshopCurrentResolution = nil
        workshopSortBy = .ranked
        workshopDays = 7
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
    func setWorkshopSort(sortBy: WorkshopSearchParams.SortOption, days: Int? = nil) async {
        invalidatePreservedExploreFeed()
        workshopSortBy = sortBy
        workshopDays = days
        await loadWorkshopFeedInternal(
            query: workshopSearchQuery,
            tags: workshopCurrentTags,
            type: workshopCurrentType,
            contentLevel: workshopCurrentContentLevel,
            resolution: workshopCurrentResolution
        )
    }

    /// 内部方法：加载 Workshop 数据
    private func loadWorkshopFeedInternal(
        query: String,
        tags: [String],
        type: WorkshopSourceManager.WorkshopTypeFilter = .all,
        contentLevel: WorkshopSourceManager.WorkshopContentLevel? = nil,
        resolution: String? = nil
    ) async {
        guard !isLoading else { return }

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
            case .application: return .application
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

        workshopCurrentPage += 1

        let wallpaperType: WorkshopWallpaper.WallpaperType? = (workshopCurrentType == .all) ? nil : {
            switch workshopCurrentType {
            case .scene: return .scene
            case .video: return .video
            case .web: return .web
            case .application: return .application
            case .all: return nil
            }
        }()

        let params = WorkshopSearchParams(
            query: workshopSearchQuery,
            sortBy: workshopSortBy,
            page: workshopCurrentPage,
            pageSize: 20,
            tags: workshopCurrentTags,
            type: wallpaperType,
            contentLevel: workshopCurrentContentLevel?.rawValue,
            resolution: workshopCurrentResolution,
            days: workshopDays
        )

        do {
            let response = try await workshopService.search(params: params)
            let mediaItems = workshopService.convertToMediaItems(response.items)

            // 源一致性检查：如果切换了源，丢弃这个过期结果
            guard workshopSourceManager.activeSource == .wallpaperEngine else { return }

            let existingIDs = Set(items.map(\.id))
            let newItems = mediaItems.filter { !existingIDs.contains($0.id) }
            items.append(contentsOf: newItems)

            workshopHasMore = response.hasMore
            hasMorePages = response.hasMore
            print("[MediaExploreViewModel] loadMoreWorkshop completed: +\(newItems.count) items, total: \(items.count)")
        } catch {
            errorMessage = error.localizedDescription
            workshopCurrentPage -= 1  // 恢复页码
            print("[MediaExploreViewModel] loadMoreWorkshop failed: \(error)")
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
        dongtaiSortBy = .popular
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
            sortBy: .popular,
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
        print("[MediaExploreViewModel] loadDongTaiFeedInternal completed: \(items.count) items, total=\(result.totalCount)")
    }

    /// DongTai 加载更多
    func loadMoreDongTai() async {
        guard !isLoading, !isLoadingMore, dongtaiHasMore else { return }

        isLoadingMore = true
        errorMessage = nil

        defer { isLoadingMore = false }

        dongtaiCurrentPage += 1

        let params = DynamicWallpaperSearchParams(
            query: dongtaiSearchQuery,
            listType: dongtaiCurrentListType,
            categories: dongtaiCurrentCategories,
            sortBy: dongtaiSortBy,
            page: dongtaiCurrentPage,
            pageSize: 20,
            hasAudio: dongtaiFilterAudio,
            isFourK: dongtaiFilterFourK
        )

        let result = dynamicWallpaperService.queryItems(params: params)

        // 源一致性检查：如果切换了源，丢弃这个过期结果
        guard workshopSourceManager.activeSource == .dongtai else { return }

        let existingIDs = Set(items.map(\.id))
        let newItems = result.items.filter { !existingIDs.contains($0.id) }
        items.append(contentsOf: newItems)

        dongtaiHasMore = result.hasMore
        hasMorePages = result.hasMore
        print("[MediaExploreViewModel] loadMoreDongTai completed: +\(newItems.count) items, total: \(items.count)")
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
    private func loadWallsflowFeedInternal(query: String?, categorySlug: String?) async {
        guard !isLoading else { return }

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

        wallsflowCurrentPage += 1

        do {
            let page: WallsflowListPage

            if !wallsflowSearchQuery.isEmpty {
                page = try await wallsflowService.search(query: wallsflowSearchQuery, page: wallsflowCurrentPage)
            } else {
                page = try await wallsflowService.fetchCategory(slug: wallsflowCurrentCategorySlug, page: wallsflowCurrentPage)
            }

            // 源一致性检查：如果切换了源，丢弃这个过期结果
            guard workshopSourceManager.activeSource == .wallsflow else { return }

            let existingIDs = Set(items.map(\.id))
            let newItems = page.items.filter { !existingIDs.contains($0.id) }
            items.append(contentsOf: newItems)

            wallsflowHasMore = page.nextPagePath != nil
            hasMorePages = page.nextPagePath != nil
            print("[MediaExploreViewModel] loadMoreWallsflow completed: +\(newItems.count) items, total: \(items.count)")
        } catch {
            errorMessage = error.localizedDescription
            wallsflowCurrentPage -= 1
            print("[MediaExploreViewModel] loadMoreWallsflow failed: \(error)")
        }
    }

    // MARK: - 按作者获取 Workshop 物品

    /// 获取指定作者的所有 Workshop 壁纸
    /// - Parameters:
    ///   - steamID: Steam 64位数字 ID
    ///   - page: 页码
    /// - Returns: 壁纸列表（已转为 MediaItem）
    func fetchMediaByAuthor(steamID: String, page: Int = 1) async throws -> [MediaItem] {
        let wallpapers = try await workshopService.fetchByAuthor(steamID: steamID, page: page)
        let mediaItems = workshopService.convertToMediaItems(wallpapers)

        // 缓存到本地库
        for item in mediaItems {
            mediaLibrary.upsert(item)
        }

        return mediaItems
    }

    // MARK: - Workshop 下载

    /// 下载 Workshop 壁纸（通过 SteamCMD）
    func downloadWorkshopWallpaper(_ item: MediaItem, guardCode: String? = nil) async throws {
        guard item.id.hasPrefix("workshop_") else {
            throw WorkshopError.workshopNotSupported
        }

        let workshopID = String(item.id.dropFirst("workshop_".count))
        AppLogger.info(.download, "downloadWorkshopWallpaper", metadata: [
            "item.id": item.id,
            "workshopID": workshopID,
            "title": item.title
        ])
        let task = downloadTaskService.addTask(workshopWallpaper: item)
        let taskID = task.id
        downloadTaskService.markDownloading(id: taskID)

        let downloadTask = Task { [weak self] in
            guard let self else { throw CancellationError() }

            let localURL = try await workshopService.downloadWorkshopItem(
                workshopID: workshopID,
                guardCode: guardCode,
                progressHandler: { [weak self] progress in
                    Task { @MainActor in
                        self?.downloadTaskService.updateProgress(id: taskID, progress: progress)
                    }
                }
            )
            let normalizedURL = normalizeWorkshopDownloadLocation(localURL, workshopID: workshopID)
            mediaLibrary.recordDownload(item: item, localFileURL: normalizedURL)
            downloadTaskService.markCompleted(id: taskID)
            print("[MediaExploreViewModel] downloadWorkshopWallpaper completed: \(normalizedURL)")
        }

        // 注册任务以便支持取消
        downloadTaskService.registerDownloadTask(id: taskID, task: downloadTask)
        defer { downloadTaskService.unregisterDownloadTask(id: taskID) }

        do {
            try await downloadTask.value
        } catch {
            if !(error is CancellationError) {
                downloadTaskService.markFailed(id: taskID)
            }
            throw error
        }
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
