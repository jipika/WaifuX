import SwiftUI
import Combine

// MARK: - 下一张项目数据协议
/// 用于统一 Wallpaper 和 MediaItem 的预览数据
public protocol NextItemPreviewable {
    var previewId: String { get }
    var previewTitle: String { get }
    var previewSubtitle: String { get }
    var previewThumbnailURL: URL? { get }
    var previewResolution: String { get }
    var previewBadge: String? { get }
}

// MARK: - Wallpaper 扩展
extension Wallpaper: NextItemPreviewable {
    public var previewId: String { id }
    public var previewTitle: String { resolution }
    public var previewSubtitle: String { "\(views) 浏览 · \(favorites) 收藏" }
    public var previewThumbnailURL: URL? { thumbURL }
    public var previewResolution: String { resolution }
    public var previewBadge: String? { categoryDisplayName }
}

// MARK: - MediaItem 扩展
extension MediaItem: NextItemPreviewable {
    public var previewId: String { id }
    public var previewTitle: String { title }
    public var previewSubtitle: String { tags.first ?? collectionTitle ?? sourceName }
    public var previewThumbnailURL: URL? { posterURL ?? thumbnailURL }
    public var previewResolution: String { primaryBadgeText }
    public var previewBadge: String? { previewVideoURL != nil ? "LIVE" : nil }
}

// MARK: - 下一张项目数据源
@MainActor
public class NextItemDataSource: ObservableObject {
    @Published public private(set) var items: [NextItemPreviewable] = []
    @Published public private(set) var currentIndex: Int = 0

    public var currentItem: NextItemPreviewable? {
        guard currentIndex >= 0, currentIndex < items.count else { return nil }
        return items[currentIndex]
    }

    public var nextItem: NextItemPreviewable? {
        let nextIndex = currentIndex + 1
        guard nextIndex >= 0, nextIndex < items.count else { return nil }
        return items[nextIndex]
    }

    public var hasNext: Bool {
        currentIndex + 1 < items.count
    }

    public var hasPrevious: Bool {
        currentIndex > 0
    }

    public func setItems(_ newItems: [NextItemPreviewable], currentIndex: Int) {
        self.items = newItems
        self.currentIndex = max(0, min(currentIndex, newItems.count - 1))
    }

    public func moveToNext() {
        guard hasNext else { return }
        currentIndex += 1
    }

    public func moveToPrevious() {
        guard hasPrevious else { return }
        currentIndex -= 1
    }

    public func moveToIndex(_ index: Int) {
        guard index >= 0, index < items.count else { return }
        currentIndex = index
    }
}

// MARK: - 滚动事件监测视图
private struct ScrollWheelMonitorView: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ScrollWheelMonitorNSView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let monitorView = nsView as? ScrollWheelMonitorNSView else { return }
        monitorView.onScroll = onScroll
    }
}

// MARK: - 滚动监测 NSView
private class ScrollWheelMonitorNSView: NSView {
    var onScroll: ((CGFloat) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        onScroll?(event.scrollingDeltaY)
        super.scrollWheel(with: event)
    }

    override var acceptsFirstResponder: Bool { true }
}

// MARK: - 液态玻璃下一张弹窗
public struct LiquidGlassNextItemToast: View {
    let nextItem: NextItemPreviewable?
    let onTap: () -> Void
    let onScrollUp: () -> Void
    let onScrollDown: () -> Void

    @State private var isVisible = false
    @State private var viewTimer: Timer?
    @State private var scrollOffset: CGFloat = 0
    @State private var isAnimating = false
    @State private var isHovered = false
    @State private var isPressed = false

    // 滚轮累积
    @State private var accumulatedScrollDelta: CGFloat = 0

    // 配置
    private let appearDelay: TimeInterval = 3.0
    private let scrollThreshold: CGFloat = 60.0
    private let toastHeight: CGFloat = 80
    private let toastWidth: CGFloat = 260

    public init(
        nextItem: NextItemPreviewable?,
        onTap: @escaping () -> Void,
        onScrollUp: @escaping () -> Void = {},
        onScrollDown: @escaping () -> Void = {}
    ) {
        self.nextItem = nextItem
        self.onTap = onTap
        self.onScrollUp = onScrollUp
        self.onScrollDown = onScrollDown
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack {
                if isVisible, let item = nextItem {
                    toastContent(item: item)
                        .frame(width: toastWidth, height: toastHeight)
                        .position(
                            x: geometry.size.width - toastWidth / 2 - 20,
                            y: geometry.size.height - toastHeight / 2 - 20
                        )
                        .offset(y: scrollOffset)
                        .transition(
                            .asymmetric(
                                insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .move(edge: .trailing).combined(with: .opacity)
                            )
                        )
                }

                // 滚动事件监测层（覆盖整个屏幕）
                ScrollWheelMonitorView { delta in
                    handleScrollWheel(delta: delta)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
            }
            .onAppear {
                startViewTimer()
            }
            .onDisappear {
                stopViewTimer()
            }
            .onChange(of: nextItem?.previewId) { _, _ in
                resetViewTimer()
            }
        }
    }

    // MARK: - 滚轮事件处理
    private func handleScrollWheel(delta: CGFloat) {
        guard !isAnimating, nextItem != nil else { return }

        accumulatedScrollDelta += delta

        // 检测滚动阈值
        if accumulatedScrollDelta < -scrollThreshold {
            // 向上滚动超过阈值，翻到下一张
            accumulatedScrollDelta = 0
            performFlipAnimation(direction: .up)
        } else if accumulatedScrollDelta > scrollThreshold {
            // 向下滚动超过阈值，翻到上一张
            accumulatedScrollDelta = 0
            performFlipAnimation(direction: .down)
        }
    }

