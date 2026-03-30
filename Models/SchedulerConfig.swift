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

struct SchedulerConfig: Codable {
    var isEnabled: Bool
    var intervalMinutes: Int      // 5, 15, 30, 60, 360, 1440
    var order: ScheduleOrder      // sequential, random
    var source: WallpaperSource   // online, local, favorites

    static let `default` = SchedulerConfig(
        isEnabled: false,
        intervalMinutes: 60,
        order: .random,
        source: .favorites
    )

    static let intervalOptions: [Int] = [5, 15, 30, 60, 360, 1440]
}
