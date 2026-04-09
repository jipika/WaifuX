import SwiftUI
import AppKit

// MARK: - 壁纸探索页（方案C：纯SwiftUI + 流畅动画 + 自适应列数）
struct WallpaperExploreContentView: View {
    @ObservedObject var viewModel: WallpaperViewModel
    @Binding var selectedWallpaper: Wallpaper?
    @StateObject private var exploreAtmosphere = ExploreAtmosphereController(wallpaperMode: true)
    
    // MARK: - 状态管理
    @State private var selectedCategory: ExploreCategoryFilter = .all
    @State private var selectedHotTag: ExploreHotTag?
    @State private var searchText = ""
    @State private var displayedWallpapers: [Wallpaper] = []
    @State private var isLoadingMore = false
    @State private var showProtectedPurityAlert = false
    @State private var isInitialLoading = false
    @State private var scrollOffset: CGFloat = 0
    
    // MARK: - 动画状态
    @State private var visibleCardIDs: Set<String> = []
    @State private var isFirstAppear = true
    
    // MARK: - Task 管理
    @State private var searchTask: Task<Void, Never>?
    @State private var loadMoreTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geometry in
            let contentWidth = max(0, geometry.size.width - 56)
            let gridConfig = WallpaperGridConfig(contentWidth: contentWidth)
            
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 34, pinnedViews: []) {
                    heroSection
                    categorySection
                    quickFilterSection
                    activeFiltersSection
                    wallpaperSection(gridConfig: gridConfig)
                }
                .padding(.horizontal, 28)
                .padding(.top, 80)
                .padding(.bottom, 48)
                .frame(width: geometry.size.width, alignment: .center)
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
                    referenceImage: exploreAtmosphere.referenceImage,
                    lightweightBackdrop: false
                )
            )
        }
        .alert(t("apiKeyRequired"), isPresented: $showProtectedPurityAlert) {
            Button(t("ok"), role: .cancel) {}
        } message: {
            Text(t("apiKeyNeeded"))
        }
        .onAppear {
            handleOnAppear()
        }
        .onChange(of: selectedCategory) { _, _ in handleCategoryChange() }
        .onChange(of: selectedHotTag) { _, _ in handleHotTagChange() }
        .onChange(of: viewModel.sortingOption) { _, _ in reloadData() }
        .onChange(of: viewModel.orderDescending) { _, _ in reloadData() }
        .onChange(of: viewModel.wallpapers) { oldVal, newVal in
            handleWallpapersChange(oldVal: oldVal, newVal: newVal)
        }
        .onDisappear {
            loadMoreTask?.cancel()
        }
    }
    
    // MARK: - 事件处理
    
    private func handleOnAppear() {
        if searchText.isEmpty {
            searchText = viewModel.searchQuery
        }
        
        if viewModel.wallpapers.isEmpty {
            isInitialLoading = true
            Task {
                await viewModel.search()
                await MainActor.run {
                    rebuildVisibleWallpapers()
                    syncExploreAtmosphere()
                    isInitialLoading = false
                    isFirstAppear = false
                }
            }
        } else {
            rebuildVisibleWallpapers()
            syncExploreAtmosphere()
            isFirstAppear = false
        }
    }
    
    private func triggerLoadMore() {
        guard viewModel.hasMorePages,
              !viewModel.isLoading,
              !isLoadingMore else { return }
        
        loadMoreTask?.cancel()
        loadMoreTask = Task {
            isLoadingMore = true
            defer { isLoadingMore = false }
            await viewModel.loadMore()
        }
    }

    /// 通过 scrollOffset 检测是否滚动到底部触发加载更多
    /// - Parameter offset: 滚动偏移量（已取反，正值表示向上滚动的距离）
    private func checkLoadMore(offset: CGFloat) {
        let threshold: CGFloat = 600 // 向上滚动超过 600pt 触发加载
        guard offset > threshold,
              viewModel.hasMorePages else { return }

        // 防死锁：如果 isLoading 卡住超过 3 秒，强制允许重试
        if viewModel.isLoading || isLoadingMore {
            if let loadMoreTask, !loadMoreTask.isCancelled {
                // 已有进行中的加载任务，不重复触发
                return
            }
            // 任务已完成但状态未重置（异常情况），强制继续
        }

        loadMoreTask?.cancel()
        loadMoreTask = Task {
            isLoadingMore = true
            defer { isLoadingMore = false }
            await viewModel.loadMore()
        }
    }
    
    private func handleCategoryChange() {
        switch selectedCategory {
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
    
    private func handleHotTagChange() {
        displayedWallpapers = []
        reloadData()
    }
    
    private func handleWallpapersChange(oldVal: [Wallpaper], newVal: [Wallpaper]) {
        if newVal.isEmpty || displayedWallpapers.isEmpty {
            rebuildVisibleWallpapers()
        } else if !oldVal.isEmpty, newVal.count > oldVal.count {
            appendNewWallpapers()
        } else {
            rebuildVisibleWallpapers()
        }
    }
    
    private func reloadData() {
        displayedWallpapers = []
        visibleCardIDs.removeAll()
        Task {
            await viewModel.search()
        }
    }
    
    private func syncExploreAtmosphere() {
        exploreAtmosphere.updateFirstWallpaper(displayedWallpapers.first)
    }
}

// MARK: - 网格配置（保持原有逻辑）
struct WallpaperGridConfig {
    let columnCount: Int
    let spacing: CGFloat
    let cardWidth: CGFloat
    let cardHeight: CGFloat
    let contentWidth: CGFloat
    
    init(contentWidth: CGFloat) {
        self.contentWidth = contentWidth
        self.columnCount = contentWidth > 1200 ? 4 : (contentWidth > 800 ? 3 : 2)
        self.spacing = 16
        let totalSpacing = spacing * CGFloat(columnCount - 1)
        self.cardWidth = floor((contentWidth - totalSpacing) / CGFloat(columnCount))
        self.cardHeight = cardWidth * 0.6
    }
    
    var gridItems: [GridItem] {
        Array(repeating: GridItem(.fixed(cardWidth), spacing: spacing), count: columnCount)
    }
    
    func calculateTotalHeight(itemCount: Int) -> CGFloat {
        guard itemCount > 0 else { return 0 }
        let rows = ceil(Double(itemCount) / Double(columnCount))
        let totalCardHeight = cardHeight + 44 // 底部信息栏约 44pt
        return CGFloat(rows * Double(totalCardHeight) + max(0, rows - 1) * Double(spacing) + 40)
    }
}

// MARK: - 视图 Sections
private extension WallpaperExploreContentView {
    
    var heroSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(greetingText)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.58))
                    
                    Text("Wallhaven")
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
                
                Text(t("wallpaperLibrary"))
                    .font(.system(size: 32, weight: .bold, design: .serif))
                    .tracking(-0.5)
                    .foregroundStyle(.white.opacity(0.98))
                    .lineLimit(1)
            }
            
            HStack(spacing: 12) {
                searchBar
                resetButton
            }
            
            HStack(alignment: .center, spacing: 10) {
                Text(t("hotWallpaper") + ":")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.42))
                
                ForEach(ExploreHotTag.allCases) { tag in
                    ExploreHotTagChip(
                        tag: tag,
                        isSelected: selectedHotTag == tag
                    ) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            selectedHotTag = (selectedHotTag == tag) ? nil : tag
                        }
                    }
                }
                
                ratioMenu
            }
        }
        .frame(maxWidth: 700, alignment: .leading)
    }
    
    var searchBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.54))
            
            TextField(t("search.placeholder"), text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .onSubmit {
                    submitSearch()
                }
            
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    selectedHotTag = nil
                    submitSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.38))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: 460)
        .frame(height: 46)
        .liquidGlassSurface(
            .prominent,
            tint: exploreAtmosphere.tint.primary.opacity(0.12),
            in: Capsule(style: .continuous)
        )
    }
    
    var resetButton: some View {
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
    
    var ratioMenu: some View {
        Menu {
            Button(t("allRatios")) {
                viewModel.selectedRatios = []
                reloadData()
            }
            Divider()
            ForEach(["16x9", "16x10", "21x9", "4x3", "3x2", "1x1", "9x16", "10x16"], id: \.self) { ratio in
                let isSelected = viewModel.selectedRatios.contains(ratio)
                Button {
                    viewModel.selectedRatios = isSelected ? [] : [ratio]
                    reloadData()
                } label: {
                    HStack {
                        Text(ratio.replacingOccurrences(of: "x", with: ":"))
                        if isSelected {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            let hasRatio = !viewModel.selectedRatios.isEmpty
            HStack(spacing: 6) {
                Image(systemName: "aspectratio")
                    .font(.system(size: 11, weight: .semibold))
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
    
    var categorySection: some View {
        FlowLayout(spacing: 12) {
            ForEach(ExploreCategoryFilter.allCases) { category in
                ExploreCategoryChip(
                    category: category,
                    isSelected: selectedCategory == category
                ) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        selectedCategory = category
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
    
    var quickFilterSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                Text(t("contentLevel"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.46))
                FlowLayout(spacing: 10) {
                    ForEach(visiblePurityFilters) { filter in
                        QuickFilterChip(
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
            
            VStack(alignment: .leading, spacing: 10) {
                Text(t("colorFilter"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.46))
                FlowLayout(spacing: 10) {
                    ForEach(quickColorPresets) { preset in
                        QuickColorChip(
                            preset: preset,
                            isSelected: viewModel.selectedColors.first == preset.hex
                        ) {
                            toggleColor(preset)
                        }
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    var activeFiltersSection: some View {
        let chips = currentFilterChips
        if !chips.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Text(t("currentFilters"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.46))
                    Button {
                        resetServerFilters()
                    } label: {
                        Text(t("clear"))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.72))
                    }
                    .buttonStyle(.plain)
                }
                FlowLayout(spacing: 10) {
                    ForEach(chips) { chip in
                        ActiveFilterChipView(chip: chip) {
                            removeFilter(chip)
                        }
                    }
                }
            }
        }
    }
    
    func wallpaperSection(gridConfig: WallpaperGridConfig) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            // 标题栏
            HStack(alignment: .center) {
                Text("\(displayedWallpapers.count) \(t("wallpaperCount"))")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.66))
                
                Spacer()
                
                Menu {
                    ForEach(SortingOption.allCases, id: \.self) { option in
                        Button(sortingOptionDisplayName(option)) {
                            viewModel.sortingOption = option
                            reloadData()
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 13, weight: .semibold))
                        Text(sortingOptionDisplayName(viewModel.sortingOption))
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
            
            // 内容区域
            if viewModel.isLoading && displayedWallpapers.isEmpty {
                WallpaperGridSkeleton(contentWidth: gridConfig.contentWidth)
                    .padding(.top, 20)
                    .transition(.opacity.animation(.easeInOut(duration: 0.25)))
            } else if displayedWallpapers.isEmpty {
                emptyState
                    .transition(.opacity.animation(.easeInOut(duration: 0.25)))
            } else {
                // 使用 LazyVGrid，固定卡片尺寸
                LazyVGrid(columns: gridConfig.gridItems, alignment: .leading, spacing: gridConfig.spacing) {
                    ForEach(Array(displayedWallpapers.enumerated()), id: \.element.id) { index, wallpaper in
                        WallpaperCard(
                            wallpaper: wallpaper,
                            isFavorite: viewModel.isFavorite(wallpaper),
                            index: index,
                            cardWidth: gridConfig.cardWidth,
                            cardHeight: gridConfig.cardHeight
                        )
                        .onTapGesture {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                selectedWallpaper = wallpaper
                            }
                        }
                        .onAppear {
                            // 标记卡片可见，触发入场动画
                            let _ = withAnimation(.spring(response: 0.5, dampingFraction: 0.8).delay(Double(min(index % 8, 4)) * 0.05)) {
                                visibleCardIDs.insert(wallpaper.id)
                            }
                            // 预加载附近图片
                            preloadNearbyImages(for: index)
                        }
                        .opacity(visibleCardIDs.contains(wallpaper.id) ? 1 : 0)
                        .offset(y: visibleCardIDs.contains(wallpaper.id) ? 0 : 30)
                        .scaleEffect(visibleCardIDs.contains(wallpaper.id) ? 1 : 0.9)
                        .scrollTransition { content, phase in
                            content
                                .scaleEffect(phase.isIdentity ? 1 : 0.95)
                                .opacity(phase.isIdentity ? 1 : 0.8)
                        }
                    }
                }
                .frame(height: gridConfig.calculateTotalHeight(itemCount: displayedWallpapers.count))

                // 分页加载指示器
                if isLoadingMore || (viewModel.isLoading && !displayedWallpapers.isEmpty) {
                    LoadingMoreIndicator()
                        .padding(.vertical, 20)
                        .transition(.opacity.animation(.easeInOut(duration: 0.2)))
                }
                
                // 没有更多提示
                if !isLoadingMore && !viewModel.hasMorePages && !viewModel.isLoading && !displayedWallpapers.isEmpty {
                    NoMoreFooter()
                        .padding(.vertical, 20)
                }
            }
        }
    }
    
    var emptyState: some View {
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
    
    // MARK: - 辅助方法
    
    func preloadNearbyImages(for index: Int) {
        let preloadRange = (index + 1)...(index + 6)
        let urls = preloadRange
            .filter { $0 < displayedWallpapers.count }
            .compactMap { displayedWallpapers[$0].thumbURL }
        
        ImagePreloader.shared.preloadImages(from: urls)
    }
    
    func submitSearch() {
        selectedHotTag = nil
        viewModel.searchQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        reloadData()
    }
    
    func resetAllFilters() {
        searchText = ""
        viewModel.searchQuery = ""
        selectedCategory = .all
        selectedHotTag = nil
        viewModel.puritySFW = true
        viewModel.puritySketchy = false
        viewModel.purityNSFW = false
        viewModel.sortingOption = .dateAdded
        viewModel.orderDescending = true
        viewModel.selectedColors = []
        viewModel.selectedRatios = []
        viewModel.selectedResolutions = []
        viewModel.atleastResolution = nil
        
        Task {
            await viewModel.search()
        }
    }
    
    private func rebuildVisibleWallpapers() {
        let filtered = viewModel.wallpapers.filter { wallpaper in
            matchesCategory(wallpaper, category: selectedCategory)
        }
        displayedWallpapers = filtered
        syncExploreAtmosphere()
    }
    
    private func appendNewWallpapers() {
        let existingIDs = Set(displayedWallpapers.map(\.id))
        let newWallpapers = viewModel.wallpapers.filter { !existingIDs.contains($0.id) }
        guard !newWallpapers.isEmpty else { return }
        displayedWallpapers.append(contentsOf: newWallpapers)
    }
    
    private func matchesCategory(_ wallpaper: Wallpaper, category: ExploreCategoryFilter) -> Bool {
        switch category {
        case .all: return true
        case .general: return wallpaper.category.lowercased() == "general"
        case .anime: return wallpaper.category.lowercased() == "anime"
        case .people: return wallpaper.category.lowercased() == "people"
        }
    }
    
    var greetingText: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Good Morning"
        case 12..<18: return "Good Afternoon"
        default: return "Good Evening"
        }
    }
}


// MARK: - 壁纸卡片（带固定宽高和流畅动画）
private struct WallpaperCard: View {
    let wallpaper: Wallpaper
    let isFavorite: Bool
    let index: Int
    let cardWidth: CGFloat
    let cardHeight: CGFloat
    
    @State private var isHovered = false
    
    // 预计算属性
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
            // 图片区域 - 固定宽高
            ZStack {
                OptimizedAsyncImage(
                    url: wallpaper.thumbURL ?? wallpaper.smallThumbURL,
                    priority: .medium
                ) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    placeholderGradient
                }
            }
            .frame(width: cardWidth, height: cardHeight)
            .clipShape(UnevenRoundedRectangle(
                topLeadingRadius: 14,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 14,
                style: .continuous
            ))
            .overlay(alignment: .topLeading) {
                metadataRow
                    .padding(10)
            }
            
            // 底部信息栏
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
            .frame(width: cardWidth, alignment: .leading)
            .background(Color.black.opacity(0.46))
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(borderColor, lineWidth: borderWidth)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.spring(response: 0.2, dampingFraction: 0.85), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
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
            if let primaryColorHex = wallpaper.primaryColorHex {
                footerColorTag(hex: primaryColorHex)
            }
            
            statLabel(
                systemImage: "heart.fill",
                value: compactNumber(wallpaper.favorites),
                tint: isFavorite ? Color(hex: "FF5A7D") : .white.opacity(0.5)
            )
            
            statLabel(
                systemImage: "eye.fill",
                value: compactNumber(wallpaper.views),
                tint: .white.opacity(0.5)
            )
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
            Circle()
                .fill(Color(hex: "#\(hex)"))
                .frame(width: 8, height: 8)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.22), lineWidth: 0.5)
                )
            
            Text("#\(hex)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(Color.black.opacity(0.22), in: Capsule(style: .continuous))
    }
    
    func statLabel(systemImage: String, value: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .bold))
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
        }
        .foregroundStyle(tint)
    }
    
    var placeholderGradient: some View {
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
    
    func compactNumber(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000)
        }
        return "\(value)"
    }
}

