import Foundation
import AVFoundation
import AppKit
import CryptoKit
import Kingfisher

/// 视频缩略图缓存服务
/// 为本地视频文件生成并缓存缩略图
@MainActor
final class VideoThumbnailCache {
    static let shared = VideoThumbnailCache()
    
    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    private let memoryCache = NSCache<NSString, NSImage>()
    
    private init() {
        // 设置缓存目录
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
        cacheDirectory = caches[0].appendingPathComponent("WaifuX/VideoThumbnails", isDirectory: true)
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        memoryCache.countLimit = 50
        memoryCache.totalCostLimit = 50 * 1024 * 1024 // 50MB
    }

    /// 清理内存缓存，用于内存压力响应
    func clearMemoryCache() {
        memoryCache.removeAllObjects()
    }
    
    /// 若已为本地媒体生成过列表缩略图（`generateThumbnail`）或动态壁纸海报帧（`posterJPEGFileURL`），返回对应磁盘文件 URL。
    /// 供「我的库」等场景优先于站点封面展示截取静帧。
    func cachedStaticThumbnailFileURLIfExists(forLocalFile mediaURL: URL) -> URL? {
        guard mediaURL.isFileURL else { return nil }
        let path = mediaURL.standardizedFileURL.path
        guard fileManager.fileExists(atPath: path) else { return nil }

        let thumb = cacheURL(for: mediaURL)
        if fileManager.fileExists(atPath: thumb.path) { return thumb }

        let poster = posterCacheURL(forPathKey: path)
        if fileManager.fileExists(atPath: poster.path) { return poster }

        return nil
    }

    /// 获取视频缩略图 URL
    /// - Parameter videoURL: 视频文件 URL
    /// - Returns: 缩略图 URL（可能是缓存的文件 URL，也可能是原始视频 URL）
    func thumbnailURL(for videoURL: URL) -> URL {
        // 检查内存缓存
        let cacheKey = videoURL.absoluteString as NSString
        if memoryCache.object(forKey: cacheKey) != nil {
            return cacheURL(for: videoURL)
        }
        
        // 检查磁盘缓存
        let cachedURL = cacheURL(for: videoURL)
        if fileManager.fileExists(atPath: cachedURL.path) {
            return cachedURL
        }
        
        // 异步生成缩略图
        Task {
            await generateThumbnail(for: videoURL)
        }
        
        // 返回视频 URL（Kingfisher 会处理生成）
        return videoURL
    }
    
    /// 从本地视频抽一帧为 JPEG，用作动态壁纸的**静态桌面/锁屏**底图（与 `VideoWallpaperManager.setPosterAsDesktopWallpaper` 配套）。
    /// - Note: 输出在 `VideoThumbnails` 目录，文件名由视频路径哈希决定；失败时返回 `nil`。
    func posterJPEGFileURL(forLocalVideo videoURL: URL) async -> URL? {
        guard videoURL.isFileURL else { return nil }
        let pathKey = videoURL.standardizedFileURL.path
        guard fileManager.fileExists(atPath: pathKey) else { return nil }

        let outURL = posterCacheURL(forPathKey: pathKey)
        if fileManager.fileExists(atPath: outURL.path),
           let attrs = try? fileManager.attributesOfItem(atPath: outURL.path),
           let sz = attrs[.size] as? NSNumber, sz.intValue > 500 {
            return outURL
        }

        let fileURL = URL(fileURLWithPath: pathKey)
        return await generatePosterJPEGFile(from: fileURL, outputURL: outURL)
    }

    /// 动态壁纸的锁屏/静态桌面底图：对 mp4/mov/webm/m4v 从片源抽高清帧，失败或未识别扩展名时回退为站点封面等。
    func lockScreenPosterURL(forLocalVideo localVideoURL: URL, fallbackPosterURL: URL?) async -> URL? {
        let ext = localVideoURL.pathExtension.lowercased()
        guard ["mp4", "mov", "webm", "m4v"].contains(ext) else { return fallbackPosterURL }
        return await posterJPEGFileURL(forLocalVideo: localVideoURL) ?? fallbackPosterURL
    }

    private func posterCacheURL(forPathKey pathKey: String) -> URL {
        cacheDirectory.appendingPathComponent("poster_wallpaper_\(pathKey.md5).jpg")
    }

