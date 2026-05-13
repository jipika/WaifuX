import SwiftUI
import Kingfisher
import AppKit
import AVFoundation

struct MyLibraryContentView: View {
    @StateObject private var viewModel = WallpaperViewModel()
    @StateObject private var mediaViewModel = MediaExploreViewModel()
    @StateObject private var downloadTaskViewModel = DownloadTaskViewModel()
    @ObservedObject private var animeFavoriteStore = AnimeFavoriteStore.shared
    @ObservedObject private var folderStore = LibraryFolderStore.shared

    // 分类筛选
    @State private var selectedContentType: ContentType = .wallpaper
    @Binding var selectedWallpaper: Wallpaper?
    @Binding var selectedMedia: MediaItem?
    @Binding var selectedAnime: AnimeSearchResult?
    @Binding var wallpaperContext: [Wallpaper]
    @Binding var mediaContext: [MediaItem]
    @State private var animeFavorites: [AnimeSearchResult] = []

    // 子标签：收藏 / 已下载
    @State private var selectedSubTab: SubTab = .downloads

    // 编辑状态
    @State private var isEditing = false
    @State private var selectedItems = Set<String>()

    // 图片预加载由 onAppear 直接触发，无需追踪可见卡片 ID

    // 壁纸比例筛选
    @State private var wallpaperRatioFilter: WallpaperRatioFilter = .all
    // 媒体比例筛选
    @State private var mediaRatioFilter: WallpaperRatioFilter = .all

    // 缓存壁纸和媒体列表，避免 computed property 在 body 重绘时反复 map/filter
    @State private var wallpaperItems: [AnyWallpaperItem] = []
    @State private var mediaItems: [AnyMediaItem] = []
    @State private var wallpaperFolderDisplay: [String: FolderDisplayInfo] = [:]
    @State private var mediaFolderDisplay: [String: FolderDisplayInfo] = [:]
    @State private var lastWallpaperPrefetchBucket: Int?
    @State private var lastMediaPrefetchBucket: Int?
    @State private var lastAnimePrefetchBucket: Int?
    
    // 文件夹导航
    @State private var currentWallpaperFolderID: String? = nil
    @State private var currentMediaFolderID: String? = nil
    @State private var wallpaperFolderStack: [String] = []  // 面包屑栈
    @State private var mediaFolderStack: [String] = []  // 面包屑栈
    
    // 新建文件夹
    @State private var showNewFolderSheet = false
    @State private var newFolderName = ""

    enum WallpaperRatioFilter: String, CaseIterable {
        case all = "all"
        case landscape = "landscape"
        case portrait = "portrait"

        var title: String {
            switch self {
            case .all: return LocalizationService.shared.t("filter.all")
            case .landscape: return LocalizationService.shared.t("filter.landscape")
            case .portrait: return LocalizationService.shared.t("filter.portrait")
            }
        }
    }

    enum SubTab: String, CaseIterable {
        case favorites = "favorites"
        case downloads = "downloads"

        var title: String {
            switch self {
            case .favorites: return LocalizationService.shared.t("my.favorites")
            case .downloads: return LocalizationService.shared.t("my.downloads")
            }
        }
    }

    private struct FolderDisplayInfo {
        let previewURLs: [URL]
        let itemCount: Int
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
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

            SpotlightBackground(
                lightColor: Color.white.opacity(0.95),
                backgroundColor: Color.black,
                intensity: 0.9,
                spread: 0.4
            )
            .ignoresSafeArea()

            GeometryReader { geometry in
                let contentWidth = max(0, geometry.size.width - 56)
                let gridConfig = LibraryGridConfig(contentWidth: contentWidth)

                ScrollView {
                    VStack(alignment: .leading, spacing: 32) {
                        mediaHero
                        ContentTypePicker(selected: $selectedContentType)
                        contentSections(config: gridConfig)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 80)
                    .padding(.bottom, 48)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .frame(minHeight: geometry.size.height)
                }
                .scrollClipDisabled()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await viewModel.initialLoad()
            await loadAnimeFavorites()
            Task {
                await LocalWallpaperScanner.shared.forceRescan()
            }
            updateWallpaperItems()
            updateMediaItems()
        }
        .onReceive(animeFavoriteStore.$favorites) { _ in
            Task {
                await loadAnimeFavorites()
            }
        }
        .onChange(of: viewModel.libraryContentRevision) { _, _ in
            updateWallpaperItems()
        }
        .onChange(of: mediaViewModel.libraryContentRevision) { _, _ in
            updateMediaItems()
        }
        .onChange(of: selectedSubTab) { _, _ in
            // 切换子标签时重置文件夹导航
            currentWallpaperFolderID = nil
            currentMediaFolderID = nil
            wallpaperFolderStack.removeAll()
            mediaFolderStack.removeAll()
            isEditing = false
            selectedItems.removeAll()
            updateWallpaperItems()
            updateMediaItems()
        }
        .onChange(of: wallpaperRatioFilter) { _, _ in
            updateWallpaperItems()
        }
        .onChange(of: mediaRatioFilter) { _, _ in
            updateMediaItems()
        }
        .onReceive(folderStore.$wallpaperFolders) { _ in
            updateWallpaperItems()
        }
        .onReceive(folderStore.$mediaFolders) { _ in
            updateMediaItems()
        }
        .onReceive(NotificationCenter.default.publisher(for: .appShouldReleaseForegroundMemory)) { _ in
            releaseForegroundMemory()
        }
        .onChange(of: selectedContentType) { _, _ in
            // 切换内容类型时重置编辑状态和文件夹导航
            isEditing = false
            selectedItems.removeAll()
            currentWallpaperFolderID = nil
            currentMediaFolderID = nil
            wallpaperFolderStack.removeAll()
            mediaFolderStack.removeAll()
            updateWallpaperItems()
            updateMediaItems()
        }
        .sheet(isPresented: $showNewFolderSheet) {
            NewFolderSheet(
                folderName: $newFolderName,
                onConfirm: {
                    let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    let contentType: LibraryFolder.FolderContentType = selectedContentType == .wallpaper ? .wallpaper : .media
                    let parentID = selectedContentType == .wallpaper ? currentWallpaperFolderID : currentMediaFolderID
                    folderStore.createFolder(name: name, contentType: contentType, parentID: parentID)
                    newFolderName = ""
                    showNewFolderSheet = false
                    updateWallpaperItems()
                    updateMediaItems()
                },
                onCancel: {
                    newFolderName = ""
                    showNewFolderSheet = false
                }
            )
        }
    }

