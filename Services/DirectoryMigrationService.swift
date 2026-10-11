import Foundation

// MARK: - 迁移阶段

/// 迁移所处阶段（持久化到 UserDefaults，用于中断恢复）
enum MigrationPhase: String, Codable {
    case idle
    case copying
    case updatingPaths
    case deleting
}

/// 迁移阶段信息（用于 UI 展示）
enum MigrationStep: Codable, Sendable {
    case copying
    case updatingPaths
    case deleting
    case cleanup

    var description: String {
        switch self {
        case .copying: return NSLocalizedString("migration.step.copying", comment: "")
        case .updatingPaths: return NSLocalizedString("migration.step.updatingPaths", comment: "")
        case .deleting: return NSLocalizedString("migration.step.deleting", comment: "")
        case .cleanup: return NSLocalizedString("migration.step.cleanup", comment: "")
        }
    }

    /// 该阶段在全流程中的权重占比
    var weight: Double {
        switch self {
        case .copying: return 0.70
        case .updatingPaths: return 0.10
        case .deleting: return 0.15
        case .cleanup: return 0.05
        }
    }
}

// MARK: - 进度与结果

struct MigrationProgress: Codable, Sendable {
    let step: MigrationStep
    let currentFileName: String
    let processedCount: Int
    let totalCount: Int
    /// 全流程百分比（0.0 ~ 1.0），综合所有阶段权重
    let fractionCompleted: Double
}

enum MigrationResult: Codable, Sendable {
    case success(movedFiles: Int, deletedFiles: Int)
    case partial(successCount: Int, failCount: Int, errors: [String])
    case failure(error: String)
}

// MARK: - 持久化状态

/// 写入 UserDefaults 的迁移快照，用于中断恢复
private struct MigrationStateRecord: Codable {
    let phase: MigrationPhase
    let oldPath: String
    let newPath: String
    /// 复制阶段已成功处理的文件数（用于恢复时跳过已复制文件）
    var copiedFileCount: Int
}

// MARK: - Service

/// 目录迁移服务。
/// 路径记录更新在 MainActor；文件枚举/复制/删除在后台线程执行，避免大库迁移卡死 UI。
@MainActor
final class DirectoryMigrationService {
    static let shared = DirectoryMigrationService()

    private let stateKey = "migration_state_v1"
    private(set) var isMigrating = false
    /// 每处理多少个文件回一次进度 + yield（平衡 UI 刷新与调度开销）
    private static let progressStride = 4

    private var remoteProgressHandler: (@MainActor (MigrationProgress) -> Void)?
    private init() {
        if BackgroundRuntimeRole.isRemoteUI {
            BackgroundRuntimeBridge.observe { [weak self] snapshot in
                guard let bytes = snapshot["migration"] as? Data, let progress = try? JSONDecoder().decode(MigrationProgress.self, from: bytes) else { return }
                self?.remoteProgressHandler?(progress)
            }
        }
    }

    // MARK: - Public API

