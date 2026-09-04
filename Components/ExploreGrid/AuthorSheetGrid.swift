import AppKit
import SwiftUI

// MARK: - 作者弹窗卡片度量
//
// 与 SwiftUI 卡片（原 AuthorWallpaperCard / AuthorMediaCard）的字号、间距一一对应，
// 供布局（高度计算）与 Cell（内部排版）共用，保证两端几何一致。
enum AuthorSheetCardMetrics {
    /// 固定两列卡宽（原 LazyVGrid GridItem(.fixed(158))）
    static let cardWidth: CGFloat = 158
    /// 封面高度（原 KFImage frame(height: 100)）
    static let cardImageHeight: CGFloat = 100
    /// 列/行间距（原 GridItem spacing 与 LazyVGrid spacing 均 12）
    static let cardSpacing: CGFloat = 12
    /// 网格左右内边距（原 ScrollView 内容 .padding(.horizontal, 16)）
    static let horizontalInset: CGFloat = 16
    /// 底部余量（原 .padding(.bottom, 20) + 尾部 Color.clear 12）
    static let bottomInset: CGFloat = 32
    /// 卡片圆角（原 cardCornerRadius 14）
    static let cardCornerRadius: CGFloat = 14

    // NSFont 非 Sendable，用计算属性规避 Swift 6 静态存储并发检查；
    // systemFont 内部有缓存，度量访问频率低，无性能问题
    static var titleFont: NSFont { .systemFont(ofSize: 11, weight: .semibold) }
    static var categoryFont: NSFont { .systemFont(ofSize: 10, weight: .semibold) }
    static var resolutionFont: NSFont { .systemFont(ofSize: 9, weight: .medium) }

    static let titleLineHeight: CGFloat = ceil(titleFont.boundingRectForFont.height)
    static let categoryTextHeight: CGFloat = ceil(categoryFont.boundingRectForFont.height)
    static let resolutionLineHeight: CGFloat = ceil(resolutionFont.boundingRectForFont.height)

    /// 分类胶囊高：文本 + .padding(.vertical, 2)
    static var categoryCapsuleHeight: CGFloat { categoryTextHeight + 4 }
    /// 分类胶囊水平内边距（原 .padding(.horizontal, 6)）
    static let categoryCapsuleHorizontalPadding: CGFloat = 6
    /// 卡内文字统一水平边距（原 .padding(.horizontal, 8)）
    static let textHorizontalPadding: CGFloat = 8
    /// 分类胶囊与分辨率文本间距（原 HStack spacing 6）
    static let bottomRowSpacing: CGFloat = 6

    /// 底部信息行高度（分类胶囊 16 与分辨率文本取最大）
    static func wallpaperBottomRowHeight(hasCategory: Bool, hasResolution: Bool) -> CGFloat {
        max(hasCategory ? categoryCapsuleHeight : 0, hasResolution ? resolutionLineHeight : 0)
    }

    /// AuthorWallpaperCard 卡高：封面 100 + 可选标题行 + 底部信息行
    static func wallpaperCardHeight(hasTitle: Bool, hasCategory: Bool, hasResolution: Bool) -> CGFloat {
        let titleBlock: CGFloat = hasTitle ? 7 + titleLineHeight : 0
        let bottomBlock: CGFloat = (hasTitle ? 4 : 7)
            + wallpaperBottomRowHeight(hasCategory: hasCategory, hasResolution: hasResolution)
            + 7
        return cardImageHeight + titleBlock + bottomBlock
    }

    /// AuthorMediaCard 卡高（固定：封面 100 + 标题上下各 7）
    static var mediaCardHeight: CGFloat { cardImageHeight + 7 + titleLineHeight + 7 }

    /// 布局兜底宽度：两列卡 + 列间距 + 左右内边距
    static var fallbackLayoutWidth: CGFloat {
        cardWidth * 2 + cardSpacing + horizontalInset * 2
    }
}

// MARK: - 行式网格布局
//
// 还原 LazyVGrid 的排布语义：固定两列、行高取行内最大卡高、
// 短卡在行槽内垂直居中（LazyVGrid 默认 center 对齐）。
@MainActor
protocol AuthorSheetGridLayoutDelegate: AnyObject {
    func collectionView(_ collectionView: NSCollectionView, heightForItemAt indexPath: IndexPath) -> CGFloat
}

final class AuthorSheetGridLayout: NSCollectionViewLayout {

    weak var delegate: AuthorSheetGridLayoutDelegate?

