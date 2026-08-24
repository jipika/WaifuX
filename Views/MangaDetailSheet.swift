import SwiftUI
import Combine
import Kingfisher
import AppKit

// MARK: - MangaDetailSheet

/// 漫画详情页（左右分栏：左阅读器 / 右章节面板）
/// 全屏沉浸式，风格对齐 AnimeDetailSheet。
struct MangaDetailSheet: View {
    let route: MangaRoutePayload
    let onNavigateToManga: (MangaRoutePayload) -> Void
    @StateObject private var viewModel: MangaDetailViewModel

    @State private var isVisible = false
    @State private var scrollOffset: CGFloat = 0
    @State private var showInfoBubble = false
    @Environment(\.dismiss) private var dismiss

    // 键盘监听（全局热键）
    @State private var keyboardMonitor: Any?

    // MARK: - 作者漫画面板
    @State private var showAuthorMangaSheet = false
    @State private var authorMangaItems: [Wallpaper] = []
    @State private var isLoadingAuthorManga = false
    @State private var authorMangaPage = 1
    @State private var hasMoreAuthorManga = true
    @State private var cachedAuthorMangaUploader: Wallpaper.Uploader?
    @State private var isDownloadingAuthorManga = false

    init(
        route: MangaRoutePayload,
        onNavigateToManga: @escaping (MangaRoutePayload) -> Void = { _ in }
    ) {
        self.route = route
        self.onNavigateToManga = onNavigateToManga
        self._viewModel = StateObject(wrappedValue: MangaDetailViewModel(route: route))
    }

    var body: some View {
        GeometryReader { geometry in
            let topBarTopInset = max(geometry.safeAreaInsets.top, 18)
            let viewW = geometry.size.width
            let viewH = geometry.size.height

            ZStack(alignment: .topLeading) {
                Color(hex: "0A0A0C")
                    .ignoresSafeArea()

                if isVisible {
                    // 封面高斯模糊背景
                    backdropLayer(width: viewW, height: viewH)
                }

                // 顶/底渐变暗角
                cornerGradient(viewH: viewH)
                    .allowsHitTesting(false)

                // 主体：左阅读器 + 右章节/信息面板
                if viewModel.isLoading && viewModel.series == nil {
                    loadingView
                        .frame(width: viewW, height: viewH)
                } else if let _ = viewModel.series {
                    mainSplit
                        .padding(.top, topBarTopInset + 72)
                        .padding(.bottom, 20)
                        .padding(.horizontal, 24)
                } else if let err = viewModel.errorMessage {
                    errorView(message: err)
                        .frame(width: viewW, height: viewH)
                }

                // 顶部浮动工具栏
                topBar(topInset: topBarTopInset, width: viewW)
            }
        }
        .ignoresSafeArea()
        .task {
            isVisible = true
            await viewModel.load()
            installKeyboardMonitor()
        }
        .onDisappear {
            if let monitor = keyboardMonitor {
                NSEvent.removeMonitor(monitor)
                keyboardMonitor = nil
            }
        }
        .overlay {
            authorMangaSheetOverlay
        }
    }

    // MARK: - Main split
    private var mainSplit: some View {
        HStack(spacing: 20) {
            // 左：阅读器
            MangaReaderView(viewModel: viewModel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // 右：信息 + 章节列表
            MangaSidePanel(
                viewModel: viewModel,
                onShowAuthorManga: openAuthorMangaSheet
            )
                .frame(width: 320)
        }
    }

    // MARK: - Backdrop
    @ViewBuilder
    private func backdropLayer(width: CGFloat, height: CGFloat) -> some View {
        let coverURLStr = viewModel.series?.coverURL
            ?? viewModel.currentChapter?.coverURL

        KFImage(URL(string: coverURLStr ?? ""))
            .cacheMemoryOnly(false)
            .fade(duration: 0.3)
            .placeholder { _ in Color(hex: "1A1A1E") }
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: width, height: height)
            .clipped()
            .blur(radius: 60)
            .overlay(
                Color.black.opacity(0.55)
            )
    }

