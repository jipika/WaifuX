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
    
    // MARK: - 窗口自动保存名称
    private enum WindowAutosaveName {
        static let mainWindow = "WaifuXMainWindow"
    }
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

        // 使用 defer: true 延迟窗口显示，避免先创建默认大小再恢复保存大小产生的缩放动画
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )

        window?.title = "WaifuX"
        window?.titlebarAppearsTransparent = true
        window?.titleVisibility = .hidden

        // 隐藏系统红绿灯（使用自定义 CustomWindowControls）
        window?.standardWindowButton(.closeButton)?.isHidden = true
        window?.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window?.standardWindowButton(.zoomButton)?.isHidden = true

        // 设置最小窗口大小
        window?.minSize = NSSize(width: 900, height: 600)

        // 使用无边框托管视图
        let hostingView = EdgeToEdgeHostingView(rootView: contentView)
        window?.contentView = hostingView

        window?.delegate = self

        // 设置窗口自动保存名称 - macOS 会自动恢复保存的窗口大小和位置
        window?.setFrameAutosaveName(WindowAutosaveName.mainWindow)
        
        // 首次启动时居中显示（没有保存的窗口状态时）
        if !hasSavedWindowFrame() {
            window?.center()
        }

        // 现在显示窗口 - 此时大小已经被 setFrameAutosaveName 恢复好了
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        
        // 注：更新检查已移到 ContentView 中处理
    }

    @MainActor func applicationShouldHandleReopening(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
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

    func showMainWindow() {
        updateActivationPolicy(showDockIcon: true)

        if window == nil {
            let contentView = ContentView()
                .frame(minWidth: 900, minHeight: 600)

            // 使用 defer: true 延迟窗口显示，避免缩放动画
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: true
            )

            window?.title = "WaifuX"
            window?.titlebarAppearsTransparent = true
            window?.titleVisibility = .hidden
            window?.minSize = NSSize(width: 900, height: 600)

            // 隐藏系统红绿灯（使用自定义 CustomWindowControls）
            window?.standardWindowButton(.closeButton)?.isHidden = true
            window?.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window?.standardWindowButton(.zoomButton)?.isHidden = true

            let hostingView = EdgeToEdgeHostingView(rootView: contentView)
            window?.contentView = hostingView

            window?.delegate = self
            
            // 设置窗口自动保存名称 - macOS 会自动恢复保存的窗口大小和位置
            window?.setFrameAutosaveName(WindowAutosaveName.mainWindow)
            
            // 首次启动时居中显示
            if !hasSavedWindowFrame() {
                window?.center()
            }
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
        // macOS 使用 NSWindow Frame <name> 作为键保存窗口状态
        let key = "NSWindow Frame \(WindowAutosaveName.mainWindow)"
        return UserDefaults.standard.object(forKey: key) != nil
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
                        .foregroundStyle(LiquidGlassColors.accentCyan)
                        .symbolEffect(.bounce, options: .repeat(1))
                    
                    // 标题
                    Text("发现新版本")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.96))
                    
                    // 版本信息
                    HStack(spacing: 16) {
                        // 当前版本
                        VStack(spacing: 4) {
                            Text("当前版本")
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
                            Text("最新版本")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.5))
                            Text(latestVersion)
                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                                .foregroundStyle(LiquidGlassColors.accentCyan)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(LiquidGlassColors.accentCyan.opacity(0.08))
                        )
                    }
                    
                    // 更新内容
                    if let commit = commit {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("更新内容")
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
                                tintColor: LiquidGlassColors.accentCyan,
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
                                        .fill(LiquidGlassColors.accentCyan.opacity(0.3))
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(updateManager.state.isDownloading)
                        } else if updateManager.state.isDownloaded {
                            Button {
                                updateManager.installUpdate()
                            } label: {
                                Text("立即安装")
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
