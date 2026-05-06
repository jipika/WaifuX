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

    @ObservedObject private var wallpaperManager = VideoWallpaperManager.shared
    @ObservedObject private var mediaLibrary = MediaLibraryService.shared
    @ObservedObject private var loopService = VideoLoopPreprocessingService.shared
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

    // MARK: - 键盘快捷键与滑动动画
    @State private var keyboardMonitor: Any?
    @State private var slideIncomingOffset: CGFloat = 0
    @State private var slideOutgoingOffset: CGFloat = 0
    @State private var isNavigating = false

    private enum SlideDirection {
        case up, down
    }
    /// 烘焙并应用 MP4 成功后短暂显示在底部状态行（约 4s）
    @State private var sceneBakeStatusFlash: String?
    @State private var sharePickerAnchorView: NSView?

    // 挤压动画配置
    private let squeezeThreshold: CGFloat = 80
    private let maxSqueezeOffset: CGFloat = 120

    // MARK: - 下一张弹窗相关
    @StateObject private var nextItemDataSource = NextItemDataSource()
    @State private var currentItemIndex: Int = 0

    // 计算属性：当前媒体项
    var item: MediaItem { resolvedItem }

    init(item: MediaItem, viewModel: MediaExploreViewModel, contextItems: [MediaItem]? = nil, onClose: @escaping () -> Void) {
        self.initialItem = item
        self.viewModel = viewModel
        self.contextItems = contextItems
        self.onClose = onClose
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
                        .id("media-bg-\(resolvedItem.id)")
                        .transition(
                            AnyTransition.asymmetric(
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
                                    ImagePrefetcher(urls: [imageURL]).start()
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
        .onDisappear {
            isVisible = false
            removeKeyboardMonitor()
        }
    }

    private var heroImageURL: URL {
        resolvedItem.coverImageURL
    }

    private var previewVideoURL: URL? {
        // 优先使用已烘焙的 Scene MP4 作为背景视频
        if let artifact = currentDownloadRecord?.sceneBakeArtifact,
           FileManager.default.fileExists(atPath: artifact.videoPath) {
            return URL(fileURLWithPath: artifact.videoPath)
        }
        // 已下载的视频文件优先使用本地路径，避免从网络加载
        if let localURL = currentDownloadRecord?.localFileURL,
           FileManager.default.fileExists(atPath: localURL.path),
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
                KFMediaCoverImage(
                    url: heroImageURL,
                    animated: resolvedItem.shouldRenderThumbnailAsAnimatedImage,
                    downsampleSize: nil,
                    fadeDuration: 0.3,
                    loadFinished: {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            isMediaLoaded = true
                        }
                    },
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
        Button {
            if isSettingWallpaper {
                AppLogger.warn(.ui, "返回被阻止：设置壁纸进行中",
                    metadata: ["isSettingWallpaper": isSettingWallpaper])
                return
            }
            onClose()
        } label: {
            DetailSheetCircleIconLabel(
                systemName: "chevron.left",
                foreground: isSettingWallpaper ? .white.opacity(0.35) : .white.opacity(0.95),
                fontSize: 15,
                frameSide: 38
            )
            .detailGlassCircleChrome()
            .opacity(isSettingWallpaper ? 0.5 : 1)
        }
        .buttonStyle(.plain)
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
        Text("\(resolvedItem.subtitle) · \(resolvedItem.resolutionLabel)")
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

        // Workshop 源显示丰富的元数据胶囊（订阅、浏览、评分、大小、类型）
        if resolvedItem.sourceName == t("wallpaperEngine") {
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

    private func detailMetaCapsule(label: String, value: String, isLast: Bool = false) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
        }
        .padding(.horizontal, 14)
        .frame(height: 32)
        .detailGlassCapsuleChrome(level: .prominent)
        .padding(.trailing, isLast ? 0 : 8)
    }

    private var metadataCapsules: some View {
        ForEach(Array(metadataItems.enumerated()), id: \.offset) { index, item in
            detailMetaCapsule(
                label: item.label,
                value: item.value,
                isLast: index == metadataItems.count - 1
            )
        }
    }

    private var sceneBakeActionRow: some View {
        VStack(spacing: 8) {
            Text(t("sceneBake.tierHint"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)

            Button {
                runSceneOfflineBake()
            } label: {
                HStack(spacing: 8) {
                    if isBakingScene {
                        CustomProgressView(tint: .white)
                            .scaleEffect(0.75)
                    } else {
                        Image(systemName: "film.stack")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    Text(t("sceneBake.button"))
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(.white.opacity(0.95))
                .padding(.horizontal, 20)
                .frame(height: 40)
                .contentShape(Capsule())
                .detailGlassCapsuleChrome(level: .prominent)
            }
            .buttonStyle(.plain)
            .disabled(isBakingScene)

            if let art = currentDownloadRecord?.sceneBakeArtifact {
                Text("\(t("sceneBake.cached")) · \(URL(fileURLWithPath: art.videoPath).lastPathComponent)")
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

    private func runSceneOfflineBake() {
        guard let record = currentDownloadRecord else { return }
        if isBakingScene { return }
        guard SystemMemoryPressure.hasRoomForSceneOfflineBake() else {
            errorMessage = t("sceneBake.error.insufficientMemory.bake")
            showError = true
            return
        }
        isBakingScene = true
        errorMessage = ""
        Task {
            do {
                let artifact = try await SceneOfflineBakeService.bake(record: record)
                let videoURL = URL(fileURLWithPath: artifact.videoPath)
                await MainActor.run {
                    isBakingScene = false
                    scheduleSceneBakeSuccessFlash()
                    applyWorkshopVideoWallpaper(videoURL: videoURL, preferPosterFrameFromVideo: true)
                }
            } catch {
                await MainActor.run {
                    isBakingScene = false
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
                    if isSettingWallpaper || isBakingScene {
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
            .disabled(isSettingWallpaper || isBakingScene)

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
                    wallpaperManager.setMuted(newMuted)
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

                if isAlreadyDownloaded {
                    Button {
                        shareDownloadedMediaFile()
                    } label: {
                        DetailSheetCircleIconLabel(systemName: "square.and.arrow.up")
                            .detailGlassCircleChrome()
                    }
                    .buttonStyle(.plain)
                    .help(t("shareLocalFile"))
                    .background {
                        SharePickerAnchorReader { sharePickerAnchorView = $0 }
                    }
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

    private func detailInfoBubble(width: CGFloat) -> some View {
        DetailGlassPopoverCard(width: width, maxHeight: 460, variant: .dark) {
            VStack(alignment: .leading, spacing: 8) {
                Text(mediaTitle)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.96))
                    .lineLimit(2)

                Text("\(resolvedItem.subtitle) · \(resolvedItem.resolutionLabel)")
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
               || resolvedItem.authorName != nil || resolvedItem.fileSize != nil
               || resolvedItem.createdAt != nil || resolvedItem.updatedAt != nil {
                dividerLine.opacity(0.7)

                infoSection(title: t("wallpaperEngine")) {
                    if let author = resolvedItem.authorName {
                        compactFact(label: t("author"), value: author)
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

    private func compactFact(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
                .frame(width: 72, alignment: .leading)

            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
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
            return t("applyingWallpaper")
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

    private func loadDetailIfNeeded() async {
        let detail = await viewModel.ensureDetail(for: initialItem)
        resolvedItem = itemWithLocalWorkshopVideo(detail)
        viewModel.recordViewed(resolvedItem)
        // 来源数据已加载并排序完成
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
            case 53: // ESC：优先关闭预览弹窗，否则关闭详情页
                if PreviewWindowManager.shared.isPresented {
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

    private func loadDetailIfNeededFor(_ item: MediaItem) async {
        let detail = await viewModel.ensureDetail(for: item)
        resolvedItem = itemWithLocalWorkshopVideo(detail)
        viewModel.recordViewed(resolvedItem)
        // 来源数据已加载并排序完成
        withAnimation(.easeInOut(duration: 0.3)) {
            isSourcesReady = true
        }
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

    private static func truncateErrorMessage(_ message: String, maxLength: Int = 600) -> String {
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
            errorMessage = t("downloadFirstToLocal")
            showError = true
            return
        }

        // 检测多显示器
        let screens = NSScreen.screens
        if screens.count > 1 {
            DisplaySelectorManager.shared.showSelector(
                title: t("setWallpaper"),
                message: t("multiDisplayDetected")
            ) { [self] selectedScreen in
                isSettingWallpaper = true
                errorMessage = ""
                Task {
                    do {
                        try await viewModel.applyDynamicWallpaper(resolvedItem, muted: isMuted, targetScreen: selectedScreen)
                        WallpaperSchedulerService.shared.notifyManualWallpaperChange(screenID: selectedScreen?.wallpaperScreenIdentifier)
                    } catch {
                        await MainActor.run {
                            errorMessage = Self.truncateErrorMessage(error.localizedDescription)
                            showError = true
                            isSettingWallpaper = false
                        }
                    }
                    await MainActor.run {
                        isSettingWallpaper = false
                    }
                }
            }
        } else {
            isSettingWallpaper = true
            errorMessage = ""
            Task {
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
            applySceneWallpaperPreferringBake(sceneContentRoot: contentRoot, cliPath: localURL.path)
        case .image:
            applyWorkshopImageWallpaper(imageURL: localURL)
        case .video:
            // localURL 本身是视频文件的情况已在开头拦截；
            // 这里处理目录型 video workshop（background/file 指向子目录中的视频）
            if let videoURL = findVideoFile(in: contentRoot) {
                applyWorkshopVideoWallpaper(videoURL: videoURL, preferPosterFrameFromVideo: true)
            } else {
                applyWorkshopRendererWallpaper(path: localURL.path, posterURL: preferredWorkshopPosterForVideo)
            }
        default:
            applyWorkshopRendererWallpaper(path: localURL.path, posterURL: preferredWorkshopPosterForVideo)
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
        if let artifact = currentDownloadRecord?.sceneBakeArtifact,
           FileManager.default.fileExists(atPath: artifact.videoPath) {
            targetURL = URL(fileURLWithPath: artifact.videoPath)
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
        PreviewWindowManager.shared.openPreview(url: url, isMuted: isMuted, aspectRatio: aspectRatio, isWeb: isWebPreview, posterURL: posterForPreview)
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

    /// Scene：优先已烘焙的组合 Web 目录（video + overlay）→ 无则现场烘焙 → 失败再回退 CLI 实时渲染
    private func applySceneWallpaperPreferringBake(sceneContentRoot: URL, cliPath: String) {
        let itemID = resolvedItem.id
        let fm = FileManager.default

        // 1. 已有烘焙产物：优先使用 .web 组合目录（视频背景 + Web overlay）
        if let record = currentDownloadRecord,
           let art = record.sceneBakeArtifact,
           art.analysisId == record.sceneBakeEligibility?.analysisId {
            let webDirPath = art.videoPath.replacingOccurrences(of: ".mp4", with: ".web")
            if fm.fileExists(atPath: webDirPath) {
                applyWorkshopWebWallpaper(webDirPath: webDirPath, posterURL: preferredWorkshopPosterForVideo)
                return
            }
            // _fallback_：无 .web 目录但视频存在，直接播放视频
            if fm.fileExists(atPath: art.videoPath) {
                applyWorkshopVideoWallpaper(
                    videoURL: URL(fileURLWithPath: art.videoPath),
                    preferPosterFrameFromVideo: true
                )
                return
            }
        }

        if isBakingScene { return }
        isBakingScene = true
        Task {
            do {
                let snapshotRecord = await MainActor.run {
                    mediaLibrary.downloadedItems.first { $0.item.id == itemID }
                }
                let needsFreshAnalyze: Bool = {
                    guard let existing = snapshotRecord?.sceneBakeEligibility,
                          existing.contentRootPath == sceneContentRoot.path else { return true }
                    return false
                }()
                if needsFreshAnalyze, !SystemMemoryPressure.hasRoomForSceneEligibilityAnalysis() {
                    await MainActor.run {
                        isBakingScene = false
                        errorMessage = t("sceneBake.error.insufficientMemory.analysis")
                        showError = true
                        applyWorkshopRendererWallpaper(path: cliPath, posterURL: preferredWorkshopPosterForVideo)
                    }
                    return
                }

                let eligibility: SceneBakeEligibilitySnapshot
                if let existing = snapshotRecord?.sceneBakeEligibility,
                   existing.contentRootPath == sceneContentRoot.path {
                    eligibility = existing
                } else {
                    eligibility = try await Task.detached(priority: .userInitiated) {
                        try SceneBakeEligibilityAnalyzer.analyze(contentRoot: sceneContentRoot)
                    }.value
                }

                await MainActor.run {
                    MediaLibraryService.shared.attachSceneBakeEligibility(
                        itemID: itemID,
                        snapshot: eligibility,
                        triggerAutoBake: false
                    )
                }

                if !SystemMemoryPressure.hasRoomForSceneOfflineBake() {
                    await MainActor.run {
                        isBakingScene = false
                        errorMessage = t("sceneBake.error.insufficientMemory.bake")
                        showError = true
                        applyWorkshopRendererWallpaper(path: cliPath, posterURL: preferredWorkshopPosterForVideo)
                    }
                    return
                }

                let persistID = await MainActor.run {
                    mediaLibrary.downloadedItems.first { $0.item.id == itemID && $0.isActive }?.id
                }
                let cacheKey =
                    persistID ?? SceneOfflineBakeService.stableOrphanCacheItemID(contentRootPath: sceneContentRoot.path)

                let artifact = try await SceneOfflineBakeService.bake(
                    eligibility: eligibility,
                    contentRoot: sceneContentRoot,
                    cacheItemID: cacheKey,
                    persistArtifactToItemID: persistID
                )
                let webDirPath = artifact.videoPath.replacingOccurrences(of: ".mp4", with: ".web")
                await MainActor.run {
                    isBakingScene = false
                    scheduleSceneBakeSuccessFlash()
                    if fm.fileExists(atPath: webDirPath) {
                        applyWorkshopWebWallpaper(webDirPath: webDirPath, posterURL: preferredWorkshopPosterForVideo)
                    } else {
                        applyWorkshopVideoWallpaper(videoURL: URL(fileURLWithPath: artifact.videoPath), preferPosterFrameFromVideo: true)
                    }
                }
            } catch {
                await MainActor.run {
                    isBakingScene = false
                    if let bakeErr = error as? SceneOfflineBakeError, case .insufficientMemory = bakeErr {
                        errorMessage = t("sceneBake.error.insufficientMemory.bake")
                        showError = true
                        applyWorkshopRendererWallpaper(path: cliPath, posterURL: preferredWorkshopPosterForVideo)
                    } else {
                        let detail = Self.truncateErrorMessage(error.localizedDescription)
                        errorMessage = detail + "\n\n" + t("sceneBake.error.afterBakeFailureHint")
                        showError = true
                        applyWorkshopRendererWallpaper(path: cliPath, posterURL: preferredWorkshopPosterForVideo)
                        print("[SceneWallpaper] 离线烘焙失败，已回退实时渲染: \(error.localizedDescription)")
                    }
                }
            }
        }
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
            isAnimatedImage: item.isAnimatedImage
        )
    }

    private func scheduleSceneBakeSuccessFlash() {
        sceneBakeStatusFlash = t("sceneBake.success")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            sceneBakeStatusFlash = nil
        }
    }

    /// 直接应用 Workshop / 烘焙 MP4 视频壁纸（须在主线程调用；内部 `Task` 使用 `@MainActor` 以匹配 `VideoWallpaperManager`）
    /// - Parameter preferPosterFrameFromVideo: 为 true 时从该 MP4 抽一帧作静态桌面/锁屏（与 Workshop 预览图逻辑一致，失败则回退 `preferredWorkshopPosterForVideo`）。
    /// - Parameter onApplyFinished: 成功应用到桌面后回调（用于离线烘焙完成后的文案提示）。
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
                isSettingWallpaper = true
                Task { @MainActor in
                    let posterFromVideo: URL? = if preferPosterFrameFromVideo {
                        await VideoThumbnailCache.shared.posterJPEGFileURL(forLocalVideo: videoURL)
                    } else {
                        nil
                    }
                    let posterURL = posterFromVideo ?? preferredWorkshopPosterForVideo
                    do {
                        try wallpaperManager.applyVideoWallpaper(
                            from: videoURL,
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
            isSettingWallpaper = true
            Task { @MainActor in
                let posterFromVideo: URL? = if preferPosterFrameFromVideo {
                    await VideoThumbnailCache.shared.posterJPEGFileURL(forLocalVideo: videoURL)
                } else {
                    nil
                }
                let posterURL = posterFromVideo ?? preferredWorkshopPosterForVideo
                do {
                    try wallpaperManager.applyVideoWallpaper(
                        from: videoURL,
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
        applyWorkshopRendererWallpaper(path: webDirPath, posterURL: posterURL)
    }

    private func applyWorkshopRendererWallpaper(path: String, posterURL: URL?) {
        let screens = NSScreen.screens
        if screens.count > 1 {
            DisplaySelectorManager.shared.showSelector(
                title: t("setWallpaper"),
                message: t("multiDisplayDetected")
            ) { [self] selectedScreen in
                isSettingWallpaper = true
                Task { @MainActor in
                    do {
                        try WallpaperEngineXBridge.shared.setWallpaper(
                            path: path,
                            posterURL: posterURL,
                            targetScreens: selectedScreen.map { [$0] }
                        )
                        WallpaperSchedulerService.shared.notifyManualWallpaperChange(screenID: selectedScreen?.wallpaperScreenIdentifier)
                    } catch {
                        errorMessage = Self.truncateErrorMessage(error.localizedDescription)
                        showError = true
                    }
                    isSettingWallpaper = false
                }
            }
        } else {
            isSettingWallpaper = true
            Task { @MainActor in
                do {
                    try WallpaperEngineXBridge.shared.setWallpaper(
                        path: path,
                        posterURL: posterURL,
                        targetScreens: nil
                    )
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

    /// 应用 Workshop 静态图片壁纸：无 type/file、有 background 指向图片的资源，不走 CLI，直接设静态桌面。
    private func applyWorkshopImageWallpaper(imageURL: URL) {
        guard FileManager.default.fileExists(atPath: imageURL.path) else {
            errorMessage = "图片文件不存在"
            showError = true
            return
        }

        // 停止视频层和 CLI，避免冲突
        VideoWallpaperManager.shared.stopNativeVideoWallpaperOnly()
        WallpaperEngineXBridge.shared.ensureStoppedForNonCLIWallpaper()

        let screens = NSScreen.screens
        if screens.count > 1 {
            DisplaySelectorManager.shared.showSelector(
                title: t("setWallpaper"),
                message: t("multiDisplayDetected")
            ) { [self] selectedScreen in
                isSettingWallpaper = true
                Task { @MainActor in
                    do {
                        let targetScreens = selectedScreen.map { [$0] } ?? screens
                        for screen in targetScreens {
                            try NSWorkspace.shared.setDesktopImageURLForAllSpaces(imageURL, for: screen)
                            DesktopWallpaperSyncManager.shared.registerWallpaperSet(imageURL, for: screen)
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
            isSettingWallpaper = true
            Task { @MainActor in
                do {
                    if let mainScreen = screens.first {
                        try NSWorkspace.shared.setDesktopImageURLForAllSpaces(imageURL, for: mainScreen)
                        DesktopWallpaperSyncManager.shared.registerWallpaperSet(imageURL, for: mainScreen)
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
    @Binding var isMuted: Bool
    let isWeb: Bool
    var posterURL: URL? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var isVideoReady = false
    @State private var isWebLoaded = false

    private var isVideo: Bool {
        ["mp4", "mov", "webm"].contains(url.pathExtension.lowercased())
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if isWeb {
                // Web壁纸：先显示背景图，加载完成后显示web内容
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
                LoopingVideoBackgroundView(
                    url: url,
                    isMuted: isMuted,
                    contentMode: .fit,
                    onReady: { isVideoReady = true }
                )
                .ignoresSafeArea()
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

            // 视频/网页加载进度指示
            if showLoadingIndicator {
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

    private var showLoadingIndicator: Bool {
        if isWeb { return !isWebLoaded }
        if isVideo { return !isVideoReady }
        return false
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
                    xhr.onload = function() {
                      if (xhr.status === 200 || xhr.status === 0) {
                        resolve(new Response(xhr.responseText, { status: 200, statusText: "OK" }));
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
