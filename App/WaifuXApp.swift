import SwiftUI
import AppKit
import AppIntents
import Kingfisher
import ExceptionHandling
import WebKit
import Darwin
import Sparkle

final class EdgeToEdgeHostingView<Content: View>: NSHostingView<Content> {
    private let edgeToEdgeLayoutGuide = NSLayoutGuide()

    /// macOS 15+ (Sequoia) 的 Liquid Glass 改变了 safe area 行为，
    /// 强制覆盖 safe area 为 0 会与 SwiftUI 布局引擎产生冲突导致振荡。
    private let useLegacySafeAreaOverride: Bool = {
        if #available(macOS 15.0, *) {
            return false
        }
        return true
    }()

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
        useLegacySafeAreaOverride ? bounds : super.safeAreaRect
    }

    override var safeAreaInsets: NSEdgeInsets {
        useLegacySafeAreaOverride ? zeroInsets : super.safeAreaInsets
    }

    override var safeAreaLayoutGuide: NSLayoutGuide {
        useLegacySafeAreaOverride ? edgeToEdgeLayoutGuide : super.safeAreaLayoutGuide
    }

    override var additionalSafeAreaInsets: NSEdgeInsets {
        get { useLegacySafeAreaOverride ? zeroInsets : super.additionalSafeAreaInsets }
        set { if useLegacySafeAreaOverride { /* ignore */ } else { super.additionalSafeAreaInsets = newValue } }
    }
}

@main
struct WaifuXApp {
    #if os(macOS)
    private nonisolated(unsafe) static var memoryPressureSource: DispatchSourceMemoryPressure?
    #endif

