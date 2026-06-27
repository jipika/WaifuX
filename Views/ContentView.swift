import SwiftUI
import AppKit
import Kingfisher
import AVFoundation

/// macOS 15+ 的 Liquid Glass 改变了标题栏 safe area 行为，
/// NSHostingController 会报告标题栏高度作为 top safe area，
/// 但我们的 UI 已经通过 fullSizeContentView 自行处理布局。
/// 使用 SwiftUI 的 .ignoresSafeArea() 在视图层面解决。
private struct EdgeToEdgeContainer<Content: View>: View {
    let content: Content

    var body: some View {
        if #available(macOS 15.0, *) {
            content.ignoresSafeArea(.container, edges: .top)
        } else {
            content
        }
    }
}

@MainActor
private final class MainContentNavigationState: ObservableObject {
    @Published var selectedTab: MainTab = .home
    @Published var selectedWallpaper: Wallpaper?
    @Published var selectedMedia: MediaItem?
    @Published var selectedAnime: AnimeSearchResult?
    @Published var librarySelectedAnime: AnimeSearchResult?
    @Published var librarySelectedWallpaper: Wallpaper?
    @Published var librarySelectedMedia: MediaItem?
    @Published var libraryWallpaperContext: [Wallpaper] = []
    @Published var libraryMediaContext: [MediaItem] = []

    func binding<Value>(for keyPath: ReferenceWritableKeyPath<MainContentNavigationState, Value>) -> Binding<Value> {
        Binding(
            get: { self[keyPath: keyPath] },
            set: { self[keyPath: keyPath] = $0 }
        )
    }

    func resetForMemoryRelease() {
        selectedWallpaper = nil
        selectedMedia = nil
        selectedAnime = nil
        librarySelectedAnime = nil
        librarySelectedWallpaper = nil
        librarySelectedMedia = nil
        libraryWallpaperContext.removeAll()
        libraryMediaContext.removeAll()
        selectedTab = .home
    }
}

private struct MainTabContainerView: NSViewControllerRepresentable {
    @ObservedObject var navigationState: MainContentNavigationState
    @ObservedObject var wallpaperViewModel: WallpaperViewModel
    @ObservedObject var mediaViewModel: MediaExploreViewModel
    @ObservedObject var animeViewModel: AnimeViewModel

    func makeNSViewController(context: Context) -> MainTabViewController {
        let controller = MainTabViewController()
        controller.configure(
            navigationState: navigationState,
            wallpaperViewModel: wallpaperViewModel,
            mediaViewModel: mediaViewModel,
            animeViewModel: animeViewModel
        )
        return controller
    }

    func updateNSViewController(_ controller: MainTabViewController, context: Context) {
        controller.select(tab: navigationState.selectedTab)
    }
}

private enum MainDetailRoute: Hashable {
    case wallpaper(Wallpaper, context: [Wallpaper]?)
    case media(MediaItem, context: [MediaItem]?)
    case anime(AnimeSearchResult)
}

@MainActor
private final class MainTabViewController: NSTabViewController {
    private var isConfigured = false
    /// 实际添加的 tab 顺序（仅含启动快照启用的 tab），用于 select(tab:) 查找真实 index。
    /// 在 configure 一次性构建（快照不变），禁用的 tab 不加入，避免位置 Int 错位。
    private var addedTabs: [MainTab] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        tabStyle = .unspecified
        tabView.tabViewType = .noTabsNoBorder
    }

    func configure(
        navigationState: MainContentNavigationState,
        wallpaperViewModel: WallpaperViewModel,
        mediaViewModel: MediaExploreViewModel,
        animeViewModel: AnimeViewModel
    ) {
        guard !isConfigured else {
            select(tab: navigationState.selectedTab)
            return
        }

        // 按 MainTab.allCases 顺序（home → wallpaperExplore → animeExplore → mediaExplore → myMedia）
        // 仅添加启动快照启用的 tab。home/myMedia 永远启用；三个 Explore 受 ModuleAvailability 门控。
        for tab in MainTab.allCases where ModuleAvailability.shared.isTabEnabled(tab) {
            switch tab {
            case .home:
                addPage(title: tab.title, view: HomeTabPage(
                    navigationState: navigationState,
                    wallpaperViewModel: wallpaperViewModel,
                    mediaViewModel: mediaViewModel
                ))
            case .wallpaperExplore:
                addPage(title: tab.title, view: WallpaperExploreTabPage(
                    navigationState: navigationState,
                    wallpaperViewModel: wallpaperViewModel
                ))
            case .animeExplore:
                addPage(title: tab.title, view: AnimeExploreTabPage(
                    navigationState: navigationState,
                    animeViewModel: animeViewModel
                ))
            case .mediaExplore:
                addPage(title: tab.title, view: MediaExploreTabPage(
                    navigationState: navigationState,
                    mediaViewModel: mediaViewModel
                ))
            case .myMedia:
                addPage(title: tab.title, view: MyLibraryTabPage(
                    navigationState: navigationState,
                    wallpaperViewModel: wallpaperViewModel,
                    mediaViewModel: mediaViewModel
                ))
            }
            addedTabs.append(tab)
        }

        isConfigured = true
        select(tab: navigationState.selectedTab)
    }

    func select(tab: MainTab) {
        // 用 addedTabs 的真实位置查找，不依赖固定 controllerIndex（禁用 tab 后会错位）。
        guard let targetIndex = addedTabs.firstIndex(of: tab) else {
            // tab 被禁用（不在 addedTabs 中），回退到 home
            if let homeIndex = addedTabs.firstIndex(of: .home) {
                if selectedTabViewItemIndex != homeIndex {
                    selectedTabViewItemIndex = homeIndex
                }
            }
            return
        }
        guard selectedTabViewItemIndex != targetIndex else { return }
        selectedTabViewItemIndex = targetIndex
    }

    private func addPage<Content: View>(title: String, view: Content) {
        let hostingController = NSHostingController(rootView: EdgeToEdgeContainer(content: view))
        let item = NSTabViewItem(viewController: hostingController)
        item.label = title
        addTabViewItem(item)
    }
}

