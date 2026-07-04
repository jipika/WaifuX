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

    var isBuiltInDisplay: Bool {
        guard let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return false
        }
        return CGDisplayIsBuiltin(CGDirectDisplayID(screenNumber.uint32Value)) != 0
    }

    /// 热插拔检测使用的连接指纹。不要包含分辨率/缩放，否则外接屏刚接入时
    /// macOS 的模式协商会把同一块显示器误判成多次新连接。
    var externalConnectionFingerprint: String {
        guard let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return "fallback:\(localizedName)"
        }

        let displayID = CGDirectDisplayID(screenNumber.uint32Value)
        let vendor = CGDisplayVendorNumber(displayID)
        let model = CGDisplayModelNumber(displayID)
        let serial = CGDisplaySerialNumber(displayID)
        let builtin = CGDisplayIsBuiltin(displayID) != 0 ? "builtin" : "external"

        if serial != 0 {
            return "cg:\(vendor):\(model):\(serial):\(builtin)"
        }
        return "cg:\(vendor):\(model):noserial:\(localizedName):\(builtin)"
    }

    /// 调度器配置使用的物理显示器指纹。这里复用连接指纹，避免同一块外接屏
    /// 在缩放/分辨率变化或重插后被当作另一块屏幕。
    var schedulerConfigFingerprint: String {
        externalConnectionFingerprint
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

    /// 当前显示器的主刷新率（Hz），取整。
    ///
    /// 通过 `CGDisplayCopyDisplayMode` 获取当前分辨率模式的刷新率。
    /// ProMotion / 可变刷新率显示器可能返回 0，此时回退到 60。
    var maxRefreshRate: Int {
        guard let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return 60
        }
        let displayID = CGDirectDisplayID(screenNumber.uint32Value)
        guard let mode = CGDisplayCopyDisplayMode(displayID) else {
            return 60
        }
        let rate = mode.refreshRate
        // ProMotion / 可变刷新率可能返回 0
        if rate <= 0 {
            return 60
        }
        return Int(rate.rounded())
    }
}
