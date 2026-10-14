import SwiftUI
import AppKit
import AppIntents
import Kingfisher
import ExceptionHandling
import WebKit
import Darwin
import Sparkle

/// 后台 Helper 连接横幅的挂载位置。
///
/// 横幅是窗口级 overlay，而 `EdgeToEdgeHostingView` 铺满整个窗口、自绘顶栏
/// （红绿灯 + Tabs）就画在最顶部那一条：直接 `overlay(alignment: .top)`
/// 会把横幅压在红绿灯与 Tabs 上面。这里让出顶栏高度，让横幅落在内容区顶部。
private extension View {
    func attachingBackgroundAgentBanner() -> some View {
        overlay(alignment: .top) {
            BackgroundAgentConnectionBanner()
                .padding(.top, MainTopBarLayout.legacyContentTopPadding)
        }
    }
}

/// Coordinates ordinary app windows with the macOS Space that is currently active.
///
/// `.moveToActiveSpace` is intentionally limited to user-facing windows. Desktop
/// wallpaper and overlay windows must keep their existing all-Spaces behavior.
@MainActor
enum WindowSpaceCoordinator {
    static var referenceWindow: NSWindow? {
        if let keyWindow = NSApp.keyWindow, keyWindow.isVisible {
            return keyWindow
        }
        if let mainWindow = NSApp.mainWindow, mainWindow.isVisible {
            return mainWindow
        }
        return nil
    }

    static func prepare(_ window: NSWindow) {
        window.collectionBehavior.insert(.moveToActiveSpace)
    }

