import SwiftUI
import Kingfisher
import AppKit
import AVFoundation

// MARK: - Scroll State
private final class LibraryScrollRuntimeState: ObservableObject {
    var currentOffset: CGFloat = 0
    /// 不发布到 SwiftUI，仅记录滚停时应从哪张可见卡继续预取。
    var lastWallpaperItemID: String?
    var lastMediaItemID: String?
    var lastAnimeItemID: String?
}

// MARK: - Scroll 观察与恢复辅助组件
/// 直接观察底层 NSScrollView，避免滚动时通过 PreferenceKey 持续触发整棵 SwiftUI 内容重算。
private struct LibraryScrollObserver: NSViewRepresentable {
    let restoreOffset: CGFloat
    let restoreTrigger: Int
    let onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        scheduleInstall(from: view, context: context)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onScroll = onScroll
        scheduleInstall(from: nsView, context: context)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onScroll: onScroll)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    private func scheduleInstall(from view: NSView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.install(
                from: view,
                restoreOffset: restoreOffset,
                restoreTrigger: restoreTrigger
            )
        }
    }

    @MainActor
    final class Coordinator {
        var onScroll: (CGFloat) -> Void
        private weak var observedScrollView: NSScrollView?
        private var boundsObserver: NSObjectProtocol?
        private var lastRestoreTrigger = -1

        init(onScroll: @escaping (CGFloat) -> Void) {
            self.onScroll = onScroll
        }

        func install(from view: NSView, restoreOffset: CGFloat, restoreTrigger: Int) {
            guard let scrollView = findParentScrollView(from: view) else { return }

            if observedScrollView !== scrollView {
                stopObserving()
                observedScrollView = scrollView
                scrollView.contentView.postsBoundsChangedNotifications = true
                boundsObserver = NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification,
                    object: scrollView.contentView,
                    queue: .main
                ) { [weak self, weak scrollView] _ in
                    guard let scrollView else { return }
                    MainActor.assumeIsolated { self?.handleScroll(scrollView) }
                }
            }

            if restoreTrigger != lastRestoreTrigger {
                lastRestoreTrigger = restoreTrigger
                restore(scrollView: scrollView, targetOffset: restoreOffset)
            }

            handleScroll(scrollView)
        }

        func stopObserving() {
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
            }
            boundsObserver = nil
            observedScrollView = nil
        }

        private func handleScroll(_ scrollView: NSScrollView) {
            onScroll(max(0, scrollView.contentView.bounds.origin.y))
        }

        private func restore(scrollView: NSScrollView, targetOffset: CGFloat) {
            guard targetOffset > 0 else { return }
            let currentY = scrollView.contentView.bounds.origin.y
            if abs(currentY - targetOffset) > 1 {
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetOffset))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }

        private func findParentScrollView(from view: NSView) -> NSScrollView? {
            var current = view.superview
            while let candidate = current {
                if let scrollView = candidate as? NSScrollView {
                    return scrollView
                }
                current = candidate.superview
            }
            return nil
        }
    }
}

struct MyLibraryContentView: View {
    // 共享 AppDelegate 持有的全局 ViewModel 实例（与首页/壁纸探索/媒体探索共用）。
    // ⚠️ 不用 @ObservedObject：WallpaperViewModel / MediaExploreViewModel 各有大量
    // @Published（探索页 searchQuery/isLoading 等），任一变化都会刷整页库 body。
    // 库内容变更只听 libraryContentRevision（onReceive），数据用 viewModel.xxx 命令式读取。
    let viewModel: WallpaperViewModel
    let mediaViewModel: MediaExploreViewModel
    // 注意：ArcBackgroundSettings / CurrentWallpaperService / WorkshopSourceManager /
    // FolderLockService / AnimeFavoriteStore 均不在顶层 @ObservedObject。
    // - 背景 → LibraryAtmosphereBackground 自行观察
    // - 当前壁纸标记 → activeWallpaperRevision 快照 + 卡片布尔
    // - 文件夹解锁 → folderUnlockRevision 快照
    // - 动漫收藏 / Steam 配置 → 事件驱动写 @State，不订阅整对象
    // 命令式访问共享单例（不订阅 objectWillChange）
    private let folderStore = LibraryFolderStore.shared
    private let gridOrderStore = LibraryGridOrderStore.shared
    private let workshopSourceManager = WorkshopSourceManager.shared
    private let animeFavoriteStore = AnimeFavoriteStore.shared
    @Environment(\.mainTopBarContentPadding) private var mainTopBarContentPadding

    // 分类筛选
    @State private var selectedContentType: ContentType = .wallpaper
    @Binding var selectedWallpaper: Wallpaper?
    @Binding var selectedMedia: MediaItem?
    @Binding var selectedAnime: AnimeSearchResult?
    @Binding var wallpaperContext: [Wallpaper]
    @Binding var mediaContext: [MediaItem]
    let isVisible: Bool
    @State private var animeFavorites: [AnimeSearchResult] = []

    // 子标签：收藏 / 已下载
    @State private var selectedSubTab: SubTab = .downloads
    @State private var didRestoreLastLibraryPage = false
    @State private var librarySearchQuery = ""
    @State private var isLibrarySearchExpanded = false
    @FocusState private var isLibrarySearchFocused: Bool

    // 编辑状态
    @State private var isEditing = false
    @State private var selectedItems = Set<String>()

    // 图片预加载由 onAppear 直接触发，无需追踪可见卡片 ID

    // MARK: - Scroll 恢复
    @StateObject private var libraryScrollRuntimeState = LibraryScrollRuntimeState()
    /// 当前活跃壁纸路径快照（仅路径集合变化时递增，驱动卡片 isCurrent 布尔刷新）
    @State private var activeWallpaperFilePaths: Set<String> = []
    @State private var activeWallpaperURLStrings: Set<String> = []
    @State private var activeWallpaperRevision: UInt = 0
    /// 文件夹解锁集合变化时递增，驱动文件夹卡锁态刷新（不观察 FolderLockService 全对象）
    @State private var folderUnlockRevision: UInt = 0
    /// 详情页导航前保存的滚动位置（>=0 表示需要恢复）
    @State private var savedLibraryScrollOffset: CGFloat = -1
    /// 恢复成功后自增，驱动 LibraryScrollRestorer 重新触发
    @State private var libraryScrollRestoreToken: Int = 0

    // 壁纸比例筛选
    @State private var wallpaperRatioFilter: WallpaperRatioFilter = .all
    // 媒体比例筛选
    @State private var mediaRatioFilter: WallpaperRatioFilter = .all

    // 缓存壁纸和媒体列表，避免 computed property 在 body 重绘时反复 map/filter
    @State private var wallpaperItems: [AnyWallpaperItem] = []
    @State private var mediaItems: [AnyMediaItem] = []
    @State private var wallpaperFolderDisplay: [String: FolderDisplayInfo] = [:]
    @State private var mediaFolderDisplay: [String: FolderDisplayInfo] = [:]
    // ⚡ 滚动 prefetch 用的 ID→Index 字典缓存（O(1) 查找替代 firstIndex(where:) O(N)）。
    @State private var wallpaperIDIndexCache: [String: Int] = [:]
    @State private var mediaIDIndexCache: [String: Int] = [:]
    @State private var animeIDIndexCache: [String: Int] = [:]
    @State private var lastWallpaperPrefetchBucket: Int?
    @State private var lastMediaPrefetchBucket: Int?
    @State private var lastAnimePrefetchBucket: Int?
    @State private var updateWallpaperDebounce: DispatchWorkItem?
    @State private var updateMediaDebounce: DispatchWorkItem?
    private let wallpaperPrefetchNamespace = "library.wallpapers"
    private let mediaPrefetchNamespace = "library.media"
    private let animePrefetchNamespace = "library.anime"

    // 文件夹导航
    @State private var currentWallpaperFolderID: String? = nil
    @State private var currentMediaFolderID: String? = nil
    @State private var wallpaperFolderStack: [String] = []  // 面包屑栈
    @State private var mediaFolderStack: [String] = []  // 面包屑栈

    // 触摸板双指右滑返回（文件夹内）
    @State private var folderBackSwipeRegistration: UUID?
    @State private var folderBackKeyboardMonitor: Any?

    // 新建文件夹
    @State private var showNewFolderSheet = false
    @State private var newFolderName = ""
    @State private var renamingFolder: LibraryFolder?
    @State private var renameFolderName = ""
    @State private var pendingRedownloadMediaFolder: LibraryFolder?
    @State private var showRedownloadMediaFolderConfirm = false
    @State private var pendingRedownloadMediaItem: MediaItem?
    @State private var showRedownloadMediaItemConfirm = false
    @State private var pendingWallpaperDeletion: AnyWallpaperItem?
    @State private var pendingMediaDeletion: AnyMediaItem?

    // 添加壁纸到文件夹
    @State private var showAddToFolderSheet = false

    // 拖拽排序 UI 状态
    /// 当前 hover 中的插入位置：插入到该 entry ID 之前。nil = 未 hover 任何插入条。
    @State private var hoveredInsertionID: String? = nil

    // 同步 Steam 订阅
    @State private var isSyncingSubscriptions = false
    @State private var showSyncProfileSheet = false
    @State private var showSyncSelectionSheet = false
    @State private var syncSubscribedItems: [WorkshopWallpaper] = []
    @State private var syncSelectedIDs = Set<String>()
    @State private var syncIsLoadingList = false
    @State private var syncErrorMessage: String?

    enum WallpaperRatioFilter: String, CaseIterable {
        case all = "all"
        case landscape = "landscape"
        case portrait = "portrait"

        var title: String {
            switch self {
            case .all: return LocalizationService.shared.t("filter.all")
            case .landscape: return LocalizationService.shared.t("filter.landscape")
            case .portrait: return LocalizationService.shared.t("filter.portrait")
            }
        }
    }

    enum SubTab: String, CaseIterable {
        case favorites = "favorites"
        case downloads = "downloads"

        var title: String {
            switch self {
            case .favorites: return LocalizationService.shared.t("my.favorites")
            case .downloads: return LocalizationService.shared.t("my.downloads")
            }
        }
    }

    private struct FolderDisplayInfo {
        let previewURLs: [URL]
        let itemCount: Int
    }

    /// 文件夹叠图后台预热任务（按 content+subTab 合并，避免快速切换时堆积）
    @State private var folderPreviewWarmupTask: Task<Void, Never>?

    private enum LastLibraryPageStore {
        private static let contentTypeKey = "my_library_last_content_type_v1"
        private static let subTabKey = "my_library_last_sub_tab_v1"

        static func load() -> (contentType: ContentType, subTab: SubTab)? {
            let defaults = UserDefaults.standard
            guard let contentValue = defaults.string(forKey: contentTypeKey),
                  let contentType = ContentType(rawValue: contentValue) else {
                return nil
            }
            let subTabValue = defaults.string(forKey: subTabKey)
            let subTab = subTabValue.flatMap(SubTab.init(rawValue:)) ?? .downloads
            return (contentType, subTab)
        }

        static func save(contentType: ContentType, subTab: SubTab) {
            let defaults = UserDefaults.standard
            defaults.set(contentType.rawValue, forKey: contentTypeKey)
            defaults.set(subTab.rawValue, forKey: subTabKey)
        }
    }

    private var libraryAtmosphereTint: ExploreAtmosphereTint {
        switch selectedContentType {
        case .wallpaper:
            return .wallpaperFallback
        case .video:
            return .mediaFallback
        case .anime:
            return ExploreAtmosphereTint(
                primary: Color(hex: "FF5A7D"),
                secondary: Color(hex: "8A5CFF"),
                tertiary: Color(hex: "20C1FF"),
                baseTop: Color(hex: "1D2128"),
                baseBottom: Color(hex: "0E1116")
            )
        }
    }

