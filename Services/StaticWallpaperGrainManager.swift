import AppKit
import Combine

/// 静态壁纸颗粒蒙层管理器
///
/// 为静态桌面壁纸提供独立的颗粒蒙层 overlay 窗口。
/// 与视频壁纸的颗粒蒙层类似，作为独立窗口覆盖在桌面上，
/// 自动切换壁纸时蒙层不受影响。
@MainActor
final class StaticWallpaperGrainManager {
    static let shared = StaticWallpaperGrainManager()

    /// 每个屏幕的颗粒蒙层窗口（key 为 screenID）
    private var grainWindows: [String: NSWindow] = [:]

    private var cancellables = Set<AnyCancellable>()

    private init() {
        // 监听颗粒开关和强度变化，实时更新蒙层
        ArcBackgroundSettings.shared.$grainTextureEnabled
            .map { _ in () }
            .merge(with: ArcBackgroundSettings.shared.$grainIntensity.map { _ in () })
            .merge(with: NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification).map { _ in () })
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateOverlay()
            }
            .store(in: &cancellables)

        // 监听 Space 切换，重新显示蒙层
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSpaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )

        // 监听屏幕配置变化（外接显示器插拔）
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func handleSpaceChanged() {
        // Space 切换后延迟更新，确保窗口层级正确
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.updateOverlay()
        }
    }

    @objc private func handleScreenParametersChanged() {
        // 屏幕配置变化（外接显示器插拔）后延迟刷新
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.refreshWindows()
        }
    }

    /// 更新所有屏幕的颗粒蒙层
    func updateOverlay() {
        let grainEnabled = ArcBackgroundSettings.shared.grainTextureEnabled
        let grainIntensity = ArcBackgroundSettings.shared.grainIntensity

        if grainEnabled && grainIntensity > 0.01 {
            showOverlay(intensity: grainIntensity)
        } else {
            hideOverlay()
        }
    }

    /// 为所有屏幕显示颗粒蒙层
    private func showOverlay(intensity: Double) {
        for screen in NSScreen.screens {
            let screenID = screen.wallpaperScreenIdentifier

            if let existingWindow = grainWindows[screenID] {
                // 更新现有窗口的强度
                if let contentView = existingWindow.contentView as? GrainOverlayView {
                    contentView.intensity = intensity
                }
                // 确保窗口在正确的层级
                existingWindow.orderFront(nil)
            } else {
                // 创建新的蒙层窗口
                createGrainWindow(for: screen, intensity: intensity)
            }
        }
    }

    /// 隐藏所有屏幕的颗粒蒙层
    private func hideOverlay() {
        for (screenID, window) in grainWindows {
            window.orderOut(nil)
            window.contentView = nil
            grainWindows.removeValue(forKey: screenID)
        }
    }

    /// 为指定屏幕创建颗粒蒙层窗口
    private func createGrainWindow(for screen: NSScreen, intensity: Double) {
        let screenID = screen.wallpaperScreenIdentifier
        let frame = screen.frame

        // 创建透明窗口，位于桌面层级
        let window = NSWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.setFrame(frame, display: true)
        window.level = .init(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1) // 比桌面高一层
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.isMovable = false

        // 创建颗粒蒙层视图
        let grainView = GrainOverlayView(frame: CGRect(origin: .zero, size: frame.size))
        grainView.intensity = intensity
        window.contentView = grainView

        grainWindows[screenID] = window
        window.orderFront(nil)
    }

    /// 刷新所有窗口（屏幕配置变化时调用）
    func refreshWindows() {
        // 移除不再存在的屏幕的窗口
        let currentScreenIDs = Set(NSScreen.screens.map { $0.wallpaperScreenIdentifier })
        for (screenID, window) in grainWindows {
            if !currentScreenIDs.contains(screenID) {
                window.orderOut(nil)
                window.contentView = nil
                grainWindows.removeValue(forKey: screenID)
            }
        }

        // 更新现有窗口的帧
        for screen in NSScreen.screens {
            let screenID = screen.wallpaperScreenIdentifier
            if let window = grainWindows[screenID] {
                window.setFrame(screen.frame, display: true)
                window.contentView?.frame = CGRect(origin: .zero, size: screen.frame.size)
            }
        }

        updateOverlay()
    }
}

