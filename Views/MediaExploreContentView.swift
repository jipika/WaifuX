import SwiftUI
import AppKit
import Kingfisher
@preconcurrency import Translation

private struct MediaLoadMoreSentinelMinYPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = .greatestFiniteMagnitude

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next < value {
            value = next
        }
    }
}

private struct MediaExploreHeaderHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 {
            value = next
        }
    }
}

private final class MediaExploreScrollCoordinator: ObservableObject {
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

// MARK: - MediaExploreContentView - 媒体探索页

struct MediaExploreContentView: View {
    private static let scrollCoordinateSpaceName = "media-explore-scroll"
    private static let loadMoreTriggerThreshold: CGFloat = 120

    @ObservedObject var viewModel: MediaExploreViewModel
    @Binding var selectedMedia: MediaItem?
    var isVisible: Bool = true
    @StateObject private var exploreAtmosphere = ExploreAtmosphereController(wallpaperMode: false)
    @ObservedObject private var arcSettings = ArcBackgroundSettings.shared
    @ObservedObject private var workshopSourceManager = WorkshopSourceManager.shared
    // 注意：VideoWallpaperManager / WallpaperEngineXBridge 不在顶层观察。
    // 它们各有多个 @Published（isPaused/isMuted/volume 等），若顶层观察会导致
    // 视频壁纸暂停/恢复时整个媒体探索页 body 重算。
    // 仅 shouldUseLightweightEffects 依赖它们的播放状态，已下沉到
    // MediaExploreAtmosphereBackground 子视图内自行观察，只重建背景。
    @StateObject private var translationBridge = SearchTranslationBridge()
    @Environment(\.mainTopBarContentPadding) private var mainTopBarContentPadding

    @State private var selectedCategory: MediaCategory = .all
    @State private var selectedHotTag: MediaHotTag?
    @State private var selectedSort: MediaSortOption = .newest
    @State private var searchText = ""
    @State private var isLoadingMore = false
    @State private var isInitialLoading = false
    @State private var isFirstAppearance = true
    @State private var loadMoreFailed = false
    @State private var lastSyncedFirstItemID: String?
    @State private var isApplyingProgrammaticReset = false

    @State private var searchTask: Task<Void, Never>?
    @State private var loadMoreTask: Task<Void, Never>?
    /// loadMore 世代计数器，防止过期 task 覆盖较新 task 的引用或 UI 状态
    @State private var loadMoreGeneration: UInt = 0
    @State private var pendingSearchText: String?
    /// 翻译后的实际搜索词（英文），与 searchText（原始中文）分离
    @State private var mediaSearchQuery: String = ""
    /// loadMore 冷却期，防止 contentSize 增长 → isNearBottom 翻转 → 立即重试的无限级联。
    @State private var loadMoreCooldownUntil: Date? = nil
    @State private var measuredHeaderHeight: CGFloat = 0
    @State private var isHeaderContentMounted = true
    @StateObject private var scrollCoordinator = MediaExploreScrollCoordinator()
    // shouldUseLightweightEffects 已下沉到 MediaExploreAtmosphereBackground 子视图，
    // 该子视图自行观察 VideoWallpaperManager / WallpaperEngineXBridge 的播放状态。

    // Grid 控制
    @State private var showScrollToTop: Bool = false
    @State private var outerScrollToTopToken: Int = 0

    // Workshop 筛选
    @State private var selectedWorkshopTags: Set<WorkshopSourceManager.WorkshopTag> = []
    @State private var selectedWorkshopType: WorkshopSourceManager.WorkshopTypeFilter = .all
    @State private var selectedWorkshopContentLevel: WorkshopSourceManager.WorkshopContentLevel? = .everyone
    @State private var selectedWorkshopResolution: WorkshopSourceManager.WorkshopResolution? = nil
    @State private var selectedWorkshopSort: WorkshopSortOption = .trendWeek
    @State private var showWorkshopURLSheet = false
    @State private var workshopURLInput = ""
    @State private var isResolvingWorkshopURL = false
    @State private var workshopURLError: String?

    // Wallsflow 筛选
    @State private var selectedWallsflowCategorySlug: String = "live-wallpapers"

    // Dynamic Wallpaper (DongTai) 筛选
    @State private var selectedDongTaiCategories: Set<DynamicWallpaperCategory> = []
    @State private var selectedDongTaiListType: DynamicWallpaperListType = .all
    @State private var selectedDongTaiSort: DynamicWallpaperSortOption = .popular
    @State private var dongtaiFilterAudio: Bool? = nil
    @State private var dongtaiFilterFourK: Bool? = nil
    private var workshopService: WorkshopService {
        WorkshopService.shared
    }

    var body: some View {
        // 性能测量：开启 PERF_TRACE 编译标记后，会在控制台打印触发本 body 的属性来源
        #if PERF_TRACE
        let _ = Self._printChanges()
        #endif
        GeometryReader { geometry in
            let gridContentWidth = max(0, geometry.size.width - 56)

            ZStack {
                if arcSettings.compactMode {
                    arcSettings.compactBackground
                        .ignoresSafeArea()
                } else {
                    // 背景渲染下沉到独立子视图：它自行观察 VideoWallpaperManager /
                    // WallpaperEngineXBridge 的播放状态以决定 lightweight，
                    // 视频壁纸暂停/恢复只重建此背景，不触发整个媒体探索页 body 重算。
                    MediaExploreAtmosphereBackground(
                        tint: exploreAtmosphere.tint,
                        referenceImage: exploreAtmosphere.referenceImage,
                        isLightMode: arcSettings.isLightMode,
                        dotGridOpacity: arcSettings.dotGridOpacity,
                        grainIntensity: arcSettings.exploreGrainMedia
                    )
                    .ignoresSafeArea()
                }

                ZStack {
                    contentArea(
                        gridContentWidth: gridContentWidth,
                        fullWidth: geometry.size.width,
                        viewportHeight: geometry.size.height
                    )
                        .frame(width: geometry.size.width, alignment: .leading)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .environment(\.explorePageAtmosphereTint, exploreAtmosphere.tint)
                        .environment(\.arcIsLightMode, arcSettings.isLightMode)
                        .disabled(isInitialLoading)

                    bottomLoadingOverlay

                    scrollToTopButton
                }
            }
        }
        .sheet(isPresented: $showWorkshopURLSheet) {
            WorkshopURLInputSheet(
                urlInput: $workshopURLInput,
                errorMessage: workshopURLError,
                isLoading: isResolvingWorkshopURL,
                onSubmit: { handleWorkshopURLSubmit() },
                onDismiss: { showWorkshopURLSheet = false }
            )
        }
        .onAppear {
            if isFirstAppearance {
                Task { await performFirstAppearanceLoad() }
            } else {
                Task { await handleInitialLoad() }
            }
        }
        .onChange(of: isVisible) { _, visible in
            if !visible {
                cancelTasks()
                exploreAtmosphere.pause()
            } else {
                // 恢复可见时复位 isLoadingMore，防止之前 task 被取消后状态卡死
                isLoadingMore = false
                _ = viewModel.restoreExploreFeedIfNeededAfterDetailReturn()
                syncAtmosphereIfNeeded()
            }
        }
        .onChange(of: arcSettings.isLightMode) { _, _ in }
        .onChange(of: selectedHotTag) { _, _ in handleFilterChange() }
        .onChange(of: selectedWorkshopSort) { _, _ in handleWorkshopSortChange() }
        .onChange(of: selectedDongTaiSort) { _, _ in handleDongTaiSortChange() }
        .onChange(of: searchText) { _, newValue in
            translationBridge.detectLanguage(for: newValue)
            handleFilterChange()
        }
        .onReceive(translationBridge.$translationCompleted) { _ in
            handleTranslationCompleted()
        }
        .onChange(of: viewModel.isLoading) { _, newValue in
            if newValue {
                // 加载开始时自动刷新
            } else {
                syncAtmosphereIfNeeded()
            }
        }
        // ❌ 已移除 libraryContentRevision 的空 onChange，收藏状态改为视图直接读取
        // viewModel.favoriteIDSet，无需 @State 中间赋值引发 body 重算。
        .onChange(of: viewModel.items.count) { _, newCount in
            if newCount != 0 {
                // 数据从 0→N（切换源后新数据到达）时同步大气层背景
                syncAtmosphereIfNeeded()
            }
            if newCount > 60 { showScrollToTop = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .workshopSourceChanged)) { _ in
            handleSourceChange()
            invalidateHeaderMeasurement()
        }
        .onChange(of: headerLayoutSignature) { _, _ in
            invalidateHeaderMeasurement()
        }
    }