    private var trimmedLibrarySearchQuery: String {
        librarySearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasActiveLibrarySearch: Bool {
        !trimmedLibrarySearchQuery.isEmpty
    }

    var body: some View {
        // 性能测量：开启 PERF_TRACE 编译标记后，会在控制台打印触发本 body 的属性来源
        #if PERF_TRACE
        let _ = Self._printChanges()
        #endif
        ZStack(alignment: .topLeading) {
            if isEditing {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation {
                            isEditing = false
                            selectedItems.removeAll()
                        }
                    }
                    .allowsHitTesting(true)
            }

            // 背景渲染下沉到独立子视图：自行观察 ArcBackgroundSettings，
            // 外观设置变化只重建本背景，不触发整个库视图 body 重算。
            LibraryAtmosphereBackground(tint: libraryAtmosphereTint)
                // 把多层渐变+点阵+噪点合并成一个 Metal 纹理，减少 WindowServer 合成层数
                .drawingGroup(opaque: true)
                // 滚动时暂停背景重绘（背景是静态的，不需要每帧更新）
                .allowsHitTesting(false)

            GeometryReader { geometry in
                let contentWidth = max(0, geometry.size.width - 56)
                let gridConfig = LibraryGridConfig(contentWidth: contentWidth)
                let animeGridConfig = AnimeGridConfig(contentWidth: contentWidth)

                VStack(spacing: 0) {
                    // 固定头部
                    VStack(alignment: .leading, spacing: 0) {
                        mediaHero
                        libraryControlPanel
                            .padding(.top, 20)
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, mainTopBarContentPadding)
                    .padding(.bottom, 12)

                    // 内部滚动区域
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            contentSections(config: gridConfig, animeConfig: animeGridConfig)
                                .padding(.top, 10)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 28)
                        .padding(.bottom, 80)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .background(
                            LibraryScrollObserver(
                                restoreOffset: savedLibraryScrollOffset,
                                restoreTrigger: libraryScrollRestoreToken,
                                onScroll: handleLibraryScroll
                            )
                            .frame(width: 0, height: 0)
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environmentObject(CurrentWallpaperService.shared)
        .task {
            async let wallpaperIndex: Void = viewModel.ensureLocalWallpaperIndex()
            async let mediaIndex: Void = mediaViewModel.ensureLocalMediaIndex()
            _ = await (wallpaperIndex, mediaIndex)

            updateWallpaperItems()
            updateMediaItems()

            async let initialLoad: Void = viewModel.initialLoad()
            async let animeFavoritesLoad: Void = loadAnimeFavorites()
            _ = await (initialLoad, animeFavoritesLoad)
        }
        .onAppear {
            restoreLastLibraryPageIfNeeded()
            // ✅ 从详情返回时触发 ScrollView 滚动位置恢复
            if savedLibraryScrollOffset > 0 {
                libraryScrollRestoreToken += 1
            }
            // 注册触摸板双指右滑返回手势（文件夹内）。
            registerFolderBackSwipeHandler()
            registerFolderBackKeyboardHandler()
            syncActiveWallpaperSnapshot()
        }
        .onDisappear {
            unregisterFolderBackSwipeHandler()
            unregisterFolderBackKeyboardHandler()
        }
        .onReceive(animeFavoriteStore.$favorites) { _ in
            Task {
                await loadAnimeFavorites()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryScrollDidBecomeIdle)) { _ in
            guard isVisible else { return }
            resumeLibraryPrefetchAfterScroll()
        }
        .onChange(of: librarySearchQuery) { _, _ in
            updateWallpaperItems()
            updateMediaItems()
            syncSelectionWithVisibleItems()
        }
        .onChange(of: isVisible) { _, visible in
            if !visible {
                isLibrarySearchExpanded = false
                persistLastLibraryPage()
            } else {
                restoreLastLibraryPageIfNeeded()
                // 回到库页时同步一次当前壁纸快照（可能在其他页被切换）
                syncActiveWallpaperSnapshot()
            }
        }
        // ViewModel 不再 @ObservedObject：用 publisher 只听库内容 revision
        .onReceive(viewModel.$libraryContentRevision) { _ in
            debouncedUpdateWallpaperItems()
        }
        .onReceive(mediaViewModel.$libraryContentRevision) { _ in
            debouncedUpdateMediaItems()
        }
        .onChange(of: selectedSubTab) { _, _ in
            persistLastLibraryPage()
            // 切换子标签时重置文件夹导航和滚动位置
            savedLibraryScrollOffset = -1
            currentWallpaperFolderID = nil
            currentMediaFolderID = nil
            wallpaperFolderStack.removeAll()
            mediaFolderStack.removeAll()
            isEditing = false
            selectedItems.removeAll()
            updateWallpaperItems()
            updateMediaItems()
        }
        .onChange(of: wallpaperRatioFilter) { _, _ in
            debouncedUpdateWallpaperItems()
        }
        .onChange(of: mediaRatioFilter) { _, _ in
            debouncedUpdateMediaItems()
        }
        .onReceive(folderStore.$wallpaperFolders) { _ in
            debouncedUpdateWallpaperItems()
        }
        .onReceive(folderStore.$mediaFolders) { _ in
            debouncedUpdateMediaItems()
        }
        .onReceive(gridOrderStore.$revision) { _ in
            debouncedUpdateWallpaperItems()
            debouncedUpdateMediaItems()
        }
        // 当前壁纸 / 文件夹解锁：只在集合真变化时写 @State，避免无关 @Published 刷整页
        .onReceive(CurrentWallpaperService.shared.$activeFilePaths) { paths in
            guard paths != activeWallpaperFilePaths else { return }
            activeWallpaperFilePaths = paths
            activeWallpaperRevision &+= 1
        }
        .onReceive(CurrentWallpaperService.shared.$activeURLStrings) { urls in
            guard urls != activeWallpaperURLStrings else { return }
            activeWallpaperURLStrings = urls
            activeWallpaperRevision &+= 1
        }
        .onReceive(FolderLockService.shared.$unlockedFolderIDs) { _ in
            folderUnlockRevision &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .appShouldReleaseForegroundMemory)) { _ in
            releaseForegroundMemory()
        }
        .onReceive(NotificationCenter.default.publisher(for: .appDidReceiveMemoryPressure)) { _ in
            stopLibraryPrefetchers()
        }
        .onChange(of: selectedContentType) { _, _ in
            persistLastLibraryPage()
            // 切换内容类型时重置编辑状态、文件夹导航和滚动位置
            savedLibraryScrollOffset = -1
            isEditing = false
            selectedItems.removeAll()
            currentWallpaperFolderID = nil
            currentMediaFolderID = nil
            wallpaperFolderStack.removeAll()
            mediaFolderStack.removeAll()
            debouncedUpdateWallpaperItems()
            debouncedUpdateMediaItems()
        }
        .sheet(isPresented: $showNewFolderSheet) {
            NewFolderSheet(
                folderName: $newFolderName,
                onConfirm: {
                    let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    let contentType: LibraryFolder.FolderContentType = selectedContentType == .wallpaper ? .wallpaper : .media
                    let parentID = selectedContentType == .wallpaper ? currentWallpaperFolderID : currentMediaFolderID
                    let collection: LibraryFolder.FolderCollection = selectedSubTab == .favorites ? .favorites : .downloads
                    folderStore.createFolder(name: name, contentType: contentType, parentID: parentID, collection: collection)
                    newFolderName = ""
                    showNewFolderSheet = false
                    updateWallpaperItems()
                    updateMediaItems()
                },
                onCancel: {
                    newFolderName = ""
                    showNewFolderSheet = false
                }
            )
        }
        .sheet(item: $renamingFolder) { folder in
            NewFolderSheet(
                title: t("folder.rename"),
                confirmTitle: t("rename"),
                folderName: $renameFolderName,
                onConfirm: {
                    let name = renameFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    folderStore.renameFolder(id: folder.id, contentType: folder.contentType, newName: name)
                    renameFolderName = ""
                    renamingFolder = nil
                    updateWallpaperItems()
                    updateMediaItems()
                },
                onCancel: {
                    renameFolderName = ""
                    renamingFolder = nil
                }
            )
        }
        .sheet(isPresented: $showAddToFolderSheet) {
            addToFolderSheetContent
        }
        .alert(t("folder.redownload.all.media.confirm.title"), isPresented: $showRedownloadMediaFolderConfirm) {
            Button(t("folder.redownload.all.media"), role: .destructive) {
                guard let folder = pendingRedownloadMediaFolder else { return }
                redownloadAllMedia(in: folder)
                pendingRedownloadMediaFolder = nil
            }
            Button(t("cancel"), role: .cancel) {
                pendingRedownloadMediaFolder = nil
            }
        } message: {
            let count = pendingRedownloadMediaFolder.map {
                MediaLibraryService.shared.downloadedItems(inFolder: $0.id).count
            } ?? 0
            Text(String(format: t("folder.redownload.all.media.confirm.message"), count))
        }
        .alert(t("library.redownload.item.confirm.title"), isPresented: $showRedownloadMediaItemConfirm) {
            Button(t("library.redownload.item"), role: .destructive) {
                guard let item = pendingRedownloadMediaItem else { return }
                redownloadMediaItem(item)
                pendingRedownloadMediaItem = nil
            }
            Button(t("cancel"), role: .cancel) {
                pendingRedownloadMediaItem = nil
            }
        } message: {
            Text(t("library.redownload.item.confirm.message"))
        }
        .alert(t("delete"), isPresented: wallpaperDeletionAlertPresented) {
            Button(t("delete"), role: .destructive) {
                if let item = pendingWallpaperDeletion {
                    deleteWallpaperItem(item)
                }
                pendingWallpaperDeletion = nil
            }
            Button(t("cancel"), role: .cancel) {
                pendingWallpaperDeletion = nil
            }
        } message: {
            Text(t("deleteConfirmMessage"))
        }
        .alert(t("delete"), isPresented: mediaDeletionAlertPresented) {
            Button(t("delete"), role: .destructive) {
                if let item = pendingMediaDeletion {
                    deleteMediaItem(item)
                }
                pendingMediaDeletion = nil
            }
            Button(t("cancel"), role: .cancel) {
                pendingMediaDeletion = nil
            }
        } message: {
            Text(t("deleteConfirmMessage"))
        }
        .sheet(isPresented: $showSyncProfileSheet) {
            syncProfileSheet
        }
        .sheet(isPresented: $showSyncSelectionSheet) {
            syncSelectionSheet
        }
        .sheet(isPresented: $showSteamLoginSheet) {
            SteamLoginSheet(isPresented: $showSteamLoginSheet)
                .environmentObject(workshopSourceManager)
                .onDisappear {
                    // 登录成功后立即弹出选择 Sheet（显示加载中），再开始获取数据
                    if workshopSourceManager.hasSteamProfileID {
                        syncIsLoadingList = true
                        syncSelectedIDs = []
                        showSyncSelectionSheet = true
                        Task { await fetchSubscriptionList() }
                    }
                }
        }
    }

    private var wallpaperDeletionAlertPresented: Binding<Bool> {
        Binding(
            get: { pendingWallpaperDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    pendingWallpaperDeletion = nil
                }
            }
        )
    }

    private var mediaDeletionAlertPresented: Binding<Bool> {
        Binding(
            get: { pendingMediaDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    pendingMediaDeletion = nil
                }
            }
        )
    }

    // MARK: - 加载动漫收藏
    private func loadAnimeFavorites() async {
        let favorites = animeFavoriteStore.allFavorites
        let progressStore = AnimeProgressStore.shared
        lastAnimePrefetchBucket = nil
        animeFavorites = favorites.map { favorite in
            // 尝试从进度存储中获取观看信息
            let summary = progressStore.animeSummaries[favorite.id]
            let latestEp: String?
            if let summary, let epNum = summary.lastEpisodeNumber {
                latestEp = "第 \(epNum) 集"
            } else {
                latestEp = nil
            }

            return AnimeSearchResult(
                id: favorite.id,
                title: favorite.title,
                coverURL: favorite.coverURL,
                detailURL: "",
                sourceId: "bangumi",
                sourceName: "Bangumi",
                latestEpisode: latestEp,
                rating: nil,
                summary: nil,
                rank: nil,
                airDate: nil,
                airWeekday: nil,
                tags: favorite.tags.map { AnimeTag(name: $0, count: nil) },
                originalName: nil
            )
        }
        // ⚡ prefetch 用的 ID→Index 缓存与 animeFavorites 同步刷新
        var idMap: [String: Int] = [:]
        idMap.reserveCapacity(animeFavorites.count)
        for (idx, anime) in animeFavorites.enumerated() { idMap[anime.id] = idx }
        animeIDIndexCache = idMap
        syncSelectionWithVisibleItems()
    }

    private func restoreLastLibraryPageIfNeeded() {
        guard isVisible, !didRestoreLastLibraryPage else { return }
        didRestoreLastLibraryPage = true
        guard let lastPage = LastLibraryPageStore.load() else {
            persistLastLibraryPage()
            return
        }

        var didChange = false
        if selectedContentType != lastPage.contentType {
            selectedContentType = lastPage.contentType
            didChange = true
        }
        if selectedSubTab != lastPage.subTab {
            selectedSubTab = lastPage.subTab
            didChange = true
        }
        if didChange {
            savedLibraryScrollOffset = -1
            currentWallpaperFolderID = nil
            currentMediaFolderID = nil
            wallpaperFolderStack.removeAll()
            mediaFolderStack.removeAll()
            isEditing = false
            selectedItems.removeAll()
            updateWallpaperItems()
            updateMediaItems()
        }
    }

    private func persistLastLibraryPage() {
        LastLibraryPageStore.save(contentType: selectedContentType, subTab: selectedSubTab)
    }

    private func releaseForegroundMemory() {
        viewModel.releaseForegroundMemory()
        mediaViewModel.releaseForegroundMemory()

        savedLibraryScrollOffset = -1
        libraryScrollRestoreToken &+= 1
        selectedWallpaper = nil
        selectedMedia = nil
        selectedAnime = nil
        wallpaperContext.removeAll()
        mediaContext.removeAll()
        animeFavorites.removeAll()
        wallpaperItems.removeAll()
        mediaItems.removeAll()
        wallpaperFolderDisplay.removeAll()
        mediaFolderDisplay.removeAll()
        wallpaperIDIndexCache.removeAll()
        mediaIDIndexCache.removeAll()
        animeIDIndexCache.removeAll()
        currentWallpaperFolderID = nil
        currentMediaFolderID = nil
        wallpaperFolderStack.removeAll()
        mediaFolderStack.removeAll()
        selectedItems.removeAll()
        isEditing = false
        showNewFolderSheet = false
        newFolderName = ""
        lastWallpaperPrefetchBucket = nil
        lastMediaPrefetchBucket = nil
        lastAnimePrefetchBucket = nil
        stopLibraryPrefetchers()
    }

    private func stopLibraryPrefetchers() {
        ForegroundPrefetchManager.shared.stop(namespace: wallpaperPrefetchNamespace)
        ForegroundPrefetchManager.shared.stop(namespace: mediaPrefetchNamespace)
        ForegroundPrefetchManager.shared.stop(namespace: animePrefetchNamespace)
    }

    private func handleLibraryScroll(_ offset: CGFloat) {
        // 只写运行时 offset + 滚动门控；不触发任何 @State，避免滚动帧刷整页 body
        libraryScrollRuntimeState.currentOffset = offset
        // 滚动中抑制媒体卡 hover/GIF 叠加，并暂停缩略图生成/预取
        let wasScrolling = LibraryScrollHoverGate.shared.isScrolling
        LibraryScrollHoverGate.shared.noteScrollActivity()
        // 刚进入滚动：立刻停掉正在进行的 Kingfisher 预取（不写 @State）
        if !wasScrolling {
            ForegroundPrefetchManager.shared.stop(namespace: wallpaperPrefetchNamespace)
            ForegroundPrefetchManager.shared.stop(namespace: mediaPrefetchNamespace)
            ForegroundPrefetchManager.shared.stop(namespace: animePrefetchNamespace)
        }
    }

    private var mediaHero: some View {
        HStack(alignment: .bottom) {
            Text(t("my.media.library"))
                .font(.system(size: 42, weight: .bold, design: .serif))
                .foregroundStyle(.white.opacity(0.96))

            Spacer()

            let (count, icon, color, key) = heroBadgeInfo
            SettingsStatusBadge(
                title: "\(count) \(t(key))",
                systemImage: icon,
                color: color
            )
        }
    }

    private var heroBadgeInfo: (count: Int, icon: String, color: Color, key: String) {
        switch selectedContentType {
        case .wallpaper:
            if selectedSubTab == .favorites {
                return (viewModel.favorites.count, "heart.fill", LiquidGlassColors.primaryPink, "item.favorites")
            } else {
                return (viewModel.allLocalWallpapers.count, "arrow.down.circle.fill", LiquidGlassColors.accentCyan, "item.downloads")
            }
        case .video:
            if selectedSubTab == .favorites {
                return (mediaViewModel.favoriteItems.count, "heart.fill", LiquidGlassColors.primaryPink, "item.favorites")
            } else {
                return (mediaViewModel.allLocalMedia.count, "arrow.down.circle.fill", LiquidGlassColors.accentCyan, "item.downloads")
            }
        case .anime:
            return (animeFavorites.count, "heart.fill", LiquidGlassColors.primaryPink, "item.favorites")
        }
    }

    private var activeLibraryTint: Color {
        switch selectedContentType {
        case .wallpaper:
            return LiquidGlassColors.primaryPink
        case .video:
            return LiquidGlassColors.secondaryViolet
        case .anime:
            return LiquidGlassColors.tertiaryBlue
        }
    }

    private var libraryControlPanel: some View {
        let tint = activeLibraryTint

        return HStack(alignment: .center, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                ContentTypePicker(selected: $selectedContentType)
                librarySearchControl

                if selectedContentType != .anime {
                    subTabDropdown
                }
            }

            Spacer(minLength: 0)

            HStack(alignment: .center, spacing: 10) {
                if selectedContentType == .wallpaper {
                    wallpaperRatioPicker(color: tint)
                }

                libraryToolbarActions(tint: tint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassContainer(spacing: 12)
    }

    // MARK: - Content Sections
    @ViewBuilder
    private func contentSections(config: LibraryGridConfig, animeConfig: AnimeGridConfig) -> some View {
        switch selectedContentType {
        case .wallpaper:
            wallpaperSection(config: config)
        case .video:
            mediaSection(config: config)
        case .anime:
            animeSection(config: animeConfig)
        }
    }

    // MARK: - Wallpaper Section
    private func wallpaperSection(config: LibraryGridConfig) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // 文件夹导航面包屑
            folderBreadcrumb(
                folderStack: wallpaperFolderStack,
                isInFolder: currentWallpaperFolderID != nil,
                onBack: popWallpaperFolder,
                onRoot: { navigateToWallpaperFolder(nil) },
                onAdd: { showAddToFolderSheet = true }
            )

            if wallpaperItems.isEmpty && currentWallpaperFolders.isEmpty {
                emptyMediaSurface(
                    title: hasActiveLibrarySearch ? t("error.empty.title") : (selectedSubTab == .favorites ? t("no.wallpaper.favorites") : t("no.wallpaper.downloads")),
                    subtitle: hasActiveLibrarySearch ? t("error.empty.message") : (selectedSubTab == .favorites ? t("no.wallpaper.favorites.hint") : t("no.wallpaper.downloads.hint")),
                    icon: hasActiveLibrarySearch ? "magnifyingglass" : (selectedSubTab == .favorites ? "heart.slash" : "arrow.down.circle"),
                    accent: LiquidGlassColors.primaryPink
                )
            } else {
                libraryWaterfallGrid(
                    entries: orderedWallpaperGridItems,
                    config: config,
                    estimatedHeight: LibraryCardMetrics.thumbnailHeight + 60
                ) { entry in
                    wallpaperGridEntry(entry, config: config)
                }
            }
        }
    }

    @ViewBuilder
    private func wallpaperGridEntry(_ entry: LibraryGridEntry<AnyWallpaperItem>, config: LibraryGridConfig) -> some View {
        switch entry {
        case .folder(let folder):
            wallpaperFolderCard(folder: folder, config: config)
                .overlay(alignment: .leading) {
                    // 排序插入条仅编辑态挂载，减少非编辑滚动时每卡 hit-test 层
                    if isEditing {
                        insertionDropZone(before: entry.id)
                    }
                }
        case .item(let item):
            wallpaperGridItem(item: item, config: config)
                .overlay(alignment: .leading) {
                    if isEditing {
                        insertionDropZone(before: entry.id)
                    }
                }
                .onAppear {
                    libraryScrollRuntimeState.lastWallpaperItemID = item.id
                    preloadNearbyWallpapers(around: item)
                }
        }
    }

