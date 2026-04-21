import SwiftUI
import AVKit
import AVFoundation
import AppKit
import Kingfisher

struct MediaDetailSheet: View {
    let initialItem: MediaItem
    @ObservedObject var viewModel: MediaExploreViewModel
    let onClose: () -> Void

    @ObservedObject private var wallpaperManager = VideoWallpaperManager.shared
    @ObservedObject private var mediaLibrary = MediaLibraryService.shared
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
    @State private var showWallpaperEngineInstallAlert = false
    @State private var showSteamGuardAlert = false
    @State private var pendingSteamGuardCode = ""
    @State private var isBakingScene = false
    @State private var sharePickerAnchorView: NSView?

    // 挤压动画配置
    private let squeezeThreshold: CGFloat = 80
    private let maxSqueezeOffset: CGFloat = 120

    // MARK: - 下一张弹窗相关
    @StateObject private var nextItemDataSource = NextItemDataSource()
    @State private var currentItemIndex: Int = 0

    // 计算属性：当前媒体项
    var item: MediaItem { resolvedItem }

    init(item: MediaItem, viewModel: MediaExploreViewModel, onClose: @escaping () -> Void) {
        self.initialItem = item
        self.viewModel = viewModel
        self.onClose = onClose
        _resolvedItem = State(initialValue: item)
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
              let eligibility = record.sceneBakeEligibility,
              eligibility.isEligibleForOfflineBake else { return false }
        return true
    }

    /// 已展示「预渲染循环视频」且英雄区可见时，仅用按钮内进度即可，避免与全屏「正在烘焙…」重复。
    private var sceneBakeUsesInlineProgressOnly: Bool {
        sceneOfflineBakeButtonVisible && !isHeroContentHidden
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
                }
                
