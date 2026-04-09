import SwiftUI

// MARK: - 控制栏定时器管理器
final class ControlsTimerManager: ObservableObject {
    var timer: Timer?
    
    deinit {
        timer?.invalidate()
    }
    
    func invalidate() {
        timer?.invalidate()
        timer = nil
    }
    
    func schedule(interval: TimeInterval, action: @escaping @MainActor () -> Void) {
        invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { _ in
            Task { @MainActor in
                action()
            }
        }
    }
}

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
    @State private var showControls = true
    @StateObject private var controlsTimerManager = ControlsTimerManager()

    // 图片内存缓存
    @State private var cachedImage: NSImage?

    // MARK: - 下一张弹窗相关
    @StateObject private var nextItemDataSource = NextItemDataSource()
    @State private var currentWallpaperIndex: Int = 0
    @State private var isLoadingMore = false
    @State private var preloadTask: Task<Void, Never>?

    // 计算属性：当前壁纸
    var wallpaper: Wallpaper { currentWallpaper }
    
    // MARK: - 本地文件检测
    private var isLocalFile: Bool {
        wallpaper.id.hasPrefix("local_")
    }
    
    /// 是否已下载（包括网络下载和本地文件）
    private var isAlreadyDownloaded: Bool {
        isLocalFile || viewModel.isDownloaded(wallpaper)
    }

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
        .onChange(of: viewModel.wallpapers) { _, newWallpapers in
            // 当列表数据更新时，同步更新数据源
            nextItemDataSource.setItems(newWallpapers, currentIndex: currentWallpaperIndex)
            // 检查是否需要预加载
            triggerPreloadIfNeeded()
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
                        icon: isAlreadyDownloaded ? "checkmark.circle.fill" : "arrow.down.circle",
                        color: isAlreadyDownloaded ? LiquidGlassColors.onlineGreen : .white
                    ) {
                        if !isLocalFile {
                            downloadWallpaper()
                        }
                    }
                    .disabled(isLocalFile)

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
        // 进入全屏模式 - 使用 keyWindow 或 mainWindow 获取当前活动窗口
        DispatchQueue.main.async {
            if let window = NSApp.keyWindow ?? NSApp.mainWindow {
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
        controlsTimerManager.invalidate()
        
        // 取消预加载任务
        preloadTask?.cancel()

        // 恢复窗口级别 - 使用 keyWindow 或 mainWindow 获取当前活动窗口
        DispatchQueue.main.async {
            if let window = NSApp.keyWindow ?? NSApp.mainWindow {
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
        // 使用 keyWindow 或 mainWindow 获取当前活动窗口
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
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
            controlsTimerManager.invalidate()
        }
    }

    private func startControlsTimer() {
        controlsTimerManager.schedule(interval: 3.0) {
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
        
        // 初始预加载检查
        triggerPreloadIfNeeded()
    }

    /// 当浏览到倒数第3张时触发预加载
    private func triggerPreloadIfNeeded() {
        let threshold = 3 // 倒数第3张时开始预加载
        let remainingItems = viewModel.wallpapers.count - (currentWallpaperIndex + 1)
        
        // 如果剩余项目少于阈值，且有更多页面，则触发预加载
        if remainingItems < threshold && viewModel.hasMorePages && !viewModel.isLoading && !isLoadingMore {
            preloadTask?.cancel()
            preloadTask = Task {
                print("[FullScreenWallpaperView] 触发预加载，当前索引: \(currentWallpaperIndex), 总数: \(viewModel.wallpapers.count)")
                await viewModel.loadMore()
                // 加载完成后更新数据源
                await MainActor.run {
                    nextItemDataSource.setItems(viewModel.wallpapers, currentIndex: currentWallpaperIndex)
                }
            }
        }
    }

    private func navigateToNextWallpaper() {
        let nextIndex = currentWallpaperIndex + 1
        
        // 情况1：下一张已经在当前列表中
        if nextIndex < viewModel.wallpapers.count {
            navigateToIndex(nextIndex)
            // 导航后检查是否需要预加载
            triggerPreloadIfNeeded()
            return
        }
        
        // 情况2：到达列表末尾，但有更多页面可加载
        if viewModel.hasMorePages && !viewModel.isLoading && !isLoadingMore {
            Task {
                isLoadingMore = true
                defer { isLoadingMore = false }
                
                print("[FullScreenWallpaperView] 加载更多壁纸...")
                await viewModel.loadMore()
                
                // 加载完成后，尝试导航到下一张
                if nextIndex < viewModel.wallpapers.count {
                    navigateToIndex(nextIndex)
                }
            }
            return
        }
        
        // 情况3：没有更多数据了，循环到第一张
        if !viewModel.wallpapers.isEmpty && nextIndex >= viewModel.wallpapers.count {
            navigateToIndex(0)
        }
    }

    private func navigateToPreviousWallpaper() {
        let prevIndex = currentWallpaperIndex - 1
        
        // 情况1：上一张在列表中
        if prevIndex >= 0 {
            navigateToIndex(prevIndex)
            return
        }
        
        // 情况2：已经是第一张，循环到最后一张
        if !viewModel.wallpapers.isEmpty {
            navigateToIndex(viewModel.wallpapers.count - 1)
        }
    }

    private func navigateToIndex(_ index: Int) {
        guard index >= 0, index < viewModel.wallpapers.count else { return }
        
        currentWallpaperIndex = index
        nextItemDataSource.moveToIndex(index)
        reloadWallpaper(viewModel.wallpapers[index])
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
        // 本地文件无需下载
        if isLocalFile {
            return
        }
        
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
        // 使用当前 keyWindow 或 mainWindow 而不是任意窗口
        let targetView = NSApp.keyWindow?.contentView ?? NSApp.mainWindow?.contentView ?? NSView()
        picker.show(
            relativeTo: rect,
            of: targetView,
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

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .liquidGlassSurface(.max, tint: color.opacity(isHovered ? 0.22 : 0.12), in: Circle())
                .shadow(
                    color: isHovered ? Color.black.opacity(0.3) : Color.black.opacity(0.15),
                    radius: isHovered ? 12 : 8,
                    y: isHovered ? 6 : 4
                )
        }
        .buttonStyle(PressableGlassButtonStyle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// 玻璃态按钮样式：内部处理按压效果，避免手势冲突
private struct PressableGlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
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
