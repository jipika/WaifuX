import SwiftUI
import AppKit

// MARK: - 高性能可回收网格视图
// 用 NSCollectionView 替代 LazyVGrid，获得：
// 1. 真正的 cell 回收复用池（NSCollectionViewItem reuse）
// 2. iOS 风格弹簧出现动画
// 3. 原生级滚动流畅度

/// 通用数据协议：只要能提供唯一 ID 即可
protocol RecyclableGridItem: Identifiable {
    var id: String { get }
}

/// 配置参数
struct RecyclableGridConfig: Equatable {
    let columnCount: Int
    let spacing: CGFloat
    let cardWidth: CGFloat
    let cardHeight: CGFloat
    let contentWidth: CGFloat

    static func wallpaperConfig(contentWidth: CGFloat) -> RecyclableGridConfig {
        let columnCount = contentWidth > 1200 ? 4 : (contentWidth > 800 ? 3 : 2)
        let spacing: CGFloat = 16
        let totalSpacing = spacing * CGFloat(columnCount - 1)
        let cardWidth = floor((contentWidth - totalSpacing) / CGFloat(columnCount))
        let cardHeight = cardWidth * 0.6
        return RecyclableGridConfig(
            columnCount: columnCount, spacing: spacing,
            cardWidth: cardWidth, cardHeight: cardHeight,
            contentWidth: contentWidth
        )
    }

    static func animeConfig(contentWidth: CGFloat) -> RecyclableGridConfig {
        let columnCount = contentWidth > 1200 ? 5 : (contentWidth > 800 ? 4 : 3)
        let spacing: CGFloat = 20
        let totalSpacing = spacing * CGFloat(columnCount - 1)
        let cardWidth = floor((contentWidth - totalSpacing) / CGFloat(columnCount))
        let cardHeight = cardWidth * 1.4
        return RecyclableGridConfig(
            columnCount: columnCount, spacing: spacing,
            cardWidth: cardWidth, cardHeight: cardHeight,
            contentWidth: contentWidth
        )
    }

    static func mediaConfig(contentWidth: CGFloat) -> RecyclableGridConfig {
        wallpaperConfig(contentWidth: contentWidth)
    }
}

// MARK: - NonScrollingScrollView
/// NSScrollView 子类：截获所有滚动事件并转发给下一个 responder（SwiftUI ScrollView），
/// 从而消除嵌套滚动冲突。同时保留 NSScrollView 作为 NSCollectionView 的合法容器，
/// 确保 tab 切换后 NSCollectionView 能正确重新显示。

class NonScrollingScrollView: NSScrollView {
    /// 监听 SwiftUI 通过 opacity 修饰符设置的 layer.opacity，
    /// 当从 0 恢复为可见时，强制刷新 NSCollectionView 布局和显示。
    private var opacityObservation: NSKeyValueObservation?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && opacityObservation == nil {
            wantsLayer = true
            // 用 KVO 监听 layer.opacity 变化
            opacityObservation = layer?.observe(\.opacity, options: [.new, .old]) { [weak self] layer, change in
                guard let self = self else { return }
                let newOpacity: Double = change.newValue.map { Double($0) } ?? 1.0
                let oldOpacity: Double = change.oldValue.map { Double($0) } ?? 1.0

                if oldOpacity == 0.0 && newOpacity > 0.0 {
                    Task { @MainActor in
                        self.refreshAfterOpacityRestore()
                    }
                }
            }
        }
        if window == nil {
            opacityObservation = nil
        }
    }

    /// 从 opacity=0 恢复后强制刷新 NSCollectionView
    @MainActor
    private func refreshAfterOpacityRestore() {
        guard let collectionView = documentView as? NSCollectionView else { return }

        // 1. 强制重新计算布局
        collectionView.collectionViewLayout?.invalidateLayout()
        collectionView.needsLayout = true
        layoutSubtreeIfNeeded()

        // 2. 确保正确的 frame（SwiftUI 可能改变了 frame）
        let frame = self.frame
        if frame.height > 0 {
            collectionView.frame = NSRect(x: 0, y: 0, width: frame.width, height: frame.height)
        }

        // 3. 递归标记所有 subview 的 layer 需要 display
        markNeedsDisplayRecursive(collectionView)

        // 4. 延迟二次刷新，确保 CALayer 树已完全更新
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.layoutSubtreeIfNeeded()
            if let cv = self.documentView as? NSCollectionView {
                cv.collectionViewLayout?.invalidateLayout()
                cv.needsLayout = true
                cv.setNeedsDisplay(self.bounds)
                self.markNeedsDisplayRecursive(cv)
            }
        }
    }

    /// 递归标记视图及其所有子视图的 layer 需要 display
    private func markNeedsDisplayRecursive(_ view: NSView) {
        view.setNeedsDisplay(view.bounds)
        for subview in view.subviews {
            markNeedsDisplayRecursive(subview)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        // 将滚动事件转发给 SwiftUI 的响应链，不自己处理
        self.nextResponder?.scrollWheel(with: event)
    }
}

