import Foundation

/// A single global lane for Scene offline baking.
///
/// `wallpaper-wgpu bake` is expensive enough that allowing multiple callers to
/// start it directly causes both memory spikes and inconsistent per-wallpaper UI.
/// This service owns the work queue while the completed artifact remains durable
/// in `MediaDownloadRecord` and beside the resulting MP4.
@MainActor
final class SceneBakeQueueService: ObservableObject {
    static let shared = SceneBakeQueueService()

    enum JobState: Equatable {
        case preparing
        case baking
    }

    enum WallpaperStatus: Equatable {
        case idle
        case preparing(position: Int)
        case baking(progress: Double)
        case ready
        case failed(String)
    }

    struct QueueItem: Identifiable {
        let id: UUID
        let queueKey: String
        let itemID: String?
        let title: String
        let sourcePath: String
        let cacheItemID: String
        let renderer: SceneBakeRenderer
        let durationSeconds: Double?
        let forceRebake: Bool
        var state: JobState
        var progress: Double

        fileprivate init(
            queueKey: String,
            itemID: String?,
            title: String,
            sourcePath: String,
            cacheItemID: String,
            renderer: SceneBakeRenderer,
            durationSeconds: Double?,
            forceRebake: Bool
        ) {
            id = UUID()
            self.queueKey = queueKey
            self.itemID = itemID
            self.title = title
            self.sourcePath = sourcePath
            self.cacheItemID = cacheItemID
            self.renderer = renderer
            self.durationSeconds = durationSeconds
            self.forceRebake = forceRebake
            state = .preparing
            progress = 0
        }
    }

    typealias Completion = @MainActor (Result<SceneBakeArtifact, Error>) -> Void

    @Published private(set) var items: [QueueItem] = []
    @Published private(set) var latestFailures: [String: String] = [:]

    private var completions: [UUID: [Completion]] = [:]
    private var processingTask: Task<Void, Never>?

    private init() {}

    var activeProcessingItem: QueueItem? {
        items.first
    }

    var remainingWorkCount: Int {
        max(0, items.count - (activeProcessingItem == nil ? 0 : 1))
    }

    func status(for record: MediaDownloadRecord?) -> WallpaperStatus {
        guard let record else { return .idle }
        let queueKey = record.id
        if let item = items.first(where: { $0.queueKey == queueKey }) {
            switch item.state {
            case .preparing:
                let position = (items.firstIndex(where: { $0.id == item.id }) ?? 0) + 1
                return .preparing(position: position)
            case .baking:
                return .baking(progress: item.progress)
            }
        }
        if SceneOfflineBakeService.hasCachedArtifact(record: record) {
            return .ready
        }
        if let failure = record.sceneBakeFailure {
            return .failed(failure)
        }
        if let failure = latestFailures[queueKey] {
            return .failed(failure)
        }
        return .idle
    }

    func isActive(for record: MediaDownloadRecord?) -> Bool {
        guard let record else { return false }
        return items.contains { $0.queueKey == record.id }
    }

    func enqueue(
        record: MediaDownloadRecord,
        renderer: SceneBakeRenderer = .wallpaperWgpu,
        durationSeconds: Double? = nil,
        forceRebake: Bool = false,
        completion: Completion? = nil
    ) {
        let queueKey = record.id
        if !forceRebake, SceneOfflineBakeService.hasCachedArtifact(record: record, renderer: renderer),
           let artifact = record.sceneBakeArtifact {
            writeBakeRecord(
                artifact: artifact,
                record: record,
                sourcePath: record.localFilePath,
                replaceExistingHistory: false
            )
            completion?(.success(artifact))
            return
        }
        MediaLibraryService.shared.clearSceneBakeFailure(itemID: record.item.id)
        enqueueItem(
            QueueItem(
                queueKey: queueKey,
                itemID: record.item.id,
                title: record.item.title,
                sourcePath: record.localFilePath,
                cacheItemID: record.id,
                renderer: renderer,
                durationSeconds: durationSeconds,
                forceRebake: forceRebake
            ),
            completion: completion
        )
    }

