import SwiftUI
import Combine

// MARK: - 屏幕角落定位

public enum ClockCorner: String, CaseIterable, Codable, Sendable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    public var label: String {
        switch self {
        case .topLeft:     return "左上"
        case .topRight:    return "右上"
        case .bottomLeft:  return "左下"
        case .bottomRight: return "右下"
        }
    }
}

// MARK: - 时钟格式

public enum ClockFormat: String, CaseIterable, Codable, Sendable {
    /// 仅 HH:mm
    case hhmm
    /// HH:mm:ss
    case hhmmss
    /// HH:mm + 日期
    case hhmmWithDate
    /// HH:mm:ss + 日期
    case hhmmssWithDate
    /// HH:mm + 日期 + 星期
    case full

    public var label: String {
        switch self {
        case .hhmm:          return "HH:mm"
        case .hhmmss:        return "HH:mm:ss"
        case .hhmmWithDate:  return "HH:mm + 日期"
        case .hhmmssWithDate:return "HH:mm:ss + 日期"
        case .full:          return "完整（含星期）"
        }
    }
}

// MARK: - 液态玻璃时钟配置
/// ═══════════════════════════════════════════════════════
/// 所有未来自定义参数加在此处，保持 Codable 以支持持久化
/// ═══════════════════════════════════════════════════════

public struct LiquidGlassClockConfiguration: Codable, Equatable {

    // MARK: - 基础开关
    /// 时钟 overlay 总开关
    public var enabled: Bool = false

    // MARK: - 布局
    /// 屏幕角落定位
    public var corner: ClockCorner = .bottomRight
    /// 距屏幕边缘的偏移量（水平）
    public var horizontalPadding: CGFloat = 24
    /// 距屏幕边缘的偏移量（垂直）
    public var verticalPadding: CGFloat = 24
    /// 自定义偏移量（当 corner 为 custom 时生效，预留）
    public var customOffsetX: CGFloat = 0
    public var customOffsetY: CGFloat = 0

    // MARK: - 时间格式
    /// 时钟格式
    public var format: ClockFormat = .hhmmWithDate
    /// 12 小时制（false = 24 小时制）
    public var use12Hour: Bool = false
    /// 前置补零（如 09:05 而非 9:5）
    public var padHour: Bool = true

    // MARK: - 显示元素
    /// 显示秒数（对 .hhmm / .hhmmWithDate 格式也生效）
    public var showSeconds: Bool = false
    /// 显示日期
    public var showDate: Bool = true
    /// 显示星期
    public var showWeekday: Bool = false

    // MARK: - 视觉样式
    /// 玻璃效果变体
    public var glassVariant: String = "regular" // "regular" | "prominent" | "subtle" | "clear"
    /// 强调色（十六进制）
    public var accentColorHex: String = "8B5CF6"
    /// 整体不透明度 0~1
    public var opacity: Double = 0.92
    /// 时间字号
    public var timeFontSize: CGFloat = 48
    /// 日期/星期字号
    public var dateFontSize: CGFloat = 16
    /// 时钟圆角
    public var cornerRadius: CGFloat = 20

    // MARK: - 动效（预留）
    /// 启用过渡动画
    public var animationEnabled: Bool = true
    /// 数字切换动画（如翻牌效果，预留）
    public var digitAnimation: String = "opacity" // "opacity" | "slide" | "flip"

    // MARK: - 音频可视化
    /// 启用音频柱状图
    public var showAudioVisualizer: Bool = false
    /// 频段数 (16/32/64)
    public var audioBarCount: Int = 32
    /// 柱状图高度
    public var audioBarHeight: CGFloat = 40
    /// 柱体间距
    public var audioBarSpacing: CGFloat = 2
    /// 灵敏度 (0.5~2.0)
    public var audioSensitivity: Double = 1.2
    /// 柱体颜色（十六进制）
    public var audioBarColorHex: String = "8B5CF6"
    /// 高亮色（十六进制）
    public var audioHighlightColorHex: String = "00D4FF"
    /// 显示柱体顶部发光
    public var audioShowTopGlow: Bool = true
    /// 显示镜面反射
    public var audioShowMirror: Bool = false

    // MARK: - Metal 渲染参数（预留）
    /// 启用 Metal 着色器背景效果（毛玻璃/辉光）
    public var metalShaderEnabled: Bool = false
    /// Metal 着色器强度 0~1
    public var metalShaderIntensity: Double = 0.5
    /// 着色器效果类型（预留）
    public var metalShaderEffect: String = "glass" // "glass" | "glow" | "frost"

    // MARK: - 自定义文本（预留）
    /// 自定义前缀文字（如 "Now: "）
    public var customPrefix: String = ""
    /// 自定义后缀文字
    public var customSuffix: String = ""

    // MARK: - 日期/星期格式（预留）
    /// 日期格式，如 "yyyy-MM-dd"（nil = 自动本地化）
    public var dateFormat: String?
    /// 星期名称语言（zh/en/ja）
    public var weekdayLocale: String = "zh"

