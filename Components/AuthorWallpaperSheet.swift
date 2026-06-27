import SwiftUI
import Kingfisher

// MARK: - 作者壁纸右侧滑出面板（Wallhaven 源）
struct AuthorWallpaperSheet: View {
    let uploader: Wallpaper.Uploader
    let wallpapers: [Wallpaper]
    let isLoading: Bool
    let activeWallpaperID: String?
    let onSelectWallpaper: (Wallpaper) -> Void
    let onDismiss: () -> Void
    let onLoadMore: (() -> Void)?

    @State private var isVisible = false

    private let panelWidth: CGFloat = 360
    private let cardSpacing: CGFloat = 12
    private let cornerRadius: CGFloat = 22

    var body: some View {
        GeometryReader { geometry in
            // 右侧面板
            VStack(spacing: 0) {
                // 拖拽指示条
                Capsule()
                    .fill(LiquidGlassColors.textQuaternary)
                    .frame(width: 36, height: 4)
                    .padding(.top, 10)
                    .padding(.bottom, 6)

                authorHeader
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 14)

                dividerLine
                    .padding(.horizontal, 20)

                HStack {
                    Text(t("authorWallpapers"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LiquidGlassColors.textSecondary)
                    Spacer()
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                    }
                    if !wallpapers.isEmpty {
                        Text("\(wallpapers.count)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(LiquidGlassColors.textTertiary)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 10)

                wallpaperGrid
                    .frame(maxHeight: .infinity)
            }
            .frame(width: panelWidth)
            .frame(maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.55))
            )
            .liquidGlassSurface(
                .prominent,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .shadow(color: .black.opacity(0.35), radius: 48, x: -8, y: 0)
            .offset(x: isVisible ? 0 : panelWidth + 20)
            .opacity(isVisible ? 1 : 0)
            .padding(.vertical, 16)
            .padding(.trailing, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        }
        .onAppear {
            withAnimation(.spring(response: 0.40, dampingFraction: 0.85, blendDuration: 0)) {
                isVisible = true
            }
        }
    }

    // MARK: - 作者信息头部
    private var authorHeader: some View {
        HStack(spacing: 14) {
            authorAvatar
                .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 4) {
                Text(uploader.username)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(LiquidGlassColors.textPrimary)
                    .lineLimit(1)

                Label("wallhaven", systemImage: "photo.stack")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(LiquidGlassColors.textTertiary)
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LiquidGlassColors.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(LiquidGlassColors.glassTint)
                    )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 作者头像
    @ViewBuilder
    private var authorAvatar: some View {
        let avatarURL = selectBestAvatarURL()

        if let url = avatarURL {
            KFImage(url)
                .placeholder { _ in
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(LiquidGlassColors.textTertiary)
                }
                .resizable()
                .scaledToFill()
                .frame(width: 48, height: 48)
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .stroke(LiquidGlassColors.borderSubtle, lineWidth: 1)
                )
        } else {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 24))
                .foregroundStyle(LiquidGlassColors.textTertiary)
                .frame(width: 48, height: 48)
                .background(
                    Circle()
                        .fill(LiquidGlassColors.glassTint)
                )
        }
    }

    private let cardWidth: CGFloat = 158
    private let cardImageHeight: CGFloat = 100

    // MARK: - 壁纸网格（固定 2 列）
    private var wallpaperGrid: some View {
        ScrollView(.vertical, showsIndicators: false) {
            if wallpapers.isEmpty && !isLoading {
                emptyState
            } else {
                LazyVGrid(
                    columns: [
                        GridItem(.fixed(cardWidth), spacing: cardSpacing),
                        GridItem(.fixed(cardWidth), spacing: cardSpacing)
                    ],
                    spacing: cardSpacing
                ) {
                    ForEach(wallpapers) { wallpaper in
                        AuthorWallpaperCard(
                            wallpaper: wallpaper,
                            cardWidth: cardWidth,
                            cardImageHeight: cardImageHeight,
                            isActive: wallpaper.id == activeWallpaperID,
                            onTap: {
                                onSelectWallpaper(wallpaper)
                            }
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)

                // 加载更多触发器
                if let onLoadMore = onLoadMore, !wallpapers.isEmpty {
                    Color.clear
                        .frame(height: 1)
                        .onAppear {
                            onLoadMore()
                        }
                }
            }

            // 底部安全区
            Color.clear
                .frame(height: 12)
        }
        .iosSmoothScroll()
    }

    // MARK: - 空状态
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 28))
                .foregroundStyle(LiquidGlassColors.textQuaternary)

            Text(t("noWallpapers"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(LiquidGlassColors.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: - 分隔线
    private var dividerLine: some View {
        Rectangle()
            .fill(LiquidGlassColors.borderSubtle)
            .frame(height: 1)
    }

    // MARK: - Helper
    private func selectBestAvatarURL() -> URL? {
        let urls = [
            uploader.avatar.px200,
            uploader.avatar.px128,
            uploader.avatar.px32
        ]
        for urlString in urls {
            if let url = URL(string: urlString), !urlString.isEmpty {
                return url
            }
        }
        return nil
    }

    private func dismiss() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.88, blendDuration: 0)) {
            isVisible = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            onDismiss()
        }
    }
}

// MARK: - 作者壁纸卡片
private struct AuthorWallpaperCard: View {
    let wallpaper: Wallpaper
    let cardWidth: CGFloat
    let cardImageHeight: CGFloat
    let isActive: Bool
    let onTap: () -> Void

    @State private var isHovered = false
    private let cardCornerRadius: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 壁纸封面
            KFImage(coverImageURL)
                .setProcessor(DownsamplingImageProcessor(size: targetImageSize))
                .backgroundDecode()
                .cancelOnDisappear(true)
                .placeholder { _ in
                    Rectangle()
                        .fill(.white.opacity(0.05))
                }
                .fade(duration: 0.15)
                .resizable()
                .scaledToFill()
                .frame(width: cardWidth, height: cardImageHeight)
                .clipped()

            // 底部信息
            HStack(spacing: 6) {
                if !wallpaper.category.isEmpty {
                    Text(wallpaper.categoryDisplayName)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(.white.opacity(0.08))
                        )
                }

                Spacer(minLength: 0)

                if !wallpaper.resolution.isEmpty {
                    Text(wallpaper.resolution)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.35))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
        }
        .frame(width: cardWidth)
        .background(
            RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                .fill(Color(hex: "1A1D24").opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                .stroke(
                    isActive
                        ? Color.accentColor
                        : (isHovered ? .white.opacity(0.2) : .white.opacity(0.06)),
                    lineWidth: isActive ? 2 : 0.5
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
        .scaleEffect(isHovered ? 1.01 : 1)
        .animation(.easeOut(duration: 0.14), value: isHovered)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .throttledHover(interval: 0.08) { hovering in
            isHovered = hovering
        }
    }

    private var coverImageURL: URL? {
        wallpaper.thumbURL ?? wallpaper.smallThumbURL ?? wallpaper.fullImageURL
    }

    private var targetImageSize: CGSize {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        return CGSize(width: cardWidth * scale, height: cardImageHeight * scale)
    }
}
