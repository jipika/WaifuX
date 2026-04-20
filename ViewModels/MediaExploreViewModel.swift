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

    // MARK: - 内存优化：限制最大数据量
    private let maxDataCount = 150  // 最多保留150条媒体数据

    // MARK: - Network State
    @Published var networkStatus: NetworkStatus = .unknown
    private let networkMonitor = NetworkMonitor.shared

    private let mediaService = MediaService.shared
    private let mediaLibrary = MediaLibraryService.shared
    private let networkService = NetworkService.shared
    private let cacheService = CacheService.shared
    private let videoWallpaperManager = VideoWallpaperManager.shared
    private let downloadTaskService = DownloadTaskService.shared
    private let downloadPathManager = DownloadPathManager.shared
    private let localScanner = LocalWallpaperScanner.shared
    private let workshopService = WorkshopService.shared
    private let workshopSourceManager = WorkshopSourceManager.shared

    private var currentSource: MediaRouteSource = .home
    private var nextPagePath: String?
    private var detailTasks: [String: Task<MediaItem, Error>] = [:]
    private var cancellables = Set<AnyCancellable>()

    // MARK: - 预加载支持
    private var preloadTask: Task<Void, Never>?
    private var preloadedItems: [MediaItem] = []
    private var preloadedNextPath: String?

    // MARK: - Workshop 分页状态
    private var workshopCurrentPage = 1
    private var workshopHasMore = true
    private var workshopSearchQuery = ""
    private var workshopCurrentTags: [String] = []
    private var workshopCurrentType: WorkshopSourceManager.WorkshopTypeFilter = .all
    /// 壁纸引擎内容级别固定为 SFW（`requiredtags[]=Everyone`），不在 UI 中暴露其它级别
    private var workshopFixedContentLevelRaw: String {
        WorkshopSourceManager.WorkshopContentLevel.everyone.rawValue
    }

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
        // 监听 Service 数据变化，转发 objectWillChange 通知视图更新
        // 因为 favoriteItems/allLocalMedia 是计算属性，需要手动转发变化通知
        Publishers.Merge3(
            mediaLibrary.$favoriteRecords.map { _ in () },
            mediaLibrary.$downloadRecords.map { _ in () },
            localScanner.$scanRevision.map { _ in () }
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            self?.rebuildLocalMediaCache()
            self?.libraryContentRevision &+= 1
            // 转发变化通知，让使用计算属性的视图自动更新
            self?.objectWillChange.send()
        }
        .store(in: &cancellables)

        // 初始重建一次缓存
        rebuildLocalMediaCache()

        // 监听网络状态变化
        networkMonitor.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.networkStatus = status
                // 网络恢复时自动刷新
                if status.connectionState.isConnected && self?.items.isEmpty == true {
                    Task { await self?.loadHomeFeed() }
                }
            }
            .store(in: &cancellables)

        // 监听 Workshop 数据源变化
        workshopSourceManager.$activeSource
            .receive(on: DispatchQueue.main)
            .sink { [weak self] source in
                guard let self = self else { return }
                // 清空旧数据，避免切换时新旧内容混在一起
                self.items.removeAll()
                if source == .wallpaperEngine {
                    // 切换到 Workshop 数据源
                    Task {
                        await self.loadWorkshopFeed()
                        await self.refreshHomeItems()
                    }
                } else {
                    // 切换回 MotionBG 数据源，重置状态
                    self.workshopCurrentPage = 1
                    self.workshopHasMore = true
                    self.workshopSearchQuery = ""
                    Task {
                        await self.loadHomeFeed()
                        await self.refreshHomeItems()
                    }
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
    private func rebuildLocalMediaCache() {
        let downloads = mediaLibrary.downloadedItems
        let locals = localScanner.getLocalMedia()
        
        var result: [UnifiedLocalMedia] = []
        
        // 添加下载记录
        for record in downloads {
            result.append(UnifiedLocalMedia(
                id: record.item.id,
                mediaItem: record.item,
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
            result.append(UnifiedLocalMedia(
                id: item.id,
                mediaItem: item.toMediaItem(),
                localItem: item,
                downloadRecord: nil,
                fileURL: item.fileURL,
                isLocalFile: true
            ))
        }
        
        // 按下载/创建时间排序
        cachedAllLocalMedia = result.sorted { a, b in
            let dateA = a.downloadRecord?.downloadedAt ?? a.localItem?.createdAt.flatMap { parseISO8601Media($0) } ?? Date.distantPast
            let dateB = b.downloadRecord?.downloadedAt ?? b.localItem?.createdAt.flatMap { parseISO8601Media($0) } ?? Date.distantPast
            return dateA > dateB
        }
    }
    
    /// 显式清理无效下载记录（文件不存在的记录），不应在 computed property 中自动调用
    func cleanupInvalidDownloadRecords() {
        mediaLibrary.cleanupInvalidDownloadRecords()
        rebuildLocalMediaCache()
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
        guard items.isEmpty else {
            print("[MediaExploreViewModel] items not empty, skipping initial load")
            return
        }
        await load(source: .home)
    }

    func load(source: MediaRouteSource) async {
        print("[MediaExploreViewModel] load called with source=\(source), current isLoading=\(isLoading)")

        guard !isLoading else {
            print("[MediaExploreViewModel] already loading, skipping")
            return
        }

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
        preloadedNextPath = nil

        // 先测试网络连通性
        do {
            print("[MediaExploreViewModel] testing direct network request...")
            let testURL = URL(string: "https://motionbgs.com")!
            let testString = try await NetworkService.shared.fetchString(from: testURL)
            print("[MediaExploreViewModel] direct network test success, received \(testString.count) bytes")
        } catch {
            print("[MediaExploreViewModel] direct network test failed: \(error)")
        }

        // 测试 MediaService actor 是否响应
        print("[MediaExploreViewModel] testing MediaService.clearCache...")
        do {
            try await withTimeout(seconds: 5) {
                await self.mediaService.clearCache()
            }
            print("[MediaExploreViewModel] clearCache success")
        } catch {
            print("[MediaExploreViewModel] clearCache failed: \(error)")
            errorMessage = error.localizedDescription
            return
        }

        print("[MediaExploreViewModel] about to call fetchPage")

        do {
            let page = try await withTimeout(seconds: 30) {
                try await self.mediaService.fetchPage(source: source)
            }

            print("[MediaExploreViewModel] received page with \(page.items.count) items")
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
            if preloadedNextPath == nextPagePath && !preloadedItems.isEmpty {
                print("[MediaExploreViewModel] Using preloaded page")
                page = MediaListPage(items: preloadedItems, nextPagePath: preloadedNextPath, sectionTitle: currentTitle)
                // 清空预加载数据
                preloadedItems = []
                preloadedNextPath = nil
            } else {
                // 正常加载
                page = try await mediaService.fetchPage(source: currentSource, pagePath: nextPagePath)
            }
            
            let existingIDs = Set(items.map(\.id))
            let appended = page.items.filter { !existingIDs.contains($0.id) }
            page.items.forEach { mediaLibrary.upsert($0) }
            items.append(contentsOf: appended)
            
            // 移除数据上限，避免滚动时出现空白
            // 内存优化通过降低 Kingfisher 缓存实现
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
                
                // 存储预加载的数据
                preloadedItems = page.items
                preloadedNextPath = page.nextPagePath
                print("[MediaExploreViewModel] Preloaded \(page.items.count) items")
            } catch {
                print("[MediaExploreViewModel] Preload failed: \(error)")
            }
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

    /// 独立刷新首页推荐数据（与 Explore 列表数据分离）
    @MainActor
    func refreshHomeItems() async {
        print("[MediaExploreViewModel] refreshHomeItems called")
        let source = workshopSourceManager.activeSource
        do {
            if source == .wallpaperEngine {
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
                    contentLevel: workshopFixedContentLevelRaw
                )
                let response = try await workshopService.search(params: params)
                homeItems = workshopService.convertToMediaItems(response.items)
            } else {
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

        defer { isLoading = false }
        errorMessage = nil

        do {
            let source = MediaRouteSource.tag(slug)
            let page = try await mediaService.fetchPage(source: source)
            currentSource = source
            currentTitle = page.sectionTitle.isEmpty ? title : page.sectionTitle
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

        defer { isLoading = false }
        errorMessage = nil

        do {
            let source = MediaRouteSource.search(trimmedQuery)
            let page = try await mediaService.fetchPage(source: source)
            currentSource = source
            currentTitle = page.sectionTitle.isEmpty ? trimmedQuery : page.sectionTitle
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

        if !item.downloadOptions.isEmpty || item.previewVideoURL != nil {
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
        // 发送变化通知，确保计算属性（favoriteItems/allLocalMedia）的依赖视图更新
        objectWillChange.send()
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
    private var persistDownloadedMediaToAppLibrary: Bool {
        UserDefaults.standard.object(forKey: DownloadPathManager.persistDownloadsToAppLibraryDefaultsKey) as? Bool ?? true
    }

    func download(_ item: MediaItem, preferredOption: MediaDownloadOption? = nil) async throws {
        let task = downloadTaskService.addTask(mediaItem: item)

        do {
            _ = try await ensureLocalVideoFile(
                for: item,
                preferredOption: preferredOption,
                saveToDownloads: persistDownloadedMediaToAppLibrary,
                taskID: task.id
            )
            downloadTaskService.markCompleted(id: task.id)
        } catch {
            downloadTaskService.markFailed(id: task.id)
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

        do {
            let localURL = try await ensureLocalVideoFile(
                for: item,
                preferredOption: option,
                saveToDownloads: persistDownloadedMediaToAppLibrary,
                taskID: task.id
            )
            downloadTaskService.markCompleted(id: task.id)
            return localURL
        } catch {
            downloadTaskService.markFailed(id: task.id)
            throw error
        }
    }

    func applyDynamicWallpaper(_ item: MediaItem, muted: Bool, targetScreen: NSScreen? = nil) async throws {
        // Workshop 项：优先查找本地已下载的视频文件
        if item.id.hasPrefix("workshop_"),
           let localVideoURL = findLocalWorkshopVideo(for: item) {
            print("[MediaExploreViewModel] Using downloaded Workshop video: \(localVideoURL.path)")
            let posterURL = await VideoThumbnailCache.shared.lockScreenPosterURL(forLocalVideo: localVideoURL, fallbackPosterURL: item.posterURL)
            try videoWallpaperManager.applyVideoWallpaper(from: localVideoURL, posterURL: posterURL, muted: muted, targetScreens: targetScreen.map { [$0] })
            return
        }

        // 本地媒体文件：直接使用本地文件路径
        if item.id.hasPrefix("local_") {
            let localURL = item.previewVideoURL ?? item.pageURL
            if localURL.isFileURL && FileManager.default.fileExists(atPath: localURL.path) {
                print("[MediaExploreViewModel] Using local media file: \(localURL.path)")
                let posterURL = await VideoThumbnailCache.shared.lockScreenPosterURL(forLocalVideo: localURL, fallbackPosterURL: item.posterURL)
                try videoWallpaperManager.applyVideoWallpaper(from: localURL, posterURL: posterURL, muted: muted, targetScreens: targetScreen.map { [$0] })
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
        try videoWallpaperManager.applyVideoWallpaper(from: localVideoURL, posterURL: posterURL, muted: muted, targetScreens: targetScreen.map { [$0] })
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
            items[index] = updatedItem
        }
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
                    
                    let cachedData = try Data(contentsOf: cachedURL)
                    try cachedData.write(to: fileURL, options: .atomic)
                    
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
        items.removeAll()
    }

    // MARK: - Workshop 数据加载

    /// 检查当前是否使用 Workshop 数据源
    var isUsingWorkshop: Bool {
        workshopSourceManager.activeSource == .wallpaperEngine
    }

    /// 加载 Workshop 首页/搜索内容（沿用当前类型 / 标签；内容级别固定 SFW）
    func loadWorkshopFeed() async {
        await loadWorkshopFeedInternal(
            query: workshopSearchQuery,
            tags: workshopCurrentTags,
            type: workshopCurrentType
        )
    }

    /// Workshop 搜索（与 Explore 搜索栏提交一致：清空标签/类型）
    func searchWorkshop(query: String) async {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        workshopSearchQuery = trimmedQuery
        currentQuery = trimmedQuery
        workshopCurrentTags = []
        workshopCurrentType = .all

        await loadWorkshopFeedInternal(
            query: trimmedQuery,
            tags: [],
            type: .all
        )
    }

    /// 按标签筛选 Workshop 内容
    func loadWorkshopWithTags(_ tags: [String]) async {
        workshopCurrentTags = tags
        await loadWorkshopFeedInternal(query: "", tags: tags)
    }

    /// 带完整筛选条件加载 Workshop 内容（内容级别固定 SFW）
    func loadWorkshopWithFilters(
        query: String = "",
        tags: [String] = [],
        type: WorkshopSourceManager.WorkshopTypeFilter = .all
    ) async {
        workshopSearchQuery = query
        workshopCurrentTags = tags
        workshopCurrentType = type
        await loadWorkshopFeedInternal(query: query, tags: tags, type: type)
    }

    /// 内部方法：加载 Workshop 数据
    private func loadWorkshopFeedInternal(
        query: String,
        tags: [String],
        type: WorkshopSourceManager.WorkshopTypeFilter = .all
    ) async {
        guard !isLoading else { return }

        isLoading = true
        errorMessage = nil

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

        let params = WorkshopSearchParams(
            query: query,
            sortBy: .ranked,
            page: 1,
            pageSize: 20,
            tags: tags,
            type: wallpaperType,
            contentLevel: workshopFixedContentLevelRaw
        )

        do {
            let response = try await workshopService.search(params: params)
            let mediaItems = workshopService.convertToMediaItems(response.items)
            items = mediaItems
            workshopHasMore = response.hasMore
            currentTitle = query.isEmpty ? "Workshop" : "搜索: \(query)"
            print("[MediaExploreViewModel] loadWorkshopFeedInternal completed: \(items.count) items")
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
            sortBy: .ranked,
            page: workshopCurrentPage,
            pageSize: 20,
            tags: workshopCurrentTags,
            type: wallpaperType,
            contentLevel: workshopFixedContentLevelRaw
        )

        do {
            let response = try await workshopService.search(params: params)
            let mediaItems = workshopService.convertToMediaItems(response.items)

            let existingIDs = Set(items.map(\.id))
            let newItems = mediaItems.filter { !existingIDs.contains($0.id) }
            items.append(contentsOf: newItems)
            workshopHasMore = response.hasMore
            print("[MediaExploreViewModel] loadMoreWorkshop completed: +\(newItems.count) items, total: \(items.count)")
        } catch {
            errorMessage = error.localizedDescription
            workshopCurrentPage -= 1  // 恢复页码
            print("[MediaExploreViewModel] loadMoreWorkshop failed: \(error)")
        }
    }

    // MARK: - Workshop 下载

    /// 下载 Workshop 壁纸（通过 SteamCMD）
    func downloadWorkshopWallpaper(_ item: MediaItem, guardCode: String? = nil) async throws {
        guard item.id.hasPrefix("workshop_") else {
            throw WorkshopError.workshopNotSupported
        }

        let workshopID = String(item.id.dropFirst("workshop_".count))
        let task = downloadTaskService.addTask(workshopWallpaper: item)
        let taskID = task.id
        downloadTaskService.markDownloading(id: taskID)

        do {
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
        } catch {
            downloadTaskService.markFailed(id: taskID)
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
