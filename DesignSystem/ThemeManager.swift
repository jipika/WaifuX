import AppKit
import SwiftUI
import Combine

enum ThemeMode: String, CaseIterable, Identifiable {
    case dark = "深色"
    case light = "浅色"
    case system = "跟随系统"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .dark: return "moon.fill"
        case .light: return "sun.max.fill"
        case .system: return "macpro.gen1"
        }
    }
}

/// The UI and Helper use the same preference domain and appearance policy.
@MainActor
final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()
    static let preferencesKey = "theme_mode"
    static let legacyPreferencesKey = "themeMode"

    @Published var themeMode: ThemeMode = .dark {
        didSet {
            if !isRestoring { preferences.set(themeMode.rawValue, forKey: Self.preferencesKey) }
            applyTheme()
        }
    }

    var isDarkMode: Bool {
        switch themeMode {
        case .dark: return true
        case .light: return false
        case .system: return NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }
    }

    private let injectedPreferences: UserDefaults?
    private var preferences: UserDefaults { injectedPreferences ?? WaifuXPreferences.shared }
    private var isRestoring = false
    private var cancellables = Set<AnyCancellable>()

    // Preference injection lets AppKit regressions use an isolated domain.
    // No defaults are initialized/read here: restoration happens after launch.
    init(preferences: UserDefaults? = nil) {
        injectedPreferences = preferences
        DistributedNotificationCenter.default
            .publisher(for: Notification.Name("AppleInterfaceThemeChangedNotification"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        applyTheme()
    }

    static func savedMode(in preferences: UserDefaults) -> ThemeMode {
        for key in [preferencesKey, legacyPreferencesKey] {
            if let raw = preferences.string(forKey: key), let mode = ThemeMode(rawValue: raw) { return mode }
        }
        return .dark
    }

    /// Restore without generating another preference mutation or overwriting
    /// the legacy key needed by older installations.
    func restoreSavedSettings() {
        isRestoring = true
        defer { isRestoring = false }
        themeMode = Self.savedMode(in: preferences)
    }

    func applyTheme() {
        objectWillChange.send()
        switch themeMode {
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .system: NSApp.appearance = nil
        }
    }

    var backgroundSnapshot: [String: Any] {
        ["mode": themeMode.rawValue,
         "appearance": NSApp.appearance?.name.rawValue ?? "system",
         "effectiveAppearance": NSApp.effectiveAppearance.name.rawValue]
    }
}
