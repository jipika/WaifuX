import SwiftUI

// 导入 ThemeManager（如果可用）
// 注意：ThemeManager 定义在 DesignSystem/ThemeManager.swift 中

// MARK: - Liquid Glass 设计系统
// 基于 Apple 官方 Liquid Glass API (macOS 26+) 的兼容实现
// 文档: https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views/

// MARK: - 颜色系统
public enum LiquidGlassColors {
    // 主色调（不随主题变化）
    public static let primaryPink = Color(hex: "FF3366")
    public static let secondaryViolet = Color(hex: "8B5CF6")
    public static let tertiaryBlue = Color(hex: "3B8BFF")
    public static let accentCyan = Color(hex: "00D4FF")
    public static let accentOrange = Color(hex: "FF6B35")
    public static let onlineGreen = Color(hex: "34D399")
    public static let warningOrange = Color(hex: "FF9F43")

    // 背景色（随主题变化，默认为深色）
    @MainActor
    public static var deepBackground: Color {
        ThemeManager.shared.isDarkMode ? Color(hex: "0D0D0D") : Color(hex: "F5F5F7")
    }
    
    @MainActor
    public static var midBackground: Color {
        ThemeManager.shared.isDarkMode ? Color(hex: "12121F") : Color(hex: "EBEBF0")
    }
    
    @MainActor
    public static var surfaceBackground: Color {
        ThemeManager.shared.isDarkMode ? Color(hex: "1A1A2E") : Color(hex: "FFFFFF")
    }
    
    @MainActor
    public static var elevatedBackground: Color {
        ThemeManager.shared.isDarkMode ? Color(hex: "1E1E28") : Color(hex: "F0F0F5")
    }

    // 玻璃效果颜色（随主题变化）
    @MainActor
    public static var glassWhite: Color {
        ThemeManager.shared.isDarkMode ? Color.white.opacity(0.26) : Color.black.opacity(0.12)
    }
    
    @MainActor
    public static var glassWhiteLight: Color {
        ThemeManager.shared.isDarkMode ? Color.white.opacity(0.34) : Color.black.opacity(0.16)
    }
    
    @MainActor
    public static var glassWhiteSubtle: Color {
        ThemeManager.shared.isDarkMode ? Color.white.opacity(0.16) : Color.black.opacity(0.08)
    }
    
    @MainActor
    public static var glassBorder: Color {
        ThemeManager.shared.isDarkMode ? Color.white.opacity(0.34) : Color.black.opacity(0.2)
    }
    
    @MainActor
    public static var glassBorderLight: Color {
        ThemeManager.shared.isDarkMode ? Color.white.opacity(0.46) : Color.black.opacity(0.24)
    }
    
    @MainActor
    public static var glassWhiteStrong: Color {
        ThemeManager.shared.isDarkMode ? Color.white.opacity(0.42) : Color.black.opacity(0.22)
    }
    
    @MainActor
    public static var glassTint: Color {
        ThemeManager.shared.isDarkMode ? Color.white.opacity(0.12) : Color.black.opacity(0.05)
    }

    // 玻璃高光
    @MainActor
    public static var glassHighlight: Color {
        ThemeManager.shared.isDarkMode ? Color.white.opacity(0.7) : Color.black.opacity(0.36)
    }
    
    @MainActor
    public static var glassHighlightSubtle: Color {
        ThemeManager.shared.isDarkMode ? Color.white.opacity(0.4) : Color.black.opacity(0.2)
    }

    // 文字颜色（随主题变化）
    @MainActor
    public static var textPrimary: Color {
        ThemeManager.shared.isDarkMode ? Color.white : Color(hex: "1A1A1A")
    }
    
    @MainActor
    public static var textSecondary: Color {
        ThemeManager.shared.isDarkMode ? Color.white.opacity(0.7) : Color(hex: "666666")
    }
    
    @MainActor
    public static var textTertiary: Color {
        ThemeManager.shared.isDarkMode ? Color.white.opacity(0.5) : Color(hex: "999999")
    }
    
    @MainActor
    public static var textQuaternary: Color {
        ThemeManager.shared.isDarkMode ? Color.white.opacity(0.3) : Color(hex: "BBBBBB")
    }

    // 边框颜色
    @MainActor
    public static var borderSubtle: Color {
        ThemeManager.shared.isDarkMode ? Color.white.opacity(0.1) : Color.black.opacity(0.08)
    }
    
