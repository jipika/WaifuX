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
    /// 根目录: ~/Downloads/WallHaven/ 或用户选择的目录
    var rootFolderURL: URL {
        if let permittedURL = permissionManager.currentFolderURL {
            return permittedURL
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("WallHaven", isDirectory: true)
    }

    /// 壁纸目录: ~/Downloads/WallHaven/Wallpapers/
    var wallpapersFolderURL: URL {
        rootFolderURL.appendingPathComponent("Wallpapers", isDirectory: true)
    }

    /// 媒体目录: ~/Downloads/WallHaven/Media/
    var mediaFolderURL: URL {
        rootFolderURL.appendingPathComponent("Media", isDirectory: true)
    }

    /// 旧版统一目录（用于迁移检测）
    var legacyFolderURL: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("WallHaven", isDirectory: true)
    }

    private init() {
        // 不在初始化时创建目录，等待权限确认后再创建
    }

    // MARK: - 权限管理
    /// 确保下载权限有效
    /// - Returns: 是否有有效权限
    func ensureDownloadPermission() async -> Bool {
        // 尝试开始访问安全作用域
        if permissionManager.startAccessingSecurityScope() {
            return true
        }
        
        // 请求权限
        return await permissionManager.ensurePermission()
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
        let directories = [rootFolderURL, wallpapersFolderURL, mediaFolderURL]

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

    /// 查找壁纸文件（自动检测多个可能位置）
    /// 搜索顺序: 1. 新位置 -> 2. 旧位置 -> 3. 未找到
    func locateWallpaperFile(id: String, fileExtension: String) -> FileLocation {
        let fileName = "wallhaven-\(id).\(fileExtension)"

        // 1. 检查新位置
        let newLocation = wallpapersFolderURL.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: newLocation.path) {
            return FileLocation(url: newLocation, foundIn: .wallpapersFolder)
        }

        // 2. 检查旧位置（根目录）
        let legacyLocation = legacyFolderURL.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: legacyLocation.path) {
            return FileLocation(url: legacyLocation, foundIn: .legacyRootFolder)
        }

        // 3. 未找到
        return FileLocation(
            url: wallpapersFolderURL.appendingPathComponent(fileName),
            foundIn: .notFound
        )
    }

    /// 查找媒体文件（自动检测多个可能位置）
    /// 搜索顺序: 1. 新位置 -> 2. 旧位置 -> 3. 未找到
    func locateMediaFile(slug: String, label: String, fileExtension: String) -> FileLocation {
        let safeSlug = slug
            .replacingOccurrences(of: #"[^a-zA-Z0-9\-]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let safeLabel = label.lowercased().replacingOccurrences(of: " ", with: "-")
        let fileName = "motionbgs-\(safeSlug)-\(safeLabel).\(fileExtension)"

        // 1. 检查新位置
        let newLocation = mediaFolderURL.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: newLocation.path) {
            return FileLocation(url: newLocation, foundIn: .mediaFolder)
        }

        // 2. 检查旧位置（根目录）
        let legacyLocation = legacyFolderURL.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: legacyLocation.path) {
            return FileLocation(url: legacyLocation, foundIn: .legacyRootFolder)
        }

        // 3. 未找到
        return FileLocation(
            url: mediaFolderURL.appendingPathComponent(fileName),
            foundIn: .notFound
        )
    }

    /// 查找任意文件（通过文件名）
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

        // 3. 检查旧位置
        let legacyLocation = legacyFolderURL.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: legacyLocation.path) {
            return FileLocation(url: legacyLocation, foundIn: .legacyRootFolder)
        }

        // 4. 未找到，返回默认位置（根据文件名推断）
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

    // MARK: - 批量扫描
    /// 扫描旧目录中的所有文件，返回可以迁移的文件列表
    func scanLegacyFiles() -> [URL] {
        guard FileManager.default.fileExists(atPath: legacyFolderURL.path) else {
            return []
        }

        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: legacyFolderURL,
                includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles
            )
            return contents.filter { !$0.hasDirectoryPath }
        } catch {
            print("[DownloadPathManager] Failed to scan legacy folder: \(error)")
            return []
        }
    }

    /// 自动迁移旧目录中的文件到新目录结构
    /// - Returns: 迁移结果 (成功数量, 失败数量)
    @discardableResult
    func migrateLegacyFiles() -> (success: Int, failed: Int) {
        let legacyFiles = scanLegacyFiles()
        guard !legacyFiles.isEmpty else { return (0, 0) }

        var successCount = 0
        var failedCount = 0

        for fileURL in legacyFiles {
            let fileName = fileURL.lastPathComponent
            let destinationURL: URL

            // 根据文件名判断目标位置
            if fileName.hasPrefix("wallhaven-") {
                destinationURL = wallpapersFolderURL.appendingPathComponent(fileName)
            } else if fileName.hasPrefix("motionbgs-") {
                destinationURL = mediaFolderURL.appendingPathComponent(fileName)
            } else {
                // 未知类型，跳过或放入根目录
                continue
            }

            // 如果目标已存在，跳过
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                continue
            }

            do {
                try FileManager.default.moveItem(at: fileURL, to: destinationURL)
                print("[DownloadPathManager] Migrated: \(fileName) -> \(destinationURL.path)")
                successCount += 1
            } catch {
                print("[DownloadPathManager] Failed to migrate \(fileName): \(error)")
                failedCount += 1
            }
        }

        return (successCount, failedCount)
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
}
