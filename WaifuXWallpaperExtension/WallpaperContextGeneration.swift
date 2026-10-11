// Pure lifecycle gate shared by live context setup and regression tests.
// Removed contexts have no valid token; a reused ID receives a fresh token.
struct WallpaperContextGeneration: Sendable {
    private var nextGeneration: UInt64 = 0
    private var generations: [UInt32: UInt64] = [:]
    private var finishedGenerations: [UInt32: UInt64] = [:]
    private var owners: [UInt32: UInt64] = [:]

    /// Ownership changes only when a CAContext is newly admitted. Replacing
    /// its media changes the setup token while preserving connection ownership.
    mutating func admit(_ contextID: UInt32) -> UInt64 {
        let generation = begin(contextID)
        owners[contextID] = generation
        return generation
    }

    func isOwned(by owner: UInt64, contextID: UInt32) -> Bool { owners[contextID] == owner }

    mutating func begin(_ contextID: UInt32) -> UInt64 {
        nextGeneration &+= 1
        generations[contextID] = nextGeneration
        finishedGenerations.removeValue(forKey: contextID)
        return nextGeneration
    }

    func isCurrent(_ generation: UInt64, for contextID: UInt32) -> Bool {
        generations[contextID] == generation
    }

    func isPending(_ generation: UInt64, for contextID: UInt32) -> Bool {
        isCurrent(generation, for: contextID) && finishedGenerations[contextID] != generation
    }

    mutating func finish(_ generation: UInt64, for contextID: UInt32) {
        guard isCurrent(generation, for: contextID) else { return }
        finishedGenerations[contextID] = generation
    }

    mutating func remove(_ contextID: UInt32) {
        generations.removeValue(forKey: contextID)
        finishedGenerations.removeValue(forKey: contextID)
        owners.removeValue(forKey: contextID)
    }
    mutating func removeAll() {
        generations.removeAll()
        finishedGenerations.removeAll()
        owners.removeAll()
    }
}
