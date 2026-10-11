import Foundation

/// 本地壁纸扫描服务。
/// 正常运行不主动扫描；仅由“修复数据”和一次性升级迁移枚举受管目录。
@MainActor
final class LocalWallpaperScanner {
    static let shared = LocalWallpaperScanner()

    struct ReindexResult: Codable, Sendable {
        let indexedWallpapers: Int
        let indexedMedia: Int

        var totalIndexed: Int {
            indexedWallpapers + indexedMedia
        }
    }
    
    private let downloadPathManager = DownloadPathManager.shared
    private let fileManager = FileManager.default
    /// 启动兜底抽查用：走缓存，避免主线程对慢卷反复 stat
    private let fileExistenceCache = FileExistenceCache.shared
    /// 旧版本仅把扫描结果留在内存。首次升级到持久化下载记录模型时，
    /// 用该迁移标记确保用户现有内容会被补登一次，而不是每次启动都扫盘。
    private static let persistentIndexMigrationKey = "managedLibraryPersistentIndexMigration"
    /// v2：v1 的扫描范围只有 `Wallpapers/` 与 `Media/` 两个子目录，而历史版本会把媒体
    /// 文件直接落在库根顶层（`DownloadPathManager.inferDefaultLocation` 的兜底分支就返回
    /// root）。默认路径（`~/Library/Application Support/WaifuX`）用户的整库可能都在那一层：
    /// v1 扫不到任何文件，却照样把完成标记写掉，之后永不扫盘 → 「我的库」永久空白
    /// （38.0.14x 用户反馈）。bump 到 2 让这批设备再补扫一次，同时把库根顶层纳入扫描。
    private static let persistentIndexMigrationVersion = 2
    
    // 缓存扫描结果
    private var scannedWallpapers: [LocalWallpaperItem] = []
    private var scannedMediaItems: [LocalMediaItem] = []
    private var lastScanTime: Date?
    private var scanTask: Task<Void, Never>?
    /// 本次扫描在受管目录顶层发现的 Workshop 工程目录（含 project.json）。
    /// 它们是目录、不是白名单里的媒体文件，需要走 `ImportService` 的补建通路。
    private var discoveredWorkshopDirectories: [URL] = []
    
    /// 扫描版本号，扫描完成后递增，供 ViewModel 监听以重建缓存
    @Published private(set) var scanRevision: UInt = 0
    
    // 扫描间隔（秒）- 增加到 30 秒避免频繁扫描
    private let scanInterval: TimeInterval = 30
    
    private init() {}
    
    // MARK: - 公共方法
    
    /// 获取所有本地壁纸（包括扫描到的文件）
    /// - Returns: 本地壁纸项目数组
    func getLocalWallpapers() -> [LocalWallpaperItem] {
        scheduleScanIfNeeded()
        return scannedWallpapers
    }
    
    /// 获取所有本地媒体（包括扫描到的文件）
    /// - Returns: 本地媒体项目数组
    func getLocalMedia() -> [LocalMediaItem] {
        scheduleScanIfNeeded()
        return scannedMediaItems
    }
    
    /// 强制重新扫描本地文件
    func forceRescan() async {
        if BackgroundRuntimeRole.isRemoteUI { try? await BackgroundRuntimeBridge.requestVoid("library.rescan.wait"); return }
        await scanLocalFiles(force: true)
    }

    /// 在持久化下载记录模型首次启用时执行一次索引迁移。
    /// 该方法只能在 AppDelegate 的延迟恢复阶段调用，此时 UserDefaults 已可安全访问。
    /// 如果受管根目录暂时不可用（例如外置盘未挂载），不写完成标记，下次启动会重试。
    func rebuildManagedLibraryIndexForUpgradeIfNeeded() async -> ReindexResult? {
        let defaults = WaifuXPreferences.shared
        guard defaults.integer(forKey: Self.persistentIndexMigrationKey)
            < Self.persistentIndexMigrationVersion else {
            return nil
        }

        let rootURL = downloadPathManager.rootFolderURL.standardizedFileURL
        guard fileManager.fileExists(atPath: rootURL.path),
              fileManager.isReadableFile(atPath: rootURL.path) else {
            print("[LocalWallpaperScanner] Deferred persistent-index migration: managed root unavailable")
            return nil
        }

        let result = await rebuildManagedLibraryIndex()
        defaults.set(
            Self.persistentIndexMigrationVersion,
            forKey: Self.persistentIndexMigrationKey
        )
        print(
            "[LocalWallpaperScanner] Persistent-index migration completed: "
                + "indexed=\(result.totalIndexed)"
        )
        return result
    }

