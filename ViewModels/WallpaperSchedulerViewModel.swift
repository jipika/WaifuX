import Foundation
import Combine

@MainActor
class WallpaperSchedulerViewModel: ObservableObject {
    @Published var config: SchedulerConfig = .default
    @Published var isRunning: Bool = false
    @Published var lastChangedWallpaper: Wallpaper?

    private let schedulerService = WallpaperSchedulerService.shared
    private var cancellables = Set<AnyCancellable>()

    init() {
        // 绑定服务状态到本地属性
        schedulerService.$config
            .receive(on: DispatchQueue.main)
            .assign(to: &$config)

        schedulerService.$isRunning
            .receive(on: DispatchQueue.main)
            .assign(to: &$isRunning)

        schedulerService.$lastChangedWallpaper
            .receive(on: DispatchQueue.main)
            .assign(to: &$lastChangedWallpaper)
    }

    // MARK: - Control Actions

    func toggleScheduler() {
        if isRunning {
            stop()
        } else {
            start()
        }
    }

    func start() {
        schedulerService.start()
    }

    func stop() {
        schedulerService.stop()
    }

    func updateInterval(_ minutes: Int) {
        var newConfig = config
        newConfig.intervalMinutes = minutes
        schedulerService.updateConfig(newConfig)
    }

    func updateOrder(_ order: ScheduleOrder) {
        var newConfig = config
        newConfig.order = order
        schedulerService.updateConfig(newConfig)
    }

    func updateSource(_ source: WallpaperSource) {
        var newConfig = config
        newConfig.source = source
        schedulerService.updateConfig(newConfig)
    }

    // MARK: - Computed Properties

    var intervalLabel: String {
        switch config.intervalMinutes {
        case 5: return "5 min"
        case 15: return "15 min"
        case 30: return "30 min"
        case 60: return "1 hour"
        case 360: return "6 hours"
        case 1440: return "24 hours"
        default: return "\(config.intervalMinutes) min"
        }
    }

    var orderLabel: String {
        switch config.order {
        case .sequential: return "Sequential"
        case .random: return "Random"
        }
    }

    var sourceLabel: String {
        switch config.source {
        case .online: return "Online"
        case .local: return "Local"
        case .favorites: return "Favorites"
        }
    }
}
