import AppKit
import Kingfisher

/// 封面图片视图：layer.contents + contentsGravity 绘制（GIF 覆盖播放也走这里的 aspect-fill）。
/// 文件夹叠图等场景复用。
final class ExploreGridCoverImageView: NSImageView {
    /// 列表封面默认 `.resizeAspectFill` 铺满。
    /// 注意：cell 高度按**原图**比例自动算，但列表加载的是 Wallhaven thumb（常为横裁中心图），
    /// 预览图比例 ≠ cell 比例；若用 fit 会 letterbox 成“只显示半截”。
    var preferredContentsGravity: CALayerContentsGravity = .resizeAspectFill {
        didSet {
            guard preferredContentsGravity != oldValue else { return }
            updateLayerContents()
        }
    }

    override var image: NSImage? {
        didSet { updateLayerContents() }
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        updateLayerContents()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateLayerContents()
    }

    private func updateLayerContents() {
        guard let layer else { return }

        // 走 layer.contents 时关掉 NSImageView 自己的缩放，避免与 contentsGravity 打架。
        imageScaling = .scaleAxesIndependently
        layer.contentsGravity = preferredContentsGravity
        layer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2

        guard let image, image.size.width > 0, image.size.height > 0 else {
            layer.contents = nil
            return
        }

        // 保留 NSImage 自身的多分辨率表示，避免提前压平成单张 CGImage 后丢掉 Retina 细节。
        layer.contents = image
    }
}

/// cell 根视图：右键菜单（menu(for:) 只能在 NSView 上覆写），
/// 转发给持有它的 ExploreGridItem 子类的 cellMenu(for:)。
final class ExploreGridItemRootView: NSView {
    weak var owningItem: ExploreGridItem?

    override func menu(for event: NSEvent) -> NSMenu? {
        owningItem?.cellMenu(for: event)
    }
}

/// GIF 静态封面处理器：数据确为多帧 GIF 时取**中间帧**做静态封面
/// （大量动图前几帧是黑色淡入，直接显示首帧会常驻一块黑图），
/// 其余格式回落到 DownsamplingImageProcessor 同款逻辑。
/// 注意必须作为第一个（唯一）处理器使用：它只处理 `.data` 输入。
struct GIFAwareMiddleFrameImageProcessor: ImageProcessor {
    let identifier: String
    private let downsampleSize: CGSize
    private let pixelScale: CGFloat

    init(targetSize: CGSize, scaleFactor: CGFloat) {
        self.downsampleSize = targetSize
        self.pixelScale = max(1, scaleFactor)
        self.identifier = "com.waifux.gifmid|\(Int(targetSize.width))x\(Int(targetSize.height))@\(Int(pixelScale))"
    }

    func process(item: ImageProcessItem, options: KingfisherParsedOptionsInfo) -> NSImage? {
        switch item {
        case .data(let data):
            if data.starts(with: Data("GIF".utf8)),
               let image = Self.middleFrameImage(
                   from: data,
                   maxPixelSize: max(downsampleSize.width, downsampleSize.height) * pixelScale
               ) {
                return image
            }
            return DownsamplingImageProcessor(size: downsampleSize).process(item: item, options: options)
        case .image(let image):
            return image
        }
    }

    /// 取第 count/2 帧的缩略图。GIF 帧间的 delta 合成由 ImageIO 内部完成
    /// （与 startAnimatingIfAnimated 的逐帧采样同一路径，已在库页验证无残影）。
    static func middleFrameImage(from data: Data, maxPixelSize: CGFloat) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return nil }
        let index = count / 2
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: .zero)
    }
}

/// 通用网格 Cell 基类
/// 支持 Cell 复用（prepareForReuse）、图片加载/取消、hover 缩放效果
class ExploreGridItem: NSCollectionViewItem {

    static let reuseIdentifier = NSUserInterfaceItemIdentifier("ExploreGridItem")

    /// 该 cell 类在 NSCollectionView 里的注册标识。混排网格（如我的库
    /// 「文件夹 + 项目」）按类注册/复用；子类可覆写提供独立标识。
    class var gridReuseIdentifier: NSUserInterfaceItemIdentifier {
        ExploreGridItem.reuseIdentifier
    }

    // MARK: - 子视图

    /// 封面图片视图（避免与 NSCollectionViewItem.imageView 冲突）
    let coverImageView: NSImageView = {
        let iv = ExploreGridCoverImageView()
        // 实际缩放由 layer.contentsGravity 控制（见 updateLayerContents）
        iv.imageScaling = .scaleAxesIndependently
        iv.wantsLayer = true
        iv.layerContentsRedrawPolicy = .never
        iv.layer?.cornerRadius = 14
        iv.layer?.masksToBounds = true
        iv.layer?.contentsGravity = .resizeAspectFill
        iv.layer?.minificationFilter = .trilinear
        iv.layer?.magnificationFilter = .trilinear
        return iv
    }()

    /// 动画 GIF 覆盖层。默认隐藏，启用的 cell 在 hover 时叠在静态封面上，
    /// 保持旧 SwiftUI ZStack 的底图常驻语义，避免切换播放层时短暂露出空白。
    private let gifOverlayImageView: NSImageView = {
        let iv = ExploreGridCoverImageView()
        iv.imageScaling = .scaleAxesIndependently
        iv.wantsLayer = true
        iv.layerContentsRedrawPolicy = .never
        iv.layer?.cornerRadius = 14
        iv.layer?.masksToBounds = true
        iv.layer?.contentsGravity = .resizeAspectFill
        iv.layer?.minificationFilter = .trilinear
        iv.layer?.magnificationFilter = .trilinear
        iv.isHidden = true
        return iv
    }()

    let containerView: NSView = {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.cornerRadius = 16
        v.layer?.masksToBounds = true
        return v
    }()

    private let cardSurfaceView: NSView = {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.masksToBounds = false
        return v
    }()

    /// 边框层 — 子类可修改 borderWidth / borderColor 以适配不同 purity
    let borderLayer: CALayer = {
        let l = CALayer()
        l.cornerRadius = 16
        l.masksToBounds = true
        l.borderWidth = 1
        l.borderColor = NSColor.white.withAlphaComponent(0.06).cgColor
        return l
    }()

    /// 自定义内容视图（子类可添加标签、底栏等）
    let contentView: NSView = {
        let v = NSView()
        v.wantsLayer = true
        return v
    }()

    // MARK: - 状态

