import SwiftUI
import Kingfisher

// MARK: - Card Metrics

public enum LibraryCardMetrics {
    public static let cardWidth: CGFloat = 260
    public static let thumbnailHeight: CGFloat = 180
}

// MARK: - Scroll Hover Gate

/// 我的库滚动期间抑制 hover（尤其 GIF 叠加层挂载），并门控缩略图生成/预热。
/// 仅在 suppress 边沿发一次通知，避免滚动帧驱动整树重绘。
@MainActor
final class LibraryScrollHoverGate {
    static let shared = LibraryScrollHoverGate()

    private(set) var suppressesAnimatedHover = false
    /// 滚动中（含惯性尾段）为 true；滚停 idleDelay 后变 false。
    private(set) var isScrolling = false
    private var idleWorkItem: DispatchWorkItem?
    /// 只允许最新一次滚动活动结束后解除门控。
    private var idleGeneration = 0
    private var idleCallbacks: [UUID: () -> Void] = [:]
    /// 滚停后稍等再恢复，避免惯性滚动尾段反复开关
    private let idleDelay: TimeInterval = 0.22

    func noteScrollActivity() {
        idleWorkItem?.cancel()
        idleGeneration &+= 1
        let generation = idleGeneration
        isScrolling = true
        if !suppressesAnimatedHover {
            suppressesAnimatedHover = true
            NotificationCenter.default.post(name: .libraryScrollDidSuppressHover, object: nil)
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.idleGeneration == generation else { return }
            self.idleWorkItem = nil
            self.isScrolling = false
            self.suppressesAnimatedHover = false
            let callbacks = Array(self.idleCallbacks.values)
            self.idleCallbacks.removeAll()
            for callback in callbacks {
                callback()
            }
            NotificationCenter.default.post(name: .libraryScrollDidBecomeIdle, object: nil)
        }
        idleWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + idleDelay, execute: work)
    }

    /// 滚动中排队，滚停后只执行一次（同 token 会覆盖）。
    @discardableResult
    func runWhenIdle(token: UUID = UUID(), _ work: @escaping () -> Void) -> UUID {
        if !isScrolling {
            work()
            return token
        }
        idleCallbacks[token] = work
        return token
    }

    func cancelIdleWork(token: UUID) {
        idleCallbacks.removeValue(forKey: token)
    }
}

extension Notification.Name {
    static let libraryScrollDidSuppressHover = Notification.Name("libraryScrollDidSuppressHover")
    static let libraryScrollDidBecomeIdle = Notification.Name("libraryScrollDidBecomeIdle")
}

// MARK: - 滚停后命中恢复 hover
//
// macOS 上内容从静止指针下划过时，SwiftUI onHover 往往不会对“新到指针下的卡”重发 enter。
// 滚停后用 AppKit 窗口坐标对卡片 bounds 做一次 hit-test，指针仍在卡上则立刻恢复 isHovered。

private struct LibraryScrollIdleHoverProbe: NSViewRepresentable {
    let onProbe: (Bool) -> Void

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onProbe = onProbe
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.onProbe = onProbe
    }

    final class ProbeView: NSView {
        var onProbe: ((Bool) -> Void)?
        private var idleObserver: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeIdleObserver()
            guard window != nil else { return }
            idleObserver = NotificationCenter.default.addObserver(
                forName: .libraryScrollDidBecomeIdle,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.probeMouse()
            }
        }

        override func removeFromSuperview() {
            removeIdleObserver()
            super.removeFromSuperview()
        }

        private func removeIdleObserver() {
            if let idleObserver {
                NotificationCenter.default.removeObserver(idleObserver)
                self.idleObserver = nil
            }
        }

        private func probeMouse() {
            guard let window, !isHiddenOrHasHiddenAncestor else { return }
            // 不可见/零尺寸时跳过（Lazy 离屏卡）
            guard bounds.width > 1, bounds.height > 1 else { return }
            let mouseInWindow = window.mouseLocationOutsideOfEventStream
            let local = convert(mouseInWindow, from: nil)
            onProbe?(bounds.contains(local))
        }
    }
}

