import Foundation
import AVFoundation
import AppKit
import CryptoKit
import ImageIO
import Kingfisher

/// 串行化高成本的 AVFoundation 抽帧，并将同一输出文件的请求合并为一个任务。
/// 海报生成会解码高分辨率视频帧，允许多个任务同时运行会迅速耗尽 CPU 和内存。
private actor VideoPosterGenerationCoordinator {
    static let shared = VideoPosterGenerationCoordinator()

    private let maxConcurrentGenerations = 1
    private var activeGenerations = 0
    private var waitingGenerations: [CheckedContinuation<Void, Never>] = []
    private var tasks: [String: Task<URL?, Never>] = [:]

    func generate(
        key: String,
        operation: @escaping @Sendable () async -> URL?
    ) async -> URL? {
        if let task = tasks[key] {
            return await task.value
        }

        let task = Task.detached(priority: .utility) { [operation] () -> URL? in
            await self.acquireSlot()
            let result = await operation()
            await self.releaseSlot()
            return result
        }
        tasks[key] = task

        let result = await task.value
        tasks.removeValue(forKey: key)
        return result
    }

    private func acquireSlot() async {
        if activeGenerations < maxConcurrentGenerations {
            activeGenerations += 1
            return
        }
        await withCheckedContinuation { continuation in
            waitingGenerations.append(continuation)
        }
    }

    private func releaseSlot() {
        if let next = waitingGenerations.first {
            waitingGenerations.removeFirst()
            next.resume()
        } else {
            activeGenerations = max(0, activeGenerations - 1)
        }
    }
}

