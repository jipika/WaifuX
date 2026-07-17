import AppKit
import SwiftUI

/// 占位 scroller：不绘制、不响应命中，避免系统 overlay 滚动条闪现。
@MainActor
private final class ExploreGridInvisibleScroller: NSScroller {
    override func draw(_ dirtyRect: NSRect) {}
    override class var isCompatibleWithOverlayScrollers: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var usableParts: NSScroller.UsableParts {
        get { .noScrollerParts }
        set {}
    }
}

@MainActor
private final class ExploreGridScrollView: NSScrollView {
    weak var gridCoordinator: ExploreGridCoordinator?
    var allowsGridScrolling = true
    private var lastReportedSize: CGSize = .zero

    override func scrollWheel(with event: NSEvent) {
        guard allowsGridScrolling else {
            nextResponder?.scrollWheel(with: event)
            return
        }

        // 两阶段滚动：
        // 1) header 未收完时，向下滚只收 header，网格锁在顶部（避免“一起滚”的错位感）
        // 2) header 已收完才进入网格内部滚动；在顶部向上滚则先展开 header
        if let coordinator = gridCoordinator,
           coordinator.handleHeaderPhaseScrollWheel(event) {
            return
        }

        gridCoordinator?.scrollingWillBeginOrContinue()
        super.scrollWheel(with: event)
    }

    override func tile() {
        super.tile()
        // tile 后系统可能又挂回 scroller；强制关掉并清掉占用宽度。
        hasVerticalScroller = false
        hasHorizontalScroller = false
        verticalScroller?.isHidden = true
        horizontalScroller?.isHidden = true
        verticalScroller?.alphaValue = 0
        horizontalScroller?.alphaValue = 0
    }

    override func layout() {
        super.layout()
        reportViewportIfNeeded()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        lastReportedSize = .zero
        DispatchQueue.main.async { [weak self] in
            self?.gridCoordinator?.viewportDidResize()
            if self?.isHiddenOrHasHiddenAncestor == false {
                self?.gridCoordinator?.visibilityDidChange(isVisible: true)
            }
        }
    }

    override func viewDidHide() {
        super.viewDidHide()
        gridCoordinator?.visibilityDidChange(isVisible: false)
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        DispatchQueue.main.async { [weak self] in
            self?.gridCoordinator?.visibilityDidChange(isVisible: true)
        }
    }

    private func reportViewportIfNeeded() {
        let size = contentView.bounds.size
        guard size.width > 1, size.height > 1 else { return }
        guard abs(size.width - lastReportedSize.width) > 0.5 ||
              abs(size.height - lastReportedSize.height) > 0.5 else { return }

        lastReportedSize = size
        DispatchQueue.main.async { [weak self] in
            self?.gridCoordinator?.viewportDidResize()
        }
    }
}

/// NSCollectionView 数据源/代理协调器
/// 管理数据更新、滚动检测、加载更多
@MainActor
final class ExploreGridCoordinator: NSObject {

    var parent: ExploreGridContainer
    let collectionView: NSCollectionView
    let scrollView: NSScrollView
    private let layout: ExploreGridCollectionViewLayout

    var lastItemCount: Int = 0
    var lastScrollToTopToken: Int = 0
    var lastRestoreScrollToken: Int = 0
    var lastReloadToken: Int = 0
    var lastLayoutRefreshToken: Int = 0
    var lastVisibilityRefreshToken: Int = 0
    var lastExternalScrollDownToken: Int = 0
    private var scrollDebounceWorkItem: DispatchWorkItem?
    private var restoreHoverWorkItem: DispatchWorkItem?
    private var lastLaidOutWidth: CGFloat = 0
    private var isLayoutingDocument = false
    /// 防止 layoutDocument() 执行期间 clipViewBoundsDidChange 再次触发新的 layoutDocument()
    private var isUpdatingDocumentLayout = false
    /// 合并延迟的 layoutDocument 调用
    private var pendingLayoutDocument: DispatchWorkItem?
    /// 延迟的 reloadData 调用
    private var pendingReload: DispatchWorkItem?
    /// 延迟的 batch updates 调用
    private var pendingBatchUpdate: DispatchWorkItem?
    /// SwiftUI 更新后主动补一次 AppKit 布局。切换页面/调整窗口时，clipView 的 bounds 通知
    /// 有时不会在可见前触发，导致 collection view 停在空布局，直到用户滚动才刷新。
    private var pendingViewUpdateLayout: DispatchWorkItem?
    private var pendingVisibilityRefreshWorkItems: [DispatchWorkItem] = []
    private var pendingRestoreScrollOffset: CGFloat?
    private var registeredCellClassIdentifier: ObjectIdentifier?
    private var isHoverInteractionEnabled = true
    /// 仅当可见 item 索引范围变化时再回调，减轻 SwiftUI 侧与预取链路的无效触发
    private var lastReportedVisibleItemRange: (min: Int, max: Int)?
    /// 滚动偏移只在足够变化或跨越 UI 阈值时回调 SwiftUI，避免滚动中持续发布状态
    private var lastReportedScrollOffset: CGFloat?
    /// 细粒度 offset（用于可折叠 header 1:1 跟滚），与粗粒度 UI 阈值分离。
    private var lastFineReportedScrollOffset: CGFloat?
    private var lastReportedContentHeight: CGFloat = 0
    private var pendingFineScrollOffsetReport: DispatchWorkItem?
    /// 本地缓存的 header 剩余/已收高度。滚轮事件可能在 SwiftUI update 前连发，
    /// 必须立刻本地扣减，否则会把后续本该进入网格的滚动吞掉。
    private var localHeaderRemaining: CGFloat = 0
    private var localHeaderConsumed: CGFloat = 0