    static func show(
        _ window: NSWindow,
        following referenceWindow: NSWindow? = nil,
        activate: Bool = true
    ) {
        // Ordering the reference window first brings its Space active when the
        // caller opened the action from a global menu or the status bar.
        if let referenceWindow,
           referenceWindow !== window,
           referenceWindow.isVisible {
            referenceWindow.makeKeyAndOrderFront(nil)
        }

        prepare(window)
        window.makeKeyAndOrderFront(nil)
        MainWindowVisibility.shared.refresh()
        if activate {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    static func visibleFrame(for referenceWindow: NSWindow? = nil) -> NSRect? {
        let screen = referenceWindow?.screen
            ?? self.referenceWindow?.screen
            ?? NSScreen.main
            ?? NSScreen.screens.first
        return screen?.visibleFrame
    }
}

private func waifuxSignalHandler(_ signo: Int32) {
    AppExitDiagnostics.recordSignal(signo)
    signal(signo, SIG_DFL)
    raise(signo)
}

private func waifuxAtExitHandler() {
    AppExitDiagnostics.record("atexit")
}

enum AppExitDiagnostics {
    nonisolated(unsafe) private static var fd: Int32 = -1

    static func install() {
        openLogIfNeeded()
        record("install", metadata: [
            "pid": getpid(),
            "bundle": Bundle.main.bundleURL.path
        ])

        atexit(waifuxAtExitHandler)
        signal(SIGTERM, waifuxSignalHandler)
        signal(SIGINT, waifuxSignalHandler)
        signal(SIGQUIT, waifuxSignalHandler)
        signal(SIGABRT, waifuxSignalHandler)
        signal(SIGILL, waifuxSignalHandler)
        signal(SIGBUS, waifuxSignalHandler)
        signal(SIGSEGV, waifuxSignalHandler)
    }

    static func record(_ message: String, metadata: [String: Any] = [:]) {
        var parts = metadata.map { "\($0.key)=\($0.value)" }.sorted()
        parts.insert("pid=\(getpid())", at: 0)
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message) | \(parts.joined(separator: ", "))\n"
        write(line)
        AppLogger.error(.general, "Exit diagnostics: \(message)", metadata: metadata)
    }

    nonisolated static func recordSignal(_ signo: Int32) {
        switch signo {
        case SIGTERM:
            writeStatic("signal SIGTERM\n")
        case SIGINT:
            writeStatic("signal SIGINT\n")
        case SIGQUIT:
            writeStatic("signal SIGQUIT\n")
        case SIGABRT:
            writeStatic("signal SIGABRT\n")
        case SIGILL:
            writeStatic("signal SIGILL\n")
        case SIGBUS:
            writeStatic("signal SIGBUS\n")
        case SIGSEGV:
            writeStatic("signal SIGSEGV\n")
        default:
            writeStatic("signal unknown\n")
        }
    }

    private static func openLogIfNeeded() {
        guard fd < 0 else { return }
        var supportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        #if DEBUG
        if BackgroundRuntimeRole.isIsolatedTest,
           let root = ProcessInfo.processInfo.environment["WAIFUX_HELPER_TEST_ROOT"] {
            supportURL = URL(fileURLWithPath: root, isDirectory: true)
        }
        #endif
        let dirURL = supportURL.appendingPathComponent("WaifuX", isDirectory: true)
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        let path = dirURL.appendingPathComponent("waifux-exit.log").path
        fd = Darwin.open(path, O_CREAT | O_WRONLY | O_APPEND, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
    }

    private static func write(_ line: String) {
        openLogIfNeeded()
        guard fd >= 0 else { return }
        line.withCString { pointer in
            _ = Darwin.write(fd, pointer, strlen(pointer))
        }
        _ = Darwin.fsync(fd)
    }

    nonisolated private static func writeStatic(_ message: StaticString) {
        guard fd >= 0 else { return }
        _ = Darwin.write(fd, message.utf8Start, message.utf8CodeUnitCount)
    }
}

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

    // Let the first click both activate an inactive window and reach SwiftUI
    // controls. This matches standard macOS control behavior for the main UI.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
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
        #if DEBUG
        if CommandLine.arguments.contains("--helper-service-diagnostics") {
            MainActor.assumeIsolated {
                let app = NSApplication.shared
                app.setActivationPolicy(.accessory)
                Task { @MainActor in
                    do {
                        let values = try await BackgroundAgentClient.shared.inspectRunningService()
                        let data = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
                        print(String(decoding: data, as: UTF8.self))
                        app.terminate(nil)
                    } catch {
                        print("HELPER_SERVICE_DIAGNOSTICS_FAILED \(error.localizedDescription)")
                        exit(1)
                    }
                }
                app.run()
            }
            return
        }
        if CommandLine.arguments.contains("--helper-ui-exit-probe") {
            MainActor.assumeIsolated {
                guard BackgroundRuntimeRole.isIsolatedTest else { exit(2) }
                let app = NSApplication.shared
                app.setActivationPolicy(.accessory)
                let delegate = HelperUIExitProbeDelegate()
                app.delegate = delegate
                withExtendedLifetime(delegate) { app.run() }
            }
            return
        }
        #endif
        if CommandLine.arguments.contains("--helper-proxy-probe") {
            MainActor.assumeIsolated {
                _ = NSApplication.shared
                _ = WallpaperEngineXBridge.shared
                _ = WallpaperSchedulerService.shared
                _ = DynamicWallpaperAutoPauseManager.shared
                _ = StatusBarController.shared
                _ = LiquidGlassClockOverlayManager.shared
                _ = NotchOverlayManager.shared
                let values = VideoWallpaperManager.shared.backgroundSnapshot()
                precondition(values["nativePlayerCount"] as? Int == 0)
                precondition(values["nativeWindowCount"] as? Int == 0)
                precondition(NSApp.windows.isEmpty)
                precondition(!WallpaperSchedulerService.shared.isRunning)
                print("UI_PROXY_REGRESSION_PASSED players=0 windows=0 scheduler=stopped")
            }
            return
        }
        // keeper CLI 模式：由 LaunchAgent 以 --wallpaper-keeper 常驻运行，
        // 守护壁纸扩展被 pkd 清杀后自动重新拉载（见 WallpaperExtensionKeeper）。
        // 必须在一切 GUI/诊断初始化之前分流，keeper 不进入 App 生命周期。
        if CommandLine.arguments.contains(WallpaperExtensionKeeper.keeperModeArgument) {
            WallpaperExtensionKeeper.run()
            return
        }

        AppExitDiagnostics.install()
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
        // 内存缓存配置：128MB / 512 张 / 15 分钟过期 / 30 秒一次清理。
        // 探索页只显示缩略图；过高的 totalCostLimit 会让 RSS 长期顶在高位。
        // 库网格封面走独立的 LibraryCoverImageCache（LibraryGridCells.swift），
        // 不受详情页大图挤占；这里放宽过期时长，减少切页/返回后的磁盘重解码。
        ImageCache.default.memoryStorage.config.totalCostLimit = 128 * 1024 * 1024 // 128MB
        ImageCache.default.memoryStorage.config.countLimit = 512
        ImageCache.default.memoryStorage.config.expiration = .seconds(15 * 60) // 15 min
        ImageCache.default.memoryStorage.config.cleanInterval = 30             // 30s

        // 磁盘缓存配置
        ImageCache.default.diskStorage.config.sizeLimit = 500 * 1024 * 1024 // 500MB
        ImageCache.default.diskStorage.config.expiration = .days(7)

        // 下载配置
        let downloader = KingfisherManager.shared.downloader
        let configuration = downloader.sessionConfiguration
        // 探索页的可见 cell、图片预取和分页请求共享该下载器；限制并发，
        // 避免快速滚动时大量请求同时占用连接和解码内存。
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 180
        configuration.httpCookieStorage = HTTPCookieStorage.shared
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        // Wallsflow 封面图按出口 IP 被 Cloudflare 挑战（系统代理出口 403、直连放行）；
        // Kingfisher 只有全局 session，无法按 host 配代理 → 用 URLProtocol 给该域名分流。
        // 其他域名不经过这个 protocol，行为不变。
        // 动态桌面封面同理走传输层：服务端截图接口已失效，伪 host 的请求在此转成
        // `DynamicWallpaperPosterService` 的本地抽帧结果（Range 取片 + AVFoundation）。
        configuration.protocolClasses = [
            DynamicWallpaperPosterURLProtocol.self,
            WallsflowDirectURLProtocol.self
        ] + (configuration.protocolClasses ?? [])
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
            LibraryCoverImageCache.imageCache.clearMemoryCache()
            Task { @MainActor in
                VideoThumbnailCache.shared.clearMemoryCache()
                LocalImageThumbnailCache.shared.clearMemoryHints()
                WorkshopLibraryPreviewCache.shared.clearAll()
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

        let isKonachan = host.contains("konachan.net") || host.contains("konachan.com")
        request.setValue(
            isKonachan
                ? KonachanRequestConfiguration.browserUserAgent
                : "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")

        if host.contains("motionbgs.com") {
            request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
            request.setValue("https://motionbgs.com/", forHTTPHeaderField: "Referer")
        } else if host.contains("wallsflow.com") {
            // cloud.wallsflow.com 封面/视频热链保护
            request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
            request.setValue(WallsflowService.siteOrigin, forHTTPHeaderField: "Referer")
        } else if host.contains("wallhaven.cc") {
            request.setValue("https://wallhaven.cc/", forHTTPHeaderField: "Referer")
        } else if host.contains("pximg.net") {
            request.setValue("https://www.pixiv.net/", forHTTPHeaderField: "Referer")
        } else if isKonachan {
            request.setValue(
                KonachanRequestConfiguration.referer(for: request.url),
                forHTTPHeaderField: "Referer"
            )
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, @preconcurrency SPUStandardUserDriverDelegate, @preconcurrency SPUUpdaterDelegate {
    var window: NSWindow?
    // ⚠️ 延迟初始化 SettingsViewModel，不在 AppDelegate 属性初始化阶段创建
    // 避免其 @Published didSet 在 applicationDidFinishLaunching 之前写 UserDefaults
    private var settingsViewModel: SettingsViewModel?
    private var settingsWindowController: NSWindowController?
    private var uiRequestRouter = WaifuXUIActions.RequestRouter()
    private var mainWindowDataRestored = false
    /// 窗口隐藏后延迟释放视图树的任务，用于回收 IOSurface / CoreAnimation 等系统图形缓存
    private var delayedReleaseTask: Task<Void, Never>?
    /// Sparkle 自动更新控制器（检测 + 内置弹窗 + 自动安装）
    private var updaterController: SPUStandardUpdaterController!
    /// 更新检查期间暂时隐藏设置窗口，避免遮挡 Sparkle 的状态或结果窗口。
    private var shouldRestoreSettingsWindowAfterUpdateCheck = false
    /// 静态访问器，供 Settings 等外部触发更新检查
    static var shared: AppDelegate?

    // MARK: - 全局 ViewModel（生命周期与 App 一致）
    /// 这 3 个 ViewModel 由 AppDelegate 持有，传入 ContentView 时用普通 let 引用而非 @StateObject。
    /// 设计目的：避免 ContentView 因 @StateObject 响应 ViewModel 的 @Published 变化而重算 body
    /// （会连锁导致下游 5 个 tab 子视图重建 binding/参数 → 全量重算）。
    /// 同时让 ViewModel 不再随主窗口隐藏/重建而销毁，避免数据重新加载。
    // Settings-only launches and bare-window tests must not initialize feeds.
    lazy var wallpaperViewModel = WallpaperViewModel()
    lazy var mediaViewModel = MediaExploreViewModel()
    lazy var animeViewModel = AnimeViewModel()

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
        installHelperQuitHandlers()
        WaifuXPreferences.shared.loadLegacyPreferences()
        BackgroundAgentClient.shared.start()
        AppResponsivenessMonitor.startIfNeeded()
        AppResponsivenessMonitor.noteScenePhase("didFinishLaunching")
        AppResponsivenessMonitor.noteAppActive(NSApp.isActive)

        // [AnimTracker] 后台 CPU 诊断：动画存活心跳 + 主窗口遮挡状态
        RepeatForeverAnimationTracker.shared.startHeartbeat()
        NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let win = note.object as? NSWindow else { return }
            let state = win.occlusionState.contains(.visible) ? "visible" : "occluded"
            let name = win.title.isEmpty ? (win.identifier?.rawValue ?? "?") : win.title
            AppLogger.error(.general, "[AnimTracker] occlusion \(name) -> \(state)")
        }
        // ⚠️ ⚠️ 关键：所有 UserDefaults 读取都必须在 applicationDidFinishLaunching 中延迟恢复！
        // 绝对不能在任何单例 init() 中读 UserDefaults，macOS 26+ 会触发 _CFXPreferences
        // 隐式递归导致主线程栈溢出崩溃（EXC_BAD_ACCESS SIGSEGV, 174K 层递归）
        // macOS 26.5 beta 上这个问题更加严格，即使 @AppStorage 属性包装器 init 也会触发
        //
        // 在下一个 run loop 恢复设置，然后按请求创建目标窗口。

        // 设置标准菜单栏（包含 Edit 菜单，使 TextField 支持复制粘贴）
        setupMainMenu()

        // 捕获 macOS 布局循环异常（NSHostingView + NSCollectionView 混合布局的已知问题）
        // _postWindowNeedsLayout 在 _layoutViewTree 期间被触发时会抛出此异常
        setupLayoutExceptionHandler()

        // 初始化 Sparkle 自动更新（检测 + 内置弹窗 + 自动安装）
        // 拆架构分发：appcast 每个版本有 arm64 / x86_64 两个 item（sparkle:channel），
        // 这里按当前包架构声明 allowedChannels，Sparkle 只会选中对应架构的更新包。
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )

        // 状态栏由 Helper 持有；UI 只接收明确的窗口/操作请求。
        WaifuXUIActions.handler = { [weak self] action in
            switch action {
            case .main: self?.showMainWindow()
            case .library:
                MainNavigationRequestStore.requestLibraryTab()
                self?.showMainWindow()
            case .wallpaperDetail:
                WaifuXPreferences.shared.synchronize()
                self?.showMainWindow()
                NotificationCenter.default.post(name: .openCurrentWallpaperDetail, object: nil)
            case .settings: self?.showSettingsWindow(nil)
            case .scheduler:
                WaifuXPreferences.shared.set(true, forKey: "settings.openSchedulerOnNextAppearance")
                self?.showSettingsWindow(nil)
                NotificationCenter.default.post(name: .openSchedulerSettings, object: nil)
            case .updates: self?.checkForUpdates()
            case .releaseMemory: self?.releaseForegroundMemoryNow()
            }
        }

        // ⚠️ 在创建 ContentView 之前刷新功能模块启动快照。
        // ContentView 的 MainTabViewController.configure 在 makeNSViewController（视图设置）即跑，
        // 依赖 ModuleAvailability.shared 决定 addPage 哪些 tab。必须在此之前同步读 UserDefaults。
        // 直接读 UserDefaults 是安全的（非 @AppStorage、非 init 读取，与已存在的 line 316/399 一致）。
        ModuleAvailability.shared.refreshFromUserDefaults()

        // Restore preferences after launch, then create only the requested UI.
        // Helper URLs also carry launch arguments, so a late URL event cannot
        // cause the main window to flash during a settings-only cold start.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.restoreAllDataAsync()
            for action in self.uiRequestRouter.start(arguments: CommandLine.arguments) {
                WaifuXUIActions.perform(action)
            }
        }

        // Sparkle 自动按 SUScheduledCheckInterval (24h) 检查更新，无需手动触发
    }

