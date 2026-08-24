import Foundation
import CoreGraphics

/// 场景配置覆盖键定义（对应 wallpaper-wgpu 的 __-prefixed 系统键）
public enum SceneConfigOverrideKey: String, CaseIterable, Sendable {
    // ── Camera ──
    case cameraZoom = "__camera_zoom"
    case cameraFov = "__camera_fov"
    case cameraNearz = "__camera_nearz"
    case cameraFarz = "__camera_farz"

    // ── Parallax ──
    case parallaxEnabled = "__parallax_enabled"
    case parallaxAmount = "__parallax_amount"
    case parallaxDelay = "__parallax_delay"
    case parallaxMouseInfluence = "__parallax_mouse_influence"

    // ── Display ──
    case orthoWidth = "__ortho_width"
    case orthoHeight = "__ortho_height"
    case textureReduction = "__texture_reduction"

    // ── Misc ──
    case clearEnabled = "__clear_enabled"
    case clearColor = "__clear_color"
    case cameraFade = "__camera_fade"

    // ── Lighting ──
    case ambientColor = "__ambient_color"
    case skylightColor = "__skylight_color"

    public var displayName: String {
        switch self {
        case .cameraZoom: return "缩放"
        case .cameraFov: return "视场角 (FOV)"
        case .cameraNearz: return "近裁剪面"
        case .cameraFarz: return "远裁剪面"
        case .parallaxEnabled: return "视差效果"
        case .parallaxAmount: return "视差强度"
        case .parallaxDelay: return "视差延迟"
        case .parallaxMouseInfluence: return "鼠标影响"
        case .orthoWidth: return "画布宽度"
        case .orthoHeight: return "画布高度"
        case .textureReduction: return "纹理质量缩减"
        case .clearEnabled: return "背景清除"
        case .clearColor: return "背景颜色"
        case .cameraFade: return "淡入效果"
        case .ambientColor: return "环境光颜色"
        case .skylightColor: return "天光颜色"
        }
    }

    public var displayNameEN: String {
        switch self {
        case .cameraZoom: return "Camera Zoom"
        case .cameraFov: return "FOV"
        case .cameraNearz: return "Near Z"
        case .cameraFarz: return "Far Z"
        case .parallaxEnabled: return "Parallax"
        case .parallaxAmount: return "Parallax Amount"
        case .parallaxDelay: return "Parallax Delay"
        case .parallaxMouseInfluence: return "Mouse Influence"
        case .orthoWidth: return "Canvas Width"
        case .orthoHeight: return "Canvas Height"
        case .textureReduction: return "Texture Reduction"
        case .clearEnabled: return "Clear Enabled"
        case .clearColor: return "Clear Color"
        case .cameraFade: return "Camera Fade"
        case .ambientColor: return "Ambient Color"
        case .skylightColor: return "Skylight Color"
        }
    }

    /// 是否为颜色类型（RGB 字符串）
    public var isColor: Bool {
        switch self {
        case .clearColor, .ambientColor, .skylightColor: return true
        default: return false
        }
    }

    /// 是否为布尔类型
    public var isBool: Bool {
        switch self {
        case .parallaxEnabled, .clearEnabled, .cameraFade: return true
        default: return false
        }
    }

    /// 默认值
    public var defaultValue: Double {
        switch self {
        case .cameraZoom: return 1.0
        case .cameraFov: return 50.0
        case .cameraNearz: return 0.01
        case .cameraFarz: return 10000.0
        case .parallaxAmount: return 0.5
        case .parallaxDelay: return 0.1
        case .parallaxMouseInfluence: return 0.07
        case .orthoWidth: return 1920.0
        case .orthoHeight: return 1080.0
        case .textureReduction: return 1.0
        default: return 0
        }
    }

