import SwiftUI

// MARK: - 猜你喜欢推荐服务

/// 每日推荐引擎 — 从各数据源均衡取样，并用本地库偏好调整每个源内部的查询。
@MainActor
final class GuessYouLikeService {
    static let shared = GuessYouLikeService()

    private let defaults = WaifuXPreferences.shared
    private let lastUpdateKey = "gyl_lastUpdate"
    private let cachedItemsKey = "gyl_cachedItems"
    private let cacheVersionKey = "gyl_cacheVersion"
    private let currentCacheVersion = 3
    private let targetCount = 12
    private let primaryItemsPerSource = 2
    private let sourceFetchCount = 8

    private init() {}

    // MARK: - 公开接口

    func getRecommendations() async -> [GuessYouLikeItem] {
        await refresh()
    }

    func forceRefresh() async -> [GuessYouLikeItem] { await refresh() }

    // MARK: - 缓存

    private func shouldRefresh() -> Bool {
        if defaults.integer(forKey: cacheVersionKey) != currentCacheVersion { return true }
        guard let last = defaults.object(forKey: lastUpdateKey) as? Date else { return true }
        return Date().timeIntervalSince(last) > 24 * 3600
    }

    private func refresh() async -> [GuessYouLikeItem] {
        await generate()
    }

    private func loadCached() -> [GuessYouLikeItem]? {
        guard let data = defaults.data(forKey: cachedItemsKey) else { return nil }
        return try? JSONDecoder().decode([GuessYouLikeItem].self, from: data)
    }

    // MARK: - 生成推荐（多源均衡）

    private func generate() async -> [GuessYouLikeItem] {
        let preferences = makePreferenceSnapshot()

        async let wh = fetchWallhaven(count: sourceFetchCount, preferences: preferences)
        async let fk = fetch4K(count: sourceFetchCount, preferences: preferences)
        async let mb = fetchMotionBG(count: sourceFetchCount, preferences: preferences)
        async let ws = fetchWorkshop(count: sourceFetchCount, preferences: preferences)
        async let dt = fetchDongTai(count: sourceFetchCount, preferences: preferences)
        async let wf = fetchWallsflow(count: sourceFetchCount, preferences: preferences)

        let buckets = await [
            SourceBucket(.wallhaven, wh),
            SourceBucket(.fourK, fk),
            SourceBucket(.motionBG, mb),
            SourceBucket(.workshop, ws),
            SourceBucket(.dongtai, dt),
            SourceBucket(.wallsflow, wf),
        ].sorted { lhs, rhs in
            preferences.sourceScore(for: lhs.source) > preferences.sourceScore(for: rhs.source)
        }

        var selected = balancedSelection(from: buckets, targetCount: targetCount)

        if selected.count < targetCount {
            let missing = targetCount - selected.count
            async let whExtra = fetchWallhaven(count: missing + 2, preferences: preferences)
            async let mbExtra = fetchMotionBG(count: missing + 2, preferences: preferences)
            async let wfExtra = fetchWallsflow(count: missing + 2, preferences: preferences)
            let fallback = await [
                SourceBucket(.wallhaven, whExtra),
                SourceBucket(.motionBG, mbExtra),
                SourceBucket(.wallsflow, wfExtra),
            ]
            selected = mergeUnique(selected, balancedSelection(from: fallback, targetCount: missing), limit: targetCount)
        }

        return Array(selected.prefix(targetCount)).shuffled()
    }

    private func balancedSelection(from buckets: [SourceBucket], targetCount: Int) -> [GuessYouLikeItem] {
        var selected: [GuessYouLikeItem] = []
        var seen = Set<String>()

        @discardableResult
        func appendUnique(_ item: GuessYouLikeItem) -> Bool {
            guard selected.count < targetCount else { return false }
            let key = item.deduplicationKey
            guard seen.insert(key).inserted else { return false }
            selected.append(item)
            return true
        }

        // 每个桶内随机打乱，使每次选取的条目不同
        for bucket in buckets {
            for item in bucket.items.shuffled().prefix(primaryItemsPerSource) {
                appendUnique(item)
            }
        }

        var remainders = buckets.map { Array($0.items.shuffled().dropFirst(primaryItemsPerSource)) }
        while selected.count < targetCount {
            var added = false
            for index in remainders.indices where !remainders[index].isEmpty {
                let item = remainders[index].removeFirst()
                added = appendUnique(item) || added
                if selected.count >= targetCount { break }
            }
            if !added { break }
        }

        return selected
    }