// MARK: - 加载更多指示器
private struct LoadingMoreIndicator: View {
    @State private var isAnimating = false
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.2.circlepath")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .rotationEffect(.degrees(isAnimating ? 360 : 0))
                .onAppear {
                    withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
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

// MARK: - 没有更多提示
private struct NoMoreFooter: View {
    var body: some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(Color.white.opacity(0.15))
                .frame(height: 1)
            
            Text("— \(t("noMore")) —")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.25))
            
            Rectangle()
                .fill(Color.white.opacity(0.15))
                .frame(height: 1)
        }
        .padding(.horizontal, 40)
    }
}

// MARK: - 原有组件定义

private extension WallpaperExploreContentView {
    var quickColorPresets: [WallhavenAPI.ColorPreset] {
        let preferredHexes = [
            "990000", "ea4c88", "993399", "0066cc", "0099cc", "66cccc",
            "669900", "999900", "ffff00", "ff9900", "ff6600", "424153"
        ]
        return preferredHexes.compactMap { WallhavenAPI.colorPreset(for: $0) }
    }
    
    /// 根据 API Key 配置返回可见的内容分级筛选器（无 API Key 时隐藏 NSFW）
    var visiblePurityFilters: [ExplorePurityFilter] {
        if viewModel.apiKeyConfigured {
            return Array(ExplorePurityFilter.allCases)
        } else {
            return [.sfw, .sketchy]
        }
    }
    
