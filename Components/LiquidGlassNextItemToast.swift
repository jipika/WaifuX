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

// MARK: - 液态玻璃下一张弹窗
public struct LiquidGlassNextItemToast: View {
    let nextItem: NextItemPreviewable?
    let onTap: () -> Void
    let onScrollUp: () -> Void
    let onScrollDown: () -> Void

    @State private var isVisible = false
    @State private var viewTimer: Timer?
    @State private var isHovered = false
    @State private var isPressed = false

    // 配置
    private let appearDelay: TimeInterval = 3.0
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
                        .transition(
                            .asymmetric(
                                insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .move(edge: .trailing).combined(with: .opacity)
                            )
                        )
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

    // MARK: - Toast 内容 - 深色原生液态玻璃（参考 detailGlassCircleChrome 样式）
    private func toastContent(item: NextItemPreviewable) -> some View {
        Button(action: {
            // 点击后隐藏弹窗并触发回调
            withAnimation(.easeOut(duration: 0.2)) {
                isVisible = false
            }
            onTap()
        }) {
            HStack(spacing: 10) {
                // 缩略图
                thumbnailView(item: item)

                // 文字信息
                VStack(alignment: .leading, spacing: 3) {
                    Text(t("library.nextOne"))
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

    // MARK: - 计时器管理
    private func startViewTimer() {
        stopViewTimer()
        Task { @MainActor in
            viewTimer = Timer.scheduledTimer(withTimeInterval: appearDelay, repeats: false) { _ in
                Task { @MainActor in
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                        isVisible = true
                    }
                }
            }
        }
    }

    private func stopViewTimer() {
        viewTimer?.invalidate()
        viewTimer = nil
    }

    private func resetViewTimer() {
        withAnimation(.easeOut(duration: 0.2)) {
            isVisible = false
        }
        startViewTimer()
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
