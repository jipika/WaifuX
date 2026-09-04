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
    /// 每列下一张卡片的起始 y。分页追加时直接从这里继续排布，
    /// 避免把已经显示过的全部 item 重新计算一遍。
    private var columnEndY: [CGFloat] = []
    private var lastPreparedColumnCount: Int = 0
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
    /// 固定尺寸卡片（猜你喜欢 260×360 等）。非 nil 时忽略 delegate 比例，卡片保持
    /// 固定宽高，列块整体水平居中（还原 LazyVGrid 默认 .center + GridItem(.fixed)）；
    /// 容器宽度不足整块时按比例缩小避免裁切。该模式下数据总是整表替换，
    /// 不走分页追加路径（canAppend 由下方早退分支天然屏蔽）。
    var fixedCardSize: CGSize? = nil

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

        if let fixedCardSize {
            rebuildFixedGridCache(
                fixedCardSize: fixedCardSize,
                totalWidth: totalWidth,
                itemCount: itemCount,
                hoverAllowance: hoverAllowance
            )
            return
        }

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

        // NSCollectionView 的分页插入只增加尾部 item。保留旧属性和列尾，
        // 只为新 item 计算 frame；这段路径是滚动到底部时的关键帧优化。
        let canAppend = !needsCacheRebuild
            && !widthChanged
            && !hoverChanged
            && itemCount > lastPreparedItemCount
            && cache.count == lastPreparedItemCount
            && columnEndY.count == columnCount
            && lastPreparedColumnCount == columnCount

        if canAppend {
            let newAttributes = appendAttributes(
                from: lastPreparedItemCount,
                to: itemCount,
                xOffset: xOffset,
                cardWidth: cardWidth,
                itemWidth: itemWidth,
                columnCount: columnCount,
                hoverAllowance: hoverAllowance
            )
            cache.append(contentsOf: newAttributes)
            mergeAttributesByMinY(newAttributes)
            lastPreparedItemCount = itemCount
            lastPreparedWidth = totalWidth
            lastPreparedHoverAllowance = hoverAllowance
            return
        }

        cache.removeAll(keepingCapacity: true)
        attributesByMinY.removeAll(keepingCapacity: true)
        contentHeight = 0
        maxItemHeight = 0

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

        columnEndY = yOffset
        lastPreparedColumnCount = columnCount
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

    /// 固定尺寸卡片网格：所有卡片同宽同高、按行铺满、整块水平居中。
    private func rebuildFixedGridCache(
        fixedCardSize: CGSize,
        totalWidth: CGFloat,
        itemCount: Int,
        hoverAllowance: CGFloat
    ) {
        let columnCount = max(1, numberOfColumns)
        let interColumnSpacing = columnSpacing * CGFloat(max(0, columnCount - 1))
        let availableWidth = totalWidth - contentInsets.left - contentInsets.right

        let blockWidth = fixedCardSize.width * CGFloat(columnCount) + interColumnSpacing
        let cardWidth: CGFloat
        let cardHeight: CGFloat
        let leadingX: CGFloat
        if availableWidth >= blockWidth {
            // 容器装得下整块：保持固定卡片尺寸，列块居中（LazyVGrid .center 对齐）
            cardWidth = fixedCardSize.width
            cardHeight = fixedCardSize.height
            leadingX = contentInsets.left + (availableWidth - blockWidth) / 2
        } else {
            // 容器过窄：按比例缩小铺满，避免横向裁切（退化场景）
            cardWidth = max(1, floor((availableWidth - interColumnSpacing) / CGFloat(columnCount)))
            cardHeight = round(cardWidth * fixedCardSize.height / max(1, fixedCardSize.width))
            leadingX = contentInsets.left
        }

        let itemWidth = cardWidth + hoverAllowance * 2
        let itemHeight = cardHeight + hoverAllowance * 2
        maxItemHeight = itemHeight

        cache.removeAll(keepingCapacity: true)
        attributesByMinY.removeAll(keepingCapacity: true)
        contentHeight = 0

        for item in 0..<itemCount {
            let column = item % columnCount
            let row = item / columnCount
            let frame = CGRect(
                x: leadingX + CGFloat(column) * (cardWidth + columnSpacing),
                y: contentInsets.top + CGFloat(row) * (cardHeight + rowSpacing),
                width: itemWidth,
                height: itemHeight
            )
            let attributes = NSCollectionViewLayoutAttributes(forItemWith: IndexPath(item: item, section: 0))
            attributes.frame = frame
            cache.append(attributes)
            contentHeight = max(contentHeight, frame.maxY)
        }

        contentHeight += contentInsets.bottom
        attributesByMinY = cache.sorted {
            if abs($0.frame.minY - $1.frame.minY) > 0.5 {
                return $0.frame.minY < $1.frame.minY
            }
            return $0.frame.minX < $1.frame.minX
        }
        columnEndY = []
        lastPreparedColumnCount = columnCount
        lastPreparedWidth = totalWidth
        lastPreparedItemCount = itemCount
        lastPreparedHoverAllowance = hoverAllowance
        needsCacheRebuild = false
    }

    /// 仅计算分页追加的尾部 item。`columnEndY` 保存的是上一轮布局每列的
    /// 下一起始 y，因此不会改变既有卡片位置，也不会造成滚动位置跳动。
    private func appendAttributes(
        from startIndex: Int,
        to endIndex: Int,
        xOffset: [CGFloat],
        cardWidth: CGFloat,
        itemWidth: CGFloat,
        columnCount: Int,
        hoverAllowance: CGFloat
    ) -> [NSCollectionViewLayoutAttributes] {
        guard startIndex < endIndex,
              columnEndY.count == columnCount,
              let collectionView,
              let delegate else {
            return []
        }

        var newAttributes: [NSCollectionViewLayoutAttributes] = []
        newAttributes.reserveCapacity(endIndex - startIndex)

        // contentHeight 已包含 bottom inset；追加前先还原到最后一张卡片的底部。
        var contentHeightWithoutBottomInset = max(0, contentHeight - contentInsets.bottom)

        for item in startIndex..<endIndex {
            let indexPath = IndexPath(item: item, section: 0)
            let aspectRatio = delegate.collectionView(collectionView, aspectRatioForItemAt: indexPath)
            let safeAspectRatio = aspectRatio > 0 ? aspectRatio : 1.0
            let cardHeight = round(cardWidth / safeAspectRatio)
            let itemHeight = cardHeight + hoverAllowance * 2

            let minYOffset = columnEndY.min() ?? contentInsets.top
            let column = columnEndY.firstIndex(of: minYOffset) ?? 0
            let frame = CGRect(
                x: xOffset[column],
                y: columnEndY[column],
                width: itemWidth,
                height: itemHeight
            )

            let attributes = NSCollectionViewLayoutAttributes(forItemWith: indexPath)
            attributes.frame = frame
            newAttributes.append(attributes)

            columnEndY[column] += cardHeight + rowSpacing
            contentHeightWithoutBottomInset = max(contentHeightWithoutBottomInset, frame.maxY)
            maxItemHeight = max(maxItemHeight, itemHeight)
        }

        contentHeight = contentHeightWithoutBottomInset + contentInsets.bottom
        return newAttributes
    }

    /// `layoutAttributesForElements(in:)` 依赖按 y 排序的索引。追加项可能落在
    /// 不同列的旧项之间，所以做线性 merge，避免对整个数组再次 O(n log n) 排序。
    private func mergeAttributesByMinY(_ newAttributes: [NSCollectionViewLayoutAttributes]) {
        guard !newAttributes.isEmpty else { return }

        let sortedNew = newAttributes.sorted {
            if abs($0.frame.minY - $1.frame.minY) > 0.5 {
                return $0.frame.minY < $1.frame.minY
            }
            return $0.frame.minX < $1.frame.minX
        }

        var merged: [NSCollectionViewLayoutAttributes] = []
        merged.reserveCapacity(attributesByMinY.count + sortedNew.count)

        var oldIndex = 0
        var newIndex = 0
        while oldIndex < attributesByMinY.count || newIndex < sortedNew.count {
            if newIndex == sortedNew.count {
                merged.append(contentsOf: attributesByMinY[oldIndex...])
                break
            }
            if oldIndex == attributesByMinY.count {
                merged.append(contentsOf: sortedNew[newIndex...])
                break
            }

            let old = attributesByMinY[oldIndex]
            let new = sortedNew[newIndex]
            let newComesFirst: Bool
            if abs(old.frame.minY - new.frame.minY) > 0.5 {
                newComesFirst = new.frame.minY < old.frame.minY
            } else {
                newComesFirst = new.frame.minX < old.frame.minX
            }
            if newComesFirst {
                merged.append(new)
                newIndex += 1
            } else {
                merged.append(old)
                oldIndex += 1
            }
        }
        attributesByMinY = merged
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
