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
import CRenderer

// MARK: - Constants
private let SOCKET_PATH = "/tmp/wallpaperengine-cli.sock"
private let PID_PATH = "/tmp/wallpaperengine-cli.pid"
private let DEBUG_LOG_PATH = "/tmp/wallpaperengine-cli-debug.log"
/// Scene/Web 截图写入；推系统桌面时再复制到 desk-0/1 交替路径
private let PRIMARY_CAPTURE_PATH = "/tmp/wallpaperengine-cli-capture.png"
private let DESK_CAPTURE_PATH_0 = "/tmp/wallpaperengine-cli-desk-0.png"
private let DESK_CAPTURE_PATH_1 = "/tmp/wallpaperengine-cli-desk-1.png"

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
    case set, pause, resume, stop
}

private struct IPCMessage: Codable {
    let command: IPCCommand
    let path: String?
    let screen: Int?
}

// MARK: - RendererBridge (from Wallpaper Engine X)
private final class RendererBridge {
    static let shared = RendererBridge()

    private var handle: UnsafeMutableRawPointer?
    /// Bumped on stop/cancel so in-flight `asyncAfter` tick chains exit without piling up work.
    private var tickGeneration: UInt64 = 0
    private let tickQueue = DispatchQueue(label: "com.wallpaperenginex.renderer.tick", qos: .utility)
    private let rendererLock = NSLock()
    private var isLoaded = false
    private var lastAssetsPath: String? = nil

    private init() {}

    /// Default 24 fps; override with env `WAIFUX_WALLPAPERENGINE_FPS` (e.g. 20–30).
    private func effectiveTargetFPS() -> Double {
        if let s = ProcessInfo.processInfo.environment["WAIFUX_WALLPAPERENGINE_FPS"],
           let v = Double(s), v > 0, v <= 120 {
            return v
        }
        return 24.0
    }

    private func defaultAssetsPath() -> String {
        // 1) CLI 自包含：材质 zip 追加在可执行文件尾部，解压到 Caches（主 App 不再带 assets 目录）
        if let embedded = WallpaperEngineEmbeddedAssets.materializedAssetsRootIfPresent(),
           FileManager.default.fileExists(atPath: embedded) {
            return embedded
        }

        // 2) 开发/调试：环境变量覆盖
        if let injected = ProcessInfo.processInfo.environment["WAIFUX_WALLPAPERENGINE_ASSETS"],
           !injected.isEmpty,
           FileManager.default.fileExists(atPath: injected) {
            return injected
        }

        let executableDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let candidates = [
            executableDir.appendingPathComponent("assets").path,
            executableDir.appendingPathComponent("Resources").appendingPathComponent("assets").path
        ]
        for candidate in candidates {
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }
        if let bundlePath = Bundle.main.path(forResource: "assets", ofType: nil),
           FileManager.default.fileExists(atPath: bundlePath) {
            return bundlePath
        }
        return ""
    }

    deinit {
        cancelTickTimer()
        _ = drainTickQueue(timeout: 2.0)
        rendererLock.lock()
        if let h = handle {
            lw_renderer_destroy(h)
        }
        rendererLock.unlock()
    }

    func recreateWithAssets(path: String) {
        cancelTickTimer()
        _ = drainTickQueue(timeout: 2.0)
        rendererLock.lock()
        if let h = handle {
            lw_renderer_destroy(h)
        }
        if !path.isEmpty {
            handle = lw_renderer_create_with_assets(path)
        } else {
            handle = lw_renderer_create()
        }
        rendererLock.unlock()
    }

    func setAssetsPath(path: String) {
        lastAssetsPath = path
        rendererLock.lock()
        guard let h = handle else {
            rendererLock.unlock()
            return
        }
        lw_renderer_set_assets_path(h, path)
        rendererLock.unlock()
    }