    private func wallpaperFolderCard(folder: LibraryFolder, config: LibraryGridConfig) -> some View {
        let display = wallpaperFolderDisplay[folder.id] ?? FolderDisplayInfo(previewURLs: [], itemCount: 0)
        // 依赖 folderUnlockRevision，解锁集合变化时刷新锁态，无需观察 FolderLockService 全对象
        _ = folderUnlockRevision
        let isUnlocked = FolderLockService.shared.isFolderUnlocked(folder.id)
        return LibraryFolderCard(
            folder: folder,
            previewURLs: display.previewURLs,
            itemCount: display.itemCount,
            cardWidth: config.cardWidth,
            isEditing: isEditing,
            isUnlocked: isUnlocked,
            dragPayload: dragPayload(for: "folder_\(folder.id)"),
            onTap: { handleFolderTap(folder) },
            onDrop: { ids in moveWallpapersToFolder(ids: ids, folderID: folder.id) },
            onDisband: {
                folderStore.deleteFolder(id: folder.id, contentType: .wallpaper)
                gridOrderStore.removeIDs(["folder_\(folder.id)"], from: currentGridOrderScope)
                updateWallpaperItems()
            },
            onDelete: {
                deleteFolderWithContents(folderID: folder.id, contentType: .wallpaper)
            },
            onRename: { startRenamingFolder(folder) },
            onToggleLock: {
                folderStore.toggleFolderLock(id: folder.id, contentType: .wallpaper)
            },
            onRelock: {
                FolderLockService.shared.lockFolder(folder.id)
            },
            onOptimizeVideos: {
                _ = VideoOptimizationQueueService.shared.enqueueLibraryFolder(folder)
            },
            onRedownloadAll: nil
        )
    }

    private func navigateToWallpaperFolder(_ folderID: String?) {
        if let current = currentWallpaperFolderID, folderID != nil {
            wallpaperFolderStack.append(current)
        }
        currentWallpaperFolderID = folderID
        updateWallpaperItems()
    }

    private func popWallpaperFolder() {
        guard !wallpaperFolderStack.isEmpty else {
            currentWallpaperFolderID = nil
            updateWallpaperItems()
            return
        }
        currentWallpaperFolderID = wallpaperFolderStack.popLast()
        updateWallpaperItems()
    }

    /// Esc navigates up one folder level. Keep the focused search field's own Esc behavior intact.
    private func handleEscapeKey() -> Bool {
        guard isVisible, !isLibrarySearchFocused else { return false }

        switch selectedContentType {
        case .wallpaper:
            guard currentWallpaperFolderID != nil else { return false }
            popWallpaperFolder()
            return true
        case .video:
            guard currentMediaFolderID != nil else { return false }
            popMediaFolder()
            return true
        case .anime:
            return false
        }
    }

    private var isPresentingLibraryModal: Bool {
        showNewFolderSheet ||
        renamingFolder != nil ||
        showAddToFolderSheet ||
        showRedownloadMediaFolderConfirm ||
        showRedownloadMediaItemConfirm ||
        pendingWallpaperDeletion != nil ||
        pendingMediaDeletion != nil ||
        showSyncProfileSheet ||
        showSyncSelectionSheet ||
        showSteamLoginSheet ||
        NSApp.modalWindow != nil
    }

