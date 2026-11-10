import Foundation

/// WE 壁纸引擎按架构分发后的能力探测 API。
///
/// 自 38.0.154 起发布包拆分为 `WaifuX-arm64.dmg` / `WaifuX-x86_64.dmg` 两个单架构包，
/// 每个包携带自己架构的完整依赖：
/// - `wallpaper-wgpu`（Metal/wgpu 渲染器，静态链接 ffmpeg）
/// - `dxc` + `lib/libdxcompiler.dylib`（HLSL → Metal 着色器编译）
/// - `wallpaperengine-cli`（Web 壁纸 daemon）
/// - 扩展 / 屏保保持 universal，两个包共用
///
/// 已知差异：x86_64 包暂不含独立的 `ffmpeg` 二进制（仅影响 web 壁纸离线烘焙），
/// 实时 web/场景渲染与场景壁纸不受影响。
enum WallpaperEngineAvailability {
    /// 当前包是否内置 scene 渲染器（wallpaper-wgpu）。
    /// 两个架构包都携带自己的渲染器；缺文件时由
    /// `WallpaperEngineXBridge.resolvedCLIExecutableURL()` 兜底报错。
    static var sceneRenderingSupported: Bool {
        true
    }

    /// 当前机器架构名（与发布包命名后缀一致）。
    static var currentArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    /// scene 渲染不可用时的用户可读原因（正常分发下不会触发，保留给缺组件的异常安装）。
    static var sceneUnsupportedReason: String {
        LocalizationService.shared.t("当前安装包缺少场景壁纸渲染器组件，请重新下载对应架构的安装包。")
    }
}