    @MainActor
    public static var borderDefault: Color {
        ThemeManager.shared.isDarkMode ? Color.white.opacity(0.2) : Color.black.opacity(0.12)
    }
    
    @MainActor
    public static var borderStrong: Color {
        ThemeManager.shared.isDarkMode ? Color.white.opacity(0.3) : Color.black.opacity(0.18)
    }

    // 发光色（不随主题变化）
    public static let glowPink = Color(hex: "FF3B6B").opacity(0.4)
    public static let glowViolet = Color(hex: "9D6FFF").opacity(0.4)
    public static let glowBlue = Color(hex: "3B8BFF").opacity(0.4)

    // MARK: - 播放器专用颜色（固定颜色，不随主题变化）
    public static let playerBarBackground = Color(hex: "232A36")
    public static let playerBarBackgroundLight = Color(hex: "2A313F")
    public static let playerBarBorder = Color.white.opacity(0.15)
    public static let playerBarShadow = Color.black.opacity(0.25)
}

// MARK: - Glass 变体枚举
public enum GlassVariant {
    case regular
    case interactive
    case tinted(Color)
    case prominent
    case clear
}

public enum LiquidGlassLevel {
    case subtle
    case regular
    case prominent
    case max

    var material: Material {
        switch self {
        case .subtle:
            return .ultraThinMaterial
        case .regular:
            return .regularMaterial
        case .prominent:
            return .thickMaterial
        case .max:
            return .ultraThickMaterial
        }
    }

    var fillOpacity: Double {
        switch self {
        case .subtle:
            return 0.72
        case .regular:
            return 0.8
        case .prominent:
            return 0.86
        case .max:
            return 0.92
        }
    }

    var tintOpacity: Double {
        switch self {
        case .subtle:
            return 0.04
        case .regular:
            return 0.08
        case .prominent:
            return 0.12
        case .max:
            return 0.16
        }
    }

    var highlightOpacity: Double {
        switch self {
        case .subtle:
            return 0.03
        case .regular:
            return 0.05
        case .prominent:
            return 0.08
        case .max:
            return 0.11
        }
    }

    var borderOpacity: Double {
        switch self {
        case .subtle:
            return 0.12
        case .regular:
            return 0.18
        case .prominent:
            return 0.26
        case .max:
            return 0.34
        }
    }

    var shadowOpacity: Double {
        switch self {
        case .subtle:
            return 0.06
        case .regular:
            return 0.1
        case .prominent:
            return 0.14
        case .max:
            return 0.18
        }
    }

    var shadowRadius: CGFloat {
        switch self {
        case .subtle:
            return 6
        case .regular:
            return 10
        case .prominent:
            return 14
        case .max:
            return 18
        }
    }

    var shadowYOffset: CGFloat {
        switch self {
        case .subtle:
            return 2
        case .regular:
            return 4
        case .prominent:
            return 6
        case .max:
            return 8
        }
    }

    var nativeBackdropOpacity: Double {
        switch self {
        case .subtle:
            return 0.08
        case .regular:
            return 0.1
        case .prominent:
            return 0.12
        case .max:
            return 0.15
        }
    }
}

private extension GlassVariant {
    var defaultLevel: LiquidGlassLevel {
        switch self {
        case .regular:
            return .regular
        case .interactive:
            return .prominent
        case .tinted:
            return .prominent
        case .prominent:
            return .max
        case .clear:
            return .subtle
        }
    }

    var tintColor: Color? {
        switch self {
        case .tinted(let color):
            return color
        default:
            return nil
        }
    }
}

// MARK: - 环境检查
public enum LiquidGlassEnvironment {
    /// 检查是否支持原生 Liquid Glass API (macOS 26+)
    public static var supportsNativeLiquidGlass: Bool {
        if #available(macOS 26.0, *) {
            return true
        }
        return false
    }
}

@available(macOS 26.0, *)
private extension LiquidGlassLevel {
    var nativeGlass: Glass {
        switch self {
        case .subtle:
            return .clear
        case .regular, .prominent, .max:
            return .regular
        }
    }

    func configuredNativeGlass(tint: Color?) -> Glass {
        var glass = nativeGlass
        if let tint {
            glass = glass.tint(tint)
        }
        return glass
    }
}

