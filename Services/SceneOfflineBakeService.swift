import AppKit
import AVFoundation
import CryptoKit
import Foundation
import Kingfisher

enum SceneOfflineBakeError: LocalizedError {
    case cliNotFound
    case webCliNotFound
    case ineligible
    case contentRootMissing
    case insufficientMemory
    case concurrentBakeInProgress
    case bakeProcessFailed(String)

    var errorDescription: String? {
        switch self {
        case .cliNotFound: return "未找到 wallpaper-wgpu"
        case .webCliNotFound: return "未找到 wallpaperengine-cli"
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
    case wallpaperEngineWeb

    var displayName: String {
        switch self {
        case .wallpaperWgpu: return "1. wallpaper-wgpu"
        case .wallpaperEngineWeb: return "2. wallpaperengine-cli Web"
        }
    }
}

extension Notification.Name {
    /// Scene 离线烘焙完成（成功或失败）。`object` 为 `SceneBakeArtifact?`，失败时为 `nil`。
    static let sceneOfflineBakeDidComplete = Notification.Name("sceneOfflineBakeDidComplete")
    /// 烘焙视频抽帧封面已生成。`object` 为 `String`（itemID），`userInfo["thumbnailURL"]` 为 `URL`。
    static let sceneOfflineBakeThumbnailDidUpdate = Notification.Name("sceneOfflineBakeThumbnailDidUpdate")
    /// 烘焙进度更新。`object` 为 `String`（itemID），`userInfo["progress"]` 为 `Double`（0.0 ~ 1.0）。
    static let sceneOfflineBakeProgressDidUpdate = Notification.Name("sceneOfflineBakeProgressDidUpdate")
}

@discardableResult
@MainActor
func regenerateSceneBakePosterAndNotify(itemID: String, videoURL: URL) async -> URL? {
    guard SceneOfflineBakeService.isUsableBakedVideo(at: videoURL) else { return nil }

    // 重新烘焙时 MP4 路径通常不变（analysisId+分辨率+fps+时长）；必须先清列表帧，
    // 否则 library 优先 list_*.jpg 会一直显示旧画面。
    VideoThumbnailCache.shared.removeListThumbnail(forLocalVideo: videoURL)

    // 并行重生：高清 poster（锁屏/桌面/详情）+ 列表完整画幅小图（我的库网格）
    async let posterTask = VideoThumbnailCache.shared.sceneBakePosterJPEGFileURL(
        forLocalVideo: videoURL,
        itemID: itemID,
        forceRegenerate: true
    )
    async let listTask = VideoThumbnailCache.shared.regenerateListThumbnailJPEGFileURL(forLocalVideo: videoURL)
    let posterURL = await posterTask
    let listURL = await listTask

    // 库列表优先完整画幅 list 帧；无则退 poster
    let displayURL = listURL ?? posterURL
    guard let displayURL else { return nil }

    let processor = DownsamplingImageProcessor(size: CGSize(width: 512, height: 512))
    for url in [displayURL, posterURL, listURL].compactMap({ $0 }) {
        try? await ImageCache.default.removeImage(forKey: url.cacheKey)
        try? await ImageCache.default.removeImage(
            forKey: url.cacheKey,
            processorIdentifier: processor.identifier
        )
    }
    print("[BakeService] ✅ 已刷新烘焙封面 item=\(itemID) list=\(listURL?.lastPathComponent ?? "nil") poster=\(posterURL?.lastPathComponent ?? "nil")")

    NotificationCenter.default.post(
        name: .sceneOfflineBakeThumbnailDidUpdate,
        object: itemID,
        userInfo: ["thumbnailURL": displayURL]
    )
    return displayURL
}

/// 确保已有烘焙 MP4 具备高清 poster；命中缓存时不重复解码视频。
@discardableResult
@MainActor
func ensureSceneBakePosterAndNotify(itemID: String, videoURL: URL) async -> URL? {
    guard SceneOfflineBakeService.isUsableBakedVideo(at: videoURL),
          let posterURL = await VideoThumbnailCache.shared.sceneBakePosterJPEGFileURL(
              forLocalVideo: videoURL,
              itemID: itemID
          ) else {
        return nil
    }

    let processor = DownsamplingImageProcessor(size: CGSize(width: 512, height: 512))
    try? await ImageCache.default.removeImage(forKey: posterURL.cacheKey)
    try? await ImageCache.default.removeImage(
        forKey: posterURL.cacheKey,
        processorIdentifier: processor.identifier
    )
    NotificationCenter.default.post(
        name: .sceneOfflineBakeThumbnailDidUpdate,
        object: itemID,
        userInfo: ["thumbnailURL": posterURL]
    )
    return posterURL
}

/// Enough information to rebuild an unfinished Scene/Web bake after relaunch.
struct PersistentOfflineBakeJob: Codable, Hashable, Sendable, Identifiable {
    enum Kind: String, Codable, Hashable, Sendable {
        case scene
        case web
    }

    let id: UUID
    let key: String
    let kind: Kind
    let itemID: String?
    let recordID: String?
    let contentRootPath: String
    let eligibility: SceneBakeEligibilitySnapshot?
    let cacheItemID: String?
    let durationSeconds: Double
    let fps: Int
    let renderer: SceneBakeRenderer
    let persistArtifactToItemID: String?
    let progressItemID: String?
    /// Companion bakes are tied to the currently displayed realtime scene and can
    /// be cancelled when the user applies another wallpaper.
    let isCompanion: Bool?
    let addedAt: Date

    static func scene(
        id: UUID = UUID(),
        eligibility: SceneBakeEligibilitySnapshot,
        contentRoot: URL,
        cacheItemID: String,
        durationSeconds: Double,
        fps: Int32,
        renderer: SceneBakeRenderer,
        persistArtifactToItemID: String?,
        progressItemID: String?,
        isCompanion: Bool = false
    ) -> PersistentOfflineBakeJob {
        let normalizedRoot = contentRoot.standardizedFileURL.path
        let key = [
            Kind.scene.rawValue,
            normalizedRoot,
            eligibility.analysisId.uuidString,
            cacheItemID,
            renderer.rawValue,
            String(fps),
            String(format: "%.3f", durationSeconds),
        ].joined(separator: "|")
        return PersistentOfflineBakeJob(
            id: id,
            key: key,
            kind: .scene,
            itemID: progressItemID ?? persistArtifactToItemID,
            recordID: persistArtifactToItemID,
            contentRootPath: normalizedRoot,
            eligibility: eligibility,
            cacheItemID: cacheItemID,
            durationSeconds: durationSeconds,
            fps: Int(fps),
            renderer: renderer,
            persistArtifactToItemID: persistArtifactToItemID,
            progressItemID: progressItemID,
            isCompanion: isCompanion,
            addedAt: .now
        )
    }

    static func web(
        id: UUID = UUID(),
        record: MediaDownloadRecord,
        contentRoot: URL,
        outputURL: URL,
        durationSeconds: Double,
        fps: Int32
    ) -> PersistentOfflineBakeJob {
        PersistentOfflineBakeJob(
            id: id,
            key: "\(Kind.web.rawValue)|\(outputURL.standardizedFileURL.path)",
            kind: .web,
            itemID: record.item.id,
            recordID: record.id,
            contentRootPath: contentRoot.standardizedFileURL.path,
            eligibility: nil,
            cacheItemID: record.id,
            durationSeconds: durationSeconds,
            fps: Int(fps),
            renderer: .wallpaperEngineWeb,
            persistArtifactToItemID: record.id,
            progressItemID: record.item.id,
            isCompanion: nil,
            addedAt: .now
        )
    }
}

private struct OfflineBakeQueueCheckpointStore {
    private struct Snapshot: Codable {
        let version: Int
        let jobs: [PersistentOfflineBakeJob]
    }

    static let shared = OfflineBakeQueueCheckpointStore()

    private var fileURL: URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return support
            .appendingPathComponent("WaifuX", isDirectory: true)
            .appendingPathComponent("SceneBake", isDirectory: true)
            .appendingPathComponent("pending-queue.json")
    }

    func load() -> [PersistentOfflineBakeJob] {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.version == 1 else {
            return []
        }
        var seen = Set<String>()
        return snapshot.jobs
            .sorted { $0.addedAt < $1.addedAt }
            .filter { seen.insert($0.key).inserted }
    }

    func save(_ jobs: [PersistentOfflineBakeJob]) {
        guard !jobs.isEmpty else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            try encoder.encode(Snapshot(version: 1, jobs: jobs))
                .write(to: fileURL, options: .atomic)
        } catch {
            print("[OfflineBakeQueue] checkpoint write failed: \(error.localizedDescription)")
        }
    }
}

