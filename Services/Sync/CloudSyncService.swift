import Foundation
import Combine

@MainActor
final class CloudSyncService: ObservableObject {
    static let shared = CloudSyncService()

    // MARK: - Published 状态
    @Published var isSyncing: Bool = false
    @Published var lastSyncedAt: Date?
    @Published var lastError: Error?
    @Published var syncProgress: Double = 0  // 0.0 ~ 1.0
    @Published var syncStatusMessage: String = ""

    // MARK: - 依赖
    private let config = CloudSyncConfiguration.shared
    private let fileEngine = CloudSyncFileEngine.shared
    private let webDAVEngine = CloudSyncWebDAVEngine.shared
    private let metadataEngine = CloudSyncMetadataEngine.shared
    private let conflictResolver = CloudSyncConflictResolver.self

    private var cancellables = Set<AnyCancellable>()

    private init() {
        lastSyncedAt = config.lastSyncedAt
    }

    // MARK: - 主同步入口

    /// 执行完整同步（元数据 + 文件）
    func sync() async {
        guard !isSyncing else {
            lastError = CloudSyncError.syncInProgress
            return
        }

        isSyncing = true
        lastError = nil
        syncProgress = 0
        syncStatusMessage = "准备同步..."

        defer {
            isSyncing = false
            let now = Date()
            config.lastSyncedAt = now
            lastSyncedAt = now
        }

        do {
            switch config.syncMode {
            case .localFolder:
                try await performLocalSync()
            case .webDAV:
                try await performWebDAVSync()
            }
        } catch let error as CloudSyncError {
            lastError = error
            syncStatusMessage = "同步失败: \(error.localizedDescription)"
        } catch {
            lastError = CloudSyncError.internalError(reason: error.localizedDescription)
            syncStatusMessage = "同步失败: \(error.localizedDescription)"
        }
    }

    // MARK: - 本地文件夹同步

    private func performLocalSync() async throws {
        guard config.isEnabled, let syncRoot = config.syncRootURL else {
            throw CloudSyncError.syncDirectoryNotSet
        }

        // 1. 确保同步目录结构存在
        syncStatusMessage = "检查同步目录..."
        try await fileEngine.ensureSyncDirectory(at: syncRoot)
        syncProgress = 0.05

        // 2. 读取云端 manifest
        syncStatusMessage = "读取云端文件清单..."
        let cloudManifest = try await fileEngine.readManifest(from: config.manifestURL!)
        syncProgress = 0.1

        // 3. 扫描本地下载目录
        let downloadMgr = DownloadPathManager.shared
        let localManifest = try await scanLocalFiles(downloadMgr: downloadMgr)
        syncProgress = 0.2

        // 4. 对比 manifest，上传/下载文件
        let objectsDir = config.objectsURL!
        var referencedHashes = try await performFileSync(
            localManifest: localManifest,
            cloudManifest: cloudManifest,
            objectsDir: objectsDir,
            downloadMgr: downloadMgr,
            uploadFile: { localURL, hash in
                try await self.fileEngine.uploadFile(localURL: localURL, hash: hash, objectsDir: objectsDir)
            },
            downloadFile: { hash, destURL in
                try await self.fileEngine.downloadFile(hash: hash, objectsDir: objectsDir, destinationURL: destURL)
            }
        )
        syncProgress = 0.7

        // 5. 导出元数据 + 写入云端
        syncStatusMessage = "同步元数据..."
        let metadataData = try metadataEngine.exportMetadata()
        try metadataData.write(to: config.metadataURL!, options: .atomic)
        syncProgress = 0.8

        // 6. 更新云端 manifest
        let updatedManifest = CloudSyncManifest(files: localManifest, updatedAt: Date())
        try await fileEngine.writeManifest(updatedManifest, to: config.manifestURL!)
        syncProgress = 0.85

        // 7. GC
        syncStatusMessage = "清理旧文件..."
        try await fileEngine.garbageCollect(objectsDir: objectsDir, referencedHashes: referencedHashes)
        syncProgress = 0.9

        // 8. 读取云端 metadata 合并到本地
        if FileManager.default.fileExists(atPath: config.metadataURL!.path) {
            let cloudData = try Data(contentsOf: config.metadataURL!)
            try metadataEngine.importMetadata(from: cloudData, strategy: config.conflictStrategy)
        }
        syncProgress = 1.0
        syncStatusMessage = "同步完成"
    }

