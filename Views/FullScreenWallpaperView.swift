import SwiftUI

// MARK: - 全屏壁纸预览视图 - macOS 26 Liquid Glass 风格
struct FullScreenWallpaperView: View {
    let initialWallpaper: Wallpaper
    @ObservedObject var viewModel: WallpaperViewModel
    @Environment(\.dismiss) private var dismiss

    // 使用 @State 管理当前壁纸，支持内部切换
    @State private var currentWallpaper: Wallpaper
    @State private var isFullScreen = false
    @State private var isLoading = true
    @State private var loadError: Error?
    @State private var imageScale: CGFloat = 1.0
    @State private var lastTapTime: Date = Date()
    @State private var showControls = true
    @State private var controlsTimer: Timer?

    // 图片内存缓存
    @State private var cachedImage: NSImage?

    // MARK: - 下一张弹窗相关
    @StateObject private var nextItemDataSource = NextItemDataSource()
    @State private var currentWallpaperIndex: Int = 0
    @State private var viewAppearTime: Date = Date()

    // 计算属性：当前壁纸
    var wallpaper: Wallpaper { currentWallpaper }

    init(wallpaper: Wallpaper, viewModel: WallpaperViewModel) {
        self.initialWallpaper = wallpaper
        self.viewModel = viewModel
        _currentWallpaper = State(initialValue: wallpaper)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // 深色背景
                Color.black.ignoresSafeArea()

                // 壁纸图片 - 带懒加载和内存管理
                wallpaperImageView
                    .scaleEffect(imageScale)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in
                                imageScale = min(max(value, 1.0), 3.0)
                            }
                            .onEnded { _ in
                                withAnimation(.easeOut(duration: 0.3)) {
                                    imageScale = 1.0
                                }
                            }
                    )
                    .onTapGesture(count: 2) {
                        // 双击切换全屏
                        toggleFullScreen()
                    }
                    .onTapGesture {
                        // 单击切换控制栏显示
                        toggleControls()
                    }

                // 加载指示器
                if isLoading {
                    LiquidGlassLoadingView(message: t("loading"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black.opacity(0.5))
                }

                // 错误提示
                if let error = loadError {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 48))
                            .foregroundStyle(LiquidGlassColors.warningOrange)

                        Text(t("loadFailed"))
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.white)

                        Text(error.localizedDescription)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.7))
                            .multilineTextAlignment(.center)

                        Button(t("retry")) {
                            loadError = nil
                            isLoading = true
                        }
                        .buttonStyle(LiquidGlassButtonStyle())
                    }
                    .padding(32)
                    .background(
                        RoundedRectangle(cornerRadius: 20)
                            .fill(.ultraThinMaterial)
                    )
                }

                // 顶部工具栏 - Liquid Glass 风格
                if showControls {
                    topToolbar
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                // 底部信息栏
                if showControls {
                    bottomInfoBar
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // 下一张弹窗
                LiquidGlassNextItemToast(
                    nextItem: nextItemDataSource.nextItem,
                    onTap: {
                        navigateToNextWallpaper()
                    },
                    onScrollUp: {
                        navigateToNextWallpaper()
                    },
                    onScrollDown: {
                        navigateToPreviousWallpaper()
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(nextItemDataSource.nextItem != nil)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .onAppear {
            setupWindow()
            startControlsTimer()
            setupNextItemDataSource()
        }
        .onDisappear {
            cleanup()
        }
    }

    // MARK: - 壁纸图片视图（带懒加载和缓存）
    private var wallpaperImageView: some View {
        Group {
            if let cachedImage = cachedImage {
                // 使用缓存的图片
                Image(nsImage: cachedImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // 异步加载图片
                OptimizedAsyncImage(url: wallpaper.fullImageURL, priority: .high) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .onAppear {
                            isLoading = false
                        }
                } placeholder: {
                    Color.clear
                        .onAppear {
                            isLoading = true
                        }
                }
            }
        }
    }

    // MARK: - 顶部工具栏
    private var topToolbar: some View {
        VStack {
            HStack(spacing: 12) {
                // 关闭按钮
                GlassToolbarButton(
                    icon: "xmark",
                    color: .white
                ) {
                    dismiss()
                }

                Spacer()

                // 右侧工具按钮组
                HStack(spacing: 12) {
                    // 全屏切换按钮
                    GlassToolbarButton(
                        icon: isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                        color: .white
                    ) {
                        toggleFullScreen()
                    }

                    // 收藏按钮
                    GlassToolbarButton(
                        icon: viewModel.isFavorite(wallpaper) ? "heart.fill" : "heart",
                        color: viewModel.isFavorite(wallpaper) ? LiquidGlassColors.primaryPink : .white
                    ) {
                        viewModel.toggleFavorite(wallpaper)
                    }

                    // 下载按钮
                    GlassToolbarButton(
                        icon: viewModel.isDownloaded(wallpaper) ? "checkmark.circle.fill" : "arrow.down.circle",
                        color: viewModel.isDownloaded(wallpaper) ? LiquidGlassColors.onlineGreen : .white
                    ) {
                        downloadWallpaper()
                    }

                    // 设为壁纸按钮
                    GlassToolbarButton(
                        icon: "desktopcomputer",
                        color: .white
                    ) {
                        setAsWallpaper()
                    }

                    // 分享按钮
                    GlassToolbarButton(
                        icon: "square.and.arrow.up",
                        color: .white
                    ) {
                        shareWallpaper()
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(
                LinearGradient(
                    colors: [
                        Color.black.opacity(0.6),
                        Color.black.opacity(0.3),
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )

            Spacer()
        }
    }

    // MARK: - 底部信息栏
    private var bottomInfoBar: some View {
        VStack {
            Spacer()

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(wallpaper.resolution)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)

                    HStack(spacing: 8) {
                        Label("\(wallpaper.views)", systemImage: "eye")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.7))

                        Label("\(wallpaper.favorites)", systemImage: "heart")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.7))

                        if let downloads = wallpaper.downloads {
                            Label("\(downloads)", systemImage: "arrow.down")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                }

                Spacer()

                // 标签
                HStack(spacing: 6) {
                    CategoryBadge(category: wallpaper.category)
                    PurityBadge(purity: wallpaper.purity)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(
                LinearGradient(
                    colors: [
                        Color.clear,
                        Color.black.opacity(0.3),
                        Color.black.opacity(0.6)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
    }

    // MARK: - 方法

    private func setupWindow() {
        // 进入全屏模式
        DispatchQueue.main.async {
            if let window = NSApp.windows.first(where: { $0.contentView != nil }) {
                window.setFrame(
                    window.screen?.frame ?? NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1200, height: 800),
                    display: true
                )
                window.level = .floating
                window.collectionBehavior = [.fullScreenPrimary, .canJoinAllSpaces]
            }
        }
    }

    private func cleanup() {
        controlsTimer?.invalidate()
        controlsTimer = nil

        // 恢复窗口级别
        DispatchQueue.main.async {
            if let window = NSApp.windows.first(where: { $0.contentView != nil }) {
                window.level = .normal
            }
        }

        // 清理内存缓存（可选，根据内存压力决定）
        if cachedImage != nil {
            // 保留缓存以支持快速重新打开
            // 在内存警告时系统会自动清理
        }
    }

    private func toggleFullScreen() {
        if let window = NSApp.windows.first(where: { $0.contentView != nil }) {
            if isFullScreen {
                window.setFrame(
                    window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800),
                    display: true
                )
                isFullScreen = false
            } else {
                window.setFrame(
                    window.screen?.frame ?? NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1200, height: 800),
                    display: true
                )
                isFullScreen = true
            }
        }
    }

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.2)) {
            showControls.toggle()
        }

        if showControls {
            startControlsTimer()
        } else {
            controlsTimer?.invalidate()
        }
    }

    private func startControlsTimer() {
        controlsTimer?.invalidate()
        controlsTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { _ in
            withAnimation(.easeInOut(duration: 0.2)) {
                showControls = false
            }
        }
    }

    private func cacheImage(from image: Image) {
        // 将 SwiftUI Image 转换为 NSImage 并缓存
        // 注意：这里使用延迟加载策略，只在需要时缓存
        DispatchQueue.global(qos: .utility).async {
            // 实际的缓存逻辑在 AsyncImage 内部处理
            // 这里可以添加额外的缓存层
        }
    }

    // MARK: - 下一张弹窗相关方法

    private func setupNextItemDataSource() {
        // 找到当前壁纸在列表中的索引
        if let index = viewModel.wallpapers.firstIndex(where: { $0.id == wallpaper.id }) {
            currentWallpaperIndex = index
        }

        // 设置数据源
        nextItemDataSource.setItems(viewModel.wallpapers, currentIndex: currentWallpaperIndex)
    }

    private func navigateToNextWallpaper() {
        guard nextItemDataSource.hasNext else { return }

        // 获取下一张壁纸
        let nextIndex = currentWallpaperIndex + 1
        guard nextIndex < viewModel.wallpapers.count else { return }

        let nextWallpaper = viewModel.wallpapers[nextIndex]

        // 更新索引和数据源
        currentWallpaperIndex = nextIndex
        nextItemDataSource.moveToNext()

        // 重新加载视图
        reloadWallpaper(nextWallpaper)
    }

    private func navigateToPreviousWallpaper() {
        guard nextItemDataSource.hasPrevious else { return }

        // 获取上一张壁纸
        let prevIndex = currentWallpaperIndex - 1
        guard prevIndex >= 0 else { return }

        let prevWallpaper = viewModel.wallpapers[prevIndex]

        // 更新索引和数据源
        currentWallpaperIndex = prevIndex
        nextItemDataSource.moveToPrevious()

        // 重新加载视图
        reloadWallpaper(prevWallpaper)
    }

    private func reloadWallpaper(_ newWallpaper: Wallpaper) {
        withAnimation(.easeInOut(duration: 0.3)) {
            // 更新当前壁纸
            currentWallpaper = newWallpaper

            // 重置状态
            isLoading = true
            loadError = nil
            cachedImage = nil
            imageScale = 1.0
        }
    }

    private func downloadWallpaper() {
        Task {
            do {
                try await viewModel.downloadWallpaper(wallpaper)
            } catch {
                print("Download error: \(error)")
            }
        }
    }

    private func shareWallpaper() {
        guard let url = URL(string: wallpaper.url) else { return }
        let picker = NSSharingServicePicker(items: [url])
        let rect = NSRect(x: 0, y: 0, width: 44, height: 44)
        picker.show(
            relativeTo: rect,
            of: NSApp.windows.first?.contentView ?? NSView(),
            preferredEdge: .minY
        )
    }

    private func setAsWallpaper() {
        Task {
            do {
                try await viewModel.setAsWallpaper(wallpaper)
            } catch {
                print("Set wallpaper error: \(error)")
            }
        }
    }
}

// MARK: - 玻璃工具栏按钮
struct GlassToolbarButton: View {
    let icon: String
    let color: Color
    let action: () -> Void

    @State private var isHovered = false
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 44, height: 44)
                .liquidGlassSurface(.max, tint: color.opacity(isHovered ? 0.22 : 0.12), in: Circle())
                .shadow(
                    color: isHovered ? Color.black.opacity(0.3) : Color.black.opacity(0.15),
                    radius: isHovered ? 12 : 8,
                    y: isHovered ? 6 : 4
                )
                .scaleEffect(isPressed ? 0.92 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .pressEvents {
            withAnimation(.easeInOut(duration: 0.1)) {
                isPressed = true
            }
        } onRelease: {
            withAnimation(.easeInOut(duration: 0.1)) {
                isPressed = false
            }
        }
    }
}

// MARK: - 分类标签
struct CategoryBadge: View {
    let category: String

    var body: some View {
        Text(categoryLabel)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(categoryColor.opacity(0.3))
            )
            .foregroundStyle(categoryColor)
    }

    private var categoryLabel: String {
        switch category.lowercased() {
        case "general": return t("general")
        case "anime": return t("anime")
        case "people": return t("people")
        default: return category.capitalized
        }
    }

    private var categoryColor: Color {
        switch category.lowercased() {
        case "general": return LiquidGlassColors.onlineGreen
        case "anime": return LiquidGlassColors.primaryPink
        case "people": return LiquidGlassColors.secondaryViolet
        default: return .white
        }
    }
}

// MARK: - 纯度标签
struct PurityBadge: View {
    let purity: String

    var body: some View {
        Text(purityLabel)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(purityColor.opacity(0.3))
            )
            .foregroundStyle(purityColor)
    }

    private var purityLabel: String {
        switch purity.lowercased() {
        case "sfw": return "SFW"
        case "sketchy": return "Sketchy"
        case "nsfw": return "NSFW"
        default: return purity.uppercased()
        }
    }

    private var purityColor: Color {
        switch purity.lowercased() {
        case "sfw": return LiquidGlassColors.onlineGreen
        case "sketchy": return LiquidGlassColors.warningOrange
        case "nsfw": return .red
        default: return .white
        }
    }
}

// MARK: - 按钮样式
struct LiquidGlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(LiquidGlassColors.primaryPink)
                    .opacity(configuration.isPressed ? 0.8 : 1.0)
            )
    }
}

// MARK: - 按下事件扩展 (使用 DesignSystem 版本)
// pressEvents 已移至 DesignSystem/LiquidGlassDesignSystem.swift

// MARK: - 颜色定义 (使用 DesignSystem 版本)
// LiquidGlassColors 已移至 DesignSystem/LiquidGlassDesignSystem.swift
