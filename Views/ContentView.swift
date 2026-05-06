import SwiftUI
import AppKit
import Kingfisher
import AVFoundation

struct ContentView: View {
    @StateObject private var viewModel = WallpaperViewModel()
    @StateObject private var mediaViewModel = MediaExploreViewModel()
    @StateObject private var animeViewModel = AnimeViewModel()
    @StateObject private var downloadTaskViewModel = DownloadTaskViewModel()
    @ObservedObject private var localization = LocalizationService.shared
    @ObservedObject private var sourceManager = WallpaperSourceManager.shared
    @State private var selectedTab: MainTab = .home
    @State private var selectedWallpaper: Wallpaper?
    @State private var selectedMedia: MediaItem?
    @State private var selectedAnime: AnimeSearchResult?
    @State private var librarySelectedAnime: AnimeSearchResult?
    @State private var librarySelectedWallpaper: Wallpaper?
    @State private var librarySelectedMedia: MediaItem?
    @State private var libraryWallpaperContext: [Wallpaper] = []
    @State private var libraryMediaContext: [MediaItem] = []
    /// 类似 Vue `keep-alive`：除「我的库」外，Tab 至少访问过一次后保留子树；非当前页仅隐藏并暂停滚动/GIF
    @State private var mountedTabs: Set<MainTab> = [.home]

    // 更新弹窗状态
    @State private var showUpdateSheet = false
    @State private var updateRelease: GitHubRelease?
    @State private var updateCommit: GitHubCommit?

