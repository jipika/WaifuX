import CoreFoundation
import Darwin
import Foundation
import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import IOKit
import CryptoKit
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
}

// MARK: - Constants
private let SOCKET_PATH = "/tmp/wallpaperengine-cli.sock"
private let PID_PATH = "/tmp/wallpaperengine-cli.pid"
private let DEBUG_LOG_PATH = "/tmp/wallpaperengine-cli-debug.log"
/// Scene/Web 截图写入；推系统桌面时再复制到 desk-0/1 交替路径
private let PRIMARY_CAPTURE_PATH = "/tmp/wallpaperengine-cli-capture.png"
private let DESK_CAPTURE_PATH_0 = "/tmp/wallpaperengine-cli-desk-0.png"
private let DESK_CAPTURE_PATH_1 = "/tmp/wallpaperengine-cli-desk-1.png"

/// Per-screen capture paths（多屏并行壁纸避免共享文件竞争）
private func primaryCapturePath(for screen: Int) -> String {
    return "/tmp/wallpaperengine-cli-capture-s\(screen).png"
}
private func deskCapturePath(for screen: Int, slot: Int) -> String {
    return "/tmp/wallpaperengine-cli-desk-s\(screen)-\(slot).png"
}

private func isDynamicLockScreenEnabledForCurrentLaunch() -> Bool {
    let rawValue = ProcessInfo.processInfo.environment["WAIFUX_DYNAMIC_LOCK_SCREEN_ENABLED"]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
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
    case set, pause, resume, stop, applyProperties, audioControl, audioData
}

private struct IPCMessage: Codable {
    let command: IPCCommand
    let path: String?
    let screen: Int?
    let propertiesJSON: String?
    let muted: Bool?
    let volume: Double?
    /// WE 音频频谱（128 floats; 0..63 = L, 64..127 = R）；仅 `.audioData` 命令使用。
    let spectrum: [Float]?

