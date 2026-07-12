import SwiftUI
import AppKit

private struct AnimeLoadMoreSentinelMinYPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = .greatestFiniteMagnitude

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next < value {
            value = next
        }
    }
}

private struct AnimeExploreHeaderHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 {
            value = next
        }
    }
}

private final class AnimeExploreScrollCoordinator: ObservableObject {
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

// MARK: - AnimeExploreView - 动漫探索页

struct AnimeExploreView: View {
    private static let scrollCoordinateSpaceName = "anime-explore-scroll"
    private static let loadMoreTriggerThreshold: CGFloat = 120

    @ObservedObject var viewModel: AnimeViewModel
    @Binding var selectedAnime: AnimeSearchResult?
    var isVisible: Bool = true

    init(viewModel: AnimeViewModel, selectedAnime: Binding<AnimeSearchResult?>, isVisible: Bool = true) {
        self._viewModel = ObservedObject(wrappedValue: viewModel)
        self._selectedAnime = selectedAnime
        self.isVisible = isVisible
    }
    @StateObject private var exploreAtmosphere = ExploreAtmosphereController(wallpaperMode: false)
    @ObservedObject private var arcSettings = ArcBackgroundSettings.shared
    @ObservedObject private var videoWallpaperManager = VideoWallpaperManager.shared
    @ObservedObject private var wallpaperEngineBridge = WallpaperEngineXBridge.shared
    @Environment(\.mainTopBarContentPadding) private var mainTopBarContentPadding

    // MARK: State
    @State private var selectedCategory: AnimeCategory = .all
    @State private var selectedHotTag: AnimeHotTag?
    @State private var searchText = ""
    // TODO(anime sort): 排序选项目前未在 contentHeader 显示，保留 enum 与 state
    // 避免漏改 resetAllFilters；后续接入 SortMenu 时再实质化
    @State private var selectedSort: AnimeSortOption = .newest
    @State private var isLoadingMore = false
    @State private var isInitialLoading = false
    @State private var isFirstAppearance = true
    @State private var loadMoreFailed = false
    @State private var searchTask: Task<Void, Never>?
    @State private var isTagSearchActive = false
    @State private var suppressNextSearchChange = false
    @State private var lastSyncedFirstAnimeID: String?
    @State private var loadMoreTask: Task<Void, Never>?
    /// loadMore 冷却期，防止 contentSize 增长 → isNearBottom 翻转 → 立即重试的无限级联。
    @State private var loadMoreCooldownUntil: Date? = nil
    @State private var measuredHeaderHeight: CGFloat = 0
    @State private var isHeaderContentMounted = true
    @StateObject private var scrollCoordinator = AnimeExploreScrollCoordinator()

    private var shouldUseLightweightEffects: Bool {
        (videoWallpaperManager.isVideoWallpaperActive && !videoWallpaperManager.isPaused) ||
        (wallpaperEngineBridge.isControllingExternalEngine && !wallpaperEngineBridge.isExternalPaused)
    }

    // Grid 控制
    @State private var showScrollToTop: Bool = false
    @State private var outerScrollToTopToken: Int = 0

