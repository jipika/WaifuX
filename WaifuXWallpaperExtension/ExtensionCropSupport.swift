import Foundation
import CoreGraphics

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
/// `videoFrame` 可以超出 rootLayer.bounds，rootLayer 负责裁掉溢出部分；
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
