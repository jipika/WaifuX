import SwiftUI
import Kingfisher

// MARK: - Card Metrics

public enum LibraryCardMetrics {
    public static let cardWidth: CGFloat = 260
    public static let thumbnailHeight: CGFloat = 180
}

// MARK: - Media Video Card

public struct MediaVideoCard: View {
    let item: MediaItem
    var badgeText: String = ""
    var accent: Color = LiquidGlassColors.secondaryViolet
    let isEditing: Bool
    let isSelected: Bool
    var progress: Double? = nil
    var progressTint: Color? = nil
    var progressLabel: String? = nil
    let action: () -> Void

    @State private var isHovered = false

    public var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                // 图片区域 - 单独裁剪
                ZStack {
                    KFImage(item.thumbnailURL)
                        .fade(duration: 0.3)
                        .placeholder { _ in
                            SkeletonCard(
                                width: LibraryCardMetrics.cardWidth,
                                height: LibraryCardMetrics.thumbnailHeight,
                                cornerRadius: 0
                            )
                        }
                        .resizable()
                        .scaledToFill()
                        .frame(
                            width: LibraryCardMetrics.cardWidth,
                            height: LibraryCardMetrics.thumbnailHeight
                        )
                        .clipped()

                    // 左上角复选框（编辑模式下显示）
                    if isEditing {
                        VStack {
                            HStack {
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 22, weight: .semibold))
                                    .foregroundStyle(isSelected ? accent : .white.opacity(0.8))
                                    .background(
                                        Circle()
                                            .fill(isSelected ? .white : Color.black.opacity(0.4))
                                            .frame(width: 20, height: 20)
                                    )
                                    .padding(12)

                                Spacer()
                            }
                            Spacer()
                        }
                    }

                    // 右上角标签（非编辑模式下显示）
                    if !isEditing && !badgeText.isEmpty {
                        Text(badgeText)
                            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.82))
                            .padding(.horizontal, 10)
                            .frame(height: 22)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color.black.opacity(0.3))
                            )
                            .padding(12)
                    }

                    // 选中时的遮罩
                    if isEditing && isSelected {
                        Color.black.opacity(0.3)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }

                // 信息区域
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 14.5, weight: .bold))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)

                    Text(item.subtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.56))
                        .lineLimit(1)

                    // 未完成时显示进度块
                    if let progress, progress < 1.0 {
                        DownloadCardProgressBlock(
                            progress: progress,
                            label: progressLabel ?? t("status.downloading"),
                            tint: progressTint ?? accent
                        )
                        .padding(.top, 6)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(width: LibraryCardMetrics.cardWidth, alignment: .leading)
            }
            .frame(width: LibraryCardMetrics.cardWidth, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color(hex: "1A1D24").opacity(0.6))
            )
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: isHovered ? Color.black.opacity(0.3) : .clear, radius: isHovered ? 12 : 0, x: 0, y: isHovered ? 4 : 0)
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .animation(.easeOut(duration: 0.2), value: isHovered)
        .throttledHover(interval: 0.05) { hovering in
            if !isEditing {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Wallpaper Edit Card

public struct WallpaperEditCard: View {
    let wallpaper: Wallpaper
    var accent: Color = LiquidGlassColors.primaryPink
    let isEditing: Bool
    let isSelected: Bool
    var downloadDate: Date? = nil
    var progress: Double? = nil
    var progressTint: Color? = nil
    var progressLabel: String? = nil
    let action: () -> Void

    @State private var isHovered = false

    public var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                // 图片区域
                ZStack {
                    KFImage(wallpaper.thumbURL ?? wallpaper.smallThumbURL)
                        .fade(duration: 0.3)
                        .placeholder { _ in
                            SkeletonCard(
                                width: LibraryCardMetrics.cardWidth,
                                height: LibraryCardMetrics.thumbnailHeight,
                                cornerRadius: 0
                            )
                        }
                        .resizable()
                        .scaledToFill()
                        .frame(
                            width: LibraryCardMetrics.cardWidth,
                            height: LibraryCardMetrics.thumbnailHeight
                        )
                        .clipped()

                    if !isEditing {
                        VStack {
                            topMetadataRow
                            Spacer()
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }

                    // 左上角复选框（编辑模式下显示）
                    if isEditing {
                        VStack {
                            HStack {
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 22, weight: .semibold))
                                    .foregroundStyle(isSelected ? accent : .white.opacity(0.8))
                                    .background(
                                        Circle()
                                            .fill(isSelected ? .white : Color.black.opacity(0.4))
                                            .frame(width: 20, height: 20)
                                    )
                                    .padding(12)

                                Spacer()
                            }
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }

                    // 选中时的遮罩
                    if isEditing && isSelected {
                        Color.black.opacity(0.3)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }

                // 信息区域
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Text(wallpaper.uploader?.username ?? wallpaper.categoryDisplayName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .lineLimit(1)
                            .layoutPriority(1)

                        Spacer(minLength: 12)

                        trailingMetadataRow
                    }

                    // 未完成时显示进度块
                    if let progress, progress < 1.0 {
                        DownloadCardProgressBlock(
                            progress: progress,
                            label: progressLabel ?? t("status.downloading"),
                            tint: progressTint ?? accent
                        )
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(width: LibraryCardMetrics.cardWidth, alignment: .leading)
            }
            .frame(width: LibraryCardMetrics.cardWidth, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color(hex: "1A1D24").opacity(0.6))
            )
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: isHovered ? Color.black.opacity(0.3) : .clear, radius: isHovered ? 12 : 0, x: 0, y: isHovered ? 4 : 0)
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .animation(.easeOut(duration: 0.2), value: isHovered)
        .throttledHover(interval: 0.05) { hovering in
            if !isEditing {
                isHovered = hovering
            }
        }
    }

    private var topMetadataRow: some View {
        HStack(alignment: .top, spacing: 8) {
            metaTag(text: wallpaper.categoryDisplayName)
            metaTag(text: wallpaper.purityDisplayName)

            if let primaryColorHex = wallpaper.primaryColorHex {
                colorMetaTag(hex: primaryColorHex)
            }

            Spacer(minLength: 0)

            metaTag(text: wallpaper.resolution)
        }
    }

    private var trailingMetadataRow: some View {
        HStack(spacing: 8) {
            if let primaryColorHex = wallpaper.primaryColorHex {
                footerColorTag(hex: primaryColorHex)
            }

            statLabel(
                systemImage: "heart.fill",
                value: compactNumber(wallpaper.favorites),
                tint: Color(hex: "FF5A7D")
            )

            statLabel(
                systemImage: "eye.fill",
                value: compactNumber(wallpaper.views),
                tint: .white.opacity(0.5)
            )

            if !wallpaper.fileSizeLabel.isEmpty {
                statLabel(
                    systemImage: "doc.fill",
                    value: wallpaper.fileSizeLabel,
                    tint: .white.opacity(0.5)
                )
            }
        }
    }

    private func metaTag(text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(.white.opacity(0.82))
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.black.opacity(0.3))
            )
    }

    private func colorMetaTag(hex: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color(hex: hex))
                .frame(width: 8, height: 8)

            Text(hex.uppercased())
                .font(.system(size: 10, weight: .bold, design: .monospaced))
        }
        .foregroundStyle(.white.opacity(0.82))
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.3))
        )
    }

    private func footerColorTag(hex: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color(hex: hex))
                .frame(width: 10, height: 10)

            Text(hex.uppercased())
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
        }
        .foregroundStyle(.white.opacity(0.7))
    }

    private func statLabel(systemImage: String, value: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(tint)

            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    private func compactNumber(_ number: Int) -> String {
        if number >= 1_000_000 {
            return String(format: "%.1fM", Double(number) / 1_000_000)
        } else if number >= 1_000 {
            return String(format: "%.1fK", Double(number) / 1_000)
        }
        return String(number)
    }
}

// MARK: - Download Progress Block

public struct DownloadCardProgressBlock: View {
    let progress: Double
    let label: String
    let tint: Color

    private var clampedProgress: Double {
        max(0, min(progress, 1))
    }

    private var isCompleted: Bool {
        clampedProgress >= 1.0
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)

                Spacer(minLength: 8)

                if !isCompleted {
                    Text("\(Int((clampedProgress * 100).rounded()))%")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(tint.opacity(0.96))
                }
            }

            if !isCompleted {
                LiquidGlassLinearProgressBar(
                    progress: clampedProgress,
                    height: 6,
                    tintColor: tint,
                    trackOpacity: 0.15
                )
            }
        }
    }
}
