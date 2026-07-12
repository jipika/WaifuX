import Foundation

/// Resolves the Wallpaper Engine localization tokens that are embedded in
/// `project.json` user properties.
enum WallpaperEnginePropertyLocalizer {
    private static let bundledChineseLabels = loadBundledChineseLabels()

    private static let fallbackChineseLabels: [String: String] = [
        // Wallpaper Engine Android mapping reference: browse property labels.
        "ui_browse_properties_playback_rate": "播放速度",
        "ui_browse_properties_audio_recording": "音频监听",
        "ui_browse_properties_alignment": "对齐方式",
        "ui_browse_properties_alignment_cover": "覆盖",
        "ui_browse_properties_alignment_fill": "填充",
        "ui_browse_properties_alignment_free": "自由",
        "ui_browse_properties_alignment_center": "居中",
        "ui_browse_properties_alignment_stretch": "拉伸",
        "ui_browse_properties_alignment_horizontal": "水平",
        "ui_browse_properties_alignment_vertical": "垂直",
        "ui_browse_properties_alignment_zoom": "缩放",
        "ui_browse_properties_alignment_position": "位置",
        "ui_browse_properties_alignment_flip_horizontally": "翻转",
        "ui_browse_properties_parallax": "对运动作出反应",
        "ui_browse_properties_parallax_strength": "运动强度",
        "ui_browse_properties_parallax_disabled": "已禁用",
        "ui_browse_properties_parallax_gyro": "设备运动",
        "ui_browse_properties_parallax_scroll": "主屏幕滚动",
        "ui_browse_properties_brightness": "亮度",
        "ui_browse_properties_contrast": "对比度",
        "ui_browse_properties_saturation": "饱和度",
        "ui_browse_properties_hue_shift": "色调偏移",
        "ui_browse_properties_show_color_options": "显示颜色选项",
        "ui_browse_properties_pixel_art_optimization": "像素画优化",
        "ui_browse_properties_background_color": "背景色",
        "ui_browse_properties_scheme_color": "主题配色",
        "ui_browse_properties_volume": "音量",
        "ui_browse_properties_mouse_parallax": "鼠标视差",
        "ui_browse_properties_image_filter": "图片筛选器",
        "ui_browse_properties_filter_strength": "筛选器强度",
        "ui_browse_properties_accent_color": "强调色",
        "ui_browse_properties_clouds": "云朵",
        "ui_browse_properties_sun_bottom": "太阳底部",
        "ui_browse_properties_sun_top": "太阳顶部",
        "ui_browse_properties_grid_background": "网格（背景）",
        "ui_browse_properties_grid_far": "网格（远处）",
        "ui_browse_properties_grid_near": "网格（近处）",
        "ui_browse_properties_horizon": "地平线",
        "ui_browse_properties_mountain_scale": "山脉比例",
        "ui_browse_properties_noise_fx": "噪声效果",
        "ui_browse_properties_shading": "着色",
        "ui_browse_properties_count": "计数",
        "ui_browse_properties_glow": "发光",
        "ui_browse_properties_style": "风格",
        "ui_browse_properties_large": "大",
        "ui_browse_properties_small": "小",
        "ui_browse_playlist_modal_settings_order_random": "随机",
        "ui_browse_playlist_modal_settings_order_sorted": "有序",

        // Verified against the APK's assets/locale/ui_zh-chs.json.
        "ui_close": "关闭",
        "ui_editor_preset_clock_title": "时间",
        "ui_editor_preset_snow_particles_variant_2": "平整积雪",
        "ui_editor_preset_snow_particles_variant_3": "暴风雪",
        "ui_workshop_tags_asset_type_text": "文本",
        "ui_editor_user_properties_type_textinput": "文本框",
        "ui_editor_properties_alpha": "透明度",
        "ui_editor_properties_fog": "雾",
        "ui_settings_theme": "主题:",
        "ui_workshop_tags_blur": "模糊",
        "ui_workshop_tags_music": "音乐",
    ]

