import AppKit
import SwiftUI

/// Follows Sparkle's check cycle, but owns a separate feed, version space and user interface.
@MainActor
final class RendererComponentUpdater: ObservableObject {
    static let shared = RendererComponentUpdater()
    @Published private(set) var updates: [RendererComponentRelease] = []
    @Published private(set) var versions: [RendererComponent: String] = [:]
    @Published private(set) var isChecking = false
    @Published private(set) var isInstalling = false
    @Published private(set) var progress = 0.0
    @Published private(set) var status = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var didInstall = false
    private var operation: Task<Void, Never>?
    private var windowController: NSWindowController?
    private var presentWhenFinished = false
    private let installer = RendererComponentInstaller()

    private init() {}

    func check(userInitiated: Bool = false) {
        guard !BackgroundRuntimeRole.isIsolatedTest else { return }
        if userInitiated { presentWhenFinished = true; showWindow() }
        guard !isChecking, !isInstalling else { return }
        isChecking = true
        didInstall = false
        errorMessage = nil
        status = "正在检查渲染组件…"
        operation = Task {
            defer { isChecking = false; operation = nil; presentWhenFinished = false }
            versions = await installer.currentVersions()
            do {
                let result = try await installer.check()
                versions = result.versions
                updates = result.updates
                status = result.published ? (updates.isEmpty ? "渲染组件已是最新版本" : "有 \(updates.count) 个组件可更新")
                    : "组件发布源暂未提供更新清单，当前组件保持不变。"
                let hasUnskipped = updates.contains {
                    WaifuXPreferences.shared.integer(forKey: skipKey($0.component)) != $0.revision
                }
                if presentWhenFinished || hasUnskipped { showWindow() }
            } catch {
                errorMessage = error.localizedDescription
                status = "组件检查未完成"
            }
        }
    }

