import Foundation
import SwiftUI

// MARK: - 动漫 ViewModel

@MainActor
class AnimeViewModel: ObservableObject {
    // MARK: - 数据源 (详情页使用)
    @Published var availableRules: [AnimeRule] = []
    @Published var selectedRule: AnimeRule?

    // MARK: - 内容 (列表页使用 Bangumi)
    @Published var animeItems: [AnimeSearchResult] = []
    @Published var featuredItem: AnimeSearchResult?

    // MARK: - 分页状态
    @Published var isLoading = false
    @Published var isLoadingMore = false
    @Published var hasMorePages = true
    @Published var errorMessage: String?
    @Published var searchText = ""
    @Published var selectedCategory: AnimeCategory = .all
    @Published var selectedHotTag: AnimeHotTag?

    // MARK: - 查询模式追踪
    enum QueryMode: Equatable {
        case trending
        case search(keyword: String)
        case tag(tagName: String)
        case topRated
        case newArrivals(year: String)
    }
    private var currentQueryMode: QueryMode = .trending

    // MARK: - 私有状态
    private var currentPage = 1
    private let pageSize = 10
    private var loadMoreTask: Task<Void, Never>?
    
    // MARK: - 预加载支持
    private var preloadTask: Task<Void, Never>?
    private var preloadedItems: [BangumiSubject] = []
    private var preloadedTotal: Int = 0
    private var isPreloaded = false
    
    // Bangumi 服务
    private let bangumiService = BangumiService.shared

    // MARK: - 初始化

    func loadInitialData() async {
        isLoading = true
        defer { isLoading = false }

        // 重置分页状态
        currentPage = 1
        hasMorePages = true
        currentQueryMode = .trending
        invalidatePreload()
        
        // 先读本地缓存；若无则全量从 Kazumi 拉取并覆盖落盘（与启动后台同步策略一致）
        var rules = await AnimeRuleStore.shared.loadAllRules()
        if rules.isEmpty {
            await AnimeRuleStore.shared.ensureDefaultRulesCopied()
            rules = await AnimeRuleStore.shared.loadAllRules()
        }
        self.availableRules = rules
        print("[AnimeViewModel] 详情页可用规则: \(self.availableRules.count) 个")

        // 加载列表页数据 (使用 Bangumi)
        await fetchPopular()
    }

    // MARK: - 搜索 (使用 Bangumi)

