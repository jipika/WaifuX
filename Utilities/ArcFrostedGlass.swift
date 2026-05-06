import SwiftUI
import AppKit

// MARK: - 环境值：Arc 浅色模式

private struct ArcIsLightModeKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    var arcIsLightMode: Bool {
        get { self[ArcIsLightModeKey.self] }
        set { self[ArcIsLightModeKey.self] = newValue }
    }
}

// MARK: - Arc 自适应文字颜色工具

struct ArcTextColors {
    let isLightMode: Bool
    var primary: Color { isLightMode ? Color(hex: "1A1A1A") : .white }
    var secondary: Color { isLightMode ? Color(hex: "666666") : Color.white.opacity(0.7) }
    var tertiary: Color { isLightMode ? Color(hex: "999999") : Color.white.opacity(0.5) }
    var quaternary: Color { isLightMode ? Color(hex: "BBBBBB") : Color.white.opacity(0.35) }
    var border: Color { isLightMode ? Color.black.opacity(0.08) : Color.white.opacity(0.12) }
}

// MARK: - 平铺图案 overlay（仅用于点阵等固定图案）

struct TiledPatternOverlay: NSViewRepresentable {
    let image: NSImage
    let opacity: Double

    func makeNSView(context: Context) -> NSView {
        TiledPatternView(image: image, opacity: opacity)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? TiledPatternView else { return }
        view.image = image
        view.opacity = opacity
        view.needsDisplay = true
    }
}

private final class TiledPatternView: NSView {
    var image: NSImage
    var opacity: Double

    init(image: NSImage, opacity: Double) {
        self.image = image
        self.opacity = opacity
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard opacity > 0.001 else { return }

        let imgSize = image.size
        let bounds = self.bounds
        let frac = CGFloat(opacity)

        var y: CGFloat = 0
        while y < bounds.maxY {
            var x: CGFloat = 0
            while x < bounds.maxX {
                image.draw(in: NSRect(x: x, y: y, width: imgSize.width, height: imgSize.height),
                           from: NSRect(origin: .zero, size: imgSize),
                           operation: .sourceOver,
                           fraction: frac)
                x += imgSize.width
            }
            y += imgSize.height
        }
    }
}

// MARK: - CIFilter 胶片颗粒蒙层（静态纹理，无动画）

/// 细腻噪点肌理：生成一次缓存复用，无抖动无闪烁
struct GrainOverlay: NSViewRepresentable {
    let opacity: Double

    func makeNSView(context: Context) -> NSView {
        let v = GrainOverlayNSView()
        v.opacity = opacity
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? GrainOverlayNSView else { return }
        view.opacity = opacity
    }
}

final class GrainOverlayNSView: NSView {
    var opacity: Double = 0.18 {
        didSet { layer?.opacity = Float(opacity) }
    }

    /// 缓存的颗粒纹理（全局共享，只生成一次）
    private static var cachedGrainImage: CGImage?
    private static let tilePointSize = CGSize(width: 2048, height: 2048)

