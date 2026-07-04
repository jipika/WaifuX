import Foundation
import AppKit
import AVFoundation

// MARK: - 导入进度

struct ImportProgress: Equatable {
    /// 当前正在处理的文件名
    var currentFileName = ""
    /// 本次导入的文件总数（展开目录后）
    var totalFiles = 0
    /// 已处理的文件数
    var completedFiles = 0
    /// 成功导入数
    var successfulImports = 0
    /// 失败数
    var failedImports = 0
    /// 是否已被取消
    var isCancelled = false

    var isFinished: Bool {
        completedFiles >= totalFiles && totalFiles > 0
    }

    var fractionCompleted: Double {
        guard totalFiles > 0 else { return 0 }
        return min(Double(completedFiles) / Double(totalFiles), 1.0)
    }

    /// 合并另一个进度（用于 TaskGroup 累加）
    static func + (lhs: ImportProgress, rhs: ImportProgress) -> ImportProgress {
        ImportProgress(
            currentFileName: rhs.currentFileName.isEmpty ? lhs.currentFileName : rhs.currentFileName,
            totalFiles: lhs.totalFiles + rhs.totalFiles,
            completedFiles: lhs.completedFiles + rhs.completedFiles,
            successfulImports: lhs.successfulImports + rhs.successfulImports,
            failedImports: lhs.failedImports + rhs.failedImports,
            isCancelled: lhs.isCancelled || rhs.isCancelled
        )
    }
}

// MARK: - 导入结果

struct ImportResult {
    let totalFiles: Int
    let successfulImports: Int
    let failedImports: Int

    var hasFailures: Bool { failedImports > 0 }
    var allSucceeded: Bool { failedImports == 0 && successfulImports > 0 }
    var message: String {
        if allSucceeded {
            return String(format: t("import.result.success"), successfulImports)
        } else if hasFailures {
            return String(format: t("import.result.partial"), successfulImports, failedImports)
        } else {
            return t("import.result.none")
        }
    }
}

// MARK: - 统一导入服务

/// 统一导入服务：自动识别文件类型并路由到正确的库。
///
/// 支持的输入：
/// - 图片文件 → 壁纸库（`Wallpapers/`）
/// - 视频文件 → 媒体库（`Media/`）
/// - 目录（含 project.json）→ Workshop 导入（`Media/workshop_{id}/`）
/// - `.pkg` 文件 → 取其父目录作为 Workshop 源
@MainActor
final class ImportService: ObservableObject {
    static let shared = ImportService()

    @Published var isImporting = false
    @Published var progress = ImportProgress()

    private let wallpaperLibrary = WallpaperLibraryService.shared
    private let mediaLibrary = MediaLibraryService.shared
    private let downloadPathManager = DownloadPathManager.shared
    private let fileManager = FileManager.default
    private var currentTask: Task<Void, Never>?

    private init() {}

    // MARK: - 公开方法

