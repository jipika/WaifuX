import Foundation
import Network

/// Opt in only for the verified MXdm player/CDN pair. No global proxy or DNS settings are changed.
@MainActor
final class MXdmDirectHLS {
    private static let site = "www.dcc3.com"
    private nonisolated static let cdn = "svip.yzzy33-play.vip"
    private static let playlistLimit = 1024 * 1024
    private static let mediaLimit = 16 * 1024 * 1024

    private final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(request.url.map(MXdmDirectHLS.isCDN) == true ? request : nil)
        }
    }

    private enum RouteError: Error { case invalid, tooLarge, closed }
    private struct Response {
        let body: Data
        let info: HTTPURLResponse
    }

    private let session: URLSession
    private let listener: NWListener
    private let prefix = "/" + UUID().uuidString.lowercased() + "/"
    private let headers: [String: String]
    private var resources: [String: URL] = [:]
    private var paths: [URL: String] = [:]
    private var clients: [ObjectIdentifier: NWConnection] = [:]
    private var requests: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var deadlines: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var bound: CheckedContinuation<NWEndpoint.Port, any Error>?
    private var stopped = false

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
        return URLSession(configuration: config, delegate: RedirectGuard(), delegateQueue: nil)
    }

    /// Compare the same known CDN request on both routes. Only a system-route 403
    /// with a valid direct playlist qualifies; no authentication headers are forwarded.
    static func canRecover(_ url: URL, headers: [String: String]) async -> Bool {
        guard isCDN(url) else { return false }
        let system = makeSession(direct: false)
        let direct = makeSession(direct: true)
        defer { system.invalidateAndCancel(); direct.invalidateAndCancel() }
        do {
            let route = try await fetch(url, headers: headers, session: system, limit: playlistLimit)
            guard route.info.statusCode == 403 else { return false }
            try Task.checkCancellation()
            let other = try await fetch(url, headers: headers, session: direct, limit: playlistLimit)
            return (200..<300).contains(other.info.statusCode) && isPlaylist(other.body)
        } catch { return false }
    }

    private nonisolated static func fetch(_ url: URL, headers: [String: String], session: URLSession,
                                          limit: Int, range: String? = nil) async throws -> Response {
        guard isCDN(url) else { throw RouteError.invalid }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        for (name, value) in headers where ["referer", "user-agent"].contains(name.lowercased()) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }
        let (bytes, response) = try await session.bytes(for: request)
        guard let info = response as? HTTPURLResponse, let final = info.url, isCDN(final) else { throw RouteError.invalid }
        guard response.expectedContentLength <= Int64(limit) else { throw RouteError.tooLarge }
        var body = Data()
        for try await byte in bytes {
            guard body.count < limit else { throw RouteError.tooLarge }
            body.append(byte)
        }
        return Response(body: body, info: info)
    }

    private nonisolated static func isPlaylist(_ body: Data) -> Bool {
        String(decoding: body.prefix(128), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
            .hasPrefix("#EXTM3U")
    }

    init(headers: [String: String]) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        session = Self.makeSession(direct: true)
        self.headers = headers
    }

    deinit { listener.cancel(); session.invalidateAndCancel() }

    func start(at url: URL) async throws -> URL {
        let path = try localPath(for: url)
        let port = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !stopped, !Task.isCancelled else { continuation.resume(throwing: RouteError.closed); return }
                bound = continuation
                listener.newConnectionHandler = { [weak self] connection in
                    Task { @MainActor in
                        guard let self else { connection.cancel(); return }
                        self.accept(connection)
                    }
                }
                listener.stateUpdateHandler = { [weak self] state in
                    Task { @MainActor in self?.stateChanged(state) }
                }
                listener.start(queue: .main)
            } as NWEndpoint.Port
        } onCancel: {
            Task { @MainActor [weak self] in self?.stop() }
        }
        guard !stopped, let local = URL(string: "http://127.0.0.1:\(port.rawValue)\(path)") else { throw RouteError.closed }
        return local
    }

    private func stateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let port = listener.port else { stop(); return }
            let continuation = bound
            bound = nil
            continuation?.resume(returning: port)
        case .failed, .cancelled: stop()
        default: break
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        let continuation = bound
        bound = nil
        continuation?.resume(throwing: RouteError.closed)
        listener.cancel()
        for key in Array(clients.keys) { close(key) }
        session.invalidateAndCancel()
        resources.removeAll()
        paths.removeAll()
    }

    private func localPath(for url: URL) throws -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { throw RouteError.invalid }
        components.fragment = nil
        guard let clean = components.url, Self.isCDN(clean) else { throw RouteError.invalid }
        if let existing = paths[clean] { return existing }
        guard resources.count < 4096 else { throw RouteError.tooLarge }
        let ext = clean.pathExtension.lowercased()
        let suffix = ["m3u8", "ts", "m4s", "mp4", "aac", "key", "vtt"].contains(ext) ? "." + ext : ""
        let key = prefix + String(resources.count + 1) + suffix
        resources[key] = clean
        paths[clean] = key
        return key
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped, clients.count < 6 else { connection.cancel(); return }
        let id = ObjectIdentifier(connection)
        clients[id] = connection
        connection.start(queue: .main)
        deadlines[id] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(24)) } catch { return }
            self?.close(id)
        }
        receive(id, prefixData: Data())
    }

    private func close(_ id: ObjectIdentifier) {
        deadlines.removeValue(forKey: id)?.cancel()
        requests.removeValue(forKey: id)?.cancel()
        clients.removeValue(forKey: id)?.cancel()
    }

    private func receive(_ id: ObjectIdentifier, prefixData: Data) {
        clients[id]?.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, ended, error in
            Task { @MainActor in
                guard let self, self.clients[id] != nil else { return }
                guard error == nil else { self.close(id); return }
                var buffer = prefixData
                if let data { buffer.append(data) }
                guard buffer.count <= 12 * 1024 else { self.close(id); return }
                if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    self.respond(id, request: String(decoding: buffer[..<end.lowerBound], as: UTF8.self))
                } else if ended { self.close(id) }
                else { self.receive(id, prefixData: buffer) }
            }
        }
    }

    private func respond(_ id: ObjectIdentifier, request: String) {
        let lines = request.components(separatedBy: "\r\n")
        let words = lines.first?.split(separator: " ") ?? []
        guard words.count == 3, words[0] == "GET" || words[0] == "HEAD",
              let target = resources[String(words[1])] else { send(id, status: 404); return }
        let head = words[0] == "HEAD"
        let isHLS = target.pathExtension.lowercased() == "m3u8"
        let range = lines.dropFirst().first { $0.lowercased().hasPrefix("range:") }
            .map { $0.dropFirst(6).trimmingCharacters(in: .whitespaces) }
        let safeRange = range.flatMap { $0.range(of: #"^bytes=(?:[0-9]+-[0-9]*|-[0-9]+)$"#, options: .regularExpression) == nil ? nil : $0 }
        requests[id] = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await Self.fetch(target, headers: headers, session: session,
                                                    limit: isHLS ? Self.playlistLimit : Self.mediaLimit, range: isHLS ? nil : safeRange)
                guard !Task.isCancelled, clients[id] != nil else { return }
                let code = response.info.statusCode
                guard code == 200 || code == 206 else { send(id, status: 502); return }
                if Self.isPlaylist(response.body), let base = response.info.url {
                    let body = try rewrite(response.body, relativeTo: base)
                    send(id, status: 200, type: "application/vnd.apple.mpegurl", body: body, head: head)
                } else if !isHLS {
                    send(id, status: code, type: response.info.mimeType ?? "application/octet-stream", body: response.body,
                         head: head, range: response.info.value(forHTTPHeaderField: "Content-Range"))
                } else { send(id, status: 502) }
            } catch { send(id, status: 502) }
        }
    }

    private func rewrite(_ data: Data, relativeTo base: URL) throws -> Data {
        let matcher = try NSRegularExpression(pattern: #"\bURI="([^"\r\n]+)""#)
        func path(_ raw: String) throws -> String {
            guard let url = URL(string: raw, relativeTo: base)?.absoluteURL else { throw RouteError.invalid }
            return try localPath(for: url)
        }
        let lines = try String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map { raw in
            var line = String(raw).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
            guard !line.isEmpty else { return line }
            if !line.hasPrefix("#") { return try path(line) }
            // Content-steering manifests can supply arbitrary hosts and are not supported by this narrow route.
            guard !line.hasPrefix("#EXT-X-CONTENT-STEERING"), !line.hasPrefix("#EXT-X-DEFINE") else { throw RouteError.invalid }
            let declaration = line
            for match in matcher.matches(in: declaration, range: NSRange(declaration.startIndex..., in: declaration)).reversed() {
                guard let original = Range(match.range(at: 1), in: declaration),
                      let replacement = Range(match.range(at: 1), in: line) else { throw RouteError.invalid }
                line.replaceSubrange(replacement, with: try path(String(declaration[original])))
            }
            return line
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    private func send(_ id: ObjectIdentifier, status: Int, type: String = "text/plain", body: Data = Data(),
                      head: Bool = false, range: String? = nil) {
        guard let client = clients[id] else { return }
        let reason = [200: "OK", 206: "Partial Content", 404: "Not Found", 502: "Bad Gateway"][status] ?? "Error"
        let safeType = type.range(of: #"^[a-zA-Z0-9.+_-]+/[a-zA-Z0-9.+_-]+$"#, options: .regularExpression) != nil ? type : "application/octet-stream"
        var headers = "HTTP/1.1 \(status) \(reason)\r\nConnection: close\r\nContent-Type: \(safeType)\r\nContent-Length: \(body.count)\r\n"
        if let range, range.range(of: #"^bytes [0-9]+-[0-9]+/(?:[0-9]+|\*)$"#, options: .regularExpression) != nil { headers += "Content-Range: \(range)\r\n" }
        var response = Data((headers + "\r\n").utf8)
        if !head { response.append(body) }
        client.send(content: response, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in self?.close(id) }
        })
    }
}