    private func cornerGradient(viewH: CGFloat) -> some View {
        ZStack {
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [Color.black.opacity(0.55), Color.black.opacity(0.2), .clear],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 180)
                Spacer()
            }
            VStack(spacing: 0) {
                Spacer()
                LinearGradient(
                    colors: [.clear, Color.black.opacity(0.35), Color.black.opacity(0.75)],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: min(viewH * 0.4, 420))
            }
        }
    }

    // MARK: - Top bar
    private func topBar(topInset: CGFloat, width: CGFloat) -> some View {
        HStack(spacing: 12) {
            // 浮动圆形返回按钮（与 AnimeDetailSheet / WallpaperDetailSheet 风格一致）
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                    .frame(width: 38, height: 38)
                    .contentShape(Circle())
                    .detailGlassCircleChrome()
            }
            .buttonStyle(.plain)

            Spacer()

            Text(viewModel.seriesTitle)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: width * 0.4)

            Spacer()

            // 阅读器模式切换（圆形玻璃按钮）
            Button {
                viewModel.toggleReaderMode()
            } label: {
                Image(systemName: viewModel.readerMode.systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                    .frame(width: 38, height: 38)
                    .contentShape(Circle())
                    .detailGlassCircleChrome()
            }
            .buttonStyle(.plain)
            .help("切换阅读模式：\(viewModel.readerMode.displayName)")
        }
        .padding(.horizontal, 24)
        .padding(.top, topInset + 8)
    }

    // MARK: - Loading / Error
    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)
                .scaleEffect(1.2)
            Text(viewModel.loadingProgress ?? "加载中…")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 34))
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button("重试") {
                Task { await viewModel.load() }
            }
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 20).padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
        }
    }

    // MARK: - Keyboard
    private func installKeyboardMonitor() {
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // 仅当 MangaDetailSheet 在最前时响应
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
                    || event.modifierFlags == [] else { return event }

            switch event.keyCode {
            case 123: // ← 左
                viewModel.previousPage()
                return nil
            case 124: // → 右
                viewModel.nextPage()
                return nil
            case 125: // ↓ 下
                viewModel.nextPage()
                return nil
            case 126: // ↑ 上
                viewModel.previousPage()
                return nil
            case 49:  // space
                viewModel.nextPage()
                return nil
            case 53:  // esc
                if CropAdjustOverlayController.shared.isAdjusting { return event }
                dismiss()
                return nil
            default:
                return event
            }
        }
    }

    // MARK: - Author manga

    @ViewBuilder
    private var authorMangaSheetOverlay: some View {
        if showAuthorMangaSheet, let uploader = cachedAuthorMangaUploader {
            AuthorWallpaperSheet(
                uploader: uploader,
                sourceName: "Pixiv",
                contentTitle: "作者漫画",
                wallpapers: authorMangaItems,
                isLoading: isLoadingAuthorManga,
                hasMore: hasMoreAuthorManga,
                activeWallpaperID: "pixiv_\(route.illustId)",
                onSelectWallpaper: navigateToAuthorManga,
                onDismiss: dismissAuthorMangaSheet,
                onLoadMore: loadMoreAuthorManga,
                onDownloadAll: nil,
                isDownloadingAll: $isDownloadingAuthorManga
            )
            .transition(.identity)
            .zIndex(100)
        }
    }

    private func openAuthorMangaSheet() {
        guard let authorID = viewModel.authorID else { return }

        showAuthorMangaSheet = true
        authorMangaItems = []
        authorMangaPage = 1
        hasMoreAuthorManga = true
        isLoadingAuthorManga = true
        cachedAuthorMangaUploader = Wallpaper.Uploader(
            username: viewModel.authorName,
            group: "pixiv",
            avatar: Wallpaper.Avatar(px200: "", px128: "", px32: "", px20: "")
        )

        Task {
            do {
                let page = try await viewModel.fetchAuthorManga(page: 1, limit: 24)
                guard viewModel.authorID == authorID else { return }
                authorMangaItems = page.items
                hasMoreAuthorManga = page.hasMore
                isLoadingAuthorManga = false
                if let uploader = page.items.first?.uploader {
                    cachedAuthorMangaUploader = uploader
                }
            } catch {
                AppLogger.error(.wallpaper, "加载作者漫画失败", metadata: [
                    "author": authorID,
                    "error": error.localizedDescription
                ])
                isLoadingAuthorManga = false
            }
        }
    }

    private func loadMoreAuthorManga() {
        guard !isLoadingAuthorManga, hasMoreAuthorManga else { return }
        isLoadingAuthorManga = true
        let nextPage = authorMangaPage + 1

        Task {
            do {
                let page = try await viewModel.fetchAuthorManga(page: nextPage, limit: 24)
                let existingIDs = Set(authorMangaItems.map(\.id))
                let fresh = page.items.filter { !existingIDs.contains($0.id) }
                authorMangaItems.append(contentsOf: fresh)
                authorMangaPage = nextPage
                // 无新增时停止，避免重复页 + sentinel 重建形成死循环
                hasMoreAuthorManga = page.hasMore && !fresh.isEmpty
                isLoadingAuthorManga = false
            } catch {
                AppLogger.error(.wallpaper, "加载更多作者漫画失败", metadata: [
                    "author": viewModel.authorID ?? "unknown",
                    "page": nextPage,
                    "error": error.localizedDescription
                ])
                isLoadingAuthorManga = false
            }
        }
    }

    private func dismissAuthorMangaSheet() {
        showAuthorMangaSheet = false
        authorMangaItems = []
        authorMangaPage = 1
        hasMoreAuthorManga = true
        isLoadingAuthorManga = false
        cachedAuthorMangaUploader = nil
    }

    private func navigateToAuthorManga(_ wallpaper: Wallpaper) {
        guard wallpaper.isPixivManga else { return }
        dismissAuthorMangaSheet()
        onNavigateToManga(MangaRoutePayload(
            source: .pixiv,
            illustId: String(wallpaper.id.dropFirst("pixiv_".count)),
            seedTitle: wallpaper.title,
            seedCoverURL: wallpaper.path
        ))
    }
}