private struct HomeTabPage: View {
    @ObservedObject var navigationState: MainContentNavigationState
    @ObservedObject var wallpaperViewModel: WallpaperViewModel
    @ObservedObject var mediaViewModel: MediaExploreViewModel

    var body: some View {
        HomeContentView(
            viewModel: wallpaperViewModel,
            mediaViewModel: mediaViewModel,
            selectedWallpaper: navigationState.binding(for: \.selectedWallpaper),
            selectedMedia: navigationState.binding(for: \.selectedMedia),
            isTabActive: navigationState.selectedTab == .home
        )
        .environment(\.coverGIFPlaybackHostActive, navigationState.selectedTab == .home)
    }
}

private struct WallpaperExploreTabPage: View {
    @ObservedObject var navigationState: MainContentNavigationState
    @ObservedObject var wallpaperViewModel: WallpaperViewModel

    var body: some View {
        WallpaperExploreContentView(
            viewModel: wallpaperViewModel,
            selectedWallpaper: navigationState.binding(for: \.selectedWallpaper),
            isVisible: navigationState.selectedTab == .wallpaperExplore
        )
        .environment(\.coverGIFPlaybackHostActive, navigationState.selectedTab == .wallpaperExplore)
    }
}

private struct AnimeExploreTabPage: View {
    @ObservedObject var navigationState: MainContentNavigationState
    @ObservedObject var animeViewModel: AnimeViewModel

    var body: some View {
        AnimeExploreView(
            viewModel: animeViewModel,
            selectedAnime: navigationState.binding(for: \.selectedAnime),
            isVisible: navigationState.selectedTab == .animeExplore
        )
        .environment(\.coverGIFPlaybackHostActive, navigationState.selectedTab == .animeExplore)
    }
}

private struct MediaExploreTabPage: View {
    @ObservedObject var navigationState: MainContentNavigationState
    @ObservedObject var mediaViewModel: MediaExploreViewModel

    var body: some View {
        MediaExploreContentView(
            viewModel: mediaViewModel,
            selectedMedia: navigationState.binding(for: \.selectedMedia),
            isVisible: navigationState.selectedTab == .mediaExplore
        )
        .environment(\.coverGIFPlaybackHostActive, navigationState.selectedTab == .mediaExplore)
    }
}

private struct MyLibraryTabPage: View {
    @ObservedObject var navigationState: MainContentNavigationState
    @ObservedObject var wallpaperViewModel: WallpaperViewModel
    @ObservedObject var mediaViewModel: MediaExploreViewModel

    var body: some View {
        MyLibraryContentView(
            viewModel: wallpaperViewModel,
            mediaViewModel: mediaViewModel,
            selectedWallpaper: navigationState.binding(for: \.librarySelectedWallpaper),
            selectedMedia: navigationState.binding(for: \.librarySelectedMedia),
            selectedAnime: navigationState.binding(for: \.librarySelectedAnime),
            wallpaperContext: navigationState.binding(for: \.libraryWallpaperContext),
            mediaContext: navigationState.binding(for: \.libraryMediaContext),
            isVisible: navigationState.selectedTab == .myMedia
        )
        .environment(\.coverGIFPlaybackHostActive, navigationState.selectedTab == .myMedia)
    }
}

struct ContentView: View {
    // 全局 ViewModel：由 AppDelegate 持有，通过 init 参数注入；
    // 用普通 let 持有而非 @StateObject —— ContentView 本身不响应这 3 个 ViewModel 的
    // @Published 变化（body 内只命令式调用其方法，不读响应式属性），从而不会因
    // 例如 LocalWallpaperScanner 完成时 WallpaperViewModel 的多次 @Published 更新
    // 而连锁触发整个 ContentView body 及下游 tab 子视图的反复重算。
    // 子视图（5 个 TabPage）继续以 @ObservedObject 接收这些 ViewModel —— 该响应链是必要的。
    let viewModel: WallpaperViewModel
    let mediaViewModel: MediaExploreViewModel
    let animeViewModel: AnimeViewModel

