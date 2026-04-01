import Foundation
import SwiftUI

// MARK: - 通知名称

extension Notification.Name {
    static let animeRuleSourceChanged = Notification.Name("animeRuleSourceChanged")
}

// MARK: - 动漫 ViewModel

@MainActor
class AnimeViewModel: ObservableObject {
    // MARK: - 数据源
    @Published var availableRules: [AnimeRule] = []
    @Published var selectedRule: AnimeRule?

    // MARK: - 内容
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
    private var currentSearchKeyword: String = ""
    private var loadMoreTask: Task<Void, Never>?

    // MARK: - 初始化

    init() {
        // 监听规则源切换通知
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRuleSourceChanged),
            name: .animeRuleSourceChanged,
            object: nil
        )
    }

    @objc private func handleRuleSourceChanged() {
        Task {
            await reloadRules()
        }
    }

    // MARK: - 初始化

    func loadInitialData() async {
        isLoading = true
        defer { isLoading = false }

        // 重置分页状态
        currentPage = 1
        hasMorePages = false
        currentSearchKeyword = ""

        do {
            // 从远程加载所有可用规则
            let rules = try await AnimeRuleStore.shared.loadRulesFromRemote()
            self.availableRules = rules.filter { !$0.deprecated }

            print("[AnimeViewModel] Loaded \(self.availableRules.count) rules from remote")

            // 如果有规则，执行搜索获取数据
            if !self.availableRules.isEmpty {
                await search()
            } else {
                errorMessage = "没有可用的动漫源，请添加规则"
            }
        } catch {
            print("[AnimeViewModel] Failed to load rules: \(error)")
            errorMessage = error.localizedDescription
        }
    }

    /// 重新加载规则(切换规则源后调用)
    func reloadRules() async {
        await loadInitialData()
    }

    // MARK: - 搜索

    func search() async {
        guard !searchText.isEmpty else {
            // 如果搜索为空，获取热门内容
            await fetchPopular()
            return
        }

        isLoading = true
        defer { isLoading = false }

        // 重置分页状态
        currentPage = 1
        hasMorePages = false
        currentSearchKeyword = searchText

        do {
            let rules = selectedRule.map { [$0] } ?? availableRules
            let results = try await AnimeParser.shared.search(query: searchText, rules: rules, page: currentPage)

            await MainActor.run {
                self.animeItems = results
                self.featuredItem = results.first
                // 搜索结果暂时不支持分页，根据结果数量判断
                self.hasMorePages = results.count >= 20
            }

            print("[AnimeViewModel] Found \(results.count) results for '\(searchText)'")
        } catch {
            print("[AnimeViewModel] Search failed: \(error)")
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - 获取热门

    func fetchPopular(keyword: AnimeHotTag? = nil) async {
        isLoading = true
        defer { isLoading = false }

        // 重置分页状态
        currentPage = 1
        hasMorePages = true

        // 使用默认关键词或指定标签搜索
        let baseKeywords: [String]
        let searchKeyword: String
        switch keyword {
        case .none:
            baseKeywords = ["热门", "新番", "推荐", "完结"]
            searchKeyword = "热门"
        case .daily:
            baseKeywords = ["日常"]
            searchKeyword = "日常"
        case .original:
            baseKeywords = ["原创"]
            searchKeyword = "原创"
        case .school:
            baseKeywords = ["校园"]
            searchKeyword = "校园"
        case .comedy:
            baseKeywords = ["搞笑"]
            searchKeyword = "搞笑"
        case .fantasy:
            baseKeywords = ["奇幻"]
            searchKeyword = "奇幻"
        case .yuri:
            baseKeywords = ["百合"]
            searchKeyword = "百合"
        case .romance:
            baseKeywords = ["恋爱"]
            searchKeyword = "恋爱"
        case .mystery:
            baseKeywords = ["悬疑"]
            searchKeyword = "悬疑"
        case .action:
            baseKeywords = ["热血"]
            searchKeyword = "热血"
        case .harem:
            baseKeywords = ["后宫"]
            searchKeyword = "后宫"
        case .mecha:
            baseKeywords = ["机战"]
            searchKeyword = "机战"
        case .lightNovel:
            baseKeywords = ["轻改"]
            searchKeyword = "轻改"
        case .idol:
            baseKeywords = ["偶像"]
            searchKeyword = "偶像"
        case .healing:
            baseKeywords = ["治愈"]
            searchKeyword = "治愈"
        case .otherWorld:
            baseKeywords = ["异世界"]
            searchKeyword = "异世界"
        }

        // 设置当前搜索关键词用于分页
        self.currentSearchKeyword = searchKeyword

        var allResults: [AnimeSearchResult] = []

        for baseKeyword in baseKeywords {
            do {
                let rules = selectedRule.map { [$0] } ?? availableRules
                let results = try await AnimeParser.shared.search(query: baseKeyword, rules: rules, page: currentPage)
                allResults.append(contentsOf: results)

                if allResults.count >= 30 { break }
            } catch {
                continue
            }
        }

        // 去重
        var seenIDs = Set<String>()
        let uniqueResults = allResults.filter { result in
            if seenIDs.contains(result.id) {
                return false
            }
            seenIDs.insert(result.id)
            return true
        }

        await MainActor.run {
            self.animeItems = uniqueResults
            self.featuredItem = uniqueResults.first
            // 如果获取到了较多结果，认为还有下一页
            self.hasMorePages = uniqueResults.count >= 20
        }
    }

    // MARK: - 加载更多（分页）

    func loadMore() async {
        loadMoreTask?.cancel()

        guard !isLoading, !isLoadingMore, hasMorePages else { return }

        loadMoreTask = Task {
            isLoadingMore = true
            defer { isLoadingMore = false }

            currentPage += 1
            print("[AnimeViewModel] 加载第 \(currentPage) 页...")

            // 使用当前搜索关键词或默认关键词
            let keyword = currentSearchKeyword.isEmpty ? "热门" : currentSearchKeyword

            do {
                let rules = selectedRule.map { [$0] } ?? availableRules
                let results = try await AnimeParser.shared.search(query: keyword, rules: rules, page: currentPage)

                // 检查任务是否被取消
                guard !Task.isCancelled else { return }

                // 过滤已存在的结果
                let existingIDs = Set(self.animeItems.map { $0.id })
                let newResults = results.filter { !existingIDs.contains($0.id) }

                await MainActor.run {
                    if !newResults.isEmpty {
                        self.animeItems.append(contentsOf: newResults)
                        print("[AnimeViewModel] 新增 \(newResults.count) 条数据，总计 \(self.animeItems.count)")
                    }

                    // 如果没有新数据或结果太少，认为没有更多页面了
                    self.hasMorePages = !results.isEmpty && results.count >= 10

                    if !self.hasMorePages {
                        print("[AnimeViewModel] 没有更多数据了")
                    }
                }
            } catch {
                print("[AnimeViewModel] 加载更多失败: \(error)")
                currentPage -= 1 // 回退页码
            }
        }

        await loadMoreTask?.value
    }

    // MARK: - 获取详情

    func fetchDetail(for item: AnimeSearchResult) async throws -> AnimeDetail {
        guard let rule = availableRules.first(where: { $0.id == item.sourceId }) else {
            throw AnimeParserError.noRulesAvailable
        }

        return try await AnimeParser.shared.fetchDetail(detailURL: item.detailURL, rule: rule)
    }

    // MARK: - 取消加载

    func cancelLoadMore() {
        loadMoreTask?.cancel()
        loadMoreTask = nil
        isLoadingMore = false
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

// MARK: - 动漫标签（参考 Kazumi）

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
