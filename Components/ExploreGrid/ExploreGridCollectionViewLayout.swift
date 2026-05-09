import AppKit

/// 网格布局代理协议
@MainActor
protocol ExploreGridCollectionViewLayoutDelegate: AnyObject {
    func collectionView(_ collectionView: NSCollectionView, aspectRatioForItemAt indexPath: IndexPath) -> CGFloat
}

/// 网格/瀑布流布局
/// 支持多列自适应，根据图片比例动态计算 Cell 高度
/// 参考 FlowVision 的 WaterfallLayout
final class ExploreGridCollectionViewLayout: NSCollectionViewLayout {

    weak var delegate: ExploreGridCollectionViewLayoutDelegate?

    private var cache: [NSCollectionViewLayoutAttributes] = []
    private var attributesByMinY: [NSCollectionViewLayoutAttributes] = []
    private var contentHeight: CGFloat = 0
    private var maxItemHeight: CGFloat = 0
    private var needsCacheRebuild = true
    private var lastPreparedWidth: CGFloat = 0
    private var lastPreparedItemCount: Int = -1
    private var lastPreparedHoverAllowance: CGFloat = -1
    var preferredColumnCount: Int?

    var cachedItemCount: Int {
        cache.count
    }

    var preparedWidth: CGFloat {
        lastPreparedWidth
    }

    /// 列数（根据容器宽度自动计算）
    var numberOfColumns: Int {
        if let preferredColumnCount, preferredColumnCount > 0 {
            return preferredColumnCount
        }
        guard let collectionView = collectionView else { return 3 }
        let width = collectionView.bounds.width
        if width > 1200 { return 4 }
        if width > 800 { return 3 }
        return 2
    }

    /// 列间距
    var columnSpacing: CGFloat = 16
    /// 行间距
    var rowSpacing: CGFloat = 16
    /// 内边距
    var contentInsets: NSEdgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 48, right: 2)
    /// item 内部预留给 hover 扩张的空间。视觉卡片不会被边缘裁切，常态间距保持不变。
    var hoverExpansionAllowance: CGFloat = 0

    override func prepare() {
        rebuildCacheIfNeeded()
    }

    override func invalidateLayout() {
        needsCacheRebuild = true
        super.invalidateLayout()
    }

    private func rebuildCacheIfNeeded() {
        guard let collectionView = collectionView,
              let delegate = delegate else { return }

        let totalWidth = collectionView.bounds.width
        let itemCount = collectionView.numberOfItems(inSection: 0)
        let hoverAllowance = max(0, hoverExpansionAllowance)

        guard totalWidth > 0 else {
            cache.removeAll()
            attributesByMinY.removeAll()
            contentHeight = 0
            maxItemHeight = 0
            needsCacheRebuild = true
            return
        }

        let widthChanged = abs(totalWidth - lastPreparedWidth) > 0.5
        let hoverChanged = abs(hoverAllowance - lastPreparedHoverAllowance) > 0.5
        guard needsCacheRebuild ||
              widthChanged ||
              itemCount != lastPreparedItemCount ||
              hoverChanged else { return }

        cache.removeAll()
        attributesByMinY.removeAll()
        contentHeight = 0
        maxItemHeight = 0

        let columnCount = numberOfColumns
        let availableWidth = totalWidth - contentInsets.left - contentInsets.right
        let rawCardWidth = floor(
            (availableWidth - columnSpacing * CGFloat(columnCount - 1) - hoverAllowance * 2) / CGFloat(columnCount)
        )
        let cardWidth = max(1, rawCardWidth)
        let itemWidth = cardWidth + hoverAllowance * 2

        // 每列的 x 偏移
        var xOffset: [CGFloat] = []
        for column in 0..<columnCount {
            xOffset.append(contentInsets.left + CGFloat(column) * (cardWidth + columnSpacing))
        }

        // 每列的 y 偏移
        var yOffset: [CGFloat] = .init(repeating: contentInsets.top, count: columnCount)

        for item in 0..<itemCount {
            let indexPath = IndexPath(item: item, section: 0)

            // 根据图片比例计算高度
            let aspectRatio = delegate.collectionView(collectionView, aspectRatioForItemAt: indexPath)
            let safeAspectRatio = aspectRatio > 0 ? aspectRatio : 1.0
            let cardHeight = round(cardWidth / safeAspectRatio)
            let itemHeight = cardHeight + hoverAllowance * 2
            maxItemHeight = max(maxItemHeight, itemHeight)

            // 找到最短的列
            let minYOffset = yOffset.min() ?? 0
            let column = yOffset.firstIndex(of: minYOffset) ?? 0

            let frame = CGRect(
                x: xOffset[column],
                y: yOffset[column],
                width: itemWidth,
                height: itemHeight
            )

            let attributes = NSCollectionViewLayoutAttributes(forItemWith: indexPath)
            attributes.frame = frame
            cache.append(attributes)

            contentHeight = max(contentHeight, frame.maxY)
            yOffset[column] += cardHeight + rowSpacing
        }

        contentHeight += contentInsets.bottom
        attributesByMinY = cache.sorted {
            if abs($0.frame.minY - $1.frame.minY) > 0.5 {
                return $0.frame.minY < $1.frame.minY
            }
            return $0.frame.minX < $1.frame.minX
        }
        lastPreparedWidth = totalWidth
        lastPreparedItemCount = itemCount
        lastPreparedHoverAllowance = hoverAllowance
        needsCacheRebuild = false
    }

    override var collectionViewContentSize: NSSize {
        rebuildCacheIfNeeded()
        guard let collectionView = collectionView else {
            return NSSize(width: 100, height: 100)
        }
        return NSSize(width: collectionView.bounds.width, height: contentHeight)
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        rebuildCacheIfNeeded()
        guard !attributesByMinY.isEmpty else { return [] }

        var visibleAttributes: [NSCollectionViewLayoutAttributes] = []
        visibleAttributes.reserveCapacity(32)
        let searchStartY = rect.minY - maxItemHeight - rowSpacing
        let startIndex = lowerBoundForMinY(searchStartY)

        for index in startIndex..<attributesByMinY.count {
            let attributes = attributesByMinY[index]
            let frame = attributes.frame

            if frame.minY > rect.maxY {
                break
            }
            if frame.intersects(rect) {
                visibleAttributes.append(attributes)
            }
        }

        return visibleAttributes
    }

    private func lowerBoundForMinY(_ targetMinY: CGFloat) -> Int {
        var low = 0
        var high = attributesByMinY.count

        while low < high {
            let mid = (low + high) / 2
            if attributesByMinY[mid].frame.minY < targetMinY {
                low = mid + 1
            } else {
                high = mid
            }
        }

        return low
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        rebuildCacheIfNeeded()
        guard indexPath.item < cache.count else { return nil }
        return cache[indexPath.item]
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        guard let collectionView = collectionView else { return false }
        return newBounds.width != collectionView.bounds.width
    }

}
