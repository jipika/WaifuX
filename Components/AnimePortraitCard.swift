import SwiftUI

// MARK: - 竖版动漫卡片

struct AnimePortraitCard: View {
    let anime: AnimeSearchResult
    var cardWidth: CGFloat? = nil
    var cardHeight: CGFloat? = nil
    var onTap: () -> Void = {}

    @State private var isHovered = false

    private let cornerRadius: CGFloat = 14
    
    // 静态形状缓存（避免每次 body 重新创建）
    private static let cardShape = RoundedRectangle(cornerRadius: 14, style: .continuous)

    // 缓存标题和集数，避免每次 body 重新读取
    private var cachedTitle: String { anime.title }
    private var cachedEpisode: String? { anime.latestEpisode }
    private var shouldShowRating: Bool { !(anime.rating ?? "").isEmpty }
    private var cachedRating: String? { anime.rating }

    // 悬停时的视觉属性 - 预计算避免条件分支
    private var hoverOpacity: Double { isHovered ? 0.15 : 0.06 }
    private var hoverBorderWidth: CGFloat { isHovered ? 1 : 0.5 }
    private var hoverShadowOpacity: Double { isHovered ? 0.4 : 0.15 }
    private var hoverShadowRadius: CGFloat { isHovered ? 20 : 12 }
    private var hoverShadowY: CGFloat { isHovered ? 12 : 6 }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                // 图片区域 - 竖版长方形，直接使用固定 frame 移除 GeometryReader
                ZStack(alignment: .topTrailing) {
                    OptimizedAsyncImage(
                        url: anime.coverURL.flatMap { URL(string: $0) },
                        priority: .medium
                    ) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } placeholder: {
                        ZStack {
                            Rectangle()
                                .fill(Color.white.opacity(0.08))
                            Image(systemName: "tv")
                                .font(.system(size: 40, weight: .light))
                                .foregroundStyle(.white.opacity(0.25))
                        }
                    }

                    // 评分标签 - 右上角
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
                .frame(width: cardWidth, height: cardHeight ?? 300)
                .clipped()

                // 信息栏 - 深色半透明背景
                VStack(alignment: .leading, spacing: 4) {
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
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(width: cardWidth, alignment: .leading)
                .background(Color.black.opacity(0.46))
            }
            .frame(width: cardWidth)
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
        // iOS 风格悬停动画：快速弹簧响应 + 自然减速释放
        // response=0.20 快速响应，dampingFraction=0.85 微弹性（不晃动）
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