    /// 兜底自愈：记录丢失（空记录，或只剩指向已消失文件的僵尸记录）而受管根目录
    /// 确实存在时，按磁盘内容补建一次记录。
    ///
    /// 38.0.14x 之前「只信持久化记录、不再扫盘」的版本把一次性迁移标记写早了，
    /// 这批用户的「我的库」会永久空白。实测反馈形态：`CachePersistence/Records` 只有
    /// 2 个文件、`Media/` 里躺着 10 个视频、`Wallpapers/` 为空 —— 所以不能只判「记录数组
    /// 为空」，必须放宽到「抽查不到任何一条活记录」，否则留下 1~2 条僵尸记录的设备
    /// 依旧空白。
    ///
    /// 与「修复数据」的区别：`repairBrokenRecords()` 是手动入口且还会停用找不到文件的
    /// 记录；这里只在异常态自动跑一次，不影响常规路径。
    /// - Returns: 补建结果；不需要补建（存在活记录、根目录不可用）时返回 nil。
    func rebuildManagedLibraryIndexIfNoLiveRecords() async -> ReindexResult? {
        // 记录数组为空：必然要补。非空时抽查前 20 条是否有文件仍在磁盘上
        // （走 FileExistenceCache，扫描/导入路径已预热），避免主线程逐条 stat 慢卷。
        let wallpaperRecords = WallpaperLibraryService.shared.downloadedWallpapers
        if !wallpaperRecords.isEmpty,
           wallpaperRecords.prefix(20).contains(where: {
               fileExistenceCache.fileExists(atPath: $0.localFilePath)
           }) {
            return nil
        }
        let mediaRecords = MediaLibraryService.shared.downloadedItems
        if !mediaRecords.isEmpty,
           mediaRecords.prefix(20).contains(where: {
               fileExistenceCache.fileExists(atPath: $0.localFilePath)
           }) {
            return nil
        }

        let rootURL = downloadPathManager.rootFolderURL.standardizedFileURL
        guard fileManager.fileExists(atPath: rootURL.path),
              fileManager.isReadableFile(atPath: rootURL.path) else {
            return nil
        }

        let result = await rebuildManagedLibraryIndex()
        if result.totalIndexed > 0 {
            print(
                "[LocalWallpaperScanner] Rebuilt empty library index from disk: "
                    + "wallpapers=\(result.indexedWallpapers), media=\(result.indexedMedia)"
            )
        }
        return result
    }

