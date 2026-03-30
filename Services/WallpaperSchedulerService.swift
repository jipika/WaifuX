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

    private init() {
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
            // 重启调度器以应用新配置
            stop()
            start()
        }
    }

    // MARK: - Scheduling

    private func scheduleNextChange() {
        timer?.invalidate()

        let interval = TimeInterval(config.intervalMinutes * 60)

        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.changeWallpaper()
            }
        }
    }

    private func changeWallpaper() {
        guard let wallpaper = selectNextWallpaper() else { return }

        do {
            let imageURL = wallpaper.fullImageURL ?? wallpaper.thumbURL
            guard let url = imageURL else { return }

            let workspace = NSWorkspace.shared
            guard let screen = NSScreen.main else { return }

            // 下载图片到临时文件再设置为壁纸
            Task {
                do {
                    let tempURL = try await downloadImage(from: url)
                    try workspace.setDesktopImageURL(tempURL, for: screen, options: [:])
                    lastChangedWallpaper = wallpaper
                } catch {
                    print("Failed to set wallpaper: \(error)")
                }
            }
        }
    }

    private func downloadImage(from url: URL) async throws -> URL {
        let (data, _) = try await URLSession.shared.data(from: url)
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("wallpaper_\(UUID().uuidString).jpg")
        try data.write(to: tempFile)
        return tempFile
    }

    // MARK: - Wallpaper Selection

    func selectNextWallpaper() -> Wallpaper? {
        // 获取壁纸列表
        let wallpapers = getWallpapersForSource()

        guard !wallpapers.isEmpty else { return nil }

        switch config.order {
        case .sequential:
            return selectSequential(from: wallpapers)
        case .random:
            return selectRandom(from: wallpapers)
        }
    }

    private func getWallpapersForSource() -> [Wallpaper] {
        switch config.source {
        case .online:
            // 在线壁纸需要从 ViewModel 获取
            return WallpaperViewModel().wallpapers
        case .local:
            // 本地壁纸需要从缓存获取
            return []
        case .favorites:
            // 使用收藏列表
            return WallpaperViewModel().favorites
        }
    }

    private func selectSequential(from wallpapers: [Wallpaper]) -> Wallpaper? {
        // 简单实现：随机选择（严格顺序需要跟踪索引）
        return wallpapers.randomElement()
    }

    private func selectRandom(from wallpapers: [Wallpaper]) -> Wallpaper? {
        // 避免选择与上次相同的壁纸
        var available = wallpapers
        if let last = lastChangedWallpaper, let index = available.firstIndex(where: { $0.id == last.id }) {
            available.remove(at: index)
        }
        return available.randomElement()
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
