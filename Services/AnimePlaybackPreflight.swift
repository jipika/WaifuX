import Foundation
import OSLog

/// 播放前预探测：在把 URL 交给 AVPlayer 之前，用轻量请求确认媒体真的可取。
/// - m3u8：取播放列表正文（#EXTM3U），master 则跟最佳 variant，再对首个分片做小 Range GET。
/// - mp4 等直链：Range GET 前 64KB，确认 2xx/206 且正文不是 HTML。
/// - 系统路由被拒（403 等）而直连可取时，标记 needsDirectRelay，由播放侧走回环直连中继。
/// 探测只做只读 GET，不改系统代理；所有请求带解析阶段的请求头（Referer/UA/Cookie）。
enum AnimePlaybackPreflight {
    private static let logger = Logger(subsystem: "com.waifux.app", category: "AnimePreflight")

    struct Verdict {
        /// 可交给播放器（探测通过，或证据不足但值得试播）。
        var playable: Bool
        /// 系统路由失败但直连验证通过：播放需走 DirectHLSRelay。
        var needsDirectRelay: Bool = false
        /// 探测确认失败的原因（供日志/恢复链决策；playable=true 时为 nil）。
        var failure: String?
        /// 探测确认过的最终媒体 URL（master m3u8 展开后的 media playlist；其余为原 URL）。
        var resolvedURL: URL?
        /// 探测阶段抓到的播放列表正文（下载引擎可复用，避免二次请求）。
        var playlistBody: Data?

        static let pass = Verdict(playable: true)
        static func fail(_ reason: String) -> Verdict { Verdict(playable: false, failure: reason) }
    }

    private struct FetchResult {
        let body: Data
        let status: Int
        let url: URL
        let mime: String
    }

    private enum FetchError: Error { case http(Int), notHTTP, tooLarge, transport(Error) }

    /// 单候选探测预算：整体 ~8s。证据不足（超时/网络错误）不判死，交给播放器兜底。
    static func check(_ source: VideoSource, timeout: TimeInterval = 8) async -> Verdict {
        guard let url = URL(string: source.url), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return .fail("invalid-url")
        }
        if url.isFileURL { return .pass }
        let headers = source.httpHeaders ?? [:]
        let isHLS = source.type.lowercased() == "m3u8" || url.pathExtension.lowercased() == "m3u8"
        let deadline = Date().addingTimeInterval(timeout)