    /// 显式扫描受管目录，并把没有持久化下载记录的文件补建为本地记录。
    /// 仅供“修复数据”和升级迁移调用，不能作为常规列表或轮播的数据源。
    func rebuildManagedLibraryIndex() async -> ReindexResult {
        if BackgroundRuntimeRole.isRemoteUI {
            return (try? await BackgroundRuntimeBridge.requestCodable("library.reindex.wait", arguments: Data(), resultKey: "result", as: ReindexResult.self)) ?? ReindexResult(indexedWallpapers: 0, indexedMedia: 0)
        }
        await scanLocalFiles(force: true)

        var knownWallpaperPaths = Set(
            WallpaperLibraryService.shared.downloadedWallpapers.map(Self.standardizedPath)
        )
        var knownMediaPaths = Set(
            MediaLibraryService.shared.downloadedItems.map(Self.standardizedPath)
        )
        var indexedWallpapers = 0
        var indexedMedia = 0

        for item in scannedWallpapers {
            let path = Self.standardizedPath(item.fileURL)
            guard knownWallpaperPaths.insert(path).inserted else { continue }
            WallpaperLibraryService.shared.recordDownload(
                item.toWallpaper(),
                fileURL: item.fileURL
            )
            indexedWallpapers += 1
        }

        for item in scannedMediaItems {
            let path = Self.standardizedPath(item.fileURL)
            guard knownMediaPaths.insert(path).inserted else { continue }
            MediaLibraryService.shared.recordDownload(
                item: item.toMediaItem(),
                localFileURL: item.fileURL
            )
            indexedMedia += 1
        }

        // 受管目录里的 Workshop 工程目录（`Media/workshop_<id>/`、含 project.json）：
        // 它们是「目录」而不是白名单里的媒体文件，只按文件扫描永远命中不了 ——
        // 记录丢失后这条通路是唯一能把它们补回来的地方（只重建记录，不动文件）。
        if !discoveredWorkshopDirectories.isEmpty {
            indexedMedia += ImportService.shared.reindexWorkshopDirectories(discoveredWorkshopDirectories)
        }

        if indexedWallpapers > 0 || indexedMedia > 0 {
            NotificationCenter.default.post(name: .managedLibraryContentsChanged, object: nil)
            print(
                "[LocalWallpaperScanner] Rebuilt managed index: "
                    + "wallpapers=\(indexedWallpapers), media=\(indexedMedia)"
            )
        }

        return ReindexResult(
            indexedWallpapers: indexedWallpapers,
            indexedMedia: indexedMedia
        )
    }

    /// 主窗口长期隐藏后释放前台库列表缓存；下次打开时按需重新扫描。
    func clearInMemoryCache() {
        scannedWallpapers.removeAll()
        scannedMediaItems.removeAll()
        lastScanTime = nil
        scanRevision &+= 1
    }
    
    /// 根据文件路径查找或创建壁纸对象
    /// - Parameter fileURL: 文件 URL
    /// - Returns: 本地壁纸项目
    func wallpaperForFile(_ fileURL: URL) -> LocalWallpaperItem? {
        // 先检查缓存
        if let cached = scannedWallpapers.first(where: { $0.fileURL.path == fileURL.path }) {
            return cached
        }
        
        // 实时创建
        return createWallpaperItem(from: fileURL)
    }
    
    /// 根据文件路径查找或创建媒体对象
    /// - Parameter fileURL: 文件 URL
    /// - Returns: 本地媒体项目
    func mediaForFile(_ fileURL: URL) async -> LocalMediaItem? {
        if let cached = scannedMediaItems.first(where: { $0.fileURL.path == fileURL.path }) {
            return cached
        }
        return await createMediaItem(from: fileURL)
    }
    
    // MARK: - 扫描逻辑
    
    private func shouldRescan() -> Bool {
        guard let lastScan = lastScanTime else { return true }
        return Date().timeIntervalSince(lastScan) > scanInterval
    }

    private func scheduleScanIfNeeded() {
        guard shouldRescan() else { return }
        guard scanTask == nil else { return }

        scanTask = Task { [weak self] in
            guard let self else { return }
            await self.runScan()
        }
    }

    private func scanLocalFiles(force: Bool = false) async {
        if !force && !shouldRescan() {
            return
        }

        if let scanTask {
            await scanTask.value
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.runScan()
        }
        scanTask = task
        await task.value
    }

