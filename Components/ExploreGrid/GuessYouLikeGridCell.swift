import AppKit
import SwiftUI

/// 猜你喜欢网格 Cell（NSCollectionView 版，替换旧 LazyVGrid + GuessYouLikeCardView）
///
/// 原生部分（滚动性能关键路径）：
/// - 封面图：基类 Kingfisher 管线（降采样 + 下载取消 + 复用清理），首次上屏 0.2s 淡入
/// - 卡片底色 / 28pt 连续圆角 / 0.5pt 边框 / 常态投影
/// - hover 3D 倾斜（跟随光标 ±6°，带透视）+ 1.02 缩放（复用基类内层缩放动画）
/// - 顺序发牌弹簧动画（仅 dealt false→true 翻转时播放，之后静态零开销）
///
/// SwiftUI 部分：`GuessYouLikeCardOverlayContent` 经 NSHostingView 承载，
/// 字体 / 来源标签 / 玻璃按钮与旧卡片同一份代码，视觉 1:1。
///
/// 变换分层（互不干扰）：
/// - root view.layer：倾斜 + 发牌变换 + 投影（本类独占）
/// - cardSurfaceView.layer：hover 1.02 缩放（基类独占）
final class GuessYouLikeGridCell: ExploreGridItem {

    /// 旧 LazyVGrid 的固定卡片尺寸（GridItem(.fixed(260)) × 卡片高 360）
    static let cardSize = CGSize(width: 260, height: 360)

    private enum Layout {
        static let cornerRadius: CGFloat = 28
        /// 悬停最大倾斜角（度），对齐旧卡 maxTiltAngle
        static let maxTiltAngle: CGFloat = 6
        /// 近似 SwiftUI rotation3DEffect(perspective: 0.3) 的透视强度；
        /// ±6° 倾斜下与精确值的边缘缩放差异 <1%，视觉不可辨
        static let perspectiveDistance: CGFloat = 600
        static let hoverAnimationDuration: CFTimeInterval = 0.15
        static let imageFadeDuration: TimeInterval = 0.2
        /// SwiftUI spring(response: 0.5, dampingFraction: 0.7) 的等效 CASpringAnimation 参数
        static let dealSpringResponse: Double = 0.5
        static let dealSpringDampingFraction: Double = 0.7
        static let dealDelayPerIndex: Double = 0.08
        static let dealHiddenOffset: CGFloat = 320
        static let dealHiddenOffsetPerIndex: CGFloat = 8
    }

    private static let tiltAnimationKey = "gyl-card-tilt"
    private static let dealTransformAnimationKey = "gyl-card-deal-transform"
    private static let dealOpacityAnimationKey = "gyl-card-deal-opacity"

    // MARK: - 状态

    private var onDetail: ((GuessYouLikeItem) -> Void)?
    private var onDownload: ((GuessYouLikeItem) -> Void)?
    /// 上一次 configure 时的发牌状态：false→true 翻转才播放发牌动画；
    /// 复用后（nil）或静态 true 直接终态，对齐旧版 hasAnimated 行为——
    /// 滚动进场的卡片不再补播动画。
    private var lastDealt: Bool?
    private var imageFadeObservation: NSKeyValueObservation?

    // MARK: - 子视图

    private lazy var overlayHost: NSHostingView<GuessYouLikeCardOverlayContent> = {
        let host = NSHostingView(
            rootView: GuessYouLikeCardOverlayContent(
                item: GuessYouLikeItem.mockItems()[0],
                onDetail: { _ in },
                onDownload: { _ in }
            )
        )
        // 旧卡片运行在 .preferredColorScheme(.dark) 环境下；NSHostingView 不继承
        // 外层 SwiftUI 环境，需显式暗色外观保证材质/玻璃渲染一致。
        host.appearance = NSAppearance(named: .darkAqua)
        // 固定尺寸宿主：frame 由 layoutContentFrames 手动铺满卡片，不参与 Auto Layout
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = true
        return host
    }()

    // MARK: - Hover 行为定制

    /// 1.02 缩放交给基类内层动画（0.16s easeOut ≈ 旧卡 0.15s）；倾斜在本类 root layer 上
    override var hoverScaleFactor: CGFloat { 1.02 }
    /// 旧卡片 hover 不提亮边框
    override var shouldAnimateBorderOnHover: Bool { false }
    /// 投影常态常驻（非 hover 限定），由本类直接挂在 root layer 上
    override var shouldShowShadowOnHover: Bool { false }

    deinit {
        imageFadeObservation?.invalidate()
        imageFadeObservation = nil
    }

    // MARK: - 布局

    override func setupContentLayout() {
        setCardCornerRadius(Layout.cornerRadius)
        setNormalBorder(width: 0.5, color: NSColor.white.withAlphaComponent(0.12))
        // RoundedRectangle(style: .continuous)
        containerView.layer?.cornerCurve = .continuous
        borderLayer.cornerCurve = .continuous
        coverImageView.layer?.cornerCurve = .continuous
        coverImageView.layer?.cornerRadius = Layout.cornerRadius

        // 卡片底色：旧卡 RoundedRectangle fill black 0.6（图片加载前可见）
        containerView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        // KFImage placeholder { Color.black.opacity(0.3) }
        coverImageView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.3).cgColor