extension View {
    /// 滚停后若指针仍在本视图上，回调 true（用于恢复 hover，不依赖 onHover 重发）
    func libraryScrollIdleHoverProbe(_ onProbe: @escaping (Bool) -> Void) -> some View {
        background {
            LibraryScrollIdleHoverProbe(onProbe: onProbe)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
        }
    }
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
    /// 当前壁纸是否在任意屏幕上使用中（由父视图计算传入，供 Equatable.== 感知切换）
    var isCurrentWallpaper: Bool = false
    let action: () -> Void

    @State private var isHovered = false
    /// 指针是否在卡片内（滚动中也更新；滚停时用来恢复 isHovered）
    @State private var isPointerInside = false
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
    /// 滚停后再做抽帧/SSD 缩略图生成的排队 token
    @State private var pendingThumbnailIdleToken: UUID?
    private let maxAnimatedGIFBytes: Int64 = 18 * 1024 * 1024

    private static let videoExtensions: Set<String> = ["mp4", "mov", "webm", "m4v", "mkv"]

    public static func == (lhs: MediaVideoCard, rhs: MediaVideoCard) -> Bool {
        lhs.item.id == rhs.item.id &&
        lhs.isEditing == rhs.isEditing &&
        lhs.isSelected == rhs.isSelected &&
        lhs.cardWidth == rhs.cardWidth &&
        lhs.localMediaFileURL == rhs.localMediaFileURL &&
        lhs.thumbnailURL == rhs.thumbnailURL &&
        lhs.resolvedVideoFileURL == rhs.resolvedVideoFileURL &&
        lhs.isCurrentWallpaper == rhs.isCurrentWallpaper
    }

    private var thumbnailHeight: CGFloat {
        LibraryCardMetrics.thumbnailHeight
    }

    private var listThumbnailURL: URL {
        cachedListThumbnailURL ?? thumbnailURL ?? item.coverImageURL
    }

    /// hover 播放源：必须是真实 GIF 文件，不能是 LocalImageThumbnails / VideoThumbnails 里的静态 JPEG。
    private var animatedGIFSourceURL: URL {
        if let local = localMediaFileURL, LocalImageThumbnailCache.isGIFFile(local) {
            return local
        }
        if let local = localMediaFileURL,
           local.isFileURL,
           FileExistenceCache.shared.isDirectory(atPath: local.path),
           let preview = MediaItem.resolveLocalWorkshopPreviewGIF(from: local),
           LocalImageThumbnailCache.isGIFFile(preview) {
            return preview
        }
        if LocalImageThumbnailCache.isGIFFile(listThumbnailURL) {
            return listThumbnailURL
        }
        if let thumbnailURL, LocalImageThumbnailCache.isGIFFile(thumbnailURL) {
            return thumbnailURL
        }
        return listThumbnailURL
    }

