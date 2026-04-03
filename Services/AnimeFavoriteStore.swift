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
    
    private let defaults = UserDefaults.standard
    private let favoritesKey = "anime_favorites_v1"
    
    @Published private(set) var favorites: [String: FavoriteAnime] = [:]
    @Published var sortOption: FavoriteSortOption = .addedAt
    @Published var filterStatus: FavoriteAnime.WatchStatus? = nil
    
    private init() {
        loadFromDisk()
    }
    
    // MARK: - 加载/保存
    
    private func loadFromDisk() {
        if let data = defaults.data(forKey: favoritesKey),
           let decoded = try? JSONDecoder().decode([String: FavoriteAnime].self, from: data) {
            favorites = decoded
        }
        
        // 加载排序设置
        if let sortRaw = defaults.string(forKey: "anime_favorite_sort"),
           let sort = FavoriteSortOption(rawValue: sortRaw) {
            sortOption = sort
        }
    }
    
    private func saveToDisk() {
        if let encoded = try? JSONEncoder().encode(favorites) {
            defaults.set(encoded, forKey: favoritesKey)
        }
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
        saveToDisk()
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
        saveToDisk()
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
    
    // MARK: - 更新收藏
    
    /// 更新观看状态
    func updateWatchStatus(animeId: String, status: FavoriteAnime.WatchStatus) {
        guard var favorite = favorites[animeId] else { return }
        favorite.watchStatus = status
        favorite.updatedAt = Date()
        favorites[animeId] = favorite
        saveToDisk()
    }
    
    /// 更新评分
    func updateScore(animeId: String, score: Int?) {
        guard var favorite = favorites[animeId] else { return }
        favorite.score = score
        favorite.updatedAt = Date()
        favorites[animeId] = favorite
        saveToDisk()
    }
    
    /// 更新备注
    func updateNote(animeId: String, note: String?) {
        guard var favorite = favorites[animeId] else { return }
        favorite.note = note
        favorite.updatedAt = Date()
        favorites[animeId] = favorite
        saveToDisk()
    }
    
    /// 更新标签
    func updateTags(animeId: String, tags: [String]) {
        guard var favorite = favorites[animeId] else { return }
        favorite.tags = tags
        favorite.updatedAt = Date()
        favorites[animeId] = favorite
        saveToDisk()
    }
    
    /// 添加标签
    func addTag(animeId: String, tag: String) {
        guard var favorite = favorites[animeId] else { return }
        if !favorite.tags.contains(tag) {
            favorite.tags.append(tag)
            favorite.updatedAt = Date()
            favorites[animeId] = favorite
            saveToDisk()
        }
    }
    
    /// 移除标签
    func removeTag(animeId: String, tag: String) {
        guard var favorite = favorites[animeId] else { return }
        favorite.tags.removeAll { $0 == tag }
        favorite.updatedAt = Date()
        favorites[animeId] = favorite
        saveToDisk()
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
