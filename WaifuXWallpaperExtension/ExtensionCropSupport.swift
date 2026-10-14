import Foundation
import CoreGraphics
import QuartzCore

// 扩展端可视区域调节支持。
// App 端 (DisplayCropSettingsStore) 把每屏 crop 配置写入 App Group JSON
// (waifux-crop-prefs.json, key = "display-<displayID>")；扩展端在此读取并计算。
// 类型与 App 端 Models/DisplayCropSettings.swift + Services/CropLayoutEngine.swift 保持一致。

/// 归一化矩形（原点左上，y 向下）。
struct ExtUnitRect {
    var x: Double
    var y: Double
    var w: Double
    var h: Double
    static let full = ExtUnitRect(x: 0, y: 0, w: 1, h: 1)
}

enum ExtAspectPreset: String, Codable, CaseIterable {
    case autoFill, ratio16x9, ratio16x10, ratio21x9, ratio32x9, ratio4x3, ratio1x1, custom
    var aspectRatio: Double? {
        switch self {
        case .autoFill, .custom: return nil
        case .ratio16x9:  return 16.0 / 9.0
        case .ratio16x10: return 16.0 / 10.0
        case .ratio21x9:  return 21.0 / 9.0
        case .ratio32x9:  return 32.0 / 9.0
        case .ratio4x3:   return 4.0 / 3.0
        case .ratio1x1:   return 1.0
        }
    }
}

struct ExtCropSettings: Codable {
    var aspectPreset: ExtAspectPreset = .autoFill
    var customAspect: Double? = nil
    /// 与 App 端 DisplayCropSettings.pan 同名同型（CGPoint → JSON [x,y]），保证跨进程解码一致。
    /// pan ∈ [0,1]，0.5=居中（与 App 端 v2 语义一致）。
    var pan: CGPoint = CGPoint(x: 0.5, y: 0.5)
    var zoom: Double = 1.0
    var letterboxColorHex: String = "000000"
    var isEnabled: Bool = true

    var effectiveAspect: Double? {
        switch aspectPreset {
        case .autoFill: return nil
        case .custom:
            guard let customAspect, customAspect.isFinite, customAspect > 0 else {
                return nil
            }
            return customAspect
        default: return aspectPreset.aspectRatio
        }
    }
    var shouldApplyCrop: Bool { isEnabled }

    static let `default` = ExtCropSettings()
}

struct ExtCropLayout {
    var wallpaperCropRect: ExtUnitRect
    var viewportRect: ExtUnitRect
    var letterboxColor: CGColor
}

/// CALayer 坐标系中的裁切结果。
/// `videoFrame` 可以超出 viewportRect，由独立 viewport layer 裁掉溢出部分；
/// 因此视频层始终按原始比例渲染，不依赖 contentsRect 做非等比拉伸。
struct ExtLayerCropGeometry {
    var viewportRect: CGRect
    var videoFrame: CGRect
}

enum ExtCropEngine {
    static func compute(
        wallpaperSize: CGSize,
        screenSize: CGSize,
        settings: ExtCropSettings
    ) -> ExtCropLayout {
        let letterboxColor = parseColorHex(settings.letterboxColorHex)
        guard settings.shouldApplyCrop else {
            return ExtCropLayout(wallpaperCropRect: .full, viewportRect: .full, letterboxColor: letterboxColor)
        }
        let screenAspect = screenSize.height > 0 ? screenSize.width / screenSize.height : 1.0
        let targetAspect = settings.effectiveAspect ?? screenAspect
        let viewport: ExtUnitRect
        if targetAspect > screenAspect {
            let h = screenAspect / targetAspect
            viewport = ExtUnitRect(x: 0, y: (1 - h) / 2, w: 1, h: h)
        } else {
            let w = targetAspect / screenAspect
            viewport = ExtUnitRect(x: (1 - w) / 2, y: 0, w: w, h: 1)
        }
        // Use pixel geometry here, not the normalized viewport ratio.
        // For an auto-fill viewport, viewport.w / viewport.h is always 1 even
        // when the display is 16:10. Treating it as the target aspect stretches
        // a 16:9 frame across the lock screen instead of cropping it.
        let vpW = viewport.w * screenSize.width
        let vpH = viewport.h * screenSize.height
        let wpW = wallpaperSize.width
        let wpH = wallpaperSize.height
        let coverScale = max(
            wpW > 0 ? vpW / wpW : 1.0,
            wpH > 0 ? vpH / wpH : 1.0
        )
        let zoom = max(1.0, min(4.0, settings.zoom))
        let scale = coverScale * zoom
        let displayWidth = wpW * scale
        let displayHeight = wpH * scale
        let winW = displayWidth > 0 ? vpW / displayWidth : 1.0
        let winH = displayHeight > 0 ? vpH / displayHeight : 1.0
        let panX = max(0, min(1, settings.pan.x))
        let panY = max(0, min(1, settings.pan.y))
        let originX = max(0, min(1 - winW, panX - winW / 2))
        let originY = max(0, min(1 - winH, panY - winH / 2))
        return ExtCropLayout(
            wallpaperCropRect: ExtUnitRect(x: originX, y: originY, w: winW, h: winH),
            viewportRect: viewport,
            letterboxColor: letterboxColor)
    }

