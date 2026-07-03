import Foundation

// MARK: - 收藏的动漫
struct FavoriteAnime: Codable, Identifiable, Equatable {
    let id: String // 动漫 ID
    let title: String
    let originalTitle: String?
    let coverURL: String?
    let bangumiId: Int?
    let addedAt: Date
    var updatedAt: Date
    var note: String? // 用户备注
    var tags: [String] // 用户标签
    var score: Int? // 用户评分 (1-10)
    var watchStatus: WatchStatus

    enum WatchStatus: String, Codable, CaseIterable {
        case planToWatch = "plan_to_watch"
        case watching = "watching"
        case completed = "completed"
        case onHold = "on_hold"
        case dropped = "dropped"

        var displayName: String {
            switch self {
            case .planToWatch: return t("favorite.planToWatch")
            case .watching: return t("favorite.watching")
            case .completed: return t("favorite.completed")
            case .onHold: return t("favorite.onHold")
            case .dropped: return t("favorite.dropped")
            }
        }

        var icon: String {
            switch self {
            case .planToWatch: return "bookmark"
            case .watching: return "play.circle"
            case .completed: return "checkmark.circle.fill"
            case .onHold: return "pause.circle"
            case .dropped: return "xmark.circle"
            }
        }

        var color: String {
            switch self {
            case .planToWatch: return "3B82F6"
            case .watching: return "10B981"
            case .completed: return "8B5CF6"
            case .onHold: return "F59E0B"
            case .dropped: return "EF4444"
            }
        }
    }
}

// MARK: - 收藏列表排序方式
enum FavoriteSortOption: String, CaseIterable {
    case addedAt = "added_at"
    case title = "title"
    case score = "score"
    case updatedAt = "updated_at"

    var displayName: String {
        switch self {
        case .addedAt: return t("favorite.addedAt")
        case .title: return t("favorite.title")
        case .score: return t("favorite.score")
        case .updatedAt: return t("favorite.updatedAt")
        }
    }
}

// MARK: - 本地收藏存储
@MainActor
class AnimeFavoriteStore: ObservableObject {
    static let shared = AnimeFavoriteStore()

    private let cache = CachePersistenceService.shared
    private let animeFavCategory = "anime/fav"

    /// UserDefaults key — 仅迁移用
    private let defaults = UserDefaults.standard
    private let favoritesKey = "anime_favorites_v1"

    @Published private(set) var favorites: [String: FavoriteAnime] = [:]
    @Published var sortOption: FavoriteSortOption = .addedAt
    @Published var filterStatus: FavoriteAnime.WatchStatus? = nil

    private init() {
        // ⚠️ 不在 init 中读 UserDefaults，避免 _CFXPreferences 递归栈溢出
    }

    /// 延迟恢复持久化数据（必须在 AppDelegate.applicationDidFinishLaunching 中调用）
    func restoreSavedData() {
        loadFromDisk()
    }

    // MARK: - 加载/保存

    private func loadFromDisk() {
        let decoder = JSONDecoder()

        // 1) 优先从 Cache 加载
        let cachedFavs: [FavoriteAnime] = cache.loadAll(category: animeFavCategory)
        if !cachedFavs.isEmpty {
            var dict: [String: FavoriteAnime] = [:]
            for fav in cachedFavs {
                dict[fav.id] = fav
            }
            favorites = dict
        } else if let data = defaults.data(forKey: favoritesKey),
                  let decoded = try? decoder.decode([String: FavoriteAnime].self, from: data) {
            // 2) Cache 为空 → 从 UserDefaults 迁移
            favorites = decoded
            defaults.removeObject(forKey: favoritesKey)
            rebuildCache()
        }

        // 3) 孤儿记录恢复：扫描缓存目录找回索引丢失但文件仍在的记录
        let orphanedData = cache.recoverOrphanedRecordData(for: [animeFavCategory])
        if let orphans = orphanedData[animeFavCategory], !orphans.isEmpty {
            let recovered = orphans.compactMap { try? decoder.decode(FavoriteAnime.self, from: $0) }
            let newRecords = recovered.filter { favorites[$0.id] == nil }
            if !newRecords.isEmpty {
                for fav in newRecords {
                    favorites[fav.id] = fav
                }
                rebuildCache()
                print("[AnimeFavoriteStore] Recovered \(newRecords.count) orphaned favorite records from disk")
            }
        }

        // 加载排序设置（量小，保留 UserDefaults）
        if let sortRaw = defaults.string(forKey: "anime_favorite_sort"),
           let sort = FavoriteSortOption(rawValue: sortRaw) {
            sortOption = sort
        }
    }