    func loadWallpaper(path: String, width: Int, height: Int, autoStartTicking: Bool = true) {
        // 预检 Scene parent 循环引用，避免 C++ 渲染器陷入不可恢复的无限递归
        if let validationError = validateSceneParentGraph(sceneRoot: path) {
            dlog("[RendererBridge] Scene validation failed: \(validationError)")
            rendererLock.lock()
            isLoaded = false
            rendererLock.unlock()
            return
        }

        rendererLock.lock()
        if isLoaded {
            rendererLock.unlock()
            cancelTickTimer()
            _ = drainTickQueue(timeout: 2.0)
            rendererLock.lock()
            if let h = handle {
                lw_renderer_destroy(h)
            }
            handle = nil
            isLoaded = false
        }

        let assets = lastAssetsPath ?? defaultAssetsPath()
        dlog("[RendererBridge] Creating renderer assets=\(assets) ...")
        if !assets.isEmpty {
            handle = autoreleasepool { lw_renderer_create_with_assets(assets) }
        } else {
            handle = autoreleasepool { lw_renderer_create() }
        }
        dlog("[RendererBridge] Renderer handle=\(String(describing: handle))")

        guard let h = handle else {
            rendererLock.unlock()
            dlog("[RendererBridge] ERROR: lw_renderer_create returned nil")
            return
        }
        dlog("[RendererBridge] Loading wallpaper: \(path) \(width)x\(height)")
        autoreleasepool { lw_renderer_load(h, path, Int32(width), Int32(height)) }
        dlog("[RendererBridge] lw_renderer_load returned")
        isLoaded = true
        rendererLock.unlock()
        if autoStartTicking {
            startTicking(fps: effectiveTargetFPS())
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self = self else { return }
                let w = self.renderWidth
                let h = self.renderHeight
                if w <= 0 || h <= 0 {
                    dlog("[RendererBridge] ERROR: Wallpaper load failed for \(path). Render size is \(w)x\(h).")
                }
            }
        }
    }

    /// 单步 tick（离线烘焙）；返回 false 表示应停止（close_requested 或无效状态）
    func tickOnce() -> Bool {
        rendererLock.lock()
        guard let h = handle, isLoaded else {
            rendererLock.unlock()
            return false
        }
        lw_renderer_tick(h)
        let close = lw_renderer_close_requested(h) != 0
        rendererLock.unlock()
        if close {
            cancelTickTimer()
            rendererLock.lock()
            if let hh = handle {
                lw_renderer_hide_window(hh)
            }
            isLoaded = false
            rendererLock.unlock()
            return false
        }
        return true
    }

    func startTicking(fps: Double? = nil) {
        cancelTickTimer()
        _ = drainTickQueue(timeout: 2.0)

        let targetFps = fps ?? effectiveTargetFPS()
        let period = 1.0 / max(1.0, min(120.0, targetFps))
        tickGeneration &+= 1
        let generation = tickGeneration

        func scheduleNext() {
            tickQueue.async { [weak self] in
                guard let self else { return }
                guard generation == self.tickGeneration else { return }
                let frameStart = CFAbsoluteTimeGetCurrent()
                self.rendererLock.lock()
                guard generation == self.tickGeneration, let h = self.handle else {
                    self.rendererLock.unlock()
                    return
                }
                lw_renderer_tick(h)
                let close = lw_renderer_close_requested(h) != 0
                self.rendererLock.unlock()

                if close {
                    self.cancelTickTimer()
                    self.rendererLock.lock()
                    if let hh = self.handle {
                        lw_renderer_hide_window(hh)
                    }
                    self.isLoaded = false
                    self.rendererLock.unlock()
                    return
                }

                guard generation == self.tickGeneration else { return }
                let elapsed = CFAbsoluteTimeGetCurrent() - frameStart
                let delay = max(0.002, period - elapsed)
                self.tickQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, generation == self.tickGeneration else { return }
                    scheduleNext()
                }
            }
        }
        scheduleNext()
    }

    func stop() {
        cancelTickTimer()
        _ = drainTickQueue(timeout: 2.0)
    }

    /// Scene 动态壁纸暂停：只停渲染 tick，**不** `hideWindow()`。
    /// 隐藏 GL 窗口在部分环境下会触发 close 语义，恢复后首帧 tick 即认为需退出，表现为「像退出且无法恢复」。
    /// 不 tick 时画面已静止；与彻底 `destroy` 的「停止壁纸」不同。
    func pauseSceneRendering() {
        cancelTickTimer()
        _ = drainTickQueue(timeout: 2.0)
    }

    /// 从暂停恢复：确保 `isLoaded` 与窗口状态正确后重启 tick
    func resumeSceneRendering() {
        showWindow()
        rendererLock.lock()
        if handle != nil {
            isLoaded = true
        }
        rendererLock.unlock()
        startTicking(fps: effectiveTargetFPS())
    }

    private func cancelTickTimer() {
        tickGeneration &+= 1
    }

    private func drainTickQueue(timeout: TimeInterval) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        tickQueue.async {
            semaphore.signal()
        }
        let result = semaphore.wait(timeout: .now() + timeout)
        return result == .success
    }

    func destroy() {
        cancelTickTimer()
        _ = drainTickQueue(timeout: 2.0)
        rendererLock.lock()
        if let h = handle {
            lw_renderer_destroy(h)
            handle = nil
        }
        isLoaded = false
        lastAssetsPath = nil
        rendererLock.unlock()
    }

    func resize(width: Int, height: Int) {
        rendererLock.lock()
        guard let h = handle else {
            rendererLock.unlock()
            return
        }
        lw_renderer_resize(h, Int32(width), Int32(height))
        rendererLock.unlock()
    }

    func showWindow() {
        rendererLock.lock()
        guard let h = handle else {
            rendererLock.unlock()
            return
        }
        lw_renderer_show_window(h)
        rendererLock.unlock()
    }

    func hideWindow() {
        rendererLock.lock()
        guard let h = handle else {
            rendererLock.unlock()
            return
        }
        lw_renderer_hide_window(h)
        rendererLock.unlock()
    }

    func setDesktopWindow(_ desktop: Bool) {
        rendererLock.lock()
        guard let h = handle else {
            rendererLock.unlock()
            return
        }
        lw_renderer_set_desktop_window(h, desktop ? 1 : 0)
        rendererLock.unlock()
    }

    var textureID: UInt32 {
        rendererLock.lock()
        defer { rendererLock.unlock() }
        guard let h = handle else { return 0 }
        return lw_renderer_get_texture(h)
    }

    var renderWidth: Int {
        rendererLock.lock()
        defer { rendererLock.unlock() }
        guard let h = handle else { return 0 }
        return Int(lw_renderer_get_width(h))
    }

    var renderHeight: Int {
        rendererLock.lock()
        defer { rendererLock.unlock() }
        guard let h = handle else { return 0 }
        return Int(lw_renderer_get_height(h))
    }

    func setScreen(_ index: Int) {
        rendererLock.lock()
        defer { rendererLock.unlock() }
        guard let h = handle else { return }
        lw_renderer_set_screen(h, Int32(index))
    }

    func captureFrame() -> CGImage? {
        rendererLock.lock()
        defer { rendererLock.unlock() }
        guard let h = handle else { return nil }
        var buffer: UnsafeMutablePointer<UInt8>?
        var w: Int32 = 0
        var h32: Int32 = 0
        guard lw_renderer_capture_frame(h, &buffer, &w, &h32) != 0 else { return nil }
        let width = Int(w)
        let height = Int(h32)
        let bytesPerRow = width * 4

        // OpenGL framebuffer is bottom-up; flip vertically for CGImage (top-down)
        let flippedBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bytesPerRow * height)
        for row in 0..<height {
            let src = buffer!.advanced(by: row * bytesPerRow)
            let dst = flippedBuffer.advanced(by: (height - 1 - row) * bytesPerRow)
            dst.update(from: src, count: bytesPerRow)
        }
        lw_renderer_free_buffer(buffer)

        guard let provider = CGDataProvider(dataInfo: nil, data: flippedBuffer, size: bytesPerRow * height, releaseData: { (_, data, _) in
            data.deallocate()
        }) else {
            flippedBuffer.deallocate()
            return nil
        }
        guard let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            return nil
        }
        return cgImage
    }

    func saveCapture(to url: URL) -> Bool {
        guard let cgImage = captureFrame() else { return false }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, cgImage, nil)
        return CGImageDestinationFinalize(destination)
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

private extension NSScreen {
    var wallpaperScreenIdentifier: String {
        if let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return screenNumber.stringValue
        }
        return localizedName + ":\(frame.origin.x):\(frame.origin.y)"
    }
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

    let projectJSON = contentDir.appendingPathComponent("project.json")
    guard fm.fileExists(atPath: projectJSON.path),
          let data = try? Data(contentsOf: projectJSON),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    return json["type"] as? String
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

