import SwiftUI

// MARK: - 竖版动漫卡片

struct AnimePortraitCard: View {
    let anime: AnimeSearchResult
    var cardWidth: CGFloat? = nil
    var cardHeight: CGFloat? = nil
    var onTap: () -> Void = {}

    @State private var isHovered = false

    private let cornerRadius: CGFloat = 14
    
    // 静态形状缓存
    private static let cardShape = RoundedRectangle(cornerRadius: 14, style: .continuous)

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                // 图片区域 - 竖版长方形
                ZStack(alignment: .topTrailing) {
                    // 图片层
                    GeometryReader { geometry in
                        OptimizedAsyncImage(
                            url: anime.coverURL.flatMap { URL(string: $0) },
                            priority: .medium
                        ) { image in
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: geometry.size.width, height: geometry.size.height)
                                .clipped()
                        } placeholder: {
                            ZStack {
                                Rectangle()
                                    .fill(Color.white.opacity(0.08))
                                Image(systemName: "tv")
                                    .font(.system(size: 40, weight: .light))
                                    .foregroundStyle(.white.opacity(0.25))
                            }
                        }
                    }

                    // 评分标签 - 右上角
                    if let rating = anime.rating, !rating.isEmpty {
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
                    Text(anime.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95))
                        .lineLimit(1)

                    if let latest = anime.latestEpisode, !latest.isEmpty {
                        HStack(spacing: 2) {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.white.opacity(0.5))
                            Text(latest)
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
                            .stroke(Color.white.opacity(isHovered ? 0.15 : 0.06), lineWidth: isHovered ? 1 : 0.5)
                    )
            )
            .clipShape(Self.cardShape)
            .shadow(
                color: isHovered ? Color.black.opacity(0.4) : Color.black.opacity(0.15),
                radius: isHovered ? 20 : 12,
                x: 0,
                y: isHovered ? 12 : 6
            )
            .scaleEffect(isHovered ? 1.02 : 1.0)
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: isHovered)
        .onHover { hovering in
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