    private var loadTask: Task<Void, Never>?
    /// Kingfisher 当前在飞的网络下载句柄。
    /// 仅取消外层 Swift `Task` 不能真正中断 Kingfisher 内部 `DownloadTask`，
    /// 后者会继续把数据下载完成再丢弃。快速滚动时大量请求堆积是历史内存
    /// 异常的主因之一。改用 callback 版 retrieveImage 拿到该句柄，
    /// `prepareForReuse` / 重新加载时一并 cancel，让网络层真停下来。
    /// 注意：项目内有同名 `DownloadTask` 类型，必须用 `Kingfisher.DownloadTask` 全限定。
    private var kfDownloadTask: Kingfisher.DownloadTask?
    /// 当前正在加载（或已加载）的图片 URL，用于 tab 切回时跳过重复的 Kingfisher 请求
    private var currentLoadingURL: URL?
    /// 上次 loadImage 的目标点尺寸；bounds 变大后需要按新尺寸重解码
    private var currentLoadingTargetSize: CGSize = .zero
    private(set) var isHovered = false
    private var isHoverInteractionEnabled = true
    private var trackingArea: NSTrackingArea?

    // MARK: - 动画 GIF 支持
    private var animationTimer: Timer?
    private var animatedFrames: [(image: NSImage, duration: TimeInterval)] = []
    private var currentFrameIndex: Int = 0
    private static let animatedGIFDataCache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.countLimit = 4
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()
    private nonisolated static let maxAnimatedGIFDataBytes = 32 * 1024 * 1024
    private struct PreparedGIFFrame: @unchecked Sendable {
        let image: CGImage
        let duration: TimeInterval
    }
    var hoverExpansionAllowance: CGFloat = 0 {
        didSet {
            guard abs(hoverExpansionAllowance - oldValue) > 0.5 else { return }
            layoutCardFrame()
        }
    }
    private var cardCornerRadius: CGFloat = 16

    var shouldAnimateScaleOnHover: Bool { true }
    var shouldAnimateBorderOnHover: Bool { true }
    /// 子类开启后，hover 时卡片获得投影（默认关：壁纸探索卡片常态无投影）。
    /// 投影挂在未裁切的 cardSurfaceView layer 上，非 hover 态 opacity=0，零合成开销。
    var shouldShowShadowOnHover: Bool { false }
    /// 子类需要在静态封面上叠加 GIF 时开启，静态封面本身不会被动画帧替换。
    var usesGIFOverlay: Bool { false }
    /// 编辑态等场景可关闭 hover；已有 hover 在配置切换时由子类主动清理。
    var allowsHoverInteraction: Bool { true }
    var hoverScaleFactor: CGFloat { 1.035 }
    var hoverOverlayMaxOpacity: Float { 0.02 }

    // MARK: - Border State

    private(set) var normalBorderWidth: CGFloat = 1
    private(set) var normalBorderColor: NSColor = NSColor.white.withAlphaComponent(0.06)

    // MARK: - Lifecycle

    /// **重要**：cell 被 dealloc（非复用）时也必须停下在飞的下载与定时器，
    /// 否则 Kingfisher 内部 `DownloadTask` 会继续跑完整次下载（数据写入磁盘缓存后被丢弃），
    /// 在窗口隐藏 / contentView 被释放等场景下导致瞬时内存压力放大。
    /// `prepareForReuse` 只覆盖复用路径，**dealloc 必须靠 deinit 兜底**。
    /// 注：`ExploreGridItem` 由 NSCollectionView 在主线程持有/释放，deinit 实际运行在主线程，
    /// 这里 `MainActor.assumeIsolated` 是为了在 Swift 6 strict concurrency 下访问主 actor 隔离的属性。
    deinit {
        MainActor.assumeIsolated {
            kfDownloadTask?.cancel()
            kfDownloadTask = nil
            loadTask?.cancel()
            loadTask = nil
            animationTimer?.invalidate()
            animationTimer = nil
        }
    }

    override func loadView() {
        let rootView = ExploreGridItemRootView()
        rootView.owningItem = self
        view = rootView
        view.wantsLayer = true
        view.layer?.masksToBounds = false
        // 不关闭 translatesAutoresizingMaskIntoConstraints：NSCollectionView 在 tile() 中
        // 通过 frame 定位 cell view，如果关闭此属性，Auto Layout 引擎会尝试通过约束
        // 定位 view，但 cell view 没有外部约束，可能导致布局引擎进入不稳定状态。

        // 根 view 由 NSCollectionView 管理，只负责占位/tracking。
        // Hover 缩放作用在内部 cardSurfaceView，避免和 collection item 布局定位互相影响。
        view.addSubview(cardSurfaceView)
        // CALayer 的默认 anchorPoint 就是中心点；hover 只做纯 scale，避免额外平移补偿造成斜向漂移。
        cardSurfaceView.layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        cardSurfaceView.addSubview(containerView)
        containerView.addSubview(coverImageView)
        containerView.addSubview(gifOverlayImageView)
        containerView.addSubview(contentView)
        cardSurfaceView.layer?.addSublayer(borderLayer)
        cardSurfaceView.layer?.allowsEdgeAntialiasing = false
        containerView.layer?.allowsEdgeAntialiasing = false
        borderLayer.zPosition = 10

        setupLayout()
        setupContentLayout()
        installHoverTrackingAreaIfNeeded()
    }

    override func prepareForReuse() {
        super.prepareForReuse()

        kfDownloadTask?.cancel()
        kfDownloadTask = nil
        loadTask?.cancel()
        loadTask = nil
        currentLoadingURL = nil
        currentLoadingTargetSize = .zero
        // 先恢复快照再清空封面，避免动画帧残留到下一个 item
        stopGIFOverlayPlayback()
        coverImageView.image = nil
        stopAnimating()

        isHovered = false
        removeHoverAnimations()
        view.layer?.zPosition = 0
        layoutCardFrame()

        normalBorderWidth = 1
        normalBorderColor = NSColor.white.withAlphaComponent(0.06)
        borderLayer.borderWidth = normalBorderWidth
        borderLayer.borderColor = normalBorderColor.cgColor
        // 复用不走 setHovered 路径，这里显式清掉可能残留的 hover 投影
        applyHoverShadow(false)
    }

    /// 子类调用此方法来设置常态边框（hover 效果会在此基础上叠加）
    func setNormalBorder(width: CGFloat, color: NSColor) {
        normalBorderWidth = width
        normalBorderColor = color
        borderLayer.borderWidth = width
        let targetAlpha = isHovered ? hoverBorderAlpha(for: color) : color.alphaComponent
        borderLayer.borderColor = color.withAlphaComponent(targetAlpha).cgColor
    }

