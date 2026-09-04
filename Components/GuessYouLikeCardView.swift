import SwiftUI

// MARK: - 猜你喜欢单张卡片的内容覆盖层（SwiftUI 共享组件）
//
// 旧 LazyVGrid 版卡片 `GuessYouLikeCardView` 的 contentOverlay 原样抽出。
// 现由 `GuessYouLikeGridCell`（NSCollectionView 原生 cell）内的 NSHostingView
// 承载：封面图 / 底色 / 边框 / 投影 / 3D 倾斜 / 发牌动画走 AppKit 原生实现，
// 文本、来源标签与玻璃按钮继续用这份 SwiftUI 代码渲染，保证两版视觉逐像素一致。

struct GuessYouLikeCardOverlayContent: View {
    let item: GuessYouLikeItem
    let onDetail: (GuessYouLikeItem) -> Void
    let onDownload: (GuessYouLikeItem) -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            // 底部渐变遮罩
            LinearGradient(
                gradient: Gradient(colors: [.clear, .black.opacity(0.35), .black.opacity(0.7)]),
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(spacing: 0) {
                // 顶部：来源标签 + 标题 + 详情按钮
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        // 来源标签
                        sourceTag
                        // 标题
                        Text(item.title)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
                        Text(item.subtitle)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                            .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                    }
                    Spacer()
                    // 右上角液态玻璃圆形按钮 → 跳转详情
                    Button { onDetail(item) } label: {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.88))
                            .frame(width: 32, height: 32)
                            .detailGlassCircleChrome()
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)

                Spacer()

                // 底部：独立下载按钮（带边距，不延伸两边）
                Button { onDownload(item) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.to.line")
                            .font(.system(size: 11, weight: .semibold))
                        Text(t("download"))
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(.white.opacity(0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.25), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
                .padding(.bottom, 16)
            }
        }
    }

    // MARK: - 来源标签

    @ViewBuilder
    private var sourceTag: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(sourceColor.opacity(0.9))
                .frame(width: 6, height: 6)
            Text(item.sourceName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(.black.opacity(0.45))
        )
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
        )
    }

    private var sourceColor: Color {
        switch item.sourceName {
        case "WallHaven": return Color(hex: "FF6B6B")
        case "4K Wallpapers": return Color(hex: "4ECDC4")
        case "MotionBG": return Color(hex: "45B7D1")
        case "Wallpaper Engine": return Color(hex: "96CEB4")
        case "DongTai": return Color(hex: "F472B6")
        case "Wallsflow": return Color(hex: "9B5DE5")
        default: return Color(hex: "DDA0DD")
        }
    }
}

// MARK: - 预览

#Preview {
    GuessYouLikeCardOverlayContent(
        item: GuessYouLikeItem.mockItems()[0],
        onDetail: { _ in },
        onDownload: { _ in }
    )
    .frame(width: 260, height: 360)
    .background(Color(hex: "0D0D0D"))
}