// MARK: - NSViewRepresentable

struct RecyclableGridView<Item: RecyclableGridItem, CardContent: View>: NSViewRepresentable {
    let items: [Item]
    let config: RecyclableGridConfig
    let cardContent: (Item, CGFloat, CGFloat) -> CardContent
    let showNoMore: Bool

    init(
        items: [Item],
        config: RecyclableGridConfig,
        @ViewBuilder cardContent: @escaping (Item, CGFloat, CGFloat) -> CardContent,
        showNoMore: Bool = false
    ) {
        self.items = items
        self.config = config
        self.cardContent = cardContent
        self.showNoMore = showNoMore
    }

    func makeNSView(context: Context) -> NonScrollingScrollView {
        // 使用 NonScrollingScrollView 包裹 NSCollectionView
        // NSCollectionView 必须嵌入 NSScrollView 才能正常工作（Apple 文档要求），
        // 但 NonScrollingScrollView 会将滚动事件转发给外层 SwiftUI ScrollView，
        // 消除手势截获问题。
        let scrollView = NonScrollingScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.wantsLayer = true

        let collectionView = NSCollectionView()
        collectionView.delegate = context.coordinator
        collectionView.dataSource = context.coordinator
        collectionView.isSelectable = false
        collectionView.backgroundColors = [.clear]
        collectionView.wantsLayer = true

        // FlowLayout
        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = .vertical
        layout.minimumInteritemSpacing = config.spacing
        layout.minimumLineSpacing = config.spacing
        layout.sectionInset = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        collectionView.collectionViewLayout = layout

        // 注册 Cell
        collectionView.register(
            GridHostingCollectionItem.self,
            forItemWithIdentifier: NSUserInterfaceItemIdentifier("GridCell")
        )
        collectionView.register(
            NoMoreFooterItem.self,
            forItemWithIdentifier: NSUserInterfaceItemIdentifier("NoMoreFooter")
        )

        scrollView.documentView = collectionView
        context.coordinator.collectionView = collectionView

        // 设置 scrollView frame 以匹配内容高度
        let contentHeight = calculateContentHeight()
        scrollView.frame = NSRect(x: 0, y: 0, width: config.contentWidth, height: contentHeight)

        return scrollView
    }

    func updateNSView(_ scrollView: NonScrollingScrollView, context: Context) {
        guard let collectionView = scrollView.documentView as? NSCollectionView else { return }
        let coordinator = context.coordinator

        let needsReload = coordinator.lastConfig != config ||
                          coordinator.hasItemContentChanged(old: coordinator.currentItems, new: items) ||
                          coordinator.lastShowNoMore != showNoMore

        coordinator.currentItems = items
        coordinator.config = config
        coordinator.cardContent = cardContent
        coordinator.showNoMore = showNoMore

        if needsReload {
            coordinator.lastConfig = config
            coordinator.lastShowNoMore = showNoMore

            // 更新 layout 间距
            if let layout = collectionView.collectionViewLayout as? NSCollectionViewFlowLayout {
                layout.minimumInteritemSpacing = config.spacing
                layout.minimumLineSpacing = config.spacing
            }

            // 重新计算内容高度并同步更新 scrollView + collectionView frame
            let contentHeight = calculateContentHeight()
            scrollView.frame = NSRect(x: 0, y: 0, width: config.contentWidth, height: contentHeight)
            collectionView.frame = NSRect(x: 0, y: 0, width: config.contentWidth, height: contentHeight)

            // 先更新 frame 再 reloadData，避免布局抖动
            collectionView.collectionViewLayout?.invalidateLayout()
            collectionView.reloadData()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            items: items,
            config: config,
            cardContent: cardContent,
            showNoMore: showNoMore
        )
    }
    
