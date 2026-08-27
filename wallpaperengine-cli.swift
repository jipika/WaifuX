import CoreFoundation
import Darwin
import Foundation
import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import IOKit
import CryptoKit
import ScreenCaptureKit
import WebKit

// MARK: - NSScreen Extension
extension NSScreen {
    /// 返回稳定的屏幕标识符，用于跨模块的屏幕级状态字典 key。
    var wallpaperScreenIdentifier: String {
        if let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return screenNumber.stringValue
        }
        return localizedName + ":\(frame.origin.x):\(frame.origin.y)"
    }

    /// 与主 App `WallpaperScreenIdentity.orderedScreens` 保持一致：
    /// 主屏优先、从左到右、从上到下。CLI 索引必须与 App 侧一致，
    /// 否则 sleep/wake 后 `NSScreen.screens` 打乱会导致 Web 壁纸落到错误显示器。
    static var screensOrderedForDisplay: [NSScreen] {
        let screens = NSScreen.screens
        let mainID = NSScreen.main?.wallpaperScreenIdentifier
        return screens.sorted { lhs, rhs in
            let lhsIsMain = lhs.wallpaperScreenIdentifier == mainID
            let rhsIsMain = rhs.wallpaperScreenIdentifier == mainID
            if lhsIsMain != rhsIsMain {
                return lhsIsMain
            }
            let lx = lhs.frame.origin.x
            let rx = rhs.frame.origin.x
            if abs(lx - rx) > 0.5 {
                return lx < rx
            }
            let ly = lhs.frame.origin.y
            let ry = rhs.frame.origin.y
            if abs(ly - ry) > 0.5 {
                return lhs.frame.maxY > rhs.frame.maxY
            }
            return lhs.wallpaperScreenIdentifier < rhs.wallpaperScreenIdentifier
        }
    }
}

// MARK: - Constants
private let SOCKET_PATH = "/tmp/wallpaperengine-cli.sock"
private let PID_PATH = "/tmp/wallpaperengine-cli.pid"
private let DEBUG_LOG_PATH = "/tmp/wallpaperengine-cli-debug.log"
/// Scene/Web 截图写入；Host 会将 Web capture 转码为 canonical poster 后再同步静态目标。
private let PRIMARY_CAPTURE_PATH = "/tmp/wallpaperengine-cli-capture.png"

/// Per-screen capture paths（多屏并行壁纸避免共享文件竞争）
private func primaryCapturePath(for screen: Int) -> String {
    return "/tmp/wallpaperengine-cli-capture-s\(screen).png"
}

private func isDynamicLockScreenEnabledForCurrentLaunch() -> Bool {
    let rawValue = ProcessInfo.processInfo.environment["WAIFUX_DYNAMIC_LOCK_SCREEN_ENABLED"]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    return rawValue == "1" || rawValue == "true" || rawValue == "yes"
}

/// 与 App「系统壁纸同步」开关对齐。
/// 优先读热更新控制文件（App 改开关后立刻生效），再回退到启动环境变量；都没有则默认开启。
private let systemWallpaperSyncControlPath = "/tmp/waifux-system-wallpaper-sync.json"

private func isSystemWallpaperSyncEnabledForCurrentLaunch() -> Bool {
    if let data = try? Data(contentsOf: URL(fileURLWithPath: systemWallpaperSyncControlPath)),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        if let enabled = obj["enabled"] as? Bool {
            return enabled
        }
        if let n = obj["enabled"] as? NSNumber {
            return n.boolValue
        }
        if let s = obj["enabled"] as? String {
            let v = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return v == "1" || v == "true" || v == "yes"
        }
    }
    let rawValue = ProcessInfo.processInfo.environment["WAIFUX_SYSTEM_WALLPAPER_SYNC_ENABLED"]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    if rawValue == nil || rawValue?.isEmpty == true { return true }
    return rawValue == "1" || rawValue == "true" || rawValue == "yes"
}

private func dlog(_ msg: String) {
    let line = "[\(Date())] \(msg)\n"
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: DEBUG_LOG_PATH) {
            if let fh = FileHandle(forWritingAtPath: DEBUG_LOG_PATH) {
                _ = try? fh.seekToEnd()
                fh.write(data)
                try? fh.close()
            }
        } else {
            try? data.write(to: URL(fileURLWithPath: DEBUG_LOG_PATH), options: .atomic)
        }
    }
}

/// Scene 首帧缩略图比较（与 Web 侧逻辑一致）
private func waifuXMeanAbsDiffGrayscale(_ a: [UInt8], _ b: [UInt8]) -> Double {
    guard a.count == b.count, !a.isEmpty else { return 1 }
    var sum: Int = 0
    for i in 0..<a.count {
        sum += abs(Int(a[i]) - Int(b[i]))
    }
    return Double(sum) / Double(a.count * 255)
}

private func waifuXGrayscaleThumb(from cgImage: CGImage, dimension: Int) -> [UInt8]? {
    guard dimension > 0 else { return nil }
    let cw = dimension
    let ch = dimension
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
    guard let ctx = CGContext(
        data: nil,
        width: cw,
        height: ch,
        bitsPerComponent: 8,
        bytesPerRow: cw * 4,
        space: colorSpace,
        bitmapInfo: bitmapInfo.rawValue
    ) else { return nil }
    ctx.interpolationQuality = .low
    ctx.translateBy(x: 0, y: CGFloat(ch))
    ctx.scaleBy(x: 1, y: -1)
    ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: CGFloat(cw), height: CGFloat(ch)))
    guard let data = ctx.data else { return nil }
    let ptr = data.bindMemory(to: UInt8.self, capacity: cw * ch * 4)
    var out = [UInt8](repeating: 0, count: cw * ch)
    for y in 0..<ch {
        for x in 0..<cw {
            let i = (y * cw + x) * 4
            let r = Float(ptr[i])
            let g = Float(ptr[i + 1])
            let b = Float(ptr[i + 2])
            let gry = UInt8(min(255, max(0, 0.299 * r + 0.587 * g + 0.114 * b)))
            out[y * cw + x] = gry
        }
    }
    return out
}

// MARK: - IPC
private enum IPCCommand: String, Codable {
    case set, pause, resume, stop, capture, applyProperties, crop, audioControl, audioData
    /// Host → daemon：系统 Now Playing 元数据（低频）
    case mediaUpdate, mediaThumbnail
    /// Host → daemon：Apple Music 歌词（整首 / 当前行）；Web 只收 JSON
    case mediaLyrics, mediaLyricsLine
}

private struct IPCLyricLine: Codable {
    let start: Double
    let end: Double?
    let text: String
}

/// App 在首次 set 时把初始裁切编码为 base64 JSON 传给 CLI client。
private struct InitialWebCropPayload: Codable {
    let crop: [Double]?
    let viewport: [Double]?
    let letterboxColorHex: String?
    let cropRevision: UInt64
}

private struct IPCMessage: Codable {
    let command: IPCCommand
    let path: String?
    let screen: Int?
    let propertiesJSON: String?
    /// Web 壁纸裁切参数。均为 0...1 的 [x, y, w, h]，原点左上、y 向下。
    let crop: [Double]?
    let viewport: [Double]?
    let letterboxColorHex: String?
    /// 每屏单调递增；乱序 crop 消息会被 daemon 丢弃。
    let cropRevision: UInt64?
    /// crop 命令可选择等待响应；拖拽中的高频更新不响应，避免 socket 堆积。
    let expectsResponse: Bool?
    let muted: Bool?
    let volume: Double?
    /// WE 音频频谱（128 floats; 0..63 = L, 64..127 = R）；仅 `.audioData` 命令使用。
    let spectrum: [Float]?
    // MARK: mediaUpdate / mediaThumbnail（可选字段，其它命令忽略）
    let enabled: Bool?
    let title: String?
    let artist: String?
    let albumTitle: String?
    /// WE playback state: 0=STOPPED, 1=PLAYING, 2=PAUSED
    let state: Int?
    let position: Double?
    let duration: Double?
    let rate: Double?
    /// data URL 或空字符串
    let thumbnail: String?
    // MARK: mediaLyrics / mediaLyricsLine
    let hasLyrics: Bool?
    let songId: String?
    let storefront: String?
    let source: String?
    let lineCount: Int?
    let lines: [IPCLyricLine]?
    let index: Int?
    let text: String?
    let nextText: String?
    let previousText: String?
    let start: Double?
    let end: Double?
    let progress: Double?
    let elapsedTime: Double?
    let hasLine: Bool?

    init(
        command: IPCCommand,
        path: String?,
        screen: Int?,
        propertiesJSON: String? = nil,
        crop: [Double]? = nil,
        viewport: [Double]? = nil,
        letterboxColorHex: String? = nil,
        cropRevision: UInt64? = nil,
        expectsResponse: Bool? = nil,
        muted: Bool? = nil,
        volume: Double? = nil,
        spectrum: [Float]? = nil,
        enabled: Bool? = nil,
        title: String? = nil,
        artist: String? = nil,
        albumTitle: String? = nil,
        state: Int? = nil,
        position: Double? = nil,
        duration: Double? = nil,
        rate: Double? = nil,
        thumbnail: String? = nil,
        hasLyrics: Bool? = nil,
        songId: String? = nil,
        storefront: String? = nil,
        source: String? = nil,
        lineCount: Int? = nil,
        lines: [IPCLyricLine]? = nil,
        index: Int? = nil,
        text: String? = nil,
        nextText: String? = nil,
        previousText: String? = nil,
        start: Double? = nil,
        end: Double? = nil,
        progress: Double? = nil,
        elapsedTime: Double? = nil,
        hasLine: Bool? = nil
    ) {
        self.command = command
        self.path = path
        self.screen = screen
        self.propertiesJSON = propertiesJSON
        self.crop = crop
        self.viewport = viewport
        self.letterboxColorHex = letterboxColorHex
        self.cropRevision = cropRevision
        self.expectsResponse = expectsResponse
        self.muted = muted
        self.volume = volume
        self.spectrum = spectrum
        self.enabled = enabled
        self.title = title
        self.artist = artist
        self.albumTitle = albumTitle
        self.state = state
        self.position = position
        self.duration = duration
        self.rate = rate
        self.thumbnail = thumbnail
        self.hasLyrics = hasLyrics
        self.songId = songId
        self.storefront = storefront
        self.source = source
        self.lineCount = lineCount
        self.lines = lines
        self.index = index
        self.text = text
        self.nextText = nextText
        self.previousText = previousText
        self.start = start
        self.end = end
        self.progress = progress
        self.elapsedTime = elapsedTime
        self.hasLine = hasLine
    }
}


// MARK: - Original Wallpaper Persistence Models
private struct SavedOriginalWallpaperState: Codable {
    let configs: [ScreenWallpaperConfig]
    let savedAt: Date
    let appVersion: String
}

private struct ScreenWallpaperConfig: Codable {
    let screenID: String
    let screenName: String
    let wallpaperURL: String
    let isMainScreen: Bool
}

// MARK: - Wallpaper Type Detection & PKG Extraction
private func isWebWallpaper(path: String) -> Bool {
    let type = detectWallpaperProjectType(path: path)
    return type?.lowercased() == "web"
}

private func detectWallpaperProjectType(path: String) -> String? {
    let fm = FileManager.default
    let url = URL(fileURLWithPath: path)
    var contentDir = url

    // 1. 如果是 .pkg，先解压到临时目录再检查
    if url.pathExtension.lowercased() == "pkg" {
        guard let extracted = extractPKG(at: url) else { return nil }
        contentDir = extracted
    } else {
        contentDir = URL(fileURLWithPath: resolveSteamWorkshopDirectoryIfNeeded(path))
    }

    // 2. 读取 project.json
    let projectJSON = contentDir.appendingPathComponent("project.json")
    if fm.fileExists(atPath: projectJSON.path),
       let data = try? Data(contentsOf: projectJSON),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        // 优先使用显式 type
        if let type = json["type"] as? String, !type.isEmpty {
            return type
        }
        // 启发式推断：通过 file 字段扩展名
        if let file = json["file"] as? String {
            let ext = (file as NSString).pathExtension.lowercased()
            if ext == "html" || ext == "htm" { return "web" }
            if ext == "json" {
                let lower = file.lowercased()
                if lower.contains("scene") { return "scene" }
            }
            if ["mp4", "mov", "webm", "avi"].contains(ext) { return "video" }
        }
        // 有 project.json 但无明确 type/file → 按目录内容推断
        if let entries = try? fm.contentsOfDirectory(at: contentDir, includingPropertiesForKeys: nil) {
            let names = entries.map { $0.lastPathComponent.lowercased() }
            let exts = entries.map { $0.pathExtension.lowercased() }
            if exts.contains("html") || exts.contains("htm") { return "web" }
            if names.contains(where: { $0.hasSuffix(".scene.pkg") || $0 == "scene.pkg" }) { return "scene" }
            if exts.contains("mp4") || exts.contains("mov") || exts.contains("webm") { return "video" }
            if exts.contains("pkg") {
                // 进一步检查 pkg 内容（不解压，只看文件名是否含 scene）
                if let pkgEntry = entries.first(where: { $0.pathExtension.lowercased() == "pkg" }),
                   let pkgEntries = try? fm.contentsOfDirectory(at: pkgEntry, includingPropertiesForKeys: nil) {
                    let pkgNames = pkgEntries.map { $0.lastPathComponent.lowercased() }
                    if pkgNames.contains(where: { $0.contains("scene") }) { return "scene" }
                }
            }
        }
        return nil
    }

    // 3. 无 project.json：按目录内容推断
    if let entries = try? fm.contentsOfDirectory(at: contentDir, includingPropertiesForKeys: nil) {
        let exts = entries.map { $0.pathExtension.lowercased() }
        if exts.contains("html") || exts.contains("htm") { return "web" }
        if exts.contains("mp4") || exts.contains("mov") || exts.contains("webm") { return "video" }
        if exts.contains("pkg") { return "scene" }
        if exts.contains("json") {
            if entries.contains(where: { $0.lastPathComponent.lowercased().contains("scene") }) {
                return "scene"
            }
        }
    }
    return nil
}

private func extractPKG(at url: URL) -> URL? {
    let fm = FileManager.default
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("wallpaperengine_pkg_\(url.deletingPathExtension().lastPathComponent)")
    try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    process.arguments = ["-o", "-q", url.path, "-d", tempDir.path]

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus == 0 {
            return tempDir
        }
        let err = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        print("[extractPKG] unzip failed: \(err)")
    } catch {
        print("[extractPKG] Exception: \(error)")
    }
    return nil
}

/// SteamCMD 解压目录常见为 `.../431960/<id>/`，真实 `project.json` 可能在唯一子目录内；与 App 内 `WorkshopService.resolveWallpaperEngineProjectRoot` 行为对齐。
private func resolveSteamWorkshopDirectoryIfNeeded(_ path: String) -> String {
    let url = URL(fileURLWithPath: path)
    var isDir: ObjCBool = false
    let fm = FileManager.default
    guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
        return path
    }
    return resolveWEWorkshopNestedRoot(url, depthLeft: 8, fm: fm).path
}

private func resolveWEWorkshopNestedRoot(_ url: URL, depthLeft: UInt, fm: FileManager) -> URL {
    if depthLeft == 0 { return url }
    if fm.fileExists(atPath: url.appendingPathComponent("project.json").path) { return url }
    guard let entries = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
        return url
    }
    if entries.contains(where: { $0.pathExtension.lowercased() == "pkg" }) { return url }
    if entries.contains(where: { ["mp4", "mov", "webm"].contains($0.pathExtension.lowercased()) }) { return url }
    var childDirs: [URL] = []
    for entry in entries {
        var d: ObjCBool = false
        guard fm.fileExists(atPath: entry.path, isDirectory: &d), d.boolValue else { continue }
        childDirs.append(entry)
    }
    if childDirs.count == 1 {
        return resolveWEWorkshopNestedRoot(childDirs[0], depthLeft: depthLeft - 1, fm: fm)
    }
    if childDirs.count > 1 {
        let withProject = childDirs
            .filter { fm.fileExists(atPath: $0.appendingPathComponent("project.json").path) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        if let first = withProject.first {
            return resolveWEWorkshopNestedRoot(first, depthLeft: depthLeft - 1, fm: fm)
        }
    }
    return url
}


/// Steam 布局：`.../steamapps/workshop/content/431960/<workshopId>/.../project.json`。
/// Web 壁纸的 HTML 常在子目录，但用 `../` 引用与 `<workshopId>` 同级的资源；`loadFileURL` 的 readAccess 仅设 project 目录会导致 WebKit 拒读，表现为贴图/脚本缺失、画面残缺。
private func steamWorkshopContentInstallRootIfApplicable(forProjectDir projectDir: URL) -> URL? {
    let comps = projectDir.standardizedFileURL.pathComponents
    guard let idx = comps.firstIndex(of: "431960"), idx + 1 < comps.count else {
        return nil
    }
    let prefix = comps.prefix(through: idx + 1)
    let path = "/" + prefix.dropFirst().joined(separator: "/")
    var isDir: ObjCBool = false
    let url = URL(fileURLWithPath: path, isDirectory: true)
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
        return nil
    }
    return url
}

/// Web 本地文件可读范围：`SteamCMD` 解压的 workshop 根，否则退化为工程目录（本地 .pkg 解压或扁平导入）。
private func webWallpaperFileReadAccessURL(projectContentDir: URL, cliWallpaperPath: String) -> URL {
    if cliWallpaperPath.contains("/steamapps/workshop/content/"),
       let root = steamWorkshopContentInstallRootIfApplicable(forProjectDir: projectContentDir) {
        return root
    }
    return projectContentDir
}

/// 解析 Workshop Web 壁纸的依赖路径。支持同级 workshop 目录与向上回溯 steamapps/workshop/content/431960。
private func resolveWallpaperDependencyPath(from contentDir: URL, dependencyID: String) -> URL? {
    let fm = FileManager.default
    // 1. 同级 workshop 目录（如 .../431960/<id>/ 的同级）
    let candidate1 = contentDir.deletingLastPathComponent().appendingPathComponent(dependencyID)
    if fm.fileExists(atPath: candidate1.path) { return candidate1 }

    // 2. 向上回溯寻找 steamapps/workshop/content/431960/<dependencyID>
    var current = contentDir
    for _ in 0..<6 {
        current = current.deletingLastPathComponent()
        let candidate = current.appendingPathComponent("steamapps/workshop/content/431960/\(dependencyID)")
        if fm.fileExists(atPath: candidate.path) { return candidate }
    }
    return nil
}

/// 将主壁纸目录与依赖目录合并到临时目录（主壁纸文件覆盖依赖）。
/// 返回临时目录 URL；失败时返回 nil。
private func mergeWallpaperWithDependency(contentDir: URL, dependencyDir: URL) -> URL? {
    let fm = FileManager.default
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("wallpaperengine_merged_\(contentDir.lastPathComponent)_\(dependencyDir.lastPathComponent)_\(UUID().uuidString.prefix(8))")
    do {
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        // 先复制依赖内容
        if let depEntries = try? fm.contentsOfDirectory(at: dependencyDir, includingPropertiesForKeys: nil) {
            for entry in depEntries {
                let dest = tempDir.appendingPathComponent(entry.lastPathComponent)
                if !fm.fileExists(atPath: dest.path) {
                    try? fm.copyItem(at: entry, to: dest)
                }
            }
        }
        // 再复制主壁纸内容（覆盖依赖同名文件）
        if let entries = try? fm.contentsOfDirectory(at: contentDir, includingPropertiesForKeys: nil) {
            for entry in entries {
                let dest = tempDir.appendingPathComponent(entry.lastPathComponent)
                if fm.fileExists(atPath: dest.path) {
                    try? fm.removeItem(at: dest)
                }
                try? fm.copyItem(at: entry, to: dest)
            }
        }
        dlog("[mergeWallpaperWithDependency] Merged to \(tempDir.path)")
        return tempDir
    } catch {
        dlog("[mergeWallpaperWithDependency] Failed: \(error)")
        return nil
    }
}

private func resolveWebWallpaperEntry(path: String) -> (baseURL: URL, indexFile: String)? {
    let url = URL(fileURLWithPath: path)
    var contentDir = url
    if url.pathExtension.lowercased() == "pkg" {
        guard let extracted = extractPKG(at: url) else { return nil }
        contentDir = extracted
    } else {
        contentDir = URL(fileURLWithPath: resolveSteamWorkshopDirectoryIfNeeded(path))
    }
    let projectJSON = contentDir.appendingPathComponent("project.json")
    guard FileManager.default.fileExists(atPath: projectJSON.path),
          let data = try? Data(contentsOf: projectJSON),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    let file = json["file"] as? String ?? "index.html"

    // 处理依赖：Web 预设（preset）常引用另一个壁纸作为依赖
    if let dependency = json["dependency"] as? String, !dependency.isEmpty {
        if let depDir = resolveWallpaperDependencyPath(from: contentDir, dependencyID: dependency) {
            if let merged = mergeWallpaperWithDependency(contentDir: contentDir, dependencyDir: depDir) {
                let mergedIndex = merged.appendingPathComponent(file)
                if FileManager.default.fileExists(atPath: mergedIndex.path) {
                    return (merged, file)
                }
                // 若指定文件不存在，尝试 fallback 到 index.html
                let fallbackIndex = merged.appendingPathComponent("index.html")
                if FileManager.default.fileExists(atPath: fallbackIndex.path) {
                    return (merged, "index.html")
                }
                // fallback 失败，返回原始目录（至少主壁纸自己的文件存在）
                dlog("[resolveWebWallpaperEntry] Merged dir missing \(file) and index.html, falling back to original dir")
                try? FileManager.default.removeItem(at: merged)
            }
        } else {
            dlog("[resolveWebWallpaperEntry] Dependency \(dependency) not found for \(contentDir.path)")
        }
    }

    return (contentDir, file)
}

/// 读取 Wallpaper Engine `project.json` 中 `general.properties`，供 `wallpaperPropertyListener.applyUserProperties` 注入（背景 schemecolor、滑块 x/y/z 等）。
private func readWebWallpaperUserPropertiesJSON(contentDir: URL) -> String? {
    let projectURL = contentDir.appendingPathComponent("project.json")
    guard let data = try? Data(contentsOf: projectURL),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let general = json["general"] as? [String: Any],
          let props = general["properties"] as? [String: Any],
          !props.isEmpty,
          let out = try? JSONSerialization.data(withJSONObject: props, options: []),
          let str = String(data: out, encoding: .utf8) else {
        return nil
    }
    return str
}

// MARK: - Web Renderer Bridge (WKWebView-based HTML wallpaper)
private final class WebRendererBridge: NSObject, WKNavigationDelegate {
    static let shared = WebRendererBridge()
    static let offlineBakeScreen = -1