// MARK: - MangaReaderView

@MainActor
private struct MangaReaderView: View {
    @ObservedObject var viewModel: MangaDetailViewModel

    // 竖屏滚动预加载追踪
    @State private var cachedContentHeight: CGFloat = 0
    @State private var cachedVisibleHeight: CGFloat = 0
    @State private var estimatedScrollOffset: CGFloat = 0
    @State private var wheelMonitor: Any?
    /// 滚轮事件发布器（NSEvent.addLocalMonitorForEvents → PassthroughSubject）
    @State private var wheelPublisher: PassthroughSubject<CGFloat, Never> = .init()

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.black.opacity(0.35))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(.white.opacity(0.08), lineWidth: 0.5)
                )

            Group {
                switch viewModel.readerMode {
                case .singlePage:
                    singlePageReader
                case .verticalScroll:
                    verticalScrollReader
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            // 底部翻页条：仅单页模式显示（滚动模式靠手势滚动，不需要翻页）
            if viewModel.readerMode == .singlePage {
                VStack {
                    Spacer()
                    pageNavBar
                        .padding(.bottom, 14)
                }
            }
        }
        .onAppear { installWheelMonitor() }
        .onDisappear {
            if let monitor = wheelMonitor {
                NSEvent.removeMonitor(monitor)
                wheelMonitor = nil
            }
        }
    }

    // 单页模式
    private var singlePageReader: some View {
        ZStack {
            if let page = currentMangaPage() {
                ZoomableAsyncImage(urlString: page.readerURL)
                    .transition(.opacity.animation(.easeInOut(duration: 0.18)))
                    .id(page.id)
            } else {
                emptyReader
            }

            // 左右点击区翻页
            HStack(spacing: 0) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { viewModel.previousPage() }
                    .frame(maxWidth: .infinity)
                Color.clear
                    .frame(width: 0)
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { viewModel.nextPage() }
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // 纵向卷轴模式
    private var verticalScrollReader: some View {
        GeometryReader { outer in
            let pageH = outer.size.height   // 每页行高 = 可视高度
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 2) {
                    ForEach(viewModel.currentPages) { page in
                        // 用 KFImage 而非 AsyncImage，以继承全局 Kingfisher
                        // imageModifier（pixiv.net Referer）避免 403
                        KFImage(URL(string: page.readerURL))
                            .cacheMemoryOnly(false)
                            .fade(duration: 0.2)
                            .placeholder {
                                ZStack {
                                    Color(hex: "1A1A1E")
                                    ProgressView().tint(.white)
                                }
                                .frame(minHeight: 200)
                            }
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            // 与翻页模式（singlePageReader / ZoomableAsyncImage）保持一致：
                            // 翻页模式把图约束在 (containerWidth, containerHeight) 内按 .fit 缩放，
                            // 竖长图受高度限制 → 实际显示宽度 < 容器宽度、左右留白。
                            // 滚动模式给每一页一个"可视高度"的行高，同样用 .fit，
                            // 即可得到与翻页模式一致的显示宽度，且能纵向滚动逐页查看。
                            .frame(width: outer.size.width - 16, height: pageH)
                            .frame(maxWidth: .infinity) // 水平居中（左右留白对齐翻页模式）
                            .id(page.id)
                    }
                    // 底部占位：通过 PreferenceKey 上报内容总高度
                    Color.clear
                        .frame(height: 1)
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: MangaContentHeightKey.self,
                                    value: proxy.frame(in: .named("mangaScroll")).maxY
                                )
                            }
                        )
                }
                .padding(8)
                // 读取整个 LazyVStack 在滚动坐标空间中的偏移，推算当前可视页
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: MangaScrollOffsetKey.self,
                            value: -proxy.frame(in: .named("mangaScroll")).minY
                        )
                    }
                )
            }
            .coordinateSpace(name: "mangaScroll")
            .onPreferenceChange(MangaContentHeightKey.self) { h in
                self.cachedContentHeight = h
            }
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: MangaVisibleHeightKey.self,
                        value: proxy.size.height
                    )
                }
            )
            .onPreferenceChange(MangaVisibleHeightKey.self) { h in
                self.cachedVisibleHeight = h
            }
            // 真实滚动偏移 → 推算当前可视页索引 → 触发预加载
            // 比原来基于滚轮累加的 estimatedScrollOffset 更可靠（不受惯性/触控板动量影响）
            .onPreferenceChange(MangaScrollOffsetKey.self) { offset in
                guard pageH > 0 else { return }
                // 当前可视页 = floor(offset / pageH)，clamp 到合法范围
                let visibleIndex = max(0, min(Int(offset / pageH), max(0, viewModel.currentPages.count - 1)))
                viewModel.updateCurrentPageForScroll(visibleIndex)
            }
            .onReceive(wheelPublisher) { deltaY in
                // 保留滚轮监听作为接近底部时的额外预加载兜底
                guard viewModel.readerMode == .verticalScroll else { return }
                estimatedScrollOffset -= deltaY
                estimatedScrollOffset = max(0, min(estimatedScrollOffset, max(0, cachedContentHeight - cachedVisibleHeight)))
                let distanceToBottom = cachedContentHeight - (estimatedScrollOffset + cachedVisibleHeight)
                if distanceToBottom < 600 {
                    viewModel.prefetchPages(ahead: 5)
                }
            }
        }
    }

    private var emptyReader: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 42))
                .foregroundStyle(.white.opacity(0.3))
            Text("暂无可阅读页面")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    private func currentMangaPage() -> MangaPage? {
        let pages = viewModel.currentPages
        let idx = viewModel.currentPageIndex
        guard pages.indices.contains(idx) else { return nil }
        return pages[idx]
    }

    // 底部导航
    private var pageNavBar: some View {
        HStack(spacing: 16) {
            Button {
                viewModel.previousPage()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(viewModel.hasPreviousPage ? .white : .white.opacity(0.3))
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.hasPreviousPage)

            Text("\(viewModel.currentPageIndex + 1) / \(max(1, viewModel.totalPageCount))")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(minWidth: 70)

            Button {
                viewModel.nextPage()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(viewModel.hasNextPage ? .white : .white.opacity(0.3))
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.hasNextPage)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.08), lineWidth: 0.5))
    }

    /// 监听滚轮事件 → 估算 ScrollView 偏移量 → 接近底部触发 prefetchPages
    private func installWheelMonitor() {
        // 避免重复安装
        if wheelMonitor != nil { return }
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            let dy = event.scrollingDeltaY
            // 向上滚（dy>0）：内容下移 → contentOffset 减小
            // 向下滚（dy<0）：内容上移 → contentOffset 增大
            wheelPublisher.send(dy)
            return event
        }
    }
}

