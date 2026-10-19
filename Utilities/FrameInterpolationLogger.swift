import Foundation

/// 补帧流程的调试日志。
///
/// 这些消息在每次视频壁纸应用时都会走一遍（实测重复上百次），且属于调试信息：
/// - 控制台 `NSLog` 只在 Debug 构建输出，避免 Release 的 Console 被刷屏；
/// - 文件日志按固定类别 key 节流（5s），保留「发生了什么」但不逐条重复。
func frameInterpolationDebugPrint(_ message: String) {
    #if DEBUG
    NSLog("[VideoWallpaperManager] [FrameInterpolation] \(message)")
    #endif

    let key: String
    if message.hasPrefix("后台读取视频原始 FPS") {
        key = "fi.readSourceFPS"
    } else if message.hasPrefix("FPS 分析完成") {
        key = "fi.analysisFinished"
    } else if message.hasPrefix("视频需要补帧") {
        key = "fi.enqueue"
    } else if message.hasPrefix("已有补帧") {
        key = "fi.skipExisting"
    } else if message.hasPrefix("目标 FPS 无效") {
        key = "fi.invalidTarget"
    } else {
        key = "fi.other"
    }
    AppLogger.throttled(.debug, .wallpaper, key: key, interval: 5, "FrameInterpolation", metadata: [
        "message": message
    ])
}
