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
    @ObservedObject private var loopService = VideoLoopPreprocessingService.shared
    @ObservedObject private var displaySelectorManager = DisplaySelectorManager.shared
    @State private var resolvedItem: MediaItem
    @State private var isDownloading = false
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
    @State private var showSteamGuardAlert = false
    @State private var showSessionExpiredAlert = false
    @State private var pendingSteamGuardCode = ""
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

    private enum SlideDirection {
        case up, down
    }
    /// 烘焙成功后短暂显示在底部状态行（约 4s）
    @State private var sceneBakeStatusFlash: String?
    @State private var applyingWallpaperStatusKey = "applyingWallpaper"
    @State private var sharePickerAnchorView: NSView?
    @State private var showCopyLinkToast = false
    @State private var showMoreOptionsPopover = false
    @State private var showDeleteBakeConfirm = false
    @State private var isDeletingBake = false

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

    private var currentDownloadRecord: MediaDownloadRecord? {
        mediaLibrary.downloadedItems.first { $0.item.id == resolvedItem.id }
    }

    private var cachedSceneBakeVideoURL: URL? {
        guard let art = currentDownloadRecord?.sceneBakeArtifact else { return nil }
        let url = URL(fileURLWithPath: art.videoPath)
        guard SceneOfflineBakeService.isUsableBakedVideo(at: url) else { return nil }
        return url
    }

    private var sceneOfflineBakeButtonVisible: Bool {
        guard isAlreadyDownloaded,
              let record = currentDownloadRecord,
              record.sceneBakeEligibility != nil else { return false }
        return true
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
                        .id("media-bg-\(resolvedItem.id)-\(previewVideoURL?.path ?? heroImageURL.path)")
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

                floatingBackButton
                    .padding(.top, topBarTopInset + 18)
                    .padding(.leading, 28)
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
                    Text("链接已复制")
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
            }
        }
        .ignoresSafeArea()
        .alert(t("mediaError"), isPresented: $showError) {
            Button(t("ok"), role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .alert("Steam Guard 验证码", isPresented: $showSteamGuardAlert) {
            TextField("输入验证码", text: $pendingSteamGuardCode)
            Button("取消", role: .cancel) {}
            Button("确认下载") {
                WorkshopSourceManager.shared.updateGuardCode(pendingSteamGuardCode)
                downloadWorkshop(guardCode: pendingSteamGuardCode)
            }
        } message: {
            Text("当前账号启用了 Steam Guard，请输入 Authenticator 应用中的验证码以继续下载。")
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
        .alert("删除烘焙产物?", isPresented: $showDeleteBakeConfirm) {
            Button("删除", role: .destructive) {
                Task { await performDeleteSceneBakeKeepingPoster() }
            }
            Button(t("cancel"), role: .cancel) {}
        } message: {
            Text("将删除该壁纸的离线烘焙视频，静态预览图保留。删除后会立即用静态图替换正在显示的锁屏/桌面壁纸。")
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
        .alert("Steam 登录已过期", isPresented: $showSessionExpiredAlert) {
            Button("确定", role: .cancel) {}
        } message: {
            Text("Steam 会话已失效，凭据已自动清除。请前往设置页面重新登录后再试。")
        }
        .navigationBarBackButtonHidden(true)
        .task {
            AppLogger.info(.media, "媒体详情页 onAppear",
                metadata: ["itemId": initialItem.id, "title": initialItem.title])
            isVisible = true
            setupNextItemDataSource()
            setupKeyboardMonitor()
            await loadDetailIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .sceneOfflineBakeProgressDidUpdate)) { notification in
            guard let notifItemID = notification.object as? String,
                  notifItemID == resolvedItem.id else { return }
            if let progress = notification.userInfo?["progress"] as? Double {
                if !isBakingScene {
                    isBakingScene = true
                }
                updateSceneBakeProgress(progress)
                if progress >= 1.0 {
                    isBakingScene = false
                    bakeProgress = 0
                }
            }
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

    private var heroImageURL: URL {
        resolvedItem.coverImageURL
    }

    private var previewVideoURL: URL? {
        // 优先使用已烘焙的 Scene MP4 作为背景视频
        if let cachedSceneBakeVideoURL {
            return cachedSceneBakeVideoURL
        }
        // 已下载的视频文件优先使用本地路径，避免从网络加载
        // 使用 FileExistenceCache 避免主线程 FileManager.fileExists(atPath:)
        if let localURL = currentDownloadRecord?.localFileURL,
           FileExistenceCache.shared.fileExists(atPath: localURL.path),
           ["mp4", "mov", "webm", "m4v"].contains(localURL.pathExtension.lowercased()) {
            return localURL
        }
        return resolvedItem.previewVideoURL
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
            } else {
                let heroLayoutSize = CGSize(width: width, height: viewH)
                let heroDownsampleSize = CGSize(
                    width: min(max(width * 2, 1), 2400),
                    height: min(max(viewH * 2, 1), 2400)
                )
                KFMediaCoverImage(
                    url: heroImageURL,
                    animated: resolvedItem.shouldRenderThumbnailAsAnimatedImage,
                    downsampleSize: heroDownsampleSize,
                    fadeDuration: 0.3,
                    loadFinished: {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            isMediaLoaded = true
                        }
                    },
                    layoutSize: heroLayoutSize,
                    playAnimatedImage: true
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            Spacer()
                .frame(height: max(topBarTopInset + 44, 68))

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
        .padding(.top, topBarTopInset + 18)
        .padding(.trailing, 28)
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
                if let cachedSceneBakeVideoURL {
                    applyWorkshopVideoWallpaper(
                        videoURL: cachedSceneBakeVideoURL,
                        preferPosterFrameFromVideo: true
                    )
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
                            sceneBakeRendererRow(renderer: .legacyCLI)
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
        presentSceneBakeRendererDialog(clearCachedArtifact: true)
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

        // 4. 仅当确实有屏正在用这张烘焙视频，且 poster 可用时，立即用静态图替换
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

    private func runSceneOfflineBake(renderer: SceneBakeRenderer, clearCachedArtifact: Bool) {
        guard let record = currentDownloadRecord else { return }
        if isBakingScene { return }
        guard SystemMemoryPressure.hasRoomForSceneOfflineBake() else {
            errorMessage = t("sceneBake.error.insufficientMemory.bake")
            showError = true
            return
        }
        isBakingScene = true
        bakeProgress = 0
        errorMessage = ""
        let shouldAutoApplyAfterBake = NSScreen.screens.count <= 1
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
                        if shouldAutoApplyAfterBake {
                            applyWorkshopVideoWallpaper(videoURL: videoURL, preferPosterFrameFromVideo: true)
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
                        // 实时渲染模式下，烘焙产物不自动设置到桌面（已由 wallpaper-wgpu 实时渲染）
                        if UserDefaults.standard.bool(forKey: "scene_realtime_rendering_enabled") {
                            if #available(macOS 26.0, *), !VideoWallpaperManager.shared.isLockScreenEnabled {
                                // 动态锁屏关闭：用烘焙产物的静态帧设置桌面 poster（不启动视频播放器）
                                Task {
                                    if let posterURL = await VideoThumbnailCache.shared.lockScreenPosterURL(forLocalVideo: videoURL, fallbackPosterURL: nil) {
                                        let fillOptions: [NSWorkspace.DesktopImageOptionKey: Any] = [
                                            .imageScaling: NSNumber(value: NSImageScaling.scaleProportionallyUpOrDown.rawValue),
                                            .allowClipping: true
                                        ]
                                        for screen in NSScreen.screens {
                                            try? NSWorkspace.shared.setDesktopImageURLForAllSpaces(posterURL, for: screen, options: fillOptions)
                                            DesktopWallpaperSyncManager.shared.registerWallpaperSet(posterURL, for: screen, options: fillOptions)
                                        }
                                        print("[MediaDetailSheet] 实时渲染模式：烘焙完成，已设置桌面 poster")
                                    }
                                }
                                scheduleSceneBakeSuccessFlash()
                            } else {
                                sceneBakeStatusFlash = t("sceneBake.cached")
                                print("[MediaDetailSheet] 实时渲染模式：烘焙完成，产物已缓存用于锁屏推送")
                            }
                        } else {
                            scheduleSceneBakeSuccessFlash()
                            applyWorkshopVideoWallpaper(videoURL: videoURL, preferPosterFrameFromVideo: true)
                        }
                    } else {
                        sceneBakeStatusFlash = t("sceneBake.cached")
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

            // 循环视频预处理提示（已临时关闭自动预处理，待后续增加手动开关后恢复）
            // if loopService.isProcessing {
            //     HStack(spacing: 6) {
            //         CustomProgressView(tint: .white.opacity(0.7))
            //             .scaleEffect(0.6)
            //         Text(t("loopProcessing"))
            //             .font(.system(size: 11))
            //             .foregroundStyle(.white.opacity(0.6))
            //     }
            //     .padding(.top, 4)
            // }

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
                    if !isAlreadyDownloaded && !isDownloading {
                        downloadMedia()
                    }
                } label: {
                    ZStack {
                        if isDownloading {
                            CustomProgressView(tint: .white)
                                .scaleEffect(0.7)
                        }
                        DetailSheetCircleIconLabel(systemName: isAlreadyDownloaded ? "checkmark" : "arrow.down")
                            .opacity(isDownloading ? 0 : 1)
                    }
                    .frame(width: 42, height: 42)
                    .contentShape(Circle())
                    .detailGlassCircleChrome()
                }
                .buttonStyle(.plain)
                .disabled(isDownloading || isAlreadyDownloaded)

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
                .background(
                    Rectangle()
                        .fill(Color.white.opacity(0.15))
                        .frame(height: 1),
                    alignment: .bottom
                )

                Button {
                    showMoreOptionsPopover = false
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(resolvedItem.pageURL.absoluteString, forType: .string)
                    showCopyLinkToast = true
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        showCopyLinkToast = false
                    }
                } label: {
                    HStack {
                        Image(systemName: "link")
                        Text("复制链接")
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .opacity(hasValidSteamPageURL ? 1 : 0.4)
                }
                .buttonStyle(.plain)
                .disabled(!hasValidSteamPageURL)
            } else {
                Button {
                    showMoreOptionsPopover = false
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(resolvedItem.pageURL.absoluteString, forType: .string)
                    showCopyLinkToast = true
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        showCopyLinkToast = false
                    }
                } label: {
                    HStack {
                        Image(systemName: "link")
                        Text("复制链接")
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .opacity(hasValidSteamPageURL ? 1 : 0.4)
                }
                .buttonStyle(.plain)
                .disabled(!hasValidSteamPageURL)
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
        }
        .frame(width: 192)
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
        if isDownloading {
            return t("downloadingMedia")
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
        let detail = await viewModel.ensureDetail(for: initialItem)
        let merged = mediaItemByMergingAuthorMetadata(detail, fallback: initialItem)
        var item = itemWithLocalWorkshopVideo(merged)
        // 修复历史脏数据：早期导入未读 project.json 的 workshopid，可能把本地 hash/UUID
        // 伪造成了打不开的 Steam 链接。这里从本地 project.json 重新提取真实 ID 并修正 pageURL。
        item = itemWithCorrectedWorkshopPageURL(item)
        resolvedItem = item
        viewModel.recordViewed(resolvedItem)

        // 如果已下载但尚未分析烘焙资格，尝试重新分析（修复后重试之前失败的分析）
        if let record = currentDownloadRecord, record.sceneBakeEligibility == nil,
           let localURL = findLocalWorkshopFile(for: resolvedItem) {
            let contentRoot = sceneEngineContentRoot(for: localURL)
            if FileManager.default.fileExists(atPath: contentRoot.appendingPathComponent("project.json").path) {
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

        withAnimation(.easeInOut(duration: 0.3)) {
            isSourcesReady = true
        }
    }

    // MARK: - 下一张弹窗相关方法

    private func setupNextItemDataSource() {
        let items = navigationItems
        // 找到当前媒体项在列表中的索引
        if let index = items.firstIndex(where: { $0.id == initialItem.id }) {
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
        // iOS 丝滑切换：交叉淡入淡出 + 微位移
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82, blendDuration: 0)) {
            // 更新当前媒体项
            resolvedItem = newItem

            // 重置状态
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
        let detail = await viewModel.ensureDetail(for: item)
        let updated = itemWithLocalWorkshopVideo(mediaItemByMergingAuthorMetadata(detail, fallback: item))
        resolvedItem = updated
        viewModel.recordViewed(resolvedItem)
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
        // 本地文件无需下载
        if isLocalFile {
            AppLogger.debug(.download, "跳过下载：本地媒体", metadata: ["id": resolvedItem.id])
            return
        }

        // Workshop 下载
        if resolvedItem.id.hasPrefix("workshop_") {
            downloadWorkshop()
            return
        }

        AppLogger.info(.download, "开始下载媒体", metadata:
            ["id": resolvedItem.id, "title": resolvedItem.title,
             "选项数": resolvedItem.downloadOptions.count])
        isDownloading = true
        errorMessage = ""
        let start = Date()
        Task {
            do {
                // 默认选择最高画质（与设为壁纸逻辑一致）
                let targetOption = resolvedItem.downloadOptions.max { lhs, rhs in
                    if lhs.qualityRank == rhs.qualityRank {
                        return lhs.fileSizeMegabytes < rhs.fileSizeMegabytes
                    }
                    return lhs.qualityRank < rhs.qualityRank
                }
                if let targetOption {
                    _ = try await viewModel.downloadMedia(resolvedItem, option: targetOption)
                    AppLogger.info(.download, "媒体下载成功", metadata:
                        ["id": resolvedItem.id, "耗时(s)": String(format: "%.2f", Date().timeIntervalSince(start)),
                         "选中选项": targetOption.label])
                } else {
                    throw NetworkError.invalidResponse
                }
            } catch {
                await MainActor.run {
                    errorMessage = Self.truncateErrorMessage(error.localizedDescription)
                    showError = true
                }
                AppLogger.error(.download, "媒体下载失败", metadata:
                    ["id": resolvedItem.id, "error": error.localizedDescription,
                     "耗时(s)": String(format: "%.2f", Date().timeIntervalSince(start))])
            }
            isDownloading = false
        }
    }

    private func downloadWorkshop(guardCode: String? = nil) {
        AppLogger.info(.download, "开始下载 Workshop 内容", metadata:
            ["id": resolvedItem.id, "title": resolvedItem.title, "guardCode": guardCode != nil ? "provided" : "nil"])
        isDownloading = true
        errorMessage = ""
        let start = Date()
        Task { @MainActor in
            do {
                try await viewModel.downloadWorkshopWallpaper(resolvedItem, guardCode: guardCode)
                isDownloading = false
                AppLogger.info(.download, "Workshop 下载成功", metadata:
                    ["id": resolvedItem.id, "耗时(s)": String(format: "%.2f", Date().timeIntervalSince(start))])
            } catch let error as WorkshopError {
                switch error {
                case .guardCodeRequired:
                    isDownloading = false
                    pendingSteamGuardCode = ""
                    showSteamGuardAlert = true
                case .confirmationRequired(let msg):
                    isDownloading = false
                    errorMessage = msg
                    showError = true
                case .sessionExpired:
                    isDownloading = false
                    showSessionExpiredAlert = true
                    AppLogger.error(.download, "Workshop 会话过期，已清除凭据", metadata:
                        ["id": resolvedItem.id])
                default:
                    errorMessage = Self.truncateErrorMessage(error.localizedDescription)
                    showError = true
                    isDownloading = false
                    AppLogger.error(.download, "Workshop 下载失败", metadata:
                        ["id": resolvedItem.id, "error": error.localizedDescription,
                         "耗时(s)": String(format: "%.2f", Date().timeIntervalSince(start))])
                }
            } catch {
                errorMessage = Self.truncateErrorMessage(error.localizedDescription)
                showError = true
                isDownloading = false
                AppLogger.error(.download, "Workshop 下载失败", metadata:
                    ["id": resolvedItem.id, "error": error.localizedDescription,
                     "耗时(s)": String(format: "%.2f", Date().timeIntervalSince(start))])
            }
        }
    }

    private static func truncateErrorMessage(_ message: String, maxLength: Int = 2_000) -> String {
        if message.count <= maxLength { return message }
        let endIndex = message.index(message.startIndex, offsetBy: maxLength)
        return String(message[..<endIndex]) + "\n\n[日志已截断，完整错误请查看控制台]"
    }

    private func setAsDesktopWallpaper() {
        // Wallpaper Engine 类内容：Workshop 与本地入库（同一套路径解析）
        if let localURL = findLocalWorkshopFile(for: resolvedItem) {
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
                            let msg: String
                            switch error {
                            case .guardCodeRequired:
                                msg = "依赖项需要 Steam Guard 验证码，请先在下载列表中单独下载母壁纸后再试"
                            case .credentialsRequired:
                                msg = "下载依赖项需要 Steam 登录凭证"
                            case .steamcmdNotFound:
                                msg = "SteamCMD 未找到，无法下载依赖项"
                            default:
                                msg = "依赖项下载失败: \(error.localizedDescription)"
                            }
                            self.errorMessage = msg
                            self.showError = true
                            self.isSettingWallpaper = false
                        }
                    } catch {
                        await MainActor.run {
                            self.errorMessage = "依赖项下载失败: \(error.localizedDescription)"
                            self.showError = true
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
            isSettingWallpaper = true
            errorMessage = ""
            autoDownloadTask = Task { @MainActor in
                do {
                    AppLogger.info(.download, "自动下载 Workshop 内容后设置壁纸", metadata:
                        ["id": resolvedItem.id, "title": resolvedItem.title])
                    try await viewModel.downloadWorkshopWallpaper(resolvedItem)
                    // 下载被取消则不再继续设置壁纸
                    if Task.isCancelled { return }
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
                    isSettingWallpaper = false
                } catch let error as WorkshopError {
                    isSettingWallpaper = false
                    switch error {
                    case .guardCodeRequired:
                        pendingSteamGuardCode = ""
                        showSteamGuardAlert = true
                    case .confirmationRequired(let msg):
                        errorMessage = msg
                        showError = true
                    case .sessionExpired:
                        showSessionExpiredAlert = true
                    default:
                        errorMessage = Self.truncateErrorMessage(error.localizedDescription)
                        showError = true
                    }
                } catch {
                    isSettingWallpaper = false
                    errorMessage = Self.truncateErrorMessage(error.localizedDescription)
                    showError = true
                }
            }
            return
        }

        // 检测多显示器
        let screens = NSScreen.screens
        if screens.count > 1 {
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
            guardCode: nil,
            progressHandler: { progress in
                print("[DependencyDownload] \(dependencyID) progress: \(String(format: "%.1f", progress * 100))%")
            }
        )
        print("[DependencyDownload] \(dependencyID) completed at \(localURL.path)")
    }

    /// 从本地 URL 设置 Workshop 壁纸（提取原 setAsDesktopWallpaper 中的设置逻辑）
    private func applyWorkshopWallpaperFromLocalURL(_ localURL: URL) {
        let ext = localURL.pathExtension.lowercased()
        let isVideoFile = ["mp4", "mov", "webm"].contains(ext)
        let isImageFile = ["jpg", "jpeg", "png", "bmp", "gif", "webp"].contains(ext)
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: localURL.path, isDirectory: &isDirectory)

        if isVideoFile && !isDirectory.boolValue {
            print("[MediaDetailSheet] WE video file, using VideoWallpaperManager: \(localURL.path)")
            applyWorkshopVideoWallpaper(videoURL: localURL, preferPosterFrameFromVideo: true)
            return
        }

        // pickWorkshopPlayableFile 已识别为 .image 并返回了图片文件路径 → 直接处理，不走 sceneEngineContentRoot
        if isImageFile && !isDirectory.boolValue {
            applyWorkshopImageWallpaper(imageURL: localURL)
            return
        }

        let contentRoot = sceneEngineContentRoot(for: localURL)

        // Preset 类型预处理：如果 project.json 含 preset 字段，生成 HTML 轮播页面
        ensurePresetHTMLGenerated(at: contentRoot)

        let contentType = determineWorkshopContentType(at: contentRoot)
        if case .unsupported(let detectedType) = contentType {
            errorMessage = "检测到该文件类型为 \(detectedType.capitalized)，暂不支持设置此类型壁纸"
            showError = true
            return
        }

        switch contentType {
        case .scene:
            if UserDefaults.standard.bool(forKey: "scene_realtime_rendering_enabled") {
                // 实时渲染模式：直接用 wallpaper-wgpu 渲染桌面，后台烘焙推锁屏
                applyWorkshopRendererWallpaper(
                    path: contentRoot.path,
                    posterURL: preferredWorkshopPosterForVideo,
                    statusKey: "applyingWallpaper.realtime"
                )
            } else {
                // 非实时渲染模式：走烘焙产物
                applySceneWallpaperPreferringBake(sceneContentRoot: contentRoot, cliPath: localURL.path)
            }
        case .web:
            applyWorkshopWebWallpaper(webDirPath: localURL.path, posterURL: preferredWorkshopPosterForVideo)
        case .image:
            applyWorkshopImageWallpaper(imageURL: localURL)
        case .video:
            // localURL 本身是视频文件的情况已在开头拦截；
            // 这里处理目录型 video workshop（background/file 指向子目录中的视频）
            if let videoURL = findVideoFile(in: contentRoot) {
                applyWorkshopVideoWallpaper(videoURL: videoURL, preferPosterFrameFromVideo: true)
            } else {
                applyWorkshopRendererWallpaper(
                    path: localURL.path,
                    posterURL: preferredWorkshopPosterForVideo,
                    statusKey: "applyingWallpaper.realtime"
                )
            }
        default:
            applyWorkshopRendererWallpaper(
                path: localURL.path,
                posterURL: preferredWorkshopPosterForVideo,
                statusKey: "applyingWallpaper.realtime"
            )
        }
    }

    /// Scene 壁纸设置：优先使用烘焙产物，无缓存时自动用 legacyCLI 烘焙后应用
    /// 不再使用 wallpaper-wgpu 实时渲染
    private func applySceneWallpaperPreferringBake(sceneContentRoot: URL, cliPath: String) {
        let itemID = resolvedItem.id
        let fm = FileManager.default

        // 1. 已有烘焙产物 → 直接应用
        if let record = currentDownloadRecord,
           let art = record.sceneBakeArtifact,
           art.analysisId == record.sceneBakeEligibility?.analysisId {
            // 优先使用 .web 组合目录（视频背景 + Web overlay）
            let webDirPath = art.videoPath.replacingOccurrences(of: ".mp4", with: ".web")
            if fm.fileExists(atPath: webDirPath) {
                applyWorkshopWebWallpaper(webDirPath: webDirPath, posterURL: preferredWorkshopPosterForVideo)
                return
            }
            // 回退到纯视频
            if fm.fileExists(atPath: art.videoPath) {
                applyWorkshopVideoWallpaper(
                    videoURL: URL(fileURLWithPath: art.videoPath),
                    preferPosterFrameFromVideo: true
                )
                return
            }
        }

        // 2. 无烘焙产物 → 自动用 legacyCLI 烘焙后应用
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
                   existing.contentRootPath == sceneContentRoot.path {
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

                guard SystemMemoryPressure.hasRoomForSceneOfflineBake() else {
                    await MainActor.run {
                        isBakingScene = false
                        isSettingWallpaper = false
                        errorMessage = t("sceneBake.error.insufficientMemory.bake")
                        showError = true
                    }
                    return
                }

                let persistID = await MainActor.run {
                    mediaLibrary.downloadedItems.first { $0.item.id == itemID && $0.isActive }?.id
                }
                let cacheKey = persistID ?? SceneOfflineBakeService.stableOrphanCacheItemID(contentRootPath: sceneContentRoot.path)

                // 使用 wallpaper-wgpu bake 子命令烘焙
                let artifact = try await SceneOfflineBakeService.bake(
                    eligibility: eligibility,
                    contentRoot: sceneContentRoot,
                    cacheItemID: cacheKey,
                    renderer: .wallpaperWgpu,
                    persistArtifactToItemID: persistID,
                    progress: { [self] progress in
                        Task { @MainActor in
                            updateSceneBakeProgress(progress)
                        }
                    }
                )

                let webDirPath = artifact.videoPath.replacingOccurrences(of: ".mp4", with: ".web")
                await MainActor.run {
                    isBakingScene = false
                    isSettingWallpaper = false
                    scheduleSceneBakeSuccessFlash()
                    if fm.fileExists(atPath: webDirPath) {
                        applyWorkshopWebWallpaper(webDirPath: webDirPath, posterURL: preferredWorkshopPosterForVideo)
                    } else {
                        applyWorkshopVideoWallpaper(
                            videoURL: URL(fileURLWithPath: artifact.videoPath),
                            preferPosterFrameFromVideo: true
                        )
                    }
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

    /// 复制当前壁纸的静态图片到剪贴板
    private func copyStaticImageToPasteboard() {
        Task { @MainActor in
            var imageURL: URL?

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
                print("[MediaDetailSheet] ✅ 已复制静态图片到剪贴板")
            }
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

        // 3. 如果根目录直接有 .mp4/.mov/.webm 文件（这是纯视频 Workshop 的常见情况）
        if let rootVideo = rootContents?.first(where: {
            ["mp4", "mov", "webm"].contains($0.pathExtension.lowercased())
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

        if let localVideoURL = findLocalWorkshopFile(for: item) {
        let videoExts = ["mp4", "mov", "webm"]
            if updatedPreviewVideoURL == nil, videoExts.contains(localVideoURL.pathExtension.lowercased()) {
                updatedPreviewVideoURL = localVideoURL
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

    /// 当前详情项是否有合法 Steam 链接（用于「复制链接」按钮启用/置灰）
    private var hasValidSteamPageURL: Bool {
        hasValidSteamPageURL(resolvedItem)
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

    /// 直接应用 Workshop / 烘焙 MP4 视频壁纸（须在主线程调用；内部 `Task` 使用 `@MainActor` 以匹配 `VideoWallpaperManager`）
    /// - Parameter preferPosterFrameFromVideo: 为 true 时从该 MP4 抽一帧作静态桌面/锁屏（与 Workshop 预览图逻辑一致，失败则回退 `preferredWorkshopPosterForVideo`）。
    private func applyWorkshopVideoWallpaper(
        videoURL: URL,
        preferPosterFrameFromVideo: Bool = true,
        onApplyFinished: (() -> Void)? = nil
    ) {
        let path = videoURL.path
        guard FileManager.default.fileExists(atPath: path) else {
            errorMessage = t("sceneBake.error.outputMissing")
            showError = true
            return
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let sz = attrs[.size] as? NSNumber, sz.int64Value <= 10_000 {
            errorMessage = t("sceneBake.error.outputMissing")
            showError = true
            return
        }
        let screens = NSScreen.screens
        if screens.count > 1 {
            DisplaySelectorManager.shared.showSelector(
                title: t("setWallpaper"),
                message: t("multiDisplayDetected")
            ) { [self] selectedScreen in
                applyingWallpaperStatusKey = "applyingWallpaper.video"
                isSettingWallpaper = true
                Task { @MainActor in
                    let posterFromVideo = await preferredPosterFrame(
                        for: videoURL,
                        preferPosterFrameFromVideo: preferPosterFrameFromVideo
                    )
                    let posterURL = posterFromVideo ?? preferredWorkshopPosterForVideo
                    do {
                        // 高码率/B帧视频自动转码，解决 seek 卡顿根本问题
                        let optimizedURL = await VideoTranscodeService.ensureSeekFriendly(videoURL)
                        try wallpaperManager.applyVideoWallpaper(
                            from: optimizedURL,
                            posterURL: posterURL,
                            muted: isMuted,
                            targetScreens: selectedScreen.map { [$0] }
                        )
                        WallpaperSchedulerService.shared.notifyManualWallpaperChange(screenID: selectedScreen?.wallpaperScreenIdentifier)
                        onApplyFinished?()
                    } catch {
                        errorMessage = error.localizedDescription
                        showError = true
                    }
                    isSettingWallpaper = false
                }
            }
        } else {
            applyingWallpaperStatusKey = "applyingWallpaper.video"
            isSettingWallpaper = true
            Task { @MainActor in
                let posterFromVideo = await preferredPosterFrame(
                    for: videoURL,
                    preferPosterFrameFromVideo: preferPosterFrameFromVideo
                )
                let posterURL = posterFromVideo ?? preferredWorkshopPosterForVideo
                do {
                    // 高码率/B帧视频自动转码，解决 seek 卡顿根本问题
                    let optimizedURL = await VideoTranscodeService.ensureSeekFriendly(videoURL)
                    try wallpaperManager.applyVideoWallpaper(
                        from: optimizedURL,
                        posterURL: posterURL,
                        muted: isMuted
                    )
                    WallpaperSchedulerService.shared.notifyManualWallpaperChange(
                        screenID: NSScreen.screens.first?.wallpaperScreenIdentifier
                    )
                    onApplyFinished?()
                } catch {
                    errorMessage = error.localizedDescription
                    showError = true
                }
                isSettingWallpaper = false
            }
        }
    }

    private func applyWorkshopWebWallpaper(webDirPath: String, posterURL: URL?) {
        applyWorkshopRendererWallpaper(
            path: webDirPath,
            posterURL: posterURL,
            statusKey: "applyingWallpaper.web"
        )
    }

    private func applyWorkshopRendererWallpaper(
        path: String,
        posterURL: URL?,
        statusKey: String = "applyingWallpaper.realtime"
    ) {
        let screens = NSScreen.screens
        print("[MediaDetailSheet] applyWorkshopRendererWallpaper path=\(path) screens=\(screens.count)")

        // 检查二进制是否存在
        if WallpaperEngineXBridge.resolvedCLIExecutableURL() == nil {
            print("[MediaDetailSheet] ❌ wallpaper-wgpu 二进制不存在")
            errorMessage = "wallpaper-wgpu 渲染器未找到"
            showError = true
            return
        }

        // 检查路径是否存在
        if !FileManager.default.fileExists(atPath: path) {
            print("[MediaDetailSheet] ❌ 壁纸路径不存在: \(path)")
            errorMessage = "壁纸文件不存在"
            showError = true
            return
        }

        let runSetWallpaper: (NSScreen?) -> Void = { [self] selectedScreen in
            applyingWallpaperStatusKey = statusKey
            isSettingWallpaper = true
            Task { @MainActor in
                do {
                    let isRealtime = UserDefaults.standard.bool(forKey: "scene_realtime_rendering_enabled")
                    let userProps = isRealtime ? SceneWallpaperPropertiesService.propertiesOverrideJSON(for: path) : nil
                    print("[MediaDetailSheet] 调用 WallpaperEngineXBridge.setWallpaper (realtime=\(isRealtime))...")
                    try await WallpaperEngineXBridge.shared.setWallpaper(
                        path: path,
                        targetScreens: selectedScreen.map { [$0] },
                        userProperties: userProps
                    )
                    print("[MediaDetailSheet] ✅ 壁纸设置成功")
                    WallpaperSchedulerService.shared.notifyManualWallpaperChange(screenID: selectedScreen?.wallpaperScreenIdentifier)

                    // 实时渲染模式下，后台触发烘焙；完成后若动态锁屏开启，则推送到对应锁屏实例。
                    if isRealtime {
                        SceneOfflineBakeService.scheduleRealtimeCompanionBake(
                            path: path,
                            targetScreens: selectedScreen.map { [$0] },
                            reason: "manual-apply"
                        )
                    }
                } catch {
                    print("[MediaDetailSheet] ❌ 设置壁纸失败: \(error.localizedDescription)")
                    errorMessage = Self.truncateErrorMessage(error.localizedDescription)
                    showError = true
                }
                isSettingWallpaper = false
            }
        }

        if screens.count > 1 {
            DisplaySelectorManager.shared.showSelector(
                title: t("setWallpaper"),
                message: t("multiDisplayDetected")
            ) { selectedScreen in
                runSetWallpaper(selectedScreen)
            }
        } else {
            runSetWallpaper(nil)
        }
    }

    /// 应用 Workshop 静态图片壁纸：无 type/file、有 background 指向图片的资源，不走 CLI，直接设静态桌面。
    private func applyWorkshopImageWallpaper(imageURL: URL) {
        guard FileManager.default.fileExists(atPath: imageURL.path) else {
            errorMessage = "图片文件不存在"
            showError = true
            return
        }

        let screens = NSScreen.screens
        if #available(macOS 26.0, *), VideoWallpaperManager.shared.isLockScreenEnabled {
            let applyToDynamicLockScreen: (NSScreen?) -> Void = { selectedScreen in
                applyingWallpaperStatusKey = "applyingWallpaper.static"
                isSettingWallpaper = true
                Task { @MainActor in
                    defer { isSettingWallpaper = false }
                    WallpaperEngineXBridge.shared.ensureStoppedForNonCLIWallpaper(for: selectedScreen)
                    VideoWallpaperManager.shared.stopNativeVideoWallpaperOnly(for: selectedScreen)
                    let targetScreens = selectedScreen.map { [$0] } ?? screens
                    let displayIDs = targetScreens.compactMap { screen -> UInt32? in
                        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
                    }
                    do {
                        try await LockScreenWallpaperService.shared.cacheStaticImageSource(imageURL: imageURL, displayIDs: displayIDs)
                        WallpaperSchedulerService.shared.notifyManualWallpaperChange(screenID: selectedScreen?.wallpaperScreenIdentifier)
                        print("[MediaDetailSheet] 🔒 动态锁屏已启用，已将 Workshop 静态图同步到 WaifuX 实例")
                    } catch {
                        errorMessage = Self.truncateErrorMessage(error.localizedDescription)
                        showError = true
                    }
                }
            }

            if screens.count > 1 {
                DisplaySelectorManager.shared.showSelector(
                    title: t("setWallpaper"),
                    message: t("multiDisplayDetected")
                ) { selectedScreen in
                    applyToDynamicLockScreen(selectedScreen)
                }
            } else {
                applyToDynamicLockScreen(screens.first)
            }
            return
        }

        // macOS 26+：仅当用户未启用动态锁屏时才清空帧源缓存。
        // 使用持久化设置 isLockScreenEnabled 而非 isLockScreenMirroringActive。
        if #available(macOS 26.0, *) {
            if !VideoWallpaperManager.shared.isLockScreenEnabled {
                LockScreenWallpaperService.shared.clearMirroringSourceCache()
            }
        }

        if screens.count > 1 {
            DisplaySelectorManager.shared.showSelector(
                title: t("setWallpaper"),
                message: t("multiDisplayDetected")
            ) { [self] selectedScreen in
                applyingWallpaperStatusKey = "applyingWallpaper.static"
                isSettingWallpaper = true
                Task { @MainActor in
                    do {
                        let targetScreens = selectedScreen.map { [$0] } ?? screens
                        WallpaperEngineXBridge.shared.ensureStoppedForNonCLIWallpaper(for: selectedScreen)
                        VideoWallpaperManager.shared.stopNativeVideoWallpaperOnly(for: selectedScreen)
                        // 系统壁纸同步关闭时走独立静态图 overlay，不写系统壁纸
                        if !VideoWallpaperManager.shared.isSystemWallpaperSyncEnabled {
                            for screen in targetScreens {
                                StaticImageWallpaperOverlayManager.shared.show(imageURL: imageURL, for: screen)
                            }
                        } else {
                            for screen in targetScreens {
                                try NSWorkspace.shared.setDesktopImageURLForAllSpaces(imageURL, for: screen)
                                DesktopWallpaperSyncManager.shared.registerWallpaperSet(imageURL, for: screen)
                            }
                            // 互斥：走系统壁纸时关闭并清除静态图 overlay 持久化状态
                            StaticImageWallpaperOverlayManager.shared.clearState()
                        }
                        WallpaperSchedulerService.shared.notifyManualWallpaperChange(screenID: selectedScreen?.wallpaperScreenIdentifier)
                    } catch {
                        errorMessage = Self.truncateErrorMessage(error.localizedDescription)
                        showError = true
                    }
                    isSettingWallpaper = false
                }
            }
        } else {
            applyingWallpaperStatusKey = "applyingWallpaper.static"
            isSettingWallpaper = true
            Task { @MainActor in
                do {
                    WallpaperEngineXBridge.shared.ensureStoppedForNonCLIWallpaper(for: screens.first)
                    VideoWallpaperManager.shared.stopNativeVideoWallpaperOnly(for: screens.first)
                    if let mainScreen = screens.first {
                        // 系统壁纸同步关闭时走独立静态图 overlay，不写系统壁纸
                        if !VideoWallpaperManager.shared.isSystemWallpaperSyncEnabled {
                            StaticImageWallpaperOverlayManager.shared.show(imageURL: imageURL, for: mainScreen)
                        } else {
                            try NSWorkspace.shared.setDesktopImageURLForAllSpaces(imageURL, for: mainScreen)
                            DesktopWallpaperSyncManager.shared.registerWallpaperSet(imageURL, for: mainScreen)
                            // 互斥：走系统壁纸时关闭并清除静态图 overlay 持久化状态
                            StaticImageWallpaperOverlayManager.shared.clearState()
                        }
                    }
                    WallpaperSchedulerService.shared.notifyManualWallpaperChange(
                        screenID: NSScreen.screens.first?.wallpaperScreenIdentifier
                    )
                } catch {
                    errorMessage = Self.truncateErrorMessage(error.localizedDescription)
                    showError = true
                }
                isSettingWallpaper = false
            }
        }
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
                activeItemID: resolvedItem.id,
                onSelectItem: { selectedItem in
                    navigateToAuthorMedia(selectedItem)
                },
                onDismiss: {
                    dismissAuthorSheet()
                },
                onLoadMore: {
                    self.loadMoreAuthorMedia()
                }
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
                let results = try await viewModel.fetchMediaByAuthor(
                    steamID: steamID,
                    page: 1
                )
                await MainActor.run {
                    if let authorItem = results.first(where: {
                        $0.authorName != nil || $0.authorSteamID != nil || $0.authorAvatarURL != nil
                    }) {
                        resolvedItem = mediaItemByMergingAuthorMetadata(resolvedItem, fallback: authorItem)
                    }
                    // 过滤掉当前正在查看的项
                    authorMediaItems = results.filter { $0.id != resolvedItem.id }
                    hasMoreAuthorItems = results.count >= 30
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

    /// 加载更多作者壁纸（分页）
    private func loadMoreAuthorMedia() {
        guard let steamID = resolvedItem.authorSteamID,
              !isLoadingAuthorItems,
              hasMoreAuthorItems else { return }
        isLoadingAuthorItems = true
        let nextPage = authorItemsPage + 1

        Task {
            do {
                let results = try await viewModel.fetchMediaByAuthor(
                    steamID: steamID,
                    page: nextPage
                )
                await MainActor.run {
                    let newItems = results.filter { $0.id != resolvedItem.id }
                    authorMediaItems.append(contentsOf: newItems)
                    authorItemsPage = nextPage
                    hasMoreAuthorItems = results.count >= 30
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

        // 始终原地替换 resolvedItem，不走 onNavigateToItem push 路径
        // 这样作者面板保持打开，详情页数据无缝切换
        isAuthorPanelFade = true
        isNavigating = true

        if let index = viewModel.items.firstIndex(where: { $0.id == patchedItem.id }) {
            navigateToIndex(index)
        } else {
            reloadMedia(patchedItem)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            self.isNavigating = false
            self.isAuthorPanelFade = false
        }
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
            window.wallpaperRegisterMediaStatusListener = function(cb) {
              if (typeof cb === 'function') {
                try { cb({ enabled: false }); } catch (e) {}
              }
            };
            window.wallpaperRegisterMediaPropertiesListener = function(cb) {};
            window.wallpaperRegisterMediaThumbnailListener = function(cb) {};
            window.wallpaperRegisterMediaPlaybackListener = function(cb) {
              if (typeof cb === 'function') {
                try { cb({ state: window.wallpaperMediaIntegration.playback.STOPPED }); } catch (e) {}
              }
            };
            window.wallpaperRegisterMediaTimelineListener = function(cb) {};
          } catch (e) {}
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false
    )

    /// `file://` 本地文件兼容：修复 Spine 纹理 crossOrigin 及 fetch() 读本地文件失败
    private static let localFileCompatScript = WKUserScript(
        source: """
        (function() {
          try {
            if (location.protocol !== "file:") return;
            var proto = HTMLImageElement.prototype;
            var srcDesc = Object.getOwnPropertyDescriptor(proto, "src");
            if (srcDesc && srcDesc.set) {
              Object.defineProperty(proto, "src", {
                set: function(value) {
                  try {
                    var s = String(value || "");
                    if (s.indexOf("http:") !== 0 && s.indexOf("https:") !== 0 && s.indexOf("data:") !== 0 && s.indexOf("blob:") !== 0) {
                      this.removeAttribute("crossorigin");
                    }
                  } catch (e) {}
                  srcDesc.set.call(this, value);
                },
                get: srcDesc.get,
                configurable: true
              });
            }
            var origFetch = window.fetch;
            if (typeof origFetch === "function") {
              window.fetch = function(input, init) {
                var url = typeof input === "string" ? input : (input && input.url) ? input.url : "";
                if (url && url.indexOf("http:") !== 0 && url.indexOf("https:") !== 0 && url.indexOf("data:") !== 0 && url.indexOf("blob:") !== 0) {
                  return new Promise(function(resolve, reject) {
                    var xhr = new XMLHttpRequest();
                    xhr.open("GET", url, true);
                    xhr.responseType = "arraybuffer";
                    xhr.onload = function() {
                      if (xhr.status === 200 || xhr.status === 0) {
                        var headers = new Headers();
                        try {
                          var contentType = xhr.getResponseHeader("Content-Type");
                          if (contentType) headers.set("Content-Type", contentType);
                        } catch (e) {}
                        resolve(new Response(xhr.response, {
                          status: xhr.status === 0 ? 200 : xhr.status,
                          statusText: xhr.statusText || "OK",
                          headers: headers
                        }));
                      } else {
                        reject(new Error("HTTP " + xhr.status));
                      }
                    };
                    xhr.onerror = function() { reject(new Error("network error")); };
                    xhr.send();
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
                // 允许访问整个壁纸目录及其子目录（资源引用）
                let allowDir = entryURL.deletingLastPathComponent()
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