    /// 滑块的取值范围
    public var sliderRange: ClosedRange<Double> {
        switch self {
        case .cameraZoom: return 0.1...5.0
        case .cameraFov: return 10.0...120.0
        case .cameraNearz: return 0.001...10.0
        case .cameraFarz: return 100.0...100000.0
        case .parallaxAmount: return 0.0...2.0
        case .parallaxDelay: return 0.0...1.0
        case .parallaxMouseInfluence: return 0.0...1.0
        case .orthoWidth: return 100.0...7680.0
        case .orthoHeight: return 100.0...4320.0
        case .textureReduction: return 1.0...8.0
        default: return 0...1
        }
    }
}

/// 场景壁纸 Scene Config 覆盖管理服务
///
/// 管理 wallpaper-wgpu 的 scene.json 内部参数覆盖。
/// 这些参数通过 `--user-properties` 的 `__` 前缀键传递，
/// 在 wallpaper-wgpu 端被 `apply_scene_config_overrides()` 解析并覆盖 SceneDescription 字段。
@MainActor
enum SceneConfigOverrideService {
    private static let defaultsKeyPrefix = "scene_config_overrides_v1_"

    // MARK: - 覆盖值加载/保存

    /// 加载指定壁纸的场景配置覆盖
    static func loadOverrides(for wallpaperPath: String) -> [SceneConfigOverrideKey: AnyCodableValue] {
        guard let data = UserDefaults.standard.data(forKey: storageKey(for: wallpaperPath)),
              let dict = try? JSONDecoder().decode([String: AnyCodableValue].self, from: data) else {
            return [:]
        }
        var result: [SceneConfigOverrideKey: AnyCodableValue] = [:]
        for (keyStr, value) in dict {
            if let key = SceneConfigOverrideKey(rawValue: keyStr) {
                result[key] = value
            }
        }
        return result
    }

