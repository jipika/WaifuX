import SwiftUI

// MARK: - 猜你喜欢覆盖层

struct GuessYouLikeOverlay: View {
    @ObservedObject var viewModel: GuessYouLikeViewModel
    let onDetail: (GuessYouLikeItem) -> Void
    let onDownload: (GuessYouLikeItem) -> Void

    init(
        viewModel: GuessYouLikeViewModel,
        onDetail: @escaping (GuessYouLikeItem) -> Void = { _ in },
        onDownload: @escaping (GuessYouLikeItem) -> Void = { _ in }
    ) {
        self.viewModel = viewModel
        self.onDetail = onDetail
        self.onDownload = onDownload
    }

    /// 发牌完成（dealingProgress → 1.0）等状态变化时递增，
    /// 驱动 AppKit 网格重配可见 cell 触发发牌动画
    @State private var gridReloadToken = 0

    private let columns = 4
    private let spacing: CGFloat = 18
    private let horizontalPadding: CGFloat = 40

    var body: some View {
        ZStack {
            // 半透明背景 — 点击关闭
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture { viewModel.dismiss() }

            VStack(spacing: 0) {
                // 标题栏
                HStack(alignment: .center) {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(LinearGradient(
                                colors: [.yellow, .orange, .pink],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ))
                        Text(t("common.youMayLike"))
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    Spacer()
                    Button { viewModel.dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.88))
                            .frame(width: 32, height: 32)
                            .detailGlassCircleChrome()
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 40)
                .padding(.top, 60)
                .padding(.bottom, 16)

                // 卡片区域 — NSCollectionView（ExploreGrid 复用管线，60fps 滚动）；
                // 发牌动画 / hover 倾斜由 GuessYouLikeGridCell 原生实现
                ExploreGridContainer(
                    itemCount: { viewModel.items.count },
                    aspectRatio: { _ in
                        GuessYouLikeGridCell.cardSize.width / GuessYouLikeGridCell.cardSize.height
                    },
                    configureCell: { cell, index in
                        configureGridCell(cell, index)
                    },
                    cellClass: GuessYouLikeGridCell.self,
                    // 每次 show() 都整表替换推荐内容：禁用增量插入，
                    // 数量变化一律 reloadData，避免旧卡片内容残留
                    cellClassForItem: { _ in GuessYouLikeGridCell.self },
                    gridSpacing: spacing,
                    onSelect: { index in
                        guard index < viewModel.items.count else { return }
                        onDetail(viewModel.items[index])
                    },
                    onReachBottom: {},
                    reloadToken: gridReloadToken,
                    gridColumnCount: columns,
                    // 旧 LazyVGrid padding：horizontal 40 / top 10 / bottom 30
                    contentInsets: NSEdgeInsets(
                        top: 10,
                        left: horizontalPadding,
                        bottom: 30,
                        right: horizontalPadding
                    ),
                    // 固定 260×360 卡片 + 列块居中（还原 GridItem(.fixed) + LazyVGrid .center）
                    fixedCardSize: GuessYouLikeGridCell.cardSize,
                    // NSCollectionView 抢占 first responder 后 onKeyPress 收不到 Escape，
                    // 从 NSScrollView.keyDown 兜底转发
                    onEscape: { viewModel.dismiss() }
                )
            }
        }
        .transition(.opacity.animation(.easeOut(duration: 0.25)))
        .preferredColorScheme(.dark)
        .onKeyPress(.escape) {
            viewModel.dismiss()
            return .handled
        }
        .onChange(of: viewModel.dealingProgress) { _, newValue in
            // 发牌触发时机：数据就绪 0.2s 后 dealingProgress 翻为 1.0
            if newValue >= 1.0 {
                gridReloadToken += 1
            }
        }
    }

    /// 配置网格 cell：读闭包执行时的最新 dealingProgress，
    /// cell 内部按 false→true 翻转决定是否播放发牌动画
    private func configureGridCell(_ cell: ExploreGridItem, _ index: Int) {
        guard let cell = cell as? GuessYouLikeGridCell,
              index < viewModel.items.count else { return }
        let item = viewModel.items[index]
        cell.configure(
            item: item,
            index: index,
            dealt: viewModel.dealingProgress >= 1.0,
            onDetail: { _ in onDetail(item) },
            onDownload: { _ in onDownload(item) }
        )
    }
}
