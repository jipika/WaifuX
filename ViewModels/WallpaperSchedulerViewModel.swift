import Foundation
import Combine
import AppKit

@MainActor
class WallpaperSchedulerViewModel: ObservableObject {
    @Published var config: SchedulerConfig = .default

    private let schedulerService = WallpaperSchedulerService.shared

    init() {
        schedulerService.$config
            .receive(on: DispatchQueue.main)
            .assign(to: &$config)
    }

    func updateSyncAllDisplays(_ enabled: Bool) {
        schedulerService.updateSyncAllDisplays(enabled)
    }

    // MARK: - Per-Display Config

    func displayConfig(for screen: NSScreen) -> DisplaySchedulerConfig {
        schedulerService.resolvedDisplayConfig(for: screen)
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

    func updateDisplayFolderIDs(_ folderIDs: [String]?, for screenID: String) {
        schedulerService.updateDisplayFolderIDs(folderIDs, for: screenID)
    }

    func updateDisplayWebSceneSwitchSeconds(_ seconds: Int?, for screenID: String) {
        schedulerService.updateDisplayWebSceneSwitchSeconds(seconds, for: screenID)
    }

}