    private func registerFolderBackKeyboardHandler() {
        guard folderBackKeyboardMonitor == nil else { return }

        folderBackKeyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            guard NSApp.isActive,
                  event.window?.isKeyWindow == true,
                  event.keyCode == 53,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  !CropAdjustOverlayController.shared.isAdjusting,
                  !self.isPresentingLibraryModal else {
                return event
            }

            return self.handleEscapeKey() ? nil : event
        }
    }

    private func unregisterFolderBackKeyboardHandler() {
        guard let folderBackKeyboardMonitor else { return }
        NSEvent.removeMonitor(folderBackKeyboardMonitor)
        self.folderBackKeyboardMonitor = nil
    }

    // MARK: - 触摸板双指右滑返回

    /// 当前是否处于某个文件夹内（壁纸或媒体）
    private var isInAnyFolder: Bool {
        isVisible && (currentWallpaperFolderID != nil || currentMediaFolderID != nil)
    }

    /// 注册共享滚动事件路由：详情页的优先级更高，避免返回详情时同时退出后台文件夹。
    private func registerFolderBackSwipeHandler() {
        guard folderBackSwipeRegistration == nil else { return }
        folderBackSwipeRegistration = TrackpadBackSwipeRouter.shared.register(
            priority: 10,
            isEnabled: { self.isInAnyFolder },
            action: {
                if self.selectedContentType == .wallpaper {
                    self.popWallpaperFolder()
                } else if self.selectedContentType == .video {
                    self.popMediaFolder()
                }
            }
        )
    }

    private func unregisterFolderBackSwipeHandler() {
        guard let folderBackSwipeRegistration else { return }
        TrackpadBackSwipeRouter.shared.unregister(folderBackSwipeRegistration)
        self.folderBackSwipeRegistration = nil
    }

    private var currentWallpaperFolderScope: WallpaperLibraryService.FolderMembershipScope {
        selectedSubTab == .favorites ? .favorites : .downloads
    }

    private var currentMediaFolderScope: MediaLibraryService.FolderMembershipScope {
        selectedSubTab == .favorites ? .favorites : .downloads
    }

    private func moveTargetFolders(
        contentType: LibraryFolder.FolderContentType,
        excluding currentFolderID: String?
    ) -> [LibraryFolder] {
        let collection: LibraryFolder.FolderCollection = selectedSubTab == .favorites ? .favorites : .downloads
        let folders = contentType == .wallpaper ? folderStore.wallpaperFolders : folderStore.mediaFolders
        return folders
            .filter { $0.collection == collection && $0.id != currentFolderID }
            .sorted { lhs, rhs in
                let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
                if nameOrder != .orderedSame {
                    return nameOrder == .orderedAscending
                }
                return lhs.id < rhs.id
            }
    }

    private var wallpaperMoveTargetFolders: [LibraryFolder] {
        moveTargetFolders(contentType: .wallpaper, excluding: currentWallpaperFolderID)
    }

    private var mediaMoveTargetFolders: [LibraryFolder] {
        moveTargetFolders(contentType: .media, excluding: currentMediaFolderID)
    }

    private func moveWallpapersToFolder(ids: [String], folderID: String) {
        // 空字符串不是合法文件夹 ID，统一视为根目录 nil，避免写入 "" 后变成“幽灵归属”
        let normalizedFolderID = WallpaperLibraryService.normalizedFolderID(folderID)
        gridOrderStore.removeIDs(Set(ids), from: currentGridOrderScope)
        let scope = currentWallpaperFolderScope
        let unifiedByID: [String: UnifiedLocalWallpaper] = Dictionary(
            uniqueKeysWithValues: viewModel.allLocalWallpapers.map { ($0.id, $0) }
        )
        for id in ids {
            // 对「扫描进来但还没有 DownloadRecord」的项传 fallback，
            // 让 Service 层自动补登记，确保 folderID 写得进去。
            let fallback: (wallpaper: Wallpaper, fileURL: URL)?
            if scope == .downloads, let unified = unifiedByID[id], unified.downloadRecord == nil {
                fallback = (unified.wallpaper, unified.fileURL)
            } else {
                fallback = nil
            }
            folderStore.moveWallpaperToFolder(
                wallpaperID: id,
                folderID: normalizedFolderID,
                scope: scope,
                fallback: fallback
            )
        }
        updateWallpaperItems()
    }

    private func debouncedUpdateWallpaperItems() {
        updateWallpaperDebounce?.cancel()
        let work = DispatchWorkItem { [self] in
            updateWallpaperItems()
        }
        updateWallpaperDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    private func debouncedUpdateMediaItems() {
        updateMediaDebounce?.cancel()
        let work = DispatchWorkItem { [self] in
            updateMediaItems()
        }
        updateMediaDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    // MARK: - 当前壁纸快照（不订阅 CurrentWallpaperService 全对象）

    private func syncActiveWallpaperSnapshot() {
        let service = CurrentWallpaperService.shared
        let paths = service.activeFilePaths
        let urls = service.activeURLStrings
        if paths != activeWallpaperFilePaths {
            activeWallpaperFilePaths = paths
        }
        if urls != activeWallpaperURLStrings {
            activeWallpaperURLStrings = urls
        }
    }

    /// 与 `CurrentWallpaperService.isCurrentWallpaper` 等价，但只读本地快照，
    /// 避免顶层 @ObservedObject 在任意活跃路径重建时刷整页 body。
    private func isActiveWallpaperURL(_ url: URL?) -> Bool {
        // 引用 revision，确保路径/URL 集合变化时 SwiftUI 会重算依赖该布尔的卡片
        _ = activeWallpaperRevision
        guard let url else { return false }
        if activeWallpaperURLStrings.contains(url.absoluteString) {
            return true
        }
        guard url.isFileURL else { return false }
        guard !activeWallpaperFilePaths.isEmpty else { return false }
        let candidate = url.standardizedFileURL.path
        if activeWallpaperFilePaths.contains(candidate) {
            return true
        }
        for activePath in activeWallpaperFilePaths {
            if candidate.hasPrefix(activePath + "/") || activePath.hasPrefix(candidate + "/") {
                return true
            }
        }
        return false
    }

    private func updateWallpaperItems() {
        lastWallpaperPrefetchBucket = nil
        let baseItems: [AnyWallpaperItem]
        switch selectedSubTab {
        case .favorites:
            let allFavorites = viewModel.favorites
            let folderID = WallpaperLibraryService.normalizedFolderID(currentWallpaperFolderID)
            let filtered = allFavorites.filter { wallpaper in
                guard let record = WallpaperLibraryService.shared.favoriteRecord(for: wallpaper.id) else { return false }
                return WallpaperLibraryService.normalizedFolderID(record.folderID) == folderID
            }
            baseItems = filtered.map {
                AnyWallpaperItem(
                    wallpaper: $0,
                    localFileURL: viewModel.localFileURLIfAvailable(for: $0)
                )
            }
        case .downloads:
            let allLocal = viewModel.allLocalWallpapers
            let folderID = WallpaperLibraryService.normalizedFolderID(currentWallpaperFolderID)
            let filtered = allLocal.filter { unified in
                if let record = unified.downloadRecord {
                    return WallpaperLibraryService.normalizedFolderID(record.folderID) == folderID
                }
                // 扫描到的本地文件只在根目录显示
                return folderID == nil
            }
            baseItems = filtered.map { AnyWallpaperItem(unified: $0) }
        }
        switch wallpaperRatioFilter {
        case .all:
            wallpaperItems = baseItems
        case .landscape:
            wallpaperItems = baseItems.filter { $0.wallpaper.dimensionX >= $0.wallpaper.dimensionY }
        case .portrait:
            wallpaperItems = baseItems.filter { $0.wallpaper.dimensionX < $0.wallpaper.dimensionY }
        }
        if hasActiveLibrarySearch {
            let query = trimmedLibrarySearchQuery
            wallpaperItems = wallpaperItems.filter { matchesLibrarySearch(for: $0, query: query) }
        }
        // ⚡ prefetch 用的 ID→Index 缓存与 wallpaperItems 同步刷新
        var idMap: [String: Int] = [:]
        idMap.reserveCapacity(wallpaperItems.count)
        for (idx, item) in wallpaperItems.enumerated() { idMap[item.id] = idx }
        wallpaperIDIndexCache = idMap
        refreshWallpaperFolderDisplay()
        syncSelectionWithVisibleItems()
    }

    private var orderedWallpaperGridItems: [LibraryGridEntry<AnyWallpaperItem>] {
        let entries = currentWallpaperFolders.map { LibraryGridEntry<AnyWallpaperItem>.folder($0) }
            + wallpaperItems.map { LibraryGridEntry<AnyWallpaperItem>.item($0) }
        return orderedGridEntries(entries)
    }

    /// 当前内容类型下可选中的项目总数（用于全选/取消全选判断）
    private var selectableItemCount: Int {
        switch selectedContentType {
        case .wallpaper:
            return wallpaperItems.count + currentWallpaperFolders.count
        case .video:
            return mediaItems.count + currentMediaFolders.count
        case .anime:
            return currentAnimeItems.count
        }
    }

    private var currentWallpaperFolders: [LibraryFolder] {
        let collection: LibraryFolder.FolderCollection = selectedSubTab == .favorites ? .favorites : .downloads
        let folders = folderStore.folders(for: .wallpaper, parentID: currentWallpaperFolderID, collection: collection)
        guard hasActiveLibrarySearch else { return folders }
        let query = trimmedLibrarySearchQuery
        return folders.filter { matchesLibrarySearch(for: $0, query: query) }
    }

    private var currentMediaFolders: [LibraryFolder] {
        let collection: LibraryFolder.FolderCollection = selectedSubTab == .favorites ? .favorites : .downloads
        let folders = folderStore.folders(for: .media, parentID: currentMediaFolderID, collection: collection)
        guard hasActiveLibrarySearch else { return folders }
        let query = trimmedLibrarySearchQuery
        return folders.filter { matchesLibrarySearch(for: $0, query: query) }
    }

    /// 可添加到文件夹的壁纸（不在任何文件夹中的根目录壁纸）
    private var availableWallpapersForFolder: [(id: String, name: String, thumbURL: URL?, localFileURL: URL?)] {
        switch selectedSubTab {
        case .favorites:
            return WallpaperLibraryService.shared.favoriteWallpapers(inFolder: nil).map {
                (id: $0.id, name: $0.id, thumbURL: $0.thumbURL, localFileURL: nil)
            }
        case .downloads:
            let downloads = WallpaperLibraryService.shared.downloadedWallpapers(inFolder: nil)
            let scanned = viewModel.allLocalWallpapers.filter { $0.downloadRecord == nil }
            var result = downloads.map {
                (id: $0.wallpaper.id, name: $0.wallpaper.id, thumbURL: $0.wallpaper.thumbURL, localFileURL: $0.localFileURL)
            }
            for s in scanned {
                guard !result.contains(where: { $0.id == s.id }) else { continue }
                result.append((id: s.id, name: s.wallpaper.id, thumbURL: s.wallpaper.thumbURL, localFileURL: s.fileURL))
            }
            return result
        }
    }

    /// 可添加到文件夹的媒体（不在任何文件夹中的根目录媒体）
    private var availableMediaForFolder: [(id: String, name: String, thumbURL: URL?)] {
        switch selectedSubTab {
        case .favorites:
            return MediaLibraryService.shared.favoriteItems(inFolder: nil).map {
                (id: $0.id, name: $0.title, thumbURL: $0.libraryGridThumbnailURL(localFileURL: nil))
            }
        case .downloads:
            let downloads = MediaLibraryService.shared.downloadedItems(inFolder: nil)
            let scanned = mediaViewModel.allLocalMedia.filter { $0.downloadRecord == nil }
            var result = downloads.map {
                (id: $0.item.id, name: $0.item.title, thumbURL: $0.item.libraryGridThumbnailURL(localFileURL: $0.localFileURL))
            }
            for s in scanned {
                guard !result.contains(where: { $0.id == s.id }) else { continue }
                result.append((id: s.id, name: s.mediaItem.title, thumbURL: s.mediaItem.libraryGridThumbnailURL(localFileURL: s.fileURL)))
            }
            return result
        }
    }

    private func updateMediaItems() {
        lastMediaPrefetchBucket = nil
        let baseItems: [AnyMediaItem]
        switch selectedSubTab {
        case .favorites:
            let allFavorites = mediaViewModel.favoriteItems
            let folderID = MediaLibraryService.normalizedFolderID(currentMediaFolderID)
            let filtered = allFavorites.filter { item in
                guard let record = MediaLibraryService.shared.favoriteRecord(for: item.id) else { return false }
                return MediaLibraryService.normalizedFolderID(record.folderID) == folderID
            }
            baseItems = filtered.map {
                AnyMediaItem(
                    mediaItem: $0,
                    localFileURL: MediaLibraryService.shared.localFileURLIfAvailable(for: $0)
                )
            }
        case .downloads:
            let allLocal = mediaViewModel.allLocalMedia
            let folderID = MediaLibraryService.normalizedFolderID(currentMediaFolderID)
            let filtered = allLocal.filter { unified in
                if let record = unified.downloadRecord {
                    return MediaLibraryService.normalizedFolderID(record.folderID) == folderID
                }
                // 扫描到的本地文件只在根目录显示
                return folderID == nil
            }
            baseItems = filtered.map { AnyMediaItem(unified: $0) }
        }
        // 媒体库不再做横屏/竖屏筛选
        mediaItems = baseItems
        if hasActiveLibrarySearch {
            let query = trimmedLibrarySearchQuery
            mediaItems = mediaItems.filter { matchesLibrarySearch(for: $0, query: query) }
        }
        // ⚡ prefetch 用的 ID→Index 缓存与 mediaItems 同步刷新
        var idMap: [String: Int] = [:]
        idMap.reserveCapacity(mediaItems.count)
        for (idx, item) in mediaItems.enumerated() { idMap[item.id] = idx }
        mediaIDIndexCache = idMap
        refreshMediaFolderDisplay()
        syncSelectionWithVisibleItems()
    }

    private var orderedMediaGridItems: [LibraryGridEntry<AnyMediaItem>] {
        let entries = currentMediaFolders.map { LibraryGridEntry<AnyMediaItem>.folder($0) }
            + mediaItems.map { LibraryGridEntry<AnyMediaItem>.item($0) }
        return orderedGridEntries(entries)
    }

    private func orderedGridEntries<Item>(_ entries: [LibraryGridEntry<Item>]) -> [LibraryGridEntry<Item>] {
        let orderedIDs = gridOrderStore.orderedIDs(for: entries.map(\.id), scope: currentGridOrderScope)
        let entryByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        return orderedIDs.compactMap { entryByID[$0] }
    }

    private var currentGridOrderScope: LibraryGridOrderScope {
        LibraryGridOrderScope(
            content: selectedContentType == .wallpaper ? .wallpaper : .media,
            collection: selectedSubTab == .favorites ? .favorites : .downloads,
            parentFolderID: selectedContentType == .wallpaper ? currentWallpaperFolderID : currentMediaFolderID
        )
    }

    private func startRenamingFolder(_ folder: LibraryFolder) {
        renameFolderName = folder.name
        renamingFolder = folder
    }

    @ViewBuilder
    private func wallpaperGridItem(item: AnyWallpaperItem, config: LibraryGridConfig) -> some View {
        let card = WallpaperEditCard(
            wallpaper: item.wallpaper,
            localFileURL: item.localFileURL,
            accent: selectedSubTab == .favorites ? LiquidGlassColors.primaryPink : LiquidGlassColors.accentCyan,
            isEditing: isEditing,
            isSelected: selectedItems.contains(item.id),
            downloadDate: item.downloadDate,
            cardWidth: config.cardWidth,
            isCurrentWallpaper: isActiveWallpaperURL(item.localFileURL)
                || isActiveWallpaperURL(item.wallpaper.fullImageURL)
        ) {
            handleWallpaperTap(item.wallpaper)
        }
        .equatable()
        .contextMenu {
            if !wallpaperMoveTargetFolders.isEmpty {
                Menu {
                    ForEach(wallpaperMoveTargetFolders) { folder in
                        Button {
                            moveWallpapersToFolder(ids: [item.id], folderID: folder.id)
                        } label: {
                            Label(folder.name, systemImage: "folder")
                        }
                    }
                } label: {
                    Label(t("move.to.folder"), systemImage: "folder.badge.gearshape")
                }
            }
            if currentWallpaperFolderID != nil {
                Button {
                    gridOrderStore.removeIDs([item.id], from: currentGridOrderScope)
                    folderStore.moveWallpaperToFolder(
                        wallpaperID: item.id,
                        folderID: nil,
                        scope: currentWallpaperFolderScope
                    )
                    updateWallpaperItems()
                } label: {
                    Label(t("remove.from.folder"), systemImage: "folder.badge.minus")
                }
            }
            if let videoURL = VideoOptimizationQueueService.shared.optimizableVideoURL(from: item.localFileURL) {
                Divider()
                Button {
                    _ = VideoOptimizationQueueService.shared.enqueueOptimizeVideo(
                        videoURL: videoURL,
                        title: item.wallpaper.title,
                        targetFPS: FrameInterpolationTargetFPSResolver.targetFPSForManualAction(),
                        source: .manual
                    )
                } label: {
                    Label(t("videoOptimizationOptimizeVideo"), systemImage: "sparkles")
                }
            }
            Divider()
            Button(role: .destructive) {
                pendingWallpaperDeletion = item
            } label: {
                Label(t("delete"), systemImage: "trash")
            }
        }
        // 始终可拖入文件夹（浏览态也需要）；排序插入条仍仅编辑态挂载
        card.draggable(dragPayload(for: item.id))
    }

    // MARK: - Media Section
    private func mediaSection(config: LibraryGridConfig) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // 文件夹导航面包屑
            folderBreadcrumb(
                folderStack: mediaFolderStack,
                isInFolder: currentMediaFolderID != nil,
                onBack: popMediaFolder,
                onRoot: { navigateToMediaFolder(nil) },
                onAdd: { showAddToFolderSheet = true }
            )

            if mediaItems.isEmpty && currentMediaFolders.isEmpty {
                emptyMediaSurface(
                    title: hasActiveLibrarySearch ? t("error.empty.title") : (selectedSubTab == .favorites ? t("no.media.favorites") : t("no.media.downloads")),
                    subtitle: hasActiveLibrarySearch ? t("error.empty.message") : (selectedSubTab == .favorites ? t("no.media.favorites.hint") : t("no.media.downloads.hint")),
                    icon: hasActiveLibrarySearch ? "magnifyingglass" : (selectedSubTab == .favorites ? "heart.slash" : "arrow.down.circle"),
                    accent: LiquidGlassColors.secondaryViolet
                )
            } else {
                libraryWaterfallGrid(
                    entries: orderedMediaGridItems,
                    config: config,
                    estimatedHeight: LibraryCardMetrics.thumbnailHeight + 56
                ) { entry in
                    mediaGridEntry(entry, config: config)
                }
            }
        }
    }

    @ViewBuilder
    private func mediaGridEntry(_ entry: LibraryGridEntry<AnyMediaItem>, config: LibraryGridConfig) -> some View {
        switch entry {
        case .folder(let folder):
            mediaFolderCard(folder: folder, config: config)
                .overlay(alignment: .leading) {
                    if isEditing {
                        insertionDropZone(before: entry.id)
                    }
                }
        case .item(let item):
            mediaGridItem(item: item, config: config)
                .overlay(alignment: .leading) {
                    if isEditing {
                        insertionDropZone(before: entry.id)
                    }
                }
                .onAppear {
                    libraryScrollRuntimeState.lastMediaItemID = item.id
                    preloadNearbyMedia(around: item)
                }
        }
    }

    private func mediaFolderCard(folder: LibraryFolder, config: LibraryGridConfig) -> some View {
        let display = mediaFolderDisplay[folder.id] ?? FolderDisplayInfo(previewURLs: [], itemCount: 0)
        _ = folderUnlockRevision
        let isUnlocked = FolderLockService.shared.isFolderUnlocked(folder.id)
        return LibraryFolderCard(
            folder: folder,
            previewURLs: display.previewURLs,
            itemCount: display.itemCount,
            cardWidth: config.cardWidth,
            isEditing: isEditing,
            isUnlocked: isUnlocked,
            dragPayload: dragPayload(for: "folder_\(folder.id)"),
            onTap: { handleFolderTap(folder) },
            onDrop: { ids in moveMediasToFolder(ids: ids, folderID: folder.id) },
            onDisband: {
                folderStore.deleteFolder(id: folder.id, contentType: .media)
                gridOrderStore.removeIDs(["folder_\(folder.id)"], from: currentGridOrderScope)
                updateMediaItems()
            },
            onDelete: {
                deleteFolderWithContents(folderID: folder.id, contentType: .media)
            },
            onRename: { startRenamingFolder(folder) },
            onToggleLock: {
                folderStore.toggleFolderLock(id: folder.id, contentType: .media)
            },
            onRelock: {
                FolderLockService.shared.lockFolder(folder.id)
            },
            onOptimizeVideos: {
                _ = VideoOptimizationQueueService.shared.enqueueLibraryFolder(folder)
            },
            onRedownloadAll: selectedSubTab == .downloads && display.itemCount > 0 ? {
                pendingRedownloadMediaFolder = folder
                showRedownloadMediaFolderConfirm = true
            } : nil
        )
    }

    private func navigateToMediaFolder(_ folderID: String?) {
        if let current = currentMediaFolderID, folderID != nil {
            mediaFolderStack.append(current)
        }
        currentMediaFolderID = folderID
        updateMediaItems()
    }

    private func popMediaFolder() {
        guard !mediaFolderStack.isEmpty else {
            currentMediaFolderID = nil
            updateMediaItems()
            return
        }
        currentMediaFolderID = mediaFolderStack.popLast()
        updateMediaItems()
    }

    private func moveMediasToFolder(ids: [String], folderID: String) {
        let normalizedFolderID = MediaLibraryService.normalizedFolderID(folderID)
        gridOrderStore.removeIDs(Set(ids), from: currentGridOrderScope)
        let scope = currentMediaFolderScope
        let unifiedByID: [String: UnifiedLocalMedia] = Dictionary(
            uniqueKeysWithValues: mediaViewModel.allLocalMedia.map { ($0.id, $0) }
        )
        for id in ids {
            let fallback: (item: MediaItem, fileURL: URL)?
            if scope == .downloads, let unified = unifiedByID[id], unified.downloadRecord == nil {
                fallback = (unified.mediaItem, unified.fileURL)
            } else {
                fallback = nil
            }
            folderStore.moveMediaToFolder(
                mediaID: id,
                folderID: normalizedFolderID,
                scope: scope,
                fallback: fallback
            )
        }
        updateMediaItems()
    }

    private var currentMediaItems: [AnyMediaItem] {
        mediaItems
    }

    private var activeRatioFilter: WallpaperRatioFilter {
        selectedContentType == .wallpaper ? wallpaperRatioFilter : mediaRatioFilter
    }

    @ViewBuilder
    private func mediaGridItem(item: AnyMediaItem, config: LibraryGridConfig) -> some View {
        let card = MediaVideoCard(
            item: item.mediaItem,
            localMediaFileURL: item.localFileURL,
            badgeText: selectedSubTab == .favorites ? t("badge.favorite") : item.mediaItem.resolutionLabel,
            accent: selectedSubTab == .favorites ? LiquidGlassColors.primaryPink : LiquidGlassColors.accentCyan,
            isEditing: isEditing,
            isSelected: selectedItems.contains(item.id),
            cardWidth: config.cardWidth,
            thumbnailURL: item.thumbnailURL,
            shouldProbeAnimatedThumbnail: item.shouldProbeAnimatedThumbnail,
            resolvedVideoFileURL: item.resolvedVideoFileURL,
            isVisible: isVisible,
            isCurrentWallpaper: isActiveWallpaperURL(item.localFileURL)
                || isActiveWallpaperURL(item.resolvedVideoFileURL)
        ) {
            handleMediaTap(item.mediaItem)
        }
        .equatable()
        .contextMenu {
            if !mediaMoveTargetFolders.isEmpty {
                Menu {
                    ForEach(mediaMoveTargetFolders) { folder in
                        Button {
                            moveMediasToFolder(ids: [item.id], folderID: folder.id)
                        } label: {
                            Label(folder.name, systemImage: "folder")
                        }
                    }
                } label: {
                    Label(t("move.to.folder"), systemImage: "folder.badge.gearshape")
                }
            }
            if currentMediaFolderID != nil {
                Button {
                    gridOrderStore.removeIDs([item.id], from: currentGridOrderScope)
                    folderStore.moveMediaToFolder(
                        mediaID: item.id,
                        folderID: nil,
                        scope: currentMediaFolderScope
                    )
                    updateMediaItems()
                } label: {
                    Label(t("remove.from.folder"), systemImage: "folder.badge.minus")
                }
            }
            if selectedSubTab == .downloads, canRedownloadMediaItem(item.mediaItem) {
                Button {
                    pendingRedownloadMediaItem = item.mediaItem
                    showRedownloadMediaItemConfirm = true
                } label: {
                    Label(t("library.redownload.item"), systemImage: "arrow.clockwise.circle")
                }
            }
            // Scene 烘焙 MP4 优先：纯 scene 工程目录本身没有视频，不能只看 localFileURL。
            if let videoURL = VideoOptimizationQueueService.shared.optimizableVideoURL(
                forMediaItem: item.mediaItem,
                localURL: item.localFileURL
            ) {
                Divider()
                Button {
                    _ = VideoOptimizationQueueService.shared.enqueueOptimizeVideo(
                        videoURL: videoURL,
                        title: item.mediaItem.title,
                        targetFPS: FrameInterpolationTargetFPSResolver.targetFPSForManualAction(),
                        source: .manual
                    )
                } label: {
                    Label(t("videoOptimizationOptimizeVideo"), systemImage: "sparkles")
                }
            }
            Divider()
            Button(role: .destructive) {
                pendingMediaDeletion = item
            } label: {
                Label(t("delete"), systemImage: "trash")
            }
        }
        // 始终可拖入文件夹（浏览态也需要）；排序插入条仍仅编辑态挂载
        card.draggable(dragPayload(for: item.id))
    }

    private func dragPayload(for itemID: String) -> String {
        let selectedMovableIDs = selectedItems
            .filter { currentItemIDs.contains($0) }

        guard selectedItems.contains(itemID), !selectedMovableIDs.isEmpty else {
            return "waifux:item:\(itemID)"
        }

        return "waifux:items:\(selectedMovableIDs.sorted().joined(separator: "\n"))"
    }

    // MARK: - 拖拽反馈辅助

    /// 单条插入条 drop zone：贴在卡片左侧内缘，命中时显示一根蓝色指示条。
    /// 占用卡片左侧约 14pt 命中宽。不挡卡片其他区域的点击/hover。
    @ViewBuilder
    private func insertionDropZone(before entryID: String) -> some View {
        let isActive = hoveredInsertionID == entryID
        ZStack(alignment: .leading) {
            if isActive {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Color.accentColor)
                    .frame(width: 3)
                    .padding(.vertical, 6)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
            Color.clear
                .frame(width: 14)
                .contentShape(Rectangle())
                .dropDestination(for: String.self) { payloads, _ in
                    handleGridReorderDrop(payloads, before: entryID)
                } isTargeted: { hovering in
                    if hovering {
                        hoveredInsertionID = entryID
                    } else if hoveredInsertionID == entryID {
                        hoveredInsertionID = nil
                    }
                }
        }
        .frame(maxHeight: .infinity)
        .animation(.easeOut(duration: 0.12), value: isActive)
    }

    /// 处理排序 drop。
    /// - Parameter targetID: 插入到该 entry 之前；传 nil 表示插入到末尾。
    @discardableResult
    private func handleGridReorderDrop(_ payloads: [String], before targetID: String?) -> Bool {
        let movingIDs = uniqueIDs(payloads.flatMap(parseDropPayload))
            .filter { currentItemIDs.contains($0) }
        guard !movingIDs.isEmpty else { return false }

        withAnimation(.spring(response: 0.36, dampingFraction: 0.85)) {
            gridOrderStore.reorder(
                moving: movingIDs,
                before: targetID,
                availableIDs: currentItemIDs,
                scope: currentGridOrderScope
            )
            updateWallpaperItems()
            updateMediaItems()
            hoveredInsertionID = nil
        }
        return true
    }

    private func parseDropPayload(_ payload: String) -> [String] {
        if payload.hasPrefix("waifux:items:") {
            return String(payload.dropFirst(13))
                .split(separator: "\n")
                .map(String.init)
                .filter { !$0.isEmpty }
        }
        if payload.hasPrefix("waifux:item:") {
            return [String(payload.dropFirst(12))]
        }
        return []
    }

    private func uniqueIDs(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    // MARK: - Image Preloading
    //
    // ⚡ 滚动时每个 grid item 的 .onAppear 都会调 preloadNearbyXxx；旧实现内部走
    // `firstIndex(where:)` 是 O(N)，大库（数千项）时每次滚动 mount 几十张就会做几十次
    // 全表扫描。改用 ID→Index 字典做 O(1) 查找。

    private func resumeLibraryPrefetchAfterScroll() {
        switch selectedContentType {
        case .wallpaper:
            guard let id = libraryScrollRuntimeState.lastWallpaperItemID,
                  let index = wallpaperIDIndexCache[id] else { return }
            preloadNearbyWallpapers(at: index)
        case .video:
            guard let id = libraryScrollRuntimeState.lastMediaItemID,
                  let index = mediaIDIndexCache[id] else { return }
            preloadNearbyMedia(at: index)
        case .anime:
            guard let id = libraryScrollRuntimeState.lastAnimeItemID,
                  let index = animeIDIndexCache[id] else { return }
            preloadNearbyAnime(at: index)
        }
    }

    private func preloadNearbyWallpapers(around item: AnyWallpaperItem) {
        guard let index = wallpaperIDIndexCache[item.id] else { return }
        preloadNearbyWallpapers(at: index)
    }

    private func preloadNearbyWallpapers(at index: Int) {
        // 快速滚动时跳过预取/SSD 生成，避免与滚动抢 I/O 与主线程
        guard !LibraryScrollHoverGate.shared.isScrolling,
              wallpaperItems.indices.contains(index) else { return }
        let bucket = prefetchBucket(for: index)
        guard lastWallpaperPrefetchBucket != bucket else { return }
        lastWallpaperPrefetchBucket = bucket

        let targetSize = CGSize(width: 512, height: 512)
        let range = prefetchRange(around: index, totalCount: wallpaperItems.count)
        // 优先本机 SSD 列表缩略图 / 站点 thumb，绝不 prefetch 外置原图路径
        let urls = range
            .filter { $0 != index }
            .compactMap { idx -> URL? in
                let entry = wallpaperItems[idx]
                if let local = entry.localFileURL,
                   LocalImageThumbnailCache.isRasterImageFile(local),
                   let cached = LocalImageThumbnailCache.shared.cachedThumbnailURLIfExists(forLocalFile: local) {
                    return cached
                }
                return entry.wallpaper.thumbURL ?? entry.wallpaper.smallThumbURL
            }

        ForegroundPrefetchManager.shared.stop(namespace: wallpaperPrefetchNamespace)
        ForegroundPrefetchManager.shared.start(
            urls: urls,
            options: [.processor(DownsamplingImageProcessor(size: targetSize))],
            namespace: wallpaperPrefetchNamespace
        )

        // 后台为附近静图生成 SSD 缩略图；滚动中不启动，滚停后由卡片 ensure 补齐
        let nearbyLocals = range.compactMap { wallpaperItems[$0].localFileURL }
            .filter { LocalImageThumbnailCache.isRasterImageFile($0) }
        if !nearbyLocals.isEmpty {
            Task { @MainActor in
                guard !LibraryScrollHoverGate.shared.isScrolling else { return }
                for url in nearbyLocals.prefix(8) {
                    if LibraryScrollHoverGate.shared.isScrolling { return }
                    _ = await LocalImageThumbnailCache.shared.ensureThumbnail(forLocalFile: url)
                }
            }
        }
    }

    private func preloadNearbyMedia(around item: AnyMediaItem) {
        guard let index = mediaIDIndexCache[item.id] else { return }
        preloadNearbyMedia(at: index)
    }

    private func preloadNearbyMedia(at index: Int) {
        guard !LibraryScrollHoverGate.shared.isScrolling,
              currentMediaItems.indices.contains(index) else { return }
        let bucket = prefetchBucket(for: index)
        guard lastMediaPrefetchBucket != bucket else { return }
        lastMediaPrefetchBucket = bucket

        let targetSize = CGSize(width: 512, height: 512)
        let range = prefetchRange(around: index, totalCount: currentMediaItems.count)
        let urls = range
            .filter { $0 != index }
            .map { currentMediaItems[$0] }
            .map(\.thumbnailURL)

        ForegroundPrefetchManager.shared.stop(namespace: mediaPrefetchNamespace)
        ForegroundPrefetchManager.shared.start(
            urls: urls,
            options: [.processor(DownsamplingImageProcessor(size: targetSize))],
            namespace: mediaPrefetchNamespace
        )
    }

    private func preloadNearbyAnime(around anime: AnimeSearchResult) {
        guard let index = animeIDIndexCache[anime.id] else { return }
        preloadNearbyAnime(at: index)
    }

    private func preloadNearbyAnime(at index: Int) {
        guard !LibraryScrollHoverGate.shared.isScrolling,
              currentAnimeItems.indices.contains(index) else { return }
        let bucket = prefetchBucket(for: index)
        guard lastAnimePrefetchBucket != bucket else { return }
        lastAnimePrefetchBucket = bucket

        let targetSize = CGSize(width: 512, height: 512)
        let range = prefetchRange(around: index, totalCount: currentAnimeItems.count)
        let urls = range
            .filter { $0 != index }
            .compactMap { URL(string: currentAnimeItems[$0].coverURL ?? "") }

        ForegroundPrefetchManager.shared.stop(namespace: animePrefetchNamespace)
        ForegroundPrefetchManager.shared.start(
            urls: urls,
            options: [.processor(DownsamplingImageProcessor(size: targetSize))],
            namespace: animePrefetchNamespace
        )
    }

    private func prefetchBucket(for index: Int) -> Int {
        // 更粗的 bucket：减少滚动时 stop/start prefetcher 频率
        index / 8
    }

    private func prefetchRange(around index: Int, totalCount: Int) -> Range<Int> {
        // 收窄窗口：±5，降低 Kingfisher 与磁盘压力
        max(0, index - 5)..<min(totalCount, index + 6)
    }

    private func refreshWallpaperFolderDisplay() {
        let folders = currentWallpaperFolders
        guard !folders.isEmpty else {
            wallpaperFolderDisplay = [:]
            return
        }

        // ⚡ O(N) 预分组：按 folderID 建索引，避免对每个文件夹线性扫描全部记录。
        // 收藏/下载集合各自只读对应记录，避免跨集合污染封面与计数。
        var next: [String: FolderDisplayInfo] = [:]
        var warmupTargets: [(local: URL?, remote: URL?)] = []

        if selectedSubTab == .favorites {
            var favoriteByFolder: [String: [WallpaperFavoriteRecord]] = [:]
            for r in WallpaperLibraryService.shared.favoriteRecords where r.isActive {
                guard let fid = WallpaperLibraryService.normalizedFolderID(r.folderID) else { continue }
                favoriteByFolder[fid, default: []].append(r)
            }
            for folder in folders {
                let wallpapers = favoriteByFolder[folder.id, default: []].map(\.wallpaper)
                let preview = Self.wallpaperFolderPreviewURLs(from: wallpapers, localPathByID: [:])
                next[folder.id] = FolderDisplayInfo(
                    previewURLs: preview.urls,
                    itemCount: wallpapers.count
                )
                warmupTargets.append(contentsOf: preview.warmup)
            }
        } else {
            var downloadedByFolder: [String: [WallpaperDownloadRecord]] = [:]
            for r in WallpaperLibraryService.shared.downloadRecords where r.isActive {
                guard let fid = WallpaperLibraryService.normalizedFolderID(r.folderID) else { continue }
                downloadedByFolder[fid, default: []].append(r)
            }
            for folder in folders {
                let records = downloadedByFolder[folder.id, default: []]
                let wallpapers = records.map(\.wallpaper)
                var localPathByID: [String: URL] = [:]
                for r in records {
                    localPathByID[r.wallpaper.id] = r.localFileURL
                }
                let preview = Self.wallpaperFolderPreviewURLs(from: wallpapers, localPathByID: localPathByID)
                next[folder.id] = FolderDisplayInfo(
                    previewURLs: preview.urls,
                    itemCount: wallpapers.count
                )
                warmupTargets.append(contentsOf: preview.warmup)
            }
        }
        wallpaperFolderDisplay = next
        scheduleWallpaperFolderPreviewWarmup(targets: warmupTargets)
    }

    /// 壁纸夹叠图：优先本机 SSD 列表小图 / 本地文件，再远程 thumb（避免夹外永远糊远程图）。
    private static func wallpaperFolderPreviewURLs(
        from wallpapers: [Wallpaper],
        localPathByID: [String: URL]
    ) -> (urls: [URL], warmup: [(local: URL?, remote: URL?)]) {
        var urls: [URL] = []
        var warmup: [(local: URL?, remote: URL?)] = []
        urls.reserveCapacity(3)
        for wallpaper in wallpapers.prefix(3) {
            let local = localPathByID[wallpaper.id]
                ?? WallpaperLibraryService.shared.localFileURLIfAvailable(for: wallpaper)
            let remote = wallpaper.thumbURL ?? wallpaper.smallThumbURL
            if let local, local.isFileURL {
                if LocalImageThumbnailCache.isRasterImageFile(local),
                   let cached = LocalImageThumbnailCache.shared.cachedThumbnailURLIfExists(forLocalFile: local) {
                    urls.append(cached)
                    continue
                }
                // 无 SSD 小图：先远程占位，后台预热
                if let remote {
                    urls.append(remote)
                } else {
                    urls.append(local)
                }
                warmup.append((local, remote))
            } else if let remote {
                urls.append(remote)
            }
        }
        return (urls, warmup)
    }

    private func scheduleWallpaperFolderPreviewWarmup(targets: [(local: URL?, remote: URL?)]) {
        let needWarmup = targets.compactMap(\.local).filter { local in
            LocalImageThumbnailCache.isRasterImageFile(local)
                && LocalImageThumbnailCache.shared.cachedThumbnailURLIfExists(forLocalFile: local) == nil
        }
        guard !needWarmup.isEmpty else { return }

        folderPreviewWarmupTask?.cancel()
        folderPreviewWarmupTask = Task { @MainActor in
            var any = false
            for url in needWarmup.prefix(12) {
                guard !Task.isCancelled else { return }
                if await LocalImageThumbnailCache.shared.ensureThumbnail(forLocalFile: url) != nil {
                    any = true
                }
            }
            guard any, !Task.isCancelled else { return }
            // 小图落盘后重算夹外预览，替换远程糊图
            refreshWallpaperFolderDisplayWithoutWarmup()
        }
    }

    /// 预热完成后刷新，避免递归再 schedule 同一批任务。
    private func refreshWallpaperFolderDisplayWithoutWarmup() {
        let folders = currentWallpaperFolders
        guard !folders.isEmpty else {
            wallpaperFolderDisplay = [:]
            return
        }
        var next: [String: FolderDisplayInfo] = [:]
        if selectedSubTab == .favorites {
            var favoriteByFolder: [String: [WallpaperFavoriteRecord]] = [:]
            for r in WallpaperLibraryService.shared.favoriteRecords where r.isActive {
                guard let fid = WallpaperLibraryService.normalizedFolderID(r.folderID) else { continue }
                favoriteByFolder[fid, default: []].append(r)
            }
            for folder in folders {
                let wallpapers = favoriteByFolder[folder.id, default: []].map(\.wallpaper)
                let preview = Self.wallpaperFolderPreviewURLs(from: wallpapers, localPathByID: [:])
                next[folder.id] = FolderDisplayInfo(previewURLs: preview.urls, itemCount: wallpapers.count)
            }
        } else {
            var downloadedByFolder: [String: [WallpaperDownloadRecord]] = [:]
            for r in WallpaperLibraryService.shared.downloadRecords where r.isActive {
                guard let fid = WallpaperLibraryService.normalizedFolderID(r.folderID) else { continue }
                downloadedByFolder[fid, default: []].append(r)
            }
            for folder in folders {
                let records = downloadedByFolder[folder.id, default: []]
                let wallpapers = records.map(\.wallpaper)
                var localPathByID: [String: URL] = [:]
                for r in records {
                    localPathByID[r.wallpaper.id] = r.localFileURL
                }
                let preview = Self.wallpaperFolderPreviewURLs(from: wallpapers, localPathByID: localPathByID)
                next[folder.id] = FolderDisplayInfo(previewURLs: preview.urls, itemCount: wallpapers.count)
            }
        }
        wallpaperFolderDisplay = next
    }

    private func refreshMediaFolderDisplay() {
        let folders = currentMediaFolders
        guard !folders.isEmpty else {
            mediaFolderDisplay = [:]
            return
        }

        // ⚡ O(N) 预分组；收藏/下载各自只读对应记录
        var next: [String: FolderDisplayInfo] = [:]
        var warmupItems: [(item: MediaItem, local: URL?)] = []

        if selectedSubTab == .favorites {
            var favoriteByFolder: [String: [MediaFavoriteRecord]] = [:]
            for r in MediaLibraryService.shared.favoriteRecords where r.isActive {
                guard let fid = MediaLibraryService.normalizedFolderID(r.folderID) else { continue }
                favoriteByFolder[fid, default: []].append(r)
            }
            for folder in folders {
                let items = favoriteByFolder[folder.id, default: []].map(\.item)
                // 收藏也可能已下载：尽量解析本地路径，夹外才能用抽帧
                let previewURLs: [URL] = items.prefix(3).map { item in
                    let local = MediaLibraryService.shared.localFileURLIfAvailable(for: item)
                    if let local { warmupItems.append((item, local)) }
                    return item.libraryFolderThumbnailURL(localFileURL: local)
                }
                next[folder.id] = FolderDisplayInfo(
                    previewURLs: previewURLs,
                    itemCount: items.count
                )
            }
        } else {
            var downloadedByFolder: [String: [MediaDownloadRecord]] = [:]
            for r in MediaLibraryService.shared.downloadRecords where r.isActive {
                guard let fid = MediaLibraryService.normalizedFolderID(r.folderID) else { continue }
                downloadedByFolder[fid, default: []].append(r)
            }
            for folder in folders {
                let records = downloadedByFolder[folder.id, default: []]
                var items: [MediaItem] = []
                var localPaths: [String: URL] = [:]
                var seen = Set<String>()
                for r in records {
                    guard seen.insert(r.item.id).inserted else { continue }
                    items.append(r.item)
                    localPaths[r.item.id] = URL(fileURLWithPath: r.localFilePath)
                }
                let previewURLs = items.prefix(3).map { item -> URL in
                    let local = localPaths[item.id]
                    warmupItems.append((item, local))
                    return item.libraryFolderThumbnailURL(localFileURL: local)
                }
                next[folder.id] = FolderDisplayInfo(
                    previewURLs: previewURLs,
                    itemCount: items.count
                )
            }
        }
        mediaFolderDisplay = next
        scheduleMediaFolderPreviewWarmup(targets: warmupItems)
    }

    /// 夹外叠图：后台为前若干项生成列表抽帧/静图小图，完成后刷新 display。
    private func scheduleMediaFolderPreviewWarmup(targets: [(item: MediaItem, local: URL?)]) {
        guard !targets.isEmpty else { return }
        // 去重，限制总量，避免一次对整库外置卡抽帧
        var seen = Set<String>()
        let unique = targets.filter { seen.insert($0.item.id).inserted }.prefix(18)

        folderPreviewWarmupTask?.cancel()
        folderPreviewWarmupTask = Task { @MainActor in
            var any = false
            for entry in unique {
                guard !Task.isCancelled else { return }
                if await entry.item.ensureFolderPreviewCache(localFileURL: entry.local) {
                    any = true
                }
            }
            guard any, !Task.isCancelled else { return }
            refreshMediaFolderDisplayWithoutWarmup()
        }
    }

    private func refreshMediaFolderDisplayWithoutWarmup() {
        let folders = currentMediaFolders
        guard !folders.isEmpty else {
            mediaFolderDisplay = [:]
            return
        }
        var next: [String: FolderDisplayInfo] = [:]
        if selectedSubTab == .favorites {
            var favoriteByFolder: [String: [MediaFavoriteRecord]] = [:]
            for r in MediaLibraryService.shared.favoriteRecords where r.isActive {
                guard let fid = MediaLibraryService.normalizedFolderID(r.folderID) else { continue }
                favoriteByFolder[fid, default: []].append(r)
            }
            for folder in folders {
                let items = favoriteByFolder[folder.id, default: []].map(\.item)
                let previewURLs = items.prefix(3).map { item in
                    item.libraryFolderThumbnailURL(
                        localFileURL: MediaLibraryService.shared.localFileURLIfAvailable(for: item)
                    )
                }
                next[folder.id] = FolderDisplayInfo(previewURLs: previewURLs, itemCount: items.count)
            }
        } else {
            var downloadedByFolder: [String: [MediaDownloadRecord]] = [:]
            for r in MediaLibraryService.shared.downloadRecords where r.isActive {
                guard let fid = MediaLibraryService.normalizedFolderID(r.folderID) else { continue }
                downloadedByFolder[fid, default: []].append(r)
            }
            for folder in folders {
                let records = downloadedByFolder[folder.id, default: []]
                var items: [MediaItem] = []
                var localPaths: [String: URL] = [:]
                var seen = Set<String>()
                for r in records {
                    guard seen.insert(r.item.id).inserted else { continue }
                    items.append(r.item)
                    localPaths[r.item.id] = URL(fileURLWithPath: r.localFilePath)
                }
                let previewURLs = items.prefix(3).map {
                    $0.libraryFolderThumbnailURL(localFileURL: localPaths[$0.id])
                }
                next[folder.id] = FolderDisplayInfo(previewURLs: previewURLs, itemCount: items.count)
            }
        }
        mediaFolderDisplay = next
    }

    // MARK: - Anime Section
    private func animeSection(config: AnimeGridConfig) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if currentAnimeItems.isEmpty {
                emptyMediaSurface(
                    title: hasActiveLibrarySearch ? t("error.empty.title") : t("no.anime.favorites"),
                    subtitle: hasActiveLibrarySearch ? t("error.empty.message") : t("no.anime.favorites.hint"),
                    icon: hasActiveLibrarySearch ? "magnifyingglass" : "heart.slash",
                    accent: LiquidGlassColors.tertiaryBlue
                )
            } else {
                let animeCardHeight = config.cardWidth * 1.4 + 52

                // ⚡ 改用 LazyVGrid：动漫卡片高度统一，不需要瀑布流多列对齐。
                LazyVGrid(columns: config.gridItems, alignment: .leading, spacing: config.spacing) {
                    ForEach(currentAnimeItems) { anime in
                        AnimeLibraryCard(
                            anime: anime,
                            isEditing: isEditing,
                            isSelected: selectedItems.contains(anime.id),
                            cardWidth: config.cardWidth
                        ) {
                            handleAnimeTap(anime)
                        }
                        .onAppear {
                            libraryScrollRuntimeState.lastAnimeItemID = anime.id
                            preloadNearbyAnime(around: anime)
                        }
                        .frame(height: animeCardHeight)
                    }
                }
            }
        }
    }

    private var currentAnimeItems: [AnimeSearchResult] {
        // 动漫目前只有收藏
        guard hasActiveLibrarySearch else { return animeFavorites }
        let query = trimmedLibrarySearchQuery
        return animeFavorites.filter { matchesLibrarySearch(for: $0, query: query) }
    }

    // MARK: - Section Header
    // MARK: - 同步订阅 - Profile ID 输入 Sheet

    @State private var syncProfileInput: String = ""

    private var syncProfileSheet: some View {
        VStack(spacing: 20) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 32))
                .foregroundStyle(Color.accentColor)

            Text("同步 Steam 订阅")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)

            Text("请输入你的 Steam 社区档案 ID（64位数字ID 或 自定义URL）\n例如：76561198113134000 或 customurl")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .lineSpacing(4)

            TextField("Steam Profile ID", text: $syncProfileInput)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 14))
                .padding(.horizontal, 20)
                .onAppear {
                    syncProfileInput = workshopSourceManager.steamProfileID
                }

            HStack(spacing: 12) {
                Button("取消") {
                    showSyncProfileSheet = false
                }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )

                Button("保存并继续") {
                    let trimmed = syncProfileInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    workshopSourceManager.steamProfileID = trimmed
                    showSyncProfileSheet = false
                    Task { await fetchSubscriptionList() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.accentColor.opacity(0.5))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
                )
                .disabled(syncProfileInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(30)
        .frame(width: 400)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(hex: "1C1C1E"))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
        )
    }

    // MARK: - 同步订阅 - 选择列表 Sheet

    private var syncSelectionSheet: some View {
        VStack(spacing: 0) {
            // 标题区
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("选择要同步的订阅")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                    Text("已过滤掉已下载的项目，共 \(syncSubscribedItems.count) 个待同步")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
                Button("全选") {
                    let allIDs = Set(syncSubscribedItems.map(\.id))
                    if syncSelectedIDs == allIDs {
                        syncSelectedIDs = []
                    } else {
                        syncSelectedIDs = allIDs
                    }
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .buttonStyle(.plain)
                .pointingHandCursor()
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 12)

            Divider()
                .background(Color.white.opacity(0.1))

            if syncIsLoadingList {
                Spacer()
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在获取订阅列表...")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.6))
                }
                Spacer()
            } else if syncSubscribedItems.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 32))
                        .foregroundStyle(.green.opacity(0.7))
                    Text("所有订阅已同步完成")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(syncSubscribedItems) { item in
                            syncSelectionRow(item: item)
                            Divider()
                                .background(Color.white.opacity(0.05))
                                .padding(.leading, 60)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Divider()
                .background(Color.white.opacity(0.1))

            // 底部确认区
            HStack {
                Text("已选择 \(syncSelectedIDs.count) 项")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))

                Spacer()

                Button("取消") {
                    showSyncSelectionSheet = false
                    syncSubscribedItems = []
                    syncSelectedIDs = []
                }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )

                Button {
                    let selectedItems = syncSubscribedItems.filter { syncSelectedIDs.contains($0.id) }
                    showSyncSelectionSheet = false
                    syncSubscribedItems = []
                    syncSelectedIDs = []
                    Task { await downloadSelectedSubscriptions(selectedItems) }
                } label: {
                    HStack(spacing: 6) {
                        if isSyncingSubscriptions {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.7)
                        }
                        Text("确认下载 (\(syncSelectedIDs.count))")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(syncSelectedIDs.isEmpty
                                  ? Color.white.opacity(0.05)
                                  : Color.accentColor.opacity(0.5))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(syncSelectedIDs.isEmpty
                                    ? Color.white.opacity(0.05)
                                    : Color.accentColor.opacity(0.3), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .disabled(syncSelectedIDs.isEmpty || isSyncingSubscriptions)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .frame(width: 520, height: 480)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(hex: "1C1C1E"))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
        )
    }

    private func syncSelectionRow(item: WorkshopWallpaper) -> some View {
        Button {
            if syncSelectedIDs.contains(item.id) {
                syncSelectedIDs.remove(item.id)
            } else {
                syncSelectedIDs.insert(item.id)
            }
        } label: {
            HStack(spacing: 12) {
                // 复选框
                Image(systemName: syncSelectedIDs.contains(item.id) ? "checkmark.square.fill" : "square")
                    .font(.system(size: 18))
                    .foregroundStyle(syncSelectedIDs.contains(item.id)
                                     ? Color.accentColor
                                     : .white.opacity(0.3))

                // 预览图（使用 Kingfisher 缓存，避免滚动时重复加载）
                KFImage(item.previewURL)
                    .fade(duration: 0.2)
                    .placeholder { _ in
                        Color.gray.opacity(0.2)
                    }
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 48, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(item.type.rawValue.capitalized)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.accentColor.opacity(0.7))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15))
                            .cornerRadius(3)
                        if let subs = item.subscriptions {
                            Text("\(formatStat(subs)) 订阅")
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .background(
            Color.white.opacity(syncSelectedIDs.contains(item.id) ? 0.04 : 0)
        )
    }

    private func formatStat(_ count: Int) -> String {
        if count >= 10000 {
            return String(format: "%.1fw", Double(count) / 10000)
        } else if count >= 1000 {
            return String(format: "%.1fk", Double(count) / 1000)
        }
        return "\(count)"
    }

    // MARK: - 添加到文件夹弹窗

    private var addToFolderSheetContent: some View {
        AddToFolderSheetView(
            contentType: selectedContentType,
            subTab: selectedSubTab,
            availableWallpapers: availableWallpapersForFolder,
            availableMedia: availableMediaForFolder,
            onAdd: { selectedIDs in
                addSelectedItemsToFolder(ids: selectedIDs)
            },
            onDismiss: {
                showAddToFolderSheet = false
            }
        )
    }

    private func addSelectedItemsToFolder(ids: [String]) {
        switch selectedContentType {
        case .wallpaper:
            // 只允许在已进入某个文件夹时添加；根目录没有目标 folderID
            if let folderID = currentWallpaperFolderID {
                moveWallpapersToFolder(ids: ids, folderID: folderID)
            }
        case .video:
            if let folderID = currentMediaFolderID {
                moveMediasToFolder(ids: ids, folderID: folderID)
            }
        case .anime:
            break
        }
        showAddToFolderSheet = false
    }

    private var librarySearchControl: some View {
        HStack(spacing: 0) {
            if isLibrarySearchExpanded {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))

                    TextField(t("search.placeholder"), text: $librarySearchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))
                        .focused($isLibrarySearchFocused)
                        .onSubmit {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                isLibrarySearchExpanded = false
                            }
                        }
                        .onExitCommand {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                isLibrarySearchExpanded = false
                            }
                        }

                    if !librarySearchQuery.isEmpty {
                        Button {
                            librarySearchQuery = ""
                            // 清空后自动收起
                            withAnimation(.easeInOut(duration: 0.25)) {
                                isLibrarySearchExpanded = false
                            }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .frame(maxWidth: 240)
                .frame(height: 42)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        isLibrarySearchExpanded = true
                        isLibrarySearchFocused = true
                    }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.88))
                        .frame(width: 42, height: 42)
                }
                .buttonStyle(.plain)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .liquidGlassSurface(.regular, in: Capsule(style: .continuous), lightweight: true)
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        .clipped()
        .animation(.easeInOut(duration: 0.25), value: isLibrarySearchExpanded)
        .onChange(of: isLibrarySearchFocused) { _, focused in
            if !focused {
                withAnimation(.easeInOut(duration: 0.25)) {
                    isLibrarySearchExpanded = false
                }
            }
        }
    }

    private func libraryToolbarActions(tint: Color) -> some View {
        HStack(spacing: 8) {
            // 编辑模式下：全选 + 删除 放在完成左边
            if isEditing {
                let totalCount = selectableItemCount
                // 全选/取消全选
                Button {
                    toggleSelectAll()
                } label: {
                    Text(selectedItems.count == totalCount ? t("deselect.all") : t("select.all"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(.regularMaterial)
                                .opacity(0.5)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.white.opacity(0.15), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .pointingHandCursor()

                // 删除按钮
                Button {
                    deleteSelectedItems()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "trash")
                            .font(.system(size: 12, weight: .semibold))
                        Text("\(t("delete")) (\(selectedItems.count))")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.red.opacity(0.7))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.red.opacity(0.4), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .disabled(selectedItems.isEmpty)
                .opacity(selectedItems.isEmpty ? 0.5 : 1)
            }

            toolbarCapsuleButton(
                title: isEditing ? t("done") : t("edit"),
                systemImage: isEditing ? "checkmark.circle.fill" : "checkmark.circle",
                tint: tint,
                prominence: isEditing ? .primary : .secondary
            ) {
                withAnimation {
                    isEditing.toggle()
                    selectedItems.removeAll()
                }
            }

            if selectedContentType != .anime {
                toolbarCapsuleButton(
                    title: t("new.folder"),
                    systemImage: "folder.badge.plus",
                    tint: tint,
                    prominence: .secondary
                ) {
                    showNewFolderSheet = true
                }

                // 统一导入按钮（仅下载标签下显示）
                if selectedSubTab == .downloads {
                    toolbarCapsuleButton(
                        title: t("import"),
                        systemImage: "square.and.arrow.down",
                        tint: tint,
                        prominence: .primary
                    ) {
                        startImport()
                    }
                }
            }

            libraryUtilityMenu(tint: tint)
        }
    }

    private var subTabDropdown: some View {
        Menu {
            ForEach(SubTab.allCases, id: \.self) { tab in
                Button(tab.title) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedSubTab = tab
                        isEditing = false
                        selectedItems.removeAll()
                    }
                }
            }
        } label: {
            Text(selectedSubTab.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .liquidGlassSurface(.regular, in: RoundedRectangle(cornerRadius: 8, style: .continuous), lightweight: true)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                )
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: true, vertical: false)
        .pointingHandCursor()
    }

    private func wallpaperRatioPicker(color: Color) -> some View {
        HStack(spacing: 0) {
            ForEach(WallpaperRatioFilter.allCases, id: \.self) { filter in
                Button {
                    wallpaperRatioFilter = filter
                    isEditing = false
                    selectedItems.removeAll()
                } label: {
                    Text(filter.title)
                        .font(.system(size: 12, weight: activeRatioFilter == filter ? .semibold : .medium))
                        .foregroundStyle(activeRatioFilter == filter ? .white : .white.opacity(0.7))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(activeRatioFilter == filter ? color.opacity(0.35) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 2)
        .liquidGlassSurface(.regular, in: RoundedRectangle(cornerRadius: 8, style: .continuous), lightweight: true)
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func libraryUtilityMenu(tint: Color) -> some View {
        let hasMenuItems = selectedSubTab == .downloads
        && (selectedContentType == .wallpaper || selectedContentType == .video)

        if hasMenuItems {
            Menu {
                if selectedSubTab == .downloads {
                    switch selectedContentType {
                    case .wallpaper:
                        Button {
                            openFolderInFinder(DownloadPathManager.shared.wallpapersFolderURL)
                        } label: {
                            Label(t("open.in.finder"), systemImage: "folder")
                        }
                    case .video:
                        Button(action: { syncSubscriptions() }) {
                            Label(isSyncingSubscriptions ? t("syncing") : t("sync.subscriptions"), systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(isSyncingSubscriptions)

                        Button {
                            openFolderInFinder(DownloadPathManager.shared.mediaFolderURL)
                        } label: {
                            Label(t("open.in.finder"), systemImage: "folder")
                        }
                    case .anime:
                        EmptyView()
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.84))
                    .frame(width: 36, height: 36)
                    .liquidGlassSurface(.regular, in: Circle(), lightweight: true)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                    )
            }
            .menuStyle(.borderlessButton)
            .pointingHandCursor()
        }
    }

    private enum ToolbarButtonProminence {
        case primary
        case secondary
    }

    private func toolbarCapsuleButton(
        title: String,
        systemImage: String,
        tint: Color,
        prominence: ToolbarButtonProminence,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))

                Text(title)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background {
                Group {
                    if prominence == .primary {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(tint.opacity(0.3))
                    } else {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.regularMaterial)
                            .opacity(0.5)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(prominence == .primary ? tint.opacity(0.24) : Color.white.opacity(0.15), lineWidth: 1)
                )
            }
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    // MARK: - 文件夹面包屑
    @ViewBuilder
    private func folderBreadcrumb(
        folderStack: [String],
        isInFolder: Bool,
        onBack: @escaping () -> Void,
        onRoot: @escaping () -> Void,
        onAdd: @escaping () -> Void
    ) -> some View {
        if isInFolder {
            HStack(spacing: 6) {
                Button(action: onRoot) {
                    Image(systemName: "house")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()

                if !folderStack.isEmpty {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.3))

                    Text("...")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))

                    Image(systemName: "chevron.right")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.3))
                }

                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.left")
                            .font(.system(size: 10))
                        Text(t("back"))
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(.regularMaterial)
                            .opacity(0.4)
                    )
                }
                .buttonStyle(.plain)
                .pointingHandCursor()

                Spacer()

                Button(action: onAdd) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                        Text(t("add"))
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.regularMaterial)
                            .opacity(0.5)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.white.opacity(0.15), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }
            .padding(.horizontal, 4)
        }
    }

    // MARK: - Empty State
    private func emptyMediaSurface(title: String, subtitle: String, icon: String, accent: Color) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundStyle(accent.opacity(0.8))

            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))

            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    // MARK: - Actions
    private func handleWallpaperTap(_ wallpaper: Wallpaper) {
        if isEditing {
            toggleSelection(wallpaper.id)
        } else {
            savedLibraryScrollOffset = libraryScrollRuntimeState.currentOffset
            wallpaperContext = wallpaperItems.map(\.wallpaper)
            selectedWallpaper = wallpaper
        }
    }

    private func handleFolderTap(_ folder: LibraryFolder) {
        if isEditing {
            toggleSelection("folder_\(folder.id)")
            return
        }

        // 加密文件夹需要认证
        if folder.isLocked {
            let lockService = FolderLockService.shared
            if !lockService.isFolderUnlocked(folder.id) {
                Task { @MainActor in
                    let reason = "解锁「\(folder.name)」文件夹"
                    let success = await lockService.unlockFolder(folderID: folder.id, reason: reason)
                    if success {
                        navigateToFolder(folder)
                    }
                }
                return
            }
        }

        navigateToFolder(folder)
    }

    private func navigateToFolder(_ folder: LibraryFolder) {
        switch folder.contentType {
        case .wallpaper:
            navigateToWallpaperFolder(folder.id)
        case .media:
            navigateToMediaFolder(folder.id)
        }
    }

    private func handleMediaTap(_ item: MediaItem) {
        if isEditing {
            toggleSelection(item.id)
        } else {
            savedLibraryScrollOffset = libraryScrollRuntimeState.currentOffset
            mediaContext = mediaItems.map(\.mediaItem)
            selectedMedia = item
        }
    }

    private func handleAnimeTap(_ anime: AnimeSearchResult) {
        if isEditing {
            toggleSelection(anime.id)
        } else {
            savedLibraryScrollOffset = libraryScrollRuntimeState.currentOffset
            selectedAnime = anime
        }
    }

    private func toggleSelection(_ id: String) {
        if selectedItems.contains(id) {
            selectedItems.remove(id)
        } else {
            selectedItems.insert(id)
        }
    }

    private func toggleSelectAll() {
        let allIDs = Set(currentItemIDs)
        selectedItems = selectedItems.count == allIDs.count ? [] : allIDs
    }

    private func syncSelectionWithVisibleItems() {
        selectedItems = selectedItems.intersection(Set(currentItemIDs))
    }

    private var currentItemIDs: [String] {
        switch selectedContentType {
        case .wallpaper:
            return orderedWallpaperGridItems.map(\.id)
        case .video:
            return orderedMediaGridItems.map(\.id)
        case .anime:
            return currentAnimeItems.map(\.id)
        }
    }

    private func deleteSelectedItems() {
        let removedOrderIDs = selectedItems
        // 分离文件夹 ID 和普通项目 ID
        let folderIDs = selectedItems.filter { $0.hasPrefix("folder_") }
        let itemIDs = selectedItems.filter { !$0.hasPrefix("folder_") }

        // 先删除文件夹
        for folderID in folderIDs {
            let realID = String(folderID.dropFirst(7))
            switch selectedContentType {
            case .wallpaper:
                folderStore.deleteFolder(id: realID, contentType: .wallpaper)
            case .video:
                folderStore.deleteFolder(id: realID, contentType: .media)
            case .anime:
                break
            }
        }

        // 再删除普通项目
        switch selectedContentType {
        case .wallpaper:
            if selectedSubTab == .favorites {
                let favoriteIDs = Set(viewModel.favorites.map(\.id))
                let ids = itemIDs.intersection(favoriteIDs)
                if !ids.isEmpty {
                    viewModel.removeWallpaperFavorites(withIDs: ids)
                }
            } else {
                let allLocal = viewModel.allLocalWallpapers
                let ids = itemIDs.intersection(Set(allLocal.map(\.id)))
                if !ids.isEmpty {
                    deleteLocalWallpapers(allLocal.filter { ids.contains($0.id) })
                }
            }

        case .video:
            if selectedSubTab == .favorites {
                let favoriteIDs = Set(mediaViewModel.favoriteItems.map(\.id))
                let ids = itemIDs.intersection(favoriteIDs)
                if !ids.isEmpty {
                    mediaViewModel.removeFavorites(withIDs: ids)
                }
            } else {
                let allLocal = mediaViewModel.allLocalMedia
                let ids = itemIDs.intersection(Set(allLocal.map(\.id)))
                if !ids.isEmpty {
                    deleteLocalMedias(allLocal.filter { ids.contains($0.id) })
                }
            }

        case .anime:
            for id in itemIDs {
                AnimeFavoriteStore.shared.removeFavorite(animeId: id)
            }
            Task {
                await loadAnimeFavorites()
            }
        }
        if selectedContentType != .anime {
            gridOrderStore.removeIDs(removedOrderIDs, from: currentGridOrderScope)
        }
        selectedItems.removeAll()
        isEditing = false
        updateWallpaperItems()
        updateMediaItems()
    }

    private func deleteWallpaperItem(_ item: AnyWallpaperItem) {
        if selectedSubTab == .favorites {
            viewModel.removeWallpaperFavorites(withIDs: [item.id])
        } else {
            _ = viewModel.deleteLocalWallpaper(item.wallpaper)
        }
        gridOrderStore.removeIDs([item.id], from: currentGridOrderScope)
        updateWallpaperItems()
    }

    private func deleteMediaItem(_ item: AnyMediaItem) {
        if selectedSubTab == .favorites {
            mediaViewModel.removeFavorites(withIDs: [item.id])
        } else if let localItem = mediaViewModel.allLocalMedia.first(where: { $0.id == item.id }) {
            deleteLocalMedias([localItem])
        }
        gridOrderStore.removeIDs([item.id], from: currentGridOrderScope)
        updateMediaItems()
    }

    /// 删除文件夹及其所有内容（包括子文件夹中的项目）
    private func deleteFolderWithContents(folderID: String, contentType: LibraryFolder.FolderContentType) {
        // 收集该文件夹及所有子文件夹的 ID
        var allFolderIDs = [folderID]
        func collectSubfolders(_ parentID: String) {
            let children = folderStore.subfolders(of: parentID, contentType: contentType)
            for child in children {
                allFolderIDs.append(child.id)
                collectSubfolders(child.id)
            }
        }
        collectSubfolders(folderID)

        // 收集所有项目 ID 并删除
        var allItemIDs = Set<String>()
        if contentType == .wallpaper {
            for fid in allFolderIDs {
                let favs = WallpaperLibraryService.shared.favoriteWallpapers(inFolder: fid)
                allItemIDs.formUnion(favs.map(\.id))
                let dls = WallpaperLibraryService.shared.downloadedWallpapers(inFolder: fid)
                allItemIDs.formUnion(dls.map(\.wallpaper.id))
            }
            // 删除项目
            if selectedSubTab == .favorites {
                let favIDs = Set(viewModel.favorites.map(\.id)).intersection(allItemIDs)
                if !favIDs.isEmpty { viewModel.removeWallpaperFavorites(withIDs: favIDs) }
            } else {
                let allLocal = viewModel.allLocalWallpapers.filter { allItemIDs.contains($0.id) }
                if !allLocal.isEmpty { deleteLocalWallpapers(allLocal) }
            }
        } else {
            for fid in allFolderIDs {
                let favs = MediaLibraryService.shared.favoriteItems(inFolder: fid)
                allItemIDs.formUnion(favs.map(\.id))
                let dls = MediaLibraryService.shared.downloadedItems(inFolder: fid)
                allItemIDs.formUnion(dls.map(\.item.id))
            }
            if selectedSubTab == .favorites {
                let favIDs = Set(mediaViewModel.favoriteItems.map(\.id)).intersection(allItemIDs)
                if !favIDs.isEmpty { mediaViewModel.removeFavorites(withIDs: favIDs) }
            } else {
                let allLocal = mediaViewModel.allLocalMedia.filter { allItemIDs.contains($0.id) }
                if !allLocal.isEmpty { deleteLocalMedias(allLocal) }
            }
        }

        // 删除文件夹本身
        folderStore.deleteFolder(id: folderID, contentType: contentType)
        gridOrderStore.removeIDs(["folder_\(folderID)"], from: currentGridOrderScope)
        updateWallpaperItems()
        updateMediaItems()
    }

    /// 将视频文件夹中的现有下载先登记到下载任务列表，再删除旧文件并重新下载。
    /// 下载落盘时始终携带原 folderID，避免重建下载记录后掉回媒体库根目录。
    private func redownloadAllMedia(in folder: LibraryFolder) {
        guard folder.contentType == .media, folder.collection == .downloads else { return }

        let records = MediaLibraryService.shared.downloadedItems(inFolder: folder.id)
        guard !records.isEmpty else { return }
        redownloadMediaRecords(records, folderID: folder.id)
    }

    /// 单个库内壁纸重新下载：保留原文件夹归属（若有），先入队再删旧文件。
    private func redownloadMediaItem(_ item: MediaItem) {
        guard canRedownloadMediaItem(item) else { return }
        guard let record = MediaLibraryService.shared.downloadRecord(for: item.id),
              record.isActive else {
            return
        }
        redownloadMediaRecords([record], folderID: record.folderID)
    }

    private func canRedownloadMediaItem(_ item: MediaItem) -> Bool {
        // 本地导入文件没有远端源，无法重新拉取。
        if item.id.hasPrefix("local_") { return false }
        if item.sourceName == t("local") { return false }
        return MediaLibraryService.shared.downloadRecord(for: item.id)?.isActive == true
    }

    /// 先持久化下载队列，再清优化状态与旧文件，最后启动传输。
    private func redownloadMediaRecords(_ records: [MediaDownloadRecord], folderID: String?) {
        guard !records.isEmpty else { return }

        guard PersistentDownloadQueueService.shared.stage(
            records.map(\.item),
            folderID: folderID
        ) else {
            mediaViewModel.errorMessage = "无法保存下载队列，已取消删除旧文件"
            return
        }

        // 新文件需要重新建立自己的优化判断，不能继承已删除文件的 sidecar 终态。
        for videoURL in records.compactMap(\.resolvedVideoFileURL) {
            VideoOptimizationQueueService.shared.cancelSourceRestoreRequest(videoURL: videoURL)
            VideoOptimizationQueueService.shared.resetOptimizationState(videoURL: videoURL)
        }

        let itemIDs = Set(records.map(\.item.id))
        mediaViewModel.removeDownloads(withIDs: itemIDs)
        updateMediaItems()

        PersistentDownloadQueueService.shared.start(using: mediaViewModel)
    }

    private func matchesLibrarySearch(for folder: LibraryFolder, query: String) -> Bool {
        folder.name.localizedCaseInsensitiveContains(query)
    }

    private func matchesLibrarySearch(for item: AnyWallpaperItem, query: String) -> Bool {
        let wallpaper = item.wallpaper
        let directMatches = [
            item.localFileURL?.deletingPathExtension().lastPathComponent,
            wallpaper.id,
            wallpaper.category,
            wallpaper.categoryDisplayName,
            wallpaper.purity,
            wallpaper.purityDisplayName,
            wallpaper.effectiveResolutionLabel,
            wallpaper.ratio,
            wallpaper.source,
            wallpaper.uploader?.username,
            wallpaper.primaryTagName
        ]
        if directMatches.contains(where: { $0?.localizedCaseInsensitiveContains(query) == true }) {
            return true
        }
        return wallpaper.tags?.contains(where: {
            $0.name.localizedCaseInsensitiveContains(query)
                || ($0.alias?.localizedCaseInsensitiveContains(query) ?? false)
        }) ?? false
    }

    private func matchesLibrarySearch(for item: AnyMediaItem, query: String) -> Bool {
        let media = item.mediaItem
        let directMatches = [
            item.localFileURL?.deletingPathExtension().lastPathComponent,
            media.id,
            media.title,
            media.collectionTitle,
            media.summary,
            media.sourceName,
            media.authorName,
            media.resolutionLabel,
            media.exactResolution,
            media.primaryTagText
        ]
        if directMatches.contains(where: { $0?.localizedCaseInsensitiveContains(query) == true }) {
            return true
        }
        return media.tags.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    private func matchesLibrarySearch(for anime: AnimeSearchResult, query: String) -> Bool {
        let directMatches = [
            anime.title,
            anime.originalName,
            anime.sourceName,
            anime.latestEpisode,
            anime.summary,
            anime.rating
        ]
        if directMatches.contains(where: { $0?.localizedCaseInsensitiveContains(query) == true }) {
            return true
        }
        return anime.tags?.contains(where: { $0.name.localizedCaseInsensitiveContains(query) }) ?? false
    }

    /// 删除本地壁纸（含物理文件删除）
    private func deleteLocalWallpapers(_ items: [UnifiedLocalWallpaper]) {
        let fileManager = FileManager.default

        for item in items {
            if let record = item.downloadRecord {
                viewModel.removeWallpaperDownloads(withIDs: [record.wallpaper.id])
            }
            let filePath = item.fileURL.path
            if fileManager.fileExists(atPath: filePath) {
                do {
                    try fileManager.removeItem(atPath: filePath)
                    print("[MyLibrary] ✅ Deleted file: \(filePath)")
                } catch {
                    print("[MyLibrary] ❌ Failed to delete file \(filePath): \(error)")
                }
            }
        }

        viewModel.loadFavorites()
    }

    /// 删除本地媒体（含物理文件删除）
    private func deleteLocalMedias(_ items: [UnifiedLocalMedia]) {
        let fileManager = FileManager.default

        for item in items {
            if let record = item.downloadRecord {
                MediaLibraryService.shared.removeDownloadRecord(withID: record.item.id)
            }
            let filePath = item.fileURL.path
            if fileManager.fileExists(atPath: filePath) {
                do {
                    try fileManager.removeItem(atPath: filePath)
                    print("[MyLibrary] ✅ Deleted media file: \(filePath)")
                } catch {
                    print("[MyLibrary] ❌ Failed to delete media file \(filePath): \(error)")
                }
            }
        }

        mediaViewModel.refreshLibraryContent()
    }

    // MARK: - Grid Config
    private struct LibraryGridConfig {
        let columnCount: Int
        let spacing: CGFloat
        let cardWidth: CGFloat
        let contentWidth: CGFloat
        let gridItems: [GridItem]

        init(contentWidth: CGFloat) {
            self.contentWidth = contentWidth
            self.columnCount = contentWidth > 1200 ? 4 : (contentWidth > 800 ? 3 : 2)
            self.spacing = 16
            let totalSpacing = spacing * CGFloat(columnCount - 1)
            self.cardWidth = floor((contentWidth - totalSpacing) / CGFloat(columnCount))
            self.gridItems = Array(repeating: GridItem(.fixed(cardWidth), spacing: spacing), count: columnCount)
        }
    }

    @ViewBuilder
    private func libraryWaterfallGrid<Item: Identifiable, Content: View>(
        entries: [Item],
        config: LibraryGridConfig,
        estimatedHeight: CGFloat,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        // ⚡ 库卡片高度是统一的（LibraryCardMetrics.thumbnailHeight = 180 + 元数据栏），
        // 不需要瀑布流。改用 LazyVGrid 替代 `HStack { LazyVStack × N }` 的多列模式
        // ——后者在 macOS 上会让所有列在每帧滚动期间反复同步对齐，是已知 hitch 来源。
        LazyVGrid(columns: config.gridItems, alignment: .leading, spacing: config.spacing) {
            ForEach(entries) { item in
                content(item)
            }
        }
    }

    /// 动漫列表专用网格配置，列数更多使封面更小
    private struct AnimeGridConfig {
        let columnCount: Int
        let spacing: CGFloat
        let cardWidth: CGFloat
        let gridItems: [GridItem]

        init(contentWidth: CGFloat) {
            self.spacing = 12
            self.columnCount = contentWidth > 1200 ? 5 : (contentWidth > 800 ? 4 : 3)
            let totalSpacing = spacing * CGFloat(columnCount - 1)
            self.cardWidth = floor((contentWidth - totalSpacing) / CGFloat(columnCount))
            self.gridItems = Array(repeating: GridItem(.fixed(cardWidth), spacing: spacing), count: columnCount)
        }
    }

    // MARK: - Import & Folder
    private func openFolderInFinder(_ url: URL) {
        DownloadPathManager.shared.createDirectoryStructure()
        NSWorkspace.shared.open(url)
    }

    /// 统一导入入口：打开文件选择面板，支持图片/视频/文件夹/workshop 混合选择
    private func startImport() {
        guard DownloadPathManager.shared.createDirectoryStructure() else {
            print("[MyLibrary] Failed to create download directory structure, import aborted")
            return
        }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = t("import")
        panel.message = t("import.panel.message")

        guard panel.runModal() == .OK else { return }

        // 确定当前文件夹上下文：如果在某个文件夹内，导入的文件自动归入该文件夹
        let currentFolderID: String?
        switch selectedContentType {
        case .wallpaper:
            currentFolderID = currentWallpaperFolderID
        case .video:
            currentFolderID = currentMediaFolderID
        default:
            currentFolderID = nil
        }

        let urls = panel.urls
        Task {
            await ImportService.shared.importURLs(urls, folderID: currentFolderID)

            // 完成后用原生 NSAlert 展示结果
            let progress = ImportService.shared.progress
            let message: String
            if progress.failedImports > 0 {
                message = String(format: t("import.result.partial"), progress.successfulImports, progress.failedImports)
            } else if progress.skippedImports > 0 {
                message = String(format: t("import.result.partial.skipped"), progress.successfulImports, progress.skippedImports)
            } else if progress.successfulImports > 0 {
                message = String(format: t("import.result.success"), progress.successfulImports)
            } else {
                message = t("import.result.none")
            }

            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = t("import.completed")
                alert.informativeText = message
                alert.alertStyle = (progress.failedImports > 0 || progress.skippedImports > 0) ? .warning : .informational
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }

    // MARK: - 同步 Steam 订阅

    /// 获取用户订阅列表（已过滤已下载），展示选择 Sheet
    private func fetchSubscriptionList() async {
        defer { syncIsLoadingList = false }

        let steamID = workshopSourceManager.steamProfileID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !steamID.isEmpty else {
            showSyncSelectionSheet = false
            showSyncProfileSheet = true
            return
        }

        do {
            let allItems = try await mediaViewModel.fetchSubscribedItems(steamID: steamID)
            syncSubscribedItems = allItems
            // 默认全选
            syncSelectedIDs = Set(allItems.map(\.id))
            // showSyncSelectionSheet 已在 onDisappear 中设为 true，无需重复设置
        } catch {
            syncErrorMessage = error.localizedDescription
            // 关闭加载中的选择 Sheet，然后显示错误弹窗
            showSyncSelectionSheet = false
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "获取订阅列表失败"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }

    /// 下载用户勾选的订阅项
    private func downloadSelectedSubscriptions(_ items: [WorkshopWallpaper]) async {
        guard !items.isEmpty else { return }
        isSyncingSubscriptions = true

        let mediaItems = mediaViewModel.workshopService.convertToMediaItems(items)

        // 并发提交所有下载任务，SteamCMD 下载限制器会自动控制并发（最多 2 个同时下载）
        let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for item in mediaItems {
                group.addTask {
                    guard !Task.isCancelled else { return false }
                    do {
                        try await self.mediaViewModel.downloadWorkshopWallpaper(item)
                        return true
                    } catch {
                        AppLogger.error(.media, "sync download failed", metadata: ["id": item.id, "error": "\(error)"])
                        return false
                    }
                }
            }

            var results: [Bool] = []
            for await success in group {
                results.append(success)
            }
            return results
        }

        let successCount = results.filter { $0 }.count
        let failCount = results.filter { !$0 }.count

        isSyncingSubscriptions = false
        mediaViewModel.objectWillChange.send()

        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "同步订阅"
            if failCount > 0 {
                alert.informativeText = "下载完成！\n成功：\(successCount) 个\n失败：\(failCount) 个"
                alert.alertStyle = .warning
            } else {
                alert.informativeText = "所有勾选的订阅已开始下载！\n共 \(successCount) 个"
                alert.alertStyle = .informational
            }
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    /// 同步按钮入口：始终弹出 Steam Web 登录页面以建立有效会话
    /// 登录成功后自动关闭 Web 页面 → onDisappear 触发 fetchSubscriptionList() → 弹出选择弹窗
    @State private var showSteamLoginSheet = false

    private func syncSubscriptions() {
        showSteamLoginSheet = true
    }

}

// MARK: - 库视图氛围背景（独立观察 ArcBackgroundSettings）
/// 从 MyLibraryContentView 下沉而来：自行观察 ArcBackgroundSettings，
/// 外观设置（点阵/噪点/颗粒度）变化时只重建本背景，不触发整个库视图 body 重算。
private struct LibraryAtmosphereBackground: View {
    let tint: ExploreAtmosphereTint
    @ObservedObject private var arcSettings = ArcBackgroundSettings.shared

    var body: some View {
        ArcAtmosphereBackground(
            tint: tint,
            referenceImage: nil,
            isLightMode: false,
            dotGridOpacity: arcSettings.dotGridOpacity,
            useNoise: arcSettings.useNoiseTexture,
            grainIntensity: arcSettings.grainIntensity,
            lightweight: true
        )
    }
}

// MARK: - Content Type Picker
struct ContentTypePicker: View {
    @Binding var selected: ContentType

    @Namespace private var selectionNamespace
    @State private var hoveredType: ContentType?

    var body: some View {
        HStack(spacing: 6) {
            ForEach(ContentType.allCases, id: \.self) { type in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selected = type
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: type.icon)
                            .font(.system(size: 13, weight: .semibold))

                        Text(type.displayName)
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(labelColor(for: type))
                    .frame(minWidth: 86, minHeight: 32)
                    .padding(.horizontal, 10)
                    .background {
                        if selected == type {
                            selectedTypeGlass
                        } else if hoveredType == type {
                            Capsule(style: .continuous)
                                .fill(Color.white.opacity(0.1))
                        }
                    }
                }
                .buttonStyle(.plain)
                .contentShape(Capsule(style: .continuous))
                .onHover { hovering in
                    withAnimation(.easeOut(duration: 0.16)) {
                        hoveredType = hovering ? type : (hoveredType == type ? nil : hoveredType)
                    }
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .liquidGlassSurface(.regular, in: Capsule(style: .continuous))
    }

    private func labelColor(for type: ContentType) -> Color {
        if selected == type {
            return .white.opacity(0.96)
        }
        if hoveredType == type {
            return .white.opacity(0.86)
        }
        return .white.opacity(0.72)
    }

    @ViewBuilder
    private var selectedTypeGlass: some View {
        Capsule(style: .continuous)
            .fill(Color.white.opacity(0.12))
            .overlay(
                Capsule(style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.34),
                                Color.white.opacity(0.08)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.8
                    )
            )
            .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
            .matchedGeometryEffect(id: "libraryContentTypeGlass", in: selectionNamespace)
    }
}

// MARK: - Anime Library Card

struct AnimeLibraryCard: View {
    let anime: AnimeSearchResult
    let isEditing: Bool
    let isSelected: Bool
    var cardWidth: CGFloat = LibraryCardMetrics.cardWidth
    let action: () -> Void

    @State private var isHovered = false
    @State private var progressText: String? = nil
    @State private var progressValue: Double? = nil

    /// 竖版封面（10:14 比例）
    private var imageHeight: CGFloat {
        cardWidth * 1.4
    }

    /// 底部信息栏高度
    private let bottomBarHeight: CGFloat = 52

    private var totalCardHeight: CGFloat {
        imageHeight + bottomBarHeight
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                // 图片区域
                ZStack {
                    KFImage(URL(string: anime.coverURL ?? ""))
                        .setProcessor(DownsamplingImageProcessor(size: CGSize(width: 512, height: 512)))
                        .cacheMemoryOnly(false)
                        .fade(duration: 0.3)
                        .placeholder { _ in
                            SkeletonCard(
                                width: cardWidth,
                                height: imageHeight,
                                cornerRadius: 0
                            )
                        }
                        .resizable()
                        .scaledToFill()
                        .frame(width: cardWidth, height: imageHeight)
                        .clipped()

                    // 左上角复选框（编辑模式下显示）
                    if isEditing {
                        VStack {
                            HStack {
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 22, weight: .semibold))
                                    .foregroundStyle(isSelected ? LiquidGlassColors.secondaryViolet : .white.opacity(0.8))
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

                    // 右上角评分/排名（非编辑模式）
                    if !isEditing {
                        VStack {
                            HStack {
                                Spacer()
                                if let rating = anime.rating, let score = Double(rating), score > 0 {
                                    HStack(spacing: 4) {
                                        Image(systemName: "star.fill")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(.yellow)
                                        Text(String(format: "%.1f", score))
                                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                                            .foregroundStyle(.white.opacity(0.95))
                                    }
                                    .padding(.horizontal, 10)
                                    .frame(height: 24)
                                    .background(
                                        Capsule(style: .continuous)
                                            .fill(Color.black.opacity(0.45))
                                    )
                                    .padding(12)
                                } else if let rank = anime.rank {
                                    Text("#\(rank)")
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                        .foregroundStyle(.white.opacity(0.95))
                                        .padding(.horizontal, 10)
                                        .frame(height: 24)
                                        .background(
                                            Capsule(style: .continuous)
                                                .fill(Color.black.opacity(0.45))
                                        )
                                        .padding(12)
                                }
                            }
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    }

                    // 选中遮罩
                    if isEditing && isSelected {
                        Color.black.opacity(0.3)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(width: cardWidth, height: imageHeight)

                // 底部信息栏（半透明黑底，与 AnimeGridCell 风格一致）
                bottomInfoBar
            }
            .frame(width: cardWidth, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color(hex: "1A1D24").opacity(0.6))
            )
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.white.opacity(isHovered ? 0.18 : 0.08), lineWidth: isHovered ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .animation(.easeOut(duration: 0.16), value: isHovered)
        .throttledHover(interval: 0.05) { hovering in
            if !isEditing {
                isHovered = hovering
            }
        }
        .onAppear {
            loadProgress()
        }
    }

    // MARK: - 底部信息栏

    private var bottomInfoBar: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                // 标题
                Text(anime.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1)

                // 进度 / 集数信息
                if let progressText {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 8, weight: .regular))
                            .foregroundStyle(.white.opacity(0.5))
                        Text(progressText)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                } else if let episode = anime.latestEpisode?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !episode.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 8, weight: .regular))
                            .foregroundStyle(.white.opacity(0.5))
                        Text(episode)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                }

                // 进度条（有进度时显示）
                if let progressValue {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(.white.opacity(0.15))
                                .frame(height: 3)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(LiquidGlassColors.tertiaryBlue.opacity(0.8))
                                .frame(width: geo.size.width * CGFloat(min(max(progressValue, 0), 1)), height: 3)
                        }
                    }
                    .frame(height: 3)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Spacer(minLength: 0)
        }
        .frame(width: cardWidth, height: bottomBarHeight, alignment: .leading)
    }

    // MARK: - 加载进度

    private func loadProgress() {
        let summary = AnimeProgressStore.shared.animeSummaries[anime.id]
        if let summary {
            if summary.watchedEpisodes > 0 {
                progressText = summary.continueWatchingText
            } else {
                progressText = "开始观看"
            }
            if summary.totalEpisodes > 0 {
                progressValue = summary.overallProgress
            } else if let lastEp = summary.lastEpisodeNumber {
                progressText = "看到第 \(lastEp) 集"
            }
        }
    }
}

