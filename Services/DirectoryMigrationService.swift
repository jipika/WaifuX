import Foundation

/// 目录迁移进度回调信息
struct MigrationProgress {
    let currentFileName: String
    let processedCount: Int
    let totalCount: Int
    let fractionCompleted: Double
}

/// 目录迁移结果
enum MigrationResult {
    case success(movedFiles: Int, deletedFiles: Int)
    case partial(successCount: Int, failCount: Int, errors: [String])
    case failure(error: String)
}

@MainActor
final class DirectoryMigrationService {
    static let shared = DirectoryMigrationService()

    private let fileManager = FileManager.default

    private init() {}

    /// 执行目录迁移：将旧 WaifuX 目录下的所有文件复制到新目录，并更新下载记录路径
    /// - Parameters:
    ///   - oldRoot: 旧根目录（包含 Wallpapers、Media、SceneBakes 等子目录）
    ///   - newRoot: 新根目录（会在其下创建相同的子目录结构）
    ///   - progressHandler: 进度回调（在主线程序运行）
    /// - Returns: 迁移结果
    func migrate(
        from oldRoot: URL,
        to newRoot: URL,
        progressHandler: @escaping @MainActor (MigrationProgress) -> Void
    ) async -> MigrationResult {
        // 1. 收集所有需要迁移的文件
        let filesToMigrate = collectFiles(at: oldRoot)
        let totalCount = filesToMigrate.count
        guard totalCount > 0 else {
            // 没有文件，直接更新目录设置即可
            return .success(movedFiles: 0, deletedFiles: 0)
        }

        var successCount = 0
        var failCount = 0
        var errors: [String] = []

        // 2. 逐个复制文件
        for (index, sourceURL) in filesToMigrate.enumerated() {
            let relativePath = relativePath(from: sourceURL, base: oldRoot)
            let destURL = newRoot.appendingPathComponent(relativePath)
            let fileName = sourceURL.lastPathComponent

            let progress = MigrationProgress(
                currentFileName: fileName,
                processedCount: index,
                totalCount: totalCount,
                fractionCompleted: Double(index) / Double(totalCount)
            )
            await MainActor.run {
                progressHandler(progress)
            }

            do {
                // 确保目标目录存在
                let destDir = destURL.deletingLastPathComponent()
                if !fileManager.fileExists(atPath: destDir.path) {
                    try fileManager.createDirectory(
                        at: destDir,
                        withIntermediateDirectories: true,
                        attributes: nil
                    )
                }

                // 复制文件
                if fileManager.fileExists(atPath: destURL.path) {
                    try fileManager.removeItem(at: destURL)
                }
                try fileManager.copyItem(at: sourceURL, to: destURL)
                successCount += 1
            } catch {
                failCount += 1
                errors.append("\(fileName): \(error.localizedDescription)")
                print("[DirectoryMigrationService] Failed to migrate \(sourceURL.path): \(error)")
            }
        }

        // 3. 更新所有下载记录路径
        await updateDownloadRecordPaths(from: oldRoot, to: newRoot)

        // 4. 清理旧文件
        var deletedCount = 0
        for sourceURL in filesToMigrate {
            do {
                try fileManager.removeItem(at: sourceURL)
                deletedCount += 1
            } catch {
                print("[DirectoryMigrationService] Failed to delete old file: \(sourceURL.path)")
            }
        }

        // 5. 尝试删除旧的空目录
        cleanupEmptyDirectories(at: oldRoot)

        let finalProgress = MigrationProgress(
            currentFileName: "完成",
            processedCount: totalCount,
            totalCount: totalCount,
            fractionCompleted: 1.0
        )
        await MainActor.run {
            progressHandler(finalProgress)
        }

        if failCount == 0 {
            return .success(movedFiles: successCount, deletedFiles: deletedCount)
        } else {
            return .partial(successCount: successCount, failCount: failCount, errors: errors)
        }
    }

    // MARK: - Private