    private func mergeUnique(_ base: [GuessYouLikeItem], _ extra: [GuessYouLikeItem], limit: Int) -> [GuessYouLikeItem] {
        var merged: [GuessYouLikeItem] = []
        var seen = Set<String>()
        for item in base + extra {
            guard merged.count < limit else { break }
            guard seen.insert(item.deduplicationKey).inserted else { continue }
            merged.append(item)
        }
        return merged
    }

    // MARK: - 偏好分析

    private enum RecommendationSource: String, CaseIterable {
        case wallhaven
        case fourK
        case motionBG
        case workshop
        case dongtai
        case wallsflow

        var displayName: String {
            switch self {
            case .wallhaven: return "WallHaven"
            case .fourK: return "4K Wallpapers"
            case .motionBG: return "MotionBG"
            case .workshop: return "Wallpaper Engine"
            case .dongtai: return "DongTai"
            case .wallsflow: return "Wallsflow"
            }
        }
    }

    private struct SourceBucket {
        let source: RecommendationSource
        let items: [GuessYouLikeItem]

        init(_ source: RecommendationSource, _ items: [GuessYouLikeItem]) {
            self.source = source
            self.items = items
        }
    }

    private struct PreferenceSnapshot {
        let allTags: [String]
        let staticTags: [String]
        let videoTags: [String]
        let sourceScores: [RecommendationSource: Double]
        let wallhavenCategoryMask: String
        let wallhavenPurityMask: String
        let wallhavenRatios: [String]
        let wallhavenColors: [String]
        let excludedWallpaperIDs: Set<String>

        func sourceScore(for source: RecommendationSource) -> Double {
            sourceScores[source, default: 0]
        }
    }

