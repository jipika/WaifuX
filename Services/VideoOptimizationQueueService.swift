import Foundation
import AVFoundation
import AppKit
import CryptoKit
import CoreGraphics
import CoreVideo
import VideoToolbox
import Vision
import Combine

extension Notification.Name {
    /// 视频优化原地替换文件后发出；播放器决定该文件是否仍是当前壁纸。
    static let videoOptimizationFileDidReplace = Notification.Name("videoOptimizationFileDidReplace")
}

enum VideoOptimizationFileReplacementKind: String {
    case loopPreprocessing
    case frameInterpolation

    static let userInfoKey = "videoOptimizationFileReplacementKind"
}

enum VideoOptimizationOutputContainer: String, Sendable {
    case mp4
    case mov
    case m4v

    init?(sourceURL: URL) {
        self.init(rawValue: sourceURL.pathExtension.lowercased())
    }

    var fileType: AVFileType {
        switch self {
        case .mp4:
            return .mp4
        case .mov:
            return .mov
        case .m4v:
            return .m4v
        }
    }

    var displayName: String {
        rawValue.uppercased()
    }

    func temporarySiblingURL(for sourceURL: URL, operation: String) -> URL {
        sourceURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".\(sourceURL.deletingPathExtension().lastPathComponent).waifux-\(operation)-\(UUID().uuidString)"
            )
            .appendingPathExtension(rawValue)
    }
}

enum VideoOptimizationFileReplacement {
    static func replaceSourceVideo(_ sourceURL: URL, with temporaryURL: URL) throws {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        guard sourceURL.deletingLastPathComponent().standardizedFileURL
            == temporaryURL.deletingLastPathComponent().standardizedFileURL else {
            throw CocoaError(.fileWriteInvalidFileName)
        }

        _ = try FileManager.default.replaceItemAt(
            sourceURL,
            withItemAt: temporaryURL,
            backupItemName: nil,
            options: []
        )
    }
}

private final class FrameInterpolationAudioCopyState: @unchecked Sendable {
    private let lock = NSLock()
    private var didFinish = false
    private var storedFailureMessage: String?

    func finish(failureMessage: String? = nil) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didFinish else { return false }
        didFinish = true
        storedFailureMessage = failureMessage
        return true
    }

    var failureMessage: String? {
        lock.lock()
        defer { lock.unlock() }
        return storedFailureMessage
    }
}

private final class FrameInterpolationAudioPassthrough: @unchecked Sendable {
    private let reader: AVAssetReader
    private let writer: AVAssetWriter
    private let output: AVAssetReaderTrackOutput
    private let input: AVAssetWriterInput
    private let state: FrameInterpolationAudioCopyState
    private let group: DispatchGroup

    init(
        reader: AVAssetReader,
        writer: AVAssetWriter,
        output: AVAssetReaderTrackOutput,
        input: AVAssetWriterInput,
        state: FrameInterpolationAudioCopyState,
        group: DispatchGroup
    ) {
        self.reader = reader
        self.writer = writer
        self.output = output
        self.input = input
        self.state = state
        self.group = group
    }

    func start(on queue: DispatchQueue) {
        group.enter()
        input.requestMediaDataWhenReady(on: queue) { [self] in
            drain()
        }
    }

    private func drain() {
        while input.isReadyForMoreMediaData {
            if reader.status == .failed || reader.status == .cancelled {
                finish(reader.error?.localizedDescription ?? "音频读取被取消")
                return
            }
            if writer.status == .failed || writer.status == .cancelled {
                finish(writer.error?.localizedDescription ?? "音频写入被取消")
                return
            }
            guard let sampleBuffer = output.copyNextSampleBuffer() else {
                finish()
                return
            }
            guard input.append(sampleBuffer) else {
                finish(writer.error?.localizedDescription ?? "音频 passthrough 写入失败")
                return
            }
        }
    }

    private func finish(_ failureMessage: String? = nil) {
        guard state.finish(failureMessage: failureMessage) else { return }
        input.markAsFinished()
        group.leave()
    }
}

#if DEBUG
private final class FrameInterpolationExporterTestHooks: @unchecked Sendable {
    private let lock = NSLock()
    private var sourceReplacementHook: (@Sendable () -> Void)?

    func setSourceReplacementHook(_ hook: (@Sendable () -> Void)?) {
        lock.lock()
        sourceReplacementHook = hook
        lock.unlock()
    }

    func runSourceReplacementHook() {
        lock.lock()
        let hook = sourceReplacementHook
        lock.unlock()
        hook?()
    }
}
#endif

struct VideoFrameInterpolationDecision: Sendable {
    let sourceFPS: Double?
    let targetFPS: Int
    let shouldInterpolate: Bool
    let reason: String
}

enum VideoFrameInterpolationAnalyzer {
    static func decision(for url: URL, targetFPS: Int) async -> VideoFrameInterpolationDecision {
        guard targetFPS > 0 else {
            return VideoFrameInterpolationDecision(sourceFPS: nil, targetFPS: targetFPS, shouldInterpolate: false, reason: "目标 FPS 无效")
        }

        guard let sourceFPS = await sourceFrameRate(for: url), sourceFPS > 0 else {
            return VideoFrameInterpolationDecision(sourceFPS: nil, targetFPS: targetFPS, shouldInterpolate: false, reason: "无法读取原始 FPS")
        }

        let shouldInterpolate = sourceFPS < Double(targetFPS)
        return VideoFrameInterpolationDecision(
            sourceFPS: sourceFPS,
            targetFPS: targetFPS,
            shouldInterpolate: shouldInterpolate,
            reason: shouldInterpolate ? "原始 FPS 低于目标 FPS" : "原始 FPS 已达到或高于目标 FPS"
        )
    }

    static func sourceFrameRate(for url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
            return nil
        }

        if let nominalFrameRate = try? await track.load(.nominalFrameRate),
           nominalFrameRate > 0 {
            return Double(nominalFrameRate)
        }

        if let minFrameDuration = try? await track.load(.minFrameDuration),
           minFrameDuration.isValid,
           minFrameDuration.seconds.isFinite,
           minFrameDuration.seconds > 0 {
            return 1.0 / minFrameDuration.seconds
        }

        return nil
    }
}

struct FrameInterpolationQueueItem: Identifiable, Equatable, Codable {
    enum Operation: String, CaseIterable, Codable, Hashable {
        // Keep the previous raw value so existing optimization history remains decodable.
        case loopTransition = "loopAnalysis"
        case frameInterpolation

        var label: String {
            switch self {
            case .loopTransition: return t("videoOptimizationGenerateLoopTransition")
            case .frameInterpolation: return t("videoOptimizationInterpolateVideo")
            }
        }
    }

    enum Status: Equatable, Codable {
        case waiting
        case analyzing
        case running
        case completed
        case failed(String)

        var label: String {
            switch self {
            case .waiting: return t("frameInterpolationStatusWaiting")
            case .analyzing: return t("frameInterpolationStatusAnalyzing")
            case .running: return t("frameInterpolationStatusRunning")
            case .completed: return t("frameInterpolationStatusCompleted")
            case .failed: return t("frameInterpolationStatusFailed")
            }
        }
    }

    enum Source: String, Codable {
        case automatic = "自动"
        case manual = "手动"
    }

    let id: UUID
    let videoURL: URL
    let title: String
    let targetFPS: Int
    let source: Source
    var operations: [Operation]
    var completedOperations: Set<Operation>
    var currentOperation: Operation?
    var sourceFPS: Double?
    var status: Status
    var progress: Double
    var writtenFrames: Int64
    var totalFrames: Int64?
    var opticalFlowFrames: Int64
    var elapsedSeconds: TimeInterval
    var remainingSeconds: TimeInterval?
    var currentStage: String
    var outputURL: URL?
    var addedAt: Date

    var statusText: String {
        if case let .failed(message) = status {
            return message.isEmpty ? status.label : "\(status.label)：\(message)"
        }
        return status.label
    }

    var isTerminalForCleanup: Bool {
        switch status {
        case .completed, .failed:
            return true
        case .waiting, .analyzing, .running:
            return false
        }
    }
}

typealias VideoOptimizationQueueItem = FrameInterpolationQueueItem

struct VideoOptimizationHistoryRecord: Identifiable, Equatable, Codable {
    enum Outcome: String, Codable {
        case completed
        case failed
        case cancelled
    }

    let id: UUID
    let videoPath: String
    let title: String
    let targetFPS: Int
    let source: FrameInterpolationQueueItem.Source
    let operations: [FrameInterpolationQueueItem.Operation]
    let completedOperations: [FrameInterpolationQueueItem.Operation]
    let outcome: Outcome
    let message: String?
    let completedAt: Date

    var videoURL: URL { URL(fileURLWithPath: videoPath) }
}

struct FrameInterpolationExportProgress: Sendable {
    let progress: Double
    let writtenFrames: Int64
    let totalFrames: Int64?
    let opticalFlowFrames: Int64
    let elapsedSeconds: TimeInterval
    let remainingSeconds: TimeInterval?
    let currentStage: String
}

enum FrameInterpolationExportResult: Sendable {
    case replaced(URL)
    case cancelled
    case failed(String)
}

struct FrameInterpolationRecordItem: Identifiable, Equatable, Codable {
    let id: String
    let videoPath: String
    let title: String
    let targetFPS: Int
    let recordedAt: Date

    var videoURL: URL {
        URL(fileURLWithPath: videoPath)
    }
}


struct VideoOptimizationAutomaticPolicy: Equatable, Codable {
    /// 下载 / 烘焙完成后是否自动「优化视频」。
    /// 与手动入口一致：先循环分析，再补帧（Scene bake 产物跳过循环分析）。
    var automaticallyOptimizeVideos: Bool
    var targetFPS: Int

    static let disabled = VideoOptimizationAutomaticPolicy(
        automaticallyOptimizeVideos: false,
        targetFPS: 60
    )
}

@MainActor
final class VideoOptimizationQueueService: ObservableObject {
    static let shared = VideoOptimizationQueueService()

    @Published private(set) var items: [FrameInterpolationQueueItem] = [] {
        didSet {
            scheduleQueueCheckpointSave()
        }
    }
    @Published private(set) var completedInterpolationItems: [FrameInterpolationRecordItem] = []
    @Published private(set) var blacklistedInterpolationItems: [FrameInterpolationRecordItem] = []
    @Published private(set) var history: [VideoOptimizationHistoryRecord] = []
    /// 下载/烘焙完成后是否自动进入优化流水线。
    @Published private(set) var automaticPolicy = VideoOptimizationAutomaticPolicy.disabled

    /// 兼容旧属性名：映射到统一自动优化开关。
    @Published var autoInterpolateOnDownload: Bool {
        didSet {
            WaifuXPreferences.shared.set(autoInterpolateOnDownload, forKey: Self.autoOnDownloadKey)
        }
    }

    /// 兼容旧设置页绑定名；映射到「下载后自动优化视频」。
    @Published var autoEnqueueEnabled: Bool {
        didSet {
            if autoEnqueueEnabled != autoInterpolateOnDownload {
                autoInterpolateOnDownload = autoEnqueueEnabled
            }
        }
    }

    private var runningTasks: [UUID: Task<Void, Never>] = [:]
    private var heartbeatTasks: [UUID: Task<Void, Never>] = [:]
    private var taskStartDates: [UUID: Date] = [:]
    /// 异步规划（读源 FPS）进行中的视频路径，防止连点重复入队。
    private var planningVideoPaths = Set<String>()
    private var interpolationRecordsLoaded = false
    private var historyLoaded = false
    private var didRestoreQueueCheckpoint = false
    private var sourceRestoreRequests: [String: VideoOptimizationQueueCheckpointStore.SourceRestoreRequest] = [:]
    private var queueCheckpointSaveTask: Task<Void, Never>?

    private static let completedInterpolationRecordsKey = "frame_interpolation_completed_records_v1"
    private static let blacklistedInterpolationRecordsKey = "frame_interpolation_blacklist_records_v1"
    private static let autoOnDownloadKey = "frame_interpolation_auto_on_download"
    private static let legacyAutoEnqueueKey = "frame_interpolation_auto_enqueue"
    private static let legacyAutoAnalyzeLoopKey = "auto_analyze_loop_point"
    private static let historyKey = "video_optimization_history_v1"

    func backgroundSnapshot() -> Data {
        (try? BackgroundPropertyList.encode([
            "items": JSONEncoder().encode(items),
            "completed": JSONEncoder().encode(completedInterpolationItems),
            "blacklisted": JSONEncoder().encode(blacklistedInterpolationItems),
            "history": JSONEncoder().encode(history),
            "policy": JSONEncoder().encode(automaticPolicy)
        ])) ?? Data()
    }

    private func receiveBackgroundSnapshot(_ snapshot: [String: Any]) {
        guard let bytes = snapshot["optimization"] as? Data, let values = try? BackgroundPropertyList.decode(bytes) else { return }
        if let data = values["items"] as? Data, let decoded = try? JSONDecoder().decode([FrameInterpolationQueueItem].self, from: data) { items = decoded }
        if let data = values["completed"] as? Data, let decoded = try? JSONDecoder().decode([FrameInterpolationRecordItem].self, from: data) { completedInterpolationItems = decoded }
        if let data = values["blacklisted"] as? Data, let decoded = try? JSONDecoder().decode([FrameInterpolationRecordItem].self, from: data) { blacklistedInterpolationItems = decoded }
        if let data = values["history"] as? Data, let decoded = try? JSONDecoder().decode([VideoOptimizationHistoryRecord].self, from: data) { history = decoded }
    }