    /// 对齐 Wallpaper Engine Web 文档：`wallpaperRegisterAudioListener`、Media Integration
    /// 注册函数与 `wallpaperMediaIntegration` 命名空间。
    /// 音频由 Host `__wxUpdateAudioBuf` 注入；媒体元数据由 `__wxPushMediaUpdate` / `__wxPushMediaThumbnail` 注入。
    /// 注册 listener 时回放最近一次状态，避免壁纸晚于推送注册而丢首帧。
    private static let wallpaperEngineWebAPIShim = WKUserScript(
        source: """
        (function() {
          try {
            window.wallpaperMediaIntegration = {
              playback: { PLAYING: 1, PAUSED: 2, STOPPED: 0 }
            };
            var __wxAudioCbs = [];
            var __wxAudioBuf = new Float32Array(128);
            var __wxAudioEnabled = false;
            var __wxLastAudioAt = 0;
            window.wallpaperRegisterAudioListener = function(cb) {
              if (typeof cb === 'function') __wxAudioCbs.push(cb);
            };
            window.__wxUpdateAudioBuf = function(arr) {
              if (arr && arr.length) {
                __wxAudioEnabled = true;
                __wxLastAudioAt = Date.now();
                for (var i = 0; i < __wxAudioBuf.length && i < arr.length; i++) {
                  __wxAudioBuf[i] = arr[i];
                }
                for (var j = 0; j < __wxAudioCbs.length; j++) {
                  try { __wxAudioCbs[j](__wxAudioBuf); } catch (e) {}
                }
              }
            };
            setInterval(function() {
              if (!__wxAudioEnabled || Date.now() - __wxLastAudioAt > 500) {
                for (var i = 0; i < __wxAudioBuf.length; i++) __wxAudioBuf[i] = 0;
              }
              for (var j = 0; j < __wxAudioCbs.length; j++) {
                try { __wxAudioCbs[j](__wxAudioBuf); } catch (e) {}
              }
            }, 33);

            // ---- Media Integration ----
            var __wxMedia = {
              status: [], properties: [], thumbnail: [], playback: [], timeline: [], lyrics: [], lyricsLine: []
            };
            var __wxMediaState = {
              enabled: false,
              title: "",
              artist: "",
              albumTitle: "",
              state: 0,
              position: 0,
              duration: 0,
              rate: 1,
              thumbnail: "",
              lyrics: null,
              lyricsLine: null
            };
            function __wxFire(list, payload) {
              for (var i = 0; i < list.length; i++) {
                try { list[i](payload); } catch (e) {}
              }
            }
            window.wallpaperRegisterMediaStatusListener = function(cb) {
              if (typeof cb !== 'function') return;
              __wxMedia.status.push(cb);
              try { cb({ enabled: !!__wxMediaState.enabled }); } catch (e) {}
            };
            window.wallpaperRegisterMediaPropertiesListener = function(cb) {
              if (typeof cb !== 'function') return;
              __wxMedia.properties.push(cb);
              try {
                cb({
                  title: __wxMediaState.title || "",
                  artist: __wxMediaState.artist || "",
                  albumTitle: __wxMediaState.albumTitle || "",
                  subTitle: __wxMediaState.artist || ""
                });
              } catch (e) {}
            };
            window.wallpaperRegisterMediaThumbnailListener = function(cb) {
              if (typeof cb !== 'function') return;
              __wxMedia.thumbnail.push(cb);
              try { cb({ thumbnail: __wxMediaState.thumbnail || "" }); } catch (e) {}
            };
            window.wallpaperRegisterMediaPlaybackListener = function(cb) {
              if (typeof cb !== 'function') return;
              __wxMedia.playback.push(cb);
              try { cb({ state: __wxMediaState.state|0 }); } catch (e) {}
            };
            window.wallpaperRegisterMediaTimelineListener = function(cb) {
              if (typeof cb !== 'function') return;
              __wxMedia.timeline.push(cb);
              try {
                cb({
                  position: __wxMediaState.position||0,
                  duration: __wxMediaState.duration||0
                });
              } catch (e) {}
            };
            window.wallpaperRegisterMediaLyricsListener = function(cb) {
              if (typeof cb !== 'function') return;
              __wxMedia.lyrics.push(cb);
              try { if (__wxMediaState.lyrics) cb(__wxMediaState.lyrics); } catch (e) {}
            };
            window.wallpaperRegisterMediaLyricsLineListener = function(cb) {
              if (typeof cb !== 'function') return;
              __wxMedia.lyricsLine.push(cb);
              try { if (__wxMediaState.lyricsLine) cb(__wxMediaState.lyricsLine); } catch (e) {}
            };
            // UTF-8 安全：JSON.parse(atob(b64)) 会把多字节中文解成 Latin-1 乱码。
            // 正确：atob → 字节数组 → TextDecoder('utf-8') → JSON.parse
            window.__wxParseB64JSON = function(b64) {
              if (!b64) return null;
              try {
                var bin = atob(b64);
                var bytes = new Uint8Array(bin.length);
                for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i) & 0xff;
                var text = (typeof TextDecoder !== 'undefined')
                  ? new TextDecoder('utf-8').decode(bytes)
                  : decodeURIComponent(escape(bin));
                return JSON.parse(text);
              } catch (e) {
                try { return JSON.parse(atob(b64)); } catch (e2) { return null; }
              }
            };
            // Host 注入：整包媒体状态
            window.__wxPushMediaUpdate = function(obj) {
              if (!obj || typeof obj !== 'object') return;
              if (typeof obj.enabled === 'boolean') __wxMediaState.enabled = obj.enabled;
              if (typeof obj.title === 'string') __wxMediaState.title = obj.title;
              if (typeof obj.artist === 'string') __wxMediaState.artist = obj.artist;
              if (typeof obj.albumTitle === 'string') __wxMediaState.albumTitle = obj.albumTitle;
              if (typeof obj.state === 'number') __wxMediaState.state = obj.state;
              if (typeof obj.position === 'number') __wxMediaState.position = obj.position;
              if (typeof obj.duration === 'number') __wxMediaState.duration = obj.duration;
              if (typeof obj.rate === 'number') __wxMediaState.rate = obj.rate;
              __wxFire(__wxMedia.status, { enabled: !!__wxMediaState.enabled });
              __wxFire(__wxMedia.properties, {
                title: __wxMediaState.title || "",
                artist: __wxMediaState.artist || "",
                albumTitle: __wxMediaState.albumTitle || "",
                subTitle: __wxMediaState.artist || ""
              });
              __wxFire(__wxMedia.playback, { state: __wxMediaState.state|0 });
              __wxFire(__wxMedia.timeline, {
                position: __wxMediaState.position||0,
                duration: __wxMediaState.duration||0
              });
            };
            window.__wxPushMediaThumbnail = function(obj) {
              if (!obj || typeof obj !== 'object') return;
              __wxMediaState.thumbnail = (typeof obj.thumbnail === 'string') ? obj.thumbnail : "";
              __wxFire(__wxMedia.thumbnail, { thumbnail: __wxMediaState.thumbnail });
            };
            window.__wxPushMediaLyrics = function(obj) {
              if (!obj || typeof obj !== 'object') return;
              __wxMediaState.lyrics = obj;
              __wxFire(__wxMedia.lyrics, obj);
            };
            window.__wxPushMediaLyricsLine = function(obj) {
              if (!obj || typeof obj !== 'object') return;
              __wxMediaState.lyricsLine = obj;
              __wxFire(__wxMedia.lyricsLine, obj);
            };
          } catch (e) {}
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false
    )

    /// `file://` 壁纸常见兼容问题：
    /// 1) Spine 等库对 `HTMLImageElement` 设置 `crossOrigin = "anonymous"`，WebKit 在本地文件场景下会拒绝加载同目录纹理 → 画面空白。
    /// 2) 部分 Workshop 脚本用 `XMLHttpRequest` / `fetch()` 读相对路径 atlas、JSON、`.splat` 等资源；
    ///    WebKit 成功读取 `file://` 时常返回 status=0，部分脚本会将其误判为加载失败。
    ///    尤其是 `fetch(new URL("test.splat", location.href))` 传入的是 URL 对象：
    ///    旧兼容层只识别 string / Request.url，漏掉了 URL.href，导致仍走原生 fetch。
    ///    对原生 XHR 及 fetch 回退路径都将成功的本地 status=0 规范成 200。
    private static let localFileCompatScript = WKUserScript(
        source: """
        (function() {
          try {
            if (location.protocol !== "file:") return;

            function resolveFetchURL(input) {
              if (typeof input === "string") return input;
              if (!input) return "";
              // URL 用 .href；Request 用 .url
              if (typeof input.href === "string" && input.href) return input.href;
              if (typeof input.url === "string" && input.url) return input.url;
              try { return String(input); } catch (e) { return ""; }
            }

            function isLocalNonHTTPURL(url) {
              if (!url) return false;
              var lower = String(url).toLowerCase();
              if (lower.indexOf("http:") === 0 || lower.indexOf("https:") === 0) return false;
              if (lower.indexOf("data:") === 0 || lower.indexOf("blob:") === 0) return false;
              // 相对路径 / file:// / 其他本地 scheme
              return true;
            }

            var proto = HTMLImageElement.prototype;
            var srcDesc = Object.getOwnPropertyDescriptor(proto, "src");
            if (srcDesc && srcDesc.set) {
              Object.defineProperty(proto, "src", {
                set: function(value) {
                  try {
                    var s = String(value || "");
                    if (isLocalNonHTTPURL(s)) {
                      this.removeAttribute("crossorigin");
                    }
                  } catch (e) {}
                  srcDesc.set.call(this, value);
                },
                get: srcDesc.get,
                configurable: true
                });
            }

            // WebKit 会让成功的 file:// XMLHttpRequest 保持 status=0。Spine 等
            // Workshop runtime 常直接判断 `xhr.status !== 200`，导致存在的 atlas
            // 被误报为缺失。记录 open() 的本地地址，再仅在请求完成时规范该状态。
            var xhrProto = window.XMLHttpRequest && window.XMLHttpRequest.prototype;
            if (xhrProto) {
              var originalOpen = xhrProto.open;
              if (typeof originalOpen === "function") {
                xhrProto.open = function(method, url) {
                  try {
                    this.__wxLocalFileRequest = isLocalNonHTTPURL(resolveFetchURL(url));
                  } catch (e) {}
                  return originalOpen.apply(this, arguments);
                };
              }
              var statusDesc = Object.getOwnPropertyDescriptor(xhrProto, "status");
              if (statusDesc && statusDesc.get) {
                Object.defineProperty(xhrProto, "status", {
                  get: function() {
                    var status = statusDesc.get.call(this);
                    try {
                      if (status === 0
                        && this.__wxLocalFileRequest
                        && this.readyState === XMLHttpRequest.DONE) {
                        return 200;
                      }
                    } catch (e) {}
                    return status;
                  },
                  configurable: true
                });
              }
            }

            var origFetch = window.fetch;
            if (typeof origFetch === "function") {
              window.fetch = function(input, init) {
                var url = resolveFetchURL(input);
                if (isLocalNonHTTPURL(url)) {
                  return new Promise(function(resolve, reject) {
                    try {
                      var xhr = new XMLHttpRequest();
                      // 显式串化，避免某些 WebKit 对 URL 对象 open 行为不一致
                      xhr.open("GET", String(url), true);
                      xhr.responseType = "arraybuffer";
                      xhr.onload = function() {
                        // file:// 成功时常为 status 0；部分环境也可能给 200
                        if (xhr.status === 200 || xhr.status === 0) {
                          var headers = new Headers();
                          try {
                            var contentType = xhr.getResponseHeader("Content-Type");
                            if (contentType) headers.set("Content-Type", contentType);
                            var contentLength = xhr.getResponseHeader("Content-Length");
                            if (contentLength) headers.set("Content-Length", contentLength);
                          } catch (e) {}
                          // 无 Content-Type 时给二进制默认值，避免部分库误判
                          if (!headers.has("Content-Type")) {
                            headers.set("Content-Type", "application/octet-stream");
                          }
                          var body = xhr.response || new ArrayBuffer(0);
                          if (!headers.has("Content-Length") && body && typeof body.byteLength === "number") {
                            headers.set("Content-Length", String(body.byteLength));
                          }
                          resolve(new Response(body, {
                            status: 200,
                            statusText: "OK",
                            headers: headers
                          }));
                        } else {
                          reject(new Error("HTTP " + xhr.status + " Unable to load " + url));
                        }
                      };
                      xhr.onerror = function() {
                        reject(new Error("0 Unable to load " + url));
                      };
                      xhr.onabort = function() {
                        reject(new Error("Aborted loading " + url));
                      };
                      xhr.send();
                    } catch (e) {
                      reject(e);
                    }
                  });
                }
                return origFetch.call(this, input, init);
              };
            }
          } catch (e) {}
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false
    )

    /// 鼠标事件桥：Swift 侧通过全局事件监听捕获鼠标，再经 JS 注入模拟进 WebView。
    /// 解决 macOS Finder 桌面图标层遮挡 desktopWindow 层级窗口导致点击/移动无法到达 WKWebView 的问题。
    private static let mouseEventBridgeScript = WKUserScript(
        source: """
        (function() {
          if (window.__wxMouseBridge) return;
          window.__wxMouseBridge = {
            lastDownTarget: null,
            dispatch: function(type, x, y, button, deltaX, deltaY) {
              var el = document.elementFromPoint(x, y);
              if (!el) el = document.documentElement;
              if (type === 'wheel') {
                var event = new WheelEvent('wheel', {
                  clientX: x, clientY: y,
                  deltaX: deltaX || 0, deltaY: deltaY || 0,
                  bubbles: true, cancelable: true, view: window
                });
                el.dispatchEvent(event);
                return;
              }
              var mouseInit = {
                clientX: x,
                clientY: y,
                screenX: x,
                screenY: y,
                bubbles: true,
                cancelable: true,
                button: button || 0,
                buttons: type === 'mouseup' ? 0 : 1,
                view: window
              };
              var pointerMap = {
                mousemove: 'pointermove',
                mousedown: 'pointerdown',
                mouseup: 'pointerup'
              };
              var pointerType = pointerMap[type];
              if (pointerType && typeof PointerEvent === 'function') {
                var pointerEvent = new PointerEvent(pointerType, Object.assign({}, mouseInit, {
                  pointerId: 1,
                  pointerType: 'mouse',
                  isPrimary: true,
                  width: 1,
                  height: 1,
                  pressure: type === 'mouseup' ? 0 : (type === 'mousedown' ? 0.5 : 0),
                  tangentialPressure: 0,
                  tiltX: 0,
                  tiltY: 0,
                  twist: 0
                }));
                el.dispatchEvent(pointerEvent);
              }
              var event = new MouseEvent(type, mouseInit);
              el.dispatchEvent(event);
              if (type === 'mousedown') { this.lastDownTarget = el; }
              if (type === 'mouseup' && this.lastDownTarget) {
                var clickEvent = new MouseEvent('click', {
                  clientX: x, clientY: y,
                  bubbles: true, cancelable: true,
                  button: button || 0, view: window
                });
                this.lastDownTarget.dispatchEvent(clickEvent);
                this.lastDownTarget = null;
              }
            }
          };
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false
    )

    /// Offline bake 虚拟时钟：把动画时间与墙钟解耦。
    ///
    /// 关键：Spine 等用 **rAF 回调参数 timestamp**（不是 performance.now）算 delta。
    /// 因此 documentStart 即包装 rAF：仍走浏览器调度，但回调拿到的是虚拟 contentMs。
    /// - setContentTime 推进 contentMs 后，下一次真实 rAF 看到非零 dt → 动画前进一步
    /// - 抓帧等待期间 contentMs 不变 → 多次 rAF 的 dt=0 → 动画冻结，不会超速
    /// - 同时对齐 performance.now / Date.now / timer / media
    private static let offlineBakeClockScript = WKUserScript(
        source: """
        (function() {
          'use strict';
          if (window.__wxBakeClock) return;
          var contentMs = 0;
          var startMs = 0;
          /// Real wall epoch ms corresponding to contentMs==startMs (Date.now must stay epoch-based).
          var epochAtStart = 0;
          var running = false;
          var timerId = 1;
          var timers = Object.create(null);
          var origRAF = window.requestAnimationFrame ? window.requestAnimationFrame.bind(window) : null;
          var origCAF = window.cancelAnimationFrame ? window.cancelAnimationFrame.bind(window) : null;
          var origSTO = window.setTimeout.bind(window);
          var origCTO = window.clearTimeout.bind(window);
          var origDateNow = Date.now.bind(Date);
          var origPerfNow = (window.performance && performance.now)
            ? performance.now.bind(performance) : function() { return origDateNow(); };
          var videoTargets = typeof WeakMap === 'function' ? new WeakMap() : null;

          function nowMs() {
            return running ? contentMs : origPerfNow();
          }

          function epochNowMs() {
            return running ? (epochAtStart + (contentMs - startMs)) : origDateNow();
          }

          function flushTimers() {
            var ids = Object.keys(timers);
            for (var i = 0; i < ids.length; i++) {
              var id = ids[i];
              var t = timers[id];
              if (!t) continue;
              if (contentMs + 1e-6 < t.fireAt) continue;
              try { t.fn.apply(null, t.args || []); } catch (e) {}
              if (t.interval > 0) {
                t.fireAt = contentMs + t.interval;
                while (t.fireAt <= contentMs) t.fireAt += t.interval;
              } else {
                delete timers[id];
              }
            }
          }

          function waitForVideoFrame(el) {
            return new Promise(function(resolve) {
              var finished = false;
              var timeout = origSTO(finish, 800);
              function finish() {
                if (finished) return;
                finished = true;
                try { origCTO(timeout); } catch (e) {}
                resolve();
              }
              try {
                if (typeof el.requestVideoFrameCallback === 'function') {
                  el.requestVideoFrameCallback(function() { finish(); });
                  return;
                }
              } catch (e) {}
              if (origRAF) {
                origRAF(function() { finish(); });
              } else {
                origSTO(finish, 0);
              }
            });
          }

          function seekVideo(el, target) {
            return new Promise(function(resolve) {
              var finished = false;
              var timeout = origSTO(finish, 1200);
              function finish() {
                if (finished) return;
                finished = true;
                try { origCTO(timeout); } catch (e) {}
                try { el.removeEventListener('seeked', onSeeked); } catch (e) {}
                waitForVideoFrame(el).then(resolve, resolve);
              }
              function onSeeked() { finish(); }
              try {
                el.pause();
                if (!isFinite(el.duration) || el.duration <= 0) {
                  resolve();
                  return;
                }
                if (isFinite(el.currentTime)
                    && Math.abs(el.currentTime - target) <= 0.0005
                    && !el.seeking) {
                  finish();
                  return;
                }
                el.addEventListener('seeked', onSeeked, { once: true });
                el.currentTime = target;
                if (!el.seeking
                    && isFinite(el.currentTime)
                    && Math.abs(el.currentTime - target) <= 0.0005) {
                  finish();
                }
              } catch (e) {
                resolve();
              }
            });
          }

          function lastVideoTarget(el) {
            try {
              return videoTargets ? videoTargets.get(el) : el.__wxBakeLastTarget;
            } catch (e) {
              return undefined;
            }
          }

          function rememberVideoTarget(el, target) {
            try {
              if (videoTargets) videoTargets.set(el, target);
              else el.__wxBakeLastTarget = target;
            } catch (e) {}
          }

          function playVideoUntil(el, target) {
            return new Promise(function(resolve) {
              var finished = false;
              var timeout = origSTO(finish, 1800);
              function finish() {
                if (finished) return;
                finished = true;
                try { origCTO(timeout); } catch (e) {}
                try { el.pause(); } catch (e) {}
                rememberVideoTarget(el, target);
                waitForVideoFrame(el).then(resolve, resolve);
              }
              function poll() {
                if (finished) return;
                try {
                  if (isFinite(el.currentTime) && el.currentTime + 0.0005 >= target) {
                    finish();
                    return;
                  }
                } catch (e) {}
                if (origRAF) origRAF(poll);
                else origSTO(poll, 8);
              }
              try {
                el.playbackRate = 1;
                var p = el.play();
                if (p && typeof p.catch === 'function') p.catch(function(){});
              } catch (e) {}
              poll();
            });
          }

          function synchronizeVideo(el, target) {
            var prior = lastVideoTarget(el);
            var current = NaN;
            try { current = el.currentTime; } catch (e) {}
            // Seek only for the first capture, a loop/source reset, or a large drift.
            // Every regular next frame stays on the decoder's sequential playback path.
            var needsSeek = !isFinite(prior)
              || target + 0.001 < prior
              || !isFinite(current)
              || Math.abs(current - prior) > 0.12;
            if (needsSeek) {
              return seekVideo(el, target).then(function() {
                rememberVideoTarget(el, target);
              });
            }
            return playVideoUntil(el, target);
          }

          function syncMedia() {
            var sec = (contentMs - startMs) / 1000.0;
            var waits = [];
            try {
              var nodes = document.querySelectorAll('video,audio');
              for (var i = 0; i < nodes.length; i++) {
                var el = nodes[i];
                try {
                  var target = (isFinite(el.duration) && el.duration > 0)
                    ? sec % el.duration
                    : sec;
                  if (el.tagName === 'VIDEO') {
                    waits.push(synchronizeVideo(el, target));
                  } else {
                    el.pause();
                    if (!isFinite(el.currentTime) || Math.abs(el.currentTime - target) > 0.0005) {
                      el.currentTime = target;
                    }
                  }
                } catch (e) {}
              }
            } catch (e) {}
            return Promise.all(waits);
          }

          // Always wrap rAF so bake mode can inject virtual timestamps.
          // Before enable: pass browser timestamp through. After: pass contentMs.
          if (origRAF) {
            window.requestAnimationFrame = function(cb) {
              return origRAF(function(realT) {
                var t = running ? contentMs : realT;
                try { cb(t); } catch (e) {}
              });
            };
          }
          if (origCAF) {
            window.cancelAnimationFrame = function(id) {
              try { origCAF(id); } catch (e) {}
            };
          }

          window.__wxBakeClock = {
            enable: function() {
              if (running) return true;
              // Freeze content timeline at current wall time; subsequent setContentTime advances both.
              contentMs = origPerfNow();
              startMs = contentMs;
              epochAtStart = origDateNow();
              running = true;
              try {
                if (window.performance && typeof Object.defineProperty === 'function') {
                  Object.defineProperty(window.performance, 'now', {
                    configurable: true,
                    writable: true,
                    value: function() { return nowMs(); }
                  });
                }
              } catch (e) {
                try { performance.now = function() { return nowMs(); }; } catch (e2) {}
              }
              // Spine TimeKeeper uses Date.now()/1e3 — must remain epoch milliseconds.
              try { Date.now = function() { return Math.floor(epochNowMs()); }; } catch (e) {}
              window.setTimeout = function(fn, delay) {
                var id = timerId++;
                var ms = (typeof delay === 'number' && isFinite(delay)) ? Math.max(0, delay) : 0;
                var args = [].slice.call(arguments, 2);
                timers[id] = { fn: fn, fireAt: contentMs + ms, interval: 0, args: args };
                return id;
              };
              window.clearTimeout = function(id) { delete timers[id]; };
              window.setInterval = function(fn, delay) {
                var id = timerId++;
                var ms = (typeof delay === 'number' && isFinite(delay) && delay > 0) ? delay : 1;
                var args = [].slice.call(arguments, 2);
                timers[id] = { fn: fn, fireAt: contentMs + ms, interval: ms, args: args };
                return id;
              };
              window.clearInterval = function(id) { delete timers[id]; };
              return true;
            },
            /// Absolute content timeline offset from enable (ms). Frame N → N * (1000/fps).
            setContentTime: function(ms) {
              if (!running) this.enable();
              var offset = Math.max(0, Number(ms) || 0);
              contentMs = startMs + offset;
              flushTimers();
              return syncMedia().then(function() {
                return contentMs - startMs;
              }, function() {
                return contentMs - startMs;
              });
            },
            /// Wait for `count` real animation frames after time advance (lets Spine/WebGL paint).
            afterFrames: function(count, token) {
              count = Math.max(1, count | 0);
              return new Promise(function(resolve) {
                if (!origRAF) {
                  origSTO(function() { resolve(token || 0); }, 16);
                  return;
                }
                var left = count;
                function step() {
                  left -= 1;
                  if (left <= 0) {
                    resolve(token || 0);
                    return;
                  }
                  origRAF(step);
                }
                origRAF(step);
              });
            },
            /// Completes only after media seek and the requested real paints. Native polls
            /// `lastReadyToken` because WKWebView does not consistently await Promises.
            advanceAndPaint: function(ms, count, token) {
              var self = this;
              return Promise.resolve(self.setContentTime(ms))
                .then(function() {
                  return self.afterFrames(count, token);
                })
                .then(function() {
                  self.lastReadyToken = String(token || '');
                  return true;
                }, function() {
                  self.lastReadyToken = String(token || '');
                  return false;
                });
            },
            /// Probe the active video cadence before the virtual clock freezes media.
            probeMediaFrameRate: function() {
              return new Promise(function(resolve) {
                var videos = [];
                try {
                  videos = Array.prototype.slice.call(document.querySelectorAll('video'))
                    .filter(function(el) {
                      return el.readyState >= 2 && isFinite(el.duration) && el.duration > 0;
                    })
                    .sort(function(a, b) {
                      var scoreA = (a.paused ? 0 : 1000000) + a.videoWidth * a.videoHeight;
                      var scoreB = (b.paused ? 0 : 1000000) + b.videoWidth * b.videoHeight;
                      return scoreB - scoreA;
                    });
                } catch (e) {}
                var video = videos[0];
                if (!video || typeof video.requestVideoFrameCallback !== 'function') {
                  resolve(null);
                  return;
                }

                var done = false;
                var first = null;
                var last = null;
                var timeout = origSTO(function() { finish(null); }, 2200);
                function finish(rate) {
                  if (done) return;
                  done = true;
                  try { origCTO(timeout); } catch (e) {}
                  resolve(rate);
                }
                function sample(_, metadata) {
                  if (done) return;
                  var mediaTime = Number(metadata && metadata.mediaTime);
                  var presented = Number(metadata && metadata.presentedFrames);
                  if (isFinite(mediaTime) && isFinite(presented)) {
                    if (!first) first = { mediaTime: mediaTime, presented: presented };
                    last = { mediaTime: mediaTime, presented: presented };
                    var dt = last.mediaTime - first.mediaTime;
                    var frames = last.presented - first.presented;
                    if (dt >= 0.45 && frames >= 12) {
                      var rate = frames / dt;
                      finish(isFinite(rate) && rate >= 10 ? rate : null);
                      return;
                    }
                  }
                  try { video.requestVideoFrameCallback(sample); } catch (e) { finish(null); }
                }
                try {
                  if (video.paused) {
                    var p = video.play();
                    if (p && typeof p.catch === 'function') p.catch(function(){});
                  }
                  video.requestVideoFrameCallback(sample);
                } catch (e) {
                  finish(null);
                }
              });
            },
            lastReadyToken: '',
            getContentTime: function() { return contentMs - startMs; },
            isEnabled: function() { return running; }
          };
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false
    )

    /// Offline bake must never route Web audio to the user's output device. The companion
    /// capture script taps media-element PCM before the zero-output processor branch.
    private static let offlineBakeAudioSilenceStateScript = WKUserScript(
        source: """
        (function() {
          window.__waifuxAudioMuted = true;
          window.__waifuxAudioVolume = 1.0;
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false
    )

    /// Records media-element audio into a Web Audio stream that has no hardware output.
    /// After bake, WebKit decodes the recorded Blob back to PCM for the native AAC writer.
    /// MediaRecorder pause/resume excludes the slow snapshot intervals from the audio timeline.
    private static let offlineBakeAudioCaptureScript = WKUserScript(
        source: """
        (function() {
          'use strict';
          if (window.__wxBakeAudio) return;

          var context = null;
          var streamDestination = null;
          var recorder = null;
          var recorderChunks = [];
          var captureEnabled = false;
          var observer = null;
          var installed = false;
          var originalPlay = null;
          var originalPause = null;
          var attachedMediaCount = 0;
          var failedMediaCount = 0;
          var realSetTimeout = window.setTimeout.bind(window);

          function post(message) {
            try {
              var bridge = window.webkit && window.webkit.messageHandlers
                && window.webkit.messageHandlers.waifuxOfflineBakeAudio;
              if (bridge && typeof bridge.postMessage === 'function') bridge.postMessage(message);
            } catch (e) {}
          }

          function postPCM(buffer) {
            try {
              var frames = buffer.length | 0;
              if (frames <= 0) return;
              var left = buffer.getChannelData(0);
              var right = buffer.numberOfChannels > 1 ? buffer.getChannelData(1) : left;
              var packetFrames = 16384;
              for (var start = 0; start < frames; start += packetFrames) {
                var count = Math.min(packetFrames, frames - start);
                var bytes = new Uint8Array(count * 4);
                var view = new DataView(bytes.buffer);
                for (var i = 0; i < count; i++) {
                  var l = Math.max(-1, Math.min(1, Number(left[start + i]) || 0));
                  var r = Math.max(-1, Math.min(1, Number(right[start + i]) || 0));
                  view.setInt16(i * 4, l < 0 ? Math.round(l * 32768) : Math.round(l * 32767), true);
                  view.setInt16(i * 4 + 2, r < 0 ? Math.round(r * 32768) : Math.round(r * 32767), true);
                }
                var binary = '';
                var stringChunk = 0x8000;
                for (var offset = 0; offset < bytes.length; offset += stringChunk) {
                  binary += String.fromCharCode.apply(
                    null,
                    bytes.subarray(offset, Math.min(bytes.length, offset + stringChunk))
                  );
                }
                post({
                  type: 'pcm',
                  sampleRate: Number(buffer.sampleRate) || 48000,
                  channels: 2,
                  data: btoa(binary)
                });
              }
            } catch (e) {}
          }

          function ensureContext() {
            if (context) return context;
            var Ctor = window.__waifuxOriginalAudioContext
              || window.AudioContext || window.webkitAudioContext;
            if (!Ctor) return null;
            try {
              context = new Ctor({ sampleRate: 48000 });
            } catch (e) {
              try { context = new Ctor(); } catch (e2) { context = null; }
            }
            if (!context) return null;

            try {
              streamDestination = context.createMediaStreamDestination();
            } catch (e) {
              context = null;
              streamDestination = null;
              return null;
            }
            return context;
          }

          function ensureRecorder() {
            var ctx = ensureContext();
            if (!ctx || !streamDestination || typeof MediaRecorder !== 'function') return null;
            if (recorder) return recorder;
            try {
              recorder = new MediaRecorder(streamDestination.stream);
              recorder.addEventListener('dataavailable', function(event) {
                if (event.data && event.data.size > 0) recorderChunks.push(event.data);
              });
              recorder.addEventListener('stop', function() {
                var blob = new Blob(recorderChunks, {
                  type: recorder.mimeType || 'audio/webm'
                });
                recorderChunks = [];
                if (!blob || blob.size <= 0) {
                  post({ type: 'end', sampleRate: Number(ctx.sampleRate) || 48000, channels: 2 });
                  return;
                }
                blob.arrayBuffer()
                  .then(function(bytes) {
                    var DecodeCtor = window.__waifuxOriginalAudioContext
                      || window.AudioContext || window.webkitAudioContext;
                    var decoder = new DecodeCtor({ sampleRate: 48000 });
                    return decoder.decodeAudioData(bytes).then(function(buffer) {
                      try { if (decoder && decoder.close) decoder.close(); } catch (e) {}
                      return buffer;
                    }, function(error) {
                      try { if (decoder && decoder.close) decoder.close(); } catch (e) {}
                      throw error;
                    });
                  })
                  .then(function(buffer) {
                    postPCM(buffer);
                    post({
                      type: 'end',
                      sampleRate: Number(buffer.sampleRate) || 48000,
                      channels: 2
                    });
                  })
                  .catch(function() {
                    post({ type: 'end', sampleRate: Number(ctx.sampleRate) || 48000, channels: 2 });
                  });
              });
            } catch (e) {
              recorder = null;
            }
            return recorder;
          }

          function anyMediaPlaying() {
            try {
              return Array.prototype.some.call(
                document.querySelectorAll('video,audio'),
                function(el) { return !!el.__wxBakeAudioSource && !el.paused; }
              );
            } catch (e) {
              return false;
            }
          }

          function updateRecorderState() {
            if (!captureEnabled) return;
            var activeRecorder = ensureRecorder();
            if (!activeRecorder) return;
            var shouldRecord = anyMediaPlaying();
            try {
              if (shouldRecord && activeRecorder.state === 'inactive') {
                activeRecorder.start();
              } else if (shouldRecord && activeRecorder.state === 'paused') {
                activeRecorder.resume();
              } else if (!shouldRecord && activeRecorder.state === 'recording') {
                activeRecorder.pause();
              }
            } catch (e) {}
          }

          function attachMediaElement(el) {
            if (!el || el.__wxBakeAudioSource) return;
            var ctx = ensureContext();
            if (!ctx || !streamDestination) {
              try { el.muted = true; } catch (e) {}
              return;
            }
            try {
              var source = ctx.createMediaElementSource(el);
              source.connect(streamDestination);
              Object.defineProperty(el, '__wxBakeAudioSource', {
                value: source, configurable: false
              });
              attachedMediaCount += 1;
              el.addEventListener('play', function() { realSetTimeout(updateRecorderState, 0); });
              el.addEventListener('pause', function() { realSetTimeout(updateRecorderState, 0); });
              el.addEventListener('ended', function() { realSetTimeout(updateRecorderState, 0); });
            } catch (e) {
              // A page may already own this media element's source node. Silence it rather
              // than risking speaker leakage; the bake remains valid but has no PCM for it.
              try { el.muted = true; } catch (e2) {}
              failedMediaCount += 1;
            }
          }

          function attachTree(root) {
            try {
              if (root && root instanceof HTMLMediaElement) attachMediaElement(root);
              var nodes = root && root.querySelectorAll
                ? root.querySelectorAll('video,audio') : document.querySelectorAll('video,audio');
              for (var i = 0; nodes && i < nodes.length; i++) attachMediaElement(nodes[i]);
            } catch (e) {}
          }

          function install() {
            if (installed) return;
            installed = true;
            originalPlay = HTMLMediaElement.prototype.play;
            originalPause = HTMLMediaElement.prototype.pause;
            HTMLMediaElement.prototype.play = function() {
              attachMediaElement(this);
              var ctx = ensureContext();
              try {
                if (ctx && ctx.state === 'suspended') {
                  var p = ctx.resume();
                  if (p && typeof p.catch === 'function') p.catch(function(){});
                }
              } catch (e) {}
              var result = originalPlay.apply(this, arguments);
              realSetTimeout(updateRecorderState, 0);
              return result;
            };
            HTMLMediaElement.prototype.pause = function() {
              var result = originalPause.apply(this, arguments);
              realSetTimeout(updateRecorderState, 0);
              return result;
            };

            var srcDesc = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'src');
            if (srcDesc && srcDesc.set) {
              Object.defineProperty(HTMLMediaElement.prototype, 'src', {
                get: srcDesc.get,
                set: function(value) {
                  srcDesc.set.call(this, value);
                  attachMediaElement(this);
                },
                configurable: true
              });
            }

            var originalSetAttribute = Element.prototype.setAttribute;
            Element.prototype.setAttribute = function(name, value) {
              var result = originalSetAttribute.apply(this, arguments);
              if (this instanceof HTMLMediaElement && String(name).toLowerCase() === 'src') {
                attachMediaElement(this);
              }
              return result;
            };

            function beginObservation() {
              attachTree(document);
              try {
                observer = new MutationObserver(function(records) {
                  for (var i = 0; i < records.length; i++) {
                    for (var j = 0; j < records[i].addedNodes.length; j++) {
                      attachTree(records[i].addedNodes[j]);
                    }
                  }
                });
                observer.observe(document.documentElement || document, { childList: true, subtree: true });
              } catch (e) {}
            }
            if (document.readyState === 'loading') {
              document.addEventListener('DOMContentLoaded', beginObservation, { once: true });
            } else {
              beginObservation();
            }
          }

          window.__wxBakeAudio = {
            isOfflineBake: true,
            prepare: function() {
              install();
              attachTree(document);
              var ctx = ensureContext();
              try {
                if (ctx && ctx.state === 'suspended') {
                  var p = ctx.resume();
                  if (p && typeof p.catch === 'function') p.catch(function(){});
                }
              } catch (e) {}
              return ctx ? (Number(ctx.sampleRate) || 48000) : 48000;
            },
            start: function() {
              var rate = this.prepare();
              captureEnabled = true;
              updateRecorderState();
              post({ type: 'start', sampleRate: rate, channels: 2 });
              try {
                var media = Array.prototype.slice.call(document.querySelectorAll('video,audio')).map(function(el) {
                  return {
                    id: String(el.id || ''),
                    muted: !!el.muted,
                    volume: Number(el.volume || 0),
                    readyState: Number(el.readyState || 0),
                    attached: !!el.__wxBakeAudioSource
                  };
                });
                post({
                  type: 'debug',
                  attachedMediaCount: attachedMediaCount,
                  failedMediaCount: failedMediaCount,
                  mediaJSON: JSON.stringify(media)
                });
              } catch (e) {}
              return rate;
            },
            stop: function() {
              captureEnabled = false;
              try {
                if (recorder && recorder.state !== 'inactive') {
                  recorder.stop();
                } else {
                  post({
                    type: 'end',
                    sampleRate: context ? (Number(context.sampleRate) || 48000) : 48000,
                    channels: 2
                  });
                }
              } catch (e) {
                post({
                  type: 'end',
                  sampleRate: context ? (Number(context.sampleRate) || 48000) : 48000,
                  channels: 2
                });
              }
              return true;
            }
          };

          install();
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false
    )

    /// Silences physical HTML media output from document start, while preserving the media
    /// element's original muted state and volume for native-side audio mux planning.
    private static let offlineBakeSilentMediaScript = WKUserScript(
        source: """
        (function() {
          'use strict';
          if (window.__wxBakeSilentMediaInstalled) return;
          window.__wxBakeSilentMediaInstalled = true;

          function silence(el) {
            try {
              if (typeof el.__wxBakeOriginalMuted !== 'boolean') {
                el.__wxBakeOriginalMuted = !!el.muted;
              }
              el.defaultMuted = true;
              el.muted = true;
            } catch (e) {}
          }

          function silenceAll() {
            try { document.querySelectorAll('video,audio').forEach(silence); } catch (e) {}
          }

          var originalPlay = HTMLMediaElement.prototype.play;
          HTMLMediaElement.prototype.play = function() {
            silence(this);
            return originalPlay.apply(this, arguments);
          };

          var srcDesc = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'src');
          if (srcDesc && srcDesc.set) {
            Object.defineProperty(HTMLMediaElement.prototype, 'src', {
              get: srcDesc.get,
              set: function(value) {
                srcDesc.set.call(this, value);
                silence(this);
              },
              configurable: true
            });
          }

          function observe() {
            silenceAll();
            try {
              var observer = new MutationObserver(silenceAll);
              observer.observe(document.documentElement || document, { childList: true, subtree: true });
            } catch (e) {}
          }
          if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', observe, { once: true });
          } else {
            observe();
          }
          window.__wxBakeSilenceAllMedia = silenceAll;
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false
    )

    /// documentStart 注入：包装 AudioContext / webkitAudioContext，把 ctx.destination 路由到一个
    /// master GainNode；同时维护 window.__waifuxAudioMuted / __waifuxAudioVolume 状态，
    /// 暴露 window.__waifuxSetAudio({muted?, volume?}) 供 native 通过 evaluateJavaScript 调用。
    /// 静音也走这里——有效输出 = muted ? 0 : volume。绕开 WKWebView 私有 SPI _setPageMuted
    /// （KVC 不兼容 setter=_setPageMuted: 的命名约定，setValue:forKey: 会抛 NSUnknownKeyException）。
    private static let audioWrapperScript = WKUserScript(
        source: """
        (function() {
            'use strict';
            var ACtor = window.AudioContext || window.webkitAudioContext;
            if (!ACtor) return;
            try {
                if (!window.__waifuxOriginalAudioContext) {
                    window.__waifuxOriginalAudioContext = ACtor;
                }
            } catch (_) {}

            if (typeof window.__waifuxAudioVolume !== 'number') {
                window.__waifuxAudioVolume = 1.0;
            }
            if (typeof window.__waifuxAudioMuted !== 'boolean') {
                window.__waifuxAudioMuted = false;
            }
            var wrappedRefs = [];

            function effectiveVolume() {
                if (window.__wxBakeAudio && window.__wxBakeAudio.isOfflineBake) {
                    return 0;
                }
                return window.__waifuxAudioMuted ? 0 : window.__waifuxAudioVolume;
            }

            function applyAudio() {
                var v = effectiveVolume();
                for (var i = 0; i < wrappedRefs.length; i++) {
                    try {
                        var g = wrappedRefs[i].__waifuxGain;
                        if (g && g.gain) g.gain.value = v;
                    } catch (_) {}
                }
                try {
                    document.querySelectorAll('video,audio').forEach(function(e) {
                        e.volume = v;
                    });
                } catch (_) {}
            }

            function wrapContext(ctx) {
                try {
                    var origDest = ctx.destination;
                    var gain = ctx.createGain();
                    gain.connect(origDest);
                    gain.gain.value = effectiveVolume();
                    Object.defineProperty(ctx, '__waifuxGain', {
                        value: gain, writable: false, configurable: false
                    });
                    Object.defineProperty(ctx, '__waifuxOrigDestination', {
                        value: origDest, writable: false, configurable: false
                    });
                    Object.defineProperty(ctx, 'destination', {
                        get: function() { return gain; },
                        configurable: true
                    });
                    wrappedRefs.push(ctx);
                } catch (e) {
                    try { console.warn('[waifux] wrap AudioContext failed:', e); } catch (_) {}
                }
            }

            function makeWrapped(Original) {
                var Wrapped = function() {
                    var inst;
                    switch (arguments.length) {
                        case 0: inst = new Original(); break;
                        case 1: inst = new Original(arguments[0]); break;
                        default: inst = new (Function.prototype.bind.apply(
                            Original, [null].concat(Array.prototype.slice.call(arguments))
                        ))();
                    }
                    wrapContext(inst);
                    return inst;
                };
                Wrapped.prototype = Original.prototype;
                try { Object.setPrototypeOf(Wrapped, Original); } catch (_) {}
                return Wrapped;
            }

            if (window.AudioContext) {
                window.AudioContext = makeWrapped(window.AudioContext);
            }
            if (window.webkitAudioContext) {
                window.webkitAudioContext = makeWrapped(window.webkitAudioContext);
            }

            window.__waifuxSetAudio = function(opts) {
                if (!opts) return;
                if (typeof opts.muted === 'boolean') {
                    window.__waifuxAudioMuted = opts.muted;
                }
                if (typeof opts.volume === 'number') {
                    window.__waifuxAudioVolume = Math.max(0, Math.min(1, opts.volume));
                }
                applyAudio();
            };
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false
    )

    private struct WebCropRect {
        var x: CGFloat
        var y: CGFloat
        var w: CGFloat
        var h: CGFloat

        static let full = WebCropRect(x: 0, y: 0, w: 1, h: 1)

        static func normalized(from values: [Double]?) -> WebCropRect {
            guard let values, values.count == 4, values.allSatisfy(\.isFinite) else {
                return .full
            }
            let minimumSize: CGFloat = 0.0001
            let x = max(0, min(1 - minimumSize, CGFloat(values[0])))
            let y = max(0, min(1 - minimumSize, CGFloat(values[1])))
            let w = min(1 - x, max(minimumSize, CGFloat(values[2])))
            let h = min(1 - y, max(minimumSize, CGFloat(values[3])))
            return WebCropRect(x: x, y: y, w: w, h: h)
        }

    }

    private struct WebCropLayout {
        var crop: WebCropRect
        var viewport: WebCropRect
        var letterboxColor: NSColor

        static let full = WebCropLayout(crop: .full, viewport: .full, letterboxColor: .black)

        static func make(
            crop: [Double]?,
            viewport: [Double]?,
            letterboxColorHex: String?
        ) -> WebCropLayout {
            WebCropLayout(
                crop: WebCropRect.normalized(from: crop),
                viewport: WebCropRect.normalized(from: viewport),
                letterboxColor: color(from: letterboxColorHex)
            )
        }

        private static func color(from hex: String?) -> NSColor {
            var value = (hex ?? "000000")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            if value.hasPrefix("#") { value.removeFirst() }
            guard value.count == 6, let rgb = UInt32(value, radix: 16) else {
                return .black
            }
            return NSColor(
                red: CGFloat((rgb >> 16) & 0xFF) / 255,
                green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255,
                alpha: 1
            )
        }
    }

    /// 每个屏幕独立的 Web 渲染状态
    private struct ScreenState {
        var window: NSWindow?
        /// 仅裁切容器裁掉超出 viewport 的区域，WebView 本身始终保留完整逻辑尺寸。
        var cropContainer: NSView?
        var webView: WKWebView?
        var cropLayout: WebCropLayout = .full
        /// 乱序 socket 消息只允许前进，避免拖拽结束后被旧位置覆盖。
        var lastCropRevision: UInt64 = 0
        var pendingCompletion: ((Bool) -> Void)?
        var extractedPKGDir: URL?
        var mergedDependencyDir: URL?
        var projectContentDir: URL?
        var injectedPropertiesJSON: String?
        /// 每次 load/stop 递增。离线烘焙 settle 与 30s 超时回调必须比对 generation，
        /// 否则旧 load 的 asyncAfter 会误杀后续 set 的 pendingCompletion（exit=1 竞态）。
        var firstFrameSettleGeneration: UInt64 = 0
        var isLoaded: Bool = false
        var isOffscreen: Bool = false
        /// 在线静帧 capture 期间暂停该屏的鼠标注入，避免视差/交互效果在 snapshot 中途跳动。
        var mouseCaptureSuppressionDepth: Int = 0
        var mouseEventMonitors: [Any] = []
        var lastMouseMoveTime: TimeInterval = 0
    }

    private var screenStates: [Int: ScreenState] = [:]
    private let mouseMoveThrottle: TimeInterval = 1.0 / 30.0

    private enum OfflineBakeFirstFramePolicy {
        /// 至少经历此时长后才允许「稳定」判真，避免白屏/首帧未绘制误判
        static let minElapsed: TimeInterval = 3.0
        /// 含加载动画时最长等到此时长，取最后一帧作为首帧
        static let maxElapsed: TimeInterval = 24
        static let pollInterval: TimeInterval = 0.5
        /// 48×48 灰度缩略图平均通道差，低于此认为两帧近似
        static let diffThreshold: Double = 0.014
        /// 连续多少次「近似」后认为加载动画结束
        static let stablePassesRequired: Int = 2
        static let thumbDimension: Int = 48
    }

    func loadWallpaper(
        path: String,
        width: Int,
        height: Int,
        screen: Int? = nil,
        offscreen: Bool = false,
        userPropertiesJSON: String? = nil,
        initialCrop: [Double]? = nil,
        initialViewport: [Double]? = nil,
        initialLetterboxColorHex: String? = nil,
        initialCropRevision: UInt64? = nil,
        completion: ((Bool) -> Void)? = nil
    ) {
        // 解析目标屏幕索引（与 App 共用稳定顺序，禁止依赖系统枚举）
        let screens = NSScreen.screensOrderedForDisplay
        let screenIdx: Int
        if offscreen {
            screenIdx = Self.offlineBakeScreen
        } else if let s = screen, s >= 0, s < screens.count {
            screenIdx = s
        } else if let main = NSScreen.main,
                  let mainIdx = screens.firstIndex(where: {
                      $0.wallpaperScreenIdentifier == main.wallpaperScreenIdentifier
                  }) {
            screenIdx = mainIdx
        } else {
            screenIdx = 0
        }

        // 先保留旧 generation 再 stop：stop 会 fail 旧 pendingCompletion 并 +1 generation
        let previousGeneration = screenStates[screenIdx]?.firstFrameSettleGeneration ?? 0
        stop(screen: screenIdx) // 只清理目标屏幕的旧状态
        // stop 后可能仍留下空 state；统一重建，并分配本代 loadGeneration
        let loadGeneration = max(previousGeneration, screenStates[screenIdx]?.firstFrameSettleGeneration ?? 0) &+ 1
        screenStates[screenIdx] = ScreenState()
        screenStates[screenIdx]?.firstFrameSettleGeneration = loadGeneration
        screenStates[screenIdx]?.pendingCompletion = completion
        screenStates[screenIdx]?.isOffscreen = offscreen
        screenStates[screenIdx]?.cropLayout = WebCropLayout.make(
            crop: initialCrop,
            viewport: initialViewport,
            letterboxColorHex: initialLetterboxColorHex
        )
        screenStates[screenIdx]?.lastCropRevision = initialCropRevision ?? 0

        // 超时安全网：30 秒后如果本代 load 的 pendingCompletion 仍在，强制回调防止 IPC 卡死。
        // 必须比对 firstFrameSettleGeneration：否则前一次 set 的 30s 定时器会误杀下一次 set。
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self else { return }
            guard let state = self.screenStates[screenIdx],
                  state.firstFrameSettleGeneration == loadGeneration,
                  let pending = state.pendingCompletion else { return }
            let alreadyLoaded = state.isLoaded
            dlog("[WebRendererBridge] ⚠️ loadWallpaper 30s timeout screen=\(screenIdx) gen=\(loadGeneration) isLoaded=\(alreadyLoaded)")
            // 在线壁纸会在 didFinish 后立即完成；走到这里说明导航未完成。
            pending(alreadyLoaded)
            self.screenStates[screenIdx]?.pendingCompletion = nil
            if !alreadyLoaded {
                self.screenStates[screenIdx]?.firstFrameSettleGeneration &+= 1
            }
        }

        guard let (baseURL, indexFile) = resolveWebWallpaperEntry(path: path) else {
            dlog("[WebRendererBridge] Failed to resolve web wallpaper entry for \(path)")
            screenStates[screenIdx]?.pendingCompletion = nil
            completion?(false)
            return
        }

        screenStates[screenIdx]?.injectedPropertiesJSON = userPropertiesJSON
            ?? readWebWallpaperUserPropertiesJSON(contentDir: baseURL)
        screenStates[screenIdx]?.projectContentDir = baseURL
        if screenStates[screenIdx]?.injectedPropertiesJSON != nil {
            dlog("[WebRendererBridge] Loaded user properties for injection")
        }

        // 记录临时目录以便 stop 时清理
        if URL(fileURLWithPath: path).pathExtension.lowercased() == "pkg" {
            screenStates[screenIdx]?.extractedPKGDir = baseURL
        } else if baseURL.path.contains("wallpaperengine_merged_") {
            screenStates[screenIdx]?.mergedDependencyDir = baseURL
        }

        let targetScreen: NSScreen
        if screenIdx >= 0 && screenIdx < screens.count {
            targetScreen = screens[screenIdx]
        } else if let main = NSScreen.main {
            targetScreen = main
        } else {
            screenStates[screenIdx]?.pendingCompletion = nil
            completion?(false)
            return
        }
        // 创建无边框窗口
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let desktopLevel = CGWindowLevelForKey(.desktopWindow)
        w.level = offscreen ? .normal : .init(rawValue: Int(desktopLevel))
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        if offscreen {
            // `orderOut`, transparent, and fully occluded windows make WebKit throttle
            // media decode. Leave one physical pixel on-screen so the surface remains
            // compositor-participating; ScreenCaptureKit ignores the global clip and
            // captures the complete window.
            let scale = max(1, targetScreen.backingScaleFactor)
            let logicalSize = NSSize(
                width: max(2, (CGFloat(width) / scale).rounded(.up)),
                height: max(2, (CGFloat(height) / scale).rounded(.up))
            )
            let visibleEdge = 1.0 / scale
            let candidates = [
                NSRect(
                    x: targetScreen.frame.maxX - visibleEdge,
                    y: targetScreen.frame.maxY - visibleEdge,
                    width: logicalSize.width,
                    height: logicalSize.height
                ),
                NSRect(
                    x: targetScreen.frame.minX - logicalSize.width + visibleEdge,
                    y: targetScreen.frame.maxY - visibleEdge,
                    width: logicalSize.width,
                    height: logicalSize.height
                ),
                NSRect(
                    x: targetScreen.frame.maxX - visibleEdge,
                    y: targetScreen.frame.minY - logicalSize.height + visibleEdge,
                    width: logicalSize.width,
                    height: logicalSize.height
                ),
                NSRect(
                    x: targetScreen.frame.minX - logicalSize.width + visibleEdge,
                    y: targetScreen.frame.minY - logicalSize.height + visibleEdge,
                    width: logicalSize.width,
                    height: logicalSize.height
                )
            ]
            // A neighbouring display may sit directly outside one edge. Choose the
            // corner whose bake window overlaps the least visible desktop area.
            let frame = candidates.min { lhs, rhs in
                let lhsArea = screens.reduce(CGFloat.zero) { partial, screen in
                    partial + lhs.intersection(screen.frame).width * lhs.intersection(screen.frame).height
                }
                let rhsArea = screens.reduce(CGFloat.zero) { partial, screen in
                    partial + rhs.intersection(screen.frame).width * rhs.intersection(screen.frame).height
                }
                return lhsArea < rhsArea
            } ?? candidates[0]
            w.setFrame(frame, display: false)
            w.alphaValue = 1
        } else {
            // 全屏覆盖（含菜单栏条带下方）。alpha=0.99999 常驻近乎不透明
            // （+ isOpaque=false 已有）：壁纸层不被挂起，菜单栏 backdrop
            // 懒采样能跟随 poster 更新。
            w.setFrame(targetScreen.frame, display: true)
        }
        w.acceptsMouseMovedEvents = true
        w.ignoresMouseEvents = offscreen
        w.isReleasedWhenClosed = false

        guard let contentView = w.contentView else {
            screenStates[screenIdx]?.pendingCompletion = nil
            completion?(false)
            return
        }
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.black.cgColor

        // 外层仅负责 viewport 裁切。WebView 保持完整屏幕尺寸，避免固定定位/WebGL
        // 壁纸因 crop 而重排或收到错误的 window.innerWidth/window.innerHeight。
        let cropContainer = NSView(frame: contentView.bounds)
        cropContainer.wantsLayer = true
        cropContainer.layer?.masksToBounds = true
        cropContainer.layer?.backgroundColor = NSColor.clear.cgColor
        cropContainer.autoresizingMask = []

        // 配置 WKWebView
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        let ucc = WKUserContentController()
        ucc.addUserScript(Self.wallpaperEngineWebAPIShim)
        ucc.addUserScript(Self.localFileCompatScript)
        ucc.addUserScript(Self.mouseEventBridgeScript)
        if offscreen {
            ucc.addUserScript(Self.offlineBakeAudioSilenceStateScript)
            ucc.addUserScript(Self.offlineBakeSilentMediaScript)
        }
        ucc.addUserScript(Self.audioWrapperScript)
        config.userContentController = ucc
        if #available(macOS 14.0, *) {
            config.defaultWebpagePreferences.allowsContentJavaScript = true
        }
        config.mediaTypesRequiringUserActionForPlayback = []

        let web = WKWebView(frame: cropContainer.bounds, configuration: config)
        web.autoresizingMask = []
        web.navigationDelegate = self
        web.wantsLayer = true
        web.layer?.backgroundColor = NSColor.clear.cgColor
        web.layer?.contentsScale = targetScreen.backingScaleFactor

        cropContainer.addSubview(web)
        contentView.addSubview(cropContainer)

        screenStates[screenIdx]?.window = w
        screenStates[screenIdx]?.cropContainer = cropContainer
        screenStates[screenIdx]?.webView = web
        applyCropLayout(for: screenIdx)

        let fileURL = baseURL.appendingPathComponent(indexFile)
        let readAccessURL = webWallpaperFileReadAccessURL(projectContentDir: baseURL, cliWallpaperPath: path)
        if readAccessURL.path != baseURL.path {
            dlog("[WebRendererBridge] file read access expanded to workshop root: \(readAccessURL.path)")
        }
        autoFixSpineConfigIfNeeded(projectContentDir: baseURL)
        web.loadFileURL(fileURL, allowingReadAccessTo: readAccessURL)
        if offscreen {
            w.orderFrontRegardless()
        } else {
            // `desktopWindow` 层本身低于普通 App 窗口；在该层内前置不会盖住应用，
            // 却能避免 WindowServer 将完整遮挡的 WKWebView/WebGL canvas 停止合成。
            w.orderFront(nil)
            // 常驻近乎不透明 alpha=0.99999（+ isOpaque=false 已有）：窗口按半透明层
            // 合成，必须与壁纸层混合 → 壁纸层不被挂起 → 菜单栏 backdrop
            // 懒采样能跟随 poster 更新（alpha=1 时壁纸层被挂起，菜单栏永不
            // 更新——实测验证）。0.99999 与 1 视觉无差别。
            w.alphaValue = 0.99999
        }

        let destination = offscreen ? "offscreen bake surface" : "screen \(screenIdx) (\(targetScreen.localizedName))"
        dlog("[WebRendererBridge] Loading web wallpaper: \(fileURL.path) on \(destination)")
    }

    /// 自动检测并修复 Spine 动画壁纸缺失的 .config.json。
    /// 部分 Workshop 作者本地有配置文件，打包时遗漏，导致 JS fallback 到不存在的 hardcode 文件名。
    private func autoFixSpineConfigIfNeeded(projectContentDir: URL) {
        let fm = FileManager.default
        let imageDir = projectContentDir.appendingPathComponent("image")
        let configURL = imageDir.appendingPathComponent(".config.json")

        // 已有配置则跳过
        guard fm.fileExists(atPath: imageDir.path),
              !fm.fileExists(atPath: configURL.path) else { return }

        // 查找 .skel 文件
        let skelFiles: [URL]
        do {
            skelFiles = try fm.contentsOfDirectory(at: imageDir, includingPropertiesForKeys: [.fileSizeKey])
                .filter { $0.pathExtension.lowercased() == "skel" }
        } catch {
            return
        }

        guard !skelFiles.isEmpty else { return }

        // 多个 skel 时选最大的（通常是最完整的角色模型）
        let targetSkel: URL
        if skelFiles.count == 1 {
            targetSkel = skelFiles[0]
        } else {
            targetSkel = skelFiles.max { a, b in
                let sizeA = (try? fm.attributesOfItem(atPath: a.path)[.size] as? Int) ?? 0
                let sizeB = (try? fm.attributesOfItem(atPath: b.path)[.size] as? Int) ?? 0
                return sizeA < sizeB
            } ?? skelFiles[0]
        }

        let skelName = targetSkel.lastPathComponent
        let config: [String: String] = ["skeleton": skelName]
        guard let data = try? JSONSerialization.data(withJSONObject: config, options: []) else { return }

        do {
            try data.write(to: configURL, options: .atomic)
            dlog("[WebRendererBridge] Auto-created Spine config: \(skelName)")
        } catch {
            dlog("[WebRendererBridge] Failed to auto-create Spine config: \(error)")
        }
    }

    /// 根据 webView 实例查找所属屏幕索引
    private func screenIndex(for webView: WKWebView) -> Int? {
        for (idx, state) in screenStates {
            if state.webView === webView { return idx }
        }
        return nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let s = screenIndex(for: webView) else { return }
        dlog("[WebRendererBridge] didFinish screen=\(s)")
        screenStates[s]?.isLoaded = true
        runWebWallpaperBootstrap(screen: s) { [weak self] in
            guard let self = self else { return }
            self.applyCropLayout(for: s)
            if self.screenStates[s]?.isOffscreen == true {
                // Compositor recording does not need a stable WKWebView snapshot.
                // Snapshot settling pauses/seeks video and is the source of judder.
                self.completeOfflineBakeLoad(screen: s)
            } else {
                self.completeLiveWallpaperLoad(screen: s)
            }
            // Offline bake surfaces are full-screen transparent windows; never bridge
            // mouse into them or the bake will follow the cursor / parallax props.
            if self.screenStates[s]?.isOffscreen != true {
                self.startMouseEventBridge(for: s)
            }
        }
        NSApp.setActivationPolicy(.prohibited)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard let s = screenIndex(for: webView) else { return }
        dlog("[WebRendererBridge] didFail screen=\(s): \(error)")
        screenStates[s]?.firstFrameSettleGeneration &+= 1
        screenStates[s]?.pendingCompletion?(false)
        screenStates[s]?.pendingCompletion = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard let s = screenIndex(for: webView) else { return }
        dlog("[WebRendererBridge] didFailProvisional screen=\(s): \(error)")
        screenStates[s]?.firstFrameSettleGeneration &+= 1
        screenStates[s]?.pendingCompletion?(false)
        screenStates[s]?.pendingCompletion = nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let s = screenIndex(for: webView) else { return }
        dlog("[WebRendererBridge] WebContent terminated screen=\(s)")
        screenStates[s]?.firstFrameSettleGeneration &+= 1
        screenStates[s]?.pendingCompletion?(false)
        screenStates[s]?.pendingCompletion = nil
        screenStates[s]?.isLoaded = false
    }

    func pause(screen: Int = 0) {
        guard let state = screenStates[screen] else { return }
        state.window?.orderOut(nil)
        state.webView?.evaluateJavaScript("""
            document.querySelectorAll('video, audio').forEach(m => m.pause());
            document.querySelectorAll('*').forEach(el => {
                const st = window.getComputedStyle(el);
                if (st.animationName !== 'none') el.style.animationPlayState = 'paused';
            });
        """) { _, _ in }
    }

    func pauseAll() { for s in screenStates.keys { pause(screen: s) } }

    func resume(screen: Int = 0) {
        guard let state = screenStates[screen], state.isLoaded else { return }
        // 与首次加载保持一致：WebGL 壁纸在 desktop 层内必须前置才会持续合成。
        state.window?.orderFront(nil)
        state.webView?.evaluateJavaScript("""
            document.querySelectorAll('video, audio').forEach(m => { if(m.paused) m.play().catch(()=>{}); });
            document.querySelectorAll('*').forEach(el => {
                if (el.style.animationPlayState === 'paused') el.style.animationPlayState = 'running';
            });
            window.dispatchEvent(new Event('resize'));
        """) { _, _ in }
        if state.isOffscreen != true {
            startMouseEventBridge(for: screen)
        }
        NSApp.setActivationPolicy(.prohibited)
    }

    func resumeAll() { for s in screenStates.keys { resume(screen: s) } }

    func setAudioControl(muted: Bool?, volume: Double?, screen: Int = 0) {
        guard let state = screenStates[screen], state.isLoaded, let webView = state.webView else { return }
        if let muted {
            let sel = NSSelectorFromString("_setPageMuted:")
            if let method = class_getInstanceMethod(type(of: webView), sel) {
                typealias SetPageMutedFn = @convention(c) (NSObject, Selector, UInt) -> Void
                let imp = method_getImplementation(method)
                let fn = unsafeBitCast(imp, to: SetPageMutedFn.self)
                fn(webView, sel, muted ? UInt(1) : UInt(0))
            } else {
                webView.evaluateJavaScript("if(window.__waifuxSetAudio)window.__waifuxSetAudio({muted:\(muted)});")
            }
        }
        if let volume {
            let v = max(0.0, min(1.0, volume))
            let js = "if(window.__waifuxSetAudio){window.__waifuxSetAudio({volume:\(v)});}else{document.querySelectorAll('video,audio').forEach(function(e){e.volume=\(v);});}"
            webView.evaluateJavaScript(js)
        }
    }

    func pushAudioFrame(_ floats: [Float]) {
        guard floats.count == 128 else { return }
        var sb = "if(window.__wxUpdateAudioBuf)window.__wxUpdateAudioBuf(["
        sb.reserveCapacity(1200)
        for i in 0..<128 { if i > 0 { sb.append(",") }; sb.append(String(format: "%.4f", floats[i])) }
        sb.append("]);")
        let js = sb
        for (_, state) in screenStates where state.isLoaded {
            guard let webView = state.webView else { continue }
            DispatchQueue.main.async { [weak webView] in
                webView?.evaluateJavaScript(js) { _, error in
                    if let error { dlog("[WebRendererBridge] pushAudioFrame JS error: \(error)") }
                }
            }
        }
    }

    /// 推送 Now Playing 元数据到所有已加载的 Web 壁纸。
    /// 参数与 WE Media Integration 对齐；JSON 经 base64 注入避免转义问题。
    func pushMediaUpdate(
        enabled: Bool,
        title: String,
        artist: String,
        albumTitle: String,
        state: Int,
        position: Double,
        duration: Double,
        rate: Double
    ) {
        let payload: [String: Any] = [
            "enabled": enabled,
            "title": title,
            "artist": artist,
            "albumTitle": albumTitle,
            "state": state,
            "position": position,
            "duration": duration,
            "rate": rate
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              case let b64 = data.base64EncodedString() else { return }
        // 必须走 __wxParseB64JSON：裸 atob+JSON.parse 会把中文 title 解成 Latin-1 乱码
        let js = "(function(){try{var o=(window.__wxParseB64JSON?window.__wxParseB64JSON('\(b64)'):JSON.parse(atob('\(b64)')));if(o&&window.__wxPushMediaUpdate)window.__wxPushMediaUpdate(o);}catch(e){}})();"
        for (_, st) in screenStates where st.isLoaded {
            guard let webView = st.webView else { continue }
            DispatchQueue.main.async { [weak webView] in
                webView?.evaluateJavaScript(js, completionHandler: nil)
            }
        }
    }

    func pushMediaThumbnail(_ thumbnail: String) {
        let payload: [String: Any] = ["thumbnail": thumbnail]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              case let b64 = data.base64EncodedString() else { return }
        let js = "(function(){try{var o=(window.__wxParseB64JSON?window.__wxParseB64JSON('\(b64)'):JSON.parse(atob('\(b64)')));if(o&&window.__wxPushMediaThumbnail)window.__wxPushMediaThumbnail(o);}catch(e){}})();"
        for (_, st) in screenStates where st.isLoaded {
            guard let webView = st.webView else { continue }
            DispatchQueue.main.async { [weak webView] in
                webView?.evaluateJavaScript(js, completionHandler: nil)
            }
        }
    }


    func pushMediaLyrics(
        hasLyrics: Bool,
        title: String,
        artist: String,
        songId: String,
        storefront: String,
        source: String,
        lines: [IPCLyricLine]
    ) {
        var lineArr: [[String: Any]] = []
        lineArr.reserveCapacity(lines.count)
        for ln in lines {
            var d: [String: Any] = ["start": ln.start, "text": ln.text]
            if let end = ln.end { d["end"] = end }
            lineArr.append(d)
        }
        let payload: [String: Any] = [
            "hasLyrics": hasLyrics,
            "title": title,
            "artist": artist,
            "songId": songId,
            "storefront": storefront,
            "source": source,
            "lineCount": lines.count,
            "lines": lineArr
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              case let b64 = data.base64EncodedString() else { return }
        let js = "(function(){try{var o=(window.__wxParseB64JSON?window.__wxParseB64JSON('\(b64)'):JSON.parse(atob('\(b64)')));if(o&&window.__wxPushMediaLyrics)window.__wxPushMediaLyrics(o);}catch(e){}})();"
        for (_, st) in screenStates where st.isLoaded {
            guard let webView = st.webView else { continue }
            DispatchQueue.main.async { [weak webView] in
                webView?.evaluateJavaScript(js, completionHandler: nil)
            }
        }
    }

    func pushMediaLyricsLine(
        index: Int,
        text: String,
        nextText: String,
        previousText: String,
        start: Double,
        end: Double?,
        progress: Double,
        elapsedTime: Double,
        hasLine: Bool
    ) {
        var payload: [String: Any] = [
            "index": index,
            "text": text,
            "nextText": nextText,
            "previousText": previousText,
            "start": start,
            "progress": progress,
            "elapsedTime": elapsedTime,
            "hasLine": hasLine
        ]
        if let end { payload["end"] = end }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              case let b64 = data.base64EncodedString() else { return }
        let js = "(function(){try{var o=(window.__wxParseB64JSON?window.__wxParseB64JSON('\(b64)'):JSON.parse(atob('\(b64)')));if(o&&window.__wxPushMediaLyricsLine)window.__wxPushMediaLyricsLine(o);}catch(e){}})();"
        for (_, st) in screenStates where st.isLoaded {
            guard let webView = st.webView else { continue }
            DispatchQueue.main.async { [weak webView] in
                webView?.evaluateJavaScript(js, completionHandler: nil)
            }
        }
    }

    @discardableResult
    func applyUserProperties(jsonString: String, screen: Int = 0) -> Bool {
        screenStates[screen]?.injectedPropertiesJSON = jsonString
        guard let state = screenStates[screen], state.isLoaded, let webView = state.webView else { return false }
        let encoded = Data(jsonString.utf8).base64EncodedString()
        let source = "(function(){try{var props=JSON.parse(atob(\"\(encoded)\"));if(window.wallpaperPropertyListener&&typeof window.wallpaperPropertyListener.applyUserProperties==='function'){window.wallpaperPropertyListener.applyUserProperties(props);return true;}}catch(e){}return false;})();"
        webView.evaluateJavaScript(source) { result, _ in
            dlog("[WebRendererBridge] applyUserProperties screen=\(screen) result=\(String(describing: result))")
        }
        return true
    }

    /// 热更新 Web 壁纸的裁切与可视框。WebView 保持原始屏幕 viewport，
    /// 父容器负责可视框裁切，HTML 根节点负责整个 Web 页面的缩放与平移。
    @discardableResult
    func applyCrop(
        crop: [Double]?,
        viewport: [Double]?,
        letterboxColorHex: String?,
        cropRevision: UInt64?,
        screen: Int = 0
    ) -> Bool {
        guard var state = screenStates[screen],
              state.window != nil,
              state.cropContainer != nil,
              state.webView != nil else {
            return false
        }
        if let cropRevision, cropRevision < state.lastCropRevision {
            dlog("[WebRendererBridge] Ignored stale crop screen=\(screen) revision=\(cropRevision) latest=\(state.lastCropRevision)")
            return true
        }
        state.cropLayout = WebCropLayout.make(
            crop: crop,
            viewport: viewport,
            letterboxColorHex: letterboxColorHex
        )
        if let cropRevision {
            state.lastCropRevision = cropRevision
        }
        screenStates[screen] = state
        applyCropLayout(for: screen)
        return true
    }

    private func webRootTransform(
        targetSize: CGSize,
        crop: WebCropRect,
        viewport: WebCropRect
    ) -> (scaleX: CGFloat, scaleY: CGFloat, translateX: CGFloat, translateY: CGFloat) {
        let viewportWidth = viewport.w * targetSize.width
        let viewportHeight = viewport.h * targetSize.height
        let viewportX = viewport.x * targetSize.width
        let viewportY = viewport.y * targetSize.height
        let scaleX = viewportWidth / max(0.0001, targetSize.width * crop.w)
        let scaleY = viewportHeight / max(0.0001, targetSize.height * crop.h)
        let translateX = viewportX - crop.x * targetSize.width * scaleX
        let translateY = viewportY - crop.y * targetSize.height * scaleY
        return (scaleX, scaleY, translateX, translateY)
    }

    private func applyCropLayout(for screen: Int) {
        guard let state = screenStates[screen],
              let window = state.window,
              let contentView = window.contentView,
              let cropContainer = state.cropContainer,
              let webView = state.webView else {
            return
        }

        let targetSize = contentView.bounds.size
        let sourceSize = webView.bounds.size
        guard targetSize.width > 0, targetSize.height > 0,
              sourceSize.width > 0, sourceSize.height > 0 else {
            return
        }

        let layout = state.cropLayout
        let viewport = layout.viewport
        let crop = layout.crop
        let cropText = String(format: "%.4f,%.4f,%.4f,%.4f", crop.x, crop.y, crop.w, crop.h)
        let viewportText = String(format: "%.4f,%.4f,%.4f,%.4f", viewport.x, viewport.y, viewport.w, viewport.h)
        dlog("[WebRendererBridge] crop geometry screen=\(screen) revision=\(state.lastCropRevision) root=html source=\(Int(sourceSize.width))x\(Int(sourceSize.height)) target=\(Int(targetSize.width))x\(Int(targetSize.height)) crop=\(cropText) viewport=\(viewportText)")
        let viewportWidth = viewport.w * targetSize.width
        let viewportHeight = viewport.h * targetSize.height
        let viewportX = viewport.x * targetSize.width
        // AppKit view 坐标原点在左下；Crop 参数 y 原点在左上。
        let viewportY = (1 - viewport.y - viewport.h) * targetSize.height

        contentView.layer?.backgroundColor = layout.letterboxColor.cgColor
        cropContainer.frame = CGRect(
            x: viewportX,
            y: viewportY,
            width: viewportWidth,
            height: viewportHeight
        )
        cropContainer.layer?.masksToBounds = true

        // Keep the WebView viewport at the screen size. The crop transform is
        // applied to document.documentElement, so the entire Web page moves
        // together and WebGL/fixed-position descendants keep their own layout.
        webView.frame = CGRect(
            x: -viewportX,
            y: -viewportY,
            width: targetSize.width,
            height: targetSize.height
        )

        let transform = webRootTransform(
            targetSize: targetSize,
            crop: crop,
            viewport: viewport
        )
        let config: [String: Any] = [
            "scaleX": transform.scaleX,
            "scaleY": transform.scaleY,
            "translateX": transform.translateX,
            "translateY": transform.translateY
        ]
        guard state.isLoaded else { return }
        if let data = try? JSONSerialization.data(withJSONObject: config),
           let json = String(data: data, encoding: .utf8) {
            let script = "window.__wxApplyWebCrop && window.__wxApplyWebCrop(\(json));"
            webView.evaluateJavaScript(script) { result, error in
                if let error {
                    dlog("[WebRendererBridge] root crop JS error screen=\(screen): \(error)")
                } else if (result as? Bool) != true {
                    dlog(
                        "[WebRendererBridge] root crop JS rejected screen=\(screen) " +
                        "result=\(String(describing: result))"
                    )
                }
            }
        }
    }

    func stop(screen: Int = 0) {
        guard var state = screenStates[screen] else { return }
        state.firstFrameSettleGeneration &+= 1
        // 必须先调用 pendingCompletion 再置 nil，否则 IPC 响应永远不会发回给 CLI client
        // （CLI client 的 recv() 会一直阻塞直到 35s 超时）
        state.pendingCompletion?(false)
        state.pendingCompletion = nil
        state.webView?.stopLoading()
        state.webView?.navigationDelegate = nil
        state.webView?.removeFromSuperview()
        state.webView = nil
        state.cropContainer?.removeFromSuperview()
        state.cropContainer = nil
        state.window?.close()
        state.window = nil
        state.isLoaded = false
        if let dir = state.extractedPKGDir { try? FileManager.default.removeItem(at: dir); state.extractedPKGDir = nil }
        if let dir = state.mergedDependencyDir { try? FileManager.default.removeItem(at: dir); state.mergedDependencyDir = nil }
        state.projectContentDir = nil
        state.injectedPropertiesJSON = nil
        screenStates[screen] = state
    }

    func stopAll() {
        for s in Array(screenStates.keys) { stop(screen: s) }
        stopMouseEventBridge()
        screenStates.removeAll()
    }

    var loadedScreens: [Int] { screenStates.filter { $0.value.isLoaded }.map { $0.key } }

    // MARK: - Mouse Event Bridge (全局一组 monitor，分发到所有屏幕的 webView)

    private var globalMouseMonitors: [Any] = []
    private var lastGlobalMouseMoveTime: TimeInterval = 0

    private func startMouseEventBridge(for screen: Int) {
        guard screenStates[screen]?.window != nil, screenStates[screen]?.webView != nil else { return }
        // Bake / offscreen surfaces must not receive cursor parallax or click injection.
        guard screenStates[screen]?.isOffscreen != true else { return }
        if !globalMouseMonitors.isEmpty { return }
        let eventTypes: [(NSEvent.EventTypeMask, String)] = [
            (.leftMouseDown, "mousedown"), (.leftMouseUp, "mouseup"),
            (.mouseMoved, "mousemove"), (.scrollWheel, "wheel")
        ]
        for (eventType, type) in eventTypes {
            if let g = NSEvent.addGlobalMonitorForEvents(matching: eventType) { [weak self] event in
                self?.dispatchMouseEvent(event, type: type)
            } { globalMouseMonitors.append(g) }
            if let l = NSEvent.addLocalMonitorForEvents(matching: eventType) { [weak self] event -> NSEvent? in
                self?.dispatchMouseEvent(event, type: type)
                return event
            } { globalMouseMonitors.append(l) }
        }
    }

    private func stopMouseEventBridge() {
        for monitor in globalMouseMonitors { NSEvent.removeMonitor(monitor) }
        globalMouseMonitors.removeAll()
        lastGlobalMouseMoveTime = 0
    }

    private func dispatchMouseEvent(_ event: NSEvent, type: String) {
        if type == "mousemove" {
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastGlobalMouseMoveTime < mouseMoveThrottle { return }
            lastGlobalMouseMoveTime = now
        }
        let mouseLocation = NSEvent.mouseLocation
        for (_, state) in screenStates {
            // Offline bake uses a full-screen transparent window; never inject into it.
            guard !state.isOffscreen, state.mouseCaptureSuppressionDepth == 0 else { continue }
            guard state.isLoaded, let window = state.window, let webView = state.webView else { continue }
            guard window.frame.contains(mouseLocation) else { continue }
            let relX = mouseLocation.x - window.frame.origin.x
            let relY = mouseLocation.y - window.frame.origin.y
            let sourceX = relX
            let sourceY = window.frame.height - relY
            let layout = state.cropLayout
            let viewport = layout.viewport
            let crop = layout.crop
            let targetWidth = window.frame.width
            let targetHeight = window.frame.height
            let viewportX = viewport.x * targetWidth
            let viewportY = viewport.y * targetHeight
            let viewportWidth = viewport.w * targetWidth
            let viewportHeight = viewport.h * targetHeight
            guard sourceX >= viewportX, sourceX <= viewportX + viewportWidth,
                  sourceY >= viewportY, sourceY <= viewportY + viewportHeight else {
                continue
            }
            let transform = webRootTransform(
                targetSize: CGSize(width: targetWidth, height: targetHeight),
                crop: crop,
                viewport: viewport
            )
            guard transform.scaleX > 0, transform.scaleY > 0 else { continue }
            // Mouse coordinates are sent back through the inverse transform of
            // document.documentElement, in the WebView's normal CSS viewport.
            let webViewX = (sourceX - transform.translateX) / transform.scaleX
            let webViewY = (sourceY - transform.translateY) / transform.scaleY
            guard webViewX >= 0, webViewX <= webView.bounds.width,
                  webViewY >= 0, webViewY <= webView.bounds.height else { continue }
            let xStr = String(Double(webViewX))
            let yStr = String(Double(webViewY))
            var script = "if(window.__wxMouseBridge){window.__wxMouseBridge.dispatch('" + type + "'," + xStr + "," + yStr + ",0"
            if type == "wheel" {
                let dxStr = String(Double(event.scrollingDeltaX))
                let dyStr = String(Double(event.scrollingDeltaY))
                script += "," + dxStr + "," + dyStr
            } else {
                script += ",0,0"
            }
            script += ");}"
            DispatchQueue.main.async { [weak webView] in
                webView?.evaluateJavaScript(script)
            }
            break
        }
    }

    private func applyUserPropertiesJSBody(b64EncodedJSON: String) -> String {
        "var props=JSON.parse(atob(\"\(b64EncodedJSON)\"));if(window.wallpaperPropertyListener&&typeof window.wallpaperPropertyListener.applyUserProperties==='function'){window.wallpaperPropertyListener.applyUserProperties(props);}"
    }

    private func makeApplyUserPropertiesScript(json: String) -> String? {
        guard let data = json.data(using: .utf8) else { return nil }
        let encoded = data.base64EncodedString()
        return "(function(){try{\(applyUserPropertiesJSBody(b64EncodedJSON: encoded))}catch(e){}})();"
    }

    private func runWebWallpaperBootstrap(screen: Int, completion: (() -> Void)? = nil) {
        guard let state = screenStates[screen], let webView = state.webView else { completion?(); return }
        var propsBlock = ""
        if let json = state.injectedPropertiesJSON,
           let data = json.data(using: .utf8) {
            let encoded = data.base64EncodedString()
            propsBlock = "try{\(applyUserPropertiesJSBody(b64EncodedJSON: encoded))}catch(e){}"
        }
        // 不重写 html/body 的尺寸、边距或 overflow，避免改变 WebGL 壁纸自身的布局基准。
        // crop 只通过 document.documentElement 的 transform 作用于整页。
        let source = """
        (function() {
          try {
            var root = document.documentElement;
            if (root) {
              var state = window.__wxWebCropState || {
                active: false,
                captured: false,
                transform: '',
                transformPriority: '',
                transformOrigin: '',
                transformOriginPriority: ''
              };
              window.__wxWebCropState = state;
              window.__wxSyncWebCropBackground = function() {
                try {
                  var body = document.body;
                  var rootStyle = window.getComputedStyle(root);
                  var bodyStyle = body ? window.getComputedStyle(body) : null;
                  var bodyHasImage = bodyStyle && bodyStyle.backgroundImage !== 'none';
                  var bodyHasColor = bodyStyle
                    && bodyStyle.backgroundColor !== 'transparent'
                    && bodyStyle.backgroundColor !== 'rgba(0, 0, 0, 0)';
                  var sourceStyle = bodyHasImage || bodyHasColor ? bodyStyle : rootStyle;
                  if (!sourceStyle) return false;
                  root.style.setProperty('--wx-crop-background-color', sourceStyle.backgroundColor);
                  root.style.setProperty('--wx-crop-background-image', sourceStyle.backgroundImage);
                  root.style.setProperty('--wx-crop-background-position', sourceStyle.backgroundPosition);
                  root.style.setProperty('--wx-crop-background-size', sourceStyle.backgroundSize);
                  root.style.setProperty('--wx-crop-background-repeat', sourceStyle.backgroundRepeat);
                  root.style.setProperty('--wx-crop-background-origin', sourceStyle.backgroundOrigin);
                  root.style.setProperty('--wx-crop-background-clip', sourceStyle.backgroundClip);
                  root.style.setProperty('--wx-crop-background-blend-mode', sourceStyle.backgroundBlendMode);
                  return true;
                } catch (e) {
                  return false;
                }
              };
              if (!document.getElementById('__wx-web-crop-background-style')) {
                var cropStyle = document.createElement('style');
                cropStyle.id = '__wx-web-crop-background-style';
                cropStyle.textContent =
                  'html[data-wx-web-crop-active="true"] { isolation: isolate; }' +
                  'html[data-wx-web-crop-active="true"]::before {' +
                  'content:"";position:fixed;inset:0;width:100vw;height:100vh;' +
                  'pointer-events:none;z-index:-2147483647;' +
                  'background-color:var(--wx-crop-background-color,transparent);' +
                  'background-image:var(--wx-crop-background-image,none);' +
                  'background-position:var(--wx-crop-background-position,0% 0%);' +
                  'background-size:var(--wx-crop-background-size,auto);' +
                  'background-repeat:var(--wx-crop-background-repeat,repeat);' +
                  'background-origin:var(--wx-crop-background-origin,padding-box);' +
                  'background-clip:var(--wx-crop-background-clip,border-box);' +
                  'background-blend-mode:var(--wx-crop-background-blend-mode,normal);' +
                  'background-attachment:scroll;}';
                (document.head || root).appendChild(cropStyle);
              }
              if (!window.__wxWebCropBackgroundObserver && typeof MutationObserver === 'function') {
                window.__wxWebCropBackgroundObserver = new MutationObserver(function() {
                  if (state.active && window.__wxSyncWebCropBackground) {
                    window.__wxSyncWebCropBackground();
                  }
                });
                if (document.body) {
                  window.__wxWebCropBackgroundObserver.observe(
                    document.body,
                    { attributes: true, attributeFilter: ['style', 'class'] }
                  );
                }
              }
              window.__wxApplyWebCrop = function(config) {
                try {
                  if (!config || !isFinite(config.scaleX) || !isFinite(config.scaleY)
                      || !isFinite(config.translateX) || !isFinite(config.translateY)) {
                    return false;
                  }
                  var isIdentity = Math.abs(config.scaleX - 1) < 0.000001
                    && Math.abs(config.scaleY - 1) < 0.000001
                    && Math.abs(config.translateX) < 0.0001
                    && Math.abs(config.translateY) < 0.0001;
                  if (isIdentity) {
                    if (state.active && state.captured) {
                      if (state.transform) {
                        root.style.setProperty('transform', state.transform, state.transformPriority);
                      } else {
                        root.style.removeProperty('transform');
                      }
                      if (state.transformOrigin) {
                        root.style.setProperty('transform-origin', state.transformOrigin, state.transformOriginPriority);
                      } else {
                        root.style.removeProperty('transform-origin');
                      }
                    }
                    root.removeAttribute('data-wx-web-crop-active');
                    state.active = false;
                    state.captured = false;
                    return true;
                  }
                  if (!state.captured) {
                    state.transform = root.style.getPropertyValue('transform');
                    state.transformPriority = root.style.getPropertyPriority('transform');
                    state.transformOrigin = root.style.getPropertyValue('transform-origin');
                    state.transformOriginPriority = root.style.getPropertyPriority('transform-origin');
                    state.captured = true;
                  }
                  if (window.__wxSyncWebCropBackground) {
                    window.__wxSyncWebCropBackground();
                  }
                  root.setAttribute('data-wx-web-crop-active', 'true');
                  root.style.setProperty('transform-origin', '0 0', 'important');
                  root.style.setProperty(
                    'transform',
                    'translate3d(' + config.translateX + 'px,' + config.translateY + 'px,0) '
                      + 'scale3d(' + config.scaleX + ',' + config.scaleY + ',1)',
                    'important'
                  );
                  state.active = true;
                  return true;
                } catch (e) {
                  return false;
                }
              };
            }
          } catch (e2) {}
          \(propsBlock)
          return true;
        })();
        """
        webView.evaluateJavaScript(source) { [weak self] _, _ in
            // Re-read current properties after async wallpaper initialization:
            // a design.json update may have arrived after the initial bootstrap.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self,
                      let webView = self.screenStates[screen]?.webView,
                      let json = self.screenStates[screen]?.injectedPropertiesJSON,
                      let reapply = self.makeApplyUserPropertiesScript(json: json) else {
                    return
                }
                webView.evaluateJavaScript(reapply) { _, _ in }
            }
            DispatchQueue.main.async { completion?() }
        }
    }

    private func completeLiveWallpaperLoad(screen: Int) {
        guard let state = screenStates[screen],
              state.isLoaded,
              state.webView != nil else {
            return
        }
        state.pendingCompletion?(true)
        screenStates[screen]?.pendingCompletion = nil
        dlog("[WebRendererBridge] live Web load complete screen=\(screen)")
    }

    private func completeOfflineBakeLoad(screen: Int) {
        guard let state = screenStates[screen],
              state.isLoaded,
              state.webView != nil else {
            return
        }
        state.pendingCompletion?(true)
        screenStates[screen]?.pendingCompletion = nil
        dlog("[WebRendererBridge] offline Web load complete screen=\(screen)")
    }

    private func beginSettlingOfflineBakeFirstFrame(screen: Int) {
        // 不递增 generation：loadWallpaper 已为本次 set 分配 loadGeneration；
        // settle 复用同一 gen，便于 30s 超时与 stop 统一取消。
        let gen = screenStates[screen]?.firstFrameSettleGeneration ?? 0
        let t0 = Date()
        final class SettleState { var lastThumb: [UInt8]?; var stablePasses = 0; var lastImage: NSImage? }
        let ss = SettleState()
        func finish(_ image: NSImage?, reason: String) {
            guard self.screenStates[screen]?.firstFrameSettleGeneration == gen else { return }
            // 离线烘焙只需在内存中判断首帧稳定；不能写入在线 poster 的 /tmp capture 路径。
            let ok = image != nil
            // 页面已加载但截图失败/始终空白：仍返回成功，后续烘焙帧会在虚拟时钟下重新截图。
            if !ok, self.screenStates[screen]?.isLoaded == true {
                dlog("[WebRendererBridge] offline first-frame weak path screen=\(screen) reason=\(reason); treating as success")
            } else {
                dlog("[WebRendererBridge] offline first-frame settle screen=\(screen) reason=\(reason) hasImage=\(ok)")
            }
            self.screenStates[screen]?.pendingCompletion?(ok || self.screenStates[screen]?.isLoaded == true)
            self.screenStates[screen]?.pendingCompletion = nil
        }
        func scheduleStep() {
            guard self.screenStates[screen]?.firstFrameSettleGeneration == gen,
                  self.screenStates[screen]?.webView != nil else { return }
            let elapsed = Date().timeIntervalSince(t0)
            if elapsed >= OfflineBakeFirstFramePolicy.maxElapsed { finish(ss.lastImage, reason: "timeout"); return }
            self.snapshotWebView(screen: screen) { image in
                guard self.screenStates[screen]?.firstFrameSettleGeneration == gen else { return }
                guard let image = image else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + OfflineBakeFirstFramePolicy.pollInterval) { scheduleStep() }; return
                }
                ss.lastImage = image
                let thumb = self.grayscaleThumb(from: image, dimension: OfflineBakeFirstFramePolicy.thumbDimension)
                defer { if let t = thumb { ss.lastThumb = t } }
                if let prev = ss.lastThumb, let curr = thumb {
                    let diff = Self.meanAbsDiffGrayscale(prev, curr)
                    if diff < OfflineBakeFirstFramePolicy.diffThreshold, elapsed >= OfflineBakeFirstFramePolicy.minElapsed { ss.stablePasses += 1 }
                    else { ss.stablePasses = 0 }
                    if ss.stablePasses >= OfflineBakeFirstFramePolicy.stablePassesRequired { finish(image, reason: "stable"); return }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + OfflineBakeFirstFramePolicy.pollInterval) { scheduleStep() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { scheduleStep() }
    }

    private func snapshotWebView(screen: Int, completion: @escaping (NSImage?) -> Void) {
        guard let webView = screenStates[screen]?.webView else {
            completion(nil)
            return
        }
        if #available(macOS 11.0, *) {
            let config = WKSnapshotConfiguration()
            config.rect = CGRect(origin: .zero, size: webView.bounds.size)
            // 海报、锁屏和暂停静态帧保持 Web 壁纸的原始全画面，不跟随实时 crop 改动。
            webView.takeSnapshot(with: config) { image, _ in DispatchQueue.main.async { completion(image) } }
        } else {
            completion(nil)
        }
    }

    private func grayscaleThumb(from image: NSImage, dimension: Int) -> [UInt8]? {
        guard dimension > 0 else { return nil }
        let target = NSSize(width: dimension, height: dimension)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: dimension, pixelsHigh: dimension,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.clear.set(); NSRect(origin: .zero, size: target).fill()
        image.draw(in: NSRect(origin: .zero, size: target), from: NSRect(origin: .zero, size: image.size),
                   operation: .copy, fraction: 1.0, respectFlipped: false, hints: [.interpolation: NSImageInterpolation.low])
        NSGraphicsContext.restoreGraphicsState()
        var out = [UInt8](repeating: 0, count: dimension * dimension)
        for y in 0..<dimension { for x in 0..<dimension {
            guard let c = rep.colorAt(x: x, y: y) else { continue }
            out[y * dimension + x] = UInt8(min(255, max(0, (c.redComponent * 0.299 + c.greenComponent * 0.587 + c.blueComponent * 0.114) * 255.0)))
        } }
        return out
    }

    private static func meanAbsDiffGrayscale(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        var sum = 0; for i in 0..<a.count { sum += abs(Int(a[i]) - Int(b[i])) }
        return Double(sum) / Double(a.count * 255)
    }

    private func saveImage(_ image: NSImage, screen: Int = 0) -> Bool {
        guard screen >= 0 else {
            dlog("[WebRendererBridge] refusing to write capture for invalid screen=\(screen)")
            return false
        }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return false }
        let path = primaryCapturePath(for: screen)
        do { try png.write(to: URL(fileURLWithPath: path), options: .atomic); return true }
        catch { return false }
    }

    private func saveBitmap(_ bitmap: NSBitmapImageRep, screen: Int = 0) -> Bool {
        guard screen >= 0 else {
            dlog("[WebRendererBridge] refusing to write bitmap capture for invalid screen=\(screen)")
            return false
        }
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return false }
        let path = primaryCapturePath(for: screen)
        do { try png.write(to: URL(fileURLWithPath: path), options: .atomic); return true }
        catch { return false }
    }

    func captureFrame(screen: Int = 0, completion: ((Bool) -> Void)? = nil) {
        guard screen >= 0 else {
            dlog("[WebRendererBridge] refusing capture request for invalid screen=\(screen)")
            completion?(false)
            return
        }
        guard let state = screenStates[screen], state.webView != nil else {
            completion?(false)
            return
        }
        let generation = state.firstFrameSettleGeneration
        let suppressMouse = !state.isOffscreen
        if suppressMouse {
            screenStates[screen]?.mouseCaptureSuppressionDepth += 1
        }
        snapshotWebView(screen: screen) { [weak self] image in
            guard let self,
                  var currentState = self.screenStates[screen],
                  currentState.firstFrameSettleGeneration == generation else {
                completion?(false)
                return
            }
            if suppressMouse {
                currentState.mouseCaptureSuppressionDepth = max(0, currentState.mouseCaptureSuppressionDepth - 1)
                self.screenStates[screen] = currentState
            }
            guard let image else {
                completion?(false)
                return
            }
            completion?(self.saveImage(image, screen: screen))
        }
    }

    func captureImage(screen: Int, completion: @escaping (NSImage?) -> Void) {
        snapshotWebView(screen: screen, completion: completion)
    }

    func windowID(for screen: Int) -> CGWindowID? {
        guard let window = screenStates[screen]?.window,
              window.windowNumber > 0 else {
            return nil
        }
        return CGWindowID(window.windowNumber)
    }

    func resolveOfflineBakeMediaAudioPlan(
        screen: Int,
        fallbackStartOffset: TimeInterval = 0,
        completion: @escaping (WebOfflineBakeMediaAudioPlan?) -> Void
    ) {
        guard let state = screenStates[screen],
              let webView = state.webView else {
            completion(nil)
            return
        }
        let projectContentDir = state.projectContentDir
        let js = """
        (function() {
          try {
            var candidates = Array.prototype.slice.call(document.querySelectorAll('video,audio'))
              .map(function(el) {
                return {
                  source: String(el.currentSrc || el.src || ''),
                  originalMuted: el.__wxBakeOriginalMuted === true,
                  volume: Number(el.volume || 0),
                  paused: !!el.paused,
                  ended: !!el.ended,
                  loop: !!el.loop,
                  currentTime: Number(el.currentTime || 0),
                  videoWidth: Number(el.videoWidth || 0),
                  videoHeight: Number(el.videoHeight || 0),
                  readyState: Number(el.readyState || 0)
                };
              })
              .filter(function(el) {
                return !!el.source
                  && !el.originalMuted
                  && el.volume > 0
                  && el.readyState >= 2
                  && !el.paused
                  && !el.ended;
              })
              .sort(function(a, b) {
                var scoreA = (a.paused ? 0 : 1000000) + a.videoWidth * a.videoHeight;
                var scoreB = (b.paused ? 0 : 1000000) + b.videoWidth * b.videoHeight;
                return scoreB - scoreA;
              });
            return JSON.stringify(candidates.length ? candidates[0] : null);
          } catch (e) {
            return 'null';
          }
        })();
        """
        webView.evaluateJavaScript(js) { result, _ in
            guard let text = result as? String,
                  let data = text.data(using: .utf8),
                  let probe = try? JSONDecoder().decode(WebOfflineBakeMediaAudioProbe.self, from: data),
                  let url = URL(string: probe.source),
                  url.isFileURL,
                  FileManager.default.fileExists(atPath: url.path) else {
                let fallback = projectContentDir.flatMap {
                    Self.resolveProjectBackgroundAudioPlan(
                        contentDir: $0,
                        startOffset: fallbackStartOffset
                    )
                }
                DispatchQueue.main.async { completion(fallback) }
                return
            }
            let plan = WebOfflineBakeMediaAudioPlan(
                sourceURL: url,
                volume: max(0, min(1, probe.volume)),
                loops: probe.loop,
                startOffset: max(0, probe.currentTime.isFinite ? probe.currentTime : 0)
            )
            DispatchQueue.main.async { completion(plan) }
        }
    }

    /// Some Workshop authors create BGM through script-managed `Audio` objects.
    /// If their initialization fails before a DOM media element exists, recover the
    /// intended looping background track from the authored script and property defaults.
    private static func resolveProjectBackgroundAudioPlan(
        contentDir: URL,
        startOffset: TimeInterval = 0
    ) -> WebOfflineBakeMediaAudioPlan? {
        let projectURL = contentDir.appendingPathComponent("project.json")
        guard let projectData = try? Data(contentsOf: projectURL),
              let project = try? JSONSerialization.jsonObject(with: projectData) as? [String: Any],
              let general = project["general"] as? [String: Any],
              let properties = general["properties"] as? [String: Any] else {
            return nil
        }

        let backgroundVolume = properties.reduce(into: Double?.none) { result, item in
            let key = item.key.lowercased()
            guard key.contains("bgm") || key.contains("music") else { return }
            guard key.contains("volume"),
                  let descriptor = item.value as? [String: Any],
                  let value = Self.numericPropertyValue(descriptor["value"]) else {
                return
            }
            result = value > 1 ? value / 100 : value
        }
        guard let backgroundVolume, backgroundVolume > 0 else {
            return nil
        }

        let ignoredScriptNames = Set(["spine-player.js", "spine-player4.1.js"])
        let scriptURLs = (try? FileManager.default.contentsOfDirectory(
            at: contentDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ))?.filter {
            $0.pathExtension.lowercased() == "js"
                && !ignoredScriptNames.contains($0.lastPathComponent.lowercased())
        } ?? []

        let expression = try? NSRegularExpression(
            pattern: #"new\s+Audio\s*\(\s*["']([^"']+\.(?:aac|flac|m4a|mp3|ogg|opus|wav))["']\s*\)"#,
            options: [.caseInsensitive]
        )
        guard let expression else { return nil }

        var best: (url: URL, score: Int, loops: Bool)?
        for scriptURL in scriptURLs {
            guard let scriptData = try? Data(contentsOf: scriptURL),
                  let source = String(data: scriptData, encoding: .utf8)
                    ?? String(data: scriptData, encoding: .isoLatin1) else {
                continue
            }
            let nsSource = source as NSString
            let fullRange = NSRange(location: 0, length: nsSource.length)
            for match in expression.matches(in: source, options: [], range: fullRange) {
                guard match.numberOfRanges >= 2 else { continue }
                let relativePath = nsSource.substring(with: match.range(at: 1))
                let candidateURL: URL
                if let absoluteURL = URL(string: relativePath), absoluteURL.isFileURL {
                    candidateURL = absoluteURL
                } else {
                    candidateURL = contentDir.appendingPathComponent(relativePath)
                }
                guard FileManager.default.fileExists(atPath: candidateURL.path) else {
                    continue
                }

                let before = max(0, match.range.location - 240)
                let after = min(nsSource.length, NSMaxRange(match.range) + 360)
                let context = nsSource.substring(with: NSRange(location: before, length: after - before))
                    .lowercased()
                var score = 0
                if context.range(of: #"\bbgm\b|\bbackground\s*music\b"#, options: .regularExpression) != nil {
                    score += 160
                }
                if context.range(of: #"\bloop\s*=\s*true\b"#, options: .regularExpression) != nil {
                    score += 80
                }
                let fileName = candidateURL.lastPathComponent.lowercased()
                if fileName.range(of: #"bgm|music|soundtrack|ost"#, options: .regularExpression) != nil {
                    score += 60
                }
                if fileName.range(of: #"click|voice|idle|clicked|_se|soundeffect"#, options: .regularExpression) != nil {
                    score -= 240
                }
                guard score >= 160 else { continue }

                let loops = context.range(of: #"\bloop\s*=\s*true\b"#, options: .regularExpression) != nil
                if best == nil || score > best!.score {
                    best = (candidateURL, score, loops)
                }
            }
        }

        guard let best else { return nil }
        dlog(
            "[WebRendererBridge] offline bake recovered script BGM: \(best.url.lastPathComponent) score=\(best.score)"
        )
        return WebOfflineBakeMediaAudioPlan(
            sourceURL: best.url,
            volume: max(0, min(1, backgroundVolume)),
            loops: best.loops,
            startOffset: max(0, startOffset)
        )
    }

    private static func numericPropertyValue(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            return number.doubleValue
        case let string as String:
            return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    /// Freeze the page's current media state before the capture stream begins.
    ///
    /// Only media that the wallpaper itself had already started are resumed later.
    /// This avoids accidentally playing click / idle voice tracks during a bake.
    func prepareOfflineBakeRealtimeMedia(
        screen: Int,
        completion: @escaping (Bool) -> Void
    ) {
        guard let webView = screenStates[screen]?.webView else {
            completion(false)
            return
        }
        let token = UUID().uuidString
        let js = """
        (function() {
          try {
            var token = '\(token)';
            var media = Array.prototype.slice.call(document.querySelectorAll('video,audio'));
            var loopVideos = media.filter(function(el) {
              return el instanceof HTMLVideoElement
                && !!el.loop
                && !!String(el.currentSrc || el.src || '');
            });
            var openingCandidates = media.filter(function(el) {
              return el instanceof HTMLVideoElement
                && !el.loop
                && (!el.paused || !!el.autoplay)
                && !!String(el.currentSrc || el.src || '')
                && el.readyState >= 2
                && isFinite(el.duration)
                && el.duration > 0;
            }).sort(function(a, b) {
              return (b.videoWidth * b.videoHeight) - (a.videoWidth * a.videoHeight);
            });
            // Skip an opening only when the page has a concrete looping video to
            // transition into. A single non-looping video may be the actual wallpaper.
            var opening = loopVideos.length && openingCandidates.length
              ? openingCandidates[0] : null;
            window.__wxBakeRealtimeState = {
              token: token,
              openingIndex: opening ? media.indexOf(opening) : -1,
              loopVideoIndexes: loopVideos.map(function(el) { return media.indexOf(el); })
            };
            var waits = media.map(function(el) {
              return new Promise(function(resolve) {
                try {
                  el.__wxBakeShouldResume = !el.paused || !!el.autoplay;
                  el.pause();
                  if (!isFinite(el.duration) || el.duration <= 0
                    || (isFinite(el.currentTime) && Math.abs(el.currentTime) <= 0.0005)) {
                    resolve();
                    return;
                  }
                  var done = false;
                  var timer = setTimeout(finish, 1200);
                  function finish() {
                    if (done) return;
                    done = true;
                    clearTimeout(timer);
                    try { el.removeEventListener('seeked', finish); } catch (e) {}
                    resolve();
                  }
                  el.addEventListener('seeked', finish, { once: true });
                  el.currentTime = 0;
                  if (!el.seeking && isFinite(el.currentTime)
                    && Math.abs(el.currentTime) <= 0.0005) {
                    finish();
                  }
                } catch (e) {
                  resolve();
                }
              });
            });
            Promise.all(waits).then(function() {
              window.__wxBakeRealtimeReadyToken = token;
            }, function() {
              window.__wxBakeRealtimeReadyToken = token;
            });
            return true;
          } catch (e) {
            return false;
          }
        })();
        """
        webView.evaluateJavaScript(js) { result, _ in
            guard (result as? Bool) == true else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            self.waitForOfflineBakeRealtimeToken(
                webView: webView,
                token: token,
                completion: completion
            )
        }
    }

    func startOfflineBakeRealtimeMedia(
        screen: Int,
        warmup: TimeInterval,
        completion: @escaping (Bool) -> Void
    ) {
        guard let webView = screenStates[screen]?.webView else {
            completion(false)
            return
        }
        let token = UUID().uuidString
        let js = """
        (function() {
          try {
            var token = '\(token)';
            var warmupMS = \(Int(max(0, warmup * 1_000).rounded()));
            var media = Array.prototype.slice.call(document.querySelectorAll('video,audio'));
            var state = window.__wxBakeRealtimeState || {};
            var opening = state.openingIndex >= 0 ? media[state.openingIndex] : null;
            var loopVideos = Array.isArray(state.loopVideoIndexes)
              ? state.loopVideoIndexes.map(function(index) { return media[index]; }).filter(Boolean)
              : [];

            function play(el) {
              try {
                var p = el.play();
                if (p && typeof p.catch === 'function') p.catch(function(){});
              } catch (e) {}
            }

            // The page owns the media topology. Resume only the elements that were
            // active at the stable load point; script event handlers can start their
            // own successor media (for example, opening.onended -> loop.play()).
            media.forEach(function(el) {
              if (el !== opening && el.__wxBakeShouldResume) play(el);
            });

            if (opening && isFinite(opening.duration) && opening.duration > 0) {
              try {
                opening.currentTime = Math.max(
                  0,
                  opening.duration - Math.min(0.08, opening.duration * 0.1)
                );
              } catch (e) {}
              play(opening);
            }

            var settled = false;
            var startedAt = Date.now();
            var transitionDeadlineMS = 2500;
            function finish() {
              if (settled) return;
              settled = true;
              setTimeout(function() {
                window.__wxBakeRealtimeStartedToken = token;
              }, warmupMS);
            }
            function loopIsRunning() {
              return loopVideos.some(function(el) {
                return el && el.readyState >= 2 && !el.paused && !el.ended;
              });
            }
            function waitForStableLoop() {
              if (!opening || loopIsRunning() || Date.now() - startedAt >= transitionDeadlineMS) {
                finish();
                return;
              }
              setTimeout(waitForStableLoop, 25);
            }
            waitForStableLoop();
          } catch (e) {}
          return true;
        })();
        """
        webView.evaluateJavaScript(js) { _, _ in
            self.waitForOfflineBakeRealtimeStartToken(
                webView: webView,
                token: token,
                completion: completion
            )
        }
    }

    private func waitForOfflineBakeRealtimeToken(
        webView: WKWebView,
        token: String,
        attempt: Int = 0,
        completion: @escaping (Bool) -> Void
    ) {
        let escapedToken = token.replacingOccurrences(of: "'", with: "\\'")
        let js = "window.__wxBakeRealtimeReadyToken === '\(escapedToken)';"
        webView.evaluateJavaScript(js) { result, _ in
            if (result as? Bool) == true {
                DispatchQueue.main.async { completion(true) }
                return
            }
            if attempt >= 240 {
                DispatchQueue.main.async { completion(false) }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self, weak webView] in
                guard let self, let webView else {
                    completion(false)
                    return
                }
                self.waitForOfflineBakeRealtimeToken(
                    webView: webView,
                    token: token,
                    attempt: attempt + 1,
                    completion: completion
                )
            }
        }
    }

    private func waitForOfflineBakeRealtimeStartToken(
        webView: WKWebView,
        token: String,
        attempt: Int = 0,
        completion: @escaping (Bool) -> Void
    ) {
        let escapedToken = token.replacingOccurrences(of: "'", with: "\\'")
        let js = "window.__wxBakeRealtimeStartedToken === '\(escapedToken)';"
        webView.evaluateJavaScript(js) { result, _ in
            if (result as? Bool) == true {
                DispatchQueue.main.async { completion(true) }
                return
            }
            // Opening transition (up to 2.5s) + the steady-state warmup can exceed
            // the old 8s limit before the recorder is intentionally armed.
            if attempt >= 750 {
                DispatchQueue.main.async { completion(false) }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self, weak webView] in
                guard let self, let webView else {
                    completion(false)
                    return
                }
                self.waitForOfflineBakeRealtimeStartToken(
                    webView: webView,
                    token: token,
                    attempt: attempt + 1,
                    completion: completion
                )
            }
        }
    }

    /// Enable offline-bake virtual clock (no-op if script missing).
    func enableOfflineBakeClock(screen: Int, completion: (() -> Void)? = nil) {
        guard let webView = screenStates[screen]?.webView else {
            completion?()
            return
        }
        webView.evaluateJavaScript(
            "(function(){try{if(window.__wxBakeClock){window.__wxBakeClock.enable();return true;}return false;}catch(e){return false;}})();"
        ) { _, _ in
            DispatchQueue.main.async { completion?() }
        }
    }

    /// Samples the active HTML video's presented-frame cadence before bake mode freezes media.
    func probeOfflineBakeMediaFrameRate(
        screen: Int,
        completion: @escaping (Double?) -> Void
    ) {
        guard let webView = screenStates[screen]?.webView else {
            completion(nil)
            return
        }
        let js = """
        (function() {
          try {
            if (!window.__wxBakeClock
                || typeof window.__wxBakeClock.probeMediaFrameRate !== 'function') {
              return Promise.resolve(null);
            }
            return window.__wxBakeClock.probeMediaFrameRate();
          } catch (e) {
            return Promise.resolve(null);
          }
        })();
        """
        webView.evaluateJavaScript(js) { result, _ in
            let value = (result as? NSNumber)?.doubleValue
            DispatchQueue.main.async {
                completion(value?.isFinite == true && (value ?? 0) >= 10 ? value : nil)
            }
        }
    }

    /// Advance wallpaper content time to `seconds`, then wait for real rAF paints.
    /// Real rAF keeps Spine/WebGL loops alive. This also awaits media seek/present before
    /// returning, so the snapshot corresponds to the requested virtual content timestamp.
    func setOfflineBakeContentTime(
        screen: Int,
        seconds: Double,
        paintFrames: Int = 2,
        completion: (() -> Void)? = nil
    ) {
        guard let webView = screenStates[screen]?.webView else {
            completion?()
            return
        }
        let ms = max(0, seconds) * 1000.0
        let frames = max(1, paintFrames)
        let token = UUID().uuidString
        // `evaluateJavaScript` does not reliably await a returned JavaScript Promise.
        // Start the async page work, then poll a token written only after media seek + paint.
        let js = String(
            format: """
            (function(){
              try {
                if (!window.__wxBakeClock
                    || typeof window.__wxBakeClock.advanceAndPaint !== 'function') return false;
                window.__wxBakeClock.advanceAndPaint(%.3f, %d, '%@');
                return true;
              } catch (e) { return false; }
            })();
            """,
            ms,
            frames,
            token
        )
        webView.evaluateJavaScript(js) { result, _ in
            guard (result as? Bool) == true else {
                DispatchQueue.main.async { completion?() }
                return
            }
            self.waitForOfflineBakeFrameReady(
                webView: webView,
                token: token,
                completion: completion
            )
        }
    }

    private func waitForOfflineBakeFrameReady(
        webView: WKWebView,
        token: String,
        attempt: Int = 0,
        completion: (() -> Void)?
    ) {
        let escapedToken = token.replacingOccurrences(of: "'", with: "\\'")
        let js = """
        Boolean(window.__wxBakeClock
          && window.__wxBakeClock.lastReadyToken === '\(escapedToken)');
        """
        webView.evaluateJavaScript(js) { result, _ in
            if (result as? Bool) == true || attempt >= 240 {
                DispatchQueue.main.async { completion?() }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self, weak webView] in
                guard let self, let webView else {
                    completion?()
                    return
                }
                self.waitForOfflineBakeFrameReady(
                    webView: webView,
                    token: token,
                    attempt: attempt + 1,
                    completion: completion
                )
            }
        }
    }

}

// MARK: - Offline Web Bake

private enum WebOfflineBakeError: LocalizedError {
    case invalidArguments(String)
    case rendererFailed(String)
    case writerFailed(String)
    case captureFailed
    case streamCaptureFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let message): return message
        case .rendererFailed(let message): return message
        case .writerFailed(let message): return message
        case .captureFailed: return "无法从 Web 渲染器捕获画面"
        case .streamCaptureFailed(let message): return message
        }
    }
}

