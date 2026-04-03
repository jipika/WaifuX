import SwiftUI
import AppKit

// MARK: - Glass 风格颜色 (兼容旧代码)
enum GlassStyleColors {
    @MainActor
    static var backgroundDark: Color { LiquidGlassColors.deepBackground }
    @MainActor
    static var backgroundMedium: Color { LiquidGlassColors.midBackground }
    @MainActor
    static var cardBackground: Color { LiquidGlassColors.glassWhiteSubtle }
    @MainActor
    static var cardBackgroundLight: Color { LiquidGlassColors.glassWhite }
    @MainActor
    static var glassHighlight: Color { LiquidGlassColors.glassHighlight }
    @MainActor
    static var glassBorder: Color { LiquidGlassColors.glassBorder }

    static let primaryPink = LiquidGlassColors.primaryPink
    static let secondaryViolet = LiquidGlassColors.secondaryViolet
    static let onlineGreen = LiquidGlassColors.onlineGreen
    static let warningOrange = LiquidGlassColors.warningOrange

    @MainActor
    static var textPrimary: Color { LiquidGlassColors.textPrimary }
    @MainActor
    static var textSecondary: Color { LiquidGlassColors.textSecondary }
    @MainActor
    static var textTertiary: Color { LiquidGlassColors.textTertiary }

    @MainActor
    static var gradientStart: Color { LiquidGlassColors.surfaceBackground }
    @MainActor
    static var gradientEnd: Color { LiquidGlassColors.deepBackground }
}

// MARK: - Glass 风格常量
enum GlassStyle {
    enum CornerRadius {
        static let small: CGFloat = 12
        static let medium: CGFloat = 20      // 增大
        static let large: CGFloat = 28        // 增大
        static let extraLarge: CGFloat = 36  // 新增
        static let capsule: CGFloat = 9999
    }

    enum Padding {
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let standard: CGFloat = 16
        static let large: CGFloat = 20
    }

    enum BorderWidth {
        static let thin: CGFloat = 0.5
        static let standard: CGFloat = 1
        static let medium: CGFloat = 1.5
    }
}

// MARK: - macOS 26 液态玻璃背景
struct LiquidGlassBackground: View {
    @State private var animateGlow = false

    var body: some View {
        ZStack {
            // 最深层 - 纯色底
            LiquidGlassColors.deepBackground
                .ignoresSafeArea()

            // 第二层 - 渐变
            RadialGradient(
                colors: [
                    LiquidGlassColors.surfaceBackground.opacity(0.6),
                    Color.clear
                ],
                center: .topLeading,
                startRadius: 0,
                endRadius: 600
            )

            // 第三层 - 紫色光晕 (左上)
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            LiquidGlassColors.secondaryViolet.opacity(0.15),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: 400
                    )
                )
                .frame(width: 600, height: 600)
                .blur(radius: 80)
                .offset(x: -200, y: -150)
                .offset(y: animateGlow ? -15 : 15)

            // 第四层 - 粉色光晕 (右下)
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            LiquidGlassColors.primaryPink.opacity(0.12),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: 350
                    )
                )
                .frame(width: 500, height: 500)
                .blur(radius: 70)
                .offset(x: 250, y: 200)
                .offset(y: animateGlow ? 20 : -20)

            // 第五层 - 青色光晕 (中心)
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            LiquidGlassColors.accentCyan.opacity(0.08),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: 300
                    )
                )
                .frame(width: 400, height: 400)
                .blur(radius: 60)
                .offset(x: 0, y: 100)
                .offset(y: animateGlow ? -10 : 10)

            // 顶层 - 微妙的扫描线纹理
            ScanlineTexture()
        }
        .onAppear {
            withAnimation(
                .easeInOut(duration: 10)
                .repeatForever(autoreverses: true)
            ) {
                animateGlow.toggle()
            }
        }
    }
}

// MARK: - 扫描线纹理
struct ScanlineTexture: View {
    var opacity: Double = 0.015

