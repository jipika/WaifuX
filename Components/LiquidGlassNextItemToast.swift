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

// MARK: - 深色液态玻璃下一张弹窗 - iOS 丝滑动画风格
public struct LiquidGlassNextItemToast: View {
    let nextItem: NextItemPreviewable?
    let onTap: () -> Void
    let onScrollUp: () -> Void
    let onScrollDown: () -> Void

    @State private var isVisible = false
    @State private var viewTimer: Timer?
    @State private var isHovered = false
    @State private var isPressed = false
    @State private var contentOpacity: Double = 0
    @State private var contentScale: Double = 0.85
    @State private var contentOffset: CGFloat = 20
    @State private var isDismissing: Bool = false

    // 配置
    private let appearDelay: TimeInterval = 3.0
    private let toastHeight: CGFloat = 80
    private let toastWidth: CGFloat = 280

    /// iOS 丝滑弹簧动画 - 用于入场
    private var iOSSpringAnimation: Animation {
        .spring(response: 0.42, dampingFraction: 0.78, blendDuration: 0)
    }

    /// iOS 丝滑弹簧动画 - 用于退场（稍快）
    private var iOSDismissAnimation: Animation {
        .spring(response: 0.28, dampingFraction: 0.88, blendDuration: 0)
    }

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
                    // iOS 风格：背景遮罩层（极轻微暗化，不拦截点击）
                    Color.black.opacity(0.08)
                        .ignoresSafeArea()
                        .opacity(contentOpacity * 0.6)
                        .allowsHitTesting(false)

                    toastContent(item: item)
                        .frame(width: toastWidth, height: toastHeight)
                        .position(
                            x: geometry.size.width - toastWidth / 2 - 20,
                            y: geometry.size.height - toastHeight / 2 - 20
                        )
                        // 确保 toast 整个区域可点击
                        .contentShape(Rectangle())
                        .opacity(contentOpacity)
                        // 入场：从右边缘滑入 + 缩放
                        .scaleEffect(contentScale, anchor: .trailing)
                        .offset(x: (1 - contentOpacity) * 60, y: contentOffset)
                        .transition(
                            .asymmetric(
                                insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .opacity
                            )
                        )
                        // 放大散开消失效果：完成时模糊扩散
                        .blur(radius: isDismissing ? 8 : (1 - contentScale) * 3)
                }
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

    // MARK: - Toast 按钮（内部组件，使用 ButtonStyle 处理按压效果）
    private struct ToastButton: View {
        let item: NextItemPreviewable
        @Binding var isHovered: Bool
        @Binding var isPressed: Bool
        let onTap: () -> Void
        
        var body: some View {
            Button(action: onTap) {
                HStack(spacing: 12) {
                    // 缩略图
                    ThumbnailView(item: item)

                    // 文字信息
                    VStack(alignment: .leading, spacing: 4) {
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

                    // 向下箭头指示（弹窗在底部）
                    VStack(spacing: 2) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(0.6))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .buttonStyle(ToastPressableStyle(isPressed: $isPressed))
            .background(
                DarkLiquidGlassBackground(
                    cornerRadius: 20,
                    isHovered: isHovered
                )
            )
            // iOS 风格按压反馈：轻微缩放 + 暗色叠加
            .scaleEffect(isPressed ? 0.96 : 1.0)
            .animation(iOSSmoothEase(duration: 0.18), value: isPressed)
            .onHover { hovering in
                withAnimation(iOSSmoothEase(duration: 0.25)) {
                    isHovered = hovering
                }
            }
        }
        
        /// iOS 平滑缓动曲线
        private func iOSSmoothEase(duration: TimeInterval) -> Animation {
            .easeInOut(duration: duration)
        }
    }
    
    // 按钮样式：内部处理按压状态
    private struct ToastPressableStyle: ButtonStyle {
        @Binding var isPressed: Bool
        
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .onChange(of: configuration.isPressed) { _, newValue in
                    isPressed = newValue
                }
        }
    }

    // MARK: - Toast 内容 - 真正的深色液态玻璃材质
    private func toastContent(item: NextItemPreviewable) -> some View {
        ToastButton(
            item: item,
            isHovered: $isHovered,
            isPressed: $isPressed,
            onTap: {
                dismissWithAnimation {
                    onTap()
                }
            }
        )
    }

    // MARK: - 缩略图视图（结构体版本）
    private struct ThumbnailView: View {
        let item: NextItemPreviewable
        
        var body: some View {
            ZStack {
                if let url = item.previewThumbnailURL {
                    OptimizedAsyncImage(url: url, priority: .low) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } placeholder: {
                        PlaceholderView()
                    }
                } else {
                    PlaceholderView()
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
            )
        }
    }

    private struct PlaceholderView: View {
        var body: some View {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    Image(systemName: "photo")
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.3))
                )
        }
    }

    // MARK: - 计时器管理 & iOS 丝滑动画控制

    /// iOS 风格入场动画：右侧滑入 + 缩放（类似 iOS 卡片插入效果）
    private func performIOSShowAnimation() {
        // 重置初始状态
        isDismissing = false
        contentOpacity = 0
        contentScale = 0.85
        contentOffset = 8

        withAnimation(iOSSpringAnimation) {
            contentOpacity = 1
            contentScale = 1.0
            contentOffset = 0
        }
    }

    /// iOS 风格退场动画：放大 + 模糊散开消失（类似粒子扩散）
    private func dismissWithAnimation(completion: @escaping () -> Void) {
        isDismissing = true

        // 先快速放大到超过原始尺寸
        withAnimation(.easeOut(duration: 0.15)) {
            contentOpacity = 1
            contentScale = 1.08
        }

        // 然后模糊散开 + 淡出
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [self] in
            withAnimation(.easeOut(duration: 0.22)) {
                contentOpacity = 0
                contentScale = 1.20
                contentOffset = -4
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) {
                completion()
            }
        }
    }

    private func startViewTimer() {
        stopViewTimer()
        Task { @MainActor in
            viewTimer = Timer.scheduledTimer(withTimeInterval: appearDelay, repeats: false) { _ in
                Task { @MainActor in
                    isVisible = true
                    performIOSShowAnimation()
                }
            }
        }
    }

    private func stopViewTimer() {
        viewTimer?.invalidate()
        viewTimer = nil
    }

    private func resetViewTimer() {
        dismissWithAnimation { [self] in
            isVisible = false
        }
        startViewTimer()
    }
}

