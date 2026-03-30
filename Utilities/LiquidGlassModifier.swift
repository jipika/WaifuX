import SwiftUI

// MARK: - 基础玻璃态修饰器
struct LiquidGlassModifier: ViewModifier {
    var cornerRadius: CGFloat = 20
    var material: Material = .ultraThinMaterial
    var opacity: Double = 0.7

    func body(content: Content) -> some View {
        content
            .liquidGlassSurface(
                level(for: material, opacity: opacity),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
    }

    private func level(for material: Material, opacity: Double) -> LiquidGlassLevel {
        _ = material
        if opacity >= 0.9 {
            return .max
        }
        if opacity >= 0.78 {
            return .prominent
        }
        if opacity >= 0.64 {
            return .regular
        }
        return .subtle
    }
}

// MARK: - 聚光灯效果
struct SpotlightModifier: ViewModifier {
    var center: CGPoint
    var radius: CGFloat
    var intensity: Double

    func body(content: Content) -> some View {
        content
            .overlay(
                RadialGradient(
                    colors: [
                        .white.opacity(intensity),
                        .clear
                    ],
                    center: UnitPoint(x: center.x, y: center.y),
                    startRadius: 0,
                    endRadius: radius
                )
                .clipShape(RoundedRectangle(cornerRadius: 0))
            )
    }
}

// MARK: - View 扩展方法
extension View {
    func liquidGlass(
        cornerRadius: CGFloat = 20,
        material: Material = .ultraThinMaterial,
        opacity: Double = 0.7
    ) -> some View {
        modifier(LiquidGlassModifier(cornerRadius: cornerRadius, material: material, opacity: opacity))
    }

    func glassCard() -> some View {
        self
            .liquidGlassSurface(.prominent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - 玻璃态渐变背景
struct MeshGradientBackground: View {
    var body: some View {
        ZStack {
            // 基础深色
            Color(hex: "0A0A0F")

            // 动态渐变背景
            RadialGradient(
                colors: [
                    Color(hex: "1a0a2e").opacity(0.8),
                    Color(hex: "0D0D0D")
                ],
                center: .topLeading,
                startRadius: 0,
                endRadius: 800
            )
            .opacity(0.6)
            .blur(radius: 60)
        }
        .ignoresSafeArea()
    }
}