    private func makePreferenceSnapshot() -> PreferenceSnapshot {
        var allScores: [String: Double] = [:]
        var staticScores: [String: Double] = [:]
        var videoScores: [String: Double] = [:]
        var sourceScores: [RecommendationSource: Double] = [:]
        var wallhavenCategoryScores: [String: Double] = [:]
        var wallhavenPurityScores: [String: Double] = [:]
        var wallhavenRatioScores: [String: Double] = [:]
        var wallhavenColorScores: [String: Double] = [:]
        var excludedWallpaperIDs = Set<String>()

        func addTag(_ raw: String?, weight: Double, toStatic: Bool, toVideo: Bool) {
            guard let term = normalizedPreferenceTerm(raw) else { return }
            allScores[term, default: 0] += weight
            if toStatic {
                staticScores[term, default: 0] += weight
            }
            if toVideo {
                videoScores[term, default: 0] += weight
            }
        }

        func addWallpaper(_ wallpaper: Wallpaper, weight: Double) {
            let source = wallpaperRecommendationSource(wallpaper)
            sourceScores[source, default: 0] += weight
            addTag(wallpaper.primaryTagName, weight: weight, toStatic: true, toVideo: false)
            addTag(wallpaper.category, weight: weight * 0.7, toStatic: true, toVideo: false)
            for tag in wallpaper.tags ?? [] {
                addTag(tag.name, weight: weight * 0.6, toStatic: true, toVideo: false)
            }

            if source == .wallhaven {
                excludedWallpaperIDs.insert(wallpaper.id)
            }
            wallhavenCategoryScores[wallpaper.category.lowercased(), default: 0] += weight
            wallhavenPurityScores[wallpaper.purity.lowercased(), default: 0] += weight
            if let ratio = wallhavenRatioLabel(for: wallpaper) {
                wallhavenRatioScores[ratio, default: 0] += weight
            }
            for color in wallpaper.normalizedColorHexes.prefix(3) where WallhavenAPI.colorPreset(for: color) != nil {
                wallhavenColorScores[color.lowercased(), default: 0] += weight
            }
        }

        func addMedia(_ item: MediaItem, weight: Double) {
            sourceScores[mediaRecommendationSource(item), default: 0] += weight
            addTag(item.collectionTitle, weight: weight * 0.9, toStatic: false, toVideo: true)
            addTag(item.sourceName, weight: weight * 0.25, toStatic: false, toVideo: true)
            for tag in item.tags {
                addTag(tag, weight: weight, toStatic: false, toVideo: true)
            }
        }

        for record in WallpaperLibraryService.shared.favoriteRecords where record.isActive {
            addWallpaper(record.wallpaper, weight: 5)
        }
        for record in WallpaperLibraryService.shared.downloadedWallpapers {
            addWallpaper(record.wallpaper, weight: 4)
        }
        for record in MediaLibraryService.shared.favoriteRecords where record.isActive {
            addMedia(record.item, weight: 5)
        }
        for record in MediaLibraryService.shared.downloadedItems {
            addMedia(record.item, weight: 4)
        }
        for item in MediaLibraryService.shared.recentItems.prefix(20) {
            addMedia(item, weight: 1)
        }
        for (_, anime) in AnimeFavoriteStore.shared.favorites {
            for tag in anime.tags {
                addTag(tag, weight: 3, toStatic: true, toVideo: true)
            }
            addTag("anime", weight: 2, toStatic: true, toVideo: true)
            sourceScores[.wallhaven, default: 0] += 1
            sourceScores[.fourK, default: 0] += 1
            sourceScores[.workshop, default: 0] += 1
        }

        return PreferenceSnapshot(
            allTags: rankedTerms(allScores),
            staticTags: rankedTerms(staticScores),
            videoTags: rankedTerms(videoScores),
            sourceScores: sourceScores,
            wallhavenCategoryMask: wallhavenCategoryMask(from: wallhavenCategoryScores),
            wallhavenPurityMask: wallhavenPurityMask(from: wallhavenPurityScores),
            wallhavenRatios: rankedTerms(wallhavenRatioScores, limit: 2),
            wallhavenColors: rankedTerms(wallhavenColorScores, limit: 1),
            excludedWallpaperIDs: excludedWallpaperIDs
        )
    }

    private func rankedTerms(_ scores: [String: Double], limit: Int = 6) -> [String] {
        scores.sorted {
            if $0.value == $1.value { return $0.key < $1.key }
            return $0.value > $1.value
        }
        .prefix(limit)
        .map(\.key)
    }

    private func normalizedPreferenceTerm(_ raw: String?) -> String? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !text.isEmpty else {
            return nil
        }
        text = text.replacingOccurrences(of: "_", with: " ")
        text = text.replacingOccurrences(of: "-", with: " ")
        for suffix in [" live wallpapers", " wallpapers", " wallpaper"] where text.hasSuffix(suffix) {
            text.removeLast(suffix.count)
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let ignored: Set<String> = ["", "wallpaper", "wallpapers", "live", "video", "dynamic", "sfw", "general", "motionbg", "motionbgs"]
        return ignored.contains(text) ? nil : text
    }

    private func mappedValue<T>(for tags: [String], candidates: [(String, T)]) -> T? {
        for tag in tags {
            let normalized = tag.lowercased()
            if let direct = candidates.first(where: { $0.0 == normalized }) {
                return direct.1
            }
            if let fuzzy = candidates.first(where: { normalized.contains($0.0) }) {
                return fuzzy.1
            }
        }
        return nil
    }

