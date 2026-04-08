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
    @State private var sortAscending = false  // false = 降序, true = 升序
    @State private var searchText = ""
    @State private var displayedMediaItems: [MediaItem] = []
    @State private var isLoadingMore = false
    @State private var loadMoreSentinelID: String? = nil

    // Task 管理
    @State private var searchTask: Task<Void, Never>?
    @State private var loadMoreTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geometry in
            let gridContentWidth = max(0, geometry.size.width - 56)
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 24) {
                    heroSection
                    categorySection
                    mediaSection(gridContentWidth: gridContentWidth)
                }
                .padding(.horizontal, 28)
                .padding(.top, 80)
                .padding(.bottom, 48)
                .frame(width: geometry.size.width, alignment: .leading)
                .environment(\.explorePageAtmosphereTint, exploreAtmosphere.tint)
            }
            // 命名坐标空间，供视差效果使用
            .coordinateSpace(name: "exploreScroll")
            // iOS 风格弹性滚动：惯性减速 + 弹性边界
            .iosSmoothScroll()
            .background(
                ExploreDynamicAtmosphereBackground(
                    tint: exploreAtmosphere.tint,
                    referenceImage: exploreAtmosphere.referenceImage
                )
            )
        }
        .task {
            await viewModel.initialLoadIfNeeded()
            if searchText.isEmpty {
                searchText = viewModel.currentQuery
            }
            rebuildVisibleMediaItems()
            syncExploreMediaAtmosphere()
        }
        // 合并 onChange 监听，减少重复调用
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
        .onChange(of: viewModel.items) { _, _ in
            // 当媒体数据变化时，重新构建显示的列表
            rebuildVisibleMediaItems()
        }
        .onChange(of: displayedMediaItems.first?.id) { _, _ in
            syncExploreMediaAtmosphere()
        }
        .onDisappear {
            // 视图消失时取消所有任务
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

                // 重置按钮 - 深色液态玻璃风格
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
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .center) {
                Text("\(formattedMediaCount) \(t("media.count")) · \(t("media.loaded")) \(formattedLoadedCount)")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.64))

                Spacer()

                HStack(spacing: 12) {
                    // 排序选项菜单
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
                // 骨架屏加载状态
                MediaGridSkeleton(contentWidth: gridContentWidth)
                    .padding(.top, 20)
                    .transition(.opacity.animation(.easeInOut(duration: 0.3)))
            } else if displayedMediaItems.isEmpty {
                emptyState
                    .transition(.opacity.animation(.easeInOut(duration: 0.3)))
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
                    ForEach(displayedMediaItems) { item in
                        // 预计算索引（用于入场动画交错延迟 + 分页加载定位）
                        let cardIndex = displayedMediaItems.firstIndex(where: { $0.id == item.id }) ?? 0

                        SimpleMediaCard(
                            item: item,
                            cardWidth: cardWidth,
                            cardHeight: cardHeight,
                            isFavorite: viewModel.isFavorite(item),
                            onTap: { selectedMedia = item }
                        )
                        // iOS 风格入场动画
                        .iosFadeInOnAppear(index: cardIndex)
                        .onAppear {
                            guard cardIndex >= displayedMediaItems.count - 6 else { return }
                            guard viewModel.hasMorePages,
                                  !viewModel.isLoading,
                                  !isLoadingMore else { return }
                            isLoadingMore = true
                            Task {
                                await viewModel.loadMore()
                                await MainActor.run {
                                    appendNewMediaItems()
                                    isLoadingMore = false
                                }
                            }
                        }
                    }

                    // 分页加载指示器（简化版，不遮挡内容）
                    if isLoadingMore || (viewModel.isLoading && !displayedMediaItems.isEmpty) {
                        HStack(spacing: 8) {
                            CustomProgressView(tint: LiquidGlassColors.primaryPink)
                                .scaleEffect(0.8)
                            Text(t("loadMore"))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                        .gridCellColumns(columnCount)
                    } else if !viewModel.hasMorePages && !viewModel.isLoading {
                        // 全部加载完毕提示
                        HStack(spacing: 6) {
                            Rectangle()
                                .fill(Color.white.opacity(0.15))
                                .frame(width: 32, height: 1)
                            Text("— \(t("noMore")) —")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.25))
                            Rectangle()
                                .fill(Color.white.opacity(0.15))
                                .frame(width: 32, height: 1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                        .gridCellColumns(columnCount)
                    }
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
                    retryAction: {
                        Task { await viewModel.loadHomeFeed() }
                    }
                )
            } else {
                // 空数据状态
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
        displayedMediaItems.append(contentsOf: newItems)
    }
    private func submitSearch(with query: String) {
        selectedCategory = .all
        selectedHotTag = nil
        Task {
            await viewModel.search(query: query)
        }
    }

    // MARK: - 合并的过滤处理

    /// 判断该 HotTag 是否对应网站上的真实标签页面（可发起服务端请求）
    private static let hotTagServerSlugs: [MediaExploreHotTag: String] = [
        .anime: "anime",
        .rain: "rain",
        .cyberpunk: "cyberpunk",
        .nature: "nature",
        .game: "games",       // 注意：网站 slug 是 games 不是 game
        .dark: "dark",
    ]

    private func isServerSideHotTag(_ tag: MediaExploreHotTag) -> Bool {
        Self.hotTagServerSlugs[tag] != nil
    }

    private func handleFilterChange() {
        // 如果选中的是服务端请求型 HotTag，发起真实 API 请求
        if let hotTag = selectedHotTag, isServerSideHotTag(hotTag),
           let slug = Self.hotTagServerSlugs[hotTag] {
            Task {
                await viewModel.loadTagFeed(slug: slug, title: hotTag.title)
            }
            return
        }

        // 否则执行客户端过滤（4K/HD 等）
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
            // newest 模式保留服务端返回顺序，确保分页加载的数据稳定追加在末尾。
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

        let sentinelIndex = max(0, displayedMediaItems.count - 10)
        loadMoreSentinelID = displayedMediaItems.indices.contains(sentinelIndex) ? displayedMediaItems[sentinelIndex].id : nil
        syncExploreMediaAtmosphere()
    }
}

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

