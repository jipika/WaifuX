import Foundation
import CoreGraphics

/// 归一化矩形（原点左上，y 向下）。
struct UnitRect: Codable, Equatable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double

    static let full = UnitRect(x: 0, y: 0, w: 1, h: 1)
}

/// 比例预设。autoFill = 等价现状 aspect-fill（无黑边、无裁切）。
enum AspectPreset: String, Codable, CaseIterable {
    case autoFill
    case ratio16x9
    case ratio16x10
    case ratio21x9
    case ratio32x9
    case ratio4x3
    case ratio1x1
    case custom

    /// 目标宽高比；autoFill/custom 返回 nil。
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

    /// 菜单显示名（非 autoFill/custom 的字面量）。
    func displayName() -> String {
        switch self {
        case .ratio16x9:  return "16:9"
        case .ratio16x10: return "16:10"
        case .ratio21x9:  return "21:9"
        case .ratio32x9:  return "32:9"
        case .ratio4x3:   return "4:3"
        case .ratio1x1:   return "1:1"
        default:          return ""
        }
    }
}

/// 单屏可视区域调节配置。存归一化值（非像素），换屏/改分辨率自动正确。
struct DisplayCropSettings: Codable, Equatable {
    var aspectPreset: AspectPreset = .autoFill
    /// aspectPreset == .custom 时生效。
    var customAspect: Double? = nil
    /// 平移，(0...1, 0...1)，0.5=居中。= 可视窗口中心在壁纸上的归一化位置
    /// （0=壁纸左/上边，1=右/下边）。哪个方向壁纸比可视框大有富余，那个方向可平移。
    var pan: CGPoint = CGPoint(x: 0.5, y: 0.5)
    /// 缩放，1.0...4.0。1.0=壁纸刚好铺满可视框；>1.0=放大裁切。
    var zoom: Double = 1.0
    /// 框外填充色，默认黑。
    var letterboxColorHex: String = "000000"
    /// 总开关。false=回退现状 aspect-fill，零行为变化。
    var isEnabled: Bool = true

    /// 实际生效的目标比例：custom 用 customAspect，autoFill 使用屏幕比例。
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

    /// 是否应走 crop 通路。Auto Fill 也必须进入 crop 管线，
    /// 否则 pan/zoom 只会保存而不会应用。
    var shouldApplyCrop: Bool {
        isEnabled
    }

    static let defaultSettings = DisplayCropSettings()
}
