import Foundation

/// GitHub Hosts 加速配置
/// 支持静态 hosts + 动态 DNS 解析
enum GitHubHosts {
    
    /// 静态 hosts 映射表（备选）
    /// 来源: https://github.com/oopsunix/hosts
    static let fallbackHosts: [String: String] = [
        "github.io": "185.199.109.153",
        "github.dev": "52.224.38.193",
        "github.blog": "192.0.66.2",
        "github.community": "140.82.113.18",
        "githubstatus.com": "185.199.108.153",
        "github.com": "140.82.113.4",
        "alive.github.com": "140.82.114.26",
        "api.github.com": "140.82.113.6",
        "central.github.com": "140.82.112.21",
        "codeload.github.com": "140.82.112.10",
        "collector.github.com": "140.82.112.22",
        "gist.github.com": "140.82.114.3",
        "live.github.com": "140.82.114.26",
        "github.githubassets.com": "185.199.108.154",
        "avatars.githubusercontent.com": "185.199.108.133",
        "avatars0.githubusercontent.com": "185.199.108.133",
        "avatars1.githubusercontent.com": "185.199.108.133",
        "avatars2.githubusercontent.com": "185.199.108.133",
        "avatars3.githubusercontent.com": "185.199.108.133",
        "avatars4.githubusercontent.com": "185.199.108.133",
        "avatars5.githubusercontent.com": "185.199.108.133",
        "camo.githubusercontent.com": "185.199.108.133",
        "cloud.githubusercontent.com": "185.199.108.133",
        "copilot-proxy.githubusercontent.com": "20.85.130.105",
        "desktop.githubusercontent.com": "185.199.108.133",
        "favicons.githubusercontent.com": "185.199.111.133",
        "raw.githubusercontent.com": "185.199.111.133",
        "media.githubusercontent.com": "185.199.108.133",
        "objects.githubusercontent.com": "185.199.108.133",
        "user-images.githubusercontent.com": "185.199.108.133",
        "pipelines.actions.githubusercontent.com": "13.107.42.16",
        "github-cloud.s3.amazonaws.com": "3.5.20.192",
        "github-com.s3.amazonaws.com": "52.217.69.164",
        "github-production-release-asset-2e65be.s3.amazonaws.com": "16.15.189.14",
        "github-production-repository-file-5c1aeb.s3.amazonaws.com": "52.216.8.59",
        "github-production-user-asset-6210df.s3.amazonaws.com": "3.5.29.129",
        "github.map.fastly.net": "185.199.108.133",
        "github.global.ssl.fastly.net": "199.232.89.194",
        "vscode.dev": "13.107.246.40"
    ]
    
    /// 当前使用的 hosts 表（动态更新）
    private nonisolated(unsafe) static var dynamicHosts: [String: String] = [:]
    private nonisolated(unsafe) static var lastUpdate: Date = .distantPast
    private static let updateInterval: TimeInterval = 300 // 5分钟更新一次
    
    /// 是否启用 GitHub Hosts 加速
    nonisolated(unsafe) static var isEnabled = true
    
    /// 获取当前 hosts 表
    static var hosts: [String: String] {
        // 如果动态解析结果较新，优先使用
        if Date().timeIntervalSince(lastUpdate) < updateInterval && !dynamicHosts.isEmpty {
            return dynamicHosts
        }
        return fallbackHosts
    }
    
    /// 刷新 hosts（异步更新）
    static func refreshHosts() async {
        guard Date().timeIntervalSince(lastUpdate) > 60 else { return } // 至少间隔1分钟
        
        let resolved = await GitHubDNSResolver.shared.resolveAllGitHubDomains()
        await MainActor.run {
            dynamicHosts = resolved
            lastUpdate = Date()
        }
        print("[GitHubHosts] ✅ 已更新 hosts，共 \(resolved.count) 个域名")
    }
    
    /// 将 GitHub URL 转换为使用 IP 的 URL
    /// - Parameter urlString: 原始 GitHub URL
    /// - Returns: 转换后的 URL（如果 hosts 中有对应映射）
    static func resolveURL(_ urlString: String) -> URL? {
        guard isEnabled,
              let url = URL(string: urlString),
              let host = url.host,
              let ip = hosts[host] else {
            return nil
        }
        
        // 构建新的 URL，使用 IP 但保留 Host 头
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.host = ip
        
        return components?.url
    }
    
    /// 获取用于请求的头信息（包含原始 Host）
    /// - Parameter urlString: 原始 URL
    /// - Returns: 请求头字典
    static func headers(for urlString: String) -> [String: String] {
        guard isEnabled,
              let url = URL(string: urlString),
              let host = url.host,
              hosts[host] != nil else {
            return [:]
        }
        
        return ["Host": host]
    }
    
    /// 检查 URL 是否是 GitHub 相关域名
    static func isGitHubURL(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString),
              let host = url.host else {
            return false
        }
        return hosts[host] != nil || host.contains("github")
    }

    /// 为 GitHub 相关请求准备 `URLRequest`：与 `NetworkService` 一致，`isEnabled == false` 时不改写 URL（走系统 DNS / VPN）。
    static func urlRequest(forGitHubURL url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        guard isEnabled,
              let host = url.host,
              hosts[host] != nil,
              let resolvedURL = resolveURL(url.absoluteString) else {
            return request
        }
        request.url = resolvedURL
        request.setValue(host, forHTTPHeaderField: "Host")
        return request
    }
}

// MARK: - NetworkService 扩展

extension NetworkService {
    
    /// 解析 GitHub URL，返回 (实际请求URL, 原始Host)
    /// 如果不是 GitHub 域名或 hosts 未启用，返回原始 URL 和 nil
    static func resolveGitHubURL(_ url: URL) -> (URL, String?) {
        guard GitHubHosts.isEnabled,
              let resolvedURL = GitHubHosts.resolveURL(url.absoluteString) else {
            return (url, nil)
        }
        
        return (resolvedURL, url.host)
    }
}
