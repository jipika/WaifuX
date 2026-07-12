import AppKit
import Foundation

@MainActor
final class ExternalDisplayConnectionCoordinator: NSObject {
    static let shared = ExternalDisplayConnectionCoordinator()

    private struct PendingDisplay {
        let screenID: String
        let name: String
    }

    private var isStarted = false
    private var previousExternalFingerprints = Set<String>()
    private var pendingWorkItem: DispatchWorkItem?
    private var pendingDisplays: [PendingDisplay] = []
    private var isPresentingPrompt = false

    private override init() {
        super.init()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        previousExternalFingerprints = Set(Self.currentExternalScreensByFingerprint().keys)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func handleScreenParametersChanged() {
        AppLogger.error(.wallpaper, "ExternalDisplay screen parameters changed", metadata: [
            "previousExternalFingerprints": previousExternalFingerprints.count,
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
        let connectedFingerprints = currentFingerprints.subtracting(previousExternalFingerprints)
        let disconnectedFingerprints = previousExternalFingerprints.subtracting(currentFingerprints)
        AppLogger.error(.wallpaper, "ExternalDisplay processed display change", metadata: [
            "currentExternal": currentFingerprints.count,
            "connected": connectedFingerprints.count,
            "disconnected": disconnectedFingerprints.count,
            "connectedFingerprints": connectedFingerprints.joined(separator: ","),
            "disconnectedFingerprints": disconnectedFingerprints.joined(separator: ",")
        ])
        previousExternalFingerprints = currentFingerprints

        guard !connectedFingerprints.isEmpty else { return }

        for fingerprint in connectedFingerprints {
            guard let screen = screensByFingerprint[fingerprint] else { continue }
            handleConnectedExternalDisplay(screen)
        }
    }

    private func handleConnectedExternalDisplay(_ screen: NSScreen) {
        Task { @MainActor in
            // 全局同步优先级最高：新显示器直接加入显示器 1 的同步组，不恢复旧状态、不随机切换，也不弹窗。
            if await WallpaperSchedulerService.shared.syncConnectedDisplayToPrimary(screen) {
                print("[ExternalDisplay] Global sync applied display 1 wallpaper to connected display: \(screen.localizedName)")
                return
            }

            if await restorePreviousDisplayStateIfAvailable(for: screen) {
                return
            }
            continueHandlingConnectedExternalDisplay(screen)
        }
    }

    private func continueHandlingConnectedExternalDisplay(_ screen: NSScreen) {
        let screenID = screen.wallpaperScreenIdentifier
        let config = WallpaperSchedulerService.shared.resolvedDisplayConfig(for: screen)

        if config.autoChangeOnExternalConnect {
            WallpaperSchedulerService.shared.triggerRandomWallpaperNow(for: screenID)
            print("[ExternalDisplay] Auto-applied random wallpaper for connected display: \(screen.localizedName)")
            return
        }

        pendingDisplays.append(PendingDisplay(screenID: screenID, name: screen.localizedName))
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
        alert.addButton(withTitle: t("externalDisplay.useRandomWallpaper"))
        alert.addButton(withTitle: t("externalDisplay.chooseWallpaper"))
        alert.addButton(withTitle: t("externalDisplay.doNotUseWallpaper"))

        let autoSwitchCheckbox = NSButton(checkboxWithTitle: t("externalDisplay.autoSwitchOnConnect"), target: nil, action: nil)
        let displayScreen = NSScreen.screens.first { $0.wallpaperScreenIdentifier == display.screenID }
        let displayConfig = displayScreen.map {
            WallpaperSchedulerService.shared.resolvedDisplayConfig(for: $0)
        } ?? WallpaperSchedulerService.shared.config.resolvedDisplayConfig(for: display.screenID)
        autoSwitchCheckbox.state = displayConfig.autoChangeOnExternalConnect ? .on : .off
        autoSwitchCheckbox.translatesAutoresizingMaskIntoConstraints = false

        let accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        accessoryView.addSubview(autoSwitchCheckbox)
        NSLayoutConstraint.activate([
            autoSwitchCheckbox.leadingAnchor.constraint(equalTo: accessoryView.leadingAnchor),
            autoSwitchCheckbox.trailingAnchor.constraint(lessThanOrEqualTo: accessoryView.trailingAnchor),
            autoSwitchCheckbox.centerYAnchor.constraint(equalTo: accessoryView.centerYAnchor),
        ])
        alert.accessoryView = accessoryView

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if let displayScreen {
            WallpaperSchedulerService.shared.updateDisplayAutoChangeOnExternalConnect(
                autoSwitchCheckbox.state == .on,
                for: displayScreen
            )
        } else {
            WallpaperSchedulerService.shared.updateDisplayAutoChangeOnExternalConnect(
                autoSwitchCheckbox.state == .on,
                for: display.screenID
            )
        }

        switch response {
        case .alertFirstButtonReturn:
            WallpaperSchedulerService.shared.triggerRandomWallpaperNow(for: display.screenID)
        case .alertSecondButtonReturn:
            openLibrary()
        default:
            break
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

    private static func currentExternalScreensByFingerprint() -> [String: NSScreen] {
        var result: [String: NSScreen] = [:]
        for screen in NSScreen.screens where !screen.isBuiltInDisplay {
            result[screen.externalConnectionFingerprint] = screen
        }
        return result
    }
}