    /// Used for a Scene that can be resolved from disk but is not represented in
    /// the media library yet. The resulting MP4 still receives its own sidecar.
    func enqueue(
        sceneContentRoot: URL,
        cacheItemID: String,
        itemID: String? = nil,
        title: String? = nil,
        renderer: SceneBakeRenderer = .wallpaperWgpu,
        durationSeconds: Double? = nil,
        completion: Completion? = nil
    ) {
        let queueKey = itemID ?? cacheItemID
        enqueueItem(
            QueueItem(
                queueKey: queueKey,
                itemID: itemID,
                title: title ?? sceneContentRoot.lastPathComponent,
                sourcePath: sceneContentRoot.path,
                cacheItemID: cacheItemID,
                renderer: renderer,
                durationSeconds: durationSeconds,
                forceRebake: false
            ),
            completion: completion
        )
    }

    private func enqueueItem(_ item: QueueItem, completion: Completion?) {
        if let existing = items.first(where: { $0.queueKey == item.queueKey }) {
            if let completion {
                completions[existing.id, default: []].append(completion)
            }
            return
        }
        latestFailures[item.queueKey] = nil
        items.append(item)
        if let completion {
            completions[item.id] = [completion]
        }
        startNextIfNeeded()
    }

    private func startNextIfNeeded() {
        guard processingTask == nil, let item = items.first else { return }
        processingTask = Task { [weak self] in
            guard let self else { return }
            do {
                let artifact = try await self.performBake(for: item.id)
                self.finish(itemID: item.id, result: .success(artifact))
            } catch {
                self.finish(itemID: item.id, result: .failure(error))
            }
        }
    }

    private func performBake(for queueItemID: UUID) async throws -> SceneBakeArtifact {
        guard let item = items.first(where: { $0.id == queueItemID }) else {
            throw CancellationError()
        }
        setState(.preparing, for: queueItemID, progress: 0)

        if let itemID = item.itemID,
           var record = MediaLibraryService.shared.downloadRecord(for: itemID) {
            if !item.forceRebake,
               SceneOfflineBakeService.hasCachedArtifact(record: record, renderer: item.renderer),
               let artifact = record.sceneBakeArtifact {
                writeBakeRecord(
                    artifact: artifact,
                    record: record,
                    sourcePath: item.sourcePath,
                    replaceExistingHistory: false
                )
                return artifact
            }

            if record.sceneBakeEligibility == nil {
                guard SystemMemoryPressure.hasRoomForSceneEligibilityAnalysis() else {
                    throw SceneOfflineBakeError.insufficientMemory
                }
                let contentRoot = WorkshopService.resolveWallpaperEngineProjectRoot(
                    startingAt: URL(fileURLWithPath: record.localFilePath)
                )
                let eligibility = try await Task.detached(priority: .utility) {
                    try SceneBakeEligibilityAnalyzer.analyze(contentRoot: contentRoot)
                }.value
                MediaLibraryService.shared.attachSceneBakeEligibility(
                    itemID: itemID,
                    snapshot: eligibility,
                    triggerAutoBake: false
                )
                guard let refreshed = MediaLibraryService.shared.downloadRecord(for: itemID) else {
                    throw SceneOfflineBakeError.contentRootMissing
                }
                record = refreshed
            }

            guard record.sceneBakeEligibility?.isEligibleForOfflineBake == true else {
                throw SceneOfflineBakeError.ineligible
            }
            guard SystemMemoryPressure.hasRoomForSceneOfflineBake() else {
                throw SceneOfflineBakeError.insufficientMemory
            }

            setState(.baking, for: queueItemID, progress: 0)
            let artifact = try await SceneOfflineBakeService.bake(
                record: record,
                durationSeconds: item.durationSeconds,
                renderer: item.renderer
            ) { [weak self] progress in
                self?.setState(.baking, for: queueItemID, progress: progress)
            }
            writeBakeRecord(
                artifact: artifact,
                record: record,
                sourcePath: item.sourcePath,
                replaceExistingHistory: true
            )
            return artifact
        }

        guard SystemMemoryPressure.hasRoomForSceneEligibilityAnalysis() else {
            throw SceneOfflineBakeError.insufficientMemory
        }
        let contentRoot = WorkshopService.resolveWallpaperEngineProjectRoot(
            startingAt: URL(fileURLWithPath: item.sourcePath)
        )
        let eligibility = try await Task.detached(priority: .utility) {
            try SceneBakeEligibilityAnalyzer.analyze(contentRoot: contentRoot)
        }.value
        guard eligibility.isEligibleForOfflineBake else {
            throw SceneOfflineBakeError.ineligible
        }
        guard SystemMemoryPressure.hasRoomForSceneOfflineBake() else {
            throw SceneOfflineBakeError.insufficientMemory
        }

        setState(.baking, for: queueItemID, progress: 0)
        let artifact = try await SceneOfflineBakeService.bake(
            eligibility: eligibility,
            contentRoot: contentRoot,
            cacheItemID: item.cacheItemID,
            durationSeconds: item.durationSeconds,
            renderer: item.renderer,
            persistArtifactToItemID: nil
        ) { [weak self] progress in
            self?.setState(.baking, for: queueItemID, progress: progress)
        }
        writeBakeRecord(
            artifact: artifact,
            itemID: item.itemID,
            sourceName: "sceneProject",
            sourcePath: item.sourcePath,
            replaceExistingHistory: false
        )
        return artifact
    }

