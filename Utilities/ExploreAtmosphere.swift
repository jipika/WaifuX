import SwiftUI
import AppKit

// MARK: - 探索页氛围色（背景光斑 + 液态玻璃主题色）

struct ExploreAtmosphereTint {
    var primary: Color
    var secondary: Color
    var tertiary: Color
    var baseTop: Color
    var baseBottom: Color

    static let wallpaperFallback = ExploreAtmosphereTint(
        primary: Color(hex: "5A7CFF"),
        secondary: Color(hex: "8A5CFF"),
        tertiary: Color(hex: "20C1FF"),
        baseTop: Color(hex: "1D2128"),
        baseBottom: Color(hex: "0E1116")
    )

    static let mediaFallback = ExploreAtmosphereTint(
        primary: Color(hex: "20C1FF"),
        secondary: Color(hex: "6D42FF"),
        tertiary: Color(hex: "2EE6A6"),
        baseTop: Color(hex: "1D2128"),
        baseBottom: Color(hex: "0E1116")
    )

    static func fromWallpaperMetadata(_ wallpaper: Wallpaper) -> ExploreAtmosphereTint {
        let palette = HeroDrivenPalette(wallpaper: wallpaper)
        return ExploreAtmosphereTint(
            primary: palette.primary,
            secondary: palette.secondary,
            tertiary: palette.tertiary,
            baseTop: Color(hex: "1D2128"),
            baseBottom: Color(hex: "0E1116")
        )
    }

    static func fromSampledTriplet(_ a: Color, _ b: Color, _ c: Color) -> ExploreAtmosphereTint {
        ExploreAtmosphereTint(
            primary: a,
            secondary: b,
            tertiary: c,
            baseTop: Color(hex: "1D2128"),
            baseBottom: Color(hex: "0E1116")
        )
    }
}

// MARK: - Environment（子视图同步主题色）

private struct ExplorePageAtmosphereTintKey: EnvironmentKey {
    static let defaultValue = ExploreAtmosphereTint.wallpaperFallback
}

extension EnvironmentValues {
    var explorePageAtmosphereTint: ExploreAtmosphereTint {
        get { self[ExplorePageAtmosphereTintKey.self] }
        set { self[ExplorePageAtmosphereTintKey.self] = newValue }
    }
}

// MARK: - 缩略图三色采样（左/中/右条带平均）

enum ExploreImageColorSampler {
    static func triplet(from image: NSImage) -> (Color, Color, Color)? {
        let pixelWidth = 48
        let pixelHeight = 48
        let size = NSSize(width: pixelWidth, height: pixelHeight)

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.clear.set()
        NSRect(origin: .zero, size: size).fill()
        image.draw(
            in: NSRect(origin: .zero, size: size),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.bitmapData else { return nil }
        let w = rep.pixelsWide
        let h = rep.pixelsHigh
        let bpp = max(rep.bitsPerPixel / 8, 4)

        func average(in rect: (x: Int, y: Int, width: Int, height: Int)) -> (Double, Double, Double) {
            var r: Double = 0
            var g: Double = 0
            var b: Double = 0
            var n: Double = 0
            let x1 = max(0, rect.x)
            let y1 = max(0, rect.y)
            let x2 = min(w, rect.x + rect.width)
            let y2 = min(h, rect.y + rect.height)
            for y in y1..<y2 {
                for x in x1..<x2 {
                    let o = (y * w + x) * bpp
                    guard o + 2 < rep.bytesPerRow * h else { continue }
                    r += Double(data[o])
                    g += Double(data[o &+ 1])
                    b += Double(data[o &+ 2])
                    n += 1
                }
            }
            guard n > 0 else { return (0.15, 0.15, 0.18) }
            return (r / n / 255, g / n / 255, b / n / 255)
        }

        let colW = max(1, w / 3)
        let a1 = boost(average(in: (0, 0, colW, h)))
        let a2 = boost(average(in: (colW, 0, colW, h)))
        let a3 = boost(average(in: (colW * 2, 0, w - colW * 2, h)))

        return (color(from: a1), color(from: a2), color(from: a3))
    }

    private static func boost(_ rgb: (Double, Double, Double)) -> (Double, Double, Double) {
        let mx = max(rgb.0, rgb.1, rgb.2)
        let mn = min(rgb.0, rgb.1, rgb.2)
        if mx - mn < 0.07 {
            return (
                min(1, rgb.0 * 0.55 + mx * 0.45),
                min(1, rgb.1 * 0.55 + mx * 0.45),
                min(1, rgb.2 * 0.55 + mx * 0.45)
            )
        }
        return (
            min(1, rgb.0 * 0.85 + mx * 0.15),
            min(1, rgb.1 * 0.85 + mx * 0.15),
            min(1, rgb.2 * 0.85 + mx * 0.15)
        )
    }

    private static func color(from rgb: (Double, Double, Double)) -> Color {
        Color(red: rgb.0, green: rgb.1, blue: rgb.2)
    }
}

// MARK: - 控制器（首张卡片缩略图 + 采样）

@MainActor
final class ExploreAtmosphereController: ObservableObject {
    @Published private(set) var tint: ExploreAtmosphereTint
    @Published private(set) var referenceImage: NSImage?

