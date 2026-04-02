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
        
        // 加载详情页需要的规则
        do {
            let rules = try await AnimeRuleStore.shared.loadRulesFromRemote()
            self.availableRules = rules.filter { !$0.deprecated }
            print("[AnimeViewModel] Loaded \(self.availableRules.count) rules for detail page")
        } catch {
            print("[AnimeViewModel] Failed to load rules: \(error)")
        }

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
        defer { isLoading = false }

        currentPage = 1
        
        do {
            let (items, total) = try await bangumiService.searchByTag(
                tag: searchText,
                limit: pageSize,
                offset: 0
            )
            
            await MainActor.run {
                self.animeItems = items.map { $0.toAnimeSearchResult() }
                self.featuredItem = self.animeItems.first
                self.hasMorePages = items.count < (total ?? 0)
            }

            print("[AnimeViewModel] Bangumi search found \(items.count) results for '\(searchText)'")
        } catch {
            print("[AnimeViewModel] Bangumi search failed: \(error)")
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - 按标签搜索

    func searchByTag(_ tag: AnimeHotTag) async {
        isLoading = true
        defer { isLoading = false }

        currentPage = 1

        do {
            // 将标签的 displayName 用作搜索关键词
            let (items, total) = try await bangumiService.searchByTag(
                tag: tag.rawValue,
                limit: pageSize,
                offset: 0
            )

            await MainActor.run {
                self.animeItems = items.map { $0.toAnimeSearchResult() }
                self.featuredItem = self.animeItems.first
                self.hasMorePages = items.count < (total ?? 0)
            }

            print("[AnimeViewModel] Bangumi tag search found \(items.count) results for tag '\(tag.displayName)'")
        } catch {
            print("[AnimeViewModel] Bangumi tag search failed: \(error)")
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - 获取热门 (使用 Bangumi)

    func fetchPopular(keyword: AnimeHotTag? = nil) async {
        isLoading = true
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
            let rules = try await AnimeRuleStore.shared.loadRulesFromRemote()
            self.availableRules = rules.filter { !$0.deprecated }
        } catch {
            print("[AnimeViewModel] Failed to reload rules: \(error)")
        }
    }
}

// MARK: - 动漫分类

enum AnimeCategory: String, CaseIterable, Identifiable {
    case all = "all"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: return "全部"
        }
    }

    var icon: String {
        switch self {
        case .all: return "sparkles"
        }
    }

    var accentColors: [String] {
        switch self {
        case .all: return ["5A7CFF", "20C1FF"]
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
        case .daily: return "日常"
        case .original: return "原创"
        case .school: return "校园"
        case .comedy: return "搞笑"
        case .fantasy: return "奇幻"
        case .yuri: return "百合"
        case .romance: return "恋爱"
        case .mystery: return "悬疑"
        case .action: return "热血"
        case .harem: return "后宫"
        case .mecha: return "机战"
        case .lightNovel: return "轻改"
        case .idol: return "偶像"
        case .healing: return "治愈"
        case .otherWorld: return "异世界"
        }
    }
}
