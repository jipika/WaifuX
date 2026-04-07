import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var viewModel = WallpaperViewModel()
    @StateObject private var mediaViewModel = MediaExploreViewModel()
    @StateObject private var downloadTaskViewModel = DownloadTaskViewModel()
    @StateObject private var localization = LocalizationService.shared
    @State private var selectedTab: MainTab = .home
    @State private var selectedWallpaper: Wallpaper?
    @State private var selectedMedia: MediaItem?
    @State private var selectedAnime: AnimeSearchResult?
    @State private var librarySelectedAnime: AnimeSearchResult?
    @State private var librarySelectedWallpaper: Wallpaper?
    @State private var librarySelectedMedia: MediaItem?

    var body: some View {
        ZStack {
            Color(hex: "0D0D0D")
                .ignoresSafeArea()

            // 全局颗粒材质覆盖层
            GrainTextureOverlay()
                .ignoresSafeArea()
                .zIndex(0)

            // Tab 缓存 - 使用 opacity 保持视图存活，避免重新渲染
            ZStack {
                // Home Tab
                HomeContentView(
                    viewModel: viewModel,
                    mediaViewModel: mediaViewModel,
                    selectedWallpaper: $selectedWallpaper,
                    selectedMedia: $selectedMedia
                )
                .opacity(selectedTab == .home ? 1 : 0)
                .allowsHitTesting(selectedTab == .home)
                
                // Wallpaper Explore Tab
                WallpaperExploreContentView(viewModel: viewModel, selectedWallpaper: $selectedWallpaper)
                    .opacity(selectedTab == .wallpaperExplore ? 1 : 0)
                    .allowsHitTesting(selectedTab == .wallpaperExplore)
                
                // Anime Explore Tab
                AnimeExploreView(selectedAnime: $selectedAnime)
                    .opacity(selectedTab == .animeExplore ? 1 : 0)
                    .allowsHitTesting(selectedTab == .animeExplore)
                
                // Media Explore Tab
                MediaExploreContentView(viewModel: mediaViewModel, selectedMedia: $selectedMedia)
                    .opacity(selectedTab == .mediaExplore ? 1 : 0)
                    .allowsHitTesting(selectedTab == .mediaExplore)
                
                // My Media Tab
                MyLibraryContentView(
                    selectedWallpaper: $librarySelectedWallpaper,
                    selectedMedia: $librarySelectedMedia,
                    selectedAnime: $librarySelectedAnime
                )
                    .opacity(selectedTab == .myMedia ? 1 : 0)
                    .allowsHitTesting(selectedTab == .myMedia)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .id(localization.currentLanguage)

            VStack {
                TopNavigationBar(
                    selectedTab: $selectedTab,
                    onOpenSettings: { openSettingsWindow() },
                    onClose: { hideMainWindow() },
                    onMinimize: { minimizeWindow() },
                    onMaximize: { maximizeWindow() }
                )
                .zIndex(100)

                Spacer()
            }

            if let wallpaper = selectedWallpaper {
                WallpaperDetailSheet(wallpaper: wallpaper, viewModel: viewModel) {
                    selectedWallpaper = nil
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.asymmetric(
                    insertion: .opacity.animation(.easeOut(duration: 0.18)),
                    removal: .opacity.animation(.easeIn(duration: 0.12))
                ))
                .zIndex(300)
            }

            if let item = selectedMedia {
                MediaDetailSheet(item: item, viewModel: mediaViewModel) {
                    selectedMedia = nil
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.asymmetric(
                    insertion: .opacity.animation(.easeOut(duration: 0.18)),
                    removal: .opacity.animation(.easeIn(duration: 0.12))
                ))
                .zIndex(300)
            }

            if let anime = selectedAnime {
                AnimeDetailSheet(anime: anime, selectedAnime: $selectedAnime)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.asymmetric(
                        insertion: .opacity.animation(.easeOut(duration: 0.18)),
                        removal: .opacity.animation(.easeIn(duration: 0.12))
                    ))
                    .zIndex(500)
            }
            
            // 我的库中的详情页（在 ContentView 层级显示，确保覆盖 TopNavigationBar）
            if let wallpaper = librarySelectedWallpaper {
                WallpaperDetailSheet(wallpaper: wallpaper, viewModel: viewModel) {
                    librarySelectedWallpaper = nil
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.asymmetric(
                    insertion: .opacity.animation(.easeOut(duration: 0.18)),
                    removal: .opacity.animation(.easeIn(duration: 0.12))
                ))
                .zIndex(300)
            }
            
            if let item = librarySelectedMedia {
                MediaDetailSheet(item: item, viewModel: mediaViewModel) {
                    librarySelectedMedia = nil
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.asymmetric(
                    insertion: .opacity.animation(.easeOut(duration: 0.18)),
                    removal: .opacity.animation(.easeIn(duration: 0.12))
                ))
                .zIndex(300)
            }
            
            if let anime = librarySelectedAnime {
                AnimeDetailSheet(anime: anime, selectedAnime: $librarySelectedAnime)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
                    .transition(.asymmetric(
                        insertion: .opacity.animation(.easeOut(duration: 0.18)),
                        removal: .opacity.animation(.easeIn(duration: 0.12))
                    ))
                    .zIndex(500)
            }

            DownloadProgressToastHost(viewModel: downloadTaskViewModel)
                .padding(.horizontal, 24)
                .zIndex(400)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await viewModel.initialLoad()
        }
        .ignoresSafeArea()
        .applyTheme()
    }

    private func minimizeWindow() {
        NSApp.mainWindow?.miniaturize(nil)
    }

    private func maximizeWindow() {
        guard let window = NSApp.mainWindow else { return }
        if window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        } else {
            window.zoom(nil)
        }
    }

    private func openSettingsWindow() {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return }
        appDelegate.showSettingsWindow(nil)
    }

    private func hideMainWindow() {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return }
        appDelegate.hideMainWindow()
    }
}

