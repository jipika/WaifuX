import AppKit
import Combine

/// 静态壁纸独立显示 Overlay 管理器
///
/// 当「系统壁纸同步」关闭时，静态壁纸不再走 `setDesktopImageURL`，
/// 改由本管理器在 desktop 级 NSWindow 上用 NSImageView 直接覆盖桌面显示，
/// 与视频/场景/web 动态壁纸引擎各自独立、互不干扰。
///
/// 窗口层级与 `VideoWallpaperManager` 的视频壁纸窗口一致（`CGWindowLevelForKey(.desktopWindow)`），
/// 低于颗粒蒙层（`+1`）与时钟 overlay（`+20`），叠加顺序天然正确。
///
/// 裁切逻辑与视频壁纸完全一致：使用 `CropLayoutEngine` 计算 viewport + wallpaperCropRect，
/// 通过 CALayer frame + mask 实现 pan/zoom/letterbox。
/// layer 结构与 `WallpaperVideoContainerView` 完全对齐：override backing layer + masksToBounds 容器。
///
/// 持久化：每屏静态图 URL 写入 UserDefaults（`static_image_overlay_state_v1`），
/// App 启动时 `restoreIfNeeded()` 在 sync 关闭且无活跃动态壁纸时自动重建 overlay。
@MainActor
final class StaticImageWallpaperOverlayManager {
    static let shared = StaticImageWallpaperOverlayManager()

    /// 每个屏幕的静态图 overlay 窗口（key 为 screenID）
    private var imageWindows: [String: NSWindow] = [:]

    /// 每个屏幕当前显示的图片 URL（内存镜像，供 refreshWindows 重建使用）
    private var imageByScreen: [String: URL] = [:]

    /// 每个屏幕的图片原始像素尺寸（用于 CropLayoutEngine 计算）
    private var imageSizes: [String: CGSize] = [:]

    private var cancellables = Set<AnyCancellable>()

    /// 持久化键：`{screenID: imageURLString}` JSON
    private static let stateKey = "static_image_overlay_state_v1"

    private init() {
        // Space 切换后重新显示 overlay（desktop 级窗口可能被系统重排）
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSpaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )

