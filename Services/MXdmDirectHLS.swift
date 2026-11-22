import Foundation
import Network

/// MXdm 已验证站点/CDN 对的窄路径快速恢复（提取阶段短路用）。
/// 通用「系统代理拒绝 + 直连可取」的回环中继见 DirectHLSRelay（预探测阶段启用）。
/// 不改任何全局代理或 DNS 设置。
@MainActor
final class MXdmDirectHLS {
    private static let site = "www.dcc3.com"
    private nonisolated static let cdn = "svip.yzzy33-play.vip"
    private nonisolated static let playlistLimit = 1024 * 1024

    private let relay: DirectHLSRelay

    private nonisolated static func isCDN(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == cdn &&
            (url.port == nil || url.port == 443) && url.user == nil && url.password == nil
    }

    static func eligible(_ url: URL, page: String, ruleID: String) -> Bool {
        guard ruleID.lowercased() == "mxdm", url.pathExtension.lowercased() == "m3u8", isCDN(url),
              let page = URL(string: page), page.scheme == "https", page.host?.lowercased() == site,
              page.path.hasPrefix("/play/") else { return false }
        return true
    }

    private nonisolated static func makeSession(direct: Bool) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        if direct { config.connectionProxyDictionary = [:] }
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 20
        return URLSession(configuration: config)
    }

    /// Compare the same known CDN request on both routes. Only a system-route 403
    /// with a valid direct playlist qualifies; no authentication headers are forwarded.
    static func canRecover(_ url: URL, headers: [String: String]) async -> Bool {
        guard isCDN(url) else { return false }
        let system = makeSession(direct: false)
        let direct = makeSession(direct: true)
        defer { system.invalidateAndCancel(); direct.invalidateAndCancel() }
        do {
            let route = try await fetch(url, headers: headers, session: system)
            guard route.status == 403 else { return false }
            try Task.checkCancellation()
            let other = try await fetch(url, headers: headers, session: direct)
            return (200..<300).contains(other.status) && isPlaylist(other.body)
        } catch { return false }
    }

    private nonisolated static func fetch(_ url: URL, headers: [String: String],
                                          session: URLSession) async throws -> (status: Int, body: Data) {
        guard isCDN(url) else { throw URLError(.badURL) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        for (name, value) in headers where ["referer", "user-agent"].contains(name.lowercased()) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let (bytes, response) = try await session.bytes(for: request)
        guard let info = response as? HTTPURLResponse, let final = info.url, isCDN(final) else { throw URLError(.badServerResponse) }
        guard response.expectedContentLength <= Int64(playlistLimit) else { throw URLError(.dataLengthExceedsMaximum) }
        var body = Data()
        for try await byte in bytes {
            guard body.count < playlistLimit else { throw URLError(.dataLengthExceedsMaximum) }
            body.append(byte)
        }
        return (info.statusCode, body)
    }

    private nonisolated static func isPlaylist(_ body: Data) -> Bool {
        String(decoding: body.prefix(128), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
            .hasPrefix("#EXTM3U")
    }

    init(headers: [String: String]) throws {
        relay = try DirectHLSRelay(mediaHost: Self.cdn, headers: headers)
    }

    func start(at url: URL) async throws -> URL {
        guard Self.isCDN(url) else { throw URLError(.badURL) }
        return try await relay.start(at: url)
    }

    func stop() { relay.stop() }
}