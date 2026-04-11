import SwiftUI

// MARK: - Shimmer 效果（iOS 风格闪光加载动画）
struct ShimmerModifier: ViewModifier {
    @State private var isAnimating = false
    
    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geometry in
                    LinearGradient(
                        gradient: Gradient(colors: [
                            Color.white.opacity(0),
                            Color.white.opacity(0.3),
                            Color.white.opacity(0)
                        ]),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geometry.size.width * 2)
                    .offset(x: isAnimating ? geometry.size.width : -geometry.size.width)
                }
                .mask(content)
            )
            .onAppear {
                withAnimation(
                    .linear(duration: 1.5)
                    .repeatForever(autoreverses: false)
                ) {
                    isAnimating = true
                }
            }
    }
}

extension View {
    @ViewBuilder
    func shimmer(isActive: Bool = true) -> some View {
        if isActive {
            self.modifier(ShimmerModifier())
        } else {
            self
        }
    }
}

// MARK: - 骨架屏卡片（iOS 风格）
struct SkeletonCard: View {
    let width: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat
    
    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.white.opacity(0.08))
            .frame(width: width, height: height)
            .shimmer()
    }
}

// MARK: - 壁纸卡片骨架屏（简化版）
struct WallpaperCardSkeleton: View {
    var cardWidth: CGFloat = LibraryCardMetrics.cardWidth

    // 与真实卡片一致的高度
    private var imageHeight: CGFloat { LibraryCardMetrics.thumbnailHeight }
    private var infoHeight: CGFloat { 44 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 图片区域骨架 - 深蓝色渐变
            LinearGradient(
                colors: [Color(hex: "1C2431"), Color(hex: "233B5A"), Color(hex: "14181F")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .frame(width: cardWidth, height: imageHeight)
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: 14,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 14,
                    style: .continuous
                )
            )
            .shimmer()

            // 底部信息栏骨架 - 简化占位
            HStack {
                // 左侧标题占位
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 100, height: 12)

                Spacer()

                // 右侧统计占位
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 60, height: 12)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(width: cardWidth, height: infoHeight)
            .background(Color.black.opacity(0.46))
        }
        .frame(width: cardWidth)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }
}

// MARK: - Hero 区域骨架屏
struct HeroSkeletonView: View {
    var height: CGFloat = 450
    
    var body: some View {
        ZStack {
            // 主图骨架 - 使用渐变色避免纯黑
            LinearGradient(
                colors: [
                    Color(hex: "232338"),
                    Color(hex: "1a1a2e"),
                    Color(hex: "12121f")
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .shimmer()

            // 底部信息面板骨架
            VStack(alignment: .leading, spacing: 18) {
                // eyebrow 骨架
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 80, height: 13)
                    .shimmer()

                // 大标题骨架
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.white.opacity(0.11))
                    .frame(width: 300, height: 46)
                    .shimmer()

                // 元数据行骨架
                HStack(spacing: 8) {
                    ForEach(0..<4, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.white.opacity(0.07))
                            .frame(width: i == 3 ? 50 : 70, height: 14)
                            .shimmer()
                    }
                }

                // 按钮行骨架
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 22)
                        .fill(Color.white.opacity(0.09))
                        .frame(width: 130, height: 44)
                        .shimmer()

                    RoundedRectangle(cornerRadius: 22)
                        .fill(Color.white.opacity(0.07))
                        .frame(width: 80, height: 44)
                        .shimmer()
                }
            }
            .frame(maxWidth: 520, alignment: .leading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.leading, 112)
            .padding(.trailing, 96)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
    }
}

// MARK: - 网格加载骨架屏
struct WallpaperGridSkeleton: View {
    /// 与探索页一致：按可用宽度计算 2…4 列
    var contentWidth: CGFloat = 800

    private var columns: [GridItem] {
        ExploreGridLayout.columns(for: contentWidth)
    }

