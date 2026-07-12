import Foundation
import CryptoKit

enum WebWallpaperDesignError: LocalizedError {
    case projectNotFound
    case unsupportedWallpaperType
    case missingProperties
    case invalidPropertyData

    var errorDescription: String? {
        switch self {
        case .projectNotFound:
            return "未找到当前 Web 壁纸的 project.json"
        case .unsupportedWallpaperType:
            return "当前壁纸不是可调参的 Web 壁纸"
        case .missingProperties:
            return "当前壁纸没有可编辑的属性"
        case .invalidPropertyData:
            return "属性数据解析失败"
        }
    }
}

enum WebWallpaperPropertyType: String {
    case bool
    case checkbox
    case slider
    case color
    case combo
    case textinput
    case text
    case label
    case group
    case file
    case directory
    case scenetexture
    case replacetexture
    case unknown

    static func parse(_ rawValue: String) -> WebWallpaperPropertyType {
        WebWallpaperPropertyType(rawValue: rawValue.lowercased()) ?? .unknown
    }
}

struct WebWallpaperPropertyOption: Identifiable, Equatable {
    let value: WebWallpaperPropertyValue
    let label: String

    var id: String { value.stableString + "|" + label }
}

struct WebWallpaperProperty: Identifiable, Equatable {
    let key: String
    let type: WebWallpaperPropertyType
    let label: String
    let rawLabel: String
    let fileType: String?
    let defaultValue: WebWallpaperPropertyValue?
    let minValue: Double?
    let maxValue: Double?
    let stepValue: Double?
    let order: Int
    let condition: String?
    let options: [WebWallpaperPropertyOption]
    let isFraction: Bool
    let precision: Int?

    var id: String { key }

    var isEditable: Bool {
        switch type {
        case .bool, .checkbox, .slider, .color, .combo, .textinput, .file, .directory, .scenetexture, .replacetexture:
            return true
        case .text, .label, .group, .unknown:
            return false
        }
    }
}