/// 所有离线烘焙共用的串行 FIFO 队列。
///
/// Scene / Web 烘焙都会占用大量 GPU、内存和编码资源。这里允许用户连续提交任务，
/// 但始终只放行一个实际子进程，避免重叠渲染导致内存成倍上涨。
actor OfflineBakeSerialQueue {
    static let shared = OfflineBakeSerialQueue()

    private struct Waiter {
        let jobID: UUID
        let continuation: CheckedContinuation<Void, Never>
    }

    private var activeJobID: UUID?
    private var waiters: [Waiter] = []

    func waitForTurn(jobID: UUID) async {
        if activeJobID == nil, waiters.isEmpty {
            activeJobID = jobID
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(Waiter(jobID: jobID, continuation: continuation))
        }
    }

    func leave(jobID: UUID) {
        guard activeJobID == jobID else { return }
        activeJobID = nil

        guard !waiters.isEmpty else { return }
        let next = waiters.removeFirst()
        activeJobID = next.jobID
        next.continuation.resume()
    }
}

/// 跨详情页生命周期保留的烘焙进度。
/// 详情页关闭后 `@State` 会丢，重进时需要从这里恢复 UI。
@MainActor
final class SceneOfflineBakeProgressTracker {
    static let shared = SceneOfflineBakeProgressTracker()

    enum State: Equatable {
        case queued
        case running
    }

    struct Entry: Identifiable, Equatable {
        let id: UUID
        let itemID: String?
        let persistentJob: PersistentOfflineBakeJob?
        var state: State
        var progress: Double
    }

    struct EnqueueResult {
        let jobID: UUID
        let shouldExecute: Bool
    }

    private(set) var entries: [Entry]
    private var claimedRestoredJobIDs = Set<UUID>()

    private init() {
        let restoredJobs = OfflineBakeQueueCheckpointStore.shared.load()
        entries = restoredJobs.map {
            Entry(
                id: $0.id,
                itemID: $0.itemID,
                persistentJob: $0,
                state: .queued,
                progress: 0
            )
        }
        guard !restoredJobs.isEmpty else { return }
        print("[OfflineBakeQueue] restored \(restoredJobs.count) unfinished bake job(s)")
        Task { @MainActor in
            // MediaLibraryService finishes its own persisted-record load during app startup.
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await SceneOfflineBakeService.resumePersistedBakeQueue()
        }
    }

    var activeItemID: String? {
        entries.first(where: { $0.state == .running })?.itemID
    }

    var progress: Double {
        entries.first(where: { $0.state == .running })?.progress ?? 0
    }

    var isBaking: Bool { !entries.isEmpty }

    func enqueue(
        job: PersistentOfflineBakeJob,
        resumingJobID: UUID? = nil
    ) -> EnqueueResult {
        if let resumingJobID,
           let existing = entries.first(where: { $0.id == resumingJobID }) {
            let claimed = claimedRestoredJobIDs.insert(resumingJobID).inserted
            return EnqueueResult(jobID: existing.id, shouldExecute: claimed)
        }
        if let existing = entries.first(where: { $0.persistentJob?.key == job.key }) {
            print("[OfflineBakeQueue] duplicate bake excluded: \(job.key)")
            return EnqueueResult(jobID: existing.id, shouldExecute: false)
        }

        entries.append(
            Entry(
                id: job.id,
                itemID: job.itemID,
                persistentJob: job,
                state: .queued,
                progress: 0
            )
        )
        persistPendingJobs()
        notifyProgress(itemID: job.itemID, progress: 0)
        return EnqueueResult(jobID: job.id, shouldExecute: true)
    }

    func begin(jobID: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == jobID }) else { return }
        entries[index].state = .running
        notifyProgress(itemID: entries[index].itemID, progress: entries[index].progress)
    }

    func update(jobID: UUID, progress value: Double) {
        guard let index = entries.firstIndex(where: { $0.id == jobID }) else { return }
        let clamped = min(max(value, 0.0), 0.99)
        entries[index].progress = max(entries[index].progress, clamped)
        notifyProgress(itemID: entries[index].itemID, progress: entries[index].progress)
    }

    func finish(jobID: UUID, success: Bool) {
        guard let index = entries.firstIndex(where: { $0.id == jobID }) else { return }
        let entry = entries[index]
        if success {
            notifyProgress(itemID: entry.itemID, progress: 1)
        }
        entries.remove(at: index)
        claimedRestoredJobIDs.remove(jobID)
        persistPendingJobs()
    }

    func progress(for itemID: String) -> Double? {
        entries.first(where: { $0.itemID == itemID })?.progress
    }

    var pendingPersistentJobs: [PersistentOfflineBakeJob] {
        entries.compactMap(\.persistentJob).sorted { $0.addedAt < $1.addedAt }
    }

    func discardPersistedJob(id: UUID, reason: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let itemID = entries[index].itemID
        entries.remove(at: index)
        claimedRestoredJobIDs.remove(id)
        persistPendingJobs()
        notifyProgress(itemID: itemID, progress: 0)
        print("[OfflineBakeQueue] dropped restored job \(id): \(reason)")
    }

    private func persistPendingJobs() {
        OfflineBakeQueueCheckpointStore.shared.save(entries.compactMap(\.persistentJob))
    }

    private func notifyProgress(itemID: String?, progress: Double) {
        guard let itemID else { return }
        NotificationCenter.default.post(
            name: .sceneOfflineBakeProgressDidUpdate,
            object: itemID,
            userInfo: ["progress": progress]
        )
    }
}

@MainActor
private final class ScenePreviewProcessController {
    static let shared = ScenePreviewProcessController()
    private var process: Process?
    private var renderer: SceneBakeRenderer?
    private var memoryWatchdogTask: Task<Void, Never>?

    func stop() {
        memoryWatchdogTask?.cancel()
        memoryWatchdogTask = nil
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
                    self.memoryWatchdogTask?.cancel()
                    self.memoryWatchdogTask = nil
                }
            }
        }
        try process.run()
        self.process = process
        self.renderer = renderer
        startMemoryWatchdog(pid: process.processIdentifier)
    }

    /// 预览子进程内存看门狗：phys_footprint 超过 1.5GB 视为 runaway，
    /// 立即终止，避免用户打开异常项目时拖垮整个 App。
    private func startMemoryWatchdog(pid: pid_t) {
        memoryWatchdogTask?.cancel()
        memoryWatchdogTask = Task(priority: .utility) { [weak self] in
            let limitBytes: UInt64 = 1_500_000_000
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { return }
                guard let process = self.process,
                      process.isRunning,
                      process.processIdentifier == pid else { return }
                var info = rusage_info_current()
                let status = withUnsafeMutablePointer(to: &info) { pointer in
                    pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                        proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
                    }
                }
                guard status == 0 else { continue }
                if info.ri_phys_footprint > limitBytes {
                    let footprintMB = info.ri_phys_footprint / 1_048_576
                    print("[SceneOfflineBake] ⚠️ bake 进程内存超限 \(footprintMB)MB > 1500MB，强制终止（pid=\(pid)）")
                    self.stop()
                    return
                }
            }
        }
    }
}

/// 跟踪真正执行 `wallpaper-wgpu bake` 的子进程。
/// 预览进程和 bake 进程是两条独立的 Process 生命周期，不能共用预览 controller。
@MainActor
private final class SceneBakeProcessController {
    static let shared = SceneBakeProcessController()

    private var process: Process?
    private var processID: pid_t?
    private var isCompanionProcess = false
    private var memoryWatchdogTask: Task<Void, Never>?
    private var terminationSerial: UInt64 = 0

    func attach(process: Process, isCompanion: Bool) {
        if self.process != nil {
            terminateCurrentProcess()
        }
        terminationSerial &+= 1
        self.process = process
        processID = process.processIdentifier
        isCompanionProcess = isCompanion
        startMemoryWatchdog(process: process)
    }

    func finish(pid: pid_t) {
        guard process?.processIdentifier == pid else { return }
        memoryWatchdogTask?.cancel()
        memoryWatchdogTask = nil
        process = nil
        processID = nil
        isCompanionProcess = false
        terminationSerial &+= 1
    }

    func stopCompanion() {
        guard isCompanionProcess else { return }
        terminateCurrentProcess()
    }

    func stop(pid: pid_t) {
        guard processID == pid else { return }
        terminateCurrentProcess()
    }