// MARK: - AnyWallpaperItem (统一封装用于 ForEach)
private struct AnyWallpaperItem: Identifiable {
    let id: String
    let wallpaper: Wallpaper
    let localFileURL: URL?
    let downloadDate: Date?

    init(wallpaper: Wallpaper, localFileURL: URL? = nil) {
        self.id = wallpaper.id
        self.wallpaper = wallpaper
        self.localFileURL = localFileURL
        self.downloadDate = nil
    }

    init(unified: UnifiedLocalWallpaper) {
        self.id = unified.id
        self.wallpaper = unified.wallpaper
        self.localFileURL = unified.fileURL
        self.downloadDate = unified.downloadRecord?.downloadedAt
    }
}

// MARK: - AnyMediaItem (统一封装用于 ForEach)
private struct AnyMediaItem: Identifiable {
    let id: String
    let mediaItem: MediaItem
    let localFileURL: URL?
    let thumbnailURL: URL
    let shouldProbeAnimatedThumbnail: Bool
    let resolvedVideoFileURL: URL?
    private let unifiedLocalMedia: UnifiedLocalMedia?

    @MainActor
    init(mediaItem: MediaItem, localFileURL: URL? = nil) {
        // 列表重建不做 Workshop 递归/外置 stat；视频路径由卡片 onAppear 按需解析。
        let resolvedVideoFileURL = Self.resolveVideoFileURLLightweight(
            localFileURL: localFileURL,
            downloadRecord: nil
        )
        let thumbnailURL = mediaItem.libraryGridThumbnailURL(localFileURL: localFileURL)

        self.id = mediaItem.id
        self.mediaItem = mediaItem
        self.localFileURL = localFileURL
        self.thumbnailURL = thumbnailURL
        self.shouldProbeAnimatedThumbnail = Self.shouldProbeAnimatedThumbnail(
            url: thumbnailURL,
            mediaItem: mediaItem
        )
        self.resolvedVideoFileURL = resolvedVideoFileURL
        self.unifiedLocalMedia = nil
    }

