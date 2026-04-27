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

    static func fromLegacy(_ config: SchedulerConfig) -> DisplaySchedulerConfig {
        DisplaySchedulerConfig(
            isEnabled: config.isEnabled,
            intervalMinutes: config.intervalMinutes,
            order: config.order,
            includeWallpapers: config.includeWallpapers,
            includeMedia: config.includeMedia
        )
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case intervalMinutes
        case order
        case source
        case includeWallpapers
        case includeMedia
    }

    init(
        isEnabled: Bool,
        intervalMinutes: Int,
        order: ScheduleOrder,
        includeWallpapers: Bool,
        includeMedia: Bool
    ) {
        self.isEnabled = isEnabled
        self.intervalMinutes = intervalMinutes
        self.order = order
        self.includeWallpapers = includeWallpapers
        self.includeMedia = includeMedia
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        intervalMinutes = try container.decode(Int.self, forKey: .intervalMinutes)
        order = try container.decode(ScheduleOrder.self, forKey: .order)

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
    }
}

struct SchedulerConfig: Codable {
    var isEnabled: Bool
    var intervalMinutes: Int      // 5, 15, 30, 60, 360, 1440
    var order: ScheduleOrder      // sequential, random
    var includeWallpapers: Bool
    var includeMedia: Bool
    var displayConfigs: [String: DisplaySchedulerConfig]

    static let `default` = SchedulerConfig(
        isEnabled: false,
        intervalMinutes: 60,
        order: .random,
        includeWallpapers: true,
        includeMedia: true,
        displayConfigs: [:]
    )

    static let intervalOptions: [Int] = [1, 5, 15, 30, 60, 360, 1440]

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case intervalMinutes
        case order
        case source
        case includeWallpapers
        case includeMedia
        case displayConfigs
    }

    init(
        isEnabled: Bool,
        intervalMinutes: Int,
        order: ScheduleOrder,
        includeWallpapers: Bool,
        includeMedia: Bool,
        displayConfigs: [String: DisplaySchedulerConfig] = [:]
    ) {
        self.isEnabled = isEnabled
        self.intervalMinutes = intervalMinutes
        self.order = order
        self.includeWallpapers = includeWallpapers
        self.includeMedia = includeMedia
        self.displayConfigs = displayConfigs
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
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(intervalMinutes, forKey: .intervalMinutes)
        try container.encode(order, forKey: .order)
        try container.encode(includeWallpapers, forKey: .includeWallpapers)
        try container.encode(includeMedia, forKey: .includeMedia)
        try container.encode(displayConfigs, forKey: .displayConfigs)
    }

    func resolvedDisplayConfig(for screenID: String) -> DisplaySchedulerConfig {
        displayConfigs[screenID] ?? .fromLegacy(self)
    }
}