    /// 执行目录迁移
    func migrate(
        from oldRoot: URL,
        to newRoot: URL,
        progressHandler: @escaping @MainActor (MigrationProgress) -> Void
    ) async -> MigrationResult {
        if BackgroundRuntimeRole.isRemoteUI {
            remoteProgressHandler = progressHandler
            defer { remoteProgressHandler = nil }
            do {
                return try await BackgroundRuntimeBridge.requestCodable("directory.migrate.wait", arguments: BackgroundPropertyList.encode(["old": oldRoot.absoluteString, "new": newRoot.absoluteString]), resultKey: "result", as: MigrationResult.self)
            } catch { return .failure(error: error.localizedDescription) }
        }

        guard !isMigrating else { return .failure(error: "目录迁移正在进行，请等待完成") }
        let source = oldRoot.resolvingSymlinksInPath().standardizedFileURL.path
        let destination = newRoot.resolvingSymlinksInPath().standardizedFileURL.path
        guard source != destination,
              !destination.hasPrefix(source + "/"),
              !source.hasPrefix(destination + "/") else {
            return .failure(error: "原目录与目标目录不能相同或相互包含")
        }
        isMigrating = true
        defer { isMigrating = false }

        let oldPath = oldRoot.path
        let newPath = newRoot.path

        // 1. 后台枚举文件，避免大目录扫描阻塞主线程
        await reportProgress(
            step: .copying, fileName: "",
            processed: 0, total: 0,
            fraction: 0,
            handler: progressHandler
        )
        let filesToMigrate = await Task.detached(priority: .userInitiated) {
            Self.collectFiles(at: oldRoot)
        }.value
        let totalCount = filesToMigrate.count
        guard totalCount > 0 else {
            clearMigrationState()
            return .success(movedFiles: 0, deletedFiles: 0)
        }

        // 2. 持久化迁移状态
        saveMigrationState(MigrationStateRecord(
            phase: .copying,
            oldPath: oldPath,
            newPath: newPath,
            copiedFileCount: 0
        ))
        await reportProgress(
            step: .copying, fileName: "",
            processed: 0, total: totalCount,
            fraction: 0,
            handler: progressHandler
        )

        // ── 阶段 A：复制文件（后台 I/O，定期回主线程更新进度）──
        var successCount = 0
        var failCount = 0
        var errors: [String] = []
        let batchSize = Self.progressStride

        for start in Swift.stride(from: 0, to: totalCount, by: batchSize) {
            let end = min(start + batchSize, totalCount)
            let batch = Array(filesToMigrate[start..<end])

            let batchOutcome = await Task.detached(priority: .userInitiated) {
                Self.copyBatch(batch, from: oldRoot, to: newRoot)
            }.value

            successCount += batchOutcome.successCount
            failCount += batchOutcome.failCount
            errors.append(contentsOf: batchOutcome.errors)

            let processed = end
            let fileName = batch.last?.lastPathComponent ?? ""
            let phaseProgress = Double(processed) / Double(totalCount)
            await reportProgress(
                step: .copying, fileName: fileName,
                processed: processed, total: totalCount,
                fraction: phaseProgress * MigrationStep.copying.weight,
                handler: progressHandler
            )

            // 每约 50 个文件刷新一次持久化断点
            if processed % 50 < batchSize || processed == totalCount {
                updateCopiedCount(successCount)
            }
            await Task.yield()
        }
        updateCopiedCount(successCount)

        // A partial copy is not a committed migration. Keep every library and
        // playback reference on the readable source until the full copy succeeds.
        // The destination copies can be reused on retry; the sources stay intact.
        if failCount > 0 {
            clearMigrationState()
            print(
                "[DirectoryMigrationService] Path updates and deletion skipped: "
                    + "\(failCount)/\(totalCount) file(s) failed to copy; source left intact"
            )
            return .partial(successCount: successCount, failCount: failCount, errors: errors)
        }

        // ── 阶段 B：更新路径记录 ──
        saveMigrationState(MigrationStateRecord(
            phase: .updatingPaths,
            oldPath: oldPath, newPath: newPath,
            copiedFileCount: successCount
        ))
        await reportProgress(
            step: .updatingPaths, fileName: "",
            processed: 0, total: 1,
            fraction: MigrationStep.copying.weight,
            handler: progressHandler
        )
        await updateDownloadRecordPaths(from: oldRoot, to: newRoot)
        await reportProgress(
            step: .updatingPaths, fileName: "",
            processed: 1, total: 1,
            fraction: MigrationStep.copying.weight + MigrationStep.updatingPaths.weight,
            handler: progressHandler
        )

        // ── 阶段 C：删除旧文件（后台 I/O）──
        // Copy failures return before any paths are committed or sources deleted.

        saveMigrationState(MigrationStateRecord(
            phase: .deleting,
            oldPath: oldPath, newPath: newPath,
            copiedFileCount: successCount
        ))
        var deletedCount = 0
        let deleteBase = MigrationStep.copying.weight + MigrationStep.updatingPaths.weight

        for start in Swift.stride(from: 0, to: totalCount, by: batchSize) {
            let end = min(start + batchSize, totalCount)
            let batch = Array(filesToMigrate[start..<end])

            let batchDeleted = await Task.detached(priority: .userInitiated) {
                Self.deleteVerifiedBatch(batch, from: oldRoot, verifiedAgainst: newRoot)
            }.value
            deletedCount += batchDeleted

            let processed = end
            let fileName = batch.last?.lastPathComponent ?? ""
            let deleteProgress = Double(processed) / Double(totalCount)
            await reportProgress(
                step: .deleting, fileName: fileName,
                processed: processed, total: totalCount,
                fraction: deleteBase + deleteProgress * MigrationStep.deleting.weight,
                handler: progressHandler
            )
            await Task.yield()
        }

        // ── 阶段 D：清理空目录 ──
        await reportProgress(
            step: .cleanup, fileName: "",
            processed: 0, total: 1,
            fraction: deleteBase + MigrationStep.deleting.weight,
            handler: progressHandler
        )
        await Task.detached(priority: .userInitiated) {
            Self.cleanupEmptyDirectories(at: oldRoot)
        }.value
        await reportProgress(
            step: .cleanup, fileName: "",
            processed: 1, total: 1,
            fraction: 1.0,
            handler: progressHandler
        )

        // The target may be unplugged or modified after copying. Keep both
        // the remaining sources and the deletion checkpoint until verified.
        guard deletedCount == totalCount else {
            return .partial(successCount: successCount,
                            failCount: totalCount - deletedCount,
                            errors: ["部分原文件未删除：目标副本缺失、内容不同或删除失败，已保留原文件和恢复记录"])
        }
        clearMigrationState()
        return .success(movedFiles: successCount, deletedFiles: deletedCount)
    }