    // MARK: - 加载动漫收藏
    private func loadAnimeFavorites() async {
        let favorites = animeFavoriteStore.allFavorites
        lastAnimePrefetchBucket = nil
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

    private func releaseForegroundMemory() {
        viewModel.releaseForegroundMemory()
        mediaViewModel.releaseForegroundMemory()

        selectedWallpaper = nil
        selectedMedia = nil
        selectedAnime = nil
        wallpaperContext.removeAll()
        mediaContext.removeAll()
        animeFavorites.removeAll()
        wallpaperItems.removeAll()
        mediaItems.removeAll()
        wallpaperFolderDisplay.removeAll()
        mediaFolderDisplay.removeAll()
        currentWallpaperFolderID = nil
        currentMediaFolderID = nil
        wallpaperFolderStack.removeAll()
        mediaFolderStack.removeAll()
        selectedItems.removeAll()
        isEditing = false
        showNewFolderSheet = false
        newFolderName = ""
        lastWallpaperPrefetchBucket = nil
        lastMediaPrefetchBucket = nil
        lastAnimePrefetchBucket = nil
    }

    // MARK: - Hero
    private var mediaHero: some View {
        HStack(alignment: .bottom) {
            Text(t("my.media.library"))
                .font(.system(size: 42, weight: .bold, design: .serif))
                .foregroundStyle(.white.opacity(0.96))

            Spacer()

            let (count, icon, color, key) = heroBadgeInfo
            SettingsStatusBadge(
                title: "\(count) \(t(key))",
                systemImage: icon,
                color: color
            )
        }
    }

    private var heroBadgeInfo: (count: Int, icon: String, color: Color, key: String) {
        switch selectedContentType {
        case .wallpaper:
            if selectedSubTab == .favorites {
                return (viewModel.favorites.count, "heart.fill", LiquidGlassColors.primaryPink, "item.favorites")
            } else {
                return (viewModel.allLocalWallpapers.count, "arrow.down.circle.fill", LiquidGlassColors.accentCyan, "item.downloads")
            }
        case .video:
            if selectedSubTab == .favorites {
                return (mediaViewModel.favoriteItems.count, "heart.fill", LiquidGlassColors.primaryPink, "item.favorites")
            } else {
                return (mediaViewModel.allLocalMedia.count, "arrow.down.circle.fill", LiquidGlassColors.accentCyan, "item.downloads")
            }
        case .anime:
            return (animeFavorites.count, "heart.fill", LiquidGlassColors.primaryPink, "item.favorites")
        }
    }

    // MARK: - Content Sections
    @ViewBuilder
    private func contentSections(config: LibraryGridConfig) -> some View {
        switch selectedContentType {
        case .wallpaper:
            wallpaperSection(config: config)
        case .video:
            mediaSection(config: config)
        case .anime:
            animeSection(config: config)
        }
    }

    // MARK: - Wallpaper Section
    private func wallpaperSection(config: LibraryGridConfig) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(
                title: t("library.wallpapers"),
                color: LiquidGlassColors.primaryPink,
                importAction: importWallpapers,
                folderURL: DownloadPathManager.shared.wallpapersFolderURL
            )
            
            // 文件夹导航面包屑
            folderBreadcrumb(
                folderStack: wallpaperFolderStack,
                isInFolder: currentWallpaperFolderID != nil,
                onBack: popWallpaperFolder,
                onRoot: { navigateToWallpaperFolder(nil) }
            )

            if wallpaperItems.isEmpty && currentWallpaperFolders.isEmpty {
                emptyMediaSurface(
                    title: selectedSubTab == .favorites ? t("no.wallpaper.favorites") : t("no.wallpaper.downloads"),
                    subtitle: selectedSubTab == .favorites ? t("no.wallpaper.favorites.hint") : t("no.wallpaper.downloads.hint"),
                    icon: selectedSubTab == .favorites ? "heart.slash" : "arrow.down.circle",
                    accent: LiquidGlassColors.primaryPink
                )
            } else {
                batchDeleteToolbar(count: wallpaperItems.count + currentWallpaperFolders.count)

                LazyVGrid(columns: config.gridItems, alignment: .leading, spacing: config.spacing) {
                    // 文件夹
                    ForEach(currentWallpaperFolders) { folder in
                        wallpaperFolderCard(folder: folder, config: config)
                    }
                    // 壁纸卡片
                    ForEach(wallpaperItems) { item in
                        wallpaperGridItem(item: item, config: config)
                            .onAppear {
                                preloadNearbyWallpapers(around: item, config: config)
                            }
                    }
                }
            }
        }
    }
    
    private func wallpaperFolderCard(folder: LibraryFolder, config: LibraryGridConfig) -> some View {
        let display = wallpaperFolderDisplay[folder.id] ?? FolderDisplayInfo(previewURLs: [], itemCount: 0)
        return LibraryFolderCard(
            folder: folder,
            previewURLs: display.previewURLs,
            itemCount: display.itemCount,
            cardWidth: config.cardWidth,
            onTap: { navigateToWallpaperFolder(folder.id) },
            onDrop: { ids in moveWallpapersToFolder(ids: ids, folderID: folder.id) },
            onDisband: {
                folderStore.deleteFolder(id: folder.id, contentType: .wallpaper)
                updateWallpaperItems()
            }
        )
        .draggable("waifux:folder:\(folder.id)")
    }
    
    private func navigateToWallpaperFolder(_ folderID: String?) {
        if let current = currentWallpaperFolderID, folderID != nil {
            wallpaperFolderStack.append(current)
        }
        currentWallpaperFolderID = folderID
        updateWallpaperItems()
    }
    
    private func popWallpaperFolder() {
        guard !wallpaperFolderStack.isEmpty else {
            currentWallpaperFolderID = nil
            updateWallpaperItems()
            return
        }
        currentWallpaperFolderID = wallpaperFolderStack.popLast()
        updateWallpaperItems()
    }
    
    private func moveWallpapersToFolder(ids: [String], folderID: String) {
        for id in ids {
            folderStore.moveWallpaperToFolder(wallpaperID: id, folderID: folderID)
        }
        updateWallpaperItems()
    }

    private func updateWallpaperItems() {
        lastWallpaperPrefetchBucket = nil
        let baseItems: [AnyWallpaperItem]
        switch selectedSubTab {
        case .favorites:
            let allFavorites = viewModel.favorites
            let folderID = currentWallpaperFolderID
            let filtered = allFavorites.filter { wallpaper in
                guard let record = WallpaperLibraryService.shared.favoriteRecord(for: wallpaper.id) else { return false }
                return record.folderID == folderID
            }
            baseItems = filtered.map { AnyWallpaperItem(wallpaper: $0) }
        case .downloads:
            let allLocal = viewModel.allLocalWallpapers
            let folderID = currentWallpaperFolderID
            let filtered = allLocal.filter { unified in
                if let record = unified.downloadRecord {
                    return record.folderID == folderID
                }
                // 扫描到的本地文件只在根目录显示
                return folderID == nil
            }
            baseItems = filtered.map { AnyWallpaperItem(unified: $0) }
        }
        switch wallpaperRatioFilter {
        case .all:
            wallpaperItems = baseItems
        case .landscape:
            wallpaperItems = baseItems.filter { $0.wallpaper.dimensionX >= $0.wallpaper.dimensionY }
        case .portrait:
            wallpaperItems = baseItems.filter { $0.wallpaper.dimensionX < $0.wallpaper.dimensionY }
        }
        refreshWallpaperFolderDisplay()
    }
    
    private var currentWallpaperFolders: [LibraryFolder] {
        folderStore.folders(for: .wallpaper, parentID: currentWallpaperFolderID)
    }
    
    private var currentMediaFolders: [LibraryFolder] {
        folderStore.folders(for: .media, parentID: currentMediaFolderID)
    }

    private func updateMediaItems() {
        lastMediaPrefetchBucket = nil
        let baseItems: [AnyMediaItem]
        switch selectedSubTab {
        case .favorites:
            let allFavorites = mediaViewModel.favoriteItems
            let folderID = currentMediaFolderID
            let filtered = allFavorites.filter { item in
                guard let record = MediaLibraryService.shared.favoriteRecord(for: item.id) else { return false }
                return record.folderID == folderID
            }
            baseItems = filtered.map {
                AnyMediaItem(
                    mediaItem: $0,
                    localFileURL: MediaLibraryService.shared.localFileURLIfAvailable(for: $0)
                )
            }
        case .downloads:
            let allLocal = mediaViewModel.allLocalMedia
            let folderID = currentMediaFolderID
            let filtered = allLocal.filter { unified in
                if let record = unified.downloadRecord {
                    return record.folderID == folderID
                }
                // 扫描到的本地文件只在根目录显示
                return folderID == nil
            }
            baseItems = filtered.map { AnyMediaItem(unified: $0) }
        }
        // 媒体库不再做横屏/竖屏筛选
        mediaItems = baseItems
        refreshMediaFolderDisplay()
    }

    @ViewBuilder
    private func wallpaperGridItem(item: AnyWallpaperItem, config: LibraryGridConfig) -> some View {
        WallpaperEditCard(
            wallpaper: item.wallpaper,
            localFileURL: item.localFileURL,
            accent: selectedSubTab == .favorites ? LiquidGlassColors.primaryPink : LiquidGlassColors.accentCyan,
            isEditing: isEditing,
            isSelected: selectedItems.contains(item.id),
            downloadDate: item.downloadDate,
            cardWidth: config.cardWidth
        ) {
            handleWallpaperTap(item.wallpaper)
        }
        .draggable("waifux:item:\(item.id)")
        .contextMenu {
            if currentWallpaperFolderID != nil {
                Button {
                    folderStore.moveWallpaperToFolder(wallpaperID: item.id, folderID: nil)
                    updateWallpaperItems()
                } label: {
                    Label(t("remove.from.folder"), systemImage: "folder.badge.minus")
                }
            }
        }
    }

    // MARK: - Media Section
    private func mediaSection(config: LibraryGridConfig) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(
                title: t("library.videos"),
                color: LiquidGlassColors.secondaryViolet,
                importAction: { Task { await importMedia() } },
                workshopImportAction: importWorkshop,
                folderURL: DownloadPathManager.shared.mediaFolderURL
            )
            
            // 文件夹导航面包屑
            folderBreadcrumb(
                folderStack: mediaFolderStack,
                isInFolder: currentMediaFolderID != nil,
                onBack: popMediaFolder,
                onRoot: { navigateToMediaFolder(nil) }
            )

            if mediaItems.isEmpty && currentMediaFolders.isEmpty {
                emptyMediaSurface(
                    title: selectedSubTab == .favorites ? t("no.media.favorites") : t("no.media.downloads"),
                    subtitle: selectedSubTab == .favorites ? t("no.media.favorites.hint") : t("no.media.downloads.hint"),
                    icon: selectedSubTab == .favorites ? "heart.slash" : "arrow.down.circle",
                    accent: LiquidGlassColors.secondaryViolet
                )
            } else {
                batchDeleteToolbar(count: mediaItems.count + currentMediaFolders.count)

                LazyVGrid(columns: config.gridItems, alignment: .leading, spacing: config.spacing) {
                    // 文件夹
                    ForEach(currentMediaFolders) { folder in
                        mediaFolderCard(folder: folder, config: config)
                    }
                    // 媒体卡片
                    ForEach(mediaItems) { item in
                        mediaGridItem(item: item, config: config)
                            .onAppear {
                                preloadNearbyMedia(around: item, config: config)
                            }
                    }
                }
            }
        }
    }
    
    private func mediaFolderCard(folder: LibraryFolder, config: LibraryGridConfig) -> some View {
        let display = mediaFolderDisplay[folder.id] ?? FolderDisplayInfo(previewURLs: [], itemCount: 0)
        return LibraryFolderCard(
            folder: folder,
            previewURLs: display.previewURLs,
            itemCount: display.itemCount,
            cardWidth: config.cardWidth,
            onTap: { navigateToMediaFolder(folder.id) },
            onDrop: { ids in moveMediasToFolder(ids: ids, folderID: folder.id) },
            onDisband: {
                folderStore.deleteFolder(id: folder.id, contentType: .media)
                updateMediaItems()
            }
        )
        .draggable("waifux:folder:\(folder.id)")
    }
    
    private func navigateToMediaFolder(_ folderID: String?) {
        if let current = currentMediaFolderID, folderID != nil {
            mediaFolderStack.append(current)
        }
        currentMediaFolderID = folderID
        updateMediaItems()
    }
    
    private func popMediaFolder() {
        guard !mediaFolderStack.isEmpty else {
            currentMediaFolderID = nil
            updateMediaItems()
            return
        }
        currentMediaFolderID = mediaFolderStack.popLast()
        updateMediaItems()
    }
    
    private func moveMediasToFolder(ids: [String], folderID: String) {
        for id in ids {
            folderStore.moveMediaToFolder(mediaID: id, folderID: folderID)
        }
        updateMediaItems()
    }

    private var currentMediaItems: [AnyMediaItem] {
        mediaItems
    }

    private var activeRatioFilter: WallpaperRatioFilter {
        selectedContentType == .wallpaper ? wallpaperRatioFilter : mediaRatioFilter
    }

    @ViewBuilder
    private func mediaGridItem(item: AnyMediaItem, config: LibraryGridConfig) -> some View {
        MediaVideoCard(
            item: item.mediaItem,
            localMediaFileURL: item.localFileURL,
            badgeText: selectedSubTab == .favorites ? t("badge.favorite") : item.mediaItem.resolutionLabel,
            accent: selectedSubTab == .favorites ? LiquidGlassColors.primaryPink : LiquidGlassColors.accentCyan,
            isEditing: isEditing,
            isSelected: selectedItems.contains(item.id),
            cardWidth: config.cardWidth
        ) {
            handleMediaTap(item.mediaItem)
        }
        .draggable("waifux:item:\(item.id)")
        .contextMenu {
            if currentMediaFolderID != nil {
                Button {
                    folderStore.moveMediaToFolder(mediaID: item.id, folderID: nil)
                    updateMediaItems()
                } label: {
                    Label(t("remove.from.folder"), systemImage: "folder.badge.minus")
                }
            }
        }
    }

    // MARK: - Image Preloading
    private func preloadNearbyWallpapers(around item: AnyWallpaperItem, config: LibraryGridConfig) {
        guard let index = wallpaperItems.firstIndex(where: { $0.id == item.id }) else { return }
        let bucket = prefetchBucket(for: index)
        guard lastWallpaperPrefetchBucket != bucket else { return }
        lastWallpaperPrefetchBucket = bucket

        let targetSize = CGSize(width: 512, height: 512)
        let range = prefetchRange(around: index, totalCount: wallpaperItems.count)
        let urls = range
            .filter { $0 != index }
            .compactMap { wallpaperItems[$0].wallpaper.thumbURL }

        let prefetcher = Kingfisher.ImagePrefetcher(
            urls: urls,
            options: [.processor(DownsamplingImageProcessor(size: targetSize))]
        )
        prefetcher.start()
    }

    private func preloadNearbyMedia(around item: AnyMediaItem, config: LibraryGridConfig) {
        guard let index = currentMediaItems.firstIndex(where: { $0.id == item.id }) else { return }
        let bucket = prefetchBucket(for: index)
        guard lastMediaPrefetchBucket != bucket else { return }
        lastMediaPrefetchBucket = bucket

        let targetSize = CGSize(width: 512, height: 512)
        let range = prefetchRange(around: index, totalCount: currentMediaItems.count)
        let urls = range
            .filter { $0 != index }
            .map { currentMediaItems[$0] }
            .map { $0.mediaItem.libraryGridThumbnailURL(localFileURL: $0.localFileURL) }

        let prefetcher = Kingfisher.ImagePrefetcher(
            urls: urls,
            options: [.processor(DownsamplingImageProcessor(size: targetSize))]
        )
        prefetcher.start()
    }

    private func preloadNearbyAnime(around anime: AnimeSearchResult, config: LibraryGridConfig) {
        guard let index = currentAnimeItems.firstIndex(where: { $0.id == anime.id }) else { return }
        let bucket = prefetchBucket(for: index)
        guard lastAnimePrefetchBucket != bucket else { return }
        lastAnimePrefetchBucket = bucket

        let targetSize = CGSize(width: 512, height: 512)
        let range = prefetchRange(around: index, totalCount: currentAnimeItems.count)
        let urls = range
            .filter { $0 != index }
            .compactMap { URL(string: currentAnimeItems[$0].coverURL ?? "") }

        let prefetcher = Kingfisher.ImagePrefetcher(
            urls: urls,
            options: [.processor(DownsamplingImageProcessor(size: targetSize))]
        )
        prefetcher.start()
    }

    private func prefetchBucket(for index: Int) -> Int {
        index / 6
    }

    private func prefetchRange(around index: Int, totalCount: Int) -> Range<Int> {
        max(0, index - 8)..<min(totalCount, index + 9)
    }

    private func refreshWallpaperFolderDisplay() {
        let folders = currentWallpaperFolders
        guard !folders.isEmpty else {
            wallpaperFolderDisplay = [:]
            return
        }

        var next: [String: FolderDisplayInfo] = [:]
        for folder in folders {
            let favoriteWallpapers = WallpaperLibraryService.shared.favoriteWallpapers(inFolder: folder.id)
            let downloadedWallpapers = WallpaperLibraryService.shared.downloadedWallpapers(inFolder: folder.id).map(\.wallpaper)
            // 有序去重：优先 favorite 顺序，下载记录替换同名项
            var seen = Set<String>()
            var wallpapers: [Wallpaper] = []
            // 下载记录优先（有本地抽帧），favorite 补充去重
            for w in downloadedWallpapers + favoriteWallpapers {
                if seen.insert(w.id).inserted { wallpapers.append(w) }
            }
            next[folder.id] = FolderDisplayInfo(
                previewURLs: Array(wallpapers.prefix(3).compactMap(\.thumbURL)),
                itemCount: wallpapers.count
            )
        }
        wallpaperFolderDisplay = next
    }

    private func refreshMediaFolderDisplay() {
        let folders = currentMediaFolders
        guard !folders.isEmpty else {
            mediaFolderDisplay = [:]
            return
        }

        var next: [String: FolderDisplayInfo] = [:]
        for folder in folders {
            let favoriteItems = MediaLibraryService.shared.favoriteItems(inFolder: folder.id)
            let records = MediaLibraryService.shared.downloadedItems(inFolder: folder.id)

            // 下载记录优先；使用与卡片封面一致的 libraryGridThumbnailURL 解析
            var seen = Set<String>()
            var items: [MediaItem] = []
            var localPaths: [String: URL] = [:]  // id → local file URL

            for r in records {
                guard seen.insert(r.item.id).inserted else { continue }
                items.append(r.item)
                let url = URL(fileURLWithPath: r.localFilePath)
                localPaths[r.item.id] = url
            }
            // favorite 补充不重复的项
            for item in favoriteItems where seen.insert(item.id).inserted {
                items.append(item)
            }
            // 使用与卡片封面完全一致的解析链（抽帧 > 本地静图 > 海报 > 站点封面）
            let previewURLs = items.prefix(3).map { item in
                item.libraryGridThumbnailURL(localFileURL: localPaths[item.id])
            }
            // 异步生成尚未缓存的抽帧（与 MediaVideoCard.onAppear 逻辑一致）
            for (itemID, localURL) in localPaths {
                guard FileManager.default.fileExists(atPath: localURL.path) else { continue }
                // 第一步：尝试常规视频文件解析
                let resolvedVideo = MediaItem.resolveLocalVideoFile(from: localURL) ?? (
                    ["mp4", "mov", "webm", "m4v", "mkv"].contains(localURL.pathExtension.lowercased()) ? localURL : nil
                )
                // 第二步：若常规解析失败，尝试查找烘焙产物（Scene 项目）
                let bakeVideoURL: URL? = (resolvedVideo == nil)
                    ? MediaLibraryService.shared.downloadRecords
                        .first(where: { $0.item.id == itemID })?
                        .sceneBakeArtifact
                        .flatMap { URL(fileURLWithPath: $0.videoPath) }
                    : nil
                let videoURL = resolvedVideo ?? bakeVideoURL
                if let videoURL,
                   VideoThumbnailCache.shared.cachedStaticThumbnailFileURLIfExists(forLocalFile: videoURL) == nil,
                   ["mp4", "mov", "webm", "m4v", "mkv"].contains(videoURL.pathExtension.lowercased()) {
                    Task { @MainActor in
                        if await VideoThumbnailCache.shared.posterJPEGFileURL(forLocalVideo: videoURL) != nil {
                            refreshMediaFolderDisplay()
                        }
                    }
                }
            }
            next[folder.id] = FolderDisplayInfo(
                previewURLs: previewURLs,
                itemCount: items.count
            )
        }
        mediaFolderDisplay = next
    }

    // MARK: - Anime Section
    private func animeSection(config: LibraryGridConfig) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(
                title: t("library.anime"),
                color: LiquidGlassColors.tertiaryBlue,
                importAction: nil,
                folderURL: nil
            )

            if currentAnimeItems.isEmpty {
                emptyMediaSurface(
                    title: t("no.anime.favorites"),
                    subtitle: t("no.anime.favorites.hint"),
                    icon: "heart.slash",
                    accent: LiquidGlassColors.tertiaryBlue
                )
            } else {
                batchDeleteToolbar(count: currentAnimeItems.count)

                LazyVGrid(columns: config.gridItems, alignment: .leading, spacing: config.spacing) {
                    ForEach(currentAnimeItems) { anime in
                        AnimeLibraryCard(
                            anime: anime,
                            isEditing: isEditing,
                            isSelected: selectedItems.contains(anime.id),
                            cardWidth: config.cardWidth
                        ) {
                            handleAnimeTap(anime)
                        }
                        .onAppear {
                            preloadNearbyAnime(around: anime, config: config)
                        }
                    }
                }
            }
        }
    }

    private var currentAnimeItems: [AnimeSearchResult] {
        // 动漫目前只有收藏
        animeFavorites
    }

    // MARK: - Section Header
    private func sectionHeader(
        title: String,
        color: Color,
        importAction: (() -> Void)?,
        workshopImportAction: (() -> Void)? = nil,
        folderURL: URL?
    ) -> some View {
        HStack(spacing: 16) {
            // 左侧：收藏 / 已下载 下拉选择器 + 壁纸比例筛选
            HStack(spacing: 10) {
                if selectedContentType != .anime {
                    Menu {
                        ForEach(SubTab.allCases, id: \.self) { tab in
                            Button(tab.title) {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    selectedSubTab = tab
                                    isEditing = false
                                    selectedItems.removeAll()
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(selectedSubTab.title)
                                .font(.system(size: 14, weight: .semibold))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(.white.opacity(0.95))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.white.opacity(0.1))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.white.opacity(0.15), lineWidth: 1)
                        )
                    }
                    .menuStyle(.borderlessButton)
                    .pointingHandCursor()
                } else {
                    Text(title)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white.opacity(0.95))
                }

                // 壁纸比例筛选（媒体库不显示）
                if selectedContentType == .wallpaper {
                    HStack(spacing: 0) {
                        ForEach(WallpaperRatioFilter.allCases, id: \.self) { filter in
                            Button {
                                if selectedContentType == .wallpaper {
                                    wallpaperRatioFilter = filter
                                } else {
                                    mediaRatioFilter = filter
                                }
                                isEditing = false
                                selectedItems.removeAll()
                            } label: {
                                Text(filter.title)
                                    .font(.system(size: 12, weight: activeRatioFilter == filter ? .semibold : .medium))
                                    .foregroundStyle(activeRatioFilter == filter ? .white : .white.opacity(0.7))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .fill(activeRatioFilter == filter ? color.opacity(0.35) : Color.clear)
                                    )
                            }
                            .buttonStyle(.plain)
                            .pointingHandCursor()
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
                }
            }

            Spacer()

            // 右侧：按钮组
            HStack(spacing: 8) {
                // 新建文件夹
                if selectedContentType != .anime {
                    Button {
                        showNewFolderSheet = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "folder.badge.plus")
                                .font(.system(size: 12))
                            Text(t("new.folder"))
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.white.opacity(0.12), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                }
                
                // 编辑 / 完成
                Button {
                    withAnimation {
                        isEditing.toggle()
                        selectedItems.removeAll()
                    }
                } label: {
                    Text(isEditing ? t("done") : t("edit"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isEditing ? .white : .white.opacity(0.9))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(isEditing ? color.opacity(0.35) : Color.white.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.white.opacity(0.12), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .pointingHandCursor()

                // 导入
                if let importAction {
                    Button(action: importAction) {
                        Text(t("import"))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.white.opacity(0.08))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                }

                // Workshop 导入
                if let workshopImportAction {
                    Button(action: workshopImportAction) {
                        Text(t("import.workshop"))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.white.opacity(0.08))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                }

                // 打开文件夹
                if let folderURL {
                    Button {
                        openFolderInFinder(folderURL)
                    } label: {
                        Text(t("open.in.finder"))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.white.opacity(0.08))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                }
            }
        }
    }
    
    // MARK: - 文件夹面包屑
    @ViewBuilder
    private func folderBreadcrumb(
        folderStack: [String],
        isInFolder: Bool,
        onBack: @escaping () -> Void,
        onRoot: @escaping () -> Void
    ) -> some View {
        if isInFolder {
            HStack(spacing: 6) {
                Button(action: onRoot) {
                    Image(systemName: "house")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                
                if !folderStack.isEmpty {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.3))
                    
                    Text("...")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                    
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.3))
                }
                
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.left")
                            .font(.system(size: 10))
                        Text(t("back"))
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                
                Spacer()
            }
            .padding(.horizontal, 4)
        }
    }

    // MARK: - Batch Delete Toolbar
    private func batchDeleteToolbar(count: Int) -> some View {
        HStack {
            if isEditing {
                // 全选/取消全选
                Button {
                    toggleSelectAll()
                } label: {
                    Text(selectedItems.count == count ? t("deselect.all") : t("select.all"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                }
                .buttonStyle(.plain)

                Spacer()

                // 删除按钮
                Button {
                    deleteSelectedItems()
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
        .frame(height: isEditing ? 36 : 0)
        .opacity(isEditing ? 1 : 0)
        .animation(.easeInOut(duration: 0.2), value: isEditing)
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
            wallpaperContext = wallpaperItems.map(\.wallpaper)
            selectedWallpaper = wallpaper
        }
    }
    
    private func handleFolderTap(_ folder: LibraryFolder) {
        if isEditing {
            toggleSelection("folder_\(folder.id)")
        } else {
            switch folder.contentType {
            case .wallpaper:
                navigateToWallpaperFolder(folder.id)
            case .media:
                navigateToMediaFolder(folder.id)
            }
        }
    }

    private func handleMediaTap(_ item: MediaItem) {
        if isEditing {
            toggleSelection(item.id)
        } else {
            mediaContext = mediaItems.map(\.mediaItem)
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

    private func toggleSelectAll() {
        let allIDs = Set(currentItemIDs)
        selectedItems = selectedItems.count == allIDs.count ? [] : allIDs
    }

    private var currentItemIDs: [String] {
        switch selectedContentType {
        case .wallpaper:
            let folderIDs = currentWallpaperFolders.map { "folder_\($0.id)" }
            let itemIDs = wallpaperItems.map(\.id)
            return folderIDs + itemIDs
        case .video:
            let folderIDs = currentMediaFolders.map { "folder_\($0.id)" }
            let itemIDs = currentMediaItems.map(\.id)
            return folderIDs + itemIDs
        case .anime:
            return currentAnimeItems.map(\.id)
        }
    }

    private func deleteSelectedItems() {
        // 分离文件夹 ID 和普通项目 ID
        let folderIDs = selectedItems.filter { $0.hasPrefix("folder_") }
        let itemIDs = selectedItems.filter { !$0.hasPrefix("folder_") }
        
        // 先删除文件夹
        for folderID in folderIDs {
            let realID = String(folderID.dropFirst(7))
            switch selectedContentType {
            case .wallpaper:
                folderStore.deleteFolder(id: realID, contentType: .wallpaper)
            case .video:
                folderStore.deleteFolder(id: realID, contentType: .media)
            case .anime:
                break
            }
        }
        
        // 再删除普通项目
        switch selectedContentType {
        case .wallpaper:
            if selectedSubTab == .favorites {
                let favoriteIDs = Set(viewModel.favorites.map(\.id))
                let ids = itemIDs.intersection(favoriteIDs)
                if !ids.isEmpty {
                    viewModel.removeWallpaperFavorites(withIDs: ids)
                }
            } else {
                let allLocal = viewModel.allLocalWallpapers
                let ids = itemIDs.intersection(Set(allLocal.map(\.id)))
                if !ids.isEmpty {
                    deleteLocalWallpapers(allLocal.filter { ids.contains($0.id) })
                }
            }

        case .video:
            if selectedSubTab == .favorites {
                let favoriteIDs = Set(mediaViewModel.favoriteItems.map(\.id))
                let ids = itemIDs.intersection(favoriteIDs)
                if !ids.isEmpty {
                    mediaViewModel.removeFavorites(withIDs: ids)
                }
            } else {
                let allLocal = mediaViewModel.allLocalMedia
                let ids = itemIDs.intersection(Set(allLocal.map(\.id)))
                if !ids.isEmpty {
                    deleteLocalMedias(allLocal.filter { ids.contains($0.id) })
                }
            }

        case .anime:
            for id in itemIDs {
                AnimeFavoriteStore.shared.removeFavorite(animeId: id)
            }
            Task {
                await loadAnimeFavorites()
            }
        }
        selectedItems.removeAll()
        isEditing = false
        updateWallpaperItems()
        updateMediaItems()
    }

    /// 删除本地壁纸（含物理文件删除）
    private func deleteLocalWallpapers(_ items: [UnifiedLocalWallpaper]) {
        let fileManager = FileManager.default

        for item in items {
            if let record = item.downloadRecord {
                viewModel.removeWallpaperDownloads(withIDs: [record.wallpaper.id])
            }
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

        Task {
            await LocalWallpaperScanner.shared.forceRescan()
            viewModel.loadFavorites()
        }
    }

    /// 删除本地媒体（含物理文件删除）
    private func deleteLocalMedias(_ items: [UnifiedLocalMedia]) {
        let fileManager = FileManager.default

        for item in items {
            if let record = item.downloadRecord {
                MediaLibraryService.shared.removeDownloadRecord(withID: record.item.id)
            }
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

        Task {
            await LocalWallpaperScanner.shared.forceRescan()
            mediaViewModel.refreshLibraryContent()
        }
    }

    // MARK: - Grid Config
    private struct LibraryGridConfig {
        let columnCount: Int
        let spacing: CGFloat
        let cardWidth: CGFloat
        let contentWidth: CGFloat
        let gridItems: [GridItem]

        init(contentWidth: CGFloat) {
            self.contentWidth = contentWidth
            self.columnCount = contentWidth > 1200 ? 4 : (contentWidth > 800 ? 3 : 2)
            self.spacing = 16
            let totalSpacing = spacing * CGFloat(columnCount - 1)
            self.cardWidth = floor((contentWidth - totalSpacing) / CGFloat(columnCount))
            self.gridItems = Array(repeating: GridItem(.flexible(), spacing: spacing), count: columnCount)
        }
    }

    // MARK: - Import & Folder
    private func openFolderInFinder(_ url: URL) {
        DownloadPathManager.shared.createDirectoryStructure()
        NSWorkspace.shared.open(url)
    }

    private func importWallpapers() {
        DownloadPathManager.shared.createDirectoryStructure()
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image]
        panel.prompt = t("import")

        guard panel.runModal() == .OK else { return }

        let destinationFolder = DownloadPathManager.shared.wallpapersFolderURL
        let fileManager = FileManager.default
        var importedCount = 0

        for url in panel.urls {
            let destURL = destinationFolder.appendingPathComponent(url.lastPathComponent)
            do {
                if url.standardizedFileURL != destURL.standardizedFileURL {
                    if fileManager.fileExists(atPath: destURL.path) {
                        try fileManager.removeItem(at: destURL)
                    }
                    try fileManager.copyItem(at: url, to: destURL)
                }
                let wallpaper = makeImportedWallpaper(from: destURL)
                WallpaperLibraryService.shared.recordDownload(wallpaper, fileURL: destURL)
                importedCount += 1
            } catch {
                print("[MyLibrary] Failed to import wallpaper \(url.lastPathComponent): \(error)")
            }
        }

        if importedCount > 0 {
            viewModel.objectWillChange.send()
        }
    }

    private func importMedia() async {
        DownloadPathManager.shared.createDirectoryStructure()
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.movie]
        panel.prompt = t("import")

        guard panel.runModal() == .OK else { return }

        let destinationFolder = DownloadPathManager.shared.mediaFolderURL
        let fileManager = FileManager.default
        var importedCount = 0

        for url in panel.urls {
            let destURL = destinationFolder.appendingPathComponent(url.lastPathComponent)
            do {
                if url.standardizedFileURL != destURL.standardizedFileURL {
                    if fileManager.fileExists(atPath: destURL.path) {
                        try fileManager.removeItem(at: destURL)
                    }
                    try fileManager.copyItem(at: url, to: destURL)
                }
                let item = await makeImportedMediaItem(from: destURL)
                MediaLibraryService.shared.recordDownload(item: item, localFileURL: destURL)
                importedCount += 1
            } catch {
                print("[MyLibrary] Failed to import media \(url.lastPathComponent): \(error)")
            }
        }

        if importedCount > 0 {
            mediaViewModel.objectWillChange.send()
        }
    }

    private func importWorkshop() {
        DownloadPathManager.shared.createDirectoryStructure()
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = t("import")

        guard panel.runModal() == .OK else { return }

        let destinationRoot = DownloadPathManager.shared.mediaFolderURL
        let fileManager = FileManager.default
        var importedCount = 0
        var skippedCount = 0

        // 递归查找目录树中的第一个 project.json（含 preview 同目录）
        func findProjectJSON(in dir: URL) -> (projectURL: URL, parentDir: URL)? {
            guard let enumerator = fileManager.enumerator(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
            for case let fileURL as URL in enumerator {
                if fileURL.lastPathComponent == "project.json" {
                    return (fileURL, fileURL.deletingLastPathComponent())
                }
            }
            return nil
        }

        // 在指定目录下递归查找预览图
        func findPreview(in dir: URL) -> URL? {
            guard let enumerator = fileManager.enumerator(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
            for case let fileURL as URL in enumerator {
                let name = fileURL.lastPathComponent.lowercased()
                if name == "preview.jpg" || name == "preview.jpeg" || name == "preview.png" || name == "preview.webp" || name == "preview.gif" {
                    return fileURL
                }
            }
            return nil
        }

        // 收集所有待导入的源目录（用户选文件夹→递归扫描子目录；选 .pkg→取上级目录）
        var sourceDirPaths: [String] = []
        for url in panel.urls {
            let path = url.path
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                // 批量模式：列出其下所有子目录，每个都尝试递归查找 project.json
                let subItems = (try? fileManager.contentsOfDirectory(atPath: path)) ?? []
                for name in subItems {
                    guard !name.hasPrefix(".") else { continue }
                    let subPath = (path as NSString).appendingPathComponent(name)
                    var subIsDir: ObjCBool = false
                    guard fileManager.fileExists(atPath: subPath, isDirectory: &subIsDir), subIsDir.boolValue else { continue }
                    sourceDirPaths.append(subPath)
                }
            } else if url.pathExtension.lowercased() == "pkg" {
                // 单文件模式：取 .pkg 所在目录
                sourceDirPaths.append(url.deletingLastPathComponent().path)
            }
        }

        // 去重
        sourceDirPaths = Array(Set(sourceDirPaths))

        for sourcePath in sourceDirPaths {
            let sourceURL = URL(fileURLWithPath: sourcePath)
            let sourceName = (sourcePath as NSString).lastPathComponent

            // 递归查找 project.json
            guard let found = findProjectJSON(in: sourceURL) else {
                print("[MyLibrary] No project.json found under \(sourceName)")
                skippedCount += 1
                continue
            }

            let projectJSONURL = found.projectURL

            guard let data = try? Data(contentsOf: projectJSONURL),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                print("[MyLibrary] Failed to parse project.json in \(sourceName)")
                skippedCount += 1
                continue
            }

            let title = (json["title"] as? String) ?? sourceName
            var workshopID = (json["publishedfileid"] as? String) ?? (json["id"] as? String)

            if workshopID == nil {
                let numeric = sourceName.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
                if !numeric.isEmpty { workshopID = numeric }
            }

            guard let id = workshopID, !id.isEmpty else {
                print("[MyLibrary] Could not infer workshop ID for \(sourceName)")
                skippedCount += 1
                continue
            }

            let destDir = destinationRoot.appendingPathComponent("workshop_\(id)")
            do {
                if fileManager.fileExists(atPath: destDir.path) {
                    try fileManager.removeItem(at: destDir)
                }
                // 复制整个 workshop 目录（保留 steamapps/... 深层结构）
                try fileManager.copyItem(at: sourceURL, to: destDir)

                // 在复制的目录中递归查找预览图
                let previewURL = findPreview(in: destDir)

                let item = makeImportedWorkshopItem(
                    workshopID: id,
                    title: title,
                    projectJSON: json,
                    destDir: destDir,
                    previewURL: previewURL
                )
                MediaLibraryService.shared.recordDownload(item: item, localFileURL: destDir)
                importedCount += 1
            } catch {
                print("[MyLibrary] Failed to import \(sourceName): \(error)")
                skippedCount += 1
            }
        }

        if importedCount > 0 {
            mediaViewModel.objectWillChange.send()
        }

        // 反馈
        let message: String
        if importedCount > 0 {
            message = String(format: t("import.workshop.result"), importedCount, skippedCount)
        } else {
            message = t("import.workshop.none")
        }
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = t("import")
            alert.informativeText = message
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    private func makeImportedWallpaper(from fileURL: URL) -> Wallpaper {
        let fileName = fileURL.lastPathComponent
        let id: String
        if fileName.hasPrefix("wallhaven-"), let dotIndex = fileName.firstIndex(of: ".") {
            let start = fileName.index(fileName.startIndex, offsetBy: 10)
            let extracted = String(fileName[start..<dotIndex])
            id = extracted.isEmpty ? "local_import_\(UUID().uuidString.prefix(8))" : extracted
        } else {
            id = "local_import_\(fileURL.deletingPathExtension().lastPathComponent)"
        }

        let localPath = fileURL.absoluteString
        var dimensionX = 1920
        var dimensionY = 1080
        if let imageSource = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any],
           let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
           let height = properties[kCGImagePropertyPixelHeight as String] as? Int {
            // 检查方向，可能需要交换宽高
            if let orientation = properties[kCGImagePropertyOrientation as String] as? UInt32,
               (5...8).contains(orientation) {
                dimensionX = height
                dimensionY = width
            } else {
                dimensionX = width
                dimensionY = height
            }
        }
        let resolution = "\(dimensionX)x\(dimensionY)"
        let ratio = dimensionY > 0 ? Double(dimensionX) / Double(dimensionY) : 1.77

        return Wallpaper(
            id: id,
            url: localPath,
            shortUrl: nil,
            views: 0,
            favorites: 0,
            downloads: nil,
            source: nil,
            purity: "sfw",
            category: "general",
            dimensionX: dimensionX,
            dimensionY: dimensionY,
            resolution: resolution,
            ratio: String(format: "%.2f", ratio),
            fileSize: nil,
            fileType: nil,
            createdAt: nil,
            colors: [],
            path: localPath,
            thumbs: Wallpaper.Thumbs(large: localPath, original: localPath, small: localPath),
            tags: nil,
            uploader: nil
        )
    }

    private func makeImportedMediaItem(from fileURL: URL) async -> MediaItem {
        let fileName = fileURL.lastPathComponent
        let slug: String
        if fileName.hasPrefix("motionbgs-") {
            let parts = fileName.split(separator: "-")
            if parts.count >= 2 {
                slug = String(parts[1])
            } else {
                slug = "local_import_\(fileURL.deletingPathExtension().lastPathComponent)"
            }
        } else {
            slug = "local_import_\(fileURL.deletingPathExtension().lastPathComponent)"
        }

        let title = fileURL.deletingPathExtension().lastPathComponent
        var resolutionLabel = "Unknown"
        var durationSeconds: Double?
        let asset = AVAsset(url: fileURL)
        do {
            let tracks = try await asset.loadTracks(withMediaType: .video)
            if let track = tracks.first {
                let naturalSize = try await track.load(.naturalSize)
                let preferredTransform = try await track.load(.preferredTransform)
                let size = naturalSize.applying(preferredTransform)
                let w = Int(abs(size.width))
                let h = Int(abs(size.height))
                resolutionLabel = "\(w)x\(h)"
            }
            let duration = try await asset.load(.duration)
            if duration.isValid && duration != CMTime.indefinite {
                durationSeconds = CMTimeGetSeconds(duration)
            }
        } catch {
            print("[MyLibrary] Failed to load video metadata: \(error)")
        }

        // 为导入的视频生成并缓存第一帧缩略图到缓存目录
        _ = await VideoThumbnailCache.shared.thumbnailImage(for: fileURL)
        let thumbnailURL = VideoThumbnailCache.shared.thumbnailURL(for: fileURL)

        return MediaItem(
            slug: slug,
            title: title,
            pageURL: fileURL,
            thumbnailURL: thumbnailURL,
            resolutionLabel: resolutionLabel,
            collectionTitle: "Imported",
            summary: nil,
            previewVideoURL: fileURL,
            posterURL: thumbnailURL,
            tags: [],
            exactResolution: resolutionLabel,
            durationSeconds: durationSeconds,
            downloadOptions: [],
            sourceName: "Import",
            isAnimatedImage: nil
        )
    }



    private func makeImportedWorkshopItem(
        workshopID: String,
        title: String,
        projectJSON: [String: Any],
        destDir: URL,
        previewURL: URL?
    ) -> MediaItem {
        let typeString = (projectJSON["type"] as? String) ?? "pkg"
        let resolutionLabel = typeString.capitalized
        let thumbnailURL = previewURL ?? URL(string: "https://steamcommunity.com/favicon.ico")!

        return MediaItem(
            slug: "workshop_\(workshopID)",
            title: title,
            pageURL: URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(workshopID)")!,
            thumbnailURL: thumbnailURL,
            resolutionLabel: resolutionLabel,
            collectionTitle: "Workshop",
            summary: (projectJSON["description"] as? String),
            previewVideoURL: nil,
            posterURL: previewURL,
            tags: [],
            exactResolution: nil,
            durationSeconds: nil,
            downloadOptions: [],
            sourceName: t("wallpaperEngine"),
            isAnimatedImage: nil
        )
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
        .pointingHandCursor()
    }
}

// MARK: - Anime Library Card
struct AnimeLibraryCard: View {
    let anime: AnimeSearchResult
    let isEditing: Bool
    let isSelected: Bool
    var cardWidth: CGFloat = LibraryCardMetrics.cardWidth
    let action: () -> Void

    @State private var isHovered = false

    private var thumbnailHeight: CGFloat {
        LibraryCardMetrics.thumbnailHeight + 72
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                // 图片区域 - 单独裁剪顶部圆角
                ZStack {
                    KFImage(URL(string: anime.coverURL ?? ""))
                        .setProcessor(DownsamplingImageProcessor(size: CGSize(width: 512, height: 512)))
                        .cacheMemoryOnly(false)
                        .fade(duration: 0.3)
                        .placeholder { _ in
                            SkeletonCard(
                                width: cardWidth,
                                height: thumbnailHeight,
                                cornerRadius: 0
                            )
                        }
                        .resizable()
                        .scaledToFill()
                        .frame(width: cardWidth, height: thumbnailHeight)
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
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }

                    // 右上角标签（非编辑模式下显示评分/排名）
                    if !isEditing {
                        VStack {
                            HStack {
                                Spacer()
                                
                                // 显示评分或排名标签
                                if let rating = anime.rating, let score = Double(rating), score > 0 {
                                    HStack(spacing: 4) {
                                        Image(systemName: "star.fill")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(.yellow)
                                        Text(String(format: "%.1f", score))
                                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                                            .foregroundStyle(.white.opacity(0.95))
                                    }
                                    .padding(.horizontal, 10)
                                    .frame(height: 24)
                                    .background(
                                        Capsule(style: .continuous)
                                            .fill(Color.black.opacity(0.45))
                                    )
                                    .padding(12)
                                } else if let rank = anime.rank {
                                    Text("#\(rank)")
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                        .foregroundStyle(.white.opacity(0.95))
                                        .padding(.horizontal, 10)
                                        .frame(height: 24)
                                        .background(
                                            Capsule(style: .continuous)
                                                .fill(Color.black.opacity(0.45))
                                        )
                                    .padding(12)
                                }
                            }
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    }

                    // 选中时的遮罩 - 确保填满整个图片区域
                    if isEditing && isSelected {
                        Color.black.opacity(0.3)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }

                // 信息区域
                VStack(alignment: .leading, spacing: 6) {
                    Text(anime.title)
                        .font(.system(size: 14.5, weight: .bold))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)

                    if let tags = anime.tags, !tags.isEmpty {
                        Text(tags.prefix(3).map { $0.name }.joined(separator: ", "))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.56))
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(width: cardWidth, alignment: .leading)
            }
            .frame(width: cardWidth, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color(hex: "1A1D24").opacity(0.6))
            )
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.white.opacity(isHovered ? 0.18 : 0.08), lineWidth: isHovered ? 1.5 : 1)
            )
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

// MARK: - AnyWallpaperItem (统一封装用于 ForEach)
private struct AnyWallpaperItem: Identifiable {
    let id: String
    let wallpaper: Wallpaper
    let localFileURL: URL?
    let downloadDate: Date?

    init(wallpaper: Wallpaper) {
        self.id = wallpaper.id
        self.wallpaper = wallpaper
        self.localFileURL = nil
        self.downloadDate = nil
    }

    init(unified: UnifiedLocalWallpaper) {
        self.id = unified.id
        self.wallpaper = unified.wallpaper
        self.localFileURL = unified.fileURL
        self.downloadDate = unified.downloadRecord?.downloadedAt
    }
}

// MARK: - AnyMediaItem (统一封装用于 ForEach)
private struct AnyMediaItem: Identifiable {
    let id: String
    let mediaItem: MediaItem
    let localFileURL: URL?
    private let unifiedLocalMedia: UnifiedLocalMedia?

    init(mediaItem: MediaItem, localFileURL: URL? = nil) {
        self.id = mediaItem.id
        self.mediaItem = mediaItem
        self.localFileURL = localFileURL
        self.unifiedLocalMedia = nil
    }

    init(unified: UnifiedLocalMedia) {
        self.id = unified.id
        self.mediaItem = unified.mediaItem
        self.localFileURL = unified.fileURL
        self.unifiedLocalMedia = unified
    }

    /// 是否为竖屏；优先使用 UnifiedLocalMedia 的解析（包含烘焙产物信息），其次 MediaItem
    var isPortrait: Bool? {
        unifiedLocalMedia?.isPortrait ?? mediaItem.isPortrait
    }

    /// 解析后的视频文件 URL：优先烘焙产物，其次目录内视频文件
    var resolvedVideoFileURL: URL? {
        unifiedLocalMedia?.downloadRecord?.resolvedVideoFileURL ?? localFileURL
    }
}

// MARK: - Cursor Extension
private extension View {
    func pointingHandCursor() -> some View {
        self.onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}
