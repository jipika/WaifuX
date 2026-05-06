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
    private var pendingCleanupWorkItem: DispatchWorkItem?
    private let userDefaultsKey = "wallpaper_scheduler_config"
    private let usedItemIDsKey = "wallpaper_scheduler_used_item_ids_v1"
    private let lastChangeTimesKey = "wallpaper_scheduler_last_change_times_v1"
    private let lastChangedItemIDsKey = "wallpaper_scheduler_last_changed_item_ids_v1"
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
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

    @objc private func handleScreenParametersChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // 防抖：延迟 0.5s 执行
            self.pendingCleanupWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.cleanupOrphanedScreenState()
                if self.isRunning {
                    self.scheduleNextChange()
                }
            }
            self.pendingCleanupWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
        }
    }

    private func cleanupOrphanedScreenState() {
        let currentScreenIDs = Set(NSScreen.screens.map { $0.wallpaperScreenIdentifier })

        // 清理 lastChangedItemIDs
        let orphanedChangedItemIDs = Set(lastChangedItemIDs.keys).subtracting(currentScreenIDs)
        for screenID in orphanedChangedItemIDs {
            lastChangedItemIDs.removeValue(forKey: screenID)
        }

        // 清理 lastChangeTimes
        let orphanedChangeTimes = Set(lastChangeTimes.keys).subtracting(currentScreenIDs)
        for screenID in orphanedChangeTimes {
            lastChangeTimes.removeValue(forKey: screenID)
        }

        // 清理 usedItemIDs
        let orphanedUsedItemIDs = Set(usedItemIDs.keys).subtracting(currentScreenIDs)
        for screenID in orphanedUsedItemIDs {
            usedItemIDs.removeValue(forKey: screenID)
        }

        // 清理 displayConfigs
        let orphanedDisplayConfigs = Set(config.displayConfigs.keys).subtracting(currentScreenIDs)
        for screenID in orphanedDisplayConfigs {
            config.displayConfigs.removeValue(forKey: screenID)
        }

        // 持久化清理后的状态
        if !orphanedChangedItemIDs.isEmpty || !orphanedChangeTimes.isEmpty || !orphanedUsedItemIDs.isEmpty {
            persistSchedulerState()
            saveConfig()
            let allOrphaned = orphanedChangedItemIDs.union(orphanedChangeTimes).union(orphanedUsedItemIDs)
            print("\(logTag) Cleaned up orphaned state for \(allOrphaned.count) disconnected screen(s): \(allOrphaned)")
        }
    }

    /// 延迟恢复保存的调度配置与运行状态
    func restoreSavedConfig() {
        loadConfig()
        restoreSchedulerState()
    }

    /// 恢复随机一轮状态与上次切换时间，确保应用重启后随机不重复、间隔不立即触发
    private func restoreSchedulerState() {
        if let data = UserDefaults.standard.data(forKey: usedItemIDsKey),
           let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) {
            usedItemIDs = decoded.mapValues { Set($0) }
        }
        if let data = UserDefaults.standard.data(forKey: lastChangeTimesKey),
           let decoded = try? PropertyListDecoder().decode([String: Date].self, from: data) {
            lastChangeTimes = decoded
        }
        if let data = UserDefaults.standard.data(forKey: lastChangedItemIDsKey),
           let decoded = try? PropertyListDecoder().decode([String: String].self, from: data) {
            lastChangedItemIDs = decoded
        }
    }

    private func persistSchedulerState() {
        let encodableUsed = usedItemIDs.mapValues { Array($0) }
        if let data = try? JSONEncoder().encode(encodableUsed) {
            UserDefaults.standard.set(data, forKey: usedItemIDsKey)
        }
        if let data = try? PropertyListEncoder().encode(lastChangeTimes) {
            UserDefaults.standard.set(data, forKey: lastChangeTimesKey)
        }
        if let data = try? PropertyListEncoder().encode(lastChangedItemIDs) {
            UserDefaults.standard.set(data, forKey: lastChangedItemIDsKey)
        }
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
        // 停止时保留持久化状态，以便重新启用时继续上轮随机进度
        persistSchedulerState()
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
        persistSchedulerState()
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
                    self.persistSchedulerState()
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
                // 注：CLI 壁纸由 daemon 自身管理桌面 capture，不注册到 DesktopWallpaperSyncManager
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
                   let projectJSON = try? JSONSerialization.jsonObject(with: projectData) as? [String: Any] {

                    // Preset 类型（图片轮播）：project.json 含 "preset" 字段且无 "type" 字段
                    if projectJSON["type"] == nil,
                       let presetDict = projectJSON["preset"] as? [String: Any],
                       let customDir = presetDict["customdirectory"] as? String {
                        let imagesDir = resolvedRoot.appendingPathComponent(customDir)
                        let images = enumerateImages(in: imagesDir)
                        if !images.isEmpty {
                            // 根据 preset 配置生成 HTML 轮播页面
                            // imageswitchtimes 是倍率（1=默认），使用 5 秒基础间隔
                            let multiplier = presetDict["imageswitchtimes"] as? Int ?? 1
                            let switchTime = max(multiplier * 5, 3)
                            let transitionMode = presetDict["TransitionMode"] as? Int ?? 1
                            generatePresetHTML(
                                images: images, imagesDir: imagesDir,
                                switchTime: switchTime, transitionMode: transitionMode,
                                outputDir: resolvedRoot
                            )
                            print("\(logTag) Generated preset HTML slideshow: \(images.count) images, interval=\(switchTime)s")
                            // 通过 CLI web 渲染器渲染
                            try WallpaperEngineXBridge.shared.setWallpaper(
                                path: resolvedRoot.path,
                                targetScreens: [screen]
                            )
                            // 注：CLI 壁纸由 daemon 自身管理桌面 capture，不注册到 DesktopWallpaperSyncManager
                            return true
                        }
                    }

                    let typeString = projectJSON["type"] as? String
                    let type = typeString?.lowercased() ?? ""

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
                            // 注：CLI 壁纸由 daemon 自身管理桌面 capture，不注册到 DesktopWallpaperSyncManager
                        }
                    } else {
                        // Scene/Web 类型：通过 CLI 渲染
                        print("\(logTag) Using CLI renderer for WE \(type): \(resolvedRoot.path)")
                        try WallpaperEngineXBridge.shared.setWallpaper(
                            path: resolvedRoot.path,
                            targetScreens: [screen]
                        )
                        // 注：CLI 壁纸由 daemon 自身管理桌面 capture，不注册到 DesktopWallpaperSyncManager
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
            // com.apple.desktop 通知已由 setDesktopImageURLForAllSpaces 内部发送，无需重复触发
            return true
        } catch {
            print("\(logTag) applyItem failed for '\(item.title)' (\(fileURL.lastPathComponent)): \(error)")
            return false
        }
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
    private let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "bmp", "gif", "webp", "tga", "tif", "tiff"]

    /// 枚举目录中的图片文件，按文件名排序
    private func enumerateImages(in directory: URL) -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        return contents
            .filter { imageExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// 根据 preset 配置生成 HTML 图片轮播页面，写入 outputDir/index.html
    private func generatePresetHTML(images: [URL], imagesDir: URL, switchTime: Int, transitionMode: Int, outputDir: URL) {
        // 图片路径相对于 outputDir
        let imagePaths = images.map { url -> String in
            let absPath = url.path
            let dirPath = outputDir.path.hasSuffix("/") ? outputDir.path : outputDir.path + "/"
            if absPath.hasPrefix(dirPath) {
                return String(absPath.dropFirst(dirPath.count))
            }
            return url.lastPathComponent
        }

        let escapedPaths = imagePaths.map { path -> String in
            let escaped = path.replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
        let imagesJS = "[\(escapedPaths.joined(separator: ","))]"

        // 过渡动画 CSS
        let transitionCSS: String
        switch transitionMode {
        case 1: // 淡入淡出
            transitionCSS = """
            .slide { opacity: 0; transition: opacity 1.2s ease-in-out; }
            .slide.active { opacity: 1; }
            """
        case 2: // 左右滑动
            transitionCSS = """
            .slide { position: absolute; top: 0; left: 100%; transition: left 1.2s ease-in-out; width: 100%; height: 100%; }
            .slide.active { left: 0; }
            .slide.prev { left: -100%; }
            """
        default: // 淡入淡出（默认）
            transitionCSS = """
            .slide { opacity: 0; transition: opacity 1.2s ease-in-out; }
            .slide.active { opacity: 1; }
            """
        }

        let html = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        html, body { width: 100%; height: 100%; overflow: hidden; background: #000; }
        .slideshow { position: relative; width: 100%; height: 100%; }
        .slide {
            position: absolute; top: 0; left: 0; width: 100%; height: 100%;
            background-size: cover; background-position: center; background-repeat: no-repeat;
        }
        \(transitionCSS)
        </style>
        </head>
        <body>
        <div class="slideshow" id="slideshow"></div>
        <script>
        const images = \(imagesJS);
        const switchTime = \(max(switchTime, 1)) * 1000;
        const container = document.getElementById('slideshow');
        let current = 0;

        // 创建所有 slide 元素
        images.forEach((src, i) => {
            const div = document.createElement('div');
            div.className = 'slide' + (i === 0 ? ' active' : '');
            div.style.backgroundImage = 'url("' + src + '")';
            container.appendChild(div);
        });

        const slides = container.querySelectorAll('.slide');

        function nextSlide() {
            slides[current].classList.remove('active');
            if (slides[current].classList) slides[current].classList.add('prev');
            current = (current + 1) % slides.length;
            slides[current].classList.remove('prev');
            slides[current].classList.add('active');
            // 清理 prev 类
            setTimeout(() => {
                slides.forEach((s, i) => { if (i !== current) s.classList.remove('prev'); });
            }, 1300);
        }

        setInterval(nextSlide, switchTime);
        </script>
        </body>
        </html>
        """

        let htmlURL = outputDir.appendingPathComponent("index.html")
        try? html.write(to: htmlURL, atomically: true, encoding: .utf8)
    }

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
        persistSchedulerState()
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