    static func label(for rawLabel: String, fallback: String? = nil) -> String {
        let trimmed = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback ?? "" }
        return bundledChineseLabels[trimmed] ?? fallbackChineseLabels[trimmed] ?? fallback ?? trimmed
    }

    private static func loadBundledChineseLabels() -> [String: String] {
        guard let resourceURL = Bundle.main.resourceURL else { return [:] }
        let candidates = [
            resourceURL.appendingPathComponent("WallpaperEngineLocale.zh-Hans.json"),
            resourceURL.appendingPathComponent("Resources/WallpaperEngineLocale.zh-Hans.json"),
        ]

        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let labels = try? JSONDecoder().decode([String: String].self, from: data) else {
                continue
            }
            return labels
        }
        return [:]
    }
}

/// 属性展示方式
public enum ScenePropertyPresentation: String, Codable, Sendable {
    case control    // 可编辑控件
    case group      // 分组标题
    case decoration // 装饰性（不显示）
}

/// 单个用户属性的完整信息
public struct SceneWallpaperProperty: Codable, Equatable, Sendable {
    public let key: String
    public let type: String
    public let text: String?
    public let originalValue: AnyCodableValue
    public var currentValue: AnyCodableValue
    public let options: [String: String]?
    public let min: Double?
    public let max: Double?
    public let step: Double?
    public let order: Int?
    public let group: String?
    public let condition: String?
    public let presentation: ScenePropertyPresentation

    public var isModified: Bool {
        originalValue != currentValue
    }

    public var isEditable: Bool {
        presentation == .control
    }
}

/// 可编码的 Any 值（支持 Bool、Number、String）
public enum AnyCodableValue: Codable, Equatable, Sendable {
    case bool(Bool)
    case number(Double)
    case string(String)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? container.decode(Double.self) {
            self = .number(n)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else {
            self = .null
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let b): try container.encode(b)
        case .number(let n): try container.encode(n)
        case .string(let s): try container.encode(s)
        case .null: try container.encodeNil()
        }
    }

    public var stringValue: String {
        switch self {
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return n.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(n)) : String(n)
        case .string(let s): return s
        case .null: return ""
        }
    }

    public var jsonValue: Any {
        switch self {
        case .bool(let b): return b
        case .number(let n): return n
        case .string(let s): return s
        case .null: return NSNull()
        }
    }

    public var truthy: Bool {
        switch self {
        case .bool(let b): return b
        case .number(let n): return n != 0
        case .string(let s): return !s.isEmpty && s != "0" && s.lowercased() != "false"
        case .null: return false
        }
    }
}

/// 场景壁纸属性文档（持久化用户覆盖值）
public struct SceneWallpaperPropertiesDocument: Codable, Equatable, Sendable {
    public let wallpaperPath: String
    public var overrides: [String: AnyCodableValue]
    public let backupDate: Date

    public init(wallpaperPath: String, overrides: [String: AnyCodableValue] = [:]) {
        self.wallpaperPath = wallpaperPath
        self.overrides = overrides
        self.backupDate = Date()
    }
}

/// 场景壁纸属性管理服务
///
/// 负责：
/// 1. 从 project.json 加载壁纸的用户属性定义和原始值
/// 2. 持久化用户的属性覆盖值
/// 3. 备份原始属性用于重置
/// 4. 生成 wallpaper-wgpu 所需的属性 JSON
/// 5. 支持条件显示（condition 字段）
enum SceneWallpaperPropertiesService {
    private static let folderName = "SceneProperties"

    // MARK: - 属性加载

