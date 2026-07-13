import Foundation

/// Persists an auditable optimization history next to each video file.
///
/// The sidecar deliberately records lifecycle transitions instead of high-frequency
/// progress samples so it remains concise and survives relaunches and file playback
/// replacement.
@MainActor
final class VideoOptimizationRecordService {
    static let shared = VideoOptimizationRecordService()

    enum EventKind: String, Codable {
        case sourceDownloaded
        case optimizationReset
        case loopQueued
        case loopAnalysisStarted
        case loopApplied
        case loopNotNeeded
        case loopNoReliablePoint
        case loopFailed
        case frameQueued
        case frameAnalysisStarted
        case frameInterpolationStarted
        case frameApplied
        case frameNotNeeded
        case frameFailed
        case frameCancelled
        case frameBlacklisted
        case frameReset
    }

    struct Event: Codable, Identifiable {
        let id: UUID
        let date: Date
        let kind: EventKind
        let detail: String?
        let metadata: [String: String]

        init(kind: EventKind, detail: String? = nil, metadata: [String: String] = [:]) {
            self.id = UUID()
            self.date = Date()
            self.kind = kind
            self.detail = detail
            self.metadata = metadata
        }
    }

    struct Record: Codable {
        let schemaVersion: Int
        let videoPath: String
        let createdAt: Date
        var updatedAt: Date
        var events: [Event]

        init(videoURL: URL) {
            schemaVersion = 1
            videoPath = videoURL.standardizedFileURL.path
            createdAt = Date()
            updatedAt = createdAt
            events = []
        }
    }

    private let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "webm", "mkv", "avi", "wmv", "flv"
    ]

    private init() {}

    func sidecarURL(for videoURL: URL) -> URL {
        URL(fileURLWithPath: videoURL.standardizedFileURL.path + ".waifux-optimization.json")
    }

    func record(for videoURL: URL) -> Record? {
        guard isVideoFile(videoURL) else { return nil }
        let url = sidecarURL(for: videoURL)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Record.self, from: data)
    }

    func append(
        _ kind: EventKind,
        for videoURL: URL,
        detail: String? = nil,
        metadata: [String: String] = [:]
    ) {
        guard isVideoFile(videoURL) else { return }

        var record = record(for: videoURL) ?? Record(videoURL: videoURL)
        record.events.append(Event(kind: kind, detail: detail, metadata: metadata))
        record.updatedAt = Date()
        write(record, for: videoURL)
    }

    /// Returns the last loop-related transition, including a reset marker. Callers
    /// can reconstruct the durable UI state without keeping an in-memory job map.
    func latestLoopLifecycleEvent(for videoURL: URL) -> Event? {
        let loopLifecycleKinds: Set<EventKind> = [
            .optimizationReset,
            .loopQueued,
            .loopAnalysisStarted,
            .loopApplied,
            .loopNotNeeded,
            .loopNoReliablePoint,
            .loopFailed
        ]
        return record(for: videoURL)?.events.reversed().first {
            loopLifecycleKinds.contains($0.kind)
        }
    }

    /// The interpolation queue uses this to restore terminal state per video
    /// instead of treating UserDefaults as the only source of truth.
    func latestFrameLifecycleEvent(for videoURL: URL) -> Event? {
        let frameLifecycleKinds: Set<EventKind> = [
            .optimizationReset,
            .frameQueued,
            .frameAnalysisStarted,
            .frameInterpolationStarted,
            .frameApplied,
            .frameNotNeeded,
            .frameFailed,
            .frameCancelled,
            .frameBlacklisted,
            .frameReset
        ]
        return record(for: videoURL)?.events.reversed().first {
            frameLifecycleKinds.contains($0.kind)
        }
    }

    /// Starts a fresh history for a newly downloaded original video.
    func reset(for videoURL: URL) {
        guard isVideoFile(videoURL) else { return }
        try? FileManager.default.removeItem(at: sidecarURL(for: videoURL))
    }

    /// Clears every optimization layer before an original-file redownload.
    /// Workshop and Scene download records can point at a project directory, so
    /// a reset must walk that item directory instead of assuming it is a single
    /// video URL.
    func resetAllOptimizationState(for localURL: URL) {
        for videoURL in videoFiles(at: localURL) {
            reset(for: videoURL)
            LoopPointAnalysisQueueService.shared.reset(videoURL: videoURL)
            VideoLoopPreprocessingService.shared.resetState(for: videoURL)
            FrameInterpolationQueueService.shared.reset(videoURL: videoURL)
        }
    }

    private func isVideoFile(_ url: URL) -> Bool {
        videoExtensions.contains(url.pathExtension.lowercased())
    }

    private func videoFiles(at localURL: URL) -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: localURL.path, isDirectory: &isDirectory) else {
            return isVideoFile(localURL) ? [localURL] : []
        }

        guard isDirectory.boolValue else {
            return isVideoFile(localURL) ? [localURL] : []
        }

        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey]
        let enumerator = FileManager.default.enumerator(
            at: localURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        var videos: [URL] = []
        while let candidate = enumerator?.nextObject() as? URL {
            guard isVideoFile(candidate),
                  let values = try? candidate.resourceValues(forKeys: resourceKeys),
                  values.isRegularFile == true else {
                continue
            }
            videos.append(candidate)
        }
        return videos
    }

    private func write(_ record: Record, for videoURL: URL) {
        let url = sidecarURL(for: videoURL)
        guard let data = try? JSONEncoder.prettyPrintedSorted.encode(record) else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            AppLogger.error(.media, "写入视频优化记录失败", metadata: [
                "video": videoURL.path,
                "sidecar": url.path,
                "error": error.localizedDescription
            ])
        }
    }
}

private extension JSONEncoder {
    static var prettyPrintedSorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