    private func runScan() async {
        defer { scanTask = nil }

        let startTime = Date()
        print("[LocalWallpaperScanner] Starting local file scan...")

        // 路径在 MainActor 解析（security-scoped）；目录枚举/轻量元数据放到后台，避免卡 UI。
        let wallpapersFolder = downloadPathManager.wallpapersFolderURL
        let mediaFolder = downloadPathManager.mediaFolderURL
        let libraryRootFolder = downloadPathManager.rootFolderURL

        let (wallpapers, mediaItems, workshopDirectories) = await Task.detached(priority: .utility) {
            var wallpapers: [LocalWallpaperItem] = []
            var mediaItems: [LocalMediaItem] = []
            var workshopDirectories: [URL] = []
            let fm = FileManager.default

            if fm.fileExists(atPath: wallpapersFolder.path) {
                do {
                    let contents = try fm.contentsOfDirectory(
                        at: wallpapersFolder,
                        includingPropertiesForKeys: [
                            .fileSizeKey,
                            .creationDateKey,
                            .contentModificationDateKey
                        ],
                        options: .skipsHiddenFiles
                    )
                    for fileURL in contents where Self.isImageFileStatic(fileURL) {
                        if let item = Self.createWallpaperItemLightweight(from: fileURL) {
                            wallpapers.append(item)
                        }
                    }
                } catch {
                    print("[LocalWallpaperScanner] Failed to scan wallpapers folder: \(error)")
                }
            }

            if fm.fileExists(atPath: mediaFolder.path) {
                do {
                    let contents = try fm.contentsOfDirectory(
                        at: mediaFolder,
                        includingPropertiesForKeys: [
                            .fileSizeKey,
                            .creationDateKey,
                            .contentModificationDateKey
                        ],
                        options: .skipsHiddenFiles
                    )
                    for fileURL in contents where Self.isVideoFileStatic(fileURL) {
                        if let item = Self.createMediaItemLightweight(from: fileURL) {
                            mediaItems.append(item)
                        }
                    }
                    // Workshop 工程目录（`Media/workshop_<id>/`）：是「目录」不是媒体文件，
                    // 扩展名白名单判定永远命中不了，记录一旦丢失就再也补不回来。
                    // 这里只按目录名收集、不判断工程是否可解析 —— Steam 下载的工程是
                    // `workshop_<id>/steamapps/workshop/content/431960/<id>/project.json`
                    // 这种壳目录，顶层并没有 project.json，解析交给 ImportService。
                    for fileURL in contents {
                        var isDir: ObjCBool = false
                        guard fm.fileExists(atPath: fileURL.path, isDirectory: &isDir),
                              isDir.boolValue,
                              fileURL.lastPathComponent.hasPrefix("workshop_") else {
                            continue
                        }
                        workshopDirectories.append(fileURL)
                    }
                } catch {
                    print("[LocalWallpaperScanner] Failed to scan media folder: \(error)")
                }
            }

            // 库根顶层的散装媒体文件：历史版本（以及 inferDefaultLocation 的兜底分支）
            // 会把文件直接放在 root 下，只扫两个子目录会永久漏掉这批内容。
            // 只取顶层常规文件、不下钻子目录，避免把 Cache/、SceneBakes/ 之类卷进来。
            if fm.fileExists(atPath: libraryRootFolder.path),
               let rootContents = try? fm.contentsOfDirectory(
                   at: libraryRootFolder,
                   includingPropertiesForKeys: [
                       .fileSizeKey,
                       .creationDateKey,
                       .contentModificationDateKey,
                       .isRegularFileKey
                   ],
                   options: .skipsHiddenFiles
               ) {
                for fileURL in rootContents {
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: fileURL.path, isDirectory: &isDir), isDir.boolValue {
                        // 库根下的工程目录（老版本可能直接放在 root）；同样只按前缀收集
                        if fileURL.lastPathComponent.hasPrefix("workshop_") {
                            workshopDirectories.append(fileURL)
                        }
                        continue
                    }
                    if Self.isImageFileStatic(fileURL) {
                        if let item = Self.createWallpaperItemLightweight(from: fileURL) {
                            wallpapers.append(item)
                        }
                    } else if Self.isVideoFileStatic(fileURL) {
                        if let item = Self.createMediaItemLightweight(from: fileURL) {
                            mediaItems.append(item)
                        }
                    }
                }
            }

            return (wallpapers, mediaItems, workshopDirectories)
        }.value

        // 预热存在性缓存，列表 isDownloaded / localFileURL 不再 stat 外置卷
        for item in wallpapers {
            FileExistenceCache.shared.markExisting(atPath: item.fileURL.path)
        }
        for item in mediaItems {
            FileExistenceCache.shared.markExisting(atPath: item.fileURL.path)
        }

        scannedWallpapers = wallpapers
        scannedMediaItems = mediaItems
        discoveredWorkshopDirectories = workshopDirectories
        lastScanTime = Date()
        scanRevision &+= 1

        print(
            "[LocalWallpaperScanner] Scan completed in \(Date().timeIntervalSince(startTime))s, "
                + "found \(wallpapers.count) wallpapers, \(mediaItems.count) media files, "
                + "\(workshopDirectories.count) workshop project folders"
        )

