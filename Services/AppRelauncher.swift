import AppKit

/// Restart only after the normal UI exit gate has saved all pending settings.
/// On timeout/failure the existing UI remains open and no second UI is launched.
@MainActor
enum AppRelauncher {
    static func relaunch() {
        AppDelegate.shared?.relaunchInterface()
    }
}
