import SwiftUI
import Kingfisher

// MARK: - MediaItem 我的库列表封面

extension MediaItem {
    fileprivate static let libraryLocalRasterExtensions: Set<String> = [
        "jpg", "jpeg", "png", "webp", "gif", "heic", "heif", "avif", "bmp", "tiff", "tif"
    ]

    private static let videoFileExtensions: Set<String> = ["mp4", "mov", "webm", "m4v", "mkv"]
    private static let workshopPreviewFallbackNames = [
        "preview.gif", "preview.jpg", "preview.jpeg", "preview.png", "preview.webp"
    ]

    /// 若 `url` 是已下载的 Wallpaper Engine 项目录，优先寻找本地预览图（特别是 web 壁纸）。
    nonisolated static func resolveLocalWorkshopPreviewImage(from url: URL) -> URL? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return nil }

        let resolved = WorkshopService.resolveWallpaperEngineProjectRoot(startingAt: url)
        let projectURL = resolved.appendingPathComponent("project.json")
        if let data = try? Data(contentsOf: projectURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let previewName = json["preview"] as? String {
            let trimmed = previewName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let candidate = resolved.appendingPathComponent(trimmed)
                if fm.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
        }

        for name in workshopPreviewFallbackNames {
            let candidate = resolved.appendingPathComponent(name)
            if fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// 若 `url` 是目录（壁纸引擎 Workshop 项），递归查找其中的视频文件并返回；若是视频文件则直接返回。
    nonisolated static func resolveLocalVideoFile(from url: URL) -> URL? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }

        if !isDir.boolValue {
            return videoFileExtensions.contains(url.pathExtension.lowercased()) ? url : nil
        }

        // 目录：使用 WorkshopService 的根解析逻辑
        let resolved = WorkshopService.resolveWallpaperEngineProjectRoot(startingAt: url)
        let rootContents = (try? fm.contentsOfDirectory(at: resolved, includingPropertiesForKeys: nil)) ?? []

        // scene 类型（有 .pkg 文件）不生成视频抽帧
        if rootContents.contains(where: { $0.pathExtension.lowercased() == "pkg" }) {
            return nil
        }

        // 递归查找视频文件
        if let enumerator = fm.enumerator(at: resolved, includingPropertiesForKeys: nil) {
            for case let fileURL as URL in enumerator {
                if videoFileExtensions.contains(fileURL.pathExtension.lowercased()) {
                    return fileURL
                }
            }
        }
        return nil
    }

    /// 「我的库」列表封面（仅静态 `KFImage`）：有本地文件时优先已缓存的截取帧，其次本地静图，再回退 `posterURL` / 站点 `coverImageURL`（下载与导入一致）。
    @MainActor
    func libraryGridThumbnailURL(localFileURL: URL?) -> URL {
        if let local = localFileURL,
           local.isFileURL,
           FileManager.default.fileExists(atPath: local.path) {
            if let localPreview = Self.resolveLocalWorkshopPreviewImage(from: local) {
                return localPreview
            }
            // 解析目录→视频文件（壁纸引擎源），或直接使用文件
            let resolved = Self.resolveLocalVideoFile(from: local) ?? local

            if let extracted = VideoThumbnailCache.shared.cachedStaticThumbnailFileURLIfExists(forLocalFile: resolved) {
                return extracted
            }
            let ext = resolved.pathExtension.lowercased()
            if Self.libraryLocalRasterExtensions.contains(ext) || Self.videoFileExtensions.contains(ext) {
                return resolved
            }
        }
        if let poster = posterURL, poster.isFileURL, FileManager.default.fileExists(atPath: poster.path) {
            return poster
        }
        return coverImageURL
    }
}

// MARK: - Card Metrics

public enum LibraryCardMetrics {
    public static let cardWidth: CGFloat = 260
    public static let thumbnailHeight: CGFloat = 180
}

// MARK: - Media Video Card

public struct MediaVideoCard: View {
    let item: MediaItem
    /// 本地媒体文件路径（下载或导入）
    var localMediaFileURL: URL? = nil
    var badgeText: String = ""
    var accent: Color = LiquidGlassColors.secondaryViolet
    let isEditing: Bool
    let isSelected: Bool
    var progress: Double? = nil
    var progressTint: Color? = nil
    var progressLabel: String? = nil
    var cardWidth: CGFloat = LibraryCardMetrics.cardWidth
    let action: () -> Void

    @State private var isHovered = false
    /// 异步生成抽帧后更新的本地封面 URL
    @State private var resolvedThumbnailURL: URL?

    private static let videoExtensions: Set<String> = ["mp4", "mov", "webm", "m4v", "mkv"]

    private var thumbnailHeight: CGFloat {
        LibraryCardMetrics.thumbnailHeight
    }

    private var listThumbnailURL: URL {
        resolvedThumbnailURL ?? item.libraryGridThumbnailURL(localFileURL: localMediaFileURL)
    }

