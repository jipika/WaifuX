import SwiftUI
import AppKit
import AppIntents
import Kingfisher

final class EdgeToEdgeHostingView<Content: View>: NSHostingView<Content> {
    private let edgeToEdgeLayoutGuide = NSLayoutGuide()
    private let zeroInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

    required init(rootView: Content) {
        super.init(rootView: rootView)

        addLayoutGuide(edgeToEdgeLayoutGuide)
        NSLayoutConstraint.activate([
            edgeToEdgeLayoutGuide.leadingAnchor.constraint(equalTo: leadingAnchor),
            edgeToEdgeLayoutGuide.trailingAnchor.constraint(equalTo: trailingAnchor),
            edgeToEdgeLayoutGuide.topAnchor.constraint(equalTo: topAnchor),
            edgeToEdgeLayoutGuide.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var safeAreaRect: NSRect {
        bounds
    }

    override var safeAreaInsets: NSEdgeInsets {
        zeroInsets
    }

    override var safeAreaLayoutGuide: NSLayoutGuide {
        edgeToEdgeLayoutGuide
    }

    override var additionalSafeAreaInsets: NSEdgeInsets {
        get { zeroInsets }
        set { }
    }
}

@main
struct WaifuXApp {
    static func main() {
        // 配置 Kingfisher（高性能图片加载）
        configureKingfisher()
        
        // 配置全局 URLCache
        let cache = URLCache(
            memoryCapacity: 50_000_000,  // 50 MB，与 Kingfisher 内存缓存叠加后更可控
            diskCapacity: 500_000_000,   // 500 MB 磁盘缓存
            diskPath: "WaifuXImageCache"
        )
        URLCache.shared = cache

        // 注意：不要修改 URLSession.shared 的配置
        // 因为它是一个共享的单例，修改可能影响其他代码
        // 各服务应该使用自定义的 URLSession 配置

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
    
    /// 配置 Kingfisher 高性能图片加载
    private static func configureKingfisher() {
        // 内存缓存配置 - 降低到 50MB/80张，减少内存占用
        ImageCache.default.memoryStorage.config.totalCostLimit = 50 * 1024 * 1024 // 50MB
        ImageCache.default.memoryStorage.config.countLimit = 80
        
        // 磁盘缓存配置
        ImageCache.default.diskStorage.config.sizeLimit = 500 * 1024 * 1024 // 500MB
        ImageCache.default.diskStorage.config.expiration = .days(7)
        
        // 下载配置
        let downloader = KingfisherManager.shared.downloader
        downloader.downloadTimeout = 30.0
        
        // 设置内存压力处理（使用 DispatchSource）
        #if os(macOS)
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler {
            // 内存紧张时清理 Kingfisher 内存缓存
            ImageCache.default.clearMemoryCache()
        }
        source.resume()
        #endif
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow?
    // ⚠️ 延迟初始化 SettingsViewModel，不在 AppDelegate 属性初始化阶段创建
    // 避免其 @Published didSet 在 applicationDidFinishLaunching 之前写 UserDefaults
    private var settingsViewModel: SettingsViewModel?
    private var settingsWindowController: NSWindowController?
    
    // MARK: - 窗口尺寸（唯一真实来源，全局统一）
    /// 最小允许的窗口大小
    private static let minimumWindowSize = NSSize(width: 1150, height: 720)

    /// 默认窗口大小：根据屏幕尺寸动态计算（首次启动或无保存状态时使用）
    private static var defaultWindowSize: NSSize {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let screen else {
            return NSSize(width: 1400, height: 880) // 兜底值
        }
        let available = screen.visibleFrame
        // 取屏幕可用区域的 ~78% 宽度，~92% 高度，给首页轮播和内容区留足空间
        let width = max(minimumWindowSize.width, floor(available.width * 0.78))
        let height = max(minimumWindowSize.height, floor(available.height * 0.92))
        return NSSize(width: width, height: height)
    }

    // MARK: - 窗口自动保存名称
    private enum WindowAutosaveName {
        static let mainWindow = "WaifuXMainWindow"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // ⚠️ ⚠️ 关键：所有 UserDefaults 读取都必须在 applicationDidFinishLaunching 中延迟恢复！
        // 绝对不能在任何单例 init() 中读 UserDefaults，macOS 26+ 会触发 _CFXPreferences
        // 隐式递归导致主线程栈溢出崩溃（EXC_BAD_ACCESS SIGSEGV, 174K 层递归）
        // macOS 26.5 beta 上这个问题更加严格，即使 @AppStorage 属性包装器 init 也会触发
        //
        // ⚡ 关键优化：先立即显示窗口，所有数据恢复都在下一个 run loop 异步执行
        // 避免主线程阻塞导致布局计算延迟

        // 设置标准菜单栏（包含 Edit 菜单，使 TextField 支持复制粘贴）
        setupMainMenu()

        // 1. 初始化状态栏控制器（轻量级，不阻塞）
        StatusBarController.shared.configure(
            showWindow: { [weak self] in
                self?.showMainWindow()
            },
            quit: { [weak self] in
                self?.quitApplication()
            }
        )

        // 2. 立即创建窗口（使用 defer: false 立即渲染，不等待）
        let contentView = ContentView()
            .frame(
                minWidth: Self.minimumWindowSize.width,
                minHeight: Self.minimumWindowSize.height
            )

        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultWindowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window?.collectionBehavior = .fullScreenPrimary

        window?.title = "WaifuX"
        window?.titlebarAppearsTransparent = true
        window?.titleVisibility = .hidden

        // 隐藏系统红绿灯（使用自定义 CustomWindowControls）
        window?.standardWindowButton(.closeButton)?.isHidden = true
        window?.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window?.standardWindowButton(.zoomButton)?.isHidden = true

        // 设置最小窗口大小
        window?.minSize = Self.minimumWindowSize

        // 设置 contentView
        let hostingView = EdgeToEdgeHostingView(rootView: contentView)
        window?.contentView = hostingView

        // 恢复保存的窗口尺寸
        window?.setFrameAutosaveName(WindowAutosaveName.mainWindow)

        // 首次启动时居中显示
        if !hasSavedWindowFrame() {
            window?.center()
        }

        window?.delegate = self

        // ⚠️ 关键：立即显示窗口，不要等待
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        
        // ⚠️ 关键：让出主线程，让 SwiftUI 完成首次布局渲染
        // 所有数据恢复在下一个 run loop 异步执行
        DispatchQueue.main.async { [weak self] in
            self?.restoreAllDataAsync()
        }
        
        // 注：更新检查已移到 ContentView 中处理
    }
    
    // MARK: - 异步恢复所有数据（在窗口显示后执行，避免阻塞主线程）
    private func restoreAllDataAsync() {
        // ⚠️ 关键：分帧执行，每批数据恢复之间让出时间给主线程渲染 UI
        
        // 第1帧：基础设置
        DispatchQueue.main.async { [weak self] in
            LocalizationService.shared.restoreSavedSettings()
            ThemeManager.shared.restoreSavedSettings()
            
            // 第2帧：权限和库数据
            DispatchQueue.main.async {
                DownloadPathManager.shared.migrateLegacyCustomFolderPreferenceIfNeeded()
                WallpaperLibraryService.shared.restoreSavedData()
                
                // 第3帧：媒体库
                DispatchQueue.main.async {
                    MediaLibraryService.shared.restoreSavedData()
                    
                    // 第4帧：动漫数据
                    DispatchQueue.main.async {
                        AnimeFavoriteStore.shared.restoreSavedData()
                        AnimeProgressStore.shared.restoreSavedData()
                        
                        // 第5帧：播放缓存和任务
                        DispatchQueue.main.async {
                            PlaybackProgressCache.shared.restoreSavedData()
                            DownloadTaskService.shared.restoreSavedTasks()
                            WallpaperSchedulerService.shared.restoreSavedConfig()
                            
                            // 恢复动态壁纸（如果用户之前设置了）
                            VideoWallpaperManager.shared.restoreIfNeeded()
                            if VideoWallpaperManager.shared.currentVideoURL == nil {
                                WallpaperEngineXBridge.shared.restoreIfNeeded()
                            }
                            
                            // 恢复动态壁纸自动暂停设置
                            DynamicWallpaperAutoPauseManager.shared.restoreSettings()
                            
                            // 第6帧：其他状态
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                // 尽早与启动源选择一致：开 VPN 时关闭 GitHub Hosts，避免检查更新/下载仍走固定 IP 绕开隧道
                                if WallpaperSourceManager.shared.shouldDisableGitHubHostsPinning() {
                                    GitHubHosts.isEnabled = false
                                }
                                Task { await GitHubHosts.refreshHosts() }
                                UpdateChecker.shared.restoreCachedState()
                                
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    WallpaperViewModel().restoreAPIKeyState()
                                    WallpaperSourceManager.shared.restoreState()
                                    
                                    // 应用启动时的数据源选择（ping Google 决策）
                                    Task {
                                        await WallpaperSourceManager.shared.performStartupSourceSelection()
                                    }
                                    
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                                        let vm = SettingsViewModel()
                                        vm.restoreSavedSettings()
                                        self?.settingsViewModel = vm
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @MainActor func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // 当用户点击 Dock 图标时显示主窗口
        showMainWindow()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // 备用同步：当应用重新变为活跃时，检查并同步跨 Space 壁纸
        // 因为 activeSpaceDidChangeNotification 在应用后台时可能不可靠
        DesktopWallpaperSyncManager.shared.syncOnAppActivation()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // 最后一个窗口关闭时不退出应用，保持在后台运行（无 Dock 图标）
        return false
    }

    func showMainWindow() {
        updateActivationPolicy(showDockIcon: true)

        if window == nil {
            let contentView = ContentView()
                .frame(
                    minWidth: Self.minimumWindowSize.width,
                    minHeight: Self.minimumWindowSize.height
                )

            // ⚠️ 使用 defer: false 立即显示窗口
            window = NSWindow(
                contentRect: NSRect(origin: .zero, size: Self.defaultWindowSize),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )

            window?.title = "WaifuX"
            window?.titlebarAppearsTransparent = true
            window?.titleVisibility = .hidden
            window?.minSize = Self.minimumWindowSize

            // 隐藏系统红绿灯（使用自定义 CustomWindowControls）
            window?.standardWindowButton(.closeButton)?.isHidden = true
            window?.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window?.standardWindowButton(.zoomButton)?.isHidden = true

            // ⚠️ 先设置 contentView，再恢复保存的窗口尺寸
            let hostingView = EdgeToEdgeHostingView(rootView: contentView)
            window?.contentView = hostingView
            
            // 恢复保存的窗口尺寸
            window?.setFrameAutosaveName(WindowAutosaveName.mainWindow)

            window?.delegate = self
        }

        // 确保窗口显示在最前面
        if let window = window {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            
            // macOS 14+ 需要延迟一点时间来确保窗口正确显示
            if #available(macOS 14.0, *) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    guard let self, let window = self.window else { return }
                    window.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                }
            } else {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    func hideMainWindow() {
        window?.orderOut(nil)
        if !(settingsWindowController?.window?.isVisible ?? false) {
            updateActivationPolicy(showDockIcon: false)
        }
        // 窗口隐藏时异步逐步清理内存，避免卡顿
        Task { @MainActor in
            // 先让窗口动画完成
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1秒
            // 第一步：通知各个 View 清理大内存数据（图片引用等）
            NotificationCenter.default.post(name: .appDidHideWindow, object: nil)
            // 小延迟后再清理缓存
            try? await Task.sleep(nanoseconds: 200_000_000) // 0.2秒
            // 第二步：清理 Kingfisher 内存缓存
            ImageCache.default.clearMemoryCache()
        }
    }

    func quitApplication() {
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 主程序退出时，强制清理所有 wallpaperengine-cli 进程（包括 daemon 和 client）
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-9", "-f", "wallpaperengine-cli"]
        try? pkill.run()
        pkill.waitUntilExit()
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu(title: "MainMenu")

        // App 菜单
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "WaifuX")
        appMenu.addItem(NSMenuItem(title: "About WaifuX", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Hide WaifuX", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit WaifuX", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Edit 菜单（使 TextField 支持 Cmd+C / Cmd+V / Cmd+A 等）
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // Window 菜单
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
    }

    private func updateActivationPolicy(showDockIcon: Bool) {
        let desiredPolicy: NSApplication.ActivationPolicy = showDockIcon ? .regular : .accessory
        if NSApp.activationPolicy() != desiredPolicy {
            NSApp.setActivationPolicy(desiredPolicy)
        }
    }

    // MARK: - 设置窗口
    
    @objc func showSettingsWindow(_ sender: Any?) {
        // 如果窗口已存在，直接显示（最快路径）
        if let settingsWindow = settingsWindowController?.window {
            centerWindow(settingsWindow, relativeTo: window)
            settingsWindow.makeKeyAndOrderFront(nil)
            settingsWindow.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // ⚠️ 先异步初始化 ViewModel，再显示窗口
        Task(priority: .userInitiated) { @MainActor in
            // 如果 SettingsViewModel 尚未初始化，先创建并恢复
            if self.settingsViewModel == nil {
                let vm = SettingsViewModel()
                // 快速恢复基本设置，耗时操作在后台执行
                vm.restoreSavedSettings()
                self.settingsViewModel = vm
            }
            
            // 创建并显示窗口
            self.createAndShowSettingsWindow()
        }
    }
    
    private func createAndShowSettingsWindow() {
        let settingsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        settingsWindow.title = "设置"
        settingsWindow.titlebarAppearsTransparent = true
        settingsWindow.titleVisibility = .hidden
        settingsWindow.standardWindowButton(.closeButton)?.isHidden = true
        settingsWindow.standardWindowButton(.miniaturizeButton)?.isHidden = true
        settingsWindow.standardWindowButton(.zoomButton)?.isHidden = true
        settingsWindow.isMovableByWindowBackground = true
        settingsWindow.backgroundColor = NSColor(Color(hex: "1C1C1E"))
        settingsWindow.setContentSize(NSSize(width: 680, height: 520))
        settingsWindow.minSize = NSSize(width: 680, height: 520)
        settingsWindow.maxSize = NSSize(width: 680, height: 520)
        settingsWindow.isReleasedWhenClosed = false
        centerWindow(settingsWindow, relativeTo: window)
        settingsWindow.tabbingMode = .disallowed
        
        settingsWindow.contentView = EdgeToEdgeHostingView(
            rootView: SettingsView(viewModel: settingsViewModel!)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        )

        let windowController = NSWindowController(window: settingsWindow)
        settingsWindowController = windowController
        windowController.showWindow(nil)
        settingsWindow.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }
    
    private func centerWindow(_ window: NSWindow, relativeTo parentWindow: NSWindow?) {
        if let parentWindow = parentWindow, parentWindow.isVisible {
            // 在主窗口中央显示
            let parentFrame = parentWindow.frame
            let windowSize = window.frame.size
            let x = parentFrame.midX - windowSize.width / 2
            let y = parentFrame.midY - windowSize.height / 2
            window.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            // 屏幕中央显示
            window.center()
        }
    }
}

// MARK: - NSWindowDelegate
extension AppDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // 点击关闭按钮时隐藏窗口而不是退出
        hideMainWindow()
        return false
    }
}

// MARK: - 窗口状态检测
extension AppDelegate {
    /// 检查是否有保存的窗口状态
    private func hasSavedWindowFrame() -> Bool {
        return Self.savedWindowFrame() != nil
    }
    
    /// 获取保存的窗口大小（如果有）
    private static func savedWindowFrame() -> NSSize? {
        let key = "NSWindow Frame \(WindowAutosaveName.mainWindow)"
        guard let frameString = UserDefaults.standard.string(forKey: key) else {
            return nil
        }
        // macOS 保存格式: "x y width height"
        let components = frameString.split(separator: " ")
        guard components.count >= 4,
              let width = Double(components[2]),
              let height = Double(components[3]) else {
            return nil
        }
        return NSSize(width: width, height: height)
    }
}

// MARK: - 自动更新弹窗
struct AutoUpdateSheet: View {
    @ObservedObject var updateChecker = UpdateChecker.shared
    @ObservedObject var updateManager = UpdateManager.shared
    
    let currentVersion: String
    let latestVersion: String
    let release: GitHubRelease
    let commit: GitHubCommit?
    let onClose: () -> Void
    
    var body: some View {
        // 半透明遮罩
        Color.black.opacity(0.5)
            .ignoresSafeArea()
            .overlay {
                // 居中毛玻璃卡片
                VStack(spacing: 20) {
                    // 标题图标
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(Color.accentColor)
                        .modifier(BounceSymbolModifier())
                    
                    // 标题
                    Text(t("newVersionFound"))
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.96))
                    
                    // 版本信息
                    HStack(spacing: 16) {
                        // 当前版本
                        VStack(spacing: 4) {
                            Text(t("currentVersion"))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.5))
                            Text(currentVersion)
                                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.8))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(.white.opacity(0.05))
                        )
                        
                        // 箭头
                        Image(systemName: "arrow.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.3))
                        
                        // 最新版本
                        VStack(spacing: 4) {
                            Text(t("latestVersion"))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.5))
                            Text(latestVersion)
                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color.accentColor)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.accentColor.opacity(0.08))
                        )
                    }
                    
                    // 更新内容
                    if let commit = commit {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(t("updateContent"))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.45))
                            
                            Text(commit.shortMessage)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.white.opacity(0.88))
                                .lineLimit(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            
                            Text(commit.shortSHA)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.35))
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(.white.opacity(0.04))
                        )
                    }
                    
