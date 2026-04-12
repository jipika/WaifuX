import SwiftUI
import AppKit
import Kingfisher

// MARK: - AnimeExploreView - 动漫探索页

struct AnimeExploreView: View {
    @ObservedObject var viewModel: AnimeViewModel
    @Binding var selectedAnime: AnimeSearchResult?
    var isVisible: Bool = true

    init(viewModel: AnimeViewModel, selectedAnime: Binding<AnimeSearchResult?>, isVisible: Bool = true) {
        self._viewModel = ObservedObject(wrappedValue: viewModel)
        self._selectedAnime = selectedAnime
        self.isVisible = isVisible
    }
    @StateObject private var exploreAtmosphere = ExploreAtmosphereController(wallpaperMode: false)

    // MARK: State
    @State private var selectedCategory: AnimeCategory = .all
    @State private var selectedHotTag: AnimeHotTag?
    @State private var searchText = ""
    @State private var selectedSort: AnimeSortOption = .newest
    @State private var displayedItems: [AnimeSearchResult] = []
    @State private var isLoadingMore = false
    @State private var isInitialLoading = false
    @State private var scrollOffset: CGFloat = 0
    @State private var contentSize: CGFloat = 0
    @State private var containerSize: CGFloat = 0
    @State private var visibleCardIDs: Set<String> = []
    @State private var isFirstAppearance = true
    @State private var loadMoreFailed = false
    @State private var searchTask: Task<Void, Never>?
    @State private var isTagSearchActive = false

