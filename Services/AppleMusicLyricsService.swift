import Foundation
import Combine
import MusicKit
import StoreKit

// MARK: - Apple Music Lyrics (Host-only tokens, Web receives push only)
//
// Phase B：Host 鉴权 + 拉 TTML + 行对齐；经 WallpaperWebMediaRelay → daemon → JS。
// Web **永不**接触 developerToken / userToken。
//
// Token：
//   developerToken — env WAIFUX_APPLE_MUSIC_DEVELOPER_TOKEN，或抓 music.apple.com index~.js 中 WebPlayback JWT
//   userToken      — SKCloudServiceController.requestUserToken(forDeveloperToken:)
//
// 失败冷静：同一 trackKey 失败后 COOLDOWN 秒内不再请求。

public struct LyricLine: Equatable, Sendable {
    public var start: Double
    public var end: Double?
    public var text: String
}

public struct LyricsDoc: Equatable, Sendable {
    public var title: String
    public var artist: String
    public var songId: String
    public var storefront: String
    public var source: String
    public var lines: [LyricLine]

    public static let empty = LyricsDoc(
        title: "", artist: "", songId: "", storefront: "", source: "", lines: []
    )

    public var hasLyrics: Bool { !lines.isEmpty }
}

public struct LyricsLineState: Equatable, Sendable {
    public var index: Int
    public var text: String
    public var nextText: String
    public var previousText: String
    public var start: Double
    public var end: Double?
    public var progress: Double
    public var elapsedTime: Double
    public var hasLine: Bool

    public static let empty = LyricsLineState(
        index: -1, text: "", nextText: "", previousText: "",
        start: 0, end: nil, progress: 0, elapsedTime: 0, hasLine: false
    )
}

@MainActor
public final class AppleMusicLyricsService: ObservableObject {

    public static let shared = AppleMusicLyricsService()
    private static var developerTokenOverride: String?
    private static var storefrontOverride: String?

    static func configureEnvironment(developerToken: String, storefront: String) {
        developerTokenOverride = developerToken.isEmpty ? nil : developerToken
        storefrontOverride = storefront.isEmpty ? nil : storefront
        shared.tokens = nil
    }

    @Published public private(set) var currentDoc: LyricsDoc?
    @Published public private(set) var currentLine: LyricsLineState = .empty

    private var referenceCount = 0
    private var tokens: AppleMusicTokens?
    private var cache: [String: LyricsDoc] = [:]
    private var failedAt: [String: Date] = [:]
    private var currentKey: String?
    private var currentLineIndex: Int?
    private var inFlight: String?
    private var lastTrackTitle = ""
    private var lastTrackArtist = ""

    private let cooldown: TimeInterval = 20
    private let tokenTTL: TimeInterval = 45 * 60

    private init() {}

    // MARK: - Lifecycle

    public func start() {
        referenceCount += 1
        guard referenceCount == 1 else { return }
        print("[AppleMusicLyrics] started")
    }

    public func stop() {
        guard referenceCount > 0 else { return }
        referenceCount -= 1
        guard referenceCount == 0 else { return }
        clear()
        print("[AppleMusicLyrics] stopped")
    }

    public func clear() {
        currentKey = nil
        currentDoc = nil
        currentLineIndex = nil
        currentLine = .empty
        lastTrackTitle = ""
        lastTrackArtist = ""
        inFlight = nil
    }

    // MARK: - Track / tick

    /// 换歌时调用（title 空 → 清空）
    public func onTrackChanged(title: String, artist: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let a = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty {
            clear()
            return
        }
        let key = trackKey(title: t, artist: a)
        if key == currentKey { return }

        currentKey = key
        currentLineIndex = nil
        currentLine = .empty
        lastTrackTitle = t
        lastTrackArtist = a

        if let cached = cache[key] {
            currentDoc = cached
            print("[AppleMusicLyrics] cache hit key=\(key) lines=\(cached.lines.count)")
            return
        }

        currentDoc = nil

        if inFlight == key { return }
        if let at = failedAt[key], Date().timeIntervalSince(at) < cooldown {
            return
        }

        inFlight = key
        Task { @MainActor in
            defer {
                if self.inFlight == key { self.inFlight = nil }
            }
            do {
                let tok = try await self.ensureTokens()
                let doc = try await self.fetchLyrics(title: t, artist: a, tokens: tok)
                self.cache[key] = doc
                if self.currentKey == key {
                    self.currentDoc = doc
                    self.currentLineIndex = nil
                    print("[AppleMusicLyrics] loaded source=\(doc.source) songId=\(doc.songId) lines=\(doc.lines.count)")
                }
            } catch {
                self.failedAt[key] = Date()
                if self.currentKey == key {
                    self.currentDoc = nil
                    self.currentLine = .empty
                }
                print("[AppleMusicLyrics] fetch failed key=\(key) err=\(error.localizedDescription)")
            }
        }
    }