/// 预检 Scene 壁纸的 objects parent 链，检测循环引用和过深层级。
/// 返回 nil 表示通过预检；返回字符串表示错误原因（应拒绝加载）。
private func validateSceneParentGraph(sceneRoot: String) -> String? {
    let fm = FileManager.default
    let rootURL = URL(fileURLWithPath: sceneRoot)

    let projectJSON = rootURL.appendingPathComponent("project.json")
    guard fm.fileExists(atPath: projectJSON.path),
          let data = try? Data(contentsOf: projectJSON),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }

    guard let type = json["type"] as? String, type.lowercased() == "scene" else {
        return nil
    }

    let sceneFileName = json["file"] as? String ?? "scene.json"
    let sceneURL = rootURL.appendingPathComponent(sceneFileName)

    guard fm.fileExists(atPath: sceneURL.path),
          let sceneData = try? Data(contentsOf: sceneURL),
          let sceneJson = try? JSONSerialization.jsonObject(with: sceneData) as? [String: Any],
          let objects = sceneJson["objects"] as? [[String: Any]] else {
        return nil
    }

    var idToParent: [Int: Int] = [:]
    var idToName: [Int: String] = [:]
    for obj in objects {
        guard let id = obj["id"] as? Int else { continue }
        idToName[id] = obj["name"] as? String ?? "?"
        if let parent = obj["parent"] as? Int {
            idToParent[id] = parent
        }
    }

    let maxDepth = 500

    func detectCycle(from startId: Int, visited: inout Set<Int>, path: inout [Int], depth: Int) -> String? {
        if depth > maxDepth {
            return "Scene 对象层级过深（>\(maxDepth)），可能存在异常嵌套"
        }
        if let idx = path.firstIndex(of: startId) {
            let cycle = path[idx...] + [startId]
            let chain = cycle.map { "\($0)(\(idToName[$0] ?? "?"))" }.joined(separator: " -> ")
            return "Scene 对象存在 parent 循环引用: \(chain)"
        }
        if visited.contains(startId) {
            return nil
        }
        visited.insert(startId)
        path.append(startId)
        defer { path.removeLast() }

        guard let parentId = idToParent[startId] else { return nil }
        return detectCycle(from: parentId, visited: &visited, path: &path, depth: depth + 1)
    }

    var visited = Set<Int>()
    for id in idToParent.keys {
        var path = [Int]()
        if let error = detectCycle(from: id, visited: &visited, path: &path, depth: 1) {
            return error
        }
    }

    return nil
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
            window.wallpaperRegisterAudioListener = function(cb) {
              if (typeof cb === 'function') __wxAudioCbs.push(cb);
            };
            setInterval(function() {
              for (var i = 0; i < __wxAudioBuf.length; i++) __wxAudioBuf[i] = 0;
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
                    xhr.onload = function() {
                      if (xhr.status === 200 || xhr.status === 0) {
                        resolve(new Response(xhr.responseText, { status: 200, statusText: "OK" }));
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

    private var window: NSWindow?
    private var webView: WKWebView?
    private var captureTimer: Timer?
    private var pendingCompletion: ((Bool) -> Void)?
    private var extractedPKGDir: URL?
    /// `project.json` → `general.properties` 的 JSON 文本，加载完成后注入 JS
    private var injectedPropertiesJSON: String?
    /// 递增以取消进行中的首帧采样（stop / 重新加载）
    private var firstFrameSettleGeneration: UInt64 = 0
    private(set) var isLoaded = false

    private enum FirstFramePolicy {
        /// 至少经历此时长后才允许「稳定」判真，避免白屏/首帧未绘制误判
        static let minElapsed: TimeInterval = 1.05
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
        stop() // 清理旧的（包括临时目录）
        pendingCompletion = completion
        injectedPropertiesJSON = nil

        guard let (baseURL, indexFile) = resolveWebWallpaperEntry(path: path) else {
            dlog("[WebRendererBridge] Failed to resolve web wallpaper entry for \(path)")
            completion?(false)
            return
        }

        injectedPropertiesJSON = readWebWallpaperUserPropertiesJSON(contentDir: baseURL)
        if injectedPropertiesJSON != nil {
            dlog("[WebRendererBridge] Loaded user properties from project.json for injection")
        }

        // 记录 .pkg 解压目录以便 stop 时清理
        if URL(fileURLWithPath: path).pathExtension.lowercased() == "pkg" {
            extractedPKGDir = baseURL
        }

        let screens = NSScreen.screens
        let targetScreen: NSScreen
        if let s = screen, s >= 0, s < screens.count {
            targetScreen = screens[s]
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
        // 允许交互式 Web 壁纸（如 Spine 点击）接收鼠标；桌面图标层仍高于 desktopWindow，一般仍可点到图标
        w.acceptsMouseMovedEvents = false
        w.ignoresMouseEvents = false
        w.isReleasedWhenClosed = false

        // 配置 WKWebView
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptEnabled = true
        // 允许本地 HTML 引用同目录资源（Workshop web 壁纸依赖）
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        let ucc = WKUserContentController()
        ucc.addUserScript(Self.wallpaperEngineWebAPIShim)
        ucc.addUserScript(Self.localFileCompatScript)
        config.userContentController = ucc
        if #available(macOS 14.0, *) {
            config.defaultWebpagePreferences.allowsContentJavaScript = true
        }
        config.mediaTypesRequiringUserActionForPlayback = []

        // 允许本地文件访问
        let web = WKWebView(frame: w.contentView!.bounds, configuration: config)
        web.autoresizingMask = [.width, .height]
        web.navigationDelegate = self
        web.wantsLayer = true
        web.layer?.backgroundColor = NSColor.black.cgColor
        web.layer?.contentsScale = targetScreen.backingScaleFactor

        w.contentView?.addSubview(web)

        self.window = w
        self.webView = web

        let fileURL = baseURL.appendingPathComponent(indexFile)
        let readAccessURL = webWallpaperFileReadAccessURL(projectContentDir: baseURL, cliWallpaperPath: path)
        if readAccessURL.path != baseURL.path {
            dlog("[WebRendererBridge] file read access expanded to workshop root: \(readAccessURL.path)")
        }
        web.loadFileURL(fileURL, allowingReadAccessTo: readAccessURL)
        w.orderBack(nil)

        dlog("[WebRendererBridge] Loading web wallpaper: \(fileURL.path) on screen \(targetScreen.localizedName)")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        dlog("[WebRendererBridge] didFinish")
        isLoaded = true
        // 对齐 Wallpaper Engine：注入 project 属性 + 修正缺失背景图与全屏布局，再稍等 Spine 应用相机/缩放
        runWebWallpaperBootstrap { [weak self] in
            guard let self = self else { return }
            self.beginSettlingFirstFrame()
        }
        NSApp.setActivationPolicy(.prohibited)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        dlog("[WebRendererBridge] didFail: \(error)")
        firstFrameSettleGeneration += 1
        pendingCompletion?(false)
        pendingCompletion = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        dlog("[WebRendererBridge] didFailProvisional: \(error)")
        firstFrameSettleGeneration += 1
        pendingCompletion?(false)
        pendingCompletion = nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        dlog("[WebRendererBridge] WebContent process terminated")
        firstFrameSettleGeneration += 1
        pendingCompletion?(false)
        pendingCompletion = nil
        isLoaded = false
    }

    func pause() {
        window?.orderOut(nil)
        captureTimer?.invalidate()
        captureTimer = nil
        // 暂停页面内所有媒体与 CSS 动画，避免后台继续消耗资源
        webView?.evaluateJavaScript("""
            document.querySelectorAll('video, audio').forEach(m => m.pause());
            document.querySelectorAll('*').forEach(el => {
                const st = window.getComputedStyle(el);
                if (st.animationName !== 'none') el.style.animationPlayState = 'paused';
            });
        """) { _, _ in }
    }

    func resume() {
        guard isLoaded else { return }
        window?.orderBack(nil)
        // 恢复媒体与动画
        webView?.evaluateJavaScript("""
            document.querySelectorAll('video, audio').forEach(m => { if(m.paused) m.play().catch(()=>{}); });
            document.querySelectorAll('*').forEach(el => {
                if (el.style.animationPlayState === 'paused') el.style.animationPlayState = 'running';
            });
            window.dispatchEvent(new Event('resize'));
        """) { _, _ in }
        startCaptureTimer()
        NSApp.setActivationPolicy(.prohibited)
    }

    func stop() {
        firstFrameSettleGeneration += 1
        captureTimer?.invalidate()
        captureTimer = nil
        // 中断可能还在等待的 completion
        pendingCompletion = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        window?.close()
        window = nil
        isLoaded = false
        // 清理 .pkg 解压产生的临时目录
        if let dir = extractedPKGDir {
            try? FileManager.default.removeItem(at: dir)
            extractedPKGDir = nil
        }
        injectedPropertiesJSON = nil
    }

    /// 注入 WE 用户属性、去掉常见坏掉的 `background.png`、铺满视口并触发 resize（供 Spine/Canvas 重算）
    private func runWebWallpaperBootstrap(completion: (() -> Void)? = nil) {
        var propsBlock = ""
        if let json = injectedPropertiesJSON,
           let data = json.data(using: .utf8) {
            let b64 = data.base64EncodedString()
            propsBlock = """
            try {
              var props = JSON.parse(atob("\(b64)"));
              if (window.wallpaperPropertyListener && typeof window.wallpaperPropertyListener.applyUserProperties === 'function') {
                window.wallpaperPropertyListener.applyUserProperties(props);
              }
            } catch(e) {}
            """
        }
        let generalPropsBlock = """
        try {
          if (window.wallpaperPropertyListener && typeof window.wallpaperPropertyListener.applyGeneralProperties === 'function') {
            window.wallpaperPropertyListener.applyGeneralProperties({ fps: { value: 30, type: 'slider' } });
          }
        } catch(eGP) {}
        """
        let layoutBlock = """
        try {
          document.documentElement.style.cssText = 'width:100%;height:100%;margin:0;padding:0;background:transparent;overflow:hidden;';
          document.body.style.setProperty('background-image', 'none', 'important');
          document.body.style.setProperty('width', '100%');
          document.body.style.setProperty('height', '100%');
          document.body.style.setProperty('margin', '0');
          document.body.style.setProperty('overflow', 'hidden');
          var pc = document.getElementById('player-container');
          if (pc) { pc.style.width = '100%'; pc.style.height = '100%'; }
          window.dispatchEvent(new Event('resize'));
        } catch(e2) {}
        """
        let source = "(function(){\(propsBlock)\(generalPropsBlock)\(layoutBlock); return true;})();"
        webView?.evaluateJavaScript(source) { _, _ in
            DispatchQueue.main.async { completion?() }
        }
    }

    /// 轮询截图直到画面连续稳定（加载动画结束）或超时，避免把 Loading 当首帧
    private func beginSettlingFirstFrame() {
        firstFrameSettleGeneration += 1
        let gen = firstFrameSettleGeneration
        let t0 = Date()

        final class SettleState {
            var lastThumb: [UInt8]?
            var stablePasses = 0
            var lastImage: NSImage?
        }
        let state = SettleState()

        func finish(_ image: NSImage?, reason: String) {
            guard gen == firstFrameSettleGeneration else { return }
            let ok: Bool
            if let image = image {
                ok = saveImage(image)
            } else {
                ok = false
            }
            dlog("[WebRendererBridge] First frame settle: \(reason), saveOk=\(ok)")
            pendingCompletion?(ok)
            pendingCompletion = nil
            startCaptureTimer()
        }

        func scheduleStep() {
            guard gen == firstFrameSettleGeneration, webView != nil else { return }
            let elapsed = Date().timeIntervalSince(t0)
            if elapsed >= FirstFramePolicy.maxElapsed {
                finish(state.lastImage, reason: "timeout_elapsed=\(String(format: "%.2f", elapsed))s")
                return
            }

            snapshotWebView { [weak self] image in
                guard let self = self, gen == self.firstFrameSettleGeneration else { return }
                guard let image = image else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + FirstFramePolicy.pollInterval) { scheduleStep() }
                    return
                }
                state.lastImage = image
                let thumb = self.grayscaleThumb(from: image, dimension: FirstFramePolicy.thumbDimension)
                defer {
                    if let t = thumb { state.lastThumb = t }
                }
                if let prev = state.lastThumb, let curr = thumb {
                    let diff = Self.meanAbsDiffGrayscale(prev, curr)
                    if diff < FirstFramePolicy.diffThreshold, elapsed >= FirstFramePolicy.minElapsed {
                        state.stablePasses += 1
                    } else {
                        state.stablePasses = 0
                    }
                    if state.stablePasses >= FirstFramePolicy.stablePassesRequired {
                        finish(image, reason: "stable_diff=\(String(format: "%.4f", diff)) elapsed=\(String(format: "%.2f", elapsed))s")
                        return
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + FirstFramePolicy.pollInterval) { scheduleStep() }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { scheduleStep() }
    }

    private func snapshotWebView(completion: @escaping (NSImage?) -> Void) {
        guard let webView = webView else {
            completion(nil)
            return
        }
        if #available(macOS 11.0, *) {
            let config = WKSnapshotConfiguration()
            config.rect = CGRect(origin: .zero, size: webView.bounds.size)
            webView.takeSnapshot(with: config) { image, error in
                if image == nil {
                    dlog("[WebRendererBridge] snapshotWebView failed: \(error?.localizedDescription ?? "unknown")")
                }
                DispatchQueue.main.async {
                    completion(image)
                }
            }
        } else {
            DispatchQueue.main.async { [weak webView] in
                guard let webView = webView else { completion(nil); return }
                guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                                     pixelsWide: max(1, Int(webView.bounds.width)),
                                                     pixelsHigh: max(1, Int(webView.bounds.height)),
                                                     bitsPerSample: 8,
                                                     samplesPerPixel: 4,
                                                     hasAlpha: true,
                                                     isPlanar: false,
                                                     colorSpaceName: .deviceRGB,
                                                     bytesPerRow: 0,
                                                     bitsPerPixel: 0) else {
                    completion(nil)
                    return
                }
                NSGraphicsContext.saveGraphicsState()
                let ctx = NSGraphicsContext(bitmapImageRep: bitmap)
                NSGraphicsContext.current = ctx
                webView.layer?.render(in: ctx!.cgContext)
                NSGraphicsContext.restoreGraphicsState()
                let img = NSImage(size: bitmap.size)
                img.addRepresentation(bitmap)
                completion(img)
            }
        }
    }

    private func grayscaleThumb(from image: NSImage, dimension: Int) -> [UInt8]? {
        guard dimension > 0 else { return nil }
        let target = NSSize(width: dimension, height: dimension)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: dimension,
                                         pixelsHigh: dimension,
                                         bitsPerSample: 8,
                                         samplesPerPixel: 4,
                                         hasAlpha: true,
                                         isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0,
                                         bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.clear.set()
        NSRect(origin: .zero, size: target).fill()
        image.draw(in: NSRect(origin: .zero, size: target),
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .copy,
                   fraction: 1.0,
                   respectFlipped: false,
                   hints: [.interpolation: NSImageInterpolation.low])
        NSGraphicsContext.restoreGraphicsState()
        var out = [UInt8](repeating: 0, count: dimension * dimension)
        for y in 0..<dimension {
            for x in 0..<dimension {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                let g = UInt8(min(255, max(0, (c.redComponent * 0.299 + c.greenComponent * 0.587 + c.blueComponent * 0.114) * 255.0)))
                out[y * dimension + x] = g
            }
        }
        return out
    }

    private static func meanAbsDiffGrayscale(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        var sum: Int = 0
        for i in 0..<a.count {
            sum += abs(Int(a[i]) - Int(b[i]))
        }
        return Double(sum) / Double(a.count * 255)
    }

    private func startCaptureTimer() {
        captureTimer?.invalidate()
        captureTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.captureFrame()
        }
    }

    private func captureFrame(completion: ((Bool) -> Void)? = nil) {
        snapshotWebView { [weak self] image in
            guard let image = image else {
                completion?(false)
                return
            }
            let success = self?.saveImage(image) ?? false
            completion?(success)
        }
    }

    private func saveImage(_ image: NSImage) -> Bool {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return false }
        do {
            try png.write(to: URL(fileURLWithPath: PRIMARY_CAPTURE_PATH), options: .atomic)
            return true
        } catch {
            dlog("[WebRendererBridge] saveImage failed: \(error)")
            return false
        }
    }

    private func saveBitmap(_ bitmap: NSBitmapImageRep) -> Bool {
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return false }
        do {
            try png.write(to: URL(fileURLWithPath: PRIMARY_CAPTURE_PATH), options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Desktop Wallpaper Manager (MVP: C++ renderer + Web renderer)
private final class DesktopWallpaperManager {
    static let shared = DesktopWallpaperManager()

    private var currentWallpaperPath: String?
    private var isRunning = false
    private var isPaused = false
    private var isWebMode = false
    private var desktopCaptureSlot = 0
    /// scene 切换时作废尚未触发的首次截图延迟任务，避免旧 completion 与新壁纸错乱
    private var sceneLoadGeneration: UInt64 = 0

    /// Scene 首帧：不再固定等 5s；轮询直到渲染尺寸就绪、画面非黑且略稳定（或超时兜底）
    private enum SceneFirstFramePolicy {
        static let initialDelay: TimeInterval = 0.42
        static let pollInterval: TimeInterval = 0.34
        static let maxElapsed: TimeInterval = 18
        static let minRenderSize: Int = 32
        static let minElapsedBeforeCapture: TimeInterval = 0.62
        static let consecutiveNonBlackFrames: Int = 2
        /// 缩略图平均亮度，低于此视为尚未出画（黑屏/未提交 GL）
        static let minMeanLuma: Double = 0.014
        static let stableDiffThreshold: Double = 0.022
        static let stablePassesRequired: Int = 2
        /// 强动画场景可能永不「稳定」，此时在足够亮的前提下按时长兜底截图
        static let busyFallbackElapsed: TimeInterval = 4.0
    }

    private let originalWallpaperKey = "renderer_original_wallpaper_v1"
    private var captureUpdateTimer: Timer?
    private(set) var lastErrorMessage: String?

    private init() {}

    func setWallpaper(path: String, width: Int = 1920, height: Int = 1080, screen: Int? = nil, completion: ((Bool) -> Void)? = nil) {
        let path = resolveSteamWorkshopDirectoryIfNeeded(path)
        dlog("[DesktopWallpaperManager] setWallpaper path=\(path) width=\(width) height=\(height) screen=\(screen ?? -1)")

        lastErrorMessage = nil

        captureUpdateTimer?.invalidate()
        captureUpdateTimer = nil

        // 提前检测并拦截不支持的类型
        isWebMode = isWebWallpaper(path: path)
        if !isWebMode {
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

        // Save original desktop wallpaper once
        if !isRunning {
            saveOriginalWallpaper()
        }

        // 清掉旧截图与桌面用副本，切换 scene/web 时避免继续显示上一张
        try? FileManager.default.removeItem(atPath: PRIMARY_CAPTURE_PATH)
        try? FileManager.default.removeItem(atPath: DESK_CAPTURE_PATH_0)
        try? FileManager.default.removeItem(atPath: DESK_CAPTURE_PATH_1)
        desktopCaptureSlot = 0

        currentWallpaperPath = path
        isRunning = true
        isPaused = false

        if isWebMode {
            WebRendererBridge.shared.loadWallpaper(path: path, width: width, height: height, screen: screen) { [weak self] success in
                guard let self = self else { return }
                print("[DesktopWallpaperManager] Web wallpaper load result: \(success)")
                if !success {
                    self.isRunning = false
                    self.isWebMode = false
                    self.currentWallpaperPath = nil
                    self.restoreOriginalWallpaper()
                } else {
                    // 与 Scene 一致：把快照同步到系统桌面（锁屏/调度中心等），并定时刷新实现「动态壁纸」
                    self.applyCaptureAsDesktopWallpaper(screen: screen)
                    self.startPeriodicCapture(screen: screen)
                }
                NSApp.setActivationPolicy(.prohibited)
                completion?(success)
            }
            return
        }

        sceneLoadGeneration += 1
        let loadGen = sceneLoadGeneration

        RendererBridge.shared.loadWallpaper(path: path, width: width, height: height)
        if let s = screen {
            RendererBridge.shared.setScreen(s)
        }
        RendererBridge.shared.setDesktopWindow(true)
        RendererBridge.shared.showWindow()
        fixupRendererWindow(screen: screen)

        beginSceneFirstCapture(path: path, loadGen: loadGen, screen: screen, completion: completion)
    }

    /// Scene：自适应首帧截图时机（主线程；依赖 OpenGL 读回）
    private func beginSceneFirstCapture(path: String, loadGen: UInt64, screen: Int?, completion: ((Bool) -> Void)?) {
        final class SceneSettleState {
            var lastThumb: [UInt8]?
            var stablePasses = 0
            var consecutiveNonBlack = 0
        }
        let state = SceneSettleState()
        let t0 = Date()

        func complete(success: Bool) {
            guard loadGen == sceneLoadGeneration, currentWallpaperPath == path else {
                completion?(false)
                return
            }
            if success {
                print("[DesktopWallpaperManager] Scene first capture OK → \(PRIMARY_CAPTURE_PATH)")
                applyCaptureAsDesktopWallpaper(screen: screen)
                startPeriodicCapture(screen: screen)
            } else {
                isRunning = false
                isWebMode = false
                currentWallpaperPath = nil
                restoreOriginalWallpaper()
            }
            NSApp.setActivationPolicy(.prohibited)
            completion?(success)
        }

        func scheduleStep() {
            guard loadGen == sceneLoadGeneration, currentWallpaperPath == path, isRunning, !isWebMode else {
                completion?(false)
                return
            }

            let elapsed = Date().timeIntervalSince(t0)
            if elapsed >= SceneFirstFramePolicy.maxElapsed {
                let url = URL(fileURLWithPath: PRIMARY_CAPTURE_PATH)
                let ok = RendererBridge.shared.saveCapture(to: url)
                dlog("[DesktopWallpaperManager] Scene first capture timeout elapsed=\(String(format: "%.2f", elapsed))s saveOk=\(ok)")
                complete(success: ok)
                return
            }

            let rw = RendererBridge.shared.renderWidth
            let rh = RendererBridge.shared.renderHeight
            if rw < SceneFirstFramePolicy.minRenderSize || rh < SceneFirstFramePolicy.minRenderSize {
                DispatchQueue.main.asyncAfter(deadline: .now() + SceneFirstFramePolicy.pollInterval) { scheduleStep() }
                return
            }

            guard let cg = RendererBridge.shared.captureFrame(),
                  let thumb = waifuXGrayscaleThumb(from: cg, dimension: 48) else {
                DispatchQueue.main.asyncAfter(deadline: .now() + SceneFirstFramePolicy.pollInterval) { scheduleStep() }
                return
            }

            let luma = Double(thumb.reduce(0) { $0 + Int($1) }) / Double(thumb.count * 255)
            let notBlack = luma >= SceneFirstFramePolicy.minMeanLuma
            if notBlack {
                state.consecutiveNonBlack += 1
            } else {
                state.consecutiveNonBlack = 0
            }

            if let prev = state.lastThumb, elapsed >= SceneFirstFramePolicy.minElapsedBeforeCapture {
                let diff = waifuXMeanAbsDiffGrayscale(prev, thumb)
                if diff < SceneFirstFramePolicy.stableDiffThreshold, notBlack {
                    state.stablePasses += 1
                } else {
                    state.stablePasses = 0
                }
            }
            state.lastThumb = thumb

            let url = URL(fileURLWithPath: PRIMARY_CAPTURE_PATH)
            var shouldSave = false
            if state.stablePasses >= SceneFirstFramePolicy.stablePassesRequired, notBlack {
                shouldSave = true
                dlog("[DesktopWallpaperManager] Scene first capture: stable (diff settled) elapsed=\(String(format: "%.2f", elapsed))s")
            } else if state.consecutiveNonBlack >= SceneFirstFramePolicy.consecutiveNonBlackFrames,
                      elapsed >= SceneFirstFramePolicy.minElapsedBeforeCapture, notBlack {
                shouldSave = true
                dlog("[DesktopWallpaperManager] Scene first capture: consecutive non-black elapsed=\(String(format: "%.2f", elapsed))s")
            } else if notBlack, elapsed >= SceneFirstFramePolicy.busyFallbackElapsed {
                shouldSave = true
                dlog("[DesktopWallpaperManager] Scene first capture: busy fallback elapsed=\(String(format: "%.2f", elapsed))s")
            }

            if shouldSave {
                if RendererBridge.shared.saveCapture(to: url) {
                    complete(success: true)
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + SceneFirstFramePolicy.pollInterval) { scheduleStep() }
                }
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + SceneFirstFramePolicy.pollInterval) { scheduleStep() }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + SceneFirstFramePolicy.initialDelay) { scheduleStep() }
    }

    func pauseWallpaper() {
        guard isRunning, !isPaused else { return }
        if isWebMode {
            WebRendererBridge.shared.pause()
        } else {
            RendererBridge.shared.pauseSceneRendering()
        }
        isPaused = true
    }

    func resumeWallpaper() {
        guard isRunning, isPaused else { return }
        if isWebMode {
            WebRendererBridge.shared.resume()
        } else {
            RendererBridge.shared.resumeSceneRendering()
            fixupRendererWindow()
        }
        isPaused = false
    }

    func stopWallpaper() {
        captureUpdateTimer?.invalidate()
        captureUpdateTimer = nil
        if isWebMode {
            WebRendererBridge.shared.stop()
        } else {
            RendererBridge.shared.stop()
            RendererBridge.shared.hideWindow()
            RendererBridge.shared.destroy()
        }
        isWebMode = false
        try? FileManager.default.removeItem(atPath: PRIMARY_CAPTURE_PATH)
        try? FileManager.default.removeItem(atPath: DESK_CAPTURE_PATH_0)
        try? FileManager.default.removeItem(atPath: DESK_CAPTURE_PATH_1)
        currentWallpaperPath = nil
        isRunning = false
        isPaused = false
        restoreOriginalWallpaper()
    }

    // MARK: - Desktop Wallpaper Capture Updates

    /// 将主截图复制到交替路径再设为桌面图，避免系统因固定路径缓存上一张壁纸（锁屏/静态桌面不更新）
    private func applyCaptureAsDesktopWallpaper(screen: Int? = nil) {
        guard FileManager.default.fileExists(atPath: PRIMARY_CAPTURE_PATH) else { return }
        let src = URL(fileURLWithPath: PRIMARY_CAPTURE_PATH)
        desktopCaptureSlot = 1 - desktopCaptureSlot
        let dstPath = desktopCaptureSlot == 0 ? DESK_CAPTURE_PATH_0 : DESK_CAPTURE_PATH_1
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
        let targetScreens: [NSScreen]
        if let s = screen, s >= 0, s < screens.count {
            targetScreens = [screens[s]]
        } else {
            targetScreens = screens
        }

        for targetScreen in targetScreens {
            do {
                try workspace.setDesktopImageURLForAllSpaces(dst, for: targetScreen, options: [
                    .imageScaling: NSNumber(value: NSImageScaling.scaleProportionallyUpOrDown.rawValue)
                ])
            } catch {
                print("[DesktopWallpaperManager] Failed to set desktop image: \(error)")
            }
        }
        dlog("[DesktopWallpaperManager] Applied capture as desktop wallpaper for \(targetScreens.count) screen(s) via \(dstPath)")
    }

    /// Periodically re-capture and update desktop wallpaper to reflect animation
    private func startPeriodicCapture(screen: Int? = nil) {
        captureUpdateTimer?.invalidate()
        // 使用 500ms 间隔（2fps）在性能与流畅度之间取得平衡
        // 注意：saveCapture 依赖 OpenGL 上下文，必须在主线程执行
        captureUpdateTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self, self.isRunning, !self.isPaused else { return }
            if self.isWebMode {
                // Web：由 WebRendererBridge 定时写入主截图文件，这里只负责推到系统桌面
                guard FileManager.default.fileExists(atPath: PRIMARY_CAPTURE_PATH) else { return }
                self.applyCaptureAsDesktopWallpaper(screen: screen)
            } else {
                let url = URL(fileURLWithPath: PRIMARY_CAPTURE_PATH)
                let success = RendererBridge.shared.saveCapture(to: url)
                guard success else { return }
                self.applyCaptureAsDesktopWallpaper(screen: screen)
            }
        }
    }

    // MARK: - Renderer Window Fixup
    // C++ renderer 创建的窗口可能缺少桌面壁纸所需的 NSWindow 属性，这里手动补齐。
    private var fixupTimer: Timer?
    private func fixupRendererWindow(screen: Int? = nil) {
        fixupTimer?.invalidate()
        let screens = NSScreen.screens
        let targetScreen: NSScreen
        if let s = screen, s >= 0, s < screens.count {
            targetScreen = screens[s]
        } else if let main = NSScreen.main {
            targetScreen = main
        } else {
            return
        }

        // 记录已处理的窗口避免重复日志刷屏
        var processedIDs = Set<Int>()

        func applyFixup() {
            for window in NSApp.windows {
                let area = window.frame.width * window.frame.height
                // renderer 窗口通常 > 100x100 且不是 our own tiny windows
                guard area > 100*100 else { continue }

                let id = window.hashValue
                if !processedIDs.contains(id) {
                    processedIDs.insert(id)
                    print("[DesktopWallpaperManager] Found candidate window: \(window.className) frame=\(window.frame) title='\(window.title ?? "")'")
                }

                let desktopLevel = CGWindowLevelForKey(.desktopWindow)
                if window.level.rawValue != Int(desktopLevel) {
                    window.level = .init(rawValue: Int(desktopLevel))
                }
                window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
                window.isOpaque = true
                window.backgroundColor = .black
                if window.frame != targetScreen.frame {
                    window.setFrame(targetScreen.frame, display: true)
                }
                window.orderBack(nil)

                // 尝试把 window 的 contentView 背景也弄成黑色
                if let contentView = window.contentView {
                    contentView.wantsLayer = true
                    contentView.layer?.backgroundColor = NSColor.black.cgColor
                }

                // 遍历 subviews 找 NSOpenGLView 并设背景
                for subview in window.contentView?.subviews ?? [] {
                    let className = String(describing: type(of: subview))
                    if className.contains("OpenGL") || className.contains("GLView") {
                        subview.wantsLayer = true
                        subview.layer?.backgroundColor = NSColor.black.cgColor
                        print("[DesktopWallpaperManager] Patched OpenGL view background to black: \(className)")
                    }
                }
            }
        }

        applyFixup()
        fixupTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { t in
            applyFixup()
            // 2 秒后停止
            if t.fireDate.timeIntervalSinceNow < -2.0 {
                t.invalidate()
                self.fixupTimer = nil
            }
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
        var payload = Data(bytes: &length, count: MemoryLayout<UInt32>.size) + data
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

        let size = MemoryLayout<sockaddr_un>.size
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(size))
            }
        }
        guard connected == 0 else { return "Daemon not responding" }

        guard let data = try? JSONEncoder().encode(message) else { return "Encode failed" }
        var length = UInt32(data.count)
        var payload = Data(bytes: &length, count: MemoryLayout<UInt32>.size) + data
        let sent = payload.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, payload.count, 0) }
        guard sent == payload.count else { return "Send failed" }

        var responseBuf = Data(repeating: 0, count: 1024)
        let received = responseBuf.withUnsafeMutableBytes { recv(fd, $0.baseAddress, 1024, 0) }
        guard received > 0 else { return nil }
        return String(data: responseBuf.prefix(received), encoding: .utf8)
    }
}

