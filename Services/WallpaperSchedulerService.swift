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
    /// Tracks already-used item IDs per screen in the current random round to avoid duplicates within a full cycle.
    private var usedItemIDs: [String: Set<String>] = [:]

    private var timer: Timer?
    private let userDefaultsKey = "wallpaper_scheduler_config"
    private let logTag = "[WallpaperScheduler]"
    private var isScreenLocked = false

    private init() {
        DistributedNotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenLocked),
            name: Notification.Name("com.apple.screenIsLocked"),
            object: nil
        )
        DistributedNotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenUnlocked),
            name: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil
        )
    }

    @objc private func handleScreenLocked() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isScreenLocked = true
            self.timer?.invalidate()
            self.timer = nil
            print("\(self.logTag) Screen locked, pausing scheduler")
        }
    }

    @objc private func handleScreenUnlocked() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isScreenLocked = false
            if self.isRunning {
                self.scheduleNextChange()
                print("\(self.logTag) Screen unlocked, resuming scheduler")
            }
        }
    }

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

    /// 手动设置壁纸后调用：重置该屏幕的调度计时器，避免刚设置完就被自动切换覆盖。
    /// - Parameter screenID: 被手动设置壁纸的屏幕标识符；nil 表示重置所有屏幕。
    func notifyManualWallpaperChange(screenID: String? = nil) {
        let now = Date()
        if let screenID = screenID {
            lastChangeTimes[screenID] = now
        } else {
            for screen in NSScreen.screens {
                lastChangeTimes[screen.wallpaperScreenIdentifier] = now
            }
        }
        // 重启定时器以确保从现在开始重新计时
        if isRunning {
            scheduleNextChange()
        }
        print("\(logTag) Manual wallpaper change notified, timer reset")
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
        guard !isScreenLocked else { return }
        let screens = NSScreen.screens
        let now = Date()

        for screen in screens {
            let screenID = screen.wallpaperScreenIdentifier
            let displayConfig = config.resolvedDisplayConfig(for: screenID)
            guard displayConfig.isEnabled else { continue }

            let items = getSchedulableItems(for: displayConfig)
            if items.isEmpty {
                print("\(logTag) Screen \(screenID): no schedulable items (wallpapers=\(displayConfig.includeWallpapers), media=\(displayConfig.includeMedia))")
                continue
            }

            let interval = TimeInterval(displayConfig.intervalMinutes * 60)
            if let lastChange = lastChangeTimes[screenID],
               now.timeIntervalSince(lastChange) < interval - 0.5 {
                print("\(logTag) Screen \(screenID) skipped: \(Int(now.timeIntervalSince(lastChange)))s < \(Int(interval))s")
                continue
            }

            guard let item = selectNextItem(from: items, lastID: lastChangedItemIDs[screenID], screenID: screenID, order: displayConfig.order) else {
                print("\(logTag) Screen \(screenID): item selection returned nil")
                continue
            }

            let bakeStatus: String
            if item.bakedWebDirPath != nil { bakeStatus = "web-dir" }
            else if item.bakedVideoPath != nil { bakeStatus = "mp4" }
            else { bakeStatus = "none" }
            print("\(logTag) Applying '\(item.title)' to screen \(screenID) [bake=\(bakeStatus)]")
            Task { @MainActor in
                let success = await applyItem(item, toScreenID: screenID)
                if success {
                    self.lastChangeTimes[screenID] = now
                    self.lastChangedItemIDs[screenID] = item.id
                    print("\(logTag) Successfully applied '\(item.title)' to screen \(screenID)")
                } else {
                    print("\(logTag) Failed to apply '\(item.title)' to screen \(screenID), will retry next cycle")
                }
            }
        }
    }

    // MARK: - Item Application

    private func applyItem(_ item: SchedulableItem, toScreenID screenID: String) async -> Bool {
        guard let screen = NSScreen.screens.first(where: { $0.wallpaperScreenIdentifier == screenID }) else {
            return false
        }

        let fileURL = item.fileURL
        let ext = fileURL.pathExtension.lowercased()
        let isDirectory = (try? FileManager.default
            .attributesOfItem(atPath: fileURL.path)[.type] as? FileAttributeType) == .typeDirectory

        do {
            // 优先使用烘焙产物（WE Scene 离线烘焙）
            // 1a. .web 组合目录（视频背景 + Web overlay）→ 通过 CLI 渲染
            if let webDirPath = item.bakedWebDirPath,
               FileManager.default.fileExists(atPath: webDirPath) {
                print("\(logTag) Using baked .web dir: \(webDirPath)")
                try WallpaperEngineXBridge.shared.setWallpaper(
                    path: webDirPath,
                    targetScreens: [screen]
                )
                let cliCaptureURL = URL(fileURLWithPath: "/tmp/wallpaperengine-cli-capture.png")
                DesktopWallpaperSyncManager.shared.registerWallpaperSet(cliCaptureURL, for: screen)
            }
            // 1b. .mp4 烘焙视频 → VideoWallpaperManager 直接播放
            else if let bakedPath = item.bakedVideoPath,
               FileManager.default.fileExists(atPath: bakedPath) {
                print("\(logTag) Using baked video: \(bakedPath)")
                let bakedURL = URL(fileURLWithPath: bakedPath)
                let posterURL = await VideoThumbnailCache.shared.lockScreenPosterURL(
                    forLocalVideo: bakedURL,
                    fallbackPosterURL: nil
                )
                try VideoWallpaperManager.shared.applyVideoWallpaper(
                    from: bakedURL,
                    posterURL: posterURL,
                    muted: true,
                    targetScreen: screen
                )
                if let posterURL = posterURL {
                    DesktopWallpaperSyncManager.shared.registerWallpaperSet(posterURL, for: screen)
                }
            } else if isDirectory || ext == "pkg" {
                // 2. Workshop 目录 → 根据 project.json 类型分发
                let resolvedRoot = WorkshopService.resolveWallpaperEngineProjectRoot(startingAt: fileURL)
                let projectJSONPath = resolvedRoot.appendingPathComponent("project.json")

                if FileManager.default.fileExists(atPath: projectJSONPath.path),
                   let projectData = try? Data(contentsOf: projectJSONPath),
                   let projectJSON = try? JSONSerialization.jsonObject(with: projectData) as? [String: Any],
                   let typeString = projectJSON["type"] as? String {
                    let type = typeString.lowercased()

                    if type == "video" {
                        // Video 类型：提取实际视频文件路径，用 VideoWallpaperManager 播放
                        if let videoURL = findVideoFileInProject(projectJSON: projectJSON, root: resolvedRoot) {
                            print("\(logTag) Using video from WE project: \(videoURL.lastPathComponent)")
                            let posterURL = await VideoThumbnailCache.shared.lockScreenPosterURL(
                                forLocalVideo: videoURL,
                                fallbackPosterURL: nil
                            )
                            try VideoWallpaperManager.shared.applyVideoWallpaper(
                                from: videoURL,
                                posterURL: posterURL,
                                muted: true,
                                targetScreen: screen
                            )
                            if let posterURL = posterURL {
                                DesktopWallpaperSyncManager.shared.registerWallpaperSet(posterURL, for: screen)
                            }
                        } else {
                            print("\(logTag) Video type but no video file found in project, falling back to CLI")
                            try WallpaperEngineXBridge.shared.setWallpaper(
                                path: resolvedRoot.path,
                                targetScreens: [screen]
                            )
                            let cliCaptureURL = URL(fileURLWithPath: "/tmp/wallpaperengine-cli-capture.png")
                            DesktopWallpaperSyncManager.shared.registerWallpaperSet(cliCaptureURL, for: screen)
                        }
                    } else {
                        // Scene/Web 类型：通过 CLI 渲染
                        print("\(logTag) Using CLI renderer for WE \(type): \(resolvedRoot.path)")
                        try WallpaperEngineXBridge.shared.setWallpaper(
                            path: resolvedRoot.path,
                            targetScreens: [screen]
                        )
                        let cliCaptureURL = URL(fileURLWithPath: "/tmp/wallpaperengine-cli-capture.png")
                        DesktopWallpaperSyncManager.shared.registerWallpaperSet(cliCaptureURL, for: screen)
                    }
                } else {
                    // 无 project.json 的静态图目录
                    print("\(logTag) Using static image from directory: \(fileURL.path)")
                    let vm = WallpaperViewModel()
                    try await vm.setWallpaper(from: fileURL, option: .desktop, for: screen)
                }
            } else if videoExtensions.contains(ext) {
                // 3. 视频文件 → VideoWallpaperManager
                print("\(logTag) Using video wallpaper: \(fileURL.lastPathComponent)")
                let posterURL = await VideoThumbnailCache.shared.lockScreenPosterURL(
                    forLocalVideo: fileURL,
                    fallbackPosterURL: nil
                )
                try VideoWallpaperManager.shared.applyVideoWallpaper(
                    from: fileURL,
                    posterURL: posterURL,
                    muted: true,
                    targetScreen: screen
                )
                if let posterURL = posterURL {
                    DesktopWallpaperSyncManager.shared.registerWallpaperSet(posterURL, for: screen)
                }
            } else {
                // 4. 静态图 → WallpaperViewModel
                print("\(logTag) Using static image: \(fileURL.lastPathComponent)")
                let vm = WallpaperViewModel()
                try await vm.setWallpaper(from: fileURL, option: .desktop, for: screen)
            }
            triggerSystemMenuBarRefresh()
            return true
        } catch {
            print("\(logTag) applyItem failed for '\(item.title)' (\(fileURL.lastPathComponent)): \(error)")
            return false
        }
    }

    private func triggerSystemMenuBarRefresh() {
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("com.apple.desktop"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    /// 从 project.json 的 file/background 字段提取视频文件路径
    private func findVideoFileInProject(projectJSON: [String: Any], root: URL) -> URL? {
        let fm = FileManager.default
        let videoExts: Set<String> = ["mp4", "mov", "webm", "m4v"]

        // 1. 优先读 project.json 中明确的 file/background 字段
        for key in ["file", "background"] {
            if let path = projectJSON[key] as? String {
                let candidate = root.appendingPathComponent(path)
                if videoExts.contains(candidate.pathExtension.lowercased()),
                   fm.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
        }

        // 2. 递归查找目录中的视频文件
        if let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let fileURL as URL in enumerator {
                if videoExts.contains(fileURL.pathExtension.lowercased()) {
                    return fileURL
                }
            }
        }
        return nil
    }

    private let videoExtensions: Set<String> = ["mp4", "mov", "webm", "mkv", "avi", "m4v", "flv"]

    // MARK: - Item Selection

    /// Lightweight representation of a local item that can be scheduled.
    private struct SchedulableItem: Identifiable {
        let id: String
        let fileURL: URL
        let title: String
        /// 已烘焙的 scene MP4 路径（优先于原始 WE Scene 目录）
        let bakedVideoPath: String?
        /// 已烘焙的 .web 组合目录路径（视频背景 + Web overlay，优先于纯 MP4）
        let bakedWebDirPath: String?
    }

    private func selectNextItem(from items: [SchedulableItem], lastID: String?, screenID: String, order: ScheduleOrder) -> SchedulableItem? {
        guard !items.isEmpty else { return nil }

        switch order {
        case .sequential:
            return selectSequential(from: items, lastID: lastID)
        case .random:
            return selectRandom(from: items, lastID: lastID, screenID: screenID)
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
                    title: url.deletingPathExtension().lastPathComponent,
                    bakedVideoPath: nil,
                    bakedWebDirPath: nil
                ))
            }
            // Scanned local wallpapers
            for item in LocalWallpaperScanner.shared.getLocalWallpapers() {
                guard FileManager.default.fileExists(atPath: item.fileURL.path) else { continue }
                items.append(SchedulableItem(
                    id: "wp_scan_\(item.id)",
                    fileURL: item.fileURL,
                    title: item.title,
                    bakedVideoPath: nil,
                    bakedWebDirPath: nil
                ))
            }
            // Workshop 下载的壁纸引擎内容（记录在 MediaLibraryService 中）
            for record in MediaLibraryService.shared.downloadedItems where record.item.id.hasPrefix("workshop_") {
                let url = URL(fileURLWithPath: record.localFilePath)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                let isDirectory = (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeDirectory
                let isVideo = ["mp4", "m4v"].contains(url.pathExtension.lowercased())
                // WE scene 目录 或 烘焙视频 均可作为壁纸
                guard isDirectory || isVideo else { continue }
                // 优先使用烘焙产物：.web 组合目录 > .mp4 视频
                var bakedVideoPath: String? = nil
                var bakedWebDirPath: String? = nil
                if let art = record.sceneBakeArtifact {
                    let webDir = art.videoPath.replacingOccurrences(of: ".mp4", with: ".web")
                    if FileManager.default.fileExists(atPath: webDir) {
                        bakedWebDirPath = webDir
                    }
                    if FileManager.default.fileExists(atPath: art.videoPath) {
                        bakedVideoPath = art.videoPath
                    }
                }
                items.append(SchedulableItem(
                    id: "media_dl_\(record.id)",
                    fileURL: url,
                    title: record.item.title,
                    bakedVideoPath: bakedVideoPath,
                    bakedWebDirPath: bakedWebDirPath
                ))
            }
        }

        if displayConfig.includeMedia {
            // 自动切换仅支持 mp4/m4v 视频（VideoWallpaperManager 实际只能稳定播放这类格式）
            let allowedMediaExts: Set<String> = ["mp4", "m4v"]

            // 已在 wallpapers 分支添加过的 Workshop 项 ID，避免重复
            let existingIDs = Set(items.map(\.id))

            // Downloaded media（包含 Workshop 视频/媒体）
            for record in MediaLibraryService.shared.downloadedItems {
                let url = URL(fileURLWithPath: record.localFilePath)
                let isWorkshop = record.item.id.hasPrefix("workshop_")
                let isAllowedExt = allowedMediaExts.contains(url.pathExtension.lowercased())
                let isDirectory = (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeDirectory
                guard FileManager.default.fileExists(atPath: url.path),
                      (isWorkshop || isAllowedExt || isDirectory) else { continue }
                // Workshop 项已在 wallpapers 分支处理过（含烘焙视频路径），跳过避免重复
                let itemID = "media_dl_\(record.id)"
                if isWorkshop && displayConfig.includeWallpapers && existingIDs.contains(itemID) {
                    continue
                }
                items.append(SchedulableItem(
                    id: itemID,
                    fileURL: url,
                    title: record.item.title,
                    bakedVideoPath: nil,
                    bakedWebDirPath: nil
                ))
            }
            // Scanned local media
            for item in LocalWallpaperScanner.shared.getLocalMedia() {
                guard FileManager.default.fileExists(atPath: item.fileURL.path),
                      allowedMediaExts.contains(item.fileURL.pathExtension.lowercased()) else { continue }
                items.append(SchedulableItem(
                    id: "media_scan_\(item.id)",
                    fileURL: item.fileURL,
                    title: item.title,
                    bakedVideoPath: nil,
                    bakedWebDirPath: nil
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

    private func selectRandom(from items: [SchedulableItem], lastID: String?, screenID: String) -> SchedulableItem? {
        guard !items.isEmpty else { return nil }

        var used = usedItemIDs[screenID] ?? Set()
        var candidates = items.filter { !used.contains($0.id) }

        // 如果全部都用过了，重置本轮记录重新开始
        if candidates.isEmpty {
            used.removeAll()
            candidates = items
        }

        // 尽量避免连续重复（如果上一轮最后一个还在候选里，优先排除）
        if let lastID,
           candidates.count > 1,
           let lastIndex = candidates.firstIndex(where: { $0.id == lastID }) {
            candidates.remove(at: lastIndex)
        }

        guard let selected = candidates.randomElement() else { return nil }
        used.insert(selected.id)
        usedItemIDs[screenID] = used
        return selected
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


