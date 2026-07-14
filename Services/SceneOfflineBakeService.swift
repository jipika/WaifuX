import AppKit
import AVFoundation
import Foundation
import Kingfisher

enum SceneOfflineBakeError: LocalizedError {
    case cliNotFound
    case ineligible
    case contentRootMissing
    case insufficientMemory
    case concurrentBakeInProgress
    case bakeProcessFailed(String)

    var errorDescription: String? {
        switch self {
        case .cliNotFound: return "未找到 wallpaper-wgpu"
        case .ineligible: return "当前 Scene 不适合离线烘焙（资格不足）"
        case .contentRootMissing: return "内容目录不存在，请重新下载"
        case .insufficientMemory: return LocalizationService.shared.t("sceneBake.error.insufficientMemory.bake")
        case .concurrentBakeInProgress: return LocalizationService.shared.t("sceneBake.error.concurrent")
        case .bakeProcessFailed(let msg): return msg
        }
    }
}

enum SceneBakeRenderer: String, CaseIterable, Codable, Hashable, Sendable {
    case wallpaperWgpu

    var displayName: String {
        switch self {
        case .wallpaperWgpu: return "1. wallpaper-wgpu"
        }
    }
}

extension Notification.Name {
    /// 烘焙视频抽帧封面已生成。`object` 为 `String`（itemID），`userInfo["thumbnailURL"]` 为 `URL`。
    static let sceneOfflineBakeThumbnailDidUpdate = Notification.Name("sceneOfflineBakeThumbnailDidUpdate")
}

@discardableResult
@MainActor
func regenerateSceneBakePosterAndNotify(itemID: String, videoURL: URL) async -> URL? {
    guard SceneOfflineBakeService.isUsableBakedVideo(at: videoURL) else { return nil }
    guard let posterURL = await VideoThumbnailCache.shared.sceneBakePosterJPEGFileURL(
        forLocalVideo: videoURL,
        itemID: itemID,
        forceRegenerate: true
    ) else {
        return nil
    }
    // 清除 Kingfisher 对该 poster URL 的缓存，确保下次 KFImage 加载时读取磁盘上的新文件
    try? await ImageCache.default.removeImage(forKey: posterURL.cacheKey)
    // KFImage 使用了 DownsamplingImageProcessor(size: 512x512)，处理器会生成不同的缓存 key
    // （格式：originalKey@processorIdentifier），必须一并清除，否则旧的降采样版本仍被命中
    let processor = DownsamplingImageProcessor(size: CGSize(width: 512, height: 512))
    try? await ImageCache.default.removeImage(forKey: posterURL.cacheKey, processorIdentifier: processor.identifier)
    print("[BakeService] ✅ 已清除 Kingfisher 缓存: \(posterURL.cacheKey)")
    NotificationCenter.default.post(
        name: .sceneOfflineBakeThumbnailDidUpdate,
        object: itemID,
        userInfo: ["thumbnailURL": posterURL]
    )
    return posterURL
}

/// 全局只允许一个 `wallpaper-wgpu bake` 子进程，避免重叠渲染导致内存成倍上涨。
private actor SceneOfflineBakeConcurrencyGate {
    static let shared = SceneOfflineBakeConcurrencyGate()
    private var busy = false
    private var busySince: Date?

    func tryEnter() -> Bool {
        // 安全重置：如果门控卡死超过 10 分钟，自动重置
        if busy, let since = busySince, Date().timeIntervalSince(since) > 600 {
            print("[SceneOfflineBakeConcurrencyGate] ⚠️ 门控卡死超过 10 分钟，自动重置")
            busy = false
            busySince = nil
        }
        if busy { return false }
        busy = true
        busySince = Date()
        return true
    }

    func leave() {
        busy = false
        busySince = nil
    }
}

@MainActor
private final class ScenePreviewProcessController {
    static let shared = ScenePreviewProcessController()
    private var process: Process?
    private var renderer: SceneBakeRenderer?

    func stop() {
        guard let process else { return }
        if process.isRunning {
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if kill(pid, 0) == 0 {
                    kill(pid, SIGKILL)
                }
            }
        }
        self.process = nil
        self.renderer = nil
    }

    func launch(executableURL: URL, arguments: [String], renderer: SceneBakeRenderer) throws {
        stop()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = SceneOfflineBakeService.rendererLaunchEnvironment(for: executableURL)
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.process?.processIdentifier == process.processIdentifier {
                    self.process = nil
                    self.renderer = nil
                }
            }
        }
        try process.run()
        self.process = process
        self.renderer = renderer
    }
}

/// 将 Workshop Scene 预渲染为循环 MP4，并写入下载记录。
enum SceneOfflineBakeService {
    private struct BakedVideoInspection {
        let duration: TimeInterval
        let width: Int
        let height: Int
    }

    private static func displayIDs(for screens: [NSScreen]?) -> [UInt32] {
        let targetScreens = (screens?.isEmpty == false) ? screens! : NSScreen.screens
        return targetScreens.compactMap { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        }
    }