private struct WebOfflineBakeMediaAudioProbe: Decodable {
    let source: String
    let volume: Double
    let loop: Bool
    let currentTime: Double
}

private struct WebOfflineBakeMediaAudioPlan {
    let sourceURL: URL
    let volume: Double
    let loops: Bool
    var startOffset: TimeInterval = 0
}

/// Records a display-backed Web window at its actual compositor cadence. Unlike
/// `WKWebView.takeSnapshot`, SCStream delivers new WindowServer frames only when
/// the page has genuinely presented them, so Web videos are not converted into
/// a fixed-FPS sequence of stale snapshots.
private final class WebRealtimeStreamRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct Options {
        let windowID: CGWindowID
        let width: Int
        let height: Int
        let duration: TimeInterval
        let maximumFrameRate: Double
        let outputURL: URL
        let captureReady: () -> Void
    }

    private let options: Options
    private let progress: (Int, TimeInterval) -> Void
    private let completion: (Result<Void, Error>) -> Void
    private let sampleQueue = DispatchQueue(label: "com.waifux.web-bake.stream")

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var firstPresentationTime: CMTime?
    private var lastPresentationTimeValue: CMTimeValue?
    private var writtenFrameCount = 0
    private var writerBackpressureDropCount = 0
    private var isFinishing = false
    private var didComplete = false
    private var isRecording = false

    init(
        options: Options,
        progress: @escaping (Int, TimeInterval) -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        self.options = options
        self.progress = progress
        self.completion = completion
    }

    func start() {
        Task {
            do {
                try FileManager.default.createDirectory(
                    at: options.outputURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? FileManager.default.removeItem(at: options.outputURL)

                let writer = try AVAssetWriter(outputURL: options.outputURL, fileType: .mp4)
                let input = AVAssetWriterInput(
                    mediaType: .video,
                    outputSettings: [
                        AVVideoCodecKey: AVVideoCodecType.h264,
                        AVVideoWidthKey: options.width,
                        AVVideoHeightKey: options.height,
                        AVVideoCompressionPropertiesKey: [
                            AVVideoAverageBitRateKey: Self.averageBitRate(
                                width: options.width,
                                height: options.height,
                                fps: 60
                            ),
                            AVVideoExpectedSourceFrameRateKey: 60,
                            AVVideoMaxKeyFrameIntervalKey: 120,
                            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                            AVVideoAllowFrameReorderingKey: false
                        ] as [String: Any]
                    ]
                )
                // ScreenCaptureKit supplies the source at compositor cadence. Treat it as
                // real time so AVAssetWriter keeps its hardware encode path draining instead
                // of accumulating a large offline backlog.
                input.expectsMediaDataInRealTime = true
                let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                    assetWriterInput: input,
                    sourcePixelBufferAttributes: [
                        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                        kCVPixelBufferWidthKey as String: options.width,
                        kCVPixelBufferHeightKey as String: options.height
                    ]
                )
                guard writer.canAdd(input) else {
                    throw WebOfflineBakeError.writerFailed("无法添加 Web 流视频编码输入")
                }
                writer.add(input)
                guard writer.startWriting() else {
                    throw WebOfflineBakeError.writerFailed(writer.error?.localizedDescription ?? "无法启动 Web 流视频编码")
                }
                writer.startSession(atSourceTime: .zero)
                self.writer = writer
                self.videoInput = input
                self.adaptor = adaptor

                let content = try await SCShareableContent.current
                guard let window = content.windows.first(where: { $0.windowID == options.windowID }) else {
                    throw WebOfflineBakeError.streamCaptureFailed("ScreenCaptureKit 未找到 Web 烘焙窗口")
                }
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let configuration = SCStreamConfiguration()
                configuration.width = options.width
                configuration.height = options.height
                // Keep the output at standard display/video cadence. The source PTS
                // remain intact, so 59.56fps workshop media is not forced through
                // a seek/pause resampling loop.
                let rate = max(1, min(120, options.maximumFrameRate))
                configuration.minimumFrameInterval = CMTime(
                    value: 1,
                    timescale: CMTimeScale(rate.rounded())
                )
                configuration.pixelFormat = kCVPixelFormatType_32BGRA
                configuration.queueDepth = 8
                configuration.scalesToFit = true
                configuration.showsCursor = false
                configuration.ignoreShadowsSingleWindow = true
                configuration.ignoreGlobalClipSingleWindow = true
                configuration.captureResolution = .nominal

                let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
                self.stream = stream
                DispatchQueue.main.async {
                    self.options.captureReady()
                }
                try await stream.startCapture()
            } catch {
                finish(.failure(error))
            }
        }
    }

    func beginRecording() {
        sampleQueue.async { [weak self] in
            guard let self, !self.isFinishing else { return }
            self.firstPresentationTime = nil
            self.lastPresentationTimeValue = nil
            self.isRecording = true
        }
    }

    func failIfNoFirstFrame(after timeout: TimeInterval) {
        sampleQueue.asyncAfter(deadline: .now() + max(1, timeout)) { [weak self] in
            guard let self,
                  !self.isFinishing,
                  self.writtenFrameCount == 0 else {
                return
            }
            self.finish(.failure(
                WebOfflineBakeError.streamCaptureFailed("ScreenCaptureKit 未在限定时间内返回 Web 烘焙画面")
            ))
        }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen,
              CMSampleBufferIsValid(sampleBuffer),
              let pixelBuffer = sampleBuffer.imageBuffer else {
            return
        }
        guard !isFinishing,
              isRecording,
              let writer,
              let videoInput,
              let adaptor,
              writer.status == .writing else {
            return
        }

        let sourceTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard sourceTime.isValid else { return }
        if firstPresentationTime == nil {
            firstPresentationTime = sourceTime
        }
        guard let firstPresentationTime else { return }
        let elapsed = CMTimeGetSeconds(CMTimeSubtract(sourceTime, firstPresentationTime))
        guard elapsed.isFinite else { return }

        if elapsed >= options.duration {
            finishWriting()
            return
        }
        guard videoInput.isReadyForMoreMediaData else {
            writerBackpressureDropCount += 1
            return
        }
        // Preserve the compositor's real cadence. ScreenCaptureKit occasionally emits
        // repeated timestamps around transactions, so normalize only those collisions.
        let relativeSourceTime = CMTimeSubtract(sourceTime, firstPresentationTime)
        let scaledSourceTime = CMTimeConvertScale(
            relativeSourceTime,
            timescale: 600,
            method: .roundHalfAwayFromZero
        )
        let presentationTimeValue = max(
            scaledSourceTime.value,
            (lastPresentationTimeValue ?? -1) + 1
        )
        let presentationTime = CMTime(
            value: presentationTimeValue,
            timescale: 600
        )
        guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
            finish(.failure(
                WebOfflineBakeError.writerFailed(
                    writer.error?.localizedDescription ?? "写入 Web 流视频帧失败"
                )
            ))
            return
        }

        writtenFrameCount += 1
        lastPresentationTimeValue = presentationTimeValue
        progress(writtenFrameCount, elapsed)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard !isFinishing else { return }
        finish(.failure(WebOfflineBakeError.streamCaptureFailed(error.localizedDescription)))
    }

    private func finishWriting() {
        guard !isFinishing else { return }
        isFinishing = true
        let stream = stream
        Task {
            try? await stream?.stopCapture()
            guard let writer, let videoInput else {
                finish(.failure(WebOfflineBakeError.writerFailed("Web 流视频编码器未初始化")))
                return
            }
            videoInput.markAsFinished()
            nonisolated(unsafe) let completedWriter = writer
            writer.finishWriting { [weak self] in
                guard let self else { return }
                if completedWriter.status == .completed, self.writtenFrameCount > 0 {
                    fputs(
                        "[web-bake] compositor stream writer-backpressure-drops=\(self.writerBackpressureDropCount)\n",
                        stderr
                    )
                    fflush(stderr)
                    self.finish(.success(()))
                } else {
                    self.finish(.failure(
                        WebOfflineBakeError.writerFailed(
                            completedWriter.error?.localizedDescription ?? "Web 流视频编码完成失败"
                        )
                    ))
                }
            }
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard !didComplete else { return }
        didComplete = true
        isFinishing = true
        if case .failure = result {
            let activeStream = stream
            Task {
                try? await activeStream?.stopCapture()
            }
            writer?.cancelWriting()
            try? FileManager.default.removeItem(at: options.outputURL)
        }
        completion(result)
    }

    private static func averageBitRate(width: Int, height: Int, fps: Double) -> Int {
        let raw = Double(max(1, width) * max(1, height)) * max(15, fps) * 0.10
        return Int(min(max(raw, 8_000_000), 100_000_000))
    }
}