    @ViewBuilder
    private func contentArea(gridContentWidth: CGFloat, fullWidth: CGFloat, viewportHeight: CGFloat) -> some View {
        if viewModel.items.isEmpty {
            legacyScrollContent(gridContentWidth: gridContentWidth) {
                Group {
                    if isMediaLoadingState {
                        loadingState
                    } else {
                        emptyState
                    }
                }
                .transition(.opacity.animation(.easeInOut(duration: 0.3)))
            }
        } else {
            if #available(macOS 15.0, *) {
                scrollViewModern(gridContentWidth: gridContentWidth, fullWidth: fullWidth)
            } else {
                scrollViewLegacy(gridContentWidth: gridContentWidth, fullWidth: fullWidth, viewportHeight: viewportHeight)
            }
        }
    }

    // MARK: - macOS 15+：使用 onScrollGeometryChange

    @available(macOS 15.0, *)
    private func scrollViewModern(gridContentWidth: CGFloat, fullWidth: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear
                        .frame(height: 0)
                        .id("media-scroll-top")
                    headerStack
                    mediaGrid(contentWidth: gridContentWidth)
                }
                .padding(.horizontal, 28)
                .frame(width: fullWidth, alignment: .leading)
                .coordinateSpace(name: Self.scrollCoordinateSpaceName)
                // ⚡ macOS 15+ 路径不再使用 ScrollToTopHelper（NSScrollView KVO）。
                // header mount state / 滚动到顶都通过下方 onScrollGeometryChange + ScrollViewReader 实现，
                // 避免每帧 KVO 与 onScrollGeometryChange 重复触发同一个 handleScrollOffset 回调。
            }
            .onScrollGeometryChange(for: ScrollNearBottomState.self, of: { geometry in
                let bottomOffset = geometry.contentOffset.y + geometry.containerSize.height
                let distanceFromBottom = geometry.contentSize.height - bottomOffset
                guard distanceFromBottom.isFinite else {
                    return ScrollNearBottomState(isNearBottom: false)
                }
                return ScrollNearBottomState(
                    isNearBottom: distanceFromBottom <= Self.loadMoreTriggerThreshold
                )
            }, action: { oldValue, newValue in
                if newValue.isNearBottom && !oldValue.isNearBottom {
                    // ⛔ 冷却期内不触发 loadMore
                    if let cooldown = loadMoreCooldownUntil, Date() < cooldown { return }
                    guard !scrollCoordinator.wasNearBottom else { return }
                    scrollCoordinator.wasNearBottom = true
                    scheduleLoadMoreFromScroll()
                } else if !newValue.isNearBottom && oldValue.isNearBottom {
                    // ⚡ 延迟重置 wasNearBottom，给 contentSize 足够时间稳定
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                        scrollCoordinator.wasNearBottom = false
                    }
                }
            })
            .onScrollGeometryChange(for: CGFloat.self, of: { geometry in
                geometry.contentOffset.y
            }, action: { _, newOffset in
                handleScrollOffset(max(0, newOffset))
            })
            .scrollDisabled(!isVisible)
            .onChange(of: outerScrollToTopToken) { _, _ in
                withAnimation(nil) {
                    proxy.scrollTo("media-scroll-top", anchor: .top)
                }
            }
        }
    }

    // MARK: - macOS 14：使用 PreferenceKey

    private func scrollViewLegacy(gridContentWidth: CGFloat, fullWidth: CGFloat, viewportHeight: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear
                        .frame(height: 0)
                        .id("media-scroll-top")
                    headerStack
                    mediaGrid(contentWidth: gridContentWidth)
                    loadMoreSentinel
                }
                .padding(.horizontal, 28)
                .frame(width: fullWidth, alignment: .leading)
                .coordinateSpace(name: Self.scrollCoordinateSpaceName)
                .background(
                    ScrollToTopHelper(trigger: 0, onOffsetChange: handleScrollOffset)
                        .frame(width: 0, height: 0)
                )
            }
            .onPreferenceChange(MediaLoadMoreSentinelMinYPreferenceKey.self) { sentinelMinY in
                scrollCoordinator.sentinelDebounceTask?.cancel()
                let task = DispatchWorkItem {
                    handleLoadMoreSentinelPosition(sentinelMinY, viewportHeight: viewportHeight)
                }
                scrollCoordinator.sentinelDebounceTask = task
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: task)
            }
            .scrollDisabled(!isVisible)
            .onChange(of: outerScrollToTopToken) { _, _ in
                withAnimation(nil) {
                    proxy.scrollTo("media-scroll-top", anchor: .top)
                }
            }
        }
    }

    /// 仅用于"骨架/空状态"等无网格场景的兜底滚动容器（保留 header）
    private func legacyScrollContent<Content: View>(gridContentWidth: CGFloat, @ViewBuilder body: () -> Content) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                headerStack
                body()
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 48)
        }
        .scrollDisabled(!isVisible)
    }

    private var bottomLoadingOverlay: some View {
        VStack {
            Spacer()
            if loadMoreFailed {
                BottomLoadingFailedCard {
                    triggerLoadMore()
                }
                .padding(.bottom, 60)
            } else if isLoadingMore || (viewModel.isLoadingMore && !viewModel.items.isEmpty) || (viewModel.isLoading && !viewModel.items.isEmpty) {
                BottomLoadingCard(isLoading: true)
                    .padding(.bottom, 60)
            } else if !isLoadingMore && !viewModel.hasMorePages && !viewModel.items.isEmpty {
                BottomNoMoreCard()
                    .padding(.bottom, 60)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private var scrollToTopButton: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                if showScrollToTop {
                    ScrollToTopButton {
                        outerScrollToTopToken &+= 1
                    }
                    .padding(.trailing, 28)
                    .padding(.bottom, 120)
                    .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: showScrollToTop)
    }

    // MARK: - Header

    private var headerStack: some View {
        Group {
            if isHeaderContentMounted {
                headerContent
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: MediaExploreHeaderHeightPreferenceKey.self,
                                value: proxy.size.height
                            )
                        }
                    )
            } else {
                Color.clear
                    .frame(height: max(measuredHeaderHeight, 1))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onPreferenceChange(MediaExploreHeaderHeightPreferenceKey.self) { height in
            updateMeasuredHeaderHeight(height)
        }
    }

    private var headerContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            heroSection
            categorySection
            switch workshopSourceManager.activeSource {
            case .wallpaperEngine:
                filterSection
                workshopTagsSection
                activeFiltersSection
            case .dongtai:
                dongtaiFilterSection
                dongtaiActiveFiltersSection
            default:
                EmptyView()
            }
            contentHeader.padding(.top, 12)
        }
        .padding(.top, mainTopBarContentPadding)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .environment(\.explorePageAtmosphereTint, exploreAtmosphere.tint)
        .environment(\.arcIsLightMode, arcSettings.isLightMode)
    }

    private var headerLayoutSignature: String {
        [
            workshopSourceManager.activeSource.rawValue,
            selectedCategory.rawValue,
            selectedHotTag?.id ?? "none",
            selectedWorkshopType.id,
            selectedWorkshopContentLevel?.id ?? "none",
            selectedWorkshopResolution?.id ?? "none",
            selectedWorkshopTags.map(\.id).sorted().joined(separator: ","),
            selectedWallsflowCategorySlug,
            selectedDongTaiCategories.map(\.rawValue).sorted().joined(separator: ","),
            dongtaiFilterAudio.map(String.init) ?? "nil",
            dongtaiFilterFourK.map(String.init) ?? "nil"
        ].joined(separator: "|")
    }

    private func handleScrollOffset(_ offset: CGFloat) {
        updateHeaderMountState(scrollOffset: offset)
    }

    private func updateHeaderMountState(scrollOffset: CGFloat) {
        let headerHeight = measuredHeaderHeight > 1 ? measuredHeaderHeight : 260
        let hideThreshold = headerHeight + 80
        let showThreshold = max(0, headerHeight - 48)
        let shouldMount = isHeaderContentMounted
            ? scrollOffset < hideThreshold
            : scrollOffset < showThreshold

        guard shouldMount != isHeaderContentMounted else { return }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isHeaderContentMounted = shouldMount
        }
    }

    private func updateMeasuredHeaderHeight(_ height: CGFloat) {
        guard height > 1, abs(height - measuredHeaderHeight) > 1 else { return }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            measuredHeaderHeight = height
        }
    }

    private func invalidateHeaderMeasurement() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isHeaderContentMounted = true
            measuredHeaderHeight = 0
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
            if workshopSourceManager.activeSource != .wallpaperEngine && workshopSourceManager.activeSource != .dongtai {
                hotTagsRow
            }
        }
        .frame(maxWidth: 700, alignment: .leading)
    }

    private var headerTitle: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(greetingText)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(arcSettings.secondaryText.opacity(0.85))

                // 源切换 Menu（支持扩展更多源）
                Menu {
                    ForEach(WorkshopSourceManager.SourceType.allCases, id: \.self) { source in
                        Button {
                            workshopSourceManager.switchTo(source)
                        } label: {
                            HStack(spacing: 8) {
                                Text(source.displayName)
                                    .font(.system(size: 13, weight: .semibold))
                                if source == workshopSourceManager.activeSource {
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
                        Text(workshopSourceManager.activeSource.displayName)
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

            Text(t("exploreMedia"))
                .font(.system(size: 32, weight: .bold, design: .serif))
                .tracking(-0.5)
                .foregroundStyle(arcSettings.primaryText)
                .lineLimit(1)
        }
    }

    private var searchRow: some View {
        HStack(alignment: .center, spacing: 12) {
            ExploreSearchBar(
                text: $searchText,
                placeholder: t("search.placeholder"),
                tint: exploreAtmosphere.tint.primary,
                onSubmit: { submitSearch() },
                onClear: { searchText = ""; translationBridge.reset(); submitSearch(with: "") },
                translatedText: (workshopSourceManager.activeSource != .wallpaperEngine && workshopSourceManager.activeSource != .dongtai) ? translationBridge.translatedText : nil,
                isTranslating: (workshopSourceManager.activeSource != .wallpaperEngine && workshopSourceManager.activeSource != .dongtai) ? translationBridge.isTranslating : false,
                onDismissTranslation: (workshopSourceManager.activeSource != .wallpaperEngine && workshopSourceManager.activeSource != .dongtai) ? {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        translationBridge.dismiss()
                    }
                } : nil
            )

            WorkshopURLInputButton(tint: exploreAtmosphere.tint.primary) {
                showWorkshopURLSheet = true
            }

            if !arcSettings.compactMode {
                ArcBackgroundPanelButton(tint: exploreAtmosphere.tint.primary, grainIntensity: $arcSettings.exploreGrainMedia) {
                    randomizeAtmosphere()
                }
            }

            ResetFiltersButton(tint: exploreAtmosphere.tint.secondary) {
                resetAllFilters(reloadData: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var hotTagsRow: some View {
        motionBGTagsRow
    }

    private var motionBGTagsRow: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(t("hotWallpaper") + ":")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(arcSettings.secondaryText.opacity(0.4))

            ForEach(MediaHotTag.allCases) { tag in
                TagChip(
                    title: tag.title,
                    isSelected: selectedHotTag == tag
                ) {
                    withAnimation(AppFluidMotion.interactiveSpring) {
                        selectedHotTag = selectedHotTag == tag ? nil : tag
                    }
                }
            }
        }
    }

    private func applyWorkshopFilters(query: String? = nil) async {
        prepareForFeedReplacement()
        viewModel.clearItems()

        let tags = selectedWorkshopTags.map { $0.name }
        let searchQuery = query ?? viewModel.workshopSearchQuery
        await viewModel.loadWorkshopWithFilters(
            query: searchQuery,
            tags: tags,
            type: selectedWorkshopType,
            contentLevel: selectedWorkshopContentLevel,
            resolution: selectedWorkshopResolution?.tagValue
        )
    }

    @ViewBuilder
    private var categorySection: some View {
        switch workshopSourceManager.activeSource {
        case .wallpaperEngine:
            workshopTypeSection
        case .dongtai:
            dongtaiCategorySection
        case .wallsflow:
            wallsflowCategorySection
        default:
            FlowLayout(spacing: 12) {
                ForEach(MediaCategory.allCases) { category in
                    CategoryChip(
                        icon: category.icon,
                        title: category.title,
                        accentColors: category.accentColors,
                        isSelected: selectedCategory == category
                    ) {
                        selectCategory(category)
                    }
                }
            }
        }
    }

    private var workshopTypeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(t("categories"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(arcSettings.secondaryText.opacity(0.46))
            FlowLayout(spacing: 12) {
                ForEach(WorkshopSourceManager.WorkshopTypeFilter.allCases) { type in
                    CategoryChip(
                        icon: type.icon,
                        title: type.displayName,
                        accentColors: type.accentColors,
                        isSelected: selectedWorkshopType.id == type.id
                    ) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            selectedWorkshopType = type
                            Task { await applyWorkshopFilters() }
                        }
                    }
                }
                workshopResolutionMenu
            }
        }
    }

    private var workshopTagsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(t("tags"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(arcSettings.secondaryText.opacity(0.46))
            FlowLayout(spacing: 12) {
                ForEach(workshopSourceManager.availableTags) { tag in
                    CategoryChip(
                        icon: tag.icon,
                        title: tag.displayName,
                        accentColors: tag.accentColors,
                        isSelected: selectedWorkshopTags.contains(tag)
                    ) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            if selectedWorkshopTags.contains(tag) {
                                selectedWorkshopTags.remove(tag)
                            } else {
                                selectedWorkshopTags.insert(tag)
                            }
                            Task { await applyWorkshopFilters() }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var filterSection: some View {
        if workshopSourceManager.activeSource == .wallpaperEngine {
            VStack(alignment: .leading, spacing: 10) {
                Text(t("contentLevel"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(arcSettings.secondaryText.opacity(0.46))
                FlowLayout(spacing: 10) {
                    ForEach(visibleWorkshopContentLevels) { level in
                        FilterChip(
                            title: level.title,
                            subtitle: level.subtitle,
                            isSelected: selectedWorkshopContentLevel?.id == level.id,
                            tint: level.tint
                        ) {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                if selectedWorkshopContentLevel?.id == level.id {
                                    // 点击已选中项：回到默认 Everyone（不允许空选）
                                    selectedWorkshopContentLevel = .everyone
                                } else {
                                    selectedWorkshopContentLevel = level
                                }
                                Task { await applyWorkshopFilters() }
                            }
                        }
                    }
                }
            }
        }
    }

    private var workshopResolutionMenu: some View {
        Menu {
            Button(t("allResolutions")) {
                selectedWorkshopResolution = nil
                Task { await applyWorkshopFilters() }
            }
            Divider()
            ForEach(workshopSourceManager.availableResolutions) { res in
                let isSelected = selectedWorkshopResolution?.id == res.id
                Button {
                    selectedWorkshopResolution = isSelected ? nil : res
                    Task { await applyWorkshopFilters() }
                } label: {
                    HStack {
                        Text(res.display)
                        if isSelected { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            let hasResolution = selectedWorkshopResolution != nil
            HStack(spacing: 6) {
                Image(systemName: "aspectratio").font(.system(size: 11, weight: .semibold))
                Text(hasResolution ? (selectedWorkshopResolution?.display ?? "") : t("resolution"))
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(hasResolution ? arcSettings.primaryText.opacity(0.95) : arcSettings.secondaryText.opacity(0.7))
            .padding(.horizontal, 12)
            .frame(height: 34)
            .exploreFrostedCapsule(
                tint: exploreAtmosphere.tint.primary,
                material: hasResolution ? .regularMaterial : .ultraThinMaterial,
                tintLayerOpacity: hasResolution ? 0.1 : 0.03
            )
        }
        .menuStyle(.borderlessButton)
        .offset(y: 1)
        .frame(height: 34)
    }

    private var visibleWorkshopContentLevels: [WorkshopSourceManager.WorkshopContentLevel] {
        if workshopSourceManager.isSteamAuthenticated && UserDefaults.standard.bool(forKey: "show_all_workshop_content") {
            [.everyone, .questionable, .mature]
        } else {
            [.everyone, .questionable]
        }
    }

    @ViewBuilder
    private var activeFiltersSection: some View {
        if workshopSourceManager.activeSource == .wallpaperEngine {
            let chips = workshopActiveFilterChips
            if !chips.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Text(t("currentFilters"))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(arcSettings.secondaryText.opacity(0.46))
                        Button(t("clear")) {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                selectedWorkshopTags = []
                                selectedWorkshopContentLevel = .everyone
                                selectedWorkshopType = .all
                                selectedWorkshopResolution = nil
                                Task { await applyWorkshopFilters() }
                            }
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(arcSettings.secondaryText.opacity(0.72))
                        .buttonStyle(.plain)
                    }
                    FlowLayout(spacing: 10) {
                        ForEach(chips) { chip in
                            WorkshopActiveFilterChip(
                                title: chip.title,
                                accentHex: chip.accentHex
                            ) {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    removeWorkshopFilter(chip)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private struct WorkshopFilterChipData: Identifiable {
        let id: String
        let title: String
        let accentHex: String
        let kind: Kind
        enum Kind { case type, tag, level, resolution }
    }

    private var workshopActiveFilterChips: [WorkshopFilterChipData] {
        var chips: [WorkshopFilterChipData] = []
        if selectedWorkshopType != .all {
            chips.append(WorkshopFilterChipData(
                id: "type_\(selectedWorkshopType.id)",
                title: selectedWorkshopType.displayName,
                accentHex: selectedWorkshopType.accentColors.first ?? "FFFFFF",
                kind: .type
            ))
        }
        for tag in selectedWorkshopTags {
            chips.append(WorkshopFilterChipData(
                id: "tag_\(tag.id)",
                title: tag.displayName,
                accentHex: tag.accentColors.first ?? "FFFFFF",
                kind: .tag
            ))
        }
        if let level = selectedWorkshopContentLevel, level != .everyone {
            chips.append(WorkshopFilterChipData(
                id: "level_\(level.id)",
                title: level.title,
                accentHex: level.accentHex,
                kind: .level
            ))
        }
        if let res = selectedWorkshopResolution {
            chips.append(WorkshopFilterChipData(
                id: "res_\(res.id)",
                title: res.display,
                accentHex: "3A86FF",
                kind: .resolution
            ))
        }
        return chips
    }

    private func removeWorkshopFilter(_ chip: WorkshopFilterChipData) {
        switch chip.kind {
        case .type:
            selectedWorkshopType = .all
        case .tag:
            let tagId = chip.id.replacingOccurrences(of: "tag_", with: "")
            selectedWorkshopTags = selectedWorkshopTags.filter { $0.id != tagId }
        case .level:
            selectedWorkshopContentLevel = .everyone
        case .resolution:
            selectedWorkshopResolution = nil
        }
        Task { await applyWorkshopFilters() }
    }

    // MARK: - Wallsflow 分类

    private var wallsflowCategorySection: some View {
        FlowLayout(spacing: 12) {
            // "全部"选项
            CategoryChip(
                icon: "square.grid.2x2",
                title: t("filter.all"),
                accentColors: ["9B5DE5", "F15BB5"],
                isSelected: selectedWallsflowCategorySlug == "live-wallpapers"
            ) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    selectedWallsflowCategorySlug = "live-wallpapers"
                    Task { await applyWallsflowCategory(slug: "live-wallpapers") }
                }
            }
            // Wallsflow 分类（排除 "live-wallpapers" 顶层分类，只显示子分类）
            ForEach(WallsflowCategory.allCategories.filter { $0.slug != "live-wallpapers" }, id: \.slug) { category in
                CategoryChip(
                    icon: wallsflowCategoryIcon(for: category.slug),
                    title: wallsflowCategoryDisplayName(for: category.slug),
                    accentColors: wallsflowCategoryColors(for: category.slug),
                    isSelected: selectedWallsflowCategorySlug == category.slug
                ) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        selectedWallsflowCategorySlug = category.slug
                        Task { await applyWallsflowCategory(slug: category.slug) }
                    }
                }
            }
        }
    }

    private func wallsflowCategoryDisplayName(for slug: String) -> String {
        let key = "wallsflow.category.\(slug)"
        let localized = t(key)
        // 如果本地化键不存在，t() 返回 key 本身，此时回退到英文名
        if localized == key {
            // fallback: 从 WallsflowCategory 取英文名并去掉 " Live Wallpapers" 后缀
            if let category = WallsflowCategory.allCategories.first(where: { $0.slug == slug }) {
                return category.name.replacingOccurrences(of: " Live Wallpapers", with: "")
            }
            return slug
        }
        return localized
    }

    private func wallsflowCategoryIcon(for slug: String) -> String {
        switch slug {
        case "anime": return "sparkles"
        case "games": return "gamecontroller.fill"
        case "cars": return "car.fill"
        case "nature": return "leaf.fill"
        case "space": return "moon.fill"
        case "animals": return "pawprint.fill"
        case "winter": return "snowflake"
        case "minimalist": return "circle.fill"
        case "pixel-art": return "square.grid.2x2"
        case "movies": return "film.fill"
        case "people": return "person.fill"
        case "graphics": return "paintpalette.fill"
        default: return "photo.fill"
        }
    }

    private func wallsflowCategoryColors(for slug: String) -> [String] {
        switch slug {
        case "anime": return ["FF5E98", "FF9A5B"]
        case "games": return ["FFBE0B", "FB5607"]
        case "cars": return ["E71D36", "FF9F1C"]
        case "nature": return ["00F5D4", "01BE96"]
        case "space": return ["3A86FF", "00BBF9"]
        case "animals": return ["A8E6CF", "1A936F"]
        case "winter": return ["A8DADC", "457B9D"]
        case "minimalist": return ["D4A373", "BC6C25"]
        case "pixel-art": return ["FF006E", "8338EC"]
        case "movies": return ["E71D36", "FF9F1C"]
        case "people": return ["FF5E98", "FF9A5B"]
        case "graphics": return ["9B5DE5", "F15BB5"]
        default: return ["9B5DE5", "F15BB5"]
        }
    }

    /// 应用 Wallsflow 分类筛选
    private func applyWallsflowCategory(slug: String) async {
        prepareForFeedReplacement()
        viewModel.isLoading = false
        viewModel.clearItems()
        await viewModel.loadWallsflowCategory(slug: slug)
        syncAtmosphereIfNeeded()
    }

    // MARK: - DongTai 分类

    private var dongtaiCategorySection: some View {
        FlowLayout(spacing: 12) {
            // 列表类型切换（隐藏普通视频选项）
            ForEach(DynamicWallpaperListType.allCases.filter { $0 != .collection }) { listType in
                CategoryChip(
                    icon: listTypeIcon(listType),
                    title: listType.displayName,
                    accentColors: ["FF5E98", "FF9A5B"],
                    isSelected: selectedDongTaiListType == listType
                ) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        selectedDongTaiListType = listType
                        Task { await applyDongTaiFilters() }
                    }
                }
            }
            // 分类标签
            ForEach(DynamicWallpaperCategory.allCases) { category in
                CategoryChip(
                    icon: category.icon,
                    title: category.title,
                    accentColors: category.accentColors,
                    isSelected: selectedDongTaiCategories.contains(category)
                ) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        if selectedDongTaiCategories.contains(category) {
                            selectedDongTaiCategories.remove(category)
                        } else {
                            selectedDongTaiCategories.insert(category)
                        }
                        Task { await applyDongTaiFilters() }
                    }
                }
            }
        }
    }

    private func listTypeIcon(_ type: DynamicWallpaperListType) -> String {
        switch type {
        case .all: return "square.grid.2x2"
        case .collection: return "film.stack.fill"
        case .exclusive: return "star.fill"
        }
    }

    // MARK: - DongTai 筛选区

    @ViewBuilder
    private var dongtaiFilterSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(t("dongtai.filters"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(arcSettings.secondaryText.opacity(0.46))
            FlowLayout(spacing: 10) {
                // 音频筛选
                dongtaiAudioFilterChip
                // 4K 筛选
                dongtaiFourKFilterChip
            }
        }
    }

    private var dongtaiAudioFilterChip: some View {
        FilterChip(
            title: t("dongtai.filter.hasAudio"),
            subtitle: "",
            isSelected: dongtaiFilterAudio == true,
            tint: LiquidGlassColors.onlineGreen
        ) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                if dongtaiFilterAudio == true {
                    dongtaiFilterAudio = nil
                } else {
                    dongtaiFilterAudio = true
                    dongtaiFilterFourK = nil // 互斥，便于 UI 清晰
                }
                Task { await applyDongTaiFilters() }
            }
        }
    }

    private var dongtaiFourKFilterChip: some View {
        FilterChip(
            title: t("dongtai.filter.fourK"),
            subtitle: "",
            isSelected: dongtaiFilterFourK == true,
            tint: LiquidGlassColors.primaryPink
        ) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                if dongtaiFilterFourK == true {
                    dongtaiFilterFourK = nil
                } else {
                    dongtaiFilterFourK = true
                    dongtaiFilterAudio = nil // 互斥
                }
                Task { await applyDongTaiFilters() }
            }
        }
    }

    // MARK: - DongTai 活跃筛选标签

    @ViewBuilder
    private var dongtaiActiveFiltersSection: some View {
        let chips = dongtaiActiveFilterChips
        if !chips.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Text(t("currentFilters"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(arcSettings.secondaryText.opacity(0.46))
                    Button(t("clear")) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            selectedDongTaiCategories = []
                            selectedDongTaiListType = .all
                            dongtaiFilterAudio = nil
                            dongtaiFilterFourK = nil
                            Task { await applyDongTaiFilters() }
                        }
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(arcSettings.secondaryText.opacity(0.72))
                    .buttonStyle(.plain)
                }
                FlowLayout(spacing: 10) {
                    ForEach(chips) { chip in
                        WorkshopActiveFilterChip(
                            title: chip.title,
                            accentHex: chip.accentHex
                        ) {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                removeDongTaiFilter(chip)
                            }
                        }
                    }
                }
            }
        }
    }

    private struct DongTaiFilterChipData: Identifiable {
        let id: String
        let title: String
        let accentHex: String
        let kind: Kind
        enum Kind { case category, listType, audio, fourK }
    }

    private var dongtaiActiveFilterChips: [DongTaiFilterChipData] {
        var chips: [DongTaiFilterChipData] = []
        if selectedDongTaiListType != .all {
            chips.append(DongTaiFilterChipData(
                id: "list_\(selectedDongTaiListType.id)",
                title: selectedDongTaiListType.displayName,
                accentHex: "FF5E98",
                kind: .listType
            ))
        }
        for cat in selectedDongTaiCategories {
            chips.append(DongTaiFilterChipData(
                id: "cat_\(cat.rawValue)",
                title: cat.title,
                accentHex: cat.accentColors.first ?? "FFFFFF",
                kind: .category
            ))
        }
        if dongtaiFilterAudio == true {
            chips.append(DongTaiFilterChipData(
                id: "audio",
                title: t("dongtai.filter.hasAudio"),
                accentHex: "43C463",
                kind: .audio
            ))
        }
        if dongtaiFilterFourK == true {
            chips.append(DongTaiFilterChipData(
                id: "fourk",
                title: t("dongtai.filter.fourK"),
                accentHex: "FF5A7D",
                kind: .fourK
            ))
        }
        return chips
    }

    private func removeDongTaiFilter(_ chip: DongTaiFilterChipData) {
        switch chip.kind {
        case .category:
            let catId = chip.id.replacingOccurrences(of: "cat_", with: "")
            selectedDongTaiCategories = selectedDongTaiCategories.filter { $0.rawValue != catId }
        case .listType:
            selectedDongTaiListType = .all
        case .audio:
            dongtaiFilterAudio = nil
        case .fourK:
            dongtaiFilterFourK = nil
        }
        Task { await applyDongTaiFilters() }
    }

    /// 应用 DongTai 筛选（组合全部活跃筛选条件）
    private func applyDongTaiFilters(query: String? = nil) async {
        prepareForFeedReplacement()
        // 先重置 isLoading 避免被 loadDongTaiFeedInternal 的 guard 阻塞
        viewModel.isLoading = false
        viewModel.clearItems()

        let searchQuery = query ?? searchText
        let dongtaiQuery = workshopSourceManager.activeSource == .dongtai ? searchQuery : ""

        // 同步筛选状态到 ViewModel 并组合全部条件
        await viewModel.loadDongTaiWithAllFilters(
            query: dongtaiQuery,
            categories: selectedDongTaiCategories,
            listType: selectedDongTaiListType,
            sortBy: selectedDongTaiSort,
            hasAudio: dongtaiFilterAudio,
            isFourK: dongtaiFilterFourK
        )

        // 强制刷新网格：DongTai 查询为同步操作，isLoading 变化太快，
        // SwiftUI 的 .onChange(of: viewModel.isLoading) 无法捕捉到中间状态，
        // 此处显式通知网格重新加载
        syncAtmosphereIfNeeded()

    }

    private var contentHeader: some View {
        HStack(alignment: .center) {
            Text("\(formattedCount(viewModel.items.count)) \(t("media.count")) · \(t("media.loaded")) \(formattedCount(viewModel.items.count))")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(arcSettings.secondaryText.opacity(0.64))

            Spacer()

            switch workshopSourceManager.activeSource {
            case .wallpaperEngine:
                SortMenu(options: WorkshopSortOption.allCases, selected: $selectedWorkshopSort, tint: exploreAtmosphere.tint.primary)
            case .dongtai:
                SortMenu(options: DynamicWallpaperSortOption.allCases, selected: $selectedDongTaiSort, tint: exploreAtmosphere.tint.primary)
            default:
                EmptyView()
            }
        }
    }

    // MARK: - Grid

    private func mediaGrid(contentWidth: CGFloat) -> some View {
        let spacing: CGFloat = ExploreGridLayout.spacing
        let columnCount = ExploreGridLayout.columnCount(for: contentWidth)
        let totalSpacing = spacing * CGFloat(columnCount - 1)
        let cardWidth = max(1, floor((contentWidth - totalSpacing) / CGFloat(columnCount)))
        let cardHeight = Self.uniformMediaCardHeight(cardWidth: cardWidth)
        let columns = Array(
            repeating: GridItem(.fixed(cardWidth), spacing: spacing, alignment: .topLeading),
            count: max(1, columnCount)
        )

        return LazyVGrid(columns: columns, alignment: .leading, spacing: spacing) {
            ForEach(viewModel.items) { media in
                MediaCardView(
                    media: media,
                    // ✅ 直接读取 viewModel.favoriteIDSet，O(1) 判断
                    isFavorite: viewModel.favoriteIDSet.contains(media.id),
                    cardWidth: cardWidth,
                    forcedHeight: cardHeight
                ) {
                    viewModel.preserveExploreFeedForDetailNavigation()
                    selectedMedia = media
                }
                .equatable()
                .frame(width: cardWidth, height: cardHeight)
            }
        }
    }

    /// 媒体网格的统一卡片高度（LazyVGrid 模式：所有卡片同样高度，避免瀑布流的高度抖动与
    /// 多列 LazyVStack 在 macOS 上的协调开销）。
    private static func uniformMediaCardHeight(cardWidth: CGFloat) -> CGFloat {
        let bottomBarHeight: CGFloat = 44
        // 16:10 是动态壁纸/桌面壁纸常见的视觉比例，在大多数媒体源里都是合适的中位数。
        let imageHeight = cardWidth / (16.0 / 10.0)
        return imageHeight + bottomBarHeight
    }

    /// 旧 API：保留以兼容外部潜在调用，内部已不再使用。
    private static func mediaCardHeight(cardWidth: CGFloat, media: MediaItem) -> CGFloat {
        return uniformMediaCardHeight(cardWidth: cardWidth)
    }

    // MARK: - UI Components

    private func smartRetry() async {
        let query = viewModel.currentQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            await viewModel.searchFeed(query: query)
        } else {
            await viewModel.initialLoadIfNeeded()
        }
    }

    private var emptyState: some View {
        Group {
            if let errorMessage = viewModel.errorMessage {
                ErrorStateView(
                    type: viewModel.networkStatus.connectionState == .offline ? .offline : .network,
                    message: errorMessage,
                    retryAction: { Task { await smartRetry() } }
                )
            } else {
                ErrorStateView(
                    type: .empty,
                    title: t("noMediaFilter"),
                    message: t("tryDifferentFilter"),
                    retryAction: { Task { await smartRetry() } }
                )
            }
        }
        .frame(height: 220)
        .exploreFrostedPanel(cornerRadius: 28, tint: exploreAtmosphere.tint.primary)
    }

    private var loadingState: some View {
        ExploreLoadingStateView(
            message: "加载中...",
            tint: arcSettings.primaryText
        )
        .exploreFrostedPanel(cornerRadius: 28, tint: exploreAtmosphere.tint.primary)
    }

    private var isMediaLoadingState: Bool {
        viewModel.items.isEmpty && (
            isInitialLoading
            || isFirstAppearance
            || viewModel.isLoading
            || viewModel.isLoadingMore
            || searchTask != nil
        )
    }

    private var loadMoreSentinel: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: MediaLoadMoreSentinelMinYPreferenceKey.self,
                value: proxy.frame(in: .named(Self.scrollCoordinateSpaceName)).minY
            )
        }
        .frame(height: 1)
    }

    // MARK: - Actions

    private func handleInitialLoad() async {

        let restoredFeed = viewModel.restoreExploreFeedIfNeededAfterDetailReturn()
        if viewModel.items.isEmpty {
            isInitialLoading = true
        }
        if !restoredFeed {
            await viewModel.initialLoadIfNeeded()
        }
        if searchText.isEmpty {
            searchText = viewModel.currentQuery
        }
        syncAtmosphereIfNeeded()
        isInitialLoading = false
    }

    private func performFirstAppearanceLoad() async {
        // ⚠️ 防止 NavigationStack pop 后视图被重建导致丢失已加载的多页数据
        guard viewModel.items.isEmpty else {
            isFirstAppearance = false
            return
        }

        isInitialLoading = true
        searchText = ""
        mediaSearchQuery = ""
        translationBridge.reset()
        selectedHotTag = nil
        selectedWorkshopTags = []
        selectedWorkshopType = .all
        selectedWorkshopContentLevel = .everyone
        selectedWorkshopResolution = nil
        selectedWorkshopSort = .trendWeek
        selectedCategory = .all
        selectedSort = .newest
        lastSyncedFirstItemID = nil
        loadMoreFailed = false
        viewModel.errorMessage = nil

        await viewModel.initialLoadIfNeeded()

        syncAtmosphereIfNeeded()
        isInitialLoading = false
        isFirstAppearance = false
    }

    private func selectCategory(_ category: MediaCategory) {
        prepareForFeedReplacement()
        withAnimation(AppFluidMotion.interactiveSpring) {
            selectedCategory = category
            selectedHotTag = nil
            selectedWorkshopTags = []
            selectedWorkshopType = .all
            selectedWorkshopContentLevel = .everyone
            searchText = ""
        }

        lastSyncedFirstItemID = nil
        // 清空 ViewModel 数据避免显示旧数据
        viewModel.clearItems()

        searchTask?.cancel()
        viewModel.isLoading = false
        searchTask = Task { @MainActor in
            defer { searchTask = nil }
            switch workshopSourceManager.activeSource {
            case .wallpaperEngine:
                await viewModel.loadWorkshopFeed()
            case .dongtai:
                await viewModel.loadDongTaiFeed()
            case .wallsflow:
                await viewModel.loadWallsflowFeed()
            default:
                if category == .all {
                    await viewModel.loadHomeFeed()
                } else {
                    await viewModel.loadTagFeed(slug: category.slug, title: category.title)
                }
            }
        }
    }

    private func submitSearch(with query: String? = nil) {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        // BG 源：中文翻译处理（仅在无外部 query 时触发）
        let isMotionBG = workshopSourceManager.activeSource != .wallpaperEngine && workshopSourceManager.activeSource != .dongtai && workshopSourceManager.activeSource != .wallsflow
        if query == nil && isMotionBG && !trimmed.isEmpty {
            let chineseDetected = translationBridge.isChinese(trimmed)
            let needsTranslation = chineseDetected
                && !translationBridge.translationDismissed
                && (translationBridge.translatedText == nil || translationBridge.translatedSourceText != trimmed)

            if needsTranslation {
                pendingSearchText = trimmed
                if translationBridge.checkCache(for: trimmed) {
                    pendingSearchText = nil
                    let effectiveQuery = translationBridge.effectiveQuery(for: trimmed)
                    mediaSearchQuery = effectiveQuery
                    executeSearch(query: effectiveQuery)
                    return
                }
                translationBridge.prepareForTranslation(trimmed)
                translationBridge.triggerTranslation()
                return
            }
        }

        let searchQuery = query ?? translationBridge.effectiveQuery(for: trimmed)
        if query != nil { searchText = "" }
        mediaSearchQuery = searchQuery
        pendingSearchText = nil
        executeSearch(query: searchQuery)
    }

    private func executeSearch(query: String) {
        prepareForFeedReplacement()
        selectedCategory = .all
        selectedHotTag = nil
        searchTask?.cancel()
        viewModel.isLoading = false
        searchTask = Task { @MainActor in
            defer {
                searchTask = nil
                syncAtmosphereIfNeeded()

            }
            switch workshopSourceManager.activeSource {
            case .wallpaperEngine:
                await applyWorkshopFilters(query: query)
            case .dongtai:
                await viewModel.searchDongTai(query: query)
            case .wallsflow:
                await viewModel.searchWallsflow(query: query)
            default:
                await viewModel.search(query: query)
            }
        }
    }

    private func handleTranslationCompleted() {
        guard workshopSourceManager.activeSource != .wallpaperEngine,
              workshopSourceManager.activeSource != .dongtai,
              workshopSourceManager.activeSource != .wallsflow else { return }
        guard let pending = pendingSearchText else { return }
        pendingSearchText = nil
        let query = translationBridge.effectiveQuery(for: pending)
        mediaSearchQuery = query
        executeSearch(query: query)
    }

    private func handleFilterChange() {
        guard !isApplyingProgrammaticReset else { return }

        // Workshop/DongTai/Wallsflow 模式下不支持标签过滤
        if workshopSourceManager.activeSource == .wallpaperEngine || workshopSourceManager.activeSource == .dongtai || workshopSourceManager.activeSource == .wallsflow {
            syncAtmosphereIfNeeded()
            return
        }

        if let hotTag = selectedHotTag, hotTag.isServerSide,
           let slug = hotTag.serverSlug {
            prepareForFeedReplacement()
            Task {
                await viewModel.loadTagFeed(slug: slug, title: hotTag.title)
            }
            return
        }

        if selectedHotTag != nil && viewModel.items.isEmpty {
            Task {
                prepareForFeedReplacement()
                await viewModel.loadHomeFeed()
                await MainActor.run {
                    syncAtmosphereIfNeeded()
                }
            }
            return
        }

        syncAtmosphereIfNeeded()
    }

    private func handleWorkshopSortChange() {
        guard !isApplyingProgrammaticReset else { return }

        AppLogger.info(.wallpaper, "Workshop 排序变化", metadata: ["排序": selectedWorkshopSort.rawValue])
        // 仅在 Workshop 模式下实际重载数据；MotionBG 下仅更新 UI 不触发加载
        guard workshopSourceManager.activeSource == .wallpaperEngine else { return }
        prepareForFeedReplacement()
        searchTask?.cancel()
        viewModel.isLoading = false
        searchTask = Task { @MainActor in
            defer { searchTask = nil }
            await viewModel.setWorkshopSort(
                sortBy: selectedWorkshopSort.sortBy,
                days: selectedWorkshopSort.days
            )
        }
    }

    private func handleDongTaiSortChange() {
        guard !isApplyingProgrammaticReset else { return }

        guard workshopSourceManager.activeSource == .dongtai else { return }
        prepareForFeedReplacement()
        searchTask?.cancel()
        viewModel.isLoading = false
        searchTask = Task { @MainActor in
            defer {
                searchTask = nil
                // 强制刷新网格（DongTai 查询为同步操作）
                syncAtmosphereIfNeeded()

            }
            await viewModel.setDongTaiSort(sortBy: selectedDongTaiSort)
        }
    }

    private func handleSourceChange() {
        // 仅重置 UI 筛选状态，不触发数据加载——加载由 ViewModel.$activeSource sink 统一负责
        resetAllFilters(reloadData: false)
    }

    private func handleWorkshopURLSubmit() {
        let url = workshopURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else {
            workshopURLError = "请输入链接"
            return
        }
        isResolvingWorkshopURL = true
        workshopURLError = nil
        Task {
            do {
                let isWE = WorkshopService.extractWorkshopID(from: url) != nil
                let isDongTai = DynamicWallpaperService.shared.canHandleOSSURL(url)
                let item: MediaItem
                if isWE {
                    item = try await viewModel.resolveWorkshopItemByURL(url)
                } else if isDongTai {
                    item = try await viewModel.resolveDongTaiItemByURL(url)
                } else {
                    item = try await viewModel.resolveMotionBGItemByURL(url)
                }
                await MainActor.run {
                    isResolvingWorkshopURL = false
                    showWorkshopURLSheet = false
                    workshopURLInput = ""
                    viewModel.preserveExploreFeedForDetailNavigation()
                    selectedMedia = item
                }
            } catch {
                await MainActor.run {
                    isResolvingWorkshopURL = false
                    workshopURLError = error.localizedDescription
                }
            }
        }
    }

    private func triggerLoadMore() {
        guard viewModel.hasMorePages,
              !viewModel.isLoading,
              !isLoadingMore,
              !viewModel.isLoadingMore else { return }

        // ⛔ 冷却期内不触发 loadMore（防止 contentSize 增长后的无限级联）
        if let cooldown = loadMoreCooldownUntil, Date() < cooldown { return }

        isLoadingMore = true
        loadMoreFailed = false
        loadMoreTask?.cancel()
        let generation = loadMoreGeneration
        loadMoreGeneration &+= 1
        loadMoreTask = Task { [generation] in
            await viewModel.loadMoreFeed()
            await MainActor.run {
                // 只有最新的 task 才能更新 UI：generation 被捕获后 loadMoreGeneration 已 +1，
                // 若期间有新 task 创建则 loadMoreGeneration 会继续 +1，此时 guard 不成立跳过
                guard loadMoreGeneration == generation + 1 else { return }
                if viewModel.hasMorePages && viewModel.errorMessage != nil {
                    loadMoreFailed = true
                }
                // ⚡ 设置 1.5s 冷却期 + 0.5s 延迟释放 isLoadingMore，双重防护
                loadMoreCooldownUntil = Date().addingTimeInterval(1.5)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    isLoadingMore = false
                }
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
        let isNearBottom = sentinelMinY <= viewportHeight + Self.loadMoreTriggerThreshold
        if isNearBottom {
            // ⛔ 冷却期内不触发 loadMore
            if let cooldown = loadMoreCooldownUntil, Date() < cooldown { return }
            guard !scrollCoordinator.wasNearBottom else { return }
            scrollCoordinator.wasNearBottom = true
            scheduleLoadMoreFromScroll()
        } else {
            // ⚡ 延迟重置 wasNearBottom，给 contentSize 足够时间稳定
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                scrollCoordinator.wasNearBottom = false
            }
        }
    }

    private func resetAllFilters(reloadData: Bool = false) {
        isApplyingProgrammaticReset = true
        searchText = ""
        mediaSearchQuery = ""
        translationBridge.reset()
        selectedHotTag = nil
        selectedWorkshopTags = []
        selectedWorkshopType = .all
        selectedWorkshopContentLevel = .everyone
        selectedWorkshopResolution = nil
        selectedWorkshopSort = .trendWeek
        selectedDongTaiCategories = []
        selectedDongTaiListType = .all
        selectedDongTaiSort = .popular
        dongtaiFilterAudio = nil
        dongtaiFilterFourK = nil
        selectedWallsflowCategorySlug = "live-wallpapers"
        selectedCategory = .all
        selectedSort = .newest
        lastSyncedFirstItemID = nil
        loadMoreFailed = false
        viewModel.errorMessage = nil
        prepareForFeedReplacement()

        if reloadData {
            reloadDefaultFeedAfterReset()
        } else {
            Task { @MainActor in
                await Task.yield()
                isApplyingProgrammaticReset = false
            }
        }
    }

    private func reloadDefaultFeedAfterReset() {
        searchTask?.cancel()
        loadMoreTask?.cancel()

        pendingSearchText = nil
        isLoadingMore = false
        isInitialLoading = viewModel.items.isEmpty

        searchTask = Task { @MainActor in
            defer {
                isInitialLoading = false
                isApplyingProgrammaticReset = false
                searchTask = nil
            }

            await viewModel.resetAndLoadDefaultFeed()

            syncAtmosphereIfNeeded()

        }
    }

    private func prepareForFeedReplacement() {
        loadMoreTask?.cancel()
        scrollCoordinator.cancelPendingWork()
        isLoadingMore = false
        loadMoreFailed = false
        showScrollToTop = false
        outerScrollToTopToken &+= 1
    }

    private func cancelTasks() {
        searchTask?.cancel()
        loadMoreTask?.cancel()
        scrollCoordinator.cancelPendingWork()

        searchTask = nil
        loadMoreTask = nil
        isLoadingMore = false
    }

    private func syncAtmosphereIfNeeded() {
        let items = viewModel.items
        let newFirstID = items.first?.id
        guard newFirstID != lastSyncedFirstItemID else { return }
        lastSyncedFirstItemID = newFirstID
        DispatchQueue.main.async {
            guard lastSyncedFirstItemID == newFirstID else { return }
            exploreAtmosphere.updateFirstMedia(items.first)
        }
    }

    private func randomizeAtmosphere() {
        guard !viewModel.items.isEmpty else { return }
        let random = viewModel.items.randomElement()!
        exploreAtmosphere.updateFromImageURL(
            random.coverImageURL,
            keyPrefix: "rand-media"
        )
    }

    private func formattedCount(_ count: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal)
    }

}