    /// 从 project.json 加载所有用户属性定义
    static func loadProperties(for wallpaperPath: String) -> [SceneWallpaperProperty] {
        let contentDir = resolveContentDir(for: wallpaperPath)
        let projectURL = contentDir.appendingPathComponent("project.json")
        guard let data = try? Data(contentsOf: projectURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        return parseProperties(from: json, wallpaperPath: wallpaperPath)
    }

    /// 获取用户覆盖后的属性列表（合并原始值和覆盖值）
    static func loadPropertiesWithOverrides(for wallpaperPath: String) -> [SceneWallpaperProperty] {
        let originalProps = loadProperties(for: wallpaperPath)
        let doc = loadDocument(for: wallpaperPath)
        guard !doc.overrides.isEmpty else { return originalProps }

        return originalProps.map { prop in
            var modified = prop
            if let override = doc.overrides[prop.key] {
                modified.currentValue = override
            }
            return modified
        }
    }

    /// 获取当前可见的属性（过滤掉 decoration 和条件不满足的属性）
    static func loadVisibleProperties(for wallpaperPath: String) -> [SceneWallpaperProperty] {
        let allProps = loadPropertiesWithOverrides(for: wallpaperPath)
        let valueMap = Dictionary(uniqueKeysWithValues: allProps.map { ($0.key, $0.currentValue) })
        return allProps.filter { prop in
            guard prop.presentation != .decoration else { return false }
            return evaluateCondition(prop.condition, values: valueMap)
        }
    }

    // MARK: - 属性修改

    /// 修改单个属性值
    static func setProperty(key: String, value: AnyCodableValue, for wallpaperPath: String) throws {
        var doc = loadDocument(for: wallpaperPath)
        doc.overrides[key] = value
        try saveDocument(doc, for: wallpaperPath)
    }

    /// 批量修改属性
    static func setProperties(_ changes: [String: AnyCodableValue], for wallpaperPath: String) throws {
        var doc = loadDocument(for: wallpaperPath)
        for (key, value) in changes {
            doc.overrides[key] = value
        }
        try saveDocument(doc, for: wallpaperPath)
    }

    /// 重置单个属性为原始值
    static func resetProperty(key: String, for wallpaperPath: String) throws {
        var doc = loadDocument(for: wallpaperPath)
        doc.overrides.removeValue(forKey: key)
        try saveDocument(doc, for: wallpaperPath)
    }

    /// 重置所有属性为原始值
    static func resetAllProperties(for wallpaperPath: String) throws {
        let doc = SceneWallpaperPropertiesDocument(wallpaperPath: wallpaperPath)
        try saveDocument(doc, for: wallpaperPath)
    }

    /// 检查是否有任何属性被修改
    static func hasModifiedProperties(for wallpaperPath: String) -> Bool {
        let doc = loadDocument(for: wallpaperPath)
        return !doc.overrides.isEmpty
    }

    // MARK: - 属性 JSON 生成

    /// 异步加载可见属性（后台队列执行文件 I/O）
    static func loadVisiblePropertiesAsync(for wallpaperPath: String) async -> [SceneWallpaperProperty] {
        await Task.detached(priority: .userInitiated) {
            self.loadVisibleProperties(for: wallpaperPath)
        }.value
    }

    /// 异步加载属性列表（后台队列执行文件 I/O，防止 .pkg 解压阻塞主线程）
    static func loadPropertiesAsync(for wallpaperPath: String) async -> [SceneWallpaperProperty] {
        await Task.detached(priority: .userInitiated) {
            self.loadProperties(for: wallpaperPath)
        }.value
    }

    /// 异步加载带覆盖值的属性列表（后台队列执行文件 I/O）
    static func loadPropertiesWithOverridesAsync(for wallpaperPath: String) async -> [SceneWallpaperProperty] {
        await Task.detached(priority: .userInitiated) {
            self.loadPropertiesWithOverrides(for: wallpaperPath)
        }.value
    }

    /// 生成用于 wallpaper-wgpu 的属性覆盖 JSON 字符串
    /// 格式: {"prop_key": "value", ...}
    static func propertiesOverrideJSON(for wallpaperPath: String) -> String? {
        let doc = loadDocument(for: wallpaperPath)
        guard !doc.overrides.isEmpty else { return nil }

        let dict = doc.overrides.mapValues { $0.stringValue }
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: []),
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        return str
    }

    /// 生成完整的属性参数列表（用于 wallpaper-wgpu CLI）
    /// 返回 ["--user-properties", "{json}"] 或空数组
    static func cliArguments(for wallpaperPath: String) -> [String] {
        guard let json = propertiesOverrideJSON(for: wallpaperPath) else { return [] }
        return ["--user-properties", json]
    }

    // MARK: - 持久化

