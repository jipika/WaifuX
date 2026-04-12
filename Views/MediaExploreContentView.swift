import SwiftUI
import AppKit
import Kingfisher

// MARK: - MediaExploreContentView - 媒体探索页

struct MediaExploreContentView: View {
    @ObservedObject var viewModel: MediaExploreViewModel
    @Binding var selectedMedia: MediaItem?
    var isVisible: Bool = true
    @StateObject private var exploreAtmosphere = ExploreAtmosphereController(wallpaperMode: false)

    @State private var selectedCategory: MediaCategory = .all
    @State private var selectedHotTag: MediaHotTag?
    @State private var selectedSort: MediaSortOption = .newest
    @State private var searchText = ""
    @State private var displayedItems: [MediaItem] = []
    @State private var isLoadingMore = false
    @State private var isInitialLoading = false
    @State private var scrollOffset: CGFloat = 0
    @State private var contentSize: CGFloat = 0
    @State private var containerSize: CGFloat = 0
    @State private var visibleCardIDs: Set<String> = []

    @State private var searchTask: Task<Void, Never>?
    @State private var loadMoreTask: Task<Void, Never>?

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
                    if isLoadingMore || (viewModel.isLoading && !displayedItems.isEmpty) {
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
        .task { await handleInitialLoad() }
        .onChange(of: selectedHotTag) { _, _ in handleFilterChange() }
        .onChange(of: selectedSort) { _, _ in handleFilterChange() }
        .onChange(of: searchText) { _, _ in handleFilterChange() }
        .onChange(of: viewModel.items) { oldVal, newVal in handleItemsChange(old: oldVal, new: newVal) }
        .onDisappear { cancelTasks() }
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
                    .foregroundStyle(.white.opacity(0.56))

                Text("MotionBG")
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
                resetAllFilters()
            }
        }
        .frame(maxWidth: 520)
    }
    
    private var hotTagsRow: some View {
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

    private var categorySection: some View {
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

    private func contentSection(gridContentWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            contentHeader
            
            if viewModel.isLoading && displayedItems.isEmpty {
                MediaGridSkeleton(contentWidth: gridContentWidth)
                    .transition(.opacity.animation(.easeInOut(duration: 0.3)))
            } else if displayedItems.isEmpty {
                emptyState
                    .transition(.opacity.animation(.easeInOut(duration: 0.3)))
            } else {
                mediaGrid(contentWidth: gridContentWidth)
            }
        }
    }
    
    private var contentHeader: some View {
        HStack(alignment: .center) {
            Text("\(formattedCount(displayedItems.count)) \(t("media.count")) · \(t("media.loaded")) \(formattedCount(viewModel.items.count))")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.64))

            Spacer()

            SortMenu(options: MediaSortOption.allCases, selected: $selectedSort, tint: exploreAtmosphere.tint.primary)
        }
    }

    // MARK: - Grid

    private func mediaGrid(contentWidth: CGFloat) -> some View {
        let config = GridConfig(contentWidth: contentWidth, columns: contentWidth > 1200 ? 4 : (contentWidth > 800 ? 3 : 2), baseRatio: 0.6)
        
        return LazyVGrid(columns: config.columns, alignment: .leading, spacing: config.spacing) {
            // 使用 id: \.id 确保稳定 ID
            ForEach(displayedItems) { item in
                let index = displayedItems.firstIndex(where: { $0.id == item.id }) ?? 0
                SimpleMediaCard(
                    item: item,
                    cardWidth: config.cardWidth,
                    isFavorite: viewModel.isFavorite(item),
                    onTap: { selectedMedia = item }
                )
                .onAppear {
                    // 移除动画触发，直接显示
                    visibleCardIDs.insert(item.id)
                    preloadNearbyImages(for: index, config: config)
                }
                // 移除入场动画和滚动效果，解决卡顿和空白问题
                // .cardEntrance(...)
                // .scrollTransitionEffect()
            }
        }
        // 移除强制高度，让 LazyVGrid 自然布局，解决空白问题
        // .frame(height: config.calculateHeight(itemCount: displayedItems.count, extraHeight: 40))
    }
    
    /// 智能预加载附近图片（前后各 10 张）
    private func preloadNearbyImages(for index: Int, config: GridConfig) {
        // 使用固定比例计算高度 (16:10)
        let imageHeight = config.cardWidth * 0.625
        let targetSize = CGSize(width: config.cardWidth * 2, height: imageHeight * 2)
        let range = max(0, index - 10)..<min(displayedItems.count, index + 11)
        let urls = range
            .filter { $0 != index }
            .compactMap { displayedItems[$0].posterURLValue ?? displayedItems[$0].thumbnailURLValue }

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
        if viewModel.items.isEmpty {
            isInitialLoading = true
        }
        await viewModel.initialLoadIfNeeded()
        // 请求完数据后重置 visibleCardIDs，避免脏数据
        visibleCardIDs.removeAll()
        if searchText.isEmpty {
            searchText = viewModel.currentQuery
        }
        rebuildVisibleItems()
        syncAtmosphere()
        isInitialLoading = false
    }

    private func selectCategory(_ category: MediaCategory) {
        withAnimation(AppFluidMotion.interactiveSpring) {
            selectedCategory = category
            selectedHotTag = nil
            searchText = ""
        }

        displayedItems = []
        visibleCardIDs.removeAll()
        // 清空 ViewModel 数据避免显示旧数据
        viewModel.clearItems()

        Task {
            if category == .all {
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
        displayedItems = []
        Task {
            await viewModel.search(query: searchQuery)
            await MainActor.run {
                viewModel.items.forEach { visibleCardIDs.insert($0.id) }
            }
        }
    }

    private func handleFilterChange() {
        visibleCardIDs.removeAll()
        
        if let hotTag = selectedHotTag, hotTag.isServerSide,
           let slug = hotTag.serverSlug {
            displayedItems = []
            Task { await viewModel.loadTagFeed(slug: slug, title: hotTag.title) }
            return
        }

        if selectedHotTag != nil && viewModel.items.isEmpty {
            Task {
                await viewModel.loadHomeFeed()
                rebuildVisibleItems()
            }
            return
        }

        rebuildVisibleItems()
    }

    private func handleItemsChange(old: [MediaItem], new: [MediaItem]) {
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
              !isLoadingMore,
              !viewModel.isLoadingMore else { return }

        isLoadingMore = true
        Task {
            await viewModel.loadMore()
            await MainActor.run {
                appendNewItems()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    isLoadingMore = false
                }
            }
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
        Task {
            await viewModel.loadMore()
            await MainActor.run {
                appendNewItems()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    isLoadingMore = false
                }
            }
        }
    }

    private func rebuildVisibleItems() {
        let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let sourceOrder = Dictionary(uniqueKeysWithValues: viewModel.items.enumerated().map { ($1.id, $0) })
        
        let filtered = viewModel.items.filter { item in
            let matchesSearch = trimmedQuery.isEmpty || item.matches(search: trimmedQuery)
            let matchesHotTag = selectedHotTag?.matches(item) ?? true
            return matchesSearch && matchesHotTag
        }
        
        displayedItems = selectedSort.sort(items: filtered, sourceOrder: sourceOrder)
        syncAtmosphere()
    }

    private func appendNewItems() {
        let existingIDs = Set(displayedItems.map(\.id))
        let newItems = viewModel.items.filter { !existingIDs.contains($0.id) }
        guard !newItems.isEmpty else { return }
        displayedItems.append(contentsOf: newItems)
    }

    private func resetAllFilters() {
        searchText = ""
        selectedHotTag = nil
        selectedCategory = .all
        selectedSort = .newest
        displayedItems = []
        visibleCardIDs.removeAll()

        Task { await viewModel.loadHomeFeed() }
    }

    private func cancelTasks() {
        searchTask?.cancel()
        loadMoreTask?.cancel()
        searchTask = nil
        loadMoreTask = nil
    }

    private func syncAtmosphere() {
        exploreAtmosphere.updateFirstMedia(displayedItems.first)
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
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    // Kingfisher 高性能图片加载 - 移除 cancelOnDisappear 避免重复加载问题
                    KFImage(item.posterURLValue ?? item.thumbnailURLValue)
                        .setProcessor(DownsamplingImageProcessor(size: targetImageSize))
                        .cacheMemoryOnly(false)
                        // 移除 fade 动画避免闪烁问题
                        .placeholder { _ in
                            fallbackArtwork
                        }
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
                // 使用固定比例而非固定高度
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
            // 移除强制宽度，让 VStack 自然布局
            .clipShape(Self.cardShape)
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.spring(response: 0.20, dampingFraction: 0.85), value: isHovered)
        .throttledHover(interval: 0.05) { hovering in
            isHovered = hovering
        }
    }
    
    private var simplifiedMetadataRow: some View {
        HStack(spacing: 6) {
            if let tag = firstListTag {
                metaTag(text: tag)
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

    private var fallbackArtwork: some View {
        LinearGradient(
            colors: [Color(hex: "1C2431"), Color(hex: "233B5A"), Color(hex: "14181F")],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay {
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.white.opacity(0.18))
        }
    }
}