    private func generatePosterJPEGFile(from videoURL: URL, outputURL: URL) async -> URL? {
        await Task.detached(priority: .utility) {
            let asset = AVAsset(url: videoURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 3840, height: 2160)

            // 计算候选时间点：优先中间帧，回退到 30%/70%/1s，避免第一帧（可能是黑屏/过渡）
            var candidates: [Double] = []
            if let duration = try? await asset.load(.duration) {
                let d = CMTimeGetSeconds(duration)
                if d.isFinite, d > 0 {
                    // 主候选：中间时间点；回退：30%、70%、1秒
                    candidates = [d * 0.5, d * 0.3, d * 0.7, min(d * 0.1, 2.0)]
                        .filter { $0 >= 0.2 }  // 过滤掉太靠前的（避免第一帧）
                    // 去重并保持顺序
                    var seen = Set<Double>()
                    candidates = candidates.compactMap {
                        let rounded = (($0 * 10).rounded() / 10)
                        guard !seen.contains(rounded) else { return nil }
                        seen.insert(rounded)
                        return $0
                    }
                }
            }
            // 兜底：如果所有候选都被过滤（如超短视频），回退到第一帧
            if candidates.isEmpty {
                candidates = [0.0]
            }

            // 多点尝试，任一成功即返回
            for seconds in candidates {
                let t = CMTime(seconds: seconds, preferredTimescale: 600)
                do {
                    let cgImage = try generator.copyCGImage(at: t, actualTime: nil)
                    let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                    guard let tiff = image.tiffRepresentation,
                          let rep = NSBitmapImageRep(data: tiff),
                          let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.88]) else {
                        continue
                    }
                    try jpeg.write(to: outputURL, options: .atomic)
                    print("[VideoThumbnailCache] Poster frame at \(String(format: "%.1f", seconds))s for wallpaper: \(outputURL.path)")
                    return outputURL
                } catch {
                    print("[VideoThumbnailCache] Poster try at \(String(format: "%.1f", seconds))s failed: \(error)")
                    continue
                }
            }

