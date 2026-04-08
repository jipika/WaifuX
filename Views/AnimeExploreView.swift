import SwiftUI
import AppKit

// MARK: - AnimeExploreView - 动漫探索页

struct AnimeExploreView: View {
    @StateObject private var viewModel = AnimeViewModel()
    @StateObject private var exploreAtmosphere = ExploreAtmosphereController(wallpaperMode: false)

    @State private var selectedCategory: AnimeCategory = .all
    @State private var selectedHotTag: AnimeHotTag?
    @State private var searchText = ""
    @State private var selectedSort: AnimeSortOption = .newest
    @State private var sortAscending = false
    @State private var displayedAnimeItems: [AnimeSearchResult] = []
    
    @State private var isInitialLoading = false
    
    @Binding var selectedAnime: AnimeSearchResult?

    @State private var searchTask: Task<Void, Never>?
    @State private var isTagSearchActive = false

    var body: some View {
        GeometryReader { geometry in
            let gridContentWidth = max(0, geometry.size.width - 56)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 24) {
                    heroSection
                    animeSection(gridContentWidth: gridContentWidth)
                }
                .padding(.horizontal, 28)
                .padding(.top, 80)
                .padding(.bottom, 48)
                .frame(width: geometry.size.width, alignment: .leading)
                .environment(\.explorePageAtmosphereTint, exploreAtmosphere.tint)
            }
            .coordinateSpace(name: "exploreScroll")
            .onScrollGeometryChange(for: Bool.self) { geometry in
                let threshold: CGFloat = 300
                let bottomOffset = geometry.contentOffset.y + geometry.containerSize.height
                return bottomOffset >= geometry.contentSize.height - threshold
            } action: { oldValue, newValue in
                if newValue, !oldValue {
                    guard viewModel.hasMorePages,
                          !viewModel.isLoading,
                          !viewModel.isLoadingMore else { return }
                    print("[AnimeExplore] Scroll geometry triggered load more...")
                    Task { await viewModel.loadMore() }
                }
            }
            .iosSmoothScroll()
            .disabled(isInitialLoading)
            .background(
                ExploreDynamicAtmosphereBackground(
                    tint: exploreAtmosphere.tint,
                    referenceImage: exploreAtmosphere.referenceImage
                )
            )

        }
        .task {
            if viewModel.animeItems.isEmpty {
                isInitialLoading = true
            }
            await viewModel.loadInitialData()
            syncExploreAtmosphere()
            isInitialLoading = false
        }
        .onChange(of: searchText) { _, newValue in
            viewModel.searchText = newValue
            
            if isTagSearchActive {
                isTagSearchActive = false
                return
            }
            
            searchTask?.cancel()
            
            if newValue.isEmpty {
                Task {
                    await viewModel.fetchPopular()
                }
                return
            }
            
            searchTask = Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                await viewModel.search()
            }
        }
        .onChange(of: viewModel.animeItems.first?.id) { _, _ in
            syncExploreAtmosphere()
        }
        .onChange(of: viewModel.animeItems.count) { _, _ in
            rebuildDisplayedAnimeItems()
        }
        .onChange(of: selectedSort) { _, _ in
            rebuildDisplayedAnimeItems()
        }
        .onChange(of: sortAscending) { _, _ in
            rebuildDisplayedAnimeItems()
        }
    }

    // MARK: - Hero Section

    private var heroSection: some View {
        VStack(alignment: .leading, spacing: 18) {
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

            HStack(spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.52))

                    TextField(t("anime.searchAnime"), text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))
                        .onSubmit {
                            searchTask?.cancel()
                            Task {
                                await viewModel.search()
                            }
                        }

                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                            selectedHotTag = nil
                            Task {
                                await viewModel.search()
                            }
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
                .frame(maxWidth: 460)
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

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(AnimeCategory.allCases) { category in
                        AnimeCategoryChip(
                            category: category,
                            isSelected: selectedCategory == category
                        ) {
                            withAnimation(AppFluidMotion.interactiveSpring) {
                                selectedCategory = category
                                selectedHotTag = nil
                                isTagSearchActive = true
                                searchTask?.cancel()
                                searchText = ""
                                viewModel.searchText = ""
                                Task {
                                    await viewModel.fetchByCategory(category)
                                }
                            }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                Text(t("anime.hotTags"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(AnimeHotTag.allCases) { tag in
                            AnimeHotTagChip(tag: tag, isSelected: selectedHotTag == tag) {
                                withAnimation(AppFluidMotion.interactiveSpring) {
                                    let newTag = selectedHotTag == tag ? nil : tag
                                    selectedHotTag = newTag
                                    selectedCategory = .all
                                    isTagSearchActive = true
                                    searchTask?.cancel()
                                    searchText = ""
                                    viewModel.searchText = ""
                                    Task {
                                        if let tagToSearch = newTag {
                                            print("[AnimeExploreView] Tag clicked: \(tagToSearch.displayName)")
                                            await viewModel.searchByTagName(tagToSearch.displayName)
                                        } else {
                                            print("[AnimeExploreView] Tag deselected, fetching popular")
                                            await viewModel.fetchPopular()
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: 700, alignment: .leading)
    }

    // MARK: - Anime Grid Section

    private func animeSection(gridContentWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .center) {
                Text("\(displayedAnimeItems.count) \(t("content.animes"))")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.66))

                Spacer()

                Menu {
                    ForEach(AnimeSortOption.allCases) { option in
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

            if viewModel.isLoading && displayedAnimeItems.isEmpty {
                AnimeGridSkeleton(contentWidth: gridContentWidth)
                    .padding(.top, 20)
                    .transition(.opacity.animation(.easeInOut(duration: 0.25)))
            } else if displayedAnimeItems.isEmpty {
                emptyState
                    .transition(.opacity.animation(.easeInOut(duration: 0.25)))
            } else {
                animeGrid(contentWidth: gridContentWidth)

                if viewModel.isLoadingMore || (viewModel.isLoading && !displayedAnimeItems.isEmpty) {
                    LoadingMoreIndicator()
                        .padding(.vertical, 20)
                }
            }
        }
    }

    // MARK: - Anime Grid (LazyVGrid)

    private func animeGrid(contentWidth: CGFloat) -> some View {
        let columnCount = contentWidth > 1200 ? 5 : (contentWidth > 800 ? 4 : 3)
        let spacing: CGFloat = 20
        let totalSpacing = CGFloat(columnCount - 1) * spacing
        let cardWidth = (contentWidth - totalSpacing) / CGFloat(columnCount)
        let cardHeight = cardWidth * 1.4  // 动漫卡片宽高比约 1:1.4
        
        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: columnCount),
            spacing: spacing
        ) {
            ForEach(Array(displayedAnimeItems.enumerated()), id: \.element.id) { index, anime in
                AnimeCard(
                    anime: anime,
                    index: index,
                    cardWidth: cardWidth,
                    cardHeight: cardHeight,
                    onTap: {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                            selectedAnime = anime
                        }
                    }
                )
            }
        }
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
                    type: .network,
                    message: errorMessage,
                    retryAction: {
                        Task { await viewModel.loadInitialData() }
                    }
                )
            } else {
                ErrorStateView(
                    type: .empty,
                    title: t("anime.noData"),
                    message: t("anime.tryDifferentSource"),
                    retryAction: {
                        Task { await viewModel.loadInitialData() }
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

    private func syncExploreAtmosphere() {
        if let firstAnime = displayedAnimeItems.first,
           let coverURL = firstAnime.coverURL {
            exploreAtmosphere.updateFirstAnime(coverURL: coverURL)
        }
    }

    private func rebuildDisplayedAnimeItems() {
        let source = viewModel.animeItems
        
        let newItems: [AnimeSearchResult]
        switch selectedSort {
        case .newest:
            newItems = sortAscending ? source.reversed() : source
        case .title:
            newItems = source.sorted { lhs, rhs in
                let cmp = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
                if cmp == .orderedSame { return false }
                return sortAscending ? cmp == .orderedDescending : cmp == .orderedAscending
            }
        case .popular:
            newItems = source.sorted { lhs, rhs in
                let lhsScore = Double(lhs.rating ?? "0") ?? 0
                let rhsScore = Double(rhs.rating ?? "0") ?? 0
                if lhsScore == rhsScore {
                    return lhs.rank ?? Int.max < rhs.rank ?? Int.max
                }
                return sortAscending ? lhsScore < rhsScore : lhsScore > rhsScore
            }
        }
        
        displayedAnimeItems = newItems
        syncExploreAtmosphere()
    }
    
    private func resetAllFilters() {
        searchText = ""
        selectedHotTag = nil
        selectedCategory = .all
        selectedSort = .newest
        sortAscending = false

        Task {
            await viewModel.loadInitialData()
        }
    }
}

// MARK: - Anime Card with Entrance Animation

private struct AnimeCard: View {
    let anime: AnimeSearchResult
    let index: Int
    let cardWidth: CGFloat
    let cardHeight: CGFloat
    let onTap: () -> Void
    
    @State private var isVisible = false
    
    var body: some View {
        AnimePortraitCard(
            anime: anime,
            cardWidth: cardWidth,
            cardHeight: cardHeight
        ) {
            onTap()
        }
        .opacity(isVisible ? 1 : 0)
        .offset(y: isVisible ? 0 : 30)
        .scaleEffect(isVisible ? 1 : 0.9)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)
                .delay(Double(min(index % 8, 4)) * 0.05)) {
                isVisible = true
            }
        }
    }
}

// MARK: - Hot Tag Chip

private struct AnimeHotTagChip: View {
    let tag: AnimeHotTag
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(tag.displayName)
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

private struct AnimeCategoryChip: View {
    let category: AnimeCategory
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

                Text(category.displayName)
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

// MARK: - Sort Options

private enum AnimeSortOption: String, CaseIterable, Identifiable {
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
}

// MARK: - Grid Skeleton

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

// MARK: - Card Skeleton

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
