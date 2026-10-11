import Foundation

/// Guards the multi-display XPC teardown contract. A WallpaperAgent connection
/// can represent only one instance while the extension process owns contexts
/// for several instances; invalidating one connection must not call the global
/// removeAllContexts path.
@main
struct ExtensionMultiDisplayConnectionRegression {
    static func main() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let state = try source("WaifuXWallpaperExtension/WallpaperState.swift", from: root)
        let handler = try source("WaifuXWallpaperExtension/WallpaperXPCHandler.swift", from: root)
        let extensionMain = try source("WaifuXWallpaperExtension/WaifuXWallpaperExtension.swift", from: root)

        precondition(state.contains("func removeContexts(ids: Set<UInt32>, ownedBy owners: [UInt32: UInt64]?"),
                     "WallpaperState must expose per-connection context cleanup")
        precondition(handler.contains("ownedContexts: [UInt32: UInt64]"),
                     "XPC handlers must track the contexts they acquired")
        precondition(handler.contains("beginOwnedContext(placeholder)"),
                     "acquire must register context ownership before async setup")
        precondition(extensionMain.contains("WallpaperState.shared.removeContexts(ids: ownedContextIDs, ownedBy: ownedContexts)"),
                     "XPC invalidation must reclaim only the invalidated connection's contexts")
        precondition(state.contains("state.contextGenerations.isOwned(by: owner, contextID: id)"),
                     "cleanup must reject an obsolete connection ownership token")
        precondition(extensionMain.contains("if remaining > 0"),
                     "one invalidated display connection must not exit a live multi-display extension")

        print("Extension multi-display connection regression passed")
    }

    private static func source(_ relativePath: String, from root: URL) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
