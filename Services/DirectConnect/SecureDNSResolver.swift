import Foundation
import Network

/// Resolve only known read-only endpoints. If DoH fails, the caller leaves system DNS to URLSession.
actor SecureDNSResolver {
    static let shared = SecureDNSResolver()

    private struct CacheEntry {
        let addresses: [String]
        let expires: ContinuousClock.Instant
    }

    private struct Answer: Decodable {
        let type: Int
        let TTL: Int
        let data: String
    }

    private struct DNSMessage: Decodable {
        let Status: Int
        let TC: Bool?
        let Answer: [Answer]?
    }

    private var cache: [String: CacheEntry] = [:]
    private var inFlight: [String: Task<CacheEntry, Never>] = [:]
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        // Inherit system proxies. A proxy enabled during a lookup must not be bypassed.
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 2
        config.waitsForConnectivity = false
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        return URLSession(configuration: config)
    }()

    private static let providers = ["https://doh.pub/dns-query", "https://cloudflare-dns.com/dns-query"]
    private static let eligibleHosts: Set<String> = ["konachan.com", "konachan.net", "i.pximg.net"]
    private static let poisonedPrefixes = ["199.59.", "69.171.", "31.13.", "108.160.", "128.121.", "185.60.", "69.63.", "103.252.", "157.240."]

    func resolve(host: String) async -> [String] {
        guard Self.eligibleHosts.contains(host), !Task.isCancelled else { return [] }
        if let entry = cache[host], entry.expires > .now { return entry.addresses }
        if let task = inFlight[host] { return await task.value.addresses }
        let session = self.session
        let task = Task { await Self.fetch(host: host, session: session) }
        inFlight[host] = task
        let result = await task.value
        cache[host] = result
        inFlight[host] = nil
        return result.addresses
    }

    private static func fetch(host: String, session: URLSession) async -> CacheEntry {
        await withTaskGroup(of: CacheEntry?.self) { group in
            for provider in providers {
                group.addTask {
                    guard var components = URLComponents(string: provider) else { return nil }
                    components.queryItems = [URLQueryItem(name: "name", value: host), URLQueryItem(name: "type", value: "A")]
                    guard let url = components.url else { return nil }
                    var request = URLRequest(url: url)
                    request.setValue("application/dns-json", forHTTPHeaderField: "Accept")
                    guard let (data, response) = try? await session.data(for: request),
                          let http = response as? HTTPURLResponse, http.statusCode == 200,
                          http.url?.host == components.host, http.url?.scheme == "https",
                          let parsed = parseARecords(data) else { return nil }
                    return CacheEntry(addresses: parsed.addresses, expires: .now.advanced(by: .seconds(parsed.ttl)))
                }
            }
            for await entry in group {
                if let entry { group.cancelAll(); return entry }
            }
            return CacheEntry(addresses: [], expires: .now.advanced(by: .seconds(5)))
        }
    }

    static func parseARecords(_ data: Data) -> (addresses: [String], ttl: Int)? {
        guard data.count <= 64 * 1024, let msg = try? JSONDecoder().decode(DNSMessage.self, from: data),
              msg.Status == 0, msg.TC != true, let answers = msg.Answer else { return nil }
        var addresses: [String] = []
        var ttl = 300
        for record in answers where record.type == 1 && record.TTL >= 0 && isAcceptable(record.data) {
            ttl = min(ttl, record.TTL)
            if !addresses.contains(record.data) { addresses.append(record.data) }
            if addresses.count == 16 { break }
        }
        return addresses.isEmpty ? nil : (addresses, ttl)
    }

    static func isAcceptable(_ ip: String) -> Bool {
        guard let address = IPv4Address(ip), address.debugDescription == ip else { return false }
        let bytes = Array(address.rawValue)
        let a = bytes[0], b = bytes[1], c = bytes[2]
        if a == 0 || a == 10 || a == 127 || a >= 224 { return false }
        if a == 100 && (64...127).contains(b) || a == 169 && b == 254 || a == 172 && (16...31).contains(b) { return false }
        if a == 192 && (b == 168 || (b == 0 && [0, 2].contains(c)) || (b == 88 && c == 99)) { return false }
        if a == 198 && ([18, 19].contains(b) || b == 51 && c == 100) || a == 203 && b == 0 && c == 113 { return false }
        return !poisonedPrefixes.contains(where: ip.hasPrefix)
    }
}