    static func main() {
        // 全局忽略 SIGPIPE：AVFoundation 内部管道在快速切换视频壁纸时可能写入已关闭的 pipe，
        // 若不加此保护会导致信号 13 (SIGPIPE) 传递到 NSEventThread 崩溃。
        // 所有自定义 socket 已通过 SO_NOSIGPIPE 独立防护，全局忽略是安全的。
        signal(SIGPIPE, SIG_IGN)

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
        // 内存缓存配置：256MB / 300 张 / 10 分钟过期 / 60 秒一次清理。
        // 壁纸探索页瀑布流可能滚出几百张缩略图，仅靠 totalCostLimit 不够：
        // 没有 expiration + cleanInterval 时，长期不访问的条目仍然驻留，
        // RSS 会持续增长直至触发 macOS 内存压力 → 全量 clearMemoryCache()。
        // 主动 expiration 让长尾图片自然落到磁盘缓存，缓解抖动。
        ImageCache.default.memoryStorage.config.totalCostLimit = 256 * 1024 * 1024 // 256MB
        ImageCache.default.memoryStorage.config.countLimit = 300
        ImageCache.default.memoryStorage.config.expiration = .seconds(10 * 60) // 10 min
        ImageCache.default.memoryStorage.config.cleanInterval = 60             // 60s

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
        // ⚠️ 不设置全局 .backgroundDecode：
        // macOS 上某些图片（16bpc、非 RGB 色彩空间等）在后台解码时 CGContext 创建会失败，
        // 触发 "[Kingfisher] Image context cannot be created." 崩溃。
        // macOS 14+ Core Graphics 已能高效处理离屏渲染，无需全局后台解码。
        KingfisherManager.shared.defaultOptions = [
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
        memoryPressureSource = source
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
    /// Sparkle 自动更新控制器（检测 + 内置弹窗 + 自动安装）
    private var updaterController: SPUStandardUpdaterController!
    /// 静态访问器，供 Settings 等外部触发更新检查
    static var shared: AppDelegate?

    // MARK: - 全局 ViewModel（生命周期与 App 一致）
    /// 这 3 个 ViewModel 由 AppDelegate 持有，传入 ContentView 时用普通 let 引用而非 @StateObject。
    /// 设计目的：避免 ContentView 因 @StateObject 响应 ViewModel 的 @Published 变化而重算 body
    /// （会连锁导致下游 5 个 tab 子视图重建 binding/参数 → 全量重算）。
    /// 同时让 ViewModel 不再随主窗口隐藏/重建而销毁，避免数据重新加载。
    let wallpaperViewModel = WallpaperViewModel()
    let mediaViewModel = MediaExploreViewModel()
    let animeViewModel = AnimeViewModel()

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
        Self.shared = self
        AppResponsivenessMonitor.startIfNeeded()
        AppResponsivenessMonitor.noteScenePhase("didFinishLaunching")
        AppResponsivenessMonitor.noteAppActive(NSApp.isActive)
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

        // 初始化 Sparkle 自动更新（检测 + 内置弹窗 + 自动安装）
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

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

        // ⚠️ 在创建 ContentView 之前刷新功能模块启动快照。
        // ContentView 的 MainTabViewController.configure 在 makeNSViewController（视图设置）即跑，
        // 依赖 ModuleAvailability.shared 决定 addPage 哪些 tab。必须在此之前同步读 UserDefaults。
        // 直接读 UserDefaults 是安全的（非 @AppStorage、非 init 读取，与已存在的 line 316/399 一致）。
        ModuleAvailability.shared.refreshFromUserDefaults()

        // 2. 立即创建窗口（使用 defer: false 立即渲染，不等待）
        let contentView = ContentView(
            wallpaperViewModel: wallpaperViewModel,
            mediaViewModel: mediaViewModel,
            animeViewModel: animeViewModel
        )
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
        window?.isOpaque = true
        window?.backgroundColor = NSColor(Color(hex: "0D0D0D"))
        if #available(macOS 15.0, *) {
            window?.titlebarSeparatorStyle = .none
        }

        // 隐藏系统红绿灯（使用自定义 CustomWindowControls）
        window?.standardWindowButton(.closeButton)?.isHidden = true
        window?.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window?.standardWindowButton(.zoomButton)?.isHidden = true

        // 设置最小窗口大小
        window?.minSize = Self.minimumWindowSize

        // 设置 contentView
        let hostingView = EdgeToEdgeHostingView(rootView: contentView)
        configureOpaqueHostingView(hostingView)
        window?.contentView = hostingView

        // 恢复保存的窗口尺寸
        window?.setFrameAutosaveName(WindowAutosaveName.mainWindow)

        // 首次启动时居中显示
        if !hasSavedWindowFrame() {
            window?.center()
        }

        window?.delegate = self

        // 开机启动时不显示主窗口，仅后台运行（状态栏 + 动态壁纸自动应用）
        let isLoginLaunch = UserDefaults.standard.bool(forKey: "launch_at_login")
        if isLoginLaunch {
            // 窗口已创建但保持隐藏，用户可通过 Dock 图标或状态栏菜单显示
            // 动态壁纸恢复在 restoreAllDataAsync 中完成
            // 设置激活策略为 .accessory（无 Dock 图标和菜单栏）
            NSApp.setActivationPolicy(.accessory)
            AppResponsivenessMonitor.noteWindowVisible(false)
            AppResponsivenessMonitor.noteScenePhase("loginLaunchHidden")
        } else {
            // ⚠️ 关键：立即显示窗口，不要等待
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            AppResponsivenessMonitor.noteWindowVisible(true)
            AppResponsivenessMonitor.noteScenePhase("mainWindowVisible")
        }

        // ⚠️ 关键：让出主线程，让 SwiftUI 完成首次布局渲染
        // 所有数据恢复在下一个 run loop 异步执行
        DispatchQueue.main.async { [weak self] in
            self?.restoreAllDataAsync()
        }

        // 预先在后台线程解压内嵌 assets（wallpaper-wgpu 渲染依赖），避免首次设置壁纸时阻塞主线程
        WallpaperEngineEmbeddedAssets.prepareAssetsInBackground()

        // Sparkle 自动按 SUScheduledCheckInterval (24h) 检查更新，无需手动触发
    }

