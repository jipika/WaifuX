import SwiftUI
import Combine
import AppKit

@MainActor
final class MediaExploreViewModel: ObservableObject {
    @Published private(set) var items: [MediaItem] = []
    @Published private(set) var currentTitle = "Featured"
    @Published var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published var errorMessage: String?
    @Published private(set) var hasMorePages = false
    @Published private(set) var currentQuery = ""
    
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

    private var currentSource: MediaRouteSource = .home
    private var nextPagePath: String?
    private var detailTasks: [String: Task<MediaItem, Error>] = [:]
    private var cancellables = Set<AnyCancellable>()

    /// 与 WallpaperViewModel.libraryContentRevision 相同用途：保证列表上的收藏/下载状态随库更新而刷新。
    @Published private(set) var libraryContentRevision: UInt = 0

    // MARK: - 计算属性

    /// 当前 Feed 标题（用于 UI 展示）
    var currentFeedTitle: String {
        currentTitle
    }

    init() {
        Publishers.Merge(
            mediaLibrary.$favoriteRecords.map { _ in () },
            mediaLibrary.$downloadRecords.map { _ in () }
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
                if status.connectionState.isConnected && self?.items.isEmpty == true {
                    Task { await self?.loadHomeFeed() }
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

        defer { isLoadingMore = false }

        do {
            let page = try await mediaService.fetchPage(source: currentSource, pagePath: nextPagePath)
            let existingIDs = Set(items.map(\.id))
            let appended = page.items.filter { !existingIDs.contains($0.id) }
            page.items.forEach { mediaLibrary.upsert($0) }
            items.append(contentsOf: appended)
            self.nextPagePath = page.nextPagePath
            hasMorePages = page.nextPagePath != nil
        } catch {
            errorMessage = error.localizedDescription
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

    func isFavorite(_ item: MediaItem) -> Bool {
        mediaLibrary.isFavorite(item)
    }

    func isDownloaded(_ item: MediaItem) -> Bool {
        mediaLibrary.isDownloaded(item)
    }

    func recordViewed(_ item: MediaItem) {
        mediaLibrary.recordViewed(item)
    }

    func download(_ item: MediaItem, preferredOption: MediaDownloadOption? = nil) async throws {
        let task = downloadTaskService.addTask(mediaItem: item)

        do {
            _ = try await ensureLocalVideoFile(
                for: item,
                preferredOption: preferredOption,
                saveToDownloads: true,
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
                saveToDownloads: true,
                taskID: task.id
            )
            downloadTaskService.markCompleted(id: task.id)
            return localURL
        } catch {
            downloadTaskService.markFailed(id: task.id)
            throw error
        }
    }

    func applyDynamicWallpaper(_ item: MediaItem, muted: Bool) async throws {
        let localVideoURL = try await ensureLocalVideoFile(
            for: item,
            preferredOption: preferredWallpaperOption(for: item),
            saveToDownloads: false
        )
        try videoWallpaperManager.applyVideoWallpaper(from: localVideoURL, muted: muted)
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
            // 复制到下载目录（安全作用域访问已由 ensureDirectoryStructure 确保）
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                do {
                    let cachedData = try Data(contentsOf: cachedURL)
                    try cachedData.write(to: fileURL, options: .atomic)
                } catch {
                    print("[MediaExploreViewModel] Failed to write file to download directory: \(error)")
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
}