// MARK: - ZoomableAsyncImage（异步 + 双指缩放 + 双击放大）

private struct ZoomableAsyncImage: View {
    let urlString: String

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            KFImage(URL(string: urlString))
                .cacheMemoryOnly(false)
                .fade(duration: 0.2)
                .placeholder { _ in
                    ZStack {
                        Color(hex: "1A1A1E")
                        ProgressView().tint(.white)
                    }
                }
                .resizable()
                .aspectRatio(contentMode: .fit)
                .scaleEffect(scale)
                .offset(offset)
                .frame(width: geo.size.width, height: geo.size.height)
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            let delta = value / lastScale
                            lastScale = value
                            scale = min(max(scale * delta, 1.0), 5.0)
                        }
                        .onEnded { _ in
                            lastScale = 1.0
                            if scale < 1.05 {
                                withAnimation(.spring()) {
                                    scale = 1.0
                                    offset = .zero
                                }
                            }
                        }
                )
                .onTapGesture(count: 2) {
                    withAnimation(.spring()) {
                        if scale > 1.05 {
                            scale = 1.0
                            offset = .zero
                        } else {
                            scale = 2.0
                        }
                    }
                }
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { value in
                            guard scale > 1.05 else { return }
                            offset = CGSize(
                                width: lastOffset.width + value.translation.width,
                                height: lastOffset.height + value.translation.height
                            )
                        }
                        .onEnded { _ in
                            lastOffset = offset
                        }
                )
        }
    }
}

