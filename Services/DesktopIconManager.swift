import AppKit

// MARK: - 桌面图标显示/隐藏管理器

/// 通过修改 Finder 偏好设置控制桌面图标的显示与隐藏。
///
/// 原理：
/// - 写入 `com.apple.finder` 的 `CreateDesktop` 键（`false` = 隐藏，`true` = 显示）
/// - 重启 Finder 使更改生效（`killall Finder`）
///
/// ⚠️ 注意：重启 Finder 会短暂刷新桌面，所有 Finder 窗口也会被重新打开。
@MainActor
final class DesktopIconManager {
    static let shared = DesktopIconManager()

    /// 当前桌面图标是否处于隐藏状态
    private(set) var areDesktopIconsHidden: Bool = false

    private let finderDomain = "com.apple.finder"
    private let createDesktopKey = "CreateDesktop"

    private init() {
        // 读取当前状态
        areDesktopIconsHidden = readCurrentState()
    }

    /// 切换桌面图标显示/隐藏
    func toggle() {
        setDesktopIconsHidden(!areDesktopIconsHidden)
    }

    /// 设置桌面图标隐藏或显示
    /// - Parameter hidden: `true` 隐藏桌面图标，`false` 显示桌面图标
    func setDesktopIconsHidden(_ hidden: Bool) {
        let value = hidden ? "false" : "true"

        // 1. 写入 Finder 偏好设置
        let setTask = Process()
        setTask.launchPath = "/usr/bin/defaults"
        setTask.arguments = ["write", finderDomain, createDesktopKey, "-bool", value]

        let setPipe = Pipe()
        setTask.standardOutput = setPipe
        setTask.standardError = setPipe

        setTask.launch()
        setTask.waitUntilExit()

        guard setTask.terminationStatus == 0 else {
            let errorData = setPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMsg = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            print("[DesktopIconManager] Failed to write defaults: \(errorMsg)")
            return
        }

        // 2. 重启 Finder 使更改生效
        let killTask = Process()
        killTask.launchPath = "/usr/bin/killall"
        killTask.arguments = ["Finder"]

        let killPipe = Pipe()
        killTask.standardOutput = killPipe
        killTask.standardError = killPipe

        killTask.launch()
        killTask.waitUntilExit()

        if killTask.terminationStatus != 0 {
            let errorData = killPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMsg = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            print("[DesktopIconManager] Failed to restart Finder: \(errorMsg)")
            // 即使 killall 失败，偏好设置也已写入，用户下次手动重启 Finder 会生效
        }

        // 3. 更新状态
        areDesktopIconsHidden = hidden
        print("[DesktopIconManager] Desktop icons \(hidden ? "hidden" : "visible")")
    }

    // MARK: - Private

    /// 读取当前 `CreateDesktop` 偏好值
    private func readCurrentState() -> Bool {
        guard let value = CFPreferencesCopyAppValue(createDesktopKey as CFString, finderDomain as CFString) else {
            // 如果键不存在，默认桌面图标是显示的
            return false
        }

        if let boolValue = value as? Bool {
            return !boolValue
        }

        if let numberValue = value as? NSNumber {
            return !numberValue.boolValue
        }

        if let stringValue = value as? String {
            return stringValue == "0" || stringValue.lowercased() == "false"
        }

        return false
    }
}
