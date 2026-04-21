import SwiftUI
import AppKit
import Kingfisher

// MARK: - MediaExploreContentView - 媒体探索页

struct MediaExploreContentView: View {
    @ObservedObject var viewModel: MediaExploreViewModel
    @Binding var selectedMedia: MediaItem?
    var isVisible: Bool = true
    @StateObject private var exploreAtmosphere = ExploreAtmosphereController(wallpaperMode: false)
    @StateObject private var workshopSourceManager = WorkshopSourceManager.shared

    @State private var selectedCategory: MediaCategory = .all
    @State private var selectedHotTag: MediaHotTag?
    @State private var selectedSort: MediaSortOption = .newest
    @State private var searchText = ""
    @State private var isLoadingMore = false
    @State private var isInitialLoading = false
    @State private var scrollOffset: CGFloat = 0
    @State private var contentSize: CGFloat = 0
    @State private var containerSize: CGFloat = 0
    @State private var visibleCardIDs: Set<String> = []
    @State private var isFirstAppearance = true
    @State private var loadMoreFailed = false
    @State private var gridImagePrefetcher: ImagePrefetcher?
    @State private var lastPrefetchCenterIndex: Int = -1
    @State private var lastSyncedFirstItemID: String?

    @State private var searchTask: Task<Void, Never>?
    @State private var loadMoreTask: Task<Void, Never>?

    /// 缓存筛选/排序后的列表，避免每次 body（含滚动、`isLoading` 等）都对 `items` 全表 filter/sort，减轻 AttributeGraph 压力。
    @State private var visibleMediaItems: [MediaItem] = []

    // Workshop 筛选
    @State private var selectedWorkshopTag: WorkshopSourceManager.WorkshopTag?
    @State private var selectedWorkshopType: WorkshopSourceManager.WorkshopTypeFilter = .all
    @State private var selectedWorkshopContentLevel: WorkshopSourceManager.WorkshopContentLevel? = .everyone
    @State private var workshopSearchQuery: String = ""
    @State private var selectedWorkshopSort: WorkshopSortOption = .trendWeek
    private var workshopService: WorkshopService {
        WorkshopService.shared
    }

