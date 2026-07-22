import AppKit
import Combine
import CoreImage
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

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
    /// 按物理显示器指纹索引的静态图 URL，用于外接屏重插后 screenID 变化时恢复。
    private var imageByScreenFingerprint: [String: URL] = [:]

    /// 状态变化信号，供外部 Combine 订阅（每次 show/hide/clear 时递增）
    @Published private(set) var stateChangeSignal: Int = 0

    /// 每个屏幕的图片原始像素尺寸（用于 CropLayoutEngine 计算）
    private var imageSizes: [String: CGSize] = [:]
    /// 每屏静态图源文件自带黑边的内容裁切框。只在全屏自动铺满模式下叠加。
    private var imageLetterboxContentCrops: [String: UnitRect] = [:]
    private var imageLetterboxAnalysisTasks: [String: Task<UnitRect?, Never>] = [:]
    private var imageLetterboxCropCache: [String: UnitRect] = [:]
    private var imageLetterboxNoCropCache = Set<String>()

    private var cancellables = Set<AnyCancellable>()

    /// 持久化键：`{screenID: imageURLString}` JSON
    private static let stateKey = "static_image_overlay_state_v1"
    private static let fingerprintStateKey = "static_image_overlay_fingerprint_state_v1"

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
        Task { @MainActor in
            await showAllPrepared(imageURL: imageURL)
        }
    }

    /// 为所有屏幕显示同一张静态图：先完成黑边分析，再真正更新 overlay。
    func showAllPrepared(imageURL: URL) async {
        for screen in NSScreen.screens {
            await showPrepared(imageURL: imageURL, for: screen)
        }
        persistState()
    }

    /// 为指定屏幕显示静态图（覆盖已有窗口），并持久化状态。
    func show(imageURL: URL, for screen: NSScreen) {
        Task { @MainActor in
            await showPrepared(imageURL: imageURL, for: screen)
        }
    }

    /// 为指定屏幕显示静态图：先完成黑边分析，再真正更新 overlay。
    func showPrepared(imageURL: URL, for screen: NSScreen) async {
        guard FileManager.default.fileExists(atPath: imageURL.path) else {
            print("[StaticImageOverlay] ⚠️ 图片不存在，跳过 overlay 显示: \(imageURL.path)")
            return
        }
        let screenID = screen.wallpaperScreenIdentifier
        let screenFingerprint = screen.wallpaperScreenFingerprint
        guard Self.currentScreenExists(screenID: screenID, fingerprint: screenFingerprint) else {
            AppLogger.error(.wallpaper, "Static overlay skipped because screen disconnected before prepare", metadata: [
                "screenID": screenID,
                "fingerprint": screenFingerprint,
                "image": imageURL.lastPathComponent,
                "currentScreens": NSScreen.screens.map(\.wallpaperScreenIdentifier).joined(separator: ",")
            ])
            print("[StaticImageOverlay] ⚠️ 屏幕已断开，跳过 overlay 显示: \(screen.localizedName)")
            return
        }
        imageByScreen[screenID] = imageURL
        imageByScreenFingerprint[screenFingerprint] = imageURL
        imageLetterboxContentCrops.removeValue(forKey: screenID)
        imageLetterboxAnalysisTasks[screenID]?.cancel()
        imageLetterboxAnalysisTasks.removeValue(forKey: screenID)

        // 加载图片并记录原始像素尺寸（供 CropLayoutEngine 使用）
        if let img = NSImage(contentsOf: imageURL), img.size.width > 0, img.size.height > 0 {
            // NSImage.size 是 point 尺寸，需乘以 rep 像素比
            if let rep = img.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
                imageSizes[screenID] = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
            } else {
                imageSizes[screenID] = img.size
            }
        }

        let contentCrop = await imageLetterboxCropIfNeeded(screenID: screenID, imageURL: imageURL)
        guard Self.currentScreenExists(screenID: screenID, fingerprint: screenFingerprint) else {
            imageLetterboxContentCrops.removeValue(forKey: screenID)
            imageLetterboxAnalysisTasks.removeValue(forKey: screenID)
            AppLogger.error(.wallpaper, "Static overlay skipped because screen disconnected after letterbox analysis", metadata: [
                "screenID": screenID,
                "fingerprint": screenFingerprint,
                "image": imageURL.lastPathComponent,
                "currentScreens": NSScreen.screens.map(\.wallpaperScreenIdentifier).joined(separator: ",")
            ])
            print("[StaticImageOverlay] ⚠️ 黑边分析完成时屏幕已断开，跳过 overlay 更新: \(screen.localizedName)")
            return
        }
        guard imageByScreen[screenID]?.standardizedFileURL == imageURL.standardizedFileURL else {
            return
        }
        if let contentCrop {
            imageLetterboxContentCrops[screenID] = contentCrop
        } else {
            imageLetterboxContentCrops.removeValue(forKey: screenID)
        }

        if let existing = imageWindows[screenID] {
            // 复用窗口，只更新图片
            updateContentView(of: existing, imageURL: imageURL, screenID: screenID, screen: screen)
            existing.orderFront(nil)
        } else {
            createWindow(for: screen, imageURL: imageURL)
        }
        persistState()
        stateChangeSignal &+= 1
    }

    /// 隐藏指定屏幕的 overlay（保留持久化记录，供下次 restoreIfNeeded 恢复）。
    func hide(for screen: NSScreen) {
        let screenID = screen.wallpaperScreenIdentifier
        if let window = imageWindows.removeValue(forKey: screenID) {
            window.orderOut(nil)
            window.contentView = nil
        }
        stateChangeSignal &+= 1
    }

    /// 隐藏所有屏幕的 overlay（保留持久化记录）。
    func hideAll() {
        for (_, window) in imageWindows {
            window.orderOut(nil)
            window.contentView = nil
        }
        imageWindows.removeAll()
        stateChangeSignal &+= 1
    }

    /// 彻底清除持久化状态（切到视频/场景/web 或系统壁纸时调用）。
    func clearState() {
        imageByScreen.removeAll()
        imageByScreenFingerprint.removeAll()
        imageSizes.removeAll()
        imageLetterboxContentCrops.removeAll()
        for task in imageLetterboxAnalysisTasks.values { task.cancel() }
        imageLetterboxAnalysisTasks.removeAll()
        hideAll()
        UserDefaults.standard.removeObject(forKey: Self.stateKey)
        UserDefaults.standard.removeObject(forKey: Self.fingerprintStateKey)
        stateChangeSignal &+= 1
    }

    /// 彻底清除指定屏幕的静态壁纸状态，不影响其它显示器。
    func clearState(for screen: NSScreen) {
        let screenID = screen.wallpaperScreenIdentifier
        let fingerprint = screen.wallpaperScreenFingerprint
        imageByScreen.removeValue(forKey: screenID)
        imageByScreenFingerprint.removeValue(forKey: fingerprint)
        imageSizes.removeValue(forKey: screenID)
        imageLetterboxContentCrops.removeValue(forKey: screenID)
        imageLetterboxAnalysisTasks.removeValue(forKey: screenID)?.cancel()
        hide(for: screen)
        persistState()
        stateChangeSignal &+= 1
    }

    /// 返回指定屏幕当前显示的静态图 URL（无 overlay 时返回 nil）
    func imageURL(for screen: NSScreen) -> URL? {
        let screenID = screen.wallpaperScreenIdentifier
        let fingerprint = screen.wallpaperScreenFingerprint
        return imageByScreen[screenID] ?? imageByScreenFingerprint[fingerprint]
    }

    func hasActiveWallpaper(on screens: [NSScreen]) -> Bool {
        screens.contains { screen in
            imageWindows[screen.wallpaperScreenIdentifier] != nil
        }
    }

    /// 动态目标在后方加载时保持旧静态图可见，避免新 renderer 的未稳定首帧抢到前方。
    func keepPresentationFront(on screens: [NSScreen]) {
        for screen in screens {
            guard let window = imageWindows[screen.wallpaperScreenIdentifier] else { continue }
            window.orderFrontRegardless()
            window.displayIfNeeded()
        }
        CATransaction.flush()
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
            restoreCurrentScreensFromFingerprintStateIfNeeded()
            return
        }

        // 按当前屏幕匹配已保存的图片 URL；匹配不到（屏幕已拔）的记录跳过。
        let currentScreens = NSScreen.screens
        let savedByFingerprint = loadFingerprintState() ?? [:]
        var restored = 0
        for screen in currentScreens {
            let screenID = screen.wallpaperScreenIdentifier
            let urlString = saved[screenID] ?? savedByFingerprint[screen.wallpaperScreenFingerprint]
            guard let urlString, let url = URL(string: urlString) else { continue }
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            Task { @MainActor in
                await showPrepared(imageURL: url, for: screen)
            }
            restored += 1
        }
        if restored > 0 {
            print("[StaticImageOverlay] ✅ 启动恢复 \(restored) 屏静态图 overlay")
        }
    }

    @discardableResult
    func restorePreviousImageIfAvailable(for screen: NSScreen) -> Bool {
        guard !VideoWallpaperManager.shared.isSystemWallpaperSyncEnabled else { return false }
        guard !VideoWallpaperManager.shared.isVideoWallpaperActive else { return false }
        guard !WallpaperEngineXBridge.shared.isControllingExternalEngine,
              !WallpaperEngineXBridge.shared.hasPersistedRestoreState(for: screen) else {
            return false
        }

        let screenID = screen.wallpaperScreenIdentifier
        let fingerprint = screen.wallpaperScreenFingerprint
        let url = imageByScreen[screenID]
            ?? imageByScreenFingerprint[fingerprint]
            ?? loadState().flatMap { $0[screenID] }.flatMap(URL.init(string:))
            ?? loadFingerprintState().flatMap { $0[fingerprint] }.flatMap(URL.init(string:))
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            return false
        }

        Task { @MainActor in
            await showPrepared(imageURL: url, for: screen)
        }
        print("[StaticImageOverlay] Restored previous static wallpaper for reconnected display: \(screen.localizedName)")
        return true
    }

    /// Removes persistence for one disconnected display without touching the
    /// overlay windows or image registrations of other displays.
    func discardPersistedImageState(screenID: String, fingerprint: String) {
        imageByScreen.removeValue(forKey: screenID)
        imageByScreenFingerprint.removeValue(forKey: fingerprint)
        imageSizes.removeValue(forKey: screenID)
        imageLetterboxContentCrops.removeValue(forKey: screenID)
        imageLetterboxAnalysisTasks.removeValue(forKey: screenID)?.cancel()
        persistState()
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
        let contentCrop = autoRemoveImageLetterboxEnabled ? imageLetterboxContentCrops[screenID] : nil
        guard settings.shouldApplyCrop else {
            window.backgroundColor = .black
            if let contentCrop {
                let layout = CropLayout(
                    wallpaperCropRect: contentCrop,
                    viewportRect: .full,
                    letterboxColor: CGColor(gray: 0, alpha: 1)
                )
                cropView.applyCropLayout(layout)
            } else {
                cropView.applyCropLayout(nil)
            }
            return
        }
        let wallpaperSize = imageSizes[screenID] ?? screen.frame.size
        let layoutWallpaperSize: CGSize
        if let contentCrop {
            layoutWallpaperSize = CGSize(
                width: max(1, wallpaperSize.width * contentCrop.w),
                height: max(1, wallpaperSize.height * contentCrop.h)
            )
        } else {
            layoutWallpaperSize = wallpaperSize
        }
        let layout = CropLayoutEngine.compute(
            wallpaperSize: layoutWallpaperSize,
            screenSize: screen.frame.size,
            settings: settings)
        cropView.applyCropLayout(applyingSourceContentCrop(contentCrop, to: layout))
        window.backgroundColor = NSColor(cgColor: layout.letterboxColor) ?? .black
    }

    private func applyingSourceContentCrop(_ contentCrop: UnitRect?, to layout: CropLayout) -> CropLayout {
        guard let contentCrop else { return layout }
        let crop = layout.wallpaperCropRect
        let combinedCrop = UnitRect(
            x: contentCrop.x + crop.x * contentCrop.w,
            y: contentCrop.y + crop.y * contentCrop.h,
            w: crop.w * contentCrop.w,
            h: crop.h * contentCrop.h
        )
        return CropLayout(
            wallpaperCropRect: combinedCrop,
            viewportRect: layout.viewportRect,
            letterboxColor: layout.letterboxColor
        )
    }

    // MARK: - 刷新（屏幕插拔 / crop 变更）

    func refreshWindows() {
        let currentScreenIDs = Set(NSScreen.screens.map { $0.wallpaperScreenIdentifier })
        AppLogger.error(.wallpaper, "Static overlay refresh windows", metadata: [
            "currentScreens": currentScreenIDs.joined(separator: ","),
            "windowScreens": imageWindows.keys.sorted().joined(separator: ","),
            "imageScreens": imageByScreen.keys.sorted().joined(separator: ",")
        ])
        // 移除已断开屏幕的窗口；screenID 级映射可清，fingerprint 级保留供重插恢复
        for (screenID, window) in Array(imageWindows) {
            if !currentScreenIDs.contains(screenID) {
                AppLogger.error(.wallpaper, "Static overlay removing disconnected window", metadata: ["screenID": screenID])
                window.orderOut(nil)
                window.contentView = nil
                imageWindows.removeValue(forKey: screenID)
                imageSizes.removeValue(forKey: screenID)
                imageLetterboxContentCrops.removeValue(forKey: screenID)
                imageLetterboxAnalysisTasks.removeValue(forKey: screenID)?.cancel()
                // 不删 imageByScreenFingerprint；只去掉失效的 screenID 键
                imageByScreen.removeValue(forKey: screenID)
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
                Task { @MainActor in
                    await showPrepared(imageURL: imageURL, for: screen)
                }
            } else if let imageURL = imageByScreenFingerprint[screen.wallpaperScreenFingerprint] {
                Task { @MainActor in
                    await showPrepared(imageURL: imageURL, for: screen)
                }
            }
        }
    }

    private static func currentScreenExists(screenID: String, fingerprint: String) -> Bool {
        NSScreen.screens.contains { screen in
            screen.wallpaperScreenIdentifier == screenID ||
            screen.wallpaperScreenFingerprint == fingerprint
        }
    }

    func refreshAutoRemoveImageLetterbox() {
        guard autoRemoveImageLetterboxEnabled else {
            for task in imageLetterboxAnalysisTasks.values { task.cancel() }
            imageLetterboxAnalysisTasks.removeAll()
            imageLetterboxContentCrops.removeAll()
            for screen in NSScreen.screens {
                let screenID = screen.wallpaperScreenIdentifier
                if let window = imageWindows[screenID] {
                    applyCropToWindow(window, screenID: screenID, screen: screen)
                }
            }
            return
        }

        for screen in NSScreen.screens {
            let screenID = screen.wallpaperScreenIdentifier
            guard let imageURL = imageByScreen[screenID] else { continue }
            Task { @MainActor in
                _ = await self.refreshImageLetterboxCrop(screenID: screenID, imageURL: imageURL)
            }
        }
    }

    private var autoRemoveImageLetterboxEnabled: Bool {
        UserDefaults.standard.object(forKey: "auto_remove_video_letterbox") as? Bool ?? false
    }

    func preparedSystemWallpaperURL(for imageURL: URL) async -> URL {
        guard autoRemoveImageLetterboxEnabled else {
            return imageURL
        }
        return await StaticImageLetterboxAnalyzer.croppedImageFileURL(for: imageURL) ?? imageURL
    }

    private func imageLetterboxCropIfNeeded(screenID: String, imageURL: URL) async -> UnitRect? {
        guard autoRemoveImageLetterboxEnabled else { return nil }
        let cacheKey = imageLetterboxCacheKey(for: imageURL)
        if let cached = imageLetterboxCropCache[cacheKey] {
            return cached
        }
        if imageLetterboxNoCropCache.contains(cacheKey) {
            return nil
        }
        if let existingTask = imageLetterboxAnalysisTasks[screenID] {
            return await existingTask.value
        }

        let task = Task.detached(priority: .utility) {
            await StaticImageLetterboxAnalyzer.analyze(url: imageURL)
        }
        imageLetterboxAnalysisTasks[screenID] = task
        let crop = await task.value

        if imageByScreen[screenID]?.standardizedFileURL == imageURL.standardizedFileURL {
            self.imageLetterboxAnalysisTasks.removeValue(forKey: screenID)
        }
        if let crop {
            imageLetterboxCropCache[cacheKey] = crop
        } else {
            imageLetterboxNoCropCache.insert(cacheKey)
        }
        return crop
    }

    private func refreshImageLetterboxCrop(screenID: String, imageURL: URL) async -> UnitRect? {
        let crop = await imageLetterboxCropIfNeeded(screenID: screenID, imageURL: imageURL)
        guard autoRemoveImageLetterboxEnabled else { return crop }
        guard imageByScreen[screenID]?.standardizedFileURL == imageURL.standardizedFileURL else {
            return crop
        }
        if let crop {
            imageLetterboxContentCrops[screenID] = crop
        } else {
            imageLetterboxContentCrops.removeValue(forKey: screenID)
        }
        if let screen = NSScreen.screens.first(where: { $0.wallpaperScreenIdentifier == screenID }),
           let window = imageWindows[screenID] {
            applyCropToWindow(window, screenID: screenID, screen: screen)
        }
        return crop
    }

    private func imageLetterboxCacheKey(for url: URL) -> String {
        guard url.isFileURL,
              let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else {
            return url.standardizedFileURL.absoluteString
        }
        let size = values.fileSize ?? 0
        let mtime = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        return "\(url.standardizedFileURL.path)|\(size)|\(mtime)"
    }

    // MARK: - 持久化

    private func persistState() {
        let dict = imageByScreen.mapValues { $0.absoluteString }
        let fpDict = imageByScreenFingerprint.mapValues { $0.absoluteString }
        if dict.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.stateKey)
        } else if let data = try? JSONSerialization.data(withJSONObject: dict),
                  let str = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(str, forKey: Self.stateKey)
        }
        if fpDict.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.fingerprintStateKey)
        } else if let data = try? JSONSerialization.data(withJSONObject: fpDict),
                  let str = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(str, forKey: Self.fingerprintStateKey)
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

    private func loadFingerprintState() -> [String: String]? {
        guard let str = UserDefaults.standard.string(forKey: Self.fingerprintStateKey),
              let data = str.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return nil
        }
        return dict
    }

    private func restoreCurrentScreensFromFingerprintStateIfNeeded() {
        guard let savedByFingerprint = loadFingerprintState(), !savedByFingerprint.isEmpty else { return }
        var restored = 0
        for screen in NSScreen.screens {
            let fingerprint = screen.wallpaperScreenFingerprint
            guard let urlString = savedByFingerprint[fingerprint],
                  let url = URL(string: urlString),
                  FileManager.default.fileExists(atPath: url.path) else { continue }
            Task { @MainActor in
                await showPrepared(imageURL: url, for: screen)
            }
            restored += 1
        }
        if restored > 0 {
            print("[StaticImageOverlay] ✅ 按显示器指纹恢复 \(restored) 屏静态图 overlay")
        }
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

private enum StaticImageLetterboxAnalyzer {
    private static let blackLumaThreshold: UInt8 = 28
    private static let edgeBlackRatioThreshold = 0.94
    private static let maxRemovedArea = 0.36
    private static let minRemovedArea = 0.01
    private static let minPairInsetRatio = 0.012
    private static let overscanPixels = 2

    static func analyze(url: URL) async -> UnitRect? {
        await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                return nil
            }
            return detectCropRect(in: image)
        }.value
    }

    static func croppedImageFileURL(for url: URL) async -> URL? {
        await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let crop = detectCropRect(in: image) else {
                return nil
            }

            let cropRect = pixelCropRect(from: crop, imageWidth: image.width, imageHeight: image.height)
            guard let cropped = image.cropping(to: cropRect) else {
                return nil
            }

            let outputExtension = normalizedOutputExtension(for: url.pathExtension)
            let cacheURL = systemWallpaperCacheURL(for: url, crop: crop, fileExtension: outputExtension)
            if FileManager.default.fileExists(atPath: cacheURL.path) {
                return cacheURL
            }

            do {
                try FileManager.default.createDirectory(
                    at: cacheURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
            } catch {
                print("[StaticImageOverlay] ⚠️ 创建系统壁纸裁剪缓存目录失败: \(error)")
                return nil
            }

            guard writeImage(cropped, to: cacheURL, fileExtension: outputExtension) else {
                return nil
            }
            print("[StaticImageOverlay] 🖼️ 系统静态壁纸已生成去黑边缓存: \(cacheURL.lastPathComponent)")
            return cacheURL
        }.value
    }

    private static func detectCropRect(in image: CGImage) -> UnitRect? {
        let width = image.width
        let height = image.height
        guard width > 16, height > 16 else { return nil }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        let didDraw = pixels.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress,
                  let ctx = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard didDraw else { return nil }

        let top = edgeInset(limit: height / 2) { y in
            blackRatioInRow(y, width: width, bytesPerRow: bytesPerRow, pixels: pixels)
        }
        let bottom = edgeInset(limit: height / 2) { offset in
            blackRatioInRow(height - 1 - offset, width: width, bytesPerRow: bytesPerRow, pixels: pixels)
        }
        let left = edgeInset(limit: width / 2) { x in
            blackRatioInColumn(x, height: height, bytesPerRow: bytesPerRow, pixels: pixels)
        }
        let right = edgeInset(limit: width / 2) { offset in
            blackRatioInColumn(width - 1 - offset, height: height, bytesPerRow: bytesPerRow, pixels: pixels)
        }

        let horizontalPair = Double(top + bottom) / Double(height) >= minPairInsetRatio
            && top > 0 && bottom > 0
        let verticalPair = Double(left + right) / Double(width) >= minPairInsetRatio
            && left > 0 && right > 0
        guard horizontalPair || verticalPair else { return nil }

        let rawCropTop = horizontalPair ? top : 0
        let rawCropBottom = horizontalPair ? bottom : 0
        let rawCropLeft = verticalPair ? left : 0
        let rawCropRight = verticalPair ? right : 0

        let rawCropW = max(1, width - rawCropLeft - rawCropRight)
        let rawCropH = max(1, height - rawCropTop - rawCropBottom)
        let removedArea = 1.0 - (Double(rawCropW * rawCropH) / Double(width * height))
        guard removedArea >= minRemovedArea, removedArea <= maxRemovedArea else { return nil }

        let cropTop = horizontalPair ? min(height - 1, rawCropTop + overscanPixels) : 0
        let cropBottom = horizontalPair ? min(height - cropTop - 1, rawCropBottom + overscanPixels) : 0
        let cropLeft = verticalPair ? min(width - 1, rawCropLeft + overscanPixels) : 0
        let cropRight = verticalPair ? min(width - cropLeft - 1, rawCropRight + overscanPixels) : 0

        let cropW = max(1, width - cropLeft - cropRight)
        let cropH = max(1, height - cropTop - cropBottom)
        return UnitRect(
            x: Double(cropLeft) / Double(width),
            y: Double(cropTop) / Double(height),
            w: Double(cropW) / Double(width),
            h: Double(cropH) / Double(height)
        )
    }

    private static func edgeInset(limit: Int, ratioAt: (Int) -> Double) -> Int {
        var inset = 0
        for i in 0..<limit {
            if ratioAt(i) >= edgeBlackRatioThreshold {
                inset += 1
            } else {
                break
            }
        }
        return inset
    }

    private static func blackRatioInRow(_ y: Int, width: Int, bytesPerRow: Int, pixels: [UInt8]) -> Double {
        let step = max(1, width / 360)
        var black = 0
        var total = 0
        let row = y * bytesPerRow
        var x = 0
        while x < width {
            if isBlackPixel(at: row + x * 4, pixels: pixels) {
                black += 1
            }
            total += 1
            x += step
        }
        return total > 0 ? Double(black) / Double(total) : 0
    }

    private static func blackRatioInColumn(_ x: Int, height: Int, bytesPerRow: Int, pixels: [UInt8]) -> Double {
        let step = max(1, height / 360)
        var black = 0
        var total = 0
        var y = 0
        while y < height {
            if isBlackPixel(at: y * bytesPerRow + x * 4, pixels: pixels) {
                black += 1
            }
            total += 1
            y += step
        }
        return total > 0 ? Double(black) / Double(total) : 0
    }

    private static func isBlackPixel(at index: Int, pixels: [UInt8]) -> Bool {
        guard index + 2 < pixels.count else { return false }
        let r = pixels[index]
        let g = pixels[index + 1]
        let b = pixels[index + 2]
        let luma = (UInt16(r) * 54 + UInt16(g) * 183 + UInt16(b) * 19) >> 8
        return luma <= blackLumaThreshold
    }

    private static func pixelCropRect(from crop: UnitRect, imageWidth: Int, imageHeight: Int) -> CGRect {
        let x = max(0, min(imageWidth - 1, Int((crop.x * Double(imageWidth)).rounded(.down))))
        let y = max(0, min(imageHeight - 1, Int((crop.y * Double(imageHeight)).rounded(.down))))
        let right = max(x + 1, min(imageWidth, Int(((crop.x + crop.w) * Double(imageWidth)).rounded(.up))))
        let bottom = max(y + 1, min(imageHeight, Int(((crop.y + crop.h) * Double(imageHeight)).rounded(.up))))
        return CGRect(x: x, y: y, width: right - x, height: bottom - y)
    }

    private static func normalizedOutputExtension(for sourceExtension: String) -> String {
        switch sourceExtension.lowercased() {
        case "png":
            return "png"
        default:
            return "jpg"
        }
    }

    private static func writeImage(_ image: CGImage, to url: URL, fileExtension: String) -> Bool {
        let outputUTI: CFString = fileExtension == "png"
            ? UTType.png.identifier as CFString
            : UTType.jpeg.identifier as CFString
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, outputUTI, 1, nil) else {
            return false
        }

        let options: [CFString: Any] = fileExtension == "jpg"
            ? [kCGImageDestinationLossyCompressionQuality: 0.95]
            : [:]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }

    private static func systemWallpaperCacheURL(for url: URL, crop: UnitRect, fileExtension: String) -> URL {
        let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = cacheRoot
            .appendingPathComponent("WaifuX", isDirectory: true)
            .appendingPathComponent("StaticSystemWallpapers", isDirectory: true)
        let key = "\(imageCacheKey(for: url))|\(crop.x),\(crop.y),\(crop.w),\(crop.h)"
        return directory.appendingPathComponent("\(stableHashHex(key)).\(fileExtension)")
    }

    private static func imageCacheKey(for url: URL) -> String {
        guard url.isFileURL,
              let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else {
            return url.standardizedFileURL.absoluteString
        }
        let size = values.fileSize ?? 0
        let mtime = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        return "\(url.standardizedFileURL.path)|\(size)|\(mtime)"
    }

    private static func stableHashHex(_ string: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
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

// MARK: - Portrait Blur Fill Artifacts

/// 为竖向静态图生成与显示器比例一致的模糊延伸版本。
///
/// 派生文件和原图分开保存，并以源文件指纹 + 目标像素尺寸建立映射，因此不会改写
/// 下载记录、收藏记录或原始图片。映射随派生目录保存，旧原图删除时可精确清理。
actor PortraitBlurFillWallpaperService {
    static let shared = PortraitBlurFillWallpaperService()

    private static let mappingFileName = "mapping.json"
    private static let artifactDirectoryName = "PortraitBlurFill"
    private static let rendererVersion = 1

    private struct MappingDocument: Codable {
        var version: Int
        var artifacts: [String: Artifact]
    }

    private struct Artifact: Codable {
        var sourcePath: String
        var sourceFingerprint: String
        var targetWidth: Int
        var targetHeight: Int
        var outputPath: String
        var createdAt: Date
    }

    private struct RenderRequest: Sendable {
        var sourceURL: URL
        var outputURL: URL
        var targetWidth: Int
        var targetHeight: Int
    }

    private var artifacts: [String: Artifact] = [:]
    private var loadedMappingURL: URL?

    /// 返回给指定显示器使用的派生图；横图或关闭开关时由调用方直接跳过此服务。
    func preparedWallpaperURL(
        for sourceURL: URL,
        targetPixelSize: CGSize,
        derivedWallpapersDirectory: URL
    ) async throws -> URL {
        let targetWidth = max(1, Int(targetPixelSize.width.rounded()))
        let targetHeight = max(1, Int(targetPixelSize.height.rounded()))
        guard targetWidth > 1, targetHeight > 1 else { return sourceURL }

        let sourcePath = sourceURL.standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: sourcePath) else {
            throw NSError(
                domain: "PortraitBlurFillWallpaper",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "原始壁纸文件不存在"]
            )
        }

        let sourceSize = try Self.pixelSize(of: sourceURL)
        guard sourceSize.height > sourceSize.width else { return sourceURL }

        let artifactDirectory = derivedWallpapersDirectory
            .appendingPathComponent(Self.artifactDirectoryName, isDirectory: true)
        let mappingURL = artifactDirectory.appendingPathComponent(Self.mappingFileName)
        try loadArtifactsIfNeeded(from: mappingURL)

        let sourceFingerprint = try Self.sourceFingerprint(for: sourceURL)
        let key = Self.artifactKey(
            sourceFingerprint: sourceFingerprint,
            targetWidth: targetWidth,
            targetHeight: targetHeight
        )

        if let artifact = artifacts[key],
           artifact.sourceFingerprint == sourceFingerprint,
           FileManager.default.fileExists(atPath: artifact.outputPath) {
            return URL(fileURLWithPath: artifact.outputPath)
        }

        try FileManager.default.createDirectory(
            at: artifactDirectory,
            withIntermediateDirectories: true
        )

        let outputURL = artifactDirectory.appendingPathComponent("blur-fill-\(key).jpg")
        let request = RenderRequest(
            sourceURL: sourceURL,
            outputURL: outputURL,
            targetWidth: targetWidth,
            targetHeight: targetHeight
        )
        try await Task.detached(priority: .userInitiated) {
            try Self.render(request)
        }.value

        artifacts[key] = Artifact(
            sourcePath: sourcePath,
            sourceFingerprint: sourceFingerprint,
            targetWidth: targetWidth,
            targetHeight: targetHeight,
            outputPath: outputURL.path,
            createdAt: .now
        )
        try persistArtifacts(to: mappingURL)
        return outputURL
    }

    /// 原图被用户删除时移除全部关联派生文件，不影响其他来源的生成结果。
    func removeArtifacts(
        for sourceURL: URL,
        derivedWallpapersDirectory: URL
    ) {
        let artifactDirectory = derivedWallpapersDirectory
            .appendingPathComponent(Self.artifactDirectoryName, isDirectory: true)
        let mappingURL = artifactDirectory.appendingPathComponent(Self.mappingFileName)
        guard (try? loadArtifactsIfNeeded(from: mappingURL)) != nil else { return }

        let sourcePath = sourceURL.standardizedFileURL.path
        let keys = artifacts.compactMap { key, artifact in
            artifact.sourcePath == sourcePath ? key : nil
        }
        guard !keys.isEmpty else { return }

        for key in keys {
            if let outputPath = artifacts[key]?.outputPath {
                try? FileManager.default.removeItem(atPath: outputPath)
            }
            artifacts.removeValue(forKey: key)
        }
        try? persistArtifacts(to: mappingURL)
    }

    /// 下载根目录迁移后，修复 copied mapping.json 中的绝对路径与缓存键。
    func rebaseArtifacts(
        from oldRoot: URL,
        to newRoot: URL,
        derivedWallpapersDirectory: URL
    ) {
        let artifactDirectory = derivedWallpapersDirectory
            .appendingPathComponent(Self.artifactDirectoryName, isDirectory: true)
        let mappingURL = artifactDirectory.appendingPathComponent(Self.mappingFileName)
        guard (try? loadArtifactsIfNeeded(from: mappingURL)) != nil else { return }

        var rebased: [String: Artifact] = [:]
        for artifact in artifacts.values {
            var next = artifact
            next.sourcePath = Self.rebasedPath(
                artifact.sourcePath,
                from: oldRoot.path,
                to: newRoot.path
            )
            next.outputPath = Self.rebasedPath(
                artifact.outputPath,
                from: oldRoot.path,
                to: newRoot.path
            )
            next.sourceFingerprint = Self.rebasedPath(
                artifact.sourceFingerprint,
                from: oldRoot.path,
                to: newRoot.path
            )
            let key = Self.artifactKey(
                sourceFingerprint: next.sourceFingerprint,
                targetWidth: next.targetWidth,
                targetHeight: next.targetHeight
            )
            rebased[key] = next
        }
        artifacts = rebased
        try? persistArtifacts(to: mappingURL)
    }

    private func loadArtifactsIfNeeded(from mappingURL: URL) throws {
        guard loadedMappingURL?.standardizedFileURL != mappingURL.standardizedFileURL else {
            return
        }

        loadedMappingURL = mappingURL
        guard FileManager.default.fileExists(atPath: mappingURL.path) else {
            artifacts = [:]
            return
        }

        let data = try Data(contentsOf: mappingURL)
        let document = try JSONDecoder().decode(MappingDocument.self, from: data)
        artifacts = document.version == Self.rendererVersion ? document.artifacts : [:]
    }

    private func persistArtifacts(to mappingURL: URL) throws {
        try FileManager.default.createDirectory(
            at: mappingURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let document = MappingDocument(
            version: Self.rendererVersion,
            artifacts: artifacts
        )
        let data = try JSONEncoder().encode(document)
        try data.write(to: mappingURL, options: .atomic)
    }

    private nonisolated static func pixelSize(of sourceURL: URL) throws -> CGSize {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let rawWidth = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let rawHeight = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw NSError(
                domain: "PortraitBlurFillWallpaper",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "无法读取原始壁纸尺寸"]
            )
        }

        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let shouldSwapDimensions = (5...8).contains(orientation)
        let width = CGFloat(shouldSwapDimensions ? rawHeight.intValue : rawWidth.intValue)
        let height = CGFloat(shouldSwapDimensions ? rawWidth.intValue : rawHeight.intValue)
        return CGSize(width: width, height: height)
    }

    private nonisolated static func sourceFingerprint(for sourceURL: URL) throws -> String {
        let standardized = sourceURL.standardizedFileURL
        let values = try standardized.resourceValues(forKeys: [
            .fileSizeKey,
            .contentModificationDateKey
        ])
        let size = values.fileSize ?? 0
        let modifiedAt = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        return "\(standardized.path)|\(size)|\(modifiedAt)"
    }

    private nonisolated static func artifactKey(
        sourceFingerprint: String,
        targetWidth: Int,
        targetHeight: Int
    ) -> String {
        let raw = "\(rendererVersion)|\(sourceFingerprint)|\(targetWidth)x\(targetHeight)"
        let hash = SHA256.hash(data: Data(raw.utf8))
        return hash.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func rebasedPath(
        _ value: String,
        from oldPrefix: String,
        to newPrefix: String
    ) -> String {
        guard value == oldPrefix || value.hasPrefix(oldPrefix + "/") else {
            return value
        }
        return newPrefix + String(value.dropFirst(oldPrefix.count))
    }

    private nonisolated static func render(_ request: RenderRequest) throws {
        guard let source = CGImageSourceCreateWithURL(request.sourceURL as CFURL, nil) else {
            throw NSError(
                domain: "PortraitBlurFillWallpaper",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "无法解码原始壁纸"]
            )
        }

        let options: [CFString: Any] = [
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let sourceImage = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary) else {
            throw NSError(
                domain: "PortraitBlurFillWallpaper",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "无法解码原始壁纸图像"]
            )
        }

        let orientation = (
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )?[kCGImagePropertyOrientation] as? NSNumber
        let orientedSourceImage = CIImage(cgImage: sourceImage)
            .oriented(forExifOrientation: Int32(orientation?.intValue ?? 1))
        let sourceExtent = orientedSourceImage.extent.integral
        let sourceImageCI = orientedSourceImage.transformed(by: CGAffineTransform(
            translationX: -sourceExtent.origin.x,
            y: -sourceExtent.origin.y
        ))
        let sourceWidth = sourceExtent.width
        let sourceHeight = sourceExtent.height
        let targetWidth = CGFloat(request.targetWidth)
        let targetHeight = CGFloat(request.targetHeight)
        guard sourceWidth > 0, sourceHeight > 0 else {
            throw NSError(
                domain: "PortraitBlurFillWallpaper",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "壁纸图像尺寸无效"]
            )
        }

        let targetRect = CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)

        // 背景使用 aspect-fill 后的同一图片，模糊并略微压暗；前景完整保留原图。
        let backgroundScale = max(targetWidth / sourceWidth, targetHeight / sourceHeight)
        let backgroundWidth = sourceWidth * backgroundScale
        let backgroundHeight = sourceHeight * backgroundScale
        let background = sourceImageCI.transformed(by: CGAffineTransform(
            a: backgroundScale,
            b: 0,
            c: 0,
            d: backgroundScale,
            tx: (targetWidth - backgroundWidth) / 2,
            ty: (targetHeight - backgroundHeight) / 2
        ))
        let blurRadius = min(120, max(42, min(targetWidth, targetHeight) * 0.075))
        let blurredBackground = background
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blurRadius])
            .cropped(to: targetRect)
        let darkenedBackground = CIImage(
            color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.18)
        )
        .cropped(to: targetRect)
        .composited(over: blurredBackground)

        let foregroundScale = min(targetWidth / sourceWidth, targetHeight / sourceHeight)
        let foregroundWidth = sourceWidth * foregroundScale
        let foregroundHeight = sourceHeight * foregroundScale
        let foreground = sourceImageCI.transformed(by: CGAffineTransform(
            a: foregroundScale,
            b: 0,
            c: 0,
            d: foregroundScale,
            tx: (targetWidth - foregroundWidth) / 2,
            ty: (targetHeight - foregroundHeight) / 2
        ))
        let finalImage = foreground
            .composited(over: darkenedBackground)
            .cropped(to: targetRect)

        let context = CIContext(options: [.workingColorSpace: NSNull()])
        guard let renderedImage = context.createCGImage(finalImage, from: targetRect) else {
            throw NSError(
                domain: "PortraitBlurFillWallpaper",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "无法渲染模糊填充壁纸"]
            )
        }

        let temporaryURL = request.outputURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).tmp")
        guard let destination = CGImageDestinationCreateWithURL(
            temporaryURL as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw NSError(
                domain: "PortraitBlurFillWallpaper",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: "无法创建模糊填充壁纸文件"]
            )
        }

        CGImageDestinationAddImage(
            destination,
            renderedImage,
            [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(
                domain: "PortraitBlurFillWallpaper",
                code: 8,
                userInfo: [NSLocalizedDescriptionKey: "无法写入模糊填充壁纸文件"]
            )
        }

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: request.outputURL.path) {
            try fileManager.removeItem(at: request.outputURL)
        }
        try fileManager.moveItem(at: temporaryURL, to: request.outputURL)
    }
}
