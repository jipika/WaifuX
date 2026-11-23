import Foundation

/// Proxy-first fallback, injected at the two existing HTTP entry points.
actor DirectConnectRouter {
    struct Terminal: Error {
        let underlying: NetworkError
    }

    typealias Resolve = @Sendable (String) async -> [String]
    typealias Get = @Sendable (URL, String, Bool, [String: String], TimeInterval) async throws -> DirectTransport.Response

    static let shared = DirectConnectRouter(
        allowsDirect: { DirectConnectPolicy.shared.isActive() },
        resolve: { await SecureDNSResolver.shared.resolve(host: $0) },
        get: { try await DirectTransport.get(url: $0, ip: $1, sni: $2, headers: $3, timeout: $4) },
        cookieStorage: .shared
    )

    private let allowsDirect: @Sendable () -> Bool
    private let resolve: Resolve
    private let get: Get
    private let cookieStorage: HTTPCookieStorage?
    private var running = 0

    init(allowsDirect: @escaping @Sendable () -> Bool, resolve: @escaping Resolve,
         get: @escaping Get, cookieStorage: HTTPCookieStorage? = nil) {
        self.allowsDirect = allowsDirect
        self.resolve = resolve
        self.get = get
        self.cookieStorage = cookieStorage
    }

    /// nil means the request should use its existing URLSession path, without any proxy override.
    func attempt(request: URLRequest) async throws -> DirectTransport.Response? {
        let strategy = DirectConnectPolicy.strategy(for: request)
        // The experimental HTTP/3 implementation did not pass the end-to-end gate.
        // Keep Pixiv AJAX on its original stack instead of starting a doomed DoH lookup.
        guard strategy == .konachanSNI || strategy == .pixivImageNoSNI,
              let url = request.url, let host = url.host, allowsDirect(), running < 4 else { return nil }
        try Task.checkCancellation()
        running += 1
        defer { running -= 1 }
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        let addresses = await resolve(host)
        try Task.checkCancellation()
        guard !addresses.isEmpty else { return nil }
        let sni = strategy == .konachanSNI
        let route = sni ? "konachan-tls" : "pixiv-image-tls"
        var headers = request.allHTTPHeaderFields ?? [:]
        if !sni {
            headers = headers.filter { $0.key.caseInsensitiveCompare("Referer") != .orderedSame }
            headers["Referer"] = "https://www.pixiv.net/"
        }
        if request.httpShouldHandleCookies, request.value(forHTTPHeaderField: "Cookie") == nil,
           let cookies = cookieStorage?.cookies(for: url), !cookies.isEmpty {
            headers.merge(HTTPCookie.requestHeaderFields(with: cookies)) { current, _ in current }
        }

        var last: Error = URLError(.timedOut)
        for index in 0..<(sni ? 3 : min(2, addresses.count)) {
            try Task.checkCancellation()
            guard allowsDirect() else { return nil }
            let remaining = ContinuousClock.now.duration(to: deadline).components
            let seconds = min(6, Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18)
            guard seconds > 0 else { break }
            AppLogger.throttled(.info, .directConnect, key: "direct-\(route)-attempt", interval: 30,
                                "route=\(route) attempt=\(index + 1)")
            let response: DirectTransport.Response
            do {
                response = try await get(url, addresses[index % addresses.count], sni, headers, seconds)
            } catch is CancellationError {
                throw CancellationError()
            } catch DirectTransport.TransportError.tooLarge {
                return nil // preserve URLSession's downloadable-file path and limits
            } catch DirectTransport.TransportError.unsupportedResponse {
                return nil // let URLSession handle content encodings
            } catch {
                last = error
                continue
            }
            try Task.checkCancellation()
            if (300...399).contains(response.status) { return nil } // URLSession handles redirects and credentials.
            if Self.isChallenge(response) {
                throw Terminal(underlying: .loginRequired(message: NetworkError.cloudflareBlockedMessage))
            }
            guard (200...299).contains(response.status) else {
                throw Terminal(underlying: .httpError(response.status))
            }
            if request.httpShouldHandleCookies {
                for field in response.cookies {
                    let cookies = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": field], for: url)
                    cookieStorage?.setCookies(cookies, for: url, mainDocumentURL: nil)
                }
            }
            AppLogger.throttled(.info, .directConnect, key: "direct-\(route)-success", interval: 30,
                                "route=\(route) status=\(response.status)")
            return response
        }
        AppLogger.throttled(.warn, .directConnect, key: "direct-\(route)-failed", interval: 30,
                            "route=\(route) outcome=exhausted")
        if (last as? URLError)?.code == .timedOut { throw Terminal(underlying: .timeout) }
        throw Terminal(underlying: .networkError(last))
    }

    private static func isChallenge(_ response: DirectTransport.Response) -> Bool {
        guard response.status == 403 || response.status == 503 else { return false }
        if response.headers["cf-mitigated"]?.lowercased() == "challenge" { return true }
        let body = String(decoding: response.body.prefix(2048), as: UTF8.self).lowercased()
        return body.contains("just a moment") || body.contains("challenges.cloudflare")
    }
}