    private init() {
        // 不在单例初始化阶段读取 UserDefaults。macOS 26+ 上启动早期读偏好设置
        // 可能触发 _CFXPreferences 递归；真实设置由 SettingsViewModel 延迟恢复后同步过来。
        self.autoInterpolateOnDownload = false
        self.autoEnqueueEnabled = false
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.observe { [weak self] snapshot in self?.receiveBackgroundSnapshot(snapshot) } }
    }

    /// 由设置页恢复偏好后调用（兼容旧签名）。
    func applySettings(autoOnDownload: Bool) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("optimization.applySettings0", ["autoOnDownload": autoOnDownload]); return }

        applySettings(
            automaticPolicy: VideoOptimizationAutomaticPolicy(
                automaticallyOptimizeVideos: autoOnDownload,
                targetFPS: FrameInterpolationTargetFPSResolver.targetFPSForManualAction()
            )
        )
    }

    /// 统一自动优化策略：开关打开后按「循环分析 → 补帧」入队（与手动优化一致）。
    func applySettings(automaticPolicy: VideoOptimizationAutomaticPolicy) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("optimization.applySettings1", ["automaticPolicy": try? JSONEncoder().encode(automaticPolicy)]); return }

        self.automaticPolicy = automaticPolicy
        autoInterpolateOnDownload = automaticPolicy.automaticallyOptimizeVideos
        autoEnqueueEnabled = automaticPolicy.automaticallyOptimizeVideos
        WaifuXPreferences.shared.set(automaticPolicy.automaticallyOptimizeVideos, forKey: Self.autoOnDownloadKey)
        // 旧双开关一并同步，避免其它路径读到分叉状态。
        WaifuXPreferences.shared.set(automaticPolicy.automaticallyOptimizeVideos, forKey: Self.legacyAutoAnalyzeLoopKey)
        // 清理旧的「切换壁纸时自动补帧」开关，避免再被读回。
        WaifuXPreferences.shared.set(false, forKey: Self.legacyAutoEnqueueKey)
        restoreQueueCheckpointIfNeeded()
    }

    private struct OptimizationPlan: Sendable {
        let operations: [FrameInterpolationQueueItem.Operation]
        /// 仅当明确读到源 FPS 且 ≥ 目标时非 nil，用于写入 frameNotNeeded。
        let frameNotNeededReason: String?
    }

    /// 规划优化步骤：先循环再补帧。
    /// - 循环：Scene bake 已可循环或已有终态时跳过。
    /// - 补帧：源 FPS 已达到/高于目标、或已有覆盖目标的补帧终态时跳过。
    func plannedOptimizationOperations(
        for videoURL: URL,
        targetFPS: Int,
        preferDurableLoopState: Bool = true
    ) async -> [FrameInterpolationQueueItem.Operation] {
        await makeOptimizationPlan(
            for: videoURL,
            targetFPS: targetFPS,
            preferDurableLoopState: preferDurableLoopState
        ).operations
    }

    private func makeOptimizationPlan(
        for videoURL: URL,
        targetFPS: Int,
        preferDurableLoopState: Bool = true
    ) async -> OptimizationPlan {
        let fps = FrameInterpolationTargetFPSResolver.nearestAllowedFixedFPS(targetFPS)
        var operations: [FrameInterpolationQueueItem.Operation] = []
        var frameNotNeededReason: String?

        let needsLoop: Bool
        if hasSceneBakeProvidedLoop(for: videoURL) {
            needsLoop = false
        } else if preferDurableLoopState {
            switch VideoOptimizationRecordStore.shared.loopState(for: videoURL) {
            case .applied, .notNeeded, .noReliablePoint:
                needsLoop = false
            case .idle, .failed:
                needsLoop = true
            }
        } else {
            needsLoop = true
        }
        if needsLoop {
            operations.append(.loopTransition)
        }

        if fps > 0,
           !isBlacklisted(videoURL: videoURL),
           completedRecord(videoURL: videoURL, satisfying: fps) == nil {
            let decision = await VideoFrameInterpolationAnalyzer.decision(for: videoURL, targetFPS: fps)
            if decision.shouldInterpolate {
                operations.append(.frameInterpolation)
            } else if decision.sourceFPS != nil {
                frameNotNeededReason = decision.reason
            }
        }

        return OptimizationPlan(
            operations: normalizedOperations(operations),
            frameNotNeededReason: frameNotNeededReason
        )
    }

    private func applyFrameNotNeededIfNeeded(
        plan: OptimizationPlan,
        videoURL: URL,
        title: String,
        targetFPS: Int
    ) {
        guard let reason = plan.frameNotNeededReason else { return }
        markInterpolationNotNeeded(
            videoURL: videoURL,
            title: title,
            targetFPS: targetFPS,
            reason: reason
        )
    }

    private func beginPlanning(for videoURL: URL) -> Bool {
        let path = videoURL.standardizedFileURL.path
        if planningVideoPaths.contains(path) { return false }
        if hasActiveInterpolation(videoURL: videoURL) { return false }
        objectWillChange.send()
        planningVideoPaths.insert(path)
        return true
    }

    private func endPlanning(for videoURL: URL) {
        objectWillChange.send()
        planningVideoPaths.remove(videoURL.standardizedFileURL.path)
    }

    /// 下载或烘焙完成后的统一自动入口。
    @discardableResult
    func enqueueAutomaticOptimizationIfNeeded(
        videoURL: URL,
        title: String? = nil
    ) -> UUID? {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("optimization.enqueueAutomaticOptimizationIfNeeded", ["videoURL": videoURL, "title": title]); return nil }

        let policy = automaticPolicy
        guard policy.automaticallyOptimizeVideos else { return nil }
        guard videoURL.isFileURL,
              FileManager.default.fileExists(atPath: videoURL.path) else {
            return nil
        }
        let ext = videoURL.pathExtension.lowercased()
        guard ["mp4", "mov", "m4v", "mkv"].contains(ext) else { return nil }

        let targetFPS = FrameInterpolationTargetFPSResolver.nearestAllowedFixedFPS(policy.targetFPS)
        guard targetFPS > 0 else { return nil }
        guard !isBlacklisted(videoURL: videoURL) else { return nil }
        guard beginPlanning(for: videoURL) else { return nil }

        let resolvedTitle = title?.isEmpty == false
            ? title!
            : videoURL.deletingPathExtension().lastPathComponent
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.endPlanning(for: videoURL) }
            let plan = await self.makeOptimizationPlan(
                for: videoURL,
                targetFPS: targetFPS,
                preferDurableLoopState: true
            )
            self.applyFrameNotNeededIfNeeded(
                plan: plan,
                videoURL: videoURL,
                title: resolvedTitle,
                targetFPS: targetFPS
            )
            guard !plan.operations.isEmpty else {
                frameInterpolationDebugPrint(
                    "自动入口：源 FPS 已达标且无需循环，跳过。视频=\(videoURL.lastPathComponent)，目标 FPS=\(targetFPS)"
                )
                return
            }
            frameInterpolationDebugPrint(
                "自动入口：加入优化队列。操作=\(plan.operations.map(\.rawValue).joined(separator: "+"))，视频=\(videoURL.lastPathComponent)，目标 FPS=\(targetFPS)"
            )
            _ = self.enqueue(
                videoURL: videoURL,
                title: resolvedTitle,
                targetFPS: targetFPS,
                source: .automatic,
                operations: plan.operations
            )
        }
        // 异步规划 FPS；调用方只需触发即可，具体入队在 Task 内完成。
        return nil
    }


    /// Scene bake already emits a loopable clip. Automatic loop analysis should
    /// not rewrite those files unless the user starts a manual loop job.
    private func hasSceneBakeProvidedLoop(for videoURL: URL) -> Bool {
        guard let record = VideoOptimizationRecordStore.shared.record(for: videoURL) else {
            return false
        }
        if record.source?.kind == .sceneBake {
            return true
        }
        return record.events.reversed().contains { event in
            event.kind == .loopNotNeeded && event.metadata["reason"] == "sceneBakeSeamless"
        }
    }

    /// 烘焙产物登记后的自动优化入口。
    ///
    /// Scene bake already produces a loopable clip (period detection / fixed
    /// duration). Automatic loop analysis is therefore skipped; with auto
    /// optimize on, only frame interpolation is enqueued. Manual loop actions
    /// remain available.
    @discardableResult
    func enqueueAfterBakeIfNeeded(videoURL: URL, title: String? = nil) -> UUID? {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("optimization.enqueueAfterBakeIfNeeded", ["videoURL": videoURL, "title": title]); return nil }

        let policy = automaticPolicy
        guard videoURL.isFileURL,
              FileManager.default.fileExists(atPath: videoURL.path) else {
            return nil
        }

        // Durable hint for later generic auto-entry paths: bake already owns looping.
        if !hasSceneBakeProvidedLoop(for: videoURL) {
            _ = VideoOptimizationRecordStore.shared.append(
                .loopNotNeeded,
                for: videoURL,
                metadata: [
                    "reason": "sceneBakeSeamless",
                    "title": title ?? videoURL.deletingPathExtension().lastPathComponent,
                ]
            )
        }

        guard policy.automaticallyOptimizeVideos else {
            frameInterpolationDebugPrint(
                "烘焙完成：自动优化关闭，不入队。视频=\(videoURL.lastPathComponent)"
            )
            return nil
        }

        let targetFPS = FrameInterpolationTargetFPSResolver.nearestAllowedFixedFPS(policy.targetFPS)
        guard targetFPS > 0 else { return nil }
        guard !isBlacklisted(videoURL: videoURL) else { return nil }
        guard beginPlanning(for: videoURL) else { return nil }

        let resolvedTitle = title?.isEmpty == false
            ? title!
            : videoURL.deletingPathExtension().lastPathComponent
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.endPlanning(for: videoURL) }
            let plan = await self.makeOptimizationPlan(
                for: videoURL,
                targetFPS: targetFPS,
                preferDurableLoopState: true
            )
            self.applyFrameNotNeededIfNeeded(
                plan: plan,
                videoURL: videoURL,
                title: resolvedTitle,
                targetFPS: targetFPS
            )
            guard !plan.operations.isEmpty else {
                frameInterpolationDebugPrint(
                    "烘焙完成：源 FPS 已达标且无需循环，跳过。视频=\(videoURL.lastPathComponent)，目标 FPS=\(targetFPS)"
                )
                return
            }
            frameInterpolationDebugPrint(
                "烘焙完成：自动优化入队。操作=\(plan.operations.map(\.rawValue).joined(separator: "+"))，视频=\(videoURL.lastPathComponent)，目标 FPS=\(targetFPS)"
            )
            _ = self.enqueue(
                videoURL: videoURL,
                title: resolvedTitle,
                targetFPS: targetFPS,
                source: .automatic,
                operations: plan.operations
            )
        }
        return nil
    }

    /// Registers a completed download as a new optimization origin. A re-download
    /// must not inherit terminal states from the previous optimized file.
    func registerDownloadedSource(videoURL: URL, sourceURL: URL? = nil) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("optimization.registerDownloadedSource", ["videoURL": videoURL, "sourceURL": sourceURL]); return }

        resetOptimizationState(videoURL: videoURL)
        VideoOptimizationRecordStore.shared.recordDownloadedSource(for: videoURL, sourceURL: sourceURL)
    }

    /// Refreshes bake provenance for a baked MP4. Existing terminal decisions
    /// for that artifact path are retained unless the caller resets first.
    func registerBakedSource(
        videoURL: URL,
        sourcePath: String,
        artifact: SceneBakeArtifact
    ) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("optimization.registerBakedSource", ["videoURL": videoURL, "sourcePath": sourcePath, "artifact": try? JSONEncoder().encode(artifact)]); return }

        VideoOptimizationRecordStore.shared.recordBakeArtifact(
            for: videoURL,
            sourcePath: sourcePath,
            artifact: artifact
        )
    }

    /// Clears in-flight queue work and the adjacent sidecar so a replaced source
    /// can start a fresh lifecycle.
    func resetOptimizationState(videoURL: URL) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("optimization.resetOptimizationState", ["videoURL": videoURL]); return }

        let standardizedURL = videoURL.standardizedFileURL
        let matchingIDs = items.compactMap { item in
            item.videoURL.standardizedFileURL == standardizedURL ? item.id : nil
        }

        for id in matchingIDs {
            if let task = runningTasks[id] {
                task.cancel()
                runningTasks[id] = nil
            }
            stopHeartbeat(id: id)
            taskStartDates[id] = nil
        }
        items.removeAll { $0.videoURL.standardizedFileURL == standardizedURL }
        VideoOptimizationRecordStore.shared.reset(for: standardizedURL)
        persistQueueCheckpointImmediately()
        scheduleNext()
    }

    /// 将单个视频加入循环过渡生成任务。若同一文件已有待处理任务，返回原任务 id。
    /// Defers one manual operation until the original source has been re-downloaded.
    func requestAfterSourceRestore(
        videoURL: URL,
        title: String? = nil,
        operations: [FrameInterpolationQueueItem.Operation]
    ) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("optimization.requestAfterSourceRestore", ["videoURL": videoURL, "title": title, "operations": operations.map(\.rawValue)]); return }

        let ops = normalizedOperations(operations)
        guard !ops.isEmpty else { return }
        sourceRestoreRequests[videoURL.standardizedFileURL.path] = .enqueue(
            videoURL: videoURL,
            title: title,
            targetFPS: FrameInterpolationTargetFPSResolver.targetFPSForManualAction(),
            operations: ops
        )
        persistQueueCheckpointImmediately()
    }

    func cancelSourceRestoreRequest(videoURL: URL) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("optimization.cancelSourceRestoreRequest", ["videoURL": videoURL]); return }

        sourceRestoreRequests.removeValue(forKey: videoURL.standardizedFileURL.path)
        persistQueueCheckpointImmediately()
    }


    /// 手动循环分析始终可用；不再受设置页总开关门控。
    var isLoopAnalysisEnabled: Bool { true }

    /// 手动补帧始终可用；不再受设置页总开关门控。
    /// 实际是否入队补帧仍以源 FPS 与目标 FPS 比较为准。
    var isFrameInterpolationEnabled: Bool { true }

    /// 菜单展示用：始终提供「优化视频」入口；具体步骤在入队时按 FPS/终态规划。
    var enabledManualOptimizationOperations: [FrameInterpolationQueueItem.Operation] {
        [.loopTransition, .frameInterpolation]
    }

    /// 手动「优化视频」：读取源 FPS 后规划步骤。
    /// 源 FPS ≥ 目标时只做循环；都无需做则不入队。
    @discardableResult
    func enqueueOptimizeVideo(
        videoURL: URL,
        title: String? = nil,
        targetFPS: Int? = nil,
        source: FrameInterpolationQueueItem.Source = .manual
    ) -> UUID? {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("optimization.enqueueOptimizeVideo", ["videoURL": videoURL, "title": title, "targetFPS": targetFPS, "source": source.rawValue]); return nil }

        let fps = FrameInterpolationTargetFPSResolver.nearestAllowedFixedFPS(
            targetFPS ?? FrameInterpolationTargetFPSResolver.targetFPSForManualAction()
        )
        guard fps > 0,
              videoURL.isFileURL,
              FileManager.default.fileExists(atPath: videoURL.path) else {
            return nil
        }
        guard beginPlanning(for: videoURL) else { return nil }

        let resolvedTitle = title?.isEmpty == false
            ? title!
            : videoURL.deletingPathExtension().lastPathComponent
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.endPlanning(for: videoURL) }
            let plan = await self.makeOptimizationPlan(
                for: videoURL,
                targetFPS: fps,
                preferDurableLoopState: true
            )
            // 源 FPS 已达标时记下 notNeeded，避免详情菜单仍显示可补帧却入队后空跑。
            self.applyFrameNotNeededIfNeeded(
                plan: plan,
                videoURL: videoURL,
                title: resolvedTitle,
                targetFPS: fps
            )
            guard !plan.operations.isEmpty else {
                frameInterpolationDebugPrint(
                    "手动优化：源 FPS 已达标且无需循环，跳过。视频=\(videoURL.lastPathComponent)，目标 FPS=\(fps)"
                )
                return
            }
            frameInterpolationDebugPrint(
                "手动优化：加入队列。操作=\(plan.operations.map(\.rawValue).joined(separator: "+"))，视频=\(videoURL.lastPathComponent)，目标 FPS=\(fps)"
            )
            _ = self.enqueue(
                videoURL: videoURL,
                title: resolvedTitle,
                targetFPS: fps,
                source: source,
                operations: plan.operations
            )
        }
        return nil
    }

    @discardableResult
    func enqueueLoopTransition(
        videoURL: URL,
        title: String? = nil,
        source: FrameInterpolationQueueItem.Source = .manual
    ) -> UUID? {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("optimization.enqueueLoopTransition", ["videoURL": videoURL, "title": title, "source": source.rawValue]); return nil }

        return enqueue(
            videoURL: videoURL,
            title: title,
            targetFPS: FrameInterpolationTargetFPSResolver.targetFPSForManualAction(),
            source: source,
            operations: [.loopTransition]
        )
    }

    /// Alias used by detail-status UI (same as loop transition / loop analysis).
    @discardableResult
    func enqueueLoopAnalysis(
        videoURL: URL,
        title: String? = nil,
        source: FrameInterpolationQueueItem.Source = .manual
    ) -> UUID? {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("optimization.enqueueLoopAnalysis", ["videoURL": videoURL, "title": title, "source": source.rawValue]); return nil }

        return enqueueLoopTransition(videoURL: videoURL, title: title, source: source)
    }

    /// Explicit frame interpolation without a preceding loop step.
    /// 源 FPS 已达标时不入队。
    @discardableResult
    func enqueueFrameInterpolation(
        videoURL: URL,
        title: String? = nil,
        targetFPS: Int? = nil,
        source: FrameInterpolationQueueItem.Source = .manual
    ) -> UUID? {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("optimization.enqueueFrameInterpolation", ["videoURL": videoURL, "title": title, "targetFPS": targetFPS, "source": source.rawValue]); return nil }

        let fps = FrameInterpolationTargetFPSResolver.nearestAllowedFixedFPS(
            targetFPS ?? FrameInterpolationTargetFPSResolver.targetFPSForManualAction()
        )
        guard fps > 0,
              videoURL.isFileURL,
              FileManager.default.fileExists(atPath: videoURL.path) else {
            return nil
        }
        guard beginPlanning(for: videoURL) else { return nil }

        let resolvedTitle = title?.isEmpty == false
            ? title!
            : videoURL.deletingPathExtension().lastPathComponent
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.endPlanning(for: videoURL) }
            let decision = await VideoFrameInterpolationAnalyzer.decision(for: videoURL, targetFPS: fps)
            guard decision.shouldInterpolate else {
                if decision.sourceFPS != nil {
                    self.markInterpolationNotNeeded(
                        videoURL: videoURL,
                        title: resolvedTitle,
                        targetFPS: fps,
                        reason: decision.reason
                    )
                }
                frameInterpolationDebugPrint(
                    "手动补帧：源 FPS 已达标或无法读取，跳过。视频=\(videoURL.lastPathComponent)，目标 FPS=\(fps)，原因=\(decision.reason)"
                )
                return
            }
            _ = self.enqueue(
                videoURL: videoURL,
                title: resolvedTitle,
                targetFPS: fps,
                source: source,
                operations: [.frameInterpolation]
            )
        }
        return nil
    }

    /// 将同一个文件按“生成循环过渡 -> 补帧”的顺序加入统一队列。
    /// 源 FPS 已达标时只入队循环分析。
    @discardableResult
    func enqueueLoopTransitionThenInterpolation(
        videoURL: URL,
        title: String? = nil,
        targetFPS: Int? = nil,
        source: FrameInterpolationQueueItem.Source = .manual
    ) -> UUID? {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("optimization.enqueueLoopTransitionThenInterpolation", ["videoURL": videoURL, "title": title, "targetFPS": targetFPS, "source": source.rawValue]); return nil }

        return enqueueOptimizeVideo(
            videoURL: videoURL,
            title: title,
            targetFPS: targetFPS,
            source: source
        )
    }

    func markInterpolationNotNeeded(
        videoURL: URL,
        title: String,
        targetFPS: Int,
        reason: String
    ) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("optimization.markInterpolationNotNeeded", ["videoURL": videoURL, "title": title, "targetFPS": targetFPS, "reason": reason]); return }

        ensureInterpolationRecordsLoaded()
        let record = makeInterpolationRecord(videoURL: videoURL, title: title, targetFPS: targetFPS)
        _ = VideoOptimizationRecordStore.shared.removeEvents(
            matching: [.frameApplied, .frameBlacklisted],
            for: videoURL
        )
        _ = VideoOptimizationRecordStore.shared.append(
            .frameNotNeeded,
            for: videoURL,
            detail: reason,
            metadata: [
                "targetFPS": String(targetFPS),
                "title": record.title,
            ]
        )
        completedInterpolationItems.removeAll { $0.id == record.id }
        completedInterpolationItems.append(record)
        completedInterpolationItems.sort { $0.recordedAt > $1.recordedAt }
        blacklistedInterpolationItems.removeAll { $0.id == record.id }
        saveInterpolationRecords()
    }

    /// 批量入口只接受本地视频，文件枚举与任务去重均由服务负责。
    @discardableResult
    func enqueue(
        videoURLs: [URL],
        operation: FrameInterpolationQueueItem.Operation,
        targetFPS: Int? = nil,
        source: FrameInterpolationQueueItem.Source = .manual
    ) -> [UUID] {
        videoURLs.compactMap { videoURL in
            enqueue(
                videoURL: videoURL,
                title: videoURL.deletingPathExtension().lastPathComponent,
                targetFPS: targetFPS ?? FrameInterpolationTargetFPSResolver.targetFPSForManualAction(),
                source: source,
                operations: [operation]
            )
        }
    }

    /// 文件夹批量入口。递归扫描支持的视频扩展名，但调用方无需自行枚举文件。
    @discardableResult
    func enqueueFolder(
        at folderURL: URL,
        operation: FrameInterpolationQueueItem.Operation,
        targetFPS: Int? = nil,
        source: FrameInterpolationQueueItem.Source = .manual
    ) -> [UUID] {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("optimization.enqueueFolder", ["folderURL": folderURL, "operation": operation.rawValue, "targetFPS": targetFPS, "source": source.rawValue]); return [] }

        let extensions = Set(["mp4", "mov", "m4v", "mkv"])
        guard let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let urls = enumerator.compactMap { $0 as? URL }.filter { url in
            guard extensions.contains(url.pathExtension.lowercased()) else { return false }
            return (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        return enqueue(videoURLs: urls, operation: operation, targetFPS: targetFPS, source: source)
    }

    /// 从“我的库”的逻辑文件夹解析本地视频并批量入队；视图只传递文件夹，不枚举或替换文件。
    /// 每个视频单独规划步骤：源 FPS 已达标时只做循环。
    /// `operations` 保留兼容旧调用方，实际步骤由 `enqueueOptimizeVideo` 按 FPS/终态规划。
    @discardableResult
    func enqueueLibraryFolder(
        _ folder: LibraryFolder,
        operations _: [FrameInterpolationQueueItem.Operation] = [.loopTransition, .frameInterpolation],
        targetFPS: Int? = nil,
        source: FrameInterpolationQueueItem.Source = .manual
    ) -> [UUID] {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("optimization.enqueueLibraryFolder", ["folder": try? JSONEncoder().encode(folder), "targetFPS": targetFPS, "source": source.rawValue]); return [] }

        let effectiveTargetFPS = targetFPS ?? FrameInterpolationTargetFPSResolver.targetFPSForManualAction()
        let targets = libraryOptimizationTargets(in: folder)
        for target in targets {
            _ = enqueueOptimizeVideo(
                videoURL: target.videoURL,
                title: target.title,
                targetFPS: effectiveTargetFPS,
                source: source
            )
        }
        // 异步规划后入队，无法同步返回真实 UUID。
        return []
    }

    /// 统一判断库条目是否能作为视频优化输入，避免各个视图各自猜测文件类型。
    /// Web Wallpaper Engine 工程由 Web renderer 接管，不能替换其内部媒体资源。
    func optimizableVideoURL(from localURL: URL?) -> URL? {
        guard let localURL, localURL.isFileURL else {
            return nil
        }
        guard !isWebWallpaperEngineAsset(at: localURL) else {
            return nil
        }
        guard let videoURL = MediaItem.resolveLocalVideoFile(from: localURL) else {
            return nil
        }
        return videoURL
    }

    /// 库内媒体下载记录：优先 Scene 烘焙 MP4（纯 scene 工程目录本身没有可优化视频）。
    /// 与详情页 `currentOptimizationVideoURL` 一致，避免「详情可优化、列表右键没有」分叉。
    func optimizableVideoURL(forDownloadRecord record: MediaDownloadRecord) -> URL? {
        if let bakePath = record.sceneBakeArtifact?.videoPath, !bakePath.isEmpty {
            let bakeURL = URL(fileURLWithPath: bakePath)
            if let videoURL = optimizableVideoURL(from: bakeURL) {
                return videoURL
            }
        }
        // 部分历史路径写在 resolved 侧；再回退工程目录内嵌视频 / 原生 mp4。
        if let resolved = record.resolvedVideoFileURL,
           let videoURL = optimizableVideoURL(from: resolved) {
            return videoURL
        }
        return optimizableVideoURL(from: record.localFileURL)
    }

    /// 按媒体项解析可优化视频：有下载记录时走烘焙优先路径。
    func optimizableVideoURL(forMediaItem item: MediaItem, localURL: URL? = nil) -> URL? {
        if let record = MediaLibraryService.shared.downloadRecord(for: item.id) {
            return optimizableVideoURL(forDownloadRecord: record)
        }
        return optimizableVideoURL(from: localURL)
    }

    /// `localURL` 通常是工程根目录，但旧下载记录可能直接指向工程内的视频资源。
    /// 向上检查有限层级，确保 Web 工程不会通过该兼容路径进入原地替换流程。
    private func isWebWallpaperEngineAsset(at url: URL) -> Bool {
        if MediaItem.localWorkshopProjectType(from: url) == "web" {
            return true
        }

        let fileManager = FileManager.default
        var candidate = url
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
           !isDirectory.boolValue {
            candidate = candidate.deletingLastPathComponent()
        }

        for _ in 0..<8 {
            let projectURL = candidate.appendingPathComponent("project.json")
            if let data = try? Data(contentsOf: projectURL),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let type = json["type"] as? String,
               type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "web" {
                return true
            }

            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { break }
            candidate = parent
        }
        return false
    }

    /// 下载完成后：若有 source-restore 请求则优先兑现，否则按统一自动策略入队。
    @discardableResult
    func enqueueAfterDownloadIfNeeded(
        videoURL: URL,
        title: String? = nil
    ) -> UUID? {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("optimization.enqueueAfterDownloadIfNeeded", ["videoURL": videoURL, "title": title]); return nil }

        let path = videoURL.standardizedFileURL.path
        if let request = sourceRestoreRequests.removeValue(forKey: path) {
            persistQueueCheckpointImmediately()
            if let operation = request.blacklistOperation {
                markBlacklisted(
                    videoURL: videoURL,
                    title: request.title ?? title ?? videoURL.deletingPathExtension().lastPathComponent,
                    targetFPS: request.targetFPS
                )
                // markBlacklisted is frame-focused; also append loop blacklist metadata when requested.
                if operation == .loopTransition {
                    _ = VideoOptimizationRecordStore.shared.append(
                        .loopFailed,
                        for: videoURL,
                        detail: "blacklisted-after-source-restore",
                        metadata: ["title": request.title ?? title ?? ""]
                    )
                }
                return nil
            }
            return enqueue(
                videoURL: videoURL,
                title: request.title ?? title,
                targetFPS: request.targetFPS,
                source: .manual,
                operations: request.operations
            )
        }
        return enqueueAutomaticOptimizationIfNeeded(videoURL: videoURL, title: title)
    }

    func hasPendingInterpolation(videoURL: URL, targetFPS: Int) -> Bool {
        items.contains { item in
            item.videoURL.standardizedFileURL == videoURL.standardizedFileURL
                && item.targetFPS == targetFPS
                && !item.isTerminalForCleanup
        }
    }

    func hasActiveInterpolation(videoURL: URL) -> Bool {
        items.contains { item in
            item.videoURL.standardizedFileURL == videoURL.standardizedFileURL
                && !item.isTerminalForCleanup
        }
    }

    /// 队列中或异步规划（读 FPS）中，用于 UI 禁用连点。
    func isPlanningOrQueued(videoURL: URL) -> Bool {
        let path = videoURL.standardizedFileURL.path
        return planningVideoPaths.contains(path) || hasActiveInterpolation(videoURL: videoURL)
    }

    func activeInterpolationTargetFPS(videoURL: URL) -> Int? {
        items
            .filter { item in
                item.videoURL.standardizedFileURL == videoURL.standardizedFileURL
                    && !item.isTerminalForCleanup
            }
            .map(\.targetFPS)
            .max()
    }

    func hasActiveInterpolation(videoURL: URL, satisfying targetFPS: Int) -> Bool {
        guard let activeTargetFPS = activeInterpolationTargetFPS(videoURL: videoURL) else {
            return false
        }
        return activeTargetFPS >= targetFPS
    }

    func needsInterpolation(videoURL: URL, targetFPS: Int) async -> Bool {
        await VideoFrameInterpolationAnalyzer.decision(for: videoURL, targetFPS: targetFPS).shouldInterpolate
    }

    func isCompleted(videoURL: URL) -> Bool {
        completedRecord(videoURL: videoURL) != nil
    }

    func completedRecord(videoURL: URL) -> FrameInterpolationRecordItem? {
        if let sidecar = VideoOptimizationRecordStore.shared.record(for: videoURL) {
            guard let event = VideoOptimizationRecordStore.shared.latestFrameEvent(for: videoURL) else {
                return nil
            }
            let targetFPS = event.metadata["targetFPS"].flatMap(Int.init)
            switch VideoOptimizationRecordStore.shared.frameState(for: videoURL) {
            case .applied(_), .notNeeded(_):
                return FrameInterpolationRecordItem(
                    id: interpolationRecordID(for: videoURL),
                    videoPath: sidecar.videoPath,
                    title: event.metadata["title"] ?? videoURL.deletingPathExtension().lastPathComponent,
                    targetFPS: targetFPS ?? 0,
                    recordedAt: event.date
                )
            case .idle, .failed, .blacklisted:
                return nil
            }
        }

        ensureInterpolationRecordsLoaded()
        let id = interpolationRecordID(for: videoURL)
        return completedInterpolationItems
            .filter { $0.id == id }
            .max {
                if $0.targetFPS == $1.targetFPS {
                    return $0.recordedAt < $1.recordedAt
                }
                return $0.targetFPS < $1.targetFPS
            }
    }

    func completedRecord(videoURL: URL, satisfying targetFPS: Int) -> FrameInterpolationRecordItem? {
        guard let record = completedRecord(videoURL: videoURL),
              record.targetFPS >= targetFPS else {
            return nil
        }
        return record
    }

    func isBlacklisted(videoURL: URL) -> Bool {
        if VideoOptimizationRecordStore.shared.record(for: videoURL) != nil {
            return VideoOptimizationRecordStore.shared.frameState(for: videoURL) == .blacklisted
        }

        ensureInterpolationRecordsLoaded()
        let id = interpolationRecordID(for: videoURL)
        return blacklistedInterpolationItems.contains { $0.id == id }
    }

    func markCompleted(videoURL: URL, title: String, targetFPS: Int) {
        ensureInterpolationRecordsLoaded()
        let existingRecord = completedRecord(videoURL: videoURL)
        let effectiveTargetFPS = max(targetFPS, existingRecord?.targetFPS ?? targetFPS)
        let effectiveTitle = title.isEmpty ? (existingRecord?.title ?? "") : title
        let record = makeInterpolationRecord(videoURL: videoURL, title: effectiveTitle, targetFPS: effectiveTargetFPS)
        _ = VideoOptimizationRecordStore.shared.removeEvents(
            matching: [.frameBlacklisted],
            for: videoURL
        )
        if !VideoOptimizationRecordStore.shared.append(
            .frameApplied,
            for: videoURL,
            metadata: [
                "targetFPS": String(effectiveTargetFPS),
                "title": record.title,
            ]
        ) {
            frameInterpolationDebugPrint("补帧队列：无法写入补帧 sidecar，已保留旧终态记录。视频=\(videoURL.lastPathComponent)")
        }
        completedInterpolationItems.removeAll { $0.id == record.id }
        completedInterpolationItems.append(record)
        completedInterpolationItems.sort { $0.recordedAt > $1.recordedAt }
        blacklistedInterpolationItems.removeAll { $0.id == record.id }
        saveInterpolationRecords()
    }

    func removeCompleted(videoURL: URL) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("optimization.removeCompleted", ["videoURL": videoURL]); return }

        ensureInterpolationRecordsLoaded()
        _ = VideoOptimizationRecordStore.shared.removeEvents(
            matching: [.frameApplied, .frameNotNeeded],
            for: videoURL
        )
        let id = interpolationRecordID(for: videoURL)
        completedInterpolationItems.removeAll { $0.id == id }
        saveInterpolationRecords()
    }

    func markBlacklisted(videoURL: URL, title: String, targetFPS: Int) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("optimization.markBlacklisted", ["videoURL": videoURL, "title": title, "targetFPS": targetFPS]); return }

        ensureInterpolationRecordsLoaded()
        let record = makeInterpolationRecord(videoURL: videoURL, title: title, targetFPS: targetFPS)
        _ = VideoOptimizationRecordStore.shared.removeEvents(
            matching: [.frameApplied, .frameNotNeeded],
            for: videoURL
        )
        _ = VideoOptimizationRecordStore.shared.append(
            .frameBlacklisted,
            for: videoURL,
            metadata: [
                "targetFPS": String(targetFPS),
                "title": record.title,
            ]
        )
        blacklistedInterpolationItems.removeAll { $0.id == record.id }
        blacklistedInterpolationItems.append(record)
        blacklistedInterpolationItems.sort { $0.recordedAt > $1.recordedAt }
        completedInterpolationItems.removeAll { $0.id == record.id }
        saveInterpolationRecords()
    }

    func removeBlacklisted(videoURL: URL) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("optimization.removeBlacklisted", ["videoURL": videoURL]); return }

        ensureInterpolationRecordsLoaded()
        _ = VideoOptimizationRecordStore.shared.removeEvents(
            matching: [.frameBlacklisted],
            for: videoURL
        )
        let id = interpolationRecordID(for: videoURL)
        blacklistedInterpolationItems.removeAll { $0.id == id }
        saveInterpolationRecords()
    }

    @discardableResult
    func enqueue(
        videoURL: URL,
        title: String? = nil,
        targetFPS: Int,
        source: FrameInterpolationQueueItem.Source,
        operations: [FrameInterpolationQueueItem.Operation] = [.frameInterpolation]
    ) -> UUID? {
        if BackgroundRuntimeRole.isRemoteUI {
            guard videoURL.isFileURL, FileManager.default.fileExists(atPath: videoURL.path) else { return nil }
            let requestedID = UUID()
            BackgroundRuntimeBridge.send("optimization.enqueue", ["url": videoURL, "title": title, "fps": targetFPS, "source": source.rawValue, "operations": operations.map(\.rawValue), "requestedID": requestedID.uuidString])
            return requestedID
        }

        guard targetFPS > 0 else { return nil }
        guard videoURL.isFileURL,
              FileManager.default.fileExists(atPath: videoURL.path) else {
            return nil
        }
        let requestedOperations = normalizedOperations(operations)
        guard !requestedOperations.isEmpty else { return nil }
        // 本地黑名单只记「补帧」终态，不应挡住纯循环分析。
        // 若请求里含补帧且已在补帧黑名单，整单跳过（与旧行为一致）。
        if requestedOperations.contains(.frameInterpolation), isBlacklisted(videoURL: videoURL) {
            frameInterpolationDebugPrint("补帧队列：视频在补帧黑名单中，跳过添加。视频=\(videoURL.lastPathComponent)")
            return nil
        }

        if requestedOperations == [.frameInterpolation],
           let record = completedRecord(videoURL: videoURL, satisfying: targetFPS) {
            frameInterpolationDebugPrint("补帧队列：已有完成记录覆盖目标 FPS，跳过添加。记录 FPS=\(record.targetFPS)，目标 FPS=\(targetFPS)，视频=\(videoURL.lastPathComponent)")
            return nil
        }

        let matchingIndexes = items.indices.filter {
            items[$0].videoURL.standardizedFileURL == videoURL.standardizedFileURL
                && items[$0].targetFPS >= targetFPS
                && !items[$0].isTerminalForCleanup
        }
        if let waitingIndex = matchingIndexes.first(where: {
            if case .waiting = items[$0].status { return true }
            return false
        }) {
            items[waitingIndex].operations = normalizedOperations(
                items[waitingIndex].operations + requestedOperations
            )
            frameInterpolationDebugPrint("补帧队列：已合并等待任务。任务 FPS=\(items[waitingIndex].targetFPS)，目标 FPS=\(targetFPS)，视频=\(videoURL.lastPathComponent)")
            return items[waitingIndex].id
        }
        if let activeIndex = matchingIndexes.first {
            let missingOperations = requestedOperations.filter { !items[activeIndex].operations.contains($0) }
            guard !missingOperations.isEmpty else {
                frameInterpolationDebugPrint("补帧队列：已有运行任务覆盖请求，跳过重复添加。任务 FPS=\(items[activeIndex].targetFPS)，目标 FPS=\(targetFPS)，视频=\(videoURL.lastPathComponent)")
                return items[activeIndex].id
            }

            let successor = makeQueueItem(
                videoURL: videoURL,
                title: title,
                targetFPS: targetFPS,
                source: source,
                operations: requestedOperations
            )
            items.append(successor)
            frameInterpolationDebugPrint("补帧队列：运行中的任务无法追加新操作，已创建后继任务。当前任务=\(items[activeIndex].id)，后继任务=\(successor.id)，视频=\(videoURL.lastPathComponent)")
            clearProgressForWaitingItems()
            return successor.id
        }

        let lowerWaitingIDs = items.compactMap { item -> UUID? in
            guard item.videoURL.standardizedFileURL == videoURL.standardizedFileURL,
                  item.targetFPS < targetFPS,
                  case .waiting = item.status else {
                return nil
            }
            return item.id
        }
        for waitingID in lowerWaitingIDs {
            guard let index = items.firstIndex(where: { $0.id == waitingID }) else { continue }
            let removedItem = items.remove(at: index)
            archive(removedItem, outcome: .cancelled, message: "被更高目标帧率任务替代")
            frameInterpolationDebugPrint("补帧队列：目标 FPS 已提高，移除低目标等待任务。旧 FPS=\(removedItem.targetFPS)，新 FPS=\(targetFPS)，视频=\(videoURL.lastPathComponent)")
        }

        let item = makeQueueItem(
            videoURL: videoURL,
            title: title,
            targetFPS: targetFPS,
            source: source,
            operations: requestedOperations
        )
        items.append(item)
        if requestedOperations.contains(.frameInterpolation) {
            _ = VideoOptimizationRecordStore.shared.append(
                .frameQueued,
                for: videoURL,
                metadata: [
                    "targetFPS": String(targetFPS),
                    "title": item.title,
                ]
            )
        }
        frameInterpolationDebugPrint("补帧队列：已添加任务。来源=\(source.rawValue)，目标 FPS=\(targetFPS)，视频=\(videoURL.path)")
        clearProgressForWaitingItems()
        persistQueueCheckpointImmediately()
        scheduleNext()
        return item.id
    }

    private func makeQueueItem(
        videoURL: URL,
        title: String?,
        targetFPS: Int,
        source: FrameInterpolationQueueItem.Source,
        operations: [FrameInterpolationQueueItem.Operation]
    ) -> FrameInterpolationQueueItem {
        FrameInterpolationQueueItem(
            id: UUID(),
            videoURL: videoURL,
            title: title?.isEmpty == false ? title! : videoURL.deletingPathExtension().lastPathComponent,
            targetFPS: targetFPS,
            source: source,
            operations: operations,
            completedOperations: [],
            currentOperation: nil,
            sourceFPS: nil,
            status: .waiting,
            progress: 0,
            writtenFrames: 0,
            totalFrames: nil,
            opticalFlowFrames: 0,
            elapsedSeconds: 0,
            remainingSeconds: nil,
            currentStage: t("frameInterpolationStageWaiting"),
            outputURL: nil,
            addedAt: Date()
        )
    }

    private func scheduleNext() {
        clearProgressForWaitingItems()
        // 循环分析与补帧是两条独立资源通道，各自最多运行 1 个任务。
        // 同一视频仍不能跨通道并发，因为循环分析和补帧都会原地替换源文件。
        for operation in FrameInterpolationQueueItem.Operation.allCases {
            guard !isOperationLaneRunning(operation) else { continue }

            let runningPaths = Set(runningTasks.keys.compactMap { runningID in
                items.first(where: { $0.id == runningID })?.videoURL.standardizedFileURL.path
            })
            guard let nextID = items
                .filter({ item in
                    guard runningTasks[item.id] == nil,
                          !runningPaths.contains(item.videoURL.standardizedFileURL.path),
                          nextPendingOperation(for: item) == operation else {
                        return false
                    }
                    if case .waiting = item.status { return true }
                    return false
                })
                .sorted(by: { $0.addedAt < $1.addedAt })
                .first?
                .id else {
                continue
            }
            startItem(id: nextID)
        }
    }

    private func nextPendingOperation(
        for item: FrameInterpolationQueueItem
    ) -> FrameInterpolationQueueItem.Operation? {
        item.operations.first { !item.completedOperations.contains($0) }
    }

    private func isOperationLaneRunning(_ operation: FrameInterpolationQueueItem.Operation) -> Bool {
        runningTasks.keys.contains { runningID in
            items.first(where: { $0.id == runningID })?.currentOperation == operation
        }
    }

    private func startItem(id: UUID) {
        guard runningTasks[id] == nil,
              let index = items.firstIndex(where: { $0.id == id }),
              let operation = nextPendingOperation(for: items[index]),
              !isOperationLaneRunning(operation) else { return }

        items[index].status = .analyzing
        items[index].progress = 0
        items[index].writtenFrames = 0
        items[index].totalFrames = nil
        items[index].opticalFlowFrames = 0
        items[index].elapsedSeconds = 0
        items[index].remainingSeconds = nil
        items[index].currentOperation = operation
        items[index].currentStage = operation == .loopTransition
            ? t("videoOptimizationGeneratingLoopTransition")
            : t("frameInterpolationStageReadingFPS")
        let videoURL = items[index].videoURL
        let targetFPS = items[index].targetFPS
        startHeartbeat(id: id)
        frameInterpolationDebugPrint("视频优化队列：开始 \(operation.rawValue) 通道任务。视频=\(videoURL.lastPathComponent)，目标 FPS=\(targetFPS)")

        let task = Task.detached(priority: .utility) { [weak self] in
            switch operation {
            case .loopTransition:
                do {
                    let loopOutcome = try await VideoLoopAnalysisService.analyzeAndReplace(
                        videoURL: videoURL
                    ) { progress in
                        Task { @MainActor in
                            self?.updateLoopAnalysisProgress(id: id, progress: progress)
                        }
                    }
                    let wasCancelledBeforeTerminalOutcome = Task.isCancelled

                    await MainActor.run {
                        guard let self else { return }
                        switch loopOutcome {
                        case .applied(let firstContentFrame, let lastIncludedFrame):
                            // An in-place replacement is the terminal action. A cancellation
                            // observed after this point must not make the durable state claim
                            // the source remained untouched.
                            _ = VideoOptimizationRecordStore.shared.append(
                                .loopApplied,
                                for: videoURL,
                                metadata: [
                                    "firstContentFrame": String(firstContentFrame),
                                    "lastIncludedFrame": String(lastIncludedFrame),
                                ]
                            )
                            WallpaperLibraryService.shared.markAsLooped(localFilePath: videoURL.path)
                            MediaLibraryService.shared.markAsLooped(localFilePath: videoURL.path)
                            NotificationCenter.default.post(
                                name: .videoOptimizationFileDidReplace,
                                object: videoURL,
                                userInfo: [
                                    VideoOptimizationFileReplacementKind.userInfoKey:
                                        VideoOptimizationFileReplacementKind.loopPreprocessing.rawValue
                                ]
                            )
                            self.finishLoopAnalysis(
                                id: id,
                                message: "循环分析完成"
                            )
                        case .notNeeded:
                            guard !wasCancelledBeforeTerminalOutcome else {
                                self.finishCancelled(id: id, reason: "任务已取消")
                                return
                            }
                            _ = VideoOptimizationRecordStore.shared.append(
                                .loopNotNeeded,
                                for: videoURL,
                                detail: "已验证为无缝循环"
                            )
                            self.finishLoopAnalysis(
                                id: id,
                                message: "视频已是无缝循环"
                            )
                        case .noReliablePoint:
                            guard !wasCancelledBeforeTerminalOutcome else {
                                self.finishCancelled(id: id, reason: "任务已取消")
                                return
                            }
                            _ = VideoOptimizationRecordStore.shared.append(
                                .loopNoReliablePoint,
                                for: videoURL,
                                detail: "未找到可靠循环点"
                            )
                            self.finishLoopAnalysis(
                                id: id,
                                message: "未找到可靠循环点，保留原视频"
                            )
                        }
                    }
                } catch is CancellationError {
                    await MainActor.run { self?.finishCancelled(id: id, reason: "任务已取消") }
                } catch {
                    await MainActor.run {
                        self?.finishFailed(id: id, message: error.localizedDescription)
                    }
                }
            case .frameInterpolation:
                let decision = await VideoFrameInterpolationAnalyzer.decision(
                    for: videoURL,
                    targetFPS: targetFPS
                )
                await MainActor.run {
                    guard let self,
                          let itemIndex = self.items.firstIndex(where: { $0.id == id }) else { return }
                    self.items[itemIndex].sourceFPS = decision.sourceFPS
                    self.items[itemIndex].status = .running
                    self.items[itemIndex].currentStage = t("frameInterpolationStagePreparingExport")
                }

                guard !Task.isCancelled else {
                    await MainActor.run {
                        self?.finishCancelled(id: id, reason: "任务已取消")
                    }
                    return
                }
                guard decision.shouldInterpolate else {
                    await MainActor.run {
                        self?.finishWithoutExport(id: id, reason: decision.reason)
                    }
                    return
                }

                await MainActor.run {
                    guard let self,
                          let item = self.items.first(where: { $0.id == id }) else {
                        return
                    }
                    _ = VideoOptimizationRecordStore.shared.append(
                        .frameStarted,
                        for: videoURL,
                        metadata: [
                            "targetFPS": String(item.targetFPS),
                            "title": item.title,
                        ]
                    )
                }
                let result = await VideoFrameInterpolationExporter.exportIfNeeded(
                    sourceURL: videoURL,
                    targetFPS: targetFPS
                ) { progress in
                    Task { @MainActor in
                        VideoOptimizationQueueService.shared.updateProgress(id: id, progress: progress)
                    }
                }

                await MainActor.run {
                    self?.finishInterpolationExport(id: id, result: result)
                }
            }
        }
        runningTasks[id] = task
    }

    private func startHeartbeat(id: UUID) {
        stopHeartbeat(id: id)
        taskStartDates[id] = Date()
        heartbeatTasks[id] = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.updateHeartbeat(id: id)
                }
            }
        }
    }

    private func stopHeartbeat(id: UUID) {
        heartbeatTasks[id]?.cancel()
        heartbeatTasks[id] = nil
        taskStartDates[id] = nil
    }

    private func updateHeartbeat(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              let startDate = taskStartDates[id] else {
            stopHeartbeat(id: id)
            return
        }

        switch items[index].status {
        case .analyzing, .running:
            break
        default:
            stopHeartbeat(id: id)
            return
        }

        let elapsed = Date().timeIntervalSince(startDate)
        items[index].elapsedSeconds = elapsed

        if let totalFrames = items[index].totalFrames,
           totalFrames > 0,
           items[index].writtenFrames > 0 {
            let speed = Double(items[index].writtenFrames) / max(elapsed, 0.001)
            let remainingFrames = max(0, totalFrames - items[index].writtenFrames)
            items[index].remainingSeconds = speed > 0 && remainingFrames > 0
                ? Double(remainingFrames) / speed
                : nil
        }

        let percent = Int((items[index].progress * 100).rounded())
        frameInterpolationDebugPrint(
            "补帧队列心跳：状态=\(items[index].statusText)，阶段=\(items[index].currentStage)，进度=\(percent)%，已写=\(items[index].writtenFrames)/\(items[index].totalFrames.map(String.init) ?? "未知")，光流帧=\(items[index].opticalFlowFrames)，耗时=\(Self.formatSeconds(elapsed))，剩余=\(items[index].remainingSeconds.map(Self.formatSeconds) ?? "未知")，视频=\(items[index].videoURL.lastPathComponent)"
        )
    }

    private func updateProgress(id: UUID, progress: FrameInterpolationExportProgress) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        guard runningTasks[id] != nil else {
            if case .waiting = items[index].status {
                clearProgress(at: index)
            }
            frameInterpolationDebugPrint("补帧队列：忽略非运行任务的进度回调。状态=\(items[index].statusText)，视频=\(items[index].videoURL.lastPathComponent)")
            return
        }
        switch items[index].status {
        case .analyzing, .running:
            break
        default:
            frameInterpolationDebugPrint("补帧队列：忽略状态不匹配的进度回调。状态=\(items[index].statusText)，视频=\(items[index].videoURL.lastPathComponent)")
            return
        }
        items[index].progress = progress.progress
        items[index].writtenFrames = progress.writtenFrames
        items[index].totalFrames = progress.totalFrames
        items[index].opticalFlowFrames = progress.opticalFlowFrames
        items[index].elapsedSeconds = progress.elapsedSeconds
        items[index].remainingSeconds = progress.remainingSeconds
        items[index].currentStage = progress.currentStage
    }

    private func updateLoopAnalysisProgress(id: UUID, progress: Double) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              runningTasks[id] != nil,
              items[index].currentOperation == .loopTransition else {
            return
        }
        items[index].status = .running
        items[index].progress = min(1, max(0, progress))
        items[index].currentStage = t("videoOptimizationGeneratingLoopTransition")
    }

    /// 取消等待或正在执行的任务。取消不会影响同队列中的其它视频。
    func cancel(id: UUID) {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("optimization.cancel", ["id": id.uuidString]); return }

        if let task = runningTasks[id] {
            task.cancel()
            return
        }
        finishCancelled(id: id, reason: "任务已取消")
    }

    /// 仅重试失败任务；成功和主动取消不会被隐式重新执行。
    @discardableResult
    func retry(historyID: UUID) -> UUID? {
        if BackgroundRuntimeRole.isRemoteUI { BackgroundRuntimeBridge.send("optimization.retry", ["historyID": historyID.uuidString]); return nil }

        ensureHistoryLoaded()
        guard let record = history.first(where: { $0.id == historyID }),
              record.outcome == .failed else {
            return nil
        }
        return enqueue(
            videoURL: record.videoURL,
            title: record.title,
            targetFPS: record.targetFPS,
            source: record.source,
            operations: record.operations
        )
    }

    func item(for videoURL: URL) -> VideoOptimizationQueueItem? {
        let standardizedURL = videoURL.standardizedFileURL
        return items.first { item in
            item.videoURL.standardizedFileURL == standardizedURL && item.currentOperation != nil
        } ?? items.first { item in
            item.videoURL.standardizedFileURL == standardizedURL && !item.isTerminalForCleanup
        }
    }

    /// Read-only operation lanes for status surfaces (status bar / compact toasts).
    func pendingItems(for operation: FrameInterpolationQueueItem.Operation) -> [VideoOptimizationQueueItem] {
        items
            .filter {
                !$0.isTerminalForCleanup
                    && $0.operations.contains(operation)
                    && !$0.completedOperations.contains(operation)
            }
            .sorted { $0.addedAt < $1.addedAt }
    }

    func activeItem(for operation: FrameInterpolationQueueItem.Operation) -> VideoOptimizationQueueItem? {
        pendingItems(for: operation).first { $0.currentOperation == operation }
    }

    func history(for videoURL: URL) -> [VideoOptimizationHistoryRecord] {
        ensureHistoryLoaded()
        let path = videoURL.standardizedFileURL.path
        return history.filter { $0.videoPath == path }
    }

    private func clearProgressForWaitingItems() {
        for index in items.indices {
            if case .waiting = items[index].status {
                clearProgress(at: index)
            }
        }
    }

    private func clearProgress(at index: Array<FrameInterpolationQueueItem>.Index) {
        items[index].progress = 0
        items[index].writtenFrames = 0
        items[index].totalFrames = nil
        items[index].opticalFlowFrames = 0
        items[index].elapsedSeconds = 0
        items[index].remainingSeconds = nil
        items[index].currentStage = t("frameInterpolationStageWaiting")
    }

    private func finishWithoutExport(id: UUID, reason: String) {
        runningTasks[id] = nil
        stopHeartbeat(id: id)
        if let index = items.firstIndex(where: { $0.id == id }) {
            let videoName = items[index].videoURL.lastPathComponent
            let videoURL = items[index].videoURL
            let title = items[index].title
            let targetFPS = items[index].targetFPS
            items[index].status = .completed
            items[index].progress = 1
            items[index].completedOperations.insert(.frameInterpolation)
            let completedItem = items.remove(at: index)
            _ = VideoOptimizationRecordStore.shared.append(
                .frameNotNeeded,
                for: videoURL,
                detail: reason,
                metadata: [
                    "targetFPS": String(targetFPS),
                    "title": title,
                ]
            )
            archive(completedItem, outcome: .completed, message: reason)
            frameInterpolationDebugPrint("补帧队列：无需补帧，任务已移除。原因=\(reason)，视频=\(videoName)")
        }
        persistQueueCheckpointImmediately()
        scheduleNext()
    }

    private func finishCancelled(id: UUID, reason: String) {
        runningTasks[id] = nil
        stopHeartbeat(id: id)
        if let index = items.firstIndex(where: { $0.id == id }) {
            let videoName = items[index].videoURL.lastPathComponent
            let cancelledItem = items.remove(at: index)
            switch cancelledItem.currentOperation {
            case .frameInterpolation:
                _ = VideoOptimizationRecordStore.shared.append(
                    .frameCancelled,
                    for: cancelledItem.videoURL,
                    detail: reason,
                    metadata: [
                        "targetFPS": String(cancelledItem.targetFPS),
                        "title": cancelledItem.title,
                    ]
                )
            case .loopTransition:
                _ = VideoOptimizationRecordStore.shared.append(
                    .loopCancelled,
                    for: cancelledItem.videoURL,
                    detail: reason
                )
            case nil:
                break
            }
            archive(cancelledItem, outcome: .cancelled, message: reason)
            frameInterpolationDebugPrint("补帧队列：任务已取消并移除。原因=\(reason)，视频=\(videoName)")
        }
        persistQueueCheckpointImmediately()
        scheduleNext()
    }

    private func finishInterpolationExport(id: UUID, result: FrameInterpolationExportResult) {
        switch result {
        case .replaced(let outputURL):
            finishExport(id: id, outputURL: outputURL)
        case .cancelled:
            finishCancelled(id: id, reason: "任务已取消")
        case .failed(let message):
            finishFailed(id: id, message: message)
        }
    }

    private func finishExport(id: UUID, outputURL: URL) {
        runningTasks[id] = nil
        stopHeartbeat(id: id)
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            scheduleNext()
            return
        }

        let title = items[index].title
        let targetFPS = items[index].targetFPS
        items[index].status = .completed
        items[index].progress = 1
        items[index].outputURL = outputURL
        items[index].completedOperations.insert(.frameInterpolation)
        let completedItem = items.remove(at: index)
        markCompleted(videoURL: outputURL, title: title, targetFPS: targetFPS)
        frameInterpolationDebugPrint("补帧队列：任务完成，已原地替换源视频。路径=\(outputURL.path)")
        archive(completedItem, outcome: .completed, message: nil)
        NotificationCenter.default.post(
            name: .videoOptimizationFileDidReplace,
            object: outputURL,
            userInfo: [
                VideoOptimizationFileReplacementKind.userInfoKey:
                VideoOptimizationFileReplacementKind.frameInterpolation.rawValue
            ]
        )
        persistQueueCheckpointImmediately()
        scheduleNext()
    }

    private func markOperationCompleted(id: UUID, operation: FrameInterpolationQueueItem.Operation) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].completedOperations.insert(operation)
        items[index].currentOperation = nil
        items[index].progress = operation == .loopTransition ? 0.08 : items[index].progress
    }

    private func finishLoopAnalysis(id: UUID, message: String) {
        markOperationCompleted(id: id, operation: .loopTransition)
        guard let item = items.first(where: { $0.id == id }) else {
            runningTasks[id] = nil
            stopHeartbeat(id: id)
            scheduleNext()
            return
        }
        if nextPendingOperation(for: item) != nil {
            // 释放循环分析 lane，再由调度器等待独立的补帧 lane。
            // 这样其它视频的循环分析可与当前补帧并行，但本视频顺序不会反转。
            runningTasks[id] = nil
            stopHeartbeat(id: id)
            if let index = items.firstIndex(where: { $0.id == id }) {
                items[index].status = .waiting
                items[index].currentOperation = nil
                clearProgress(at: index)
            }
            persistQueueCheckpointImmediately()
            scheduleNext()
        } else {
            finishCompleted(id: id, message: message)
        }
    }

    private func finishCompleted(id: UUID, message: String?) {
        runningTasks[id] = nil
        stopHeartbeat(id: id)
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            scheduleNext()
            return
        }
        var item = items.remove(at: index)
        item.status = .completed
        item.progress = 1
        archive(item, outcome: .completed, message: message)
        persistQueueCheckpointImmediately()
        scheduleNext()
    }

    private func finishFailed(id: UUID, message: String) {
        runningTasks[id] = nil
        stopHeartbeat(id: id)
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            scheduleNext()
            return
        }
        var item = items.remove(at: index)
        item.status = .failed(message)
        switch item.currentOperation {
        case .frameInterpolation:
            _ = VideoOptimizationRecordStore.shared.append(
                .frameFailed,
                for: item.videoURL,
                detail: message,
                metadata: [
                    "targetFPS": String(item.targetFPS),
                    "title": item.title,
                ]
            )
        case .loopTransition:
            _ = VideoOptimizationRecordStore.shared.append(
                .loopFailed,
                for: item.videoURL,
                detail: message
            )
        case nil:
            break
        }
        archive(item, outcome: .failed, message: message)
        frameInterpolationDebugPrint("视频优化队列：任务失败。原因=\(message)，视频=\(item.videoURL.lastPathComponent)")
        persistQueueCheckpointImmediately()
        scheduleNext()
    }

    private func restoreQueueCheckpointIfNeeded() {
        guard BackgroundRuntimeRole.isHelper else { return }
        guard !didRestoreQueueCheckpoint else { return }
        didRestoreQueueCheckpoint = true

        // Keep Media / SceneBakes free of optimization sidecars: lift any historical
        // adjacent `*.waifux-optimization.json` into Application Support once per launch.
        let migrated = VideoOptimizationRecordStore.shared.migrateLegacyAdjacentSidecarsInLibraryRootsIfNeeded()
        if migrated > 0 {
            frameInterpolationDebugPrint(
                "视频优化：已将 \(migrated) 个媒体旁履历迁移到 Application Support。"
            )
        }

        let restoredState = VideoOptimizationQueueCheckpointStore.shared.loadState()
        let restoredItems = restoredState.items
        for request in restoredState.sourceRestoreRequests {
            sourceRestoreRequests[request.videoPath] = request
        }
        guard !restoredItems.isEmpty || !sourceRestoreRequests.isEmpty else {
            persistQueueCheckpointImmediately()
            return
        }

        let existingVideoPaths = Set(items.map { $0.videoURL.standardizedFileURL.path })
        let additions = restoredItems.filter {
            !existingVideoPaths.contains($0.videoURL.standardizedFileURL.path)
        }
        if !additions.isEmpty {
            items.append(contentsOf: additions)
            clearProgressForWaitingItems()
            frameInterpolationDebugPrint("视频优化队列：已从断点恢复 \(additions.count) 个未完成任务。")
        }
        if !sourceRestoreRequests.isEmpty {
            frameInterpolationDebugPrint("视频优化队列：已恢复 \(sourceRestoreRequests.count) 个 source-restore 请求。")
        }
        persistQueueCheckpointImmediately()
        scheduleNext()
    }

    /// Checkpoint writes are coalesced while media progress is changing, but
    /// every terminal removal flushes immediately so completed work cannot be
    /// resurrected after a relaunch.
    private func scheduleQueueCheckpointSave() {
        guard BackgroundRuntimeRole.isHelper else { return }
        queueCheckpointSaveTask?.cancel()
        let itemSnapshot = items
        let sourceRestoreSnapshot = Array(sourceRestoreRequests.values)
        queueCheckpointSaveTask = Task { [itemSnapshot, sourceRestoreSnapshot] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            VideoOptimizationQueueCheckpointStore.shared.save(
                itemSnapshot,
                sourceRestoreRequests: sourceRestoreSnapshot
            )
        }
    }

    private func persistQueueCheckpointImmediately() {
        guard BackgroundRuntimeRole.isHelper else { return }

        queueCheckpointSaveTask?.cancel()
        VideoOptimizationQueueCheckpointStore.shared.save(
            items,
            sourceRestoreRequests: Array(sourceRestoreRequests.values)
        )
    }

    private func normalizedOperations(_ operations: [FrameInterpolationQueueItem.Operation]) -> [FrameInterpolationQueueItem.Operation] {
        FrameInterpolationQueueItem.Operation.allCases.filter { operations.contains($0) }
    }

    private struct LibraryOptimizationTarget {
        let videoURL: URL
        let title: String
    }

    private func libraryOptimizationTargets(in folder: LibraryFolder) -> [LibraryOptimizationTarget] {
        switch (folder.contentType, folder.collection) {
        case (.media, .downloads):
            return MediaLibraryService.shared.downloadedItems(inFolder: folder.id).compactMap { record in
                makeLibraryOptimizationTarget(
                    videoURL: optimizableVideoURL(forDownloadRecord: record),
                    title: record.item.title
                )
            }
        case (.media, .favorites):
            return MediaLibraryService.shared.favoriteItems(inFolder: folder.id).compactMap { item in
                makeLibraryOptimizationTarget(
                    videoURL: optimizableVideoURL(
                        forMediaItem: item,
                        localURL: MediaLibraryService.shared.localFileURLIfAvailable(for: item)
                    ),
                    title: item.title
                )
            }
        case (.wallpaper, .downloads):
            return WallpaperLibraryService.shared.downloadedWallpapers(inFolder: folder.id).compactMap { record in
                makeLibraryOptimizationTarget(
                    videoURL: optimizableVideoURL(from: record.localFileURL),
                    title: record.wallpaper.title ?? record.localFileURL.deletingPathExtension().lastPathComponent
                )
            }
        case (.wallpaper, .favorites):
            return WallpaperLibraryService.shared.favoriteWallpapers(inFolder: folder.id).compactMap { wallpaper in
                makeLibraryOptimizationTarget(
                    videoURL: optimizableVideoURL(
                        from: WallpaperLibraryService.shared.localFileURLIfAvailable(for: wallpaper)
                    ),
                    title: wallpaper.title ?? wallpaper.id
                )
            }
        }
    }

    private func makeLibraryOptimizationTarget(videoURL: URL?, title: String) -> LibraryOptimizationTarget? {
        guard let videoURL else { return nil }
        return LibraryOptimizationTarget(videoURL: videoURL, title: title)
    }

    private func archive(
        _ item: FrameInterpolationQueueItem,
        outcome: VideoOptimizationHistoryRecord.Outcome,
        message: String?
    ) {
        ensureHistoryLoaded()
        let record = VideoOptimizationHistoryRecord(
            id: item.id,
            videoPath: item.videoURL.standardizedFileURL.path,
            title: item.title,
            targetFPS: item.targetFPS,
            source: item.source,
            operations: item.operations,
            completedOperations: item.completedOperations.sorted { $0.rawValue < $1.rawValue },
            outcome: outcome,
            message: message,
            completedAt: Date()
        )
        history.insert(record, at: 0)
        history = Array(history.prefix(200))
        saveHistory()
    }

    private static func formatSeconds(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "未知" }
        if seconds < 60 { return "\(String(format: "%.1f", seconds))s" }
        return "\(Int(seconds) / 60)m\(Int(seconds) % 60)s"
    }

    var activeProcessingItem: FrameInterpolationQueueItem? {
        items.first { item in
            if case .analyzing = item.status { return true }
            if case .running = item.status { return true }
            return false
        }
    }

    var remainingWorkCount: Int {
        return items.filter { item in
            !runningTasks.keys.contains(item.id) && !item.isTerminalForCleanup
        }.count
    }

    private func ensureInterpolationRecordsLoaded() {
        guard !interpolationRecordsLoaded else { return }
        completedInterpolationItems = Self.loadInterpolationRecords(key: Self.completedInterpolationRecordsKey)
        blacklistedInterpolationItems = Self.loadInterpolationRecords(key: Self.blacklistedInterpolationRecordsKey)
        interpolationRecordsLoaded = true
    }

    private func saveInterpolationRecords() {
        Self.saveInterpolationRecords(completedInterpolationItems, key: Self.completedInterpolationRecordsKey)
        Self.saveInterpolationRecords(blacklistedInterpolationItems, key: Self.blacklistedInterpolationRecordsKey)
    }

    private func makeInterpolationRecord(videoURL: URL, title: String, targetFPS: Int) -> FrameInterpolationRecordItem {
        FrameInterpolationRecordItem(
            id: interpolationRecordID(for: videoURL),
            videoPath: videoURL.standardizedFileURL.path,
            title: title.isEmpty ? videoURL.deletingPathExtension().lastPathComponent : title,
            targetFPS: targetFPS,
            recordedAt: Date()
        )
    }

    private func interpolationRecordID(for videoURL: URL) -> String {
        videoURL.standardizedFileURL.path
    }

    private static func loadInterpolationRecords(key: String) -> [FrameInterpolationRecordItem] {
        guard let data = WaifuXPreferences.shared.data(forKey: key),
              let records = try? JSONDecoder().decode([FrameInterpolationRecordItem].self, from: data) else {
            return []
        }
        return records.sorted { $0.recordedAt > $1.recordedAt }
    }

    private static func saveInterpolationRecords(_ records: [FrameInterpolationRecordItem], key: String) {
        if let data = try? JSONEncoder().encode(records) {
            WaifuXPreferences.shared.set(data, forKey: key)
        }
    }

    private func ensureHistoryLoaded() {
        guard !historyLoaded else { return }
        defer { historyLoaded = true }
        guard let data = WaifuXPreferences.shared.data(forKey: Self.historyKey),
              let records = try? JSONDecoder().decode([VideoOptimizationHistoryRecord].self, from: data) else {
            return
        }
        history = records.sorted { $0.completedAt > $1.completedAt }
    }

    private func saveHistory() {
        guard BackgroundRuntimeRole.isHelper else { return }

        guard let data = try? JSONEncoder().encode(history) else { return }
        WaifuXPreferences.shared.set(data, forKey: Self.historyKey)
    }
}