    func search() async {
        guard !searchText.isEmpty else {
            await fetchPopular()
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        currentPage = 1
        currentQueryMode = .search(keyword: searchText)
        invalidatePreload()
        
        do {
            // 使用关键词搜索而不是标签搜索
            let (items, total) = try await bangumiService.searchByKeyword(
                keyword: searchText,
                limit: pageSize,
                offset: 0
            )
            
            await MainActor.run {
                self.animeItems = items.map { $0.toAnimeSearchResult() }
                self.featuredItem = self.animeItems.first
                self.hasMorePages = items.count < (total ?? 0)
                print("[AnimeViewModel] Search updated animeItems with \(self.animeItems.count) items")
            }

            print("[AnimeViewModel] Bangumi search found \(items.count) results for '\(searchText)'")
        } catch {
            print("[AnimeViewModel] Bangumi search failed: \(error)")
            errorMessage = error.localizedDescription
            await MainActor.run {
                self.animeItems = []
            }
        }
    }

    // MARK: - 按标签搜索 (使用中文标签名)

    func searchByTagName(_ tagName: String) async {
        print("[AnimeViewModel] Starting tag search for: \(tagName)")
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        currentPage = 1
        currentQueryMode = .tag(tagName: tagName)
        invalidatePreload()

        do {
            // 直接使用中文标签名进行搜索
            let (items, total) = try await bangumiService.searchByTag(
                tag: tagName,
                limit: pageSize,
                offset: 0
            )
            
            print("[AnimeViewModel] API returned \(items.count) items for tag '\(tagName)'")

            await MainActor.run {
                let newItems = items.map { $0.toAnimeSearchResult() }
                self.animeItems = newItems
                self.featuredItem = newItems.first
                self.hasMorePages = newItems.count < (total ?? 0)
                print("[AnimeViewModel] Updated animeItems with \(newItems.count) items")
            }
        } catch {
            print("[AnimeViewModel] Bangumi tag search failed: \(error)")
            errorMessage = error.localizedDescription
            await MainActor.run {
                self.animeItems = []
            }
        }
    }

    // MARK: - 获取热门 (使用 Bangumi)

    func fetchPopular(keyword: AnimeHotTag? = nil) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        currentPage = 1
        hasMorePages = true
        currentQueryMode = .trending
        invalidatePreload()

        do {
            let (items, total) = try await bangumiService.getTrendingList(
                limit: pageSize,
                offset: 0
            )
            
            await MainActor.run {
                self.animeItems = items.map { $0.toAnimeSearchResult() }
                self.featuredItem = self.animeItems.first
                self.hasMorePages = items.count < (total ?? 0)
            }
            
            print("[AnimeViewModel] Bangumi trending loaded \(items.count) items")
        } catch {
            print("[AnimeViewModel] Bangumi trending failed: \(error)")
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - 按分类获取

    func fetchByCategory(_ category: AnimeCategory) async {
        selectedCategory = category
        
        switch category {
        case .all:
            await fetchPopular()
        case .trending:
            await fetchPopular()
        case .topRated:
            await fetchTopRated()
        case .newArrivals:
            await fetchNewArrivals()
        }
    }

    // MARK: - 获取高分动漫

    private func fetchTopRated() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        currentPage = 1
        currentQueryMode = .topRated
        invalidatePreload()

        do {
            // 使用 trending 接口获取数据，然后按评分排序
            let (items, total) = try await bangumiService.getTrendingList(
                limit: pageSize * 2,  // 获取更多数据以便排序
                offset: 0
            )
            
            // 过滤并排序获取高评分动漫
            let sortedItems = items
                .filter { ($0.rating?.score ?? 0) > 0 }
                .sorted { ($0.rating?.score ?? 0) > ($1.rating?.score ?? 0) }
                .prefix(pageSize)  // 只取前 pageSize 个
            
            await MainActor.run {
                self.animeItems = Array(sortedItems).map { $0.toAnimeSearchResult() }
                self.featuredItem = self.animeItems.first
                self.hasMorePages = items.count < (total ?? 0)
            }
            
            print("[AnimeViewModel] Top rated loaded \(sortedItems.count) items")
        } catch {
            print("[AnimeViewModel] Top rated fetch failed: \(error)")
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - 获取新番

    private func fetchNewArrivals() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        currentPage = 1
        let calendar = Calendar.current
        let currentYear = calendar.component(.year, from: Date())
        currentQueryMode = .newArrivals(year: String(currentYear))
        invalidatePreload()

        do {
            // 获取当前年份的动漫作为新番
            let (items, total) = try await bangumiService.searchByKeyword(
                keyword: String(currentYear),
                limit: pageSize,
                offset: 0
            )
            
            await MainActor.run {
                self.animeItems = items.map { $0.toAnimeSearchResult() }
                self.featuredItem = self.animeItems.first
                self.hasMorePages = items.count < (total ?? 0)
            }
            
            print("[AnimeViewModel] New arrivals loaded \(items.count) items")
        } catch {
            print("[AnimeViewModel] New arrivals fetch failed: \(error)")
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - 加载更多 (分页)

    private var isLoadMoreInProgress = false

    func loadMore() async {
        // 防止重复调用
        guard !isLoading, !isLoadingMore, hasMorePages, !isLoadMoreInProgress else { return }

        isLoadMoreInProgress = true
        defer { 
            isLoadMoreInProgress = false
            // 加载完成后触发预加载
            if hasMorePages {
                triggerPreloadNextPage()
            }
        }

        loadMoreTask?.cancel()

        loadMoreTask = Task {
            isLoadingMore = true
            defer { isLoadingMore = false }

            let nextPage = currentPage + 1
            
            do {
                let items: [BangumiSubject]
                let total: Int?
                
                // 检查是否有预加载的数据（仅 trending 模式支持预加载）
                if currentQueryMode == .trending, isPreloaded, !preloadedItems.isEmpty {
                    print("[AnimeViewModel] Using preloaded page \(nextPage)")
                    items = preloadedItems
                    total = preloadedTotal
                    preloadedItems = []
                    isPreloaded = false
                } else {
                    // 根据当前查询模式调用不同 API
                    let offset = currentPage * pageSize
                    (items, total) = try await fetchPageData(offset: offset)
                }
                
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    let newResults = items.map { $0.toAnimeSearchResult() }
                    guard !newResults.isEmpty else {
                        self.hasMorePages = false
                        return
                    }
                    self.animeItems.append(contentsOf: newResults)
                    self.currentPage = nextPage
                    self.hasMorePages = self.animeItems.count < (total ?? 0)
                    print("[AnimeViewModel] Loaded more (mode: \(currentQueryMode)), total: \(self.animeItems.count)")
                }
            } catch {
                print("[AnimeViewModel] Load more failed: \(error)")
            }
        }

        await loadMoreTask?.value
    }

    // MARK: - 根据查询模式获取分页数据

    private func fetchPageData(offset: Int) async throws -> (items: [BangumiSubject], total: Int?) {
        switch currentQueryMode {
        case .trending:
            return try await bangumiService.getTrendingList(limit: pageSize, offset: offset)
        case .search(let keyword):
            return try await bangumiService.searchByKeyword(keyword: keyword, limit: pageSize, offset: offset)
        case .tag(let tagName):
            return try await bangumiService.searchByTag(tag: tagName, limit: pageSize, offset: offset)
        case .topRated:
            return try await bangumiService.getTrendingList(limit: pageSize, offset: offset)
        case .newArrivals(let year):
            return try await bangumiService.searchByKeyword(keyword: year, limit: pageSize, offset: offset)
        }
    }

    /// 清空预加载数据（切换查询模式时调用）
    private func invalidatePreload() {
        preloadTask?.cancel()
        preloadedItems = []
        preloadedTotal = 0
        isPreloaded = false
    }
    
    // MARK: - 预加载下一页
    private func triggerPreloadNextPage() {
        preloadTask?.cancel()
        
        let nextPage = currentPage + 1
        let offset = currentPage * pageSize
        let mode = currentQueryMode
        
        preloadTask = Task(priority: .low) {
            // 延迟一下再开始预加载
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5秒
            
            guard !Task.isCancelled else { return }
            
            do {
                print("[AnimeViewModel] Preloading page \(nextPage) (mode: \(mode))...")
                let (items, total) = try await fetchPageData(offset: offset)
                
                guard !Task.isCancelled else { return }
                
                // 存储预加载的数据
                preloadedItems = items
                preloadedTotal = total ?? 0
                isPreloaded = true
                print("[AnimeViewModel] Preloaded page \(nextPage) with \(items.count) items")
            } catch {
                print("[AnimeViewModel] Preload failed: \(error)")
            }
        }
    }

    // MARK: - 获取详情 (使用规则源)

    func fetchDetail(for item: AnimeSearchResult) async throws -> AnimeDetail {
        guard let rule = availableRules.first(where: { $0.id == item.sourceId }) else {
            throw AnimeParserError.noRulesAvailable
        }

        return try await AnimeParser.shared.fetchDetail(detailURL: item.detailURL, rule: rule)
    }
    
    // MARK: - 重新加载规则
    
    func reloadRules() async {
        do {
            try await AnimeRuleStore.shared.replaceAllRulesFromKazumiRemote()
            self.availableRules = await AnimeRuleStore.shared.loadAllRules()
        } catch {
            print("[AnimeViewModel] Kazumi 全量同步失败，保留当前缓存: \(error)")
            self.availableRules = await AnimeRuleStore.shared.loadAllRules()
        }
    }
}

// MARK: - 动漫分类

enum AnimeCategory: String, CaseIterable, Identifiable {
    case all = "all"
    case trending = "trending"
    case topRated = "topRated"
    case newArrivals = "newArrivals"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: return LocalizationService.shared.t("anime.all")
        case .trending: return LocalizationService.shared.t("anime.trending")
        case .topRated: return LocalizationService.shared.t("anime.topRated")
        case .newArrivals: return LocalizationService.shared.t("anime.newArrivals")
        }
    }

    var icon: String {
        switch self {
        case .all: return "sparkles"
        case .trending: return "flame"
        case .topRated: return "star.fill"
        case .newArrivals: return "calendar"
        }
    }

    var accentColors: [String] {
        switch self {
        case .all: return ["5A7CFF", "20C1FF"]
        case .trending: return ["FF6B35", "F7931E"]
        case .topRated: return ["FFD700", "FFA500"]
        case .newArrivals: return ["00C9A7", "00D9FF"]
        }
    }
}

// MARK: - 动漫标签

enum AnimeHotTag: String, CaseIterable, Identifiable {
    case daily = "daily"
    case original = "original"
    case school = "school"
    case comedy = "comedy"
    case fantasy = "fantasy"
    case yuri = "yuri"
    case romance = "romance"
    case mystery = "mystery"
    case action = "action"
    case harem = "harem"
    case mecha = "mecha"
    case lightNovel = "lightNovel"
    case idol = "idol"
    case healing = "healing"
    case otherWorld = "otherWorld"