    var body: some View {
        GeometryReader { geometry in
            let contentWidth = calculateContentWidth(geometry: geometry)

            ZStack {
                if arcSettings.compactMode {
                    arcSettings.compactBackground
                        .ignoresSafeArea()
                } else {
                    ArcAtmosphereBackground(
                        tint: exploreAtmosphere.tint,
                        referenceImage: shouldUseLightweightEffects ? nil : exploreAtmosphere.referenceImage,
                        isLightMode: arcSettings.isLightMode,
                        dotGridOpacity: arcSettings.dotGridOpacity,
                        useNoise: true,
                        grainIntensity: arcSettings.exploreGrainAnime,
                        lightweight: shouldUseLightweightEffects
                    )
                    // 把多层渐变+点阵+噪点合并成一个 Metal 纹理，减少 WindowServer 合成层数
                    .drawingGroup(opaque: true)
                    .ignoresSafeArea()
                }

                ZStack {
                    if viewModel.animeItems.isEmpty {
                        legacyScrollContent(width: geometry.size.width, contentWidth: contentWidth) {
                            Group {
                                if isAnimeLoadingState {
                                    loadingState
                                } else {
                                    emptyState
                                }
                            }
                            .transition(.opacity.animation(.easeInOut(duration: 0.25)))
                        }
                    } else {
                        if #available(macOS 15.0, *) {
                            scrollViewModern(contentWidth: contentWidth, geometry: geometry)
                        } else {
                            scrollViewLegacy(contentWidth: contentWidth, geometry: geometry)
                        }
                    }

                    bottomLoadingOverlay
                    scrollToTopButton
                }
            }
        }
        .onAppear {
            if isFirstAppearance {
                Task { await performFirstAppearanceLoad() }
            } else {
                handleAppear()
            }
        }
        .onChange(of: isVisible) { _, visible in
            if !visible {
                searchTask?.cancel()
                loadMoreTask?.cancel()
                scrollCoordinator.cancelPendingWork()
                searchTask = nil
                loadMoreTask = nil
                isLoadingMore = false
                exploreAtmosphere.pause()
            } else {
                syncAtmosphereIfNeeded()
            }
        }
        .onChange(of: searchText) { _, newValue in handleSearchChange(newValue) }
        .onChange(of: viewModel.animeItems.count) { _, _ in
            syncAtmosphereIfNeeded()
        }
        .onChange(of: headerLayoutSignature) { _, _ in
            invalidateHeaderMeasurement()
        }
    }

    // MARK: - Legacy scroll wrapper (skeleton / empty state)

    private func legacyScrollContent<Content: View>(width: CGFloat, contentWidth: CGFloat, @ViewBuilder body: () -> Content) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                heroSection
                categorySection
                hotTagsSection
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

    private var bottomLoadingOverlay: some View {
        VStack {
            Spacer()
            if loadMoreFailed {
                BottomLoadingFailedCard {
                    triggerLoadMore()
                }
                .padding(.bottom, 60)
            } else if viewModel.isLoadingMore || isLoadingMore || (viewModel.isLoading && !viewModel.animeItems.isEmpty) {
                BottomLoadingCard(isLoading: true)
                    .padding(.bottom, 60)
            } else if !isLoadingMore && !viewModel.isLoadingMore && !viewModel.hasMorePages && !viewModel.animeItems.isEmpty {
                BottomNoMoreCard()
                    .padding(.bottom, 60)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private var isAnimeLoadingState: Bool {
        viewModel.animeItems.isEmpty && (isInitialLoading || isFirstAppearance || viewModel.isLoading)
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
                    .padding(.trailing, 8)
                    .padding(.bottom, 112)
                    .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: showScrollToTop)
        .zIndex(1)
    }

    // MARK: - Sections

    private var heroSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            headerTitle
            searchRow
        }
        .frame(maxWidth: 700, alignment: .leading)
    }

    private var headerTitle: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(greetingText)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(arcSettings.secondaryText.opacity(0.85))

