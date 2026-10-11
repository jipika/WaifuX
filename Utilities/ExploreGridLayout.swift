import SwiftUI

/// 用于 `onScrollGeometryChange` 的 Equatable 状态，只在跨过"近底"阈值时翻转。
/// 避免因 contentSize 增长导致 distance 数值波动触发不必要的 action 回调。
public struct ScrollNearBottomState: Equatable {
    public var isNearBottom: Bool
    public init(isNearBottom: Bool) {
        self.isNearBottom = isNearBottom
    }
}

/// 探索页网格：列数 2…4（中间宽度默认约 3 列）、间距 16pt。
enum ExploreGridLayout {
    static let spacing: CGFloat = 16

    /// 列数上限。媒体探索页的壁纸引擎源会在默认分级上 +1 列（见 `squareCoverColumnCount`）。
    static let maximumColumnCount = 5

    /// `contentWidth` 为已扣除水平内边距后的可用宽度。
    static func columnCount(for contentWidth: CGFloat) -> Int {
        let w = max(0, contentWidth)
        let g = spacing
        // 列数越大，对单卡最小宽度要求略提高，避免过窄时仍挤 4 列；中间区间自然落在 3 列。
        let tiers: [(cols: Int, minCell: CGFloat)] = [
            (4, 210),
            (3, 195),
            (2, 160)
        ]
        for tier in tiers {
            let cell = (w - CGFloat(tier.cols - 1) * g) / CGFloat(tier.cols)
            if cell >= tier.minCell {
                return tier.cols
            }
        }
        return 2
    }

    /// 正方形封面源（壁纸引擎 Steam Workshop）的列数：默认分级 +1，封顶 `maximumColumnCount`。
    /// 封面从 16:10 变 1:1 后单卡明显更高，多一列才能让整体卡片尺度与其它源接近。
    static func squareCoverColumnCount(for contentWidth: CGFloat) -> Int {
        min(columnCount(for: contentWidth) + 1, maximumColumnCount)
    }

    static func columns(for contentWidth: CGFloat) -> [GridItem] {
        let n = columnCount(for: contentWidth)
        return Array(
            repeating: GridItem(.flexible(), spacing: spacing, alignment: .top),
            count: n
        )
    }

    static func stableColumns<Item>(items: [Item], columnCount: Int) -> [[Item]] {
        let safeColumnCount = max(1, columnCount)
        var columns = Array(repeating: [Item](), count: safeColumnCount)

        for (index, item) in items.enumerated() {
            columns[index % safeColumnCount].append(item)
        }

        return columns
    }

    /// 高度平衡的瀑布流列分配，根据每项计算高度将新项放入当前最矮的列。
    /// 适用于图片尺寸不一致的场景（如壁纸/媒体），避免部分列堆积过多导致视觉不平衡。
    /// - Parameters:
    ///   - items: 所有数据项
    ///   - columnCount: 列数
    ///   - cardWidth: 卡片宽度（用于计算高度）
    ///   - spacing: 列内 item 间距
    ///   - heightProvider: 返回每项在给定卡片宽度下的高度
    /// - Returns: 每列的数据数组
    static func waterfallColumns<Item>(
        items: [Item],
        columnCount: Int,
        cardWidth: CGFloat,
        spacing: CGFloat,
        heightProvider: (Item) -> CGFloat
    ) -> [[Item]] {
        let safeColumnCount = max(1, columnCount)
        var columns = Array(repeating: [Item](), count: safeColumnCount)
        var columnHeights = Array(repeating: CGFloat(0), count: safeColumnCount)

        for item in items {
            // 找到当前总高度最小的列
            let minHeight = columnHeights.min() ?? 0
            let column = columnHeights.firstIndex(of: minHeight) ?? 0

            columns[column].append(item)
            let itemHeight = heightProvider(item)
            columnHeights[column] += itemHeight + spacing
        }

        return columns
    }
}