    init(_ parent: ExploreGridContainer) {
        self.parent = parent
        self.layout = ExploreGridCollectionViewLayout()
        self.layout.hoverExpansionAllowance = parent.hoverExpansionAllowance
        self.layout.preferredColumnCount = parent.gridColumnCount
        if let insets = parent.contentInsets {
            self.layout.contentInsets = insets
        }

        // 配置 NSCollectionView
        self.collectionView = NSCollectionView()
        collectionView.wantsLayer = true
        collectionView.collectionViewLayout = layout
        collectionView.backgroundColors = [.clear]
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        collectionView.allowsEmptySelection = true

        // 注册 Cell
        // 配置 NSScrollView
        self.scrollView = ExploreGridScrollView()
        scrollView.wantsLayer = true
        scrollView.documentView = collectionView
        // 彻底隐藏滚动条：自定义 InvisibleScroller + 关闭 scroller 开关
        let invisibleV = ExploreGridInvisibleScroller()
        invisibleV.scrollerStyle = .overlay
        let invisibleH = ExploreGridInvisibleScroller()
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
        scrollView.contentView.postsBoundsChangedNotifications = true

        super.init()

        registerCellClassIfNeeded(parent.cellClass)

        (scrollView as? ExploreGridScrollView)?.gridCoordinator = self
        configureScrollingMode(parent.allowsScrolling)

        collectionView.dataSource = self
        collectionView.delegate = self
        layout.delegate = self

        // 监听滚动事件
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
        // 显式 cancel 所有 pending work item，避免 view 频繁重建时遗留延后副作用。
        // 仅靠闭包内 [weak self] 的 no-op 不够——work item 仍会被主队列调度执行一次空 block，
        // 且部分 work item 通过闭包捕获了 parent / scrollView 等强引用。
        // 注：Coordinator 是 @MainActor 的，由 SwiftUI 主线程在 makeCoordinator/拆 view 时持有/释放，
        // 因此 deinit 实际运行在主线程。assumeIsolated 是为了让 Swift 6 strict concurrency
        // 允许从 nonisolated deinit 访问主 actor 隔离的 DispatchWorkItem 属性。
        MainActor.assumeIsolated {
            scrollDebounceWorkItem?.cancel()
            restoreHoverWorkItem?.cancel()
            pendingLayoutDocument?.cancel()
            pendingReload?.cancel()
            pendingBatchUpdate?.cancel()
            pendingViewUpdateLayout?.cancel()
            pendingFineScrollOffsetReport?.cancel()
            pendingVisibilityRefreshWorkItems.forEach { $0.cancel() }
            pendingVisibilityRefreshWorkItems.removeAll()
        }
    }

    // MARK: - 滚动处理

    func scrollingWillBeginOrContinue() {
        scrollDebounceWorkItem?.cancel()
        restoreHoverWorkItem?.cancel()
        setHoverInteractionEnabledForVisibleItems(false)
    }

    /// 从 parent 同步 header 阶段状态（SwiftUI update 时调用）。
    func syncHeaderCollapseStateFromParent() {
        localHeaderRemaining = max(0, parent.headerCollapseRemaining)
        localHeaderConsumed = max(0, parent.headerCollapseConsumed)
    }