    public init() {}

    // MARK: - Equatable
    public static func == (lhs: LiquidGlassClockConfiguration, rhs: LiquidGlassClockConfiguration) -> Bool {
        lhs.enabled == rhs.enabled &&
        lhs.corner == rhs.corner &&
        lhs.horizontalPadding == rhs.horizontalPadding &&
        lhs.verticalPadding == rhs.verticalPadding &&
        lhs.format == rhs.format &&
        lhs.use12Hour == rhs.use12Hour &&
        lhs.showSeconds == rhs.showSeconds &&
        lhs.showDate == rhs.showDate &&
        lhs.showWeekday == rhs.showWeekday &&
        lhs.showAudioVisualizer == rhs.showAudioVisualizer &&
        lhs.audioBarCount == rhs.audioBarCount &&
        lhs.glassVariant == rhs.glassVariant &&
        lhs.accentColorHex == rhs.accentColorHex &&
        lhs.opacity == rhs.opacity &&
        lhs.timeFontSize == rhs.timeFontSize &&
        lhs.dateFontSize == rhs.dateFontSize
    }
}

// MARK: - 便捷访问

extension LiquidGlassClockConfiguration {
    /// 当前玻璃变体
    public var glassLevel: LiquidGlassLevel {
        switch glassVariant {
        case "prominent": return .prominent
        case "subtle":    return .subtle
        case "clear":     return .subtle
        default:          return .regular
        }
    }

    /// 当前强调色
    public var accentColor: Color {
        Color(hex: accentColorHex)
    }

    /// 音频可视化配置
    public var audioVisualizerConfig: AudioVisualizerConfig {
        var c = AudioVisualizerConfig()
        c.barCount = audioBarCount
        c.barHeight = audioBarHeight
        c.barSpacing = audioBarSpacing
        c.sensitivity = CGFloat(audioSensitivity)
        c.barColor = Color(hex: audioBarColorHex)
        c.highlightColor = Color(hex: audioHighlightColorHex)
        c.showTopGlow = audioShowTopGlow
        c.showMirror = audioShowMirror
        c.animationEnabled = animationEnabled
        return c
    }

    /// 当前日期的星期名称
    public func weekdayString(for date: Date) -> String {
        let formatter = WeekdayFormatter(locale: weekdayLocale)
        return formatter.string(from: date)
    }

    /// 当前日期的日期字符串
    public func dateString(for date: Date) -> String {
        if let fmt = dateFormat {
            let df = DateFormatter()
            df.dateFormat = fmt
            return df.string(from: date)
        }
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = "M月d日"
        return df.string(from: date)
    }

    /// 时间字符串
    public func timeString(for date: Date) -> String {
        let df = DateFormatter()
        if use12Hour {
            df.locale = Locale(identifier: "en_US")
            df.dateFormat = showSeconds ? "h:mm:ss a" : "h:mm a"
        } else {
            df.locale = Locale(identifier: "zh_CN")
            df.dateFormat = showSeconds ? "HH:mm:ss" : (padHour ? "HH:mm" : "H:mm")
        }
        return df.string(from: date)
    }
}

// MARK: - 星期格式化器

private struct WeekdayFormatter {
    let locale: String

    private let weekdaySymbols: [String: [String]] = [
        "zh": ["周日", "周一", "周二", "周三", "周四", "周五", "周六"],
        "en": ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"],
        "ja": ["日", "月", "火", "水", "木", "金", "土"],
    ]

    func string(from date: Date) -> String {
        let cal = Calendar.current
        let weekday = cal.component(.weekday, from: date) - 1
        let symbols = weekdaySymbols[locale] ?? weekdaySymbols["zh"]!
        return symbols.indices.contains(weekday) ? symbols[weekday] : ""
    }
}

// MARK: - 持久化管理器

@MainActor
public final class LiquidGlassClockSettings: ObservableObject {
    public static let shared = LiquidGlassClockSettings()

    @Published public var config: LiquidGlassClockConfiguration = .init() {
        didSet { onChangeNotifier?() }
    }

    private var cancellables = Set<AnyCancellable>()
    private var onChangeNotifier: (() -> Void)?
    private let configKey = "liquid_glass_clock_config_v2"

    private init() {
        load()
        // 自动持久化（防抖）
        $config
            .debounce(for: .seconds(0.3), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.save()
            }
            .store(in: &cancellables)
    }

    /// 更新配置并持久化
    public func update(_ mutation: (inout LiquidGlassClockConfiguration) -> Void) {
        var newConfig = config
        mutation(&newConfig)
        config = newConfig
    }

    /// 切换开关
    public func toggle() {
        config.enabled.toggle()
    }

    // MARK: - 持久化
    private func load() {
        guard let data = UserDefaults.standard.data(forKey: configKey),
              let decoded = try? JSONDecoder().decode(LiquidGlassClockConfiguration.self, from: data)
        else { return }
        config = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(config) else { return }
        UserDefaults.standard.set(data, forKey: configKey)
    }
}