    // MARK: - Cache 辅助

    private func saveFavToCache(_ fav: FavoriteAnime) {
        cache.save(fav, key: "\(animeFavCategory)/\(fav.id)")
    }

    private func deleteFavFromCache(_ id: String) {
        cache.delete(key: "\(animeFavCategory)/\(id)")
    }

    private func syncIndex() {
        cache.saveIndex(Array(favorites.keys), key: "index/\(animeFavCategory)")
    }

    private func rebuildCache() {
        for (_, fav) in favorites {
            saveFavToCache(fav)
        }
        syncIndex()
    }

    func saveSortOption(_ option: FavoriteSortOption) {
        sortOption = option
        defaults.set(option.rawValue, forKey: "anime_favorite_sort")
    }

    // MARK: - 收藏操作

    /// 添加收藏
    func addFavorite(
        anime: AnimeSearchResult,
        bangumiId: Int? = nil,
        note: String? = nil,
        score: Int? = nil,
        status: FavoriteAnime.WatchStatus = .planToWatch
    ) {
        let favorite = FavoriteAnime(
            id: anime.id,
            title: anime.title,
            originalTitle: nil,
            coverURL: anime.coverURL,
            bangumiId: bangumiId,
            addedAt: Date(),
            updatedAt: Date(),
            note: note,
            tags: [],
            score: score,
            watchStatus: status
        )

        favorites[anime.id] = favorite
        saveFavToCache(favorite)
        syncIndex()
    }

    /// 从 ViewModel 添加收藏
    func addFavorite(from viewModel: AnimeDetailViewModel, status: FavoriteAnime.WatchStatus = .planToWatch) {
        let anime = viewModel.anime
        let bangumiId = viewModel.bangumiDetail?.id

        addFavorite(
            anime: anime,
            bangumiId: bangumiId,
            status: status
        )
    }

    /// 移除收藏
    func removeFavorite(animeId: String) {
        favorites.removeValue(forKey: animeId)
        deleteFavFromCache(animeId)
        syncIndex()
    }

    /// 切换收藏状态
    func toggleFavorite(anime: AnimeSearchResult, bangumiId: Int? = nil) -> Bool {
        if isFavorite(animeId: anime.id) {
            removeFavorite(animeId: anime.id)
            return false
        } else {
            addFavorite(anime: anime, bangumiId: bangumiId)
            return true
        }
    }

    /// 检查是否已收藏
    func isFavorite(animeId: String) -> Bool {
        favorites[animeId] != nil
    }

    /// 获取收藏
    func getFavorite(animeId: String) -> FavoriteAnime? {
        favorites[animeId]
    }

    // MARK: - 云同步导入方法

    /// 同步导入收藏记录（合并模式）
    func syncImportFavorites(_ records: [FavoriteAnime]) {
        for record in records {
            favorites[record.id] = record
            saveFavToCache(record)
        }
        syncIndex()
    }

    /// 同步删除收藏（按 ID 集合）
    func syncRemoveFavorites(ids: Set<String>) {
        for id in ids {
            favorites.removeValue(forKey: id)
            deleteFavFromCache(id)
        }
        syncIndex()
    }

    // MARK: - 更新收藏