        // 常态投影：shadow(black 0.2, radius 6, y 3)。root layer 的 y 轴向上为正，
        // 视觉下方偏移取 -3；shadowPath 避免按 alpha 离屏求轮廓。
        if let layer = view.layer {
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = 0.2
            layer.shadowRadius = 6
            layer.shadowOffset = CGSize(width: 0, height: -3)
            // 倾斜时旋转边缘更平滑（SwiftUI 旋转渲染自带抗锯齿）
            layer.allowsEdgeAntialiasing = true
        }

        overlayHost.translatesAutoresizingMaskIntoConstraints = true
        contentView.addSubview(overlayHost)
    }

    override func layoutContentFrames() {
        super.layoutContentFrames()
        let bounds = containerView.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        overlayHost.frame = contentView.bounds

        let radius = min(Layout.cornerRadius, min(view.bounds.width, view.bounds.height) / 2)
        view.layer?.shadowPath = CGPath(
            roundedRect: view.bounds,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )
    }

    // MARK: - 复用

    override func prepareForReuse() {
        super.prepareForReuse()
        lastDealt = nil
        onDetail = nil
        onDownload = nil
        resetCardPose()
    }

    /// 清掉发牌 / 倾斜动画与变换，恢复静态终态
    private func resetCardPose() {
        guard let layer = view.layer else { return }
        layer.removeAnimation(forKey: Self.tiltAnimationKey)
        layer.removeAnimation(forKey: Self.dealTransformAnimationKey)
        layer.removeAnimation(forKey: Self.dealOpacityAnimationKey)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = CATransform3DIdentity
        layer.opacity = 1
        CATransaction.commit()
    }

    // MARK: - 配置

    func configure(
        item: GuessYouLikeItem,
        index: Int,
        dealt: Bool,
        onDetail: @escaping (GuessYouLikeItem) -> Void,
        onDownload: @escaping (GuessYouLikeItem) -> Void
    ) {
        self.onDetail = onDetail
        self.onDownload = onDownload

        overlayHost.rootView = GuessYouLikeCardOverlayContent(
            item: item,
            onDetail: { [weak self] current in self?.onDetail?(current) },
            onDownload: { [weak self] current in self?.onDownload?(current) }
        )

        if let url = URL(string: item.imageURL), !item.imageURL.isEmpty {
            loadImage(url: url, targetSize: Self.cardSize)
        }
        installImageFadeObservationIfNeeded()

        // 发牌：仅 dealt false→true 翻转时播放
        let previousDealt = lastDealt
        lastDealt = dealt
        if dealt {
            if previousDealt == false {
                runDealAnimation(index: index)
            } else {
                // 复用后 / 静态刷新：直接终态（滚动进场的卡片不补播动画）
                resetCardPose()
            }
        } else {
            // 数据就绪、等待发牌：先摆到隐藏起点
            applyHiddenDealPose(index: index)
        }
    }

    // MARK: - 首图淡入（对齐 KFImage.fade(duration: 0.2)）

    private func installImageFadeObservationIfNeeded() {
        guard imageFadeObservation == nil else { return }
        imageFadeObservation = coverImageView.observe(
            \.image,
            options: [.old, .new]
        ) { [weak self] imageView, change in
            guard let self else { return }
            MainActor.assumeIsolated {
                let newImage = change.newValue ?? nil
                let oldImage = change.oldValue ?? nil
                if let newImage, oldImage == nil {
                    // 占位 → 首图：淡入
                    imageView.alphaValue = 0
                    NSAnimationContext.runAnimationGroup({ context in
                        context.duration = Layout.imageFadeDuration
                        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                        imageView.animator().alphaValue = 1
                    })
                } else if newImage == nil {
                    // 复用清空：复位 alpha，下一张重新淡入
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    imageView.alphaValue = 1
                    CATransaction.commit()
                }
            }
        }
    }

    // MARK: - 发牌动画

    /// 隐藏起点姿态：上方 320+8·index、缩放 0.3、旋转 ±20°、透明
    private static func dealStartTransform(index: Int) -> CATransform3D {
        // SwiftUI rotationEffect(+) 视觉顺时针，CA z 轴正向为逆时针，取负
        let zDegrees: Double = index.isMultiple(of: 2) ? -20 : 20
        var t = CATransform3DMakeTranslation(0, Layout.dealHiddenOffset + CGFloat(index) * Layout.dealHiddenOffsetPerIndex, 0)
        t = CATransform3DRotate(t, zDegrees * .pi / 180, 0, 0, 1)
        t = CATransform3DScale(t, 0.3, 0.3, 1)
        return t
    }

    private func applyHiddenDealPose(index: Int) {
        guard let layer = view.layer else { return }
        layer.removeAnimation(forKey: Self.dealTransformAnimationKey)
        layer.removeAnimation(forKey: Self.dealOpacityAnimationKey)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = Self.dealStartTransform(index: index)
        layer.opacity = 0
        CATransaction.commit()
    }

    /// 顺序发牌：spring(response 0.5, damping 0.7) + 每卡 0.08s 延迟。
    /// 终态（identity + opacity 1）写为模型值，动画结束后零开销。
    private func runDealAnimation(index: Int) {
        guard let layer = view.layer else { return }
        layer.removeAnimation(forKey: Self.dealTransformAnimationKey)
        layer.removeAnimation(forKey: Self.dealOpacityAnimationKey)

        let startTransform = Self.dealStartTransform(index: index)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = CATransform3DIdentity
        layer.opacity = 1
        CATransaction.commit()

        // SwiftUI spring → CASpringAnimation 换算：
        // stiffness = (2π/response)²，damping = 4π·dampingFraction/response
        let response = Layout.dealSpringResponse
        let dampingFraction = Layout.dealSpringDampingFraction
        let stiffness = pow(2 * Double.pi / response, 2)
        let damping = 4 * Double.pi * dampingFraction / response
        let beginTime = CACurrentMediaTime() + Double(index) * Layout.dealDelayPerIndex

        let transformSpring = CASpringAnimation(keyPath: "transform")
        transformSpring.fromValue = NSValue(caTransform3D: startTransform)
        transformSpring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        transformSpring.mass = 1
        transformSpring.stiffness = stiffness
        transformSpring.damping = damping
        transformSpring.initialVelocity = 0
        transformSpring.duration = max(response, transformSpring.settlingDuration)
        transformSpring.beginTime = beginTime
        transformSpring.fillMode = .backwards
        layer.add(transformSpring, forKey: Self.dealTransformAnimationKey)

        let opacitySpring = CASpringAnimation(keyPath: "opacity")
        opacitySpring.fromValue = 0
        opacitySpring.toValue = 1
        opacitySpring.mass = 1
        opacitySpring.stiffness = stiffness
        opacitySpring.damping = damping
        opacitySpring.initialVelocity = 0
        opacitySpring.duration = max(response, opacitySpring.settlingDuration)
        opacitySpring.beginTime = beginTime
        opacitySpring.fillMode = .backwards
        layer.add(opacitySpring, forKey: Self.dealOpacityAnimationKey)
    }

    // MARK: - Hover 3D 倾斜

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        // 倾斜跟随光标实时更新（无动画，对齐旧卡行为）
        let local = containerView.convert(event.locationInWindow, from: nil)
        applyTiltTransform(tiltTransform(localPointInCard: local), animated: false)
    }

    override func hoverStateDidChange(_ hovering: Bool) {
        // 进入/离开（含滚动结束后的 hover 恢复）：0.15s easeOut 过渡。
        // 异步一拍，确保在基类 hover 缩放动画落地之后应用。
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshTiltFromMouseLocation(animated: true)
        }
    }

    private func refreshTiltFromMouseLocation(animated: Bool) {
        guard isHovered, let window = view.window else {
            applyTiltTransform(CATransform3DIdentity, animated: animated)
            return
        }
        let locationInWindow = window.mouseLocationOutsideOfEventStream
        let local = containerView.convert(locationInWindow, from: nil)
        applyTiltTransform(tiltTransform(localPointInCard: local), animated: animated)
    }

    /// 旧卡公式（SwiftUI，左上原点）：rotationY = nx·6°，rotationX = -(ny·6°)。
    /// 本视图非翻转（y 向上），换算后 X 角取 `-(y/h-0.5)·2·6`，Y 轴同号；
    /// CA 的 X 轴正向与 SwiftUI 相反，最终 X 取负号。
    private func tiltTransform(localPointInCard point: NSPoint) -> CATransform3D {
        var size = containerView.bounds.size
        if size.width <= 0 || size.height <= 0 { size = Self.cardSize }
        let nx = (point.x / size.width - 0.5) * 2
        let ny = (point.y / size.height - 0.5) * 2
        let angleY = Double(nx * Layout.maxTiltAngle) * .pi / 180
        let angleX = -Double(ny * Layout.maxTiltAngle) * .pi / 180

        var t = CATransform3DIdentity
        t.m34 = -1.0 / Layout.perspectiveDistance
        // 修饰符顺序 rotationY → rotationX，此处同序复合
        t = CATransform3DRotate(t, angleY, 0, 1, 0)
        t = CATransform3DRotate(t, angleX, 1, 0, 0)
        return t
    }

    private func applyTiltTransform(_ transform: CATransform3D, animated: Bool) {
        guard let layer = view.layer else { return }
        // 发牌动画进行中不让倾斜改写姿态（窗口开启瞬间光标恰在卡上）
        guard layer.animation(forKey: Self.dealTransformAnimationKey) == nil else { return }

        if animated {
            let from = layer.presentation()?.transform ?? layer.transform
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.transform = transform
            CATransaction.commit()

            let animation = CABasicAnimation(keyPath: "transform")
            animation.fromValue = NSValue(caTransform3D: from)
            animation.toValue = NSValue(caTransform3D: transform)
            animation.duration = Layout.hoverAnimationDuration
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(animation, forKey: Self.tiltAnimationKey)
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.transform = transform
            CATransaction.commit()
        }
    }
}
