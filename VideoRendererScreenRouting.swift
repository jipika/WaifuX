import Foundation

/// Resolve a command against the renderer's current display topology.
/// A stale index must never take the place of an unmatched physical display ID.
enum VideoRendererScreenRouting {
    struct Screen {
        let identifier: String
        let fingerprint: String
    }

    static func resolvedIndex(
        stableID: String,
        screens: [Screen],
        previousScreens: [Screen] = [],
        expectedFingerprint: String? = nil
    ) -> Int? {
        let directMatches = screens.indices.filter { screens[$0].identifier == stableID }
        guard directMatches.count <= 1 else { return nil }
        let previousMatches = previousScreens.filter { $0.identifier == stableID }
        guard expectedFingerprint != nil || previousMatches.count <= 1 else { return nil }
        if let fingerprint = expectedFingerprint ?? previousMatches.first?.fingerprint {
            if let index = directMatches.first, screens[index].fingerprint == fingerprint { return index }
            let physicalMatches = screens.indices.filter {
                stablePart(screens[$0].fingerprint) == stablePart(fingerprint)
            }
            return physicalMatches.count == 1 ? physicalMatches[0] : nil
        }
        if directMatches.count == 1 { return directMatches[0] }
        if !directMatches.isEmpty { return nil }

        let fingerprintMatches = screens.indices.filter { screens[$0].fingerprint == stableID }
        if fingerprintMatches.count == 1 { return fingerprintMatches[0] }
        if !fingerprintMatches.isEmpty { return nil }

        // CG display IDs may be reassigned during sleep or hotplug. The
        // renderer can still identify a display it already owned by its
        // physical fingerprint, provided both sides of the match are unique.
        return nil
    }

    private static func stablePart(_ fingerprint: String) -> String {
        fingerprint.components(separatedBy: ":position:").first ?? fingerprint
    }
}
