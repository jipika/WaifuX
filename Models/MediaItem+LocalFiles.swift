import Foundation

// MARK: - MediaItem 我的库列表封面

extension MediaItem {
    private static let libraryLocalRasterExtensions: Set<String> = [
        "jpg", "jpeg", "png", "webp", "gif", "heic", "heif", "avif", "bmp", "tiff", "tif"
    ]

    private static let videoFileExtensions: Set<String> = ["mp4", "mov", "webm", "m4v", "mkv"]
    private static let workshopStaticPreviewFallbackNames = [
        "preview.jpg", "preview.jpeg", "preview.png", "preview.webp"
    ]
    private static let workshopGIFPreviewFallbackNames = ["preview.gif"]

    nonisolated static func urlLooksLikeGIF(_ url: URL) -> Bool {
        let value = url.absoluteString.lowercased()
        return value.hasSuffix(".gif")
            || value.contains(".gif?")
            || value.contains(".gif&")
            || url.pathExtension.lowercased() == "gif"
            || value.contains("format=gif")
            || value.contains("output-format=gif")
    }

    /// 读取 Wallpaper Engine `project.json` 的 type，用于区分 Web 壁纸和可抽帧的视频类内容。
    /// 结果经 `WorkshopLibraryPreviewCache` 缓存，避免列表重建时反复读外置卡。
    nonisolated static func localWorkshopProjectType(from url: URL) -> String? {
        WorkshopLibraryPreviewCache.shared.projectType(for: url) {
            let fm = FileManager.default
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return nil }

            let resolved = WorkshopService.resolveWallpaperEngineProjectRoot(startingAt: url)
            let projectURL = resolved.appendingPathComponent("project.json")
            guard let data = try? Data(contentsOf: projectURL),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String else {
                return nil
            }
            return type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }

    /// 若 `url` 是已下载的 Wallpaper Engine 项目录，优先寻找静态本地预览图。
    /// GIF 是 hover 动画源；只有没有其他静态候选时才作为列表封面保底。
    nonisolated static func resolveLocalWorkshopPreviewImage(from url: URL) -> URL? {
        WorkshopLibraryPreviewCache.shared.previewImage(for: url) {
            let fm = FileManager.default
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return nil }

            let resolved = WorkshopService.resolveWallpaperEngineProjectRoot(startingAt: url)
            let projectURL = resolved.appendingPathComponent("project.json")
            var projectGIFPreview: URL?
            if let data = try? Data(contentsOf: projectURL),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let previewName = json["preview"] as? String {
                let trimmed = previewName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    let candidate = resolved.appendingPathComponent(trimmed)
                    if fm.fileExists(atPath: candidate.path) {
                        if !Self.urlLooksLikeGIF(candidate) {
                            return candidate
                        }
                        projectGIFPreview = candidate
                    }
                }
            }

            for name in workshopStaticPreviewFallbackNames {
                let candidate = resolved.appendingPathComponent(name)
                if fm.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
            if let projectGIFPreview {
                return projectGIFPreview
            }
            for name in workshopGIFPreviewFallbackNames {
                let candidate = resolved.appendingPathComponent(name)
                if fm.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
            return nil
        }
    }

    /// Wallpaper Engine 本地工程的真实 GIF 预览，只供 hover 播放使用。
    nonisolated static func resolveLocalWorkshopPreviewGIF(from url: URL) -> URL? {
        WorkshopLibraryPreviewCache.shared.previewGIF(for: url) {
            let fm = FileManager.default
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return nil }

            let resolved = WorkshopService.resolveWallpaperEngineProjectRoot(startingAt: url)
            let projectURL = resolved.appendingPathComponent("project.json")
            if let data = try? Data(contentsOf: projectURL),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let previewName = json["preview"] as? String {
                let candidate = resolved.appendingPathComponent(
                    previewName.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                if fm.fileExists(atPath: candidate.path), Self.urlLooksLikeGIF(candidate) {
                    return candidate
                }
            }

            for name in workshopGIFPreviewFallbackNames {
                let candidate = resolved.appendingPathComponent(name)
                if fm.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
            return nil
        }
    }

    /// 若 `url` 是目录（壁纸引擎 Workshop 项），递归查找其中的视频文件并返回；若是视频文件则直接返回。
    ///
    /// 注意：根目录有 `.pkg` 时仍可能带 `video.mp4`（混合工程），不能一票否决；
    /// 只跳过纯 scene（有 pkg 且无视频文件）的抽帧。
    nonisolated static func resolveLocalVideoFile(from url: URL) -> URL? {
        WorkshopLibraryPreviewCache.shared.videoFile(for: url) {
            let fm = FileManager.default
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }

            if !isDir.boolValue {
                return videoFileExtensions.contains(url.pathExtension.lowercased()) ? url : nil
            }

            let resolved = WorkshopService.resolveWallpaperEngineProjectRoot(startingAt: url)

            // 先浅扫工程根（常见 video.mp4 / 同级媒体）
            let rootContents = (try? fm.contentsOfDirectory(
                at: resolved,
                includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles
            )) ?? []
            if let rootVideo = rootContents.first(where: {
                videoFileExtensions.contains($0.pathExtension.lowercased())
            }) {
                return rootVideo
            }

            // 再递归（部分工程把视频放 materials/ 等子目录）
            if let enumerator = fm.enumerator(
                at: resolved,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) {
                for case let fileURL as URL in enumerator {
                    if videoFileExtensions.contains(fileURL.pathExtension.lowercased()) {
                        return fileURL
                    }
                }
            }
            return nil
        }
    }