    var body: some View {
        GeometryReader { geometry in
            let gridContentWidth = max(0, geometry.size.width - 56)

            ZStack {
                ExploreDynamicAtmosphereBackground(
                    tint: exploreAtmosphere.tint,
                    referenceImage: exploreAtmosphere.referenceImage,
                    lightweightBackdrop: true
                )
                .ignoresSafeArea()

                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        heroSection
                        categorySection
                        if workshopSourceManager.activeSource == .wallpaperEngine {
                            filterSection
                            workshopTagsSection
                            activeFiltersSection
                        }
                        contentSection(gridContentWidth: gridContentWidth)
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 80)
                    .padding(.bottom, 48)
                    .frame(width: geometry.size.width, alignment: .leading)
                    .background(scrollTrackingOverlay)
                    .background(contentSizeTrackingOverlay)
                    .environment(\.explorePageAtmosphereTint, exploreAtmosphere.tint)
                }
                .coordinateSpace(name: "exploreScroll")
                .iosSmoothScroll()
                .scrollDisabled(!isVisible)
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

                VStack {
                    Spacer()
                    if loadMoreFailed {
                        BottomLoadingFailedCard {
                            loadMoreFailed = false
                            Task { await viewModel.loadMore() }
                        }
                        .padding(.bottom, 60)
                    } else if isLoadingMore || (viewModel.isLoading && !visibleMediaItems.isEmpty) {
                        BottomLoadingCard(isLoading: true)
                            .padding(.bottom, 60)
                    } else if !isLoadingMore && !viewModel.hasMorePages && !visibleMediaItems.isEmpty {
                        BottomNoMoreCard()
                            .padding(.bottom, 60)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
        .onAppear {
            if isFirstAppearance {
                resetAllFilters(reloadData: true)
                isFirstAppearance = false
            } else {
                Task { await handleInitialLoad() }
            }
        }
        .onChange(of: isVisible) { _, visible in
            if !visible {
                cancelTasks()
                gridImagePrefetcher?.stop()
            }
        }
        .onChange(of: selectedHotTag) { _, _ in handleFilterChange() }
        .onChange(of: selectedSort) { _, _ in handleFilterChange() }
        .onChange(of: selectedWorkshopSort) { _, _ in handleWorkshopSortChange() }
        .onChange(of: searchText) { _, _ in handleFilterChange() }
        .onChange(of: viewModel.items) { _, _ in
            recomputeVisibleMediaItems()
            syncAtmosphereIfNeeded()
        }
        .onChange(of: viewModel.libraryContentRevision) { _, _ in
            recomputeVisibleMediaItems()
        }
        .onReceive(NotificationCenter.default.publisher(for: .workshopSourceChanged)) { _ in
            handleSourceChange()
        }
    }

    // MARK: - Sections

    private var heroSection: some View {
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
                    .foregroundStyle(.white.opacity(0.56))

                // 当前源标签
                Text(workshopSourceManager.activeSource.displayName)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.72))
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
                        .foregroundStyle(.white.opacity(0.72))
                        .frame(width: 24, height: 20)
                        .exploreFrostedCapsule(
                            tint: exploreAtmosphere.tint.primary,
                            material: .ultraThinMaterial,
                            tintLayerOpacity: 0.06
                        )
                }
                .buttonStyle(.plain)
                .help("切换到 \(workshopSourceManager.activeSource == .motionBG ? t("wallpaperEngine") : "MotionBG")")
            }

            Text(t("exploreMedia"))
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
                onSubmit: { submitSearch() },
                onClear: { submitSearch(with: "") }
            )
            
            ResetFiltersButton(tint: exploreAtmosphere.tint.secondary) {
                resetAllFilters(reloadData: true)
            }
        }
        .frame(maxWidth: 520)
    }
    
    private var hotTagsRow: some View {
        motionBGTagsRow
    }

    private var motionBGTagsRow: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(t("hotWallpaper") + ":")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))

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

    private func applyWorkshopFilters() async {
        viewModel.clearItems()

        let tags = selectedWorkshopTag.map { [$0.name] } ?? []
        await viewModel.loadWorkshopWithFilters(
            query: workshopSearchQuery,
            tags: tags,
            type: selectedWorkshopType,
            contentLevel: selectedWorkshopContentLevel
        )
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
                .foregroundStyle(.white.opacity(0.46))
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
            }
        }
    }

    private var workshopTagsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(t("tags"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.46))
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
        if workshopSourceManager.activeSource == .wallpaperEngine {
            VStack(alignment: .leading, spacing: 10) {
                Text(t("contentLevel"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.46))
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
                                    selectedWorkshopContentLevel = nil
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
                            .foregroundStyle(.white.opacity(0.46))
                        Button(t("clear")) {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                selectedWorkshopTag = nil
                                selectedWorkshopContentLevel = .everyone
                                selectedWorkshopType = .all
                                Task { await applyWorkshopFilters() }
                            }
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.72))
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
        enum Kind { case type, tag, contentLevel }
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
        if let level = selectedWorkshopContentLevel {
            chips.append(WorkshopFilterChipData(
                id: "level_\(level.id)",
                title: level.title,
                accentHex: level.accentHex,
                kind: .contentLevel
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
        case .contentLevel:
            selectedWorkshopContentLevel = .everyone
        }
        Task { await applyWorkshopFilters() }
    }

    private func contentSection(gridContentWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            contentHeader
                .zIndex(1)
            
            if viewModel.isLoading && visibleMediaItems.isEmpty {
                MediaGridSkeleton(contentWidth: gridContentWidth)
                    .transition(.opacity.animation(.easeInOut(duration: 0.3)))
            } else if visibleMediaItems.isEmpty {
                emptyState
                    .transition(.opacity.animation(.easeInOut(duration: 0.3)))
            } else {
                mediaGrid(contentWidth: gridContentWidth)
            }
        }
    }
    
    private var contentHeader: some View {
        HStack(alignment: .center) {
            Text("\(formattedCount(visibleMediaItems.count)) \(t("media.count")) · \(t("media.loaded")) \(formattedCount(viewModel.items.count))")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.64))

            Spacer()

            if workshopSourceManager.activeSource == .wallpaperEngine {
                SortMenu(options: WorkshopSortOption.allCases, selected: $selectedWorkshopSort, tint: exploreAtmosphere.tint.primary)
            } else {
                SortMenu(options: MediaSortOption.allCases, selected: $selectedSort, tint: exploreAtmosphere.tint.primary)
            }
        }
    }

    // MARK: - Grid

    private func mediaGrid(contentWidth: CGFloat) -> some View {
        let config = GridConfig(contentWidth: contentWidth, columns: contentWidth > 1200 ? 4 : (contentWidth > 800 ? 3 : 2), baseRatio: 0.6)
        
        return LazyVGrid(columns: config.columns, alignment: .leading, spacing: config.spacing) {
            ForEach(visibleMediaItems) { item in
                SimpleMediaCard(
                    item: item,
                    cardWidth: config.cardWidth,
                    isFavorite: viewModel.isFavorite(item),
                    onTap: { selectedMedia = item }
                )
                .onAppear {
                    visibleCardIDs.insert(item.id)
                    preloadNearbyImages(around: item, config: config)
                }
                // 移除入场动画和滚动效果，解决卡顿和空白问题
                // .cardEntrance(...)
                // .scrollTransitionEffect()
            }
        }
        // 移除强制高度，让 LazyVGrid 自然布局，解决空白问题
        // .frame(height: config.calculateHeight(itemCount: displayedItems.count, extraHeight: 40))
    }
    
    /// 智能预加载附近图片（前后各 8 张）；中心索引节流减少 Prefetcher 抖动
    private func preloadNearbyImages(around item: MediaItem, config: GridConfig) {
        let items = visibleMediaItems
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        if lastPrefetchCenterIndex >= 0, abs(index - lastPrefetchCenterIndex) < 4 { return }
        lastPrefetchCenterIndex = index

        let imageHeight = config.cardWidth * 0.625
        let targetSize = CGSize(width: config.cardWidth * 2, height: imageHeight * 2)
        let count = items.count
        guard count > 0 else { return }
        let clamped = min(max(0, index), count - 1)
        let lower = max(0, clamped - 8)
        let upper = min(count, clamped + 9)
        guard lower < upper else { return }
        let range = lower..<upper
        // 列表封面统一为 KFImage + 降采样静态帧，GIF 可与静图一同预取
        let urls = range
            .filter { $0 != clamped }
            .map { items[$0] }
            .map(\.coverImageURL)

        gridImagePrefetcher?.stop()
        let prefetcher = ImagePrefetcher(
            urls: urls,
            options: [.processor(DownsamplingImageProcessor(size: targetSize))]
        )
        gridImagePrefetcher = prefetcher
        prefetcher.start()
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

    private func handleInitialLoad() async {
        if viewModel.items.isEmpty {
            isInitialLoading = true
        }
        await viewModel.initialLoadIfNeeded()
        // 请求完数据后重置 visibleCardIDs，避免脏数据
        visibleCardIDs.removeAll()
        if searchText.isEmpty {
            searchText = viewModel.currentQuery
        }
        lastPrefetchCenterIndex = -1
        recomputeVisibleMediaItems()
        syncAtmosphereIfNeeded()
        isInitialLoading = false
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

        lastPrefetchCenterIndex = -1
        lastSyncedFirstItemID = nil
        visibleCardIDs.removeAll()
        // 清空 ViewModel 数据避免显示旧数据
        viewModel.clearItems()

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
        }
    }

    private func submitSearch(with query: String? = nil) {
        let searchQuery = query ?? searchText
        if query != nil { searchText = "" }
        selectedCategory = .all
        selectedHotTag = nil
        selectedWorkshopTag = nil
        selectedWorkshopType = .all
        selectedWorkshopContentLevel = .everyone
        lastPrefetchCenterIndex = -1
        searchTask?.cancel()
        searchTask = Task {
            if workshopSourceManager.activeSource == .wallpaperEngine {
                await viewModel.searchWorkshop(query: searchQuery)
            } else {
                await viewModel.search(query: searchQuery)
            }
            await MainActor.run {
                viewModel.items.forEach { visibleCardIDs.insert($0.id) }
            }
            searchTask = nil
        }
    }

    private func handleFilterChange() {
        visibleCardIDs.removeAll()
        recomputeVisibleMediaItems()

        // Workshop 模式下不支持标签过滤
        if workshopSourceManager.activeSource == .wallpaperEngine {
            syncAtmosphereIfNeeded()
            return
        }

        if let hotTag = selectedHotTag, hotTag.isServerSide,
           let slug = hotTag.serverSlug {
            Task { await viewModel.loadTagFeed(slug: slug, title: hotTag.title) }
            return
        }

        if selectedHotTag != nil && viewModel.items.isEmpty {
            Task {
                await viewModel.loadHomeFeed()
                syncAtmosphereIfNeeded()
            }
            return
        }

        syncAtmosphereIfNeeded()
    }
    
    private func handleWorkshopSortChange() {
        AppLogger.info(.wallpaper, "Workshop 排序变化", metadata: ["排序": selectedWorkshopSort.rawValue])
        visibleCardIDs.removeAll()
        searchTask?.cancel()
        searchTask = Task {
            await viewModel.setWorkshopSort(
                sortBy: selectedWorkshopSort.sortBy,
                days: selectedWorkshopSort.days
            )
            await MainActor.run {
                viewModel.items.forEach { visibleCardIDs.insert($0.id) }
                searchTask = nil
            }
        }
    }

    private func handleSourceChange() {
        // 数据源切换时重置并重新加载
        resetAllFilters(reloadData: true)
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

    private func checkLoadMore(offset: CGFloat, contentHeight: CGFloat, containerHeight: CGFloat) {
        guard viewModel.hasMorePages else { return }
        guard !viewModel.isLoading, !isLoadingMore, !viewModel.isLoadingMore else { return }

        // 计算距离底部距离
        let distanceToBottom = contentHeight - (offset + containerHeight)

        // 双阈值策略：
        // 1. 提前加载（距离底部 < 800pt）- 正常预加载
        // 2. 触底保底（距离底部 < 100pt）- 保底机制
        let shouldLoadEarly = distanceToBottom < 800 && distanceToBottom > 100
        let shouldLoadBottom = distanceToBottom < 100

        guard shouldLoadEarly || shouldLoadBottom else { return }

        loadMoreTask?.cancel()
        isLoadingMore = true
        loadMoreFailed = false
        Task {
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
        }
    }

    private func resetAllFilters(reloadData: Bool = false) {
        searchText = ""
        selectedHotTag = nil
        selectedWorkshopTag = nil
        selectedWorkshopType = .all
        selectedWorkshopContentLevel = .everyone
        selectedWorkshopSort = .trendWeek
        selectedCategory = .all
        selectedSort = .newest
        viewModel.clearItems()
        lastPrefetchCenterIndex = -1
        lastSyncedFirstItemID = nil
        visibleCardIDs.removeAll()
        loadMoreFailed = false
        viewModel.errorMessage = nil
        recomputeVisibleMediaItems()

        if reloadData {
            searchTask?.cancel()
            searchTask = Task {
                if workshopSourceManager.activeSource == .wallpaperEngine {
                    await viewModel.loadWorkshopFeed()
                } else {
                    await viewModel.loadHomeFeed()
                }
                searchTask = nil
            }
        }
    }

    private func cancelTasks() {
        searchTask?.cancel()
        loadMoreTask?.cancel()
        searchTask = nil
        loadMoreTask = nil
    }

    private func syncAtmosphereIfNeeded() {
        let items = visibleMediaItems
        let newFirstID = items.first?.id
        guard newFirstID != lastSyncedFirstItemID else { return }
        lastSyncedFirstItemID = newFirstID
        exploreAtmosphere.updateFirstMedia(items.first)
    }

    private func recomputeVisibleMediaItems() {
        let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let sourceOrder = Dictionary(uniqueKeysWithValues: viewModel.items.enumerated().map { ($1.id, $0) })
        let filtered = viewModel.items.filter { item in
            let matchesSearch = trimmedQuery.isEmpty || item.matches(search: trimmedQuery)
            let matchesHotTag = selectedHotTag?.matches(item) ?? true
            return matchesSearch && matchesHotTag
        }
        visibleMediaItems = selectedSort.sort(items: filtered, sourceOrder: sourceOrder)
    }
    
    private func animateCardAppearance(id: String, index: Int) {
        // 直接插入，不使用动画，避免 CPU 占用
        visibleCardIDs.insert(id)
    }
    
    private func formattedCount(_ count: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal)
    }
}