struct MyMediaContentView: View {
    @ObservedObject var viewModel: WallpaperViewModel
    @ObservedObject var mediaViewModel: MediaExploreViewModel
    @ObservedObject var downloadTaskViewModel: DownloadTaskViewModel
    @Binding var selectedWallpaper: Wallpaper?
    @Binding var selectedMedia: MediaItem?

    // 编辑状态
    @State private var isEditing = false
    @State private var editingSection: EditingSection = .mediaFavorites
    @State private var selectedItems = Set<String>()

    enum EditingSection: String, CaseIterable {
        case wallpaperFavorites = "wallpaperFavorites"
        case wallpaperDownloads = "wallpaperDownloads"
        case mediaFavorites = "mediaFavorites"
        case mediaDownloads = "mediaDownloads"
        case history = "history"
    }

    private var activeWallpaperTasks: [DownloadTask] {
        downloadTaskViewModel.wallpaperTasks.filter { $0.wallpaper != nil }
    }

    private var activeMediaTasks: [DownloadTask] {
        downloadTaskViewModel.mediaTasks.filter { $0.mediaItem != nil }
    }

    private var completedWallpaperDownloads: [WallpaperDownloadRecord] {
        let activeIDs = Set(activeWallpaperTasks.map(\.itemID))
        return viewModel.downloadedWallpapers.filter { !activeIDs.contains($0.wallpaper.id) }
    }

    private var completedMediaDownloads: [MediaDownloadRecord] {
        let activeIDs = Set(activeMediaTasks.map(\.itemID))
        return mediaViewModel.downloadedItems.filter { !activeIDs.contains($0.item.id) }
    }

    private var wallpaperDownloadCount: Int {
        activeWallpaperTasks.count + completedWallpaperDownloads.count
    }

