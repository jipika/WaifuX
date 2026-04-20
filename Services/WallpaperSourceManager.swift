import Foundation
import Darwin

// MARK: - 壁纸源管理器
///
/// 管理两个壁纸数据源之间的切换逻辑：
///   1. WallHaven（主源）→ 4KWallpapers（回退源）
///   2. 健康检测：请求前 ping Wallhaven，失败则自动切换
///   3. 手动切换：用户可在设置中手动选择数据源
///   4. 状态持久化：记录用户选择和自动切换状态
///   5. 回弹机制：Wallhaven 恢复后可切回（可选）
@MainActor
class WallpaperSourceManager: ObservableObject {
    static let shared = WallpaperSourceManager()

    // MARK: - 数据源类型

    enum SourceType: String, CaseIterable {
        case wallhaven = "wallhaven"
        case fourKWallpapers = "4kwallpapers"

        var displayName: String {
            switch self {
            case .wallhaven: return "WallHaven"
            case .fourKWallpapers: return "4K Wallpapers"
            }
        }

        var subtitle: String {
            switch self {
            case .wallhaven: return t("source.official")
            case .fourKWallpapers: return t("source.fallback")
            }
        }

        /// 降级顺序中的下一个源
        var fallbackSource: SourceType {
            switch self {
            case .wallhaven: return .fourKWallpapers
            case .fourKWallpapers: return .fourKWallpapers  // 已是最后一级
            }
        }

        /// 是否支持 NSFW 筛选
        var supportsNSFW: Bool {
            switch self {
            case .wallhaven: return true
            case .fourKWallpapers: return false   // 4KWallpapers 不支持 NSFW
            }
        }

        /// 是否支持 WallHaven 风格的排序（date_added/relevance/toplist/views/favorites/random）
        var supportsWallhavenSorting: Bool {
            switch self {
            case .wallhaven: return true
            case .fourKWallpapers: return false   // 4K 只支持 Recent / Popular
            }
        }

        /// 是否支持比例筛选（16x9, 21x9 等）
        var supportsRatioFilter: Bool {
            switch self {
            case .wallhaven: return true
            case .fourKWallpapers: return false
            }
        }

        /// 是否支持颜色筛选
        var supportsColorFilter: Bool {
            switch self {
            case .wallhaven: return true
            case .fourKWallpapers: return false
            }
        }

        /// 是否使用 WallHaven 风格分类（general/anime/people 三分类）
        var supportsWallhavenCategories: Bool {
            switch self {
            case .wallhaven: return true
            case .fourKWallpapers: return false   // 4K 使用自己的 30 个分类
            }
        }

        /// 用于设置页分段控件的颜色标识
        var accentColor: String {
            switch self {
            case .wallhaven: return "blue"
            case .fourKWallpapers: return "orange"
            }
        }
    }

    // MARK: - Published State

    @Published private(set) var activeSource: SourceType
    @Published private(set) var isAutoSwitched: Bool = false       // 是否因网络问题自动切换过
    @Published var lastSwitchMessage: String?                  // 最近一次切换的消息（用于 Toast 提示）
    @Published private(set) var isCheckingHealth: Bool = false
    /// 启动时数据源选择是否已完成（ping Google 决策完成）
    @Published private(set) var isInitialSourceSelectionComplete: Bool = false

    // MARK: - Storage Keys

    private let selectedSourceKey = "wallpaper_selected_source"     // 用户手动选择的源
    private let autoSwitchedKey = "wallpaper_auto_switched"       // 是否自动切换过
    private let lastHealthCheckKey = "wallpaper_last_health_ok"    // 上次健康检查成功的时间戳

    // MARK: - Health Check 配置

    /// 连续多少次失败后触发自动降级
    /// ⚠️ 设为 Int.max 禁用运行时的自动降级，只在应用启动时的健康检查中决定是否切换
    private let failureThreshold = Int.max
    /// 连续成功多少次后认为已恢复（用于提示用户可切回）
    private let recoveryThreshold = 3
    /// 健康检查超时时间（秒）
    private let healthCheckTimeout: TimeInterval = 8
    /// 最小健康检查间隔（秒），避免频繁检测
    private let minHealthCheckInterval: TimeInterval = 30

