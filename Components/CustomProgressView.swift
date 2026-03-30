import SwiftUI

// MARK: - 自定义加载指示器（解决 ProgressView 尺寸约束警告）
struct CustomProgressView: View {
    var tint: Color = .white
    var scale: CGFloat = 1.0
    
    @State private var isAnimating = false
    
    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.3), lineWidth: 2)
                .frame(width: 20 * scale, height: 20 * scale)
            
            Circle()
                .trim(from: 0, to: 0.7)
                .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: 20 * scale, height: 20 * scale)
                .rotationEffect(Angle(degrees: isAnimating ? 360 : 0))
        }
        .onAppear {
            withAnimation(
                .linear(duration: 1)
                .repeatForever(autoreverses: false)
            ) {
                isAnimating = true
            }
        }
    }
}

// MARK: - 简化的加载点（用于更小的占位）
struct LoadingDots: View {
    var tint: Color = .white.opacity(0.72)
    
    @State private var animatingDot = 0
    
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(tint)
                    .frame(width: 6, height: 6)
                    .scaleEffect(animatingDot == index ? 1.2 : 0.8)
                    .opacity(animatingDot == index ? 1.0 : 0.5)
            }
        }
        .onAppear {
            withAnimation(
                .easeInOut(duration: 0.4)
                .repeatForever(autoreverses: true)
            ) {
                animatingDot = 2
            }
        }
    }
}

// MARK: - 带固定尺寸的 ProgressView 包装器
struct FixedProgressView: View {
    var tint: Color = .white
    
    var body: some View {
        ProgressView()
            .progressViewStyle(CircularProgressViewStyle(tint: tint))
            .frame(width: 24, height: 24)
            .fixedSize()
    }
}

// MARK: - 液态玻璃线性进度条（简约风格）
struct LiquidGlassLinearProgressBar: View {
    let progress: Double
    var height: CGFloat = 6
    var tintColor: Color = LiquidGlassColors.primaryPink
    var trackOpacity: Double = 0.15

    var body: some View {
        GeometryReader { proxy in
            let clampedProgress = max(0, min(progress, 1))
            let fillWidth = max(height, proxy.size.width * clampedProgress)

            ZStack(alignment: .leading) {
                // 轨道 - 液态玻璃效果
                Capsule(style: .continuous)
                    .fill(.ultraThinMaterial)
                    .opacity(trackOpacity)
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                    )

                // 填充 - 简约单色
                Capsule(style: .continuous)
                    .fill(tintColor.opacity(0.85))
                    .frame(width: fillWidth)
                    .overlay(
                        // 液态玻璃高光
                        Capsule(style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.4),
                                        Color.white.opacity(0.1),
                                        Color.clear
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(width: fillWidth)
                    )
            }
        }
        .frame(height: height)
    }
}