                    // 下载进度
                    if updateManager.state.isDownloading || updateManager.state.isInstalling {
                        VStack(spacing: 8) {
                            LiquidGlassLinearProgressBar(
                                progress: updateManager.progress,
                                height: 6,
                                tintColor: Color.accentColor,
                                trackOpacity: 0.12
                            )
                            
                            HStack {
                                Text(statusText)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.55))
                                Spacer()
                                Text("\(Int(updateManager.progress * 100))%")
                                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.8))
                            }
                        }
                        .padding(.top, 4)
                    }
                    
                    Spacer(minLength: 0)
                    
                    // 按钮行
                    HStack(spacing: 12) {
                        // 取消/关闭按钮
                        Button {
                            if updateManager.state.isDownloading {
                                updateManager.reset()
                            }
                            onClose()
                        } label: {
                            Text(buttonText)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.white.opacity(0.7))
                                .frame(maxWidth: .infinity)
                                .frame(height: 38)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(.white.opacity(0.08))
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(updateManager.state.isInstalling)
                        
                        // 主操作按钮
                        if !updateManager.state.isDownloaded && !updateManager.state.isInstalling {
                            Button {
                                Task {
                                    await updateManager.downloadUpdate(version: latestVersion)
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    if updateManager.state.isDownloading {
                                        ProgressView()
                                            .controlSize(.small)
                                            .scaleEffect(0.8)
                                    }
                                    Text(downloadButtonText)
                                        .font(.system(size: 14, weight: .semibold))
                                }
                                .foregroundStyle(.white.opacity(0.95))
                                .frame(maxWidth: .infinity)
                                .frame(height: 38)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Color.accentColor.opacity(0.3))
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(updateManager.state.isDownloading)
                        } else if updateManager.state.isDownloaded {
                            Button {
                                updateManager.installUpdate()
                            } label: {
                                Text(t("installNow"))
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.95))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 38)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(LiquidGlassColors.onlineGreen.opacity(0.3))
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(24)
                .frame(width: 360, height: 440)
                .background(
                    DarkLiquidGlassBackground(
                        cornerRadius: 20,
                        isHovered: false
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
    }
    
    // MARK: - 辅助属性
    
    private var statusText: String {
        switch updateManager.state {
        case .downloading:
            return t("downloading")
        case .installing:
            return t("installing")
        default:
            return ""
        }
    }
    
    private var buttonText: String {
        switch updateManager.state {
        case .downloading:
            return t("cancel")
        case .installing:
            return t("installing")
        default:
            return t("later")
        }
    }
    
    private var downloadButtonText: String {
        switch updateManager.state {
        case .downloading:
            return t("downloading")
        default:
            return t("updateNow")
        }
    }
}
