import SwiftUI
import AppKit
import Kingfisher

// MARK: - AnimeExploreView - 动漫探索页

struct AnimeExploreView: View {
    @StateObject private var viewModel = AnimeViewModel()
    @StateObject private var exploreAtmosphere = ExploreAtmosphereController(wallpaperMode: false)

    @State private var selectedCategory: AnimeCategory = .all
    @State private var selectedHotTag: AnimeHotTag?
    @State private var searchText = ""
    @State private var selectedSort: AnimeSortOption = .newest
    @State private var displayedItems: [AnimeSearchResult] = []
    @State private var visibleCardIDs: Set<String> = []

    @State private var isInitialLoading = false
    @State private var scrollOffset: CGFloat = 0

    @Binding var selectedAnime: AnimeSearchResult?
    var isVisible: Bool = true
    @State private var searchTask: Task<Void, Never>?
    @State private var isTagSearchActive = false

    var body: some View {
        GeometryReader { geometry in
            let gridContentWidth = max(0, geometry.size.width - 56)

            ZStack {
                // 背景放在 ScrollView 同级底层，避免滚动耦合重绘
                if isVisible {
                    ExploreDynamicAtmosphereBackground(
                        tint: exploreAtmosphere.tint,
                        referenceImage: exploreAtmosphere.referenceImage
                    )
                    .ignoresSafeArea()
                }

                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        heroSection
                        categorySection
                        contentSection(gridContentWidth: gridContentWidth)
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 80)
                    .padding(.bottom, 48)
                    .frame(width: geometry.size.width, alignment: .leading)
                    .background(scrollTrackingOverlay)
                    .environment(\.explorePageAtmosphereTint, exploreAtmosphere.tint)
                }
                .coordinateSpace(name: "exploreScroll")
                .iosSmoothScroll()
                .modifier(ScrollLoadMoreModifier(
                    scrollOffset: $scrollOffset,
                    threshold: 1500,  // 提前两屏预加载
                    onLoadMore: triggerLoadMore,
                    checkLoadMore: checkLoadMore
                ))
                .disabled(isInitialLoading)
            }
        }
        .task { await handleInitialLoad() }
        .onChange(of: searchText) { _, newValue in handleSearchChange(newValue) }
        .onChange(of: viewModel.animeItems.first?.id) { _, _ in handleDataSourceChange() }
        .onChange(of: viewModel.animeItems.count) { _, _ in rebuildDisplayedItems() }
        .onChange(of: selectedSort) { _, _ in rebuildDisplayedItems() }
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
                    .foregroundStyle(.white.opacity(0.58))

                Text("Kazumi")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.72))
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .liquidGlassSurface(
                        .regular,
                        tint: exploreAtmosphere.tint.primary.opacity(0.12),
                        in: Capsule(style: .continuous)
                    )
            }

            Text(t("anime.exploreAnime"))
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
                placeholder: t("anime.searchAnime"),
                tint: exploreAtmosphere.tint.primary,
                onSubmit: performSearch,
                onClear: clearSearch
            )
            
            ResetFiltersButton(tint: exploreAtmosphere.tint.secondary) {
                resetAllFilters()
            }
        }
    }

    private var categorySection: some View {
        VStack(alignment: .leading, spacing: 18) {
            categoryChips
            hotTagsSection
        }
    }
    
    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
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
        }
    }
    
    private var hotTagsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(t("anime.hotTags"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))

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

    private func contentSection(gridContentWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            contentHeader
            
            if viewModel.isLoading && displayedItems.isEmpty {
                AnimeGridSkeleton(contentWidth: gridContentWidth)
                    .transition(.opacity.animation(.easeInOut(duration: 0.25)))
            } else if displayedItems.isEmpty {
                emptyState
                    .transition(.opacity.animation(.easeInOut(duration: 0.25)))
            } else {
                animeGrid(contentWidth: gridContentWidth)
                
                if viewModel.isLoadingMore || (viewModel.isLoading && !displayedItems.isEmpty) {
                    LoadingMoreIndicator()
                        .padding(.vertical, 20)
                }
            }
        }
    }
    
    private var contentHeader: some View {
        HStack(alignment: .center) {
            Text("\(displayedItems.count) \(t("content.animes"))")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white.opacity(0.66))

            Spacer()

            SortMenu(
                options: AnimeSortOption.allCases,
                selected: $selectedSort,
                tint: exploreAtmosphere.tint.primary
            )
        }
    }

    // MARK: - Grid

    private func animeGrid(contentWidth: CGFloat) -> some View {
        let config = GridConfig(contentWidth: contentWidth, baseRatio: 1.4)
        
        return LazyVGrid(
            columns: config.columns,
            alignment: .leading,
            spacing: config.spacing
        ) {
            // 使用 id: \.id 确保稳定 ID，优化 SwiftUI 渲染循环
            ForEach(displayedItems) { anime in
                let index = displayedItems.firstIndex(where: { $0.id == anime.id }) ?? 0
                AnimePortraitCard(
                    anime: anime,
                    cardWidth: config.cardWidth
                    // 移除 cardHeight，让卡片自动计算
                ) {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        selectedAnime = anime
                    }
                }
                .onAppear {
                    // 移除动画触发，直接显示
                    visibleCardIDs.insert(anime.id)
                    preloadNearbyImages(for: index, config: config)
                }
                // 移除入场动画和滚动效果
                // .cardEntrance(...)
                // .scrollTransitionEffect()
            }
        }
        // 移除强制高度
        // .frame(height: config.calculateHeight(itemCount: displayedItems.count, extraHeight: 44))
    }
    
    /// 智能预加载附近图片（前后各 10 张，与卡片降采样尺寸一致）
    private func preloadNearbyImages(for index: Int, config: GridConfig) {
        // 使用固定比例计算高度 (10:14)
        let imageHeight = config.cardWidth * 1.4
        let targetSize = CGSize(width: config.cardWidth * 2, height: imageHeight * 2)
        let range = max(0, index - 10)..<min(displayedItems.count, index + 11)

        let urls = range
            .filter { $0 != index }
            .compactMap { displayedItems[$0].coverURL.flatMap { URL(string: $0) } }

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
                    type: .network,
                    message: errorMessage,
                    retryAction: { Task { await viewModel.loadInitialData() } }
                )
            } else {
                ErrorStateView(
                    type: .empty,
                    title: t("anime.noData"),
                    message: t("anime.tryDifferentSource"),
                    retryAction: { Task { await viewModel.loadInitialData() } }
                )
            }
        }
        .frame(height: 220)
        .liquidGlassSurface(
            .prominent,
            tint: exploreAtmosphere.tint.primary.opacity(0.12),
            in: RoundedRectangle(cornerRadius: 28, style: .continuous)
        )
    }
    
    private var scrollTrackingOverlay: some View {
        GeometryReader { scrollProxy in
            Color.clear.preference(
                key: ExploreScrollOffsetKey.self,
                value: -scrollProxy.frame(in: .named("exploreScroll")).minY
            )
        }
    }

    // MARK: - Actions

    private func handleInitialLoad() async {
        AppLogger.info(.anime, "动漫探索页 onAppear",
            metadata: ["已有数据": !viewModel.animeItems.isEmpty, "当前数量": viewModel.animeItems.count])
        
        if viewModel.animeItems.isEmpty {
            isInitialLoading = true
        }
        let start = Date()
        await viewModel.loadInitialData()
        AppLogger.info(.anime, "初始加载完成",
            metadata: [
                "耗时(s)": String(format: "%.2f", Date().timeIntervalSince(start)),
                "结果数": viewModel.animeItems.count,
                "错误": viewModel.errorMessage ?? "无"
            ])
        syncAtmosphere()
        isInitialLoading = false
        // 如果内容不足两屏，继续加载更多
        checkAndLoadMoreIfNeeded()
    }
    
    /// 检查内容高度，如果不足两屏则继续加载
    private func checkAndLoadMoreIfNeeded(attemptCount: Int = 0) {
        // 安全边界：最多尝试3次，避免无限递归
        guard attemptCount < 3,
              viewModel.hasMorePages,
              !viewModel.isLoading,
              !viewModel.isLoadingMore else { return }
        
        let currentCount = displayedItems.count
        // 简单判断：如果数据少于60条（约两屏，动漫卡片更小），继续加载
        guard currentCount < 60 else { return }
        
        Task {
            await viewModel.loadMore()
            await MainActor.run {
                let newCount = displayedItems.count
                // 如果没有加载到新数据，停止递归
                guard newCount > currentCount else { return }
                rebuildDisplayedItems()
                // 递归检查，尝试次数+1
                checkAndLoadMoreIfNeeded(attemptCount: attemptCount + 1)
            }
        }
    }

    private func selectCategory(_ category: AnimeCategory) {
        withAnimation(AppFluidMotion.interactiveSpring) {
            selectedCategory = category
            selectedHotTag = nil
            isTagSearchActive = true
            searchTask?.cancel()
            searchText = ""
            viewModel.searchText = ""
        }
        Task { await viewModel.fetchByCategory(category) }
    }
    
    private func selectHotTag(_ tag: AnimeHotTag) {
        withAnimation(AppFluidMotion.interactiveSpring) {
            let newTag = selectedHotTag == tag ? nil : tag
            selectedHotTag = newTag
            selectedCategory = .all
            isTagSearchActive = true
            searchTask?.cancel()
            searchText = ""
            viewModel.searchText = ""
        }
        Task {
            if let tagToSearch = selectedHotTag {
                await viewModel.searchByTagName(tagToSearch.displayName)
            } else {
                await viewModel.fetchPopular()
            }
        }
    }

    private func handleSearchChange(_ newValue: String) {
        viewModel.searchText = newValue
        
        if isTagSearchActive {
            isTagSearchActive = false
            return
        }
        
        searchTask?.cancel()
        
        if newValue.isEmpty {
            Task { await viewModel.fetchPopular() }
            return
        }
        
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await viewModel.search()
        }
    }
    
    private func performSearch() {
        searchTask?.cancel()
        Task { await viewModel.search() }
    }
    
    private func clearSearch() {
        searchText = ""
        selectedHotTag = nil
        Task { await viewModel.search() }
    }
    
    private func handleDataSourceChange() {
        syncAtmosphere()
        visibleCardIDs.removeAll()
    }

    private func animateCardAppearance(id: String, index: Int) {
        // 直接插入，不使用动画
        visibleCardIDs.insert(id)
    }

    private func triggerLoadMore() {
        guard viewModel.hasMorePages,
              !viewModel.isLoading,
              !viewModel.isLoadingMore else { return }
        
        AppLogger.info(.anime, "加载更多", metadata: ["当前数量": displayedItems.count])
        Task { await viewModel.loadMore() }
    }
    
    private func checkLoadMore(offset: CGFloat) {
        // 提前两屏预加载，避免触底顿挫感
        let threshold: CGFloat = 1500
        guard offset > threshold, viewModel.hasMorePages else { return }
        guard !viewModel.isLoading, !viewModel.isLoadingMore else { return }
        Task { await viewModel.loadMore() }
    }

    private func rebuildDisplayedItems() {
        let source = viewModel.animeItems
        
        guard selectedSort != .newest else {
            displayedItems = source
            return
        }
        
        displayedItems = source.sorted { lhs, rhs in
            selectedSort.sortComparator(lhs, rhs, ascending: false)
        }
    }
    
    private func resetAllFilters() {
        searchText = ""
        selectedHotTag = nil
        selectedCategory = .all
        displayedItems = []
        visibleCardIDs.removeAll()
        selectedSort = .newest

        Task {
            await viewModel.loadInitialData()
            await MainActor.run { rebuildDisplayedItems() }
        }
    }

    private func syncAtmosphere() {
        if let firstAnime = displayedItems.first, let coverURL = firstAnime.coverURL {
            exploreAtmosphere.updateFirstAnime(coverURL: coverURL)
        }
    }
}

