import SwiftUI
import AppKit
import Kingfisher
@preconcurrency import Translation

private struct WallpaperLoadMoreSentinelMinYPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = .greatestFiniteMagnitude

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

@MainActor
private final class WallpaperExploreGridRuntimeState: ObservableObject {
    var gridImagePrefetcher: Kingfisher.ImagePrefetcher?
    var lastPrefetchCenterIndex: Int = -1
    var lastPrefetchStartedAt: Date = .distantPast
    var lastPrefetchURLs: Set<URL> = []

    deinit {
        gridImagePrefetcher?.stop()
    }

    func resetPrefetchState() {
        gridImagePrefetcher?.stop()
        lastPrefetchCenterIndex = -1
        lastPrefetchStartedAt = .distantPast
        lastPrefetchURLs.removeAll()
    }
}

// MARK: - WallpaperExploreContentView - 壁纸探索页

struct WallpaperExploreContentView: View {
    private static let scrollCoordinateSpaceName = "wallpaper-explore-scroll"
    private static let loadMoreTriggerThreshold: CGFloat = 120

    @ObservedObject var viewModel: WallpaperViewModel
    @Binding var selectedWallpaper: Wallpaper?
    var isVisible: Bool = true
    @StateObject private var exploreAtmosphere = ExploreAtmosphereController(wallpaperMode: true)
    @ObservedObject private var arcSettings = ArcBackgroundSettings.shared
    @StateObject private var translationBridge = SearchTranslationBridge()
    @StateObject private var gridRuntimeState = WallpaperExploreGridRuntimeState()
    init(viewModel: WallpaperViewModel, selectedWallpaper: Binding<Wallpaper?>, isVisible: Bool = true) {
        self._viewModel = ObservedObject(wrappedValue: viewModel)
        self._selectedWallpaper = selectedWallpaper
        self.isVisible = isVisible
    }

    // MARK: State
    @State private var category: CategoryFilter = .all
    @State private var fourKCategory: FourKCategory?
    @State private var fourKSorting: FourKSortingOption = .latest
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
    @State private var gridScrollToTopToken = 0
    @State private var gridReloadToken = 0
    @State private var gridLayoutRefreshToken = 0
    @State private var gridSavedScrollOffset: CGFloat = 0
    @State private var gridContentHeight: CGFloat = 600

    @State private var loadMoreTask: Task<Void, Never>?

    /// 缓存筛选后的列表，避免每次 body 重绘时对 `wallpapers` 全表过滤（Wallhaven 分类）
    @State private var visibleWallpapers: [Wallpaper] = []

    var body: some View {
        if #available(macOS 15.0, *) {
            TranslationTaskHost(bridge: translationBridge) {
                mainContent
            }
        } else {
            mainContent
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        GeometryReader { geometry in
            let contentWidth = calculateContentWidth(geometry: geometry)
            let gridConfig = WallpaperGridConfig(contentWidth: contentWidth)

            ZStack {
                ArcAtmosphereBackground(
                    tint: exploreAtmosphere.tint,
                    referenceImage: exploreAtmosphere.referenceImage,
                    isLightMode: arcSettings.isLightMode,
                    dotGridOpacity: arcSettings.dotGridOpacity,
                    useNoise: true,
                    grainIntensity: arcSettings.exploreGrainWallpaper
                )
                .ignoresSafeArea()

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
                gridRuntimeState.resetPrefetchState()
                syncAtmosphereIfNeeded()
                gridLayoutRefreshToken += 1
            }
        }
        .onChange(of: arcSettings.isLightMode) { _, _ in
            gridReloadToken += 1
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
        }
        .onReceive(NotificationCenter.default.publisher(for: .appShouldReleaseForegroundMemory)) { _ in
            gridRuntimeState.resetPrefetchState()
        }
        .onChange(of: category) { _, _ in handleCategoryChange(); recomputeVisibleWallpapers(); syncAtmosphereIfNeeded() }
        .onChange(of: fourKCategory) { _, _ in handle4KCategoryChange() }
        .onChange(of: hotTag) { _, _ in handleHotTagChange() }
        .onChange(of: viewModel.sortingOption) { _, _ in handleSortingChange() }
        .onChange(of: fourKSorting) { _, _ in handle4KSortingChange() }
        .onChange(of: viewModel.wallpapers) { _, _ in recomputeVisibleWallpapers(); syncAtmosphereIfNeeded() }
        .overlay(alertOverlay)
    }
    