    private var shouldAnimateGIF: Bool {
        // 滚动中一律不挂 KFAnimatedImage，避免滚过 GIF 时反复切显示层
        isHovered && isVisible && !LibraryScrollHoverGate.shared.suppressesAnimatedHover
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
            guard !isEditing else { return }
            // 始终记录指针位置；滚动中仅抑制 isHovered，不丢 enter 信息
            isPointerInside = hovering
            if hovering, LibraryScrollHoverGate.shared.suppressesAnimatedHover {
                // 滚动中忽略 enter，保持静态封面
                return
            }
            isHovered = hovering
        }
        // 仅已 hover 的卡才订阅 suppress 通知：避免每张可见卡都挂 Combine sink。
        .background {
            if isHovered {
                Color.clear
                    .onReceive(NotificationCenter.default.publisher(for: .libraryScrollDidSuppressHover)) { _ in
                        isHovered = false
                    }
            }
        }
        // 内容从指针下划过时 onHover 不重发 enter；滚停 hit-test 恢复
        .libraryScrollIdleHoverProbe { inside in
            guard !isEditing else { return }
            isPointerInside = inside
            if inside {
                isHovered = true
            } else if isHovered {
                isHovered = false
            }
        }
        .task(id: "\(animatedGIFSourceURL.absoluteString)|\(shouldProbeAnimatedThumbnail)") {
            gifProbeTask?.cancel()
            // 路径已是 .gif 时直接认定，避免外置卡上再读文件头探测
            if LocalImageThumbnailCache.isGIFFile(animatedGIFSourceURL) {
                detectedGIF = true
                return
            }
            guard shouldProbeAnimatedThumbnail else {
                detectedGIF = false
                return
            }
            // 滚动中不启动 GIF probe（读文件头会抖）；滚停后再探测
            if LibraryScrollHoverGate.shared.isScrolling {
                detectedGIF = false
                return
            }
            detectedGIF = false
            gifProbeTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
                if LibraryScrollHoverGate.shared.isScrolling { return }
                let probeURL = animatedGIFSourceURL
                // 静态列表缓存路径不可能是动图
                let path = probeURL.standardizedFileURL.path
                if probeURL.isFileURL,
                   VideoThumbnailCache.isGeneratedStaticImagePath(path) {
                    detectedGIF = false
                    return
                }
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
            // 强制 KFImage 换 id，避免同 path 的 list_*.jpg / scene_bake_*.jpg 仍吃旧内存图
            thumbnailRefreshID &+= 1
            resolvedThumbnailURL = nil
            cachedListThumbnailURL = nil
            if let thumbURL = notification.userInfo?["thumbnailURL"] as? URL {
                resolvedThumbnailURL = thumbURL
                cachedListThumbnailURL = thumbURL
            } else {
                // 清除产物 / 无新帧：重新解析（可能回退站点封面）
                resolveThumbnailURL()
                scheduleThumbnailWork()
            }
        }
        .onAppear {
            resolveThumbnailURL()
            scheduleThumbnailWork()
        }
        .onDisappear {
            gifProbeTask?.cancel()
            gifProbeTask = nil
            if let token = pendingThumbnailIdleToken {
                LibraryScrollHoverGate.shared.cancelIdleWork(token: token)
                pendingThumbnailIdleToken = nil
            }
        }
        .onChange(of: localMediaFileURL) { _, _ in
            thumbnailRefreshID &+= 1
            resolvedThumbnailURL = nil
            cachedListThumbnailURL = nil
            resolveThumbnailURL()
            scheduleThumbnailWork()
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
            // 当前使用中的壁纸标记
            .overlay(alignment: .bottomLeading) {
                if !isEditing && isCurrentWallpaper {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10, weight: .bold))
                        Text(t("wallpaper.currentlyActive"))
                            .font(.system(size: 10, weight: .bold))
                    }
                    .foregroundStyle(.white.opacity(0.95))
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(
                        Capsule(style: .continuous).fill(Color.green.opacity(0.78))
                    )
                    .padding(12)
                    .transition(.opacity)
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

