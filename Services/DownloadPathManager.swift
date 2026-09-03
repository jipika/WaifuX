import Foundation
import AppKit

/// 下载路径管理器 - 统一管理壁纸和媒体的下载路径
/// 默认存储在 Application Support/WaifuX，支持用户自定义到其他目录。
@MainActor
final class DownloadPathManager {
    static let shared = DownloadPathManager()

    /// 与设置中的开关一致：是否写入应用内媒体库
    static let persistDownloadsToAppLibraryDefaultsKey = "save_to_downloads"
    /// 用户自定义下载根目录路径（ bookmarks 数据，用于跨启动保持访问权限）
    static let customDownloadRootBookmarkKey = "custom_download_root_bookmark_v1"
    /// 用户自定义下载根目录的纯路径字符串（仅用于展示）
    static let customDownloadRootPathKey = "custom_download_root_path_v1"

    private static let legacyCustomFolderPathKey = "download_folder_path"
    private static let legacyPermissionRequestedKey = "download_permission_requested"

    private let defaults = UserDefaults.standard
    private let fileManager = FileManager.default
    /// 当前已 `startAccessingSecurityScopedResource` 的自定义父目录（进程内保持访问）
    private var activeSecurityScopedRootURL: URL?
    private var isAccessingSecurityScopedRoot = false

    // MARK: - 根目录

    /// 是否使用了自定义下载目录
    var hasCustomRoot: Bool {
        resolveCustomRootURL() != nil
    }

    /// 用户可见的当前根目录路径字符串（用于 UI 展示）
    var currentRootPathDisplay: String {
        if let customPath = defaults.string(forKey: Self.customDownloadRootPathKey) {
            return customPath
        }
        return rootFolderURL.path
    }

    /// 根目录: 默认 ~/Library/Application Support/WaifuX/，或用户自定义目录下 WaifuX/
    /// 自定义目录会先恢复 security-scoped 访问，确保导入/下载写到设置里的存储位置。
    var rootFolderURL: URL {
        let url: URL
        if let customRoot = resolveCustomRootURL() {
            ensureSecurityScopedAccess(to: customRoot)
            url = customRoot.appendingPathComponent("WaifuX", isDirectory: true)
        } else {
            stopSecurityScopedAccessIfNeeded()
            url = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first!
                .appendingPathComponent("WaifuX", isDirectory: true)
        }
        return url
    }

    /// 壁纸目录
    var wallpapersFolderURL: URL {
        rootFolderURL.appendingPathComponent("Wallpapers", isDirectory: true)
    }

    /// 媒体目录
    var mediaFolderURL: URL {
        rootFolderURL.appendingPathComponent("Media", isDirectory: true)
    }

    /// Scene 离线烘焙 MP4 目录
    var sceneBakesFolderURL: URL {
        rootFolderURL.appendingPathComponent("SceneBakes", isDirectory: true)
    }

    /// 静态壁纸派生文件目录（例如竖图模糊填充），不参与本地壁纸扫描。
    var derivedWallpapersFolderURL: URL {
        rootFolderURL.appendingPathComponent("DerivedWallpapers", isDirectory: true)
    }

    private init() {}

    // MARK: - 自定义目录解析

