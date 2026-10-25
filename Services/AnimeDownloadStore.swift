import Foundation

// MARK: - 动漫下载记录
//
// 一条记录 = 一集已缓存的本地视频。ID 采用 "\(ruleId)__\(episodeId)"（与
// PlaybackProgressCache 的 progressId 拼法一致），保证同一集在不同源之间互不覆盖。
// 只存终态记录；下载中的任务状态由引擎层内存态管理，不进持久化。

struct AnimeDownloadRecord: Identifiable, Codable, Equatable {
    let id: String
    /// 动漫 ID（Bangumi/搜索结果 ID），用于按番剧聚合
    let animeId: String
    let animeTitle: String
    let coverURL: String?
    let sourceId: String
    let sourceName: String
    let episodeId: String
    let episodeName: String?
    let episodeNumber: Int
    /// 本地缓存文件绝对路径
    var localFilePath: String
    var downloadedAt: Date
    /// 文件字节数（用于展示与完整性校验）
    var fileSizeBytes: Int64
    /// 下载时的原始视频 URL（重新下载/校验时参考）
    var originalURL: String?
    /// 关联的下载文件夹（暂为 nil，保留与媒体库一致的结构）
    var folderID: String?

    init(
        anime: AnimeSearchResult,
        source: AnimeRule,
        episode: AnimeDetail.AnimeEpisodeItem,
        localFilePath: String,
        fileSizeBytes: Int64,
        originalURL: String?
    ) {
        self.id = AnimeDownloadRecord.recordID(ruleId: source.id, episodeId: episode.id)
        self.animeId = anime.id
        self.animeTitle = anime.title
        self.coverURL = anime.coverURL
        self.sourceId = source.id
        self.sourceName = source.name
        self.episodeId = episode.id
        self.episodeName = episode.name
        self.episodeNumber = episode.episodeNumber
        self.localFilePath = localFilePath
        self.downloadedAt = .now
        self.fileSizeBytes = fileSizeBytes
        self.originalURL = originalURL
        self.folderID = nil
    }

    static func recordID(ruleId: String, episodeId: String) -> String {
        "\(ruleId)__\(episodeId)"
    }

    var localFileURL: URL { URL(fileURLWithPath: localFilePath) }

    /// 文件是否仍存在于磁盘
    var fileExists: Bool {
        FileManager.default.fileExists(atPath: localFilePath)
    }
}

// MARK: - 下载组条目（我的库下载 tab 按番剧聚合展示）

struct AnimeDownloadGroupItem: Identifiable {
    let animeId: String
    let searchResult: AnimeSearchResult
    let downloadedCount: Int
    let recordIDs: Set<String>

    var id: String { animeId }
}

// MARK: - 动漫下载存储

@MainActor
final class AnimeDownloadStore: ObservableObject {
    static let shared = AnimeDownloadStore()

    private let cache = CachePersistenceService.shared
    private let downloadCategory = "anime/downloads"

    @Published private(set) var records: [String: AnimeDownloadRecord] = [:]

    private init() {
        // ⚠️ 不在 init 中读 UserDefaults，避免 _CFXPreferences 递归栈溢出
    }

    /// 延迟恢复持久化数据（在 AppDelegate.restoreAllDataAsync 中调用）
    func restoreSavedData() {
        loadFromDisk()
    }

    private func loadFromDisk() {
        let decoder = JSONDecoder()

        // 1) 分类索引 → 记录
        let cached: [AnimeDownloadRecord] = cache.loadAll(category: downloadCategory)
        if !cached.isEmpty {
            var dict: [String: AnimeDownloadRecord] = [:]
            for record in cached {
                dict[record.id] = record
            }
            records = dict
        }

        // 2) 孤儿恢复：索引丢失但记录文件还在
        let orphanedData = cache.recoverOrphanedRecordData(for: [downloadCategory])
        if let orphans = orphanedData[downloadCategory], !orphans.isEmpty {
            let recovered = orphans.compactMap { try? decoder.decode(AnimeDownloadRecord.self, from: $0) }
            let newRecords = recovered.filter { records[$0.id] == nil }
            if !newRecords.isEmpty {
                for record in newRecords {
                    records[record.id] = record
                }
                rebuildCache()
                print("[AnimeDownloadStore] Recovered \(newRecords.count) orphaned download records from disk")
            }
        }
    }

