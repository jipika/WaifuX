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
    @State private var isExploreFastScrolling = false
    @State private var lastExploreScrollOffset: CGFloat = 0
    @State private var selectedSort: AnimeSortOption = .newest
    @State private var sortAscending = false

    // 详情页导航
    @State private var selectedAnime: AnimeSearchResult?
    @State private var showDetail = false

    var body: some View {
        GeometryReader { geometry in
            let gridContentWidth = max(0, geometry.size.width - 56)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    heroSection
                    sourceAndCategorySection
                    animeSection(gridContentWidth: gridContentWidth)
                }
                .padding(.horizontal, 28)
                .padding(.top, 108)
                .padding(.bottom, 48)
                .frame(width: geometry.size.width, alignment: .leading)
                .environment(\.explorePageAtmosphereTint, exploreAtmosphere.tint)
                .environment(\.isHighSpeedScrolling, isExploreFastScrolling)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: ScrollOffsetPreferenceKey.self,
                            value: proxy.frame(in: .named("animeExploreScroll")).minY
                        )
                    }
                )
            }
            .coordinateSpace(name: "animeExploreScroll")
            .onPreferenceChange(ScrollOffsetPreferenceKey.self) { offset in
                let delta = offset - lastExploreScrollOffset
                let speed = abs(delta) * 60

                let newFastScrolling = speed > 1200
                if newFastScrolling != isExploreFastScrolling {
                    isExploreFastScrolling = newFastScrolling

                    if newFastScrolling {
                        ImageLoader.shared.cancelAllLoads()
                    }
                }

                lastExploreScrollOffset = offset
            }
            .scrollClipDisabled()
            .background(
                ExploreDynamicAtmosphereBackground(
                    tint: exploreAtmosphere.tint,
                    referenceImage: exploreAtmosphere.referenceImage,
                    lightweightBackdrop: isExploreFastScrolling
                )
            )
            .overlay {
                if showDetail, let anime = selectedAnime {
                    AnimeDetailView(
                        anime: anime,
                        viewModel: viewModel,
                        isPresented: $showDetail
                    )
                    .transition(.move(edge: .trailing))
                }
            }
        }
        .task {
            await viewModel.loadInitialData()
            syncExploreAtmosphere()
        }
        .onChange(of: searchText) { _, newValue in
            viewModel.searchText = newValue
        }
        .onChange(of: viewModel.animeItems.first?.id) { _, _ in
            syncExploreAtmosphere()
        }
    }

    // MARK: - Hero Section

    private var heroSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "play.tv")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.56))

                    Text("ANIME")
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

                Text("探索动漫")
                    .font(.system(size: 32, weight: .bold, design: .serif))
                    .tracking(-0.5)
                    .foregroundStyle(.white.opacity(0.98))
                    .lineLimit(1)

                if !viewModel.availableRules.isEmpty {
                    Text("\(viewModel.animeItems.count) 部动漫 · 已加载 \(viewModel.availableRules.count) 个动漫源")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
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
                            Task {
                                await viewModel.search()
                            }
                        }

                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                            selectedHotTag = nil
                            Task {
                                await viewModel.fetchPopular()
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
            .frame(maxWidth: 520)

            // 热门标签
            HStack(alignment: .center, spacing: 10) {
                Text("热门:")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))

                ForEach(AnimeHotTag.allCases) { tag in
                    AnimeHotTagChip(tag: tag, isSelected: selectedHotTag == tag) {
                        withAnimation(AppFluidMotion.interactiveSpring) {
                            selectedHotTag = selectedHotTag == tag ? nil : tag
                            if selectedHotTag != nil {
                                searchText = tag.displayName
                                Task {
                                    await viewModel.search()
                                }
                            } else {
                                searchText = ""
                                Task {
                                    await viewModel.fetchPopular()
                                }
                            }
                        }
                    }
                }

                // 源选择器（放在热门标签后，与壁纸页比例一致）
                if !viewModel.availableRules.isEmpty {
                    Divider()
                        .background(Color.white.opacity(0.2))
                        .frame(height: 20)

                    AnimeSourcePicker(
                        selectedRule: $viewModel.selectedRule,
                        rules: viewModel.availableRules
                    ) {
                        Task {
                            await viewModel.search()
                        }
                    }
                }
            }
        }
        .frame(maxWidth: 700, alignment: .leading)
    }

    // MARK: - 源和分类区域

    private var sourceAndCategorySection: some View {
        FlowLayout(spacing: 12) {
            ForEach(AnimeCategory.allCases) { category in
                AnimeCategoryChip(
                    category: category,
                    isSelected: selectedCategory == category
                ) {
                    withAnimation(AppFluidMotion.interactiveSpring) {
                        selectedCategory = category
                        selectedHotTag = nil
                        searchText = ""
                    }

                    Task {
                        await viewModel.fetchPopular()
                    }
                }
            }
        }
    }

    // MARK: - 动漫网格区域

    private func animeSection(gridContentWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .center) {
                Text("\(viewModel.animeItems.count) 部动漫")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.64))

                Spacer()

                HStack(spacing: 12) {
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
            }

            if viewModel.isLoading && viewModel.animeItems.isEmpty {
                // 骨架屏加载状态
                AnimeGridSkeleton(contentWidth: gridContentWidth)
                    .padding(.top, 20)
                    .transition(.opacity.animation(.easeInOut(duration: 0.3)))
            } else if viewModel.animeItems.isEmpty {
                // 空状态/错误状态
                emptyState
                    .transition(.opacity.animation(.easeInOut(duration: 0.3)))
            } else {
                LazyVGrid(
                    columns: calculateGridColumns(width: gridContentWidth),
                    spacing: 20
                ) {
                    ForEach(viewModel.animeItems) { anime in
                        AnimePortraitCard(anime: anime) {
                            selectedAnime = anime
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                showDetail = true
                            }
                        }
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
        let minItemWidth: CGFloat = 160
        let spacing: CGFloat = 20

        let availableWidth = width + spacing
        let columnCount = max(2, Int(availableWidth / (minItemWidth + spacing)))

        return Array(repeating: GridItem(.flexible(), spacing: spacing), count: columnCount)
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
        .onHover { hovering in
            withAnimation(AppFluidMotion.hoverEase) {
                isHovered = hovering
            }
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
        .onHover { hovering in
            withAnimation(AppFluidMotion.hoverEase) {
                isHovered = hovering
            }
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
        let minItemWidth: CGFloat = 160
        let spacing: CGFloat = 20
        let availableWidth = contentWidth + spacing
        let columnCount = max(2, Int(availableWidth / (minItemWidth + spacing)))
        return Array(repeating: GridItem(.flexible(), spacing: spacing), count: columnCount)
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 20) {
            ForEach(0..<8, id: \.self) { _ in
                AnimePortraitCardSkeleton()
            }
        }
    }
}

// MARK: - 动漫卡片骨架屏

private struct AnimePortraitCardSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 竖版图片区域骨架 - 2:3比例
            LinearGradient(
                colors: [Color(hex: "1C2431"), Color(hex: "233B5A"), Color(hex: "14181F")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .frame(height: 240) // 竖版高度
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: 14,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 14,
                    style: .continuous
                )
            )
            .shimmer()

            // 底部信息栏骨架
            HStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 80, height: 12)

                Spacer()

                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 40, height: 12)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color.black.opacity(0.46))
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }
}