        // 列表缩略图在可见卡片 onAppear 时按需生成；扫描阶段不读全图、不抽视频帧
    }

    // MARK: - 创建元数据

    /// 列表扫描用：只读目录项 resourceValues，不打开 ImageIO/AVAsset（外置卡上极慢）。
    nonisolated private static func createWallpaperItemLightweight(from fileURL: URL) -> LocalWallpaperItem? {
        let fileName = fileURL.deletingPathExtension().lastPathComponent
        let fileExtension = fileURL.pathExtension.lowercased()
        let id = "local_\(fileName)_\(fileExtension)"
        let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey])
        let created = values?.creationDate ?? values?.contentModificationDate
        let createdAt = created.map { ISO8601DateFormatter().string(from: $0) }

        return LocalWallpaperItem(
            id: id,
            fileURL: fileURL,
            fileName: fileName,
            title: fileName.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " "),
            // 分辨率延后到详情/需要筛选时再读；列表滚动不依赖精确像素
            resolution: "Unknown",
            dimensionX: 1920,
            dimensionY: 1080,
            ratio: "1.78",
            fileSize: values?.fileSize,
            fileType: mimeTypeStatic(fileExtension),
            createdAt: createdAt
        )
    }

    nonisolated private static func createMediaItemLightweight(from fileURL: URL) -> LocalMediaItem? {
        let fileName = fileURL.deletingPathExtension().lastPathComponent
        let fileExtension = fileURL.pathExtension.lowercased()
        let (parsedTitle, parsedResolution) = parseMediaFileNameStatic(fileName)
        let id = "local_\(fileName)_\(fileExtension)"
        let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey])
        let created = values?.creationDate ?? values?.contentModificationDate
        let createdAt = created.map { ISO8601DateFormatter().string(from: $0) }

        return LocalMediaItem(
            id: id,
            fileURL: fileURL,
            fileName: fileName,
            title: parsedTitle,
            resolution: parsedResolution,
            duration: nil,
            fileSize: values?.fileSize,
            fileType: mimeTypeStatic(fileExtension),
            createdAt: createdAt
        )
    }

    private func createWallpaperItem(from fileURL: URL) -> LocalWallpaperItem? {
        Self.createWallpaperItemLightweight(from: fileURL)
    }

    private func createMediaItem(from fileURL: URL) async -> LocalMediaItem? {
        Self.createMediaItemLightweight(from: fileURL)
    }

    nonisolated private static func isImageFileStatic(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "webp", "gif", "bmp", "tiff", "heic"].contains(ext)
    }

    nonisolated private static func standardizedPath(_ url: URL) -> String {
        (url.path as NSString).standardizingPath
    }

    nonisolated private static func standardizedPath(_ record: WallpaperDownloadRecord) -> String {
        (record.localFilePath as NSString).standardizingPath
    }

    nonisolated private static func standardizedPath(_ record: MediaDownloadRecord) -> String {
        (record.localFilePath as NSString).standardizingPath
    }

    nonisolated private static func isVideoFileStatic(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ["mp4", "mov", "avi", "mkv", "webm", "m4v", "flv"].contains(ext)
    }

    nonisolated private static func mimeTypeStatic(_ ext: String) -> String? {
        let typeMap: [String: String] = [
            "jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png",
            "webp": "image/webp", "gif": "image/gif", "bmp": "image/bmp",
            "tiff": "image/tiff", "heic": "image/heic",
            "mp4": "video/mp4", "mov": "video/quicktime", "avi": "video/x-msvideo",
            "mkv": "video/x-matroska", "webm": "video/webm", "m4v": "video/x-m4v",
            "flv": "video/x-flv"
        ]
        return typeMap[ext]
    }

    nonisolated private static func parseMediaFileNameStatic(_ fileName: String) -> (title: String, resolution: String?) {
        let patterns = [
            ("(\\d{3,4})p", 1),
            ("(\\d{4})x(\\d{3,4})", 0),
            ("(4k|8k|2k)", 1),
            ("(hd|fullhd|fhd)", 1),
        ]
        var foundResolution: String?
        var modifiedName = fileName
        for (pattern, group) in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(modifiedName.startIndex..., in: modifiedName)
                if let match = regex.firstMatch(in: modifiedName, options: [], range: range) {
                    if let resolutionRange = Range(match.range(at: group), in: modifiedName) {
                        foundResolution = String(modifiedName[resolutionRange]).uppercased()
                    }
                    modifiedName = regex.stringByReplacingMatches(
                        in: modifiedName,
                        options: [],
                        range: range,
                        withTemplate: ""
                    )
                }
            }
        }
        let cleanTitle = modifiedName
            .replacingOccurrences(of: "motionbgs-", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "wallhaven-", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return (cleanTitle.isEmpty ? fileName : cleanTitle, foundResolution)
    }
    
    // 图片/视频像素与时长改由详情页/设壁纸路径按需读取；
    // 列表扫描只保留目录项 resourceValues，避免外置卡上 ImageIO/AVAsset 全量 I/O。
}