    var columnCount: Int = 2
    var columnSpacing: CGFloat = AuthorSheetCardMetrics.cardSpacing
    var rowSpacing: CGFloat = AuthorSheetCardMetrics.cardSpacing
    var contentInsets = NSEdgeInsets(
        top: 0,
        left: AuthorSheetCardMetrics.horizontalInset,
        bottom: AuthorSheetCardMetrics.bottomInset,
        right: AuthorSheetCardMetrics.horizontalInset
    )

    private var cache: [NSCollectionViewLayoutAttributes] = []
    private var contentHeight: CGFloat = 0
    private var needsCacheRebuild = true
    private var lastPreparedWidth: CGFloat = 0
    private var lastPreparedItemCount: Int = -1

    var cachedItemCount: Int { cache.count }
    var preparedWidth: CGFloat { lastPreparedWidth }

    override func prepare() {
        rebuildCacheIfNeeded()
    }

    override func invalidateLayout() {
        needsCacheRebuild = true
        super.invalidateLayout()
    }

    private func rebuildCacheIfNeeded() {
        guard let collectionView else {
            cache.removeAll()
            contentHeight = 0
            needsCacheRebuild = true
            return
        }

        let totalWidth = collectionView.bounds.width
        let itemCount = collectionView.numberOfItems(inSection: 0)

        guard totalWidth > 0 else {
            cache.removeAll()
            contentHeight = 0
            needsCacheRebuild = true
            return
        }

        guard needsCacheRebuild
            || abs(totalWidth - lastPreparedWidth) > 0.5
            || itemCount != lastPreparedItemCount else { return }

        cache.removeAll(keepingCapacity: true)
        contentHeight = 0

        let columns = max(1, columnCount)
        let availableWidth = totalWidth - contentInsets.left - contentInsets.right
        // 与 LazyVGrid .fixed 列一致：可用宽度富余时整块居中，不足时收窄卡片
        let cardWidth = min(
            AuthorSheetCardMetrics.cardWidth,
            max(1, floor((availableWidth - columnSpacing * CGFloat(columns - 1)) / CGFloat(columns)))
        )
        let gridWidth = cardWidth * CGFloat(columns) + columnSpacing * CGFloat(columns - 1)
        let leadingInset = contentInsets.left + max(0, floor((availableWidth - gridWidth) / 2))

        // NSCollectionView 自身是 flipped 坐标（y 向下增长）
        var yOffset = contentInsets.top
        var index = 0
        while index < itemCount {
            let rowItemCount = min(columns, itemCount - index)
            var rowHeight: CGFloat = 0
            var rowHeights: [CGFloat] = []
            for column in 0..<rowItemCount {
                let indexPath = IndexPath(item: index + column, section: 0)
                let height = resolvedHeight(forItemAt: indexPath, in: collectionView)
                rowHeights.append(height)
                rowHeight = max(rowHeight, height)
            }
            for column in 0..<rowItemCount {
                let height = rowHeights[column]
                let frame = CGRect(
                    x: leadingInset + CGFloat(column) * (cardWidth + columnSpacing),
                    y: yOffset + (rowHeight - height) / 2,
                    width: cardWidth,
                    height: height
                )
                let attributes = NSCollectionViewLayoutAttributes(
                    forItemWith: IndexPath(item: index + column, section: 0)
                )
                attributes.frame = frame
                cache.append(attributes)
            }
            yOffset += rowHeight + rowSpacing
            index += rowItemCount
        }
        contentHeight = max(0, yOffset - rowSpacing) + contentInsets.bottom

        lastPreparedWidth = totalWidth
        lastPreparedItemCount = itemCount
        needsCacheRebuild = false
    }

    private func resolvedHeight(forItemAt indexPath: IndexPath, in collectionView: NSCollectionView) -> CGFloat {
        let height = delegate?.collectionView(collectionView, heightForItemAt: indexPath)
            ?? AuthorSheetCardMetrics.mediaCardHeight
        return height > 1 ? height : AuthorSheetCardMetrics.mediaCardHeight
    }

    override var collectionViewContentSize: NSSize {
        rebuildCacheIfNeeded()
        return NSSize(
            width: collectionView?.bounds.width ?? 0,
            height: contentHeight
        )
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        rebuildCacheIfNeeded()
        guard !cache.isEmpty else { return [] }
        return cache.filter { $0.frame.intersects(rect) }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        rebuildCacheIfNeeded()
        guard indexPath.item >= 0, indexPath.item < cache.count else { return nil }
        return cache[indexPath.item]
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        guard let collectionView else { return false }
        return newBounds.width != collectionView.bounds.width
    }
}

