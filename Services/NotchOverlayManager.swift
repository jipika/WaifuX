import AppKit
import Combine

/// 刘海隐藏管理器
///
/// 在每个屏幕的菜单栏区域下方放置纯黑窗口，利用 macOS 菜单栏的半透明毛玻璃效果，
/// 使菜单栏呈现纯黑背景，从而在视觉上隐藏刘海（留海）。
///
/// ⚠️ 关键原理：菜单栏是半透明的，它会模糊桌面层级的内容。
/// 因此在 desktop 层级上方放置纯黑窗口，菜单栏的 blur 效果会让它呈现黑色，
/// 但菜单栏上的图标（时间、WiFi、电量等）仍然可见。
///
/// 窗口层级使用 desktopWindow + 1（与颗粒蒙层相同），低于菜单栏。
@MainActor
final class NotchOverlayManager {
    static let shared = NotchOverlayManager()

    /// 每个屏幕的 overlay 窗口（key 为 screenID）
    private var overlayWindows: [String: NSWindow] = [:]

    /// 当前是否启用
    private var isEnabled = false

    private init() {
        guard BackgroundRuntimeRole.isHelper else { return }
        // 监听屏幕配置变化（外接显示器插拔）
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        // 监听 Space 切换，重新排序窗口
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSpaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
    }

    // MARK: - 公开控制

    /// 启用/禁用刘海隐藏
    func setEnabled(_ enabled: Bool) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("overlay.notch", ["enabled": enabled]); return }

        guard isEnabled != enabled else { return }
        isEnabled = enabled
        if enabled {
            createOverlays()
        } else {
            destroyOverlays()
        }
    }

    /// 刷新所有窗口（屏幕配置变化时调用）
    func refresh() {
        guard isEnabled else { return }

        // 移除不再存在的屏幕的窗口
        let currentScreenIDs = Set(NSScreen.screens.map { $0.wallpaperScreenIdentifier })
        for (screenID, window) in overlayWindows {
            if !currentScreenIDs.contains(screenID) {
                window.orderOut(nil)
                window.contentView = nil
                overlayWindows.removeValue(forKey: screenID)
            }
        }

        // 为新屏幕创建窗口，更新现有窗口位置
        for screen in NSScreen.screens {
            let screenID = screen.wallpaperScreenIdentifier
            if let window = overlayWindows[screenID] {
                updateWindowFrame(window, for: screen)
            } else {
                createOverlay(for: screen)
            }
        }
    }

    // MARK: - 内部实现

    private func createOverlays() {
        for screen in NSScreen.screens {
            createOverlay(for: screen)
        }
    }

    private func destroyOverlays() {
        for (screenID, window) in overlayWindows {
            window.orderOut(nil)
            window.contentView = nil
            overlayWindows.removeValue(forKey: screenID)
        }
    }

    private func createOverlay(for screen: NSScreen) {
        guard BackgroundRuntimeRole.allowsDesktopRendering else { return }
        let screenID = screen.wallpaperScreenIdentifier
        let frame = menuBarFrame(for: screen)

        let window = NSWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.setFrame(frame, display: true)
        // ⚠️ 关键：使用 desktopWindow 层级（与视频壁纸窗口同级）。
        // 菜单栏的毛玻璃效果会模糊此层的内容，使菜单栏呈现纯黑视觉效果。
        window.level = .init(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.isMovable = false

        overlayWindows[screenID] = window
        window.orderFront(nil)
    }

    /// 计算菜单栏区域的 frame（位于桌面层级，将被菜单栏的毛玻璃模糊）
    private func menuBarFrame(for screen: NSScreen) -> NSRect {
        let screenFrame = screen.frame
        // 菜单栏高度 = 屏幕顶部到 visibleFrame 顶部的距离
        let menuBarHeight = screenFrame.maxY - screen.visibleFrame.maxY
        // 向下多延伸 1pt 消除可能的缝隙
        let overlayHeight = max(menuBarHeight, 0) + 1
        return NSRect(
            x: screenFrame.minX,
            y: screenFrame.maxY - overlayHeight,
            width: screenFrame.width,
            height: overlayHeight
        )
    }

    private func updateWindowFrame(_ window: NSWindow, for screen: NSScreen) {
        let frame = menuBarFrame(for: screen)
        window.setFrame(frame, display: true)
        window.orderFront(nil)
    }

    @objc private func handleSpaceChanged() {
        // Space 切换后重新排序窗口，确保在正确层级
        guard isEnabled else { return }
        for (_, window) in overlayWindows {
            window.orderFront(nil)
        }
    }

    @objc private func handleScreenParametersChanged() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.refresh()
        }
    }
}
