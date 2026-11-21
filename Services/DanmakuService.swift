import Foundation

/// DanDanPlay API client. No search terms, request URLs, payloads or credentials are logged.
@MainActor
final class DanmakuService {
    static let shared = DanmakuService()

    private let baseURL = URL(string: "https://api.dandanplay.net/api/v2")!
    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.httpAdditionalHeaders = ["Accept": "application/json", "User-Agent": "WaifuX/1.0"]
        session = URLSession(configuration: config)
    }

    func searchAnime(keyword: String) async throws -> [DanmakuAnime] {
        let keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return [] }
        guard let data = try await request(path: "search/episodes", query: [
            URLQueryItem(name: "anime", value: keyword), URLQueryItem(name: "v2", value: "true")])
        else { return [] }
        return try await Self.decode(DanmakuSearchResponse.self, data: data).animes
    }

    func getDanmakuSourceByBangumiId(bangumiId: Int) async throws -> DanmakuAnime? {
        guard bangumiId > 0 else { throw DanmakuError.noData }
        guard let data = try await request(path: "bangumi/bgmtv/\(bangumiId)", allowNotFound: true) else { return nil }
        return try await Self.decodeBangumi(data)
    }

    func getAnime(animeID: Int) async throws -> DanmakuAnime? {
        guard animeID > 0 else { throw DanmakuError.noData }
        guard let data = try await request(path: "bangumi/\(animeID)", allowNotFound: true) else { return nil }
        return try await Self.decodeBangumi(data)
    }

    private nonisolated static func decodeBangumi(_ data: Data) async throws -> DanmakuAnime? {
        let response = try await decode(DanmakuBangumiResponse.self, data: data)
        guard response.success != false else { return nil }
        return response.bangumi
    }

    /// Prefer declared numbers/titles; retain the pinned upstream's numeric ID convention as fallback.
    private func matchingEpisode(in anime: DanmakuAnime, number: Int) -> DanmakuEpisode? {
        if let episode = anime.episodes.first(where: { Self.matches($0, number: number) }) { return episode }
        guard number >= 0, number < 10_000, anime.animeId > 0,
              anime.animeId <= (Int.max - number) / 10_000 else { return nil }
        let identity = anime.animeId * 10_000 + number
        return anime.episodes.first { $0.episodeId == identity }
    }

    func getDanmaku(episodeId: Int, withRelated: Bool = true) async throws -> [Danmaku] {
        guard episodeId > 0 else { throw DanmakuError.noData }
        guard let data = try await request(path: "comment/\(episodeId)",
                                           query: [URLQueryItem(name: "withRelated", value: String(withRelated))])
        else { return [] }
        return try await Self.decodeComments(data)
    }

    func getDanmaku(animeId: Int, episodeNumber: Int) async throws -> [Danmaku] {
        guard let anime = try await getAnime(animeID: animeId),
              let episode = matchingEpisode(in: anime, number: episodeNumber) else { return [] }
        return try await getDanmaku(episodeId: episode.episodeId)
    }

    func fetchDanmakuSmart(animeTitle: String, episodeNumber: Int) async throws -> [Danmaku] {
        let animes = try await searchAnime(keyword: animeTitle)
        guard let match = findBestMatch(animes: animes, title: animeTitle),
              let anime = try await getAnime(animeID: match.animeId),
              let episode = matchingEpisode(in: anime, number: episodeNumber) else { return [] }
        return try await getDanmaku(episodeId: episode.episodeId)
    }

    func fetchDanmakuByBangumiId(bangumiId: Int, episodeNumber: Int) async throws -> [Danmaku] {
        guard let anime = try await getDanmakuSourceByBangumiId(bangumiId: bangumiId),
              let episode = matchingEpisode(in: anime, number: episodeNumber) else { return [] }
        return try await getDanmaku(episodeId: episode.episodeId)
    }

    private func request(path: String, query: [URLQueryItem] = [], allowNotFound: Bool = false) async throws -> Data? {
        try Task.checkCancellation()
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        else { throw DanmakuError.invalidURL }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw DanmakuError.invalidURL }
        // 开放 API 强制鉴权：无凭证直接给出可行动错误，避免服务端 403 被误报为网络故障。
        guard let authHeaders = DanmakuCredentials.authenticationHeaders(path: url.path) else {
            throw DanmakuError.authenticationRequired
        }
        var request = URLRequest(url: url)
        for (field, value) in authHeaders { request.setValue(value, forHTTPHeaderField: field) }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch {
            try Task.checkCancellation()
            throw DanmakuError.networkError(error)
        }
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw DanmakuError.serverError }
        if allowNotFound && response.statusCode == 404 { return nil }
        if response.statusCode == 401 || response.statusCode == 403 {
            // 服务端鉴权拒绝（凭证缺失/失效/额度用尽），与网络错误区分。
            throw DanmakuError.authenticationRequired
        }
        guard response.statusCode == 200 else { throw DanmakuError.serverError }
        guard data.count <= 32 * 1024 * 1024 else { throw DanmakuError.decodingError }
        return data
    }

    /// Decoding and conversion run on the generic executor, away from the main actor's drawing work.
    private nonisolated static func decode<Value: Decodable & Sendable>(_ type: Value.Type, data: Data) async throws -> Value {
        try Task.checkCancellation()
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw DanmakuError.decodingError }
    }

    private nonisolated static func decodeComments(_ data: Data) async throws -> [Danmaku] {
        let response = try await decode(DanmakuCommentResponse.self, data: data)
        var result: [Danmaku] = []
        result.reserveCapacity(min(response.comments.count, 100_000))
        var seen = Set<UUID>()
        for comment in response.comments.prefix(100_000) {
            try Task.checkCancellation()
            let parts = comment.p.split(separator: ",", omittingEmptySubsequences: false)
            guard parts.count >= 3, let time = Double(parts[0]), time.isFinite, time >= 0,
                  let mode = Int(parts[1]), DanmakuMode(rawValue: mode) != nil,
                  let color = Int(parts[2]), (0...0xFFFFFF).contains(color),
                  !comment.m.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let item = Danmaku(from: comment)
            if seen.insert(item.id).inserted { result.append(item) }
        }
        // Keep raw text duplicates: the renderer applies the user's deduplication preference.
        return result.sorted { $0.time == $1.time ? $0.id.uuidString < $1.id.uuidString : $0.time < $1.time }
    }

    /// Match the whole episode number; episode 1 must never select episode 10 or 21.
    nonisolated static func matches(_ episode: DanmakuEpisode, number: Int) -> Bool {
        guard number >= 0 else { return false }
        let raw = episode.episodeNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = Double(raw), value.isFinite { return value == Double(number) }
        let patterns = [
            #"^\s*第?\s*([0-9]+)(?:\.0+)?\s*[集话話]?\s*$"#,
            #"(?:第\s*|\bEP(?:ISODE)?[\s._-]*)([0-9]+)(?:\.0+)?(?:\s*[集话話]|(?=\D|$))"#
        ]
        for candidate in [raw, episode.episodeTitle] {
            for pattern in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                      let match = regex.firstMatch(in: candidate, range: NSRange(candidate.startIndex..., in: candidate)),
                      let range = Range(match.range(at: 1), in: candidate),
                      let parsed = Int(candidate[range]) else { continue }
                return parsed == number
            }
        }
        return false
    }

    private func findBestMatch(animes: [DanmakuAnime], title: String) -> DanmakuAnime? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !title.isEmpty else { return nil }
        return animes.first { $0.animeTitle.lowercased() == title }
            ?? animes.first { $0.animeTitle.lowercased().contains(title) }
            ?? animes.first
    }
}

// MARK: - Error descriptions contain no underlying request/URL data.
enum DanmakuError: Error, LocalizedError, Equatable {
    case invalidURL
    case serverError
    case noData
    case decodingError
    case authenticationRequired
    case networkError(Error)

    static func == (lhs: DanmakuError, rhs: DanmakuError) -> Bool {
        switch (lhs, rhs) {
        case (.invalidURL, .invalidURL), (.serverError, .serverError), (.noData, .noData),
             (.decodingError, .decodingError), (.authenticationRequired, .authenticationRequired):
            return true
        case (.networkError, .networkError):
            return true
        default:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidURL: return t("无效的 URL")
        case .serverError: return t("error.server.title")
        case .noData: return t("没有数据")
        case .decodingError: return t("数据解析错误")
        case .authenticationRequired: return t("anime.player.danmakuAuthMissing")
        case .networkError: return t("danmaku.source.networkError")
        }
    }
}
