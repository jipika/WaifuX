import AppKit

/// 应用重启执行器。
///
/// 用 `open -n <bundleURL>` 启动新实例（-n 强制新实例，避免激活已运行实例导致重启失败），
/// 随后延迟 0.1s 调用 `NSApp.terminate(nil)`，保证 open 命令已发出。
/// 模式参考 `SettingsViewModel.resetAllData()`（ViewModels/SettingsViewModel.swift:479-481）。
@MainActor
enum AppRelauncher {
    static func relaunch() {
        let bundleURL = Bundle.main.bundleURL
        AppDelegate.shared?.markIntentionalTermination(reason: "relaunch")
        AppExitDiagnostics.record("relaunchRequested", metadata: [
            "bundle": bundleURL.path
        ])

        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-n", bundleURL.path]
        try? task.run()
        // 稍延迟 terminate，保证 open 已发出
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            AppDelegate.shared?.markIntentionalTermination(reason: "relaunchTerminate")
            AppExitDiagnostics.record("relaunchTerminate")
            NSApp.terminate(nil)
        }
    }
}
