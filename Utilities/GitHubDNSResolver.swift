import Foundation

/// GitHub DNS 解析器（已禁用，直接使用域名）
actor GitHubDNSResolver {
    
    static let shared = GitHubDNSResolver()
    
    private init() {}
    
    /// 需要解析的 GitHub 关键域名（保留作为参考）
    static let githubDomains = [
        "github.com",
        "api.github.com",
        "raw.githubusercontent.com",
        "github.githubassets.com",
        "avatars.githubusercontent.com",
        "codeload.github.com"
    ]
    
    /// 解析域名的 IP 地址（已禁用，始终返回空）
    func resolve(_ domain: String) async -> [String] {
        return []
    }
    
    /// 批量解析所有 GitHub 域名（已禁用，始终返回空）
    func resolveAllGitHubDomains() async -> [String: String] {
        return [:]
    }
    
    /// 获取最佳 IP（已禁用，始终返回 nil）
    func getBestIP(for domain: String, timeout: TimeInterval = 2) async -> String? {
        return nil
    }
    
    /// 清除缓存（空实现）
    func clearCache() {}
}
