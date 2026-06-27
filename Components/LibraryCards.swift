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

    /// 读取 Wallpaper Engine `project.json` 的 type，用于区分 Web 壁纸和可抽帧的视频类内容。
    nonisolated static func localWorkshopProjectType(from url: URL) -> String? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return nil }

        let resolved = WorkshopService.resolveWallpaperEngineProjectRoot(startingAt: url)
        let projectURL = resolved.appendingPathComponent("project.json")
        guard let data = try? Data(contentsOf: projectURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return nil
        }
        return type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

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
    /// 使用 FileExistenceCache 避免主线程 FileManager.fileExists(atPath:)。
    @MainActor
    func libraryGridThumbnailURL(localFileURL: URL?) -> URL {
        let fileCache = FileExistenceCache.shared
        if let local = localFileURL,
           local.isFileURL,
           fileCache.fileExists(atPath: local.path) {
            let isWebWorkshop = Self.localWorkshopProjectType(from: local) == "web"
            if isWebWorkshop, let localPreview = Self.resolveLocalWorkshopPreviewImage(from: local) {
                return localPreview
            }

            // 解析目录→视频文件（壁纸引擎源），或直接使用文件
            let resolved = Self.resolveLocalVideoFile(from: local) ?? local

            if let extracted = VideoThumbnailCache.shared.cachedStaticThumbnailFileURLIfExists(forLocalFile: resolved) {
                return extracted
            }
            let ext = resolved.pathExtension.lowercased()
            if Self.libraryLocalRasterExtensions.contains(ext) {
                return resolved
            }
            // Workshop 项目（Scene/Web）已烘焙产物：尝试使用烘焙产物的 MP4 抽帧缓存
            if let record = MediaLibraryService.shared.downloadRecords.first(where: { $0.item.id == id }),
               let bakedPath = record.sceneBakeArtifact?.videoPath,
               SceneOfflineBakeService.isUsableBakedVideo(at: URL(fileURLWithPath: bakedPath)) {
                if let extracted = VideoThumbnailCache.shared.cachedSceneBakePosterFileURLIfExists(itemID: id) {
                    return extracted
                }
            }
            if let localPreview = Self.resolveLocalWorkshopPreviewImage(from: local) {
                return localPreview
            }
        }
        if let poster = posterURL, poster.isFileURL, fileCache.fileExists(atPath: poster.path) {
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

public struct MediaVideoCard: View, @preconcurrency Equatable {
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
    var thumbnailURL: URL? = nil
    var shouldProbeAnimatedThumbnail: Bool = true
    var resolvedVideoFileURL: URL? = nil
    var isVisible: Bool = true
    let action: () -> Void

    @State private var isHovered = false
    /// 异步生成抽帧后更新的本地封面 URL
    @State private var resolvedThumbnailURL: URL?
    /// GIF 动画检测
    @State private var detectedGIF = false
    /// 缩略图刷新计数器（每次重新烘焙后递增，强制 KFImage 重新加载）
    @State private var thumbnailRefreshID = 0
    /// 缓存计算后的缩略图 URL，避免每次 body 重绘都做文件 I/O
    @State private var cachedListThumbnailURL: URL?
    /// GIF 探测 debounce 任务
    @State private var gifProbeTask: Task<Void, Never>?
    private let maxAnimatedGIFBytes: Int64 = 18 * 1024 * 1024

    private static let videoExtensions: Set<String> = ["mp4", "mov", "webm", "m4v", "mkv"]

    public static func == (lhs: MediaVideoCard, rhs: MediaVideoCard) -> Bool {
        lhs.item.id == rhs.item.id &&
        lhs.isEditing == rhs.isEditing &&
        lhs.isSelected == rhs.isSelected &&
        lhs.cardWidth == rhs.cardWidth &&
        lhs.localMediaFileURL == rhs.localMediaFileURL
    }

    private var thumbnailHeight: CGFloat {
        LibraryCardMetrics.thumbnailHeight
    }

    private var listThumbnailURL: URL {
        cachedListThumbnailURL ?? thumbnailURL ?? item.coverImageURL
    }

    private var shouldAnimateGIF: Bool {
        isHovered && isVisible
    }

    // 降采样目标尺寸（固定 512x512，避免窗口大小变化导致缓存失效）
    private let targetImageSize: CGSize = CGSize(width: 512, height: 512)

    public var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                coverSurface
                    .frame(width: cardWidth, height: thumbnailHeight)

                bottomInfoBar
            }
            .frame(width: cardWidth, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color(hex: "1A1D24"))
            )
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.white.opacity(isHovered ? 0.18 : 0.08), lineWidth: isHovered ? 1.5 : 1)
            )
            .frame(width: cardWidth, alignment: .leading)
            .libraryCardHoverScale(isHovered: isHovered)
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .throttledHover(interval: 0.05) { hovering in
            if !isEditing {
                isHovered = hovering
            }
        }
        .task(id: listThumbnailURL.absoluteString) {
            gifProbeTask?.cancel()
            guard shouldProbeAnimatedThumbnail else {
                detectedGIF = false
                return
            }
            detectedGIF = false
            gifProbeTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
                let probeURL = listThumbnailURL
                let result = await AnimatedImageProbeCache.shared.isAnimatedGIF(
                    probeURL,
                    maxByteCount: maxAnimatedGIFBytes
                )
                guard !Task.isCancelled else { return }
                detectedGIF = result
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .sceneOfflineBakeThumbnailDidUpdate)) { notification in
            guard let updatedItemID = notification.object as? String,
                  updatedItemID == item.id else { return }
            thumbnailRefreshID &+= 1
            resolvedThumbnailURL = nil
            cachedListThumbnailURL = nil
            if let posterURL = notification.userInfo?["thumbnailURL"] as? URL {
                resolvedThumbnailURL = posterURL
                cachedListThumbnailURL = posterURL
            } else {
                triggerThumbnailIfNeeded()
            }
        }
        // ⚡ 内存压力下的 detectedGIF 重置已不在每张卡注册：滚动期间数百张卡片各自挂
        // 两个 Combine sink 会拖慢滚动；下次内存压力时由 ViewModel/Bridge 通过统一通道
        // 推送即可。`detectedGIF` 是几字节布尔，留着无碍。
        .onAppear {
            resolveThumbnailURL()
            triggerThumbnailIfNeeded()
        }
        .onChange(of: localMediaFileURL) { _, _ in
            thumbnailRefreshID &+= 1
            resolvedThumbnailURL = nil
            cachedListThumbnailURL = nil
            resolveThumbnailURL()
            triggerThumbnailIfNeeded()
        }
        .onChange(of: thumbnailURL) { _, _ in
            cachedListThumbnailURL = nil
            resolveThumbnailURL()
        }
    }

    private var coverSurface: some View {
        coverImage
            .frame(width: cardWidth, height: thumbnailHeight)
            .clipped()
            .overlay(alignment: .topLeading) {
                if !isEditing {
                    mediaBadgeRow
                        .padding(12)
                }
            }
            .overlay(alignment: .topLeading) {
                if isEditing {
                    editSelectionControl
                }
            }
            .overlay {
                if isEditing && isSelected {
                    Color.black.opacity(0.3)
                }
            }
    }

    @ViewBuilder
    private var coverImage: some View {
        // 修复两个 bug（同 MediaCardView 之前的修复）：
        // 1. KFImage ↔ NativeGIFView 切换瞬间黑底闪烁（新 NSView 未下载完成）
        // 2. NativeGIFView.Coordinator.load 完成后只设静态帧、没启动动画 → hover 不动
        //
        // 改用 ZStack 双层：底层 KFImage 静态封面**永不销毁**；顶层仅当 detectedGIF
        // 且当前卡片需要播放时叠加 KFAnimatedImage，`id` 随播放状态变化触发 NSView
        // 重建以使 `autoPlayAnimatedImage = true` 真实生效。
        ZStack {
            // 底层：静态封面，始终存在
            KFImage(listThumbnailURL)
                .setProcessor(DownsamplingImageProcessor(size: targetImageSize))
                .cacheMemoryOnly(false)
                .memoryCacheExpiration(.seconds(300))
                .placeholder { _ in
                    SkeletonCard(width: cardWidth, height: thumbnailHeight, cornerRadius: 0)
                }
                .resizable()
                .scaledToFill()
                .frame(width: cardWidth, height: thumbnailHeight)
                .clipped()
                .id(thumbnailRefreshID)

            // 顶层：仅 GIF 已确认 + 当前应播放时叠加（库列表 shouldAnimateGIF 通常包含 isHovered 条件）
            if detectedGIF, shouldAnimateGIF {
                KFAnimatedImage.url(listThumbnailURL)
                    .memoryCacheExpiration(.expired)
                    .diskCacheExpiration(.days(3))
                    .cancelOnDisappear(true)
                    .configure { view in
                        configureAnimatedGIFViewForAspectFill(view, autoPlay: true)
                    }
                    .placeholder { _ in Color.clear }
                    .onFailure { _ in /* 静默：底层 KFImage 兜底 */ }
                    .id("\(listThumbnailURL.absoluteString)|play:1|r:\(thumbnailRefreshID)")
                    .aspectRatio(contentMode: .fill)
                    .frame(width: cardWidth, height: thumbnailHeight)
                    .clipped()
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: shouldAnimateGIF)
    }

    private var mediaBadgeRow: some View {
        HStack(alignment: .top, spacing: 8) {
            mediaBadgeText(item.subtitle)

            Spacer(minLength: 0)

            if !badgeText.isEmpty && badgeText != item.subtitle {
                mediaBadgeText(badgeText)
            }
        }
        .frame(width: max(0, cardWidth - 24), alignment: .topLeading)
    }

    private func mediaBadgeText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(.white.opacity(0.82))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black.opacity(0.3))
            )
    }

    private var editSelectionControl: some View {
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

    private var bottomInfoBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.title)
                .font(.system(size: 14.5, weight: .bold))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)

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
        .background(Color(hex: "1A1D24"))
    }

    @MainActor
    private func triggerThumbnailIfNeeded() {
        guard resolvedThumbnailURL == nil,
              let local = localMediaFileURL,
              local.isFileURL,
              FileExistenceCache.shared.fileExists(atPath: local.path) else { return }

        if let thumbnailURL,
           thumbnailURL.isFileURL,
           !Self.videoExtensions.contains(thumbnailURL.pathExtension.lowercased()) {
            return
        }

        let isWebWorkshop = MediaItem.localWorkshopProjectType(from: local) == "web"
        if isWebWorkshop, let localPreview = MediaItem.resolveLocalWorkshopPreviewImage(from: local) {
            resolvedThumbnailURL = localPreview
            cachedListThumbnailURL = localPreview
            return
        }

        if let resolved = resolvedVideoFileURL ?? MediaItem.resolveLocalVideoFile(from: local) ?? (
            Self.videoExtensions.contains(local.pathExtension.lowercased()) ? local : nil
        ) {
            if let cached = VideoThumbnailCache.shared.cachedStaticThumbnailFileURLIfExists(forLocalFile: resolved) {
                resolvedThumbnailURL = cached
                cachedListThumbnailURL = cached
                return
            }
            if Self.videoExtensions.contains(resolved.pathExtension.lowercased()) {
                Task { @MainActor in
                    if let poster = await VideoThumbnailCache.shared.posterJPEGFileURL(forLocalVideo: resolved) {
                        resolvedThumbnailURL = poster
                        cachedListThumbnailURL = poster
                    }
                }
            }
            return
        }

        if let record = MediaLibraryService.shared.downloadRecords.first(where: { $0.item.id == item.id }),
           let bakedVideo = record.sceneBakeArtifact.flatMap({ $0.videoPath }).map({ URL(fileURLWithPath: $0) }),
           SceneOfflineBakeService.isUsableBakedVideo(at: bakedVideo) {
            if let cached = VideoThumbnailCache.shared.cachedSceneBakePosterFileURLIfExists(itemID: item.id) {
                resolvedThumbnailURL = cached
                cachedListThumbnailURL = cached
                return
            }
            if Self.videoExtensions.contains(bakedVideo.pathExtension.lowercased()) {
                Task { @MainActor in
                    if let poster = await VideoThumbnailCache.shared.sceneBakePosterJPEGFileURL(
                        forLocalVideo: bakedVideo,
                        itemID: item.id
                    ) {
                        resolvedThumbnailURL = poster
                        cachedListThumbnailURL = poster
                    }
                }
            }
            return
        }

        if let localPreview = MediaItem.resolveLocalWorkshopPreviewImage(from: local) {
            resolvedThumbnailURL = localPreview
            cachedListThumbnailURL = localPreview
        }
    }

    @MainActor
    private func resolveThumbnailURL() {
        guard cachedListThumbnailURL == nil else { return }
        if let resolved = resolvedThumbnailURL {
            cachedListThumbnailURL = resolved
            return
        }
        cachedListThumbnailURL = item.libraryGridThumbnailURL(localFileURL: localMediaFileURL)
    }
}