    // MARK: - Internal State

    private var consecutiveFailures: Int = 0
    private var consecutiveSuccesses: Int = 0
    private var lastHealthCheckTime: Date?
    private var forceSourceOverride: SourceType?  // 用户强制指定的源（忽略自动切换）
    private var hasShownAutoSwitchToast: Bool = false  // 是否已显示过自动降级提示（只提示一次）

    private init() {
        // ⚠️ 绝对不能在 init() 中读 UserDefaults.standard！
        // macOS 26+ 上会触发 _CFXPreferences 隐式递归导致栈溢出崩溃（EXC_BAD_ACCESS SIGSEGV）
        // 所有状态通过 AppDelegate 调用 restoreState() 延迟恢复
        activeSource = .wallhaven
        isAutoSwitched = false
        lastHealthCheckTime = nil
    }

    /// ⚠️ 延迟恢复持久化状态（必须在 AppDelegate.applicationDidFinishLaunching 中调用）
    func restoreState() {
        if let saved = UserDefaults.standard.string(forKey: selectedSourceKey),
           let source = SourceType(rawValue: saved) {
            activeSource = source
        }
        isAutoSwitched = UserDefaults.standard.bool(forKey: autoSwitchedKey)
        let timestamp = UserDefaults.standard.double(forKey: lastHealthCheckKey)
        if timestamp > 0 {
            lastHealthCheckTime = Date(timeIntervalSince1970: timestamp)
        }
    }

    // MARK: - Public API

    /// 当前是否使用备用源（非主源）
    var isUsingFallbackSource: Bool {
        activeSource != .wallhaven
    }

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

    /// 获取当前活跃的数据源类型
    func currentSource() -> SourceType {
        if let override = forceSourceOverride {
            return override
        }
        return activeSource
    }

    /// 手动切换数据源（用户从设置页操作）
    func switchTo(_ source: SourceType) {
        guard activeSource != source else { return }

        activeSource = source
        forceSourceOverride = source  // 标记为用户手动指定，阻止自动切换覆盖
        isAutoSwitched = false
        consecutiveFailures = 0
        consecutiveSuccesses = 0
        hasShownAutoSwitchToast = false  // 重置，允许下次自动降级时再次提示

        // 持久化
        UserDefaults.standard.set(source.rawValue, forKey: selectedSourceKey)
        UserDefaults.standard.set(false, forKey: autoSwitchedKey)

        lastSwitchMessage = "已切换到 \(source.displayName) \(source.subtitle)"

        NotificationCenter.default.post(name: .wallpaperDataSourceChanged, object: nil)

        print("[WallpaperSourceManager] Manual switch to \(source.displayName)")
    }

    /// 恢复自动模式（取消手动锁定，允许自动切换）
    func enableAutoMode() {
        forceSourceOverride = nil
        print("[WallpaperSourceManager] Auto mode enabled")
    }

    /// 在发起请求前调用：检查是否需要用回退源
    /// - Returns: 当前应该使用的回退源（nil 表示使用主源 WallHaven）
    func shouldUseFallback() -> SourceType? {
        // 用户手动指定了源时，不自动切换
        if let override = forceSourceOverride {
            return override == .wallhaven ? nil : override
        }

        // 已经在用备用源了，继续用
        // ⚠️ 不再在每次请求时检查主源是否恢复，只在应用启动时初始化检测
        if activeSource != .wallhaven {
            return activeSource
        }

        // 检查是否需要自动切换
        if shouldAutoSwitchToFallback() {
            performAutoSwitch()
            return activeSource
        }

        return nil
    }

    /// 记录一次请求成功（⚠️ 当前仅在应用启动检测中使用，运行时不再调用）
    func recordSuccess() {
        if activeSource == .wallhaven {
            consecutiveSuccesses += 1
            consecutiveFailures = 0
        }
    }