    // MARK: - WebDAV 同步

    private func performWebDAVSync() async throws {
        guard config.isEnabled,
              let credentials = config.webDAVCredentials else {
            throw CloudSyncError.syncDirectoryNotSet
        }

        let baseURL = credentials.baseURL
        let syncBaseURL = credentials.syncRootURL
        let objectsBaseURL = credentials.objectsURL

        // 1. 确保远程目录结构存在
        syncStatusMessage = "检查远程目录..."
        try await webDAVEngine.ensureSyncDirectory(baseURL: baseURL, credentials: credentials)
        syncProgress = 0.05

        // 2. 读取远程 manifest
        syncStatusMessage = "读取文件清单..."
        let cloudManifest = try await webDAVEngine.readManifest(baseURL: syncBaseURL, credentials: credentials)
        syncProgress = 0.1

        // 3. 扫描本地下载目录
        let downloadMgr = DownloadPathManager.shared
        let localManifest = try await scanLocalFiles(downloadMgr: downloadMgr)
        syncProgress = 0.2

        // 4. 上传/下载
        var referencedHashes = try await performFileSync(
            localManifest: localManifest,
            cloudManifest: cloudManifest,
            objectsDir: objectsBaseURL,
            downloadMgr: downloadMgr,
            uploadFile: { localURL, hash in
                try await self.webDAVEngine.uploadFile(
                    localURL: localURL, hash: hash,
                    objectsBaseURL: objectsBaseURL, credentials: credentials
                )
            },
            downloadFile: { hash, destURL in
                try await self.webDAVEngine.downloadFile(
                    hash: hash, objectsBaseURL: objectsBaseURL,
                    destinationURL: destURL, credentials: credentials
                )
            }
        )
        syncProgress = 0.7

        // 5. 导出元数据 + 写入远程
        syncStatusMessage = "同步元数据..."
        let metadataData = try metadataEngine.exportMetadata()
        try await client.put(
            url: credentials.metadataURL,
            data: metadataData,
            contentType: "application/json",
            credentials: credentials
        )
        syncProgress = 0.8

        // 6. 更新远程 manifest
        let updatedManifest = CloudSyncManifest(files: localManifest, updatedAt: Date())
        try await webDAVEngine.writeManifest(updatedManifest, baseURL: syncBaseURL, credentials: credentials)
        syncProgress = 0.85

        // 7. GC
        syncStatusMessage = "清理旧文件..."
        try await webDAVEngine.garbageCollect(
            objectsBaseURL: objectsBaseURL,
            referencedHashes: referencedHashes,
            credentials: credentials
        )
        syncProgress = 0.9

        // 8. 读取远程 metadata 合并到本地
        do {
            let cloudData = try await client.get(url: credentials.metadataURL, credentials: credentials)
            try metadataEngine.importMetadata(from: cloudData, strategy: config.conflictStrategy)
        } catch let error as CloudSyncError {
            if case .webDAVNotFound = error {
                // 首次同步，没有 metadata 是正常的
            } else { throw error }
        }
        syncProgress = 1.0
        syncStatusMessage = "同步完成"
    }

    // 访问 WebDAV client 用于 PUT/GET metadata
    private var client: CloudSyncWebDAVClient { .shared }

    // MARK: - 公共同步子步骤

