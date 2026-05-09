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
    var rootFolderURL: URL {
        if let customRoot = resolveCustomRootURL() {
            return customRoot.appendingPathComponent("WaifuX", isDirectory: true)
        }
        return fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("WaifuX", isDirectory: true)
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

    private init() {}

    // MARK: - 自定义目录解析

    /// 从 bookmark 数据解析用户自定义的根目录 URL，并自动恢复访问权限
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
                // 刷新 bookmark
                _ = try? createBookmark(for: url)
            }
            return url
        } catch {
            print("[DownloadPathManager] Failed to resolve custom root bookmark: \(error)")
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
            let bookmarkData = try createBookmark(for: parentURL)
            defaults.set(bookmarkData, forKey: Self.customDownloadRootBookmarkKey)
            defaults.set(parentURL.path, forKey: Self.customDownloadRootPathKey)
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
        let directories = [rootFolderURL, wallpapersFolderURL, mediaFolderURL, sceneBakesFolderURL]
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
    static let wallpaperDataSourceChanged = Notification.Name("wallpaperDataSourceChanged")
    static let appDidHideWindow = Notification.Name("appDidHideWindow")
    static let appShouldReleaseForegroundMemory = Notification.Name("appShouldReleaseForegroundMemory")
}
