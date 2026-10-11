import Foundation

/// 功能模块启动快照。
///
/// 在 `applicationDidFinishLaunching` 构建 ContentView 之前，从 UserDefaults 同步读取一次
/// 壁纸/媒体/动漫三个模块开关，并定值到本单例。整个运行会话内，所有门控（tab 显隐、
/// 管线加载、首页内容过滤）都读这个快照——运行时切换设置开关不会立即生效，必须重启。
///
/// 这样做的原因：管线是懒加载的（壁纸/媒体在 ContentView.task、动漫在 AnimeExploreView
/// .onAppear），热切换开关会导致 tab 树重建 / 管线半加载等复杂状态机；快照让"重启生效"
/// 成为唯一生效路径，实现极简且无歧义。
///
/// ⚠️ 不读 SettingsViewModel：settingsViewModel 在 restoreAllDataAsync 深层 asyncAfter 链
/// （~+0.3s）才创建，而 ContentView 在 didFinishLaunching 同步创建并立即布局，此时
/// settingsViewModel 尚不存在。直接读 UserDefaults 是安全的（非 @AppStorage、非 init 读取）。
@MainActor
final class ModuleAvailability {
    static let shared = ModuleAvailability()

    /// 启动时定值，整个会话不变。运行时门控只读这三个值。
    private(set) var wallpaperEnabled: Bool = true
    private(set) var mediaEnabled: Bool = true
    private(set) var animeEnabled: Bool = true

    private init() {}

    /// 仅在 `applicationDidFinishLaunching` 创建 ContentView 之前调用一次。
    /// 直接读 UserDefaults（同步、安全），不依赖 SettingsViewModel。
    func refreshFromUserDefaults() {
        let defaults = WaifuXPreferences.shared
        wallpaperEnabled = defaults.object(forKey: "module_wallpaper_enabled") as? Bool ?? true
        mediaEnabled = defaults.object(forKey: "module_media_enabled") as? Bool ?? true
        animeEnabled = defaults.object(forKey: "module_anime_enabled") as? Bool ?? true
    }

    /// 判断某个 MainTab 是否在当前会话启用。home/myMedia 永远启用。
    func isTabEnabled(_ tab: MainTab) -> Bool {
        switch tab {
        case .home, .myMedia: return true
        case .wallpaperExplore: return wallpaperEnabled
        case .mediaExplore: return mediaEnabled
        case .animeExplore: return animeEnabled
        }
    }
}