    private func wallhavenQuery(for preferences: PreferenceSnapshot) -> String {
        let usefulTags = preferences.staticTags
            .filter(isUsefulWallhavenTag)
        guard !usefulTags.isEmpty else { return "" }
        // 随机选择 1-2 个标签，起点随机，使每次查询不同
        let maxStart = max(0, usefulTags.count - 2)
        let start = Int.random(in: 0...maxStart)
        let take = min(Int.random(in: 1...2), usefulTags.count - start)
        return Array(usefulTags[start..<start + take]).joined(separator: " ")
    }

    private func isUsefulWallhavenTag(_ tag: String) -> Bool {
        let noisyTerms: Set<String> = [
            "art", "digital art", "illustration", "background", "desktop",
            "hd", "4k", "8k", "girl", "girls", "woman", "women", "man",
            "person", "people", "cute", "beautiful", "wallhaven"
        ]
        guard tag.count >= 3, !noisyTerms.contains(tag) else { return false }
        return !tag.contains("wallpaper")
    }

    private func wallhavenCategoryMask(from scores: [String: Double]) -> String {
        guard let topScore = scores.values.max(), topScore > 0 else { return "111" }
        let threshold = max(1, topScore * 0.45)
        let general = scores["general", default: 0] >= threshold
        let anime = scores["anime", default: 0] >= threshold
        let people = scores["people", default: 0] >= threshold
        let mask = "\(general ? 1 : 0)\(anime ? 1 : 0)\(people ? 1 : 0)"
        return mask == "000" ? "111" : mask
    }

    private func wallhavenPurityMask(from scores: [String: Double]) -> String {
        guard let topScore = scores.values.max(), topScore > 0 else { return "100" }
        let sketchyPreferred = scores["sketchy", default: 0] >= topScore * 0.5
        // 推荐卡片默认不引入 NSFW；后续如果接入用户显式内容级别设置，再放开第三位。
        return sketchyPreferred ? "110" : "100"
    }

    private func wallhavenRatioLabel(for wallpaper: Wallpaper) -> String? {
        guard let ratio = wallpaper.aspectRatioValue else { return nil }
        let candidates: [(String, Double)] = [
            ("16x9", 16.0 / 9.0),
            ("16x10", 16.0 / 10.0),
            ("21x9", 21.0 / 9.0),
            ("32x9", 32.0 / 9.0),
            ("48x9", 48.0 / 9.0),
            ("9x16", 9.0 / 16.0),
            ("10x16", 10.0 / 16.0),
        ]
        return candidates.min { lhs, rhs in
            abs(lhs.1 - ratio) < abs(rhs.1 - ratio)
        }
        .flatMap { abs($0.1 - ratio) <= 0.08 ? $0.0 : nil }
    }

    private func fourKCategoryID(for preferences: PreferenceSnapshot) -> String? {
        mappedValue(for: preferences.staticTags + preferences.allTags, candidates: [
            ("anime", "anime"), ("nature", "nature"), ("games", "games"),
            ("game", "games"), ("fantasy", "fantasy"), ("space", "space"),
            ("car", "cars"), ("cars", "cars"), ("music", "music"),
            ("movie", "movies"), ("movies", "movies"), ("city", "architecture"),
            ("architecture", "architecture"), ("animal", "animals"), ("animals", "animals"),
            ("food", "food"), ("technology", "technology"), ("minimal", "minimal"),
            ("minimalist", "minimal"),
        ])
    }

    private func motionBGTag(for preferences: PreferenceSnapshot) -> String? {
        mappedValue(for: preferences.videoTags + preferences.allTags, candidates: [
            ("anime", "anime"), ("nature", "nature"), ("game", "game"),
            ("games", "game"), ("cyberpunk", "cyberpunk"), ("rain", "rain"),
            ("dark", "dark"), ("fantasy", "fantasy"), ("space", "space"),
            ("city", "city"),
        ])
    }

    private func workshopTags(for preferences: PreferenceSnapshot) -> [String] {
        let candidates: [(String, String)] = [
            ("anime", "Anime"), ("nature", "Nature"), ("game", "Game"),
            ("games", "Game"), ("fantasy", "Fantasy"), ("cyberpunk", "Cyberpunk"),
            ("space", "Sci-Fi"), ("scifi", "Sci-Fi"), ("car", "Vehicle"),
            ("cars", "Vehicle"),
        ]
        var result: [String] = []
        for tag in preferences.videoTags + preferences.allTags {
            if let mapped = mappedValue(for: [tag], candidates: candidates), !result.contains(mapped) {
                result.append(mapped)
            }
        }
        return Array(result.prefix(3))
    }

