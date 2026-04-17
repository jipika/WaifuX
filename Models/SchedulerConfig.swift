import Foundation

enum ScheduleOrder: String, Codable {
    case sequential
    case random
}

enum WallpaperSource: String, Codable {
    case online
    case local
    case favorites
}

struct DisplaySchedulerConfig: Codable, Equatable {
    var isEnabled: Bool
    var intervalMinutes: Int
    var order: ScheduleOrder
    var source: WallpaperSource

    static func fromLegacy(_ config: SchedulerConfig) -> DisplaySchedulerConfig {
        DisplaySchedulerConfig(
            isEnabled: config.isEnabled,
            intervalMinutes: config.intervalMinutes,
            order: config.order,
            source: config.source
        )
    }
}

struct SchedulerConfig: Codable {
    var isEnabled: Bool
    var intervalMinutes: Int      // 5, 15, 30, 60, 360, 1440
    var order: ScheduleOrder      // sequential, random
    var source: WallpaperSource   // online, local, favorites
    var displayConfigs: [String: DisplaySchedulerConfig]

    static let `default` = SchedulerConfig(
        isEnabled: false,
        intervalMinutes: 60,
        order: .random,
        source: .favorites,
        displayConfigs: [:]
    )

    static let intervalOptions: [Int] = [5, 15, 30, 60, 360, 1440]

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case intervalMinutes
        case order
        case source
        case displayConfigs
    }

    init(
        isEnabled: Bool,
        intervalMinutes: Int,
        order: ScheduleOrder,
        source: WallpaperSource,
        displayConfigs: [String: DisplaySchedulerConfig] = [:]
    ) {
        self.isEnabled = isEnabled
        self.intervalMinutes = intervalMinutes
        self.order = order
        self.source = source
        self.displayConfigs = displayConfigs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        intervalMinutes = try container.decode(Int.self, forKey: .intervalMinutes)
        order = try container.decode(ScheduleOrder.self, forKey: .order)
        source = try container.decode(WallpaperSource.self, forKey: .source)
        displayConfigs = try container.decodeIfPresent([String: DisplaySchedulerConfig].self, forKey: .displayConfigs) ?? [:]
    }

    func resolvedDisplayConfig(for screenID: String) -> DisplaySchedulerConfig {
        displayConfigs[screenID] ?? .fromLegacy(self)
    }
}