    override var isOpaque: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        if window != nil {
            setupGrain()
        }
    }

    private func setupGrain() {
        guard let layer = self.layer else { return }

        if Self.cachedGrainImage == nil {
            Self.cachedGrainImage = Self.generateFineGrainTexture(size: Self.tilePointSize)
        }
        layer.contents = Self.cachedGrainImage
        layer.contentsGravity = .resizeAspectFill
        layer.opacity = Float(opacity)
    }

    override func resize(withOldSuperviewSize oldSize: NSSize) {
        super.resize(withOldSuperviewSize: oldSize)
        layer?.frame = bounds
    }

    /// 生成细腻灰度噪点纹理（以 0.5 为中心，用于 softLight 混合）
    ///
    /// softLight 混合：0.5 中性灰不偏移，>0.5 提亮，<0.5 压暗。
    /// 产生的明暗变化保留底层色调，不引入灰色。
    private static func generateFineGrainTexture(size: CGSize) -> CGImage? {
        guard size.width > 0, size.height > 0 else { return nil }

        let context = CIContext(options: [.workingColorSpace: NSNull()])

        // 1. 基础白噪声
        guard let noiseFilter = CIFilter(name: "CIRandomGenerator") else { return nil }
        let margin: CGFloat = 4
        let noiseSize = CGSize(width: size.width + margin * 2, height: size.height + margin * 2)
        let baseNoise = noiseFilter.outputImage?.cropped(to: CGRect(origin: .zero, size: noiseSize))
            ?? CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))

        // 2. 柔化：0.6px 让单像素噪点变成 2~3px 的有机颗粒簇
        guard let blurFilter = CIFilter(name: "CIGaussianBlur") else { return nil }
        blurFilter.setValue(baseNoise, forKey: kCIInputImageKey)
        blurFilter.setValue(0.6, forKey: kCIInputRadiusKey)
        let blurred = blurFilter.outputImage ?? baseNoise

        // 3. 温和对比：以 0.5 为中心
        guard let contrastFilter = CIFilter(name: "CIColorControls") else { return nil }
        contrastFilter.setValue(blurred, forKey: kCIInputImageKey)
        contrastFilter.setValue(1.3, forKey: kCIInputContrastKey)
        contrastFilter.setValue(0.0, forKey: kCIInputBrightnessKey)
        contrastFilter.setValue(0.0, forKey: kCIInputSaturationKey)
        let grain = contrastFilter.outputImage ?? blurred

        let final = grain.cropped(to: CGRect(origin: CGPoint(x: margin, y: margin), size: size))
        return context.createCGImage(final, from: final.extent)
    }
}

// MARK: - 点阵纹理平铺图（生成一次复用）

enum ArcDotGridTile {
    private static func makeDotGrid(color: NSColor) -> NSImage {
        let spacing: CGFloat = 14
        let dotSize: CGFloat = 1.2
        let size = NSSize(width: spacing, height: spacing)
        return NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setFillColor(color.cgColor)
            let dotRect = CGRect(
                x: (spacing - dotSize) / 2,
                y: (spacing - dotSize) / 2,
                width: dotSize,
                height: dotSize
            )
            ctx.fillEllipse(in: dotRect)
            return true
        }
    }
    
    static let whiteImage: NSImage = makeDotGrid(color: .white)
    static let blackImage: NSImage = makeDotGrid(color: .black)
}

// MARK: - Arc 风格毛玻璃修饰器

/// 高透光、浅色基调、带颗粒噪点的 Arc 风格磨砂玻璃
struct ArcFrostedModifier: ViewModifier {
    let cornerRadius: CGFloat
    let intensity: Double  // 0.0~1.0，控制磨砂浓度
    let isLightMode: Bool
    let accentColor: Color
    let useNoise: Bool

    func body(content: Content) -> some View {
        content
            .background(
                ArcFrostedBackground(
                    cornerRadius: cornerRadius,
                    intensity: intensity,
                    isLightMode: isLightMode,
                    accentColor: accentColor,
                    useNoise: useNoise
                )
            )
    }
}

/// Arc 风格磨砂背景层（可独立使用）
struct ArcFrostedBackground: View {
    let cornerRadius: CGFloat
    let intensity: Double
    let isLightMode: Bool
    let accentColor: Color
    let useNoise: Bool

    /// 材质透明度：Arc 风格高透光
    private var materialOpacity: Double {
        isLightMode
            ? 0.15 + intensity * 0.25   // 浅色: 0.15~0.40
            : 0.10 + intensity * 0.20   // 深色: 0.10~0.30
    }

    /// 色调层透明度
    private var tintOpacity: Double {
        intensity * 0.06
    }

    /// 高光强度
    private var highlightOpacity: Double {
        isLightMode ? intensity * 0.15 : intensity * 0.08
    }

