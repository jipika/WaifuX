import Foundation
import Combine

@MainActor
class WallpaperSchedulerViewModel: ObservableObject {
    @Published var config: SchedulerConfig = .default
    @Published var isRunning: Bool = false

    private let schedulerService = WallpaperSchedulerService.shared
    private var cancellables = Set<AnyCancellable>()

    init() {
        schedulerService.$config
            .receive(on: DispatchQueue.main)
            .assign(to: &$config)

        schedulerService.$isRunning
            .receive(on: DispatchQueue.main)
            .assign(to: &$isRunning)
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
        schedulerService.updateConfig(
            SchedulerConfig(
                isEnabled: config.isEnabled,
                intervalMinutes: minutes,
                order: config.order,
                includeWallpapers: config.includeWallpapers,
                includeMedia: config.includeMedia,
                displayConfigs: config.displayConfigs
            )
        )
    }

    func updateOrder(_ order: ScheduleOrder) {
        schedulerService.updateConfig(
            SchedulerConfig(
                isEnabled: config.isEnabled,
                intervalMinutes: config.intervalMinutes,
                order: order,
                includeWallpapers: config.includeWallpapers,
                includeMedia: config.includeMedia,
                displayConfigs: config.displayConfigs
            )
        )
    }

    func updateIncludeWallpapers(_ include: Bool) {
        schedulerService.updateConfig(
            SchedulerConfig(
                isEnabled: config.isEnabled,
                intervalMinutes: config.intervalMinutes,
                order: config.order,
                includeWallpapers: include,
                includeMedia: config.includeMedia,
                displayConfigs: config.displayConfigs
            )
        )
    }

    func updateIncludeMedia(_ include: Bool) {
        schedulerService.updateConfig(
            SchedulerConfig(
                isEnabled: config.isEnabled,
                intervalMinutes: config.intervalMinutes,
                order: config.order,
                includeWallpapers: config.includeWallpapers,
                includeMedia: include,
                displayConfigs: config.displayConfigs
            )
        )
    }

    // MARK: - Per-Display Config

    func displayConfig(for screenID: String) -> DisplaySchedulerConfig {
        config.resolvedDisplayConfig(for: screenID)
    }

    func updateDisplayEnabled(_ enabled: Bool, for screenID: String) {
        schedulerService.updateDisplayEnabled(enabled, for: screenID)
    }

    func updateDisplayInterval(_ minutes: Int, for screenID: String) {
        schedulerService.updateDisplayInterval(minutes, for: screenID)
    }

    func updateDisplayOrder(_ order: ScheduleOrder, for screenID: String) {
        schedulerService.updateDisplayOrder(order, for: screenID)
    }

    func updateDisplayIncludeWallpapers(_ include: Bool, for screenID: String) {
        schedulerService.updateDisplayIncludeWallpapers(include, for: screenID)
    }

    func updateDisplayIncludeMedia(_ include: Bool, for screenID: String) {
        schedulerService.updateDisplayIncludeMedia(include, for: screenID)
    }

    // MARK: - Computed Properties

    var intervalLabel: String {
        intervalLabel(for: config.intervalMinutes)
    }

    func intervalLabel(for minutes: Int) -> String {
        switch minutes {
        case 1: return "1 min"
        case 5: return "5 min"
        case 15: return "15 min"
        case 30: return "30 min"
        case 60: return "1 hour"
        case 360: return "6 hours"
        case 1440: return "24 hours"
        default: return "\(minutes) min"
        }
    }

    var orderLabel: String {
        switch config.order {
        case .sequential: return "Sequential"
        case .random: return "Random"
        }
    }
}
