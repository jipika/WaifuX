import SwiftUI
import AppKit

/// 通用 NSCollectionView 桥接容器
/// 将 NSCollectionView + Cell 复用接入 SwiftUI，替换 LazyVGrid 实现 60fps 滚动
struct ExploreGridContainer: NSViewRepresentable {
    /// 数据项总数
    var itemCount: () -> Int
    /// 指定索引的宽高比（宽/高）
    var aspectRatio: (Int) -> CGFloat
    /// 配置 Cell（设置图片、标签、文字等）
    var configureCell: (ExploreGridItem, Int) -> Void
    /// Cell 类型（各页面自定义子类）
    var cellClass: ExploreGridItem.Type
    /// 点击回调
    var onSelect: ((Int) -> Void)?
    /// 可见区域变化回调
    var onVisibleItemsChange: ((Set<IndexPath>) -> Void)?
    /// 滚动偏移回调，用于 SwiftUI 外层显示返回顶部等轻量状态。
    var onScrollOffsetChange: ((CGFloat) -> Void)?
    /// 触底加载回调
    var onReachBottom: () -> Void
    /// 外部递增该值时滚回顶部。
    var scrollToTopToken: Int = 0
    /// 外部递增该值时恢复到指定滚动偏移。用于重建 NSCollectionView 后无跳动恢复原阅读位置。
    var restoreScrollToken: Int = 0
    var restoreScrollOffset: CGFloat = 0
    /// 数据内容变化但数量不变时，递增该值强制刷新可见 Cell。
    var reloadToken: Int = 0
    /// 外部视图重新变为可见时递增，强制刷新 AppKit header 与布局。
    var layoutRefreshToken: Int = 0
    /// 页面真正出现在窗口后递增，触发一次更强的 AppKit 刷新。
    var visibilityRefreshToken: Int = 0
    /// 当 false 时，网格只负责内容渲染与高度汇报，外层页面接管整体滚动。
    var allowsScrolling: Bool = true
    /// 汇报当前内容高度，供外层在单一滚动容器里布局。
    var onContentHeightChange: ((CGFloat) -> Void)? = nil
    /// 当前页面是否处于前台可见状态。用于 keep-alive tab 切回时显式触发 AppKit 网格刷新。
    var isVisible: Bool = true
    /// SwiftUI 外层确认后的容器宽度。切换 tab / 调整窗口时，直接把稳定宽度传给 AppKit，
    /// 避免仅依赖 NSScrollView 暂态 bounds 导致空布局。
    var layoutWidth: CGFloat = 0
    /// 允许不同页面显式指定列数，避免被共享布局的默认阈值覆盖。
    var gridColumnCount: Int? = nil
    /// 给 hover 预留在 item 内部的扩张空间。当前 hover 对齐我的库卡片，只做 1.01 中心缩放，
    /// 不再改变布局宽度，所以默认不预留，保持和媒体探索页相同的宽度/列数计算。
    var hoverExpansionAllowance: CGFloat = 0
    /// 网格内边距。`nil` 表示沿用 `ExploreGridCollectionViewLayout` 默认值
    /// `(top: 0, left: 2, bottom: 48, right: 2)`。壁纸探索页等需要紧贴上下边的场景显式传 `.zero`。
    var contentInsets: NSEdgeInsets? = nil
    /// 顶部 header 还剩多少高度未收起。>0 时向下滚优先收 header，网格锁在 y=0。
    var headerCollapseRemaining: CGFloat = 0
    /// 顶部 header 已收起高度。网格在顶部且此值>0 时，向上滚优先展开 header。
    var headerCollapseConsumed: CGFloat = 0
    /// 滚轮驱动的 header 收起增量：`>0` 收起，`<0` 展开。
    var onHeaderCollapseDelta: ((CGFloat) -> Void)? = nil
    /// 外部递增时，把 `pendingScrollDown` 应用到网格（header 区域滚轮余量）。
    var externalScrollDownToken: Int = 0
    var pendingScrollDown: CGFloat = 0
    /// 已消费 pending 后回调，供 SwiftUI 清零，避免重复应用。
    var onPendingScrollDownConsumed: (() -> Void)? = nil

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        let previousParent = coordinator.parent
        let layoutWidthChanged = abs(layoutWidth - previousParent.layoutWidth) > 0.5
        let hoverAllowanceChanged = abs(hoverExpansionAllowance - previousParent.hoverExpansionAllowance) > 0.5
        let columnCountChanged = gridColumnCount != previousParent.gridColumnCount
        let contentInsetsChanged = !insetsEqual(contentInsets, previousParent.contentInsets)
        let visibilityChanged = isVisible != previousParent.isVisible
        let cellClassChanged = previousParent.cellClass != cellClass
        let scrollingModeChanged = allowsScrolling != previousParent.allowsScrolling
        coordinator.parent = self
        coordinator.syncHeaderCollapseStateFromParent()
        let layoutRefreshChanged = layoutRefreshToken != coordinator.lastLayoutRefreshToken
        let visibilityRefreshChanged = visibilityRefreshToken != coordinator.lastVisibilityRefreshToken