    /// 更新观看状态
    func updateWatchStatus(animeId: String, status: FavoriteAnime.WatchStatus) {
        guard var favorite = favorites[animeId] else { return }
        favorite.watchStatus = status
        favorite.updatedAt = Date()
        favorites[animeId] = favorite
        saveFavToCache(favorite)
        syncIndex()
    }

    /// 更新评分
    func updateScore(animeId: String, score: Int?) {
        guard var favorite = favorites[animeId] else { return }
        favorite.score = score
        favorite.updatedAt = Date()
        favorites[animeId] = favorite
        saveFavToCache(favorite)
        syncIndex()
    }

    /// 更新备注
    func updateNote(animeId: String, note: String?) {
        guard var favorite = favorites[animeId] else { return }
        favorite.note = note
        favorite.updatedAt = Date()
        favorites[animeId] = favorite
        saveFavToCache(favorite)
        syncIndex()
    }

    /// 更新标签
    func updateTags(animeId: String, tags: [String]) {
        guard var favorite = favorites[animeId] else { return }
        favorite.tags = tags
        favorite.updatedAt = Date()
        favorites[animeId] = favorite
        saveFavToCache(favorite)
        syncIndex()
    }

    /// 添加标签
    func addTag(animeId: String, tag: String) {
        guard var favorite = favorites[animeId] else { return }
        if !favorite.tags.contains(tag) {
            favorite.tags.append(tag)
            favorite.updatedAt = Date()
            favorites[animeId] = favorite
            saveFavToCache(favorite)
            syncIndex()
        }
    }

    /// 移除标签
    func removeTag(animeId: String, tag: String) {
        guard var favorite = favorites[animeId] else { return }
        favorite.tags.removeAll { $0 == tag }
        favorite.updatedAt = Date()
        favorites[animeId] = favorite
        saveFavToCache(favorite)
        syncIndex()
    }

    // MARK: - 查询

    /// 获取所有收藏列表
    var allFavorites: [FavoriteAnime] {
        Array(favorites.values)
    }

    /// 获取筛选和排序后的列表
    var filteredAndSortedFavorites: [FavoriteAnime] {
        var result = allFavorites

        // 筛选
        if let status = filterStatus {
            result = result.filter { $0.watchStatus == status }
        }

        // 排序
        switch sortOption {
        case .addedAt:
            result.sort { $0.addedAt > $1.addedAt }
        case .title:
            result.sort { $0.title.localizedCompare($1.title) == .orderedAscending }
        case .score:
            result.sort {
                let s1 = $0.score ?? 0
                let s2 = $1.score ?? 0
                if s1 != s2 { return s1 > s2 }
                return $0.addedAt > $1.addedAt
            }
        case .updatedAt:
            result.sort { $0.updatedAt > $1.updatedAt }
        }

        return result
    }

    /// 按状态分组
    func favoritesByStatus(_ status: FavoriteAnime.WatchStatus) -> [FavoriteAnime] {
        allFavorites.filter { $0.watchStatus == status }
    }

    /// 获取所有标签
    var allTags: [String] {
        Array(Set(allFavorites.flatMap { $0.tags })).sorted()
    }

    /// 按标签搜索
    func favoritesWithTag(_ tag: String) -> [FavoriteAnime] {
        allFavorites.filter { $0.tags.contains(tag) }
    }

    /// 搜索标题
    func searchFavorites(query: String) -> [FavoriteAnime] {
        let lowerQuery = query.lowercased()
        return allFavorites.filter {
            $0.title.lowercased().contains(lowerQuery) ||
            $0.tags.contains { $0.lowercased().contains(lowerQuery) }
        }
    }

    // MARK: - 统计

    var totalCount: Int { favorites.count }

    func countByStatus(_ status: FavoriteAnime.WatchStatus) -> Int {
        favorites.values.filter { $0.watchStatus == status }.count
    }

    var statistics: [FavoriteAnime.WatchStatus: Int] {
        Dictionary(grouping: allFavorites, by: { $0.watchStatus })
            .mapValues { $0.count }
    }
}
