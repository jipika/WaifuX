import SwiftUI

// MARK: - 拟物化设计系统
// 为播放器界面提供金属质感、实体按键、LED指示灯等拟物化元素

// MARK: - 颜色定义
enum SkeuomorphicColors {
    // 金属背景色
    static let metalDark = Color(hex: "1a1a1a")
    static let metalMid = Color(hex: "2d2d2d")
    static let metalLight = Color(hex: "3d3d3d")
    static let metalHighlight = Color(hex: "4a4a4a")
    
    // 按键色
    static let buttonBase = Color(hex: "4a4a4a")
    static let buttonHighlight = Color(hex: "5a5a5a")
    static let buttonShadow = Color(hex: "2a2a2a")
    
    // 指示灯色
    static let ledGreen = Color(hex: "34D399")
    static let ledRed = Color(hex: "FF6B6B")
    static let ledAmber = Color(hex: "FF9F43")
    static let ledOff = Color(hex: "4a4a4a")
    
    // 选中/激活色
    static let activeAmber = Color(hex: "ff9500")
    static let activeGlow = Color(hex: "ff6b35")
    
    // 文字色
    static let textPrimary = Color(hex: "f5f5f5")
    static let textSecondary = Color(hex: "b0b0b0")
    static let textMuted = Color(hex: "808080")
}

// MARK: - 金属表面修饰器
struct MetalSurfaceModifier: ViewModifier {
    var isPressed: Bool = false
    var cornerRadius: CGFloat = 8
    
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                isPressed ? SkeuomorphicColors.metalDark : SkeuomorphicColors.metalLight,
                                isPressed ? SkeuomorphicColors.metalMid : SkeuomorphicColors.metalDark
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay(
                        // 顶部高光
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(isPressed ? 0.05 : 0.15),
                                        Color.clear
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    )
                    .shadow(
                        color: Color.black.opacity(0.5),
                        radius: isPressed ? 1 : 3,
                        x: 0,
                        y: isPressed ? 1 : 2
                    )
            )
            .overlay(
                // 内阴影/边框
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        isPressed 
                            ? Color.black.opacity(0.3)
                            : Color.white.opacity(0.1),
                        lineWidth: 1
                    )
            )
    }
}

// MARK: - 机械按键样式
struct MechanicalButtonStyle: ButtonStyle {
    var isActive: Bool = false
    var cornerRadius: CGFloat = 8
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: isActive ? .bold : .medium))
            .foregroundStyle(isActive ? SkeuomorphicColors.activeAmber : SkeuomorphicColors.textPrimary)
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(
                ZStack {
                    // 基础金属色
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    isActive || configuration.isPressed 
                                        ? SkeuomorphicColors.metalDark 
                                        : SkeuomorphicColors.buttonHighlight,
                                    isActive || configuration.isPressed 
                                        ? SkeuomorphicColors.metalMid 
                                        : SkeuomorphicColors.buttonBase
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    
                    // 顶部高光
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(isActive || configuration.isPressed ? 0.05 : 0.2),
                                    Color.clear
                                ],
                                startPoint: .top,
                                endPoint: UnitPoint(x: 0.5, y: 0.4)
                            )
                        )
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        isActive 
                            ? SkeuomorphicColors.activeAmber.opacity(0.5)
                            : Color.white.opacity(0.1),
                        lineWidth: isActive ? 1.5 : 1
                    )
            )
            .shadow(
                color: Color.black.opacity(0.4),
                radius: isActive || configuration.isPressed ? 1 : 3,
                x: 0,
                y: isActive || configuration.isPressed ? 1 : 2
            )
            .offset(y: isActive || configuration.isPressed ? 1 : 0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - LED 指示灯
struct LEDIndicator: View {
    var color: Color
    var isOn: Bool
    var size: CGFloat = 8
    
    var body: some View {
        ZStack {
            // 外圈（灯座）
            Circle()
                .fill(SkeuomorphicColors.metalDark)
                .frame(width: size + 4, height: size + 4)
                .shadow(color: Color.black.opacity(0.5), radius: 1, x: 0, y: 1)
            
            // LED 灯泡
            Circle()
                .fill(isOn ? color : SkeuomorphicColors.ledOff)
                .frame(width: size, height: size)
                .overlay(
                    // 高光
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color.white.opacity(isOn ? 0.6 : 0.2),
                                    Color.clear
                                ],
                                center: .topLeading,
                                startRadius: 0,
                                endRadius: size / 2
                            )
                        )
                        .frame(width: size - 2, height: size - 2)
                )
                .shadow(
                    color: isOn ? color.opacity(0.8) : Color.clear,
                    radius: isOn ? 4 : 0,
                    x: 0,
                    y: 0
                )
        }
    }
}