@available(macOS 26.0, *)
private extension GlassVariant {
    var nativeGlass: Glass {
        switch self {
        case .regular, .prominent:
            return .regular
        case .interactive:
            return .regular.interactive()
        case .tinted(let color):
            return .regular.tint(color)
        case .clear:
            return .clear
        }
    }
}

public struct LiquidGlassAtmosphereBackground: View {
    let primary: Color
    let secondary: Color
    let tertiary: Color
    let baseTop: Color
    let baseBottom: Color
    
    /// 轻量模式（减少特效层数）
    var lightweight: Bool = false

    public init(
        primary: Color = LiquidGlassColors.secondaryViolet,
        secondary: Color = LiquidGlassColors.primaryPink,
        tertiary: Color = LiquidGlassColors.accentCyan,
        baseTop: Color = LiquidGlassColors.midBackground,
        baseBottom: Color = LiquidGlassColors.deepBackground,
        lightweight: Bool = false
    ) {
        self.primary = primary
        self.secondary = secondary
        self.tertiary = tertiary
        self.baseTop = baseTop
        self.baseBottom = baseBottom
        self.lightweight = lightweight
    }

    public var body: some View {
        ZStack {
            // 基础渐变
            LinearGradient(
                colors: [baseTop, baseBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            // 主色调光晕（简化版）
            Circle()
                .fill(primary.opacity(lightweight ? 0.18 : 0.22))
                .frame(width: lightweight ? 600 : 720, height: lightweight ? 600 : 720)
                .blur(radius: lightweight ? 90 : 118)
                .offset(x: -180, y: -220)

            // 轻量模式下跳过次要光晕
            if !lightweight {
                Circle()
                    .fill(secondary.opacity(0.18))
                    .frame(width: 640, height: 640)
                    .blur(radius: 124)
                    .offset(x: 220, y: -120)

                Circle()
                    .fill(tertiary.opacity(0.12))
                    .frame(width: 560, height: 560)
                    .blur(radius: 108)
                    .offset(x: 60, y: 220)
            }

            // 顶部渐变遮罩
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.02),
                            Color.clear,
                            Color.black.opacity(0.18)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
        .ignoresSafeArea()
    }
}

// MARK: - Liquid Glass 卡片组件
public struct LiquidGlassCard<Content: View>: View {
    let variant: GlassVariant
    let cornerRadius: CGFloat
    let padding: CGFloat
    let spacing: CGFloat
    let content: Content

    public init(
        padding: CGFloat = 20,
        cornerRadius: CGFloat = 20,
        variant: GlassVariant = .regular,
        spacing: CGFloat = 8,
        @ViewBuilder content: () -> Content
    ) {
        self.variant = variant
        self.cornerRadius = cornerRadius
        self.padding = padding
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .liquidGlassSurface(
                variant.defaultLevel,
                tint: variant.tintColor,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
    }
}

// MARK: - Liquid Glass 按钮组件
public struct LiquidGlassButton<Content: View>: View {
    let variant: GlassVariant
    let action: () -> Void
    let content: Content

    @State private var isHovered = false
    @State private var isPressed = false

    public init(
        variant: GlassVariant = .regular,
        action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.variant = variant
        self.action = action
        self.content = content()
    }

    public var body: some View {
        Button(action: action) {
            content
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .contentShape(Capsule())
                .liquidGlassSurface(
                    variant.defaultLevel,
                    tint: variant.tintColor,
                    in: Capsule()
                )
                .scaleEffect(isPressed ? 0.96 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Liquid Glass 导航栏
public struct LiquidGlassNavigationBar<Leading: View, Title: View, Trailing: View>: View {
    let variant: GlassVariant
    let height: CGFloat
    let leading: Leading
    let title: Title
    let trailing: Trailing

    public init(
        variant: GlassVariant = .regular,
        height: CGFloat = 52,
        @ViewBuilder leading: () -> Leading = { EmptyView() },
        @ViewBuilder title: () -> Title = { EmptyView() },
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.variant = variant
        self.height = height
        self.leading = leading()
        self.title = title()
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: 16) {
            leading
            Spacer()
            title
            Spacer()
            trailing
        }
        .padding(.horizontal, 16)
        .frame(height: height)
        .liquidGlassSurface(
            variant.defaultLevel,
            tint: variant.tintColor,
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
    }
}

// MARK: - Glass Effect 容器
public struct OptimizedGlassContainer<Content: View>: View {
    let spacing: CGFloat
    let content: Content

    public init(
        spacing: CGFloat = 12,
        @ViewBuilder content: () -> Content
    ) {
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                GlassEffectContainer(spacing: spacing) {
                    content
                }
            } else {
                content
            }
        }
    }
}

// MARK: - Liquid Glass 胶囊按钮
public struct LiquidGlassPillButton: View {
    let title: String
    let icon: String?
    let variant: GlassVariant
    let isSelected: Bool
    let color: Color
    let action: () -> Void

    @State private var isHovered = false

    public init(
        title: String,
        icon: String? = nil,
        variant: GlassVariant = .regular,
        isSelected: Bool = false,
        color: Color = LiquidGlassColors.primaryPink,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.icon = icon
        self.variant = variant
        self.isSelected = isSelected
        self.color = color
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .medium))
                }
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(isSelected ? .white : LiquidGlassColors.textSecondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Capsule())
            .liquidGlassSurface(
                isSelected ? .max : .regular,
                tint: isSelected ? color : nil,
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Liquid Glass 浮动按钮
public struct LiquidGlassFloatingButton: View {
    let icon: String
    let color: Color
    let variant: GlassVariant
    let size: CGFloat
    let action: () -> Void

    @State private var isHovered = false

    public init(
        icon: String,
        color: Color = LiquidGlassColors.primaryPink,
        variant: GlassVariant = .regular,
        size: CGFloat = 44,
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.color = color
        self.variant = variant
        self.size = size
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(isHovered ? color : LiquidGlassColors.textPrimary)
                .frame(width: size, height: size)
                .contentShape(Circle())
                .liquidGlassSurface(.max, tint: color, in: Circle())
                .shadow(
                    color: isHovered ? color.opacity(0.5) : Color.black.opacity(0.15),
                    radius: isHovered ? 16 : 8,
                    y: isHovered ? 8 : 4
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - View 扩展
public extension View {
    /// 应用 Liquid Glass 效果
    func liquidGlassEffect(
        _ variant: GlassVariant = .regular,
        in shape: some Shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
    ) -> some View {
        modifier(AdaptiveVariantGlassModifier(shape: shape, variant: variant))
    }

    func liquidGlassSurface(
        _ level: LiquidGlassLevel = .regular,
        tint: Color? = nil,
        in shape: some Shape = RoundedRectangle(cornerRadius: 20, style: .continuous),
        lightweight: Bool = false
    ) -> some View {
        modifier(AdaptiveLevelGlassModifier(shape: shape, level: level, tint: tint, lightweight: lightweight))
    }

    /// 包装在 GlassEffectContainer 中
    func glassContainer(spacing: CGFloat = 12) -> some View {
        OptimizedGlassContainer(spacing: spacing) {
            self
        }
    }
}

struct AdaptiveVariantGlassModifier<S: Shape>: ViewModifier {
    let shape: S
    let variant: GlassVariant

    func body(content: Content) -> some View {
        Group {
            if #available(macOS 26.0, *) {
                content.modifier(
                    NativeGlassModifier(
                        shape: shape,
                        glass: variant.nativeGlass,
                        backdropOpacity: variant.defaultLevel.nativeBackdropOpacity
                    )
                )
            } else {
                content.modifier(
                    FallbackGlassModifier(
                        shape: shape,
                        level: variant.defaultLevel,
                        tint: variant.tintColor
                    )
                )
            }
        }
    }
}

struct AdaptiveLevelGlassModifier<S: Shape>: ViewModifier {
    let shape: S
    let level: LiquidGlassLevel
    let tint: Color?
    var lightweight: Bool = false

    func body(content: Content) -> some View {
        Group {
            if #available(macOS 26.0, *) {
                content.modifier(
                    NativeGlassModifier(
                        shape: shape,
                        glass: level.configuredNativeGlass(tint: tint),
                        backdropOpacity: level.nativeBackdropOpacity
                    )
                )
            } else {
                content.modifier(
                    FallbackGlassModifier(
                        shape: shape,
                        level: level,
                        tint: tint,
                        lightweight: lightweight
                    )
                )
            }
        }
    }
}

@available(macOS 26.0, *)
struct NativeGlassModifier<S: Shape>: ViewModifier {
    let shape: S
    let glass: Glass
    let backdropOpacity: Double

    func body(content: Content) -> some View {
        content
            .glassEffect(glass, in: shape)
    }
}

// MARK: - 兼容修饰器
struct FallbackGlassModifier: ViewModifier {
    let shape: any Shape
    let level: LiquidGlassLevel
    let tint: Color?
    var lightweight: Bool = false

    func body(content: Content) -> some View {
        content
            .background {
                // 优化：轻量模式减少层级，避免渲染开销
                if lightweight {
                    // 轻量模式：仅基础材质 + 色调
                    AnyShape(shape)
                        .fill(level.material)
                        .opacity(level.fillOpacity)
                        .overlay {
                            if let tint {
                                AnyShape(shape)
                                    .fill(tint.opacity(level.tintOpacity * 0.8))
                            }
                        }
                } else {
                    // 完整模式：所有视觉效果
                    ZStack {
                        // 基础材质
                        AnyShape(shape)
                            .fill(level.material)
                            .opacity(level.fillOpacity)

                        // 色调叠加（仅当有 tint 时）
                        if let tint {
                            AnyShape(shape)
                                .fill(tint.opacity(level.tintOpacity))
                        }

                        // 高光效果 - 增强视觉效果
                        AnyShape(shape)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(level.highlightOpacity * 1.2),
                                        Color.white.opacity(0.03),
                                        Color.clear
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )

                        // 底部渐变 - 增强层次感
                        AnyShape(shape)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.clear,
                                        Color.black.opacity(0.05)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    }
                }
            }
            // 优化：仅在需要时添加边框和阴影
            .overlay {
                AnyShape(shape)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(level.borderOpacity * 1.3),
                                Color.white.opacity(level.borderOpacity * 0.5),
                                tint?.opacity(level.borderOpacity * 0.5) ?? Color.clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: lightweight ? 0.5 : 1
                    )
            }
            // 优化：轻量模式减少阴影开销
            .shadow(
                color: .black.opacity(lightweight ? level.shadowOpacity * 0.5 : level.shadowOpacity * 1.2),
                radius: lightweight ? min(level.shadowRadius * 0.5, 4) : level.shadowRadius,
                y: lightweight ? max(level.shadowYOffset * 0.5, 1) : level.shadowYOffset
            )
    }
}

// MARK: - 玻璃态按钮样式（带按压效果）
/// 使用 ButtonStyle 实现按压效果，避免手势冲突
public struct LiquidGlassPressableStyle: ButtonStyle {
    @Binding var isPressed: Bool
    var scale: CGFloat = 0.96
    var animationDuration: Double = 0.1
    
    public init(isPressed: Binding<Bool>, scale: CGFloat = 0.96, animationDuration: Double = 0.1) {
        self._isPressed = isPressed
        self.scale = scale
        self.animationDuration = animationDuration
    }
    
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, newValue in
                withAnimation(.easeInOut(duration: animationDuration)) {
                    isPressed = newValue
                }
            }
    }
}

// MARK: - 按下事件辅助（基于 NSEvent 的可靠实现）
/// 使用 NSView Representable 来处理鼠标事件，避免与 Button 冲突
struct PressEventsView: NSViewRepresentable {
    var onPress: () -> Void
    var onRelease: () -> Void
    
    func makeNSView(context: Context) -> NSView {
        let view = PressTrackingView()
        view.onPress = onPress
        view.onRelease = onRelease
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? PressTrackingView else { return }
        view.onPress = onPress
        view.onRelease = onRelease
    }
}

/// 用于跟踪鼠标按下/释放的 NSView
class PressTrackingView: NSView {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    
    override var acceptsFirstResponder: Bool { true }
    
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        onPress?()
    }
    
    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        onRelease?()
    }
}