/// Receives interleaved stereo Int16 PCM from the offline WKWebView and writes it as
/// AAC through the same `AVAssetWriter` used for the baked video.
private final class WebOfflineBakeAudioRecorder {
    private static let channels = 2
    private static let bytesPerSample = MemoryLayout<Int16>.size
    private static let bytesPerFrame = channels * bytesPerSample
    private static let silenceChunkFrames = 4_096

    private let sampleRate: Double
    private let timescale: CMTimeScale
    private let maximumFrameCount: Int64

    private weak var audioInput: AVAssetWriterInput?
    private var formatDescription: CMAudioFormatDescription?
    private var pendingPCM: [Data] = []
    private var acceptedFrameCount: Int64 = 0
    private var writtenFrameCount: Int64 = 0
    private var capturedPCMChunkCount = 0
    private var capturedPCMFrameCount: Int64 = 0
    private var isCaptureOpen = false
    private var finishRequested = false
    private var endReceived = false
    private var inputMarkedFinished = false
    private var retryScheduled = false
    private var finishCompletion: (() -> Void)?

    init(sampleRate: Double, duration: TimeInterval) {
        let normalizedRate = sampleRate.isFinite && sampleRate >= 8_000
            ? sampleRate
            : 48_000
        self.sampleRate = normalizedRate
        self.timescale = CMTimeScale(max(8_000, min(192_000, normalizedRate.rounded())))
        self.maximumFrameCount = Int64(
            max(0, (max(0, duration) * normalizedRate).rounded(.toNearestOrAwayFromZero))
        )
    }

