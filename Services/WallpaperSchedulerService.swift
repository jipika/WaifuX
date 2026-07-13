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

    private var dispatchTimer: DispatchSourceTimer?
    private var pendingCleanupWorkItem: DispatchWorkItem?
    private let userDefaultsKey = "wallpaper_scheduler_config"
    private let usedItemIDsKey = "wallpaper_scheduler_used_item_ids_v1"
    private let lastChangeTimesKey = "wallpaper_scheduler_last_change_times_v1"
    private let lastChangedItemIDsKey = "wallpaper_scheduler_last_changed_item_ids_v1"
    private let displayFingerprintsKey = "wallpaper_scheduler_display_fingerprints_v1"
    private let logTag = "[WallpaperScheduler]"
    private var isScreenLocked = false
    private var lastUnlockSwitchTime: Date?
    private var isApplyingSynchronizedItem = false
    private var isRebuildingDisplaySync = false
    private var independentWallpaperSources: [String: ActiveWallpaperSource] = [:]

    private enum ActiveWallpaperSource {
        case video(URL, posterURL: URL?)
        case engine(path: String, userProperties: String?, isWeb: Bool)
        case image(URL)
    }

    /// Persists screenID → fingerprint mapping so that display configs can be
    /// relinked after sleep/wake when CGDirectDisplayID may change on external monitors.
    private var displayFingerprints: [String: String] = [:]

    /// 视频播放完成通知（用于"播完即换"模式）
    static let videoPlaybackEndedNotification = Notification.Name("com.waifux.scheduler.videoPlaybackEnded")

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
        // 监听视频播放完成通知（用于"播完即换"模式）
        DistributedNotificationCenter.default.addObserver(
            self,
            selector: #selector(handleVideoPlaybackEnded(_:)),
            name: Self.videoPlaybackEndedNotification,
            object: nil
        )
    }

    @objc private func handleVideoPlaybackEnded(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let screenID = userInfo["screenID"] as? String else {
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.triggerNextWallpaper(for: screenID)
        }
    }

    /// 为指定屏幕触发下一次壁纸更换（用于"播完即换"模式）
    private func triggerNextWallpaper(for screenID: String) {
        guard isRunning else { return }
        applyNextWallpaper(
            for: canonicalDisplayConfigScreenID(for: screenID),
            requiredMode: .onEnd
        )
    }

    /// 手动为指定屏幕切换下一张壁纸。即使该屏幕暂时关闭自动切换，也允许使用
    /// 已保存的轮换范围、顺序和文件夹过滤来选取下一张。
    func triggerNextWallpaperNow(for screenID: String) {
        applyNextWallpaper(for: canonicalDisplayConfigScreenID(for: screenID), requiredMode: nil)
    }

    func triggerRandomWallpaperNow(for screenID: String) {
        applyNextWallpaper(
            for: canonicalDisplayConfigScreenID(for: screenID),
            requiredMode: nil,
            overrideOrder: .random
        )
    }

    func hasSchedulableItems(for screenID: String) -> Bool {
        let resolvedScreenID = canonicalDisplayConfigScreenID(for: screenID)
        let displayConfig = resolvedScopedDisplayConfig(for: resolvedScreenID)
        return !getSchedulableItems(for: displayConfig, screenID: resolvedScreenID).isEmpty
    }

    func resolvedDisplayConfig(for screen: NSScreen) -> DisplaySchedulerConfig {
        if config.syncAllDisplays {
            return config.resolvedGlobalDisplayConfig()
        }

        let screenID = screen.wallpaperScreenIdentifier
        if let displayConfig = config.displayConfigs[screenID] {
            return displayConfig
        }

        if let oldScreenID = existingConfigScreenID(for: screen),
           let displayConfig = config.displayConfigs[oldScreenID] {
            return displayConfig
        }

        return config.resolvedDisplayConfig(for: screenID)
    }

    /// Scheduler controls shown while display sync is enabled edit the dedicated
    /// global record. Independent display preferences stay untouched for later.
    private func resolvedScopedDisplayConfig(for screenID: String) -> DisplaySchedulerConfig {
        config.syncAllDisplays
            ? config.resolvedGlobalDisplayConfig()
            : config.resolvedDisplayConfig(for: screenID)
    }

    private func storeScopedDisplayConfig(
        _ displayConfig: DisplaySchedulerConfig,
        for screenID: String,
        in schedulerConfig: inout SchedulerConfig
    ) {
        if schedulerConfig.syncAllDisplays {
            schedulerConfig.globalDisplayConfig = displayConfig
        } else {
            schedulerConfig.displayConfigs[screenID] = displayConfig
        }
    }

    func displayConfigScreenID(for screen: NSScreen) -> String {
        if let existingScreenID = existingConfigScreenID(for: screen),
           config.displayConfigs[existingScreenID] != nil {
            migrateDisplayConfig(from: existingScreenID, to: screen)
        }
        let screenID = screen.wallpaperScreenIdentifier
        let fingerprint = screen.schedulerConfigFingerprint
        if displayFingerprints[screenID] != fingerprint {
            displayFingerprints[screenID] = fingerprint
            saveDisplayFingerprints()
        }
        return screenID
    }

    /// 将调用方持有的临时 screen ID 对齐到当前物理显示器的配置记录。
    /// 外接屏重连后，菜单栏和设置页都可能仍持有旧 ID；必须先迁移再读写。
    private func canonicalDisplayConfigScreenID(for screenID: String) -> String {
        guard let screen = NSScreen.screens.first(where: {
            $0.wallpaperScreenIdentifier == screenID
        }) else {
            return screenID
        }
        return displayConfigScreenID(for: screen)
    }

    func relinkDisplayConfigsForCurrentScreens() {
        let previousFingerprints = displayFingerprints
        relinkDisplayConfigsByFingerprint()
        relinkSchedulerStateByFingerprint(using: previousFingerprints)
    }

    private enum RequiredSwitchMode {
        case onEnd
    }

    private func applyNextWallpaper(
        for screenID: String,
        requiredMode: RequiredSwitchMode?,
        overrideOrder: ScheduleOrder? = nil
    ) {
        guard !isScreenLocked, !isRebuildingDisplaySync else { return }
        if config.syncAllDisplays,
           let primaryScreenID = NSScreen.screens.first?.wallpaperScreenIdentifier,
           screenID != primaryScreenID {
            applyNextWallpaper(for: primaryScreenID, requiredMode: requiredMode, overrideOrder: overrideOrder)
            return
        }
        guard let screen = NSScreen.screens.first(where: {
            $0.wallpaperScreenIdentifier == screenID
        }) else {
            return
        }
        let displayConfig = resolvedDisplayConfig(for: screen)
        switch requiredMode {
        case .onEnd:
            guard displayConfig.isEnabled && displayConfig.isOnEndMode else { return }
        case nil:
            break
        }

        let items = getSchedulableItems(for: displayConfig, screenID: screenID)
        guard !items.isEmpty else {
            print("\(logTag) Screen \(screenID): no schedulable items for next-wallpaper request")
            recoverCurrentVideoAfterFailedOnEndSwitch(for: screenID, requiredMode: requiredMode)
            return
        }

        let now = Date()
        let lastChangedItemID = lastChangedItemIDs[screenID]

        let order = overrideOrder ?? displayConfig.order
        guard let item = selectNextItem(from: items, lastID: lastChangedItemID, screenID: screenID, order: order) else {
            print("\(logTag) Screen \(screenID): item selection returned nil for on-end mode")
            recoverCurrentVideoAfterFailedOnEndSwitch(for: screenID, requiredMode: requiredMode)
            return
        }

        if config.syncAllDisplays {
            Task { @MainActor in
                _ = await self.applySynchronizedItem(item, at: now)
            }
            return
        }

        Task { @MainActor in
            let success = await applyItem(item, toScreenID: screenID)
            if success {
                self.lastChangeTimes[screenID] = now
                self.lastChangedItemIDs[screenID] = item.id
                self.persistSchedulerState()
                print("\(logTag) Applied next wallpaper '\(item.title)' to screen \(screenID)")
            } else {
                print("\(logTag) Failed to apply next wallpaper '\(item.title)' to screen \(screenID), trying next item")
                // 尝试其他可用项，避免因选中不支持的壁纸类型导致黑屏
                var remaining = items.filter { $0.id != item.id }
                while !remaining.isEmpty {
                    guard let retryItem = selectNextItem(from: remaining, lastID: lastChangedItemID, screenID: screenID, order: order) else { break }
                    remaining.removeAll { $0.id == retryItem.id }
                    let retrySuccess = await applyItem(retryItem, toScreenID: screenID)
                    if retrySuccess {
                        self.lastChangeTimes[screenID] = now
                        self.lastChangedItemIDs[screenID] = retryItem.id
                        self.persistSchedulerState()
                        print("\(logTag) Retry applied next wallpaper '\(retryItem.title)' to screen \(screenID)")
                        return
                    }
                    print("\(logTag) Retry failed for next wallpaper '\(retryItem.title)', trying next")
                }
                print("\(logTag) All next-wallpaper candidates exhausted for screen \(screenID), no wallpaper applied")
                self.recoverCurrentVideoAfterFailedOnEndSwitch(for: screenID, requiredMode: requiredMode)
            }
        }
    }

    /// An on-end rotation has already paused the current video. If no candidate can
    /// replace it, start that player again instead of leaving its window black.
    private func recoverCurrentVideoAfterFailedOnEndSwitch(
        for screenID: String,
        requiredMode: RequiredSwitchMode?
    ) {
        guard case .onEnd? = requiredMode,
              let screen = NSScreen.screens.first(where: { $0.wallpaperScreenIdentifier == screenID }) else {
            return
        }

        print("\(logTag) Restoring current video after failed on-end switch for screen \(screenID)")
        VideoWallpaperManager.shared.resumeOnEndVideoAfterFailedSwitch(for: screen)
    }

    @objc private func handleScreenLocked() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isScreenLocked = true
            self.dispatchTimer?.cancel()
            self.dispatchTimer = nil
            print("\(self.logTag) Screen locked, pausing scheduler")
        }
    }

    @objc private func handleScreenUnlocked() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isScreenLocked = false
            self.changeUnlockWallpapersIfNeeded()
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
                let previousFingerprints = self.displayFingerprints
                self.relinkDisplayConfigsByFingerprint()
                self.relinkSchedulerStateByFingerprint(using: previousFingerprints)
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

        // 持久化清理后的状态
        if !orphanedChangedItemIDs.isEmpty || !orphanedChangeTimes.isEmpty || !orphanedUsedItemIDs.isEmpty {
            persistSchedulerState()
            saveConfig()
            let allOrphaned = orphanedChangedItemIDs.union(orphanedChangeTimes).union(orphanedUsedItemIDs)
            print("\(logTag) Cleaned up orphaned state for \(allOrphaned.count) disconnected screen(s): \(allOrphaned)")
        }
    }

    /// Re-maps display configs whose screen ID changed (e.g. after sleep/wake when
    /// CGDirectDisplayID may change on external monitors) using the stable fingerprint.
    private func relinkDisplayConfigsByFingerprint() {
        let currentScreens = NSScreen.screens
        let currentScreenIDs = Set(currentScreens.map { $0.wallpaperScreenIdentifier })

        // Find orphaned config keys — screen IDs that were in displayConfigs but are no longer present
        let orphanedIDs = Set(config.displayConfigs.keys).subtracting(currentScreenIDs)
        guard !orphanedIDs.isEmpty else { return }

        // Build fingerprint → current screenID map
        var fingerprintToScreenID: [String: String] = [:]
        for screen in currentScreens {
            fingerprintToScreenID[screen.schedulerConfigFingerprint] = screen.wallpaperScreenIdentifier
            fingerprintToScreenID[screen.wallpaperScreenFingerprint] = screen.wallpaperScreenIdentifier
        }

        var migratedCount = 0
        for orphanedID in orphanedIDs {
            guard let fingerprint = displayFingerprints[orphanedID],
                  let newScreenID = fingerprintToScreenID[fingerprint],
                  !config.displayConfigs.keys.contains(newScreenID) else { continue }

            if let orphanedConfig = config.displayConfigs[orphanedID] {
                config.displayConfigs[newScreenID] = orphanedConfig
                displayFingerprints[newScreenID] = fingerprint
                migratedCount += 1
            }
            displayFingerprints.removeValue(forKey: orphanedID)
            config.displayConfigs.removeValue(forKey: orphanedID)
        }

        if migratedCount > 0 {
            saveConfig()
            saveDisplayFingerprints()
            print("\(logTag) Relinked \(migratedCount) display config(s) by fingerprint after screen change")
        }
    }

    private func existingConfigScreenID(for screen: NSScreen) -> String? {
        let currentID = screen.wallpaperScreenIdentifier
        if config.displayConfigs[currentID] != nil {
            return currentID
        }

        let fingerprints = Set([
            screen.schedulerConfigFingerprint,
            screen.wallpaperScreenFingerprint,
        ])
        return displayFingerprints.first { _, fingerprint in
            fingerprints.contains(fingerprint)
        }?.key
    }

    private func migrateDisplayConfig(from oldScreenID: String, to screen: NSScreen) {
        let newScreenID = screen.wallpaperScreenIdentifier
        guard oldScreenID != newScreenID,
              let oldConfig = config.displayConfigs[oldScreenID],
              config.displayConfigs[newScreenID] == nil else {
            return
        }

        config.displayConfigs[newScreenID] = oldConfig
        config.displayConfigs.removeValue(forKey: oldScreenID)
        displayFingerprints.removeValue(forKey: oldScreenID)
        displayFingerprints[newScreenID] = screen.schedulerConfigFingerprint
        saveConfig()
        saveDisplayFingerprints()
        print("\(logTag) Migrated display config from \(oldScreenID) to \(newScreenID) for \(screen.localizedName)")
    }

    /// Re-maps per-screen scheduler state using the saved display fingerprint.
    private func relinkSchedulerStateByFingerprint(using previousFingerprints: [String: String]) {
        let currentScreens = NSScreen.screens
        let currentScreenIDs = Set(currentScreens.map { $0.wallpaperScreenIdentifier })

        var fingerprintToScreenID: [String: String] = [:]
        for screen in currentScreens {
            fingerprintToScreenID[screen.schedulerConfigFingerprint] = screen.wallpaperScreenIdentifier
            fingerprintToScreenID[screen.wallpaperScreenFingerprint] = screen.wallpaperScreenIdentifier
        }

        let orphanedIDs = Set(lastChangedItemIDs.keys)
            .union(lastChangeTimes.keys)
            .union(usedItemIDs.keys)
            .subtracting(currentScreenIDs)
        guard !orphanedIDs.isEmpty else { return }

        var migratedCount = 0
        for orphanedID in orphanedIDs {
            guard let fingerprint = previousFingerprints[orphanedID],
                  let newScreenID = fingerprintToScreenID[fingerprint],
                  newScreenID != orphanedID else {
                continue
            }

            if let value = lastChangedItemIDs.removeValue(forKey: orphanedID) {
                if lastChangedItemIDs[newScreenID] == nil {
                    lastChangedItemIDs[newScreenID] = value
                    migratedCount += 1
                }
            }

            if let value = lastChangeTimes.removeValue(forKey: orphanedID) {
                if lastChangeTimes[newScreenID] == nil {
                    lastChangeTimes[newScreenID] = value
                    migratedCount += 1
                }
            }

            if let value = usedItemIDs.removeValue(forKey: orphanedID) {
                if var existing = usedItemIDs[newScreenID] {
                    existing.formUnion(value)
                    usedItemIDs[newScreenID] = existing
                } else {
                    usedItemIDs[newScreenID] = value
                }
                migratedCount += 1
            }
        }

        if migratedCount > 0 {
            persistSchedulerState()
            print("\(logTag) Relinked scheduler state by fingerprint (\(migratedCount) migrated value(s))")
        }
    }

    /// Persists fingerprint mapping whenever display configs are saved.
    private func syncDisplayFingerprints() {
        for screen in NSScreen.screens {
            let screenID = screen.wallpaperScreenIdentifier
            if config.displayConfigs.keys.contains(screenID) {
                displayFingerprints[screenID] = screen.schedulerConfigFingerprint
            }
        }
    }

    /// 延迟恢复保存的调度配置与运行状态
    func restoreSavedConfig() {
        loadConfig()
        loadDisplayFingerprints()
        restoreSchedulerState()
        // After loading, try to relink configs if screen IDs changed since last launch
        let previousFingerprints = displayFingerprints
        relinkDisplayConfigsByFingerprint()
        relinkSchedulerStateByFingerprint(using: previousFingerprints)
        if hasAnyEnabledDisplay {
            start()
        }
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
        scheduleNextChange()
        saveConfig()
        print("\(logTag) Started. Check interval: \(effectiveCheckInterval())s")
    }

    func stop() {
        dispatchTimer?.cancel()
        dispatchTimer = nil
        isRunning = false
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
        // 根据各屏启用的内容类型校验 folderIDs：移除属于已关闭类型（或 on-end 模式下的壁纸类型）
        // 的文件夹 ID。若全部失效则回退为 nil（全部），避免文件夹过滤把候选清空导致自动更换失效。
        var validated = newConfig
        for screenID in validated.displayConfigs.keys {
            guard var dc = validated.displayConfigs[screenID] else { continue }
            let pruned = validatedFolderIDs(dc.folderIDs, displayConfig: dc)
            if pruned != dc.folderIDs {
                dc.folderIDs = pruned
                validated.displayConfigs[screenID] = dc
            }
        }
        if var globalConfig = validated.globalDisplayConfig {
            let pruned = validatedFolderIDs(globalConfig.folderIDs, displayConfig: globalConfig)
            if pruned != globalConfig.folderIDs {
                globalConfig.folderIDs = pruned
                validated.globalDisplayConfig = globalConfig
            }
        }
        config = validated
        saveConfig()
        if isRunning {
            stop()
        }
        if hasAnyEnabledDisplay {
            start()
        }
    }

    func updateSyncAllDisplays(_ enabled: Bool) {
        guard config.syncAllDisplays != enabled else { return }

        let screens = NSScreen.screens
        if enabled {
            independentWallpaperSources = Dictionary(
                uniqueKeysWithValues: screens.compactMap { screen in
                    activeWallpaperSource(for: screen).map {
                        (screen.wallpaperScreenIdentifier, $0)
                    }
                }
            )
        }

        var newConfig = config
        if enabled, newConfig.globalDisplayConfig == nil {
            if let primaryScreen = screens.first {
                let primaryScreenID = canonicalDisplayConfigScreenID(for: primaryScreen.wallpaperScreenIdentifier)
                newConfig.globalDisplayConfig = newConfig.resolvedDisplayConfig(for: primaryScreenID)
            } else {
                newConfig.globalDisplayConfig = DisplaySchedulerConfig.fromLegacy(newConfig)
            }
        }
        newConfig.syncAllDisplays = enabled
        updateConfig(newConfig)

        guard let primaryScreen = screens.first else { return }
        let primarySource = activeWallpaperSource(for: primaryScreen)
            ?? independentWallpaperSources[primaryScreen.wallpaperScreenIdentifier]
        guard let primarySource else {
            print("\(logTag) Cannot rebuild display sync: primary screen has no active wallpaper source")
            return
        }

        isRebuildingDisplaySync = true
        Task { @MainActor in
            defer { self.isRebuildingDisplaySync = false }
            if enabled {
                await self.rebuildGlobalWallpaper(from: primarySource, screens: screens)
            } else {
                await self.restoreIndependentWallpapers(
                    primarySource: primarySource,
                    screens: screens
                )
            }
        }
    }

    private func rebuildGlobalWallpaper(
        from source: ActiveWallpaperSource,
        screens: [NSScreen]
    ) async {
        stopAllWallpaperRenderersForSyncRebuild()
        guard await applyActiveWallpaperSource(source, to: screens, forceRestartEngine: true) else {
            print("\(logTag) Failed to rebuild global wallpaper from primary screen")
            return
        }
        print("\(logTag) Rebuilt global wallpaper from primary screen on \(screens.count) display(s)")
    }

    private func restoreIndependentWallpapers(
        primarySource: ActiveWallpaperSource,
        screens: [NSScreen]
    ) async {
        guard let primaryScreen = screens.first else { return }
        stopAllWallpaperRenderersForSyncRebuild()

        _ = await applyActiveWallpaperSource(primarySource, to: [primaryScreen], forceRestartEngine: true)
        lastChangeTimes[primaryScreen.wallpaperScreenIdentifier] = .now

        for screen in screens.dropFirst() {
            let screenID = screen.wallpaperScreenIdentifier
            let displayConfig = resolvedDisplayConfig(for: screen)
            let candidates = getSchedulableItems(for: displayConfig, screenID: screenID)
            let candidate = selectNextItem(
                from: candidates,
                lastID: lastChangedItemIDs[screenID],
                screenID: screenID,
                order: displayConfig.order
            )

            if let candidate, await applyItem(candidate, toScreenID: screenID) {
                lastChangeTimes[screenID] = .now
                lastChangedItemIDs[screenID] = candidate.id
                continue
            }

            if let savedSource = independentWallpaperSources[screenID] {
                _ = await applyActiveWallpaperSource(savedSource, to: [screen], forceRestartEngine: true)
                lastChangeTimes[screenID] = .now
                print("\(logTag) Restored saved independent wallpaper for \(screen.localizedName)")
            } else {
                print("\(logTag) No scheduled or saved wallpaper available for \(screen.localizedName)")
            }
        }

        independentWallpaperSources.removeAll()
        persistSchedulerState()
        print("\(logTag) Restored independent wallpaper scheduling after global sync disabled")
    }

    private func activeWallpaperSource(for screen: NSScreen) -> ActiveWallpaperSource? {
        if let videoURL = VideoWallpaperManager.shared.videoURL(for: screen) {
            return .video(videoURL, posterURL: VideoWallpaperManager.shared.posterURL(for: screen))
        }
        if let path = WallpaperEngineXBridge.shared.currentWallpaperPath(for: screen) {
            let isScene = WallpaperEngineXBridge.shared.isCurrentWallpaperScene
            let prefersRealtimeScene = UserDefaults.standard.bool(forKey: "scene_realtime_rendering_enabled")
            if isScene,
               !prefersRealtimeScene,
               let record = downloadedSceneRecord(for: path),
               let artifact = record.sceneBakeArtifact {
                let bakedURL = URL(fileURLWithPath: artifact.videoPath)
                if SceneOfflineBakeService.isUsableBakedVideo(at: bakedURL) {
                    return .video(bakedURL, posterURL: nil)
                }
            }
            let userProperties = WallpaperEngineXBridge.shared.isCurrentWallpaperScene
                ? SceneWallpaperPropertiesService.propertiesOverrideJSON(for: path)
                : nil
            return .engine(
                path: path,
                userProperties: userProperties,
                isWeb: WallpaperEngineXBridge.shared.isCurrentWallpaperWeb
            )
        }
        if let imageURL = StaticImageWallpaperOverlayManager.shared.imageURL(for: screen) {
            return .image(imageURL)
        }
        return DesktopWallpaperSyncManager.shared.imageURL(for: screen).map(ActiveWallpaperSource.image)
    }

    private func stopAllWallpaperRenderersForSyncRebuild() {
        VideoWallpaperManager.shared.stopNativeVideoWallpaperOnly()
        WallpaperEngineXBridge.shared.ensureStoppedForNonCLIWallpaper()
        StaticImageWallpaperOverlayManager.shared.clearState()
    }

    private func applyActiveWallpaperSource(
        _ source: ActiveWallpaperSource,
        to screens: [NSScreen],
        forceRestartEngine: Bool
    ) async -> Bool {
        guard !screens.isEmpty else { return false }

        do {
            switch source {
            case .video(let videoURL, let posterURL):
                try VideoWallpaperManager.shared.applyVideoWallpaper(
                    from: videoURL,
                    posterURL: posterURL,
                    muted: VideoWallpaperManager.shared.isMuted,
                    targetScreens: screens,
                    animatedTransition: false
                )
                return true

            case .engine(let path, let userProperties, let isWeb):
                if isWeb && screens.count > 1 {
                    for screen in screens {
                        try await WallpaperEngineXBridge.shared.setWallpaper(
                            path: path,
                            targetScreens: [screen],
                            userProperties: userProperties,
                            forceRestart: forceRestartEngine
                        )
                    }
                } else {
                    try await WallpaperEngineXBridge.shared.setWallpaper(
                        path: path,
                        targetScreens: screens,
                        userProperties: userProperties,
                        forceRestart: forceRestartEngine
                    )
                }
                if !isWeb {
                    if UserDefaults.standard.bool(forKey: "scene_realtime_rendering_enabled") {
                        SceneOfflineBakeService.scheduleRealtimeCompanionBake(
                            path: path,
                            targetScreens: screens,
                            reason: "displaySyncRebuild"
                        )
                    } else {
                        scheduleBakeForScheduledScene(
                            contentRoot: URL(fileURLWithPath: path),
                            title: URL(fileURLWithPath: path).lastPathComponent,
                            targetScreens: screens,
                            reason: "displaySyncRebuild"
                        )
                    }
                }
                return true

            case .image(let imageURL):
                var applied = true
                for screen in screens {
                    if VideoWallpaperManager.shared.isSystemWallpaperSyncEnabled {
                        do {
                            try NSWorkspace.shared.setDesktopImageURL(imageURL, for: screen, options: [:])
                            DesktopWallpaperSyncManager.shared.registerWallpaperSet(imageURL, for: screen)
                        } catch {
                            applied = false
                            print("\(logTag) Failed to set desktop image for \(screen.localizedName): \(error.localizedDescription)")
                        }
                    } else {
                        applied = StaticImageWallpaperOverlayManager.shared.applyImage(imageURL, to: screen) && applied
                    }
                }
                return applied
            }
        } catch {
            print("\(logTag) Failed to apply captured wallpaper source: \(error.localizedDescription)")
            return false
        }
    }

    /// 将显示器 1 当前的壁纸同步到新接入的显示器。
    ///
    /// 该入口只用于全局同步模式下的热接入，不触发调度随机选择，也不显示“接入新显示器”弹窗。
    /// 视频和烘焙 Scene 会通过全局视频入口复用同一个播放器，避免新屏幕额外创建解码流程。
    @discardableResult
    func syncConnectedDisplayToPrimary(_ screen: NSScreen) async -> Bool {
        guard config.syncAllDisplays else { return false }
        let screens = NSScreen.screens
        guard let primary = screens.first,
              !screens.isEmpty,
              screen.wallpaperScreenIdentifier != primary.wallpaperScreenIdentifier else {
            return false
        }

        let prefersRealtimeScene = UserDefaults.standard.bool(forKey: "scene_realtime_rendering_enabled")

        if prefersRealtimeScene,
           WallpaperEngineXBridge.shared.isCurrentWallpaperScene,
           let path = WallpaperEngineXBridge.shared.currentWallpaperPathForDesign,
           FileManager.default.fileExists(atPath: path) {
            do {
                let userProperties = SceneWallpaperPropertiesService.propertiesOverrideJSON(for: path)
                try await WallpaperEngineXBridge.shared.setWallpaper(
                    path: path,
                    targetScreens: screens,
                    userProperties: userProperties
                )
                SceneOfflineBakeService.scheduleRealtimeCompanionBake(
                    path: path,
                    targetScreens: screens,
                    reason: "globalSyncConnectedDisplay"
                )
                return true
            } catch {
                print("\(logTag) Failed to sync realtime Scene to connected display: \(error)")
            }
        }

        if let videoURL = VideoWallpaperManager.shared.videoURL(for: primary),
           FileManager.default.fileExists(atPath: videoURL.path) {
            let posterURL = VideoWallpaperManager.shared.posterURL(for: primary)
            do {
                try VideoWallpaperManager.shared.applyVideoWallpaper(
                    from: videoURL,
                    posterURL: posterURL,
                    muted: VideoWallpaperManager.shared.isMuted,
                    targetScreens: screens
                )
                return true
            } catch {
                print("\(logTag) Failed to sync shared video to connected display: \(error)")
            }
        }

        if WallpaperEngineXBridge.shared.isControllingExternalEngine,
           let path = WallpaperEngineXBridge.shared.currentWallpaperPathForDesign,
           FileManager.default.fileExists(atPath: path) {
            if !prefersRealtimeScene,
               WallpaperEngineXBridge.shared.isCurrentWallpaperScene,
               let record = downloadedSceneRecord(for: path),
               let artifact = record.sceneBakeArtifact {
                let bakedURL = URL(fileURLWithPath: artifact.videoPath)
                if SceneOfflineBakeService.isUsableBakedVideo(at: bakedURL) {
                    let posterURL = await VideoThumbnailCache.shared.sceneBakePosterJPEGFileURL(
                        forLocalVideo: bakedURL,
                        itemID: record.item.id
                    )
                    do {
                        try VideoWallpaperManager.shared.applyVideoWallpaper(
                            from: bakedURL,
                            posterURL: posterURL,
                            muted: VideoWallpaperManager.shared.isMuted,
                            targetScreens: screens
                        )
                        return true
                    } catch {
                        print("\(logTag) Failed to sync baked Scene to connected display: \(error)")
                    }
                }
            }

            do {
                let userProps = SceneWallpaperPropertiesService.propertiesOverrideJSON(for: path)
                let engineTargets = WallpaperEngineXBridge.shared.isCurrentWallpaperWeb ? [screen] : screens
                try await WallpaperEngineXBridge.shared.setWallpaper(
                    path: path,
                    targetScreens: engineTargets,
                    userProperties: userProps
                )
                return true
            } catch {
                print("\(logTag) Failed to sync live wallpaper engine content: \(error)")
            }
        }

        if let imageURL = StaticImageWallpaperOverlayManager.shared.imageURL(for: primary) {
            return StaticImageWallpaperOverlayManager.shared.applyImage(imageURL, to: screen)
        }

        if let imageURL = DesktopWallpaperSyncManager.shared.imageURL(for: primary) {
            DesktopWallpaperSyncManager.shared.registerWallpaperSet(imageURL, for: screen)
            return true
        }

        return false
    }

    private func downloadedSceneRecord(for path: String) -> MediaDownloadRecord? {
        let contentRoot = WorkshopService.resolveWallpaperEngineProjectRoot(
            startingAt: URL(fileURLWithPath: path)
        ).standardizedFileURL.path
        return MediaLibraryService.shared.downloadedItems.first { record in
            let recordRoot = WorkshopService.resolveWallpaperEngineProjectRoot(
                startingAt: URL(fileURLWithPath: record.localFilePath)
            ).standardizedFileURL.path
            return record.isActive && recordRoot == contentRoot
        }
    }

    /// A scheduled Scene must not remain an indefinitely realtime renderer just
    /// because its bake was absent when it was selected. The bake queue handles
    /// expensive work off the switch path; this callback only replaces the Scene
    /// when it is still the active wallpaper for the same target displays.
    private func scheduleBakeForScheduledScene(
        contentRoot: URL,
        title: String,
        targetScreens: [NSScreen],
        reason: String
    ) {
        let resolvedRoot = WorkshopService.resolveWallpaperEngineProjectRoot(
            startingAt: contentRoot
        )
        let record = downloadedSceneRecord(for: resolvedRoot.path)

        SceneOfflineBakeService.enqueueBakeForAppliedScene(path: resolvedRoot.path) { [weak self] result in
            guard case .success(let artifact) = result else { return }
            let bakedVideoURL = URL(fileURLWithPath: artifact.videoPath)

            guard !UserDefaults.standard.bool(forKey: "scene_realtime_rendering_enabled"),
                  self?.isScheduledSceneStillActive(resolvedRoot, on: targetScreens) == true else {
                VideoWallpaperManager.shared.enqueueAutomaticOptimizationForBakedScene(
                    videoURL: bakedVideoURL,
                    title: record?.item.title ?? title,
                    pipelineItemID: record?.item.id
                )
                return
            }

            Task { @MainActor [weak self] in
                guard let self,
                      !UserDefaults.standard.bool(forKey: "scene_realtime_rendering_enabled"),
                      self.isScheduledSceneStillActive(resolvedRoot, on: targetScreens) else {
                    VideoWallpaperManager.shared.enqueueAutomaticOptimizationForBakedScene(
                        videoURL: bakedVideoURL,
                        title: record?.item.title ?? title,
                        pipelineItemID: record?.item.id
                    )
                    return
                }

                let posterURL: URL?
                if let itemID = record?.item.id {
                    posterURL = await VideoThumbnailCache.shared.sceneBakePosterJPEGFileURL(
                        forLocalVideo: bakedVideoURL,
                        itemID: itemID
                    )
                } else {
                    posterURL = await VideoThumbnailCache.shared.lockScreenPosterURL(
                        forLocalVideo: bakedVideoURL,
                        fallbackPosterURL: nil
                    )
                }

                guard !UserDefaults.standard.bool(forKey: "scene_realtime_rendering_enabled"),
                      self.isScheduledSceneStillActive(resolvedRoot, on: targetScreens) else {
                    VideoWallpaperManager.shared.enqueueAutomaticOptimizationForBakedScene(
                        videoURL: bakedVideoURL,
                        title: record?.item.title ?? title,
                        pipelineItemID: record?.item.id
                    )
                    return
                }

                do {
                    try VideoWallpaperManager.shared.applyVideoWallpaper(
                        from: bakedVideoURL,
                        posterURL: posterURL,
                        muted: true,
                        targetScreens: targetScreens,
                        animatedTransition: true
                    )
                    if let posterURL {
                        for screen in targetScreens {
                            DesktopWallpaperSyncManager.shared.registerWallpaperSet(posterURL, for: screen)
                        }
                    }
                    print("\(self.logTag) Applied completed Scene bake for \(reason): \(bakedVideoURL.lastPathComponent)")
                } catch {
                    print("\(self.logTag) Failed to apply completed Scene bake (\(reason)): \(error.localizedDescription)")
                }
            }
        }
    }

    private func isScheduledSceneStillActive(_ contentRoot: URL, on targetScreens: [NSScreen]) -> Bool {
        guard !targetScreens.isEmpty else { return false }
        let expectedRoot = WorkshopService.resolveWallpaperEngineProjectRoot(
            startingAt: contentRoot
        ).standardizedFileURL.path
        return targetScreens.allSatisfy { screen in
            guard let activePath = WallpaperEngineXBridge.shared.currentWallpaperPath(for: screen) else {
                return false
            }
            let activeRoot = WorkshopService.resolveWallpaperEngineProjectRoot(
                startingAt: URL(fileURLWithPath: activePath)
            ).standardizedFileURL.path
            return activeRoot == expectedRoot
        }
    }

    /// 校验 folderIDs 是否仍属于当前启用的内容类型。
    /// - on-end 模式仅消费媒体，壁纸文件夹视为失效。
    /// - 已删除（在两类文件夹存储中均查不到）的 ID 一并剔除。
    /// - 全部失效时返回 nil（等价于"全部"），避免空过滤把候选清空。
    private func validatedFolderIDs(_ folderIDs: [String]?, displayConfig: DisplaySchedulerConfig) -> [String]? {
        guard let folderIDs, !folderIDs.isEmpty else { return folderIDs }
        let includeWallpapers = displayConfig.includeWallpapers && !displayConfig.isOnEndMode
        let includeMedia = displayConfig.includeMedia
        let store = LibraryFolderStore.shared
        let filtered = folderIDs.filter { id in
            let isWallpaperFolder = store.folder(withID: id, contentType: .wallpaper) != nil
            let isMediaFolder = store.folder(withID: id, contentType: .media) != nil
            if isWallpaperFolder { return includeWallpapers }
            if isMediaFolder { return includeMedia }
            return false // 未知/已删除 ID
        }
        return filtered.isEmpty ? nil : filtered
    }

    /// 是否有至少一个显示器开启了自动更换
    private var hasAnyEnabledDisplay: Bool {
        NSScreen.screens.contains { screen in
            let displayConfig = resolvedDisplayConfig(for: screen)
            return displayConfig.isEnabled
        }
    }

    // MARK: - Per-Display Updates

    func updateDisplayEnabled(_ enabled: Bool, for screenID: String) {
        let screenID = canonicalDisplayConfigScreenID(for: screenID)
        var newConfig = config
        var displayConfig = resolvedScopedDisplayConfig(for: screenID)
        let wasOnEndMode = displayConfig.isOnEndMode
        displayConfig.isEnabled = enabled
        storeScopedDisplayConfig(displayConfig, for: screenID, in: &newConfig)
        updateConfig(newConfig)

        if !enabled {
            if let screen = NSScreen.screens.first(where: { $0.wallpaperScreenIdentifier == screenID }) {
                if wasOnEndMode, let videoURL = VideoWallpaperManager.shared.videoURL(for: screen) {
                    // "播完即换"模式下关闭自动切换：重新应用当前视频并启用循环播放，
                    // 让视频继续播放而不是直接停掉整个动态壁纸
                    Task { @MainActor in
                        let posterURL = VideoWallpaperManager.shared.posterURL(for: screen)
                        try? VideoWallpaperManager.shared.applyVideoWallpaper(
                            from: videoURL,
                            posterURL: posterURL,
                            muted: VideoWallpaperManager.shared.isMuted,
                            targetScreen: screen
                        )
                        print("\(logTag) Auto-switch disabled for screen \(screenID) (was on-end mode), re-enabled looping")
                    }
                } else {
                    // 普通定时模式下关闭自动切换：停止定时器即可，不关闭动态壁纸
                    print("\(logTag) Auto-switch disabled for screen \(screenID), video wallpaper kept running")
                }
            }
        }
    }

    func updateDisplayInterval(_ minutes: Int, for screenID: String) {
        let screenID = canonicalDisplayConfigScreenID(for: screenID)
        var newConfig = config
        var displayConfig = resolvedScopedDisplayConfig(for: screenID)
        let wasOnEndMode = displayConfig.isOnEndMode
        displayConfig.intervalMinutes = minutes
        let isNowOnEndMode = minutes == SchedulerConfig.intervalOnEndMinutes
        storeScopedDisplayConfig(displayConfig, for: screenID, in: &newConfig)
        updateConfig(newConfig)

        // 如果切换到"播完即换"模式，需要重新应用壁纸以启用非循环播放器
        if !wasOnEndMode && isNowOnEndMode {
            if let screen = NSScreen.screens.first(where: { $0.wallpaperScreenIdentifier == screenID }) {
                Task { @MainActor in
                    // 检查是否是 Web 壁纸（由 WallpaperEngineXBridge 管理）
                    let isWebWallpaper = WallpaperEngineXBridge.shared.isManaging(screen: screen)
                    let hasVideo = VideoWallpaperManager.shared.hasActiveWallpaper(on: screen)

                    // 已有本机视频壁纸：重新应用以禁用循环（播完即换非循环模式）
                    if hasVideo, let videoURL = VideoWallpaperManager.shared.videoURL(for: screen) {
                        let posterURL = VideoWallpaperManager.shared.posterURL(for: screen)
                        try? VideoWallpaperManager.shared.applyVideoWallpaper(
                            from: videoURL,
                            posterURL: posterURL,
                            muted: VideoWallpaperManager.shared.isMuted,
                            targetScreen: screen
                        )
                        print("\(logTag) Switched to on-end mode, reapplied wallpaper for screen \(screenID)")
                        return
                    }

                    // 无本机视频壁纸（静态图片 / Web CLI 壁纸等）：自动选取一个视频开始播放
                    if isWebWallpaper {
                        print("\(logTag) On-end mode: stopping CLI Web wallpaper to switch to video")
                        WallpaperEngineXBridge.shared.ensureStoppedForNonCLIWallpaper(for: screen)
                    }
                    print("\(logTag) On-end mode: no active video, auto-selecting first video wallpaper for screen \(screenID)")
                    self.triggerNextWallpaper(for: screenID)
                }
            }
        } else if wasOnEndMode && !isNowOnEndMode {
            // 如果从"播完即换"模式切换回来，需要重新启用循环播放
            if let screen = NSScreen.screens.first(where: { $0.wallpaperScreenIdentifier == screenID }) {
                Task { @MainActor in
                    if let videoURL = VideoWallpaperManager.shared.videoURL(for: screen) {
                        let posterURL = VideoWallpaperManager.shared.posterURL(for: screen)
                        try? VideoWallpaperManager.shared.applyVideoWallpaper(
                            from: videoURL,
                            posterURL: posterURL,
                            muted: VideoWallpaperManager.shared.isMuted,
                            targetScreen: screen
                        )
                        print("\(logTag) Switched from on-end mode, reapplied wallpaper with looping for screen \(screenID)")
                    }
                }
            }
        }
    }

    func updateDisplayOrder(_ order: ScheduleOrder, for screenID: String) {
        let screenID = canonicalDisplayConfigScreenID(for: screenID)
        var newConfig = config
        var displayConfig = resolvedScopedDisplayConfig(for: screenID)
        displayConfig.order = order
        storeScopedDisplayConfig(displayConfig, for: screenID, in: &newConfig)
        updateConfig(newConfig)
    }

    func updateDisplayIncludeWallpapers(_ include: Bool, for screenID: String) {
        let screenID = canonicalDisplayConfigScreenID(for: screenID)
        var newConfig = config
        var displayConfig = resolvedScopedDisplayConfig(for: screenID)
        displayConfig.includeWallpapers = include
        storeScopedDisplayConfig(displayConfig, for: screenID, in: &newConfig)
        updateConfig(newConfig)
    }

    func updateDisplayIncludeMedia(_ include: Bool, for screenID: String) {
        let screenID = canonicalDisplayConfigScreenID(for: screenID)
        var newConfig = config
        var displayConfig = resolvedScopedDisplayConfig(for: screenID)
        displayConfig.includeMedia = include
        storeScopedDisplayConfig(displayConfig, for: screenID, in: &newConfig)
        updateConfig(newConfig)
    }

    func updateDisplayFolderIDs(_ folderIDs: [String]?, for screenID: String) {
        let screenID = canonicalDisplayConfigScreenID(for: screenID)
        var newConfig = config
        var displayConfig = resolvedScopedDisplayConfig(for: screenID)
        guard displayConfig.folderIDs != folderIDs else { return }
        displayConfig.folderIDs = folderIDs
        storeScopedDisplayConfig(displayConfig, for: screenID, in: &newConfig)
        updateConfig(newConfig)
        // 文件夹范围一旦变更，立即从新的范围重新应用壁纸；不等待下一轮定时调度。
        triggerNextWallpaperNow(for: screenID)
    }

    func updateDisplayWebSceneSwitchSeconds(_ seconds: Int?, for screenID: String) {
        let screenID = canonicalDisplayConfigScreenID(for: screenID)
        var newConfig = config
        var displayConfig = resolvedScopedDisplayConfig(for: screenID)
        displayConfig.webSceneSwitchSeconds = seconds
        storeScopedDisplayConfig(displayConfig, for: screenID, in: &newConfig)
        updateConfig(newConfig)
    }

    /// 新外接显示器选择“随机全部壁纸自动更换”时建立独立调度记录。
    /// 时间、内容类型等沿用显示器 1，范围改为全部且强制随机。
    func configureExternalDisplayForRandomAllWallpapers(_ screen: NSScreen) {
        guard !config.syncAllDisplays else { return }
        let screenID = displayConfigScreenID(for: screen)
        let primaryConfig = NSScreen.screens.first
            .map { resolvedDisplayConfig(for: $0) }
            ?? DisplaySchedulerConfig.fromLegacy(config)
        var displayConfig = primaryConfig
        displayConfig.isEnabled = true
        displayConfig.order = .random
        displayConfig.folderIDs = nil

        var newConfig = config
        newConfig.displayConfigs[screenID] = displayConfig
        updateConfig(newConfig)
        triggerNextWallpaperNow(for: screenID)
    }

    /// 记录“暂不使用自动更换”的外接显示器配置，供用户选择保留状态时下次静默恢复。
    func configureExternalDisplayWithoutAutoSwitch(_ screen: NSScreen) {
        guard !config.syncAllDisplays else { return }
        let screenID = displayConfigScreenID(for: screen)
        var displayConfig = resolvedDisplayConfig(for: screen)
        displayConfig.isEnabled = false
        var newConfig = config
        newConfig.displayConfigs[screenID] = displayConfig
        updateConfig(newConfig)
    }

    /// 未选择“保留显示器状态”的外接屏断开后，不再允许其旧调度记录在重连时复活。
    func discardPersistedDisplayState(screenID: String, fingerprint: String) {
        let matchingIDs = Set(displayFingerprints.compactMap { id, storedFingerprint in
            storedFingerprint == fingerprint ? id : nil
        }).union([screenID])

        var changed = false
        for id in matchingIDs {
            changed = config.displayConfigs.removeValue(forKey: id) != nil || changed
            changed = displayFingerprints.removeValue(forKey: id) != nil || changed
            lastChangedItemIDs.removeValue(forKey: id)
            lastChangeTimes.removeValue(forKey: id)
            usedItemIDs.removeValue(forKey: id)
        }
        guard changed else { return }
        saveConfig()
        saveDisplayFingerprints()
        persistSchedulerState()
        print("\(logTag) Discarded persisted scheduler state for disconnected display \(fingerprint)")
    }

    // MARK: - Scheduling

    /// Returns the smallest interval among enabled timed displays.
    /// 注意：特殊模式（intervalMinutes < 0）不参与定时器调度；
    /// 但如果设置了 webSceneSwitchSeconds（Web/Scene 壁纸切换间隔），则仍需定时器。
    private func effectiveCheckInterval() -> TimeInterval {
        let screens = config.syncAllDisplays ? Array(NSScreen.screens.prefix(1)) : NSScreen.screens
        let intervals = screens.compactMap { screen -> TimeInterval? in
            let displayConfig = resolvedDisplayConfig(for: screen)
            guard displayConfig.isEnabled else { return nil }
            guard !displayConfig.isOnUnlockMode else { return nil }
            // "播完即换"模式的屏幕：仅当设置了 Web/Scene 切换间隔时才纳入定时器
            guard !displayConfig.isOnEndMode else {
                if let wsSec = displayConfig.webSceneSwitchSeconds {
                    return TimeInterval(wsSec)
                }
                return nil
            }
            return TimeInterval(displayConfig.intervalMinutes * 60)
        }
        return intervals.min() ?? 0
    }

    private func scheduleNextChange() {
        dispatchTimer?.cancel()
        dispatchTimer = nil

        let interval = effectiveCheckInterval()
        // interval 为 0 表示所有启用的显示器都使用事件触发模式，不需要定时器
        guard interval > 0 else {
            print("\(logTag) All enabled displays use event-driven modes, no timer needed")
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            self?.changeWallpaperIfNeeded()
        }
        timer.activate()
        dispatchTimer = timer
    }

    private func changeWallpaperIfNeeded() {
        guard isRunning, !isScreenLocked, !isRebuildingDisplaySync else { return }
        guard !WallpaperEngineXBridge.shared.isSettingWallpaper else {
            print("\(logTag) Skipping: manual wallpaper setting in progress")
            return
        }
        let screens = NSScreen.screens
        let now = Date()

        if config.syncAllDisplays {
            guard let primaryScreen = screens.first else { return }
            let screenID = primaryScreen.wallpaperScreenIdentifier
            let displayConfig = resolvedDisplayConfig(for: primaryScreen)
            guard displayConfig.isEnabled, !displayConfig.isOnUnlockMode else { return }

            if displayConfig.isOnEndMode {
                guard let seconds = displayConfig.webSceneSwitchSeconds,
                      WallpaperEngineXBridge.shared.isManaging(screen: primaryScreen),
                      lastChangeTimes[screenID].map({ now.timeIntervalSince($0) >= TimeInterval(seconds) - 0.5 }) ?? true else {
                    return
                }
            }

            let items = getSchedulableItems(for: displayConfig, screenID: screenID)
            guard let item = selectNextItem(
                from: items,
                lastID: lastChangedItemIDs[screenID],
                screenID: screenID,
                order: displayConfig.order
            ) else { return }

            Task { @MainActor in
                _ = await self.applySynchronizedItem(item, at: now)
            }
            return
        }

        // 收集所有需要切换的屏幕及其选中项，然后在一个 Task 内依次执行，
        // 避免多屏同时切换时各自 Task 的 @MainActor 片段互相打断导致状态不一致。
        typealias PendingChange = (screenID: String, item: SchedulableItem, screen: NSScreen)
        var pending: [PendingChange] = []

        for screen in screens {
            let screenID = screen.wallpaperScreenIdentifier
            let displayConfig = resolvedDisplayConfig(for: screen)
            guard displayConfig.isEnabled else { continue }
            guard !displayConfig.isOnUnlockMode else { continue }

            // "播完即换"模式的屏幕：设置了 webSceneSwitchSeconds 时由定时器调度（仅 Web/Scene 壁纸）
            // 视频壁纸仍由播放完成通知触发，不走定时器
            if displayConfig.isOnEndMode {
                guard let wsSec = displayConfig.webSceneSwitchSeconds,
                      WallpaperEngineXBridge.shared.isManaging(screen: screen) else { continue }
                let items = getSchedulableItems(for: displayConfig)
                if items.isEmpty {
                    print("\(logTag) Screen \(screenID): no schedulable items for on-end mode with webSceneSwitchSeconds")
                    continue
                }
                let interval = TimeInterval(wsSec)
                if let lastChange = lastChangeTimes[screenID],
                   now.timeIntervalSince(lastChange) < interval - 0.5 {
                    continue
                }
                guard let item = selectNextItem(from: items, lastID: lastChangedItemIDs[screenID], screenID: screenID, order: displayConfig.order) else {
                    print("\(logTag) Screen \(screenID): item selection returned nil for on-end mode with webSceneSwitchSeconds")
                    continue
                }
                pending.append((screenID, item, screen))
                continue
            }

            let items = getSchedulableItems(for: displayConfig)
            if items.isEmpty {
                print("\(logTag) Screen \(screenID): no schedulable items (wallpapers=\(displayConfig.includeWallpapers), media=\(displayConfig.includeMedia))")
                continue
            }

            let interval = TimeInterval(displayConfig.intervalMinutes * 60)
            if let lastChange = lastChangeTimes[screenID],
               now.timeIntervalSince(lastChange) < interval - 0.5 {
                continue
            }

            guard let item = selectNextItem(from: items, lastID: lastChangedItemIDs[screenID], screenID: screenID, order: displayConfig.order) else {
                print("\(logTag) Screen \(screenID): item selection returned nil")
                continue
            }

            pending.append((screenID, item, screen))
        }

        guard !pending.isEmpty else { return }

        Task { @MainActor in
            for (index, change) in pending.enumerated() {
                await self.waitBeforeApplyingBatchedWallpaper(index: index)
                let (screenID, item, _) = change
                let bakeStatus: String
                if item.bakedVideoPath != nil { bakeStatus = "mp4" }
                else { bakeStatus = "none" }
                print("\(logTag) Applying '\(item.title)' to screen \(screenID) [bake=\(bakeStatus)]")

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

    private func changeUnlockWallpapersIfNeeded() {
        guard isRunning, !isScreenLocked, !isRebuildingDisplaySync else { return }
        guard !WallpaperEngineXBridge.shared.isSettingWallpaper else {
            print("\(logTag) Skipping unlock switch: manual wallpaper setting in progress")
            return
        }

        let now = Date()
        if let lastUnlockSwitchTime,
           now.timeIntervalSince(lastUnlockSwitchTime) < 2.0 {
            print("\(logTag) Skipping duplicate unlock switch")
            return
        }

        if config.syncAllDisplays {
            guard let primaryScreen = NSScreen.screens.first else { return }
            let screenID = primaryScreen.wallpaperScreenIdentifier
            let displayConfig = resolvedDisplayConfig(for: primaryScreen)
            guard displayConfig.isEnabled, displayConfig.isOnUnlockMode else { return }
            let items = getSchedulableItems(for: displayConfig, screenID: screenID)
            guard let item = selectNextItem(
                from: items,
                lastID: lastChangedItemIDs[screenID],
                screenID: screenID,
                order: displayConfig.order
            ) else { return }
            lastUnlockSwitchTime = now
            Task { @MainActor in
                _ = await self.applySynchronizedItem(item, at: now)
            }
            return
        }

        typealias PendingChange = (screenID: String, item: SchedulableItem)
        var pending: [PendingChange] = []

        for screen in NSScreen.screens {
            let screenID = screen.wallpaperScreenIdentifier
            let displayConfig = resolvedDisplayConfig(for: screen)
            guard displayConfig.isEnabled && displayConfig.isOnUnlockMode else { continue }

            let items = getSchedulableItems(for: displayConfig, screenID: screenID)
            if items.isEmpty {
                print("\(logTag) Screen \(screenID): no schedulable items for unlock mode")
                continue
            }

            guard let item = selectNextItem(from: items, lastID: lastChangedItemIDs[screenID], screenID: screenID, order: displayConfig.order) else {
                print("\(logTag) Screen \(screenID): item selection returned nil for unlock mode")
                continue
            }

            pending.append((screenID, item))
        }

        guard !pending.isEmpty else { return }
        lastUnlockSwitchTime = now

        Task { @MainActor in
            for (index, change) in pending.enumerated() {
                await self.waitBeforeApplyingBatchedWallpaper(index: index)
                let (screenID, item) = change
                print("\(logTag) Unlock applying '\(item.title)' to screen \(screenID)")

                let success = await applyItem(item, toScreenID: screenID)
                if success {
                    self.lastChangeTimes[screenID] = now
                    self.lastChangedItemIDs[screenID] = item.id
                    self.persistSchedulerState()
                    print("\(logTag) Unlock successfully applied '\(item.title)' to screen \(screenID)")
                } else {
                    print("\(logTag) Unlock failed to apply '\(item.title)' to screen \(screenID)")
                }
            }
        }
    }

    // MARK: - Item Application

    @discardableResult
    private func applySynchronizedItem(_ item: SchedulableItem, at date: Date) async -> Bool {
        guard let primaryScreen = NSScreen.screens.first else { return false }
        guard !isRebuildingDisplaySync,
              !isApplyingSynchronizedItem,
              !VideoWallpaperManager.shared.isPreparingSharedGlobalReplacement else {
            print("\(logTag) Skipping overlapping synchronized switch while the next video is preparing")
            return false
        }
        isApplyingSynchronizedItem = true
        defer { isApplyingSynchronizedItem = false }

        // 全局同步是一次原子切换。applyItem 会把目标提升为全部显示器；这里不能逐屏重复调用，
        // 否则同一视频会被重复预热、重复换层，Scene/Web 还会重复重启渲染器。
        guard await applyItem(item, toScreenID: primaryScreen.wallpaperScreenIdentifier) else {
            return false
        }

        for screen in NSScreen.screens {
            let screenID = screen.wallpaperScreenIdentifier
            lastChangeTimes[screenID] = date
            lastChangedItemIDs[screenID] = item.id
        }
        persistSchedulerState()
        print("\(logTag) Applied synchronized wallpaper '\(item.title)' as one global transaction")
        return true
    }

    private func waitBeforeApplyingBatchedWallpaper(index: Int) async {
        guard index > 0 else { return }
        let delayNanoseconds = UInt64(index) * 1_200_000_000
        try? await Task.sleep(nanoseconds: delayNanoseconds)
    }

    private func applyItem(_ item: SchedulableItem, toScreenID screenID: String) async -> Bool {
        guard let screen = NSScreen.screens.first(where: { $0.wallpaperScreenIdentifier == screenID }) else {
            return false
        }

        let displayConfig = resolvedDisplayConfig(for: screen)
        let isOnEndMode = displayConfig.isOnEndMode
        // Web/Scene 壁纸在播完即换模式下是否启用了定时切换
        let webSceneSwitchEnabled = isOnEndMode && displayConfig.webSceneSwitchSeconds != nil
        let targetScreens = config.syncAllDisplays ? NSScreen.screens : [screen]

        let fileURL = item.fileURL
        let ext = fileURL.pathExtension.lowercased()
        let isDirectory = (try? FileManager.default
            .attributesOfItem(atPath: fileURL.path)[.type] as? FileAttributeType) == .typeDirectory

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            print("\(logTag) Skipping missing scheduled item '\(item.title)': \(fileURL.path)")
            return false
        }

        do {
            // 优先使用烘焙 MP4 产物（WE Scene 离线烘焙）。
            // 实时渲染模式下需跳过：scene 壁纸的烘焙 MP4 仅供锁屏/桌面 poster，不得反向替换
            // 桌面实时渲染（否则会变成播放固定时长 MP4 循环而非 wallpaper-wgpu 实时渲染）。
            // on-end 模式下：如果设置了 webSceneSwitchSeconds（走定时器而非视频通知），允许实时渲染。
            let preferRealtime = UserDefaults.standard.bool(forKey: "scene_realtime_rendering_enabled")
            if let bakedPath = item.bakedVideoPath,
               !preferRealtime,
               SceneOfflineBakeService.isUsableBakedVideo(at: URL(fileURLWithPath: bakedPath)) {
                print("\(logTag) Using baked video: \(bakedPath)")
                let bakedURL = URL(fileURLWithPath: bakedPath)
                let posterURL: URL?
                if let itemID = item.sceneBakeItemID {
                    posterURL = await VideoThumbnailCache.shared.sceneBakePosterJPEGFileURL(
                        forLocalVideo: bakedURL,
                        itemID: itemID
                    )
                } else {
                    posterURL = await VideoThumbnailCache.shared.lockScreenPosterURL(
                        forLocalVideo: bakedURL,
                        fallbackPosterURL: nil
                    )
                }
                try VideoWallpaperManager.shared.applyVideoWallpaper(
                    from: bakedURL,
                    posterURL: posterURL,
                    muted: true,
                    targetScreens: targetScreens,
                    animatedTransition: true
                )
                if let posterURL = posterURL {
                    for targetScreen in targetScreens {
                        DesktopWallpaperSyncManager.shared.registerWallpaperSet(posterURL, for: targetScreen)
                    }
                }
            } else if ext == "pkg", !isDirectory {
                guard isNonemptyRegularFile(fileURL), !isTransientSteamWorkshopPath(fileURL) else {
                    print("\(logTag) Skipping unavailable package wallpaper '\(item.title)'")
                    return false
                }
                if isOnEndMode && !webSceneSwitchEnabled {
                    print("\(logTag) Skipping package wallpaper in on-end mode")
                    return false
                }
                try await WallpaperEngineXBridge.shared.setWallpaper(
                    path: fileURL.path,
                    targetScreens: targetScreens
                )
            } else if isDirectory {
                // 2. Workshop 目录 → 根据 project.json 类型分发
                guard let resolvedRoot = readyWallpaperEngineProjectRoot(at: fileURL) else {
                    print("\(logTag) Skipping incomplete or unsupported project '\(item.title)': \(fileURL.path)")
                    return false
                }
                let projectJSONPath = resolvedRoot.appendingPathComponent("project.json")

                if FileManager.default.fileExists(atPath: projectJSONPath.path),
                   let projectData = try? Data(contentsOf: projectJSONPath),
                   let projectJSON = try? JSONSerialization.jsonObject(with: projectData) as? [String: Any] {

                    // Preset 类型（图片轮播）：project.json 含 "preset" 字段且无 "type" 字段
                    if projectJSON["type"] == nil,
                       let presetDict = projectJSON["preset"] as? [String: Any],
                       let customDir = presetDict["customdirectory"] as? String {
                        // "播完即换"模式下跳过图片轮播（不支持播放完成通知）
                        // 但如果设置了 webSceneSwitchSeconds，则允许图片轮播
                        if isOnEndMode && !webSceneSwitchEnabled {
                            print("\(logTag) Skipping preset slideshow in on-end mode")
                            return false
                        }
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
                            for targetScreen in targetScreens {
                                try await WallpaperEngineXBridge.shared.setWallpaper(
                                    path: resolvedRoot.path,
                                    targetScreens: [targetScreen]
                                )
                            }
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
                                targetScreens: targetScreens,
                                animatedTransition: true
                            )
                            if let posterURL = posterURL {
                                for targetScreen in targetScreens {
                                    DesktopWallpaperSyncManager.shared.registerWallpaperSet(posterURL, for: targetScreen)
                                }
                            }
                        } else {
                            print("\(logTag) Video type but no video file found in project, falling back to CLI")
                            // "播完即换"模式下不能用 CLI 壁纸
                            // 但如果设置了 webSceneSwitchSeconds，则允许 CLI fallback
                            if isOnEndMode && !webSceneSwitchEnabled {
                                print("\(logTag) Skipping CLI fallback in on-end mode")
                                return false
                            }
                            try await WallpaperEngineXBridge.shared.setWallpaper(
                                path: resolvedRoot.path,
                                targetScreens: targetScreens
                            )
                            // 注：CLI 壁纸由 daemon 自身管理桌面 capture，不注册到 DesktopWallpaperSyncManager
                        }
                    } else {
                        // Scene/Web 类型：通过 CLI 渲染
                        // "播完即换"模式下不能用 CLI 壁纸（无播放完成通知），跳过
                        // 但如果设置了 webSceneSwitchSeconds，则允许通过 CLI 渲染
                        if isOnEndMode && !webSceneSwitchEnabled {
                            print("\(logTag) Skipping \(type) wallpaper '\(item.title)' in on-end mode (CLI renderer not supported)")
                            return false
                        }
                        print("\(logTag) Using CLI renderer for WE \(type): \(resolvedRoot.path)")
                        let isRealtime = UserDefaults.standard.bool(forKey: "scene_realtime_rendering_enabled")
                        let userProps = isRealtime
                            ? SceneWallpaperPropertiesService.propertiesOverrideJSON(for: resolvedRoot.path)
                            : nil
                        if type == "web" && config.syncAllDisplays {
                            // Web CLI 一次只消费一个目标屏幕；沿用原有逐屏调用语义。
                            for targetScreen in targetScreens {
                                try await WallpaperEngineXBridge.shared.setWallpaper(
                                    path: resolvedRoot.path,
                                    targetScreens: [targetScreen],
                                    userProperties: userProps
                                )
                            }
                        } else {
                            try await WallpaperEngineXBridge.shared.setWallpaper(
                                path: resolvedRoot.path,
                                targetScreens: targetScreens,
                                userProperties: userProps
                            )
                        }
                        // 无成片的 Scene 一律进入烘焙队列。实时渲染只决定烘焙完成后
                        // 是否替换桌面；不应阻止 Scene 生成可供后续优化的 MP4。
                        if type == "scene", isRealtime {
                            SceneOfflineBakeService.scheduleRealtimeCompanionBake(
                                path: resolvedRoot.path,
                                targetScreens: targetScreens,
                                reason: "scheduler"
                            )
                        } else if type == "scene" {
                            scheduleBakeForScheduledScene(
                                contentRoot: resolvedRoot,
                                title: item.title,
                                targetScreens: targetScreens,
                                reason: "scheduler"
                            )
                        }
                        // 注：CLI 壁纸由 daemon 自身管理桌面 capture，不注册到 DesktopWallpaperSyncManager
                    }
                } else {
                    // 所有目录候选在入队前必须通过 project.json 校验；这里保留兜底，
                    // 绝不能把目录交给系统静态壁纸 API，否则会先停掉旧渲染再得到空桌面。
                    print("\(logTag) Skipping project without readable project.json: \(fileURL.path)")
                    return false
                }
            } else if videoExtensions.contains(ext) {
                // 3. 视频文件 → VideoWallpaperManager
                guard isNonemptyRegularFile(fileURL), !isTransientSteamWorkshopPath(fileURL) else {
                    print("\(logTag) Skipping incomplete video wallpaper '\(item.title)'")
                    return false
                }
                print("\(logTag) Using video wallpaper: \(fileURL.lastPathComponent)")
                let posterURL = await VideoThumbnailCache.shared.lockScreenPosterURL(
                    forLocalVideo: fileURL,
                    fallbackPosterURL: nil
                )
                try VideoWallpaperManager.shared.applyVideoWallpaper(
                    from: fileURL,
                    posterURL: posterURL,
                    muted: true,
                    targetScreens: targetScreens,
                    animatedTransition: true
                )
                if let posterURL = posterURL {
                    for targetScreen in targetScreens {
                        DesktopWallpaperSyncManager.shared.registerWallpaperSet(posterURL, for: targetScreen)
                    }
                }
            } else {
                // 4. 静态图 → WallpaperViewModel
                if isOnEndMode && !webSceneSwitchEnabled {
                    print("\(logTag) Skipping static image '\(item.title)' in on-end mode")
                    return false
                }
                guard isReadyStaticImage(fileURL) else {
                    print("\(logTag) Skipping unsupported static wallpaper '\(item.title)': \(fileURL.path)")
                    return false
                }
                print("\(logTag) Using static image: \(fileURL.lastPathComponent)")
                let vm = WallpaperViewModel()
                for targetScreen in targetScreens {
                    try await vm.setWallpaper(from: fileURL, option: .desktop, for: targetScreen)
                }
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

    /// Validates a Workshop directory before it enters an event-driven rotation.
    /// Scene and web projects have no AVPlayer completion event, so selecting either
    /// after a video ends would leave the finished player paused without a successor.
    private func workshopDirectoryContainsPlayableVideo(
        at directory: URL,
        allowedExtensions: Set<String>
    ) -> Bool {
        let root = WorkshopService.resolveWallpaperEngineProjectRoot(startingAt: directory)
        let projectURL = root.appendingPathComponent("project.json")
        guard let data = try? Data(contentsOf: projectURL),
              let project = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (project["type"] as? String)?.lowercased() == "video",
              let videoURL = findVideoFileInProject(projectJSON: project, root: root) else {
            return false
        }

        return allowedExtensions.contains(videoURL.pathExtension.lowercased())
    }

    private let videoExtensions: Set<String> = ["mp4", "mov", "webm", "mkv", "avi", "m4v", "flv"]
    private let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "bmp", "gif", "webp", "tga", "tif", "tiff"]

    private func isNonemptyRegularFile(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.type] as? FileAttributeType) != .typeDirectory else {
            return false
        }
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0 > 0
    }

    private func isReadyStaticImage(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased()) && isNonemptyRegularFile(url)
    }

    /// SteamCMD 会在下载期间创建外层 `workshop_<id>` 目录和临时 project.json；
    /// 只有内容进入 `workshop/content/431960/<id>` 后，才可被调度器当作可用工程。
    /// 没有 Steam 目录的本地导入工程则直接验证自身 project.json。
    private func readyWallpaperEngineProjectRoot(at url: URL) -> URL? {
        let fileManager = FileManager.default
        let standardizedURL = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: standardizedURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              !isTransientSteamWorkshopPath(standardizedURL) else {
            return nil
        }

        let candidateRoot: URL
        if let workshopContainer = workshopContainerURL(for: standardizedURL) {
            let steamapps = workshopContainer.appendingPathComponent("steamapps", isDirectory: true)
            if fileManager.fileExists(atPath: steamapps.path) {
                let workshopID = String(workshopContainer.lastPathComponent.dropFirst("workshop_".count))
                let completedContent = steamapps
                    .appendingPathComponent("workshop/content/431960/\(workshopID)", isDirectory: true)
                guard fileManager.fileExists(atPath: completedContent.path) else {
                    return nil
                }
                candidateRoot = completedContent
            } else {
                candidateRoot = standardizedURL
            }
        } else {
            candidateRoot = standardizedURL
        }

        let resolvedRoot = WorkshopService.resolveWallpaperEngineProjectRoot(startingAt: candidateRoot)
        let projectURL = resolvedRoot.appendingPathComponent("project.json")
        guard let data = try? Data(contentsOf: projectURL),
              let project = try? JSONSerialization.jsonObject(with: data),
              project is [String: Any] else {
            return nil
        }
        return resolvedRoot
    }

    private func workshopContainerURL(for url: URL) -> URL? {
        var current = url
        while true {
            if current.lastPathComponent.hasPrefix("workshop_") {
                return current
            }
            let parent = current.deletingLastPathComponent()
            guard parent.path != current.path else { return nil }
            current = parent
        }
    }

    private func isTransientSteamWorkshopPath(_ url: URL) -> Bool {
        let components = url.pathComponents
        guard let steamappsIndex = components.lastIndex(of: "steamapps"),
              steamappsIndex + 2 < components.count,
              components[steamappsIndex + 1] == "workshop" else {
            return false
        }
        let location = components[steamappsIndex + 2]
        return location == "downloads" || location == "downloading"
    }

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
        /// 生成稳定烘焙抽帧时使用的媒体 item id。
        let sceneBakeItemID: String?
    }

    private func selectNextItem(from items: [SchedulableItem], lastID: String?, screenID: String, order: ScheduleOrder) -> SchedulableItem? {
        guard !items.isEmpty else { return nil }
        let sequenceAnchorID = activeSchedulableItemID(
            for: screenID,
            in: items
        ) ?? lastID

        switch order {
        case .sequential:
            return selectSequential(from: items, lastID: sequenceAnchorID)
        case .random:
            return selectRandom(from: items, lastID: sequenceAnchorID, screenID: screenID)
        }
    }

    private func getSchedulableItems(for displayConfig: DisplaySchedulerConfig, screenID: String? = nil) -> [SchedulableItem] {
        var items: [SchedulableItem] = []

        // "播完即换"模式下只获取视频项（静态图片和 Web/Scene 壁纸不支持播完即换）
        // 但如果设置了 webSceneSwitchSeconds，则允许包含 Web/Scene 壁纸
        let onEndMode = displayConfig.isOnEndMode
        let webSceneSwitchEnabled = onEndMode && displayConfig.webSceneSwitchSeconds != nil

        // 文件夹过滤：nil = 全部，非空 = 仅这些文件夹（含根目录无 folderID 的项）
        let folderIDs = displayConfig.folderIDs
        let folderFilter: (String?) -> Bool = { itemFolderID in
            guard let folderIDs else { return true } // nil = 全部
            if folderIDs.isEmpty { return itemFolderID == nil } // 空数组 = 只匹配根目录
            guard let itemFolderID else { return false } // 有文件夹过滤，nil 项不匹配
            return folderIDs.contains(itemFolderID)
        }

        if displayConfig.includeWallpapers && (!onEndMode || webSceneSwitchEnabled) {
            // Downloaded wallpapers（图片或已烘焙的 WE scene 目录）
            for record in WallpaperLibraryService.shared.downloadedWallpapers {
                guard folderFilter(record.folderID) else { continue }
                let url = URL(fileURLWithPath: record.localFilePath)
                guard isReadyStaticImage(url) else { continue }
                items.append(SchedulableItem(
                    id: "wp_dl_\(record.id)",
                    fileURL: url,
                    title: url.deletingPathExtension().lastPathComponent,
                    bakedVideoPath: nil,
                    sceneBakeItemID: nil
                ))
            }
            // Scanned local wallpapers（仅未指定文件夹时包含本地扫描文件）
            if folderIDs == nil {
                for item in LocalWallpaperScanner.shared.getLocalWallpapers() {
                    guard isReadyStaticImage(item.fileURL) else { continue }
                    items.append(SchedulableItem(
                        id: "wp_scan_\(item.id)",
                        fileURL: item.fileURL,
                        title: item.title,
                        bakedVideoPath: nil,
                        sceneBakeItemID: nil
                    ))
                }
            }
        }

        if displayConfig.includeMedia {
            // 自动切换仅支持能被 VideoWallpaperManager 播放的视频格式
            // 与 applyItem 中的 videoExtensions 保持一致（排除 webm——macOS 原生播放器不稳定）
            let allowedMediaExts: Set<String> = ["mp4", "m4v", "mov", "mkv", "avi", "flv"]

            // 已在 wallpapers 分支添加过的 Workshop 项 ID（当双选时避免重复）
            let existingIDs = Set(items.map(\.id))

            // Downloaded media（包含 Workshop 视频/媒体）
            for record in MediaLibraryService.shared.downloadedItems {
                guard folderFilter(record.folderID) else { continue }
                let url = URL(fileURLWithPath: record.localFilePath)
                let isWorkshop = record.item.id.hasPrefix("workshop_")
                let isAllowedExt = allowedMediaExts.contains(url.pathExtension.lowercased())
                let isDirectory = (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeDirectory
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                let itemID = "media_dl_\(record.id)"
                // 双选时 wallpapers 分支已添加过，跳过避免重复
                if isWorkshop && displayConfig.includeWallpapers && existingIDs.contains(itemID) {
                    continue
                }
                // Workshop 项优先使用烘焙产物。
                // 但实时渲染模式下，scene 壁纸的烘焙 MP4 仅供锁屏/桌面 poster（见
                // SceneOfflineBakeService.scheduleRealtimeCompanionBake 注释），
                // 不得反向替换桌面实时渲染——否则轮播第二次起会变成播放固定时长的
                // 烘焙视频而非 wallpaper-wgpu 实时渲染。
                // on-end 模式下：如果设置了 webSceneSwitchSeconds（走定时器），允许实时渲染。
                let isRealtimeRenderingEnabled = UserDefaults.standard.bool(forKey: "scene_realtime_rendering_enabled")
                let preferRealtimeForScene = isRealtimeRenderingEnabled && (!onEndMode || webSceneSwitchEnabled)
                var bakedVideoPath: String? = nil
                var sceneBakeItemID: String? = nil
                if isWorkshop, !preferRealtimeForScene, let art = record.sceneBakeArtifact {
                    if SceneOfflineBakeService.isUsableBakedVideo(at: URL(fileURLWithPath: art.videoPath)) {
                        bakedVideoPath = art.videoPath
                        sceneBakeItemID = record.item.id
                    }
                }

                // 目录存在不等于 Workshop 已完成下载。SteamCMD 在临时 downloads 目录
                // 中就会写入 project.json，若不在这里过滤，后续会把半成品当壁纸应用。
                let hasUsableBakedVideo = bakedVideoPath != nil
                let isReadyProject = isDirectory && readyWallpaperEngineProjectRoot(at: url) != nil
                let isReadyDirectVideo = !isDirectory
                    && isAllowedExt
                    && isNonemptyRegularFile(url)
                    && !isTransientSteamWorkshopPath(url)
                let isReadyPackage = !isDirectory
                    && url.pathExtension.lowercased() == "pkg"
                    && isNonemptyRegularFile(url)
                    && !isTransientSteamWorkshopPath(url)
                guard hasUsableBakedVideo || isReadyDirectVideo || (isWorkshop && (isReadyProject || isReadyPackage)) else {
                    print("\(logTag) Skipping unavailable media candidate '\(record.item.title)': \(url.path)")
                    continue
                }

                // "播完即换"模式下跳过 Web 壁纸（由 CLI 渲染，不支持播完即换）
                // 但如果设置了 webSceneSwitchSeconds，则允许包含 Web 壁纸
                if onEndMode && !webSceneSwitchEnabled && url.pathExtension.lowercased() == "web" {
                    continue
                }

                // "播完即换"模式下只保留可通过 VideoWallpaperManager 播放的视频项：
                // 1. 有 bakedVideoPath 的烘焙 mp4 项
                // 2. 直接的视频文件
                // 3. 声明为 video 类型且包含可播放视频的 Workshop 目录
                // 如果设置了 webSceneSwitchSeconds，则放宽限制，允许所有 Workshop 项
                if onEndMode && !webSceneSwitchEnabled {
                    if bakedVideoPath != nil {
                        // 有烘焙视频产物，可播放
                    } else if isAllowedExt && !isDirectory {
                        // 可由 AVFoundation 直接播放的视频文件
                    } else if isWorkshop && isDirectory && workshopDirectoryContainsPlayableVideo(
                        at: url,
                        allowedExtensions: allowedMediaExts
                    ) {
                        // 候选阶段已验证，避免结束后选到 scene/web 再黑屏。
                    } else {
                        continue
                    }
                }

                items.append(SchedulableItem(
                    id: itemID,
                    fileURL: url,
                    title: record.item.title,
                    bakedVideoPath: bakedVideoPath,
                    sceneBakeItemID: sceneBakeItemID
                ))
            }
            // Scanned local media（仅未指定文件夹时包含）
            if folderIDs == nil {
                for item in LocalWallpaperScanner.shared.getLocalMedia() {
                    guard allowedMediaExts.contains(item.fileURL.pathExtension.lowercased()),
                          isNonemptyRegularFile(item.fileURL) else { continue }
                    items.append(SchedulableItem(
                        id: "media_scan_\(item.id)",
                        fileURL: item.fileURL,
                        title: item.title,
                        bakedVideoPath: nil,
                        sceneBakeItemID: nil
                    ))
                }
            }
        }

        return deduplicatedSchedulableItemsPreservingLibraryOrder(items)
    }

    /// 资料库记录本身就是“我的库 / 文件夹”的展示顺序，顺序切换必须保留它。
    /// 同时，本地扫描会再次发现已入库的文件；只移除同一路径的重复条目，不排序、
    /// 不打散资料库已有的顺序。
    private func deduplicatedSchedulableItemsPreservingLibraryOrder(
        _ items: [SchedulableItem]
    ) -> [SchedulableItem] {
        var seenPaths = Set<String>()
        return items.filter { item in
            seenPaths.insert(item.fileURL.standardizedFileURL.path).inserted
        }
    }

    /// 手动设置壁纸、升级后恢复状态或切换全局模式时，持久化的 last ID 可能已过期。
    /// 优先以屏幕当前正在显示的资源反查候选项，保证“下一张”从当前库项继续，而不是
    /// 因找不到旧 ID 永远回到第一项。
    private func activeSchedulableItemID(
        for screenID: String,
        in items: [SchedulableItem]
    ) -> String? {
        guard let screen = NSScreen.screens.first(where: {
            $0.wallpaperScreenIdentifier == screenID
        }), let activeURL = activeWallpaperURL(for: screen) else {
            return nil
        }

        let activePath = activeURL.standardizedFileURL.path
        return items.first { item in
            let candidatePath = item.fileURL.standardizedFileURL.path
            return activePath == candidatePath
                || activePath.hasPrefix(candidatePath + "/")
                || candidatePath.hasPrefix(activePath + "/")
        }?.id
    }

    private func activeWallpaperURL(for screen: NSScreen) -> URL? {
        if let videoURL = VideoWallpaperManager.shared.videoURL(for: screen) {
            return videoURL
        }
        if let enginePath = WallpaperEngineXBridge.shared.currentWallpaperPath(for: screen) {
            return URL(fileURLWithPath: enginePath)
        }
        if let imageURL = StaticImageWallpaperOverlayManager.shared.imageURL(for: screen) {
            return imageURL
        }
        return DesktopWallpaperSyncManager.shared.imageURL(for: screen)
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
        syncDisplayFingerprints()
        saveDisplayFingerprints()
    }

    private func saveDisplayFingerprints() {
        if let data = try? PropertyListEncoder().encode(displayFingerprints) {
            UserDefaults.standard.set(data, forKey: displayFingerprintsKey)
        }
    }

    private func loadDisplayFingerprints() {
        if let data = UserDefaults.standard.data(forKey: displayFingerprintsKey),
           let decoded = try? PropertyListDecoder().decode([String: String].self, from: data) {
            displayFingerprints = decoded
        }
    }

    private func loadConfig() {
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let loadedConfig = try? JSONDecoder().decode(SchedulerConfig.self, from: data) {
            config = loadedConfig
        }
    }
}