    /// 递归收集目录下所有文件（不包括隐藏文件和 .DS_Store）
    private func collectFiles(at root: URL) -> [URL] {
        var files: [URL] = []
        guard fileManager.fileExists(atPath: root.path) else { return files }

        if let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator {
                let name = url.lastPathComponent
                if name == ".DS_Store" { continue }
                if let isFile = try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile,
                   isFile == true {
                    files.append(url)
                }
            }
        }
        return files
    }

    /// 计算相对于 base 的路径
    private func relativePath(from url: URL, base: URL) -> String {
        let basePath = base.path.hasSuffix("/") ? base.path : base.path + "/"
        let fullPath = url.path
        if fullPath.hasPrefix(basePath) {
            return String(fullPath.dropFirst(basePath.count))
        }
        return url.lastPathComponent
    }

    /// 更新所有下载记录中的路径
    private func updateDownloadRecordPaths(from oldRoot: URL, to newRoot: URL) async {
        let oldPath = oldRoot.path
        let newPath = newRoot.path

        MediaLibraryService.shared.bulkUpdateDownloadPaths(oldPrefix: oldPath, newPrefix: newPath)
        WallpaperLibraryService.shared.bulkUpdateDownloadPaths(oldPrefix: oldPath, newPrefix: newPath)
        VideoWallpaperManager.shared.bulkUpdatePaths(oldPrefix: oldPath, newPrefix: newPath)
        WallpaperEngineXBridge.shared.bulkUpdatePaths(oldPrefix: oldPath, newPrefix: newPath)
        await UserLibrary.shared.bulkUpdatePaths(oldPrefix: oldPath, newPrefix: newPath)
        VideoThumbnailCache.shared.migrateCacheKeys(fromOldPrefix: oldPath, toNewPrefix: newPath)

        print("[DirectoryMigrationService] Updated all persisted paths from \(oldPath) to \(newPath)")
    }

    /// 从可能包含 file:// 前缀的字符串中提取纯路径
    private static func pathString(_ string: String) -> String {
        if let url = URL(string: string), url.isFileURL { return url.path }
        return string
    }

    /// 修复之前迁移代码有 bug 时遗留的孤儿路径（启动时调用）
    /// 若当前使用了自定义目录，但持久化记录中仍有路径指向默认 App Support 目录，则自动修复。
    func repairOrphanedPathsIfNeeded() async {
        guard DownloadPathManager.shared.hasCustomRoot else { return }

        let fileManager = FileManager.default
        let defaultRoot = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("WaifuX", isDirectory: true)
        let currentRoot = DownloadPathManager.shared.rootFolderURL

        let oldPath = defaultRoot.path
        let newPath = currentRoot.path

        guard oldPath != newPath else { return }

        // 检查是否有任何记录仍指向旧路径（简单抽样检查，避免无意义的全量修复）
        var needsRepair = false
        for record in MediaLibraryService.shared.downloadRecords {
            if record.localFilePath.hasPrefix(oldPath) {
                needsRepair = true; break
            }
            if record.item.pageURL.path.hasPrefix(oldPath) {
                needsRepair = true; break
            }
            if let artifact = record.sceneBakeArtifact, artifact.videoPath.hasPrefix(oldPath) {
                needsRepair = true; break
            }
            if let eligibility = record.sceneBakeEligibility, eligibility.contentRootPath.hasPrefix(oldPath) {
                needsRepair = true; break
            }
        }
        if !needsRepair {
            for record in WallpaperLibraryService.shared.downloadRecords {
                if record.localFilePath.hasPrefix(oldPath) {
                    needsRepair = true; break
                }
                if Self.pathString(record.wallpaper.url).hasPrefix(oldPath) || Self.pathString(record.wallpaper.path).hasPrefix(oldPath) {
                    needsRepair = true; break
                }
            }
        }
        if !needsRepair {
            for record in MediaLibraryService.shared.favoriteRecords {
                if record.item.pageURL.path.hasPrefix(oldPath) {
                    needsRepair = true; break
                }
            }
        }
        if !needsRepair {
            for record in WallpaperLibraryService.shared.favoriteRecords {
                if Self.pathString(record.wallpaper.url).hasPrefix(oldPath) || Self.pathString(record.wallpaper.path).hasPrefix(oldPath) {
                    needsRepair = true; break
                }
            }
        }

        guard needsRepair else { return }

        print("[DirectoryMigrationService] Repairing orphaned paths from \(oldPath) to \(newPath)")
        MediaLibraryService.shared.bulkUpdateDownloadPaths(oldPrefix: oldPath, newPrefix: newPath)
        WallpaperLibraryService.shared.bulkUpdateDownloadPaths(oldPrefix: oldPath, newPrefix: newPath)
        VideoWallpaperManager.shared.bulkUpdatePaths(oldPrefix: oldPath, newPrefix: newPath)
        WallpaperEngineXBridge.shared.bulkUpdatePaths(oldPrefix: oldPath, newPrefix: newPath)
        await UserLibrary.shared.bulkUpdatePaths(oldPrefix: oldPath, newPrefix: newPath)
        VideoThumbnailCache.shared.migrateCacheKeys(fromOldPrefix: oldPath, toNewPrefix: newPath)
        print("[DirectoryMigrationService] Orphaned path repair completed")
    }

    /// 清理空目录
    private func cleanupEmptyDirectories(at root: URL) {
        guard fileManager.fileExists(atPath: root.path) else { return }

        func cleanup(_ url: URL) {
            guard fileManager.fileExists(atPath: url.path) else { return }
            do {
                let contents = try fileManager.contentsOfDirectory(atPath: url.path)
                for name in contents {
                    let child = url.appendingPathComponent(name)
                    var isDir: ObjCBool = false
                    if fileManager.fileExists(atPath: child.path, isDirectory: &isDir), isDir.boolValue {
                        cleanup(child)
                    }
                }
                // 再次检查是否为空
                let remaining = try fileManager.contentsOfDirectory(atPath: url.path)
                if remaining.isEmpty {
                    try fileManager.removeItem(at: url)
                }
            } catch {
                print("[DirectoryMigrationService] Cleanup error at \(url.path): \(error)")
            }
        }

        cleanup(root)
    }
}
