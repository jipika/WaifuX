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
    // 移除 cardHeight 参数，使用固定比例
    var onTap: () -> Void = {}

    @State private var isHovered = false

    private let cornerRadius: CGFloat = 14
    
    // 静态形状缓存
    private static let cardShape = RoundedRectangle(cornerRadius: 14, style: .continuous)

    // 缓存属性
    private var cachedTitle: String { anime.title }
    private var cachedEpisode: String? { anime.latestEpisode }
    private var shouldShowRating: Bool { !(anime.rating ?? "").isEmpty }
    private var cachedRating: String? { anime.rating }
    
    // 固定比例 10:14 (约 1:1.4)
    private var imageHeight: CGFloat {
        (cardWidth ?? 200) * 1.4
    }
    
    // 信息栏高度
    private var infoHeight: CGFloat { 44 }

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
                        // 移除 cancelOnDisappear(false) 和 fade 避免问题
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

                    // 评分标签（始终渲染占位，避免高度不一致导致空白）
                    HStack(spacing: 2) {
                        if shouldShowRating, let rating = cachedRating {
                            Image(systemName: "star.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(.yellow)
                            Text(rating)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                    }
                    .padding(.horizontal, shouldShowRating ? 6 : 0)
                    .padding(.vertical, shouldShowRating ? 4 : 0)
                    .background(shouldShowRating ? .black.opacity(0.5) : .clear)
                    .clipShape(Capsule())
                    .padding(.top, 10)
                    .padding(.trailing, 8)
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

                    if let episode = cachedEpisode, !episode.isEmpty {
                        HStack(spacing: 2) {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.white.opacity(0.5))
                            Text(episode)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    } else {
                        Color.clear.frame(height: 12)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(width: cardWidth, height: infoHeight, alignment: .leading)
                .background(Color.black.opacity(0.46))
            }
            .contentShape(Self.cardShape)
            .background(
                Self.cardShape
                    .fill(Color.clear)
                    .overlay(
                        Self.cardShape
                            .stroke(Color.white.opacity(hoverOpacity), lineWidth: hoverBorderWidth)
                    )
            )
            .clipShape(Self.cardShape)
            .shadow(
                color: Color.black.opacity(hoverShadowOpacity),
                radius: hoverShadowRadius,
                x: 0,
                y: hoverShadowY
            )
            .scaleEffect(isHovered ? 1.02 : 1.0)
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.20, dampingFraction: 0.85), value: isHovered)
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
