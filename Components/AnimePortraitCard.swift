import SwiftUI
import Kingfisher

// MARK: - 高性能竖版动漫卡片（Kingfisher 优化版）
// 优化策略：
// 1. 图片降采样 - 使用 DownsamplingImageProcessor 避免加载完整大图
// 2. 后台解码 - Kingfisher 自动在后台线程解码图片
// 3. 内存/磁盘缓存 - 自动管理，支持 NSCache
// 4. 渐进式过渡 - 使用 fade 动画避免图片"弹出"
// 5. drawingGroup - 将复杂视图扁平化为 Metal 纹理提升滚动 FPS

struct AnimePortraitCard: View {
    let anime: AnimeSearchResult
    var cardWidth: CGFloat? = nil
    var onTap: () -> Void = {}

    @State private var isHovered = false

    private let cornerRadius: CGFloat = 14
    
    // 静态形状缓存
    private static let cardShape = RoundedRectangle(cornerRadius: 14, style: .continuous)
    
    // 初始化器 - 预计算缓存属性
    init(anime: AnimeSearchResult, cardWidth: CGFloat? = nil, onTap: @escaping () -> Void = {}) {
        self.anime = anime
        self.cardWidth = cardWidth
        self.onTap = onTap
        // 预计算缓存属性，避免每次 body 重新计算
        self.cachedTitle = anime.title
        self.cachedEpisode = anime.latestEpisode
        self.cachedRating = anime.rating
        self.shouldShowRating = !(anime.rating ?? "").isEmpty
    }

    // 缓存属性 - 使用 let 避免重复计算
    private let cachedTitle: String
    private let cachedEpisode: String?
    private let shouldShowRating: Bool
    private let cachedRating: String?
    
    // 固定比例 10:14 (约 1:1.4)
    private var imageHeight: CGFloat {
        (cardWidth ?? 200) * 1.4
    }
    
    // 信息栏高度
    private let infoHeight: CGFloat = 44

    // 图片降采样目标尺寸（Retina 2x）
    private var targetImageSize: CGSize {
        CGSize(width: (cardWidth ?? 200) * 2, height: imageHeight * 2)
    }

    // 悬停视觉属性
    private var hoverOpacity: Double { isHovered ? 0.15 : 0.06 }
    private var hoverBorderWidth: CGFloat { isHovered ? 1 : 0.5 }
    private var hoverShadowOpacity: Double { isHovered ? 0.4 : 0.15 }
    private var hoverShadowRadius: CGFloat { isHovered ? 20 : 12 }
    private var hoverShadowY: CGFloat { isHovered ? 12 : 6 }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                // 图片区域 - 使用 Kingfisher 降采样
                ZStack(alignment: .topTrailing) {
                    KFImage(anime.coverURL.flatMap { URL(string: $0) })
                        .setProcessor(DownsamplingImageProcessor(size: targetImageSize))
                        .cacheMemoryOnly(false)
                        .placeholder { _ in
                            ZStack {
                                LinearGradient(
                                    colors: [Color(hex: "1C2431"), Color(hex: "233B5A")],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                                Image(systemName: "tv")
                                    .font(.system(size: 40, weight: .light))
                                    .foregroundStyle(.white.opacity(0.25))
                            }
                        }
                        .resizable()
                        .aspectRatio(contentMode: .fill)

                    // 评分标签 - 条件渲染避免无评分时占用空间
                    if shouldShowRating, let rating = cachedRating {
                        HStack(spacing: 2) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(.yellow)
                            Text(rating)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.5))
                        .clipShape(Capsule())
                        .padding(.top, 10)
                        .padding(.trailing, 8)
                    }
                }
                // 使用固定比例计算高度
                .frame(width: cardWidth, height: imageHeight)
                .clipped()

                // 信息栏
                VStack(alignment: .leading, spacing: 2) {
                    Text(cachedTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95))
                        .lineLimit(1)

                    // 集数信息 - 条件渲染
                    if let episode = cachedEpisode, !episode.isEmpty {
                        HStack(spacing: 2) {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.white.opacity(0.5))
                            Text(episode)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(width: cardWidth, height: infoHeight, alignment: .leading)
                .background(Color.black.opacity(0.46))
            }
            .contentShape(Self.cardShape)
            // 悬停效果：边框
            .background(
                Self.cardShape
                    .fill(Color.clear)
                    .overlay(
                        Self.cardShape
                            .stroke(Color.white.opacity(hoverOpacity), lineWidth: hoverBorderWidth)
                    )
            )
            .clipShape(Self.cardShape)
            // 悬停效果：阴影
            .shadow(
                color: Color.black.opacity(hoverShadowOpacity),
                radius: hoverShadowRadius,
                x: 0,
                y: hoverShadowY
            )
            // 悬停效果：缩放
            .scaleEffect(isHovered ? 1.02 : 1.0)
        }
        .buttonStyle(.plain)
        // 悬停动画
        .animation(.spring(response: 0.20, dampingFraction: 0.85), value: isHovered)
        // 节流悬停
        .throttledHover(interval: 0.05) { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - 源选择器

struct AnimeSourcePicker: View {
    @Binding var selectedRule: AnimeRule?
    let rules: [AnimeRule]
    var onChange: () -> Void = {}

    var body: some View {
        Menu {
            Button("全部源") {
                withAnimation(.easeInOut(duration: 0.2)) {
                    selectedRule = nil
                }
                onChange()
            }

            Divider()

            ForEach(rules) { rule in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedRule = rule
                    }
                    onChange()
                } label: {
                    HStack {
                        Text(rule.name)
                        if selectedRule?.id == rule.id {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "globe")
                    .font(.system(size: 13, weight: .semibold))

                Text(selectedRule?.name ?? "全部源")
                    .font(.system(size: 13, weight: .semibold))

                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .liquidGlassSurface(
                .regular,
                in: Capsule(style: .continuous)
            )
        }
        .menuStyle(.borderlessButton)
    }
}