private func formatCompactCount(_ count: Int) -> String {
    if count >= 1_000_000 {
        return String(format: "%.1fM", Double(count) / 1_000_000)
    } else if count >= 1_000 {
        return String(format: "%.1fK", Double(count) / 1_000)
    }
    return "\(count)"
}

// MARK: - Models & Enums

private enum MediaSortOption: String, CaseIterable, SortOptionProtocol {
    case newest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newest: return t("sort.newest")
        }
    }

    var menuTitle: String {
        switch self {
        case .newest: return t("sortByNewest")
        }
    }
}

private enum MediaHotTag: String, CaseIterable, Identifiable {
    case anime
    case rain
    case cyberpunk
    case nature
    case game
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .anime: return t("filter.anime")
        case .rain: return t("filter.rain")
        case .cyberpunk: return t("filter.cyberpunk")
        case .nature: return t("filter.nature2")
        case .game: return t("filter.game")
        case .dark: return t("filter.dark")
        }
    }

    var isServerSide: Bool {
        serverSlug != nil
    }

    var serverSlug: String? {
        switch self {
        case .anime: return "anime"
        case .rain: return "rain"
        case .cyberpunk: return "cyberpunk"
        case .nature: return "nature"
        case .game: return "games"
        case .dark: return "dark"
        }
    }
}