                // 媒体加载动画
                if !isMediaLoaded {
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

                if isBakingScene, !sceneBakeUsesInlineProgressOnly {
                    sceneBakeProgressOverlay(width: viewW, height: viewH)
                        .zIndex(250)
                }

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
        .alert(t("wallpaperEngineRequiredTitle"), isPresented: $showWallpaperEngineInstallAlert) {
            Button(t("cancel"), role: .cancel) {}
            Button(t("goToAppStore")) {
                if let url = URL(string: "https://apps.apple.com/cn/app/wallpaper-engine/id1573093741") {
                    NSWorkspace.shared.open(url)
                }
            }
        } message: {
            Text(t("wallpaperEngineRequiredMessage"))
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
        .navigationBarBackButtonHidden(true)
        .task {
            AppLogger.info(.media, "媒体详情页 onAppear",
                metadata: ["itemId": initialItem.id, "title": initialItem.title])
            isVisible = true
            setupNextItemDataSource()
            await loadDetailIfNeeded()
        }
    }

    private var heroImageURL: URL {
        resolvedItem.coverImageURL
    }

    private var previewVideoURL: URL? {
        resolvedItem.previewVideoURL
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

    // MARK: - 顶部返回按钮（下载/设置壁纸中禁用）
    private var floatingBackButton: some View {
        Button(action: {
            if isDownloading || isSettingWallpaper || isBakingScene {
                AppLogger.warn(.ui, "Media 返回被阻止：下载/设置壁纸/烘焙进行中",
                    metadata: ["isDownloading": isDownloading, "isSettingWallpaper": isSettingWallpaper, "isBakingScene": isBakingScene])
                return
            }
            onClose()
        }) {
            DetailSheetCircleIconLabel(
                systemName: "chevron.left",
                foreground: (isDownloading || isSettingWallpaper) ? .white.opacity(0.35) : .white.opacity(0.95),
                fontSize: 15,
                frameSide: 38
            )
            .detailGlassCircleChrome()
            .opacity(isDownloading || isSettingWallpaper ? 0.5 : 1)
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

    private func sceneBakeProgressOverlay(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
            VStack(spacing: 18) {
                CustomProgressView(tint: .white)
                    .scaleEffect(1.35)
                Text(t("sceneBake.progressTitle"))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                Text(t("sceneBake.progressSubtitle"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: min(360, width * 0.85))
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 32)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(Color.white.opacity(0.14), lineWidth: 1)
                    )
            )
        }
        .frame(width: width, height: height)
        .contentShape(Rectangle())
        .allowsHitTesting(true)
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
                    // 烘焙目的即替代 Scene 实时渲染：直接走本机 MP4 壁纸
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

    private var statusText: String {
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
        // 找到当前媒体项在列表中的索引
        let allItems = viewModel.items
        if let index = allItems.firstIndex(where: { $0.id == initialItem.id }) {
            currentItemIndex = index
        }

        // 设置数据源
        nextItemDataSource.setItems(allItems, currentIndex: currentItemIndex)
    }

    private func navigateToNextMedia() {
        guard nextItemDataSource.hasNext else { return }

        // 获取下一个媒体项
        let nextIndex = currentItemIndex + 1
        let allItems = viewModel.items
        guard nextIndex < allItems.count else { return }

        let nextItem = allItems[nextIndex]

        // 更新索引和数据源
        currentItemIndex = nextIndex
        nextItemDataSource.moveToNext()

        // 重新加载媒体
        reloadMedia(nextItem)
    }

    private func navigateToPreviousMedia() {
        guard nextItemDataSource.hasPrevious else { return }

        // 获取上一个媒体项
        let prevIndex = currentItemIndex - 1
        guard prevIndex >= 0 else { return }

        let prevItem = viewModel.items[prevIndex]

        // 更新索引和数据源
        currentItemIndex = prevIndex
        nextItemDataSource.moveToPrevious()

        // 重新加载媒体
        reloadMedia(prevItem)
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
                if case .guardCodeRequired = error {
                    isDownloading = false
                    pendingSteamGuardCode = ""
                    showSteamGuardAlert = true
                } else {
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
            let ext = localURL.pathExtension.lowercased()
            let isVideoFile = ["mp4", "mov", "webm"].contains(ext)
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: localURL.path, isDirectory: &isDirectory)

            if isVideoFile && !isDirectory.boolValue {
                print("[MediaDetailSheet] WE video file, using VideoWallpaperManager: \(localURL.path)")
                applyWorkshopVideoWallpaper(videoURL: localURL, preferPosterFrameFromVideo: true)
                return
            }

            let contentRoot = sceneEngineContentRoot(for: localURL)
            let contentType = determineWorkshopContentType(at: contentRoot)
            if case .unsupported(let detectedType) = contentType {
                errorMessage = "检测到该文件类型为 \(detectedType.capitalized)，暂不支持设置此类型壁纸"
                showError = true
                return
            }

            if !WorkshopService.isWallpaperEngineAppInstalled() {
                showWallpaperEngineInstallAlert = true
                return
            }

            if contentType == .scene {
                applySceneWallpaperPreferringBake(sceneContentRoot: contentRoot, cliPath: localURL.path)
            } else {
                applyWorkshopRendererWallpaper(path: localURL.path, posterURL: preferredWorkshopPosterForVideo)
            }
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
                } catch {
                    errorMessage = error.localizedDescription
                    showError = true
                }
                isSettingWallpaper = false
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

    /// 含 `project.json` 的工程根（目录本身，或单文件的父目录）
    private func sceneEngineContentRoot(for localURL: URL) -> URL {
        var isDir: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: localURL.path, isDirectory: &isDir)
        return isDir.boolValue ? localURL : localURL.deletingLastPathComponent()
    }

    /// Scene：优先已烘焙 MP4 → 无则现场资格分析 + 烘焙 MP4（无媒体库记录也可）→ 不合格或失败再 CLI
    private func applySceneWallpaperPreferringBake(sceneContentRoot: URL, cliPath: String) {
        let itemID = resolvedItem.id
        if let record = currentDownloadRecord,
           let art = record.sceneBakeArtifact,
           art.analysisId == record.sceneBakeEligibility?.analysisId,
           FileManager.default.fileExists(atPath: art.videoPath) {
            applyWorkshopVideoWallpaper(
                videoURL: URL(fileURLWithPath: art.videoPath),
                preferPosterFrameFromVideo: true
            )
            return
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

                guard eligibility.isEligibleForOfflineBake else {
                    await MainActor.run {
                        isBakingScene = false
                        applyWorkshopRendererWallpaper(path: cliPath, posterURL: preferredWorkshopPosterForVideo)
                    }
                    return
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
                let videoURL = URL(fileURLWithPath: artifact.videoPath)
                await MainActor.run {
                    isBakingScene = false
                    applyWorkshopVideoWallpaper(videoURL: videoURL, preferPosterFrameFromVideo: true)
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
                        print("[SceneWallpaper] 离线烘焙/分析失败（未自动切换实时渲染）: \(error.localizedDescription)")
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
        case unsupported(String) // 不支持的类型（如 application、游戏等）
        case unknown
    }

    /// 确定 Workshop 内容类型（通过 project.json 判断）
    private func determineWorkshopContentType(at contentDir: URL) -> WorkshopContentType {
        let projectURL = contentDir.appendingPathComponent("project.json")
        guard let data = try? Data(contentsOf: projectURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let typeString = json["type"] as? String else {
            return .unknown
        }
        let type = typeString.lowercased()
        switch type {
        case "video": return .video
        case "scene": return .scene
        case "web": return .web
        default: return .unsupported(typeString)
        }
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

        // 2. 纯视频类型或有 .mp4 文件的情况 → 返回视频文件
        if contentType == .video {
            // 递归查找视频文件
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

    /// 直接应用 Workshop / 烘焙 MP4 视频壁纸（须在主线程调用；内部 `Task` 使用 `@MainActor` 以匹配 `VideoWallpaperManager`）
    /// - Parameter preferPosterFrameFromVideo: 为 true 时从该 MP4 抽一帧作静态桌面/锁屏（与 Workshop 预览图逻辑一致，失败则回退 `preferredWorkshopPosterForVideo`）。
    private func applyWorkshopVideoWallpaper(videoURL: URL, preferPosterFrameFromVideo: Bool = true) {
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
        // 应用本机 MP4 前始终停 CLI，避免与播放器叠层或桥接状态残留
        WallpaperEngineXBridge.shared.ensureStoppedForNonCLIWallpaper()

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
                } catch {
                    errorMessage = error.localizedDescription
                    showError = true
                }
                isSettingWallpaper = false
            }
        }
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
                } catch {
                    errorMessage = Self.truncateErrorMessage(error.localizedDescription)
                    showError = true
                }
                isSettingWallpaper = false
            }
        }
    }
}

private struct LoopingVideoBackgroundView: NSViewRepresentable {
    let url: URL
    let isMuted: Bool
    let onReady: (@MainActor @Sendable () -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(onReady: onReady)
    }

    func makeNSView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        context.coordinator.attach(to: view)
        context.coordinator.update(url: url, isMuted: isMuted, in: view)
        return view
    }

    func updateNSView(_ nsView: PlayerContainerView, context: Context) {
        context.coordinator.update(url: url, isMuted: isMuted, in: nsView)
    }

    static func dismantleNSView(_ nsView: PlayerContainerView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    @MainActor
    final class Coordinator {
        private weak var containerView: PlayerContainerView?
        private var currentURL: URL?
        private var player: AVQueuePlayer?
        private var looper: AVPlayerLooper?
        private var onReady: (@MainActor @Sendable () -> Void)?
        private var readyObserver: NSObjectProtocol?

        init(onReady: (@MainActor @Sendable () -> Void)?) {
            self.onReady = onReady
        }

        func attach(to view: PlayerContainerView) {
            containerView = view
        }

        func update(url: URL, isMuted: Bool, in view: PlayerContainerView) {
            attach(to: view)

            if currentURL != url {
                configurePlayer(with: url, in: view)
            }

            player?.isMuted = isMuted
            player?.volume = isMuted ? 0 : 1
            player?.play()
        }

        func teardown() {
            if let observer = readyObserver {
                NotificationCenter.default.removeObserver(observer)
                readyObserver = nil
            }
            looper?.disableLooping()
            looper = nil
            player?.pause()
            player = nil
            currentURL = nil
            containerView?.playerLayer.player = nil
        }

        private func configurePlayer(with url: URL, in view: PlayerContainerView) {
            teardown()

            let item = AVPlayerItem(url: url)
            let queuePlayer = AVQueuePlayer()
            queuePlayer.actionAtItemEnd = .none
            queuePlayer.automaticallyWaitsToMinimizeStalling = true

            let looper = AVPlayerLooper(player: queuePlayer, templateItem: item)
            view.playerLayer.player = queuePlayer
            
            // 监听视频准备好播放的状态
            readyObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemNewAccessLogEntry,
                object: item,
                queue: .main
            ) { @Sendable [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.onReady?()
                }
            }
            
            // 备选：使用短暂延迟确保视频已经开始加载
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.onReady?()
            }
            
            queuePlayer.play()

            self.player = queuePlayer
            self.looper = looper
            self.currentURL = url
        }
    }
}

private final class PlayerContainerView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = AVPlayerLayer()
        playerLayer.videoGravity = .resizeAspectFill
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var playerLayer: AVPlayerLayer {
        guard let layer = layer as? AVPlayerLayer else {
            let newLayer = AVPlayerLayer()
            newLayer.videoGravity = .resizeAspectFill
            self.layer = newLayer
            return newLayer
        }
        return layer
    }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
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
