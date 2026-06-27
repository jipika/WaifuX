import SwiftUI
import AppKit
import Kingfisher

// MARK: - 壁纸详情页 - macOS 26 Liquid Glass 沉浸式全屏风格
struct WallpaperDetailSheet: View {
    let initialWallpaper: Wallpaper
    @ObservedObject var viewModel: WallpaperViewModel
    let contextWallpapers: [Wallpaper]?
    let onClose: () -> Void
    /// 当需要在 NavigationStack 中 push 新壁纸时调用（如作者列表点击）
    let onNavigateToWallpaper: ((Wallpaper) -> Void)?

    @State private var resolvedWallpaper: Wallpaper
    @State private var isDownloading = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var isSettingWallpaper = false
    @State private var isVisible = false
    @State private var isImageLoaded = false
    @State private var scrollOffset: CGFloat = 0
    @State private var showInfoBubble = false
    @State private var isHeroContentHidden = false
    @State private var showDeleteConfirm = false
    /// 竖图模式下全分辨率图加载一次，供模糊延伸层与主图层共用
    @State private var sharedPortraitImage: NSImage?
    /// 竖图加载任务跟踪，防止快速切换时旧任务覆盖新图片
    @State private var portraitLoadTask: Task<Void, Never>?

    // MARK: - 键盘快捷键与滑动动画
    @State private var keyboardMonitor: Any?
    @State private var slideIncomingOffset: CGFloat = 0
    @State private var slideOutgoingOffset: CGFloat = 0
    @State private var isNavigating = false

    private enum SlideDirection {
        case up, down
    }

    // 挤压动画配置
    private let squeezeThreshold: CGFloat = 80
    private let maxSqueezeOffset: CGFloat = 120

    // MARK: - 下一张弹窗相关
    @StateObject private var nextItemDataSource = NextItemDataSource()
    @State private var currentWallpaperIndex: Int = 0
    @State private var isLoadingMore = false
    @State private var preloadTask: Task<Void, Never>?
    /// 分享面板相对定位用（与分享按钮同几何的锚定 `NSView`）
    @State private var sharePickerAnchorView: NSView?
    @State private var showCopyLinkToast = false
    @State private var showMoreOptionsPopover = false

    // MARK: - 作者壁纸弹窗相关
    @State private var showAuthorSheet = false
    @State private var authorWallpapers: [Wallpaper] = []
    @State private var isLoadingAuthorWallpapers = false
    @State private var authorWallpapersPage = 1
    @State private var hasMoreAuthorWallpapers = true
    /// 已加载的作者用户名，防止面板已打开时重复加载
    @State private var authorLoadedUploaderName: String?
    /// 缓存当前作者 uploader，避免切换壁纸时因新壁纸无 uploader 导致面板闪退
    @State private var cachedAuthorUploader: Wallpaper.Uploader?
    /// 从作者面板切换时使用淡入淡出过渡（而非滑动）
    @State private var isAuthorPanelFade = false

    private var prefetchNamespace: String {
        "wallpaper-detail-\(initialWallpaper.id)"
    }

    // MARK: - 本地文件检测
    private var isLocalFile: Bool {
        wallpaper.id.hasPrefix("local_")
    }

    /// 是否已下载（包括网络下载和本地文件）
    private var isAlreadyDownloaded: Bool {
        isLocalFile || viewModel.isDownloaded(wallpaper)
    }

    // 计算属性：当前壁纸
    var wallpaper: Wallpaper { resolvedWallpaper }

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

