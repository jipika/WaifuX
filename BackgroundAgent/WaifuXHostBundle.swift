import Foundation

/// Locates the outer WaifuX.app when code runs from the nested Helper app.
/// A standalone Helper build intentionally falls back to its own bundle.
enum WaifuXHostBundle {
    static let bundleURL: URL = {
        let current = Bundle.main
        guard current.bundleIdentifier == BackgroundAgentWire.bundleIdentifier else {
            return current.bundleURL
        }
        let candidate = current.bundleURL
            .deletingLastPathComponent() // Contents/Helpers
            .deletingLastPathComponent() // Contents
            .deletingLastPathComponent() // WaifuX.app
        guard Bundle(url: candidate)?.bundleIdentifier == "com.waifux.app" else {
            return current.bundleURL
        }
        return candidate
    }()

    static var resourcesURL: URL {
        bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
    }

    static func resourceCandidates(named name: String) -> [URL] {
        [
            resourcesURL.appendingPathComponent(name),
            resourcesURL.appendingPathComponent("Resources/\(name)")
        ]
    }
}