    func isPuritySelected(_ filter: ExplorePurityFilter) -> Bool {
        switch filter {
        case .sfw: return viewModel.puritySFW
        case .sketchy: return viewModel.puritySketchy
        case .nsfw: return viewModel.purityNSFW
        }
    }
    
    func togglePurity(_ filter: ExplorePurityFilter) {
        if filter.requiresAPIKey && !viewModel.apiKeyConfigured {
            showProtectedPurityAlert = true
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
    
    var currentFilterChips: [ExploreFilterChipData] {
        var chips: [ExploreFilterChipData] = []
        if viewModel.puritySFW {
            chips.append(.init(kind: .purity(.sfw), title: "SFW", accentHex: "43C463"))
        }
        if viewModel.puritySketchy {
            chips.append(.init(kind: .purity(.sketchy), title: "Sketchy", accentHex: "FFB347"))
        }
        if viewModel.purityNSFW {
            chips.append(.init(kind: .purity(.nsfw), title: "NSFW", accentHex: "FF5A7D"))
        }
        if let hex = viewModel.selectedColors.first,
           let preset = WallhavenAPI.colorPreset(for: hex) {
            chips.append(.init(kind: .color(hex), title: preset.displayName, subtitle: preset.displayHex, accentHex: hex))
        }
        return chips
    }
    
    func resetServerFilters() {
        viewModel.puritySFW = true
        viewModel.puritySketchy = false
        viewModel.purityNSFW = false
        viewModel.selectedColors = []
        reloadData()
    }
    
    func removeFilter(_ chip: ExploreFilterChipData) {
        switch chip.kind {
        case .purity(let purity):
            switch purity {
            case .sfw: viewModel.puritySFW = false
            case .sketchy: viewModel.puritySketchy = false
            case .nsfw: viewModel.purityNSFW = false
            }
        case .color: viewModel.selectedColors = []
        default: break
        }
        reloadData()
    }
}

// MARK: - 组件定义

private struct QuickFilterChip: View {
    let title: String
    let subtitle: String
    let isSelected: Bool
    let tint: Color
    let action: () -> Void
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.94))
                Text(subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(tint.opacity(isSelected ? 0.15 : 0.08))
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
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

private struct QuickColorChip: View {
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
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.24), lineWidth: 0.6)
                    )
                Text(preset.displayHex)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.94))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.ultraThinMaterial)
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
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

