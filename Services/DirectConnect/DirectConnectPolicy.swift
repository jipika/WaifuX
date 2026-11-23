import CFNetwork
import Foundation

/// 只处理已验证的只读 HTTPS 请求，不接管登录、写请求或其他源。
enum DirectConnectStrategy: Equatable {
    case konachanSNI
    case pixivImageNoSNI
    case pixivAPIQuic
    case none
}

final class DirectConnectPolicy: @unchecked Sendable {
    static let shared = DirectConnectPolicy()

    private let lock = NSLock()
    private var cachedTunnel: (active: Bool, until: ContinuousClock.Instant)?

    private init() {}

    static func strategy(for request: URLRequest, imagesOnly: Bool = false) -> DirectConnectStrategy {
        guard let url = request.url, let host = url.host?.lowercased(),
              url.scheme?.lowercased() == "https", url.port == nil || url.port == 443,
              url.user == nil, url.password == nil,
              (request.httpMethod ?? "GET").uppercased() == "GET",
              request.httpBody == nil, request.httpBodyStream == nil,
              request.value(forHTTPHeaderField: "Range") == nil else { return .none }
        if host == "i.pximg.net" { return .pixivImageNoSNI }
        let path = url.path
        if host == "konachan.com" || host == "konachan.net" {
            if path.hasPrefix("/image/") || path.hasPrefix("/sample/") || path.hasPrefix("/jpeg/") || path.hasPrefix("/preview/") {
                return .konachanSNI
            }
            if !imagesOnly && ["/post.json", "/tag.json"].contains(path) { return .konachanSNI }
        }
        if !imagesOnly && host == "www.pixiv.net" && path.hasPrefix("/ajax/") {
            return .pixivAPIQuic
        }
        return .none
    }

    func isActive() -> Bool {
        guard !WaifuXPreferences.shared.bool(forKey: "proxy_enabled") else { return false }
        let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] ?? [:]
        guard !Self.proxyConfigured(settings) else { return false }
        return !lock.withLock {
            let now = ContinuousClock.now
            if let cachedTunnel, now < cachedTunnel.until { return cachedTunnel.active }
            let active = Self.hasVPNInterface()
            cachedTunnel = (active, now.advanced(by: .seconds(30)))
            return active
        }
    }

    static func proxyConfigured(_ settings: [String: Any]) -> Bool {
        let keys = ["HTTPEnable", "HTTPSEnable", "SOCKSEnable", "ProxyAutoConfigEnable", "ProxyAutoDiscoveryEnable"]
        if keys.contains(where: { (settings[$0] as? NSNumber)?.boolValue == true }) { return true }
        for key in ["__SCOPED__", "__SUPPLEMENTAL__"] {
            if let scopes = settings[key] as? [String: [String: Any]],
               scopes.values.contains(where: proxyConfigured) { return true }
            if let scopes = settings[key] as? [[String: Any]],
               scopes.contains(where: proxyConfigured) { return true }
        }
        return false
    }

    /// macOS 可长期保留 UP/RUNNING 但只有 IPv6 link-local 的 utun；这不是可用 VPN 地址。
    static func isTunnelAddress(name: String, flags: UInt32, family: Int32, bytes: [UInt8]) -> Bool {
        guard ["utun", "ipsec", "ppp", "tun", "tap"].contains(where: name.hasPrefix),
              flags & UInt32(IFF_UP | IFF_RUNNING) == UInt32(IFF_UP | IFF_RUNNING) else { return false }
        if family == AF_INET, bytes.count == 4 {
            return bytes[0] != 0 && bytes[0] != 127 && !(bytes[0] == 169 && bytes[1] == 254)
        }
        if family == AF_INET6, bytes.count == 16 {
            return !(bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80) && bytes.dropLast().contains(where: { $0 != 0 })
        }
        return false
    }

    private static func hasVPNInterface() -> Bool {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return true }
        defer { freeifaddrs(head) }
        var node = head
        while let current = node {
            let entry = current.pointee
            node = entry.ifa_next
            guard let addr = entry.ifa_addr else { continue }
            let family = Int32(addr.pointee.sa_family)
            let bytes: [UInt8]
            switch family {
            case AF_INET:
                let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                bytes = withUnsafeBytes(of: ip) { Array($0) }
            case AF_INET6:
                let ip = addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                bytes = withUnsafeBytes(of: ip) { Array($0) }
            default:
                continue
            }
            if isTunnelAddress(name: String(cString: entry.ifa_name), flags: entry.ifa_flags, family: family, bytes: bytes) {
                return true
            }
        }
        return false
    }
}
