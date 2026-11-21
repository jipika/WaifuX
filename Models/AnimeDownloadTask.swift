import Foundation
import CryptoKit

/// 队列快照不包含规则副本、请求头、媒体 URL 或 URLSession 的明文 resumeData。
/// 恢复时按 sourceID 读取现行规则，再独立解析剧集页面。
struct AnimeDownloadTaskDescriptor: Codable, Identifiable {
    let id: String
    let animeID: String
    let animeTitle: String
    let detailPageURL: String?
    let sourceID: String
    let sourceName: String
    let episodeID: String
    let episodePageURL: String?
    let episodeName: String?
    let episodeNumber: Int
    let createdAt: Date

    init(anime: AnimeSearchResult, source: AnimeRule, episode: AnimeDetail.AnimeEpisodeItem) {
        id = Self.identity(sourceID: source.id, episodeID: episode.id)
        animeID = Self.safeIdentifier(anime.id)
        animeTitle = anime.title
        detailPageURL = Self.detailLocator(anime.detailURL, source: source)
        sourceID = source.id
        sourceName = source.name
        episodeID = Self.safeIdentifier(episode.id)
        episodePageURL = Self.pageURL(episode.url)
        episodeName = episode.name
        episodeNumber = episode.episodeNumber
        createdAt = .now
    }

    static func identity(sourceID: String, episodeID: String) -> String {
        digest(AnimeDownloadRecord.recordID(ruleId: sourceID, episodeId: episodeID))
    }

    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 仅保留可重建页面所需的常见公开标识参数；签名、令牌、用户信息和 fragment 不落盘。
    /// 直接媒体链接不属于页面，恢复时必须重新从详情页查找。
    static func pageURL(_ value: String) -> String? {
        guard var components = URLComponents(string: value),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.host != nil else { return nil }
        let ext = (components.path as NSString).pathExtension.lowercased()
        guard !["m3u8", "mp4", "m4v", "webm", "mkv", "ts", "m4s", "aac"].contains(ext) else { return nil }
        components.user = nil
        components.password = nil
        components.fragment = nil
        let publicKeys = Set(["id", "vid", "sid", "ep", "episode", "episodeid", "chapter", "chapterid", "road", "line", "play", "page"])
        components.queryItems = components.queryItems?.filter {
            publicKeys.contains($0.name.lowercased()) && ($0.value?.count ?? 0) <= 128
        }
        if components.queryItems?.isEmpty == true { components.queryItems = nil }
        return components.url?.absoluteString
    }

    /// API 详情可使用公开数字 ID；网页详情必须同源，避免把 Bangumi 页面送给站点规则。
    static func detailLocator(_ value: String, source: AnimeRule) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed.count <= 32, trimmed.allSatisfy({ $0.isNumber }) { return trimmed }
        guard let page = pageURL(trimmed), let host = URL(string: page)?.host,
              let sourceHost = URL(string: source.baseURL)?.host,
              host.caseInsensitiveCompare(sourceHost) == .orderedSame else { return nil }
        return page
    }

    static func safeIdentifier(_ value: String) -> String {
        if let url = URL(string: value), url.scheme != nil {
            return pageURL(value) ?? "sha256:" + digest(value)
        }
        return value
    }
}

enum AnimeDownloadTaskStatus: String, Codable {
    case queued, resolving, downloading, merging, paused, failed, completed, cancelled

    var isActive: Bool { [.queued, .resolving, .downloading, .merging].contains(self) }
    var canResume: Bool { [.paused, .failed, .cancelled].contains(self) }

    var displayName: String {
        switch self {
        case .queued: return t("等待下载")
        case .resolving: return t("正在重新解析")
        case .downloading: return t("正在下载")
        case .merging: return t("正在合成")
        case .paused: return t("已暂停")
        case .failed: return t("下载失败")
        case .completed: return t("下载完成")
        case .cancelled: return t("已取消")
        }
    }
}

struct AnimeDownloadQueueSnapshot: Codable {
    struct Entry: Codable {
        let descriptor: AnimeDownloadTaskDescriptor
        let status: AnimeDownloadTaskStatus
        let progress: Double
        let downloadedBytes: Int64
        let totalBytes: Int64?
    }
    let version: Int
    let entries: [Entry]
}

/// 绑定实际 URL 与 URLRequest 合并后的有效请求头；落盘的值只有 SHA-256。
enum AnimeDownloadRequestFingerprint {
    static func make(url: URL, headers: [String: String]) -> String {
        var request = URLRequest(url: url)
        request.allHTTPHeaderFields = headers
        let effectiveHeaders: [String: String] = request.allHTTPHeaderFields ?? [:]
        var fields: [(name: String, value: String)] = []
        fields.reserveCapacity(effectiveHeaders.count)
        for (name, value) in effectiveHeaders {
            fields.append((name: name.lowercased(), value: value))
        }
        fields.sort { left, right -> Bool in
            if left.name == right.name {
                return left.value < right.value
            }
            return left.name < right.name
        }
        var bytes = Data(url.absoluteString.utf8)
        for (name, value) in fields {
            bytes.append(0)
            bytes.append(contentsOf: name.utf8)
            bytes.append(0)
            bytes.append(contentsOf: value.utf8)
        }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