    private func terminateCurrentProcess() {
        guard let process,
              let pid = processID,
              process.processIdentifier == pid else {
            return
        }

        memoryWatchdogTask?.cancel()
        memoryWatchdogTask = nil
        self.process = nil
        processID = nil
        isCompanionProcess = false
        terminationSerial &+= 1
        let serial = terminationSerial

        if process.isRunning {
            process.terminate()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self, process] in
            guard let self else { return }
            guard self.terminationSerial == serial else { return }
            guard process.isRunning,
                  process.processIdentifier == pid else {
                return
            }
            kill(pid, SIGKILL)
        }
    }

    private func startMemoryWatchdog(process: Process) {
        let pid = process.processIdentifier
        memoryWatchdogTask?.cancel()
        memoryWatchdogTask = Task(priority: .utility) { [weak self] in
            let limitBytes: UInt64 = 1_500_000_000
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                } catch {
                    return
                }

                guard let self,
                      self.process === process,
                      process.isRunning,
                      self.processID == pid else {
                    return
                }

                var info = rusage_info_current()
                let status = withUnsafeMutablePointer(to: &info) { pointer in
                    pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                        proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
                    }
                }
                guard status == 0 else { continue }
                if info.ri_phys_footprint > limitBytes {
                    let footprintMB = info.ri_phys_footprint / 1_048_576
                    print("[SceneOfflineBake] bake 进程内存超限 \(footprintMB)MB > 1500MB，强制终止（pid=\(pid)）")
                    self.stop(pid: pid)
                    return
                }
            }
        }
    }
}

/// 将 Workshop Scene 预渲染为循环 MP4，并写入下载记录。
enum SceneOfflineBakeService {
    private struct BakedVideoInspection {
        let duration: TimeInterval
        let width: Int
        let height: Int
    }

    private struct RealtimePosterTarget: Sendable {
        let displayID: UInt32
        let size: WallpaperPosterPixelSize
    }

    /// 已连接显示器中的最高刷新率，用作离线烘焙输出的帧率上限。
    private static var maximumBakeFPS: Double {
        Double(NSScreen.screens.map(\.maxRefreshRate).max() ?? 60)
    }

    /// 将显式请求或用户偏好规范为烘焙器可用的帧率。
    ///
    /// 统一在服务层限制，确保自动烘焙和旧版保存的偏好也不会超过显示器最高刷新率。
    private static func resolvedBakeFPS(requestedFPS: Int32?) -> Int32 {
        let selectedFPS: Double
        if let requestedFPS {
            selectedFPS = Double(requestedFPS)
        } else {
            let savedFPS = UserDefaults.standard.double(forKey: "scene_bake_fps")
            selectedFPS = savedFPS >= 15 ? savedFPS : 30
        }
        return Int32(min(max(selectedFPS, 15), maximumBakeFPS))
    }

    @MainActor
    private static func realtimePosterTargets(for screens: [NSScreen]?) -> [RealtimePosterTarget] {
        let targetScreens = (screens?.isEmpty == false) ? screens! : NSScreen.screens
        var seenDisplayIDs = Set<UInt32>()
        return targetScreens.compactMap { screen in
            guard let screenNumber = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else {
                return nil
            }
            let displayID = screenNumber.uint32Value
            guard seenDisplayIDs.insert(displayID).inserted else { return nil }

            let frame = screen.frame
            return RealtimePosterTarget(
                displayID: displayID,
                size: WallpaperPosterGeometry.evenPixelSize(
                    widthPoints: frame.width,
                    heightPoints: frame.height,
                    scale: screen.backingScaleFactor
                )
            )
        }
    }

    private static func realtimePosterVariantKey(
        eligibility: SceneBakeEligibilitySnapshot,
        size: WallpaperPosterPixelSize
    ) -> String {
        "\(eligibility.analysisId.uuidString.lowercased())_\(size.width)x\(size.height)"
    }

    static func usableArtifact(from record: MediaDownloadRecord?) -> SceneBakeArtifact? {
        guard let record,
              let artifact = record.sceneBakeArtifact,
              isUsableBakedVideo(at: URL(fileURLWithPath: artifact.videoPath)) else {
            return nil
        }
        // Web bake: no eligibility snapshot; file presence is enough (same as recovery path).
        if artifact.renderer == .wallpaperEngineWeb {
            return artifact
        }
        // Scene bake: analysisId must still match eligibility when present.
        if let eligibilityId = record.sceneBakeEligibility?.analysisId,
           artifact.analysisId != eligibilityId {
            return nil
        }
        return artifact
    }

    @MainActor
    private static func downloadedRecord(forResolvedContentRoot contentRoot: URL) -> MediaDownloadRecord? {
        let resolvedContentRoot = WorkshopService.resolveWallpaperEngineProjectRoot(startingAt: contentRoot)
        let resolvedPath = resolvedContentRoot.path
        if let exact = MediaLibraryService.shared.downloadRecord(forLocalFilePath: resolvedPath) {
            return exact
        }
        return MediaLibraryService.shared.downloadedItems.first { record in
            // SteamCMD stores a Workshop download at its outer `workshop_<id>` directory,
            // whose sibling content/downloads/temp folders prevent a generic root walk from
            // reaching the actual project. Use the record's canonical path comparison first.
            record.hasSameLocalContent(as: resolvedContentRoot)
                || WorkshopService.resolveWallpaperEngineProjectRoot(
                    startingAt: URL(fileURLWithPath: record.localFilePath)
                ).path == resolvedPath
        }
    }

    /// 实时渲染桌面后配套生成离线 MP4。
    /// 该 MP4 不会反向替换桌面实时渲染；如果动态锁屏开启，则烘焙完成后推送给对应显示器实例。
    /// 关闭自动烘焙时，缓存未命中会改为临时烘焙 1 秒，仅保留抽出的 poster。
    /// 伴生烘焙代数：任何新的壁纸应用都会使上一轮伴生烘焙失效
    /// （被替换的壁纸不再显示，继续烘焙只浪费资源，失控时还会拖垮系统）。
    private static let companionBakeGenerationLock = NSLock()
    private nonisolated(unsafe) static var _companionBakeGeneration: UInt = 0

    /// 递增代数并终止 in-flight bake 进程。在每次壁纸应用入口调用。
    @MainActor
    static func cancelRealtimeCompanionBake(reason: String) {
        companionBakeGenerationLock.lock()
        _companionBakeGeneration &+= 1
        companionBakeGenerationLock.unlock()
        SceneBakeProcessController.shared.stopCompanion()
        ScenePreviewProcessController.shared.stop()
        print("[SceneOfflineBake] realtime companion bake cancelled (\(reason))")
    }

    private static var companionBakeGeneration: UInt {
        companionBakeGenerationLock.lock()
        defer { companionBakeGenerationLock.unlock() }
        return _companionBakeGeneration
    }

