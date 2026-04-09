import SwiftUI
import AppKit

// MARK: - MediaExploreContentView - 媒体探索页
struct MediaExploreContentView: View {
    @ObservedObject var viewModel: MediaExploreViewModel
    @Binding var selectedMedia: MediaItem?
    @StateObject private var exploreAtmosphere = ExploreAtmosphereController(wallpaperMode: false)

    @State private var selectedCategory: MediaExploreCategory = .all
    @State private var selectedHotTag: MediaExploreHotTag?
    @State private var selectedSort: MediaExploreSortOption = .newest
    @State private var sortAscending = false
    @State private var searchText = ""
    @State private var displayedMediaItems: [MediaItem] = []
    @State private var isLoadingMore = false
    @State private var isInitialLoading = false
    @State private var scrollOffset: CGFloat = 0
    @State private var visibleCardIDs: Set<String> = []

    @State private var searchTask: Task<Void, Never>?
    @State private var loadMoreTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geometry in
            let gridContentWidth = max(0, geometry.size.width - 56)
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 16) {
                    heroSection
                    categorySection
                    mediaSection(gridContentWidth: gridContentWidth)
                }
                .padding(.horizontal, 28)
                .padding(.top, 80)
                .padding(.bottom, 48)
                .frame(width: geometry.size.width, alignment: .leading)
                .background(
                    // macOS 14 滚动追踪：通过 GeometryReader + PreferenceKey 上报滚动位置
                    GeometryReader { scrollProxy in
                        Color.clear.preference(
                            key: ExploreScrollOffsetKey.self,
                            value: -scrollProxy.frame(in: .named("exploreScroll")).minY
                        )
                    }
                )
                .environment(\.explorePageAtmosphereTint, exploreAtmosphere.tint)
            }
            .coordinateSpace(name: "exploreScroll")
            .iosSmoothScroll()
            .modifier(ScrollLoadMoreModifier(
                scrollOffset: $scrollOffset,
                onLoadMore: triggerLoadMore,
                checkLoadMore: checkLoadMore
            ))
            .disabled(isInitialLoading)
            .background(
                ExploreDynamicAtmosphereBackground(
                    tint: exploreAtmosphere.tint,
                    referenceImage: exploreAtmosphere.referenceImage
                )
            )
        }
        .task {
            if viewModel.items.isEmpty {
                isInitialLoading = true
            }
            await viewModel.initialLoadIfNeeded()
            if searchText.isEmpty {
                searchText = viewModel.currentQuery
            }
            rebuildVisibleMediaItems()
            syncExploreMediaAtmosphere()
            isInitialLoading = false
        }
        .onChange(of: selectedHotTag) { _, _ in
            handleFilterChange()
        }
        .onChange(of: selectedSort) { _, _ in
            handleFilterChange()
        }
        .onChange(of: sortAscending) { _, _ in
            handleFilterChange()
        }
        .onChange(of: searchText) { _, _ in
            handleFilterChange()
        }
        .onChange(of: viewModel.items) { oldVal, newVal in
            if newVal.isEmpty || displayedMediaItems.isEmpty {
                rebuildVisibleMediaItems()
            } else if !oldVal.isEmpty, newVal.count > oldVal.count {
                appendNewMediaItems()
            } else {
                rebuildVisibleMediaItems()
            }
        }
        .onChange(of: displayedMediaItems.first?.id) { _, _ in
            syncExploreMediaAtmosphere()
        }
        .onDisappear {
            searchTask?.cancel()
            loadMoreTask?.cancel()
            searchTask = nil
            loadMoreTask = nil
        }
    }

    private func syncExploreMediaAtmosphere() {
        exploreAtmosphere.updateFirstMedia(displayedMediaItems.first)
    }

    private var heroSection: some View {
        VStack(alignment: .leading, spacing: 18) {
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

            HStack(spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.52))

                    TextField(t("search.placeholder"), text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))
                        .onSubmit {
                            submitSearch(with: searchText)
                        }

                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                            selectedHotTag = nil
                            submitSearch(with: "")
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.36))
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: 46)
                .liquidGlassSurface(
                    .prominent,
                    tint: exploreAtmosphere.tint.primary.opacity(0.1),
                    in: Capsule(style: .continuous)
                )

                Button {
                    resetAllFilters()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .frame(width: 46, height: 46)
                        .contentShape(Circle())
                        .liquidGlassSurface(
                            .prominent,
                            tint: exploreAtmosphere.tint.secondary.opacity(0.12),
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: 520)

            HStack(alignment: .center, spacing: 10) {
                Text(t("hotWallpaper") + ":")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))

                ForEach(MediaExploreHotTag.allCases) { tag in
                    MediaHotTagChip(tag: tag, isSelected: selectedHotTag == tag) {
                        withAnimation(AppFluidMotion.interactiveSpring) {
                            selectedHotTag = selectedHotTag == tag ? nil : tag
                        }
                    }
                }
            }
        }
        .frame(maxWidth: 700, alignment: .leading)
    }

    private var categorySection: some View {
        FlowLayout(spacing: 12) {
            ForEach(MediaExploreCategory.allCases) { category in
                MediaCategoryChip(category: category, isSelected: selectedCategory == category) {
                    withAnimation(AppFluidMotion.interactiveSpring) {
                        selectedCategory = category
                        selectedHotTag = nil
                        searchText = ""
                    }

                    displayedMediaItems = []
                    visibleCardIDs.removeAll()

                    Task {
                        if category == .all {
                            await viewModel.loadHomeFeed()
                        } else {
                            await viewModel.loadTagFeed(slug: category.slug, title: category.title)
                        }
                    }
                }
            }
        }
    }

    private func mediaSection(gridContentWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                Text("\(formattedMediaCount) \(t("media.count")) · \(t("media.loaded")) \(formattedLoadedCount)")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.64))

                Spacer()

                HStack(spacing: 12) {
                    Menu {
                        ForEach(MediaExploreSortOption.allCases) { option in
                            Button(option.menuTitle) {
                                selectedSort = option
                            }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.up.arrow.down")
                                .font(.system(size: 13, weight: .semibold))
                            Text(selectedSort.title)
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundStyle(.white.opacity(0.92))
                        .padding(.horizontal, 16)
                        .frame(height: 38)
                        .liquidGlassSurface(
                            .regular,
                            tint: exploreAtmosphere.tint.primary.opacity(0.1),
                            in: Capsule(style: .continuous)
                        )
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }

            if viewModel.isLoading && displayedMediaItems.isEmpty {
                MediaGridSkeleton(contentWidth: gridContentWidth)
                    .padding(.top, 20)
                    .transition(.opacity.animation(.easeInOut(duration: 0.3)))
            } else if displayedMediaItems.isEmpty {
                emptyState
                    .transition(.opacity.animation(.easeInOut(duration: 0.3)))
            } else {
                mediaGrid(contentWidth: gridContentWidth)

                if isLoadingMore || (viewModel.isLoading && !displayedMediaItems.isEmpty) {
                    LoadingMoreIndicator()
                        .padding(.vertical, 20)
                }
            }
        }
    }

    // MARK: - Media Grid (LazyVGrid)

    private func mediaGrid(contentWidth: CGFloat) -> some View {
        let columnCount = contentWidth > 1200 ? 4 : (contentWidth > 800 ? 3 : 2)
        let spacing: CGFloat = 16
        let totalSpacing = CGFloat(columnCount - 1) * spacing
        let cardWidth = (contentWidth - totalSpacing) / CGFloat(columnCount)
        let cardHeight = cardWidth * 0.6  // 媒体卡片宽高比 16:10
        
        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: columnCount),
            spacing: spacing
        ) {
            ForEach(Array(displayedMediaItems.enumerated()), id: \.element.id) { index, item in
                SimpleMediaCard(
                    item: item,
                    cardWidth: cardWidth,
                    cardHeight: cardHeight,
                    isFavorite: viewModel.isFavorite(item),
                    onTap: { selectedMedia = item }
                )
                .onAppear {
                    let _ = withAnimation(.spring(response: 0.5, dampingFraction: 0.8).delay(Double(min(index % 8, 4)) * 0.05)) {
                        visibleCardIDs.insert(item.id)
                    }
                }
                .opacity(visibleCardIDs.contains(item.id) ? 1 : 0)
                .offset(y: visibleCardIDs.contains(item.id) ? 0 : 30)
                .scaleEffect(visibleCardIDs.contains(item.id) ? 1 : 0.9)
                .scrollTransition { content, phase in
                    content
                        .scaleEffect(phase.isIdentity ? 1 : 0.95)
                        .opacity(phase.isIdentity ? 1 : 0.8)
                }
            }
        }
        .frame(height: calculateTotalHeight(itemCount: displayedMediaItems.count, cardHeight: cardHeight, columnCount: columnCount, spacing: spacing))
    }

    /// 计算 LazyVGrid 总高度（确保 ScrollView contentSize 正确）
    private func calculateTotalHeight(itemCount: Int, cardHeight: CGFloat, columnCount: Int, spacing: CGFloat) -> CGFloat {
        guard itemCount > 0 else { return 0 }
        let rows = ceil(Double(itemCount) / Double(columnCount))
        let totalCardHeight = cardHeight + 44 // 卡片高度 + 底部信息栏约 44pt
        return CGFloat(rows * Double(totalCardHeight) + max(0, rows - 1) * Double(spacing) + 40)
    }

    // MARK: - Loading Indicator

    private struct LoadingMoreIndicator: View {
        @State private var isAnimating = false
        
        var body: some View {
            HStack(spacing: 8) {
                Image(systemName: "arrow.2.circlepath")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .rotationEffect(.degrees(isAnimating ? 360 : 0))
                    .onAppear {
                        withAnimation(
                            .linear(duration: 1.0)
                            .repeatForever(autoreverses: false)
                        ) {
                            isAnimating = true
                        }
                    }
                    .onDisappear {
                        isAnimating = false
                    }
                
                Text(t("loading.simple"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var emptyState: some View {
        Group {
            if let errorMessage = viewModel.errorMessage {
                ErrorStateView(
                    type: viewModel.networkStatus.connectionState == .offline ? .offline : .network,
                    message: errorMessage,
                    retryAction: {
                        Task { await viewModel.loadHomeFeed() }
                    }
                )
            } else {
                ErrorStateView(
                    type: .empty,
                    title: t("noMediaFilter"),
                    message: t("tryDifferentFilter"),
                    retryAction: {
                        Task { await viewModel.loadHomeFeed() }
                    }
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

    private var greetingText: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Good Morning"
        case 12..<18: return "Good Afternoon"
        default: return "Good Evening"
        }
    }

    private var formattedMediaCount: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: displayedMediaItems.count)) ?? "\(displayedMediaItems.count)"
    }

    private var formattedLoadedCount: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: viewModel.items.count)) ?? "\(viewModel.items.count)"
    }

    private func appendNewMediaItems() {
        let existingIDs = Set(displayedMediaItems.map { $0.id })
        let newItems = viewModel.items.filter { !existingIDs.contains($0.id) }
        
        guard !newItems.isEmpty else { return }
        
        displayedMediaItems.append(contentsOf: newItems)
    }

    /// macOS 15+ 使用：触发加载更多
    private func triggerLoadMore() {
        guard viewModel.hasMorePages,
              !viewModel.isLoading,
              !isLoadingMore,
              !viewModel.isLoadingMore else { return }

        isLoadingMore = true
        Task {
            await viewModel.loadMore()
            await MainActor.run {
                appendNewMediaItems()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    isLoadingMore = false
                }
            }
        }
    }
    
    /// macOS 14 使用：通过 scrollOffset 检测是否滚动到底部触发加载更多
    /// - Parameter offset: 滚动偏移量（已取反，正值表示向上滚动的距离）
    private func checkLoadMore(offset: CGFloat) {
        let threshold: CGFloat = 300 // 向上滚动超过 300pt 触发加载
        guard offset > threshold,
              viewModel.hasMorePages else { return }

        // 防死锁：如果 isLoading/isLoadingMore 卡住，检查是否有活跃任务
        if viewModel.isLoading || isLoadingMore || viewModel.isLoadingMore {
            if let loadMoreTask, !loadMoreTask.isCancelled {
                return // 已有进行中的加载任务，不重复触发
            }
            // 任务已完成但状态未重置（异常情况），强制继续
        }

        loadMoreTask?.cancel()
        isLoadingMore = true
        Task {
            await viewModel.loadMore()
            await MainActor.run {
                appendNewMediaItems()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    isLoadingMore = false
                }
            }
        }
    }

    private func submitSearch(with query: String) {
        selectedCategory = .all
        selectedHotTag = nil
        displayedMediaItems = []
        visibleCardIDs.removeAll()
        Task {
            await viewModel.search(query: query)
        }
    }

    private static let hotTagServerSlugs: [MediaExploreHotTag: String] = [
        .anime: "anime",
        .rain: "rain",
        .cyberpunk: "cyberpunk",
        .nature: "nature",
        .game: "games",
        .dark: "dark",
    ]

    private func isServerSideHotTag(_ tag: MediaExploreHotTag) -> Bool {
        Self.hotTagServerSlugs[tag] != nil
    }

    private func handleFilterChange() {
        if let hotTag = selectedHotTag, isServerSideHotTag(hotTag),
           let slug = Self.hotTagServerSlugs[hotTag] {
            displayedMediaItems = []
            visibleCardIDs.removeAll()
            Task {
                await viewModel.loadTagFeed(slug: slug, title: hotTag.title)
            }
            return
        }

        rebuildVisibleMediaItems()
    }

    private func rebuildVisibleMediaItems() {
        let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let sourceOrder = Dictionary(uniqueKeysWithValues: viewModel.items.enumerated().map { ($1.id, $0) })
        
        let filtered = viewModel.items.filter { item in
            let matchesSearch = trimmedQuery.isEmpty || item.matches(search: trimmedQuery)
            let matchesHotTag = selectedHotTag.map { item.matches(hotTag: $0) } ?? true
            return matchesSearch && matchesHotTag
        }
        
        switch selectedSort {
        case .newest:
            displayedMediaItems = sortAscending ? Array(filtered.reversed()) : filtered
        case .title:
            displayedMediaItems = filtered.sorted { lhs, rhs in
                let comparison = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
                if comparison == .orderedSame {
                    return (sourceOrder[lhs.id] ?? 0) < (sourceOrder[rhs.id] ?? 0)
                }
                return sortAscending ? comparison == .orderedDescending : comparison == .orderedAscending
            }
        case .format:
            displayedMediaItems = filtered.sorted { lhs, rhs in
                let comparison = lhs.formatText.localizedCaseInsensitiveCompare(rhs.formatText)
                if comparison == .orderedSame {
                    return (sourceOrder[lhs.id] ?? 0) < (sourceOrder[rhs.id] ?? 0)
                }
                return sortAscending ? comparison == .orderedAscending : comparison == .orderedDescending
            }
        }
        
        syncExploreMediaAtmosphere()
    }

    private func resetAllFilters() {
        searchText = ""
        selectedHotTag = nil
        selectedCategory = .all
        selectedSort = .newest
        sortAscending = false

        Task {
            await viewModel.loadHomeFeed()
        }
    }
}

