import Foundation
import Combine
import AVFoundation

// MARK: - 播放进度记录

struct PlaybackProgress: Codable, Identifiable {
    let id: String          // 唯一标识: sourceId_episodeId
    let animeId: String     // 动漫ID
    let animeTitle: String  // 动漫标题
    let episodeId: String   // 剧集ID
    let episodeName: String? // 剧集名称
    let episodeNumber: Int  // 剧集编号
    let sourceId: String    // 源ID
    let sourceName: String  // 源名称
    var currentTime: Double // 当前播放时间（秒）
    var duration: Double    // 总时长（秒）
    var lastPlayedAt: Date  // 最后播放时间
    let coverURL: String?   // 封面URL

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(currentTime / duration, 1.0)
    }

    var isCompleted: Bool {
        progress >= 0.9 // 90% 以上视为已看完
    }

    var formattedProgress: String {
        let current = formatTime(currentTime)
        let total = formatTime(duration)
        return "\(current) / \(total)"
    }

    private func formatTime(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}

// MARK: - 播放进度缓存服务

@MainActor
class PlaybackProgressCache: ObservableObject {
    static let shared = PlaybackProgressCache()

    @Published private(set) var progresses: [PlaybackProgress] = []

    private let userDefaults = UserDefaults.standard
    private let cacheKey = "playback_progress_cache"
    private var saveTimer: Timer?
    private var currentProgress: PlaybackProgress?

    private init() {
        loadFromDisk()
    }

    // MARK: - 加载/保存

    private func loadFromDisk() {
        guard let data = userDefaults.data(forKey: cacheKey),
              let decoded = try? JSONDecoder().decode([PlaybackProgress].self, from: data) else {
            return
        }
        progresses = decoded.sorted { $0.lastPlayedAt > $1.lastPlayedAt }
    }

    private func saveToDisk() {
        guard let data = try? JSONEncoder().encode(progresses) else { return }
        userDefaults.set(data, forKey: cacheKey)
    }

    // MARK: - 更新进度

    /// 开始跟踪播放进度
    func startTracking(
        animeId: String,
        animeTitle: String,
        episode: AnimeDetail.AnimeEpisodeItem,
        sourceId: String,
        sourceName: String,
        coverURL: String?
    ) {
        let progressId = "\(sourceId)_\(episode.id)"
        currentProgress = PlaybackProgress(
            id: progressId,
            animeId: animeId,
            animeTitle: animeTitle,
            episodeId: episode.id,
            episodeName: episode.name,
            episodeNumber: episode.episodeNumber,
            sourceId: sourceId,
            sourceName: sourceName,
            currentTime: 0,
            duration: 0,
            lastPlayedAt: Date(),
            coverURL: coverURL
        )
    }

    /// 更新当前播放进度
    func updateProgress(currentTime: Double, duration: Double) {
        guard var progress = currentProgress else { return }
        progress.currentTime = currentTime
        progress.duration = duration
        progress.lastPlayedAt = Date()
        currentProgress = progress

        // 延迟保存，避免频繁写入
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.commitCurrentProgress()
            }
        }
    }

    /// 提交当前进度到缓存
    private func commitCurrentProgress() {
        guard let progress = currentProgress else { return }

        // 移除旧的记录
        progresses.removeAll { $0.id == progress.id }

        // 添加新记录到开头
        progresses.insert(progress, at: 0)

        // 限制缓存数量（保留最近100条）
        if progresses.count > 100 {
            progresses = Array(progresses.prefix(100))
        }

        saveToDisk()
        objectWillChange.send()
    }

    /// 停止跟踪并保存最终进度
    func stopTracking() {
        saveTimer?.invalidate()
        commitCurrentProgress()
        currentProgress = nil
    }

    // MARK: - 查询进度

    /// 获取指定剧集的播放进度
    func getProgress(sourceId: String, episodeId: String) -> PlaybackProgress? {
        let id = "\(sourceId)_\(episodeId)"
        return progresses.first { $0.id == id }
    }

    /// 获取指定动漫的所有进度
    func getAnimeProgresses(animeId: String) -> [PlaybackProgress] {
        progresses.filter { $0.animeId == animeId }
    }

    /// 获取最近播放的列表
    func getRecentPlays(limit: Int = 20) -> [PlaybackProgress] {
        return Array(progresses.prefix(limit))
    }

    /// 获取上次播放的剧集（用于"继续播放"功能）
    func getLastPlayedEpisode(animeId: String) -> PlaybackProgress? {
        return progresses.first { $0.animeId == animeId && !$0.isCompleted }
    }

    // MARK: - 清除进度

    /// 清除指定剧集的进度
    func clearProgress(sourceId: String, episodeId: String) {
        let id = "\(sourceId)_\(episodeId)"
        progresses.removeAll { $0.id == id }
        saveToDisk()
    }

    /// 清除指定动漫的所有进度
    func clearAnimeProgress(animeId: String) {
        progresses.removeAll { $0.animeId == animeId }
        saveToDisk()
    }

    /// 清除所有进度
    func clearAll() {
        progresses.removeAll()
        saveToDisk()
    }

    /// 清理已完成的播放记录（保留最近30天）
    func cleanupCompletedRecords() {
        let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        progresses.removeAll {
            $0.isCompleted && $0.lastPlayedAt < thirtyDaysAgo
        }
        saveToDisk()
    }
}

// MARK: - 播放进度跟踪器（用于 AVPlayer）

import AVFoundation

@MainActor
class PlaybackProgressTracker: NSObject, ObservableObject {
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var progress: Double = 0

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var cancellables = Set<AnyCancellable>()

    func attach(to player: AVPlayer) {
        detach()
        self.player = player

        // 监听播放时间
        let interval = CMTime(seconds: 1.0, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                self?.updateProgress(time: time)
            }
        }

        // 监听时长变化
        player.currentItem?.publisher(for: \.duration)
            .sink { [weak self] duration in
                Task { @MainActor in
                    self?.duration = duration.seconds.isFinite ? duration.seconds : 0
                }
            }
            .store(in: &cancellables)

        // 监听播放状态
        NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.progress = 1.0
                    self?.currentTime = self?.duration ?? 0
                }
            }
            .store(in: &cancellables)
    }

    func detach() {
        if let observer = timeObserver, let player = player {
            player.removeTimeObserver(observer)
            timeObserver = nil
        }
        cancellables.removeAll()
        player = nil
    }

    private func updateProgress(time: CMTime) {
        currentTime = time.seconds.isFinite ? time.seconds : 0
        if duration > 0 {
            progress = min(currentTime / duration, 1.0)
        }

        // 定期保存进度
        PlaybackProgressCache.shared.updateProgress(
            currentTime: currentTime,
            duration: duration
        )
    }

}
