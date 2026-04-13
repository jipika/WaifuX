import SwiftUI
import AppKit
import Kingfisher

// MARK: - WallpaperExploreContentView - 壁纸探索页

struct WallpaperExploreContentView: View {
    @ObservedObject var viewModel: WallpaperViewModel
    @Binding var selectedWallpaper: Wallpaper?
    var isVisible: Bool = true
    @StateObject private var exploreAtmosphere = ExploreAtmosphereController(wallpaperMode: true)

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
    @State private var displayedItems: [Wallpaper] = []
    @State private var isLoadingMore = false
    @State private var isInitialLoading = false
    @State private var scrollOffset: CGFloat = 0
    @State private var contentSize: CGFloat = 0
    @State private var containerSize: CGFloat = 0
    @State private var visibleCardIDs: Set<String> = []
    @State private var showAPIKeyAlert = false
    @State private var isFirstAppearance = true
    @State private var loadMoreFailed = false

    private var loadMoreTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geometry in
            let contentWidth = calculateContentWidth(geometry: geometry)
            let gridConfig = WallpaperGridConfig(contentWidth: contentWidth)

            ZStack {
                // 背景放在 ScrollView 同级底层，避免滚动耦合重绘
                if isVisible {
                    ExploreDynamicAtmosphereBackground(
                        tint: exploreAtmosphere.tint,
                        referenceImage: exploreAtmosphere.referenceImage,
                        lightweightBackdrop: false
                    )
                    .ignoresSafeArea()
                }

                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        heroSection
                        categorySection
                        filterSection
                        activeFiltersSection
                        contentSection(config: gridConfig)
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 80)
                    .padding(.bottom, 48)
                    .frame(width: geometry.size.width, alignment: .center)
                    .background(scrollTrackingOverlay)
                    .background(contentSizeTrackingOverlay)
                    .environment(\.explorePageAtmosphereTint, exploreAtmosphere.tint)
                }
                .coordinateSpace(name: "exploreScroll")
                .iosSmoothScroll()
                .modifier(ScrollLoadMoreModifier(
                    scrollOffset: $scrollOffset,
                    contentSize: $contentSize,
                    containerSize: $containerSize,
                    earlyThreshold: 800,
                    bottomThreshold: 100,
                    onLoadMore: triggerLoadMore,
                    checkLoadMore: checkLoadMore
                ))
                .disabled(isInitialLoading)

                // 底部弹出加载卡片（解决列表高度抖动问题）
                VStack {
                    Spacer()
                    if loadMoreFailed {
                        BottomLoadingFailedCard {
                            loadMoreFailed = false
                            Task { await viewModel.loadMore() }
                        }
                        .padding(.bottom, 60)
                    } else if isLoadingMore || (viewModel.isLoading && !displayedItems.isEmpty) {
                        BottomLoadingCard(isLoading: true)
                            .padding(.bottom, 60)
                    } else if !isLoadingMore && !viewModel.hasMorePages && !displayedItems.isEmpty {
                        BottomNoMoreCard()
                            .padding(.bottom, 60)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
        // 移除 API Key 弹窗提示
        .onAppear {
            if isFirstAppearance {
                resetAllFilters(reloadData: true)
                isFirstAppearance = false
            } else {
                handleAppear()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .wallpaperDataSourceChanged)) { _ in
            handleDataSourceChange()
        }
        .onChange(of: category) { _, _ in handleCategoryChange() }
        .onChange(of: fourKCategory) { _, _ in handle4KCategoryChange() }
        .onChange(of: hotTag) { _, _ in handleHotTagChange() }
        .onChange(of: viewModel.sortingOption) { _, _ in handleSortingChange() }
        .onChange(of: fourKSorting) { _, _ in handle4KSortingChange() }
        .onChange(of: viewModel.wallpapers) { old, new in handleWallpapersChange(old: old, new: new) }
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
                    .foregroundStyle(.white.opacity(0.58))

                Text(WallpaperSourceManager.shared.activeSource.displayName)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.72))
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .liquidGlassSurface(
                        .regular,
                        tint: exploreAtmosphere.tint.primary.opacity(0.12),
                        in: Capsule(style: .continuous)
                    )

                // 切换源按钮
                Button {
                    let nextSource: WallpaperSourceManager.SourceType = WallpaperSourceManager.shared.activeSource == .wallhaven ? .fourKWallpapers : .wallhaven
                    WallpaperSourceManager.shared.switchTo(nextSource)
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.72))
                        .frame(width: 24, height: 20)
                        .liquidGlassSurface(
                            .regular,
                            tint: exploreAtmosphere.tint.primary.opacity(0.12),
                            in: Capsule(style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .help("切换到 \(WallpaperSourceManager.shared.activeSource == .wallhaven ? "4K Wallpapers" : "WallHaven")")
            }
            
            Text(t("wallpaperLibrary"))
                .font(.system(size: 32, weight: .bold, design: .serif))
                .tracking(-0.5)
                .foregroundStyle(.white.opacity(0.98))
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
                onClear: { searchText = ""; submitSearch() }
            )
            
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
                    .foregroundStyle(.white.opacity(0.42))
                
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
                .foregroundStyle(.white.opacity(0.46))
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
                .foregroundStyle(.white.opacity(0.46))
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
                        .foregroundStyle(.white.opacity(0.46))
                    Button(t("clear")) { resetServerFilters() }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.72))
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
            
            if viewModel.isLoading && displayedItems.isEmpty {
                WallpaperGridSkeleton(contentWidth: config.contentWidth)
                    .transition(.opacity.animation(.easeInOut(duration: 0.25)))
            } else if displayedItems.isEmpty {
                emptyState
                    .transition(.opacity.animation(.easeInOut(duration: 0.25)))
            } else {
                wallpaperGrid(config: config)
            }
        }
    }
    
    private var contentHeader: some View {
        HStack(alignment: .center) {
            Text("\(displayedItems.count) \(t("wallpaperCount"))")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white.opacity(0.66))
            
            Spacer()
            
            if viewModel.currentSourceSupportsWallhavenSorting {
                SortMenu(options: SortingOption.allCases, selected: $viewModel.sortingOption, tint: exploreAtmosphere.tint.primary)
            } else {
                SortMenu(options: FourKSortingOption.allCases, selected: $fourKSorting, tint: exploreAtmosphere.tint.primary)
            }
        }
    }

    // MARK: - Grid & Cards

    private func wallpaperGrid(config: WallpaperGridConfig) -> some View {
        LazyVGrid(columns: config.gridItems, alignment: .leading, spacing: config.spacing) {
            // 使用稳定 ID 优化 SwiftUI 渲染循环
            ForEach(displayedItems) { wallpaper in
                let index = displayedItems.firstIndex(where: { $0.id == wallpaper.id }) ?? 0
                WallpaperCard(
                    wallpaper: wallpaper,
                    isFavorite: viewModel.isFavorite(wallpaper),
                    index: index,
                    cardWidth: config.cardWidth
                    // 移除 cardHeight，让卡片自动计算
                )
                .onTapGesture {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        selectedWallpaper = wallpaper
                    }
                }
                .onAppear {
                    // 移除动画触发，直接显示
                    visibleCardIDs.insert(wallpaper.id)
                    preloadNearbyImages(for: index, config: config)
                }
                // 移除入场动画和滚动效果
                // .cardEntrance(...)
                // .scrollTransitionEffect()
            }
        }
        // 移除强制高度，解决空白问题
        // .frame(height: config.calculateTotalHeight(itemCount: displayedItems.count))
    }
    
    /// 智能预加载附近图片（前后各 10 张）
    private func preloadNearbyImages(for index: Int, config: WallpaperGridConfig) {
        // 使用固定比例计算高度 (10:6)
        let imageHeight = config.cardWidth * 0.6
        let targetSize = CGSize(width: config.cardWidth * 2, height: imageHeight * 2)
        let range = max(0, index - 10)..<min(displayedItems.count, index + 11)
        let urls = range
            .filter { $0 != index }
            .compactMap { displayedItems[$0].thumbURL }

        let prefetcher = Kingfisher.ImagePrefetcher(
            urls: urls,
            options: [.processor(DownsamplingImageProcessor(size: targetSize))]
        )
        prefetcher.start()
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
        .liquidGlassSurface(
            .prominent,
            tint: exploreAtmosphere.tint.primary.opacity(0.14),
            in: RoundedRectangle(cornerRadius: 30, style: .continuous)
        )
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
            .foregroundStyle(.white.opacity(hasRatio ? 0.95 : 0.7))
            .padding(.horizontal, 12)
            .frame(height: 30)
            .liquidGlassSurface(
                hasRatio ? .prominent : .subtle,
                tint: hasRatio ? exploreAtmosphere.tint.primary.opacity(0.15) : nil,
                in: Capsule(style: .continuous)
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
    
    private var scrollTrackingOverlay: some View {
        GeometryReader { scrollProxy in
            Color.clear.preference(
                key: ExploreScrollOffsetKey.self,
                value: -scrollProxy.frame(in: .named("exploreScroll")).minY
            )
        }
    }
    
    private var contentSizeTrackingOverlay: some View {
        GeometryReader { contentProxy in
            Color.clear.preference(
                key: ExploreContentSizeKey.self,
                value: contentProxy.size.height
            )
        }
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
                // 请求完数据后重置 visibleCardIDs，避免脏数据
                await MainActor.run {
                    visibleCardIDs.removeAll()
                    rebuildVisibleItems()
                    syncAtmosphere()
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
            visibleCardIDs.removeAll()
            rebuildVisibleItems()
            syncAtmosphere()
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
        displayedItems = []
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

    private func handleWallpapersChange(old: [Wallpaper], new: [Wallpaper]) {
        AppLogger.debug(.wallpaper, "wallpapers 数据变化",
            metadata: ["旧数量": old.count, "新数量": new.count, "当前显示": displayedItems.count])
        
        if new.isEmpty || displayedItems.isEmpty {
            rebuildVisibleItems()
        } else if !old.isEmpty, new.count > old.count {
            appendNewItems()
        } else {
            rebuildVisibleItems()
        }
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

    private func checkLoadMore(offset: CGFloat, contentHeight: CGFloat, containerHeight: CGFloat) {
        guard viewModel.hasMorePages else { return }
        guard !viewModel.isLoading, !isLoadingMore else { return }

        // 计算距离底部距离
        let distanceToBottom = contentHeight - (offset + containerHeight)

        // 双阈值策略：
        // 1. 提前加载（距离底部 < 800pt）- 正常预加载
        // 2. 触底保底（距离底部 < 100pt）- 保底机制
        let shouldLoadEarly = distanceToBottom < 800 && distanceToBottom > 100
        let shouldLoadBottom = distanceToBottom < 100

        guard shouldLoadEarly || shouldLoadBottom else { return }

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

    private func submitSearch() {
        hotTag = nil
        viewModel.searchQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        reloadData()
    }

    private func reloadData() {
        AppLogger.info(.wallpaper, "重新搜索：用户操作触发")
        displayedItems = []
        visibleCardIDs.removeAll()
        loadMoreFailed = false
        viewModel.errorMessage = nil
        // 清空 ViewModel 的数据，确保数据源切换时不显示旧数据
        viewModel.wallpapers.removeAll()
        Task { await viewModel.search() }
    }

    private func rebuildVisibleItems() {
        if viewModel.currentSourceSupportsWallhavenCategories {
            displayedItems = viewModel.wallpapers.filter { matchesCategory($0, category: category) }
        } else {
            displayedItems = viewModel.wallpapers
        }
        syncAtmosphere()
    }

    private func appendNewItems() {
        let existingIDs = Set(displayedItems.map(\.id))
        let newItems = viewModel.wallpapers.filter { !existingIDs.contains($0.id) }
        guard !newItems.isEmpty else { return }
        displayedItems.append(contentsOf: newItems)
    }

    private func resetAllFilters(reloadData: Bool = false) {
        searchText = ""
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
        displayedItems = []
        visibleCardIDs.removeAll()
        loadMoreFailed = false
        viewModel.errorMessage = nil

        if reloadData {
            viewModel.wallpapers.removeAll()
            Task { await viewModel.search() }
        }
    }

    private func syncAtmosphere() {
        exploreAtmosphere.updateFirstWallpaper(displayedItems.first)
    }

    private func animateCardAppearance(id: String, index: Int) {
        // 直接插入，不使用动画
        visibleCardIDs.insert(id)
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
    var requiresAPIKey: Bool { self != .sfw }
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

private struct FilterChip: View {
    let title: String
    let subtitle: String
    let isSelected: Bool
    let tint: Color
    let action: () -> Void
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.94))
                Text(subtitle).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.55))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: 16, style: .continuous).fill(tint.opacity(isSelected ? 0.15 : 0.08))
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(tint.opacity(isSelected ? 0.4 : 0.2), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(AppFluidMotion.hoverEase, value: isHovered)
        .onHover { isHovered = $0 }
    }
}

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
                    .foregroundStyle(.white.opacity(0.94))
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
                    Text(chip.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.94))
                    if let subtitle = chip.subtitle {
                        Text(subtitle).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(.white.opacity(0.56))
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

                Text(name).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(isSelected ? 0.96 : 0.84)).lineLimit(1)
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

// MARK: - WallpaperCard (Kingfisher 高性能版)

private struct WallpaperCard: View {
    let wallpaper: Wallpaper
    let isFavorite: Bool
    let index: Int
    let cardWidth: CGFloat
    // 移除 cardHeight 参数，使用固定比例
    
    @State private var isHovered = false
    
    // 固定图片比例 10:6 (5:3)
    private var imageHeight: CGFloat {
        cardWidth * 0.6
    }
    
    // 文字区域高度
    private var textAreaHeight: CGFloat { 44 }

    // 降采样目标尺寸（Retina 2x）
    private var targetImageSize: CGSize {
        CGSize(width: cardWidth * 2, height: imageHeight * 2)
    }
    
    private var purityBorderColor: Color? {
        switch wallpaper.purity.lowercased() {
        case "nsfw": return Color(hex: "FF3B30")
        case "sketchy": return Color(hex: "FFB347")
        default: return nil
        }
    }
    
    private var borderColor: Color { purityBorderColor ?? Color.white.opacity(0.06) }
    private var borderWidth: CGFloat { purityBorderColor != nil ? 2 : 1 }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                // Kingfisher 高性能图片加载 - 移除问题配置
                KFImage(wallpaper.thumbURL ?? wallpaper.smallThumbURL)
                    .setProcessor(DownsamplingImageProcessor(size: targetImageSize))
                    .cacheMemoryOnly(false)
                    // 移除 cancelOnDisappear(false) 和 fade 避免闪烁和加载问题
                    .placeholder { _ in
                        placeholderGradient
                    }
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
            // 使用固定比例而非传入的高度
            .frame(width: cardWidth, height: imageHeight)
            .clipShape(UnevenRoundedRectangle(
                topLeadingRadius: 14, bottomLeadingRadius: 0,
                bottomTrailingRadius: 0, topTrailingRadius: 14,
                style: .continuous
            ))
            .overlay(alignment: .topLeading) {
                metadataRow.padding(10)
            }
            
            HStack(spacing: 12) {
                Text(wallpaper.uploader?.username ?? wallpaper.categoryDisplayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                Spacer(minLength: 12)
                trailingMetadata
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(width: cardWidth, height: textAreaHeight, alignment: .leading)
            .background(Color.black.opacity(0.46))
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.clear)
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(borderColor, lineWidth: borderWidth))
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.spring(response: 0.2, dampingFraction: 0.85), value: isHovered)
        .onHover { isHovered = $0 }
    }
    
    var metadataRow: some View {
        HStack(alignment: .top, spacing: 8) {
            metaTag(text: wallpaper.categoryDisplayName)
            metaTag(text: wallpaper.purityDisplayName)
            Spacer(minLength: 0)
            metaTag(text: wallpaper.resolution.replacingOccurrences(of: "x", with: "×"))
        }
    }
    
    var trailingMetadata: some View {
        HStack(spacing: 10) {
            if let hex = wallpaper.primaryColorHex { footerColorTag(hex: hex) }
            statLabel(systemImage: "heart.fill", value: compactNumber(wallpaper.favorites), tint: isFavorite ? Color(hex: "FF5A7D") : .white.opacity(0.5))
            statLabel(systemImage: "eye.fill", value: compactNumber(wallpaper.views), tint: .white.opacity(0.5))
        }
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }
    
    func metaTag(text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.4))
            .clipShape(Capsule())
    }
    
    func footerColorTag(hex: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(Color(hex: "#\(hex)")).frame(width: 8, height: 8)
                .overlay(Circle().stroke(Color.white.opacity(0.22), lineWidth: 0.5))
            Text("#\(hex)").font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(.white.opacity(0.85))
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(Color.black.opacity(0.22), in: Capsule(style: .continuous))
    }
    
    func statLabel(systemImage: String, value: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage).font(.system(size: 10, weight: .bold))
            Text(value).font(.system(size: 11, weight: .semibold, design: .monospaced))
        }
        .foregroundStyle(tint)
    }
    
    var placeholderGradient: some View {
        LinearGradient(
            colors: [Color(hex: "1C2431"), Color(hex: "233B5A"), Color(hex: "14181F")],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        .overlay {
            Image(systemName: "photo.fill")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.white.opacity(0.18))
        }
    }
    
    func compactNumber(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return "\(value)"
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