// MARK: - Daemon
private final class Daemon: NSObject, NSApplicationDelegate {
    static let shared = Daemon()
    private var serverSocket: Int32 = -1

    func applicationDidFinishLaunching(_ notification: Notification) {
        writePID(getpid())
        removeSocket()
        // Re-enforce no-dock-icon policy after NSApplication run loop starts
        NSApp.setActivationPolicy(.prohibited)
        startServer()
        startProhibitionTimer()
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

    func applicationWillTerminate(_ notification: Notification) {
        prohibitionTimer?.invalidate()
        prohibitionTimer = nil
        DesktopWallpaperManager.shared.stopWallpaper()
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
                                sendResponse("ERROR:壁纸渲染失败，请尝试其他壁纸")
                            }
                        }
                    } else {
                        sendResponse("NO_PATH")
                    }
                case .pause:
                    DesktopWallpaperManager.shared.pauseWallpaper()
                    sendResponse("OK")
                case .resume:
                    DesktopWallpaperManager.shared.resumeWallpaper()
                    sendResponse("OK")
                case .stop:
                    DesktopWallpaperManager.shared.stopWallpaper()
                    sendResponse("OK")
                }
            }
        }
    }
}

// MARK: - Offline scene bake（独立进程，不经 daemon；输出 H.264 MP4 循环片）

