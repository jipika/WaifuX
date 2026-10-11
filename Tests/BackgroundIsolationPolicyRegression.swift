import Foundation

@main
struct BackgroundIsolationPolicyRegression {
    static func main() throws {
        let expectedRendering = CommandLine.arguments[1] == "rendering"
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw CocoaError(.coderInvalidValue) }
            print("PASS \(message)")
        }
        try check(BackgroundRuntimeRole.allowsDesktopRendering == expectedRendering,
                  "desktop output follows the explicit test boundary")
        for operation in ["video.apply", "video.applySingle", "engine.apply", "wallpaper.static",
                          "desktop.restore", "lock.syncCatalog", "clock.settings", "bake.video.wait",
                          "overlay.notch", "overlay.grain", "overlay.clock", "overlay.staticRefresh",
                          "dsh.set.wait", "dsh.clear.wait", "saver.sync", "saver.syncNow"] {
            try check(BackgroundRuntimeRole.permitsOperation(operation) == expectedRendering,
                      "\(operation) cannot bypass the isolated rendering boundary")
        }
        for operation in ["bootstrap", "preferences.set", "library.snapshot", "runtime.stop", "test.preference"] {
            try check(BackgroundRuntimeRole.permitsOperation(operation),
                      "\(operation) remains available for non-rendering regression")
        }
    }
}