// MARK: - 本地壁纸项目

struct LocalWallpaperItem: Identifiable, Hashable {
    let id: String
    let fileURL: URL
    let fileName: String
    let title: String
    let resolution: String
    let dimensionX: Int
    let dimensionY: Int
    let ratio: String
    let fileSize: Int?
    let fileType: String?
    let createdAt: String?
    
    /// 转换为 Wallpaper 对象（用于详情页）
    func toWallpaper() -> Wallpaper {
        Wallpaper(
            id: id,
            title: nil,
            url: fileURL.absoluteString,
            shortUrl: nil,
            views: 0,
            favorites: 0,
            downloads: nil,
            source: "local",
            purity: "sfw",
            category: "general",
            dimensionX: dimensionX,
            dimensionY: dimensionY,
            resolution: resolution,
            ratio: ratio,
            fileSize: fileSize,
            fileType: fileType,
            createdAt: createdAt,
            colors: [],
            path: fileURL.absoluteString,
            thumbs: Wallpaper.Thumbs(
                large: fileURL.absoluteString,
                original: fileURL.absoluteString,
                small: fileURL.absoluteString
            ),
            tags: nil,
            uploader: nil
        )
    }
}

// MARK: - 本地媒体项目

struct LocalMediaItem: Identifiable, Hashable {
    let id: String
    let fileURL: URL
    let fileName: String
    let title: String
    let resolution: String?
    let duration: Double?
    let fileSize: Int?
    let fileType: String?
    let createdAt: String?
    
    /// 转换为 MediaItem 对象（用于详情页）
    @MainActor
    func toMediaItem() -> MediaItem {
        let resolutionLabel = resolution ?? "HD"
        
        // 列表缩略图（800×600）；锁屏/桌面请用 posterJPEG / existingWallpaperPoster，不得复用列表小图
        let listThumbnailURL = VideoThumbnailCache.shared.thumbnailURL(for: fileURL)
        let hdPosterURL = VideoThumbnailCache.shared.cachedPosterJPEGFileURLIfExists(forLocalVideo: fileURL)
        
        return MediaItem(
            slug: id,
            title: title,
            pageURL: fileURL,
            thumbnailURL: listThumbnailURL,
            resolutionLabel: resolutionLabel,
            collectionTitle: t("local.files"),
            summary: t("local.imported.video"),
            previewVideoURL: fileURL,
            posterURL: hdPosterURL,
            tags: ["local", fileURL.pathExtension.lowercased()],
            exactResolution: resolution,
            durationSeconds: duration,
            downloadOptions: [], // 本地文件没有下载选项
            sourceName: t("local")
        )
    }
    
    /// 时长格式化
    var durationLabel: String? {
        guard let duration = duration else { return nil }
        let totalSeconds = Int(duration.rounded())
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
    
    /// 文件大小格式化
    var fileSizeLabel: String? {
        guard let size = fileSize else { return nil }
        let mb = Double(size) / 1024 / 1024
        if mb >= 1024 {
            return String(format: "%.1f GB", mb / 1024)
        }
        return String(format: "%.1f MB", mb)
    }
}