    func makeWriterInput() -> AVAssetWriterInput {
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: Self.channels,
                AVEncoderBitRateKey: 192_000
            ]
        )
        input.expectsMediaDataInRealTime = false
        audioInput = input
        return input
    }

    func beginCapture() {
        isCaptureOpen = true
        finishRequested = false
        endReceived = false
    }

    func receiveStart() {
        isCaptureOpen = true
    }

    func receivePCM(sampleRate: Double, channels: Int, base64PCM: String) {
        guard isCaptureOpen,
              !inputMarkedFinished,
              channels == Self.channels,
              abs(sampleRate - self.sampleRate) < 100,
              let decoded = Data(base64Encoded: base64PCM),
              !decoded.isEmpty else {
            return
        }
        let completeFrames = decoded.count / Self.bytesPerFrame
        guard completeFrames > 0 else { return }

        let remaining = maximumFrameCount - acceptedFrameCount
        guard remaining > 0 else { return }
        let acceptedFrames = min(Int64(completeFrames), remaining)
        let acceptedBytes = Int(acceptedFrames) * Self.bytesPerFrame
        let data = acceptedBytes == decoded.count ? decoded : decoded.prefix(acceptedBytes)

        pendingPCM.append(Data(data))
        acceptedFrameCount += acceptedFrames
        capturedPCMChunkCount += 1
        capturedPCMFrameCount += acceptedFrames
        drainPendingPCM()
    }

    func receiveEnd() {
        endReceived = true
        finishIfReady()
    }

    func finishCapture(completion: @escaping () -> Void) {
        guard !inputMarkedFinished else {
            completion()
            return
        }
        finishRequested = true
        finishCompletion = completion
        // A malformed page may never send `end`; preserve a valid file rather than
        // blocking the bake forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.finishIfReady(force: true)
        }
        finishIfReady()
    }

    func cancel() {
        isCaptureOpen = false
        pendingPCM.removeAll()
        finishCompletion = nil
    }

    private func finishIfReady(force: Bool = false) {
        guard finishRequested, !inputMarkedFinished,
              endReceived || force else {
            return
        }
        isCaptureOpen = false
        appendSilenceToDuration()
        drainPendingPCM()
    }

    private func appendSilenceToDuration() {
        let missing = maximumFrameCount - acceptedFrameCount
        guard missing > 0 else { return }
        var remaining = missing
        while remaining > 0 {
            let frames = min(Int64(Self.silenceChunkFrames), remaining)
            pendingPCM.append(Data(repeating: 0, count: Int(frames) * Self.bytesPerFrame))
            acceptedFrameCount += frames
            remaining -= frames
        }
    }

    private func drainPendingPCM() {
        guard let audioInput else {
            markFinished()
            return
        }
        while !pendingPCM.isEmpty, audioInput.isReadyForMoreMediaData {
            let data = pendingPCM.removeFirst()
            guard appendPCM(data) else {
                dlog("[WebOfflineBakeAudioRecorder] Failed to append PCM sample buffer")
                pendingPCM.removeAll()
                markFinished()
                return
            }
        }
        if !pendingPCM.isEmpty {
            scheduleDrainRetry()
        } else if finishRequested && (endReceived || !isCaptureOpen) {
            markFinished()
        }
    }

    private func scheduleDrainRetry() {
        guard !retryScheduled else { return }
        retryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.retryScheduled = false
            self.drainPendingPCM()
        }
    }

    private func markFinished() {
        guard !inputMarkedFinished else { return }
        inputMarkedFinished = true
        audioInput?.markAsFinished()
        fputs(
            "[web-bake] audio pcm chunks=\(capturedPCMChunkCount) frames=\(capturedPCMFrameCount) padded=\(max(0, acceptedFrameCount - capturedPCMFrameCount))\n",
            stderr
        )
        fflush(stderr)
        let completion = finishCompletion
        finishCompletion = nil
        completion?()
    }

    private func appendPCM(_ data: Data) -> Bool {
        guard let audioInput,
              let formatDescription = makeFormatDescription() else {
            return false
        }
        let frames = data.count / Self.bytesPerFrame
        guard frames > 0 else { return true }

        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == kCMBlockBufferNoErr, let blockBuffer else {
            return false
        }
        let replaceStatus = data.withUnsafeBytes { bytes -> OSStatus in
            guard let baseAddress = bytes.baseAddress else {
                return kCMBlockBufferBadPointerParameterErr
            }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: data.count
            )
        }
        guard replaceStatus == kCMBlockBufferNoErr else {
            return false
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: timescale),
            presentationTimeStamp: CMTime(value: writtenFrameCount, timescale: timescale),
            decodeTimeStamp: .invalid
        )
        var sampleSize = Self.bytesPerFrame
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: frames,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr,
              let sampleBuffer,
              audioInput.append(sampleBuffer) else {
            return false
        }
        writtenFrameCount += Int64(frames)
        return true
    }

    private func makeFormatDescription() -> CMAudioFormatDescription? {
        if let formatDescription { return formatDescription }

        var asbd = AudioStreamBasicDescription(
            mSampleRate: Double(timescale),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(Self.bytesPerFrame),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(Self.bytesPerFrame),
            mChannelsPerFrame: UInt32(Self.channels),
            mBitsPerChannel: UInt32(Self.bytesPerSample * 8),
            mReserved: 0
        )
        var description: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &description
        )
        guard status == noErr else { return nil }
        formatDescription = description
        return description
    }
}