    private func setState(_ state: JobState, for itemID: UUID, progress: Double) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[index].state = state
        items[index].progress = min(max(progress, 0), 0.99)
    }

    private func finish(itemID: UUID, result: Result<SceneBakeArtifact, Error>) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else {
            processingTask = nil
            startNextIfNeeded()
            return
        }
        let item = items.remove(at: index)
        let callbacks = completions.removeValue(forKey: itemID) ?? []
        if case .failure(let error) = result, !(error is CancellationError) {
            latestFailures[item.queueKey] = error.localizedDescription
            if let itemID = item.itemID {
                MediaLibraryService.shared.markSceneBakeFailed(
                    itemID: itemID,
                    message: error.localizedDescription
                )
            }
        }
        processingTask = nil
        callbacks.forEach { $0(result) }
        startNextIfNeeded()
    }

    /// The MP4 sidecar starts with its source and complete bake descriptor.
    /// Loop-point analysis and frame interpolation append their own events later.
    private func writeBakeRecord(
        artifact: SceneBakeArtifact,
        record: MediaDownloadRecord,
        sourcePath: String,
        replaceExistingHistory: Bool
    ) {
        writeBakeRecord(
            artifact: artifact,
            itemID: record.item.id,
            sourceName: record.item.sourceName,
            sourcePath: sourcePath,
            replaceExistingHistory: replaceExistingHistory
        )
    }

    private func writeBakeRecord(
        artifact: SceneBakeArtifact,
        itemID: String?,
        sourceName: String,
        sourcePath: String,
        replaceExistingHistory: Bool
    ) {
        let videoURL = URL(fileURLWithPath: artifact.videoPath)
        if !replaceExistingHistory,
           let existing = VideoOptimizationRecordService.shared.record(for: videoURL),
           existing.events.first?.kind == .sourceDownloaded,
           existing.events.first?.metadata["renderer"] != nil {
            return
        }
        VideoOptimizationRecordService.shared.reset(for: videoURL)
        VideoOptimizationRecordService.shared.append(.sourceDownloaded, for: videoURL, metadata: [
            "itemID": itemID ?? "",
            "source": sourceName,
            "sourcePath": sourcePath,
            "renderer": artifact.renderer?.rawValue ?? "unknown",
            "width": String(artifact.width),
            "height": String(artifact.height),
            "fps": String(artifact.fps),
            "durationSeconds": String(artifact.durationSeconds),
            "bakedAt": ISO8601DateFormatter().string(from: artifact.bakedAt)
        ])
    }
}
