import Foundation

func frameInterpolationDebugPrint(_ message: String) {
    NSLog("[VideoWallpaperManager] [FrameInterpolation] \(message)")
    AppLogger.debug(.wallpaper, "FrameInterpolation", metadata: [
        "message": message
    ])
}
