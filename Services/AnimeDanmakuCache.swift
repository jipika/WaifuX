import Foundation
import CryptoKit

/// Text-only cache and durable per-episode manual source choices.
/// No URL, request headers, cookies or credentials are persisted.
actor AnimeDanmakuCache {
    static let shared = AnimeDanmakuCache()

    private struct Key: Codable, Equatable {
        let animeId: String
        let episodeNumber: Int
    }

    private struct CachedEpisode: Codable {
        let version: Int
        let key: Key
        let manualEpisodeID: Int?
        let sourceRevision: UUID?
        let comments: [Danmaku]
    }

    private struct ManualSource: Codable {
        let version: Int
        let key: Key
        let episodeID: Int?
        let revision: UUID
    }

    private let rootDirectory: URL?
    private var inFlight = Set<String>()
    private let maximumFileSize = 32 * 1024 * 1024

    /// Tests may supply a repository tmp directory. No preferences are read during init.
    init(rootDirectory: URL? = nil) {
        self.rootDirectory = rootDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory,
                                                                       in: .userDomainMask).first?
            .appendingPathComponent("WaifuX/AnimeDanmaku", isDirectory: true)
    }

    func cached(animeId: String, episodeNumber: Int) -> [Danmaku]? {
        guard cacheIsEnabled(), let key = key(animeId, episodeNumber),
              let url = fileURL(key, kind: "comments"),
              let data = readData(url),
              let record = try? JSONDecoder().decode(CachedEpisode.self, from: data),
              record.version == 1, record.key == key,
              record.manualEpisodeID == manualEpisodeID(animeId: animeId, episodeNumber: episodeNumber),
              record.sourceRevision == manualSource(key)?.revision
        else { return nil }
        return record.comments
    }

    func store(_ comments: [Danmaku], animeId: String, episodeNumber: Int) {
        guard cacheIsEnabled(), let key = key(animeId, episodeNumber),
              let url = fileURL(key, kind: "comments") else { return }
        let valid = comments.filter { $0.time.isFinite && $0.time >= 0 && !$0.text.isEmpty }
        let record = CachedEpisode(version: 1, key: key,
                                   manualEpisodeID: manualEpisodeID(animeId: animeId, episodeNumber: episodeNumber),
                                   sourceRevision: manualSource(key)?.revision,
                                   comments: Array(valid.prefix(100_000)))
        write(record, to: url)
    }

    func manualEpisodeID(animeId: String, episodeNumber: Int) -> Int? {
        guard let key = key(animeId, episodeNumber),
              let id = manualSource(key)?.episodeID, id > 0 else { return nil }
        return id
    }

    /// Passing nil removes the override. An old comment record becomes a cache miss automatically.
    func setManualEpisodeID(_ episodeID: Int?, animeId: String, episodeNumber: Int) {
        guard let key = key(animeId, episodeNumber), let url = fileURL(key, kind: "source") else { return }
        let validID = episodeID.flatMap { $0 > 0 ? $0 : nil }
        // A new revision invalidates the old cache even when selecting the same source again.
        write(ManualSource(version: 1, key: key, episodeID: validID, revision: UUID()), to: url)
    }

    /// Download completion may call this from a background task. A failed prefetch never fails a download.
    /// A manual choice always wins over title matching, including when it is changed during a request.
    func cacheAfterDownload(animeId: String, title: String, episodeNumber: Int) async {
        // 开放 API 无凭证时不发预取请求（避免下载完成后批量 403）。
        guard DanmakuCredentials.isConfigured else { return }
        guard cacheIsEnabled(), let key = key(animeId, episodeNumber),
              cached(animeId: animeId, episodeNumber: episodeNumber) == nil else { return }
        let token = fileStem(key)
        guard inFlight.insert(token).inserted else { return }
        defer { inFlight.remove(token) }
        let selectedID = manualEpisodeID(animeId: animeId, episodeNumber: episodeNumber)
        let sourceRevision = manualSource(key)?.revision
        do {
            try Task.checkCancellation()
            let comments: [Danmaku]
            if let selectedID {
                comments = try await DanmakuService.shared.getDanmaku(episodeId: selectedID)
            } else {
                guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                comments = try await DanmakuService.shared.fetchDanmakuSmart(animeTitle: title,
                                                                            episodeNumber: episodeNumber)
            }
            try Task.checkCancellation()
            guard cacheIsEnabled(), selectedID == manualEpisodeID(animeId: animeId, episodeNumber: episodeNumber),
                  sourceRevision == manualSource(key)?.revision, !comments.isEmpty else { return }
            store(comments, animeId: animeId, episodeNumber: episodeNumber)
        } catch {
            // Expected for offline/unsupported sources. Never log request data or account state.
        }
    }

    private func manualSource(_ key: Key) -> ManualSource? {
        guard let url = fileURL(key, kind: "source"), let data = readData(url),
              let source = try? JSONDecoder().decode(ManualSource.self, from: data),
              source.version == 1, source.key == key else { return nil }
        return source
    }

    private func cacheIsEnabled() -> Bool {
        guard let data = WaifuXPreferences.shared.data(forKey: "danmakuSettings"),
              let settings = try? JSONDecoder().decode(DanmakuSettings.self, from: data) else { return true }
        return settings.cacheEnabled
    }

    private func key(_ animeId: String, _ episodeNumber: Int) -> Key? {
        guard !animeId.isEmpty, episodeNumber >= 0 else { return nil }
        return Key(animeId: animeId, episodeNumber: episodeNumber)
    }

    private func fileStem(_ key: Key) -> String {
        let identifier = "\(key.animeId.utf8.count):\(key.animeId):\(key.episodeNumber)"
        return SHA256.hash(data: Data(identifier.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func fileURL(_ key: Key, kind: String) -> URL? {
        rootDirectory?.appendingPathComponent(fileStem(key) + "." + kind + ".json", isDirectory: false)
    }

    private func readData(_ url: URL) -> Data? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= maximumFileSize else { return nil }
        return try? Data(contentsOf: url)
    }

    private func write<Value: Encodable>(_ value: Value, to url: URL) {
        guard let data = try? JSONEncoder().encode(value), data.count <= maximumFileSize else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            // Cache failure is recoverable and must not affect playback or downloads.
        }
    }
}
