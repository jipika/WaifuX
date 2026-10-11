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
        case dongtai = "dongtai"
        case wallsflow = "wallsflow"

        var displayName: String {
            switch self {
            case .motionBG: return "MotionBG"
            case .wallpaperEngine: return t("wallpaperEngine")
            case .dongtai: return t("dongtai")
            case .wallsflow: return t("wallsflow")
            }
        }

        var subtitle: String {
            switch self {
            case .motionBG: return "在线视频壁纸"
            case .wallpaperEngine: return "Steam Workshop"
            case .dongtai: return "动态桌面视频壁纸"
            case .wallsflow: return "Live Wallpaper 动态壁纸"
            }
        }

        /// 图标
        var icon: String {
            switch self {
            case .motionBG: return "play.rectangle.fill"
            case .wallpaperEngine: return "gearshape.fill"
            case .dongtai: return "sparkles.tv.fill"
            case .wallsflow: return "water.waves"
            }
        }

        /// 是否支持搜索
        var supportsSearch: Bool {
            switch self {
            case .motionBG: return true
            case .wallpaperEngine: return true
            case .dongtai: return true
            case .wallsflow: return true
            }
        }

        /// 是否支持分类浏览
        var supportsCategories: Bool {
            switch self {
            case .motionBG: return true
            case .wallpaperEngine: return true
            case .dongtai: return true
            case .wallsflow: return true
            }
        }

        /// 是否需要 Steam 登录
        var requiresSteamAuth: Bool {
            switch self {
            case .motionBG: return false
            case .wallpaperEngine: return false
            case .dongtai: return false
            case .wallsflow: return false
            }
        }

        /// 是否支持预渲染
        var supportsPrerender: Bool {
            switch self {
            case .motionBG: return false
            case .wallpaperEngine: return true
            case .dongtai: return false
            case .wallsflow: return false
            }
        }

        /// 强调色
        var accentColor: String {
            switch self {
            case .motionBG: return "cyan"
            case .wallpaperEngine: return "blue"
            case .dongtai: return "pink"
            case .wallsflow: return "purple"
            }
        }
    }

    // MARK: - Workshop 类型筛选

    enum WorkshopTypeFilter: String, CaseIterable, Identifiable {
        case all = "all"
        case scene = "Scene"
        case video = "Video"
        case web = "Web"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .all: return t("workshop.type.all")
            case .scene: return t("workshop.type.scene")
            case .video: return t("workshop.type.video")
            case .web: return t("workshop.type.web")
            }
        }

        var icon: String {
            switch self {
            case .all: return "square.grid.2x2"
            case .scene: return "cube.fill"
            case .video: return "film.fill"
            case .web: return "safari.fill"
            }
        }

        var accentColors: [String] {
            switch self {
            case .all: return ["FF9B58", "F54E42"]
            case .scene: return ["9B5DE5", "F15BB5"]
            case .video: return ["E71D36", "FF9F1C"]
            case .web: return ["00BBF9", "3A86FF"]
            }
        }
    }

    // MARK: - Steam 账号标识

    struct SteamIdentity: Codable, Equatable {
        let username: String
    }

    private struct LegacySteamCredentials: Codable {
        let username: String
        let password: String
        let guardCode: String?
    }

    enum SteamCredentialState: Equatable {
        case unknown
        case available(username: String)
        case missing
        case failure(String)
    }

    private let localIdentityKey = "workshop_steam_identity_v1"
    private let legacyCredentialsKey = "workshop_steam_credentials_plaintext"

    @Published private(set) var steamIdentity: SteamIdentity?
    @Published private(set) var steamCredentialState: SteamCredentialState = .unknown

    /// 仅检查本地是否保存过账号名，不代表 Steam 会话仍然有效。
    var hasStoredSteamIdentity: Bool {
        steamIdentity != nil
    }

    func setSteamIdentity(username: String) {
        let normalized = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            steamCredentialState = .failure("Steam 用户名不能为空。")
            return
        }
        persistIdentityLocally(SteamIdentity(username: normalized))
    }

    func clearSteamIdentity() {
        WaifuXPreferences.shared.removeObject(forKey: localIdentityKey)
        WaifuXPreferences.shared.removeObject(forKey: legacyCredentialsKey)
        steamIdentity = nil
        steamCredentialState = .missing
    }

    func refreshStoredSteamIdentity() {
        switch loadStoredIdentity() {
        case .success(let identity):
            steamIdentity = identity
            steamCredentialState = .available(username: identity.username)
        case .missing:
            steamIdentity = nil
            steamCredentialState = .missing
        case .failure(let message):
            steamIdentity = nil
            steamCredentialState = .failure(message)
        }
    }

    // MARK: - Steam 订阅同步

    /// 用户 Steam 社区档案 ID（64位数字 ID 或自定义 URL）用于获取订阅列表
    @Published var steamProfileID: String = "" {
        didSet {
            WaifuXPreferences.shared.set(steamProfileID, forKey: profileIDKey)
        }
    }

    private let profileIDKey = "workshop_steam_profile_id"

    /// 加载已保存的 Steam Profile ID
    func loadSteamProfileID() {
        if let saved = WaifuXPreferences.shared.string(forKey: profileIDKey), !saved.isEmpty {
            steamProfileID = saved
        }
    }

    /// 是否有有效的 Steam Profile ID
    var hasSteamProfileID: Bool {
        !steamProfileID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - 本地存储操作

    private enum LocalIdentityLoadResult {
        case success(SteamIdentity)
        case missing
        case failure(String)
    }

    private func loadStoredIdentity() -> LocalIdentityLoadResult {
        let defaults = WaifuXPreferences.shared
        if let data = defaults.data(forKey: localIdentityKey) {
            guard let identity = try? JSONDecoder().decode(SteamIdentity.self, from: data) else {
                return .failure("本地 Steam 账号信息已损坏，请重新登录。")
            }
            return .success(identity)
        }

        guard let legacyData = defaults.data(forKey: legacyCredentialsKey) else {
            return .missing
        }
        guard let legacy = try? JSONDecoder().decode(LegacySteamCredentials.self, from: legacyData) else {
            defaults.removeObject(forKey: legacyCredentialsKey)
            return .failure("旧版 Steam 账号数据已损坏，请重新登录。")
        }

        let identity = SteamIdentity(username: legacy.username)
        persistIdentityLocally(identity)
        defaults.removeObject(forKey: legacyCredentialsKey)
        AppLogger.info(.media, "已迁移旧版 Steam 账号并删除明文密码")
        return .success(identity)
    }

    private func persistIdentityLocally(_ identity: SteamIdentity) {
        guard let data = try? JSONEncoder().encode(identity) else {
            steamCredentialState = .failure("账号数据编码失败，请重试。")
            return
        }
        WaifuXPreferences.shared.set(data, forKey: localIdentityKey)
        steamIdentity = identity
        steamCredentialState = .available(username: identity.username)
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
            WorkshopResolution(id: "7680x4320", display: "7680 × 4320 (8K UHD)",  tagValue: "7680 x 4320"),
            WorkshopResolution(id: "5120x2880", display: "5120 × 2880 (5K)",      tagValue: "5120 x 2880"),
            WorkshopResolution(id: "3840x2160", display: "3840 × 2160 (4K UHD)",  tagValue: "3840 x 2160"),
            WorkshopResolution(id: "2560x1440", display: "2560 × 1440 (2K QHD)",  tagValue: "2560 x 1440"),
            WorkshopResolution(id: "3440x1440", display: "3440 × 1440 (UW-QHD)",  tagValue: "3440 x 1440"),
            WorkshopResolution(id: "1920x1080", display: "1920 × 1080 (FHD)",     tagValue: "1920 x 1080"),
            WorkshopResolution(id: "2560x1080", display: "2560 × 1080 (UW-FHD)",  tagValue: "2560 x 1080"),
            WorkshopResolution(id: "1280x720",  display: "1280 × 720 (HD)",       tagValue: "1280 x 720"),
            WorkshopResolution(id: "5120x1440", display: "5120 × 1440 (超宽)",    tagValue: "5120 x 1440"),
            // ── 竖屏 Portrait ──
            WorkshopResolution(id: "2160x3840", display: "2160 × 3840 (竖屏 4K)", tagValue: "Portrait 2160 x 3840"),
            WorkshopResolution(id: "1440x2560", display: "1440 × 2560 (竖屏 2K)", tagValue: "Portrait 1440 x 2560"),
            WorkshopResolution(id: "1080x1920", display: "1080 × 1920 (竖屏)",    tagValue: "Portrait 1080 x 1920"),
            WorkshopResolution(id: "720x1280",  display: "720 × 1280 (竖屏)",     tagValue: "Portrait 720 x 1280"),
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
        refreshStoredSteamIdentity()
    }

    /// 恢复持久化状态
    private func restoreState() {
        if let saved = WaifuXPreferences.shared.string(forKey: selectedSourceKey),
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

        WaifuXPreferences.shared.set(source.rawValue, forKey: selectedSourceKey)

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

    /// 已恢复的 SteamKit2 会话优先；在启动恢复完成前保留本地账号标识，
    /// 以便设置页仍能展示账户并允许用户主动重新登录。
    var isSteamAuthenticated: Bool {
        SteamServiceManager.shared.isLoggedIn || hasStoredSteamIdentity
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let workshopSourceChanged = Notification.Name("workshopSourceChanged")
    static let steamWorkshopLoginRequired = Notification.Name("steamWorkshopLoginRequired")
}
