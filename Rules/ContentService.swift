import Foundation

actor ContentService {
    static let shared = ContentService()

    func fetchList(from ruleId: String, route: Route, page: Int) async throws -> [UniversalContentItem] {
        guard let rule = await RuleLoader.shared.rule(id: ruleId) else {
            throw ContentError.ruleNotFound
        }

        let urlString: String
        switch route {
        case .home:
            urlString = rule.xpath.list?.url.replacingOccurrences(of: "{page}", with: String(page)) ?? rule.baseURL
        case .search(let keyword):
            urlString = rule.xpath.search?.url
                .replacingOccurrences(of: "{keyword}", with: keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")
                .replacingOccurrences(of: "{page}", with: String(page)) ?? rule.baseURL
        case .detail:
            throw ContentError.invalidRoute
        }

        guard let url = URL(string: urlString) else {
            throw ContentError.invalidURL
        }

        var request = URLRequest(url: url)
        request.allHTTPHeaderFields = rule.headers
        request.timeoutInterval = TimeInterval(rule.timeout)

        let (data, _) = try await URLSession.shared.data(for: request)

        let items = try parseList(data: data, rule: rule)
        return items
    }

    func fetchDetail(from ruleId: String, id: String) async throws -> UniversalContentItem {
        guard let rule = await RuleLoader.shared.rule(id: ruleId) else {
            throw ContentError.ruleNotFound
        }

        let urlString = rule.baseURL + id
        guard let url = URL(string: urlString) else {
            throw ContentError.invalidURL
        }

        var request = URLRequest(url: url)
        request.allHTTPHeaderFields = rule.headers
        request.timeoutInterval = TimeInterval(rule.timeout)

        let (data, _) = try await URLSession.shared.data(for: request)

        let item = try parseDetail(data: data, id: id, rule: rule)
        return item
    }

    private func parseList(data: Data, rule: DataSourceRule) throws -> [UniversalContentItem] {
        return []
    }

    private func parseDetail(data: Data, id: String, rule: DataSourceRule) throws -> UniversalContentItem {
        throw ContentError.parseError
    }
}

enum ContentError: Error {
    case ruleNotFound
    case invalidURL
    case invalidRoute
    case parseError
    case networkError
}