    @MainActor
    static func scheduleRealtimeCompanionBake(path: String, targetScreens: [NSScreen]? = nil, reason: String) {
        let autoBakeEnabled = UserDefaults.standard.bool(forKey: "auto_bake_scene")
        let contentRoot = WorkshopService.resolveWallpaperEngineProjectRoot(startingAt: URL(fileURLWithPath: path))
        guard SceneBakeEligibilityAnalyzer.sceneContentRootIfEligibleForAnalysis(localFileURL: contentRoot) != nil else {
            print("[SceneOfflineBake] realtime companion bake skipped (\(reason)): not a scene project \(contentRoot.path)")
            return
        }

        let posterTargets = realtimePosterTargets(for: targetScreens)
        let displayIDs = posterTargets.map(\.displayID)
        let generation = companionBakeGeneration
        AppLogger.error(.wallpaper, "Scene companion poster scheduled", metadata: [
            "reason": reason,
            "autoBake": autoBakeEnabled,
            "contentRoot": contentRoot.path,
            "targetCount": posterTargets.count,
            "displayIDs": displayIDs.map(String.init).joined(separator: ","),
            "generation": generation
        ])

        Task(priority: .utility) {
            do {
                let record = await MainActor.run {
                    downloadedRecord(forResolvedContentRoot: contentRoot)
                }

                guard generation == companionBakeGeneration else {
                    print("[SceneOfflineBake] realtime companion bake stale (\(reason)): superseded before record lookup")
                    return
                }

                if let artifact = usableArtifact(from: record) {
                    guard generation == companionBakeGeneration else { return }
                    await syncRealtimeBakeToLockScreen(
                        artifact: artifact,
                        itemID: record?.item.id,
                        displayIDs: displayIDs,
                        reason: reason,
                        generation: generation
                    )
                    print("[SceneOfflineBake] realtime companion bake cache hit (\(reason)): \(artifact.videoPath)")
                    return
                }

                guard autoBakeEnabled else {
                    await generateTransientRealtimePosters(
                        contentRoot: contentRoot,
                        record: record,
                        targets: posterTargets,
                        reason: reason,
                        generation: generation
                    )
                    return
                }

                guard generation == companionBakeGeneration else {
                    print("[SceneOfflineBake] realtime companion bake stale (\(reason)): superseded by newer apply")
                    return
                }

                let eligibility: SceneBakeEligibilitySnapshot
                if let existing = record?.sceneBakeEligibility,
                   SceneBakeEligibilityAnalyzer.isSameContentRoot(existing.contentRootPath, contentRoot.path) {
                    eligibility = existing
                } else {
                    guard SystemMemoryPressure.hasRoomForSceneEligibilityAnalysis() else {
                        print("[SceneOfflineBake] realtime companion bake skipped (\(reason)): insufficient memory for analysis")
                        return
                    }
                    eligibility = try await Task.detached(priority: .utility) {
                        try SceneBakeEligibilityAnalyzer.analyze(contentRoot: contentRoot, intent: .desktopLoop, strict: false)
                    }.value
                    guard generation == companionBakeGeneration else {
                        print("[SceneOfflineBake] realtime companion bake stale (\(reason)): superseded after analysis")
                        return
                    }
                    if let itemID = record?.item.id {
                        await MainActor.run {
                            MediaLibraryService.shared.attachSceneBakeEligibility(
                                itemID: itemID,
                                snapshot: eligibility,
                                triggerAutoBake: false
                            )
                        }
                    }
                }

                guard generation == companionBakeGeneration else { return }
                let itemID = record?.item.id
                let displayTitle = record?.item.title
                let cacheItemID = itemID ?? stableOrphanCacheItemID(contentRootPath: contentRoot.path)
                let artifact = try await bake(
                    eligibility: eligibility,
                    contentRoot: contentRoot,
                    cacheItemID: cacheItemID,
                    renderer: .wallpaperWgpu,
                    persistArtifactToItemID: itemID,
                    progressItemID: itemID,
                    displayTitle: displayTitle,
                    isCompanion: true,
                    companionGeneration: generation
                )
                guard generation == companionBakeGeneration else {
                    print("[SceneOfflineBake] realtime companion bake stale (\(reason)): superseded after bake")
                    return
                }
                print("[SceneOfflineBake] realtime companion bake finished (\(reason)): \(artifact.videoPath)")
                await syncRealtimeBakeToLockScreen(
                    artifact: artifact,
                    itemID: itemID,
                    displayIDs: displayIDs,
                    reason: reason,
                    generation: generation
                )
            } catch {
                print("[SceneOfflineBake] realtime companion bake failed (\(reason)): \(error.localizedDescription)")
            }
        }
    }

    /// 自动烘焙关闭时的 Scene 静帧兜底。
    ///
    /// 临时 MP4 仅用于给 `AVAssetImageGenerator` 提供抽帧源：不会进入 SceneBakes、
    /// 不写 `sceneBakeArtifact`、不持久化任务，也不会进入视频优化队列。
    @MainActor
    private static func generateTransientRealtimePosters(
        contentRoot: URL,
        record: MediaDownloadRecord?,
        targets: [RealtimePosterTarget],
        reason: String,
        generation: UInt
    ) async {
        guard generation == companionBakeGeneration else { return }
        // 抽帧缓存也供详情页/媒体库使用，与是否需要把静帧写回系统桌面无关。
        // `syncRealtimeStaticPoster` 会在系统壁纸同步关闭时自行跳过桌面写入。
        guard !targets.isEmpty else {
            print("[SceneOfflineBake] transient poster skipped (\(reason)): no target display geometry")
            return
        }

        let itemID = record?.item.id
        let posterCacheID = itemID ?? stableOrphanCacheItemID(contentRootPath: contentRoot.path)

        let eligibility: SceneBakeEligibilitySnapshot
        if let existing = record?.sceneBakeEligibility,
           SceneBakeEligibilityAnalyzer.isSameContentRoot(existing.contentRootPath, contentRoot.path) {
            eligibility = existing
        } else {
            guard SystemMemoryPressure.hasRoomForSceneEligibilityAnalysis() else {
                print("[SceneOfflineBake] transient poster skipped (\(reason)): insufficient memory for analysis")
                return
            }
            do {
                eligibility = try await Task.detached(priority: .utility) {
                    try SceneBakeEligibilityAnalyzer.analyze(
                        contentRoot: contentRoot,
                        intent: .desktopLoop,
                        strict: false
                    )
                }.value
            } catch {
                print("[SceneOfflineBake] transient poster analysis failed (\(reason)): \(error.localizedDescription)")
                return
            }

            guard generation == companionBakeGeneration else { return }
            if let itemID {
                MediaLibraryService.shared.attachSceneBakeEligibility(
                    itemID: itemID,
                    snapshot: eligibility,
                    triggerAutoBake: false
                )
            }
        }

        let groupedTargets = Dictionary(grouping: targets, by: \.size)
        let orderedSizes = groupedTargets.keys.sorted {
            if $0.width != $1.width { return $0.width < $1.width }
            return $0.height < $1.height
        }
        let primarySize = targets.first?.size
        var postersBySize: [WallpaperPosterPixelSize: URL] = [:]
        var missingSizes: [WallpaperPosterPixelSize] = []

        for size in orderedSizes {
            guard generation == companionBakeGeneration else { return }
            let variantKey = realtimePosterVariantKey(eligibility: eligibility, size: size)
            if let cachedPoster = VideoThumbnailCache.shared
                .cachedSceneRealtimePosterFileURLIfExists(
                    itemID: posterCacheID,
                    variantKey: variantKey
                ) {
                postersBySize[size] = cachedPoster
                await syncRealtimeStaticPoster(
                    cachedPoster,
                    displayIDs: groupedTargets[size, default: []].map(\.displayID),
                    reason: "\(reason), cached \(size.width)x\(size.height) transient poster",
                    generation: generation
                )
            } else {
                missingSizes.append(size)
            }
        }

        if !missingSizes.isEmpty {
            let userProperties = SceneConfigOverrideService.mergedPropertiesJSON(
                userPropertiesJSON: SceneWallpaperPropertiesService.propertiesOverrideJSON(
                    for: contentRoot.path
                ),
                for: contentRoot.path
            )
            let jobID = UUID()
            await OfflineBakeSerialQueue.shared.waitForTurn(jobID: jobID)

            guard generation == companionBakeGeneration else {
                await OfflineBakeSerialQueue.shared.leave(jobID: jobID)
                return
            }

            for size in missingSizes {
                guard generation == companionBakeGeneration else {
                    await OfflineBakeSerialQueue.shared.leave(jobID: jobID)
                    return
                }
                let variantKey = realtimePosterVariantKey(eligibility: eligibility, size: size)
                let displayIDs = groupedTargets[size, default: []].map(\.displayID)

                // 在等待 GPU 队列期间，另一个同场景请求可能已经写好了同尺寸 poster。
                if let cachedPoster = VideoThumbnailCache.shared
                    .cachedSceneRealtimePosterFileURLIfExists(
                        itemID: posterCacheID,
                        variantKey: variantKey
                    ) {
                    postersBySize[size] = cachedPoster
                    await syncRealtimeStaticPoster(
                        cachedPoster,
                        displayIDs: displayIDs,
                        reason: "\(reason), shared \(size.width)x\(size.height) transient poster",
                        generation: generation
                    )
                    continue
                }

                guard let posterURL = await bakeTransientRealtimePoster(
                    contentRoot: contentRoot,
                    eligibility: eligibility,
                    posterCacheID: posterCacheID,
                    variantKey: variantKey,
                    size: size,
                    userProperties: userProperties,
                    reason: reason,
                    generation: generation
                ) else {
                    continue
                }

                guard generation == companionBakeGeneration else {
                    await OfflineBakeSerialQueue.shared.leave(jobID: jobID)
                    return
                }
                postersBySize[size] = posterURL
                await syncRealtimeStaticPoster(
                    posterURL,
                    displayIDs: displayIDs,
                    reason: "\(reason), temporary 1s bake \(size.width)x\(size.height)",
                    generation: generation
                )
                print(
                    "[SceneOfflineBake] transient poster finished (\(reason)) "
                        + "size=\(size.width)x\(size.height): \(posterURL.path)"
                )
            }

            await OfflineBakeSerialQueue.shared.leave(jobID: jobID)
        }

        guard generation == companionBakeGeneration else { return }
        if let itemID,
           let primarySize,
           let primaryPoster = postersBySize[primarySize] {
            // 同路径覆盖写入后必须清 Kingfisher 缓存，否则详情页/列表继续命中旧帧。
            let processor = DownsamplingImageProcessor(size: CGSize(width: 512, height: 512))
            try? await ImageCache.default.removeImage(forKey: primaryPoster.cacheKey)
            try? await ImageCache.default.removeImage(
                forKey: primaryPoster.cacheKey,
                processorIdentifier: processor.identifier
            )
            NotificationCenter.default.post(
                name: .sceneOfflineBakeThumbnailDidUpdate,
                object: itemID,
                userInfo: ["thumbnailURL": primaryPoster]
            )
        }
    }

