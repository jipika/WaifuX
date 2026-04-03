import SwiftUI
import Combine

// MARK: - 底部 Wallpaper Playing 控制条 (macOS 26 Liquid Glass 风格)
struct WallpaperPlayerBar: View {
    let wallpaper: Wallpaper?
    let isPlaying: Bool
    let isLiked: Bool  // 外部传入的收藏状态
    let onPlayPause: () -> Void
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onSpeedChange: () -> Void
    let onPlaylist: () -> Void
    let onLike: () -> Void
    let onMusic: () -> Void

    @State private var playbackSpeed: Double = 1.0
    @State private var isHoveringLike = false
    @State private var isHoveringPlaylist = false
    @State private var isHoveringMusic = false
    @State private var isHoveringSpeed = false

    var body: some View {
        HStack(spacing: 0) {
            // 左侧：壁纸信息
            WallpaperInfoView(wallpaper: wallpaper)
                .padding(.leading, 16)

            Spacer()

            // 中间：控制按钮
            ControlButtons(
                isPlaying: isPlaying,
                isLiked: isLiked,
                playbackSpeed: playbackSpeed,
                isHoveringLike: $isHoveringLike,
                isHoveringPlaylist: $isHoveringPlaylist,
                isHoveringMusic: $isHoveringMusic,
                isHoveringSpeed: $isHoveringSpeed,
                onPlaylist: onPlaylist,
                onLike: onLike,
                onMusic: onMusic,
                onPrevious: onPrevious,
                onPlayPause: onPlayPause,
                onNext: onNext,
                onSpeedChange: onSpeedChange
            )

            Spacer()

            // 右侧：占位（保持平衡）
            Color.clear
                .frame(width: 44 + 16)
        }
        .padding(.vertical, 12)
        .background(
            PlayerBarBackground()
        )
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }
}

// MARK: - 壁纸信息视图
private struct WallpaperInfoView: View {
    let wallpaper: Wallpaper?