// MARK: - 占位 scroller（同 ExploreGrid：不绘制、不命中，避免 overlay 滚动条闪现）
@MainActor
private final class AuthorSheetInvisibleScroller: NSScroller {
    override func draw(_ dirtyRect: NSRect) {}
    override class var isCompatibleWithOverlayScrollers: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var usableParts: NSScroller.UsableParts {
        get { .noScrollerParts }
        set {}
    }
}

// MARK: - 滚动容器
@MainActor
private final class AuthorSheetGridScrollView: NSScrollView {
    weak var gridCoordinator: AuthorSheetGridCoordinator?

    override func layout() {
        super.layout()
        gridCoordinator?.scheduleLayoutDocument()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            self?.gridCoordinator?.scheduleLayoutDocument()
        }
    }
}

// MARK: - NSCollectionView 数据源/代理协调器
//
// 结构对齐 ExploreGridCoordinator 的已验证路径：延迟 reloadData / performBatchUpdates
// （避免在窗口 display cycle 内触发布局循环）、触底回调、layoutDocument 补布局。
@MainActor
final class AuthorSheetGridCoordinator: NSObject {

    var parent: AuthorSheetGridContainer
    let collectionView: NSCollectionView
    let scrollView: NSScrollView
    private let layout: AuthorSheetGridLayout

    var lastItemCount = 0
    var lastReloadToken = 0
    private var pendingReload: DispatchWorkItem?
    private var pendingBatchUpdate: DispatchWorkItem?
    private var pendingLayoutDocument: DispatchWorkItem?
    private var hasPendingReachBottomCheck = false
    private var lastLaidOutWidth: CGFloat = 0
    private var isUpdatingDocumentLayout = false
    /// 原 SwiftUI 哨兵在距底 ~80pt 内触发加载；这里放宽少许作为等效阈值
    private static let reachBottomThreshold: CGFloat = 120