    static func loadDocument(for wallpaperPath: String) -> SceneWallpaperPropertiesDocument {
        let fileURL = documentFileURL(for: wallpaperPath)
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(SceneWallpaperPropertiesDocument.self, from: data) else {
            return SceneWallpaperPropertiesDocument(wallpaperPath: wallpaperPath)
        }
        return decoded
    }

    private static func saveDocument(_ document: SceneWallpaperPropertiesDocument, for wallpaperPath: String) throws {
        let fileURL = documentFileURL(for: wallpaperPath)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        try data.write(to: fileURL, options: .atomic)
    }

    private static func documentFileURL(for wallpaperPath: String) -> URL {
        let safeName = wallpaperPath
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let baseDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("com.waifux.WaifuX", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
        return baseDir.appendingPathComponent("\(safeName).json")
    }

    // MARK: - 解析

    private static func resolveContentDir(for wallpaperPath: String) -> URL {
        let url = URL(fileURLWithPath: wallpaperPath)
        if url.pathExtension.lowercased() == "pkg" {
            if let extracted = extractPKGIfNeeded(at: url) {
                return extracted
            }
        }
        return WorkshopService.resolveWallpaperEngineProjectRoot(startingAt: url)
    }

    private static func extractPKGIfNeeded(at url: URL) -> URL? {
        let fm = FileManager.default
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wallpaperengine_props_\(url.deletingPathExtension().lastPathComponent)_\(UUID().uuidString.prefix(8))")
        try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", "-q", url.path, "-d", tempDir.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? tempDir : nil
        } catch {
            return nil
        }
    }

    private static func parseProperties(from json: [String: Any], wallpaperPath: String) -> [SceneWallpaperProperty] {
        guard let general = json["general"] as? [String: Any],
              let properties = general["properties"] as? [String: [String: Any]] else {
            return []
        }

        var result: [SceneWallpaperProperty] = []
        for (key, prop) in properties {
            let rawType = prop["type"] as? String ?? "text"
            let text = prop["text"] as? String
            let options = parseOptions(prop["options"])
            let min = prop["min"] as? Double
            let max = prop["max"] as? Double
            let step = prop["step"] as? Double
            let order = prop["order"] as? Int
            let group = prop["group"] as? String
            let condition = prop["condition"] as? String
            let presentation = determinePresentation(rawType: rawType, key: key, text: text)

            let value = parseAnyCodableValue(prop["value"])

            let normalizedType = normalizePropertyType(rawType)

            let sceneProp = SceneWallpaperProperty(
                key: key,
                type: normalizedType,
                text: text,
                originalValue: value,
                currentValue: value,
                options: options,
                min: min,
                max: max,
                step: step,
                order: order,
                group: group,
                condition: condition,
                presentation: presentation
            )
            result.append(sceneProp)
        }

        return result.sorted { ($0.order ?? Int.max) < ($1.order ?? Int.max) || ($0.order == $1.order && $0.key < $1.key) }
    }

    private static func parseOptions(_ raw: Any?) -> [String: String]? {
        guard let raw else { return nil }
        // 格式1: {"key": "label", ...}
        if let dict = raw as? [String: String] {
            return dict
        }
        // 格式2: [{"value": "v", "label": "l"}, ...]
        if let array = raw as? [[String: Any]] {
            var result: [String: String] = [:]
            for item in array {
                if let value = item["value"], let label = item["label"] as? String {
                    result[String(describing: value)] = label
                }
            }
            return result.isEmpty ? nil : result
        }
        return nil
    }

    private static func determinePresentation(rawType: String, key: String, text: String?) -> ScenePropertyPresentation {
        let lower = rawType.lowercased()
        if lower == "group" || lower == "description" {
            return .group
        }
        // 装饰性属性检测
        let keyLower = key.lowercased()
        let textLower = (text ?? "").lowercased()
        if keyLower.hasPrefix("imgsrc") || keyLower.hasPrefix("brimgsrc")
            || keyLower.contains("imgsrchttp") || keyLower.contains("hrefhttps")
            || textLower.contains("<img") || textLower.contains("<a ")
            || textLower.contains("<hr") || textLower.contains("rf=viewer")
            || (key.count > 96 && !key.contains("_")) {
            return .decoration
        }
        return .control
    }

