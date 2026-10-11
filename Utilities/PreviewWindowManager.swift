import AppKit
import Combine
import SwiftUI

// MARK: - 预览窗口管理器
@MainActor
final class PreviewWindowManager: ObservableObject {
    static let shared = PreviewWindowManager()

    private var windowController: NSWindowController?
    private var closeObserver: NSObjectProtocol?
    @Published private(set) var isPresented = false

    private init() {}

    func closePreview() {
        guard isPresented else { return }
        removeCloseObserver()
        if let window = windowController?.window {
            // 主动断开 hosting view，确保 SwiftUI 视图树立即销毁
            // (PreviewPlayer @StateObject 走 deinit → AVPlayer 停播)
            window.contentView = nil
        }
        windowController?.close()
        windowController = nil
        isPresented = false
    }

    private func removeCloseObserver() {
        if let observer = closeObserver {
            NotificationCenter.default.removeObserver(observer)
            closeObserver = nil
        }
    }

    func openPreview(url: URL, aspectRatio: Double? = nil, isWeb: Bool = false, posterURL: URL? = nil) {
        removeCloseObserver()
        windowController?.close()
        windowController = nil

        let screen = WindowSpaceCoordinator.referenceWindow?.screen
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let screenFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)

        let maxWidth = max(1000, screenFrame.width * 0.85)
        let maxHeight = max(700, screenFrame.height * 0.85)

        var width = maxWidth
        var height = maxHeight

        // 根据图片实际比例计算窗口尺寸，竖图窗口也保持竖比例
        if let ratio = aspectRatio, ratio > 0 {
            let containerAspect = maxWidth / maxHeight
            if ratio > containerAspect {
                // 图片比容器更宽：宽度撑满，高度按比例
                width = maxWidth
                height = maxWidth / ratio
            } else {
                // 图片比容器更高（含竖图）：高度撑满，宽度按比例
                height = maxHeight
                width = maxHeight * ratio
            }
        }

        let x = screenFrame.midX - width / 2
        let y = screenFrame.midY - height / 2

        let window = NSWindow(
            contentRect: NSRect(x: x, y: y, width: width, height: height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "预览"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 400, height: 400)
        WindowSpaceCoordinator.prepare(window)

        let hostingView = NSHostingView(
            rootView: WallpaperPreviewSheet(url: url, isWeb: isWeb, posterURL: posterURL)
        )
        window.contentView = hostingView

        windowController = NSWindowController(window: window)
        windowController?.showWindow(nil)
        WindowSpaceCoordinator.show(window)
        isPresented = true

        // 监听窗口关闭（用户点击关闭按钮时同步状态）
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.removeCloseObserver()
                // 主动断开 hosting view，触发 SwiftUI .onDisappear /
                // PreviewPlayer.deinit，避免 AVPlayer 在窗口隐藏后继续播放音频
                if let win = self.windowController?.window {
                    win.contentView = nil
                }
                self.windowController = nil
                self.isPresented = false
            }
        }
    }
}
