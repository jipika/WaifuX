import Foundation
import CryptoKit
import Security

/// Shared by the UI installer and Helper's executable resolvers. Never modifies the app bundle.
enum RendererComponent: String, Codable, CaseIterable, Identifiable, Sendable {
    case wgpu, web, video

    var id: String { rawValue }
    var title: String {
        switch self {
        case .wgpu: return "Scene 渲染器"
        case .web: return "Web 渲染器"
        case .video: return "视频渲染器"
        }
    }
    var executable: String {
        switch self {
        case .wgpu: return "wallpaper-wgpu"
        case .web: return "wallpaperengine-cli"
        case .video: return "wallpaper-video-renderer"
        }
    }
    /// Dependencies are versioned and activated with their renderer, never mixed across releases.
    var files: Set<String> {
        switch self {
        case .wgpu: return [executable, "dxc", "lib/libdxcompiler.dylib"]
        case .web: return [executable, "ffmpeg"]
        case .video: return [executable]
        }
    }
    func signingIdentifier(for path: String) -> String {
        "com.waifux.component.\(rawValue).\(URL(fileURLWithPath: path).lastPathComponent)"
    }
}

struct RendererComponentRelease: Codable, Sendable, Identifiable {
    struct File: Codable, Sendable {
        let path: String
        let url: URL
        let size: Int64
        let sha256: String
    }
    let component: RendererComponent
    let version: String
    let revision: Int
    let architecture: String
    let protocolVersion: Int
    let minimumAppVersion: String
    let maximumAppVersion: String
    let minimumSystemVersion: String
    let notes: String
    let files: [File]

    var id: String { "\(component.rawValue)-\(architecture)-\(revision)" }
    var byteCount: Int64 { files.reduce(0) { $0 + $1.size } }
    var directoryName: String { "\(revision)-\(architecture)" }

    func validate() throws {
        guard revision > 0, revision <= 1_000_000_000,
              !version.isEmpty, version.count <= 80, notes.count <= 16_000,
              ["arm64", "x86_64"].contains(architecture), (1...1024).contains(protocolVersion),
              RendererComponentStore.isVersion(minimumAppVersion),
              RendererComponentStore.isVersion(maximumAppVersion),
              RendererComponentStore.isVersion(minimumSystemVersion),
              RendererComponentStore.compareVersions(minimumAppVersion, maximumAppVersion) != .orderedDescending,
              Set(files.map(\.path)) == component.files, files.count == component.files.count else {
            throw RendererComponentError.invalidManifest
        }
        for file in files {
            guard file.size > 0, file.size <= 512 * 1024 * 1024,
                  file.sha256.count == 64,
                  file.sha256.allSatisfy({ "0123456789abcdef".contains($0) }),
                  file.url.scheme == "https", file.url.host == "github.com",
                  file.url.user == nil, file.url.password == nil, file.url.port == nil,
                  file.url.path.hasPrefix("/jipika/WaifuX/releases/download/") else {
                throw RendererComponentError.invalidManifest
            }
        }
    }

    var isCompatible: Bool {
        let app = RendererComponentStore.appVersion
        let system = ProcessInfo.processInfo.operatingSystemVersion
        let os = "\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)"
        return architecture == RendererComponentStore.architecture && protocolVersion == 1
            && RendererComponentStore.isVersion(app)
            && RendererComponentStore.compareVersions(app, minimumAppVersion) != .orderedAscending
            && RendererComponentStore.compareVersions(app, maximumAppVersion) != .orderedDescending
            && RendererComponentStore.compareVersions(os, minimumSystemVersion) != .orderedAscending
    }
}

struct RendererComponentFeed: Codable, Sendable {
    let schemaVersion: Int
    let releases: [RendererComponentRelease]

    func validate() throws {
        guard schemaVersion == 1, releases.count <= 60,
              Set(releases.map(\.id)).count == releases.count else {
            throw RendererComponentError.invalidManifest
        }
        try releases.forEach { try $0.validate() }
    }
}

enum RendererComponentError: LocalizedError {
    case invalidManifest, invalidFile(String), signature(String), architecture(String), unavailable
    var errorDescription: String? {
        switch self {
        case .invalidManifest: return "组件更新清单无效，请稍后重试。"
        case .invalidFile(let name): return "\(name) 下载不完整或校验失败，原组件仍然可用。"
        case .signature(let name): return "\(name) 的开发者签名不符合要求，已取消安装。"
        case .architecture(let name): return "\(name) 不支持当前处理器，已取消安装。"
        case .unavailable: return "暂时无法获取组件更新，请检查网络后重试。"
        }
    }
}

enum RendererComponentStore {
    struct BundledVersion: Codable, Sendable {
        let version: String
        let revision: Int
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var verified: [String: String] = [:]