private actor VideoFrameInterpolationExportCoordinator {
    static let shared = VideoFrameInterpolationExportCoordinator()
    private let maxConcurrentExports = 1
    private var activeExportCount = 0
    private var exportWaiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []
    private var tasks: [String: Task<FrameInterpolationExportResult, Never>] = [:]

    func export(
        key: String,
        sourceURL: URL,
        outputURL: URL,
        outputContainer: VideoOptimizationOutputContainer,
        targetFPS: Int,
        progress: (@Sendable (FrameInterpolationExportProgress) -> Void)? = nil
    ) async -> FrameInterpolationExportResult {
        if let task = tasks[key] {
            frameInterpolationDebugPrint("导出队列：同一个视频已有任务，复用当前任务。视频=\(sourceURL.lastPathComponent)")
            return await task.value
        }

        let task: Task<FrameInterpolationExportResult, Never> = Task.detached(priority: .utility) {
            let videoName = sourceURL.lastPathComponent
            do {
                try await VideoFrameInterpolationExportCoordinator.shared.acquireExportSlot(videoName: videoName)
            } catch {
                frameInterpolationDebugPrint("导出队列：等待补帧槽位时已取消。视频=\(videoName)")
                return .cancelled
            }

            let result = await VideoFrameInterpolationExporter.performExport(
                sourceURL: sourceURL,
                outputURL: outputURL,
                outputContainer: outputContainer,
                targetFPS: targetFPS,
                progress: progress
            )
            await VideoFrameInterpolationExportCoordinator.shared.releaseExportSlot(videoName: videoName)
            return result
        }
        tasks[key] = task
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        tasks.removeValue(forKey: key)
        return result
    }

    private func acquireExportSlot(videoName: String) async throws {
        if activeExportCount < maxConcurrentExports {
            activeExportCount += 1
            frameInterpolationDebugPrint("导出队列：开始补帧。当前并发=\(activeExportCount)/\(maxConcurrentExports)，视频=\(videoName)")
            return
        }

        frameInterpolationDebugPrint("导出队列：补帧任务排队等待。当前并发=\(activeExportCount)/\(maxConcurrentExports)，视频=\(videoName)")
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                exportWaiters.append((id: waiterID, continuation: continuation))
            }
        } onCancel: {
            Task {
                await VideoFrameInterpolationExportCoordinator.shared.cancelExportWaiter(id: waiterID, videoName: videoName)
            }
        }
        try Task.checkCancellation()
        frameInterpolationDebugPrint("导出队列：排队任务获得补帧槽位。当前并发=\(activeExportCount)/\(maxConcurrentExports)，视频=\(videoName)")
    }

    private func releaseExportSlot(videoName: String) {
        if exportWaiters.isEmpty {
            activeExportCount = max(0, activeExportCount - 1)
        } else {
            let waiter = exportWaiters.removeFirst()
            waiter.continuation.resume()
        }
        frameInterpolationDebugPrint("导出队列：补帧任务结束。当前并发=\(activeExportCount)/\(maxConcurrentExports)，视频=\(videoName)")
    }

    private func cancelExportWaiter(id: UUID, videoName: String) {
        guard let index = exportWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = exportWaiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
        frameInterpolationDebugPrint("导出队列：已移除取消的排队任务。视频=\(videoName)")
    }
}

