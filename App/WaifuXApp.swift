import SwiftUI
import AppKit
import AppIntents
import Kingfisher
import ExceptionHandling
import WebKit

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
        let cache = makeSharedURLCache()
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
        let configuration = downloader.sessionConfiguration
        configuration.httpMaximumConnectionsPerHost = 10
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 180
        downloader.sessionConfiguration = configuration
        downloader.downloadTimeout = 60.0
        KingfisherManager.shared.defaultOptions = [
            .backgroundDecode,
            .retryStrategy(DelayRetryStrategy(maxRetryCount: 2, retryInterval: .accumulated(1.0))),
            .requestModifier(AnyModifier { request in
                var request = request
                request.timeoutInterval = max(request.timeoutInterval, 45)
                applyImageRequestHeaders(to: &request)
                return request
            })
        ]
        
        // 设置内存压力处理（使用 DispatchSource）
        #if os(macOS)
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler {
            // 内存紧张时清理所有内存缓存
            ImageCache.default.clearMemoryCache()
            Task { @MainActor in
                VideoThumbnailCache.shared.clearMemoryCache()
                NotificationCenter.default.post(name: .appDidReceiveMemoryPressure, object: nil)
            }
        }
        source.resume()
        #endif
    }

    private static func makeSharedURLCache() -> URLCache {
        let memoryCapacity = 50_000_000
        let diskCapacity = 500_000_000
        let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("WaifuXImageCache", isDirectory: true)

        if let cacheDirectory {
            do {
                try FileManager.default.createDirectory(
                    at: cacheDirectory,
                    withIntermediateDirectories: true
                )
                return URLCache(
                    memoryCapacity: memoryCapacity,
                    diskCapacity: diskCapacity,
                    directory: cacheDirectory
                )
            } catch {
                print("[WaifuXApp] Failed to create URLCache directory at \(cacheDirectory.path): \(error)")
            }
        }

        return URLCache(
            memoryCapacity: memoryCapacity,
            diskCapacity: diskCapacity,
            diskPath: nil
        )
    }

    private static func applyImageRequestHeaders(to request: inout URLRequest) {
        guard let host = request.url?.host?.lowercased() else { return }

        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")

        if host.contains("motionbgs.com") {
            request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
            request.setValue("https://motionbgs.com/", forHTTPHeaderField: "Referer")
        } else if host.contains("wallhaven.cc") {
            request.setValue("https://wallhaven.cc/", forHTTPHeaderField: "Referer")
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow?
    // ⚠️ 延迟初始化 SettingsViewModel，不在 AppDelegate 属性初始化阶段创建
    // 避免其 @Published didSet 在 applicationDidFinishLaunching 之前写 UserDefaults
    private var settingsViewModel: SettingsViewModel?
    private var settingsWindowController: NSWindowController?
    /// 窗口隐藏后延迟释放视图树的任务，用于回收 IOSurface / CoreAnimation 等系统图形缓存
    private var delayedReleaseTask: Task<Void, Never>?
    
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

        // 捕获 macOS 布局循环异常（NSHostingView + NSCollectionView 混合布局的已知问题）
        // _postWindowNeedsLayout 在 _layoutViewTree 期间被触发时会抛出此异常
        setupLayoutExceptionHandler()

        // 1. 初始化状态栏控制器（轻量级，不阻塞）
        StatusBarController.shared.configure(
            showWindow: { [weak self] in
                self?.showMainWindow()
            },
            releaseMemory: { [weak self] in
                self?.releaseForegroundMemoryNow()
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

        // 启动探索网格内存监控（800MB / 150 entries 阈值，触发 LRU trim）
        // ⚠️ 必须异步启动，禁止在 init 路径或 applicationDidFinishLaunching 同步调用，
        // 避免触发 macOS 26 _CFXPreferences 隐式递归
        DispatchQueue.main.async {
            // ExploreGridMemoryMonitor 已移除，Kingfisher 管理自己的缓存
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
                WorkshopSourceManager.shared.refreshStoredSteamCredentials()
                WallpaperLibraryService.shared.restoreSavedData()
                LibraryFolderStore.shared.restoreSavedData()
                
                // 第3帧：媒体库
                DispatchQueue.main.async {
                    MediaLibraryService.shared.restoreSavedData()
                    
                    // 第4帧：动漫数据
                    DispatchQueue.main.async {
                        AnimeFavoriteStore.shared.restoreSavedData()
                        AnimeProgressStore.shared.restoreSavedData()
                        
                        // 第4.5帧：恢复未完成迁移 + 修复孤儿路径
                        DispatchQueue.main.async {
                            Task {
                                await DirectoryMigrationService.shared.recoverIncompleteMigrationIfNeeded()
                                await DirectoryMigrationService.shared.repairOrphanedPathsIfNeeded()
                            }
                        }
                        
                        // 第5帧：播放缓存和任务
                        DispatchQueue.main.async {
                            PlaybackProgressCache.shared.restoreSavedData()
                            DownloadTaskService.shared.restoreSavedTasks()
                            WallpaperSchedulerService.shared.restoreSavedConfig()
                            
                            // 恢复动态壁纸（如果用户之前设置了）
                            VideoWallpaperManager.shared.restoreIfNeeded()
                            if !VideoWallpaperManager.shared.isVideoWallpaperActive {
                                WallpaperEngineXBridge.shared.restoreIfNeeded()
                            }
                            
                            // 恢复动态壁纸自动暂停设置
                            DynamicWallpaperAutoPauseManager.shared.restoreSettings()

                            // 初始化静态壁纸颗粒蒙层（独立于壁纸设置，开关实时生效）
                            StaticWallpaperGrainManager.shared.updateOverlay()
                            
                            // 第6帧：其他状态
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
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
        guard !isDynamicWallpaperRendering else { return }
        // 备用同步：当应用重新变为活跃时，检查并同步跨 Space 壁纸
        // 因为 activeSpaceDidChangeNotification 在应用后台时可能不可靠
        DesktopWallpaperSyncManager.shared.syncOnAppActivation()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // 最后一个窗口关闭时不退出应用，保持在后台运行（无 Dock 图标）
        return false
    }

    func showMainWindow() {
        // 取消待执行的延迟释放，避免重新打开窗口后视图树被意外清空
        delayedReleaseTask?.cancel()
        delayedReleaseTask = nil

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
        } else if window?.contentView == nil {
            // 视图树之前已被释放，重新挂载
            let contentView = ContentView()
                .frame(
                    minWidth: Self.minimumWindowSize.width,
                    minHeight: Self.minimumWindowSize.height
                )
            let hostingView = EdgeToEdgeHostingView(rootView: contentView)
            window?.contentView = hostingView
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
        DynamicWallpaperAutoPauseManager.shared.suppressForegroundPauseForMainWindowHide()
        window?.orderOut(nil)

        // 主窗口隐藏后尽快卸载前台视图树，后台只保留状态栏、动态壁纸、调度器和下载任务。
        delayedReleaseTask?.cancel()
        delayedReleaseTask = Task { @MainActor in
            // 先让窗口服务器完成 orderOut，避免拆 contentView 时和窗口隐藏动画抢布局。
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }

            if !(self.settingsWindowController?.window?.isVisible ?? false) {
                self.updateActivationPolicy(showDockIcon: false)
            }

            NotificationCenter.default.post(name: .appDidHideWindow, object: nil)
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            guard let window = self.window, !window.isVisible else { return }
            self.releaseForegroundResourcesForHiddenWindow(window)
            self.delayedReleaseTask = nil
        }
    }

    func releaseForegroundMemoryNow() {
        delayedReleaseTask?.cancel()
        delayedReleaseTask = nil

        guard let window else {
            DisplaySelectorManager.shared.cancelForMemoryRelease()
            AnimeWindowManager.shared.closeAllWindowsForMemoryRelease()
            AnimeVideoExtractor.shared.cancel()
            ForegroundPrefetchManager.shared.stopAll()
            KingfisherManager.shared.downloader.cancelAll()
            ImageCache.default.clearMemoryCache()
            VideoThumbnailCache.shared.clearMemoryCache()
            VideoPreloader.shared.clearCache()
            URLCache.shared.removeAllCachedResponses()
            clearWebKitForegroundCaches()
            Task(priority: .utility) {
                // ExploreGridImageLoader 已移除
                await MediaService.shared.clearCache()
                await ContentService.shared.clearCache()
                await NetworkService.shared.clearCache()
                await KazumiRuleLoader.shared.clearCache()
                await AnimeRuleStore.shared.clearInMemoryCache()
                await RuleLoader.shared.clearInMemoryCache()
                await RuleRepository.shared.clearCache()
            }
            return
        }

        if window.isVisible {
            DynamicWallpaperAutoPauseManager.shared.suppressForegroundPauseForMainWindowHide()
            window.orderOut(nil)
        }

        if !(self.settingsWindowController?.window?.isVisible ?? false) {
            updateActivationPolicy(showDockIcon: false)
        }

        releaseForegroundResourcesForHiddenWindow(window)
    }

    private func releaseForegroundResourcesForHiddenWindow(_ window: NSWindow) {
        NotificationCenter.default.post(name: .appShouldReleaseForegroundMemory, object: nil)
        DisplaySelectorManager.shared.cancelForMemoryRelease()
        AnimeWindowManager.shared.closeAllWindowsForMemoryRelease()
        AnimeVideoExtractor.shared.cancel()

        // 释放视图树是回收系统图形缓存（IOSurface、CALayer backing store）的关键。
        // 只清前台浏览/预览缓存；动态壁纸渲染、调度器、下载任务和状态栏继续运行。
        ForegroundPrefetchManager.shared.stopAll()
        KingfisherManager.shared.downloader.cancelAll()
        autoreleasepool {
            window.contentView = nil
        }

        PreviewWindowManager.shared.closePreview()
        ImageCache.default.clearMemoryCache()
        VideoThumbnailCache.shared.clearMemoryCache()
        VideoPreloader.shared.clearCache()
        LocalWallpaperScanner.shared.clearInMemoryCache()
        WorkshopService.shared.clearForegroundState()
        URLCache.shared.removeAllCachedResponses()
        clearWebKitForegroundCaches()

        Task(priority: .utility) {
            // ExploreGridImageLoader 已移除
            await MediaService.shared.clearCache()
            await ContentService.shared.clearCache()
            await NetworkService.shared.clearCache()
            await KazumiRuleLoader.shared.clearCache()
            await AnimeRuleStore.shared.clearInMemoryCache()
            await RuleLoader.shared.clearInMemoryCache()
            await RuleRepository.shared.clearCache()
        }
    }

    private func clearWebKitForegroundCaches() {
        let cacheTypes: Set<String> = [
            WKWebsiteDataTypeMemoryCache,
            WKWebsiteDataTypeDiskCache
        ]

        WKWebsiteDataStore.default().removeData(
            ofTypes: cacheTypes,
            modifiedSince: .distantPast
        ) {
            print("[WaifuXApp] WebKit foreground caches cleared")
        }
    }

    private var isDynamicWallpaperRendering: Bool {
        VideoWallpaperManager.shared.isVideoWallpaperActive ||
        WallpaperEngineXBridge.shared.isControllingExternalEngine
    }

    func quitApplication() {
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 只清理动态壁纸窗口，不回退到旧静态壁纸
        VideoWallpaperManager.shared.prepareForAppTermination()

        // 主程序退出时，强制清理所有 wallpaperengine-cli 进程（包括 daemon 和 client）
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-9", "-f", "wallpaperengine-cli"]
        try? pkill.run()
        pkill.waitUntilExit()
    }

    /// 捕获 macOS 窗口布局循环异常。
    /// 当 NSHostingView（SwiftUI）和 NSCollectionView（AppKit）混合布局时，
    /// 窗口的 _layoutViewTree 可能触发 _postWindowNeedsLayout 导致无限布局循环崩溃。
    /// NSExceptionHandler 只能记录日志，无法真正抑制异常（异常仍会被重新抛出）。
    /// 真正的修复应确保所有 UI 操作都在主线程执行。
    private func setupLayoutExceptionHandler() {
        // 设置未捕获异常处理器，仅用于日志记录
        NSSetUncaughtExceptionHandler { exception in
            if exception.name.rawValue == "NSGenericException",
               let reason = exception.reason,
               reason.contains("Layout Window") {
                AppLogger.error(.general, "检测到窗口布局循环异常（未捕获）: \(reason)")
            }
        }

        // NSExceptionHandler 用于在异常传播过程中记录日志
        guard let handler = NSExceptionHandler.default() else { return }
        handler.setDelegate(LayoutExceptionHandlerDelegate.shared)
        let mask = NSLogOtherExceptionMask | NSHandleOtherExceptionMask
            | NSLogUncaughtExceptionMask | NSHandleUncaughtExceptionMask
            | NSHandleUncaughtSystemExceptionMask
        handler.setExceptionHandlingMask(mask)
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

// MARK: - 布局异常处理代理

/// 记录 macOS 窗口布局循环异常（_postWindowNeedsLayout）。
/// 当 NSHostingView 和 NSCollectionView 混合布局时，窗口的 _layoutViewTree
/// 可能触发 _postWindowNeedsLayout 导致 NSGenericException 崩溃。
/// 注意：NSExceptionHandler 只能观察和记录，无法真正抑制异常传播。
/// 异常仍会被重新抛出并导致崩溃。真正的修复需确保 UI 操作在主线程执行。
/// NSExceptionHandlerDelegate 是 NSObject 的 category（非正式协议），
/// 直接在 NSObject 子类上实现方法即可，无需协议声明。
private final class LayoutExceptionHandlerDelegate: NSObject, @unchecked Sendable {
    static let shared = LayoutExceptionHandlerDelegate()

    /// 记录布局循环异常
    @objc override func exceptionHandler(
        _ sender: NSExceptionHandler,
        shouldHandle exception: NSException,
        mask: Int
    ) -> Bool {
        if exception.name.rawValue == "NSGenericException",
           let reason = exception.reason,
           reason.contains("Layout Window") {
            AppLogger.error(.general, "窗口布局循环异常: \(reason)")
        }
        return true
    }

    /// 控制布局循环异常的日志记录
    @objc override func exceptionHandler(
        _ sender: NSExceptionHandler,
        shouldLogException exception: NSException,
        mask: Int
    ) -> Bool {
        if exception.name.rawValue == "NSGenericException",
           let reason = exception.reason,
           reason.contains("Layout Window") {
            return false
        }
        return true
    }
}
