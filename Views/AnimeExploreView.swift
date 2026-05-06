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
    @ObservedObject private var arcSettings = ArcBackgroundSettings.shared

    // MARK: State
    @State private var selectedCategory: AnimeCategory = .all
    @State private var selectedHotTag: AnimeHotTag?
    @State private var searchText = ""
    @State private var selectedSort: AnimeSortOption = .newest
    @State private var isLoadingMore = false
    @State private var isInitialLoading = false
    @State private var scrollOffset: CGFloat = 0
    @State private var contentSize: CGFloat = 0
    @State private var containerSize: CGFloat = 0
    @State private var isFirstAppearance = true
    @State private var loadMoreFailed = false
    @State private var searchTask: Task<Void, Never>?
    @State private var isTagSearchActive = false
    @State private var gridImagePrefetcher: Kingfisher.ImagePrefetcher?
    @State private var lastPrefetchCenterIndex: Int = -1
    @State private var lastSyncedFirstAnimeID: String?

    /// 缓存排序后的列表，避免每次 body 重绘时对 `animeItems` 全表排序
    @State private var visibleAnimeItems: [AnimeSearchResult] = []

    var body: some View {
        GeometryReader { geometry in
            let contentWidth = calculateContentWidth(geometry: geometry)
            let gridConfig = AnimeGridConfig(contentWidth: contentWidth)

            ZStack {
                ArcAtmosphereBackground(
                    tint: exploreAtmosphere.tint,
                    referenceImage: exploreAtmosphere.referenceImage,
                    isLightMode: arcSettings.isLightMode,
                    dotGridOpacity: arcSettings.dotGridOpacity,
                    useNoise: true,
                    grainIntensity: arcSettings.exploreGrainAnime
                )
                .ignoresSafeArea()

                ScrollViewReader { proxy in
                    ZStack {
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
                            .environment(\.arcIsLightMode, arcSettings.isLightMode)
                            .id("exploreTop")
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
                            } else if isLoadingMore || (viewModel.isLoading && !visibleAnimeItems.isEmpty) {
                                BottomLoadingCard(isLoading: true)
                                    .padding(.bottom, 60)
                            } else if !isLoadingMore && !viewModel.hasMorePages && !visibleAnimeItems.isEmpty {
                                BottomNoMoreCard()
                                    .padding(.bottom, 60)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)

                        // 浮动返回顶部按钮（独立定位，不与其他内容耦合）
                        VStack {
                            Spacer()
                            HStack {
                                Spacer()
                                if scrollOffset > 300 {
                                    Button {
                                        withAnimation {
                                            proxy.scrollTo("exploreTop", anchor: .top)
                                        }
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
                }
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
        .onChange(of: isVisible) { _, visible in
            if !visible {
                searchTask?.cancel()
                searchTask = nil
                gridImagePrefetcher?.stop()
                exploreAtmosphere.pause()
            }
        }
        .onChange(of: searchText) { _, newValue in handleSearchChange(newValue) }
        .onChange(of: viewModel.animeItems) { _, _ in
            recomputeVisibleAnimeItems()
            syncAtmosphereIfNeeded()
        }
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

            ArcBackgroundPanelButton(tint: exploreAtmosphere.tint.primary, grainIntensity: $arcSettings.exploreGrainAnime) {
                randomizeAtmosphere()
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

    private func contentSection(config: AnimeGridConfig) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            contentHeader

            if viewModel.isLoading && visibleAnimeItems.isEmpty {
                AnimeGridSkeleton(contentWidth: config.contentWidth)
                    .transition(.opacity.animation(.easeInOut(duration: 0.25)))
            } else if visibleAnimeItems.isEmpty {
                emptyState
                    .transition(.opacity.animation(.easeInOut(duration: 0.25)))
            } else {
                animeGrid(config: config)
            }
        }
    }

    private var contentHeader: some View {
        HStack(alignment: .center) {
            Text("\(visibleAnimeItems.count) \(t("content.animes"))")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(arcSettings.secondaryText.opacity(0.66))

            Spacer()
        }
    }

    // MARK: - Grid & Cards

    private func animeGrid(config: AnimeGridConfig) -> some View {
        LazyVGrid(columns: config.gridItems, alignment: .leading, spacing: config.spacing) {
            ForEach(visibleAnimeItems) { anime in
                AnimeCard(
                    anime: anime,
                    cardWidth: config.cardWidth,
                    onTap: {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                            selectedAnime = anime
                        }
                    }
                )
                .onAppear {
                    preloadNearbyImages(around: anime, config: config)
                }
            }
        }
    }

    /// 智能预加载附近图片（前后各 8 张）；中心索引节流
    private func preloadNearbyImages(around anime: AnimeSearchResult, config: AnimeGridConfig) {
        let items = visibleAnimeItems
        guard let index = items.firstIndex(where: { $0.id == anime.id }) else { return }
        if lastPrefetchCenterIndex >= 0, abs(index - lastPrefetchCenterIndex) < 4 { return }
        lastPrefetchCenterIndex = index

        let targetSize = CGSize(width: 512, height: 512)
        let count = items.count
        guard count > 0 else { return }
        let clamped = min(max(0, index), count - 1)
        let lower = max(0, clamped - 8)
        let upper = min(count, clamped + 9)
        guard lower < upper else { return }
        let range = lower..<upper
        let urls = range
            .filter { $0 != clamped }
            .compactMap { items[$0].coverURL.flatMap { URL(string: $0) } }

        // 放到后台线程执行，避免阻塞主线程滚动
        Task(priority: .background) {
            await MainActor.run {
                self.gridImagePrefetcher?.stop()
            }
            let prefetcher = Kingfisher.ImagePrefetcher(
                urls: urls,
                options: [.processor(DownsamplingImageProcessor(size: targetSize))]
            )
            await MainActor.run {
                self.gridImagePrefetcher = prefetcher
            }
            prefetcher.start()
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
                    lastPrefetchCenterIndex = -1
                    recomputeVisibleAnimeItems()
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
            lastPrefetchCenterIndex = -1
            recomputeVisibleAnimeItems()
            syncAtmosphereIfNeeded()
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
                recomputeVisibleAnimeItems()
                syncAtmosphereIfNeeded()
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
                recomputeVisibleAnimeItems()
                syncAtmosphereIfNeeded()
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

        AppLogger.info(.anime, "加载更多", metadata: ["当前数量": visibleAnimeItems.count])
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

    private func resetAllFilters(reloadData: Bool = false) {
        searchText = ""
        selectedHotTag = nil
        selectedCategory = .all
        selectedSort = .newest
        lastPrefetchCenterIndex = -1
        lastSyncedFirstAnimeID = nil
        loadMoreFailed = false
        viewModel.searchText = ""
        viewModel.errorMessage = nil

        if reloadData {
            viewModel.animeItems.removeAll()
            Task { await viewModel.loadInitialData() }
        } else {
            recomputeVisibleAnimeItems()
        }
    }

    private func reloadData() {
        AppLogger.info(.anime, "重新搜索：用户操作触发")
        lastPrefetchCenterIndex = -1
        lastSyncedFirstAnimeID = nil
        loadMoreFailed = false
        viewModel.errorMessage = nil
        viewModel.animeItems.removeAll()
        Task { await viewModel.loadInitialData() }
    }

    private func recomputeVisibleAnimeItems() {
        visibleAnimeItems = viewModel.animeItems
    }

    private func syncAtmosphereIfNeeded() {
        let first = visibleAnimeItems.first
        let fid = first?.id
        guard fid != lastSyncedFirstAnimeID else { return }
        lastSyncedFirstAnimeID = fid
        if let first, let coverURL = first.coverURL {
            exploreAtmosphere.updateFirstAnime(coverURL: coverURL)
        }
    }

    private func randomizeAtmosphere() {
        guard !visibleAnimeItems.isEmpty else { return }
        let random = visibleAnimeItems.randomElement()!
        if let coverURL = random.coverURL.flatMap({ URL(string: $0) }) {
            exploreAtmosphere.updateFromImageURL(coverURL, keyPrefix: "rand-anime")
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

// MARK: - AnimeCard (内嵌私有卡片，参考 WallpaperCard 架构)

private struct AnimeCard: View {
    let anime: AnimeSearchResult
    let cardWidth: CGFloat
    let onTap: () -> Void

    @State private var isHovered = false

    // 竖图比例 10:14 (1:1.4)
    private var imageHeight: CGFloat {
        cardWidth * 1.4
    }

    // 信息栏高度
    private var textAreaHeight: CGFloat { 44 }

    // 降采样目标尺寸（固定 512x512，避免窗口大小变化导致缓存失效）
    private let targetImageSize: CGSize = CGSize(width: 512, height: 512)

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                // Kingfisher 高性能图片加载
                KFImage(anime.coverURL.flatMap { URL(string: $0) })
                    .setProcessor(DownsamplingImageProcessor(size: targetImageSize))
                    .cacheMemoryOnly(false)
                    .fade(duration: 0.2)
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
                        .foregroundStyle(ArcBackgroundSettings.shared.primaryText.opacity(0.9))
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
                                .foregroundStyle(ArcBackgroundSettings.shared.secondaryText.opacity(0.8))
                        }
                    }

                    if let episode = anime.latestEpisode, !episode.isEmpty {
                        HStack(spacing: 3) {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 9))
                            Text(episode)
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                        }
                        .foregroundStyle(ArcBackgroundSettings.shared.secondaryText.opacity(0.5))
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
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.white.opacity(isHovered ? 0.18 : 0.08), lineWidth: isHovered ? 1.5 : 1)
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.01 : 1.0)
        .animation(.easeOut(duration: 0.2), value: isHovered)
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