// MARK: - 真正的深色液态玻璃背景
/// 基于 Apple 官方 Liquid Glass 设计规范的深色玻璃效果
struct DarkLiquidGlassBackground: View {
    let cornerRadius: CGFloat
    let isHovered: Bool

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                // macOS 26+: 使用原生 Liquid Glass API
                NativeDarkLiquidGlass(cornerRadius: cornerRadius, isHovered: isHovered)
            } else {
                // 旧版本: 使用 Material 模拟深色液态玻璃
                FallbackDarkLiquidGlass(cornerRadius: cornerRadius, isHovered: isHovered)
            }
        }
    }
}

// MARK: - macOS 26+ 原生深色液态玻璃
@available(macOS 26.0, *)
private struct NativeDarkLiquidGlass: View {
    let cornerRadius: CGFloat
    let isHovered: Bool

    var body: some View {
        ZStack {
            // 基础玻璃效果 - 使用 thickMaterial 作为深色基底
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.thickMaterial)

            // 深色色调叠加 - 实现深色玻璃效果
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.black.opacity(0.35))

            // 玻璃反光 - 顶部高光
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(isHovered ? 0.15 : 0.08),
                            Color.white.opacity(0.02),
                            Color.clear
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            // 底部阴影 - 增强立体感
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.clear,
                            Color.black.opacity(0.15)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
        .overlay(
            // 边框 - 液态玻璃风格
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(isHovered ? 0.25 : 0.15),
                            Color.white.opacity(0.05),
                            Color.white.opacity(0.02)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(
            color: Color.black.opacity(isHovered ? 0.4 : 0.25),
            radius: isHovered ? 24 : 16,
            x: 0,
            y: isHovered ? 12 : 8
        )
    }
}

// MARK: - 旧版本深色液态玻璃回退实现
private struct FallbackDarkLiquidGlass: View {
    let cornerRadius: CGFloat
    let isHovered: Bool

    var body: some View {
        ZStack {
            // 基础材质层 - 使用 ultraThickMaterial 作为深色基底
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.ultraThickMaterial)
                .opacity(0.85)

            // 深色色调层 - 模拟深色玻璃
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(hex: "1A1A2E").opacity(0.6),
                            Color(hex: "12121F").opacity(0.7)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            // 玻璃反光层 - 顶部高光
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(isHovered ? 0.12 : 0.06),
                            Color.white.opacity(0.02),
                            Color.clear
                        ],
                        startPoint: .topLeading,
                        endPoint: .center
                    )
                )

            // 底部渐变 - 增强深度感
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.clear,
                            Color.black.opacity(0.2)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
        .overlay(
            // 边框 - 液态玻璃风格
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(isHovered ? 0.2 : 0.12),
                            Color.white.opacity(0.06),
                            Color.clear
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(
            color: Color.black.opacity(isHovered ? 0.35 : 0.22),
            radius: isHovered ? 20 : 14,
            x: 0,
            y: isHovered ? 10 : 6
        )
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

            // 下一张弹窗（容器本身不拦截点击，只有 toast 按钮接收点击）
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