/// 通过 overlay 添加按压事件跟踪，不干扰按钮本身的手势
struct PressEventsModifier: ViewModifier {
    var onPress: () -> Void
    var onRelease: () -> Void
    
    func body(content: Content) -> some View {
        content
            .overlay(
                PressEventsView(onPress: onPress, onRelease: onRelease)
                    .allowsHitTesting(false)  // 允许点击穿透到下面的按钮
            )
    }
}

public extension View {
    /// 添加按压事件跟踪（使用 NSView 实现，不与 Button 冲突）
    func pressEvents(onPress: @escaping () -> Void, onRelease: @escaping () -> Void) -> some View {
        modifier(PressEventsModifier(onPress: onPress, onRelease: onRelease))
    }
}

// MARK: - Color 扩展
public extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
import SwiftUI
import Combine

// MARK: - 主题模式
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

// MARK: - 主题管理器
@MainActor
class ThemeManager: ObservableObject {
    static let shared = ThemeManager()
    
    @Published var themeMode: ThemeMode = .dark {
        didSet {
            UserDefaults.standard.set(themeMode.rawValue, forKey: "themeMode")
            applyTheme()
        }
    }
    
    var isDarkMode: Bool {
        switch themeMode {
        case .dark:
            return true
        case .light:
            return false
        case .system:
            return !isSystemLightMode
        }
    }
    
