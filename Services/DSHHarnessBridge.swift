import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// DeepSeek Harness（DSH）「页面背景」推送桥。
///
/// 背景状态的权威副本由 DSH 的 `dsh-theme-manager` 插件持有
/// （`$DSH_HOME/state/theme-manager/background.json`），并对外暴露一组
/// **免 token 的本机 HTTP 接口**（插件注册的 prefix 路由不在 host 鉴权网关后面）：
///
///   GET  /dsh-theme-manager/health            探活 + 端点清单
///   GET  /dsh-theme-manager/state             当前背景状态
///   POST /dsh-theme-manager/background        设置背景（支持部分字段更新）
///   POST /dsh-theme-manager/background/clear  恢复「无背景」
///
/// 桌面版启动参数里固定 `--port 19387`（`dsh-desktop-host` 里的
/// `args: ["--no-open", "--port", "19387"]`），所以端口默认取 19387；
/// 需要改端口时 `defaults write com.waifux.app dsh_harness_port <port>`。
///
/// 媒体只能是**绝对路径的普通文件**、且扩展名落在 DSH 侧白名单里
/// （图片 jpg/jpeg/png/webp/gif/avif/bmp；视频 mp4/m4v/webm/ogv/ogg/mov）。
/// 不在白名单里的图片（heic/tiff）会先转成 JPEG 落到缓存目录再推送。
@MainActor
final class DSHHarnessBridge: ObservableObject {

    static let shared = DSHHarnessBridge()

    // MARK: - 常量

    /// DSH 桌面端 bundle id（`/Applications/DeepSeek Harness.app`）。
    nonisolated static let bundleIdentifier = "com.deepseek.dsh"
    /// 桌面版 `dsh-desktop-host` 硬编码的 web 端口。
    nonisolated static let desktopDefaultPort = 19387
    /// 覆盖端口用的 UserDefaults 键。
    nonisolated static let portOverrideKey = "dsh_harness_port"
    /// 推送时标记来源，DSH 侧会把它记进 `updatedBy`（设置页能看到是谁改的）。
    nonisolated static let sourceHeader = "x-dsh-theme-source"
    nonisolated static let sourceName = "WaifuX"

