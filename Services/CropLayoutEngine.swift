import Foundation
import CoreGraphics

/// crop 计算结果（全部归一化，原点左上，y 向下）。
struct CropLayout {
    /// 壁纸裁切框：把壁纸的 [origin, origin+size] 这段映射到可视框。
    var wallpaperCropRect: UnitRect
    /// 可视框在屏幕上的矩形（框外即 letterbox）。
    var viewportRect: UnitRect
    /// 框外填充色。
    var letterboxColor: CGColor
    /// 将同一份媒体画面周期重复；crop 仍表示 viewport 到源 UV 的映射。
    var isTiled: Bool = false
}

enum CropLayoutEngine {
    /// 输入壁纸原始像素尺寸、屏幕像素尺寸、crop 设置，输出归一化裁切框 + 可视框 + 黑边色。
    /// 纯函数，无副作用，可单测。
    static func compute(
        wallpaperSize: CGSize,
        screenSize: CGSize,
        settings: DisplayCropSettings
    ) -> CropLayout {
        // All sizes use physical pixels. Layer consumers convert the normalized result
        // to their local point bounds only after this calculation.
        let settings = settings.shouldApplyCrop ? settings : .defaultSettings
        let letterboxColor = Self.parseColorHex(settings.letterboxColorHex)
        guard wallpaperSize.width.isFinite, wallpaperSize.height.isFinite,
              screenSize.width.isFinite, screenSize.height.isFinite,
              wallpaperSize.width > 0, wallpaperSize.height > 0,
              screenSize.width > 0, screenSize.height > 0 else {
            return CropLayout(wallpaperCropRect: .full, viewportRect: .full,
                              letterboxColor: letterboxColor)
        }
        let screenAspect = screenSize.width / screenSize.height
        let targetAspect = settings.effectiveAspect ?? screenAspect
        let viewport: UnitRect
        if targetAspect > screenAspect {
            let h = screenAspect / targetAspect
            viewport = UnitRect(x: 0, y: (1 - h) / 2, w: 1, h: h)
        } else {
            let w = targetAspect / screenAspect
            viewport = UnitRect(x: (1 - w) / 2, y: 0, w: w, h: 1)
        }
        let vpW = viewport.w * screenSize.width
        let vpH = viewport.h * screenSize.height
        let zoom = settings.zoom.isFinite ? max(0.25, min(4, settings.zoom)) : 1
        let baseScale: Double
        switch settings.displayMode {
        case .fill: baseScale = max(vpW / wallpaperSize.width, vpH / wallpaperSize.height)
        case .fit: baseScale = min(vpW / wallpaperSize.width, vpH / wallpaperSize.height)
        }
        let winW = vpW / (wallpaperSize.width * baseScale * zoom)
        let winH = vpH / (wallpaperSize.height * baseScale * zoom)
        func origin(_ window: Double, _ pan: Double) -> Double {
            let pan = pan.isFinite ? max(0, min(1, pan)) : 0.5
            if window > 1 { return (1 - window) * pan }
            return max(0, min(1 - window, pan - window / 2))
        }
        return CropLayout(
            wallpaperCropRect: UnitRect(x: origin(winW, settings.pan.x),
                                       y: origin(winH, settings.pan.y), w: winW, h: winH),
            viewportRect: viewport, letterboxColor: letterboxColor, isTiled: false)
    }

    /// 解析 #RRGGBB / RRGGBB → CGColor（alpha=1）。
    static func parseColorHex(_ hex: String) -> CGColor {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else {
            return CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        }
        let r = CGFloat((v >> 16) & 0xFF) / 255.0
        let g = CGFloat((v >> 8) & 0xFF) / 255.0
        let b = CGFloat(v & 0xFF) / 255.0
        return CGColor(red: r, green: g, blue: b, alpha: 1)
    }
}