    private func scrollContent(width: CGFloat, viewportHeight: CGFloat, gridConfig: WallpaperGridConfig) -> some View {
        return ZStack {
            if visibleWallpapers.isEmpty {
                legacyScrollContent(width: width, body: AnyView(
                    Group {
                        if isWallpaperLoadingState {
                            loadingState
                        } else {
                            emptyState
                        }
                    }
                    .transition(.opacity.animation(.easeInOut(duration: 0.25)))
                ))
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        ScrollToTopHelper(trigger: outerScrollToTopToken)
                            .frame(height: 0)
                        gridHeaderStack
                        wallpaperGrid(config: gridConfig)
                            .frame(height: max(gridContentHeight, 320))
                        loadMoreSentinel
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

                .onPreferenceChange(WallpaperLoadMoreSentinelMinYPreferenceKey.self) { sentinelMinY in
                    handleLoadMoreSentinelPosition(sentinelMinY, viewportHeight: viewportHeight)
                }
                .scrollDisabled(!isVisible)
                .disabled(isInitialLoading || !isVisible)
            }

            // 底部加载状态卡片
            bottomLoadingOverlay

            scrollToTopButton
        }
    }

    private func legacyScrollContent(width: CGFloat, body: AnyView) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                heroSection
                categorySection
                filterSection
                activeFiltersSection
                contentHeader
                    .padding(.top, 12)
                body
            }
            .padding(.horizontal, 28)
            .padding(.top, 80)
            .padding(.bottom, 48)
            .frame(width: width, alignment: .leading)
            .environment(\.explorePageAtmosphereTint, exploreAtmosphere.tint)
            .environment(\.arcIsLightMode, arcSettings.isLightMode)
        }
        .scrollDisabled(!isVisible)
    }

    private var scrollToTopButton: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                if showScrollToTop {
                    Button {
                        gridScrollToTopToken += 1
                        outerScrollToTopToken += 1
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.92))
                            .frame(width: 44, height: 44)
                            .liquidGlassSurface(.regular, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 28)
                    .padding(.bottom, 120)
                    .contentShape(Rectangle())
                    .zIndex(100)
                    .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .zIndex(100)
        .animation(.easeInOut(duration: 0.3), value: showScrollToTop)
    }
    
    private var bottomLoadingOverlay: some View {
        VStack {
            Spacer()
            if loadMoreFailed {
                BottomLoadingFailedCard {
                    loadMoreFailed = false
                    Task { await viewModel.loadMore() }
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

    private var heroSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            headerTitle
            searchRow
            hotTagsRow
        }
        .frame(maxWidth: 700, alignment: .leading)
    }
    
    private var headerTitle: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(greetingText)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(arcSettings.secondaryText.opacity(0.85))

                Text(WallpaperSourceManager.shared.activeSource.displayName)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(arcSettings.primaryText.opacity(0.75))
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .exploreFrostedCapsule(
                        tint: exploreAtmosphere.tint.primary,
                        material: .ultraThinMaterial,
                        tintLayerOpacity: 0.06
                    )

                // 切换源按钮
                Button {
                    let nextSource: WallpaperSourceManager.SourceType = WallpaperSourceManager.shared.activeSource == .wallhaven ? .fourKWallpapers : .wallhaven
                    WallpaperSourceManager.shared.switchTo(nextSource)
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(arcSettings.primaryText.opacity(0.75))
                        .frame(width: 24, height: 20)
                        .exploreFrostedCapsule(
                            tint: exploreAtmosphere.tint.primary,
                            material: .ultraThinMaterial,
                            tintLayerOpacity: 0.06
                        )
                }
                .buttonStyle(.plain)
                .help("切换到 \(WallpaperSourceManager.shared.activeSource == .wallhaven ? "4K Wallpapers" : "WallHaven")")
                .sourceSwitchTooltip(
                    key: "wallpaper_source_switch_tooltip_shown",
                    message: "点击这里切换壁纸源"
                )
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
            
            ArcBackgroundPanelButton(tint: exploreAtmosphere.tint.primary, grainIntensity: $arcSettings.exploreGrainWallpaper) {
                randomizeAtmosphere()
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

    private var categorySection: some View {
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
            } else {
                SortMenu(options: FourKSortingOption.allCases, selected: $fourKSorting, tint: exploreAtmosphere.tint.primary)
            }
        }
    }

    private var gridHeaderStack: some View {
        VStack(alignment: .leading, spacing: 16) {
            heroSection
            categorySection
            filterSection
            activeFiltersSection
            contentHeader
                .padding(.top, 12)
        }
        .padding(.top, 80)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Grid & Cards

    private func wallpaperGrid(config: WallpaperGridConfig) -> some View {
        ExploreGridContainer(
            itemCount: { visibleWallpapers.count },
            aspectRatio: { index in
                guard index < visibleWallpapers.count else {
                    return wallpaperCellAspectRatio(config: config)
                }
                return wallpaperCellAspectRatio(for: visibleWallpapers[index], config: config)
            },
            configureCell: { cell, index in
                guard index < visibleWallpapers.count else { return }
                cell.configure(
                    with: visibleWallpapers[index],
                    isFavorite: viewModel.isFavorite(visibleWallpapers[index])
                )
            },
            cellClass: WallpaperGridCell.self,
            onSelect: { index in
                guard index < visibleWallpapers.count else { return }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    selectedWallpaper = visibleWallpapers[index]
                }
            },
            onVisibleItemsChange: { indexPaths in
                preloadVisibleNeighborhood(indexPaths: indexPaths, config: config)
            },
            onScrollOffsetChange: { offset in
                gridSavedScrollOffset = offset
            },
            onReachBottom: triggerLoadMore,
            scrollToTopToken: gridScrollToTopToken,
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
            hoverExpansionAllowance: 8
        )
    }

    private func wallpaperCellAspectRatio(config: WallpaperGridConfig) -> CGFloat {
        let safeCardWidth = max(1, config.cardWidth)
        let height = safeCardWidth * 0.6 + 46
        return safeCardWidth / max(1, height)
    }

    private func wallpaperCellAspectRatio(for wallpaper: Wallpaper, config: WallpaperGridConfig) -> CGFloat {
        let safeCardWidth = max(1, config.cardWidth)
        let imageAspectRatio = CGFloat(wallpaper.effectiveAspectRatioValue)
        let clampedImageAspectRatio = min(max(imageAspectRatio, 0.35), 3.6)
        let imageHeight = safeCardWidth / clampedImageAspectRatio
        let height = imageHeight + 46
        return safeCardWidth / max(1, height)
    }

    private func preloadVisibleNeighborhood(indexPaths: Set<IndexPath>, config: WallpaperGridConfig) {
        let visibleIndices = indexPaths
            .map(\.item)
            .filter { $0 >= 0 && $0 < visibleWallpapers.count }
            .sorted()
        guard let center = visibleIndices.dropFirst(visibleIndices.count / 2).first,
              center < visibleWallpapers.count else { return }
        preloadNearbyImages(centerIndex: center, config: config)
    }

    /// 智能预加载附近图片（前后各 8 张）；中心索引节流，减少快速滑动时 Prefetcher 抖动。
    /// 预取不应用降采样处理器，让 Cell 按自身动态尺寸从磁盘缓存读取原始图并处理。
    private func preloadNearbyImages(centerIndex index: Int, config: WallpaperGridConfig) {
        let items = visibleWallpapers
        guard index >= 0, index < items.count else { return }
        let centerDelta = gridRuntimeState.lastPrefetchCenterIndex >= 0
            ? abs(index - gridRuntimeState.lastPrefetchCenterIndex)
            : Int.max
        let now = Date()
        if centerDelta < 8 { return }
        if now.timeIntervalSince(gridRuntimeState.lastPrefetchStartedAt) < 0.24, centerDelta < 16 {
            return
        }

        let count = items.count
        guard count > 0 else { return }
        let clamped = min(max(0, index), count - 1)
        let lower = max(0, clamped - 8)
        let upper = min(count, clamped + 9)
        guard lower < upper else { return }
        let range = lower..<upper
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let urls = range
            .filter { $0 != clamped }
            .flatMap { prefetchCandidateURLs(for: items[$0], config: config, scale: scale) }
        let urlSet = Set(urls)
        guard !urlSet.isEmpty, urlSet != gridRuntimeState.lastPrefetchURLs else { return }

        // 停止旧预取器，启动新预取器（Kingfisher 内部队列执行，不阻塞主线程）
        gridRuntimeState.gridImagePrefetcher?.stop()
        gridRuntimeState.lastPrefetchCenterIndex = index
        gridRuntimeState.lastPrefetchStartedAt = now
        gridRuntimeState.lastPrefetchURLs = urlSet
        // 不应用 DownsamplingImageProcessor：Cell 按各自动态尺寸处理，
        // 预取仅负责把原始图下载到 Kingfisher 磁盘缓存即可。
        let prefetcher = ImagePrefetcher(
            urls: urls,
            options: [
                .scaleFactor(scale),
                .backgroundDecode
            ]
        )
        gridRuntimeState.gridImagePrefetcher = prefetcher
        prefetcher.start()
    }

    private func prefetchCandidateURLs(
        for wallpaper: Wallpaper,
        config: WallpaperGridConfig,
        scale: CGFloat
    ) -> [URL] {
        let cardWidth = max(1, config.cardWidth)
        let aspectRatio = min(max(CGFloat(wallpaper.effectiveAspectRatioValue), 0.35), 3.6)
        let imageHeight = cardWidth / aspectRatio
        let targetWidth = cardWidth * scale
        let targetHeight = imageHeight * scale
        let targetMaxEdge = min(max(targetWidth, targetHeight), 1280)
        let isExtremeAspect = aspectRatio < 0.7 || aspectRatio > 2.1
        let prefersHighResFirst = targetMaxEdge >= 900 || isExtremeAspect

        let candidates: [URL?]
        if prefersHighResFirst {
            candidates = [
                wallpaper.originalThumbURL,
                wallpaper.fullImageURL,
                wallpaper.thumbURL
            ]
        } else {
            candidates = [
                wallpaper.thumbURL,
                wallpaper.originalThumbURL
            ]
        }

        var seen: Set<String> = []
        let deduplicated: [URL] = candidates.compactMap { url -> URL? in
            guard let url else { return nil }
            let key = url.absoluteString
            guard seen.insert(key).inserted else { return nil }
            return url
        }

        return Array(deduplicated.prefix(prefersHighResFirst ? 2 : 1))
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
            message: "加载中...",
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
                    gridRuntimeState.resetPrefetchState()
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
            gridRuntimeState.resetPrefetchState()
            recomputeVisibleWallpapers()
            syncAtmosphereIfNeeded()
        }
    }
    
    // 移除递归加载逻辑，保留触底分页保底机制

    private func handleDataSourceChange() {
        if !viewModel.currentSourceSupportsNSFW {
            viewModel.puritySFW = true
            viewModel.puritySketchy = false
            viewModel.purityNSFW = false
        }
        fourKCategory = nil
        category = .all
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

    private func triggerLoadMore() {
        guard viewModel.hasMorePages,
              !viewModel.isLoading,
              !isLoadingMore else { return }

        Task {
            isLoadingMore = true
            loadMoreFailed = false
            defer { isLoadingMore = false }
            await viewModel.loadMore()
            // 检查是否加载失败（仍有更多页但没有新数据）
            if viewModel.hasMorePages && viewModel.errorMessage != nil {
                loadMoreFailed = true
            }
        }
    }

    private func handleLoadMoreSentinelPosition(_ sentinelMinY: CGFloat, viewportHeight: CGFloat) {
        guard isVisible, viewportHeight > 0, sentinelMinY.isFinite else { return }
        if sentinelMinY <= viewportHeight + Self.loadMoreTriggerThreshold {
            triggerLoadMore()
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
        AppLogger.info(.wallpaper, "重新搜索：用户操作触发")
        gridRuntimeState.resetPrefetchState()
        lastSyncedFirstWallpaperID = nil
        loadMoreFailed = false
        viewModel.errorMessage = nil
        // 不再手动清空 wallpapers，让旧数据保持在屏幕上直到 search() 一次性替换新数据，
        // 避免根视图在 ExploreGridContainer 和 legacyScrollContent 之间来回切换导致的抖动。
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
        gridRuntimeState.resetPrefetchState()
        lastSyncedFirstWallpaperID = nil
        loadMoreFailed = false
        viewModel.errorMessage = nil

        if reloadData {
            // 不再手动清空 wallpapers，避免根视图切换导致的抖动
            Task { await viewModel.search() }
        } else {
            recomputeVisibleWallpapers()
        }
    }

    private func recomputeVisibleWallpapers() {
        let newVisible: [Wallpaper]
        if viewModel.currentSourceSupportsWallhavenCategories {
            newVisible = viewModel.wallpapers.filter { matchesCategory($0, category: category) }
        } else {
            newVisible = viewModel.wallpapers
        }
        visibleWallpapers = newVisible
        gridReloadToken += 1
    }

    private func syncAtmosphereIfNeeded() {
        let first = visibleWallpapers.first
        let fid = first?.id
        guard fid != lastSyncedFirstWallpaperID else { return }
        lastSyncedFirstWallpaperID = fid
        DispatchQueue.main.async {
            guard lastSyncedFirstWallpaperID == fid else { return }
            exploreAtmosphere.updateFirstWallpaper(first)
        }
    }

    private func pauseActivity() {
        loadMoreTask?.cancel()
        loadMoreTask = nil
        gridRuntimeState.resetPrefetchState()
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

// MARK: - Grid Configuration

private struct WallpaperGridConfig {
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
        // 移除 cardHeight 计算，让卡片自动计算高度
        // 使用 flexible 而非 fixed，让卡片自然布局
        self.gridItems = Array(repeating: GridItem(.flexible(), spacing: spacing), count: columnCount)
    }
    
    // 移除强制高度计算方法
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
            chips.append(.init(kind: .color(hex), title: preset.displayName, subtitle: preset.displayHex, accentHex: hex))
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