    var body: some View {
        ZStack {
            Color(hex: "0D0D0D")
                .ignoresSafeArea()

            // Tab：keep-alive（不含我的库）；非当前页 opacity 0 + 不响应点击；`coverGIFPlaybackHostActive` 停后台 GIF
            ZStack {
                if mountedTabs.contains(.home) {
                    HomeContentView(
                        viewModel: viewModel,
                        mediaViewModel: mediaViewModel,
                        selectedWallpaper: $selectedWallpaper,
                        selectedMedia: $selectedMedia,
                        isTabActive: selectedTab == .home
                    )
                    .environment(\.coverGIFPlaybackHostActive, selectedTab == .home)
                    .opacity(selectedTab == .home ? 1 : 0)
                    .zIndex(selectedTab == .home ? 1 : 0)
                    .allowsHitTesting(selectedTab == .home)
                }

                if mountedTabs.contains(.wallpaperExplore) {
                    WallpaperExploreContentView(
                        viewModel: viewModel,
                        selectedWallpaper: $selectedWallpaper,
                        isVisible: selectedTab == .wallpaperExplore
                    )
                    .environment(\.coverGIFPlaybackHostActive, selectedTab == .wallpaperExplore)
                    .opacity(selectedTab == .wallpaperExplore ? 1 : 0)
                    .zIndex(selectedTab == .wallpaperExplore ? 1 : 0)
                    .allowsHitTesting(selectedTab == .wallpaperExplore)
                }

                if mountedTabs.contains(.animeExplore) {
                    AnimeExploreView(
                        viewModel: animeViewModel,
                        selectedAnime: $selectedAnime,
                        isVisible: selectedTab == .animeExplore
                    )
                    .environment(\.coverGIFPlaybackHostActive, selectedTab == .animeExplore)
                    .opacity(selectedTab == .animeExplore ? 1 : 0)
                    .zIndex(selectedTab == .animeExplore ? 1 : 0)
                    .allowsHitTesting(selectedTab == .animeExplore)
                }

                if mountedTabs.contains(.mediaExplore) {
                    MediaExploreContentView(
                        viewModel: mediaViewModel,
                        selectedMedia: $selectedMedia,
                        isVisible: selectedTab == .mediaExplore
                    )
                    .environment(\.coverGIFPlaybackHostActive, selectedTab == .mediaExplore)
                    .opacity(selectedTab == .mediaExplore ? 1 : 0)
                    .zIndex(selectedTab == .mediaExplore ? 1 : 0)
                    .allowsHitTesting(selectedTab == .mediaExplore)
                }

                // 我的库：不 keep-alive，仅选中时挂载；离开即销毁，`.task` 每次进入全量重载
                if selectedTab == .myMedia {
                    MyLibraryContentView(
                        selectedWallpaper: $librarySelectedWallpaper,
                        selectedMedia: $librarySelectedMedia,
                        selectedAnime: $librarySelectedAnime,
                        wallpaperContext: $libraryWallpaperContext,
                        mediaContext: $libraryMediaContext
                    )
                    .environment(\.coverGIFPlaybackHostActive, true)
                    .zIndex(1)
                    .allowsHitTesting(true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: selectedTab) { _, tab in
                if tab != .myMedia {
                    mountedTabs.insert(tab)
                }
            }
            .id(localization.currentLanguage)

            VStack {
                TopNavigationBar(
                    selectedTab: $selectedTab,
                    onOpenSettings: { openSettingsWindow() },
                    onClose: { hideMainWindow() },
                    onMinimize: { minimizeWindow() },
                    onMaximize: { maximizeWindow() },
                    onZoom: { zoomWindow() }
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
                WallpaperDetailSheet(
                    wallpaper: wallpaper,
                    viewModel: viewModel,
                    contextWallpapers: libraryWallpaperContext.isEmpty ? nil : libraryWallpaperContext
                ) {
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
                MediaDetailSheet(
                    item: item,
                    viewModel: mediaViewModel,
                    contextItems: libraryMediaContext.isEmpty ? nil : libraryMediaContext
                ) {
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

            // 更新弹窗 - ZStack overlay，不创建新窗口避免双层红绿灯
            if showUpdateSheet, let release = updateRelease {
                AutoUpdateSheet(
                    currentVersion: UpdateChecker.shared.currentVersion,
                    latestVersion: release.version,
                    release: release,
                    commit: updateCommit,
                    onClose: { showUpdateSheet = false }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity.animation(.easeOut(duration: 0.25)))
                .zIndex(600)
            }

            // 下载进度弹窗 - 固定在底部
            VStack {
                Spacer()
                DownloadProgressToastHost(viewModel: downloadTaskViewModel)
                WallpaperSourceSwitchToast()
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
                WorkshopSourceSwitchToast()
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)
            }
            .zIndex(400)
            
            // 显示器选择弹窗覆盖层
            DisplaySelectorOverlay()
                .zIndex(700)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            // ⚠️ 等待启动时数据源选择完成（ping Google 决策）
            // 在确定数据源之前不加载壁纸列表数据
            if !sourceManager.isInitialSourceSelectionComplete {
                print("[ContentView] Waiting for initial source selection...")
                // 最多等待 10 秒超时
                for _ in 0..<20 {
                    try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
                    if sourceManager.isInitialSourceSelectionComplete {
                        break
                    }
                }
            }

            // 数据源确定后再加载首页数据
            try? await Task.sleep(nanoseconds: 300_000_000) // 0.3s
            await viewModel.initialLoad()
            
            // 延迟2秒后检查更新（自动检查，非强制，避免频繁触发）
            try? await Task.sleep(nanoseconds: 2 * 1_000_000_000)
            let checker = UpdateChecker.shared
            let result = await checker.checkForUpdates(force: false)
            // 只在有更新时显示弹窗，错误或频率限制时静默处理
            if case .updateAvailable(current: _, latest: let release, commit: let commit) = result {
                updateRelease = release
                updateCommit = commit
                showUpdateSheet = true
            }
        }
        .ignoresSafeArea()
        .applyTheme()
    }

    private func minimizeWindow() {
        NSApp.mainWindow?.miniaturize(nil)
    }

    private func maximizeWindow() {
        guard let window = NSApp.mainWindow else { return }
        window.toggleFullScreen(nil)
    }

    private func zoomWindow() {
        NSApp.mainWindow?.zoom(nil)
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
                                localMediaFileURL: MediaLibraryService.shared.resolvedVideoFileURLIfAvailable(for: item),
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
            downloadsSectionHeader(
                title: t("wallpaper.downloads"),
                systemImage: "arrow.down.circle.fill",
                color: LiquidGlassColors.tertiaryBlue,
                countText: "\(wallpaperDownloadCount) \(t("items"))",
                section: .wallpaperDownloads,
                folderURL: DownloadPathManager.shared.wallpapersFolderURL,
                importAction: importWallpapers
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
            downloadsSectionHeader(
                title: t("media.downloads"),
                systemImage: "arrow.down.circle.fill",
                color: LiquidGlassColors.tertiaryBlue,
                countText: "\(mediaDownloadCount) \(t("items"))",
                section: .mediaDownloads,
                folderURL: DownloadPathManager.shared.mediaFolderURL,
                importAction: { Task { await importMedia() } },
                workshopImportAction: importWorkshop
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
                                    localMediaFileURL: MediaLibraryService.shared.resolvedVideoFileURLIfAvailable(for: item),
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
                                localMediaFileURL: record.resolvedVideoFileURL,
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
                                localMediaFileURL: MediaLibraryService.shared.resolvedVideoFileURLIfAvailable(for: item),
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

    private func downloadsSectionHeader(
        title: String,
        systemImage: String,
        color: Color,
        countText: String,
        section: EditingSection,
        folderURL: URL,
        importAction: @escaping () -> Void,
        workshopImportAction: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: 10) {
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

            // Workshop 导入按钮
            if let workshopImportAction {
                Button(action: workshopImportAction) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .frame(width: 32, height: 32)
                        .liquidGlassSurface(
                            .regular,
                            tint: color.opacity(0.1),
                            in: Capsule(style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .contentShape(Capsule(style: .continuous))
            }

            // 导入按钮
            Button(action: importAction) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .frame(width: 32, height: 32)
                    .liquidGlassSurface(
                        .regular,
                        tint: color.opacity(0.1),
                        in: Capsule(style: .continuous)
                    )
            }
            .buttonStyle(.plain)
            .contentShape(Capsule(style: .continuous))

            // 在访达中显示按钮
            Button {
                openFolderInFinder(folderURL)
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .frame(width: 32, height: 32)
                    .liquidGlassSurface(
                        .regular,
                        tint: color.opacity(0.1),
                        in: Capsule(style: .continuous)
                    )
            }
            .buttonStyle(.plain)
            .contentShape(Capsule(style: .continuous))

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

    // MARK: - 导入与文件夹操作

    private func openFolderInFinder(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    private func importWallpapers() {
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
                print("[ContentView] Failed to import wallpaper \(url.lastPathComponent): \(error)")
            }
        }

        if importedCount > 0 {
            viewModel.objectWillChange.send()
        }
    }

    private func importMedia() async {
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
                print("[ContentView] Failed to import media \(url.lastPathComponent): \(error)")
            }
        }

        if importedCount > 0 {
            mediaViewModel.objectWillChange.send()
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
            print("[ContentView] Failed to load video metadata: \(error)")
        }

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



    private func importWorkshop() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = t("import")

        guard panel.runModal() == .OK else { return }

        let destinationRoot = DownloadPathManager.shared.mediaFolderURL
        let fileManager = FileManager.default
        var importedCount = 0

        for url in panel.urls {
            let ext = url.pathExtension.lowercased()
            guard ext == "pkg" else {
                print("[ContentView] Skipped non-pkg file: \(url.lastPathComponent)")
                continue
            }

            let sourceDir = url.deletingLastPathComponent()
            let projectJSONURL = sourceDir.appendingPathComponent("project.json")
            guard fileManager.fileExists(atPath: projectJSONURL.path) else {
                print("[ContentView] No project.json found next to \(url.lastPathComponent)")
                continue
            }

            guard let data = try? Data(contentsOf: projectJSONURL),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                print("[ContentView] Failed to parse project.json for \(url.lastPathComponent)")
                continue
            }

            let title = (json["title"] as? String) ?? sourceDir.lastPathComponent
            var workshopID = (json["publishedfileid"] as? String) ?? (json["id"] as? String)

            if workshopID == nil {
                let dirName = sourceDir.lastPathComponent
                let numeric = dirName.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
                if !numeric.isEmpty {
                    workshopID = numeric
                }
            }

            guard let id = workshopID, !id.isEmpty else {
                print("[ContentView] Could not infer workshop ID for \(url.lastPathComponent)")
                continue
            }

            let destDir = destinationRoot.appendingPathComponent("workshop_\(id)")
            do {
                if fileManager.fileExists(atPath: destDir.path) {
                    try fileManager.removeItem(at: destDir)
                }
                try fileManager.copyItem(at: sourceDir, to: destDir)

                let previewExtensions = ["jpg", "jpeg", "png", "webp", "gif"]
                var previewURL: URL?
                for pe in previewExtensions {
                    let candidate = destDir.appendingPathComponent("preview.\(pe)")
                    if fileManager.fileExists(atPath: candidate.path) {
                        previewURL = candidate
                        break
                    }
                }

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
                print("[ContentView] Failed to import workshop \(url.lastPathComponent): \(error)")
            }
        }

        if importedCount > 0 {
            mediaViewModel.objectWillChange.send()
        }
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
    var localMediaFileURL: URL? = nil
    let badgeText: String
    let accent: Color
    let isEditing: Bool
    let isSelected: Bool
    var progress: Double? = nil
    var progressTint: Color? = nil
    var progressLabel: String? = nil
    let action: () -> Void

    @State private var isHovered = false
    /// 异步生成抽帧后更新的本地封面 URL
    @State private var resolvedThumbnailURL: URL?

    private static let videoExtensions: Set<String> = ["mp4", "mov", "webm", "m4v", "mkv"]

    private var listThumbnailURL: URL {
        resolvedThumbnailURL ?? item.libraryGridThumbnailURL(localFileURL: localMediaFileURL)
    }

    // 降采样目标尺寸（固定 512x512，避免窗口大小变化导致缓存失效）
    private let listThumbnailTargetSize: CGSize = CGSize(width: 512, height: 512)

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                // 图片区域 - 单独裁剪（仅静态；优先本地截取帧）
                ZStack {
                    KFImage(listThumbnailURL)
                        .setProcessor(DownsamplingImageProcessor(size: listThumbnailTargetSize))
                        .cacheMemoryOnly(false)
                        .cancelOnDisappear(true)
                        .fade(duration: 0.3)
                        .placeholder { _ in
                            SkeletonCard(
                                width: LibraryCardMetrics.cardWidth,
                                height: LibraryCardMetrics.thumbnailHeight,
                                cornerRadius: 0
                            )
                        }
                        .resizable()
                        .scaledToFill()
                        .frame(width: LibraryCardMetrics.cardWidth, height: LibraryCardMetrics.thumbnailHeight)
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
                // 只给图片区域顶部圆角
                .clipShape(
                    .rect(
                        topLeadingRadius: 22,
                        bottomLeadingRadius: 0,
                        bottomTrailingRadius: 0,
                        topTrailingRadius: 22
                    )
                )

                // 信息区域 - 单独背景
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
                .frame(width: LibraryCardMetrics.cardWidth, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color(hex: "1A1D24").opacity(0.6))
                        .clipShape(
                            .rect(
                                topLeadingRadius: 0,
                                bottomLeadingRadius: 22,
                                bottomTrailingRadius: 22,
                                topTrailingRadius: 0
                            )
                        )
                )
            }
            .frame(width: LibraryCardMetrics.cardWidth, alignment: .leading)
            .scaleEffect(isHovered ? 1.01 : 1.0)
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onHover { hovering in
            if !isEditing {
                withAnimation(.easeOut(duration: 0.16)) {
                    isHovered = hovering
                }
            }
        }
        .onAppear { triggerThumbnailIfNeeded() }
        .onChange(of: localMediaFileURL) { _, _ in resolvedThumbnailURL = nil; triggerThumbnailIfNeeded() }
    }

    /// 已下载的视频如果没有缓存抽帧，异步生成并刷新封面
    @MainActor
    private func triggerThumbnailIfNeeded() {
        guard resolvedThumbnailURL == nil,
              let local = localMediaFileURL,
              local.isFileURL,
              FileManager.default.fileExists(atPath: local.path) else { return }

        // 解析目录→视频文件/预览图（壁纸引擎源），或直接使用文件
        if let resolved = MediaItem.resolveLocalVideoFile(from: local) ?? (
            Self.videoExtensions.contains(local.pathExtension.lowercased()) ? local : nil
        ) {
            if let cached = VideoThumbnailCache.shared.cachedStaticThumbnailFileURLIfExists(forLocalFile: resolved) {
                resolvedThumbnailURL = cached
                return
            }
            // 如果是视频文件，异步生成抽帧
            if Self.videoExtensions.contains(resolved.pathExtension.lowercased()) {
                Task { @MainActor in
                    if let poster = await VideoThumbnailCache.shared.posterJPEGFileURL(forLocalVideo: resolved) {
                        resolvedThumbnailURL = poster
                    }
                }
            }
            return
        }
    }
}

// MARK: - iOS 丝滑风格下载进度弹窗宿主
private struct DownloadProgressToastHost: View {
    @ObservedObject var viewModel: DownloadTaskViewModel

    @State private var displayedTaskID: String?
    @State private var hideWorkItem: DispatchWorkItem?

    // iOS 丝滑动画状态
    @State private var toastOpacity: Double = 0
    @State private var toastScale: Double = 0.92
    @State private var toastOffset: CGFloat = 10

    private var displayedTask: DownloadTask? {
        viewModel.tasks.first(where: { $0.id == displayedTaskID })
    }

    /// 入场动画：轻快弹簧，类似系统通知弹出
    private var iOSShowAnimation: Animation {
        .spring(response: 0.35, dampingFraction: 0.82, blendDuration: 0)
    }

    /// 退场动画：快速利落
    private var iOSDismissAnimation: Animation {
        .easeOut(duration: 0.20)
    }

    var body: some View {
        Group {
            if let task = displayedTask {
                DownloadProgressToast(
                    task: task,
                    activeTaskCount: viewModel.tasks.filter(\.isRunning).count
                )
                .frame(maxWidth: 440)
                .padding(.bottom, 26)
                .opacity(toastOpacity)
                .scaleEffect(toastScale, anchor: .bottom)
                .offset(y: toastOffset)
                .transition(
                    .asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .bottom)),
                        removal: .opacity
                    )
                )
            }
        }
        .onAppear {
            reconcileDisplayedTask(with: viewModel.tasks)
        }
        .onReceive(viewModel.$tasks) { tasks in
            reconcileDisplayedTask(with: tasks)
        }
    }

    // MARK: - 动画控制

    /// 入场：底部轻弹 + 缩放
    private func performShow() {
        toastOpacity = 0
        toastScale = 0.92
        toastOffset = 8

        withAnimation(iOSShowAnimation) {
            toastOpacity = 1
            toastScale = 1.0
            toastOffset = 0
        }
    }

    /// 退场：向下缩小淡出（精简不卡顿）
    private func performHide(completion: @escaping () -> Void) {
        withAnimation(iOSDismissAnimation) {
            toastOpacity = 0
            toastScale = 0.96
            toastOffset = 6
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
            completion()
        }
    }

    private func reconcileDisplayedTask(with tasks: [DownloadTask]) {
        hideWorkItem?.cancel()

        if let activeTask = tasks
            .filter(\.isRunning)
            .max(by: { $0.lastUpdatedAt < $1.lastUpdatedAt })
        {
            // 如果是新任务或当前无显示任务，重新执行入场动画
            if displayedTaskID != activeTask.id {
                displayedTaskID = activeTask.id
                performShow()
            } else {
                withAnimation(iOSShowAnimation) {
                    displayedTaskID = activeTask.id
                }
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
            if displayedTaskID != recentTerminalTask.id {
                displayedTaskID = recentTerminalTask.id
                performShow()
            }

            let workItem = DispatchWorkItem { [self] in
                performHide {
                    if displayedTaskID == recentTerminalTask.id {
                        displayedTaskID = nil
                    }
                }
            }
            hideWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: workItem)
            return
        }

        performHide {
            displayedTaskID = nil
        }
    }
}

// MARK: - iOS 丝滑风格下载进度 Toast
private struct DownloadProgressToast: View {
    let task: DownloadTask
    let activeTaskCount: Int

    @State private var animatedProgress: Double = 0

    private var tint: Color {
        switch task.status {
        case .pending:
            return Color.white.opacity(0.7)
        case .downloading:
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

    private var iconName: String {
        switch task.kind {
        case .wallpaper:
            return "photo.fill"
        case .media:
            return "play.rectangle.fill"
        case .workshop:
            return "gearshape.fill"
        }
    }

    private var statusText: String {
        switch task.status {
        case .pending:   return t("status.pending")
        case .downloading: return t("status.downloading")
        case .paused:     return t("status.paused")
        case .completed:   return t("status.completed")
        case .failed:      return t("status.failed")
        case .cancelled:   return t("status.cancelled")
        }
    }

    private var subtitle: String {
        if activeTaskCount > 1 && task.isRunning {
            let base = task.subtitle.isEmpty ? "\(activeTaskCount) \(t("items"))" : "\(task.subtitle) · \(activeTaskCount) \(t("items"))"
            return base
        }
        if task.subtitle.isEmpty { return task.badgeText }
        if task.badgeText.isEmpty { return task.subtitle }
        return "\(task.subtitle) · \(task.badgeText)"
    }

    private var isCompleted: Bool { task.status == .completed }

    /// 进度条动画：平滑跟随（优化：更长的响应时间减少重绘频率）
    private var progressAnimation: Animation {
        .interpolatingSpring(stiffness: 120, damping: 20)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                // 图标：完成时变绿色 + 微弹性
                Image(systemName: isCompleted ? "checkmark" : iconName)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                    .background(
                        DarkLiquidGlassBackground(
                            cornerRadius: 17,
                            isHovered: false
                        )
                    )
                    .scaleEffect(isCompleted ? 1.08 : 1.0)

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

                // 状态标签（统一样式，只变色）
                Text(statusText)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(
                        DarkLiquidGlassBackground(
                            cornerRadius: 12,
                            isHovered: false
                        )
                        .opacity(0.7)
                    )
            }

            // 进度区域
            if !isCompleted {
                // 进度条
                LiquidGlassLinearProgressBar(
                    progress: animatedProgress,
                    height: 6,
                    tintColor: tint,
                    trackOpacity: 0.15
                )

                HStack {
                    Text(task.kind == .wallpaper ? t("wallpaper.downloads") : t("media.downloads"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))

                    Spacer()

                    Text("\(Int((max(0, min(animatedProgress, 1)) * 100).rounded()))%")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.86))
                        .contentTransition(.numericText())
                }
            } else {
                // 完成行：简洁显示
                HStack(spacing: 6) {
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(LiquidGlassColors.onlineGreen)
                    Text(t("status.completed"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(LiquidGlassColors.onlineGreen)
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: 440)
        .background(
            DarkLiquidGlassBackground(
                cornerRadius: 24,
                isHovered: false
            )
        )
        // 精简动画：只用颜色过渡，避免复杂的 layout transition 导致卡顿
        .animation(.easeInOut(duration: 0.20), value: isCompleted)
        .onChange(of: task.progress) { _, newProgress in
            withAnimation(progressAnimation) {
                animatedProgress = newProgress
            }
        }
        .onAppear {
            animatedProgress = task.progress
        }
    }
}

// MARK: - 壁纸数据源切换 Toast（自动降级 / 手动切换提示）
private struct WallpaperSourceSwitchToast: View {
    @ObservedObject private var sourceManager = WallpaperSourceManager.shared
    @State private var isShowing: Bool = false
    @State private var hideWorkItem: DispatchWorkItem?

    var body: some View {
        VStack {
            if let message = sourceManager.lastSwitchMessage, isShowing {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color(hex: "FFD60A"))
                    Text(message)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.9))
                        .multilineTextAlignment(.center)
                    Text("可在「设置 → 壁纸数据源」中手动切回")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(Color.white.opacity(0.4))
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                        )
                        .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
                )
                .frame(maxWidth: 360)
            }
        }
        .padding(.bottom, 40)
        .opacity(isShowing ? 1 : 0)
        .offset(y: isShowing ? 0 : 20)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
        .onChange(of: sourceManager.lastSwitchMessage) { _, _ in
            checkForNewMessage()
        }
    }

    // MARK: - 监听消息变化

    /// 当 lastSwitchMessage 变化时触发显示
    private func checkForNewMessage() {
        guard sourceManager.lastSwitchMessage != nil else { return }
        
        hideWorkItem?.cancel()
        isShowing = true
        
        let workItem = DispatchWorkItem { [weak sourceManager] in
            withAnimation(.easeOut(duration: 0.25)) {
                isShowing = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                sourceManager?.lastSwitchMessage = nil
            }
        }
        self.hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: workItem)
    }
}