    @StateObject private var navigationState = MainContentNavigationState()
    @StateObject private var guessYouLikeVM = GuessYouLikeViewModel()
    @ObservedObject private var localization = LocalizationService.shared
    // 注意：WallpaperSourceManager.shared 不在此顶层观察。
    // 它有 5 个 @Published 属性，若顶层 @ObservedObject 会在数据源切换时触发整个 ContentView body 重算。
    // 顶层仅在 .task 中一次性轮询 isInitialSourceSelectionComplete，无需响应式；
    // 数据源切换提示由独立的 SourceSwitchToast / WorkshopSourceSwitchToast 子视图各自观察。
    @State private var detailPath: [MainDetailRoute] = []

    init(
        wallpaperViewModel: WallpaperViewModel,
        mediaViewModel: MediaExploreViewModel,
        animeViewModel: AnimeViewModel
    ) {
        self.viewModel = wallpaperViewModel
        self.mediaViewModel = mediaViewModel
        self.animeViewModel = animeViewModel
    }

    var body: some View {
        // 性能测量：开启 PERF_TRACE 编译标记后，会在控制台打印触发本 body 的属性来源
        #if PERF_TRACE
        let _ = Self._printChanges()
        #endif
        ZStack {
            NavigationStack(path: $detailPath) {
                mainContent
                    .navigationDestination(for: MainDetailRoute.self) { route in
                        detailDestination(for: route)
                    }
            }

            globalOverlayLayer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            AppResponsivenessMonitor.noteTabChange(navigationState.selectedTab.title)
            AppResponsivenessMonitor.noteDetailDepth(detailPath.count)
            AppResponsivenessMonitor.noteScenePhase("contentViewVisible")
        }
        .onChange(of: navigationState.selectedTab) { _, tab in
            AppResponsivenessMonitor.noteTabChange(tab.title)
        }
        .onChange(of: detailPath.count) { _, depth in
            AppResponsivenessMonitor.noteDetailDepth(depth)
        }
        .onChange(of: navigationState.selectedWallpaper) { _, wallpaper in
            guard let wallpaper else { return }
            openDetail(.wallpaper(wallpaper, context: nil))
        }
        .onChange(of: navigationState.selectedMedia) { _, item in
            guard let item else { return }
            openDetail(.media(item, context: nil))
        }
        .onChange(of: navigationState.selectedAnime) { _, anime in
            guard let anime else { return }
            openDetail(.anime(anime))
        }
        .onChange(of: navigationState.librarySelectedWallpaper) { _, wallpaper in
            guard let wallpaper else { return }
            let context = navigationState.libraryWallpaperContext.isEmpty ? nil : navigationState.libraryWallpaperContext
            openDetail(.wallpaper(wallpaper, context: context))
        }
        .onChange(of: navigationState.librarySelectedMedia) { _, item in
            guard let item else { return }
            let context = navigationState.libraryMediaContext.isEmpty ? nil : navigationState.libraryMediaContext
            openDetail(.media(item, context: context))
        }
        .onChange(of: navigationState.librarySelectedAnime) { _, anime in
            guard let anime else { return }
            openDetail(.anime(anime))
        }
        .task {
            // ⚠️ 等待启动时数据源选择完成（ping Google 决策）
            // 在确定数据源之前不加载壁纸列表数据
            // 直接读单例（非观察）：isInitialSourceSelectionComplete 只在启动决策时变化一次，无需响应式
            let sourceManager = WallpaperSourceManager.shared
            if !sourceManager.isInitialSourceSelectionComplete {
                print("[ContentView] Waiting for initial source selection...")
                // 最多等待 10 秒超时
                for _ in 0..<20 {
                    try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
                    if sourceManager.isInitialSourceSelectionComplete {
                        break
                    }
                }
            }

            // 数据源确定后再加载首页数据（各管线按功能模块开关门控）
            try? await Task.sleep(nanoseconds: 300_000_000) // 0.3s
            if ModuleAvailability.shared.wallpaperEnabled {
                await viewModel.initialLoad()
            }

            if ModuleAvailability.shared.mediaEnabled {
                Task(priority: .utility) {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    await mediaViewModel.initialLoadIfNeeded()
                }
            }

            // 预加载猜你喜欢数据（后台静默加载，确保点击弹窗时数据已就绪）
            // 猜你喜欢依赖壁纸数据，壁纸模块关闭时跳过
            if ModuleAvailability.shared.wallpaperEnabled {
                guessYouLikeVM.preload()
            }

            // Sparkle 自动按 SUScheduledCheckInterval (24h) 检查更新，无需手动触发
        }
        .ignoresSafeArea()
        .applyTheme()
    }

