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
        /// 所有用户可见的壁纸切换默认启用首帧预热过渡；恢复/回滚路径可显式关闭。
        var animatedTransition: Bool = true
        /// 播完即换且未开 web/scene 定时：跳过无播放完成事件的类型
        var requirePlaybackEndSupport: Bool = false
        var muted: Bool = true
        /// 视频高清 poster 的非视频 fallback（站点/工程预览图）。
        /// 注意：这里只接受可直接当桌面/锁屏底图的图，不能塞列表 800×600 小图。
        var fallbackPosterURL: URL? = nil
        /// true 时若无**高清** poster 缓存，允许从视频抽高清帧（最大 3840×2160）。
        /// 抽帧始终在后台 Task 中执行，不阻塞起播热路径。
        /// 调度器也应 true：否则无预生成 poster 的视频会永远写不上系统静帧。
        /// **绝不**回退到 `generateThumbnail` 列表小图。
        var generatePosterFromVideoIfNeeded: Bool = true
        var sceneBakeItemID: String? = nil
        var bakedVideoPath: String? = nil
        /// Prevents re-entry after the global coordinator has acquired its
        /// serialized transaction slot.
        var isGlobalTransaction: Bool = false
        /// When true, all target screens share one AVQueuePlayer (global sync).
        var usesSharedVideoDecoder: Bool = false
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

        DesktopWallpaperSyncManager.shared.captureOriginalSystemWallpaperIfNeeded(for: screens)

        if WallpaperSchedulerService.shared.isGlobalDisplaySyncEnabled,
           !options.isGlobalTransaction {
            return try await GlobalWallpaperSyncCoordinator.shared.apply(
                localURL: localURL,
                options: options
            )
        }

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

        let isRealtime = UserDefaults.standard.object(forKey: "scene_realtime_rendering_enabled") as? Bool ?? true
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
            // Align with scene: realtime mode always prefers live WKWebView daemon.
            // Baked MP4 is only for offline / non-realtime desktop playback (and posters).
            // Previously bake always short-circuited here, so "Set wallpaper" never
            // applied the live web wallpaper once a bake product existed.
            if !isRealtime,
               let bakedURL = usableBakedVideoURL(options: options, contentRoot: contentRoot) {
                try await applyVideo(bakedURL, to: screens, options: options)
                return true
            }
            guard allowNonVideoInOnEnd else { return false }
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
        // 桌面/锁屏静态底图只认高清 poster（scene_bake_* / poster_wallpaper_*），
        // existingWallpaperPosterURL 已与列表 generateThumbnail（800×600）隔离。
        //
        // 性能关键：只同步读取已有高清缓存；缺失时先起播视频，再后台抽帧补静帧，
        // 避免 4K copyCGImage 阻塞「设为壁纸 / 调度切换」热路径（静态图很快、动态却很慢的主因）。
        // 只查真正的 HD poster（scene_bake / poster_wallpaper），不把 fallback 预览算作已缓存，
        // 否则有站点预览图时永远不会后台抽帧补系统静帧。
        let hdPosterURL = VideoThumbnailCache.shared.existingWallpaperPosterURL(
            forLocalVideo: videoURL,
            sceneBakeItemID: options.sceneBakeItemID,
            fallbackPosterURL: nil
        )
        // 没有 HD 缓存时先用调用方 fallback（站点/工程预览，不能是列表小图）；仍无则 nil，视频先起播
        let immediatePosterURL = hdPosterURL ?? options.fallbackPosterURL
        // 无 HD 缓存时后台补静帧（异步、不阻塞切换）。
        // 即使 immediate 用了 fallback，也尽量补一张真正的 HD poster 写回系统桌面/锁屏底图。
        // 调度器必须允许补帧，否则无预生成 poster 的视频会「偶尔设置不到静态帧」。
        let needsBackgroundPoster = (hdPosterURL == nil && options.generatePosterFromVideoIfNeeded)

        // Full current-screen-set applies use the nil-target path so window rebuild
        // and URL maps stay atomic across displays. Subsets still loop per screen.
        let coversAllScreens = !screens.isEmpty
            && screens.count == NSScreen.screens.count
            && Set(screens.map(\.wallpaperScreenIdentifier))
                == Set(NSScreen.screens.map(\.wallpaperScreenIdentifier))
        // 多屏播同一文件时默认共享一路 AVQueuePlayer，避免每屏各起 VTDecoderXPCService。
        // 仅「覆盖全部当前屏幕」或全局同步时走共享标志路径；子集多选仍按屏循环，
        // 由 VideoWallpaperManager 按 URL 机会式复用已有 player。
        let useShared = options.usesSharedVideoDecoder
            || ((options.isGlobalTransaction || WallpaperSchedulerService.shared.isGlobalDisplaySyncEnabled)
                && screens.count > 1)
            || (coversAllScreens && screens.count > 1)
        if useShared {
            try VideoWallpaperManager.shared.applyVideoWallpaper(
                from: videoURL,
                posterURL: immediatePosterURL,
                muted: options.muted,
                targetScreens: screens,
                animatedTransition: options.animatedTransition,
                usesSharedVideoDecoder: true
            )
        } else if coversAllScreens {
            try VideoWallpaperManager.shared.applyVideoWallpaper(
                from: videoURL,
                posterURL: immediatePosterURL,
                muted: options.muted,
                targetScreen: nil,
                animatedTransition: options.animatedTransition,
                usesSharedVideoDecoder: false
            )
        } else {
            try VideoWallpaperManager.shared.applyVideoWallpaper(
                from: videoURL,
                posterURL: immediatePosterURL,
                muted: options.muted,
                targetScreens: screens,
                animatedTransition: options.animatedTransition,
                usesSharedVideoDecoder: false
            )
        }

        // 仅系统壁纸同步开启时注册桌面 poster；动态层（视频窗）不受影响
        if let immediatePosterURL, VideoWallpaperManager.shared.isSystemWallpaperSyncEnabled {
            for screen in screens {
                DesktopWallpaperSyncManager.shared.registerWallpaperSet(immediatePosterURL, for: screen)
            }
        }

        // 后台补高清静帧：生成后回写各屏 poster，并更新系统桌面/锁屏静态底图
        if needsBackgroundPoster {
            let sceneBakeItemID = options.sceneBakeItemID
            let targetScreenIDs = Set(screens.map(\.wallpaperScreenIdentifier))
            let targetFingerprints = Set(screens.map(\.wallpaperScreenFingerprint))
            let expectedVideoURL = videoURL.standardizedFileURL
            Task(priority: .utility) { @MainActor in
                var posterURL: URL?
                if let itemID = sceneBakeItemID {
                    posterURL = await VideoThumbnailCache.shared.sceneBakePosterJPEGFileURL(
                        forLocalVideo: videoURL,
                        itemID: itemID
                    )
                }
                if posterURL == nil {
                    posterURL = await VideoThumbnailCache.shared.posterJPEGFileURL(forLocalVideo: videoURL)
                }
                guard let posterURL else { return }

                let vm = VideoWallpaperManager.shared
                for screen in NSScreen.screens {
                    let id = screen.wallpaperScreenIdentifier
                    let fp = screen.wallpaperScreenFingerprint
                    guard targetScreenIDs.contains(id) || targetFingerprints.contains(fp) else { continue }
                    // 用户已切到别的视频时不要回写旧 poster
                    vm.updatePosterURL(posterURL, for: screen, expectedVideoURL: expectedVideoURL)
                }
            }
        }
    }

    private static func applyStaticImage(_ imageURL: URL, to screens: [NSScreen]) async throws {
        let vm = WallpaperViewModel()
        if screens.count == 1, let only = screens.first {
            try await vm.setWallpaper(from: imageURL, option: .desktop, for: only)
            return
        }

        // Multi-display: apply sequentially but fail the whole transaction if
        // any screen fails so GlobalWallpaperSyncCoordinator can roll back.
        var appliedScreens: [NSScreen] = []
        do {
            for screen in screens {
                try await vm.setWallpaper(from: imageURL, option: .desktop, for: screen)
                appliedScreens.append(screen)
            }
        } catch {
            throw ApplyError.failed(
                "静态壁纸多屏应用在 \(appliedScreens.count)/\(screens.count) 屏后失败：\(error.localizedDescription)"
            )
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
        let isRealtime = UserDefaults.standard.object(forKey: "scene_realtime_rendering_enabled") as? Bool ?? true
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
           let art = SceneOfflineBakeService.usableArtifact(from: record) {
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
