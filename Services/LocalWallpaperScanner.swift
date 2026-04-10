import Foundation
import AppKit
import AVFoundation

/// 本地壁纸扫描服务
/// 自动检测用户复制到下载目录的壁纸和媒体文件，生成基本元数据
@MainActor
final class LocalWallpaperScanner {
    static let shared = LocalWallpaperScanner()
    
    private let downloadPathManager = DownloadPathManager.shared
    private let fileManager = FileManager.default
    
    // 缓存扫描结果
    private var scannedWallpapers: [LocalWallpaperItem] = []
    private var scannedMediaItems: [LocalMediaItem] = []
    private var lastScanTime: Date?
    
    // 扫描间隔（秒）- 增加到 30 秒避免频繁扫描
    private let scanInterval: TimeInterval = 30
    
    private init() {}
    
    // MARK: - 公共方法
    
    /// 获取所有本地壁纸（包括扫描到的文件）
    /// - Returns: 本地壁纸项目数组
    func getLocalWallpapers() -> [LocalWallpaperItem] {
        // 检查是否需要重新扫描
        if shouldRescan() {
            Task {
                await scanLocalFiles()
            }
        }
        return scannedWallpapers
    }
    
    /// 获取所有本地媒体（包括扫描到的文件）
    /// - Returns: 本地媒体项目数组
    func getLocalMedia() -> [LocalMediaItem] {
        if shouldRescan() {
            Task {
                await scanLocalFiles()
            }
        }
        return scannedMediaItems
    }
    
    /// 强制重新扫描本地文件
    func forceRescan() async {
        await scanLocalFiles()
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
    
    private func scanLocalFiles() async {
        let startTime = Date()
        print("[LocalWallpaperScanner] Starting local file scan...")
        
        var wallpapers: [LocalWallpaperItem] = []
        var mediaItems: [LocalMediaItem] = []
        
        // 扫描壁纸目录
        let wallpapersFolder = downloadPathManager.wallpapersFolderURL
        if fileManager.fileExists(atPath: wallpapersFolder.path) {
            do {
                let contents = try fileManager.contentsOfDirectory(
                    at: wallpapersFolder,
                    includingPropertiesForKeys: [.contentTypeKey, .fileSizeKey],
                    options: .skipsHiddenFiles
                )
                
                for fileURL in contents {
                    if isImageFile(fileURL) {
                        if let item = createWallpaperItem(from: fileURL) {
                            wallpapers.append(item)
                        }
                    }
                }
            } catch {
                print("[LocalWallpaperScanner] Failed to scan wallpapers folder: \(error)")
            }
        }
        
        // 扫描媒体目录
        let mediaFolder = downloadPathManager.mediaFolderURL
        if fileManager.fileExists(atPath: mediaFolder.path) {
            do {
                let contents = try fileManager.contentsOfDirectory(
                    at: mediaFolder,
                    includingPropertiesForKeys: [.contentTypeKey, .fileSizeKey],
                    options: .skipsHiddenFiles
                )
                
                for fileURL in contents {
                    if isVideoFile(fileURL) {
                        if let item = await createMediaItem(from: fileURL) {
                            mediaItems.append(item)
                        }
                    }
                }
            } catch {
                print("[LocalWallpaperScanner] Failed to scan media folder: \(error)")
            }
        }
        
        // 扫描旧版根目录（兼容性）
        let legacyFolder = downloadPathManager.legacyFolderURL
        if fileManager.fileExists(atPath: legacyFolder.path) {
            do {
                let contents = try fileManager.contentsOfDirectory(
                    at: legacyFolder,
                    includingPropertiesForKeys: [.contentTypeKey, .fileSizeKey],
                    options: .skipsHiddenFiles
                )
                
                for fileURL in contents where !fileURL.hasDirectoryPath {
                    if isImageFile(fileURL) {
                        if let item = createWallpaperItem(from: fileURL),
                           !wallpapers.contains(where: { $0.id == item.id }) {
                            wallpapers.append(item)
                        }
                    } else if isVideoFile(fileURL) {
                        if let item = await createMediaItem(from: fileURL),
                           !mediaItems.contains(where: { $0.id == item.id }) {
                            mediaItems.append(item)
                        }
                    }
                }
            } catch {
                print("[LocalWallpaperScanner] Failed to scan legacy folder: \(error)")
            }
        }
        
        scannedWallpapers = wallpapers
        scannedMediaItems = mediaItems
        lastScanTime = Date()
        
        print("[LocalWallpaperScanner] Scan completed in \(Date().timeIntervalSince(startTime))s, found \(wallpapers.count) wallpapers, \(mediaItems.count) media files")
    }
    
    // MARK: - 创建元数据
    
    private func createWallpaperItem(from fileURL: URL) -> LocalWallpaperItem? {
        let fileName = fileURL.deletingPathExtension().lastPathComponent
        let fileExtension = fileURL.pathExtension.lowercased()
        
        // 尝试从文件读取分辨率
        let dimensions = getImageDimensions(fileURL)
        let resolution = dimensions.map { "\($0.width)x\($0.height)" } ?? "Unknown"
        let ratio = dimensions.map { String(format: "%.2f", Double($0.width) / Double($0.height)) } ?? "1.78"
        
        // 生成唯一 ID
        let id = "local_\(fileName)_\(fileExtension)"
        
        return LocalWallpaperItem(
            id: id,
            fileURL: fileURL,
            fileName: fileName,
            title: fileName.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " "),
            resolution: resolution,
            dimensionX: dimensions?.width ?? 1920,
            dimensionY: dimensions?.height ?? 1080,
            ratio: ratio,
            fileSize: getFileSize(fileURL),
            fileType: getMimeType(fileExtension),
            createdAt: getCreationDate(fileURL)
        )
    }
    
