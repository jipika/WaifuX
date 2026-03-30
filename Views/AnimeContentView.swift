import SwiftUI

struct AnimeContentView: View {
    @StateObject private var viewModel = AnimeViewModel()
    @Binding var selectedAnime: UniversalContentItem?

    @State private var searchText = ""
    @State private var selectedCategory: String = "all"

    var body: some View {
        ZStack {
            // 背景
            ExploreDynamicAtmosphereBackground(
                tint: ExploreAtmosphereTint(
                    primary: Color(hex: "FF6B9D"),
                    secondary: Color(hex: "C44569"),
                    tertiary: Color(hex: "786FA6"),
                    baseTop: Color(hex: "1A1A2E"),
                    baseBottom: Color(hex: "16213E")
                ),
                referenceImage: nil,
                lightweightBackdrop: false
            )
            .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {
                    // Hero 区域
                    heroSection

                    // 搜索栏
                    searchBar

                    // 分类筛选
                    categorySection

                    // 动漫列表
                    animeGrid
                }
                .padding(.horizontal, 26)
                .padding(.top, 70)
                .padding(.bottom, 40)
            }
        }
        .task {
            await viewModel.loadInitialData()
        }
    }

    // MARK: - Hero Section
    private var heroSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "play.tv")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))

                Text("ANIME")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.72))
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .background(
                        Capsule()
                            .fill(Color(hex: "FF6B9D").opacity(0.2))
                    )
            }

            Text(t("content.anime"))
                .font(.system(size: 42, weight: .bold, design: .serif))
                .foregroundStyle(.white.opacity(0.96))
                .tracking(-0.5)

            Text("发现精彩动漫，追番不再错过")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Search Bar
    private var searchBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.52))

            TextField(t("search.placeholder"), text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: - Category Section
    private var categorySection: some View {
        FlowLayout(spacing: 10) {
            CategoryChip(title: "全部", isSelected: selectedCategory == "all") {
                selectedCategory = "all"
            }
            CategoryChip(title: "热门", isSelected: selectedCategory == "popular") {
                selectedCategory = "popular"
            }
            CategoryChip(title: "新番", isSelected: selectedCategory == "new") {
                selectedCategory = "new"
            }
            CategoryChip(title: "连载", isSelected: selectedCategory == "ongoing") {
                selectedCategory = "ongoing"
            }
            CategoryChip(title: "完结", isSelected: selectedCategory == "completed") {
                selectedCategory = "completed"
            }
        }
    }

    // MARK: - Anime Grid
    private var animeGrid: some View {
        LazyVGrid(columns: [
            GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 16)
        ], spacing: 20) {
            ForEach(viewModel.animeItems) { anime in
                AnimeCard(anime: anime)
                    .onTapGesture {
                        selectedAnime = anime
                    }
            }
        }
    }
}