    /// 触发 Sparkle 更新检查（供 Settings "检查更新" 按钮调用）
    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    // MARK: - 异步恢复所有数据（在窗口显示后执行，避免阻塞主线程）
    private func restoreAllDataAsync() {
        // ⚠️ 关键：分帧执行，每批数据恢复之间让出时间给主线程渲染 UI

        // 第1帧：基础设置
        DispatchQueue.main.async { [weak self] in
            if #available(macOS 26.0, *) {
                // ⚠️ 延迟到窗口显示后执行，避免启动卡死；在主线程执行避免后台线程调用
                // Bundle/FileManager/NSWorkspace 等非线程安全 API 触发崩溃
                self?.repairWallpaperExtensionRegistration()
            }

            LocalizationService.shared.restoreSavedSettings()
            ThemeManager.shared.restoreSavedSettings()

            // 第2帧：权限和库数据
            DispatchQueue.main.async {
                DownloadPathManager.shared.migrateLegacyCustomFolderPreferenceIfNeeded()
                WorkshopSourceManager.shared.refreshStoredSteamCredentials()
                WorkshopSourceManager.shared.loadSteamProfileID()
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

                            // 启动锁屏扩展 Socket IPC 服务端（仅 macOS 26+）
                            if #available(macOS 26.0, *) {
                                WallpaperExtensionSocketServer.shared.start()
                                LockScreenWallpaperService.shared.syncInstanceCatalogToSocketServer()
                                // 通知旧扩展进程退出，macOS WallpaperAgent 从新 bundle 重新加载
                                WallpaperExtensionSocketServer.shared.notifyExtensionReload()
                            }

                            // 恢复刘海隐藏设置（纯 UI 覆盖层，不依赖壁纸）
                            let notchHidden = UserDefaults.standard.bool(forKey: "hide_notch")
                            if notchHidden {
                                NotchOverlayManager.shared.setEnabled(true)
                            }

                            // 恢复动态壁纸（如果用户之前设置了）
                            if WallpaperEngineXBridge.shared.hasPersistedRestoreState() {
                                Task { await WallpaperEngineXBridge.shared.restoreIfNeeded() }
                            } else {
                                VideoWallpaperManager.shared.restoreIfNeeded()
                                if !VideoWallpaperManager.shared.isVideoWallpaperActive {
                                    Task { await WallpaperEngineXBridge.shared.restoreIfNeeded() }
                                }
                            }

                            // 恢复静态壁纸 overlay（系统壁纸同步关闭时，用 overlay 重新显示上次静态图）
                            StaticImageWallpaperOverlayManager.shared.restoreIfNeeded()

                            // 恢复动态壁纸自动暂停设置
                            DynamicWallpaperAutoPauseManager.shared.restoreSettings()

                            // 初始化静态壁纸颗粒蒙层（独立于壁纸设置，开关实时生效）
                            StaticWallpaperGrainManager.shared.updateOverlay()

                            // 初始化液态玻璃时钟 Overlay（桌面壁纸时钟，Metal 渲染）
                            // 配置持久化由 LiquidGlassClockSettings 自动管理
                            LiquidGlassClockOverlayManager.shared.refreshAll()

                            // 第6帧：其他状态
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                // Sparkle 自动处理更新检查，无需手动恢复缓存状态

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
        AppResponsivenessMonitor.noteAppActive(true)
        AppResponsivenessMonitor.noteScenePhase("didBecomeActive")
        AppResponsivenessMonitor.noteForegroundActivation(reason: "applicationDidBecomeActive")
        guard !isDynamicWallpaperRendering else { return }
        // 备用同步：当应用重新变为活跃时，检查并同步跨 Space 壁纸
        // 因为 activeSpaceDidChangeNotification 在应用后台时可能不可靠
        DesktopWallpaperSyncManager.shared.syncOnAppActivation()
    }

