import SwiftUI
import AVKit
import AVFoundation
import AppKit
import Kingfisher
import WebKit

struct MediaDetailSheet: View {
    let initialItem: MediaItem
    @ObservedObject var viewModel: MediaExploreViewModel
    let contextItems: [MediaItem]?
    let onClose: () -> Void
    /// 当需要在 NavigationStack 中 push 新媒体项时调用（如作者列表点击）
    let onNavigateToItem: ((MediaItem) -> Void)?

    @ObservedObject private var wallpaperManager = VideoWallpaperManager.shared
    @ObservedObject private var mediaLibrary = MediaLibraryService.shared
    @ObservedObject private var displaySelectorManager = DisplaySelectorManager.shared
    @ObservedObject private var frameInterpolationQueue = VideoOptimizationQueueService.shared
    @State private var resolvedItem: MediaItem
    @State private var downloadActivity = DetailDownloadActivity()
    @State private var isSettingWallpaper = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var isMuted = true
    @State private var isVisible = false
    @State private var isMediaLoaded = false
    @State private var isSourcesReady = false // 来源是否排序/加载完毕
    @State private var scrollOffset: CGFloat = 0
    @State private var showInfoBubble = false
    @State private var isHeroContentHidden = false
    @State private var showDeleteConfirm = false
    @State private var showSteamLoginRequiredAlert = false
    @State private var steamLoginRequiredMessage = ""
    @State private var isBakingScene = false
    @State private var showSceneBakeRendererDialog = false
    @State private var sceneBakeDialogAnimating = false
    @State private var sceneBakeShouldClearCachedArtifact = false
    @State private var activeScenePreviewRenderer: SceneBakeRenderer?
    /// 烘焙进度 0.0 ~ 1.0
    @State private var bakeProgress: Double = 0

    /// Workshop 自动下载后设置壁纸的后台任务引用。
    /// 持有它以便在重新发起设置 / 视图消失时取消，避免 sheet 关闭后仍执行壁纸应用造成竞态。
    @State private var autoDownloadTask: Task<Void, Never>?

    // MARK: - 作者壁纸弹窗相关
    @State private var showAuthorSheet = false
    @State private var authorMediaItems: [MediaItem] = []
    @State private var isLoadingAuthorItems = false
    @State private var authorItemsPage = 1
    @State private var hasMoreAuthorItems = true
    /// 已加载的作者 Steam ID，防止面板已打开时重复加载
    @State private var authorLoadedSteamID: String?

    // MARK: - 键盘快捷键与滑动动画
    @State private var keyboardMonitor: Any?
    @State private var slideIncomingOffset: CGFloat = 0
    @State private var slideOutgoingOffset: CGFloat = 0
    @State private var isNavigating = false
    /// 从作者面板切换时使用淡入淡出过渡（而非滑动）
    @State private var isAuthorPanelFade = false
    /// 作者媒体批量下载中状态
    @State private var isDownloadingAllAuthor = false

    private enum SlideDirection {
        case up, down
    }
    /// 烘焙成功后短暂显示在底部状态行（约 4s）
    @State private var sceneBakeStatusFlash: String?
    @State private var applyingWallpaperStatusKey = "applyingWallpaper"
    @State private var sharePickerAnchorView: NSView?
    @State private var showCopyLinkToast = false
    @State private var copyToastMessage = "链接已复制"
    @State private var showMoreOptionsPopover = false
    @State private var showDeleteBakeConfirm = false
    @State private var showRedownloadConfirm = false
    @State private var showRemoveFrameInterpolationBlacklistConfirm = false
    @State private var pendingRemoveFrameInterpolationBlacklistURL: URL?
    @State private var isDeletingBake = false
    /// 删除烘焙 / 本地预览源变化时递增，强制详情背景重建（避免仍挂已删 MP4 黑屏）
    @State private var mediaBackgroundEpoch: Int = 0
    @State private var isResettingVideoOptimization = false
    @State private var isTranscodingVideo = false
    @State private var transcodeVideoProgress: Double = 0
    /// Workshop 已下载项是否有远端更新
    @State private var hasWorkshopUpdateAvailable: Bool = false
    @State private var remoteWorkshopUpdatedAt: Date?
    /// 当前下载流程是否为「更新重下」（用于 Steam Guard 重试）。
    /// 保存发起更新的 item ID，避免切换详情后把 A 的更新态显示在 B 上。
    @State private var workshopUpdateItemID: String?

    // 挤压动画配置
    private let squeezeThreshold: CGFloat = 80
    private let maxSqueezeOffset: CGFloat = 120

    // MARK: - 下一张弹窗相关
    @StateObject private var nextItemDataSource = NextItemDataSource()
    @State private var currentItemIndex: Int = 0

    private var prefetchNamespace: String {
        "media-detail-\(initialItem.id)"
    }

    // 计算属性：当前媒体项
    var item: MediaItem { resolvedItem }

    private var isDownloading: Bool {
        downloadActivity.isDownloading(itemID: resolvedItem.id)
    }

    private var isWorkshopUpdateFlow: Bool {
        workshopUpdateItemID == resolvedItem.id
    }

    init(item: MediaItem, viewModel: MediaExploreViewModel, contextItems: [MediaItem]? = nil, onClose: @escaping () -> Void, onNavigateToItem: ((MediaItem) -> Void)? = nil) {
        self.initialItem = item
        self.viewModel = viewModel
        self.contextItems = contextItems
        self.onClose = onClose
        self.onNavigateToItem = onNavigateToItem
        _resolvedItem = State(initialValue: item)
    }

    /// 当前导航使用的媒体列表（本地上下文优先，否则使用线上列表）
    private var navigationItems: [MediaItem] {
        contextItems ?? viewModel.items
    }

    // MARK: - 本地文件检测
    private var isLocalFile: Bool {
        resolvedItem.id.hasPrefix("local_") || resolvedItem.sourceName == t("local")
    }

    /// 是否已下载（包括网络下载和本地文件）
    private var isAlreadyDownloaded: Bool {
        isLocalFile || viewModel.isDownloaded(resolvedItem)
    }

    /// 已下载 Workshop 项且检测到远端更新
    private var canUpdateWorkshopDownload: Bool {
        isAlreadyDownloaded
            && !isLocalFile
            && resolvedItem.id.hasPrefix("workshop_")
            && hasWorkshopUpdateAvailable
    }

    /// 与库右键一致：已下载且有远端源时才可重新下载（本地导入除外）
    private var canRedownloadItem: Bool {
        guard !isLocalFile else { return false }
        return mediaLibrary.downloadRecord(for: resolvedItem.id)?.isActive == true
            || viewModel.isDownloaded(resolvedItem)
    }

    private var downloadActionSystemName: String {
        if canUpdateWorkshopDownload || isWorkshopUpdateFlow {
            return "arrow.triangle.2.circlepath"
        }
        return isAlreadyDownloaded ? "checkmark" : "arrow.down"
    }

    private var currentDownloadRecord: MediaDownloadRecord? {
        mediaLibrary.downloadedItems.first { $0.item.id == resolvedItem.id }
    }

    private var cachedSceneBakeVideoURL: URL? {
        guard let art = SceneOfflineBakeService.usableArtifact(from: currentDownloadRecord) else {
            return nil
        }
        let url = URL(fileURLWithPath: art.videoPath)
        guard SceneOfflineBakeService.isUsableBakedVideo(at: url) else { return nil }
        return url
    }

    /// 烘焙服务会在任务完全收尾前写回 MP4 成品。详情背景必须等 UI 的烘焙态结束，
    /// 否则会过早销毁静态封面、切到尚未准备好的 AVPlayer，导致黑屏加载。
    private var backgroundSceneBakeVideoURL: URL? {
        guard !isBakingScene else { return nil }
        return cachedSceneBakeVideoURL
    }

    private var currentDownloadedWallpaperEngineProjectType: String? {
        guard let record = currentDownloadRecord else { return nil }
        let contentRoot = WorkshopService.resolveWallpaperEngineProjectRoot(
            startingAt: record.localFileURL
        )
        return Self.projectTypeString(at: contentRoot)
    }

    private var isCurrentDownloadedSceneProject: Bool {
        currentDownloadedWallpaperEngineProjectType == "scene"
    }

    private var isCurrentDownloadedWebProject: Bool {
        currentDownloadedWallpaperEngineProjectType == "web"
    }

    private var sceneOfflineBakeButtonVisible: Bool {
        guard isAlreadyDownloaded, currentDownloadRecord != nil else { return false }
        return isCurrentDownloadedSceneProject || isCurrentDownloadedWebProject
    }