    /// 「我的库」列表封面（仅静态 `KFImage`）：优先本机 SSD 上的小图缓存，避免从 TF/U 盘读原图。
    /// 使用 FileExistenceCache 避免主线程 FileManager.fileExists(atPath:)。
    @MainActor
    func libraryGridThumbnailURL(localFileURL: URL?) -> URL {
        let fileCache = FileExistenceCache.shared
        let staticMetadataFallback = Self.firstExistingStaticMetadataURL(
            posterURL: posterURL,
            thumbnailURL: thumbnailURL,
            fileCache: fileCache
        )
        var gifFallbackURL: URL?

        // Scene 烘焙：列表优先完整画幅列表帧；高清 poster 可能已 letterbox 裁切，作次选兜底。
        if let record = MediaLibraryService.shared.downloadRecord(for: id),
           let bakedPath = record.sceneBakeArtifact?.videoPath {
            let bakedURL = URL(fileURLWithPath: bakedPath)
            if let listThumb = VideoThumbnailCache.shared.cachedListThumbnailFileURLIfExists(forLocalVideo: bakedURL) {
                return listThumb
            }
            if let extracted = VideoThumbnailCache.shared.cachedSceneBakePosterFileURLIfExists(itemID: id) {
                return extracted
            }
        }

        // 自动烘焙关闭时，实时 Scene 只会留下按屏幕尺寸生成的静帧。
        // 没有正式 bake artifact 时也要让「我的库」优先显示这张图。
        if let extracted = VideoThumbnailCache.shared.latestSceneRealtimePosterFileURLIfExists(itemID: id) {
            return extracted
        }

        if let local = localFileURL,
           local.isFileURL,
           fileCache.fileExists(atPath: local.path) {
            let ext = local.pathExtension.lowercased()

            // GIF 保留原文件给 hover 播放，但静态封面先找抽帧 / 普通静图。
            if ext == "gif" {
                gifFallbackURL = local
            }

            // 静图：优先 SSD 列表缩略图，缺失时异步生成，列表先用站点封面
            if ext != "gif",
               Self.libraryLocalRasterExtensions.contains(ext),
               LocalImageThumbnailCache.isRasterImageFile(local) {
                if let cached = LocalImageThumbnailCache.shared.cachedThumbnailURLIfExists(forLocalFile: local) {
                    return cached
                }
                return LocalImageThumbnailCache.shared.listThumbnailURL(
                    forLocalFile: local,
                    fallbackURL: staticMetadataFallback
                )
            }

            // 直出视频文件：只读已有抽帧缓存（优先列表小图），不在列表重建时扫目录/生成
            if Self.videoFileExtensions.contains(ext),
               let extracted = VideoThumbnailCache.shared.cachedStaticThumbnailFileURLIfExists(forLocalFile: local) {
                return extracted
            }

            // Workshop 目录：
            // - 有可抽帧视频时：**优先**已有列表抽帧 / 高清 poster，preview 只作临时占位
            //   （Steam preview 往往极小，scaledToFill 后像马赛克，用户会以为「没抽帧」）
            // - 无视频（纯 scene/web）才长期用 preview / 远程封面
            if fileCache.isDirectory(atPath: local.path) {
                if let resolved = Self.resolveLocalVideoFile(from: local),
                   let extracted = VideoThumbnailCache.shared.cachedStaticThumbnailFileURLIfExists(forLocalFile: resolved) {
                    return extracted
                }
                if let localPreview = Self.resolveLocalWorkshopPreviewImage(from: local) {
                    if Self.urlLooksLikeGIF(localPreview) {
                        gifFallbackURL = localPreview
                    } else if LocalImageThumbnailCache.isRasterImageFile(localPreview),
                       let cached = LocalImageThumbnailCache.shared.cachedThumbnailURLIfExists(forLocalFile: localPreview) {
                        return cached
                    } else if LocalImageThumbnailCache.isRasterImageFile(localPreview) {
                        return LocalImageThumbnailCache.shared.listThumbnailURL(
                            forLocalFile: localPreview,
                            fallbackURL: staticMetadataFallback ?? localPreview
                        )
                    } else {
                        return localPreview
                    }
                }
            }
        }
        if let staticMetadataFallback {
            return staticMetadataFallback
        }
        if let gifFallbackURL {
            return gifFallbackURL
        }
        for candidate in [posterURL, thumbnailURL] {
            guard let candidate else { continue }
            if !candidate.isFileURL || fileCache.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return coverImageURL
    }

    @MainActor
    private static func firstExistingStaticMetadataURL(
        posterURL: URL?,
        thumbnailURL: URL,
        fileCache: FileExistenceCache
    ) -> URL? {
        for candidate in [posterURL, thumbnailURL] {
            guard let candidate, !urlLooksLikeGIF(candidate) else { continue }
            if !candidate.isFileURL || fileCache.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// 文件夹卡片封面：与夹内列表同一套「清晰源」优先级，但**只读已有 SSD 缓存**，
/// 不在此函数里同步扫外置卡/抽帧（生成由 `refreshMediaFolderDisplay` 后台预热）。
///
/// 优先级：
/// 1. scene bake 列表帧 / 高清 poster
/// 2. 本地视频列表抽帧（含 Workshop 目录内已解析视频）
/// 3. 本地静图 SSD 列表小图
/// 4. 本地 GIF / 已落盘 poster
/// 5. 站点 cover（可能偏糊，仅作占位）
    @MainActor
    func libraryFolderThumbnailURL(localFileURL: URL?) -> URL {
        let fileCache = FileExistenceCache.shared
        let videoCache = VideoThumbnailCache.shared

        // Scene 烘焙：优先完整画幅列表帧，再高清 poster
        if let record = MediaLibraryService.shared.downloadRecord(for: id),
           let bakedPath = record.sceneBakeArtifact?.videoPath,
           !bakedPath.isEmpty {
            let bakedURL = URL(fileURLWithPath: bakedPath)
            if let listThumb = videoCache.cachedListThumbnailFileURLIfExists(forLocalVideo: bakedURL) {
                return listThumb
            }
            if let extracted = videoCache.cachedSceneBakePosterFileURLIfExists(itemID: id) {
                return extracted
            }
        } else if let extracted = videoCache.cachedSceneBakePosterFileURLIfExists(itemID: id) {
            return extracted
        }

        if let extracted = videoCache.latestSceneRealtimePosterFileURLIfExists(itemID: id) {
            return extracted
        }

        if let local = localFileURL, local.isFileURL {
            let ext = local.pathExtension.lowercased()

            // 直出视频：只认已有列表/poster 缓存
            if Self.videoFileExtensions.contains(ext),
               let extracted = videoCache.cachedStaticThumbnailFileURLIfExists(forLocalFile: local) {
                return extracted
            }

            // 静图：SSD 列表小图
            if LocalImageThumbnailCache.isRasterImageFile(local),
               let cached = LocalImageThumbnailCache.shared.cachedThumbnailURLIfExists(forLocalFile: local) {
                return cached
            }

            // GIF 原文件只在没有静态封面时回退使用。
            if LocalImageThumbnailCache.isGIFFile(local) {
                if let staticFallback = Self.firstExistingStaticMetadataURL(
                    posterURL: posterURL,
                    thumbnailURL: thumbnailURL,
                    fileCache: fileCache
                ) {
                    return staticFallback
                }
                return local
            }

            // Workshop 目录：优先内部视频的已有抽帧，其次 preview 的 SSD 小图/原 preview
            // 注意：不在此处 fileExists 负缓存短路；缓存查找本身只打 SSD
            if fileCache.isDirectory(atPath: local.path)
                || ext.isEmpty
                || (!Self.videoFileExtensions.contains(ext) && !Self.libraryLocalRasterExtensions.contains(ext)) {
                if let resolved = Self.resolveLocalVideoFile(from: local),
                   let extracted = videoCache.cachedStaticThumbnailFileURLIfExists(forLocalFile: resolved) {
                    return extracted
                }
                if let preview = Self.resolveLocalWorkshopPreviewImage(from: local) {
                    if Self.urlLooksLikeGIF(preview),
                       let staticFallback = Self.firstExistingStaticMetadataURL(
                           posterURL: posterURL,
                           thumbnailURL: thumbnailURL,
                           fileCache: fileCache
                       ) {
                        return staticFallback
                    }
                    if Self.urlLooksLikeGIF(preview) {
                        return preview
                    }
                    if LocalImageThumbnailCache.isRasterImageFile(preview),
                       let cached = LocalImageThumbnailCache.shared.cachedThumbnailURLIfExists(forLocalFile: preview) {
                        return cached
                    }
                    // preview 本身往往偏小，仅在无抽帧时作占位
                    return preview
                }
            }
        }

        if let staticFallback = Self.firstExistingStaticMetadataURL(
            posterURL: posterURL,
            thumbnailURL: thumbnailURL,
            fileCache: fileCache
        ) {
            return staticFallback
        }
        if let poster = posterURL, poster.isFileURL, fileCache.fileExists(atPath: poster.path) {
            // 本地 poster 也可能是抽帧产物
            return poster
        }
        return coverImageURL
    }

    /// 为文件夹叠图预热：把「前 N 项」缺的列表抽帧/静图小图生成到 SSD（限流由调用方控制）。
    /// - Returns: 是否新生成了至少一个清晰源（用于决定是否刷新文件夹 display）
    @MainActor
    @discardableResult
    func ensureFolderPreviewCache(localFileURL: URL?) async -> Bool {
        var generated = false
        let videoCache = VideoThumbnailCache.shared

        if let record = MediaLibraryService.shared.downloadRecord(for: id),
           let bakedPath = record.sceneBakeArtifact?.videoPath,
           !bakedPath.isEmpty {
            let bakedURL = URL(fileURLWithPath: bakedPath)
            if videoCache.cachedListThumbnailFileURLIfExists(forLocalVideo: bakedURL) == nil {
                if await videoCache.listThumbnailJPEGFileURL(forLocalVideo: bakedURL) != nil {
                    generated = true
                }
            }
            return generated
        }

        guard let local = localFileURL, local.isFileURL else { return false }
        let ext = local.pathExtension.lowercased()

        if Self.videoFileExtensions.contains(ext) {
            if videoCache.cachedStaticThumbnailFileURLIfExists(forLocalFile: local) == nil {
                if await videoCache.listThumbnailJPEGFileURL(forLocalVideo: local) != nil {
                    generated = true
                }
            }
            return generated
        }

        if LocalImageThumbnailCache.isRasterImageFile(local) {
            if LocalImageThumbnailCache.shared.cachedThumbnailURLIfExists(forLocalFile: local) == nil {
                if await LocalImageThumbnailCache.shared.ensureThumbnail(forLocalFile: local) != nil {
                    generated = true
                }
            }
            return generated
        }

        if LocalImageThumbnailCache.isGIFFile(local) {
            return false
        }

        // Workshop 目录
        if let resolved = MediaItem.resolveLocalVideoFile(from: local),
           Self.videoFileExtensions.contains(resolved.pathExtension.lowercased()) {
            if videoCache.cachedStaticThumbnailFileURLIfExists(forLocalFile: resolved) == nil {
                if await videoCache.listThumbnailJPEGFileURL(forLocalVideo: resolved) != nil {
                    generated = true
                }
            }
            return generated
        }

        if let preview = MediaItem.resolveLocalWorkshopPreviewImage(from: local),
           LocalImageThumbnailCache.isRasterImageFile(preview),
           LocalImageThumbnailCache.shared.cachedThumbnailURLIfExists(forLocalFile: preview) == nil {
            if await LocalImageThumbnailCache.shared.ensureThumbnail(forLocalFile: preview) != nil {
                generated = true
            }
        }
        return generated
    }
}

