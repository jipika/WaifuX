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
    @Published var hasMorePages = false
    @Published var errorMessage: String?
    @Published var searchText = ""
    @Published var selectedCategory: AnimeCategory = .all
    @Published var selectedHotTag: AnimeHotTag?

    // MARK: - 私有状态
    private var currentPage = 1
    private let pageSize = 24
    private var loadMoreTask: Task<Void, Never>?
    
    // Bangumi 服务
    private let bangumiService = BangumiService.shared

    // MARK: - 初始化

    func loadInitialData() async {
        isLoading = true
        defer { isLoading = false }

        // 重置分页状态
        currentPage = 1
        hasMorePages = true
        
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

        do {
            // 获取当前年份的动漫作为新番
            let calendar = Calendar.current
            let currentYear = calendar.component(.year, from: Date())
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

    func loadMore() async {
        loadMoreTask?.cancel()

        guard !isLoading, !isLoadingMore, hasMorePages else { return }

        loadMoreTask = Task {
            isLoadingMore = true
            defer { isLoadingMore = false }

            let offset = currentPage * pageSize
            
            do {
                let (items, total) = try await bangumiService.getTrendingList(
                    limit: pageSize,
                    offset: offset
                )
                
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    let newResults = items.map { $0.toAnimeSearchResult() }
                    self.animeItems.append(contentsOf: newResults)
                    currentPage += 1
                    self.hasMorePages = self.animeItems.count < (total ?? 0)
                    print("[AnimeViewModel] Loaded more, total: \(self.animeItems.count)")
                }
            } catch {
                print("[AnimeViewModel] Load more failed: \(error)")
            }
        }

        await loadMoreTask?.value
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
}
