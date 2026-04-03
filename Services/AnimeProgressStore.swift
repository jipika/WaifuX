import Foundation

// MARK: - 单集播放进度
struct EpisodeProgress: Codable, Equatable {
    let animeId: String
    let episodeId: String
    let episodeNumber: String
    var currentTime: Double // 当前播放位置（秒）
    var totalDuration: Double // 总时长（秒）
    var progress: Double // 进度百分比 (0-1)
    var lastPlayedAt: Date
    var isCompleted: Bool // 是否已看完（进度 > 90%）
    
    init(
        animeId: String,
        episodeId: String,
        episodeNumber: String,
        currentTime: Double = 0,
        totalDuration: Double = 0,
        progress: Double = 0,
        lastPlayedAt: Date = Date(),
        isCompleted: Bool = false
    ) {
        self.animeId = animeId
        self.episodeId = episodeId
        self.episodeNumber = episodeNumber
        self.currentTime = currentTime
        self.totalDuration = totalDuration
        self.progress = progress
        self.lastPlayedAt = lastPlayedAt
        self.isCompleted = isCompleted
    }
}

// MARK: - 动漫播放进度摘要
struct AnimeProgressSummary: Codable, Equatable {
    let animeId: String
    let animeTitle: String
    let coverURL: String?
    var lastEpisodeId: String?
    var lastEpisodeNumber: String?
    var lastPlayedAt: Date
    var totalEpisodes: Int
    var watchedEpisodes: Int
    var overallProgress: Double // 总体进度 (0-1)
    
    var continueWatchingText: String {
        if let epNum = lastEpisodeNumber {
            return "看到第 \(epNum) 集"
        }
        return "继续观看"
    }
}

// MARK: - 播放进度存储
@MainActor
class AnimeProgressStore: ObservableObject {
    static let shared = AnimeProgressStore()
    
    private let defaults = UserDefaults.standard
    private let episodeProgressKey = "anime_episode_progress_v1"
    private let animeSummaryKey = "anime_progress_summary_v1"
    
    @Published private(set) var episodeProgress: [String: EpisodeProgress] = [:]
    @Published private(set) var animeSummaries: [String: AnimeProgressSummary] = [:]
    
    private init() {
        loadFromDisk()
    }
    
    // MARK: - 加载/保存
    
    private func loadFromDisk() {
        // 加载单集进度
        if let data = defaults.data(forKey: episodeProgressKey),
           let decoded = try? JSONDecoder().decode([String: EpisodeProgress].self, from: data) {
            episodeProgress = decoded
        }
        
        // 加载动漫摘要
        if let data = defaults.data(forKey: animeSummaryKey),
           let decoded = try? JSONDecoder().decode([String: AnimeProgressSummary].self, from: data) {
            animeSummaries = decoded
        }
    }
    
    private func saveEpisodeProgress() {
        if let encoded = try? JSONEncoder().encode(episodeProgress) {
            defaults.set(encoded, forKey: episodeProgressKey)
        }
    }
    
    private func saveAnimeSummaries() {
        if let encoded = try? JSONEncoder().encode(animeSummaries) {
            defaults.set(encoded, forKey: animeSummaryKey)
        }
    }
    
    // MARK: - 更新进度
    
    /// 更新单集播放进度
    func updateProgress(
        animeId: String,
        animeTitle: String,
        coverURL: String?,
        episodeId: String,
        episodeNumber: String,
        currentTime: Double,
        totalDuration: Double
    ) {
        let progress = totalDuration > 0 ? currentTime / totalDuration : 0
        let isCompleted = progress >= 0.9
        
        let key = "\(animeId)_\(episodeId)"
        let episodeProg = EpisodeProgress(
            animeId: animeId,
            episodeId: episodeId,
            episodeNumber: episodeNumber,
            currentTime: currentTime,
            totalDuration: totalDuration,
            progress: progress,
            lastPlayedAt: Date(),
            isCompleted: isCompleted
        )
        
        episodeProgress[key] = episodeProg
        saveEpisodeProgress()
        
        // 更新动漫摘要
        updateAnimeSummary(
            animeId: animeId,
            animeTitle: animeTitle,
            coverURL: coverURL,
            lastEpisodeId: episodeId,
            lastEpisodeNumber: episodeNumber,
            totalEpisodes: nil // 未知总数
        )
    }
    