        if isHLS {
            return await checkHLS(url: url, headers: headers, deadline: deadline)
        }
        return await checkDirect(url: url, headers: headers, deadline: deadline)
    }

    // MARK: - HLS

    private static func checkHLS(url: URL, headers: [String: String], deadline: Date) async -> Verdict {
        // 1) 系统路由取播放列表。
        let systemResult = await fetchPlaylist(url: url, headers: headers, direct: false, deadline: deadline)
        switch systemResult {
        case .success(let fetched):
            return await validatePlaylist(fetched, headers: headers, direct: false, deadline: deadline)
        case .failure(let error):
            // 2) 系统路由被拒/失败：对照直连。只有「系统失败 + 直连成功」才判 relay。
            guard Date() < deadline else { return .pass }
            let directResult = await fetchPlaylist(url: url, headers: headers, direct: true, deadline: deadline)
            if case .success(let fetched) = directResult {
                let verdict = await validatePlaylist(fetched, headers: headers, direct: true, deadline: deadline)
                if verdict.playable {
                    var relay = verdict
                    relay.needsDirectRelay = true
                    logger.notice("preflight_direct_relay host=\(url.host ?? "?", privacy: .public) systemError=\(String(describing: error), privacy: .public)")
                    return relay
                }
                return verdict
            }
            // 两条路由都失败：HTTP 拒绝判死；网络级错误（超时/DNS）不判死，播放器兜底。
            if case .failure(let directError) = directResult, case FetchError.http(let code) = directError,
               code == 401 || code == 403 || code == 404 || code == 410 || code >= 500 {
                return .fail("playlist-http-\(code)")
            }
            if case FetchError.http(let code) = error, code == 404 || code == 410 {
                return .fail("playlist-http-\(code)")
            }
            return .pass
        }
    }

    private static func validatePlaylist(_ fetched: FetchResult, headers: [String: String],
                                         direct: Bool, deadline: Date) async -> Verdict {
        guard isPlaylist(fetched.body) else {
            // 200 但正文是 HTML/其它：这不是媒体，判死（广告页/防盗链页的典型形态）。
            return .fail("playlist-not-hls")
        }
        let text = String(decoding: fetched.body, as: UTF8.self)
        // master playlist：跟 BANDWIDTH 最高的 variant（Kazumi bestVariant 同款）。
        if text.contains("#EXT-X-STREAM-INF") {
            guard let variant = bestVariantURL(in: text, base: fetched.url) else {
                return .fail("playlist-empty-master")
            }
            guard Date() < deadline else { return passWith(fetched) }
            let nested = await fetchPlaylist(url: variant, headers: headers, direct: direct, deadline: deadline)
            switch nested {
            case .success(let media):
                guard isPlaylist(media.body) else { return .fail("variant-not-hls") }
                var verdict = await checkFirstSegment(playlist: media, headers: headers, direct: direct, deadline: deadline)
                if verdict.playable { verdict.resolvedURL = media.url; verdict.playlistBody = media.body }
                return verdict
            case .failure(let error):
                if case FetchError.http(let code) = error, code == 404 || code == 410 { return .fail("variant-http-\(code)") }
                // variant 取不到但 master 有效：不判死。
                return passWith(fetched)
            }
        }
        var verdict = await checkFirstSegment(playlist: fetched, headers: headers, direct: direct, deadline: deadline)
        if verdict.playable { verdict.resolvedURL = fetched.url; verdict.playlistBody = fetched.body }
        return verdict
    }

    private static func passWith(_ fetched: FetchResult) -> Verdict {
        var verdict = Verdict.pass
        verdict.resolvedURL = fetched.url
        verdict.playlistBody = fetched.body
        return verdict
    }

    /// 首个分片小 Range GET：确认分片真的能下（防盗链在分片层拦截的站很多）。
    private static func checkFirstSegment(playlist: FetchResult, headers: [String: String],
                                          direct: Bool, deadline: Date) async -> Verdict {
        let text = String(decoding: playlist.body, as: UTF8.self)
        guard let segment = firstSegmentURL(in: text, base: playlist.url) else {
            // 空列表/纯注释：判死。
            return .fail("playlist-no-segments")
        }
        guard Date() < deadline else { return .pass }
        let session = makeSession(direct: direct, timeout: min(4, max(1, deadline.timeIntervalSinceNow)))
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: segment, cachePolicy: .reloadIgnoringLocalCacheData)
        applyHeaders(headers, to: &request)
        request.setValue("bytes=0-65535", forHTTPHeaderField: "Range")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { return .pass }
            // 200/206 都算通过；403/401/404/410/5xx 判死；其余不判死。
            if (200...299).contains(http.statusCode) {
                var count = 0
                for try await _ in bytes { count += 1; if count >= 1024 { break } }
                return .pass
            }
            if [401, 403, 404, 410].contains(http.statusCode) || http.statusCode >= 500 {
                return .fail("segment-http-\(http.statusCode)")
            }
            return .pass
        } catch {
            return .pass
        }
    }

    // MARK: - 直链（mp4 等）

    private static func checkDirect(url: URL, headers: [String: String], deadline: Date) async -> Verdict {
        let system = await probeRange(url: url, headers: headers, direct: false, deadline: deadline)
        switch system {
        case .success(let result):
            if looksLikeHTML(result.body) { return .fail("direct-html-body") }
            return .pass
        case .failure(let error):
            guard Date() < deadline else { return .pass }
            let direct = await probeRange(url: url, headers: headers, direct: true, deadline: deadline)
            if case .success(let result) = direct {
                if looksLikeHTML(result.body) { return .fail("direct-html-body") }
                var verdict = Verdict.pass
                verdict.needsDirectRelay = true
                logger.notice("preflight_direct_relay host=\(url.host ?? "?", privacy: .public) systemError=\(String(describing: error), privacy: .public)")
                return verdict
            }
            if case .failure(let directError) = direct, case FetchError.http(let code) = directError,
               code == 401 || code == 403 || code == 404 || code == 410 || code >= 500 {
                return .fail("direct-http-\(code)")
            }
            if case FetchError.http(let code) = error, code == 404 || code == 410 {
                return .fail("direct-http-\(code)")
            }
            return .pass
        }
    }

    private static func probeRange(url: URL, headers: [String: String], direct: Bool,
                                   deadline: Date) async -> Result<FetchResult, FetchError> {
        let session = makeSession(direct: direct, timeout: min(5, max(1, deadline.timeIntervalSinceNow)))
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        applyHeaders(headers, to: &request)
        request.setValue("bytes=0-65535", forHTTPHeaderField: "Range")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { return .failure(.notHTTP) }
            guard (200...299).contains(http.statusCode) else { return .failure(.http(http.statusCode)) }
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count >= 65536 { break }
            }
            return .success(FetchResult(body: body, status: http.statusCode,
                                        url: http.url ?? url, mime: http.mimeType ?? ""))
        } catch {
            return .failure(.transport(error))
        }
    }

    // MARK: - 播放列表获取与解析

    private static func fetchPlaylist(url: URL, headers: [String: String], direct: Bool,
                                      deadline: Date) async -> Result<FetchResult, FetchError> {
        let session = makeSession(direct: direct, timeout: min(5, max(1, deadline.timeIntervalSinceNow)))
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        applyHeaders(headers, to: &request)
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { return .failure(.notHTTP) }
            guard (200...299).contains(http.statusCode) else { return .failure(.http(http.statusCode)) }
            guard response.expectedContentLength <= 2 * 1024 * 1024 else { return .failure(.tooLarge) }
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count > 2 * 1024 * 1024 { return .failure(.tooLarge) }
            }
            return .success(FetchResult(body: body, status: http.statusCode,
                                        url: http.url ?? url, mime: http.mimeType ?? ""))
        } catch {
            return .failure(.transport(error))
        }
    }

    static func isPlaylist(_ body: Data) -> Bool {
        String(decoding: body.prefix(256), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
            .hasPrefix("#EXTM3U")
    }

    static func looksLikeHTML(_ body: Data) -> Bool {
        let head = String(decoding: body.prefix(512), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return head.hasPrefix("<!doctype html") || head.hasPrefix("<html") || head.hasPrefix("<?xml")
    }

    /// master playlist 里 BANDWIDTH 最高的 variant URL（相对路径按 base 展开）。
    static func bestVariantURL(in text: String, base: URL) -> URL? {
        var best: (bandwidth: Int, url: URL)?
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        for (index, line) in lines.enumerated() where line.hasPrefix("#EXT-X-STREAM-INF") {
            guard index + 1 < lines.count else { continue }
            let next = lines[index + 1]
            guard !next.isEmpty, !next.hasPrefix("#"),
                  let url = URL(string: next, relativeTo: base)?.absoluteURL,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { continue }
            let bandwidth = line.range(of: #"BANDWIDTH=(\d+)"#, options: .regularExpression)
                .flatMap { Int(line[$0].dropFirst("BANDWIDTH=".count)) } ?? 0
            if best == nil || bandwidth > best!.bandwidth { best = (bandwidth, url) }
        }
        return best?.url
    }

    /// media playlist 的首个分片 URL（跳过注释与空行；嵌套 m3u8 也返回，由调用方决定）。
    static func firstSegmentURL(in text: String, base: URL) -> URL? {
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"),
                  let url = URL(string: line, relativeTo: base)?.absoluteURL,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { continue }
            return url
        }
        return nil
    }

    // MARK: - 会话与请求头

    private static func makeSession(direct: Bool, timeout: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        if direct { config.connectionProxyDictionary = [:] }
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout + 2
        return URLSession(configuration: config)
    }

    private static func applyHeaders(_ headers: [String: String], to request: inout URLRequest) {
        for (name, value) in headers {
            // Range/Host/Content-Length 由探测自己控制。
            if ["range", "host", "content-length"].contains(name.lowercased()) { continue }
            request.setValue(value, forHTTPHeaderField: name)
        }
    }
}