// MARK: - Grid Configuration

private struct GridConfig {
    let columnCount: Int
    let spacing: CGFloat
    let cardWidth: CGFloat
    let columns: [GridItem]
    
    init(contentWidth: CGFloat, columns columnCount: Int, baseRatio: CGFloat, spacing: CGFloat = 16) {
        self.columnCount = columnCount
        self.spacing = spacing
        let totalSpacing = spacing * CGFloat(columnCount - 1)
        self.cardWidth = floor((contentWidth - totalSpacing) / CGFloat(columnCount))
        // 移除 cardHeight 计算，让卡片自动计算高度
        self.columns = Array(repeating: GridItem(.flexible(), spacing: spacing), count: columnCount)
    }
    
    // 移除强制高度计算方法
}

// MARK: - Models & Enums

private enum MediaSortOption: String, CaseIterable, SortOptionProtocol {
    case newest
    case title
    case format

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newest: return t("sort.newest")
        case .title: return t("sort.title2")
        case .format: return t("sort.format2")
        }
    }

    var menuTitle: String {
        switch self {
        case .newest: return t("sortByNewest")
        case .title: return t("sortByTitle")
        case .format: return t("sortByFormat")
        }
    }
    
    func sort(items: [MediaItem], sourceOrder: [String: Int]) -> [MediaItem] {
        switch self {
        case .newest:
            return items
        case .title:
            return items.sorted {
                let comparison = $0.title.localizedCaseInsensitiveCompare($1.title)
                return comparison == .orderedSame 
                    ? (sourceOrder[$0.id] ?? 0) < (sourceOrder[$1.id] ?? 0)
                    : comparison == .orderedAscending
            }
        case .format:
            return items.sorted {
                let comparison = $0.formatText.localizedCaseInsensitiveCompare($1.formatText)
                return comparison == .orderedSame
                    ? (sourceOrder[$0.id] ?? 0) < (sourceOrder[$1.id] ?? 0)
                    : comparison == .orderedDescending
            }
        }
    }
}