    init(_ parent: AuthorSheetGridContainer) {
        self.parent = parent
        let layout = AuthorSheetGridLayout()
        self.layout = layout

        let collectionView = NSCollectionView()
        collectionView.wantsLayer = true
        collectionView.collectionViewLayout = layout
        collectionView.backgroundColors = [.clear]
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        collectionView.allowsEmptySelection = true
        self.collectionView = collectionView

        let scrollView = AuthorSheetGridScrollView()
        scrollView.wantsLayer = true
        scrollView.documentView = collectionView
        let invisibleV = AuthorSheetInvisibleScroller()
        invisibleV.scrollerStyle = .overlay
        let invisibleH = AuthorSheetInvisibleScroller()
        invisibleH.scrollerStyle = .overlay
        scrollView.verticalScroller = invisibleV
        scrollView.horizontalScroller = invisibleH
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.scrollsDynamically = true
        scrollView.verticalScrollElasticity = .allowed
        scrollView.horizontalScrollElasticity = .none
        scrollView.usesPredominantAxisScrolling = true
        self.scrollView = scrollView

        super.init()

        scrollView.gridCoordinator = self
        collectionView.register(
            parent.cellClass,
            forItemWithIdentifier: parent.cellClass.gridReuseIdentifier
        )
        collectionView.dataSource = self
        collectionView.delegate = self
        layout.delegate = self

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewDidScroll(_:)),
            name: NSScrollView.didLiveScrollNotification,
            object: scrollView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewDidEndScroll(_:)),
            name: NSScrollView.didEndLiveScrollNotification,
            object: scrollView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipViewBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        MainActor.assumeIsolated {
            pendingReload?.cancel()
            pendingBatchUpdate?.cancel()
            pendingLayoutDocument?.cancel()
        }
    }

    // MARK: - 滚动 / 触底

    @objc private func scrollViewDidScroll(_ notification: Notification) {
        scheduleReachBottomCheck()
    }

    @objc private func scrollViewDidEndScroll(_ notification: Notification) {
        scheduleReachBottomCheck()
    }

    @objc private func clipViewBoundsDidChange(_ notification: Notification) {
        guard !isUpdatingDocumentLayout else { return }
        let width = scrollView.contentView.bounds.width
        if width > 0, abs(width - lastLaidOutWidth) > 0.5 {
            scheduleLayoutDocument()
        }
        scheduleReachBottomCheck()
    }

    /// 触底检查合并到下一 runloop，且同一时刻最多挂起一个，
    /// 避免在 AppKit 滚动通知栈内同步触发 SwiftUI 状态更新。
    private func scheduleReachBottomCheck() {
        guard !hasPendingReachBottomCheck else { return }
        hasPendingReachBottomCheck = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hasPendingReachBottomCheck = false
            guard self.isNearBottom(), let onReachBottom = self.parent.onReachBottom else { return }
            onReachBottom()
        }
    }

    private func isNearBottom() -> Bool {
        let contentHeight = max(collectionView.frame.height, layout.collectionViewContentSize.height)
        let visibleRect = scrollView.contentView.bounds
        let distanceToBottom = contentHeight - (visibleRect.origin.y + visibleRect.height)
        return distanceToBottom < Self.reachBottomThreshold
    }

    // MARK: - 数据更新

    func reloadData() {
        // 延迟 collectionView.reloadData()，避免在窗口 display cycle 内同步触发布局循环。
        pendingReload?.cancel()
        pendingBatchUpdate?.cancel()
        let itemCount = parent.itemCount()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingReload = nil
            self.lastItemCount = itemCount
            self.collectionView.reloadData()
            self.layoutDocument()
            self.scheduleReachBottomCheck()
        }
        pendingReload = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    func performBatchUpdates(insertedCount: Int, oldCount: Int) {
        pendingReload?.cancel()
        pendingBatchUpdate?.cancel()
        let newTotal = oldCount + insertedCount
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingBatchUpdate = nil
            self.lastItemCount = newTotal
            let currentCount = self.collectionView.numberOfItems(inSection: 0)

            guard newTotal > currentCount else {
                self.collectionView.reloadData()
                self.layoutDocument()
                return
            }

            let newIndexPaths = (currentCount..<newTotal).map {
                IndexPath(item: $0, section: 0)
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.collectionView.performBatchUpdates {
                    self.collectionView.insertItems(at: Set(newIndexPaths))
                } completionHandler: { [weak self] _ in
                    self?.layoutDocument()
                    self?.scheduleReachBottomCheck()
                }
                CATransaction.commit()
            }
        }
        pendingBatchUpdate = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    func refreshVisibleItems() {
        pendingReload?.cancel()
        pendingBatchUpdate?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.canSafelyReconfigureVisibleItems else { return }
            for indexPath in self.collectionView.indexPathsForVisibleItems() {
                guard let item = self.collectionView.item(at: indexPath) as? ExploreGridItem else { continue }
                self.parent.configureCell(item, indexPath.item)
            }
        }
        DispatchQueue.main.async(execute: workItem)
    }

    /// 数据源与 collection view 已对齐且无未落地更新时才允许局部重配，
    /// 否则 reloadItems(at:) 极易触发 AppKit 内部断言。
    private var canSafelyReconfigureVisibleItems: Bool {
        guard pendingReload == nil, pendingBatchUpdate == nil else { return false }
        let dataCount = parent.itemCount()
        guard dataCount == lastItemCount, dataCount > 0 else { return false }
        return collectionView.numberOfItems(inSection: 0) == dataCount
    }

    // MARK: - 文档布局

    func scheduleLayoutDocument() {
        pendingLayoutDocument?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.pendingLayoutDocument = nil
            self?.layoutDocument()
        }
        pendingLayoutDocument = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    func layoutDocument() {
        guard !isUpdatingDocumentLayout else { return }
        isUpdatingDocumentLayout = true
        defer { isUpdatingDocumentLayout = false }

        let requestedWidth = max(parent.layoutWidth, scrollView.contentView.bounds.width)
        let width = max(1, requestedWidth)
        let widthChanged = abs(width - lastLaidOutWidth) > 0.5
        lastLaidOutWidth = width

        // NSCollectionViewLayout 依赖 collectionView.bounds.width 计算内容高度。
        // 初次布局时 collectionView 可能还是 .zero，先给正确宽度再读 contentSize。
        let provisionalGridHeight = max(1, collectionView.frame.height, layout.collectionViewContentSize.height)
        let provisionalFrame = CGRect(x: 0, y: 0, width: width, height: provisionalGridHeight)
        if collectionView.frame != provisionalFrame {
            collectionView.frame = provisionalFrame
        }

        let expectedItemCount = parent.itemCount()
        let layoutNeedsRebuild = expectedItemCount > 0 && layout.cachedItemCount != expectedItemCount
        if widthChanged
            || layoutNeedsRebuild
            || abs(collectionView.bounds.width - width) > 0.5
            || abs(layout.preparedWidth - width) > 0.5 {
            layout.invalidateLayout()
            collectionView.needsLayout = true
            collectionView.layoutSubtreeIfNeeded()
        }

        let gridHeight = max(1, layout.collectionViewContentSize.height)
        let newFrame = CGRect(x: 0, y: 0, width: width, height: gridHeight)
        if collectionView.frame != newFrame {
            collectionView.frame = newFrame
        }

        let visibleBounds = scrollView.contentView.bounds
        let maxOriginY = max(0, newFrame.height - visibleBounds.height)
        let clampedOrigin = NSPoint(
            x: 0,
            y: min(max(visibleBounds.origin.y, 0), maxOriginY)
        )
        if abs(clampedOrigin.y - visibleBounds.origin.y) > 0.5 || abs(visibleBounds.origin.x) > 0.5 {
            scrollView.contentView.scroll(to: clampedOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }
}

// MARK: - NSCollectionViewDataSource

extension AuthorSheetGridCoordinator: NSCollectionViewDataSource {

    func numberOfSections(in collectionView: NSCollectionView) -> Int {
        1
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        parent.itemCount()
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        let item = collectionView.makeItem(
            withIdentifier: parent.cellClass.gridReuseIdentifier,
            for: indexPath
        ) as! ExploreGridItem
        parent.configureCell(item, indexPath.item)
        return item
    }
}

// MARK: - NSCollectionViewDelegate

extension AuthorSheetGridCoordinator: NSCollectionViewDelegate {

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let indexPath = indexPaths.first else { return }
        parent.onSelect?(indexPath.item)
        collectionView.deselectItems(at: indexPaths)
    }
}

