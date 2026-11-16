import CoreGraphics
import Foundation
import QuartzCore

// 屏保端可视区域调节支持。
//
// 与 `WaifuXWallpaperExtension/ExtensionCropSupport.swift` 同构：App 端
// (DisplayCropSettingsStore) 把每屏 crop 写进 App Group JSON
// (waifux-crop-prefs.json, key = "display-<displayID>")，屏保宿主在此读取并计算。
// 屏保不被沙盒约束，直接按路径读容器即可，不需要 entitlement。
//
// 类型字段与 App 端 Models/DisplayCropSettings.swift + Services/CropLayoutEngine.swift 保持一致，
// 因此 JSON 可以直接互通。

/// 归一化矩形（原点左上，y 向下）。
struct SaverUnitRect: Codable, Equatable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double
    static let full = SaverUnitRect(x: 0, y: 0, w: 1, h: 1)
}

enum SaverAspectPreset: String, Codable, CaseIterable {
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

enum SaverDisplayMode: String, Codable, CaseIterable {
    case fill, fit
}

struct SaverCropSettings: Codable, Equatable {
    var displayMode: SaverDisplayMode = .fill
    var aspectPreset: SaverAspectPreset = .autoFill
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
        displayMode = rawMode.flatMap(SaverDisplayMode.init(rawValue:)) ?? .fill
        aspectPreset = try values.decodeIfPresent(SaverAspectPreset.self, forKey: .aspectPreset) ?? .autoFill
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

    static let `default` = SaverCropSettings()
}

struct SaverCropLayout {
    var wallpaperCropRect: SaverUnitRect
    var viewportRect: SaverUnitRect
    var letterboxColor: CGColor
    var isTiled: Bool = false
}

/// CALayer 坐标系中的裁切结果。`mediaFrame` 可以超出 rootLayer.bounds，
/// rootLayer 负责裁掉溢出部分，因此媒体层始终按原始比例渲染。
struct SaverLayerGeometry {
    var viewportRect: CGRect
    var mediaFrame: CGRect
}

enum SaverCropEngine {
    static func isValidSourceSize(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
            && size.width <= 1_000_000 && size.height <= 1_000_000
    }

