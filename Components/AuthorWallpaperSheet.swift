import SwiftUI
import Kingfisher

// MARK: - 作者壁纸右侧滑出面板
struct AuthorWallpaperSheet: View {
    let uploader: Wallpaper.Uploader
    let sourceName: String
    let contentTitle: String
    let wallpapers: [Wallpaper]
    let isLoading: Bool
    /// 是否还有更多页；为 false 时不再触发 onLoadMore
    var hasMore: Bool = true
    let activeWallpaperID: String?
    let onSelectWallpaper: (Wallpaper) -> Void
    let onDismiss: () -> Void
    let onLoadMore: (() -> Void)?
    let onDownloadLoaded: (([Wallpaper]) -> Void)?
    let onDownloadAll: (([Wallpaper]) -> Void)?

    @State private var isVisible = false
    @Binding var isDownloadingAll: Bool
    /// 触底加载冷却（NSCollectionView onReachBottom 会随滚动反复回调，靠冷却 + isLoading 去重）
    @State private var loadMoreCooldownUntil: Date?
    /// 当前项高亮切换（数量不变的内容变化）时递增，强制刷新可见 Cell
    @State private var activeReloadToken = 0

    private let panelWidth: CGFloat = 360
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
                    // 顶部留出右上角关闭按钮的避让空间
                    .padding(.top, 18)
                    .padding(.bottom, 14)

                dividerLine
                    .padding(.horizontal, 20)

                HStack {
                    Text(contentTitle)
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
            .overlay(alignment: .topTrailing) {
                // 关闭按钮固定在面板右上角
                closeButton
                    .padding(.top, 8)
                    .padding(.trailing, 12)
            }
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

                Label(sourceName, systemImage: sourceName.caseInsensitiveCompare("pixiv") == .orderedSame ? "paintpalette" : "photo.stack")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(LiquidGlassColors.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !wallpapers.isEmpty {
                // 下载操作固定贴面板右缘，把中间空间让给作者名
                downloadActions
            }
        }
    }

    // MARK: - 右上角关闭按钮
    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(LiquidGlassColors.textSecondary)
                .frame(width: 26, height: 26)
                .background(
                    Circle()
                        .fill(LiquidGlassColors.glassTint)
                )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var downloadActions: some View {
        VStack(spacing: 5) {
            if let onDownloadLoaded {
                authorDownloadButton(title: t("downloadLoadedByAuthor")) {
                    isDownloadingAll = true
                    onDownloadLoaded(wallpapers)
                }
                .help(t("downloadLoadedByAuthor"))
            }

            if let onDownloadAll {
                authorDownloadButton(title: t("downloadAllByAuthor")) {
                    isDownloadingAll = true
                    onDownloadAll(wallpapers)
                }
                .help(t("downloadAllByAuthor"))
            }
        }
    }

    private func authorDownloadButton(
        title: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .foregroundStyle(isDownloadingAll ? Color.accentColor : LiquidGlassColors.textSecondary)
                .frame(width: 94, height: 24)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(
                            isDownloadingAll
                                ? Color.accentColor.opacity(0.55)
                                : LiquidGlassColors.borderSubtle,
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(.plain)
        .disabled(isDownloadingAll)
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

    // MARK: - 壁纸网格（NSCollectionView 固定 2 列，复用 ExploreGrid cell 基建保证滚动流畅）
    private var wallpaperGrid: some View {
        Group {
            if wallpapers.isEmpty && !isLoading {
                ScrollView(.vertical, showsIndicators: false) {
                    emptyState
                }
            } else {
                AuthorSheetGridContainer(
                    itemCount: { wallpapers.count },
                    heightForItem: { index in
                        guard index >= 0, index < wallpapers.count else {
                            return AuthorSheetCardMetrics.mediaCardHeight
                        }
                        let wallpaper = wallpapers[index]
                        return AuthorSheetCardMetrics.wallpaperCardHeight(
                            hasTitle: wallpaper.title?.isEmpty == false,
                            hasCategory: !wallpaper.category.isEmpty,
                            hasResolution: !wallpaper.resolution.isEmpty
                        )
                    },
                    configureCell: { cell, index in
                        guard index >= 0, index < wallpapers.count else { return }
                        (cell as? AuthorWallpaperGridCell)?.configure(
                            with: wallpapers[index],
                            isActive: wallpapers[index].id == activeWallpaperID
                        )
                    },
                    cellClass: AuthorWallpaperGridCell.self,
                    onSelect: { index in
                        guard index >= 0, index < wallpapers.count else { return }
                        onSelectWallpaper(wallpapers[index])
                    },
                    onReachBottom: {
                        handleReachBottom()
                    },
                    reloadToken: activeReloadToken,
                    layoutWidth: panelWidth
                )
            }
        }
        .onChange(of: activeWallpaperID) { _, _ in
            activeReloadToken += 1
        }
    }

    // MARK: - 触底加载
    /// onReachBottom 在近底区间会随滚动反复回调；
    /// 与旧哨兵方案相同语义：isLoading / hasMore 拦截 + 0.8s 冷却。
    private func handleReachBottom() {
        guard let onLoadMore,
              hasMore,
              !isLoading,
              !wallpapers.isEmpty else { return }

        if let cooldown = loadMoreCooldownUntil, Date() < cooldown { return }

        loadMoreCooldownUntil = Date().addingTimeInterval(0.8)
        onLoadMore()
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
