import SwiftUI

// MARK: - 消息内容视图
struct MessagesContentView: View {
    @ObservedObject var viewModel: WallpaperViewModel

    var body: some View {
        ZStack {
            LiquidGlassBackground()

            VStack(spacing: 24) {
                // 标题
                Text(t("nav.messages"))
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(LiquidGlassColors.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 32)
                    .padding(.top, 60)

                Spacer()

                // 消息图标
                Image(systemName: "message.fill")
                    .font(.system(size: 60, weight: .light))
                    .foregroundStyle(LiquidGlassColors.textTertiary)

                Text(t("noMessages"))
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(LiquidGlassColors.textSecondary)

                Spacer()
            }
        }
    }
}
