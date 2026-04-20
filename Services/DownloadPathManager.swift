import Foundation

/// 下载路径管理器 - 统一管理壁纸和媒体的下载路径
/// 支持路径迁移检测，当用户手动移动文件时能够自动找到
/// 存储根目录固定为 Application Support 下 `WaifuX`，不读写系统「下载」等用户目录，避免隐私弹窗。
@MainActor
final class DownloadPathManager {
    static let shared = DownloadPathManager()

    /// 与设置中的开关一致：是否写入应用内媒体库（Application Support 下 `WaifuX`）。与系统「下载」文件夹无关。
    static let persistDownloadsToAppLibraryDefaultsKey = "save_to_downloads"

    private static let legacyCustomFolderPathKey = "download_folder_path"
    private static let legacyPermissionRequestedKey = "download_permission_requested"

    // MARK: - 文件夹结构
    /// 根目录: ~/Library/Application Support/WaifuX/（仅此一处，不再支持自定义到下载/文稿等目录）
    var rootFolderURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("WaifuX", isDirectory: true)
    }

    /// 壁纸目录: ~/Library/Application Support/WaifuX/Wallpapers/
    var wallpapersFolderURL: URL {
        rootFolderURL.appendingPathComponent("Wallpapers", isDirectory: true)
    }

    /// 媒体目录: ~/Library/Application Support/WaifuX/Media/
    var mediaFolderURL: URL {
        rootFolderURL.appendingPathComponent("Media", isDirectory: true)
    }

    /// Scene 离线烘焙 MP4（与 `Media` / `Wallpapers` 同级，随 `rootFolderURL` 迁移）
    var sceneBakesFolderURL: URL {
        rootFolderURL.appendingPathComponent("SceneBakes", isDirectory: true)
    }

    private init() {}

    /// 清除旧版本写入的「自定义保存目录」键，避免曾指向「下载」等路径时触发系统访问提示。
    func migrateLegacyCustomFolderPreferenceIfNeeded() {
        let d = UserDefaults.standard
        guard d.object(forKey: Self.legacyCustomFolderPathKey) != nil else { return }
        d.removeObject(forKey: Self.legacyCustomFolderPathKey)
        d.removeObject(forKey: Self.legacyPermissionRequestedKey)
        print("[DownloadPathManager] Cleared legacy custom folder keys; storage is Application Support/WaifuX only.")
    }

    // MARK: - 权限管理
    /// 确保应用数据目录（Application Support 下 `WaifuX`）可创建且可写。
    func ensureDownloadPermission() async -> Bool {
        createDirectoryStructure()
    }

    /// 应用库根目录是否可写（已创建或能创建）
    var hasValidPermission: Bool {
        let root = rootFolderURL
        let fm = FileManager.default
        if fm.fileExists(atPath: root.path) {
            return fm.isWritableFile(atPath: root.path)
        }
        return true
    }

    // MARK: - 目录创建
    /// 创建完整的目录结构；任一必需目录无法创建或不可写则返回 `false`。
    @discardableResult
    func createDirectoryStructure() -> Bool {
        let directories = [rootFolderURL, wallpapersFolderURL, mediaFolderURL, sceneBakesFolderURL]
        let fm = FileManager.default
        var ok = true

        for directory in directories {
            if !fm.fileExists(atPath: directory.path) {
                do {
                    try fm.createDirectory(
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
            if fm.fileExists(atPath: directory.path), !fm.isWritableFile(atPath: directory.path) {
                print("[DownloadPathManager] Directory not writable: \(directory.path)")
                ok = false
            }
        }
        return ok
    }

    /// 确保目录结构存在（异步版本）
    func ensureDirectoryStructure() async -> Bool {
        await ensureDownloadPermission()
    }

    // MARK: - 路径解析
    /// 内容类型
    enum ContentType {
        case wallpaper    // 静态壁纸图片
        case media        // 动态媒体（视频等）
    }

    /// 为目标内容获取正确的下载目录
    func destinationFolder(for type: ContentType) -> URL {
        switch type {
        case .wallpaper:
            return wallpapersFolderURL
        case .media:
            return mediaFolderURL
        }
    }

    /// 生成壁纸文件的完整路径
    /// - Parameters:
    ///   - id: 壁纸ID
    ///   - fileExtension: 文件扩展名
    /// - Returns: 目标文件URL
    func wallpaperFileURL(id: String, fileExtension: String) -> URL {
        let fileName = "wallhaven-\(id).\(fileExtension)"
        return wallpapersFolderURL.appendingPathComponent(fileName)
    }

    /// 生成媒体文件的完整路径
    /// - Parameters:
    ///   - slug: 媒体slug
    ///   - label: 质量标签
    ///   - fileExtension: 文件扩展名
    /// - Returns: 目标文件URL
    func mediaFileURL(slug: String, label: String, fileExtension: String) -> URL {
        let safeSlug = slug
            .replacingOccurrences(of: #"[^a-zA-Z0-9\-]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let safeLabel = label.lowercased().replacingOccurrences(of: " ", with: "-")
        let fileName = "motionbgs-\(safeSlug)-\(safeLabel).\(fileExtension)"
        return mediaFolderURL.appendingPathComponent(fileName)
    }

    // MARK: - 路径检测与迁移
    /// 文件位置信息
    struct FileLocation {
        let url: URL
        let foundIn: LocationType

        enum LocationType {
            case wallpapersFolder      // 新位置：壁纸文件夹
            case mediaFolder           // 新位置：媒体文件夹
            case legacyRootFolder      // 旧位置：根目录
            case notFound             // 未找到
        }
    }

    /// 查找壁纸文件（仅检测新位置）
    func locateWallpaperFile(id: String, fileExtension: String) -> FileLocation {
        let fileName = "wallhaven-\(id).\(fileExtension)"
        let location = wallpapersFolderURL.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: location.path) {
            return FileLocation(url: location, foundIn: .wallpapersFolder)
        }
        return FileLocation(url: location, foundIn: .notFound)
    }

    /// 查找媒体文件（仅检测新位置）
    func locateMediaFile(slug: String, label: String, fileExtension: String) -> FileLocation {
        let safeSlug = slug
            .replacingOccurrences(of: #"[^a-zA-Z0-9\-]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let safeLabel = label.lowercased().replacingOccurrences(of: " ", with: "-")
        let fileName = "motionbgs-\(safeSlug)-\(safeLabel).\(fileExtension)"
        let location = mediaFolderURL.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: location.path) {
            return FileLocation(url: location, foundIn: .mediaFolder)
        }
        return FileLocation(url: location, foundIn: .notFound)
    }

    /// 查找任意文件（通过文件名，仅检测新位置）
    /// - Parameter fileName: 文件名
    /// - Returns: 文件位置信息
    func locateFile(named fileName: String) -> FileLocation {
        // 1. 检查壁纸文件夹
        let wallpaperLocation = wallpapersFolderURL.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: wallpaperLocation.path) {
            return FileLocation(url: wallpaperLocation, foundIn: .wallpapersFolder)
        }

        // 2. 检查媒体文件夹
        let mediaLocation = mediaFolderURL.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: mediaLocation.path) {
            return FileLocation(url: mediaLocation, foundIn: .mediaFolder)
        }

        // 3. 未找到，返回默认位置（根据文件名推断）
        let defaultURL = inferDefaultLocation(for: fileName)
        return FileLocation(url: defaultURL, foundIn: .notFound)
    }

    /// 根据文件名推断默认存储位置
    private func inferDefaultLocation(for fileName: String) -> URL {
        if fileName.hasPrefix("wallhaven-") {
            return wallpapersFolderURL.appendingPathComponent(fileName)
        } else if fileName.hasPrefix("motionbgs-") {
            return mediaFolderURL.appendingPathComponent(fileName)
        } else {
            // 未知类型，默认放到根目录
            return rootFolderURL.appendingPathComponent(fileName)
        }
    }

    // MARK: - 下载记录路径更新
    /// 更新下载记录的本地文件路径
    /// 当检测到文件在新位置时，更新数据库记录
    func updateDownloadRecordPath(recordID: String, newPath: String) {
        // 这个方法将由 LibraryService 调用
        // 用于同步数据库中的路径信息
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
}