private enum MediaCategory: String, CaseIterable, Identifiable {
    case all, anime, games, superhero, nature, car, tv, fantasy, space
    case technology, holiday, animal, horror, football, japan, helloKitty

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return t("filter.all")
        case .anime: return t("filter.anime")
        case .games: return t("filter.games")
        case .superhero: return t("filter.superhero")
        case .nature: return t("filter.nature2")
        case .car: return t("filter.car")
        case .tv: return t("filter.tv")
        case .fantasy: return t("filter.fantasy")
        case .space: return t("filter.space")
        case .technology: return t("filter.technology2")
        case .holiday: return t("filter.holiday")
        case .animal: return t("filter.animal")
        case .horror: return t("filter.horror")
        case .football: return t("filter.football")
        case .japan: return t("filter.japan")
        case .helloKitty: return "Hello Kitty"
        }
    }

    var slug: String {
        switch self {
        case .all: return ""
        case .helloKitty: return "hello-kitty"
        default: return rawValue
        }
    }

    var icon: String {
        switch self {
        case .all: return "sparkles"
        case .anime: return "person.crop.rectangle.stack.fill"
        case .games: return "gamecontroller.fill"
        case .superhero: return "bolt.shield.fill"
        case .nature: return "leaf.fill"
        case .car: return "car.side.fill"
        case .tv: return "film.stack.fill"
        case .fantasy: return "wand.and.stars"
        case .space: return "sparkles.tv"
        case .technology: return "cpu.fill"
        case .holiday: return "gift.fill"
        case .animal: return "pawprint.fill"
        case .horror: return "moon.stars.fill"
        case .football: return "soccerball"
        case .japan: return "building.columns.fill"
        case .helloKitty: return "heart.fill"
        }
    }

    var accentColors: [String] {
        switch self {
        case .all: return ["5A7CFF", "20C1FF"]
        case .anime: return ["FF88C7", "7747FF"]
        case .games: return ["62D4FF", "4E66FF"]
        case .superhero: return ["FFB15B", "E14949"]
        case .nature: return ["98E978", "3AA565"]
        case .car: return ["FFD66E", "FF8B3D"]
        case .tv: return ["63A3FF", "6D42FF"]
        case .fantasy: return ["F17CF5", "5F67FF"]
        case .space: return ["B1C9FF", "5B75FF"]
        case .technology: return ["4FF4D6", "1AB9A5"]
        case .holiday: return ["FF6B6B", "EE5A6E"]
        case .animal: return ["C8A876", "8B7355"]
        case .horror: return ["8B0000", "4A0000"]
        case .football: return ["4CAF50", "2E7D32"]
        case .japan: return ["FFB7C5", "E85D75"]
        case .helloKitty: return ["FF69B4", "FF1493"]
        }
    }
}

