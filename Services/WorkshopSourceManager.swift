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

    // MARK: - SteamCMD 凭证
    
    struct SteamCredentials: Codable {
        let username: String
        let password: String
        let guardCode: String?
    }
    
    private let steamCredentialsKey = "workshop_steam_credentials"
    
    var steamCredentials: SteamCredentials? {
        get {
            guard let data = UserDefaults.standard.data(forKey: steamCredentialsKey),
                  let creds = try? JSONDecoder().decode(SteamCredentials.self, from: data) else {
                return nil
            }
            return creds
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: steamCredentialsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: steamCredentialsKey)
            }
            objectWillChange.send()
        }
    }
    
    var isSteamCMDLoggedIn: Bool {
        steamCredentials != nil
    }
    
    // MARK: - Wallpaper Engine 激活码
    
    private let wallpaperEngineActivationCodeKey = "wallpaper_engine_activation_code"
    
    var wallpaperEngineActivationCode: String {
        get {
            UserDefaults.standard.string(forKey: wallpaperEngineActivationCodeKey) ?? ""
        }
        set {
            UserDefaults.standard.set(newValue, forKey: wallpaperEngineActivationCodeKey)
            objectWillChange.send()
        }
    }
    
    func setSteamCredentials(username: String, password: String, guardCode: String? = nil) {
        steamCredentials = SteamCredentials(username: username, password: password, guardCode: guardCode)
    }

    func updateGuardCode(_ guardCode: String?) {
        guard let current = steamCredentials else { return }
        steamCredentials = SteamCredentials(username: current.username, password: current.password, guardCode: guardCode)
    }

    func clearSteamCredentials() {
        steamCredentials = nil
    }

    // MARK: - SteamCMD 路径管理
    
    /// 返回 SteamCMD 可执行文件路径
    /// 首次调用时会将 Bundle 中的 steamcmd 复制到 Application Support，
    /// 避免重新编译 App 时覆盖掉 steamcmd 的自更新文件和登录缓存
    func steamCMDExecutableURL() -> URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let destDir = appSupport.appendingPathComponent("com.waifux.app/steamcmd", isDirectory: true)
        let script = destDir.appendingPathComponent("steamcmd.sh")
        
        // 如果 Application Support 中已有副本，直接返回脚本路径
        if FileManager.default.fileExists(atPath: script.path) {
            return script
        }
        
        // 从 Bundle 复制原始 steamcmd
        guard let bundleSteamcmd = Bundle.main.url(forResource: "steamcmd", withExtension: nil, subdirectory: "steamcmd") else {
            return nil
        }
        
        let bundleSteamcmdDir = bundleSteamcmd.deletingLastPathComponent()
        
        do {
            try FileManager.default.createDirectory(at: destDir.deletingLastPathComponent(), withIntermediateDirectories: true)
            // 如果旧版本目录已存在（不含 steamcmd.sh 的情况），先删除
            if FileManager.default.fileExists(atPath: destDir.path) {
                try FileManager.default.removeItem(at: destDir)
            }
            try FileManager.default.copyItem(at: bundleSteamcmdDir, to: destDir)
            print("[WorkshopSourceManager] 已将 steamcmd 复制到 \(destDir.path)")
        } catch {
            print("[WorkshopSourceManager] 复制 steamcmd 失败: \(error)")
            return nil
        }
        
        return script
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
        // 检查 bundle 中是否包含 steamcmd 可执行文件
        Bundle.main.url(forResource: "steamcmd", withExtension: nil, subdirectory: "steamcmd") != nil
    }
    
    /// 是否已通过 SteamCMD 凭证配置
    var isSteamAuthenticated: Bool {
        isSteamCMDLoggedIn
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let workshopSourceChanged = Notification.Name("workshopSourceChanged")
}
