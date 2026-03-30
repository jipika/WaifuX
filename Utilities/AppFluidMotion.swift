import SwiftUI

/// 全局动画节奏：略提高阻尼、略拉长 response，减少「弹两下」的廉价感，更接近系统控件手感。
enum AppFluidMotion {
    /// 筛选、分段、芯片等交互
    static let interactiveSpring = Animation.spring(response: 0.34, dampingFraction: 0.88)
    /// 导航标签、开关状态
    static let navigationSpring = Animation.spring(response: 0.36, dampingFraction: 0.86)
    /// 悬停 scale、小控件
    static let hoverEase = Animation.easeOut(duration: 0.18)
    /// 列表卡片悬停
    static let cardHoverEase = Animation.easeOut(duration: 0.16)
    /// 页面级淡入淡出（Tab、Sheet 可配合 transition）
    static let contentCrossfade = Animation.easeInOut(duration: 0.22)
}

// MARK: - 高速滚动（与 Home 一致：降载图片与重背景）

private struct IsHighSpeedScrollingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// 由滚动容器在 preference 更新时写入；子视图可据此跳过缩略图解码等。
    var isHighSpeedScrolling: Bool {
        get { self[IsHighSpeedScrollingKey.self] }
        set { self[IsHighSpeedScrollingKey.self] = newValue }
    }
}