    /// 从 bookmark 数据解析用户自定义的根目录 URL。
    /// 若 bookmark 解析失败，尝试使用保存的路径字符串作为兜底。
    private func resolveCustomRootURL() -> URL? {
        guard let bookmarkData = defaults.data(forKey: Self.customDownloadRootBookmarkKey) else {
            return nil
        }
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale {
                // 刷新 bookmark（需已持有访问权）
                ensureSecurityScopedAccess(to: url)
                if let newBookmark = try? createBookmark(for: url) {
                    defaults.set(newBookmark, forKey: Self.customDownloadRootBookmarkKey)
                }
            }
            return url
        } catch {
            print("[DownloadPathManager] Failed to resolve custom root bookmark: \(error)")
            // 兜底：尝试使用保存的纯路径字符串（可能无 security-scope，外置盘可能失败）
            if let savedPath = defaults.string(forKey: Self.customDownloadRootPathKey),
               fileManager.fileExists(atPath: savedPath) {
                print("[DownloadPathManager] Falling back to saved path: \(savedPath)")
                return URL(fileURLWithPath: savedPath)
            }
            print("[DownloadPathManager] Saved path also unavailable, custom root is lost")
            return nil
        }
    }

    /// 为指定 URL 创建 security-scoped bookmark 数据
    private func createBookmark(for url: URL) throws -> Data {
        return try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    /// 恢复自定义目录的 security-scoped 访问（导入/下载写盘必需）。
    @discardableResult
    private func ensureSecurityScopedAccess(to url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        if isAccessingSecurityScopedRoot,
           let active = activeSecurityScopedRootURL,
           active.standardizedFileURL == standardized {
            return true
        }
        stopSecurityScopedAccessIfNeeded()
        let started = standardized.startAccessingSecurityScopedResource()
        if started {
            activeSecurityScopedRootURL = standardized
            isAccessingSecurityScopedRoot = true
            print("[DownloadPathManager] Started security-scoped access: \(standardized.path)")
        } else {
            // 非沙盒 / 已有权限时可能返回 false，仍可尝试使用该路径
            activeSecurityScopedRootURL = standardized
            isAccessingSecurityScopedRoot = false
            print("[DownloadPathManager] Security-scoped start returned false (may still be writable): \(standardized.path)")
        }
        return true
    }

    private func stopSecurityScopedAccessIfNeeded() {
        guard isAccessingSecurityScopedRoot, let active = activeSecurityScopedRootURL else {
            activeSecurityScopedRootURL = nil
            isAccessingSecurityScopedRoot = false
            return
        }
        active.stopAccessingSecurityScopedResource()
        print("[DownloadPathManager] Stopped security-scoped access: \(active.path)")
        activeSecurityScopedRootURL = nil
        isAccessingSecurityScopedRoot = false
    }

    // MARK: - 目录选择

    /// 弹出目录选择器让用户选择新的下载根目录
    /// - Returns: 选中的目录 URL（不包含 WaifuX 子目录），nil 表示用户取消
    func showDirectoryPicker() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择目录"
        panel.message = "选择 WaifuX 下载文件的存储位置"

        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            return nil
        }
        return selectedURL
    }

    /// 设置自定义下载根目录（父目录，会在其下创建 WaifuX 子目录）
    /// - Parameter parentURL: 用户选择的父目录
    /// - Returns: 是否成功
    @discardableResult
    func setCustomRoot(parentURL: URL) -> Bool {
        do {
            // 面板选中的 URL 在当前 runloop 内通常已可访问；立刻建 bookmark 并接管长期访问
            let bookmarkData = try createBookmark(for: parentURL)
            defaults.set(bookmarkData, forKey: Self.customDownloadRootBookmarkKey)
            defaults.set(parentURL.path, forKey: Self.customDownloadRootPathKey)
            ensureSecurityScopedAccess(to: parentURL)
            createDirectoryStructure()
            print("[DownloadPathManager] Custom root set to: \(parentURL.path)")
            return true
        } catch {
            print("[DownloadPathManager] Failed to set custom root: \(error)")
            return false
        }
    }

    /// 恢复为默认目录（Application Support/WaifuX）
    func resetToDefaultRoot() {
        stopSecurityScopedAccessIfNeeded()
        defaults.removeObject(forKey: Self.customDownloadRootBookmarkKey)
        defaults.removeObject(forKey: Self.customDownloadRootPathKey)
        createDirectoryStructure()
        print("[DownloadPathManager] Reset to default root")
    }

    // MARK: - 旧版清理

    func migrateLegacyCustomFolderPreferenceIfNeeded() {
        guard defaults.object(forKey: Self.legacyCustomFolderPathKey) != nil else { return }
        defaults.removeObject(forKey: Self.legacyCustomFolderPathKey)
        defaults.removeObject(forKey: Self.legacyPermissionRequestedKey)
        print("[DownloadPathManager] Cleared legacy custom folder keys.")
    }

    // MARK: - 权限与目录创建

    func ensureDownloadPermission() async -> Bool {
        createDirectoryStructure()
    }

    var hasValidPermission: Bool {
        let root = rootFolderURL
        if fileManager.fileExists(atPath: root.path) {
            return fileManager.isWritableFile(atPath: root.path)
        }
        return true
    }

    @discardableResult
    func createDirectoryStructure() -> Bool {
        // 通过 rootFolderURL 触发自定义目录的 security-scoped 恢复
        let root = rootFolderURL
        let directories = [
            root,
            wallpapersFolderURL,
            mediaFolderURL,
            sceneBakesFolderURL,
            derivedWallpapersFolderURL
        ]
        var ok = true

        for directory in directories {
            if !fileManager.fileExists(atPath: directory.path) {
                do {
                    try fileManager.createDirectory(
                        at: directory,
                        withIntermediateDirectories: true,
                        attributes: nil
                    )
                    print("[DownloadPathManager] Created directory: \(directory.path)")
                } catch {
                    print("[DownloadPathManager] Failed to create directory: \(error)")
                    ok = false
                }
            }
            if fileManager.fileExists(atPath: directory.path), !fileManager.isWritableFile(atPath: directory.path) {
                print("[DownloadPathManager] Directory not writable: \(directory.path)")
                ok = false
            }
        }

        // Optimization records no longer live next to media; lift any historical
        // adjacent sidecars out of Media / SceneBakes when the library root is ready.
        let migrated = VideoOptimizationRecordStore.shared.migrateLegacyAdjacentSidecarsInLibraryRootsIfNeeded()
        if migrated > 0 {
            print("[DownloadPathManager] Migrated \(migrated) video optimization sidecars out of media folders")
        }
        return ok
    }

    func ensureDirectoryStructure() async -> Bool {
        await ensureDownloadPermission()
    }

    // MARK: - 路径解析

    enum ContentType {
        case wallpaper
        case media
    }

    func destinationFolder(for type: ContentType) -> URL {
        switch type {
        case .wallpaper:
            return wallpapersFolderURL
        case .media:
            return mediaFolderURL
        }
    }

    func wallpaperFileURL(id: String, fileExtension: String) -> URL {
        let fileName = "wallhaven-\(id).\(fileExtension)"
        return wallpapersFolderURL.appendingPathComponent(fileName)
    }

    func mediaFileURL(slug: String, label: String, fileExtension: String) -> URL {
        let safeSlug = slug
            .replacingOccurrences(of: #"[^a-zA-Z0-9\-]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let safeLabel = label.lowercased().replacingOccurrences(of: " ", with: "-")
        let fileName = "motionbgs-\(safeSlug)-\(safeLabel).\(fileExtension)"
        return mediaFolderURL.appendingPathComponent(fileName)
    }

    // MARK: - 路径检测

    struct FileLocation {
        let url: URL
        let foundIn: LocationType

        enum LocationType {
            case wallpapersFolder
            case mediaFolder
            case legacyRootFolder
            case notFound
        }
    }

    func locateWallpaperFile(id: String, fileExtension: String) -> FileLocation {
        let fileName = "wallhaven-\(id).\(fileExtension)"
        let location = wallpapersFolderURL.appendingPathComponent(fileName)
        if fileManager.fileExists(atPath: location.path) {
            return FileLocation(url: location, foundIn: .wallpapersFolder)
        }
        return FileLocation(url: location, foundIn: .notFound)
    }

    func locateMediaFile(slug: String, label: String, fileExtension: String) -> FileLocation {
        let safeSlug = slug
            .replacingOccurrences(of: #"[^a-zA-Z0-9\-]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let safeLabel = label.lowercased().replacingOccurrences(of: " ", with: "-")
        let fileName = "motionbgs-\(safeSlug)-\(safeLabel).\(fileExtension)"
        let location = mediaFolderURL.appendingPathComponent(fileName)
        if fileManager.fileExists(atPath: location.path) {
            return FileLocation(url: location, foundIn: .mediaFolder)
        }
        return FileLocation(url: location, foundIn: .notFound)
    }

    func locateFile(named fileName: String) -> FileLocation {
        let wallpaperLocation = wallpapersFolderURL.appendingPathComponent(fileName)
        if fileManager.fileExists(atPath: wallpaperLocation.path) {
            return FileLocation(url: wallpaperLocation, foundIn: .wallpapersFolder)
        }

        let mediaLocation = mediaFolderURL.appendingPathComponent(fileName)
        if fileManager.fileExists(atPath: mediaLocation.path) {
            return FileLocation(url: mediaLocation, foundIn: .mediaFolder)
        }

        let defaultURL = inferDefaultLocation(for: fileName)
        return FileLocation(url: defaultURL, foundIn: .notFound)
    }

    private func inferDefaultLocation(for fileName: String) -> URL {
        if fileName.hasPrefix("wallhaven-") {
            return wallpapersFolderURL.appendingPathComponent(fileName)
        } else if fileName.hasPrefix("motionbgs-") {
            return mediaFolderURL.appendingPathComponent(fileName)
        } else {
            return rootFolderURL.appendingPathComponent(fileName)
        }
    }

    // MARK: - 下载记录路径更新
    func updateDownloadRecordPath(recordID: String, newPath: String) {
        NotificationCenter.default.post(
            name: .downloadPathChanged,
            object: nil,
            userInfo: ["recordID": recordID, "newPath": newPath]
        )
    }
}

// MARK: - Notification Names
extension Notification.Name {
    static let downloadPathChanged = Notification.Name("downloadPathChanged")
    static let managedLibraryContentsChanged = Notification.Name("managedLibraryContentsChanged")
    static let wallpaperDataSourceChanged = Notification.Name("wallpaperDataSourceChanged")
    static let wallhavenDefaultFiltersChanged = Notification.Name("wallhavenDefaultFiltersChanged")
    static let appDidHideWindow = Notification.Name("appDidHideWindow")
    static let appShouldReleaseForegroundMemory = Notification.Name("appShouldReleaseForegroundMemory")
    static let appDidReceiveMemoryPressure = Notification.Name("appDidReceiveMemoryPressure")
    static let switchToLibraryTab = Notification.Name("switchToLibraryTab")
    static let openCurrentWallpaperDetail = Notification.Name("openCurrentWallpaperDetail")
}

enum MainWallpaperDetailRequest {
    case wallpaper(Wallpaper)
    case media(MediaItem)
}

enum MainNavigationRequestStore {
    private static let pendingTabKey = "mainNavigation.pendingTab"
    private static let libraryTabValue = "myMedia"
    private static let pendingWallpaperDetailKindKey = "mainNavigation.pendingWallpaperDetail.kind"
    private static let pendingWallpaperDetailPayloadKey = "mainNavigation.pendingWallpaperDetail.payload"

    private enum WallpaperDetailKind: String {
        case wallpaper
        case media
    }

    static func requestLibraryTab() {
        UserDefaults.standard.set(libraryTabValue, forKey: pendingTabKey)
        NotificationCenter.default.post(name: .switchToLibraryTab, object: nil)
    }

    static func consumeLibraryTabRequest() -> Bool {
        guard UserDefaults.standard.string(forKey: pendingTabKey) == libraryTabValue else {
            return false
        }
        UserDefaults.standard.removeObject(forKey: pendingTabKey)
        return true
    }

    static func clearLibraryTabRequest() {
        UserDefaults.standard.removeObject(forKey: pendingTabKey)
    }

    static func requestWallpaperDetail(_ request: MainWallpaperDetailRequest) {
        let kind: WallpaperDetailKind
        let payload: Data?
        switch request {
        case .wallpaper(let wallpaper):
            kind = .wallpaper
            payload = try? JSONEncoder().encode(wallpaper)
        case .media(let media):
            kind = .media
            payload = try? JSONEncoder().encode(media)
        }

        guard let payload else { return }
        UserDefaults.standard.set(kind.rawValue, forKey: pendingWallpaperDetailKindKey)
        UserDefaults.standard.set(payload, forKey: pendingWallpaperDetailPayloadKey)
        NotificationCenter.default.post(name: .openCurrentWallpaperDetail, object: nil)
    }

    static func consumeWallpaperDetailRequest() -> MainWallpaperDetailRequest? {
        defer { clearWallpaperDetailRequest() }
        guard let rawKind = UserDefaults.standard.string(forKey: pendingWallpaperDetailKindKey),
              let kind = WallpaperDetailKind(rawValue: rawKind),
              let payload = UserDefaults.standard.data(forKey: pendingWallpaperDetailPayloadKey) else {
            return nil
        }

        switch kind {
        case .wallpaper:
            return (try? JSONDecoder().decode(Wallpaper.self, from: payload))
                .map(MainWallpaperDetailRequest.wallpaper)
        case .media:
            return (try? JSONDecoder().decode(MediaItem.self, from: payload))
                .map(MainWallpaperDetailRequest.media)
        }
    }

    static func clearWallpaperDetailRequest() {
        UserDefaults.standard.removeObject(forKey: pendingWallpaperDetailKindKey)
        UserDefaults.standard.removeObject(forKey: pendingWallpaperDetailPayloadKey)
    }
}
