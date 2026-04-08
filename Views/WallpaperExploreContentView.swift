import SwiftUI
import AppKit
// MARK: - WallpaperExploreContentView - 壁纸探索页
struct WallpaperExploreContentView: View {
    @ObservedObject var viewModel: WallpaperViewModel
    @Binding var selectedWallpaper: Wallpaper?
    @StateObject private var exploreAtmosphere = ExploreAtmosphereController(wallpaperMode: true)
    @State private var selectedCategory: ExploreCategoryFilter = .all
    @State private var selectedHotTag: ExploreHotTag?
    @State private var searchText = ""
    @State private var displayedWallpapers: [Wallpaper] = []
    @State private var isLoadingMore = false
    @State private var showProtectedPurityAlert = false

    // Task 管理
    @State private var searchTask: Task<Void, Never>?
    @State private var loadMoreTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geometry in
            let gridContentWidth = max(0, geometry.size.width - 56)
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 34) {
                    heroSection
                    categorySection
                    quickFilterSection
                    activeFiltersSection
                    wallpaperSection(gridContentWidth: gridContentWidth)
                }
                .padding(.horizontal, 28)
                .padding(.top, 80)
                .padding(.bottom, 48)
                .frame(width: geometry.size.width, alignment: .center)
                .environment(\.explorePageAtmosphereTint, exploreAtmosphere.tint)
            }
            // 命名坐标空间，供视差效果使用
            .coordinateSpace(name: "exploreScroll")
            // iOS 风格弹性滚动：惯性减速 + 弹性边界
            .iosSmoothScroll()
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
            if searchText.isEmpty {
                searchText = viewModel.searchQuery
            }
            // 初始加载：如果壁纸数据为空，触发搜索加载
            // 注意：isLoading卡住时也需要尝试重新加载
            if viewModel.wallpapers.isEmpty {
                Task {
                    await viewModel.search()
                    // 搜索完成后在主线程重建显示列表
                    await MainActor.run {
                        rebuildVisibleWallpapers()
                        syncExploreAtmosphere()
                    }
                }
            } else {
                // 数据已存在，直接重建显示列表
                rebuildVisibleWallpapers()
                syncExploreAtmosphere()
            }
        }
        .onChange(of: selectedCategory) { newCategory, _ in
            // 将分类映射到 ViewModel 的 API 参数并触发服务端搜索
            switch newCategory {
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
            // 清空本地缓存列表，触发 API 重新请求
            displayedWallpapers = []
            cancelAndSearch()
        }
        .onChange(of: selectedHotTag) { _, _ in
            // 筛选条件变化时完全重建
            displayedWallpapers = []
            rebuildVisibleWallpapers()
        }
        .onChange(of: viewModel.sortingOption) { _, _ in rebuildVisibleWallpapers() }
        .onChange(of: viewModel.orderDescending) { _, _ in rebuildVisibleWallpapers() }
        .onChange(of: viewModel.wallpapers) { oldVal, newVal in
            // 当壁纸数据变化时，增量追加新数据而非全量重建
            // 只有当数据源完全替换（如搜索、重置）时才全量重建
            if newVal.isEmpty || displayedWallpapers.isEmpty {
                rebuildVisibleWallpapers()
            } else if !oldVal.isEmpty, newVal.count > oldVal.count {
                // 数据追加场景：只追加新数据，避免 LazyVGrid 全量刷新
                appendNewWallpapers()
            } else {
                rebuildVisibleWallpapers()
            }
        }
        .onChange(of: displayedWallpapers.first?.id) { _, _ in
            syncExploreAtmosphere()
        }
        .onDisappear {
            // 视图消失时取消所有任务
            cancelAllTasks()
        }
    }

    private func syncExploreAtmosphere() {
        exploreAtmosphere.updateFirstWallpaper(displayedWallpapers.first)
    }

    // MARK: - 视图 Section
    private var heroSection: some View {
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
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.54))
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
                                .foregroundStyle(.white.opacity(0.38))
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
                    tint: exploreAtmosphere.tint.primary.opacity(0.12),
                    in: Capsule(style: .continuous)
                )
                // 重置按钮 - 在搜索栏外面，深色液态玻璃风格
                Button {
                    resetAllFilters()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .frame(width: 46, height: 46)
                        // contentShape 必须在 liquidGlassSurface 之前，确保整个圆形区域可点击
                        .contentShape(Circle())
                        .liquidGlassSurface(
                            .prominent,
                            tint: exploreAtmosphere.tint.secondary.opacity(0.12),
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)
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
                        applyHotTag(tag)
                    }
                }
                // 比例筛选
                Menu {
                    Button(t("allRatios")) {
                        viewModel.selectedRatios = []
                        cancelAndSearch()
                    }
                    Divider()
                    ForEach(["16x9", "16x10", "21x9", "4x3", "3x2", "1x1", "9x16", "10x16"], id: \.self) { ratio in
                        let isSelected = viewModel.selectedRatios.contains(ratio)
                        Button {
                            if isSelected {
                                viewModel.selectedRatios.removeAll { $0 == ratio }
                            } else {
                                viewModel.selectedRatios = [ratio]
                            }
                            cancelAndSearch()
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
        }
        .frame(maxWidth: 700, alignment: .leading)
    }
    private var categorySection: some View {
        FlowLayout(spacing: 12) {
            ForEach(ExploreCategoryFilter.allCases) { category in
                ExploreCategoryChip(
                    category: category,
                    isSelected: selectedCategory == category
                ) {
                        withAnimation(AppFluidMotion.interactiveSpring) {
                        selectedCategory = category
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
    private var quickFilterSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                Text(t("contentLevel"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.46))
                FlowLayout(spacing: 10) {
                    ForEach(ExplorePurityFilter.allCases) { filter in
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
                            isSelected: selectedColorPreset?.hex.lowercased() == preset.hex.lowercased()
                        ) {
                            toggleColor(preset)
                        }
                    }
                }
            }
        }
    }
    @ViewBuilder
    private var activeFiltersSection: some View {
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
    private func wallpaperSection(gridContentWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .center) {
                Text("\(formattedWallpaperCount) \(t("wallpaperCount"))")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.66))
                Spacer()
                // 排序选择器
                Menu {
                    ForEach(SortingOption.allCases, id: \.self) { option in
                        Button(sortingOptionDisplayName(option)) {
                            viewModel.sortingOption = option
                            cancelAndSearch()
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
            if viewModel.isLoading && displayedWallpapers.isEmpty {
                // 骨架屏加载状态 - 初始加载
                WallpaperGridSkeleton(contentWidth: gridContentWidth)
                    .padding(.top, 20)
                    .transition(.opacity.animation(.easeInOut(duration: 0.25)))
            } else if displayedWallpapers.isEmpty {
                emptyState
                    .transition(.opacity.animation(.easeInOut(duration: 0.25)))
            } else {
                // 简单固定布局：根据窗口宽度决定列数
                let columnCount = gridContentWidth > 1200 ? 4 : (gridContentWidth > 800 ? 3 : 2)
                let spacing: CGFloat = 16
                let totalSpacing = spacing * CGFloat(columnCount - 1)
                // gridContentWidth 已是可用内容宽度（已扣除 padding），直接均分，floor 避免亚像素误差
                let cardWidth = floor((gridContentWidth - totalSpacing) / CGFloat(columnCount))
                let cardHeight = cardWidth * 0.6
                
                // 动态创建固定列
                let columns = Array(repeating: GridItem(.fixed(cardWidth), spacing: spacing), count: columnCount)
                
                LazyVGrid(
                    columns: columns,
                    alignment: .leading,
                    spacing: spacing
                ) {
                    ForEach(displayedWallpapers) { wallpaper in
                        // 预计算索引（用于入场动画交错延迟 + 分页加载定位）
                        let cardIndex = displayedWallpapers.firstIndex(where: { $0.id == wallpaper.id }) ?? 0

                        SimpleWallpaperCard(
                            wallpaper: wallpaper,
                            cardWidth: cardWidth,
                            cardHeight: cardHeight,
                            isFavorite: viewModel.isFavorite(wallpaper),
                            onTap: { selectedWallpaper = wallpaper }
                        )
                        // iOS 风格入场动画：淡入 + 上移 + 微缩放（每张卡片错开 30ms）
                        .iosFadeInOnAppear(index: cardIndex)
                        .onAppear {
                            guard cardIndex >= displayedWallpapers.count - 6 else { return }
                            guard viewModel.hasMorePages,
                                  !viewModel.isLoading,
                                  !isLoadingMore else { return }
                            isLoadingMore = true
                            Task {
                                await loadMoreUntilVisibleGrowth()
                                isLoadingMore = false
                            }
                        }
                    }

                    // 🍎 脉冲色块放在 grid 内部跨整行，占据布局空间
                    PaginationShimmerOverlay(
                        isLoading: isLoadingMore || (viewModel.isLoading && !displayedWallpapers.isEmpty),
                        hasMorePages: viewModel.hasMorePages
                    )
                    .gridCellColumns(columnCount)
                }
            }
        }
    }
    private var emptyState: some View {
        Group {
            if let errorMessage = viewModel.errorMessage {
                // 网络错误状态
                ErrorStateView(
                    type: viewModel.networkStatus.connectionState == .offline ? .offline : .network,
                    message: errorMessage,
                    retryAction: cancelAndSearch
                )
            } else {
                // 空数据状态
                ErrorStateView(
                    type: .empty,
                    title: t("no.wallpapers"),
                    message: t("tryDifferentFilter"),
                    retryAction: cancelAndSearch
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
    private var greetingText: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Good Morning"
        case 12..<18: return "Good Afternoon"
        default: return "Good Evening"
        }
    }
    private var formattedWallpaperCount: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: displayedWallpapers.count)) ?? "\(displayedWallpapers.count)"
    }
    private func submitSearch(with query: String) {
        selectedHotTag = nil
        viewModel.searchQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        cancelAndSearch()
    }

    /// 将热门标签映射为真实 Wallhaven API 参数并触发搜索
    private func applyHotTag(_ tag: ExploreHotTag) {
        // 切换选中状态
        let wasSelected = selectedHotTag == tag
        withAnimation(AppFluidMotion.interactiveSpring) {
            selectedHotTag = wasSelected ? nil : tag
        }

        if wasSelected {
            // 取消：清除该标签设置的所有参数，重新搜索
            clearHotTagAPIParams()
            cancelAndSearch()
            return
        }

        // 先清除之前可能残留的其他标签参数
        clearHotTagAPIParams()

        // 根据标签类型写入对应的 ViewModel 参数
        if let ratios = tag.apiRatios {
            viewModel.selectedRatios = ratios
        }
        if let atleast = tag.apiAtleast {
            viewModel.atleastResolution = atleast
        }

        cancelAndSearch()
    }

    /// 清除热门标签设置的 API 参数（保留用户手动设置的筛选条件）
    private func clearHotTagAPIParams() {
        viewModel.atleastResolution = nil
        if let currentTag = selectedHotTag {
            if currentTag.apiRatios != nil {
                viewModel.selectedRatios = []
            }
        }
    }
    private var activePurityLabels: [String] {
        var labels: [String] = []
        if viewModel.puritySFW { labels.append("SFW") }
        if viewModel.puritySketchy { labels.append("Sketchy") }
        if viewModel.purityNSFW { labels.append("NSFW") }
        return labels.isEmpty ? ["SFW"] : labels
    }
    private var selectedColorPreset: WallhavenAPI.ColorPreset? {
        guard let first = viewModel.selectedColors.first else { return nil }
        return WallhavenAPI.colorPreset(for: first)
    }
    private var quickColorPresets: [WallhavenAPI.ColorPreset] {
        let preferredHexes = [
            "990000", "ea4c88", "993399", "0066cc", "0099cc", "66cccc",
            "669900", "999900", "ffff00", "ff9900", "ff6600", "424153"
        ]
        var presets = preferredHexes.compactMap { hex in
            WallhavenAPI.colorPreset(for: hex)
        }
        if let selectedColorPreset, !presets.contains(selectedColorPreset) {
            presets.insert(selectedColorPreset, at: 0)
        }
        return presets
    }
    private var currentFilterChips: [ExploreFilterChipData] {
        var chips: [ExploreFilterChipData] = []
        if !viewModel.puritySFW || viewModel.puritySketchy || viewModel.purityNSFW {
            if viewModel.puritySFW {
                chips.append(.init(kind: .purity(.sfw), title: "SFW", accentHex: "43C463"))
            }
            if viewModel.puritySketchy {
                chips.append(.init(kind: .purity(.sketchy), title: "Sketchy", accentHex: "FFB347"))
            }
            if viewModel.purityNSFW {
                chips.append(.init(kind: .purity(.nsfw), title: "NSFW", accentHex: "FF5A7D"))
            }
        }
        if let colorPreset = selectedColorPreset {
            chips.append(.init(kind: .color(colorPreset.hex), title: colorPreset.displayName,subtitle: colorPreset.displayHex, accentHex: colorPreset.hex))
        }
        for resolution in viewModel.selectedResolutions {
            chips.append(.init(kind: .resolution(resolution), title: resolution, accentHex:"7A5CFF"))
        }
        if let atleast = viewModel.atleastResolution {
            chips.append(.init(kind: .atleast(atleast), title: "≥\(atleast)", accentHex: "E85D04"))
        }
        for ratio in viewModel.selectedRatios {
            chips.append(.init(kind: .ratio(ratio), title: ratio.replacingOccurrences(of: "x",with: ":"), accentHex: "5A7CFF"))
        }
        return chips
    }
    private func isPuritySelected(_ filter: ExplorePurityFilter) -> Bool {
        switch filter {
        case .sfw:
            return viewModel.puritySFW
        case .sketchy:
            return viewModel.puritySketchy
        case .nsfw:
            return viewModel.purityNSFW
        }
    }
    private func togglePurity(_ filter: ExplorePurityFilter) {
        if filter.requiresAPIKey && !viewModel.apiKeyConfigured {
            showProtectedPurityAlert = true
            return
        }
        let currentlySelected = isPuritySelected(filter)
        let activeCount = [viewModel.puritySFW, viewModel.puritySketchy,viewModel.purityNSFW].filter { $0 }.count
        if currentlySelected && activeCount == 1 {
            return
        }
        switch filter {
        case .sfw:
            viewModel.puritySFW.toggle()
        case .sketchy:
            viewModel.puritySketchy.toggle()
        case .nsfw:
            viewModel.purityNSFW.toggle()
        }
        cancelAndSearch()
    }
    private func toggleColor(_ preset: WallhavenAPI.ColorPreset) {
        if selectedColorPreset?.hex.lowercased() == preset.hex.lowercased() {
            viewModel.selectedColors = []
        } else {
            viewModel.selectedColors = [preset.hex]
        }
        cancelAndSearch()
    }
    private func resetServerFilters() {
        viewModel.puritySFW = true
        viewModel.puritySketchy = false
        viewModel.purityNSFW = false
        viewModel.selectedColors = []
        viewModel.selectedRatios = []
        viewModel.selectedResolutions = []
        viewModel.atleastResolution = nil
        cancelAndSearch()
    }
    private func removeFilter(_ chip: ExploreFilterChipData) {
        switch chip.kind {
        case .purity(let purity):
            if activePurityLabels.count <= 1 {
                return
            }
            switch purity {
            case .sfw:
                viewModel.puritySFW = false
            case .sketchy:
                viewModel.puritySketchy = false
            case .nsfw:
                viewModel.purityNSFW = false
            }
        case .color:
            viewModel.selectedColors = []
        case .resolution(let resolution):
            viewModel.selectedResolutions.removeAll { $0 == resolution }
        case .ratio(let ratio):
            viewModel.selectedRatios.removeAll { $0 == ratio }
            // 如果热门标签设置了该比例，取消选中
            if let tag = selectedHotTag, let tagRatios = tag.apiRatios, tagRatios.contains(ratio) {
                selectedHotTag = nil
            }
        case .atleast:
            viewModel.atleastResolution = nil
            // 取消关联的热门标签选中状态
            if selectedHotTag?.apiAtleast != nil {
                selectedHotTag = nil
            }
        }
        cancelAndSearch()
    }
    private func filterSummaryPill(title: String, value: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(0.46))
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        .liquidGlassSurface(
            .regular,
            tint: accent.opacity(0.12),
            in: Capsule(style: .continuous)
        )
    }
    private func matchesCategory(_ wallpaper: Wallpaper, category: ExploreCategoryFilter) -> Bool {
        switch category {
        case .all:
            return true
        case .general:
            return wallpaper.category.lowercased() == "general"
        case .anime:
            return wallpaper.category.lowercased() == "anime"
        case .people:
            return wallpaper.category.lowercased() == "people"
        }
    }
    private func matchesHotTag(_ wallpaper: Wallpaper, tag: ExploreHotTag) -> Bool {
        // 所有标签都已通过 API 参数筛选（ratios/atleast），无需客户端二次过滤
        return true
    }
    private func rebuildVisibleWallpapers() {
        print("[WallpaperExplore] Rebuilding visible wallpapers. viewModel.wallpapers.count: \(viewModel.wallpapers.count)")
        
        // 快速路径：如果数据量小，直接在主线程处理
        if viewModel.wallpapers.count < 100 {
            let filtered = filterWallpapers(
                viewModel.wallpapers,
                category: selectedCategory,
                hotTag: selectedHotTag
            )
            displayedWallpapers = filtered
            syncExploreAtmosphere()
            print("[WallpaperExplore] Updated displayedWallpapers to \(displayedWallpapers.count)")
            return
        }
        
        // 大数据量时在后台线程执行过滤
        let wallpapers = viewModel.wallpapers
        let category = selectedCategory
        let hotTag = selectedHotTag
        
        Task.detached(priority: .userInitiated) {
            let filtered = Self.filterWallpapersStatic(
                wallpapers,
                category: category,
                hotTag: hotTag
            )
            
            await MainActor.run {
                displayedWallpapers = filtered
                syncExploreAtmosphere()
                print("[WallpaperExplore] Updated displayedWallpapers to \(displayedWallpapers.count)")
            }
        }
    }
    
    /// 实例方法过滤（主线程使用）
    private func filterWallpapers(
        _ wallpapers: [Wallpaper],
        category: ExploreCategoryFilter,
        hotTag: ExploreHotTag?
    ) -> [Wallpaper] {
        let categoryFiltered = wallpapers.filter { matchesCategory($0, category: category) }
        if let hotTag {
            return categoryFiltered.filter { matchesHotTag($0, tag: hotTag) }
        }
        return categoryFiltered
    }
    
    /// 静态方法过滤（后台线程使用）
    private nonisolated static func filterWallpapersStatic(
        _ wallpapers: [Wallpaper],
        category: ExploreCategoryFilter,
        hotTag: ExploreHotTag?
    ) -> [Wallpaper] {
        let categoryFiltered = wallpapers.filter { wallpaper in
            switch category {
            case .all: return true
            case .general: return wallpaper.category.lowercased() == "general"
            case .anime: return wallpaper.category.lowercased() == "anime"
            case .people: return wallpaper.category.lowercased() == "people"
            }
        }
        
        guard let hotTag else { return categoryFiltered }
        
        return categoryFiltered.filter { wallpaper in
            // 所有热门标签都已通过 API 参数筛选，无需客户端二次过滤
            return true
        }
    }
    /// 增量追加新壁纸（用于 loadMore 场景）
    private func appendNewWallpapers() {
        // 获取当前应该显示的所有壁纸
        let categoryWallpapers = viewModel.wallpapers.filter { wallpaper in
            matchesCategory(wallpaper, category: selectedCategory)
        }
        let tagFilteredWallpapers: [Wallpaper]
        if let selectedHotTag {
            tagFilteredWallpapers = categoryWallpapers.filter { matchesHotTag($0, tag: selectedHotTag) }
        } else {
            tagFilteredWallpapers = categoryWallpapers
        }
        // 获取当前已显示的ID集合
        let existingIDs = Set(displayedWallpapers.map(\.id))
        // 只追加新数据
        let newWallpapers = tagFilteredWallpapers.filter { !existingIDs.contains($0.id) }
        guard !newWallpapers.isEmpty else { return }
        
        // 使用事务禁用动画，避免抖动
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            displayedWallpapers.append(contentsOf: newWallpapers)
        }
    }
    private func loadMoreUntilVisibleGrowth(maxAttempts: Int = 6) async {
        let initialVisibleCount = displayedWallpapers.count
        var attempts = 0
        defer { isLoadingMore = false }
        
        while attempts < maxAttempts, viewModel.hasMorePages {
            attempts += 1
            await viewModel.loadMore()
            appendNewWallpapers()
            if displayedWallpapers.count > initialVisibleCount {
                break
            }
        }
    }

    // MARK: - Task 管理

    /// 取消并执行新的搜索
    private func cancelAndSearch() {
        searchTask?.cancel()
        searchTask = Task {
            await viewModel.search()
            await MainActor.run {
                rebuildVisibleWallpapers()
                syncExploreAtmosphere()
            }
        }
    }

    /// 取消所有任务（视图消失时调用）
    private func cancelAllTasks() {
        searchTask?.cancel()
        loadMoreTask?.cancel()
        searchTask = nil
        loadMoreTask = nil
    }
}

