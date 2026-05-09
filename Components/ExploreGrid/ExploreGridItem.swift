import AppKit

private final class ExploreGridAspectFillImageView: NSImageView {
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

        layer.contentsGravity = .resizeAspectFill
        layer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2

        guard let image, image.size.width > 0, image.size.height > 0 else {
            layer.contents = nil
            return
        }

        // 保留 NSImage 自身的多分辨率表示，避免提前压平成单张 CGImage 后丢掉 Retina 细节。
        layer.contents = image
    }
}

/// 通用网格 Cell 基类
/// 支持 Cell 复用（prepareForReuse）、图片加载/取消、hover 缩放效果
class ExploreGridItem: NSCollectionViewItem {

    static let reuseIdentifier = NSUserInterfaceItemIdentifier("ExploreGridItem")

    // MARK: - 子视图

    /// 封面图片视图（避免与 NSCollectionViewItem.imageView 冲突）
    let coverImageView: NSImageView = {
        let iv = ExploreGridAspectFillImageView()
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.wantsLayer = true
        iv.layerContentsRedrawPolicy = .never
        iv.layer?.cornerRadius = 14
        iv.layer?.masksToBounds = true
        iv.layer?.contentsGravity = .resizeAspectFill
        iv.layer?.minificationFilter = .linear
        iv.layer?.magnificationFilter = .linear
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
    private(set) var isHovered = false
    private var isHoverInteractionEnabled = true
    private var currentImageURL: URL?
    private var currentImageURLs: [URL] = []
    private var currentImageTargetSize: CGSize = .zero
    private var isCurrentImageRequestPending = false
    private var trackingArea: NSTrackingArea?
    var hoverExpansionAllowance: CGFloat = 0 {
        didSet {
            guard abs(hoverExpansionAllowance - oldValue) > 0.5 else { return }
            layoutCardFrame()
        }
    }
    private var cardCornerRadius: CGFloat = 16

    var shouldAnimateScaleOnHover: Bool { true }
    var shouldAnimateBorderOnHover: Bool { true }
    var hoverScaleFactor: CGFloat { 1.035 }
    var hoverOverlayMaxOpacity: Float { 0.02 }

    // MARK: - Border State

    private(set) var normalBorderWidth: CGFloat = 1
    private(set) var normalBorderColor: NSColor = NSColor.white.withAlphaComponent(0.06)

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
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

        let cancelledURL = currentImageURL
        let cancelledTargetSize = currentImageTargetSize
        loadTask?.cancel()
        loadTask = nil
        let cancelledURLs = currentImageURLs
        if (!cancelledURLs.isEmpty || cancelledURL != nil), cancelledTargetSize != .zero {
            Task {
                for url in cancelledURLs.isEmpty ? [cancelledURL].compactMap({ $0 }) : cancelledURLs {
                    await ExploreGridImageLoader.shared.cancel(
                        url: url,
                        targetSize: cancelledTargetSize
                    )
                }
            }
        }
        coverImageView.image = nil
        currentImageURL = nil
        currentImageURLs = []
        currentImageTargetSize = .zero
        isCurrentImageRequestPending = false

        isHovered = false
        removeHoverAnimations()
        view.layer?.zPosition = 0
        layoutCardFrame()

        normalBorderWidth = 1
        normalBorderColor = NSColor.white.withAlphaComponent(0.06)
        borderLayer.borderWidth = normalBorderWidth
        borderLayer.borderColor = normalBorderColor.cgColor
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

    // MARK: - 配置

    /// 子类重写此方法来配置 Cell 内容
    func configure(with item: Any, isFavorite: Bool) {
        // 子类实现
    }

    func hoverStateDidChange(_ hovering: Bool) {
        // 子类按需覆写
    }

    /// 加载图片
    func loadImage(url: URL?, targetSize: CGSize) {
        loadImage(urls: url.map { [$0] } ?? [], targetSize: targetSize)
    }

    /// 加载图片。传入多个候选 URL 时，前一个加载失败或分辨率不足会继续尝试后续候选。
    func loadImage(urls: [URL], targetSize: CGSize) {
        let roundedTargetSize = CGSize(width: ceil(targetSize.width), height: ceil(targetSize.height))
        let candidates = deduplicatedURLs(urls)
        let sameURL = candidates == currentImageURLs
        // 与按物理像素桶化的 decode 尺寸对齐，避免布局微抖反复排队解码
        let sizeChanged = abs(roundedTargetSize.width - currentImageTargetSize.width) > 24
            || abs(roundedTargetSize.height - currentImageTargetSize.height) > 24
        let hasDisplayedImage = coverImageView.image != nil
        if sameURL && !sizeChanged && (hasDisplayedImage || isCurrentImageRequestPending) {
            return
        }
        currentImageURL = candidates.first
        currentImageURLs = candidates
        currentImageTargetSize = roundedTargetSize

        loadTask?.cancel()
        if candidates.isEmpty {
            coverImageView.image = nil
            loadTask = nil
            isCurrentImageRequestPending = false
            return
        }

        isCurrentImageRequestPending = true
        loadTask = Task { [weak self] in
            guard let self else { return }

            var bestImage: NSImage?
            var bestURL: URL?
            var bestMaxEdge: CGFloat = 0

            for candidate in candidates {
                guard !Task.isCancelled else { return }
                if let image = await ExploreGridImageLoader.shared.load(url: candidate, targetSize: roundedTargetSize) {
                    let imagePixelSize = pixelSize(for: image)
                    let imageMaxEdge = max(imagePixelSize.width, imagePixelSize.height)

                    // 分辨率足够，直接使用
                    if isImageAcceptablySharp(image, pixelSize: imagePixelSize, for: roundedTargetSize) {
                        bestImage = image
                        bestURL = candidate
                        break
                    }

                    // 分辨率不够，记录当前最佳，继续尝试更高分辨率的候选
                    if imageMaxEdge > bestMaxEdge {
                        bestImage = image
                        bestURL = candidate
                        bestMaxEdge = imageMaxEdge
                    }
                }
            }

            guard !Task.isCancelled else { return }

            let requestedURLs = candidates
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.currentImageURLs == requestedURLs else { return }
                self.currentImageURL = bestURL
                self.coverImageView.image = bestImage
                self.isCurrentImageRequestPending = false
                self.loadTask = nil
            }
        }
    }

