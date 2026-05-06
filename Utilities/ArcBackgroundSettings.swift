import SwiftUI
import AppKit
import Combine

// MARK: - Arc 风格背景模式

enum ArcThemeMode: String, CaseIterable, Identifiable {
    case auto = "auto"
    case light = "light"
    case dark = "dark"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .auto: return "sparkles"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }

    var label: String {
        switch self {
        case .auto: return "自动"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }
}

// MARK: - Arc 背景设置管理器

@MainActor
final class ArcBackgroundSettings: ObservableObject {
    static let shared = ArcBackgroundSettings()

    /// 主题模式
    @Published var themeMode: ArcThemeMode = .auto
    /// 主色调（影响光晕和强调色）
    @Published var accentColor: Color = Color(hex: "8B5CF6")
    /// 磨砂强度 0.0~1.0
    @Published var frostedIntensity: Double = 0.55
    /// 是否启用桌面颗粒纹理
    @Published var grainTextureEnabled: Bool = false
    /// 桌面颗粒强度 0.0~1.0
    @Published var grainIntensity: Double = 0.5
    /// 点阵透明度
    @Published var dotGridOpacity: Double = 0.05
    /// 是否启用噪点纹理（桌面用）
    @Published var useNoiseTexture: Bool = false

    // MARK: - 探索页独立颗粒强度（各自持久化）

    @Published var exploreGrainWallpaper: Double = 0.5
    @Published var exploreGrainAnime: Double = 0.5
    @Published var exploreGrainMedia: Double = 0.5
    /// 当前实际是否为浅色模式（只读，由 themeMode + 系统主题计算）
    @Published private(set) var isLightMode: Bool = false

    /// 预设颜色盘
    let presetColors: [Color] = [
        Color(hex: "8B5CF6"), // 紫
        Color(hex: "EC4899"), // 粉
        Color(hex: "EF4444"), // 红
        Color(hex: "F97316"), // 橙
        Color(hex: "EAB308"), // 黄
        Color(hex: "22C55E"), // 绿
        Color(hex: "06B6D4"), // 青
        Color(hex: "3B82F6"), // 蓝
        Color(hex: "6366F1"), // 靛
        Color(hex: "78716C"), // 暖灰
    ]

    private var cancellables = Set<AnyCancellable>()

    private init() {
        loadSettings()
        updateLightMode()

        DistributedNotificationCenter.default
            .publisher(for: Notification.Name("AppleInterfaceThemeChangedNotification"))
            .sink { [weak self] _ in
                self?.updateLightMode()
            }
            .store(in: &cancellables)

        // 颗粒开关联动：grainTextureEnabled 控制桌面 useNoiseTexture
        $grainTextureEnabled
            .sink { [weak self] enabled in
                self?.useNoiseTexture = enabled
            }
            .store(in: &cancellables)

        // 持久化监听
        Publishers.MergeMany(
            $themeMode.map { _ in () }.eraseToAnyPublisher(),
            $accentColor.map { _ in () }.eraseToAnyPublisher(),
            $frostedIntensity.map { _ in () }.eraseToAnyPublisher(),
            $grainTextureEnabled.map { _ in () }.eraseToAnyPublisher(),
            $grainIntensity.map { _ in () }.eraseToAnyPublisher(),
            $dotGridOpacity.map { _ in () }.eraseToAnyPublisher(),
            $useNoiseTexture.map { _ in () }.eraseToAnyPublisher(),
            $exploreGrainWallpaper.map { _ in () }.eraseToAnyPublisher(),
            $exploreGrainAnime.map { _ in () }.eraseToAnyPublisher(),
            $exploreGrainMedia.map { _ in () }.eraseToAnyPublisher()
        )
        .debounce(for: .seconds(0.3), scheduler: RunLoop.main)
        .sink { [weak self] in
            self?.saveSettings()
        }
        .store(in: &cancellables)
    }

    // MARK: - 派生颜色

    /// 背景基础色（Arc 风格：浅灰白或深灰黑）
    var baseBackground: Color {
        isLightMode ? Color(hex: "F5F5F0") : Color(hex: "121214")
    }

    /// 表面色（面板底色倾向）
    var surfaceColor: Color {
        isLightMode ? Color(hex: "FFFFFF") : Color(hex: "1C1C1E")
    }