    /// 记录一次请求失败（⚠️ 当前仅在应用启动检测中使用，运行时不再调用）
    /// - Parameter nextSourceAfterFailure: 当前源失败后建议降级到的源
    func recordFailure(error: Error?) {
        if forceSourceOverride == nil {
            consecutiveFailures += 1
            consecutiveSuccesses = 0
            print("[WallpaperSourceManager] Failure count: \(consecutiveFailures)/\(failureThreshold) (source: \(activeSource.displayName))")

            if consecutiveFailures >= failureThreshold {
                performAutoSwitch()
            }
        }
    }

    /// 记录当前源失败并尝试降级到下一个源
    /// - Returns: 降级后的源，如果已是最后一级则返回 nil
    func recordCurrentSourceFailedAndDowngrade() -> SourceType? {
        let nextSource = activeSource.fallbackSource
        if nextSource != activeSource {
            // 还可以降级
            let previousSource = activeSource
            activeSource = nextSource
            isAutoSwitched = true
            consecutiveFailures = 0
            consecutiveSuccesses = 0

            UserDefaults.standard.set(nextSource.rawValue, forKey: selectedSourceKey)
            UserDefaults.standard.set(true, forKey: autoSwitchedKey)

            // 只在首次自动降级时提示，后续不再重复
            if !hasShownAutoSwitchToast {
                lastSwitchMessage = "⚠️ \(previousSource.displayName) 不可用，已降级到 \(nextSource.displayName)"
                hasShownAutoSwitchToast = true
            }

            print("[WallpaperSourceManager] Downgraded from \(previousSource.displayName) to \(nextSource.displayName)")

            NotificationCenter.default.post(name: .wallpaperDataSourceChanged, object: nil)

            return nextSource
        } else {
            // 已是最后一级，不再提示"所有源不可用"
            print("[WallpaperSourceManager] All sources failed (silent)")
            return nil
        }
    }

    // MARK: - Private: Health Check

    private func shouldAutoSwitchToFallback() -> Bool {
        // 已经在用备用源了
        guard activeSource == .wallhaven else { return false }
        // 用户手动锁定了 Wallhaven
        guard forceSourceOverride == nil else { return false }
        // 还没达到阈值
        guard consecutiveFailures >= failureThreshold else { return false }

        return true
    }

    func performAutoSwitch() {
        let nextSource = activeSource.fallbackSource
        guard nextSource != activeSource else { return }

        let previousSource = activeSource
        activeSource = nextSource
        isAutoSwitched = true
        consecutiveFailures = 0
        consecutiveSuccesses = 0

        // 持久化
        UserDefaults.standard.set(nextSource.rawValue, forKey: selectedSourceKey)
        UserDefaults.standard.set(true, forKey: autoSwitchedKey)

        // 只在首次自动降级时提示，后续不再重复
        if !hasShownAutoSwitchToast {
            lastSwitchMessage = "⚠️ \(previousSource.displayName) 无法连接，已自动切换到 \(nextSource.displayName) 备用源"
            hasShownAutoSwitchToast = true
        }

        print("[WallpaperSourceManager] Auto-switched to \(nextSource.displayName) due to failures")

        // ⚠️ 关键：通知 UI 层数据源已变更，触发 HomeContentView / ExploreView 重新请求数据
        NotificationCenter.default.post(name: .wallpaperDataSourceChanged, object: nil)
    }

