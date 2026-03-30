import Foundation

// MARK: - 数据源规则配置（参考 Kazumi）

struct DataSourceRule: Identifiable, Codable {
    let id: String
    let name: String
    let version: String
    let api: String

    // 内容类型
    let contentType: ContentType
    let sourceType: String

    // 功能开关
    let deprecated: Bool
    let useWebview: Bool
    let multiSources: Bool

    // 请求配置
    let baseURL: String
    let headers: [String: String]?
    let timeout: Int?

    // XPath 解析规则
    let xpath: XPathRules

    enum CodingKeys: String, CodingKey {
        case id, name, version, api
        case contentType, sourceType
        case deprecated
        case useWebview = "useWebview"
        case multiSources = "multiSources"
        case baseURL, headers, timeout
        case xpath
    }
}

// MARK: - XPath 规则

struct XPathRules: Codable {
    let search: SearchXPath?
    let detail: DetailXPath?
    let list: ListXPath?
}

struct SearchXPath: Codable {
    let url: String
    let list: String
    let title: String
    let cover: String
    let detail: String
    let id: String?

    enum CodingKeys: String, CodingKey {
        case url, list, title, cover, detail, id
    }
}

struct DetailXPath: Codable {
    let title: String
    let cover: String?
    let description: String?

    // 壁纸专用
    let fullImage: String?
    let resolution: String?
    let fileSize: String?

    // 动漫专用
    let episodes: String?
    let episodeName: String?
    let episodeLink: String?
    let episodeThumb: String?

    enum CodingKeys: String, CodingKey {
        case title, cover, description
        case fullImage, resolution, fileSize
        case episodes, episodeName, episodeLink, episodeThumb
    }
}

struct ListXPath: Codable {
    let url: String
    let list: String
    let title: String
    let cover: String
    let detail: String
    let nextPage: String?

    enum CodingKeys: String, CodingKey {
        case url, list, title, cover, detail, nextPage
    }
}

// MARK: - 规则错误

enum RuleError: Error, LocalizedError {
    case invalidURL
    case invalidRule
    case downloadFailed
    case ruleNotFound(String)
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .invalidRule:
            return "Invalid rule format"
        case .downloadFailed:
            return "Failed to download rule"
        case .ruleNotFound(let id):
            return "Rule not found: \(id)"
        case .parseError(let msg):
            return "Parse error: \(msg)"
        }
    }
}
