import SwiftUI

// MARK: - 竖版动漫卡片

struct AnimePortraitCard: View {
    let anime: AnimeSearchResult
    var onTap: () -> Void = {}

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 海报区域 - 竖版 2:3
            ZStack(alignment: .bottomTrailing) {
                OptimizedAsyncImage(
                    url: anime.coverURL.flatMap { URL(string: $0) },
                    priority: .medium
                ) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle()
                        .fill(Color.white.opacity(0.1))
                        .overlay(
                            Image(systemName: "tv")
                                .font(.system(size: 32))
                                .foregroundStyle(.white.opacity(0.3))
                        )
                }
                .aspectRatio(2/3, contentMode: .fill)
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                // 源标签
                Text(anime.sourceName)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color.black.opacity(0.6))
                    )
                    .padding(8)
            }
            .frame(height: 200)

            // 信息栏
            VStack(alignment: .leading, spacing: 4) {
                Text(anime.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)

                if let latest = anime.latestEpisode, !latest.isEmpty {
                    Text(latest)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black.opacity(0.46))
        }
        .liquidGlassSurface(.prominent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .scaleEffect(isHovered ? 1.03 : 1.0)
        .shadow(
            color: isHovered ? Color(hex: "FF6B9D").opacity(0.3) : Color.black.opacity(0.2),
            radius: isHovered ? 16 : 8,
            x: 0,
            y: isHovered ? 8 : 4
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
        .onTapGesture {
            onTap()
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
