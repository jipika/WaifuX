import Foundation
import Combine
import AppKit

@MainActor
class WallpaperSchedulerService: ObservableObject {
    static let shared = WallpaperSchedulerService()

    @Published var config: SchedulerConfig = .default
    @Published var isRunning: Bool = false

    /// Tracks last-applied item ID per screen to avoid immediate repeats.
    private var lastChangedItemIDs: [String: String] = [:]
    /// Tracks last change time per screen to honor per-display intervals.
    private var lastChangeTimes: [String: Date] = [:]

    private var timer: Timer?
    private let userDefaultsKey = "wallpaper_scheduler_config"
    private let logTag = "[WallpaperScheduler]"

    private init() {}

    /// 延迟恢复保存的调度配置
    func restoreSavedConfig() {
        loadConfig()
    }

    // MARK: - Control

    func start() {
        guard !isRunning else { return }
        isRunning = true
        config.isEnabled = true
        scheduleNextChange()
        saveConfig()
        print("\(logTag) Started. Check interval: \(effectiveCheckInterval())s")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
        config.isEnabled = false
        saveConfig()
        print("\(logTag) Stopped.")
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

    func updateDisplayIncludeWallpapers(_ include: Bool, for screenID: String) {
        var newConfig = config
        var displayConfig = newConfig.resolvedDisplayConfig(for: screenID)
        displayConfig.includeWallpapers = include
        newConfig.displayConfigs[screenID] = displayConfig
        updateConfig(newConfig)
    }

    func updateDisplayIncludeMedia(_ include: Bool, for screenID: String) {
        var newConfig = config
        var displayConfig = newConfig.resolvedDisplayConfig(for: screenID)
        displayConfig.includeMedia = include
        newConfig.displayConfigs[screenID] = displayConfig
        updateConfig(newConfig)
    }

    // MARK: - Scheduling

    /// Returns the smallest interval among all enabled displays (or the global fallback).
    private func effectiveCheckInterval() -> TimeInterval {
        let screens = NSScreen.screens
        let intervals = screens.compactMap { screen -> TimeInterval? in
            let screenID = screen.wallpaperScreenIdentifier
            let displayConfig = config.resolvedDisplayConfig(for: screenID)
            guard displayConfig.isEnabled else { return nil }
            return TimeInterval(displayConfig.intervalMinutes * 60)
        }
        return intervals.min() ?? TimeInterval(config.intervalMinutes * 60)
    }

    private func scheduleNextChange() {
        timer?.invalidate()

        let interval = effectiveCheckInterval()
        guard interval > 0 else { return }

        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.changeWallpaperIfNeeded()
            }
        }
    }

    private func changeWallpaperIfNeeded() {
        let screens = NSScreen.screens
        let now = Date()
        var anyScreenHasItems = false

        for screen in screens {
            let screenID = screen.wallpaperScreenIdentifier
            let displayConfig = config.resolvedDisplayConfig(for: screenID)
            guard displayConfig.isEnabled else { continue }

            let items = getSchedulableItems(for: displayConfig)
            if items.isEmpty {
                print("\(logTag) Screen \(screenID): no schedulable items (wallpapers=\(displayConfig.includeWallpapers), media=\(displayConfig.includeMedia))")
                continue
            }
            anyScreenHasItems = true

            let interval = TimeInterval(displayConfig.intervalMinutes * 60)
            if let lastChange = lastChangeTimes[screenID],
               now.timeIntervalSince(lastChange) < interval - 0.5 {
                // Not yet time for this screen
                print("\(logTag) Screen \(screenID) skipped: \(Int(now.timeIntervalSince(lastChange)))s < \(Int(interval))s")
                continue
            }

            guard let item = selectNextItem(from: items, lastID: lastChangedItemIDs[screenID], order: displayConfig.order) else {
                print("\(logTag) Screen \(screenID): item selection returned nil")
                continue
            }

            print("\(logTag) Applying '\(item.title)' to screen \(screenID)")
            applyItem(item, toScreenID: screenID)
            lastChangeTimes[screenID] = now
            lastChangedItemIDs[screenID] = item.id
        }

        // 所有启用的屏幕都没有可切换项时自动停止，避免空跑
        if !anyScreenHasItems {
            print("\(logTag) No schedulable items on any enabled screen, stopping scheduler.")
            stop()
        }
    }

    // MARK: - Item Application

    private func applyItem(_ item: SchedulableItem, toScreenID screenID: String) {
        let fileURL = item.fileURL

        Task.detached(priority: .utility) { [fileURL] in
            let ext = fileURL.pathExtension.lowercased()
            let isDirectory = (try? FileManager.default
                .attributesOfItem(atPath: fileURL.path)[.type] as? FileAttributeType) == .typeDirectory

            // Detect type on background queue
            let itemType: SchedulableItemType
            if isDirectory || ext == "pkg" {
                let projectJSON = fileURL.appendingPathComponent("project.json")
                if FileManager.default.fileExists(atPath: projectJSON.path) {
                    itemType = .weScene
                } else {
                    itemType = .staticImage
                }
            } else if self.videoExtensions.contains(ext) {
                itemType = .video
            } else {
                itemType = .staticImage
            }

            // Apply on main thread (all wallpaper APIs require MainActor)
            await MainActor.run {
                self.applyItemType(itemType, fileURL: fileURL, screenID: screenID)
            }
        }
    }

    private func applyItemType(_ type: SchedulableItemType, fileURL: URL, screenID: String) {
        guard let screen = NSScreen.screens.first(where: { $0.wallpaperScreenIdentifier == screenID }) else {
            print("\(logTag) Screen \(screenID) not found")
            return
        }

        switch type {
        case .weScene:
            do {
                try WallpaperEngineXBridge.shared.setWallpaper(
                    path: fileURL.path,
                    targetScreens: [screen]
                )
                print("\(logTag) Applied WE scene: \(fileURL.lastPathComponent)")
            } catch {
                print("\(logTag) WE scene error: \(error)")
            }

        case .video:
            VideoWallpaperManager.shared.stopNativeVideoWallpaperOnly(for: screen)
            WallpaperEngineXBridge.shared.ensureStoppedForNonCLIWallpaper()
            do {
                try VideoWallpaperManager.shared.applyVideoWallpaper(
                    from: fileURL,
                    muted: true,
                    targetScreen: screen
                )
                print("\(logTag) Applied video: \(fileURL.lastPathComponent)")
            } catch {
                print("\(logTag) Video error: \(error)")
            }

        case .staticImage:
            VideoWallpaperManager.shared.stopNativeVideoWallpaperOnly(for: screen)
            WallpaperEngineXBridge.shared.ensureStoppedForNonCLIWallpaper()
            do {
                try NSWorkspace.shared.setDesktopImageURLForAllSpaces(fileURL, for: screen)
                DesktopWallpaperSyncManager.shared.registerWallpaperSet(fileURL, for: screen)
                print("\(logTag) Applied static image: \(fileURL.lastPathComponent)")
            } catch {
                print("\(logTag) Static image error: \(error)")
            }
        }
    }

    private let videoExtensions: Set<String> = ["mp4", "mov", "webm", "mkv", "avi", "m4v", "flv"]

    private enum SchedulableItemType {
        case weScene
        case video
        case staticImage
    }

    // MARK: - Item Selection

    /// Lightweight representation of a local item that can be scheduled.
    private struct SchedulableItem: Identifiable {
        let id: String
        let fileURL: URL
        let title: String
    }

    private func selectNextItem(from items: [SchedulableItem], lastID: String?, order: ScheduleOrder) -> SchedulableItem? {
        guard !items.isEmpty else { return nil }

        switch order {
        case .sequential:
            return selectSequential(from: items, lastID: lastID)
        case .random:
            return selectRandom(from: items, lastID: lastID)
        }
    }

    private func getSchedulableItems(for displayConfig: DisplaySchedulerConfig) -> [SchedulableItem] {
        var items: [SchedulableItem] = []

        if displayConfig.includeWallpapers {
            // Downloaded wallpapers（图片或已烘焙的 WE scene 目录）
            for record in WallpaperLibraryService.shared.downloadedWallpapers {
                let url = URL(fileURLWithPath: record.localFilePath)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                items.append(SchedulableItem(
                    id: "wp_dl_\(record.id)",
                    fileURL: url,
                    title: url.deletingPathExtension().lastPathComponent
                ))
            }
            // Scanned local wallpapers
            for item in LocalWallpaperScanner.shared.getLocalWallpapers() {
                guard FileManager.default.fileExists(atPath: item.fileURL.path) else { continue }
                items.append(SchedulableItem(
                    id: "wp_scan_\(item.id)",
                    fileURL: item.fileURL,
                    title: item.title
                ))
            }
        }

        if displayConfig.includeMedia {
            // 自动切换仅支持 mp4/m4v 视频（VideoWallpaperManager 实际只能稳定播放这类格式）
            let allowedMediaExts: Set<String> = ["mp4", "m4v"]

            // Downloaded media
            for record in MediaLibraryService.shared.downloadedItems {
                let url = URL(fileURLWithPath: record.localFilePath)
                guard FileManager.default.fileExists(atPath: url.path),
                      allowedMediaExts.contains(url.pathExtension.lowercased()) else { continue }
                items.append(SchedulableItem(
                    id: "media_dl_\(record.id)",
                    fileURL: url,
                    title: record.item.title
                ))
            }
            // Scanned local media
            for item in LocalWallpaperScanner.shared.getLocalMedia() {
                guard FileManager.default.fileExists(atPath: item.fileURL.path),
                      allowedMediaExts.contains(item.fileURL.pathExtension.lowercased()) else { continue }
                items.append(SchedulableItem(
                    id: "media_scan_\(item.id)",
                    fileURL: item.fileURL,
                    title: item.title
                ))
            }
        }

        return items
    }

    private func selectSequential(from items: [SchedulableItem], lastID: String?) -> SchedulableItem? {
        guard let lastID else { return items.first }
        if let index = items.firstIndex(where: { $0.id == lastID }), index + 1 < items.count {
            return items[index + 1]
        }
        return items.first
    }

    private func selectRandom(from items: [SchedulableItem], lastID: String?) -> SchedulableItem? {
        var available = items
        if let lastID, let index = available.firstIndex(where: { $0.id == lastID }) {
            available.remove(at: index)
        }
        return available.randomElement() ?? items.randomElement()
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