    @MainActor
    private static func bakeTransientRealtimePoster(
        contentRoot: URL,
        eligibility: SceneBakeEligibilitySnapshot,
        posterCacheID: String,
        variantKey: String,
        size: WallpaperPosterPixelSize,
        userProperties: String?,
        reason: String,
        generation: UInt
    ) async -> URL? {
        guard generation == companionBakeGeneration else { return nil }
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WaifuX", isDirectory: true)
            .appendingPathComponent("TransientScenePosters", isDirectory: true)
        let temporaryVideoURL = temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mp4")
        let temporarySidecarURL = temporaryVideoURL
            .deletingPathExtension()
            .appendingPathExtension("json")
        do {
            try FileManager.default.createDirectory(
                at: temporaryDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            print("[SceneOfflineBake] transient poster setup failed (\(reason)): \(error.localizedDescription)")
            return nil
        }
        defer {
            try? FileManager.default.removeItem(at: temporaryVideoURL)
            try? FileManager.default.removeItem(at: temporarySidecarURL)
        }

        let artifact: SceneBakeArtifact
        do {
            artifact = try await bakeWithWallpaperWgpu(
                contentRoot: contentRoot,
                outURL: temporaryVideoURL,
                eligibility: eligibility,
                width: size.width,
                height: size.height,
                fps: min(resolvedBakeFPS(requestedFPS: nil), 30),
                durationSeconds: 1,
                userProperties: userProperties,
                progress: nil,
                isCompanion: true,
                companionGeneration: generation
            )
        } catch {
            print(
                "[SceneOfflineBake] transient poster bake failed (\(reason)) "
                    + "size=\(size.width)x\(size.height): \(error.localizedDescription)"
            )
            return nil
        }

        guard generation == companionBakeGeneration else { return nil }
        let videoURL = URL(fileURLWithPath: artifact.videoPath)
        guard isUsableBakedVideo(at: videoURL),
              let posterURL = await VideoThumbnailCache.shared.sceneRealtimePosterJPEGFileURL(
                  forLocalVideo: videoURL,
                  itemID: posterCacheID,
                  variantKey: variantKey,
                  targetWidth: size.width,
                  targetHeight: size.height
              ) else {
            print(
                "[SceneOfflineBake] transient poster extraction failed (\(reason)) "
                    + "size=\(size.width)x\(size.height): \(temporaryVideoURL.path)"
            )
            return nil
        }
        return posterURL
    }

    @MainActor
    private static func syncRealtimeBakeToLockScreen(
        artifact: SceneBakeArtifact,
        itemID: String?,
        displayIDs: [UInt32],
        reason: String,
        generation: UInt? = nil
    ) async {
        guard generation.map({ $0 == companionBakeGeneration }) ?? true else { return }
        let videoURL = URL(fileURLWithPath: artifact.videoPath)
        guard isUsableBakedVideo(at: videoURL) else { return }

        if #available(macOS 26.0, *), VideoWallpaperManager.shared.isLockScreenEnabled {
            // 动态锁屏开启：推送烘焙视频到锁屏实例
            guard !displayIDs.isEmpty else { return }
            let videoID = itemID ?? URL(fileURLWithPath: artifact.videoPath).deletingPathExtension().lastPathComponent
            await LockScreenWallpaperService.shared.switchActiveInstancesToLocalDecode(
                videoURL: videoURL,
                videoID: videoID,
                displayIDs: displayIDs
            )
            guard generation.map({ $0 == companionBakeGeneration }) ?? true else { return }
            print("[SceneOfflineBake] realtime companion bake synced lock screen (\(reason)): display=\(displayIDs) video=\(videoID)")
        } else {
            guard let posterURL = await VideoThumbnailCache.shared.lockScreenPosterURL(
                forLocalVideo: videoURL,
                fallbackPosterURL: nil
            ) else {
                print("[SceneOfflineBake] realtime companion bake could not generate desktop poster (\(reason)): \(videoURL.path)")
                return
            }
            guard generation.map({ $0 == companionBakeGeneration }) ?? true else { return }
            await syncRealtimeStaticPoster(
                posterURL,
                displayIDs: displayIDs,
                reason: reason,
                generation: generation
            )
        }
    }

    /// 将已抽出的静帧推送到当前可用的静态承载层。
    ///
    /// 动态锁屏开启时使用静态图片源，避免短暂的 1 秒 MP4 被删除后仍被扩展引用。
    @MainActor
    private static func syncRealtimeStaticPoster(
        _ posterURL: URL,
        displayIDs: [UInt32],
        reason: String,
        generation: UInt? = nil
    ) async {
        guard generation.map({ $0 == companionBakeGeneration }) ?? true else { return }
        if #available(macOS 26.0, *), VideoWallpaperManager.shared.isLockScreenEnabled {
            guard !displayIDs.isEmpty else {
                print("[SceneOfflineBake] static poster skipped (\(reason)): no lock-screen display IDs")
                return
            }
            do {
                try await LockScreenWallpaperService.shared.cacheStaticImageSource(
                    imageURL: posterURL,
                    displayIDs: displayIDs
                )
                guard generation.map({ $0 == companionBakeGeneration }) ?? true else { return }
                print("[SceneOfflineBake] set lock-screen static poster (\(reason)): display=\(displayIDs) poster=\(posterURL.path)")
            } catch {
                print("[SceneOfflineBake] failed to set lock-screen static poster (\(reason)): \(error.localizedDescription)")
            }
            return
        }

        // 系统壁纸同步关闭时桌面由实时 scene 渲染，不得偷偷改系统壁纸。
        guard VideoWallpaperManager.shared.isSystemWallpaperSyncEnabled else {
            print("[SceneOfflineBake] system wallpaper sync disabled; skipped static poster (\(reason))")
            return
        }

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
        guard !targetScreens.isEmpty else {
            print("[SceneOfflineBake] static poster has no matching display (\(reason)): display=\(displayIDs)")
            return
        }