    /// 与 WallpaperGridConfig 一致，根据可用宽度动态计算卡片宽度
    private var cardWidth: CGFloat {
        let columnCount = ExploreGridLayout.columnCount(for: contentWidth)
        let spacing = ExploreGridLayout.spacing
        let totalSpacing = spacing * CGFloat(columnCount - 1)
        return floor((contentWidth - totalSpacing) / CGFloat(columnCount))
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: ExploreGridLayout.spacing) {
            ForEach(0..<8, id: \.self) { _ in
                WallpaperCardSkeleton(cardWidth: cardWidth)
            }
        }
    }
}

// MARK: - 媒体卡片骨架屏
struct MediaCardSkeleton: View {
    var cardWidth: CGFloat = LibraryCardMetrics.cardWidth

    // 固定比例 16:10，与 SimpleMediaCard 一致
    private var imageHeight: CGFloat { cardWidth * 0.625 }
    private var infoHeight: CGFloat { 44 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 视频缩略图区域骨架
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .shimmer()

                // 播放按钮骨架
                Circle()
                    .fill(Color.white.opacity(0.1))
                    .frame(width: 36, height: 36)
                    .shimmer()
            }
            .frame(width: cardWidth, height: imageHeight)

            // 信息栏骨架
            HStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 80, height: 12)

                Spacer()

                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 50, height: 12)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(width: cardWidth, height: infoHeight)
        }
        .frame(width: cardWidth)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.03))
        )
    }
}

// MARK: - 媒体网格骨架屏
struct MediaGridSkeleton: View {
    var contentWidth: CGFloat = 800

    private var columns: [GridItem] {
        ExploreGridLayout.columns(for: contentWidth)
    }

    /// 与 MediaExploreContentView GridConfig 一致，根据可用宽度动态计算卡片宽度
    private var cardWidth: CGFloat {
        let columnCount = ExploreGridLayout.columnCount(for: contentWidth)
        let spacing = ExploreGridLayout.spacing
        let totalSpacing = spacing * CGFloat(columnCount - 1)
        return floor((contentWidth - totalSpacing) / CGFloat(columnCount))
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: ExploreGridLayout.spacing) {
            ForEach(0..<8, id: \.self) { _ in
                MediaCardSkeleton(cardWidth: cardWidth)
            }
        }
    }
}

// MARK: - 水平滚动骨架屏
struct HorizontalScrollSkeleton: View {
    var body: some View {
        HStack(spacing: 18) {
            ForEach(0..<5, id: \.self) { _ in
                SkeletonCard(width: 278, height: 158, cornerRadius: 18)
            }
        }
    }
}

// MARK: - 内容渐入动画修饰器
struct ContentTransitionModifier: ViewModifier {
    @State private var opacity: Double = 0
    @State private var offset: CGFloat = 20
    let delay: Double
    let duration: Double
    
    func body(content: Content) -> some View {
        content
            .opacity(opacity)
            .offset(y: offset)
            .onAppear {
                withAnimation(
                    .spring(response: 0.5, dampingFraction: 0.8)
                    .delay(delay)
                ) {
                    opacity = 1
                    offset = 0
                }
            }
    }
}

extension View {
    func fadeIn(delay: Double = 0, duration: Double = 0.5) -> some View {
        self.modifier(ContentTransitionModifier(delay: delay, duration: duration))
    }
}

// MARK: - 优化的加载状态视图（带骨架屏）
struct OptimizedLoadingView: View {
    let message: String
    let showSkeleton: Bool
    
    init(message: String = t("loading"), showSkeleton: Bool = true) {
        self.message = message
        self.showSkeleton = showSkeleton
    }
    
