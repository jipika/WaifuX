import AppKit
import Foundation

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

    private var isStarted = false
    private var previousExternalDisplays: [String: ExternalDisplaySnapshot] = [:]
    private var pendingWorkItem: DispatchWorkItem?
    private var pendingDisplays: [PendingDisplay] = []
    private var isPresentingPrompt = false
    private let retainedDisplayFingerprintsKey = "external_display_retained_fingerprints_v1"

    private override init() {
        super.init()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        previousExternalDisplays = Self.currentExternalDisplaySnapshots()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func handleScreenParametersChanged() {
        AppLogger.error(.wallpaper, "ExternalDisplay screen parameters changed", metadata: [
            "previousExternalFingerprints": previousExternalDisplays.count,
            "currentScreens": NSScreen.screens.map(\.wallpaperScreenIdentifier).joined(separator: ",")
        ])
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
        WallpaperSchedulerService.shared.relinkDisplayConfigsForCurrentScreens()

        let screensByFingerprint = Self.currentExternalScreensByFingerprint()
        let currentFingerprints = Set(screensByFingerprint.keys)
        let previousFingerprints = Set(previousExternalDisplays.keys)
        let connectedFingerprints = currentFingerprints.subtracting(previousFingerprints)
        let disconnectedFingerprints = previousFingerprints.subtracting(currentFingerprints)
        AppLogger.error(.wallpaper, "ExternalDisplay processed display change", metadata: [
            "currentExternal": currentFingerprints.count,
            "connected": connectedFingerprints.count,
            "disconnected": disconnectedFingerprints.count,
            "connectedFingerprints": connectedFingerprints.joined(separator: ","),
            "disconnectedFingerprints": disconnectedFingerprints.joined(separator: ",")
        ])
        for fingerprint in disconnectedFingerprints {
            guard !retainedDisplayFingerprints.contains(fingerprint),
                  let display = previousExternalDisplays[fingerprint] else {
                continue
            }
            discardUnretainedDisplayPersistence(display)
        }

        previousExternalDisplays = Self.currentExternalDisplaySnapshots()

        guard !connectedFingerprints.isEmpty else { return }

        for fingerprint in connectedFingerprints {
            guard let screen = screensByFingerprint[fingerprint] else { continue }
            handleConnectedExternalDisplay(screen)
        }
    }

    private func handleConnectedExternalDisplay(_ screen: NSScreen) {
        Task { @MainActor in
            // 全局同步优先级最高：新显示器直接加入显示器 1 的同步组，不恢复旧状态、
            // 不随机切换，也绝不显示独立模式的接入弹窗。
            if WallpaperSchedulerService.shared.config.syncAllDisplays {
                _ = await WallpaperSchedulerService.shared.syncConnectedDisplayToPrimary(screen)
                print("[ExternalDisplay] Global sync handled connected display: \(screen.localizedName)")
                return
            }

            if retainedDisplayFingerprints.contains(screen.externalConnectionFingerprint) {
                if await restorePreviousDisplayStateIfAvailable(for: screen) {
                    return
                }

                if WallpaperSchedulerService.shared.resolvedDisplayConfig(for: screen).isEnabled,
                   WallpaperSchedulerService.shared.hasSchedulableItems(for: screen.wallpaperScreenIdentifier) {
                    WallpaperSchedulerService.shared.triggerNextWallpaperNow(for: screen.wallpaperScreenIdentifier)
                }
                // 这块屏幕已经由用户明确处理过：无可恢复壁纸且未启用调度时，
                // 保持“不使用任何壁纸”的选择，不再次弹出接入向导。
                return
            }

            continueHandlingConnectedExternalDisplay(screen)
        }
    }

    private func continueHandlingConnectedExternalDisplay(_ screen: NSScreen) {
        pendingDisplays.append(PendingDisplay(
            screenID: screen.wallpaperScreenIdentifier,
            fingerprint: screen.externalConnectionFingerprint,
            name: screen.localizedName
        ))
        presentNextPromptIfNeeded()
    }

    private func restorePreviousDisplayStateIfAvailable(for screen: NSScreen) async -> Bool {
        if VideoWallpaperManager.shared.restorePreviousVideoWallpaperIfAvailable(for: screen) {
            return true
        }

        if await WallpaperEngineXBridge.shared.restorePreviousWallpaperIfAvailable(for: screen) {
            return true
        }

        if StaticImageWallpaperOverlayManager.shared.restorePreviousImageIfAvailable(for: screen) {
            return true
        }

        // 兜底：系统原生静态壁纸（含视频 poster）。macOS 自己记得该屏壁纸，
        // 只要 App 曾为该屏（按指纹）注册过壁纸且文件仍在，就静默恢复不弹窗。
        // 实际 re-apply 由 performSync 在 screenParametersChanged 时按指纹 relink 完成。
        if DesktopWallpaperSyncManager.shared.hasPersistedWallpaperForFingerprint(screen.wallpaperScreenFingerprint) {
            return true
        }

        return false
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

        let retainStateCheckbox = NSButton(checkboxWithTitle: t("externalDisplay.retainState"), target: nil, action: nil)
        retainStateCheckbox.state = retainedDisplayFingerprints.contains(display.fingerprint) ? .on : .off
        retainStateCheckbox.translatesAutoresizingMaskIntoConstraints = false

        let accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        accessoryView.addSubview(retainStateCheckbox)
        NSLayoutConstraint.activate([
            retainStateCheckbox.leadingAnchor.constraint(equalTo: accessoryView.leadingAnchor),
            retainStateCheckbox.trailingAnchor.constraint(lessThanOrEqualTo: accessoryView.trailingAnchor),
            retainStateCheckbox.centerYAnchor.constraint(equalTo: accessoryView.centerYAnchor),
        ])
        alert.accessoryView = accessoryView

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        setRetainsDisplayState(retainStateCheckbox.state == .on, fingerprint: display.fingerprint)

        guard let displayScreen = NSScreen.screens.first(where: {
            $0.wallpaperScreenIdentifier == display.screenID
                || $0.externalConnectionFingerprint == display.fingerprint
        }) else {
            isPresentingPrompt = false
            presentNextPromptIfNeeded()
            return
        }

        if response == .alertFirstButtonReturn {
            WallpaperSchedulerService.shared.configureExternalDisplayForRandomAllWallpapers(displayScreen)
        } else if response == .alertSecondButtonReturn {
            WallpaperSchedulerService.shared.configureExternalDisplayWithoutAutoSwitch(displayScreen)
            openSchedulerSettings()
        } else if response == .alertThirdButtonReturn {
            WallpaperSchedulerService.shared.configureExternalDisplayWithoutAutoSwitch(displayScreen)
            openLibrary()
        } else {
            WallpaperSchedulerService.shared.configureExternalDisplayWithoutAutoSwitch(displayScreen)
        }

        isPresentingPrompt = false
        presentNextPromptIfNeeded()
    }

    private func openLibrary() {
        MainNavigationRequestStore.requestLibraryTab()

        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.showMainWindow()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func openSchedulerSettings() {
        UserDefaults.standard.set(true, forKey: "settings.openSchedulerOnNextAppearance")
        NotificationCenter.default.post(name: .openSchedulerSettings, object: nil)
        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.showSettingsWindow(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private var retainedDisplayFingerprints: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: retainedDisplayFingerprintsKey) ?? [])
    }

    private func setRetainsDisplayState(_ retains: Bool, fingerprint: String) {
        var fingerprints = retainedDisplayFingerprints
        if retains {
            fingerprints.insert(fingerprint)
        } else {
            fingerprints.remove(fingerprint)
        }
        UserDefaults.standard.set(Array(fingerprints).sorted(), forKey: retainedDisplayFingerprintsKey)
    }

    private func discardUnretainedDisplayPersistence(_ display: ExternalDisplaySnapshot) {
        WallpaperSchedulerService.shared.discardPersistedDisplayState(
            screenID: display.screenID,
            fingerprint: display.fingerprint
        )
        VideoWallpaperManager.shared.discardPersistedWallpaperState(
            screenID: display.screenID,
            fingerprint: display.fingerprint
        )
        Task {
            await WallpaperEngineXBridge.shared.discardPersistedWallpaperState(
                screenID: display.screenID,
                fingerprint: display.fingerprint
            )
        }
        StaticImageWallpaperOverlayManager.shared.discardPersistedImageState(
            screenID: display.screenID,
            fingerprint: display.fingerprint
        )
        DesktopWallpaperSyncManager.shared.clearRegistration(
            screenID: display.screenID,
            fingerprint: display.fingerprint
        )
        print("[ExternalDisplay] Discarded unretained display state: \(display.fingerprint)")
    }

    private static func currentExternalScreensByFingerprint() -> [String: NSScreen] {
        var result: [String: NSScreen] = [:]
        for screen in NSScreen.screens where !screen.isBuiltInDisplay {
            result[screen.externalConnectionFingerprint] = screen
        }
        return result
    }

    private static func currentExternalDisplaySnapshots() -> [String: ExternalDisplaySnapshot] {
        Dictionary(uniqueKeysWithValues: currentExternalScreensByFingerprint().map { fingerprint, screen in
            (fingerprint, ExternalDisplaySnapshot(
                screenID: screen.wallpaperScreenIdentifier,
                fingerprint: fingerprint
            ))
        })
    }
}

extension Notification.Name {
    static let openSchedulerSettings = Notification.Name("com.waifux.openSchedulerSettings")
}