    private func dongtaiCategories(for preferences: PreferenceSnapshot) -> Set<DynamicWallpaperCategory> {
        let candidates: [(String, DynamicWallpaperCategory)] = [
            ("anime", .anime), ("game", .game), ("games", .game),
            ("nature", .nature), ("fantasy", .scifi), ("space", .scifi),
            ("sci fi", .scifi), ("music", .visualMusic),
        ]
        let mapped = (preferences.videoTags + preferences.allTags).compactMap {
            mappedValue(for: [$0], candidates: candidates)
        }
        return Set(mapped)
    }

    private func wallsflowCategorySlug(for preferences: PreferenceSnapshot) -> String? {
        mappedValue(for: preferences.videoTags + preferences.allTags, candidates: [
            ("anime", "anime"), ("game", "games"), ("games", "games"),
            ("car", "cars"), ("cars", "cars"), ("nature", "nature"),
            ("space", "space"), ("movie", "movies"), ("movies", "movies"),
            ("people", "people"), ("animal", "animals"), ("animals", "animals"),
            ("minimal", "minimalist"), ("minimalist", "minimalist"),
            ("winter", "winter"), ("pixel art", "pixel-art"), ("pixel", "pixel-art"),
        ])
    }

    private func wallpaperRecommendationSource(_ wallpaper: Wallpaper) -> RecommendationSource {
        let source = (wallpaper.source ?? wallpaper.id).lowercased()
        return source.contains("4k") ? .fourK : .wallhaven
    }

    private func mediaRecommendationSource(_ item: MediaItem) -> RecommendationSource {
        let source = "\(item.sourceName) \(item.id) \(item.pageURL.host ?? "")".lowercased()
        if source.contains("wallsflow") || source.contains("wf_") {
            return .wallsflow
        }
        if source.contains("dongtai") {
            return .dongtai
        }
        if source.contains("wallpaper engine") || source.contains("workshop") || source.contains("steamcommunity") {
            return .workshop
        }
        return .motionBG
    }

    // MARK: - 1. Wallhaven（按标签搜索或精选）

    private func fetchWallhaven(count: Int, preferences: PreferenceSnapshot) async -> [GuessYouLikeItem] {
        guard count > 0 else { return [] }
        do {
            let list = try await fetchWallhavenCandidates(count: count, preferences: preferences)

            return list.prefix(count).map { w in
                GuessYouLikeItem(
                    id: w.id,
                    title: w.primaryTagName ?? w.categoryDisplayName,
                    subtitle: w.resolution,
                    imageURL: w.gridPreviewURL?.absoluteString ?? w.thumbs.original,
                    destination: w.url,
                    contentType: .wallpaper,
                    sourceName: RecommendationSource.wallhaven.displayName
                )
            }
        } catch {
            print("[GYL] Wallhaven error: \(error)")
            return []
        }
    }

