import Foundation

// MARK: - DanDanPlay API 响应模型

/// 弹幕搜索响应
struct DanmakuSearchResponse: Codable, Sendable {
    let hasMore: Bool
    let animes: [DanmakuAnime]

    private enum CodingKeys: String, CodingKey { case hasMore, animes }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        hasMore = try values.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
        animes = try values.decodeIfPresent([DanmakuAnime].self, forKey: .animes) ?? []
    }
}

struct DanmakuAnime: Codable, Identifiable, Sendable {
    let animeId: Int
    let animeTitle: String
    let type: String
    let typeDescription: String
    let episodes: [DanmakuEpisode]

    var id: Int { animeId }

    private enum CodingKeys: String, CodingKey { case animeId, animeTitle, type, typeDescription, episodes }
    init(animeId: Int, animeTitle: String, type: String = "", typeDescription: String = "", episodes: [DanmakuEpisode] = []) {
        self.animeId = animeId
        self.animeTitle = animeTitle
        self.type = type
        self.typeDescription = typeDescription
        self.episodes = episodes
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        animeId = try c.decode(Int.self, forKey: .animeId)
        animeTitle = try c.decodeIfPresent(String.self, forKey: .animeTitle) ?? ""
        type = (try? c.decodeIfPresent(String.self, forKey: .type)) ?? ""
        typeDescription = try c.decodeIfPresent(String.self, forKey: .typeDescription) ?? ""
        episodes = try c.decodeIfPresent([DanmakuEpisode].self, forKey: .episodes) ?? []
    }
}

/// The detail API nests metadata beneath `bangumi`; search entries may omit episodes.
struct DanmakuBangumiResponse: Decodable, Sendable {
    let bangumi: DanmakuAnime?
    let success: Bool?
}

struct DanmakuEpisode: Codable, Identifiable, Sendable {
    let episodeId: Int
    let episodeTitle: String
    let episodeNumber: String

    var id: Int { episodeId }

    private enum CodingKeys: String, CodingKey { case episodeId, episodeTitle, episodeNumber }
    init(episodeId: Int, episodeTitle: String, episodeNumber: String = "") {
        self.episodeId = episodeId
        self.episodeTitle = episodeTitle
        self.episodeNumber = episodeNumber
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        episodeId = try c.decode(Int.self, forKey: .episodeId)
        episodeTitle = try c.decodeIfPresent(String.self, forKey: .episodeTitle) ?? ""
        if let number = try? c.decode(String.self, forKey: .episodeNumber) { episodeNumber = number }
        else if let number = try? c.decode(Double.self, forKey: .episodeNumber) { episodeNumber = String(number) }
        else { episodeNumber = "" }
    }
}

/// 弹幕内容响应
struct DanmakuCommentResponse: Codable, Sendable {
    let count: Int
    let comments: [DanmakuComment]
}

struct DanmakuComment: Codable, Sendable {
    let cid: Int
    let p: String  // 格式: "时间,模式,颜色,用户ID"
    let m: String  // 弹幕内容

    /// 解析属性
    var time: Double {
        let parts = p.split(separator: ",", omittingEmptySubsequences: false)
        return Double(parts[safe: 0] ?? "0") ?? 0
    }

    var mode: DanmakuMode {
        let parts = p.split(separator: ",", omittingEmptySubsequences: false)
        let modeValue = Int(parts[safe: 1] ?? "1") ?? 1
        return DanmakuMode(rawValue: modeValue) ?? .scroll
    }

    var color: Int {
        let parts = p.split(separator: ",", omittingEmptySubsequences: false)
        return Int(parts[safe: 2] ?? "16777215") ?? 16777215
    }

    var userId: String {
        let parts = p.split(separator: ",", omittingEmptySubsequences: false)
        return String(parts[safe: 3] ?? "0")
    }
}

