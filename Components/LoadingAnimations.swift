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
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 图片区域骨架 - 深蓝色渐变
            LinearGradient(
                colors: [Color(hex: "1C2431"), Color(hex: "233B5A"), Color(hex: "14181F")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .frame(height: 152)
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
            .background(Color.black.opacity(0.46))
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }
}

// MARK: - Hero 区域骨架屏
struct HeroSkeletonView: View {
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
            VStack {
                Spacer()
                
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 12) {
                        // 标题骨架
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.white.opacity(0.1))
                            .frame(width: 200, height: 16)
                            .shimmer()
                        
                        // 大标题骨架
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.white.opacity(0.12))
                            .frame(width: 280, height: 40)
                            .shimmer()
                        
                        // 按钮骨架
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 22)
                                .fill(Color.white.opacity(0.1))
                                .frame(width: 120, height: 44)
                                .shimmer()
                            
                            RoundedRectangle(cornerRadius: 22)
                                .fill(Color.white.opacity(0.08))
                                .frame(width: 80, height: 44)
                                .shimmer()
                        }
                    }
                    
                    Spacer()
                }
                .padding(.horizontal, 50)
                .padding(.bottom, 80)
            }
        }
    }
}

// MARK: - 网格加载骨架屏
struct WallpaperGridSkeleton: View {
    /// 与探索页一致：按可用宽度计算 2…4 列
    var contentWidth: CGFloat = 800

    private var columns: [GridItem] {
        ExploreGridLayout.columns(for: contentWidth)
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: ExploreGridLayout.spacing) {
            ForEach(0..<8, id: \.self) { _ in
                WallpaperCardSkeleton()
            }
        }
    }
}

// MARK: - 媒体卡片骨架屏
struct MediaCardSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 视频缩略图区域骨架
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .shimmer()
                
                // 播放按钮骨架
                Circle()
                    .fill(Color.white.opacity(0.1))
                    .frame(width: 48, height: 48)
                    .shimmer()
            }
            .frame(height: 160)
            
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
        }
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
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

    var body: some View {
        LazyVGrid(columns: columns, spacing: ExploreGridLayout.spacing) {
            ForEach(0..<8, id: \.self) { _ in
                MediaCardSkeleton()
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

// MARK: - 智能加载占位符（根据内容类型显示不同骨架）
enum SkeletonType {
    case card
    case hero
    case grid
    case horizontalScroll
    case text
    
    @ViewBuilder
    @MainActor
    var view: some View {
        switch self {
        case .card:
            WallpaperCardSkeleton()
        case .hero:
            HeroSkeletonView()
        case .grid:
            WallpaperGridSkeleton()
        case .horizontalScroll:
            HorizontalScrollSkeleton()
        case .text:
            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 200, height: 16)
                    .shimmer()
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 150, height: 12)
                    .shimmer()
            }
        }
    }
}

// MARK: - 渐进式加载图片视图（带骨架屏过渡）
struct ProgressiveImageWithSkeleton<Content: View>: View {
    let url: URL?
    let skeletonType: SkeletonType
    let priority: TaskPriority
    @ViewBuilder let content: (Image) -> Content
    
    private let loader = ImageLoader.shared
    @State private var image: NSImage?
    @State private var isVisible = false
    @State private var hasStartedLoading = false
    
    init(
        url: URL?,
        skeletonType: SkeletonType = .card,
        priority: TaskPriority = .medium,
        @ViewBuilder content: @escaping (Image) -> Content
    ) {
        self.url = url
        self.skeletonType = skeletonType
        self.priority = priority
        self.content = content
    }
    
    var body: some View {
        ZStack {
            if let image = image {
                content(Image(nsImage: image))
                    .transition(.opacity.combined(with: .scale(scale: 1.02)))
            } else {
                skeletonType.view
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: image != nil)
        .onAppear {
            isVisible = true
            loadImage()
        }
        .onDisappear {
            isVisible = false
            cancelLoad()
        }
        .onChange(of: url) { _, _ in
            image = nil
            hasStartedLoading = false
            loadImage()
        }
    }
    
    private func loadImage() {
        guard let url = url, isVisible, !hasStartedLoading else { return }
        hasStartedLoading = true
        
        Task {
            if let loadedImage = await loader.loadImage(from: url, priority: priority) {
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.35)) {
                        self.image = loadedImage
                    }
                }
            }
        }
    }
    
    private func cancelLoad() {
        guard let url = url else { return }
        loader.cancelLoad(for: url)
        hasStartedLoading = false
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
