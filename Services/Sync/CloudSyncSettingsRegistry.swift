import Foundation

// MARK: - 设置分类
enum CloudSyncSettingsCategory: String, Codable, CaseIterable {
    case general       // 主题、下载、代理、模块开关等
    case playback      // 自动暂停、HDR、音量等
    case wallpaperEngine // 超分、FPS、烘焙、实时渲染等
    case appearance    // Arc 背景、颗粒、刘海等
    case clock         // Liquid Glass 时钟
    case sources       // 数据源、壁纸源、规则仓库
    case player        // 弹幕、播放器增强
    case localization  // 语言

    var displayName: String {
        switch self {
        case .general: return "通用"
        case .playback: return "播放"
        case .wallpaperEngine: return "壁纸引擎"
        case .appearance: return "外观"
        case .clock: return "时钟"
        case .sources: return "数据源"
        case .player: return "播放器"
        case .localization: return "语言"
        }
    }
}

// MARK: - 值类型
enum CloudSyncSettingsValueType: Codable {
    case bool
    case string
    case double
    case data
}

// MARK: - 白名单条目
struct CloudSyncSettingsEntry {
    let key: String
    let category: CloudSyncSettingsCategory
    let valueType: CloudSyncSettingsValueType
}

// MARK: - 设置注册表
enum CloudSyncSettingsRegistry {
    /// 完整的同步白名单
    static var allEntries: [CloudSyncSettingsEntry] {
        generalEntries + playbackEntries + wallpaperEngineEntries
            + appearanceEntries + clockEntries + sourcesEntries
            + playerEntries + localizationEntries
    }

    // MARK: - 通用设置
    private static var generalEntries: [CloudSyncSettingsEntry] {
        [
            .init(key: "theme_mode", category: .general, valueType: .string),
            .init(key: "save_to_downloads", category: .general, valueType: .bool),
            .init(key: "launch_at_login", category: .general, valueType: .bool),
            .init(key: "prevent_system_sleep", category: .general, valueType: .bool),
            .init(key: "proxy_enabled", category: .general, valueType: .bool),
            .init(key: "proxy_host", category: .general, valueType: .string),
            .init(key: "proxy_port", category: .general, valueType: .string),
            .init(key: "module_wallpaper_enabled", category: .general, valueType: .bool),
            .init(key: "module_media_enabled", category: .general, valueType: .bool),
            .init(key: "module_anime_enabled", category: .general, valueType: .bool),
            .init(key: "show_all_workshop_content", category: .general, valueType: .bool),
            .init(key: "dynamic_lock_screen_enabled", category: .general, valueType: .bool),
            .init(key: "system_wallpaper_sync_enabled", category: .general, valueType: .bool),
        ]
    }

    // MARK: - 播放设置
    private static var playbackEntries: [CloudSyncSettingsEntry] {
        [
            .init(key: "pause_when_other_app_foreground", category: .playback, valueType: .bool),
            .init(key: "pause_when_fullscreen_covers", category: .playback, valueType: .bool),
            .init(key: "pause_on_battery_power", category: .playback, valueType: .bool),
            .init(key: "pause_when_window_coverage", category: .playback, valueType: .bool),
            .init(key: "window_coverage_pause_threshold", category: .playback, valueType: .double),
            .init(key: "hdr_enabled", category: .playback, valueType: .bool),
        ]
    }

    // MARK: - 壁纸引擎设置
    private static var wallpaperEngineEntries: [CloudSyncSettingsEntry] {
        [
            .init(key: "scene_realtime_rendering_enabled", category: .wallpaperEngine, valueType: .bool),
            .init(key: "upscaling_enabled", category: .wallpaperEngine, valueType: .bool),
            .init(key: "upscaling_percent", category: .wallpaperEngine, valueType: .double),
            .init(key: "effect_reduction_enabled", category: .wallpaperEngine, valueType: .bool),
            .init(key: "wallpaper_engine_fps", category: .wallpaperEngine, valueType: .double),
            .init(key: "scene_bake_fps", category: .wallpaperEngine, valueType: .double),
            .init(key: "scene_bake_duration", category: .wallpaperEngine, valueType: .double),
            .init(key: "auto_bake_scene", category: .wallpaperEngine, valueType: .bool),
        ]
    }

    // MARK: - 外观设置（避免与 general 重叠）
    private static var appearanceEntries: [CloudSyncSettingsEntry] {
        [
            .init(key: "arc_theme_mode", category: .appearance, valueType: .string),
            .init(key: "arc_accent_color", category: .appearance, valueType: .string),
            .init(key: "arc_frosted_intensity", category: .appearance, valueType: .double),
            .init(key: "grain_texture_enabled", category: .appearance, valueType: .bool),
            .init(key: "grain_texture_quality", category: .appearance, valueType: .string),
            .init(key: "arc_grain_intensity", category: .appearance, valueType: .double),
            .init(key: "arc_dot_grid_opacity", category: .appearance, valueType: .double),
            .init(key: "arc_use_noise", category: .appearance, valueType: .bool),
            .init(key: "arc_compact_mode", category: .appearance, valueType: .bool),
            .init(key: "hide_notch", category: .appearance, valueType: .bool),
            .init(key: "explore_grain_wallpaper", category: .appearance, valueType: .double),
            .init(key: "explore_grain_anime", category: .appearance, valueType: .double),
            .init(key: "explore_grain_media", category: .appearance, valueType: .double),
        ]
    }

    // MARK: - 时钟设置
    private static var clockEntries: [CloudSyncSettingsEntry] {
        [
            .init(key: "liquid_glass_clock_config_v2", category: .clock, valueType: .data),
        ]
    }

