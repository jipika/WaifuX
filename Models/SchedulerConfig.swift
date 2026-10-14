import Foundation

enum ScheduleOrder: String, Codable {
    case sequential
    case random
}

// MARK: - Legacy WallpaperSource (kept for backward-compatible decoding only)
private enum LegacyWallpaperSource: String, Codable {
    case online
    case local
    case favorites
}

struct DisplaySchedulerConfig: Codable, Equatable {
    var isEnabled: Bool
    var intervalMinutes: Int
    var order: ScheduleOrder
    var includeWallpapers: Bool
    var includeMedia: Bool
    /// 限制自动切换的文件夹 ID 列表。nil = 全部，非空数组 = 仅这些文件夹（含根目录无 folderID 的项）
    var folderIDs: [String]?
    /// Web/Scene 壁纸在"播完即换"模式下的切换间隔（秒）。nil = 不启用（仅视频走播完通知）
    var webSceneSwitchSeconds: Int?
    /// Persist ownership with the folder policy, in the same encoded record.
    /// CGDirectDisplayID is only a live routing address and may be reused after wake.
    var displayFingerprint: String? = nil

    /// 判断是否为"播完即换"模式
    var isOnEndMode: Bool {
        intervalMinutes == SchedulerConfig.intervalOnEndMinutes
    }

    /// 判断是否为"解锁即换"模式
    var isOnUnlockMode: Bool {
        intervalMinutes == SchedulerConfig.intervalOnUnlockMinutes
    }

    static func fromLegacy(_ config: SchedulerConfig) -> DisplaySchedulerConfig {
        DisplaySchedulerConfig(
            isEnabled: config.isEnabled,
            intervalMinutes: config.intervalMinutes,
            order: config.order,
            includeWallpapers: config.includeWallpapers,
            includeMedia: config.includeMedia,
            folderIDs: nil,
            webSceneSwitchSeconds: nil
        )
    }

    private enum CodingKeys: String, CodingKey {
        // isWallpaperEnabled 已废弃：旧配置若含此字段，解码时忽略
        case isEnabled
        case intervalMinutes
        case order
        case source
        case includeWallpapers
        case includeMedia
        case folderIDs
        case webSceneSwitchSeconds
        case displayFingerprint
    }

    init(
        isEnabled: Bool,
        intervalMinutes: Int,
        order: ScheduleOrder,
        includeWallpapers: Bool,
        includeMedia: Bool,
        folderIDs: [String]? = nil,
        webSceneSwitchSeconds: Int? = nil
    ) {
        self.isEnabled = isEnabled
        self.intervalMinutes = intervalMinutes
        self.order = order
        self.includeWallpapers = includeWallpapers
        self.includeMedia = includeMedia
        self.folderIDs = folderIDs
        self.webSceneSwitchSeconds = webSceneSwitchSeconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        intervalMinutes = try container.decode(Int.self, forKey: .intervalMinutes)
        order = try container.decode(ScheduleOrder.self, forKey: .order)
        folderIDs = try container.decodeIfPresent([String].self, forKey: .folderIDs)
        webSceneSwitchSeconds = try container.decodeIfPresent(Int.self, forKey: .webSceneSwitchSeconds)
        displayFingerprint = try container.decodeIfPresent(String.self, forKey: .displayFingerprint)

        if let includeWallpapers = try? container.decode(Bool.self, forKey: .includeWallpapers),
           let includeMedia = try? container.decode(Bool.self, forKey: .includeMedia) {
            self.includeWallpapers = includeWallpapers
            self.includeMedia = includeMedia
        } else if let legacySource = try? container.decode(LegacyWallpaperSource.self, forKey: .source) {
            switch legacySource {
            case .online, .favorites:
                self.includeWallpapers = true
                self.includeMedia = false
            case .local:
                self.includeWallpapers = true
                self.includeMedia = true
            }
        } else {
            self.includeWallpapers = true
            self.includeMedia = true
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(intervalMinutes, forKey: .intervalMinutes)
        try container.encode(order, forKey: .order)
        try container.encode(includeWallpapers, forKey: .includeWallpapers)
        try container.encode(includeMedia, forKey: .includeMedia)
        try container.encodeIfPresent(folderIDs, forKey: .folderIDs)
        try container.encodeIfPresent(webSceneSwitchSeconds, forKey: .webSceneSwitchSeconds)
        try container.encodeIfPresent(displayFingerprint, forKey: .displayFingerprint)
    }
}

struct SchedulerConfig: Codable {
    var isEnabled: Bool
    var intervalMinutes: Int      // 5, 15, 30, 60, 360, 1440
    var order: ScheduleOrder      // sequential, random
    var includeWallpapers: Bool
    var includeMedia: Bool
    var displayConfigs: [String: DisplaySchedulerConfig]
    /// Global mode keeps an independent rotation policy while preserving the
    /// existing per-display policies for a later return to independent mode.
    var isGlobalDisplaySyncEnabled: Bool
    var globalDisplayConfig: DisplaySchedulerConfig

