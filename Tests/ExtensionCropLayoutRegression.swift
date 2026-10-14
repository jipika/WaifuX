import CoreGraphics
import Foundation
import QuartzCore

@main
struct ExtensionCropLayoutRegression {
    static func main() {
        testRequestGeometry()
        testContextRouting()
        testLayerLayouts()
        testStaticImageRelayout()
        let sourceSize = CGSize(width: 1920, height: 1080)
        let laptopScreenSize = CGSize(width: 1600, height: 1000)
        let layout = ExtCropEngine.compute(
            wallpaperSize: sourceSize,
            screenSize: laptopScreenSize,
            settings: .default
        )

        precondition(approximatelyEqual(layout.viewportRect.x, 0))
        precondition(approximatelyEqual(layout.viewportRect.y, 0))
        precondition(approximatelyEqual(layout.viewportRect.w, 1))
        precondition(approximatelyEqual(layout.viewportRect.h, 1))
        precondition(approximatelyEqual(layout.wallpaperCropRect.x, 0.05))
        precondition(approximatelyEqual(layout.wallpaperCropRect.y, 0))
        precondition(approximatelyEqual(layout.wallpaperCropRect.w, 0.9))
        precondition(approximatelyEqual(layout.wallpaperCropRect.h, 1))

        let geometry = ExtCropGeometry.layerGeometry(
            layout: layout,
            in: CGRect(origin: .zero, size: laptopScreenSize)
        )
        let videoFrameAspect = geometry.videoFrame.width / geometry.videoFrame.height
        precondition(approximatelyEqual(videoFrameAspect, sourceSize.width / sourceSize.height))
        precondition(geometry.videoFrame.width > laptopScreenSize.width)
        precondition(approximatelyEqual(geometry.videoFrame.height, laptopScreenSize.height))

        let portraitScreenSize = CGSize(width: 1080, height: 1920)
        let portraitLayout = ExtCropEngine.compute(
            wallpaperSize: sourceSize,
            screenSize: portraitScreenSize,
            settings: .default
        )
        let portraitGeometry = ExtCropGeometry.layerGeometry(
            layout: portraitLayout,
            in: CGRect(origin: .zero, size: portraitScreenSize)
        )
        precondition(
            approximatelyEqual(
                portraitGeometry.videoFrame.width / portraitGeometry.videoFrame.height,
                sourceSize.width / sourceSize.height
            )
        )
        precondition(portraitGeometry.videoFrame.width > portraitScreenSize.width)
        precondition(approximatelyEqual(portraitGeometry.videoFrame.height, portraitScreenSize.height))

        let croppedAspect = (
            sourceSize.width * layout.wallpaperCropRect.w
        ) / (
            sourceSize.height * layout.wallpaperCropRect.h
        )
        precondition(approximatelyEqual(croppedAspect, laptopScreenSize.width / laptopScreenSize.height))

        print(
            "Extension crop regression passed: "
                + "crop=\(layout.wallpaperCropRect.x),"
                + "\(layout.wallpaperCropRect.y),"
                + "\(layout.wallpaperCropRect.w),"
                + "\(layout.wallpaperCropRect.h)"
        )
    }

