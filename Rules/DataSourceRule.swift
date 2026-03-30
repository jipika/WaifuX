import Foundation

struct DataSourceRule: Identifiable, Codable {
    let id: String
    let name: String
    let version: String
    let api: String
    let contentType: ContentType
    let sourceType: String
    let deprecated: Bool
    let useWebview: Bool
    let multiSources: Bool
    let baseURL: String
    let headers: [String: String]
    let timeout: Int
    let xpath: XPathRules

    enum CodingKeys: String, CodingKey {
        case id, name, version, api, contentType, sourceType, deprecated
        case useWebview = "useWebview"
        case multiSources = "multiSources"
        case baseURL = "baseURL"
        case headers, timeout, xpath
    }
}

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
}

struct DetailXPath: Codable {
    let title: String
    let cover: String
    let description: String?
    let episodes: String?
    let episodeName: String?
    let episodeLink: String?
    let episodeThumb: String?
    let fullImage: String?
    let resolution: String?
    let fileSize: String?
}

struct ListXPath: Codable {
    let url: String
    let list: String
    let title: String
    let cover: String
    let detail: String
    let nextPage: String?
}

enum Route {
    case home
    case search(keyword: String)
    case detail(id: String)
}
