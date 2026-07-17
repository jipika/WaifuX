import Foundation
import AppKit

/// 统一本地设壁纸入口（详情页「设为壁纸」与调度器共用同一实现）。
/// UI（多屏选择、进度、错误弹窗）留在调用方；本服务只做类型分发与底层设置。
@MainActor
enum LocalWallpaperApplyService {
    enum ApplyError: LocalizedError {
        case missingFile(String)
        case unsupported(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .missingFile(let path): return "壁纸文件不存在：\(path)"
            case .unsupported(let type): return "暂不支持该类型壁纸：\(type)"
            case .failed(let msg): return msg
            }
        }
    }

    struct Options {
        /// 调度切换淡入；手动默认 false
        var animatedTransition: Bool = false
        /// 播完即换且未开 web/scene 定时：跳过无播放完成事件的类型
        var requirePlaybackEndSupport: Bool = false
        var muted: Bool = true
        /// 视频 poster：已有缓存优先；手动可传入站点/工程预览图作 fallback
        var fallbackPosterURL: URL? = nil
        /// true 时若无缓存 poster，允许从视频抽一帧（仅手动；调度保持 false）
        var generatePosterFromVideoIfNeeded: Bool = false
        var sceneBakeItemID: String? = nil
        var bakedVideoPath: String? = nil
        var reason: String = "apply"
    }

    /// 对本地路径设壁纸。
    /// - Parameters:
    ///   - localURL: 本地文件或 Workshop 目录
    ///   - targetScreens: nil = 全部屏幕（与详情页单屏机默认行为一致）；非空则只设这些屏
    @discardableResult
    static func apply(
        localURL: URL,
        targetScreens: [NSScreen]?,
        options: Options = Options()
    ) async throws -> Bool {
        guard FileManager.default.fileExists(atPath: localURL.path) else {
            throw ApplyError.missingFile(localURL.path)
        }

        let screens: [NSScreen]
        if let targetScreens, !targetScreens.isEmpty {
            screens = targetScreens
        } else {
            screens = NSScreen.screens
        }
        guard !screens.isEmpty else { return false }

        let ext = localURL.pathExtension.lowercased()
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: localURL.path, isDirectory: &isDirectory)

        let videoExts: Set<String> = ["mp4", "mov", "webm", "m4v", "mkv", "avi", "flv"]
        let imageExts: Set<String> = ["jpg", "jpeg", "png", "bmp", "gif", "webp", "tga", "tif", "tiff"]

        // 1) 直接视频文件
        if !isDirectory.boolValue, videoExts.contains(ext) {
            try await applyVideo(localURL, to: screens, options: options)
            return true
        }

        // 2) 直接静态图
        if !isDirectory.boolValue, imageExts.contains(ext) {
            if options.requirePlaybackEndSupport { return false }
            try await applyStaticImage(localURL, to: screens)
            return true
        }

        // 3) Workshop 目录 / pkg
        let contentRoot = WorkshopService.resolveWallpaperEngineProjectRoot(startingAt: localURL)
        ensurePresetHTMLGenerated(at: contentRoot)

        let isRealtime = UserDefaults.standard.bool(forKey: "scene_realtime_rendering_enabled")
        let contentType = determineWorkshopContentType(at: contentRoot)
        let allowNonVideoInOnEnd = !options.requirePlaybackEndSupport || screens.contains { hasWebSceneTimer(for: $0) }

        switch contentType {
        case .video:
            if let videoURL = findVideoFile(in: contentRoot) {
                try await applyVideo(videoURL, to: screens, options: options)
                return true
            }
            guard allowNonVideoInOnEnd else { return false }
            // 无内嵌视频文件的 video 工程：退回 CLI/web 渲染，不按 scene 做 companion bake
            try await applyRenderer(path: contentRoot.path, to: screens, options: options, scheduleSceneCompanionBake: false)
            return true

        case .scene:
            if isRealtime {
                guard allowNonVideoInOnEnd else { return false }
                // 详情页实时 scene：只 setWallpaper；companion bake 仅在已有产物时推锁屏，无产物且关自动烘焙则不烘不推
                try await applyRenderer(path: contentRoot.path, to: screens, options: options, scheduleSceneCompanionBake: true)
                return true
            }
            // 非实时：优先烘焙 MP4（与详情页 applySceneWallpaperPreferringBake 一致）
            if let bakedURL = usableBakedVideoURL(options: options, contentRoot: contentRoot) {
                // 详情页：若有 .web 组合目录则走 web 渲染
                let webDirPath = bakedURL.path.replacingOccurrences(of: ".mp4", with: ".web")
                if FileManager.default.fileExists(atPath: webDirPath) {
                    guard allowNonVideoInOnEnd else { return false }
                    try await applyRenderer(path: webDirPath, to: screens, options: options, scheduleSceneCompanionBake: false)
                    return true
                }
                try await applyVideo(bakedURL, to: screens, options: options)
                return true
            }
            // 无烘焙：不在此阻塞长烘焙。
            // 调度器：退回实时渲染（能设上桌面）；详情页应先 bake UI 再调本方法。
            guard allowNonVideoInOnEnd else { return false }
            try await applyRenderer(path: contentRoot.path, to: screens, options: options, scheduleSceneCompanionBake: true)
            return true

        case .web:
            guard allowNonVideoInOnEnd else { return false }
            // web 永不走 scene companion bake
            try await applyRenderer(path: contentRoot.path, to: screens, options: options, scheduleSceneCompanionBake: false)
            return true

        case .image:
            guard !options.requirePlaybackEndSupport else { return false }
            if let imageURL = findImageFile(in: contentRoot) {
                try await applyStaticImage(imageURL, to: screens)
                return true
            }
            throw ApplyError.unsupported("image-directory")

        case .unsupported(let type):
            throw ApplyError.unsupported(type)

        case .unknown:
            if let videoURL = findVideoFile(in: contentRoot) {
                try await applyVideo(videoURL, to: screens, options: options)
                return true
            }
            if let bakedURL = usableBakedVideoURL(options: options, contentRoot: contentRoot) {
                try await applyVideo(bakedURL, to: screens, options: options)
                return true
            }
            guard allowNonVideoInOnEnd else { return false }
            if let imageURL = findImageFile(in: contentRoot) {
                try await applyStaticImage(imageURL, to: screens)
                return true
            }
            try await applyRenderer(path: contentRoot.path, to: screens, options: options, scheduleSceneCompanionBake: false)
            return true
        }
    }

    /// 调度器便捷封装：单屏 + animatedTransition。
    @discardableResult
    static func apply(
        localURL: URL,
        to screen: NSScreen,
        options: Options = Options()
    ) async throws -> Bool {
        try await apply(localURL: localURL, targetScreens: [screen], options: options)
    }

    // MARK: - Primitives

    private static func applyVideo(_ videoURL: URL, to screens: [NSScreen], options: Options) async throws {
        var posterURL = VideoThumbnailCache.shared.existingWallpaperPosterURL(
            forLocalVideo: videoURL,
            sceneBakeItemID: options.sceneBakeItemID,
            fallbackPosterURL: options.fallbackPosterURL
        )
        if posterURL == nil, options.generatePosterFromVideoIfNeeded {
            if let itemID = options.sceneBakeItemID {
                posterURL = await VideoThumbnailCache.shared.sceneBakePosterJPEGFileURL(
                    forLocalVideo: videoURL,
                    itemID: itemID
                )
            }
            if posterURL == nil {
                posterURL = await VideoThumbnailCache.shared.posterJPEGFileURL(forLocalVideo: videoURL)
            }
            posterURL = posterURL ?? options.fallbackPosterURL
        }

        try VideoWallpaperManager.shared.applyVideoWallpaper(
            from: videoURL,
            posterURL: posterURL,
            muted: options.muted,
            targetScreens: screens,
            animatedTransition: options.animatedTransition
        )
        // 仅系统壁纸同步开启时注册桌面 poster；动态层（视频窗）不受影响
        if let posterURL, VideoWallpaperManager.shared.isSystemWallpaperSyncEnabled {
            for screen in screens {
                DesktopWallpaperSyncManager.shared.registerWallpaperSet(posterURL, for: screen)
            }
        }
    }

    private static func applyStaticImage(_ imageURL: URL, to screens: [NSScreen]) async throws {
        let vm = WallpaperViewModel()
        if screens.count == 1, let only = screens.first {
            try await vm.setWallpaper(from: imageURL, option: .desktop, for: only)
        } else {
            // 多屏：逐屏设置（与详情页静态图逻辑一致，含同步开关 / 动态锁屏）
            for screen in screens {
                try await vm.setWallpaper(from: imageURL, option: .desktop, for: screen)
            }
        }
    }

    /// - Parameter scheduleSceneCompanionBake: 仅 scene 实时路径为 true。
    ///   web / preset / 非 scene 不得触发 scene 离线 companion bake。
    private static func applyRenderer(
        path: String,
        to screens: [NSScreen],
        options: Options,
        scheduleSceneCompanionBake: Bool
    ) async throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw ApplyError.missingFile(path)
        }
        if WallpaperEngineXBridge.resolvedCLIExecutableURL() == nil {
            throw ApplyError.failed("wallpaper-wgpu 渲染器未找到")
        }
        let isRealtime = UserDefaults.standard.bool(forKey: "scene_realtime_rendering_enabled")
        // user properties 仅 scene 实时有意义；web 传 nil
        let userProps = (scheduleSceneCompanionBake && isRealtime)
            ? SceneWallpaperPropertiesService.propertiesOverrideJSON(for: path)
            : nil
        try await WallpaperEngineXBridge.shared.setWallpaper(
            path: path,
            targetScreens: screens,
            userProperties: userProps
        )
        // companion bake：有产物才推锁屏；无产物且关自动烘焙则不烘不推（设壁纸本身不强制烘）
        if scheduleSceneCompanionBake {
            SceneOfflineBakeService.scheduleRealtimeCompanionBake(
                path: path,
                targetScreens: screens,
                reason: options.reason
            )
        }
    }

    private static func hasWebSceneTimer(for screen: NSScreen) -> Bool {
        let cfg = WallpaperSchedulerService.shared.config.resolvedDisplayConfig(
            for: screen.wallpaperScreenIdentifier
        )
        return cfg.isOnEndMode && cfg.webSceneSwitchSeconds != nil
    }

    private static func usableBakedVideoURL(options: Options, contentRoot: URL) -> URL? {
        if let bakedPath = options.bakedVideoPath {
            let url = URL(fileURLWithPath: bakedPath)
            if SceneOfflineBakeService.isUsableBakedVideo(at: url) { return url }
        }
        if let record = mediaRecord(for: contentRoot),
           let art = record.sceneBakeArtifact,
           art.analysisId == record.sceneBakeEligibility?.analysisId {
            let url = URL(fileURLWithPath: art.videoPath)
            if SceneOfflineBakeService.isUsableBakedVideo(at: url) { return url }
        }
        return nil
    }

    private static func mediaRecord(for contentRoot: URL) -> MediaDownloadRecord? {
        let library = MediaLibraryService.shared
        if let exact = library.downloadRecord(forLocalFilePath: contentRoot.path) {
            return exact
        }

        // 只做轻量 hasSameLocalContent；避免对整表逐条 resolveWallpaperEngineProjectRoot
        //（目录扫描 + 反复 URL.path）把设壁纸主线程再次拖慢。
        let contentPath = (contentRoot.path as NSString).standardizingPath
        return library.downloadedItems.first { record in
            let recordedPath = (record.localFilePath as NSString).standardizingPath
            if recordedPath == contentPath { return true }
            return record.hasSameLocalContent(as: contentRoot)
        }
    }

    // MARK: - Type detection（原 MediaDetailSheet.determineWorkshopContentType）

    private enum WorkshopContentType: Equatable {
        case video, scene, web, image
        case unsupported(String)
        case unknown
    }

    private static func determineWorkshopContentType(at contentDir: URL) -> WorkshopContentType {
        let projectURL = contentDir.appendingPathComponent("project.json")
        guard let data = try? Data(contentsOf: projectURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unknown
        }
        if let typeString = json["type"] as? String {
            switch typeString.lowercased() {
            case "video": return .video
            case "scene": return .scene
            case "web": return .web
            default: return .unsupported(typeString)
            }
        }
        return inferWorkshopContentType(from: json, contentDir: contentDir)
    }

    private static func inferWorkshopContentType(from json: [String: Any], contentDir: URL) -> WorkshopContentType {
        let fm = FileManager.default
        if let background = json["background"] as? String {
            let bgPath = contentDir.appendingPathComponent(background).path
            if fm.fileExists(atPath: bgPath) {
                let ext = (background as NSString).pathExtension.lowercased()
                if ["jpg", "jpeg", "png", "bmp", "gif", "webp", "tga", "tif", "tiff"].contains(ext) {
                    return .image
                }
                if ["mp4", "mov", "webm"].contains(ext) {
                    return .video
                }
            }
        }
        if json["dependency"] != nil && json["preset"] != nil { return .web }
        if fm.fileExists(atPath: contentDir.appendingPathComponent("scene.pkg").path)
            || fm.fileExists(atPath: contentDir.appendingPathComponent("scene.json").path) {
            return .scene
        }
        if let rootContents = try? fm.contentsOfDirectory(at: contentDir, includingPropertiesForKeys: nil),
           rootContents.contains(where: { ["mp4", "mov", "webm"].contains($0.pathExtension.lowercased()) }) {
            return .video
        }
        if json["dependency"] != nil { return .web }
        return .unknown
    }

    private static func findVideoFile(in directory: URL) -> URL? {
        let videoExts: Set<String> = ["mp4", "mov", "webm", "m4v"]
        let projectURL = directory.appendingPathComponent("project.json")
        if let data = try? Data(contentsOf: projectURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["file", "background"] {
                if let path = json[key] as? String {
                    let candidate = directory.appendingPathComponent(path)
                    if videoExts.contains(candidate.pathExtension.lowercased()),
                       FileManager.default.fileExists(atPath: candidate.path) {
                        return candidate
                    }
                }
            }
        }
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return nil
        }
        for case let fileURL as URL in enumerator {
            if videoExts.contains(fileURL.pathExtension.lowercased()) {
                return fileURL
            }
        }
        return nil
    }

    private static func findImageFile(in directory: URL) -> URL? {
        let imageExts: Set<String> = ["jpg", "jpeg", "png", "bmp", "gif", "webp"]
        let projectURL = directory.appendingPathComponent("project.json")
        if let data = try? Data(contentsOf: projectURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let background = json["background"] as? String {
            let candidate = directory.appendingPathComponent(background)
            if imageExts.contains(candidate.pathExtension.lowercased()),
               FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return nil
        }
        for case let fileURL as URL in enumerator {
            if imageExts.contains(fileURL.pathExtension.lowercased()) {
                return fileURL
            }
        }
        return nil
    }

    private static func ensurePresetHTMLGenerated(at contentRoot: URL) {
        let fm = FileManager.default
        let htmlURL = contentRoot.appendingPathComponent("index.html")
        guard !fm.fileExists(atPath: htmlURL.path) else { return }

        let projectJSONURL = contentRoot.appendingPathComponent("project.json")
        guard fm.fileExists(atPath: projectJSONURL.path),
              let data = try? Data(contentsOf: projectJSONURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["type"] == nil,
              let presetDict = json["preset"] as? [String: Any],
              let customDir = presetDict["customdirectory"] as? String else { return }

        let imagesDir = contentRoot.appendingPathComponent(customDir)
        let imageExts: Set<String> = ["jpg", "jpeg", "png", "bmp", "gif", "webp", "tga", "tif", "tiff"]
        guard let contents = try? fm.contentsOfDirectory(
            at: imagesDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return }
        let images = contents
            .filter { imageExts.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !images.isEmpty else { return }

        let multiplier = presetDict["imageswitchtimes"] as? Int ?? 1
        let switchTime = max(multiplier * 5, 3)
        let imagePaths = images.map { url -> String in
            let absPath = url.path
            let dirPath = contentRoot.path.hasSuffix("/") ? contentRoot.path : contentRoot.path + "/"
            if absPath.hasPrefix(dirPath) { return String(absPath.dropFirst(dirPath.count)) }
            return url.lastPathComponent
        }
        let imagesJS = "[\(imagePaths.map { "\"\($0.replacingOccurrences(of: "\"", with: "\\\""))\"" }.joined(separator: ","))]"
        let html = """
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <style>
        html,body{margin:0;padding:0;width:100%;height:100%;overflow:hidden;background:#000}
        .slide{position:absolute;inset:0;background-size:cover;background-position:center;opacity:0;transition:opacity 1.2s ease-in-out}
        .slide.active{opacity:1}
        </style></head><body><div id="root"></div>
        <script>
        const images=\(imagesJS); const switchTime=\(switchTime)*1000; let current=0;
        const root=document.getElementById('root');
        const slides=images.map((src,i)=>{const el=document.createElement('div');el.className='slide'+(i===0?' active':'');el.style.backgroundImage='url('+src+')';root.appendChild(el);return el;});
        setInterval(()=>{slides[current].classList.remove('active');current=(current+1)%slides.length;slides[current].classList.add('active');},switchTime);
        </script></body></html>
        """
        try? html.write(to: htmlURL, atomically: true, encoding: .utf8)
    }
}
