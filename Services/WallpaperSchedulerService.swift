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
    /// Per-screen in-flight set for "播完即换" — blocks concurrent applies.
    private var onEndSwitchInFlightScreens = Set<String>()
    /// Cancellable tasks for independent-screen on-end applies. The task must
    /// be drained before a manual apply starts, otherwise its awaited renderer
    /// work can finish later and overwrite the user's selection.
    private var onEndSwitchTasks: [String: Task<Void, Never>] = [:]
    private var onEndSwitchGeneration: UInt64 = 0
    /// Earliest time another on-end apply is allowed for a screen (post-apply cooldown).
    private var onEndSwitchCooldownUntilByScreen: [String: Date] = [:]
    /// Ignore another on-end trigger for the same screen within this window after apply returns.
    private let onEndSwitchCooldown: TimeInterval = 1.5
    /// A timed multi-screen batch is one transaction. Later timer ticks must
    /// not race it while renderer/player setup is still awaiting.
    private var timedRotationTask: Task<Void, Never>?
    private var timedRotationGeneration: UInt64 = 0
    /// Shared-decoder playback has one logical end event even though every
    /// attached display may observe the underlying AVPlayerItem.
    private var globalOnEndSwitchCooldownUntil: Date?
    /// 使关闭全局同步之前启动的全局任务失效，禁止其晚到结果覆盖各屏状态。
    private var globalRotationGeneration: UInt64 = 0
    private var displayModeTransitionGeneration: UInt64 = 0
    private var displayModeTransitionTask: Task<Void, Never>?

    /// One-shot deadline timer: fire at the earliest due switch, then recompute.
    private var dispatchTimer: DispatchSourceTimer?
    /// Keeps the process out of App Nap while a timed rotation is armed.
    private var schedulerActivity: NSObjectProtocol?
    /// After a failed timed apply, retry this screen no earlier than this date
    /// (avoids waiting a full user interval on transient failures).
    private var failedApplyRetryAfter: [String: Date] = [:]
    private var pendingCleanupWorkItem: DispatchWorkItem?
    private let userDefaultsKey = "wallpaper_scheduler_config"
    private let usedItemIDsKey = "wallpaper_scheduler_used_item_ids_v1"
    private let lastChangeTimesKey = "wallpaper_scheduler_last_change_times_v1"
    private let lastChangedItemIDsKey = "wallpaper_scheduler_last_changed_item_ids_v1"
    private let displayFingerprintsKey = "wallpaper_scheduler_display_fingerprints_v1"
    private let logTag = "[WallpaperScheduler]"
    private let globalSchedulerStateKey = "__global_display_sync__"
    /// 用户从状态栏手动关闭壁纸后抑制定时轮换的屏幕（含全局键）。
    /// 该屏重新出现活跃动态壁纸（用户手动开启/设置）时由 tick 自然解除。
    private let userSuppressedScreensKey = "wallpaper_scheduler_user_suppressed_v1"
    private var userSuppressedScreenIDs: Set<String> = []
    /// Match existing "interval - 0.5" eligibility slack.
    private let intervalEligibilitySlack: TimeInterval = 0.5
    /// Short poll when apply is blocked (manual set in flight, batch running).
    private let deferredRetryDelay: TimeInterval = 5
    /// Retry soon after a failed timed apply instead of waiting a full interval.
    private let failedApplyRetryDelay: TimeInterval = 15
    /// When a managed library root is unavailable (for example, its external
    /// volume is disconnected), avoid probing every registered item path.
    private let unavailableLibraryRetryDelay: TimeInterval = 60
    private let minimumTimerDelay: TimeInterval = 0.25
    private let scheduleLeeway: DispatchTimeInterval = .milliseconds(200)
    private var isScreenLocked = false
    /// 锁屏期间到达的「播完即换」事件（观察者已把旧视频 pause+seek(0)）。
    /// screenIsUnlocked 分布式通知偶发丢失时 isScreenLocked 会卡死，
    /// 这些事件解锁后由 drainPendingOnEndSwitches 重放，避免该屏永远停在封面帧。
    private var pendingOnEndSwitchScreenIDs: Set<String> = []
    private var lastUnlockSwitchTime: Date?
    private var globalRotationTask: Task<Void, Never>?
    /// A manual next request must not be lost when a timed/on-end global
    /// rotation is still committing its renderer transaction.
    private struct PendingManualGlobalRotation {
        let overrideOrder: ScheduleOrder?
        let preferImmediatePresentation: Bool
    }
    private var activeGlobalRotationIsManual = false
    private var pendingManualGlobalRotation: PendingManualGlobalRotation?
    /// Blocks a timer callback while a user-initiated apply is committing.
    private var manualWallpaperApplyInFlight = false
    /// Cached per-root health result. Candidate construction stays memory-only;
    /// each actual switch forces one root-level check before applying.
    private var managedLibraryRootAvailability: (path: String, isAvailable: Bool)?
    private var unavailableLibraryRetryUntil: Date?
    /// Missing files are removed from this process's candidate pool after the
    /// real apply path detects them, rather than being stat'ed every rotation.
    private var unavailableSchedulableItemIDs = Set<String>()

    /// Persists screenID → fingerprint mapping so that display configs can be
    /// relinked after sleep/wake when CGDirectDisplayID may change on external monitors.
    private var displayFingerprints: [String: String] = [:]

    /// 视频播放完成通知（用于"播完即换"模式）
    static let videoPlaybackEndedNotification = Notification.Name("com.waifux.scheduler.videoPlaybackEnded")

    var isGlobalDisplaySyncEnabled: Bool {
        config.isGlobalDisplaySyncEnabled
    }

    var globalDisplayConfig: DisplaySchedulerConfig {
        config.globalDisplayConfig
    }

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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleManagedLibraryChanged),
            name: .managedLibraryContentsChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleManagedLibraryChanged),
            name: .downloadPathChanged,
            object: nil
        )
        // 监听视频播放完成通知（用于"播完即换"模式）
        DistributedNotificationCenter.default.addObserver(
            self,
            selector: #selector(handleVideoPlaybackEnded(_:)),
            name: Self.videoPlaybackEndedNotification,
            object: nil
        )
        // LockScreenWallpaperService 的播放状态（进程内通知，带唤醒/解锁后的
        // session 校正）。com.apple.screenIsUnlocked 分布式通知偶发丢失会让
        // 本地 isScreenLocked 永久卡死（定时器被取消、on-end 事件全被丢弃），
        // 这里订阅校正后的状态作为自愈来源。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleLockScreenPlaybackStateDidChange(_:)),
            name: LockScreenWallpaperService.playbackStateNotification,
            object: nil
        )
    }

    @objc private func handleVideoPlaybackEnded(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let screenID = userInfo["screenID"] as? String else {
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.displayModeTransitionTask != nil,
               !self.config.isGlobalDisplaySyncEnabled {
                print("\(self.logTag) Ignoring playback-end event during global-to-independent transition")
                return
            }
            if self.config.isGlobalDisplaySyncEnabled {
                self.applyNextGlobalWallpaper(requiredMode: .onEnd)
            } else {
                self.triggerNextWallpaper(for: screenID)
            }
        }
    }

    /// 为指定屏幕触发下一次壁纸更换（用于"播完即换"模式）
    private func triggerNextWallpaper(for screenID: String) {
        applyNextWallpaper(for: screenID, requiredMode: .onEnd)
    }

    /// 手动为指定屏幕切换下一张壁纸。即使该屏幕暂时关闭自动切换，也允许使用
    /// 已保存的轮换范围、顺序和文件夹过滤来选取下一张。
    func triggerNextWallpaperNow(for screenID: String) {
        print("\(logTag) Manual next wallpaper requested for screen \(screenID)")
        if config.isGlobalDisplaySyncEnabled {
            applyNextGlobalWallpaper(requiredMode: nil, preferImmediatePresentation: true)
            return
        }
        applyNextWallpaper(for: screenID, requiredMode: nil, preferImmediatePresentation: true)
    }

    func triggerNextGlobalWallpaperNow() {
        applyNextGlobalWallpaper(requiredMode: nil, preferImmediatePresentation: true)
    }

    func triggerRandomWallpaperNow(for screenID: String) {
        if config.isGlobalDisplaySyncEnabled {
            applyNextGlobalWallpaper(requiredMode: nil, overrideOrder: .random, preferImmediatePresentation: true)
            return
        }
        applyNextWallpaper(for: screenID, requiredMode: nil, overrideOrder: .random, preferImmediatePresentation: true)
    }

    func hasSchedulableItems(for screenID: String) -> Bool {
        guard isManagedLibraryAvailable() else { return false }
        let displayConfig = config.isGlobalDisplaySyncEnabled
            ? config.globalDisplayConfig
            : config.resolvedDisplayConfig(for: screenID)
        return !getSchedulableItems(
            for: displayConfig
        ).isEmpty
    }

    func resolvedDisplayConfig(for screen: NSScreen) -> DisplaySchedulerConfig {
        if config.isGlobalDisplaySyncEnabled {
            return config.globalDisplayConfig
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

    func displayConfigScreenID(for screen: NSScreen) -> String {
        if let existingScreenID = existingConfigScreenID(for: screen),
           config.displayConfigs[existingScreenID] != nil {
            migrateDisplayConfig(from: existingScreenID, to: screen)
        }
        displayFingerprints[screen.wallpaperScreenIdentifier] = screen.schedulerConfigFingerprint
        saveDisplayFingerprints()
        return screen.wallpaperScreenIdentifier
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
        overrideOrder: ScheduleOrder? = nil,
        preferImmediatePresentation: Bool = false
    ) {
        if case .onEnd? = requiredMode, manualWallpaperApplyInFlight {
            print("\(logTag) Skipping on-end next for \(screenID): manual wallpaper setting in progress")
            return
        }
        // 手动“下一张”允许在锁屏标志异常时继续；自动 on-end 仍尊重锁屏状态。
        // screenIsUnlocked DistributedNotification 偶发丢失时，isScreenLocked 会永久卡死，
        // 因此丢弃的 on-end 事件记入 pendingOnEndSwitchScreenIDs，解锁后重放。
        if isScreenLocked {
            if requiredMode == nil {
                print("\(logTag) Manual next requested while isScreenLocked=true; force-clearing stuck lock flag")
                isScreenLocked = false
            } else {
                print("\(logTag) Skip next wallpaper for \(screenID): screen is locked (queued for replay after unlock)")
                pendingOnEndSwitchScreenIDs.insert(screenID)
                return
            }
        }
        guard let liveScreen = NSScreen.screens.first(where: { $0.wallpaperScreenIdentifier == screenID }) else {
            print("\(logTag) Skip next wallpaper: screen \(screenID) not found")
            return
        }
        let displayConfig = resolvedDisplayConfig(for: liveScreen)
        switch requiredMode {
        case .onEnd:
            guard displayConfig.isEnabled && displayConfig.isOnEndMode else {
                print("\(logTag) Skip on-end next for \(screenID): enabled=\(displayConfig.isEnabled) onEnd=\(displayConfig.isOnEndMode)")
                return
            }
            // 同一屏切换进行中 / 冷却中：吞掉重复 end 事件，避免“连着切两张”。
            // 冷却命中时必须恢复当前视频，否则 end observer 已 pause+seek 会停在 poster 上。
            if onEndSwitchInFlightScreens.contains(screenID) {
                print("\(logTag) Skip on-end next for \(screenID): switch already in flight")
                return
            }
            if let cooldownUntil = onEndSwitchCooldownUntilByScreen[screenID],
               Date() < cooldownUntil {
                print("\(logTag) Skip on-end next for \(screenID): within post-switch cooldown; resume current video")
                recoverCurrentVideoAfterFailedOnEndSwitch(for: screenID, requiredMode: requiredMode)
                return
            }
            onEndSwitchInFlightScreens.insert(screenID)
        case nil:
            break
        }

        guard isManagedLibraryAvailable(forceRefresh: true) else {
            print("\(logTag) Skip next wallpaper for \(screenID): managed library root unavailable")
            finishOnEndSwitch(for: screenID, requiredMode: requiredMode, applied: false)
            recoverCurrentVideoAfterFailedOnEndSwitch(for: screenID, requiredMode: requiredMode)
            return
        }

        let items = getSchedulableItems(for: displayConfig)
        guard !items.isEmpty else {
            print("\(logTag) Screen \(screenID): no schedulable items for next-wallpaper request (includeMedia=\(displayConfig.includeMedia) includeWallpapers=\(displayConfig.includeWallpapers) onEnd=\(displayConfig.isOnEndMode))")
            finishOnEndSwitch(for: screenID, requiredMode: requiredMode, applied: false)
            recoverCurrentVideoAfterFailedOnEndSwitch(for: screenID, requiredMode: requiredMode)
            return
        }

        let now = Date()
        let lastChangedItemID = lastChangedItemIDs[screenID]

        let order = overrideOrder ?? displayConfig.order
        // 优先消费预热时定下的粘性预约：保证子进程预热管线命中，
        // 播完→新视频首帧可见间隔从 ~1.3s 压到 ~0.4s。
        // 预约失效（已被手动切走 / 已从图库移除）则回落常规选择。
        let reservationKey = config.isGlobalDisplaySyncEnabled
            ? globalSchedulerStateKey
            : screenID
        var reservedItem: SchedulableItem?
        if let reserved = reservedNextOnEndItems.removeValue(forKey: reservationKey) {
            if reserved.id == lastChangedItemID {
                AppLogger.debug(.wallpaper, "onEnd 预约弃用：与当前项相同", metadata: ["item": reserved.fileURL.lastPathComponent])
            } else if !items.contains(where: { $0.id == reserved.id }) {
                AppLogger.debug(.wallpaper, "onEnd 预约弃用：已不在候选池", metadata: ["item": reserved.fileURL.lastPathComponent])
            } else {
                AppLogger.debug(.wallpaper, "onEnd 预约消费 ✓", metadata: [
                    "stateKey": reservationKey,
                    "item": reserved.fileURL.lastPathComponent
                ])
                reservedItem = reserved
                if order == .random {
                    var used = usedItemIDs[screenID] ?? Set()
                    used.insert(reserved.id)
                    usedItemIDs[screenID] = used
                    persistSchedulerState()
                }
            }
        }
        guard let item = reservedItem
            ?? selectNextItem(from: items, lastID: lastChangedItemID, screenID: screenID, order: order) else {
            print("\(logTag) Screen \(screenID): item selection returned nil for on-end mode")
            finishOnEndSwitch(for: screenID, requiredMode: requiredMode, applied: false)
            recoverCurrentVideoAfterFailedOnEndSwitch(for: screenID, requiredMode: requiredMode)
            return
        }

        let generation = onEndSwitchGeneration
        let task = Task { @MainActor in
            var didApply = false
            defer {
                if self.onEndSwitchGeneration == generation {
                    self.onEndSwitchTasks.removeValue(forKey: screenID)
                    self.finishOnEndSwitch(for: screenID, requiredMode: requiredMode, applied: didApply)
                }
            }
            guard !Task.isCancelled,
                  self.onEndSwitchGeneration == generation,
                  !self.manualWallpaperApplyInFlight else {
                return
            }
            print("\(logTag) Applying next wallpaper '\(item.title)' (\(item.fileURL.lastPathComponent)) to screen \(screenID)")
            let success = await applyItem(
                item,
                toScreenID: screenID,
                preferImmediatePresentation: preferImmediatePresentation
            )
            guard !Task.isCancelled,
                  self.onEndSwitchGeneration == generation,
                  !self.manualWallpaperApplyInFlight else {
                return
            }
            if success {
                didApply = true
                self.lastChangeTimes[screenID] = now
                self.lastChangedItemIDs[screenID] = item.id
                self.persistSchedulerState()
                print("\(logTag) Applied next wallpaper '\(item.title)' to screen \(screenID)")
            } else {
                print("\(logTag) Failed to apply next wallpaper '\(item.title)' to screen \(screenID), trying next item")
                // 尝试其他可用项，避免因选中不支持的壁纸类型导致黑屏
                var remaining = items.filter { $0.id != item.id }
                while !remaining.isEmpty {
                    guard !Task.isCancelled,
                          self.onEndSwitchGeneration == generation,
                          !self.manualWallpaperApplyInFlight else {
                        return
                    }
                    guard let retryItem = selectNextItem(from: remaining, lastID: lastChangedItemID, screenID: screenID, order: order) else { break }
                    remaining.removeAll { $0.id == retryItem.id }
                    let retrySuccess = await applyItem(
                        retryItem,
                        toScreenID: screenID,
                        preferImmediatePresentation: preferImmediatePresentation
                    )
                    guard !Task.isCancelled,
                          self.onEndSwitchGeneration == generation,
                          !self.manualWallpaperApplyInFlight else {
                        return
                    }
                    if retrySuccess {
                        didApply = true
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
        onEndSwitchTasks[screenID] = task
    }

    private func finishOnEndSwitch(
        for screenID: String,
        requiredMode: RequiredSwitchMode?,
        applied: Bool
    ) {
        guard case .onEnd? = requiredMode else { return }
        onEndSwitchInFlightScreens.remove(screenID)
        // Only arm cooldown after a successful apply. Failed recovery should
        // allow the next real end event to try again immediately.
        if applied {
            onEndSwitchCooldownUntilByScreen[screenID] = Date().addingTimeInterval(onEndSwitchCooldown)
        } else {
            onEndSwitchCooldownUntilByScreen.removeValue(forKey: screenID)
        }
    }

    /// Global mode selects one candidate and commits it only after the
    /// coordinator has applied the same source to the full current screen set.
    private func applyNextGlobalWallpaper(
        requiredMode: RequiredSwitchMode?,
        overrideOrder: ScheduleOrder? = nil,
        preferImmediatePresentation: Bool = false
    ) {
        if case .onEnd? = requiredMode, manualWallpaperApplyInFlight {
            print("\(logTag) Skipping global on-end rotation: manual wallpaper setting in progress")
            return
        }
        guard globalRotationTask == nil else {
            if requiredMode == nil, !activeGlobalRotationIsManual {
                pendingManualGlobalRotation = PendingManualGlobalRotation(
                    overrideOrder: overrideOrder,
                    preferImmediatePresentation: preferImmediatePresentation
                )
                print("\(logTag) Queued manual global next after in-flight rotation")
            } else {
                print("\(logTag) Global rotation already in flight; coalescing trigger")
            }
            return
        }
        // 锁屏时丢弃的 on-end 事件记入重放队列，解锁后由 drainPendingOnEndSwitches 恢复。
        guard !isScreenLocked || requiredMode == nil else {
            if case .onEnd? = requiredMode {
                pendingOnEndSwitchScreenIDs.insert(globalSchedulerStateKey)
            }
            return
        }
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }

        let displayConfig = config.globalDisplayConfig
        if case .onEnd? = requiredMode,
           !(displayConfig.isEnabled && displayConfig.isOnEndMode) {
            return
        }
        if case .onEnd? = requiredMode,
           let cooldownUntil = globalOnEndSwitchCooldownUntil,
           Date() < cooldownUntil {
            print("\(logTag) Skip global on-end rotation: within post-switch cooldown")
            return
        }
        guard isManagedLibraryAvailable(forceRefresh: true) else {
            if case .onEnd? = requiredMode {
                VideoWallpaperManager.shared.resumeOnEndVideosAfterFailedGlobalSwitch(for: screens)
            }
            print("\(logTag) Skip global next wallpaper: managed library root unavailable")
            return
        }
        let items = getSchedulableItems(for: displayConfig)
        guard !items.isEmpty else {
            if case .onEnd? = requiredMode {
                VideoWallpaperManager.shared.resumeOnEndVideosAfterFailedGlobalSwitch(for: screens)
            }
            return
        }

        let order = overrideOrder ?? displayConfig.order
        guard let item = selectNextItem(
            from: items,
            lastID: lastChangedItemIDs[globalSchedulerStateKey],
            screenID: globalSchedulerStateKey,
            order: order
        ) else {
            return
        }

        let generation = globalRotationGeneration
        let immediate = preferImmediatePresentation
        activeGlobalRotationIsManual = preferImmediatePresentation
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.globalRotationGeneration == generation {
                    self.globalRotationTask = nil
                    self.activeGlobalRotationIsManual = false
                    // Re-arm one-shot timer after any global batch (timed or on-end
                    // with web/scene fallback). Event-only modes get nextFire=nil.
                    if self.isRunning {
                        self.scheduleNextChange()
                    }
                    if let pending = self.pendingManualGlobalRotation {
                        self.pendingManualGlobalRotation = nil
                        if self.config.isGlobalDisplaySyncEnabled {
                            DispatchQueue.main.async { [weak self] in
                                self?.applyNextGlobalWallpaper(
                                    requiredMode: nil,
                                    overrideOrder: pending.overrideOrder,
                                    preferImmediatePresentation: pending.preferImmediatePresentation
                                )
                            }
                        }
                    }
                }
            }

            let success = await self.applyItemGlobally(
                item,
                to: screens,
                preferImmediatePresentation: immediate
            )
            guard !Task.isCancelled,
                  self.globalRotationGeneration == generation,
                  self.config.isGlobalDisplaySyncEnabled else {
                print("\(self.logTag) Ignoring superseded global rotation result")
                return
            }
            guard success else {
                if case .onEnd? = requiredMode {
                    VideoWallpaperManager.shared.resumeOnEndVideosAfterFailedGlobalSwitch(for: screens)
                } else {
                    self.failedApplyRetryAfter[self.globalSchedulerStateKey] =
                        Date().addingTimeInterval(self.failedApplyRetryDelay)
                    print("\(self.logTag) Global apply failed, retry in \(Int(self.failedApplyRetryDelay))s")
                }
                return
            }

            self.failedApplyRetryAfter.removeValue(forKey: self.globalSchedulerStateKey)
            self.lastChangeTimes[self.globalSchedulerStateKey] = Date()
            self.lastChangedItemIDs[self.globalSchedulerStateKey] = item.id
            if case .onEnd? = requiredMode {
                self.globalOnEndSwitchCooldownUntil = Date().addingTimeInterval(self.onEndSwitchCooldown)
            }
            self.persistSchedulerState()
        }
        globalRotationTask = task
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
            self.cancelDispatchTimer()
            self.endSchedulerActivity()
            self.cancelTimedRotation()
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

    /// LockScreenWallpaperService 校正后的锁屏/唤醒状态（进程内通知）。
    /// 用于从「screenIsUnlocked 分布式通知丢失」的卡死中自愈：
    /// 服务侧有 250ms/750ms/1.5s 的 session 校正，状态比裸系统通知可靠。
    @objc private func handleLockScreenPlaybackStateDidChange(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let userInfo = notification.userInfo
            let locked = (userInfo?[LockScreenWallpaperService.lockedUserInfoKey] as? Bool)
                ?? LockScreenWallpaperService.shared.playbackState.isScreenLocked
            guard locked != self.isScreenLocked else { return }
            if locked {
                self.isScreenLocked = true
                self.cancelDispatchTimer()
                self.endSchedulerActivity()
                self.cancelTimedRotation()
                print("\(self.logTag) Playback state: screen locked, pausing scheduler")
            } else {
                self.isScreenLocked = false
                print("\(self.logTag) Playback state: screen unlocked (healing scheduler state)")
                self.drainPendingOnEndSwitches()
                self.changeUnlockWallpapersIfNeeded()
                if self.isRunning {
                    self.scheduleNextChange()
                }
            }
        }
    }

    /// 重放锁屏期间被丢弃的「播完即换」事件。
    /// 观察者在事件触发时已经 pause + seek(0)，如果只丢弃不重放，
    /// 对应屏幕会永远停在封面帧上（动态锁屏用户频繁锁屏时极易命中）。
    private func drainPendingOnEndSwitches() {
        guard !pendingOnEndSwitchScreenIDs.isEmpty else { return }
        let screenIDs = pendingOnEndSwitchScreenIDs
        pendingOnEndSwitchScreenIDs = []
        if let globalIndex = screenIDs.firstIndex(of: globalSchedulerStateKey) {
            var perScreen = screenIDs
            perScreen.remove(at: globalIndex)
            if config.isGlobalDisplaySyncEnabled {
                print("\(logTag) Replaying global on-end switch dropped while locked")
                applyNextGlobalWallpaper(requiredMode: .onEnd)
            }
            for screenID in perScreen.sorted() {
                print("\(logTag) Replaying on-end switch dropped while locked for \(screenID)")
                applyNextWallpaper(for: screenID, requiredMode: .onEnd)
            }
            return
        }
        for screenID in screenIDs.sorted() {
            print("\(logTag) Replaying on-end switch dropped while locked for \(screenID)")
            applyNextWallpaper(for: screenID, requiredMode: .onEnd)
        }
    }

    /// 自愈：若 unlock 通知丢失导致 isScreenLocked 卡死，调度定时器路径可主动恢复。
    private func clearStuckScreenLockIfNeeded(source: String) {
        guard isScreenLocked else { return }
        // 用户能点到状态栏菜单 / 定时器在跑，说明会话通常已解锁。
        isScreenLocked = false
        print("\(logTag) Self-healed stuck isScreenLocked via \(source)")
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
                self.cancelTimedRotation()
                if self.isRunning {
                    self.scheduleNextChange()
                }
            }
            self.pendingCleanupWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
        }
    }

    @objc private func handleManagedLibraryChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.managedLibraryRootAvailability = nil
            self.unavailableLibraryRetryUntil = nil
            self.unavailableSchedulableItemIDs.removeAll()
            if self.isRunning {
                self.scheduleNextChange()
            }
        }
    }

    private func cleanupOrphanedScreenState() {
        var currentScreenIDs = Set(NSScreen.screens.map { $0.wallpaperScreenIdentifier })
        currentScreenIDs.insert(globalSchedulerStateKey)

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

        let orphanedRetryKeys = Set(failedApplyRetryAfter.keys).subtracting(currentScreenIDs)
        for screenID in orphanedRetryKeys {
            failedApplyRetryAfter.removeValue(forKey: screenID)
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
        let currentScreens = NSScreen.screensOrderedForDisplay
        let currentScreenIDs = Set(currentScreens.map(\.wallpaperScreenIdentifier))

        // Find orphaned config keys — screen IDs that were in displayConfigs but are no longer present
        var orphanedIDs = Set(config.displayConfigs.keys).subtracting(currentScreenIDs)
        guard !orphanedIDs.isEmpty else { return }

        var claimedTargets = Set(config.displayConfigs.keys).intersection(currentScreenIDs)
        var migratedCount = 0

        // 第一轮：唯一精确/松散匹配（含 position 的新指纹通常走这里）
        for orphanedID in orphanedIDs.sorted() {
            guard let orphanedConfig = config.displayConfigs[orphanedID],
                  let fingerprint = displayFingerprints[orphanedID],
                  let newScreenID = resolveScreenID(
                    forFingerprint: fingerprint,
                    among: currentScreens,
                    excluding: claimedTargets
                  ) else {
                continue
            }

            applyDisplayConfigMigration(
                orphanedID: orphanedID,
                orphanedConfig: orphanedConfig,
                fingerprint: fingerprint,
                newScreenID: newScreenID,
                currentScreens: currentScreens
            )
            claimedTargets.insert(newScreenID)
            orphanedIDs.remove(orphanedID)
            migratedCount += 1
        }

        // 第二轮：旧版无序列号短指纹会同时命中多块同型号屏。
        // 按「硬件身份」分组后，将 orphan 与空闲屏各自按稳定顺序 1:1 zip，
        // 避免随机 .first 把显示器 2/3 配置互换。
        if !orphanedIDs.isEmpty {
            let freeScreens = currentScreens.filter {
                !claimedTargets.contains($0.wallpaperScreenIdentifier)
            }
            var freeByHardware: [String: [NSScreen]] = [:]
            for screen in freeScreens {
                freeByHardware[hardwareIdentityKey(for: screen), default: []].append(screen)
            }

            var orphansByHardware: [String: [String]] = [:]
            for orphanedID in orphanedIDs {
                guard let fingerprint = displayFingerprints[orphanedID] else { continue }
                orphansByHardware[hardwareIdentityKey(forFingerprint: fingerprint), default: []].append(orphanedID)
            }

            for hardwareKey in orphansByHardware.keys.sorted() {
                guard var orphanGroup = orphansByHardware[hardwareKey],
                      let freeGroup = freeByHardware[hardwareKey],
                      !freeGroup.isEmpty else { continue }
                orphanGroup.sort()
                // freeGroup 已来自 screensOrderedForDisplay 的稳定顺序
                let pairCount = min(orphanGroup.count, freeGroup.count)
                for i in 0..<pairCount {
                    let orphanedID = orphanGroup[i]
                    let target = freeGroup[i]
                    let newScreenID = target.wallpaperScreenIdentifier
                    guard let orphanedConfig = config.displayConfigs[orphanedID] else { continue }
                    let fingerprint = displayFingerprints[orphanedID] ?? target.schedulerConfigFingerprint
                    applyDisplayConfigMigration(
                        orphanedID: orphanedID,
                        orphanedConfig: orphanedConfig,
                        fingerprint: fingerprint,
                        newScreenID: newScreenID,
                        currentScreens: currentScreens
                    )
                    claimedTargets.insert(newScreenID)
                    orphanedIDs.remove(orphanedID)
                    migratedCount += 1
                }
            }
        }

        if migratedCount > 0 {
            saveConfig()
            saveDisplayFingerprints()
            print("\(logTag) Relinked \(migratedCount) display config(s) by fingerprint after screen change")
        }
    }

    private func applyDisplayConfigMigration(
        orphanedID: String,
        orphanedConfig: DisplaySchedulerConfig,
        fingerprint: String,
        newScreenID: String,
        currentScreens: [NSScreen]
    ) {
        config.displayConfigs[newScreenID] = orphanedConfig
        config.displayConfigs.removeValue(forKey: orphanedID)
        displayFingerprints.removeValue(forKey: orphanedID)
        if let screen = currentScreens.first(where: { $0.wallpaperScreenIdentifier == newScreenID }) {
            displayFingerprints[newScreenID] = screen.schedulerConfigFingerprint
        } else {
            displayFingerprints[newScreenID] = fingerprint
        }
    }

    /// 用于同型号双屏分组：去掉 position 后缀，并尽量归一化到 vendor/model/name 粒度。
    private func hardwareIdentityKey(for screen: NSScreen) -> String {
        hardwareIdentityKey(forFingerprint: screen.externalConnectionFingerprint)
    }

    private func hardwareIdentityKey(forFingerprint fingerprint: String) -> String {
        var key = fingerprint
        if let range = key.range(of: ":position:") {
            key = String(key[..<range.lowerBound])
        }
        // 去掉分辨率段（旧 wallpaper 指纹：…:WxH:builtin）
        // cg:v:m:noserial:name:2560x1440:external → cg:v:m:noserial:name:external
        if let regex = try? NSRegularExpression(pattern: #":\d+x\d+(?=:)"#),
           regex.firstMatch(in: key, range: NSRange(key.startIndex..., in: key)) != nil {
            key = regex.stringByReplacingMatches(
                in: key,
                range: NSRange(key.startIndex..., in: key),
                withTemplate: ""
            )
        }
        return key
    }

    private func existingConfigScreenID(for screen: NSScreen) -> String? {
        let currentID = screen.wallpaperScreenIdentifier
        if config.displayConfigs[currentID] != nil {
            return currentID
        }

        let candidates = screen.schedulerFingerprintCandidates
        let matches = displayFingerprints.filter { key, fingerprint in
            config.displayConfigs[key] != nil && candidates.contains(fingerprint)
        }

        // 精确指纹优先（含位置）；同型号无序列号时旧短指纹可能命中多条，绝不能 .first 随机挑。
        if let exact = matches.first(where: { $0.value == screen.wallpaperScreenFingerprint })?.key {
            return exact
        }
        if matches.count == 1, let only = matches.keys.first {
            return only
        }
        return nil
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
        let currentScreens = NSScreen.screensOrderedForDisplay
        let currentScreenIDs = Set(currentScreens.map(\.wallpaperScreenIdentifier))

        let orphanedIDs = Set(lastChangedItemIDs.keys)
            .union(lastChangeTimes.keys)
            .union(usedItemIDs.keys)
            .subtracting(currentScreenIDs)
            .subtracting([globalSchedulerStateKey])
        guard !orphanedIDs.isEmpty else { return }

        // 已有运行时状态的屏先占位，避免两块同型号屏的 orphan 状态互换。
        var claimedTargets = Set(
            currentScreenIDs.filter {
                lastChangedItemIDs[$0] != nil || lastChangeTimes[$0] != nil || usedItemIDs[$0] != nil
            }
        )
        var migratedCount = 0

        for orphanedID in orphanedIDs.sorted() {
            guard let fingerprint = previousFingerprints[orphanedID],
                  let newScreenID = resolveScreenID(
                    forFingerprint: fingerprint,
                    among: currentScreens,
                    excluding: claimedTargets
                  ),
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

            claimedTargets.insert(newScreenID)
        }

        if migratedCount > 0 {
            persistSchedulerState()
            print("\(logTag) Relinked scheduler state by fingerprint (\(migratedCount) migrated value(s))")
        }
    }

    /// 在当前屏幕列表中按指纹找回目标屏。优先精确匹配；旧版无 position 的短指纹
    /// 若命中多块同型号屏，只在「唯一未占用」时才绑定，避免 2/3 配置互换。
    private func resolveScreenID(
        forFingerprint fingerprint: String,
        among screens: [NSScreen],
        excluding claimedTargets: Set<String>
    ) -> String? {
        let exactMatches = screens.filter { screen in
            let id = screen.wallpaperScreenIdentifier
            guard !claimedTargets.contains(id) else { return false }
            return screen.schedulerFingerprintCandidates.contains(fingerprint)
                || screen.wallpaperScreenFingerprint == fingerprint
                || screen.schedulerConfigFingerprint == fingerprint
                || screen.legacyWallpaperScreenFingerprint == fingerprint
                || screen.externalConnectionFingerprint == fingerprint
        }

        if exactMatches.count == 1 {
            return exactMatches[0].wallpaperScreenIdentifier
        }

        // 短指纹（无 position）可能同时命中两块同型号屏：只接受唯一未占用目标。
        let available = exactMatches.map(\.wallpaperScreenIdentifier)
        if available.count == 1 {
            return available[0]
        }

        // 模糊匹配：历史 fingerprint 与当前候选有公共前缀（旧 noserial 无 position）。
        if exactMatches.isEmpty {
            let fuzzy = screens.filter { screen in
                let id = screen.wallpaperScreenIdentifier
                guard !claimedTargets.contains(id) else { return false }
                return screen.schedulerFingerprintCandidates.contains { candidate in
                    fingerprintsLooselyMatch(fingerprint, candidate)
                }
            }
            if fuzzy.count == 1 {
                return fuzzy[0].wallpaperScreenIdentifier
            }
        }

        return nil
    }

    private func fingerprintsLooselyMatch(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        // 新指纹 = 旧指纹 + ":position:..."
        if lhs.hasPrefix(rhs + ":position:") || rhs.hasPrefix(lhs + ":position:") {
            return true
        }
        // 去掉 position 后缀后比较
        let strip: (String) -> String = { value in
            if let range = value.range(of: ":position:") {
                return String(value[..<range.lowerBound])
            }
            return value
        }
        return strip(lhs) == strip(rhs)
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

    /// 用户开始应用壁纸前调用：取消已经排队/在途的自动切换，避免它在用户操作
    /// 期间覆盖手动选择。成功/失败后的时间状态由 completeManualWallpaperApply 处理。
    @MainActor
    func beginManualWallpaperApply() async {
        var tasksToDrain: [Task<Void, Never>] = []
        if let timedRotationTask {
            tasksToDrain.append(timedRotationTask)
        }
        if let globalRotationTask {
            tasksToDrain.append(globalRotationTask)
        }
        if let displayModeTransitionTask {
            tasksToDrain.append(displayModeTransitionTask)
        }
        tasksToDrain.append(contentsOf: onEndSwitchTasks.values)

        manualWallpaperApplyInFlight = true
        cancelDispatchTimer()
        cancelTimedRotation()
        pendingOnEndSwitchScreenIDs.removeAll()

        globalRotationGeneration &+= 1
        globalRotationTask?.cancel()
        globalRotationTask = nil
        activeGlobalRotationIsManual = false
        pendingManualGlobalRotation = nil
        displayModeTransitionGeneration &+= 1
        displayModeTransitionTask?.cancel()
        displayModeTransitionTask = nil
        onEndSwitchGeneration &+= 1
        onEndSwitchTasks.removeAll()
        onEndSwitchInFlightScreens.removeAll()
        onEndSwitchCooldownUntilByScreen.removeAll()
        globalOnEndSwitchCooldownUntil = nil
        for task in tasksToDrain {
            task.cancel()
            await task.value
        }

        print("\(logTag) Manual wallpaper apply started; auto-switch work cancelled")
    }

    /// 用户壁纸应用完成后调用：成功时按当前调度模式重置对应状态，失败时仅恢复
    /// 调度器，不把一次失败的手动操作误记成最近一次壁纸切换。
    @MainActor
    func completeManualWallpaperApply(success: Bool, screenIDs: Set<String>) {
        manualWallpaperApplyInFlight = false
        guard success else {
            if isRunning {
                scheduleNextChange()
            }
            print("\(logTag) Manual wallpaper apply failed; auto-switch timers restored")
            return
        }

        let now = Date()
        if config.isGlobalDisplaySyncEnabled {
            lastChangeTimes[globalSchedulerStateKey] = now
            failedApplyRetryAfter.removeValue(forKey: globalSchedulerStateKey)
        } else {
            let currentScreenIDs = Set(NSScreen.screens.map(\.wallpaperScreenIdentifier))
            let targetIDs = screenIDs.isEmpty
                ? currentScreenIDs
                : screenIDs.intersection(currentScreenIDs)
            for screenID in targetIDs {
                lastChangeTimes[screenID] = now
                failedApplyRetryAfter.removeValue(forKey: screenID)
            }
        }
        persistSchedulerState()
        if isRunning {
            scheduleNextChange()
        }
        print("\(logTag) Manual wallpaper applied; auto-switch timers reset")
    }

    // MARK: - Control

    func start() {
        guard !isRunning else { return }
        isRunning = true
        // Anchor missing last-change times so the first switch waits a full interval
        // (matches previous repeating-timer behavior) instead of firing immediately.
        seedMissingLastChangeTimesIfNeeded()
        restoreUserSuppressedScreensIfNeeded()
        scheduleNextChange()
        saveConfig()
        let delayDesc: String
        if let next = nextTimerFireDate(from: Date()) {
            delayDesc = String(format: "%.1fs", max(0, next.timeIntervalSinceNow))
        } else {
            delayDesc = "none (event-driven)"
        }
        print("\(logTag) Started. Next check: \(delayDesc)")
    }

    /// When a timed display has never recorded a switch, treat "now" as the start
    /// of the interval so enabling auto-switch does not instantly replace the wallpaper.
    private func seedMissingLastChangeTimesIfNeeded(now: Date = Date()) {
        var didSeed = false
        if config.isGlobalDisplaySyncEnabled {
            if timedIntervalSeconds(for: config.globalDisplayConfig) != nil,
               lastChangeTimes[globalSchedulerStateKey] == nil {
                lastChangeTimes[globalSchedulerStateKey] = now
                didSeed = true
            }
        } else {
            for screen in NSScreen.screens {
                let screenID = screen.wallpaperScreenIdentifier
                let displayConfig = resolvedDisplayConfig(for: screen)
                guard timedIntervalSeconds(for: displayConfig) != nil else { continue }
                guard lastChangeTimes[screenID] == nil else { continue }
                lastChangeTimes[screenID] = now
                didSeed = true
            }
        }
        if didSeed {
            persistSchedulerState()
        }
    }

    // MARK: - 手动关闭抑制

    /// 从 UserDefaults 恢复抑制标记（跨启动保持「用户主动关闭」语义）。
    private func restoreUserSuppressedScreensIfNeeded() {
        guard userSuppressedScreenIDs.isEmpty else { return }
        if let ids = UserDefaults.standard.stringArray(forKey: userSuppressedScreensKey) {
            userSuppressedScreenIDs = Set(ids)
        }
    }

    private func persistUserSuppressedScreens() {
        UserDefaults.standard.set(Array(userSuppressedScreenIDs), forKey: userSuppressedScreensKey)
    }

    /// 该屏被抑制时：若已有活跃动态壁纸（用户手动开启/设置）则解除抑制并返回 false，否则返回 true。
    private func isSuppressedForScheduling(screen: NSScreen, stateKey: String) -> Bool {
        guard userSuppressedScreenIDs.contains(stateKey) else { return false }
        let live = VideoWallpaperManager.shared.hasActiveWallpaper(on: screen)
            || WallpaperEngineXBridge.shared.hasLivePresentation(on: screen)
        if live {
            userSuppressedScreenIDs.remove(stateKey)
            persistUserSuppressedScreens()
            print("\(logTag) Auto-switch suppression lifted for screen \(stateKey): wallpaper live again")
            return false
        }
        return true
    }

    /// 用户手动关闭壁纸后调用：抑制该屏的定时轮换，防止调度器把刚关掉的壁纸自动拉起。
    func suppressAutoSwitch(forScreen screen: NSScreen) {
        userSuppressedScreenIDs.insert(screen.wallpaperScreenIdentifier)
        persistUserSuppressedScreens()
        print("\(logTag) Auto-switch suppressed by manual stop: \(screen.localizedName)")
    }

    /// 全局同步模式下手动关闭后抑制全局轮换入口。
    func suppressAutoSwitchGlobally() {
        userSuppressedScreenIDs.insert(globalSchedulerStateKey)
        persistUserSuppressedScreens()
        print("\(logTag) Global auto-switch suppressed by manual stop")
    }

    func stop() {
        cancelDispatchTimer()
        endSchedulerActivity()
        cancelTimedRotation()
        failedApplyRetryAfter.removeAll()
        isRunning = false
        saveConfig()
        // 停止时保留持久化状态，以便重新启用时继续上轮随机进度
        persistSchedulerState()
        print("\(logTag) Stopped.")
    }

    /// 手动设置壁纸后调用：重置该屏幕的调度计时器，避免刚设置完就被自动切换覆盖。
    /// - Parameter screenID: 被手动设置壁纸的屏幕标识符；nil 表示重置所有屏幕。
    func notifyManualWallpaperChange(screenID: String? = nil) {
        manualWallpaperApplyInFlight = false
        cancelTimedRotation()
        let now = Date()
        if config.isGlobalDisplaySyncEnabled {
            lastChangeTimes[globalSchedulerStateKey] = now
            failedApplyRetryAfter.removeValue(forKey: globalSchedulerStateKey)
        } else if let screenID = screenID {
            lastChangeTimes[screenID] = now
            failedApplyRetryAfter.removeValue(forKey: screenID)
        } else {
            for screen in NSScreen.screens {
                let id = screen.wallpaperScreenIdentifier
                lastChangeTimes[id] = now
                failedApplyRetryAfter.removeValue(forKey: id)
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
        // 根据各屏启用的内容类型校验 folderIDs：移除属于已关闭类型
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
        validated.globalDisplayConfig.folderIDs = validatedFolderIDs(
            validated.globalDisplayConfig.folderIDs,
            displayConfig: validated.globalDisplayConfig
        )
        config = validated
        saveConfig()
        if isRunning {
            stop()
        }
        if hasAnyEnabledDisplay {
            start()
        }
    }

    /// 校验 folderIDs 是否仍属于当前启用的内容类型。
    /// - 已删除（在两类文件夹存储中均查不到）的 ID 一并剔除。
    /// - 全部失效时返回 nil（等价于"全部"），避免空过滤把候选清空。
    private func validatedFolderIDs(_ folderIDs: [String]?, displayConfig: DisplaySchedulerConfig) -> [String]? {
        guard let folderIDs, !folderIDs.isEmpty else { return folderIDs }
        let includeWallpapers = displayConfig.includeWallpapers
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
        if config.isGlobalDisplaySyncEnabled {
            return config.globalDisplayConfig.isEnabled
                && !NSScreen.screens.isEmpty
        }
        return NSScreen.screens.contains { screen in
            resolvedDisplayConfig(for: screen).isEnabled
        }
    }

    // MARK: - Per-Display Updates

    func updateGlobalDisplaySyncEnabled(_ enabled: Bool) {
        guard config.isGlobalDisplaySyncEnabled != enabled else { return }

        displayModeTransitionGeneration &+= 1
        let transitionGeneration = displayModeTransitionGeneration
        displayModeTransitionTask?.cancel()
        displayModeTransitionTask = nil

        if enabled {
            var newConfig = config
            newConfig.isGlobalDisplaySyncEnabled = true
            updateConfig(newConfig)
            GlobalWallpaperSyncCoordinator.shared.synchronizeCurrentWallpaperAfterEnabling()
            return
        }

        // 先让旧全局选片任务失效；其底层全局事务会在异步切换阶段完整收尾。
        globalRotationGeneration &+= 1
        let supersededGlobalTask = globalRotationTask
        supersededGlobalTask?.cancel()
        globalRotationTask = nil
        activeGlobalRotationIsManual = false
        pendingManualGlobalRotation = nil
        globalOnEndSwitchCooldownUntil = nil
        failedApplyRetryAfter.removeValue(forKey: globalSchedulerStateKey)

        var newConfig = config
        newConfig.isGlobalDisplaySyncEnabled = false
        updateConfig(newConfig)

        // updateConfig 会按独立配置启动计时器；模式切换完成前先阻止它抢跑。
        cancelDispatchTimer()
        endSchedulerActivity()
        cancelTimedRotation()

        displayModeTransitionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard !Task.isCancelled,
                  self.displayModeTransitionGeneration == transitionGeneration,
                  !self.config.isGlobalDisplaySyncEnabled else { return }

            // 等待已开始的全局事务结束，避免它在各屏重选后又覆盖全部屏幕。
            await GlobalWallpaperSyncCoordinator.shared.drainBeforeLeavingGlobalMode()
            if let supersededGlobalTask {
                await supersededGlobalTask.value
            }

            guard !Task.isCancelled,
                  self.displayModeTransitionGeneration == transitionGeneration,
                  !self.config.isGlobalDisplaySyncEnabled else { return }

            // 先把当前共享 AVPlayer 拆成各屏独立播放器；未启用调度的屏幕保留当前画面。
            if let primary = NSScreen.screensOrderedForDisplay.first,
               VideoWallpaperManager.shared.isVideoWallpaperActive {
                VideoWallpaperManager.shared.setSharedDecoderPlaybackEnabled(
                    false,
                    sourceScreen: primary
                )
            }

            await self.applyIndependentSelectionsAfterGlobalDisable(
                transitionGeneration: transitionGeneration
            )

            guard self.displayModeTransitionGeneration == transitionGeneration,
                  !self.config.isGlobalDisplaySyncEnabled else { return }
            self.displayModeTransitionTask = nil
            if self.isRunning {
                self.scheduleNextChange()
            }
        }
    }

    /// 按每块显示器已保存的启用状态、内容范围、文件夹过滤和顺序立即重选一次。
    private func applyIndependentSelectionsAfterGlobalDisable(
        transitionGeneration: UInt64
    ) async {
        guard isManagedLibraryAvailable(forceRefresh: true) else {
            print("\(logTag) Global sync disabled: managed library root unavailable")
            return
        }

        for screen in NSScreen.screensOrderedForDisplay {
            guard !Task.isCancelled,
                  displayModeTransitionGeneration == transitionGeneration,
                  !config.isGlobalDisplaySyncEnabled else { return }

            let screenID = screen.wallpaperScreenIdentifier
            let displayConfig = resolvedDisplayConfig(for: screen)
            guard displayConfig.isEnabled else {
                print("\(logTag) Global sync disabled: scheduler remains off for \(screen.localizedName)")
                continue
            }

            let items = getSchedulableItems(for: displayConfig)
            guard let item = selectNextItem(
                from: items,
                lastID: lastChangedItemIDs[screenID],
                screenID: screenID,
                order: displayConfig.order
            ) else {
                print("\(logTag) Global sync disabled: no candidate for \(screen.localizedName)")
                continue
            }

            let success = await applyItem(item, toScreenID: screenID)
            guard displayModeTransitionGeneration == transitionGeneration,
                  !config.isGlobalDisplaySyncEnabled else { return }
            if success {
                lastChangeTimes[screenID] = Date()
                lastChangedItemIDs[screenID] = item.id
                failedApplyRetryAfter.removeValue(forKey: screenID)
                print("\(logTag) Activated independent scheduler for \(screen.localizedName): \(item.title)")
            } else {
                failedApplyRetryAfter[screenID] = Date().addingTimeInterval(failedApplyRetryDelay)
                print("\(logTag) Failed initial independent selection for \(screen.localizedName)")
            }
        }
        persistSchedulerState()
    }

    func updateGlobalDisplayEnabled(_ enabled: Bool) {
        let wasUsingOnEndPlayback = config.globalDisplayConfig.isEnabled
            && config.globalDisplayConfig.isOnEndMode
        updateGlobalDisplayConfig { $0.isEnabled = enabled }
        let isUsingOnEndPlayback = config.globalDisplayConfig.isEnabled
            && config.globalDisplayConfig.isOnEndMode
        if wasUsingOnEndPlayback != isUsingOnEndPlayback {
            reconfigureCurrentGlobalVideoForScheduling()
        }
    }

    func updateGlobalDisplayInterval(_ minutes: Int) {
        let wasOnEndMode = config.globalDisplayConfig.isOnEndMode
        updateGlobalDisplayConfig { $0.intervalMinutes = minutes }
        if wasOnEndMode != config.globalDisplayConfig.isOnEndMode {
            reconfigureCurrentGlobalVideoForScheduling()
        }
    }

    func updateGlobalDisplayOrder(_ order: ScheduleOrder) {
        updateGlobalDisplayConfig { $0.order = order }
    }

    func updateGlobalDisplayIncludeWallpapers(_ include: Bool) {
        updateGlobalDisplayConfig { $0.includeWallpapers = include }
    }

    func updateGlobalDisplayIncludeMedia(_ include: Bool) {
        updateGlobalDisplayConfig { $0.includeMedia = include }
    }

    func updateGlobalDisplayFolderIDs(_ folderIDs: [String]?) {
        updateGlobalDisplayConfig { $0.folderIDs = folderIDs }
    }

    func updateGlobalDisplayWebSceneSwitchSeconds(_ seconds: Int?) {
        updateGlobalDisplayConfig { $0.webSceneSwitchSeconds = seconds }
    }

    private func updateGlobalDisplayConfig(_ mutate: (inout DisplaySchedulerConfig) -> Void) {
        var newConfig = config
        mutate(&newConfig.globalDisplayConfig)
        updateConfig(newConfig)
    }

    /// An existing AVPlayerLooper cannot change into non-looping playback by
    /// configuration alone. Rebuild the global player whenever the scheduling
    /// mode crosses the play-to-end boundary.
    private func reconfigureCurrentGlobalVideoForScheduling() {
        guard config.isGlobalDisplaySyncEnabled,
              let videoURL = VideoWallpaperManager.shared.currentVideoURL,
              FileManager.default.fileExists(atPath: videoURL.path) else {
            return
        }

        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        let posterURL = VideoWallpaperManager.shared.currentPosterURL
        Task { @MainActor in
            do {
                try await VideoWallpaperManager.shared.applyVideoWallpaper(
                    from: videoURL,
                    posterURL: posterURL,
                    muted: VideoWallpaperManager.shared.isMuted,
                    targetScreens: screens,
                    animatedTransition: false,
                    usesSharedVideoDecoder: screens.count > 1,
                    forceRebuild: true
                )
                print("\(logTag) Reconfigured global video playback for scheduler mode")
            } catch {
                print("\(logTag) Failed to reconfigure global video playback: \(error.localizedDescription)")
            }
        }
    }

    /// 进入播完即换：把当前视频重建为非循环并挂播放结束观察者；
    /// 无本机视频时自动选取一个开始播放。
    /// AVPlayerLooper 无法仅改配置变成非循环，与全局路径
    /// reconfigureCurrentGlobalVideoForScheduling 同理，必须 forceRebuild。
    private func enterOnEndPlaybackNow(for screenID: String) {
        guard let screen = NSScreen.screens.first(where: { $0.wallpaperScreenIdentifier == screenID }) else {
            print("\(logTag) ⚠️ Could not find screen with ID \(screenID) to apply on-end mode")
            return
        }
        Task { @MainActor in
            // 检查是否是 Web 壁纸（由 WallpaperEngineXBridge 管理）
            let isWebWallpaper = WallpaperEngineXBridge.shared.isManaging(screen: screen)
            let hasVideo = VideoWallpaperManager.shared.hasActiveWallpaper(on: screen)
            print("\(logTag) Screen \(screenID) state: isWeb=\(isWebWallpaper), hasVideo=\(hasVideo)")

            // 已有本机视频壁纸：重新应用以禁用循环（播完即换非循环模式）
            if hasVideo, let videoURL = VideoWallpaperManager.shared.videoURL(for: screen) {
                let posterURL = VideoWallpaperManager.shared.posterURL(for: screen)
                print("\(logTag) Reapplying video wallpaper with forceRebuild to disable looping: \(videoURL.lastPathComponent)")
                try? await VideoWallpaperManager.shared.applyVideoWallpaper(
                    from: videoURL,
                    posterURL: posterURL,
                    muted: VideoWallpaperManager.shared.isMuted,
                    targetScreen: screen,
                    forceRebuild: true
                )
                print("\(logTag) ✅ On-end mode active, reapplied wallpaper for screen \(screenID)")
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

    /// 写入前把「当前 screenID」规范到真实配置 key。
    /// sleep/wake 后 UI 传来的是新 NSScreenNumber，但配置可能仍在旧 id 下；
    /// 若不迁移就直接写，会留下双份配置并在设置页看起来像 2/3 对调。
    private func canonicalDisplayConfigScreenID(_ screenID: String) -> String {
        if config.displayConfigs[screenID] != nil {
            if let screen = NSScreen.screens.first(where: { $0.wallpaperScreenIdentifier == screenID }) {
                displayFingerprints[screenID] = screen.schedulerConfigFingerprint
            }
            return screenID
        }
        guard let screen = NSScreen.screens.first(where: { $0.wallpaperScreenIdentifier == screenID }),
              let existing = existingConfigScreenID(for: screen),
              existing != screenID,
              config.displayConfigs[existing] != nil else {
            return screenID
        }
        migrateDisplayConfig(from: existing, to: screen)
        return screen.wallpaperScreenIdentifier
    }

    func updateDisplayEnabled(_ enabled: Bool, for screenID: String) {
        let screenID = canonicalDisplayConfigScreenID(screenID)
        var newConfig = config
        var displayConfig = newConfig.storedDisplayConfig(for: screenID)
        let wasUsingOnEndPlayback = displayConfig.isEnabled && displayConfig.isOnEndMode
        displayConfig.isEnabled = enabled
        newConfig.displayConfigs[screenID] = displayConfig
        updateConfig(newConfig)
        let isUsingOnEndPlayback = displayConfig.isEnabled && displayConfig.isOnEndMode

        if !enabled {
            if let screen = NSScreen.screens.first(where: { $0.wallpaperScreenIdentifier == screenID }) {
                if wasUsingOnEndPlayback, let videoURL = VideoWallpaperManager.shared.videoURL(for: screen) {
                    // "播完即换"模式下关闭自动切换：重新应用当前视频并启用循环播放，
                    // 让视频继续播放而不是直接停掉整个动态壁纸
                    Task { @MainActor in
                        let posterURL = VideoWallpaperManager.shared.posterURL(for: screen)
                        try? await VideoWallpaperManager.shared.applyVideoWallpaper(
                            from: videoURL,
                            posterURL: posterURL,
                            muted: VideoWallpaperManager.shared.isMuted,
                            targetScreen: screen,
                            forceRebuild: true
                        )
                        print("\(logTag) Auto-switch disabled for screen \(screenID) (was on-end mode), re-enabled looping")
                    }
                } else {
                    // 普通定时模式下关闭自动切换：停止定时器即可，不关闭动态壁纸
                    print("\(logTag) Auto-switch disabled for screen \(screenID), video wallpaper kept running")
                }
            }
        } else if !wasUsingOnEndPlayback && isUsingOnEndPlayback {
            // 开启自动切换且已是播完即换：当前视频仍是循环播放（未挂播完观察者），
            // 不重建的话播完即换永远不触发（与全局路径 updateGlobalDisplayEnabled 对齐）。
            enterOnEndPlaybackNow(for: screenID)
        }
    }

    func updateDisplayInterval(_ minutes: Int, for screenID: String) {
        let screenID = canonicalDisplayConfigScreenID(screenID)
        var newConfig = config
        var displayConfig = newConfig.storedDisplayConfig(for: screenID)
        let wasOnEndMode = displayConfig.isOnEndMode
        displayConfig.intervalMinutes = minutes
        let isNowOnEndMode = minutes == SchedulerConfig.intervalOnEndMinutes
        newConfig.displayConfigs[screenID] = displayConfig
        updateConfig(newConfig)

        // 如果切换到"播完即换"模式，需要重新应用壁纸以启用非循环播放器。
        // 仅在自动切换已开启时立即重建；未开启时由 updateDisplayEnabled 的开启路径
        // 统一处理，避免禁用状态下做一次循环模式不变的无谓重建。
        if !wasOnEndMode && isNowOnEndMode {
            print("\(logTag) Detected switch to on-end mode for screen \(screenID)")
            if displayConfig.isEnabled {
                enterOnEndPlaybackNow(for: screenID)
            }
        } else if wasOnEndMode && !isNowOnEndMode {
            // 如果从"播完即换"模式切换回来，需要重新启用循环播放
            if displayConfig.isEnabled,
               let screen = NSScreen.screens.first(where: { $0.wallpaperScreenIdentifier == screenID }) {
                Task { @MainActor in
                    if let videoURL = VideoWallpaperManager.shared.videoURL(for: screen) {
                        let posterURL = VideoWallpaperManager.shared.posterURL(for: screen)
                        try? await VideoWallpaperManager.shared.applyVideoWallpaper(
                            from: videoURL,
                            posterURL: posterURL,
                            muted: VideoWallpaperManager.shared.isMuted,
                            targetScreen: screen,
                            forceRebuild: true
                        )
                        print("\(logTag) Switched from on-end mode, reapplied wallpaper with looping for screen \(screenID)")
                    }
                }
            }
        }
    }

    func updateDisplayOrder(_ order: ScheduleOrder, for screenID: String) {
        let screenID = canonicalDisplayConfigScreenID(screenID)
        var newConfig = config
        var displayConfig = newConfig.storedDisplayConfig(for: screenID)
        displayConfig.order = order
        newConfig.displayConfigs[screenID] = displayConfig
        updateConfig(newConfig)
    }

    func updateDisplayIncludeWallpapers(_ include: Bool, for screenID: String) {
        let screenID = canonicalDisplayConfigScreenID(screenID)
        var newConfig = config
        var displayConfig = newConfig.storedDisplayConfig(for: screenID)
        displayConfig.includeWallpapers = include
        newConfig.displayConfigs[screenID] = displayConfig
        updateConfig(newConfig)
    }

    func updateDisplayIncludeMedia(_ include: Bool, for screenID: String) {
        let screenID = canonicalDisplayConfigScreenID(screenID)
        var newConfig = config
        var displayConfig = newConfig.storedDisplayConfig(for: screenID)
        displayConfig.includeMedia = include
        newConfig.displayConfigs[screenID] = displayConfig
        updateConfig(newConfig)
    }

    func updateDisplayFolderIDs(_ folderIDs: [String]?, for screenID: String) {
        let screenID = canonicalDisplayConfigScreenID(screenID)
        var newConfig = config
        var displayConfig = newConfig.storedDisplayConfig(for: screenID)
        displayConfig.folderIDs = folderIDs
        newConfig.displayConfigs[screenID] = displayConfig
        updateConfig(newConfig)
    }

    func updateDisplayWebSceneSwitchSeconds(_ seconds: Int?, for screenID: String) {
        let screenID = canonicalDisplayConfigScreenID(screenID)
        var newConfig = config
        var displayConfig = newConfig.storedDisplayConfig(for: screenID)
        displayConfig.webSceneSwitchSeconds = seconds
        newConfig.displayConfigs[screenID] = displayConfig
        updateConfig(newConfig)
    }

    /// 外接显示器变更后，重新把当前全局壁纸覆盖到完整的屏幕集合。
    /// 调度器只发起统一应用；媒体类型分发不在此处实现。
    func synchronizeCurrentGlobalWallpaperToConnectedDisplays() {
        guard config.isGlobalDisplaySyncEnabled else { return }
        if VideoWallpaperManager.shared.isVideoWallpaperActive {
            VideoWallpaperManager.shared.refreshSharedDecoderTargets()
        } else {
            GlobalWallpaperSyncCoordinator.shared.reapplyToConnectedDisplays()
        }
    }

    /// Configures a newly connected external display to use the same schedulable
    /// range as the primary display while choosing its first item randomly.
    func configureExternalDisplayForRandomAllWallpapers(_ screen: NSScreen) {
        guard !config.isGlobalDisplaySyncEnabled else { return }
        let screenID = displayConfigScreenID(for: screen)
        var newConfig = config
        let primary = NSScreen.screens.first
        var displayConfig = primary.map { resolvedDisplayConfig(for: $0) }
            ?? newConfig.storedDisplayConfig(for: screenID)
        displayConfig.isEnabled = true
        displayConfig.order = .random
        displayConfig.folderIDs = nil
        newConfig.displayConfigs[screenID] = displayConfig
        updateConfig(newConfig)
        triggerRandomWallpaperNow(for: screenID)
    }

    /// Keeps the display outside automatic rotation until the user explicitly
    /// chooses a wallpaper or enables its scheduler settings.
    func configureExternalDisplayWithoutAutoSwitch(_ screen: NSScreen) {
        guard !config.isGlobalDisplaySyncEnabled else { return }
        let screenID = displayConfigScreenID(for: screen)
        var newConfig = config
        var displayConfig = newConfig.storedDisplayConfig(for: screenID)
        displayConfig.isEnabled = false
        newConfig.displayConfigs[screenID] = displayConfig
        updateConfig(newConfig)
    }

    /// Removes scheduler-only state for a disconnected display that the user did
    /// not choose to retain. Rendering services own cleanup of their own states.
    func discardPersistedDisplayState(screenID: String, fingerprint: String) {
        var newConfig = config
        let matchingIDs = Set(newConfig.displayConfigs.keys.filter {
            $0 == screenID || displayFingerprints[$0] == fingerprint
        })
        for id in matchingIDs {
            newConfig.displayConfigs.removeValue(forKey: id)
            displayFingerprints.removeValue(forKey: id)
            lastChangedItemIDs.removeValue(forKey: id)
            lastChangeTimes.removeValue(forKey: id)
            usedItemIDs.removeValue(forKey: id)
        }
        updateConfig(newConfig)
        persistSchedulerState()
        saveDisplayFingerprints()
    }

    // MARK: - Scheduling

    /// User-facing rotation interval for a timed (non-event) display config.
    /// Returns nil when the display only switches on unlock / pure on-end video events.
    private func timedIntervalSeconds(for displayConfig: DisplaySchedulerConfig) -> TimeInterval? {
        guard displayConfig.isEnabled, !displayConfig.isOnUnlockMode else { return nil }
        if displayConfig.isOnEndMode {
            return displayConfig.webSceneSwitchSeconds.map(TimeInterval.init)
        }
        guard displayConfig.intervalMinutes > 0 else { return nil }
        return TimeInterval(displayConfig.intervalMinutes * 60)
    }

    /// Earliest wall-clock time this state key is eligible for a timed switch.
    private func dueDate(
        forStateKey stateKey: String,
        interval: TimeInterval,
        now: Date
    ) -> Date {
        let base: Date
        if let last = lastChangeTimes[stateKey] {
            base = last.addingTimeInterval(interval - intervalEligibilitySlack)
        } else {
            // No prior change: allow immediately (first enable / fresh screen).
            base = now
        }
        if let retryAfter = failedApplyRetryAfter[stateKey], retryAfter > base {
            return retryAfter
        }
        return base
    }

    /// The scheduler's source of truth is the managed download library. Checking
    /// its root once per actual switch is much cheaper than stat'ing every item
    /// on a removable volume.
    private func isManagedLibraryAvailable(forceRefresh: Bool = false) -> Bool {
        let rootURL = DownloadPathManager.shared.rootFolderURL.standardizedFileURL
        let rootPath = rootURL.path
        let now = Date()

        if !forceRefresh,
           let cached = managedLibraryRootAvailability,
           cached.path == rootPath,
           (cached.isAvailable || (unavailableLibraryRetryUntil ?? .distantPast) > now) {
            return cached.isAvailable
        }

        let isAvailable = FileManager.default.fileExists(atPath: rootPath)
        managedLibraryRootAvailability = (path: rootPath, isAvailable: isAvailable)
        if isAvailable {
            unavailableLibraryRetryUntil = nil
        } else {
            unavailableLibraryRetryUntil = Date().addingTimeInterval(unavailableLibraryRetryDelay)
            print("\(logTag) Managed library root unavailable: \(rootPath); retry in \(Int(unavailableLibraryRetryDelay))s")
        }
        return isAvailable
    }

    /// Next one-shot fire: earliest due time among timed displays, or a short
    /// deferred poll when apply is blocked. nil = event-driven only (no timer).
    private func nextTimerFireDate(from now: Date) -> Date? {
        if let retryUntil = unavailableLibraryRetryUntil, retryUntil > now {
            return retryUntil
        }

        if WallpaperEngineXBridge.shared.isSettingWallpaper
            || timedRotationTask != nil
            || globalRotationTask != nil {
            return now.addingTimeInterval(deferredRetryDelay)
        }

        var earliest: Date?

        func consider(_ date: Date) {
            if earliest == nil || date < earliest! {
                earliest = date
            }
        }

        if config.isGlobalDisplaySyncEnabled {
            let global = config.globalDisplayConfig
            guard let interval = timedIntervalSeconds(for: global) else { return nil }
            if global.isOnEndMode, VideoWallpaperManager.shared.isVideoWallpaperActive {
                // Pure video on-end: web/scene timer only applies when no native video.
                // Keep a light poll so we notice when video stops.
                consider(now.addingTimeInterval(deferredRetryDelay))
                return earliest
            }
            consider(dueDate(forStateKey: globalSchedulerStateKey, interval: interval, now: now))
            return earliest
        }

        var hasTimedDisplay = false
        for screen in NSScreen.screens {
            let screenID = screen.wallpaperScreenIdentifier
            let displayConfig = resolvedDisplayConfig(for: screen)
            guard let interval = timedIntervalSeconds(for: displayConfig) else { continue }
            hasTimedDisplay = true
            if displayConfig.isOnEndMode,
               VideoWallpaperManager.shared.hasActiveWallpaper(on: screen) {
                consider(now.addingTimeInterval(deferredRetryDelay))
                continue
            }
            consider(dueDate(forStateKey: screenID, interval: interval, now: now))
        }
        return hasTimedDisplay ? earliest : nil
    }

    private func cancelDispatchTimer() {
        dispatchTimer?.cancel()
        dispatchTimer = nil
    }

    private func beginSchedulerActivityIfNeeded() {
        guard schedulerActivity == nil else { return }
        // Resist App Nap so 1-minute deadlines stay accurate; still allow idle sleep.
        schedulerActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Wallpaper auto-switch timer"
        )
    }

    private func endSchedulerActivity() {
        if let activity = schedulerActivity {
            ProcessInfo.processInfo.endActivity(activity)
            schedulerActivity = nil
        }
    }

    /// Arm a one-shot timer for the next due switch (not a fixed repeating period).
    /// - Parameter earliestDelay: Optional floor on delay (e.g. empty-library poll backoff).
    private func scheduleNextChange(earliestDelay: TimeInterval = 0) {
        cancelDispatchTimer()
        guard isRunning, !isScreenLocked else {
            endSchedulerActivity()
            return
        }

        let now = Date()
        guard let nextFire = nextTimerFireDate(from: now) else {
            endSchedulerActivity()
            print("\(logTag) All enabled displays use event-driven modes, no timer needed")
            return
        }

        beginSchedulerActivityIfNeeded()
        let delay = max(nextFire.timeIntervalSince(now), minimumTimerDelay, earliestDelay)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        // One-shot: recompute after each fire so interval tracks last successful apply.
        timer.schedule(deadline: .now() + delay, repeating: .never, leeway: scheduleLeeway)
        timer.setEventHandler { [weak self] in
            self?.handleTimerFired()
        }
        timer.activate()
        dispatchTimer = timer
        print("\(logTag) Next check in \(String(format: "%.1f", delay))s")
    }

    private func handleTimerFired() {
        dispatchTimer = nil
        let startedWork = changeWallpaperIfNeeded()
        // If a batch started, it reschedules when finished; otherwise re-arm now.
        if isRunning, !startedWork, timedRotationTask == nil, globalRotationTask == nil {
            // Due but nothing applied (empty library / blocked path): avoid a 0.25s spin.
            if let next = nextTimerFireDate(from: Date()), next.timeIntervalSinceNow <= minimumTimerDelay {
                scheduleNextChange(earliestDelay: deferredRetryDelay)
            } else {
                scheduleNextChange()
            }
        }
    }

    /// - Returns: true if a timed apply batch was started (caller must not re-arm;
    ///   the batch re-arms on completion).
    @discardableResult
    private func changeWallpaperIfNeeded() -> Bool {
        if isScreenLocked {
            clearStuckScreenLockIfNeeded(source: "timer")
        }
        guard !isScreenLocked else { return false }
        guard !manualWallpaperApplyInFlight else {
            print("\(logTag) Skipping: manual wallpaper setting in progress")
            return false
        }
        guard !WallpaperEngineXBridge.shared.isSettingWallpaper else {
            print("\(logTag) Skipping: manual wallpaper setting in progress")
            return false
        }
        if config.isGlobalDisplaySyncEnabled {
            return changeGlobalWallpaperIfNeeded()
        }
        guard isManagedLibraryAvailable(forceRefresh: true) else {
            print("\(logTag) Skipping timed rotation: managed library root unavailable")
            return false
        }
        let screens = NSScreen.screens
        let now = Date()

        // 收集所有需要切换的屏幕及其选中项，然后在一个 Task 内依次执行，
        // 避免多屏同时切换时各自 Task 的 @MainActor 片段互相打断导致状态不一致。
        typealias PendingChange = (screenID: String, item: SchedulableItem, screen: NSScreen)
        var pending: [PendingChange] = []

        for screen in screens {
            let screenID = screen.wallpaperScreenIdentifier
            let displayConfig = resolvedDisplayConfig(for: screen)
            guard displayConfig.isEnabled else { continue }
            guard !displayConfig.isOnUnlockMode else { continue }

            // 用户手动关闭该屏壁纸期间不自动拉起；重新开启（有活跃壁纸）时自然解除抑制。
            guard !isSuppressedForScheduling(screen: screen, stateKey: screenID) else {
                print("\(logTag) Skipping screen \(screenID): suppressed by manual stop")
                continue
            }
            guard let interval = timedIntervalSeconds(for: displayConfig) else { continue }

            // "播完即换"模式设置了秒级兜底时，Web/Scene/静态图都由定时器继续轮换。
            // 本机视频仍必须等播放完成通知，不能被秒级定时器中途切走。
            if displayConfig.isOnEndMode {
                guard !VideoWallpaperManager.shared.hasActiveWallpaper(on: screen) else {
                    continue
                }
            }

            if dueDate(forStateKey: screenID, interval: interval, now: now) > now {
                continue
            }

            let items = getSchedulableItems(for: displayConfig)
            if items.isEmpty {
                let context = displayConfig.isOnEndMode
                    ? "on-end mode with webSceneSwitchSeconds"
                    : "wallpapers=\(displayConfig.includeWallpapers), media=\(displayConfig.includeMedia)"
                print("\(logTag) Screen \(screenID): no schedulable items (\(context))")
                continue
            }

            guard let item = selectNextItem(
                from: items,
                lastID: lastChangedItemIDs[screenID],
                screenID: screenID,
                order: displayConfig.order
            ) else {
                print("\(logTag) Screen \(screenID): item selection returned nil")
                continue
            }

            pending.append((screenID, item, screen))
        }

        guard !pending.isEmpty else { return false }
        guard timedRotationTask == nil else {
            print("\(logTag) Timed rotation already in flight; coalescing tick")
            return true
        }

        let generation = timedRotationGeneration
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.timedRotationGeneration == generation {
                    self.timedRotationTask = nil
                    if self.isRunning {
                        self.scheduleNextChange()
                    }
                }
            }

            for (index, change) in pending.enumerated() {
                guard self.timedRotationGeneration == generation,
                      await self.waitBeforeApplyingBatchedWallpaper(index: index) else {
                    return
                }
                let (screenID, item, _) = change
                let bakeStatus = item.bakedVideoPath != nil ? "mp4" : "none"
                print("\(logTag) Applying '\(item.title)' to screen \(screenID) [bake=\(bakeStatus)]")

                let success = await applyItem(item, toScreenID: screenID)
                guard self.timedRotationGeneration == generation else { return }
                if success {
                    self.failedApplyRetryAfter.removeValue(forKey: screenID)
                    self.lastChangeTimes[screenID] = Date()
                    self.lastChangedItemIDs[screenID] = item.id
                    self.persistSchedulerState()
                    print("\(logTag) Successfully applied '\(item.title)' to screen \(screenID)")
                } else {
                    self.failedApplyRetryAfter[screenID] = Date().addingTimeInterval(self.failedApplyRetryDelay)
                    print("\(logTag) Failed to apply '\(item.title)' to screen \(screenID), retry in \(Int(self.failedApplyRetryDelay))s")
                }
            }
        }
        timedRotationTask = task
        return true
    }

    private func changeUnlockWallpapersIfNeeded() {
        guard !isScreenLocked else { return }
        guard !manualWallpaperApplyInFlight else {
            print("\(logTag) Skipping unlock switch: manual wallpaper setting in progress")
            return
        }
        guard !WallpaperEngineXBridge.shared.isSettingWallpaper else {
            print("\(logTag) Skipping unlock switch: manual wallpaper setting in progress")
            return
        }
        if config.isGlobalDisplaySyncEnabled {
            let global = config.globalDisplayConfig
            guard global.isEnabled, global.isOnUnlockMode else { return }
            applyNextGlobalWallpaper(requiredMode: nil)
            return
        }
        guard isManagedLibraryAvailable(forceRefresh: true) else {
            print("\(logTag) Skipping unlock switch: managed library root unavailable")
            return
        }

        let now = Date()
        if let lastUnlockSwitchTime,
           now.timeIntervalSince(lastUnlockSwitchTime) < 2.0 {
            print("\(logTag) Skipping duplicate unlock switch")
            return
        }

        typealias PendingChange = (screenID: String, item: SchedulableItem)
        var pending: [PendingChange] = []

        for screen in NSScreen.screens {
            let screenID = screen.wallpaperScreenIdentifier
            let displayConfig = resolvedDisplayConfig(for: screen)
            guard displayConfig.isEnabled && displayConfig.isOnUnlockMode else { continue }

            let items = getSchedulableItems(for: displayConfig)
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
                guard await self.waitBeforeApplyingBatchedWallpaper(index: index) else {
                    return
                }
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

    private func waitBeforeApplyingBatchedWallpaper(index: Int) async -> Bool {
        guard !Task.isCancelled else { return false }
        guard index > 0 else { return true }
        let delayNanoseconds = UInt64(index) * 1_200_000_000
        do {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        } catch {
            return false
        }
        return !Task.isCancelled
    }

    private func cancelTimedRotation() {
        timedRotationGeneration &+= 1
        timedRotationTask?.cancel()
        timedRotationTask = nil
    }

    /// 调度只选片 + 触发；真正设壁纸与详情页共用 `LocalWallpaperApplyService`。
    /// - Parameter preferImmediatePresentation: 状态栏/手动下一张为 true，跳过黑场预热并强制桌面合帧。
    private func applyItem(
        _ item: SchedulableItem,
        toScreenID screenID: String,
        preferImmediatePresentation: Bool = false
    ) async -> Bool {
        guard let screen = NSScreen.screens.first(where: { $0.wallpaperScreenIdentifier == screenID }) else {
            return false
        }

        let displayConfig = resolvedDisplayConfig(for: screen)
        // 播完即换且未开 web/scene 定时：只能切可接播放完成通知的视频类
        let requirePlaybackEndSupport = displayConfig.isOnEndMode
            && displayConfig.webSceneSwitchSeconds == nil

        // 自动切换常在 App 未激活时发生；短暂拉起 userInitiated activity，
        // 避免 App Nap 挂起桌面层 CA / AVPlayer 首帧提交（表现为要点一下才更新）。
        let applyActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Wallpaper auto-switch apply"
        )
        defer { ProcessInfo.processInfo.endActivity(applyActivity) }

        do {
            print("\(logTag) applyItem via LocalWallpaperApplyService '\(item.title)' → \(screen.localizedName) immediate=\(preferImmediatePresentation)")
            // 手动「下一张」也保留首帧预热和交叉淡入，避免先露黑再切换。
            let ok = try await LocalWallpaperApplyService.apply(
                localURL: item.fileURL,
                targetScreens: [screen],
                options: LocalWallpaperApplyService.Options(
                    animatedTransition: true,
                    requirePlaybackEndSupport: requirePlaybackEndSupport,
                    muted: true,
                    // 无预生成 HD poster 时后台抽帧补系统静帧（不阻塞切换）
                    generatePosterFromVideoIfNeeded: true,
                    sceneBakeItemID: item.sceneBakeItemID,
                    bakedVideoPath: item.bakedVideoPath,
                    reason: preferImmediatePresentation ? "scheduler-manual-next" : "scheduler"
                )
            )
            if !ok {
                AppLogger.error(.wallpaper, "onEnd apply 返回 false（类型不支持或条件不满足，将走重试）", metadata: [
                    "item": item.fileURL.lastPathComponent
                ])
            }
            return ok
        } catch LocalWallpaperApplyService.ApplyError.missingFile {
            unavailableSchedulableItemIDs.insert(item.id)
            AppLogger.error(.wallpaper, "onEnd 项文件缺失，移出本轮换池", metadata: ["item": item.fileURL.lastPathComponent])
            return false
        } catch {
            AppLogger.error(.wallpaper, "onEnd applyItem 失败（将走重试）", metadata: [
                "item": item.fileURL.lastPathComponent,
                "error": String(describing: error)
            ])
            return false
        }
    }

    /// - Returns: true if a global apply task was started or is already in flight.
    @discardableResult
    private func changeGlobalWallpaperIfNeeded() -> Bool {
        let global = config.globalDisplayConfig
        guard global.isEnabled, !global.isOnUnlockMode else { return false }
        guard let interval = timedIntervalSeconds(for: global) else { return false }
        let now = Date()

        // 用户手动全局关闭期间不自动拉起；任一屏重新出现活跃动态壁纸时自然解除。
        if userSuppressedScreenIDs.contains(globalSchedulerStateKey) {
            let anyLive = NSScreen.screens.contains { screen in
                !isSuppressedForScheduling(screen: screen, stateKey: globalSchedulerStateKey)
            }
            if !anyLive {
                print("\(logTag) Skipping global rotation: suppressed by manual stop")
                return false
            }
        }

        if global.isOnEndMode {
            // Web/Scene 秒级兜底：仅在没有本机视频时由定时器推进。
            guard !VideoWallpaperManager.shared.isVideoWallpaperActive else { return false }
        }

        if dueDate(forStateKey: globalSchedulerStateKey, interval: interval, now: now) > now {
            return false
        }

        if globalRotationTask != nil {
            print("\(logTag) Global rotation already in flight; coalescing tick")
            return true
        }

        applyNextGlobalWallpaper(requiredMode: global.isOnEndMode ? .onEnd : nil)
        return globalRotationTask != nil
    }

    private func applyItemGlobally(
        _ item: SchedulableItem,
        to screens: [NSScreen],
        preferImmediatePresentation: Bool = false
    ) async -> Bool {
        let displayConfig = config.globalDisplayConfig
        let requirePlaybackEndSupport = displayConfig.isOnEndMode
            && displayConfig.webSceneSwitchSeconds == nil

        let applyActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Wallpaper global auto-switch apply"
        )
        defer { ProcessInfo.processInfo.endActivity(applyActivity) }

        do {
            let ok = try await LocalWallpaperApplyService.apply(
                localURL: item.fileURL,
                targetScreens: screens,
                options: LocalWallpaperApplyService.Options(
                    animatedTransition: true,
                    requirePlaybackEndSupport: requirePlaybackEndSupport,
                    muted: true,
                    // 无预生成 HD poster 时后台抽帧补系统静帧（不阻塞切换）
                    generatePosterFromVideoIfNeeded: true,
                    sceneBakeItemID: item.sceneBakeItemID,
                    bakedVideoPath: item.bakedVideoPath,
                    usesSharedVideoDecoder: screens.count > 1,
                    reason: preferImmediatePresentation ? "globalScheduler-manual-next" : "globalScheduler"
                )
            )
            return ok
        } catch LocalWallpaperApplyService.ApplyError.missingFile {
            unavailableSchedulableItemIDs.insert(item.id)
            print("\(logTag) Removed missing global item '\(item.title)' from this session's rotation pool")
            return false
        } catch {
            print("\(logTag) Global apply failed for '\(item.title)': \(error.localizedDescription)")
            return false
        }
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
        /// 生成稳定烘焙抽帧时使用的媒体 item id。
        let sceneBakeItemID: String?
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

    /// 播完即换「下一张」的粘性预约（stateKey → item）。
    /// 预热（peek）时提前定好下一张并缓存；实际切换时优先消费预约，
    /// 保证预热管线必然命中（否则随机顺序下预演与实际是两次独立随机
    /// 抽取，命中率仅 1/(N-1)，预热形同虚设）。
    private var reservedNextOnEndItems: [String: SchedulableItem] = [:]

    /// 预演「播完即换」的下一张：先按真实切换路径选择下一项，再决定
    /// 是否可以预热。预热不能改变候选顺序，也不能绕过随机轮次去重；
    /// 只有直接视频文件才交给独立 renderer 预热。

    func peekNextOnEndPlaybackURL(for screenID: String) -> URL? {
        guard let screen = NSScreen.screens.first(where: {
            $0.wallpaperScreenIdentifier == screenID
        }) else { return nil }
        let displayConfig = resolvedDisplayConfig(for: screen)
        guard displayConfig.isEnabled, displayConfig.isOnEndMode else { return nil }
        guard isManagedLibraryAvailable() else { return nil }
        let items = getSchedulableItems(for: displayConfig)
        guard !items.isEmpty else { return nil }

        let stateKey = config.isGlobalDisplaySyncEnabled
            ? globalSchedulerStateKey
            : screenID
        let lastID = lastChangedItemIDs[stateKey]

        // 预热只接受直接视频文件。Workshop 目录可能最终走烘焙 MP4、
        // wallpaper-wgpu 或其它 apply 路径，不能把目录路径直接交给 AVPlayer。
        let videoExts: Set<String> = ["mp4", "mov", "m4v", "webm", "mkv", "avi"]

        let candidate: SchedulableItem?
        switch displayConfig.order {
        case .sequential:
            // 顺序模式必须先在完整候选池中选下一项。若下一项是
            // Workshop/烘焙项，就放弃预热，不能从 direct-video 子集里
            // 偷换成另一项，否则实际顺序会被预约逻辑改写。
            candidate = selectSequential(from: items, lastID: lastID)
        case .random:
            // 与 selectRandom 同口径但不写 usedItemIDs / 不持久化，
            // 避免预演污染实际轮换的随机去重池。
            candidate = chooseRandomCandidate(
                from: items,
                lastID: lastID,
                used: usedItemIDs[stateKey] ?? Set()
            )?.item
        }
        guard let item = candidate else {
            reservedNextOnEndItems.removeValue(forKey: stateKey)
            return nil
        }
        guard item.bakedVideoPath == nil,
              videoExts.contains(item.fileURL.pathExtension.lowercased()) else {
            reservedNextOnEndItems.removeValue(forKey: stateKey)
            return nil
        }
        reservedNextOnEndItems[stateKey] = item
        AppLogger.debug(.wallpaper, "onEnd 预热预约", metadata: [
            "stateKey": stateKey,
            "item": item.fileURL.lastPathComponent
        ])
        return item.fileURL
    }

    /// Builds candidates from persisted library records only. Imported content is
    /// recorded synchronously, so polling the download folders is unnecessary.
    private func getSchedulableItems(for displayConfig: DisplaySchedulerConfig) -> [SchedulableItem] {
        guard isManagedLibraryAvailable() else { return [] }
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
            // Persisted wallpaper download records are the authoritative source.
            for record in WallpaperLibraryService.shared.downloadedWallpapers {
                guard folderFilter(record.folderID) else { continue }
                let url = URL(fileURLWithPath: record.localFilePath)
                let itemID = "wp_dl_\(record.id)"
                guard !unavailableSchedulableItemIDs.contains(itemID) else { continue }
                items.append(SchedulableItem(
                    id: itemID,
                    fileURL: url,
                    title: url.deletingPathExtension().lastPathComponent,
                    bakedVideoPath: nil,
                    sceneBakeItemID: nil
                ))
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
                // Imports only create direct video files or `workshop_*` project
                // directories. Do not stat every record just to rediscover that.
                guard isWorkshop || isAllowedExt else { continue }
                let itemID = "media_dl_\(record.id)"
                guard !unavailableSchedulableItemIDs.contains(itemID) else { continue }
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
                if isWorkshop,
                   let art = SceneOfflineBakeService.usableArtifact(from: record) {
                    // Scene and web share the same rule: realtime mode keeps live
                    // rendering; baked MP4 is only used when realtime is off (or
                    // on-end without web/scene timer where live cannot participate).
                    let isWebBake = art.renderer == .wallpaperEngineWeb
                    let preferRealtime = isWebBake
                        ? (isRealtimeRenderingEnabled && (!onEndMode || webSceneSwitchEnabled))
                        : preferRealtimeForScene
                    if !preferRealtime {
                        bakedVideoPath = art.videoPath
                        sceneBakeItemID = record.item.id
                    }
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
                    } else if isAllowedExt {
                        // 可由 AVFoundation 直接播放的视频文件
                    } else if isWorkshop && workshopRecordDeclaresVideo(record) {
                        // 导入/下载时已经保存了 Wallpaper Engine 项目类型，避免在
                        // 每次播完时递归扫描 project 目录验证视频文件。
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
        }

        return items
    }

    private func workshopRecordDeclaresVideo(_ record: MediaDownloadRecord) -> Bool {
        record.item.resolutionLabel
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("video") == .orderedSame
    }

    private func selectSequential(from items: [SchedulableItem], lastID: String?) -> SchedulableItem? {
        guard let lastID else { return items.first }
        if let index = items.firstIndex(where: { $0.id == lastID }), index + 1 < items.count {
            return items[index + 1]
        }
        return items.first
    }

    /// Selects the same random candidate that the real apply path would see,
    /// without mutating the per-screen random-round state. The caller decides
    /// whether consuming the result should advance `usedItemIDs`.
    private func chooseRandomCandidate(
        from items: [SchedulableItem],
        lastID: String?,
        used: Set<String>
    ) -> (item: SchedulableItem, didResetRound: Bool)? {
        guard !items.isEmpty else { return nil }

        var candidates = items.filter { !used.contains($0.id) }
        let didResetRound = candidates.isEmpty
        if didResetRound {
            candidates = items
        }

        if let lastID,
           candidates.count > 1,
           let lastIndex = candidates.firstIndex(where: { $0.id == lastID }) {
            candidates.remove(at: lastIndex)
        }

        guard let selected = candidates.randomElement() else { return nil }
        return (selected, didResetRound)
    }

    private func selectRandom(from items: [SchedulableItem], lastID: String?, screenID: String) -> SchedulableItem? {
        guard !items.isEmpty else { return nil }

        var used = usedItemIDs[screenID] ?? Set()
        guard let selection = chooseRandomCandidate(
            from: items,
            lastID: lastID,
            used: used
        ) else {
            return nil
        }

        // 如果全部都用过了，重置本轮记录重新开始。
        if selection.didResetRound {
            used.removeAll()
        }

        used.insert(selection.item.id)
        usedItemIDs[screenID] = used
        persistSchedulerState()
        return selection.item
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