    var body: some View {
        if showSkeleton {
            VStack(spacing: 20) {
                CustomProgressView(tint: LiquidGlassColors.primaryPink)
                    .scaleEffect(1.2)
                
                Text(message)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(LiquidGlassColors.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // 简单的 loading spinner
            VStack(spacing: 16) {
                CustomProgressView(tint: LiquidGlassColors.primaryPink)
                
                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LiquidGlassColors.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - 分页加载指示器（iOS 风格）
struct PaginationLoadingView: View {
    var body: some View {
        HStack(spacing: 12) {
            CustomProgressView(tint: LiquidGlassColors.primaryPink)

            Text(t("loadMore"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(LiquidGlassColors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }
}

// MARK: - 🍎 分页骨架脉冲行（滚动到底部时的占位动画）

/// 通用分页加载骨架脉冲占位符
/// 在 LazyVGrid 底部追加一行与真实卡片同尺寸的骨架卡片，
/// 配合 shimmer 脉冲效果，让用户感知到"正在加载更多内容"
struct PaginationSkeletonRow: View {
    /// 卡片数量（通常一行的列数）
    let cardCount: Int
    /// 单张卡片的宽度
    let cardWidth: CGFloat
    /// 单张卡片的高度
    let cardHeight: CGFloat
    /// 列间距
    let spacing: CGFloat
    /// 卡片圆角
    let cornerRadius: CGFloat
    /// 骨架类型
    let style: SkeletonRowStyle

    enum SkeletonRowStyle {
        case wallpaper   // 壁纸卡片：顶部图片 + 底部文字栏
        case media       // 媒体卡片：同壁纸但可能有播放按钮
        case anime       // 动漫卡片：竖版比例 + 标题+集数
    }

    init(
        cardCount: Int,
        cardWidth: CGFloat,
        cardHeight: CGFloat,
        spacing: CGFloat = 16,
        cornerRadius: CGFloat = 16,
        style: SkeletonRowStyle = .wallpaper
    ) {
        self.cardCount = cardCount
        self.cardWidth = cardWidth
        self.cardHeight = cardHeight
        self.spacing = spacing
        self.cornerRadius = cornerRadius
        self.style = style
    }

    var body: some View {
        // 使用固定布局的 HStack 确保尺寸精确匹配真实卡片
        HStack(spacing: spacing) {
            ForEach(0..<cardCount, id: \.self) { _ in
                skeletonCard
                    .frame(width: cardWidth, height: cardHeight)
            }
        }
    }

    @ViewBuilder
    private var skeletonCard: some View {
        switch style {
        case .wallpaper, .media:
            WallpaperPaginationSkeleton(cornerRadius: cornerRadius)
        case .anime:
            AnimePaginationSkeleton()
        }
    }
}

// MARK: - 壁纸/媒体分页骨架卡片

struct WallpaperPaginationSkeleton: View {
    let cornerRadius: CGFloat

    private static let thumbShape = UnevenRoundedRectangle(
        topLeadingRadius: 14,
        bottomLeadingRadius: 0,
        bottomTrailingRadius: 0,
        topTrailingRadius: 14,
        style: .continuous
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 图片区域骨架 - 渐变底色 + shimmer
            LinearGradient(
                colors: [Color(hex: "1C2431"), Color(hex: "233B5A"), Color(hex: "14181F")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .shimmer()

            // 底部信息栏骨架
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.07))
                    .frame(width: 90, height: 12)

                Spacer(minLength: 12)

                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.05))
                    .frame(width: 50, height: 12)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color.black.opacity(0.46))
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.05), lineWidth: 1)
        )
    }
}

// MARK: - 动漫分页骨架卡片

struct AnimePaginationSkeleton: View {
    var cardWidth: CGFloat = 160

    // 与 AnimePortraitCard 一致：固定比例 10:14
    private var imageHeight: CGFloat { cardWidth * 1.4 }
    private var infoHeight: CGFloat { 44 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 竖版图片骨架
            LinearGradient(
                colors: [Color(hex: "1C2431"), Color(hex: "233B5A"), Color(hex: "14181F")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .frame(width: cardWidth, height: imageHeight)
            .shimmer()

            // 信息栏骨架
            VStack(alignment: .leading, spacing: 4) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 100, height: 13)

                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.white.opacity(0.05))
                    .frame(width: 50, height: 10)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(width: cardWidth, height: infoHeight)
            .background(Color.black.opacity(0.46))
        }
        .frame(width: cardWidth)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.05), lineWidth: 0.5)
        )
    }
}

// MARK: - 脉冲式分页加载容器

