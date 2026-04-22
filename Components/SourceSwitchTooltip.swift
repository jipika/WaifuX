import SwiftUI

// MARK: - 切换源按钮引导提示
/// 首次使用时在切换源按钮旁显示箭头提示，点击"知道了"后不再显示
struct SourceSwitchTooltip: ViewModifier {
    let tooltipKey: String
    let message: String
    @State private var isVisible: Bool = false
    
    private var hasBeenDismissed: Bool {
        UserDefaults.standard.bool(forKey: tooltipKey)
    }
    
    func body(content: Content) -> some View {
        content
            .overlay {
                if isVisible {
                    GeometryReader { geo in
                        tooltipBubble
                            .position(
                                x: geo.size.width + 8 + 80,
                                y: geo.size.height / 2
                            )
                    }
                    .allowsHitTesting(true)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .onAppear {
                if !hasBeenDismissed {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8).delay(0.6)) {
                        isVisible = true
                    }
                }
            }
    }
    
    private var tooltipBubble: some View {
        HStack(spacing: 0) {
            // 向左箭头（指向按钮）
            Triangle(direction: .left)
                .fill(Color.black.opacity(0.82))
                .frame(width: 6, height: 10)
            
            VStack(spacing: 10) {
                Text(message)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .multilineTextAlignment(.center)
                
                Button {
                    UserDefaults.standard.set(true, forKey: tooltipKey)
                    withAnimation(.easeOut(duration: 0.25)) {
                        isVisible = false
                    }
                } label: {
                    Text("知道了")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.white.opacity(0.18))
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.black.opacity(0.82))
            )
        }
        .shadow(color: .black.opacity(0.35), radius: 16, x: 0, y: 8)
        .frame(width: 160)
    }
}

// MARK: - 三角形箭头
private struct Triangle: Shape {
    enum Direction { case up, down, left, right }
    var direction: Direction = .up
    
    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch direction {
        case .up:
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        case .down:
            path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        case .left:
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        case .right:
            path.move(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - View Extension
extension View {
    func sourceSwitchTooltip(key: String, message: String) -> some View {
        modifier(SourceSwitchTooltip(tooltipKey: key, message: message))
    }
}