    private static func normalizePropertyType(_ raw: String) -> String {
        switch raw.lowercased() {
        case "bool", "toggle", "checkbox": return "bool"
        case "slider", "float", "percentage": return "slider"
        case "color", "schemecolor": return "color"
        case "combo", "dropdown", "select": return "combo"
        case "textinput", "string": return "textinput"
        case "text", "label": return "label"
        case "integer", "int": return "slider"
        case "file", "directory", "scenetexture", "replacetexture": return "file"
        case "group": return "group"
        case "description": return "description"
        default: return raw.lowercased()
        }
    }

    // MARK: - 条件求值

    /// 求值条件表达式，返回属性是否应该显示
    static func evaluateCondition(_ expression: String?, values: [String: AnyCodableValue]) -> Bool {
        guard let expr = expression, !expr.trimmingCharacters(in: .whitespaces).isEmpty else {
            return true
        }
        return evaluateExpression(expr, values: values) != false
    }

    private static func evaluateExpression(_ expr: String, values: [String: AnyCodableValue]) -> Bool? {
        let tokens = tokenize(expr)
        guard !tokens.isEmpty else { return nil }
        var index = 0
        let result = parseOr(tokens: tokens, index: &index, values: values)
        return result.map { truthy($0) }
    }

    private enum ConditionToken {
        case identifier(String)
        case number(Double)
        case string(String)
        case bool(Bool)
        case op(String)
        case paren(Character)
    }

    private static func tokenize(_ input: String) -> [ConditionToken] {
        var tokens: [ConditionToken] = []
        var i = input.startIndex
        while i < input.endIndex {
            let ch = input[i]
            if ch.isWhitespace {
                i = input.index(after: i)
                continue
            }
            // 双字符运算符
            let end = input.index(i, offsetBy: 2, limitedBy: input.endIndex) ?? input.endIndex
            let two = String(input[i..<end])
            if ["&&", "||", "==", "!=", ">=", "<="].contains(two) {
                tokens.append(.op(two))
                i = input.index(i, offsetBy: 2)
                continue
            }
            if "><!".contains(ch) {
                tokens.append(.op(String(ch)))
                i = input.index(after: i)
                continue
            }
            if ch == "(" || ch == ")" {
                tokens.append(.paren(ch))
                i = input.index(after: i)
                continue
            }
            if ch == "'" || ch == "\"" {
                var j = input.index(after: i)
                var s = ""
                while j < input.endIndex && input[j] != ch {
                    s.append(input[j])
                    j = input.index(after: j)
                }
                if j < input.endIndex { j = input.index(after: j) }
                tokens.append(.string(s))
                i = j
                continue
            }
            if ch.isNumber || (ch == "-" && input.index(after: i) < input.endIndex && input[input.index(after: i)].isNumber) {
                var j = i
                if ch == "-" { j = input.index(after: j) }
                while j < input.endIndex && (input[j].isNumber || input[j] == ".") {
                    j = input.index(after: j)
                }
                if let n = Double(input[i..<j]) {
                    tokens.append(.number(n))
                }
                i = j
                continue
            }
            if ch.isLetter || ch == "_" {
                var j = i
                while j < input.endIndex && (input[j].isLetter || input[j].isNumber || input[j] == "_" || input[j] == ".") {
                    j = input.index(after: j)
                }
                let word = String(input[i..<j])
                if word == "true" { tokens.append(.bool(true)) }
                else if word == "false" { tokens.append(.bool(false)) }
                else { tokens.append(.identifier(word)) }
                i = j
                continue
            }
            i = input.index(after: i)
        }
        return tokens
    }

    private static func parsePrimary(tokens: [ConditionToken], index: inout Int, values: [String: AnyCodableValue]) -> AnyCodableValue? {
        guard index < tokens.count else { return nil }
        let token = tokens[index]
        switch token {
        case .op("!"):
            index += 1
            guard let val = parsePrimary(tokens: tokens, index: &index, values: values) else { return nil }
            return .bool(!val.truthy)
        case .paren("("):
            index += 1
            let val = parseOr(tokens: tokens, index: &index, values: values)
            if index < tokens.count, case .paren(")") = tokens[index] { index += 1 }
            return val
        case .bool(let b):
            index += 1
            return .bool(b)
        case .number(let n):
            index += 1
            return .number(n)
        case .string(let s):
            index += 1
            return .string(s)
        case .identifier(let id):
            index += 1
            let key = id.hasSuffix(".value") ? String(id.dropLast(6)) : id
            return values[key]
        default:
            return nil
        }
    }

