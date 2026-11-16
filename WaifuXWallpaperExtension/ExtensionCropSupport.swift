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

enum ExtDisplayMode: String, Codable, CaseIterable {
    case fill, fit
}

struct ExtCropSettings: Codable {
    var displayMode: ExtDisplayMode = .fill
    var aspectPreset: ExtAspectPreset = .autoFill
    var customAspect: Double? = nil
    /// 与 App 端 DisplayCropSettings.pan 同名同型（CGPoint → JSON [x,y]），保证跨进程解码一致。
    /// pan ∈ [0,1]，0.5=居中（与 App 端 v2 语义一致）。
    var pan: CGPoint = CGPoint(x: 0.5, y: 0.5)
    var zoom: Double = 1.0
    var letterboxColorHex: String = "000000"
    var isEnabled: Bool = true

    init() {}

    private enum CodingKeys: String, CodingKey {
        case displayMode, aspectPreset, customAspect, pan, zoom, letterboxColorHex, isEnabled
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let rawMode = try? values.decode(String.self, forKey: .displayMode)
        displayMode = rawMode.flatMap(ExtDisplayMode.init(rawValue:)) ?? .fill
        aspectPreset = try values.decodeIfPresent(ExtAspectPreset.self, forKey: .aspectPreset) ?? .autoFill
        customAspect = try values.decodeIfPresent(Double.self, forKey: .customAspect)
        pan = try values.decodeIfPresent(CGPoint.self, forKey: .pan) ?? CGPoint(x: 0.5, y: 0.5)
        zoom = try values.decodeIfPresent(Double.self, forKey: .zoom) ?? 1
        letterboxColorHex = try values.decodeIfPresent(String.self, forKey: .letterboxColorHex) ?? "000000"
        isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(displayMode.rawValue, forKey: .displayMode)
        try values.encode(aspectPreset, forKey: .aspectPreset)
        try values.encodeIfPresent(customAspect, forKey: .customAspect)
        try values.encode(pan, forKey: .pan)
        try values.encode(zoom, forKey: .zoom)
        try values.encode(letterboxColorHex, forKey: .letterboxColorHex)
        try values.encode(isEnabled, forKey: .isEnabled)
    }

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
    var isTiled: Bool = false
}

/// CALayer 坐标系中的裁切结果。
/// `videoFrame` 可以超出 viewportRect，由独立 viewport layer 裁掉溢出部分。
/// 非 stretch 模式的 frame 保持原始比例；stretch 把全图映射到 viewport。
struct ExtLayerCropGeometry {
    var viewportRect: CGRect
    var videoFrame: CGRect
}

enum ExtCropEngine {
    static func isValidSourceSize(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
            && size.width <= 1_000_000 && size.height <= 1_000_000
    }