    func setCardCornerRadius(_ radius: CGFloat) {
        cardCornerRadius = radius
        containerView.layer?.cornerRadius = radius
        borderLayer.cornerRadius = radius
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        layoutCardFrame()
    }

    // MARK: - 布局

    private func setupLayout() {
        containerView.translatesAutoresizingMaskIntoConstraints = true
        coverImageView.translatesAutoresizingMaskIntoConstraints = true
        gifOverlayImageView.translatesAutoresizingMaskIntoConstraints = true
        contentView.translatesAutoresizingMaskIntoConstraints = true
    }

    /// 子类重写此方法来添加自定义内容布局
    func setupContentLayout() {
        // 默认由 layoutContentFrames() 手动填充，避免复用初始 0 高时触发约束冲突。
    }

    /// 子类重写此方法来布局卡片内部内容。
    func layoutContentFrames() {
        coverImageView.frame = containerView.bounds
        contentView.frame = containerView.bounds
    }

    /// 让动画覆盖层始终与当前静态封面区域一致。库卡片的封面不占整张 card，
    /// 因此不能只把覆盖层铺满 container。
    func syncGIFOverlayFrame() {
        gifOverlayImageView.frame = coverImageView.frame
        gifOverlayImageView.layer?.cornerRadius = coverImageView.layer?.cornerRadius ?? 0
        gifOverlayImageView.layer?.maskedCorners = coverImageView.layer?.maskedCorners ?? []
    }

    // MARK: - 配置

    /// 子类重写此方法来配置 Cell 内容
    func configure(with item: Any, isFavorite: Bool) {
        // 子类实现
    }

    func hoverStateDidChange(_ hovering: Bool) {
        // 子类按需覆写
    }

    /// 子类覆写：返回右键菜单。由根视图 ExploreGridItemRootView.menu(for:) 触发
    /// （menu(for:) 只能在 NSView 子类上覆写，controller 链不允许 override）。
    func cellMenu(for event: NSEvent) -> NSMenu? {
        nil
    }

    /// 加载图片。传入单个 URL，使用 Kingfisher 内置缓存。
    func loadImage(url: URL?, targetSize: CGSize) {
        guard let url else { return }
        loadImage(urls: [url], targetSize: targetSize)
    }

    /// 配置封面缩放模式。竖图用 fit 完整显示，横图用 fill 铺满。
    func setCoverContentsGravity(_ gravity: CALayerContentsGravity) {
        if let cover = coverImageView as? ExploreGridCoverImageView {
            cover.preferredContentsGravity = gravity
        } else {
            coverImageView.layer?.contentsGravity = gravity
        }
    }

    /// 加载图片。在候选 URL 中选**比例匹配里更清晰**的一档显示。
    /// - Parameter targetSize: **点**尺寸（显示区域）。Downsampling 用 size×scaleFactor 得像素。
    /// - Parameter preferredAspectRatio: 封面显示区的宽高比（w/h，点单位即可）。
    ///   提供后比例匹配优先于清晰度：Wallhaven 缩略图实测 lg 恒为 432×243（16:9 中心横裁）、
    ///   small 恒为 300×200（3:2 横裁）、仅 orig 保原图比例但长边只有 300px。
    ///   旧逻辑只比像素边，竖卡上 lg(432) 恒胜 orig(300)，结果显示横裁条再被 fill 放大——
    ///   即“竖图显示不完整且模糊”的根因。
    ///   提供该参数时启用渐进上屏：比例匹配的低清候选先显示，更高清候选下载完成后原地升级。
    /// - Parameter preferGIFMiddleFrame: true 时静态封面用 GIFAwareMiddleFrameImageProcessor：
    ///   候选确为多帧 GIF 就显示中间帧而非首帧（规避黑色开场帧常驻封面）。
    func loadImage(
        urls: [URL],
        targetSize: CGSize,
        preferredAspectRatio: CGFloat? = nil,
        preferGIFMiddleFrame: Bool = false
    ) {
        guard !urls.isEmpty else { return }

        let pointSize = CGSize(
            width: max(targetSize.width, 64),
            height: max(targetSize.height, 64)
        )
        // URL 相同且目标尺寸没有明显变大时跳过（tab 切回 / 重复 configure）
        let sizeGrew =
            pointSize.width > currentLoadingTargetSize.width + 24
            || pointSize.height > currentLoadingTargetSize.height + 24
        if urls.first == currentLoadingURL, !sizeGrew {
            return
        }

        let scale = view.window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
        // Kingfisher: maxPixelSize = max(size.w, size.h) * scaleFactor
        // 点尺寸 + scaleFactor 才是正确像素预算；不要预先 * scale。
        let neededPixelEdge = max(pointSize.width, pointSize.height) * scale
        // 旧逻辑 0.55 太松：800px 源对 1440px 需求也会被当成“够了”直接停，竖卡必糊。
        // 0.90 才算够清晰；达不到则继续试下一档（original）。
        let goodEnoughPixelEdge = neededPixelEdge * 0.90

        currentLoadingURL = urls.first
        currentLoadingTargetSize = pointSize
        // 取消上一轮的 Swift Task 与 Kingfisher 下载，避免重复下载堆积
        kfDownloadTask?.cancel()
        kfDownloadTask = nil
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }

            let options: KingfisherOptionsInfo = [
                .processor(
                    preferGIFMiddleFrame
                        ? GIFAwareMiddleFrameImageProcessor(targetSize: pointSize, scaleFactor: CGFloat(scale))
                        : DownsamplingImageProcessor(size: pointSize)
                ),
                .scaleFactor(CGFloat(scale)),
                .backgroundDecode,
                .retryStrategy(DelayRetryStrategy(maxRetryCount: 1, retryInterval: .seconds(0.5))),
                .requestModifier(AnyModifier { request in
                    var req = request
                    req.timeoutInterval = 30
if let host = req.url?.host?.lowercased() {
                            if host.contains("steam") || host.contains("akamaihd") {
                                req.setValue("https://steamcommunity.com/", forHTTPHeaderField: "Referer")
                            } else if host.contains("pximg.net") {
                                req.setValue("https://www.pixiv.net/", forHTTPHeaderField: "Referer")
                            } else if host.contains("wallsflow.com") {
                                req.setValue(WallsflowService.siteOrigin, forHTTPHeaderField: "Referer")
                            } else if host.contains("konachan.net") || host.contains("konachan.com") {
                                req.setValue(KonachanRequestConfiguration.browserUserAgent, forHTTPHeaderField: "User-Agent")
                                req.setValue(
                                    KonachanRequestConfiguration.referer(for: req.url),
                                    forHTTPHeaderField: "Referer"
                                )
                            }
                        }
                    return req
                })
            ]

