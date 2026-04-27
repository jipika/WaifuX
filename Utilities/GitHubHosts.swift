import Foundation

/// GitHub Hosts 配置（已禁用 IP 直连，直接使用域名）
enum GitHubHosts {
    
    /// 是否启用 GitHub Hosts 加速（始终禁用，直接使用域名）
    nonisolated(unsafe) static var isEnabled = false
    
    /// 获取当前 hosts 表（始终返回空，禁用 IP 直连）
    static var hosts: [String: String] {
        return [:]
    }
    
    /// 刷新 hosts（空实现，不再解析 IP）
    static func refreshHosts() async {
        // 已禁用 IP 直连，直接使用域名
    }
    
    /// 将 GitHub URL 转换为使用 IP 的 URL（始终返回 nil）
    static func resolveURL(_ urlString: String) -> URL? {
        return nil
    }
    
    /// 获取用于请求的头信息（始终返回空）
    static func headers(for urlString: String) -> [String: String] {
        return [:]
    }
    
    /// 检查 URL 是否是 GitHub 相关域名
    static func isGitHubURL(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString),
              let host = url.host else {
            return false
        }
        return host.contains("github")
    }

    /// 为 GitHub 相关请求准备 `URLRequest`（直接返回原始请求）
    static func urlRequest(forGitHubURL url: URL) -> URLRequest {
        return URLRequest(url: url)
    }
}

// MARK: - NetworkService 扩展

extension NetworkService {
    
    /// 解析 GitHub URL（已禁用 IP 直连，始终返回原始 URL）
    static func resolveGitHubURL(_ url: URL) -> (URL, String?) {
        return (url, nil)
    }
}