    static func compute(
        wallpaperSize: CGSize,
        screenSize: CGSize,
        settings: ExtCropSettings
    ) -> ExtCropLayout {
        let settings = settings.isEnabled ? settings : .default
        let letterboxColor = parseColorHex(settings.letterboxColorHex)
        guard wallpaperSize.width.isFinite, wallpaperSize.height.isFinite,
              screenSize.width.isFinite, screenSize.height.isFinite,
              wallpaperSize.width > 0, wallpaperSize.height > 0,
              screenSize.width > 0, screenSize.height > 0 else {
            return ExtCropLayout(wallpaperCropRect: .full, viewportRect: .full, letterboxColor: letterboxColor)
        }
        let screenAspect = screenSize.width / screenSize.height
        let targetAspect = settings.effectiveAspect ?? screenAspect
        let viewport: ExtUnitRect
        if targetAspect > screenAspect {
            let h = screenAspect / targetAspect
            viewport = ExtUnitRect(x: 0, y: (1 - h) / 2, w: 1, h: h)
        } else {
            let w = targetAspect / screenAspect
            viewport = ExtUnitRect(x: (1 - w) / 2, y: 0, w: w, h: 1)
        }
        // screenSize is physical pixels.
        let vpW = viewport.w * screenSize.width
        let vpH = viewport.h * screenSize.height
        let wpW = wallpaperSize.width
        let wpH = wallpaperSize.height
        let zoom = settings.zoom.isFinite ? max(0.25, min(4.0, settings.zoom)) : 1.0
        let baseScale: Double
        switch settings.displayMode {
        case .fill: baseScale = max(vpW / wpW, vpH / wpH)
        case .fit: baseScale = min(vpW / wpW, vpH / wpH)
        }
        let scale = baseScale * zoom
        let displayWidth = wpW * scale
        let displayHeight = wpH * scale
        let winW = vpW / displayWidth
        let winH = vpH / displayHeight
        let panX = settings.pan.x.isFinite ? max(0, min(1, settings.pan.x)) : 0.5
        let panY = settings.pan.y.isFinite ? max(0, min(1, settings.pan.y)) : 0.5
        func origin(window: Double, pan: Double) -> Double {
            if window <= 1 { return max(0, min(1 - window, pan - window / 2)) }
            return (1 - window) * pan
        }
        return ExtCropLayout(
            wallpaperCropRect: ExtUnitRect(x: origin(window: winW, pan: panX), y: origin(window: winH, pan: panY), w: winW, h: winH),
            viewportRect: viewport,
            letterboxColor: letterboxColor,
            isTiled: false)
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

        let cropWidth = crop.w.isFinite && crop.w > 0 ? crop.w : 1
        let cropHeight = crop.h.isFinite && crop.h > 0 ? crop.h : 1
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

/// A bounded repeat plan shared by CALayer and CPU snapshots. Its origin is
/// the first tile intersecting the viewport, so no offscreen copies are needed.
struct ExtTilePlan {
    static let maximumCopies = 65_536
    let frame: CGRect
    let columns: Int
    let rows: Int

    static func make(contentFrame: CGRect, viewportSize: CGSize) -> ExtTilePlan? {
        guard contentFrame.width.isFinite, contentFrame.height.isFinite,
              contentFrame.minX.isFinite, contentFrame.minY.isFinite,
              viewportSize.width.isFinite, viewportSize.height.isFinite,
              contentFrame.width > 0, contentFrame.height > 0,
              viewportSize.width > 0, viewportSize.height > 0 else { return nil }
        let x = contentFrame.minX - ceil(contentFrame.minX / contentFrame.width) * contentFrame.width
        let y = contentFrame.minY - ceil(contentFrame.minY / contentFrame.height) * contentFrame.height
        let columns = ceil((viewportSize.width - x) / contentFrame.width)
        let rows = ceil((viewportSize.height - y) / contentFrame.height)
        guard columns.isFinite, rows.isFinite, columns >= 1, rows >= 1,
              columns <= CGFloat(maximumCopies), rows <= CGFloat(maximumCopies),
              columns * rows <= CGFloat(maximumCopies) else { return nil }
        return ExtTilePlan(frame: CGRect(origin: CGPoint(x: x, y: y), size: contentFrame.size),
                           columns: Int(columns), rows: Int(rows))
    }
}

/// 图片、视频及暂停帧共用同一套 frame 布局；contentsRect/contentsCenter 始终为全图。
/// 只操作调用方传入的 layer，不创建窗口、播放器或 IOSurface。调用方须在主线程使用。
enum ExtCropLayers {
    private static let staticViewportName = "waifux.static.viewport"
    private static let staticContentName = "waifux.static.content"
    private static let tileWrapperName = "waifux.crop.tiles"
    private static let tileColumnsName = "waifux.crop.tile-columns"
    private static let tileMediaName = "waifux.crop.tile-media"

    private final class StaticContentLayer: CALayer {
        var sourceSize: CGSize = .zero
    }

    @discardableResult
    static func apply(
        rootLayer: CALayer, viewportLayer: CALayer, contentLayers: [CALayer],
        sourceSize: CGSize, settings: ExtCropSettings
    ) -> Bool {
        guard ExtCropEngine.isValidSourceSize(sourceSize),
              ExtDisplayGeometry.isValid(size: rootLayer.bounds.size) else { return false }
        // 关闭自定义裁剪仍要保持图片比例，使用默认 auto-fill 几何。
        let effectiveSettings = settings.shouldApplyCrop ? settings : .default
        let contentsScale = rootLayer.contentsScale.isFinite && rootLayer.contentsScale > 0 ? rootLayer.contentsScale : 1
        let screenSize = CGSize(width: rootLayer.bounds.width * contentsScale, height: rootLayer.bounds.height * contentsScale)
        guard ExtDisplayGeometry.isValid(size: screenSize) else { return false }
        let layout = ExtCropEngine.compute(
            wallpaperSize: sourceSize, screenSize: screenSize, settings: effectiveSettings)
        let geometry = ExtCropGeometry.layerGeometry(
            layout: layout, in: CGRect(origin: .zero, size: rootLayer.bounds.size))
        guard isValidGeometry(geometry) else {
            NSLog("[WaifuX crop] layout rejected: non-finite or non-positive geometry")
            return false
        }
        let viewportFrame = geometry.viewportRect.offsetBy(dx: rootLayer.bounds.minX, dy: rootLayer.bounds.minY)
        let contentFrame = geometry.videoFrame.offsetBy(
            dx: -geometry.viewportRect.minX, dy: -geometry.viewportRect.minY)
        let tilePlan = layout.isTiled ? ExtTilePlan.make(contentFrame: contentFrame, viewportSize: geometry.viewportRect.size) : nil
        if layout.isTiled && tilePlan == nil {
            NSLog("[WaifuX crop] tile layout rejected: exceeds %d copies or invalid geometry", ExtTilePlan.maximumCopies)
            return false
        }
        let fullRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        var changed = viewportLayer.frame != viewportFrame
            || rootLayer.backgroundColor != layout.letterboxColor
            || contentLayers.contains { $0.contentsScale != contentsScale || $0.contentsGravity != .resize }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rootLayer.masksToBounds = true
        rootLayer.contentsGravity = .resize
        rootLayer.contentsRect = fullRect
        rootLayer.contentsCenter = fullRect
        rootLayer.backgroundColor = layout.letterboxColor
        viewportLayer.frame = viewportFrame
        viewportLayer.bounds = CGRect(origin: .zero, size: geometry.viewportRect.size)
        viewportLayer.contentsScale = contentsScale
        viewportLayer.masksToBounds = true
        let mediaParent: CALayer
        let mediaFrame: CGRect
        if let tilePlan {
            let rows = (viewportLayer.sublayers?.first { $0.name == tileWrapperName } as? CAReplicatorLayer) ?? CAReplicatorLayer()
            let columns = (rows.sublayers?.first { $0.name == tileColumnsName } as? CAReplicatorLayer) ?? CAReplicatorLayer()
            let media = columns.sublayers?.first { $0.name == tileMediaName } ?? CALayer()
            changed = changed || rows.superlayer == nil || rows.instanceCount != tilePlan.rows
                || columns.instanceCount != tilePlan.columns || media.frame != tilePlan.frame
            rows.name = tileWrapperName
            columns.name = tileColumnsName
            media.name = tileMediaName
            if rows.superlayer !== viewportLayer { viewportLayer.addSublayer(rows) }
            if columns.superlayer !== rows { rows.addSublayer(columns) }
            if media.superlayer !== columns { columns.addSublayer(media) }
            rows.frame = viewportLayer.bounds
            columns.frame = viewportLayer.bounds
            rows.instanceCount = tilePlan.rows
            columns.instanceCount = tilePlan.columns
            rows.instanceTransform = CATransform3DMakeTranslation(0, contentFrame.height, 0)
            columns.instanceTransform = CATransform3DMakeTranslation(contentFrame.width, 0, 0)
            rows.instanceDelay = 0
            columns.instanceDelay = 0
            rows.contentsScale = contentsScale
            columns.contentsScale = contentsScale
            media.contentsScale = contentsScale
            media.frame = tilePlan.frame
            media.masksToBounds = true
            mediaParent = media
            mediaFrame = CGRect(origin: .zero, size: contentFrame.size)
        } else {
            mediaParent = viewportLayer
            mediaFrame = contentFrame
        }
        for layer in contentLayers {
            changed = changed || layer.superlayer !== mediaParent || layer.frame != mediaFrame
            if layer.superlayer !== mediaParent { mediaParent.addSublayer(layer) }
            layer.frame = mediaFrame
            // The geometry already supplies proportional frames for every mode
            // except stretch; resize also permits stretch to map the full image.
            layer.contentsGravity = .resize
            layer.contentsRect = fullRect
            layer.contentsCenter = fullRect
            layer.contentsScale = contentsScale
        }
        if !layout.isTiled {
            let wrappers = viewportLayer.sublayers?.filter { $0.name == tileWrapperName } ?? []
            changed = changed || !wrappers.isEmpty
            wrappers.forEach { $0.removeFromSuperlayer() }
        }
        CATransaction.commit()
        return changed
    }

    private static func isValidGeometry(_ geometry: ExtLayerCropGeometry) -> Bool {
        [geometry.viewportRect.minX, geometry.viewportRect.minY,
         geometry.viewportRect.width, geometry.viewportRect.height,
         geometry.videoFrame.minX, geometry.videoFrame.minY,
         geometry.videoFrame.width, geometry.videoFrame.height].allSatisfy(\.isFinite)
            && geometry.viewportRect.width > 0 && geometry.viewportRect.height > 0
            && geometry.videoFrame.width > 0 && geometry.videoFrame.height > 0
    }

    static func staticImage(in rootLayer: CALayer) -> CGImage? {
        guard let viewport = staticViewport(in: rootLayer), let content = staticContent(in: viewport) else { return nil }
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
    static func setStaticImage(
        _ image: CGImage, in rootLayer: CALayer, settings: ExtCropSettings, sourceSize: CGSize? = nil
    ) -> Bool {
        let viewport = staticViewport(in: rootLayer) ?? CALayer()
        let content = (staticContent(in: viewport) as? StaticContentLayer) ?? StaticContentLayer()
        let retainedSize = imageContents(in: content) === image ? content.sourceSize : .zero
        let sourceSize = sourceSize ?? (ExtCropEngine.isValidSourceSize(retainedSize) ? retainedSize : CGSize(width: image.width, height: image.height))
        // Validate the complete geometry before replacing either image or hierarchy.
        let scale = rootLayer.contentsScale.isFinite && rootLayer.contentsScale > 0 ? rootLayer.contentsScale : 1
        let effectiveSettings = settings.shouldApplyCrop ? settings : .default
        let layout = ExtCropEngine.compute(
            wallpaperSize: sourceSize,
            screenSize: CGSize(width: rootLayer.bounds.width * scale, height: rootLayer.bounds.height * scale),
            settings: effectiveSettings
        )
        let geometry = ExtCropGeometry.layerGeometry(layout: layout, in: CGRect(origin: .zero, size: rootLayer.bounds.size))
        guard isValidGeometry(geometry) else {
            NSLog("[WaifuX crop] static layout rejected: non-finite or non-positive geometry")
            return false
        }
        if layout.isTiled {
            let frame = geometry.videoFrame.offsetBy(dx: -geometry.viewportRect.minX, dy: -geometry.viewportRect.minY)
            guard ExtTilePlan.make(contentFrame: frame, viewportSize: geometry.viewportRect.size) != nil else {
                NSLog("[WaifuX crop] static tile layout rejected: exceeds %d copies or invalid geometry", ExtTilePlan.maximumCopies)
                return false
            }
        }
        let isNew = viewport.superlayer == nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        viewport.name = staticViewportName
        content.name = staticContentName
        if content.superlayer == nil { viewport.addSublayer(content) }
        if isNew { rootLayer.addSublayer(viewport) }
        let imageChanged = imageContents(in: content) !== image
        content.sourceSize = sourceSize
        content.contents = image
        rootLayer.contents = nil
        let changed = apply(
            rootLayer: rootLayer, viewportLayer: viewport, contentLayers: [content],
            sourceSize: sourceSize, settings: settings)
        CATransaction.commit()
        return isNew || imageChanged || changed
    }

    static func removeStaticImage(from rootLayer: CALayer) {
        staticViewport(in: rootLayer)?.removeFromSuperlayer()
    }

    private static func staticViewport(in rootLayer: CALayer) -> CALayer? {
        rootLayer.sublayers?.first { $0.name == staticViewportName }
    }

    private static func staticContent(in layer: CALayer) -> CALayer? {
        if layer.name == staticContentName { return layer }
        for child in layer.sublayers ?? [] {
            if let content = staticContent(in: child) { return content }
        }
        return nil
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