                Text("Bangumi")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(arcSettings.primaryText.opacity(0.75))
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .exploreFrostedCapsule(
                        tint: exploreAtmosphere.tint.primary,
                        material: .ultraThinMaterial,
                        tintLayerOpacity: 0.06
                    )
            }

            Text(t("anime.exploreAnime"))
                .font(.system(size: 32, weight: .bold, design: .serif))
                .tracking(-0.5)
                .foregroundStyle(arcSettings.primaryText)
                .lineLimit(1)
        }
    }

    private var searchRow: some View {
        HStack(spacing: 12) {
            ExploreSearchBar(
                text: $searchText,
                placeholder: t("anime.searchAnime"),
                tint: exploreAtmosphere.tint.primary,
                onSubmit: performSearch,
                onClear: clearSearch
            )

            if !arcSettings.compactMode {
                ArcBackgroundPanelButton(tint: exploreAtmosphere.tint.primary, grainIntensity: $arcSettings.exploreGrainAnime) {
                    randomizeAtmosphere()
                }
            }

            ResetFiltersButton(tint: exploreAtmosphere.tint.secondary) {
                resetAllFilters(reloadData: true)
            }
        }
    }

    private var categorySection: some View {
        FlowLayout(spacing: 12) {
            ForEach(AnimeCategory.allCases) { category in
                CategoryChip(
                    icon: category.icon,
                    title: category.displayName,
                    accentColors: category.accentColors,
                    isSelected: selectedCategory == category
                ) {
                    selectCategory(category)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var hotTagsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(t("anime.hotTags"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(arcSettings.secondaryText.opacity(0.42))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(AnimeHotTag.allCases) { tag in
                        TagChip(
                            title: tag.displayName,
                            isSelected: selectedHotTag == tag
                        ) {
                            selectHotTag(tag)
                        }
                    }
                }
            }
        }
    }

    private var contentHeader: some View {
        HStack(alignment: .center) {
            Text("\(viewModel.animeItems.count) \(t("content.animes"))")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(arcSettings.secondaryText.opacity(0.66))

            Spacer()
            // TODO(anime sort): 暂不显示 SortMenu，等排序逻辑实质化后接入
        }
    }

    // MARK: - Header Stack

    private var headerStack: some View {
        Group {
            if isHeaderContentMounted {
                headerContent
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: AnimeExploreHeaderHeightPreferenceKey.self,
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
        .onPreferenceChange(AnimeExploreHeaderHeightPreferenceKey.self) { height in
            updateMeasuredHeaderHeight(height)
        }
    }

    private var headerContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            heroSection
            categorySection
            hotTagsSection
            contentHeader
                .padding(.top, 12)
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
            selectedCategory.rawValue,
            selectedHotTag?.id ?? "none",
            searchText.isEmpty ? "empty" : "searching"
        ].joined(separator: "|")
    }

    private func handleScrollOffset(_ offset: CGFloat) {
        updateHeaderMountState(scrollOffset: offset)
    }

    private func updateHeaderMountState(scrollOffset: CGFloat) {
        let headerHeight = measuredHeaderHeight > 1 ? measuredHeaderHeight : 220
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

    // MARK: - Grid

    private func animeGrid(contentWidth: CGFloat) -> some View {
        let columnCount = contentWidth > 1200 ? 5 : (contentWidth > 800 ? 4 : 3)
        let spacing: CGFloat = 20
        let totalSpacing = spacing * CGFloat(columnCount - 1)
        let cardWidth = max(1, floor((contentWidth - totalSpacing) / CGFloat(columnCount)))
        let items = viewModel.animeItems
        let columnItems = ExploreGridLayout.stableColumns(
            items: items,
            columnCount: columnCount
        )

        return HStack(alignment: .top, spacing: spacing) {
            ForEach(0..<columnCount, id: \.self) { columnIndex in
                LazyVStack(spacing: spacing) {
                    ForEach(columnItems[safe: columnIndex] ?? []) { anime in
                        AnimeCardView(
                            anime: anime,
                            cardWidth: cardWidth
                        ) {
                            selectedAnime = anime
                        }
                        .equatable()
                        // ⚡ 显式设定卡片高度，让 LazyVStack 实现真正的懒加载。
                        .frame(height: cardWidth * 1.4 + 44)
                    }
                }
                .frame(width: cardWidth)
            }
        }
    }

    // MARK: - UI Components

    private var emptyState: some View {
        Group {
            if let errorMessage = viewModel.errorMessage {
                ErrorStateView(
                    type: .network,
                    message: errorMessage,
                    retryAction: reloadData
                )
            } else {
                ErrorStateView(
                    type: .empty,
                    title: t("anime.noData"),
                    message: t("anime.tryDifferentSource"),
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

    // MARK: - macOS 15+：使用 onScrollGeometryChange

    @available(macOS 15.0, *)
    private func scrollViewModern(contentWidth: CGFloat, geometry: GeometryProxy) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear
                        .frame(height: 0)
                        .id("anime-scroll-top")
                    headerStack
                    animeGrid(contentWidth: contentWidth)
                }
                .padding(.horizontal, 28)
                .frame(width: geometry.size.width, alignment: .leading)
                .environment(\.explorePageAtmosphereTint, exploreAtmosphere.tint)
                .environment(\.arcIsLightMode, arcSettings.isLightMode)
                .background(
                    ScrollToTopHelper(trigger: 0, onOffsetChange: handleScrollOffset)
                        .frame(width: 0, height: 0)
                )
            }
            .coordinateSpace(name: Self.scrollCoordinateSpaceName)
            .onChange(of: viewModel.animeItems.count) { _, count in
                if count > 60 { showScrollToTop = true }
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
            .scrollDisabled(!isVisible)
            .disabled(isInitialLoading)
            .onChange(of: outerScrollToTopToken) { _, _ in
                withAnimation(nil) {
                    proxy.scrollTo("anime-scroll-top", anchor: .top)
                }
            }
        }
    }

    // MARK: - macOS 14：使用 PreferenceKey

    private func scrollViewLegacy(contentWidth: CGFloat, geometry: GeometryProxy) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear
                        .frame(height: 0)
                        .id("anime-scroll-top")
                    headerStack
                    animeGrid(contentWidth: contentWidth)
                    loadMoreSentinel
                }
                .padding(.horizontal, 28)
                .frame(width: geometry.size.width, alignment: .leading)
                .environment(\.explorePageAtmosphereTint, exploreAtmosphere.tint)
                .environment(\.arcIsLightMode, arcSettings.isLightMode)
                .background(
                    ScrollToTopHelper(trigger: 0, onOffsetChange: handleScrollOffset)
                        .frame(width: 0, height: 0)
                )
            }
            .coordinateSpace(name: Self.scrollCoordinateSpaceName)
            .onChange(of: viewModel.animeItems.count) { _, count in
                if count > 60 { showScrollToTop = true }
            }
            .onPreferenceChange(AnimeLoadMoreSentinelMinYPreferenceKey.self) { sentinelMinY in
                scrollCoordinator.sentinelDebounceTask?.cancel()
                let task = DispatchWorkItem {
                    handleLoadMoreSentinelPosition(sentinelMinY, viewportHeight: geometry.size.height)
                }
                scrollCoordinator.sentinelDebounceTask = task
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: task)
            }
            .scrollDisabled(!isVisible)
            .disabled(isInitialLoading)
            .onChange(of: outerScrollToTopToken) { _, _ in
                withAnimation(nil) {
                    proxy.scrollTo("anime-scroll-top", anchor: .top)
                }
            }
        }
    }

    // MARK: - 滚动哨兵

    private var loadMoreSentinel: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: AnimeLoadMoreSentinelMinYPreferenceKey.self,
                value: proxy.frame(in: .named(Self.scrollCoordinateSpaceName)).minY
            )
        }
        .frame(height: 1)
    }

    // MARK: - Actions

    private func performFirstAppearanceLoad() async {
        // 动漫模块关闭时不加载（防御性：禁用时该 tab 不应被添加，此处双保险）
        guard ModuleAvailability.shared.animeEnabled else {
            isFirstAppearance = false
            return
        }
        // ⚠️ 防止 NavigationStack pop 后视图被重建导致丢失已加载的多页数据
        guard viewModel.animeItems.isEmpty else {
            isFirstAppearance = false
            return
        }

        isInitialLoading = true
        searchText = ""
        selectedHotTag = nil
        selectedCategory = .all
        selectedSort = .newest
        isTagSearchActive = false
        lastSyncedFirstAnimeID = nil
        loadMoreFailed = false
        viewModel.searchText = ""
        viewModel.errorMessage = nil

        await viewModel.loadInitialData()
        syncAtmosphereIfNeeded()
        isInitialLoading = false
        isFirstAppearance = false
    }

    private func handleAppear() {
        // 动漫模块关闭时不加载（防御性：禁用时该 tab 不应被添加，此处双保险）
        guard ModuleAvailability.shared.animeEnabled else { return }

        AppLogger.info(.anime, "动漫探索页 onAppear",
            metadata: ["已有数据": !viewModel.animeItems.isEmpty, "当前数量": viewModel.animeItems.count])

        if viewModel.animeItems.isEmpty {
            isInitialLoading = true
            Task {
                let start = Date()
                await viewModel.loadInitialData()
                await MainActor.run {
                    syncAtmosphereIfNeeded()
                    isInitialLoading = false
                }
                AppLogger.info(.anime, "首次加载完成",
                    metadata: [
                        "耗时(s)": String(format: "%.2f", Date().timeIntervalSince(start)),
                        "结果数": viewModel.animeItems.count,
                        "错误": viewModel.errorMessage ?? "无"
                    ])
            }
        } else {
            syncAtmosphereIfNeeded()
        }
    }

    private func selectCategory(_ category: AnimeCategory) {
        guard selectedCategory != category else { return }
        prepareForFeedReplacement()

        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            selectedCategory = category
            selectedHotTag = nil
            isTagSearchActive = true
            searchTask?.cancel()
            searchText = ""
            viewModel.searchText = ""
        }
        // 确保 isTagSearchActive 被清理，防止 onChange(of: searchText) 未触发时标志位泄漏
        DispatchQueue.main.async { [self] in
            isTagSearchActive = false
        }
        Task {
            await viewModel.fetchByCategory(category)
            await MainActor.run {
                syncAtmosphereIfNeeded()
            }
        }
    }

    private func selectHotTag(_ tag: AnimeHotTag) {
        // 与 selectCategory 一致：点击已选中的标签不做任何事，避免开关逻辑导致意外「清空」
        guard selectedHotTag != tag else { return }
        prepareForFeedReplacement()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            selectedHotTag = tag
            selectedCategory = .all
            isTagSearchActive = true
            searchTask?.cancel()
            searchText = ""
            viewModel.searchText = ""
        }
        // 确保 isTagSearchActive 被清理，防止 onChange(of: searchText) 未触发时标志位泄漏
        DispatchQueue.main.async { [self] in
            isTagSearchActive = false
        }
        Task {
            await viewModel.searchByTagName(tag.displayName)
            await MainActor.run {
                syncAtmosphereIfNeeded()
            }
        }
    }

    private func handleSearchChange(_ newValue: String) {
        viewModel.searchText = newValue

        if suppressNextSearchChange {
            suppressNextSearchChange = false
            return
        }

        if isTagSearchActive {
            isTagSearchActive = false
            return
        }

        searchTask?.cancel()

        if newValue.isEmpty {
            prepareForFeedReplacement()
            Task {
                await viewModel.fetchPopular()
            }
            return
        }

        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                prepareForFeedReplacement(cancelSearchTask: false)
            }
            await viewModel.search()
        }
    }

    private func performSearch() {
        prepareForFeedReplacement()
        searchTask?.cancel()
        Task {
            await viewModel.search()
        }
    }

    private func clearSearch() {
        prepareForFeedReplacement()
        setSearchTextSilently("")
        selectedHotTag = nil
        selectedCategory = .all
        Task {
            await viewModel.fetchPopular()
        }
    }

    private func triggerLoadMore() {
        guard viewModel.hasMorePages,
              !viewModel.isLoading,
              !isLoadingMore else { return }

        // ⛔ 冷却期内不触发 loadMore（防止 contentSize 增长后的无限级联）
        if let cooldown = loadMoreCooldownUntil, Date() < cooldown { return }

        AppLogger.info(.anime, "加载更多", metadata: ["当前数量": viewModel.animeItems.count])
        isLoadingMore = true
        loadMoreFailed = false
        loadMoreTask?.cancel()
        loadMoreTask = Task { @MainActor in
            defer {
                loadMoreTask = nil
            }
            guard !Task.isCancelled else { return }
            loadMoreFailed = false
            await viewModel.loadMore()
            guard !Task.isCancelled else { return }
            if viewModel.hasMorePages && viewModel.errorMessage != nil {
                loadMoreFailed = true
            }
            // ⚡ 设置 1.5s 冷却期，防止 contentSize 增长后的无限级联
            loadMoreCooldownUntil = Date().addingTimeInterval(1.5)
            // 延迟释放 isLoadingMore 给 contentSize 稳定时间
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
        setSearchTextSilently("")
        selectedHotTag = nil
        selectedCategory = .all
        selectedSort = .newest
        isTagSearchActive = false
        lastSyncedFirstAnimeID = nil
        loadMoreFailed = false
        viewModel.searchText = ""
        viewModel.errorMessage = nil
        prepareForFeedReplacement()

        if reloadData {
            Task {
                await viewModel.loadInitialData()
            }
        }
    }

    private func reloadData() {
        AppLogger.info(.anime, "重新搜索：用户操作触发")
        prepareForFeedReplacement()
        lastSyncedFirstAnimeID = nil
        loadMoreFailed = false
        viewModel.errorMessage = nil
        Task {
            await viewModel.loadInitialData()
        }
    }

    private func prepareForFeedReplacement(cancelSearchTask: Bool = true) {
        if cancelSearchTask {
            searchTask?.cancel()
        }
        loadMoreTask?.cancel()
        viewModel.prepareForFeedReplacement()
        scrollCoordinator.cancelPendingWork()
        isLoadingMore = false
        loadMoreFailed = false
        showScrollToTop = false
        outerScrollToTopToken &+= 1
    }

    private func setSearchTextSilently(_ value: String) {
        viewModel.searchText = value
        guard searchText != value else { return }
        suppressNextSearchChange = true
        searchText = value
    }

    private func syncAtmosphereIfNeeded() {
        let first = viewModel.animeItems.first
        let fid = first?.id
        guard fid != lastSyncedFirstAnimeID else { return }
        lastSyncedFirstAnimeID = fid
        if let first, let coverURL = first.coverURL {
            exploreAtmosphere.updateFirstAnime(coverURL: coverURL)
        }
    }

    private func randomizeAtmosphere() {
        guard !viewModel.animeItems.isEmpty else { return }
        let random = viewModel.animeItems.randomElement()!
        if let coverURL = random.coverURL.flatMap({ URL(string: $0) }) {
            exploreAtmosphere.updateFromImageURL(coverURL, keyPrefix: "rand-anime")
        }
    }

    private func calculateContentWidth(geometry: GeometryProxy) -> CGFloat {
        max(0, geometry.size.width - 56)
    }
}