    var body: some View {
        GeometryReader { geometry in
            let horizontalPadding = max(28, min(72, geometry.size.width * 0.05))
            let topBarTopInset = max(geometry.safeAreaInsets.top, 18)
            let bottomSafeInset = max(geometry.safeAreaInsets.bottom, 28)

            let viewW = geometry.size.width
            let viewH = geometry.size.height

            ZStack(alignment: .topLeading) {
                Color(hex: "0A0A0C")
                    .ignoresSafeArea()
                    .coordinateSpace(name: "scroll")

                if isVisible {
                    fixedMediaBackground(width: viewW, height: viewH)
                        .id("media-bg-\(resolvedItem.id)-\(mediaBackgroundEpoch)-\(previewVideoURL?.path ?? heroImageURL.path)")
                        .transition(
                            isAuthorPanelFade
                                ? AnyTransition.opacity.animation(.easeInOut(duration: 0.28))
                                : AnyTransition.asymmetric(
                                    insertion: .offset(y: slideIncomingOffset).combined(with: .opacity),
                                    removal: .offset(y: slideOutgoingOffset).combined(with: .opacity)
                                  )
                                  .animation(.easeInOut(duration: 0.3))
                        )
                }

                // 媒体加载动画
                if !isMediaLoaded && !isNavigating {
                    LoadingOverlayView()
                        .frame(width: viewW, height: viewH)
                        .transition(.opacity.animation(.easeInOut(duration: 0.3)))
                }

                ZStack {
                    VStack {
                        LinearGradient(
                            colors: [Color.black.opacity(0.52), Color.black.opacity(0.18), Color.clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 180)
                        Spacer()
                    }
                    VStack {
                        Spacer()
                        LinearGradient(
                            colors: [Color.clear, Color.black.opacity(0.26), Color.black.opacity(0.56)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: min(viewH * 0.36, 440))
                    }
                }
                .allowsHitTesting(false)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        Color.clear
                            .frame(height: detailScrollTopInset(viewportHeight: viewH, heroHidden: isHeroContentHidden))

                        Color.clear
                            .frame(height: 1)
                            .padding(.horizontal, horizontalPadding)
                            .padding(.bottom, bottomSafeInset + 88)
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                    .background(
                        GeometryReader { proxy in
                            Color.clear
                                .preference(key: ScrollOffsetPreferenceKey.self, value: proxy.frame(in: .named("scroll")).minY)
                        }
                    )
                }
                .scrollClipDisabled()
                .safeAreaPadding(.bottom, bottomSafeInset)
                .background(Color.clear)
                .onPreferenceChange(ScrollOffsetPreferenceKey.self) { value in
                    scrollOffset = value
                }
                .overlay(alignment: .top) {
                    fixedHeroChrome(
                        viewportWidth: viewW,
                        topBarTopInset: topBarTopInset
                    )
                }

                if showInfoBubble {
                    Color.black.opacity(0.001)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture {
                            // iOS 丝滑关闭：弹簧动画
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.85, blendDuration: 0)) {
                                showInfoBubble = false
                            }
                        }
                }

                DetailSheetWindowControls()
                    .zIndex(110)

                floatingBackButton
                    .padding(.top, max(topBarTopInset, DetailSheetTopBarLayout.actionRowTop))
                    .padding(.leading, DetailSheetTopBarLayout.actionRowLeading)
                    .zIndex(100)

                floatingInfoOverlay(
                    viewportWidth: viewW,
                    topBarTopInset: topBarTopInset
                )
                .zIndex(100)

                // 下一张弹窗 - 固定在右下角，不覆盖全屏
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        LiquidGlassNextItemToast(
                            nextItem: nextItemDataSource.nextItem,
                            onTap: {
                                navigateToNextMedia()
                            },
                            onScrollUp: {
                                navigateToNextMedia()
                            },
                            onScrollDown: {
                                navigateToPreviousMedia()
                            },
                            onPreload: { _ in
                                // 预加载下一张媒体
                                if let nextMedia = nextItemDataSource.nextItem as? MediaItem {
                                    // 预加载图片
                                    let imageURL = nextMedia.posterURL ?? nextMedia.thumbnailURL
                                    ForegroundPrefetchManager.shared.start(
                                        urls: [imageURL],
                                        namespace: prefetchNamespace
                                    )
                                    // 预加载视频（如果存在）
                                    if let videoURL = nextMedia.previewVideoURL {
                                        VideoPreloader.shared.preload(url: videoURL)
                                    }
                                }
                            }
                        )
                        .padding(.trailing, 28)
                        .padding(.bottom, 28)
                    }
                }

            }
            .overlay(alignment: .bottom) {
                if showCopyLinkToast {
                    Text(copyToastMessage)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(
                            Capsule()
                                .fill(.ultraThinMaterial)
                                .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 0.5))
                        )
                        .padding(.bottom, 48)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: showCopyLinkToast)
                }
                VStack(spacing: 8) {
                    if isTranscodingVideo {
                        MediaProcessingToast(
                            title: String(format: t("transcodingToast"), Int(transcodeVideoProgress * 100)),
                            detail: nil,
                            progress: transcodeVideoProgress
                        )
                    }

                }
                .padding(.bottom, 48)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .ignoresSafeArea()
        .alert(t("mediaError"), isPresented: $showError) {
            Button(t("ok"), role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .alert(t("delete"), isPresented: $showDeleteConfirm) {
            Button(t("delete"), role: .destructive) {
                viewModel.removeDownloads(withIDs: [resolvedItem.id])
                onClose()
            }
            Button(t("cancel"), role: .cancel) {}
        } message: {
            Text(t("deleteConfirmMessage"))
        }
        .alert(t("library.redownload.item.confirm.title"), isPresented: $showRedownloadConfirm) {
            Button(t("library.redownload.item"), role: .destructive) {
                redownloadCurrentItem()
            }
            Button(t("cancel"), role: .cancel) {}
        } message: {
            Text(t("library.redownload.item.confirm.message"))
        }
        .alert("删除烘焙产物?", isPresented: $showDeleteBakeConfirm) {
            Button("删除", role: .destructive) {
                Task { await performDeleteSceneBakeKeepingPoster() }
            }
            Button(t("cancel"), role: .cancel) {}
        } message: {
            Text("将删除该壁纸的离线烘焙视频，静态预览图保留。删除后会立即用静态图替换正在显示的锁屏/桌面壁纸。")
        }
        .alert(t("frameInterpolationBlacklistRemoveConfirmTitle"), isPresented: $showRemoveFrameInterpolationBlacklistConfirm) {
            Button(t("frameInterpolationBlacklistRemoveButton"), role: .destructive) {
                if let url = pendingRemoveFrameInterpolationBlacklistURL {
                    frameInterpolationQueue.removeBlacklisted(videoURL: url)
                }
                pendingRemoveFrameInterpolationBlacklistURL = nil
            }
            Button(t("cancel"), role: .cancel) {
                pendingRemoveFrameInterpolationBlacklistURL = nil
            }
        } message: {
            Text(t("frameInterpolationBlacklistRemoveConfirmMessage"))
        }
        .overlay {
            authorSheetOverlay
        }
        .overlay {
            sceneBakeRendererOverlay
        }
        .onExitCommand {
            if showSceneBakeRendererDialog {
                dismissSceneBakeRendererDialog()
            }
        }
        .alert("需要重新登录 Steam", isPresented: $showSteamLoginRequiredAlert) {
            Button("稍后", role: .cancel) {}
            Button("打开设置") {
                openSteamLoginSettings()
            }
        } message: {
            Text(steamLoginRequiredMessage)
        }
        .navigationBarBackButtonHidden(true)
        .task {
            AppLogger.info(.media, "媒体详情页 onAppear",
                metadata: ["itemId": initialItem.id, "title": initialItem.title])
            isVisible = true
            restoreSceneBakeProgressIfNeeded()
            setupNextItemDataSource()
            setupKeyboardMonitor()
            await loadDetailIfNeeded()
        }
        .onChange(of: resolvedItem.id) { _, _ in
            restoreSceneBakeProgressIfNeeded()
            hasWorkshopUpdateAvailable = false
            remoteWorkshopUpdatedAt = nil
            workshopUpdateItemID = nil
            Task { await checkWorkshopUpdateIfNeeded() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .sceneOfflineBakeProgressDidUpdate)) { notification in
            guard let notifItemID = notification.object as? String,
                  notifItemID == resolvedItem.id else { return }
            if let progress = notification.userInfo?["progress"] as? Double {
                if progress >= 1.0 {
                    isBakingScene = false
                    bakeProgress = 0
                    return
                }
                if !isBakingScene {
                    isBakingScene = true
                }
                updateSceneBakeProgress(progress)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .sceneOfflineBakeDidComplete)) { _ in
            // 失败时不会推 progress=1.0，用完成通知兜底清掉本页烘焙态
            if isBakingScene,
               SceneOfflineBakeProgressTracker.shared.progress(for: resolvedItem.id) == nil {
                isBakingScene = false
                bakeProgress = 0
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .sceneOfflineBakeThumbnailDidUpdate)) { notification in
            guard let itemID = notification.object as? String,
                  itemID == resolvedItem.id,
                  cachedSceneBakeVideoURL == nil else {
                return
            }
            isMediaLoaded = false
            mediaBackgroundEpoch &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .localMediaPosterDidUpdate)) { notification in
            guard let itemID = notification.object as? String,
                  itemID == resolvedItem.id,
                  cachedSceneBakeVideoURL == nil else {
                return
            }
            isMediaLoaded = false
            mediaBackgroundEpoch &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .steamWorkshopLoginRequired)) { notification in
            guard let itemID = notification.object as? String,
                  itemID == resolvedItem.id else {
                return
            }
            let message = notification.userInfo?["message"] as? String
            presentSteamLoginRequired(message)
        }
        .onDisappear {
            isVisible = false
            ForegroundPrefetchManager.shared.stop(namespace: prefetchNamespace)
            removeKeyboardMonitor()
            SceneOfflineBakeService.stopPreview()
            // 兜底：sheet 消失时取消可能仍在运行的自动下载任务，
            // 避免下载完成后对已关闭的 sheet 执行壁纸应用造成竞态
            autoDownloadTask?.cancel()
            autoDownloadTask = nil
        }
    }

    /// 无循环烘焙视频时，优先复用 Scene 高清抽帧，再回退 catalog/远程缩略图。
    private var heroImageURL: URL {
        // 临时 1 秒烘焙不会写入 artifact，但会留下稳定的 item 级 JPEG poster。
        // 详情页应优先展示它，避免退化到 Workshop 的低分辨率 preview.*。
        if backgroundSceneBakeVideoURL == nil {
            if let posterURL = cachedSceneBakePosterURL {
                return posterURL
            }
            // 自动烘焙关闭时实时渲染只写 scene_realtime_*；不读它会让详情页
            // 一直停留在 Workshop 旧预览图。
            if let realtimePosterURL = cachedSceneRealtimePosterURL {
                return realtimePosterURL
            }
            if let posterURL = cachedLocalVideoPosterURL {
                return posterURL
            }
            if let previewURL = localWorkshopPreviewFallbackURL {
                return previewURL
            }
            return undownloadedStylePreviewImageURL
        }
        return resolvedItem.coverImageURL
    }

    /// 仅在不存在可播放的烘焙视频时读取静帧缓存。
    /// 烘焙正在收尾时继续沿用原有预览图，避免旧 poster 抢占即将切入的循环视频。
    private var cachedSceneBakePosterURL: URL? {
        guard cachedSceneBakeVideoURL == nil,
              let itemID = currentDownloadRecord?.item.id else {
            return nil
        }
        return VideoThumbnailCache.shared.cachedSceneBakePosterFileURLIfExists(itemID: itemID)
    }

    /// 自动烘焙关闭时实时渲染的临时抽帧静帧（`scene_realtime_*`）。
    /// 正式烘焙封面 `scene_bake_*` 缺席时的次级回退。
    private var cachedSceneRealtimePosterURL: URL? {
        guard cachedSceneBakeVideoURL == nil,
              let itemID = currentDownloadRecord?.item.id else {
            return nil
        }
        return VideoThumbnailCache.shared.latestSceneRealtimePosterFileURLIfExists(itemID: itemID)
    }

    /// 普通本地视频抽出的高清 poster。Scene 未烘焙时可作为详情页背景兜底，
    /// 避免 Scene 识别先关掉视频背景而静帧尚未接入，退化为黑底。
    private var cachedLocalVideoPosterURL: URL? {
        guard let videoURL = currentDownloadRecord?.resolvedVideoFileURL,
              Self.previewVideoExtensions.contains(videoURL.pathExtension.lowercased()) else {
            return nil
        }
        return VideoThumbnailCache.shared.cachedPosterJPEGFileURLIfExists(forLocalVideo: videoURL)
    }

    /// 下载的 Workshop 工程自带预览图。静帧未生成前优先于远程 Steam 缩略图，
    /// 确保离线或远程预览失效时仍有可显示的本地背景。
    private var localWorkshopPreviewFallbackURL: URL? {
        if let recordURL = currentDownloadRecord?.localFileURL,
           let previewURL = MediaItem.resolveLocalWorkshopPreviewImage(from: recordURL) {
            return previewURL
        }
        return localWorkshopPreviewImageURL(for: resolvedItem)
    }

    /// 列表/探索未下载时常用的封面：thumbnail 优先，再 poster。
    /// 必须只读当前 `resolvedItem`：作者列表/键盘切换会原地替换详情，
    /// 若仍优先 `initialItem`，背景会继续显示打开详情页时那张旧 GIF/封面。
    private var undownloadedStylePreviewImageURL: URL {
        // 远程/原始 thumbnail 最接近「未下载」详情观感
        let candidates: [URL?] = [
            resolvedItem.thumbnailURL,
            resolvedItem.posterURL,
            resolvedItem.coverImageURL
        ]

        for case let url? in candidates {
            if url.isFileURL {
                if FileExistenceCache.shared.fileExists(atPath: url.path) {
                    return url
                }
                continue
            }
            // 远程 URL 直接可用（Kingfisher 拉取）
            return url
        }
        return resolvedItem.thumbnailURL
    }

    private var previewVideoURL: URL? {
        // 仅在有可用烘焙 MP4 时用循环视频作详情背景
        if let backgroundSceneBakeVideoURL {
            return backgroundSceneBakeVideoURL
        }

        // 只有资源本身是视频时才播放本地视频；Scene/Web 工程内的素材视频不能当详情背景。
        if let localVideo = resolvedLocalPreviewVideoURL() {
            return localVideo
        }

        // Scene / Web 等非视频工程没有烘焙成片时只显示静态 poster / preview，
        // 不播放工程内或远程预览视频。
        if isKnownNonVideoLocalProject || sceneOfflineBakeButtonVisible {
            return nil
        }

        if let preview = resolvedItem.previewVideoURL {
            if preview.isFileURL {
                guard FileExistenceCache.shared.fileExists(atPath: preview.path),
                      Self.previewVideoExtensions.contains(preview.pathExtension.lowercased()) else {
                    return nil
                }
                return preview
            }
            return preview
        }
        return nil
    }

    private static let previewVideoExtensions: Set<String> = ["mp4", "mov", "webm", "m4v", "mkv"]

    /// 已下载工程的明确内容类型。`nil` 表示没有 project.json，例如直接导入的普通视频。
    private var localProjectContentType: WorkshopContentType? {
        guard let localURL = currentDownloadRecord?.localFileURL else { return nil }
        let contentRoot = WorkshopService.resolveWallpaperEngineProjectRoot(startingAt: localURL)
        guard FileManager.default.fileExists(
            atPath: contentRoot.appendingPathComponent("project.json").path
        ) else {
            return nil
        }
        return determineWorkshopContentType(at: contentRoot)
    }

    private var isKnownNonVideoLocalProject: Bool {
        guard let localProjectContentType else { return false }
        if case .video = localProjectContentType {
            return false
        }
        return true
    }

    /// 从下载记录 / Workshop 本地路径解析可用于详情页背景循环的原始视频。
    /// 仅允许直接视频文件或 `project.json.type == "video"` 的工程。
    private func resolvedLocalPreviewVideoURL() -> URL? {
        let fileCache = FileExistenceCache.shared
        var candidates: [URL] = []
        if let recordURL = currentDownloadRecord?.localFileURL {
            candidates.append(recordURL)
        }
        if let workshop = findLocalWorkshopFile(for: resolvedItem) {
            candidates.append(workshop)
        }

        var seen = Set<String>()
        for candidate in candidates {
            let path = candidate.standardizedFileURL.path
            guard seen.insert(path).inserted else { continue }
            guard fileCache.fileExists(atPath: path) else { continue }

            let contentRoot = WorkshopService.resolveWallpaperEngineProjectRoot(startingAt: candidate)
            let projectType: WorkshopContentType? = FileManager.default.fileExists(
                atPath: contentRoot.appendingPathComponent("project.json").path
            ) ? determineWorkshopContentType(at: contentRoot) : nil

            if let projectType, projectType != .video {
                continue
            }

            if Self.previewVideoExtensions.contains(candidate.pathExtension.lowercased()) {
                return candidate
            }
            // 明确 video 类型的 Workshop 工程：解析其实际视频文件。
            if let videoURL = MediaItem.resolveLocalVideoFile(from: candidate),
               fileCache.fileExists(atPath: videoURL.path) {
                return videoURL
            }
        }
        return nil
    }

    /// 下载 / 更新完成后：注入本地视频与预览图，让详情页背景立刻切到本地资源。
    /// 作者面板可原地切换详情；异步任务只能刷新其发起时对应的 item。
    @MainActor
    private func refreshResolvedItemAfterLocalDownload(for itemID: String) -> Bool {
        guard resolvedItem.id == itemID else { return false }

        let merged = mediaItemByMergingAuthorMetadata(resolvedItem, fallback: resolvedItem)
        var item = itemWithLocalWorkshopVideo(merged)
        item = itemWithCorrectedWorkshopPageURL(item)

        // 普通媒体直链下载：下载记录是 mp4 时也写入 previewVideoURL
        if item.previewVideoURL == nil || !(item.previewVideoURL?.isFileURL ?? false),
           let localVideo = resolvedLocalPreviewVideoURL() {
            item = MediaItem(
                slug: item.slug,
                title: item.title,
                pageURL: item.pageURL,
                thumbnailURL: item.thumbnailURL,
                resolutionLabel: item.resolutionLabel,
                collectionTitle: item.collectionTitle,
                summary: item.summary,
                previewVideoURL: localVideo,
                posterURL: item.posterURL,
                tags: item.tags,
                exactResolution: item.exactResolution,
                durationSeconds: item.durationSeconds,
                downloadOptions: item.downloadOptions,
                sourceName: item.sourceName,
                isAnimatedImage: item.isAnimatedImage,
                subscriptionCount: item.subscriptionCount,
                favoriteCount: item.favoriteCount,
                viewCount: item.viewCount,
                ratingScore: item.ratingScore,
                authorName: item.authorName,
                authorSteamID: item.authorSteamID,
                authorAvatarURL: item.authorAvatarURL,
                fileSize: item.fileSize,
                createdAt: item.createdAt,
                updatedAt: item.updatedAt
            )
        }

        // 新落盘路径可能尚未进 FileExistenceCache，标记存在以免本帧仍判不存在
        if let recordURL = currentDownloadRecord?.localFileURL {
            FileExistenceCache.shared.markExisting(atPath: recordURL.path)
            if let nestedVideo = MediaItem.resolveLocalVideoFile(from: recordURL) {
                FileExistenceCache.shared.markExisting(atPath: nestedVideo.path)
            }
        }
        if let localVideo = resolvedLocalPreviewVideoURL() {
            FileExistenceCache.shared.markExisting(atPath: localVideo.path)
        }

        // 强制背景视图按新 URL 重建（.id 依赖 preview 路径）
        isMediaLoaded = false
        resolvedItem = item
        return true
    }

    private func detailScrollTopInset(viewportHeight: CGFloat, heroHidden: Bool) -> CGFloat {
        if heroHidden {
            return max(min(viewportHeight * 0.42, 380), 300)
        }
        return max(min(viewportHeight * 0.58, 520), 420)
    }

    @ViewBuilder
    private func fixedMediaBackground(width: CGFloat, height viewH: CGFloat) -> some View {
        ZStack {
            // 远程视频失败（如 CDN 鉴权）时仍有封面垫底，避免纯黑详情背景。
            let heroLayoutSize = CGSize(width: width, height: viewH)
            let heroDownsampleSize = CGSize(
                width: min(max(width * 2, 1), 2400),
                height: min(max(viewH * 2, 1), 2400)
            )
            let showPosterUnderVideo = previewVideoURL != nil && !(previewVideoURL?.isFileURL ?? true)

            if previewVideoURL == nil || showPosterUnderVideo {
                KFMediaCoverImage(
                    url: heroImageURL,
                    animated: resolvedItem.shouldRenderThumbnailAsAnimatedImage,
                    downsampleSize: heroDownsampleSize,
                    fadeDuration: 0.3,
                    loadFinished: {
                        // 仅在没有视频、或视频尚未 ready 时由封面结束 loading
                        if previewVideoURL == nil {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                isMediaLoaded = true
                            }
                        }
                    },
                    layoutSize: heroLayoutSize,
                    playAnimatedImage: previewVideoURL == nil
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let previewVideoURL {
                LoopingVideoBackgroundView(
                    url: previewVideoURL,
                    isMuted: isMuted,
                    onReady: { @MainActor in
                        withAnimation(.easeInOut(duration: 0.3)) {
                            isMediaLoaded = true
                        }
                    }
                )
            }

            LinearGradient(
                colors: [
                    Color.black.opacity(0.22),
                    Color.black.opacity(0.10),
                    Color.black.opacity(0.34)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            Rectangle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.clear,
                            Color.black.opacity(0.12),
                            Color.black.opacity(0.34)
                        ],
                        center: .center,
                        startRadius: 120,
                        endRadius: max(width, viewH)
                    )
                )
        }
        .frame(width: width, height: viewH)
        .clipped()
        .ignoresSafeArea()
    }

    private func fixedHeroChrome(viewportWidth: CGFloat, topBarTopInset: CGFloat) -> some View {
        // 计算挤压进度：0 表示未滚动，1 表示达到最大挤压
        let squeezeProgress = min(max(-scrollOffset / squeezeThreshold, 0), 1)
        let scaleY = 1 - (squeezeProgress * 0.15) // 最大挤压到 85%
        let offsetY = -squeezeProgress * maxSqueezeOffset * 0.3
        let opacity = 1 - (squeezeProgress * 0.3)

        return VStack(spacing: 0) {
            // 预留给标题栏红绿灯 + 下方返回/工具行，避免标题区与顶栏控件重叠
            Spacer()
                .frame(height: max(topBarTopInset, DetailSheetTopBarLayout.heroContentTop))

            VStack(spacing: 18) {
                if !isHeroContentHidden {
                    detailCategoryBadge

                    Text(mediaTitle)
                        .font(.system(size: 52, weight: .bold, design: .serif))
                        .tracking(-1.3)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .frame(maxWidth: 980)
                        .detailGlassTitleChrome()

                    HStack(spacing: 0) {
                        metadataCapsules
                    }
                    .frame(maxWidth: .infinity, alignment: .center)

                    buttonRowWithDividers

                    if sceneOfflineBakeButtonVisible {
                        sceneBakeActionRow
                    }
                }

                Text(statusText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .opacity(statusText.isEmpty ? 0 : 1)
            }
            .frame(maxWidth: 920)
            .frame(maxWidth: .infinity)
        }
        .frame(width: viewportWidth)
        .scaleEffect(x: 1, y: scaleY, anchor: .center)
        .offset(y: offsetY)
        .opacity(opacity)
        .animation(.easeOut(duration: 0.15), value: scrollOffset)
    }

    // MARK: - 顶部返回按钮（设置壁纸中禁用，下载时可返回）
    private var floatingBackButton: some View {
        let shouldBlockBack = isSettingWallpaper || displaySelectorManager.isShowingSelector
        return Button {
            if shouldBlockBack {
                AppLogger.warn(.ui, "返回被阻止：设置壁纸或选择显示器进行中",
                    metadata: [
                        "isSettingWallpaper": isSettingWallpaper,
                        "isShowingDisplaySelector": displaySelectorManager.isShowingSelector
                    ])
                return
            }
            onClose()
        } label: {
            DetailSheetCircleIconLabel(
                systemName: "chevron.left",
                foreground: shouldBlockBack ? .white.opacity(0.35) : .white.opacity(0.95),
                fontSize: 15,
                frameSide: 38
            )
            .detailGlassCircleChrome()
            .opacity(shouldBlockBack ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .disabled(shouldBlockBack)
    }

    private func floatingInfoOverlay(viewportWidth: CGFloat, topBarTopInset: CGFloat) -> some View {
        let bubbleWidth = min(360, max(260, viewportWidth - 84))

        return VStack(alignment: .trailing, spacing: 14) {
            HStack(spacing: 10) {
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.85, blendDuration: 0)) {
                        showInfoBubble.toggle()
                    }
                } label: {
                    DetailSheetCircleIconLabel(
                        systemName: showInfoBubble ? "info.circle.fill" : "info.circle",
                        foreground: .white.opacity(0.95),
                        fontSize: 16,
                        frameSide: 40
                    )
                    .detailGlassCircleChrome()
                }
                .buttonStyle(.plain)

                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.85, blendDuration: 0)) {
                        isHeroContentHidden.toggle()
                    }
                } label: {
                    DetailSheetCircleIconLabel(
                        systemName: isHeroContentHidden ? "eye.slash" : "eye",
                        foreground: .white.opacity(0.95),
                        fontSize: 16,
                        frameSide: 40
                    )
                    .detailGlassCircleChrome()
                }
                .buttonStyle(.plain)

                if isAlreadyDownloaded {
                    Button {
                        showDeleteConfirm = true
                    } label: {
                        DetailSheetCircleIconLabel(
                            systemName: "trash",
                            foreground: Color(hex: "FF5A7D"),
                            fontSize: 16,
                            frameSide: 40
                        )
                        .detailGlassCircleChrome(tint: Color(hex: "FF5A7D").opacity(0.25))
                    }
                    .buttonStyle(.plain)
                }
            }

            if showInfoBubble {
                detailInfoBubble(width: bubbleWidth)
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.88, anchor: .topTrailing).combined(with: .opacity),
                            removal: .scale(scale: 0.94, anchor: .topTrailing).combined(with: .opacity)
                        )
                    )
            }
        }
        // 与左侧返回按钮同一动作行基线（红绿灯单独在上方）
        .padding(.top, max(topBarTopInset, DetailSheetTopBarLayout.actionRowTop))
        .padding(.trailing, DetailSheetTopBarLayout.actionRowTrailing)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .zIndex(2)
    }

    private var detailCategoryBadge: some View {
        Text(resolvedItem.subtitle == resolvedItem.resolutionLabel
             ? resolvedItem.subtitle
             : "\(resolvedItem.subtitle) · \(resolvedItem.resolutionLabel)")
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.white.opacity(0.85))
            .tracking(2)
            .padding(.horizontal, 16)
            .frame(height: 34)
            .detailGlassCapsuleChrome(level: .prominent)
    }

    private var metadataItems: [(label: String, value: String)] {
        var items: [(String, String)] = [
            (t("source"), resolvedItem.sourceName)
        ]

        // Workshop 源显示丰富的元数据胶囊（作者、订阅、浏览、评分、大小、类型）
        if resolvedItem.sourceName == t("wallpaperEngine") {
            if resolvedItem.authorSteamID != nil || resolvedItem.authorName != nil {
                items.append((t("author"), resolvedItem.authorName ?? t("unknown")))
            }
            items.append((t("fileType"), resolvedItem.resolutionLabel))
            if let subs = resolvedItem.subscriptionCount, subs > 0 {
                items.append((t("subscriptions"), formatCount(subs)))
            }
            if let views = resolvedItem.viewCount, views > 0 {
                items.append((t("views"), formatCount(views)))
            }
            if let rating = resolvedItem.ratingScore {
                items.append((t("rating"), String(format: "%.1f", rating)))
            }
            if let fileSize = resolvedItem.fileSize, fileSize > 0 {
                items.append((t("size"), formatFileSize(fileSize)))
            }
        } else {
            // MotionBG / 其他源保持原有逻辑
            if let exactResolution = resolvedItem.exactResolution, !exactResolution.isEmpty {
                items.append((t("specs2"), exactResolution))
            } else {
                items.append((t("specs2"), resolvedItem.resolutionLabel))
            }
            if let duration = resolvedItem.durationLabel {
                items.append((t("duration"), duration))
            }
            if !resolvedItem.downloadOptions.isEmpty {
                items.append((t("download2"), "\(resolvedItem.downloadOptions.count) \(t("items"))"))
            }
        }

        return items
    }

    private func detailMetaCapsule(label: String, value: String, isLast: Bool = false, isInteractive: Bool = false) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
            if isInteractive {
                detailDisclosureIndicator
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 32)
        .detailGlassCapsuleChrome(level: .prominent)
        .padding(.trailing, isLast ? 0 : 8)
    }

    private var metadataCapsules: some View {
        ForEach(Array(metadataItems.enumerated()), id: \.offset) { index, item in
            if item.label == t("author"),
               resolvedItem.sourceName == t("wallpaperEngine"),
               resolvedItem.authorSteamID != nil {
                Button {
                    openAuthorSheet()
                } label: {
                    detailMetaCapsule(
                        label: item.label,
                        value: item.value,
                        isLast: index == metadataItems.count - 1,
                        isInteractive: true
                    )
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
            } else {
                detailMetaCapsule(
                    label: item.label,
                    value: item.value,
                    isLast: index == metadataItems.count - 1
                )
            }
        }
    }

    private var sceneBakeActionRow: some View {
        VStack(spacing: 8) {
            Text(isBakingScene ? sceneBakeProgressSubtitle : t("sceneBake.tierHint"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)

            if !isBakingScene {
                Text(t("sceneBake.memoryHint"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.42))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }

            Button {
                // 「预渲染循环视频」= 应用/生成烘焙 MP4，不走实时 Web/Scene。
                // 有成片时直接把 MP4 设为视频壁纸（与 scene 非实时路径一致）。
                if let bakedURL = cachedSceneBakeVideoURL {
                    applyBakedLoopVideoAsWallpaper(bakedURL)
                } else if isCurrentDownloadedWebProject {
                    runWebOfflineBake(clearCachedArtifact: false)
                } else {
                    presentSceneBakeRendererDialog(clearCachedArtifact: false)
                }
            } label: {
                HStack(spacing: 8) {
                    if isBakingScene {
                        // 圆形进度条
                        ZStack {
                            // 背景圆圈
                            Circle()
                                .stroke(.white.opacity(0.2), lineWidth: 2.5)
                                .frame(width: 16, height: 16)

                            // 进度圆弧
                            Circle()
                                .trim(from: 0, to: bakeProgress)
                                .stroke(.white, lineWidth: 2.5)
                                .rotationEffect(.degrees(-90))
                                .frame(width: 16, height: 16)
                                .animation(.easeInOut(duration: 0.2), value: bakeProgress)
                        }
                        .frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "film.stack")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    if isBakingScene {
                        Text("\(Int(bakeProgress * 100))%")
                            .font(.system(size: 14, weight: .semibold))
                            .monospacedDigit()
                    } else {
                        Text(t("sceneBake.button"))
                            .font(.system(size: 14, weight: .semibold))
                    }
                }
                .foregroundStyle(.white.opacity(0.95))
                .padding(.horizontal, 20)
                .frame(height: 40)
                .contentShape(Capsule())
                .detailGlassCapsuleChrome(level: .prominent)
            }
            .buttonStyle(.plain)
            .disabled(isBakingScene)

            if let cachedSceneBakeVideoURL {
                Text("\(t("sceneBake.cached")) · \(cachedSceneBakeVideoURL.lastPathComponent)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }

            if currentDownloadRecord?.sceneBakeEligibility?.flags.wallClockTime == true {
                Text(t("sceneBake.wallClockHint"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }
        }
        .padding(.top, 4)
    }

    private var sceneBakeRendererOverlay: some View {
        Group {
            if showSceneBakeRendererDialog {
                ZStack {
                    Color.black.opacity(0.58)
                        .ignoresSafeArea()
                        .onTapGesture {
                            dismissSceneBakeRendererDialog()
                        }

                    VStack(alignment: .leading, spacing: 18) {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "film.stack")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(LiquidGlassColors.primaryPink)
                                .frame(width: 34, height: 34)
                                .liquidGlassSurface(
                                    .prominent,
                                    tint: LiquidGlassColors.primaryPink.opacity(0.15),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                                )

                            VStack(alignment: .leading, spacing: 4) {
                                Text(t("sceneBake.rendererDialog.title"))
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(LiquidGlassColors.textPrimary)
                                Text(t("sceneBake.rendererDialog.message"))
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(LiquidGlassColors.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Spacer()

                            Button {
                                dismissSceneBakeRendererDialog()
                            } label: {
                                DetailSheetCircleIconLabel(
                                    systemName: "xmark",
                                    foreground: LiquidGlassColors.textPrimary,
                                    fontSize: 12,
                                    frameSide: 30
                                )
                                .detailGlassCircleChrome()
                            }
                            .buttonStyle(.plain)
                            .help(t("cancel"))
                        }

                        VStack(spacing: 12) {
                            sceneBakeRendererRow(renderer: .wallpaperWgpu)
                        }
                    }
                    .padding(22)
                    .frame(width: 520)
                    .liquidGlassSurface(
                        .prominent,
                        in: RoundedRectangle(cornerRadius: 26, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .stroke(.white.opacity(0.18), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.38), radius: 28, x: 0, y: 20)
                    .scaleEffect(sceneBakeDialogAnimating ? 1.0 : 0.88)
                    .opacity(sceneBakeDialogAnimating ? 1.0 : 0.0)
                }
                .zIndex(1200)
                .transition(.opacity)
                .onAppear {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        sceneBakeDialogAnimating = true
                    }
                }
            }
        }
    }

    private func sceneBakeRendererRow(renderer: SceneBakeRenderer) -> some View {
        let available = SceneOfflineBakeService.isRendererAvailable(renderer)
        let isPreviewing = activeScenePreviewRenderer == renderer
        return HStack(spacing: 12) {
            Button {
                let chosenRenderer = renderer
                let chosenClear = sceneBakeShouldClearCachedArtifact
                dismissSceneBakeRendererDialog()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    runSceneOfflineBake(renderer: chosenRenderer, clearCachedArtifact: chosenClear)
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: renderer == .wallpaperWgpu ? "sparkles.tv" : "terminal")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(available ? .white : .white.opacity(0.34))
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(renderer == .wallpaperWgpu ? t("sceneBake.renderer.wgpu") : t("sceneBake.renderer.legacy"))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(available ? LiquidGlassColors.textPrimary : LiquidGlassColors.textQuaternary)
                            .lineLimit(1)
                        Text(renderer == .wallpaperWgpu ? "metal / live" : "legacy / offline")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(LiquidGlassColors.textTertiary)
                    }

                    Spacer()
                }
                .frame(height: 52)
                .padding(.horizontal, 14)
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .liquidGlassSurface(
                    available ? (isBakingScene ? .subtle : .prominent) : .subtle,
                    tint: available ? (renderer == .wallpaperWgpu ? LiquidGlassColors.primaryPink.opacity(0.10) : LiquidGlassColors.accentCyan.opacity(0.10)) : nil,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(available ? Color.white.opacity(0.10) : Color.clear, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(!available || isBakingScene)

            Button {
                previewSceneRenderer(renderer)
            } label: {
                Image(systemName: isPreviewing ? "eye.fill" : "eye")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(available ? LiquidGlassColors.textPrimary : LiquidGlassColors.textQuaternary)
                    .frame(width: 46, height: 52)
                    .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .liquidGlassSurface(
                        .regular,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .help(t("sceneBake.preview"))
            .disabled(!available)
        }
    }

    /// 重新烘焙：清除已有缓存后重新执行烘焙
    private func reBakeScene() {
        if isCurrentDownloadedWebProject {
            runWebOfflineBake(clearCachedArtifact: true)
        } else {
            presentSceneBakeRendererDialog(clearCachedArtifact: true)
        }
    }

    /// 「更多」菜单→「删除烘焙产物」执行体：保留静态预览图(poster)、删 MP4、并立即用静态图替换正在显示该烘焙的锁屏/桌面壁纸。
    /// sceneBakeEligibility 不动；用户后续仍可重新烘焙。
    @MainActor
    private func performDeleteSceneBakeKeepingPoster() async {
        guard !isDeletingBake else { return }
        guard let record = currentDownloadRecord,
              let artifact = record.sceneBakeArtifact else { return }
        let itemID = record.item.id
        let bakedVideoPath = artifact.videoPath
        let bakedVideoURL = URL(fileURLWithPath: bakedVideoPath)

        isDeletingBake = true
        defer { isDeletingBake = false }

        // 1. 兜底：若 poster 已被外部清理过，先从 MP4 抽帧生成（forceRegenerate: false，已存在则跳过）
        let posterURL: URL? = await VideoThumbnailCache.shared.sceneBakePosterJPEGFileURL(
            forLocalVideo: bakedVideoURL,
            itemID: itemID,
            forceRegenerate: false
        )

        // 2. 在删 MP4 之前快照"当前哪些屏在用这张烘焙视频"，删完才能正确把静态图推给它们
        let manager = VideoWallpaperManager.shared
        let affectedScreens: [NSScreen] = NSScreen.screens.filter { screen in
            guard let url = manager.videoURL(for: screen) else { return false }
            return url.standardizedFileURL.path == bakedVideoURL.standardizedFileURL.path
        }
        let affectedDisplayIDs: [UInt32] = affectedScreens.compactMap { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        }

        // 3. 删除烘焙 MP4 + 重置 artifact（保留 poster；保留 eligibility）
        MediaLibraryService.shared.clearSceneBakeArtifactKeepingPoster(itemID: itemID)

        // 4. 立刻切详情页背景：停用已删 MP4 → 未下载风格静态预览（不改桌面/锁屏）
        refreshDetailBackgroundAfterBakeDeleted(deletedBakePath: bakedVideoPath)

        // 5. 仅当确实有屏正在用这张烘焙视频，且 poster 可用时，立即用静态图替换锁屏/桌面
        guard let posterURL = posterURL,
              FileManager.default.fileExists(atPath: posterURL.path),
              !affectedScreens.isEmpty else {
            print("[MediaDetailSheet] deleteBake: skip lockscreen reset, affectedScreens=\(affectedScreens.count) posterExists=\(posterURL != nil)")
            return
        }

        let dynamicLockEnabled = UserDefaults.standard.bool(forKey: "dynamic_lock_screen_enabled")
        if dynamicLockEnabled {
            // 动态锁屏（macOS 26+）：推静态图给锁屏扩展，扩展切到静态图渲染
            do {
                try await LockScreenWallpaperService.shared.cacheStaticImageSource(
                    imageURL: posterURL,
                    displayIDs: affectedDisplayIDs
                )
                print("[MediaDetailSheet] deleteBake: pushed static image to dynamic lock screen on displays=\(affectedDisplayIDs)")
            } catch {
                print("[MediaDetailSheet] deleteBake: cacheStaticImageSource failed: \(error)")
            }
        } else {
            // 普通锁屏：写桌面壁纸，系统锁屏自动跟随
            let fillOptions: [NSWorkspace.DesktopImageOptionKey: Any] = [
                .imageScaling: NSNumber(value: NSImageScaling.scaleProportionallyUpOrDown.rawValue),
                .allowClipping: true
            ]
            for screen in affectedScreens {
                do {
                    try NSWorkspace.shared.setDesktopImageURLForAllSpaces(posterURL, for: screen, options: fillOptions)
                    DesktopWallpaperSyncManager.shared.registerWallpaperSet(posterURL, for: screen, options: fillOptions)
                } catch {
                    print("[MediaDetailSheet] deleteBake: setDesktopImageURL failed on screen=\(screen.localizedName): \(error)")
                }
            }
            print("[MediaDetailSheet] deleteBake: set desktop poster on \(affectedScreens.count) screen(s): \(posterURL.path)")
        }
    }

    /// 删除烘焙产物后**仅**刷新详情页背景（不碰桌面/锁屏）：
    /// 失效存在性缓存、清掉指向 bake 的 preview、强制重建背景层 → 未下载风格静态预览。
    @MainActor
    private func refreshDetailBackgroundAfterBakeDeleted(deletedBakePath: String) {
        let cache = FileExistenceCache.shared
        cache.invalidate(atPath: deletedBakePath)
        let standardizedBakePath = (deletedBakePath as NSString).standardizingPath
        if standardizedBakePath != deletedBakePath {
            cache.invalidate(atPath: standardizedBakePath)
        }

        // Scene/Web 可烘焙项：删 bake 后详情不再保留任何视频预览 URL
        if sceneOfflineBakeButtonVisible {
            resolvedItem.previewVideoURL = nil
        } else if let preview = resolvedItem.previewVideoURL, preview.isFileURL {
            let previewPath = preview.standardizedFileURL.path
            if previewPath == standardizedBakePath || preview.path == deletedBakePath {
                resolvedItem.previewVideoURL = nil
            }
        }

        isMediaLoaded = false
        mediaBackgroundEpoch &+= 1

        // 静态图 onFailure 也会 loadFinished；再兜一层防止卡在黑色 LoadingOverlay
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !isMediaLoaded else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                isMediaLoaded = true
            }
        }
    }

    private func presentSceneBakeRendererDialog(clearCachedArtifact: Bool) {
        guard currentDownloadRecord != nil else { return }
        sceneBakeShouldClearCachedArtifact = clearCachedArtifact
        sceneBakeDialogAnimating = false
        showSceneBakeRendererDialog = true
    }

    private func dismissSceneBakeRendererDialog() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            sceneBakeDialogAnimating = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            showSceneBakeRendererDialog = false
        }
    }

    private func previewSceneRenderer(_ renderer: SceneBakeRenderer) {
        guard let record = currentDownloadRecord else { return }
        do {
            try SceneOfflineBakeService.preview(record: record, renderer: renderer)
            activeScenePreviewRenderer = renderer
        } catch {
            errorMessage = Self.truncateErrorMessage(error.localizedDescription)
            showError = true
        }
    }

    private func updateSceneBakeProgress(_ progress: Double) {
        guard progress.isFinite else { return }
        let clamped = min(max(progress, 0.0), 0.99)
        bakeProgress = max(bakeProgress, clamped)
    }

    /// 详情页重建后从全局 tracker 恢复进行中的烘焙 UI（关闭再进入不会丢进度条）
    private func restoreSceneBakeProgressIfNeeded() {
        if let progress = SceneOfflineBakeProgressTracker.shared.progress(for: resolvedItem.id) {
            isBakingScene = true
            bakeProgress = progress
        } else if isBakingScene {
            // 切换到别的 item 或烘焙已结束：清掉陈旧本地态
            isBakingScene = false
            bakeProgress = 0
        }
    }

    private func runSceneOfflineBake(renderer: SceneBakeRenderer, clearCachedArtifact: Bool) {
        guard let record = currentDownloadRecord else { return }
        if isBakingScene { return }
        isBakingScene = true
        bakeProgress = 0
        errorMessage = ""
        // 仅首次烘焙 + 单显示器时自动设壁纸；「重新烘焙」只更新缓存，不改当前壁纸
        let shouldAutoApplyAfterBake = !clearCachedArtifact && NSScreen.screens.count <= 1
        Task {
            if clearCachedArtifact {
                await MainActor.run {
                    mediaLibrary.clearSceneBakeArtifact(itemID: record.item.id)
                }
            }
            if !clearCachedArtifact, SceneOfflineBakeService.hasCachedArtifact(record: record, renderer: renderer) {
                if let artifact = record.sceneBakeArtifact {
                    let videoURL = URL(fileURLWithPath: artifact.videoPath)
                    _ = await VideoThumbnailCache.shared.sceneBakePosterJPEGFileURL(
                        forLocalVideo: videoURL,
                        itemID: record.item.id
                    )
                    await MainActor.run {
                        isBakingScene = false
                        bakeProgress = 0
                        if shouldAutoApplyAfterBake,
                           SceneOfflineBakeService.isUsableBakedVideo(at: videoURL) {
                            // 预渲染意图：直接应用烘焙 MP4，不走实时 renderer
                            applyBakedLoopVideoAsWallpaper(videoURL)
                        } else {
                            sceneBakeStatusFlash = t("sceneBake.cached")
                        }
                    }
                    return
                }
                // 缓存记录不一致：hasCachedArtifact 返回 true 但 sceneBakeArtifact 为 nil，回退到重新烘焙
                print("[MediaDetailSheet] WARN: hasCachedArtifact true but sceneBakeArtifact nil, falling back to re-bake")
            }
            do {
                let artifact = try await SceneOfflineBakeService.bake(record: record, renderer: renderer) { progress in
                    updateSceneBakeProgress(progress)
                }
                let videoURL = URL(fileURLWithPath: artifact.videoPath)

                await MainActor.run {
                    isBakingScene = false
                    bakeProgress = 0
                    if shouldAutoApplyAfterBake {
                        // 实时渲染：桌面已由实时引擎渲染，不自动覆盖；仅缓存
                        if UserDefaults.standard.bool(forKey: "scene_realtime_rendering_enabled") {
                            sceneBakeStatusFlash = t("sceneBake.cached")
                            print("[MediaDetailSheet] 实时渲染模式：烘焙完成，产物已缓存（锁屏/companion 由统一 apply 路径处理）")
                        } else if SceneOfflineBakeService.isUsableBakedVideo(at: videoURL) {
                            scheduleSceneBakeSuccessFlash()
                            applyBakedLoopVideoAsWallpaper(videoURL)
                        } else {
                            scheduleSceneBakeSuccessFlash()
                        }
                    } else {
                        // 重新烘焙 / 多显示器：只缓存，不自动改壁纸
                        scheduleSceneBakeSuccessFlash()
                    }
                }
            } catch let error as BakeError where error == .cancelled {
                await MainActor.run {
                    isBakingScene = false
                    bakeProgress = 0
                }
            } catch {
                await MainActor.run {
                    isBakingScene = false
                    bakeProgress = 0
                    errorMessage = Self.truncateErrorMessage(error.localizedDescription)
                    showError = true
                }
            }
        }
    }

    private func runWebOfflineBake(clearCachedArtifact: Bool) {
        guard let record = currentDownloadRecord, !isBakingScene else { return }

        isBakingScene = true
        bakeProgress = 0
        errorMessage = ""
        let shouldAutoApplyAfterBake = !clearCachedArtifact && NSScreen.screens.count <= 1

        Task {
            if clearCachedArtifact {
                await MainActor.run {
                    mediaLibrary.clearSceneBakeArtifact(itemID: record.item.id)
                }
            }

            if !clearCachedArtifact,
               SceneOfflineBakeService.hasCachedArtifact(record: record, renderer: .wallpaperEngineWeb),
               let videoURL = cachedSceneBakeVideoURL {
                _ = await VideoThumbnailCache.shared.sceneBakePosterJPEGFileURL(
                    forLocalVideo: videoURL,
                    itemID: record.item.id
                )
                await MainActor.run {
                    isBakingScene = false
                    bakeProgress = 0
                    if shouldAutoApplyAfterBake {
                        // 与 scene 缓存命中一致：预渲染意图 → 应用烘焙 MP4
                        applyBakedLoopVideoAsWallpaper(videoURL)
                    } else {
                        sceneBakeStatusFlash = t("sceneBake.cached")
                    }
                }
                return
            }

            do {
                let artifact = try await WebOfflineBakeService.bake(record: record) { progress in
                    updateSceneBakeProgress(progress)
                }
                let videoURL = URL(fileURLWithPath: artifact.videoPath)
                await MainActor.run {
                    isBakingScene = false
                    bakeProgress = 0
                    if shouldAutoApplyAfterBake {
                        // 与 scene 一致：实时开着只缓存；非实时则应用烘焙循环视频
                        if UserDefaults.standard.bool(forKey: "scene_realtime_rendering_enabled") {
                            sceneBakeStatusFlash = t("sceneBake.cached")
                            print("[MediaDetailSheet] 实时渲染模式：Web 烘焙完成，产物已缓存（不覆盖当前实时壁纸）")
                        } else if SceneOfflineBakeService.isUsableBakedVideo(at: videoURL) {
                            scheduleSceneBakeSuccessFlash()
                            applyBakedLoopVideoAsWallpaper(videoURL)
                        } else {
                            scheduleSceneBakeSuccessFlash()
                        }
                    } else {
                        scheduleSceneBakeSuccessFlash()
                    }
                }
            } catch {
                await MainActor.run {
                    isBakingScene = false
                    bakeProgress = 0
                    errorMessage = Self.truncateErrorMessage(error.localizedDescription)
                    showError = true
                }
            }
        }
    }

    /// 将已烘焙的循环 MP4 设为视频壁纸（预渲染按钮 / 烘焙完成后的非实时路径）。
    /// 直接传视频文件，避免再走 Workshop 根路径触发实时 Web/Scene。
    private func applyBakedLoopVideoAsWallpaper(_ bakedVideoURL: URL) {
        guard SceneOfflineBakeService.isUsableBakedVideo(at: bakedVideoURL) else {
            sceneBakeStatusFlash = t("sceneBake.cached")
            return
        }
        let screens = NSScreen.screens
        let run: (NSScreen?) -> Void = { [self] selectedScreen in
            applyingWallpaperStatusKey = "applyingWallpaper.video"
            isSettingWallpaper = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [self] in
                guard isSettingWallpaper else { return }
                isSettingWallpaper = false
            }
            Task { @MainActor in
                do {
                    let isGlobalDisplaySyncEnabled = WallpaperSchedulerService.shared.isGlobalDisplaySyncEnabled
                    let targetScreens = isGlobalDisplaySyncEnabled
                        ? NSScreen.screens
                        : selectedScreen.map { [$0] }
                    var options = LocalWallpaperApplyService.Options(
                        animatedTransition: true,
                        requirePlaybackEndSupport: false,
                        muted: isMuted,
                        generatePosterFromVideoIfNeeded: true,
                        sceneBakeItemID: currentDownloadRecord?.item.id,
                        bakedVideoPath: bakedVideoURL.path,
                        usesSharedVideoDecoder: isGlobalDisplaySyncEnabled,
                        reason: "baked-loop-apply"
                    )
                    options.bakedVideoPath = bakedVideoURL.path
                    _ = try await LocalWallpaperApplyService.apply(
                        localURL: bakedVideoURL,
                        targetScreens: targetScreens,
                        options: options
                    )
                    WallpaperSchedulerService.shared.notifyManualWallpaperChange(
                        screenID: isGlobalDisplaySyncEnabled ? nil : selectedScreen?.wallpaperScreenIdentifier
                    )
                    sceneBakeStatusFlash = t("sceneBake.cached")
                } catch {
                    errorMessage = Self.truncateErrorMessage(error.localizedDescription)
                    showError = true
                }
                isSettingWallpaper = false
            }
        }

        if WallpaperSchedulerService.shared.isGlobalDisplaySyncEnabled {
            run(nil)
        } else if screens.count > 1 {
            DisplaySelectorManager.shared.showSelector(
                title: t("setWallpaper"),
                message: t("multiDisplayDetected")
            ) { selected in
                run(selected)
            }
        } else {
            run(screens.first)
        }
    }

    /// Workshop 视频/烘焙成片：锁屏海报优先用本地 project 预览图，其次 item.posterURL
    private var preferredWorkshopPosterForVideo: URL? {
        localWorkshopPreviewImageURL(for: resolvedItem) ?? resolvedItem.posterURL
    }

    @MainActor
    private func preferredPosterFrame(for videoURL: URL, preferPosterFrameFromVideo: Bool) async -> URL? {
        guard preferPosterFrameFromVideo else { return nil }
        if let record = currentDownloadRecord,
           let artifact = record.sceneBakeArtifact,
           artifact.videoPath == videoURL.path {
            return await VideoThumbnailCache.shared.sceneBakePosterJPEGFileURL(
                forLocalVideo: videoURL,
                itemID: record.item.id
            )
        }
        return await VideoThumbnailCache.shared.posterJPEGFileURL(forLocalVideo: videoURL)
    }

    private var buttonRowWithDividers: some View {
        HStack(spacing: 16) {
            HStack(spacing: 16) {
                dividerLine
                    .frame(width: 70)

                Button {
                    viewModel.toggleFavorite(resolvedItem)
                } label: {
                    DetailSheetCircleIconLabel(
                        systemName: viewModel.isFavorite(resolvedItem) ? "heart.fill" : "heart",
                        foreground: viewModel.isFavorite(resolvedItem) ? Color(hex: "FF5A7D") : .white
                    )
                    .detailGlassCircleChrome()
                }
                .buttonStyle(.plain)

                if isAlreadyDownloaded {
                    Button {
                        Task { await previewWallpaper() }
                    } label: {
                        DetailSheetCircleIconLabel(systemName: "arrow.up.backward.and.arrow.down.forward")
                            .detailGlassCircleChrome()
                    }
                    .buttonStyle(.plain)
                    .help(t("preview"))
                }
            }

            Button {
                setAsDesktopWallpaper()
            } label: {
                HStack(spacing: 10) {
                    if isSettingWallpaper {
                        CustomProgressView(tint: .white)
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "play.fill")
                            .font(.system(size: 13, weight: .medium))
                        Text(t("setWallpaper"))
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 28)
                .frame(height: 46)
                .contentShape(Capsule())
                .detailPrimaryGlassButtonChrome()
            }
            .buttonStyle(.plain)
            .disabled(isSettingWallpaper)

            HStack(spacing: 16) {
                Button {
                    let newMuted = !isMuted
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isMuted = newMuted
                    }
                } label: {
                    DetailSheetCircleIconLabel(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .detailGlassCircleChrome()
                }
                .buttonStyle(.plain)

                Button {
                    if isDownloading { return }
                    if canUpdateWorkshopDownload {
                        updateWorkshopDownload()
                    } else if !isAlreadyDownloaded {
                        downloadMedia()
                    }
                } label: {
                    ZStack {
                        if isDownloading {
                            CustomProgressView(tint: .white)
                                .scaleEffect(0.7)
                        }
                        DetailSheetCircleIconLabel(systemName: downloadActionSystemName)
                            .opacity(isDownloading ? 0 : 1)
                    }
                    .frame(width: 42, height: 42)
                    .contentShape(Circle())
                    .detailGlassCircleChrome(
                        tint: (canUpdateWorkshopDownload || isWorkshopUpdateFlow)
                            ? Color.accentColor.opacity(0.28)
                            : nil
                    )
                }
                .buttonStyle(.plain)
                .disabled(isDownloading || (isAlreadyDownloaded && !canUpdateWorkshopDownload))
                .help(
                    (canUpdateWorkshopDownload || isWorkshopUpdateFlow)
                        ? t("workshop.updateAvailable")
                        : (isAlreadyDownloaded ? t("downloaded") : t("download"))
                )

                Button {
                    showMoreOptionsPopover = true
                } label: {
                    DetailSheetCircleIconLabel(systemName: "ellipsis")
                        .detailGlassCircleChrome()
                }
                .buttonStyle(.plain)
                .help("更多选项")
                .background(
                    SharePickerAnchorReader { anchor in
                        sharePickerAnchorView = anchor
                    }
                )
                .popover(isPresented: $showMoreOptionsPopover, arrowEdge: .bottom) {
                    morePopoverMenuContent
                }

                dividerLine
                    .frame(width: 70)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
        .glassContainer(spacing: 16)
    }

    private var dividerLine: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.0),
                        Color.white.opacity(0.25),
                        Color.white.opacity(0.0)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(height: 1)
    }

    // MARK: - 液态玻璃更多菜单
    @ViewBuilder
    private var morePopoverMenuContent: some View {
        VStack(spacing: 0) {
            if isAlreadyDownloaded {
                Button {
                    // 不关闭菜单，保持锚点有效
                    shareDownloadedMediaFile()
                } label: {
                    HStack {
                        Image(systemName: "square.and.arrow.up")
                        Text(t("shareLocalFile"))
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
            }

            if canRedownloadItem {
                Button {
                    showMoreOptionsPopover = false
                    showRedownloadConfirm = true
                } label: {
                    HStack {
                        Image(systemName: "arrow.clockwise.circle")
                        Text(t("library.redownload.item"))
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .disabled(isDownloading || isResettingVideoOptimization || isWorkshopUpdateFlow)
            }

            copySourceLinkButton

            if let finderURL = currentShowInFinderURL {
                Button {
                    showMoreOptionsPopover = false
                    NSWorkspace.shared.activateFileViewerSelecting([finderURL])
                } label: {
                    HStack {
                        Image(systemName: "folder")
                        Text(t("showInFinder"))
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
            }

            // 重新烘焙（仅 Scene 类型已下载壁纸）
            if sceneOfflineBakeButtonVisible {
                Button {
                    showMoreOptionsPopover = false
                    reBakeScene()
                } label: {
                    HStack {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("重新烘焙")
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .disabled(isBakingScene)
            }

            // 删除烘焙产物（保留静态预览图，删除后立即用静态图替换正在显示的锁屏/桌面）
            if cachedSceneBakeVideoURL != nil {
                Button {
                    showMoreOptionsPopover = false
                    showDeleteBakeConfirm = true
                } label: {
                    HStack {
                        Image(systemName: "trash")
                        Text("删除烘焙产物")
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .disabled(isBakingScene || isDeletingBake)
            }

            // 视频转码（检测到 B 帧+高码率时显示，转码后自动消失）
            if isAlreadyDownloaded,
               let localURL = currentDownloadRecord?.localFileURL,
               let videoURL = MediaItem.resolveLocalVideoFile(from: localURL),
               VideoTranscodeService.needsTranscode(videoURL) {
                Button {
                    showMoreOptionsPopover = false
                    Task {
                        isTranscodingVideo = true
                        transcodeVideoProgress = 0
                        _ = await VideoTranscodeService.ensureSeekFriendly(videoURL) { progress in
                            Task { @MainActor in
                                transcodeVideoProgress = progress
                            }
                        }
                        isTranscodingVideo = false
                        sceneBakeStatusFlash = "完成了"
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            sceneBakeStatusFlash = nil
                        }
                    }
                } label: {
                    HStack {
                        Image(systemName: isTranscodingVideo ? "arrow.triangle.2.circlepath" : "film")
                        Text(isTranscodingVideo ? String(format: t("transcodingToast"), Int(transcodeVideoProgress * 100)) : t("transcodingVideo"))
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .disabled(isTranscodingVideo)
            }

            if let optimizationVideoURL = currentOptimizationVideoURL,
               shouldShowVideoOptimizationSection(videoURL: optimizationVideoURL) {
                Rectangle()
                    .fill(Color.white.opacity(0.15))
                    .frame(height: 1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
            }

            if let optimizationVideoURL = currentOptimizationVideoURL,
               let statusTitle = videoOptimizationStatusTitle(videoURL: optimizationVideoURL) {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                    Text(statusTitle)
                    Spacer()
                }
                .foregroundStyle(Color(hex: "30D158"))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }

            if let optimizationVideoURL = currentOptimizationVideoURL,
               shouldShowVideoOptimizationMenuItem(videoURL: optimizationVideoURL) {
                videoOptimizationMenuItem(videoURL: optimizationVideoURL)
            }

            // 复制静态图片
            if isAlreadyDownloaded || WallpaperEngineXBridge.shared.isControllingExternalEngine {
                Button {
                    showMoreOptionsPopover = false
                    copyStaticImageToPasteboard()
                } label: {
                    HStack {
                        Image(systemName: "photo.on.rectangle")
                        Text("复制静态图片")
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
            }

            // 仅在存在可用的 Scene 烘焙 MP4 时展示。
            if let bakedVideoURL = cachedSceneBakeVideoURL {
                Button {
                    showMoreOptionsPopover = false
                    copyBakedSceneVideoToPasteboard(bakedVideoURL)
                } label: {
                    HStack {
                        Image(systemName: "doc.on.doc")
                        Text("复制烘焙资源")
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .frame(minWidth: 192)
    }

    private var copySourceLinkButton: some View {
        Button {
            guard let link = copyableSourceLinkString else {
                NSSound.beep()
                return
            }
            showMoreOptionsPopover = false
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(link, forType: .string)
            showCopyLinkToast = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                showCopyLinkToast = false
            }
        } label: {
            HStack {
                Image(systemName: "link")
                Text(t("wallpaperDetail.copyLink"))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .opacity(hasCopyableSourceLink ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!hasCopyableSourceLink)
    }

    /// Prefer the concrete local video (or workshop root) so Finder can select it.
    private var currentShowInFinderURL: URL? {
        let candidates = [
            cachedSceneBakeVideoURL,
            currentDownloadRecord?.localFileURL,
            findLocalWorkshopFile()
        ].compactMap { $0 }

        for localURL in candidates {
            if FileManager.default.fileExists(atPath: localURL.path) {
                return localURL
            }
        }
        return nil
    }

    /// Optimization actions resolve the physical local video (not just the UI download marker).
    /// Prefer baked scene MP4 when present: desktop often plays that artifact, and local
    /// bake policy already skips auto loop while still allowing manual optimize actions.
    /// Uses queue-side `optimizableVideoURL` so web Workshop assets never surface here.
    private var currentOptimizationVideoURL: URL? {
        let candidates = [
            cachedSceneBakeVideoURL,
            currentDownloadRecord?.localFileURL,
            findLocalWorkshopFile()
        ].compactMap { $0 }

        for localURL in candidates {
            if let videoURL = frameInterpolationQueue.optimizableVideoURL(from: localURL) {
                return videoURL
            }
        }
        return nil
    }

    private var isCurrentOptimizationBakedSceneVideo: Bool {
        guard let bakedVideoURL = cachedSceneBakeVideoURL,
              let optimizationVideoURL = currentOptimizationVideoURL else {
            return false
        }
        return bakedVideoURL.standardizedFileURL == optimizationVideoURL.standardizedFileURL
    }

    private var currentFrameInterpolationTargetFPS: Int {
        FrameInterpolationTargetFPSResolver.targetFPSForManualAction()
    }

    private func shouldShowVideoOptimizationSection(videoURL: URL) -> Bool {
        shouldShowVideoOptimizationMenuItem(videoURL: videoURL)
            || videoOptimizationStatusTitle(videoURL: videoURL) != nil
    }

    private func videoOptimizationStatusTitle(videoURL: URL) -> String? {
        switch currentVideoOptimizationState(videoURL: videoURL) {
        case .completed:
            return t("videoOptimizationCompleted")
        case .notNeeded:
            return t("videoOptimizationNotNeeded")
        case .idle, .failed, .blacklisted:
            return nil
        }
    }

    private func shouldShowVideoOptimizationMenuItem(videoURL: URL) -> Bool {
        // 持久化终态优先于同步粗判。否则 Scene 烘焙视频虽然已经记录为
        // `notNeeded`，下面的 loopState 仍可能是 idle，导致“无需优化”和
        // “优化视频”同时出现。
        switch currentVideoOptimizationState(videoURL: videoURL) {
        case .completed, .notNeeded:
            return false
        case .idle, .failed, .blacklisted:
            break
        }

        return frameInterpolationQueue.isPlanningOrQueued(videoURL: videoURL)
            || shouldResetVideoOptimization(videoURL: videoURL)
            || isFrameInterpolationBlacklisted(videoURL: videoURL)
            || !videoOptimizationOperations(for: videoURL).isEmpty
    }

    private func currentVideoOptimizationState(
        videoURL: URL
    ) -> VideoOptimizationRecordStore.OptimizationState {
        VideoOptimizationRecordStore.shared.optimizationState(
            for: videoURL,
            targetFPS: currentFrameInterpolationTargetFPS
        )
    }

    private func videoOptimizationMenuItem(videoURL: URL) -> some View {
        Button {
            showMoreOptionsPopover = false
            handleVideoOptimizationTap(videoURL: videoURL)
        } label: {
            HStack {
                Image(systemName: videoOptimizationActionIcon(videoURL: videoURL))
                Text(videoOptimizationActionTitle(videoURL: videoURL))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .foregroundStyle(videoOptimizationActionForegroundStyle(videoURL: videoURL))
        .disabled(videoOptimizationActionDisabled(videoURL: videoURL))
    }

    private func videoOptimizationActionTitle(videoURL: URL) -> String {
        if frameInterpolationQueue.isPlanningOrQueued(videoURL: videoURL) {
            return t("videoOptimizationOptimizingVideo")
        }
        if shouldResetVideoOptimization(videoURL: videoURL) {
            return t("videoOptimizationReoptimizeVideo")
        }
        if isFrameInterpolationBlacklisted(videoURL: videoURL) {
            return t("videoOptimizationEnableInterpolation")
        }
        return t("videoOptimizationOptimizeVideo")
    }

    private func videoOptimizationActionIcon(videoURL: URL) -> String {
        if frameInterpolationQueue.isPlanningOrQueued(videoURL: videoURL) {
            return "hourglass"
        }
        if shouldResetVideoOptimization(videoURL: videoURL) {
            return "arrow.triangle.2.circlepath"
        }
        if isFrameInterpolationBlacklisted(videoURL: videoURL) {
            return "nosign"
        }
        return "sparkles"
    }

    private func videoOptimizationActionForegroundStyle(videoURL: URL) -> Color {
        if videoOptimizationActionDisabled(videoURL: videoURL) {
            return Color.white.opacity(0.46)
        }
        if isFrameInterpolationBlacklisted(videoURL: videoURL) {
            return Color(hex: "FF9F0A")
        }
        return .white
    }

    private func videoOptimizationActionDisabled(videoURL: URL) -> Bool {
        guard !frameInterpolationQueue.isPlanningOrQueued(videoURL: videoURL) else { return true }
        guard shouldResetVideoOptimization(videoURL: videoURL) else { return false }
        return isResettingVideoOptimization || isLocalFile
    }

    private func handleVideoOptimizationTap(videoURL: URL) {
        guard !frameInterpolationQueue.isPlanningOrQueued(videoURL: videoURL) else { return }

        if shouldResetVideoOptimization(videoURL: videoURL) {
            deleteAndRedownloadCurrentItem()
            return
        }

        if isFrameInterpolationBlacklisted(videoURL: videoURL) {
            pendingRemoveFrameInterpolationBlacklistURL = videoURL
            showRemoveFrameInterpolationBlacklistConfirm = true
            return
        }

        // 入队前读源 FPS：已达目标则只做循环，源 FPS 不足才带补帧。
        _ = frameInterpolationQueue.enqueueOptimizeVideo(
            videoURL: videoURL,
            title: resolvedItem.title,
            targetFPS: currentFrameInterpolationTargetFPS,
            source: .manual
        )
    }

    /// 菜单/禁用态用的同步粗判（不读磁盘 FPS）。
    /// 真实步骤在 `enqueueOptimizeVideo` 内按源 FPS 再规划。
    private func videoOptimizationOperations(
        for videoURL: URL
    ) -> [FrameInterpolationQueueItem.Operation] {
        var operations: [FrameInterpolationQueueItem.Operation] = []
        switch VideoOptimizationRecordStore.shared.loopState(for: videoURL) {
        case .idle, .failed:
            operations.append(.loopTransition)
        case .applied, .notNeeded, .noReliablePoint:
            break
        }

        switch VideoOptimizationRecordStore.shared.frameState(for: videoURL) {
        case .idle, .failed:
            operations.append(.frameInterpolation)
        case .notNeeded(let targetFPS):
            if (targetFPS ?? 0) < currentFrameInterpolationTargetFPS {
                operations.append(.frameInterpolation)
            }
        case .applied, .blacklisted:
            break
        }
        return operations
    }

    private func shouldResetVideoOptimization(videoURL: URL) -> Bool {
        guard !isCurrentOptimizationBakedSceneVideo,
              videoOptimizationOperations(for: videoURL).isEmpty else {
            return false
        }
        if case .applied = VideoOptimizationRecordStore.shared.loopState(for: videoURL) {
            return true
        }
        if case .applied = VideoOptimizationRecordStore.shared.frameState(for: videoURL) {
            return true
        }
        return false
    }

    private func isFrameInterpolationBlacklisted(videoURL: URL) -> Bool {
        if case .blacklisted = VideoOptimizationRecordStore.shared.frameState(for: videoURL) {
            return true
        }
        return false
    }

    /// Clears durable optimization state, removes library files, then re-downloads source.
    /// 先清队列/sidecar，再 `removeDownloads`（含物理文件 + 烘焙产物），最后重下。
    private func deleteAndRedownloadCurrentItem() {
        redownloadCurrentItem(fromOptimizationReset: true)
    }

    /// 与库右键「重新下载」一致：先持久化下载队列，再清优化状态与旧文件，最后启动传输。
    /// 删前捕获 folderID 写入 Job，落盘复活时按 Job 归属恢复原文件夹（含根目录）。
    /// `fromOptimizationReset` 时沿用原优化重置的 loading / toast 行为。
    private func redownloadCurrentItem(fromOptimizationReset: Bool = false) {
        guard canRedownloadItem, !isResettingVideoOptimization else { return }

        let downloadingItem = resolvedItem
        let itemID = downloadingItem.id
        // 优先读活跃记录；删前必须捕获，removeDownloads 后 isActive 会变 false
        let preservedFolderID = MediaLibraryService.normalizedFolderID(
            currentDownloadRecord?.folderID
                ?? mediaLibrary.downloadRecord(for: itemID)?.folderID
        )
        let videoURLs = [
            currentOptimizationVideoURL,
            cachedSceneBakeVideoURL,
            currentDownloadRecord?.resolvedVideoFileURL
        ].compactMap { $0 }

        // 先落盘 Job（带 folderID），失败则不删旧文件（与 MyLibrary 行为一致）
        guard PersistentDownloadQueueService.shared.stage(
            [downloadingItem],
            folderID: preservedFolderID
        ) else {
            errorMessage = "无法保存下载队列，已取消删除旧文件"
            showError = true
            return
        }

        if fromOptimizationReset {
            isResettingVideoOptimization = true
            downloadActivity.start(itemID: itemID)
        }
        errorMessage = ""

        stopPlayingWallpaperIfNeeded(for: downloadingItem)

        for videoURL in Set(videoURLs.map(\.standardizedFileURL)) {
            frameInterpolationQueue.cancelSourceRestoreRequest(videoURL: videoURL)
            frameInterpolationQueue.resetOptimizationState(videoURL: videoURL)
        }

        // removeDownloads 会软删下载记录 + 物理文件 + 烘焙产物，必须在 re-download 之前。
        viewModel.removeDownloads(withIDs: [itemID])

        PersistentDownloadQueueService.shared.start(using: viewModel)

        if fromOptimizationReset {
            Task { @MainActor in
                defer {
                    isResettingVideoOptimization = false
                    downloadActivity.finish(itemID: itemID)
                }
                // 短轮询等待下载记录复活
                for _ in 0..<120 {
                    if mediaLibrary.downloadRecord(for: itemID)?.isActive == true { break }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                // 双保险：若队列路径未写回归属，按删前 folderID 强制恢复
                restoreDownloadFolderMembershipIfNeeded(
                    itemID: itemID,
                    folderID: preservedFolderID
                )
                let refreshedCurrentDetail = refreshResolvedItemAfterLocalDownload(for: itemID)
                if let videoURL = videoURLs.first {
                    VideoWallpaperManager.shared.reloadPlaybackAfterInPlaceOptimization(videoURL: videoURL)
                }
                if refreshedCurrentDetail {
                    sceneBakeStatusFlash = "已重新下载原文件"
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if resolvedItem.id == itemID,
                       sceneBakeStatusFlash == "已重新下载原文件" {
                        sceneBakeStatusFlash = nil
                    }
                }
            }
        } else {
            sceneBakeStatusFlash = t("library.redownload.item")
            Task { @MainActor in
                // 下载完成后兜底一次文件夹归属（根目录则保持 nil）
                for _ in 0..<120 {
                    if mediaLibrary.downloadRecord(for: itemID)?.isActive == true {
                        restoreDownloadFolderMembershipIfNeeded(
                            itemID: itemID,
                            folderID: preservedFolderID
                        )
                        break
                    }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if sceneBakeStatusFlash == t("library.redownload.item") {
                    sceneBakeStatusFlash = nil
                }
            }
        }
    }

    /// 重新下载完成后，确保下载记录仍在删前的库文件夹内。
    private func restoreDownloadFolderMembershipIfNeeded(itemID: String, folderID: String?) {
        guard let record = mediaLibrary.downloadRecord(for: itemID), record.isActive else { return }
        let expected = MediaLibraryService.normalizedFolderID(folderID)
        let actual = MediaLibraryService.normalizedFolderID(record.folderID)
        guard expected != actual else { return }
        mediaLibrary.moveMediaToFolder(
            mediaID: itemID,
            folderID: expected,
            scope: .downloads
        )
    }

    private func detailInfoBubble(width: CGFloat) -> some View {
        DetailGlassPopoverCard(width: width, maxHeight: 460, variant: .dark) {
            VStack(alignment: .leading, spacing: 8) {
                Text(mediaTitle)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.96))
                    .lineLimit(2)

                Text({
                    let s = resolvedItem.subtitle, r = resolvedItem.resolutionLabel
                    return s == r ? s : "\(s) · \(r)"
                }())
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
                    .tracking(0.6)
            }

            if !resolvedItem.tags.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(resolvedItem.tags.prefix(8), id: \.self) { tag in
                        Text(tag)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 10)
                            .frame(height: 26)
                            .detailGlassCapsuleChrome(level: .prominent)
                    }
                }
                .glassContainer(spacing: 10)
            }

            infoSection(title: t("info")) {
                compactFact(label: t("title"), value: mediaTitle)
                compactFact(label: t("source"), value: resolvedItem.sourceName)
                compactFact(label: t("category"), value: resolvedItem.subtitle)
                compactFact(label: t("page"), value: resolvedItem.slug)
            }

            dividerLine.opacity(0.7)

            infoSection(title: t("specs2")) {
                compactFact(label: t("resolution2"), value: resolvedItem.exactResolution ?? resolvedItem.resolutionLabel)
                compactFact(label: t("duration"), value: resolvedItem.durationLabel ?? t("unknown"))
                compactFact(
                    label: t("format2"),
                    value: previewVideoURL?.pathExtension.uppercased() ?? "MP4"
                )
                compactFact(label: t("audio2"), value: isMuted ? t("muted") : t("audioOn"))
                compactFact(
                    label: t("download2"),
                    value: resolvedItem.downloadOptions.isEmpty ? t("noDownloadOptions") : "\(resolvedItem.downloadOptions.count) \(t("versions"))"
                )
            }

            // Workshop 社交统计
            if resolvedItem.sourceName == t("wallpaperEngine"),
               resolvedItem.subscriptionCount != nil || resolvedItem.favoriteCount != nil
               || resolvedItem.viewCount != nil || resolvedItem.ratingScore != nil
               || resolvedItem.authorName != nil || resolvedItem.authorSteamID != nil || resolvedItem.fileSize != nil
               || resolvedItem.createdAt != nil || resolvedItem.updatedAt != nil {
                dividerLine.opacity(0.7)

                infoSection(title: t("wallpaperEngine")) {
                    if resolvedItem.authorName != nil || resolvedItem.authorSteamID != nil {
                        let author = resolvedItem.authorName ?? t("unknown")
                        if resolvedItem.authorSteamID != nil {
                            Button {
                                openAuthorSheet()
                            } label: {
                                compactFact(label: t("author"), value: author, isInteractive: true)
                            }
                            .buttonStyle(.plain)
                            .onHover { hovering in
                                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                            }
                        } else {
                            compactFact(label: t("author"), value: author)
                        }
                    }
                    compactFact(label: "ID", value: resolvedItem.slug.replacingOccurrences(of: "workshop_", with: ""))
                    if let subs = resolvedItem.subscriptionCount {
                        compactFact(label: t("subscriptions"), value: formatCount(subs))
                    }
                    if let favs = resolvedItem.favoriteCount {
                        compactFact(label: t("favorites"), value: formatCount(favs))
                    }
                    if let views = resolvedItem.viewCount {
                        compactFact(label: t("views"), value: formatCount(views))
                    }
                    if let rating = resolvedItem.ratingScore {
                        compactFact(label: t("rating"), value: String(format: "%.1f / 5.0", rating))
                    }
                    if let fileSize = resolvedItem.fileSize, fileSize > 0 {
                        compactFact(label: t("size"), value: formatFileSize(fileSize))
                    }
                    if let created = resolvedItem.createdAt {
                        compactFact(label: t("created"), value: formatDate(created))
                    }
                    if let updated = resolvedItem.updatedAt {
                        compactFact(label: t("updated"), value: formatDate(updated))
                    }
                }
            }

            if !resolvedItem.downloadOptions.isEmpty {
                dividerLine.opacity(0.7)

                VStack(alignment: .leading, spacing: 12) {
                    sectionTitle(t("downloadSources"))

                    if isSourcesReady {
                        ForEach(resolvedItem.downloadOptions.prefix(3)) { option in
                            HStack(spacing: 10) {
                                Text(option.label)
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.92))
                                    .frame(width: 44, alignment: .leading)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.resolutionText)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.82))

                                    Text(option.fileSizeLabel)
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.46))
                                }

                                Spacer(minLength: 0)

                                Image(systemName: "arrow.down.circle.fill")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.42))
                            }
                            .padding(.horizontal, 12)
                            .frame(height: 46)
                            .detailGlassRoundedRectChrome(cornerRadius: 14, level: .prominent)
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        }
                    } else {
                        // 来源加载中的占位动画
                        SourceLoadingPlaceholder()
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func infoSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(title)
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white.opacity(0.56))
            .tracking(2)
    }

    private func compactFact(label: String, value: String, isInteractive: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
                .frame(width: 72, alignment: .leading)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if isInteractive {
                    detailDisclosureIndicator
                }
            }

            Spacer(minLength: 0)
        }
    }

    private var detailDisclosureIndicator: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white.opacity(0.32))
    }

    private var mediaTitle: String {
        resolvedItem.title
    }

    private func formatCount(_ count: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1

        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return formatter.string(from: NSNumber(value: count)) ?? "\(count)"
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1024 / 1024
        if mb >= 1024 {
            return String(format: "%.1f GB", mb / 1024)
        }
        return String(format: "%.1f MB", mb)
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.locale = Locale.current
        return formatter.string(from: date)
    }

    private var statusText: String {
        if isBakingScene {
            return t("sceneBake.progressTitle")
        }
        if let flash = sceneBakeStatusFlash {
            return flash
        }
        if isSettingWallpaper {
            return t(applyingWallpaperStatusKey)
        }
        if isTranscodingVideo {
            return String(format: t("transcodingToast"), Int(transcodeVideoProgress * 100))
        }
        if isDownloading {
            return (canUpdateWorkshopDownload || isWorkshopUpdateFlow)
                ? t("workshop.updating")
                : t("downloadingMedia")
        }
        if canUpdateWorkshopDownload || isWorkshopUpdateFlow {
            return t("workshop.updateAvailable")
        }
        if isAlreadyDownloaded {
            return t("savedToDownloads")
        }
        if previewVideoURL != nil {
            return isMuted ? t("videoMutedPlaying") : t("videoPlaying")
        }
        return ""
    }

    @MainActor
    private func loadDetailIfNeeded() async {
        // 仅加载「当前」详情；作者面板切换后 resolvedItem 会变，
        // 不可再用已过期的 initialItem 覆盖背景。
        let target = resolvedItem
        let targetID = target.id
        let detail = await viewModel.ensureDetail(for: target)
        guard resolvedItem.id == targetID else { return }
        let merged = mediaItemByMergingAuthorMetadata(detail, fallback: target)
        var item = itemWithLocalWorkshopVideo(merged)
        // 修复历史脏数据：早期导入未读 project.json 的 workshopid，可能把本地 hash/UUID
        // 伪造成了打不开的 Steam 链接。这里从本地 project.json 重新提取真实 ID 并修正 pageURL。
        item = itemWithCorrectedWorkshopPageURL(item)
        guard resolvedItem.id == targetID else { return }
        resolvedItem = item
        viewModel.recordViewed(resolvedItem)

        // 如果已下载但尚未分析烘焙资格，尝试重新分析（修复后重试之前失败的分析）
        if let record = currentDownloadRecord, record.sceneBakeEligibility == nil,
           let localURL = findLocalWorkshopFile(for: resolvedItem) {
            let contentRoot = sceneEngineContentRoot(for: localURL)
            if Self.projectTypeString(at: contentRoot) == "scene" {
                Task(priority: .utility) {
                    do {
                        let snapshot = try SceneBakeEligibilityAnalyzer.analyze(
                            contentRoot: contentRoot,
                            intent: .desktopLoop,
                            strict: false
                        )
                        await MainActor.run {
                            MediaLibraryService.shared.attachSceneBakeEligibility(
                                itemID: resolvedItem.id,
                                snapshot: snapshot,
                                triggerAutoBake: true
                            )
                            print("[MediaDetailSheet] ✅ 烘焙资格分析完成: tier=\(snapshot.tier.rawValue) score=\(snapshot.score)")
                        }
                    } catch {
                        print("[MediaDetailSheet] ⚠️ 烘焙资格分析重试失败: \(error)")
                    }
                }
            }
        }

        await checkWorkshopUpdateIfNeeded()

        withAnimation(.easeInOut(duration: 0.3)) {
            isSourcesReady = true
        }
    }

    /// 已下载 Workshop 项：对比远端 time_updated 与本地下载记录
    private func checkWorkshopUpdateIfNeeded() async {
        guard isAlreadyDownloaded,
              !isLocalFile,
              resolvedItem.id.hasPrefix("workshop_") else {
            hasWorkshopUpdateAvailable = false
            remoteWorkshopUpdatedAt = nil
            return
        }

        let itemID = resolvedItem.id
        guard let result = await viewModel.checkWorkshopUpdateAvailability(for: resolvedItem) else {
            // 网络失败时保留现有状态，不把“有更新”误清掉
            return
        }
        guard resolvedItem.id == itemID else { return }
        hasWorkshopUpdateAvailable = result.hasUpdate
        remoteWorkshopUpdatedAt = result.remoteUpdatedAt
        if result.hasUpdate {
            AppLogger.info(.download, "检测到 Workshop 更新", metadata: [
                "id": itemID,
                "remoteUpdatedAt": result.remoteUpdatedAt.map { "\($0.timeIntervalSince1970)" } ?? "nil"
            ])
        }
    }

    /// 删除本地包后重新下载最新 Workshop 内容
    private func updateWorkshopDownload() {
        guard canUpdateWorkshopDownload || isWorkshopUpdateFlow else { return }
        let updatingItem = resolvedItem
        let itemID = updatingItem.id
        workshopUpdateItemID = itemID

        AppLogger.info(.download, "开始更新 Workshop 内容", metadata: [
            "id": itemID,
            "title": updatingItem.title,
            "remoteUpdatedAt": remoteWorkshopUpdatedAt.map { "\($0.timeIntervalSince1970)" } ?? "nil"
        ])

        // 若该壁纸正在桌面播放，先停掉，避免删文件占用
        stopPlayingWallpaperIfNeeded(for: updatingItem)

        downloadActivity.start(itemID: itemID)
        errorMessage = ""
        let start = Date()
        Task { @MainActor in
            defer { downloadActivity.finish(itemID: itemID) }
            do {
                try await viewModel.updateWorkshopWallpaper(updatingItem)
                clearWorkshopUpdateFlow(for: itemID)
                guard resolvedItem.id == itemID else { return }

                hasWorkshopUpdateAvailable = false
                remoteWorkshopUpdatedAt = nil
                // 刷新详情侧元数据（updatedAt 已写入下载记录）
                if let record = mediaLibrary.downloadRecord(for: itemID) {
                    resolvedItem = record.item
                }
                _ = refreshResolvedItemAfterLocalDownload(for: itemID)
                sceneBakeStatusFlash = t("workshop.updated")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if resolvedItem.id == itemID,
                   sceneBakeStatusFlash == t("workshop.updated") {
                    sceneBakeStatusFlash = nil
                }
                AppLogger.info(.download, "Workshop 更新成功", metadata: [
                    "id": itemID,
                    "耗时(s)": String(format: "%.2f", Date().timeIntervalSince(start))
                ])
            } catch let error as WorkshopError {
                clearWorkshopUpdateFlow(for: itemID)
                guard resolvedItem.id == itemID else { return }

                if error.requiresSteamLoginRecovery {
                    presentSteamLoginRequired(error.localizedDescription)
                } else {
                    presentWorkshopDownloadError(error.localizedDescription)
                }
                AppLogger.error(.download, "Workshop 更新失败", metadata: [
                    "id": itemID,
                    "error": error.localizedDescription
                ])
            } catch {
                clearWorkshopUpdateFlow(for: itemID)
                guard resolvedItem.id == itemID else { return }

                presentWorkshopDownloadError(error.localizedDescription)
                AppLogger.error(.download, "Workshop 更新失败", metadata: [
                    "id": itemID,
                    "error": error.localizedDescription
                ])
            }
        }
    }

    /// 若当前详情对应的壁纸正在被桌面/外部引擎使用，先停止再删包
    private func stopPlayingWallpaperIfNeeded(for item: MediaItem) {
        guard item.id.hasPrefix("workshop_") else { return }
        let workshopID = String(item.id.dropFirst("workshop_".count))
        let bridge = WallpaperEngineXBridge.shared

        if bridge.isControllingExternalEngine,
           let path = bridge.currentWallpaperPathForDesign,
           path.contains(workshopID) {
            bridge.stopWallpaper()
            return
        }

        // 本机视频路径命中 workshop 目录时也停掉
        if let currentURL = VideoWallpaperManager.shared.currentVideoURL,
           currentURL.path.contains(workshopID) || currentURL.path.contains("workshop_\(workshopID)") {
            VideoWallpaperManager.shared.stopWallpaper()
        }
    }

    // MARK: - 下一张弹窗相关方法

    private func setupNextItemDataSource() {
        let items = navigationItems
        // 找到当前媒体项在列表中的索引（用 resolvedItem，兼容作者面板原地切换）
        if let index = items.firstIndex(where: { $0.id == resolvedItem.id }) {
            currentItemIndex = index
        }

        // 设置数据源
        nextItemDataSource.setItems(items, currentIndex: currentItemIndex)
    }

    private func navigateToNextMedia() {
        guard !isNavigating else { return }
        let items = navigationItems
        let nextIndex = currentItemIndex + 1
        guard nextIndex < items.count else {
            // 本地模式下循环到第一张
            if contextItems != nil, !items.isEmpty {
                prepareSlideTransition(direction: .down)
                navigateToIndex(0)
            }
            return
        }

        // 更新索引和数据源
        currentItemIndex = nextIndex
        nextItemDataSource.moveToNext()

        // 滑动切换
        prepareSlideTransition(direction: .down)
        reloadMedia(items[nextIndex])
    }

    private func navigateToPreviousMedia() {
        guard !isNavigating else { return }
        let items = navigationItems
        let prevIndex = currentItemIndex - 1
        guard prevIndex >= 0 else {
            // 本地模式下循环到最后一张
            if contextItems != nil, !items.isEmpty {
                prepareSlideTransition(direction: .up)
                navigateToIndex(items.count - 1)
            }
            return
        }

        // 更新索引和数据源
        currentItemIndex = prevIndex
        nextItemDataSource.moveToPrevious()

        // 滑动切换
        prepareSlideTransition(direction: .up)
        reloadMedia(items[prevIndex])
    }

    private func navigateToIndex(_ index: Int) {
        let items = navigationItems
        guard index >= 0, index < items.count else { return }
        currentItemIndex = index
        nextItemDataSource.moveToIndex(index)
        reloadMedia(items[index])
    }

    private func reloadMedia(_ newItem: MediaItem) {
        // 切到另一个详情项后，旧项的“下载后自动设为壁纸”不能继续作用于新项。
        autoDownloadTask?.cancel()
        autoDownloadTask = nil

        // iOS 丝滑切换：交叉淡入淡出 + 微位移
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82, blendDuration: 0)) {
            // 更新当前媒体项
            resolvedItem = newItem

            // 重置状态
            isSettingWallpaper = false
            isMediaLoaded = false
            isSourcesReady = false
            showInfoBubble = false
        }

        // 异步加载详情
        Task {
            await loadDetailIfNeededFor(newItem)
        }
    }

    // MARK: - 键盘快捷键

    private func setupKeyboardMonitor() {
        removeKeyboardMonitor()
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            guard NSApp.isActive, let window = event.window, window.isKeyWindow else { return event }
            guard self.isVisible else { return event }
            switch event.keyCode {
            case 49: // 空格键：显示/隐藏信息区域
                withAnimation(.spring(response: 0.32, dampingFraction: 0.85, blendDuration: 0)) {
                    self.isHeroContentHidden.toggle()
                }
                return nil
            case 126: // 上方向键：上一张
                guard !self.isNavigating else { return nil }
                self.navigateToPreviousMedia()
                return nil
            case 125: // 下方向键：下一张
                guard !self.isNavigating else { return nil }
                self.navigateToNextMedia()
                return nil
            case 53: // ESC：优先关闭当前弹窗，再关闭预览，最后返回详情栈
                if CropAdjustOverlayController.shared.isAdjusting { return event }
                if self.showSceneBakeRendererDialog {
                    self.dismissSceneBakeRendererDialog()
                } else if self.showAuthorSheet {
                    self.dismissAuthorSheet()
                } else if PreviewWindowManager.shared.isPresented {
                    PreviewWindowManager.shared.closePreview()
                } else {
                    self.onClose()
                }
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyboardMonitor() {
        if let monitor = keyboardMonitor {
            NSEvent.removeMonitor(monitor)
            keyboardMonitor = nil
        }
    }

    // MARK: - 滑动动画

    private func prepareSlideTransition(direction: SlideDirection) {
        isNavigating = true
        let distance: CGFloat = 600
        switch direction {
        case .up:
            // 上一张：新图从上方滑入，当前图向下滑出
            slideIncomingOffset = -distance
            slideOutgoingOffset = distance
        case .down:
            // 下一张：新图从下方滑入，当前图向上滑出
            slideIncomingOffset = distance
            slideOutgoingOffset = -distance
        }
        // 动画结束后重置
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            self.isNavigating = false
            self.slideIncomingOffset = 0
            self.slideOutgoingOffset = 0
        }
    }

    @MainActor
    private func loadDetailIfNeededFor(_ item: MediaItem) async {
        let targetID = item.id
        let detail = await viewModel.ensureDetail(for: item)
        // 快速连续切换时丢弃过期响应，避免旧项封面/GIF 回写到当前详情
        guard resolvedItem.id == targetID else { return }
        let updated = itemWithLocalWorkshopVideo(mediaItemByMergingAuthorMetadata(detail, fallback: item))
        guard resolvedItem.id == targetID else { return }
        resolvedItem = updated
        viewModel.recordViewed(resolvedItem)
        await checkWorkshopUpdateIfNeeded()
        guard resolvedItem.id == targetID else { return }
        withAnimation(.easeInOut(duration: 0.3)) {
            isSourcesReady = true
        }
    }

    private func mediaItemByMergingAuthorMetadata(_ item: MediaItem, fallback: MediaItem) -> MediaItem {
        let mergedAuthorName = item.authorName ?? fallback.authorName
        let mergedAuthorSteamID = item.authorSteamID ?? fallback.authorSteamID
        let mergedAuthorAvatarURL = item.authorAvatarURL ?? fallback.authorAvatarURL

        guard mergedAuthorName != item.authorName
              || mergedAuthorSteamID != item.authorSteamID
              || mergedAuthorAvatarURL != item.authorAvatarURL else {
            return item
        }

        return MediaItem(
            slug: item.slug,
            title: item.title,
            pageURL: item.pageURL,
            thumbnailURL: item.thumbnailURL,
            resolutionLabel: item.resolutionLabel,
            collectionTitle: item.collectionTitle,
            summary: item.summary,
            previewVideoURL: item.previewVideoURL,
            posterURL: item.posterURL,
            tags: item.tags,
            exactResolution: item.exactResolution,
            durationSeconds: item.durationSeconds,
            downloadOptions: item.downloadOptions,
            sourceName: item.sourceName,
            isAnimatedImage: item.isAnimatedImage,
            subscriptionCount: item.subscriptionCount,
            favoriteCount: item.favoriteCount,
            viewCount: item.viewCount,
            ratingScore: item.ratingScore,
            authorName: mergedAuthorName,
            authorSteamID: mergedAuthorSteamID,
            authorAvatarURL: mergedAuthorAvatarURL,
            fileSize: item.fileSize,
            createdAt: item.createdAt,
            updatedAt: item.updatedAt
        )
    }

    private func downloadMedia() {
        let downloadingItem = resolvedItem
        let itemID = downloadingItem.id

        // 本地文件无需下载
        if isLocalFile {
            AppLogger.debug(.download, "跳过下载：本地媒体", metadata: ["id": itemID])
            return
        }

        // Workshop 下载
        if itemID.hasPrefix("workshop_") {
            downloadWorkshop()
            return
        }

        AppLogger.info(.download, "开始下载媒体", metadata:
            ["id": itemID, "title": downloadingItem.title,
             "选项数": downloadingItem.downloadOptions.count])
        downloadActivity.start(itemID: itemID)
        errorMessage = ""
        let start = Date()
        Task { @MainActor in
            defer { downloadActivity.finish(itemID: itemID) }

            do {
                // 默认选择最高画质（与设为壁纸逻辑一致）
                let targetOption = downloadingItem.downloadOptions.max { lhs, rhs in
                    if lhs.qualityRank == rhs.qualityRank {
                        return lhs.fileSizeMegabytes < rhs.fileSizeMegabytes
                    }
                    return lhs.qualityRank < rhs.qualityRank
                }
                if let targetOption {
                    _ = try await viewModel.downloadMedia(downloadingItem, option: targetOption)
                    _ = refreshResolvedItemAfterLocalDownload(for: itemID)
                    AppLogger.info(.download, "媒体下载成功", metadata:
                        ["id": itemID, "耗时(s)": String(format: "%.2f", Date().timeIntervalSince(start)),
                         "选中选项": targetOption.label])
                } else {
                    throw NetworkError.invalidResponse
                }
            } catch {
                guard resolvedItem.id == itemID else { return }
                errorMessage = Self.truncateErrorMessage(error.localizedDescription)
                showError = true
                AppLogger.error(.download, "媒体下载失败", metadata:
                    ["id": itemID, "error": error.localizedDescription,
                     "耗时(s)": String(format: "%.2f", Date().timeIntervalSince(start))])
            }
        }
    }

    private func downloadWorkshop() {
        let downloadingItem = resolvedItem
        let itemID = downloadingItem.id

        AppLogger.info(.download, "开始下载 Workshop 内容", metadata:
            ["id": itemID, "title": downloadingItem.title])
        downloadActivity.start(itemID: itemID)
        errorMessage = ""
        let start = Date()
        Task { @MainActor in
            defer { downloadActivity.finish(itemID: itemID) }

            do {
                try await viewModel.downloadWorkshopWallpaper(downloadingItem)
                _ = refreshResolvedItemAfterLocalDownload(for: itemID)
                AppLogger.info(.download, "Workshop 下载成功", metadata:
                    ["id": itemID, "耗时(s)": String(format: "%.2f", Date().timeIntervalSince(start))])
            } catch let error as WorkshopError {
                guard resolvedItem.id == itemID else { return }
                if error.requiresSteamLoginRecovery {
                    presentSteamLoginRequired(error.localizedDescription)
                } else {
                    presentWorkshopDownloadError(error.localizedDescription)
                    AppLogger.error(.download, "Workshop 下载失败", metadata:
                        ["id": itemID, "error": error.localizedDescription,
                         "耗时(s)": String(format: "%.2f", Date().timeIntervalSince(start))])
                }
            } catch {
                guard resolvedItem.id == itemID else { return }
                presentWorkshopDownloadError(error.localizedDescription)
                AppLogger.error(.download, "Workshop 下载失败", metadata:
                    ["id": itemID, "error": error.localizedDescription,
                     "耗时(s)": String(format: "%.2f", Date().timeIntervalSince(start))])
            }
        }
    }

    private static func truncateErrorMessage(_ message: String, maxLength: Int = 2_000) -> String {
        if message.count <= maxLength { return message }
        let endIndex = message.index(message.startIndex, offsetBy: maxLength)
        return String(message[..<endIndex]) + "\n\n[日志已截断，完整错误请查看控制台]"
    }

    private func presentWorkshopDownloadError(_ message: String) {
        errorMessage = Self.truncateErrorMessage(Self.workshopDownloadUserFacingMessage(message))
        showError = true
    }

    private func presentSteamLoginRequired(_ message: String?) {
        let fallback = "Steam 会话需要重新登录。下载任务已保留；请在设置中登录，成功后将自动继续。密码和 Guard 验证码不会保存。"
        let normalizedMessage = message?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let displayMessage: String
        if let normalizedMessage, !normalizedMessage.isEmpty {
            displayMessage = normalizedMessage
        } else {
            displayMessage = fallback
        }
        steamLoginRequiredMessage = Self.truncateErrorMessage(displayMessage)
        showSteamLoginRequiredAlert = true
    }

    private func openSteamLoginSettings() {
        (NSApp.delegate as? AppDelegate)?.showSettingsWindow(nil)
    }

    /// 根据 SteamCMD/业务错误文本生成用户可读提示，避免一律套“检查 VPN”的无效话术。
    private static func workshopDownloadUserFacingMessage(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        // WorkshopService 已给出结构化诊断时，直接展示，不再叠加泛化提示
        if trimmed.contains("SteamCMD 原始信息")
            || trimmed.contains("建议按顺序排查")
            || trimmed.contains("可依次排查") {
            return trimmed
        }

        if trimmed.localizedCaseInsensitiveContains("Access Denied")
            || trimmed.localizedCaseInsensitiveContains("Permission denied") {
            return "\(t("workshopError.accessDenied"))\n\n\(trimmed)"
        }
        if trimmed.localizedCaseInsensitiveContains("No subscriptions")
            || trimmed.contains("没有可用的 Workshop 订阅权限") {
            return "\(t("workshopError.noSubscription"))\n\n\(trimmed)"
        }
        if trimmed.localizedCaseInsensitiveContains("RateLimitExceeded")
            || trimmed.contains("请求过于频繁")
            || trimmed.localizedCaseInsensitiveContains("rate limit") {
            return "\(t("workshopError.rateLimited"))\n\n\(trimmed)"
        }
        if trimmed.contains("需要登录")
            || trimmed.contains("登录已过期")
            || trimmed.contains("账号或密码错误")
            || trimmed.localizedCaseInsensitiveContains("credentials")
            || trimmed.localizedCaseInsensitiveContains("session") {
            return "\(t("workshopError.login"))\n\n\(trimmed)"
        }

        let networkKeywords = [
            "Timeout", "timed out", "Connection", "Network", "No route",
            "unreachable", "VPN", "TUN", "connect to Steam"
        ]
        if networkKeywords.contains(where: { trimmed.localizedCaseInsensitiveContains($0) }) {
            return "\(t("workshopError.network"))\n\n\(trimmed)"
        }

        // 未知错误：给简短可操作方向，而不是只甩原始日志
        return "\(t("workshopError.generic"))\n\n\(trimmed)"
    }

    private func setAsDesktopWallpaper() {
        // Wallpaper Engine 类内容：Workshop 与本地入库（同一套路径解析）
        if let localURL = findLocalWorkshopFile(for: resolvedItem) {
            // 入库校验不得阻塞设壁纸热路径。
            // sample 显示主线程会卡在 ensureDownloadRecord → hasSameLocalContent →
            // canonicalWorkshopContentURL；旧壁纸若已停，桌面就会黑屏，RSS 同步顶高。
            // 先把 apply 排进当前调用栈，再用 async 补入库，保证设壁纸先走。
            let itemForLibrary = resolvedItem
            DispatchQueue.main.async { [viewModel] in
                viewModel.ensureMediaIsInLibrary(itemForLibrary, localFileURL: localURL)
            }
            let contentRoot = sceneEngineContentRoot(for: localURL)

            // 检查并自动下载 Workshop 依赖项（预设壁纸的母壁纸）
            if let dependencyID = readWorkshopDependencyID(from: contentRoot),
               !isWorkshopDependencyDownloaded(dependencyID: dependencyID) {
                isSettingWallpaper = true
                errorMessage = ""
                Task {
                    do {
                        print("[MediaDetailSheet] Downloading dependency \(dependencyID) for \(resolvedItem.id)...")
                        try await downloadWorkshopDependency(dependencyID: dependencyID)
                        print("[MediaDetailSheet] Dependency \(dependencyID) downloaded, proceeding to set wallpaper")
                        await MainActor.run {
                            self.isSettingWallpaper = false
                            self.applyWorkshopWallpaperFromLocalURL(localURL)
                        }
                    } catch let error as WorkshopError {
                        await MainActor.run {
                            if error.requiresSteamLoginRecovery {
                                self.presentSteamLoginRequired(error.localizedDescription)
                            } else {
                                self.presentWorkshopDownloadError(
                                    "依赖项下载失败: \(error.localizedDescription)"
                                )
                            }
                            self.isSettingWallpaper = false
                        }
                    } catch {
                        await MainActor.run {
                            self.presentWorkshopDownloadError("依赖项下载失败: \(error.localizedDescription)")
                            self.isSettingWallpaper = false
                        }
                    }
                }
                return
            }

            // 没有依赖或已下载，直接设置
            applyWorkshopWallpaperFromLocalURL(localURL)
            return
        }

        if resolvedItem.id.hasPrefix("workshop_") {
            // 未下载的 Workshop 内容：自动下载后再设置壁纸
            // 取消可能正在进行的上一个自动下载任务，避免并发设置壁纸造成竞态
            autoDownloadTask?.cancel()
            let itemToDownload = resolvedItem
            let itemID = itemToDownload.id
            isSettingWallpaper = true
            errorMessage = ""
            autoDownloadTask = Task { @MainActor in
                do {
                    AppLogger.info(.download, "自动下载 Workshop 内容后设置壁纸", metadata:
                        ["id": itemID, "title": itemToDownload.title])
                    try await viewModel.downloadWorkshopWallpaper(itemToDownload)
                    // 下载被取消则不再继续设置壁纸
                    if Task.isCancelled { return }
                    guard refreshResolvedItemAfterLocalDownload(for: itemID) else { return }
                    // 下载完成后，查找本地文件并设置壁纸
                    if let localURL = findLocalWorkshopFile(for: resolvedItem) {
                        isSettingWallpaper = false
                        applyWorkshopWallpaperFromLocalURL(localURL)
                    } else {
                        isSettingWallpaper = false
                        errorMessage = "下载完成但未找到本地文件"
                        showError = true
                    }
                } catch is CancellationError {
                    if resolvedItem.id == itemID {
                        isSettingWallpaper = false
                    }
                } catch let error as WorkshopError {
                    guard resolvedItem.id == itemID else { return }
                    isSettingWallpaper = false
                    if error.requiresSteamLoginRecovery {
                        presentSteamLoginRequired(error.localizedDescription)
                    } else {
                        presentWorkshopDownloadError(error.localizedDescription)
                    }
                } catch {
                    guard resolvedItem.id == itemID else { return }
                    isSettingWallpaper = false
                    presentWorkshopDownloadError(error.localizedDescription)
                }
            }
            return
        }

        // 检测多显示器
        let screens = NSScreen.screens
        if WallpaperSchedulerService.shared.isGlobalDisplaySyncEnabled {
            applyingWallpaperStatusKey = "applyingWallpaper.video"
            isSettingWallpaper = true
            errorMessage = ""
            Task { @MainActor in
                do {
                    try await viewModel.applyDynamicWallpaper(
                        resolvedItem,
                        muted: isMuted,
                        targetScreens: NSScreen.screens,
                        usesSharedVideoDecoder: true
                    )
                    WallpaperSchedulerService.shared.notifyManualWallpaperChange(screenID: nil)
                } catch {
                    errorMessage = Self.truncateErrorMessage(error.localizedDescription)
                    showError = true
                }
                isSettingWallpaper = false
            }
        } else if screens.count > 1 {
            DisplaySelectorManager.shared.showSelector(
                title: t("setWallpaper"),
                message: t("multiDisplayDetected")
            ) { [self] selectedScreen in
                applyingWallpaperStatusKey = "applyingWallpaper.video"
                isSettingWallpaper = true
                errorMessage = ""
                Task { @MainActor in
                    do {
                        try await viewModel.applyDynamicWallpaper(resolvedItem, muted: isMuted, targetScreen: selectedScreen)
                        WallpaperSchedulerService.shared.notifyManualWallpaperChange(screenID: selectedScreen?.wallpaperScreenIdentifier)
                        isSettingWallpaper = false
                    } catch {
                        errorMessage = Self.truncateErrorMessage(error.localizedDescription)
                        showError = true
                        isSettingWallpaper = false
                    }
                }
            }
        } else {
            applyingWallpaperStatusKey = "applyingWallpaper.video"
            isSettingWallpaper = true
            errorMessage = ""
            Task { @MainActor in
                do {
                    try await viewModel.applyDynamicWallpaper(resolvedItem, muted: isMuted)
                    WallpaperSchedulerService.shared.notifyManualWallpaperChange(
                        screenID: NSScreen.screens.first?.wallpaperScreenIdentifier
                    )
                } catch {
                    errorMessage = error.localizedDescription
                    showError = true
                }
                isSettingWallpaper = false
            }
        }
    }

    // MARK: - Workshop 依赖处理

    /// 从 project.json 读取 dependency ID
    private func readWorkshopDependencyID(from contentDir: URL) -> String? {
        let projectURL = contentDir.appendingPathComponent("project.json")
        guard let data = try? Data(contentsOf: projectURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["dependency"] as? String
    }

    /// 检查 Workshop 依赖项是否已下载到本地
    private func isWorkshopDependencyDownloaded(dependencyID: String) -> Bool {
        let fm = FileManager.default
        let mediaFolder = DownloadPathManager.shared.mediaFolderURL

        // 1. 检查 MediaLibrary 中是否有记录
        let depItemID = "workshop_\(dependencyID)"
        if MediaLibraryService.shared.downloadedItems.contains(where: { $0.item.id == depItemID }) {
            return true
        }

        // 2. 检查本地目录是否存在（包括嵌套路径）
        let depPaths = [
            mediaFolder.appendingPathComponent("workshop_\(dependencyID)/steamapps/workshop/content/431960/\(dependencyID)"),
            mediaFolder.appendingPathComponent("workshop_\(dependencyID)")
        ]
        for path in depPaths {
            if fm.fileExists(atPath: path.path) {
                // 进一步检查目录下是否有实质内容（project.json 或文件）
                let resolved = WorkshopService.resolveWallpaperEngineProjectRoot(startingAt: path)
                if fm.fileExists(atPath: resolved.appendingPathComponent("project.json").path) {
                    return true
                }
            }
        }
        return false
    }

    /// 下载 Workshop 依赖项
    private func downloadWorkshopDependency(dependencyID: String) async throws {
        let localURL = try await WorkshopService.shared.downloadWorkshopItem(
            workshopID: dependencyID,
            progressHandler: { progress in
                print("[DependencyDownload] \(dependencyID) progress: \(String(format: "%.1f", progress * 100))%")
            }
        )
        print("[DependencyDownload] \(dependencyID) completed at \(localURL.path)")
    }

    /// 从本地 URL 设置 Workshop 壁纸。
    /// 核心设置统一走 `LocalWallpaperApplyService`（与调度器同一方法）；本处只负责 UI（多屏选择/转圈/错误）。
    private func applyWorkshopWallpaperFromLocalURL(_ localURL: URL) {
        // 非实时 scene 且尚无烘焙产物：保留详情页「先烘再设」流程（会阻塞生成 MP4）
        let contentRoot = sceneEngineContentRoot(for: localURL)
        let isRealtime = UserDefaults.standard.bool(forKey: "scene_realtime_rendering_enabled")
        let hasUsableBake = SceneOfflineBakeService.usableArtifact(from: currentDownloadRecord) != nil
        let projectType = Self.projectTypeString(at: contentRoot)
        if projectType == "scene", !isRealtime, !hasUsableBake {
            applySceneWallpaperPreferringBake(sceneContentRoot: contentRoot, cliPath: localURL.path)
            return
        }

        let screens = NSScreen.screens
        let run: (NSScreen?) -> Void = { [self] selectedScreen in
            applyingWallpaperStatusKey = "applyingWallpaper.realtime"
            isSettingWallpaper = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [self] in
                guard isSettingWallpaper else { return }
                isSettingWallpaper = false
            }
            Task { @MainActor in
                do {
                    let isGlobalDisplaySyncEnabled = WallpaperSchedulerService.shared.isGlobalDisplaySyncEnabled
                    let targetScreens = isGlobalDisplaySyncEnabled
                        ? NSScreen.screens
                        : selectedScreen.map { [$0] }
                    var options = LocalWallpaperApplyService.Options(
                        animatedTransition: true,
                        requirePlaybackEndSupport: false,
                        muted: isMuted,
                        generatePosterFromVideoIfNeeded: true,
                        sceneBakeItemID: currentDownloadRecord?.item.id,
                        bakedVideoPath: SceneOfflineBakeService.usableArtifact(from: currentDownloadRecord)?.videoPath,
                        usesSharedVideoDecoder: isGlobalDisplaySyncEnabled,
                        reason: "manual-apply"
                    )
                    if let art = SceneOfflineBakeService.usableArtifact(from: currentDownloadRecord) {
                        options.bakedVideoPath = art.videoPath
                    }
                    _ = try await LocalWallpaperApplyService.apply(
                        localURL: localURL,
                        targetScreens: targetScreens,
                        options: options
                    )
                    WallpaperSchedulerService.shared.notifyManualWallpaperChange(
                        screenID: isGlobalDisplaySyncEnabled ? nil : selectedScreen?.wallpaperScreenIdentifier
                    )
                } catch {
                    errorMessage = Self.truncateErrorMessage(error.localizedDescription)
                    showError = true
                }
                isSettingWallpaper = false
            }
        }

        if WallpaperSchedulerService.shared.isGlobalDisplaySyncEnabled {
            run(nil)
        } else if screens.count > 1 {
            DisplaySelectorManager.shared.showSelector(
                title: t("setWallpaper"),
                message: t("multiDisplayDetected")
            ) { selected in
                run(selected)
            }
        } else {
            run(screens.first)
        }
    }

    private static func projectTypeString(at contentRoot: URL) -> String? {
        let projectURL = contentRoot.appendingPathComponent("project.json")
        guard let data = try? Data(contentsOf: projectURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return nil }
        return type.lowercased()
    }

    /// Scene 壁纸设置：优先使用烘焙产物，无缓存时自动用 wallpaper-wgpu 烘焙后应用
    /// 不再使用 wallpaper-wgpu 实时渲染
    private func applySceneWallpaperPreferringBake(sceneContentRoot: URL, cliPath: String) {
        let itemID = resolvedItem.id
        let fm = FileManager.default
        let hasBakeArtifact = currentDownloadRecord?.sceneBakeArtifact != nil
            && currentDownloadRecord?.sceneBakeArtifact?.analysisId == currentDownloadRecord?.sceneBakeEligibility?.analysisId
        AppLogger.error(.wallpaper, "applySceneWallpaperPreferringBake", metadata: [
            "contentRoot": sceneContentRoot.lastPathComponent,
            "hasBakeArtifact": hasBakeArtifact
        ])

        // 1. 已有烘焙产物 → 走统一 LocalWallpaperApplyService（与调度器同一方法）
        if let record = currentDownloadRecord,
           let art = record.sceneBakeArtifact,
           art.analysisId == record.sceneBakeEligibility?.analysisId,
           SceneOfflineBakeService.isUsableBakedVideo(at: URL(fileURLWithPath: art.videoPath))
            || fm.fileExists(atPath: art.videoPath.replacingOccurrences(of: ".mp4", with: ".web")) {
            applyWorkshopWallpaperFromLocalURL(sceneContentRoot)
            return
        }

        // 2. 无烘焙产物 → 自动用 wallpaper-wgpu 烘焙后应用
        guard !isBakingScene else { return }
        isBakingScene = true
        bakeProgress = 0
        applyingWallpaperStatusKey = "applyingWallpaper.video"
        isSettingWallpaper = true

        Task {
            do {
                // 获取或分析烘焙资格
                let snapshotRecord = await MainActor.run {
                    mediaLibrary.downloadedItems.first { $0.item.id == itemID }
                }
                let eligibility: SceneBakeEligibilitySnapshot
                if let existing = snapshotRecord?.sceneBakeEligibility,
                   SceneBakeEligibilityAnalyzer.isSameContentRoot(existing.contentRootPath, sceneContentRoot.path) {
                    eligibility = existing
                } else {
                    guard SystemMemoryPressure.hasRoomForSceneEligibilityAnalysis() else {
                        await MainActor.run {
                            isBakingScene = false
                            isSettingWallpaper = false
                            errorMessage = t("sceneBake.error.insufficientMemory.analysis")
                            showError = true
                        }
                        return
                    }
                    eligibility = try await Task.detached(priority: .userInitiated) {
                        try SceneBakeEligibilityAnalyzer.analyze(contentRoot: sceneContentRoot)
                    }.value
                    await MainActor.run {
                        MediaLibraryService.shared.attachSceneBakeEligibility(
                            itemID: itemID,
                            snapshot: eligibility,
                            triggerAutoBake: false
                        )
                    }
                }

                let persistID = await MainActor.run {
                    mediaLibrary.downloadedItems.first { $0.item.id == itemID && $0.isActive }?.id
                }
                let displayTitle = await MainActor.run {
                    mediaLibrary.downloadedItems.first { $0.item.id == itemID && $0.isActive }?.item.title
                        ?? resolvedItem.title
                }
                let cacheKey = persistID ?? SceneOfflineBakeService.stableOrphanCacheItemID(contentRootPath: sceneContentRoot.path)

                // 使用 wallpaper-wgpu bake 子命令烘焙
                let artifact = try await SceneOfflineBakeService.bake(
                    eligibility: eligibility,
                    contentRoot: sceneContentRoot,
                    cacheItemID: cacheKey,
                    renderer: .wallpaperWgpu,
                    persistArtifactToItemID: persistID,
                    progressItemID: itemID,
                    displayTitle: displayTitle,
                    progress: { progress in
                        // 全局 tracker 会广播通知；本地回调兜底当前页即时刷新
                        updateSceneBakeProgress(progress)
                    }
                )

                await MainActor.run {
                    isBakingScene = false
                    isSettingWallpaper = false
                    scheduleSceneBakeSuccessFlash()
                    // 烘焙完成后与手动设壁纸同一路径
                    applyWorkshopWallpaperFromLocalURL(sceneContentRoot)
                }
            } catch {
                await MainActor.run {
                    isBakingScene = false
                    isSettingWallpaper = false
                    let detail = Self.truncateErrorMessage(error.localizedDescription)
                    errorMessage = detail
                    showError = true
                    print("[SceneWallpaper] 离线烘焙失败: \(error.localizedDescription)")
                }
            }
        }
    }

    /// 系统分享：已下载的本地源文件（视频分享文件，常见静图分享 NSImage）
    private func shareDownloadedMediaFile() {
        guard isAlreadyDownloaded else { return }
        let url = findLocalWorkshopFile() ?? resolvedShareableFileFromRecordOrCover()
        guard let url else { return }
        let items = SystemShareSupport.itemsForLocalFile(at: url)
        SystemShareSupport.presentPicker(items: items, anchorView: sharePickerAnchorView)
    }

    /// 将离线烘焙 MP4 作为文件引用写入剪贴板，供 Finder 等应用直接粘贴。
    @MainActor
    private func copyBakedSceneVideoToPasteboard(_ videoURL: URL) {
        guard SceneOfflineBakeService.isUsableBakedVideo(at: videoURL) else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.writeObjects([videoURL as NSURL]) else {
            print("[MediaDetailSheet] ⚠️ 无法复制烘焙视频到剪贴板: \(videoURL.path)")
            return
        }

        copyToastMessage = "烘焙视频已复制"
        showCopyLinkToast = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            showCopyLinkToast = false
        }
        print("[MediaDetailSheet] 已复制烘焙视频到剪贴板: \(videoURL.lastPathComponent)")
    }

    /// 复制当前壁纸的静态图片到剪贴板
    private func copyStaticImageToPasteboard() {
        Task { @MainActor in
            var imageURL: URL?
            let imageExtensions: Set<String> = [
                "jpg", "jpeg", "png", "webp", "gif", "heic", "heif", "avif", "bmp", "tiff", "tif"
            ]
            let videoExtensions: Set<String> = ["mp4", "mov", "webm", "m4v", "mkv"]

            // 1. 优先从烘焙产物抽帧
            if let record = currentDownloadRecord,
               let artifact = record.sceneBakeArtifact,
               SceneOfflineBakeService.isUsableBakedVideo(at: URL(fileURLWithPath: artifact.videoPath)) {
                imageURL = await VideoThumbnailCache.shared.sceneBakePosterJPEGFileURL(
                    forLocalVideo: URL(fileURLWithPath: artifact.videoPath),
                    itemID: record.item.id
                )
            }

            // 2. Web 壁纸截图
            if imageURL == nil, WallpaperEngineXBridge.shared.isCurrentWallpaperWeb {
                let webCapture = "/tmp/wallpaperengine-web-capture.png"
                if FileManager.default.fileExists(atPath: webCapture) {
                    imageURL = URL(fileURLWithPath: webCapture)
                }
            }

            // 3. 实时渲染壁纸的静态帧
            if imageURL == nil, WallpaperEngineXBridge.shared.isControllingExternalEngine {
                if let path = WallpaperEngineXBridge.shared.currentWallpaperPathForDesign {
                    let hash = abs(path.hashValue)
                    let cacheKey = "cached_frame_\(hash)"
                    if let cachedPath = UserDefaults.standard.string(forKey: cacheKey),
                       FileManager.default.fileExists(atPath: cachedPath) {
                        imageURL = URL(fileURLWithPath: cachedPath)
                    }
                }
            }

            // 4. 本机视频壁纸：从视频抽一帧
            if imageURL == nil {
                let candidateVideoURLs: [URL] = {
                    var urls: [URL] = []
                    if let localURL = currentDownloadRecord?.localFileURL {
                        if let videoURL = MediaItem.resolveLocalVideoFile(from: localURL) {
                            urls.append(videoURL)
                        } else if videoExtensions.contains(localURL.pathExtension.lowercased()) {
                            urls.append(localURL)
                        }
                    }
                    if let workshop = findLocalWorkshopFile() {
                        if let videoURL = MediaItem.resolveLocalVideoFile(from: workshop) {
                            urls.append(videoURL)
                        } else if videoExtensions.contains(workshop.pathExtension.lowercased()) {
                            urls.append(workshop)
                        }
                    }
                    if let preview = previewVideoURL,
                       preview.isFileURL,
                       videoExtensions.contains(preview.pathExtension.lowercased()) {
                        urls.append(preview)
                    }
                    // 去重
                    var seen = Set<String>()
                    return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
                }()

                for videoURL in candidateVideoURLs {
                    if let cached = VideoThumbnailCache.shared.cachedStaticThumbnailFileURLIfExists(forLocalFile: videoURL) {
                        imageURL = cached
                        break
                    }
                    if let poster = await VideoThumbnailCache.shared.posterJPEGFileURL(forLocalVideo: videoURL) {
                        imageURL = poster
                        break
                    }
                }
            }

            // 5. Workshop 预览图 / 本地静态图文件
            if imageURL == nil {
                let localCandidates: [URL] = {
                    var urls: [URL] = []
                    if let recordURL = currentDownloadRecord?.localFileURL {
                        urls.append(recordURL)
                    }
                    if let workshop = findLocalWorkshopFile() {
                        urls.append(workshop)
                    }
                    if isLocalFile,
                       resolvedItem.coverImageURL.isFileURL {
                        urls.append(resolvedItem.coverImageURL)
                    }
                    var seen = Set<String>()
                    return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
                }()

                for local in localCandidates {
                    if let preview = MediaItem.resolveLocalWorkshopPreviewImage(from: local),
                       FileManager.default.fileExists(atPath: preview.path) {
                        imageURL = preview
                        break
                    }
                    let ext = local.pathExtension.lowercased()
                    if imageExtensions.contains(ext),
                       FileManager.default.fileExists(atPath: local.path) {
                        imageURL = local
                        break
                    }
                }
            }

            // 6. 封面图（本地文件优先；远程封面尽量下载后写入剪贴板）
            if imageURL == nil {
                let cover = resolvedItem.coverImageURL
                if cover.isFileURL, FileManager.default.fileExists(atPath: cover.path) {
                    imageURL = cover
                } else if let image = await loadNSImageForPasteboard(from: cover) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([image])
                    showCopyLinkToast = true
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        showCopyLinkToast = false
                    }
                    print("[MediaDetailSheet] ✅ 已复制静态图片到剪贴板（远程封面）")
                    return
                }
            }

            guard let imageURL, FileManager.default.fileExists(atPath: imageURL.path) else {
                print("[MediaDetailSheet] ⚠️ 未找到可复制的静态图片")
                return
            }

            if let image = NSImage(contentsOf: imageURL) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([image])
                showCopyLinkToast = true
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    showCopyLinkToast = false
                }
                print("[MediaDetailSheet] ✅ 已复制静态图片到剪贴板: \(imageURL.lastPathComponent)")
            } else {
                print("[MediaDetailSheet] ⚠️ 无法读取图片文件: \(imageURL.path)")
            }
        }
    }

    /// 为剪贴板加载图片：本地直接读，远程则下载
    private func loadNSImageForPasteboard(from url: URL) async -> NSImage? {
        if url.isFileURL {
            return NSImage(contentsOf: url)
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return nil
            }
            return NSImage(data: data)
        } catch {
            print("[MediaDetailSheet] ⚠️ 下载封面失败: \(error.localizedDescription)")
            return nil
        }
    }

    private func resolvedShareableFileFromRecordOrCover() -> URL? {
        if let record = currentDownloadRecord {
            let u = record.localFileURL
            guard FileManager.default.fileExists(atPath: u.path) else { return nil }
            var isDir: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir)
            if isDir.boolValue { return pickWorkshopPlayableFile(from: u) }
            return u
        }
        if isLocalFile,
           resolvedItem.coverImageURL.isFileURL,
           FileManager.default.fileExists(atPath: resolvedItem.coverImageURL.path) {
            return resolvedItem.coverImageURL
        }
        return nil
    }

    /// 查找本地已下载的 Workshop 文件
    private func findLocalWorkshopFile() -> URL? {
        findLocalWorkshopFile(for: resolvedItem)
    }

    private func findLocalWorkshopFile(for item: MediaItem) -> URL? {
        if item.id.hasPrefix("workshop_") {
            let workshopID = String(item.id.dropFirst("workshop_".count))
            let fm = FileManager.default

            if let record = MediaLibraryService.shared.downloadedItems.first(where: { $0.item.id == item.id }) {
                let recordedURL = record.localFileURL
                if let resolved = resolveWorkshopContentPath(recordedURL, workshopID: workshopID), fm.fileExists(atPath: resolved.path) {
                    return pickWorkshopPlayableFile(from: resolved)
                }
            }

            let mediaFolder = DownloadPathManager.shared.mediaFolderURL
            let steamPath = mediaFolder
                .appendingPathComponent("workshop_\(workshopID)/steamapps/workshop/content/431960/\(workshopID)")
            let rootPath = mediaFolder.appendingPathComponent("workshop_\(workshopID)")

            if fm.fileExists(atPath: steamPath.path) {
                return pickWorkshopPlayableFile(from: steamPath)
            }
            if fm.fileExists(atPath: rootPath.path) {
                return pickWorkshopPlayableFile(from: rootPath)
            }
            return nil
        }

        // 本地导入等非 workshop_ id：依赖媒体库下载记录路径
        if let record = MediaLibraryService.shared.downloadedItems.first(where: { $0.item.id == item.id }) {
            let recordedURL = record.localFileURL
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: recordedURL.path, isDirectory: &isDir) else { return nil }
            return pickWorkshopPlayableFile(from: recordedURL)
        }
        return nil
    }

    /// 预览设为壁纸的内容：优先已烘焙 MP4 → 本地视频文件 → 静态封面图
    private func previewWallpaper() async {
        let targetURL: URL?
        var isWebPreview = false

        // 1. 已烘焙的 Scene MP4
        if let cachedSceneBakeVideoURL {
            targetURL = cachedSceneBakeVideoURL
        }
        // 2. 本地 Workshop 文件/目录
        else if let localURL = findLocalWorkshopFile() {
            let ext = localURL.pathExtension.lowercased()
            if ["mp4", "mov", "webm"].contains(ext) {
                targetURL = localURL
            } else {
                // 判断目录内容类型（scene/web/image/video 等）
                var checkDir = localURL
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: localURL.path, isDirectory: &isDir), !isDir.boolValue {
                    checkDir = localURL.deletingLastPathComponent()
                }
                let contentType = determineWorkshopContentType(at: checkDir)
                if contentType == .web {
                    targetURL = checkDir
                    isWebPreview = true
                } else {
                    // 非 web 类型回退到静态图或原路径
                    targetURL = resolvedShareableFileFromRecordOrCover() ?? localURL
                }
            }
        }
        // 3. 静态图（封面或下载记录中的图片）
        else if let imageURL = resolvedShareableFileFromRecordOrCover() {
            targetURL = imageURL
        }
        // 4. 网络封面图兜底
        else {
            targetURL = resolvedItem.posterURL
        }

        guard let url = targetURL else { return }
        var aspectRatio: Double? = parseAspectRatio(from: resolvedItem.exactResolution)
        // 视频文件优先读取实际尺寸，更准确
        if ["mp4", "mov", "webm"].contains(url.pathExtension.lowercased()) {
            aspectRatio = await videoAspectRatio(of: url) ?? aspectRatio
        }
        // Web壁纸传递背景图URL作为占位符
        let posterForPreview: URL? = isWebPreview ? preferredWorkshopPosterForVideo : nil
        PreviewWindowManager.shared.openPreview(url: url, aspectRatio: aspectRatio, isWeb: isWebPreview, posterURL: posterForPreview)
    }

    /// 从 "1920x1080" / "1920 x 1080" / "1080X1920" 这类分辨率字符串解析宽高比
    private func parseAspectRatio(from resolution: String?) -> Double? {
        guard let resolution = resolution else { return nil }
        let trimmed = resolution
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "X", with: "x")
        let parts = trimmed.split(separator: "x")
        guard parts.count == 2,
              let w = Double(parts[0]),
              let h = Double(parts[1]),
              h > 0 else { return nil }
        return w / h
    }

    /// 读取本地视频文件的实际宽高比（支持竖屏视频的旋转信息）
    private func videoAspectRatio(of url: URL) async -> Double? {
        let asset = AVAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return nil }
        let size = try? await track.load(.naturalSize)
        guard let size = size, size.height > 0 else { return nil }
        let transform = try? await track.load(.preferredTransform)
        // 检查是否有 90 度旋转（竖屏视频）
        let isPortrait = abs(transform?.b ?? 0) == 1.0 && abs(transform?.c ?? 0) == 1.0
        if isPortrait {
            return size.height / size.width
        }
        return size.width / size.height
    }

    /// 含 `project.json` 的工程根（目录本身，或单文件的父目录）
    private func sceneEngineContentRoot(for localURL: URL) -> URL {
        var isDir: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: localURL.path, isDirectory: &isDir)
        return isDir.boolValue ? localURL : localURL.deletingLastPathComponent()
    }

    private func resolveWorkshopContentPath(_ url: URL, workshopID: String) -> URL? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }

        // 已经是最终内容目录
        if isDir.boolValue,
           url.pathComponents.suffix(2).joined(separator: "/") == "431960/\(workshopID)" {
            return url
        }

        // 可能记录的是 workshop_xxx 根目录
        if isDir.boolValue {
            let nested = url.appendingPathComponent("steamapps/workshop/content/431960/\(workshopID)")
            if fm.fileExists(atPath: nested.path) {
                return nested
            }
        }

        // 可能直接记录了 scene.pkg 或视频文件
        if !isDir.boolValue {
            let ext = url.pathExtension.lowercased()
            if ["pkg", "mp4", "mov", "webm"].contains(ext) {
                return url
            }
        }

        return nil
    }

    /// Workshop 内容类型
    private enum WorkshopContentType: Equatable {
        case video        // 纯视频类型，WaifuX 可直接播放
        case scene        // 场景类型，需要 Wallpaper Engine CLI 渲染
        case web          // Web 类型，需要 Wallpaper Engine CLI 渲染
        case image        // 静态图片壁纸（无 type/file，有 background 图片）
        case unsupported(String) // 不支持的类型（如 application、游戏等）
        case unknown
    }

    /// 确定 Workshop 内容类型（通过 project.json 判断）
    private func determineWorkshopContentType(at contentDir: URL) -> WorkshopContentType {
        let projectURL = contentDir.appendingPathComponent("project.json")
        guard let data = try? Data(contentsOf: projectURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unknown
        }

        // 1. 优先读取明确的 type 字段
        if let typeString = json["type"] as? String {
            let type = typeString.lowercased()
            switch type {
            case "video": return .video
            case "scene": return .scene
            case "web": return .web
            default: return .unsupported(typeString)
            }
        }

        // 2. 启发式推断（type 缺失时常见于预设包/依赖型壁纸）
        return inferWorkshopContentType(from: json, contentDir: contentDir)
    }

    /// 当 project.json 缺少 type 字段时的启发式类型推断
    private func inferWorkshopContentType(from json: [String: Any], contentDir: URL) -> WorkshopContentType {
        let fm = FileManager.default

        // 1. 有 background 指向明确的媒体文件 → 优先按实际媒体类型识别（不应被 dependency/preset 覆盖为 web）
        if let background = json["background"] as? String {
            let bgPath = contentDir.appendingPathComponent(background).path
            if fm.fileExists(atPath: bgPath) {
                let ext = (background as NSString).pathExtension.lowercased()
                if ["jpg", "jpeg", "png", "bmp", "gif", "webp", "tga", "tif", "tiff"].contains(ext) {
                    return .image
                }
                if ["mp4", "mov", "webm"].contains(ext) {
                    return .video
                }
            }
        }

        // 2. 有 dependency + preset → Web 预设
        if json["dependency"] != nil && json["preset"] != nil {
            return .web
        }

        // 目录下有 scene.pkg 或 scene.json → scene
        if fm.fileExists(atPath: contentDir.appendingPathComponent("scene.pkg").path) ||
           fm.fileExists(atPath: contentDir.appendingPathComponent("scene.json").path) {
            return .scene
        }

        // 目录下有视频文件 → video
        let rootContents = try? fm.contentsOfDirectory(at: contentDir, includingPropertiesForKeys: nil)
        if rootContents?.contains(where: { ["mp4", "mov", "webm"].contains($0.pathExtension.lowercased()) }) == true {
            return .video
        }

        // 有 dependency → 尝试 web
        if json["dependency"] != nil {
            return .web
        }

        return .unknown
    }

    private func pickWorkshopPlayableFile(from contentPath: URL) -> URL {
        var isDir: ObjCBool = false
        let fm = FileManager.default
        guard fm.fileExists(atPath: contentPath.path, isDirectory: &isDir), isDir.boolValue else {
            // 如果不是目录，检查是否是视频文件
            let ext = contentPath.pathExtension.lowercased()
            if ["mp4", "mov", "webm"].contains(ext) {
                return contentPath
            }
            // pkg 文件也直接返回
            if ext == "pkg" {
                return contentPath
            }
            // 其他文件返回目录（让 CLI 处理）
            return contentPath.deletingLastPathComponent()
        }

        let contentPath = WorkshopService.resolveWallpaperEngineProjectRoot(startingAt: contentPath)

        // 目录内容：先统计有哪些文件类型
        let rootContents = try? fm.contentsOfDirectory(at: contentPath, includingPropertiesForKeys: nil)
        let hasPkgFile = rootContents?.contains(where: { $0.pathExtension.lowercased() == "pkg" }) ?? false
        let hasProjectJson = fm.fileExists(atPath: contentPath.appendingPathComponent("project.json").path)

        // 1. 先检查 project.json 确定内容类型
        let contentType = determineWorkshopContentType(at: contentPath)

        // 2. 纯视频类型 → 优先用 project.json 中 background/file 字段的明确路径，其次递归查找
        if contentType == .video {
            if let projectData = try? Data(contentsOf: contentPath.appendingPathComponent("project.json")),
               let projectJson = try? JSONSerialization.jsonObject(with: projectData) as? [String: Any] {
                for key in ["background", "file"] {
                    if let path = projectJson[key] as? String {
                        let candidate = contentPath.appendingPathComponent(path)
                        let ext = candidate.pathExtension.lowercased()
                        if ["mp4", "mov", "webm"].contains(ext), fm.fileExists(atPath: candidate.path) {
                            return candidate
                        }
                    }
                }
            }
            // 字段未命中时递归查找视频文件
            if let videoURL = findVideoFile(in: contentPath) {
                return videoURL
            }
            // 有 project.json 且类型是 video 但没找到视频，返回目录
            return contentPath
        }

        // 3. 如果根目录直接有视频文件（纯视频 Workshop 的常见情况）。
        // AVPlayer 对 h264/h265 (mp4/mov) 兼容性最好，vp9 (webm) 可能无法打开；
        // Workshop 壁纸常同时自带预烘焙 mp4 + webm，必须优先 mp4/mov，webm 仅兜底。
        if let rootVideo = rootContents?.first(where: {
            ["mp4", "mov", "m4v"].contains($0.pathExtension.lowercased())
        }) {
            return rootVideo
        }
        if let rootVideo = rootContents?.first(where: {
            $0.pathExtension.lowercased() == "webm"
        }) {
            return rootVideo
        }

        // 4. 如果根目录直接有 .pkg 文件，这是 scene 类型，需要 CLI
        if hasPkgFile {
            return contentPath
        }

        // 5. scene 类型或 unknown 类型：递归查找 .pkg 文件
        if contentType == .scene || contentType == .unknown {
            if let pkgURL = findPkgFile(in: contentPath) {
                return pkgURL
            }
        }

        // 静态图片壁纸：返回 background 图片路径（不走 CLI）
        if contentType == .image {
            if let projectData = try? Data(contentsOf: contentPath.appendingPathComponent("project.json")),
               let projectJson = try? JSONSerialization.jsonObject(with: projectData) as? [String: Any],
               let background = projectJson["background"] as? String {
                let imagePath = contentPath.appendingPathComponent(background)
                if fm.fileExists(atPath: imagePath.path) {
                    return imagePath
                }
            }
            return contentPath
        }

        // 6. 如果有 project.json 但不是 video 类型，返回目录让 CLI 处理
        if hasProjectJson {
            return contentPath
        }

        // 7. 兜底：递归找视频文件（处理嵌套目录中的视频）
        if let videoURL = findVideoFile(in: contentPath) {
            return videoURL
        }

        // 8. 什么都没找到，返回目录
        return contentPath
    }

    /// 递归查找目录中的视频文件
    private func findVideoFile(in directory: URL) -> URL? {
        let videoExts = ["mp4", "mov", "webm"]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return nil
        }
        for case let fileURL as URL in enumerator {
            if videoExts.contains(fileURL.pathExtension.lowercased()) {
                return fileURL
            }
        }
        return nil
    }

    /// 递归查找目录中的 .pkg 文件
    private func findPkgFile(in directory: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return nil
        }
        for case let fileURL as URL in enumerator {
            if fileURL.pathExtension.lowercased() == "pkg" {
                return fileURL
            }
        }
        return nil
    }

    /// 如果目录是 preset 类型且还没有 index.html，根据 preset 配置生成 HTML 轮播页面
    private func ensurePresetHTMLGenerated(at contentRoot: URL) {
        let fm = FileManager.default
        let htmlURL = contentRoot.appendingPathComponent("index.html")
        guard !fm.fileExists(atPath: htmlURL.path) else { return } // 已有则跳过

        let projectJSONURL = contentRoot.appendingPathComponent("project.json")
        guard fm.fileExists(atPath: projectJSONURL.path),
              let data = try? Data(contentsOf: projectJSONURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["type"] == nil,
              let presetDict = json["preset"] as? [String: Any],
              let customDir = presetDict["customdirectory"] as? String else { return }

        let imagesDir = contentRoot.appendingPathComponent(customDir)
        let imageExts: Set<String> = ["jpg", "jpeg", "png", "bmp", "gif", "webp", "tga", "tif", "tiff"]
        guard let contents = try? fm.contentsOfDirectory(
            at: imagesDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return }
        let images = contents
            .filter { imageExts.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !images.isEmpty else { return }

        let multiplier = presetDict["imageswitchtimes"] as? Int ?? 1
        let switchTime = max(multiplier * 5, 3)
        let escapedPaths = images.map { url -> String in
            let relPath = "directories/customdirectory/" + url.lastPathComponent
            let escaped = relPath.replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
        let imagesJS = "[\(escapedPaths.joined(separator: ","))]"

        let html = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        html, body { width: 100%; height: 100%; overflow: hidden; background: #000; }
        .slideshow { position: relative; width: 100%; height: 100%; }
        .slide {
            position: absolute; top: 0; left: 0; width: 100%; height: 100%;
            background-size: cover; background-position: center; background-repeat: no-repeat;
            opacity: 0; transition: opacity 1.2s ease-in-out;
        }
        .slide.active { opacity: 1; }
        </style>
        </head>
        <body>
        <div class="slideshow" id="slideshow"></div>
        <script>
        const images = \(imagesJS);
        const switchTime = \(max(switchTime, 1)) * 1000;
        const container = document.getElementById('slideshow');
        let current = 0;
        images.forEach((src, i) => {
            const div = document.createElement('div');
            div.className = 'slide' + (i === 0 ? ' active' : '');
            div.style.backgroundImage = 'url("' + src + '")';
            container.appendChild(div);
        });
        const slides = container.querySelectorAll('.slide');
        setInterval(() => {
            slides[current].classList.remove('active');
            current = (current + 1) % slides.length;
            slides[current].classList.add('active');
        }, switchTime);
        </script>
        </body>
        </html>
        """
        try? html.write(to: htmlURL, atomically: true, encoding: .utf8)
    }

    private func workshopContentDirectory(for item: MediaItem) -> URL? {
        let fm = FileManager.default
        guard let localURL = findLocalWorkshopFile(for: item) else { return nil }

        var isDir: ObjCBool = false
        if fm.fileExists(atPath: localURL.path, isDirectory: &isDir) {
            if isDir.boolValue {
                return localURL
            }
            return localURL.deletingLastPathComponent()
        }
        return nil
    }

    private func localWorkshopPreviewImageURL(for item: MediaItem) -> URL? {
        let fm = FileManager.default
        guard let contentDir = workshopContentDirectory(for: item) else { return nil }

        let projectURL = contentDir.appendingPathComponent("project.json")
        if let data = try? Data(contentsOf: projectURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let previewName = json["preview"] as? String,
           !previewName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let previewURL = contentDir.appendingPathComponent(previewName)
            if fm.fileExists(atPath: previewURL.path) {
                return previewURL
            }
        }

        // 兼容无 project.json 或字段缺失
        let fallbackNames = ["preview.gif", "preview.jpg", "preview.jpeg", "preview.png", "preview.webp"]
        for name in fallbackNames {
            let candidate = contentDir.appendingPathComponent(name)
            if fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// 如果 Workshop 项已下载本地资产，优先注入本地视频和本地预览图
    private func itemWithLocalWorkshopVideo(_ item: MediaItem) -> MediaItem {
        guard item.id.hasPrefix("workshop_") else { return item }

        var updatedPreviewVideoURL = item.previewVideoURL
        var updatedPosterURL = item.posterURL
        let videoExts = Self.previewVideoExtensions

        // 1) 可播放文件路径（pickWorkshopPlayableFile 可能直接返回 mp4）
        if let localPlayable = findLocalWorkshopFile(for: item) {
            if videoExts.contains(localPlayable.pathExtension.lowercased()) {
                updatedPreviewVideoURL = localPlayable
            } else if let nestedVideo = MediaItem.resolveLocalVideoFile(from: localPlayable) {
                // 2) content 目录 / project 根内嵌视频
                updatedPreviewVideoURL = nestedVideo
            }
        }

        // 3) 下载记录路径再兜底扫一遍（与 findLocal 偶发路径不一致时）
        if updatedPreviewVideoURL == nil || !(updatedPreviewVideoURL?.isFileURL ?? false),
           let record = MediaLibraryService.shared.downloadedItems.first(where: { $0.item.id == item.id }) {
            let recorded = record.localFileURL
            if videoExts.contains(recorded.pathExtension.lowercased()) {
                updatedPreviewVideoURL = recorded
            } else if let nestedVideo = MediaItem.resolveLocalVideoFile(from: recorded) {
                updatedPreviewVideoURL = nestedVideo
            }
        }

        if let localPreviewURL = localWorkshopPreviewImageURL(for: item) {
            updatedPosterURL = localPreviewURL
        }

        if updatedPreviewVideoURL == item.previewVideoURL && updatedPosterURL == item.posterURL {
            return item
        }

        return MediaItem(
            slug: item.slug,
            title: item.title,
            pageURL: item.pageURL,
            thumbnailURL: item.thumbnailURL,
            resolutionLabel: item.resolutionLabel,
            collectionTitle: item.collectionTitle,
            summary: item.summary,
            previewVideoURL: updatedPreviewVideoURL,
            posterURL: updatedPosterURL,
            tags: item.tags,
            exactResolution: item.exactResolution,
            durationSeconds: item.durationSeconds,
            downloadOptions: item.downloadOptions,
            sourceName: item.sourceName,
            isAnimatedImage: item.isAnimatedImage,
            subscriptionCount: item.subscriptionCount,
            favoriteCount: item.favoriteCount,
            viewCount: item.viewCount,
            ratingScore: item.ratingScore,
            authorName: item.authorName,
            authorSteamID: item.authorSteamID,
            authorAvatarURL: item.authorAvatarURL,
            fileSize: item.fileSize,
            createdAt: item.createdAt,
            updatedAt: item.updatedAt
        )
    }

    /// 修复历史脏数据：早期导入未读 project.json 的 workshopid 字段，可能把本地 hash/UUID
    /// 伪造成了打不开的 Steam 链接。这里从本地 project.json 重新提取真实 ID 并修正 pageURL。
    private func itemWithCorrectedWorkshopPageURL(_ item: MediaItem) -> MediaItem {
        // 仅 workshop 导入项需要修正
        guard item.id.hasPrefix("workshop_") || item.sourceName == t("wallpaperEngine") else { return item }

        // 当前 pageURL 已是合法 Steam 链接（含纯数字 ID）则无需修正
        if hasValidSteamPageURL(item) { return item }

        // 定位本地 project.json
        guard let localFileURL = findLocalWorkshopFile(for: item) else { return item }
        let projectRoot = WorkshopService.resolveWallpaperEngineProjectRoot(startingAt: localFileURL)
        let projectURL = projectRoot.appendingPathComponent("project.json")
        guard let data = try? Data(contentsOf: projectURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return item
        }

        // 提取真实 Steam ID（与 ImportService 保持一致）
        var steamID = (json["workshopid"] as? String)
            ?? (json["publishedfileid"] as? String)
            ?? (json["id"] as? String)
        steamID = steamID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if steamID == nil || steamID!.isEmpty,
           let rawURL = json["workshopurl"] as? String {
            let urlStr = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if !urlStr.isEmpty {
                steamID = extractSteamIDFromWorkshopURL(urlStr)
            }
        }
        // 必须是纯数字才算真实 Steam ID
        guard let realID = steamID, !realID.isEmpty, realID.allSatisfy(\.isNumber) else {
            return item
        }

        let correctedPageURL = URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(realID)")!
        return MediaItem(
            slug: item.slug,
            title: item.title,
            pageURL: correctedPageURL,
            thumbnailURL: item.thumbnailURL,
            resolutionLabel: item.resolutionLabel,
            collectionTitle: item.collectionTitle,
            summary: item.summary,
            previewVideoURL: item.previewVideoURL,
            posterURL: item.posterURL,
            tags: item.tags,
            exactResolution: item.exactResolution,
            durationSeconds: item.durationSeconds,
            downloadOptions: item.downloadOptions,
            sourceName: item.sourceName,
            isAnimatedImage: item.isAnimatedImage,
            subscriptionCount: item.subscriptionCount,
            favoriteCount: item.favoriteCount,
            viewCount: item.viewCount,
            ratingScore: item.ratingScore,
            authorName: item.authorName,
            authorSteamID: item.authorSteamID,
            authorAvatarURL: item.authorAvatarURL,
            fileSize: item.fileSize,
            createdAt: item.createdAt,
            updatedAt: item.updatedAt
        )
    }

    /// 判断 item 的 pageURL 是否是合法的 Steam Workshop 链接（非本地 file URL、ID 为纯数字）
    private func hasValidSteamPageURL(_ item: MediaItem) -> Bool {
        let url = item.pageURL
        // 本地 file URL（导入时无真实 ID 的兜底）不算合法 Steam 链接
        if url.isFileURL { return false }
        guard url.absoluteString.contains("steamcommunity.com/sharedfiles/filedetails") else { return false }
        // 取 id 参数，必须纯数字
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let id = comps.queryItems?.first(where: { $0.name.lowercased() == "id" })?.value,
              !id.isEmpty, id.allSatisfy(\.isNumber) else { return false }
        return true
    }

    /// 从 Steam 链接提取 Workshop ID，支持 https 与 steam:// 两种形式
    private func extractSteamIDFromWorkshopURL(_ urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.allSatisfy(\.isNumber), !trimmed.isEmpty { return trimmed }
        guard let url = URL(string: trimmed),
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let path = comps.path.lowercased()
        if path.contains("sharedfiles/filedetails") {
            return comps.queryItems?.first(where: { $0.name.lowercased() == "id" })?.value
        }
        if trimmed.lowercased().hasPrefix("steam://"), path.contains("communityfilepage") {
            return path.split(separator: "/").last.map(String.init)
        }
        return nil
    }

    /// 当前详情项是否有合法 Steam 链接（用于修正本地 workshop 的 pageURL）
    private var hasValidSteamPageURL: Bool {
        hasValidSteamPageURL(resolvedItem)
    }

    /// 任意源可复制的远程链接：优先合法 Steam pageURL；
    /// 其余源（MotionBG / Wallsflow / 动态桌面 OSS 等）只要 pageURL 是 http(s) 即可复制。
    private func copyableSourceLinkString(for item: MediaItem) -> String? {
        let url = item.pageURL
        if url.isFileURL { return nil }
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else { return nil }
        let absolute = url.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !absolute.isEmpty else { return nil }
        // Workshop 源：只复制合法纯数字 ID 的 Steam 链接，避免假链接
        if item.id.hasPrefix("workshop_") || item.sourceName == t("wallpaperEngine") {
            return hasValidSteamPageURL(item) ? absolute : nil
        }
        return absolute
    }

    private var copyableSourceLinkString: String? {
        copyableSourceLinkString(for: resolvedItem)
    }

    /// 当前详情项是否有可复制的来源链接（用于「复制链接」按钮启用/置灰）
    private var hasCopyableSourceLink: Bool {
        copyableSourceLinkString != nil
    }

    private func scheduleSceneBakeSuccessFlash() {
        sceneBakeStatusFlash = t("sceneBake.success")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            sceneBakeStatusFlash = nil
        }
    }

    private var sceneBakeProgressSubtitle: String {
        if NSScreen.screens.count > 1 {
            return t("sceneBake.progressSubtitleMultiDisplay")
        }
        return t("sceneBake.progressSubtitle")
    }

    // MARK: - 作者壁纸弹窗

    @ViewBuilder
    private var authorSheetOverlay: some View {
        if showAuthorSheet,
           let steamID = resolvedItem.authorSteamID {
            AuthorMediaSheet(
                authorName: resolvedItem.authorName ?? t("unknown"),
                authorSteamID: steamID,
                authorAvatarURL: resolvedItem.authorAvatarURL,
                items: authorMediaItems,
                isLoading: isLoadingAuthorItems,
                hasMore: hasMoreAuthorItems,
                activeItemID: resolvedItem.id,
                onSelectItem: { selectedItem in
                    navigateToAuthorMedia(selectedItem)
                },
                onDismiss: {
                    dismissAuthorSheet()
                },
                onLoadMore: {
                    self.loadMoreAuthorMedia()
                },
                onDownloadAll: { items in
                    downloadAllByAuthor(authorName: resolvedItem.authorName ?? t("unknown"), items: items)
                },
                isDownloadingAll: $isDownloadingAllAuthor
            )
            .transition(.identity)
            .zIndex(100)
        }
    }

    /// 打开作者壁纸弹窗，开始加载该作者的 Workshop 壁纸列表
    private func openAuthorSheet() {
        guard let steamID = resolvedItem.authorSteamID else { return }
        // 面板已打开且同一作者时，不重复加载
        if showAuthorSheet && steamID == authorLoadedSteamID { return }
        showAuthorSheet = true
        authorLoadedSteamID = steamID
        authorMediaItems = []
        authorItemsPage = 1
        hasMoreAuthorItems = true
        isLoadingAuthorItems = true

        Task {
            do {
                let page = try await viewModel.fetchMediaByAuthor(
                    steamID: steamID,
                    page: 1
                )
                await MainActor.run {
                    if let authorItem = page.items.first(where: {
                        $0.authorName != nil || $0.authorSteamID != nil || $0.authorAvatarURL != nil
                    }) {
                        resolvedItem = mediaItemByMergingAuthorMetadata(resolvedItem, fallback: authorItem)
                    }
                    // 作者列表保留当前项，不排除自己；当前项用 activeItemID 高亮
                    authorMediaItems = page.items
                    hasMoreAuthorItems = page.hasMore
                    isLoadingAuthorItems = false
                }
            } catch {
                AppLogger.error(.media, "加载作者 Workshop 壁纸失败",
                    metadata: ["steamID": steamID, "error": error.localizedDescription])
                await MainActor.run {
                    isLoadingAuthorItems = false
                }
            }
        }
    }

    private func dismissAuthorSheet() {
        showAuthorSheet = false
        authorMediaItems = []
        authorItemsPage = 1
        hasMoreAuthorItems = true
        isLoadingAuthorItems = false
        authorLoadedSteamID = nil
    }

    /// 批量下载作者所有已加载媒体，并自动归入以作者名命名的虚拟文件夹。
    /// 同作者多次批量下载会复用同一文件夹，避免拆成多个同名目录。
    private func downloadAllByAuthor(authorName: String, items: [MediaItem]) {
        let folderStore = LibraryFolderStore.shared
        let libraryService = MediaLibraryService.shared
        var identityKeys = Set(items.flatMap { LibraryFolderStore.mediaAuthorIdentityKeys($0) })
        if let steamID = resolvedItem.authorSteamID?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !steamID.isEmpty {
            identityKeys.insert("steam:\(steamID)")
        }
        let trimmedAuthorName = authorName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedAuthorName.isEmpty {
            identityKeys.insert("name:\(trimmedAuthorName.lowercased())")
        }

        // 作者列表项可能缺 authorName/steamID；下载前补齐，便于后续按作者身份复用文件夹
        let stampedItems = items.map {
            mediaItemByMergingAuthorMetadata($0, fallback: resolvedItem)
        }

        Task { @MainActor in
            defer { isDownloadingAllAuthor = false }

            let folder = folderStore.findOrCreateAuthorDownloadFolder(
                name: authorName,
                contentType: .media,
                identityKeys: identityKeys
            )

            // 已下载的项直接归入文件夹，过滤出需要下载的
            var pendingItems: [MediaItem] = []
            for item in stampedItems {
                if libraryService.isDownloaded(item) {
                    folderStore.moveMediaToFolder(
                        mediaID: item.id,
                        folderID: folder.id,
                        scope: .downloads
                    )
                } else {
                    pendingItems.append(item)
                }
            }

            // 全部已下载时只归夹；defer 会复位按钮，不弹错误框
            guard !pendingItems.isEmpty else { return }

            // 并发提交下载；folderID 在落盘登记时一并写入，避免“成功落盘却落在根目录”
            let vm = viewModel
            let folderID = folder.id
            var successCount = 0
            var failureCount = 0
            await withTaskGroup(of: (String, Bool).self) { group in
                for item in pendingItems {
                    group.addTask {
                        do {
                            if item.id.hasPrefix("workshop_") {
                                try await vm.downloadWorkshopWallpaper(item, folderID: folderID)
                            } else {
                                guard let bestOption = item.downloadOptions.max(by: {
                                    $0.qualityRank < $1.qualityRank
                                }) else {
                                    return (item.id, false)
                                }
                                _ = try await vm.downloadMedia(item, option: bestOption, folderID: folderID)
                            }
                            return (item.id, true)
                        } catch {
                            AppLogger.error(.download, "作者媒体批量下载失败",
                                metadata: ["itemID": item.id, "author": authorName,
                                           "error": error.localizedDescription])
                            return (item.id, false)
                        }
                    }
                }
                for await (_, ok) in group {
                    if ok { successCount += 1 } else { failureCount += 1 }
                }
            }

            // 兜底：本批成功项再归一次作者夹。
            // 优先按 isDownloaded；若仅有下载记录（文件检测偶发缓存滞后）也尝试归夹。
            for item in stampedItems {
                let hasRecord = libraryService.downloadRecords.contains {
                    $0.item.id == item.id && $0.isActive
                }
                guard libraryService.isDownloaded(item) || hasRecord else { continue }
                folderStore.moveMediaToFolder(
                    mediaID: item.id,
                    folderID: folderID,
                    scope: .downloads
                )
            }

            if failureCount > 0 {
                if successCount == 0 {
                    errorMessage = String(format: t("downloadAllByAuthor.allFailed"), failureCount)
                } else {
                    errorMessage = String(format: t("downloadAllByAuthor.partialFailed"), successCount, failureCount)
                }
                showError = true
            }
        }
    }

    /// 加载更多作者壁纸（分页）
    private func loadMoreAuthorMedia() {
        guard let steamID = resolvedItem.authorSteamID,
              !isLoadingAuthorItems,
              hasMoreAuthorItems else { return }
        isLoadingAuthorItems = true
        let nextPage = authorItemsPage + 1

        Task {
            do {
                let page = try await viewModel.fetchMediaByAuthor(
                    steamID: steamID,
                    page: nextPage
                )
                await MainActor.run {
                    let existingIDs = Set(authorMediaItems.map(\.id))
                    let newItems = page.items.filter { !existingIDs.contains($0.id) }
                    authorMediaItems.append(contentsOf: newItems)
                    authorItemsPage = nextPage
                    // 服务端 hasMore + 本页确实有新增；重复页/空增量时停
                    hasMoreAuthorItems = page.hasMore && !newItems.isEmpty
                    isLoadingAuthorItems = false
                }
            } catch {
                AppLogger.error(.media, "加载更多作者壁纸失败",
                    metadata: ["steamID": steamID, "page": nextPage, "error": error.localizedDescription])
                await MainActor.run {
                    isLoadingAuthorItems = false
                }
            }
        }
    }

    /// 从作者壁纸面板切换到新的壁纸详情（不关闭面板，原地替换数据，不做 NavigationStack 跳转）
    private func navigateToAuthorMedia(_ item: MediaItem) {
        // 作者列表所有项目同属一个作者，按字段补齐作者信息，避免只因 authorName 已存在就漏掉头像。
        let patchedItem = mediaItemByMergingAuthorMetadata(item, fallback: resolvedItem)
        guard patchedItem.id != resolvedItem.id else { return }

        // 始终原地替换 resolvedItem，不走 onNavigateToItem push 路径
        // 这样作者面板保持打开，详情页数据无缝切换
        isAuthorPanelFade = true
        isNavigating = true
        // 强制详情背景按新项重建，避免 Kingfisher/AVPlayer 残留上一张 GIF/视频
        isMediaLoaded = false
        mediaBackgroundEpoch &+= 1

        if let index = navigationItems.firstIndex(where: { $0.id == patchedItem.id }) {
            navigateToIndex(index)
        } else {
            reloadMedia(patchedItem)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            self.isNavigating = false
            self.isAuthorPanelFade = false
        }
    }

    private func clearWorkshopUpdateFlow(for itemID: String) {
        guard workshopUpdateItemID == itemID else { return }
        workshopUpdateItemID = nil
    }
}

// MARK: - 详情页加载动画
private struct LoadingOverlayView: View {
    @State private var isAnimating = false
    @State private var rotationAngle: Double = 0

    var body: some View {
        ZStack {
            Color(hex: "0A0A0C")
                .ignoresSafeArea()

            VStack(spacing: 24) {
                // 加载指示器
                ZStack {
                    // 外圈
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.1),
                                    Color.white.opacity(0.3),
                                    Color.white.opacity(0.1)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 3
                        )
                        .frame(width: 48, height: 48)

                    // 旋转的弧线
                    Circle()
                        .trim(from: 0, to: 0.7)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.8),
                                    Color.white.opacity(0.4),
                                    Color.clear
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round)
                        )
                        .frame(width: 48, height: 48)
                        .rotationEffect(.degrees(rotationAngle))
                }
                .onAppear {
                    withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                        rotationAngle = 360
                    }
                }

                // 加载文本
                Text(t("loading"))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - 来源加载占位动画
private struct SourceLoadingPlaceholder: View {
    @State private var rotationAngle: Double = 0

    var body: some View {
        VStack(spacing: 12) {
            // 模拟 3 个来源行的骨架
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: 10) {
                    // label 骨架
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 36, height: 12)

                    // 分辨率 + 文件大小骨架
                    VStack(alignment: .leading, spacing: 4) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.white.opacity(0.08))
                            .frame(width: 64, height: 10)

                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.white.opacity(0.05))
                            .frame(width: 44, height: 8)
                    }

                    Spacer(minLength: 0)

                    // 图标骨架
                    Circle()
                        .fill(Color.white.opacity(0.06))
                        .frame(width: 14, height: 14)
                }
                .padding(.horizontal, 12)
                .frame(height: 46)
                .detailGlassRoundedRectChrome(cornerRadius: 14, level: .prominent)
                .overlay(alignment: .center) {
                    // 微妙的脉冲动画暗示正在加载
                    RoundedRectangle(cornerRadius: 14)
                        .fill(
                            RadialGradient(
                                colors: [.white.opacity(0.03), .clear],
                                center: .center,
                                startRadius: 10,
                                endRadius: 40
                            )
                        )
                        .pulseAnimation()
                }
            }
        }
    }
}

// MARK: - 壁纸预览 Sheet（视频/图片通用）
struct WallpaperPreviewSheet: View {
    let url: URL
    let isWeb: Bool
    var posterURL: URL? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var isWebLoaded = false
    @StateObject private var previewPlayer = PreviewPlayer()
    /// 预览弹窗独立静音状态，与详情页互不干扰
    @State private var isPreviewMuted = true
    private var isVideo: Bool {
        ["mp4", "mov", "webm"].contains(url.pathExtension.lowercased())
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if isWeb {
                if let posterURL = posterURL {
                    KFImage(posterURL)
                        .cacheMemoryOnly(false)
                        .cancelOnDisappear(true)
                        .fade(duration: 0.3)
                        .placeholder { _ in Color.black }
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .ignoresSafeArea()
                        .opacity(isWebLoaded ? 0 : 1)
                }
                WebWallpaperPreviewView(url: url, onLoaded: { isWebLoaded = true })
                    .ignoresSafeArea()
            } else if isVideo {
                // 原生播放器悬浮控件（播放/暂停、进度条、音量、全屏）
                AVPlayerViewRepresentable(player: previewPlayer.player, controlsStyle: .floating)
                    .ignoresSafeArea()
                    .onAppear {
                        previewPlayer.load(url: url, isMuted: isPreviewMuted)
                    }
                    .onDisappear {
                        previewPlayer.cleanup()
                    }
            } else {
                KFImage(url)
                    .cacheMemoryOnly(false)
                    .cancelOnDisappear(true)
                    .fade(duration: 0.3)
                    .placeholder { _ in Color.black }
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
            }

            // 网页加载进度指示（视频使用 AVPlayerView 原生缓冲指示器）
            if isWeb && !isWebLoaded {
                VStack(spacing: 12) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.3)
                    Text(isWeb ? "加载中..." : "视频加载中...")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.6))
            }

            // 关闭按钮
            VStack {
                HStack {
                    Spacer()
                    Button {
                        // NSHostingView 装载在独立 NSWindow 时 dismiss() 不生效，
                        // 必须显式走 PreviewWindowManager.closePreview()，
                        // 否则视图不会被释放，AVPlayer 会继续播放音频
                        PreviewWindowManager.shared.closePreview()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(Color.black.opacity(0.45)))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 20)
                    .padding(.trailing, 20)
                }
                Spacer()
            }
        }
    }
}

// MARK: - 预览播放器（可拖拽进度条）

@MainActor
final class PreviewPlayer: ObservableObject, @unchecked Sendable {
    let player = AVPlayer()
    @Published var currentTime: TimeInterval = 0
    @Published var totalDuration: TimeInterval = 0
    @Published var isPlaying: Bool = true
    nonisolated(unsafe) private var timeObserver: Any?

    func load(url: URL, isMuted: Bool) {
        removeTimeObserver()

        player.isMuted = isMuted
        let item = AVPlayerItem(url: url)
        // 优化高码率/B帧视频的缓冲和 seek 性能
        item.preferredForwardBufferDuration = 3.0
        item.seekingWaitsForVideoCompositionRendering = false
        player.automaticallyWaitsToMinimizeStalling = true
        player.replaceCurrentItem(with: item)
        player.play()
        isPlaying = true

        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let duration = self.player.currentItem?.duration.seconds ?? 0
                guard duration.isFinite, duration > 0 else { return }
                self.currentTime = time.seconds
                self.totalDuration = duration
            }
        }
    }

    func seek(to time: TimeInterval) {
        // 使用默认容差（snap 到最近关键帧），避免 B 帧视频逐帧解码卡顿
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600))
    }

    func togglePlayPause() {
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
    }

    func cleanup() {
        removeTimeObserver()
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    private func removeTimeObserver() {
        if let observer = timeObserver {
            player.removeTimeObserver(observer)
            timeObserver = nil
        }
    }

    deinit {
        if let observer = timeObserver {
            DispatchQueue.main.async { [player] in
                player.removeTimeObserver(observer)
            }
        }
    }
}

struct AVPlayerViewRepresentable: NSViewRepresentable {
    let player: AVPlayer
    var controlsStyle: AVPlayerViewControlsStyle = .none

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = controlsStyle
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {}
}

// MARK: - 预览视频渲染层（AVPlayerLayer，避免 AVPlayerView 内部精确 seek）

struct PreviewVideoLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        layer.frame = view.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(layer)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let layer = nsView.layer?.sublayers?.first as? AVPlayerLayer {
            layer.frame = nsView.bounds
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        nsView.layer?.sublayers?.forEach { layer in
            if let pl = layer as? AVPlayerLayer { pl.player = nil }
            layer.removeFromSuperlayer()
        }
    }
}

// MARK: - 预览播放控制条

struct PreviewPlayerControls: View {
    @ObservedObject var player: PreviewPlayer
    @State private var isDragging = false
    @State private var dragValue: TimeInterval = 0

    var body: some View {
        HStack(spacing: 14) {
            // 播放/暂停
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

            // 当前时间
            Text(formatTime(isDragging ? dragValue : player.currentTime))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.85))

            // 进度条 — 关键：拖拽中暂停播放，松手后用默认容差 seek
            Slider(
                value: Binding(
                    get: { isDragging ? dragValue : player.currentTime },
                    set: { dragValue = $0 }
                ),
                in: 0...max(player.totalDuration, 0.1)
            ) { editing in
                isDragging = editing
                if editing {
                    player.player.pause()
                } else {
                    player.seek(to: dragValue)
                    if player.isPlaying { player.player.play() }
                }
            }
            .tint(.white)
            .frame(height: 16)

            // 总时长
            Text(formatTime(player.totalDuration))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.55)))
    }

    private func formatTime(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Web 壁纸预览 WebView
struct WebWallpaperPreviewView: NSViewRepresentable {
    let url: URL
    var onLoaded: (() -> Void)?

    /// 壁纸内容目录（用于读取 project.json）
    private var contentDir: URL {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if url.pathExtension.lowercased() == "html" || url.pathExtension.lowercased() == "htm" {
            return url.deletingLastPathComponent()
        }
        if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            return url
        }
        return url.deletingLastPathComponent()
    }

    /// WE Web API 垫片：避免壁纸脚本因 `undefined is not a function` 整页中断
    private static let wallpaperEngineWebAPIShim = WKUserScript(
        source: """
        (function() {
          try {
            window.wallpaperMediaIntegration = {
              playback: { PLAYING: 1, PAUSED: 2, STOPPED: 0 }
            };
            var __wxAudioCbs = [];
            var __wxAudioBuf = new Float32Array(128);
            var __wxAudioEnabled = false;
            window.wallpaperRegisterAudioListener = function(cb) {
              if (typeof cb === 'function') __wxAudioCbs.push(cb);
            };
            window.__wxUpdateAudioBuf = function(arr) {
              if (arr && arr.length) {
                __wxAudioEnabled = true;
                for (var i = 0; i < __wxAudioBuf.length && i < arr.length; i++) {
                  __wxAudioBuf[i] = arr[i];
                }
                for (var j = 0; j < __wxAudioCbs.length; j++) {
                  try { __wxAudioCbs[j](__wxAudioBuf); } catch (e) {}
                }
              }
            };
            setInterval(function() {
              if (!__wxAudioEnabled) {
                for (var i = 0; i < __wxAudioBuf.length; i++) __wxAudioBuf[i] = 0;
              }
              for (var j = 0; j < __wxAudioCbs.length; j++) {
                try { __wxAudioCbs[j](__wxAudioBuf); } catch (e) {}
              }
            }, 33);
            var __wxMedia = { status: [], properties: [], thumbnail: [], playback: [], timeline: [], lyrics: [], lyricsLine: [] };
            var __wxMediaState = { enabled: false, title: "", artist: "", albumTitle: "", state: 0, position: 0, duration: 0, rate: 1, thumbnail: "", lyrics: null, lyricsLine: null };
            function __wxFire(list, payload) {
              for (var i = 0; i < list.length; i++) { try { list[i](payload); } catch (e) {} }
            }
            window.wallpaperRegisterMediaStatusListener = function(cb) {
              if (typeof cb !== 'function') return;
              __wxMedia.status.push(cb);
              try { cb({ enabled: !!__wxMediaState.enabled }); } catch (e) {}
            };
            window.wallpaperRegisterMediaPropertiesListener = function(cb) {
              if (typeof cb !== 'function') return;
              __wxMedia.properties.push(cb);
              try {
                cb({ title: __wxMediaState.title||"", artist: __wxMediaState.artist||"", albumTitle: __wxMediaState.albumTitle||"", subTitle: __wxMediaState.artist||"" });
              } catch (e) {}
            };
            window.wallpaperRegisterMediaThumbnailListener = function(cb) {
              if (typeof cb !== 'function') return;
              __wxMedia.thumbnail.push(cb);
              try { cb({ thumbnail: __wxMediaState.thumbnail||"" }); } catch (e) {}
            };
            window.wallpaperRegisterMediaPlaybackListener = function(cb) {
              if (typeof cb !== 'function') return;
              __wxMedia.playback.push(cb);
              try { cb({ state: __wxMediaState.state|0 }); } catch (e) {}
            };
            window.wallpaperRegisterMediaTimelineListener = function(cb) {
              if (typeof cb !== 'function') return;
              __wxMedia.timeline.push(cb);
              try { cb({ position: __wxMediaState.position||0, duration: __wxMediaState.duration||0 }); } catch (e) {}
            };
            window.wallpaperRegisterMediaLyricsListener = function(cb) {
              if (typeof cb !== 'function') return;
              __wxMedia.lyrics.push(cb);
              try { if (__wxMediaState.lyrics) cb(__wxMediaState.lyrics); } catch (e) {}
            };
            window.wallpaperRegisterMediaLyricsLineListener = function(cb) {
              if (typeof cb !== 'function') return;
              __wxMedia.lyricsLine.push(cb);
              try { if (__wxMediaState.lyricsLine) cb(__wxMediaState.lyricsLine); } catch (e) {}
            };
            window.__wxParseB64JSON = function(b64) {
              if (!b64) return null;
              try {
                var bin = atob(b64);
                var bytes = new Uint8Array(bin.length);
                for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i) & 0xff;
                var text = (typeof TextDecoder !== 'undefined')
                  ? new TextDecoder('utf-8').decode(bytes)
                  : decodeURIComponent(escape(bin));
                return JSON.parse(text);
              } catch (e) {
                try { return JSON.parse(atob(b64)); } catch (e2) { return null; }
              }
            };
            window.__wxPushMediaUpdate = function(obj) {
              if (!obj || typeof obj !== 'object') return;
              if (typeof obj.enabled === 'boolean') __wxMediaState.enabled = obj.enabled;
              if (typeof obj.title === 'string') __wxMediaState.title = obj.title;
              if (typeof obj.artist === 'string') __wxMediaState.artist = obj.artist;
              if (typeof obj.albumTitle === 'string') __wxMediaState.albumTitle = obj.albumTitle;
              if (typeof obj.state === 'number') __wxMediaState.state = obj.state;
              if (typeof obj.position === 'number') __wxMediaState.position = obj.position;
              if (typeof obj.duration === 'number') __wxMediaState.duration = obj.duration;
              if (typeof obj.rate === 'number') __wxMediaState.rate = obj.rate;
              __wxFire(__wxMedia.status, { enabled: !!__wxMediaState.enabled });
              __wxFire(__wxMedia.properties, { title: __wxMediaState.title||"", artist: __wxMediaState.artist||"", albumTitle: __wxMediaState.albumTitle||"", subTitle: __wxMediaState.artist||"" });
              __wxFire(__wxMedia.playback, { state: __wxMediaState.state|0 });
              __wxFire(__wxMedia.timeline, { position: __wxMediaState.position||0, duration: __wxMediaState.duration||0 });
            };
            window.__wxPushMediaThumbnail = function(obj) {
              if (!obj || typeof obj !== 'object') return;
              __wxMediaState.thumbnail = (typeof obj.thumbnail === 'string') ? obj.thumbnail : "";
              __wxFire(__wxMedia.thumbnail, { thumbnail: __wxMediaState.thumbnail });
            };
            window.__wxPushMediaLyrics = function(obj) {
              if (!obj || typeof obj !== 'object') return;
              __wxMediaState.lyrics = obj;
              __wxFire(__wxMedia.lyrics, obj);
            };
            window.__wxPushMediaLyricsLine = function(obj) {
              if (!obj || typeof obj !== 'object') return;
              __wxMediaState.lyricsLine = obj;
              __wxFire(__wxMedia.lyricsLine, obj);
            };
          } catch (e) {}
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false
    )

    /// `file://` 本地文件兼容：修复 Spine 纹理 crossOrigin 及 atlas/XHR/fetch 读本地文件失败
    private static let localFileCompatScript = WKUserScript(
        source: """
        (function() {
          try {
            if (location.protocol !== "file:") return;

            function resolveURL(input) {
              if (typeof input === "string") return input;
              if (!input) return "";
              if (typeof input.href === "string" && input.href) return input.href;
              if (typeof input.url === "string" && input.url) return input.url;
              try { return String(input); } catch (e) { return ""; }
            }

            function isLocalNonHTTPURL(url) {
              if (!url) return false;
              var lower = String(url).toLowerCase();
              if (lower.indexOf("http:") === 0 || lower.indexOf("https:") === 0) return false;
              if (lower.indexOf("data:") === 0 || lower.indexOf("blob:") === 0) return false;
              return true;
            }

            var proto = HTMLImageElement.prototype;
            var srcDesc = Object.getOwnPropertyDescriptor(proto, "src");
            if (srcDesc && srcDesc.set) {
              Object.defineProperty(proto, "src", {
                set: function(value) {
                  try {
                    if (isLocalNonHTTPURL(String(value || ""))) {
                      this.removeAttribute("crossorigin");
                    }
                  } catch (e) {}
                  srcDesc.set.call(this, value);
                },
                get: srcDesc.get,
                configurable: true
              });
            }

            // WebKit 成功读取 file:// XHR 时常返回 status=0。Spine 3.6
            // 预览脚本会直接判断 status !== 200，导致存在的 atlas 被误报为失败。
            var xhrProto = window.XMLHttpRequest && window.XMLHttpRequest.prototype;
            if (xhrProto) {
              var originalOpen = xhrProto.open;
              if (typeof originalOpen === "function") {
                xhrProto.open = function(method, url) {
                  try {
                    this.__wxLocalFileRequest = isLocalNonHTTPURL(resolveURL(url));
                  } catch (e) {}
                  return originalOpen.apply(this, arguments);
                };
              }
              var statusDesc = Object.getOwnPropertyDescriptor(xhrProto, "status");
              if (statusDesc && statusDesc.get) {
                Object.defineProperty(xhrProto, "status", {
                  get: function() {
                    var status = statusDesc.get.call(this);
                    try {
                      if (status === 0
                        && this.__wxLocalFileRequest
                        && this.readyState === XMLHttpRequest.DONE) {
                        return 200;
                      }
                    } catch (e) {}
                    return status;
                  },
                  configurable: true
                });
              }
            }

            var origFetch = window.fetch;
            if (typeof origFetch === "function") {
              window.fetch = function(input, init) {
                var url = resolveURL(input);
                if (isLocalNonHTTPURL(url)) {
                  return new Promise(function(resolve, reject) {
                    try {
                      var xhr = new XMLHttpRequest();
                      xhr.open("GET", String(url), true);
                      xhr.responseType = "arraybuffer";
                      xhr.onload = function() {
                        if (xhr.status === 200 || xhr.status === 0) {
                          var headers = new Headers();
                          try {
                            var contentType = xhr.getResponseHeader("Content-Type");
                            if (contentType) headers.set("Content-Type", contentType);
                            var contentLength = xhr.getResponseHeader("Content-Length");
                            if (contentLength) headers.set("Content-Length", contentLength);
                          } catch (e) {}
                          var body = xhr.response || new ArrayBuffer(0);
                          if (!headers.has("Content-Type")) {
                            headers.set("Content-Type", "application/octet-stream");
                          }
                          if (!headers.has("Content-Length") && body && typeof body.byteLength === "number") {
                            headers.set("Content-Length", String(body.byteLength));
                          }
                          resolve(new Response(body, {
                            status: 200,
                            statusText: "OK",
                            headers: headers
                          }));
                        } else {
                          reject(new Error("HTTP " + xhr.status));
                        }
                      };
                      xhr.onerror = function() { reject(new Error("network error")); };
                      xhr.onabort = function() { reject(new Error("aborted")); };
                      xhr.send();
                    } catch (e) {
                      reject(e);
                    }
                  });
                }
                return origFetch.call(this, input, init);
              };
            }
          } catch (e) {}
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false
    )

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        config.websiteDataStore = .nonPersistent()

        // 注入 WE API Shim 和本地文件兼容脚本
        let ucc = WKUserContentController()
        ucc.addUserScript(Self.wallpaperEngineWebAPIShim)
        ucc.addUserScript(Self.localFileCompatScript)
        config.userContentController = ucc

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")

        // 找到 Web 壁纸入口文件
        if let entryURL = resolveWebEntryURL(from: url) {
            if #available(macOS 11.0, *) {
                // 允许访问工程目录及 Steam Workshop 同级依赖资源。
                // 某些 Web 壁纸的 HTML 会通过 ../ 引用外层资源，预览也要与 daemon
                // 的 readAccess 范围保持一致。
                let allowDir = previewReadAccessURL(for: entryURL)
                webView.loadFileURL(entryURL, allowingReadAccessTo: allowDir)
            } else {
                webView.load(URLRequest(url: entryURL))
            }
        } else {
            // 兜底：直接加载 URL
            webView.load(URLRequest(url: url))
        }

        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.stopLoading()
        nsView.navigationDelegate = nil
        nsView.configuration.userContentController.removeAllUserScripts()
        nsView.loadHTMLString("", baseURL: nil)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onLoaded: onLoaded, contentDir: contentDir)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        var onLoaded: (() -> Void)?
        let contentDir: URL

        init(onLoaded: (() -> Void)?, contentDir: URL) {
            self.onLoaded = onLoaded
            self.contentDir = contentDir
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            print("[WebWallpaperPreviewView] Loaded: \(webView.url?.absoluteString ?? "unknown")")
            runWebWallpaperBootstrap(webView: webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            print("[WebWallpaperPreviewView] Failed: \(error.localizedDescription)")
            onLoaded?()
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            print("[WebWallpaperPreviewView] Provisional failed: \(error.localizedDescription)")
            onLoaded?()
        }

        /// 对齐 Wallpaper Engine：注入 project 属性 + 修正缺失背景图与全屏布局
        private func runWebWallpaperBootstrap(webView: WKWebView) {
            let projectURL = contentDir.appendingPathComponent("project.json")
            var propsBlock = ""
            if let data = try? Data(contentsOf: projectURL),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let general = json["general"] as? [String: Any],
               let props = general["properties"] as? [String: Any],
               !props.isEmpty,
               let propsData = try? JSONSerialization.data(withJSONObject: props, options: []),
               let b64 = String(data: propsData.base64EncodedData(), encoding: .utf8) {
                propsBlock = """
                try {
                  var props = JSON.parse(atob("\(b64)"));
                  if (window.wallpaperPropertyListener && typeof window.wallpaperPropertyListener.applyUserProperties === 'function') {
                    window.wallpaperPropertyListener.applyUserProperties(props);
                  }
                } catch(e) {}
                """
            }
            let generalPropsBlock = """
            try {
              if (window.wallpaperPropertyListener && typeof window.wallpaperPropertyListener.applyGeneralProperties === 'function') {
                window.wallpaperPropertyListener.applyGeneralProperties({ fps: { value: 30, type: 'slider' } });
              }
            } catch(eGP) {}
            """
            let layoutBlock = """
            try {
              document.documentElement.style.cssText = 'width:100%;height:100%;margin:0;padding:0;background:transparent;overflow:hidden;';
              document.body.style.setProperty('background-image', 'none', 'important');
              document.body.style.setProperty('width', '100%');
              document.body.style.setProperty('height', '100%');
              document.body.style.setProperty('margin', '0');
              document.body.style.setProperty('overflow', 'hidden');
              var pc = document.getElementById('player-container');
              if (pc) { pc.style.width = '100%'; pc.style.height = '100%'; }
              window.dispatchEvent(new Event('resize'));
            } catch(e2) {}
            """
            let source = "(function(){\(propsBlock)\(generalPropsBlock)\(layoutBlock); return true;})();"
            webView.evaluateJavaScript(source) { [weak self] _, _ in
                self?.onLoaded?()
            }
        }
    }

    /// 解析 Web 壁纸入口文件 URL
    private func resolveWebEntryURL(from url: URL) -> URL? {
        let fm = FileManager.default
        var isDir: ObjCBool = false

        // 如果本身就是 HTML 文件
        if url.pathExtension.lowercased() == "html" || url.pathExtension.lowercased() == "htm" {
            return url
        }

        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }

        // 1. 优先检查 index.html
        let indexHTML = url.appendingPathComponent("index.html")
        if fm.fileExists(atPath: indexHTML.path) {
            return indexHTML
        }

        // 2. 检查 project.json 中的 file 字段
        let projectJSON = url.appendingPathComponent("project.json")
        if let data = try? Data(contentsOf: projectJSON),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let file = json["file"] as? String {
            let fileURL = url.appendingPathComponent(file)
            if fm.fileExists(atPath: fileURL.path),
               fileURL.pathExtension.lowercased() == "html" {
                return fileURL
            }
        }

        // 3. 查找目录下的第一个 HTML 文件
        if let contents = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil),
           let firstHTML = contents.first(where: { ["html", "htm"].contains($0.pathExtension.lowercased()) }) {
            return firstHTML
        }

        return nil
    }

    private func previewReadAccessURL(for entryURL: URL) -> URL {
        let standardized = entryURL.standardizedFileURL
        let components = standardized.pathComponents
        guard let workshopIndex = components.firstIndex(of: "431960"),
              workshopIndex + 1 < components.count else {
            return standardized.deletingLastPathComponent()
        }

        let prefix = components.prefix(through: workshopIndex + 1)
        let workshopRootPath = "/" + prefix.dropFirst().joined(separator: "/")
        var isDirectory: ObjCBool = false
        let workshopRoot = URL(fileURLWithPath: workshopRootPath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: workshopRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return standardized.deletingLastPathComponent()
        }
        return workshopRoot
    }
}

private struct MediaProcessingToast: View {
    let title: String
    let detail: String?
    let progress: Double

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .monospacedDigit()
                .frame(minWidth: 92, alignment: .leading)

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.12))
                    .frame(width: 92, height: 5)

                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.78))
                    .frame(width: 92 * min(1, max(0, progress)), height: 5)
            }

            if let detail {
                Text(detail)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .liquidGlassSurface(.prominent, tint: Color.white.opacity(0.06), in: Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
    }
}

// MARK: - 脉冲动画修饰器
private struct PulseModifier: ViewModifier {
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .opacity(isPulsing ? 1 : 0.5)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                    isPulsing = true
                }
            }
    }
}

extension View {
    func pulseAnimation() -> some View {
        modifier(PulseModifier())
    }
}
