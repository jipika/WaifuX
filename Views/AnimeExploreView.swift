import SwiftUI
import AppKit

// MARK: - AnimeExploreView - 动漫探索页
// 样式1:1复刻 MediaExploreContentView

struct AnimeExploreView: View {
    @StateObject private var viewModel = AnimeViewModel()
    @StateObject private var exploreAtmosphere = ExploreAtmosphereController(wallpaperMode: false)

    @State private var selectedCategory: AnimeCategory = .all
    @State private var selectedHotTag: AnimeHotTag?
    @State private var searchText = ""
    @State private var selectedSort: AnimeSortOption = .newest
    @State private var sortAscending = false

    // 详情页导航 - 通过 Binding 暴露给父视图
    @Binding var selectedAnime: AnimeSearchResult?

    // 搜索防抖
    @State private var searchTask: Task<Void, Never>?
    // 防止标签点击时触发搜索框的自动刷新
    @State private var isTagSearchActive = false

    var body: some View {
        GeometryReader { geometry in
            let gridContentWidth = max(0, geometry.size.width - 56)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    heroSection
                    animeSection(gridContentWidth: gridContentWidth)
                }
                .padding(.horizontal, 28)
                .padding(.top, 108)
                .padding(.bottom, 48)
                .frame(width: geometry.size.width, alignment: .leading)
                .environment(\.explorePageAtmosphereTint, exploreAtmosphere.tint)
            }
            .scrollClipDisabled()
            .background(
                ExploreDynamicAtmosphereBackground(
                    tint: exploreAtmosphere.tint,
                    referenceImage: exploreAtmosphere.referenceImage
                )
            )

        }
        .task {
            await viewModel.loadInitialData()
            syncExploreAtmosphere()
        }
        .onChange(of: searchText) { _, newValue in
            viewModel.searchText = newValue
            
            // 如果正在进行标签搜索，忽略搜索框的变化
            if isTagSearchActive {
                isTagSearchActive = false
                return
            }
            
            // 防抖搜索
            searchTask?.cancel()
            
            // 如果清空搜索框，立即刷新
            if newValue.isEmpty {
                Task {
                    await viewModel.fetchPopular()
                }
                return
            }
            
            searchTask = Task {
                // 延迟 300ms 再搜索，避免频繁输入时触发过多请求
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                await viewModel.search()
            }
        }
        .onChange(of: viewModel.animeItems.first?.id) { _, _ in
            syncExploreAtmosphere()
        }
    }

    // MARK: - Hero Section

    private var heroSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("探索动漫")
                    .font(.system(size: 32, weight: .bold, design: .serif))
                    .tracking(-0.5)
                    .foregroundStyle(.white.opacity(0.98))
                    .lineLimit(1)

                Text("发现热门动漫，追踪最新剧集")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }

            HStack(spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.52))

                    TextField("搜索动漫...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))
                        .onSubmit {
                            // 取消防抖任务，立即执行搜索
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

                // 重置按钮
                Button {
                    resetAllFilters()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .frame(width: 46, height: 46)
                        .liquidGlassSurface(
                            .prominent,
                            tint: exploreAtmosphere.tint.secondary.opacity(0.12),
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: 460, alignment: .leading)

            // 分类选择器
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

            // 热门标签（横向滚动布局，与 WallpaperExploreContentView 一致）
            VStack(alignment: .leading, spacing: 12) {
                Text("热门标签")
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
                                    // 标记正在进行标签搜索，防止触发搜索框的自动刷新
                                    isTagSearchActive = true
                                    // 取消搜索框的防抖任务并清空搜索框
                                    searchTask?.cancel()
                                    searchText = ""
                                    viewModel.searchText = ""
                                    // 标签搜索不填充搜索栏，使用中文标签名
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

    // MARK: - 动漫网格区域

    private func animeSection(gridContentWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .center) {
                HStack(spacing: 8) {
                    Text("\(viewModel.animeItems.count) 部动漫")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.66))

                    if viewModel.isLoadingMore {
                        ProgressView()
                            .scaleEffect(0.6)
                            .tint(.white.opacity(0.6))
                    }
                }

                Spacer()

                // 排序选项菜单
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

            if viewModel.isLoading && viewModel.animeItems.isEmpty {
                // 骨架屏加载状态
                AnimeGridSkeleton(contentWidth: gridContentWidth)
                    .padding(.top, 20)
                    .transition(.opacity.animation(.easeInOut(duration: 0.25)))
            } else if viewModel.animeItems.isEmpty {
                // 空状态/错误状态
                emptyState
                    .transition(.opacity.animation(.easeInOut(duration: 0.25)))
            } else {
                LazyVGrid(
                    columns: calculateGridColumns(width: gridContentWidth),
                    spacing: 24
                ) {
                    ForEach(viewModel.animeItems) { anime in
                        AnimePortraitCard(anime: anime) {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                selectedAnime = anime
                            }
                        }
                    }

                    // 加载更多指示器（同时作为触发器）
                    if viewModel.hasMorePages && !viewModel.isLoading {
                        PaginationLoadingView()
                            .frame(height: 60)
                            .padding(.top, 20)
                            .onAppear {
                                guard !viewModel.isLoadingMore else { return }
                                Task {
                                    await viewModel.loadMore()
                                }
                            }
                    }
                }
                .id("grid-\(selectedCategory.rawValue)-\(selectedHotTag?.rawValue ?? "all")")

                // 加载更多指示器（非网格内）
                if viewModel.isLoadingMore {
                    PaginationLoadingView()
                        .frame(height: 60)
                        .padding(.top, 20)
                }

                // 没有更多数据提示
                if !viewModel.hasMorePages && viewModel.animeItems.count > 20 {
                    Text("已经到底啦")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                        .frame(height: 50)
                        .padding(.top, 10)
                }
            }
        }
    }

    private var emptyState: some View {
        Group {
            if let errorMessage = viewModel.errorMessage {
                // 网络错误状态
                ErrorStateView(
                    type: .network,
                    message: errorMessage,
                    retryAction: {
                        Task { await viewModel.loadInitialData() }
                    }
                )
            } else {
                // 空数据状态
                ErrorStateView(
                    type: .empty,
                    title: "暂无动漫数据",
                    message: "尝试切换不同的动漫源或检查网络连接",
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

    private func calculateGridColumns(width: CGFloat) -> [GridItem] {
        let spacing: CGFloat = 24
        // 竖图 2:3 比例，支持 2-6 列
        let tiers: [(cols: Int, minCell: CGFloat)] = [
            (6, 140),  // 6列需要每列至少 140pt
            (5, 145),  // 5列需要每列至少 145pt
            (4, 150),  // 4列需要每列至少 150pt
            (3, 160),  // 3列需要每列至少 160pt
            (2, 180)   // 2列需要每列至少 180pt
        ]

        for tier in tiers {
            let cellWidth = (width - CGFloat(tier.cols - 1) * spacing) / CGFloat(tier.cols)
            if cellWidth >= tier.minCell {
                return Array(repeating: GridItem(.flexible(), spacing: spacing, alignment: .top), count: tier.cols)
            }
        }
        return Array(repeating: GridItem(.flexible(), spacing: spacing, alignment: .top), count: 2)
    }

    private func syncExploreAtmosphere() {
        if let firstAnime = viewModel.animeItems.first,
           let coverURL = firstAnime.coverURL {
            exploreAtmosphere.updateFirstAnime(coverURL: coverURL)
        }
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

// MARK: - 热门标签 Chip（与 MediaHotTagChip 样式一致）

private struct AnimeHotTagChip: View {
    let tag: AnimeHotTag
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.explorePageAtmosphereTint) private var exploreTint
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(tag.displayName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(isSelected ? 0.95 : 0.78))
                .padding(.horizontal, 14)
                .frame(height: 32)
                .liquidGlassSurface(
                    isSelected ? .prominent : .regular,
                    tint: isSelected ? exploreTint.primary.opacity(0.14) : exploreTint.primary.opacity(0.06),
                    in: Capsule(style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.01 : 1.0)
        .animation(AppFluidMotion.hoverEase, value: isHovered)
        .throttledHover(interval: 0.05) { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - 分类 Chip（与 MediaCategoryChip 样式一致，带彩色图标）

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
            .liquidGlassSurface(
                isSelected ? .max : .regular,
                tint: category.accentColors.first.map { Color(hex: $0).opacity(isSelected ? 0.18 : 0.08) },
                in: Capsule(style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered && !isSelected ? 1.01 : 1.0)
        .animation(AppFluidMotion.hoverEase, value: isHovered)
        .throttledHover(interval: 0.05) { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - 排序选项

private enum AnimeSortOption: String, CaseIterable, Identifiable {
    case newest
    case title
    case popular

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newest: return "最新"
        case .title: return "名称"
        case .popular: return "热门"
        }
    }

    var menuTitle: String {
        switch self {
        case .newest: return "按最新排序"
        case .title: return "按名称排序"
        case .popular: return "按热门排序"
        }
    }
}

// MARK: - 动漫网格骨架屏（与 MediaGridSkeleton 一致）

private struct AnimeGridSkeleton: View {
    var contentWidth: CGFloat = 800

    private var columns: [GridItem] {
        let spacing: CGFloat = 24
        let tiers: [(cols: Int, minCell: CGFloat)] = [
            (6, 140), (5, 145), (4, 150), (3, 160), (2, 180)
        ]

        for tier in tiers {
            let cellWidth = (contentWidth - CGFloat(tier.cols - 1) * spacing) / CGFloat(tier.cols)
            if cellWidth >= tier.minCell {
                return Array(repeating: GridItem(.flexible(), spacing: spacing, alignment: .top), count: tier.cols)
            }
        }
        return Array(repeating: GridItem(.flexible(), spacing: spacing, alignment: .top), count: 2)
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 24) {
            ForEach(0..<6, id: \.self) { _ in
                AnimePortraitCardSkeleton()
            }
        }
    }
}

// MARK: - 动漫卡片骨架屏

private struct AnimePortraitCardSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 竖版图片区域骨架 - 与实际卡片保持相同的尺寸
            LinearGradient(
                colors: [Color(hex: "1C2431"), Color(hex: "233B5A"), Color(hex: "14181F")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .frame(height: 300)
            .clipped()

            // 信息栏骨架 - 深色半透明背景
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
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shimmer()
    }
}