    var body: some View {
        GeometryReader { geo in
            Path { path in
                let spacing: CGFloat = 3
                var y: CGFloat = 0
                while y < geo.size.height {
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: geo.size.width, y: y))
                    y += spacing
                }
            }
            .stroke(Color.white.opacity(opacity), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Glass 背景 (保留兼容)
struct GlassBackground: View {
    var body: some View {
        LiquidGlassBackground()
    }
}

// MARK: - 液态玻璃按钮 (使用 DesignSystem 版本)
// LiquidGlassButton 已移至 DesignSystem/LiquidGlassDesignSystem.swift

// MARK: - 液态玻璃图标按钮
struct LiquidGlassIconButton: View {
    var icon: String
    var size: CGFloat = 44
    var iconSize: CGFloat = 18
    var color: Color = LiquidGlassColors.glassWhiteSubtle
    var iconColor: Color = LiquidGlassColors.textPrimary
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundColor(iconColor)
                .frame(width: size, height: size)
                .liquidGlassSurface(.max, tint: color.opacity(isHovering ? 0.9 : 0.7), in: Circle())
                .shadow(
                    color: isHovering ? LiquidGlassColors.primaryPink.opacity(0.3) : .clear,
                    radius: 10
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovering = hovering
            }
        }
    }
}

// MARK: - Glass 图标按钮 (保留兼容)
struct GlassIconButton: View {
    var icon: String
    var size: CGFloat = 44
    var iconSize: CGFloat = 18
    var color: Color = LiquidGlassColors.glassWhiteSubtle
    var iconColor: Color = LiquidGlassColors.textPrimary
    let action: () -> Void

    var body: some View {
        LiquidGlassIconButton(
            icon: icon,
            size: size,
            iconSize: iconSize,
            color: color,
            iconColor: iconColor,
            action: action
        )
    }
}

// MARK: - 液态玻璃搜索栏
struct LiquidGlassSearchBar: View {
    @Binding var text: String
    var onSubmit: () -> Void = {}

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(isFocused ? LiquidGlassColors.primaryPink : LiquidGlassColors.textSecondary)

            TextField("搜索...", text: $text)
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(LiquidGlassColors.textPrimary)
                .focused($isFocused)
                .onSubmit { onSubmit() }

            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(LiquidGlassColors.textTertiary)
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(
            RoundedRectangle(cornerRadius: GlassStyle.CornerRadius.large, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: GlassStyle.CornerRadius.large, style: .continuous)
                .stroke(isFocused ? LiquidGlassColors.primaryPink : LiquidGlassColors.glassBorder, lineWidth: isFocused ? 1.5 : 1)
        )
        .shadow(color: isFocused ? LiquidGlassColors.primaryPink.opacity(0.25) : .clear, radius: 12)
    }
}

// MARK: - Glass 搜索栏 (保留兼容)
struct GlassSearchBar: View {
    @Binding var text: String
    var onSubmit: () -> Void = {}

    var body: some View {
        LiquidGlassSearchBar(text: $text, onSubmit: onSubmit)
    }
}

// MARK: - 液态玻璃 Toggle (使用 DesignSystem 版本)
// LiquidGlassToggle 已移至 DesignSystem/LiquidGlassDesignSystem.swift

// MARK: - 液态玻璃下拉弹出框
struct LiquidGlassDropdownButton<Content: View>: View {
    var title: String
    var icon: String = "chevron.down"
    @Binding var isOpen: Bool
    let content: () -> Content

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
            }
            .foregroundColor(LiquidGlassColors.textPrimary)
            .padding(.horizontal, GlassStyle.Padding.standard)
            .padding(.vertical, GlassStyle.Padding.small)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: GlassStyle.CornerRadius.capsule, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: GlassStyle.CornerRadius.capsule, style: .continuous)
                        .fill(LiquidGlassColors.glassWhiteSubtle)
                }
            )
            .overlay(
                ZStack {
                    RoundedRectangle(cornerRadius: GlassStyle.CornerRadius.capsule, style: .continuous)
                        .stroke(LiquidGlassColors.glassBorder, lineWidth: 1)
                    RoundedRectangle(cornerRadius: GlassStyle.CornerRadius.capsule, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.3),
                                    Color.white.opacity(0.1)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.5
                        )
                }
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            LiquidGlassDropdownContent {
                content()
            }
        }
    }
}