    private var globalOverlayLayer: some View {
        ZStack {
            // 下载进度与来源切换提示必须挂在 NavigationStack 外，保证详情页里也可见。
            VStack {
                Spacer()
                DownloadProgressToastHost(
                    onDismiss: { snapshot in
                        handleDownloadToastDismiss(snapshot)
                    },
                    onCancel: { snapshot in
                        handleDownloadToastCancel(snapshot)
                    },
                    onRetry: { snapshot in
                        handleDownloadToastRetry(snapshot)
                    }
                )
                WallpaperSourceSwitchToast()
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
                WorkshopSourceSwitchToast()
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)
            }
            .zIndex(400)

            // 显示器选择弹窗覆盖层
            DisplaySelectorOverlay()
                .zIndex(700)

            // 猜你喜欢覆盖层
            if guessYouLikeVM.isShowing {
                GuessYouLikeOverlay(
                    viewModel: guessYouLikeVM,
                    onDetail: { [self] item in
                        handleGuessYouLikeDetail(item)
                    },
                    onDownload: { [self] item in
                        handleGuessYouLikeDownload(item)
                    }
                )
                .zIndex(800)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(true)
    }

    private var mainContent: some View {
        mainContentBase
            .environment(\.mainTopBarContentPadding, MainTopBarLayout.legacyContentTopPadding)
            .overlay(alignment: .top) {
                topNavigationBar
            }
    }

    private var mainContentBase: some View {
        ZStack {
            Color(hex: "0D0D0D")
                .ignoresSafeArea()

            MainTabContainerView(
                navigationState: navigationState,
                wallpaperViewModel: viewModel,
                mediaViewModel: mediaViewModel,
                animeViewModel: animeViewModel
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onReceive(NotificationCenter.default.publisher(for: .appShouldReleaseForegroundMemory)) { _ in
                releaseForegroundMemory()
            }
            .onReceive(NotificationCenter.default.publisher(for: .switchToLibraryTab)) { _ in
                navigationState.selectedTab = .myMedia
            }
            .id(localization.currentLanguage)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationBarBackButtonHidden(true)
        .toolbar(navigationState.selectedTab == .myMedia ? .visible : .hidden, for: .automatic)
    }

    private var topNavigationBar: some View {
        TopNavigationBar(
            selectedTab: navigationState.binding(for: \.selectedTab),
            onOpenSettings: { openSettingsWindow() },
            onGuessYouLike: { guessYouLikeVM.show() },
            onClose: { hideMainWindow() },
            onMinimize: { minimizeWindow() },
            onMaximize: { maximizeWindow() },
            onZoom: { zoomWindow() }
        )
        .zIndex(100)
    }

    private func minimizeWindow() {
        NSApp.mainWindow?.miniaturize(nil)
    }

    private func maximizeWindow() {
        guard let window = NSApp.mainWindow else { return }
        window.toggleFullScreen(nil)
    }

    @ViewBuilder
    private func detailDestination(for route: MainDetailRoute) -> some View {
        switch route {
        case .wallpaper(let wallpaper, let context):
            WallpaperDetailSheet(
                wallpaper: wallpaper,
                viewModel: viewModel,
                contextWallpapers: context,
                onClose: popDetail,
                onNavigateToWallpaper: { selected in
                    detailPath.append(.wallpaper(selected, context: context))
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationBarBackButtonHidden(true)
            .toolbar(.hidden, for: .automatic)

        case .media(let item, let context):
            MediaDetailSheet(
                item: item,
                viewModel: mediaViewModel,
                contextItems: context,
                onClose: popDetail,
                onNavigateToItem: { selected in
                    detailPath.append(.media(selected, context: context))
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationBarBackButtonHidden(true)
            .toolbar(.hidden, for: .automatic)

        case .anime(let anime):
            AnimeDetailSheet(
                anime: anime,
                isPresented: Binding(
                    get: { !detailPath.isEmpty },
                    set: { if !$0 { popDetail() } }
                )
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
            .navigationBarBackButtonHidden(true)
            .toolbar(.hidden, for: .automatic)
        }
    }

    private func openDetail(_ route: MainDetailRoute) {
        detailPath = [route]
        // 仅清除触发当前导航的那个 binding，避免 5 个无关的 onChange 空跑
        switch route {
        case .wallpaper:
            navigationState.selectedWallpaper = nil
        case .media:
            navigationState.selectedMedia = nil
        case .anime:
            navigationState.selectedAnime = nil
        }
    }

    private func popDetail() {
        if !detailPath.isEmpty {
            detailPath.removeLast()
        }
        if detailPath.isEmpty {
            clearSelectedDetailBindings()
        }
    }

    // MARK: - 猜你喜欢回调

    /// 将 GuessYouLikeItem 映射到 Wallpaper（用于详情与下载）
    private func resolveWallpaper(from item: GuessYouLikeItem) -> Wallpaper {
        let imageURL = item.imageURL
        return Wallpaper(
            id: item.id,
            url: item.destination,
            shortUrl: nil,
            views: 0,
            favorites: 0,
            downloads: nil,
            source: nil,
            purity: "sfw",
            category: "general",
            dimensionX: 0,
            dimensionY: 0,
            resolution: item.subtitle,
            ratio: "",
            fileSize: nil,
            fileType: nil,
            createdAt: nil,
            colors: [],
            path: imageURL,
            thumbs: Wallpaper.Thumbs(large: imageURL, original: imageURL, small: imageURL),
            tags: nil,
            uploader: nil
        )
    }

    /// 将 GuessYouLikeItem 映射到 MediaItem（用于详情）
    private func resolveMediaItem(from item: GuessYouLikeItem) -> MediaItem {
        MediaItem(
            slug: item.id,
            title: item.title,
            pageURL: URL(string: item.destination)
                ?? URL(string: "https://example.com")!,
            thumbnailURL: URL(string: item.imageURL)
                ?? URL(string: "https://example.com")!,
            resolutionLabel: item.subtitle,
            collectionTitle: item.sourceName,
            summary: nil,
            previewVideoURL: nil,
            posterURL: URL(string: item.imageURL),
            tags: [],
            exactResolution: nil,
            durationSeconds: nil,
            downloadOptions: [],
            sourceName: item.sourceName,
            isAnimatedImage: nil
        )
    }

    private func handleGuessYouLikeDetail(_ item: GuessYouLikeItem) {
        guessYouLikeVM.dismiss()
        switch item.contentType {
        case .wallpaper:
            let wp = resolveWallpaper(from: item)
            // 通过 NavigationStack 打开详情
            navigationState.selectedWallpaper = wp
        case .video, .anime:
            let media = resolveMediaItem(from: item)
            navigationState.selectedMedia = media
        }
    }

    private func handleGuessYouLikeDownload(_ item: GuessYouLikeItem) {
        guessYouLikeVM.dismiss()
        switch item.contentType {
        case .wallpaper:
            let wp = resolveWallpaper(from: item)
            Task {
                do {
                    try await viewModel.downloadWallpaper(wp)
                } catch {
                    AppLogger.error(.download, "猜你喜欢下载壁纸失败",
                        metadata: ["id": wp.id, "error": error.localizedDescription])
                }
            }
        case .video, .anime:
            let media = resolveMediaItem(from: item)
            Task {
                do {
                    // Wallpaper Engine 走专用下载路径
                    if item.sourceName == "Wallpaper Engine" {
                        let workshopItem = MediaItem(
                            slug: "workshop_\(item.id)",
                            title: item.title,
                            pageURL: URL(string: item.destination)
                                ?? URL(string: "https://example.com")!,
                            thumbnailURL: URL(string: item.imageURL)
                                ?? URL(string: "https://example.com")!,
                            resolutionLabel: item.subtitle,
                            collectionTitle: item.sourceName,
                            sourceName: item.sourceName
                        )
                        try await mediaViewModel.downloadWorkshopWallpaper(workshopItem)
                        return
                    }

                    // 1. 加载详情获取 downloadOptions（与详情页 downloadMedia 逻辑一致）
                    let resolved = try await mediaViewModel.loadDetail(for: media)
                    // 2. 自动选择最高画质（与详情页一致）
                    guard let best = resolved.downloadOptions.max(by: {
                        if $0.qualityRank == $1.qualityRank {
                            return $0.fileSizeMegabytes < $1.fileSizeMegabytes
                        }
                        return $0.qualityRank < $1.qualityRank
                    }) else {
                        throw NetworkError.invalidResponse
                    }
                    // 3. 走标准下载流程，自动触发 DownloadProgressToastHost
                    _ = try await mediaViewModel.downloadMedia(resolved, option: best)
                } catch {
                    AppLogger.error(.download, "猜你喜欢下载媒体失败",
                        metadata: ["id": media.id, "error": error.localizedDescription])
                    // 自动下载失败时 fallback 到详情页，让用户手动下载
                    await MainActor.run {
                        navigationState.selectedMedia = media
                    }
                }
            }
        }
    }

    private func clearSelectedDetailBindings() {
        navigationState.selectedWallpaper = nil
        navigationState.selectedMedia = nil
        navigationState.selectedAnime = nil
        navigationState.librarySelectedWallpaper = nil
        navigationState.librarySelectedMedia = nil
        navigationState.librarySelectedAnime = nil
    }

    private func zoomWindow() {
        NSApp.mainWindow?.zoom(nil)
    }

    private func openSettingsWindow() {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return }
        appDelegate.showSettingsWindow(nil)
    }

    private func hideMainWindow() {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return }
        appDelegate.hideMainWindow()
    }

    private func releaseForegroundMemory() {
        ForegroundPrefetchManager.shared.stopAll()
        viewModel.releaseForegroundMemory()
        mediaViewModel.releaseForegroundMemory()
        animeViewModel.releaseForegroundMemory()
        detailPath.removeAll()
        navigationState.resetForMemoryRelease()
    }

    private func handleDownloadToastDismiss(_ snapshot: DownloadToastSnapshot) {
        DownloadTaskService.shared.markToastSuppressed(for: snapshot.id)
    }

    private func handleDownloadToastCancel(_ snapshot: DownloadToastSnapshot) {
        let service = DownloadTaskService.shared
        service.markToastSuppressed(for: snapshot.id)
        service.cancelTask(id: snapshot.id)
        service.removeTask(id: snapshot.id)
    }

    private func handleDownloadToastRetry(_ snapshot: DownloadToastSnapshot) {
        DownloadTaskService.shared.clearToastSuppression(for: snapshot.id)

        guard let task = DownloadTaskService.shared.task(for: snapshot.id) else { return }

        Task {
            do {
                switch task.kind {
                case .wallpaper:
                    try await viewModel.retryDownload(task: task)
                case .media, .workshop:
                    try await mediaViewModel.retryDownload(task: task)
                }
            } catch {
                await MainActor.run {
                    switch task.kind {
                    case .wallpaper:
                        viewModel.errorMessage = error.localizedDescription
                    case .media, .workshop:
                        mediaViewModel.errorMessage = error.localizedDescription
                    }
                }
            }
        }
    }
}

// MARK: - MyMediaContentView 已移除（死代码，未被任何视图引用）

// MARK: - iOS 丝滑风格下载进度弹窗宿主
private struct DownloadProgressToastHost: View {
    @StateObject private var viewModel = DownloadToastViewModel()
    let onDismiss: (DownloadToastSnapshot) -> Void
    let onCancel: (DownloadToastSnapshot) -> Void
    let onRetry: (DownloadToastSnapshot) -> Void

    @State private var displayedSnapshot: DownloadToastSnapshot?
    @State private var hideWorkItem: DispatchWorkItem?

    // iOS 丝滑动画状态
    @State private var toastOpacity: Double = 0
    @State private var toastScale: Double = 0.92
    @State private var toastOffset: CGFloat = 10

    /// 入场动画：轻快弹簧，类似系统通知弹出
    private var iOSShowAnimation: Animation {
        .spring(response: 0.35, dampingFraction: 0.82, blendDuration: 0)
    }

    /// 退场动画：快速利落
    private var iOSDismissAnimation: Animation {
        .easeOut(duration: 0.20)
    }

    var body: some View {
        Group {
            if let snapshot = displayedSnapshot {
                DownloadProgressToast(
                    snapshot: snapshot,
                    activeTaskCount: viewModel.activeTaskCount,
                    steamCMDQueuedCount: viewModel.steamCMDQueuedCount,
                    onDismiss: {
                        dismiss(snapshot)
                    },
                    onCancel: {
                        cancel(snapshot)
                    },
                    onRetry: {
                        retry(snapshot)
                    }
                )
                .frame(maxWidth: 440)
                .padding(.bottom, 26)
                .opacity(toastOpacity)
                .scaleEffect(toastScale, anchor: .bottom)
                .offset(y: toastOffset)
                .transition(
                    .asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .bottom)),
                        removal: .opacity
                    )
                )
            }
        }
        .onAppear {
            reconcileDisplayedSnapshot(viewModel.snapshot)
        }
        .onChange(of: viewModel.snapshot) { _, snapshot in
            reconcileDisplayedSnapshot(snapshot)
        }
    }

    // MARK: - 动画控制

    /// 入场：底部轻弹 + 缩放
    private func performShow() {
        toastOpacity = 0
        toastScale = 0.92
        toastOffset = 8

        withAnimation(iOSShowAnimation) {
            toastOpacity = 1
            toastScale = 1.0
            toastOffset = 0
        }
    }

    /// 退场：向下缩小淡出（精简不卡顿）
    private func performHide(completion: @escaping () -> Void) {
        withAnimation(iOSDismissAnimation) {
            toastOpacity = 0
            toastScale = 0.96
            toastOffset = 6
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
            completion()
        }
    }

    private func reconcileDisplayedSnapshot(_ snapshot: DownloadToastSnapshot?) {
        hideWorkItem?.cancel()

        guard let snapshot else {
            performHide {
                displayedSnapshot = nil
            }
            return
        }

        if viewModel.isSuppressed(taskID: snapshot.id) {
            displayedSnapshot = nil
            return
        }

        if snapshot.isRunning {
            // 如果是新任务或当前无显示任务，重新执行入场动画
            if displayedSnapshot?.id != snapshot.id {
                displayedSnapshot = snapshot
                performShow()
            } else {
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    displayedSnapshot = snapshot
                }
            }
            return
        }

        if snapshot.status == .completed {
            viewModel.clearSuppression(taskID: snapshot.id)
            if displayedSnapshot?.id != snapshot.id {
                displayedSnapshot = snapshot
                performShow()
            }

            let workItem = DispatchWorkItem { [self] in
                performHide {
                    if displayedSnapshot?.id == snapshot.id {
                        displayedSnapshot = nil
                    }
                }
            }
            hideWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: workItem)
            return
        }

        if snapshot.isActionable {
            if displayedSnapshot?.id != snapshot.id {
                displayedSnapshot = snapshot
                performShow()
            } else {
                withAnimation(iOSShowAnimation) {
                    displayedSnapshot = snapshot
                }
            }
            return
        }

        performHide {
            displayedSnapshot = nil
        }
    }

    private func dismiss(_ snapshot: DownloadToastSnapshot) {
        onDismiss(snapshot)
        performHide {
            if displayedSnapshot?.id == snapshot.id {
                displayedSnapshot = nil
            }
        }
    }

    private func cancel(_ snapshot: DownloadToastSnapshot) {
        onCancel(snapshot)
        performHide {
            if displayedSnapshot?.id == snapshot.id {
                displayedSnapshot = nil
            }
        }
    }

    private func retry(_ snapshot: DownloadToastSnapshot) {
        onRetry(snapshot)
        performHide {
            if displayedSnapshot?.id == snapshot.id {
                displayedSnapshot = nil
            }
        }
    }
}

// MARK: - iOS 丝滑风格下载进度 Toast
private struct DownloadProgressToast: View {
    let snapshot: DownloadToastSnapshot
    let activeTaskCount: Int
    let steamCMDQueuedCount: Int
    let onDismiss: () -> Void
    let onCancel: () -> Void
    let onRetry: () -> Void

