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

        // 2. ⚠️ 延迟恢复更新检查器缓存状态（读取 UserDefaults）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            UpdateChecker.shared.restoreCachedState()
        }

        // 3. 恢复 API Key 状态（必须在 WallpaperViewModel 使用之前）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            WallpaperViewModel().restoreAPIKeyState()
        }

        let contentView = ContentView()
            .frame(minWidth: 900, minHeight: 600)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window?.title = "WaifuX"
        window?.titlebarAppearsTransparent = true
        window?.titleVisibility = .hidden

        // 设置最小窗口大小
        window?.minSize = NSSize(width: 900, height: 600)

        // 使用无边框托管视图
        let hostingView = EdgeToEdgeHostingView(rootView: contentView)
        window?.contentView = hostingView

        window?.delegate = self

        setupToolbar()

        window?.center()

        // 初始隐藏 Dock 图标（启动后不显示在 Dock）
        updateActivationPolicy(showDockIcon: false)

        // ⚠️ 延迟检查更新（等所有状态恢复完成后）
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.checkForUpdatesOnLaunch()
        }
    }

    func applicationShouldHandleReopening(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if flag {
            window?.makeKeyAndOrderFront(nil)
        } else {
            showMainWindow()
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // 最后一个窗口关闭时不退出应用，保持在后台运行（无 Dock 图标）
        return false
    }

    private func setupToolbar() {
        guard let window = window else { return }

        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.showsBaselineSeparator = false

        window.toolbar = toolbar
        window.toolbarStyle = .unified
    }

    func showMainWindow() {
        updateActivationPolicy(showDockIcon: true)

        if window == nil {
            let contentView = ContentView()
                .frame(minWidth: 900, minHeight: 600)

            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )

            window?.title = "WaifuX"
            window?.titlebarAppearsTransparent = true
            window?.titleVisibility = .hidden
            window?.minSize = NSSize(width: 900, height: 600)

            let hostingView = EdgeToEdgeHostingView(rootView: contentView)
            window?.contentView = hostingView

            window?.delegate = self
            setupToolbar()
            window?.center()
        }

        // 检查窗口是否被最小化
        if let window = window {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }

            // 检查窗口是否可见且是 key window
            if #available(macOS 14.0, *) {
                if !window.isVisible || !window.isKeyWindow {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        guard let self, let window = self.window else { return }
                        window.makeKeyAndOrderFront(nil)
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
            } else {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        } else {
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
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

    /// 显示更新弹窗（液态玻璃风格，自动下载）
    private func showUpdateDialog(latest: GitHubRelease, commit: GitHubCommit?) {
        // 先显示主窗口
        showMainWindow()
        
        let currentVersion = UpdateChecker.shared.currentVersion
        
        // 创建自定义弹窗
        let alert = NSAlert()
        alert.messageText = "发现新版本"
        
        // 构建弹窗内容
        var content = "当前版本: \(currentVersion)\n最新版本: \(latest.version)\n"
        
        if let commit = commit {
            content += "\n📌 \(commit.shortMessage)"
        }
        
        alert.informativeText = content
        alert.addButton(withTitle: "立即更新")
        alert.addButton(withTitle: "稍后")
        
        // 自定义液态玻璃样式
        let window = alert.window
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 0.8)
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.cornerRadius = 12
        window.contentView?.layer?.masksToBounds = true
        
        // 添加毛玻璃背景
        if #available(macOS 10.14, *) {
            let visualEffectView = NSVisualEffectView()
            visualEffectView.blendingMode = .behindWindow
            visualEffectView.material = .hudWindow
            visualEffectView.state = .active
            visualEffectView.frame = window.contentView!.bounds
            visualEffectView.autoresizingMask = [.width, .height]
            window.contentView?.addSubview(visualEffectView, positioned: .below, relativeTo: nil)
        }
        
        // 异步显示弹窗（不阻塞主窗口初始化）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            let response = alert.runModal()
            
            if response == .alertFirstButtonReturn {
                // 立即更新 - 显示下载进度弹窗
                self?.showDownloadProgressDialog(latest: latest, commit: commit)
            }
            // 稍后 - 直接关闭，主窗口已显示
        }
    }
    
    /// 显示下载进度弹窗
    private var downloadWindow: NSPanel?
    
    private func showDownloadProgressDialog(latest: GitHubRelease, commit: GitHubCommit?) {
        let currentVersion = UpdateChecker.shared.currentVersion
        
        // 创建进度弹窗
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.backgroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 0.9)
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .floating
        panel.center()
        
        self.downloadWindow = panel
        
        // 创建进度视图
        let progressView = DownloadProgressView(
            currentVersion: currentVersion,
            latestVersion: latest.version,
            onInstall: { [weak self] in
                self?.downloadWindow?.close()
                UpdateManager.shared.installUpdate()
            },
            onCancel: { [weak self] in
                UpdateManager.shared.reset()
                self?.downloadWindow?.close()
            }
        )
        .frame(width: 320, height: 180)
        
        let hostingController = NSHostingController(rootView: progressView)
        panel.contentViewController = hostingController
        panel.makeKeyAndOrderFront(nil)
        
        // 开始下载
        Task {
            await UpdateManager.shared.downloadUpdate(version: latest.version)
        }
    }

    /// 清洗 Release body 内容，过滤掉 commit hash 等无意义行
    private func cleanReleaseBody(_ body: String?) -> String {
        guard let body = body, !body.isEmpty else {
            return "暂无更新日志"
        }

        let lines = body.components(separatedBy: "\n")
        let cleaned = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return false }
            // 过滤纯 commit hash 行（如 a1b2c3d）
            if trimmed.range(of: "^[a-f0-9]{7,40}$", options: .regularExpression) != nil { return false }
            // 过滤 "Commit: xxxxx" / "SHA: xxxxx" 等 hash 前缀行（CI 自动生成常见格式）
            if trimmed.range(of: "(?i)^(commit|sha|hash|revision)[:\\s]+[a-f0-9]{7,40}", options: .regularExpression) != nil { return false }
            // 过滤 Merge / merge commit 行（通常没有有价值的信息）
            if trimmed.hasPrefix("Merge ") || trimmed.hasPrefix("merge ") || trimmed.hasPrefix("Merged ") { return false }
            // 过滤 CI 自动生成的无意义描述
            if trimmed == "Auto-generated CI build" || trimmed == "Auto-generated release" { return false }
            return true
        }

        let result = cleaned.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? "暂无更新日志" : result
    }

    /// 启动时检查更新
    private func checkForUpdatesOnLaunch() {
        Task {
            let result = await UpdateChecker.shared.checkForUpdates()

            if case .updateAvailable(_, let latest, let commit) = result {
                // 在主线程显示更新弹窗
                await MainActor.run {
                    self.showUpdateDialog(latest: latest, commit: commit)
                }
            }
        }
    }
    
    // MARK: - 设置窗口
    
    @objc func showSettingsWindow(_ sender: Any?) {
        if let settingsWindow = settingsWindowController?.window {
            centerWindow(settingsWindow, relativeTo: window)
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
        centerWindow(settingsWindow, relativeTo: window)
        settingsWindow.tabbingMode = .disallowed
        settingsWindow.contentView = EdgeToEdgeHostingView(
            rootView: SettingsView(viewModel: settingsViewModel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        )

        let windowController = NSWindowController(window: settingsWindow)
        settingsWindowController = windowController
        windowController.showWindow(nil)
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

// MARK: - NSToolbarDelegate
extension AppDelegate: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return []
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return []
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

// MARK: - 下载进度视图
struct DownloadProgressView: View {
    @ObservedObject var updateManager = UpdateManager.shared
    
    let currentVersion: String
    let latestVersion: String
    let onInstall: () -> Void
    let onCancel: () -> Void
    
    var body: some View {
        VStack(spacing: 20) {
            // 标题
            Text("正在下载更新...")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
            
            // 版本信息
            HStack(spacing: 8) {
                Text(currentVersion)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Image(systemName: "arrow.right")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(latestVersion)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.blue)
            }
            
            // 进度条
            VStack(spacing: 8) {
                ProgressView(value: updateManager.progress)
                    .progressViewStyle(LinearProgressViewStyle())
                    .tint(.blue)
                
                HStack {
                    Text(statusText)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(updateManager.progress * 100))%")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 260)
            
            // 按钮
            HStack(spacing: 12) {
                if case .downloaded = updateManager.state {
                    Button("立即安装") {
                        onInstall()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                } else if case .error(let message) = updateManager.state {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                    
                    Button("确定") {
                        onCancel()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Button("取消") {
                        onCancel()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(24)
        .frame(width: 320, height: 180)
        .background(Color.black.opacity(0.8))
    }
    
    private var statusText: String {
        switch updateManager.state {
        case .downloading:
            return "正在下载..."
        case .downloaded:
            return "下载完成"
        case .installing:
            return "正在安装..."
        case .error:
            return "下载失败"
        default:
            return "准备下载..."
        }
    }
}

// MARK: - 自动更新弹窗（保留给 SettingsView 使用）
struct AutoUpdateSheet: View {
    @ObservedObject var updateChecker = UpdateChecker.shared
    @ObservedObject var updateManager = UpdateManager.shared
    
    let currentVersion: String
    let latestVersion: String
    let release: GitHubRelease
    let commit: GitHubCommit?
    let onClose: () -> Void
    
    var body: some View {
        VStack(spacing: 24) {
            // 标题图标
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.blue)
                .symbolEffect(.bounce, options: .repeat(1))
            
            // 标题
            Text("发现新版本")
                .font(.system(size: 20, weight: .bold))
            
            // 版本信息
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Text("当前版本")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Text(currentVersion)
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(4)
                }
                
                HStack(spacing: 8) {
                    Text("最新版本")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Text(latestVersion)
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.15))
                        .foregroundStyle(.blue)
                        .cornerRadius(4)
                }
            }
            
            // 更新内容
            if let commit = commit {
                VStack(alignment: .leading, spacing: 8) {
                    Text("更新内容")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    
                    Text(commit.shortMessage)
                        .font(.system(size: 14))
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    HStack {
                        Text(commit.shortSHA)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
                .padding(12)
                .background(Color.secondary.opacity(0.05))
                .cornerRadius(8)
            }
            
            // 进度条或按钮
            VStack(spacing: 12) {
                if updateManager.state.isDownloading || updateManager.state.isInstalling {
                    // 下载/安装中显示进度条
                    VStack(spacing: 8) {
                        ProgressView(value: updateManager.progress)
                            .progressViewStyle(LinearProgressViewStyle())
                        
                        HStack {
                            Text(statusText)
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(Int(updateManager.progress * 100))%")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                
                // 按钮行
                HStack(spacing: 12) {
                    // 取消/关闭按钮
                    Button {
                        if updateManager.state.isDownloading {
                            // 取消下载
                            updateManager.reset()
                        }
                        // 关闭窗口
                        onClose()
                    } label: {
                        Text(buttonText)
                            .font(.system(size: 14, weight: .medium))
                            .frame(minWidth: 80)
                    }
                    .buttonStyle(.bordered)
                    .disabled(updateManager.state.isInstalling)
                    
                    // 主操作按钮
                    if !updateManager.state.isDownloaded && !updateManager.state.isInstalling {
                        Button {
                            print("[AutoUpdateSheet] 按钮被点击")
                            print("[AutoUpdateSheet] 当前状态: \(updateManager.state)")
                            print("[AutoUpdateSheet] 开始下载版本: \(latestVersion)")
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
                            .frame(minWidth: 120)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(updateManager.state.isDownloading)
                    } else if updateManager.state.isDownloaded {
                        Button {
                            updateManager.installUpdate()
                        } label: {
                            Text("立即安装")
                                .font(.system(size: 14, weight: .semibold))
                                .frame(minWidth: 120)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .frame(width: 280)
        }
        .padding(24)
        .frame(width: 360, height: 420)
        .background(Color.black.opacity(0.8))
    }
    
    // MARK: - 辅助属性
    
    private var statusText: String {
        switch updateManager.state {
        case .downloading:
            return "正在下载..."
        case .installing:
            return "正在安装..."
        default:
            return ""
        }
    }
    
    private var buttonText: String {
        switch updateManager.state {
        case .downloading:
            return "取消"
        case .installing:
            return "安装中..."
        default:
            return "稍后"
        }
    }
    
    private var downloadButtonText: String {
        switch updateManager.state {
        case .downloading:
            return "下载中..."
        default:
            return "立即更新"
        }
    }
}