    /// 取消当前正在进行的导入
    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        progress.isCancelled = true
        isImporting = false
    }

    /// 导入指定的 URL 列表（文件/目录混合）
    /// - Parameters:
    ///   - urls: 用户选择的文件或目录 URL
    ///   - folderID: 可选，导入后自动归入的文件夹 ID
    func importURLs(_ urls: [URL], folderID: String? = nil) async {
        // 防止重复调用
        guard !isImporting else { return }
        isImporting = true
        progress = ImportProgress()

        currentTask = Task { [weak self] in
            guard let self else { return }

            defer {
                self.isImporting = false
                self.currentTask = nil
            }

            // 第一步：展开所有 URL，收集待处理的导入项
            let items = await self.collectImportItems(from: urls)
            guard !items.isEmpty, !Task.isCancelled else {
                self.progress.totalFiles = 0
                self.progress.completedFiles = 0
                return
            }

            self.progress.totalFiles = items.count

            // 第二步：逐项处理（文件 I/O 为主，顺序执行避免并发竞争）
            var totalSuccess = 0
            var totalFailed = 0

            for item in items {
                guard !Task.isCancelled else { break }

                self.progress.currentFileName = item.displayName

                let success = await self.processImportItem(item, folderID: folderID)

                self.progress.completedFiles += 1
                if success {
                    self.progress.successfulImports += 1
                    totalSuccess += 1
                } else {
                    self.progress.failedImports += 1
                    totalFailed += 1
                }
            }

            let result = ImportResult(
                totalFiles: items.count,
                successfulImports: totalSuccess,
                failedImports: totalFailed
            )

            // 第三步：完成后触发扫描刷新
            if result.allSucceeded || result.hasFailures {
                await LocalWallpaperScanner.shared.forceRescan()
                // 发送变更通知，让 ViewModel 知道内容变了
                NotificationCenter.default.post(name: .wallpaperDataSourceChanged, object: nil)
                print("[ImportService] Import completed: \(result.message)")
            }
        }

        await currentTask?.value
    }

    // MARK: - 导入项分类

    private enum ImportItemType {
        case wallpaper(sourceURL: URL)
        case media(sourceURL: URL)
        case workshop(directoryURL: URL, projectJSONURL: URL, json: [String: Any])
    }

    private struct ImportItem {
        let type: ImportItemType
        var displayName: String {
            switch type {
            case .wallpaper(let url), .media(let url):
                return url.lastPathComponent
            case .workshop(let dirURL, _, _):
                return dirURL.lastPathComponent
            }
        }
    }

    /// 展开用户选择的 URL，收集所有待导入项
    private func collectImportItems(from urls: [URL]) async -> [ImportItem] {
        var items: [ImportItem] = []

        for url in urls {
            guard !Task.isCancelled else { break }

            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }

            if isDir.boolValue {
                // 目录：先检查是否是 Workshop 项目（含 project.json）
                if let workshopItem = findWorkshopItem(in: url) {
                    items.append(workshopItem)
                } else {
                    // 普通目录：递归扫描子文件
                    let subItems = await scanDirectory(url)
                    items.append(contentsOf: subItems)
                }
            } else {
                // 文件
                let ext = url.pathExtension.lowercased()
                if ext == "pkg" {
                    // .pkg 文件：取上级目录作为 Workshop 源
                    let parentDir = url.deletingLastPathComponent()
                    if let workshopItem = findWorkshopItem(in: parentDir) {
                        items.append(workshopItem)
                    } else {
                        print("[ImportService] .pkg file found but no project.json in parent dir: \(parentDir.path)")
                    }
                } else if isImageFile(url) {
                    items.append(ImportItem(type: .wallpaper(sourceURL: url)))
                } else if isVideoFile(url) {
                    items.append(ImportItem(type: .media(sourceURL: url)))
                } else {
                    print("[ImportService] Skipping unsupported file: \(url.lastPathComponent)")
                }
            }
        }

        return items
    }

    /// 递归扫描目录中的所有支持文件
    private func scanDirectory(_ dir: URL) async -> [ImportItem] {
        var items: [ImportItem] = []

        // 在同步上下文中收集文件，避免 FileManager.Enumerator 的 Sequence 冲突
        let collectedURLs: [URL] = {
            guard let enumerator = fileManager.enumerator(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { return [] }

            var urls: [URL] = []
            for case let fileURL as URL in enumerator {
                urls.append(fileURL)
            }
            return urls
        }()

        for fileURL in collectedURLs {
            guard !Task.isCancelled else { break }

            var isDir: AnyObject?
            try? (fileURL as NSURL).getResourceValue(&isDir, forKey: URLResourceKey.isDirectoryKey)
            let isDirectory = isDir as? Bool ?? false

            if isDirectory { continue } // 不递归子目录（避免扫描 workshop 深层结构）

            if isImageFile(fileURL) {
                items.append(ImportItem(type: .wallpaper(sourceURL: fileURL)))
            } else if isVideoFile(fileURL) {
                items.append(ImportItem(type: .media(sourceURL: fileURL)))
            }
        }
        return items
    }

    /// 在指定目录中查找 project.json → Workshop 项目
    private func findWorkshopItem(in dir: URL) -> ImportItem? {
        guard let enumerator = fileManager.enumerator(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }

        for case let fileURL as URL in enumerator {
            if fileURL.lastPathComponent == "project.json" {
                guard let data = try? Data(contentsOf: fileURL),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return nil
                }
                return ImportItem(
                    type: .workshop(
                        directoryURL: dir,
                        projectJSONURL: fileURL,
                        json: json
                    )
                )
            }
        }
        return nil
    }

    // MARK: - 处理单个导入项

    private func processImportItem(_ item: ImportItem, folderID: String?) async -> Bool {
        switch item.type {
        case .wallpaper(let sourceURL):
            return importWallpaper(from: sourceURL, folderID: folderID)
        case .media(let sourceURL):
            return await importMedia(from: sourceURL, folderID: folderID)
        case .workshop(let dirURL, let projectJSONURL, let json):
            return importWorkshop(
                sourceDir: dirURL,
                projectJSONURL: projectJSONURL,
                json: json,
                folderID: folderID
            )
        }
    }

    // MARK: - 壁纸导入

    private func importWallpaper(from sourceURL: URL, folderID: String?) -> Bool {
        guard downloadPathManager.createDirectoryStructure() else {
            print("[ImportService] Failed to create directory structure")
            return false
        }

        let destinationFolder = downloadPathManager.wallpapersFolderURL
        let destURL = destinationFolder.appendingPathComponent(sourceURL.lastPathComponent)

        do {
            if sourceURL.standardizedFileURL != destURL.standardizedFileURL {
                if fileManager.fileExists(atPath: destURL.path) {
                    try fileManager.removeItem(at: destURL)
                }
                try fileManager.copyItem(at: sourceURL, to: destURL)
            }

            let wallpaper = makeImportedWallpaper(from: destURL)
            wallpaperLibrary.recordDownload(wallpaper, fileURL: destURL)

            // 如果指定了文件夹，归入该文件夹
            if let folderID {
                wallpaperLibrary.moveWallpaperToFolder(wallpaperID: wallpaper.id, folderID: folderID)
            }

            return true
        } catch {
            print("[ImportService] Failed to import wallpaper \(sourceURL.lastPathComponent): \(error)")
            return false
        }
    }

    /// 从导入的图片文件创建 Wallpaper 对象
    private func makeImportedWallpaper(from fileURL: URL) -> Wallpaper {
        let fileName = fileURL.lastPathComponent
        let id: String
        if fileName.hasPrefix("wallhaven-"), let dotIndex = fileName.firstIndex(of: ".") {
            let start = fileName.index(fileName.startIndex, offsetBy: 10)
            let extracted = String(fileName[start..<dotIndex])
            id = extracted.isEmpty ? "local_import_\(UUID().uuidString.prefix(8))" : extracted
        } else {
            id = "local_import_\(fileURL.deletingPathExtension().lastPathComponent)"
        }

        let localPath = fileURL.absoluteString
        var dimensionX = 1920
        var dimensionY = 1080
        if let imageSource = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any],
           let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
           let height = properties[kCGImagePropertyPixelHeight as String] as? Int {
            if let orientation = properties[kCGImagePropertyOrientation as String] as? UInt32,
               (5...8).contains(orientation) {
                dimensionX = height
                dimensionY = width
            } else {
                dimensionX = width
                dimensionY = height
            }
        }
        let resolution = "\(dimensionX)x\(dimensionY)"
        let ratio = dimensionY > 0 ? Double(dimensionX) / Double(dimensionY) : 1.77

        return Wallpaper(
            id: id,
            title: nil,
            url: localPath,
            shortUrl: nil,
            views: 0,
            favorites: 0,
            downloads: nil,
            source: nil,
            purity: "sfw",
            category: "general",
            dimensionX: dimensionX,
            dimensionY: dimensionY,
            resolution: resolution,
            ratio: String(format: "%.2f", ratio),
            fileSize: nil,
            fileType: nil,
            createdAt: nil,
            colors: [],
            path: localPath,
            thumbs: Wallpaper.Thumbs(large: localPath, original: localPath, small: localPath),
            tags: nil,
            uploader: nil
        )
    }

    // MARK: - 媒体导入

    private func importMedia(from sourceURL: URL, folderID: String?) async -> Bool {
        guard downloadPathManager.createDirectoryStructure() else {
            print("[ImportService] Failed to create directory structure")
            return false
        }

        let destinationFolder = downloadPathManager.mediaFolderURL
        let destURL = destinationFolder.appendingPathComponent(sourceURL.lastPathComponent)

        do {
            if sourceURL.standardizedFileURL != destURL.standardizedFileURL {
                if fileManager.fileExists(atPath: destURL.path) {
                    try fileManager.removeItem(at: destURL)
                }
                try fileManager.copyItem(at: sourceURL, to: destURL)
            }

            let mediaItem = await makeImportedMediaItem(from: destURL)
            mediaLibrary.recordDownload(item: mediaItem, localFileURL: destURL)

            // 如果指定了文件夹，归入该文件夹
            if let folderID {
                mediaLibrary.moveMediaToFolder(mediaID: mediaItem.id, folderID: folderID)
            }

            return true
        } catch {
            print("[ImportService] Failed to import media \(sourceURL.lastPathComponent): \(error)")
            return false
        }
    }

    /// 从导入的视频文件创建 MediaItem 对象
    private func makeImportedMediaItem(from fileURL: URL) async -> MediaItem {
        let fileName = fileURL.lastPathComponent
        let slug: String
        if fileName.hasPrefix("motionbgs-") {
            let parts = fileName.split(separator: "-")
            if parts.count >= 2 {
                slug = String(parts[1])
            } else {
                slug = "local_import_\(fileURL.deletingPathExtension().lastPathComponent)"
            }
        } else {
            slug = "local_import_\(fileURL.deletingPathExtension().lastPathComponent)"
        }

        let title = fileURL.deletingPathExtension().lastPathComponent
        var resolutionLabel = t("unknown")
        var durationSeconds: Double?

        let asset = AVAsset(url: fileURL)
        do {
            let tracks = try await asset.loadTracks(withMediaType: .video)
            if let track = tracks.first {
                let naturalSize = try await track.load(.naturalSize)
                let preferredTransform = try await track.load(.preferredTransform)
                let size = naturalSize.applying(preferredTransform)
                let w = Int(abs(size.width))
                let h = Int(abs(size.height))
                resolutionLabel = "\(w)x\(h)"
            }
            let duration = try await asset.load(.duration)
            if duration.isValid, duration != CMTime.indefinite {
                durationSeconds = CMTimeGetSeconds(duration)
            }
        } catch {
            print("[ImportService] Failed to load video metadata: \(error)")
        }

        // 生成并缓存第一帧缩略图
        _ = await VideoThumbnailCache.shared.thumbnailImage(for: fileURL)
        let thumbnailURL = VideoThumbnailCache.shared.thumbnailURL(for: fileURL)

        return MediaItem(
            slug: slug,
            title: title,
            pageURL: fileURL,
            thumbnailURL: thumbnailURL,
            resolutionLabel: resolutionLabel,
            collectionTitle: t("imported"),
            summary: nil,
            previewVideoURL: fileURL,
            posterURL: thumbnailURL,
            tags: [],
            exactResolution: resolutionLabel,
            durationSeconds: durationSeconds,
            downloadOptions: [],
            sourceName: t("import"),
            isAnimatedImage: nil
        )
    }

    // MARK: - Workshop 导入

    private func importWorkshop(
        sourceDir: URL,
        projectJSONURL: URL,
        json: [String: Any],
        folderID: String?
    ) -> Bool {
        guard downloadPathManager.createDirectoryStructure() else {
            print("[ImportService] Failed to create directory structure")
            return false
        }

        let sourceName = sourceDir.lastPathComponent
        let destinationRoot = downloadPathManager.mediaFolderURL

        let title = (json["title"] as? String) ?? sourceName
        // 提取真实 Steam Workshop ID。优先级：
        // 1) WE 规范字段 workshopid（发布到 Workshop 的项目都会写）
        // 2) 兼容本 App 旧版写入的 publishedfileid / id
        // 3) workshopurl 里的 ID（steam://url/CommunityFilePage/<id>）
        // 4) 文件夹名中的纯数字
        // 都拿不到时才用 hash 作为本地 slug，绝不当作真实 Steam ID 拼链接。
        var workshopID = (json["workshopid"] as? String)
            ?? (json["publishedfileid"] as? String)
            ?? (json["id"] as? String)
        workshopID = workshopID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if workshopID == nil || workshopID!.isEmpty,
           let rawURL = json["workshopurl"] as? String {
            let urlStr = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if !urlStr.isEmpty, let extracted = Self.extractSteamID(from: urlStr) {
                workshopID = extracted
            }
        }
        if workshopID == nil || workshopID!.isEmpty {
            let numeric = sourceName.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
            if !numeric.isEmpty {
                workshopID = numeric
            }
        }

        // 真实 Steam ID 必须是纯数字；非数字值（如旧版 hash）不能当作 Steam ID
        let realSteamID = workshopID.flatMap { id -> String? in
            !id.isEmpty && id.allSatisfy(\.isNumber) ? id : nil
        }

        // 本地 slug：有真实 ID 就用，没有就生成稳定的本地 hash（仅用于目录名/去重，不暴露为 Steam 链接）
        let localSlug: String
        if let realSteamID {
            localSlug = realSteamID
        } else {
            let hash = String(format: "%08x", sourceDir.absoluteString.hashValue & 0xFFFFFFFF)
            localSlug = hash.isEmpty ? String(UUID().uuidString.prefix(8)) : hash
            print("[ImportService] Non-numeric folder name '\(sourceName)', using local slug: \(localSlug) (no real Steam ID)")
        }

        guard !localSlug.isEmpty else {
            print("[ImportService] Could not infer workshop ID for \(sourceName)")
            return false
        }

        let destDir = destinationRoot.appendingPathComponent("workshop_\(localSlug)")
        do {
            if fileManager.fileExists(atPath: destDir.path) {
                try fileManager.removeItem(at: destDir)
            }
            try fileManager.copyItem(at: sourceDir, to: destDir)

            let previewURL = findPreview(in: destDir)
            let item = makeImportedWorkshopItem(
                localSlug: localSlug,
                steamID: realSteamID,
                title: title,
                projectJSON: json,
                destDir: destDir,
                previewURL: previewURL
            )
            mediaLibrary.recordDownload(item: item, localFileURL: destDir)

            if let folderID {
                mediaLibrary.moveMediaToFolder(mediaID: item.id, folderID: folderID)
            }

            return true
        } catch {
            print("[ImportService] Failed to import workshop \(sourceName): \(error)")
            return false
        }
    }

    /// 在指定目录中递归查找预览图
    private func findPreview(in dir: URL) -> URL? {
        guard let enumerator = fileManager.enumerator(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }

        for case let fileURL as URL in enumerator {
            let name = fileURL.lastPathComponent.lowercased()
            if name == "preview.jpg" || name == "preview.jpeg" || name == "preview.png" || name == "preview.webp" || name == "preview.gif" {
                return fileURL
            }
        }
        return nil
    }

    private func makeImportedWorkshopItem(
        localSlug: String,
        steamID: String?,
        title: String,
        projectJSON: [String: Any],
        destDir: URL,
        previewURL: URL?
    ) -> MediaItem {
        let typeString = (projectJSON["type"] as? String) ?? "pkg"
        let resolutionLabel = typeString.capitalized
        let thumbnailURL = previewURL ?? URL(string: "https://steamcommunity.com/favicon.ico")!

        // 只有拿到真实纯数字 Steam ID 时才生成 Steam 链接；
        // 否则用本地导入目录 file URL，避免把本地 hash/UUID 伪造成打不开的 Steam URL。
        let pageURL: URL
        if let steamID {
            pageURL = URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(steamID)")!
        } else {
            pageURL = destDir
        }

        return MediaItem(
            slug: "workshop_\(localSlug)",
            title: title,
            pageURL: pageURL,
            thumbnailURL: thumbnailURL,
            resolutionLabel: resolutionLabel,
            collectionTitle: t("workshop"),
            summary: (projectJSON["description"] as? String),
            previewVideoURL: nil,
            posterURL: previewURL,
            tags: [],
            exactResolution: nil,
            durationSeconds: nil,
            downloadOptions: [],
            sourceName: t("wallpaperEngine"),
            isAnimatedImage: nil
        )
    }

    /// 从 Steam 链接里提取 Workshop ID，支持：
    /// - https://steamcommunity.com/sharedfiles/filedetails/?id=3741983456
    /// - steam://url/CommunityFilePage/3741983456
    /// - 纯数字
    private static func extractSteamID(from urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.allSatisfy(\.isNumber), !trimmed.isEmpty { return trimmed }

        guard let url = URL(string: trimmed),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        let path = components.path.lowercased()
        // https 形式：取 query 的 id
        if path.contains("sharedfiles/filedetails") {
            return components.queryItems?.first(where: { $0.name.lowercased() == "id" })?.value
        }

        // steam://url/CommunityFilePage/<id> 形式：取最后一段路径
        if trimmed.lowercased().hasPrefix("steam://"),
           path.contains("communityfilepage") {
            return path.split(separator: "/").last.map(String.init)
        }

        return nil
    }

    // MARK: - 文件类型判断

    private func isImageFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "webp", "gif", "bmp", "tiff", "heic"].contains(ext)
    }

    private func isVideoFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ["mp4", "mov", "avi", "mkv", "webm", "m4v", "flv"].contains(ext)
    }
}