private final class WebOfflineBakeRunner {
    struct Options {
        let path: String
        let width: Int
        let height: Int
        /// `nil` means profile the loaded wallpaper's active video cadence.
        let requestedFPS: Double?
        let duration: TimeInterval
        let outputURL: URL
        let userPropertiesJSON: String?
    }

    private let options: Options
    private let completion: (Result<Void, Error>) -> Void
    private let renderer = WebRendererBridge.shared
    /// 目标进度帧数（以 60fps 近似显示进度；实际成片保留合成器 PTS）。
    private var totalFrameCount = 0
    /// 旧快照烘焙的内容时间步长；保留仅为兼容旧实现。
    private var contentFrameInterval: TimeInterval = 1.0 / 60.0
    private var effectiveFPS: Double = 60

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var mediaAudioPlan: WebOfflineBakeMediaAudioPlan?
    private var temporaryOutputURL: URL?
    private var captureStartedAt: Date?
    private var nextFrameIndex = 0
    private var writtenFrameCount = 0
    private var isFinishing = false
    private var didComplete = false
    private var bakeClockEnabled = false
    private var realtimeRecorder: WebRealtimeStreamRecorder?
    private var lastProgressEmissionDate: Date?

    private static let fallbackFrameRate = 60.0
    private static let minimumAutomaticFrameRate = 15.0
    private static let maximumAutomaticFrameRate = 120.0
    private static let presentationTimescale: CMTimeScale = 1_000_000
    /// Match the live Web poster sampler: complex Web/Spine wallpapers often create
    /// their steady animation and BGM several seconds after the document first loads.
    private static let realtimeCaptureWarmup: TimeInterval = 7.0

    /// 4K60 下约 50Mbps（~0.1 bpp），明显优于旧的 width×height×3（~25Mbps）。
    private static func averageBitRate(width: Int, height: Int, fps: Double) -> Int {
        let pixels = max(1, width) * max(1, height)
        let safeFPS = max(minimumAutomaticFrameRate, fps)
        // ~0.10 bit/pixel/frame，并按分辨率夹紧，避免 1080p 过低或 5K 失控。
        let raw = Double(pixels) * safeFPS * 0.10
        return Int(min(max(raw, 8_000_000), 100_000_000))
    }

    init(options: Options, completion: @escaping (Result<Void, Error>) -> Void) {
        self.options = options
        self.completion = completion
    }

