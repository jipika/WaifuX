import SwiftUI
import AVKit
import AVFoundation
import AppKit

struct MediaDetailSheet: View {
    let initialItem: MediaItem
    @ObservedObject var viewModel: MediaExploreViewModel
    let onClose: () -> Void

    @ObservedObject private var wallpaperManager = VideoWallpaperManager.shared
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
        .navigationBarBackButtonHidden(true)
        .task {
            isVisible = true
            setupNextItemDataSource()
            await loadDetailIfNeeded()
        }
    }

    private var heroImageURL: URL? {
        resolvedItem.posterURL ?? resolvedItem.thumbnailURL
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
                OptimizedAsyncImage(url: heroImageURL, priority: .high, onLoad: { @MainActor in
                    withAnimation(.easeInOut(duration: 0.3)) {
                        isMediaLoaded = true
                    }
                }) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Color.clear
                }
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

    private var floatingBackButton: some View {
        Button(action: onClose) {
            Image(systemName: "chevron.left")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
                .frame(width: 38, height: 38)
                .contentShape(Circle())
                .detailGlassCircleChrome()
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
                    Image(systemName: showInfoBubble ? "info.circle.fill" : "info.circle")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95))
                        .frame(width: 40, height: 40)
                        .contentShape(Circle())
                        .detailGlassCircleChrome()
                }
                .buttonStyle(.plain)

                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.85, blendDuration: 0)) {
                        isHeroContentHidden.toggle()
                    }
                } label: {
                    Image(systemName: isHeroContentHidden ? "eye.slash" : "eye")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95))
                        .frame(width: 40, height: 40)
                        .contentShape(Circle())
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

    private var buttonRowWithDividers: some View {
        HStack(spacing: 16) {
            HStack(spacing: 16) {
                dividerLine
                    .frame(width: 70)

                Button {
                    viewModel.toggleFavorite(resolvedItem)
                } label: {
                    Image(systemName: viewModel.isFavorite(resolvedItem) ? "heart.fill" : "heart")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(viewModel.isFavorite(resolvedItem) ? Color(hex: "FF5A7D") : .white)
                        .frame(width: 42, height: 42)
                        .contentShape(Circle())
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
                    Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .contentShape(Circle())
                        .detailGlassCircleChrome()
                }
                .buttonStyle(.plain)

                Button {
                    if !isAlreadyDownloaded {
                        downloadMedia()
                    }
                } label: {
                    Image(systemName: isAlreadyDownloaded ? "checkmark" : "arrow.down")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .contentShape(Circle())
                        .detailGlassCircleChrome()
                }
                .buttonStyle(.plain)
                .disabled(isDownloading || isAlreadyDownloaded)

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
                    value: previewVideoURL?.pathExtension.uppercased().isEmpty == false ? previewVideoURL!.pathExtension.uppercased() : "MP4"
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
        resolvedItem = detail
        viewModel.recordViewed(detail)
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
        resolvedItem = detail
        viewModel.recordViewed(detail)
        // 来源数据已加载并排序完成
        withAnimation(.easeInOut(duration: 0.3)) {
            isSourcesReady = true
        }
    }

    private func downloadMedia() {
        // 本地文件无需下载
        if isLocalFile {
            return
        }
        
        isDownloading = true
        errorMessage = ""
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
                } else {
                    throw NetworkError.invalidResponse
                }
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
            isDownloading = false
        }
    }

    private func setAsDesktopWallpaper() {
        // 检测多显示器
        let screens = NSScreen.screens
        if screens.count > 1 {
            // 多显示器环境下显示选择弹窗
            DisplaySelectorManager.shared.showSelector(
                title: t("setWallpaper"),
                message: t("multiDisplayDetected")
            ) { [self] selectedScreen in
                // 用户取消选择
                guard selectedScreen != nil || screens.count > 0 else {
                    return
                }
                
                isSettingWallpaper = true
                errorMessage = ""
                Task {
                    do {
                        try await viewModel.applyDynamicWallpaper(resolvedItem, muted: isMuted, targetScreen: selectedScreen)
                    } catch {
                        await MainActor.run {
                            errorMessage = error.localizedDescription
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
            // 单显示器环境下直接设置
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
