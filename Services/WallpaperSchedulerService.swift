import Foundation
import Combine
import AppKit

@MainActor
class WallpaperSchedulerService: ObservableObject {
    static let shared = WallpaperSchedulerService()

    @Published var config: SchedulerConfig = .default
    @Published var isRunning: Bool = false
    @Published var lastChangedWallpaper: Wallpaper?

    private var timer: Timer?
    private let userDefaultsKey = "wallpaper_scheduler_config"

    private init() {}

    /// 延迟恢复保存的调度配置
    func restoreSavedConfig() {
        loadConfig()
    }

    // MARK: - Control

    func start() {
        guard !isRunning else { return }
        isRunning = true
        scheduleNextChange()
        saveConfig()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
        saveConfig()
    }

    func updateConfig(_ newConfig: SchedulerConfig) {
        config = newConfig
        saveConfig()
        if isRunning {
            stop()
            start()
        }
    }

    // MARK: - Per-Display Updates

    func updateDisplayEnabled(_ enabled: Bool, for screenID: String) {
        var newConfig = config
        var displayConfig = newConfig.resolvedDisplayConfig(for: screenID)
        displayConfig.isEnabled = enabled
        newConfig.displayConfigs[screenID] = displayConfig
        updateConfig(newConfig)
    }

    func updateDisplayInterval(_ minutes: Int, for screenID: String) {
        var newConfig = config
        var displayConfig = newConfig.resolvedDisplayConfig(for: screenID)
        displayConfig.intervalMinutes = minutes
        newConfig.displayConfigs[screenID] = displayConfig
        updateConfig(newConfig)
    }

    func updateDisplayOrder(_ order: ScheduleOrder, for screenID: String) {
        var newConfig = config
        var displayConfig = newConfig.resolvedDisplayConfig(for: screenID)
        displayConfig.order = order
        newConfig.displayConfigs[screenID] = displayConfig
        updateConfig(newConfig)
    }

    func updateDisplaySource(_ source: WallpaperSource, for screenID: String) {
        var newConfig = config
        var displayConfig = newConfig.resolvedDisplayConfig(for: screenID)
        displayConfig.source = source
        newConfig.displayConfigs[screenID] = displayConfig
        updateConfig(newConfig)
    }

    // MARK: - Scheduling

    private func scheduleNextChange() {
        timer?.invalidate()

        let interval = TimeInterval(config.intervalMinutes * 60)
        guard interval > 0 else { return }

        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.changeWallpaperIfNeeded()
            }
        }
    }

    private func changeWallpaperIfNeeded() {
        let screens = NSScreen.screens
        for screen in screens {
            let screenID = screen.wallpaperScreenIdentifier
            let displayConfig = config.resolvedDisplayConfig(for: screenID)
            guard displayConfig.isEnabled else { continue }

            if let wallpaper = selectNextWallpaper(for: displayConfig) {
                applyWallpaper(wallpaper, to: screen)
            }
        }
    }

    private func applyWallpaper(_ wallpaper: Wallpaper, to screen: NSScreen) {
        guard let url = wallpaper.fullImageURL ?? wallpaper.thumbURL else { return }

        Task { @MainActor in
            do {
                WallpaperEngineXBridge.shared.ensureStoppedForNonCLIWallpaper()
                VideoWallpaperManager.shared.stopNativeVideoWallpaperOnly()

                let tempURL = try await downloadImage(from: url)
                try NSWorkspace.shared.setDesktopImageURL(tempURL, for: screen, options: [:])
                lastChangedWallpaper = wallpaper
            } catch {
                print("[WallpaperSchedulerService] Failed to set wallpaper: \(error)")
            }
        }
    }

    private func downloadImage(from url: URL) async throws -> URL {
        let (data, _) = try await URLSession.shared.data(from: url)
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("wallpaper_\(UUID().uuidString).jpg")
        try data.write(to: tempFile)
        return tempFile
    }

    // MARK: - Wallpaper Selection

    func selectNextWallpaper(for displayConfig: DisplaySchedulerConfig) -> Wallpaper? {
        let wallpapers = getWallpapersForSource(displayConfig.source)
        guard !wallpapers.isEmpty else { return nil }

        switch displayConfig.order {
        case .sequential:
            return selectSequential(from: wallpapers)
        case .random:
            return selectRandom(from: wallpapers)
        }
    }

    private func getWallpapersForSource(_ source: WallpaperSource) -> [Wallpaper] {
        let vm = WallpaperViewModel()
        switch source {
        case .online:
            return vm.wallpapers
        case .local:
            return []
        case .favorites:
            return vm.favorites
        }
    }

    private func selectSequential(from wallpapers: [Wallpaper]) -> Wallpaper? {
        wallpapers.randomElement()
    }

    private func selectRandom(from wallpapers: [Wallpaper]) -> Wallpaper? {
        var available = wallpapers
        if let last = lastChangedWallpaper, let index = available.firstIndex(where: { $0.id == last.id }) {
            available.remove(at: index)
        }
        return available.randomElement() ?? wallpapers.randomElement()
    }

    // MARK: - Persistence

    private func saveConfig() {
        if let encoded = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(encoded, forKey: userDefaultsKey)
        }
    }

    private func loadConfig() {
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let loadedConfig = try? JSONDecoder().decode(SchedulerConfig.self, from: data) {
            config = loadedConfig
            if config.isEnabled {
                start()
            }
        }
    }
}

private extension NSScreen {
    var wallpaperScreenIdentifier: String {
        if let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return screenNumber.stringValue
        }
        return localizedName + ":\(frame.origin.x):\(frame.origin.y)"
    }
}
