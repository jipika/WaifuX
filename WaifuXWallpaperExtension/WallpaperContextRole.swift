import Foundation

/// Presentation identity comes from the request/owning XPC connection, never
/// from layer dimensions. Unknown or ambiguous contexts cannot unlock a handoff.
enum WallpaperContextRole: String, Sendable {
    case unknown, desktop, lockScreen, preview

    static func explicit(isPreview: Bool, destination: String?) -> Self {
        if isPreview { return .preview }
        guard let destination else { return .unknown }
        let value = destination.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch value {
        case "desktop", ".desktop": return .desktop
        case "lockscreen", ".lockscreen", "lock-screen": return .lockScreen
        case "preview", ".preview": return .preview
        default: return .unknown
        }
    }

    func updated(mode: String, explicit: Bool, uniquelyAddressed: Bool) -> Self {
        // Raw presentation updates may add missing evidence for one unambiguous
        // context. They are not acquire-destination evidence and must never
        // reclassify a known desktop, lock screen, or preview.
        guard self == .unknown, !explicit, uniquelyAddressed else { return self }
        switch mode {
        case "default", "active": return .desktop
        case "locked": return .lockScreen
        default: return .unknown
        }
    }
}