struct LiquidGlassDropdownContent<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: GlassStyle.CornerRadius.medium, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: GlassStyle.CornerRadius.medium, style: .continuous)
                    .fill(LiquidGlassColors.glassWhiteSubtle)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: GlassStyle.CornerRadius.medium, style: .continuous))
        .overlay(
            ZStack {
                RoundedRectangle(cornerRadius: GlassStyle.CornerRadius.medium, style: .continuous)
                    .stroke(LiquidGlassColors.glassBorder, lineWidth: 1)
                RoundedRectangle(cornerRadius: GlassStyle.CornerRadius.medium, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.3),
                                Color.white.opacity(0.05)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.5
                    )
            }
        )
    }
}

struct GlassDropdownButton<Content: View>: View {
    var title: String
    var icon: String = "chevron.down"
    @Binding var isOpen: Bool
    let content: () -> Content

    var body: some View {
        LiquidGlassDropdownButton(title: title, icon: icon, isOpen: $isOpen, content: content)
    }
}

struct GlassDropdownContent<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        LiquidGlassDropdownContent(content: content)
    }
}

struct GlassDropdownItem: View {
    var title: String
    var isSelected: Bool = false
    var icon: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(LiquidGlassColors.textSecondary)
                }

                Text(title)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(LiquidGlassColors.textPrimary)

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(LiquidGlassColors.primaryPink)
                }
            }
            .padding(.horizontal, GlassStyle.Padding.standard)
            .padding(.vertical, GlassStyle.Padding.small)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(minWidth: 140)
    }
}


// MARK: - 液态玻璃徽章
struct LiquidGlassBadge: View {
    var text: String
    var color: Color = LiquidGlassColors.primaryPink
    var textColor: Color = LiquidGlassColors.textPrimary

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(textColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                ZStack {
                    Capsule()
                        .fill(color.opacity(0.25))
                    Capsule()
                        .stroke(color.opacity(0.4), lineWidth: 0.5)
                }
            )
    }
}

// MARK: - Glass 徽章 (保留兼容)
struct GlassBadge: View {
    var text: String
    var color: Color = LiquidGlassColors.primaryPink
    var textColor: Color = LiquidGlassColors.textPrimary

    var body: some View {
        LiquidGlassBadge(text: text, color: color, textColor: textColor)
    }
}

// MARK: - 液态玻璃分隔线
struct LiquidGlassDivider: View {
    var body: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [
                        Color.clear,
                        LiquidGlassColors.glassBorder,
                        Color.clear
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(height: 1)
    }
}


// MARK: - Glass 文本框 (保留兼容)
struct GlassTextField: View {
    var placeholder: String
    @Binding var text: String

    var body: some View {
        LiquidGlassTextField(placeholder, text: $text)
    }
}