    private static func usableArtifact(from record: MediaDownloadRecord?) -> SceneBakeArtifact? {
        guard let record,
              let artifact = record.sceneBakeArtifact,
              artifact.analysisId == record.sceneBakeEligibility?.analysisId,
              isUsableBakedVideo(at: URL(fileURLWithPath: artifact.videoPath)) else {
            return nil
        }
        return artifact
    }

    @MainActor
    private static func downloadedRecord(forResolvedContentRoot contentRoot: URL) -> MediaDownloadRecord? {
        let resolvedPath = WorkshopService.resolveWallpaperEngineProjectRoot(startingAt: contentRoot).path
        if let exact = MediaLibraryService.shared.downloadRecord(forLocalFilePath: resolvedPath) {
            return exact
        }
        return MediaLibraryService.shared.downloadedItems.first { record in
            WorkshopService.resolveWallpaperEngineProjectRoot(startingAt: URL(fileURLWithPath: record.localFilePath)).path == resolvedPath
        }
    }

    /// 返回与 Scene 工程根目录对应、且仍通过完整性校验的烘焙视频。
    /// 详情页的 `resolvedItem.id` 在不同来源间可能与下载记录不完全一致，
    /// 因此必须按工程根目录查找，不能只依赖页面 item ID。
    @MainActor
    static func usableBakedVideoURL(
        forSceneContentRoot contentRoot: URL,
        matchingCurrentBakeSettings: Bool = false
    ) -> URL? {
        guard let record = downloadedRecord(forResolvedContentRoot: contentRoot),
              let artifact = usableArtifact(from: record) else {
            return nil
        }
        if matchingCurrentBakeSettings,
           !hasCachedArtifact(
            record: record,
            renderer: .wallpaperWgpu,
            durationSeconds: resolvedBakeDuration(),
            fps: resolvedBakeFPS()
           ) {
            return nil
        }
        return URL(fileURLWithPath: artifact.videoPath)
    }

    /// Ensures that a Scene currently selected as wallpaper has a bake job.
    ///
    /// `auto_bake_scene` controls opportunistic baking after import. Explicitly
    /// setting a Scene is different: it must always receive a background job so
    /// non-realtime playback can eventually use the MP4 without blocking setup.
    @MainActor
    static func enqueueBakeForAppliedScene(
        path: String,
        completion: SceneBakeQueueService.Completion? = nil
    ) {
        let contentRoot = WorkshopService.resolveWallpaperEngineProjectRoot(
            startingAt: URL(fileURLWithPath: path)
        )
        guard SceneBakeEligibilityAnalyzer.sceneContentRootIfEligibleForAnalysis(
            localFileURL: contentRoot
        ) != nil else {
            return
        }

        if let record = downloadedRecord(forResolvedContentRoot: contentRoot) {
            SceneBakeQueueService.shared.enqueue(record: record, completion: completion)
        } else {
            SceneBakeQueueService.shared.enqueue(
                sceneContentRoot: contentRoot,
                cacheItemID: stableOrphanCacheItemID(contentRootPath: contentRoot.path),
                completion: completion
            )
        }
    }