            print("[VideoThumbnailCache] All poster frame attempts exhausted for \(videoURL.lastPathComponent)")
            return nil
        }.value
    }

    /// 获取缩略图图片
    /// - Parameter videoURL: 视频文件 URL
    /// - Returns: 缩略图
    func thumbnailImage(for videoURL: URL) async -> NSImage? {
        let cacheKey = videoURL.absoluteString as NSString
        
        // 检查内存缓存
        if let cached = memoryCache.object(forKey: cacheKey) {
            return cached
        }
        
        // 检查磁盘缓存
        let cachedURL = cacheURL(for: videoURL)
        if fileManager.fileExists(atPath: cachedURL.path),
           let data = try? Data(contentsOf: cachedURL),
           let image = NSImage(data: data) {
            memoryCache.setObject(image, forKey: cacheKey)
            return image
        }
        
        // 生成缩略图
        return await generateThumbnail(for: videoURL)
    }
    
    /// 生成并缓存缩略图
    @discardableResult
    private func generateThumbnail(for videoURL: URL) async -> NSImage? {
        let cacheKeyString = videoURL.absoluteString
        
        return await Task.detached(priority: .utility) { [weak self] in
            guard let self = self else { return nil }
            
            let asset = AVAsset(url: videoURL)
            let imageGenerator = AVAssetImageGenerator(asset: asset)
            imageGenerator.appliesPreferredTrackTransform = true
            imageGenerator.maximumSize = CGSize(width: 800, height: 600)
            
            do {
                let cgImage = try imageGenerator.copyCGImage(
                    at: CMTime(seconds: 0, preferredTimescale: 1),
                    actualTime: nil
                )
                
                let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                let cost = Int(cgImage.width * cgImage.height * 4)
                
                // 保存到内存缓存
                await MainActor.run {
                    let cacheKey = cacheKeyString as NSString
                    self.memoryCache.setObject(image, forKey: cacheKey, cost: cost)
                }
                
                // 保存到磁盘缓存
                let cachedURL = await self.cacheURL(for: videoURL)
                if let data = image.tiffRepresentation,
                   let bitmap = NSBitmapImageRep(data: data),
                   let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
                    try? jpegData.write(to: cachedURL)
                    print("[VideoThumbnailCache] Generated and cached thumbnail: \(cachedURL.path)")
                }
                
                return image
            } catch {
                print("[VideoThumbnailCache] Failed to generate thumbnail for \(videoURL.lastPathComponent): \(error)")
                return nil
            }
        }.value
    }
    
    /// 获取缓存 URL
    private func cacheURL(for videoURL: URL) -> URL {
        let hash = videoURL.absoluteString.md5
        return cacheDirectory.appendingPathComponent("\(hash).jpg")
    }
    
    /// 迁移缓存键：将旧路径对应的缓存文件重命名为新路径对应的缓存文件名。
    /// 遍历所有下载记录中的视频文件，计算旧/新 MD5 缓存键并执行重命名。
    func migrateCacheKeys(fromOldPrefix oldPrefix: String, toNewPrefix newPrefix: String) {
        Task.detached(priority: .utility) { [cacheDirectory = self.cacheDirectory] in
            let fileManager = FileManager.default
            var movedCount = 0

            // 基于 media & wallpaper 下载记录重建映射
            let mediaRecords = await MainActor.run { MediaLibraryService.shared.downloadRecords }
            let wallpaperRecords = await MainActor.run { WallpaperLibraryService.shared.downloadRecords }

            for record in mediaRecords {
                let path = record.localFilePath
                guard path.hasPrefix(newPrefix) else { continue }
                let oldPath = oldPrefix + String(path.dropFirst(newPrefix.count))

                let oldURL = URL(fileURLWithPath: oldPath)
                let newURL = URL(fileURLWithPath: path)

                // 缩略图缓存
                let oldThumb = cacheDirectory.appendingPathComponent("\(oldURL.absoluteString.md5).jpg")
                let newThumb = cacheDirectory.appendingPathComponent("\(newURL.absoluteString.md5).jpg")
                if fileManager.fileExists(atPath: oldThumb.path), !fileManager.fileExists(atPath: newThumb.path) {
                    try? fileManager.moveItem(at: oldThumb, to: newThumb)
                    movedCount += 1
                }

                // 海报帧缓存
                let oldPoster = cacheDirectory.appendingPathComponent("poster_wallpaper_\(oldPath.md5).jpg")
                let newPoster = cacheDirectory.appendingPathComponent("poster_wallpaper_\(path.md5).jpg")
                if fileManager.fileExists(atPath: oldPoster.path), !fileManager.fileExists(atPath: newPoster.path) {
                    try? fileManager.moveItem(at: oldPoster, to: newPoster)
                    movedCount += 1
                }
            }

            for record in wallpaperRecords {
                let path = record.localFilePath
                guard path.hasPrefix(newPrefix) else { continue }
                let oldPath = oldPrefix + String(path.dropFirst(newPrefix.count))

                let oldURL = URL(fileURLWithPath: oldPath)
                let newURL = URL(fileURLWithPath: path)

                // 缩略图缓存
                let oldThumb = cacheDirectory.appendingPathComponent("\(oldURL.absoluteString.md5).jpg")
                let newThumb = cacheDirectory.appendingPathComponent("\(newURL.absoluteString.md5).jpg")
                if fileManager.fileExists(atPath: oldThumb.path), !fileManager.fileExists(atPath: newThumb.path) {
                    try? fileManager.moveItem(at: oldThumb, to: newThumb)
                    movedCount += 1
                }

                // 海报帧缓存
                let oldPoster = cacheDirectory.appendingPathComponent("poster_wallpaper_\(oldPath.md5).jpg")
                let newPoster = cacheDirectory.appendingPathComponent("poster_wallpaper_\(path.md5).jpg")
                if fileManager.fileExists(atPath: oldPoster.path), !fileManager.fileExists(atPath: newPoster.path) {
                    try? fileManager.moveItem(at: oldPoster, to: newPoster)
                    movedCount += 1
                }
            }

            print("[VideoThumbnailCache] Migrated \(movedCount) cache files from old paths to new paths")
        }
    }

    /// 清理过期缓存
    func cleanupCache() {
        Task.detached(priority: .utility) { [cacheDirectory = self.cacheDirectory] in
            let fileManager = FileManager.default
            let contents = (try? fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            
            // 删除超过 30 天的缓存
            let thirtyDaysAgo = Date().addingTimeInterval(-30 * 24 * 60 * 60)
            for file in contents {
                if let attrs = try? fileManager.attributesOfItem(atPath: file.path),
                   let date = attrs[.modificationDate] as? Date,
                   date < thirtyDaysAgo {
                    try? fileManager.removeItem(at: file)
                }
            }
        }
    }
}

// MARK: - String MD5 扩展

extension String {
    var md5: String {
        let data = Data(self.utf8)
        let hash = Insecure.MD5.hash(data: data)
        return hash.map { String(format: "%02hhx", $0) }.joined()
    }
}