    /// DSH 侧白名单：图片扩展名（原样可推）。
    nonisolated static let pushableImageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "avif", "bmp"]
    /// 本机可解码但 DSH 不收的图片扩展名，推送前转 JPEG。
    nonisolated static let convertibleImageExtensions: Set<String> = ["heic", "heif", "tiff", "tif"]
    /// DSH 侧白名单：视频扩展名。
    nonisolated static let pushableVideoExtensions: Set<String> = ["mp4", "m4v", "webm", "ogv", "ogg", "mov"]

    /// 背景「透出范围」：base=只透明页面底板 / panels=侧栏与会话区一起 / full=连输入框。
    enum Coverage: String {
        case base
        case panels
        case full
    }

    /// 推送默认值：与 DSH 设置页手改后的观感一致（侧栏与会话区透出 + 轻度压暗）。
    nonisolated static let defaultCoverage: Coverage = .panels
    nonisolated static let defaultDim: Double = 0.35
    nonisolated static let defaultVideoLoop = true
    nonisolated static let defaultVideoMuted = true
    nonisolated static let defaultVideoRate: Double = 1.0

    /// 可用性缓存有效期（秒）。
    nonisolated private static let availabilityTTL: TimeInterval = 20

    // MARK: - 类型

    enum Availability: Equatable, Codable, Sendable {
        case unknown
        case available(port: Int, version: String)
        case unavailable

        var isAvailable: Bool {
            if case .available = self { return true }
            return false
        }

        var port: Int? {
            if case .available(let port, _) = self { return port }
            return nil
        }

        var version: String? {
            if case .available(_, let version) = self { return version }
            return nil
        }
    }

    /// 待推送的媒体。
    enum Media: Equatable {
        case image(URL)
        case video(URL)

        var url: URL {
            switch self {
            case .image(let url), .video(let url): return url
            }
        }
    }

    enum BridgeError: LocalizedError {
        case notRunning
        case fileMissing(URL)
        case unsupported(URL)
        /// 工程目录（scene / web）既没有烘焙成片也没有预览图可用。
        case noUsableContent(String)
        case rejected(String)
        case transport(String)

        var errorDescription: String? {
            switch self {
            case .notRunning:
                return t("dshHarness.error.notRunning")
            case .fileMissing:
                return t("dshHarness.error.fileMissing")
            case .unsupported:
                return t("dshHarness.error.unsupported")
            case .noUsableContent(let name):
                return "\(t("dshHarness.error.noUsableContent"))（\(name)）"
            case .rejected(let reason):
                return "\(t("dshHarness.error.rejected"))：\(reason)"
            case .transport(let reason):
                return "\(t("dshHarness.error.transport"))：\(reason)"
            }
        }
    }

    // MARK: - 状态

    @Published private(set) var availability: Availability = .unknown

    private var lastProbeAt: Date?
    private var probeTask: Task<Availability, Never>?
    private var monitorTask: Task<Void, Never>?

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1.2
        configuration.timeoutIntervalForResource = 2.0
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: configuration)
    }()

    private init() {
        if BackgroundRuntimeRole.isRemoteUI {
            BackgroundRuntimeBridge.observe { [weak self] snapshot in
                if let data = snapshot["dsh"] as? Data, let value = try? JSONDecoder().decode(Availability.self, from: data) { self?.availability = value }
            }
        }
    }

    // MARK: - 探测

    /// DSH 桌面端是否装在本机（只看安装，不看运行）。
    static var isInstalled: Bool {
        let candidates = [
            "/Applications/DeepSeek Harness.app",
            NSHomeDirectory() + "/Applications/DeepSeek Harness.app"
        ]
        if candidates.contains(where: { FileManager.default.fileExists(atPath: $0) }) {
            return true
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
    }
    /// 候选端口：用户覆盖值优先，其次桌面版硬编码端口。
    private var candidatePorts: [Int] {
        var ports: [Int] = []
        if let override = WaifuXPreferences.shared.object(forKey: Self.portOverrideKey) as? Int,
           override > 0, override < 65536 {
            ports.append(override)
        }
        ports.append(Self.desktopDefaultPort)
        return ports
    }

    /// 刷新可用性（带缓存；探测本身是毫秒级的本机 GET）。
    @discardableResult
    func refreshAvailability(force: Bool = false) async -> Availability {
        if BackgroundRuntimeRole.isRemoteUI {
            let arguments = (try? BackgroundPropertyList.encode(["force": force])) ?? Data()
            let result = (try? await BackgroundRuntimeBridge.requestCodable("dsh.refresh.wait", arguments: arguments, resultKey: "result", as: Availability.self)) ?? .unavailable
            availability = result
            return result
        }
        if !force, let lastProbeAt, Date().timeIntervalSince(lastProbeAt) < Self.availabilityTTL {
            return availability
        }
        if let probeTask {
            return await probeTask.value
        }
        let task = Task { [weak self] () -> Availability in
            guard let self else { return .unavailable }
            let result = await self.performProbe()
            self.availability = result
            self.lastProbeAt = Date()
            self.probeTask = nil
            return result
        }
        probeTask = task
        return await task.value
    }

    /// 常驻观察：装了 DSH 才轮询——可用时 20s 一次，不可用 60s 一次，未安装 300s 复查安装。
    func startAvailabilityMonitor() {
        guard BackgroundRuntimeRole.isHelper else { return }
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let installed = Self.isInstalled
                let result = await self.refreshAvailability(force: true)
                let interval: TimeInterval
                if !installed {
                    interval = 300
                } else if result.isAvailable {
                    interval = Self.availabilityTTL
                } else {
                    interval = 60
                }
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stopAvailabilityMonitor() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    private func performProbe() async -> Availability {
        guard Self.isInstalled else { return .unavailable }
        for port in candidatePorts {
            if let version = await healthVersion(port: port) {
                return .available(port: port, version: version)
            }
        }
        return .unavailable
    }

    private func healthVersion(port: Int) async -> String? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/dsh-theme-manager/health") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["ok"] as? Bool == true,
                  json["name"] as? String == "dsh-theme-manager" else { return nil }
            return json["version"] as? String ?? ""
        } catch {
            return nil
        }
    }

    // MARK: - 推送

    /// 把本地媒体推成 DSH 页面背景。成功返回 DSH 侧写入后的 `background` 字典。
    @discardableResult
    func setBackground(
        media: Media,
        coverage: Coverage = DSHHarnessBridge.defaultCoverage,
        dim: Double = DSHHarnessBridge.defaultDim,
        videoLoop: Bool = DSHHarnessBridge.defaultVideoLoop,
        videoMuted: Bool = DSHHarnessBridge.defaultVideoMuted,
        videoRate: Double = DSHHarnessBridge.defaultVideoRate
    ) async throws -> [String: Any] {
        if BackgroundRuntimeRole.isRemoteUI {
            return try await BackgroundRuntimeBridge.request("dsh.set.wait", ["url": media.url, "video": { if case .video = media { return true }; return false }(), "coverage": coverage.rawValue, "dim": dim, "videoLoop": videoLoop, "videoMuted": videoMuted, "videoRate": videoRate])
        }
        let prepared = try await Self.prepareMedia(media)
        let current = await refreshAvailability()
        guard let port = current.port else { throw BridgeError.notRunning }

        var body: [String: Any] = [
            "path": prepared.url.path,
            "coverage": coverage.rawValue,
            "dim": dim
        ]
        switch prepared {
        case .image:
            body["type"] = "image"
        case .video:
            body["type"] = "video"
            body["video"] = ["loop": videoLoop, "muted": videoMuted, "rate": videoRate]
        }

        let json = try await post(port: port, route: "/dsh-theme-manager/background", body: body)
        if let warning = json["warning"] as? [String], !warning.isEmpty {
            AppLogger.warn(.wallpaper, "DSH 背景已写入但 DSH 侧有告警",
                           metadata: ["warning": warning.joined(separator: " | "),
                                      "path": prepared.url.path])
        }
        AppLogger.info(.wallpaper, "已推送 DSH 页面背景",
                       metadata: ["type": prepared.url.pathExtension.lowercased(),
                                  "port": String(port),
                                  "path": prepared.url.lastPathComponent])
        return json["background"] as? [String: Any] ?? [:]
    }

    /// 清除 DSH 页面背景（恢复成不画背景层）。
    func clearBackground() async throws {
        if BackgroundRuntimeRole.isRemoteUI { try await BackgroundRuntimeBridge.requestVoid("dsh.clear.wait"); return }
        let current = await refreshAvailability()
        guard let port = current.port else { throw BridgeError.notRunning }
        _ = try await post(port: port, route: "/dsh-theme-manager/background/clear", body: [:])
    }

    private func post(port: Int, route: String, body: [String: Any]) async throws -> [String: Any] {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(route)") else {
            throw BridgeError.transport("bad url")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.sourceName, forHTTPHeaderField: Self.sourceHeader)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // 请求失败说明对端已经不是「可用」状态，立刻降级，避免后续继续走死端口。
            availability = .unavailable
            lastProbeAt = Date()
            throw BridgeError.transport(error.localizedDescription)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let text = String(data: data, encoding: .utf8) ?? ""
        guard status == 200 else {
            throw BridgeError.rejected("HTTP \(status) \(text.prefix(200))")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["ok"] as? Bool == true else {
            throw BridgeError.rejected(text.prefix(200).description)
        }
        return json
    }

    // MARK: - 媒体规整

    /// 校验/规整待推送的媒体：文件必须存在；不在 DSH 白名单里的图片转成 JPEG。
    nonisolated static func prepareMedia(_ media: Media) async throws -> Media {
        try await Task.detached(priority: .userInitiated) {
            try prepareMediaSync(media)
        }.value
    }

    nonisolated static func prepareMediaSync(_ media: Media) throws -> Media {
        let url = media.url
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else {
            throw BridgeError.fileMissing(url)
        }
        let ext = url.pathExtension.lowercased()
        switch media {
        case .video:
            guard pushableVideoExtensions.contains(ext) else { throw BridgeError.unsupported(url) }
            return media
        case .image:
            if pushableImageExtensions.contains(ext) { return media }
            guard convertibleImageExtensions.contains(ext) else { throw BridgeError.unsupported(url) }
            return .image(try convertedJPEGURL(from: url))
        }
    }

    /// heic/tiff 这类 DSH 不收的图片转成 JPEG，落 `~/Library/Caches/dsh-background/`。
    nonisolated static func convertedJPEGURL(from url: URL) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw BridgeError.unsupported(url)
        }

        let directory = jpegCacheDirectory()
        let key = cacheKey(for: url, image: image, directory: directory)
        let output = directory.appendingPathComponent("\(key).jpg")
        if FileManager.default.fileExists(atPath: output.path) { return output }

        guard let destination = CGImageDestinationCreateWithURL(
            output as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else {
            throw BridgeError.unsupported(url)
        }
        CGImageDestinationAddImage(
            destination, image,
            [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw BridgeError.unsupported(url)
        }
        return output
    }

    nonisolated private static func jpegCacheDirectory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = base.appendingPathComponent("dsh-background", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// 路径 + 修改时间 + 尺寸 → 稳定文件名（同一张图重复推送不会反复转码）。
    nonisolated private static func cacheKey(for url: URL, image: CGImage, directory: URL) -> String {
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)?
            .timeIntervalSince1970 ?? 0
        let seed = "\(url.path)|\(Int(modified))|\(image.width)x\(image.height)"
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}

// MARK: - 本地路径 → 可推送媒体

/// 把「可能是媒体文件、也可能是 Workshop / scene 工程目录」的本地路径解析成 DSH 背景媒体。
///
/// 工程目录（含 `project.json` 的 Wallpaper Engine 内容）本身不是媒体：
/// 优先用离线烘焙成片（循环 MP4），其次用工程自带的预览图兜底。
enum DSHMediaResolver {

    /// 工程目录里可当静态背景用的预览图候选名（Wallpaper Engine 约定）。
    private static let previewNames = [
        "preview.jpg", "preview.jpeg", "preview.png", "preview.gif", "preview.webp",
        "preview.avif", "preview.bmp"
    ]

    /// - Parameters:
    ///   - localURL: 本地文件或 Workshop / scene 工程目录
    ///   - bakedVideoPath: 该内容对应的离线烘焙成片（没有就传 nil）
    static func resolve(localURL: URL, bakedVideoPath: String? = nil) -> DSHHarnessBridge.Media? {
        guard localURL.isFileURL else { return nil }
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: localURL.path, isDirectory: &isDirectory) else { return nil }

        if !isDirectory.boolValue {
            return media(for: localURL)
        }

        if let bakedVideoPath, !bakedVideoPath.isEmpty {
            let baked = URL(fileURLWithPath: bakedVideoPath)
            if fileManager.fileExists(atPath: baked.path),
               let media = media(for: baked), case .video = media {
                return media
            }
        }

        if let preview = previewImage(in: localURL, depth: 0) {
            return .image(preview)
        }
        return nil
    }

    /// 文件 → 媒体（扩展名不在 DSH 白名单、但本机能解码的图片也返回，交给推送层转码）。
    static func media(for url: URL) -> DSHHarnessBridge.Media? {
        let ext = url.pathExtension.lowercased()
        if DSHHarnessBridge.pushableVideoExtensions.contains(ext) { return .video(url) }
        if DSHHarnessBridge.pushableImageExtensions.contains(ext)
            || DSHHarnessBridge.convertibleImageExtensions.contains(ext) {
            return .image(url)
        }
        return nil
    }

    /// 在工程目录里浅层找 `preview.*`（Wallpaper Engine 的预览图约定）。
    private static func previewImage(in directory: URL, depth: Int) -> URL? {
        guard depth <= 2 else { return nil }
        let fileManager = FileManager.default
        for name in previewNames {
            let candidate = directory.appendingPathComponent(name)
            if fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for entry in entries {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory, let found = previewImage(in: entry, depth: depth + 1) {
                return found
            }
        }
        return nil
    }
}