/// 智能分页加载底部：显示骨架脉冲行 + 加载指示器
/// 替代原来的简单 PaginationLoadingView
struct PaginationSkeletonFooter: View {
    let isLoading: Bool
    let hasMorePages: Bool
    let skeletonRow: PaginationSkeletonRow?

    init(isLoading: Bool, hasMorePages: Bool = true, skeletonRow: PaginationSkeletonRow? = nil) {
        self.isLoading = isLoading
        self.hasMorePages = hasMorePages
        self.skeletonRow = skeletonRow
    }

    var body: some View {
        if isLoading && hasMorePages {
            // 加载中：显示骨架脉冲行 + spinner
            VStack(spacing: 8) {
                if let row = skeletonRow {
                    row
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                PaginationLoadingView()
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            .animation(.easeOut(duration: 0.25), value: isLoading)
        } else if !hasMorePages && !isLoading {
            // 全部加载完毕：简洁提示
            HStack(spacing: 6) {
                Rectangle()
                    .fill(Color.white.opacity(0.15))
                    .frame(width: 32, height: 1)

                Text("— \(t("noMore")) —")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.25))

                Rectangle()
                    .fill(Color.white.opacity(0.15))
                    .frame(width: 32, height: 1)
            }
            .padding(.vertical, 24)
            .transition(.opacity)
        } else {
            Color.clear.frame(height: 20)
        }
    }
}

// MARK: - 分页加载底部脉冲色块

/// 轻量级分页加载占位：一个带 shimmer 脉冲的半透明渐变色块，
/// 放在 LazyVGrid 内部 ForEach 末尾，跨整行显示（.gridCellColumns）。
/// 占据 grid 布局空间 → scroll view 正确计算内容高度 → 新数据不需要额外滚动。
/// 数据加载完成后被新卡片推走，或切换为"到底了"提示。
struct PaginationShimmerOverlay: View {
    let isLoading: Bool
    let hasMorePages: Bool

    init(isLoading: Bool, hasMorePages: Bool = true) {
        self.isLoading = isLoading
        self.hasMorePages = hasMorePages
    }

    var body: some View {
        if isLoading && hasMorePages {
            shimmerBlock
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .animation(.easeOut(duration: 0.3), value: isLoading)
        } else if !hasMorePages && !isLoading {
            HStack(spacing: 6) {
                Rectangle()
                    .fill(Color.white.opacity(0.15))
                    .frame(width: 32, height: 1)

                Text("— \(t("noMore")) —")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.25))

                Rectangle()
                    .fill(Color.white.opacity(0.15))
                    .frame(width: 32, height: 1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .transition(.opacity)
        } else {
            Color.clear.frame(height: 20)
        }
    }

    /// 核心脉冲色块：静态渐变 + 极轻量呼吸，零持续重绘开销
    private var shimmerBlock: some View {
        // 渐变底色：透明 → 暗色，暗示"下方还有内容在加载"
        LinearGradient(
            colors: [
                Color.clear,
                Color.black.opacity(0.20),
                Color.black.opacity(0.35)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        // 用已有 ShimmerModifier（overlay+mask 方案，GPU 层面扫光）
        // ShimmerModifier 内部是 .repeatForever 但通过 GeometryReader mask 实现，
        // SwiftUI 不会每帧重建 body，性能远优于 @State offset 动画
        .shimmer()
        .frame(height: 260)
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 20,
                topTrailingRadius: 20,
                style: .continuous
            )
        )
    }
}

// MARK: - 空状态动画视图
struct AnimatedEmptyState: View {
    let icon: String
    let title: String
    let subtitle: String
    
    @State private var isAnimating = false
    
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(LiquidGlassColors.textTertiary)
                .scaleEffect(isAnimating ? 1.1 : 1.0)
                .opacity(isAnimating ? 0.7 : 1.0)
            
            Text(title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(LiquidGlassColors.textPrimary)
            
            Text(subtitle)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(LiquidGlassColors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(
                .easeInOut(duration: 2.0)
                .repeatForever(autoreverses: true)
            ) {
                isAnimating = true
            }
        }
    }
}
