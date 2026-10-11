import AppKit
import SwiftUI

private final class RecordingDefaults: UserDefaults, @unchecked Sendable {
    var writes = 0
    var reads = 0
    override func set(_ value: Any?, forKey key: String) {
        writes += 1
        super.set(value, forKey: key)
    }
    override func string(forKey key: String) -> String? {
        reads += 1
        return super.string(forKey: key)
    }
}

@main
private enum HelperAppearanceRegression {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = nil
        let systemAppearance = app.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        let suite = "com.waifux.test.appearance.\(UUID().uuidString)"
        let defaults = RecordingDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var count = 0
        func check(_ condition: Bool, _ name: String) {
            precondition(condition, name)
            count += 1
            print("PASS \(name)")
        }
        let manager = ThemeManager(preferences: defaults)
        check(defaults.reads == 0 && defaults.writes == 0, "theme initialization does not touch preferences")
        manager.restoreSavedSettings()
        check(manager.themeMode == .dark && app.appearance?.name == .darkAqua, "missing preference preserves the original dark appearance")
        check(defaults.writes == 0, "restoring the default does not persist a new value")

        defaults.set(ThemeMode.light.rawValue, forKey: ThemeManager.legacyPreferencesKey)
        let writesBeforeRestore = defaults.writes
        manager.restoreSavedSettings()
        check(manager.themeMode == .light && app.appearance?.name == .aqua, "legacy appearance is restored in the shared domain")
        check(defaults.writes == writesBeforeRestore, "legacy restoration generates no mutation")
        defaults.set(ThemeMode.dark.rawValue, forKey: ThemeManager.preferencesKey)
        manager.restoreSavedSettings()
        check(manager.themeMode == .dark, "canonical setting takes precedence over legacy setting")
        defaults.set("invalid", forKey: ThemeManager.preferencesKey)
        manager.restoreSavedSettings()
        check(manager.themeMode == .light, "invalid canonical value falls back to valid legacy preference")
        defaults.set("invalid", forKey: ThemeManager.legacyPreferencesKey)
        manager.restoreSavedSettings()
        check(manager.themeMode == .dark, "invalid preferences preserve the default dark appearance")

        let writesBeforeEdit = defaults.writes
        manager.themeMode = .light
        check(defaults.writes == writesBeforeEdit + 1 && defaults.string(forKey: ThemeManager.preferencesKey) == ThemeMode.light.rawValue, "user edit writes the canonical key once")
        check(defaults.string(forKey: ThemeManager.legacyPreferencesKey) == "invalid", "user edit preserves the legacy key")
        check(!manager.isDarkMode && app.appearance?.name == .aqua, "light appearance is applied before the next frame")
        manager.themeMode = .system
        check(app.appearance == nil, "following system clears the previous forced light appearance")
        check(app.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == systemAppearance, "system mode inherits the actual AppKit system appearance")
        manager.themeMode = .dark
        manager.themeMode = .system
        check(app.appearance == nil && manager.isDarkMode == (systemAppearance == .darkAqua), "dark to system does not keep the previous dark override")

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 120, height: 80), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: RoundedRectangle(cornerRadius: 16).fill(.ultraThinMaterial))
        panel.contentView = host
        manager.themeMode = .dark
        check(panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua, "menu panel inherits the restored dark appearance")
        check(host.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua, "hosted material inherits dark appearance")
        manager.themeMode = .light
        check(host.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua, "existing hosted material follows a live light theme change")
        manager.themeMode = .system
        check(host.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == systemAppearance, "existing material returns to system appearance")
        panel.close()
        print("HELPER_APPEARANCE_REGRESSION_PASSED role=\(BackgroundRuntimeRole.isHelper ? "helper" : "ui") checks=\(count)")
    }
}