enum WebWallpaperPropertyValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([WebWallpaperPropertyValue])
    case object([String: WebWallpaperPropertyValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: WebWallpaperPropertyValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([WebWallpaperPropertyValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var stableString: String {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            if value.rounded() == value {
                return String(Int(value))
            }
            return String(value)
        case .bool(let value):
            return value ? "true" : "false"
        case .array(let value):
            return value.map(\.stableString).joined(separator: ",")
        case .object(let value):
            let sorted = value.keys.sorted().map { "\($0)=\(value[$0]?.stableString ?? "")" }
            return sorted.joined(separator: "&")
        case .null:
            return ""
        }
    }

    var foundationValue: Any {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            if value.rounded() == value {
                return Int(value)
            }
            return value
        case .bool(let value):
            return value
        case .array(let value):
            return value.map(\.foundationValue)
        case .object(let value):
            return value.mapValues(\.foundationValue)
        case .null:
            return NSNull()
        }
    }

    var asBool: Bool? {
        switch self {
        case .bool(let value):
            return value
        case .number(let value):
            return value != 0
        case .string(let value):
            let lowered = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["true", "1", "on", "yes"].contains(lowered) { return true }
            if ["false", "0", "off", "no"].contains(lowered) { return false }
            return nil
        default:
            return nil
        }
    }

    var asDouble: Double? {
        switch self {
        case .number(let value):
            return value
        case .bool(let value):
            return value ? 1 : 0
        case .string(let value):
            return Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    static func from(any value: Any) -> WebWallpaperPropertyValue? {
        switch value {
        case let value as WebWallpaperPropertyValue:
            return value
        case let value as String:
            return .string(value)
        case let value as NSString:
            return .string(value as String)
        case let value as Bool:
            return .bool(value)
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return .bool(value.boolValue)
            }
            return .number(value.doubleValue)
        case let value as [Any]:
            return .array(value.compactMap(Self.from(any:)))
        case let value as [String: Any]:
            var object: [String: WebWallpaperPropertyValue] = [:]
            for (key, raw) in value {
                if let converted = Self.from(any: raw) {
                    object[key] = converted
                }
            }
            return .object(object)
        case _ as NSNull:
            return .null
        default:
            return nil
        }
    }
}

struct WebWallpaperDesignDocument {
    let wallpaperPath: String
    let wallpaperTitle: String
    let properties: [WebWallpaperProperty]
    let currentValues: [String: WebWallpaperPropertyValue]
    let overrideValues: [String: WebWallpaperPropertyValue]
}

@MainActor
final class WebWallpaperDesignService {
    static let shared = WebWallpaperDesignService()

    /// 缓存 hasEditableProperties 结果，避免每次菜单刷新都读取 project.json
    private var editablePropertiesCache: [String: Bool] = [:]
    /// 缓存的时间戳，用于一定时间后自动失效
    private var cacheTimestamps: [String: Date] = [:]
    private let cacheValidityDuration: TimeInterval = 30 // 缓存 30 秒

    private init() {}

    /// 使指定壁纸的属性缓存失效（壁纸切换时调用）
    func invalidateCache(for wallpaperPath: String) {
        editablePropertiesCache.removeValue(forKey: wallpaperPath)
        cacheTimestamps.removeValue(forKey: wallpaperPath)
    }

    /// 使所有缓存失效
    func invalidateAllCaches() {
        editablePropertiesCache.removeAll()
        cacheTimestamps.removeAll()
    }

    /// 解析 project.json 路径并验证类型（单次读取 JSON）
    private func resolveProjectAndLoadJSON(for wallpaperPath: String) throws -> (projectURL: URL, json: [String: Any]) {
        try Self.resolveProjectAndLoadJSONFromDisk(for: wallpaperPath)
    }

    /// 磁盘 I/O：解析 project.json（可从后台线程调用）
    private nonisolated static func resolveProjectAndLoadJSONFromDisk(for wallpaperPath: String) throws -> (projectURL: URL, json: [String: Any]) {
        let rootURL = Self.resolveWallpaperEngineProjectRootFromDisk(startingAt: URL(fileURLWithPath: wallpaperPath))
        let projectURL = rootURL.appendingPathComponent("project.json")
        guard FileManager.default.fileExists(atPath: projectURL.path) else {
            throw WebWallpaperDesignError.projectNotFound
        }
        let projectData = try Data(contentsOf: projectURL)
        guard let json = try JSONSerialization.jsonObject(with: projectData) as? [String: Any] else {
            throw WebWallpaperDesignError.invalidPropertyData
        }
        let type = (json["type"] as? String)?.lowercased()
        if type != nil, type != "web" {
            throw WebWallpaperDesignError.unsupportedWallpaperType
        }
        return (projectURL, json)
    }

    /// 从后台线程加载完整文档（不含 @MainActor 隔离）
    nonisolated static func loadDocumentFromDisk(for wallpaperPath: String) throws -> WebWallpaperDesignDocument {
        let (projectURL, json) = try resolveProjectAndLoadJSONFromDisk(for: wallpaperPath)
        let wallpaperTitle = Self.extractTitle(from: json, fallback: projectURL)
        let properties = try Self.parseProperties(from: json)
        let defaults = Self.defaultValueMapStatic(for: properties)
        let overrides = Self.loadOverridesFromDisk(for: wallpaperPath)
        let merged = defaults.merging(overrides) { _, override in override }
        return WebWallpaperDesignDocument(
            wallpaperPath: wallpaperPath,
            wallpaperTitle: wallpaperTitle,
            properties: properties,
            currentValues: merged,
            overrideValues: overrides
        )
    }

    func loadDocument(for wallpaperPath: String) throws -> WebWallpaperDesignDocument {
        try Self.loadDocumentFromDisk(for: wallpaperPath)
    }

    func effectivePropertiesJSON(for wallpaperPath: String) throws -> String? {
        let (_, json) = try Self.resolveProjectAndLoadJSONFromDisk(for: wallpaperPath)
        let properties = try Self.parseProperties(from: json)
        let defaults = defaultValueMap(for: properties)
        let overrides = loadOverrides(for: wallpaperPath)
        let merged = defaults.merging(overrides) { _, override in override }
        return try makeEffectivePropertiesJSON(properties: properties, currentValues: merged)
    }

    func hasEditableProperties(for wallpaperPath: String) -> Bool {
        // 检查缓存
        if let cached = editablePropertiesCache[wallpaperPath],
           let timestamp = cacheTimestamps[wallpaperPath],
           Date().timeIntervalSince(timestamp) < cacheValidityDuration {
            return cached
        }
        // 未缓存或已过期，重新计算
        guard let (_, json) = try? resolveProjectAndLoadJSON(for: wallpaperPath) else {
            editablePropertiesCache[wallpaperPath] = false
            cacheTimestamps[wallpaperPath] = Date()
            return false
        }
        guard let properties = try? Self.parseProperties(from: json) else {
            editablePropertiesCache[wallpaperPath] = false
            cacheTimestamps[wallpaperPath] = Date()
            return false
        }
        let result = properties.contains(where: { $0.isEditable })
        editablePropertiesCache[wallpaperPath] = result
        cacheTimestamps[wallpaperPath] = Date()
        return result
    }

    func saveOverrides(
        for wallpaperPath: String,
        properties: [WebWallpaperProperty],
        currentValues: [String: WebWallpaperPropertyValue]
    ) throws {
        let overrides = makeOverrideValues(properties: properties, currentValues: currentValues)
        let directory = try designDirectory(for: wallpaperPath)
        let fileURL = directory.appendingPathComponent("design.json")
        if overrides.isEmpty {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }

        let data = try JSONEncoder.pretty.encode(overrides)
        try data.write(to: fileURL, options: .atomic)
    }

    func makeEffectivePropertiesJSON(
        properties: [WebWallpaperProperty],
        currentValues: [String: WebWallpaperPropertyValue]
    ) throws -> String? {
        var object: [String: Any] = [:]
        for property in properties {
            guard property.type != .text, property.type != .group else { continue }
            var descriptor: [String: Any] = [:]
            descriptor["type"] = property.type.rawValue
            descriptor["text"] = property.rawLabel
            if let order = property.order as Int? {
                descriptor["order"] = order
            }
            if let condition = property.condition, !condition.isEmpty {
                descriptor["condition"] = condition
            }
            if let minValue = property.minValue {
                descriptor["min"] = minValue
            }
            if let maxValue = property.maxValue {
                descriptor["max"] = maxValue
            }
            if let stepValue = property.stepValue {
                descriptor["step"] = stepValue
            }
            if property.isFraction {
                descriptor["fraction"] = true
            }
            if let precision = property.precision {
                descriptor["precision"] = precision
            }
            if !property.options.isEmpty {
                descriptor["options"] = property.options.map { ["label": $0.label, "value": $0.value.foundationValue] }
            }
            if let value = currentValues[property.key] ?? property.defaultValue {
                descriptor["value"] = emittedFoundationValue(for: property, value: value)
            }
            object[property.key] = descriptor
        }

        guard JSONSerialization.isValidJSONObject(object) else {
            throw WebWallpaperDesignError.invalidPropertyData
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        return String(data: data, encoding: .utf8)
    }

    func visibleProperties(
        _ properties: [WebWallpaperProperty],
        currentValues: [String: WebWallpaperPropertyValue]
    ) -> [WebWallpaperProperty] {
        let lookup = currentValues
        return properties.filter { property in
            guard let condition = property.condition, !condition.isEmpty else { return true }
            return evaluateCondition(condition, values: lookup) != false
        }
    }

    func displayLabel(for property: WebWallpaperProperty) -> String {
        let stripped = Self.stripHTML(property.rawLabel)
        return WallpaperEnginePropertyLocalizer.label(for: stripped, fallback: property.key)
    }

    private nonisolated static func defaultValueMapStatic(for properties: [WebWallpaperProperty]) -> [String: WebWallpaperPropertyValue] {
        var output: [String: WebWallpaperPropertyValue] = [:]
        for property in properties {
            if let defaultValue = property.defaultValue {
                output[property.key] = defaultValue
            }
        }
        return output
    }

    private func defaultValueMap(for properties: [WebWallpaperProperty]) -> [String: WebWallpaperPropertyValue] {
        Self.defaultValueMapStatic(for: properties)
    }

    /// 从已解析的 JSON 中提取壁纸标题，不重新读取文件
    private nonisolated static func extractTitle(from json: [String: Any], fallback projectURL: URL) -> String {
        guard let title = json["title"] as? String,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return projectURL.deletingLastPathComponent().lastPathComponent
        }
        return title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 从已解析的 JSON 中解析属性列表，不重新读取文件
    private nonisolated static func parseProperties(from json: [String: Any]) throws -> [WebWallpaperProperty] {
        guard let general = json["general"] as? [String: Any],
              let rawProperties = general["properties"] as? [String: Any],
              !rawProperties.isEmpty else {
            throw WebWallpaperDesignError.missingProperties
        }

        var properties: [WebWallpaperProperty] = []
        for (key, rawValue) in rawProperties {
            guard let rawProperty = rawValue as? [String: Any] else { continue }
            let type = WebWallpaperPropertyType.parse(rawProperty["type"] as? String ?? "")
            let property = WebWallpaperProperty(
                key: key,
                type: type,
                label: Self.stripHTML(rawProperty["text"] as? String ?? ""),
                rawLabel: rawProperty["text"] as? String ?? "",
                fileType: rawProperty["fileType"] as? String,
                defaultValue: WebWallpaperPropertyValue.from(any: rawProperty["value"] as Any),
                minValue: Self.doubleValue(rawProperty["min"]),
                maxValue: Self.doubleValue(rawProperty["max"]),
                stepValue: Self.doubleValue(rawProperty["step"]),
                order: Self.intValue(rawProperty["order"]) ?? Int.max,
                condition: rawProperty["condition"] as? String,
                options: Self.parseOptions(rawProperty["options"]),
                isFraction: (rawProperty["fraction"] as? Bool) ?? false,
                precision: Self.intValue(rawProperty["precision"])
            )
            properties.append(property)
        }

        properties.sort {
            if $0.order != $1.order { return $0.order < $1.order }
            return $0.key.localizedStandardCompare($1.key) == .orderedAscending
        }
        return properties
    }

    private nonisolated static func loadOverridesFromDisk(for wallpaperPath: String) -> [String: WebWallpaperPropertyValue] {
        guard let fileURL = try? designDirectoryOnDisk(for: wallpaperPath).appendingPathComponent("design.json"),
              FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: WebWallpaperPropertyValue].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func loadOverrides(for wallpaperPath: String) -> [String: WebWallpaperPropertyValue] {
        Self.loadOverridesFromDisk(for: wallpaperPath)
    }

    private func makeOverrideValues(
        properties: [WebWallpaperProperty],
        currentValues: [String: WebWallpaperPropertyValue]
    ) -> [String: WebWallpaperPropertyValue] {
        var overrides: [String: WebWallpaperPropertyValue] = [:]
        for property in properties {
            guard property.isEditable,
                  let defaultValue = property.defaultValue,
                  let currentValue = currentValues[property.key] else { continue }
            if !Self.valuesEqual(currentValue, defaultValue) {
                overrides[property.key] = currentValue
            }
        }
        return overrides
    }

    private func emittedFoundationValue(for property: WebWallpaperProperty, value: WebWallpaperPropertyValue) -> Any {
        switch property.type {
        case .file, .directory, .scenetexture, .replacetexture:
            if case .string(let rawPath) = value {
                return Self.normalizedWallpaperEngineFileValue(rawPath)
            }
            return value.foundationValue
        default:
            return value.foundationValue
        }
    }

    private nonisolated static func designDirectoryOnDisk(for wallpaperPath: String) throws -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let baseURL = (appSupport ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support"))
            .appendingPathComponent("WaifuX")
            .appendingPathComponent("Designs")
            .appendingPathComponent(Self.wallpaperHash(for: wallpaperPath), isDirectory: true)
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        return baseURL
    }

    private func designDirectory(for wallpaperPath: String) throws -> URL {
        try Self.designDirectoryOnDisk(for: wallpaperPath)
    }

    private nonisolated static func wallpaperHash(for wallpaperPath: String) -> String {
        let canonicalPath = URL(fileURLWithPath: wallpaperPath).standardizedFileURL.path
        let digest = SHA256.hash(data: Data(canonicalPath.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func parseOptions(_ rawValue: Any?) -> [WebWallpaperPropertyOption] {
        guard let array = rawValue as? [Any] else { return [] }
        return array.compactMap { element in
            guard let option = element as? [String: Any],
                  let label = option["label"] as? String,
                  let value = WebWallpaperPropertyValue.from(any: option["value"] as Any) else {
                return nil
            }
            return WebWallpaperPropertyOption(value: value, label: stripHTML(label))
        }
    }

    private nonisolated static func stripHTML(_ raw: String) -> String {
        var text = raw
            .replacingOccurrences(of: "<br>", with: "\n")
            .replacingOccurrences(of: "<br/>", with: "\n")
            .replacingOccurrences(of: "<br />", with: "\n")
            .replacingOccurrences(of: "</p>", with: "\n")
            .replacingOccurrences(of: "<hr>", with: "\n")
            .replacingOccurrences(of: "<hr/>", with: "\n")
            .replacingOccurrences(of: "<hr />", with: "\n")
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return text
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func doubleValue(_ rawValue: Any?) -> Double? {
        switch rawValue {
        case let value as Double:
            return value
        case let value as Int:
            return Double(value)
        case let value as NSNumber:
            return value.doubleValue
        case let value as String:
            return Double(value)
        default:
            return nil
        }
    }

    private nonisolated static func intValue(_ rawValue: Any?) -> Int? {
        switch rawValue {
        case let value as Int:
            return value
        case let value as NSNumber:
            return value.intValue
        case let value as String:
            return Int(value)
        default:
            return nil
        }
    }

    private nonisolated static func normalizedWallpaperEngineFileValue(_ rawPath: String) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.hasPrefix("/") {
            return String(trimmed.drop(while: { $0 == "/" }))
        }
        return trimmed
    }

    private nonisolated static func valuesEqual(_ lhs: WebWallpaperPropertyValue, _ rhs: WebWallpaperPropertyValue) -> Bool {
        let normalizedLeft = normalizeComparable(lhs)
        let normalizedRight = normalizeComparable(rhs)
        switch (normalizedLeft, normalizedRight) {
        case let (.string(left), .string(right)):
            return left == right
        case let (.number(left), .number(right)):
            return abs(left - right) < 0.000_001
        case let (.bool(left), .bool(right)):
            return left == right
        default:
            return lhs == rhs
        }
    }

    private nonisolated static func normalizeComparable(_ value: WebWallpaperPropertyValue) -> WebWallpaperPropertyValue {
        switch value {
        case .string(let raw):
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowered = trimmed.lowercased()
            if ["true", "on", "yes"].contains(lowered) { return .bool(true) }
            if ["false", "off", "no"].contains(lowered) { return .bool(false) }
            if let numeric = Double(trimmed) { return .number(numeric) }
            return .string(trimmed)
        default:
            return value
        }
    }

    // MARK: - Condition evaluation

    private enum ConditionTokenKind {
        case identifier
        case number
        case string
        case bool
        case `operator`
        case paren
    }

    private struct ConditionToken {
        let kind: ConditionTokenKind
        let value: String
    }

    private func evaluateCondition(
        _ expression: String,
        values: [String: WebWallpaperPropertyValue]
    ) -> Bool? {
        guard let tokens = tokenizeCondition(expression) else { return nil }
        var index = 0

        func parsePrimary() throws -> WebWallpaperPropertyValue {
            guard index < tokens.count else { throw WebWallpaperDesignError.invalidPropertyData }
            let token = tokens[index]
            if token.kind == .operator, token.value == "!" {
                index += 1
                let value = try parsePrimary()
                return .bool(!(Self.truthy(value)))
            }
            if token.kind == .paren, token.value == "(" {
                index += 1
                let value = try parseOr()
                guard index < tokens.count, tokens[index].kind == .paren, tokens[index].value == ")" else {
                    throw WebWallpaperDesignError.invalidPropertyData
                }
                index += 1
                return value
            }

            index += 1
            switch token.kind {
            case .bool:
                return .bool(token.value == "true")
            case .number:
                return .number(Double(token.value) ?? 0)
            case .string:
                return .string(token.value)
            case .identifier:
                let key = token.value.hasSuffix(".value") ? String(token.value.dropLast(6)) : token.value
                return values[key] ?? .null
            case .operator, .paren:
                throw WebWallpaperDesignError.invalidPropertyData
            }
        }

        func parseComparison() throws -> WebWallpaperPropertyValue {
            var left = try parsePrimary()
            while index < tokens.count,
                  tokens[index].kind == .operator,
                  ["==", "!=", ">", ">=", "<", "<="].contains(tokens[index].value) {
                let op = tokens[index].value
                index += 1
                let right = try parsePrimary()
                switch op {
                case "==":
                    left = .bool(Self.valuesEqual(left, right))
                case "!=":
                    left = .bool(!Self.valuesEqual(left, right))
                case ">":
                    left = .bool((left.asDouble ?? 0) > (right.asDouble ?? 0))
                case ">=":
                    left = .bool((left.asDouble ?? 0) >= (right.asDouble ?? 0))
                case "<":
                    left = .bool((left.asDouble ?? 0) < (right.asDouble ?? 0))
                case "<=":
                    left = .bool((left.asDouble ?? 0) <= (right.asDouble ?? 0))
                default:
                    break
                }
            }
            return left
        }

        func parseAnd() throws -> WebWallpaperPropertyValue {
            var left = try parseComparison()
            while index < tokens.count, tokens[index].kind == .operator, tokens[index].value == "&&" {
                index += 1
                let right = try parseComparison()
                left = .bool(Self.truthy(left) && Self.truthy(right))
            }
            return left
        }

        func parseOr() throws -> WebWallpaperPropertyValue {
            var left = try parseAnd()
            while index < tokens.count, tokens[index].kind == .operator, tokens[index].value == "||" {
                index += 1
                let right = try parseAnd()
                left = .bool(Self.truthy(left) || Self.truthy(right))
            }
            return left
        }

        do {
            let value = try parseOr()
            return Self.truthy(value)
        } catch {
            return nil
        }
    }

    private static func truthy(_ value: WebWallpaperPropertyValue) -> Bool {
        if let bool = value.asBool {
            return bool
        }
        if let number = value.asDouble {
            return number != 0
        }
        switch value {
        case .string(let value):
            return !value.isEmpty && value != "0"
        case .null:
            return false
        default:
            return true
        }
    }

    private func tokenizeCondition(_ input: String) -> [ConditionToken]? {
        var tokens: [ConditionToken] = []
        var index = input.startIndex

        func advance(_ count: Int = 1) {
            index = input.index(index, offsetBy: count)
        }

        while index < input.endIndex {
            let char = input[index]
            if char.isWhitespace {
                advance()
                continue
            }

            let remaining = String(input[index...])
            let two = String(remaining.prefix(2))
            if ["&&", "||", "==", "!=", ">=", "<="].contains(two) {
                tokens.append(.init(kind: .operator, value: two))
                advance(2)
                continue
            }

            if [">", "<", "!"].contains(String(char)) {
                tokens.append(.init(kind: .operator, value: String(char)))
                advance()
                continue
            }

            if char == "(" || char == ")" {
                tokens.append(.init(kind: .paren, value: String(char)))
                advance()
                continue
            }

            if char == "\"" || char == "'" {
                let quote = char
                advance()
                var value = ""
                while index < input.endIndex, input[index] != quote {
                    value.append(input[index])
                    advance()
                }
                guard index < input.endIndex else { return nil }
                advance()
                tokens.append(.init(kind: .string, value: value))
                continue
            }

            if char.isNumber || char == "-" {
                let match = remaining.prefix { $0.isNumber || $0 == "." || $0 == "-" }
                guard !match.isEmpty else { return nil }
                tokens.append(.init(kind: .number, value: String(match)))
                advance(match.count)
                continue
            }

            if char.isLetter || char == "_" {
                let match = remaining.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }
                let value = String(match)
                let kind: ConditionTokenKind = (value == "true" || value == "false") ? .bool : .identifier
                tokens.append(.init(kind: kind, value: value))
                advance(match.count)
                continue
            }

            return nil
        }

        return tokens
    }

    private nonisolated static func resolveWallpaperEngineProjectRootFromDisk(startingAt url: URL) -> URL {
        let fm = FileManager.default
        var current = url
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: current.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            current.deleteLastPathComponent()
        }

        for _ in 0..<8 {
            if fm.fileExists(atPath: current.appendingPathComponent("project.json").path) {
                return current
            }

            guard let entries = try? fm.contentsOfDirectory(at: current, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
                return current
            }

            let projectChildren = entries.filter { entry in
                var childDir: ObjCBool = false
                guard fm.fileExists(atPath: entry.path, isDirectory: &childDir), childDir.boolValue else { return false }
                return fm.fileExists(atPath: entry.appendingPathComponent("project.json").path)
            }

            if projectChildren.count == 1 {
                current = projectChildren[0]
                continue
            }

            return current
        }
        return current
    }

    private func resolveWallpaperEngineProjectRoot(startingAt url: URL) -> URL {
        Self.resolveWallpaperEngineProjectRootFromDisk(startingAt: url)
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