            // 顶层：仅 GIF 已确认 + 当前应播放时叠加；动画源用原始 GIF，勿用静态列表 JPEG
            if detectedGIF, shouldAnimateGIF {
                KFAnimatedImage.url(animatedGIFSourceURL)
                    .memoryCacheExpiration(.expired)
                    .diskCacheExpiration(.days(3))
                    .cancelOnDisappear(true)
                    .configure { view in
                        configureAnimatedGIFViewForAspectFill(view, autoPlay: true)
                    }
                    .placeholder { _ in Color.clear }
                    .onFailure { _ in /* 静默：底层 KFImage 兜底 */ }
                    .id("\(animatedGIFSourceURL.absoluteString)|play:1|r:\(thumbnailRefreshID)")
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

    /// 滚动中排队；滚停后只做一次抽帧/SSD 生成。
    @MainActor
    private func scheduleThumbnailWork() {
        if let token = pendingThumbnailIdleToken {
            LibraryScrollHoverGate.shared.cancelIdleWork(token: token)
        }
        // 已停滚：直接生成
        if !LibraryScrollHoverGate.shared.isScrolling {
            pendingThumbnailIdleToken = nil
            triggerThumbnailIfNeeded()
            return
        }
        let token = UUID()
        pendingThumbnailIdleToken = token
        LibraryScrollHoverGate.shared.runWhenIdle(token: token) {
            guard pendingThumbnailIdleToken == token else { return }
            pendingThumbnailIdleToken = nil
            triggerThumbnailIfNeeded()
        }
    }

    @MainActor
    private func triggerThumbnailIfNeeded() {
        // 滚动中绝不启动生成/目录解析，避免与滚动抢主线程与磁盘
        if LibraryScrollHoverGate.shared.isScrolling {
            scheduleThumbnailWork()
            return
        }

        // Scene 烘焙：优先列表小图；有 poster 先占位再后台补完整画幅帧
        if let bakedPath = MediaLibraryService.shared.downloadRecord(for: item.id)?.sceneBakeArtifact?.videoPath,
           !bakedPath.isEmpty {
            let bakedVideo = URL(fileURLWithPath: bakedPath)
            // 通知刚写入的新帧已进 cachedListThumbnailURL 时不要用旧磁盘 list 覆盖
            if cachedListThumbnailURL == nil,
               let listThumb = VideoThumbnailCache.shared.cachedListThumbnailFileURLIfExists(forLocalVideo: bakedVideo) {
                resolvedThumbnailURL = listThumb
                cachedListThumbnailURL = listThumb
                return
            }
            if cachedListThumbnailURL == nil,
               let hd = VideoThumbnailCache.shared.cachedSceneBakePosterFileURLIfExists(itemID: item.id) {
                resolvedThumbnailURL = hd
                cachedListThumbnailURL = hd
            }
            // 已有有效列表帧则不必再生成；缺则后台补
            if VideoThumbnailCache.shared.cachedListThumbnailFileURLIfExists(forLocalVideo: bakedVideo) != nil {
                return
            }
            Task { @MainActor in
                guard !LibraryScrollHoverGate.shared.isScrolling else { return }
                // 不在主线程 isUsableBakedVideo（外置卡 stat 很慢）；生成侧会自己检查文件
                if let listThumb = await VideoThumbnailCache.shared.listThumbnailJPEGFileURL(forLocalVideo: bakedVideo) {
                    resolvedThumbnailURL = listThumb
                    cachedListThumbnailURL = listThumb
                } else if cachedListThumbnailURL == nil,
                          let poster = await VideoThumbnailCache.shared.sceneBakePosterJPEGFileURL(
                            forLocalVideo: bakedVideo,
                            itemID: item.id
                          ) {
                    resolvedThumbnailURL = poster
                    cachedListThumbnailURL = poster
                }
            }
            return
        }

        if let cached = VideoThumbnailCache.shared.cachedSceneBakePosterFileURLIfExists(itemID: item.id) {
            resolvedThumbnailURL = cached
            cachedListThumbnailURL = cached
            return
        }

        // 已有解析结果则不再重入
        guard resolvedThumbnailURL == nil else { return }

        // 注意：不要因 FileExistenceCache 负缓存直接 return。
        // 外置卡上偶发 stat 失败会被缓存成 false，导致永远不抽帧。
        guard let local = localMediaFileURL, local.isFileURL else {
            // 无本地路径：用传入/站点封面即可
            if cachedListThumbnailURL == nil {
                cachedListThumbnailURL = thumbnailURL ?? item.coverImageURL
            }
            return
        }

        let ext = local.pathExtension.lowercased()
        let fileCache = FileExistenceCache.shared

        // GIF：直接用原文件
        if ext == "gif" {
            resolvedThumbnailURL = local
            cachedListThumbnailURL = local
            fileCache.markExisting(atPath: local.path)
            return
        }

        // 静图：只读已有 SSD 缓存；缺失时后台生成
        if LocalImageThumbnailCache.isRasterImageFile(local) {
            if let cached = LocalImageThumbnailCache.shared.cachedThumbnailURLIfExists(forLocalFile: local) {
                resolvedThumbnailURL = cached
                cachedListThumbnailURL = cached
                return
            }
            if cachedListThumbnailURL == nil {
                cachedListThumbnailURL = thumbnailURL ?? item.coverImageURL
            }
            Task { @MainActor in
                guard !LibraryScrollHoverGate.shared.isScrolling else { return }
                if let thumb = await LocalImageThumbnailCache.shared.ensureThumbnail(forLocalFile: local) {
                    resolvedThumbnailURL = thumb
                    cachedListThumbnailURL = thumb
                    fileCache.markExisting(atPath: local.path)
                }
            }
            return
        }

        // 直出视频文件
        if Self.videoExtensions.contains(ext) {
            applyVideoListThumbnail(for: local, fallbackCover: true)
            return
        }

        // 父视图已解析出内部视频（轻量路径）
        if let resolved = resolvedVideoFileURL,
           Self.videoExtensions.contains(resolved.pathExtension.lowercased()) {
            applyVideoListThumbnail(for: resolved, fallbackCover: true)
            return
        }

        // Workshop 目录：有内部视频则必须抽帧；preview 仅占位，不能「有 preview 就永久 return」
        Task { @MainActor in
            guard !LibraryScrollHoverGate.shared.isScrolling else { return }
            let exists = await local.fileExistsAsync()
            if exists {
                fileCache.markExisting(atPath: local.path)
            } else {
                fileCache.invalidate(atPath: local.path)
                if cachedListThumbnailURL == nil {
                    cachedListThumbnailURL = thumbnailURL ?? item.coverImageURL
                }
                return
            }
            guard !LibraryScrollHoverGate.shared.isScrolling else { return }

            // 1) 先找可抽帧视频（结果有 WorkshopLibraryPreviewCache）
            if let resolved = MediaItem.resolveLocalVideoFile(from: local),
               Self.videoExtensions.contains(resolved.pathExtension.lowercased()) {
                // 有缓存帧 → 直接用；没有则先 preview/远程占位，再异步抽帧替换
                if let cached = VideoThumbnailCache.shared.cachedStaticThumbnailFileURLIfExists(forLocalFile: resolved) {
                    resolvedThumbnailURL = cached
                    cachedListThumbnailURL = cached
                    return
                }
                // 临时占位：preview 或站点图（用户会先看到模糊小图，抽完变清晰）
                if cachedListThumbnailURL == nil {
                    if let preview = MediaItem.resolveLocalWorkshopPreviewImage(from: local),
                       !LocalImageThumbnailCache.isGIFFile(preview) {
                        cachedListThumbnailURL = preview
                    } else {
                        cachedListThumbnailURL = thumbnailURL ?? item.coverImageURL
                    }
                }
                applyVideoListThumbnail(for: resolved, fallbackCover: false)
                return
            }

            // 2) 无视频（web/scene 等）：用 preview / GIF
            if let localPreview = MediaItem.resolveLocalWorkshopPreviewImage(from: local) {
                if LocalImageThumbnailCache.isGIFFile(localPreview) {
                    resolvedThumbnailURL = localPreview
                    cachedListThumbnailURL = localPreview
                    return
                }
                if LocalImageThumbnailCache.isRasterImageFile(localPreview) {
                    if let cached = LocalImageThumbnailCache.shared.cachedThumbnailURLIfExists(forLocalFile: localPreview) {
                        resolvedThumbnailURL = cached
                        cachedListThumbnailURL = cached
                        return
                    }
                    if cachedListThumbnailURL == nil {
                        cachedListThumbnailURL = localPreview
                    }
                    if let thumb = await LocalImageThumbnailCache.shared.ensureThumbnail(forLocalFile: localPreview) {
                        resolvedThumbnailURL = thumb
                        cachedListThumbnailURL = thumb
                    } else {
                        resolvedThumbnailURL = localPreview
                        cachedListThumbnailURL = localPreview
                    }
                    return
                }
                resolvedThumbnailURL = localPreview
                cachedListThumbnailURL = localPreview
                return
            }

            if cachedListThumbnailURL == nil {
                cachedListThumbnailURL = thumbnailURL ?? item.coverImageURL
            }
        }
    }

    /// 列表视频封面：已有缓存直接用；否则后台生成列表帧，失败回退站点封面/高清 poster。
    @MainActor
    private func applyVideoListThumbnail(for videoURL: URL, fallbackCover: Bool) {
        if let cached = VideoThumbnailCache.shared.cachedStaticThumbnailFileURLIfExists(forLocalFile: videoURL) {
            resolvedThumbnailURL = cached
            cachedListThumbnailURL = cached
            FileExistenceCache.shared.markExisting(atPath: videoURL.path)
            return
        }
        if fallbackCover, cachedListThumbnailURL == nil {
            cachedListThumbnailURL = thumbnailURL ?? item.coverImageURL
        }
        Task { @MainActor in
            guard !LibraryScrollHoverGate.shared.isScrolling else { return }
            if let listThumb = await VideoThumbnailCache.shared.listThumbnailJPEGFileURL(forLocalVideo: videoURL) {
                resolvedThumbnailURL = listThumb
                cachedListThumbnailURL = listThumb
                FileExistenceCache.shared.markExisting(atPath: videoURL.path)
                return
            }
            // 列表帧失败：尝试高清 poster 兜底（总比空白好）
            if let poster = await VideoThumbnailCache.shared.posterJPEGFileURL(forLocalVideo: videoURL) {
                resolvedThumbnailURL = poster
                cachedListThumbnailURL = poster
                FileExistenceCache.shared.markExisting(atPath: videoURL.path)
            }
        }
    }

    /// 滚动热路径：只读父视图预计算 / 已有 state，绝不触发 `libraryGridThumbnailURL` 的磁盘扫描。
    @MainActor
    private func resolveThumbnailURL() {
        guard cachedListThumbnailURL == nil else { return }
        if let resolved = resolvedThumbnailURL {
            cachedListThumbnailURL = resolved
            return
        }
        // 父视图传入的 thumbnailURL 已尽量避开外置原图
        if let thumbnailURL {
            cachedListThumbnailURL = thumbnailURL
            return
        }
        // 无预计算时用站点封面占位；缺失缓存的生成由 scheduleThumbnailWork 滚停后补
        cachedListThumbnailURL = item.coverImageURL
    }
}

// MARK: - Wallpaper Edit Card

public struct WallpaperEditCard: View, @preconcurrency Equatable {
    let wallpaper: Wallpaper
    /// 已下载壁纸的本地文件路径（可选）；列表封面优先 SSD 缩略图，不直接读外置原图
    var localFileURL: URL? = nil
    var accent: Color = LiquidGlassColors.primaryPink
    let isEditing: Bool
    let isSelected: Bool
    var downloadDate: Date? = nil
    var progress: Double? = nil
    var progressTint: Color? = nil
    var progressLabel: String? = nil
    var cardWidth: CGFloat = LibraryCardMetrics.cardWidth
    /// 当前壁纸是否在任意屏幕上使用中。
    /// 作为存储属性由父视图计算后传入，确保 .equatable() 的 == 能正确感知
    /// 壁纸切换（若用计算属性读 @EnvironmentObject，== 比较时新旧值读到的是
    /// 同一份当前环境，恒相等，标记永不刷新）。
    var isCurrentWallpaper: Bool = false
    let action: () -> Void