    /// 进度对齐当前行（由 media relay 定时调用）
    public func tick(elapsed: Double, isPlaying: Bool) {
        guard let doc = currentDoc, !doc.lines.isEmpty else {
            if currentLine.hasLine || currentLine.index != -1 {
                currentLine = .empty
            }
            return
        }
        let e = max(0, elapsed)
        let idx = Self.currentLineIndex(in: doc.lines, elapsed: e)
        if idx == currentLineIndex {
            // 同 index 也更新 progress
            if idx >= 0 {
                let next = Self.makeLineState(doc: doc, index: idx, elapsed: e)
                if abs(next.progress - currentLine.progress) > 0.02 || abs(next.elapsedTime - currentLine.elapsedTime) > 0.15 {
                    currentLine = next
                }
            }
            return
        }
        currentLineIndex = idx
        currentLine = Self.makeLineState(doc: doc, index: idx, elapsed: e)
    }

    // MARK: - Tokens

    private struct AppleMusicTokens {
        var developerToken: String
        var userToken: String
        var storefront: String
        var fetchedAt: Date
    }

    private func ensureTokens() async throws -> AppleMusicTokens {
        if let tokens,
           Date().timeIntervalSince(tokens.fetchedAt) < tokenTTL,
           !tokens.developerToken.isEmpty,
           !tokens.userToken.isEmpty {
            return tokens
        }

        let auth = await MusicAuthorization.request()
        guard auth == .authorized else {
            throw LyricsError.musicAuthorizationDenied
        }

        let dev = try await Self.resolveDeveloperToken()
        let user = try await Self.requestUserToken(developerToken: dev)
        guard !user.isEmpty else { throw LyricsError.emptyUserToken }

        let sf = await Self.resolveStorefront()
        let next = AppleMusicTokens(
            developerToken: dev,
            userToken: user,
            storefront: sf,
            fetchedAt: Date()
        )
        tokens = next
        print("[AppleMusicLyrics] tokens ready storefront=\(sf) devLen=\(dev.count) userLen=\(user.count)")
        return next
    }

    private static func resolveDeveloperToken() async throws -> String {
        if let developerTokenOverride { return developerTokenOverride }
        if let env = ProcessInfo.processInfo.environment["WAIFUX_APPLE_MUSIC_DEVELOPER_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty {
            return env
        }
        // 抓 music.apple.com 前端 bundle 里的 WebPlayback JWT（与业界常见做法一致）
        return try await scrapeWebPlaybackDeveloperToken()
    }

    private static func scrapeWebPlaybackDeveloperToken() async throws -> String {
        let session = URLSession.shared
        // 入口页 → 找 index~*.js
        guard let homeURL = URL(string: "https://music.apple.com/") else {
            throw LyricsError.developerTokenUnavailable
        }
        var homeReq = URLRequest(url: homeURL)
        homeReq.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        let (homeData, _) = try await session.data(for: homeReq)
        let homeHTML = String(data: homeData, encoding: .utf8) ?? ""

        // 匹配 script src 含 index 或 music-app
        let pattern = #"https://[^"']+(?:index|music)[^"']*\.js"#
        let regex = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        let ns = homeHTML as NSString
        let matches = regex.matches(in: homeHTML, options: [], range: NSRange(location: 0, length: ns.length))
        var candidates: [URL] = []
        for m in matches.prefix(8) {
            if let r = Range(m.range, in: homeHTML), let u = URL(string: String(homeHTML[r])) {
                candidates.append(u)
            }
        }
        // 兜底已知 CDN 模式（可能 404，再试下一页内链）
        if candidates.isEmpty {
            throw LyricsError.developerTokenUnavailable
        }

        let jwtPattern = try NSRegularExpression(
            pattern: #"eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#,
            options: []
        )

        for url in candidates {
            var req = URLRequest(url: url)
            req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
            guard let (data, resp) = try? await session.data(for: req),
                  let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let text = String(data: data, encoding: .utf8) else {
                continue
            }
            let tns = text as NSString
            let jm = jwtPattern.matches(in: text, options: [], range: NSRange(location: 0, length: tns.length))
            for m in jm {
                guard let r = Range(m.range, in: text) else { continue }
                let jwt = String(text[r])
                // 粗筛：payload 里常有 media-user / applemusic
                if jwt.count > 80, isLikelyMusicDeveloperJWT(jwt) {
                    return jwt
                }
            }
            // 次选：任意足够长的 JWT
            for m in jm {
                guard let r = Range(m.range, in: text) else { continue }
                let jwt = String(text[r])
                if jwt.count > 100 { return jwt }
            }
        }
        throw LyricsError.developerTokenUnavailable
    }

