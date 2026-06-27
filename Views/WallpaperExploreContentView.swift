import SwiftUI
import AppKit
import Kingfisher
@preconcurrency import Translation

@MainActor
private enum WallpaperExploreDiagnostics {
    private struct Counters {
        var reloadRequests = 0
        var reloadWhileLoading = 0
        var wallpaperChanges = 0
        var loadMoreTriggers = 0
        var loadMoreSkips = 0
        var recomputes = 0
        var slowRecomputes = 0
        var layoutCacheHits = 0
        var layoutRebuilds = 0
        var slowLayoutRebuilds = 0
        var atmosphereSyncs = 0
    }

    private static var counters = Counters()
    private static var lastSnapshotTime: TimeInterval = 0
    private static let snapshotInterval: TimeInterval = 2.0
    private static let slowRecomputeThresholdMS = 12.0
    private static let slowLayoutThresholdMS = 10.0

    static func markReloadRequested(reason: String, isLoading: Bool, currentCount: Int) {
        counters.reloadRequests += 1
        if isLoading {
            counters.reloadWhileLoading += 1
            AppLogger.warn(.wallpaper, "ExploreDiag reload requested during active load", metadata: [
                "reason": reason,
                "currentCount": currentCount
            ])
        }
        flushSnapshotIfNeeded(trigger: "reload", metadata: [
            "reason": reason,
            "currentCount": currentCount
        ])
    }

    static func markWallpapersChanged(totalCount: Int, isLoading: Bool) {
        counters.wallpaperChanges += 1
        flushSnapshotIfNeeded(trigger: "wallpapersChanged", metadata: [
            "totalCount": totalCount,
            "isLoading": isLoading
        ])
    }

    static func markLoadMoreTriggered(source: String, currentCount: Int) {
        counters.loadMoreTriggers += 1
        flushSnapshotIfNeeded(trigger: "loadMore", metadata: [
            "source": source,
            "currentCount": currentCount
        ])
    }

    static func markLoadMoreSkipped(source: String, reason: String) {
        counters.loadMoreSkips += 1
        if counters.loadMoreSkips % 8 == 0 {
            flushSnapshotIfNeeded(trigger: "loadMoreSkipped", force: true, metadata: [
                "source": source,
                "reason": reason
            ])
        }
    }

    static func markRecompute(durationMS: Double, totalCount: Int, visibleCount: Int, changed: Bool) {
        counters.recomputes += 1
        if durationMS >= slowRecomputeThresholdMS {
            counters.slowRecomputes += 1
            AppLogger.warn(.wallpaper, "ExploreDiag slow visible recompute", metadata: [
                "durationMS": String(format: "%.2f", durationMS),
                "totalCount": totalCount,
                "visibleCount": visibleCount,
                "changed": changed
            ])
        } else {
            flushSnapshotIfNeeded(trigger: "recompute", metadata: [
                "durationMS": String(format: "%.2f", durationMS),
                "visibleCount": visibleCount,
                "changed": changed
            ])
        }
    }

    static func markLayout(durationMS: Double, itemCount: Int, columnCount: Int, reusedCache: Bool) {
        if reusedCache {
            counters.layoutCacheHits += 1
            return
        }

        counters.layoutRebuilds += 1
        if durationMS >= slowLayoutThresholdMS {
            counters.slowLayoutRebuilds += 1
            AppLogger.warn(.wallpaper, "ExploreDiag slow waterfall layout rebuild", metadata: [
                "durationMS": String(format: "%.2f", durationMS),
                "itemCount": itemCount,
                "columnCount": columnCount
            ])
        } else {
            flushSnapshotIfNeeded(trigger: "layout", metadata: [
                "durationMS": String(format: "%.2f", durationMS),
                "itemCount": itemCount,
                "columnCount": columnCount
            ])
        }
    }

    static func markAtmosphereSync(firstID: String?) {
        counters.atmosphereSyncs += 1
        flushSnapshotIfNeeded(trigger: "atmosphere", metadata: [
            "firstID": firstID ?? "nil"
        ])
    }

    private static func flushSnapshotIfNeeded(
        trigger: String,
        force: Bool = false,
        metadata: [String: Any] = [:]
    ) {
        let now = Date().timeIntervalSinceReferenceDate
        guard force || now - lastSnapshotTime >= snapshotInterval else { return }
        lastSnapshotTime = now

        var combined: [String: Any] = [
            "trigger": trigger,
            "reloadRequests": counters.reloadRequests,
            "reloadWhileLoading": counters.reloadWhileLoading,
            "wallpaperChanges": counters.wallpaperChanges,
            "loadMoreTriggers": counters.loadMoreTriggers,
            "loadMoreSkips": counters.loadMoreSkips,
            "recomputes": counters.recomputes,
            "slowRecomputes": counters.slowRecomputes,
            "layoutCacheHits": counters.layoutCacheHits,
            "layoutRebuilds": counters.layoutRebuilds,
            "slowLayoutRebuilds": counters.slowLayoutRebuilds,
            "atmosphereSyncs": counters.atmosphereSyncs
        ]

        for (key, value) in metadata {
            combined[key] = value
        }

        AppLogger.info(.wallpaper, "ExploreDiag snapshot", metadata: combined)
    }
}

// MARK: - 滚动位置保存已移除（怀疑返回时回到顶部是因数据被清空导致）

// MARK: - macOS 14 兼容：滚动加载更多哨兵

private struct WallpaperLoadMoreSentinelMinYPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = .greatestFiniteMagnitude

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        // 只取最小值，且仅当显著变化时记录（避免同一帧多次更新警告）
        if next < value {
            value = next
        }
    }
}

private struct WallpaperExploreHeaderHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 {
            value = next
        }
    }
}

private enum WallpaperLoadMoreScrollZone: Equatable {
    case near
    case armed
    case far
}

private final class WallpaperExploreScrollCoordinator: ObservableObject {
    var sentinelDebounceTask: DispatchWorkItem?
    var pendingLoadMoreTask: DispatchWorkItem?
    var wasNearBottom = false

    func cancelPendingWork() {
        sentinelDebounceTask?.cancel()
        pendingLoadMoreTask?.cancel()
        sentinelDebounceTask = nil
        pendingLoadMoreTask = nil
        wasNearBottom = false
    }
}

// MARK: - WallpaperExploreContentView - 壁纸探索页

struct WallpaperExploreContentView: View {
    private static let scrollCoordinateSpaceName = "wallpaper-explore-scroll"
    private static let loadMoreTriggerThreshold: CGFloat = 120
    private static let loadMoreResetThreshold: CGFloat = 520

    @ObservedObject var viewModel: WallpaperViewModel
    @Binding var selectedWallpaper: Wallpaper?
    var isVisible: Bool = true
    @StateObject private var exploreAtmosphere = ExploreAtmosphereController(wallpaperMode: true)
    @ObservedObject private var arcSettings = ArcBackgroundSettings.shared
    // 注意：VideoWallpaperManager / WallpaperEngineXBridge 不在顶层观察。
    // 它们各有多个 @Published（isPaused/isMuted/volume 等），若顶层观察会导致
    // 视频壁纸暂停/恢复时整个壁纸探索页 body 重算（含瀑布流布局重计算）。
    // 仅 shouldUseLightweightEffects 依赖它们的播放状态，已下沉到
    // WallpaperExploreAtmosphereBackground 子视图内自行观察，只重建背景。
    @StateObject private var translationBridge = SearchTranslationBridge()
    @Environment(\.mainTopBarContentPadding) private var mainTopBarContentPadding
    init(viewModel: WallpaperViewModel, selectedWallpaper: Binding<Wallpaper?>, isVisible: Bool = true) {
        self._viewModel = ObservedObject(wrappedValue: viewModel)
        self._selectedWallpaper = selectedWallpaper
        self.isVisible = isVisible
    }

    // MARK: State
    @State private var category: CategoryFilter = .all
    @State private var fourKCategory: FourKCategory?
    @State private var fourKSorting: FourKSortingOption = .latest
    @State private var konachanSorting: KonachanSorting = .dateAdded
    @State private var konachanCategory: KonachanService.KonachanCategory?
    @State private var konachanHotTagName: String? = nil
    @State private var konachanDynamicHotTags: [KonachanTag] = []
    @State private var hotTag: HotTag?
    @State private var searchText = ""
    @State private var isLoadingMore = false
    @State private var isInitialLoading = false
    @State private var showScrollToTop = false
    @State private var outerScrollToTopToken: Int = 0
    @State private var showAPIKeyAlert = false
    @State private var isFirstAppearance = true
    @State private var loadMoreFailed = false
    @State private var pendingSearchText: String?
    /// 氛围图仅在实际首张 id 变化时更新
    @State private var lastSyncedFirstWallpaperID: String?
    @State private var loadMoreTask: Task<Void, Never>?


    @State private var showWallpaperURLSheet = false
    @State private var wallpaperURLInput = ""
    @State private var isResolvingWallpaperURL = false
    @State private var wallpaperURLError: String?
    @StateObject private var scrollCoordinator = WallpaperExploreScrollCoordinator()

    /// 缓存筛选后的列表，避免每次 body 重绘时对 `wallpapers` 全表过滤（Wallhaven 分类）
    @State private var visibleWallpapers: [Wallpaper] = []
    /// 防止重复设置同一个 visibleWallpapers 值触发不必要重建；必须保留顺序，排序变化也要刷新瀑布流。
    @State private var lastVisibleIDs: [Wallpaper.ID] = []
    // 注意：旧版"按列缓存"机制 (WallpaperWaterfallLayoutCache) 已移除——
    // 新瀑布流走 SwiftUI Layout protocol（WaterfallChunkLayout），其内部自带 cache。
    // 收藏状态已移除 @State 缓存，改为视图在 ForEach 中直接读取 viewModel.favoriteIDSet。
    // MARK: - 渲染限流防御
    /// 用于异步防抖执行 recomputeVisibleWallpapers，避免高频触发时主线程堆积。
    @State private var recomputeTask: Task<Void, Never>? = nil
    /// loadMore 冷却期，防止 contentSize 增长 → isNearBottom 翻转 → 立即重试的无限级联。
    @State private var loadMoreCooldownUntil: Date? = nil
    /// syncAtmosphereIfNeeded 节流时间戳，避免 loadMore 高频触发时反复下载缩略图+CoreImage 采样。
    @State private var lastAtmosphereSyncTime: Date = .distantPast
    @State private var measuredGridHeaderHeight: CGFloat = 0
    @State private var isGridHeaderContentMounted = true