// MARK: - Wallpaper Edit Card

public struct WallpaperEditCard: View, @preconcurrency Equatable {
    let wallpaper: Wallpaper
    /// 已下载壁纸的本地文件路径（可选），离线时直接用本地文件避免依赖远程缓存
    var localFileURL: URL? = nil
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

    public static func == (lhs: WallpaperEditCard, rhs: WallpaperEditCard) -> Bool {
        lhs.wallpaper.id == rhs.wallpaper.id &&
        lhs.isEditing == rhs.isEditing &&
        lhs.isSelected == rhs.isSelected &&
        lhs.cardWidth == rhs.cardWidth &&
        lhs.localFileURL == rhs.localFileURL
    }

    private var thumbnailHeight: CGFloat {
        LibraryCardMetrics.thumbnailHeight
    }

    /// 封面 URL：已下载壁纸优先用本地文件，离线也能显示
    private var resolvedThumbURL: URL? {
        if let local = localFileURL,
           local.isFileURL,
           FileExistenceCache.shared.fileExists(atPath: local.path) {
            return local
        }
        return wallpaper.thumbURL ?? wallpaper.smallThumbURL
    }

    public var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                // 图片区域
                ZStack {
                    KFImage(resolvedThumbURL)
                        .setProcessor(DownsamplingImageProcessor(size: CGSize(width: 512, height: 512)))
                        .cacheMemoryOnly(false)
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
                    .fill(Color(hex: "1A1D24"))
            )
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.white.opacity(isHovered ? 0.18 : 0.08), lineWidth: isHovered ? 1.5 : 1)
            )
            .libraryCardHoverScale(isHovered: isHovered)
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
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
        HStack(spacing: 5) {
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
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
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

// MARK: - 性能优化：scale + animation 永久挂载以保证平滑过渡
//
// ⚠️ 同 MediaCardView 注释：scaleEffect / animation 不能用 `@ViewBuilder if isHovered`
// 做条件挂载 —— SwiftUI 把结构变化看作 transition，只能做默认 opacity 动画，
// 没法在 1.0 ↔ 1.01 之间插值，hover 体感会变成生硬跳变。
//
// scaleEffect(1.0) 是 identity transform，SwiftUI 会优化掉矩阵运算；
// .animation 仅登记一个 value dependency，无实际变化时几乎零开销。
private extension View {
    func libraryCardHoverScale(isHovered: Bool) -> some View {
        self
            .scaleEffect(isHovered ? 1.01 : 1.0)
            .animation(.easeOut(duration: 0.2), value: isHovered)
    }
}