private enum SceneOfflineBakeError: Error, LocalizedError {
    case invalidArguments
    case scenePathNotDirectory
    case loadFailed
    case captureFailed
    case writerFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments: return "Invalid bake arguments"
        case .scenePathNotDirectory: return "Scene path must be a directory with project.json"
        case .loadFailed: return "Renderer failed to load scene"
        case .captureFailed: return "Frame capture failed"
        case .writerFailed(let s): return s
        }
    }
}

private struct SceneOfflineBakeConfig {
    let sceneRoot: String
    let outputURL: URL
    let width: Int
    let height: Int
    let fps: Int32
    let durationSeconds: Double
}

private func sceneBakeParseConfig(_ arguments: [String]) throws -> SceneOfflineBakeConfig {
    guard arguments.count >= 2 else { throw SceneOfflineBakeError.invalidArguments }
    let root = arguments[0]
    let outPath = arguments[1]
    var w = 1920
    var h = 1080
    var fps: Int32 = 30
    var seconds = 8.0
    if arguments.count >= 6 {
        w = max(32, Int(arguments[2]) ?? 1920)
        h = max(32, Int(arguments[3]) ?? 1080)
        fps = Int32(max(1, min(60, Int(arguments[4]) ?? 30)))
        seconds = max(0.5, Double(arguments[5]) ?? 8.0)
    }
    w = (w / 2) * 2
    h = (h / 2) * 2
    return SceneOfflineBakeConfig(
        sceneRoot: root,
        outputURL: URL(fileURLWithPath: outPath),
        width: w,
        height: h,
        fps: fps,
        durationSeconds: seconds
    )
}