private enum MediaHotTag: String, CaseIterable, Identifiable {
    case fourK
    case hd
    case anime
    case rain
    case cyberpunk
    case nature
    case game
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fourK: return "4K"
        case .hd: return t("filter.hd")
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
        default: return nil
        }
    }
    
    func matches(_ item: MediaItem) -> Bool {
        switch self {
        case .fourK:
            let normalized = item.formatText.uppercased().replacingOccurrences(of: " ", with: "")
            if normalized.contains("3840X2160") || normalized.contains("4K") { return true }
            if let er = item.exactResolution, er.uppercased().contains("3840") { return true }
            return false
        case .hd:
            let normalized = item.formatText.uppercased().replacingOccurrences(of: " ", with: "")
            if normalized.contains("HD") || normalized.contains("1920X1080") || normalized.contains("1280X720") { return true }
            if let er = item.exactResolution,
               er.uppercased().contains("1920") || er.uppercased().contains("1280") { return true }
            return false
        default:
            return false
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

// MARK: - MediaItem Extension

private extension MediaItem {
    func matches(search query: String) -> Bool {
        let haystack = [
            title, sourceText, categoryName ?? "", formatText,
            tags.joined(separator: " ")
        ].joined(separator: " ").lowercased()
        return haystack.contains(query)
    }
}



// MARK: - SimpleMediaCard (Kingfisher 高性能版)

private struct SimpleMediaCard: View {
    let item: MediaItem
    var cardWidth: CGFloat
    let isFavorite: Bool
    let onTap: () -> Void

    @State private var isHovered = false

    private static let thumbShape = UnevenRoundedRectangle(
        topLeadingRadius: 14,
        bottomLeadingRadius: 0,
        bottomTrailingRadius: 0,
        topTrailingRadius: 14,
        style: .continuous
    )
    private static let cardShape = RoundedRectangle(cornerRadius: 16, style: .continuous)
    
    // 固定图片比例 16:10，高度自动计算
    private var imageHeight: CGFloat {
        cardWidth * 0.625  // 16:10 比例
    }
    
    // 文字区域高度
    private var textAreaHeight: CGFloat { 44 }

    // 降采样目标尺寸（Retina 2x）
    private var targetImageSize: CGSize {
        CGSize(width: cardWidth * 2, height: imageHeight * 2)
    }

    private var resolutionOverlayText: String {
        item.resolutionLabel.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var firstListTag: String? {
        item.tags.lazy
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                // 与壁纸探索一致：仅静态缩略图（GIF 经降采样为单帧，不播放动画）
                KFImage(item.coverImageURL)
                    .setProcessor(DownsamplingImageProcessor(size: targetImageSize))
                    .cacheMemoryOnly(false)
                    .cancelOnDisappear(true)
                    .placeholder { _ in placeholderGradient }
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
            .frame(width: cardWidth, height: imageHeight)
            .clipShape(Self.thumbShape)
            .overlay(alignment: .topLeading) {
                simplifiedMetadataRow
                    .padding(10)
            }
            .overlay(alignment: .center) {
                if item.previewVideoURL != nil {
                    Image(systemName: "play.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.black.opacity(0.45))
                        .clipShape(Circle())
                }
            }

            HStack(spacing: 8) {
                Text(item.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                
                Spacer()
                
                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(isFavorite ? Color(hex: "FF5A7D") : .white.opacity(0.36))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(width: cardWidth, height: textAreaHeight, alignment: .leading)
            .background(Color.black.opacity(0.46))
        }
        .background(
            Self.cardShape
                .fill(Color.clear)
                .overlay(
                    Self.cardShape
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                )
        )
        .clipShape(Self.cardShape)
        .throttledHover(interval: 0.05) { hovering in
            isHovered = hovering
        }
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.spring(response: 0.20, dampingFraction: 0.85), value: isHovered)
        .onTapGesture {
            onTap()
        }
    }
    
    private var simplifiedMetadataRow: some View {
        HStack(spacing: 6) {
            if let tag = firstListTag {
                metaTag(text: tag)
            }
            if item.isGIF {
                metaTag(text: "GIF")
            }
            if item.previewVideoURL != nil {
                metaTag(text: "LIVE")
            }
            Spacer(minLength: 0)
            if !resolutionOverlayText.isEmpty {
                metaTag(text: resolutionOverlayText)
            }
        }
    }

    private func metaTag(text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.4))
            .clipShape(Capsule())
    }

    private var placeholderGradient: some View {
        LinearGradient(
            colors: [Color(hex: "1C2431"), Color(hex: "233B5A"), Color(hex: "14181F")],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay {
            Image(systemName: "photo.fill")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.white.opacity(0.18))
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
                    .foregroundStyle(.white.opacity(0.94))
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
    case subscribed = "subscribed"
    case updated = "updated"
    case created = "created"
    
    var id: String { rawValue }
    
    var title: String {
        switch self {
        case .trendToday: return t("workshop.sort.trendToday")
        case .trendWeek: return t("workshop.sort.trendWeek")
        case .trendMonth: return t("workshop.sort.trendMonth")
        case .trendQuarter: return t("workshop.sort.trendQuarter")
        case .trendYear: return t("workshop.sort.trendYear")
        case .trendAll: return t("workshop.sort.trendAll")
        case .subscribed: return t("workshop.sort.subscribed")
        case .updated: return t("workshop.sort.updated")
        case .created: return t("workshop.sort.created")
        }
    }
    
    var menuTitle: String { title }
    
    /// 映射到 WorkshopSearchParams.SortOption
    var sortBy: WorkshopSearchParams.SortOption {
        switch self {
        case .trendToday, .trendWeek, .trendMonth, .trendQuarter, .trendYear, .trendAll:
            return .ranked
        case .subscribed:
            return .subscriptions
        case .updated:
            return .updated
        case .created:
            return .created
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
        case .trendAll, .subscribed, .updated, .created:
            return nil
        }
    }
}
