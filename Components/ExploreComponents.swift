import SwiftUI
import AppKit

// MARK: - 探索页公共组件

/// 加载更多指示器
public struct LoadingMoreIndicator: View {
    @State private var isAnimating = false
    
    public init() {}
    
    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.2.circlepath")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .rotationEffect(.degrees(isAnimating ? 360 : 0))
                .animation(.linear(duration: 1.0).repeatForever(autoreverses: false), value: isAnimating)
                .onAppear { isAnimating = true }
                .onDisappear { isAnimating = false }
            
            Text(t("loading.simple"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

/// 没有更多数据提示
public struct NoMoreFooter: View {
    public init() {}
    
    public var body: some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(Color.white.opacity(0.15))
                .frame(height: 1)
            
            Text("— \(t("noMore")) —")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.25))
            
            Rectangle()
                .fill(Color.white.opacity(0.15))
                .frame(height: 1)
        }
        .padding(.horizontal, 40)
    }
}

// MARK: - 滚动加载状态

/// 用于 onScrollGeometryChange 的状态类型
private struct ScrollLoadState: Equatable {
    let nearBottom: Bool
    let atBottom: Bool
}

// MARK: - 跨版本兼容的滚动加载更多

/// 滚动加载更多修饰符
/// macOS 15+ 使用 onScrollGeometryChange，macOS 14 使用 PreferenceKey 滚动追踪
public struct ScrollLoadMoreModifier: ViewModifier {
    @Binding var scrollOffset: CGFloat
    @Binding var contentSize: CGFloat
    @Binding var containerSize: CGFloat
    let earlyThreshold: CGFloat  // 提前加载阈值
    let bottomThreshold: CGFloat // 触底加载阈值
    let onLoadMore: () -> Void
    let checkLoadMore: (CGFloat, CGFloat, CGFloat) -> Void  // offset, contentSize, containerSize

    // 防止重复触发的状态
    @State private var isLoadingTriggered = false

    public init(
        scrollOffset: Binding<CGFloat>,
        contentSize: Binding<CGFloat> = .constant(0),
        containerSize: Binding<CGFloat> = .constant(0),
        earlyThreshold: CGFloat = 800,
        bottomThreshold: CGFloat = 100,
        onLoadMore: @escaping () -> Void,
        checkLoadMore: @escaping (CGFloat, CGFloat, CGFloat) -> Void
    ) {
        self._scrollOffset = scrollOffset
        self._contentSize = contentSize
        self._containerSize = containerSize
        self.earlyThreshold = earlyThreshold
        self.bottomThreshold = bottomThreshold
        self.onLoadMore = onLoadMore
        self.checkLoadMore = checkLoadMore
    }

    public func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                // 合并的滚动位置检测（避免重复触发）
                .onScrollGeometryChange(for: ScrollLoadState.self) { geometry in
                    let bottomOffset = geometry.contentOffset.y + geometry.containerSize.height
                    let nearBottom = bottomOffset >= geometry.contentSize.height - earlyThreshold
                    let atBottom = bottomOffset >= geometry.contentSize.height - bottomThreshold
                    return ScrollLoadState(nearBottom: nearBottom, atBottom: atBottom)
                } action: { oldValue, newValue in
                    // 只在从假变真时触发
                    if newValue.nearBottom && !oldValue.nearBottom {
                        isLoadingTriggered = true
                        onLoadMore()
                    } else if newValue.atBottom && !oldValue.atBottom && !isLoadingTriggered {
                        // 如果提前加载未触发，才触发触底加载
                        onLoadMore()
                    }
                    // 滚动回顶部时重置状态
                    if !newValue.nearBottom && oldValue.nearBottom {
                        isLoadingTriggered = false
                    }
                }
                // 滚动中暂停列表 GIF 动画（同时更新 scrollOffset 供返回顶部按钮使用）
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    geometry.contentOffset.y
                } action: { _, newValue in
                    scrollOffset = newValue
                    ExploreListGIFPlaybackState.shared.noteListScrolling()
                }
        } else {
            content
                .background(
                    GeometryReader { geometry in
                        Color.clear
                            .onAppear {
                                containerSize = geometry.size.height
                            }
                            .onChange(of: geometry.size.height) { _, newHeight in
                                containerSize = newHeight
                            }
                    }
                )
                .onPreferenceChange(ExploreScrollOffsetKey.self) { value in
                    scrollOffset = value
                    ExploreListGIFPlaybackState.shared.noteListScrolling()
                }
                .onPreferenceChange(ExploreContentSizeKey.self) { value in
                    contentSize = value
                }
                .onChange(of: scrollOffset) { _, offset in
                    // 使用简单的距离判断，避免依赖可能过时的 contentSize
                    checkLoadMore(offset, contentSize, containerSize)
                }
        }
    }
}