private func sceneBakePixelBuffer(from image: CGImage) throws -> CVPixelBuffer {
    let width = image.width
    let height = image.height
    var buffer: CVPixelBuffer?
    let attrs: [CFString: Any] = [
        kCVPixelBufferCGImageCompatibilityKey: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey: true
    ]
    guard CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        attrs as CFDictionary,
        &buffer
    ) == kCVReturnSuccess,
        let px = buffer else {
        throw SceneOfflineBakeError.writerFailed("CVPixelBufferCreate failed")
    }
    CVPixelBufferLockBaseAddress(px, [])
    defer { CVPixelBufferUnlockBaseAddress(px, []) }
    guard let base = CVPixelBufferGetBaseAddress(px) else {
        throw SceneOfflineBakeError.writerFailed("pixel buffer base address nil")
    }
    let rowBytes = CVPixelBufferGetBytesPerRow(px)
    guard let ctx = CGContext(
        data: base,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: rowBytes,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    ) else {
        throw SceneOfflineBakeError.writerFailed("CGContext failed")
    }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return px
}

/// GLFW/Cocoa 后端要求 `glfwDestroyWindow`、事件轮询等发生在主线程；`sceneBakePerform` 在后台队列执行以避免
/// `AVAssetWriter.finishWriting` 与主线程 `semaphore.wait` 死锁，故此处将渲染器调用派回主线程。
private func sceneBakeOnMain<T>(_ work: () throws -> T) rethrows -> T {
    if Thread.isMainThread {
        return try work()
    }
    return try DispatchQueue.main.sync(execute: work)
}