    /// 计算内容总高度，用于强制设置 NSCollectionView 的 frame
    private func calculateContentHeight() -> CGFloat {
        guard !items.isEmpty else { return 0 }
        let rows = ceil(Double(items.count) / Double(config.columnCount))
        let cardHeight = config.cardHeight + 44 // 底部信息栏约 44pt
        let totalHeight = rows * Double(cardHeight) + max(0, rows - 1) * Double(config.spacing)
        return CGFloat(totalHeight)
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout {
        var currentItems: [Item]
        var config: RecyclableGridConfig
        var cardContent: (Item, CGFloat, CGFloat) -> CardContent
        var showNoMore: Bool
        weak var collectionView: NSCollectionView?

        // Diff 状态
        var lastConfig: RecyclableGridConfig?
        var lastShowNoMore: Bool = false

        init(
            items: [Item],
            config: RecyclableGridConfig,
            cardContent: @escaping (Item, CGFloat, CGFloat) -> CardContent,
            showNoMore: Bool
        ) {
            self.currentItems = items
            self.config = config
            self.cardContent = cardContent
            self.showNoMore = showNoMore
        }

        func hasItemContentChanged(old: [Item], new: [Item]) -> Bool {
            guard old.count == new.count else { return true }
            // 快速路径：检查最后几项 ID 变化（增量追加场景）
            for (o, n) in zip(old, new) {
                if o.id != n.id { return true }
            }
            return false
        }

        // MARK: - Data Source

        func numberOfSections(in collectionView: NSCollectionView) -> Int {
            1
        }

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            currentItems.count + (showNoMore ? 1 : 0)
        }

        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            // "no more" footer
            if indexPath.item == currentItems.count && showNoMore {
                guard let item = collectionView.makeItem(
                    withIdentifier: NSUserInterfaceItemIdentifier("NoMoreFooter"),
                    for: indexPath
                ) as? NoMoreFooterItem else {
                    return NSCollectionViewItem()
                }
                return item
            }

            guard indexPath.item < currentItems.count else {
                // 返回一个空的 GridHostingCollectionItem 作为后备
                let fallbackItem = collectionView.makeItem(
                    withIdentifier: NSUserInterfaceItemIdentifier("GridCell"),
                    for: indexPath
                ) as! GridHostingCollectionItem
                fallbackItem.hostingView?.rootView = AnyView(EmptyView())
                return fallbackItem
            }

            guard let item = collectionView.makeItem(
                withIdentifier: NSUserInterfaceItemIdentifier("GridCell"),
                for: indexPath
            ) as? GridHostingCollectionItem else {
                // 如果创建失败，返回一个默认的 NSCollectionViewItem
                return NSCollectionViewItem()
            }

            let dataItem = currentItems[indexPath.item]
            let card = cardContent(dataItem, config.cardWidth, config.cardHeight)
            item.hostingView?.rootView = AnyView(card)
            item.itemId = dataItem.id
            item.itemIndex = indexPath.item

            // 触发弹簧入场动画
            item.triggerAppearAnimation(itemId: dataItem.id, index: indexPath.item)

            return item
        }

        // MARK: - Layout

        func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> NSSize {
            if indexPath.item == currentItems.count && showNoMore {
                return NSSize(width: config.contentWidth, height: 40)
            }
            // 卡片高度 = 图片高度 + 底部信息栏（约 44pt）
            let cardHeight = config.cardHeight + 44
            return NSSize(width: config.cardWidth, height: cardHeight)
        }

        func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout, insetForSectionAt section: Int) -> NSEdgeInsets {
            NSEdgeInsetsZero
        }

        func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout, minimumInteritemSpacingForSectionAt section: Int) -> CGFloat {
            config.spacing
        }

        func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout, minimumLineSpacingForSectionAt section: Int) -> CGFloat {
            config.spacing
        }

    }
}

// MARK: - SwiftUI 托管 Cell

class GridHostingCollectionItem: NSCollectionViewItem {
    var hostingView: NSHostingView<AnyView>!
    var itemId: String = ""
    var itemIndex: Int = 0

    // 弹簧动画 - 全局追踪已做过入场动画的 item（与 FadeInOnAppearModifier 共享逻辑）
    private static var animatedItems: Set<String> = []
    private static var animatedItemsOrder: [String] = []
    private static let maxAnimatedItems = 1000
    private static let lock = NSLock()