    @State private var isHovered = false
    /// 指针是否在卡片内（滚动中也更新；滚停时用来恢复 isHovered）
    @State private var isPointerInside = false
    /// SSD 列表缩略图（生成后刷新，避免 KFImage 一直读 TF 上的全尺寸文件）
    @State private var cachedListThumbURL: URL?
    /// 滚动中延后的本地静图缩略图任务。
    @State private var pendingLocalThumbnailIdleToken: UUID?

    public static func == (lhs: WallpaperEditCard, rhs: WallpaperEditCard) -> Bool {
        lhs.wallpaper.id == rhs.wallpaper.id &&
        lhs.isEditing == rhs.isEditing &&
        lhs.isSelected == rhs.isSelected &&
        lhs.cardWidth == rhs.cardWidth &&
        lhs.localFileURL == rhs.localFileURL &&
        // 纳入"当前使用中"状态：壁纸切换后 .equatable() 才会重算 body、刷新标记
        lhs.isCurrentWallpaper == rhs.isCurrentWallpaper
    }

    private var thumbnailHeight: CGFloat {
        LibraryCardMetrics.thumbnailHeight
    }

    private var remoteThumbURL: URL? {
        wallpaper.thumbURL ?? wallpaper.smallThumbURL
    }

    /// 封面 URL：SSD 列表缩略图 > 站点 thumb > 绝不把外置/全尺寸原图喂给 KFImage。
    private var resolvedThumbURL: URL? {
        if let cachedListThumbURL {
            return cachedListThumbURL
        }
        if let local = localFileURL,
           local.isFileURL,
           LocalImageThumbnailCache.isRasterImageFile(local),
           let cached = LocalImageThumbnailCache.shared.cachedThumbnailURLIfExists(forLocalFile: local) {
            return cached
        }
        if let remote = remoteThumbURL {
            return remote
        }
        // 无远程 thumb 且 SSD 缓存未就绪：返回 nil → Skeleton 占位，
        // 由 ensureLocalListThumbnail 在滚停后生成并切换。
        return nil
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

                    // 当前使用中的壁纸标记
                    if !isEditing && isCurrentWallpaper {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 10, weight: .bold))
                            Text(t("wallpaper.currentlyActive"))
                                .font(.system(size: 10, weight: .bold))
                        }
                        .foregroundStyle(.white.opacity(0.95))
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(
                            Capsule(style: .continuous).fill(Color.green.opacity(0.78))
                        )
                        .padding(12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .transition(.opacity)
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
                isPointerInside = hovering
                if hovering, LibraryScrollHoverGate.shared.suppressesAnimatedHover {
                    return
                }
                isHovered = hovering
            }
        }
        .libraryScrollIdleHoverProbe { inside in
            guard !isEditing else { return }
            isPointerInside = inside
            if inside {
                isHovered = true
            } else if isHovered {
                isHovered = false
            }
        }
        .onAppear {
            ensureLocalListThumbnail()
        }
        .onChange(of: localFileURL) { _, _ in
            cachedListThumbURL = nil
            ensureLocalListThumbnail()
        }
        .onDisappear {
            if let token = pendingLocalThumbnailIdleToken {
                LibraryScrollHoverGate.shared.cancelIdleWork(token: token)
                pendingLocalThumbnailIdleToken = nil
            }
        }
    }

    /// 外置原图 → 本机 SSD 512 列表缩略图；有远程 thumb 时列表先显示远程，滚停后再补本地缓存。
    @MainActor
    private func ensureLocalListThumbnail() {
        guard let local = localFileURL,
              local.isFileURL,
              LocalImageThumbnailCache.isRasterImageFile(local) else { return }

        if let token = pendingLocalThumbnailIdleToken {
            LibraryScrollHoverGate.shared.cancelIdleWork(token: token)
            pendingLocalThumbnailIdleToken = nil
        }

        if let cached = LocalImageThumbnailCache.shared.cachedThumbnailURLIfExists(forLocalFile: local) {
            cachedListThumbURL = cached
            return
        }

        // 滚动中不生成：先靠远程 thumb / skeleton，滚停后再写 SSD
        if LibraryScrollHoverGate.shared.isScrolling {
            let token = UUID()
            pendingLocalThumbnailIdleToken = token
            LibraryScrollHoverGate.shared.runWhenIdle(token: token) {
                guard pendingLocalThumbnailIdleToken == token else { return }
                pendingLocalThumbnailIdleToken = nil
                guard let stillLocal = localFileURL,
                      stillLocal == local,
                      cachedListThumbURL == nil else { return }
                Task { @MainActor in
                    if LibraryScrollHoverGate.shared.isScrolling {
                        ensureLocalListThumbnail()
                        return
                    }
                    if let thumb = await LocalImageThumbnailCache.shared.ensureThumbnail(forLocalFile: stillLocal) {
                        cachedListThumbURL = thumb
                    }
                }
            }
            return
        }

        Task { @MainActor in
            guard !LibraryScrollHoverGate.shared.isScrolling else { return }
            if let thumb = await LocalImageThumbnailCache.shared.ensureThumbnail(forLocalFile: local) {
                cachedListThumbURL = thumb
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