private func sceneBakePerform(_ cfg: SceneOfflineBakeConfig) throws {
    let sceneRoot = resolveSteamWorkshopDirectoryIfNeeded(cfg.sceneRoot)

    if let validationError = validateSceneParentGraph(sceneRoot: sceneRoot) {
        throw SceneOfflineBakeError.writerFailed("Scene validation failed: \(validationError)")
    }

    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: sceneRoot, isDirectory: &isDir),
          isDir.boolValue,
          FileManager.default.fileExists(atPath: URL(fileURLWithPath: sceneRoot).appendingPathComponent("project.json").path) else {
        throw SceneOfflineBakeError.scenePathNotDirectory
    }

    if FileManager.default.fileExists(atPath: cfg.outputURL.path) {
        try FileManager.default.removeItem(at: cfg.outputURL)
    }

    sceneBakeOnMain {
        RendererBridge.shared.destroy()
        RendererBridge.shared.loadWallpaper(path: sceneRoot, width: cfg.width, height: cfg.height, autoStartTicking: false)
        RendererBridge.shared.setDesktopWindow(false)
        RendererBridge.shared.hideWindow()
    }

    let rw = sceneBakeOnMain { RendererBridge.shared.renderWidth }
    let rh = sceneBakeOnMain { RendererBridge.shared.renderHeight }
    guard rw > 0, rh > 0 else {
        sceneBakeOnMain { RendererBridge.shared.destroy() }
        throw SceneOfflineBakeError.loadFailed
    }

    for _ in 0 ..< 120 {
        let ok: Bool = autoreleasepool {
            sceneBakeOnMain { RendererBridge.shared.tickOnce() }
        }
        if !ok {
            sceneBakeOnMain { RendererBridge.shared.destroy() }
            throw SceneOfflineBakeError.loadFailed
        }
    }

    let frameCount = max(1, Int(Double(cfg.fps) * cfg.durationSeconds))
    let outSettings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: rw,
        AVVideoHeightKey: rh,
        AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: rw * rh * 3,
            AVVideoExpectedSourceFrameRateKey: cfg.fps,
            AVVideoMaxKeyFrameIntervalKey: Int(cfg.fps) * 2
        ] as [String: Any]
    ]
    let writer = try AVAssetWriter(outputURL: cfg.outputURL, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: outSettings)
    input.expectsMediaDataInRealTime = false
    let sourceAttrs: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
        kCVPixelBufferWidthKey as String: rw,
        kCVPixelBufferHeightKey as String: rh
    ]
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: sourceAttrs)
    guard writer.canAdd(input) else {
        sceneBakeOnMain { RendererBridge.shared.destroy() }
        throw SceneOfflineBakeError.writerFailed("cannot add video input")
    }
    writer.add(input)
    guard writer.startWriting() else {
        sceneBakeOnMain { RendererBridge.shared.destroy() }
        throw SceneOfflineBakeError.writerFailed(writer.error?.localizedDescription ?? "startWriting failed")
    }
    writer.startSession(atSourceTime: .zero)

    for i in 0 ..< frameCount {
        try autoreleasepool {
            if !sceneBakeOnMain({ RendererBridge.shared.tickOnce() }) {
                input.markAsFinished()
                writer.cancelWriting()
                sceneBakeOnMain { RendererBridge.shared.destroy() }
                throw SceneOfflineBakeError.captureFailed
            }
            guard let cg = sceneBakeOnMain({ RendererBridge.shared.captureFrame() }) else {
                input.markAsFinished()
                writer.cancelWriting()
                sceneBakeOnMain { RendererBridge.shared.destroy() }
                throw SceneOfflineBakeError.captureFailed
            }
            let pb = try sceneBakePixelBuffer(from: cg)
            let pts = CMTime(value: Int64(i), timescale: cfg.fps)
            var wait = 0
            while !input.isReadyForMoreMediaData, wait < 6000 {
                usleep(500)
                wait += 1
            }
            guard input.isReadyForMoreMediaData else {
                input.markAsFinished()
                writer.cancelWriting()
                sceneBakeOnMain { RendererBridge.shared.destroy() }
                throw SceneOfflineBakeError.writerFailed("writer not ready")
            }
            if !adaptor.append(pb, withPresentationTime: pts) {
                input.markAsFinished()
                writer.cancelWriting()
                sceneBakeOnMain { RendererBridge.shared.destroy() }
                throw SceneOfflineBakeError.writerFailed(writer.error?.localizedDescription ?? "append failed")
            }
        }
    }

    input.markAsFinished()
    let sem = DispatchSemaphore(value: 0)
    var finishErr: Error?
    writer.finishWriting {
        if writer.status == .failed {
            finishErr = writer.error
        }
        sem.signal()
    }
    sem.wait()
    sceneBakeOnMain { RendererBridge.shared.destroy() }
    if let finishErr {
        throw SceneOfflineBakeError.writerFailed(finishErr.localizedDescription)
    }
    guard writer.status == .completed else {
        throw SceneOfflineBakeError.writerFailed("writer status \(writer.status.rawValue)")
    }
}