    /// 扫描本地三个下载目录
    private func scanLocalFiles(downloadMgr: DownloadPathManager) async throws -> [String: CloudSyncManifest.CloudSyncManifestEntry] {
        let localWallpapers = try await fileEngine.scanLocalDirectory(
            basePath: "Wallpapers",
            directoryURL: downloadMgr.wallpapersFolderURL
        )
        let localMedia = try await fileEngine.scanLocalDirectory(
            basePath: "Media",
            directoryURL: downloadMgr.mediaFolderURL
        )
        let localSceneBakes = try await fileEngine.scanLocalDirectory(
            basePath: "SceneBakes",
            directoryURL: downloadMgr.sceneBakesFolderURL
        )
        var localManifest = localWallpapers
        localManifest.merge(localMedia) { current, _ in current }
        localManifest.merge(localSceneBakes) { current, _ in current }
        return localManifest
    }

    /// 上传/下载文件循环
    private func performFileSync(
        localManifest: [String: CloudSyncManifest.CloudSyncManifestEntry],
        cloudManifest: CloudSyncManifest,
        objectsDir: URL,
        downloadMgr: DownloadPathManager,
        uploadFile: (URL, String) async throws -> Void,
        downloadFile: (String, URL) async throws -> Void
    ) async throws -> Set<String> {
        var referencedHashes = Set<String>()

        // 收集云端 hash
        for entry in cloudManifest.files.values {
            referencedHashes.insert(entry.hash)
        }

        // 上传
        syncStatusMessage = "上传文件..."
        var totalFiles = localManifest.count
        var processedFiles = 0
        for (relativePath, localEntry) in localManifest {
            let isUpload = conflictResolver.resolveFile(
                localHash: localEntry.hash,
                cloudHash: cloudManifest.files[relativePath]?.hash,
                strategy: config.conflictStrategy
            ) == .upload

            if isUpload {
                let localURL = downloadMgr.rootFolderURL.appendingPathComponent(relativePath)
                try await uploadFile(localURL, localEntry.hash)
            }
            referencedHashes.insert(localEntry.hash)
            processedFiles += 1
            syncProgress = 0.2 + (Double(processedFiles) / Double(max(totalFiles, 1))) * 0.3
        }

        // 下载
        syncStatusMessage = "下载文件..."
        var cloudFilesToDownload: [(relativePath: String, hash: String)] = []
        for (relativePath, cloudEntry) in cloudManifest.files {
            let resolution = conflictResolver.resolveFile(
                localHash: localManifest[relativePath]?.hash,
                cloudHash: cloudEntry.hash,
                strategy: config.conflictStrategy
            )
            if case .download = resolution {
                cloudFilesToDownload.append((relativePath, cloudEntry.hash))
            }
        }

        totalFiles = cloudFilesToDownload.count
        processedFiles = 0
        for (relativePath, hash) in cloudFilesToDownload {
            let destURL = downloadMgr.rootFolderURL.appendingPathComponent(relativePath)
            try await downloadFile(hash, destURL)
            processedFiles += 1
            syncProgress = 0.5 + (Double(processedFiles) / Double(max(totalFiles, 1))) * 0.2
        }

        return referencedHashes
    }

    // MARK: - 从云端恢复（首次配置）

    func restoreFromCloud() async {
        guard !isSyncing else { return }

        isSyncing = true
        lastError = nil
        syncProgress = 0
        syncStatusMessage = "从云端恢复..."

        defer {
            isSyncing = false
        }

        do {
            switch config.syncMode {
            case .localFolder:
                try await performLocalRestore()
            case .webDAV:
                try await performWebDAVRestore()
            }

            let now = Date()
            config.lastSyncedAt = now
            lastSyncedAt = now
        } catch let error as CloudSyncError {
            lastError = error
            syncStatusMessage = "恢复失败: \(error.localizedDescription)"
        } catch {
            lastError = CloudSyncError.internalError(reason: error.localizedDescription)
            syncStatusMessage = "恢复失败: \(error.localizedDescription)"
        }
    }