    private static func parseComparison(tokens: [ConditionToken], index: inout Int, values: [String: AnyCodableValue]) -> AnyCodableValue? {
        guard var left = parsePrimary(tokens: tokens, index: &index, values: values) else { return nil }
        while index < tokens.count {
            guard case .op(let op) = tokens[index], ["==", "!=", ">", ">=", "<", "<="].contains(op) else { break }
            index += 1
            guard let right = parsePrimary(tokens: tokens, index: &index, values: values) else { break }
            switch op {
            case "==": left = .bool(valuesEqual(left, right))
            case "!=": left = .bool(!valuesEqual(left, right))
            case ">":  left = .bool(compareNumeric(left, right, op: >))
            case ">=": left = .bool(compareNumeric(left, right, op: >=))
            case "<":  left = .bool(compareNumeric(left, right, op: <))
            case "<=": left = .bool(compareNumeric(left, right, op: <=))
            default: break
            }
        }
        return left
    }

    private static func parseAnd(tokens: [ConditionToken], index: inout Int, values: [String: AnyCodableValue]) -> AnyCodableValue? {
        guard var left = parseComparison(tokens: tokens, index: &index, values: values) else { return nil }
        while index < tokens.count, case .op("&&") = tokens[index] {
            index += 1
            guard let right = parseComparison(tokens: tokens, index: &index, values: values) else { break }
            left = .bool(left.truthy && right.truthy)
        }
        return left
    }

    private static func parseOr(tokens: [ConditionToken], index: inout Int, values: [String: AnyCodableValue]) -> AnyCodableValue? {
        guard var left = parseAnd(tokens: tokens, index: &index, values: values) else { return nil }
        while index < tokens.count, case .op("||") = tokens[index] {
            index += 1
            guard let right = parseAnd(tokens: tokens, index: &index, values: values) else { break }
            left = .bool(left.truthy || right.truthy)
        }
        return left
    }

    private static func valuesEqual(_ lhs: AnyCodableValue, _ rhs: AnyCodableValue) -> Bool {
        switch (lhs, rhs) {
        case (.bool(let a), .bool(let b)): return a == b
        case (.number(let a), .number(let b)): return a == b
        case (.string(let a), .string(let b)): return a == b
        case (.bool(let a), .number(let b)): return (a ? 1.0 : 0.0) == b
        case (.number(let a), .bool(let b)): return a == (b ? 1.0 : 0.0)
        case (.string(let a), .bool(let b)): return (a == "true") == b
        case (.bool(let a), .string(let b)): return a == (b == "true")
        default: return false
        }
    }

    private static func compareNumeric(_ lhs: AnyCodableValue, _ rhs: AnyCodableValue, op: (Double, Double) -> Bool) -> Bool {
        let l: Double
        let r: Double
        switch lhs {
        case .number(let n): l = n
        case .bool(let b): l = b ? 1 : 0
        case .string(let s): l = Double(s) ?? 0
        case .null: l = 0
        }
        switch rhs {
        case .number(let n): r = n
        case .bool(let b): r = b ? 1 : 0
        case .string(let s): r = Double(s) ?? 0
        case .null: r = 0
        }
        return op(l, r)
    }

    private static func truthy(_ value: AnyCodableValue) -> Bool {
        value.truthy
    }

    private static func parseAnyCodableValue(_ any: Any?) -> AnyCodableValue {
        guard let any else { return .null }
        if let b = any as? Bool {
            return .bool(b)
        } else if let n = any as? NSNumber {
            if type(of: any) == type(of: NSNumber(value: true)) {
                return .bool(n.boolValue)
            }
            return .number(n.doubleValue)
        } else if let s = any as? String {
            return .string(s)
        }
        return .null
    }
}
