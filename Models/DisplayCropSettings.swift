import Foundation
import CoreGraphics

/// 归一化矩形（原点左上，y 向下）。
struct UnitRect: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double

    static let full = UnitRect(x: 0, y: 0, w: 1, h: 1)
}

/// 壁纸在可视区域内的显示方式；仅 cover(fill) 与 contain(fit) 两种，均支持缩放。
/// 旧配置及未知值（含已移除的 stretch/center/tile）回退为填充。
enum WallpaperDisplayMode: String, Codable, CaseIterable, Sendable {
    case fill, fit

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = Self(rawValue: try container.decode(String.self)) ?? .fill
    }

    var supportsAdjustment: Bool { true }
}

/// 比例预设。autoFill 保留旧持久化值，表示跟随屏幕比例。
enum AspectPreset: String, Codable, CaseIterable, Sendable {
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
struct DisplayCropSettings: Codable, Equatable, Sendable {
    var aspectPreset: AspectPreset = .autoFill
    var displayMode: WallpaperDisplayMode = .fill
    /// aspectPreset == .custom 时生效。
    var customAspect: Double? = nil
    /// 平移，(0...1, 0...1)，0.5=居中。= 可视窗口中心在壁纸上的归一化位置
    /// （0=壁纸左/上边，1=右/下边）。哪个方向壁纸比可视框大有富余，那个方向可平移。
    var pan: CGPoint = CGPoint(x: 0.5, y: 0.5)
    /// 基于显示方式的缩放，0.25...4.0；拉伸模式忽略此值。
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

    init() {}

    private enum CodingKeys: String, CodingKey {
        case aspectPreset, displayMode, customAspect, pan, zoom, letterboxColorHex, isEnabled
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        aspectPreset = try values.decodeIfPresent(AspectPreset.self, forKey: .aspectPreset) ?? .autoFill
        displayMode = try values.decodeIfPresent(WallpaperDisplayMode.self, forKey: .displayMode) ?? .fill
        customAspect = try values.decodeIfPresent(Double.self, forKey: .customAspect)
        pan = try values.decodeIfPresent(CGPoint.self, forKey: .pan) ?? CGPoint(x: 0.5, y: 0.5)
        zoom = try values.decodeIfPresent(Double.self, forKey: .zoom) ?? 1
        letterboxColorHex = try values.decodeIfPresent(String.self, forKey: .letterboxColorHex) ?? "000000"
        isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }

    static let defaultSettings = DisplayCropSettings()
}
