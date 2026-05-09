import AppKit
import CoreGraphics

extension NSScreen {
    /// 返回稳定的屏幕标识符，用于跨模块的屏幕级状态字典 key。
    ///
    /// 优先使用 `NSScreenNumber`（CGDirectDisplayID 的字符串形式），它在同一物理显示器
    /// 的同一端口上具有全局唯一性和稳定性。
    ///
    /// 当 `NSScreenNumber` 不可用时（某些外接显示器、AirPlay 屏幕等），
    /// 回退到 `localizedName + 原点坐标`，比单纯的 localizedName 更能区分
    /// 同型号的多块显示器。
    var wallpaperScreenIdentifier: String {
        if let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return screenNumber.stringValue
        }
        return localizedName + ":\(frame.origin.x):\(frame.origin.y)"
    }

    /// 尽量稳定的物理显示器指纹，用于外接屏断开 / 重连后 `NSScreenNumber` 变化时找回目标屏。
    var wallpaperScreenFingerprint: String {
        guard let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return "fallback:\(localizedName):\(Int(frame.width))x\(Int(frame.height))"
        }

        let displayID = CGDirectDisplayID(screenNumber.uint32Value)
        let vendor = CGDisplayVendorNumber(displayID)
        let model = CGDisplayModelNumber(displayID)
        let serial = CGDisplaySerialNumber(displayID)
        let builtin = CGDisplayIsBuiltin(displayID) != 0 ? "builtin" : "external"
        let pixelWidth = Int(frame.width * backingScaleFactor)
        let pixelHeight = Int(frame.height * backingScaleFactor)

        if serial != 0 {
            return "cg:\(vendor):\(model):\(serial):\(builtin)"
        }
        return "cg:\(vendor):\(model):noserial:\(localizedName):\(pixelWidth)x\(pixelHeight):\(builtin)"
    }
}
