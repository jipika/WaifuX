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

    /// 「可作为壁纸应用的静态图」分类集（`apply` 的直接文件判定与工程 background
    /// 类型推断共用）。含 heic/heif/avif：库里 `MediaItem+LocalFiles.swift` 已把它们
    /// 认作图片，应用侧却漏了 → `.heic` 直接文件掉进 `case .unknown`，被当成 Workshop
    /// 目录交给 wallpaper-wgpu（`renderKind = .scene`），渲染器报
    /// `VFS open failed` 而 App 侧仍判成功（2026-10-25 用户日志实证）。
    /// macOS 桌面通道原生支持 HEIC（系统默认桌面即 heic）；AVIF 需 macOS 13+，
    /// 本工程部署目标 14.4，满足。
    static let staticImageClassificationExts: Set<String> = [
        "jpg", "jpeg", "png", "bmp", "gif", "webp", "tga", "tif", "tiff",
        "heic", "heif", "avif"
    ]

    /// `findImageFile` 的搜索集。刻意**不含** tga/tif/tiff —— 该处原有口径就是这 6 个，
    /// 合并进来会静默扩大目录内可搜到的格式范围，不属于本次修复。只补 heic/heif/avif。
    static let staticImageSearchExts: Set<String> = [
        "jpg", "jpeg", "png", "bmp", "gif", "webp", "heic", "heif", "avif"
    ]

    struct Options: Codable {
        /// 所有用户可见的壁纸切换默认启用首帧预热过渡；恢复/回滚路径可显式关闭。
        var animatedTransition: Bool = true
        /// 播完即换且未开 web/scene 定时：跳过无播放完成事件的类型
        var requirePlaybackEndSupport: Bool = false
        var muted: Bool = true
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
        var wallpaperTransitionToken: [String: UInt64]? = nil
    }

    /// 对本地路径设壁纸。
    /// - Parameters:
    ///   - localURL: 本地文件或 Workshop 目录
    ///   - targetScreens: nil = 全部屏幕（与详情页单屏机默认行为一致）；非空则只设这些屏
    @discardableResult
    static func apply(
        localURL: URL,
        targetScreens: [NSScreen]?,
        options: Options = Options(),
        onStageChange: WallpaperApplyStageHandler? = nil
    ) async throws -> Bool {
        try Task.checkCancellation()
        if BackgroundRuntimeRole.isRemoteUI { return (try await BackgroundRuntimeBridge.request("wallpaper.apply", ["url": localURL, "screens": targetScreens, "options": try JSONEncoder().encode(options)])["success"] as? Bool) ?? false }

        guard FileManager.default.fileExists(atPath: localURL.path) else {
            throw ApplyError.missingFile(localURL.path)
        }

        var options = options
        let screens: [NSScreen]
        if WallpaperSchedulerService.shared.isGlobalDisplaySyncEnabled, !options.isGlobalTransaction {
            screens = NSScreen.screens
        } else if let targetScreens, !targetScreens.isEmpty {
            screens = targetScreens
        } else {
            screens = NSScreen.screens
        }
        guard !screens.isEmpty else { return false }
        let transitionToken: WallpaperCrossTypeTransitionCoordinator.RequestToken
        if let generations = options.wallpaperTransitionToken {
            let supplied = WallpaperCrossTypeTransitionCoordinator.RequestToken(generationsByScreen: generations)
            guard let token = WallpaperCrossTypeTransitionCoordinator.shared.subset(supplied, screens: screens) else {
                throw GlobalWallpaperSyncCoordinator.WallpaperApplySupersededError(
                    screenIDs: Set(screens.map(\.wallpaperScreenIdentifier)), requestToken: supplied
                )
            }
            transitionToken = token
        } else {
            transitionToken = WallpaperCrossTypeTransitionCoordinator.shared.beginRequest(on: screens)
        }
        options.wallpaperTransitionToken = transitionToken.generationsByScreen

        DesktopWallpaperSyncManager.shared.captureOriginalSystemWallpaperIfNeeded(for: screens)

        // 任何新的壁纸应用都会使上一轮伴生烘焙失效：被替换的壁纸不再显示，
        // 继续烘焙只浪费资源，失控时还会拖垮系统（2026-08-31 实测 16.4GB）。
        SceneOfflineBakeService.cancelRealtimeCompanionBake(reason: "apply:\(options.reason)")

        let isSchedulerInitiated = options.reason.hasPrefix("scheduler") || options.reason.hasPrefix("globalScheduler")
        let managesManualApplyLifecycle = !isSchedulerInitiated && !options.isGlobalTransaction
        let targetScreenIDs = Set(screens.map(\.wallpaperScreenIdentifier))
        var applySucceeded = false
        if managesManualApplyLifecycle {
            await WallpaperSchedulerService.shared.beginManualWallpaperApply()
        }
        defer {
            if managesManualApplyLifecycle {
                WallpaperSchedulerService.shared.completeManualWallpaperApply(
                    success: applySucceeded,
                    screenIDs: targetScreenIDs
                )
            }
        }
        try Task.checkCancellation()
        func succeeded() throws -> Bool {
            try checkRequestCurrent(transitionToken, on: screens)
            VideoWallpaperManager.shared.forceCommitDesktopPresentation(on: screens)
            applySucceeded = true
            return true
        }

        do {
        if WallpaperSchedulerService.shared.isGlobalDisplaySyncEnabled,
           !options.isGlobalTransaction {
            let ok = try await GlobalWallpaperSyncCoordinator.shared.apply(
                localURL: localURL,
                options: options,
                onStageChange: onStageChange
            )
            guard ok else { return false }
            return try succeeded()
        }

        guard WallpaperCrossTypeTransitionCoordinator.shared.isCurrent(transitionToken) else {
            throw CancellationError()
        }
        let ext = localURL.pathExtension.lowercased()
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: localURL.path, isDirectory: &isDirectory)
        print("[LocalWallpaperApply] apply 入口 path=\(localURL.lastPathComponent) ext=\(ext) isDir=\(isDirectory.boolValue) screens=\(screens.count) reason=\(options.reason)")

        let videoExts: Set<String> = ["mp4", "mov", "webm", "m4v", "mkv", "avi", "flv"]
        let imageExts = Self.staticImageClassificationExts

        // 1) 直接视频文件
        if !isDirectory.boolValue, videoExts.contains(ext) {
            try await applyVideo(localURL, to: screens, options: options, requestToken: transitionToken)
            return try succeeded()
        }

        // 2) 直接静态图
        if !isDirectory.boolValue, imageExts.contains(ext) {
            if options.requirePlaybackEndSupport { return false }
            try await applyStaticImage(localURL, to: screens, requestToken: transitionToken)
            return try succeeded()
        }

        // 3) Workshop 目录 / pkg
        let contentRoot = WorkshopService.resolveWallpaperEngineProjectRoot(startingAt: localURL)
        ensurePresetHTMLGenerated(at: contentRoot)

        let isRealtime = WaifuXPreferences.shared.bool(forKey: "scene_realtime_rendering_enabled")
        let contentType = determineWorkshopContentType(at: contentRoot)
        let allowNonVideoInOnEnd = !options.requirePlaybackEndSupport || screens.contains { hasWebSceneTimer(for: $0) }

        switch contentType {
        case .video:
            if let videoURL = findVideoFile(in: contentRoot) {
                try await applyVideo(videoURL, to: screens, options: options, requestToken: transitionToken)
                return try succeeded()
            }
            guard allowNonVideoInOnEnd else { return false }
            // 无内嵌视频文件的 video 工程：退回 CLI/web 渲染，不按 scene 做 companion bake
            try await applyRenderer(path: contentRoot.path, to: screens, options: options, scheduleSceneCompanionBake: false, onStageChange: onStageChange, requestToken: transitionToken)
            return try succeeded()

        case .scene:
            if isRealtime {
                guard allowNonVideoInOnEnd else { return false }
                // 详情页实时 scene：只 setWallpaper；companion bake 仅在已有产物时推锁屏，无产物且关自动烘焙则不烘不推
                try await applyRenderer(path: contentRoot.path, to: screens, options: options, scheduleSceneCompanionBake: true, onStageChange: onStageChange, requestToken: transitionToken)
                return try succeeded()
            }
            // 非实时：优先烘焙 MP4（与详情页 applySceneWallpaperPreferringBake 一致）
            if let bakedURL = usableBakedVideoURL(options: options, contentRoot: contentRoot) {
                // 详情页：若有 .web 组合目录则走 web 渲染
                let webDirPath = bakedURL.path.replacingOccurrences(of: ".mp4", with: ".web")
                if FileManager.default.fileExists(atPath: webDirPath) {
                    guard allowNonVideoInOnEnd else { return false }
                    try await applyRenderer(path: webDirPath, to: screens, options: options, scheduleSceneCompanionBake: false, onStageChange: onStageChange, requestToken: transitionToken)
                    return try succeeded()
                }
                try await applyVideo(bakedURL, to: screens, options: options, requestToken: transitionToken)
                return try succeeded()
            }
            // 无烘焙：不在此阻塞长烘焙。
            // 调度器：退回实时渲染（能设上桌面）；详情页应先 bake UI 再调本方法。
            guard allowNonVideoInOnEnd else { return false }
            try await applyRenderer(path: contentRoot.path, to: screens, options: options, scheduleSceneCompanionBake: true, onStageChange: onStageChange, requestToken: transitionToken)
            return try succeeded()

        case .web:
            // Align with scene: realtime mode always prefers live WKWebView daemon.
            // Baked MP4 is only for offline / non-realtime desktop playback (and posters).
            // Previously bake always short-circuited here, so "Set wallpaper" never
            // applied the live web wallpaper once a bake product existed.
            if !isRealtime,
               let bakedURL = usableBakedVideoURL(options: options, contentRoot: contentRoot) {
                try await applyVideo(bakedURL, to: screens, options: options, requestToken: transitionToken)
                return try succeeded()
            }
            guard allowNonVideoInOnEnd else { return false }
            try await applyRenderer(path: contentRoot.path, to: screens, options: options, scheduleSceneCompanionBake: false, onStageChange: onStageChange, requestToken: transitionToken)
            return try succeeded()

        case .image:
            guard !options.requirePlaybackEndSupport else { return false }
            if let imageURL = findImageFile(in: contentRoot) {
                try await applyStaticImage(imageURL, to: screens, requestToken: transitionToken)
                return try succeeded()
            }
            throw ApplyError.unsupported("image-directory")

        case .unsupported(let type):
            throw ApplyError.unsupported(type)

        case .unknown:
            if let videoURL = findVideoFile(in: contentRoot) {
                try await applyVideo(videoURL, to: screens, options: options, requestToken: transitionToken)
                return try succeeded()
            }
            if let bakedURL = usableBakedVideoURL(options: options, contentRoot: contentRoot) {
                try await applyVideo(bakedURL, to: screens, options: options, requestToken: transitionToken)
                return try succeeded()
            }
            guard allowNonVideoInOnEnd else { return false }
            if let imageURL = findImageFile(in: contentRoot) {
                try await applyStaticImage(imageURL, to: screens, requestToken: transitionToken)
                return try succeeded()
            }
            try await applyRenderer(path: contentRoot.path, to: screens, options: options, scheduleSceneCompanionBake: false, onStageChange: onStageChange, requestToken: transitionToken)
            return try succeeded()
        }
        } catch {
            if !Task.isCancelled,
               !WallpaperCrossTypeTransitionCoordinator.shared.isCurrent(transitionToken) {
                throw GlobalWallpaperSyncCoordinator.WallpaperApplySupersededError(
                    screenIDs: targetScreenIDs, requestToken: transitionToken
                )
            }
            throw error
        }
    }

    /// 调度器便捷封装：单屏 + animatedTransition。
    @discardableResult
    static func apply(
        localURL: URL,
        to screen: NSScreen,
        options: Options = Options(),
        onStageChange: WallpaperApplyStageHandler? = nil
    ) async throws -> Bool {
        try await apply(localURL: localURL, targetScreens: [screen], options: options, onStageChange: onStageChange)
    }

    // MARK: - Primitives

    private static func checkRequestCurrent(
        _ token: WallpaperCrossTypeTransitionCoordinator.RequestToken, on screens: [NSScreen]
    ) throws {
        try Task.checkCancellation()
        guard WallpaperCrossTypeTransitionCoordinator.shared.isCurrent(token) else {
            throw GlobalWallpaperSyncCoordinator.WallpaperApplySupersededError(
                screenIDs: Set(screens.map(\.wallpaperScreenIdentifier)), requestToken: token
            )
        }
    }

    private static func applyVideo(
        _ originalVideoURL: URL, to screens: [NSScreen], options: Options,
        requestToken: WallpaperCrossTypeTransitionCoordinator.RequestToken? = nil
    ) async throws {
        // 桌面/锁屏静态底图只认高清 poster（scene_bake_* / poster_wallpaper_*）。
        // 有缓存直接用；没有就同步抽一帧——切换需要静态帧先写桌面、拆旧窗、
        // 菜单栏采样，不能跳过。
        // 可播性兜底：AVFoundation 打不开（如 elst 计数损坏的 Workshop 视频）时
        // 先用内置 ffmpeg 转封装修复，避免「静默失败、桌面不动」。
        let videoURL = try await VideoRepairService.playableVideoURL(for: originalVideoURL)
        var hdPosterURL = VideoThumbnailCache.shared.existingWallpaperPosterURL(
            forLocalVideo: videoURL,
            sceneBakeItemID: options.sceneBakeItemID
        )
        if hdPosterURL == nil, options.generatePosterFromVideoIfNeeded {
            let genStarted = Date()
            hdPosterURL = await VideoThumbnailCache.shared.posterJPEGFileURL(forLocalVideo: videoURL)
            AppLogger.error(.wallpaper, "[VideoTransition] 无缓存封面，同步抽帧", metadata: [
                "video": videoURL.lastPathComponent,
                "ok": hdPosterURL != nil ? "1" : "0",
                "genMS": String(Int(Date().timeIntervalSince(genStarted) * 1000))
            ])
        }
        let immediatePosterURL = hdPosterURL
        print("[LocalWallpaperApply] applyVideo hdPoster=\(hdPosterURL?.lastPathComponent ?? "nil")")

        // Full current-screen-set applies use the nil-target path so window rebuild
        // and URL maps stay atomic across displays. Subsets still loop per screen.
        let coversAllScreens = !screens.isEmpty
            && screens.count == NSScreen.screens.count
            && Set(screens.map(\.wallpaperScreenIdentifier))
                == Set(NSScreen.screens.map(\.wallpaperScreenIdentifier))
        // 多屏播同一文件时默认共享一路 AVQueuePlayer，避免每屏各起 VTDecoderXPCService。
        // 仅「覆盖全部当前屏幕」或全局同步时走共享标志路径；子集多选仍按屏循环，
        // 由 VideoWallpaperManager 按 URL 机会式复用已有 player。
        let useShared = coversAllScreens && (options.usesSharedVideoDecoder
            || ((options.isGlobalTransaction || WallpaperSchedulerService.shared.isGlobalDisplaySyncEnabled)
                && screens.count > 1)
            || screens.count > 1)
        if let requestToken { try checkRequestCurrent(requestToken, on: screens) }
        if useShared {
            try await VideoWallpaperManager.shared.applyVideoWallpaper(
                from: videoURL,
                posterURL: immediatePosterURL,
                muted: options.muted,
                targetScreens: screens,
                animatedTransition: options.animatedTransition,
                usesSharedVideoDecoder: true,
                requestTransitionToken: requestToken
            )
        } else if coversAllScreens {
            try await VideoWallpaperManager.shared.applyVideoWallpaper(
                from: videoURL,
                posterURL: immediatePosterURL,
                muted: options.muted,
                targetScreen: nil,
                animatedTransition: options.animatedTransition,
                usesSharedVideoDecoder: false,
                requestTransitionToken: requestToken
            )
        } else {
            try await VideoWallpaperManager.shared.applyVideoWallpaper(
                from: videoURL,
                posterURL: immediatePosterURL,
                muted: options.muted,
                targetScreens: screens,
                animatedTransition: options.animatedTransition,
                usesSharedVideoDecoder: false,
                requestTransitionToken: requestToken
            )
        }

        if let requestToken { try checkRequestCurrent(requestToken, on: screens) }
        // 仅系统壁纸同步开启时注册桌面 poster；动态层（视频窗）不受影响
        if let immediatePosterURL, VideoWallpaperManager.shared.isSystemWallpaperSyncEnabled {
            for screen in screens {
                DesktopWallpaperSyncManager.shared.registerWallpaperSet(immediatePosterURL, for: screen)
            }
        }

        // 同步抽帧失败时的后台兜底：再试一次，生成后回写各屏 poster 和系统桌面
        if immediatePosterURL == nil, options.generatePosterFromVideoIfNeeded {
            let sceneBakeItemID = options.sceneBakeItemID
            let bakedVideoPath = options.bakedVideoPath
            let targetScreenIDs = Set(screens.map(\.wallpaperScreenIdentifier))
            let targetFingerprints = Set(screens.map(\.wallpaperScreenFingerprint))
            let expectedVideoURL = videoURL.standardizedFileURL
            Task(priority: .utility) { @MainActor in
                var posterURL: URL?
                // scene_bake 键只属于真烘焙产物：应用的正是那份可用烘焙 MP4 时才写；
                // 纯视频（无 bakedVideoPath 或根本对不上）一律走路径键，杜绝视频蹭出 scene_bake_*。
                if let itemID = sceneBakeItemID,
                   let bakedPath = bakedVideoPath,
                   !bakedPath.isEmpty,
                   URL(fileURLWithPath: bakedPath).standardizedFileURL == videoURL.standardizedFileURL,
                   SceneOfflineBakeService.isUsableBakedVideo(at: URL(fileURLWithPath: bakedPath)) {
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
                    if let requestToken,
                       !WallpaperCrossTypeTransitionCoordinator.shared.isCurrent(requestToken, on: screen) { continue }
                    // 用户已切到别的视频时不要回写旧 poster
                    vm.updatePosterURL(posterURL, for: screen, expectedVideoURL: expectedVideoURL)
                }
            }
        }
    }

    private static func applyStaticImage(
        _ imageURL: URL, to screens: [NSScreen],
        requestToken: WallpaperCrossTypeTransitionCoordinator.RequestToken? = nil
    ) async throws {
        if screens.count == 1, let only = screens.first {
            try await StaticWallpaperApplyService.apply(
                from: imageURL, option: .desktop, for: only, requestToken: requestToken
            )
            return
        }

        // One transaction publishes every target before it retires any old
        // presentation. Sequential per-screen commits could leave a half apply.
        try await StaticWallpaperApplyService.apply(
            from: imageURL, option: .desktop, targetScreens: screens, requestToken: requestToken
        )
    }

    /// - Parameter scheduleSceneCompanionBake: 仅 scene 实时路径为 true。
    ///   web / preset / 非 scene 不得触发 scene 离线 companion bake。
    private static func applyRenderer(
        path: String,
        to screens: [NSScreen],
        options: Options,
        scheduleSceneCompanionBake: Bool,
        onStageChange: WallpaperApplyStageHandler? = nil,
        requestToken: WallpaperCrossTypeTransitionCoordinator.RequestToken? = nil
    ) async throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw ApplyError.missingFile(path)
        }
        if WallpaperEngineXBridge.resolvedCLIExecutableURL() == nil {
            throw ApplyError.failed("wallpaper-wgpu 渲染器未找到")
        }
        let isRealtime = WaifuXPreferences.shared.bool(forKey: "scene_realtime_rendering_enabled")
        // user properties 仅 scene 实时有意义；web 传 nil
        let userProps = (scheduleSceneCompanionBake && isRealtime)
            ? SceneWallpaperPropertiesService.propertiesOverrideJSON(for: path)
            : nil
        try await WallpaperEngineXBridge.shared.setWallpaper(
            path: path,
            targetScreens: screens,
            userProperties: userProps,
            requireAllTargetScreens: options.isGlobalTransaction,
            requestTransitionToken: requestToken,
            onStageChange: onStageChange
        )
        try Task.checkCancellation()
        if let requestToken { try checkRequestCurrent(requestToken, on: screens) }
        // 系统底图由 WallpaperEngineXBridge 统一提交：Scene 在不透明窗口显示前写入，
        // 未提交成功的屏由桥内封面同步兜底；Web 沿用自己的海报与有限采样保持链。
        // 此处不得在 renderer 就绪后再写一次，否则会重置已完成前置提交的采样源。
        // 伴生烘焙也由桥的最终成功路径调度，覆盖启动恢复、显示器重连等入口。
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
            if case .scene = determineWorkshopContentType(at: contentRoot) {
                if SceneOfflineBakeService.isCurrentBakedSceneVideo(at: url, contentRoot: contentRoot) { return url }
            } else if SceneOfflineBakeService.isUsableBakedVideo(at: url) { return url }
        }
        if let record = mediaRecord(for: contentRoot),
           let art = SceneOfflineBakeService.usableCurrentArtifact(from: record) {
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
                if Self.staticImageClassificationExts.contains(ext) {
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
        // AVPlayer 对 h264/h265 (mp4/mov) 兼容性最好，vp9 (webm) 可能无法打开；
        // Workshop 壁纸常同时自带预烘焙 mp4 + webm，优先 mp4/mov，webm 仅兜底。
        let preferredExts: Set<String> = ["mp4", "mov", "m4v"]
        if let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) {
            for case let fileURL as URL in enumerator where preferredExts.contains(fileURL.pathExtension.lowercased()) {
                return fileURL
            }
        }
        if let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) {
            for case let fileURL as URL in enumerator where fileURL.pathExtension.lowercased() == "webm" {
                return fileURL
            }
        }
        return nil
    }

    private static func findImageFile(in directory: URL) -> URL? {
        let imageExts = Self.staticImageSearchExts
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