// MARK: - AuthorSheetGridLayoutDelegate

extension AuthorSheetGridCoordinator: AuthorSheetGridLayoutDelegate {

    func collectionView(_ collectionView: NSCollectionView, heightForItemAt indexPath: IndexPath) -> CGFloat {
        let height = parent.heightForItem(indexPath.item)
        return height > 1 ? height : AuthorSheetCardMetrics.mediaCardHeight
    }
}

// MARK: - SwiftUI 桥接容器
//
// 作者弹窗专用 NSCollectionView 容器：固定两列小面板场景，不需要
// ExploreGridContainer 的 header 折叠 / keep-alive / 拖拽等页面级能力。
struct AuthorSheetGridContainer: NSViewRepresentable {

    /// 数据项总数
    var itemCount: () -> Int
    /// 指定索引的卡片高度（由 AuthorSheetCardMetrics 计算）
    var heightForItem: (Int) -> CGFloat
    /// 配置 Cell
    var configureCell: (ExploreGridItem, Int) -> Void
    /// Cell 类型
    var cellClass: ExploreGridItem.Type
    /// 点击回调
    var onSelect: ((Int) -> Void)? = nil
    /// 触底回调（外部需自行做 isLoading / hasMore / 冷却去重）
    var onReachBottom: (() -> Void)? = nil
    /// 数据内容变化但数量不变时（如当前项高亮切换），递增该值强制刷新可见 Cell
    var reloadToken: Int = 0
    /// SwiftUI 侧确认的容器宽度（面板固定宽），避免初帧 clipView 宽度为 0 导致空布局
    var layoutWidth: CGFloat = AuthorSheetCardMetrics.fallbackLayoutWidth

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self

        if scrollView.isHidden {
            scrollView.isHidden = false
        }

        // 注意：reloadData / performBatchUpdates 延迟到下一 run loop 执行，
        // lastItemCount 在延迟块内才更新，确保后续 updateNSView 能正确触发 reload。
        let newCount = itemCount()
        if newCount != coordinator.lastItemCount {
            let oldCount = coordinator.lastItemCount
            if newCount > oldCount, oldCount > 0 {
                coordinator.performBatchUpdates(insertedCount: newCount - oldCount, oldCount: oldCount)
            } else {
                coordinator.reloadData()
            }
        } else if reloadToken != coordinator.lastReloadToken {
            coordinator.refreshVisibleItems()
        }
        coordinator.lastReloadToken = reloadToken

        coordinator.scheduleLayoutDocument()
    }

    func makeCoordinator() -> AuthorSheetGridCoordinator {
        AuthorSheetGridCoordinator(self)
    }
}
