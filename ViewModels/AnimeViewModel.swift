import Foundation
import SwiftUI

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

    // MARK: - 初始化

    func loadInitialData() async {
        isLoading = true
        defer { isLoading = false }

        do {
            // 加载所有可用规则
            let rules = await AnimeRuleStore.shared.loadAllRules()
            self.availableRules = rules.filter { !$0.deprecated }

            print("[AnimeViewModel] Loaded \(self.availableRules.count) rules")

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

    func fetchPopular() async {
        isLoading = true
        defer { isLoading = false }

        // 使用默认关键词搜索热门动漫
        let popularKeywords = ["热门", "新番", "推荐"]
        var allResults: [AnimeSearchResult] = []

        for keyword in popularKeywords {
            do {
                let rules = selectedRule.map { [$0] } ?? availableRules
                let results = try await AnimeParser.shared.search(query: keyword, rules: rules)
                allResults.append(contentsOf: results)

                if allResults.count >= 20 { break }
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
    case japan = "japan"
    case china = "china"
    case western = "western"
    case korea = "korea"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: return "全部"
        case .japan: return "日本"
        case .china: return "国产"
        case .western: return "欧美"
        case .korea: return "韩国"
        }
    }

    var icon: String {
        switch self {
        case .all: return "sparkles"
        case .japan: return "person.crop.rectangle.stack.fill"
        case .china: return "building.columns.fill"
        case .western: return "film.fill"
        case .korea: return "heart.fill"
        }
    }

    var accentColors: [String] {
        switch self {
        case .all: return ["5A7CFF", "20C1FF"]
        case .japan: return ["FF88C7", "7747FF"]
        case .china: return ["FF6B6B", "FF8E53"]
        case .western: return ["62D4FF", "4E66FF"]
        case .korea: return ["FFD66E", "FF8B3D"]
        }
    }
}

// MARK: - 热门标签

enum AnimeHotTag: String, CaseIterable, Identifiable {
    case popular = "popular"
    case new = "new"
    case classic = "classic"
    case movie = "movie"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .popular: return "热播"
        case .new: return "新番"
        case .classic: return "经典"
        case .movie: return "电影"
        }
    }
}