    private var loadTask: Task<Void, Never>?
    private let wallpaperMode: Bool
    /// 避免列表刷新但首张未变时重复拉缩略图、重复采样
    private var activeFirstItemKey: String?

    init(wallpaperMode: Bool) {
        self.wallpaperMode = wallpaperMode
        self.tint = wallpaperMode ? .wallpaperFallback : .mediaFallback
    }

    deinit {
        loadTask?.cancel()
    }

    func resetToFallback() {
        loadTask?.cancel()
        loadTask = nil
        referenceImage = nil
        activeFirstItemKey = nil
        tint = wallpaperMode ? .wallpaperFallback : .mediaFallback
    }

    func updateFirstWallpaper(_ wallpaper: Wallpaper?) {
        guard let wallpaper else {
            resetToFallback()
            return
        }

        let key = "w:\(wallpaper.id)"
        if key == activeFirstItemKey, referenceImage != nil {
            return
        }
        activeFirstItemKey = key

        loadTask?.cancel()
        loadTask = nil
        referenceImage = nil

        tint = ExploreAtmosphereTint.fromWallpaperMetadata(wallpaper)

        guard let url = wallpaper.thumbURL ?? wallpaper.smallThumbURL else { return }

        loadTask = Task {
            let image = await ImageLoader.shared.loadImage(from: url, priority: .low)
            guard !Task.isCancelled, let image else { return }

            // 在后台线程进行颜色采样（耗时操作）
            let sampledColors = await Task.detached(priority: .userInitiated) {
                ExploreImageColorSampler.triplet(from: image)
            }.value

            guard !Task.isCancelled else { return }

            await MainActor.run {
                referenceImage = image
                if let (c1, c2, c3) = sampledColors {
                    tint = ExploreAtmosphereTint.fromSampledTriplet(c1, c2, c3)
                }
            }
        }
    }

    func updateFirstMedia(_ item: MediaItem?) {
        guard let item else {
            resetToFallback()
            return
        }

        let key = "m:\(item.id)"
        if key == activeFirstItemKey, referenceImage != nil {
            return
        }
        activeFirstItemKey = key

        loadTask?.cancel()
        loadTask = nil
        referenceImage = nil

        tint = .mediaFallback
        let url = item.posterURLValue ?? item.thumbnailURLValue

        loadTask = Task {
            let image = await ImageLoader.shared.loadImage(from: url, priority: .low)
            guard !Task.isCancelled, let image else { return }

            // 在后台线程进行颜色采样
            let sampledColors = await Task.detached(priority: .userInitiated) {
                ExploreImageColorSampler.triplet(from: image)
            }.value

            guard !Task.isCancelled else { return }

            await MainActor.run {
                referenceImage = image
                if let (c1, c2, c3) = sampledColors {
                    tint = ExploreAtmosphereTint.fromSampledTriplet(c1, c2, c3)
                }
            }
        }
    }