    @State private var animatedProgress: Double = 0

    private var tint: Color {
        switch snapshot.status {
        case .pending:
            return Color.white.opacity(0.7)
        case .downloading:
            return Color.white.opacity(0.85)
        case .paused:
            return Color.white.opacity(0.6)
        case .completed:
            return LiquidGlassColors.onlineGreen
        case .failed:
            return Color.white.opacity(0.7)
        case .cancelled:
            return Color.white.opacity(0.5)
        }
    }

    private var iconName: String {
        switch snapshot.kind {
        case .wallpaper:
            return "photo.fill"
        case .media:
            return "play.rectangle.fill"
        case .workshop:
            return "gearshape.fill"
        }
    }

    private var statusText: String {
        switch snapshot.status {
        case .pending:   return t("status.pending")
        case .downloading: return t("status.downloading")
        case .paused:     return t("status.paused")
        case .completed:   return t("status.completed")
        case .failed:      return t("status.failed")
        case .cancelled:   return t("status.cancelled")
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if activeTaskCount > 1 && snapshot.isRunning {
            let base = snapshot.subtitle.isEmpty ? "\(activeTaskCount) \(t("items"))" : "\(snapshot.subtitle) · \(activeTaskCount) \(t("items"))"
            parts.append(base)
        } else {
            if !snapshot.subtitle.isEmpty { parts.append(snapshot.subtitle) }
            if !snapshot.badgeText.isEmpty { parts.append(snapshot.badgeText) }
        }
        // SteamCMD 排队提示
        if steamCMDQueuedCount > 0 {
            parts.append(String(format: t("status.queued"), steamCMDQueuedCount))
        }
        return parts.isEmpty ? "" : parts.joined(separator: " · ")
    }

    private var isCompleted: Bool { snapshot.status == .completed }
    private var showsRetry: Bool {
        snapshot.status == .failed || snapshot.status == .cancelled || snapshot.status == .paused
    }
    private var showsCancel: Bool {
        snapshot.status == .pending || snapshot.status == .downloading
    }

    /// 进度条动画：平滑跟随（优化：更长的响应时间减少重绘频率）
    private var progressAnimation: Animation {
        .interpolatingSpring(stiffness: 120, damping: 20)
    }

    private enum ToastActionRole {
        case secondary
        case retry
        case destructive
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                // 图标：完成时变绿色 + 微弹性
                Image(systemName: isCompleted ? "checkmark" : iconName)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                    .background(
                        DarkLiquidGlassBackground(
                            cornerRadius: 17,
                            isHovered: false
                        )
                    )
                    .scaleEffect(isCompleted ? 1.08 : 1.0)

                VStack(alignment: .leading, spacing: 4) {
                    Text(snapshot.title)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white.opacity(0.94))
                        .lineLimit(1)

                    Text(subtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                // 状态标签（统一样式，只变色）
                Text(statusText)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(
                        DarkLiquidGlassBackground(
                            cornerRadius: 12,
                            isHovered: false
                        )
                        .opacity(0.7)
                    )
            }

            // 进度区域
            if !isCompleted {
                // 进度条
                LiquidGlassLinearProgressBar(
                    progress: animatedProgress,
                    height: 6,
                    tintColor: tint,
                    trackOpacity: 0.15
                )

                HStack {
                    Text(snapshot.kind == .wallpaper ? t("wallpaper.downloads") : t("media.downloads"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))

                    Spacer()

                    Text("\(Int((max(0, min(animatedProgress, 1)) * 100).rounded()))%")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.86))
                        .contentTransition(.numericText())
                }
            } else {
                // 完成行：简洁显示
                HStack(spacing: 6) {
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(LiquidGlassColors.onlineGreen)
                    Text(t("status.completed"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(LiquidGlassColors.onlineGreen)
                    Spacer()
                }
            }

            if showsCancel || showsRetry {
                HStack(spacing: 10) {
                    toastActionButton(
                        title: showsCancel ? "后台继续" : "关闭",
                        icon: showsCancel ? "arrow.down.circle" : "xmark",
                        role: .secondary,
                        action: onDismiss
                    )

                    toastActionButton(
                        title: showsCancel ? "取消下载" : "重新下载",
                        icon: showsCancel ? "xmark.circle.fill" : "arrow.clockwise",
                        role: showsCancel ? .destructive : .retry,
                        action: showsCancel ? onCancel : onRetry
                    )
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: 440)
        .background(
            DarkLiquidGlassBackground(
                cornerRadius: 24,
                isHovered: false
            )
        )
        // 精简动画：只用颜色过渡，避免复杂的 layout transition 导致卡顿
        .animation(.easeInOut(duration: 0.20), value: isCompleted)
        .onChange(of: snapshot.progress) { _, newProgress in
            withAnimation(progressAnimation) {
                animatedProgress = newProgress
            }
        }
        .onAppear {
            animatedProgress = snapshot.progress
        }
    }

    @ViewBuilder
    private func toastActionButton(title: String, icon: String, role: ToastActionRole, action: @escaping () -> Void) -> some View {
        let fillColor: Color = {
            switch role {
            case .secondary:
                return Color.white.opacity(0.08)
            case .retry:
                return Color(red: 0.58, green: 0.82, blue: 0.72).opacity(0.96)
            case .destructive:
                return Color(red: 0.93, green: 0.42, blue: 0.42).opacity(0.94)
            }
        }()

        let foregroundColor: Color = {
            switch role {
            case .secondary:
                return Color.white.opacity(0.88)
            case .retry, .destructive:
                return Color.black.opacity(0.84)
            }
        }()

        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .bold))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(foregroundColor)
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: 19, style: .continuous)
                    .fill(fillColor)
                    .overlay(
                        RoundedRectangle(cornerRadius: 19, style: .continuous)
                            .stroke(
                                role == .secondary ? Color.white.opacity(0.08) : Color.white.opacity(0.16),
                                lineWidth: 0.8
                            )
                    )
            )
            .shadow(
                color: role == .secondary ? .clear : fillColor.opacity(0.24),
                radius: 10,
                y: 4
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 壁纸数据源切换 Toast
private struct WallpaperSourceSwitchToast: View {
    @ObservedObject private var sourceManager = WallpaperSourceManager.shared
    @State private var isShowing: Bool = false
    @State private var hideWorkItem: DispatchWorkItem?

    var body: some View {
        VStack {
            if let message = sourceManager.lastSwitchMessage, isShowing {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color(hex: "FFD60A"))
                    Text(message)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.9))
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                        )
                        .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
                )
                .frame(maxWidth: 360)
            }
        }
        .padding(.bottom, 40)
        .opacity(isShowing ? 1 : 0)
        .offset(y: isShowing ? 0 : 20)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
        .onChange(of: sourceManager.lastSwitchMessage) { _, _ in
            checkForNewMessage()
        }
    }

    // MARK: - 监听消息变化

    /// 当 lastSwitchMessage 变化时触发显示
    private func checkForNewMessage() {
        guard sourceManager.lastSwitchMessage != nil else { return }

        hideWorkItem?.cancel()
        isShowing = true

        let workItem = DispatchWorkItem { [weak sourceManager] in
            withAnimation(.easeOut(duration: 0.25)) {
                isShowing = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                sourceManager?.lastSwitchMessage = nil
            }
        }
        self.hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: workItem)
    }
}