    static func compute(
        wallpaperSize: CGSize,
        screenSize: CGSize,
        settings: SaverCropSettings
    ) -> SaverCropLayout {
        let settings = settings.isEnabled ? settings : .default
        let letterboxColor = parseColorHex(settings.letterboxColorHex)
        guard wallpaperSize.width.isFinite, wallpaperSize.height.isFinite,
              screenSize.width.isFinite, screenSize.height.isFinite,
              wallpaperSize.width > 0, wallpaperSize.height > 0,
              screenSize.width > 0, screenSize.height > 0 else {
            return SaverCropLayout(wallpaperCropRect: .full, viewportRect: .full, letterboxColor: letterboxColor)
        }
        let screenAspect = screenSize.width / screenSize.height
        let targetAspect = settings.effectiveAspect ?? screenAspect
        let viewport: SaverUnitRect
        if targetAspect > screenAspect {
            let h = screenAspect / targetAspect
            viewport = SaverUnitRect(x: 0, y: (1 - h) / 2, w: 1, h: h)
        } else {
            let w = targetAspect / screenAspect
            viewport = SaverUnitRect(x: (1 - w) / 2, y: 0, w: w, h: 1)
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
        return SaverCropLayout(
            wallpaperCropRect: SaverUnitRect(x: origin(window: winW, pan: panX), y: origin(window: winH, pan: panY), w: winW, h: winH),
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

enum SaverCropGeometry {
    /// 把归一化 crop/viewport 转为 CALayer 几何。
    /// SaverUnitRect 使用左上原点，CALayer 使用左下原点，所以这里翻转 y。
    static func layerGeometry(layout: SaverCropLayout, in bounds: CGRect) -> SaverLayerGeometry {
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
        let mediaWidth = viewportRect.width / cropWidth
        let mediaHeight = viewportRect.height / cropHeight
        let mediaFrame = CGRect(
            x: viewportRect.minX - crop.x * mediaWidth,
            y: viewportRect.minY - (1 - crop.y - crop.h) * mediaHeight,
            width: mediaWidth,
            height: mediaHeight
        )
        return SaverLayerGeometry(viewportRect: viewportRect, mediaFrame: mediaFrame)
    }
}

/// A bounded repeat plan shared by CALayer and CPU snapshots. Its origin is
/// the first tile intersecting the viewport, so no offscreen copies are needed.
struct SaverTilePlan {
    static let maximumCopies = 65_536
    let frame: CGRect
    let columns: Int
    let rows: Int

    static func make(contentFrame: CGRect, viewportSize: CGSize) -> SaverTilePlan? {
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
        return SaverTilePlan(frame: CGRect(origin: CGPoint(x: x, y: y), size: contentFrame.size),
                           columns: Int(columns), rows: Int(rows))
    }
}

/// Applies one shared image/player subtree; replication never creates players.
enum SaverCropLayers {
    private static let tileRowsName = "waifux.saver.tile-rows"
    private static let tileColumnsName = "waifux.saver.tile-columns"
    private static let tileMediaName = "waifux.saver.tile-media"

    @discardableResult
    static func apply(rootLayer: CALayer, viewportLayer: CALayer, mediaLayers: [CALayer], layout: SaverCropLayout) -> Bool {
        let geometry = SaverCropGeometry.layerGeometry(layout: layout, in: CGRect(origin: .zero, size: rootLayer.bounds.size))
        guard [geometry.viewportRect.minX, geometry.viewportRect.minY,
               geometry.viewportRect.width, geometry.viewportRect.height,
               geometry.mediaFrame.minX, geometry.mediaFrame.minY,
               geometry.mediaFrame.width, geometry.mediaFrame.height].allSatisfy(\.isFinite),
              geometry.viewportRect.width > 0, geometry.viewportRect.height > 0,
              geometry.mediaFrame.width > 0, geometry.mediaFrame.height > 0 else {
            NSLog("[WaifuX saver crop] layout rejected: non-finite or non-positive geometry")
            return false
        }
        let contentFrame = geometry.mediaFrame.offsetBy(dx: -geometry.viewportRect.minX, dy: -geometry.viewportRect.minY)
        let tilePlan = layout.isTiled ? SaverTilePlan.make(contentFrame: contentFrame, viewportSize: geometry.viewportRect.size) : nil
        if layout.isTiled && tilePlan == nil {
            NSLog("[WaifuX saver crop] tile layout rejected: exceeds %d copies or invalid geometry", SaverTilePlan.maximumCopies)
            return false
        }
        let contentsScale = rootLayer.contentsScale.isFinite && rootLayer.contentsScale > 0 ? rootLayer.contentsScale : 1
        let fullRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rootLayer.backgroundColor = layout.letterboxColor
        rootLayer.masksToBounds = true
        viewportLayer.frame = geometry.viewportRect.offsetBy(dx: rootLayer.bounds.minX, dy: rootLayer.bounds.minY)
        viewportLayer.bounds = CGRect(origin: .zero, size: geometry.viewportRect.size)
        viewportLayer.masksToBounds = true
        viewportLayer.mask = nil
        viewportLayer.contentsScale = contentsScale
        let mediaParent: CALayer
        let mediaFrame: CGRect
        if let tilePlan {
            let rows = (viewportLayer.sublayers?.first { $0.name == tileRowsName } as? CAReplicatorLayer) ?? CAReplicatorLayer()
            let columns = (rows.sublayers?.first { $0.name == tileColumnsName } as? CAReplicatorLayer) ?? CAReplicatorLayer()
            let media = columns.sublayers?.first { $0.name == tileMediaName } ?? CALayer()
            rows.name = tileRowsName
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
        for layer in mediaLayers {
            if layer.superlayer !== mediaParent { mediaParent.addSublayer(layer) }
            layer.frame = mediaFrame
            layer.contentsGravity = .resize
            layer.contentsRect = fullRect
            layer.contentsCenter = fullRect
            layer.contentsScale = contentsScale
        }
        if !layout.isTiled { removeTileWrappers(from: viewportLayer) }
        CATransaction.commit()
        return true
    }

    static func removeTileWrappers(from viewportLayer: CALayer) {
        (viewportLayer.sublayers?.filter { $0.name == tileRowsName } ?? []).forEach { $0.removeFromSuperlayer() }
    }
}

/// 屏保端读取 App Group 里的实时 crop 配置。
/// 屏保进程没有沙盒，`containerURL(forSecurityApplicationGroupIdentifier:)` 拿不到容器，
/// 因此直接按 Group Containers 路径读取；文件不存在时返回 nil，由调用方回退到配置快照。
enum SaverSharedCropPrefs {
    private static let appGroupID = "group.com.waifux.app"
    private static let jsonName = "waifux-crop-prefs.json"

    static func settings(forDisplayKey key: String) -> SaverCropSettings? {
        guard let url = containerURL()?.appendingPathComponent(jsonName),
              let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: SaverCropSettings].self, from: data) else {
            return nil
        }
        return dict[key]
    }

    static func containerURL() -> URL? {
        let home = SaverHomeDirectory.url
        let url = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Group Containers", isDirectory: true)
            .appendingPathComponent(appGroupID, isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
}

/// 屏保宿主可能在没有 App 环境的情况下启动，这里统一解析真实用户主目录。
enum SaverHomeDirectory {
    static var url: URL {
        if let record = getpwuid(getuid()), let path = String(validatingUTF8: record.pointee.pw_dir) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}

/// 屏幕号 → crop 配置键。与 App 端 `NSScreen.wallpaperScreenIdentifier` 同源，
/// 都是 CGDirectDisplayID 的十进制字符串。
func saverDisplayKey(_ displayID: UInt32) -> String {
    "display-\(displayID)"
}
