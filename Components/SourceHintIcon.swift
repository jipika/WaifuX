import SwiftUI

// MARK: - 数据源切换提示问号图标
/// 实心问号 + 圆形边框，悬停时显示 tooltip 提示用户可以点击切换数据源
struct SourceHintIcon: View {
    @State private var isHovering = false
    @State private var showTooltip = false

    var body: some View {
        Image(systemName: "questionmark.circle.fill")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Color.secondary.opacity(isHovering ? 0.75 : 0.45))
            .overlay(
                Circle()
                    .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5)
            )
            .onHover { hovering in
                isHovering = hovering
                showTooltip = hovering
            }
            .popover(isPresented: $showTooltip, arrowEdge: .bottom) {
                Text(t("sourceSwitchHint"))
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
    }
}