    func start() {
        let requestedFPSIsValid = options.requestedFPS.map {
            $0.isFinite && $0 >= Self.minimumAutomaticFrameRate
        } ?? true
        guard options.width >= 2,
              options.height >= 2,
              options.duration > 0,
              requestedFPSIsValid else {
            finish(.failure(WebOfflineBakeError.invalidArguments("烘焙尺寸、帧率或时长无效")))
            return
        }

        // 旧版本的首帧稳定逻辑可能误写离线 screen=-1 的 PNG；本次烘焙先清理残留。
        try? FileManager.default.removeItem(
            atPath: primaryCapturePath(for: WebRendererBridge.offlineBakeScreen)
        )
        renderer.loadWallpaper(
            path: options.path,
            width: options.width,
            height: options.height,
            screen: nil,
            offscreen: true,
            userPropertiesJSON: options.userPropertiesJSON
        ) { [weak self] success in
            guard let self else { return }
            guard success else {
                self.finish(.failure(WebOfflineBakeError.rendererFailed("Web 壁纸加载失败")))
                return
            }
            // Let the page create its default media nodes, then record the actual
            // compositor output instead of sampling a virtual clock frame by frame.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, !self.isFinishing else { return }
                self.prepareAndBeginRealtimeStreamCapture()
            }
        }
    }

    private func prepareAndBeginRealtimeStreamCapture() {
        renderer.prepareOfflineBakeRealtimeMedia(
            screen: WebRendererBridge.offlineBakeScreen
        ) { [weak self] ready in
            guard let self, !self.isFinishing else { return }
            guard ready else {
                self.finish(.failure(
                    WebOfflineBakeError.rendererFailed("Web 壁纸媒体未能准备为实时烘焙")
                ))
                return
            }
            guard let windowID = self.renderer.windowID(for: WebRendererBridge.offlineBakeScreen) else {
                self.finish(.failure(
                    WebOfflineBakeError.streamCaptureFailed("未找到 Web 烘焙窗口")
                ))
                return
            }
            self.beginRealtimeStreamCapture(windowID: windowID)
        }
    }

    private func resolveFrameRateAndStartEncoding() {
        if let requestedFPS = options.requestedFPS {
            beginEncoding(frameRate: normalizedFrameRate(requestedFPS), source: "requested")
            return
        }
        renderer.probeOfflineBakeMediaFrameRate(screen: WebRendererBridge.offlineBakeScreen) { [weak self] probedFPS in
            guard let self, !self.isFinishing else { return }
            let frameRate = probedFPS.map(self.normalizedFrameRate) ?? Self.fallbackFrameRate
            self.beginEncoding(frameRate: frameRate, source: probedFPS == nil ? "snapshot-fallback" : "media-probe")
        }
    }

    private func beginRealtimeStreamCapture(windowID: CGWindowID) {
        guard !isFinishing else { return }

        effectiveFPS = normalizedFrameRate(options.requestedFPS ?? Self.fallbackFrameRate)
        totalFrameCount = max(1, Int((options.duration * effectiveFPS).rounded(.up)))
        nextFrameIndex = 0
        writtenFrameCount = 0
        captureStartedAt = nil
        let temporaryURL = options.outputURL.deletingLastPathComponent()
            .appendingPathComponent(".web-bake-\(UUID().uuidString).stream.mp4")
        try? FileManager.default.removeItem(at: temporaryURL)
        temporaryOutputURL = temporaryURL
        emitProgress(phase: "准备", progress: 0)
        fputs(
            String(
                format: "[web-bake] compositor stream target=%dx%d duration=%.1fs max-fps=%.3f cadence=wallpaper\n",
                options.width,
                options.height,
                options.duration,
                effectiveFPS
            ),
            stderr
        )
        fflush(stderr)

        let recorder = WebRealtimeStreamRecorder(
            options: .init(
                windowID: windowID,
                width: options.width,
                height: options.height,
                duration: options.duration,
                maximumFrameRate: effectiveFPS,
                outputURL: temporaryURL,
                captureReady: { [weak self] in
                    guard let self, !self.isFinishing else { return }
                    self.emitProgress(phase: "预热", progress: 0)
                    self.renderer.startOfflineBakeRealtimeMedia(
                        screen: WebRendererBridge.offlineBakeScreen,
                        warmup: Self.realtimeCaptureWarmup
                    ) { [weak self] ready in
                        guard let self, !self.isFinishing else { return }
                        guard ready else {
                            self.finish(.failure(
                                WebOfflineBakeError.rendererFailed("Web 壁纸媒体未能完成预热")
                            ))
                            return
                        }
                        self.renderer.resolveOfflineBakeMediaAudioPlan(
                            screen: WebRendererBridge.offlineBakeScreen,
                            fallbackStartOffset: Self.realtimeCaptureWarmup
                        ) { [weak self] plan in
                            guard let self, !self.isFinishing else { return }
                            self.mediaAudioPlan = plan
                            let audioSource = plan?.sourceURL.lastPathComponent ?? "none"
                            fputs(
                                String(
                                    format: "[web-bake] media stabilized warmup=%.1fs audio=%@\n",
                                    Self.realtimeCaptureWarmup,
                                    audioSource
                                ),
                                stderr
                            )
                            fflush(stderr)
                            self.emitProgress(phase: "预热", progress: 0.15)
                            self.captureStartedAt = Date()
                            self.realtimeRecorder?.beginRecording()
                        }
                    }
                }
            ),
            progress: { [weak self] frameCount, elapsed in
                DispatchQueue.main.async {
                    guard let self, !self.isFinishing else { return }
                    self.writtenFrameCount = frameCount
                    self.nextFrameIndex = frameCount
                    self.emitProgress(
                        phase: "录制",
                        progress: min(
                            0.99,
                            max(0.15, 0.15 + 0.84 * elapsed / self.options.duration)
                        )
                    )
                }
            },
            completion: { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.realtimeRecorder = nil
                    if case .success = result {
                        let wall = self.captureStartedAt.map { Date().timeIntervalSince($0) } ?? 0
                        fputs(
                            String(
                                format: "[web-bake] compositor stream finished frames=%d wall=%.1fs\n",
                                self.writtenFrameCount,
                                wall
                            ),
                            stderr
                        )
                        fflush(stderr)
                    }
                    self.finish(result)
                }
            }
        )
        realtimeRecorder = recorder
        recorder.start()
        recorder.failIfNoFirstFrame(after: Self.realtimeCaptureWarmup + 6)
    }

    private func normalizedFrameRate(_ candidate: Double) -> Double {
        let clamped = min(
            max(candidate, Self.minimumAutomaticFrameRate),
            Self.maximumAutomaticFrameRate
        )
        // Preserve non-integer video cadences such as 59.94/62.5 without propagating
        // browser timing noise into the MP4 timescale.
        return (clamped * 1000).rounded() / 1000
    }

    private func beginEncoding(frameRate: Double, source: String) {
        guard !isFinishing else { return }

        do {
            effectiveFPS = frameRate
            totalFrameCount = max(1, Int((options.duration * frameRate).rounded(.up)))
            contentFrameInterval = 1.0 / frameRate
            nextFrameIndex = 0
            writtenFrameCount = 0

            try FileManager.default.createDirectory(
                at: options.outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let temporaryURL = options.outputURL.deletingLastPathComponent()
                .appendingPathComponent(".web-bake-\(UUID().uuidString).tmp.mp4")
            try? FileManager.default.removeItem(at: temporaryURL)
            temporaryOutputURL = temporaryURL

            let bitrate = Self.averageBitRate(
                width: options.width,
                height: options.height,
                fps: frameRate
            )
            let writer = try AVAssetWriter(outputURL: temporaryURL, fileType: .mp4)
            let input = AVAssetWriterInput(
                mediaType: .video,
                outputSettings: [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: options.width,
                    AVVideoHeightKey: options.height,
                    AVVideoCompressionPropertiesKey: [
                        AVVideoAverageBitRateKey: bitrate,
                        AVVideoExpectedSourceFrameRateKey: frameRate,
                        AVVideoMaxKeyFrameIntervalKey: max(1, Int((frameRate * 2).rounded())),
                        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                        AVVideoAllowFrameReorderingKey: false
                    ] as [String: Any]
                ]
            )
            // Offline bake is not a live capture pipeline: accept frames as soon as
            // snapshots are ready. Content timing is driven by the virtual clock.
            input.expectsMediaDataInRealTime = false
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: options.width,
                    kCVPixelBufferHeightKey as String: options.height
                ]
            )
            guard writer.canAdd(input) else {
                throw WebOfflineBakeError.writerFailed("无法添加视频编码输入")
            }
            writer.add(input)
            guard writer.startWriting() else {
                throw WebOfflineBakeError.writerFailed(writer.error?.localizedDescription ?? "无法启动视频编码")
            }
            writer.startSession(atSourceTime: .zero)

            self.writer = writer
            videoInput = input
            pixelBufferAdaptor = adaptor
            emitProgress(phase: "准备", progress: 0)
            fputs(
                String(
                    format: "[web-bake] encoder bitrate=%d target=%dx%d@%.3ffps duration=%.1fs source=%@ precise-media-seek\n",
                    bitrate,
                    options.width,
                    options.height,
                    frameRate,
                    options.duration,
                    source
                ),
                stderr
            )
            fflush(stderr)

            renderer.enableOfflineBakeClock(screen: WebRendererBridge.offlineBakeScreen) { [weak self] in
                guard let self, !self.isFinishing else { return }
                self.bakeClockEnabled = true
                fputs("[web-bake] virtual clock enabled; waiting for loop rebind\n", stderr)
                fflush(stderr)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                    guard let self, !self.isFinishing else { return }
                    self.renderer.setOfflineBakeContentTime(
                        screen: WebRendererBridge.offlineBakeScreen,
                        seconds: 0
                    ) { [weak self] in
                        guard let self, !self.isFinishing else { return }
                        self.captureStartedAt = Date()
                        let audioSource = self.mediaAudioPlan?.sourceURL.lastPathComponent ?? "none"
                        fputs("[web-bake] capturing dense frames (virtual clock + silent media, audio=\(audioSource))\n", stderr)
                        fflush(stderr)
                        self.captureNextFrame()
                    }
                }
            }
        } catch {
            finish(.failure(error))
        }
    }

    private func captureNextFrame() {
        guard !isFinishing else { return }
        if nextFrameIndex >= totalFrameCount {
            finishWriting()
            return
        }

        let contentSeconds = Double(nextFrameIndex) * contentFrameInterval
        // Advance virtual clock, wait for real rAF paints, then snapshot.
        // paintFrames=2: one frame consumes the content dt, second ensures GL presents.
        renderer.setOfflineBakeContentTime(
            screen: WebRendererBridge.offlineBakeScreen,
            seconds: contentSeconds,
            paintFrames: 2
        ) { [weak self] in
            guard let self, !self.isFinishing else { return }
            self.renderer.captureImage(screen: WebRendererBridge.offlineBakeScreen) { [weak self] image in
                guard let self, !self.isFinishing else { return }
                guard let image else {
                    self.finish(.failure(WebOfflineBakeError.captureFailed))
                    return
                }
                self.append(image: image)
            }
        }
    }

    private func append(image: NSImage) {
        guard let writer,
              let videoInput,
              let pixelBufferAdaptor,
              let pool = pixelBufferAdaptor.pixelBufferPool else {
            finish(.failure(WebOfflineBakeError.writerFailed("视频编码器未准备好")))
            return
        }
        guard writer.status == .writing else {
            finish(.failure(WebOfflineBakeError.writerFailed(writer.error?.localizedDescription ?? "视频编码器异常退出")))
            return
        }

        guard videoInput.isReadyForMoreMediaData else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
                self?.append(image: image)
            }
            return
        }

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        guard status == kCVReturnSuccess, let pixelBuffer,
              draw(image: image, into: pixelBuffer) else {
            finish(.failure(WebOfflineBakeError.writerFailed("无法转换 Web 帧为视频像素缓冲区")))
            return
        }

        // Dense capture: every index is written. Content time is virtual-clock driven,
        // so wall-clock snapshot lag no longer drops intermediate frames.
        let writtenIndex = nextFrameIndex
        let presentationTime = CMTime(
            value: CMTimeValue(
                (Double(writtenIndex) * contentFrameInterval * Double(Self.presentationTimescale))
                    .rounded()
            ),
            timescale: Self.presentationTimescale
        )
        guard pixelBufferAdaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
            finish(.failure(WebOfflineBakeError.writerFailed(writer.error?.localizedDescription ?? "写入视频帧失败")))
            return
        }

        writtenFrameCount += 1
        nextFrameIndex = writtenIndex + 1

        let wallElapsed = captureStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        emitProgress(
            phase: "录制",
            progress: min(0.99, Double(nextFrameIndex) / Double(totalFrameCount))
        )
        if writtenFrameCount == 1
            || writtenFrameCount % max(1, Int(effectiveFPS.rounded())) == 0
            || nextFrameIndex >= totalFrameCount {
            fputs(
                String(
                    format: "[web-bake] dense frame %d/%d content=%.3fs wall=%.1fs\n",
                    writtenFrameCount,
                    totalFrameCount,
                    Double(writtenIndex) * contentFrameInterval,
                    wallElapsed
                ),
                stderr
            )
            fflush(stderr)
        }
        captureNextFrame()
    }

    private func draw(image: NSImage, into pixelBuffer: CVPixelBuffer) -> Bool {
        guard let cgImage = image.cgImage(
            forProposedRect: nil,
            context: nil,
            hints: nil
        ) else {
            return false
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer),
              let context = CGContext(
                data: baseAddress,
                width: options.width,
                height: options.height,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
              ) else {
            return false
        }

        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: options.width, height: options.height))
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: options.width, height: options.height))
        return true
    }

    private func finishWriting() {
        guard !isFinishing else { return }
        isFinishing = true
        emitProgress(phase: "编码", progress: 0.99)
        guard let writer, let videoInput else {
            finish(.failure(WebOfflineBakeError.writerFailed("视频编码器未初始化")))
            return
        }
        videoInput.markAsFinished()
        writer.finishWriting { [weak self] in
            guard let self else { return }
            let result: Result<Void, Error>
            if writer.status == .completed {
                let wall = self.captureStartedAt.map { Date().timeIntervalSince($0) } ?? 0
                fputs(
                    String(
                        format: "[web-bake] finished frames=%d expected=%d wall=%.1fs\n",
                        self.writtenFrameCount,
                        self.totalFrameCount,
                        wall
                    ),
                    stderr
                )
                fflush(stderr)
                result = .success(())
            } else {
                result = .failure(
                    WebOfflineBakeError.writerFailed(
                        writer.error?.localizedDescription ?? "完成视频编码失败"
                    )
                )
            }
            DispatchQueue.main.async {
                self.finish(result)
            }
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard !didComplete else { return }
        didComplete = true
        isFinishing = true
        renderer.stop(screen: WebRendererBridge.offlineBakeScreen)
        try? FileManager.default.removeItem(
            atPath: primaryCapturePath(for: WebRendererBridge.offlineBakeScreen)
        )

        switch result {
        case .success:
            guard let temporaryOutputURL else {
                completion(.failure(WebOfflineBakeError.writerFailed("烘焙临时文件丢失")))
                return
            }
            do {
                let completedURL = try muxMediaAudioIfNeeded(videoURL: temporaryOutputURL)
                try? FileManager.default.removeItem(at: options.outputURL)
                try FileManager.default.moveItem(at: completedURL, to: options.outputURL)
                if completedURL != temporaryOutputURL {
                    try? FileManager.default.removeItem(at: temporaryOutputURL)
                }
                emitProgress(phase: "完成", progress: 1)
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        case .failure(let error):
            writer?.cancelWriting()
            if let temporaryOutputURL {
                try? FileManager.default.removeItem(at: temporaryOutputURL)
            }
            completion(.failure(error))
        }
    }

    private func muxMediaAudioIfNeeded(videoURL: URL) throws -> URL {
        guard let mediaAudioPlan else { return videoURL }
        guard let ffmpegURL = resolvedBundledFFmpegURL() else {
            throw WebOfflineBakeError.writerFailed("未找到打包的 ffmpeg，无法写入 Web 壁纸音轨")
        }

        let muxedURL = videoURL.deletingLastPathComponent().appendingPathComponent(
            ".web-bake-\(UUID().uuidString).audio.mp4"
        )
        try? FileManager.default.removeItem(at: muxedURL)

        let filter = String(
            format: "[1:a]volume=%.6f,apad[a]",
            mediaAudioPlan.volume
        )
        let process = Process()
        process.executableURL = ffmpegURL
        var arguments = [
            "-y",
            "-i", videoURL.path
        ]
        if mediaAudioPlan.loops {
            arguments += ["-stream_loop", "-1"]
        }
        if mediaAudioPlan.startOffset > 0 {
            arguments += [
                "-ss", String(format: "%.3f", mediaAudioPlan.startOffset)
            ]
        }
        arguments += [
            "-i", mediaAudioPlan.sourceURL.path,
            "-filter_complex", filter,
            "-map", "0:v:0",
            "-map", "[a]",
            "-c:v", "copy",
            "-c:a", "aac",
            "-t", String(format: "%.3f", options.duration),
            muxedURL.path
        ]
        process.arguments = arguments
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: muxedURL.path) else {
            let stderr = String(
                data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown ffmpeg failure"
            try? FileManager.default.removeItem(at: muxedURL)
            throw WebOfflineBakeError.writerFailed("Web 音频 mux 失败: \(stderr)")
        }
        fputs(
            "[web-bake] muxed media audio=\(mediaAudioPlan.sourceURL.lastPathComponent) volume=\(String(format: "%.3f", mediaAudioPlan.volume)) loop=\(mediaAudioPlan.loops) offset=\(String(format: "%.3f", mediaAudioPlan.startOffset))\n",
            stderr
        )
        fflush(stderr)
        return muxedURL
    }

    private func resolvedBundledFFmpegURL() -> URL? {
        let executableURL = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
            .standardizedFileURL
        let executableDirectory = executableURL.deletingLastPathComponent()
        let candidates: [URL?] = [
            Bundle.main.url(forResource: "ffmpeg", withExtension: nil),
            executableDirectory.appendingPathComponent("ffmpeg"),
            executableDirectory.appendingPathComponent("Resources/ffmpeg"),
            executableDirectory.deletingLastPathComponent()
                .appendingPathComponent("Resources/ffmpeg"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Resources/ffmpeg")
        ]
        return candidates.compactMap { $0 }.first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

    private func emitProgress(phase: String, progress: Double) {
        let now = Date()
        if phase == "录制",
           let lastProgressEmissionDate,
           now.timeIntervalSince(lastProgressEmissionDate) < (1.0 / 12.0) {
            return
        }
        lastProgressEmissionDate = now
        let currentFrame = min(totalFrameCount, max(0, nextFrameIndex))
        let line = String(
            format: "[web-bake] %@ %d/%d [%.1f%%]\n",
            phase,
            currentFrame,
            totalFrameCount,
            min(100, max(0, progress * 100))
        )
        fputs(line, stderr)
        fflush(stderr)
    }
}

// MARK: - Desktop Wallpaper Manager (Web renderer)
private final class DesktopWallpaperManager {
    static let shared = DesktopWallpaperManager()

    /// 每个屏幕独立的壁纸状态
    private struct ScreenState {
        var wallpaperPath: String?
        var isWebMode: Bool = false
        var isRunning: Bool = false
        var isPaused: Bool = false
    }

    private var screenStates: [Int: ScreenState] = [:]

    /// 所有屏幕共享的原始壁纸备份（首次设置时保存，全部停止后恢复）
    private var activeScreenCount: Int = 0


    private let originalWallpaperKey = "renderer_original_wallpaper_v1"
    private(set) var lastErrorMessage: String?
    private var screenChangeObserver: NSObjectProtocol?

    private init() {
        // 外接屏拔插：回收 index 已越界 / 窗口 frame 不再对应任何屏的 web 渲染
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.cleanupOrphanedScreensAfterDisplayChange()
        }
    }

    deinit {
        if let screenChangeObserver {
            NotificationCenter.default.removeObserver(screenChangeObserver)
        }
    }

    /// 停掉已不对应任何 NSScreen 的 web 槽位（断线后 index 越界，或窗口落在虚空）。
    private func cleanupOrphanedScreensAfterDisplayChange() {
        let screens = NSScreen.screensOrderedForDisplay
        let screenCount = screens.count
        let orphanIndices = screenStates.keys.filter { idx in
            if idx < 0 { return true }
            if idx >= screenCount { return true }
            // 索引仍合法但窗口 frame 已不与该屏匹配（排列变化 / 短暂错位）时不主动停，
            // 由后续 set/resize 路径处理；此处只清明确越界的槽。
            return false
        }
        guard !orphanIndices.isEmpty else { return }
        dlog("[DesktopWallpaperManager] cleaning orphaned web screens after display change: \(orphanIndices.sorted()) (screenCount=\(screenCount))")
        for idx in orphanIndices.sorted(by: >) {
            stopWallpaper(screen: idx)
        }
    }

    func setWallpaper(
        path: String,
        width: Int = 1920,
        height: Int = 1080,
        screen: Int? = nil,
        initialCrop: [Double]? = nil,
        initialViewport: [Double]? = nil,
        initialLetterboxColorHex: String? = nil,
        initialCropRevision: UInt64? = nil,
        completion: ((Bool) -> Void)? = nil
    ) {
        let path = resolveSteamWorkshopDirectoryIfNeeded(path)
        let screenIdx = screen ?? 0
        dlog("[DesktopWallpaperManager] setWallpaper path=\(path) width=\(width) height=\(height) screen=\(screenIdx)")

        lastErrorMessage = nil

        // 提前检测并拦截不支持的类型
        let webMode = isWebWallpaper(path: path)
        if !webMode {
            if let type = detectWallpaperProjectType(path: path) {
                let lower = type.lowercased()
                if !["web", "scene", "video"].contains(lower) {
                    let msg = "检测到该文件类型为 \(type.capitalized)，暂不支持设置此类型壁纸"
                    dlog("[DesktopWallpaperManager] Blocked unsupported type: \(type)")
                    lastErrorMessage = msg
                    completion?(false)
                    return
                }
            }
        }

        // 先停掉该屏幕上已有的壁纸（不影响其它屏幕）
        if screenStates[screenIdx]?.isRunning == true {
            stopWallpaper(screen: screenIdx)
        }

        // Save original desktop wallpaper once (first wallpaper across all screens)
        if activeScreenCount == 0 {
            saveOriginalWallpaper()
        }

        // 清掉该屏幕的旧截图
        let capPath = primaryCapturePath(for: screenIdx)
        try? FileManager.default.removeItem(atPath: capPath)

        // 初始化该屏幕的壁纸状态
        var state = ScreenState()
        state.wallpaperPath = path
        state.isWebMode = webMode
        state.isRunning = true
        state.isPaused = false
        screenStates[screenIdx] = state
        activeScreenCount += 1

        if webMode {
            WebRendererBridge.shared.loadWallpaper(
                path: path,
                width: width,
                height: height,
                screen: screenIdx,
                initialCrop: initialCrop,
                initialViewport: initialViewport,
                initialLetterboxColorHex: initialLetterboxColorHex,
                initialCropRevision: initialCropRevision
            ) { [weak self] success in
                guard let self = self else { return }
                print("[DesktopWallpaperManager] Web wallpaper load result: \(success) screen=\(screenIdx)")
                if !success {
                    let msg = "Web 壁纸渲染引擎加载失败，可能因资源不完整或浏览器引擎初始化错误"
                    dlog("[DesktopWallpaperManager] Web wallpaper load failed: \(msg)")
                    self.lastErrorMessage = msg
                    self.screenStates[screenIdx] = nil
                    self.activeScreenCount -= 1
                    if self.activeScreenCount == 0 {
                        self.restoreOriginalWallpaper()
                    }
                }
                NSApp.setActivationPolicy(.prohibited)
                completion?(success)
            }
            return
        }

    }


    func pauseWallpaper(screen: Int = 0) {
        guard let state = screenStates[screen], state.isRunning, !state.isPaused else { return }
        WebRendererBridge.shared.pause(screen: screen)
        // 系统桌面/锁屏已由 Host 的 canonical poster 同步；暂停不再把 raw capture 写成另一套壁纸源。
        screenStates[screen]?.isPaused = true
    }

    func resumeWallpaper(screen: Int = 0) {
        guard let state = screenStates[screen], state.isRunning, state.isPaused else { return }
        WebRendererBridge.shared.resume(screen: screen)
        screenStates[screen]?.isPaused = false
    }

    /// Capture the currently rendered WebView without changing playback or desktop state.
    func captureWallpaperFrame(screen: Int = 0, completion: @escaping (Bool) -> Void) {
        guard let state = screenStates[screen], state.isRunning, state.isWebMode else {
            completion(false)
            return
        }
        WebRendererBridge.shared.captureFrame(screen: screen, completion: completion)
    }

    @discardableResult
    func applyWebWallpaperProperties(_ jsonString: String, screen: Int = 0) -> Bool {
        guard let state = screenStates[screen], state.isRunning, state.isWebMode else { return false }
        return WebRendererBridge.shared.applyUserProperties(jsonString: jsonString, screen: screen)
    }

    @discardableResult
    func applyWebWallpaperCrop(
        crop: [Double]?,
        viewport: [Double]?,
        letterboxColorHex: String?,
        cropRevision: UInt64?,
        screen: Int = 0
    ) -> Bool {
        guard let state = screenStates[screen], state.isRunning, state.isWebMode else { return false }
        return WebRendererBridge.shared.applyCrop(
            crop: crop,
            viewport: viewport,
            letterboxColorHex: letterboxColorHex,
            cropRevision: cropRevision,
            screen: screen
        )
    }

    /// 设置 Web 壁纸的音频控制（静音/音量）
    /// screen 为 nil 时广播到所有正在运行 web 壁纸的屏幕
    func setWebAudioControl(muted: Bool?, volume: Double?, screen: Int? = nil) {
        if let screen = screen {
            guard let state = screenStates[screen], state.isRunning, state.isWebMode else { return }
            WebRendererBridge.shared.setAudioControl(muted: muted, volume: volume, screen: screen)
        } else {
            // 广播到所有 web 壁纸屏幕
            for (screenIdx, state) in screenStates where state.isRunning && state.isWebMode {
                WebRendererBridge.shared.setAudioControl(muted: muted, volume: volume, screen: screenIdx)
            }
        }
    }

    /// 透传 WE 音频频谱给 web renderer。推送到所有正在运行的 web 壁纸屏幕。
    /// 参数为 WE 标准 128 frame：0..63 = L, 64..127 = R。
    func pushWebAudioFrame(_ spectrum: [Float]) {
        guard spectrum.count == 128 else { return }
        // 推送到所有已加载的 web 壁纸屏幕（WebRendererBridge 内部会过滤）
        WebRendererBridge.shared.pushAudioFrame(spectrum)
    }

    /// 透传系统 Now Playing 元数据到 Web Media Integration。
    func pushWebMediaUpdate(
        enabled: Bool,
        title: String,
        artist: String,
        albumTitle: String,
        state: Int,
        position: Double,
        duration: Double,
        rate: Double
    ) {
        WebRendererBridge.shared.pushMediaUpdate(
            enabled: enabled,
            title: title,
            artist: artist,
            albumTitle: albumTitle,
            state: state,
            position: position,
            duration: duration,
            rate: rate
        )
    }

    func pushWebMediaThumbnail(_ thumbnail: String) {
        WebRendererBridge.shared.pushMediaThumbnail(thumbnail)
    }


    func pushWebMediaLyrics(
        hasLyrics: Bool,
        title: String,
        artist: String,
        songId: String,
        storefront: String,
        source: String,
        lines: [IPCLyricLine]
    ) {
        WebRendererBridge.shared.pushMediaLyrics(
            hasLyrics: hasLyrics,
            title: title,
            artist: artist,
            songId: songId,
            storefront: storefront,
            source: source,
            lines: lines
        )
    }

    func pushWebMediaLyricsLine(
        index: Int,
        text: String,
        nextText: String,
        previousText: String,
        start: Double,
        end: Double?,
        progress: Double,
        elapsedTime: Double,
        hasLine: Bool
    ) {
        WebRendererBridge.shared.pushMediaLyricsLine(
            index: index,
            text: text,
            nextText: nextText,
            previousText: previousText,
            start: start,
            end: end,
            progress: progress,
            elapsedTime: elapsedTime,
            hasLine: hasLine
        )
    }

    func stopWallpaper(screen: Int = 0) {
        guard screenStates[screen] != nil else { return }
        WebRendererBridge.shared.stop(screen: screen)
        // 清理该屏幕的截图文件
        try? FileManager.default.removeItem(atPath: primaryCapturePath(for: screen))
        screenStates[screen] = nil
        activeScreenCount -= 1
        if activeScreenCount == 0 {
            restoreOriginalWallpaper()
        }
    }

    /// 停止所有屏幕上的壁纸
    func stopAllWallpapers() {
        for screenIdx in Array(screenStates.keys) {
            stopWallpaper(screen: screenIdx)
        }
    }

    // MARK: - Original Wallpaper Management

    private func saveOriginalWallpaper() {
        let workspace = NSWorkspace.shared
        var screenConfigs: [ScreenWallpaperConfig] = []

        for screen in NSScreen.screens {
            if let desktopURL = workspace.desktopImageURL(for: screen) {
                if isOurPosterImage(desktopURL) {
                    print("[DesktopWallpaperManager] Skipping our own poster image: \(desktopURL.lastPathComponent)")
                    continue
                }
                let config = ScreenWallpaperConfig(
                    screenID: screen.wallpaperScreenIdentifier,
                    screenName: screen.localizedName,
                    wallpaperURL: desktopURL.absoluteString,
                    isMainScreen: screen == NSScreen.main
                )
                screenConfigs.append(config)
            }
        }

        guard !screenConfigs.isEmpty else {
            print("[DesktopWallpaperManager] No valid original wallpaper to save")
            return
        }

        let savedState = SavedOriginalWallpaperState(
            configs: screenConfigs,
            savedAt: Date(),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        )

        if let data = try? JSONEncoder().encode(savedState) {
            UserDefaults.standard.set(data, forKey: originalWallpaperKey)
            print("[DesktopWallpaperManager] Saved original wallpaper for \(screenConfigs.count) screen(s)")
        }
    }

    private func restoreOriginalWallpaper() {
        guard !isDynamicLockScreenEnabledForCurrentLaunch() else {
            dlog("[DesktopWallpaperManager] Dynamic lock screen enabled; skip restoring desktop wallpaper")
            return
        }
        guard let data = UserDefaults.standard.data(forKey: originalWallpaperKey),
              let savedState = try? JSONDecoder().decode(SavedOriginalWallpaperState.self, from: data) else {
            print("[DesktopWallpaperManager] No original wallpaper to restore")
            return
        }

        print("[DesktopWallpaperManager] Restoring wallpaper from state saved at \(savedState.savedAt)")

        let workspace = NSWorkspace.shared
        let currentScreens = NSScreen.screens
        var restoredCount = 0
        var unmatchedScreens: [NSScreen] = []

        for screen in currentScreens {
            let screenID = screen.wallpaperScreenIdentifier
            if let config = savedState.configs.first(where: { $0.screenID == screenID }),
               let originalURL = URL(string: config.wallpaperURL),
               FileManager.default.fileExists(atPath: originalURL.path) {
                do {
                    try workspace.setDesktopImageURLForAllSpaces(originalURL, for: screen)
                    print("[DesktopWallpaperManager] Restored wallpaper for screen \(screen.localizedName) (exact match)")
                    restoredCount += 1
                } catch {
                    print("[DesktopWallpaperManager] Failed to restore wallpaper for screen \(screenID): \(error)")
                    unmatchedScreens.append(screen)
                }
            } else {
                unmatchedScreens.append(screen)
            }
        }

        if !unmatchedScreens.isEmpty,
           let mainConfig = savedState.configs.first(where: { $0.isMainScreen }),
           let mainURL = URL(string: mainConfig.wallpaperURL),
           FileManager.default.fileExists(atPath: mainURL.path) {
            for screen in unmatchedScreens {
                do {
                    try workspace.setDesktopImageURLForAllSpaces(mainURL, for: screen)
                    print("[DesktopWallpaperManager] Restored wallpaper for screen \(screen.localizedName) (fallback to main screen)")
                    restoredCount += 1
                } catch {
                    print("[DesktopWallpaperManager] Failed to restore wallpaper for screen \(screen.localizedName): \(error)")
                }
            }
        }

        if restoredCount == 0 && !savedState.configs.isEmpty {
            for config in savedState.configs {
                if let url = URL(string: config.wallpaperURL),
                   FileManager.default.fileExists(atPath: url.path) {
                    for screen in unmatchedScreens {
                        do {
                            try workspace.setDesktopImageURLForAllSpaces(url, for: screen)
                            print("[DesktopWallpaperManager] Restored wallpaper for screen \(screen.localizedName) (fallback to any available)")
                        } catch {
                            print("[DesktopWallpaperManager] Failed to restore wallpaper: \(error)")
                        }
                    }
                    break
                }
            }
        }

        UserDefaults.standard.removeObject(forKey: originalWallpaperKey)
        print("[DesktopWallpaperManager] Original wallpaper restore completed")
    }

    private func isOurPosterImage(_ url: URL) -> Bool {
        let path = url.path
        return path.contains("WallpaperPosters") && path.contains("poster_")
    }
}


// MARK: - IPC Helpers
private func writePID(_ pid: Int32) {
    try? String(pid).write(toFile: PID_PATH, atomically: true, encoding: .utf8)
}

private func readPID() -> Int32? {
    guard let text = try? String(contentsOfFile: PID_PATH, encoding: .utf8),
          let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
    return pid
}

private func isDaemonRunning() -> Bool {
    guard let pid = readPID() else { return false }
    return kill(pid, 0) == 0
}

private func stopDaemonIfRunning() {
    // 1. 尝试通过 socket 发送优雅停止命令
    if FileManager.default.fileExists(atPath: SOCKET_PATH) {
        _ = Client.send(IPCMessage(command: .stop, path: nil, screen: nil))
        Thread.sleep(forTimeInterval: 0.2)
    }
    // 2. 如果 PID 文件存在且进程还在，先 SIGTERM 它并等待退出（避免 pkill 误伤未来的新进程）
    if let pid = readPID(), kill(pid, 0) == 0 {
        kill(pid, SIGTERM)
        // 轮询等待旧进程退出，最多 1.5 秒
        for _ in 0..<15 {
            Thread.sleep(forTimeInterval: 0.1)
            if kill(pid, 0) != 0 { break }
        }
        // 如果还在，再 SIGKILL
        if kill(pid, 0) == 0 {
            kill(pid, SIGKILL)
            Thread.sleep(forTimeInterval: 0.2)
        }
    }
    // 3. 兜底：pkill 清理可能残留的同名进程（此时应无新进程）
    let pkill = Process()
    pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    pkill.arguments = ["-f", "wallpaperengine-cli daemon"]
    try? pkill.run()
    pkill.waitUntilExit()
    // 4. 清理文件
    removeSocket()
    if FileManager.default.fileExists(atPath: PID_PATH) {
        try? FileManager.default.removeItem(atPath: PID_PATH)
    }
}

private func removeSocket() {
    let fm = FileManager.default
    if fm.fileExists(atPath: SOCKET_PATH) {
        try? fm.removeItem(atPath: SOCKET_PATH)
    }
}

// MARK: - Client
private enum Client {
    static func send(_ message: IPCMessage) -> Bool {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        strncpy(&addr.sun_path, SOCKET_PATH, MemoryLayout.size(ofValue: addr.sun_path) - 1)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        let size = MemoryLayout<sockaddr_un>.size
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(size))
            }
        }
        guard connected == 0 else { return false }

        guard let data = try? JSONEncoder().encode(message) else { return false }
        var length = UInt32(data.count)
        let payload = Data(bytes: &length, count: MemoryLayout<UInt32>.size) + data
        let sent = payload.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, payload.count, 0) }
        return sent == payload.count
    }

    static func sendAndWaitForOK(_ message: IPCMessage, timeout: TimeInterval = 5.0) -> String? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        strncpy(&addr.sun_path, SOCKET_PATH, MemoryLayout.size(ofValue: addr.sun_path) - 1)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return "Failed to create socket" }
        defer { close(fd) }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let size = MemoryLayout<sockaddr_un>.size
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(size))
            }
        }
        guard connected == 0 else { return "Daemon not responding" }

        guard let data = try? JSONEncoder().encode(message) else { return "Encode failed" }
        var length = UInt32(data.count)
        let payload = Data(bytes: &length, count: MemoryLayout<UInt32>.size) + data
        let sent = payload.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, payload.count, 0) }
        guard sent == payload.count else { return "Send failed" }

        var responseBuf = Data(repeating: 0, count: 1024)
        let received = responseBuf.withUnsafeMutableBytes { recv(fd, $0.baseAddress, 1024, 0) }
        guard received > 0 else { return "Daemon communication timed out" }
        return String(data: responseBuf.prefix(received), encoding: .utf8)
    }
}