    static func parseColorHex(_ hex: String) -> CGColor {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else {
            return CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        }
        return CGColor(red: CGFloat((v >> 16) & 0xFF) / 255.0,
                       green: CGFloat((v >> 8) & 0xFF) / 255.0,
                       blue: CGFloat(v & 0xFF) / 255.0, alpha: 1)
    }
}

enum ExtCropGeometry {
    /// 把归一化 crop/viewport 转为 CALayer 几何。
    /// ExtUnitRect 使用左上原点，CALayer 使用左下原点，所以这里翻转 y。
    static func layerGeometry(layout: ExtCropLayout, in bounds: CGRect) -> ExtLayerCropGeometry {
        let viewport = layout.viewportRect
        let crop = layout.wallpaperCropRect
        let viewportRect = CGRect(
            x: viewport.x * bounds.width,
            y: (1 - viewport.y - viewport.h) * bounds.height,
            width: viewport.w * bounds.width,
            height: viewport.h * bounds.height
        )

        let cropWidth = max(crop.w, 0.0001)
        let cropHeight = max(crop.h, 0.0001)
        let videoWidth = viewportRect.width / cropWidth
        let videoHeight = viewportRect.height / cropHeight
        let videoFrame = CGRect(
            x: viewportRect.minX - crop.x * videoWidth,
            y: viewportRect.minY - (1 - crop.y - crop.h) * videoHeight,
            width: videoWidth,
            height: videoHeight
        )
        return ExtLayerCropGeometry(
            viewportRect: viewportRect,
            videoFrame: videoFrame
        )
    }
}

/// 图片、视频及暂停帧共用同一套 layer 布局；不通过 contentsRect/contentsCenter 拉伸内容。
/// 只操作调用方传入的 layer，不创建窗口、播放器或 IOSurface。调用方须在主线程使用。
enum ExtCropLayers {
    private static let staticViewportName = "waifux.static.viewport"

    @discardableResult
    static func apply(
        rootLayer: CALayer, viewportLayer: CALayer, contentLayers: [CALayer],
        sourceSize: CGSize, settings: ExtCropSettings
    ) -> Bool {
        guard ExtDisplayGeometry.isValid(size: sourceSize),
              ExtDisplayGeometry.isValid(size: rootLayer.bounds.size) else { return false }
        // 关闭自定义裁剪仍要保持图片比例，使用默认 auto-fill 几何。
        let effectiveSettings = settings.shouldApplyCrop ? settings : .default
        let layout = ExtCropEngine.compute(
            wallpaperSize: sourceSize, screenSize: rootLayer.bounds.size, settings: effectiveSettings)
        let geometry = ExtCropGeometry.layerGeometry(
            layout: layout, in: CGRect(origin: .zero, size: rootLayer.bounds.size))
        let viewportFrame = geometry.viewportRect.offsetBy(dx: rootLayer.bounds.minX, dy: rootLayer.bounds.minY)
        let contentFrame = geometry.videoFrame.offsetBy(
            dx: -geometry.viewportRect.minX, dy: -geometry.viewportRect.minY)
        let fullRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        let changed = viewportLayer.frame != viewportFrame
            || rootLayer.backgroundColor != layout.letterboxColor
            || contentLayers.contains { $0.frame != contentFrame || $0.contentsScale != rootLayer.contentsScale }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rootLayer.masksToBounds = true
        rootLayer.contentsGravity = .resizeAspectFill
        rootLayer.contentsRect = fullRect
        rootLayer.contentsCenter = fullRect
        rootLayer.backgroundColor = layout.letterboxColor
        viewportLayer.frame = viewportFrame
        viewportLayer.bounds = CGRect(origin: .zero, size: geometry.viewportRect.size)
        viewportLayer.contentsScale = rootLayer.contentsScale
        viewportLayer.masksToBounds = true
        for layer in contentLayers {
            layer.frame = contentFrame
            layer.contentsGravity = .resizeAspectFill
            layer.contentsRect = fullRect
            layer.contentsCenter = fullRect
            layer.contentsScale = rootLayer.contentsScale
        }
        CATransaction.commit()
        return changed
    }