    func applicationDidResignActive(_ notification: Notification) {
        AppResponsivenessMonitor.noteAppActive(false)
        AppResponsivenessMonitor.noteScenePhase("didResignActive")
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
            let contentView = ContentView(
                wallpaperViewModel: wallpaperViewModel,
                mediaViewModel: mediaViewModel,
                animeViewModel: animeViewModel
            )
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
            window?.isOpaque = true
            window?.backgroundColor = NSColor(Color(hex: "0D0D0D"))
            window?.minSize = Self.minimumWindowSize

            // 隐藏系统红绿灯（使用自定义 CustomWindowControls）
            window?.standardWindowButton(.closeButton)?.isHidden = true
            window?.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window?.standardWindowButton(.zoomButton)?.isHidden = true

            // ⚠️ 先设置 contentView，再恢复保存的窗口尺寸
            let hostingView = EdgeToEdgeHostingView(rootView: contentView)
            configureOpaqueHostingView(hostingView)
            window?.contentView = hostingView

            // 恢复保存的窗口尺寸
            window?.setFrameAutosaveName(WindowAutosaveName.mainWindow)

            window?.delegate = self
        } else if window?.contentView == nil {
            // 视图树之前已被释放，重新挂载
            let contentView = ContentView(
                wallpaperViewModel: wallpaperViewModel,
                mediaViewModel: mediaViewModel,
                animeViewModel: animeViewModel
            )
                .frame(
                    minWidth: Self.minimumWindowSize.width,
                    minHeight: Self.minimumWindowSize.height
                )
            let hostingView = EdgeToEdgeHostingView(rootView: contentView)
            configureOpaqueHostingView(hostingView)
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
        AppResponsivenessMonitor.noteWindowVisible(true)
        AppResponsivenessMonitor.noteScenePhase("showMainWindow")
    }