    // 降采样目标尺寸（固定 512x512，避免窗口大小变化导致缓存失效）
    private let targetImageSize: CGSize = CGSize(width: 512, height: 512)

    public var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                // 图片区域 - 单独裁剪（仅静态，与壁纸库卡片一致；GIF 为降采样单帧）
                ZStack {
                    KFImage(listThumbnailURL)
                        .setProcessor(DownsamplingImageProcessor(size: targetImageSize))
                        .cacheMemoryOnly(false)
                        .fade(duration: 0.3)
                        .placeholder { _ in
                            SkeletonCard(width: cardWidth, height: thumbnailHeight, cornerRadius: 0)
                        }
                        .resizable()
                        .scaledToFill()
                        .frame(width: cardWidth, height: thumbnailHeight)
                        .clipped()

                    // 左上角：编辑模式显示复选框，非编辑模式显示 subtitle tag
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
                    } else {
                        VStack {
                            HStack(spacing: 8) {
                                Text(item.subtitle)
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.82))
                                    .lineLimit(1)
                                    .padding(.horizontal, 8)
                                    .frame(height: 20)
                                    .background(
                                        Capsule(style: .continuous)
                                            .fill(Color.black.opacity(0.3))
                                    )

                                Spacer()
                            }
                            Spacer()
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }

                    // 右上角标签（非编辑模式下显示）
                    if !isEditing && !badgeText.isEmpty {
                        VStack {
                            HStack {
                                Spacer()
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
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
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
                .frame(width: cardWidth, alignment: .leading)
            }
            .frame(width: cardWidth, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color(hex: "1A1D24").opacity(0.6))
            )
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.white.opacity(isHovered ? 0.18 : 0.08), lineWidth: isHovered ? 1.5 : 1)
            )
            .scaleEffect(isHovered ? 1.01 : 1.0)
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .animation(.easeOut(duration: 0.2), value: isHovered)
        .throttledHover(interval: 0.05) { hovering in
            if !isEditing {
                isHovered = hovering
            }
        }
        .onAppear { triggerThumbnailIfNeeded() }
        .onChange(of: localMediaFileURL) { _, _ in resolvedThumbnailURL = nil; triggerThumbnailIfNeeded() }
    }

    /// 已下载的视频如果没有缓存抽帧，异步生成并刷新封面
    @MainActor
    private func triggerThumbnailIfNeeded() {
        guard resolvedThumbnailURL == nil,
              let local = localMediaFileURL,
              local.isFileURL,
              FileManager.default.fileExists(atPath: local.path) else { return }

        if let localPreview = MediaItem.resolveLocalWorkshopPreviewImage(from: local) {
            resolvedThumbnailURL = localPreview
            return
        }

        // 解析目录→视频文件/预览图（壁纸引擎源），或直接使用文件
        if let resolved = MediaItem.resolveLocalVideoFile(from: local) ?? (
            Self.videoExtensions.contains(local.pathExtension.lowercased()) ? local : nil
        ) {
            // 已有缓存则直接使用
            if let cached = VideoThumbnailCache.shared.cachedStaticThumbnailFileURLIfExists(forLocalFile: resolved) {
                resolvedThumbnailURL = cached
                return
            }
            // 如果是视频文件，异步生成抽帧
            if Self.videoExtensions.contains(resolved.pathExtension.lowercased()) {
                Task { @MainActor in
                    if let poster = await VideoThumbnailCache.shared.posterJPEGFileURL(forLocalVideo: resolved) {
                        resolvedThumbnailURL = poster
                    }
                }
            }
            return
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
    var cardWidth: CGFloat = LibraryCardMetrics.cardWidth
    let action: () -> Void

    @State private var isHovered = false

    private var thumbnailHeight: CGFloat {
        LibraryCardMetrics.thumbnailHeight
    }

    public var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                // 图片区域
                ZStack {
                    KFImage(wallpaper.thumbURL ?? wallpaper.smallThumbURL)
                        .setProcessor(DownsamplingImageProcessor(size: CGSize(width: 512, height: 512)))
                        .cacheMemoryOnly(false)
                        .fade(duration: 0.3)
                        .placeholder { _ in
                            SkeletonCard(
                                width: cardWidth,
                                height: thumbnailHeight,
                                cornerRadius: 0
                            )
                        }
                        .resizable()
                        .scaledToFill()
                        .frame(
                            width: cardWidth,
                            height: thumbnailHeight
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
                .frame(width: cardWidth, alignment: .leading)
            }
            .frame(width: cardWidth, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color(hex: "1A1D24").opacity(0.6))
            )
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.white.opacity(isHovered ? 0.18 : 0.08), lineWidth: isHovered ? 1.5 : 1)
            )
            .scaleEffect(isHovered ? 1.01 : 1.0)
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

            Spacer(minLength: 0)

            metaTag(text: wallpaper.resolution)
        }
    }

    private var trailingMetadataRow: some View {
        HStack(spacing: 8) {
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
