import AppKit
import Foundation

/// Owns only external-display connection policy. Each wallpaper service keeps
/// ownership of its renderer and persisted state; the scheduler only receives
/// scheduler configuration requests from this coordinator.
@MainActor
final class ExternalDisplayConnectionCoordinator: NSObject {
    static let shared = ExternalDisplayConnectionCoordinator()

    private struct PendingDisplay {
        let screenID: String
        let fingerprint: String
        let name: String
    }

    private struct ExternalDisplaySnapshot {
        let screenID: String
        let fingerprint: String
    }

    private let knownDisplayFingerprintsKey = "external_display_known_fingerprints_v1"
    private let legacyRetainedDisplayFingerprintsKey = "external_display_retained_fingerprints_v1"
    private var isStarted = false
    private var previousExternalDisplays: [String: ExternalDisplaySnapshot] = [:]
    private var pendingWorkItem: DispatchWorkItem?
    private var pendingDisplays: [PendingDisplay] = []
    private var isPresentingPrompt = false
    private var lastLoggedScreenSignature: String?
    private var lastLoggedScreenSignatureAt = Date.distantPast

    private override init() {
        super.init()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        migrateLegacyRetainedDisplayFingerprintsIfNeeded()
        previousExternalDisplays = Self.currentExternalDisplaySnapshots()
        markDisplaysAsKnown(previousExternalDisplays.values.map(\.fingerprint))
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func handleScreenParametersChanged() {
        // 系统在唤醒/显示器热插拔时会在 1 秒内连发同一通知几十次，直接每次
        // 打 ERROR 会刷爆日志并加剧主线程压力；签名相同且 15s 内已打过则降级 debug。
        let signature = NSScreen.screens.map(\.wallpaperScreenIdentifier).joined(separator: ",")
        if signature == lastLoggedScreenSignature,
           Date().timeIntervalSince(lastLoggedScreenSignatureAt) < 15 {
            AppLogger.debug(.wallpaper, "ExternalDisplay screen parameters changed (重复通知已合并)", metadata: [
                "previousExternalFingerprints": previousExternalDisplays.count,
                "currentScreens": signature
            ])
        } else {
            lastLoggedScreenSignature = signature
            lastLoggedScreenSignatureAt = Date()
            AppLogger.error(.wallpaper, "ExternalDisplay screen parameters changed", metadata: [
                "previousExternalFingerprints": previousExternalDisplays.count,
                "currentScreens": signature
            ])
        }
        pendingWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.processCurrentDisplays()
            }
        }
        pendingWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)
    }

    private func processCurrentDisplays() {
        let scheduler = WallpaperSchedulerService.shared
        scheduler.relinkDisplayConfigsForCurrentScreens()

        // Identical no-serial monitors can share one connection fingerprint.
        // Compare occurrence tokens so a second identical display is not silently
        // collapsed into the first dictionary entry.
        let current = Self.currentExternalScreensByToken()
        let currentFingerprints = Set(current.values.map(\.externalConnectionFingerprint))
        let previousFingerprints = Set(previousExternalDisplays.values.map(\.fingerprint))
        let newlyVisibleTokens = current.keys.filter { previousExternalDisplays[$0] == nil }
        let connectedFingerprints = Set(newlyVisibleTokens.compactMap { current[$0]?.externalConnectionFingerprint })

        AppLogger.error(.wallpaper, "ExternalDisplay processed display change", metadata: [
            "currentExternal": current.count,
            "currentFingerprints": currentFingerprints.count,
            "connected": newlyVisibleTokens.count,
            "known": knownDisplayFingerprints.count,
            "connectedFingerprints": connectedFingerprints.joined(separator: ","),
            "previousFingerprints": previousFingerprints.joined(separator: ",")
        ])

        previousExternalDisplays = Self.currentExternalDisplaySnapshots()

        for token in newlyVisibleTokens {
            guard let screen = current[token] else { continue }
            handleConnectedExternalDisplay(screen)
        }
    }

    private func handleConnectedExternalDisplay(_ screen: NSScreen) {
        Task { @MainActor in
            if WallpaperSchedulerService.shared.isGlobalDisplaySyncEnabled {
                // A synchronized display has no independent connect decision.
                markDisplayAsKnown(screen.externalConnectionFingerprint)
                WallpaperSchedulerService.shared.synchronizeCurrentGlobalWallpaperToConnectedDisplays()
                return
            }

            // Try persisted renderer/image state first, even if the older
            // "known display" marker is missing. This makes upgrades and
            // restored UserDefaults behave the same as a normal reconnect.
            if await restorePreviousDisplayStateIfAvailable(for: screen) {
                markDisplayAsKnown(screen.externalConnectionFingerprint)
                return
            }

            if knownDisplayFingerprints.contains(screen.externalConnectionFingerprint) {
                if WallpaperSchedulerService.shared.resolvedDisplayConfig(for: screen).isEnabled,
                   WallpaperSchedulerService.shared.hasSchedulableItems(for: screen.wallpaperScreenIdentifier) {
                    WallpaperSchedulerService.shared.triggerNextWallpaperNow(for: screen.wallpaperScreenIdentifier)
                }
                return
            }

            pendingDisplays.append(PendingDisplay(
                screenID: screen.wallpaperScreenIdentifier,
                fingerprint: screen.externalConnectionFingerprint,
                name: screen.localizedName
            ))
            presentNextPromptIfNeeded()
        }
    }

    private func restorePreviousDisplayStateIfAvailable(for screen: NSScreen) async -> Bool {
        if await VideoWallpaperManager.shared.restorePreviousVideoWallpaperIfAvailable(for: screen) {
            return true
        }
        if await WallpaperEngineXBridge.shared.restorePreviousWallpaperIfAvailable(for: screen) {
            return true
        }
        if StaticImageWallpaperOverlayManager.shared.restorePreviousImageIfAvailable(for: screen) {
            return true
        }
        // Fallback: system-native static wallpaper (including video posters).
        return DesktopWallpaperSyncManager.shared.hasPersistedWallpaperForFingerprint(screen.wallpaperScreenFingerprint)
    }

    private func presentNextPromptIfNeeded() {
        guard !isPresentingPrompt, !pendingDisplays.isEmpty else { return }
        isPresentingPrompt = true
        let display = pendingDisplays.removeFirst()

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = t("externalDisplay.connected.title")
        alert.informativeText = String(format: t("externalDisplay.connected.message"), display.name)
        alert.addButton(withTitle: t("externalDisplay.randomAllWallpapers"))
        alert.addButton(withTitle: t("externalDisplay.openSchedulerSettings"))
        alert.addButton(withTitle: t("externalDisplay.openLibraryWithoutAuto"))
        alert.addButton(withTitle: t("externalDisplay.doNotUseAnyWallpaper"))

        // 绝不在主线程 runModal：显示器热插拔可能连发多次触发，同步模态会把
        // 主线程卡住数秒到数分钟（日志实锤 stall 148s/459s，栈顶即 runModal），
        // 期间壁纸设置点击全部无响应。有可见宿主窗口时用 sheet 异步呈现；
        // 托盘/无窗口时采用默认「不使用壁纸」静默处理，不打扰后台。
        let hostWindow = NSApp.mainWindow
            ?? NSApp.keyWindow
            ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain && !$0.isSheet }

        if let hostWindow {
            NSApp.activate(ignoringOtherApps: true)
            alert.beginSheetModal(for: hostWindow) { [weak self] response in
                guard let self else { return }
                self.handleExternalDisplayPromptResponse(response, display: display)
                self.isPresentingPrompt = false
                self.presentNextPromptIfNeeded()
            }
        } else {
            AppLogger.info(.wallpaper, "外接显示器连接但无可见窗口，跳过弹窗按默认不使用壁纸处理", metadata: [
                "screenID": display.screenID,
                "fingerprint": display.fingerprint
            ])
            handleExternalDisplayPromptResponse(nil, display: display)
            isPresentingPrompt = false
            presentNextPromptIfNeeded()
        }
    }

    private func handleExternalDisplayPromptResponse(_ response: NSApplication.ModalResponse?, display: PendingDisplay) {
        markDisplayAsKnown(display.fingerprint)

        if let screen = NSScreen.screens.first(where: {
            $0.wallpaperScreenIdentifier == display.screenID
                || $0.externalConnectionFingerprint == display.fingerprint
        }) {
            switch response {
            case .alertFirstButtonReturn:
                WallpaperSchedulerService.shared.configureExternalDisplayForRandomAllWallpapers(screen)
            case .alertSecondButtonReturn:
                WallpaperSchedulerService.shared.configureExternalDisplayWithoutAutoSwitch(screen)
                openSchedulerSettings()
            case .alertThirdButtonReturn:
                WallpaperSchedulerService.shared.configureExternalDisplayWithoutAutoSwitch(screen)
                openLibrary()
            default:
                // nil（无窗口静默路径）与「不使用壁纸」同义：不自动换壁纸
                WallpaperSchedulerService.shared.configureExternalDisplayWithoutAutoSwitch(screen)
            }
        }
    }

    private var knownDisplayFingerprints: Set<String> {
        Set(WaifuXPreferences.shared.stringArray(forKey: knownDisplayFingerprintsKey) ?? [])
    }

    private func markDisplayAsKnown(_ fingerprint: String) {
        var fingerprints = knownDisplayFingerprints
        guard fingerprints.insert(fingerprint).inserted else { return }
        WaifuXPreferences.shared.set(fingerprints.sorted(), forKey: knownDisplayFingerprintsKey)
    }

    private func markDisplaysAsKnown<S: Sequence>(_ fingerprints: S) where S.Element == String {
        var known = knownDisplayFingerprints
        let originalCount = known.count
        known.formUnion(fingerprints)
        guard known.count != originalCount else { return }
        WaifuXPreferences.shared.set(known.sorted(), forKey: knownDisplayFingerprintsKey)
    }

    private func migrateLegacyRetainedDisplayFingerprintsIfNeeded() {
        let defaults = WaifuXPreferences.shared
        guard defaults.object(forKey: knownDisplayFingerprintsKey) == nil else { return }

        let retained = Set(defaults.stringArray(forKey: legacyRetainedDisplayFingerprintsKey) ?? [])
        guard !retained.isEmpty else { return }
        defaults.set(retained.sorted(), forKey: knownDisplayFingerprintsKey)
    }

    private func openLibrary() {
        MainNavigationRequestStore.requestLibraryTab()
        WaifuXUIActions.perform(.library)
    }

    private func openSchedulerSettings() {
        WaifuXPreferences.shared.set(true, forKey: "settings.openSchedulerOnNextAppearance")
        NotificationCenter.default.post(name: .openSchedulerSettings, object: nil)
        WaifuXUIActions.perform(.scheduler)
    }

    private static func currentExternalScreens() -> [NSScreen] {
        NSScreen.screens
            .filter { !$0.isBuiltInDisplay }
            .sorted { lhs, rhs in
                let lFingerprint = lhs.externalConnectionFingerprint
                let rFingerprint = rhs.externalConnectionFingerprint
                if lFingerprint != rFingerprint { return lFingerprint < rFingerprint }
                // Relative position is only an ordering tie-breaker. It is not
                // persisted as identity, so a main-screen origin shift does not
                // make an existing monitor look newly connected.
                if lhs.frame.origin.y != rhs.frame.origin.y {
                    return lhs.frame.origin.y > rhs.frame.origin.y
                }
                if lhs.frame.origin.x != rhs.frame.origin.x {
                    return lhs.frame.origin.x < rhs.frame.origin.x
                }
                return lhs.localizedName < rhs.localizedName
            }
    }

    /// One token per physical screen, including duplicate connection
    /// fingerprints. The rank is local to two adjacent screen-parameter
    /// samples and is only used to detect count changes.
    private static func currentExternalScreensByToken() -> [String: NSScreen] {
        var occurrenceByFingerprint: [String: Int] = [:]
        let entries = currentExternalScreens().map { screen -> (String, NSScreen) in
            let fingerprint = screen.externalConnectionFingerprint
            let rank = occurrenceByFingerprint[fingerprint, default: 0]
            occurrenceByFingerprint[fingerprint] = rank + 1
            return ("\(fingerprint)#\(rank)", screen)
        }
        // Keep a uniquing closure as a defensive guard for malformed snapshots
        // and regression coverage of duplicate-fingerprint handling.
        return Dictionary(entries, uniquingKeysWith: { existing, _ in existing })
    }

    /// Compatibility helper for code/tests that need a lossy one-screen-per-
    /// fingerprint view. Change detection must use currentExternalScreensByToken().
    private static func currentExternalScreensByFingerprint() -> [String: NSScreen] {
        Dictionary(currentExternalScreens().map { ($0.externalConnectionFingerprint, $0) },
                   uniquingKeysWith: { existing, _ in existing })
    }

    private static func currentExternalDisplaySnapshots() -> [String: ExternalDisplaySnapshot] {
        Dictionary(currentExternalScreensByToken().map { token, screen in
            (
                token,
                ExternalDisplaySnapshot(
                    screenID: screen.wallpaperScreenIdentifier,
                    fingerprint: screen.externalConnectionFingerprint
                )
            )
        }, uniquingKeysWith: { existing, _ in existing })
    }
}

extension Notification.Name {
    static let openSchedulerSettings = Notification.Name("com.waifux.openSchedulerSettings")
}