    var id: String { rawValue }

    /// 界面显示的中文标签名
    var displayName: String {
        switch self {
        case .daily: return LocalizationService.shared.t("animeTag.daily")
        case .original: return LocalizationService.shared.t("animeTag.original")
        case .school: return LocalizationService.shared.t("animeTag.school")
        case .comedy: return LocalizationService.shared.t("animeTag.comedy")
        case .fantasy: return LocalizationService.shared.t("animeTag.fantasy")
        case .yuri: return LocalizationService.shared.t("animeTag.yuri")
        case .romance: return LocalizationService.shared.t("animeTag.romance")
        case .mystery: return LocalizationService.shared.t("animeTag.mystery")
        case .action: return LocalizationService.shared.t("animeTag.action")
        case .harem: return LocalizationService.shared.t("animeTag.harem")
        case .mecha: return LocalizationService.shared.t("animeTag.mecha")
        case .lightNovel: return LocalizationService.shared.t("animeTag.lightNovel")
        case .idol: return LocalizationService.shared.t("animeTag.idol")
        case .healing: return LocalizationService.shared.t("animeTag.healing")
        case .otherWorld: return LocalizationService.shared.t("animeTag.otherWorld")
        }
    }
    
    /// Bangumi API 使用的英文/日文标签名
    var apiTagName: String {
        switch self {
        case .daily: return "日常"
        case .original: return "原创"
        case .school: return "校园"
        case .comedy: return "喜剧"
        case .fantasy: return "奇幻"
        case .yuri: return "百合"
        case .romance: return "爱情"
        case .mystery: return "悬疑"
        case .action: return "动作"
        case .harem: return "后宫"
        case .mecha: return "机战"
        case .lightNovel: return "轻小说改"
        case .idol: return "偶像"
        case .healing: return "治愈"
        case .otherWorld: return "异世界"
        }
    }
}