// MARK: - MangaSidePanel

private struct MangaSidePanel: View {
    @ObservedObject var viewModel: MangaDetailViewModel
    let onShowAuthorManga: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            infoHeader
            Divider().background(.white.opacity(0.08))
            chapterList
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.black.opacity(0.35))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(.white.opacity(0.08), lineWidth: 0.5)
                )
        )
    }

    private var infoHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            KFImage(URL(string: viewModel.series?.coverURL ?? ""))
                .cacheMemoryOnly(true)
                .fade(duration: 0.2)
                .placeholder { _ in Color(hex: "1A1A1E") }
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(height: 140)
                .frame(maxWidth: .infinity)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            Text(viewModel.seriesTitle)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)

            if viewModel.authorID != nil {
                Button(action: onShowAuthorManga) {
                    HStack(spacing: 5) {
                        Text("by \(viewModel.authorName)")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
                }
                .buttonStyle(.plain)
                .help("查看该作者的漫画")
                .onHover { hovering in
                    if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
            } else {
                Text("by \(viewModel.authorName)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
            }

            if !viewModel.seriesTags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(viewModel.seriesTags.prefix(6), id: \.self) { tag in
                            Text(tag)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.85))
                                .padding(.horizontal, 8)
                                .frame(height: 22)
                                .detailGlassCapsuleChrome(level: .prominent)
                        }
                    }
                }
            }
        }
    }

    private var chapterList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("章节")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Text("\(viewModel.chapters.count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
            }

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(Array(viewModel.chapters.enumerated()), id: \.element.id) { idx, ch in
                        let isCurrent = ch.id == viewModel.currentChapter?.id
                        Button {
                            Task { await viewModel.select(chapter: ch) }
                        } label: {
                            HStack(spacing: 10) {
                                Text("\(idx + 1)")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(isCurrent ? .black : .white.opacity(0.7))
                                    .frame(width: 26, height: 26)
                                    .background(
                                        Circle().fill(isCurrent ? Color.white : Color.white.opacity(0.12))
                                    )

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(ch.title)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                    Text("\(ch.pageCount > 0 ? "\(ch.pageCount) 页" : "页数未知")")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.white.opacity(0.5))
                                }

                                Spacer(minLength: 0)

                                if isCurrent {
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.white)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(isCurrent ? Color.white.opacity(0.14) : Color.white.opacity(0.05))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(isCurrent ? .white.opacity(0.3) : .white.opacity(0.06), lineWidth: 0.5)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

// MARK: - 竖屏滚动追踪 PreferenceKey

private struct MangaContentHeightKey: PreferenceKey {
    static nonisolated(unsafe) var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct MangaVisibleHeightKey: PreferenceKey {
    static nonisolated(unsafe) var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// 滚动模式：整个内容在滚动坐标空间中的纵向偏移（用于推算当前可视页索引）
private struct MangaScrollOffsetKey: PreferenceKey {
    static nonisolated(unsafe) var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
