import SwiftUI

// MARK: - 搜索视图 - Liquid Glass 风格
struct SearchView: View {
    @ObservedObject var viewModel: WallpaperViewModel
    @Binding var isPresented: Bool
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool
    @State private var selectedFilter: SearchFilter = .all

    enum SearchFilter: String, CaseIterable {
        case all
        case anime
        case nature
        case people
        case tech

        var color: Color {
            switch self {
            case .all: return LiquidGlassColors.tertiaryBlue
            case .anime: return LiquidGlassColors.primaryPink
            case .nature: return LiquidGlassColors.onlineGreen
            case .people: return LiquidGlassColors.warningOrange
            case .tech: return LiquidGlassColors.secondaryViolet
            }
        }

        var displayName: String {
            switch self {
            case .all: return t("filter.all")
            case .anime: return t("filter.anime")
            case .nature: return t("filter.nature")
            case .people: return t("filter.people")
            case .tech: return t("filter.tech")
            }
        }

        // 用于精确搜索的关键字
        var searchTag: String? {
            switch self {
            case .all: return nil
            case .anime: return "anime"
            case .nature: return "nature"
            case .people: return "people"
            case .tech: return "technology"
            }
        }
    }

    private let columns = [
        GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 16)
    ]

    var body: some View {
        VStack(spacing: 0) {
            // 顶部栏
            topBar

            // 搜索区域
            searchSection

            // 搜索结果
            resultSection
        }
        .background(
            ZStack {
                LiquidGlassAtmosphereBackground(
                    primary: LiquidGlassColors.tertiaryBlue,
                    secondary: LiquidGlassColors.secondaryViolet,
                    tertiary: LiquidGlassColors.primaryPink,
                    baseTop: LiquidGlassColors.midBackground,
                    baseBottom: LiquidGlassColors.deepBackground
                )

                // 颗粒材质覆盖层
                GrainTextureOverlay()
            }
        )
        .onAppear {
            isSearchFocused = true
        }
    }

    // MARK: - 顶部栏
    private var topBar: some View {
        HStack {
            // 返回按钮
            Button {
                isPresented = false
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(LiquidGlassColors.textPrimary)
                    .frame(width: 36, height: 36)
                    .liquidGlassSurface(.max, tint: LiquidGlassColors.tertiaryBlue.opacity(0.18), in: Circle())
            }
            .buttonStyle(.plain)

            Spacer()

            Text(t("search"))
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(LiquidGlassColors.textPrimary)

            Spacer()

            // 占位保持对称
            Color.clear.frame(width: 36, height: 36)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.clear)
                .liquidGlassSurface(.prominent, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        )
        .padding(.horizontal, 12)
        .padding(.top, 12)
    }

    // MARK: - 搜索区域
    private var searchSection: some View {
        VStack(spacing: 16) {
            // 搜索框
            HStack(spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(LiquidGlassColors.textSecondary)

                    TextField(t("searchWallpaper"), text: $searchText)
                        .font(.system(size: 15))
                        .foregroundStyle(LiquidGlassColors.textPrimary)
                        .focused($isSearchFocused)
                        .onSubmit {
                            performSearch()
                        }

                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(LiquidGlassColors.textTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .liquidGlassSurface(
                    .max,
                    tint: LiquidGlassColors.tertiaryBlue.opacity(0.14),
                    in: RoundedRectangle(cornerRadius: GlassStyle.CornerRadius.medium, style: .continuous)
                )

                // 搜索按钮
                Button {
                    performSearch()
                } label: {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .liquidGlassSurface(.max, tint: LiquidGlassColors.primaryPink.opacity(0.35), in: Circle())
                }
                .buttonStyle(.plain)
            }

            // 筛选标签
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(SearchFilter.allCases, id: \.self) { filter in
                        LiquidGlassPillButton(
                            title: filter.displayName,
                            icon: nil,
                            isSelected: selectedFilter == filter,
                            color: filter.color
                        ) {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                selectedFilter = filter
                            }
                            performSearch()
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    // MARK: - 结果区域
    private var resultSection: some View {
        ScrollView {
            if viewModel.isLoading && viewModel.wallpapers.isEmpty {
                LiquidGlassLoadingView(message: t("searching"))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 100)
            } else if viewModel.wallpapers.isEmpty {
                LiquidGlassEmptyState(message: t("no.results"))
                    .frame(maxWidth: .infinity, minHeight: 300)
            } else {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(viewModel.wallpapers) { wallpaper in
                        LiquidGlassWallpaperCard(wallpaper: wallpaper, rank: nil) {
                            isPresented = false
                        }
                    }
                }
                .padding(20)
            }
        }
        .background(LiquidGlassColors.deepBackground)
    }

    private func performSearch() {
        // 如果选择了特定分类且没有输入搜索词，使用tag搜索
        if searchText.isEmpty, let tag = selectedFilter.searchTag {
            viewModel.searchQuery = tag
        } else {
            viewModel.searchQuery = searchText
        }
        viewModel.selectedCategory = "111"  // 使用所有分类
        Task { await viewModel.search() }
    }
}