private struct ActiveFilterChipView: View {
    let chip: ExploreFilterChipData
    let onRemove: () -> Void
    @State private var isHovered = false
    
    var body: some View {
        Button(action: onRemove) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(hex: "#\(chip.accentHex)"))
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(chip.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.94))
                    if let subtitle = chip.subtitle {
                        Text(subtitle)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.56))
                    }
                }
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(isHovered ? 0.95 : 0.72))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                ZStack {
                    Capsule(style: .continuous)
                        .fill(.ultraThinMaterial)
                    Capsule(style: .continuous)
                        .fill(Color(hex: "#\(chip.accentHex)").opacity(0.12))
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
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

private struct ExploreHotTagChip: View {
    let tag: ExploreHotTag
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            Text(tag.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(isSelected ? 0.95 : 0.78))
                .fixedSize()
                .padding(.horizontal, 12)
                .frame(height: 32, alignment: .center)
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
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

private struct ExploreCategoryChip: View {
    let category: ExploreCategoryFilter
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
                                colors: category.accentColors.map { Color(hex: $0) },
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: category.icon)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(isSelected ? .white : .black.opacity(0.75))
                }
                .frame(width: 22, height: 22)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(isSelected ? 0.18 : 0.08), lineWidth: 1)
                )
                Text(category.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(isSelected ? 0.96 : 0.84))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(
                ZStack {
                    Capsule(style: .continuous)
                        .fill(.ultraThinMaterial)
                    if let accentColor = category.accentColors.first {
                        Capsule(style: .continuous)
                            .fill(Color(hex: accentColor).opacity(isSelected ? 0.15 : 0.08))
                    }
                }
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(
                        (category.accentColors.first.map { Color(hex: $0) } ?? Color.white)
                            .opacity(isSelected ? 0.35 : 0.15),
                        lineWidth: 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered && !isSelected ? 1.02 : 1.0)
        .animation(AppFluidMotion.hoverEase, value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - 枚举定义

private enum ExplorePurityFilter: String, CaseIterable, Identifiable {
    case sfw
    case sketchy
    case nsfw
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
    var requiresAPIKey: Bool {
        self != .sfw
    }
}

private enum ExploreHotTag: String, CaseIterable, Identifiable {
    case ultraHD
    case ultrawide
    case ratio21x9
    case ratio32x9
    case ratio16x9
    case portrait
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
        switch self {
        case .ultraHD: return "3840x2160"
        default: return nil
        }
    }
}

private enum ExploreCategoryFilter: String, CaseIterable, Identifiable {
    case all
    case general
    case anime
    case people
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

private struct ExploreFilterChipData: Identifiable {
    enum Kind: Hashable {
        case purity(ExplorePurityFilter)
        case color(String)
        case resolution(String)
        case ratio(String)
        case atleast(String)
    }
    var id: String {
        switch kind {
        case .purity(let purity): return "purity_\(purity.rawValue)"
        case .color(let hex): return "color_\(hex)"
        case .resolution(let resolution): return "resolution_\(resolution)"
        case .ratio(let ratio): return "ratio_\(ratio)"
        case .atleast(let value): return "atleast_\(value)"
        }
    }
    let kind: Kind
    let title: String
    var subtitle: String? = nil
    let accentHex: String
}

// MARK: - SortingOption 扩展

extension SortingOption: CaseIterable {
    static var allCases: [SortingOption] {
        [.toplist, .dateAdded, .favorites, .views, .random, .relevance]
    }
}

private func sortingOptionDisplayName(_ option: SortingOption) -> String {
    switch option {
    case .dateAdded: return t("sort.latest")
    case .views: return t("sort.views")
    case .favorites: return t("sort.likes")
    case .toplist: return t("sort.toplist")
    case .random: return t("sort.random")
    case .relevance: return t("sort.relevance")
    }
}

// MARK: - Scroll offset

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
                    let threshold: CGFloat = 600
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

struct ScrollOffsetPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
