import AppKit

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
}
