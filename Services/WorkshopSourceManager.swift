import Foundation
import Combine

// MARK: - Wallpaper Engine  workshop 源管理器
///
/// 管理 Wallpaper Engine Steam 创意工坊的数据源切换
/// 支持多个壁纸源: MotionBG(当前) / Wallpaper Engine Workshop
@MainActor
class WorkshopSourceManager: ObservableObject {
    static let shared = WorkshopSourceManager()
    
    // MARK: - 数据源类型
    
    enum SourceType: String, CaseIterable {
        case motionBG = "motionbg"
        case wallpaperEngine = "wallpaper_engine"
        
        var displayName: String {
            switch self {
            case .motionBG: return "MotionBG"
            case .wallpaperEngine: return "小红车"
            }
        }
        
        var subtitle: String {
            switch self {
            case .motionBG: return "在线视频壁纸"
            case .wallpaperEngine: return "Steam Workshop"
            }
        }
        
        /// 图标
        var icon: String {
            switch self {
            case .motionBG: return "play.rectangle.fill"
            case .wallpaperEngine: return "gearshape.fill"
            }
        }
        
        /// 是否支持搜索
        var supportsSearch: Bool {
            switch self {
            case .motionBG: return true
            case .wallpaperEngine: return true
            }
        }
        
        /// 是否支持分类浏览
        var supportsCategories: Bool {
            switch self {
            case .motionBG: return true
            case .wallpaperEngine: return true
            }
        }
        
        /// 是否需要 Steam 登录
        var requiresSteamAuth: Bool {
            switch self {
            case .motionBG: return false
            case .wallpaperEngine: return false
            }
        }
        
        /// 是否支持预渲染
        var supportsPrerender: Bool {
            switch self {
            case .motionBG: return false
            case .wallpaperEngine: return true
            }
        }
        
        /// 强调色
        var accentColor: String {
            switch self {
            case .motionBG: return "cyan"
            case .wallpaperEngine: return "blue"
            }
        }
    }
    
    // MARK: - Published State
    
    @Published private(set) var activeSource: SourceType
    @Published private(set) var isSteamAuthenticated: Bool = false
    @Published var lastSwitchMessage: String?
    
    // MARK: - Steam 相关状态
    
    @Published var steamCredentials: SteamCredentials? {
        didSet { saveCredentials() }
    }
    
    // MARK: - Storage Keys
    
    private let selectedSourceKey = "workshop_selected_source"
    private let steamCredentialsKey = "workshop_steam_credentials"
    
    // MARK: - Internal State
    
    private var cancellables = Set<AnyCancellable>()
    
    private init() {
        activeSource = .motionBG
        restoreState()
    }
    
    /// 恢复持久化状态
    private func restoreState() {
        if let saved = UserDefaults.standard.string(forKey: selectedSourceKey),
           let source = SourceType(rawValue: saved) {
            activeSource = source
        }
        
        // 恢复 Steam 凭证
        if let credentialsData = KeychainHelper.shared.read(service: steamCredentialsKey, account: "default"),
           let credentials = try? JSONDecoder().decode(SteamCredentials.self, from: credentialsData) {
            steamCredentials = credentials
            isSteamAuthenticated = true
        }
    }
    
    // MARK: - Public API
    
    var isUsingWallpaperEngine: Bool {
        activeSource == .wallpaperEngine
    }
    
    var currentSourceSupportsSearch: Bool {
        activeSource.supportsSearch
    }
    
    var currentSourceSupportsCategories: Bool {
        activeSource.supportsCategories
    }
    
    var currentSourceRequiresSteamAuth: Bool {
        activeSource.requiresSteamAuth
    }
    
    func currentSource() -> SourceType {
        activeSource
    }
    
    /// 手动切换数据源
    func switchTo(_ source: SourceType) {
        guard activeSource != source else { return }
        
        let previousSource = activeSource
        activeSource = source
        
        UserDefaults.standard.set(source.rawValue, forKey: selectedSourceKey)
        
        lastSwitchMessage = "已切换到 \(source.displayName) - \(source.subtitle)"
        
        NotificationCenter.default.post(name: .workshopSourceChanged, object: nil)
        
        print("[WorkshopSourceManager] Switched from \(previousSource.displayName) to \(source.displayName)")
    }
    
    /// 切换到下一个数据源
    func switchToNext() {
        let allSources = SourceType.allCases
        guard let currentIndex = allSources.firstIndex(of: activeSource) else { return }
        let nextIndex = (currentIndex + 1) % allSources.count
        switchTo(allSources[nextIndex])
    }
    
    // MARK: - Steam 认证
    
    func setSteamCredentials(username: String, password: String) {
        let credentials = SteamCredentials(username: username, password: password)
        steamCredentials = credentials
        isSteamAuthenticated = true
        
        if let data = try? JSONEncoder().encode(credentials) {
            KeychainHelper.shared.save(data, service: steamCredentialsKey, account: "default")
        }
    }
    
    func clearSteamCredentials() {
        steamCredentials = nil
        isSteamAuthenticated = false
        KeychainHelper.shared.delete(service: steamCredentialsKey, account: "default")
    }
    
    /// 检查是否已配置 SteamCMD
    var isSteamCMDConfigured: Bool {
        if let steamcmdURL = Bundle.main.url(forResource: "steamcmd", withExtension: nil, subdirectory: "steamcmd") {
            return FileManager.default.fileExists(atPath: steamcmdURL.path)
        }
        return false
    }
    
    // MARK: - Private
    
    private func saveCredentials() {
        // 凭证通过 KeychainHelper 保存
    }
}

// MARK: - Steam 凭证模型

struct SteamCredentials: Codable {
    let username: String
    let password: String
}

// MARK: - Notification 扩展

extension Notification.Name {
    static let workshopSourceChanged = Notification.Name("workshopSourceChanged")
}

// MARK: - Keychain 辅助类

class KeychainHelper {
    static let shared = KeychainHelper()
    
    private init() {}
    
    func save(_ data: Data, service: String, account: String) {
        let query = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: data
        ] as CFDictionary
        
        SecItemDelete(query)
        SecItemAdd(query, nil)
    }
    
    func read(service: String, account: String) -> Data? {
        let query = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ] as CFDictionary
        
        var result: AnyObject?
        SecItemCopyMatching(query, &result)
        return result as? Data
    }
    
    func delete(service: String, account: String) {
        let query = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ] as CFDictionary
        
        SecItemDelete(query)
    }
}