// MARK: - Apple 风格标签切换器
struct ApplePillToggle: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let color: Color
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(isSelected ? .white : LiquidGlassColors.textSecondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                ZStack {
                    if isSelected {
                        // 选中态 - 纯色渐变
                        RoundedRectangle(cornerRadius: GlassStyle.CornerRadius.small, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [color, color.opacity(0.8)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                    } else if isHovering {
                        RoundedRectangle(cornerRadius: GlassStyle.CornerRadius.small, style: .continuous)
                            .fill(LiquidGlassColors.glassWhiteLight)
                    } else {
                        Color.clear
                    }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: GlassStyle.CornerRadius.small, style: .continuous))
            .animation(.easeInOut(duration: 0.2), value: isSelected)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}

// MARK: - Apple 风格分段控件
struct AppleSegmentedControl<T: Hashable>: View {
    let options: [T]
    let labels: [String]
    @Binding var selection: T
    let color: Color

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<options.count, id: \.self) { index in
                let option = options[index]
                let label = labels[index]
                segmentButton(option: option, label: label)
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: GlassStyle.CornerRadius.medium, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .clipShape(RoundedRectangle(cornerRadius: GlassStyle.CornerRadius.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: GlassStyle.CornerRadius.medium, style: .continuous)
                .stroke(LiquidGlassColors.glassBorder, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func segmentButton(option: T, label: String) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                selection = option
            }
        } label: {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(selection == option ? .white : LiquidGlassColors.textSecondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(segmentBackground(for: option))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func segmentBackground(for option: T) -> some View {
        if selection == option {
            RoundedRectangle(cornerRadius: GlassStyle.CornerRadius.small, style: .continuous)
                .fill(color)
        } else {
            Color.clear
        }
    }
}

// MARK: - Apple 风格标签栏容器
struct AppleTabBar: View {
    var body: some View {
        LiquidGlassCard(padding: 4) {
            HStack(spacing: 0) {
                // 内容由外部传入
                EmptyView()
            }
        }
    }
}

private struct DetailGlassChromeModifier<S: Shape>: ViewModifier {
    let shape: S
    let tint: Color?
    let level: LiquidGlassLevel
    let shadowColor: Color
    let shadowRadius: CGFloat
    let shadowYOffset: CGFloat
    let topBorderOpacity: Double
    let bottomBorderOpacity: Double

    func body(content: Content) -> some View {
        content
            .liquidGlassSurface(level, tint: tint, in: shape)
            .overlay {
                shape
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(topBorderOpacity),
                                Color.white.opacity(bottomBorderOpacity)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
            .shadow(color: shadowColor, radius: shadowRadius, y: shadowYOffset)
    }
}

extension View {
    func detailGlassCircleChrome(
        tint: Color? = nil,
        level: LiquidGlassLevel = .max
    ) -> some View {
        modifier(
            DetailGlassChromeModifier(
                shape: Circle(),
                tint: tint,
                level: level,
                shadowColor: .black.opacity(0.22),
                shadowRadius: 16,
                shadowYOffset: 8,
                topBorderOpacity: 0.34,
                bottomBorderOpacity: 0.10
            )
        )
    }

    func detailGlassCapsuleChrome(
        tint: Color? = nil,
        level: LiquidGlassLevel = .max
    ) -> some View {
        modifier(
            DetailGlassChromeModifier(
                shape: Capsule(style: .continuous),
                tint: tint,
                level: level,
                shadowColor: .black.opacity(0.18),
                shadowRadius: 16,
                shadowYOffset: 8,
                topBorderOpacity: 0.32,
                bottomBorderOpacity: 0.08
            )
        )
    }

    func detailPrimaryGlassButtonChrome(tint: Color? = nil) -> some View {
        modifier(
            DetailGlassChromeModifier(
                shape: Capsule(style: .continuous),
                tint: tint,
                level: .max,
                shadowColor: .black.opacity(0.24),
                shadowRadius: 18,
                shadowYOffset: 10,
                topBorderOpacity: 0.34,
                bottomBorderOpacity: 0.10
            )
        )
    }

    func detailGlassRoundedRectChrome(
        cornerRadius: CGFloat = 18,
        tint: Color? = nil,
        level: LiquidGlassLevel = .prominent
    ) -> some View {
        modifier(
            DetailGlassChromeModifier(
                shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
                tint: tint,
                level: level,
                shadowColor: .black.opacity(0.16),
                shadowRadius: 18,
                shadowYOffset: 8,
                topBorderOpacity: 0.28,
                bottomBorderOpacity: 0.06
            )
        )
    }

    func detailGlassCarouselChrome(
        cornerRadius: CGFloat = 28,
        tint: Color? = nil,
        level: LiquidGlassLevel = .prominent
    ) -> some View {
        modifier(
            DetailGlassChromeModifier(
                shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
                tint: tint,
                level: level,
                shadowColor: .black.opacity(0.22),
                shadowRadius: 22,
                shadowYOffset: 12,
                topBorderOpacity: 0.36,
                bottomBorderOpacity: 0.10
            )
        )
    }

    func detailGlassTitleChrome() -> some View {
        modifier(DetailGlassTitleModifier())
    }
}

private struct DetailGlassTitleModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            // macOS 26+: 使用原生 Liquid Glass 透明文字效果
            content
                .glassEffect(
                    Glass.regular.tint(Color.white.opacity(0.18)),
                    in: .rect
                )
                .foregroundStyle(.clear)
                .background(
                    // 使用 glass 材质作为文字的背景，实现透明效果
                    content
                        .foregroundStyle(.white)
                        .glassEffect(
                            Glass.regular.tint(Color.white.opacity(0.25)),
                            in: .rect
                        )
                        .compositingGroup()
                )
                .mask {
                    // 用原文字作为 mask，让玻璃效果只在文字形状内显示
                    content
                        .foregroundStyle(.white)
                }
                .overlay(
                    // 顶部高光增强玻璃质感
                    content
                        .foregroundStyle(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.92),
                                    Color.white.opacity(0.45),
                                    Color.clear
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .blendMode(.overlay)
                        .mask {
                            content
                                .foregroundStyle(.white)
                        }
                )
                .shadow(color: .black.opacity(0.35), radius: 28, x: 0, y: 14)
        } else {
            // Fallback: 使用 ultraThinMaterial 模拟透明玻璃文字
            ZStack {
                // 底层阴影
                content
                    .foregroundStyle(.black.opacity(0.35))
                    .blur(radius: 14)
                    .offset(y: 8)

                // 透明玻璃层 - 使用 material
                content
                    .foregroundStyle(.clear)
                    .background(.ultraThinMaterial.opacity(0.7))
                    .mask {
                        content
                            .foregroundStyle(.white)
                    }

                // 玻璃反光层
                content
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.85),
                                Color.white.opacity(0.45),
                                Color.white.opacity(0.2)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .blendMode(.screen)
                    .mask {
                        content
                            .foregroundStyle(.white)
                    }

                // 顶部高光
                content
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.95),
                                Color.white.opacity(0.5),
                                Color.clear
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .blendMode(.overlay)
                    .mask {
                        content
                            .foregroundStyle(.white)
                    }
            }
            .compositingGroup()
            .shadow(color: .black.opacity(0.32), radius: 26, x: 0, y: 12)
        }
    }
}