    /// 保存指定壁纸的场景配置覆盖
    static func saveOverrides(_ overrides: [SceneConfigOverrideKey: AnyCodableValue], for wallpaperPath: String) {
        let dict = Dictionary(uniqueKeysWithValues: overrides.map { ($0.rawValue, $1) })
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: storageKey(for: wallpaperPath))
        }
    }

    /// 设置单个覆盖值
    static func setOverride(key: SceneConfigOverrideKey, value: AnyCodableValue, for wallpaperPath: String) {
        var overrides = loadOverrides(for: wallpaperPath)
        overrides[key] = value
        saveOverrides(overrides, for: wallpaperPath)
    }

    /// 重置单个覆盖
    static func resetOverride(key: SceneConfigOverrideKey, for wallpaperPath: String) {
        var overrides = loadOverrides(for: wallpaperPath)
        overrides.removeValue(forKey: key)
        saveOverrides(overrides, for: wallpaperPath)
    }

    /// 重置所有覆盖
    static func resetAllOverrides(for wallpaperPath: String) {
        UserDefaults.standard.removeObject(forKey: storageKey(for: wallpaperPath))
    }

    /// 是否有任何覆盖
    static func hasOverrides(for wallpaperPath: String) -> Bool {
        !loadOverrides(for: wallpaperPath).isEmpty
    }

    // MARK: - JSON 生成

    /// 生成用于 wallpaper-wgpu 的场景配置覆盖 JSON
    /// 格式: {"__camera_zoom": 1.5, "__parallax_enabled": "true", ...}
    static func propertiesOverrideJSON(for wallpaperPath: String) -> String? {
        let overrides = loadOverrides(for: wallpaperPath)
        guard !overrides.isEmpty else { return nil }

        let dict = overrides.mapValues { value -> Any in
            switch value {
            case .bool(let b): return b
            case .number(let n): return n
            case .string(let s): return s
            case .null: return NSNull()
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: []),
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        return str
    }

    // MARK: - 合并到现有 user-properties JSON

    /// 将场景配置覆盖合并到现有的 user-properties JSON 中
    static func mergedPropertiesJSON(userPropertiesJSON: String?, for wallpaperPath: String) -> String? {
        let sceneOverrides = loadOverrides(for: wallpaperPath)
        guard !sceneOverrides.isEmpty else { return userPropertiesJSON }

        // 解析现有 JSON
        var merged: [String: Any] = [:]
        if let existingJSON = userPropertiesJSON,
           let existingData = existingJSON.data(using: .utf8),
           let existingDict = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any] {
            merged = existingDict
        }

        // 合并场景配置覆盖
        for (key, value) in sceneOverrides {
            switch value {
            case .bool(let b): merged[key.rawValue] = b
            case .number(let n): merged[key.rawValue] = n
            case .string(let s): merged[key.rawValue] = s
            case .null: merged[key.rawValue] = NSNull()
            }
        }

        guard let data = try? JSONSerialization.data(withJSONObject: merged, options: []),
              let str = String(data: data, encoding: .utf8) else {
            return userPropertiesJSON
        }
        return str
    }

    // MARK: - 辅助方法

    private static func storageKey(for wallpaperPath: String) -> String {
        let safeName = wallpaperPath
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return defaultsKeyPrefix + safeName
    }

    // MARK: - 从 scene.json 读取真实默认值

    /// 从壁纸的 scene.pkg 解析 scene.json 的 `general` 段，读取每个配置项的真实默认值。
    ///
    /// 此前面板回显用写死值（如 `__parallax_enabled` 恒为 false），与 scene.json 中
    /// `general.cameraparallax` 的实际值不符，导致首次打开面板时回显错误。
    /// 读不到时回退到 `SceneConfigOverrideKey.defaultValue` / isBool 写死值。
    static func loadSceneDefaults(for wallpaperPath: String) -> [SceneConfigOverrideKey: AnyCodableValue] {
        guard let general = loadSceneGeneralDict(for: wallpaperPath) else {
            return [:]
        }

        var result: [SceneConfigOverrideKey: AnyCodableValue] = [:]
        for key in SceneConfigOverrideKey.allCases {
            if let value = sceneDefaultValue(for: key, from: general) {
                result[key] = value
            }
        }
        return result
    }

    /// Scene 画布像素（`orthogonalprojection`，含用户覆盖的宽高）。
    /// 给铺满裁切在 wgpu 写出 canvas-size 之前用，才能按真实比例居中 cover。
    static func sceneOrthogonalSize(for wallpaperPath: String) -> CGSize? {
        let overrides = loadOverrides(for: wallpaperPath)
        var width: Double?
        var height: Double?
        if case .number(let value) = overrides[.orthoWidth] { width = value }
        if case .number(let value) = overrides[.orthoHeight] { height = value }
        if width == nil || height == nil, let general = loadSceneGeneralDict(for: wallpaperPath),
           let ortho = general["orthogonalprojection"] as? [String: Any] {
            if width == nil { width = numericValue(ortho["width"]) }
            if height == nil { height = numericValue(ortho["height"]) }
        }
        guard let width, let height, width > 1, height > 1 else { return nil }
        return CGSize(width: width, height: height)
    }

    private static func numericValue(_ value: Any?) -> Double? {
        if let number = value as? Double { return number }
        if let number = value as? Int { return Double(number) }
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    /// 定位壁纸目录下的 scene.pkg 并解析其中 scene.json 的 `general` 段。
    private static func loadSceneGeneralDict(for wallpaperPath: String) -> [String: Any]? {
        let rootURL = resolveSceneRoot(for: wallpaperPath)
        guard let sceneJSONData = extractSceneJSONData(rootURL: rootURL) else {
            return nil
        }
        guard let obj = try? JSONSerialization.jsonObject(with: sceneJSONData) as? [String: Any],
              let general = obj["general"] as? [String: Any] else {
            return nil
        }
        return general
    }

    /// 解析壁纸路径到包含 scene.pkg 的项目根目录。
    private static func resolveSceneRoot(for wallpaperPath: String) -> URL {
        let url = URL(fileURLWithPath: wallpaperPath)
        if url.pathExtension.lowercased() == "pkg" {
            // wallpaperPath 本身就是 .pkg
            return url.deletingLastPathComponent()
        }
        // 复用 WorkshopService 的项目根定位逻辑（处理多层嵌套目录）
        return WorkshopService.resolveWallpaperEngineProjectRoot(startingAt: url)
    }

    /// 从项目根目录提取 scene.json 的原始 JSON Data。
    /// PKG 是 WE 自定义二进制归档格式：[u32 skinLen][skin][u32 nfiles][entries...][blob]。
    private static func extractSceneJSONData(rootURL: URL) -> Data? {
        let fm = FileManager.default

        // 1. 优先读 project.json 的 "file" 字段确定场景文件名（如 gifscene.pkg）
        let projectURL = rootURL.appendingPathComponent("project.json")
        var preferredSceneFileName: String? = nil
        if let data = try? Data(contentsOf: projectURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let file = json["file"] as? String {
            preferredSceneFileName = file
        }

        // 候选 .pkg 文件：scene.pkg > project.json 指定的 > 目录下任意 .pkg
        let scenePkg = rootURL.appendingPathComponent("scene.pkg")
        let candidatePKGs: [URL] = {
            if fm.fileExists(atPath: scenePkg.path) {
                return [scenePkg]
            }
            if let preferred = preferredSceneFileName,
               !preferred.isEmpty {
                let preferredURL = rootURL.appendingPathComponent(preferred)
                if fm.fileExists(atPath: preferredURL.path) {
                    return [preferredURL]
                }
            }
            // 任意 .pkg
            if let entries = try? fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil) {
                if let anyPkg = entries.first(where: { $0.pathExtension.lowercased() == "pkg" }) {
                    return [anyPkg]
                }
            }
            return []
        }()

        guard let pkgURL = candidatePKGs.first,
              let data = try? Data(contentsOf: pkgURL) else {
            return nil
        }
        return extractSceneJSONFromPKGData(data, fallbackName: pkgURL.deletingPathExtension().lastPathComponent + ".json")
    }

    /// 从 PKG 二进制 Data 中提取 scene.json 内容。
    private static func extractSceneJSONFromPKGData(_ data: Data, fallbackName: String) -> Data? {
        var o = 0
        // [u32 skinLen][skin bytes][u32 nfiles][entries...][blob]
        guard o + 4 <= data.count else { return nil }
        let skinLen = Int(readU32LE(data, o)); o += 4
        guard o + skinLen <= data.count else { return nil }
        o += skinLen
        guard o + 4 <= data.count else { return nil }
        let nfiles = Int(readU32LE(data, o)); o += 4

        var entries: [(name: String, offset: Int, length: Int)] = []
        for _ in 0..<nfiles {
            guard o + 4 <= data.count else { return nil }
            let entrySize = Int(readU32LE(data, o)); o += 4
            guard o + entrySize <= data.count else { return nil }
            let nameData = data.subdata(in: o..<o + entrySize)
            o += entrySize
            let name = String(data: nameData, encoding: .utf8) ?? ""
            guard o + 8 <= data.count else { return nil }
            let fileOff = Int(readU32LE(data, o)); o += 4
            let fileLen = Int(readU32LE(data, o)); o += 4
            entries.append((name, fileOff, fileLen))
        }
        let base = o

        let candidates = ["scene.json", fallbackName].compactMap { $0?.lowercased() }
        func entryMatches(_ entryName: String, candidate: String) -> Bool {
            let normalized = entryName.lowercased()
            return normalized == candidate || normalized.hasSuffix("/" + candidate)
        }
        for candidate in candidates {
            if let entry = entries.first(where: { entryMatches($0.name, candidate: candidate) }) {
                let start = base + entry.offset
                let end = start + entry.length
                guard end <= data.count else { return nil }
                return data.subdata(in: start..<end)
            }
        }
        // 兼容：包根下任意 .json（排除 materials/models 等子目录）
        if let entry = entries.first(where: {
            let n = $0.name.lowercased()
            return n.hasSuffix(".json")
                && !n.contains("/materials/") && !n.contains("/models/")
                && !n.contains("/effects/") && !n.contains("/particles/")
                && !n.contains("/shaders/") && !n.contains("/fonts/")
        }) {
            let start = base + entry.offset
            let end = start + entry.length
            guard end <= data.count else { return nil }
            return data.subdata(in: start..<end)
        }
        return nil
    }

    private static func readU32LE(_ data: Data, _ o: Int) -> UInt32 {
        guard o + 4 <= data.count else { return 0 }
        return UInt32(data[o])
            | (UInt32(data[o + 1]) << 8)
            | (UInt32(data[o + 2]) << 16)
            | (UInt32(data[o + 3]) << 24)
    }

    /// 把 scene.json `general` 段的字段映射到 `SceneConfigOverrideKey` 的真实默认值。
    /// 字段名与 wallpaper-wgpu `config/scene_json.rs` 的 `SceneJsonGeneral` 对齐。
    private static func sceneDefaultValue(for key: SceneConfigOverrideKey, from general: [String: Any]) -> AnyCodableValue? {
        switch key {
        // ── Bool（scene.json 里是 true/false，也可能是 "0"/"1" 字符串或 user-bound）──
        case .parallaxEnabled:
            return boolValue(from: general, key: "cameraparallax", fallback: false)
        case .clearEnabled:
            return boolValue(from: general, key: "clearenabled", fallback: true)
        case .cameraFade:
            return boolValue(from: general, key: "camerafade", fallback: true)

        // ── 颜色 "r g b" 字符串 ──
        case .clearColor:
            return stringValue(from: general, key: "clearcolor")
        case .ambientColor:
            return stringValue(from: general, key: "ambientcolor")
        case .skylightColor:
            return stringValue(from: general, key: "skylightcolor")

        // ── 数值 ──
        case .cameraZoom:
            return numberValue(from: general, key: "zoom", fallback: 1.0)
        case .cameraFov:
            return numberValue(from: general, key: "fov", fallback: 50.0)
        case .cameraNearz:
            return numberValue(from: general, key: "nearz", fallback: 0.01)
        case .cameraFarz:
            return numberValue(from: general, key: "farz", fallback: 10000.0)
        case .parallaxAmount:
            return numberValue(from: general, key: "cameraparallaxamount", fallback: 0.5)
        case .parallaxDelay:
            return numberValue(from: general, key: "cameraparallaxdelay", fallback: 0.1)
        case .parallaxMouseInfluence:
            return numberValue(from: general, key: "cameraparallaxmouseinfluence", fallback: 0.5)
        case .textureReduction:
            // texturereduction 在 scene.json 里是 u32（不是 user-bound）
            if let n = general["texturereduction"] as? Int { return .number(Double(n)) }
            if let n = general["texturereduction"] as? Double { return .number(n) }
            return .number(1.0)
        case .orthoWidth:
            if let ortho = general["orthogonalprojection"] as? [String: Any] {
                return numberValue(from: ortho, key: "width", fallback: 1920.0)
            }
            return .number(1920.0)
        case .orthoHeight:
            if let ortho = general["orthogonalprojection"] as? [String: Any] {
                return numberValue(from: ortho, key: "height", fallback: 1080.0)
            }
            return .number(1080.0)
        }
    }

    /// 从 dict 读 bool 字段，兼容 Bool / Int(0,1) / "true","false" / "0","1" 字符串。
    private static func boolValue(from dict: [String: Any], key: String, fallback: Bool) -> AnyCodableValue {
        let b: Bool
        if let v = dict[key] as? Bool {
            b = v
        } else if let n = dict[key] as? Int {
            b = n != 0
        } else if let n = dict[key] as? Double {
            b = n != 0
        } else if let s = dict[key] as? String {
            b = s == "1" || s.lowercased() == "true"
        } else {
            b = fallback
        }
        return .bool(b)
    }

    private static func numberValue(from dict: [String: Any], key: String, fallback: Double) -> AnyCodableValue {
        if let n = dict[key] as? Double { return .number(n) }
        if let n = dict[key] as? Int { return .number(Double(n)) }
        if let s = dict[key] as? String, let d = Double(s) { return .number(d) }
        return .number(fallback)
    }

    private static func stringValue(from dict: [String: Any], key: String) -> AnyCodableValue {
        if let s = dict[key] as? String { return .string(s) }
        return .string("")
    }
}