    /// 启动时选择数据源
    /// - 如果启用了 VPN：保持 Wallhaven
    /// - 如果未启用 VPN：ping Google 检测网络状态
    ///   - Google 可达：保持 Wallhaven
    ///   - Google 不可达：切换到 4K 源，并启用 GitHub Hosts 加速
    func performStartupSourceSelection() async {
        print("[WallpaperSourceManager] Performing startup source selection...")

        // 如果用户手动锁定了源，不要自动切换
        guard forceSourceOverride == nil else {
            print("[WallpaperSourceManager] Startup: user locked to \(forceSourceOverride!.displayName), skip")
            let vpnEnabled = isVPNEnabled()
            await MainActor.run {
                if vpnEnabled {
                    GitHubHosts.isEnabled = false
                }
                isInitialSourceSelectionComplete = true
            }
            return
        }

        // 首先检测 VPN
        let vpnEnabled = isVPNEnabled()
        print("[WallpaperSourceManager] VPN detected: \(vpnEnabled)")

        if vpnEnabled {
            // 启用了 VPN，保持 Wallhaven
            print("[WallpaperSourceManager] VPN is enabled, keeping Wallhaven")
            await MainActor.run {
                // GitHub Hosts 会把请求改成直连固定 IP，容易绕过系统 VPN（尤其分流）；走 VPN 时关闭
                GitHubHosts.isEnabled = false
                if activeSource != .wallhaven {
                    activeSource = .wallhaven
                    isAutoSwitched = false
                    consecutiveFailures = 0
                    consecutiveSuccesses = 0
                    UserDefaults.standard.set(SourceType.wallhaven.rawValue, forKey: selectedSourceKey)
                    UserDefaults.standard.set(false, forKey: autoSwitchedKey)
                }
                isInitialSourceSelectionComplete = true
            }
        } else {
            // 未启用 VPN，ping Google 检测
            let googleReachable = await pingGoogle(timeout: 5)

            if googleReachable {
                // Google 可达，保持 Wallhaven
                print("[WallpaperSourceManager] Google is reachable, keeping Wallhaven")
                await MainActor.run {
                    if activeSource != .wallhaven {
                        activeSource = .wallhaven
                        isAutoSwitched = false
                        consecutiveFailures = 0
                        consecutiveSuccesses = 0
                        UserDefaults.standard.set(SourceType.wallhaven.rawValue, forKey: selectedSourceKey)
                        UserDefaults.standard.set(false, forKey: autoSwitchedKey)
                    }
                    isInitialSourceSelectionComplete = true
                }
            } else {
                // Google 不可达，切换到 4K 源并启用 GitHub Hosts
                print("[WallpaperSourceManager] Google is NOT reachable, switching to 4K and enabling GitHub Hosts")
                await MainActor.run {
                    activeSource = .fourKWallpapers
                    isAutoSwitched = true
                    consecutiveFailures = 0
                    consecutiveSuccesses = 0
                    UserDefaults.standard.set(SourceType.fourKWallpapers.rawValue, forKey: selectedSourceKey)
                    UserDefaults.standard.set(true, forKey: autoSwitchedKey)

                    // 启用 GitHub Hosts 加速
                    GitHubHosts.isEnabled = true

                    isInitialSourceSelectionComplete = true
                }
            }
        }

        NotificationCenter.default.post(name: .wallpaperDataSourceChanged, object: nil)
    }

    /// 检测是否启用了 VPN
    /// - Returns: true 如果检测到活跃的 VPN 接口
    func isVPNEnabled() -> Bool {
        let vpnInterfacePrefixes = ["utun", "ppp", "ipsec", "tun", "tap"]

        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return false
        }

        defer { freeifaddrs(ifaddr) }

        var hasVPN = false
        var ptr = firstAddr
        while true {
            let name = String(cString: ptr.pointee.ifa_name)
            if vpnInterfacePrefixes.contains(where: { name.hasPrefix($0) }) {
                // 检查接口是否处于活跃状态 (IFF_UP | IFF_RUNNING)
                let flags = Int32(ptr.pointee.ifa_flags)
                if (flags & IFF_UP) != 0 && (flags & IFF_RUNNING) != 0 {
                    hasVPN = true
                    break
                }
            }

            guard let next = ptr.pointee.ifa_next else { break }
            ptr = next
        }

        return hasVPN
    }

    /// Ping Google 检测网络是否可达
    /// - Parameter timeout: 超时时间（秒）
    /// - Returns: true 如果 Google 可达
    func pingGoogle(timeout: TimeInterval = 5) async -> Bool {
        let url = URL(string: "https://www.google.com/generate_204")!

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = timeout

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return false
            }
            // generate_204 返回 204 或者 200 都是可达
            return httpResponse.statusCode == 204 || httpResponse.statusCode == 200
        } catch {
            print("[WallpaperSourceManager] Google ping failed: \(error.localizedDescription)")
            return false
        }
    }
}