    private var mediaDownloadCount: Int {
        activeMediaTasks.count + completedMediaDownloads.count
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
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
                    mediaHero
                    wallpaperFavoritesSection
                    wallpaperDownloadsSection
                    mediaFavoritesSection
                    mediaDownloadsSection
                    historySection
                }
                .padding(.horizontal, 28)
                .padding(.top, 112)
                .padding(.bottom, 48)
                // 内层限制内容最大宽度；外层拉满宽度，避免 ScrollView 随 1520 收缩导致两侧露出主窗口底色
                .frame(maxWidth: 1520, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollClipDisabled()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var mediaHero: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(t("my.media.library"))
                        .font(.system(size: 42, weight: .bold, design: .serif))
                        .foregroundStyle(.white.opacity(0.96))

                    Text(t("my.media.subtitle"))
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }

                Spacer()

                SettingsStatusBadge(
                    title: "\(viewModel.favorites.count + mediaViewModel.favoriteItems.count) \(t("items.favorites"))",
                    systemImage: "heart.fill",
                    color: LiquidGlassColors.primaryPink
                )
            }
        }
    }

    private var wallpaperFavoritesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeaderWithEdit(
                title: t("wallpaper.favorites"),
                systemImage: "heart.fill",
                color: LiquidGlassColors.primaryPink,
                countText: "\(viewModel.favorites.count) \(t("items"))",
                section: .wallpaperFavorites
            )

            if viewModel.favorites.isEmpty {
                emptyMediaSurface(
                    title: t("no.wallpaper.favorites"),
                    subtitle: t("no.wallpaper.favorites.hint"),
                    icon: "heart.slash",
                    accent: LiquidGlassColors.primaryPink
                )
            } else {
                batchDeleteToolbar(section: .wallpaperFavorites, count: viewModel.favorites.count)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 18) {
                        ForEach(viewModel.favorites) { wallpaper in
                            WallpaperEditCard(
                                wallpaper: wallpaper,
                                isEditing: isEditing && editingSection == .wallpaperFavorites,
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
    }

    private var mediaFavoritesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeaderWithEdit(
                title: t("media.favorites"),
                systemImage: "play.rectangle.fill",
                color: LiquidGlassColors.accentCyan,
                countText: "\(mediaViewModel.favoriteItems.count) \(t("items"))",
                section: .mediaFavorites
            )

            if mediaViewModel.favoriteItems.isEmpty {
                emptyMediaSurface(
                    title: t("no.media.favorites"),
                    subtitle: t("no.media.favorites.hint"),
                    icon: "play.slash",
                    accent: LiquidGlassColors.accentCyan
                )
            } else {
                batchDeleteToolbar(section: .mediaFavorites, count: mediaViewModel.favoriteItems.count)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 18) {
                        ForEach(mediaViewModel.favoriteItems) { item in
                            MyMediaVideoCard(
                                item: item,
                                badgeText: t("badge.favorite"),
                                accent: LiquidGlassColors.accentCyan,
                                isEditing: isEditing && editingSection == .mediaFavorites,
                                isSelected: selectedItems.contains(item.id)
                            ) {
                                handleItemTap(item)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var wallpaperDownloadsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeaderWithEdit(
                title: t("wallpaper.downloads"),
                systemImage: "arrow.down.circle.fill",
                color: LiquidGlassColors.tertiaryBlue,
                countText: "\(wallpaperDownloadCount) \(t("items"))",
                section: .wallpaperDownloads
            )

            if wallpaperDownloadCount == 0 {
                emptyMediaSurface(
                    title: t("no.wallpaper.downloads"),
                    subtitle: t("no.wallpaper.downloads.hint"),
                    icon: "arrow.down.circle",
                    accent: LiquidGlassColors.tertiaryBlue
                )
            } else {
                batchDeleteToolbar(section: .wallpaperDownloads, count: wallpaperDownloadCount)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 18) {
                        ForEach(activeWallpaperTasks) { task in
                            if let wallpaper = task.wallpaper {
                                WallpaperEditCard(
                                    wallpaper: wallpaper,
                                    accent: LiquidGlassColors.tertiaryBlue,
                                    isEditing: isEditing && editingSection == .wallpaperDownloads,
                                    isSelected: selectedItems.contains(task.itemID),
                                    progress: task.progress,
                                    progressTint: downloadStatusColor(for: task.status),
                                    progressLabel: downloadStatusText(for: task.status)
                                ) {
                                    handleWallpaperDownloadTaskTap(task)
                                }
                            }
                        }

                        ForEach(completedWallpaperDownloads) { record in
                            WallpaperEditCard(
                                wallpaper: record.wallpaper,
                                accent: LiquidGlassColors.tertiaryBlue,
                                isEditing: isEditing && editingSection == .wallpaperDownloads,
                                isSelected: selectedItems.contains(record.wallpaper.id)
                            ) {
                                handleWallpaperDownloadTap(record)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var mediaDownloadsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeaderWithEdit(
                title: t("media.downloads"),
                systemImage: "arrow.down.circle.fill",
                color: LiquidGlassColors.tertiaryBlue,
                countText: "\(mediaDownloadCount) \(t("items"))",
                section: .mediaDownloads
            )

            if mediaDownloadCount == 0 {
                emptyMediaSurface(
                    title: t("no.media.downloads"),
                    subtitle: t("no.media.downloads.hint"),
                    icon: "arrow.down.circle",
                    accent: LiquidGlassColors.tertiaryBlue
                )
            } else {
                batchDeleteToolbar(section: .mediaDownloads, count: mediaDownloadCount)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 18) {
                        ForEach(activeMediaTasks) { task in
                            if let item = task.mediaItem {
                                MyMediaVideoCard(
                                    item: item,
                                    badgeText: task.badgeText,
                                    accent: LiquidGlassColors.tertiaryBlue,
                                    isEditing: isEditing && editingSection == .mediaDownloads,
                                    isSelected: selectedItems.contains(task.itemID),
                                    progress: task.progress,
                                    progressTint: downloadStatusColor(for: task.status),
                                    progressLabel: downloadStatusText(for: task.status)
                                ) {
                                    handleMediaDownloadTaskTap(task)
                                }
                            }
                        }

                        ForEach(completedMediaDownloads) { record in
                            MyMediaVideoCard(
                                item: record.item,
                                badgeText: record.item.resolutionLabel,
                                accent: LiquidGlassColors.tertiaryBlue,
                                isEditing: isEditing && editingSection == .mediaDownloads,
                                isSelected: selectedItems.contains(record.item.id)
                            ) {
                                handleDownloadItemTap(record)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeaderWithEdit(
                title: t("browse.history"),
                systemImage: "clock.fill",
                color: LiquidGlassColors.warningOrange,
                countText: "\(mediaViewModel.recentItems.count) \(t("items"))",
                section: .history
            )

            if mediaViewModel.recentItems.isEmpty {
                emptyMediaSurface(
                    title: t("no.history"),
                    subtitle: t("no.history.hint"),
                    icon: "clock.arrow.circlepath",
                    accent: LiquidGlassColors.warningOrange
                )
            } else {
                batchDeleteToolbar(section: .history, count: mediaViewModel.recentItems.count)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 18) {
                        ForEach(mediaViewModel.recentItems) { item in
                            MyMediaVideoCard(
                                item: item,
                                badgeText: t("badge.recent"),
                                accent: LiquidGlassColors.warningOrange,
                                isEditing: isEditing && editingSection == .history,
                                isSelected: selectedItems.contains(item.id)
                            ) {
                                handleHistoryItemTap(item)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: - 编辑相关方法

    private func sectionHeaderWithEdit(title: String, systemImage: String, color: Color, countText: String, section: EditingSection) -> some View {
        HStack {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(color)

            Text(title)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)

            Spacer()

            Text(countText)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.52))

            // 编辑按钮
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                    if isEditing && editingSection == section {
                        isEditing = false
                        selectedItems.removeAll()
                    } else {
                        editingSection = section
                        isEditing = true
                        selectedItems.removeAll()
                    }
                }
            } label: {
                Text(isEditing && editingSection == section ? t("done") : t("edit"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .liquidGlassSurface(
                        .regular,
                        tint: isEditing && editingSection == section ? color.opacity(0.2) : color.opacity(0.1),
                        in: Capsule(style: .continuous)
                    )
            }
            .buttonStyle(.plain)
            .contentShape(Capsule(style: .continuous))
        }
    }

    private func batchDeleteToolbar(section: EditingSection, count: Int) -> some View {
        Group {
            if isEditing && editingSection == section {
                HStack {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) {
                            let itemCount = sectionItemCount(section: section)
                            if selectedItems.count == itemCount {
                                selectedItems.removeAll()
                            } else {
                                let ids = sectionItemIDs(section: section)
                                selectedItems = Set(ids)
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: selectedItems.count == count ? "checkmark.square.fill" : "square")
                                .font(.system(size: 14, weight: .semibold))
                            Text(selectedItems.count == count ? t("deselectAll") : t("selectAll"))
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(.white.opacity(0.8))
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    if !selectedItems.isEmpty {
                        Text("\(t("selected")) \(selectedItems.count) \(t("items"))")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                    }

                    Spacer()

                    Button {
                        deleteSelectedItems(section: section)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "trash.fill")
                                .font(.system(size: 12, weight: .semibold))
                            Text(t("delete"))
                                .font(.system(size: 13, weight: .semibold))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.white.opacity(0.05))
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
    }

    func currentSectionItems(section: EditingSection) -> [Any] {
        switch section {
        case .wallpaperFavorites:
            return viewModel.favorites
        case .wallpaperDownloads:
            return viewModel.downloadedWallpapers
        case .mediaFavorites:
            return mediaViewModel.favoriteItems
        case .mediaDownloads:
            return mediaViewModel.downloadedItems.map(\.item)
        case .history:
            return mediaViewModel.recentItems
        }
    }

    func sectionItemCount(section: EditingSection) -> Int {
        switch section {
        case .wallpaperFavorites:
            return viewModel.favorites.count
        case .wallpaperDownloads:
            return wallpaperDownloadCount
        case .mediaFavorites:
            return mediaViewModel.favoriteItems.count
        case .mediaDownloads:
            return mediaDownloadCount
        case .history:
            return mediaViewModel.recentItems.count
        }
    }

    func sectionItemIDs(section: EditingSection) -> [String] {
        switch section {
        case .wallpaperFavorites:
            return viewModel.favorites.map(\.id)
        case .wallpaperDownloads:
            return activeWallpaperTasks.map(\.itemID) + completedWallpaperDownloads.map(\.wallpaper.id)
        case .mediaFavorites:
            return mediaViewModel.favoriteItems.map(\.id)
        case .mediaDownloads:
            return activeMediaTasks.map(\.itemID) + completedMediaDownloads.map(\.item.id)
        case .history:
            return mediaViewModel.recentItems.map(\.id)
        }
    }

    private func handleItemTap(_ item: MediaItem) {
        if isEditing && editingSection == .mediaFavorites {
            withAnimation(.easeOut(duration: 0.15)) {
                if selectedItems.contains(item.id) {
                    selectedItems.remove(item.id)
                } else {
                    selectedItems.insert(item.id)
                }
            }
        } else {
            selectedMedia = item
        }
    }

    private func handleWallpaperTap(_ wallpaper: Wallpaper) {
        if isEditing && editingSection == .wallpaperFavorites {
            withAnimation(.easeOut(duration: 0.15)) {
                if selectedItems.contains(wallpaper.id) {
                    selectedItems.remove(wallpaper.id)
                } else {
                    selectedItems.insert(wallpaper.id)
                }
            }
        } else {
            selectedWallpaper = wallpaper
        }
    }

    private func handleWallpaperDownloadTap(_ record: WallpaperDownloadRecord) {
        if isEditing && editingSection == .wallpaperDownloads {
            withAnimation(.easeOut(duration: 0.15)) {
                if selectedItems.contains(record.wallpaper.id) {
                    selectedItems.remove(record.wallpaper.id)
                } else {
                    selectedItems.insert(record.wallpaper.id)
                }
            }
        } else {
            selectedWallpaper = record.wallpaper
        }
    }

    private func handleWallpaperDownloadTaskTap(_ task: DownloadTask) {
        guard let wallpaper = task.wallpaper else { return }
        if isEditing && editingSection == .wallpaperDownloads {
            withAnimation(.easeOut(duration: 0.15)) {
                if selectedItems.contains(task.itemID) {
                    selectedItems.remove(task.itemID)
                } else {
                    selectedItems.insert(task.itemID)
                }
            }
        } else {
            selectedWallpaper = wallpaper
        }
    }

    private func handleDownloadItemTap(_ record: MediaDownloadRecord) {
        if isEditing && editingSection == .mediaDownloads {
            withAnimation(.easeOut(duration: 0.15)) {
                if selectedItems.contains(record.item.id) {
                    selectedItems.remove(record.item.id)
                } else {
                    selectedItems.insert(record.item.id)
                }
            }
        } else {
            selectedMedia = record.item
        }
    }

    private func handleMediaDownloadTaskTap(_ task: DownloadTask) {
        guard let item = task.mediaItem else { return }
        if isEditing && editingSection == .mediaDownloads {
            withAnimation(.easeOut(duration: 0.15)) {
                if selectedItems.contains(task.itemID) {
                    selectedItems.remove(task.itemID)
                } else {
                    selectedItems.insert(task.itemID)
                }
            }
        } else {
            selectedMedia = item
        }
    }

    private func handleHistoryItemTap(_ item: MediaItem) {
        if isEditing && editingSection == .history {
            withAnimation(.easeOut(duration: 0.15)) {
                if selectedItems.contains(item.id) {
                    selectedItems.remove(item.id)
                } else {
                    selectedItems.insert(item.id)
                }
            }
        } else {
            selectedMedia = item
        }
    }

    private func deleteSelectedItems(section: EditingSection) {
        guard !selectedItems.isEmpty else { return }

        let mediaLibrary = MediaLibraryService.shared

        switch section {
        case .wallpaperFavorites:
            viewModel.removeWallpaperFavorites(withIDs: selectedItems)
        case .wallpaperDownloads:
            for task in activeWallpaperTasks where selectedItems.contains(task.itemID) {
                downloadTaskViewModel.cancelTask(task)
                downloadTaskViewModel.removeTask(task)
            }
            viewModel.removeWallpaperDownloads(withIDs: selectedItems)
        case .mediaFavorites:
            // 从收藏中删除
            for id in selectedItems {
                if let item = mediaViewModel.favoriteItems.first(where: { $0.id == id }) {
                    mediaLibrary.toggleFavorite(item)
                }
            }
        case .mediaDownloads:
            // 从下载记录中删除
            for task in activeMediaTasks where selectedItems.contains(task.itemID) {
                downloadTaskViewModel.cancelTask(task)
                downloadTaskViewModel.removeTask(task)
            }
            for id in selectedItems {
                mediaLibrary.removeDownloadRecord(withID: id)
            }
        case .history:
            // 从历史记录中删除
            mediaViewModel.removeRecentItems(withIDs: selectedItems)
        }

        selectedItems.removeAll()
        withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
            isEditing = false
        }
    }

    private func downloadStatusText(for status: DownloadStatus) -> String {
        switch status {
        case .pending:
            return t("status.pending")
        case .downloading:
            return t("status.downloading")
        case .paused:
            return t("status.paused")
        case .completed:
            return t("status.completed")
        case .failed:
            return t("status.failed")
        case .cancelled:
            return t("status.cancelled")
        }
    }

    private func downloadStatusColor(for status: DownloadStatus) -> Color {
        switch status {
        case .pending:
            return Color.white.opacity(0.6)
        case .downloading:
            // 深色液态玻璃风格
            return Color.white.opacity(0.85)
        case .paused:
            return Color.white.opacity(0.6)
        case .completed:
            return LiquidGlassColors.onlineGreen
        case .failed:
            return Color.white.opacity(0.7)
        case .cancelled:
            return Color.white.opacity(0.5)
        }
    }

    private func sectionHeader(title: String, systemImage: String, color: Color, countText: String) -> some View {
        HStack {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(color)

            Text(title)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)

            Spacer()

            Text(countText)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.52))
        }
    }

    private func emptyMediaSurface(title: String, subtitle: String, icon: String, accent: Color) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(accent)

            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))

            Text(subtitle)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.56))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 160)
        .liquidGlassSurface(
            .prominent,
            tint: accent.opacity(0.12),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
    }
}

private struct MyMediaVideoCard: View {
    let item: MediaItem
    let badgeText: String
    let accent: Color
    let isEditing: Bool
    let isSelected: Bool
    var progress: Double? = nil
    var progressTint: Color? = nil
    var progressLabel: String? = nil
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    OptimizedAsyncImage(url: item.thumbnailURL, priority: .low) { image in
                        image
                            .resizable()
                            .scaledToFill()
                    } placeholder: {
                        SkeletonCard(
                            width: LibraryCardMetrics.cardWidth,
                            height: LibraryCardMetrics.thumbnailHeight,
                            cornerRadius: 0
                        )
                    }
                    .frame(
                        width: LibraryCardMetrics.cardWidth,
                        height: LibraryCardMetrics.thumbnailHeight
                    )
                    .clipped()

                    // 左上角复选框（编辑模式下显示）
                    if isEditing {
                        VStack {
                            HStack {
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 22, weight: .semibold))
                                    .foregroundStyle(isSelected ? accent : .white.opacity(0.8))
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

                    // 右上角标签（非编辑模式下显示）
                    if !isEditing {
                        Text(badgeText)
                            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.82))
                            .padding(.horizontal, 10)
                            .frame(height: 22)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color.black.opacity(0.3))
                            )
                            .padding(12)
                    }

                    // 选中时的遮罩
                    if isEditing && isSelected {
                        Color.black.opacity(0.3)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 14.5, weight: .bold))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(2)

                    Text(item.subtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.56))
                        .lineLimit(1)

                    // 未完成时显示进度块
                    if let progress, progress < 1.0 {
                        DownloadCardProgressBlock(
                            progress: progress,
                            label: progressLabel ?? t("status.downloading"),
                            tint: progressTint ?? accent
                        )
                        .padding(.top, 6)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .frame(width: LibraryCardMetrics.cardWidth, alignment: .leading)
            .liquidGlassSurface(
                isHovered ? .max : .prominent,
                tint: accent.opacity(0.12),
                in: RoundedRectangle(cornerRadius: 22, style: .continuous)
            )
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .scaleEffect(isHovered ? 1.01 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if !isEditing {
                withAnimation(.easeOut(duration: 0.16)) {
                    isHovered = hovering
                }
            }
        }
    }
}