// MARK: - Hot Tag Chip

private struct MediaHotTagChip: View {
    let tag: MediaExploreHotTag
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(tag.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(isSelected ? 0.95 : 0.78))
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(
                    Capsule(style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.white.opacity(isSelected ? 0.3 : 0.15), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(AppFluidMotion.hoverEase, value: isHovered)
        .throttledHover(interval: 0.05) { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Category Chip

private struct MediaCategoryChip: View {
    let category: MediaExploreCategory
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: category.accentColors.map(Color.init(hex:)),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 22, height: 22)

                    Image(systemName: category.icon)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(isSelected ? .white : .black.opacity(0.78))
                }

                Text(category.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(isSelected ? 0.96 : 0.82))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(
                Capsule(style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.white.opacity(isSelected ? 0.3 : 0.15), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered && !isSelected ? 1.02 : 1.0)
        .animation(AppFluidMotion.hoverEase, value: isHovered)
        .throttledHover(interval: 0.05) { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Media Card

private struct SimpleMediaCard: View {
    let item: MediaItem
    var cardWidth: CGFloat
    var cardHeight: CGFloat
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
                    OptimizedAsyncImage(
                        url: item.posterURLValue ?? item.thumbnailURLValue,
                        priority: .medium
                    ) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } placeholder: {
                        fallbackArtwork
                    }
                }
                .frame(width: cardWidth, height: cardHeight)
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
                .frame(width: cardWidth, alignment: .leading)
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
            .frame(width: cardWidth)
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

// MARK: - Enums

private enum MediaExploreSortOption: String, CaseIterable, Identifiable {
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
}

private enum MediaExploreHotTag: String, CaseIterable, Identifiable {
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
}

private enum MediaExploreCategory: String, CaseIterable, Identifiable {
    case all
    case anime
    case games
    case superhero
    case nature
    case car
    case tv
    case fantasy
    case space
    case technology
    case holiday
    case animal
    case horror
    case football
    case japan
    case helloKitty

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
        case .anime: return "anime"
        case .games: return "games"
        case .superhero: return "superhero"
        case .nature: return "nature"
        case .car: return "car"
        case .tv: return "tv"
        case .fantasy: return "fantasy"
        case .space: return "space"
        case .technology: return "technology"
        case .holiday: return "holiday"
        case .animal: return "animal"
        case .horror: return "horror"
        case .football: return "football"
        case .japan: return "japan"
        case .helloKitty: return "hello-kitty"
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

extension MediaItem {
    fileprivate func matches(search query: String) -> Bool {
        let haystack = [
            title,
            sourceText,
            categoryName ?? "",
            formatText,
            tags.joined(separator: " ")
        ]
            .joined(separator: " ")
            .lowercased()

        return haystack.contains(query)
    }

    fileprivate func matches(hotTag: MediaExploreHotTag) -> Bool {
        switch hotTag {
        case .fourK:
            let normalized = formatText.uppercased()
                .replacingOccurrences(of: " ", with: "")
            if normalized.contains("3840X2160") || normalized.contains("4K") { return true }
            if let er = exactResolution, er.uppercased().contains("3840") { return true }
            return false
        case .hd:
            let normalized = formatText.uppercased()
                .replacingOccurrences(of: " ", with: "")
            if normalized.contains("HD") || normalized.contains("1920X1080")
               || normalized.contains("1280X720") { return true }
            if let er = exactResolution,
               er.uppercased().contains("1920") || er.uppercased().contains("1280") { return true }
            return false
        default:
            return false
        }
    }
}

// MARK: - Scroll Load More Modifier

/// 跨版本兼容的滚动加载更多修饰符
/// macOS 15+ 使用 onScrollGeometryChange，macOS 14 使用 PreferenceKey 滚动追踪
private struct ScrollLoadMoreModifier: ViewModifier {
    @Binding var scrollOffset: CGFloat
    let onLoadMore: () -> Void
    let checkLoadMore: (CGFloat) -> Void

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    let threshold: CGFloat = 300
                    let bottomOffset = geometry.contentOffset.y + geometry.containerSize.height
                    return bottomOffset >= geometry.contentSize.height - threshold
                } action: { oldValue, newValue in
                    if newValue && !oldValue {
                        onLoadMore()
                    }
                }
        } else {
            content
                .onPreferenceChange(ExploreScrollOffsetKey.self) { value in
                    scrollOffset = value
                }
                .onChange(of: scrollOffset) { _, offset in
                    checkLoadMore(offset)
                }
        }
    }
}

// macOS 14 用 PreferenceKey 追踪滚动偏移量（比 GeometryReader overlay 更可靠）
private struct ExploreScrollOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}