// MARK: - Anime Card
struct AnimeCard: View {
    let anime: UniversalContentItem
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 封面图
            ZStack(alignment: .bottomTrailing) {
                AsyncImage(url: URL(string: anime.thumbnailURL)) { phase in
                    switch phase {
                    case .empty:
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.white.opacity(0.05))
                            .overlay(
                                ProgressView()
                                    .scaleEffect(0.8)
                            )
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    case .failure:
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.white.opacity(0.05))
                            .overlay(
                                Image(systemName: "photo")
                                    .font(.system(size: 24))
                                    .foregroundStyle(.white.opacity(0.3))
                            )
                    @unknown default:
                        EmptyView()
                    }
                }
                .frame(height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                // 集数标签
                if case .anime(let metadata) = anime.metadata, let total = metadata.totalEpisodes {
                    Text("\(total)集")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(Color.black.opacity(0.6))
                        )
                        .padding(8)
                }

                // 播放按钮（悬停显示）
                if isHovered {
                    Circle()
                        .fill(Color.white.opacity(0.9))
                        .frame(width: 44, height: 44)
                        .overlay(
                            Image(systemName: "play.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.black)
                        )
                        .shadow(color: .black.opacity(0.3), radius: 10)
                }
            }
            .frame(height: 220)

            // 标题
            Text(anime.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(2)
                .frame(height: 40, alignment: .top)

            // 标签
            if !anime.tags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(anime.tags.prefix(2), id: \.self) { tag in
                        Text(tag)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(Color.white.opacity(0.08))
                            )
                    }
                }
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Category Chip
struct CategoryChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? .white : .white.opacity(0.7))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(isSelected ? Color(hex: "FF6B9D").opacity(0.3) : Color.white.opacity(0.08))
                )
                .overlay(
                    Capsule()
                        .stroke(isSelected ? Color(hex: "FF6B9D").opacity(0.5) : Color.white.opacity(0.1), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Anime ViewModel
@MainActor
class AnimeViewModel: ObservableObject {
    @Published var animeItems: [UniversalContentItem] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    func loadInitialData() async {
        isLoading = true
        defer { isLoading = false }

        do {
            // 先加载所有规则（从本地文件）
            _ = await RuleLoader.shared.loadAllRules()

            // 获取动漫类型的规则
            let rules = await RuleLoader.shared.rules(for: .anime)

            guard let firstRule = rules.first else {
                // 如果没有规则，使用示例数据
                print("[AnimeViewModel] No rules found, loading sample data")
                loadSampleData()
                return
            }

            print("[AnimeViewModel] Found rule: \(firstRule.name), fetching content...")

            // 尝试获取内容
            let items = try await ContentService.shared.fetchList(
                from: firstRule.id,
                route: .home,
                page: 1
            )

            if items.isEmpty {
                print("[AnimeViewModel] No items fetched, using sample data")
                loadSampleData()
            } else {
                print("[AnimeViewModel] Loaded \(items.count) items")
                animeItems = items
            }
        } catch {
            print("[AnimeViewModel] Failed to load: \(error)")
            errorMessage = error.localizedDescription
            loadSampleData()
        }
    }

    private func loadSampleData() {
        // 示例数据，用于演示 UI
        animeItems = [
            UniversalContentItem(
                id: "sample_1",
                contentType: .anime,
                title: "鬼灭之刃",
                thumbnailURL: "https://via.placeholder.com/300x400/FF6B9D/FFFFFF?text=Anime+1",
                coverURL: nil,
                description: "大正时代的日本",
                tags: ["动作", "奇幻"],
                sourceType: "gimy",
                sourceURL: "",
                sourceName: "Gimy",
                metadata: .anime(.init(
                    episodes: [],
                    currentEpisode: nil,
                    totalEpisodes: 26,
                    status: "completed",
                    aired: "2019",
                    rating: "9.5"
                )),
                createdAt: nil,
                updatedAt: nil
            ),
            UniversalContentItem(
                id: "sample_2",
                contentType: .anime,
                title: "进击的巨人",
                thumbnailURL: "https://via.placeholder.com/300x400/C44569/FFFFFF?text=Anime+2",
                coverURL: nil,
                description: "人类与巨人的战争",
                tags: ["动作", "剧情"],
                sourceType: "gimy",
                sourceURL: "",
                sourceName: "Gimy",
                metadata: .anime(.init(
                    episodes: [],
                    currentEpisode: nil,
                    totalEpisodes: 87,
                    status: "completed",
                    aired: "2013",
                    rating: "9.8"
                )),
                createdAt: nil,
                updatedAt: nil
            ),
            UniversalContentItem(
                id: "sample_3",
                contentType: .anime,
                title: "咒术回战",
                thumbnailURL: "https://via.placeholder.com/300x400/786FA6/FFFFFF?text=Anime+3",
                coverURL: nil,
                description: "咒术师与咒灵",
                tags: ["动作", "超自然"],
                sourceType: "gimy",
                sourceURL: "",
                sourceName: "Gimy",
                metadata: .anime(.init(
                    episodes: [],
                    currentEpisode: nil,
                    totalEpisodes: 24,
                    status: "ongoing",
                    aired: "2020",
                    rating: "9.2"
                )),
                createdAt: nil,
                updatedAt: nil
            )
        ]
    }
}