        // 屏幕配置变化（外接显示器插拔）
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        // 系统唤醒后刷新
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        // crop 配置变化时实时刷新（与视频壁纸行为一致）
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCropDidChange),
            name: DisplayCropSettingsStore.cropDidChangeNotification,
            object: nil
        )
    }

    // MARK: - 显示 / 隐藏

    /// 为所有屏幕显示同一张静态图，并持久化状态。
    func showAll(imageURL: URL) {
        for screen in NSScreen.screens {
            show(imageURL: imageURL, for: screen)
        }
        persistState()
    }

    /// 为指定屏幕显示静态图（覆盖已有窗口），并持久化状态。
    func show(imageURL: URL, for screen: NSScreen) {
        guard FileManager.default.fileExists(atPath: imageURL.path) else {
            print("[StaticImageOverlay] ⚠️ 图片不存在，跳过 overlay 显示: \(imageURL.path)")
            return
        }
        let screenID = screen.wallpaperScreenIdentifier
        imageByScreen[screenID] = imageURL

        // 加载图片并记录原始像素尺寸（供 CropLayoutEngine 使用）
        if let img = NSImage(contentsOf: imageURL), img.size.width > 0, img.size.height > 0 {
            // NSImage.size 是 point 尺寸，需乘以 rep 像素比
            if let rep = img.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
                imageSizes[screenID] = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
            } else {
                imageSizes[screenID] = img.size
            }
        }

        if let existing = imageWindows[screenID] {
            // 复用窗口，只更新图片
            updateContentView(of: existing, imageURL: imageURL, screenID: screenID, screen: screen)
            existing.orderFront(nil)
        } else {
            createWindow(for: screen, imageURL: imageURL)
        }
        persistState()
    }

    /// 隐藏指定屏幕的 overlay（保留持久化记录，供下次 restoreIfNeeded 恢复）。
    func hide(for screen: NSScreen) {
        let screenID = screen.wallpaperScreenIdentifier
        if let window = imageWindows.removeValue(forKey: screenID) {
            window.orderOut(nil)
            window.contentView = nil
        }
    }

    /// 隐藏所有屏幕的 overlay（保留持久化记录）。
    func hideAll() {
        for (_, window) in imageWindows {
            window.orderOut(nil)
            window.contentView = nil
        }
        imageWindows.removeAll()
    }

    /// 彻底清除持久化状态（切到视频/场景/web 或系统壁纸时调用）。
    func clearState() {
        imageByScreen.removeAll()
        imageSizes.removeAll()
        hideAll()
        UserDefaults.standard.removeObject(forKey: Self.stateKey)
    }

    /// 返回指定屏幕的静态图原始像素尺寸（供 CropAdjustOverlayController 预览使用）。
    func imageSize(for screen: NSScreen) -> CGSize? {
        imageSizes[screen.wallpaperScreenIdentifier]
    }

    // MARK: - 启动恢复

    /// App 启动时调用：系统壁纸同步关闭且无活跃动态壁纸时，从持久化状态重建 overlay。
    func restoreIfNeeded() {
        // 系统壁纸同步开启 → 走系统壁纸，不需要 overlay
        guard !VideoWallpaperManager.shared.isSystemWallpaperSyncEnabled else {
            return
        }
        // 有活跃视频壁纸 → 视频窗口已覆盖桌面，不需要静态 overlay
        if VideoWallpaperManager.shared.isVideoWallpaperActive {
            return
        }
        // 有持久化的场景/web 壁纸待恢复（启动竞态防护）：
        // WaifuXApp 里 WE restore 是 async Task，restoreIfNeeded() 同步执行时
        // isControllingExternalEngine 可能仍为 false。用 hasPersistedRestoreState()
        // 同步预测 WE 将被恢复，避免静态 overlay 先弹出再被 WE 窗口盖住。
        if WallpaperEngineXBridge.shared.hasPersistedRestoreState() {
            return
        }
        // 有活跃场景/web 壁纸 → renderer 窗口已覆盖桌面，不需要静态 overlay
        if WallpaperEngineXBridge.shared.isControllingExternalEngine {
            return
        }

        guard let saved = loadState(), !saved.isEmpty else {
            return
        }

        // 按当前屏幕匹配已保存的图片 URL；匹配不到（屏幕已拔）的记录跳过。
        let currentScreens = NSScreen.screens
        var restored = 0
        for screen in currentScreens {
            let screenID = screen.wallpaperScreenIdentifier
            guard let urlString = saved[screenID], let url = URL(string: urlString) else { continue }
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            show(imageURL: url, for: screen)
            restored += 1
        }
        if restored > 0 {
            print("[StaticImageOverlay] ✅ 启动恢复 \(restored) 屏静态图 overlay")
        }
    }

    // MARK: - 窗口创建

    private func createWindow(for screen: NSScreen, imageURL: URL) {
        let screenID = screen.wallpaperScreenIdentifier
        let frame = screen.frame

        let window = StaticImageOverlayWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.setFrame(frame, display: true)
        // 与 VideoWallpaperManager 视频壁纸窗口一致：精确 desktop 级
        window.level = .init(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.isMovable = false
        window.animationBehavior = .none

        updateContentView(of: window, imageURL: imageURL, screenID: screenID, screen: screen)

        imageWindows[screenID] = window
        window.orderFront(nil)
    }

    /// 设置/更新窗口内容视图，使用 CropLayoutEngine 实现与视频壁纸一致的裁切逻辑。
    private func updateContentView(of window: NSWindow, imageURL: URL, screenID: String, screen: NSScreen) {
        let size = screen.frame.size
        let cropView = StaticCropImageView(frame: CGRect(origin: .zero, size: size))
        let img = NSImage(contentsOf: imageURL)
        cropView.image = img
        window.contentView = cropView
        applyCropToWindow(window, screenID: screenID, screen: screen)
    }

    /// 对指定屏幕的 overlay 窗口应用当前 crop 配置（与 VideoWallpaperManager.applyCropToScreen 逻辑一致）。
    private func applyCropToWindow(_ window: NSWindow, screenID: String, screen: NSScreen) {
        guard let cropView = window.contentView as? StaticCropImageView else { return }

        let settings = DisplayCropSettingsStore.shared.settings(for: screen)
        guard settings.shouldApplyCrop else {
            cropView.applyCropLayout(nil)
            window.backgroundColor = .black
            return
        }
        let wallpaperSize = imageSizes[screenID] ?? screen.frame.size
        let layout = CropLayoutEngine.compute(
            wallpaperSize: wallpaperSize,
            screenSize: screen.frame.size,
            settings: settings)
        cropView.applyCropLayout(layout)
        window.backgroundColor = NSColor(cgColor: layout.letterboxColor) ?? .black
    }

    // MARK: - 刷新（屏幕插拔 / crop 变更）

    func refreshWindows() {
        let currentScreenIDs = Set(NSScreen.screens.map { $0.wallpaperScreenIdentifier })
        // 移除已断开屏幕的窗口
        for (screenID, window) in imageWindows {
            if !currentScreenIDs.contains(screenID) {
                window.orderOut(nil)
                window.contentView = nil
                imageWindows.removeValue(forKey: screenID)
                imageSizes.removeValue(forKey: screenID)
            }
        }
        // 同步现有窗口帧 + 重建缺失窗口
        for screen in NSScreen.screens {
            let screenID = screen.wallpaperScreenIdentifier
            if let window = imageWindows[screenID] {
                window.setFrame(screen.frame, display: true)
                window.contentView?.frame = CGRect(origin: .zero, size: screen.frame.size)
                // 刷新时也重新应用 crop（屏幕分辨率可能变了）
                applyCropToWindow(window, screenID: screenID, screen: screen)
            } else if let imageURL = imageByScreen[screenID] {
                // 屏幕重连且本管理器记录过该屏图片 → 重建
                createWindow(for: screen, imageURL: imageURL)
            }
        }
    }

    // MARK: - 持久化

    private func persistState() {
        let dict = imageByScreen.mapValues { $0.absoluteString }
        if dict.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.stateKey)
        } else if let data = try? JSONSerialization.data(withJSONObject: dict),
                  let str = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(str, forKey: Self.stateKey)
        }
    }

    private func loadState() -> [String: String]? {
        guard let str = UserDefaults.standard.string(forKey: Self.stateKey),
              let data = str.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return nil
        }
        return dict
    }

    // MARK: - 通知

    @objc private func handleSpaceChanged() {
        // Space 切换后延迟重新显示，确保窗口层级正确
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            for (screenID, window) in self.imageWindows {
                if self.imageByScreen[screenID] != nil {
                    window.orderFront(nil)
                }
            }
        }
    }

    @objc private func handleScreenParametersChanged() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.refreshWindows()
        }
    }

    @objc private func handleWake() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refreshWindows()
        }
    }

    @objc private func handleCropDidChange(_ note: Notification) {
        guard let screenID = note.userInfo?["screenID"] as? String,
              let window = imageWindows[screenID],
              let screen = NSScreen.screens.first(where: { $0.wallpaperScreenIdentifier == screenID }) else { return }
        applyCropToWindow(window, screenID: screenID, screen: screen)
    }
}