// MARK: - Wallpaper Engine 数据源切换 Toast
private struct WorkshopSourceSwitchToast: View {
    @ObservedObject private var sourceManager = WorkshopSourceManager.shared
    @State private var isShowing: Bool = false
    @State private var hideWorkItem: DispatchWorkItem?

    var body: some View {
        VStack {
            if let message = sourceManager.lastSwitchMessage, isShowing {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: sourceManager.activeSource.icon)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color(hex: "0A84FF"))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.5))
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color(hex: "5E5CE6"))
                    }
                    Text(message)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.9))
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                        )
                        .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
                )
                .frame(maxWidth: 360)
            }
        }
        .opacity(isShowing ? 1 : 0)
        .offset(y: isShowing ? 0 : 20)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
        .onChange(of: sourceManager.lastSwitchMessage) { _, _ in
            checkForNewMessage()
        }
    }

    private func checkForNewMessage() {
        guard sourceManager.lastSwitchMessage != nil else { return }

        hideWorkItem?.cancel()
        isShowing = true

        let workItem = DispatchWorkItem { [weak sourceManager] in
            withAnimation(.easeOut(duration: 0.25)) {
                isShowing = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                sourceManager?.lastSwitchMessage = nil
            }
        }
        self.hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: workItem)
    }
}