    private var cancellables = Set<AnyCancellable>()
    
    private init() {
        // ⚠️ 不在 init 中读 UserDefaults，避免 _CFXPreferences 递归栈溢出
        // 使用默认深色主题（WaifuX 是纯深色设计），用户偏好通过 restoreSavedSettings() 延迟恢复
        self.themeMode = .dark
        
        // 监听系统主题变化
        DistributedNotificationCenter.default
            .publisher(for: Notification.Name("AppleInterfaceThemeChangedNotification"))
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        
        applyTheme()
    }
    
    /// 延迟恢复保存的主题设置（必须在 applicationDidFinishLaunching 中调用）
    func restoreSavedSettings() {
        if let savedMode = UserDefaults.standard.string(forKey: "themeMode"),
           let mode = ThemeMode(rawValue: savedMode) {
            self.themeMode = mode
            applyTheme()
        }
    }
    
    func applyTheme() {
        objectWillChange.send()
        
        // 更新应用外观
        let isDark = isDarkMode
        DispatchQueue.main.async {
            NSApp.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        }
    }
    
    private var isSystemLightMode: Bool {
        let appearance = NSApp.effectiveAppearance
        var isLight = false
        appearance.performAsCurrentDrawingAppearance {
            isLight = appearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
        }
        return isLight
    }
}