        if contentInsetsChanged {
            coordinator.applyContentInsetsIfNeeded()
        }

        if cellClassChanged {
            coordinator.registerCellClassIfNeeded(cellClass)
        }

        coordinator.configureScrollingMode(allowsScrolling)

        // 不再用 isHidden 驱动可见性恢复。
        // SwiftUI keep-alive 只是把整页 opacity 设为 0；这里如果再同步到 AppKit isHidden，
        // NSCollectionView 在 hide/unhide 期间更容易丢失顶部可视 item 的布局/显示状态。
        // 改为直接把可见性变化通知 coordinator，由它决定暂停与恢复时机。
        if scrollView.isHidden {
            scrollView.isHidden = false
        }
        if visibilityChanged {
            coordinator.visibilityDidChange(isVisible: isVisible)
        }

        if layoutRefreshChanged {
            coordinator.lastLayoutRefreshToken = layoutRefreshToken
            coordinator.viewportDidResize()
        } else if layoutWidthChanged || hoverAllowanceChanged || columnCountChanged || scrollingModeChanged {
            if layoutWidthChanged || hoverAllowanceChanged || columnCountChanged {
                coordinator.viewportDidResize()
            }
            if scrollingModeChanged {
                coordinator.viewportDidResize()
            }
        }

        if visibilityRefreshChanged {
            coordinator.lastVisibilityRefreshToken = visibilityRefreshToken
            coordinator.forceVisibilityRefresh()
        }

        let newCount = itemCount()

        // 注意：reloadData / performBatchUpdates 是延迟到下一个 run loop 执行的。
        // lastItemCount 在延迟块实际执行时才更新，确保后续 updateNSView 调用能正确触发 reload。
        if cellClassChanged {
            coordinator.reloadData()
        } else if newCount != coordinator.lastItemCount {
            let oldCount = coordinator.lastItemCount

            if newCount > oldCount && oldCount > 0 {
                coordinator.performBatchUpdates(insertedCount: newCount - oldCount, oldCount: oldCount)
            } else {
                coordinator.reloadData()
            }
        } else if reloadToken != coordinator.lastReloadToken {
            coordinator.refreshVisibleItems()
        }

        coordinator.lastReloadToken = reloadToken

        if scrollToTopToken != coordinator.lastScrollToTopToken {
            coordinator.lastScrollToTopToken = scrollToTopToken
            coordinator.scrollToTop()
        }

        if restoreScrollToken != coordinator.lastRestoreScrollToken {
            coordinator.lastRestoreScrollToken = restoreScrollToken
            coordinator.restoreScrollOffset(restoreScrollOffset)
        }

        if externalScrollDownToken != coordinator.lastExternalScrollDownToken {
            coordinator.lastExternalScrollDownToken = externalScrollDownToken
            let delta = pendingScrollDown
            if delta > 0.5 {
                coordinator.applyExternalScrollDown(delta)
            }
            // 无论 delta 大小都清零，防止 token 重复触发时叠加旧值
            onPendingScrollDownConsumed?()
        }
    }

    func makeCoordinator() -> ExploreGridCoordinator {
        ExploreGridCoordinator(self)
    }

    /// `NSEdgeInsets` 不是 `Equatable`，手动比较。
    private func insetsEqual(_ lhs: NSEdgeInsets?, _ rhs: NSEdgeInsets?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (l?, r?):
            return abs(l.top - r.top) < 0.5
                && abs(l.left - r.left) < 0.5
                && abs(l.bottom - r.bottom) < 0.5
                && abs(l.right - r.right) < 0.5
        default: return false
        }
    }
}