    /// 子类可按内容类型调整“这张图可以直接展示”的最低像素要求。
    /// 默认阈值偏保守，兼顾通用列表页的速度与容错。
    func minimumAcceptableImageEdge(for targetSize: CGSize) -> CGFloat {
        let targetMaxEdge = max(targetSize.width, targetSize.height)
        return max(targetMaxEdge * 0.55, 320)
    }

    /// 子类可按内容类型覆写清晰度判定。
    /// 默认只看最大边，兼顾现有媒体/动漫页的容错。
    func isImageAcceptablySharp(_ image: NSImage, pixelSize: CGSize, for targetSize: CGSize) -> Bool {
        let imageMaxEdge = max(pixelSize.width, pixelSize.height)
        return imageMaxEdge >= minimumAcceptableImageEdge(for: targetSize)
    }

    /// 获取图片物理像素的最大边（用于分辨率检查）
    /// 注意：不要把逻辑尺寸 * scale 作为优先依据，否则小缩略图会被误判成“已经够清晰”。
    /// 这里优先使用 CGImage / NSImageRep 的真实像素，只有完全拿不到时才退回估算值。
    func pixelSize(for image: NSImage) -> CGSize {
        if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return CGSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
        }

        let rep = image.representations.max {
            ($0.pixelsWide * $0.pixelsHigh) < ($1.pixelsWide * $1.pixelsHigh)
        }

        if let rep, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            return CGSize(width: CGFloat(rep.pixelsWide), height: CGFloat(rep.pixelsHigh))
        }

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let estimatedWidth = max(1, image.size.width * scale)
        let estimatedHeight = max(1, image.size.height * scale)
        return CGSize(width: estimatedWidth, height: estimatedHeight)
    }

    private func deduplicatedURLs(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        var result: [URL] = []

        for url in urls {
            let key = url.absoluteString
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(url)
        }

        return result
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
        guard isHoverInteractionEnabled != enabled else { return }
        isHoverInteractionEnabled = enabled

        if !enabled {
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
        guard isHovered != hovering || !animated else { return }

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
                borderLayer.borderWidth = hovering ? hoverBorderWidth() : normalBorderWidth
                let borderAlpha = hovering
                    ? hoverBorderAlpha(for: normalBorderColor)
                    : normalBorderColor.alphaComponent
                borderLayer.borderColor = normalBorderColor.withAlphaComponent(borderAlpha).cgColor
            } else {
                borderLayer.borderWidth = normalBorderWidth
                borderLayer.borderColor = normalBorderColor.cgColor
            }
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
            borderLayer.borderWidth = normalBorderWidth
            borderLayer.borderColor = normalBorderColor.cgColor
        }
    }

    private func animateBorderHover(_ hovering: Bool) {
        let targetWidth = hovering ? hoverBorderWidth() : normalBorderWidth
        let targetAlpha = hovering
            ? hoverBorderAlpha(for: normalBorderColor)
            : normalBorderColor.alphaComponent
        let targetColor = normalBorderColor.withAlphaComponent(targetAlpha)

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
        borderLayer.frame = cardSurfaceView.bounds
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

    private func hoverBorderAlpha(for color: NSColor) -> CGFloat {
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