    // MARK: - 数据源设置
    private static var sourcesEntries: [CloudSyncSettingsEntry] {
        [
            .init(key: "wallpaper_selected_source", category: .sources, valueType: .string),
            .init(key: "workshop_selected_source", category: .sources, valueType: .string),
            .init(key: "workshop_steam_profile_id", category: .sources, valueType: .string),
            .init(key: "rule_repository_url", category: .sources, valueType: .string),
            .init(key: "data_source_profiles_v1", category: .sources, valueType: .data),
            .init(key: "data_source_active_profile_id_v1", category: .sources, valueType: .string),
            .init(key: WallhavenBrowsePreferences.hidePortraitByDefaultKey, category: .sources, valueType: .bool),
            .init(key: WallhavenBrowsePreferences.hidePeopleByDefaultKey, category: .sources, valueType: .bool),
        ]
    }

    // MARK: - 播放器增强设置
    private static var playerEntries: [CloudSyncSettingsEntry] {
        [
            .init(key: "danmaku_enabled", category: .player, valueType: .bool),
            .init(key: "danmaku_opacity", category: .player, valueType: .double),
            .init(key: "danmaku_speed", category: .player, valueType: .double),
            .init(key: "danmaku_font_size", category: .player, valueType: .double),
            .init(key: "player_enhancement_enabled", category: .player, valueType: .bool),
        ]
    }

    // MARK: - 语言设置
    private static var localizationEntries: [CloudSyncSettingsEntry] {
        [
            .init(key: "app_language", category: .localization, valueType: .string),
        ]
    }

    // MARK: - 读取和写入

    /// 读取所有白名单中的设置
    static func exportSettings() -> [CloudSyncSettingsCategory: [String: AnyCodable]] {
        let defaults = UserDefaults.standard
        var result: [CloudSyncSettingsCategory: [String: AnyCodable]] = [:]

        for entry in allEntries {
            guard let value = readValue(from: defaults, entry: entry) else { continue }
            result[entry.category, default: [:]][entry.key] = value
        }

        return result
    }

    /// 写入设置到 UserDefaults（根据冲突策略决定是否覆盖）
    static func importSettings(
        _ settings: [CloudSyncSettingsCategory: [String: AnyCodable]],
        strategy: CloudSyncConflictStrategy = .cloudPreferred
    ) {
        let defaults = UserDefaults.standard

        guard strategy == .cloudPreferred else { return }

        for (_, entries) in settings {
            for (key, value) in entries {
                // 检查是否在白名单中
                guard allEntries.contains(where: { $0.key == key }) else { continue }
                writeValue(value, to: defaults, key: key)
            }
        }

        // 通知各服务重新加载设置
        notifySettingsChanged()
    }

    /// 获取云端和本地都存在的分类（用于展示同步预览）
    static func categorizedKeys() -> [(CloudSyncSettingsCategory, [CloudSyncSettingsEntry])] {
        let grouped = Dictionary(grouping: allEntries, by: { $0.category })
        return grouped.map { ($0.key, $0.value) }
            .sorted { $0.0.rawValue < $1.0.rawValue }
    }

    // MARK: - 内部辅助

    private static func readValue(
        from defaults: UserDefaults,
        entry: CloudSyncSettingsEntry
    ) -> AnyCodable? {
        switch entry.valueType {
        case .bool:
            guard defaults.object(forKey: entry.key) != nil else { return nil }
            return .bool(defaults.bool(forKey: entry.key))
        case .string:
            guard let val = defaults.string(forKey: entry.key), !val.isEmpty else { return nil }
            return .string(val)
        case .double:
            guard defaults.object(forKey: entry.key) != nil else { return nil }
            return .number(defaults.double(forKey: entry.key))
        case .data:
            guard let val = defaults.data(forKey: entry.key) else { return nil }
            return .data(val)
        }
    }

    private static func writeValue(_ value: AnyCodable, to defaults: UserDefaults, key: String) {
        switch value {
        case .bool(let b):
            defaults.set(b, forKey: key)
        case .string(let s):
            defaults.set(s, forKey: key)
        case .number(let n):
            defaults.set(n, forKey: key)
        case .data(let d):
            defaults.set(d, forKey: key)
        }
    }

    private static func notifySettingsChanged() {
        // 发送通知让各服务重载
        NotificationCenter.default.post(name: .cloudSyncSettingsImported, object: nil)
    }
}

// MARK: - AnyCodable（JSON 兼容包装）
enum AnyCodable: Codable {
    case bool(Bool)
    case string(String)
    case number(Double)
    case data(Data)

    var codableValue: Codable {
        switch self {
        case .bool(let v): return v
        case .string(let v): return v
        case .number(let v): return v
        case .data(let v): return v
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let boolVal = try? container.decode(Bool.self) {
            self = .bool(boolVal)
        } else if let stringVal = try? container.decode(String.self) {
            self = .string(stringVal)
        } else if let doubleVal = try? container.decode(Double.self) {
            self = .number(doubleVal)
        } else {
            throw DecodingError.typeMismatch(
                AnyCodable.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "不支持的 AnyCodable 类型")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let v): try container.encode(v)
        case .string(let v): try container.encode(v)
        case .number(let v): try container.encode(v)
        case .data(let v): try container.encode(v.base64EncodedString())
        }
    }
}

// MARK: - 通知扩展
extension Notification.Name {
    static let cloudSyncSettingsImported = Notification.Name("cloudSyncSettingsImported")
}