private final class SceneOfflineBakeAppDelegate: NSObject, NSApplicationDelegate {
    let arguments: [String]

    init(arguments: [String]) {
        self.arguments = arguments
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 不得在主线程同步跑 sceneBakePerform：`AVAssetWriter.finishWriting` 的 completion 常派回主队列，
        // 与主线程上的 `DispatchSemaphore.wait` 会形成死锁，表现为烘焙卡住、需点击 Dock 才继续。
        let args = arguments
        DispatchQueue.global(qos: .userInitiated).async {
            var code: Int32 = 1
            defer {
                sceneOfflineBakeExitCode = code
                // 结束 AppKit run loop：`stop` 只设标志位，不会立即返回；
                // 必须再 post 一个虚拟 NSEvent 强制 `nextEventMatchingMask` 返回，
                // 否则 run loop 会永远卡在等待事件上。
                let stopBlock = {
                    NSApp.stop(nil)
                    if let ev = NSEvent.otherEvent(
                        with: .applicationDefined,
                        location: .zero,
                        modifierFlags: [],
                        timestamp: 0,
                        windowNumber: 0,
                        context: nil,
                        subtype: 0,
                        data1: 0,
                        data2: 0
                    ) {
                        NSApp.postEvent(ev, atStart: true)
                    }
                }
                if Thread.isMainThread {
                    stopBlock()
                } else {
                    let rl = CFRunLoopGetMain()
                    CFRunLoopPerformBlock(rl, CFRunLoopMode.commonModes.rawValue as CFString, stopBlock)
                    CFRunLoopWakeUp(rl)
                }
            }
            do {
                let cfg = try sceneBakeParseConfig(args)
                fputs(
                    "[bake] \(cfg.sceneRoot) → \(cfg.outputURL.path) \(cfg.width)x\(cfg.height) @\(cfg.fps)fps \(cfg.durationSeconds)s\n",
                    stderr
                )
                try sceneBakePerform(cfg)
                print(cfg.outputURL.path)
                fflush(stdout)
                code = 0
            } catch {
                fputs("Bake failed: \(error.localizedDescription)\n", stderr)
                fflush(stderr)
                code = 1
            }
        }
    }
}

/// `NSApplication.delegate` 为 weak，需强引用至 `run()` 结束
private final class SceneOfflineBakeDelegateBox {
    let delegate: SceneOfflineBakeAppDelegate
    init(arguments: [String]) {
        delegate = SceneOfflineBakeAppDelegate(arguments: arguments)
    }
}

private var sceneOfflineBakeDelegateBox: SceneOfflineBakeDelegateBox?

/// bake 子进程退出码；用 `NSApp.stop` 结束 run loop 后再退出。
private var sceneOfflineBakeExitCode: Int32 = 1

private func sceneOfflineBakeRunStandalone(arguments: [String]) -> Never {
    sceneOfflineBakeExitCode = 1
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let box = SceneOfflineBakeDelegateBox(arguments: arguments)
    sceneOfflineBakeDelegateBox = box
    app.delegate = box.delegate
    app.run()
    fflush(stdout)
    fflush(stderr)
    // 必须用 `_exit`：`exit(3)` 会跑 C++ 静态析构，glslang 在 FinalizeProcess 里对全局 mutex 加锁，
    // 与 AppKit 子线程同时收尾时会在 libc++ 里抛 system_error → abort（见 bake 成功后的崩溃栈）。
    _exit(sceneOfflineBakeExitCode)
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
        let args = Array(allArgs.dropFirst())
        let remainingArgs = args

        guard let command = remainingArgs.first else {
            printUsage()
            exit(1)
        }

        if command == "bake" {
            let bakeArgs = Array(remainingArgs.dropFirst())
            guard bakeArgs.count >= 2 else {
                print("Usage: wallpaperengine-cli bake <scene_dir> <out.mp4> [width height fps seconds]")
                exit(1)
            }
            sceneOfflineBakeRunStandalone(arguments: bakeArgs)
        }

        switch command {
        case "set", "pause", "resume", "stop", "exit":

            // 总是先清理旧 daemon 并启动新版本，避免旧版本残留导致行为不一致
            stopDaemonIfRunning()
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
            case "pause":
                msg = IPCMessage(command: .pause, path: nil, screen: nil)
            case "resume":
                msg = IPCMessage(command: .resume, path: nil, screen: nil)
            case "stop", "exit":
                msg = IPCMessage(command: .stop, path: nil, screen: nil)
            default:
                print("Unknown command: \(command)")
                exit(1)
            }

            if let err = Client.sendAndWaitForOK(msg) {
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
        // 防御性阻止 C++ renderer 或其窗口框架改变 activation policy 或抢焦点
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

        // 确保 daemon 能找到 liblinux-wallpaperengine-renderer.dylib
        // dylib 可能与可执行文件同级或在 Resources/ 子目录
        let execDir = URL(fileURLWithPath: executable).deletingLastPathComponent()
        let dylibCandidates = [
            execDir.path,                                           // @executable_path
            execDir.appendingPathComponent("Resources").path,       // @executable_path/Resources
            execDir.appendingPathComponent("../Frameworks").path,   // @executable_path/../Frameworks (app bundle)
        ]
        var libPaths: [String] = []
        if let existing = env["DYLD_LIBRARY_PATH"] {
            libPaths.append(existing)
        }
        for candidate in dylibCandidates {
            let dylibPath = candidate + "/liblinux-wallpaperengine-renderer.dylib"
            if FileManager.default.fileExists(atPath: dylibPath) {
                libPaths.append(candidate)
            }
        }
        if !libPaths.isEmpty {
            env["DYLD_LIBRARY_PATH"] = libPaths.joined(separator: ":")
        }

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
          bake <dir> <out.mp4> [w h fps sec]   Offline H.264 bake (no daemon)
        """)
    }
}