/// 列表小图抽帧限并发（外置卡上同时 N 路 AVAsset 会全卡死）。
private actor VideoListThumbnailGenerationCoordinator {
    static let shared = VideoListThumbnailGenerationCoordinator()

    private let maxConcurrentGenerations = 2
    private var activeGenerations = 0
    private var waitingGenerations: [CheckedContinuation<Void, Never>] = []
    private var tasks: [String: Task<URL?, Never>] = [:]

    func generate(
        key: String,
        operation: @escaping @Sendable () async -> URL?
    ) async -> URL? {
        if let task = tasks[key] {
            return await task.value
        }

        let task = Task.detached(priority: .utility) { [operation] () -> URL? in
            await self.acquireSlot()
            let result = await operation()
            await self.releaseSlot()
            return result
        }
        tasks[key] = task

        let result = await task.value
        tasks.removeValue(forKey: key)
        return result
    }

    private func acquireSlot() async {
        if activeGenerations < maxConcurrentGenerations {
            activeGenerations += 1
            return
        }
        await withCheckedContinuation { continuation in
            waitingGenerations.append(continuation)
        }
    }

    private func releaseSlot() {
        if let next = waitingGenerations.first {
            waitingGenerations.removeFirst()
            next.resume()
        } else {
            activeGenerations = max(0, activeGenerations - 1)
        }
    }
}

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
        if BackgroundRuntimeRole.isIsolatedTest, let root = ProcessInfo.processInfo.environment["WAIFUX_HELPER_TEST_ROOT"] {
            cacheDirectory = URL(fileURLWithPath: root).appendingPathComponent("VideoThumbnails", isDirectory: true)
        } else {
            cacheDirectory = caches[0].appendingPathComponent("WaifuX/VideoThumbnails", isDirectory: true)
        }
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        memoryCache.countLimit = 50
        memoryCache.totalCostLimit = 50 * 1024 * 1024 // 50MB
    }

    /// 清理内存缓存，用于内存压力响应
    func clearMemoryCache() {
        memoryCache.removeAllObjects()
    }
    
    /// 「我的库」等列表封面用的静帧查找。
    ///
    /// **仅服务 UI 列表展示**，不得用于桌面/锁屏静态底图。
    /// 优先级：列表小图（`generateThumbnail` 写入，完整画幅）→ 高清 poster（仅兜底）。
    ///
    /// 注意：高清 poster 会做 letterbox 去黑边，竖屏/带边视频会被裁窄；若列表优先用它，
    /// 再叠加 KF `Downsampling(512×512)` + `scaledToFill`，封面会像被放大裁切。
    /// 因此列表必须优先未裁切的 800×600 列表帧。
    func cachedStaticThumbnailFileURLIfExists(forLocalFile mediaURL: URL) -> URL? {
        guard mediaURL.isFileURL else { return nil }
        // 列表热路径：只查本机 SSD 上的抽帧缓存，不要 fileExists 外置原片

        let thumb = cacheURL(for: mediaURL)
        if isUsableCachedImage(at: thumb) { return thumb }

        // 无列表小图时才回退 poster（旧缓存/仅生成过高清帧的路径）
        let path = mediaURL.standardizedFileURL.path
        if let poster = usablePosterURL(forPathKey: path) { return poster }

        return nil
    }

    /// Scene 烘焙封面使用稳定的 item 级缓存文件，避免每次重新烘焙因为 MP4 文件名变化而堆出多张抽帧图。
    func cachedSceneBakePosterFileURLIfExists(itemID: String) -> URL? {
        let poster = sceneBakePosterCacheURL(itemID: itemID)
        if isUsableCachedImage(at: poster) { return poster }
        // 兼容：迁移前只在 Caches 里的旧封面
        let legacy = legacySceneBakePosterURL(itemID: itemID)
        if legacy != poster, isUsableCachedImage(at: legacy) { return legacy }
        return nil
    }

    /// 实时 Scene 在关闭自动烘焙时生成的按目标尺寸静帧。
    /// 与真正烘焙产物的 `scene_bake_*` 隔离，避免横屏主屏 poster 污染竖屏副屏。
    func cachedSceneRealtimePosterFileURLIfExists(
        itemID: String,
        variantKey: String
    ) -> URL? {
        let poster = sceneRealtimePosterCacheURL(itemID: itemID, variantKey: variantKey)
        if isUsableCachedImage(at: poster) { return poster }
        let legacy = legacySceneRealtimePosterURL(itemID: itemID, variantKey: variantKey)
        if legacy != poster, isUsableCachedImage(at: legacy) { return legacy }
        return nil
    }

    /// `scene_realtime_*` 目录快照索引：itemID.md5 → 修改时间最新的一张。
    ///
    /// 「我的库」构建列表时会为**每个**媒体条目调用一次
    /// `latestSceneRealtimePosterFileURLIfExists`；旧实现每次 `contentsOfDirectory`
    /// 全量枚举缓存目录（条目数 × 目录项数）。索引之后每个条目只剩一次字典查找。
    /// 失效由写入点显式触发，TTL 只作兜底（其他进程写入/清理）。
    private static var realtimePosterIndex: [String: URL] = [:]
    private static var realtimePosterIndexBuiltAt: Date = .distantPast
    private static let realtimePosterIndexTTL: TimeInterval = 10

    /// 自动烘焙关闭时实时渲染抽帧的 item 级最新静帧（`scene_realtime_<itemID>_*.jpg`）。
    /// 供详情页等没有 variantKey 上下文的调用方回退：不区分目标尺寸，取修改时间最新的一张。
    func latestSceneRealtimePosterFileURLIfExists(itemID: String) -> URL? {
        refreshRealtimePosterIndexIfNeeded()
        return Self.realtimePosterIndex[itemID.md5]
    }

    /// 重建目录快照；10 秒内直接命中。
    private func refreshRealtimePosterIndexIfNeeded() {
        let now = Date()
        guard now.timeIntervalSince(Self.realtimePosterIndexBuiltAt) > Self.realtimePosterIndexTTL else {
            return
        }
        Self.realtimePosterIndexBuiltAt = now

        // 库目录 Covers/ 与旧 Caches 目录都扫；同一条目取修改时间最新的一张。
        var directories = [cacheDirectory]
        if let covers = sceneCoversDirectory(), covers != cacheDirectory { directories.insert(covers, at: 0) }
        let files = directories.flatMap { dir in
            (try? fileManager.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []
        }

        let prefix = "scene_realtime_"
        var latestByItem: [String: (url: URL, date: Date)] = [:]
        for file in files {
            let name = file.lastPathComponent
            guard name.hasPrefix(prefix),
                  file.pathExtension.lowercased() == "jpg" else { continue }
            // 文件名形如 scene_realtime_<itemID.md5>_<variantKey.md5>.jpg
            let body = name.dropFirst(prefix.count)
            guard let separator = body.firstIndex(of: "_") else { continue }
            let itemKey = String(body[body.startIndex..<separator])
            guard !itemKey.isEmpty else { continue }

            guard isUsableCachedImage(at: file),
                  let date = (try? fileManager.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date else {
                continue
            }
            if let existing = latestByItem[itemKey], existing.date >= date { continue }
            latestByItem[itemKey] = (file, date)
        }
        Self.realtimePosterIndex = latestByItem.mapValues(\.url)
    }

    /// 实时封面写入/删除后必须调用，否则同一进程内列表会继续命中旧目录快照。
    private func invalidateRealtimePosterIndex() {
        Self.realtimePosterIndexBuiltAt = .distantPast
    }

    /// 仅返回已缓存的**高清**动态壁纸 poster，不触发 AVFoundation 抽帧。
    /// 调度器切换下一张时优先走这里，避免串行抽帧把切换卡住。
    ///
    /// **绝不返回** `generateThumbnail` 的列表小图（800×600）。
    func cachedPosterJPEGFileURLIfExists(forLocalVideo videoURL: URL) -> URL? {
        guard videoURL.isFileURL else { return nil }
        let pathKey = videoURL.standardizedFileURL.path
        guard fileManager.fileExists(atPath: pathKey) else { return nil }
        return usablePosterURL(forPathKey: pathKey)
    }

    /// 桌面/锁屏静态底图：只读**高清** poster 缓存，绝不触发抽帧，也**绝不回退列表缩略图**。
    ///
    /// 优先级：
    /// 1. scene 烘焙稳定封面 `scene_bake_<itemID>.jpg`（烘焙完成时写入，高清）
    /// 2. 下载/设壁纸生成的高清 poster `poster_wallpaper_<path>.jpg`（最大 3840×2160）
    /// 3. 调用方显式 fallback（必须是 file URL 且可用）
    ///
    /// **不用** `generateThumbnail` 的列表小图（800×600，仅供库列表/网格 UI）。
    /// **不用** Workshop 工程自带的 `preview.*`（商店缩略图，不适合桌面/锁屏）。
    ///
    /// 锁屏/桌面若需要强制生成高清帧，请走 `posterJPEGFileURL` / `sceneBakePosterJPEGFileURL`
    /// 或 `LocalWallpaperApplyService.Options.generatePosterFromVideoIfNeeded`。
    func existingWallpaperPosterURL(
        forLocalVideo videoURL: URL?,
        sceneBakeItemID: String? = nil,
        projectRoot: URL? = nil,
        fallbackPosterURL: URL? = nil
    ) -> URL? {
        _ = projectRoot // 兼容旧调用；不再从工程目录取 preview.*

        if let sceneBakeItemID,
           let scenePoster = cachedSceneBakePosterFileURLIfExists(itemID: sceneBakeItemID) {
            return scenePoster
        }

        if let videoURL,
           let poster = cachedPosterJPEGFileURLIfExists(forLocalVideo: videoURL) {
            return poster
        }

        if let fallbackPosterURL,
           fallbackPosterURL.isFileURL,
           isUsableCachedImage(at: fallbackPosterURL) {
            return fallbackPosterURL
        }

        return nil
    }

    /// 列表缩略图磁盘缓存（`generateThumbnail` 写入，最大 800×600），不触发生成。
    /// **仅供列表/网格 UI**，禁止作为桌面/锁屏静态底图。
    func cachedListThumbnailFileURLIfExists(forLocalVideo videoURL: URL) -> URL? {
        guard videoURL.isFileURL else { return nil }
        let thumb = cacheURL(for: videoURL)
        guard isUsableCachedImage(at: thumb) else { return nil }
        return thumb
    }

    private func isUsableCachedImage(at url: URL) -> Bool {
        guard fileManager.fileExists(atPath: url.path),
              let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let sz = attrs[.size] as? NSNumber,
              sz.intValue > 500 else {
            return false
        }
        return true
    }

    /// 获取**列表**视频缩略图 URL（最大 800×600）。
    /// - Important: 仅供库列表/网格 UI，**禁止**作为桌面/锁屏静态底图。
    ///   锁屏/桌面请用 `posterJPEGFileURL` / `existingWallpaperPosterURL`。
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
        
        // 异步生成列表缩略图（非高清 poster）
        Task {
            await generateThumbnail(for: videoURL)
        }
        
        // 返回视频 URL（Kingfisher 会处理生成）
        return videoURL
    }
    
    /// 从本地视频抽一帧为**高清** JPEG（最大 3840×2160），用作动态壁纸的**静态桌面/锁屏**底图
    /// （与 `VideoWallpaperManager.setPosterAsDesktopWallpaper` 配套）。
    ///
    /// - Important: 这是锁屏/桌面唯一允许的抽帧生成入口；与列表 `generateThumbnail`（800×600）完全隔离。
    /// - Note: 输出在 `VideoThumbnails` 目录，文件名 `poster_wallpaper_<path_md5>.jpg`；失败时返回 `nil`。
    /// - Performance: 缓存命中时立即返回，letterbox 去黑边在后台异步修正，不阻塞设壁纸。
    func posterJPEGFileURL(forLocalVideo videoURL: URL) async -> URL? {
        guard videoURL.isFileURL else { return nil }
        let pathKey = videoURL.standardizedFileURL.path
        guard fileManager.fileExists(atPath: pathKey) else { return nil }

        let outURL = posterCacheURL(forPathKey: pathKey)
        if let existing = usablePosterURL(forPathKey: pathKey) {
            // 关键：不要 await 全分辨率 letterbox 扫描；已有高清 poster 直接返回
            scheduleCropExistingPosterIfNeeded(existing)
            return existing
        }

        let fileURL = URL(fileURLWithPath: pathKey)
        return await generatePosterJPEGFile(from: fileURL, outputURL: outURL)
    }

    /// 为 Wallpaper Engine 烘焙 MP4 生成稳定封面。`forceRegenerate` 为 true 时覆盖同一个 item 的旧抽帧。
    func sceneBakePosterJPEGFileURL(
        forLocalVideo videoURL: URL,
        itemID: String,
        forceRegenerate: Bool = false
    ) async -> URL? {
        guard videoURL.isFileURL else { return nil }
        let pathKey = videoURL.standardizedFileURL.path
        guard fileManager.fileExists(atPath: pathKey) else { return nil }

        let outURL = sceneBakePosterCacheURL(itemID: itemID)
        if !forceRegenerate,
           let existing = cachedSceneBakePosterFileURLIfExists(itemID: itemID) {
            scheduleCropExistingPosterIfNeeded(existing)
            return existing
        }

        try? fileManager.removeItem(at: outURL)
        return await generatePosterJPEGFile(from: URL(fileURLWithPath: pathKey), outputURL: outURL)
    }

    /// 为实时 Scene 的临时 1 秒视频生成目标屏幕专用封面。
    /// `variantKey` 应包含内容版本与目标像素尺寸；不同横竖比例不会共享缓存。
    func sceneRealtimePosterJPEGFileURL(
        forLocalVideo videoURL: URL,
        itemID: String,
        variantKey: String,
        targetWidth: Int,
        targetHeight: Int,
        forceRegenerate: Bool = false
    ) async -> URL? {
        guard videoURL.isFileURL else { return nil }
        let pathKey = videoURL.standardizedFileURL.path
        guard fileManager.fileExists(atPath: pathKey) else { return nil }

        let outURL = sceneRealtimePosterCacheURL(itemID: itemID, variantKey: variantKey)
        if !forceRegenerate,
           let existing = cachedSceneRealtimePosterFileURLIfExists(
               itemID: itemID,
               variantKey: variantKey
           ) {
            scheduleCropExistingPosterIfNeeded(existing)
            return existing
        }

        try? fileManager.removeItem(at: outURL)
        invalidateRealtimePosterIndex()
        return await generatePosterJPEGFile(
            from: URL(fileURLWithPath: pathKey),
            outputURL: outURL,
            maximumSize: CGSize(
                width: max(1, targetWidth),
                height: max(1, targetHeight)
            )
        )
    }

    /// 将渲染器 `detect-static` 输出的单帧 PNG 写入实时 poster 缓存。
    ///
    /// 纯静态 scene 走"抽帧"路径时没有 1 秒 MP4 可供 AVAssetImageGenerator 抽帧，
    /// 渲染器直接产出整屏 PNG；这里按与临时抽帧一致的 `scene_realtime_` 键空间
    /// 落盘 JPEG，所有 UI/锁屏消费方无感。`variantKey` 语义与视频抽帧完全一致。
    func sceneRealtimePosterJPEGFileURL(
        forImageFile imageURL: URL,
        itemID: String,
        variantKey: String,
        targetWidth: Int,
        targetHeight: Int,
        forceRegenerate: Bool = false
    ) async -> URL? {
        guard imageURL.isFileURL else { return nil }
        let pathKey = imageURL.standardizedFileURL.path
        guard fileManager.fileExists(atPath: pathKey) else { return nil }

        let outURL = sceneRealtimePosterCacheURL(itemID: itemID, variantKey: variantKey)
        if !forceRegenerate,
           let existing = cachedSceneRealtimePosterFileURLIfExists(
               itemID: itemID,
               variantKey: variantKey
           ) {
            scheduleCropExistingPosterIfNeeded(existing)
            return existing
        }

        try? fileManager.removeItem(at: outURL)
        invalidateRealtimePosterIndex()
        return await generatePosterJPEGFile(
            fromImageFile: imageURL,
            outputURL: outURL,
            maximumSize: CGSize(
                width: max(1, targetWidth),
                height: max(1, targetHeight)
            )
        )
    }

    /// 将 Wallpaper Engine Web renderer 的直接截图写入稳定 poster 缓存。
    ///
    /// 截图源通常在 `/tmp`，不能直接作为详情页或锁屏长期引用；这里编码为与离线烘焙
    /// 共用的 item 级 JPEG poster，不创建任何 MP4。
    func wallpaperEnginePosterJPEGFileURL(
        forImageFile imageURL: URL,
        itemID: String,
        forceRegenerate: Bool = false
    ) async -> URL? {
        guard imageURL.isFileURL,
              fileManager.fileExists(atPath: imageURL.path) else {
            return nil
        }

        let outURL = sceneBakePosterCacheURL(itemID: itemID)
        if !forceRegenerate,
           let existing = cachedSceneBakePosterFileURLIfExists(itemID: itemID) {
            scheduleCropExistingPosterIfNeeded(existing)
            return existing
        }

        try? fileManager.removeItem(at: outURL)
        return await generatePosterJPEGFile(fromImageFile: imageURL, outputURL: outURL)
    }

    /// 删除 Scene 烘焙稳定封面，并顺手清掉旧的 path-based poster，避免历史重复缓存继续被列表命中。
    func removeSceneBakePoster(itemID: String, videoPath: String? = nil) {
        try? fileManager.removeItem(at: sceneBakePosterCacheURL(itemID: itemID))
        try? fileManager.removeItem(at: legacySceneBakePosterURL(itemID: itemID))
        let realtimePrefix = "scene_realtime_\(itemID.md5)_"
        var directories = [cacheDirectory]
        if let covers = sceneCoversDirectory(), covers != cacheDirectory { directories.append(covers) }
        for dir in directories {
            guard let files = try? fileManager.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for file in files
            where file.lastPathComponent.hasPrefix(realtimePrefix)
                && file.pathExtension.lowercased() == "jpg" {
                try? fileManager.removeItem(at: file)
            }
        }
        if let videoPath, !videoPath.isEmpty {
            let videoURL = URL(fileURLWithPath: videoPath)
            try? fileManager.removeItem(at: posterCacheURL(forPathKey: videoURL.standardizedFileURL.path))
            try? fileManager.removeItem(at: legacyPosterCacheURL(forPathKey: videoURL.standardizedFileURL.path))
            removeListThumbnail(forLocalVideo: videoURL)
        }
        invalidateRealtimePosterIndex()
    }

    /// 删除视频对应的列表小图磁盘缓存 + 内存缓存（重新烘焙后必须调用，否则 path 不变会继续命中旧帧）。
    func removeListThumbnail(forLocalVideo videoURL: URL) {
        guard videoURL.isFileURL else { return }
        let pathKey = Self.stablePathKey(for: videoURL)
        let listURL = cacheURL(forPathKey: pathKey)
        try? fileManager.removeItem(at: listURL)
        // 兼容旧 absoluteString / 无 list_ 前缀键
        try? fileManager.removeItem(at: cacheDirectory.appendingPathComponent("\(videoURL.absoluteString.md5).jpg"))
        try? fileManager.removeItem(at: cacheDirectory.appendingPathComponent("\(pathKey.md5).jpg"))
        try? fileManager.removeItem(
            at: cacheDirectory.appendingPathComponent("\(URL(fileURLWithPath: pathKey).absoluteString.md5).jpg")
        )
        memoryCache.removeObject(forKey: pathKey as NSString)
        memoryCache.removeObject(forKey: videoURL.absoluteString as NSString)
    }

    /// 强制从当前视频重新抽列表小图（完整画幅），覆盖旧 `list_*.jpg`。
    @discardableResult
    func regenerateListThumbnailJPEGFileURL(forLocalVideo videoURL: URL) async -> URL? {
        guard videoURL.isFileURL else { return nil }
        removeListThumbnail(forLocalVideo: videoURL)
        return await listThumbnailJPEGFileURL(forLocalVideo: videoURL)
    }

    /// 强制从当前视频重新抽高清 poster（桌面/锁屏/详情背景用，最大 3840×2160），覆盖旧 `poster_wallpaper_*.jpg`。
    /// 详情页「重新抽帧」入口使用；与列表小图相互独立。
    @discardableResult
    func regeneratePosterJPEGFileURL(forLocalVideo videoURL: URL) async -> URL? {
        guard videoURL.isFileURL else { return nil }
        let pathKey = videoURL.standardizedFileURL.path
        guard fileManager.fileExists(atPath: pathKey) else { return nil }
        let outURL = posterCacheURL(forPathKey: pathKey)
        try? fileManager.removeItem(at: outURL)
        memoryCache.removeObject(forKey: pathKey as NSString)
        memoryCache.removeObject(forKey: videoURL.absoluteString as NSString)
        return await generatePosterJPEGFile(
            from: URL(fileURLWithPath: pathKey),
            outputURL: outURL
        )
    }

    /// 动态壁纸的锁屏/静态桌面底图：对 mp4/mov/webm/m4v **强制**从片源抽高清帧。
    /// 失败或未识别扩展名时才回退站点封面等；**绝不**使用列表 `generateThumbnail` 小图。
    func lockScreenPosterURL(forLocalVideo localVideoURL: URL, fallbackPosterURL: URL?) async -> URL? {
        let ext = localVideoURL.pathExtension.lowercased()
        guard ["mp4", "mov", "webm", "m4v"].contains(ext) else { return fallbackPosterURL }
        // 先读高清 poster 缓存；没有就抽一帧生成，绝不碰列表小图
        if let existing = cachedPosterJPEGFileURLIfExists(forLocalVideo: localVideoURL) {
            return existing
        }
        return await posterJPEGFileURL(forLocalVideo: localVideoURL) ?? fallbackPosterURL
    }

    /// 普通视频高清帧（桌面/锁屏/详情背景）：写在库目录 `Covers/`，键见 `coverPathKey`。
    private func posterCacheURL(forPathKey pathKey: String) -> URL {
        sceneCoverWriteDirectory.appendingPathComponent("poster_wallpaper_\(coverPathKey(forVideoPathKey: pathKey).md5).jpg")
    }

    /// 迁移前 Caches 里的旧高清帧（绝对路径哈希）。
    private func legacyPosterCacheURL(forPathKey pathKey: String) -> URL {
        cacheDirectory.appendingPathComponent("poster_wallpaper_\(pathKey.md5).jpg")
    }

    /// 读高清帧：新位置优先；只剩旧 Caches 那份时立即返回它，并后台复制到新位置（不删源）。
    private func usablePosterURL(forPathKey pathKey: String) -> URL? {
        let poster = posterCacheURL(forPathKey: pathKey)
        if isUsableCachedImage(at: poster) { return poster }
        let legacy = legacyPosterCacheURL(forPathKey: pathKey)
        guard legacy != poster, isUsableCachedImage(at: legacy) else { return nil }
        Task.detached(priority: .utility) {
            let fm = FileManager.default
            guard !fm.fileExists(atPath: poster.path) else { return }
            try? fm.copyItem(at: legacy, to: poster)
        }
        return legacy
    }

    // MARK: 封面（真实壁纸数据，落库目录，不放 Caches）
    //
    // 动态壁纸的静态封面都在这里：`scene_bake_*`（烘焙封面）、`scene_realtime_*`（静态检测 / 临时抽帧）、
    // `poster_wallpaper_*`（普通视频的高清帧）。「我的库」卡片、详情页、锁屏/桌面底图都直接用它；
    // 放 Caches 会被系统/清理工具整目录清掉。现落在下载根目录 `Covers/`（与 Media/、SceneBakes/ 同级），
    // 切换存储目录时随库一起迁移。旧 Caches 里的文件只作兼容读取：scene 封面首次解析时整批复制过去，
    // 视频高清帧（文件名是绝对路径哈希，无法反推）在读到时逐张复制。都只复制不删。

    nonisolated static let sceneCoversFolderName = "Covers"
    private var sceneCoversDirectoryCache: (url: URL?, rootPath: String?, resolvedAt: Date) = (nil, nil, .distantPast)
    private var migratedLegacyCoversInto: Set<String> = []

    /// 库目录下的封面目录；库根不存在（外置盘未挂载）时返回 nil，调用方回退旧 Caches 位置，
    /// 避免在 /Volumes 下凭空建出同名目录。解析结果缓存 5s（书签解析不便宜，列表会逐条调用）。
    func sceneCoversDirectory() -> URL? {
        if BackgroundRuntimeRole.isIsolatedTest { return nil }
        let now = Date()
        if now.timeIntervalSince(sceneCoversDirectoryCache.resolvedAt) < 5 {
            return sceneCoversDirectoryCache.url
        }
        let root = DownloadPathManager.shared.rootFolderURL
        var url: URL?
        if fileManager.fileExists(atPath: root.path) {
            let dir = root.appendingPathComponent(Self.sceneCoversFolderName, isDirectory: true)
            if !fileManager.fileExists(atPath: dir.path) {
                try? fileManager.createDirectory(at: dir, withIntermediateDirectories: false)
            }
            url = fileManager.fileExists(atPath: dir.path) ? dir : nil
        }
        sceneCoversDirectoryCache = (url, url == nil ? nil : root.standardizedFileURL.path, now)
        if let url { migrateLegacyCoversIfNeeded(into: url) }
        return url
    }

    /// 视频高清帧的文件名键：库内视频用「相对库根的路径」，换存储目录后键不变，封面随库迁移无需重抽；
    /// 库外视频（用户导入的任意位置）仍用绝对路径。
    private func coverPathKey(forVideoPathKey pathKey: String) -> String {
        guard sceneCoversDirectory() != nil,
              let rootPath = sceneCoversDirectoryCache.rootPath else { return pathKey }
        let standardized = (pathKey as NSString).standardizingPath
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard standardized.hasPrefix(prefix) else { return pathKey }
        return "lib:" + String(standardized.dropFirst(prefix.count))
    }

    /// 一次性把旧 Caches 里的封面复制进库目录（目标已有同名文件则跳过；不删源）。
    private func migrateLegacyCoversIfNeeded(into covers: URL) {
        let key = covers.standardizedFileURL.path
        guard !migratedLegacyCoversInto.contains(key) else { return }
        migratedLegacyCoversInto.insert(key)
        let source = cacheDirectory
        Task.detached(priority: .utility) {
            let fm = FileManager.default
            let files = (try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            var copied = 0
            for file in files {
                let name = file.lastPathComponent
                guard name.hasPrefix("scene_bake_") || name.hasPrefix("scene_realtime_"),
                      file.pathExtension.lowercased() == "jpg" else { continue }
                let dest = covers.appendingPathComponent(name)
                guard !fm.fileExists(atPath: dest.path) else { continue }
                if (try? fm.copyItem(at: file, to: dest)) != nil { copied += 1 }
            }
            if copied > 0 {
                print("[VideoThumbnailCache] 旧 Caches 封面已复制进库目录: \(copied) 张 → \(covers.path)")
                await MainActor.run { VideoThumbnailCache.shared.invalidateRealtimePosterIndex() }
            }
        }
    }

    /// 封面写入/读取的首选目录：库目录可用时用库目录，否则回退旧 Caches。
    private var sceneCoverWriteDirectory: URL { sceneCoversDirectory() ?? cacheDirectory }

    private func sceneBakePosterCacheURL(itemID: String) -> URL {
        sceneCoverWriteDirectory.appendingPathComponent("scene_bake_\(itemID.md5).jpg")
    }

    private func sceneRealtimePosterCacheURL(itemID: String, variantKey: String) -> URL {
        sceneCoverWriteDirectory.appendingPathComponent(
            "scene_realtime_\(itemID.md5)_\(variantKey.md5).jpg"
        )
    }

    private func legacySceneBakePosterURL(itemID: String) -> URL {
        cacheDirectory.appendingPathComponent("scene_bake_\(itemID.md5).jpg")
    }

    private func legacySceneRealtimePosterURL(itemID: String, variantKey: String) -> URL {
        cacheDirectory.appendingPathComponent("scene_realtime_\(itemID.md5)_\(variantKey.md5).jpg")
    }

    /// 是否为本 App 生成的静态图（列表小图 / 封面），用于 UI 跳过 GIF 探测。
    nonisolated static func isGeneratedStaticImagePath(_ path: String) -> Bool {
        path.contains("/WaifuX/VideoThumbnails/")
            || path.contains("/WaifuX/LocalImageThumbnails/")
            || path.contains("/WaifuX/\(sceneCoversFolderName)/")
    }

    // MARK: Scene 精确过渡图（scene_transition_*，独立于 scene_realtime_* 索引与后处理）

    private func sceneTransitionPosterURL(identity: String) -> URL {
        cacheDirectory.appendingPathComponent("scene_transition_\(identity.prefix(40)).jpg")
    }

    private func sceneTransitionMetadataURL(identity: String) -> URL {
        cacheDirectory.appendingPathComponent("scene_transition_\(identity.prefix(40)).meta.json")
    }

    /// 只在图片可用且 sidecar 元数据与期望**逐字段一致**时返回；旧缓存没有元数据一律不算命中。
    func cachedSceneTransitionPoster(expected: SceneTransitionPosterMetadata) -> URL? {
        let imageURL = sceneTransitionPosterURL(identity: expected.identity)
        guard isUsableCachedImage(at: imageURL),
              let data = try? Data(contentsOf: sceneTransitionMetadataURL(identity: expected.identity)),
              let stored = try? JSONDecoder().decode(SceneTransitionPosterMetadata.self, from: data) else {
            return nil
        }
        let matches = stored.schemaVersion == expected.schemaVersion
            && stored.identity == expected.identity
            && stored.contentDigest == expected.contentDigest
            && stored.propertiesDigest == expected.propertiesDigest
            && stored.pixelWidth == expected.pixelWidth
            && stored.pixelHeight == expected.pixelHeight
            && abs(stored.backingScale - expected.backingScale) < 0.001
            && stored.cropSignature == expected.cropSignature
        return matches ? imageURL : nil
    }

    /// 从临时 1 秒视频抽出精确过渡图，并写 sidecar 元数据（先图后元数据，元数据写成功才算缓存）。
    func storeSceneTransitionPoster(
        forLocalVideo videoURL: URL,
        metadata: SceneTransitionPosterMetadata
    ) async -> URL? {
        guard videoURL.isFileURL, fileManager.fileExists(atPath: videoURL.path) else { return nil }
        let imageURL = sceneTransitionPosterURL(identity: metadata.identity)
        let metaURL = sceneTransitionMetadataURL(identity: metadata.identity)
        try? fileManager.removeItem(at: metaURL)
        try? fileManager.removeItem(at: imageURL)
        guard let written = await generatePosterJPEGFile(
            from: videoURL,
            outputURL: imageURL,
            maximumSize: CGSize(width: max(1, metadata.pixelWidth), height: max(1, metadata.pixelHeight))
        ), isUsableCachedImage(at: written) else {
            return nil
        }
        do {
            let data = try JSONEncoder().encode(metadata)
            Self.ensureParentDirectory(of: metaURL)
            try data.write(to: metaURL, options: .atomic)
        } catch {
            try? fileManager.removeItem(at: written)
            return nil
        }
        return written
    }

    /// 复用已有静态抽帧（`scene_realtime_*` / `scene_bake_*`）作为过渡图：复制成独立文件 + 写元数据。
    /// 复制而不是直接引用，是因为原抽帧随时可能被重新抽帧 / 删除记录清掉，过渡期间文件必须稳定。
    func adoptSceneTransitionPoster(
        fromExistingPoster sourceURL: URL,
        metadata: SceneTransitionPosterMetadata
    ) -> URL? {
        guard isUsableCachedImage(at: sourceURL) else { return nil }
        let imageURL = sceneTransitionPosterURL(identity: metadata.identity)
        let metaURL = sceneTransitionMetadataURL(identity: metadata.identity)
        try? fileManager.removeItem(at: metaURL)
        try? fileManager.removeItem(at: imageURL)
        Self.ensureParentDirectory(of: imageURL)
        do {
            try fileManager.copyItem(at: sourceURL, to: imageURL)
            let data = try JSONEncoder().encode(metadata)
            try data.write(to: metaURL, options: .atomic)
        } catch {
            print("[SceneHandoff] 复用静态抽帧失败: \(error.localizedDescription)")
            try? fileManager.removeItem(at: imageURL)
            try? fileManager.removeItem(at: metaURL)
            return nil
        }
        return isUsableCachedImage(at: imageURL) ? imageURL : nil
    }

    /// 像素尺寸（不解码整图）；用于判断已有抽帧与目标屏比例是否一致。
    func imagePixelSize(at url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0 else { return nil }
        return CGSize(width: w, height: h)
    }

    /// 缓存目录可能在运行期被外部清理（清理工具 / 手动删 Caches）；init 只建一次不够，
    /// 每次写入前补建父目录，否则 `.atomic` 写入全部失败、表现为「抽帧失败」。
    nonisolated static func ensureParentDirectory(of fileURL: URL) {
        let dir = fileURL.deletingLastPathComponent()
        guard !FileManager.default.fileExists(atPath: dir.path) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func generatePosterJPEGFile(
        from videoURL: URL,
        outputURL: URL,
        maximumSize: CGSize = CGSize(width: 3840, height: 2160)
    ) async -> URL? {
        await VideoPosterGenerationCoordinator.shared.generate(key: outputURL.path) {
            await Task.detached(priority: .userInitiated) {
                let startedAt = CFAbsoluteTimeGetCurrent()
                let asset = AVURLAsset(url: videoURL)
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                // 允许就近关键帧，显著快于精确 seek（尤其长 GOP / 4K）
                generator.requestedTimeToleranceBefore = CMTime(seconds: 0.35, preferredTimescale: 600)
                generator.requestedTimeToleranceAfter = CMTime(seconds: 0.35, preferredTimescale: 600)
                generator.maximumSize = maximumSize

                // 少候选 + 优先靠近片头的可读帧，避免 4K 中间帧随机 seek 过慢。
                // 中间帧只作为首轮失败后的备选，不再默认先抽 50%。
                var candidates: [Double] = [1.0, 0.5, 2.0]
                if let duration = try? await asset.load(.duration) {
                    let d = CMTimeGetSeconds(duration)
                    if d.isFinite, d > 0 {
                        let mid = d * 0.5
                        let early = min(max(d * 0.15, 0.3), 2.0)
                        candidates = [early, min(1.0, max(d * 0.05, 0.2)), mid]
                            .filter { $0 >= 0 && $0 < d }
                        var seen = Set<Double>()
                        candidates = candidates.compactMap {
                            let rounded = (($0 * 10).rounded() / 10)
                            guard !seen.contains(rounded) else { return nil }
                            seen.insert(rounded)
                            return $0
                        }
                    }
                }
                if candidates.isEmpty {
                    candidates = [0.0]
                }

                for seconds in candidates {
                    let t = CMTime(seconds: seconds, preferredTimescale: 600)
                    do {
                        let cgImage = try generator.copyCGImage(at: t, actualTime: nil)
                        // 生成阶段先不做全分辨率 letterbox 扫描（4K 全图像素扫描极慢），
                        // 直接编码 JPEG；后续由 scheduleCropExistingPosterIfNeeded 后台修正。
                        guard let jpeg = Self.encodeJPEG(cgImage, quality: 0.88) else {
                            continue
                        }
                        Self.ensureParentDirectory(of: outputURL)
                        try jpeg.write(to: outputURL, options: .atomic)
                        let elapsed = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
                        print("[VideoThumbnailCache] Poster frame at \(String(format: "%.1f", seconds))s in \(String(format: "%.0f", elapsed))ms → \(outputURL.lastPathComponent)")
                        // 后台异步去黑边，不阻塞返回
                        Task.detached(priority: .utility) {
                            await Self.cropExistingPosterIfNeeded(outputURL)
                        }
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
    }

    private func generatePosterJPEGFile(
        fromImageFile imageURL: URL,
        outputURL: URL,
        maximumSize: CGSize = CGSize(width: 3840, height: 2160)
    ) async -> URL? {
        await VideoPosterGenerationCoordinator.shared.generate(key: outputURL.path) {
            await Task.detached(priority: .userInitiated) {
                let startedAt = CFAbsoluteTimeGetCurrent()
                guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil) else {
                    print("[VideoThumbnailCache] Failed to open Web capture: \(imageURL.lastPathComponent)")
                    return nil
                }

                let maxPixel = max(maximumSize.width, maximumSize.height)
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                    kCGImageSourceShouldCacheImmediately: false
                ]
                guard let image = CGImageSourceCreateThumbnailAtIndex(
                    source,
                    0,
                    options as CFDictionary
                ), let jpeg = Self.encodeJPEG(image, quality: 0.90) else {
                    print("[VideoThumbnailCache] Failed to encode Web capture: \(imageURL.lastPathComponent)")
                    return nil
                }

                do {
                    Self.ensureParentDirectory(of: outputURL)
                    try jpeg.write(to: outputURL, options: .atomic)
                    let elapsed = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
                    print("[VideoThumbnailCache] Web capture poster in \(String(format: "%.0f", elapsed))ms → \(outputURL.lastPathComponent)")
                    Task.detached(priority: .utility) {
                        await Self.cropExistingPosterIfNeeded(outputURL)
                    }
                    return outputURL
                } catch {
                    print("[VideoThumbnailCache] Failed to write Web capture poster: \(error)")
                    return nil
                }
            }.value
        }
    }

    /// 后台异步 letterbox 修正；调用方不得 await，避免阻塞设壁纸热路径。
    private func scheduleCropExistingPosterIfNeeded(_ url: URL) {
        Task.detached(priority: .utility) {
            await Self.cropExistingPosterIfNeeded(url)
        }
    }

    /// 用 ImageIO 直接编码 JPEG，避免 NSImage → TIFF → NSBitmapImageRep 的双份全分辨率拷贝。
    ///
    /// 编码前统一转 sRGB：AVAssetImageGenerator 输出的 CGImage 保留视频本源色域
    /// （实测 ICC=HDTV/Rec.709），写桌面后 WindowServer 按该 ICC 做色彩管理，
    /// 与 AVPlayerLayer 的合成链路不一致，表现为静态帧与视频“色域不同”。
    /// 桌面图统一 sRGB ICC 后，颜色走的转换与系统其它图像一致，手感对齐。
    nonisolated private static func encodeJPEG(_ image: CGImage, quality: CGFloat) -> Data? {
        let normalized = sRGBImage(image)
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData,
            "public.jpeg" as CFString,
            1,
            nil
        ) else {
            return nil
        }
        let props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(dest, normalized, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// 非 sRGB 色彩的图（视频本源 Rec.709/Display P3/HDR 映射结果）重绘到 sRGB 位图。
    /// 已是 sRGB 的图原样返回，不付出重绘成本。
    nonisolated private static func sRGBImage(_ image: CGImage) -> CGImage {
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else { return image }
        if let name = image.colorSpace?.name, name == sRGB.name {
            return image
        }
        guard let ctx = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: sRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return image }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage() ?? image
    }

    nonisolated private static func cropExistingPosterIfNeeded(_ url: URL) async {
        await Task.detached(priority: .utility) {
            guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil),
                  let cropped = croppedImageLetterbox(cgImage),
                  cropped.width != cgImage.width || cropped.height != cgImage.height else {
                return
            }
            guard let jpeg = encodeJPEG(cropped, quality: 0.88) else { return }
            do {
                try jpeg.write(to: url, options: .atomic)
                print("[VideoThumbnailCache] Cropped existing poster letterbox: \(url.lastPathComponent)")
            } catch {
                print("[VideoThumbnailCache] Failed to rewrite cropped poster: \(error)")
            }
        }.value
    }

    nonisolated private static func croppingImageLetterboxIfNeeded(_ image: CGImage) -> CGImage {
        croppedImageLetterbox(image) ?? image
    }

    nonisolated private static func croppedImageLetterbox(_ image: CGImage) -> CGImage? {
        guard let crop = detectBlackBorderCropRect(in: image) else { return nil }
        return image.cropping(to: crop)
    }

    nonisolated private static func detectBlackBorderCropRect(in image: CGImage) -> CGRect? {
        let width = image.width
        let height = image.height
        guard width > 16, height > 16 else { return nil }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        let didDraw = pixels.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress,
                  let ctx = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard didDraw else { return nil }

        let blackLumaThreshold: UInt8 = 28
        let edgeBlackRatioThreshold = 0.94
        let maxRemovedArea = 0.36
        let minRemovedArea = 0.001
        let minPairInsetRatio = 0.001
        let overscanPixels = 2

        func isBlackPixel(at index: Int) -> Bool {
            guard index + 2 < pixels.count else { return false }
            let r = pixels[index]
            let g = pixels[index + 1]
            let b = pixels[index + 2]
            let luma = (UInt16(r) * 54 + UInt16(g) * 183 + UInt16(b) * 19) >> 8
            return luma <= blackLumaThreshold
        }

        func blackRatioInRow(_ y: Int) -> Double {
            let step = max(1, width / 720)
            var black = 0
            var total = 0
            let row = y * bytesPerRow
            var x = 0
            while x < width {
                if isBlackPixel(at: row + x * 4) { black += 1 }
                total += 1
                x += step
            }
            return total > 0 ? Double(black) / Double(total) : 0
        }

        func blackRatioInColumn(_ x: Int) -> Double {
            let step = max(1, height / 720)
            var black = 0
            var total = 0
            var y = 0
            while y < height {
                if isBlackPixel(at: y * bytesPerRow + x * 4) { black += 1 }
                total += 1
                y += step
            }
            return total > 0 ? Double(black) / Double(total) : 0
        }

        func edgeInset(limit: Int, ratioAt: (Int) -> Double) -> Int {
            var inset = 0
            for i in 0..<limit {
                if ratioAt(i) >= edgeBlackRatioThreshold {
                    inset += 1
                } else {
                    break
                }
            }
            return inset
        }

        let top = edgeInset(limit: height / 2) { blackRatioInRow($0) }
        let bottom = edgeInset(limit: height / 2) { blackRatioInRow(height - 1 - $0) }
        let left = edgeInset(limit: width / 2) { blackRatioInColumn($0) }
        let right = edgeInset(limit: width / 2) { blackRatioInColumn(width - 1 - $0) }

        let horizontalPair = Double(top + bottom) / Double(height) >= minPairInsetRatio
            && top > 0 && bottom > 0
        let verticalPair = Double(left + right) / Double(width) >= minPairInsetRatio
            && left > 0 && right > 0
        guard horizontalPair || verticalPair else { return nil }

        let rawCropTop = horizontalPair ? top : 0
        let rawCropBottom = horizontalPair ? bottom : 0
        let rawCropLeft = verticalPair ? left : 0
        let rawCropRight = verticalPair ? right : 0
        let rawCropW = max(1, width - rawCropLeft - rawCropRight)
        let rawCropH = max(1, height - rawCropTop - rawCropBottom)
        let removedArea = 1.0 - (Double(rawCropW * rawCropH) / Double(width * height))
        guard removedArea >= minRemovedArea, removedArea <= maxRemovedArea else { return nil }

        let cropTop = horizontalPair ? min(height - 1, rawCropTop + overscanPixels) : 0
        let cropBottom = horizontalPair ? min(height - cropTop - 1, rawCropBottom + overscanPixels) : 0
        let cropLeft = verticalPair ? min(width - 1, rawCropLeft + overscanPixels) : 0
        let cropRight = verticalPair ? min(width - cropLeft - 1, rawCropRight + overscanPixels) : 0
        let cropW = max(1, width - cropLeft - cropRight)
        let cropH = max(1, height - cropTop - cropBottom)

        return CGRect(x: cropLeft, y: cropTop, width: cropW, height: cropH)
    }

    /// 获取**列表**缩略图图片（最大 800×600）。
    /// - Important: 仅供 UI 列表，禁止用于锁屏/桌面。
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
    
    /// 生成并缓存**列表**缩略图（最长边约 960，保持原始宽高比，**不做 letterbox 裁切**）。
    /// - Important: 仅供库列表/网格 UI。桌面/锁屏必须走 `generatePosterJPEGFile`（3840×2160）。
    @discardableResult
    private func generateThumbnail(for videoURL: URL) async -> NSImage? {
        // 统一用标准化 path 作为缓存键与读盘路径，避免 fileURL absoluteString 编码差异导致
        // 「生成写了 A.jpg、查找读 B.jpg」——外置卡上路径形态不一时表现为部分封面永远空白。
        let pathKey = Self.stablePathKey(for: videoURL)
        let sourceURL = URL(fileURLWithPath: pathKey)
        let outputURL = cacheURL(forPathKey: pathKey)
        let memoryKey = pathKey as NSString

        if let cached = memoryCache.object(forKey: memoryKey) {
            return cached
        }
        if isUsableCachedImage(at: outputURL),
           let data = try? Data(contentsOf: outputURL),
           let image = NSImage(data: data) {
            memoryCache.setObject(image, forKey: memoryKey)
            return image
        }

        let generated = await VideoListThumbnailGenerationCoordinator.shared.generate(key: pathKey) {
            await Self.extractListThumbnailJPEG(
                sourceURL: sourceURL,
                outputURL: outputURL
            )
        }
        guard generated != nil,
              let data = try? Data(contentsOf: outputURL),
              let image = NSImage(data: data) else {
            return nil
        }
        let cost = Int((image.size.width * image.size.height * 4).rounded())
        memoryCache.setObject(image, forKey: memoryKey, cost: max(cost, 1))
        return image
    }

    /// 后台抽列表帧并写入 `outputURL`；成功返回 outputURL。
    nonisolated private static func extractListThumbnailJPEG(
        sourceURL: URL,
        outputURL: URL
    ) async -> URL? {
        await Task.detached(priority: .utility) {
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                print("[VideoThumbnailCache] List thumb source missing: \(sourceURL.lastPathComponent)")
                return nil
            }

            let asset = AVURLAsset(url: sourceURL)
            let imageGenerator = AVAssetImageGenerator(asset: asset)
            imageGenerator.appliesPreferredTrackTransform = true
            // 列表专用上限：正方形 bounding box，按比例缩小，竖/横画幅都够用
            imageGenerator.maximumSize = CGSize(width: 960, height: 960)
            imageGenerator.requestedTimeToleranceBefore = CMTime(seconds: 0.35, preferredTimescale: 600)
            imageGenerator.requestedTimeToleranceAfter = CMTime(seconds: 0.35, preferredTimescale: 600)

            // 多候选：短视频 / 片头黑帧 / 外置卡 seek 失败
            var candidates: [Double] = [0.5, 1.0, 0.2, 0.0, 2.0]
            if let duration = try? await asset.load(.duration) {
                let d = CMTimeGetSeconds(duration)
                if d.isFinite, d > 0 {
                    candidates = [
                        min(max(d * 0.1, 0.15), 1.5),
                        min(0.5, max(d * 0.05, 0.1)),
                        min(1.0, d * 0.25),
                        min(d * 0.5, d - 0.05),
                        0.0
                    ]
                    .filter { $0 >= 0 && $0 < d }
                    var seen = Set<String>()
                    candidates = candidates.filter {
                        let k = String(format: "%.2f", $0)
                        return seen.insert(k).inserted
                    }
                    if candidates.isEmpty { candidates = [0.0] }
                }
            }

            for seconds in candidates {
                let t = CMTime(seconds: seconds, preferredTimescale: 600)
                do {
                    let cgImage = try imageGenerator.copyCGImage(at: t, actualTime: nil)
                    guard let jpeg = encodeJPEG(cgImage, quality: 0.82) else { continue }
                    try jpeg.write(to: outputURL, options: .atomic)
                    print("[VideoThumbnailCache] List thumb @\(String(format: "%.1f", seconds))s \(cgImage.width)x\(cgImage.height) → \(outputURL.lastPathComponent)")
                    return outputURL
                } catch {
                    print("[VideoThumbnailCache] List thumb try @\(seconds)s failed: \(error)")
                    continue
                }
            }
            print("[VideoThumbnailCache] Failed to generate list thumbnail for \(sourceURL.lastPathComponent)")
            return nil
        }.value
    }

    /// 为列表 UI 生成/返回 列表小图 URL（完整画幅，无 letterbox 裁切）。
    /// 与 `posterJPEGFileURL`（高清+去黑边，桌面/锁屏用）隔离。
    func listThumbnailJPEGFileURL(forLocalVideo videoURL: URL) async -> URL? {
        guard videoURL.isFileURL else { return nil }
        let pathKey = Self.stablePathKey(for: videoURL)
        let thumb = cacheURL(forPathKey: pathKey)
        if isUsableCachedImage(at: thumb) {
            return thumb
        }
        // 也尝试旧 absoluteString 键（迁移前写入的缓存），命中则复制到新键
        if migrateLegacyListThumbIfNeeded(for: videoURL, pathKey: pathKey) {
            return thumb
        }
        _ = await generateThumbnail(for: URL(fileURLWithPath: pathKey))
        return isUsableCachedImage(at: thumb) ? thumb : nil
    }

    /// 标准化路径键：去掉 file URL 编码差异，统一 `/private` 前缀形态。
    nonisolated private static func stablePathKey(for videoURL: URL) -> String {
        var path = videoURL.standardizedFileURL.path
        // fileURLWithPath 与 absoluteString 解析后的 path 可能一个带 /private
        if path.hasPrefix("/private/var/"), path.count > "/private".count {
            // 保留原样；NSString.standardizingPath 已处理大部分
            path = (path as NSString).standardizingPath
        } else {
            path = (path as NSString).standardizingPath
        }
        return path
    }

    /// 获取缓存 URL（基于稳定 path，而非 absoluteString）
    private func cacheURL(for videoURL: URL) -> URL {
        cacheURL(forPathKey: Self.stablePathKey(for: videoURL))
    }

    private func cacheURL(forPathKey pathKey: String) -> URL {
        cacheDirectory.appendingPathComponent("list_\(pathKey.md5).jpg")
    }

    /// 兼容旧版 `\(absoluteString.md5).jpg` 与未加 `list_` 前缀的 path 键。
    @discardableResult
    private func migrateLegacyListThumbIfNeeded(for videoURL: URL, pathKey: String) -> Bool {
        let dest = cacheURL(forPathKey: pathKey)
        guard !isUsableCachedImage(at: dest) else { return true }

        let legacyCandidates = [
            cacheDirectory.appendingPathComponent("\(videoURL.absoluteString.md5).jpg"),
            cacheDirectory.appendingPathComponent("\(pathKey.md5).jpg"),
            // 某些路径会多/少 trailing slash
            cacheDirectory.appendingPathComponent("\(URL(fileURLWithPath: pathKey).absoluteString.md5).jpg")
        ]
        for legacy in legacyCandidates {
            guard isUsableCachedImage(at: legacy) else { continue }
            do {
                try fileManager.copyItem(at: legacy, to: dest)
                print("[VideoThumbnailCache] Migrated legacy list thumb → \(dest.lastPathComponent)")
                return true
            } catch {
                // 已存在或拷贝失败：若 dest 可用仍算成功
                if isUsableCachedImage(at: dest) { return true }
            }
        }
        return false
    }
    
    /// 迁移缓存键：将旧路径对应的缓存文件重命名为新路径对应的缓存文件名。
    /// 遍历所有下载记录中的视频文件，计算旧/新 MD5 缓存键并执行重命名。
    func migrateCacheKeys(fromOldPrefix oldPrefix: String, toNewPrefix newPrefix: String) {
        Task.detached(priority: .utility) { [cacheDirectory = self.cacheDirectory] in
            let fileManager = FileManager.default
            var movedCount = 0

            func moveIfNeeded(from old: URL, to new: URL) {
                guard fileManager.fileExists(atPath: old.path),
                      !fileManager.fileExists(atPath: new.path) else { return }
                try? fileManager.moveItem(at: old, to: new)
                movedCount += 1
            }

            func migrateListThumbs(oldPath: String, newPath: String) {
                let oldKey = (oldPath as NSString).standardizingPath
                let newKey = (newPath as NSString).standardizingPath
                let oldURL = URL(fileURLWithPath: oldKey)
                let newURL = URL(fileURLWithPath: newKey)

                // 新键 list_<path.md5>
                let oldList = cacheDirectory.appendingPathComponent("list_\(oldKey.md5).jpg")
                let newList = cacheDirectory.appendingPathComponent("list_\(newKey.md5).jpg")
                moveIfNeeded(from: oldList, to: newList)

                // 旧 absoluteString 键 / 裸 path.md5 键 → 新 list_ 键
                for legacy in [
                    cacheDirectory.appendingPathComponent("\(oldURL.absoluteString.md5).jpg"),
                    cacheDirectory.appendingPathComponent("\(oldKey.md5).jpg")
                ] {
                    moveIfNeeded(from: legacy, to: newList)
                }

                let oldPoster = cacheDirectory.appendingPathComponent("poster_wallpaper_\(oldKey.md5).jpg")
                let newPoster = cacheDirectory.appendingPathComponent("poster_wallpaper_\(newKey.md5).jpg")
                moveIfNeeded(from: oldPoster, to: newPoster)
            }

            let mediaRecords = await MainActor.run { MediaLibraryService.shared.downloadRecords }
            let wallpaperRecords = await MainActor.run { WallpaperLibraryService.shared.downloadRecords }

            for record in mediaRecords {
                let path = record.localFilePath
                guard path.hasPrefix(newPrefix) else { continue }
                let oldPath = oldPrefix + String(path.dropFirst(newPrefix.count))
                migrateListThumbs(oldPath: oldPath, newPath: path)
            }

            for record in wallpaperRecords {
                let path = record.localFilePath
                guard path.hasPrefix(newPrefix) else { continue }
                let oldPath = oldPrefix + String(path.dropFirst(newPrefix.count))
                migrateListThumbs(oldPath: oldPath, newPath: path)
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