// MARK: - 媒体探索页氛围背景（独立观察视频壁纸播放状态）
/// 从 MediaExploreContentView 下沉而来：自行观察 VideoWallpaperManager / WallpaperEngineXBridge，
/// 仅当播放状态变化时重建本背景视图，避免整个媒体探索页 body 重算。
private struct MediaExploreAtmosphereBackground: View {
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

private struct WorkshopActiveFilterChip: View {
    let title: String
    let accentHex: String
    let onRemove: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onRemove) {
            HStack(spacing: 8) {
                Circle().fill(Color(hex: "#\(accentHex)")).frame(width: 8, height: 8)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ArcBackgroundSettings.shared.primaryText.opacity(0.94))
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(isHovered ? 0.95 : 0.72))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                ZStack {
                    Capsule(style: .continuous).fill(.ultraThinMaterial)
                    Capsule(style: .continuous).fill(Color(hex: "#\(accentHex)").opacity(0.12))
                }
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color(hex: "#\(accentHex)").opacity(0.3), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(AppFluidMotion.hoverEase, value: isHovered)
        .onHover { isHovered = $0 }
    }
}


// MARK: - Workshop 排序选项

private enum WorkshopSortOption: String, CaseIterable, SortOptionProtocol {
    case trendToday = "trend_1"
    case trendWeek = "trend_7"
    case trendMonth = "trend_30"
    case trendQuarter = "trend_90"
    case trendYear = "trend_365"
    case trendAll = "trend"
    case updated = "updated"
    case created = "created"
    case topRated = "toprated"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .trendToday: return t("workshop.sort.trendToday")
        case .trendWeek: return t("workshop.sort.trendWeek")
        case .trendMonth: return t("workshop.sort.trendMonth")
        case .trendQuarter: return t("workshop.sort.trendQuarter")
        case .trendYear: return t("workshop.sort.trendYear")
        case .trendAll: return t("workshop.sort.trendAll")
        case .updated: return t("workshop.sort.updated")
        case .created: return t("workshop.sort.created")
        case .topRated: return t("workshop.sort.topRated")
        }
    }

    var menuTitle: String { title }

    /// 映射到 WorkshopSearchParams.SortOption
    var sortBy: WorkshopSearchParams.SortOption {
        switch self {
        case .trendToday, .trendWeek, .trendMonth, .trendQuarter, .trendYear, .trendAll:
            return .ranked
        case .updated:
            return .updated
        case .created:
            return .created
        case .topRated:
            return .topRated
        }
    }

    /// 时间范围（仅对热门趋势有效），nil = 全部时间
    var days: Int? {
        switch self {
        case .trendToday: return 1
        case .trendWeek: return 7
        case .trendMonth: return 30
        case .trendQuarter: return 90
        case .trendYear: return 365
        case .trendAll, .updated, .created, .topRated:
            return nil
        }
    }
}