    private static func testRequestGeometry() {
        let portrait = ExtDisplayGeometry.parse(descriptions: [
            "request(displayID: 3, width: 1080.0, height: 1920.0, scaleFactor: 2.0)"
        ])
        precondition(portrait.displayID == 3)
        precondition(portrait.size == CGSize(width: 1080, height: 1920))
        precondition(portrait.scale == 2)
        let nested = ExtDisplayGeometry.parse(descriptions: [
            "request(displayID: 1)", "geometry(directDisplayID: 3, width: 900, height: 1600, scaleFactor: 2)"
        ])
        precondition(nested.displayID == 3 && nested.size == CGSize(width: 900, height: 1600))
        for description in [
            "width: unknown, height: 1920", "width: 1080, height: 0", "width: -1, height: 1920",
            "width: 1e300, height: 1920", "width: nan, height: 1920", "width: 1080, height: inf"
        ] {
            precondition(ExtDisplayGeometry.parse(descriptions: [description]).size == nil,
                         "Malformed request must fall back to display metrics, never 1920x1080")
        }
        precondition(ExtDisplayGeometry.parse(descriptions: ["width: 1080", "height: 1920"]).size == nil)
        for token in ["0", "-1", "3.5", "4294967296", "1e300", "nan"] {
            precondition(ExtDisplayGeometry.parse(descriptions: ["displayID: \(token)"]).displayID == nil)
        }
        precondition(ExtDisplayGeometry.parse(descriptions: ["scaleFactor: -1"]).scale == nil)
        precondition(ExtDisplayGeometry.parse(descriptions: ["scaleFactor: 1e300"]).scale == nil)
    }

    private static func testContextRouting() {
        // 同一 wallpaper ID 的桌面、锁屏两个实例都刷新，其它显示器不受影响。
        let contexts: [(String, UInt32)] = [("portrait", 3), ("portrait", 3), ("landscape", 1)]
        func selected(_ wallpaperID: String?, _ displayID: UInt32?) -> [Int] {
            contexts.indices.filter {
                ExtDisplayGeometry.matches(
                    wallpaperID: wallpaperID, displayID: displayID,
                    contextWallpaperID: contexts[$0].0, contextDisplayID: contexts[$0].1)
            }
        }
        precondition(selected("portrait", 3) == [0, 1])
        precondition(selected(nil, 3) == [0, 1])
        precondition(selected("invalidated", 3).isEmpty)
        precondition(selected(nil, 99).isEmpty)
        precondition(selected(nil, nil) == [0, 1, 2])
        precondition(!ExtDisplayGeometry.matches(
            wallpaperID: "shared", displayID: 3, contextWallpaperID: "shared", contextDisplayID: 1),
            "An update for the portrait display must not resize another online display using the same wallpaper")
        precondition(ExtDisplayGeometry.matches(
            wallpaperID: "shared", displayID: 3, contextWallpaperID: "shared", contextDisplayID: 1,
            contextDisplayIsActive: false), "A known wallpaper may migrate from a disconnected display")
    }

    /// 只创建未挂载的 CALayer；不创建 NSWindow、CAContext、播放器或 IOSurface。
    private static func testLayerLayouts() {
        let sourceSizes = [CGSize(width: 1920, height: 1080), CGSize(width: 1080, height: 1920), CGSize(width: 1000, height: 1000)]
        let screenSizes = [CGSize(width: 1080, height: 1920), CGSize(width: 900, height: 1600), CGSize(width: 1920, height: 1080), CGSize(width: 1600, height: 1000)]
        var fixed = ExtCropSettings.default
        fixed.aspectPreset = .ratio16x9
        var portrait = ExtCropSettings.default
        portrait.aspectPreset = .custom
        portrait.customAspect = 9.0 / 16
        var zoomed = fixed
        zoomed.zoom = 3
        zoomed.pan = CGPoint(x: 0, y: 1)
        var disabled = zoomed
        disabled.isEnabled = false

        for sourceSize in sourceSizes {
            for screenSize in screenSizes {
                for settings in [ExtCropSettings.default, fixed, portrait, zoomed, disabled] {
                    let root = CALayer()
                    root.bounds = CGRect(origin: CGPoint(x: 13, y: 17), size: screenSize)
                    root.contentsScale = 2
                    let viewport = CALayer()
                    root.addSublayer(viewport)
                    let layers = [CALayer(), CALayer(), CALayer()]
                    layers.forEach { viewport.addSublayer($0) }
                    ExtCropLayers.apply(rootLayer: root, viewportLayer: viewport, contentLayers: layers,
                                        sourceSize: sourceSize, settings: settings)
                    precondition(root.masksToBounds && viewport.masksToBounds)
                    precondition(approximatelyEqual(viewport.frame.midX, root.bounds.midX))
                    precondition(approximatelyEqual(viewport.frame.midY, root.bounds.midY))
                    for layer in layers {
                        precondition(layer.contentsGravity == .resizeAspectFill)
                        precondition(layer.contentsRect == CGRect(x: 0, y: 0, width: 1, height: 1))
                        precondition(layer.contentsScale == 2)
                        precondition(layer.frame == layers[0].frame, "Video, poster and paused frame must agree")
                        precondition(approximatelyEqual(layer.frame.width / layer.frame.height, sourceSize.width / sourceSize.height))
                        precondition(layer.frame.minX <= 0.000_001 && layer.frame.minY <= 0.000_001)
                        precondition(layer.frame.maxX >= viewport.bounds.width - 0.000_001)
                        precondition(layer.frame.maxY >= viewport.bounds.height - 0.000_001)
                    }
                    if !settings.isEnabled || settings.aspectPreset == .autoFill {
                        precondition(viewport.frame == root.bounds)
                    } else if settings.aspectPreset == .ratio16x9 {
                        precondition(approximatelyEqual(viewport.frame.width / viewport.frame.height, 16.0 / 9))
                    }
                }
            }
        }
    }