    private func createMediaItem(from fileURL: URL) async -> LocalMediaItem? {
        let fileName = fileURL.deletingPathExtension().lastPathComponent
        let fileExtension = fileURL.pathExtension.lowercased()
        
        // 尝试解析文件名获取信息
        let (parsedTitle, parsedResolution) = parseMediaFileName(fileName)
        
        // 尝试从视频文件读取分辨率（使用新的异步 API）
        let videoDimensions = await getVideoDimensions(fileURL)
        let finalResolution = videoDimensions.map { "\($0.width)x\($0.height)" } ?? parsedResolution
        
        // 获取视频时长（使用新的异步 API）
        let duration = await getVideoDuration(fileURL)
        
        let id = "local_\(fileName)_\(fileExtension)"
        
        return LocalMediaItem(
            id: id,
            fileURL: fileURL,
            fileName: fileName,
            title: parsedTitle,
            resolution: finalResolution,
            duration: duration,
            fileSize: getFileSize(fileURL),
            fileType: getMimeType(fileExtension),
            createdAt: getCreationDate(fileURL)
        )
    }
    
    // MARK: - 文件类型检查
    
    private func isImageFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "webp", "gif", "bmp", "tiff", "heic"].contains(ext)
    }
    
    private func isVideoFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ["mp4", "mov", "avi", "mkv", "webm", "m4v", "flv"].contains(ext)
    }
    
    // MARK: - 元数据提取
    
    /// 获取图片尺寸
    private func getImageDimensions(_ url: URL) -> (width: Int, height: Int)? {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        
        guard let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int else {
            return nil
        }
        
        // 检查方向，可能需要交换宽高
        if let orientation = properties[kCGImagePropertyOrientation as String] as? UInt32 {
            switch orientation {
            case 5, 6, 7, 8: // 需要交换宽高
                return (height, width)
            default:
                break
            }
        }
        
        return (width, height)
    }
    
    /// 获取视频尺寸
    private func getVideoDimensions(_ url: URL) async -> (width: Int, height: Int)? {
        let asset = AVAsset(url: url)
        
        do {
            // 使用新的异步 API 加载视频轨道
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let track = tracks.first else {
                return nil
            }
            
            // 使用新的异步 API 加载尺寸和变换
            let naturalSize = try await track.load(.naturalSize)
            let preferredTransform = try await track.load(.preferredTransform)
            
            let size = naturalSize.applying(preferredTransform)
            let width = abs(Int(size.width))
            let height = abs(Int(size.height))
            
            return (width, height)
        } catch {
            print("[LocalWallpaperScanner] Failed to get video dimensions: \(error)")
            return nil
        }
    }
    
    /// 获取视频时长
    private func getVideoDuration(_ url: URL) async -> Double? {
        let asset = AVAsset(url: url)
        
        do {
            // 使用新的异步 API 加载时长
            let duration = try await asset.load(.duration)
            guard duration.isValid, duration != CMTime.indefinite else {
                return nil
            }
            return CMTimeGetSeconds(duration)
        } catch {
            print("[LocalWallpaperScanner] Failed to get video duration: \(error)")
            return nil
        }
    }
    
    /// 获取文件大小
    private func getFileSize(_ url: URL) -> Int? {
        do {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            return attributes[.size] as? Int
        } catch {
            return nil
        }
    }
    
    /// 获取文件创建日期
    private func getCreationDate(_ url: URL) -> String? {
        do {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            if let date = attributes[.creationDate] as? Date {
                let formatter = ISO8601DateFormatter()
                return formatter.string(from: date)
            }
        } catch {
            print("[LocalWallpaperScanner] Failed to get creation date: \(error)")
        }
        return nil
    }
    
    /// 解析媒体文件名
    /// 格式示例: "motionbgs-video-name-4k.mp4" 或 "My Video 1080p"
    private func parseMediaFileName(_ fileName: String) -> (title: String, resolution: String?) {
        // 尝试提取分辨率
        let patterns = [
            ("(\\d{3,4})p", 1),           // 1080p, 720p
            ("(\\d{4})x(\\d{3,4})", 0),   // 1920x1080
            ("(4k|8k|2k)", 1),            // 4K, 8K (case insensitive)
            ("(hd|fullhd|fhd)", 1),       // HD, FullHD
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
                    // 从标题中移除分辨率部分
                    modifiedName = regex.stringByReplacingMatches(
                        in: modifiedName,
                        options: [],
                        range: range,
                        withTemplate: ""
                    )
                }
            }
        }
        
        // 清理标题
        let cleanTitle = modifiedName
            .replacingOccurrences(of: "motionbgs-", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "wallhaven-", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespaces)
        
        return (cleanTitle.isEmpty ? fileName : cleanTitle, foundResolution)
    }
    
    /// 获取 MIME 类型
    private func getMimeType(_ ext: String) -> String? {
        let typeMap: [String: String] = [
            "jpg": "image/jpeg",
            "jpeg": "image/jpeg",
            "png": "image/png",
            "webp": "image/webp",
            "gif": "image/gif",
            "bmp": "image/bmp",
            "tiff": "image/tiff",
            "heic": "image/heic",
            "mp4": "video/mp4",
            "mov": "video/quicktime",
            "avi": "video/x-msvideo",
            "mkv": "video/x-matroska",
            "webm": "video/webm",
            "m4v": "video/mp4",
            "flv": "video/x-flv"
        ]
        return typeMap[ext.lowercased()]
    }
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
        
        // 获取缩略图 URL（如果有缓存则使用缓存，否则使用视频 URL 让 Kingfisher 生成）
        let thumbnailURL = VideoThumbnailCache.shared.thumbnailURL(for: fileURL)
        
        return MediaItem(
            slug: id,
            title: title,
            pageURL: fileURL,
            thumbnailURL: thumbnailURL,
            resolutionLabel: resolutionLabel,
            collectionTitle: t("local.files"),
            summary: t("local.imported.video"),
            previewVideoURL: fileURL,
            posterURL: thumbnailURL,
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
