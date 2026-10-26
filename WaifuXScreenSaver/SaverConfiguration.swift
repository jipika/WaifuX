import Foundation

/// 屏保侧配置。
///
/// 由 App 的 `ScreenSaverService` 原子写入
/// `~/Library/Application Support/WaifuX/screensaver.json`；屏保宿主只读。
/// 设计与 MirageScreenSaver 一致：不依赖主程序运行，也不需要 IPC。
///
/// 字段同时承担"身份"职责：内容变化（换壁纸 / 改裁剪 / 改填充）会让
/// `identity` 变化，屏保据此热重载当前正在播放的画面。
struct SaverConfiguration {
    /// 渲染介质类型。Scene / Web 壁纸由 App 侧先离线烘焙成 MP4，
    /// 因此屏保只需区分"播视频"和"显示静图"。
    enum Kind: String {
        case video
        case image
    }

    let kind: Kind
    let title: String
    /// 实际参与渲染的文件（视频或静图）。
    let renderURL: URL
    /// 源文件 / 工程目录，仅用于日志。
    let sourcePath: String?
    let fps: Int
    let muted: Bool
    let playbackRate: Float
    let enableHDRVideo: Bool
    let language: String
    /// 配置快照里的每屏裁剪（key = "display-<displayID>"）。
    /// 运行期优先读 App Group 实时值，快照只是兜底。
    let cropSnapshot: [String: SaverCropSettings]
    /// 主屏对应的 crop key，供"取不到当前屏幕号"时兜底。
    let defaultCropDisplayKey: String?
    /// 内容指纹：变化才重载。
    let identity: Data
    /// 按屏壁纸表（key = "display-<displayID>"）。多屏异壁纸时每块屏的屏保进程
    /// 各取自己的条目；顶层字段保留为主屏条目，兼容尚未刷新的旧版屏保组件。
    let wallpaperEntries: [String: SaverWallpaperEntry]

    // MARK: - 加载

    static var configurationURL: URL {
        SaverHomeDirectory.url
            .appendingPathComponent("Library/Application Support/WaifuX", isDirectory: true)
            .appendingPathComponent("screensaver.json")
    }

    static let supportedVersion = 1

    /// 读取并校验配置。任一环节不满足（文件缺失 / 版本不符 / 渲染文件不存在）都返回 nil，
    /// 由视图层显示"请在 WaifuX 设置中选择屏保壁纸"。
    static func load() -> SaverConfiguration? {
        let url = configurationURL
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["version"] as? Int) == supportedVersion,
              let kindRaw = object["kind"] as? String,
              let kind = Kind(rawValue: kindRaw),
              let renderPath = object["renderPath"] as? String else {
            return nil
        }
        let renderURL = URL(fileURLWithPath: renderPath)
        guard FileManager.default.fileExists(atPath: renderURL.path) else { return nil }

        let cropSnapshot = Self.decodeCropSnapshot(object["cropByDisplay"] as? [String: Any] ?? [:])
        let wallpaperEntries = Self.decodeWallpaperEntries(object["wallpaperByDisplay"] as? [String: Any] ?? [:])
        let rawRate = (object["playbackRate"] as? NSNumber)?.floatValue ?? 1
        let playbackRate = rawRate.isFinite && rawRate > 0 ? rawRate : 1

