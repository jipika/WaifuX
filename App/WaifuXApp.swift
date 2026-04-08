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
struct WaifuXApp {
    static func main() {
        // 配置全局 URLCache
        let cache = URLCache(
            memoryCapacity: 100_000_000,  // 100 MB 内存缓存
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
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow?
    private let settingsViewModel = SettingsViewModel()
    private var settingsWindowController: NSWindowController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        // ⚠️ ⚠️ 关键：所有 UserDefaults 读取都必须在 applicationDidFinishLaunching 中延迟恢复！
        // 绝对不能在任何单例 init() 中读 UserDefaults，macOS 26+ 会触发 _CFXPreferences
        // 隐式递归导致主线程栈溢出崩溃（EXC_BAD_ACCESS SIGSEGV, 174K 层递归）
        //
        // 恢复顺序很重要：语言 → 主题 → 下载权限 → 更新缓存

        // 1. 恢复用户语言偏好（必须在 UI 渲染之前）
        LocalizationService.shared.restoreSavedSettings()

        // 2. 恢复主题设置
        ThemeManager.shared.restoreSavedSettings()

        // 3. 恢复下载权限书签
        DownloadPermissionManager.shared.restoreSavedPermission()

        // 4. 恢复更新检查缓存
        UpdateChecker.shared.restoreCachedState()

        // 5. 恢复下载任务列表
        DownloadTaskService.shared.restoreSavedTasks()

        // 6. 恢复壁纸调度配置
        WallpaperSchedulerService.shared.restoreSavedConfig()

        // 7. 恢复动漫收藏数据
        AnimeFavoriteStore.shared.restoreSavedData()

        // 8. 恢复动漫播放进度
        AnimeProgressStore.shared.restoreSavedData()

        // 9. 恢复媒体播放进度缓存
        PlaybackProgressCache.shared.restoreSavedData()

        // 10. 恢复媒体库数据（收藏 + 下载记录）
        MediaLibraryService.shared.restoreSavedData()

        // 11. 恢复壁纸库数据（收藏 + 下载记录）
        WallpaperLibraryService.shared.restoreSavedData()

        // 12. 恢复用户库数据（文件系统存储的收藏/历史/下载）
        UserLibrary.shared.restoreSavedData()

        // 13. ⚠️ 关键：恢复 API Key 状态（必须在 ContentView 创建之前！）
        // WallpaperViewModel 的 canShowNSFW / effectiveAPIKey 在 SwiftUI 渲染时会被调用，
        // 如果不提前缓存 UserDefaults 值，会触发 _CFXPreferences 递归栈溢出
        let wallpaperViewModelForRestore = WallpaperViewModel()
        wallpaperViewModelForRestore.restoreAPIKeyState()

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

        window?.title = "WaifuX"
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

        // 配置状态栏控制器（单例，全局唯一）
        StatusBarController.shared.configure(
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

        // 启动时在后台同步规则：Kazumi 动漫（安装缺失 + 版本更新）+ 已配置的 GitHub 规则仓库
        Task(priority: .utility) {
            print("[AppDelegate] 开始后台规则同步…")

            // 1. 同步 Kazumi 动漫规则
            print("[AppDelegate] 同步 Kazumi 动漫规则…")
            await AnimeRuleStore.shared.syncOnLaunchInBackground()
            let animeRules = await AnimeRuleStore.shared.loadAllRules()
            print("[AppDelegate] 动漫规则同步完成，共 \(animeRules.count) 个")

            // 2. 加载已配置的 GitHub 规则仓库
            print("[AppDelegate] 加载已配置的 GitHub 规则仓库…")
            await RuleRepository.shared.loadConfiguredRepository()
            let wallpaperRules = await RuleLoader.shared.allRules()
            print("[AppDelegate] 壁纸规则加载完成，共 \(wallpaperRules.count) 个")

            print("[AppDelegate] 后台规则同步结束")
        }

        // 启动时检查更新
        Task(priority: .utility) {
            print("[AppDelegate] 开始检查更新…")
            let result = await UpdateChecker.shared.checkForUpdates()
            switch result {
            case .updateAvailable(let current, let latest):
                print("[AppDelegate] 发现新版本：\(latest.version) (当前版本：\(current))")
                // 在主线程显示更新弹窗
                await MainActor.run {
                    showUpdateDialog(latest: latest)
                }
            case .noUpdate(let current):
                print("[AppDelegate] 已是最新版本：\(current)")
            case .error(let message):
                print("[AppDelegate] 更新检查失败：\(message)")
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

    /// 显示更新弹窗
    private func showUpdateDialog(latest: GitHubRelease) {
        let dialog = NSAlert()
        dialog.messageText = "发现新版本"
        dialog.informativeText = "WaifuX \(latest.version) 已发布！\n\n\(latest.body ?? "")"
        dialog.addButton(withTitle: "立即更新")
        dialog.addButton(withTitle: "取消")
        
        // 自定义弹窗样式为液态玻璃风格
        let window = dialog.window
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 0.8)
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.cornerRadius = 12
        window.contentView?.layer?.masksToBounds = true
        
        // 添加模糊效果
        if #available(macOS 10.14, *) {
            let visualEffectView = NSVisualEffectView()
            visualEffectView.blendingMode = .behindWindow
            visualEffectView.material = .hudWindow
            visualEffectView.state = .active
            visualEffectView.frame = window.contentView!.bounds
            visualEffectView.autoresizingMask = [.width, .height]
            window.contentView?.addSubview(visualEffectView, positioned: .below, relativeTo: nil)
        }
        
        let response = dialog.runModal()
        if response == .alertFirstButtonReturn {
            // 打开下载页面
            UpdateChecker.shared.openDownloadPage(for: latest)
        }
    }
}
