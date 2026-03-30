import SwiftUI

/// 探索页网格：列数 2…4（中间宽度默认约 3 列）、间距 16pt。
enum ExploreGridLayout {
    static let spacing: CGFloat = 16

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

    static func columns(for contentWidth: CGFloat) -> [GridItem] {
        let n = columnCount(for: contentWidth)
        return Array(
            repeating: GridItem(.flexible(), spacing: spacing, alignment: .top),
            count: n
        )
    }
}
