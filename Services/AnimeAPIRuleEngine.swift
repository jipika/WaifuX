import Foundation
import CryptoKit

/// The restricted JSONPath grammar implemented by the pinned Kazumi engine.
/// Unsupported expressions fail explicitly instead of looking like an empty result.
enum AnimeJSONPath {
    private enum Segment { case key(String), index(Int), wildcard }
    private static func segments(_ expression: String) throws -> [Segment] {
        let chars = Array(expression)
        func invalid() -> AnimeRuleCompatibilityError { .init(reason: "Unsupported JSONPath: \(expression)") }
        guard chars.first == "$" else { throw invalid() }
        var i = 1
        var result: [Segment] = []
        while i < chars.count {
            if chars[i] == "." {
                i += 1
                let start = i
                while i < chars.count && String(chars[i]).range(of: "[A-Za-z0-9_$-]", options: .regularExpression) != nil { i += 1 }
                guard i > start else { throw invalid() }
                result.append(.key(String(chars[start..<i])))
            } else if chars[i] == "[" {
                i += 1
                while i < chars.count && chars[i].isWhitespace { i += 1 }
                guard i < chars.count else { throw invalid() }
                if chars[i] == "\"" || chars[i] == "'" {
                    let quote = chars[i]
                    i += 1
                    var key = ""
                    while i < chars.count && chars[i] != quote {
                        if chars[i] == "\\" {
                            i += 1
                            guard i < chars.count else { throw invalid() }
                        }
                        key.append(chars[i]); i += 1
                    }
                    guard i < chars.count else { throw invalid() }
                    i += 1
                    result.append(.key(key))
                } else {
                    let start = i
                    while i < chars.count && chars[i] != "]" { i += 1 }
                    let token = String(chars[start..<i]).trimmingCharacters(in: .whitespaces)
                    if token == "*" { result.append(.wildcard) }
                    else if token.allSatisfy({ $0.isNumber }), let index = Int(token) { result.append(.index(index)) }
                    else { throw invalid() }
                }
                while i < chars.count && chars[i].isWhitespace { i += 1 }
                guard i < chars.count && chars[i] == "]" else { throw invalid() }
                i += 1
            } else { throw invalid() }
        }
        return result
    }
    static func validate(_ expression: String) throws { _ = try segments(expression) }
    static func read(_ document: AnimeJSONValue, _ expression: String) throws -> [AnimeJSONValue] {
        var nodes = [document]
        for segment in try segments(expression) {
            nodes = nodes.flatMap { node -> [AnimeJSONValue] in
                switch (segment, node) {
                case (.key(let key), .object(let object)): return object[key].map { [$0] } ?? []
                case (.index(let index), .array(let array)): return array.indices.contains(index) ? [array[index]] : []
                case (.wildcard, .array(let array)): return array
                case (.wildcard, .object(let object)): return object.keys.sorted().compactMap { object[$0] }
                default: return []
                }
            }
        }
        return nodes
    }
    static func first(_ document: AnimeJSONValue, _ expression: String) throws -> AnimeJSONValue? {
        try read(document, expression).first
    }
}

