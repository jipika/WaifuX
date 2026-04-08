import SwiftUI

// MARK: - 丝滑动画配置
enum SmoothAnimation {
    /// 卡片悬停缩放 - 使用 spring 实现弹性效果
    static let cardHover = Animation.spring(
        response: 0.35,
        dampingFraction: 0.75,
        blendDuration: 0.1
    )
    
    /// 卡片按下效果
    static let cardPress = Animation.spring(
        response: 0.2,
        dampingFraction: 0.8,
        blendDuration: 0.05
    )
    
    /// Hero 转场动画
    static let heroTransition = Animation.spring(
        response: 0.45,
        dampingFraction: 0.85,
        blendDuration: 0.2
    )
    
    /// 列表项出现动画
    static let listAppear = Animation.spring(
        response: 0.5,
        dampingFraction: 0.7,
        blendDuration: 0.2
    )
}

// MARK: - Hero 动画状态管理
@MainActor
class HeroAnimationState: ObservableObject {
    @Published var selectedItemId: String?
    @Published var selectedItemFrame: CGRect = .zero
    @Published var selectedItemImage: NSImage?
    @Published var isAnimating = false
    
    func startHeroTransition(itemId: String, from frame: CGRect, image: NSImage?) {
        selectedItemId = itemId
        selectedItemFrame = frame
        selectedItemImage = image
        isAnimating = true
    }
    
    func endHeroTransition() {
        isAnimating = false
        // 延迟清理，让动画完成
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.selectedItemId = nil
            self.selectedItemFrame = .zero
            self.selectedItemImage = nil
        }
    }
}

// MARK: - 卡片悬停效果修饰器
struct CardHoverEffect: ViewModifier {
    @State private var isHovered = false
    @State private var isPressed = false
    let scale: CGFloat
    
    init(scale: CGFloat = 1.03) {
        self.scale = scale
    }
    
    func body(content: Content) -> some View {
        content
            .scaleEffect(isPressed ? 0.97 : (isHovered ? scale : 1.0))
            .animation(SmoothAnimation.cardPress, value: isPressed)
            .animation(SmoothAnimation.cardHover, value: isHovered)
            .onHover { hovering in
                if isHovered != hovering {
                    isHovered = hovering
                }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        isPressed = true
                    }
                    .onEnded { _ in
                        isPressed = false
                    }
            )
    }
}

// MARK: - 列表项出现动画修饰器
struct ListItemAppearEffect: ViewModifier {
    let index: Int
    @State private var isVisible = false
    
    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .offset(y: isVisible ? 0 : 20)
            .scaleEffect(isVisible ? 1 : 0.95)
            .animation(
                SmoothAnimation.listAppear.delay(Double(index) * 0.03),
                value: isVisible
            )
            .onAppear {
                isVisible = true
            }
    }
}

// MARK: - View 扩展
extension View {
    /// 添加卡片悬停效果
    func cardHoverEffect(scale: CGFloat = 1.03) -> some View {
        modifier(CardHoverEffect(scale: scale))
    }
    
    /// 添加列表项出现动画
    func listItemAppear(at index: Int) -> some View {
        modifier(ListItemAppearEffect(index: index))
    }
    
    /// 条件性应用修饰符（用于可选的 Namespace）
    @ViewBuilder
    func ifLet<T, Content: View>(_ value: T?, @ViewBuilder transform: (Self, T) -> Content) -> some View {
        if let value = value {
            transform(self, value)
        } else {
            self
        }
    }
}

// MARK: - 几何坐标追踪
struct GlobalFramePreferenceKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

extension View {
    /// 追踪视图在窗口中的全局坐标
    func trackGlobalFrame(_ frame: Binding<CGRect>) -> some View {
        self.background(
            GeometryReader { geometry in
                Color.clear
                    .preference(key: GlobalFramePreferenceKey.self, value: geometry.frame(in: .global))
            }
        )
        .onPreferenceChange(GlobalFramePreferenceKey.self) { newFrame in
            frame.wrappedValue = newFrame
        }
    }
}