    private static func markAsAnimated(_ id: String) {
        lock.lock()
        defer { lock.unlock() }
        if animatedItems.contains(id) {
            if let index = animatedItemsOrder.firstIndex(of: id) {
                animatedItemsOrder.remove(at: index)
                animatedItemsOrder.append(id)
            }
            return
        }
        animatedItems.insert(id)
        animatedItemsOrder.append(id)
        while animatedItemsOrder.count > maxAnimatedItems {
            let oldest = animatedItemsOrder.removeFirst()
            animatedItems.remove(oldest)
        }
    }

    private static func isAnimated(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return animatedItems.contains(id)
    }

    /// 清除所有入场动画记录（用于全量数据替换场景）
    static func resetAllAnimatedItems() {
        lock.lock()
        defer { lock.unlock() }
        animatedItems.removeAll()
        animatedItemsOrder.removeAll()
    }

    override func loadView() {
        let hosting = NSHostingView(rootView: AnyView(EmptyView()))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        self.view = hosting
        self.hostingView = hosting
    }

    func triggerAppearAnimation(itemId: String, index: Int) {
        let alreadyAnimated = Self.isAnimated(itemId)

        if alreadyAnimated {
            // 已做过动画，直接显示
            self.view.wantsLayer = true
            self.view.layer?.removeAllAnimations()
            self.view.layer?.opacity = 1.0
            self.view.layer?.transform = CATransform3DIdentity
            return
        }

        // 交错延迟（与 iosFadeInOnAppear 参数一致）
        let effectiveIndex = min(index, 12)
        let staggerDelay = 0.008 + Double(effectiveIndex) * 0.022

        // 延迟到 reloadData() 布局完成后再设置初始状态和动画
        // 基础延迟 0.05s 确保 NSCollectionView 布局 pass 完成，不会被覆盖
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05 + staggerDelay) { [weak self] in
            guard let self = self, self.itemId == itemId else { return }

            let view = self.view
            view.wantsLayer = true
            guard let layer = view.layer else { return }

            // 先设置初始状态（透明 + 向下偏移 + 缩小）
            layer.opacity = 0.0
            layer.transform = CATransform3DTranslate(CATransform3DMakeScale(0.9, 0.9, 1.0), 0, 20, 0)

            // 使用 CATransaction 显式驱动 Core Animation（比 NSAnimationContext 更可靠）
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.5)
            // iOS 弹簧曲线 (response: 0.5, dampingFraction: 0.72)
            CATransaction.setAnimationTimingFunction(
                CAMediaTimingFunction(controlPoints: 0.175, 0.885, 0.32, 1.075)
            )
            CATransaction.setCompletionBlock {
                Self.markAsAnimated(itemId)
            }

            layer.opacity = 1.0
            layer.transform = CATransform3DIdentity
            CATransaction.commit()
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        itemId = ""
        itemIndex = 0
        // 重置视觉状态
        view.layer?.removeAllAnimations()
        view.layer?.opacity = 1.0
        view.layer?.transform = CATransform3DIdentity
        // 安全地重置 hostingView
        if let hostingView = hostingView {
            hostingView.rootView = AnyView(EmptyView())
        }
    }
}

// MARK: - "No More" Footer Cell

class NoMoreFooterItem: NSCollectionViewItem {
    override func loadView() {
        let container = NSView()
        container.wantsLayer = true

        let leftLine = NSView()
        leftLine.wantsLayer = true
        leftLine.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.15).cgColor
        leftLine.translatesAutoresizingMaskIntoConstraints = false

        let rightLine = NSView()
        rightLine.wantsLayer = true
        rightLine.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.15).cgColor
        rightLine.translatesAutoresizingMaskIntoConstraints = false

        let noMoreText = LocalizationService.shared.t("noMore")
        let label = NSTextField(labelWithString: "— \(noMoreText) —")
        label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.25)
        label.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(leftLine)
        container.addSubview(label)
        container.addSubview(rightLine)

        NSLayoutConstraint.activate([
            leftLine.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            leftLine.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            leftLine.widthAnchor.constraint(equalToConstant: 32),
            leftLine.heightAnchor.constraint(equalToConstant: 1),

            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            rightLine.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            rightLine.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            rightLine.widthAnchor.constraint(equalToConstant: 32),
            rightLine.heightAnchor.constraint(equalToConstant: 1),
        ])

        self.view = container
    }
}