            // 选最清晰的一档：达到 goodEnough 立即停；否则保留边缘最大的结果。
            // image.size 在 macOS 上多为点，乘 scale 估像素边。
            // preferredAspectRatio 提供时按「比例匹配 > 像素边」两级评分：
            // 比例不匹配的候选（如竖卡上的 16:9 横裁 lg）再大也不选，
            // 否则 fill 会把它裁成中间一条；比例接近的允许 fill 微裁换更高清晰度。
            var bestImage: NSImage?
            var bestEdge: CGFloat = 0
            var bestAspectMatched = preferredAspectRatio == nil
            for url in urls {
                guard !Task.isCancelled else { return }
                guard let image = await self.retrieveImageCancellable(url: url, options: options) else {
                    continue
                }
                let pixelWidth = image.size.width * scale
                let pixelHeight = image.size.height * scale
                let imageEdge = max(pixelWidth, pixelHeight)

                var aspectMatched = true
                if let preferredAspectRatio, pixelHeight > 0 {
                    let imageAspect = pixelWidth / pixelHeight
                    // 对称 20% 容差：接近就当作匹配（fill 微裁可接受）；
                    // 横裁档与竖卡比例差远超 20%，会被稳定排除。
                    let aspectDiff = abs(imageAspect - preferredAspectRatio)
                    aspectMatched = aspectDiff <= max(preferredAspectRatio, imageAspect) * 0.2
                }

                let better: Bool
                if bestImage == nil {
                    better = true
                } else if aspectMatched != bestAspectMatched {
                    better = aspectMatched
                } else {
                    better = imageEdge > bestEdge
                }
                if better {
                    bestImage = image
                    bestEdge = imageEdge
                    bestAspectMatched = aspectMatched
                    // 渐进上屏（仅比例优先模式，即壁纸网格）：低清保底候选一到就先显示，
                    // 高清 full 原图下载完成后由后续迭代原地升级，避免竖卡长时间停在骨架。
                    // Media/Anime 未传 preferredAspectRatio，保持旧的「循环结束统一上屏」行为。
                    if preferredAspectRatio != nil, aspectMatched, !Task.isCancelled {
                        let candidate = image
                        _ = await MainActor.run { [weak self] in
                            guard let self, !Task.isCancelled else { return }
                            self.coverImageView.image = candidate
                        }
                    }
                }
                if aspectMatched, imageEdge >= goodEnoughPixelEdge {
                    break
                }
            }

            // 注意：不在这里 kfDownloadTask = nil。
            // 原因：reconfigureVisibleItems 路径不会调 prepareForReuse，连续 configure
            // 同一 cell 时可能在 Task1 走完 for-loop 之后、它的 MainActor.run 落地之前，
            // Task2 已经把 kfDownloadTask 设为新的 task2A。Task1 此时再清 nil 会把
            // Task2 活动的句柄抹掉，导致后续 prepareForReuse 取消时找不到目标 →
            // 退化回老问题（下载完成才丢弃，浪费内存与流量）。
            // Kingfisher 完成的句柄本身是死的，cancel 是 no-op；留着无害，
            // 由下次 loadImage / prepareForReuse / deinit 自然覆盖即可。