// MARK: - 胶片颗粒蒙层视图

/// 胶片颗粒蒙层视图
///
/// NSWindow overlay 方案：半透明黑色噪点 + 普通 alpha 混合。
/// overlay 窗口独立于桌面渲染树，不能用 compositingFilter 做 multiply。
/// 用暗色噪点 + alpha 控制可见度 → 只压暗不加灰，保留壁纸原始色调。
private final class GrainOverlayView: NSView {
    var intensity: Double = 0.5 {
        didSet { updateOpacity() }
    }

    /// 缓存的颗粒纹理 CGImage（黑色噪点，alpha=1）
    private var grainImage: CGImage?
    private let tileSize = CGSize(width: 2048, height: 2048)

    override var isOpaque: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        if window != nil {
            setupGrain()
        }
    }

    // MARK: - 初始化颗粒

    private func setupGrain() {
        guard let layer = self.layer else { return }

        if grainImage == nil {
            grainImage = generateFilmGrainTexture(size: tileSize)
        }
        layer.contents = grainImage
        layer.contentsGravity = .resizeAspectFill
        // 不用 compositingFilter — overlay 窗口是独立渲染树，
        // 普通 alpha 混合即可：暗色噪点通过透明度覆盖在壁纸上。
        updateOpacity()
    }

    private func updateOpacity() {
        layer?.opacity = Float(intensity * 0.10)
    }

    override func resize(withOldSuperviewSize oldSize: NSSize) {
        super.resize(withOldSuperviewSize: oldSize)
        layer?.frame = bounds
    }

    // MARK: - 颗粒纹理生成

    /// 生成暗色噪点纹理（黑色为主，用于 alpha 混合压暗）
    private func generateFilmGrainTexture(size: CGSize) -> CGImage? {
        guard size.width > 0, size.height > 0 else { return nil }

        let context = CIContext(options: [.workingColorSpace: NSNull()])

        // 1. 基础白噪声
        guard let noiseFilter = CIFilter(name: "CIRandomGenerator") else { return nil }
        let margin: CGFloat = 4
        let noiseSize = CGSize(width: size.width + margin * 2, height: size.height + margin * 2)
        let baseNoise = noiseFilter.outputImage?.cropped(to: CGRect(origin: .zero, size: noiseSize))
            ?? CIImage(color: CIColor(red: 0.0, green: 0.0, blue: 0.0))

        // 2. 柔化：0.6px 让单像素噪点变成有机颗粒簇
        guard let blurFilter = CIFilter(name: "CIGaussianBlur") else { return nil }
        blurFilter.setValue(baseNoise, forKey: kCIInputImageKey)
        blurFilter.setValue(0.6, forKey: kCIInputRadiusKey)
        let blurred = blurFilter.outputImage ?? baseNoise

        // 3. 颜色矩阵：映射到 0.0~0.15 暗色范围
        //    scale=0.15, bias=0.0 → 最亮的噪点也只有 15% 灰
        guard let matrixFilter = CIFilter(name: "CIColorMatrix") else { return nil }
        matrixFilter.setValue(blurred, forKey: kCIInputImageKey)
        matrixFilter.setValue(CIVector(x: 0.10, y: 0, z: 0, w: 0), forKey: "inputRVector")
        matrixFilter.setValue(CIVector(x: 0, y: 0.10, z: 0, w: 0), forKey: "inputGVector")
        matrixFilter.setValue(CIVector(x: 0, y: 0, z: 0.10, w: 0), forKey: "inputBVector")
        matrixFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
        matrixFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputBiasVector")
        let grain = matrixFilter.outputImage ?? blurred

        let final = grain.cropped(to: CGRect(origin: CGPoint(x: margin, y: margin), size: size))
        return context.createCGImage(final, from: final.extent)
    }
}