    private func fetchWallhavenCandidates(count: Int, preferences: PreferenceSnapshot) async throws -> [Wallpaper] {
        let sortingOptions = ["toplist", "random", "favorites", "date_added"]
        let topRangeOptions = ["1d", "3d", "1w", "1M"]
        let randomSorting = sortingOptions.randomElement() ?? "toplist"
        let randomTopRange = topRangeOptions.randomElement() ?? "1M"
        let randomPage = Int.random(in: 1...5)

        var params = WallhavenAPI.SearchParameters(
            categories: preferences.wallhavenCategoryMask,
            purity: preferences.wallhavenPurityMask,
            sorting: randomSorting,
            order: "desc",
            topRange: randomTopRange,
            ratios: preferences.wallhavenRatios,
            colors: preferences.wallhavenColors
        )
        params.perPage = max(count * 4, 12)
        params.page = randomPage
        params.query = wallhavenQuery(for: preferences)

        var list = try await fetchWallhavenList(params, excluding: preferences.excludedWallpaperIDs)
        if list.count >= count {
            return list
        }

        if !params.query.isEmpty {
            params.query = ""
            list = try await fetchWallhavenList(params, excluding: preferences.excludedWallpaperIDs)
            if list.count >= count { return list }
        }

        if !params.colors.isEmpty {
            params.colors = []
            list = try await fetchWallhavenList(params, excluding: preferences.excludedWallpaperIDs)
            if list.count >= count { return list }
        }

        if !params.ratios.isEmpty {
            params.ratios = []
            list = try await fetchWallhavenList(params, excluding: preferences.excludedWallpaperIDs)
            if list.count >= count { return list }
        }

        params.categories = preferences.wallhavenCategoryMask == "111" ? "111" : preferences.wallhavenCategoryMask
        params.purity = "100"
        params.query = ""
        params.colors = []
        params.ratios = []
        return try await fetchWallhavenList(params, excluding: preferences.excludedWallpaperIDs)
    }

    private func fetchWallhavenList(_ params: WallhavenAPI.SearchParameters, excluding excludedIDs: Set<String>) async throws -> [Wallpaper] {
        guard let url = WallhavenAPI.url(for: .search(params)) else { return [] }
        let headers = WallhavenAPI.authenticationHeaders(apiKey: nil)
        let resp: WallpaperSearchResponse = try await NetworkService.shared.fetch(
            WallpaperSearchResponse.self,
            from: url,
            headers: headers
        )
        return resp.data.filter { !excludedIDs.contains($0.id) }
    }

    // MARK: - 2. 4K Wallpapers

    private func fetch4K(count: Int, preferences: PreferenceSnapshot) async -> [GuessYouLikeItem] {
        guard count > 0 else { return [] }
        do {
            let randomPage = Int.random(in: 1...3)
            let list: [Wallpaper]
            if let cat = fourKCategoryID(for: preferences) {
                let resp = try await FourKWallpapersService.shared.fetchCategory(cat, page: randomPage)
                list = resp.data
            } else {
                list = try await FourKWallpapersService.shared.fetchFeatured(limit: count + 4)
            }
            return list.shuffled().prefix(count).map { w in
                GuessYouLikeItem(
                    id: w.id,
                    title: w.primaryTagName ?? w.categoryDisplayName,
                    subtitle: w.resolution,
                    imageURL: w.gridPreviewURL?.absoluteString ?? w.path,
                    destination: w.url,
                    contentType: .wallpaper,
                    sourceName: RecommendationSource.fourK.displayName
                )
            }
        } catch {
            print("[GYL] 4K error: \(error)")
            return []
        }
    }

    // MARK: - 3. MotionBG

    private func fetchMotionBG(count: Int, preferences: PreferenceSnapshot) async -> [GuessYouLikeItem] {
        guard count > 0 else { return [] }
        do {
            let useTag = Bool.random()
            let page = try await MediaService.shared.fetchPage(source: .home)
            var items = page.items
            if useTag, let tag = motionBGTag(for: preferences) {
                let filtered = items.filter { item in
                    item.tags.contains { $0.localizedCaseInsensitiveContains(tag) }
                    || (item.collectionTitle?.localizedCaseInsensitiveContains(tag) ?? false)
                }
                if !filtered.isEmpty { items = filtered }
            }
            return items.shuffled().prefix(count).map { m in
                GuessYouLikeItem(
                    id: m.slug,
                    title: m.title,
                    subtitle: m.collectionTitle ?? m.resolutionLabel,
                    imageURL: m.coverImageURL.absoluteString,
                    destination: m.pageURL.absoluteString,
                    contentType: .video,
                    sourceName: RecommendationSource.motionBG.displayName
                )
            }
        } catch {
            print("[GYL] MotionBG error: \(error)")
            return []
        }
    }