struct DetailGlassPopoverCard<Content: View>: View {
    var width: CGFloat = 360
    var maxHeight: CGFloat = 460
    var variant: PopoverVariant = .dark
    @ViewBuilder let content: () -> Content

    enum PopoverVariant {
        case dark
        case light

        var tintColor: NSColor {
            switch self {
            case .dark:
                return NSColor.black.withAlphaComponent(0.42)
            case .light:
                return NSColor.white.withAlphaComponent(0.16)
            }
        }

        var backdropOpacity: Double {
            switch self {
            case .dark:
                return 0.55
            case .light:
                return 0.15
            }
        }

        var borderColors: [Color] {
            switch self {
            case .dark:
                return [
                    Color.white.opacity(0.18),
                    Color.white.opacity(0.06)
                ]
            case .light:
                return [
                    Color.white.opacity(0.32),
                    Color.white.opacity(0.08)
                ]
            }
        }

        var shadowOpacity: Double {
            switch self {
            case .dark:
                return 0.35
            case .light:
                return 0.14
            }
        }
    }

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                ZStack {
                    NativeAppKitGlassEffectView(
                        cornerRadius: 28,
                        tintColor: variant.tintColor,
                        style: .regular
                    )

                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 18) {
                            content()
                        }
                        .padding(20)
                    }
                }
                .frame(width: width)
                .frame(maxHeight: maxHeight)
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: variant.borderColors,
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.9
                        )
                }
                .shadow(color: .black.opacity(variant.shadowOpacity), radius: 22, y: 10)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.black.opacity(0.45),
                                    Color.black.opacity(0.38)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(.ultraThickMaterial.opacity(variant.backdropOpacity))

                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 18) {
                            content()
                        }
                        .padding(20)
                    }
                }
                .frame(width: width)
                .frame(maxHeight: maxHeight)
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: variant.borderColors,
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.9
                        )
                }
                .shadow(color: .black.opacity(variant.shadowOpacity), radius: 22, y: 10)
            }
        }
    }
}

@available(macOS 26.0, *)
private struct NativeAppKitGlassEffectView: NSViewRepresentable {
    var cornerRadius: CGFloat
    var tintColor: NSColor?
    var style: NSGlassEffectView.Style = .regular

    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        view.cornerRadius = cornerRadius
        view.tintColor = tintColor
        view.style = style
        view.contentView = NSView(frame: .zero)
        return view
    }

    func updateNSView(_ nsView: NSGlassEffectView, context: Context) {
        nsView.cornerRadius = cornerRadius
        nsView.tintColor = tintColor
        nsView.style = style
    }
}

struct DetailGlassPopoverSectionTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white.opacity(0.56))
            .tracking(2)
    }
}
