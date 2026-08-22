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
}

enum CropLayoutEngine {
    /// 输入壁纸原始像素尺寸、屏幕像素尺寸、crop 设置，输出归一化裁切框 + 可视框 + 黑边色。
    /// 纯函数，无副作用，可单测。
    static func compute(
        wallpaperSize: CGSize,
        screenSize: CGSize,
        settings: DisplayCropSettings
    ) -> CropLayout {
        let letterboxColor = Self.parseColorHex(settings.letterboxColorHex)

        // 关闭时回退现状（全屏 + 全图）。
        guard settings.shouldApplyCrop else {
            return CropLayout(
                wallpaperCropRect: .full,
                viewportRect: .full,
                letterboxColor: letterboxColor
            )
        }

        let screenAspect = (screenSize.height > 0)
            ? screenSize.width / screenSize.height
            : 1.0
        // Auto Fill 没有独立目标比例，目标就是当前屏幕比例。
        // 这样 viewport 仍然是全屏，但 cover 的真实壁纸裁切框
        // 会保留下来，pan/zoom 才能作用于超出屏幕的内容。
        let targetAspect = settings.effectiveAspect ?? screenAspect

        // 1. 算可视框 viewportRect（屏幕内居中放该比例的最大框）。
        let viewport: UnitRect
        if targetAspect > screenAspect {
            // 框更宽：框宽=1，框高=screenAspect/targetAspect，y 居中
            let h = screenAspect / targetAspect
            viewport = UnitRect(x: 0, y: (1 - h) / 2, w: 1, h: h)
        } else {
            // 框更窄/等：框高=1，框宽=targetAspect/screenAspect，x 居中
            let w = targetAspect / screenAspect
            viewport = UnitRect(x: (1 - w) / 2, y: 0, w: w, h: 1)
        }

        // 2. 算壁纸裁切框 wallpaperCropRect（cover 语义：壁纸铺满可视框，裁掉溢出部分）。
        // 纯 cover 几何：壁纸按 max(可视框/壁纸 缩放比) 放大覆盖可视框，较短轴铺满、较长轴裁切。
        // zoom > 1 进一步放大（窗口缩小），露出更多平移空间。
        // pan ∈ [0,1]，0.5=居中，= 可视窗口中心在壁纸上的归一化位置（0=壁纸左/上边，1=右/下边）。
        // 哪个方向壁纸比可视框大有富余，那个方向可平移。
        let vpW_px = viewport.w * screenSize.width
        let vpH_px = viewport.h * screenSize.height
        let wpW = wallpaperSize.width
        let wpH = wallpaperSize.height
        let coverScale = max(vpW_px / wpW, vpH_px / wpH)
        let zoom = max(1.0, min(4.0, settings.zoom))
        let scale = coverScale * zoom
        let dispW = wpW * scale
        let dispH = wpH * scale
        // crop 窗口（壁纸归一化空间）= 可视框像素 / 显示壁纸像素
        let winW = (dispW > 0) ? vpW_px / dispW : 1.0
        let winH = (dispH > 0) ? vpH_px / dispH : 1.0
        let panX = max(0, min(1, settings.pan.x))
        let panY = max(0, min(1, settings.pan.y))
        // origin = 中心 - 半窗；clamp 到 [0, 1-win] 保证窗口始终在壁纸内
        let originX = max(0, min(1 - winW, panX - winW / 2))
        let originY = max(0, min(1 - winH, panY - winH / 2))

        return CropLayout(
            wallpaperCropRect: UnitRect(x: originX, y: originY, w: winW, h: winH),
            viewportRect: viewport,
            letterboxColor: letterboxColor
        )
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
