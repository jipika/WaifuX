import SwiftUI

struct MyLibraryContentView: View {
    @StateObject private var viewModel = WallpaperViewModel()
    @StateObject private var mediaViewModel = MediaExploreViewModel()
    @StateObject private var downloadTaskViewModel = DownloadTaskViewModel()
    @StateObject private var animeFavoriteStore = AnimeFavoriteStore.shared

    // 分类筛选
    @State private var selectedContentType: ContentType = .wallpaper
    @Binding var selectedWallpaper: Wallpaper?
    @Binding var selectedMedia: MediaItem?
    @Binding var selectedAnime: AnimeSearchResult?
    @State private var animeFavorites: [AnimeSearchResult] = []

    // 编辑状态
    @State private var isEditing = false
    @State private var editingSection: EditingSection = .favorites
    @State private var selectedItems = Set<String>()

    enum EditingSection: String, CaseIterable {
        case favorites = "favorites"
        case downloads = "downloads"
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // 编辑模式背景遮罩（放在最底层，不阻挡卡片点击）
            if isEditing {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation {
                            isEditing = false
                            selectedItems.removeAll()
                        }
                    }
                    .allowsHitTesting(true)
            }

            LiquidGlassAtmosphereBackground(
                primary: LiquidGlassColors.primaryPink,
                secondary: LiquidGlassColors.secondaryViolet,
                tertiary: LiquidGlassColors.tertiaryBlue,
                baseTop: LiquidGlassColors.midBackground,
                baseBottom: LiquidGlassColors.deepBackground
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // 颗粒材质覆盖层
            GrainTextureOverlay()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    // Hero 区域
                    mediaHero

                    // 内容类型切换器
                    ContentTypePicker(selected: $selectedContentType)

                    // 根据类型显示不同内容（保留原有收藏/下载分区）
                    contentSections
                }
                .padding(.horizontal, 28)
                .padding(.top, 112)
                .padding(.bottom, 48)
                .frame(maxWidth: 1520, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollClipDisabled()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 注意：所有详情页在 ContentView 层级显示，确保能覆盖 TopNavigationBar
        .task {
            await viewModel.initialLoad()
            // mediaViewModel.favoriteItems 和 downloadedItems 是计算属性，自动从 MediaLibraryService 获取
            await loadAnimeFavorites()
            // 扫描本地文件（用户手动复制到目录的文件）
            await LocalWallpaperScanner.shared.forceRescan()
        }
        .onReceive(animeFavoriteStore.$favorites) { _ in
            Task {
                await loadAnimeFavorites()
            }
        }
    }

    // MARK: - 加载动漫收藏
    private func loadAnimeFavorites() async {
        let favorites = animeFavoriteStore.allFavorites
        animeFavorites = favorites.map { favorite in
            AnimeSearchResult(
                id: favorite.id,
                title: favorite.title,
                coverURL: favorite.coverURL,
                detailURL: "",
                sourceId: "bangumi",
                sourceName: "Bangumi",
                latestEpisode: nil,
                rating: nil,
                summary: nil,
                rank: nil,
                airDate: nil,
                airWeekday: nil,
                tags: favorite.tags.map { AnimeTag(name: $0, count: nil) },
                originalName: nil
            )
        }
    }

    // MARK: - Hero
    private var mediaHero: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(t("my.media.library"))
                        .font(.system(size: 42, weight: .bold, design: .serif))
                        .foregroundStyle(.white.opacity(0.96))

