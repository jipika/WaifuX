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
        previousExternalFingerprints = currentFingerprints

        guard !connectedFingerprints.isEmpty else { return }

        for fingerprint in connectedFingerprints {
            guard let screen = screensByFingerprint[fingerprint] else { continue }
            handleConnectedExternalDisplay(screen)
        }
    }

    private func handleConnectedExternalDisplay(_ screen: NSScreen) {
        Task { @MainActor in
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

        return false
    }

    private func presentNextPromptIfNeeded() {
        guard !isPresentingPrompt, !pendingDisplays.isEmpty else { return }
        isPresentingPrompt = true
        let display = pendingDisplays.removeFirst()

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "检测到新外接显示器"
        alert.informativeText = "\(display.name) 已连接。要为这块显示器设置动态壁纸吗？"
        alert.addButton(withTitle: "使用随机壁纸")
        alert.addButton(withTitle: "去挑选壁纸")
        alert.addButton(withTitle: "不使用壁纸")

        let autoSwitchCheckbox = NSButton(checkboxWithTitle: "此显示器连接后自动切换", target: nil, action: nil)
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