    /// 边框透明度
    private var borderOpacity: Double {
        isLightMode ? 0.15 + intensity * 0.15 : 0.2 + intensity * 0.15
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        ZStack {
            // 1. 系统材质层（提供基础模糊）
            shape
                .fill(isLightMode ? .thinMaterial : .ultraThinMaterial)
                .opacity(materialOpacity)

            // 2. 色调层（微着色）
            shape
                .fill(accentColor.opacity(tintOpacity))

            // 3. 顶部高光（模拟玻璃反光）
            shape
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(highlightOpacity),
                            Color.white.opacity(highlightOpacity * 0.3),
                            Color.clear
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            // 4. 噪点纹理层（softLight 保留色调的明暗变化）
            if useNoise {
                GrainOverlay(opacity: isLightMode ? 0.12 : 0.18)
                .blendMode(.softLight)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(shape)
            }
        }
        .overlay(
            // 内边框：顶部亮、底部暗，模拟玻璃边缘
            shape
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(borderOpacity),
                            Color.white.opacity(borderOpacity * 0.3)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
        )
        .clipShape(shape)
    }
}

// MARK: - Arc 风格点阵背景

struct ArcDotGridBackground: View {
    let isLightMode: Bool
    let dotOpacity: Double

    var body: some View {
        TiledPatternOverlay(
            image: isLightMode ? ArcDotGridTile.blackImage : ArcDotGridTile.whiteImage,
            opacity: dotOpacity
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: - Arc 风格氛围背景（卡片图片 + 高透光磨砂质感）

struct ArcAtmosphereBackground: View {
    let tint: ExploreAtmosphereTint
    let referenceImage: NSImage?
    let isLightMode: Bool
    let dotGridOpacity: Double
    let useNoise: Bool
    /// 颗粒度强度（0.0~1.0），控制噪点纹理的可见度
    let grainIntensity: Double

    /// 使用传入的 tint 颜色（来自各页首张卡片采样），让每个探索页背景色独立
    private var primaryGlow: Color { tint.primary }
    private var secondaryGlow: Color { tint.secondary }
    private var tertiaryGlow: Color { tint.tertiary }

    var body: some View {
        ZStack {
            // 1. 底色
            ArcBackgroundSettings.shared.baseBackground
                .ignoresSafeArea()
                .allowsHitTesting(false)

            // 2. 图片散射光斑（大面积高斯模糊，营造高级光感）
            if let referenceImage {
                Image(nsImage: referenceImage)
                    .resizable()
                    .interpolation(.low)
                    .aspectRatio(contentMode: .fill)
                    .frame(minWidth: 160, minHeight: 160)
                    .blur(radius: 60)
                    .opacity(isLightMode ? 0.35 : 0.28)
                    .saturation(isLightMode ? 1.3 : 1.6)
                    .allowsHitTesting(false)
            }

            // 3. 多层散射光斑（非对称分布，模拟光的折射散射）
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                ZStack {
                    // 主光斑 — 偏左上方，大面积弥散
                    Ellipse()
                        .fill(
                            RadialGradient(
                                colors: [primaryGlow.opacity(isLightMode ? 0.45 : 0.55), primaryGlow.opacity(0)],
                                center: .center,
                                startRadius: 0,
                                endRadius: w * 0.5
                            )
                        )
                        .frame(width: w * 1.1, height: h * 0.9)
                        .blur(radius: 100)
                        .offset(x: -w * 0.2, y: -h * 0.15)

                    // 副光斑 — 偏右下
                    Ellipse()
                        .fill(
                            RadialGradient(
                                colors: [secondaryGlow.opacity(isLightMode ? 0.35 : 0.45), secondaryGlow.opacity(0)],
                                center: .center,
                                startRadius: 0,
                                endRadius: w * 0.4
                            )
                        )
                        .frame(width: w * 0.85, height: h * 0.75)
                        .blur(radius: 90)
                        .offset(x: w * 0.2, y: h * 0.2)

                    // 第三光斑 — 底部偏左
                    Ellipse()
                        .fill(
                            RadialGradient(
                                colors: [tertiaryGlow.opacity(isLightMode ? 0.25 : 0.35), tertiaryGlow.opacity(0)],
                                center: .center,
                                startRadius: 0,
                                endRadius: w * 0.35
                            )
                        )
                        .frame(width: w * 0.7, height: h * 0.6)
                        .blur(radius: 80)
                        .offset(x: -w * 0.1, y: h * 0.25)

                    // 小光斑 — 右上角点缀，增加层次
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [primaryGlow.opacity(isLightMode ? 0.15 : 0.22), Color.clear],
                                center: .center,
                                startRadius: 0,
                                endRadius: w * 0.15
                            )
                        )
                        .frame(width: w * 0.4, height: w * 0.4)
                        .blur(radius: 50)
                        .offset(x: w * 0.3, y: -h * 0.2)

                    // 中心柔光 — 柔和的整体提亮
                    Ellipse()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color.white.opacity(isLightMode ? 0.06 : 0.04),
                                    Color.clear
                                ],
                                center: .center,
                                startRadius: w * 0.1,
                                endRadius: w * 0.6
                            )
                        )
                        .frame(width: w, height: h)
                        .blur(radius: 60)
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            // 4. 暗模式：顶部微光 + 底部渐暗，增加深度
            if !isLightMode {
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.02),
                        Color.clear,
                        Color.black.opacity(0.20)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }

