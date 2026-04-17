import Foundation
import AppKit
import IOKit
import CryptoKit
import WebKit
import CRenderer

// MARK: - Constants
private let SOCKET_PATH = "/tmp/wallpaperengine-cli.sock"
private let PID_PATH = "/tmp/wallpaperengine-cli.pid"
private let DEBUG_LOG_PATH = "/tmp/wallpaperengine-cli-debug.log"

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
    private var tickSource: DispatchSourceTimer?
    private let tickQueue = DispatchQueue(label: "com.wallpaperenginex.renderer.tick", qos: .userInitiated)
    private let rendererLock = NSLock()
    private var isLoaded = false
    private var lastAssetsPath: String? = nil

    private init() {}

    private func defaultAssetsPath() -> String {
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

    func loadWallpaper(path: String, width: Int, height: Int) {
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
        if !assets.isEmpty {
            handle = lw_renderer_create_with_assets(assets)
        } else {
            handle = lw_renderer_create()
        }

        guard let h = handle else {
            rendererLock.unlock()
            return
        }
        lw_renderer_load(h, path, Int32(width), Int32(height))
        isLoaded = true
        rendererLock.unlock()
        startTicking()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self = self else { return }
            let w = self.renderWidth
            let h = self.renderHeight
            if w <= 0 || h <= 0 {
                dlog("[RendererBridge] ERROR: Wallpaper load failed for \(path). Render size is \(w)x\(h).")
            }
        }
    }

    func startTicking(fps: Double = 30.0) {
        cancelTickTimer()
        _ = drainTickQueue(timeout: 2.0)

        let source = DispatchSource.makeTimerSource(queue: tickQueue)
        source.schedule(deadline: .now(), repeating: 1.0 / fps, leeway: .milliseconds(1))
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.rendererLock.lock()
            guard let h = self.handle else {
                self.rendererLock.unlock()
                return
            }
            lw_renderer_tick(h)
            if lw_renderer_close_requested(h) != 0 {
                self.rendererLock.unlock()
                self.cancelTickTimer()
                self.rendererLock.lock()
                lw_renderer_hide_window(h)
                self.isLoaded = false
            }
            self.rendererLock.unlock()
        }
        source.resume()
        tickSource = source
    }

    func stop() {
        cancelTickTimer()
        _ = drainTickQueue(timeout: 2.0)
    }

    private func cancelTickTimer() {
        tickSource?.cancel()
        tickSource = nil
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

private func resolveWebWallpaperEntry(path: String) -> (baseURL: URL, indexFile: String)? {
    let url = URL(fileURLWithPath: path)
    var contentDir = url
    if url.pathExtension.lowercased() == "pkg" {
        guard let extracted = extractPKG(at: url) else { return nil }
        contentDir = extracted
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

// MARK: - Web Renderer Bridge (WKWebView-based HTML wallpaper)
private final class WebRendererBridge: NSObject, WKNavigationDelegate {
    static let shared = WebRendererBridge()

    private var window: NSWindow?
    private var webView: WKWebView?
    private var captureTimer: Timer?
    private var pendingCompletion: ((Bool) -> Void)?
    private var extractedPKGDir: URL?
    private(set) var isLoaded = false
    private let capturePath = "/tmp/wallpaperengine-cli-capture.png"

    func loadWallpaper(path: String, width: Int, height: Int, screen: Int? = nil, completion: ((Bool) -> Void)? = nil) {
        stop() // 清理旧的（包括临时目录）
        pendingCompletion = completion

        guard let (baseURL, indexFile) = resolveWebWallpaperEntry(path: path) else {
            dlog("[WebRendererBridge] Failed to resolve web wallpaper entry for \(path)")
            completion?(false)
            return
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
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false

        // 配置 WKWebView
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptEnabled = true
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

        w.contentView?.addSubview(web)

        self.window = w
        self.webView = web

        let fileURL = baseURL.appendingPathComponent(indexFile)
        web.loadFileURL(fileURL, allowingReadAccessTo: baseURL)
        w.orderBack(nil)

        dlog("[WebRendererBridge] Loading web wallpaper: \(fileURL.path) on screen \(targetScreen.localizedName)")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        dlog("[WebRendererBridge] didFinish")
        isLoaded = true
        // 首帧截图存 capture
        captureFrame { [weak self] success in
            self?.pendingCompletion?(success)
            self?.pendingCompletion = nil
        }
        // 之后定时截图（锁屏/静态桌面能看到更新）
        startCaptureTimer()
        NSApp.setActivationPolicy(.prohibited)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        dlog("[WebRendererBridge] didFail: \(error)")
        pendingCompletion?(false)
        pendingCompletion = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        dlog("[WebRendererBridge] didFailProvisional: \(error)")
        pendingCompletion?(false)
        pendingCompletion = nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        dlog("[WebRendererBridge] WebContent process terminated")
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
        """) { _, _ in }
        startCaptureTimer()
        NSApp.setActivationPolicy(.prohibited)
    }

    func stop() {
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
    }

    private func startCaptureTimer() {
        captureTimer?.invalidate()
        captureTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.captureFrame()
        }
    }

    private func captureFrame(completion: ((Bool) -> Void)? = nil) {
        guard let webView = webView else { completion?(false); return }

        if #available(macOS 11.0, *) {
            let config = WKSnapshotConfiguration()
            config.rect = CGRect(origin: .zero, size: webView.bounds.size)
            webView.takeSnapshot(with: config) { [weak self] image, error in
                guard let image = image else {
                    dlog("[WebRendererBridge] takeSnapshot failed: \(error?.localizedDescription ?? "unknown")")
                    completion?(false)
                    return
                }
                let success = self?.saveImage(image) ?? false
                completion?(success)
            }
        } else {
            // fallback for macOS 10.x
            DispatchQueue.main.async { [weak self] in
                guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                                     pixelsWide: Int(webView.bounds.width),
                                                     pixelsHigh: Int(webView.bounds.height),
                                                     bitsPerSample: 8,
                                                     samplesPerPixel: 4,
                                                     hasAlpha: true,
                                                     isPlanar: false,
                                                     colorSpaceName: .deviceRGB,
                                                     bytesPerRow: 0,
                                                     bitsPerPixel: 0) else {
                    completion?(false)
                    return
                }
                NSGraphicsContext.saveGraphicsState()
                let ctx = NSGraphicsContext(bitmapImageRep: bitmap)
                NSGraphicsContext.current = ctx
                webView.layer?.render(in: ctx!.cgContext)
                NSGraphicsContext.restoreGraphicsState()
                let success = self?.saveBitmap(bitmap) ?? false
                completion?(success)
            }
        }
    }

    private func saveImage(_ image: NSImage) -> Bool {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return false }
        do {
            try png.write(to: URL(fileURLWithPath: capturePath), options: .atomic)
            return true
        } catch {
            dlog("[WebRendererBridge] saveImage failed: \(error)")
            return false
        }
    }

    private func saveBitmap(_ bitmap: NSBitmapImageRep) -> Bool {
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return false }
        do {
            try png.write(to: URL(fileURLWithPath: capturePath), options: .atomic)
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
    private let capturePath = "/tmp/wallpaperengine-cli-capture.png"
    private let originalWallpaperKey = "renderer_original_wallpaper_v1"
    private var captureUpdateTimer: Timer?
    private(set) var lastErrorMessage: String?

    private init() {}

    func setWallpaper(path: String, width: Int = 1920, height: Int = 1080, screen: Int? = nil, completion: ((Bool) -> Void)? = nil) {
        dlog("[DesktopWallpaperManager] setWallpaper path=\(path) width=\(width) height=\(height) screen=\(screen ?? -1)")

        lastErrorMessage = nil

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

        // Remove stale capture
        try? FileManager.default.removeItem(atPath: capturePath)

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
                }
                NSApp.setActivationPolicy(.prohibited)
                completion?(success)
            }
            return
        }

        RendererBridge.shared.loadWallpaper(path: path, width: width, height: height)
        if let s = screen {
            RendererBridge.shared.setScreen(s)
        }
        RendererBridge.shared.setDesktopWindow(true)
        RendererBridge.shared.showWindow()
        fixupRendererWindow(screen: screen)

        // Capture frame after renderer has ticked a few times
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard let self = self, self.currentWallpaperPath == path else {
                completion?(false)
                return
            }
            let url = URL(fileURLWithPath: self.capturePath)
            let success = RendererBridge.shared.saveCapture(to: url)
            print("[DesktopWallpaperManager] Capture saved to \(self.capturePath): \(success)")
            if !success {
                self.isRunning = false
                self.isWebMode = false
                self.currentWallpaperPath = nil
                self.restoreOriginalWallpaper()
            }
            // Set capture as desktop wallpaper so it's visible on lock screen / mission control
            if success {
                self.applyCaptureAsDesktopWallpaper(screen: screen)
                self.startPeriodicCapture(screen: screen)
            }
            // Re-enforce hidden dock icon after window creation
            NSApp.setActivationPolicy(.prohibited)
            completion?(success)
        }
    }

    func pauseWallpaper() {
        guard isRunning, !isPaused else { return }
        if isWebMode {
            WebRendererBridge.shared.pause()
        } else {
            RendererBridge.shared.stop()
            RendererBridge.shared.hideWindow()
        }
        isPaused = true
    }

    func resumeWallpaper() {
        guard isRunning, isPaused else { return }
        if isWebMode {
            WebRendererBridge.shared.resume()
        } else {
            RendererBridge.shared.showWindow()
            RendererBridge.shared.startTicking()
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
        try? FileManager.default.removeItem(atPath: capturePath)
        currentWallpaperPath = nil
        isRunning = false
        isPaused = false
        restoreOriginalWallpaper()
    }

    // MARK: - Desktop Wallpaper Capture Updates

    /// Set the captured frame as the macOS desktop wallpaper
    private func applyCaptureAsDesktopWallpaper(screen: Int? = nil) {
        let captureURL = URL(fileURLWithPath: capturePath)
        guard FileManager.default.fileExists(atPath: capturePath) else { return }

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
                try workspace.setDesktopImageURL(captureURL, for: targetScreen, options: [
                    .imageScaling: NSNumber(value: NSImageScaling.scaleProportionallyUpOrDown.rawValue)
                ])
            } catch {
                print("[DesktopWallpaperManager] Failed to set desktop image: \(error)")
            }
        }
        dlog("[DesktopWallpaperManager] Applied capture as desktop wallpaper for \(targetScreens.count) screen(s)")
    }

    /// Periodically re-capture and update desktop wallpaper to reflect animation
    private func startPeriodicCapture(screen: Int? = nil) {
        captureUpdateTimer?.invalidate()
        // 使用 500ms 间隔（2fps）在性能与流畅度之间取得平衡
        // 注意：saveCapture 依赖 OpenGL 上下文，必须在主线程执行
        captureUpdateTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self, self.isRunning, !self.isPaused, !self.isWebMode else { return }
            let url = URL(fileURLWithPath: self.capturePath)
            let success = RendererBridge.shared.saveCapture(to: url)
            guard success else { return }
            self.applyCaptureAsDesktopWallpaper(screen: screen)
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
                    try workspace.setDesktopImageURL(originalURL, for: screen, options: [:])
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
                    try workspace.setDesktopImageURL(mainURL, for: screen, options: [:])
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
                            try workspace.setDesktopImageURL(url, for: screen, options: [:])
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
        """)
    }
}
