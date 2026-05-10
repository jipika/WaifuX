import Foundation
import SwiftUI
import AppKit

// MARK: - 播放器窗口控制器
class AnimePlayerWindowController: NSWindowController {
    let animeId: String
    let viewModel: AnimeDetailViewModel
    let player = NativeVideoPlayer()
    private var didReleaseResources = false
    
    nonisolated(unsafe) private var keyMonitor: Any?
    nonisolated(unsafe) private var mouseMonitor: Any?
    
    init(anime: AnimeSearchResult, viewModel: AnimeDetailViewModel) {
        self.animeId = anime.id
        self.viewModel = viewModel
        
        // 创建窗口
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        
        // 窗口设置
        window.title = anime.title
        window.backgroundColor = NSColor(Color(hex: "0A0A0C"))
        
        // 隐藏原生标题栏，使用自定义标题栏
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        
        // 设置大小限制
        window.minSize = NSSize(width: 900, height: 500)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.center()
        
        super.init(window: window)
        
        // 设置代理
        window.delegate = self
        
        // 监听全屏切换通知
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleToggleFullScreen),
            name: .togglePlayerFullScreen,
            object: nil
        )
        
        // 设置键盘和鼠标事件监听（在 NSHostingView 创建之前注册，
        // 确保优先级高于 SwiftUI 内部事件 monitor，避免空格键被 SwiftUI 焦点系统拦截）
        setupEventMonitors()
        
        // 设置内容视图（传入 player）
        let contentView = AnimePlayerWindow(viewModel: viewModel, player: player)
        window.contentView = NSHostingView(rootView: contentView)
    }
    
    @objc private func handleToggleFullScreen() {
        window?.toggleFullScreen(nil)
    }
    
    private func setupEventMonitors() {
        // 键盘事件监听
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window?.isKeyWindow == true else { return event }
            
            switch event.keyCode {
            case 49: // 空格键
                self.togglePlayPause()
                return nil
            case 123: // 左方向键
                self.player.skip(by: -15)
                return nil
            case 124: // 右方向键
                self.player.skip(by: 15)
                return nil
            case 126: // 上方向键
                let newVolume = min(self.player.playbackVolume + 0.1, 1.0)
                self.player.playbackVolume = newVolume
                self.player.isMuted = false
                return nil
            case 125: // 下方向键
                let newVolume = max(self.player.playbackVolume - 0.1, 0.0)
                self.player.playbackVolume = newVolume
                if newVolume == 0 { self.player.isMuted = true }
                return nil
            case 53: // ESC 键
                if self.window?.styleMask.contains(.fullScreen) == true {
                    self.window?.toggleFullScreen(nil)
                    return nil
                }
                return event
            default:
                return event
            }
        }
        
        // 鼠标移动监听（用于控制栏显隐）
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .mouseEntered, .leftMouseDragged]) { [weak self] event in
            guard let self, event.window?.isKeyWindow == true else { return event }
            self.showControlBar()
            return event
        }
    }
    
    nonisolated private func removeEventMonitors() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
    }
    
    private func togglePlayPause() {
        if player.state.isPlaying {
            player.pause()
        } else {
            player.play()
        }
    }
    
    private func showControlBar() {
        // 只负责通知 SwiftUI 显示控制栏，是否自动隐藏由 SwiftUI 根据当前状态决定
        NotificationCenter.default.post(name: .playerShowControlBar, object: animeId)
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        removeEventMonitors()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func showWindow() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    func closeWindow() {
        releaseResourcesForClose()
        window?.close()
    }

    private func releaseResourcesForClose() {
        guard !didReleaseResources else { return }
        didReleaseResources = true

        viewModel.releaseForegroundMemory()
        player.releaseResources()
        AnimeVideoExtractor.shared.cancel()
        removeEventMonitors()

        window?.contentView = nil
    }
}

// MARK: - NSWindowDelegate
extension AnimePlayerWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        releaseResourcesForClose()
        AnimeWindowManager.shared.windowWillClose(animeId: animeId)
    }
    
    func windowWillEnterFullScreen(_ notification: Notification) {
        NotificationCenter.default.post(name: .playerDidEnterFullScreen, object: animeId)
    }
    
    func windowDidExitFullScreen(_ notification: Notification) {
        NotificationCenter.default.post(name: .playerDidExitFullScreen, object: animeId)
    }
}

// MARK: - 动漫窗口管理器
@MainActor
class AnimeWindowManager: ObservableObject {
    static let shared = AnimeWindowManager()
    
    private var windowControllers: [String: AnimePlayerWindowController] = [:]
    
    private init() {}
    
    /// 打开或聚焦播放器窗口
    /// - Returns: 是否创建了新窗口
    @discardableResult
    func openPlayerWindow(for anime: AnimeSearchResult, using viewModel: AnimeDetailViewModel) -> Bool {
        // 检查是否已存在该动漫的窗口
        if let existingController = windowControllers[anime.id] {
            // 已存在，聚焦窗口
            existingController.showWindow()
            return false
        }
        
        // 创建新的窗口控制器
        let controller = AnimePlayerWindowController(anime: anime, viewModel: viewModel)
        windowControllers[anime.id] = controller
        controller.showWindow()
        
        // 自动搜索所有源
        Task {
            await viewModel.searchAllSources()
        }
        
        return true
    }
    
    /// 窗口即将关闭（由 WindowController 调用）
    func windowWillClose(animeId: String) {
        windowControllers.removeValue(forKey: animeId)
    }
    
    /// 关闭指定动漫的窗口
    func closeWindow(for animeId: String) {
        windowControllers[animeId]?.closeWindow()
        windowControllers.removeValue(forKey: animeId)
    }

    /// 主窗口进入后台极致释放时，关闭所有独立动漫播放窗口并释放播放器/WebView 资源。
    func closeAllWindowsForMemoryRelease() {
        let controllers = Array(windowControllers.values)
        windowControllers.removeAll()
        controllers.forEach { $0.closeWindow() }
    }
}
