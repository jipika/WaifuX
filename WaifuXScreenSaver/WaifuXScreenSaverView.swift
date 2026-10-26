import AppKit
import CoreGraphics
import OSLog
import QuartzCore
import ScreenSaver
@preconcurrency import AVFoundation

/// WaifuX 屏保视图。
///
/// 结构对齐 `MirageScreenSaverView`：屏保宿主自己读配置、自己解码渲染，
/// 不要求主程序运行；主程序只负责写 `screensaver.json` 并在改动后发
/// DistributedNotification 通知热重载。
///
/// 与 Mirage 的差异：Scene / Web 壁纸由主程序先离线烘焙成 MP4，
/// 所以这里只有"播视频"和"放静图"两条渲染通路，不需要内嵌场景渲染 dylib。
@objc(WaifuXScreenSaverView)
final class WaifuXScreenSaverView: ScreenSaverView {

    private static let logger = Logger(subsystem: "com.waifux.app.screensaver", category: "Rendering")

    /// 主程序写入配置后广播的通知名。
    static let configurationChangedNotification = Notification.Name("com.waifux.app.screensaver.configurationChanged")

    // MARK: - 状态

    private var configuration: SaverConfiguration?
    private var didLoadWallpaper = false
    private var isAnimatingWallpaper = false
    private var resumeAfterReattach = false
    private var isWaitingForLayout = false
    private var wallpaperLoadWorkItem: DispatchWorkItem?
    private var configurationReload: DispatchWorkItem?
    private var configurationRequestID = UUID()
    private var configurationObserver: NSObjectProtocol?
    private var lastNormalizedScreenSize = CGSize.zero

    // MARK: - 渲染层

    /// 根层：承载 letterbox 底色并裁掉超出屏幕的媒体。
    private let rootLayer = CALayer()
    /// 内容层：用 viewport mask 把媒体裁进可视框（比例预设不是屏幕比例时留黑边）。
    private let contentLayer = CALayer()
    private let viewportMask = CALayer()
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var playerLayer: AVPlayerLayer?
    private var imageLayer: CALayer?
    private var readyObservation: NSKeyValueObservation?
    private var statusObservation: NSKeyValueObservation?
    private var messageLabel: NSTextField?
    private var playbackStarted = false
    private var phaseSeekInFlight = false
    /// 下一次多屏相位核对的时间戳（挂钟秒）。
    private var nextPhaseCheckAt: TimeInterval = 0