/// Pure request/response transformations are exposed for isolated, no-network tests.
enum AnimeAPIRuleEngine {
    private static let variableRegex = try! NSRegularExpression(pattern: "(?<![A-Za-z0-9_])@([A-Za-z_][A-Za-z0-9_]*)")
    private static let componentCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    private static func encoded(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: componentCharacters) ?? value }

    static func render(_ template: String, variables: [String: AnimeJSONValue], encode: Bool = false) throws -> String {
        var output = template
        for match in variableRegex.matches(in: template, range: NSRange(template.startIndex..., in: template)).reversed() {
            let name = String(template[Range(match.range(at: 1), in: template)!])
            guard let value = variables[name] else { throw AnimeRuleCompatibilityError(reason: "Missing template variable @\(name)") }
            output.replaceSubrange(Range(match.range, in: output)!, with: encode ? encoded(value.templateText) : value.templateText)
        }
        return output
    }
    private static func renderValue(_ value: AnimeJSONValue, _ variables: [String: AnimeJSONValue]) throws -> AnimeJSONValue {
        switch value {
        case .string(let s):
            let matches = variableRegex.matches(in: s, range: NSRange(s.startIndex..., in: s))
            if let match = matches.first, matches.count == 1, match.range == NSRange(s.startIndex..., in: s) {
                let key = String(s[Range(match.range(at: 1), in: s)!])
                guard let result = variables[key] else { throw AnimeRuleCompatibilityError(reason: "Missing template variable @\(key)") }
                return result
            }
            return .string(try render(s, variables: variables))
        case .array(let array): return .array(try array.map { try renderValue($0, variables) })
        case .object(let object): return .object(try object.mapValues { try renderValue($0, variables) })
        default: return value
        }
    }
    private static func renderMap(_ map: [String: AnimeJSONValue], _ variables: [String: AnimeJSONValue]) throws -> [String: AnimeJSONValue] {
        var result: [String: AnimeJSONValue] = [:]
        for (key, value) in map { result[try render(key, variables: variables)] = try renderValue(value, variables) }
        return result
    }
    private static func withQuery(_ url: String, query: [String: AnimeJSONValue]) throws -> String {
        guard var components = URLComponents(string: url) else { throw AnimeRuleCompatibilityError(reason: "Invalid URL: \(url)") }
        if !query.isEmpty {
            var items = (components.queryItems ?? []).filter { query[$0.name] == nil }
            items += query.keys.sorted().map { URLQueryItem(name: $0, value: query[$0]!.templateText) }
            components.queryItems = items
            // URLComponents leaves '+' literal; form-style servers decode it as a space.
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        guard let output = components.string else { throw AnimeRuleCompatibilityError(reason: "Invalid URL query") }
        return output
    }
    static func validateRequest(_ config: AnimeAPIRequest) throws {
        guard ["GET", "POST"].contains(config.method.uppercased()), ["none", "json", "form"].contains(config.bodyType),
              let url = URL(string: config.url), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            throw AnimeRuleCompatibilityError(reason: "Unsupported API request method, body type or URL")
        }
        if config.method.uppercased() == "POST", config.bodyType == "form", let body = config.body {
            guard case .object = body else { throw AnimeRuleCompatibilityError(reason: "Form body must be an object") }
        }
    }
    static func prepareRequest(_ config: AnimeAPIRequest, variables: [String: AnimeJSONValue], rule: AnimeRule) throws -> URLRequest {
        try validateRequest(config)
        let renderedURL = try render(config.url.trimmingCharacters(in: .whitespacesAndNewlines), variables: variables, encode: true)
        let urlString = try withQuery(renderedURL, query: renderMap(config.query, variables))
        guard let url = URL(string: urlString) else { throw AnimeRuleCompatibilityError(reason: "Invalid API URL") }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: TimeInterval(rule.timeout ?? 30))
        request.httpMethod = config.method.uppercased()
        for (key, value) in rule.headers ?? [:] { request.setValue(value, forHTTPHeaderField: key) }
        if let ua = rule.userAgent, !ua.isEmpty { request.setValue(ua, forHTTPHeaderField: "User-Agent") }
        if request.value(forHTTPHeaderField: "Referer") == nil { request.setValue(rule.referer?.isEmpty == false ? rule.referer : rule.baseURL, forHTTPHeaderField: "Referer") }
        for (key, value) in try renderMap(config.headers, variables) { request.setValue(value.templateText, forHTTPHeaderField: key) }
        if request.httpMethod == "POST", config.bodyType != "none", let value = config.body {
            let body = try renderValue(value, variables)
            if config.bodyType == "json" {
                request.httpBody = try JSONEncoder().encode(body)
                if request.value(forHTTPHeaderField: "Content-Type") == nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            } else if config.bodyType == "form", case .object(let object) = body {
                request.httpBody = object.keys.sorted().map { encoded($0) + "=" + encoded(object[$0]!.templateText) }.joined(separator: "&").data(using: .utf8)
                if request.value(forHTTPHeaderField: "Content-Type") == nil { request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type") }
            }
        }
        return request
    }
    static func validateSearch(_ config: AnimeAPISearch) throws {
        try validateRequest(config.request)
        for path in [config.listPath, config.namePath, config.sourcePath] { try AnimeJSONPath.validate(path) }
        if !config.sourceTemplate.isEmpty && !config.sourceTemplate.contains("@source") { throw AnimeRuleCompatibilityError(reason: "Source template must contain @source") }
    }
    static func validateChapter(_ config: AnimeAPIChapter) throws {
        try validateRequest(config.request)
        for path in config.variables.values { try AnimeJSONPath.validate(path) }
        if let page = config.episodePage, page.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw AnimeRuleCompatibilityError(reason: "Empty episode page template") }
        switch config.format {
        case "delimited":
            try AnimeJSONPath.validate(config.roadNamesPath)
            try AnimeJSONPath.validate(config.roadEpisodesPath)
            guard !config.roadSeparator.isEmpty, !config.episodeSeparator.isEmpty, !config.fieldSeparator.isEmpty else { throw AnimeRuleCompatibilityError(reason: "Empty chapter separator") }
        case "nested":
            for path in [config.roadsPath, config.roadNamePath, config.episodeUrlPath] where !path.isEmpty { try AnimeJSONPath.validate(path) }
            try AnimeJSONPath.validate(config.episodesPath)
            try AnimeJSONPath.validate(config.episodeNamePath)
            if config.episodeUrlPath.isEmpty && config.episodePage == nil { throw AnimeRuleCompatibilityError(reason: "Missing episode URL mapping") }
        default: throw AnimeRuleCompatibilityError(reason: "Unsupported chapter format: \(config.format)")
        }
    }
    static func validateRule(_ rule: AnimeRule) throws {
        if let issue = rule.compatibilityIssue { throw AnimeRuleCompatibilityError(reason: issue) }
        guard !rule.id.isEmpty, rule.id.range(of: "^[a-z0-9_-]+$", options: .regularExpression) != nil,
              !rule.name.isEmpty, let base = URL(string: rule.baseURL), ["http", "https"].contains(base.scheme ?? ""), base.host != nil else {
            throw AnimeRuleCompatibilityError(reason: "Invalid rule identity or base URL")
        }
        if rule.searchMode == .api, let config = rule.searchApiConfig { try validateSearch(config) }
        else if rule.searchMode == .xpath {
            guard let config = rule.xpath?.search, !config.url.isEmpty, !config.list.isEmpty, !config.title.isEmpty, !config.detail.isEmpty else { throw AnimeRuleCompatibilityError(reason: "Missing XPath search configuration") }
        }
        if rule.chapterMode == .api, let config = rule.chapterApiConfig { try validateChapter(config) }
        else if rule.chapterMode == .xpath {
            guard rule.xpath?.detail?.episodes?.isEmpty == false, rule.xpath?.list?.list.isEmpty == false else { throw AnimeRuleCompatibilityError(reason: "Missing XPath chapter configuration") }
        }
    }
    static func parseSearch(_ data: Data, config: AnimeAPISearch, rule: AnimeRule) throws -> [AnimeSearchResult] {
        try validateSearch(config)
        let document = try JSONDecoder().decode(AnimeJSONValue.self, from: data)
        return try AnimeJSONPath.read(document, config.listPath).compactMap { node in
            let name = try AnimeJSONPath.first(node, config.namePath)?.text ?? ""
            let source = try AnimeJSONPath.first(node, config.sourcePath)?.text ?? ""
            guard !name.isEmpty, !source.isEmpty else { return nil }
            let detail = config.sourceTemplate.isEmpty ? source : config.sourceTemplate.replacingOccurrences(of: "@source", with: encoded(source))
            // Raw source IDs are intentional: API chapter requests consume @source unchanged.
            return AnimeSearchResult(id: rule.id + "|" + detail, title: name, coverURL: nil, detailURL: detail,
                                     sourceId: rule.id, sourceName: rule.name, latestEpisode: nil, rating: nil)
        }
    }
    static func parseChapters(_ data: Data, config: AnimeAPIChapter, source: String, rule: AnimeRule) throws -> [AnimeDetail] {
        try validateChapter(config)
        let document = try JSONDecoder().decode(AnimeJSONValue.self, from: data)
        let sourceIdentity = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
        var variables: [String: AnimeJSONValue] = ["source": .string(source)]
        for (key, path) in config.variables {
            guard let value = try AnimeJSONPath.first(document, path), value != .null else { throw AnimeRuleCompatibilityError(reason: "Chapter variable missing: \(key)") }
            variables[key] = value
        }
        func episode(_ name: String, _ rawURL: String, _ road: Int, _ index: Int) throws -> AnimeDetail.AnimeEpisodeItem? {
            var url = rawURL
            if let page = config.episodePage {
                var vars = variables
                vars.merge(["episodeUrl": .string(rawURL), "roadIndex": .number(Double(road)), "roadNumber": .number(Double(road + 1)),
                            "episodeIndex": .number(Double(index)), "episodeNumber": .number(Double(index + 1))]) { _, new in new }
                url = try withQuery(render(page.url, variables: vars, encode: true), query: renderMap(page.query, vars))
            }
            guard !url.isEmpty, let absolute = URL(string: url, relativeTo: URL(string: rule.baseURL))?.absoluteURL,
                  ["http", "https"].contains(absolute.scheme ?? "") else { return nil }
            return AnimeDetail.AnimeEpisodeItem(id: "api:\(sourceIdentity):\(road):\(index)", name: name.isEmpty ? "第\(index + 1)集" : name,
                                               episodeNumber: index + 1, url: absolute.absoluteString, thumbnailURL: nil)
        }
        func detail(_ name: String, _ episodes: [AnimeDetail.AnimeEpisodeItem], _ index: Int) -> AnimeDetail {
            AnimeDetail(id: source + "#\(index)", title: name.isEmpty ? "播放线路\(index + 1)" : name, coverURL: nil, description: nil,
                        status: nil, rating: nil, episodes: episodes, sourceId: rule.id)
        }
        var roads: [AnimeDetail] = []
        if config.format == "delimited" {
            let names = try (AnimeJSONPath.first(document, config.roadNamesPath)?.text ?? "").components(separatedBy: config.roadSeparator)
            let value = try AnimeJSONPath.first(document, config.roadEpisodesPath)?.text ?? ""
            if value.isEmpty { return [] }
            for (roadIndex, group) in value.components(separatedBy: config.roadSeparator).enumerated() {
                var episodes: [AnimeDetail.AnimeEpisodeItem] = []
                for (index, entry) in group.components(separatedBy: config.episodeSeparator).enumerated() {
                    guard let separator = entry.range(of: config.fieldSeparator) else { continue }
                    let name = String(entry[..<separator.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                    let raw = String(entry[separator.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if let item = try episode(name, raw, roadIndex, index) { episodes.append(item) }
                }
                if !episodes.isEmpty { roads.append(detail(names.indices.contains(roadIndex) ? names[roadIndex] : "", episodes, roadIndex)) }
            }
        } else {
            let nodes = try (config.roadsPath.isEmpty ? [document] : AnimeJSONPath.read(document, config.roadsPath))
            for (roadIndex, node) in nodes.enumerated() {
                let name = try (config.roadNamePath.isEmpty ? "" : (AnimeJSONPath.first(node, config.roadNamePath)?.text ?? ""))
                var episodes: [AnimeDetail.AnimeEpisodeItem] = []
                for (index, child) in try AnimeJSONPath.read(node, config.episodesPath).enumerated() {
                    let label = try AnimeJSONPath.first(child, config.episodeNamePath)?.text ?? ""
                    let raw = try (config.episodeUrlPath.isEmpty ? "" : (AnimeJSONPath.first(child, config.episodeUrlPath)?.text ?? ""))
                    if let item = try episode(label, raw, roadIndex, index) { episodes.append(item) }
                }
                if !episodes.isEmpty { roads.append(detail(name, episodes, roadIndex)) }
            }
        }
        return roads
    }
}