            // 5. 点阵纹理
            ArcDotGridBackground(
                isLightMode: isLightMode,
                dotOpacity: 0.02 + dotGridOpacity * 0.03
            )

            // 6. 噪点纹理
            if useNoise {
                GrainOverlay(opacity: grainIntensity * 0.20)
                .blendMode(.softLight)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - View 扩展

extension View {
    /// Arc 风格磨砂玻璃（高透光、浅色基调、带颗粒噪点）
    func arcFrostedGlass(
        cornerRadius: CGFloat = 20,
        intensity: Double = 0.55,
        isLightMode: Bool = false,
        accentColor: Color = Color(hex: "8B5CF6"),
        useNoise: Bool = true
    ) -> some View {
        modifier(ArcFrostedModifier(
            cornerRadius: cornerRadius,
            intensity: intensity,
            isLightMode: isLightMode,
            accentColor: accentColor,
            useNoise: useNoise
        ))
    }

    /// Arc 风格胶囊磨砂（默认无噪点，按钮/标签用）
    func arcFrostedCapsule(
        intensity: Double = 0.55,
        isLightMode: Bool = false,
        accentColor: Color = Color(hex: "8B5CF6"),
        useNoise: Bool = false
    ) -> some View {
        modifier(ArcFrostedCapsuleModifier(
            intensity: intensity,
            isLightMode: isLightMode,
            accentColor: accentColor,
            useNoise: useNoise
        ))
    }

    /// Arc 风格圆形按钮（默认无噪点）
    func arcFrostedCircle(
        intensity: Double = 0.55,
        isLightMode: Bool = false,
        accentColor: Color = Color(hex: "8B5CF6"),
        useNoise: Bool = false
    ) -> some View {
        modifier(ArcFrostedCircleModifier(
            intensity: intensity,
            isLightMode: isLightMode,
            accentColor: accentColor,
            useNoise: useNoise
        ))
    }
}

// MARK: - 形状专用修饰器

struct ArcFrostedCapsuleModifier: ViewModifier {
    let intensity: Double
    let isLightMode: Bool
    let accentColor: Color
    let useNoise: Bool

    func body(content: Content) -> some View {
        content
            .background(
                ArcFrostedBackground(
                    cornerRadius: 9999,
                    intensity: intensity,
                    isLightMode: isLightMode,
                    accentColor: accentColor,
                    useNoise: false // 按钮不显示颗粒效果
                )
            )
    }
}

struct ArcFrostedCircleModifier: ViewModifier {
    let intensity: Double
    let isLightMode: Bool
    let accentColor: Color
    let useNoise: Bool

    func body(content: Content) -> some View {
        content
            .background(
                ArcFrostedBackground(
                    cornerRadius: 9999,
                    intensity: intensity,
                    isLightMode: isLightMode,
                    accentColor: accentColor,
                    useNoise: false // 按钮不显示颗粒效果
                )
            )
    }
}
