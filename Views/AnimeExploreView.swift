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
    @State private var contentSize: CGFloat = 0
    @State private var containerSize: CGFloat = 0

    @Binding var selectedAnime: AnimeSearchResult?
    var isVisible: Bool = true
    @State private var searchTask: Task<Void, Never>?
    @State private var isTagSearchActive = false

    var body: some View {
        GeometryReader { geometry in
            let gridContentWidth = max(0, geometry.size.width - 56)

            ZStack {
                // 背景放在 ScrollView 同级底层，避免滚动耦合重绘
                // 使用 lightweightBackdrop 模式减少 GPU 负担
                if isVisible {
                    ExploreDynamicAtmosphereBackground(
                        tint: exploreAtmosphere.tint,
                        referenceImage: exploreAtmosphere.referenceImage,
                        lightweightBackdrop: true  // 启用轻量模式，禁用模糊背景图
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
                    if viewModel.isLoadingMore || (viewModel.isLoading && !displayedItems.isEmpty) {
                        BottomLoadingCard(isLoading: true)
                            .padding(.bottom, 60)
                    } else if !viewModel.isLoadingMore && !viewModel.hasMorePages && !displayedItems.isEmpty {
                        BottomNoMoreCard()
                            .padding(.bottom, 60)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
        .task { await handleInitialLoad() }
        .onChange(of: searchText) { _, newValue in handleSearchChange(newValue) }
        .onChange(of: viewModel.animeItems.first?.id) { _, _ in handleDataSourceChange() }
        .onChange(of: viewModel.animeItems) { old, new in handleItemsChange(old: old, new: new) }
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
            ForEach(Array(displayedItems.enumerated()), id: \.element.id) { index, anime in
                AnimePortraitCard(
                    anime: anime,
                    cardWidth: config.cardWidth
                ) {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        selectedAnime = anime
                    }
                }
                .onAppear {
                    visibleCardIDs.insert(anime.id)
                    preloadNearbyImages(for: index, config: config)
                }
            }
        }
    }
    
    /// 智能预加载附近图片（前后各 5 张）
    private func preloadNearbyImages(for index: Int, config: GridConfig) {
        let imageHeight = config.cardWidth * 1.4
        let targetSize = CGSize(width: config.cardWidth * 2, height: imageHeight * 2)
        let range = max(0, index - 5)..<min(displayedItems.count, index + 6)
        let urls = range
            .filter { $0 != index }
            .compactMap { displayedItems[$0].coverURL.flatMap { URL(string: $0) } }
        
        let prefetcher = ImagePrefetcher(
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
        AppLogger.info(.anime, "动漫探索页 onAppear",
            metadata: ["已有数据": !viewModel.animeItems.isEmpty, "当前数量": viewModel.animeItems.count])

        // 重置所有过滤条件，确保初始状态正确
        searchText = ""
        selectedHotTag = nil
        selectedCategory = .all
        displayedItems = []
        visibleCardIDs.removeAll()
        selectedSort = .newest
        viewModel.searchText = ""

        isInitialLoading = true
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
    }

    private func selectCategory(_ category: AnimeCategory) {
        // 防止重复选择
        guard selectedCategory != category else { return }

        withAnimation(AppFluidMotion.interactiveSpring) {
            selectedCategory = category
            selectedHotTag = nil
            isTagSearchActive = true
            searchTask?.cancel()
            searchText = ""
            viewModel.searchText = ""
        }
        // 不要先清空列表，保持显示旧数据直到新数据加载完成
        Task {
            await viewModel.fetchByCategory(category)
            await MainActor.run {
                rebuildDisplayedItems()
            }
        }
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
            await MainActor.run {
                rebuildDisplayedItems()
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
        Task {
            await viewModel.loadMore()
            await MainActor.run {
                rebuildDisplayedItems()
            }
        }
    }

    private func checkLoadMore(offset: CGFloat, contentHeight: CGFloat, containerHeight: CGFloat) {
        guard viewModel.hasMorePages else { return }
        guard !viewModel.isLoading, !viewModel.isLoadingMore else { return }

        // 计算距离底部距离
        let distanceToBottom = contentHeight - (offset + containerHeight)

        // 双阈值策略：
        // 1. 提前加载（距离底部 < 800pt）- 正常预加载
        // 2. 触底保底（距离底部 < 100pt）- 保底机制
        let shouldLoadEarly = distanceToBottom < 800 && distanceToBottom > 100
        let shouldLoadBottom = distanceToBottom < 100

        guard shouldLoadEarly || shouldLoadBottom else { return }

        // 使用 triggerLoadMore 统一处理，避免重复触发
        triggerLoadMore()
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

    private func handleItemsChange(old: [AnimeSearchResult], new: [AnimeSearchResult]) {
        if new.isEmpty || displayedItems.isEmpty {
            rebuildDisplayedItems()
        } else if !old.isEmpty, new.count > old.count {
            appendNewItems()
        } else {
            rebuildDisplayedItems()
        }
    }

    private func appendNewItems() {
        let existingIDs = Set(displayedItems.map(\.id))
        let newItems = viewModel.animeItems.filter { !existingIDs.contains($0.id) }
        guard !newItems.isEmpty else { return }
        displayedItems.append(contentsOf: newItems)
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