    /// 特殊间隔值：播完即换（视频播放完毕后自动切换到下一个）
    static let intervalOnEndMinutes: Int = -1
    /// 特殊间隔值：解锁即换（每次从锁屏解锁进入桌面后自动切换到下一个）
    static let intervalOnUnlockMinutes: Int = -2

    static let `default` = SchedulerConfig(
        isEnabled: false,
        intervalMinutes: 60,
        order: .random,
        includeWallpapers: true,
        includeMedia: true,
        displayConfigs: [:],
        isGlobalDisplaySyncEnabled: false,
        globalDisplayConfig: DisplaySchedulerConfig(
            isEnabled: false,
            intervalMinutes: 60,
            order: .random,
            includeWallpapers: true,
            includeMedia: true
        )
    )

    static let intervalOptions: [Int] = [1, 3, 5, 15, 30, 60, 360, 1440]

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case intervalMinutes
        case order
        case source
        case includeWallpapers
        case includeMedia
        case displayConfigs
        case isGlobalDisplaySyncEnabled
        case globalDisplayConfig
    }

    init(
        isEnabled: Bool,
        intervalMinutes: Int,
        order: ScheduleOrder,
        includeWallpapers: Bool,
        includeMedia: Bool,
        displayConfigs: [String: DisplaySchedulerConfig] = [:],
        isGlobalDisplaySyncEnabled: Bool = false,
        globalDisplayConfig: DisplaySchedulerConfig? = nil
    ) {
        self.isEnabled = isEnabled
        self.intervalMinutes = intervalMinutes
        self.order = order
        self.includeWallpapers = includeWallpapers
        self.includeMedia = includeMedia
        self.displayConfigs = displayConfigs
        self.isGlobalDisplaySyncEnabled = isGlobalDisplaySyncEnabled
        self.globalDisplayConfig = globalDisplayConfig ?? DisplaySchedulerConfig(
            isEnabled: isEnabled,
            intervalMinutes: intervalMinutes,
            order: order,
            includeWallpapers: includeWallpapers,
            includeMedia: includeMedia
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        intervalMinutes = try container.decode(Int.self, forKey: .intervalMinutes)
        order = try container.decode(ScheduleOrder.self, forKey: .order)
        displayConfigs = try container.decodeIfPresent([String: DisplaySchedulerConfig].self, forKey: .displayConfigs) ?? [:]

        // Backward compatibility: read new fields, or infer from legacy source
        if let includeWallpapers = try? container.decode(Bool.self, forKey: .includeWallpapers),
           let includeMedia = try? container.decode(Bool.self, forKey: .includeMedia) {
            self.includeWallpapers = includeWallpapers
            self.includeMedia = includeMedia
        } else if let legacySource = try? container.decode(LegacyWallpaperSource.self, forKey: .source) {
            switch legacySource {
            case .online, .favorites:
                self.includeWallpapers = true
                self.includeMedia = false
            case .local:
                self.includeWallpapers = true
                self.includeMedia = true
            }
        } else {
            self.includeWallpapers = true
            self.includeMedia = true
        }

        isGlobalDisplaySyncEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .isGlobalDisplaySyncEnabled
        ) ?? false
        globalDisplayConfig = try container.decodeIfPresent(
            DisplaySchedulerConfig.self,
            forKey: .globalDisplayConfig
        ) ?? DisplaySchedulerConfig(
            isEnabled: isEnabled,
            intervalMinutes: intervalMinutes,
            order: order,
            includeWallpapers: includeWallpapers,
            includeMedia: includeMedia
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(intervalMinutes, forKey: .intervalMinutes)
        try container.encode(order, forKey: .order)
        try container.encode(includeWallpapers, forKey: .includeWallpapers)
        try container.encode(includeMedia, forKey: .includeMedia)
        try container.encode(displayConfigs, forKey: .displayConfigs)
        try container.encode(isGlobalDisplaySyncEnabled, forKey: .isGlobalDisplaySyncEnabled)
        try container.encode(globalDisplayConfig, forKey: .globalDisplayConfig)
    }

    func resolvedDisplayConfig(for screenID: String) -> DisplaySchedulerConfig {
        if isGlobalDisplaySyncEnabled {
            return globalDisplayConfig
        }
        return storedDisplayConfig(for: screenID)
    }

    /// Reads the saved per-display policy even while global mode is active.
    func storedDisplayConfig(for screenID: String) -> DisplaySchedulerConfig {
        if let config = displayConfigs[screenID] {
            return config
        }
        // 无 per-display 配置的显示器（如新接入/唤醒后延迟枚举的屏幕）默认关闭自动切换。
        // 不再从全局 isEnabled 继承，避免旧版遗留的全局开关误开启新显示器。
        var fallback = DisplaySchedulerConfig.fromLegacy(self)
        fallback.isEnabled = false
        return fallback
    }
}