// MARK: - Content Size PreferenceKey (macOS 14)

/// macOS 14 用 PreferenceKey 追踪内容高度
public struct ExploreContentSizeKey: PreferenceKey {
    public static let defaultValue: CGFloat = 0
    public static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - PreferenceKey

/// macOS 14 用 PreferenceKey 追踪滚动偏移量
public struct ExploreScrollOffsetKey: PreferenceKey {
    public static let defaultValue: CGFloat = 0
    public static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// 通用滚动偏移追踪（其他视图使用）
public struct ScrollOffsetPreferenceKey: PreferenceKey {
    public static let defaultValue: CGFloat = 0
    public static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - 滚动到顶部助手

/// 放在 ScrollView 内容顶部，通过 PreferenceKey 报告当前滚动偏移量。
public struct ScrollOffsetTracker: View {
    public let coordinateSpace: String

    public init(coordinateSpace: String) {
        self.coordinateSpace = coordinateSpace
    }

    public var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: ScrollOffsetPreferenceKey.self,
                value: -proxy.frame(in: .named(coordinateSpace)).minY
            )
        }
        .frame(height: 0)
    }
}

/// 用于从 SwiftUI ScrollView 内部触发滚动到顶部，并实时报告滚动偏移量的 AppKit 桥接助手。
/// 当 `trigger` 变化时，向上遍历视图层级找到 NSScrollView 并将 contentOffset 归零。
/// 同时通过 KVO 监听底层 NSScrollView 的 bounds 变化，实时回调 `onOffsetChange`。
public struct ScrollToTopHelper: NSViewRepresentable {
    public var trigger: Int
    public var onOffsetChange: ((CGFloat) -> Void)?

    public init(trigger: Int, onOffsetChange: ((CGFloat) -> Void)? = nil) {
        self.trigger = trigger
        self.onOffsetChange = onOffsetChange
    }

    public func makeNSView(context: Context) -> NSView {
        let view = ScrollToTopNSView()
        view.onOffsetChange = onOffsetChange
        return view
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? ScrollToTopNSView else { return }
        view.onOffsetChange = onOffsetChange

        guard trigger != context.coordinator.lastTrigger else { return }
        context.coordinator.lastTrigger = trigger
        view.scrollToTop()
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    public class Coordinator {
        public var lastTrigger: Int = 0
        public init() {}
    }
}

private final class ScrollToTopNSView: NSView {
    var onOffsetChange: ((CGFloat) -> Void)?
    private var observation: NSKeyValueObservation?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        startObserving()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            observation?.invalidate()
            observation = nil
        }
    }

    private func startObserving() {
        guard observation == nil else { return }
        guard let scrollView = findParentScrollView() else { return }

        observation = scrollView.contentView.observe(\.bounds, options: [.new, .initial]) { [weak self] clipView, _ in
            self?.onOffsetChange?(clipView.bounds.origin.y)
        }
    }

    private func findParentScrollView() -> NSScrollView? {
        var current = superview
        while let view = current {
            if let scrollView = view as? NSScrollView {
                return scrollView
            }
            current = view.superview
        }
        return nil
    }

    func scrollToTop() {
        guard let scrollView = findParentScrollView() else { return }
        let origin = NSPoint(x: 0, y: 0)
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}

// MARK: - 入场动画修饰符

/// 统一的卡片入场动画
public struct CardEntranceAnimation: ViewModifier {
    let isVisible: Bool
    let delay: Double
    
    public init(isVisible: Bool, delay: Double = 0) {
        self.isVisible = isVisible
        self.delay = delay
    }
    
    public func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0.4)
            .offset(y: isVisible ? 0 : 16)
            .scaleEffect(isVisible ? 1 : 0.96)
            .animation(.spring(response: 0.35, dampingFraction: 0.8).delay(delay), value: isVisible)
    }
}

/// 滚动过渡动画
public struct ScrollTransitionModifier: ViewModifier {
    public init() {}
    
    public func body(content: Content) -> some View {
        content.scrollTransition { content, phase in
            content
                .scaleEffect(phase.isIdentity ? 1 : 0.95)
                .opacity(phase.isIdentity ? 1 : 0.8)
        }
    }
}

// MARK: - 问候语文本

public var greetingText: String {
    let hour = Calendar.current.component(.hour, from: Date())
    switch hour {
    case 5..<12: return "Good Morning"
    case 12..<18: return "Good Afternoon"
    default: return "Good Evening"
    }
}

// MARK: - View 扩展

extension View {
    /// 应用统一的卡片入场动画
    public func cardEntrance(isVisible: Bool, delay: Double = 0) -> some View {
        modifier(CardEntranceAnimation(isVisible: isVisible, delay: delay))
    }
    
    /// 应用滚动过渡动画
    public func scrollTransitionEffect() -> some View {
        modifier(ScrollTransitionModifier())
    }
}
