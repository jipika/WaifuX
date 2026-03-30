import SwiftUI

// MARK: - 液态玻璃壁纸卡片 (macOS 26 超写实玻璃风格)
struct LiquidGlassWallpaperCard: View {
    let wallpaper: Wallpaper
    let rank: Int?
    let onTap: () -> Void

    @State private var isHovered = false
    @State private var imageRetryId = UUID()

    private let cornerRadius: CGFloat = 20

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 0) {
                // 图片区域 - 液态玻璃边框
                ZStack {
                    OptimizedAsyncImage(url: wallpaper.smallThumbURL, priority: .medium) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } placeholder: {
                        ZStack {
                            Rectangle()
                                .fill(LiquidGlassColors.glassWhiteSubtle)
                            CustomProgressView(tint: LiquidGlassColors.primaryPink)
                        }
                    }
                    .id(imageRetryId)
                    .frame(height: 160)
                    .clipped()
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(isHovered ? 0.4 : 0.2),
                                    Color.white.opacity(isHovered ? 0.2 : 0.1),
                                    Color.white.opacity(0.05)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: isHovered ? 1.5 : 0.5
                        )
                )

                // 信息栏 - 液态玻璃效果
                HStack {
                    if let rank = rank {
                        Text("#\(rank)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(LiquidGlassColors.primaryPink)
                    }
                    Text(wallpaper.resolution)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(LiquidGlassColors.textTertiary)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .liquidGlassSurface(
                .prominent,
                tint: LiquidGlassColors.primaryPink.opacity(0.08),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .shadow(
                color: isHovered ? LiquidGlassColors.primaryPink.opacity(0.3) : .black.opacity(0.25),
                radius: isHovered ? 25 : 12,
                y: isHovered ? 12 : 6
            )
            .scaleEffect(isHovered ? 1.03 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { isHovered = hovering }
        }
        .help(wallpaper.resolution)
    }

    // MARK: - 加载失败占位图
    private var failurePlaceholder: some View {
        ZStack {
            Rectangle()
                .fill(LiquidGlassColors.glassWhiteSubtle)
            VStack(spacing: 8) {
                Image(systemName: "photo")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(LiquidGlassColors.textTertiary)
                Text("TAP TO RETRY")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(LiquidGlassColors.textTertiary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            imageRetryId = UUID()
        }
    }
}

// MARK: - 液态玻璃精选轮播卡片 (macOS 26 风格)
struct LiquidGlassCarouselCard: View {
    let wallpaper: Wallpaper
    let onTap: () -> Void

    @State private var isHovered = false

    private let cornerRadius: CGFloat = 28

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .bottomLeading) {
                // 图片
                OptimizedAsyncImage(url: wallpaper.thumbURL, priority: .medium) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle()
                        .fill(LiquidGlassColors.glassWhiteSubtle)
                        .overlay {
                            Image(systemName: "photo")
                                .font(.system(size: 32, weight: .light))
                                .foregroundStyle(LiquidGlassColors.textTertiary)
                        }
                }
                .frame(width: 340, height: 210)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .scaleEffect(isHovered ? 1.04 : 1.0)

                // 多层渐变遮罩 - 液态玻璃深度效果
                LinearGradient(
                    colors: [
                        .clear,
                        .black.opacity(0.3),
                        .black.opacity(0.6),
                        .black.opacity(0.8)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))

                // 文字信息
                VStack(alignment: .leading, spacing: 4) {
                    Text(wallpaper.resolution)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)

                    Text(wallpaper.category.uppercased())
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .padding(16)
            }
            .detailGlassCarouselChrome(
                cornerRadius: cornerRadius,
                tint: LiquidGlassColors.primaryPink.opacity(0.06),
                level: .prominent
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - 液态玻璃精选壁纸卡片 (保留兼容性)
struct LiquidGlassFeaturedCard: View {
    let wallpaper: Wallpaper
    let onTap: () -> Void

    @State private var isHovered = false

    private let cornerRadius: CGFloat = 28

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .bottomLeading) {
                // 图片
                OptimizedAsyncImage(url: wallpaper.thumbURL, priority: .medium) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle()
                        .fill(LiquidGlassColors.glassWhiteSubtle)
                }
                .frame(width: 320, height: 200)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .scaleEffect(isHovered ? 1.03 : 1.0)

                // 渐变遮罩
                LinearGradient(
                    colors: [.clear, .black.opacity(0.7)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))

                // 发光边框
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(isHovered ? 0.4 : 0.2),
                                Color.white.opacity(0.1),
                                Color.clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: isHovered ? 1.5 : 0.5
                    )

                // 文字信息
                VStack(alignment: .leading, spacing: 4) {
                    Text(wallpaper.resolution)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .padding(12)
            }
            .shadow(
                color: isHovered ? LiquidGlassColors.primaryPink.opacity(0.3) : .black.opacity(0.3),
                radius: isHovered ? 25 : 15,
                y: isHovered ? 15 : 8
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { isHovered = hovering }
        }
    }
}

// MARK: - 液态玻璃紧凑壁纸卡片
struct LiquidGlassCompactWallpaperCard: View {
    let wallpaper: Wallpaper
    let onTap: () -> Void

    @State private var isHovered = false

    private let cornerRadius: CGFloat = 16

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .topTrailing) {
                OptimizedAsyncImage(url: wallpaper.smallThumbURL, priority: .low) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle()
                        .fill(LiquidGlassColors.glassWhiteSubtle)
                }
                .frame(height: 120)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))

                // 分辨率标签
                Text(wallpaper.resolution)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(.black.opacity(0.6))
                    )
                    .padding(6)
            }
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(isHovered ? 0.35 : 0.15),
                                Color.white.opacity(0.1)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: isHovered ? 1 : 0.5
                    )
            )
            .shadow(
                color: isHovered ? LiquidGlassColors.glowPink : .black.opacity(0.2),
                radius: isHovered ? 15 : 8,
                y: isHovered ? 8 : 4
            )
            .scaleEffect(isHovered ? 1.02 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) { isHovered = hovering }
        }
    }
}