                    Text(subtitleForType)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }

                Spacer()

                SettingsStatusBadge(
                    title: "\(totalFavorites) \(t("items.favorites"))",
                    systemImage: "heart.fill",
                    color: LiquidGlassColors.primaryPink
                )
            }
        }
    }

    private var subtitleForType: String {
        switch selectedContentType {
        case .wallpaper: return t("library.wallpapers")
        case .video: return t("library.videos")
        case .anime: return t("library.anime")
        }
    }

    private var totalFavorites: Int {
        switch selectedContentType {
        case .wallpaper: return viewModel.favorites.count
        case .video: return mediaViewModel.favoriteItems.count
        case .anime: return animeFavorites.count
        }
    }

    // MARK: - Content Sections
    @ViewBuilder
    private var contentSections: some View {
        switch selectedContentType {
        case .wallpaper:
            wallpaperSections
        case .video:
            mediaSections
        case .anime:
            animeSections
        }
    }

    // MARK: - Wallpaper Sections (原有功能)
    private var wallpaperSections: some View {
        VStack(alignment: .leading, spacing: 32) {
            // 壁纸收藏
            VStack(alignment: .leading, spacing: 16) {
                sectionHeaderWithEdit(
                    title: t("wallpaper.favorites"),
                    systemImage: "heart.fill",
                    color: LiquidGlassColors.primaryPink,
                    countText: "\(viewModel.favorites.count) \(t("items"))",
                    section: .favorites
                )

                if viewModel.favorites.isEmpty {
                    emptyMediaSurface(
                        title: t("no.wallpaper.favorites"),
                        subtitle: t("no.wallpaper.favorites.hint"),
                        icon: "heart.slash",
                        accent: LiquidGlassColors.primaryPink
                    )
                } else {
                    batchDeleteToolbar(section: .favorites, count: viewModel.favorites.count)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 18) {
                            ForEach(viewModel.favorites) { wallpaper in
                                WallpaperEditCard(
                                    wallpaper: wallpaper,
                                    isEditing: isEditing,
                                    isSelected: selectedItems.contains(wallpaper.id)
                                ) {
                                    handleWallpaperTap(wallpaper)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            // 壁纸下载（包含下载记录和本地扫描的文件）
            VStack(alignment: .leading, spacing: 16) {
                sectionHeaderWithEdit(
                    title: t("wallpaper.downloads"),
                    systemImage: "arrow.down.circle.fill",
                    color: LiquidGlassColors.accentCyan,
                    countText: "\(viewModel.allLocalWallpapers.count) \(t("items"))",
                    section: .downloads
                )

                if viewModel.allLocalWallpapers.isEmpty {
                    emptyMediaSurface(
                        title: t("no.wallpaper.downloads"),
                        subtitle: t("no.wallpaper.downloads.hint"),
                        icon: "arrow.down.circle",
                        accent: LiquidGlassColors.accentCyan
                    )
                } else {
                    batchDeleteToolbar(section: .downloads, count: viewModel.allLocalWallpapers.count)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 18) {
                            ForEach(viewModel.allLocalWallpapers) { item in
                                WallpaperEditCard(
                                    wallpaper: item.wallpaper,
                                    isEditing: isEditing,
                                    isSelected: selectedItems.contains(item.id),
                                    downloadDate: item.downloadRecord?.downloadedAt
                                ) {
                                    handleWallpaperTap(item.wallpaper)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    // MARK: - Media Sections (原有功能)
    private var mediaSections: some View {
        VStack(alignment: .leading, spacing: 32) {
            // 媒体收藏
            VStack(alignment: .leading, spacing: 16) {
                sectionHeaderWithEdit(
                    title: t("media.favorites"),
                    systemImage: "heart.fill",
                    color: LiquidGlassColors.primaryPink,
                    countText: "\(mediaViewModel.favoriteItems.count) \(t("items"))",
                    section: .favorites
                )

                if mediaViewModel.favoriteItems.isEmpty {
                    emptyMediaSurface(
                        title: t("no.media.favorites"),
                        subtitle: t("no.media.favorites.hint"),
                        icon: "heart.slash",
                        accent: LiquidGlassColors.primaryPink
                    )
                } else {
                    batchDeleteToolbar(section: .favorites, count: mediaViewModel.favoriteItems.count)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 18) {
                            ForEach(mediaViewModel.favoriteItems) { item in
                                MediaVideoCard(
                                    item: item,
                                    isEditing: isEditing,
                                    isSelected: selectedItems.contains(item.id)
                                ) {
                                    handleMediaTap(item)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            // 媒体下载（包含下载记录和本地扫描的文件）
            VStack(alignment: .leading, spacing: 16) {
                sectionHeaderWithEdit(
                    title: t("media.downloads"),
                    systemImage: "arrow.down.circle.fill",
                    color: LiquidGlassColors.accentCyan,
                    countText: "\(mediaViewModel.allLocalMedia.count) \(t("items"))",
                    section: .downloads
                )

                if mediaViewModel.allLocalMedia.isEmpty {
                    emptyMediaSurface(
                        title: t("no.media.downloads"),
                        subtitle: t("no.media.downloads.hint"),
                        icon: "arrow.down.circle",
                        accent: LiquidGlassColors.accentCyan
                    )
                } else {
                    batchDeleteToolbar(section: .downloads, count: mediaViewModel.allLocalMedia.count)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 18) {
                            ForEach(mediaViewModel.allLocalMedia) { item in
                                MediaVideoCard(
                                    item: item.mediaItem,
                                    isEditing: isEditing,
                                    isSelected: selectedItems.contains(item.id)
                                ) {
                                    handleMediaTap(item.mediaItem)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    // MARK: - Anime Sections
    private var animeSections: some View {
        VStack(alignment: .leading, spacing: 32) {
            // 动漫收藏
            VStack(alignment: .leading, spacing: 16) {
                sectionHeaderWithEdit(
                    title: t("anime.favorites"),
                    systemImage: "heart.fill",
                    color: LiquidGlassColors.primaryPink,
                    countText: "\(animeFavorites.count) \(t("items"))",
                    section: .favorites
                )

                if animeFavorites.isEmpty {
                    emptyMediaSurface(
                        title: t("no.anime.favorites"),
                        subtitle: t("no.anime.favorites.hint"),
                        icon: "heart.slash",
                        accent: LiquidGlassColors.primaryPink
                    )
                } else {
                    batchDeleteToolbar(section: .favorites, count: animeFavorites.count)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 18) {
                            ForEach(animeFavorites) { anime in
                                AnimeLibraryCard(
                                    anime: anime,
                                    isEditing: isEditing,
                                    isSelected: selectedItems.contains(anime.id)
                                ) {
                                    handleAnimeTap(anime)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    // MARK: - Section Header with Edit
    private func sectionHeaderWithEdit(
        title: String,
        systemImage: String,
        color: Color,
        countText: String,
        section: EditingSection
    ) -> some View {
        HStack {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(color)

                Text(title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white.opacity(0.95))

                Text(countText)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }

            Spacer()

            // 编辑按钮
            Button {
                withAnimation {
                    if isEditing && editingSection == section {
                        isEditing = false
                        selectedItems.removeAll()
                    } else {
                        isEditing = true
                        editingSection = section
                        selectedItems.removeAll()
                    }
                }
            } label: {
                Text(isEditing && editingSection == section ? t("done") : t("edit"))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isEditing && editingSection == section ? .white : .white.opacity(0.7))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isEditing && editingSection == section ? color.opacity(0.3) : Color.white.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Batch Delete Toolbar
    private func batchDeleteToolbar(section: EditingSection, count: Int) -> some View {
        HStack {
            if isEditing && editingSection == section {
                // 全选/取消全选
                Button {
                    toggleSelectAll(for: section)
                } label: {
                    Text(selectedItems.count == count ? t("deselect.all") : t("select.all"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                }
                .buttonStyle(.plain)

                Spacer()

                // 删除按钮
                Button {
                    deleteSelectedItems(for: section)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "trash")
                        Text("\(t("delete")) (\(selectedItems.count))")
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.red.opacity(0.7))
                    )
                }
                .buttonStyle(.plain)
                .disabled(selectedItems.isEmpty)
            }
        }
        .frame(height: isEditing && editingSection == section ? 36 : 0)
        .opacity(isEditing && editingSection == section ? 1 : 0)
        .animation(.easeInOut(duration: 0.2), value: isEditing)
        .animation(.easeInOut(duration: 0.2), value: editingSection)
    }

    // MARK: - Empty State
    private func emptyMediaSurface(title: String, subtitle: String, icon: String, accent: Color) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundStyle(accent.opacity(0.8))

            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))

            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    // MARK: - Actions
    private func handleWallpaperTap(_ wallpaper: Wallpaper) {
        if isEditing {
            toggleSelection(wallpaper.id)
        } else {
            selectedWallpaper = wallpaper
        }
    }

    private func handleMediaTap(_ item: MediaItem) {
        if isEditing {
            toggleSelection(item.id)
        } else {
            selectedMedia = item
        }
    }

    private func handleAnimeTap(_ anime: AnimeSearchResult) {
        if isEditing {
            toggleSelection(anime.id)
        } else {
            selectedAnime = anime
        }
    }

    private func toggleSelection(_ id: String) {
        if selectedItems.contains(id) {
            selectedItems.remove(id)
        } else {
            selectedItems.insert(id)
        }
    }

    private func toggleSelectAll(for section: EditingSection) {
        switch selectedContentType {
        case .wallpaper:
            if section == .favorites {
                let allIDs = Set(viewModel.favorites.map(\.id))
                selectedItems = selectedItems.count == allIDs.count ? [] : allIDs
            } else {
                // 使用 allLocalWallpapers 包含下载记录和本地文件
                let allIDs = Set(viewModel.allLocalWallpapers.map(\.id))
                selectedItems = selectedItems.count == allIDs.count ? [] : allIDs
            }
        case .video:
            if section == .favorites {
                let allIDs = Set(mediaViewModel.favoriteItems.map(\.id))
                selectedItems = selectedItems.count == allIDs.count ? [] : allIDs
            } else {
                // 使用 allLocalMedia 包含下载记录和本地文件
                let allIDs = Set(mediaViewModel.allLocalMedia.map(\.id))
                selectedItems = selectedItems.count == allIDs.count ? [] : allIDs
            }
        case .anime:
            let allIDs = Set(animeFavorites.map(\.id))
            selectedItems = selectedItems.count == allIDs.count ? [] : allIDs
        }
    }

    private func deleteSelectedItems(for section: EditingSection) {
        switch selectedContentType {
        case .wallpaper:
            // 分别处理收藏和下载的删除
            let favoriteIDs = Set(viewModel.favorites.map(\.id))
            let selectedFavoriteIDs = selectedItems.intersection(favoriteIDs)
            if !selectedFavoriteIDs.isEmpty {
                viewModel.removeWallpaperFavorites(withIDs: selectedFavoriteIDs)
            }

            // 处理下载 + 本地文件的删除（包括物理文件）
            let allLocal = viewModel.allLocalWallpapers
            let localIDsToDelete = selectedItems.intersection(Set(allLocal.map(\.id)))
            if !localIDsToDelete.isEmpty {
                deleteLocalWallpapers(allLocal.filter { localIDsToDelete.contains($0.id) })
            }
            
        case .video:
            // 分别处理收藏和下载的删除
            let favoriteIDs = Set(mediaViewModel.favoriteItems.map(\.id))
            let selectedFavoriteIDs = selectedItems.intersection(favoriteIDs)
            if !selectedFavoriteIDs.isEmpty {
                mediaViewModel.removeFavorites(withIDs: selectedFavoriteIDs)
            }

            // 处理下载 + 本地媒体的删除（包括物理文件）
            let allLocal = mediaViewModel.allLocalMedia
            let localIDsToDelete = selectedItems.intersection(Set(allLocal.map(\.id)))
            if !localIDsToDelete.isEmpty {
                deleteLocalMedias(allLocal.filter { localIDsToDelete.contains($0.id) })
            }
            
        case .anime:
            for id in selectedItems {
                AnimeFavoriteStore.shared.removeFavorite(animeId: id)
            }
            Task {
                await loadAnimeFavorites()
            }
        }
        selectedItems.removeAll()
        isEditing = false
    }

    /// 删除本地壁纸（含物理文件删除）
    private func deleteLocalWallpapers(_ items: [UnifiedLocalWallpaper]) {
        let fileManager = FileManager.default
        
        for item in items {
            // 1. 如果有下载记录，先软删除记录
            if let record = item.downloadRecord {
                viewModel.removeWallpaperDownloads(withIDs: [record.wallpaper.id])
            }

            // 2. 删除物理文件
            let filePath = item.fileURL.path
            if fileManager.fileExists(atPath: filePath) {
                do {
                    try fileManager.removeItem(atPath: filePath)
                    print("[MyLibrary] ✅ Deleted file: \(filePath)")
                } catch {
                    print("[MyLibrary] ❌ Failed to delete file \(filePath): \(error)")
                }
            }
        }

        // 3. 重新扫描以刷新列表（同步等待完成，确保视图立即更新）
        Task {
            await LocalWallpaperScanner.shared.forceRescan()
            // 扫描完成后强制刷新 ViewModel（计算属性依赖扫描结果）
            viewModel.loadFavorites()
        }
    }

    /// 删除本地媒体（含物理文件删除）
    private func deleteLocalMedias(_ items: [UnifiedLocalMedia]) {
        let fileManager = FileManager.default

        for item in items {
            // 1. 如果有下载记录，先软删除记录
            if let record = item.downloadRecord {
                MediaLibraryService.shared.removeDownloadRecord(withID: record.item.id)
            }

            // 2. 删除物理文件
            let filePath = item.fileURL.path
            if fileManager.fileExists(atPath: filePath) {
                do {
                    try fileManager.removeItem(atPath: filePath)
                    print("[MyLibrary] ✅ Deleted media file: \(filePath)")
                } catch {
                    print("[MyLibrary] ❌ Failed to delete media file \(filePath): \(error)")
                }
            }
        }

        // 3. 重新扫描以刷新列表（同步等待完成，确保视图立即更新）
        Task {
            await LocalWallpaperScanner.shared.forceRescan()
            // 扫描完成后递增 revision 强制刷新（allLocalMedia 是计算属性）
            mediaViewModel.refreshLibraryContent()
        }
    }
}

// MARK: - Content Type Picker
struct ContentTypePicker: View {
    @Binding var selected: ContentType

    var body: some View {
        HStack(spacing: 12) {
            ForEach(ContentType.allCases, id: \.self) { type in
                ContentTypeButton(
                    type: type,
                    isSelected: selected == type
                ) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selected = type
                    }
                }
            }
        }
        .padding(.horizontal, 4)
    }
}

struct ContentTypeButton: View {
    let type: ContentType
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: type.icon)
                    .font(.system(size: 14, weight: .semibold))

                Text(type.displayName)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .medium))
            }
            .foregroundStyle(isSelected ? .white : .white.opacity(0.7))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.3) : Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? Color.accentColor.opacity(0.5) : Color.white.opacity(0.1), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Anime Library Card
struct AnimeLibraryCard: View {
    let anime: AnimeSearchResult
    let isEditing: Bool
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .bottomTrailing) {
                    OptimizedAsyncImage(url: URL(string: anime.coverURL ?? ""), priority: .low) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } placeholder: {
                        SkeletonCard(
                            width: LibraryCardMetrics.cardWidth,
                            height: LibraryCardMetrics.thumbnailHeight + 72,
                            cornerRadius: 0
                        )
                    }
                    .frame(width: LibraryCardMetrics.cardWidth, height: LibraryCardMetrics.thumbnailHeight + 72)
                    .clipped()

                    // 左上角复选框（编辑模式下显示）
                    if isEditing {
                        VStack {
                            HStack {
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 22, weight: .semibold))
                                    .foregroundStyle(isSelected ? LiquidGlassColors.secondaryViolet : .white.opacity(0.8))
                                    .background(
                                        Circle()
                                            .fill(isSelected ? .white : Color.black.opacity(0.4))
                                            .frame(width: 20, height: 20)
                                    )
                                    .padding(12)

                                Spacer()
                            }
                            Spacer()
                        }
                    }

                    // 选中时的遮罩
                    if isEditing && isSelected {
                        Color.black.opacity(0.3)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(anime.title)
                        .font(.system(size: 14.5, weight: .bold))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(2)

                    if let tags = anime.tags, !tags.isEmpty {
                        Text(tags.prefix(3).map { $0.name }.joined(separator: ", "))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.56))
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .frame(width: LibraryCardMetrics.cardWidth, alignment: .leading)
            .liquidGlassSurface(
                isHovered ? .max : .prominent,
                tint: LiquidGlassColors.secondaryViolet.opacity(0.12),
                in: RoundedRectangle(cornerRadius: 22, style: .continuous)
            )
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .scaleEffect(isHovered ? 1.01 : 1.0)
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .animation(.easeOut(duration: 0.16), value: isHovered)
        .throttledHover(interval: 0.05) { hovering in
            if !isEditing {
                isHovered = hovering
            }
        }
    }
}