    private static func testStaticImageRelayout() {
        let bitmap = CGContext(data: nil, width: 16, height: 9, bitsPerComponent: 8, bytesPerRow: 64,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = bitmap.makeImage()!
        let root = CALayer()
        root.bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        // 模拟旧静态图路径遗留的拉伸/裁剪状态。
        root.contents = image
        root.contentsGravity = .resize
        root.contentsRect = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        root.contentsCenter = CGRect(x: 0, y: 0.25, width: 1, height: 0.5)
        ExtCropLayers.setStaticImage(image, in: root, settings: .default)
        let viewport = root.sublayers!.first!
        let content = viewport.sublayers!.first!
        precondition(root.contents == nil)
        precondition(root.contentsRect == CGRect(x: 0, y: 0, width: 1, height: 1))
        precondition(root.contentsCenter == CGRect(x: 0, y: 0, width: 1, height: 1))

        // 同一个实例横屏 → 竖屏 → HiDPI → 比例设置变化，无需换图或重新 acquire。
        root.bounds = CGRect(x: 0, y: 0, width: 1080, height: 1920)
        ExtCropLayers.setStaticImage(ExtCropLayers.staticImage(in: root)!, in: root, settings: .default)
        precondition(approximatelyEqual(content.frame.height, 1920))
        precondition(approximatelyEqual(content.frame.width, 1920 * 16.0 / 9))
        root.contentsScale = 2
        var settings = ExtCropSettings.default
        settings.aspectPreset = .ratio16x9
        settings.zoom = 2
        settings.pan = CGPoint(x: 1, y: 0)
        ExtCropLayers.setStaticImage(image, in: root, settings: settings)
        precondition(approximatelyEqual(viewport.frame.height, 1080 * 9.0 / 16))
        precondition(content.contentsScale == 2)
        precondition(approximatelyEqual(content.frame.width / content.frame.height, 16.0 / 9))
        precondition(root.sublayers?.count == 1 && viewport.sublayers?.count == 1)
        precondition(root.sublayers?.first === viewport && viewport.sublayers?.first === content)
        ExtCropLayers.removeStaticImage(from: root)
        precondition(root.sublayers?.isEmpty ?? true)
        precondition(ExtCropLayers.staticImage(in: root) == nil)
    }

    private static func approximatelyEqual(
        _ lhs: CGFloat,
        _ rhs: CGFloat,
        tolerance: CGFloat = 0.000_001
    ) -> Bool {
        abs(lhs - rhs) <= tolerance
    }
}
