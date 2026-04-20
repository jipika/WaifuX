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
    
    // MARK: - Internal State
    
    private var currentPage = 1
    private let pageSize = 20
    private var currentSearchTask: Task<Void, Never>?
    
    // MARK: - Initialization
    
    init() {
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