    func hideMainWindow() {
        DynamicWallpaperAutoPauseManager.shared.suppressForegroundPauseForMainWindowHide()
        window?.orderOut(nil)
        AppResponsivenessMonitor.noteWindowVisible(false)
        AppResponsivenessMonitor.noteScenePhase("hideMainWindow")

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
        AppResponsivenessMonitor.noteScenePhase("releaseForegroundResources")
        // 窗口隐藏时锁定所有加密文件夹
        FolderLockService.shared.lockAllFolders()

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

    private func configureOpaqueHostingView<Content: View>(_ hostingView: EdgeToEdgeHostingView<Content>) {
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor(Color(hex: "0D0D0D")).cgColor
        hostingView.layer?.isOpaque = true
    }

    func quitApplication() {
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 只清理动态壁纸窗口，不回退到旧静态壁纸
        VideoWallpaperManager.shared.prepareForAppTermination()

        // 通知系统托管的锁屏扩展释放自解码上下文，避免旧扩展进程常驻。
        if #available(macOS 26.0, *) {
            WallpaperExtensionSocketServer.shared.notifyAppWillTerminate()
            WallpaperExtensionSocketServer.shared.clearDisplayVideos()
            WallpaperExtensionSocketServer.shared.stop()
        }

        WallpaperEngineXBridge.shared.prepareForAppTermination()
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

    @available(macOS 26.0, *)
    private func repairWallpaperExtensionRegistration() {
        // 第 1 步：在主线程捕获 Bundle 信息（macOS 26 后台访问 Bundle 会崩溃）
        let appURL = Bundle.main.bundleURL
        let extensionURL = appURL
            .appendingPathComponent("Contents/PlugIns/WaifuXWallpaperExtension.appex", isDirectory: true)
        let fm = FileManager.default

        guard fm.fileExists(atPath: extensionURL.path) else {
            print("[WaifuXApp] Wallpaper extension not found in current bundle: \(extensionURL.path)")
            return
        }

        let currentAppURL = appURL.standardizedFileURL

        // 第 2 步：Process 系统调用派发到后台，不阻塞主线程。
        // 先清理旧注册，再注册当前正在运行的 App/appex，避免 WallpaperAgent 继续命中 Debug/临时构建产物。
        DispatchQueue.global(qos: .utility).async { [appURL, extensionURL, currentAppURL] in
            let staleCandidates = self.computeStaleWallpaperExtensionCandidates(
                currentExtensionURL: extensionURL,
                currentAppURL: currentAppURL
            )

            for candidate in staleCandidates {
                self.runRegistrationTool("/usr/bin/pluginkit", arguments: ["-r", candidate.path], label: "pluginkit remove")
                self.unregisterBundleWithLaunchServices(candidate)
                if let hostAppURL = self.hostAppURL(forWallpaperExtensionURL: candidate) {
                    self.unregisterBundleWithLaunchServices(hostAppURL)
                }
                print("[WaifuXApp] Removed stale wallpaper extension registration: \(candidate.path)")
            }

            self.registerBundleWithLaunchServices(appURL)
            self.registerBundleWithPlugInKit(extensionURL)
            print("[WaifuXApp] Registered current wallpaper extension: \(extensionURL.path)")

            self.terminateStaleWallpaperExtensionProcessesByPID(currentAppURL: currentAppURL)

            // NSWorkspace 必须在主线程
            DispatchQueue.main.async {
                self.terminateStaleWallpaperExtensionProcesses(currentAppURL: currentAppURL)
            }
        }
    }

    /// 计算需要清理的过期扩展列表。
    /// 只读取当前进程表和 PlugInKit 登记项，避免启动时枚举 `/private/tmp` / build 大目录。
    nonisolated private func computeStaleWallpaperExtensionCandidates(currentExtensionURL: URL, currentAppURL: URL) -> [URL] {
        let candidates = wallpaperExtensionRegistrationCandidates(currentAppURL: currentAppURL)
        return candidates.filter { candidate in
            guard candidate.standardizedFileURL.path != currentExtensionURL.standardizedFileURL.path else {
                return false
            }
            guard FileManager.default.fileExists(atPath: candidate.path) else {
                return true
            }
            return isStaleWaifuXBuildPath(candidate)
        }
    }

    nonisolated private func registerBundleWithLaunchServices(_ url: URL) {
        let tool = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        guard FileManager.default.isExecutableFile(atPath: tool) else { return }
        runRegistrationTool(tool, arguments: ["-f", url.path], label: "lsregister")
    }

    nonisolated private func registerBundleWithPlugInKit(_ url: URL) {
        runRegistrationTool("/usr/bin/pluginkit", arguments: ["-a", url.path], label: "pluginkit add")
    }

    nonisolated private func wallpaperExtensionRegistrationCandidates(currentAppURL: URL) -> [URL] {
        var result: [URL] = []
        var seen = Set<String>()

        func appendCandidate(_ url: URL) {
            let standardized = url.standardizedFileURL
            let path = standardized.path
            guard seen.insert(path).inserted else { return }
            guard wallpaperExtensionBundleID(at: standardized) == "com.waifux.app.wallpaperextension" else {
                return
            }
            if !path.hasPrefix(currentAppURL.path + "/") {
                result.append(standardized)
            }
        }

        for url in runningWallpaperExtensionCandidates() {
            appendCandidate(url)
        }
        for url in plugInKitWallpaperExtensionCandidates() {
            appendCandidate(url)
        }

        return result
    }

    nonisolated private func runningWallpaperExtensionCandidates() -> [URL] {
        let output = processOutput(
            launchPath: "/bin/ps",
            arguments: ["-axo", "command="]
        )

        var result: [URL] = []
        var seen = Set<String>()
        let executableSuffix = "/WaifuXWallpaperExtension.appex/Contents/MacOS/WaifuXWallpaperExtension"

        for line in output.split(separator: "\n") {
            let command = line.trimmingCharacters(in: .whitespaces)
            guard let range = command.range(of: executableSuffix) else { continue }
            let appexPath = String(command[..<range.upperBound])
                .replacingOccurrences(of: "/Contents/MacOS/WaifuXWallpaperExtension", with: "")
            guard seen.insert(appexPath).inserted else { continue }
            result.append(URL(fileURLWithPath: appexPath, isDirectory: true))
        }

        return result
    }

    nonisolated private func plugInKitWallpaperExtensionCandidates() -> [URL] {
        let output = processOutput(
            launchPath: "/usr/bin/pluginkit",
            arguments: ["-m", "-A", "-D", "-v", "-i", "com.waifux.app.wallpaperextension"]
        )

        var result: [URL] = []
        var seen = Set<String>()

        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let markerRange = trimmed.range(of: "/WaifuXWallpaperExtension.appex") else { continue }
            let beforeMarker = trimmed[..<markerRange.lowerBound]
            guard let slashIndex = beforeMarker.lastIndex(of: "/") else { continue }
            let path = String(trimmed[slashIndex..<markerRange.upperBound])
            guard seen.insert(path).inserted else { continue }
            result.append(URL(fileURLWithPath: path, isDirectory: true))
        }

        return result
    }

