import Foundation
import Combine
import SwiftUI

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
            case .wallpaperEngine: return t("wallpaperEngine")
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

    // MARK: - Workshop 类型筛选
    
    enum WorkshopTypeFilter: String, CaseIterable, Identifiable {
        case all = "all"
        case scene = "Scene"
        case video = "Video"
        case web = "Web"
        case application = "Application"
        
        var id: String { rawValue }
        
        var displayName: String {
            switch self {
            case .all: return t("workshop.type.all")
            case .scene: return t("workshop.type.scene")
            case .video: return t("workshop.type.video")
            case .web: return t("workshop.type.web")
            case .application: return t("workshop.type.application")
            }
        }
        
        var icon: String {
            switch self {
            case .all: return "square.grid.2x2"
            case .scene: return "cube.fill"
            case .video: return "film.fill"
            case .web: return "safari.fill"
            case .application: return "app.fill"
            }
        }
        
        var accentColors: [String] {
            switch self {
            case .all: return ["FF9B58", "F54E42"]
            case .scene: return ["9B5DE5", "F15BB5"]
            case .video: return ["E71D36", "FF9F1C"]
            case .web: return ["00BBF9", "3A86FF"]
            case .application: return ["00F5D4", "01BE96"]
            }
        }
    }

    // MARK: - SteamCMD 凭证（Keychain 安全存储）

    struct SteamCredentials: Codable {
        let username: String
        let password: String
        let guardCode: String?
    }

    // Keychain 存储标识
    private let keychainService = "com.waifux.steamcmd.credentials"
    private let keychainAccount = "steam_credentials"

    // 旧版 UserDefaults key（仅用于一次性迁移）
    private let legacyUserDefaultsKey = "workshop_steam_credentials"
    private let migrationFlagKey = "workshop_steam_credentials_migrated_to_keychain"

    var steamCredentials: SteamCredentials? {
        get {
            loadCredentialsFromKeychain()
        }
        set {
            if let credentials = newValue {
                saveCredentialsToKeychain(credentials)
            } else {
                deleteCredentialsFromKeychain()
            }
            objectWillChange.send()
        }
    }

    /// 仅检查本地是否存有凭据，不验证 SteamCMD 会话是否仍然有效
    var hasStoredSteamCredentials: Bool {
        steamCredentials != nil
    }

    func setSteamCredentials(username: String, password: String, guardCode: String? = nil) {
        steamCredentials = SteamCredentials(username: username, password: password, guardCode: guardCode)
    }

    /// 更新 guardCode（手机确认登录后 guardCode 为 nil，此方法此时为空操作）
    func updateGuardCode(_ guardCode: String?) {
        guard let current = steamCredentials else { return }
        steamCredentials = SteamCredentials(username: current.username, password: current.password, guardCode: guardCode)
    }

    func clearSteamCredentials() {
        steamCredentials = nil
    }

    // MARK: - Keychain 操作

    private func loadCredentialsFromKeychain() -> SteamCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let creds = try? JSONDecoder().decode(SteamCredentials.self, from: data) else {
            return nil
        }
        return creds
    }

    private func saveCredentialsToKeychain(_ credentials: SteamCredentials) {
        guard let data = try? JSONEncoder().encode(credentials) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]

        // 先删除已存在的项
        SecItemDelete(query as CFDictionary)

        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: data
        ]

        SecItemAdd(attributes as CFDictionary, nil)
    }

    private func deleteCredentialsFromKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// 一次性迁移：将旧版 UserDefaults 中的凭据迁移到 Keychain
    private func migrateCredentialsToKeychainIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: migrationFlagKey) else { return }

        // 尝试从旧 UserDefaults key 读取
        if let data = UserDefaults.standard.data(forKey: legacyUserDefaultsKey),
           let creds = try? JSONDecoder().decode(SteamCredentials.self, from: data) {
            saveCredentialsToKeychain(creds)
            // 迁移成功后删除旧数据
            UserDefaults.standard.removeObject(forKey: legacyUserDefaultsKey)
            print("[WorkshopSourceManager] 已将 Steam 凭据从 UserDefaults 迁移到 Keychain")
        }

        UserDefaults.standard.set(true, forKey: migrationFlagKey)
    }

    // MARK: - SteamCMD 路径管理
    //
    // 用户侧：安装/打开 App 即可，无需自己找路径。首次使用 Workshop 下载时，若尚未准备可写副本，
    // 会自动把 **App 内已打包的** `Contents/Resources/steamcmd/` 复制到 Application Support（见 `steamCMDExecutableURL()`）。
    // 原因：Valve 的 `steamcmd.sh` 会在运行目录写入更新与 `config/` 登录缓存，`.app` 内 Resources 在正式安装环境下通常不可写，
    // 因此工作副本固定在 `~/Library/Application Support/com.waifux.app/steamcmd/`，避免自更新/登录失败。
    //
    // 开发侧：`Resources/steamcmd/` 已随仓库提交即可直接构建；更新二进制时运行 `scripts/sync-steamcmd-into-resources.sh`（默认拉官方包）。

    /// 应用包内 `steamcmd/`（与 Valve 官方 macOS 解压目录一致，目录内须有 `steamcmd.sh`）。
    ///
    /// 注意：若 Xcode 将仓库根目录的 **`Resources` 文件夹整体**作为 folder reference 打进包内，
    /// 实际路径为 `App.app/Contents/Resources/Resources/steamcmd/`，而不是 `.../Resources/steamcmd/`。
    /// 这里同时兼容「扁平」与「多套一层 Resources」两种布局，避免误判为「内置组件缺失」。
    private static func bundledSteamCMDDirectoryURL() -> URL? {
        let fm = FileManager.default
        if let sh = Bundle.main.url(forResource: "steamcmd", withExtension: "sh", subdirectory: "steamcmd"),
           fm.fileExists(atPath: sh.path) {
            return sh.deletingLastPathComponent()
        }
        if let bin = Bundle.main.url(forResource: "steamcmd", withExtension: nil, subdirectory: "steamcmd"),
           fm.fileExists(atPath: bin.path) {
            return bin.deletingLastPathComponent()
        }
        guard let bundleResources = Bundle.main.resourceURL else { return nil }
        let nestedBases = [
            bundleResources,
            bundleResources.appendingPathComponent("Resources", isDirectory: true)
        ]
        for base in nestedBases {
            let dir = base.appendingPathComponent("steamcmd", isDirectory: true)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue,
               fm.fileExists(atPath: dir.appendingPathComponent("steamcmd.sh").path) {
                return dir
            }
        }
        return nil
    }
    
    /// 返回 SteamCMD 可执行文件路径
    /// 首次调用时会将 Bundle 中的 steamcmd 复制到 Application Support，
    /// 避免重新编译 App 时覆盖掉 steamcmd 的自更新文件和登录缓存。
    /// 若已存在副本但缺少 Bundle 中新增的文件（版本更新），增量补充缺失文件，保留 config/ 登录缓存。
    func steamCMDExecutableURL() -> URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let destDir = appSupport.appendingPathComponent("com.waifux.app/steamcmd", isDirectory: true)
        let script = destDir.appendingPathComponent("steamcmd.sh")

        // 如果 Application Support 中已有可工作的副本，直接返回
        if Self.isValidSteamCMDInstallation(at: destDir) {
            return script
        }

        // 从 Bundle 复制原始 steamcmd 目录
        guard let bundleSteamcmdDir = Self.bundledSteamCMDDirectoryURL() else {
            return nil
        }

        do {
            try FileManager.default.createDirectory(at: destDir.deletingLastPathComponent(), withIntermediateDirectories: true)

            if FileManager.default.fileExists(atPath: destDir.path) {
                // 目录已存在但缺少关键文件（版本更新），增量补充缺失文件，保留 config/ 登录缓存
                let bundleContents = try FileManager.default.contentsOfDirectory(at: bundleSteamcmdDir, includingPropertiesForKeys: nil)
                for item in bundleContents {
                    let destItem = destDir.appendingPathComponent(item.lastPathComponent)
                    if !FileManager.default.fileExists(atPath: destItem.path) {
                        try FileManager.default.copyItem(at: item, to: destItem)
                    }
                }
                print("[WorkshopSourceManager] 已增量补充 steamcmd 到 \(destDir.path)（保留现有登录缓存）")
            } else {
                // 首次安装，完整复制
                try FileManager.default.copyItem(at: bundleSteamcmdDir, to: destDir)
                print("[WorkshopSourceManager] 已将 steamcmd 复制到 \(destDir.path)")
            }
        } catch {
            print("[WorkshopSourceManager] 复制 steamcmd 失败: \(error)")
            return nil
        }

        return script
    }

    /// 验证 Application Support 中的 steamcmd 是否是可工作的安装
    /// 新版 SteamCMD 不再生成 steamcmd-pty，因此只检查核心必需文件的可执行性
    static func isValidSteamCMDInstallation(at dir: URL) -> Bool {
        let fm = FileManager.default
        let script = dir.appendingPathComponent("steamcmd.sh")
        let steamBin = dir.appendingPathComponent("steamcmd")

        // 核心文件必须存在且可执行
        guard fm.fileExists(atPath: script.path),
              fm.isExecutableFile(atPath: script.path),
              fm.fileExists(atPath: steamBin.path),
              fm.isExecutableFile(atPath: steamBin.path) else {
            return false
        }

        // 关键 dylib 必须存在
        let requiredDylibs = ["steamclient.dylib", "libtier0_s.dylib", "libvstdlib_s.dylib"]
        for name in requiredDylibs {
            let dylibPath = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: dylibPath.path) {
                return false
            }
        }

        return true
    }

    // MARK: - Workshop 内容级别（与壁纸列表 Purity 对齐）
    
    enum WorkshopContentLevel: String, CaseIterable, Identifiable {
        case everyone = "Everyone"
        case questionable = "Questionable"
        case mature = "Mature"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .everyone: return "SFW"
            case .questionable: return "Sketchy"
            case .mature: return "NSFW"
            }
        }

        var subtitle: String {
            switch self {
            case .everyone: return t("purity.sfw")
            case .questionable: return t("purity.sketchy")
            case .mature: return t("purity.nsfw")
            }
        }

        var tint: Color {
            switch self {
            case .everyone: return LiquidGlassColors.onlineGreen
            case .questionable: return LiquidGlassColors.warningOrange
            case .mature: return LiquidGlassColors.primaryPink
            }
        }
        
        var accentHex: String {
            switch self {
            case .everyone: return "43C463"
            case .questionable: return "FFB347"
            case .mature: return "FF5A7D"
            }
        }
    }

    // MARK: - Workshop 标签
    
    /// Wallpaper Engine Workshop 常用标签（基于 Steam 文档实际分类）
    struct WorkshopTag: Identifiable, Hashable {
        let id: String
        let name: String
        let translationKey: String
        let icon: String
        let accentColors: [String]
        
        var displayName: String { t(translationKey) }

        static let allTags: [WorkshopTag] = [
            WorkshopTag(id: "abstract", name: "Abstract", translationKey: "workshop.tag.abstract", icon: "scribble", accentColors: ["FB5607", "FFBE0B"]),
            WorkshopTag(id: "animal", name: "Animal", translationKey: "workshop.tag.animal", icon: "pawprint.fill", accentColors: ["A8E6CF", "1A936F"]),
            WorkshopTag(id: "anime", name: "Anime", translationKey: "workshop.tag.anime", icon: "sparkles", accentColors: ["FF5E98", "FF9A5B"]),
            WorkshopTag(id: "cartoon", name: "Cartoon", translationKey: "workshop.tag.cartoon", icon: "face.smiling", accentColors: ["FFBE0B", "FF006E"]),
            WorkshopTag(id: "cgi", name: "CGI", translationKey: "workshop.tag.cgi", icon: "cpu.fill", accentColors: ["3A86FF", "00BBF9"]),
            WorkshopTag(id: "cyberpunk", name: "Cyberpunk", translationKey: "workshop.tag.cyberpunk", icon: "bolt.fill", accentColors: ["F72585", "7209B7"]),
            WorkshopTag(id: "fantasy", name: "Fantasy", translationKey: "workshop.tag.fantasy", icon: "wand.and.stars", accentColors: ["9B5DE5", "F15BB5"]),
            WorkshopTag(id: "game", name: "Game", translationKey: "workshop.tag.game", icon: "gamecontroller.fill", accentColors: ["FFBE0B", "FB5607"]),
            WorkshopTag(id: "girls", name: "Girls", translationKey: "workshop.tag.girls", icon: "person.fill", accentColors: ["FF5E98", "FF9A5B"]),
            WorkshopTag(id: "guys", name: "Guys", translationKey: "workshop.tag.guys", icon: "person.fill", accentColors: ["00BBF9", "3A86FF"]),
            WorkshopTag(id: "landscape", name: "Landscape", translationKey: "workshop.tag.landscape", icon: "photo.fill", accentColors: ["2EC4B6", "1A936F"]),
            WorkshopTag(id: "medieval", name: "Medieval", translationKey: "workshop.tag.medieval", icon: "crown.fill", accentColors: ["D4A373", "BC6C25"]),
            WorkshopTag(id: "memes", name: "Memes", translationKey: "workshop.tag.memes", icon: "face.smiling.fill", accentColors: ["FBBF24", "F59E0B"]),
            WorkshopTag(id: "mmd", name: "MMD", translationKey: "workshop.tag.mmd", icon: "figure.dance", accentColors: ["FF5E98", "9B5DE5"]),
            WorkshopTag(id: "music", name: "Music", translationKey: "workshop.tag.music", icon: "music.note", accentColors: ["8338EC", "3A86FF"]),
            WorkshopTag(id: "nature", name: "Nature", translationKey: "workshop.tag.nature", icon: "leaf.fill", accentColors: ["00F5D4", "01BE96"]),
            WorkshopTag(id: "pixelart", name: "Pixel art", translationKey: "workshop.tag.pixelart", icon: "square.grid.2x2", accentColors: ["FF006E", "8338EC"]),
            WorkshopTag(id: "relaxing", name: "Relaxing", translationKey: "workshop.tag.relaxing", icon: "wind", accentColors: ["A8DADC", "457B9D"]),
            WorkshopTag(id: "retro", name: "Retro", translationKey: "workshop.tag.retro", icon: "clock.arrow.circlepath", accentColors: ["FF9F1C", "E71D36"]),
            WorkshopTag(id: "scifi", name: "Sci-Fi", translationKey: "workshop.tag.scifi", icon: "bolt.fill", accentColors: ["00BBF9", "9B5DE5"]),
            WorkshopTag(id: "sports", name: "Sports", translationKey: "workshop.tag.sports", icon: "sportscourt.fill", accentColors: ["FB5607", "FFBE0B"]),
            WorkshopTag(id: "technology", name: "Technology", translationKey: "workshop.tag.technology", icon: "cpu.fill", accentColors: ["3A86FF", "00BBF9"]),
            WorkshopTag(id: "television", name: "Television", translationKey: "workshop.tag.television", icon: "tv.fill", accentColors: ["E71D36", "FF9F1C"]),
            WorkshopTag(id: "vehicle", name: "Vehicle", translationKey: "workshop.tag.vehicle", icon: "car.fill", accentColors: ["495057", "212529"])
        ]
    }

    /// 获取所有可用标签
    var availableTags: [WorkshopTag] {
        WorkshopTag.allTags
    }

    // MARK: - Workshop 分辨率筛选
    
    /// Steam Workshop 分辨率选项（对应 requiredtags[] 标签格式）
    struct WorkshopResolution: Identifiable, Hashable {
        let id: String
        /// 展示文本，如 "1920 × 1080"
        let display: String
        /// Steam Workshop 标签值，如 "1920 x 1080"
        let tagValue: String
        
        static let all: [WorkshopResolution] = [
            WorkshopResolution(id: "3840x2160", display: "3840 × 2160 (4K UHD)", tagValue: "3840 x 2160"),
            WorkshopResolution(id: "2560x1440", display: "2560 × 1440 (2K QHD)", tagValue: "2560 x 1440"),
            WorkshopResolution(id: "3440x1440", display: "3440 × 1440 (UW-QHD)", tagValue: "3440 x 1440"),
            WorkshopResolution(id: "1920x1080", display: "1920 × 1080 (FHD)", tagValue: "1920 x 1080"),
            WorkshopResolution(id: "2560x1080", display: "2560 × 1080 (UW-FHD)", tagValue: "2560 x 1080"),
            WorkshopResolution(id: "1280x720",  display: "1280 × 720 (HD)",    tagValue: "1280 x 720"),
            WorkshopResolution(id: "7680x4320", display: "7680 × 4320 (8K UHD)", tagValue: "7680 x 4320"),
            WorkshopResolution(id: "5120x2880", display: "5120 × 2880 (5K)",     tagValue: "5120 x 2880"),
            WorkshopResolution(id: "5120x1440", display: "5120 × 1440 (超宽)",    tagValue: "5120 x 1440"),
        ]
    }
    
    /// 获取所有可用分辨率
    var availableResolutions: [WorkshopResolution] {
        WorkshopResolution.all
    }
    
    // MARK: - Published State
    
    @Published private(set) var activeSource: SourceType
    @Published var lastSwitchMessage: String?
    
    // MARK: - Storage Keys
    
    private let selectedSourceKey = "workshop_selected_source"
    
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
        migrateCredentialsToKeychainIfNeeded()
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
    
    /// SteamCMD 是否已配置/安装
    var isSteamCMDConfigured: Bool {
        guard let dir = Self.bundledSteamCMDDirectoryURL() else { return false }
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent("steamcmd.sh").path)
    }
    
    /// 是否已通过 SteamCMD 凭证配置
    var isSteamAuthenticated: Bool {
        hasStoredSteamCredentials
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let workshopSourceChanged = Notification.Name("workshopSourceChanged")
}