// MARK: - 探索网格壁纸卡片（布局对齐 ContentView.WallpaperEditCard / 已下载壁纸）

private struct SimpleWallpaperCard: View {
    let wallpaper: Wallpaper
    let cardWidth: CGFloat
    let cardHeight: CGFloat
    /// 本地收藏：爱心与数字用粉红，否则灰色（Wallhaven 列表数字仍为接口 favorites）
    let isFavorite: Bool
    let onTap: () -> Void
    @State private var isHovered = false

    // 预计算所有条件属性（避免 body 中 switch/三目运算导致的重复求值）
    private var purityBorderColor: Color? {
        switch wallpaper.purity.lowercased() {
        case "nsfw":
            return Color(hex: "FF3B30")
        case "sketchy":
            return Color(hex: "FFB347")
        default:
            return nil
        }
    }
    
    // 预计算边框样式（避免每帧的条件分支）
    private var borderColor: Color { purityBorderColor ?? Color.white.opacity(0.06) }
    private var borderWidth: CGFloat { purityBorderColor != nil ? 2 : 1 }

    // 静态形状缓存，避免每次 body 重新创建
    private static let thumbShape = UnevenRoundedRectangle(
        topLeadingRadius: 14,
        bottomLeadingRadius: 0,
        bottomTrailingRadius: 0,
        topTrailingRadius: 14,
        style: .continuous
    )
    private static let cardShape = RoundedRectangle(cornerRadius: 16, style: .continuous)