/// 弹幕显示模式
enum DanmakuMode: Int, Codable, Sendable {
    case scroll = 1        // 从右向左滚动
    case top = 5           // 顶部固定（DanDanPlay/Bilibili 模式 5）
    case bottom = 4        // 底部固定（DanDanPlay/Bilibili 模式 4）
}

// MARK: - 内部使用的弹幕模型

struct Danmaku: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let text: String
    let time: Double        // 出现时间（秒）
    let mode: DanmakuMode
    let color: ColorInfo
    let userId: String

    /// 弹幕颜色信息
    struct ColorInfo: Codable, Equatable, Sendable {
        let hexValue: Int

        var r: Double {
            Double((hexValue >> 16) & 0xFF) / 255.0
        }

        var g: Double {
            Double((hexValue >> 8) & 0xFF) / 255.0
        }

        var b: Double {
            Double(hexValue & 0xFF) / 255.0
        }

        var swiftUIColor: (red: Double, green: Double, blue: Double) {
            (r, g, b)
        }

        static let white = ColorInfo(hexValue: 16777215)
        static let red = ColorInfo(hexValue: 0xFF0000)
        static let yellow = ColorInfo(hexValue: 0xFFFF00)
        static let green = ColorInfo(hexValue: 0x00FF00)
        static let cyan = ColorInfo(hexValue: 0x00FFFF)
        static let blue = ColorInfo(hexValue: 0x0000FF)
    }

    init(text: String, time: Double, mode: DanmakuMode = .scroll, color: Int = 16777215, userId: String = "0", id: UUID? = nil) {
        self.text = text
        self.time = time
        self.mode = mode
        self.color = ColorInfo(hexValue: color)
        self.userId = userId
        self.id = id ?? Self.stableID(text: text, time: time, mode: mode, color: color, userId: userId)
    }

    /// cid 与内容共同组成稳定标识，跨网络读取、磁盘缓存与 seek 保持一致。
    init(from comment: DanmakuComment) {
        self.init(text: comment.m, time: comment.time, mode: comment.mode,
                  color: comment.color, userId: comment.userId,
                  id: Self.stableID(text: comment.m, time: comment.time, mode: comment.mode,
                                    color: comment.color, userId: "\(comment.cid):\(comment.userId)"))
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, time, mode, color, userId
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let text = try values.decode(String.self, forKey: .text)
        let time = try values.decode(Double.self, forKey: .time)
        let mode = try values.decodeIfPresent(DanmakuMode.self, forKey: .mode) ?? .scroll
        let color = try values.decodeIfPresent(ColorInfo.self, forKey: .color) ?? .white
        let userId = try values.decodeIfPresent(String.self, forKey: .userId) ?? "0"
        self.init(text: text, time: time, mode: mode, color: color.hexValue, userId: userId,
                  id: try values.decodeIfPresent(UUID.self, forKey: .id))
    }

    private static func stableID(text: String, time: Double, mode: DanmakuMode, color: Int, userId: String) -> UUID {
        // Fixed FNV seeds, rather than Swift's per-process randomized Hasher.
        let key = "\(time.bitPattern)|\(mode.rawValue)|\(color)|\(userId.utf8.count):\(userId)|\(text)"
        var first: UInt64 = 14695981039346656037
        var second: UInt64 = 7809847782465536322
        for byte in key.utf8 {
            first = (first ^ UInt64(byte)) &* 1099511628211
            second = (second ^ UInt64(byte)) &* 14029467366897019727
        }
        let bytes = (0..<8).map { UInt8(truncatingIfNeeded: first >> ($0 * 8)) }
            + (0..<8).map { UInt8(truncatingIfNeeded: second >> ($0 * 8)) }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

// MARK: - 弹幕轨道管理

/// 弹幕轨道
struct DanmakuTrack: Identifiable {
    let id = UUID()
    var danmaku: [DanmakuItem] = []
}

/// 弹幕显示项（包含位置信息）
struct DanmakuItem: Identifiable, Equatable {
    let id = UUID()
    let danmaku: Danmaku
    var x: Double
    var y: Double
    var opacity: Double = 1.0
    var isVisible: Bool = true

    static func == (lhs: DanmakuItem, rhs: DanmakuItem) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - 弹幕设置

struct DanmakuSettings: Codable, Equatable, Sendable {
    var isEnabled: Bool
    var speed: Double        // 旧「速度倍数」字段，保留兼容；新 UI 用 durationSeconds
    var opacity: Double      // 弹幕透明度 (0.1 - 1.0)
    var fontSize: Double     // 字体大小 (10 - 48，Kazumi 同款范围)
    var enableTop: Bool      // 显示顶部弹幕
    var enableBottom: Bool   // 显示底部弹幕
    var enableScroll: Bool   // 显示滚动弹幕
    var enableDeduplication: Bool  // 启用去重
    var timeOffset: Double = 0     // 秒；正值延迟展示，负值提前展示
    var blockedKeywords: [String] = []
    var cacheEnabled: Bool = true  // 允许保存文本弹幕并在下载后预取
    // Kazumi 对齐的显示/样式参数（解码缺省时回填默认值）
    var area: Double = 1.0             // 弹幕区域占视频高度比例 (0.25 - 1.0)
    var durationSeconds: Double = 8.0  // 滚动弹幕横穿屏幕的基准时长 (2 - 16)
    var lineHeight: Double = 1.5       // 行高倍数 (1.0 - 2.5)
    var followSpeed: Bool = true       // 弹幕跟随视频倍速
    var massiveMode: Bool = false      // 轨道占满时叠加绘制
    var fontWeight: Int = 5            // 字重 (1 - 9 映射 ultralight...black)
    var showBorder: Bool = true        // 描边
    var borderWidth: Double = 1.0      // 描边粗细 (0.1 - 3)
    var allowColor: Bool = true        // 彩色弹幕；关闭时全部按白色绘制

    private enum CodingKeys: String, CodingKey {
        case isEnabled, speed, opacity, fontSize, enableTop, enableBottom, enableScroll
        case enableDeduplication, timeOffset, blockedKeywords, cacheEnabled
        case area, durationSeconds, lineHeight, followSpeed, massiveMode
        case fontWeight, showBorder, borderWidth, allowColor
    }

    // 显式保留原有构造参数，新字段均提供默认值。
    init(isEnabled: Bool, speed: Double, opacity: Double, fontSize: Double,
         enableTop: Bool, enableBottom: Bool, enableScroll: Bool, enableDeduplication: Bool,
         timeOffset: Double = 0, blockedKeywords: [String] = [], cacheEnabled: Bool = true,
         area: Double = 1.0, durationSeconds: Double = 8.0, lineHeight: Double = 1.5,
         followSpeed: Bool = true, massiveMode: Bool = false, fontWeight: Int = 5,
         showBorder: Bool = true, borderWidth: Double = 1.0, allowColor: Bool = true) {
        self.isEnabled = isEnabled
        self.speed = speed
        self.opacity = opacity
        self.fontSize = fontSize
        self.enableTop = enableTop
        self.enableBottom = enableBottom
        self.enableScroll = enableScroll
        self.enableDeduplication = enableDeduplication
        self.timeOffset = timeOffset
        self.blockedKeywords = blockedKeywords
        self.cacheEnabled = cacheEnabled
        self.area = area
        self.durationSeconds = durationSeconds
        self.lineHeight = lineHeight
        self.followSpeed = followSpeed
        self.massiveMode = massiveMode
        self.fontWeight = fontWeight
        self.showBorder = showBorder
        self.borderWidth = borderWidth
        self.allowColor = allowColor
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            isEnabled: try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true,
            speed: try values.decodeIfPresent(Double.self, forKey: .speed) ?? 1,
            opacity: try values.decodeIfPresent(Double.self, forKey: .opacity) ?? 0.8,
            fontSize: try values.decodeIfPresent(Double.self, forKey: .fontSize) ?? 16,
            enableTop: try values.decodeIfPresent(Bool.self, forKey: .enableTop) ?? true,
            enableBottom: try values.decodeIfPresent(Bool.self, forKey: .enableBottom) ?? true,
            enableScroll: try values.decodeIfPresent(Bool.self, forKey: .enableScroll) ?? true,
            enableDeduplication: try values.decodeIfPresent(Bool.self, forKey: .enableDeduplication) ?? true,
            timeOffset: try values.decodeIfPresent(Double.self, forKey: .timeOffset) ?? 0,
            blockedKeywords: try values.decodeIfPresent([String].self, forKey: .blockedKeywords) ?? [],
            cacheEnabled: try values.decodeIfPresent(Bool.self, forKey: .cacheEnabled) ?? true,
            area: try values.decodeIfPresent(Double.self, forKey: .area) ?? 1.0,
            durationSeconds: try values.decodeIfPresent(Double.self, forKey: .durationSeconds) ?? 8.0,
            lineHeight: try values.decodeIfPresent(Double.self, forKey: .lineHeight) ?? 1.5,
            followSpeed: try values.decodeIfPresent(Bool.self, forKey: .followSpeed) ?? true,
            massiveMode: try values.decodeIfPresent(Bool.self, forKey: .massiveMode) ?? false,
            fontWeight: try values.decodeIfPresent(Int.self, forKey: .fontWeight) ?? 5,
            showBorder: try values.decodeIfPresent(Bool.self, forKey: .showBorder) ?? true,
            borderWidth: try values.decodeIfPresent(Double.self, forKey: .borderWidth) ?? 1.0,
            allowColor: try values.decodeIfPresent(Bool.self, forKey: .allowColor) ?? true
        )
    }

    static let `default` = DanmakuSettings(
        isEnabled: true,
        speed: 1.0,
        opacity: 0.8,
        fontSize: 16,
        enableTop: true,
        enableBottom: true,
        enableScroll: true,
        enableDeduplication: true
    )

    static let disabled = DanmakuSettings(
        isEnabled: false,
        speed: 1.0,
        opacity: 0.8,
        fontSize: 16,
        enableTop: true,
        enableBottom: true,
        enableScroll: true,
        enableDeduplication: true
    )

    /// 恢复默认显示与样式；保留开关、屏蔽词、时间偏移与缓存偏好（Kazumi 同款语义）。
    func resettingAppearance() -> DanmakuSettings {
        var copy = self
        let base = DanmakuSettings.default
        copy.opacity = base.opacity
        copy.fontSize = base.fontSize
        copy.enableTop = base.enableTop
        copy.enableBottom = base.enableBottom
        copy.enableScroll = base.enableScroll
        copy.enableDeduplication = base.enableDeduplication
        copy.area = base.area
        copy.durationSeconds = base.durationSeconds
        copy.lineHeight = base.lineHeight
        copy.followSpeed = base.followSpeed
        copy.massiveMode = base.massiveMode
        copy.fontWeight = base.fontWeight
        copy.showBorder = base.showBorder
        copy.borderWidth = base.borderWidth
        copy.allowColor = base.allowColor
        return copy
    }
}

// MARK: - 扩展

extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - 弹幕去重

extension Array where Element == Danmaku {
    /// 合并相邻重复弹幕（参考 Kazumi 实现）
    func deduplicated(timeWindow: Double = 5.0) -> [Danmaku] {
        var result: [Danmaku] = []
        var lastSeen: [String: Double] = [:]

        for danmaku in self.sorted(by: { $0.time < $1.time }) {
            let key = danmaku.text.trimmingCharacters(in: .whitespaces)
            if let lastTime = lastSeen[key] {
                if danmaku.time - lastTime > timeWindow {
                    result.append(danmaku)
                    lastSeen[key] = danmaku.time
                }
            } else {
                result.append(danmaku)
                lastSeen[key] = danmaku.time
            }
        }

        return result
    }
}