    private func performLocalRestore() async throws {
        guard let metadataURL = config.metadataURL,
              let manifestURL = config.manifestURL else {
            throw CloudSyncError.syncDirectoryNotSet
        }
        let fileMgr = FileManager.default
        guard fileMgr.fileExists(atPath: metadataURL.path) else {
            throw CloudSyncError.metadataReadFailed
        }

        syncStatusMessage = "读取文件清单..."
        let cloudManifest = try await fileEngine.readManifest(from: manifestURL)
        let objectsDir = config.objectsURL!
        let downloadMgr = DownloadPathManager.shared
        syncProgress = 0.1

        syncStatusMessage = "下载文件..."
        var processedFiles = 0
        let totalFiles = cloudManifest.files.count
        for (relativePath, entry) in cloudManifest.files {
            let destURL = downloadMgr.rootFolderURL.appendingPathComponent(relativePath)
            try await fileEngine.downloadFile(hash: entry.hash, objectsDir: objectsDir, destinationURL: destURL)
            processedFiles += 1
            syncProgress = 0.1 + (Double(processedFiles) / Double(max(totalFiles, 1))) * 0.5
        }
        syncProgress = 0.6

        syncStatusMessage = "导入元数据..."
        let metadataData = try Data(contentsOf: metadataURL)
        try metadataEngine.importMetadata(from: metadataData, strategy: .cloudPreferred)
        syncProgress = 0.9

        syncStatusMessage = "更新文件清单..."
        let newManifest = try await scanLocalFiles(downloadMgr: downloadMgr)
        try await fileEngine.writeManifest(
            CloudSyncManifest(files: newManifest, updatedAt: Date()),
            to: manifestURL
        )
        syncProgress = 1.0
        syncStatusMessage = "恢复完成"
    }

    private func performWebDAVRestore() async throws {
        guard let credentials = config.webDAVCredentials else {
            throw CloudSyncError.syncDirectoryNotSet
        }
        let syncBaseURL = credentials.syncRootURL

        syncStatusMessage = "读取文件清单..."
        let cloudManifest = try await webDAVEngine.readManifest(baseURL: syncBaseURL, credentials: credentials)
        let objectsBaseURL = credentials.objectsURL
        let downloadMgr = DownloadPathManager.shared
        syncProgress = 0.1

        syncStatusMessage = "下载文件..."
        var processedFiles = 0
        let totalFiles = cloudManifest.files.count
        for (relativePath, entry) in cloudManifest.files {
            let destURL = downloadMgr.rootFolderURL.appendingPathComponent(relativePath)
            try await webDAVEngine.downloadFile(
                hash: entry.hash,
                objectsBaseURL: objectsBaseURL,
                destinationURL: destURL,
                credentials: credentials
            )
            processedFiles += 1
            syncProgress = 0.1 + (Double(processedFiles) / Double(max(totalFiles, 1))) * 0.5
        }
        syncProgress = 0.6

        syncStatusMessage = "导入元数据..."
        let metadataData = try await client.get(url: credentials.metadataURL, credentials: credentials)
        try metadataEngine.importMetadata(from: metadataData, strategy: .cloudPreferred)
        syncProgress = 0.9

        syncStatusMessage = "更新文件清单..."
        let newManifest = try await scanLocalFiles(downloadMgr: downloadMgr)
        try await webDAVEngine.writeManifest(
            CloudSyncManifest(files: newManifest, updatedAt: Date()),
            baseURL: syncBaseURL,
            credentials: credentials
        )
        syncProgress = 1.0
        syncStatusMessage = "恢复完成"
    }

    // MARK: - 应用退出时自动同步

    func syncOnAppTerminate() {
        guard config.isEnabled else { return }
        Task {
            await sync()
        }
    }

    // MARK: - 错误清理

    func clearError() {
        lastError = nil
        syncStatusMessage = ""
    }
}