// MARK: - Workshop URL 输入按钮

struct WorkshopURLInputButton: View {
    let tint: Color
    let action: () -> Void
    @ObservedObject private var arcSettings = ArcBackgroundSettings.shared
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "link")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(arcSettings.primaryText.opacity(0.92))
                .frame(width: 46, height: 46)
                .contentShape(Circle())
                .arcFrostedCircle(
                    intensity: arcSettings.frostedIntensity,
                    isLightMode: arcSettings.isLightMode,
                    accentColor: tint
                )
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.05 : 1.0)
        .animation(AppFluidMotion.hoverEase, value: isHovered)
        .onHover { isHovered = $0 }
        .help("通过链接打开壁纸")
    }
}

// MARK: - Workshop URL 输入弹窗

struct WorkshopURLInputSheet: View {
    @Binding var urlInput: String
    let errorMessage: String?
    let isLoading: Bool
    let onSubmit: () -> Void
    let onDismiss: () -> Void

    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 20) {
            // Header
            HStack {
                Text("通过链接打开壁纸")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }

            // Input
            VStack(alignment: .leading, spacing: 8) {
                TextField("粘贴壁纸链接...", text: $urlInput, axis: .vertical)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.9))
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(.white.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(.white.opacity(0.1), lineWidth: 1)
                    )
                    .focused($isInputFocused)
                    .onSubmit {
                        if !isLoading { onSubmit() }
                    }

                if let error = errorMessage {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.red.opacity(0.8))
                        .transition(.opacity)
                }

                Text("支持格式：steamcommunity.com/sharedfiles/filedetails/?id=1234567890 或 motionbgs.com/xxx")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.35))
            }

            // Buttons
            HStack(spacing: 12) {
                Button(action: onDismiss) {
                    Text("取消")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(.white.opacity(0.06))
                        )
                }
                .buttonStyle(.plain)

                Button(action: onSubmit) {
                    HStack(spacing: 6) {
                        if isLoading {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.8)
                        }
                        Text("确认")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(.white.opacity(0.95))
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.accentColor.opacity(0.35))
                    )
                }
                .buttonStyle(.plain)
                .disabled(isLoading || urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
        .background(
            DarkLiquidGlassBackground(cornerRadius: 16, isHovered: false)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isInputFocused = true
            }
        }
    }
}

//