private struct DownloadProgressToastHost: View {
    @ObservedObject var viewModel: DownloadTaskViewModel

    @State private var displayedTaskID: String?
    @State private var hideWorkItem: DispatchWorkItem?

    private var displayedTask: DownloadTask? {
        viewModel.tasks.first(where: { $0.id == displayedTaskID })
    }

    var body: some View {
        VStack {
            Spacer()

            if let task = displayedTask {
                DownloadProgressToast(
                    task: task,
                    activeTaskCount: viewModel.tasks.filter(\.isRunning).count
                )
                .padding(.bottom, 26)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .allowsHitTesting(false)
        .onAppear {
            reconcileDisplayedTask(with: viewModel.tasks)
        }
        .onReceive(viewModel.$tasks) { tasks in
            reconcileDisplayedTask(with: tasks)
        }
    }

    private func reconcileDisplayedTask(with tasks: [DownloadTask]) {
        hideWorkItem?.cancel()

        if let activeTask = tasks
            .filter(\.isRunning)
            .max(by: { $0.lastUpdatedAt < $1.lastUpdatedAt })
        {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                displayedTaskID = activeTask.id
            }
            return
        }

        if let recentTerminalTask = tasks
            .filter({ task in
                guard task.isTerminal else { return false }
                let referenceDate = task.completedAt ?? task.lastUpdatedAt
                return Date().timeIntervalSince(referenceDate) < 1.8
            })
            .max(by: { $0.lastUpdatedAt < $1.lastUpdatedAt })
        {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                displayedTaskID = recentTerminalTask.id
            }

            let workItem = DispatchWorkItem {
                withAnimation(.easeOut(duration: 0.2)) {
                    if displayedTaskID == recentTerminalTask.id {
                        displayedTaskID = nil
                    }
                }
            }
            hideWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: workItem)
            return
        }