enum VideoFrameInterpolationExporter {
#if DEBUG
    private static let testHooks = FrameInterpolationExporterTestHooks()

    static func setSourceReplacementTestHook(_ hook: (@Sendable () -> Void)?) {
        testHooks.setSourceReplacementHook(hook)
    }
#endif

    static func exportIfNeeded(
        sourceURL: URL,
        targetFPS: Int,
        progress: (@Sendable (FrameInterpolationExportProgress) -> Void)? = nil
    ) async -> FrameInterpolationExportResult {
        guard let outputContainer = VideoOptimizationOutputContainer(sourceURL: sourceURL) else {
            return .failed("原地补帧仅支持 MP4、MOV 和 M4V；MKV 请先转码为受支持的容器")
        }

        let outputURL = temporaryOutputURL(for: sourceURL, outputContainer: outputContainer)
        try? FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        frameInterpolationDebugPrint("导出服务：临时输出路径准备完成。输出：\(outputURL.path)")
        let key = exportTaskKey(for: sourceURL, targetFPS: targetFPS)
        return await VideoFrameInterpolationExportCoordinator.shared.export(
            key: key,
            sourceURL: sourceURL,
            outputURL: outputURL,
            outputContainer: outputContainer,
            targetFPS: targetFPS,
            progress: progress
        )
    }