    // MARK: - 4. Wallpaper Engine

    private func fetchWorkshop(count: Int, preferences: PreferenceSnapshot) async -> [GuessYouLikeItem] {
        guard count > 0 else { return [] }
        do {
            let randomPage = Int.random(in: 1...3)
            let params = WorkshopSearchParams(
                sortBy: .ranked, page: randomPage, pageSize: count + 4,
                tags: workshopTags(for: preferences)
            )
            let result = try await WorkshopService.shared.search(params: params)
            return result.items.shuffled().prefix(count).map { w in
                GuessYouLikeItem(
                    id: w.id,
                    title: w.title,
                    subtitle: w.tags.first ?? "Wallpaper Engine",
                    imageURL: w.previewURL?.absoluteString ?? "",
                    destination: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(w.id)",
                    contentType: .video,
                    sourceName: RecommendationSource.workshop.displayName
                )
            }
        } catch {
            print("[GYL] Workshop error: \(error)")
            return []
        }
    }

    // MARK: - 5. DongTai

    private func fetchDongTai(count: Int, preferences: PreferenceSnapshot) async -> [GuessYouLikeItem] {
        guard count > 0 else { return [] }
        let service = DynamicWallpaperService.shared
        if !service.isDataReady { _ = await service.loadData() }
        guard service.isDataReady else { return [] }
        let sortOptions: [DynamicWallpaperSortOption] = [.popular, .newest]
        let randomSort = sortOptions.randomElement() ?? .popular
        let randomPage = Int.random(in: 1...3)
        let params = DynamicWallpaperSearchParams(
            categories: dongtaiCategories(for: preferences),
            sortBy: randomSort, page: randomPage, pageSize: count + 2
        )
        let result = service.queryItems(params: params)
        return result.items.shuffled().prefix(count).map { m in
            GuessYouLikeItem(
                id: m.slug,
                title: m.title,
                subtitle: m.resolutionLabel,
                imageURL: m.thumbnailURL.absoluteString,
                destination: m.pageURL.absoluteString,
                contentType: .video,
                sourceName: RecommendationSource.dongtai.displayName,
                previewVideoURL: m.previewVideoURL?.absoluteString,
                downloadOptions: m.downloadOptions
            )
        }
    }

    // MARK: - 6. Wallsflow

    private func fetchWallsflow(count: Int, preferences: PreferenceSnapshot) async -> [GuessYouLikeItem] {
        guard count > 0 else { return [] }
        do {
            let randomPage = Int.random(in: 1...3)
            let useCategory = Bool.random()
            let preferredPage: WallsflowListPage
            if useCategory, let slug = wallsflowCategorySlug(for: preferences) {
                preferredPage = try await WallsflowService.shared.fetchCategory(slug: slug, page: randomPage)
            } else if let query = preferences.videoTags.first ?? preferences.allTags.first {
                preferredPage = try await WallsflowService.shared.search(query: query, page: randomPage)
            } else {
                preferredPage = try await WallsflowService.shared.fetchHome(page: randomPage)
            }

            let page = preferredPage.items.isEmpty
                ? try await WallsflowService.shared.fetchHome(page: randomPage)
                : preferredPage

            return page.items.shuffled().prefix(count).map { m in
                GuessYouLikeItem(
                    id: m.slug,
                    title: m.title,
                    subtitle: m.collectionTitle ?? m.resolutionLabel,
                    imageURL: m.coverImageURL.absoluteString,
                    destination: m.pageURL.absoluteString,
                    contentType: .video,
                    sourceName: RecommendationSource.wallsflow.displayName,
                    previewVideoURL: m.previewVideoURL?.absoluteString,
                    downloadOptions: m.downloadOptions
                )
            }
        } catch {
            print("[GYL] Wallsflow error: \(error)")
            return []
        }
    }
}

private extension GuessYouLikeItem {
    var deduplicationKey: String {
        let destinationKey = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        if !destinationKey.isEmpty {
            return destinationKey
        }
        return "\(sourceName)|\(id)"
    }
}