// MARK: - Daemon
private final class Daemon: NSObject, NSApplicationDelegate {
    static let shared = Daemon()
    private var serverSocket: Int32 = -1
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        writePID(getpid())
        removeSocket()
        // Re-enforce no-dock-icon policy after NSApplication run loop starts
        NSApp.setActivationPolicy(.prohibited)
        startServer()
        startProhibitionTimer()
        installDaemonSignalHandlers()
        dlog("[Daemon] Started, pid=\(getpid())")
    }

    private var prohibitionTimer: Timer?

    private func startProhibitionTimer() {
        prohibitionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            if NSApp.activationPolicy() != .prohibited {
                dlog("[Daemon] Re-enforcing prohibited activation policy")
                NSApp.setActivationPolicy(.prohibited)
            }
        }
    }

    /// 主程序退出时会同步 `kill(daemonPID, SIGTERM)` 让 web 壁纸落地；
    /// 默认 AppKit run loop 不响应 SIGTERM，所以这里用 DispatchSource 接管。
    /// 收到信号后直接 `_exit(0)`，避免走 NSApp.terminate 触发 C++ 静态析构（glslang/SDL 与 AppKit
    /// 子线程交叉收尾时会在 libc++ 里 abort，触发系统"意外退出"弹窗。bake 那边也是同款处理）。
    private func installDaemonSignalHandlers() {
        // 忽略 SIGPIPE：daemon 的 IPC server 在 sendResponse 时若对端已 close（例如 fire-and-forget
        // 的 audioControl 调用），写入会触发 EPIPE → SIGPIPE。默认动作是终止进程，会把整个 daemon
        // 连同正在渲染的 Web 壁纸窗口一起带走。App 一侧已经 signal(SIGPIPE, SIG_IGN)，daemon 这边
        // 是独立子进程，必须独立设置一次。
        signal(SIGPIPE, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        for sig in [SIGTERM, SIGINT] {
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [unowned self] in
                dlog("[Daemon] Received signal \(sig), exiting...")
                // 同步清掉壁纸窗口、socket、PID 文件（这是 applicationWillTerminate 的核心逻辑），
                // 然后 _exit 跳过会崩溃的 C++ 静态析构。
                DesktopWallpaperManager.shared.stopAllWallpapers()
                if self.serverSocket >= 0 {
                    close(self.serverSocket)
                    self.serverSocket = -1
                }
                removeSocket()
                if FileManager.default.fileExists(atPath: PID_PATH) {
                    try? FileManager.default.removeItem(atPath: PID_PATH)
                }
                fflush(stdout)
                fflush(stderr)
                _exit(0)
            }
            src.resume()
            signalSources.append(src)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        prohibitionTimer?.invalidate()
        prohibitionTimer = nil
        for src in signalSources { src.cancel() }
        signalSources.removeAll()
        DesktopWallpaperManager.shared.stopAllWallpapers()
        if serverSocket >= 0 {
            close(serverSocket)
        }
        removeSocket()
        if FileManager.default.fileExists(atPath: PID_PATH) {
            try? FileManager.default.removeItem(atPath: PID_PATH)
        }
    }

    private func startServer() {
        serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            dlog("[Daemon] Failed to create socket")
            NSApp.terminate(nil)
            return
        }

        var value: Int32 = 1
        setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &value, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        strncpy(&addr.sun_path, SOCKET_PATH, MemoryLayout.size(ofValue: addr.sun_path) - 1)

        let size = MemoryLayout<sockaddr_un>.size
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(serverSocket, $0, socklen_t(size))
            }
        }
        guard bound == 0 else {
            dlog("[Daemon] Failed to bind socket")
            NSApp.terminate(nil)
            return
        }

        listen(serverSocket, 5)

        DispatchQueue.global(qos: .utility).async { [weak self] in
            while let self = self, self.serverSocket >= 0 {
                let client = accept(self.serverSocket, nil, nil)
                guard client >= 0 else { continue }
                self.handleClient(client)
            }
        }
    }

    private func handleClient(_ fd: Int32) {
        DispatchQueue.global(qos: .userInitiated).async {
            var lengthBuf = Data(repeating: 0, count: MemoryLayout<UInt32>.size)
            let lenRead = lengthBuf.withUnsafeMutableBytes { recv(fd, $0.baseAddress, MemoryLayout<UInt32>.size, 0) }
            guard lenRead == MemoryLayout<UInt32>.size else { close(fd); return }

            let length = lengthBuf.withUnsafeBytes { $0.load(as: UInt32.self) }
            // mediaThumbnail 可能带 data URL，放宽到 8MB
            guard length > 0, length < 8 * 1024 * 1024 else {
                dlog("[Daemon] IPC length rejected: \(length)")
                close(fd)
                return
            }

            var data = Data()
            while data.count < Int(length) {
                var chunk = Data(repeating: 0, count: Int(length) - data.count)
                let chunkSize = chunk.count
                let n = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress, chunkSize, 0) }
                guard n > 0 else { close(fd); return }
                data.append(chunk.prefix(n))
            }

            let msg: IPCMessage
            do {
                msg = try JSONDecoder().decode(IPCMessage.self, from: data)
            } catch {
                let preview = String(data: data.prefix(200), encoding: .utf8) ?? "<bin>"
                dlog("[Daemon] IPC decode failed: \(error) body=\(preview)")
                _ = "INVALID".data(using: .utf8)?.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
                close(fd)
                return
            }

            let sendResponse = { (response: String) in
                _ = response.data(using: .utf8)?.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
                close(fd)
            }

            DispatchQueue.main.async {
                dlog("[Daemon] Received command: \(msg.command) path=\(msg.path ?? "nil") screen=\(msg.screen.map(String.init) ?? "nil")")
                switch msg.command {
                case .set:
                    if let path = msg.path {
                        let targetSize: (Int, Int)
                        let screens = NSScreen.screensOrderedForDisplay
                        if let s = msg.screen, s >= 0, s < screens.count {
                            let frame = screens[s].frame
                            targetSize = (Int(frame.width), Int(frame.height))
                        } else if let main = NSScreen.main {
                            targetSize = (Int(main.frame.width), Int(main.frame.height))
                        } else {
                            targetSize = (1920, 1080)
                        }
                        DesktopWallpaperManager.shared.setWallpaper(
                            path: path,
                            width: targetSize.0,
                            height: targetSize.1,
                            screen: msg.screen,
                            initialCrop: msg.crop,
                            initialViewport: msg.viewport,
                            initialLetterboxColorHex: msg.letterboxColorHex,
                            initialCropRevision: msg.cropRevision
                        ) { success in
                            dlog("[Daemon] setWallpaper completion: \(success)")
                            if success {
                                sendResponse("OK")
                            } else if let err = DesktopWallpaperManager.shared.lastErrorMessage {
                                sendResponse("ERROR:\(err)")
                            } else {
                                sendResponse("ERROR:壁纸渲染失败，请尝试其他壁纸（查看 /tmp/wallpaperengine-cli-daemon.log 获取详情）")
                            }
                        }
                    } else {
                        sendResponse("NO_PATH")
                    }
                case .pause:
                    DesktopWallpaperManager.shared.pauseWallpaper(screen: msg.screen ?? 0)
                    sendResponse("OK")
                case .resume:
                    DesktopWallpaperManager.shared.resumeWallpaper(screen: msg.screen ?? 0)
                    sendResponse("OK")
                case .stop:
                    if let screen = msg.screen {
                        DesktopWallpaperManager.shared.stopWallpaper(screen: screen)
                    } else {
                        DesktopWallpaperManager.shared.stopAllWallpapers()
                    }
                    sendResponse("OK")
                case .capture:
                    let screen = msg.screen ?? 0
                    guard screen >= 0 else {
                        sendResponse("ERROR:无效的屏幕索引")
                        return
                    }
                    DesktopWallpaperManager.shared.captureWallpaperFrame(screen: screen) { success in
                        if success {
                            sendResponse("OK")
                        } else {
                            sendResponse("ERROR:当前屏幕没有可捕获的 Web 壁纸画面")
                        }
                    }
                case .applyProperties:
                    if let propertiesJSON = msg.propertiesJSON {
                        let applied = DesktopWallpaperManager.shared.applyWebWallpaperProperties(propertiesJSON, screen: msg.screen ?? 0)
                        dlog("[Daemon] applyProperties applied=\(applied) screen=\(msg.screen ?? 0)")
                        if applied {
                            sendResponse("OK")
                        } else {
                            sendResponse("ERROR:当前屏幕没有运行中的 Web 壁纸可应用属性")
                        }
                    } else {
                        sendResponse("ERROR:缺少 propertiesJSON")
                    }
                case .crop:
                    let applied = DesktopWallpaperManager.shared.applyWebWallpaperCrop(
                        crop: msg.crop,
                        viewport: msg.viewport,
                        letterboxColorHex: msg.letterboxColorHex,
                        cropRevision: msg.cropRevision,
                        screen: msg.screen ?? 0
                    )
                    dlog("[Daemon] crop applied=\(applied) screen=\(msg.screen ?? 0)")
                    if msg.expectsResponse == true {
                        sendResponse(applied ? "OK" : "ERROR:当前屏幕没有运行中的 Web 壁纸可应用裁切")
                    } else {
                        // 拖拽时的高频更新不回响应，Host 也不会 recv，避免 socket 堆积。
                        close(fd)
                    }
                case .audioControl:
                    DesktopWallpaperManager.shared.setWebAudioControl(muted: msg.muted, volume: msg.volume, screen: msg.screen)
                    sendResponse("OK")
                case .audioData:
                    if let spec = msg.spectrum, spec.count == 128 {
                        DesktopWallpaperManager.shared.pushWebAudioFrame(spec)
                    }
                    // 不发响应：30fps 高频命令，sendResponse 会塞爆缓冲且让 App 侧每帧都要 recv。
                    // 必须显式关闭 fd，否则每帧泄漏一个文件描述符，~8s 后耗尽（256/30fps）导致 daemon 完全停止接收 IPC。
                    close(fd)
                case .mediaUpdate:
                    dlog("[Daemon] mediaUpdate enabled=\(msg.enabled ?? false) title=\(msg.title ?? "") state=\(msg.state ?? 0)")
                    DesktopWallpaperManager.shared.pushWebMediaUpdate(
                        enabled: msg.enabled ?? false,
                        title: msg.title ?? "",
                        artist: msg.artist ?? "",
                        albumTitle: msg.albumTitle ?? "",
                        state: msg.state ?? 0,
                        position: msg.position ?? 0,
                        duration: msg.duration ?? 0,
                        rate: msg.rate ?? 1
                    )
                    // 低频；仍 fire-and-forget，避免阻塞 Host 主线程
                    close(fd)
                case .mediaThumbnail:
                    let thumbLen = (msg.thumbnail ?? "").count
                    dlog("[Daemon] mediaThumbnail len=\(thumbLen)")
                    DesktopWallpaperManager.shared.pushWebMediaThumbnail(msg.thumbnail ?? "")
                    close(fd)
                case .mediaLyrics:
                    let n = msg.lines?.count ?? 0
                    dlog("[Daemon] mediaLyrics has=\(msg.hasLyrics ?? false) lines=\(n) songId=\(msg.songId ?? "")")
                    DesktopWallpaperManager.shared.pushWebMediaLyrics(
                        hasLyrics: msg.hasLyrics ?? false,
                        title: msg.title ?? "",
                        artist: msg.artist ?? "",
                        songId: msg.songId ?? "",
                        storefront: msg.storefront ?? "",
                        source: msg.source ?? "",
                        lines: msg.lines ?? []
                    )
                    close(fd)
                case .mediaLyricsLine:
                    DesktopWallpaperManager.shared.pushWebMediaLyricsLine(
                        index: msg.index ?? -1,
                        text: msg.text ?? "",
                        nextText: msg.nextText ?? "",
                        previousText: msg.previousText ?? "",
                        start: msg.start ?? 0,
                        end: msg.end,
                        progress: msg.progress ?? 0,
                        elapsedTime: msg.elapsedTime ?? 0,
                        hasLine: msg.hasLine ?? false
                    )
                    close(fd)
                }
            }
        }
    }
}


// MARK: - Main
@main
struct WallpaperEngineCLI {
    static func main() {
        let allArgs = CommandLine.arguments
        let isDaemon = allArgs.count > 1 && allArgs[1] == "daemon"

        if isDaemon {
            runDaemon()
            return
        }

        // Client mode
        // 忽略 SIGPIPE：client 向旧 daemon 发送 stop 命令时，若旧 daemon 已卡死（如 fd 泄漏导致
        // accept 循环阻塞），socket 写入端不可读会触发 SIGPIPE。默认动作是终止进程（exit 13），
        // 导致后续 startDaemonProcess() 根本不执行，新 daemon 无法启动。
        signal(SIGPIPE, SIG_IGN)

        let args = Array(allArgs.dropFirst())
        let remainingArgs = args

        guard let command = remainingArgs.first else {
            printUsage()
            exit(1)
        }

        switch command {
        case "bake":
            runOfflineBake(arguments: Array(remainingArgs.dropFirst()))

        case "set", "pause", "resume", "stop", "stop-screen", "exit", "capture", "apply-properties":
            if command == "stop" || command == "exit" {
                stopDaemonIfRunning()
                exit(0)
            }

            if command == "set" {
                // 复用已有 daemon（支持多屏各自独立壁纸）；仅在 daemon 未运行时启动新的
                if !isDaemonRunning() {
                    startDaemonProcess()
                    var attempts = 0
                    while !isDaemonRunning() && attempts < 30 {
                        Thread.sleep(forTimeInterval: 0.1)
                        attempts += 1
                    }
                    guard isDaemonRunning() else {
                        print("Failed to start daemon.")
                        exit(1)
                    }
                }
            } else if !isDaemonRunning() {
                // Per-screen stop is idempotent: the target daemon may already
                // have exited while the App was completing a display switch.
                if command == "stop-screen" {
                    exit(0)
                }
                guard isDaemonRunning() else {
                    print("Daemon not responding")
                    exit(1)
                }
            }

            let msg: IPCMessage
            switch command {
            case "set":
                var setArgs = Array(remainingArgs.dropFirst())
                guard !setArgs.isEmpty else {
                    print("Usage: wallpaperengine-cli set <path> [screen_index] [--initial-crop <base64-json>]")
                    exit(1)
                }
                var initialCrop: InitialWebCropPayload?
                if let cropFlagIndex = setArgs.lastIndex(of: "--initial-crop") {
                    guard cropFlagIndex + 2 == setArgs.count,
                          let cropData = Data(base64Encoded: setArgs[cropFlagIndex + 1]),
                          let decoded = try? JSONDecoder().decode(InitialWebCropPayload.self, from: cropData) else {
                        print("Invalid --initial-crop payload")
                        exit(1)
                    }
                    initialCrop = decoded
                    setArgs.removeSubrange(cropFlagIndex...)
                }
                var path = setArgs.joined(separator: " ")
                var screen: Int? = nil
                if setArgs.count > 1, let s = Int(setArgs.last!) {
                    screen = s
                    path = setArgs.dropLast().joined(separator: " ")
                }
                msg = IPCMessage(
                    command: .set,
                    path: path,
                    screen: screen,
                    crop: initialCrop?.crop,
                    viewport: initialCrop?.viewport,
                    letterboxColorHex: initialCrop?.letterboxColorHex,
                    cropRevision: initialCrop?.cropRevision
                )
            case "apply-properties":
                let applyArgs = Array(remainingArgs.dropFirst())
                guard !applyArgs.isEmpty else {
                    print("Usage: wallpaperengine-cli apply-properties <json> [screen_index]")
                    exit(1)
                }
                var jsonStr = applyArgs.joined(separator: " ")
                var applyScreen: Int? = nil
                if applyArgs.count > 1, let s = Int(applyArgs.last!) {
                    applyScreen = s
                    jsonStr = applyArgs.dropLast().joined(separator: " ")
                }
                msg = IPCMessage(command: .applyProperties, path: nil, screen: applyScreen, propertiesJSON: jsonStr)
            case "pause":
                let pauseArgs = Array(remainingArgs.dropFirst())
                var pauseScreen: Int? = nil
                if let s = pauseArgs.first, let screenIdx = Int(s) {
                    pauseScreen = screenIdx
                }
                msg = IPCMessage(command: .pause, path: nil, screen: pauseScreen)
            case "resume":
                let resumeArgs = Array(remainingArgs.dropFirst())
                var resumeScreen: Int? = nil
                if let s = resumeArgs.first, let screenIdx = Int(s) {
                    resumeScreen = screenIdx
                }
                msg = IPCMessage(command: .resume, path: nil, screen: resumeScreen)
            case "capture":
                let captureArgs = Array(remainingArgs.dropFirst())
                guard captureArgs.count <= 1,
                      let captureScreen = captureArgs.first.flatMap(Int.init),
                      captureScreen >= 0 else {
                    print("Usage: wallpaperengine-cli capture <screen_index>")
                    exit(1)
                }
                msg = IPCMessage(command: .capture, path: nil, screen: captureScreen)
            case "stop-screen":
                let stopArgs = Array(remainingArgs.dropFirst())
                guard stopArgs.count == 1,
                      let stopScreen = Int(stopArgs[0]),
                      stopScreen >= 0 else {
                    print("Usage: wallpaperengine-cli stop-screen <screen_index>")
                    exit(1)
                }
                msg = IPCMessage(command: .stop, path: nil, screen: stopScreen)
            case "stop", "exit":
                let stopArgs = Array(remainingArgs.dropFirst())
                var stopScreen: Int? = nil
                if let s = stopArgs.first, let screenIdx = Int(s) {
                    stopScreen = screenIdx
                }
                msg = IPCMessage(command: .stop, path: nil, screen: stopScreen)
            default:
                print("Unknown command: \(command)")
                exit(1)
            }

            let responseTimeout: TimeInterval = command == "set" ? 35.0 : (command == "capture" ? 10.0 : 5.0)
            if let err = Client.sendAndWaitForOK(msg, timeout: responseTimeout) {
                if err == "OK" {
                    // success
                } else if err.hasPrefix("ERROR:") {
                    let message = String(err.dropFirst("ERROR:".count))
                    print(message)
                    exit(1)
                } else {
                    print(err)
                    exit(1)
                }
            } else {
                print("Daemon communication failed")
                exit(1)
            }

        default:
            print("Unknown command: \(command)")
            printUsage()
            exit(1)
        }
    }

    private static func runDaemon() {
        let app = NSApplication.shared
        // 作为后台 daemon，不显示 Dock 图标、不占用菜单栏、不 stealing focus
        app.setActivationPolicy(.prohibited)
        // 防御性阻止窗口框架改变 activation policy 或抢焦点
        swizzleActivateIgnoringOtherApps()
        swizzleSetActivationPolicy()
        let delegate = Daemon.shared
        app.delegate = delegate
        app.run()
    }

    private static var offlineBakeRunner: WebOfflineBakeRunner?

    private static func runOfflineBake(arguments: [String]) {
        guard let options = parseOfflineBakeOptions(arguments) else {
            printUsage()
            exit(1)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        offlineBakeRunner = WebOfflineBakeRunner(options: options) { result in
            switch result {
            case .success:
                exit(0)
            case .failure(let error):
                fputs("Web bake failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        offlineBakeRunner?.start()
        app.run()
    }

    private static func parseOfflineBakeOptions(_ arguments: [String]) -> WebOfflineBakeRunner.Options? {
        guard let path = arguments.first, !path.hasPrefix("--") else {
            fputs("Usage: wallpaperengine-cli bake <path> --size WxH --fps auto|N --duration S --out <path> [--properties-base64 <base64>]\n", stderr)
            return nil
        }

        var width: Int?
        var height: Int?
        var requestedFPS: Double?
        var hasFrameRateOption = false
        var duration: TimeInterval?
        var outputPath: String?
        var userPropertiesJSON: String?
        var index = 1

        while index < arguments.count {
            let argument = arguments[index]
            guard index + 1 < arguments.count else {
                fputs("Missing value for \(argument)\n", stderr)
                return nil
            }
            let value = arguments[index + 1]
            switch argument {
            case "--size":
                let parts = value.lowercased().split(separator: "x")
                guard parts.count == 2,
                      let parsedWidth = Int(parts[0]),
                      let parsedHeight = Int(parts[1]) else {
                    fputs("Invalid --size value: \(value)\n", stderr)
                    return nil
                }
                width = max(2, parsedWidth - (parsedWidth % 2))
                height = max(2, parsedHeight - (parsedHeight % 2))
            case "--fps":
                hasFrameRateOption = true
                if value.lowercased() == "auto" {
                    requestedFPS = nil
                } else if let parsedFPS = Double(value),
                          parsedFPS.isFinite,
                          parsedFPS > 0 {
                    requestedFPS = parsedFPS
                } else {
                    fputs("Invalid --fps value: \(value)\n", stderr)
                    return nil
                }
            case "--duration":
                duration = Double(value)
            case "--out":
                outputPath = value
            case "--properties-base64":
                guard let data = Data(base64Encoded: value),
                      let json = String(data: data, encoding: .utf8) else {
                    fputs("Invalid --properties-base64 value\n", stderr)
                    return nil
                }
                userPropertiesJSON = json
            default:
                fputs("Unknown bake option: \(argument)\n", stderr)
                return nil
            }
            index += 2
        }

        guard let width, let height, hasFrameRateOption,
              let duration, duration > 0,
              let outputPath, !outputPath.isEmpty else {
            fputs("Usage: wallpaperengine-cli bake <path> --size WxH --fps auto|N --duration S --out <path> [--properties-base64 <base64>]\n", stderr)
            return nil
        }
        return WebOfflineBakeRunner.Options(
            path: path,
            width: width,
            height: height,
            requestedFPS: requestedFPS,
            duration: duration,
            outputURL: URL(fileURLWithPath: outputPath),
            userPropertiesJSON: userPropertiesJSON
        )
    }

    private static func swizzleActivateIgnoringOtherApps() {
        let sel = #selector(NSApplication.activate(ignoringOtherApps:))
        guard let method = class_getInstanceMethod(NSApplication.self, sel) else { return }
        let originalImp = method_getImplementation(method)
        let block: @convention(block) (NSApplication, Bool) -> Void = { _, _ in
            // no-op: daemon must never steal focus from the main app
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
        // Keep original IMP reachable? Not needed for simple no-op.
        _ = originalImp
    }

    private static func swizzleSetActivationPolicy() {
        let sel = #selector(NSApplication.setActivationPolicy(_:))
        guard let method = class_getInstanceMethod(NSApplication.self, sel) else { return }
        let originalImp = method_getImplementation(method)
        let block: @convention(block) (NSApplication, NSApplication.ActivationPolicy) -> Bool = { app, policy in
            if policy != .prohibited {
                dlog("[Daemon] Blocked attempt to set activation policy to \(policy)")
                return true
            }
            typealias Fn = @convention(c) (NSApplication, Selector, NSApplication.ActivationPolicy) -> Bool
            let casted = unsafeBitCast(originalImp, to: Fn.self)
            return casted(app, sel, policy)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    private static func startDaemonProcess() {
        // 清理可能残留的旧 daemon 进程和文件
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-f", "wallpaperengine-cli daemon"]
        try? pkill.run()
        pkill.waitUntilExit()

        removeSocket()
        if FileManager.default.fileExists(atPath: PID_PATH) {
            try? FileManager.default.removeItem(atPath: PID_PATH)
        }

        let executable = CommandLine.arguments[0]
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = ["daemon"]
        let logURL = URL(fileURLWithPath: "/tmp/wallpaperengine-cli-daemon.log")
        // FileHandle(forWritingTo:) requires the file to exist; otherwise logging is silently disabled.
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: nil)
        }
        task.standardOutput = try? FileHandle(forWritingTo: logURL)
        task.standardError = task.standardOutput
        var env = ProcessInfo.processInfo.environment
        env["LSUIElement"] = "1"

        task.environment = env
        try? task.run()
    }

    private static func printUsage() {
        print("""
        Usage: wallpaperengine-cli <command>
        Commands:
          set <path> [screen_index]   Set wallpaper
          bake <path> --size WxH --fps auto|N --duration S --out <path>
                                     Export a Web wallpaper as dense H.264 MP4
                                     (auto profiles active video cadence; precise media seek)
          capture <screen_index>    Capture the current Web wallpaper frame
          pause                       Pause wallpaper
          resume                      Resume wallpaper
          stop-screen <screen_index>  Stop wallpaper on one display
          stop                        Stop wallpaper
          exit                        Alias for stop
        """)
    }
}


// MARK: - NSWorkspace 扩展：设置壁纸到所有 Spaces

extension NSWorkspace {
    func setDesktopImageURLForAllSpaces(_ url: URL, for screen: NSScreen, options: [DesktopImageOptionKey: Any] = [:]) throws {
        var merged = options
        merged[DesktopImageOptionKey(rawValue: "allSpaces")] = NSNumber(value: true)
        try setDesktopImageURL(url, for: screen, options: merged)
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("com.apple.desktop"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }
}
