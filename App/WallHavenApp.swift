import SwiftUI
import AppKit

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
struct WallHavenApp {
    static func main() {
        // 配置全局 URLCache
        let cache = URLCache(
            memoryCapacity: 100_000_000,  // 100 MB 内存缓存
            diskCapacity: 500_000_000,   // 500 MB 磁盘缓存
            diskPath: "WallHavenImageCache"
        )
        URLCache.shared = cache

        // 配置默认 URLSession 使用缓存
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.urlCache = cache
        URLSession.shared.configuration.urlCache = cache
        URLSession.shared.configuration.requestCachePolicy = .returnCacheDataElseLoad

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow?
    private let settingsViewModel = SettingsViewModel()
    private var settingsWindowController: NSWindowController?
    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureApplicationIcon()

        // 应用主题
        ThemeManager.shared.applyTheme()

        // 初始化数据源配置
        DataSourceProfileStore.initialize()

        let contentView = ContentView()

        // 创建无边框窗口 - 完全自定义标题栏
        // 固定尺寸：1000×800 点（points，自动适配 Retina/非 Retina）
        let windowWidth: CGFloat = 1000
        let windowHeight: CGFloat = 800
        
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window?.title = "WallHaven"
        // 完全隐藏系统标题栏
        window?.titlebarAppearsTransparent = true
        window?.titleVisibility = .hidden
        window?.standardWindowButton(.closeButton)?.isHidden = true
        window?.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window?.standardWindowButton(.zoomButton)?.isHidden = true
        
        // 窗口背景设置为纯色，避免透明导致的边框裂开问题
        window?.isOpaque = true
        window?.backgroundColor = NSColor(Color(hex: "0D0D0D"))
        window?.hasShadow = true
        
        // 设置窗口圆角，避免边缘锯齿
        window?.contentView?.wantsLayer = true
        window?.contentView?.layer?.cornerRadius = 10
        window?.contentView?.layer?.masksToBounds = true
        
        // 启用自动保存 frame，保留用户上次调整的窗口大小
        window?.setFrameAutosaveName("WallHavenMainWindow")
        
        window?.center()
        window?.contentView = EdgeToEdgeHostingView(rootView: contentView)
        window?.delegate = self
        window?.makeKeyAndOrderFront(nil)
        window?.minSize = NSSize(width: 900, height: 600)
        updateActivationPolicy(showDockIcon: true)

        statusBarController = StatusBarController(
            showWindow: { [weak self] in self?.showMainWindow() },
            quit: { NSApp.terminate(nil) }
        )

        // 启动时检查并迁移旧目录文件
        DispatchQueue.main.async {
            let migrationResult = DownloadPathManager.shared.migrateLegacyFiles()
            if migrationResult.success > 0 {
                print("[AppDelegate] Migrated \(migrationResult.success) files to new directory structure")
            }
            if migrationResult.failed > 0 {
                print("[AppDelegate] Failed to migrate \(migrationResult.failed) files")
            }
        }

        // 启动时预加载动漫规则（后台异步）
        Task {
            print("[AppDelegate] 启动时预加载动漫规则...")
            await AnimeRuleStore.shared.ensureDefaultRulesCopied()
            let rules = await AnimeRuleStore.shared.loadAllRules()
            print("[AppDelegate] 预加载完成，共 \(rules.count) 个规则")
            for rule in rules {
                print("[AppDelegate]   - \(rule.name) (\(rule.id))")
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            VideoWallpaperManager.shared.restoreIfNeeded()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showMainWindow()
        }
        return true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender == window {
            hideMainWindow()
            return false
        }
        return true
    }

    private func configureApplicationIcon() {
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let iconImage = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = iconImage
            return
        }

        if let assetIcon = NSImage(named: NSImage.Name("AppIcon")) {
            NSApp.applicationIconImage = assetIcon
        }
    }

    @objc func showSettingsWindow(_ sender: Any?) {
        if let settingsWindow = settingsWindowController?.window {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 620),
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
        settingsWindow.backgroundColor = NSColor(Color(hex: "0D0D0D"))
        settingsWindow.setContentSize(NSSize(width: 800, height: 620))
        settingsWindow.minSize = NSSize(width: 800, height: 620)
        settingsWindow.maxSize = NSSize(width: 800, height: 620)
        settingsWindow.isReleasedWhenClosed = false
        settingsWindow.center()
        settingsWindow.tabbingMode = .disallowed
        settingsWindow.contentView = EdgeToEdgeHostingView(
            rootView: SettingsView(viewModel: settingsViewModel)
        )

        let controller = NSWindowController(window: settingsWindow)
        settingsWindowController = controller
        controller.showWindow(nil)
        updateActivationPolicy(showDockIcon: true)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showMainWindow() {
        guard let window else { return }
        updateActivationPolicy(showDockIcon: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hideMainWindow() {
        window?.orderOut(nil)
        if !(settingsWindowController?.window?.isVisible ?? false) {
            updateActivationPolicy(showDockIcon: false)
        }
    }

    private func updateActivationPolicy(showDockIcon: Bool) {
        let desiredPolicy: NSApplication.ActivationPolicy = showDockIcon ? .regular : .accessory
        if NSApp.activationPolicy() != desiredPolicy {
            NSApp.setActivationPolicy(desiredPolicy)
        }
    }
}