// MARK: - 主题颜色
struct ThemeColors {
    let isDarkMode: Bool
    
    // 背景色
    var background: Color {
        isDarkMode ? Color(hex: "0D0D0D") : Color(hex: "F5F5F7")
    }
    
    var surface: Color {
        isDarkMode ? Color(hex: "1A1A1A") : Color(hex: "FFFFFF")
    }
    
    var elevatedSurface: Color {
        isDarkMode ? Color(hex: "242424") : Color(hex: "FFFFFF")
    }
    
    // 玻璃效果颜色
    var glassBackground: Color {
        isDarkMode ? Color.white.opacity(0.1) : Color.black.opacity(0.05)
    }
    
    var glassBorder: Color {
        isDarkMode ? Color.white.opacity(0.2) : Color.black.opacity(0.1)
    }
    
    // 文字颜色
    var textPrimary: Color {
        isDarkMode ? .white : Color(hex: "1A1A1A")
    }
    
    var textSecondary: Color {
        isDarkMode ? .white.opacity(0.7) : Color(hex: "666666")
    }
    
    var textTertiary: Color {
        isDarkMode ? .white.opacity(0.5) : Color(hex: "999999")
    }
    
    // 主色调
    var primary: Color {
        Color(hex: "FF3366")
    }
    
    var secondary: Color {
        Color(hex: "8B5CF6")
    }
    
    // 渐变背景
    var meshGradientColors: [Color] {
        isDarkMode ? [
            Color(hex: "1A0A2E"),
            Color(hex: "16213E"),
            Color(hex: "0F3460"),
            Color(hex: "1A1A2E")
        ] : [
            Color(hex: "E8E4F0"),
            Color(hex: "D4E5F7"),
            Color(hex: "F0E8F5"),
            Color(hex: "E5EDF5")
        ]
    }
}

// MARK: - 环境值扩展
private struct ThemeColorsKey: EnvironmentKey {
    static let defaultValue = ThemeColors(isDarkMode: true)
}

extension EnvironmentValues {
    var themeColors: ThemeColors {
        get { self[ThemeColorsKey.self] }
        set { self[ThemeColorsKey.self] = newValue }
    }
}

// MARK: - 视图修饰器
struct ThemeModifier: ViewModifier {
    @ObservedObject var themeManager = ThemeManager.shared
    
    func body(content: Content) -> some View {
        content
            .environment(\.themeColors, ThemeColors(isDarkMode: themeManager.isDarkMode))
            .preferredColorScheme(themeManager.isDarkMode ? .dark : .light)
    }
}

extension View {
    func applyTheme() -> some View {
        modifier(ThemeModifier())
    }
}