        return SaverConfiguration(
            kind: kind,
            title: object["title"] as? String ?? "WaifuX",
            renderURL: renderURL,
            sourcePath: object["sourcePath"] as? String,
            fps: max(10, min(object["fps"] as? Int ?? 30, 60)),
            muted: object["muted"] as? Bool ?? true,
            playbackRate: playbackRate,
            enableHDRVideo: object["enableHDRVideo"] as? Bool ?? false,
            language: object["language"] as? String ?? Locale.preferredLanguages.first ?? "en",
            cropSnapshot: cropSnapshot,
            defaultCropDisplayKey: object["defaultCropDisplayKey"] as? String,
            identity: identity(of: object),
            wallpaperEntries: wallpaperEntries
        )
    }

    /// 解析出的裁剪配置：先看实时 App Group 文件，再退回配置快照，最后默认（原样铺满）。
    ///
    /// `key` 为 nil 是真实场景——屏保起屏早期 `window.screen` 还是 nil，
    /// 这时用主屏那份配置兜底，比直接退回 autoFill 更接近用户在桌面上的设置。
    func cropSettings(forDisplayKey key: String?) -> SaverCropSettings {
        if let key, let live = SaverSharedCropPrefs.settings(forDisplayKey: key) {
            return live
        }
        if let key, let snapshot = cropSnapshot[key] {
            return snapshot
        }
        if let defaultCropDisplayKey, let snapshot = cropSnapshot[defaultCropDisplayKey] {
            return snapshot
        }
        return .default
    }

    // MARK: - 按屏壁纸

    /// 解析当前屏应播放的壁纸条目：本屏条目 → 主屏条目 → 键名排序的其余条目
    /// → 顶层旧字段。条目渲染文件不存在（暂存被清 / 卷未挂载）时跳过继续回退；
    /// 顶层字段是主屏条目的旧式快照，load() 已校验其文件存在，永远兜底。
    func wallpaperEntry(forDisplayKey key: String?) -> SaverWallpaperEntry? {
        var ordered: [SaverWallpaperEntry] = []
        if let key, let entry = wallpaperEntries[key] { ordered.append(entry) }
        if let defaultCropDisplayKey, let entry = wallpaperEntries[defaultCropDisplayKey] { ordered.append(entry) }
        ordered.append(contentsOf: wallpaperEntries.sorted { $0.key < $1.key }.map(\.value))
        ordered.append(SaverWallpaperEntry(
            kind: kind, title: title, renderURL: renderURL, sourcePath: sourcePath, identity: nil
        ))
        return ordered.first { FileManager.default.fileExists(atPath: $0.renderURL.path) }
    }

    /// 当前屏实际播放内容的指纹（含回退结果）。屏保逐屏比较，变化才重载，
    /// 别的屏换壁纸不会牵连本屏重放。
    func playbackFingerprint(forDisplayKey key: String?) -> String? {
        guard let entry = wallpaperEntry(forDisplayKey: key) else { return nil }
        return entry.identity ?? identity.base64EncodedString()
    }

    /// 逐条容错解码：单屏条目损坏只跳过该屏（由取值链回退），不影响整份配置。
    private static func decodeWallpaperEntries(_ raw: [String: Any]) -> [String: SaverWallpaperEntry] {
        var entries: [String: SaverWallpaperEntry] = [:]
        for (key, value) in raw {
            guard let object = value as? [String: Any],
                  let kindRaw = object["kind"] as? String,
                  let kind = Kind(rawValue: kindRaw),
                  let renderPath = object["renderPath"] as? String else {
                continue
            }
            entries[key] = SaverWallpaperEntry(
                kind: kind,
                title: object["title"] as? String ?? "WaifuX",
                renderURL: URL(fileURLWithPath: renderPath),
                sourcePath: object["sourcePath"] as? String,
                identity: object["identity"] as? String
            )
        }
        return entries
    }

    /// 指纹 = 去掉易变字段后的配置内容。`configuredAt` 只是写入时间戳，
    /// 同一张壁纸重复写入不应触发屏保重载。
    private static func identity(of object: [String: Any]) -> Data {
        var stable = object
        stable.removeValue(forKey: "configuredAt")
        guard JSONSerialization.isValidJSONObject(stable),
              let data = try? JSONSerialization.data(withJSONObject: stable, options: [.sortedKeys]) else {
            return Data()
        }
        return data
    }

    // MARK: - 裁剪快照

    private static func decodeCropSnapshot(_ raw: [String: Any]) -> [String: SaverCropSettings] {
        guard !raw.isEmpty,
              JSONSerialization.isValidJSONObject(raw),
              let data = try? JSONSerialization.data(withJSONObject: raw) else {
            return [:]
        }
        let decoder = JSONDecoder()
        guard let decoded = try? decoder.decode([String: SaverCropSettings].self, from: data) else {
            return [:]
        }
        return decoded
    }
}

// MARK: - 按屏壁纸条目

/// `wallpaperByDisplay` 的值。多屏异壁纸时每块屏的屏保进程各自解析自己的条目；
/// 顶层字段始终保留为主屏条目，旧版屏保组件只读顶层，行为不变。
struct SaverWallpaperEntry {
    let kind: SaverConfiguration.Kind
    let title: String
    /// 实际参与渲染的文件（视频或静图）。
    let renderURL: URL
    /// 源文件 / 工程目录，仅用于日志。
    let sourcePath: String?
    /// App 侧写入的条目指纹；缺失时屏保退回整份配置指纹。
    let identity: String?
}

// MARK: - 屏保内文案

/// 屏保宿主不加载 App 的 LocalizationService，这里保留最小文案表，
/// 只覆盖"配置缺失/文件丢失"这类兜底提示。
enum SaverLocalization {
    static func string(_ key: String, language: String?) -> String {
        let preferred = (language ?? Locale.preferredLanguages.first ?? "en").lowercased()
        let table: [String: String]
        if preferred.hasPrefix("zh-hant") || preferred.hasPrefix("zh-tw") || preferred.hasPrefix("zh-hk") {
            table = traditional
        } else if preferred.hasPrefix("zh") {
            table = simplified
        } else if preferred.hasPrefix("ja") {
            table = japanese
        } else {
            table = english
        }
        return table[key] ?? english[key] ?? key
    }

    private static let simplified: [String: String] = [
        "noConfiguration": "请在 WaifuX 设置 → 屏保中选择屏保壁纸",
        "missingMedia": "屏保壁纸文件已丢失，请在 WaifuX 设置 → 屏保中重新选择",
        "unplayableVideo": "此屏保视频无法播放，请重新烘焙后再试"
    ]

    private static let traditional: [String: String] = [
        "noConfiguration": "請在 WaifuX 設定 → 螢幕保護程式選擇螢幕保護壁紙",
        "missingMedia": "螢幕保護壁紙檔案已遺失，請在 WaifuX 設定 → 螢幕保護程式中重新選擇",
        "unplayableVideo": "此螢幕保護影片無法播放，請重新烘焙後再試"
    ]

    private static let english: [String: String] = [
        "noConfiguration": "Choose a screen saver wallpaper in WaifuX Settings → Screen Saver",
        "missingMedia": "The screen saver wallpaper file is missing. Choose another one in WaifuX Settings → Screen Saver",
        "unplayableVideo": "This screen saver video cannot be played. Re-bake it and try again"
    ]

    private static let japanese: [String: String] = [
        "noConfiguration": "WaifuX 設定 → スクリーンセーバーで壁紙を選択してください",
        "missingMedia": "スクリーンセーバーの壁紙ファイルが見つかりません。WaifuX 設定で選び直してください",
        "unplayableVideo": "このスクリーンセーバー動画を再生できません。再ベイクしてお試しください"
    ]
}