        withAnimation(.easeOut(duration: 0.18)) {
            displayedTaskID = nil
        }
    }
}

private struct DownloadProgressToast: View {
    let task: DownloadTask
    let activeTaskCount: Int

    private var tint: Color {
        switch task.status {
        case .pending:
            return Color.white.opacity(0.7)
        case .downloading:
            // 深色液态玻璃风格 - 使用白色/灰色作为主色调
            return Color.white.opacity(0.85)
        case .paused:
            return Color.white.opacity(0.6)
        case .completed:
            // 完成时用绿色
            return LiquidGlassColors.onlineGreen
        case .failed:
            // 失败时也用灰色，不使用红色
            return Color.white.opacity(0.7)
        case .cancelled:
            return Color.white.opacity(0.5)
        }
    }

    private var iconName: String {
        switch task.kind {
        case .wallpaper:
            return "photo.fill"
        case .media:
            return "play.rectangle.fill"
        }
    }

    private var statusText: String {
        switch task.status {
        case .pending:
            return t("status.pending")
        case .downloading:
            return t("status.downloading")
        case .paused:
            return t("status.paused")
        case .completed:
            return t("status.completed")
        case .failed:
            return t("status.failed")
        case .cancelled:
            return t("status.cancelled")
        }
    }

    private var subtitle: String {
        if activeTaskCount > 1 && task.isRunning {
            if task.subtitle.isEmpty {
                return "\(activeTaskCount) \(t("items"))"
            }
            return "\(task.subtitle) · \(activeTaskCount) \(t("items"))"
        }
        if task.subtitle.isEmpty {
            return task.badgeText
        }
        if task.badgeText.isEmpty {
            return task.subtitle
        }
        return "\(task.subtitle) · \(task.badgeText)"
    }