    nonisolated private func unregisterBundleWithLaunchServices(_ url: URL) {
        let tool = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        guard FileManager.default.isExecutableFile(atPath: tool) else { return }
        runRegistrationTool(tool, arguments: ["-u", url.path], label: "lsregister unregister")
    }

    nonisolated private func hostAppURL(forWallpaperExtensionURL url: URL) -> URL? {
        let plugInsURL = url.deletingLastPathComponent()
        guard plugInsURL.lastPathComponent == "PlugIns" else { return nil }
        let contentsURL = plugInsURL.deletingLastPathComponent()
        guard contentsURL.lastPathComponent == "Contents" else { return nil }
        let appURL = contentsURL.deletingLastPathComponent()
        guard appURL.pathExtension == "app" else { return nil }
        return appURL
    }

    nonisolated private func wallpaperExtensionBundleID(at url: URL) -> String? {
        // ⚠️ 只能在后台线程调用，不能使用 Bundle(url:)（非线程安全）
        let infoURL = url.appendingPathComponent("Contents/Info.plist")
        return (NSDictionary(contentsOf: infoURL) as? [String: Any])?["CFBundleIdentifier"] as? String
    }

    nonisolated private func isStaleWaifuXBuildPath(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        if path.hasPrefix("/private/tmp/") {
            return true
        }
        if path.contains("/Build/Products/Debug/") || path.contains("/Build/Products/Release/") {
            return true
        }
        return false
    }

    private func terminateStaleWallpaperExtensionProcesses(currentAppURL: URL) {
        let currentPrefix = currentAppURL.standardizedFileURL.path + "/"
        // ⚠️ NSWorkspace 只能在主线程访问
        let runningApps = if Thread.isMainThread {
            NSWorkspace.shared.runningApplications
        } else {
            DispatchQueue.main.sync { NSWorkspace.shared.runningApplications }
        }
        let staleApps = runningApps.compactMap { app -> (app: NSRunningApplication, path: String)? in
            guard app.bundleIdentifier == "com.waifux.app.wallpaperextension",
                  let executableURL = app.executableURL?.standardizedFileURL,
                  !executableURL.path.hasPrefix(currentPrefix) else {
                return nil
            }
            return (app, executableURL.path)
        }
        for stale in staleApps {
            let pid = stale.app.processIdentifier
            let sentTerminate = stale.app.terminate()
            let didExit = waitForProcessExit(pid: pid, timeout: 2.0)
            if sentTerminate, didExit {
                print("[WaifuXApp] Terminated stale wallpaper extension process: \(stale.path)")
            } else if sentTerminate {
                let forced = forceKillProcessIfNeeded(pid: pid, label: stale.path)
                print("[WaifuXApp] Stale wallpaper extension required force kill: \(stale.path), forced=\(forced)")
            } else {
                let forced = forceKillProcessIfNeeded(pid: pid, label: stale.path)
                print("[WaifuXApp] Failed to terminate stale wallpaper extension process gracefully: \(stale.path), forced=\(forced)")
            }
        }
    }