    init(command: IPCCommand, path: String?, screen: Int?, propertiesJSON: String? = nil, muted: Bool? = nil, volume: Double? = nil, spectrum: [Float]? = nil) {
        self.command = command
        self.path = path
        self.screen = screen
        self.propertiesJSON = propertiesJSON
        self.muted = muted
        self.volume = volume
        self.spectrum = spectrum
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

    /// 对齐 [Wallpaper Engine Web 文档](https://docs.wallpaperengine.io/en/web/api/propertylistener.html) 等：提供 `wallpaperRegisterAudioListener`、
    /// 媒体集成注册函数与 `wallpaperMediaIntegration` 命名空间。无系统音频捕获时音频为全零；媒体集成默认 `enabled: false`。
    /// 避免壁纸脚本因 `undefined is not a function` 整页中断。
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
            // 暴露给 Swift 侧注入真实音频 FFT 数据
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
            // Fallback：无真实音频时维持旧行为（全零），或做 idle 动画
            setInterval(function() {
              if (!__wxAudioEnabled || Date.now() - __wxLastAudioAt > 500) {
                for (var i = 0; i < __wxAudioBuf.length; i++) __wxAudioBuf[i] = 0;
              }
              for (var j = 0; j < __wxAudioCbs.length; j++) {
                try { __wxAudioCbs[j](__wxAudioBuf); } catch (e) {}
              }
            }, 33);
            window.wallpaperRegisterMediaStatusListener = function(cb) {
              if (typeof cb === 'function') {
                try { cb({ enabled: false }); } catch (e) {}
              }
            };
            window.wallpaperRegisterMediaPropertiesListener = function(cb) {};
            window.wallpaperRegisterMediaThumbnailListener = function(cb) {};
            window.wallpaperRegisterMediaPlaybackListener = function(cb) {
              if (typeof cb === 'function') {
                try { cb({ state: window.wallpaperMediaIntegration.playback.STOPPED }); } catch (e) {}
              }
            };
            window.wallpaperRegisterMediaTimelineListener = function(cb) {};
          } catch (e) {}
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false
    )

    /// `file://` 壁纸常见兼容问题：
    /// 1) Spine 等库对 `HTMLImageElement` 设置 `crossOrigin = "anonymous"`，WebKit 在本地文件场景下会拒绝加载同目录纹理 → 画面空白。
    /// 2) 部分 Workshop 脚本用 `fetch()` 读相对路径 JSON，在 `file` 协议下可能失败；XHR 更稳。
    private static let localFileCompatScript = WKUserScript(
        source: """
        (function() {
          try {
            if (location.protocol !== "file:") return;
            var proto = HTMLImageElement.prototype;
            var srcDesc = Object.getOwnPropertyDescriptor(proto, "src");
            if (srcDesc && srcDesc.set) {
              Object.defineProperty(proto, "src", {
                set: function(value) {
                  try {
                    var s = String(value || "");
                    if (s.indexOf("http:") !== 0 && s.indexOf("https:") !== 0 && s.indexOf("data:") !== 0 && s.indexOf("blob:") !== 0) {
                      this.removeAttribute("crossorigin");
                    }
                  } catch (e) {}
                  srcDesc.set.call(this, value);
                },
                get: srcDesc.get,
                configurable: true
              });
            }
            var origFetch = window.fetch;
            if (typeof origFetch === "function") {
              window.fetch = function(input, init) {
                var url = typeof input === "string" ? input : (input && input.url) ? input.url : "";
                if (url && url.indexOf("http:") !== 0 && url.indexOf("https:") !== 0 && url.indexOf("data:") !== 0 && url.indexOf("blob:") !== 0) {
                  return new Promise(function(resolve, reject) {
                    var xhr = new XMLHttpRequest();
                    xhr.open("GET", url, true);
                    xhr.responseType = "arraybuffer";
                    xhr.onload = function() {
                      if (xhr.status === 200 || xhr.status === 0) {
                        var headers = new Headers();
                        try {
                          var contentType = xhr.getResponseHeader("Content-Type");
                          if (contentType) headers.set("Content-Type", contentType);
                        } catch (e) {}
                        resolve(new Response(xhr.response, {
                          status: xhr.status === 0 ? 200 : xhr.status,
                          statusText: xhr.statusText || "OK",
                          headers: headers
                        }));
                      } else {
                        reject(new Error("HTTP " + xhr.status));
                      }
                    };
                    xhr.onerror = function() { reject(new Error("network error")); };
                    xhr.send();
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

            if (typeof window.__waifuxAudioVolume !== 'number') {
                window.__waifuxAudioVolume = 1.0;
            }
            if (typeof window.__waifuxAudioMuted !== 'boolean') {
                window.__waifuxAudioMuted = false;
            }
            var wrappedRefs = [];

            function effectiveVolume() {
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

    /// 每个屏幕独立的 Web 渲染状态
    private struct ScreenState {
        var window: NSWindow?
        var webView: WKWebView?
        var pendingCompletion: ((Bool) -> Void)?
        var extractedPKGDir: URL?
        var mergedDependencyDir: URL?
        var injectedPropertiesJSON: String?
        var firstFrameSettleGeneration: UInt64 = 0
        var isLoaded: Bool = false
        var mouseEventMonitors: [Any] = []
        var lastMouseMoveTime: TimeInterval = 0
    }

    private var screenStates: [Int: ScreenState] = [:]
    private let mouseMoveThrottle: TimeInterval = 1.0 / 30.0

    private enum FirstFramePolicy {
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

    func loadWallpaper(path: String, width: Int, height: Int, screen: Int? = nil, completion: ((Bool) -> Void)? = nil) {
        // 解析目标屏幕索引
        let screens = NSScreen.screens
        let screenIdx: Int
        if let s = screen, s >= 0, s < screens.count {
            screenIdx = s
        } else if let main = NSScreen.main, let mainIdx = screens.firstIndex(of: main) {
            screenIdx = mainIdx
        } else {
            screenIdx = 0
        }

        stop(screen: screenIdx) // 只清理目标屏幕的旧状态
        screenStates[screenIdx] = ScreenState()
        screenStates[screenIdx]?.pendingCompletion = completion

        // 超时安全网：30 秒后如果 pendingCompletion 仍在，强制回调防止 IPC 响应永远不发回
        // （与 App 侧 WallpaperEngineXBridge 的 30s 超时对齐）
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, let state = self.screenStates[screenIdx],
                  state.pendingCompletion != nil else { return }
            dlog("[WebRendererBridge] ⚠️ loadWallpaper 30s timeout, forcing completion for screen \(screenIdx)")
            state.pendingCompletion?(false)
            self.screenStates[screenIdx]?.pendingCompletion = nil
        }

        guard let (baseURL, indexFile) = resolveWebWallpaperEntry(path: path) else {
            dlog("[WebRendererBridge] Failed to resolve web wallpaper entry for \(path)")
            completion?(false)
            return
        }

        screenStates[screenIdx]?.injectedPropertiesJSON = readWebWallpaperUserPropertiesJSON(contentDir: baseURL)
        if screenStates[screenIdx]?.injectedPropertiesJSON != nil {
            dlog("[WebRendererBridge] Loaded user properties from project.json for injection")
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
        w.level = .init(rawValue: Int(desktopLevel))
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.setFrame(targetScreen.frame, display: true)
        w.acceptsMouseMovedEvents = true
        w.ignoresMouseEvents = false
        w.isReleasedWhenClosed = false

        // 配置 WKWebView
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        let ucc = WKUserContentController()
        ucc.addUserScript(Self.wallpaperEngineWebAPIShim)
        ucc.addUserScript(Self.localFileCompatScript)
        ucc.addUserScript(Self.mouseEventBridgeScript)
        ucc.addUserScript(Self.audioWrapperScript)
        config.userContentController = ucc
        if #available(macOS 14.0, *) {
            config.defaultWebpagePreferences.allowsContentJavaScript = true
        }
        config.mediaTypesRequiringUserActionForPlayback = []

        let web = WKWebView(frame: w.contentView!.bounds, configuration: config)
        web.autoresizingMask = [.width, .height]
        web.navigationDelegate = self
        web.wantsLayer = true
        web.layer?.backgroundColor = NSColor.clear.cgColor
        web.layer?.contentsScale = targetScreen.backingScaleFactor

        w.contentView?.addSubview(web)

        screenStates[screenIdx]?.window = w
        screenStates[screenIdx]?.webView = web

        let fileURL = baseURL.appendingPathComponent(indexFile)
        let readAccessURL = webWallpaperFileReadAccessURL(projectContentDir: baseURL, cliWallpaperPath: path)
        if readAccessURL.path != baseURL.path {
            dlog("[WebRendererBridge] file read access expanded to workshop root: \(readAccessURL.path)")
        }
        autoFixSpineConfigIfNeeded(projectContentDir: baseURL)
        web.loadFileURL(fileURL, allowingReadAccessTo: readAccessURL)
        w.orderBack(nil)

        dlog("[WebRendererBridge] Loading web wallpaper: \(fileURL.path) on screen \(screenIdx) (\(targetScreen.localizedName))")
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
            self.beginSettlingFirstFrame(screen: s)
            self.startMouseEventBridge(for: s)
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
        state.window?.orderBack(nil)
        state.webView?.evaluateJavaScript("""
            document.querySelectorAll('video, audio').forEach(m => { if(m.paused) m.play().catch(()=>{}); });
            document.querySelectorAll('*').forEach(el => {
                if (el.style.animationPlayState === 'paused') el.style.animationPlayState = 'running';
            });
            window.dispatchEvent(new Event('resize'));
        """) { _, _ in }
        startMouseEventBridge(for: screen)
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
        state.window?.close()
        state.window = nil
        state.isLoaded = false
        if let dir = state.extractedPKGDir { try? FileManager.default.removeItem(at: dir); state.extractedPKGDir = nil }
        if let dir = state.mergedDependencyDir { try? FileManager.default.removeItem(at: dir); state.mergedDependencyDir = nil }
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
            guard state.isLoaded, let window = state.window, let webView = state.webView else { continue }
            guard window.frame.contains(mouseLocation) else { continue }
            let relX = mouseLocation.x - window.frame.origin.x
            let relY = mouseLocation.y - window.frame.origin.y
            let webViewX = relX
            let webViewY = window.frame.height - relY
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

    private func runWebWallpaperBootstrap(screen: Int, completion: (() -> Void)? = nil) {
        guard let state = screenStates[screen], let webView = state.webView else { completion?(); return }
        var propsBlock = ""
        var b64Props = ""
        if let json = state.injectedPropertiesJSON, let data = json.data(using: .utf8) {
            b64Props = data.base64EncodedString()
            propsBlock = "try{var props=JSON.parse(atob(\"" + b64Props + "\"));if(window.wallpaperPropertyListener&&typeof window.wallpaperPropertyListener.applyUserProperties==='function'){window.wallpaperPropertyListener.applyUserProperties(props);}}catch(e){}"
        }
        // 先重置样式，再执行 propsBlock（applyUserProperties 可能会设置 background-image 等样式）
        // 如果顺序反过来，bootstrap 的 background-image:none 会清掉 applyUserProperties 设置的背景图
        let source = "(function(){try{document.documentElement.style.cssText='width:100%;height:100%;margin:0;padding:0;background:transparent;overflow:hidden;';document.body.style.setProperty('width','100%');document.body.style.setProperty('height','100%');window.dispatchEvent(new Event('resize'));}catch(e2){}" + propsBlock + "return true;})();"
        webView.evaluateJavaScript(source) { [weak self] _, _ in
            // 延迟重新应用属性：部分壁纸（如 Spine 动画壁纸）异步初始化可能覆盖首次 applyUserProperties 设置的样式
            // 500ms 后再次调用 applyUserProperties 确保 background-image 等属性在异步初始化完成后仍然生效
            if !b64Props.isEmpty, let webView = self?.screenStates[screen]?.webView {
                let reapply = "(function(){try{var props=JSON.parse(atob(\"" + b64Props + "\"));if(window.wallpaperPropertyListener&&typeof window.wallpaperPropertyListener.applyUserProperties==='function'){window.wallpaperPropertyListener.applyUserProperties(props);}}catch(e){}})();"
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    webView.evaluateJavaScript(reapply) { _, _ in }
                }
            }
            DispatchQueue.main.async { completion?() }
        }
    }

    private func beginSettlingFirstFrame(screen: Int) {
        screenStates[screen]?.firstFrameSettleGeneration &+= 1
        let gen = screenStates[screen]?.firstFrameSettleGeneration ?? 0
        let t0 = Date()
        final class SettleState { var lastThumb: [UInt8]?; var stablePasses = 0; var lastImage: NSImage? }
        let ss = SettleState()
        func finish(_ image: NSImage?, reason: String) {
            guard self.screenStates[screen]?.firstFrameSettleGeneration == gen else { return }
            let ok = image.map { self.saveImage($0, screen: screen) } ?? false
            self.screenStates[screen]?.pendingCompletion?(ok)
            self.screenStates[screen]?.pendingCompletion = nil
        }
        func scheduleStep() {
            guard self.screenStates[screen]?.firstFrameSettleGeneration == gen,
                  self.screenStates[screen]?.webView != nil else { return }
            let elapsed = Date().timeIntervalSince(t0)
            if elapsed >= FirstFramePolicy.maxElapsed { finish(ss.lastImage, reason: "timeout"); return }
            self.snapshotWebView(screen: screen) { image in
                guard self.screenStates[screen]?.firstFrameSettleGeneration == gen else { return }
                guard let image = image else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + FirstFramePolicy.pollInterval) { scheduleStep() }; return
                }
                ss.lastImage = image
                let thumb = self.grayscaleThumb(from: image, dimension: FirstFramePolicy.thumbDimension)
                defer { if let t = thumb { ss.lastThumb = t } }
                if let prev = ss.lastThumb, let curr = thumb {
                    let diff = Self.meanAbsDiffGrayscale(prev, curr)
                    if diff < FirstFramePolicy.diffThreshold, elapsed >= FirstFramePolicy.minElapsed { ss.stablePasses += 1 }
                    else { ss.stablePasses = 0 }
                    if ss.stablePasses >= FirstFramePolicy.stablePassesRequired { finish(image, reason: "stable"); return }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + FirstFramePolicy.pollInterval) { scheduleStep() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { scheduleStep() }
    }

    private func snapshotWebView(screen: Int, completion: @escaping (NSImage?) -> Void) {
        guard let webView = screenStates[screen]?.webView else { completion(nil); return }
        if #available(macOS 11.0, *) {
            let config = WKSnapshotConfiguration()
            config.rect = CGRect(origin: .zero, size: webView.bounds.size)
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
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return false }
        let path = primaryCapturePath(for: screen)
        do { try png.write(to: URL(fileURLWithPath: path), options: .atomic); return true }
        catch { return false }
    }

    private func saveBitmap(_ bitmap: NSBitmapImageRep, screen: Int = 0) -> Bool {
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return false }
        let path = primaryCapturePath(for: screen)
        do { try png.write(to: URL(fileURLWithPath: path), options: .atomic); return true }
        catch { return false }
    }

    func captureFrame(screen: Int = 0, completion: ((Bool) -> Void)? = nil) {
        snapshotWebView(screen: screen) { [weak self] image in
            guard let image = image else { completion?(false); return }
            completion?(self?.saveImage(image, screen: screen) ?? false)
        }
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
        var desktopCaptureSlot: Int = 0
    }

    private var screenStates: [Int: ScreenState] = [:]

    /// 所有屏幕共享的原始壁纸备份（首次设置时保存，全部停止后恢复）
    private var activeScreenCount: Int = 0


    private let originalWallpaperKey = "renderer_original_wallpaper_v1"
    private(set) var lastErrorMessage: String?

    private init() {}

    func setWallpaper(path: String, width: Int = 1920, height: Int = 1080, screen: Int? = nil, completion: ((Bool) -> Void)? = nil) {
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

        // 清掉该屏幕的旧截图与桌面用副本
        let capPath = primaryCapturePath(for: screenIdx)
        try? FileManager.default.removeItem(atPath: capPath)
        try? FileManager.default.removeItem(atPath: deskCapturePath(for: screenIdx, slot: 0))
        try? FileManager.default.removeItem(atPath: deskCapturePath(for: screenIdx, slot: 1))

        // 初始化该屏幕的壁纸状态
        var state = ScreenState()
        state.wallpaperPath = path
        state.isWebMode = webMode
        state.isRunning = true
        state.isPaused = false
        state.desktopCaptureSlot = 0
        screenStates[screenIdx] = state
        activeScreenCount += 1

        if webMode {
            WebRendererBridge.shared.loadWallpaper(path: path, width: width, height: height, screen: screenIdx) { [weak self] success in
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
                } else {
                    // 首帧截图推系统桌面（锁屏/调度中心等），之后由 desktopWindow 层级的动态窗口直接渲染
                    self.applyCaptureAsDesktopWallpaper(screen: screenIdx)
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
        // 暂停后截取一帧推送系统桌面（动态窗口已隐藏，桌面需要静态图兜底）
        WebRendererBridge.shared.captureFrame(screen: screen) { [weak self] success in
            if success {
                self?.applyCaptureAsDesktopWallpaper(screen: screen)
            }
        }
        screenStates[screen]?.isPaused = true
    }

    func resumeWallpaper(screen: Int = 0) {
        guard let state = screenStates[screen], state.isRunning, state.isPaused else { return }
        WebRendererBridge.shared.resume(screen: screen)
        screenStates[screen]?.isPaused = false
    }

    @discardableResult
    func applyWebWallpaperProperties(_ jsonString: String, screen: Int = 0) -> Bool {
        guard let state = screenStates[screen], state.isRunning, state.isWebMode else { return false }
        return WebRendererBridge.shared.applyUserProperties(jsonString: jsonString, screen: screen)
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

    func stopWallpaper(screen: Int = 0) {
        guard screenStates[screen] != nil else { return }
        WebRendererBridge.shared.stop(screen: screen)
        // 清理该屏幕的截图文件
        try? FileManager.default.removeItem(atPath: primaryCapturePath(for: screen))
        try? FileManager.default.removeItem(atPath: deskCapturePath(for: screen, slot: 0))
        try? FileManager.default.removeItem(atPath: deskCapturePath(for: screen, slot: 1))
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

    // MARK: - Desktop Wallpaper Capture Updates

    /// 将主截图复制到交替路径再设为桌面图，避免系统因固定路径缓存上一张壁纸（锁屏/静态桌面不更新）
    private func applyCaptureAsDesktopWallpaper(screen: Int) {
        let capPath = primaryCapturePath(for: screen)
        guard FileManager.default.fileExists(atPath: capPath) else { return }
        guard !isDynamicLockScreenEnabledForCurrentLaunch() else {
            dlog("[DesktopWallpaperManager] Dynamic lock screen enabled; skip static capture desktop apply")
            return
        }
        let src = URL(fileURLWithPath: capPath)
        // 交替 slot 避免系统缓存
        let currentSlot = screenStates[screen]?.desktopCaptureSlot ?? 0
        let newSlot = 1 - currentSlot
        screenStates[screen]?.desktopCaptureSlot = newSlot
        let dstPath = deskCapturePath(for: screen, slot: newSlot)
        let dst = URL(fileURLWithPath: dstPath)
        let fm = FileManager.default
        try? fm.removeItem(at: dst)
        do {
            try fm.copyItem(at: src, to: dst)
        } catch {
            print("[DesktopWallpaperManager] Failed to copy capture for desktop: \(error)")
            return
        }

        let workspace = NSWorkspace.shared
        let screens = NSScreen.screens
        guard screen >= 0, screen < screens.count else { return }
        let targetScreen = screens[screen]

        do {
            // 使用 "充满屏幕" 缩放模式，与 App 内其他壁纸设置行为一致
            try workspace.setDesktopImageURLForAllSpaces(dst, for: targetScreen, options: [
                .imageScaling: NSNumber(value: NSImageScaling.scaleProportionallyUpOrDown.rawValue),
                .allowClipping: true
            ])
        } catch {
            print("[DesktopWallpaperManager] Failed to set desktop image: \(error)")
        }
        dlog("[DesktopWallpaperManager] Applied capture as desktop wallpaper for screen \(screen) via \(dstPath)")
    }

    // （已移除 startPeriodicCapture：不再持续截图推送系统桌面）


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
            guard length > 0, length < 1024 * 1024 else { close(fd); return }

            var data = Data()
            while data.count < Int(length) {
                var chunk = Data(repeating: 0, count: Int(length) - data.count)
                let chunkSize = chunk.count
                let n = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress, chunkSize, 0) }
                guard n > 0 else { close(fd); return }
                data.append(chunk.prefix(n))
            }

            guard let msg = try? JSONDecoder().decode(IPCMessage.self, from: data) else {
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
                        let screens = NSScreen.screens
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
                            screen: msg.screen
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
        case "set", "pause", "resume", "stop", "exit", "apply-properties":
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
            } else {
                guard isDaemonRunning() else {
                    print("Daemon not responding")
                    exit(1)
                }
            }

            let msg: IPCMessage
            switch command {
            case "set":
                let setArgs = Array(remainingArgs.dropFirst())
                guard !setArgs.isEmpty else {
                    print("Usage: wallpaperengine-cli set <path> [screen_index]")
                    exit(1)
                }
                var path = setArgs.joined(separator: " ")
                var screen: Int? = nil
                if setArgs.count > 1, let s = Int(setArgs.last!) {
                    screen = s
                    path = setArgs.dropLast().joined(separator: " ")
                }
                msg = IPCMessage(command: .set, path: path, screen: screen)
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

            let responseTimeout: TimeInterval = command == "set" ? 35.0 : 5.0
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
          pause                       Pause wallpaper
          resume                      Resume wallpaper
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
