import Foundation
import Combine

// MARK: - Workshop ViewModel
///
/// 管理 Wallpaper Engine Workshop 页面的状态和逻辑
@MainActor
class WorkshopViewModel: ObservableObject {

    // MARK: - Published State

    @Published var wallpapers: [WorkshopWallpaper] = []
    @Published var isLoading = false
    @Published var isLoadingMore = false
    @Published var errorMessage: String?
    @Published var hasMorePages = false
    @Published var searchQuery = ""
    @Published var selectedSort: WorkshopSearchParams.SortOption = .ranked

    // MARK: - Services

    private let workshopService = WorkshopService.shared
    private var cancellables = Set<AnyCancellable>()

    /// 内存压力通知 observer token；deinit 时移除。
    /// ⚠️ token 一旦丢弃，NotificationCenter 会永久持有 observer block。
    /// nonisolated(unsafe)：deinit 需要访问；removeObserver 线程安全。
    private nonisolated(unsafe) var memoryPressureObserver: NSObjectProtocol?

    // MARK: - Internal State

    private var currentPage = 1
    private let pageSize = 20
    private var currentSearchTask: Task<Void, Never>?

    // MARK: - Initialization

    init() {
        // 注册内存压力通知
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

        // 监听 WorkshopSourceManager 的变化
        WorkshopSourceManager.shared.$activeSource
            .receive(on: DispatchQueue.main)
            .sink { [weak self] source in
                if source == .wallpaperEngine {
                    self?.resetAndLoad()
                }
            }
            .store(in: &cancellables)
    }

    deinit {
        if let observer = memoryPressureObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Public API

    /// 搜索壁纸
    func search(query: String? = nil) async {
        currentSearchTask?.cancel()

        let searchQuery = query ?? searchQuery

        await MainActor.run {
            isLoading = true
            errorMessage = nil
            wallpapers = []
            currentPage = 1
        }

        let params = WorkshopSearchParams(
            query: searchQuery,
            sortBy: selectedSort,
            page: 1,
            pageSize: pageSize,
            contentLevel: WorkshopSourceManager.WorkshopContentLevel.everyone.rawValue
        )

        do {
            let response = try await workshopService.search(params: params)
            await MainActor.run {
                wallpapers = response.items
                hasMorePages = response.hasMore
                isLoading = false
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    /// 加载更多
    func loadMore() async {
        guard hasMorePages, !isLoadingMore else { return }

        await MainActor.run {
            isLoadingMore = true
        }

        let params = WorkshopSearchParams(
            query: searchQuery,
            sortBy: selectedSort,
            page: currentPage + 1,
            pageSize: pageSize,
            contentLevel: WorkshopSourceManager.WorkshopContentLevel.everyone.rawValue
        )

        do {
            let response = try await workshopService.search(params: params)
            await MainActor.run {
                wallpapers.append(contentsOf: response.items)
                hasMorePages = response.hasMore
                currentPage = response.page
                isLoadingMore = false
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                isLoadingMore = false
            }
        }
    }

    /// 重置并加载
    func resetAndLoad() {
        wallpapers = []
        currentPage = 1
        hasMorePages = false
        errorMessage = nil

        Task {
            await search()
        }
    }

    /// 刷新当前搜索
    func refresh() async {
        await search()
    }

    // MARK: - Sorting

    func setSortOption(_ option: WorkshopSearchParams.SortOption) {
        guard selectedSort != option else { return }
        selectedSort = option
        Task {
            await search()
        }
    }

    // MARK: - 内存压力处理

    private func handleMemoryPressure() {
        print("[WorkshopViewModel] 内存压力，取消网络请求: wallpapers=\(wallpapers.count)")
        currentSearchTask?.cancel()
    }

    // MARK: - Download

    /// 下载壁纸
    func downloadWallpaper(_ wallpaper: WorkshopWallpaper) async throws -> URL {
        return try await workshopService.downloadWorkshopItem(workshopID: wallpaper.id)
    }

    // MARK: - Helpers

    func clearError() {
        errorMessage = nil
    }

    func cancelTasks() {
        currentSearchTask?.cancel()
    }
}