// MARK: - 媒体探索网格卡片（简化版，优化滚动性能）
private struct SimpleMediaCard: View {
    let item: MediaItem
    let cardWidth: CGFloat
    let cardHeight: CGFloat
    let isFavorite: Bool
    let onTap: () -> Void

    @State private var isHovered = false

    // 静态形状缓存
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
                // 图片区域 - 简化结构
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
                    // 简化元数据行
                    simplifiedMetadataRow
                        .padding(10)
                }
                .overlay(alignment: .center) {
                    // 视频播放图标
                    if item.previewVideoURL != nil {
                        Image(systemName: "play.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(Color.black.opacity(0.45))
                            .clipShape(Circle())
                    }
                }

                // 底部信息 - 简化
                HStack(spacing: 8) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                    
                    Spacer()
                    
                    // 简化的收藏图标
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
    
    // 简化的元数据行
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

private struct MediaPreviewArtwork: View {
    let item: MediaItem

    var body: some View {
        ZStack {
            OptimizedAsyncImage(url: item.posterURLValue ?? item.thumbnailURLValue, priority: .medium) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                fallbackArtwork
            }

            LinearGradient(
                colors: [
                    Color.clear,
                    Color.black.opacity(0.16),
                    Color.black.opacity(0.34)
                ],
                startPoint: .center,
                endPoint: .bottom
            )

            VStack {
                Spacer()

                HStack {
                    HStack(spacing: 6) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.system(size: 9, weight: .bold))
                        Text("LIVE")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                    }
                    .foregroundStyle(.white.opacity(0.72))
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.black.opacity(0.24))
                    )

                    Spacer()

                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(0.16))
                            .frame(width: 40, height: 40)

                        Circle()
                            .stroke(Color.white.opacity(0.14), lineWidth: 1)
                            .frame(width: 40, height: 40)

                        Image(systemName: "play.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white.opacity(0.92))
                            .offset(x: 1)
                    }
                }
                .padding(16)
            }
        }
    }

    private var fallbackArtwork: some View {
        LinearGradient(
            colors: [
                Color(hex: "1C2431"),
                Color(hex: "233B5A"),
                Color(hex: "14181F")
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay {
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(.white.opacity(0.18))
        }
    }
}


// MARK: - MediaExplore 专用枚举
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

// MARK: - MediaItem 扩展（用于 MediaExplore）
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
            // formatText 可能是 "3840x2160" 或 "4K"，检查两种形式
            let normalized = formatText.uppercased()
                .replacingOccurrences(of: " ", with: "")
            if normalized.contains("3840X2160") || normalized.contains("4K") { return true }
            // 也检查 exactResolution（如 "3840 × 2160" 带空格的格式）
            if let er = exactResolution, er.uppercased().contains("3840") { return true }
            return false
        case .hd:
            // 匹配 HD / 1920x1080 / 1280x720 等
            let normalized = formatText.uppercased()
                .replacingOccurrences(of: " ", with: "")
            if normalized.contains("HD") || normalized.contains("1920X1080")
               || normalized.contains("1280X720") { return true }
            if let er = exactResolution,
               er.uppercased().contains("1920") || er.uppercased().contains("1280") { return true }
            return false
        default:
            // 其他标签由 handleFilterChange 统一走服务端请求，客户端不匹配
            return false
        }
    }
}

// MARK: - resetAllFilters
extension MediaExploreContentView {
    private func resetAllFilters() {
        // 重置搜索
        searchText = ""
        selectedHotTag = nil

        // 重置分类
        selectedCategory = .all

        // 重置排序
        selectedSort = .newest
        sortAscending = false

        // 触发重新加载
        Task {
            await viewModel.loadHomeFeed()
        }
    }
}