    // MARK: - 中断恢复（启动时调用）

    /// 检查是否有未完成的迁移，根据阶段决定回滚或继续
    func recoverIncompleteMigrationIfNeeded() async {
        guard BackgroundRuntimeRole.isHelper else { return }
        guard let record = loadMigrationState() else { return }

        let oldURL = URL(fileURLWithPath: record.oldPath)
        let newURL = URL(fileURLWithPath: record.newPath)

        switch record.phase {
        case .idle:
            clearMigrationState()

        case .copying, .updatingPaths:
            // 路径记录尚未全部更新（或还没到更新步骤），旧路径仍然有效
            // 策略：不清除 customRoot（因为新下载可能已写入新目录），
            //       而是重新执行一次完整迁移（复制是幂等的）
            print("[DirectoryMigrationService] Recovering incomplete migration (phase=\(record.phase.rawValue)), re-running migration")
            clearMigrationState()
            _ = await migrate(from: oldURL, to: newURL, progressHandler: { _ in })

        case .deleting:
            guard !isMigrating else { return }
            isMigrating = true
            defer { isMigrating = false }
            // The destination can disappear between sessions (for example an
            // unplugged drive). Verify each copy before deleting its source.
            print("[DirectoryMigrationService] Resuming deletion of old files at \(record.oldPath)")
            if await Self.deleteFilesAsync(at: oldURL, verifiedAgainst: newURL) {
                clearMigrationState()
            } else {
                print("[DirectoryMigrationService] Recovery kept source files and checkpoint: destination copy missing or different")
            }
        }
    }

    // MARK: - 修复孤儿路径