// MARK: - Wallpaper Engine 数据源切换 Toast
private struct WorkshopSourceSwitchToast: View {
    @ObservedObject private var sourceManager = WorkshopSourceManager.shared
    @State private var isShowing: Bool = false
    @State private var hideWorkItem: DispatchWorkItem?

    var body: some View {
        VStack {
            if let message = sourceManager.lastSwitchMessage, isShowing {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: sourceManager.activeSource.icon)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color(hex: "0A84FF"))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.5))
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color(hex: "5E5CE6"))
                    }
                    Text(message)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.9))
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                        )
                        .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
                )
                .frame(maxWidth: 360)
            }
        }
        .opacity(isShowing ? 1 : 0)
        .offset(y: isShowing ? 0 : 20)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
        .onChange(of: sourceManager.lastSwitchMessage) { _, _ in
            checkForNewMessage()
        }
    }

    private func checkForNewMessage() {
        guard sourceManager.lastSwitchMessage != nil else { return }
        
        hideWorkItem?.cancel()
        isShowing = true
        
        let workItem = DispatchWorkItem { [weak sourceManager] in
            withAnimation(.easeOut(duration: 0.25)) {
                isShowing = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                sourceManager?.lastSwitchMessage = nil
            }
        }
        self.hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: workItem)
    }
}