            guard let finalImage = bestImage, !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                self.coverImageView.image = finalImage
            }
            // 列表默认只显示静态封面，不再自动探测/解码 GIF。
            // 历史路径会在每张图加载后 Range 探测 + gifRepresentation + 最多 20 帧解码，
            // 快速滚动时瞬时峰值可到数 GB；hover 时再按需启动动画即可。
            guard !Task.isCancelled, shouldAutoAnimateGIFOnLoad, let probeURL = urls.first else { return }
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            let isGIF = await AnimatedImageProbeCache.shared.isAnimatedGIF(
                probeURL,
                maxByteCount: 18 * 1024 * 1024
            )
            guard !Task.isCancelled, isGIF, let image = bestImage else { return }
            if let gifData = image.kf.gifRepresentation() {
                await MainActor.run { [weak self] in
                    self?.startAnimatingIfAnimated(data: gifData)
                }
            }
        }
    }

    /// 子类可覆写：列表默认 false，避免滚动时批量解码动图。
    var shouldAutoAnimateGIFOnLoad: Bool { false }

    /// 用 Kingfisher 的 callback 版 retrieveImage 包装成 async，并把同步返回的
    /// `DownloadTask` 句柄写到 `kfDownloadTask`，以便外层 cancel 真正中断网络下载。
    /// 注意：`@MainActor` 是为了让 `kfDownloadTask` 写入与外层 cancel 在同一隔离域。
    @MainActor
    private func retrieveImageCancellable(
        url: URL,
        options: KingfisherOptionsInfo
    ) async -> NSImage? {
        await withCheckedContinuation { (continuation: CheckedContinuation<NSImage?, Never>) in
            let task: Kingfisher.DownloadTask? = KingfisherManager.shared.retrieveImage(
                with: .network(url),
                options: options,
                progressBlock: nil,
                downloadTaskUpdated: nil
            ) { result in
                switch result {
                case .success(let value):
                    continuation.resume(returning: value.image)
                case .failure:
                    continuation.resume(returning: nil)
                }
            }
            // task 是同步返回值；缓存命中时 task 为 nil（已经 resume）。
            self.kfDownloadTask = task
        }
    }

    // MARK: - 动画 GIF

    /// 从已下载的图片数据检测并启动动画。data 是 Kingfisher 下载的原始数据。
    /// 内存保护：最多解码 50 帧，每帧用 ImageIO 缩略图接口下采样到封面视图尺寸，
    /// 避免大 GIF（如 4K 分辨率的 Steam 封面动图）单帧解码即可达 8MB，累积数十帧后撑爆内存。
    /// - Parameter startingAtMiddleFrame: true 时从中间帧起播并先显示中间帧。
    ///   大量动图前几帧是黑色淡入；从中间帧开始可避免 hover 起始闪黑，
    ///   且无需对每帧做「是否黑帧」的额外检测。
    /// - Returns: 是否成功启动动画（数据非多帧 GIF / 解码失败时返回 false）。
    @discardableResult
    func startAnimatingIfAnimated(data: Data, startingAtMiddleFrame: Bool = false) -> Bool {
        stopAnimating()
        guard let cgSource = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        let count = CGImageSourceGetCount(cgSource)
        guard count > 1 else { return false }

        // 限制最大帧数并计算采样步长（列表中 20 帧足够流畅，减少内存和解码压力）
        let maxFrames = 20
        let frameStep = max(1, count / maxFrames)
        let maxPixel = gifFrameMaxPixelSize
        let targetImageView = usesGIFOverlay ? gifOverlayImageView : coverImageView

        var frames: [(image: NSImage, duration: TimeInterval)] = []
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        var i = 0
        while i < count, frames.count < maxFrames {
            let dur = Self.frameDuration(at: i, source: cgSource)
            if let thumb = CGImageSourceCreateThumbnailAtIndex(cgSource, i, options as CFDictionary) {
                frames.append((image: NSImage(cgImage: thumb, size: .zero), duration: dur))
            }
            i += frameStep
        }
        guard !frames.isEmpty else { return false }

        animatedFrames = frames
        currentFrameIndex = startingAtMiddleFrame ? frames.count / 2 : 0
        targetImageView.image = frames[currentFrameIndex].image
        advanceFrameRepeating()
        return true
    }

    /// 在后台准备 GIF 帧。hover 时不能在主线程一次性解码整组 GIF，
    /// 否则卡片已经放大了，但首个动画帧还要等主线程解码完成。
    @MainActor
    func playGIFOverlayAsync(data: Data) async -> Bool {
        guard isHoverInteractionEnabled, isHovered, !Task.isCancelled else {
            return false
        }
        let maxPixel = gifFrameMaxPixelSize
        let preparedFrames = await Self.prepareGIFFrames(
            data: data,
            maxPixelSize: maxPixel
        )
        guard isHoverInteractionEnabled, isHovered, !Task.isCancelled else {
            return false
        }
        guard installPreparedGIFFrames(preparedFrames, startingAtMiddleFrame: true) else {
            stopGIFOverlayPlayback()
            return false
        }
        if usesGIFOverlay {
            gifOverlayImageView.isHidden = false
            isPlayingGIFOverlay = true
        }
        return true
    }

    private func installPreparedGIFFrames(
        _ preparedFrames: [PreparedGIFFrame],
        startingAtMiddleFrame: Bool
    ) -> Bool {
        stopAnimating()
        guard !preparedFrames.isEmpty else { return false }

        animatedFrames = preparedFrames.map {
            (image: NSImage(cgImage: $0.image, size: .zero), duration: $0.duration)
        }
        currentFrameIndex = startingAtMiddleFrame ? animatedFrames.count / 2 : 0
        let targetImageView = usesGIFOverlay ? gifOverlayImageView : coverImageView
        targetImageView.image = animatedFrames[currentFrameIndex].image
        advanceFrameRepeating()
        return true
    }

    private static func prepareGIFFrames(
        data: Data,
        maxPixelSize: Int
    ) async -> [PreparedGIFFrame] {
        let decodeTask: Task<[PreparedGIFFrame], Never> = Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled,
                  let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                return []
            }

            let count = CGImageSourceGetCount(source)
            guard count > 1 else { return [] }

            let maxFrames = 20
            let frameStep = max(1, (count + maxFrames - 1) / maxFrames)
            let options: [CFString: Any] = [
                kCGImageSourceShouldCache: false,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: max(64, maxPixelSize),
                kCGImageSourceCreateThumbnailWithTransform: true
            ]

            var frames: [PreparedGIFFrame] = []
            frames.reserveCapacity(min(count, maxFrames))
            var index = 0
            while index < count, frames.count < maxFrames {
                guard !Task.isCancelled else { return [] }

                let endIndex = min(count, index + frameStep)
                let duration = (index..<endIndex)
                    .reduce(0) { $0 + frameDuration(at: $1, source: source) }

                if let image = CGImageSourceCreateThumbnailAtIndex(
                    source,
                    index,
                    options as CFDictionary
                ) {
                    frames.append(
                        PreparedGIFFrame(
                            image: image,
                            duration: max(duration, 0.05)
                        )
                    )
                }
                index = endIndex
            }
            return frames
        }
        return await withTaskCancellationHandler(operation: {
            await decodeTask.value
        }, onCancel: {
            decodeTask.cancel()
        })
    }

    private nonisolated static func validateAnimatedGIFData(
        _ data: Data,
        maxByteCount: Int
    ) async -> Data? {
        let validationTask: Task<Data?, Never> = Task.detached(priority: .utility) {
            guard !Task.isCancelled,
                  data.count <= maxByteCount,
                  data.starts(with: Data("GIF".utf8)),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetCount(source) > 1 else {
                return nil
            }
            return data
        }
        return await withTaskCancellationHandler(operation: {
            await validationTask.value
        }, onCancel: {
            validationTask.cancel()
        })
    }

    func stopAnimating() {
        animationTimer?.invalidate()
        animationTimer = nil
        animatedFrames = []
        currentFrameIndex = 0
    }

    // MARK: - Hover GIF 覆盖播放
    //
    // 与 Kingfisher AnimatedImageView 叠层的旧方案相比：
    // 1. 逐帧直接画进 ExploreGridCoverImageView（contentsGravity = .resizeAspectFill），
    //    动画画面与静态封面**同比例铺满**卡片；AnimatedImageView.updateLayer 会按
    //    imageScaling 强制 .resizeAspect（letterbox），NSImageScaling 无任何值能映射到
    //    aspectFill —— 这就是旧方案 GIF 显示成“固定方块”的根因。
    // 2. 从中间帧起播，避开黑色开场帧。
    // 3. 动画帧最多 20 帧且按封面尺寸下采样（见 startAnimatingIfAnimated），内存有界。

    /// 是否正在覆盖播放 hover GIF。
    private(set) var isPlayingGIFOverlay = false

    /// 在封面视图上播放 GIF（中间帧起播）。
    /// 启用覆盖层的 cell 不会替换静态封面，停止时只隐藏动画层。
    @discardableResult
    func playGIFOverlay(data: Data) -> Bool {
        guard isHoverInteractionEnabled, isHovered else {
            return false
        }
        guard usesGIFOverlay else {
            return startAnimatingIfAnimated(data: data, startingAtMiddleFrame: true)
        }
        guard startAnimatingIfAnimated(data: data, startingAtMiddleFrame: true) else {
            stopGIFOverlayPlayback()
            return false
        }
        gifOverlayImageView.isHidden = false
        isPlayingGIFOverlay = true
        return true
    }

    /// 停止覆盖播放并隐藏动画层。
    func stopGIFOverlayPlayback() {
        isPlayingGIFOverlay = false
        stopAnimating()
        gifOverlayImageView.image = nil
        gifOverlayImageView.isHidden = true
    }

    /// 拉取 URL 的原始动画数据，不经过 Kingfisher 的静态处理器。
    /// 处理器会把 GIF 压成单帧 NSImage，之后再调用 gifRepresentation 已无法保证
    /// 仍保留全部帧；直接取原始字节才能与旧 KFAnimatedImage 的播放语义一致。
    func retrieveAnimatedGIFData(from url: URL) async -> Data? {
        let cacheKey = url.absoluteString as NSString
        if let cached = Self.animatedGIFDataCache.object(forKey: cacheKey) {
            return cached as Data
        }

        if url.isFileURL {
            let readTask: Task<Data?, Never> = Task.detached(priority: .utility) {
                guard !Task.isCancelled else { return nil }
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                      let fileSize = attributes[.size] as? NSNumber,
                      fileSize.intValue <= Self.maxAnimatedGIFDataBytes else {
                    return nil
                }
                guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
                      let source = CGImageSourceCreateWithData(data as CFData, nil),
                      CGImageSourceGetCount(source) > 1 else {
                    return nil
                }
                return data
            }
            let data: Data? = await withTaskCancellationHandler(operation: {
                await readTask.value
            }, onCancel: {
                readTask.cancel()
            })
            if let data {
                Self.animatedGIFDataCache.setObject(
                    data as NSData,
                    forKey: cacheKey,
                    cost: data.count
                )
            }
            return data
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.cachePolicy = .returnCacheDataElseLoad
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        if let host = url.host?.lowercased() {
            if host.contains("steam") || host.contains("akamaihd") {
                request.setValue("https://steamcommunity.com/", forHTTPHeaderField: "Referer")
            } else if host.contains("pximg.net") {
                request.setValue("https://www.pixiv.net/", forHTTPHeaderField: "Referer")
            } else if host.contains("wallsflow.com") {
                request.setValue(WallsflowService.siteOrigin, forHTTPHeaderField: "Referer")
            } else if host.contains("konachan.net") || host.contains("konachan.com") {
                request.setValue(KonachanRequestConfiguration.browserUserAgent, forHTTPHeaderField: "User-Agent")
                request.setValue(
                    KonachanRequestConfiguration.referer(for: url),
                    forHTTPHeaderField: "Referer"
                )
            }
        }
        request.setValue("image/gif,image/*;q=0.8,*/*;q=0.5", forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              !Task.isCancelled,
              (response as? HTTPURLResponse).map({ 200..<300 ~= $0.statusCode }) ?? true,
              let validatedData = await Self.validateAnimatedGIFData(
                  data,
                  maxByteCount: Self.maxAnimatedGIFDataBytes
              ),
              !Task.isCancelled else {
            return nil
        }
        Self.animatedGIFDataCache.setObject(
            validatedData as NSData,
            forKey: cacheKey,
            cost: validatedData.count
        )
        return validatedData
    }

    private func advanceFrameRepeating() {
        guard !animatedFrames.isEmpty else {
            animationTimer?.invalidate()
            animationTimer = nil
            return
        }
        guard currentFrameIndex < animatedFrames.count else {
            currentFrameIndex = 0
            advanceFrameRepeating()
            return
        }
        let dur = max(animatedFrames[currentFrameIndex].duration, 0.05)
        animationTimer = Timer.scheduledTimer(withTimeInterval: dur, repeats: false) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                guard !self.animatedFrames.isEmpty else { return }
                self.currentFrameIndex = (self.currentFrameIndex + 1) % self.animatedFrames.count
                let targetImageView = self.usesGIFOverlay
                    ? self.gifOverlayImageView
                    : self.coverImageView
                targetImageView.image = self.animatedFrames[self.currentFrameIndex].image
                self.advanceFrameRepeating()
            }
        }
    }

    /// GIF 帧只需要覆盖当前卡片的实际像素密度。
    /// 3 倍卡片边长会在 Retina 屏上额外放大解码内存，却不会改善最终显示。
    private var gifFrameMaxPixelSize: Int {
        let scale = min(
            max(
                view.window?.backingScaleFactor
                    ?? NSScreen.main?.backingScaleFactor
                    ?? 2,
                1
            ),
            2
        )
        return max(
            64,
            Int(max(coverImageView.bounds.width, coverImageView.bounds.height) * scale)
        )
    }

    private nonisolated static func frameDuration(at index: Int, source: CGImageSource) -> TimeInterval {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let gifProps = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] else { return 0.1 }
        if let dur = gifProps[kCGImagePropertyGIFDelayTime] as? NSNumber, dur.doubleValue > 0 { return dur.doubleValue }
        if let dur = gifProps[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber, dur.doubleValue > 0 { return dur.doubleValue }
        return 0.1
    }

    // MARK: - Hover

    private func installHoverTrackingAreaIfNeeded() {
        guard trackingArea == nil else { return }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        self.trackingArea = trackingArea
        view.addTrackingArea(trackingArea)
    }

    override func mouseEntered(with event: NSEvent) {
        guard isHoverInteractionEnabled else { return }
        _ = updateHoverStateFromCurrentMouseLocation(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        guard isHoverInteractionEnabled else { return }
        setHovered(false, animated: true)
    }

    override func mouseMoved(with event: NSEvent) {
        guard isHoverInteractionEnabled else { return }
        _ = updateHoverStateFromCurrentMouseLocation(animated: true)
    }

    func setHoverInteractionEnabled(_ enabled: Bool) {
        isHoverInteractionEnabled = enabled

        if !enabled {
            // 即使开关本身已经是 false，也要清理复用或异步回调留下的状态。
            setHovered(false, animated: false)
        }
    }

    func clearHover(animated: Bool = false) {
        setHovered(false, animated: animated)
    }

    @discardableResult
    func updateHoverStateFromCurrentMouseLocation(animated: Bool = true) -> Bool {
        guard isHoverInteractionEnabled,
              let window = view.window else { return false }

        let locationInWindow = window.mouseLocationOutsideOfEventStream
        let locationInRoot = view.convert(locationInWindow, from: nil)
        let cardFrame = cardSurfaceView.frame
        guard cardFrame.width > 0, cardFrame.height > 0 else {
            setHovered(false, animated: animated)
            return false
        }

        let visualExpansion = isHovered ? max(1, hoverExpansionAllowance) : 0
        let stableHitFrame = cardFrame.insetBy(dx: -visualExpansion, dy: -visualExpansion)
        guard stableHitFrame.contains(locationInRoot) else {
            setHovered(false, animated: animated)
            return false
        }

        let locationInCard = cardSurfaceView.convert(locationInRoot, from: view)
        let hitPath = NSBezierPath(
            roundedRect: cardSurfaceView.bounds.insetBy(dx: -visualExpansion, dy: -visualExpansion),
            xRadius: cardCornerRadius,
            yRadius: cardCornerRadius
        )
        let containsMouse = hitPath.contains(locationInCard)
        setHovered(containsMouse, animated: animated)
        return containsMouse
    }

    private func setHovered(_ hovering: Bool, animated: Bool) {
        guard isHovered != hovering else { return }
        guard !hovering || allowsHoverInteraction else { return }

        if hovering {
            clearSiblingHoverStates()
        }

        isHovered = hovering
        hoverStateDidChange(hovering)

        if animated {
            animateHover(hovering)
        } else {
            removeHoverAnimations()
            view.layer?.zPosition = hovering ? 100 : 0
            layoutCardFrame()
            applyCardTransform(hovering: hovering)
            if shouldAnimateBorderOnHover {
                borderLayer.borderWidth = effectiveHoverBorderWidth(for: hovering)
                borderLayer.borderColor = effectiveHoverBorderColor(for: hovering).cgColor
            } else {
                borderLayer.borderWidth = effectiveHoverBorderWidth(for: false)
                borderLayer.borderColor = effectiveHoverBorderColor(for: false).cgColor
            }
            applyHoverShadow(hovering)
        }
    }

    private func animateHover(_ hovering: Bool) {
        view.layer?.zPosition = hovering ? 100 : 0
        if shouldAnimateScaleOnHover {
            animateCardTransform(hovering: hovering)
        } else {
            layoutCardFrame()
            applyCardTransform(hovering: false)
        }
        if shouldAnimateBorderOnHover {
            animateBorderHover(hovering)
        } else {
            borderLayer.borderWidth = effectiveHoverBorderWidth(for: false)
            borderLayer.borderColor = effectiveHoverBorderColor(for: false).cgColor
        }
        applyHoverShadow(hovering)
    }

    /// hover 投影（子类按需开启）。offset 高度为负：非翻转视图里 y 向上为正，
    /// 负值才把影子投向"视觉下方"，与 SwiftUI 卡片 shadow(x:0, y:6) 对齐。
    /// shadowPath 用圆角矩形，避免离屏按 alpha 求影子轮廓。
    private func applyHoverShadow(_ hovering: Bool) {
        guard shouldShowShadowOnHover, let layer = cardSurfaceView.layer else { return }
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = hovering ? 0.20 : 0
        layer.shadowRadius = 10
        layer.shadowOffset = CGSize(width: 0, height: -6)
        refreshHoverShadowPath()
    }

    private func refreshHoverShadowPath() {
        guard shouldShowShadowOnHover, let layer = cardSurfaceView.layer else { return }
        let radius = min(cardCornerRadius, min(layer.bounds.width, layer.bounds.height) / 2)
        layer.shadowPath = CGPath(
            roundedRect: layer.bounds,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )
    }

    private func animateBorderHover(_ hovering: Bool) {
        let targetWidth = effectiveHoverBorderWidth(for: hovering)
        let targetColor = effectiveHoverBorderColor(for: hovering)

        let oldWidth = borderLayer.presentation()?.borderWidth ?? borderLayer.borderWidth
        let oldColor = borderLayer.presentation()?.borderColor ?? borderLayer.borderColor

        borderLayer.borderWidth = targetWidth
        borderLayer.borderColor = targetColor.cgColor

        let widthAnim = CABasicAnimation(keyPath: "borderWidth")
        widthAnim.fromValue = oldWidth
        widthAnim.toValue = targetWidth
        widthAnim.duration = 0.2
        widthAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        borderLayer.add(widthAnim, forKey: "wallpaper-card-hover-borderWidth")

        let colorAnim = CABasicAnimation(keyPath: "borderColor")
        colorAnim.fromValue = oldColor
        colorAnim.toValue = targetColor.cgColor
        colorAnim.duration = 0.2
        colorAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        borderLayer.add(colorAnim, forKey: "wallpaper-card-hover-borderColor")
    }

    private func layoutCardFrame() {
        let frame = cardFrame()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyCardFrame(frame)
        applyCardTransform(hovering: isHovered)
        CATransaction.commit()
    }

    private func cardFrame() -> CGRect {
        let inset = max(0, hoverExpansionAllowance)
        return view.bounds.insetBy(dx: inset, dy: inset)
    }

    private func applyCardFrame(_ frame: CGRect) {
        cardSurfaceView.frame = frame
        if let layer = cardSurfaceView.layer {
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer.position = CGPoint(x: frame.midX, y: frame.midY)
            layer.bounds = CGRect(origin: .zero, size: frame.size)
        }
        containerView.frame = cardSurfaceView.bounds
        layoutContentFrames()
        syncGIFOverlayFrame()
        borderLayer.frame = cardSurfaceView.bounds
        refreshHoverShadowPath()
    }

    private func cardTransform(hovering: Bool) -> CATransform3D {
        guard hovering, shouldAnimateScaleOnHover, hoverScaleFactor > 1 else {
            return CATransform3DIdentity
        }
        return CATransform3DMakeScale(hoverScaleFactor, hoverScaleFactor, 1)
    }

    private func applyCardTransform(hovering: Bool) {
        cardSurfaceView.layer?.transform = cardTransform(hovering: hovering)
    }

    private func animateCardTransform(hovering: Bool) {
        guard let layer = cardSurfaceView.layer else {
            applyCardTransform(hovering: hovering)
            return
        }

        let targetTransform = cardTransform(hovering: hovering)
        let currentTransform = layer.presentation()?.transform ?? layer.transform

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = targetTransform
        CATransaction.commit()

        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = currentTransform
        animation.toValue = targetTransform
        animation.duration = 0.16
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(animation, forKey: "wallpaper-card-hover-transform")
    }

    private func removeHoverAnimations() {
        cardSurfaceView.layer?.removeAnimation(forKey: "wallpaper-card-hover-transform")
        borderLayer.removeAnimation(forKey: "wallpaper-card-hover-borderWidth")
        borderLayer.removeAnimation(forKey: "wallpaper-card-hover-borderColor")
    }

    private func hoverBorderWidth() -> CGFloat {
        normalBorderWidth + 0.5
    }

    /// 子类可覆盖，例如文件夹拖放目标需要压过普通 hover 边框。
    func effectiveHoverBorderWidth(for hovering: Bool) -> CGFloat {
        hovering ? hoverBorderWidth() : normalBorderWidth
    }

    /// 子类可覆盖，例如文件夹拖放目标需要保持强调色。
    func effectiveHoverBorderColor(for hovering: Bool) -> NSColor {
        if hovering {
            return normalBorderColor.withAlphaComponent(hoverBorderAlpha(for: normalBorderColor))
        }
        return normalBorderColor
    }

    func hoverBorderAlpha(for color: NSColor) -> CGFloat {
        let alpha = color.alphaComponent
        return alpha < 0.5 ? 0.18 : alpha
    }

    private func clearSiblingHoverStates() {
        guard let collectionView = enclosingCollectionView() else { return }

        for item in collectionView.visibleItems() {
            guard let sibling = item as? ExploreGridItem, sibling !== self else { continue }
            sibling.clearHover(animated: false)
        }
    }

    private func enclosingCollectionView() -> NSCollectionView? {
        var ancestor = view.superview
        while let current = ancestor {
            if let collectionView = current as? NSCollectionView {
                return collectionView
            }
            ancestor = current.superview
        }
        return nil
    }
}

