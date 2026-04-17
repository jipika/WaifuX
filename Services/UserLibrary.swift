import Foundation
import SwiftUI

// MARK: - 用户库管理

actor UserLibrary {
    static let shared = UserLibrary()

    private let fileManager = FileManager.default
    private let libraryDirectory: URL

    // 文件路径
    private var wallpaperFavoritesPath: URL { libraryDirectory.appendingPathComponent("wallpaper_favorites.json") }
    private var animeFavoritesPath: URL { libraryDirectory.appendingPathComponent("anime_favorites.json") }
    private var videoFavoritesPath: URL { libraryDirectory.appendingPathComponent("video_favorites.json") }
    private var watchHistoryPath: URL { libraryDirectory.appendingPathComponent("watch_history.json") }
    private var downloadsPath: URL { libraryDirectory.appendingPathComponent("downloads.json") }

    // 内存缓存
    private var wallpaperFavorites: [UniversalContentItem] = []
    private var animeFavorites: [UniversalContentItem] = []
    private var videoFavorites: [UniversalContentItem] = []
    private var watchHistory: [WatchProgress] = []
    private var downloads: [DownloadRecord] = []

    init() {
        // ⚠️ 不在 init 中做任何 I/O（FileManager/UserDefaults），避免 _CFXPreferences 递归栈溢出
        guard let supportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            self.libraryDirectory = fileManager.temporaryDirectory
                .appendingPathComponent("WaifuX", isDirectory: true)
                .appendingPathComponent("Library", isDirectory: true)
            return
        }
        self.libraryDirectory = supportDir
            .appendingPathComponent("WaifuX", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
    }
    
    /// 延迟初始化：创建目录并加载数据（必须在 AppDelegate.applicationDidFinishLaunching 中调用）
    func restoreSavedData() {
        try? fileManager.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)
        Task {
            await loadAllData()
        }
    }

    // MARK: - 加载数据

    private func loadAllData() async {
        wallpaperFavorites = loadItems(from: wallpaperFavoritesPath)
        animeFavorites = loadItems(from: animeFavoritesPath)
        videoFavorites = loadItems(from: videoFavoritesPath)
        watchHistory = loadData(from: watchHistoryPath) ?? []
        downloads = loadData(from: downloadsPath) ?? []
    }

    private func loadItems<T: Codable>(from url: URL) -> [T] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([T].self, from: data)) ?? []
    }

    private func loadData<T: Codable>(from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func saveItems<T: Codable>(_ items: [T], to url: URL) throws {
        let data = try JSONEncoder().encode(items)
        try data.write(to: url)
    }

    // MARK: - 收藏管理

    func addToFavorites(_ item: UniversalContentItem) async throws {
        switch item.contentType {
        case .wallpaper:
            guard !wallpaperFavorites.contains(where: { $0.id == item.id }) else { return }
            wallpaperFavorites.append(item)
            try saveItems(wallpaperFavorites, to: wallpaperFavoritesPath)

        case .anime:
            guard !animeFavorites.contains(where: { $0.id == item.id }) else { return }
            animeFavorites.append(item)
            try saveItems(animeFavorites, to: animeFavoritesPath)

        case .video:
            guard !videoFavorites.contains(where: { $0.id == item.id }) else { return }
            videoFavorites.append(item)
            try saveItems(videoFavorites, to: videoFavoritesPath)
        }
    }

    func removeFromFavorites(id: String, contentType: ContentType) async throws {
        switch contentType {
        case .wallpaper:
            wallpaperFavorites.removeAll { $0.id == id }
            try saveItems(wallpaperFavorites, to: wallpaperFavoritesPath)

        case .anime:
            animeFavorites.removeAll { $0.id == id }
            try saveItems(animeFavorites, to: animeFavoritesPath)

        case .video:
            videoFavorites.removeAll { $0.id == id }
            try saveItems(videoFavorites, to: videoFavoritesPath)
        }
    }

    func getFavorites(for contentType: ContentType) async -> [UniversalContentItem] {
        switch contentType {
        case .wallpaper: return wallpaperFavorites
        case .anime: return animeFavorites
        case .video: return videoFavorites
        }
    }

    func isFavorite(id: String, contentType: ContentType) async -> Bool {
        switch contentType {
        case .wallpaper: return wallpaperFavorites.contains(where: { $0.id == id })
        case .anime: return animeFavorites.contains(where: { $0.id == id })
        case .video: return videoFavorites.contains(where: { $0.id == id })
        }
    }

    func toggleFavorite(_ item: UniversalContentItem) async throws -> Bool {
        let isFav = await isFavorite(id: item.id, contentType: item.contentType)
        if isFav {
            try await removeFromFavorites(id: item.id, contentType: item.contentType)
            return false
        } else {
            try await addToFavorites(item)
            return true
        }
    }

    // MARK: - 观看进度（动漫专用）

    func saveWatchProgress(animeId: String, episodeNumber: Int, progress: Double) async throws {
        if let index = watchHistory.firstIndex(where: { $0.animeId == animeId }) {
            watchHistory[index].currentEpisode = episodeNumber
            watchHistory[index].episodeProgress = progress
            watchHistory[index].lastWatchedAt = Date()
        } else {
            watchHistory.append(WatchProgress(
                animeId: animeId,
                currentEpisode: episodeNumber,
                episodeProgress: progress,
                lastWatchedAt: Date()
            ))
        }

        try saveItems(watchHistory, to: watchHistoryPath)
    }

    func getWatchProgress(animeId: String) async -> WatchProgress? {
        return watchHistory.first(where: { $0.animeId == animeId })
    }

    func getWatchHistory() async -> [WatchProgress] {
        // 按最后观看时间排序
        return watchHistory.sorted { $0.lastWatchedAt > $1.lastWatchedAt }
    }

    func clearWatchHistory() async throws {
        watchHistory.removeAll()
        try saveItems(watchHistory, to: watchHistoryPath)
    }

    // MARK: - 下载记录

    func addDownloadRecord(_ record: DownloadRecord) async throws {
        downloads.append(record)
        try saveItems(downloads, to: downloadsPath)
    }

    func removeDownloadRecord(id: String) async throws {
        downloads.removeAll { $0.id == id }
        try saveItems(downloads, to: downloadsPath)
    }

    func getDownloads(for contentType: ContentType?) async -> [DownloadRecord] {
        if let type = contentType {
            return downloads.filter { $0.contentType == type }
        }
        return downloads
    }

    // MARK: - 获取所有内容

    func getAllItems(for contentType: ContentType) async -> LibraryItems {
        let favorites = await getFavorites(for: contentType)
        let downloaded = await getDownloads(for: contentType)

        return LibraryItems(
            favorites: favorites,
            downloads: downloaded
        )
    }

    // MARK: - 统计

    func getStats() async -> LibraryStats {
        return LibraryStats(
            wallpaperCount: wallpaperFavorites.count,
            animeCount: animeFavorites.count,
            videoCount: videoFavorites.count,
            totalDownloads: downloads.count,
            watchHistoryCount: watchHistory.count
        )
    }
}

// MARK: - 下载记录

struct DownloadRecord: Identifiable, Codable {
    let id: String
    let contentType: ContentType
    let itemId: String
    let title: String
    let thumbnailURL: String
    let downloadURL: String
    let localPath: String?
    let fileSize: String?
    let downloadedAt: Date
    let status: DownloadRecordStatus
}

enum DownloadRecordStatus: String, Codable {
    case pending, downloading, completed, failed
}

// MARK: - 库项目

struct LibraryItems {
    let favorites: [UniversalContentItem]
    let downloads: [DownloadRecord]
}

// MARK: - 库统计

struct LibraryStats {
    let wallpaperCount: Int
    let animeCount: Int
    let videoCount: Int
    let totalDownloads: Int
    let watchHistoryCount: Int

    var totalItems: Int {
        wallpaperCount + animeCount + videoCount
    }
}