    @MainActor
    init(unified: UnifiedLocalMedia) {
        let resolvedVideoFileURL = Self.resolveVideoFileURLLightweight(
            localFileURL: unified.fileURL,
            downloadRecord: unified.downloadRecord
        )
        let thumbnailURL = unified.mediaItem.libraryGridThumbnailURL(localFileURL: unified.fileURL)

        self.id = unified.id
        self.mediaItem = unified.mediaItem
        self.localFileURL = unified.fileURL
        self.thumbnailURL = thumbnailURL
        self.shouldProbeAnimatedThumbnail = Self.shouldProbeAnimatedThumbnail(
            url: thumbnailURL,
            mediaItem: unified.mediaItem
        )
        self.resolvedVideoFileURL = resolvedVideoFileURL
        self.unifiedLocalMedia = unified
    }

    /// 是否为竖屏；优先使用 UnifiedLocalMedia 的解析（包含烘焙产物信息），其次 MediaItem
    var isPortrait: Bool? {
        unifiedLocalMedia?.isPortrait ?? mediaItem.isPortrait
    }

    /// 轻量解析：只认 bake 记录路径与「本身就是视频文件」的扩展名，不扫目录、不 fileExists 外置卷。
    private static func resolveVideoFileURLLightweight(
        localFileURL: URL?,
        downloadRecord: MediaDownloadRecord?
    ) -> URL? {
        if let artifactPath = downloadRecord?.sceneBakeArtifact?.videoPath,
           !artifactPath.isEmpty {
            // 可用性检查延后到卡片/设壁纸路径；此处只给列表一个候选 URL
            return URL(fileURLWithPath: artifactPath)
        }
        guard let localFileURL, localFileURL.isFileURL else { return nil }
        let ext = localFileURL.pathExtension.lowercased()
        if ["mp4", "mov", "webm", "m4v", "mkv"].contains(ext) {
            return localFileURL
        }
        return nil
    }