    var body: some View {
        HStack(spacing: 12) {
            // 缩略图
            ThumbnailView(wallpaper: wallpaper)

            // 文字信息
            VStack(alignment: .leading, spacing: 4) {
                Text(t("player.nowPlaying"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(LiquidGlassColors.textSecondary)

                Text(wallpaper?.resolution ?? t("player.selectWallpaper"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LiquidGlassColors.textPrimary)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - 缩略图视图（优化版 - 增强玻璃效果）
private struct ThumbnailView: View {
    let wallpaper: Wallpaper?
    @State private var isHovered = false

    var body: some View {
        Group {
            if let wallpaper = wallpaper {
                OptimizedAsyncImage(url: wallpaper.smallThumbURL, priority: .low) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    PlaceholderView()
                }
            } else {
                PlaceholderView()
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            LiquidGlassColors.glassBorder,
                            LiquidGlassColors.glassBorder.opacity(0.3)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(
            color: Color.black.opacity(isHovered ? 0.3 : 0.2),
            radius: isHovered ? 12 : 8,
            y: isHovered ? 6 : 4
        )
        .scaleEffect(isHovered ? 1.05 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isHovered)
        .onHover { hovering in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - 占位视图
private struct PlaceholderView: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(LiquidGlassColors.glassWhiteSubtle)
            .overlay(
                Image(systemName: "photo")
                    .font(.system(size: 18))
                    .foregroundColor(LiquidGlassColors.textTertiary)
            )
    }
}

// MARK: - 错误占位视图
private struct ErrorPlaceholderView: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(LiquidGlassColors.glassWhiteSubtle)
            .overlay(
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 18))
                    .foregroundColor(LiquidGlassColors.warningOrange)
            )
    }
}

// MARK: - 控制按钮组
private struct ControlButtons: View {
    let isPlaying: Bool
    let isLiked: Bool
    let playbackSpeed: Double
    @Binding var isHoveringLike: Bool
    @Binding var isHoveringPlaylist: Bool
    @Binding var isHoveringMusic: Bool
    @Binding var isHoveringSpeed: Bool
    let onPlaylist: () -> Void
    let onLike: () -> Void
    let onMusic: () -> Void
    let onPrevious: () -> Void
    let onPlayPause: () -> Void
    let onNext: () -> Void
    let onSpeedChange: () -> Void

    var body: some View {
        HStack(spacing: 20) {
            // 播放列表按钮
            PlayerIconButton(
                icon: "rectangle.stack.fill",
                isHovered: $isHoveringPlaylist,
                tooltip: t("player.playlist")
            ) {
                onPlaylist()
            }

            // 收藏按钮
            LikeButton(isLiked: isLiked, isHovered: $isHoveringLike) {
                onLike()
            }

            // 音乐按钮
            PlayerIconButton(
                icon: "music.note",
                isHovered: $isHoveringMusic,
                tooltip: t("player.music")
            ) {
                onMusic()
            }

            // 分隔线
            GlassDivider()
                .frame(height: 24)

            // 上一首
            ControlButton(icon: "backward.fill", tooltip: t("player.previous")) {
                onPrevious()
            }

            // 播放/暂停
            PlayPauseButton(isPlaying: isPlaying) {
                onPlayPause()
            }

            // 下一首
            ControlButton(icon: "forward.fill", tooltip: t("player.next")) {
                onNext()
            }

            // 分隔线
            GlassDivider()
                .frame(height: 24)

            // 倍速按钮
            SpeedButton(
                speed: playbackSpeed,
                isHovered: $isHoveringSpeed
            ) {
                onSpeedChange()
            }
        }
    }
}

// MARK: - 播放器图标按钮（优化版 - Liquid Glass）
private struct PlayerIconButton: View {
    let icon: String
    @Binding var isHovered: Bool
    let tooltip: String
    let action: () -> Void
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(isHovered ? .white : LiquidGlassColors.textSecondary)
                .frame(width: 40, height: 40)
        }
        .buttonStyle(.plain)
        .liquidGlassSurface(
            isHovered ? .prominent : .subtle,
            in: Circle()
        )
        .scaleEffect(isPressed ? 0.92 : 1.0)
        .help(tooltip)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }
}

// MARK: - 收藏按钮（优化版 - 增强视觉效果）
private struct LikeButton: View {
    let isLiked: Bool
    @Binding var isHovered: Bool
    let action: () -> Void
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            Image(systemName: isLiked ? "heart.fill" : "heart")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(isLiked ? LiquidGlassColors.primaryPink : (isHovered ? .white : LiquidGlassColors.textSecondary))
                .frame(width: 40, height: 40)
        }
        .buttonStyle(.plain)
        .liquidGlassSurface(
            isLiked ? .max : (isHovered ? .prominent : .subtle),
            tint: isLiked ? LiquidGlassColors.primaryPink.opacity(0.2) : nil,
            in: Circle()
        )
        .shadow(
            color: isLiked ? LiquidGlassColors.primaryPink.opacity(0.3) : Color.clear,
            radius: isLiked ? 12 : 0,
            y: 4
        )
        .scaleEffect(isPressed ? 0.88 : (isLiked ? 1.1 : 1.0))
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isLiked)
        .animation(.easeInOut(duration: 0.1), value: isPressed)
        .help(isLiked ? t("player.unfavorite") : t("player.favorite"))
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }
}

// MARK: - 控制按钮（优化版 - Liquid Glass）
private struct ControlButton: View {
    let icon: String
    let tooltip: String
    let action: () -> Void
    @State private var isHovered = false
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(isHovered ? .white : LiquidGlassColors.textPrimary)
                .frame(width: 40, height: 40)
        }
        .buttonStyle(.plain)
        .liquidGlassSurface(
            isHovered ? .prominent : .subtle,
            in: Circle()
        )
        .scaleEffect(isPressed ? 0.92 : (isHovered ? 1.05 : 1.0))
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .help(tooltip)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }
}