// MARK: - 窗口子类

/// 静态图 overlay 窗口：不可成为 key/main，避免抢焦点（对齐 WallpaperVideoWindow）。
private final class StaticImageOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - 裁切感知的静态图视图

/// 使用与 `WallpaperVideoContainerView` 一致的裁切逻辑：
/// imageLayer（aspectFill）+ layer.frame 偏移 + viewport mask。
/// override backing layer 为 masksToBounds 容器，与视频壁纸 layer 结构完全对齐。
private final class StaticCropImageView: NSView {
    private let imageLayer = CALayer()

    /// 保留 CGImage 强引用，防止 AppKit layer display cycle 清掉 contents 后无法恢复。
    private var storedCGImage: CGImage?

    /// 上一次应用的 wallpaperCropRect（归一化），用于 layout 时回退。
    private var currentWallpaperCropRect: UnitRect?

    var image: NSImage? {
        didSet {
            if let image {
                let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
                storedCGImage = cg
                imageLayer.contents = cg
            } else {
                storedCGImage = nil
                imageLayer.contents = nil
            }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // 与 WallpaperVideoContainerView 完全对齐：override backing layer 为 masksToBounds 容器
        let container = CALayer()
        container.masksToBounds = true
        layer = container
        imageLayer.contentsGravity = .resizeAspectFill
        // ⚠️ 不设置 needsDisplayOnBoundsChange：静态 CGImage 不需要 bounds 变化时触发 display。
        // AppKit layer-backed view 在 display cycle 中可能清掉子层 contents，
        // AVPlayerLayer 不受影响（播放器持续刷新），但静态 CGImage 一旦被清就无法恢复。
        imageLayer.frame = bounds
        container.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        // 兜底：每次 layout 确保 imageLayer.contents 存在
        // （AppKit display cycle 可能清掉子层 contents，这里及时恢复）
        if imageLayer.contents == nil, let cg = storedCGImage {
            imageLayer.contents = cg
        }
        // 无 crop 时保持 imageLayer 填满
        if currentWallpaperCropRect == nil {
            imageLayer.frame = bounds
        }
    }

    /// 应用 CropLayout；nil 回退到 aspect-fill（与视频壁纸无 crop 时行为一致）。
    /// 实现逻辑与 `WallpaperVideoContainerView.applyCropLayout` 完全对齐。
    func applyCropLayout(_ layout: CropLayout?) {
        // 兜底：确保 contents 存在（与 layout() 中的保护一致）
        if imageLayer.contents == nil, let cg = storedCGImage {
            imageLayer.contents = cg
        }
        let viewBounds = bounds
        guard let layout, viewBounds.width > 0, viewBounds.height > 0 else {
            currentWallpaperCropRect = nil
            imageLayer.contentsGravity = .resizeAspectFill
            imageLayer.frame = viewBounds
            layer?.mask = nil
            return
        }

        // 与 WallpaperVideoContainerView.applyCropLayout 完全一致的计算
        let vpW = layout.viewportRect.w * viewBounds.width
        let vpH = layout.viewportRect.h * viewBounds.height
        let vpX = layout.viewportRect.x * viewBounds.width
        let vpY = (1.0 - layout.viewportRect.y - layout.viewportRect.h) * viewBounds.height
        let viewport = CGRect(x: vpX, y: vpY, width: vpW, height: vpH)
        currentWallpaperCropRect = layout.wallpaperCropRect

        let crop = layout.wallpaperCropRect
        let cropW = max(0.0001, crop.w)
        let cropH = max(0.0001, crop.h)
        let layerW = vpW / cropW
        let layerH = vpH / cropH
        let layerX = vpX - crop.x * layerW
        let layerY = vpY - (1.0 - crop.y - crop.h) * layerH
        imageLayer.frame = CGRect(x: layerX, y: layerY, width: layerW, height: layerH)

        let isFullViewport = abs(vpX) < 0.5 && abs(vpY) < 0.5
            && abs(vpW - viewBounds.width) < 0.5 && abs(vpH - viewBounds.height) < 0.5
        if isFullViewport {
            layer?.mask = nil
        } else {
            let mask = (layer?.mask as? CALayer) ?? CALayer()
            mask.backgroundColor = CGColor(gray: 1, alpha: 1)
            mask.frame = viewport
            layer?.mask = mask
        }
    }
}