        let fillOptions: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSNumber(value: NSImageScaling.scaleProportionallyUpOrDown.rawValue),
            .allowClipping: true
        ]
        var appliedScreens = 0
        var appliedTargetScreens: [NSScreen] = []
        for screen in targetScreens {
            do {
                try NSWorkspace.shared.setDesktopImageURLForAllSpaces(posterURL, for: screen, options: fillOptions)
                DesktopWallpaperSyncManager.shared.registerWallpaperSet(posterURL, for: screen, options: fillOptions)
                appliedScreens += 1
                appliedTargetScreens.append(screen)
            } catch {
                print("[SceneOfflineBake] failed to set desktop poster (\(reason)) on \(screen.localizedName): \(error.localizedDescription)")
            }
        }
        print("[SceneOfflineBake] set desktop static poster (\(reason)) on \(appliedScreens)/\(targetScreens.count) screen(s) display=\(displayIDs): \(posterURL.path)")
        if !appliedTargetScreens.isEmpty {
            // Scene 窗口在 wgpu 进程（宿主无法 orderOut）：暂无可靠的菜单栏
            // 重采样触发手段（Finder update / 通知 / 私有 API 均已实测无效）。
            // 菜单栏 backdrop 有 ~10s 懒重采样兜底，或用户切换 App 时自然更新。
        }
    }

    @MainActor
    static func isRendererAvailable(_ renderer: SceneBakeRenderer) -> Bool {
        switch renderer {
        case .wallpaperWgpu:
            return WallpaperEngineXBridge.resolvedCLIExecutableURL() != nil
        case .wallpaperEngineWeb:
            return WallpaperEngineXBridge.resolvedLegacyCLIExecutableURL() != nil
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
        case .wallpaperEngineWeb:
            throw SceneOfflineBakeError.ineligible
        }
    }

    /// 缓存文件路径：`analysisId + 可选标题 + 分辨率 + fps + 时长`
    ///（根目录为 `DownloadPathManager.sceneBakesFolderURL`）。
    ///
    /// **当前 Scene 格式（无 renderer 段）：**
    /// `{UUID}[_title]_{WxH}_{fps}fps_{duration}s.mp4`
    ///
    /// 历史格式仍可通过 `legacyCacheCandidateURLs` 命中并迁移：
    /// - `{UUID}_wallpaperWgpu_{WxH}_…`
    /// - `{UUID}_{title}_wallpaperWgpu_{WxH}_…`
    private static func cacheVideoURL(
        baseDir: URL,
        itemID: String,
        analysisId: UUID,
        renderer: SceneBakeRenderer,
        width: Int,
        height: Int,
        fps: Int,
        durationSeconds: Double,
        displayTitle: String?
    ) -> URL {
        let dir = bakeDirectory(baseDir: baseDir, itemID: itemID)
        let titleSegment = sanitizedBakeFileTitle(displayTitle).map { "_\($0)" } ?? ""
        // Scene 成片不再写入 wallpaperWgpu 段；Web 走 WebOfflineBakeService 自己的命名。
        let name: String
        switch renderer {
        case .wallpaperWgpu:
            name =
                "\(analysisId.uuidString)\(titleSegment)_\(width)x\(height)_\(fps)fps_\(Int(durationSeconds))s.mp4"
        case .wallpaperEngineWeb:
            name =
                "\(analysisId.uuidString)\(titleSegment)_\(renderer.rawValue)_\(width)x\(height)_\(fps)fps_\(Int(durationSeconds))s.mp4"
        }
        return dir.appendingPathComponent(name)
    }

    private static func bakeDirectory(baseDir: URL, itemID: String) -> URL {
        let safeID = itemID.replacingOccurrences(of: "/", with: "_")
        return baseDir.appendingPathComponent(safeID, isDirectory: true)
    }

    /// 历史 Scene 文件名候选（含 renderer 段、属性哈希或无标题段），用于 cache hit / 迁移。
    private static func legacyCacheCandidateURLs(
        baseDir: URL,
        itemID: String,
        analysisId: UUID,
        renderer: SceneBakeRenderer,
        width: Int,
        height: Int,
        fps: Int,
        durationSeconds: Double,
        propertiesCacheKey: String?,
        displayTitle: String?
    ) -> [URL] {
        guard renderer == .wallpaperWgpu else { return [] }
        let dir = bakeDirectory(baseDir: baseDir, itemID: itemID)
        let propertiesSuffix = propertiesCacheKey.map { "_props-\($0)" } ?? ""
        let legacyDims = "\(width)x\(height)_\(fps)fps_\(Int(durationSeconds))s\(propertiesSuffix).mp4"
        let uuid = analysisId.uuidString
        let title = sanitizedBakeFileTitle(displayTitle)
        var names: [String] = []
        // 上一版当前格式：带标题、无 renderer、带属性哈希。
        if let title {
            names.append("\(uuid)_\(title)_\(legacyDims)")
        }
        // 上一版：带标题 + wallpaperWgpu
        if let title {
            names.append("\(uuid)_\(title)_wallpaperWgpu_\(legacyDims)")
        }
        // 最早：无标题 + wallpaperWgpu
        names.append("\(uuid)_wallpaperWgpu_\(legacyDims)")
        // 无标题、无 renderer、带属性哈希。
        names.append("\(uuid)_\(legacyDims)")
        // 带标题但无 wallpaperWgpu 已是当前 canonical，不在 legacy 列表里

        var seen = Set<String>()
        return names.compactMap { name in
            guard seen.insert(name).inserted else { return nil }
            return dir.appendingPathComponent(name)
        }
    }

    /// 是否像 bake 产物文件名（新旧格式均认）。恢复扫描 / 清理时用。
    static func looksLikeBakeProductFilename(_ name: String) -> Bool {
        if name.contains("_wallpaperWgpu_")
            || name.contains("_wallpaperEngineWeb_")
            || name.hasPrefix("web_v") {
            return true
        }
        // 新 Scene 格式：UUID 开头 + `{W}x{H}_{fps}fps_{duration}s`
        guard parseLeadingAnalysisId(from: name) != nil else { return false }
        return name.range(of: #"_\d+x\d+_\d+fps_\d+s"#, options: .regularExpression) != nil
    }

    /// 从 bake 文件名解析前缀 UUID（兼容 `UUID_…` 与纯 UUID 段）。
    static func parseLeadingAnalysisId(from name: String) -> UUID? {
        let stem = (name as NSString).deletingPathExtension
        // UUID 标准串 36 字符（含连字符）
        let prefix = String(stem.prefix(36))
        if prefix.count == 36, UUID(uuidString: prefix) != nil {
            // 确保第 37 字符是分隔或结束，避免误吃
            if stem.count == 36 { return UUID(uuidString: prefix) }
            let next = stem[stem.index(stem.startIndex, offsetBy: 36)]
            if next == "_" { return UUID(uuidString: prefix) }
        }
        let head = stem.split(separator: "_", maxSplits: 1, omittingEmptySubsequences: true).first
            .map(String.init) ?? ""
        return UUID(uuidString: head)
    }

    /// 文件名安全标题：保留中英文与数字，空白/非法字符压成 `_`，限制长度。
    static func sanitizedBakeFileTitle(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var result = ""
        result.reserveCapacity(min(trimmed.count, 48))
        var lastWasSeparator = false
        for scalar in trimmed.unicodeScalars {
            let isAllowed =
                CharacterSet.alphanumerics.contains(scalar)
                || scalar == "_"
                || scalar == "-"
                || (scalar.value >= 0x4E00 && scalar.value <= 0x9FFF) // CJK Unified
                || (scalar.value >= 0x3400 && scalar.value <= 0x4DBF) // CJK Extension A
                || (scalar.value >= 0x3040 && scalar.value <= 0x30FF) // Hiragana/Katakana
                || (scalar.value >= 0xAC00 && scalar.value <= 0xD7AF) // Hangul
            if isAllowed {
                result.unicodeScalars.append(scalar)
                lastWasSeparator = false
            } else if !lastWasSeparator {
                result.append("_")
                lastWasSeparator = true
            }
            if result.count >= 48 { break }
        }
        while result.hasPrefix("_") { result.removeFirst() }
        while result.hasSuffix("_") { result.removeLast() }
        return result.isEmpty ? nil : result
    }

    /// 从媒体库记录解析展示标题（须在主线程调用）。
    @MainActor
    static func resolveBakeDisplayTitle(contentRoot: URL, itemID: String?) -> String? {
        if let itemID,
           let title = MediaLibraryService.shared.downloadedItems
            .first(where: { $0.item.id == itemID && $0.isActive })?
            .item.title
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title
        }
        return projectTitle(at: contentRoot)
    }

    /// 仅读 `project.json`，可在任意线程调用。
    static func projectTitle(at contentRoot: URL) -> String? {
        let projectURL = contentRoot.appendingPathComponent("project.json")
        guard let data = try? Data(contentsOf: projectURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        for key in ["title", "name"] {
            if let value = json[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    /// 新产物落地后清理同 item 目录下其它 bake mp4 / bake sidecar，避免堆出「两组一样」的文件。
    /// 优化履历已迁出媒体目录（Application Support），这里只顺带扫掉历史遗留的
    /// `.waifux-optimization.json` 旁路文件。
    static func cleanupStaleBakeFiles(
        inDirectory directory: URL,
        keeping keptURL: URL
    ) {
        let fm = FileManager.default
        let keptPath = keptURL.standardizedFileURL.path
        let keptStem = keptURL.deletingPathExtension().lastPathComponent
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for url in entries {
            let path = url.standardizedFileURL.path
            if path == keptPath { continue }

            let name = url.lastPathComponent
            // 与当前成片配套的 bake sidecar 保留；optimization 履历不再写在媒体旁
            if name == "\(keptStem).json" { continue }

            // 历史遗留：媒体旁的 optimization 元数据一律清掉（新路径在 App Support）
            if name.hasSuffix(".waifux-optimization.json") {
                try? fm.removeItem(at: url)
                print("[SceneOfflineBake] cleaned legacy optimization sidecar: \(name)")
                continue
            }

            guard looksLikeBakeProductFilename(name) else { continue }

            let ext = url.pathExtension.lowercased()
            let isVideo = ext == "mp4"
            let isSidecar = ext == "json"
            guard isVideo || isSidecar else { continue }

            // 旧 bake 成片被替换时，同步丢掉其 App Support 履历，避免孤儿记录
            if isVideo {
                Task { @MainActor in
                    VideoOptimizationRecordStore.shared.reset(for: url)
                }
            }

            do {
                try fm.removeItem(at: url)
                print("[SceneOfflineBake] cleaned stale bake file: \(name)")
            } catch {
                print("[SceneOfflineBake] failed to clean stale bake file \(name): \(error.localizedDescription)")
            }
        }
    }

    /// 设计面板属性会改变输出画面，必须参与缓存区分。
    private static func propertiesCacheKey(for userProperties: String?) -> String? {
        guard let userProperties,
              !userProperties.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let data: Data
        if let source = userProperties.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: source),
           let canonical = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
            data = canonical
        } else {
            data = Data(userProperties.utf8)
        }
        return SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
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
    /// - Parameter progressItemID: 用于跨详情页恢复的进度追踪 item id；默认取 `persistArtifactToItemID`。
    /// - Parameter displayTitle: 写入缓存文件名的壁纸标题；nil 时尝试从库/project.json 解析。
    static func bake(
        eligibility: SceneBakeEligibilitySnapshot,
        contentRoot: URL,
        cacheItemID: String,
        durationSeconds: Double? = nil,
        fps: Int32? = nil,
        renderer: SceneBakeRenderer = .wallpaperWgpu,
        persistArtifactToItemID: String? = nil,
        progressItemID: String? = nil,
        resumingJobID: UUID? = nil,
        displayTitle: String? = nil,
        isCompanion: Bool = false,
        companionGeneration: UInt? = nil,
        progress: (@MainActor (Double) -> Void)? = nil
    ) async throws -> SceneBakeArtifact {
        let effectiveFPS = resolvedBakeFPS(requestedFPS: fps)
        let effectiveDuration: Double
        if let durationSeconds {
            effectiveDuration = durationSeconds
        } else {
            let saved = UserDefaults.standard.double(forKey: "scene_bake_duration")
            effectiveDuration = saved >= 5 ? min(max(saved, 5), 60) : 15
        }
        let trackedItemID = progressItemID ?? persistArtifactToItemID
        let resolvedTitle = await MainActor.run {
            displayTitle ?? resolveBakeDisplayTitle(
                contentRoot: contentRoot,
                itemID: trackedItemID ?? persistArtifactToItemID
            )
        }
        let persistentJob = PersistentOfflineBakeJob.scene(
            id: resumingJobID ?? UUID(),
            eligibility: eligibility,
            contentRoot: contentRoot,
            cacheItemID: cacheItemID,
            durationSeconds: effectiveDuration,
            fps: effectiveFPS,
            renderer: renderer,
            persistArtifactToItemID: persistArtifactToItemID,
            progressItemID: trackedItemID,
            isCompanion: isCompanion
        )
        let enqueueResult = await MainActor.run {
            SceneOfflineBakeProgressTracker.shared.enqueue(
                job: persistentJob,
                resumingJobID: resumingJobID
            )
        }
        guard enqueueResult.shouldExecute else {
            throw SceneOfflineBakeError.concurrentBakeInProgress
        }
        let jobID = enqueueResult.jobID

        await OfflineBakeSerialQueue.shared.waitForTurn(jobID: jobID)
        guard companionGeneration.map({ $0 == companionBakeGeneration }) ?? true else {
            await MainActor.run {
                SceneOfflineBakeProgressTracker.shared.finish(jobID: jobID, success: false)
            }
            await OfflineBakeSerialQueue.shared.leave(jobID: jobID)
            throw CancellationError()
        }
        await MainActor.run {
            SceneOfflineBakeProgressTracker.shared.begin(jobID: jobID)
        }
        let trackedProgress: (@MainActor (Double) -> Void)? = { value in
            SceneOfflineBakeProgressTracker.shared.update(jobID: jobID, progress: value)
            progress?(value)
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
                displayTitle: resolvedTitle,
                isCompanion: isCompanion,
                companionGeneration: companionGeneration,
                progress: trackedProgress
            )
            guard companionGeneration.map({ $0 == companionBakeGeneration }) ?? true else {
                throw CancellationError()
            }
            await MainActor.run {
                SceneOfflineBakeProgressTracker.shared.finish(jobID: jobID, success: true)
                let bakedURL = URL(fileURLWithPath: result.videoPath)
                let title = persistArtifactToItemID.flatMap {
                    MediaLibraryService.shared.downloadRecord(for: $0)?.item.title
                } ?? bakedURL.deletingPathExtension().lastPathComponent
                VideoOptimizationQueueService.shared.registerBakedSource(
                    videoURL: bakedURL,
                    sourcePath: contentRoot.path,
                    artifact: result
                )
                _ = VideoOptimizationQueueService.shared.enqueueAfterBakeIfNeeded(
                    videoURL: bakedURL,
                    title: title
                )
                NotificationCenter.default.post(name: .sceneOfflineBakeDidComplete, object: result)
            }
            await OfflineBakeSerialQueue.shared.leave(jobID: jobID)
            return result
        } catch {
            await MainActor.run {
                SceneOfflineBakeProgressTracker.shared.finish(jobID: jobID, success: false)
                NotificationCenter.default.post(name: .sceneOfflineBakeDidComplete, object: nil)
            }
            await OfflineBakeSerialQueue.shared.leave(jobID: jobID)
            throw error
        }
    }

    /// Re-enqueues unfinished checkpoint entries after relaunch. The original
    /// UUID is reused so recovery does not create a second visible queue item.
    @MainActor
    static func resumePersistedBakeQueue() async {
        let jobs = SceneOfflineBakeProgressTracker.shared.pendingPersistentJobs
        guard !jobs.isEmpty else { return }

        for job in jobs {
            switch job.kind {
            case .scene:
                guard let eligibility = job.eligibility,
                      let cacheItemID = job.cacheItemID else {
                    SceneOfflineBakeProgressTracker.shared.discardPersistedJob(
                        id: job.id,
                        reason: "scene checkpoint is incomplete"
                    )
                    continue
                }
                do {
                    let isCompanion = job.isCompanion ?? false
                    _ = try await bake(
                        eligibility: eligibility,
                        contentRoot: URL(fileURLWithPath: job.contentRootPath),
                        cacheItemID: cacheItemID,
                        durationSeconds: job.durationSeconds,
                        fps: Int32(job.fps),
                        renderer: job.renderer,
                        persistArtifactToItemID: job.persistArtifactToItemID,
                        progressItemID: job.progressItemID,
                        resumingJobID: job.id,
                        isCompanion: isCompanion,
                        companionGeneration: isCompanion ? companionBakeGeneration : nil
                    )
                } catch {
                    SceneOfflineBakeProgressTracker.shared.discardPersistedJob(
                        id: job.id,
                        reason: error.localizedDescription
                    )
                    print("[OfflineBakeQueue] restored scene bake failed: \(error.localizedDescription)")
                }

            case .web:
                do {
                    _ = try await WebOfflineBakeService.resumePersistedBakeJob(job)
                } catch {
                    SceneOfflineBakeProgressTracker.shared.discardPersistedJob(
                        id: job.id,
                        reason: error.localizedDescription
                    )
                    print("[OfflineBakeQueue] restored web bake failed: \(error.localizedDescription)")
                }
            }
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
        displayTitle: String?,
        isCompanion: Bool,
        companionGeneration: UInt?,
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
        let effectiveUserProperties = await MainActor.run {
            SceneConfigOverrideService.mergedPropertiesJSON(
                userPropertiesJSON: SceneWallpaperPropertiesService.propertiesOverrideJSON(for: contentRoot.path),
                for: contentRoot.path
            )
        }

        let sceneBakesRoot = await MainActor.run {
            DownloadPathManager.shared.sceneBakesFolderURL
        }
        let cacheDurationSeconds = durationSeconds
        // displayTitle 已在 bake() 主线程解析；此处仅回退 project.json，避免碰 @MainActor 媒体库
        let titleForName = displayTitle ?? projectTitle(at: contentRoot)
        let outURL = cacheVideoURL(
            baseDir: sceneBakesRoot,
            itemID: cacheItemID,
            analysisId: eligibility.analysisId,
            renderer: renderer,
            width: evenW,
            height: evenH,
            fps: Int(fps),
            durationSeconds: cacheDurationSeconds,
            displayTitle: titleForName
        )

        try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        // 兼容历史命名（含 `_wallpaperWgpu_` / 无标题段）：命中后迁移到当前规范名，不重烘。
        let legacyCandidates = legacyCacheCandidateURLs(
            baseDir: sceneBakesRoot,
            itemID: cacheItemID,
            analysisId: eligibility.analysisId,
            renderer: renderer,
            width: evenW,
            height: evenH,
            fps: Int(fps),
            durationSeconds: cacheDurationSeconds,
            propertiesCacheKey: propertiesCacheKey(for: effectiveUserProperties),
            displayTitle: titleForName
        ).filter { $0.path != outURL.path }

        let cachedInspection: BakedVideoInspection? = await {
            switch renderer {
            case .wallpaperWgpu:
                if let hit = await inspectBakedVideo(at: outURL, expectedWidth: evenW, expectedHeight: evenH) {
                    return hit
                }
                for legacyOutURL in legacyCandidates {
                    guard let hit = await inspectBakedVideo(
                        at: legacyOutURL,
                        expectedWidth: evenW,
                        expectedHeight: evenH
                    ) else { continue }
                    try? FileManager.default.removeItem(at: outURL)
                    do {
                        try FileManager.default.moveItem(at: legacyOutURL, to: outURL)
                        let legacySidecar = legacyOutURL.deletingPathExtension().appendingPathExtension("json")
                        let newSidecar = outURL.deletingPathExtension().appendingPathExtension("json")
                        if FileManager.default.fileExists(atPath: legacySidecar.path) {
                            try? FileManager.default.removeItem(at: newSidecar)
                            try? FileManager.default.moveItem(at: legacySidecar, to: newSidecar)
                        }
                        // 优化履历在 Application Support，按视频路径哈希搬迁；
                        // 同时清掉历史写在媒体旁的 .waifux-optimization.json。
                        await MainActor.run {
                            VideoOptimizationRecordStore.shared.relocateRecord(
                                from: legacyOutURL,
                                to: outURL
                            )
                        }
                        print("[SceneOfflineBake] renamed legacy bake cache → \(outURL.lastPathComponent)")
                        return hit
                    } catch {
                        print("[SceneOfflineBake] legacy bake rename failed, using old path: \(error.localizedDescription)")
                        // 迁移失败仍复用旧文件路径（由 resolvedCacheURL 回落）
                        return hit
                    }
                }
                return nil
            case .wallpaperEngineWeb:
                return nil
            }
        }()

        let resolvedCacheURL: URL = {
            if FileManager.default.fileExists(atPath: outURL.path) {
                return outURL
            }
            for legacy in legacyCandidates where FileManager.default.fileExists(atPath: legacy.path) {
                return legacy
            }
            return outURL
        }()

        if let cachedInspection,
           let attrs = try? FileManager.default.attributesOfItem(atPath: resolvedCacheURL.path) {
            let artifact = SceneBakeArtifact(
                analysisId: eligibility.analysisId,
                videoPath: resolvedCacheURL.path,
                width: cachedInspection.width,
                height: cachedInspection.height,
                fps: Int(fps),
                durationSeconds: durationSeconds,
                bakedAt: (attrs[.creationDate] as? Date) ?? .now,
                renderer: renderer
            )
            guard companionGeneration.map({ $0 == companionBakeGeneration }) ?? true else {
                return artifact
            }
            cleanupStaleBakeFiles(inDirectory: resolvedCacheURL.deletingLastPathComponent(), keeping: resolvedCacheURL)
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
                userProperties: effectiveUserProperties,
                progress: progress,
                isCompanion: isCompanion,
                companionGeneration: companionGeneration
            )
        case .wallpaperEngineWeb:
            throw SceneOfflineBakeError.ineligible
        }
        guard companionGeneration.map({ $0 == companionBakeGeneration }) ?? true else {
            return artifact
        }
        cleanupStaleBakeFiles(inDirectory: outURL.deletingLastPathComponent(), keeping: outURL)
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
        userProperties: String?,
        progress: (@MainActor (Double) -> Void)?,
        isCompanion: Bool,
        companionGeneration: UInt?
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

        if let userProperties, !userProperties.isEmpty {
            args += ["--user-properties", userProperties]
        }

        // 自动检测周期时不需要传 --duration，让 bake 自己检测
        if durationSeconds > 0 {
            args += ["--duration", String(Int(durationSeconds))]
        }

        guard companionGeneration.map({ $0 == companionBakeGeneration }) ?? true else {
            throw CancellationError()
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
        let processID = process.processIdentifier
        await MainActor.run {
            SceneBakeProcessController.shared.attach(process: process, isCompanion: isCompanion)
        }
        guard companionGeneration.map({ $0 == companionBakeGeneration }) ?? true else {
            await MainActor.run {
                SceneBakeProcessController.shared.stop(pid: processID)
            }
            throw CancellationError()
        }
        defer {
            Task { @MainActor in
                SceneBakeProcessController.shared.finish(pid: processID)
            }
        }

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
            if Task.isCancelled {
                await MainActor.run {
                    SceneBakeProcessController.shared.stop(pid: processID)
                }
                break
            }
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                continue
            }
        }
        await progressTask.value
        await stdoutTask.value
        stderrCapture.close()
        await MainActor.run {
            SceneBakeProcessController.shared.finish(pid: processID)
        }

        guard companionGeneration.map({ $0 == companionBakeGeneration }) ?? true else {
            try? FileManager.default.removeItem(at: tempURL)
            throw CancellationError()
        }
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

    /// 检查是否有缓存（不触发实际烘焙）
    static func hasCachedArtifact(record: MediaDownloadRecord, renderer: SceneBakeRenderer? = nil) -> Bool {
        guard let art = usableArtifact(from: record) else { return false }
        if let renderer {
            return art.renderer == renderer
        }
        return true
    }

    /// 优先使用 `MediaDownloadRecord.sceneBakeEligibility`；缺失时在实际烘焙前现场分析。
    /// 默认主屏逻辑分辨率 × scale。
    /// FPS 默认值取自用户设置 `scene_bake_fps`（回退 30），且不超过显示器最高刷新率。
    static func bake(
        record: MediaDownloadRecord,
        durationSeconds: Double? = nil,
        fps: Int32? = nil,
        renderer: SceneBakeRenderer = .wallpaperWgpu,
        progress: (@MainActor (Double) -> Void)? = nil
    ) async throws -> SceneBakeArtifact {
        let effectiveFPS = resolvedBakeFPS(requestedFPS: fps)
        let effectiveDuration: Double
        if let durationSeconds {
            effectiveDuration = durationSeconds
        } else {
            let saved = UserDefaults.standard.double(forKey: "scene_bake_duration")
            effectiveDuration = saved >= 5 ? min(max(saved, 5), 60) : 15
        }
        let eligibility: SceneBakeEligibilitySnapshot
        let contentRoot: URL
        if let existing = record.sceneBakeEligibility {
            eligibility = existing
            contentRoot = URL(fileURLWithPath: existing.contentRootPath)
        } else {
            let resolvedRoot = WorkshopService.resolveWallpaperEngineProjectRoot(
                startingAt: record.localFileURL
            )
            guard SceneBakeEligibilityAnalyzer.sceneContentRootIfEligibleForAnalysis(
                localFileURL: resolvedRoot
            ) != nil else {
                throw SceneOfflineBakeError.ineligible
            }
            guard SystemMemoryPressure.hasRoomForSceneOfflineBake() else {
                throw SceneOfflineBakeError.insufficientMemory
            }

            eligibility = try await Task.detached(priority: .userInitiated) {
                try SceneBakeEligibilityAnalyzer.analyze(
                    contentRoot: resolvedRoot,
                    intent: .desktopLoop,
                    strict: false
                )
            }.value
            contentRoot = resolvedRoot

            await MainActor.run {
                MediaLibraryService.shared.attachSceneBakeEligibility(
                    itemID: record.item.id,
                    snapshot: eligibility,
                    triggerAutoBake: false
                )
            }
        }
        return try await bake(
            eligibility: eligibility,
            contentRoot: contentRoot,
            cacheItemID: record.id,
            durationSeconds: effectiveDuration,
            fps: effectiveFPS,
            renderer: renderer,
            persistArtifactToItemID: record.id,
            progressItemID: record.item.id,
            displayTitle: record.item.title,
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
            if let art = record.sceneBakeArtifact,
               art.analysisId == eligibility.analysisId,
               (art.renderer == nil || art.renderer == .wallpaperWgpu),
               isUsableBakedVideo(at: URL(fileURLWithPath: art.videoPath)) {
                return
            }
            do {
                // 进度由 SceneOfflineBakeProgressTracker 统一广播
                _ = try await bake(record: record)
                print("[SceneOfflineBake] auto-bake finished \(itemID)")
            } catch {
                print("[SceneOfflineBake] auto-bake failed \(itemID): \(error.localizedDescription)")
            }
        }
    }

    /// Lightweight, main-thread-safe gate: file exists and is non-trivial.
    /// Avoids AVAsset + semaphore on the main actor (that path deadlocked /
    /// starved set-wallpaper when a bake product was present).
    static func isUsableBakedVideo(at url: URL) -> Bool {
        guard url.isFileURL,
              FileManager.default.fileExists(atPath: url.path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber,
              size.int64Value > 10_000 else {
            return false
        }
        return true
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
        guard isUsableBakedVideo(at: url) else { return nil }

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
}