    // 缓存分辨率显示字符串
    private var cachedResolutionDisplay: String {
        wallpaper.resolution.replacingOccurrences(of: "x", with: "×")
    }
    
    private var cachedFooterLine: String {
        if let name = wallpaper.uploader?.username.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return wallpaper.categoryDisplayName
    }
    
    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                // 图片区域 - 简化结构
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
                .clipShape(Self.thumbShape)
                .overlay(alignment: .topLeading) {
                    // 简化元数据行
                    simplifiedMetadataRow
                        .padding(10)
                }

                // 底部信息栏（与 WallpaperEditCard 信息栏一致）
                HStack(spacing: 12) {
                    // 上传者名称
                    Text(cachedFooterLine)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                        .layoutPriority(1)
                    
                    Spacer(minLength: 12)
                    
                    // 右侧统计信息（trailingMetadataRow）
                    trailingMetadataRow
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
                            .stroke(borderColor, lineWidth: borderWidth)
                    )
            )
            .clipShape(Self.cardShape)
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.02 : 1.0)
        // iOS 风格悬停：快速弹簧响应 + 自然减速释放
        .animation(.spring(response: 0.20, dampingFraction: 0.85), value: isHovered)
        .throttledHover(interval: 0.05) { hovering in
            isHovered = hovering
        }
    }
    
    // 顶部元数据行
    private var simplifiedMetadataRow: some View {
        HStack(alignment: .top, spacing: 12) {
            HStack(spacing: 6) {
                // 分类标签
                metaTag(text: wallpaper.categoryDisplayName)
                // 纯度标签（始终显示）
                metaTag(text: wallpaper.purityDisplayName)
            }
            
            Spacer(minLength: 0)
            
            // 分辨率
            metaTag(text: cachedResolutionDisplay)
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
    
    private func footerColorTag(hex: String) -> some View {
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
    
    private func statLabel(systemImage: String, value: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .bold))
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
        }
        .foregroundStyle(tint)
    }

    // 底部右侧统计信息行 - 简化版：使用 minimumScaleFactor 替代 ViewThatFits
    private var trailingMetadataRow: some View {
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
            
            if !wallpaper.fileSizeLabel.isEmpty {
                statLabel(
                    systemImage: "doc.fill",
                    value: wallpaper.fileSizeLabel,
                    tint: .white.opacity(0.4)
                )
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.75)
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

    private func compactNumber(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000)
        }
        return "\(value)"
    }
}

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