    nonisolated private func terminateStaleWallpaperExtensionProcessesByPID(currentAppURL: URL) {
        let currentPrefix = currentAppURL.standardizedFileURL.path + "/"
        let output = processOutput(
            launchPath: "/bin/ps",
            arguments: ["-axo", "pid=,command="]
        )

        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let firstSpace = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }) else { continue }

            let pidText = trimmed[..<firstSpace].trimmingCharacters(in: .whitespaces)
            let command = trimmed[firstSpace...].trimmingCharacters(in: .whitespaces)
            guard let pid = Int32(pidText),
                  command.contains("WaifuXWallpaperExtension.appex/Contents/MacOS/WaifuXWallpaperExtension"),
                  !command.hasPrefix(currentPrefix) else {
                continue
            }

            if kill(pid, SIGTERM) == 0 {
                if waitForProcessExit(pid: pid, timeout: 2.0) {
                    print("[WaifuXApp] Terminated stale wallpaper extension pid=\(pid): \(command)")
                } else {
                    let forced = forceKillProcessIfNeeded(pid: pid, label: command)
                    print("[WaifuXApp] Stale wallpaper extension pid=\(pid) required force kill: forced=\(forced) command=\(command)")
                }
            } else {
                print("[WaifuXApp] Failed to terminate stale wallpaper extension pid=\(pid): errno=\(errno)")
            }
        }
    }

    nonisolated private func waitForProcessExit(pid: pid_t, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while kill(pid, 0) == 0 && Date() < deadline {
            usleep(100_000)
        }
        return kill(pid, 0) != 0
    }

    @discardableResult
    nonisolated private func forceKillProcessIfNeeded(pid: pid_t, label: String) -> Bool {
        guard kill(pid, 0) == 0 else { return true }
        guard kill(pid, SIGKILL) == 0 else {
            print("[WaifuXApp] Failed to SIGKILL stale wallpaper extension pid=\(pid): errno=\(errno) label=\(label)")
            return false
        }
        let didExit = waitForProcessExit(pid: pid, timeout: 1.0)
        if !didExit {
            print("[WaifuXApp] SIGKILL sent but process still present pid=\(pid) label=\(label)")
        }
        return didExit
    }

    nonisolated private func runRegistrationTool(_ launchPath: String, arguments: [String], label: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                print("[WaifuXApp] \(label) exited with status \(process.terminationStatus): \(arguments.joined(separator: " "))")
            }
        } catch {
            print("[WaifuXApp] \(label) failed: \(error.localizedDescription)")
        }
    }

    nonisolated private func processOutput(launchPath: String, arguments: [String]) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            print("[WaifuXApp] \(launchPath) failed: \(error.localizedDescription)")
            return ""
        }
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
        // 设置窗口复用 AppDelegate 作为 delegate，windowShouldClose 据此区分处理
        settingsWindow.delegate = self

        settingsWindow.contentView = EdgeToEdgeHostingView(
            rootView: SettingsView(viewModel: settingsViewModel!)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
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
        // 设置窗口：有待应用的模块改动时弹三选项确认（立即重启/稍后/放弃更改）
        if sender === settingsWindowController?.window {
            return handleSettingsWindowClose(sender)
        }
        // 主窗口：点击关闭按钮时锁定所有加密文件夹并隐藏窗口
        FolderLockService.shared.lockAllFolders()
        hideMainWindow()
        return false
    }

    /// 处理设置窗口关闭：若有待应用的模块开关改动，弹三选项确认。
    /// - 立即重启 → AppRelauncher.relaunch()
    /// - 稍后 → 允许关闭，保留 UserDefaults 改动（下次启动生效）
    /// - 放弃更改 → 回滚三标志到启动快照值后关闭
    @MainActor
    private func handleSettingsWindowClose(_ window: NSWindow) -> Bool {
        guard let vm = settingsViewModel, vm.hasPendingModuleChanges else {
            // 无待应用改动，正常关闭
            settingsWindowController = nil
            return true
        }
        let alert = NSAlert()
        alert.messageText = t("settings.modules.closePending.title")
        alert.informativeText = t("settings.modules.closePending.message")
        alert.alertStyle = .warning
        alert.addButton(withTitle: t("settings.modules.restartNow"))
        alert.addButton(withTitle: t("settings.modules.closePending.later"))
        alert.addButton(withTitle: t("settings.modules.closePending.discard"))
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            // 立即重启
            AppRelauncher.relaunch()
            return false // 不关闭，等 terminate
        case .alertSecondButtonReturn:
            // 稍后：保留改动，关闭窗口
            settingsWindowController = nil
            return true
        default:
            // 放弃更改：回滚后关闭
            vm.discardPendingModuleChanges()
            settingsWindowController = nil
            return true
        }
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