    /// 媒体原始像素尺寸；未知时退化为"铺满屏幕"。
    private var mediaSize: CGSize = .zero
    /// 上一次实际应用过的裁剪，用于按秒检测 App 侧改动。
    private var appliedCrop: SaverCropSettings?
    /// 当前实际加载内容的按屏指纹与 displayKey；变化才重载。
    private var loadedPlaybackFingerprint: String?
    private var loadedForDisplayKey: String?
    /// 已排队的上下文重载目标：0.2s debounce 生效前不再重复排队，
    /// 否则每秒 tick 会不断取消并重排，重载永远落不了地。
    private var pendingContextReload: (displayKey: String?, fingerprint: String?)?
    // MARK: - 生命周期

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        // AVPlayerLayer 自己驱动视频帧；此计时器只负责裁剪热更新与低频相位核对。
        animationTimeInterval = 1
        setUpLayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        animationTimeInterval = 1
        setUpLayers()
    }

    private func setUpLayers() {
        autoresizingMask = [.width, .height]
        wantsLayer = true
        rootLayer.masksToBounds = true
        rootLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        layer = rootLayer

        contentLayer.masksToBounds = true
        contentLayer.frame = bounds
        rootLayer.addSublayer(contentLayer)

        viewportMask.backgroundColor = CGColor(gray: 1, alpha: 1)
    }

    override var hasConfigureSheet: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            lastNormalizedScreenSize = .zero
            if isAnimatingWallpaper {
                stopAnimation()
                resumeAfterReattach = true
            } else {
                releaseWallpaper()
            }
        } else if resumeAfterReattach {
            // 只恢复曾经真正启动过的视图；系统设置创建的未启动缩略图不能自行播视频。
            resumeAfterReattach = false
            startAnimation()
        } else {
            scheduleWallpaperLoad()
        }
    }

    override func startAnimation() {
        guard !isAnimatingWallpaper else { return }
        super.startAnimation()
        isAnimatingWallpaper = true
        observeConfiguration()
        scheduleWallpaperLoad()
    }

    override func stopAnimation() {
        resumeAfterReattach = false
        guard isAnimatingWallpaper else { return }
        isAnimatingWallpaper = false
        configurationRequestID = UUID()
        configurationReload?.cancel()
        configurationReload = nil
        releaseWallpaper()
        super.stopAnimation()
    }

    override func layout() {
        super.layout()
        normalizeFullScreenBoundsIfNeeded()
        guard hasValidBounds else {
            releaseWallpaper()
            return
        }
        scheduleWallpaperLoad()
        rootLayer.contentsScale = window?.backingScaleFactor ?? rootLayer.contentsScale
        playerLayer?.contentsScale = rootLayer.contentsScale
        applyGeometry()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        scheduleWallpaperLoad()
    }

    override func setBoundsSize(_ newSize: NSSize) {
        super.setBoundsSize(newSize)
        scheduleWallpaperLoad()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
        scheduleWallpaperLoad()
    }

    override func animateOneFrame() {
        guard isAnimatingWallpaper, window != nil else { return }
        // 裁剪是用户在 App 里随手拖的，改完不一定触发配置通知；
        // 屏保计时器每秒触发一次；视频帧由 AVPlayerLayer 独立驱动。
        refreshCropIfNeeded()
        reloadIfPlaybackContextChanged()
        syncPlaybackPhaseIfNeeded()
    }

    // MARK: - 加载

    private func scheduleWallpaperLoad() {
        guard isAnimatingWallpaper, !didLoadWallpaper, window != nil, wallpaperLoadWorkItem == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.wallpaperLoadWorkItem = nil
            self.loadWallpaper()
        }
        wallpaperLoadWorkItem = work
        DispatchQueue.main.async(execute: work)
    }

    private func loadWallpaper(_ replacement: SaverConfiguration? = nil) {
        guard isAnimatingWallpaper, !didLoadWallpaper, window != nil else { return }
        layoutSubtreeIfNeeded()
        normalizeFullScreenBoundsIfNeeded()
        layoutSubtreeIfNeeded()
        guard hasValidBounds, displayPixelSize() != nil else {
            if !isWaitingForLayout {
                isWaitingForLayout = true
                Self.logger.info("Waiting for valid screen saver layout: \(self.bounds.width) x \(self.bounds.height)")
            }
            return
        }
        isWaitingForLayout = false
        didLoadWallpaper = true
        guard let configuration = replacement ?? SaverConfiguration.load() else {
            showMessage(localized("noConfiguration"))
            return
        }
        // 多屏异壁纸：每块屏的屏保进程各取自己 displayKey 的条目；
        // 取不到（设置页预览 / 起屏早期 window.screen 为 nil）回退主屏条目。
        guard let entry = configuration.wallpaperEntry(forDisplayKey: currentDisplayKey) else {
            showMessage(localized("noConfiguration"))
            return
        }
        self.configuration = configuration
        loadedForDisplayKey = currentDisplayKey
        loadedPlaybackFingerprint = configuration.playbackFingerprint(forDisplayKey: currentDisplayKey)
        pendingContextReload = nil
        Self.logger.info("Loading wallpaper title=\(entry.title) kind=\(entry.kind.rawValue) path=\(entry.renderURL.path) display=\(self.loadedForDisplayKey ?? "nil")")
        switch entry.kind {
        case .video: loadVideo(entry)
        case .image: loadImage(entry)
        }
        // loadWallpaper 之前可能已经跑过一次 layout（那时还没有配置，只能用默认裁剪），
        // 这里立刻按真实配置重排一次，避免要等下一次 layout / 动画回调才生效。
        applyGeometry()
    }

    private func observeConfiguration() {
        guard configurationObserver == nil else { return }
        configurationObserver = DistributedNotificationCenter.default().addObserver(
            forName: Self.configurationChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // 注册时指定了 queue: .main，这里直接认领主线程语义。
            MainActor.assumeIsolated {
                self?.reloadConfiguration()
            }
        }
    }

    private func reloadConfiguration() {
        guard isAnimatingWallpaper else { return }
        configurationReload?.cancel()
        let request = UUID()
        configurationRequestID = request
        let work = DispatchWorkItem { [weak self] in
            let value = SaverConfiguration.load()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.configurationRequestID == request, self.isAnimatingWallpaper else { return }
                guard let value else {
                    self.releaseWallpaper()
                    self.showMessage(self.localized("noConfiguration"))
                    return
                }
                // 按屏比较：本屏条目没变的屏保持正在播放的画面，不因别屏换壁纸而重载。
                let displayKey = self.currentDisplayKey
                if value.playbackFingerprint(forDisplayKey: displayKey) == self.loadedPlaybackFingerprint,
                   displayKey == self.loadedForDisplayKey {
                    self.pendingContextReload = nil
                    return
                }
                self.releaseWallpaper()
                self.loadWallpaper(value)
            }
        }
        configurationReload = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    // MARK: - 视频

    private func loadVideo(_ entry: SaverWallpaperEntry) {
        teardownMedia()
        guard let configuration = self.configuration else { return }
        let item = AVPlayerItem(url: entry.renderURL)
        let player = AVQueuePlayer()
        player.automaticallyWaitsToMinimizeStalling = true
        player.isMuted = configuration.muted
        player.preventsDisplaySleepDuringVideoPlayback = false
        let looper = AVPlayerLooper(player: player, templateItem: item)
        let playbackItem = player.currentItem ?? item

        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.frame = bounds
        playerLayer.contentsScale = window?.backingScaleFactor ?? 1
        playerLayer.backgroundColor = CGColor(gray: 0, alpha: 0)
        contentLayer.addSublayer(playerLayer)
        applyVideoDynamicRange(to: playerLayer, enabled: configuration.enableHDRVideo)

        self.player = player
        self.looper = looper
        self.playerLayer = playerLayer

        // AVQueuePlayer 对本地文件也可能等到 play 请求后才把首个循环 item
        // 推进到 readyToPlay；先启动解码，随后在就绪回调中至多锁相一次。
        player.playImmediately(atRate: configuration.playbackRate)

        readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
            guard layer.isReadyForDisplay else { return }
            DispatchQueue.main.async {
                guard let self, self.playerLayer?.isReadyForDisplay == true else { return }
                self.updateMediaSize()
                self.hideMessage()
            }
        }
        statusObservation = playbackItem.observe(\.status, options: [.initial, .new]) { [weak self, weak player] item, _ in
            switch item.status {
            case .readyToPlay:
                // readiness 回调（isReadyForDisplay）在部分宿主/预览场景下会迟到甚至不来，
                // 所以解码器一就绪就补上媒体尺寸，避免首帧先按屏幕比例铺满再跳一下。
                DispatchQueue.main.async {
                    guard let self, let player, self.player === player else { return }
                    self.updateMediaSize()
                    self.startVideoPlaybackIfNeeded(rate: configuration.playbackRate)
                }
            case .failed:
                let reason = item.error?.localizedDescription ?? "unknown"
                DispatchQueue.main.async {
                    guard let self, let player, self.player === player else { return }
                    Self.logger.error("Screen saver video failed: \(reason)")
                    self.showMessage(self.localized("unplayableVideo"))
                }
            default:
                break
            }
        }

        if playbackItem.status == .readyToPlay {
            startVideoPlaybackIfNeeded(rate: configuration.playbackRate)
        }
    }

    // MARK: - 多屏相位同步

    /// 多块屏的 legacyScreenSaver 是互相独立的进程，启动时刻各不相同，各自从 0
    /// 起播会永久错位。所有屏读同一份配置、共用同一台机器的时钟，所以把播放
    /// 位置锁成挂钟的确定函数（position = 挂钟 × 倍率 mod 时长）：任意时刻
    /// 各屏天然处于同一相位，起播先后只影响第一帧的落点，不影响对齐。
    private func synchronizedPhase(forDuration duration: Double) -> Double {
        let rate = Double(max(configuration?.playbackRate ?? 1, 0.01))
        var phase = (Date().timeIntervalSinceReferenceDate * rate)
            .truncatingRemainder(dividingBy: duration)
        if phase < 0 { phase += duration }
        return phase
    }

    /// 首次就绪时只 seek 一次；重复的 readiness 回调不能打断已播放的视频。
    private func startVideoPlaybackIfNeeded(rate: Float) {
        guard isAnimatingWallpaper, !playbackStarted else { return }
        guard let player else { return }
        playbackStarted = true
        let duration = player.currentItem?.duration.seconds ?? 0
        guard duration.isFinite, duration > 0 else {
            // 时长未知（流式/探测失败）时无从锁相，退回直接起播。
            player.playImmediately(atRate: rate)
            return
        }
        let target = CMTime(seconds: synchronizedPhase(forDuration: duration), preferredTimescale: 600)
        player.seek(
            to: target,
            toleranceBefore: CMTime(seconds: 0.1, preferredTimescale: 600),
            toleranceAfter: CMTime(seconds: 0.1, preferredTimescale: 600)
        ) { [weak self, weak player] _ in
            DispatchQueue.main.async {
                guard let self, let player, self.player === player, self.isAnimatingWallpaper else { return }
                player.playImmediately(atRate: rate)
            }
        }
    }

    /// 仅在多屏实际播放且明显失步时校正。正常播放不做周期性 seek，
    /// 否则解码器会反复丢弃缓冲帧，表现为每隔几秒卡一下。
    private func syncPlaybackPhaseIfNeeded() {
        guard isAnimatingWallpaper, NSScreen.screens.count > 1, isFullScreenHostWindow,
              !phaseSeekInFlight, let player, player.timeControlStatus == .playing else { return }
        let now = Date().timeIntervalSinceReferenceDate
        guard now >= nextPhaseCheckAt else { return }
        nextPhaseCheckAt = now + 30
        let duration = player.currentItem?.duration.seconds ?? 0
        guard duration.isFinite, duration > 0 else { return }
        let expected = synchronizedPhase(forDuration: duration)
        let current = player.currentTime().seconds
        guard current.isFinite, expected > 1, duration - expected > 1 else { return }
        var delta = current - expected
        delta -= duration * (delta / duration).rounded()
        if abs(delta) > 1.5 {
            phaseSeekInFlight = true
            player.seek(
                to: CMTime(seconds: expected, preferredTimescale: 600),
                toleranceBefore: CMTime(seconds: 0.25, preferredTimescale: 600),
                toleranceAfter: CMTime(seconds: 0.25, preferredTimescale: 600)
            ) { [weak self, weak player] _ in
                DispatchQueue.main.async {
                    guard let self, let player, self.player === player else { return }
                    self.phaseSeekInFlight = false
                }
            }
        }
    }

    /// 视频原始尺寸：优先 presentationSize，其次 readyForDisplay 后的 videoRect。
    private func updateMediaSize() {
        guard let playerLayer else { return }
        var size = playerLayer.player?.currentItem?.presentationSize ?? .zero
        if size.width <= 0 || size.height <= 0 {
            size = playerLayer.videoRect.size
        }
        guard size.width > 0, size.height > 0 else { return }
        mediaSize = size
        applyGeometry()
    }

    // MARK: - 静图

    private func loadImage(_ entry: SaverWallpaperEntry) {
        teardownMedia()
        guard let image = NSImage(contentsOf: entry.renderURL),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            showMessage(localized("missingMedia"))
            return
        }
        let layer = CALayer()
        layer.contents = cgImage
        layer.contentsGravity = .resizeAspectFill
        layer.masksToBounds = true
        layer.frame = bounds
        contentLayer.addSublayer(layer)
        imageLayer = layer
        mediaSize = CGSize(width: cgImage.width, height: cgImage.height)
        applyGeometry()
    }

    // MARK: - 几何

    private func applyGeometry() {
        guard hasValidBounds else { return }
        let crop = configuration?.cropSettings(forDisplayKey: currentDisplayKey) ?? .default
        let screenSize = displayPixelSize() ?? bounds.size
        // 尺寸未知时按屏幕比例兜底，等 readiness 回调补上真实尺寸再重排。
        let wallpaperSize = mediaSize == .zero ? screenSize : mediaSize
        let layout = SaverCropEngine.compute(wallpaperSize: wallpaperSize, screenSize: screenSize, settings: crop)
        apply(layout: layout)
        appliedCrop = crop
    }

    /// 检测 App 侧裁剪改动，变了才重排。
    private func refreshCropIfNeeded() {
        guard configuration != nil else { return }
        let crop = configuration?.cropSettings(forDisplayKey: currentDisplayKey) ?? .default
        guard crop != appliedCrop else { return }
        applyGeometry()
    }

    /// 每秒核对播放上下文：配置被重写而通知丢失、或本屏 displayKey 变化
    /// （起屏早期先按主屏条目播，key 解析出来后切到本屏条目）时重载。
    /// pendingContextReload 闸门防止 debounce 窗口内反复取消重排；
    /// 实际重载由 reloadConfiguration 异步执行，不在渲染回调栈里直接改层。
    private func reloadIfPlaybackContextChanged() {
        guard let configuration else { return }
        let key = currentDisplayKey
        let fingerprint = configuration.playbackFingerprint(forDisplayKey: key)
        guard key != loadedForDisplayKey || fingerprint != loadedPlaybackFingerprint else { return }
        if let pending = pendingContextReload, pending.displayKey == key, pending.fingerprint == fingerprint { return }
        pendingContextReload = (displayKey: key, fingerprint: fingerprint)
        reloadConfiguration()
    }

    private func apply(layout: SaverCropLayout) {
        let geometry = SaverCropGeometry.layerGeometry(layout: layout, in: bounds)
        rootLayer.backgroundColor = layout.letterboxColor
        contentLayer.frame = bounds
        // 只有可视框小于屏幕（比例预设 / 平移裁切）时才需要 mask；
        // 全屏时摘掉 mask，省一层合成。
        let coversScreen = geometry.viewportRect.insetBy(dx: -0.5, dy: -0.5).contains(bounds)
        if coversScreen {
            contentLayer.mask = nil
        } else {
            viewportMask.frame = geometry.viewportRect
            contentLayer.mask = viewportMask
        }
        playerLayer?.frame = geometry.mediaFrame
        imageLayer?.frame = geometry.mediaFrame
    }

    private func applyVideoDynamicRange(to playerLayer: AVPlayerLayer, enabled: Bool) {
        let screen = window?.screen ?? NSScreen.main
        let useHDR = enabled && (screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1) > 1
        if #available(macOS 26.0, *) {
            let range: CALayer.DynamicRange = useHDR ? .constrainedHigh : .standard
            rootLayer.preferredDynamicRange = range
            playerLayer.preferredDynamicRange = range
        } else {
            rootLayer.wantsExtendedDynamicRangeContent = useHDR
            playerLayer.wantsExtendedDynamicRangeContent = useHDR
        }
    }

    // MARK: - 释放

    private func teardownMedia() {
        readyObservation?.invalidate()
        readyObservation = nil
        statusObservation?.invalidate()
        statusObservation = nil
        player?.pause()
        looper?.disableLooping()
        playerLayer?.player = nil
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
        player?.removeAllItems()
        player = nil
        looper = nil
        imageLayer?.removeFromSuperlayer()
        imageLayer = nil
        mediaSize = .zero
        appliedCrop = nil
        playbackStarted = false
        phaseSeekInFlight = false
        nextPhaseCheckAt = 0
    }

    private func releaseWallpaper() {
        wallpaperLoadWorkItem?.cancel()
        wallpaperLoadWorkItem = nil
        if !isAnimatingWallpaper || window == nil { isWaitingForLayout = false }
        // Swift 6 里 deinit 是 nonisolated，碰不到这些主线程属性，
        // 所以把清理收在这里：stopAnimation / 移出窗口时都会走到。
        configurationReload?.cancel()
        configurationReload = nil
        if let configurationObserver {
            DistributedNotificationCenter.default().removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        teardownMedia()
        hideMessage()
        configuration = nil
        didLoadWallpaper = false
        loadedPlaybackFingerprint = nil
        loadedForDisplayKey = nil
        pendingContextReload = nil
    }

    // MARK: - 布局兜底

    /// 屏保宿主首帧可能给出与实际显示器不一致的 bounds（起屏动画期间尤其明显），
    /// 这里把 frame/bounds 归一到当前屏幕的逻辑尺寸，避免画面被拉伸或留边。
    private func normalizeFullScreenBoundsIfNeeded() {
        // Tahoe/27 的 legacyScreenSaver 有时把预览错报为非预览；先验证宿主窗口
        // 真的覆盖了显示器，避免把设置页中的小预览放大到全屏并反复触发布局。
        guard isFullScreenHostWindow else { return }
        guard let screen = window?.screen ?? NSScreen.main else { return }
        guard screen.backingScaleFactor.isFinite, screen.backingScaleFactor > 0 else { return }
        let backingSize = screen.convertRectToBacking(screen.frame).size
        let logicalSize = CGSize(
            width: backingSize.width / screen.backingScaleFactor,
            height: backingSize.height / screen.backingScaleFactor
        )
        guard logicalSize.width.isFinite, logicalSize.height.isFinite,
              logicalSize.width > 0, logicalSize.height > 0 else { return }
        guard !approximatelyEqual(lastNormalizedScreenSize, logicalSize) else { return }
        lastNormalizedScreenSize = logicalSize
        if !approximatelyEqual(bounds.size, logicalSize) {
            var normalizedBounds = bounds
            normalizedBounds.size = logicalSize
            bounds = normalizedBounds
        }
        if !approximatelyEqual(frame.size, logicalSize) {
            var normalizedFrame = frame
            normalizedFrame.size = logicalSize
            frame = normalizedFrame
        }
    }

    private func approximatelyEqual(_ lhs: CGSize, _ rhs: CGSize) -> Bool {
        abs(lhs.width - rhs.width) <= 1 && abs(lhs.height - rhs.height) <= 1
    }

    private var hasValidBounds: Bool {
        bounds.width.isFinite && bounds.height.isFinite && bounds.width > 0 && bounds.height > 0
    }

    private func displayPixelSize() -> CGSize? {
        guard let screen = window?.screen ?? NSScreen.main else { return nil }
        let size = isFullScreenHostWindow
            ? screen.convertRectToBacking(screen.frame).size
            : screen.convertRectToBacking(bounds).size
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
        return size
    }

    private var isFullScreenHostWindow: Bool {
        guard let window, let screen = window.screen else { return false }
        let visible = window.frame.intersection(screen.frame)
        return visible.width >= screen.frame.width * 0.9
            && visible.height >= screen.frame.height * 0.9
    }

    private var currentDisplayKey: String? {
        guard isFullScreenHostWindow, let screen = window?.screen,
              let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        else { return nil }
        return saverDisplayKey(displayID)
    }

    // MARK: - 文案

    private func localized(_ key: String) -> String {
        SaverLocalization.string(key, language: configuration?.language)
    }

    private func showMessage(_ text: String) {
        guard messageLabel?.stringValue != text else { return }
        messageLabel?.removeFromSuperview()
        let label = NSTextField(labelWithString: text)
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 18, weight: .medium)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24)
        ])
        messageLabel = label
    }

    private func hideMessage() {
        messageLabel?.removeFromSuperview()
        messageLabel = nil
    }
}