    /// 获取单集进度
    func getProgress(animeId: String, episodeId: String) -> EpisodeProgress? {
        let key = "\(animeId)_\(episodeId)"
        return episodeProgress[key]
    }
    
    /// 获取动漫的所有集进度
    func getAllEpisodeProgress(for animeId: String) -> [EpisodeProgress] {
        episodeProgress.values.filter { $0.animeId == animeId }
    }
    
    // MARK: - 摘要管理
    
    private func updateAnimeSummary(
        animeId: String,
        animeTitle: String,
        coverURL: String?,
        lastEpisodeId: String?,
        lastEpisodeNumber: String?,
        totalEpisodes: Int?
    ) {
        let allEpisodes = getAllEpisodeProgress(for: animeId)
        let watchedCount = allEpisodes.filter { $0.isCompleted }.count
        
        let summary: AnimeProgressSummary
        if let existing = animeSummaries[animeId] {
            summary = AnimeProgressSummary(
                animeId: animeId,
                animeTitle: animeTitle,
                coverURL: coverURL ?? existing.coverURL,
                lastEpisodeId: lastEpisodeId ?? existing.lastEpisodeId,
                lastEpisodeNumber: lastEpisodeNumber ?? existing.lastEpisodeNumber,
                lastPlayedAt: Date(),
                totalEpisodes: totalEpisodes ?? existing.totalEpisodes,
                watchedEpisodes: watchedCount,
                overallProgress: calculateOverallProgress(watched: watchedCount, total: totalEpisodes ?? existing.totalEpisodes)
            )
        } else {
            summary = AnimeProgressSummary(
                animeId: animeId,
                animeTitle: animeTitle,
                coverURL: coverURL,
                lastEpisodeId: lastEpisodeId,
                lastEpisodeNumber: lastEpisodeNumber,
                lastPlayedAt: Date(),
                totalEpisodes: totalEpisodes ?? 0,
                watchedEpisodes: watchedCount,
                overallProgress: calculateOverallProgress(watched: watchedCount, total: totalEpisodes ?? 0)
            )
        }
        
        animeSummaries[animeId] = summary
        saveAnimeSummaries()
    }
    
    private func calculateOverallProgress(watched: Int, total: Int) -> Double {
        guard total > 0 else { return 0 }
        return Double(watched) / Double(total)
    }
    
    /// 获取动漫摘要
    func getSummary(animeId: String) -> AnimeProgressSummary? {
        animeSummaries[animeId]
    }
    
    /// 获取所有正在观看的动漫（按最近播放排序）
    func getContinueWatchingList(limit: Int = 20) -> [AnimeProgressSummary] {
        animeSummaries.values
            .filter { $0.overallProgress < 1.0 } // 未看完
            .sorted { $0.lastPlayedAt > $1.lastPlayedAt }
            .prefix(limit)
            .map { $0 }
    }
    
    /// 获取已完成的动漫
    func getCompletedList(limit: Int = 20) -> [AnimeProgressSummary] {
        animeSummaries.values
            .filter { $0.overallProgress >= 1.0 }
            .sorted { $0.lastPlayedAt > $1.lastPlayedAt }
            .prefix(limit)
            .map { $0 }
    }
    
    // MARK: - 删除
    
    /// 删除动漫的所有进度
    func removeProgress(for animeId: String) {
        // 删除单集进度
        episodeProgress = episodeProgress.filter { key, _ in
            !key.hasPrefix("\(animeId)_")
        }
        saveEpisodeProgress()
        
        // 删除摘要
        animeSummaries.removeValue(forKey: animeId)
        saveAnimeSummaries()
    }
    
    /// 标记单集为已看完
    func markEpisodeCompleted(animeId: String, episodeId: String, episodeNumber: String) {
        guard var progress = getProgress(animeId: animeId, episodeId: episodeId) else { return }
        progress.isCompleted = true
        progress.progress = 1.0
        progress.lastPlayedAt = Date()
        
        let key = "\(animeId)_\(episodeId)"
        episodeProgress[key] = progress
        saveEpisodeProgress()
    }
    
    /// 重置单集进度
    func resetEpisodeProgress(animeId: String, episodeId: String) {
        let key = "\(animeId)_\(episodeId)"
        episodeProgress.removeValue(forKey: key)
        saveEpisodeProgress()
    }
}