// MARK: - Sort Options

private enum AnimeSortOption: String, CaseIterable, SortOptionProtocol {
    case newest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newest: return t("anime.sortNewest")
        }
    }

    var menuTitle: String {
        switch self {
        case .newest: return t("anime.sortByNewest")
        }
    }
}

// MARK: - Skeleton

private struct AnimeGridSkeleton: View {
    var contentWidth: CGFloat = 800

    private var gridItems: [GridItem] {
        let count = contentWidth > 1200 ? 5 : (contentWidth > 800 ? 4 : 3)
        return Array(repeating: GridItem(.flexible(), spacing: 20), count: count)
    }

    var body: some View {
        LazyVGrid(columns: gridItems, spacing: 20) {
            ForEach(0..<6, id: \.self) { _ in
                AnimeCardSkeleton()
            }
        }
    }
}

private struct AnimeCardSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LinearGradient(
                colors: [Color(hex: "1C2431"), Color(hex: "233B5A"), Color(hex: "14181F")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .aspectRatio(10/14, contentMode: .fit)
            .clipShape(UnevenRoundedRectangle(
                topLeadingRadius: 14, bottomLeadingRadius: 0,
                bottomTrailingRadius: 0, topTrailingRadius: 14,
                style: .continuous
            ))

            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 80, height: 13)
                Spacer()
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.white.opacity(0.05))
                    .frame(width: 40, height: 10)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(height: 44)
            .background(Color.black.opacity(0.46))
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.clear)
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 1))
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shimmer()
    }
}