    /// 主文字色
    var primaryText: Color {
        isLightMode ? Color(hex: "1A1A1A") : Color.white
    }

    /// 次级文字色
    var secondaryText: Color {
        isLightMode ? Color(hex: "666666") : Color.white.opacity(0.7)
    }

    /// 点阵颜色
    var dotColor: Color {
        isLightMode ? Color.black : Color.white
    }

    /// 边框颜色
    var borderColor: Color {
        isLightMode ? Color.black.opacity(0.08) : Color.white.opacity(0.12)
    }

    /// 磨砂材质底色（用于非系统 Material 的 fallback）
    var frostedTint: Color {
        isLightMode ? Color.white.opacity(0.45 + frostedIntensity * 0.3)
                    : Color.white.opacity(0.08 + frostedIntensity * 0.12)
    }

    // MARK: - 操作

    func randomizeAccent() {
        accentColor = presetColors.randomElement() ?? accentColor
    }

    func setThemeMode(_ mode: ArcThemeMode) {
        themeMode = mode
        updateLightMode()
    }

    private func updateLightMode() {
        switch themeMode {
        case .light:
            isLightMode = true
        case .dark:
            isLightMode = false
        case .auto:
            isLightMode = isSystemLightMode
        }
    }

    // MARK: - 持久化

    private func loadSettings() {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: "arc_theme_mode"),
           let mode = ArcThemeMode(rawValue: raw) {
            themeMode = mode
        }
        if let hex = defaults.string(forKey: "arc_accent_color") {
            accentColor = Color(hex: hex)
        }
        frostedIntensity = defaults.double(forKey: "arc_frosted_intensity").clamped(to: 0...1)
        if frostedIntensity == 0 { frostedIntensity = 0.55 }
        grainTextureEnabled = defaults.object(forKey: "grain_texture_enabled") as? Bool ?? false
        grainIntensity = defaults.double(forKey: "arc_grain_intensity").clamped(to: 0...1)
        if grainIntensity == 0 { grainIntensity = 0.5 }
        dotGridOpacity = defaults.double(forKey: "arc_dot_grid_opacity").clamped(to: 0...1)
        if dotGridOpacity == 0 { dotGridOpacity = 0.05 }
        useNoiseTexture = defaults.object(forKey: "arc_use_noise") as? Bool ?? false
        // 探索页独立颗粒强度
        let gw = defaults.double(forKey: "explore_grain_wallpaper")
        exploreGrainWallpaper = gw > 0 ? gw : 0.5
        let ga = defaults.double(forKey: "explore_grain_anime")
        exploreGrainAnime = ga > 0 ? ga : 0.5
        let gm = defaults.double(forKey: "explore_grain_media")
        exploreGrainMedia = gm > 0 ? gm : 0.5
    }

    private func saveSettings() {
        let defaults = UserDefaults.standard
        defaults.set(themeMode.rawValue, forKey: "arc_theme_mode")
        defaults.set(accentColor.toHex() ?? "8B5CF6", forKey: "arc_accent_color")
        defaults.set(frostedIntensity, forKey: "arc_frosted_intensity")
        defaults.set(grainTextureEnabled, forKey: "grain_texture_enabled")
        defaults.set(grainIntensity, forKey: "arc_grain_intensity")
        defaults.set(dotGridOpacity, forKey: "arc_dot_grid_opacity")
        defaults.set(useNoiseTexture, forKey: "arc_use_noise")
        // 探索页独立颗粒强度
        defaults.set(exploreGrainWallpaper, forKey: "explore_grain_wallpaper")
        defaults.set(exploreGrainAnime, forKey: "explore_grain_anime")
        defaults.set(exploreGrainMedia, forKey: "explore_grain_media")
    }
}

// MARK: - 辅助

@MainActor
private var isSystemLightMode: Bool {
    let appearance = NSApp.effectiveAppearance
    var isLight = false
    appearance.performAsCurrentDrawingAppearance {
        isLight = appearance.name != .darkAqua
    }
    return isLight
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

private extension Color {
    func toHex() -> String? {
        let nsColor = NSColor(self)
        guard let rgb = nsColor.usingColorSpace(.sRGB) else { return nil }
        let r = Int(rgb.redComponent * 255)
        let g = Int(rgb.greenComponent * 255)
        let b = Int(rgb.blueComponent * 255)
        return String(format: "%02X%02X%02X", r, g, b)
    }
}