enum ExploreGridSkeletonStyle {
    case wallpaper
    case media
    case anime
}

final class ExploreGridSkeletonCell: ExploreGridItem {
    private enum Layout {
        static let outerCornerRadius: CGFloat = 16
        static let imageCornerRadius: CGFloat = 14
        static let bottomBarHeight: CGFloat = 44
        static let horizontalPadding: CGFloat = 14
        static let animeTitleY: CGFloat = 18
        static let animeEpisodeY: CGFloat = 8
        static let animeBadgeTop: CGFloat = 10
        static let animeBadgeTrailing: CGFloat = 8
    }

    private let imageSkeletonView: NSView = {
        let view = NSView()
        view.wantsLayer = true
        return view
    }()

    private let bottomBar: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.46).cgColor
        return view
    }()

    private let leadingSkeleton = CALayer()
    private let trailingSkeleton = CALayer()
    private let secondaryLeadingSkeleton = CALayer()
    private let secondaryDotSkeleton = CALayer()
    private let topTrailingBadgeSkeleton = CALayer()
    private var skeletonStyle: ExploreGridSkeletonStyle = .media

    override var hoverScaleFactor: CGFloat { 1.0 }
    override var shouldAnimateScaleOnHover: Bool { false }
    override var shouldAnimateBorderOnHover: Bool { false }

    override func setupContentLayout() {
        setCardCornerRadius(Layout.outerCornerRadius)
        setNormalBorder(width: 1, color: NSColor.white.withAlphaComponent(0.06))

        contentView.translatesAutoresizingMaskIntoConstraints = true
        imageSkeletonView.translatesAutoresizingMaskIntoConstraints = true
        bottomBar.translatesAutoresizingMaskIntoConstraints = true

        contentView.addSubview(imageSkeletonView)
        contentView.addSubview(bottomBar)

        for layer in [leadingSkeleton, trailingSkeleton, secondaryLeadingSkeleton, secondaryDotSkeleton] {
            layer.cornerRadius = 4
            layer.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
            bottomBar.layer?.addSublayer(layer)
        }
        topTrailingBadgeSkeleton.cornerRadius = 11
        topTrailingBadgeSkeleton.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
        imageSkeletonView.layer?.addSublayer(topTrailingBadgeSkeleton)

        imageSkeletonView.layer?.cornerRadius = Layout.imageCornerRadius
        imageSkeletonView.layer?.masksToBounds = true
        imageSkeletonView.layer?.backgroundColor = NSColor(calibratedRed: 0.11, green: 0.14, blue: 0.19, alpha: 1).cgColor
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        skeletonStyle = .media
    }

    override func configure(with item: Any, isFavorite: Bool) {
        guard let style = item as? ExploreGridSkeletonStyle else { return }
        skeletonStyle = style
        switch style {
        case .wallpaper, .anime:
            imageSkeletonView.layer?.backgroundColor = NSColor(calibratedRed: 0.11, green: 0.14, blue: 0.19, alpha: 1).cgColor
            bottomBar.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.46).cgColor
        case .media:
            imageSkeletonView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
            bottomBar.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.32).cgColor
        }
        layoutContentFrames()
    }

    override func layoutContentFrames() {
        let bounds = containerView.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }

        contentView.frame = bounds
        let imageHeight = max(0, bounds.height - Layout.bottomBarHeight)
        imageSkeletonView.frame = CGRect(x: 0, y: Layout.bottomBarHeight, width: bounds.width, height: imageHeight)

        bottomBar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: Layout.bottomBarHeight)

        let leadingWidth: CGFloat
        let trailingWidth: CGFloat
        switch skeletonStyle {
        case .wallpaper:
            leadingWidth = min(max(90, bounds.width * 0.42), bounds.width - 120)
            trailingWidth = 60
        case .media:
            leadingWidth = min(max(72, bounds.width * 0.34), bounds.width - 100)
            trailingWidth = 50
        case .anime:
            leadingWidth = min(max(80, bounds.width * 0.48), bounds.width - 90)
            trailingWidth = 40
        }

        if skeletonStyle == .anime {
            leadingSkeleton.frame = CGRect(
                x: Layout.horizontalPadding,
                y: Layout.animeTitleY,
                width: max(56, min(bounds.width - Layout.horizontalPadding * 2, leadingWidth)),
                height: 12
            ).integral
            secondaryDotSkeleton.frame = CGRect(
                x: Layout.horizontalPadding,
                y: Layout.animeEpisodeY + 1,
                width: 10,
                height: 10
            ).integral
            secondaryDotSkeleton.cornerRadius = 5
            secondaryLeadingSkeleton.frame = CGRect(
                x: secondaryDotSkeleton.frame.maxX + 6,
                y: Layout.animeEpisodeY,
                width: max(44, min(bounds.width - Layout.horizontalPadding * 2 - 16, bounds.width * 0.34)),
                height: 10
            ).integral
            trailingSkeleton.frame = .zero
            topTrailingBadgeSkeleton.frame = CGRect(
                x: bounds.width - Layout.animeBadgeTrailing - trailingWidth,
                y: imageHeight - Layout.animeBadgeTop - 22,
                width: trailingWidth,
                height: 22
            ).integral
        } else {
            leadingSkeleton.frame = CGRect(
                x: Layout.horizontalPadding,
                y: floor((Layout.bottomBarHeight - 12) / 2),
                width: max(42, leadingWidth),
                height: 12
            ).integral
            trailingSkeleton.frame = CGRect(
                x: bounds.width - Layout.horizontalPadding - trailingWidth,
                y: floor((Layout.bottomBarHeight - 10) / 2),
                width: trailingWidth,
                height: 10
            ).integral
            secondaryLeadingSkeleton.frame = .zero
            secondaryDotSkeleton.frame = .zero
            topTrailingBadgeSkeleton.frame = .zero
            secondaryDotSkeleton.cornerRadius = 4
        }
    }
}