    private static func shouldProbeAnimatedThumbnail(url: URL, mediaItem: MediaItem) -> Bool {
        // 明确动图元数据 / 路径后缀：必须探测并允许 hover 播放
        if mediaItem.isAnimatedImage == true {
            return true
        }
        if url.pathExtension.lowercased() == "gif" {
            return true
        }
        // 本地路径文件名含 preview.gif 等（query 少见，仍看 pathExtension 即可）
        if let local = mediaItem.posterURL, local.pathExtension.lowercased() == "gif" {
            return true
        }

        if url.isFileURL {
            let path = url.standardizedFileURL.path
            // 已生成的静态列表缓存绝不是可播放 GIF
            if path.contains("/WaifuX/VideoThumbnails/")
                || path.contains("/WaifuX/LocalImageThumbnails/") {
                return false
            }

            let ext = url.pathExtension.lowercased()
            // 静图/视频封面无需 GIF probe；尤其外置卡上 probe 会再读文件头
            if ["mp4", "mov", "webm", "m4v", "mkv", "jpg", "jpeg", "png", "webp", "heic", "heif", "avif", "bmp", "tiff", "tif"].contains(ext) {
                return false
            }
        }

        // 远程封面等：保持探测（站点可能返回 GIF 但后缀不是 .gif）
        return true
    }
}

private enum LibraryGridEntry<Item: Identifiable>: Identifiable where Item.ID == String {
    case folder(LibraryFolder)
    case item(Item)

    var id: String {
        switch self {
        case .folder(let folder):
            return "folder_\(folder.id)"
        case .item(let item):
            return item.id
        }
    }
}

// MARK: - Cursor Extension
private extension View {
    func pointingHandCursor() -> some View {
        self.onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}
