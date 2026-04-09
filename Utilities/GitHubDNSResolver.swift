import Foundation

/// GitHub DNS 解析器
/// 使用 DNS over HTTPS (DoH) 实时解析 GitHub 域名的最新 IP
actor GitHubDNSResolver {
    
    static let shared = GitHubDNSResolver()
    
    /// DNS over HTTPS 服务
    private let dohServers = [
        "https://cloudflare-dns.com/dns-query",
        "https://dns.google/resolve",
        "https://doh.opendns.com/dns-query"
    ]
    
    /// 缓存解析结果
    private var cache: [String: DNSCacheEntry] = [:]
    
    /// 缓存有效期（5分钟）
    private let cacheTTL: TimeInterval = 300
    
    private struct DNSCacheEntry {
        let ips: [String]
        let timestamp: Date
        
        var isExpired: Bool {
            Date().timeIntervalSince(timestamp) > 300
        }
    }
    
    private init() {}
    
    /// 需要解析的 GitHub 关键域名
    static let githubDomains = [
        "github.com",
        "api.github.com",
        "raw.githubusercontent.com",
        "github.githubassets.com",
        "avatars.githubusercontent.com",
        "codeload.github.com"
    ]
    
    /// 解析域名的 IP 地址
    /// - Parameter domain: 域名
    /// - Returns: IP 地址数组
    func resolve(_ domain: String) async -> [String] {
        // 检查缓存
        if let cached = cache[domain], !cached.isExpired {
            return cached.ips
        }
        
        // 尝试多个 DoH 服务器
        for server in dohServers {
            if let ips = await resolveWithDoH(domain, server: server) {
                // 缓存结果
                cache[domain] = DNSCacheEntry(ips: ips, timestamp: Date())
                return ips
            }
        }
        
        // 如果 DoH 都失败，返回系统 DNS 结果
        return await resolveWithSystemDNS(domain)
    }
    
    /// 使用 DNS over HTTPS 解析
    private func resolveWithDoH(_ domain: String, server: String) async -> [String]? {
        guard let url = URL(string: "\(server)?name=\(domain)&type=A") else {
            return nil
        }
        
        var request = URLRequest(url: url)
        request.setValue("application/dns-json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 5
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return nil
            }
            
            // 解析 DNS JSON 响应
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let answers = json["Answer"] as? [[String: Any]] {
                
                let ips = answers.compactMap { answer -> String? in
                    guard let type = answer["type"] as? Int,
                          type == 1, // A record
                          let data = answer["data"] as? String else {
                        return nil
                    }
                    return data
                }
                
                return ips.isEmpty ? nil : ips
            }
            
            return nil
        } catch {
            print("[GitHubDNSResolver] DoH resolve failed for \(domain): \(error)")
            return nil
        }
    }
    
    /// 使用系统 DNS 解析（备选方案）
    private func resolveWithSystemDNS(_ domain: String) async -> [String] {
        let host = CFHostCreateWithName(nil, domain as CFString).takeRetainedValue()
        CFHostStartInfoResolution(host, .addresses, nil)
        
        var success: DarwinBoolean = false
        guard let addresses = CFHostGetAddressing(host, &success)?.takeUnretainedValue() as NSArray?,
              success.boolValue else {
            return []
        }
        
        var ips: [String] = []
        for case let address as Data in addresses {
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            address.withUnsafeBytes { pointer in
                guard let sockaddr = pointer.baseAddress?.assumingMemoryBound(to: sockaddr.self) else { return }
                getnameinfo(sockaddr, socklen_t(address.count), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
            }
            let ip = String(cString: hostname, encoding: .utf8) ?? ""
            if !ip.isEmpty && ip != "0.0.0.0" {
                ips.append(ip)
            }
        }
        
        return ips
    }
    
    /// 批量解析所有 GitHub 域名
    /// - Returns: 域名到 IP 的映射表
    func resolveAllGitHubDomains() async -> [String: String] {
        var results: [String: String] = [:]
        
        await withTaskGroup(of: (String, String?).self) { group in
            for domain in GitHubDNSResolver.githubDomains {
                group.addTask {
                    let ips = await self.resolve(domain)
                    return (domain, ips.first)
                }
            }
            
            for await (domain, ip) in group {
                if let ip = ip {
                    results[domain] = ip
                }
            }
        }
        
        return results
    }
    
    /// 获取最佳 IP（延迟最低）
    /// - Parameters:
    ///   - domain: 域名
    ///   - timeout: 超时时间
    /// - Returns: 最佳 IP
    func getBestIP(for domain: String, timeout: TimeInterval = 2) async -> String? {
        let ips = await resolve(domain)
        guard ips.count > 1 else { return ips.first }
        
        // 并发测试所有 IP 的延迟
        return await withTaskGroup(of: (String, TimeInterval)?.self) { group in
            for ip in ips {
                group.addTask {
                    let start = Date()
                    let result = await self.testIP(ip, timeout: timeout)
                    let latency = Date().timeIntervalSince(start)
                    return result ? (ip, latency) : nil
                }
            }
            
            var bestIP: String?
            var bestLatency: TimeInterval = .infinity
            
            for await case let (ip, latency)? in group {
                if latency < bestLatency {
                    bestLatency = latency
                    bestIP = ip
                }
            }
            
            return bestIP ?? ips.first
        }
    }
    
    /// 测试 IP 是否可用
    private func testIP(_ ip: String, timeout: TimeInterval) async -> Bool {
        // 简单的 TCP 连接测试
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = CFSwapInt16HostToBig(443)
        inet_pton(AF_INET, ip, &addr.sin_addr)
        
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        
        // 设置非阻塞和超时
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        
        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { addr in
                connect(fd, addr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        
        if result == 0 {
            return true // 立即连接成功
        }
        
        // 等待连接完成或超时
        var fdSet = fd_set()
        __darwin_fd_set(fd, &fdSet)
        
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        let selectResult = select(fd + 1, nil, &fdSet, nil, &tv)
        
        if selectResult > 0 {
            var error: Int32 = 0
            var errorLen = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &errorLen)
            return error == 0
        }
        
        return false
    }
    
    /// 清除缓存
    func clearCache() {
        cache.removeAll()
    }
}