    // MARK: - AppKit 瀑布流（NSCollectionView 通道）状态
    /// AppKit `ExploreGridContainer` 汇报回的内容总高度。外层 SwiftUI ScrollView
    /// 用 `.frame(height:)` 把这个值兑现给 grid，让网格在共享滚动模型下成为定高块。
    @State private var gridContentHeight: CGFloat = 600
    /// 触发可视 cell 重配的 token（数据数量未变但内容/收藏/标记发生变化时）。
    @State private var gridReloadToken: Int = 0
    /// 强制 AppKit 网格重做布局的 token（窗口宽度变化、tab 切回等场景）。
    @State private var gridLayoutRefreshToken: Int = 0

    // shouldUseLightweightEffects 已下沉到 WallpaperExploreAtmosphereBackground 子视图，
    // 该子视图自行观察 VideoWallpaperManager / WallpaperEngineXBridge 的播放状态。

    var body: some View {
        // 性能测量：开启 PERF_TRACE 编译标记后，会在控制台打印触发本 body 的属性来源
        #if PERF_TRACE
        let _ = Self._printChanges()
        #endif
        mainContent
    }

    @ViewBuilder
    private var mainContent: some View {
        GeometryReader { geometry in
            let contentWidth = calculateContentWidth(geometry: geometry)
            let gridConfig = WallpaperGridConfig(contentWidth: contentWidth)

            ZStack {
                if arcSettings.compactMode {
                    arcSettings.compactBackground
                        .ignoresSafeArea()
                } else {
                    // 背景渲染下沉到独立子视图：自行观察 VideoWallpaperManager /
                    // WallpaperEngineXBridge 的播放状态，视频壁纸暂停/恢复只重建本背景，
                    // 不触发整个壁纸探索页 body 重算（含瀑布流布局重计算）。
                    WallpaperExploreAtmosphereBackground(
                        tint: exploreAtmosphere.tint,
                        referenceImage: exploreAtmosphere.referenceImage,
                        isLightMode: arcSettings.isLightMode,
                        dotGridOpacity: arcSettings.dotGridOpacity,
                        grainIntensity: arcSettings.exploreGrainWallpaper
                    )
                    .ignoresSafeArea()
                }

                scrollContent(
                    width: geometry.size.width,
                    viewportHeight: geometry.size.height,
                    gridConfig: gridConfig
                )
            }
        }
        .onAppear {
            if isFirstAppearance {
                // 如果 viewModel 已有数据（由 ContentView.task 的 initialLoad 加载完成），
                // 不要重置筛选，避免双重 search() 竞态
                if viewModel.wallpapers.isEmpty {
                    handleAppear()
                } else {
                    if searchText.isEmpty { searchText = viewModel.searchQuery }
                    recomputeVisibleWallpapers()
                    syncAtmosphereIfNeeded()
                }
                isFirstAppearance = false
            } else {
                handleAppear()
            }
        }
        .onChange(of: isVisible) { _, visible in
            if !visible {
                pauseActivity()
            } else {
                Task { @MainActor in
                    if AppResponsivenessMonitor.isForegroundSettling {
                        await AppResponsivenessMonitor.waitUntilForegroundSettles()
                    }
                    syncAtmosphereIfNeeded()
                }
                // tab 切回时让 AppKit 网格主动补一次布局，覆盖 hide/unhide 期间的脏布局
                gridLayoutRefreshToken &+= 1
            }
        }
        .onChange(of: searchText) { _, newValue in
            translationBridge.detectLanguage(for: newValue)
        }
        .onChange(of: translationBridge.translationCompleted) { _, _ in
            AppLogger.debug(.wallpaper, "[翻译] onChange translationCompleted")
            guard let pending = pendingSearchText else { return }
            pendingSearchText = nil
            let query = translationBridge.effectiveQuery(for: pending)
            AppLogger.debug(.wallpaper, "[翻译] translationCompleted 搜索 query='\(query)'")
            viewModel.searchQuery = query
            reloadData()
        }
        .onReceive(NotificationCenter.default.publisher(for: .wallpaperDataSourceChanged)) { _ in
            handleDataSourceChange()
            invalidateGridHeaderMeasurement()
        }
        .onChange(of: gridHeaderLayoutSignature) { _, _ in
            invalidateGridHeaderMeasurement()
        }
        .onChange(of: category) { _, _ in
            handleCategoryChange()
            syncAtmosphereIfNeeded()
            // 分类切换同步执行重算（无需防抖，用户主动操作频率低）
            recomputeTask?.cancel()
            recomputeTask = Task { @MainActor in
                recomputeVisibleWallpapers()
            }
        }
        .onChange(of: fourKCategory) { _, _ in handle4KCategoryChange() }
        .onChange(of: hotTag) { _, _ in handleHotTagChange() }
        .onChange(of: viewModel.sortingOption) { _, _ in handleSortingChange() }
        .onChange(of: fourKSorting) { _, _ in handle4KSortingChange() }
        .onChange(of: konachanSorting) { _, _ in handleKonachanSortingChange() }
        .onChange(of: viewModel.wallpapers) { _, _ in
            let count = viewModel.wallpapers.count
            WallpaperExploreDiagnostics.markWallpapersChanged(
                totalCount: count,
                isLoading: viewModel.isLoading
            )
            AppLogger.debug(.wallpaper, "[诊断] wallpapers 变化", metadata: [
                "count": "\(count)",
                "isLoading": "\(viewModel.isLoading)"
            ])
            // ⚡ 3s 节流：loadMore 时 wallpapers 高频追加，syncAtmosphereIfNeeded 会下载缩略图
            // + CoreImage 颜色分析，不加节流会导致 CPU 持续满载。
            let now = Date()
            if now.timeIntervalSince(lastAtmosphereSyncTime) >= 3.0 {
                lastAtmosphereSyncTime = now
                syncAtmosphereIfNeeded()
            }

            // ✅ 异步防抖：取消上一次尚未执行的重算，开启新任务并等待 400ms 缓冲。
            // wallpapers 变更通知 + upsert 的 @Published 通知可能重叠，400ms 给 SwiftUI 足够时间
            // 完成观察系统处理，避免与滚动期间的 view 更新竞态导致主线程死锁。
            // ⚠️ 之前是 200ms，但偶发场景下仍能击破竞态保护——加大到 400ms 几乎能压住所有
            // 边界情况，代价仅是 loadMore 后新数据呈现稍晚 200ms（用户几乎感知不到）。
            recomputeTask?.cancel()
            recomputeTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 400_000_000) // 400ms 缓冲，避免与 SwiftUI 观察系统竞态
                guard !Task.isCancelled else { return }
                recomputeVisibleWallpapers()
            }
        }
        // ❌ 已移除 .onChange(of: libraryContentRevision)，收藏状态改为视图在 ForEach 中
        // 直接读取 viewModel.favoriteIDSet，避免 @State 中间赋值引发不必要的 body 重算。
        // ✅ AppKit 通道：收藏集合变化时只重配可视 cell（不整表 reload，不重启图片下载）
        .onChange(of: viewModel.favoriteIDSet) { _, _ in
            gridReloadToken &+= 1
        }
        // 数据顺序/身份变化（同长度筛选切换、排序变化等）也要让可视 cell 重读 wallpaper
        .onChange(of: lastVisibleIDs) { _, _ in
            gridReloadToken &+= 1
        }
        .overlay(alertOverlay)
        .sheet(isPresented: $showWallpaperURLSheet) {
            WorkshopURLInputSheet(
                urlInput: $wallpaperURLInput,
                errorMessage: wallpaperURLError,
                isLoading: isResolvingWallpaperURL,
                onSubmit: { handleWallpaperURLSubmit() },
                onDismiss: { showWallpaperURLSheet = false }
            )
        }
    }

    private func scrollContent(width: CGFloat, viewportHeight: CGFloat, gridConfig: WallpaperGridConfig) -> some View {
        ZStack {
            if visibleWallpapers.isEmpty {
                legacyScrollContent(width: width) {
                    Group {
                        if isWallpaperLoadingState {
                            loadingState
                        } else {
                            emptyState
                        }
                    }
                    .transition(.opacity.animation(.easeInOut(duration: 0.25)))
                }
            } else {
                if #available(macOS 15.0, *) {
                    scrollViewModern(width: width, gridConfig: gridConfig)
                } else {
                    scrollViewLegacy(width: width, viewportHeight: viewportHeight, gridConfig: gridConfig)
                }
            }

            // 底部加载状态卡片
            bottomLoadingOverlay

            scrollToTopButton
        }
    }

    private func legacyScrollContent<Content: View>(width: CGFloat, @ViewBuilder body: () -> Content) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                heroSection
                categorySection
                filterSection
                activeFiltersSection
                contentHeader
                    .padding(.top, 12)
                body()
            }
            .padding(.horizontal, 28)
            .padding(.top, mainTopBarContentPadding)
            .padding(.bottom, 48)
            .frame(width: width, alignment: .leading)
            .environment(\.explorePageAtmosphereTint, exploreAtmosphere.tint)
            .environment(\.arcIsLightMode, arcSettings.isLightMode)
        }
        .scrollDisabled(!isVisible)
    }

    // MARK: - macOS 15+：使用 onScrollGeometryChange

    @available(macOS 15.0, *)
    private func scrollViewModern(width: CGFloat, gridConfig: WallpaperGridConfig) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear
                        .frame(height: 0)
                        .id("wp-scroll-top")
                    gridHeaderStack
                    wallpaperGrid(config: gridConfig)
                }
                .padding(.horizontal, 28)
                .frame(width: width, alignment: .leading)
                .environment(\.explorePageAtmosphereTint, exploreAtmosphere.tint)
                .environment(\.arcIsLightMode, arcSettings.isLightMode)
            }
            .coordinateSpace(name: Self.scrollCoordinateSpaceName)
            .onChange(of: viewModel.wallpapers.count) { _, count in
                if count > 60 { showScrollToTop = true }
            }
            .onScrollGeometryChange(for: WallpaperLoadMoreScrollZone.self, of: { geometry in
                let bottomOffset = geometry.contentOffset.y + geometry.containerSize.height
                let distanceFromBottom = geometry.contentSize.height - bottomOffset
                guard distanceFromBottom.isFinite else {
                    return .far
                }
                if distanceFromBottom <= Self.loadMoreTriggerThreshold { return .near }
                if distanceFromBottom <= Self.loadMoreResetThreshold { return .armed }
                return .far
            }, action: { oldValue, newValue in
                if newValue == .near && oldValue != .near {
                    // ⛔ 冷却期内不触发 loadMore，防止 contentSize 增长后的无限级联
                    if let cooldown = loadMoreCooldownUntil, Date() < cooldown { return }
                    guard !scrollCoordinator.wasNearBottom else { return }
                    scrollCoordinator.wasNearBottom = true
                    self.scheduleLoadMoreFromScroll()
                } else if newValue == .far {
                    // ⚡ 延迟重置 wasNearBottom，给 contentSize 足够时间稳定
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                        scrollCoordinator.wasNearBottom = false
                    }
                }
            })
            .onScrollGeometryChange(for: CGFloat.self, of: { geometry in
                geometry.contentOffset.y
            }, action: { _, offset in
                handleScrollOffset(offset)
            })
            .scrollDisabled(!isVisible)
            .onChange(of: outerScrollToTopToken) { _, _ in
                withAnimation(nil) {
                    proxy.scrollTo("wp-scroll-top", anchor: .top)
                }
            }
        }
    }

    // MARK: - macOS 14：使用 PreferenceKey + 防抖

    private func scrollViewLegacy(width: CGFloat, viewportHeight: CGFloat, gridConfig: WallpaperGridConfig) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear
                        .frame(height: 0)
                        .id("wp-scroll-top")
                    gridHeaderStack
                    wallpaperGrid(config: gridConfig)
                    loadMoreSentinel
                }
                .padding(.horizontal, 28)
                .frame(width: width, alignment: .leading)
                .environment(\.explorePageAtmosphereTint, exploreAtmosphere.tint)
                .environment(\.arcIsLightMode, arcSettings.isLightMode)
                .background(
                    ScrollToTopHelper(trigger: 0, onOffsetChange: handleScrollOffset)
                        .frame(width: 0, height: 0)
                )
            }
            .coordinateSpace(name: Self.scrollCoordinateSpaceName)
            .onChange(of: viewModel.wallpapers.count) { _, count in
                if count > 60 { showScrollToTop = true }
            }
            .onPreferenceChange(WallpaperLoadMoreSentinelMinYPreferenceKey.self) { sentinelMinY in
                WallpaperExploreScrollActivity.markActive()
                scrollCoordinator.sentinelDebounceTask?.cancel()
                let task = DispatchWorkItem { [self] in
                    guard !Task.isCancelled else { return }
                    self.handleLoadMoreSentinelPosition(sentinelMinY, viewportHeight: viewportHeight)
                }
                scrollCoordinator.sentinelDebounceTask = task
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: task)
            }
            .scrollDisabled(!isVisible)
            .onChange(of: outerScrollToTopToken) { _, _ in
                withAnimation(nil) {
                    proxy.scrollTo("wp-scroll-top", anchor: .top)
                }
            }
        }
    }

    private var scrollToTopButton: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                if showScrollToTop {
                    ScrollToTopButton {
                        outerScrollToTopToken += 1
                    }
                    .padding(.trailing, 28)
                    .padding(.bottom, 120)
                    .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: showScrollToTop)
    }

    private var bottomLoadingOverlay: some View {
        VStack {
            Spacer()
            if loadMoreFailed {
                BottomLoadingFailedCard {
                    triggerLoadMore()
                }
                .padding(.bottom, 60)
            } else if isLoadingMore || (viewModel.isLoading && !visibleWallpapers.isEmpty) {
                BottomLoadingCard(isLoading: true)
                    .padding(.bottom, 60)
            } else if !isLoadingMore && !viewModel.hasMorePages && !visibleWallpapers.isEmpty {
                BottomNoMoreCard()
                    .padding(.bottom, 60)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private var alertOverlay: some View {
        EmptyView()
            .alert(t("apiKeyRequired"), isPresented: $showAPIKeyAlert) {
                Button(t("ok"), role: .cancel) {}
            } message: {
                Text(t("apiKeyNeeded"))
            }
    }

    // MARK: - Sections

    @ViewBuilder
    private var heroSection: some View {
        if #available(macOS 15.0, *) {
            TranslationTaskHost(bridge: translationBridge) {
                heroSectionContent
            }
        } else {
            heroSectionContent
        }
    }

    private var heroSectionContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            headerTitle
            searchRow
            konachanHotTagsRow
            hotTagsRow
            konachanCategoriesRow
        }
        .frame(maxWidth: 700, alignment: .leading)
    }

    @ViewBuilder
    private var konachanHotTagsRow: some View {
        if WallpaperSourceManager.shared.activeSource == .konachan {
            // 热门标签（紧接搜索框下方，不换行）
            HStack(alignment: .center, spacing: 10) {
                Text(t("hotWallpaper") + ":")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(arcSettings.secondaryText.opacity(0.65))

                ForEach(konachanDynamicHotTags) { tag in
                    TagChip(
                        title: KonachanService.displayName(for: tag.name),
                        isSelected: konachanHotTagName == tag.name
                    ) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            if konachanHotTagName == tag.name {
                                konachanHotTagName = nil
                                searchText = ""
                                viewModel.searchQuery = ""
                            } else {
                                konachanHotTagName = tag.name
                                konachanCategory = nil
                                searchText = tag.name
                                viewModel.searchQuery = tag.name
                            }
                            reloadData()
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var konachanCategoriesRow: some View {
        if WallpaperSourceManager.shared.activeSource == .konachan {
            // 分类（可换行，与 Wallhaven 风格一致）
            FlowLayout(spacing: 10) {
                ForEach(KonachanService.categories) { cat in
                    CategoryChip(
                        icon: cat.icon,
                        title: cat.name,
                        accentColors: cat.accentColors,
                        isSelected: konachanCategory?.id == cat.id
                    ) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            if konachanCategory?.id == cat.id {
                                konachanCategory = nil
                                searchText = ""
                                viewModel.searchQuery = ""
                            } else {
                                konachanCategory = cat
                                konachanHotTagName = nil
                                searchText = cat.query
                                viewModel.searchQuery = cat.query
                            }
                            reloadData()
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var headerTitle: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(greetingText)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(arcSettings.secondaryText.opacity(0.85))

                // 源切换 Menu（支持扩展更多源）
                Menu {
                    ForEach(WallpaperSourceManager.SourceType.allCases, id: \.self) { source in
                        Button {
                            WallpaperSourceManager.shared.switchTo(source)
                        } label: {
                            HStack(spacing: 8) {
                                Text(source.displayName)
                                    .font(.system(size: 13, weight: .semibold))
                                if source == WallpaperSourceManager.shared.activeSource {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 11, weight: .bold))
                                }
                            }
                        }
                    }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Image(systemName: "globe")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(arcSettings.primaryText.opacity(0.55))
                        Text(WallpaperSourceManager.shared.activeSource.displayName)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(arcSettings.primaryText.opacity(0.75))
                    }
                }
                .menuStyle(.borderlessButton)
                .offset(y: 1.5)
                .background {
                    SourceHintIcon()
                        .fixedSize()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .offset(x: 18)
                }
            }

            Text(t("wallpaperLibrary"))
                .font(.system(size: 32, weight: .bold, design: .serif))
                .tracking(-0.5)
                .foregroundStyle(arcSettings.primaryText)
                .lineLimit(1)
        }
    }

    private var searchRow: some View {
        HStack(spacing: 12) {
            if WallpaperSourceManager.shared.activeSource == .konachan {
                KonachanTagSearchField(
                    text: $searchText,
                    placeholder: t("search.placeholder"),
                    tint: exploreAtmosphere.tint.primary,
                    onSubmit: { tagName in
                        hotTag = nil
                        viewModel.searchQuery = tagName
                        reloadData()
                    },
                    onClear: {
                        searchText = ""
                        viewModel.searchQuery = ""
                        translationBridge.reset()
                        reloadData()
                    }
                )
            } else {
                ExploreSearchBar(
                    text: $searchText,
                    placeholder: t("search.placeholder"),
                    tint: exploreAtmosphere.tint.primary,
                    onSubmit: submitSearch,
                    onClear: { searchText = ""; translationBridge.reset(); submitSearch() },
                    translatedText: translationBridge.translatedText,
                    isTranslating: translationBridge.isTranslating,
                    onDismissTranslation: {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                            translationBridge.dismiss()
                        }
                    }
                )
            }

            WorkshopURLInputButton(tint: exploreAtmosphere.tint.primary) {
                showWallpaperURLSheet = true
            }

            if !arcSettings.compactMode {
                ArcBackgroundPanelButton(tint: exploreAtmosphere.tint.primary, grainIntensity: $arcSettings.exploreGrainWallpaper) {
                    randomizeAtmosphere()
                }
            }

            ResetFiltersButton(tint: exploreAtmosphere.tint.secondary) {
                resetAllFilters(reloadData: true)
            }
        }
    }

    @ViewBuilder
    private var hotTagsRow: some View {
        if viewModel.currentSourceSupportsRatioFilter {
            HStack(alignment: .center, spacing: 10) {
                Text(t("hotWallpaper") + ":")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(arcSettings.secondaryText.opacity(0.65))

                ForEach(HotTag.allCases) { tag in
                    TagChip(
                        title: tag.title,
                        isSelected: hotTag == tag
                    ) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            hotTag = (hotTag == tag) ? nil : tag
                        }
                    }
                }

                ratioMenu
            }
        }
    }

    @ViewBuilder
    private var categorySection: some View {
        if viewModel.currentSourceSupportsCategories {
            FlowLayout(spacing: 12) {
                if viewModel.currentSourceSupportsWallhavenCategories {
                    ForEach(CategoryFilter.allCases) { cat in
                        CategoryChip(
                            icon: cat.icon,
                            title: cat.title,
                            accentColors: cat.accentColors,
                            isSelected: category == cat
                        ) {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                category = cat
                            }
                        }
                    }
                } else {
                    FourKCategoryChip(
                        category: nil,
                        name: t("tab.all"),
                        isSelected: fourKCategory == nil
                    ) { fourKCategory = nil; handle4KCategoryChange() }

                    ForEach(FourKWallpapersParser.categories) { cat in
                        FourKCategoryChip(
                            category: cat,
                            name: t("4k.category.\(cat.id)"),
                            isSelected: fourKCategory?.id == cat.id
                        ) {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                fourKCategory = cat
                            }
                            handle4KCategoryChange()
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private var filterSection: some View {
        let hasNSFW = viewModel.currentSourceSupportsNSFW
        let hasColor = viewModel.currentSourceSupportsColorFilter

        if hasNSFW || hasColor {
            VStack(alignment: .leading, spacing: 16) {
                if hasNSFW { purityFilter }
                if hasColor { colorFilter }
            }
        }
    }

    @ViewBuilder
    private var purityFilter: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(t("contentLevel"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(arcSettings.secondaryText.opacity(0.46))
            FlowLayout(spacing: 10) {
                ForEach(visiblePurityFilters) { filter in
                    FilterChip(
                        title: filter.title,
                        subtitle: filter.subtitle,
                        isSelected: isPuritySelected(filter),
                        tint: filter.tint
                    ) {
                        togglePurity(filter)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var colorFilter: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(t("colorFilter"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(arcSettings.secondaryText.opacity(0.46))
            FlowLayout(spacing: 10) {
                ForEach(quickColorPresets) { preset in
                    ColorChip(
                        preset: preset,
                        isSelected: viewModel.selectedColors.first == preset.hex
                    ) {
                        toggleColor(preset)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var activeFiltersSection: some View {
        let chips = activeFilterChips
        if !chips.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Text(t("currentFilters"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(arcSettings.secondaryText.opacity(0.46))
                    Button(t("clear")) { resetServerFilters() }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(arcSettings.secondaryText.opacity(0.72))
                        .buttonStyle(.plain)
                }
                FlowLayout(spacing: 10) {
                    ForEach(chips) { chip in
                        ActiveFilterChip(chip: chip) { removeFilter(chip) }
                    }
                }
            }
        }
    }

    private func contentSection(config: WallpaperGridConfig) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            contentHeader

            if viewModel.isLoading && visibleWallpapers.isEmpty {
                WallpaperGridSkeleton(contentWidth: config.contentWidth)
                    .transition(.opacity.animation(.easeInOut(duration: 0.25)))
            } else if visibleWallpapers.isEmpty {
                emptyState
                    .transition(.opacity.animation(.easeInOut(duration: 0.25)))
            } else {
                wallpaperGrid(config: config)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var contentHeader: some View {
        HStack(alignment: .center) {
            Text("\(visibleWallpapers.count) \(t("wallpaperCount"))")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(arcSettings.secondaryText.opacity(0.66))

            Spacer()

            if viewModel.currentSourceSupportsWallhavenSorting {
                SortMenu(options: SortingOption.allCases, selected: $viewModel.sortingOption, tint: exploreAtmosphere.tint.primary)
            } else if WallpaperSourceManager.shared.activeSource == .konachan {
                SortMenu(options: KonachanSorting.allCases, selected: $konachanSorting, tint: exploreAtmosphere.tint.primary)
            } else {
                SortMenu(options: FourKSortingOption.allCases, selected: $fourKSorting, tint: exploreAtmosphere.tint.primary)
            }
        }
    }

    private var gridHeaderStack: some View {
        Group {
            if isGridHeaderContentMounted {
                gridHeaderContent
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: WallpaperExploreHeaderHeightPreferenceKey.self,
                                value: proxy.size.height
                            )
                        }
                    )
            } else {
                Color.clear
                    .frame(height: max(measuredGridHeaderHeight, 1))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onPreferenceChange(WallpaperExploreHeaderHeightPreferenceKey.self) { height in
            updateMeasuredGridHeaderHeight(height)
        }
    }

    private var gridHeaderContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            heroSection
            categorySection
            filterSection
            activeFiltersSection
            contentHeader
                .padding(.top, 12)
        }
        .padding(.top, mainTopBarContentPadding)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var gridHeaderLayoutSignature: String {
        [
            WallpaperSourceManager.shared.activeSource.rawValue,
            category.rawValue,
            fourKCategory?.id ?? "none",
            konachanCategory?.id ?? "none",
            konachanHotTagName ?? "none",
            hotTag?.id ?? "none",
            viewModel.puritySFW ? "sfw1" : "sfw0",
            viewModel.puritySketchy ? "sketchy1" : "sketchy0",
            viewModel.purityNSFW ? "nsfw1" : "nsfw0",
            viewModel.selectedColors.joined(separator: ",")
        ].joined(separator: "|")
    }

    private func handleScrollOffset(_ offset: CGFloat) {
        WallpaperExploreScrollActivity.markActive()
        updateGridHeaderMountState(scrollOffset: offset)
    }

    private func updateGridHeaderMountState(scrollOffset: CGFloat) {
        let headerHeight = measuredGridHeaderHeight > 1 ? measuredGridHeaderHeight : 260
        let hideThreshold = headerHeight + 80
        let showThreshold = max(0, headerHeight - 48)
        let shouldMount = isGridHeaderContentMounted
            ? scrollOffset < hideThreshold
            : scrollOffset < showThreshold

        guard shouldMount != isGridHeaderContentMounted else { return }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isGridHeaderContentMounted = shouldMount
        }
    }

    private func updateMeasuredGridHeaderHeight(_ height: CGFloat) {
        guard height > 1, abs(height - measuredGridHeaderHeight) > 1 else { return }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            measuredGridHeaderHeight = height
        }
    }

    private func invalidateGridHeaderMeasurement() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isGridHeaderContentMounted = true
            measuredGridHeaderHeight = 0
        }
    }

    // MARK: - Grid & Cards

    private func wallpaperGrid(config: WallpaperGridConfig) -> some View {
        // 走 AppKit `NSCollectionView` 通道（`ExploreGridContainer` + `WallpaperGridCell`）。
        // 关键参数：
        //   - allowsScrolling: false → 外层 SwiftUI ScrollView 拥有总滚动权，
        //     header / 网格 / loadMore sentinel 共享同一滚动模型。
        //   - onContentHeightChange → 把 AppKit 算出来的内容高度写回 SwiftUI，
        //     再用 .frame(height: gridContentHeight) 把高度兑现给外层 ScrollView。
        //   - onReachBottom: 空实现 — loadMore 全权由 SwiftUI sentinel/scrollGeometry
        //     驱动，避免双源竞态。allowsScrolling=false 时 AppKit 也不会发该回调。
        //   - onScrollOffsetChange: 不消费 — AppKit 不滚动不会发；滚回顶部按钮
        //     可见性继续由外层 SwiftUI offset 计算（handleScrollOffset）。
        // 备胎：`WallpaperGridContainerView`（SwiftUI ZStack chunks）保留在本文件下方
        // 与 `Components/WaterfallChunkLayout.swift`，未来如需切回再启用。
        ExploreGridContainer(
            itemCount: { visibleWallpapers.count },
            aspectRatio: { idx in
                guard idx < visibleWallpapers.count else {
                    return wallpaperCellAspectRatio(config: config)
                }
                return wallpaperCellAspectRatio(for: visibleWallpapers[idx], config: config)
            },
            configureCell: { cell, idx in
                guard idx < visibleWallpapers.count else { return }
                cell.configure(
                    with: visibleWallpapers[idx],
                    isFavorite: viewModel.isFavorite(visibleWallpapers[idx])
                )
            },
            cellClass: WallpaperGridCell.self,
            onSelect: { idx in
                guard idx < visibleWallpapers.count else { return }
                selectedWallpaper = visibleWallpapers[idx]
            },
            onVisibleItemsChange: nil, // 不再做近邻预取，依赖每个 cell 自己 lazy 加载
            onScrollOffsetChange: nil, // allowsScrolling=false 时不会触发
            onReachBottom: {},          // loadMore 由 SwiftUI sentinel 驱动
            scrollToTopToken: 0,        // 滚回顶部由外层 SwiftUI ScrollView 处理
            reloadToken: gridReloadToken,
            layoutRefreshToken: gridLayoutRefreshToken,
            allowsScrolling: false,
            onContentHeightChange: { height in
                if abs(gridContentHeight - height) > 0.5 {
                    gridContentHeight = height
                }
            },
            isVisible: isVisible,
            layoutWidth: config.contentWidth,
            gridColumnCount: config.columnCount,
            // hover scale 仅 1.02 + zPosition=100 + masksToBounds=false，column/row spacing 16pt
            // 已远大于缩放溢出，不需要预留扩张空间。设 0 让卡片完整占满列宽，对齐旧 SwiftUI 视觉。
            hoverExpansionAllowance: 0,
            // 默认 contentInsets 包含 bottom: 48 给动漫/媒体页留触底缓冲，
            // 但壁纸探索页外层 SwiftUI ScrollView 自己控边距，AppKit 不应再加。
            contentInsets: NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        )
        .frame(height: max(gridContentHeight, 320))
    }

    /// 卡片整体（图像 + 46pt 底栏）的宽高比，供 ExploreGridCollectionViewLayout 计算 cell 高度。
    /// 默认值（无具体壁纸时）：按 0.6 图像宽高比 + 46pt 底栏估算，保持视觉占位接近常见值。
    private func wallpaperCellAspectRatio(config: WallpaperGridConfig) -> CGFloat {
        let safeCardWidth = max(1, config.cardWidth)
        let height = safeCardWidth * 0.6 + 46
        return safeCardWidth / max(1, height)
    }

    /// 单张壁纸的卡片宽高比。原始图像比例钳制在 0.35...3.6（与 WallpaperCardView 一致），
    /// 防止超长竖图把列撑爆，或超宽横图破坏视觉。
    private func wallpaperCellAspectRatio(for wallpaper: Wallpaper, config: WallpaperGridConfig) -> CGFloat {
        let safeCardWidth = max(1, config.cardWidth)
        let imageAspectRatio = CGFloat(wallpaper.effectiveAspectRatioValue)
        let clampedImageAspectRatio = min(max(imageAspectRatio, 0.35), 3.6)
        let imageHeight = safeCardWidth / clampedImageAspectRatio
        let height = imageHeight + 46
        return safeCardWidth / max(1, height)
    }

    // MARK: - UI Components

    private var emptyState: some View {
        Group {
            if let errorMessage = viewModel.errorMessage {
                ErrorStateView(
                    type: viewModel.networkStatus.connectionState == .offline ? .offline : .network,
                    message: errorMessage,
                    retryAction: reloadData
                )
            } else {
                ErrorStateView(
                    type: .empty,
                    title: t("no.wallpapers"),
                    message: t("tryDifferentFilter"),
                    retryAction: reloadData
                )
            }
        }
        .frame(height: 240)
        .exploreFrostedPanel(cornerRadius: 30, tint: exploreAtmosphere.tint.primary)
    }

    private var loadingState: some View {
        ExploreLoadingStateView(
            message: t("loading"),
            tint: arcSettings.primaryText
        )
        .exploreFrostedPanel(cornerRadius: 30, tint: exploreAtmosphere.tint.primary)
    }

    private var isWallpaperLoadingState: Bool {
        visibleWallpapers.isEmpty && (
            isInitialLoading
            || isFirstAppearance
            || viewModel.isLoading
        )
    }

    // MARK: - macOS 14 滚动哨兵

    private var loadMoreSentinel: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: WallpaperLoadMoreSentinelMinYPreferenceKey.self,
                value: proxy.frame(in: .named(Self.scrollCoordinateSpaceName)).minY
            )
        }
        .frame(height: 1)
    }

    private var ratioMenu: some View {
        Menu {
            Button(t("allRatios")) { viewModel.selectedRatios = []; reloadData() }
            Divider()
            ForEach(["16x9", "16x10", "21x9", "4x3", "3x2", "1x1", "9x16", "10x16"], id: \.self) { ratio in
                let isSelected = viewModel.selectedRatios.contains(ratio)
                Button {
                    viewModel.selectedRatios = isSelected ? [] : [ratio]
                    reloadData()
                } label: {
                    HStack {
                        Text(ratio.replacingOccurrences(of: "x", with: ":"))
                        if isSelected { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            let hasRatio = !viewModel.selectedRatios.isEmpty
            HStack(spacing: 6) {
                Image(systemName: "aspectratio").font(.system(size: 11, weight: .semibold))
                Text(hasRatio ? (viewModel.selectedRatios.first?.replacingOccurrences(of:"x", with: ":") ?? "") : t("ratio"))
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(hasRatio ? arcSettings.primaryText.opacity(0.95) : arcSettings.secondaryText.opacity(0.7))
            .padding(.horizontal, 12)
            .frame(height: 30)
            .exploreFrostedCapsule(
                tint: exploreAtmosphere.tint.primary,
                material: hasRatio ? .regularMaterial : .ultraThinMaterial,
                tintLayerOpacity: hasRatio ? 0.1 : 0.03
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - Actions

    private func handleAppear() {
        AppLogger.info(.wallpaper, "壁纸探索页 onAppear",
            metadata: ["已有数据": !viewModel.wallpapers.isEmpty, "当前数量": viewModel.wallpapers.count])

        if searchText.isEmpty { searchText = viewModel.searchQuery }

        if viewModel.wallpapers.isEmpty {
            isInitialLoading = true
            Task {
                let start = Date()
                await viewModel.search()
                await MainActor.run {
                    recomputeVisibleWallpapers()
                    syncAtmosphereIfNeeded()
                    isInitialLoading = false
                }
                AppLogger.info(.wallpaper, "首次加载完成",
                    metadata: [
                        "耗时(s)": String(format: "%.2f", Date().timeIntervalSince(start)),
                        "结果数": viewModel.wallpapers.count,
                        "错误": viewModel.errorMessage ?? "无"
                    ])
            }
        } else {
            recomputeVisibleWallpapers()
            syncAtmosphereIfNeeded()
        }
    }

    // 移除递归加载逻辑，保留触底分页保底机制

    private func handleWallpaperURLSubmit() {
        let url = wallpaperURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else {
            wallpaperURLError = t("common.enterURL")
            return
        }
        isResolvingWallpaperURL = true
        wallpaperURLError = nil
        Task {
            do {
                let wallpaper = try await viewModel.resolveWallpaperByURL(url)
                await MainActor.run {
                    isResolvingWallpaperURL = false
                    showWallpaperURLSheet = false
                    wallpaperURLInput = ""
                    selectedWallpaper = wallpaper
                }
            } catch {
                await MainActor.run {
                    isResolvingWallpaperURL = false
                    wallpaperURLError = error.localizedDescription
                }
            }
        }
    }

    private func handleDataSourceChange() {
        if !viewModel.currentSourceSupportsNSFW {
            viewModel.puritySFW = true
            viewModel.puritySketchy = false
            viewModel.purityNSFW = false
        }
        fourKCategory = nil
        konachanSorting = .dateAdded
        konachanCategory = nil
        konachanHotTagName = nil
        category = .all
        loadKonachanHotTags()
        // 数据源切换时必须清空旧数据，避免新旧源内容混在一起显示
        viewModel.wallpapers.removeAll()
        reloadData()
    }

    private func handleCategoryChange() {
        switch category {
        case .all:
            viewModel.categoryGeneral = true
            viewModel.categoryAnime = true
            viewModel.categoryPeople = true
        case .general:
            viewModel.categoryGeneral = true
            viewModel.categoryAnime = false
            viewModel.categoryPeople = false
        case .anime:
            viewModel.categoryGeneral = false
            viewModel.categoryAnime = true
            viewModel.categoryPeople = false
        case .people:
            viewModel.categoryGeneral = false
            viewModel.categoryAnime = false
            viewModel.categoryPeople = true
        }
        reloadData()
    }

    private func handle4KCategoryChange() {
        viewModel.selected4KCategorySlug = fourKCategory?.id
        reloadData()
    }

    private func handleHotTagChange() {
        if let tag = hotTag {
            viewModel.selectedRatios = tag.apiRatios ?? []
            viewModel.atleastResolution = tag.apiAtleast
        } else {
            viewModel.selectedRatios = []
            viewModel.atleastResolution = nil
        }
        reloadData()
    }

    private func handleSortingChange() {
        AppLogger.info(.wallpaper, "排序方式变化", metadata: ["排序": viewModel.sortingOption.rawValue])
        reloadData()
    }

    private func handle4KSortingChange() {
        AppLogger.info(.wallpaper, "4K 排序方式变化", metadata: ["排序": fourKSorting.rawValue])
        viewModel.selected4KSorting = fourKSorting
        reloadData()
    }

    private func handleKonachanSortingChange() {
        AppLogger.info(.wallpaper, "Konachan 排序方式变化", metadata: ["排序": konachanSorting.rawValue])
        viewModel.selectedKonachanSorting = konachanSorting
        reloadData()
    }

    private func loadKonachanHotTags() {
        guard WallpaperSourceManager.shared.activeSource == .konachan else { return }
        Task {
            do {
                let tags = try await KonachanService.shared.fetchHotTags(limit: 6)
                await MainActor.run {
                    self.konachanDynamicHotTags = tags
                }
            } catch {
                print("[KonachanHotTags] failed: \(error)")
            }
        }
    }

    private func triggerLoadMore() {
        guard viewModel.hasMorePages else {
            WallpaperExploreDiagnostics.markLoadMoreSkipped(source: "triggerLoadMore", reason: "noMorePages")
            return
        }
        guard !viewModel.isLoading else {
            WallpaperExploreDiagnostics.markLoadMoreSkipped(source: "triggerLoadMore", reason: "viewModelLoading")
            return
        }
        guard !isLoadingMore else {
            WallpaperExploreDiagnostics.markLoadMoreSkipped(source: "triggerLoadMore", reason: "alreadyLoadingMore")
            return
        }

        // ⛔ 冷却期内不触发 loadMore（防止 contentSize 增长后的无限级联）
        if let cooldown = loadMoreCooldownUntil, Date() < cooldown {
            WallpaperExploreDiagnostics.markLoadMoreSkipped(source: "triggerLoadMore", reason: "cooldown")
            return
        }

        WallpaperExploreDiagnostics.markLoadMoreTriggered(
            source: "triggerLoadMore",
            currentCount: viewModel.wallpapers.count
        )
        // ⚠️ 诊断日志：检测 loadMore 触发
        AppLogger.info(.wallpaper, "[诊断] triggerLoadMore 触发", metadata: [
            "currentCount": "\(viewModel.wallpapers.count)",
            "isLoading": "\(viewModel.isLoading)",
            "hasMorePages": "\(viewModel.hasMorePages)"
        ])
        isLoadingMore = true
        loadMoreFailed = false
        ForegroundPrefetchManager.shared.stop(namespace: "wallpaper-view-model")
        loadMoreTask?.cancel()
        loadMoreTask = Task { @MainActor in
            defer {
                loadMoreTask = nil
            }

            guard !Task.isCancelled else { return }
            loadMoreFailed = false
            let start = Date()
            await viewModel.loadMore()
            let duration = Date().timeIntervalSince(start) * 1000
            // ⚠️ 诊断日志：检测 loadMore 耗时
            AppLogger.info(.wallpaper, "[诊断] loadMore 完成", metadata: [
                "durationMS": String(format: "%.2f", duration),
                "newCount": "\(viewModel.wallpapers.count)",
                "hasMorePages": "\(viewModel.hasMorePages)"
            ])
            guard !Task.isCancelled else { return }
            if viewModel.hasMorePages && viewModel.errorMessage != nil {
                loadMoreFailed = true
            }
            // ⚡ 设置 1.5s 冷却期 + 0.5s 延迟释放 isLoadingMore，双重防护防止 contentSize 增长 →
            // isNearBottom 翻转 → 立即重试的无限级联。
            loadMoreCooldownUntil = Date().addingTimeInterval(1.5)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                isLoadingMore = false
            }
        }
    }

    private func scheduleLoadMoreFromScroll() {
        scrollCoordinator.pendingLoadMoreTask?.cancel()
        let task = DispatchWorkItem { [self] in
            triggerLoadMore()
        }
        scrollCoordinator.pendingLoadMoreTask = task
        DispatchQueue.main.async(execute: task)
    }

    private func handleLoadMoreSentinelPosition(_ sentinelMinY: CGFloat, viewportHeight: CGFloat) {
        guard isVisible, viewportHeight > 0, sentinelMinY.isFinite else { return }
        if sentinelMinY <= viewportHeight + Self.loadMoreTriggerThreshold {
            // ⛔ 冷却期内不触发 loadMore
            if let cooldown = loadMoreCooldownUntil, Date() < cooldown {
                WallpaperExploreDiagnostics.markLoadMoreSkipped(source: "legacySentinel", reason: "cooldown")
                return
            }
            guard !scrollCoordinator.wasNearBottom else {
                WallpaperExploreDiagnostics.markLoadMoreSkipped(source: "legacySentinel", reason: "alreadyNearBottom")
                return
            }
            scrollCoordinator.wasNearBottom = true
            scheduleLoadMoreFromScroll()
        } else if sentinelMinY > viewportHeight + Self.loadMoreResetThreshold {
            // ⚡ 延迟重置 wasNearBottom，给 contentSize 足够时间稳定
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                scrollCoordinator.wasNearBottom = false
            }
        }
    }

    private func submitSearch() {
        hotTag = nil
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        AppLogger.debug(.wallpaper, "[翻译] submitSearch: text='\(trimmed)' translatedText=\(translationBridge.translatedText ?? "nil") dismissed=\(translationBridge.translationDismissed)")

        guard !trimmed.isEmpty else {
            pendingSearchText = nil
            viewModel.searchQuery = ""
            translationBridge.reset()
            reloadData()
            return
        }

        // 同步检测中文（不依赖 debounce 的 isChineseDetected）
        let chineseDetected = translationBridge.isChinese(trimmed)
        AppLogger.debug(.wallpaper, "[翻译] submitSearch: isChinese=\(chineseDetected)")

        // 判断是否需要翻译：中文文本 && (无翻译结果 || 翻译结果不匹配当前文本) && 未被用户关闭
        let needsTranslation = chineseDetected
            && !translationBridge.translationDismissed
            && (translationBridge.translatedText == nil || translationBridge.translatedSourceText != trimmed)
        if needsTranslation {
            AppLogger.debug(.wallpaper, "[翻译] submitSearch: 触发翻译，等待翻译完成")
            pendingSearchText = trimmed

            // 先查缓存，命中则直接使用
            if translationBridge.checkCache(for: trimmed) {
                AppLogger.debug(.wallpaper, "[翻译] submitSearch: 缓存命中，直接搜索")
                pendingSearchText = nil
                let query = translationBridge.effectiveQuery(for: trimmed)
                searchText = query
                viewModel.searchQuery = query
                reloadData()
                return
            }

            // 缓存未命中，准备翻译并设置 config 触发 .translationTask
            translationBridge.prepareForTranslation(trimmed)
            translationBridge.triggerTranslation()
            AppLogger.debug(.wallpaper, "[翻译] submitSearch: config 已设置，等待 .translationTask 触发")
            return
        }

        pendingSearchText = nil
        let query = translationBridge.effectiveQuery(for: trimmed)
        AppLogger.debug(.wallpaper, "[翻译] submitSearch: 直接搜索 query='\(query)'")
        viewModel.searchQuery = query
        reloadData()
    }

    private func reloadData() {
        WallpaperExploreDiagnostics.markReloadRequested(
            reason: "userAction",
            isLoading: viewModel.isLoading,
            currentCount: viewModel.wallpapers.count
        )
        AppLogger.info(.wallpaper, "重新搜索：用户操作触发")
        prepareForFeedReplacement()
        lastSyncedFirstWallpaperID = nil
        loadMoreFailed = false
        viewModel.errorMessage = nil
        // 不再手动清空 wallpapers，让旧数据保持在屏幕上直到 search() 一次性替换新数据，
        // 避免根视图切换导致的抖动。
        Task {
            await viewModel.search()
            await MainActor.run {
                recomputeVisibleWallpapers()
                syncAtmosphereIfNeeded()
            }
        }
    }

    private func resetAllFilters(reloadData: Bool = false) {
        searchText = ""
        translationBridge.reset()
        viewModel.searchQuery = ""
        category = .all
        fourKCategory = nil
        viewModel.selected4KCategorySlug = nil
        hotTag = nil
        viewModel.puritySFW = true
        viewModel.puritySketchy = false
        viewModel.purityNSFW = false
        viewModel.sortingOption = .dateAdded
        viewModel.orderDescending = true
        viewModel.selectedColors = []
        viewModel.selectedRatios = []
        viewModel.selectedResolutions = []
        viewModel.atleastResolution = nil
        lastSyncedFirstWallpaperID = nil
        loadMoreFailed = false
        viewModel.errorMessage = nil
        prepareForFeedReplacement()

        if reloadData {
            // 不再手动清空 wallpapers，避免根视图切换导致的抖动
            Task {
                await viewModel.search()
                await MainActor.run {
                    recomputeVisibleWallpapers()
                    syncAtmosphereIfNeeded()
                }
            }
        } else {
            recomputeVisibleWallpapers()
        }
    }

    private func recomputeVisibleWallpapers() {
        let start = Date()
        let newVisible: [Wallpaper]
        if viewModel.currentSourceSupportsWallhavenCategories {
            newVisible = viewModel.wallpapers.filter { matchesCategory($0, category: category) }
        } else {
            newVisible = viewModel.wallpapers
        }
        // 仅当内容或顺序真正变化时才赋值，避免触发不必要的 body 重建
        // 必须使用数组比较而非 Set，因为顺序变化（如排序变更）也需要触发重排
        let newIDs = newVisible.map(\.id)
        let changed = newIDs != lastVisibleIDs
        if newIDs != lastVisibleIDs {
            lastVisibleIDs = newIDs
            visibleWallpapers = newVisible
        }
        let duration = Date().timeIntervalSince(start) * 1000
        WallpaperExploreDiagnostics.markRecompute(
            durationMS: duration,
            totalCount: viewModel.wallpapers.count,
            visibleCount: newVisible.count,
            changed: changed
        )
        // ⚠️ 诊断日志：检测 recompute 性能
        if duration > 16 {
            AppLogger.warn(.wallpaper, "[性能] recomputeVisibleWallpapers 耗时过长", metadata: [
                "durationMS": String(format: "%.2f", duration),
                "totalCount": "\(viewModel.wallpapers.count)",
                "visibleCount": "\(newVisible.count)",
                "changed": "\(changed)"
            ])
        }
    }

    // ❌ 已移除 refreshFavoriteIDs()，收藏状态改为视图在 ForEach 中
    // 直接读取 viewModel.favoriteIDSet，避免 @State 中间赋值。

    private func prepareForFeedReplacement() {
        loadMoreTask?.cancel()
        scrollCoordinator.cancelPendingWork()
        isLoadingMore = false
        loadMoreFailed = false
        showScrollToTop = false
        outerScrollToTopToken &+= 1
    }

    private func syncAtmosphereIfNeeded() {
        let first = visibleWallpapers.first
        let fid = first?.id
        guard fid != lastSyncedFirstWallpaperID else { return }
        lastSyncedFirstWallpaperID = fid
        WallpaperExploreDiagnostics.markAtmosphereSync(firstID: fid)
        DispatchQueue.main.async {
            guard lastSyncedFirstWallpaperID == fid else { return }
            exploreAtmosphere.updateFirstWallpaper(first)
        }
    }

    private func pauseActivity() {
        loadMoreTask?.cancel()
        loadMoreTask = nil
        exploreAtmosphere.pause()
    }

    private func randomizeAtmosphere() {
        guard !visibleWallpapers.isEmpty else { return }
        let random = visibleWallpapers.randomElement()!
        exploreAtmosphere.updateFromImageURL(
            random.thumbURL,
            keyPrefix: "rand-wallpaper"
        )
    }

    private func animateCardAppearance(id: String, index: Int) {
        // 已移除 visibleCardIDs，避免滚动时触发 @State 更新导致卡顿
    }



    private func calculateContentWidth(geometry: GeometryProxy) -> CGFloat {
        max(0, geometry.size.width - 56)
    }

    private func matchesCategory(_ wallpaper: Wallpaper, category: CategoryFilter) -> Bool {
        switch category {
        case .all: return true
        case .general: return wallpaper.category.lowercased() == "general"
        case .anime: return wallpaper.category.lowercased() == "anime"
        case .people: return wallpaper.category.lowercased() == "people"
        }
    }
}

// MARK: - 壁纸探索页氛围背景（独立观察视频壁纸播放状态）
/// 从 WallpaperExploreContentView 下沉而来：自行观察 VideoWallpaperManager /
/// WallpaperEngineXBridge，仅当播放状态变化时重建本背景视图，避免整个壁纸探索页
/// body 重算（含瀑布流布局重计算）。
private struct WallpaperExploreAtmosphereBackground: View {
    let tint: ExploreAtmosphereTint
    let referenceImage: NSImage?
    let isLightMode: Bool
    let dotGridOpacity: Double
    let grainIntensity: Double

    @ObservedObject private var videoWallpaperManager = VideoWallpaperManager.shared
    @ObservedObject private var wallpaperEngineBridge = WallpaperEngineXBridge.shared

    /// 动态壁纸正在播放时启用轻量特效，降低 GPU/WindowServer 压力
    private var shouldUseLightweightEffects: Bool {
        (videoWallpaperManager.isVideoWallpaperActive && !videoWallpaperManager.isPaused) ||
        (wallpaperEngineBridge.isControllingExternalEngine && !wallpaperEngineBridge.isExternalPaused)
    }

    var body: some View {
        ArcAtmosphereBackground(
            tint: tint,
            referenceImage: shouldUseLightweightEffects ? nil : referenceImage,
            isLightMode: isLightMode,
            dotGridOpacity: dotGridOpacity,
            useNoise: true,
            grainIntensity: grainIntensity,
            lightweight: shouldUseLightweightEffects
        )
        // 把多层渐变+点阵+噪点合并成一个 Metal 纹理，减少 WindowServer 合成层数
        .drawingGroup(opaque: true)
    }
}

// MARK: - Grid Configuration

/// 瀑布流网格容器（**备胎，当前未被引用**）。
///
/// 当前壁纸探索页瀑布流走 `Components/ExploreGrid/ExploreGridContainer`
/// + `WallpaperGridCell`（AppKit `NSCollectionView` 通道）。本结构体保留作为
/// 未来 SwiftUI 化的备胎，万一 AppKit 通道又出问题可以快速切回——只需把
/// `wallpaperGrid(config:)` 的实现替换回调用本类型即可。配套的
/// `WallpaperChunkView` / `Components/WaterfallChunkLayout.swift` 同样保留。
///
/// 设计：把 wallpapers 切成固定大小的 chunk（默认 30 张），外层用单 `LazyVStack`
/// 提供 chunk 级别的 lazy 加载（仅可见 chunk 实例化）。每个 chunk 内部使用
/// `WallpaperChunkView` —— 它**完全不使用 SwiftUI Layout protocol**，而是用
/// 纯算法预计算所有卡片位置，然后用 `ZStack` + `.position` 绝对定位。
///
/// 这样 SwiftUI 在 chunk 内部不会进入 LayoutEngineBox/UnaryLayoutEngine 的
/// 复杂 measure/place 路径——彻底绕过 macOS 26 上偶发的 SwiftUI 系统库
/// 死循环（CPU 100% 主线程卡死 5+ 秒）。
private struct WallpaperGridContainerView: View, Equatable {
    let wallpapers: [Wallpaper]
    /// 用于 Equatable 比较的稳定标识；变化时整个 grid 重建。
    let layoutKey: WallpaperWaterfallLayoutKey
    let config: WallpaperGridConfig
    let favoriteIDs: Set<Wallpaper.ID>
    let onSelect: (Wallpaper) -> Void

    /// 每 chunk 包含的卡片数。30 是兼顾视觉、内存与系统稳定性的折中值。
    private static let chunkSize: Int = 30

    private var chunks: [(index: Int, items: [Wallpaper])] {
        guard !wallpapers.isEmpty else { return [] }
        var result: [(index: Int, items: [Wallpaper])] = []
        var start = 0
        var idx = 0
        while start < wallpapers.count {
            let end = Swift.min(start + Self.chunkSize, wallpapers.count)
            result.append((index: idx, items: Array(wallpapers[start..<end])))
            start = end
            idx += 1
        }
        return result
    }

    var body: some View {
        let cardMaxHeight = WallpaperCardView.maxAllowedHeight(cardWidth: config.cardWidth)
        let totalChunkCount = chunks.count

        LazyVStack(spacing: config.spacing) {
            ForEach(chunks, id: \.index) { chunk in
                // 末尾 chunk 不做对齐——loadMore 时该位置数据会变化，
                // 若做对齐会引起末尾卡片高度跳变（用户感知"卡片放大缩小"）。
                // 非末尾 chunk 必然完整且后续不再变，可安全做对齐。
                WallpaperChunkView(
                    items: chunk.items,
                    columns: config.columnCount,
                    cardWidth: config.cardWidth,
                    spacing: config.spacing,
                    cardMaxHeight: cardMaxHeight,
                    alignToBaseline: chunk.index < totalChunkCount - 1,
                    favoriteIDs: favoriteIDs,
                    onSelect: onSelect
                )
            }
        }
    }

    nonisolated static func == (lhs: WallpaperGridContainerView, rhs: WallpaperGridContainerView) -> Bool {
        lhs.layoutKey == rhs.layoutKey &&
        lhs.config == rhs.config &&
        lhs.favoriteIDs == rhs.favoriteIDs
    }
}

// MARK: - WallpaperChunkView：纯 ZStack + 绝对定位的 chunk 容器
//
// **核心设计**：完全不使用 SwiftUI Layout protocol，而是用纯 Swift 函数预计算
// 所有卡片位置，再用 ZStack + .position 直接放置。这样 SwiftUI 在 chunk 内部
// 不会进入 LayoutEngineBox/UnaryLayoutEngine 的复杂 measure/place 路径——
// 彻底绕过 macOS 26 上偶发的 SwiftUI 系统库死循环（CPU 100% 卡死 5+ 秒）。
//
// 性能特性：
// - chunk 内 30 张卡片全部实例化（不 lazy），但 KFImage 通过 hasStartedImageLoading
//   仍是延迟加载，单 chunk 内存可控
// - 外层 LazyVStack 通过 chunk 的固定 height 直接知道总高度，不需调 sizeThatFits
// - 仅可见 chunk 的视图被构造（外层 LazyVStack 的 lazy 行为）
private struct WallpaperChunkView: View, Equatable {
    let items: [Wallpaper]
    let columns: Int
    let cardWidth: CGFloat
    let spacing: CGFloat
    let cardMaxHeight: CGFloat
    let alignToBaseline: Bool
    let favoriteIDs: Set<Wallpaper.ID>
    let onSelect: (Wallpaper) -> Void

    /// chunk 容器的总宽度。理论上等于父容器（grid contentWidth），但布局计算只
    /// 关心相对位置 + 居中偏移。这里取 columns × cardWidth + (columns-1) × spacing
    /// 作为最小所需宽，外层 ScrollView 已限定 contentWidth ≥ 此值。
    private var chunkLayout: WallpaperChunkLayoutResult {
        let totalWidth = CGFloat(columns) * cardWidth + CGFloat(Swift.max(0, columns - 1)) * spacing
        return computeWallpaperChunkLayout(
            cardCount: items.count,
            baseHeight: { idx in
                WallpaperCardView.estimatedHeight(cardWidth: cardWidth, wallpaper: items[idx])
            },
            maxHeight: { _ in cardMaxHeight },
            columns: columns,
            columnWidth: cardWidth,
            spacing: spacing,
            totalWidth: totalWidth,
            alignToBaseline: alignToBaseline
        )
    }

    var body: some View {
        let layout = chunkLayout
        ZStack(alignment: .topLeading) {
            ForEach(Array(items.enumerated()), id: \.element.id) { idx, wallpaper in
                if idx < layout.placements.count {
                    let frame = layout.placements[idx].frame
                    WallpaperCardView(
                        wallpaper: wallpaper,
                        isFavorite: favoriteIDs.contains(wallpaper.id),
                        cardWidth: cardWidth
                    ) {
                        onSelect(wallpaper)
                    }
                    .equatable()
                    .frame(width: frame.width, height: frame.height)
                    // .position 接受卡片的中心点；frame 是左上角原点，需转换
                    .position(x: frame.midX, y: frame.midY)
                }
            }
        }
        // 关键：固定 chunk 整体高度，外层 LazyVStack 直接知道总高，
        // 不需要调用任何 sizeThatFits / Layout protocol 路径
        .frame(maxWidth: .infinity)
        .frame(height: layout.totalHeight)
    }

    nonisolated static func == (lhs: WallpaperChunkView, rhs: WallpaperChunkView) -> Bool {
        // 比较 IDs 数组以判断 chunk 内容是否变化（避免在 favoriteIDs 等无关变化时重算布局）
        guard lhs.items.count == rhs.items.count else { return false }
        for i in 0..<lhs.items.count where lhs.items[i].id != rhs.items[i].id {
            return false
        }
        return lhs.columns == rhs.columns
            && lhs.cardWidth == rhs.cardWidth
            && lhs.spacing == rhs.spacing
            && lhs.cardMaxHeight == rhs.cardMaxHeight
            && lhs.alignToBaseline == rhs.alignToBaseline
            && lhs.favoriteIDs == rhs.favoriteIDs
    }
}

private struct WallpaperWaterfallLayoutKey: Equatable {
    let ids: [Wallpaper.ID]
    let columnCount: Int
    let cardWidth: CGFloat
    let spacing: CGFloat
}

// 注：原基于 SwiftUI Layout protocol 的 `WaterfallChunkLayout` 已移除——
// macOS 26 上 Layout protocol 实现会触发 SwiftUICore 死循环（CPU 100% 卡死）。
// 现在使用纯算法 + ZStack/.position 的 `WallpaperChunkView`。

private struct WallpaperGridConfig: Equatable {
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
        self.gridItems = Array(repeating: GridItem(.flexible(), spacing: spacing), count: columnCount)
    }

    static func == (lhs: WallpaperGridConfig, rhs: WallpaperGridConfig) -> Bool {
        lhs.columnCount == rhs.columnCount &&
        lhs.spacing == rhs.spacing &&
        lhs.cardWidth == rhs.cardWidth &&
        lhs.contentWidth == rhs.contentWidth
    }
}

// MARK: - Enums

private enum CategoryFilter: String, CaseIterable, Identifiable {
    case all, general, anime, people
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return t("tab.all")
        case .general: return t("filter.general")
        case .anime: return t("filter.anime")
        case .people: return t("filter.people")
        }
    }
    var icon: String {
        switch self {
        case .all: return "sparkles"
        case .general: return "photo.fill"
        case .anime: return "face.smiling.fill"
        case .people: return "person.fill"
        }
    }
    var accentColors: [String] {
        switch self {
        case .all: return ["FF9B58", "F54E42"]
        case .general: return ["5A7CFF", "20C1FF"]
        case .anime: return ["FF9ED2", "C069FF"]
        case .people: return ["F6E0D3", "AA785F"]
        }
    }
}

private enum HotTag: String, CaseIterable, Identifiable {
    case ultraHD, ultrawide, ratio21x9, ratio32x9, ratio16x9, portrait
    var id: String { rawValue }
    var title: String {
        switch self {
        case .ultraHD: return "4K"
        case .ultrawide: return t("aspect.ultrawide")
        case .ratio21x9: return "21:9"
        case .ratio32x9: return "32:9"
        case .ratio16x9: return "16:9"
        case .portrait: return t("aspect.portrait")
        }
    }
    var apiRatios: [String]? {
        switch self {
        case .ultrawide: return ["21x9", "32x9"]
        case .ratio21x9: return ["21x9"]
        case .ratio32x9: return ["32x9"]
        case .ratio16x9: return ["16x9"]
        case .portrait: return ["9x16", "10x16", "2x3", "3x4", "4x5"]
        default: return nil
        }
    }
    var apiAtleast: String? {
        self == .ultraHD ? "3840x2160" : nil
    }
}

private enum PurityFilter: String, CaseIterable, Identifiable {
    case sfw, sketchy, nsfw
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sfw: return "SFW"
        case .sketchy: return "Sketchy"
        case .nsfw: return "NSFW"
        }
    }
    var subtitle: String {
        switch self {
        case .sfw: return t("purity.sfw")
        case .sketchy: return t("purity.sketchy")
        case .nsfw: return t("purity.nsfw")
        }
    }
    var tint: Color {
        switch self {
        case .sfw: return LiquidGlassColors.onlineGreen
        case .sketchy: return LiquidGlassColors.warningOrange
        case .nsfw: return LiquidGlassColors.primaryPink
        }
    }
    var requiresAPIKey: Bool { self == .nsfw }
}

// MARK: - Filter Helpers

private extension WallpaperExploreContentView {
    var visiblePurityFilters: [PurityFilter] {
        if !viewModel.currentSourceSupportsNSFW { return [.sfw] }
        return viewModel.apiKeyConfigured ? Array(PurityFilter.allCases) : [.sfw, .sketchy]
    }

    var quickColorPresets: [WallhavenAPI.ColorPreset] {
        [
            "990000", "ea4c88", "993399", "0066cc", "0099cc", "66cccc",
            "669900", "999900", "ffff00", "ff9900", "ff6600", "424153"
        ].compactMap { WallhavenAPI.colorPreset(for: $0) }
    }

    var activeFilterChips: [FilterChipData] {
        var chips: [FilterChipData] = []
        if viewModel.currentSourceSupportsNSFW {
            if viewModel.puritySFW { chips.append(.init(kind: .purity(.sfw), title: "SFW", accentHex: "43C463")) }
            if viewModel.puritySketchy { chips.append(.init(kind: .purity(.sketchy), title: "Sketchy", accentHex: "FFB347")) }
            if viewModel.purityNSFW { chips.append(.init(kind: .purity(.nsfw), title: "NSFW", accentHex: "FF5A7D")) }
        }
        if let hex = viewModel.selectedColors.first,
           let preset = WallhavenAPI.colorPreset(for: hex) {
            chips.append(.init(kind: .color(hex), title: preset.displayHex, accentHex: hex))
        }
        return chips
    }

    func isPuritySelected(_ filter: PurityFilter) -> Bool {
        switch filter {
        case .sfw: return viewModel.puritySFW
        case .sketchy: return viewModel.puritySketchy
        case .nsfw: return viewModel.purityNSFW
        }
    }

    func togglePurity(_ filter: PurityFilter) {
        // Sketchy 和 NSFW 需要 API Key
        if filter.requiresAPIKey && !viewModel.apiKeyConfigured {
            // 使用异步触发 alert，避免阻塞当前点击事件处理
            DispatchQueue.main.async {
                showAPIKeyAlert = true
            }
            return
        }
        switch filter {
        case .sfw: viewModel.puritySFW.toggle()
        case .sketchy: viewModel.puritySketchy.toggle()
        case .nsfw: viewModel.purityNSFW.toggle()
        }
        reloadData()
    }

    func toggleColor(_ preset: WallhavenAPI.ColorPreset) {
        viewModel.selectedColors = (viewModel.selectedColors.first == preset.hex) ? [] : [preset.hex]
        reloadData()
    }

    func resetServerFilters() {
        viewModel.puritySFW = true
        viewModel.puritySketchy = false
        viewModel.purityNSFW = false
        viewModel.selectedColors = []
        reloadData()
    }

    func removeFilter(_ chip: FilterChipData) {
        switch chip.kind {
        case .purity(let purity):
            switch purity {
            case .sfw: viewModel.puritySFW = false
            case .sketchy: viewModel.puritySketchy = false
            case .nsfw: viewModel.purityNSFW = false
            }
        case .color: viewModel.selectedColors = []
        }
        reloadData()
    }
}

private struct FilterChipData: Identifiable {
    enum Kind: Hashable {
        case purity(PurityFilter)
        case color(String)
    }
    var id: String {
        switch kind {
        case .purity(let p): return "purity_\(p.rawValue)"
        case .color(let hex): return "color_\(hex)"
        }
    }
    let kind: Kind
    let title: String
    var subtitle: String? = nil
    let accentHex: String
}

// MARK: - Filter Chips

private struct ColorChip: View {
    let preset: WallhavenAPI.ColorPreset
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(hex: preset.displayHex))
                    .frame(width: 10, height: 10)
                    .overlay(Circle().stroke(Color.white.opacity(0.24), lineWidth: 0.6))
                Text(preset.displayHex)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(ArcBackgroundSettings.shared.primaryText.opacity(0.94))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(hex: preset.displayHex).opacity(isSelected ? 0.18 : 0.08))
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color(hex: preset.displayHex).opacity(isSelected ? 0.4 : 0.2), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(AppFluidMotion.hoverEase, value: isHovered)
        .onHover { isHovered = $0 }
    }
}

private struct ActiveFilterChip: View {
    let chip: FilterChipData
    let onRemove: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onRemove) {
            HStack(spacing: 8) {
                Circle().fill(Color(hex: "#\(chip.accentHex)")).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(chip.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(ArcBackgroundSettings.shared.primaryText.opacity(0.94))
                    if let subtitle = chip.subtitle {
                        Text(subtitle).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(ArcBackgroundSettings.shared.secondaryText.opacity(0.56))
                    }
                }
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(isHovered ? 0.95 : 0.72))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                ZStack {
                    Capsule(style: .continuous).fill(.ultraThinMaterial)
                    Capsule(style: .continuous).fill(Color(hex: "#\(chip.accentHex)").opacity(0.12))
                }
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color(hex: "#\(chip.accentHex)").opacity(0.3), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(AppFluidMotion.hoverEase, value: isHovered)
        .onHover { isHovered = $0 }
    }
}

// MARK: - 4K Category Chip

private struct FourKCategoryChip: View {
    let category: FourKCategory?
    let name: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    private var iconName: String { category?.icon ?? "sparkles" }
    private var gradientColors: [String] { category?.accentColors ?? ["FF9B58", "F54E42"] }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: gradientColors.map(Color.init(hex:)), startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 22, height: 22)
                    Image(systemName: iconName).font(.system(size: 10, weight: .bold)).foregroundStyle(isSelected ? .white : .black.opacity(0.78))
                }
                .overlay(Circle().stroke(Color.white.opacity(isSelected ? 0.18 : 0.08), lineWidth: 1))

                Text(name).font(.system(size: 13, weight: .semibold)).foregroundStyle(ArcBackgroundSettings.shared.primaryText.opacity(isSelected ? 0.96 : 0.84)).lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(
                ZStack {
                    Capsule(style: .continuous).fill(.ultraThinMaterial)
                    if let accentColor = gradientColors.first {
                        Capsule(style: .continuous).fill(Color(hex: accentColor).opacity(isSelected ? 0.15 : 0.08))
                    }
                }
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke((gradientColors.first.map { Color(hex: $0) } ?? Color(hex: "FF9B58")).opacity(isSelected ? 0.35 : 0.15), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered && !isSelected ? 1.02 : 1.0)
        .animation(AppFluidMotion.hoverEase, value: isHovered)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Extensions

extension SortingOption: CaseIterable, SortOptionProtocol, Identifiable {
    public static var allCases: [SortingOption] {
        [.toplist, .dateAdded, .favorites, .views, .random, .relevance]
    }

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .dateAdded: return t("sort.latest")
        case .views: return t("sort.views")
        case .favorites: return t("sort.likes")
        case .toplist: return t("sort.toplist")
        case .random: return t("sort.random")
        case .relevance: return t("sort.relevance")
        }
    }

    public var menuTitle: String { title }
}



// MARK: - FourKSortingOption Extension

extension FourKSortingOption: SortOptionProtocol {
    public var title: String { displayName }
    public var menuTitle: String { displayName }
}

// MARK: - KonachanSorting Extension

extension KonachanSorting: SortOptionProtocol {
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .dateAdded: return t("sort.latest")
        case .score: return t("sort.toplist")
        case .tagcount: return "Tags"
        case .landscape: return "Landscape"
        case .portrait: return "Portrait"
        case .random: return t("sort.random")
        case .mpixels: return "Resolution"
        }
    }

    public var menuTitle: String { title }
}
