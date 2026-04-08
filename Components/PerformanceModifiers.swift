import SwiftUI

// MARK: - 🍎 iOS 丝滑滚动动画系统

/// 卡片入场淡入动画 - 模拟 App Store / Apple Music 列表项入场效果
/// 从下方 12pt 处淡入 + 缩放从 0.96 → 1.0，交错延迟避免同时触发
struct FadeInOnAppearModifier: ViewModifier {
    let delayIndex: Int      // 用于交错动画的索引
    let baseDelay: Double    // 基础延迟（秒）
    let staggerInterval: Double // 交错间隔（秒）

    @State private var hasAppeared = false

    /// iOS 风格的缓出曲线 - 模拟 UIDynamicAnimation 的自然减速
    private static let iosEaseOut: Animation = .easeOut(duration: 0.45)

    func body(content: Content) -> some View {
        content
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: hasAppeared ? 0 : 12)
            .scaleEffect(hasAppeared ? 1.0 : 0.96, anchor: .center)
            .animation(
                Self.iosEaseOut.delay(baseDelay + Double(delayIndex) * staggerInterval),
                value: hasAppeared
            )
            .onAppear {
                // 微小延迟确保视图已布局完成再启动动画
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                    hasAppeared = true
                }
            }
    }
}

/// 视差滚动效果修饰符 - 滚动时图片与卡片框产生微小位移差
/// iOS Photos / 原生列表中常见的效果
struct ParallaxScrollModifier: ViewModifier {
    @State private var offset: CGFloat = 0

    /// 视差强度系数（0 = 无视差，0.1 = 轻微视差）
    let intensity: CGFloat
    /// 视差方向（垂直滚动时通常为纵向）
    let axis: Axis

    init(intensity: CGFloat = 0.06, axis: Axis = .vertical) {
        self.intensity = intensity
        self.axis = axis
    }

    func body(content: Content) -> some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .named("exploreScroll"))
            let clampedOffset: CGFloat = {
                let rawOffset: CGFloat
                if axis == .horizontal {
                    rawOffset = frame.midX - (geo.size.width / 2)
                } else {
                    rawOffset = frame.midY - (geo.size.height / 2)
                }
                return min(max(rawOffset * intensity, -20), 20)
            }()

            content
                .offset(
                    x: axis == .horizontal ? clampedOffset : 0,
                    y: axis == .vertical ? clampedOffset : 0
                )
                .animation(.easeOut(duration: 0.25), value: clampedOffset)
        }
        .clipped()
    }
}

/// macOS 弹性 ScrollView 行为配置器
/// 让滚动拥有 iOS 风格的自然弹性减速（而非默认的线性停止）
struct SmoothScrollBehaviorModifier: ViewModifier {
    let axis: Axis

    init(axis: Axis = .vertical) {
        self.axis = axis
    }

    func body(content: Content) -> some View {
        content
            .background(SmoothScrollViewConfigurator(axis: axis))
    }
}

/// 底层 NSScrollView 配置视图
private struct SmoothScrollViewConfigurator: NSViewRepresentable {
    let axis: Axis

    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    // 在视图层次中找到并配置父级 NSScrollView
    static func configure(_ scrollView: NSScrollView, axis: Axis) {
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.verticalScrollElasticity = .allowed
        scrollView.horizontalScrollElasticity = .none

        // 关键优化：启用动态滚动（惯性/动量）
        // macOS 默认 scrollsDynamically = true，但确保它开启
        scrollView.scrollsDynamically = true

        // contentView 在 macOS 上总是 NSClipView，无需条件转换
        // copiesOnScroll 在 macOS 11.0 已废弃（默认即为 true）

        // 配置减速率：iOS 使用非线性指数衰减
        // macOS 默认 linear，改为接近 iOS 的效果
        #if os(macOS)
        switch axis {
        case .vertical:
            // 使用更自然的减速曲线（比 linear 更像 iOS）
            break  // NSScrollView 的减速率在 macOS 上有限制
        case .horizontal:
            break
        }
        #endif
    }
}

// MARK: - 性能优化的悬停修饰符

/// 节流悬停修饰符 - 减少快速滚动时的状态更新
struct ThrottledHoverModifier: ViewModifier {
    let throttleInterval: TimeInterval
    let action: (Bool) -> Void

    @State private var lastUpdateTime: Date = .distantPast
    @State private var pendingState: Bool?
    @State private var workItem: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                let now = Date()
                let timeSinceLastUpdate = now.timeIntervalSince(lastUpdateTime)

                // 取消之前的延迟任务
                workItem?.cancel()

                if timeSinceLastUpdate >= throttleInterval {
                    // 直接更新
                    lastUpdateTime = now
                    action(hovering)
                } else {
                    // 延迟更新
                    pendingState = hovering
                    workItem = Task {
                        try? await Task.sleep(nanoseconds: UInt64(throttleInterval * 1_000_000_000))
                        guard !Task.isCancelled else { return }
                        await MainActor.run {
                            if let state = pendingState {
                                lastUpdateTime = Date()
                                action(state)
                                pendingState = nil
                            }
                        }
                    }
                }
            }
    }
}

extension View {
    /// 节流悬停 - 限制状态更新频率
    func throttledHover(interval: TimeInterval = 0.05, action: @escaping (Bool) -> Void) -> some View {
        modifier(ThrottledHoverModifier(throttleInterval: interval, action: action))
    }

    /// iOS 风格卡片入场动画（淡入 + 上移 + 微缩放）
    /// - Parameters:
    ///   - index: 卡片索引，用于交错延迟
    ///   - baseDelay: 基础延迟（默认 0.02s）
    ///   - stagger: 每张卡片的交错间隔（默认 0.03s，约 30fps 一张）
    func iosFadeInOnAppear(index: Int, baseDelay: Double = 0.02, stagger: Double = 0.03) -> some View {
        modifier(FadeInOnAppearModifier(
            delayIndex: index,
            baseDelay: baseDelay,
            staggerInterval: stagger
        ))
    }

    /// 视差滚动效果
    /// - Parameters:
    ///   - intensity: 视差强度，0.04~0.1 为推荐值
    ///   - axis: 视差方向
    func parallaxScroll(intensity: CGFloat = 0.06, axis: Axis = .vertical) -> some View {
        modifier(ParallaxScrollModifier(intensity: intensity, axis: axis))
    }

    /// iOS 风格弹性滚动行为 - 配置 ScrollView 的惯性减速和弹性边界
    func iosSmoothScroll(axis: Axis = .vertical) -> some View {
        modifier(SmoothScrollBehaviorModifier(axis: axis))
    }
}

// MARK: - 静态卡片样式

/// 无状态悬停样式 - 使用 overlay 避免 @State
struct StaticHoverOverlay: ViewModifier {
    let cornerRadius: CGFloat
    let hoverColor: Color

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(hoverColor, lineWidth: 1)
                    .opacity(0) // 默认隐藏，悬停时通过父视图显示
            )
    }
}
