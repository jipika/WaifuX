import Foundation

// MARK: - DanDanPlay API 响应模型

/// 弹幕搜索响应
struct DanmakuSearchResponse: Codable {
    let hasMore: Bool
    let animes: [DanmakuAnime]
}

struct DanmakuAnime: Codable, Identifiable {
    let animeId: Int
    let animeTitle: String
    let type: String
    let typeDescription: String
    let episodes: [DanmakuEpisode]

    var id: Int { animeId }
}

struct DanmakuEpisode: Codable, Identifiable {
    let episodeId: Int
    let episodeTitle: String
    let episodeNumber: String

    var id: Int { episodeId }
}

/// 弹幕内容响应
struct DanmakuCommentResponse: Codable {
    let count: Int
    let comments: [DanmakuComment]
}

struct DanmakuComment: Codable {
    let cid: Int
    let p: String  // 格式: "时间,模式,颜色,用户ID"
    let m: String  // 弹幕内容

    /// 解析属性
    var time: Double {
        let parts = p.split(separator: ",")
        return Double(parts[safe: 0] ?? "0") ?? 0
    }

    var mode: DanmakuMode {
        let parts = p.split(separator: ",")
        let modeValue = Int(parts[safe: 1] ?? "1") ?? 1
        return DanmakuMode(rawValue: modeValue) ?? .scroll
    }

    var color: Int {
        let parts = p.split(separator: ",")
        return Int(parts[safe: 2] ?? "16777215") ?? 16777215
    }

    var userId: String {
        let parts = p.split(separator: ",")
        return String(parts[safe: 3] ?? "0")
    }
}

/// 弹幕显示模式
enum DanmakuMode: Int, Codable {
    case scroll = 1        // 从右向左滚动
    case top = 4           // 顶部固定
    case bottom = 5        // 底部固定
}

// MARK: - 内部使用的弹幕模型

struct Danmaku: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let time: Double        // 出现时间（秒）
    let mode: DanmakuMode
    let color: ColorInfo
    let userId: String

    /// 弹幕颜色信息
    struct ColorInfo: Equatable {
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

    init(text: String, time: Double, mode: DanmakuMode = .scroll, color: Int = 16777215, userId: String = "0") {
        self.text = text
        self.time = time
        self.mode = mode
        self.color = ColorInfo(hexValue: color)
        self.userId = userId
    }

    /// 从 DanDanPlay 评论创建
    init(from comment: DanmakuComment) {
        self.text = comment.m
        self.time = comment.time
        self.mode = comment.mode
        self.color = ColorInfo(hexValue: comment.color)
        self.userId = comment.userId
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

struct DanmakuSettings: Codable {
    var isEnabled: Bool
    var speed: Double        // 弹幕速度倍数 (0.5 - 2.0)
    var opacity: Double      // 弹幕透明度 (0.1 - 1.0)
    var fontSize: Double     // 字体大小 (12 - 24)
    var enableTop: Bool      // 显示顶部弹幕
    var enableBottom: Bool   // 显示底部弹幕
    var enableScroll: Bool   // 显示滚动弹幕
    var enableDeduplication: Bool  // 启用去重

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
