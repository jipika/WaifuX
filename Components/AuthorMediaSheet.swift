import SwiftUI
import Kingfisher

// MARK: - 媒体作者壁纸右侧滑出面板（Workshop 源）
struct AuthorMediaSheet: View {
    let authorName: String
    let authorSteamID: String
    let authorAvatarURL: URL?
    let items: [MediaItem]
    let isLoading: Bool
    /// 是否还有更多页；为 false 时不再触发 onLoadMore
    var hasMore: Bool = true
    /// 当前正在详情页查看的媒体 ID，用于高亮对应卡片
    let activeItemID: String?
    let onSelectItem: (MediaItem) -> Void
    let onDismiss: () -> Void
    let onLoadMore: (() -> Void)?
    let onDownloadLoaded: (([MediaItem]) -> Void)?
    let onDownloadAll: (([MediaItem]) -> Void)?

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
                    if !items.isEmpty {
                        Text("\(items.count)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(LiquidGlassColors.textTertiary)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 10)

                itemGrid
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
                Text(authorName)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(LiquidGlassColors.textPrimary)
                    .lineLimit(1)

                Label("Steam Workshop", systemImage: "person.2.crop.square.stack")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(LiquidGlassColors.textTertiary)
            }

            if !items.isEmpty {
                downloadActions
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

    @ViewBuilder
    private var downloadActions: some View {
        VStack(spacing: 5) {
            if let onDownloadLoaded {
                authorDownloadButton(title: t("downloadLoadedByAuthor")) {
                    isDownloadingAll = true
                    onDownloadLoaded(items)
                }
                .help(t("downloadLoadedByAuthor"))
            }

            if let onDownloadAll {
                authorDownloadButton(title: t("downloadAllByAuthor")) {
                    isDownloadingAll = true
                    onDownloadAll(items)
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
        if let url = authorAvatarURL {
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
    private var itemGrid: some View {
        Group {
            if items.isEmpty && !isLoading {
                ScrollView(.vertical, showsIndicators: false) {
                    emptyState
                }
            } else {
                AuthorSheetGridContainer(
                    itemCount: { items.count },
                    heightForItem: { _ in AuthorSheetCardMetrics.mediaCardHeight },
                    configureCell: { cell, index in
                        guard index >= 0, index < items.count else { return }
                        (cell as? AuthorMediaGridCell)?.configure(
                            with: items[index],
                            isActive: items[index].id == activeItemID
                        )
                    },
                    cellClass: AuthorMediaGridCell.self,
                    onSelect: { index in
                        guard index >= 0, index < items.count else { return }
                        onSelectItem(items[index])
                    },
                    onReachBottom: {
                        handleReachBottom()
                    },
                    reloadToken: activeReloadToken,
                    layoutWidth: panelWidth
                )
            }
        }
        .onChange(of: activeItemID) { _, _ in
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
              !items.isEmpty else { return }

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
    private func dismiss() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.88, blendDuration: 0)) {
            isVisible = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            onDismiss()
        }
    }
}