    /// 处理 header 收起/展开阶段的滚轮。返回 true 表示已消费事件，网格不应再滚。
    @discardableResult
    func handleHeaderPhaseScrollWheel(_ event: NSEvent) -> Bool {
        guard parent.allowsScrolling else { return false }
        guard parent.onHeaderCollapseDelta != nil else { return false }

        let rawDelta = event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY
            : event.deltaY * 16
        // 浏览向下（看更下面的内容）：scrollDown > 0
        // macOS 上手指上滑/滚轮下滚时 scrollingDeltaY 通常为负
        let scrollDown = -rawDelta
        // 本地缓存是两次 SwiftUI update 之间的权威状态（连发滚轮立刻扣减）
        let rem = max(0, localHeaderRemaining)
        let cons = max(0, localHeaderConsumed)
        let atTop = scrollView.contentView.bounds.origin.y <= 1.0

        if scrollDown > 0.5, rem > 0.5 {
            // 阶段 1：先收 header，网格强制锁顶
            let apply = min(rem, scrollDown)
            localHeaderRemaining = max(0, rem - apply)
            localHeaderConsumed = cons + apply
            lockGridToTop()
            parent.onHeaderCollapseDelta?(apply)
            scrollingWillBeginOrContinue()
            // 同一次事件把 header 收完后还有余量：手动推进网格 offset，
            // 不能 super.scrollWheel(完整 event)，否则会按整段 delta 跳。
            let leftover = scrollDown - apply
            if leftover > 0.5, localHeaderRemaining <= 0.5 {
                applyGridScrollDelta(leftover)
            }
            scheduleHoverRestoreAfterScrollWheel()
            return true
        }

        if scrollDown < -0.5, atTop, cons > 0.5 {
            // 阶段 0 反向：网格已在顶部，向上滚先展开 header
            let expand = min(cons, -scrollDown)
            localHeaderConsumed = max(0, cons - expand)
            localHeaderRemaining = rem + expand
            lockGridToTop()
            parent.onHeaderCollapseDelta?(-expand)
            scrollingWillBeginOrContinue()
            scheduleHoverRestoreAfterScrollWheel()
            return true
        }

        // header 未收完时禁止网格被其他输入带离顶部（保险）
        if rem > 0.5, !atTop {
            lockGridToTop()
        }
        return false
    }

    private func lockGridToTop() {
        let origin = NSPoint(x: 0, y: 0)
        guard abs(scrollView.contentView.bounds.origin.y) > 0.5 else { return }
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        lastReportedScrollOffset = 0
        lastFineReportedScrollOffset = 0
    }

    /// header 阶段结束后把同一次滚轮的余量应用到网格（单位：pt，向下为正）。
    private func applyGridScrollDelta(_ deltaDown: CGFloat) {
        guard deltaDown > 0.5 else { return }
        let visibleH = scrollView.contentView.bounds.height
        let contentH = max(collectionView.frame.height, layout.collectionViewContentSize.height)
        let maxY = max(0, contentH - visibleH)
        let current = scrollView.contentView.bounds.origin.y
        let newY = min(maxY, max(0, current + deltaDown))
        guard abs(newY - current) > 0.5 else { return }
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: newY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        scheduleFineScrollOffsetReport(newY)
    }

    /// header 区域滚轮在 header 已收完后推送的外部滚动。
    func applyExternalScrollDown(_ deltaDown: CGFloat) {
        applyGridScrollDelta(deltaDown)
        scrollingWillBeginOrContinue()
        scheduleHoverRestoreAfterScrollWheel()
    }