    /// 触发 Sparkle 更新检查（供 Settings "检查更新" 按钮调用）
    func checkForUpdates() {
        if let settingsWindow = settingsWindowController?.window, settingsWindow.isVisible {
            shouldRestoreSettingsWindowAfterUpdateCheck = true
            settingsWindow.orderOut(nil)
        }
        updaterController.checkForUpdates(nil)
    }

    /// Sparkle 按架构分发：只接受与当前包架构一致的 channel。
    /// appcast 中每个版本的 item 带 <sparkle:channel>arm64|x86_64</sparkle:channel>，
    /// 旧版 universal 客户端未声明 channel，会自动忽略所有带 channel 的 item（不会误装错架构包）。
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        [WallpaperEngineAvailability.currentArchitecture]
    }

    /// Share manual/scheduled Sparkle check cycles, then offer component updates in their own window.
    /// Waiting for the app-update session to finish avoids competing update prompts.
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        RendererComponentUpdater.shared.check()
    }

    func standardUserDriverWillShowModalAlert() {
        hideSettingsWindowForUpdateCheck()
    }

    func standardUserDriverDidShowModalAlert() {
        restoreSettingsWindowAfterUpdateCheck()
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard handleShowingUpdate else { return }
        hideSettingsWindowForUpdateCheck()
    }

    func standardUserDriverWillFinishUpdateSession() {
        restoreSettingsWindowAfterUpdateCheck()
    }

    private func hideSettingsWindowForUpdateCheck() {
        guard let settingsWindow = settingsWindowController?.window, settingsWindow.isVisible else { return }
        shouldRestoreSettingsWindowAfterUpdateCheck = true
        settingsWindow.orderOut(nil)
    }

    private func restoreSettingsWindowAfterUpdateCheck() {
        guard shouldRestoreSettingsWindowAfterUpdateCheck else { return }
        shouldRestoreSettingsWindowAfterUpdateCheck = false
        guard let settingsWindow = settingsWindowController?.window else { return }
        WindowSpaceCoordinator.show(settingsWindow)
    }

    // MARK: - 延迟恢复共享 UI 数据；探索页数据在主窗口打开时恢复
    private func restoreAllDataAsync() {
        LocalizationService.shared.restoreSavedSettings()
        ThemeManager.shared.restoreSavedSettings()
        WallpaperLibraryService.shared.restoreSavedData()
        MediaLibraryService.shared.restoreSavedData()
        LibraryFolderStore.shared.restoreSavedData()
        AnimeFavoriteStore.shared.restoreSavedData()
        AnimeProgressStore.shared.restoreSavedData()
        PlaybackProgressCache.shared.restoreSavedData()
        DownloadTaskService.shared.restoreSavedTasks()
        WallpaperSourceManager.shared.restoreState()
        WorkshopSourceManager.shared.refreshStoredSteamIdentity()
        WorkshopSourceManager.shared.loadSteamProfileID()
        if settingsViewModel == nil {
            let vm = SettingsViewModel()
            vm.restoreSavedSettings()
            settingsViewModel = vm
        }
    }

    private func restoreMainWindowDataIfNeeded() {
        guard !mainWindowDataRestored else { return }
        mainWindowDataRestored = true
        wallpaperViewModel.restoreExploreSortPreferences()
        mediaViewModel.restoreExploreSortPreferences()
        wallpaperViewModel.restoreAPIKeyState()
        Task { await WallpaperSourceManager.shared.performStartupSourceSelection() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let request = WaifuXUIActions.Request(url: url) else { continue }
            if let action = uiRequestRouter.receive(request) {
                WaifuXPreferences.shared.synchronize()
                WaifuXUIActions.perform(action)
            }
        }
    }

    @MainActor func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // 当用户点击 Dock 图标时显示主窗口
        showMainWindow()
        return false // The requested window was handled; skip AppKit's default ordering.
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
        if !helperExitInProgress { prepareForInterfaceExit() }
        return true
    }

    private var helperExitInProgress = false
    private var helperExitApproved = false
    private var exitsInterfaceOnly = false
    private var interfaceRelaunchURL: URL?
    private var helperExitGeneration: UInt = 0
    private var helperExitTask: Task<Void, Never>?

    func installHelperQuitHandlers() {
        BackgroundAgentClient.shared.onApplicationQuitRequested = { [weak self] in self?.quitApplication() }
        BackgroundAgentClient.shared.onHelperStopped = { [weak self] in
            // stopped is sent before final worker cleanup and process exit.
            // Follow the normal quit path so the client still confirms exit.
            self?.quitApplication()
        }
    }

    /// Window close and an intentional UI relaunch preserve the background owner.
    func prepareForInterfaceExit() {
        guard !helperExitInProgress else { return }
        exitsInterfaceOnly = true
    }

    func exitInterface() {
        prepareForInterfaceExit()
        NSApp.terminate(nil)
    }

    func relaunchInterface() {
        guard !helperExitInProgress else { return }
        interfaceRelaunchURL = Bundle.main.bundleURL
        markIntentionalTermination(reason: "relaunch")
        AppExitDiagnostics.record("relaunchRequested", metadata: ["bundle": Bundle.main.bundleURL.path])
        exitInterface()
    }

    private func completeUIExit(_ sender: NSApplication) throws {
        guard !helperExitApproved else { return }
        if let bundleURL = interfaceRelaunchURL {
            // The writer has acknowledged the final settings before a new UI
            // can read them. No asynchronous gap separates launch from exit.
            let launcher = Process()
            launcher.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            launcher.arguments = ["-n", bundleURL.path]
            launcher.standardOutput = FileHandle.nullDevice
            launcher.standardError = FileHandle.nullDevice
            try launcher.run()
            interfaceRelaunchURL = nil
            AppExitDiagnostics.record("relaunchTerminate")
        }
        helperExitApproved = true
        sender.terminate(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if helperExitApproved { return .terminateNow }
        guard !helperExitInProgress else { return .terminateCancel }
        helperExitInProgress = true
        helperExitGeneration &+= 1
        let generation = helperExitGeneration
        if !exitsInterfaceOnly { BackgroundAgentClient.shared.beginApplicationQuit() }
        let frontmost = NSWorkspace.shared.frontmostApplication
        let metadata: [String: Any] = [
            "dynamicRendering": isDynamicWallpaperRendering,
            "frontmostApp": frontmost?.localizedName ?? "nil",
            "frontmostBundle": frontmost?.bundleIdentifier ?? "nil",
            "appActive": NSApp.isActive,
            "appHidden": NSApp.isHidden,
            "mainWindowVisible": window?.isVisible ?? false,
            "settingsWindowVisible": settingsWindowController?.window?.isVisible ?? false,
            "decision": "allow",
            "scope": exitsInterfaceOnly ? "interface" : "application"
        ]
        AppExitDiagnostics.record("applicationShouldTerminate", metadata: metadata)
        // Keep the ordinary event loop running while acknowledging queued writes.
        // .terminateLater enters AppKit's modal loop; a programmatic close from
        // a main-queue/concurrency callback can then block both drain and timeout.
        helperExitTask = Task {
            do {
                try await BackgroundAgentClient.shared.drainForUIExit()
                guard generation == helperExitGeneration, !Task.isCancelled else { return }
                if exitsInterfaceOnly {
                    // The Helper can finish this sync after the UI process exits.
                    _ = try? await BackgroundAgentClient.shared.request("cloud.syncOnUIExit")
                }
                guard generation == helperExitGeneration, !Task.isCancelled else { return }
                if !exitsInterfaceOnly {
                    try await BackgroundAgentClient.shared.stopForApplicationQuit()
                }
                guard generation == helperExitGeneration, !Task.isCancelled else { return }
                try completeUIExit(sender)
            } catch { failApplicationQuit(error, generation: generation) }
        }
        Task {
            try? await Task.sleep(for: .seconds(6))
            guard generation == helperExitGeneration, !helperExitApproved else { return }
            failApplicationQuit(NSError(domain: "WaifuXHelper", code: 3,
                userInfo: [NSLocalizedDescriptionKey: exitsInterfaceOnly
                    ? "后台保存设置超时，界面尚未退出"
                    : "后台服务停止超时"]), generation: generation)
        }
        return .terminateCancel
    }

    private func failApplicationQuit(_ error: Error, generation: UInt) {
        guard generation == helperExitGeneration, !helperExitApproved else { return }
        helperExitGeneration &+= 1
        helperExitTask?.cancel()
        helperExitTask = nil
        helperExitInProgress = false
        interfaceRelaunchURL = nil
        BackgroundAgentClient.shared.applicationQuitFailed(error)
        AppLogger.error(.general, "Application quit failed; UI retained", metadata: ["error": error.localizedDescription])
        applicationQuitDidFail()
    }

    func applicationQuitDidFail() {
        showMainWindow()
    }

    func showMainWindow() {
        // 取消待执行的延迟释放，避免重新打开窗口后视图树被意外清空
        delayedReleaseTask?.cancel()
        delayedReleaseTask = nil

        updateActivationPolicy(showDockIcon: true)
        restoreMainWindowDataIfNeeded()

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
            window?.isReleasedWhenClosed = false
            if #available(macOS 15.0, *) {
                window?.titlebarSeparatorStyle = .none
            }
            window?.minSize = Self.minimumWindowSize
            window?.collectionBehavior = .fullScreenPrimary
            if let window {
                WindowSpaceCoordinator.prepare(window)
            }

            // 隐藏系统红绿灯（使用自定义 CustomWindowControls）
            window?.standardWindowButton(.closeButton)?.isHidden = true
            window?.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window?.standardWindowButton(.zoomButton)?.isHidden = true

            // ⚠️ 先设置 contentView，再恢复保存的窗口尺寸
            let hostingView = EdgeToEdgeHostingView(rootView: contentView.defaultAppStorage(WaifuXPreferences.shared).attachingBackgroundAgentBanner())
            configureOpaqueHostingView(hostingView)
            window?.contentView = hostingView

            // 恢复保存的窗口尺寸
            window?.setFrameAutosaveName(WindowAutosaveName.mainWindow)
            if !hasSavedWindowFrame() { window?.center() }

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
            let hostingView = EdgeToEdgeHostingView(rootView: contentView.defaultAppStorage(WaifuXPreferences.shared).attachingBackgroundAgentBanner())
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
                    WindowSpaceCoordinator.show(window)
                }
            } else {
                WindowSpaceCoordinator.show(window)
            }
        }
        AppResponsivenessMonitor.noteWindowVisible(true)
        AppResponsivenessMonitor.noteScenePhase("showMainWindow")
    }

    func hideMainWindow() {
        DynamicWallpaperAutoPauseManager.shared.suppressForegroundPauseForMainWindowHide()
        window?.orderOut(nil)
        MainWindowVisibility.shared.refresh()
        AppResponsivenessMonitor.noteWindowVisible(false)
        AppResponsivenessMonitor.noteScenePhase("hideMainWindow")
        enterBackgroundModeIfNoForegroundInterface(hideDockIcon: true)

        // 主窗口隐藏后尽快卸载前台视图树，后台只保留状态栏、动态壁纸、调度器和下载任务。
        delayedReleaseTask?.cancel()
        delayedReleaseTask = Task { @MainActor in
            // 先让窗口服务器完成 orderOut，避免拆 contentView 时和窗口隐藏动画抢布局。
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }

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
            enterBackgroundModeIfNoForegroundInterface(hideDockIcon: true)
            DisplaySelectorManager.shared.cancelForMemoryRelease()
            AnimeWindowManager.shared.closeAllWindowsForMemoryRelease()
            AnimeVideoExtractor.shared.cancel()
            ForegroundPrefetchManager.shared.stopAll()
            KingfisherManager.shared.downloader.cancelAll()
            ImageCache.default.clearMemoryCache()
            LibraryCoverImageCache.imageCache.clearMemoryCache()
            VideoThumbnailCache.shared.clearMemoryCache()
            LocalImageThumbnailCache.shared.clearMemoryHints()
            WorkshopLibraryPreviewCache.shared.clearAll()
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

        enterBackgroundModeIfNoForegroundInterface(hideDockIcon: true)

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
        LibraryCoverImageCache.imageCache.clearMemoryCache()
        VideoThumbnailCache.shared.clearMemoryCache()
        LocalImageThumbnailCache.shared.clearMemoryHints()
        WorkshopLibraryPreviewCache.shared.clearAll()
        VideoPreloader.shared.clearCache()
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
        exitsInterfaceOnly = false
        BackgroundAgentClient.shared.beginApplicationQuit()
        markIntentionalTermination(reason: "quitApplication")
        AppExitDiagnostics.record("quitApplication")
        NSApp.terminate(nil)
    }

    /// Records application-controlled exits for diagnostics without altering termination policy.
    func markIntentionalTermination(reason: String) {
        AppExitDiagnostics.record("intentionalTerminationMarked", metadata: [
            "reason": reason
        ])
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppExitDiagnostics.record("applicationWillTerminate")
        let children = BackgroundChildProcessCleanup.snapshot()
        SceneOfflineBakeService.stopPreview()
        // UI preview/export workers can still be alive after an asynchronous
        // stop. Keep updater/relaunch tools outside this renderer cleanup.
        let rendererNames: Set<String> = ["wallpaper-wgpu", "wallpaperengine-cli", "wallpaper-video-renderer", "ffmpeg", "dxc", "WaifuXSteamService"]
        BackgroundChildProcessCleanup.terminate(children.filter {
            let name = $0.executableName
            return rendererNames.contains(name) ||
                (name.hasSuffix("-x86_64") && rendererNames.contains(String(name.dropLast(7))))
        })
        BackgroundAgentClient.shared.disconnect()
    }

    /// 捕获 macOS 窗口布局循环异常。
    /// 当 NSHostingView（SwiftUI）和 NSCollectionView（AppKit）混合布局时，
    /// 窗口的 _layoutViewTree 可能触发 _postWindowNeedsLayout 导致无限布局循环崩溃。
    /// NSExceptionHandler 只能记录日志，无法真正抑制异常（异常仍会被重新抛出）。
    /// 真正的修复应确保所有 UI 操作都在主线程执行。
    private func setupLayoutExceptionHandler() {
        // 设置未捕获异常处理器，仅用于日志记录
        NSSetUncaughtExceptionHandler { exception in
            AppExitDiagnostics.record("uncaughtException", metadata: [
                "name": exception.name.rawValue,
                "reason": exception.reason ?? "nil"
            ])
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
        let settingsItem = NSMenuItem(title: t("settings") + "…", action: #selector(showSettingsWindow(_:)), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Hide WaifuX", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let quitItem = NSMenuItem(title: "Quit WaifuX", action: #selector(quitApplicationFromMainMenu(_:)), keyEquivalent: "q")
        quitItem.target = self
        appMenu.addItem(quitItem)
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

    @objc private func quitApplicationFromMainMenu(_ sender: Any?) {
        quitApplication()
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

        // 第 1.5 步：健康闸门（指纹在主线程读取，elected 检查在后台做）。
        // lsregister / pluginkit -a 会更新 LaunchServices 与 pkd 登记，pkd 的标准响应是
        // 终止该扩展的所有运行实例（launchd: "remove all extension instances: caller = pkd"，
        // 2026-09-20 SIGTERM 实锤）。宿主每次启动都无条件修复 = 扩展必死一次，
        // Xcode 反复 Run / 二次启动 / Sparkle 更新重启时表现为扩展被连续杀、锁屏实例假死。
        // 仅当 bundle 指纹变化或登记失去 elected 时才执行修复。指纹 key 与
        // SocketServer 的 extensionReloadFingerprintDefaultsKey 分开，避免写序耦合。
        let fingerprint = WallpaperExtensionSocketServer.embeddedExtensionBundleFingerprint()
        let registrationFingerprintKey = "wallpaper_extension_registration_fingerprint"
        let lastRegisteredFingerprint = WaifuXPreferences.shared.string(forKey: registrationFingerprintKey)

        // 第 2 步：Process 系统调用派发到后台，不阻塞主线程。
        // 先注册当前正在运行的 App/appex，再清理旧注册。
        // 这样即使旧路径文件已不存在（如 brew 更新后移到废纸篓）导致清理失败，
        // 系统也已持有新路径的有效注册，WallpaperAgent 能正常发现扩展。
        DispatchQueue.global(qos: .utility).async { [appURL, extensionURL, currentAppURL, fingerprint, lastRegisteredFingerprint] in
            // —— 健康闸门：bundle 未变且当前副本已被系统选中 → 整体跳过修复 ——
            // （读不到指纹视为异常，走修复路径，宁修勿漏）
            if let fingerprint, fingerprint == lastRegisteredFingerprint,
               self.isExtensionElected(extensionURL: extensionURL) {
                print("[WaifuXApp] Wallpaper extension registration healthy (fingerprint unchanged, elected) — skip repair")
                return
            }

            // Even an update must wait for the current extension instance to
            // leave. Registration can make pkd remove that healthy instance.
            // The healer will register this bundle after the process is gone.
            if WallpaperExtensionKeeper.isExtensionProcessRunning() {
                print("[WaifuXApp] Wallpaper extension still running — defer registration")
                return
            }

            // —— 优先注册当前 bundle ——
            self.registerBundleWithLaunchServices(appURL)
            self.registerBundleWithPlugInKit(extensionURL)
            print("[WaifuXApp] Registered current wallpaper extension: \(extensionURL.path)")

            // —— 再清理过期注册 ——
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

            // —— 选举验证：清理后当前 bundle 的 appex 必须是系统选中（elected）副本 ——
            // 参考 Mirage：pluginkit 可能在数据库里保留指向旧路径的登记或选中其他副本，
            // 导致 WallpaperAgent 加载到错误版本。未当选时重跑一次注册并复查。
            // 不删除其他合法路径的登记（误伤用户另装副本），stale 判定仍由上方逻辑负责。
            self.verifyElectedWallpaperExtensionRegistration(extensionURL: extensionURL)

            self.terminateStaleWallpaperExtensionProcessesByPID(currentAppURL: currentAppURL)

            // NSWorkspace 必须在主线程
            DispatchQueue.main.async {
                self.terminateStaleWallpaperExtensionProcesses(currentAppURL: currentAppURL)
            }

            if let fingerprint {
                WaifuXPreferences.shared.set(fingerprint, forKey: registrationFingerprintKey)
            }
        }
    }

    /// 检查当前 bundle 的扩展是否为 PlugInKit 数据库中选中的（elected）副本。
    /// 只读查询，不触发登记变更；在后台线程调用。
    nonisolated private func isExtensionElected(extensionURL: URL) -> Bool {
        let output = processOutput(
            launchPath: "/usr/bin/pluginkit",
            arguments: ["-m", "-v", "-i", "com.waifux.app.wallpaperextension"]
        )
        return WallpaperExtensionElection.isElected(
            output: output,
            targetPath: extensionURL.standardizedFileURL.path
        )
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
        // brew 更新会先删旧 bundle 再拷新 bundle，macOS 在此过程中会重置扩展的启用状态。
        // pluginkit -a 只注册不启用，必须显式 -e use 才能让 WallpaperAgent 加载扩展。
        runRegistrationTool(
            "/usr/bin/pluginkit",
            arguments: ["-e", "use", "-i", "com.waifux.app.wallpaperextension"],
            label: "pluginkit enable"
        )
    }

    /// 验证当前 bundle 的扩展在 PlugInKit 数据库中被选中（elected）。
    /// 未当选时重跑一次注册后复查，最多重试一次；在后台线程调用。
    nonisolated private func verifyElectedWallpaperExtensionRegistration(extensionURL: URL, attempt: Int = 0) {
        let targetPath = extensionURL.standardizedFileURL.path
        let output = processOutput(
            launchPath: "/usr/bin/pluginkit",
            arguments: ["-m", "-v", "-i", "com.waifux.app.wallpaperextension"]
        )
        guard WallpaperExtensionElection.isElected(output: output, targetPath: targetPath) else {
            if attempt < 1 {
                print("[WaifuXApp] Extension not elected — re-registering: \(targetPath)")
                registerBundleWithPlugInKit(extensionURL)
                Thread.sleep(forTimeInterval: 0.3)
                verifyElectedWallpaperExtensionRegistration(extensionURL: extensionURL, attempt: attempt + 1)
            } else {
                print("[WaifuXApp] ⚠️ Extension still not elected after re-registration. pluginkit output:\n\(output)")
            }
            return
        }
        print("[WaifuXApp] Extension registration verified (elected): \(targetPath)")
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
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("waifux-process-output-\(UUID().uuidString).log")
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        do {
            try Data().write(to: outputURL, options: .withoutOverwriting)
            let outputHandle = try FileHandle(forWritingTo: outputURL)
            defer {
                try? outputHandle.close()
                try? FileManager.default.removeItem(at: outputURL)
            }

            // Do not use Pipe here: waiting for a child to exit before draining a full
            // pipe can deadlock `ps` or `pluginkit` during extension registration.
            process.standardOutput = outputHandle
            process.standardError = outputHandle
            try process.run()
            process.waitUntilExit()
            let data = try Data(contentsOf: outputURL)
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
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

    /// Drop the app's foreground identity once its user-facing windows are gone.
    /// Background wallpaper/render/download services keep running under accessory mode.
    private func enterBackgroundModeIfNoForegroundInterface(hideDockIcon: Bool) {
        let mainWindowVisible = window.map { $0.isVisible && !$0.isMiniaturized } ?? false
        let settingsWindowVisible = settingsWindowController?.window.map {
            $0.isVisible && !$0.isMiniaturized
        } ?? false
        guard !mainWindowVisible, !settingsWindowVisible else { return }

        if hideDockIcon {
            updateActivationPolicy(showDockIcon: false)
        }
        if NSApp.isActive {
            NSApp.deactivate()
        }
    }

    // MARK: - 设置窗口

    @objc func showSettingsWindow(_ sender: Any?) {
        updateActivationPolicy(showDockIcon: true)
        // 如果窗口已存在，直接显示（最快路径）
        if let settingsWindow = settingsWindowController?.window {
            if settingsWindow.isMiniaturized { settingsWindow.deminiaturize(nil) }
            WindowSpaceCoordinator.show(settingsWindow)
            return
        }

        // Run on the main actor without scheduling another task: rapid requests
        // must see the same controller instead of creating multiple windows.
        if settingsViewModel == nil {
            let vm = SettingsViewModel()
            vm.restoreSavedSettings()
            settingsViewModel = vm
        }
        createAndShowSettingsWindow()
    }

    private func createAndShowSettingsWindow() {
        let settingsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        settingsWindow.title = t("settings")
        settingsWindow.titlebarAppearsTransparent = true
        settingsWindow.titleVisibility = .hidden
        settingsWindow.isMovableByWindowBackground = false
        settingsWindow.backgroundColor = NSColor(Color(hex: "1C1C1E"))
        settingsWindow.setContentSize(NSSize(width: 680, height: 520))
        settingsWindow.minSize = NSSize(width: 680, height: 520)
        settingsWindow.maxSize = NSSize(width: 680, height: 520)
        settingsWindow.isReleasedWhenClosed = false
        settingsWindow.level = .normal
        WindowSpaceCoordinator.prepare(settingsWindow)
        settingsWindow.center()
        settingsWindow.tabbingMode = .disallowed
        // 设置窗口复用 AppDelegate 作为 delegate，windowShouldClose 据此区分处理
        settingsWindow.delegate = self

        settingsWindow.contentView = EdgeToEdgeHostingView(
            rootView: SettingsView(viewModel: settingsViewModel!).defaultAppStorage(WaifuXPreferences.shared)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
        )

        let windowController = NSWindowController(window: settingsWindow)
        settingsWindowController = windowController
        windowController.showWindow(nil)
        WindowSpaceCoordinator.show(settingsWindow)
    }

}

#if DEBUG
/// Runs the production close/terminate delegates on an empty AppKit window.
/// Full ContentView startup and real SMAppService registration are excluded.
@MainActor
private final class HelperUIExitProbeDelegate: AppDelegate {
    private var deferredExitObserved = false
    private var previewWorker: Process?

    override func applicationDidFinishLaunching(_ notification: Notification) {
        installHelperQuitHandlers()
        let probeWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 32, height: 32),
                                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
        probeWindow.isReleasedWhenClosed = false
        probeWindow.delegate = self
        window = probeWindow
        Task {
            do {
                if let scenario = ProcessInfo.processInfo.environment["WAIFUX_UI_CLIENT_PROBE_SCENARIO"] {
                    try await runClientLifecycleProbe(scenario, window: probeWindow)
                    return
                }
                try await BackgroundAgentClient.shared.startIsolatedUIExitProbe()
                let operation = ProcessInfo.processInfo.environment["WAIFUX_UI_EXIT_PROBE_CLOUD"]
                if operation == "sync" { await CloudSyncService.shared.sync() }
                if operation == "restore" { await CloudSyncService.shared.restoreFromCloud() }
                if operation != nil {
                    guard CloudSyncService.shared.lastError == nil else {
                        throw CloudSyncService.shared.lastError!
                    }
                    print("UI_CLOUD_PROXY_PASSED operation=\(operation!)")
                }
                let video = VideoWallpaperManager.shared.backgroundSnapshot()
                guard video["nativePlayerCount"] as? Int == 0,
                      video["nativeWindowCount"] as? Int == 0,
                      let value = ProcessInfo.processInfo.environment["WAIFUX_UI_EXIT_PROBE_VALUE"] else {
                    throw CocoaError(.coderInvalidValue)
                }
                print("UI_EXIT_PROBE_CONNECTED pid=\(getpid()) players=0 wallpaperWindows=0")
                if ProcessInfo.processInfo.environment["WAIFUX_UI_QUIT_PROBE_PREVIEW"] == "1" {
                    let worker = Process()
                    worker.executableURL = WaifuXHostBundle.bundleURL.appendingPathComponent("Contents/Resources/Resources/ffmpeg")
                    worker.arguments = ["-hide_banner", "-loglevel", "error", "-re", "-f", "lavfi", "-i", "color=s=32x32:r=1", "-f", "null", "-"]
                    worker.standardOutput = FileHandle.nullDevice
                    worker.standardError = FileHandle.nullDevice
                    try worker.run()
                    previewWorker = worker
                    kill(worker.processIdentifier, SIGSTOP)
                    print("UI_QUIT_PREVIEW_PID=\(worker.processIdentifier)")
                }
                if ProcessInfo.processInfo.environment["WAIFUX_UI_EXIT_PROBE_UNRESPONSIVE_HELPER"] == "1" {
                    try await BackgroundAgentClient.shared.pauseIsolatedHelperForExitProbe()
                    print("UI_EXIT_PROBE_HELPER_PAUSED")
                }
                // Do not wait for this write here: the actual close delegate
                // must drain the queued preference before terminating.
                WaifuXPreferences.shared.set(value, forKey: "regression_ui_exit_ack")
                let action = ProcessInfo.processInfo.environment["WAIFUX_UI_EXIT_PROBE_ACTION"]
                if action == "helper-quit" || action == "helper-stopped" {
                    print("UI_QUIT_PROBE_WAITING_FOR_HELPER")
                    fflush(stdout)
                    return
                }
                fflush(stdout)
                if action == "quit" { quitApplication(); return }
                if action == "main-menu-quit" {
                    guard NSApp.sendAction(Selector(("quitApplicationFromMainMenu:")), to: self, from: nil) else {
                        throw CocoaError(.featureUnsupported)
                    }
                    return
                }
                if action == "terminate" { NSApp.terminate(nil); return }
                if action == "relaunch-interface" { prepareForInterfaceExit(); NSApp.terminate(nil); return }
                if action == "escalate" { probeWindow.performClose(nil); quitApplication(); return }
                // A real close button arrives from AppKit's event loop, outside
                // the currently executing Swift concurrency job.
                if ProcessInfo.processInfo.environment["WAIFUX_UI_EXIT_PROBE_CLOSE_FROM_TASK"] == "1" {
                    probeWindow.performClose(nil)
                } else {
                    DispatchQueue.main.async { probeWindow.performClose(nil) }
                }
            } catch {
                fputs("UI_EXIT_PROBE_FAILED \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
            fputs("UI_EXIT_PROBE_FAILED AppKit termination timed out\n", stderr)
            exit(3)
        }
    }

    private func runClientLifecycleProbe(_ scenario: String, window: NSWindow) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard BackgroundRuntimeRole.isIsolatedTest,
              let root = environment["WAIFUX_HELPER_TEST_ROOT"],
              let value = environment["WAIFUX_UI_EXIT_PROBE_VALUE"] else { throw CocoaError(.featureUnsupported) }
        let directory = URL(fileURLWithPath: root)
        func waitForFile(_ name: String) async throws {
            while !FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) {
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        func installQuitRequest() {
            Task {
                try await waitForFile("client.quit.request")
                quitApplication()
            }
        }
        if scenario == "startup-quit" {
            WaifuXPreferences.shared.set(value, forKey: "regression_client_latest")
            let startup = Task { try await BackgroundAgentClient.shared.startIsolatedUIExitProbe() }
            try await waitForFile("startup.identified.reached")
            let mutation = try BackgroundPropertyList.encode(["key": "regression_client_queued", "value": value,
                "removed": false, "writerID": UUID().uuidString, "sequence": 1])
            BackgroundAgentClient.shared.send("preferences.set", ["mutation": mutation])
            installQuitRequest()
            try Data().write(to: directory.appendingPathComponent("client.ready"))
            try await startup.value
            return
        }
        if scenario == "acknowledged-stop-quit" {
            try await BackgroundAgentClient.shared.startIsolatedUIExitProbe()
            WaifuXPreferences.shared.set(value, forKey: "regression_client_latest")
            BackgroundAgentClient.shared.beginApplicationQuit()
            try await BackgroundAgentClient.shared.drainForUIExit()
            try await BackgroundAgentClient.shared.stopForApplicationQuit()
            print("UI_CLIENT_STOP_ACKNOWLEDGED helperExited=true")
            fflush(stdout)
            NSApp.terminate(nil)
            return
        }
        if scenario == "reset-preflight" || scenario == "reset-timeout" {
            try await BackgroundAgentClient.shared.startIsolatedUIExitProbe()
            WaifuXPreferences.shared.set(value, forKey: "regression_client_latest")
            _ = try await BackgroundAgentClient.shared.request("test.preference", ["key": "regression_client_latest"])
            let sentinel = directory.appendingPathComponent("reset-sentinel.txt")
            try Data(value.utf8).write(to: sentinel)
            if scenario == "reset-timeout" { try await BackgroundAgentClient.shared.pauseIsolatedHelperForExitProbe() }
            let prepared = await SettingsViewModel().prepareForDataReset()
            guard try Data(contentsOf: sentinel) == Data(value.utf8) else { throw CocoaError(.fileReadCorruptFile) }
            if scenario == "reset-timeout" {
                guard !prepared, WaifuXPreferences.shared.string(forKey: "regression_client_latest") == value else { throw CocoaError(.coderInvalidValue) }
                print("UI_RESET_TIMEOUT_PASSED dataUntouched=true")
                try BackgroundAgentClient.shared.resumeIsolatedHelperAfterQuitProbe()
                quitApplication()
            } else {
                guard prepared else { throw CocoaError(.xpcConnectionInvalid) }
                WaifuXPreferences.shared.resetAfterHelperStopped()
                guard WaifuXPreferences.shared.string(forKey: "regression_client_latest") == nil else { throw CocoaError(.coderInvalidValue) }
                print("UI_RESET_PREFLIGHT_PASSED sharedDomainCleared=true")
                NSApp.terminate(nil)
            }
            fflush(stdout)
            return
        }
        guard scenario == "reconnect-replay" || scenario == "reconnect-quit" else { throw CocoaError(.featureUnsupported) }
        try await BackgroundAgentClient.shared.startIsolatedUIExitProbe()
        WaifuXPreferences.shared.set(value + ".old", forKey: "regression_client_latest")
        _ = try await BackgroundAgentClient.shared.request("test.preference", ["key": "regression_client_latest"])
        try BackgroundAgentClient.shared.interruptIsolatedConnectionForProbe()
        WaifuXPreferences.shared.set(value, forKey: "regression_client_latest")
        try await waitForFile("reconnect.identified.reached")
        if scenario == "reconnect-quit" { installQuitRequest() }
        try Data().write(to: directory.appendingPathComponent("client.ready"))
        while !BackgroundAgentClient.shared.isConnected { try await Task.sleep(for: .milliseconds(20)) }
        guard scenario == "reconnect-replay" else { return }
        let saved = try await BackgroundAgentClient.shared.request("test.preference", ["key": "regression_client_latest"])
        guard saved["value"] as? String == value, try WaifuXPreferences.shared.pendingMutationData().isEmpty else {
            throw CocoaError(.coderInvalidValue)
        }
        try BackgroundAgentClient.shared.deliverObsoleteCallbacksForProbe()
        try await Task.sleep(for: .milliseconds(200))
        guard BackgroundAgentClient.shared.isConnected else { throw CocoaError(.xpcConnectionInvalid) }
        print("UI_CLIENT_REPLAY_PASSED latestValue=true acknowledged=true obsoleteCallbacksIgnored=true")
        fflush(stdout)
        window.performClose(nil)
    }

    override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let reply = super.applicationShouldTerminate(sender)
        if reply == .terminateCancel { deferredExitObserved = true }
        return reply
    }

    override func applicationWillTerminate(_ notification: Notification) {
        super.applicationWillTerminate(notification)
        guard deferredExitObserved, !BackgroundAgentClient.shared.isConnected else { exit(4) }
        print("UI_APPKIT_EXIT_PROBE_PASSED deferredExit=true disconnected=true")
        fflush(stdout)
    }

    override func applicationQuitDidFail() {
        guard ProcessInfo.processInfo.environment["WAIFUX_UI_QUIT_PROBE_RETRY"] == "1" else {
            fputs("UI_QUIT_PROBE_FAILED unexpected quit failure\n", stderr)
            exit(5)
        }
        print("UI_QUIT_FAILURE_RETAINS_UI helperStillPaused=true")
        fflush(stdout)
        do {
            try BackgroundAgentClient.shared.resumeIsolatedHelperAfterQuitProbe()
            quitApplication()
        } catch { exit(6) }
    }
}
#endif

// MARK: - NSWindowDelegate
extension AppDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // 设置窗口：有待应用的模块改动时弹三选项确认（立即重启/稍后/放弃更改）
        if sender === settingsWindowController?.window {
            return handleSettingsWindowClose(sender)
        }
        FolderLockService.shared.lockAllFolders()
        if sender === window,
           let settingsWindow = settingsWindowController?.window,
           settingsWindow.isVisible || settingsWindow.isMiniaturized {
            // Closing the library must not tear down an independent settings UI.
            hideMainWindow()
            return false
        }
        exitInterface()
        return true
    }

    func windowDidMiniaturize(_ notification: Notification) {
        guard let minimizedWindow = notification.object as? NSWindow else { return }
        MainWindowVisibility.shared.refresh()
        if minimizedWindow === window {
            DynamicWallpaperAutoPauseManager.shared.suppressForegroundPauseForMainWindowHide()
            AppResponsivenessMonitor.noteWindowVisible(false)
            AppResponsivenessMonitor.noteScenePhase("mainWindowMiniaturized")
        }
        enterBackgroundModeIfNoForegroundInterface(hideDockIcon: false)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        guard let restoredWindow = notification.object as? NSWindow,
              restoredWindow === window else {
            return
        }
        MainWindowVisibility.shared.refresh()
        AppResponsivenessMonitor.noteWindowVisible(true)
        AppResponsivenessMonitor.noteScenePhase("mainWindowDeminiaturized")
    }

    func windowWillClose(_ notification: Notification) {
        // Wait until AppKit has removed the closed window from visibility/key-window state.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.enterBackgroundModeIfNoForegroundInterface(hideDockIcon: self.window?.isMiniaturized != true)
            if self.settingsWindowController == nil,
               self.window?.isVisible != true, self.window?.isMiniaturized != true {
                self.exitInterface()
            }
        }
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
        // 保留系统 NSAlert：此 delegate 必须同步返回是否允许关闭，且关闭设置窗后
        // 主窗口可能已隐藏（托盘模式），应用内玻璃 alert 没有宿主窗口。
        // 玻璃化前置条件：GlassAlertCenter 增加独立悬浮窗宿主后再迁移。
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
        // AppKit owns NSWindow's autosave in the UI's standard defaults domain.
        // The shared Helper domain contains only the one-time migrated value.
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