    // MARK: - Cache 辅助

    private func saveRecordToCache(_ record: AnimeDownloadRecord) {
        cache.save(record, key: "\(downloadCategory)/\(record.id)")
    }

    private func syncIndex() {
        cache.saveIndex(Array(records.keys), key: "index/\(downloadCategory)")
    }

    private func rebuildCache() {
        for record in records.values {
            saveRecordToCache(record)
        }
        syncIndex()
    }

    // MARK: - 查询

    func record(for episodeId: String, sourceId: String) -> AnimeDownloadRecord? {
        records[AnimeDownloadRecord.recordID(ruleId: sourceId, episodeId: episodeId)]
    }

    /// 该集是否有可用缓存（记录存在且文件还在）
    func availableRecord(for episodeId: String, sourceId: String) -> AnimeDownloadRecord? {
        guard let record = record(for: episodeId, sourceId: sourceId), record.fileExists else { return nil }
        return record
    }

    func isDownloaded(episodeId: String, sourceId: String) -> Bool {
        availableRecord(for: episodeId, sourceId: sourceId) != nil
    }

    /// 某部番的全部下载记录（跨源），按集数升序
    func records(forAnime animeId: String) -> [AnimeDownloadRecord] {
        records.values
            .filter { $0.animeId == animeId }
            .sorted { $0.episodeNumber < $1.episodeNumber }
    }

    /// 某部番有多少集已缓存
    func downloadedEpisodeCount(forAnime animeId: String) -> Int {
        records.values.filter { $0.animeId == animeId }.count
    }

    /// 全部记录（下载 tab 展示用），按下载时间倒序
    var allRecordsSortedByDate: [AnimeDownloadRecord] {
        records.values.sorted { $0.downloadedAt > $1.downloadedAt }
    }

    /// 下载 tab：按番剧聚合（每部番一组，组内取最新一条记录做封面/标题）
    var animeGroups: [AnimeDownloadGroupItem] {
        let byAnime = Dictionary(grouping: records.values) { $0.animeId }
        return byAnime.values
            .map { group -> AnimeDownloadGroupItem in
                let latest = group.max { $0.downloadedAt < $1.downloadedAt }!
                return AnimeDownloadGroupItem(
                    animeId: latest.animeId,
                    searchResult: AnimeSearchResult(
                        id: latest.animeId,
                        title: latest.animeTitle,
                        coverURL: latest.coverURL,
                        detailURL: "",
                        sourceId: "local",
                        sourceName: "Local",
                        latestEpisode: nil,
                        rating: nil
                    ),
                    downloadedCount: group.count,
                    recordIDs: Set(group.map(\.id))
                )
            }
            .sorted { $0.searchResult.title.localizedCompare($1.searchResult.title) == .orderedAscending }
    }

    // MARK: - 写入 / 删除

    func upsert(_ record: AnimeDownloadRecord) {
        records[record.id] = record
        saveRecordToCache(record)
        syncIndex()
    }

    func removeRecord(id: String, deleteFile: Bool) {
        guard let record = records.removeValue(forKey: id) else { return }
        cache.delete(key: "\(downloadCategory)/\(record.id)")
        syncIndex()
        if deleteFile {
            deletePhysicalFile(record.localFilePath)
        }
    }

    /// 删除某部番的全部缓存
    func removeRecords(forAnime animeId: String, deleteFiles: Bool) {
        let ids = records.values.filter { $0.animeId == animeId }.map(\.id)
        for id in ids {
            removeRecord(id: id, deleteFile: deleteFiles)
        }
    }

    private func deletePhysicalFile(_ path: String) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return }
        if fm.isDeletableFile(atPath: path) {
            try? fm.removeItem(atPath: path)
        }
    }
}