    static func staticImage(in rootLayer: CALayer) -> CGImage? {
        guard let content = staticViewport(in: rootLayer)?.sublayers?.first else { return nil }
        return imageContents(in: content)
    }

    static func imageContents(in layer: CALayer) -> CGImage? {
        guard let contents = layer.contents else { return nil }
        let object = contents as AnyObject
        // CoreFoundation 类型不能依赖 as? 做动态检查（contents 也可能是 IOSurface）。
        guard CFGetTypeID(object) == CGImage.typeID else { return nil }
        return (object as! CGImage)
    }

    @discardableResult
    static func setStaticImage(_ image: CGImage, in rootLayer: CALayer, settings: ExtCropSettings) -> Bool {
        let viewport = staticViewport(in: rootLayer) ?? CALayer()
        let content = viewport.sublayers?.first ?? CALayer()
        let isNew = viewport.superlayer == nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        viewport.name = staticViewportName
        if content.superlayer == nil { viewport.addSublayer(content) }
        if isNew { rootLayer.addSublayer(viewport) }
        content.contents = image
        rootLayer.contents = nil
        let changed = apply(
            rootLayer: rootLayer, viewportLayer: viewport, contentLayers: [content],
            sourceSize: CGSize(width: image.width, height: image.height), settings: settings)
        CATransaction.commit()
        return isNew || changed
    }

    static func removeStaticImage(from rootLayer: CALayer) {
        staticViewport(in: rootLayer)?.removeFromSuperlayer()
    }

    private static func staticViewport(in rootLayer: CALayer) -> CALayer? {
        rootLayer.sublayers?.first { $0.name == staticViewportName }
    }
}

/// XPC 的字符串反射解析失败时必须回退到对应显示器，不能把 1920x1080 当成竖屏尺寸。
enum ExtDisplayGeometry {
    static func matches(
        wallpaperID: String?, displayID: UInt32?,
        contextWallpaperID: String?, contextDisplayID: UInt32?, contextDisplayIsActive: Bool = true
    ) -> Bool {
        if let wallpaperID, contextWallpaperID != wallpaperID { return false }
        if let displayID, contextDisplayID != displayID {
            // 同一壁纸可出现在多个在线屏幕。仅明确匹配 wallpaperID 且原屏已断开
            // 才接受 displayID 迁移，不能把另一块在线屏幕一并改成目标竖屏。
            return wallpaperID != nil && !contextDisplayIsActive
        }
        return true
    }

    static func isValid(size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite
            && size.width > 0 && size.height > 0
            && size.width <= 32768 && size.height <= 32768
    }

    static func parse(descriptions: [String]) -> (displayID: UInt32?, size: CGSize?, scale: CGFloat?) {
        func number(after marker: String, in description: String) -> Double? {
            guard let range = description.range(of: marker) else { return nil }
            let token = description[range.upperBound...].drop(while: { $0 == " " })
                .prefix { $0.isNumber || $0 == "." || $0 == "-" || $0 == "+" || $0 == "e" || $0 == "E" }
            guard let value = Double(token), value.isFinite else { return nil }
            return value
        }
        func firstNumber(after marker: String) -> Double? {
            descriptions.lazy.compactMap { number(after: marker, in: $0) }.first
        }
        func validDisplayID(_ value: Double) -> UInt32? {
            guard let id = UInt32(exactly: value), id > 0 else { return nil }
            return id
        }
        let displayID = firstNumber(after: "directDisplayID: ").flatMap(validDisplayID)
            ?? firstNumber(after: "displayID: ").flatMap(validDisplayID)
        // 宽高必须来自同一份描述，不能把两个不完整对象各取一个轴拼成尺寸。
        let size = descriptions.lazy.compactMap { description -> CGSize? in
            guard let width = number(after: "width: ", in: description),
                  let height = number(after: "height: ", in: description) else { return nil }
            let candidate = CGSize(width: width, height: height)
            return isValid(size: candidate) ? candidate : nil
        }.first
        let scale = firstNumber(after: "scaleFactor: ").flatMap { $0 > 0 && $0 <= 16 ? CGFloat($0) : nil }
        return (displayID, size, scale)
    }
}

/// 扩展端从 App Group JSON 读取指定 displayID 的 crop 配置。
enum ExtCropPrefs {
    private static let appGroupID = "group.com.waifux.app"
    private static let jsonName = "waifux-crop-prefs.json"

    static func settings(forDisplayID displayID: UInt32) -> ExtCropSettings {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID) else {
            return .default
        }
        let url = container.appendingPathComponent(jsonName)
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: ExtCropSettings].self, from: data) else {
            return .default
        }
        return dict["display-\(displayID)"] ?? .default
    }
}