    func install() {
        guard !updates.isEmpty, !isInstalling, !isChecking else { return }
        let releases = updates
        let total = releases.reduce(Int64(0)) { $0 + $1.byteCount }
        isInstalling = true
        progress = 0
        errorMessage = nil
        didInstall = false
        operation = Task {
            var completed: Int64 = 0
            var installed = 0
            defer { isInstalling = false; operation = nil }
            do {
                for release in releases {
                    try Task.checkCancellation()
                    status = "正在下载并校验\(release.component.title)…"
                    let offset = completed
                    try await installer.install(release) { [weak self] received in
                        Task { @MainActor in
                            guard let self, self.isInstalling else { return }
                            self.progress = max(self.progress, min(1, Double(offset + received) / Double(max(1, total))))
                        }
                    }
                    completed += release.byteCount
                    installed += 1
                    versions[release.component] = release.version
                    updates.removeAll { $0.id == release.id }
                    WaifuXPreferences.shared.removeObject(forKey: skipKey(release.component))
                }
                progress = 1
                didInstall = true
                status = "组件已安装"
            } catch {
                if Task.isCancelled {
                    status = installed == 0 ? "已取消，当前组件保持不变。" : "已安装 \(installed) 个组件，其余下载已取消。"
                } else {
                    status = installed == 0 ? "安装未完成，当前组件保持不变。" : "已安装 \(installed) 个组件，其余更新未完成。"
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    func cancelInstallation() { operation?.cancel() }

    func skipVersions() {
        for release in updates { WaifuXPreferences.shared.set(release.revision, forKey: skipKey(release.component)) }
        closeWindow()
    }

    func closeWindow() { windowController?.close() }
    private func skipKey(_ component: RendererComponent) -> String { "renderer_component_skipped_\(component.rawValue)" }

    private func showWindow() {
        if windowController == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
                                  styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "渲染组件更新"
            window.isReleasedWhenClosed = false
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isOpaque = false
            window.backgroundColor = .clear
            window.appearance = NSAppearance(named: .darkAqua)
            window.hasShadow = true
            window.isMovableByWindowBackground = true
            window.tabbingMode = .disallowed
            // Settings is also floating; this utility window must remain reachable above it.
            window.level = .floating
            let bounds = NSRect(x: 0, y: 0, width: 520, height: 440)
            let hostingView = NSHostingView(rootView: RendererComponentUpdateView(updater: self).ignoresSafeArea())
            hostingView.frame = bounds
            hostingView.autoresizingMask = [.width, .height]
            // A single native glass surface for this transient update panel. Keep the
            // hosting view transparent so it doesn't cover the material with a solid fill.
            let backdrop = NSVisualEffectView(frame: bounds)
            backdrop.material = .hudWindow
            backdrop.blendingMode = .behindWindow
            backdrop.state = .active
            backdrop.wantsLayer = true
            backdrop.layer?.cornerRadius = 28
            backdrop.layer?.masksToBounds = true
            if #available(macOS 26.0, *) {
                let glass = NSGlassEffectView(frame: bounds)
                glass.style = .regular
                glass.cornerRadius = 28
                glass.tintColor = NSColor.black.withAlphaComponent(0.18)
                glass.autoresizingMask = [.width, .height]
                glass.contentView = hostingView
                backdrop.addSubview(glass)
            } else {
                backdrop.addSubview(hostingView)
            }
            window.contentView = backdrop
            window.center()
            windowController = NSWindowController(window: window)
        }
        guard let window = windowController?.window else { return }
        WindowSpaceCoordinator.show(window)
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
    }
}

private actor RendererComponentInstaller {
    struct CheckResult: Sendable {
        let updates: [RendererComponentRelease]
        let versions: [RendererComponent: String]
        let published: Bool
    }
    // A dedicated, stable release tag prevents component-only releases from becoming the app's latest release.
    private let feedURL = URL(string: "https://github.com/jipika/WaifuX/releases/download/renderer-components/components.json")!
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 1800
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    func currentVersions() -> [RendererComponent: String] {
        Dictionary(uniqueKeysWithValues: RendererComponent.allCases.map { component in
            (component, RendererComponentStore.installedRelease(component)?.version
             ?? RendererComponentStore.bundledVersion(component).version)
        })
    }

    func check() async throws -> CheckResult {
        var versions: [RendererComponent: String] = [:]
        var revisions: [RendererComponent: Int] = [:]
        for component in RendererComponent.allCases {
            let installed = RendererComponentStore.installedRelease(component)
            let bundled = RendererComponentStore.bundledVersion(component)
            versions[component] = installed?.version ?? bundled.version
            revisions[component] = installed?.revision ?? bundled.revision
        }
        let delegate = RendererComponentDownloadDelegate(limit: 256 * 1024) { _ in }
        let (temporary, response) = try await session.download(for: URLRequest(url: feedURL), delegate: delegate)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let http = response as? HTTPURLResponse else { throw RendererComponentError.unavailable }
        if http.statusCode == 404 { return CheckResult(updates: [], versions: versions, published: false) }
        guard http.statusCode == 200, response.url?.scheme == "https" else { throw RendererComponentError.unavailable }
        guard let size = try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber,
              size.int64Value <= 256 * 1024 else { throw RendererComponentError.invalidManifest }
        let data = try Data(contentsOf: temporary)
        guard data.count <= 256 * 1024 else { throw RendererComponentError.invalidManifest }
        let feed = try JSONDecoder().decode(RendererComponentFeed.self, from: data)
        try feed.validate()
        let updates = RendererComponent.allCases.compactMap { component in
            feed.releases.filter {
                $0.component == component && $0.isCompatible && $0.revision > (revisions[component] ?? 0)
            }.max { $0.revision < $1.revision }
        }
        return CheckResult(updates: updates, versions: versions, published: true)
    }

    func install(_ release: RendererComponentRelease, progress: @escaping @Sendable (Int64) -> Void) async throws {
        try release.validate()
        guard release.isCompatible else { throw RendererComponentError.invalidManifest }
        let fm = FileManager.default
        let componentDirectory = RendererComponentStore.root.appendingPathComponent(release.component.rawValue)
        try fm.createDirectory(at: componentDirectory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let staging = componentDirectory.appendingPathComponent(".download-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        var received: Int64 = 0
        for file in release.files {
            try Task.checkCancellation()
            let offset = received
            let delegate = RendererComponentDownloadDelegate(limit: file.size) { progress(offset + $0) }
            let (temporary, response) = try await session.download(for: URLRequest(url: file.url), delegate: delegate)
            defer { try? fm.removeItem(at: temporary) }
            guard (response as? HTTPURLResponse)?.statusCode == 200, response.url?.scheme == "https",
                  (try fm.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.int64Value == file.size else {
                throw RendererComponentError.invalidFile(file.path)
            }
            let destination = staging.appendingPathComponent(file.path)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: temporary, to: destination)
            try fm.setAttributes([.posixPermissions: file.path.hasSuffix(".dylib") ? 0o644 : 0o755], ofItemAtPath: destination.path)
            received += file.size
            progress(received)
        }
        try Task.checkCancellation()
        try RendererComponentStore.validateFiles(release, in: staging)
        let receipt = try JSONEncoder().encode(release)
        try receipt.write(to: staging.appendingPathComponent("receipt.json"), options: .atomic)
        let destination = RendererComponentStore.directory(for: release)
        if fm.fileExists(atPath: destination.path) {
            // A canceled earlier install may already have staged this immutable revision.
            try RendererComponentStore.validateFiles(release, in: destination)
        } else {
            try fm.moveItem(at: staging, to: destination)
        }
        try Task.checkCancellation()
        // Publish last. A failure/cancel before this point leaves the previous pointer intact.
        // Old directories are retained because already-running renderers can still load their libraries.
        try receipt.write(to: RendererComponentStore.activeReceiptURL(release.component), options: .atomic)
    }
}

private final class RendererComponentDownloadDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    let limit: Int64
    let progress: @Sendable (Int64) -> Void
    init(limit: Int64, progress: @escaping @Sendable (Int64) -> Void) {
        self.limit = limit
        self.progress = progress
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > limit || totalBytesExpectedToWrite > limit { downloadTask.cancel(); return }
        // Avoid creating a main-actor task for every small network packet.
        let step: Int64 = 512 * 1024
        if totalBytesWritten == limit || totalBytesWritten / step != (totalBytesWritten - bytesWritten) / step {
            progress(totalBytesWritten)
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        let host = request.url?.host ?? ""
        let allowed = request.url?.scheme == "https" && (host == "github.com" || host.hasSuffix(".githubusercontent.com"))
        completionHandler(allowed ? request : nil)
    }
}
