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

    // MARK: - 状态
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var searchText = ""
    @Published var selectedCategory: AnimeCategory = .all
    @Published var selectedHotTag: AnimeHotTag?
    
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

        do {
            let rules = selectedRule.map { [$0] } ?? availableRules
            let results = try await AnimeParser.shared.search(query: searchText, rules: rules)

            await MainActor.run {
                self.animeItems = results
                self.featuredItem = results.first
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

        // 使用默认关键词或指定标签搜索
        let baseKeywords: [String]
        switch keyword {
        case .none:
            baseKeywords = ["热门", "新番", "推荐", "完结"]
        case .daily:
            baseKeywords = ["日常"]
        case .original:
            baseKeywords = ["原创"]
        case .school:
            baseKeywords = ["校园"]
        case .comedy:
            baseKeywords = ["搞笑"]
        case .fantasy:
            baseKeywords = ["奇幻"]
        case .yuri:
            baseKeywords = ["百合"]
        case .romance:
            baseKeywords = ["恋爱"]
        case .mystery:
            baseKeywords = ["悬疑"]
        case .action:
            baseKeywords = ["热血"]
        case .harem:
            baseKeywords = ["后宫"]
        case .mecha:
            baseKeywords = ["机战"]
        case .lightNovel:
            baseKeywords = ["轻改"]
        case .idol:
            baseKeywords = ["偶像"]
        case .healing:
            baseKeywords = ["治愈"]
        case .otherWorld:
            baseKeywords = ["异世界"]
        }

        var allResults: [AnimeSearchResult] = []

        for baseKeyword in baseKeywords {
            do {
                let rules = selectedRule.map { [$0] } ?? availableRules
                let results = try await AnimeParser.shared.search(query: baseKeyword, rules: rules)
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
        }
    }

    // MARK: - 获取详情

    func fetchDetail(for item: AnimeSearchResult) async throws -> AnimeDetail {
        guard let rule = availableRules.first(where: { $0.id == item.sourceId }) else {
            throw AnimeParserError.noRulesAvailable
        }

        return try await AnimeParser.shared.fetchDetail(detailURL: item.detailURL, rule: rule)
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
