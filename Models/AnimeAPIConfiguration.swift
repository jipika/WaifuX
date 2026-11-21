import Foundation

/// Kazumi's API number is a capability level; these modes select the execution engine.
enum AnimeRuleMode: String, Codable, Sendable { case css, xpath, api }

indirect enum AnimeJSONValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: AnimeJSONValue]), array([AnimeJSONValue]), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([String: AnimeJSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([AnimeJSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        }
    }
    var templateText: String {
        if case .string(let value) = self { return value }
        return text
    }
    var text: String {
        switch self {
        case .null: return ""
        case .string(let v): return v.trimmingCharacters(in: .whitespacesAndNewlines)
        case .bool(let v): return v ? "true" : "false"
        case .number(let v): return v.rounded() == v && abs(v) < 9e15 ? String(Int64(v)) : String(v)
        default: return String(data: (try? JSONEncoder().encode(self)) ?? Data(), encoding: .utf8) ?? ""
        }
    }
}

struct AnimeAPIRequest: Codable, Sendable {
    var method = "GET"
    var url = ""
    var headers: [String: AnimeJSONValue] = [:]
    var query: [String: AnimeJSONValue] = [:]
    var bodyType = "none"
    var body: AnimeJSONValue?
    enum CodingKeys: String, CodingKey { case method, url, headers, query, bodyType, body }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        method = try c.decodeIfPresent(String.self, forKey: .method)?.uppercased() ?? "GET"
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        headers = try c.decodeIfPresent([String: AnimeJSONValue].self, forKey: .headers) ?? [:]
        query = try c.decodeIfPresent([String: AnimeJSONValue].self, forKey: .query) ?? [:]
        bodyType = try c.decodeIfPresent(String.self, forKey: .bodyType) ?? "none"
        body = try c.decodeIfPresent(AnimeJSONValue.self, forKey: .body)
    }
    init() {}
}

struct AnimeAPISearch: Codable, Sendable {
    var request = AnimeAPIRequest()
    var listPath = "$.data[*]"
    var namePath = "$.name"
    var sourcePath = "$.url"
    var sourceTemplate = ""
    enum CodingKeys: String, CodingKey { case request, listPath, namePath, sourcePath, sourceTemplate }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        request = try c.decodeIfPresent(AnimeAPIRequest.self, forKey: .request) ?? AnimeAPIRequest()
        listPath = try c.decodeIfPresent(String.self, forKey: .listPath) ?? listPath
        namePath = try c.decodeIfPresent(String.self, forKey: .namePath) ?? namePath
        sourcePath = try c.decodeIfPresent(String.self, forKey: .sourcePath) ?? sourcePath
        sourceTemplate = try c.decodeIfPresent(String.self, forKey: .sourceTemplate) ?? ""
    }
}

struct AnimeAPIEpisodePage: Codable, Sendable {
    let url: String
    let query: [String: AnimeJSONValue]
    enum CodingKeys: String, CodingKey { case url, query }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        query = try c.decodeIfPresent([String: AnimeJSONValue].self, forKey: .query) ?? [:]
    }
}

struct AnimeAPIChapter: Codable, Sendable {
    var request = AnimeAPIRequest()
    var format = "nested"
    var roadsPath = "$.data.roads[*]"
    var roadNamePath = "$.name"
    var episodesPath = "$.episodes[*]"
    var episodeNamePath = "$.name"
    var episodeUrlPath = "$.url"
    var roadNamesPath = ""
    var roadEpisodesPath = ""
    var roadSeparator = "$$$"
    var episodeSeparator = "#"
    var fieldSeparator = "$"
    var variables: [String: String] = [:]
    var episodePage: AnimeAPIEpisodePage?
    enum CodingKeys: String, CodingKey {
        case request, format, roadsPath, roadNamePath, episodesPath, episodeNamePath, episodeUrlPath
        case roadNamesPath, roadEpisodesPath, roadSeparator, episodeSeparator, fieldSeparator, variables, episodePage
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        request = try c.decodeIfPresent(AnimeAPIRequest.self, forKey: .request) ?? AnimeAPIRequest()
        format = try c.decodeIfPresent(String.self, forKey: .format) ?? format
        roadsPath = try c.decodeIfPresent(String.self, forKey: .roadsPath) ?? roadsPath
        roadNamePath = try c.decodeIfPresent(String.self, forKey: .roadNamePath) ?? roadNamePath
        episodesPath = try c.decodeIfPresent(String.self, forKey: .episodesPath) ?? episodesPath
        episodeNamePath = try c.decodeIfPresent(String.self, forKey: .episodeNamePath) ?? episodeNamePath
        episodeUrlPath = try c.decodeIfPresent(String.self, forKey: .episodeUrlPath) ?? episodeUrlPath
        roadNamesPath = try c.decodeIfPresent(String.self, forKey: .roadNamesPath) ?? roadNamesPath
        roadEpisodesPath = try c.decodeIfPresent(String.self, forKey: .roadEpisodesPath) ?? roadEpisodesPath
        roadSeparator = try c.decodeIfPresent(String.self, forKey: .roadSeparator) ?? roadSeparator
        episodeSeparator = try c.decodeIfPresent(String.self, forKey: .episodeSeparator) ?? episodeSeparator
        fieldSeparator = try c.decodeIfPresent(String.self, forKey: .fieldSeparator) ?? fieldSeparator
        variables = try c.decodeIfPresent([String: String].self, forKey: .variables) ?? [:]
        episodePage = try c.decodeIfPresent(AnimeAPIEpisodePage.self, forKey: .episodePage)
    }
}

struct AnimeRuleCompatibilityError: LocalizedError {
    let reason: String
    var errorDescription: String? { reason }
}
