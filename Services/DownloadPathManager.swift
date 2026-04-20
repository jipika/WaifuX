import Foundation

/// 下载路径管理器 - 统一管理壁纸和媒体的下载路径
/// 支持路径迁移检测，当用户手动移动文件时能够自动找到
/// 集成下载权限管理
@MainActor
final class DownloadPathManager {
    static let shared = DownloadPathManager()
    
    // 权限管理器
    private let permissionManager = DownloadPermissionManager.shared

    // MARK: - 文件夹结构
    /// 根目录: ~/Library/Application Support/WaifuX/ 或用户选择的目录
    var rootFolderURL: URL {
        if let permittedURL = permissionManager.currentFolderURL,
           permittedURL.path != legacyFolderURL.path,
           !permittedURL.path.hasPrefix(legacyFolderURL.path) {
            return permittedURL
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
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

    /// 旧版统一目录（仅作参考，不再自动读取）
    var legacyFolderURL: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("WallHaven", isDirectory: true)
    }

    private init() {
        // 不在初始化时创建目录，等待权限确认后再创建
    }

    // MARK: - 权限管理
    /// 确保下载权限有效（无沙箱版本：直接创建目录并返回）
    /// - Returns: 是否有有效权限（无沙箱下始终返回 true）
    func ensureDownloadPermission() async -> Bool {
        // 无沙箱模式：直接创建目录结构，不需要权限弹窗
        createDirectoryStructure()
        return true
    }
    
    /// 请求下载文件夹权限
    /// - Returns: 授权的文件夹URL
    func requestDownloadFolder() async -> URL? {
        await permissionManager.getDownloadFolder(requestIfNeeded: true)
    }
    
    /// 检查是否有有效权限
    var hasValidPermission: Bool {
        permissionManager.hasValidPermission
    }

    // MARK: - 目录创建
    /// 创建完整的目录结构（需要先确保有权限）
    func createDirectoryStructure() {
        let directories = [rootFolderURL, wallpapersFolderURL, mediaFolderURL, sceneBakesFolderURL]

        for directory in directories {
            if !FileManager.default.fileExists(atPath: directory.path) {
                do {
                    try FileManager.default.createDirectory(
                        at: directory,
                        withIntermediateDirectories: true,
                        attributes: nil
                    )
                    print("[DownloadPathManager] Created directory: \(directory.path)")
                } catch {
                    print("[DownloadPathManager] Failed to create directory: \(error)")
                }
            }
        }
    }
    
    /// 确保目录结构存在（异步版本，会先检查权限）
    func ensureDirectoryStructure() async -> Bool {
        // 确保有权限
        guard await ensureDownloadPermission() else {
            print("[DownloadPathManager] No download permission")
            return false
        }
        
        // 创建目录
        createDirectoryStructure()
        return true
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
