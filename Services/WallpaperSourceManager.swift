import Foundation

// MARK: - 壁纸数据源管理器
///
/// 管理 4 个数据源（WallHaven / PixelVault / Konachan / Pixiv）的**手动切换**与状态持久化。
///
/// ⚠️ 自动后备切换已整体移除（2026-11-05 用户决定，不再保留）：
///   - 不再有「启动时 ping Google / VPN 检测后自动切 4K 源」的决策（原 performStartupSourceSelection）。
///   - 不再有运行时健康检查 / 连续失败自动降级 / 回弹（原 shouldUseFallback、
///     performAutoSwitch、recordCurrentSourceFailedAndDowngrade、recordSuccess/recordFailure）。
///   - 数据源完全由用户在设置/探索页手动选择（switchTo），选择持久化到 UserDefaults。
/// 主源 WallHaven 请求失败时直接向用户抛错，不做静默降级。
@MainActor
class WallpaperSourceManager: ObservableObject {
    static let shared = WallpaperSourceManager()

    // MARK: - 数据源类型

    enum SourceType: String, CaseIterable {
        case wallhaven = "wallhaven"
        case fourKWallpapers = "4kwallpapers"
        case konachan = "konachan"
        case pixiv = "pixiv"

        var displayName: String {
            switch self {
            case .wallhaven: return "WallHaven"
            // 原名 "4K Wallpapers" 与媒体页的「4K 画质」筛选撞车，用户以为是同一个东西；
            // 这里改成不带分辨率字样的独立品牌名。
            case .fourKWallpapers: return "PixelVault"
            case .konachan: return "Konachan"
            case .pixiv: return "Pixiv"
            }
        }

        var subtitle: String {
            switch self {
            case .wallhaven: return t("source.official")
            case .fourKWallpapers: return t("source.pixelvault")
            case .konachan: return t("source.konachan")
            case .pixiv: return t("source.pixiv")
            }
        }

        /// 是否支持 NSFW 筛选
        var supportsNSFW: Bool {
            switch self {
            case .wallhaven: return true
            case .fourKWallpapers: return false   // 4KWallpapers 不支持 NSFW
            case .konachan: return true
            case .pixiv: return true              // Pixiv 登录后可用，具体检查在 ViewModel 层
            }
        }

        /// 是否支持 WallHaven 风格的排序（date_added/relevance/toplist/views/favorites/random）
        var supportsWallhavenSorting: Bool {
            switch self {
            case .wallhaven: return true
            case .fourKWallpapers: return false   // 4K 只支持 Recent / Popular
            case .konachan: return false
            case .pixiv: return false             // Pixiv 使用自己的排序
            }
        }

        /// 是否支持比例筛选（16x9, 21x9 等）
        var supportsRatioFilter: Bool {
            switch self {
            case .wallhaven: return true
            case .fourKWallpapers: return false
            case .konachan: return false
            case .pixiv: return false
            }
        }

        /// 是否支持颜色筛选
        var supportsColorFilter: Bool {
            switch self {
            case .wallhaven: return true
            case .fourKWallpapers: return false
            case .konachan: return false
            case .pixiv: return false
            }
        }

        /// 是否使用 WallHaven 风格分类（general/anime/people 三分类）
        var supportsWallhavenCategories: Bool {
            switch self {
            case .wallhaven: return true
            case .fourKWallpapers: return false   // 4K 使用自己的 30 个分类
            case .konachan: return false
            case .pixiv: return false
            }
        }

        /// 是否支持中文（CJK）关键词搜索——不支持时纯中文查询直接提示，不发无效请求
        var supportsChineseSearch: Bool {
            switch self {
            case .wallhaven: return false         // 标签库为英文
            case .fourKWallpapers: return false   // 站点关键词为英文
            case .konachan: return false          // 标签为罗马字/英文
            case .pixiv: return true              // 原生支持中日文搜索
            }
        }

        /// 用于设置页分段控件的颜色标识
        var accentColor: String {
            switch self {
            case .wallhaven: return "blue"
            case .fourKWallpapers: return "orange"
            case .konachan: return "pink"
            case .pixiv: return "cyan"
            }
        }
    }

    // MARK: - Published State

    @Published private(set) var activeSource: SourceType = .wallhaven
    @Published var lastSwitchMessage: String?                  // 最近一次手动切换的消息（用于 Toast 提示）

    // MARK: - Storage Keys

    private let selectedSourceKey = "wallpaper_selected_source"     // 用户手动选择的源

    private init() {
        // ⚠️ 绝对不能在 init() 中读 WaifuXPreferences.shared！
        // macOS 26+ 上会触发 _CFXPreferences 隐式递归导致栈溢出崩溃（EXC_BAD_ACCESS SIGSEGV）
        // 所有状态通过 AppDelegate 调用 restoreState() 延迟恢复
        activeSource = .wallhaven
        lastSwitchMessage = nil
    }

    /// ⚠️ 延迟恢复持久化状态（必须在 AppDelegate.applicationDidFinishLaunching 中调用）
    func restoreState() {
        if let saved = WaifuXPreferences.shared.string(forKey: selectedSourceKey),
           let source = SourceType(rawValue: saved) {
            activeSource = source
        }
    }

    // MARK: - Public API

    /// 当前活跃源是否支持 NSFW
    var currentSourceSupportsNSFW: Bool {
        activeSource.supportsNSFW
    }

    /// 当前活跃源是否支持 WallHaven 排序
    var currentSourceSupportsWallhavenSorting: Bool {
        activeSource.supportsWallhavenSorting
    }

    /// 当前活跃源是否支持比例筛选
    var currentSourceSupportsRatioFilter: Bool {
        activeSource.supportsRatioFilter
    }

    /// 当前活跃源是否支持颜色筛选
    var currentSourceSupportsColorFilter: Bool {
        activeSource.supportsColorFilter
    }

    /// 当前活跃源是否使用 WallHaven 风格分类
    var currentSourceSupportsWallhavenCategories: Bool {
        activeSource.supportsWallhavenCategories
    }

    /// 当前活跃源是否支持分类筛选（任何形式的分类）
    var currentSourceSupportsCategories: Bool {
        switch activeSource {
        case .wallhaven, .fourKWallpapers, .pixiv: return true
        case .konachan: return false
        }
    }

    /// 手动切换数据源（用户从设置/探索页操作）
    /// 这是唯一的数据源切换入口——没有任何自动后备逻辑会覆盖这个选择。
    func switchTo(_ source: SourceType) {
        guard activeSource != source else { return }

        activeSource = source

        // 持久化
        WaifuXPreferences.shared.set(source.rawValue, forKey: selectedSourceKey)

        lastSwitchMessage = "已切换到 \(source.displayName)"

        NotificationCenter.default.post(name: .wallpaperDataSourceChanged, object: nil)

        print("[WallpaperSourceManager] Manual switch to \(source.displayName)")
    }
}
