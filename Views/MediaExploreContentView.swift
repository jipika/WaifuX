import SwiftUI
import AppKit
import Kingfisher
@preconcurrency import Translation

private struct MediaLoadMoreSentinelMinYPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = .greatestFiniteMagnitude

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
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
    @StateObject private var translationBridge = SearchTranslationBridge()

    @State private var selectedCategory: MediaCategory = .all
    @State private var selectedHotTag: MediaHotTag?
    @State private var selectedSort: MediaSortOption = .newest
    @State private var searchText = ""
    @State private var isLoadingMore = false
    @State private var isInitialLoading = false
    @State private var isFirstAppearance = true
    @State private var loadMoreFailed = false
    @State private var lastSyncedFirstItemID: String?

    @State private var searchTask: Task<Void, Never>?
    @State private var loadMoreTask: Task<Void, Never>?
    @State private var gridRefreshTask: Task<Void, Never>?
    @State private var pendingSearchText: String?
    /// 翻译后的实际搜索词（英文），与 searchText（原始中文）分离
    @State private var mediaSearchQuery: String = ""

    // ExploreGridContainer 控制 token
    @State private var gridScrollToTopToken: Int = 0
    @State private var gridReloadToken: Int = 0
    @State private var gridLayoutRefreshToken: Int = 0
    @State private var gridSavedScrollOffset: CGFloat = 0
    @State private var gridContentHeight: CGFloat = 600
    @State private var showScrollToTop: Bool = false


    // Workshop 筛选
    @State private var selectedWorkshopTag: WorkshopSourceManager.WorkshopTag?
    @State private var selectedWorkshopType: WorkshopSourceManager.WorkshopTypeFilter = .all
    @State private var selectedWorkshopContentLevel: WorkshopSourceManager.WorkshopContentLevel? = .everyone
    @State private var selectedWorkshopResolution: WorkshopSourceManager.WorkshopResolution? = nil
    @State private var workshopSearchQuery: String = ""
    @State private var selectedWorkshopSort: WorkshopSortOption = .trendWeek
    private var workshopService: WorkshopService {
        WorkshopService.shared
    }

    var body: some View {
        GeometryReader { geometry in
            let gridContentWidth = max(0, geometry.size.width - 56)

            ZStack {
                ArcAtmosphereBackground(
                    tint: exploreAtmosphere.tint,
                    referenceImage: exploreAtmosphere.referenceImage,
                    isLightMode: arcSettings.isLightMode,
                    dotGridOpacity: arcSettings.dotGridOpacity,
                    useNoise: true,
                    grainIntensity: arcSettings.exploreGrainMedia
                )
                .ignoresSafeArea()

                ZStack {
                    contentArea(
                        gridContentWidth: gridContentWidth,
                        viewportHeight: geometry.size.height
                    )
                        .padding(.horizontal, 28)
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
                syncAtmosphereIfNeeded()
                gridLayoutRefreshToken &+= 1
            }
        }
        .onChange(of: arcSettings.isLightMode) { _, _ in
            gridReloadToken &+= 1
        }
        .onChange(of: selectedHotTag) { _, _ in handleFilterChange() }
        .onChange(of: selectedWorkshopSort) { _, _ in handleWorkshopSortChange() }
        .onChange(of: searchText) { _, newValue in
            translationBridge.detectLanguage(for: newValue)
            handleFilterChange()
        }
        .onReceive(translationBridge.$translationCompleted) { _ in
            handleTranslationCompleted()
        }
        .onChange(of: viewModel.items) { oldItems, newItems in
            syncAtmosphereIfNeeded()
            if oldItems.count == newItems.count {
                scheduleGridVisibleRefresh()
            }
        }
        .onChange(of: viewModel.libraryContentRevision) { _, _ in
            // viewModel.items 已通过 @Published 自动触发 UI 更新；这里 bump reload 让 cell 收藏状态刷新
            scheduleGridVisibleRefresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .workshopSourceChanged)) { _ in
            handleSourceChange()
        }
    }

    @ViewBuilder
    private func contentArea(gridContentWidth: CGFloat, viewportHeight: CGFloat) -> some View {
        if viewModel.items.isEmpty {
            legacyScrollContent(gridContentWidth: gridContentWidth, body: AnyView(
                Group {
                    if isMediaLoadingState {
                        loadingState
                    } else {
                        emptyState
                    }
                }
                .transition(.opacity.animation(.easeInOut(duration: 0.3)))
            ))
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    headerStack
                    mediaGrid(contentWidth: gridContentWidth)
                        .frame(height: max(gridContentHeight, 320))
                    loadMoreSentinel
                }
            }
            .coordinateSpace(name: Self.scrollCoordinateSpaceName)
            .onPreferenceChange(MediaLoadMoreSentinelMinYPreferenceKey.self) { sentinelMinY in
                handleLoadMoreSentinelPosition(sentinelMinY, viewportHeight: viewportHeight)
            }
            .scrollDisabled(!isVisible)
        }
    }

    /// 仅用于"骨架/空状态"等无网格场景的兜底滚动容器（保留 header）
    private func legacyScrollContent(gridContentWidth: CGFloat, body: AnyView) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                headerStack
                body
            }
            .padding(.bottom, 48)
        }
        .scrollDisabled(!isVisible)
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
            } else if isLoadingMore || (viewModel.isLoadingMore && !viewModel.items.isEmpty) {
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
                    Button {
                        gridScrollToTopToken &+= 1
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
    }

    // MARK: - Header

    private var headerStack: some View {
        VStack(alignment: .leading, spacing: 16) {
            heroSection
            categorySection
            if workshopSourceManager.activeSource == .wallpaperEngine {
                filterSection
                workshopTagsSection
                activeFiltersSection
            }
            contentHeader.padding(.top, 12)
        }
        .padding(.top, 80)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .environment(\.explorePageAtmosphereTint, exploreAtmosphere.tint)
        .environment(\.arcIsLightMode, arcSettings.isLightMode)
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
            if workshopSourceManager.activeSource != .wallpaperEngine {
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

                // 当前源标签
                Text(workshopSourceManager.activeSource.displayName)
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
                    workshopSourceManager.switchToNext()
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
                .help("切换到 \(workshopSourceManager.activeSource == .motionBG ? t("wallpaperEngine") : "MotionBG")")
                .sourceSwitchTooltip(
                    key: "media_source_switch_tooltip_shown",
                    message: "点击这里切换壁纸源"
                )
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
                translatedText: workshopSourceManager.activeSource != .wallpaperEngine ? translationBridge.translatedText : nil,
                isTranslating: workshopSourceManager.activeSource != .wallpaperEngine ? translationBridge.isTranslating : false,
                onDismissTranslation: workshopSourceManager.activeSource != .wallpaperEngine ? {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        translationBridge.dismiss()
                    }
                } : nil
            )

            ArcBackgroundPanelButton(tint: exploreAtmosphere.tint.primary, grainIntensity: $arcSettings.exploreGrainMedia) {
                randomizeAtmosphere()
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
        viewModel.clearItems()
        bumpReloadToken()

        let tags = selectedWorkshopTag.map { [$0.name] } ?? []
        let searchQuery = query ?? workshopSearchQuery
        await viewModel.loadWorkshopWithFilters(
            query: searchQuery,
            tags: tags,
            type: selectedWorkshopType,
            contentLevel: selectedWorkshopContentLevel,
            resolution: selectedWorkshopResolution?.tagValue
        )
        bumpReloadToken()
    }

    @ViewBuilder
    private var categorySection: some View {
        if workshopSourceManager.activeSource == .wallpaperEngine {
            workshopTypeSection
        } else {
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
                        isSelected: selectedWorkshopTag?.id == tag.id
                    ) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            if selectedWorkshopTag?.id == tag.id {
                                selectedWorkshopTag = nil
                            } else {
                                selectedWorkshopTag = tag
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
        // [强制规则] 内容级别已写死为 SFW (Everyone)，不在 UI 中显示筛选
        EmptyView()
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
        Array(WorkshopSourceManager.WorkshopContentLevel.allCases)
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
                                selectedWorkshopTag = nil
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
        enum Kind { case type, tag, resolution }
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
        if let tag = selectedWorkshopTag {
            chips.append(WorkshopFilterChipData(
                id: "tag_\(tag.id)",
                title: tag.displayName,
                accentHex: tag.accentColors.first ?? "FFFFFF",
                kind: .tag
            ))
        }
        // [强制规则] 内容级别已写死为 SFW (Everyone)，不在当前筛选中显示
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
            selectedWorkshopTag = nil
        case .resolution:
            selectedWorkshopResolution = nil
        }
        Task { await applyWorkshopFilters() }
    }

    private var contentHeader: some View {
        HStack(alignment: .center) {
            Text("\(formattedCount(viewModel.items.count)) \(t("media.count")) · \(t("media.loaded")) \(formattedCount(viewModel.items.count))")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(arcSettings.secondaryText.opacity(0.64))

            Spacer()

            if workshopSourceManager.activeSource == .wallpaperEngine {
                SortMenu(options: WorkshopSortOption.allCases, selected: $selectedWorkshopSort, tint: exploreAtmosphere.tint.primary)
            }
        }
    }

    // MARK: - Grid

    private func mediaGrid(contentWidth: CGFloat) -> some View {
        let columnCount = contentWidth > 1200 ? 4 : (contentWidth > 800 ? 3 : 2)

        return ExploreGridContainer(
            itemCount: { viewModel.items.count },
            aspectRatio: { _ in
                let spacing: CGFloat = 16
                let totalSpacing = spacing * CGFloat(columnCount - 1)
                let cardWidth = floor((contentWidth - totalSpacing) / CGFloat(columnCount))
                return MediaItem.effectiveAspectRatio(columnWidth: cardWidth)
            },
            configureCell: { cell, index in
                guard index < viewModel.items.count else { return }
                let item = viewModel.items[index]
                cell.configure(with: item, isFavorite: viewModel.isFavorite(item))
            },
            cellClass: MediaGridCell.self,
            onSelect: { index in
                guard index < viewModel.items.count else { return }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    selectedMedia = viewModel.items[index]
                }
            },
            onVisibleItemsChange: { indexPaths in
                prefetchVisibleMediaDetails(indexPaths: indexPaths)
            },
            onScrollOffsetChange: { offset in
                gridSavedScrollOffset = offset
                let shouldShow = offset > 300
                if showScrollToTop != shouldShow { showScrollToTop = shouldShow }
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
            layoutWidth: contentWidth,
            gridColumnCount: columnCount,
            hoverExpansionAllowance: 8
        )
    }

    private func bumpReloadToken() {
        cancelScheduledGridVisibleRefresh()
        gridReloadToken &+= 1
    }

    private func scheduleGridVisibleRefresh(delayNanoseconds: UInt64 = 120_000_000) {
        gridRefreshTask?.cancel()
        gridRefreshTask = Task {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled else { return }
            gridReloadToken &+= 1
            gridRefreshTask = nil
        }
    }

    private func cancelScheduledGridVisibleRefresh() {
        gridRefreshTask?.cancel()
        gridRefreshTask = nil
    }

    private func prefetchVisibleMediaDetails(indexPaths: Set<IndexPath>) {
        guard workshopSourceManager.activeSource != .wallpaperEngine else { return }

        let candidates = indexPaths
            .map(\.item)
            .filter { $0 >= 0 && $0 < viewModel.items.count }
            .sorted()
            .prefix(6)
            .compactMap { index -> MediaItem? in
                let item = viewModel.items[index]
                return item.posterURL == nil ? item : nil
            }

        guard !candidates.isEmpty else { return }
        viewModel.enqueueDetailPrefetch(for: Array(candidates), prioritizeVisible: true)
    }

    // MARK: - UI Components

    private var emptyState: some View {
        Group {
            if let errorMessage = viewModel.errorMessage {
                ErrorStateView(
                    type: viewModel.networkStatus.connectionState == .offline ? .offline : .network,
                    message: errorMessage,
                    retryAction: { Task { await viewModel.loadHomeFeed() } }
                )
            } else {
                ErrorStateView(
                    type: .empty,
                    title: t("noMediaFilter"),
                    message: t("tryDifferentFilter"),
                    retryAction: { Task { await viewModel.loadHomeFeed() } }
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
        cancelScheduledGridVisibleRefresh()
        if viewModel.items.isEmpty {
            isInitialLoading = true
        }
        await viewModel.initialLoadIfNeeded()
        if searchText.isEmpty {
            searchText = viewModel.currentQuery
        }
        syncAtmosphereIfNeeded()
        isInitialLoading = false
    }

    private func performFirstAppearanceLoad() async {
        cancelScheduledGridVisibleRefresh()
        isInitialLoading = true
        searchText = ""
        mediaSearchQuery = ""
        translationBridge.reset()
        selectedHotTag = nil
        selectedWorkshopTag = nil
        selectedWorkshopType = .all
        selectedWorkshopContentLevel = .everyone
        selectedWorkshopResolution = nil
        selectedWorkshopSort = .trendWeek
        selectedCategory = .all
        selectedSort = .newest
        lastSyncedFirstItemID = nil
        loadMoreFailed = false
        viewModel.errorMessage = nil

        if workshopSourceManager.activeSource == .wallpaperEngine {
            await viewModel.loadWorkshopFeed()
        } else {
            await viewModel.loadHomeFeed()
        }

        syncAtmosphereIfNeeded()
        isInitialLoading = false
        isFirstAppearance = false
    }

    private func selectCategory(_ category: MediaCategory) {
        withAnimation(AppFluidMotion.interactiveSpring) {
            selectedCategory = category
            selectedHotTag = nil
            selectedWorkshopTag = nil
            selectedWorkshopType = .all
            selectedWorkshopContentLevel = .everyone
            searchText = ""
        }

        lastSyncedFirstItemID = nil
        // 清空 ViewModel 数据避免显示旧数据
        viewModel.clearItems()
        bumpReloadToken()

        searchTask?.cancel()
        searchTask = Task {
            if workshopSourceManager.activeSource == .wallpaperEngine {
                // Workshop 模式下，加载 Workshop 内容
                await viewModel.loadWorkshopFeed()
            } else if category == .all {
                await viewModel.loadHomeFeed()
            } else {
                await viewModel.loadTagFeed(slug: category.slug, title: category.title)
            }
            await MainActor.run { bumpReloadToken() }
        }
    }

    private func submitSearch(with query: String? = nil) {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        // BG 源：中文翻译处理（仅在无外部 query 时触发）
        if query == nil && workshopSourceManager.activeSource != .wallpaperEngine && !trimmed.isEmpty {
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
        selectedCategory = .all
        selectedHotTag = nil
        searchTask?.cancel()
        bumpReloadToken()
        searchTask = Task {
            if workshopSourceManager.activeSource == .wallpaperEngine {
                await applyWorkshopFilters(query: query)
            } else {
                await viewModel.search(query: query)
            }
            await MainActor.run {
                bumpReloadToken()
                searchTask = nil
            }
        }
    }

    private func handleTranslationCompleted() {
        guard workshopSourceManager.activeSource != .wallpaperEngine else { return }
        guard let pending = pendingSearchText else { return }
        pendingSearchText = nil
        let query = translationBridge.effectiveQuery(for: pending)
        mediaSearchQuery = query
        executeSearch(query: query)
    }

    private func handleFilterChange() {
        // Workshop 模式下不支持标签过滤
        if workshopSourceManager.activeSource == .wallpaperEngine {
            syncAtmosphereIfNeeded()
            return
        }

        if let hotTag = selectedHotTag, hotTag.isServerSide,
           let slug = hotTag.serverSlug {
            Task {
                await viewModel.loadTagFeed(slug: slug, title: hotTag.title)
                await MainActor.run { bumpReloadToken() }
            }
            return
        }

        if selectedHotTag != nil && viewModel.items.isEmpty {
            Task {
                await viewModel.loadHomeFeed()
                await MainActor.run {
                    syncAtmosphereIfNeeded()
                    bumpReloadToken()
                }
            }
            return
        }

        syncAtmosphereIfNeeded()
    }

    private func handleWorkshopSortChange() {
        AppLogger.info(.wallpaper, "Workshop 排序变化", metadata: ["排序": selectedWorkshopSort.rawValue])
        searchTask?.cancel()
        searchTask = Task {
            await viewModel.setWorkshopSort(
                sortBy: selectedWorkshopSort.sortBy,
                days: selectedWorkshopSort.days
            )
            await MainActor.run {
                bumpReloadToken()
                searchTask = nil
            }
        }
    }

    private func handleSourceChange() {
        // 数据源切换时重置并重新加载
        resetAllFilters(reloadData: true)
        bumpReloadToken()
    }

    private func triggerLoadMore() {
        guard viewModel.hasMorePages,
              !viewModel.isLoading,
              !isLoadingMore,
              !viewModel.isLoadingMore else { return }

        isLoadingMore = true
        loadMoreFailed = false
        loadMoreTask?.cancel()
        loadMoreTask = Task {
            if workshopSourceManager.activeSource == .wallpaperEngine {
                await viewModel.loadMoreWorkshop()
            } else {
                await viewModel.loadMore()
            }
            await MainActor.run {
                if viewModel.hasMorePages && viewModel.errorMessage != nil {
                    loadMoreFailed = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    isLoadingMore = false
                }
            }
            loadMoreTask = nil
        }
    }

    private func handleLoadMoreSentinelPosition(_ sentinelMinY: CGFloat, viewportHeight: CGFloat) {
        guard isVisible, viewportHeight > 0, sentinelMinY.isFinite else { return }
        if sentinelMinY <= viewportHeight + Self.loadMoreTriggerThreshold {
            triggerLoadMore()
        }
    }

    private func resetAllFilters(reloadData: Bool = false) {
        searchText = ""
        mediaSearchQuery = ""
        translationBridge.reset()
        selectedHotTag = nil
        selectedWorkshopTag = nil
        selectedWorkshopType = .all
        selectedWorkshopContentLevel = .everyone
        selectedWorkshopResolution = nil
        selectedWorkshopSort = .trendWeek
        selectedCategory = .all
        selectedSort = .newest
        lastSyncedFirstItemID = nil
        loadMoreFailed = false
        viewModel.errorMessage = nil
        bumpReloadToken()

        if reloadData {
            searchTask?.cancel()
            searchTask = Task {
                if workshopSourceManager.activeSource == .wallpaperEngine {
                    await viewModel.loadWorkshopFeed()
                } else {
                    await viewModel.loadHomeFeed()
                }
                await MainActor.run {
                    bumpReloadToken()
                    searchTask = nil
                }
            }
        }
    }

    private func cancelTasks() {
        searchTask?.cancel()
        loadMoreTask?.cancel()
        cancelScheduledGridVisibleRefresh()
        searchTask = nil
        loadMoreTask = nil
    }

    private func syncAtmosphereIfNeeded() {
        let items = viewModel.items
        let newFirstID = items.first?.id
        guard newFirstID != lastSyncedFirstItemID else { return }
        lastSyncedFirstItemID = newFirstID
        exploreAtmosphere.updateFirstMedia(items.first)
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