// MARK: - 播放/暂停按钮（优化版 - 增强视觉冲击力）
private struct PlayPauseButton: View {
    let isPlaying: Bool
    let action: () -> Void
    @State private var isHovered = false
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    LiquidGlassColors.primaryPink,
                                    LiquidGlassColors.primaryPink.opacity(0.85),
                                    LiquidGlassColors.secondaryViolet.opacity(0.7)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .overlay(
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.5),
                                    Color.white.opacity(0.2),
                                    Color.white.opacity(0.05)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.5
                        )
                )
                .shadow(
                    color: LiquidGlassColors.primaryPink.opacity(isHovered ? 0.6 : 0.4),
                    radius: isHovered ? 20 : 15,
                    y: isHovered ? 8 : 5
                )
        }
        .buttonStyle(.plain)
        .help(isPlaying ? t("player.pause") : t("player.play"))
        .scaleEffect(isPressed ? 0.92 : (isHovered ? 1.05 : 1.0))
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isHovered)
        .animation(.easeInOut(duration: 0.1), value: isPressed)
        .onHover { hovering in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                isHovered = hovering
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }
}

// MARK: - 倍速按钮（优化版 - Liquid Glass）
private struct SpeedButton: View {
    let speed: Double
    @Binding var isHovered: Bool
    let action: () -> Void
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            Text("\(String(format: "%.1f", speed))×")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(isHovered ? .white : LiquidGlassColors.textSecondary)
                .frame(width: 40, height: 28)
        }
        .buttonStyle(.plain)
        .liquidGlassSurface(
            isHovered ? .prominent : .subtle,
            tint: isHovered ? LiquidGlassColors.tertiaryBlue.opacity(0.15) : nil,
            in: Capsule()
        )
        .scaleEffect(isPressed ? 0.92 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .help(t("player.speed"))
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }
}

// MARK: - 播放器背景（优化版 - 增强Liquid Glass）
private struct PlayerBarBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
            .fill(.thickMaterial)
            .opacity(0.92)
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                LiquidGlassColors.glassBorder,
                                LiquidGlassColors.glassBorder.opacity(0.3)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.5
                    )
            )
            .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
    }
}

// MARK: - 迷你播放器条（简化版）
struct MiniPlayerBar: View {
    let wallpaper: Wallpaper?
    let onTap: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // 缩略图
                MiniThumbnailView(wallpaper: wallpaper)

                // 文字信息
                VStack(alignment: .leading, spacing: 2) {
                    Text(t("player.nowPlaying"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(LiquidGlassColors.textSecondary)

                    Text(wallpaper?.resolution ?? t("player.selectWallpaper"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(LiquidGlassColors.textPrimary)
                        .lineLimit(1)
                }

                Spacer()

                // 播放图标
                PlayIndicator()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                MiniPlayerBackground(isHovered: isHovered)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - 迷你缩略图
private struct MiniThumbnailView: View {
    let wallpaper: Wallpaper?

    var body: some View {
        Group {
            if let wallpaper = wallpaper {
                OptimizedAsyncImage(url: wallpaper.smallThumbURL, priority: .low) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    MiniPlaceholderView()
                }
            } else {
                MiniPlaceholderView()
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - 迷你占位视图
private struct MiniPlaceholderView: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(LiquidGlassColors.glassWhiteSubtle)
            .overlay(
                Image(systemName: "photo")
                    .font(.system(size: 14))
                    .foregroundColor(LiquidGlassColors.textTertiary)
            )
    }
}

// MARK: - 播放指示器
private struct PlayIndicator: View {
    var body: some View {
        Image(systemName: "play.fill")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background(
                Circle()
                    .fill(LiquidGlassColors.primaryPink)
            )
            .shadow(
                color: LiquidGlassColors.primaryPink.opacity(0.4),
                radius: 6,
                y: 2
            )
    }
}

// MARK: - 迷你播放器背景 (使用 DesignSystem)
private struct MiniPlayerBackground: View {
    let isHovered: Bool

    var body: some View {
        LiquidGlassCard(
            padding: 0,
            cornerRadius: 16,
            variant: isHovered ? .interactive : .regular
        ) {
            Color.clear
        }
    }
}