    /// 实时渲染桌面后配套生成离线 MP4。
    /// 该 MP4 不会反向替换桌面实时渲染；如果动态锁屏开启，则烘焙完成后推送给对应显示器实例。
    @MainActor
    static func scheduleRealtimeCompanionBake(path: String, targetScreens: [NSScreen]? = nil, reason: String) {
        let contentRoot = WorkshopService.resolveWallpaperEngineProjectRoot(startingAt: URL(fileURLWithPath: path))
        guard SceneBakeEligibilityAnalyzer.sceneContentRootIfEligibleForAnalysis(localFileURL: contentRoot) != nil else {
            print("[SceneOfflineBake] realtime companion bake skipped (\(reason)): not a scene project \(contentRoot.path)")
            return
        }

        let displayIDs = displayIDs(for: targetScreens)

        let record = downloadedRecord(forResolvedContentRoot: contentRoot)
        let completion: SceneBakeQueueService.Completion = { result in
            guard case .success(let artifact) = result else { return }
            let videoURL = URL(fileURLWithPath: artifact.videoPath)
            VideoWallpaperManager.shared.enqueueAutomaticOptimizationForBakedScene(
                videoURL: videoURL,
                title: record?.item.title ?? contentRoot.lastPathComponent,
                pipelineItemID: record?.item.id
            )
            if #available(macOS 26.0, *) {
                Task {
                    await syncRealtimeBakeToLockScreen(
                        artifact: artifact,
                        itemID: record?.item.id,
                        displayIDs: displayIDs,
                        reason: reason
                    )
                }
            }
        }
        enqueueBakeForAppliedScene(path: contentRoot.path, completion: completion)
    }

    @available(macOS 26.0, *)
    @MainActor
    private static func syncRealtimeBakeToLockScreen(
        artifact: SceneBakeArtifact,
        itemID: String?,
        displayIDs: [UInt32],
        reason: String
    ) async {
        let videoURL = URL(fileURLWithPath: artifact.videoPath)
        guard isUsableBakedVideo(at: videoURL) else { return }

        if VideoWallpaperManager.shared.isLockScreenEnabled {
            // 动态锁屏开启：推送烘焙视频到锁屏实例
            guard !displayIDs.isEmpty else { return }
            let videoID = itemID ?? URL(fileURLWithPath: artifact.videoPath).deletingPathExtension().lastPathComponent
            await LockScreenWallpaperService.shared.switchActiveInstancesToLocalDecode(
                videoURL: videoURL,
                videoID: videoID,
                displayIDs: displayIDs
            )
            print("[SceneOfflineBake] realtime companion bake synced lock screen (\(reason)): display=\(displayIDs) video=\(videoID)")
        } else {
            // 动态锁屏关闭：用烘焙产物的静态帧设置桌面 poster（不启动视频播放器）
            if let posterURL = await VideoThumbnailCache.shared.lockScreenPosterURL(forLocalVideo: videoURL, fallbackPosterURL: nil) {
                let fillOptions: [NSWorkspace.DesktopImageOptionKey: Any] = [
                    .imageScaling: NSNumber(value: NSImageScaling.scaleProportionallyUpOrDown.rawValue),
                    .allowClipping: true
                ]
                // 只把 poster 推给目标显示器，绝不能写回 NSScreen.screens 全集 ——
                // 否则用户只在屏幕 N 上启用场景实时渲染时，烘焙完成会把静帧 poster
                // 顺手贴到其它屏的桌面（其它屏没有 wallpaper-wgpu 叠层挡着，直接可见）。
                // 入参 displayIDs 已由调用方按 targetScreens 精确指定，这里照单全收。
                let targetScreens: [NSScreen]
                if displayIDs.isEmpty {
                    // 调用方未指定 → 退回历史行为（兼容无显示器信息的路径）
                    targetScreens = NSScreen.screens
                } else {
                    let idSet = Set(displayIDs)
                    targetScreens = NSScreen.screens.filter { screen in
                        guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                            return false
                        }
                        return idSet.contains(n.uint32Value)
                    }
                }
                for screen in targetScreens {
                    try? NSWorkspace.shared.setDesktopImageURLForAllSpaces(posterURL, for: screen, options: fillOptions)
                    DesktopWallpaperSyncManager.shared.registerWallpaperSet(posterURL, for: screen, options: fillOptions)
                }
                print("[SceneOfflineBake] realtime companion bake set desktop poster (\(reason)) on \(targetScreens.count) screen(s) display=\(displayIDs): \(posterURL.path)")
            }
        }
    }

    @MainActor
    static func isRendererAvailable(_ renderer: SceneBakeRenderer) -> Bool {
        switch renderer {
        case .wallpaperWgpu:
            return WallpaperEngineXBridge.resolvedCLIExecutableURL() != nil
        }
    }

    @MainActor
    static func stopPreview() {
        ScenePreviewProcessController.shared.stop()
    }

    @MainActor
    static func preview(record: MediaDownloadRecord, renderer: SceneBakeRenderer) throws {
        guard let eligibility = record.sceneBakeEligibility else {
            throw SceneOfflineBakeError.ineligible
        }
        let contentRoot = URL(fileURLWithPath: eligibility.contentRootPath)
        try preview(
            eligibility: eligibility,
            contentRoot: contentRoot,
            renderer: renderer
        )
    }

    @MainActor
    static func preview(
        eligibility: SceneBakeEligibilitySnapshot,
        contentRoot: URL,
        renderer: SceneBakeRenderer
    ) throws {
        guard FileManager.default.fileExists(atPath: contentRoot.path) else {
            throw SceneOfflineBakeError.contentRootMissing
        }

        switch renderer {
        case .wallpaperWgpu:
            guard let cli = WallpaperEngineXBridge.resolvedCLIExecutableURL() else {
                throw SceneOfflineBakeError.cliNotFound
            }
            // 预览不传 `--wallpaper` / `--background`：保留一个普通可见窗口供用户查看，
            // 不要把窗口贴成桌面壁纸层级（壁纸层级会被其他窗口遮住，且鼠标事件全部穿透）。
            var args = [contentRoot.path]
            if let assets = WallpaperEngineEmbeddedAssets.materializedAssetsRootIfPresent(),
               !assets.isEmpty {
                args += ["--assets", assets]
            }
            try ScenePreviewProcessController.shared.launch(
                executableURL: cli,
                arguments: args,
                renderer: renderer
            )
        }
    }

    /// 缓存文件路径：`analysisId + 分辨率 + fps + 时长`（根目录为 `DownloadPathManager.sceneBakesFolderURL`）
    private static func cacheVideoURL(
        baseDir: URL,
        itemID: String,
        analysisId: UUID,
        renderer: SceneBakeRenderer,
        width: Int,
        height: Int,
        fps: Int,
        durationSeconds: Double
    ) -> URL {
        let safeID = itemID.replacingOccurrences(of: "/", with: "_")
        let dir = baseDir.appendingPathComponent(safeID, isDirectory: true)
        let name =
            "\(analysisId.uuidString)_\(renderer.rawValue)_\(width)x\(height)_\(fps)fps_\(Int(durationSeconds))s.mp4"
        return dir.appendingPathComponent(name)
    }

    static func rendererLaunchEnvironment(for executableURL: URL) -> [String: String] {
        let rendererDirectory = executableURL.deletingLastPathComponent()
        var env = ProcessInfo.processInfo.environment
        let searchPaths = [
            rendererDirectory.path,
            rendererDirectory.deletingLastPathComponent().path,
            env["PATH"] ?? ""
        ].filter { !$0.isEmpty }
        env["PATH"] = searchPaths.joined(separator: ":")

        let libraryPaths = [
            rendererDirectory.appendingPathComponent("lib").path,
            rendererDirectory.deletingLastPathComponent().appendingPathComponent("lib").path,
            rendererDirectory.appendingPathComponent("Resources").appendingPathComponent("lib").path,
            rendererDirectory.deletingLastPathComponent().appendingPathComponent("Resources/lib").path,
            env["DYLD_LIBRARY_PATH"] ?? ""
        ].filter { !$0.isEmpty }
        env["DYLD_LIBRARY_PATH"] = libraryPaths.joined(separator: ":")
        return env
    }

    /// 无媒体库记录时（例如仅能从 Steam 目录解析到工程）用于缓存目录名的稳定 ID。
    static func stableOrphanCacheItemID(contentRootPath: String) -> String {
        var hash: UInt64 = 1469598103934665603
        for b in contentRootPath.utf8 {
            hash ^= UInt64(b)
            hash &*= 1099511628211
        }
        return "orphan_\(hash)"
    }

    /// 与资格快照配套；`cacheItemID` 通常等于 `MediaItem.id`，无记录时用 `stableOrphanCacheItemID`。
    /// - Parameter persistArtifactToItemID: 非 nil 时将成品写回对应下载记录。
    static func bake(
        eligibility: SceneBakeEligibilitySnapshot,
        contentRoot: URL,
        cacheItemID: String,
        durationSeconds: Double? = nil,
        fps: Int32? = nil,
        renderer: SceneBakeRenderer = .wallpaperWgpu,
        persistArtifactToItemID: String? = nil,
        progress: (@MainActor (Double) -> Void)? = nil
    ) async throws -> SceneBakeArtifact {
        let effectiveFPS = resolvedBakeFPS(fps)
        let effectiveDuration = resolvedBakeDuration(durationSeconds)
        // 并发门控：防止多个烘焙同时运行
        let entered = await SceneOfflineBakeConcurrencyGate.shared.tryEnter()
        guard entered else {
            throw SceneOfflineBakeError.concurrentBakeInProgress
        }
        do {
            let result = try await bakeCore(
                eligibility: eligibility,
                contentRoot: contentRoot,
                cacheItemID: cacheItemID,
                durationSeconds: effectiveDuration,
                fps: effectiveFPS,
                renderer: renderer,
                persistArtifactToItemID: persistArtifactToItemID,
                progress: progress
            )
            await SceneOfflineBakeConcurrencyGate.shared.leave()
            return result
        } catch {
            await SceneOfflineBakeConcurrencyGate.shared.leave()
            throw error
        }
    }

    private static func bakeCore(
        eligibility: SceneBakeEligibilitySnapshot,
        contentRoot: URL,
        cacheItemID: String,
        durationSeconds: Double,
        fps: Int32,
        renderer: SceneBakeRenderer,
        persistArtifactToItemID: String?,
        progress: (@MainActor (Double) -> Void)?
    ) async throws -> SceneBakeArtifact {
        guard FileManager.default.fileExists(atPath: contentRoot.path) else {
            throw SceneOfflineBakeError.contentRootMissing
        }
        guard SystemMemoryPressure.hasRoomForSceneOfflineBake() else {
            throw SceneOfflineBakeError.insufficientMemory
        }

        let mainDisplaySize = mainDisplayPixelSize()
        let w = max(64, mainDisplaySize.width)
        let h = max(64, mainDisplaySize.height)
        let evenW = (w / 2) * 2
        let evenH = (h / 2) * 2

        let sceneBakesRoot = await MainActor.run {
            DownloadPathManager.shared.sceneBakesFolderURL
        }
        let cacheDurationSeconds = durationSeconds
        let outURL = cacheVideoURL(
            baseDir: sceneBakesRoot,
            itemID: cacheItemID,
            analysisId: eligibility.analysisId,
            renderer: renderer,
            width: evenW,
            height: evenH,
            fps: Int(fps),
            durationSeconds: cacheDurationSeconds
        )

        try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let cachedInspection: BakedVideoInspection? = await {
            switch renderer {
            case .wallpaperWgpu:
                return await inspectBakedVideo(at: outURL, expectedWidth: evenW, expectedHeight: evenH)
            }
        }()
        if let cachedInspection,
           let attrs = try? FileManager.default.attributesOfItem(atPath: outURL.path) {
            let artifact = SceneBakeArtifact(
                analysisId: eligibility.analysisId,
                videoPath: outURL.path,
                width: cachedInspection.width,
                height: cachedInspection.height,
                fps: Int(fps),
                durationSeconds: durationSeconds,
                bakedAt: (attrs[.creationDate] as? Date) ?? .now,
                renderer: renderer
            )
            if let itemID = persistArtifactToItemID {
                await MainActor.run {
                    MediaLibraryService.shared.attachSceneBakeArtifact(
                        itemID: itemID,
                        artifact: artifact,
                        regeneratePoster: false
                    )
                }
                await regenerateSceneBakePosterAndNotify(
                    itemID: itemID,
                    videoURL: URL(fileURLWithPath: artifact.videoPath)
                )
            }
            return artifact
        }
        if FileManager.default.fileExists(atPath: outURL.path) {
            print("[SceneOfflineBake] removing invalid cached MP4: \(outURL.path)")
            try? FileManager.default.removeItem(at: outURL)
        }

        let artifact: SceneBakeArtifact
        switch renderer {
        case .wallpaperWgpu:
            artifact = try await bakeWithWallpaperWgpu(
                contentRoot: contentRoot,
                outURL: outURL,
                eligibility: eligibility,
                width: evenW,
                height: evenH,
                fps: fps,
                durationSeconds: durationSeconds,
                progress: progress
            )
        }
        if let itemID = persistArtifactToItemID {
            await MainActor.run {
                MediaLibraryService.shared.attachSceneBakeArtifact(
                    itemID: itemID,
                    artifact: artifact,
                    regeneratePoster: false
                )
            }
            await regenerateSceneBakePosterAndNotify(
                itemID: itemID,
                videoURL: URL(fileURLWithPath: artifact.videoPath)
            )
        }

        return artifact
    }

    private static func bakeWithWallpaperWgpu(
        contentRoot: URL,
        outURL: URL,
        eligibility: SceneBakeEligibilitySnapshot,
        width: Int,
        height: Int,
        fps: Int32,
        durationSeconds: Double,
        progress: (@MainActor (Double) -> Void)?
    ) async throws -> SceneBakeArtifact {
        // 使用 wallpaper-wgpu bake 子命令（GPU readback 直接编码，不需要屏幕录制）
        guard let wgpuBinary = WallpaperEngineXBridge.resolvedCLIExecutableURL() else {
            throw SceneOfflineBakeError.cliNotFound
        }

        let tempURL = outURL.deletingLastPathComponent()
            .appendingPathComponent(".\(outURL.deletingPathExtension().lastPathComponent).\(UUID().uuidString).tmp.mp4")
        try? FileManager.default.removeItem(at: tempURL)

        // wallpaper-wgpu bake <path> --size WxH --fps N --duration S --out <path> [--assets <path>] [--clean]
        var args: [String] = [
            "bake",
            contentRoot.path,
            "--size", "\(width)x\(height)",
            "--fps", String(fps),
            "--clean",
            "--out", tempURL.path,
        ]

        // assets 路径（异步等待解压完成）
        if let assets = await WallpaperEngineEmbeddedAssets.awaitAssetsReady(), !assets.isEmpty {
            args += ["--assets", assets]
        }

        // 自动检测周期时不需要传 --duration，让 bake 自己检测
        if durationSeconds > 0 {
            args += ["--duration", String(Int(durationSeconds))]
        }

        print("[SceneOfflineBake] 启动 wallpaper-wgpu bake: \(wgpuBinary.lastPathComponent) \(args.joined(separator: " "))")

        let process = Process()
        process.executableURL = wgpuBinary
        process.currentDirectoryURL = wgpuBinary.deletingLastPathComponent()
        process.arguments = args
        var env = SceneOfflineBakeService.rendererLaunchEnvironment(for: wgpuBinary)
        env["RUST_LOG"] = env["RUST_LOG"] ?? "warn"
        process.environment = env

        let stderrPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = stdoutPipe

        try process.run()

        final class StderrCapture: @unchecked Sendable {
            private let maxTailBytes = 256 * 1024
            var tail = Data()
            let logURL: URL
            let logHandle: FileHandle?

            init() {
                logURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("waifux-wallpaper-wgpu-bake-\(UUID().uuidString).log")
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
                logHandle = try? FileHandle(forWritingTo: logURL)
            }

            func append(_ data: Data) {
                logHandle?.write(data)
                tail.append(data)
                if tail.count > maxTailBytes {
                    tail.removeFirst(tail.count - maxTailBytes)
                }
            }

            func close() {
                try? logHandle?.close()
            }
        }
        let stderrCapture = StderrCapture()

        // stdout 捕获：收集 DYNAMIC_TEXTS / IMAGES / AUDIO_SPECTRUM / AUDIO_VISUALIZERS JSON
        final class StdoutCapture: @unchecked Sendable {
            var data = Data()
            func append(_ chunk: Data) {
                data.append(chunk)
            }
            /// 解析 DYNAMIC_TEXTS: 行并返回 JSON Data
            func dynamicTextsJSON() -> Data? {
                guard let text = String(data: data, encoding: .utf8) else { return nil }
                for line in text.components(separatedBy: "\n") {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.hasPrefix("DYNAMIC_TEXTS:") {
                        let jsonStr = String(trimmed.dropFirst(14))
                        return jsonStr.data(using: .utf8)
                    }
                }
                return nil
            }
            /// 解析 IMAGES: 行并返回 JSON Data
            func imagesJSON() -> Data? {
                guard let text = String(data: data, encoding: .utf8) else { return nil }
                for line in text.components(separatedBy: "\n") {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.hasPrefix("IMAGES:") {
                        let jsonStr = String(trimmed.dropFirst(7))
                        return jsonStr.data(using: .utf8)
                    }
                }
                return nil
            }
        }
        let stdoutCapture = StdoutCapture()

        final class WallpaperWgpuBakeProgressParser: @unchecked Sendable {
            private let phaseFramePattern = try? NSRegularExpression(
                pattern: #"^\s*\[bake\]\s*(预热|录制|编码|完成)\s+(\d+)/(\d+)\s+\[(\d+(?:\.\d+)?)%\]"#
            )
            private let phaseTotalPattern = try? NSRegularExpression(
                pattern: #"^\s*\[bake\]\s*(预热|录制)\s+(\d+)\s+帧"#
            )
            private let percentPattern = try? NSRegularExpression(pattern: #"\[(\d+(?:\.\d+)?)%\]"#)

            private var warmupFrames: Double?
            private var recordingFrames: Double?
            private var lastProgress: Double = 0

            func progress(from line: String) -> Double? {
                updatePhaseTotals(from: line)

                if let progress = progressFromPhaseFrameLine(line) {
                    return publish(progress)
                }

                guard let pct = progressPercent(in: line) else {
                    return nil
                }
                let phaseProgress = pct / 100.0
                if line.contains("预热") {
                    return publish(mapPhaseProgress(phase: "预热", current: phaseProgress, total: 1))
                }
                if line.contains("录制") {
                    return publish(mapPhaseProgress(phase: "录制", current: phaseProgress, total: 1))
                }
                if line.contains("编码") {
                    return publish(0.98)
                }
                return publish(phaseProgress)
            }

            private func updatePhaseTotals(from line: String) {
                guard let match = phaseTotalPattern?.firstMatch(
                    in: line,
                    range: NSRange(location: 0, length: line.utf16.count)
                ), let phaseRange = Range(match.range(at: 1), in: line),
                   let totalRange = Range(match.range(at: 2), in: line),
                   let total = Double(line[totalRange]) else {
                    return
                }

                switch String(line[phaseRange]) {
                case "预热":
                    warmupFrames = total
                case "录制":
                    recordingFrames = total
                default:
                    break
                }
            }

            private func progressFromPhaseFrameLine(_ line: String) -> Double? {
                guard let match = phaseFramePattern?.firstMatch(
                    in: line,
                    range: NSRange(location: 0, length: line.utf16.count)
                ), let phaseRange = Range(match.range(at: 1), in: line),
                   let currentRange = Range(match.range(at: 2), in: line),
                   let totalRange = Range(match.range(at: 3), in: line),
                   let pctRange = Range(match.range(at: 4), in: line),
                   let current = Double(line[currentRange]),
                   let total = Double(line[totalRange]),
                   let pct = Double(line[pctRange]) else {
                    return nil
                }

                let phase = String(line[phaseRange])
                if isGlobalProgress(phase: phase, total: total) {
                    return pct / 100.0
                }
                return mapPhaseProgress(phase: phase, current: current, total: total)
            }

            private func isGlobalProgress(phase: String, total: Double) -> Bool {
                switch phase {
                case "预热":
                    if let warmupFrames {
                        return abs(total - warmupFrames) > 0.5
                    }
                case "录制":
                    if let recordingFrames {
                        return abs(total - recordingFrames) > 0.5
                    }
                default:
                    break
                }
                return false
            }

            private func mapPhaseProgress(phase: String, current: Double, total: Double) -> Double {
                let warmupWeight = 0.20
                let recordingCeiling = 0.98
                let phaseProgress = total > 0 ? min(max(current / total, 0), 1) : 0

                switch phase {
                case "预热":
                    return phaseProgress * warmupWeight
                case "录制":
                    return warmupWeight + phaseProgress * (recordingCeiling - warmupWeight)
                case "编码":
                    return recordingCeiling
                case "完成":
                    return 1.0
                default:
                    return phaseProgress
                }
            }

            private func progressPercent(in line: String) -> Double? {
                guard let match = percentPattern?.firstMatch(
                    in: line,
                    range: NSRange(location: 0, length: line.utf16.count)
                ), let range = Range(match.range(at: 1), in: line) else {
                    return nil
                }
                return Double(line[range])
            }

            private func publish(_ progress: Double) -> Double? {
                let clamped = min(max(progress, 0.0), 0.99)
                guard clamped >= lastProgress || clamped >= 0.99 else {
                    return nil
                }
                lastProgress = max(lastProgress, clamped)
                return lastProgress
            }
        }

        // 监控 stderr 中的进度信息。兼容旧版阶段内百分比和新版全局百分比。
        let stderrHandle = stderrPipe.fileHandleForReading
        let stdoutHandle = stdoutPipe.fileHandleForReading
        let progressTask = Task.detached(priority: .utility) {
            let progressParser = WallpaperWgpuBakeProgressParser()
            var buffer = ""
            while !Task.isCancelled {
                let data = stderrHandle.availableData
                if data.isEmpty { break }
                stderrCapture.append(data)
                if let chunk = String(data: data, encoding: .utf8) {
                    buffer += chunk
                    let lines = buffer.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
                    buffer = lines.last ?? ""
                    for line in lines.dropLast() where !line.isEmpty {
                        if let parsedProgress = progressParser.progress(from: line) {
                            await progress?(parsedProgress)
                        }
                    }
                }
            }
            // 处理缓冲区中剩余内容
            if !buffer.isEmpty, let parsedProgress = progressParser.progress(from: buffer) {
                await progress?(parsedProgress)
            }
        }

        // 读取 stdout（DYNAMIC_TEXTS 等 JSON 数据）
        let stdoutTask = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                let data = stdoutHandle.availableData
                if data.isEmpty { break }
                stdoutCapture.append(data)
            }
        }

        // 用轮询替代 waitUntilExit，避免阻塞 cooperative thread pool
        while process.isRunning {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        await progressTask.value
        await stdoutTask.value
        stderrCapture.close()

        guard process.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: tempURL)
            let stderrString = String(data: stderrCapture.tail, encoding: .utf8) ?? ""
            let cleanStderr = stderrString
                .replacingOccurrences(of: "\r", with: "\n")
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter {
                    !$0.isEmpty
                    && !$0.contains(" INFO ")
                    && !$0.hasPrefix("[bake] 预热 ")
                    && !$0.hasPrefix("[bake] 烘焙 ")
                }
                .suffix(20)
                .joined(separator: "\n")
            let message = cleanStderr.isEmpty
                ? "wallpaper-wgpu bake 执行失败 (exit=\(process.terminationStatus))\n完整日志: \(stderrCapture.logURL.path)"
                : "wallpaper-wgpu bake 执行失败 (exit=\(process.terminationStatus))\n\(cleanStderr)\n完整日志: \(stderrCapture.logURL.path)"
            throw SceneOfflineBakeError.bakeProcessFailed(message)
        }

        guard await inspectBakedVideo(at: tempURL, expectedWidth: width, expectedHeight: height) != nil else {
            try? FileManager.default.removeItem(at: tempURL)
            try? FileManager.default.removeItem(at: outURL)
            throw SceneOfflineBakeError.bakeProcessFailed("bake 完成后未找到输出文件")
        }
        try? FileManager.default.removeItem(at: outURL)
        try FileManager.default.moveItem(at: tempURL, to: outURL)

        // 写入 sidecar JSON（动态文本 + 图片数据）
        let sidecarURL = outURL.deletingPathExtension().appendingPathExtension("json")
        if var sidecarDict = stdoutCapture.dynamicTextsJSON().flatMap({
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }) {
            // 合并 IMAGES 数据到 sidecar
            if let imagesData = stdoutCapture.imagesJSON(),
               let imagesDict = try? JSONSerialization.jsonObject(with: imagesData) as? [String: Any],
               let images = imagesDict["images"] {
                sidecarDict["images"] = images
            }
            if let mergedData = try? JSONSerialization.data(withJSONObject: sidecarDict, options: [.sortedKeys, .withoutEscapingSlashes]) {
                try? mergedData.write(to: sidecarURL, options: .atomic)
                print("[SceneOfflineBake] wallpaper-wgpu sidecar JSON 已写入: \(sidecarURL.lastPathComponent)")
            }
        }

        await MainActor.run { progress?(1.0) }

        return SceneBakeArtifact(
            analysisId: eligibility.analysisId,
            videoPath: outURL.path,
            width: width,
            height: height,
            fps: Int(fps),
            durationSeconds: durationSeconds,
            bakedAt: .now,
            renderer: .wallpaperWgpu
        )
    }

    /// 解析本次烘焙应使用的帧率。未指定时读取当前全局设置。
    static func resolvedBakeFPS(_ requestedFPS: Int32? = nil) -> Int32 {
        if let requestedFPS {
            return Int32(min(max(requestedFPS, 15), 60))
        }
        let saved = UserDefaults.standard.double(forKey: "scene_bake_fps")
        return saved >= 15 ? Int32(min(max(saved, 15), 60)) : 30
    }

    /// 解析本次烘焙应使用的时长。未指定时读取当前全局设置。
    static func resolvedBakeDuration(_ requestedDuration: Double? = nil) -> Double {
        if let requestedDuration {
            return min(max(requestedDuration, 5), 60)
        }
        let saved = UserDefaults.standard.double(forKey: "scene_bake_duration")
        return saved >= 5 ? min(max(saved, 5), 60) : 15
    }

    /// 检查是否有缓存（不触发实际烘焙）。传入时长或帧率时，必须与成片元数据匹配。
    static func hasCachedArtifact(
        record: MediaDownloadRecord,
        renderer: SceneBakeRenderer? = nil,
        durationSeconds: Double? = nil,
        fps: Int32? = nil
    ) -> Bool {
        guard let art = record.sceneBakeArtifact,
              art.analysisId == record.sceneBakeEligibility?.analysisId,
              isUsableBakedVideo(at: URL(fileURLWithPath: art.videoPath)) else { return false }
        if let renderer {
            guard art.renderer == renderer else { return false }
        }
        if let durationSeconds,
           abs(art.durationSeconds - resolvedBakeDuration(durationSeconds)) > 0.01 {
            return false
        }
        if let fps, art.fps != Int(resolvedBakeFPS(fps)) {
            return false
        }
        return true
    }

    /// 与 `MediaDownloadRecord.sceneBakeEligibility` 配套；默认主屏逻辑分辨率 × scale。
    /// FPS 默认值取自用户设置 `scene_bake_fps`（回退 30）。
    static func bake(
        record: MediaDownloadRecord,
        durationSeconds: Double? = nil,
        fps: Int32? = nil,
        renderer: SceneBakeRenderer = .wallpaperWgpu,
        progress: (@MainActor (Double) -> Void)? = nil
    ) async throws -> SceneBakeArtifact {
        let effectiveFPS = resolvedBakeFPS(fps)
        let effectiveDuration = resolvedBakeDuration(durationSeconds)
        guard let eligibility = record.sceneBakeEligibility else {
            throw SceneOfflineBakeError.ineligible
        }
        let contentRoot = URL(fileURLWithPath: eligibility.contentRootPath)
        return try await bake(
            eligibility: eligibility,
            contentRoot: contentRoot,
            cacheItemID: record.id,
            durationSeconds: effectiveDuration,
            fps: effectiveFPS,
            renderer: renderer,
            persistArtifactToItemID: record.id,
            progress: progress
        )
    }

    /// 资格写入后后台自动烘焙（推荐/边缘档位）；已有同 `analysisId` 成品则跳过。
    static func scheduleAutoBakeAfterEligibility(itemID: String) {
        Task(priority: .utility) {
            try? await Task.sleep(nanoseconds: 200_000_000)
            let record = await MainActor.run { () -> MediaDownloadRecord? in
                MediaLibraryService.shared.downloadedItems.first { $0.item.id == itemID }
            }
            guard let record,
                  let eligibility = record.sceneBakeEligibility else { return }
            guard SystemMemoryPressure.hasRoomForSceneOfflineBake() else {
                print("[SceneOfflineBake] auto-bake skipped: insufficient reclaimable memory")
                return
            }
            if hasCachedArtifact(
                record: record,
                renderer: .wallpaperWgpu,
                durationSeconds: resolvedBakeDuration(),
                fps: resolvedBakeFPS()
            ) {
                return
            }
            await MainActor.run {
                SceneBakeQueueService.shared.enqueue(record: record) { result in
                    switch result {
                    case .success(let artifact):
                        print("[SceneOfflineBake] auto-bake finished \(itemID): \(artifact.videoPath)")
                    case .failure(let error):
                        print("[SceneOfflineBake] auto-bake failed \(itemID): \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    static func isUsableBakedVideo(at url: URL) -> Bool {
        inspectBakedVideoSync(at: url) != nil
    }

    private static func mainDisplayPixelSize() -> (width: Int, height: Int) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let frame = screen?.frame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let scale = screen?.backingScaleFactor ?? 1
        let width = max(64, Int((frame.width * scale).rounded()))
        let height = max(64, Int((frame.height * scale).rounded()))
        print("[SceneOfflineBake] main display pixels: \(width)x\(height) (frame=\(Int(frame.width))x\(Int(frame.height)), scale=\(scale))")
        return (width, height)
    }

    private static func inspectBakedVideo(at url: URL, expectedWidth: Int? = nil, expectedHeight: Int? = nil) async -> BakedVideoInspection? {
        guard url.isFileURL,
              FileManager.default.fileExists(atPath: url.path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber,
              size.int64Value > 10_000 else {
            return nil
        }

        let asset = AVURLAsset(url: url)
        let duration = try? await asset.load(.duration)
        guard let durationSec = duration?.seconds, durationSec.isFinite, durationSec > 0.5 else { return nil }
        guard let track = (try? await asset.loadTracks(withMediaType: .video))?.first else { return nil }
        let naturalSize = (try? await track.load(.naturalSize)) ?? .zero
        let preferredTransform = (try? await track.load(.preferredTransform)) ?? .identity
        let transformedSize = naturalSize.applying(preferredTransform)
        let width = abs(Int(transformedSize.width.rounded()))
        let height = abs(Int(transformedSize.height.rounded()))
        guard width > 0, height > 0 else { return nil }
        if let expectedWidth, let expectedHeight, (width != expectedWidth || height != expectedHeight) {
            print("[SceneOfflineBake] invalid cached MP4 size: actual=\(width)x\(height) expected=\(expectedWidth)x\(expectedHeight) url=\(url.path)")
            return nil
        }
        return BakedVideoInspection(duration: durationSec, width: width, height: height)
    }

    private static func inspectBakedVideoSync(at url: URL, expectedWidth: Int? = nil, expectedHeight: Int? = nil) -> BakedVideoInspection? {
        final class Box: @unchecked Sendable { var value: BakedVideoInspection? }
        let semaphore = DispatchSemaphore(value: 0)
        let box = Box()
        DispatchQueue.global().async {
            Task {
                box.value = await inspectBakedVideo(at: url, expectedWidth: expectedWidth, expectedHeight: expectedHeight)
                semaphore.signal()
            }
        }
        semaphore.wait()
        return box.value
    }
}