    private var isCompleted: Bool {
        task.status == .completed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: iconName)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                    .background(
                        // 使用真正的深色液态玻璃
                        DarkLiquidGlassBackground(
                            cornerRadius: 17,
                            isHovered: false
                        )
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text(task.title)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white.opacity(0.94))
                        .lineLimit(1)

                    Text(subtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                // 未完成时显示状态标签
                if !isCompleted {
                    Text(statusText)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(
                            // 状态标签使用 subtle 级别的深色玻璃
                            DarkLiquidGlassBackground(
                                cornerRadius: 12,
                                isHovered: false
                            )
                            .opacity(0.7)
                        )
                }
            }

            // 未完成时显示进度条
            if !isCompleted {
                LiquidGlassLinearProgressBar(
                    progress: task.progress,
                    height: 6,
                    tintColor: tint,
                    trackOpacity: 0.15
                )

                HStack {
                    Text(task.kind == .wallpaper ? t("wallpaper.downloads") : t("media.downloads"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))

                    Spacer()

                    Text("\(Int((max(0, min(task.progress, 1)) * 100).rounded()))%")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.86))
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: 440)
        .background(
            // 主容器使用真正的深色液态玻璃
            DarkLiquidGlassBackground(
                cornerRadius: 24,
                isHovered: false
            )
        )
    }
}