                // 固定背景：宽 100% 高度按比例 + 不足处模糊渐变，不随 ScrollView 滚动
                if isVisible {
                    fixedWallpaperBackground(width: viewW, height: viewH)
                        .id("wallpaper-bg-\(wallpaper.id)")
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

                // 图片加载动画
                if !isImageLoaded && !isNavigating {
                    LoadingOverlayView()
                        .frame(width: viewW, height: viewH)
                        .transition(.opacity.animation(.easeInOut(duration: 0.3)))
                }

                // 叠在固定底图上的轻暗角（不随滚动）
                ZStack {
                    VStack {
                        LinearGradient(
                            colors: [Color.black.opacity(0.48), Color.black.opacity(0.15), Color.clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 180)
                        Spacer()
                    }
                    VStack {
                        Spacer()
                        LinearGradient(
                            colors: [Color.clear, Color.black.opacity(0.22), Color.black.opacity(0.45)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: min(viewH * 0.35, 420))
                    }
                }
                .allowsHitTesting(false)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        // 为固定主信息区留出首屏空间，避免卡片顶到标题下方
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
                // 叠在滚动容器上但不铺满全屏，避免挡掉下方列表的滚动与点击
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

                floatingInfoOverlay(
                    viewportWidth: viewW,
                    topBarTopInset: topBarTopInset
                )

                // 下一张弹窗 - 固定在右下角，不覆盖全屏
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        LiquidGlassNextItemToast(
                            nextItem: nextItemDataSource.nextItem,
                            onTap: {
                                navigateToNextWallpaper()
                            },
                            onScrollUp: {
                                navigateToNextWallpaper()
                            },
                            onScrollDown: {
                                navigateToPreviousWallpaper()
                            },
                            onPreload: { _ in
                                // 预加载下一张壁纸的主图（完整分辨率）
                                if let nextWallpaper = nextItemDataSource.nextItem as? Wallpaper,
                                   let imageURL = nextWallpaper.fullImageURL ?? nextWallpaper.thumbURL {
                                    ForegroundPrefetchManager.shared.start(
                                        urls: [imageURL],
                                        namespace: prefetchNamespace
                                    )
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
                    Text(t("wallpaperDetail.linkCopied"))
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
        .alert(t("error"), isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .alert(t("delete"), isPresented: $showDeleteConfirm) {
            Button(t("delete"), role: .destructive) {
                viewModel.removeWallpaperDownloads(withIDs: [wallpaper.id])
                onClose()
            }
            Button(t("cancel"), role: .cancel) {}
        } message: {
            Text(t("deleteConfirmMessage"))
        }
        .overlay {
            authorSheetOverlay
        }
        .navigationBarBackButtonHidden(true)
        .onAppear {
            AppLogger.info(.wallpaper, "详情页 onAppear",
                metadata: ["wallpaperId": wallpaper.id, "isLocal": isLocalFile])
            // iOS 丝滑入场：分阶段渐显，模拟原生页面转场
            withAnimation(.easeOut(duration: 0.12).delay(0.02)) {
                isVisible = true
            }
            setupNextItemDataSource()
            setupKeyboardMonitor()
            // 非本地壁纸：从详情 API 获取完整数据（含 uploader）
            if !isLocalFile {
                fetchDetailAndUpdateUploader()
            }
        }
        .onChange(of: viewModel.wallpapers) { _, newWallpapers in
            // 本地上下文模式下不跟随线上列表变化
            guard contextWallpapers == nil else { return }
            // 当列表数据更新时，同步更新数据源
            nextItemDataSource.setItems(newWallpapers, currentIndex: currentWallpaperIndex)
            // 检查是否需要预加载
            triggerPreloadIfNeeded()
        }
        .onDisappear {
            isVisible = false
            // 清理预加载任务
            preloadTask?.cancel()
            ForegroundPrefetchManager.shared.stop(namespace: prefetchNamespace)
            removeKeyboardMonitor()
        }
    }

    init(wallpaper: Wallpaper, viewModel: WallpaperViewModel, contextWallpapers: [Wallpaper]? = nil, onClose: @escaping () -> Void, onNavigateToWallpaper: ((Wallpaper) -> Void)? = nil) {
        self.initialWallpaper = wallpaper
        self.viewModel = viewModel
        self.contextWallpapers = contextWallpapers
        self.onClose = onClose
        self.onNavigateToWallpaper = onNavigateToWallpaper
        _resolvedWallpaper = State(initialValue: wallpaper)
    }

    /// 当前导航使用的壁纸列表（本地上下文优先，否则使用线上列表）
    private var navigationItems: [Wallpaper] {
        contextWallpapers ?? viewModel.wallpapers
    }

    /// 主壁纸 URL（本地已下载文件优先，避免已下载壁纸仍从网络加载）
    private var heroImageURL: URL? {
        if let localURL = viewModel.localFileURLIfAvailable(for: wallpaper) {
            return localURL
        }
        return wallpaper.fullImageURL ?? wallpaper.thumbURL
    }

    private var isPortraitWallpaper: Bool {
        guard wallpaper.dimensionX > 0, wallpaper.dimensionY > 0 else {
            return false
        }
        return wallpaper.dimensionY > wallpaper.dimensionX
    }

    /// 固定背景：横图裁剪铺满整屏，竖图完整缩放并做左右模糊延伸
    @ViewBuilder
    private func fixedWallpaperBackground(width: CGFloat, height viewH: CGFloat) -> some View {
        if isPortraitWallpaper {
            portraitWallpaperBackground(width: width, height: viewH)
        } else {
            // 根据屏幕尺寸计算降采样目标大小（2x Retina），避免解码 4K/8K 全分辨率位图
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            let downsampleSize = CGSize(width: width * scale, height: viewH * scale)
            // 使用 Kingfisher 加载，有可靠的回调
            KFImage(heroImageURL)
                .setProcessor(DownsamplingImageProcessor(size: downsampleSize))
                .backgroundDecode()
                .fade(duration: 0.3)
                .onSuccess { _ in
                    isImageLoaded = true
                }
                .onFailure { _ in
                    isImageLoaded = true
                }
                .placeholder { _ in Color.clear }
                .resizable()
                .scaledToFill()
                .frame(width: width, height: viewH)
                .clipped()
        }
    }

    private func portraitWallpaperBackground(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            Color.black

            if let image = sharedPortraitImage {
                // 左右延伸层：使用已加载的全分辨率图做横向拉伸和模糊
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: width, height: height)
                    .scaleEffect(x: 2.25, y: 1.14, anchor: .center)
                    .blur(radius: 84)
                    .saturation(1.12)
                    .brightness(-0.08)
                    .mask(portraitWallpaperSideMask)

                // 主图：降采样到屏幕分辨率（用已加载的同一张图，不再重复请求网络）
                let scale = NSScreen.main?.backingScaleFactor ?? 2
                let _ = CGSize(width: width * scale, height: height * scale)
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFit()
                    .frame(width: width, height: height)
                    .shadow(color: Color.black.opacity(0.32), radius: 42, y: 18)
            }
            // 图片未加载时保持黑色背景（LoadingOverlay 覆盖期间不可见）

            LinearGradient(
                stops: [
                    .init(color: Color.black.opacity(0.42), location: 0.0),
                    .init(color: Color.clear, location: 0.20),
                    .init(color: Color.clear, location: 0.80),
                    .init(color: Color.black.opacity(0.42), location: 1.0)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .allowsHitTesting(false)
        }
        .frame(width: width, height: height, alignment: .center)
        .clipped()
        // 壁纸变化时重新加载；利用 Kingfisher 缓存，多数情况秒读
        .onChange(of: wallpaper.id) { _, _ in
            loadPortraitImage()
        }
        .onAppear {
            loadPortraitImage()
        }
    }

    /// 竖图专用：通过 Kingfisher 下载/缓存一次全分辨率图，供两个图层共用
    private func loadPortraitImage() {
        guard let url = heroImageURL else {
            isImageLoaded = true
            return
        }
        // 取消前一次加载任务，避免快速切换时旧结果覆盖新壁纸
        portraitLoadTask?.cancel()
        // 重置共享图片（触发黑色背景，LoadingOverlay 保持显示）
        sharedPortraitImage = nil
        isImageLoaded = false

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let screenSize = NSScreen.main?.frame.size ?? CGSize(width: 1512, height: 982)
        let downsampleSize = CGSize(
            width: max(screenSize.width, screenSize.height) * scale,
            height: min(screenSize.width, screenSize.height) * scale
        )

        portraitLoadTask = Task {
            do {
                let result = try await KingfisherManager.shared.retrieveImage(
                    with: url,
                    options: [
                        .processor(DownsamplingImageProcessor(size: downsampleSize)),
                        .backgroundDecode
                    ]
                )
                try Task.checkCancellation()
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    sharedPortraitImage = result.image
                    isImageLoaded = true
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    isImageLoaded = true
                }
            }
        }
    }

    private var portraitWallpaperSideMask: some View {
        LinearGradient(
            stops: [
                .init(color: .white, location: 0.0),
                .init(color: .white, location: 0.22),
                .init(color: .clear, location: 0.38),
                .init(color: .clear, location: 0.62),
                .init(color: .white, location: 0.78),
                .init(color: .white, location: 1.0)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    /// 标题、分类、元数据、操作按钮：固定在视口内，不随内容滚动（overlay 仅包裹控件本身高度，不拦截下方手势）
    private func fixedHeroChrome(viewportWidth: CGFloat, topBarTopInset: CGFloat) -> some View {
        // 计算挤压进度：0 表示未滚动，1 表示达到最大挤压
        let squeezeProgress = min(max(-scrollOffset / squeezeThreshold, 0), 1)
        let scaleY = 1 - (squeezeProgress * 0.15) // 最大挤压到 85%
        let offsetY = -squeezeProgress * maxSqueezeOffset * 0.3
        let opacity = 1 - (squeezeProgress * 0.3)

        return VStack(spacing: 0) {
            Spacer()
                .frame(height: max(topBarTopInset + 56, 72))
            centerInfoSection
                .padding(.horizontal, max(28, min(96, viewportWidth * 0.08)))
        }
        .frame(maxWidth: viewportWidth)
        .scaleEffect(x: 1, y: scaleY, anchor: .center)
        .offset(y: offsetY)
        .opacity(opacity)
        .animation(.easeOut(duration: 0.15), value: scrollOffset)
    }

    /// ScrollView 顶部透明占位高度，使详情卡片从固定主信息区下方开始
    private func detailScrollTopInset(viewportHeight: CGFloat, heroHidden: Bool) -> CGFloat {
        if heroHidden {
            return max(viewportHeight * 0.32, 260)
        }
        return max(viewportHeight * 0.5, 400)
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

    // MARK: - 中央信息区（叠在全幅壁纸上，对齐设计稿居中排版）
    private var centerInfoSection: some View {
        VStack(spacing: 20) {
            if !isHeroContentHidden {
                Text(wallpaperTitle)
                    .font(.system(size: 56, weight: .bold, design: .serif))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.72)
                    .detailGlassTitleChrome()

                detailCategoryBadge

                HStack {
                    Spacer(minLength: 0)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 0) {
                            metadataCapsules
                        }

                        VStack(spacing: 8) {
                            HStack(spacing: 0) {
                                ForEach(Array(metadataItems.prefix(2).enumerated()), id: \.offset) { index, item in
                                    authorAwareCapsule(label: item.label, value: item.value, isLast: index == metadataItems.prefix(2).count - 1)
                                }
                            }

                            HStack(spacing: 0) {
                                ForEach(Array(metadataItems.dropFirst(2).enumerated()), id: \.offset) { index, item in
                                    authorAwareCapsule(label: item.label, value: item.value, isLast: index == metadataItems.dropFirst(2).count - 1)
                                }
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 8)
                .glassContainer(spacing: 10)

                // 按钮区域：带左右横线
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

    // MARK: - 按钮行（带左右横线）
    private var buttonRowWithDividers: some View {
        HStack(spacing: 16) {
            // 左侧横线 + 收藏按钮 + 预览按钮
            HStack(spacing: 16) {
                dividerLine
                    .frame(width: 80)

                Button {
                    viewModel.toggleFavorite(wallpaper)
                } label: {
                    DetailSheetCircleIconLabel(
                        systemName: viewModel.isFavorite(wallpaper) ? "heart.fill" : "heart",
                        foreground: viewModel.isFavorite(wallpaper) ? Color(hex: "FF5A7D") : .white
                    )
                    .detailGlassCircleChrome()
                }
                .buttonStyle(.plain)

                if isAlreadyDownloaded {
                    Button {
                        previewWallpaper()
                    } label: {
                        DetailSheetCircleIconLabel(systemName: "arrow.up.backward.and.arrow.down.forward")
                            .detailGlassCircleChrome()
                    }
                    .buttonStyle(.plain)
                    .help(t("preview"))
                }
            }

            // 主按钮
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

            // 下载按钮 + 已下载时分享 + 右侧横线
            HStack(spacing: 16) {
                Button {
                    if !isAlreadyDownloaded {
                        downloadWallpaper()
                    }
                } label: {
                    DetailSheetCircleIconLabel(systemName: isAlreadyDownloaded ? "checkmark" : "arrow.down")
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
                .help(t("wallpaperDetail.moreOptions"))
                .background(
                    SharePickerAnchorReader { anchor in
                        sharePickerAnchorView = anchor
                    }
                )
                .popover(isPresented: $showMoreOptionsPopover, arrowEdge: .bottom) {
                    morePopoverMenuContent
                }

                dividerLine
                    .frame(width: 80)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
        .glassContainer(spacing: 16)
    }

    // MARK: - 液态玻璃更多菜单
    @ViewBuilder
    private var morePopoverMenuContent: some View {
        VStack(spacing: 0) {
            if isAlreadyDownloaded {
                Button {
                    // 不关闭菜单，保持锚点有效
                    viewModel.shareDownloadedWallpaperIfAvailable(wallpaper, anchorView: sharePickerAnchorView)
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
                    NSPasteboard.general.setString(wallpaper.url, forType: .string)
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
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    showMoreOptionsPopover = false
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(wallpaper.url, forType: .string)
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
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 192)
    }

    // 横线分隔符
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
                Text(wallpaperTitle)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.96))
                    .lineLimit(2)

                Text("\(wallpaper.categoryDisplayName) · \(wallpaper.purityDisplayName)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
                    .tracking(0.6)
            }

            if !tagNames.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(tagNames.prefix(8), id: \.self) { tag in
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
                compactFact(label: "ID", value: wallpaper.id.uppercased())
                if let _ = wallpaper.uploader {
                    Button {
                        openAuthorSheet()
                    } label: {
                        compactFact(label: t("author"), value: uploaderLabel, isInteractive: true)
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }
                } else {
                    compactFact(label: t("author"), value: uploaderLabel)
                }
                compactFact(label: t("category"), value: wallpaper.categoryDisplayName)
                compactFact(label: t("source"), value: sourceLabel)
                compactFact(label: t("created"), value: createdDateLabel)
            }

            dividerLine.opacity(0.7)

            infoSection(title: t("specs")) {
                compactFact(label: t("resolution"), value: wallpaper.resolution)
                compactFact(label: t("ratio"), value: wallpaper.ratio)
                compactFact(label: t("fileType"), value: fileTypeLabel)
                compactFact(label: t("purity"), value: purityLabel)
                compactFact(label: t("views"), value: "\(wallpaper.views)")
                compactFact(label: t("favorites"), value: "\(wallpaper.favorites)")

                if let downloads = wallpaper.downloads {
                    compactFact(label: t("downloads"), value: "\(downloads)")
                }

                if let fileSize = wallpaper.fileSize {
                    compactFact(label: t("size"), value: formatFileSize(fileSize))
                }
            }

            dividerLine.opacity(0.7)

            VStack(alignment: .leading, spacing: 12) {
                sectionTitle(t("wallpaperColors"))

                HStack(spacing: 8) {
                    ForEach(displayColors, id: \.self) { hex in
                        VStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color(hex: hex))
                                .frame(height: 36)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(Color.white.opacity(0.15), lineWidth: 1)
                                )

                            Text("#\(hex)")
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        .frame(maxWidth: .infinity)
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

    // 紧凑的信息项
    private func compactFact(label: String, value: String, isInteractive: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
                .frame(width: 70, alignment: .leading)

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

    // MARK: - 分享卡片（左深右透：底图 + 横向渐变，右侧露出壁纸）
    private var shareCard: some View {
        let corner: CGFloat = 28

        return ZStack(alignment: .leading) {
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height

                ZStack {
                    AsyncImage(url: heroImageURL) { phase in
                        switch phase {
                        case .empty:
                            Rectangle().fill(Color.white.opacity(0.08))
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: w * 1.08, height: h)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                                .clipped()
                        case .failure:
                            Rectangle().fill(Color.white.opacity(0.08))
                        @unknown default:
                            Rectangle().fill(Color.white.opacity(0.08))
                        }
                    }
                    .frame(width: w, height: h)

                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.92),
                            Color.black.opacity(0.72),
                            Color.black.opacity(0.35),
                            Color.black.opacity(0.08),
                            Color.clear
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                }
                .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            }
            .frame(maxWidth: .infinity, minHeight: 260)

            VStack(alignment: .leading, spacing: 12) {
                Text(t("wallpaperContent"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.65))
                    .tracking(2)

                Text(t("shareWithEveryone"))
                    .font(.system(size: 26, weight: .bold, design: .serif))
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                Text(t("generateShareable"))
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineSpacing(3)
                    .frame(maxWidth: 400, alignment: .leading)

                Text(t("shareLinkDescription"))
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.white.opacity(0.68))
                    .lineSpacing(3)
                    .frame(maxWidth: 400, alignment: .leading)

                Button {
                    shareWallpaper()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 13, weight: .medium))
                        Text(t("sendToFriends"))
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .frame(height: 38)
                    .detailGlassCapsuleChrome(level: .prominent)
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
            }
            .padding(28)
            .frame(maxWidth: 520, alignment: .leading)
        }
        .overlay(
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.35), radius: 28, y: 16)
    }



    private var metadataItems: [(label: String, value: String)] {
        var items: [(String, String)] = []

        // 仅在存在上传者信息时显示作者
        if wallpaper.uploader != nil {
            items.append((t("author"), uploaderLabel))
        }

        if let fileSize = wallpaper.fileSize {
            items.append((t("size"), formatFileSize(fileSize)))
        }

        items.append((t("resolution"), wallpaper.resolution))
        items.append((t("likes"), "\(wallpaper.favorites)"))
        return items
    }

    private var wallpaperTitle: String {
        let meaningfulTag = wallpaper.tags?.first(where: { !$0.name.isEmpty && $0.name.lowercased() != "wallpaper" })?.name
        return meaningfulTag ?? "Wallpaper \(wallpaper.id.uppercased())"
    }

    private var sourceLabel: String {
        if
            let source = wallpaper.source,
            let url = URL(string: source),
            let host = url.host
        {
            return host.replacingOccurrences(of: "www.", with: "")
        }

        if let source = wallpaper.source, !source.isEmpty {
            return source
        }

        return "wallhaven"
    }

    private var uploaderLabel: String {
        if let username = wallpaper.uploader?.username, !username.isEmpty {
            return username
        }
        return sourceLabel
    }

    private var tagNames: [String] {
        let tags = wallpaper.tags?
            .map(\.name)
            .filter { !$0.isEmpty } ?? []
        return Array(Set(tags.prefix(8))).sorted()
    }

    private var displayColors: [String] {
        let palette = Array(wallpaper.colors.prefix(4))
        return palette.isEmpty ? ["5C6470", "3B4048", "A88C74", "D4C2A8"] : palette
    }

    private var createdDateLabel: String {
        guard let createdAt = wallpaper.createdAt, !createdAt.isEmpty else {
            return t("unknown")
        }
        return createdAt.replacingOccurrences(of: "T", with: " ")
    }

    private var purityLabel: String {
        wallpaper.purityDetailLabel
    }

    private var fileTypeLabel: String {
        guard let fileType = wallpaper.fileType, !fileType.isEmpty else {
            return "JPEG"
        }
        return fileType.replacingOccurrences(of: "image/", with: "").uppercased()
    }

    private var statusText: String {
        if isSettingWallpaper {
            return t("settingWallpaper")
        }
        if isDownloading {
            return t("downloadingWallpaper")
        }
        if isAlreadyDownloaded {
            return t("savedToDownloads")
        }
        return ""
    }

    private func formatFileSize(_ bytes: Int) -> String {
        let mb = Double(bytes) / 1024 / 1024
        return String(format: "%.0f mb", mb)
    }

    private var detailCategoryBadge: some View {
        Text("\(wallpaper.categoryDisplayName) · \(wallpaper.purityDisplayName)")
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.white.opacity(0.85))
            .tracking(2)
            .padding(.horizontal, 16)
            .frame(height: 34)
            .detailGlassCapsuleChrome(level: .prominent)
    }

    // MARK: - 元数据胶囊（参考图风格：细长边框）
    private func DetailMetaCapsule(label: String, value: String, isLast: Bool = false, isInteractive: Bool = false) -> some View {
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
            authorAwareCapsule(label: item.label, value: item.value, isLast: index == metadataItems.count - 1)
        }
    }

    /// 统一的胶囊渲染：如果是作者且可点击则包装为 Button
    @ViewBuilder
    private func authorAwareCapsule(label: String, value: String, isLast: Bool) -> some View {
        if label == t("author"), let _ = wallpaper.uploader {
            Button {
                openAuthorSheet()
            } label: {
                DetailMetaCapsule(
                    label: label,
                    value: value,
                    isLast: isLast,
                    isInteractive: true
                )
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        } else {
            DetailMetaCapsule(
                label: label,
                value: value,
                isLast: isLast
            )
        }
    }

    private var detailDisclosureIndicator: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white.opacity(0.32))
    }

    // MARK: - 壁纸详情 API 获取（补充 uploader 数据）

    /// 调用 Wallhaven 详情 API 获取完整数据（含 uploader），更新当前壁纸
    private func fetchDetailAndUpdateUploader() {
        // 已有 uploader 则跳过
        if wallpaper.uploader != nil { return }
        let wallpaperID = wallpaper.id
        Task {
            do {
                let detail = try await viewModel.fetchWallpaperDetail(byID: wallpaperID)
                await MainActor.run {
                    // 只替换 uploader 字段（其他字段保持搜索结果的即可）
                    if detail.uploader != nil {
                        let updated = resolvedWallpaper
                        // 通过重新创建 Wallpaper 来更新 uploader（保持其他字段不变）
                        let newWallpaper = Wallpaper(
                            id: updated.id,
                            url: updated.url,
                            shortUrl: updated.shortUrl,
                            views: updated.views,
                            favorites: updated.favorites,
                            downloads: updated.downloads,
                            source: updated.source,
                            purity: updated.purity,
                            category: updated.category,
                            dimensionX: updated.dimensionX,
                            dimensionY: updated.dimensionY,
                            resolution: updated.resolution,
                            ratio: updated.ratio,
                            fileSize: updated.fileSize,
                            fileType: updated.fileType,
                            createdAt: updated.createdAt,
                            colors: updated.colors,
                            path: updated.path,
                            thumbs: updated.thumbs,
                            tags: updated.tags,
                            uploader: detail.uploader
                        )
                        resolvedWallpaper = newWallpaper
                        AppLogger.info(.wallpaper, "详情 API 返回 uploader",
                            metadata: ["username": detail.uploader?.username ?? "nil"])
                    }
                }
            } catch {
                AppLogger.warn(.wallpaper, "获取壁纸详情失败（不影响浏览）",
                    metadata: ["wallpaperID": wallpaperID, "error": error.localizedDescription])
            }
        }
    }

    // MARK: - 操作方法
    private func downloadWallpaper() {
        // 本地文件无需下载
        if isLocalFile {
            AppLogger.debug(.download, "跳过下载：本地文件", metadata: ["id": wallpaper.id])
            return
        }

        AppLogger.info(.download, "开始下载壁纸",
            metadata: ["id": wallpaper.id, "分辨率": wallpaper.resolution, "大小": wallpaper.fileSize.map { "\($0)B" } ?? "未知"])
        isDownloading = true
        errorMessage = ""
        let start = Date()
        Task {
            do {
                try await viewModel.downloadWallpaper(wallpaper)
                AppLogger.info(.download, "下载成功",
                    metadata: ["id": wallpaper.id, "耗时(s)": String(format: "%.2f", Date().timeIntervalSince(start))])
            } catch {
                errorMessage = "\(t("error")): \(error.localizedDescription)"
                showError = true
                AppLogger.error(.download, "下载失败",
                    metadata: ["id": wallpaper.id, "error": error.localizedDescription,
                     "耗时(s)": String(format: "%.2f", Date().timeIntervalSince(start))])
                print("Download error: \(error)")
            }
            isDownloading = false
        }
    }

    private func setAsDesktopWallpaper() {
        // 检测多显示器
        let screens = NSScreen.screens
        if screens.count > 1 {
            // 多显示器环境下显示选择弹窗
            // selectedScreen == nil 表示"所有显示器"，非 nil 表示特定显示器
            DisplaySelectorManager.shared.showSelector(
                title: t("setWallpaper"),
                message: t("multiDisplayDetected")
            ) { [self] selectedScreen in
                isSettingWallpaper = true
                errorMessage = ""
                Task { @MainActor in
                    do {
                        let imageURL = try await getWallpaperImageURL()
                        // selectedScreen == nil → 所有显示器；非 nil → 仅指定显示器
                        // viewModel 内部会按需停止对应屏幕的动态壁纸
                        try await viewModel.setWallpaper(from: imageURL, option: .desktop, for: selectedScreen)
                        WallpaperSchedulerService.shared.notifyManualWallpaperChange(screenID: selectedScreen?.wallpaperScreenIdentifier)
                        isSettingWallpaper = false
                    } catch {
                        errorMessage = "\(t("error")): \(error.localizedDescription)"
                        showError = true
                        print("Set wallpaper error: \(error)")
                        isSettingWallpaper = false
                    }
                }
            }
        } else {
            // 单显示器环境下直接设置
            isSettingWallpaper = true
            errorMessage = ""
            Task { @MainActor in
                do {
                    let imageURL = try await getWallpaperImageURL()
                    // viewModel 内部会按需停止动态壁纸
                    try await viewModel.setWallpaper(from: imageURL, option: .desktop)
                    WallpaperSchedulerService.shared.notifyManualWallpaperChange(
                        screenID: NSScreen.screens.first?.wallpaperScreenIdentifier
                    )
                } catch {
                    errorMessage = "\(t("error")): \(error.localizedDescription)"
                    showError = true
                    print("Set wallpaper error: \(error)")
                }
                isSettingWallpaper = false
            }
        }
    }

    /// 获取壁纸图片 URL（本地/已下载文件直接返回，未下载的网络壁纸才下载到临时目录）
    private func getWallpaperImageURL() async throws -> URL {
        // 本地壁纸：直接使用本地文件路径
        if wallpaper.id.hasPrefix("local_"),
           let localURL = wallpaper.fullImageURL,
           localURL.isFileURL,
           FileManager.default.fileExists(atPath: localURL.path) {
            print("[WallpaperDetailSheet] Using local wallpaper file: \(localURL.path)")
            return localURL
        }

        // 已下载的网络壁纸：直接使用本地已下载的文件，避免重复联网下载
        if let downloadedURL = viewModel.localFileURLIfAvailable(for: wallpaper) {
            print("[WallpaperDetailSheet] Using downloaded wallpaper file: \(downloadedURL.path)")
            return downloadedURL
        }

        // 未下载的网络壁纸：下载到临时目录
        let imageData = try await viewModel.downloadWallpaperData(wallpaper)
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(wallpaper.id).jpg")
        try imageData.write(to: tempURL)
        return tempURL
    }

    private func shareWallpaper() {
        viewModel.shareWallpaper(wallpaper)
    }

    private func previewWallpaper() {
        Task {
            do {
                let url = try await getWallpaperImageURL()
                await MainActor.run {
                    PreviewWindowManager.shared.openPreview(
                        url: url,
                        aspectRatio: wallpaper.aspectRatioValue
                    )
                }
            } catch {
                errorMessage = "\(t("error")): \(error.localizedDescription)"
                showError = true
            }
        }
    }

    // MARK: - 下一张弹窗相关方法

    private func setupNextItemDataSource() {
        let items = navigationItems
        // 找到当前壁纸在列表中的索引
        if let index = items.firstIndex(where: { $0.id == wallpaper.id }) {
            currentWallpaperIndex = index
        }

        // 设置数据源
        nextItemDataSource.setItems(items, currentIndex: currentWallpaperIndex)

        // 初始预加载检查（仅线上模式）
        if contextWallpapers == nil {
            triggerPreloadIfNeeded()
        }
    }

    /// 当浏览到倒数第3张时触发预加载（仅线上模式）
    private func triggerPreloadIfNeeded() {
        guard contextWallpapers == nil else { return }
        let threshold = 3 // 倒数第3张时开始预加载
        let remainingItems = viewModel.wallpapers.count - (currentWallpaperIndex + 1)

        // 如果剩余项目少于阈值，且有更多页面，则触发预加载
        if remainingItems < threshold && viewModel.hasMorePages && !viewModel.isLoading && !isLoadingMore {
            preloadTask?.cancel()
            preloadTask = Task {
                print("[WallpaperDetailSheet] 触发预加载，当前索引: \(currentWallpaperIndex), 总数: \(viewModel.wallpapers.count)")
                await viewModel.loadMore()
                // 加载完成后更新数据源
                await MainActor.run {
                    nextItemDataSource.setItems(viewModel.wallpapers, currentIndex: currentWallpaperIndex)
                }
            }
        }
    }

    private func navigateToNextWallpaper() {
        guard !isNavigating else { return }
        let items = navigationItems
        let nextIndex = currentWallpaperIndex + 1

        // 情况1：下一张已经在当前列表中
        if nextIndex < items.count {
            prepareSlideTransition(direction: .down)
            navigateToIndex(nextIndex)
            // 导航后检查是否需要预加载（仅线上模式）
            if contextWallpapers == nil {
                triggerPreloadIfNeeded()
            }
            return
        }

        // 情况2：到达列表末尾，但有更多页面可加载（仅线上模式）
        if contextWallpapers == nil, viewModel.hasMorePages && !viewModel.isLoading && !isLoadingMore {
            Task {
                isLoadingMore = true
                defer { isLoadingMore = false }

                print("[WallpaperDetailSheet] 加载更多壁纸...")
                await viewModel.loadMore()

                // 加载完成后，尝试导航到下一张
                if nextIndex < viewModel.wallpapers.count {
                    await MainActor.run {
                        self.prepareSlideTransition(direction: .down)
                        self.navigateToIndex(nextIndex)
                    }
                }
            }
            return
        }

        // 情况3：没有更多数据了，循环到第一张
        if !items.isEmpty && nextIndex >= items.count {
            prepareSlideTransition(direction: .down)
            navigateToIndex(0)
        }
    }

    private func navigateToPreviousWallpaper() {
        guard !isNavigating else { return }
        let items = navigationItems
        let prevIndex = currentWallpaperIndex - 1

        // 情况1：上一张在列表中
        if prevIndex >= 0 {
            prepareSlideTransition(direction: .up)
            navigateToIndex(prevIndex)
            return
        }

        // 情况2：已经是第一张，循环到最后一张
        if !items.isEmpty {
            prepareSlideTransition(direction: .up)
            navigateToIndex(items.count - 1)
        }
    }

    private func navigateToIndex(_ index: Int) {
        let items = navigationItems
        guard index >= 0, index < items.count else { return }

        currentWallpaperIndex = index
        nextItemDataSource.moveToIndex(index)
        reloadWallpaper(items[index])
    }

    private func reloadWallpaper(_ newWallpaper: Wallpaper) {
        // iOS 丝滑切换：交叉淡入淡出 + 微位移
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82, blendDuration: 0)) {
            // 更新当前壁纸
            resolvedWallpaper = newWallpaper

            // 重置状态来触发重新加载
            isImageLoaded = false
            showInfoBubble = false
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
                self.navigateToPreviousWallpaper()
                return nil
            case 125: // 下方向键：下一张
                guard !self.isNavigating else { return nil }
                self.navigateToNextWallpaper()
                return nil
            case 53: // ESC：优先关闭当前弹窗，再关闭预览，最后返回详情栈
                if self.showAuthorSheet {
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
        // 动画结束后重置，避免影响后续普通切换
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            self.isNavigating = false
            self.slideIncomingOffset = 0
            self.slideOutgoingOffset = 0
        }
    }

    // MARK: - 作者壁纸弹窗

    @ViewBuilder
    private var authorSheetOverlay: some View {
        if showAuthorSheet, let uploader = cachedAuthorUploader {
            AuthorWallpaperSheet(
                uploader: uploader,
                wallpapers: authorWallpapers,
                isLoading: isLoadingAuthorWallpapers,
                activeWallpaperID: wallpaper.id,
                onSelectWallpaper: { selectedWallpaper in
                    navigateToAuthorWallpaper(selectedWallpaper)
                },
                onDismiss: {
                    dismissAuthorSheet()
                },
                onLoadMore: {
                    self.loadMoreAuthorWallpapers()
                }
            )
            .transition(.identity)
            .zIndex(100)
        }
    }

    /// 打开作者壁纸弹窗，开始加载该作者的壁纸列表
    private func openAuthorSheet() {
        guard let uploader = wallpaper.uploader else { return }
        // 面板已打开且同一作者时，不重复加载
        if showAuthorSheet && uploader.username == authorLoadedUploaderName { return }
        showAuthorSheet = true
        authorLoadedUploaderName = uploader.username
        cachedAuthorUploader = uploader
        authorWallpapers = []
        authorWallpapersPage = 1
        hasMoreAuthorWallpapers = true
        isLoadingAuthorWallpapers = true

        Task {
            do {
                let results = try await viewModel.fetchWallpapersByAuthor(
                    username: uploader.username,
                    page: 1,
                    limit: 24
                )
                await MainActor.run {
                    authorWallpapers = results
                    hasMoreAuthorWallpapers = results.count >= 24
                    isLoadingAuthorWallpapers = false
                }
            } catch {
                AppLogger.error(.wallpaper, "加载作者壁纸失败",
                    metadata: ["username": uploader.username, "error": error.localizedDescription])
                await MainActor.run {
                    isLoadingAuthorWallpapers = false
                }
            }
        }
    }

    private func dismissAuthorSheet() {
        showAuthorSheet = false
        authorWallpapers = []
        authorWallpapersPage = 1
        hasMoreAuthorWallpapers = true
        isLoadingAuthorWallpapers = false
        authorLoadedUploaderName = nil
        cachedAuthorUploader = nil
    }

    /// 加载更多作者壁纸（分页），防止重复触发
    private func loadMoreAuthorWallpapers() {
        guard let uploader = cachedAuthorUploader, !isLoadingAuthorWallpapers, hasMoreAuthorWallpapers else { return }
        isLoadingAuthorWallpapers = true
        let nextPage = authorWallpapersPage + 1

        Task {
            do {
                let results = try await viewModel.fetchWallpapersByAuthor(
                    username: uploader.username,
                    page: nextPage,
                    limit: 24
                )
                await MainActor.run {
                    authorWallpapers.append(contentsOf: results)
                    authorWallpapersPage = nextPage
                    hasMoreAuthorWallpapers = results.count >= 24
                    isLoadingAuthorWallpapers = false
                }
            } catch {
                AppLogger.error(.wallpaper, "加载更多作者壁纸失败",
                    metadata: ["username": uploader.username, "page": nextPage, "error": error.localizedDescription])
                await MainActor.run {
                    isLoadingAuthorWallpapers = false
                }
            }
        }
    }

    /// 从作者壁纸面板切换到新的壁纸详情（不关闭面板，原地替换数据，不做 NavigationStack 跳转）
    private func navigateToAuthorWallpaper(_ wallpaper: Wallpaper) {
        // 使用淡入淡出过渡（而非滑动），不关闭作者面板
        isAuthorPanelFade = true
        isNavigating = true

        // 直接替换当前壁纸数据，不走 navigateToIndex（避免更新 currentWallpaperIndex 触发副作用）
        reloadWallpaper(wallpaper)
        // 重新获取 uploader 数据（新壁纸来自搜索列表，不含 uploader）
        fetchDetailAndUpdateUploader()

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