private struct ExploreFilterChipData: Identifiable {
    enum Kind: Hashable {
        case purity(ExplorePurityFilter)
        case color(String)
        case resolution(String)
        case ratio(String)
        case atleast(String)
    }

    // 使用稳定的 ID 基于 kind，避免每次重建都生成新的 UUID 导致 ForEach 全量重建
    var id: String {
        switch kind {
        case .purity(let purity):
            return "purity_\(purity.rawValue)"
        case .color(let hex):
            return "color_\(hex)"
        case .resolution(let resolution):
            return "resolution_\(resolution)"
        case .ratio(let ratio):
            return "ratio_\(ratio)"
        case .atleast(let value):
            return "atleast_\(value)"
        }
    }

    let kind: Kind
    let title: String
    var subtitle: String? = nil
    let accentHex: String
}

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
        .throttledHover(interval: 0.05) { hovering in
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
        .throttledHover(interval: 0.05) { hovering in
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
        .throttledHover(interval: 0.05) { hovering in
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
        .throttledHover(interval: 0.05) { hovering in
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
        .throttledHover(interval: 0.05) { hovering in
            isHovered = hovering
        }
    }
}
private enum ExploreHotTag: String, CaseIterable, Identifiable {
    case ultraHD
    case ultrawide
    case ratio21x9
    case ratio32x9
    case ratio16x9
    case portrait  // 竖图（高>宽）
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

    /// 映射到 Wallhaven API 参数
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
private extension Wallpaper {
    func matchesAnyTag(_ values: [String]) -> Bool {
        let normalizedValues = values.map { $0.lowercased() }
        return tags?.contains(where: { tag in
            let candidates = [tag.name, tag.alias ?? ""].map { $0.lowercased() }
            return candidates.contains(where: { candidate in
                normalizedValues.contains(where: { candidate.contains($0) })
            })
        }) ?? false
    }
}
// MARK: - SortingOption 扩展
extension SortingOption: CaseIterable {
    static var allCases: [SortingOption] {
        [.toplist, .dateAdded, .favorites, .views, .random, .relevance]
    }
}
private func sortingOptionDisplayName(_ option: SortingOption) -> String {
    switch option {
    case .dateAdded:
        return t("sort.latest")
    case .views:
        return t("sort.views")
    case .favorites:
        return t("sort.likes")
    case .toplist:
        return t("sort.toplist")
    case .random:
        return t("sort.random")
    case .relevance:
        return t("sort.relevance")
    }
}
// MARK: - resetAllFilters
extension WallpaperExploreContentView {
    private func resetAllFilters() {
        // 重置搜索
        searchText = ""
        viewModel.searchQuery = ""
        // 重置分类
        selectedCategory = .all
        // 重置热门标签
        selectedHotTag = nil
        // 重置纯度
        viewModel.puritySFW = true
        viewModel.puritySketchy = false
        viewModel.purityNSFW = false
        // 重置排序
        viewModel.sortingOption = .toplist
        viewModel.orderDescending = true
        // 重置颜色
        viewModel.selectedColors = []
        // 重置分辨率
        viewModel.selectedResolutions = []
        // 重置比例
        viewModel.selectedRatios = []
        // 重置最小分辨率
        viewModel.atleastResolution = nil
        // 触发搜索
        Task {
            await viewModel.search()
        }
    }
}

// MARK: - Scroll offset (shared with HomeContentView, WallpaperDetailSheet)
struct ScrollOffsetPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