    func repairOrphanedPathsIfNeeded() async {
        guard BackgroundRuntimeRole.isHelper else { return }
        guard DownloadPathManager.shared.hasCustomRoot else { return }

        let defaultRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("WaifuX", isDirectory: true)
        let currentRoot = DownloadPathManager.shared.rootFolderURL

        let oldPath = defaultRoot.path
        let newPath = currentRoot.path
        guard oldPath != newPath else { return }

        var needsRepair = false
        for record in MediaLibraryService.shared.downloadRecords {
            if record.localFilePath.hasPrefix(oldPath) { needsRepair = true; break }
            if record.item.pageURL.path.hasPrefix(oldPath) { needsRepair = true; break }
            if let art = record.sceneBakeArtifact, art.videoPath.hasPrefix(oldPath) { needsRepair = true; break }
            if let el = record.sceneBakeEligibility, el.contentRootPath.hasPrefix(oldPath) { needsRepair = true; break }
        }
        if !needsRepair {
            for record in WallpaperLibraryService.shared.downloadRecords {
                if record.localFilePath.hasPrefix(oldPath) { needsRepair = true; break }
                if Self.pathString(record.wallpaper.url).hasPrefix(oldPath) || Self.pathString(record.wallpaper.path).hasPrefix(oldPath) {
                    needsRepair = true; break
                }
            }
        }
        if !needsRepair {
            for record in MediaLibraryService.shared.favoriteRecords {
                if record.item.pageURL.path.hasPrefix(oldPath) { needsRepair = true; break }
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

        print("[DirectoryMigrationService] Repairing orphaned paths: \(oldPath) -> \(newPath)")
        MediaLibraryService.shared.bulkUpdateDownloadPaths(oldPrefix: oldPath, newPrefix: newPath)
        WallpaperLibraryService.shared.bulkUpdateDownloadPaths(oldPrefix: oldPath, newPrefix: newPath)
        VideoWallpaperManager.shared.bulkUpdatePaths(oldPrefix: oldPath, newPrefix: newPath)
        WallpaperEngineXBridge.shared.bulkUpdatePaths(oldPrefix: oldPath, newPrefix: newPath)
        await UserLibrary.shared.bulkUpdatePaths(oldPrefix: oldPath, newPrefix: newPath)
        VideoThumbnailCache.shared.migrateCacheKeys(fromOldPrefix: oldPath, toNewPrefix: newPath)
        await PortraitBlurFillWallpaperService.shared.rebaseArtifacts(
            from: defaultRoot,
            to: currentRoot,
            derivedWallpapersDirectory: currentRoot
                .appendingPathComponent("DerivedWallpapers", isDirectory: true)
        )
        print("[DirectoryMigrationService] Orphaned path repair completed")
    }

    // MARK: - 数据修复

    struct RepairResult: Codable, Sendable {
        var repairedCount: Int = 0
        var removedCount: Int = 0
        var healthyCount: Int = 0
        var migratedCount: Int = 0
        var indexedCount: Int = 0
    }

    /// 修复已有下载记录的断裂路径，并显式扫描受管目录补建未知文件的记录。
    func repairBrokenRecords() async -> RepairResult {
        if BackgroundRuntimeRole.isRemoteUI {
            return (try? await BackgroundRuntimeBridge.requestCodable("directory.repair.wait", arguments: Data(), resultKey: "result", as: RepairResult.self)) ?? RepairResult()
        }
        let fm = FileManager.default
        var result = RepairResult()

        // 收集所有可能的根目录
        let currentRoot = DownloadPathManager.shared.rootFolderURL.path
        let defaultRoot = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("WaifuX").path
        let candidateRoots = Array(Set([currentRoot, defaultRoot])).filter { !$0.isEmpty }

        // ── 修复 MediaLibraryService ──
        for record in MediaLibraryService.shared.downloadRecords {
            guard record.isActive else { continue }
            let filePath = record.localFilePath

            if fm.fileExists(atPath: filePath) {
                result.healthyCount += 1
            } else if let sourcePath = findFileInCandidateRoots(
                originalPath: filePath, candidateRoots: candidateRoots, fm: fm
            ) {
                let finalPath = migrateFileToCurrentRoot(
                    sourcePath: sourcePath, currentRoot: currentRoot, fm: fm
                ) ?? sourcePath
                MediaLibraryService.shared.repairDownloadPath(itemID: record.item.id, newPath: finalPath)
                if finalPath != sourcePath {
                    result.migratedCount += 1
                } else {
                    result.repairedCount += 1
                }
                print("[Repair] Media repaired: \(filePath) -> \(finalPath)")
            } else {
                MediaLibraryService.shared.deactivateDownloadRecord(itemID: record.item.id)
                result.removedCount += 1
                print("[Repair] Media not found, deactivated: \(filePath)")
            }
        }
        MediaLibraryService.shared.persistDownloads()

        // ── 修复 WallpaperLibraryService ──
        for record in WallpaperLibraryService.shared.downloadRecords {
            guard record.isActive else { continue }
            let filePath = record.localFilePath

            if fm.fileExists(atPath: filePath) {
                result.healthyCount += 1
            } else if let sourcePath = findFileInCandidateRoots(
                originalPath: filePath, candidateRoots: candidateRoots, fm: fm
            ) {
                let finalPath = migrateFileToCurrentRoot(
                    sourcePath: sourcePath, currentRoot: currentRoot, fm: fm
                ) ?? sourcePath
                WallpaperLibraryService.shared.repairDownloadPath(recordID: record.id, newPath: finalPath)
                if finalPath != sourcePath {
                    result.migratedCount += 1
                } else {
                    result.repairedCount += 1
                }
                print("[Repair] Wallpaper repaired: \(filePath) -> \(finalPath)")
            } else {
                WallpaperLibraryService.shared.deactivateDownloadRecord(recordID: record.id)
                result.removedCount += 1
                print("[Repair] Wallpaper not found, deactivated: \(filePath)")
            }
        }
        WallpaperLibraryService.shared.persistDownloads()

        // 所有内容现在都应经由软件导入；这一步只在用户主动修复时运行，
        // 用于恢复旧版本、缓存损坏或迁移中断后遗留的未索引文件。
        let reindexResult = await LocalWallpaperScanner.shared.rebuildManagedLibraryIndex()
        result.indexedCount = reindexResult.totalIndexed

        print(
            "[Repair] Done: indexed=\(result.indexedCount), "
                + "repaired=\(result.repairedCount), migrated=\(result.migratedCount), "
                + "removed=\(result.removedCount), healthy=\(result.healthyCount)"
        )
        return result
    }

    /// 尝试在候选根目录中找到对应文件
    private func findFileInCandidateRoots(originalPath: String, candidateRoots: [String], fm: FileManager) -> String? {
        for root in candidateRoots {
            let rootWithSlash = root.hasSuffix("/") ? root : root + "/"
            if originalPath.hasPrefix(rootWithSlash) { continue }
            if let range = originalPath.range(of: "/WaifuX/") {
                let relativePath = String(originalPath[range.upperBound...])
                let candidate = rootWithSlash + relativePath
                if fm.fileExists(atPath: candidate) {
                    return candidate
                }
            }
        }
        return nil
    }

    /// 尝试将文件从旧位置迁移到当前下载根目录
    /// - Returns: 迁移后的新路径，若已在当前目录或迁移失败则返回 nil
    private func migrateFileToCurrentRoot(sourcePath: String, currentRoot: String, fm: FileManager) -> String? {
        let rootWithSlash = currentRoot.hasSuffix("/") ? currentRoot : currentRoot + "/"
        if sourcePath.hasPrefix(rootWithSlash) { return nil }

        guard let range = sourcePath.range(of: "/WaifuX/") else { return nil }
        let relativePath = String(sourcePath[range.upperBound...])
        let targetPath = rootWithSlash + relativePath

        guard !fm.fileExists(atPath: targetPath) else { return targetPath }

        let targetDir = (targetPath as NSString).deletingLastPathComponent
        do {
            try fm.createDirectory(atPath: targetDir, withIntermediateDirectories: true, attributes: nil)
            try fm.moveItem(atPath: sourcePath, toPath: targetPath)
            print("[Repair] Migrated file: \(sourcePath) -> \(targetPath)")
            return targetPath
        } catch {
            print("[Repair] Failed to migrate file: \(sourcePath) -> \(targetPath): \(error)")
            return nil
        }
    }

    // MARK: - Private

    private func updateDownloadRecordPaths(from oldRoot: URL, to newRoot: URL) async {
        let oldPath = oldRoot.path
        let newPath = newRoot.path
        MediaLibraryService.shared.bulkUpdateDownloadPaths(oldPrefix: oldPath, newPrefix: newPath)
        WallpaperLibraryService.shared.bulkUpdateDownloadPaths(oldPrefix: oldPath, newPrefix: newPath)
        VideoWallpaperManager.shared.bulkUpdatePaths(oldPrefix: oldPath, newPrefix: newPath)
        WallpaperEngineXBridge.shared.bulkUpdatePaths(oldPrefix: oldPath, newPrefix: newPath)
        await UserLibrary.shared.bulkUpdatePaths(oldPrefix: oldPath, newPrefix: newPath)
        VideoThumbnailCache.shared.migrateCacheKeys(fromOldPrefix: oldPath, toNewPrefix: newPath)
        await PortraitBlurFillWallpaperService.shared.rebaseArtifacts(
            from: URL(fileURLWithPath: oldPath),
            to: URL(fileURLWithPath: newPath),
            derivedWallpapersDirectory: URL(fileURLWithPath: newPath)
                .appendingPathComponent("DerivedWallpapers", isDirectory: true)
        )
        print("[DirectoryMigrationService] Updated all persisted paths: \(oldPath) -> \(newPath)")
    }

    /// 回到 MainActor 推送进度；async 调用点会在此让出 run loop，SwiftUI 才能刷新。
    private func reportProgress(
        step: MigrationStep, fileName: String,
        processed: Int, total: Int, fraction: Double,
        handler: @escaping @MainActor (MigrationProgress) -> Void
    ) async {
        let progress = MigrationProgress(
            step: step,
            currentFileName: fileName,
            processedCount: processed,
            totalCount: total,
            fractionCompleted: min(max(fraction, 0), 1.0)
        )
        handler(progress)
    }

    // MARK: - 状态持久化

    private func saveMigrationState(_ record: MigrationStateRecord) {
        if let data = try? JSONEncoder().encode(record) {
            WaifuXPreferences.shared.set(data, forKey: stateKey)
        }
    }

    private func loadMigrationState() -> MigrationStateRecord? {
        guard let data = WaifuXPreferences.shared.data(forKey: stateKey) else { return nil }
        return try? JSONDecoder().decode(MigrationStateRecord.self, from: data)
    }

    private func clearMigrationState() {
        WaifuXPreferences.shared.removeObject(forKey: stateKey)
    }

    private func updateCopiedCount(_ count: Int) {
        guard var record = loadMigrationState() else { return }
        record.copiedFileCount = count
        saveMigrationState(record)
    }

    // MARK: - 后台文件操作（非 MainActor，可在 Task.detached 中调用）

    private struct CopyBatchOutcome: Sendable {
        var successCount: Int = 0
        var failCount: Int = 0
        var errors: [String] = []
    }

    /// 后台异步删除目录下所有文件（不阻塞主线程）
    private nonisolated static func deleteFilesAsync(at root: URL, verifiedAgainst destination: URL) async -> Bool {
        let files = collectFiles(at: root)
        let stride = 16
        var complete = true
        for start in Swift.stride(from: 0, to: files.count, by: stride) {
            let end = min(start + stride, files.count)
            let batch = Array(files[start..<end])
            let deleted = await Task.detached(priority: .utility) {
                Self.deleteVerifiedBatch(batch, from: root, verifiedAgainst: destination)
            }.value
            if deleted != batch.count { complete = false }
            await Task.yield()
        }
        await Task.detached(priority: .utility) {
            Self.cleanupEmptyDirectories(at: root)
        }.value
        return complete
    }

    nonisolated private static func copyBatch(
        _ sources: [URL],
        from oldRoot: URL,
        to newRoot: URL
    ) -> CopyBatchOutcome {
        let fm = FileManager.default
        var outcome = CopyBatchOutcome()
        for sourceURL in sources {
            guard let relative = relativePath(from: sourceURL, base: oldRoot) else {
                outcome.failCount += 1
                outcome.errors.append("\(sourceURL.lastPathComponent): 文件不属于原目录")
                continue
            }
            let destURL = newRoot.appendingPathComponent(relative)
            let fileName = sourceURL.lastPathComponent
            do {
                let destDir = destURL.deletingLastPathComponent()
                if !fm.fileExists(atPath: destDir.path) {
                    try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
                }
                if fm.fileExists(atPath: destURL.path) {
                    try fm.removeItem(at: destURL)
                }
                try fm.copyItem(at: sourceURL, to: destURL)
                outcome.successCount += 1
            } catch {
                outcome.failCount += 1
                outcome.errors.append("\(fileName): \(error.localizedDescription)")
                print("[DirectoryMigrationService] Copy failed: \(sourceURL.path): \(error)")
            }
        }
        return outcome
    }

    nonisolated private static func deleteVerifiedBatch(
        _ sources: [URL], from root: URL, verifiedAgainst destination: URL
    ) -> Int {
        let fm = FileManager.default
        var deleted = 0
        for sourceURL in sources {
            guard let relative = relativePath(from: sourceURL, base: root) else { continue }
            let target = destination.appendingPathComponent(relative)
            guard relativePath(from: target, base: destination) == relative,
                  let sourceValues = try? sourceURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  sourceValues.isRegularFile == true, sourceValues.isSymbolicLink != true,
                  let targetValues = try? target.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  targetValues.isRegularFile == true, targetValues.isSymbolicLink != true,
                  fm.contentsEqual(atPath: sourceURL.path, andPath: target.path) else { continue }
            do {
                try fm.removeItem(at: sourceURL)
                deleted += 1
            } catch {
                print("[DirectoryMigrationService] Delete failed: \(sourceURL.path)")
            }
        }
        return deleted
    }

    nonisolated private static func collectFiles(at root: URL) -> [URL] {
        let fm = FileManager.default
        var files: [URL] = []
        guard fm.fileExists(atPath: root.path) else { return files }
        if let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator {
                if url.lastPathComponent == ".DS_Store" { continue }
                if let isFile = try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile,
                   isFile == true {
                    files.append(url)
                }
            }
        }
        return files
    }

    nonisolated private static func relativePath(from url: URL, base: URL) -> String? {
        // Directory enumeration may return /private/var while the selected root
        // still uses /var. Compare canonical paths and retain the full hierarchy.
        let root = base.resolvingSymlinksInPath().standardizedFileURL.path
        let basePath = root.hasSuffix("/") ? root : root + "/"
        let fullPath = url.resolvingSymlinksInPath().standardizedFileURL.path
        if fullPath.hasPrefix(basePath) {
            return String(fullPath.dropFirst(basePath.count))
        }
        return nil
    }

    nonisolated private static func cleanupEmptyDirectories(at root: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return }
        func cleanup(_ url: URL) {
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else { return }
            do {
                let contents = try fm.contentsOfDirectory(atPath: url.path)
                for name in contents {
                    let child = url.appendingPathComponent(name)
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: child.path, isDirectory: &isDir), isDir.boolValue {
                        cleanup(child)
                    }
                }
                let remaining = try fm.contentsOfDirectory(atPath: url.path)
                if remaining.isEmpty {
                    try fm.removeItem(at: url)
                }
            } catch {
                print("[DirectoryMigrationService] Cleanup error at \(url.path): \(error)")
            }
        }
        cleanup(root)
    }

    private static func pathString(_ string: String) -> String {
        if let url = URL(string: string), url.isFileURL { return url.path }
        return string
    }
}