    private static func isLikelyMusicDeveloperJWT(_ jwt: String) -> Bool {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return false }
        var payload = String(parts[1])
        // base64url pad
        let pad = 4 - payload.count % 4
        if pad < 4 { payload += String(repeating: "=", count: pad) }
        payload = payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        // Apple Music WebPlayback 常见 claim
        if let iss = json["iss"] as? String, iss.contains("apple") { return true }
        if json["bid"] != nil || json["root"] != nil { return true }
        return false
    }

    private static func requestUserToken(developerToken: String) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let controller = SKCloudServiceController()
            controller.requestUserToken(forDeveloperToken: developerToken) { token, error in
                if let error {
                    cont.resume(throwing: error)
                    return
                }
                cont.resume(returning: token ?? "")
            }
        }
    }

    private static func resolveStorefront() async -> String {
        if let storefrontOverride { return storefrontOverride.lowercased() }
        if let env = ProcessInfo.processInfo.environment["WAIFUX_APPLE_MUSIC_STOREFRONT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty {
            return env.lowercased()
        }
        // SKCloud storefront（异步）
        if let sf = await requestStorefrontCountryCode(), !sf.isEmpty {
            return sf.lowercased()
        }
        // Locale 兜底
        if let region = Locale.current.region?.identifier.lowercased(), region.count == 2 {
            return region
        }
        return "cn"
    }

    private static func requestStorefrontCountryCode() async -> String? {
        await withCheckedContinuation { cont in
            SKCloudServiceController().requestStorefrontCountryCode { code, _ in
                cont.resume(returning: code)
            }
        }
    }

    // MARK: - Fetch lyrics

    private func fetchLyrics(title: String, artist: String, tokens: AppleMusicTokens) async throws -> LyricsDoc {
        let sf = tokens.storefront
        let term = artist.isEmpty ? title : "\(title) \(artist)"
        guard var comps = URLComponents(string: "https://api.music.apple.com/v1/catalog/\(sf)/search") else {
            throw LyricsError.badURL
        }
        comps.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "types", value: "songs"),
            URLQueryItem(name: "limit", value: "5"),
        ]
        guard let searchURL = comps.url else { throw LyricsError.badURL }

        var searchReq = URLRequest(url: searchURL)
        searchReq.setValue("Bearer \(tokens.developerToken)", forHTTPHeaderField: "Authorization")
        searchReq.setValue("https://music.apple.com", forHTTPHeaderField: "Origin")
        searchReq.setValue("https://music.apple.com/", forHTTPHeaderField: "Referer")
        searchReq.setValue("application/json", forHTTPHeaderField: "Accept")

        let (searchData, searchResp) = try await URLSession.shared.data(for: searchReq)
        guard let http = searchResp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw LyricsError.httpStatus((searchResp as? HTTPURLResponse)?.statusCode ?? -1, "search")
        }
        guard let root = try JSONSerialization.jsonObject(with: searchData) as? [String: Any],
              let results = root["results"] as? [String: Any],
              let songs = results["songs"] as? [String: Any],
              let dataArr = songs["data"] as? [[String: Any]],
              !dataArr.isEmpty else {
            throw LyricsError.noSearchHit
        }

        let song = Self.pickBestSong(dataArr, title: title, artist: artist)
        guard let songId = song["id"] as? String else { throw LyricsError.noSearchHit }
        let attrs = song["attributes"] as? [String: Any] ?? [:]
        let songTitle = (attrs["name"] as? String) ?? title
        let songArtist = (attrs["artistName"] as? String) ?? artist

        var ttml: String?
        var source: String?
        for kind in ["syllable-lyrics", "lyrics"] {
            guard let url = URL(string: "https://amp-api.music.apple.com/v1/catalog/\(sf)/songs/\(songId)/\(kind)") else {
                continue
            }
            var req = URLRequest(url: url)
            req.setValue("Bearer \(tokens.developerToken)", forHTTPHeaderField: "Authorization")
            req.setValue(tokens.userToken, forHTTPHeaderField: "Media-User-Token")
            req.setValue("media-user-token=\(tokens.userToken)", forHTTPHeaderField: "Cookie")
            req.setValue("https://music.apple.com", forHTTPHeaderField: "Origin")
            req.setValue("https://music.apple.com/", forHTTPHeaderField: "Referer")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("1", forHTTPHeaderField: "Music-User-Token")

            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  let h = resp as? HTTPURLResponse, h.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            if let extracted = Self.extractTtml(from: obj) {
                ttml = extracted
                source = kind
                break
            }
        }

        guard let ttml, let source else { throw LyricsError.noLyrics }
        let lines = Self.parseTtmlLines(ttml)
        guard !lines.isEmpty else { throw LyricsError.emptyTtml }

        return LyricsDoc(
            title: songTitle,
            artist: songArtist,
            songId: songId,
            storefront: sf,
            source: source,
            lines: lines
        )
    }

    private static func pickBestSong(_ songs: [[String: Any]], title: String, artist: String) -> [String: Any] {
        var best = songs[0]
        var bestScore = -1
        let lt = title.lowercased()
        let la = artist.lowercased()
        for s in songs {
            let attrs = s["attributes"] as? [String: Any] ?? [:]
            let n = ((attrs["name"] as? String) ?? "").lowercased()
            let a = ((attrs["artistName"] as? String) ?? "").lowercased()
            var score = 0
            if n == lt { score += 10 }
            else if n.contains(lt) || lt.contains(n) { score += 4 }
            if !la.isEmpty {
                if a == la { score += 8 }
                else if a.contains(la) || la.contains(a) { score += 3 }
            }
            if let has = attrs["hasLyrics"] as? Bool, has { score += 1 }
            if score > bestScore {
                bestScore = score
                best = s
            }
        }
        return best
    }

    private static func extractTtml(from obj: [String: Any]) -> String? {
        guard let data = obj["data"] as? [[String: Any]] else { return nil }
        for item in data {
            if let attrs = item["attributes"] as? [String: Any],
               let ttml = attrs["ttml"] as? String,
               !ttml.isEmpty {
                return ttml
            }
        }
        return nil
    }

    // MARK: - TTML parse

    static func parseTtmlLines(_ ttml: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        // <p begin="..." end="...">...</p>
        let pPattern = #"<p\b([^>]*)>([\s\S]*?)</p>"#
        guard let pRegex = try? NSRegularExpression(pattern: pPattern, options: [.caseInsensitive]) else {
            return []
        }
        let ns = ttml as NSString
        let matches = pRegex.matches(in: ttml, options: [], range: NSRange(location: 0, length: ns.length))
        for m in matches {
            guard m.numberOfRanges >= 3,
                  let attrRange = Range(m.range(at: 1), in: ttml),
                  let bodyRange = Range(m.range(at: 2), in: ttml) else { continue }
            let attrs = String(ttml[attrRange])
            let body = String(ttml[bodyRange])
            var begin = attrValue(attrs, "begin")
            if begin == nil {
                begin = firstSpanBegin(body)
            }
            guard let beginStr = begin, let start = parseTime(beginStr) else { continue }
            let endStr = attrValue(attrs, "end")
            let end = endStr.flatMap { parseTime($0) }
            let text = collapseWS(stripTags(body))
            if text.isEmpty { continue }
            lines.append(LyricLine(start: start, end: end, text: text))
        }

        if lines.isEmpty {
            // fallback: leaf <span begin end>text</span>
            let sPattern = #"<span\b([^>]*)>([^<]*)</span>"#
            if let sRegex = try? NSRegularExpression(pattern: sPattern, options: [.caseInsensitive]) {
                let sm = sRegex.matches(in: ttml, options: [], range: NSRange(location: 0, length: ns.length))
                for m in sm {
                    guard m.numberOfRanges >= 3,
                          let attrRange = Range(m.range(at: 1), in: ttml),
                          let bodyRange = Range(m.range(at: 2), in: ttml) else { continue }
                    let attrs = String(ttml[attrRange])
                    guard let beginStr = attrValue(attrs, "begin"), let start = parseTime(beginStr) else { continue }
                    let end = attrValue(attrs, "end").flatMap { parseTime($0) }
                    let text = collapseWS(String(ttml[bodyRange]))
                    if text.isEmpty { continue }
                    lines.append(LyricLine(start: start, end: end, text: text))
                }
            }
        }

        lines.sort { $0.start < $1.start }
        return lines
    }

    private static func attrValue(_ attrs: String, _ name: String) -> String? {
        let pattern = #"\#(name)\s*=\s*\"([^\"]+)\""#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = attrs as NSString
        guard let m = re.firstMatch(in: attrs, options: [], range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges >= 2,
              let r = Range(m.range(at: 1), in: attrs) else { return nil }
        return String(attrs[r])
    }

    private static func firstSpanBegin(_ body: String) -> String? {
        attrValue(body, "begin")
    }

    static func parseTime(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasSuffix("s"), let v = Double(t.dropLast()) { return v }
        let parts = t.split(separator: ":").map(String.init)
        if parts.count == 3,
           let h = Double(parts[0]), let m = Double(parts[1]), let sec = Double(parts[2]) {
            return h * 3600 + m * 60 + sec
        }
        if parts.count == 2,
           let m = Double(parts[0]), let sec = Double(parts[1]) {
            return m * 60 + sec
        }
        return Double(t)
    }

    private static func stripTags(_ html: String) -> String {
        html.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
    }

    private static func collapseWS(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Line index

    static func currentLineIndex(in lines: [LyricLine], elapsed: Double) -> Int {
        guard !lines.isEmpty else { return -1 }
        if elapsed < lines[0].start { return -1 }
        var idx = 0
        for (i, line) in lines.enumerated() {
            if line.start <= elapsed { idx = i }
            else { break }
        }
        return idx
    }

    static func makeLineState(doc: LyricsDoc, index: Int, elapsed: Double) -> LyricsLineState {
        if index < 0 {
            return LyricsLineState(
                index: -1,
                text: "",
                nextText: doc.lines.first?.text ?? "",
                previousText: "",
                start: 0,
                end: nil,
                progress: 0,
                elapsedTime: elapsed,
                hasLine: false
            )
        }
        let line = doc.lines[index]
        let next = index + 1 < doc.lines.count ? doc.lines[index + 1].text : ""
        let prev = index > 0 ? doc.lines[index - 1].text : ""
        let end = line.end ?? (index + 1 < doc.lines.count ? doc.lines[index + 1].start : nil)
        var progress = 0.0
        if let end, end > line.start {
            progress = min(1, max(0, (elapsed - line.start) / (end - line.start)))
        }
        return LyricsLineState(
            index: index,
            text: line.text,
            nextText: next,
            previousText: prev,
            start: line.start,
            end: end,
            progress: progress,
            elapsedTime: elapsed,
            hasLine: !line.text.isEmpty
        )
    }

    private func trackKey(title: String, artist: String) -> String {
        "\(title.lowercased())|\(artist.lowercased())"
    }
}

// MARK: - Errors

private enum LyricsError: LocalizedError {
    case musicAuthorizationDenied
    case emptyUserToken
    case developerTokenUnavailable
    case badURL
    case noSearchHit
    case noLyrics
    case emptyTtml
    case httpStatus(Int, String)

    var errorDescription: String? {
        switch self {
        case .musicAuthorizationDenied: return "MusicAuthorization denied"
        case .emptyUserToken: return "empty userToken — 需登录 Apple Music 并订阅"
        case .developerTokenUnavailable: return "developerToken unavailable (set WAIFUX_APPLE_MUSIC_DEVELOPER_TOKEN)"
        case .badURL: return "bad URL"
        case .noSearchHit: return "no search hit"
        case .noLyrics: return "no lyrics"
        case .emptyTtml: return "empty ttml"
        case .httpStatus(let c, let w): return "HTTP \(c) \(w)"
        }
    }
}