    func updateFirstAnime(coverURL: String) {
        guard !coverURL.isEmpty else {
            resetToFallback()
            return
        }

        let key = "a:\(coverURL)"
        if key == activeFirstItemKey, referenceImage != nil {
            return
        }
        activeFirstItemKey = key
        loadTask?.cancel()
        loadTask = nil
        referenceImage = nil

        // 动漫使用媒体回退色调
        tint = .mediaFallback

        guard let url = URL(string: coverURL) else { return }

        loadTask = Task {
            let image = await ImageLoader.shared.loadImage(from: url, priority: .low)
            guard !Task.isCancelled, let image else { return }

            // 在后台线程进行颜色采样
            let sampledColors = await Task.detached(priority: .userInitiated) {
                ExploreImageColorSampler.triplet(from: image)
            }.value

            guard !Task.isCancelled else { return }

            await MainActor.run {
                referenceImage = image
                if let (c1, c2, c3) = sampledColors {
                    tint = ExploreAtmosphereTint.fromSampledTriplet(c1, c2, c3)
                }
            }
        }
    }
}

// MARK: - 胶片噪点平铺（Arc 类质感，生成一次复用）

// MARK: - 全局胶片噪点纹理

enum GrainTextureTile {
    /// 胶片颗粒：避开「贴在中灰」——softLight 对 128 附近几乎无变化，改用更宽的明暗变化才看得见。
    static let image: NSImage = {
        let w = 256
        let h = 256
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: w,
                pixelsHigh: h,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ),
            let data = rep.bitmapData
        else {
            return NSImage(size: NSSize(width: 1, height: 1))
        }
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        for y in 0..<h {
            for x in 0..<w {
                state = state &* 6_364_136_223_846_793_005 &+ 1
                let u = UInt32(truncatingIfNeeded: state >> 33)
                // 约 55–200 的亮度跨度，叠 softLight/overlay 时才有可感颗粒
                let v = UInt8(clamping: 55 + Int(u % 146))
                let o = (y * w + x) * 4
                data[o] = v
                data[o + 1] = v
                data[o + 2] = v
                data[o + 3] = 255
            }
        }
        let img = NSImage(size: NSSize(width: w, height: h))
        img.addRepresentation(rep)
        return img
    }()
}

// MARK: - 全局颗粒材质覆盖层（支持开关和轻量模式）

struct GrainTextureOverlay: View {
    @AppStorage("grain_texture_enabled") private var enabled = true
    @AppStorage("grain_texture_quality") private var quality = "high" // high / low / off
    var lightweight: Bool = false

    var body: some View {
        if enabled && quality != "off" {
            // 轻量模式或低质量设置时使用单层
            let isLightweight = lightweight || quality == "low"
            
            Image(nsImage: GrainTextureTile.image)
                .resizable(resizingMode: .tile)
                .blendMode(.overlay)
                .opacity(isLightweight ? 0.15 : 0.35)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - 动态背景：散色模糊底图 + 原有氛围渐变 + 轻磨砂 + 噪点

struct ExploreDynamicAtmosphereBackground: View {
    let tint: ExploreAtmosphereTint
    let referenceImage: NSImage?
    /// 快速滚动时减轻效果，避免卡顿
    var lightweightBackdrop: Bool = false

    var body: some View {
        ZStack {
            // 基础氛围背景
            LiquidGlassAtmosphereBackground(
                primary: tint.primary,
                secondary: tint.secondary,
                tertiary: tint.tertiary,
                baseTop: tint.baseTop,
                baseBottom: tint.baseBottom
            )

            // 参考图片模糊背景（轻量模式时禁用）
            if !lightweightBackdrop, let referenceImage {
                Image(nsImage: referenceImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(minWidth: 200, minHeight: 200) // 进一步降低分辨率
                    .blur(radius: 60) // 增加模糊减少细节
                    .opacity(0.2) // 降低不透明度
                    .saturation(1.05)
                    .allowsHitTesting(false)
            }

            // 简化：合并径向渐变效果
            RadialGradient(
                colors: [
                    tint.primary.opacity(lightweightBackdrop ? 0.06 : 0.08),
                    tint.secondary.opacity(lightweightBackdrop ? 0.03 : 0.04),
                    Color.clear
                ],
                center: .topLeading,
                startRadius: 20,
                endRadius: lightweightBackdrop ? 200 : 300
            )
            .allowsHitTesting(false)

            // 移除材质层，使用纯色替代
            Rectangle()
                .fill(tint.baseTop.opacity(0.05))
                .allowsHitTesting(false)

            // 底部渐变遮罩
            LinearGradient(
                colors: [
                    Color.clear,
                    tint.baseBottom.opacity(0.3)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }
}