    fileprivate static func performExport(
        sourceURL: URL,
        outputURL: URL,
        outputContainer: VideoOptimizationOutputContainer,
        targetFPS: Int,
        progress: (@Sendable (FrameInterpolationExportProgress) -> Void)? = nil
    ) async -> FrameInterpolationExportResult {
        try? FileManager.default.removeItem(at: outputURL)
        guard !Task.isCancelled else {
            frameInterpolationDebugPrint("导出任务：启动前已取消。视频=\(sourceURL.lastPathComponent)")
            return .cancelled
        }
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            frameInterpolationDebugPrint("导出任务：源视频不存在。视频=\(sourceURL.lastPathComponent)")
            return .failed("源视频已不存在")
        }

        let asset = AVURLAsset(url: sourceURL)
        frameInterpolationDebugPrint("导出任务：离线补帧开始。当前只使用算法=optical-flow，不执行降级逻辑，目标 FPS=\(targetFPS)，视频=\(sourceURL.lastPathComponent)。")
        guard let exportInfo = await makeFrameInterpolationExportInfo(asset: asset, targetFPS: targetFPS) else {
            frameInterpolationDebugPrint("导出任务：读取视频轨道、尺寸、方向、码率或时长失败。")
            return .failed("无法读取视频轨道或媒体参数")
        }
        guard !Task.isCancelled else {
            frameInterpolationDebugPrint("导出任务：读取参数后已取消。视频=\(sourceURL.lastPathComponent)")
            return .cancelled
        }
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            frameInterpolationDebugPrint("导出任务：读取参数后源视频已不存在。视频=\(sourceURL.lastPathComponent)")
            return .failed("源视频已不存在")
        }
        guard SystemMemoryPressure.hasRoomForFrameInterpolationExport(width: exportInfo.width, height: exportInfo.height) else {
            let requiredBytes = SystemMemoryPressure.estimatedFrameInterpolationWorkingSetBytes(
                width: exportInfo.width,
                height: exportInfo.height
            )
            let availableBytes = SystemMemoryPressure.approximateReclaimableBytes()
            frameInterpolationDebugPrint(
                "导出任务：跳过补帧，当前可回收内存不足。需要≈\(formatBytes(requiredBytes))，可用≈\(formatBytes(availableBytes))，视频=\(sourceURL.lastPathComponent)。"
            )
            return .failed("可用内存不足，未开始补帧")
        }

        try? FileManager.default.removeItem(at: outputURL)
        frameInterpolationDebugPrint("导出任务：当前使用算法：optical-flow。")
        let succeeded = autoreleasepool {
            frameInterpolationExport(
                asset: asset,
                info: exportInfo,
                outputURL: outputURL,
                outputContainer: outputContainer,
                targetFPS: targetFPS,
                progress: progress
            )
        }

        guard succeeded else {
            frameInterpolationDebugPrint("导出任务：optical-flow 导出失败；本轮不降级，继续使用原视频播放。")
            try? FileManager.default.removeItem(at: outputURL)
            return Task.isCancelled ? .cancelled : .failed("optical-flow 导出失败")
        }
        guard !Task.isCancelled else {
            frameInterpolationDebugPrint("导出任务：写入完成后已取消，保留原视频。视频=\(sourceURL.lastPathComponent)")
            try? FileManager.default.removeItem(at: outputURL)
            return .cancelled
        }
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            frameInterpolationDebugPrint("导出任务：写入完成后源视频已不存在。视频=\(sourceURL.lastPathComponent)")
            try? FileManager.default.removeItem(at: outputURL)
            return .failed("源视频已不存在")
        }

        do {
            try replaceSourceVideo(sourceURL, with: outputURL)
            frameInterpolationDebugPrint("导出任务：补帧完成，已替换源视频。算法=optical-flow，路径=\(sourceURL.path)")
#if DEBUG
            testHooks.runSourceReplacementHook()
#endif
            return .replaced(sourceURL)
        } catch {
            frameInterpolationDebugPrint("导出任务：替换源视频失败。\(error.localizedDescription)")
            try? FileManager.default.removeItem(at: outputURL)
            return .failed("替换源视频失败：\(error.localizedDescription)")
        }
    }

    private struct FrameInterpolationExportInfo {
        let videoTrack: AVAssetTrack
        let audioTrack: AVAssetTrack?
        let audioFormatHint: CMFormatDescription?
        let width: Int
        let height: Int
        let preferredTransform: CGAffineTransform
        let duration: CMTime
        let sourceFPS: Double
        let bitrate: Double
    }

    private static func makeFrameInterpolationExportInfo(asset: AVURLAsset, targetFPS: Int) async -> FrameInterpolationExportInfo? {
        guard targetFPS > 0,
              let videoTrack = try? await asset.loadTracks(withMediaType: .video).first,
              let naturalSize = try? await videoTrack.load(.naturalSize),
              let preferredTransform = try? await videoTrack.load(.preferredTransform),
              let duration = try? await asset.load(.duration) else {
            return nil
        }

        let transformedRect = CGRect(origin: .zero, size: naturalSize)
            .applying(preferredTransform)
            .standardized
        let renderSize = CGSize(
            width: max(2, abs(transformedRect.width)),
            height: max(2, abs(transformedRect.height))
        )

        let nominalFPS = (try? await videoTrack.load(.nominalFrameRate)).map(Double.init) ?? 0
        let minFrameDuration = (try? await videoTrack.load(.minFrameDuration)) ?? .invalid
        let fallbackFPS = minFrameDuration.isValid && minFrameDuration.seconds.isFinite && minFrameDuration.seconds > 0
            ? 1.0 / minFrameDuration.seconds
            : 30.0
        let sourceFPS = nominalFPS > 0 ? nominalFPS : fallbackFPS
        let bitrate = Double((try? await videoTrack.load(.estimatedDataRate)) ?? 0)
        let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first
        let audioFormatDescriptions = try? await audioTrack?.load(.formatDescriptions)
        let audioFormatHint = audioFormatDescriptions?.first

        frameInterpolationDebugPrint("导出任务：离线补帧参数已准备，源 FPS=\(String(format: "%.2f", sourceFPS))，输出尺寸=\(Int(renderSize.width))x\(Int(renderSize.height))。")
        return FrameInterpolationExportInfo(
            videoTrack: videoTrack,
            audioTrack: audioTrack,
            audioFormatHint: audioFormatHint,
            width: Int(renderSize.width.rounded()),
            height: Int(renderSize.height.rounded()),
            preferredTransform: preferredTransform,
            duration: duration,
            sourceFPS: sourceFPS,
            bitrate: bitrate
        )
    }

    private static func frameInterpolationExport(
        asset: AVAsset,
        info: FrameInterpolationExportInfo,
        outputURL: URL,
        outputContainer: VideoOptimizationOutputContainer,
        targetFPS: Int,
        progress: (@Sendable (FrameInterpolationExportProgress) -> Void)? = nil
    ) -> Bool {
        do {
            let reader = try AVAssetReader(asset: asset)
            let writer = try AVAssetWriter(outputURL: outputURL, fileType: outputContainer.fileType)
            writer.shouldOptimizeForNetworkUse = false

            let videoOutput = AVAssetReaderTrackOutput(
                track: info.videoTrack,
                outputSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferMetalCompatibilityKey as String: true,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:]
                ]
            )
            videoOutput.alwaysCopiesSampleData = false
            guard reader.canAdd(videoOutput) else {
                frameInterpolationDebugPrint("导出任务：无法添加视频读取输出。")
                return false
            }
            reader.add(videoOutput)

            let fpsRatio = max(1.0, Double(targetFPS) / max(1.0, info.sourceFPS))
            let bitrate = Int(min(max(info.bitrate * fpsRatio, 4_000_000), 80_000_000))
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: info.width,
                AVVideoHeightKey: info.height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: bitrate,
                    AVVideoExpectedSourceFrameRateKey: targetFPS,
                    AVVideoMaxKeyFrameIntervalKey: targetFPS * 2,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                    AVVideoAllowFrameReorderingKey: false
                ] as [String: Any]
            ]

            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            videoInput.expectsMediaDataInRealTime = false
            videoInput.transform = info.preferredTransform
            guard writer.canAdd(videoInput) else {
                frameInterpolationDebugPrint("导出任务：无法添加视频写入输入。")
                return false
            }
            writer.add(videoInput)

            let audioCopyState = FrameInterpolationAudioCopyState()
            let audioCopyGroup = DispatchGroup()
            var audioPassthrough: FrameInterpolationAudioPassthrough?
            if let audioTrack = info.audioTrack {
                let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
                output.alwaysCopiesSampleData = false
                guard reader.canAdd(output) else {
                    frameInterpolationDebugPrint("导出任务：无法添加音频读取输出。")
                    return false
                }
                reader.add(output)

                let input = AVAssetWriterInput(
                    mediaType: .audio,
                    outputSettings: nil,
                    sourceFormatHint: info.audioFormatHint
                )
                input.expectsMediaDataInRealTime = false
                guard writer.canAdd(input) else {
                    frameInterpolationDebugPrint("导出任务：输出容器 \(outputContainer.displayName) 不支持保留原始音轨。")
                    return false
                }
                writer.add(input)
                audioPassthrough = FrameInterpolationAudioPassthrough(
                    reader: reader,
                    writer: writer,
                    output: output,
                    input: input,
                    state: audioCopyState,
                    group: audioCopyGroup
                )
            }

            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: videoInput,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: info.width,
                    kCVPixelBufferHeightKey as String: info.height,
                    kCVPixelBufferMetalCompatibilityKey as String: true,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:]
                ]
            )
            let pixelBufferPool = adaptor.pixelBufferPool
            var exportCompleted = false
            defer {
                if !exportCompleted {
                    if reader.status == .reading {
                        reader.cancelReading()
                    }
                    if writer.status == .writing {
                        writer.cancelWriting()
                    }
                }
                if let pixelBufferPool {
                    CVPixelBufferPoolFlush(pixelBufferPool, CVPixelBufferPoolFlushFlags.excessBuffers)
                }
                FrameInterpolationMetalInterpolator.shared.flushTextureCache()
            }

            guard reader.startReading(), writer.startWriting() else {
                frameInterpolationDebugPrint("导出任务：reader/writer 启动失败。reader=\(reader.error?.localizedDescription ?? "nil") writer=\(writer.error?.localizedDescription ?? "nil")")
                return false
            }
            writer.startSession(atSourceTime: .zero)

            if let audioPassthrough {
                let audioQueue = DispatchQueue(label: "waifux.frame-interpolation.audio-copy", qos: .utility)
                audioPassthrough.start(on: audioQueue)
            }

            let targetFrameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFPS))
            let duration = info.duration
            let durationSeconds = duration.seconds.isFinite && duration.seconds > 0 ? duration.seconds : 0
            let totalTargetFrames = durationSeconds > 0
                ? max(1, Int64((durationSeconds * Double(targetFPS)).rounded(.up)))
                : 0
            let exportStartDate = Date()
            var outputFrameIndex: Int64 = 0
            var writtenFrameCount: Int64 = 0
            var opticalFlowFrameCount: Int64 = 0
            var sourcePairCount: Int64 = 0
            var lastProgressLogFrame: Int64 = -Int64(max(1, targetFPS))

            frameInterpolationDebugPrint(
                "导出任务：进度初始化。算法==Vision optical-flow + Metal GPU warp，目标总帧数=\(totalTargetFrames > 0 ? "\(totalTargetFrames)" : "未知")，视频时长=\(formatSeconds(durationSeconds))，源 FPS=\(String(format: "%.2f", info.sourceFPS))，目标 FPS=\(targetFPS)。"
            )
            frameInterpolationDebugPrint("导出任务：使用 Vision optical-flow + Metal GPU warp；Metal 不可用或 GPU 执行失败时终止本次补帧。")

            func outputTime(for index: Int64) -> CMTime {
                CMTimeMultiply(targetFrameDuration, multiplier: Int32(index))
            }

            func waitUntilReady() -> Bool {
                while !videoInput.isReadyForMoreMediaData {
                    if Task.isCancelled { return false }
                    if writer.status == .failed || reader.status == .failed || reader.status == .cancelled {
                        return false
                    }
                    Thread.sleep(forTimeInterval: 0.002)
                }
                return true
            }

            func emitProgress(
                stage: String,
                presentationTime: CMTime? = nil,
                shouldLog: Bool = true
            ) {
                let elapsed = Date().timeIntervalSince(exportStartDate)
                let speed = elapsed > 0 ? Double(writtenFrameCount) / elapsed : 0
                let remainingFrames = totalTargetFrames > 0 ? max(0, totalTargetFrames - writtenFrameCount) : 0
                let eta = speed > 0 && remainingFrames > 0 ? Double(remainingFrames) / speed : 0
                progress?(FrameInterpolationExportProgress(
                    progress: totalTargetFrames > 0 ? min(1, max(0, Double(writtenFrameCount) / Double(totalTargetFrames))) : 0,
                    writtenFrames: writtenFrameCount,
                    totalFrames: totalTargetFrames > 0 ? totalTargetFrames : nil,
                    opticalFlowFrames: opticalFlowFrameCount,
                    elapsedSeconds: elapsed,
                    remainingSeconds: eta > 0 ? eta : nil,
                    currentStage: stage
                ))

                guard shouldLog, let presentationTime, durationSeconds > 0 else { return }
                let seconds = presentationTime.seconds
                let percent = totalTargetFrames > 0
                    ? min(100, max(0, Double(writtenFrameCount) / Double(totalTargetFrames) * 100))
                    : min(100, max(0, seconds / durationSeconds * 100))
                frameInterpolationDebugPrint(
                    "导出进度：阶段=\(stage)，算法=optical-flow，\(String(format: "%.1f", percent))%，已写=\(writtenFrameCount)/\(totalTargetFrames > 0 ? "\(totalTargetFrames)" : "未知") 帧，光流帧=\(opticalFlowFrameCount)，源帧对=\(sourcePairCount)，视频时间=\(formatSeconds(seconds))/\(formatSeconds(durationSeconds))，耗时=\(formatSeconds(elapsed))，速度=\(String(format: "%.1f", speed)) 帧/秒，预计剩余=\(eta > 0 ? formatSeconds(eta) : "未知")。"
                )
            }

            func appendFrame(_ pixelBuffer: CVPixelBuffer, at presentationTime: CMTime) -> Bool {
                guard waitUntilReady() else { return false }
                guard !Task.isCancelled else { return false }
                guard audioCopyState.failureMessage == nil else { return false }
                guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
                    frameInterpolationDebugPrint("导出任务：追加帧失败。time=\(presentationTime.seconds)，error=\(writer.error?.localizedDescription ?? "未知错误")")
                    return false
                }
                writtenFrameCount += 1
                let progressLogInterval = Int64(max(1, targetFPS))
                if writtenFrameCount - lastProgressLogFrame >= progressLogInterval || writtenFrameCount == totalTargetFrames {
                    lastProgressLogFrame = writtenFrameCount
                    emitProgress(stage: "已写入第 \(writtenFrameCount) 帧", presentationTime: presentationTime)
                }
                return true
            }

            guard var currentSample = videoOutput.copyNextSampleBuffer(),
                  var currentPixelBuffer = CMSampleBufferGetImageBuffer(currentSample) else {
                frameInterpolationDebugPrint("导出任务：读取首帧失败。")
                writer.cancelWriting()
                reader.cancelReading()
                return false
            }
            defer {
                CMSampleBufferInvalidate(currentSample)
            }

            while let nextSample = videoOutput.copyNextSampleBuffer() {
                var didPromoteNextSample = false
                defer {
                    if !didPromoteNextSample {
                        CMSampleBufferInvalidate(nextSample)
                    }
                }
                if Task.isCancelled {
                    frameInterpolationDebugPrint("导出任务：收到取消请求，停止写入临时文件。")
                    writer.cancelWriting()
                    reader.cancelReading()
                    return false
                }
                sourcePairCount += 1
                let nextPTS = CMSampleBufferGetPresentationTimeStamp(nextSample)
                let currentPTS = CMSampleBufferGetPresentationTimeStamp(currentSample)
                guard let nextPixelBuffer = CMSampleBufferGetImageBuffer(nextSample) else {
                    continue
                }
                var opticalFlowBufferForPair: CVPixelBuffer?
                while outputTime(for: outputFrameIndex) < nextPTS {
                    let presentationTime = outputTime(for: outputFrameIndex)
                    let alpha = interpolationAlpha(currentPTS: currentPTS, nextPTS: nextPTS, outputPTS: presentationTime)
                    let pixelBuffer: CVPixelBuffer?
                    if alpha > 0.001, alpha < 0.999 {
                        opticalFlowFrameCount += 1
                        if opticalFlowBufferForPair == nil {
                            emitProgress(
                                stage: "正在计算源帧对 \(sourcePairCount) 的 optical-flow 场",
                                presentationTime: presentationTime
                            )
                            let flowStart = Date()
                            opticalFlowBufferForPair = autoreleasepool {
                                makeOpticalFlowBuffer(current: currentPixelBuffer, next: nextPixelBuffer)
                            }
                            let flowElapsed = Date().timeIntervalSince(flowStart)
                            guard opticalFlowBufferForPair != nil else {
                                frameInterpolationDebugPrint("导出任务：源帧对 \(sourcePairCount) 的 optical-flow 场计算失败，用时=\(formatSeconds(flowElapsed))。")
                                writer.cancelWriting()
                                reader.cancelReading()
                                return false
                            }
                            frameInterpolationDebugPrint("导出任务：源帧对 \(sourcePairCount) 的 optical-flow 场计算完成，用时=\(formatSeconds(flowElapsed))，将复用生成本组中间帧。")
                        }
                        emitProgress(
                            stage: "正在 warp 第 \(opticalFlowFrameCount) 个 optical-flow 中间帧（源帧对 \(sourcePairCount)，alpha=\(String(format: "%.2f", alpha))）",
                            presentationTime: presentationTime
                        )
                        pixelBuffer = autoreleasepool {
                            makeOpticalFlowWarpedPixelBuffer(
                                current: currentPixelBuffer,
                                next: nextPixelBuffer,
                                flow: opticalFlowBufferForPair!,
                                alpha: alpha,
                                adaptor: adaptor
                            )
                        }
                    } else {
                        pixelBuffer = alpha >= 0.999 ? nextPixelBuffer : currentPixelBuffer
                    }
                    guard let pixelBuffer else {
                        frameInterpolationDebugPrint("导出任务：算法 optical-flow 生成帧失败。time=\(presentationTime.seconds)")
                        writer.cancelWriting()
                        reader.cancelReading()
                        return false
                    }
                    guard appendFrame(pixelBuffer, at: presentationTime) else {
                        writer.cancelWriting()
                        reader.cancelReading()
                        return false
                    }
                    outputFrameIndex += 1
                }
                opticalFlowBufferForPair = nil
                CMSampleBufferInvalidate(currentSample)
                currentSample = nextSample
                currentPixelBuffer = nextPixelBuffer
                didPromoteNextSample = true
            }

            while outputTime(for: outputFrameIndex) < duration {
                if Task.isCancelled {
                    frameInterpolationDebugPrint("导出任务：收到取消请求，停止写入尾帧。")
                    writer.cancelWriting()
                    reader.cancelReading()
                    return false
                }
                let presentationTime = outputTime(for: outputFrameIndex)
                guard appendFrame(currentPixelBuffer, at: presentationTime) else {
                    writer.cancelWriting()
                    reader.cancelReading()
                    return false
                }
                outputFrameIndex += 1
            }

            videoInput.markAsFinished()
            while audioCopyGroup.wait(timeout: .now() + .milliseconds(50)) == .timedOut {
                if Task.isCancelled {
                    writer.cancelWriting()
                    reader.cancelReading()
                    return false
                }
            }
            if let audioFailure = audioCopyState.failureMessage {
                frameInterpolationDebugPrint("导出任务：保留音轨失败。\(audioFailure)")
                return false
            }

            let finishSemaphore = DispatchSemaphore(value: 0)
            writer.finishWriting { finishSemaphore.signal() }
            finishSemaphore.wait()

            guard writer.status == .completed else {
                frameInterpolationDebugPrint("导出任务：writer 完成状态异常。status=\(writer.status.rawValue)，error=\(writer.error?.localizedDescription ?? "未知错误")")
                return false
            }

            frameInterpolationDebugPrint("导出任务：算法 optical-flow 导出完成，输出 FPS=\(targetFPS)，总帧数=\(writtenFrameCount)。")
            exportCompleted = true
            return true
        } catch {
            frameInterpolationDebugPrint("导出任务：异常失败。\(error.localizedDescription)")
            return false
        }
    }

    private static func interpolationAlpha(currentPTS: CMTime, nextPTS: CMTime, outputPTS: CMTime) -> Double {
        let span = nextPTS - currentPTS
        guard span.seconds.isFinite, span.seconds > 0 else { return 0 }
        let offset = outputPTS - currentPTS
        guard offset.seconds.isFinite else { return 0 }
        return min(1, max(0, offset.seconds / span.seconds))
    }

    private static func makeOpticalFlowBuffer(
        current: CVPixelBuffer,
        next: CVPixelBuffer
    ) -> CVPixelBuffer? {
        guard CVPixelBufferGetWidth(current) == CVPixelBufferGetWidth(next),
              CVPixelBufferGetHeight(current) == CVPixelBufferGetHeight(next),
              CVPixelBufferGetPixelFormatType(current) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetPixelFormatType(next) == kCVPixelFormatType_32BGRA else {
            return nil
        }

        do {
            let request = VNGenerateOpticalFlowRequest(targetedCVPixelBuffer: next, options: [:])
            request.computationAccuracy = .medium
            request.usesCPUOnly = false
            request.outputPixelFormat = kCVPixelFormatType_TwoComponent32Float
            let handler = VNImageRequestHandler(cvPixelBuffer: current, options: [:])
            try handler.perform([request])
            return request.results?.first?.pixelBuffer
        } catch {
            frameInterpolationDebugPrint("导出任务：optical-flow 计算失败：\(error.localizedDescription)")
            return nil
        }
    }

    private static func makeOpticalFlowWarpedPixelBuffer(
        current: CVPixelBuffer,
        next: CVPixelBuffer,
        flow: CVPixelBuffer,
        alpha: Double,
        adaptor: AVAssetWriterInputPixelBufferAdaptor
    ) -> CVPixelBuffer? {
        guard let output = makePixelBuffer(from: adaptor) else { return nil }
        guard CVPixelBufferGetWidth(current) == CVPixelBufferGetWidth(flow),
              CVPixelBufferGetHeight(current) == CVPixelBufferGetHeight(flow),
              CVPixelBufferGetPixelFormatType(flow) == kCVPixelFormatType_TwoComponent32Float else {
            return nil
        }

        if FrameInterpolationMetalInterpolator.shared.interpolate(
            current: current,
            next: next,
            flow: flow,
            alpha: alpha,
            output: output
        ) {
            return output
        }

        frameInterpolationDebugPrint("导出任务：Metal GPU warp 失败，已按 GPU-only 策略终止本次补帧。")
        return nil
    }

    private static func makePixelBuffer(from adaptor: AVAssetWriterInputPixelBufferAdaptor) -> CVPixelBuffer? {
        guard let pool = adaptor.pixelBufferPool else { return nil }
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        guard status == kCVReturnSuccess else { return nil }
        return pixelBuffer
    }

    private static func formatSeconds(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "未知" }
        if seconds < 60 {
            return "\(String(format: "%.1f", seconds))s"
        }
        let minutes = Int(seconds) / 60
        let remainingSeconds = Int(seconds) % 60
        return "\(minutes)m\(remainingSeconds)s"
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        let gib = Double(bytes) / 1024.0 / 1024.0 / 1024.0
        return "\(String(format: "%.2f", gib))GB"
    }

    private static func temporaryOutputURL(
        for sourceURL: URL,
        outputContainer: VideoOptimizationOutputContainer
    ) -> URL {
        outputContainer.temporarySiblingURL(for: sourceURL, operation: "interpolating")
    }

    private static func replaceSourceVideo(_ sourceURL: URL, with temporaryURL: URL) throws {
        try VideoOptimizationFileReplacement.replaceSourceVideo(sourceURL, with: temporaryURL)
    }

    private static func exportTaskKey(for sourceURL: URL, targetFPS: Int) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let size = attrs?[.size] as? UInt64 ?? 0
        let modified = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let raw = "\(sourceURL.standardizedFileURL.path)|\(size)|\(modified)|fps=\(targetFPS)|algorithm=optical-flow-only-v1"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