    static var architecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }
    static var appVersion: String {
        Bundle(url: WaifuXHostBundle.bundleURL)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
    static var root: URL {
        // Both targets are unsandboxed and run as the same user. Tests must never read production state.
        let support: URL
        if BackgroundRuntimeRole.isIsolatedTest {
            support = URL(fileURLWithPath: ProcessInfo.processInfo.environment["WAIFUX_HELPER_TEST_ROOT"]
                          ?? NSTemporaryDirectory()).appendingPathComponent("ComponentUpdates")
        } else {
            support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("WaifuX/RendererComponents", isDirectory: true)
        }
        return support
    }
    static func isVersion(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return (1...4).contains(parts.count) && parts.allSatisfy {
            !$0.isEmpty && $0.count <= 9 && $0.allSatisfy { "0123456789".contains($0) }
        }
    }
    static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = lhs.split(separator: ".").compactMap { Int($0) }
        let right = rhs.split(separator: ".").compactMap { Int($0) }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a < b ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
    static func bundledVersion(_ component: RendererComponent) -> BundledVersion {
        for url in WaifuXHostBundle.resourceCandidates(named: "renderer-components.json") {
            if let data = try? Data(contentsOf: url),
               let versions = try? JSONDecoder().decode([String: BundledVersion].self, from: data),
               let version = versions[component.rawValue] { return version }
        }
        return BundledVersion(version: "随 App 内置", revision: 0)
    }
    static func activeReceiptURL(_ component: RendererComponent) -> URL {
        root.appendingPathComponent("\(component.rawValue)/active.json")
    }
    static func directory(for release: RendererComponentRelease) -> URL {
        root.appendingPathComponent("\(release.component.rawValue)/\(release.directoryName)", isDirectory: true)
    }
    static func installedRelease(_ component: RendererComponent) -> RendererComponentRelease? {
        guard let data = try? Data(contentsOf: activeReceiptURL(component)), data.count <= 128 * 1024,
              let release = try? JSONDecoder().decode(RendererComponentRelease.self, from: data),
              release.component == component, (try? release.validate()) != nil,
              release.isCompatible, release.revision > bundledVersion(component).revision,
              (try? validateFiles(release, in: directory(for: release))) != nil else { return nil }
        return release
    }
    static func executableURL(_ component: RendererComponent) -> URL? {
        guard let release = installedRelease(component) else { return nil }
        return directory(for: release).appendingPathComponent(component.executable)
    }

    /// Keep an already-running Web daemon paired with its own client after installing an update.
    /// The daemon checks the client's executable path; using a new path would orphan the old daemon.
    static func runningWebExecutableURL() -> URL? {
        let pidFile = URL(fileURLWithPath: "/tmp/wallpaperengine-cli.pid")
        guard !BackgroundRuntimeRole.isIsolatedTest,
              let pid = OwnedDaemonPIDFile.readPID(at: pidFile),
              let identity = OwnedProcessIdentity.capture(pid) else { return nil }
        let url = URL(fileURLWithPath: identity.executablePath)
        var allowed = WaifuXHostBundle.resourceCandidates(named: RendererComponent.web.executable)
        allowed += [
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("wallpaperengine-cli"),
            URL(fileURLWithPath: "/Volumes/mac/CodeLibrary/Claude/WallHaven/wallpaperengine-cli"),
            URL(fileURLWithPath: "/Volumes/mac/CodeLibrary/Claude/WallHaven/Resources/wallpaperengine-cli")
        ]
        // Retained immutable releases can still own the daemon after active.json has changed.
        let directory = url.deletingLastPathComponent()
        if directory.deletingLastPathComponent().standardizedFileURL == root.appendingPathComponent("web").standardizedFileURL,
           let data = try? Data(contentsOf: directory.appendingPathComponent("receipt.json")),
           let release = try? JSONDecoder().decode(RendererComponentRelease.self, from: data),
           release.component == .web, (try? release.validate()) != nil,
           directory.lastPathComponent == release.directoryName,
           (try? validateFiles(release, in: directory)) != nil {
            allowed.append(directory.appendingPathComponent(RendererComponent.web.executable))
        }
        guard let running = OwnedDaemonPIDFile.identity(at: pidFile, expectedExecutables: allowed) else { return nil }
        return URL(fileURLWithPath: running.executablePath)
    }

    static func validateFiles(_ release: RendererComponentRelease, in directory: URL) throws {
        // Bound cache lifetime to file identities, timestamps, checksums and the immutable release path.
        var fingerprint = ""
        for file in release.files {
            let url = directory.appendingPathComponent(file.path)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.size] as? NSNumber)?.int64Value == file.size,
                  url.resolvingSymlinksInPath().path == url.standardizedFileURL.path,
                  file.path.hasSuffix(".dylib") || FileManager.default.isExecutableFile(atPath: url.path) else {
                throw RendererComponentError.invalidFile(file.path)
            }
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
            fingerprint += "\(file.path):\(file.sha256):\(attributes[.systemFileNumber] ?? ""):" +
                "\(modified):\(attributes[.posixPermissions] ?? "");"
        }
        lock.lock()
        let cached = verified[directory.path] == fingerprint
        lock.unlock()
        if cached { return }
        for file in release.files {
            let url = directory.appendingPathComponent(file.path)
            guard try sha256(url) == file.sha256 else { throw RendererComponentError.invalidFile(file.path) }
            try verifyCode(url, component: release.component, path: file.path)
        }
        lock.lock()
        verified[directory.path] = fingerprint
        lock.unlock()
    }

    static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { digest.update(data: data) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func verifyCode(_ url: URL, component: RendererComponent, path: String) throws {
        var code: SecStaticCode?
        // Explicitly select this process's architecture, including x86_64 under Rosetta.
        let attributes = [kSecCodeAttributeArchitecture as String: architecture] as CFDictionary
        guard SecStaticCodeCreateWithPathAndAttributes(url as CFURL, [], attributes, &code) == errSecSuccess,
              let code else { throw RendererComponentError.architecture(path) }
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"SRHKTRJ83W\" " +
            "and certificate leaf[field.1.2.840.113635.100.6.1.13] exists " +
            "and identifier \"\(component.signingIdentifier(for: path))\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement) == errSecSuccess else {
            throw RendererComponentError.signature(path)
        }
    }
}
