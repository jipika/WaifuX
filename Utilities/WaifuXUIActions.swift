import AppKit

/// Runtime services request a UI action without depending on AppDelegate.
@MainActor
enum WaifuXUIActions {
    enum Action: String, Codable, Sendable {
        case main, library, wallpaperDetail, settings, scheduler, updates, releaseMemory
    }

    static var handler: ((Action) -> Void)?

    static func perform(_ action: Action) {
        handler?(action)
    }
}