// MARK: - Grid Configuration

private struct GridConfig {
    let columnCount: Int
    let spacing: CGFloat
    let cardWidth: CGFloat
    let columns: [GridItem]
    
    init(contentWidth: CGFloat, baseRatio: CGFloat, spacing: CGFloat = 20) {
        self.spacing = spacing
        self.columnCount = contentWidth > 1200 ? 5 : (contentWidth > 800 ? 4 : 3)
        let totalSpacing = CGFloat(columnCount - 1) * spacing
        self.cardWidth = (contentWidth - totalSpacing) / CGFloat(columnCount)
        // 移除 cardHeight 计算，让卡片自动计算高度
        self.columns = Array(repeating: GridItem(.flexible(), spacing: spacing), count: columnCount)
    }
    
    // 移除强制高度计算方法
}

// MARK: - Sort Options

private enum AnimeSortOption: String, CaseIterable, SortOptionProtocol {
    case newest
    case title
    case popular

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newest: return t("anime.sortNewest")
        case .title: return t("anime.sortTitle")
        case .popular: return t("anime.sortPopular")
        }
    }
    
    var menuTitle: String {
        switch self {
        case .newest: return t("anime.sortByNewest")
        case .title: return t("anime.sortByTitle")
        case .popular: return t("anime.sortByPopular")
        }
    }
    
    func sortComparator(_ lhs: AnimeSearchResult, _ rhs: AnimeSearchResult, ascending: Bool) -> Bool {
        switch self {
        case .newest:
            return false // 保持原序
        case .title:
            let cmp = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
            return ascending ? cmp == .orderedDescending : cmp == .orderedAscending
        case .popular:
            let lhsScore = Double(lhs.rating ?? "0") ?? 0
            let rhsScore = Double(rhs.rating ?? "0") ?? 0
            if lhsScore == rhsScore {
                return lhs.rank ?? Int.max < rhs.rank ?? Int.max
            }
            return ascending ? lhsScore < rhsScore : lhsScore > rhsScore
        }
    }
}

// MARK: - Skeleton

private struct AnimeGridSkeleton: View {
    var contentWidth: CGFloat = 800

    private var columns: [GridItem] {
        let count = contentWidth > 1200 ? 5 : (contentWidth > 800 ? 4 : 3)
        return Array(repeating: GridItem(.flexible(), spacing: 20), count: count)
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 20) {
            ForEach(0..<6, id: \.self) { _ in
                AnimePortraitCardSkeleton()
            }
        }
    }
}

private struct AnimePortraitCardSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LinearGradient(
                colors: [Color(hex: "1C2431"), Color(hex: "233B5A"), Color(hex: "14181F")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .aspectRatio(10/14, contentMode: .fit)
            .clipped()

            VStack(alignment: .leading, spacing: 4) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 100, height: 13)

                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.white.opacity(0.05))
                    .frame(width: 50, height: 10)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black.opacity(0.46))
        }
        .frame(maxWidth: .infinity)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.15), radius: 12, x: 0, y: 6)
        .shimmer()
    }
}