    func scheduleHoverRestoreAfterScrollWheel() {
        scrollDebounceWorkItem?.cancel()
        // ⚠️ 必须 [weak self]：这里把 workItem 存到 self.scrollDebounceWorkItem，
        // 若闭包强捕获 self（旧版 `let coordinator = self` 的写法）会形成
        // self → workItem → self 的临时循环引用。即便后续 cancel + 替换，
        // 老 workItem 仍要等主队列把待执行项收掉才能释放，会延迟 coordinator 的 deinit。
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.handleScrollUpdate()
            self.scheduleHoverRestore()
        }
        scrollDebounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10, execute: workItem)
    }

    @objc private func scrollViewDidScroll(_ notification: Notification) {
        scrollingWillBeginOrContinue()
        scheduleHoverRestoreAfterScrollWheel()
    }

    @objc private func scrollViewDidEndScroll(_ notification: Notification) {
        scrollDebounceWorkItem?.cancel()
        handleScrollUpdate()
        scheduleHoverRestore()
    }

    @objc private func clipViewBoundsDidChange(_ notification: Notification) {
        guard !isUpdatingDocumentLayout else { return }
        let bounds = scrollView.contentView.bounds
        let width = bounds.width
        if width > 0, abs(width - lastLaidOutWidth) > 0.5 {
            // 延迟布局，避免在窗口 display cycle 内触发布局循环
            scheduleDeferredLayout()
        }
        // header 收起阶段禁止网格离开顶部（键盘/惯性等非 scrollWheel 路径兜底）
        if parent.allowsScrolling,
           parent.headerCollapseRemaining > 0.5,
           bounds.origin.y > 1 {
            lockGridToTop()
            return
        }
        // live scroll 时 bounds.origin.y 连续变化：细粒度上报 offset。
        if parent.allowsScrolling {
            scheduleFineScrollOffsetReport(bounds.origin.y)
        }
    }

    private func handleScrollUpdate() {
        let visibleIndexPaths = Set(collectionView.indexPathsForVisibleItems())
        let offset = scrollView.contentView.bounds.origin.y
        let shouldReachBottom = isNearBottom()
        let indices = visibleIndexPaths.map(\.item)
        let minVisible = indices.min() ?? 0
        let maxVisible = indices.max() ?? 0
        let visibleRangeChanged: Bool
        if let last = lastReportedVisibleItemRange {
            visibleRangeChanged = last.min != minVisible || last.max != maxVisible
        } else {
            visibleRangeChanged = true
        }
        if visibleRangeChanged {
            lastReportedVisibleItemRange = (minVisible, maxVisible)
        }
        // 粗粒度：回顶按钮等 UI 阈值
        let shouldReportCoarseScrollOffset = shouldReportCoarseScrollOffset(offset)
        if shouldReportCoarseScrollOffset {
            lastReportedScrollOffset = offset
        }
        // 细粒度：header 折叠跟滚（与 coarse 分离，避免被 96pt 阈值拖成瞬变）
        let shouldReportFineScrollOffset = shouldReportFineScrollOffset(offset)
        if shouldReportFineScrollOffset {
            lastFineReportedScrollOffset = offset
        }

        // 避免在 AppKit 布局/滚动通知同步栈内触发 SwiftUI 状态发布。
        let parent = parent
        DispatchQueue.main.async {
            if visibleRangeChanged {
                parent.onVisibleItemsChange?(visibleIndexPaths)
            }
            if shouldReportFineScrollOffset || shouldReportCoarseScrollOffset {
                parent.onScrollOffsetChange?(offset)
            }
            if parent.allowsScrolling && shouldReachBottom {
                parent.onReachBottom()
            }
        }
    }

    /// 细粒度 offset 上报：约每 2pt 一次，合并到下一 runloop，避免同步栈里狂刷 SwiftUI。
    private func scheduleFineScrollOffsetReport(_ offset: CGFloat) {
        guard shouldReportFineScrollOffset(offset) else { return }
        pendingFineScrollOffsetReport?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingFineScrollOffsetReport = nil
            let current = self.scrollView.contentView.bounds.origin.y
            guard self.shouldReportFineScrollOffset(current) else { return }
            self.lastFineReportedScrollOffset = current
            // 同步粗粒度缓存，避免随后 coarse 路径重复跳变
            if self.shouldReportCoarseScrollOffset(current) {
                self.lastReportedScrollOffset = current
            }
            let parent = self.parent
            parent.onScrollOffsetChange?(current)
        }
        pendingFineScrollOffsetReport = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    private func shouldReportFineScrollOffset(_ offset: CGFloat) -> Bool {
        guard let last = lastFineReportedScrollOffset else { return true }
        if offset <= 0.5, last > 0.5 { return true }
        return abs(offset - last) >= 2
    }

    private func shouldReportCoarseScrollOffset(_ offset: CGFloat) -> Bool {
        guard let lastOffset = lastReportedScrollOffset else { return true }
        let threshold: CGFloat = 300
        if (lastOffset > threshold) != (offset > threshold) {
            return true
        }
        if offset <= 1, lastOffset > 1 {
            return true
        }
        return abs(offset - lastOffset) > 96
    }

    private func isNearBottom() -> Bool {
        let contentHeight = max(collectionView.frame.height, layout.collectionViewContentSize.height)
        let visibleRect = scrollView.contentView.bounds
        let scrollPos = visibleRect.origin.y
        let distanceToBottom = contentHeight - (scrollPos + visibleRect.height)

        return distanceToBottom < 800
    }

    // MARK: - 数据更新

    func reloadData() {
        // 延迟 collectionView.reloadData()，避免在窗口 display cycle 内同步触发布局循环。
        // collectionView.reloadData() 会触发内部布局，如果在 _layoutViewTree 期间执行，
        // 会导致 _postWindowNeedsLayout 崩溃。
        pendingReload?.cancel()
        pendingBatchUpdate?.cancel()
        let itemCount = parent.itemCount()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingReload = nil
            self.lastItemCount = itemCount
            self.lastReportedVisibleItemRange = nil
            self.lastReportedScrollOffset = nil
            self.layout.hoverExpansionAllowance = self.parent.hoverExpansionAllowance
            self.layout.preferredColumnCount = self.parent.gridColumnCount
            // reloadData 会完全重建布局，不需要手动 invalidateLayout
            self.collectionView.reloadData()
            self.layoutDocument()
            self.applyPendingRestoreScrollOffsetIfNeeded()
        }
        pendingReload = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    func refreshVisibleItems() {
        pendingReload?.cancel()
        pendingBatchUpdate?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lastReportedVisibleItemRange = nil
            self.reconfigureVisibleItems()
            self.handleScrollUpdate()
        }
        DispatchQueue.main.async(execute: workItem)
    }

    func registerCellClassIfNeeded(_ cellClass: ExploreGridItem.Type) {
        let identifier = ObjectIdentifier(cellClass)
        guard registeredCellClassIdentifier != identifier else { return }
        registeredCellClassIdentifier = identifier
        collectionView.register(
            cellClass,
            forItemWithIdentifier: ExploreGridItem.reuseIdentifier
        )
    }

    func performBatchUpdates(insertedCount: Int, oldCount: Int) {
        // 延迟 batch updates，避免在窗口 display cycle 内同步触发布局循环
        pendingReload?.cancel()
        pendingBatchUpdate?.cancel()
        let newTotal = oldCount + insertedCount
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingBatchUpdate = nil
            self.lastItemCount = newTotal
            let currentCount = self.collectionView.numberOfItems(inSection: 0)

            guard newTotal > currentCount else {
                self.lastReportedVisibleItemRange = nil
                self.layout.hoverExpansionAllowance = self.parent.hoverExpansionAllowance
                self.layout.preferredColumnCount = self.parent.gridColumnCount
                // reloadData 会完全重建布局，不需要手动 invalidateLayout
                self.collectionView.reloadData()
                self.layoutDocument()
                return
            }

            let newIndexPaths = (currentCount..<newTotal).map {
                IndexPath(item: $0, section: 0)
            }

            self.layout.hoverExpansionAllowance = self.parent.hoverExpansionAllowance
            self.layout.preferredColumnCount = self.parent.gridColumnCount
            // performBatchUpdates 内部会自动重新计算布局，
            // 在 insertItems 之前 invalidateLayout 会清除旧布局缓存，
            // 导致 NSCollectionView 无法计算插入动画的起点/终点，触发崩溃
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.collectionView.performBatchUpdates {
                    self.collectionView.insertItems(at: Set(newIndexPaths))
                } completionHandler: { [weak self] _ in
                    self?.layoutDocument()
                    self?.applyPendingRestoreScrollOffsetIfNeeded()
                }
                CATransaction.commit()
            }
        }
        pendingBatchUpdate = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    func scrollToTop() {
        lastReportedVisibleItemRange = nil
        lastReportedScrollOffset = 0
        lastFineReportedScrollOffset = 0
        pendingFineScrollOffsetReport?.cancel()
        pendingFineScrollOffsetReport = nil
        let origin = NSPoint(x: 0, y: 0)
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        DispatchQueue.main.async { [weak self] in
            self?.parent.onScrollOffsetChange?(0)
        }
    }

    func restoreScrollOffset(_ offset: CGFloat) {
        pendingRestoreScrollOffset = max(0, offset)
        DispatchQueue.main.async { [weak self] in
            self?.applyPendingRestoreScrollOffsetIfNeeded()
        }
        DispatchQueue.main.async { [weak self] in
            self?.applyPendingRestoreScrollOffsetIfNeeded()
        }
    }

    private func applyRestoredScrollOffset(_ targetOffset: CGFloat) {
        layoutDocument()
        let visibleBounds = scrollView.contentView.bounds
        let maxOriginY = max(0, collectionView.frame.height - visibleBounds.height)
        let clampedY = min(max(0, targetOffset), maxOriginY)
        let origin = NSPoint(x: 0, y: clampedY)
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        lastReportedVisibleItemRange = nil
        lastReportedScrollOffset = clampedY
        handleScrollUpdate()
    }

    private func applyPendingRestoreScrollOffsetIfNeeded() {
        guard let targetOffset = pendingRestoreScrollOffset else { return }
        pendingRestoreScrollOffset = nil
        applyRestoredScrollOffset(targetOffset)
    }

    private func targetVisibleIndexPaths() -> Set<IndexPath> {
        var targetIndexPaths = Set(collectionView.indexPathsForVisibleItems())
        guard let layout = collectionView.collectionViewLayout else { return targetIndexPaths }

        // 切换 tab 返回时，NSCollectionView 偶尔只保留下半部分现存 item，
        // 这时 indexPathsForVisibleItems() 会变成“不完整但非空”的脏状态。
        // 不能只信任当前已挂载的 item，必须结合当前 viewport 的 layout attributes
        // 重新推导整块可见区应当存在的 indexPath，才能把顶部缺失的 cell 补回来。
        let visibleRectInCollection = collectionView.convert(
            scrollView.contentView.bounds.insetBy(dx: 0, dy: -160),
            from: scrollView.contentView
        )
        let layoutIndexPaths = layout.layoutAttributesForElements(in: visibleRectInCollection)
            .compactMap(\.indexPath)
        targetIndexPaths.formUnion(layoutIndexPaths)
        return targetIndexPaths
    }

    private func reconfigureVisibleItems() {
        let visibleIndexPaths = targetVisibleIndexPaths()
        guard !visibleIndexPaths.isEmpty else { return }

        var missingIndexPaths = Set<IndexPath>()
        for indexPath in visibleIndexPaths {
            guard let item = collectionView.item(at: indexPath) as? ExploreGridItem else {
                missingIndexPaths.insert(indexPath)
                continue
            }

            item.hoverExpansionAllowance = parent.hoverExpansionAllowance
            item.setHoverInteractionEnabled(isHoverInteractionEnabled)
            parent.configureCell(item, indexPath.item)
        }

        if !missingIndexPaths.isEmpty {
            collectionView.reloadItems(at: missingIndexPaths)
        }
    }

    func visibilityDidChange(isVisible: Bool) {
        cancelPendingVisibilityRefreshes()

        guard isVisible else {
            scrollDebounceWorkItem?.cancel()
            restoreHoverWorkItem?.cancel()
            setHoverInteractionEnabledForVisibleItems(false)
            return
        }

        setHoverInteractionEnabledForVisibleItems(true)
        scheduleNonDestructiveVisibilityRestore()
    }

    func viewportDidResize() {
        lastLaidOutWidth = 0
        layout.hoverExpansionAllowance = parent.hoverExpansionAllowance
        layout.preferredColumnCount = parent.gridColumnCount
        if let insets = parent.contentInsets {
            layout.contentInsets = insets
        }
        syncHoverAllowanceForVisibleItems()
        layout.invalidateLayout()
        scheduleViewUpdateLayout()
    }

    func configureScrollingMode(_ allowsScrolling: Bool) {
        guard let scrollView = scrollView as? ExploreGridScrollView else { return }
        scrollView.allowsGridScrolling = allowsScrolling
        self.scrollView.verticalScrollElasticity = allowsScrolling ? .allowed : .none
        // 无论是否允许滚动，都隐藏滚动条（探索页不需要可见 scroller）。
        self.scrollView.hasVerticalScroller = false
        self.scrollView.hasHorizontalScroller = false
        self.scrollView.verticalScroller = nil
        self.scrollView.horizontalScroller = nil

        // `allowsScrolling=false` 时本 NSScrollView 不内部滚动（外层 SwiftUI ScrollView 总滚动），
        // 默认 NSClipView.masksToBounds=true 会把 cell hover 1.02 缩放在网格四角溢出的部分裁掉。
        // 在非滚动模式下解除该裁切（cell 自带 zPosition=100 抬层，不会被邻居/父级遮挡）。
        // 仍滚动模式下保持默认裁切，避免滚动出可视区的内容溢出可见。
        applyClipMaskingForScrollingMode(allowsScrolling)
    }

    /// 根据是否允许滚动调整 clipView / collectionView 层的裁切。
    /// 仅在非滚动模式下解除裁切，确保 hover 缩放在网格边缘不被切。
    private func applyClipMaskingForScrollingMode(_ allowsScrolling: Bool) {
        scrollView.contentView.wantsLayer = true
        scrollView.contentView.layer?.masksToBounds = allowsScrolling
        collectionView.layer?.masksToBounds = allowsScrolling
    }

    /// 父端 `contentInsets` 变化时由 container 触发，写回 layout 并强制重排。
    /// 写 nil 时保持现有值不变（container 不会调本方法），由 container 侧的 equality 判断决定。
    func applyContentInsetsIfNeeded() {
        guard let insets = parent.contentInsets else { return }
        layout.contentInsets = insets
        layout.invalidateLayout()
        scheduleViewUpdateLayout()
    }

    func forceVisibilityRefresh() {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.parent.isVisible else { return }

            let expectedCount = self.parent.itemCount()
            let currentCount = self.collectionView.numberOfItems(inSection: 0)

            self.lastReportedVisibleItemRange = nil
            self.lastReportedScrollOffset = nil
            self.lastLaidOutWidth = 0
            self.layout.hoverExpansionAllowance = self.parent.hoverExpansionAllowance
            self.layout.preferredColumnCount = self.parent.gridColumnCount

            if expectedCount != currentCount {
                // 数据数量真变化时才整表 reloadData。
                self.lastItemCount = expectedCount
                self.layout.invalidateLayout()
                self.collectionView.reloadData()
            } else {
                // 数量未变 → 只重配可视 cell，保留图片，不重启下载。
                // 历史上这里曾用双层 reloadData 作"切回 tab 双保险"，会强制重建可视 cell
                // 并重启 Kingfisher 任务，触发不必要的下载和解码——已由
                // scheduleNonDestructiveVisibilityRestore() 路径覆盖。
                self.layout.invalidateLayout()
                self.reconfigureVisibleItems()
            }

            self.collectionView.needsLayout = true
            self.collectionView.layoutSubtreeIfNeeded()
            self.layoutDocument()
            self.scrollView.reflectScrolledClipView(self.scrollView.contentView)
            self.handleScrollUpdate()
        }
        pendingVisibilityRefreshWorkItems.append(workItem)
        DispatchQueue.main.async(execute: workItem)
    }

    /// 延迟合并布局调用，避免在窗口 display cycle 内重复触发。
    private func scheduleDeferredLayout() {
        pendingLayoutDocument?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.pendingLayoutDocument = nil
            self?.layoutDocument()
        }
        pendingLayoutDocument = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    func scheduleViewUpdateLayout() {
        pendingViewUpdateLayout?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingViewUpdateLayout = nil
            self.layout.hoverExpansionAllowance = self.parent.hoverExpansionAllowance
            self.layout.preferredColumnCount = self.parent.gridColumnCount
            self.layout.invalidateLayout()
            self.syncHoverAllowanceForVisibleItems()
            self.layoutDocument()
            self.scrollView.reflectScrolledClipView(self.scrollView.contentView)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.layoutDocument()
                self.scrollView.reflectScrolledClipView(self.scrollView.contentView)
            }
        }
        pendingViewUpdateLayout = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    private func scheduleNonDestructiveVisibilityRestore() {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.parent.isVisible else { return }

            self.setHoverInteractionEnabledForVisibleItems(true)
            self.layout.hoverExpansionAllowance = self.parent.hoverExpansionAllowance
            self.layout.preferredColumnCount = self.parent.gridColumnCount
            self.syncHoverAllowanceForVisibleItems()
            // isHidden 切换时 AppKit 会跳过 NSCollectionView 的 layout pass，
            // 导致上半部分 items 丢失 prepare 状态。必须显式 invalidateLayout
            // + layoutSubtreeIfNeeded 强制重新 prepare，否则 layoutDocument()
            // 内部的条件判断（widthChanged 等）可能全为 false，跳过重建。
            self.lastLaidOutWidth = 0
            self.layout.invalidateLayout()
            self.collectionView.needsLayout = true
            self.collectionView.layoutSubtreeIfNeeded()
            self.layoutDocument()
            self.scrollView.reflectScrolledClipView(self.scrollView.contentView)

            // 切页恢复时不要整表 reloadData()。
            // 整表 reload 会先拆掉当前可视 item，再等下一轮布局重建，
            // 用户就会看到切 tab 的瞬间空白。这里仅重配当前可视 items，
            // 既能恢复顶部 cell 的内容/layer，又不会把整块网格清空。
            self.reconfigureVisibleItems()

            DispatchQueue.main.async { [weak self] in
                guard let self, self.parent.isVisible else { return }
                self.setHoverInteractionEnabledForVisibleItems(true)
                self.collectionView.needsLayout = true
                self.collectionView.layoutSubtreeIfNeeded()
                self.layoutDocument()
                self.reconfigureVisibleItems()
                self.scrollView.reflectScrolledClipView(self.scrollView.contentView)
                self.handleScrollUpdate()
                self.restoreHoverForCurrentMouseLocation()
            }
        }
        pendingVisibilityRefreshWorkItems.append(workItem)
        DispatchQueue.main.async(execute: workItem)
    }

    private func cancelPendingVisibilityRefreshes() {
        pendingVisibilityRefreshWorkItems.forEach { $0.cancel() }
        pendingVisibilityRefreshWorkItems.removeAll()
    }

    private func setHoverInteractionEnabledForVisibleItems(_ enabled: Bool) {
        guard isHoverInteractionEnabled != enabled else { return }
        isHoverInteractionEnabled = enabled
        for item in collectionView.visibleItems() {
            (item as? ExploreGridItem)?.setHoverInteractionEnabled(enabled)
        }
    }

    private func syncHoverAllowanceForVisibleItems() {
        let allowance = parent.hoverExpansionAllowance
        for item in collectionView.visibleItems() {
            (item as? ExploreGridItem)?.hoverExpansionAllowance = allowance
        }
    }

    private func scheduleHoverRestore() {
        restoreHoverWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.restoreHoverWorkItem = nil
            self.setHoverInteractionEnabledForVisibleItems(true)
            self.restoreHoverForCurrentMouseLocation()
        }
        restoreHoverWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: workItem)
    }

    private func restoreHoverForCurrentMouseLocation() {
        let visibleItems = collectionView.visibleItems().compactMap { $0 as? ExploreGridItem }
        for item in visibleItems {
            item.clearHover(animated: false)
        }

        for item in visibleItems {
            if item.updateHoverStateFromCurrentMouseLocation(animated: false) {
                break
            }
        }
    }

    func layoutDocument() {
        guard !isLayoutingDocument else { return }
        isLayoutingDocument = true
        isUpdatingDocumentLayout = true
        defer {
            isLayoutingDocument = false
            isUpdatingDocumentLayout = false
        }

        let requestedWidth = max(parent.layoutWidth, scrollView.contentView.bounds.width)
        let width = max(1, requestedWidth)
        let widthChanged = abs(width - lastLaidOutWidth) > 0.5
        lastLaidOutWidth = width

        // NSCollectionViewLayout 依赖 collectionView.bounds.width 计算列数与内容高度。
        // 初次布局时 collectionView 仍可能是 .zero，必须先给它正确宽度，再读取 contentSize。
        let provisionalGridHeight = max(1, collectionView.frame.height, layout.collectionViewContentSize.height)
        let provisionalCollectionFrame = CGRect(x: 0, y: 0, width: width, height: provisionalGridHeight)
        if collectionView.frame != provisionalCollectionFrame {
            collectionView.frame = provisionalCollectionFrame
        }

        let expectedItemCount = parent.itemCount()
        let layoutNeedsRebuild = expectedItemCount > 0 && layout.cachedItemCount != expectedItemCount
        let collectionWidthMismatch = abs(collectionView.bounds.width - width) > 0.5
        let preparedWidthMismatch = abs(layout.preparedWidth - width) > 0.5

        // 宽度变化或缓存缺失时让 layout 失效；否则 collection view 可能保留空布局，
        // 表现为切回页面/调整宽度后空白，直到滚动事件触发下一次布局。
        if widthChanged || layoutNeedsRebuild || collectionWidthMismatch || preparedWidthMismatch {
            layout.hoverExpansionAllowance = parent.hoverExpansionAllowance
            layout.preferredColumnCount = parent.gridColumnCount
            layout.invalidateLayout()
            collectionView.needsLayout = true
            collectionView.layoutSubtreeIfNeeded()
        }

        // 读取内容高度；此时 collectionView 已有正确宽度，contentSize 才可靠。
        let gridHeight = max(1, layout.collectionViewContentSize.height)
        let newCollectionFrame = CGRect(x: 0, y: 0, width: width, height: gridHeight)

        // 只在 frame 真正变化时才设置，避免无意义地标记 needsLayout
        if collectionView.frame != newCollectionFrame {
            collectionView.frame = newCollectionFrame
        }

        reportContentHeightIfNeeded(newCollectionFrame.height)

        let visibleBounds = scrollView.contentView.bounds
        let maxOriginY = max(0, newCollectionFrame.height - visibleBounds.height)
        let clampedOrigin = NSPoint(
            x: 0,
            y: min(max(visibleBounds.origin.y, 0), maxOriginY)
        )
        if abs(clampedOrigin.y - visibleBounds.origin.y) > 0.5 || abs(visibleBounds.origin.x) > 0.5 {
            scrollView.contentView.scroll(to: clampedOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    private func reportContentHeightIfNeeded(_ height: CGFloat) {
        let normalizedHeight = max(1, ceil(height))
        guard abs(normalizedHeight - lastReportedContentHeight) > 0.5 else { return }
        lastReportedContentHeight = normalizedHeight
        guard let onContentHeightChange = parent.onContentHeightChange else { return }
        DispatchQueue.main.async {
            onContentHeightChange(normalizedHeight)
        }
    }
}

// MARK: - NSCollectionViewDataSource

extension ExploreGridCoordinator: NSCollectionViewDataSource {

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
            withIdentifier: ExploreGridItem.reuseIdentifier,
            for: indexPath
        ) as! ExploreGridItem

        item.hoverExpansionAllowance = parent.hoverExpansionAllowance
        item.setHoverInteractionEnabled(isHoverInteractionEnabled)
        parent.configureCell(item, indexPath.item)
        return item
    }
}

// MARK: - NSCollectionViewDelegate

extension ExploreGridCoordinator: NSCollectionViewDelegate {

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let indexPath = indexPaths.first else { return }
        parent.onSelect?(indexPath.item)
        collectionView.deselectItems(at: indexPaths)
    }
}

// MARK: - ExploreGridCollectionViewLayoutDelegate

extension ExploreGridCoordinator: ExploreGridCollectionViewLayoutDelegate {

    func collectionView(_ collectionView: NSCollectionView, aspectRatioForItemAt indexPath: IndexPath) -> CGFloat {
        parent.aspectRatio(indexPath.item)
    }
}