    var body: some View {
        GeometryReader { geometry in
            let contentWidth = calculateContentWidth(geometry: geometry)
            let gridConfig = AnimeGridConfig(contentWidth: contentWidth)

            ZStack {
                // 背景放在 ScrollView 同级底层，避免滚动耦合重绘
                if isVisible {
                    ExploreDynamicAtmosphereBackground(
                        tint: exploreAtmosphere.tint,
                        referenceImage: exploreAtmosphere.referenceImage,
                        lightweightBackdrop: true
                    )
                    .ignoresSafeArea()
                }

                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        heroSection
                        categorySection
                        hotTagsSection
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

                // 底部弹出加载卡片
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
        .onAppear {
            if isFirstAppearance {
                resetAllFilters(reloadData: true)
                isFirstAppearance = false
            } else {
                handleAppear()
            }
        }
        .onChange(of: searchText) { _, newValue in handleSearchChange(newValue) }
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

                Text("Bangumi")
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
                .foregroundStyle(.white.opacity(0.42))

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

    private func contentSection(config: AnimeGridConfig) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            contentHeader

            if viewModel.isLoading && displayedItems.isEmpty {
                AnimeGridSkeleton(contentWidth: config.contentWidth)
                    .transition(.opacity.animation(.easeInOut(duration: 0.25)))
            } else if displayedItems.isEmpty {
                emptyState
                    .transition(.opacity.animation(.easeInOut(duration: 0.25)))
            } else {
                animeGrid(config: config)
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

    // MARK: - Grid & Cards

    private func animeGrid(config: AnimeGridConfig) -> some View {
        LazyVGrid(columns: config.gridItems, alignment: .leading, spacing: config.spacing) {
            ForEach(displayedItems) { anime in
                let index = displayedItems.firstIndex(where: { $0.id == anime.id }) ?? 0
                AnimeCard(
                    anime: anime,
                    index: index,
                    cardWidth: config.cardWidth,
                    onTap: {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                            selectedAnime = anime
                        }
                    }
                )
                .onAppear {
                    visibleCardIDs.insert(anime.id)
                    preloadNearbyImages(for: index, config: config)
                }
            }
        }
    }

    /// 智能预加载附近图片（前后各 10 张）
    private func preloadNearbyImages(for index: Int, config: AnimeGridConfig) {
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
        .liquidGlassSurface(
            .prominent,
            tint: exploreAtmosphere.tint.primary.opacity(0.14),
            in: RoundedRectangle(cornerRadius: 30, style: .continuous)
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

    private func handleAppear() {
        AppLogger.info(.anime, "动漫探索页 onAppear",
            metadata: ["已有数据": !viewModel.animeItems.isEmpty, "当前数量": viewModel.animeItems.count])

        if viewModel.animeItems.isEmpty {
            isInitialLoading = true
            Task {
                let start = Date()
                await viewModel.loadInitialData()
                await MainActor.run {
                    visibleCardIDs.removeAll()
                    rebuildDisplayedItems()
                    syncAtmosphere()
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
            visibleCardIDs.removeAll()
            rebuildDisplayedItems()
            syncAtmosphere()
        }
    }

    private func selectCategory(_ category: AnimeCategory) {
        guard selectedCategory != category else { return }

        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            selectedCategory = category
            selectedHotTag = nil
            isTagSearchActive = true
            searchTask?.cancel()
            searchText = ""
            viewModel.searchText = ""
        }
        Task {
            await viewModel.fetchByCategory(category)
            await MainActor.run {
                rebuildDisplayedItems()
            }
        }
    }

    private func selectHotTag(_ tag: AnimeHotTag) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
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

    private func triggerLoadMore() {
        guard viewModel.hasMorePages,
              !viewModel.isLoading,
              !isLoadingMore else { return }

        AppLogger.info(.anime, "加载更多", metadata: ["当前数量": displayedItems.count])
        Task {
            isLoadingMore = true
            loadMoreFailed = false
            defer { isLoadingMore = false }
            await viewModel.loadMore()
            if viewModel.hasMorePages && viewModel.errorMessage != nil {
                loadMoreFailed = true
            }
        }
    }

    private func checkLoadMore(offset: CGFloat, contentHeight: CGFloat, containerHeight: CGFloat) {
        guard viewModel.hasMorePages else { return }
        guard !viewModel.isLoading, !isLoadingMore else { return }

        let distanceToBottom = contentHeight - (offset + containerHeight)

        let shouldLoadEarly = distanceToBottom < 800 && distanceToBottom > 100
        let shouldLoadBottom = distanceToBottom < 100

        guard shouldLoadEarly || shouldLoadBottom else { return }

        Task {
            isLoadingMore = true
            loadMoreFailed = false
            defer { isLoadingMore = false }
            await viewModel.loadMore()
            if viewModel.hasMorePages && viewModel.errorMessage != nil {
                loadMoreFailed = true
            }
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

    private func rebuildDisplayedItems() {
        let source = viewModel.animeItems

        guard selectedSort != .newest else {
            displayedItems = source
            syncAtmosphere()
            return
        }

        displayedItems = source.sorted { lhs, rhs in
            selectedSort.sortComparator(lhs, rhs, ascending: false)
        }
        syncAtmosphere()
    }

    private func resetAllFilters(reloadData: Bool = false) {
        searchText = ""
        selectedHotTag = nil
        selectedCategory = .all
        selectedSort = .newest
        displayedItems = []
        visibleCardIDs.removeAll()
        loadMoreFailed = false
        viewModel.searchText = ""
        viewModel.errorMessage = nil

        if reloadData {
            viewModel.animeItems.removeAll()
            Task { await viewModel.loadInitialData() }
        }
    }

    private func reloadData() {
        AppLogger.info(.anime, "重新搜索：用户操作触发")
        displayedItems = []
        visibleCardIDs.removeAll()
        loadMoreFailed = false
        viewModel.errorMessage = nil
        viewModel.animeItems.removeAll()
        Task { await viewModel.loadInitialData() }
    }

    private func syncAtmosphere() {
        if let firstAnime = displayedItems.first, let coverURL = firstAnime.coverURL {
            exploreAtmosphere.updateFirstAnime(coverURL: coverURL)
        }
    }

    private func calculateContentWidth(geometry: GeometryProxy) -> CGFloat {
        max(0, geometry.size.width - 56)
    }
}

// MARK: - Grid Configuration

private struct AnimeGridConfig {
    let columnCount: Int
    let spacing: CGFloat
    let cardWidth: CGFloat
    let contentWidth: CGFloat
    let gridItems: [GridItem]

    init(contentWidth: CGFloat) {
        self.contentWidth = contentWidth
        self.columnCount = contentWidth > 1200 ? 5 : (contentWidth > 800 ? 4 : 3)
        self.spacing = 16
        let totalSpacing = spacing * CGFloat(columnCount - 1)
        self.cardWidth = floor((contentWidth - totalSpacing) / CGFloat(columnCount))
        self.gridItems = Array(repeating: GridItem(.flexible(), spacing: spacing), count: columnCount)
    }
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
            return false
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

// MARK: - AnimeCard (内嵌私有卡片，参考 WallpaperCard 架构)

private struct AnimeCard: View {
    let anime: AnimeSearchResult
    let index: Int
    let cardWidth: CGFloat
    let onTap: () -> Void

    @State private var isHovered = false

    // 竖图比例 10:14 (1:1.4)
    private var imageHeight: CGFloat {
        cardWidth * 1.4
    }

    // 信息栏高度
    private var textAreaHeight: CGFloat { 44 }

    // 降采样目标尺寸（Retina 2x）
    private var targetImageSize: CGSize {
        CGSize(width: cardWidth * 2, height: imageHeight * 2)
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                // Kingfisher 高性能图片加载
                KFImage(anime.coverURL.flatMap { URL(string: $0) })
                    .setProcessor(DownsamplingImageProcessor(size: targetImageSize))
                    .cacheMemoryOnly(false)
                    .placeholder { _ in
                        placeholderGradient
                    }
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                .frame(width: cardWidth, height: imageHeight)
                .clipShape(UnevenRoundedRectangle(
                    topLeadingRadius: 14, bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0, topTrailingRadius: 14,
                    style: .continuous
                ))

                // 信息栏 - 参考 WallpaperCard 的 HStack 布局
                HStack(spacing: 8) {
                    Text(anime.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    // 评分标签
                    if let rating = anime.rating, !rating.isEmpty {
                        HStack(spacing: 2) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(.yellow)
                            Text(rating)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.8))
                        }
                    }

                    if let episode = anime.latestEpisode, !episode.isEmpty {
                        HStack(spacing: 3) {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 9))
                            Text(episode)
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                        }
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(width: cardWidth, height: textAreaHeight, alignment: .leading)
                .background(Color.black.opacity(0.46))
            }
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.clear)
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 1))
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.spring(response: 0.2, dampingFraction: 0.85), value: isHovered)
        .throttledHover(interval: 0.05) { hovering in
            isHovered = hovering
        }
    }

    var placeholderGradient: some View {
        LinearGradient(
            colors: [Color(hex: "1C2431"), Color(hex: "233B5A"), Color(hex: "14181F")],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        .overlay {
            Image(systemName: "tv")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.white.opacity(0.18))
        }
    }
}

// MARK: - Skeleton

private struct AnimeGridSkeleton: View {
    var contentWidth: CGFloat = 800

    private var gridItems: [GridItem] {
        let count = contentWidth > 1200 ? 5 : (contentWidth > 800 ? 4 : 3)
        return Array(repeating: GridItem(.flexible(), spacing: 16), count: count)
    }

    var body: some View {
        LazyVGrid(columns: gridItems, spacing: 16) {
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