// MARK: - 拨动开关
struct ToggleSwitch: View {
    @Binding var isOn: Bool
    var activeColor: Color = SkeuomorphicColors.activeAmber
    
    var body: some View {
        Button(action: { isOn.toggle() }) {
            ZStack {
                // 轨道背景
                Capsule()
                    .fill(SkeuomorphicColors.metalDark)
                    .frame(width: 44, height: 24)
                    .overlay(
                        Capsule()
                            .stroke(Color.black.opacity(0.3), lineWidth: 1)
                    )
                    .innerShadow(
                        color: Color.black.opacity(0.5),
                        radius: 2,
                        x: 0,
                        y: 1
                    )
                
                // 滑块
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                SkeuomorphicColors.buttonHighlight,
                                SkeuomorphicColors.buttonBase
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 20, height: 20)
                    .shadow(color: Color.black.opacity(0.4), radius: 2, x: 0, y: 1)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
                    )
                    .offset(x: isOn ? 10 : -10)
                    .overlay(
                        // 指示灯
                        Circle()
                            .fill(isOn ? activeColor : SkeuomorphicColors.ledOff)
                            .frame(width: 6, height: 6)
                            .shadow(color: isOn ? activeColor.opacity(0.8) : Color.clear, radius: 2)
                            .offset(x: isOn ? 10 : -10)
                    )
            }
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: isOn)
    }
}

// MARK: - 金属滑块
struct MetalSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double = 0.1
    var trackColor: Color = SkeuomorphicColors.metalMid
    var fillColor: Color = SkeuomorphicColors.activeAmber
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // 轨道
                RoundedRectangle(cornerRadius: 3)
                    .fill(
                        LinearGradient(
                            colors: [
                                SkeuomorphicColors.metalDark,
                                SkeuomorphicColors.metalLight
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(height: 6)
                    .innerShadow(color: Color.black.opacity(0.5), radius: 1, x: 0, y: 1)
                
                // 填充
                RoundedRectangle(cornerRadius: 3)
                    .fill(fillColor)
                    .frame(
                        width: CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound)) * geometry.size.width,
                        height: 6
                    )
                
                // 滑块
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [SkeuomorphicColors.buttonHighlight, SkeuomorphicColors.buttonBase],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 16, height: 16)
                    .shadow(color: Color.black.opacity(0.4), radius: 2, x: 0, y: 1)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
                    )
                    .overlay(
                        // 顶部高光
                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: [Color.white.opacity(0.3), Color.clear],
                                    center: .topLeading,
                                    startRadius: 0,
                                    endRadius: 8
                                )
                            )
                            .frame(width: 14, height: 14)
                    )
                    .position(
                        x: CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound)) * geometry.size.width,
                        y: 3
                    )
            }
        }
        .frame(height: 20)
    }
}

// MARK: - 控制面板分区
struct ControlPanelSection<Content: View>: View {
    var title: String?
    var content: Content
    
    init(title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title = title {
                Text(title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(SkeuomorphicColors.textSecondary)
                    .textCase(.uppercase)
                    .tracking(1)
            }
            
            content
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(SkeuomorphicColors.metalMid)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.05), lineWidth: 1)
                )
                .innerShadow(color: Color.black.opacity(0.3), radius: 2, x: 0, y: 1)
        )
    }
}

// MARK: - 内阴影修饰器
struct InnerShadowModifier: ViewModifier {
    var color: Color
    var radius: CGFloat
    var x: CGFloat
    var y: CGFloat
    
    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geometry in
                    RoundedRectangle(cornerRadius: geometry.size.height / 2)
                        .stroke(color, lineWidth: radius)
                        .blur(radius: radius)
                        .offset(x: x, y: y)
                        .mask(
                            RoundedRectangle(cornerRadius: geometry.size.height / 2)
                                .fill(
                                    LinearGradient(
                                        colors: [.black, .clear],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                        )
                }
            )
    }
}

// MARK: - View 扩展
extension View {
    func metalSurface(isPressed: Bool = false, cornerRadius: CGFloat = 8) -> some View {
        modifier(MetalSurfaceModifier(isPressed: isPressed, cornerRadius: cornerRadius))
    }
    
    func innerShadow(color: Color, radius: CGFloat, x: CGFloat, y: CGFloat) -> some View {
        modifier(InnerShadowModifier(color: color, radius: radius, x: x, y: y))
    }
}

// MARK: - 机械按键按钮
struct MechanicalButton: View {
    var title: String
    var isActive: Bool = false
    var action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(title)
        }
        .buttonStyle(MechanicalButtonStyle(isActive: isActive))
    }
}