    // MARK: - Toast 内容 - 深色原生液态玻璃（参考 detailGlassCircleChrome 样式）
    private func toastContent(item: NextItemPreviewable) -> some View {
        Button(action: {
            performFlipAnimation(direction: .up)
        }) {
            HStack(spacing: 10) {
                // 缩略图
                thumbnailView(item: item)

                // 文字信息
                VStack(alignment: .leading, spacing: 3) {
                    Text("下一张")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))

                    Text(item.previewTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Text(item.previewSubtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }

                Spacer()

                // 向上箭头指示
                VStack(spacing: 2) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.6))
                    Image(systemName: "chevron.up")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        // 应用深色原生液态玻璃样式（与 detailGlassCircleChrome 一致）
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                )
        )
        .overlay(
            // 边框 - 与 detailGlassCircleChrome 样式一致
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(isHovered ? 0.34 : 0.25),
                            Color.white.opacity(isHovered ? 0.10 : 0.06)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: .black.opacity(0.22), radius: 16, y: 8)
        .scaleEffect(isPressed ? 0.96 : 1.0)
        .animation(.easeInOut(duration: 0.1), value: isPressed)
        .gesture(
            DragGesture(minimumDistance: 10)
                .onChanged { value in
                    handleDragChanged(value: value)
                }
                .onEnded { value in
                    handleDragEnded(value: value)
                }
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
        .pressEvents {
            isPressed = true
        } onRelease: {
            isPressed = false
        }
    }

    // MARK: - 缩略图视图
    private func thumbnailView(item: NextItemPreviewable) -> some View {
        ZStack {
            if let url = item.previewThumbnailURL {
                OptimizedAsyncImage(url: url, priority: .low) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    placeholderView
                }
            } else {
                placeholderView
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
        )
    }

    private var placeholderView: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.white.opacity(0.08))
            .overlay(
                Image(systemName: "photo")
                    .font(.system(size: 18))
                    .foregroundStyle(.white.opacity(0.3))
            )
    }

    // MARK: - 拖拽处理
    private func handleDragChanged(value: DragGesture.Value) {
        guard !isAnimating else { return }

        let translation = value.translation.height

        // 添加阻尼效果
        if translation < 0 {
            // 向上拖拽（负数）
            scrollOffset = translation * 0.6
        } else {
            // 向下拖拽（正数）
            scrollOffset = translation * 0.4
        }
    }

    private func handleDragEnded(value: DragGesture.Value) {
        let translation = value.translation.height
        let velocity = value.predictedEndLocation.y - value.location.y

        // 判断是否超过阈值或有足够速度
        let shouldGoNext = translation < -scrollThreshold || (translation < -20 && velocity < -100)
        let shouldGoPrev = translation > scrollThreshold || (translation > 20 && velocity > 100)

        if shouldGoNext {
            performFlipAnimation(direction: .up)
        } else if shouldGoPrev {
            performFlipAnimation(direction: .down)
        } else {
            // 回弹
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                scrollOffset = 0
            }
        }
    }

    // MARK: - 翻页动画
    private func performFlipAnimation(direction: FlipDirection) {
        guard !isAnimating else { return }
        isAnimating = true

        let offsetAmount: CGFloat = direction == .up ? -50 : 50

        // 第一阶段：向上/下移动并淡出
        withAnimation(.easeOut(duration: 0.12)) {
            scrollOffset = offsetAmount
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            // 触发回调
            if direction == .up {
                onScrollUp()
            } else {
                onScrollDown()
            }

            // 第二阶段：复位（从反方向弹回）
            scrollOffset = -offsetAmount * 0.3

            withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) {
                scrollOffset = 0
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                isAnimating = false
                resetViewTimer()
            }
        }
    }

    // MARK: - 计时器管理
    private func startViewTimer() {
        stopViewTimer()
        viewTimer = Timer.scheduledTimer(withTimeInterval: appearDelay, repeats: false) { _ in
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                isVisible = true
            }
        }
    }

    private func stopViewTimer() {
        viewTimer?.invalidate()
        viewTimer = nil
    }

    private func resetViewTimer() {
        accumulatedScrollDelta = 0
        withAnimation(.easeOut(duration: 0.2)) {
            isVisible = false
        }
        startViewTimer()
    }

    enum FlipDirection {
        case up, down
    }
}

// MARK: - 详情页弹窗容器
public struct DetailPageWithNextItemToast<Content: View>: View {
    let content: Content
    @ObservedObject var dataSource: NextItemDataSource
    let onNavigateToNext: () -> Void
    let onNavigateToPrevious: () -> Void

    public init(
        dataSource: NextItemDataSource,
        onNavigateToNext: @escaping () -> Void,
        onNavigateToPrevious: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.dataSource = dataSource
        self.onNavigateToNext = onNavigateToNext
        self.onNavigateToPrevious = onNavigateToPrevious
        self.content = content()
    }

    public var body: some View {
        ZStack {
            content

            // 下一张弹窗
            LiquidGlassNextItemToast(
                nextItem: dataSource.nextItem,
                onTap: {
                    onNavigateToNext()
                },
                onScrollUp: {
                    onNavigateToNext()
                },
                onScrollDown: {
                    onNavigateToPrevious()
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(dataSource.nextItem != nil)
        }
    }
}

// MARK: - 便捷扩展
public extension View {
    /// 为详情页添加下一张弹窗功能
    func withNextItemToast(
        dataSource: NextItemDataSource,
        onNavigateToNext: @escaping () -> Void,
        onNavigateToPrevious: @escaping () -> Void = {}
    ) -> some View {
        DetailPageWithNextItemToast(
            dataSource: dataSource,
            onNavigateToNext: onNavigateToNext,
            onNavigateToPrevious: onNavigateToPrevious
        ) {
            self
        }
    }
}
