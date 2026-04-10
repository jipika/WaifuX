import Foundation

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

    private func checkRecoveryIfNeeded() {
        // 距离上次健康检查太近就跳过
        guard let last = lastHealthCheckTime else { return }
        let elapsed = -last.timeIntervalSinceNow
        guard elapsed > minHealthCheckInterval else { return }

        // 后台静默检查，不阻塞主流程
        Task {
            await silentHealthCheck()
        }
    }

    /// 静默健康检查 Wallhaven 是否恢复（后台执行，不显示 loading）
    private func silentHealthCheck() async {
        guard !isCheckingHealth else { return }
        isCheckingHealth = true
        defer { isCheckingHealth = false }

        do {
            let reachable = try await pingWallhaven()
            if reachable {
                lastHealthCheckTime = Date()
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastHealthCheckKey)
                print("[WallpaperSourceManager] Wallhaven health check passed")
            }
        } catch {
            print("[WallpaperSourceManager] Wallhaven still unavailable: \(error.localizedDescription)")
        }
    }

    /// 应用启动时的初始化健康检查（只执行一次）
    /// 用于检测当前使用的备用源是否可以切回 Wallhaven
    func performInitialHealthCheck() async {
        // 如果当前已经在使用 Wallhaven，不需要检测
        guard activeSource != .wallhaven else {
            print("[WallpaperSourceManager] Initial check: already using Wallhaven, skip")
            return
        }
        
        // 如果用户手动锁定了备用源，不要自动切换
        guard forceSourceOverride == nil else {
            print("[WallpaperSourceManager] Initial check: user locked to fallback, skip")
            return
        }
        
        print("[WallpaperSourceManager] Performing initial health check for Wallhaven...")
        
        do {
            let reachable = try await pingWallhaven()
            if reachable {
                // Wallhaven 可用，自动切回
                print("[WallpaperSourceManager] Wallhaven is reachable, switching back...")
                await MainActor.run {
                    activeSource = .wallhaven
                    isAutoSwitched = false
                    consecutiveFailures = 0
                    consecutiveSuccesses = 0
                    UserDefaults.standard.set(SourceType.wallhaven.rawValue, forKey: selectedSourceKey)
                    UserDefaults.standard.set(false, forKey: autoSwitchedKey)
                    lastSwitchMessage = "✅ Wallhaven 已恢复，已自动切换回主源"
                }
                NotificationCenter.default.post(name: .wallpaperDataSourceChanged, object: nil)
            } else {
                print("[WallpaperSourceManager] Wallhaven is still unavailable")
            }
        } catch {
            print("[WallpaperSourceManager] Initial health check failed: \(error.localizedDescription)")
        }
    }

    /// Ping Wallhaven 主站是否可达（轻量级检测）
    func pingWallhaven() async throws -> Bool {
        // 使用更轻量的 health check 端点，只验证服务状态
        let url = URL(string: "https://wallhaven.cc/api/v1/search?purity=100&sorting=hot&order=desc&page=1&per_page=1")!
        
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15  // 15秒超时
        
        // 使用简单的 data 请求，只检查 HTTP 状态码，不解析 JSON
        let (_, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }
        
        return (200...299).contains(httpResponse.statusCode)
    }
}
