import Foundation
import SwiftUI
import AppKit

// MARK: - 播放器窗口控制器
class AnimePlayerWindowController: NSWindowController {
    let animeId: String
    let viewModel: AnimeDetailViewModel
    
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
        
        // 显示红绿灯按钮（用于关闭窗口）
        
        // 设置大小限制
        window.minSize = NSSize(width: 900, height: 500)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.center()
        
        // 设置内容视图
        let contentView = AnimePlayerWindow(viewModel: viewModel)
        window.contentView = NSHostingView(rootView: contentView)
        
        super.init(window: window)
        
        // 设置代理
        window.delegate = self
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func showWindow() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    func closeWindow() {
        viewModel.stopPlayback()
        window?.close()
    }
}

// MARK: - NSWindowDelegate
extension AnimePlayerWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        AnimeWindowManager.shared.windowWillClose(animeId: animeId)
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
}
