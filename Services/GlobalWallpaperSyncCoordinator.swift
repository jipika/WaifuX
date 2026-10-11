import AppKit
import Foundation

/// Serializes global wallpaper application and retains one durable rollback
/// target. The coordinator owns transaction ordering; renderer/player services
/// retain ownership of their own process and playback state.
@MainActor
final class GlobalWallpaperSyncCoordinator {
    static let shared = GlobalWallpaperSyncCoordinator()

    struct Snapshot: Codable, Equatable {
        let localPath: String
        let muted: Bool
        let sceneBakeItemID: String?
        let bakedVideoPath: String?
        let requirePlaybackEndSupport: Bool
        let reason: String

        private enum CodingKeys: String, CodingKey {
            case localPath
            case muted
            case sceneBakeItemID
            case bakedVideoPath
            case requirePlaybackEndSupport
            case reason
        }

        init(
            localPath: String,
            muted: Bool,
            sceneBakeItemID: String?,
            bakedVideoPath: String?,
            requirePlaybackEndSupport: Bool,
            reason: String
        ) {
            self.localPath = localPath
            self.muted = muted
            self.sceneBakeItemID = sceneBakeItemID
            self.bakedVideoPath = bakedVideoPath
            self.requirePlaybackEndSupport = requirePlaybackEndSupport
            self.reason = reason
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            localPath = try container.decode(String.self, forKey: .localPath)
            muted = try container.decode(Bool.self, forKey: .muted)
            sceneBakeItemID = try container.decodeIfPresent(String.self, forKey: .sceneBakeItemID)
            bakedVideoPath = try container.decodeIfPresent(String.self, forKey: .bakedVideoPath)
            // Older durable snapshots omitted this flag; default keeps reapply permissive.
            requirePlaybackEndSupport = try container.decodeIfPresent(
                Bool.self,
                forKey: .requirePlaybackEndSupport
            ) ?? false
            reason = try container.decode(String.self, forKey: .reason)
        }

        var localURL: URL {
            URL(fileURLWithPath: localPath)
        }

        func options(isGlobalTransaction: Bool) -> LocalWallpaperApplyService.Options {
            LocalWallpaperApplyService.Options(
                animatedTransition: false,
                requirePlaybackEndSupport: requirePlaybackEndSupport,
                muted: muted,
                // 与调度器/手动设壁纸一致：无 HD poster 时后台抽帧补系统静帧
                generatePosterFromVideoIfNeeded: true,
                sceneBakeItemID: sceneBakeItemID,
                bakedVideoPath: bakedVideoPath,
                isGlobalTransaction: isGlobalTransaction,
                // Global applies target every connected screen; share one decoder.
                usesSharedVideoDecoder: true,
                reason: reason
            )
        }
    }

    private struct PendingRequest {
        let id: UUID
        let snapshot: Snapshot
        let animatedTransition: Bool
        let continuation: CheckedContinuation<Bool, Error>
    }

    private enum TransactionError: LocalizedError {
        case applicationReturnedFalse
        case noConnectedDisplays
        case rollbackFailed(original: Error, rollback: Error)

        var errorDescription: String? {
            switch self {
            case .applicationReturnedFalse:
                return "全局壁纸应用未完成"
            case .noConnectedDisplays:
                return "当前没有可用的显示器"
            case .rollbackFailed(let original, let rollback):
                return "全局壁纸应用失败：\(original.localizedDescription)；回滚也失败：\(rollback.localizedDescription)"
            }
        }
    }

    private static let stateKey = "global_wallpaper_sync_last_success_v1"
    private var lastSuccessfulSnapshot: Snapshot?
    private var pendingRequests: [PendingRequest] = []
    private var activeTask: Task<Void, Never>?
    private var activeRequestID: UUID?
    private var isStopping = false

    private init() {
        guard let data = WaifuXPreferences.shared.data(forKey: Self.stateKey),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              FileManager.default.fileExists(atPath: snapshot.localPath) else {
            return
        }
        lastSuccessfulSnapshot = snapshot
    }

    /// Last successful global apply. Exposed for diagnostics and regressions.
    var lastSuccessfulApply: Snapshot? {
        lastSuccessfulSnapshot
    }

    func apply(
        localURL: URL,
        options: LocalWallpaperApplyService.Options
    ) async throws -> Bool {
        try Task.checkCancellation()
        guard !isStopping else { throw CancellationError() }
        let snapshot = Snapshot(
            localPath: localURL.standardizedFileURL.path,
            muted: options.muted,
            sceneBakeItemID: options.sceneBakeItemID,
            bakedVideoPath: options.bakedVideoPath,
            requirePlaybackEndSupport: options.requirePlaybackEndSupport,
            reason: options.reason
        )

        let id = UUID()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pendingRequests.append(PendingRequest(
                    id: id,
                    snapshot: snapshot,
                    animatedTransition: options.animatedTransition,
                    continuation: continuation
                ))
                startNextRequestIfNeeded()
            }
        }, onCancel: { [weak self] in
            Task { @MainActor in self?.cancelRequest(id) }
        })
    }

    /// A cancelled caller must not leave a detached wallpaper transaction in
    /// the queue. The active request completes its own continuation exactly once.
    private func cancelRequest(_ id: UUID) {
        if activeRequestID == id {
            activeTask?.cancel()
        } else if let index = pendingRequests.firstIndex(where: { $0.id == id }) {
            pendingRequests.remove(at: index).continuation.resume(throwing: CancellationError())
        }
    }

    func prepareForProcessExit() {
        isStopping = true
        let abandoned = pendingRequests
        pendingRequests.removeAll()
        for request in abandoned { request.continuation.resume(throwing: CancellationError()) }
        activeTask?.cancel()
    }

    /// Called when the user turns global sync on while wallpapers may already
    /// differ per display. Prefer the durable last success; otherwise capture
    /// the primary screen's live wallpaper, including bake metadata when known.
    func synchronizeCurrentWallpaperAfterEnabling() {
        guard !isStopping else { return }
        if let lastSuccessfulSnapshot,
           FileManager.default.fileExists(atPath: lastSuccessfulSnapshot.localPath) {
            Task {
                _ = try? await apply(
                    localURL: lastSuccessfulSnapshot.localURL,
                    options: lastSuccessfulSnapshot.options(isGlobalTransaction: false)
                )
            }
            return
        }

        guard let snapshot = currentWallpaperSnapshot(reason: "globalSyncEnable") else {
            return
        }
        Task {
            _ = try? await apply(
                localURL: snapshot.localURL,
                options: snapshot.options(isGlobalTransaction: false)
            )
        }
    }

    /// Re-broadcast the last successful global wallpaper to the current screen
    /// set after a display is connected (or the set otherwise grows).
    func reapplyToConnectedDisplays() {
        guard !isStopping else { return }
        guard !NSScreen.screens.isEmpty else { return }

        if let lastSuccessfulSnapshot,
           FileManager.default.fileExists(atPath: lastSuccessfulSnapshot.localPath) {
            Task {
                _ = try? await apply(
                    localURL: lastSuccessfulSnapshot.localURL,
                    options: lastSuccessfulSnapshot.options(isGlobalTransaction: false)
                )
            }
            return
        }

        synchronizeCurrentWallpaperAfterEnabling()
    }

    /// 全局同步关闭时停止接受旧的排队事务，并等待当前事务完整收尾。
    /// 当前事务不能直接半途杀掉，否则可能只改完部分显示器；等待结束后再由各屏调度覆盖。
    func drainBeforeLeavingGlobalMode() async {
        let abandoned = pendingRequests
        pendingRequests.removeAll()
        for request in abandoned {
            request.continuation.resume(throwing: CancellationError())
        }

        if let activeTask {
            await activeTask.value
        }
    }

    private func startNextRequestIfNeeded() {
        guard !isStopping, activeTask == nil, !pendingRequests.isEmpty else { return }
        let request = pendingRequests.removeFirst()
        activeRequestID = request.id
        activeTask = Task { [weak self] in
            guard let self else {
                request.continuation.resume(throwing: CancellationError())
                return
            }

            do {
                let applied = try await self.perform(request)
                request.continuation.resume(returning: applied)
            } catch {
                request.continuation.resume(throwing: error)
            }

            self.activeTask = nil
            self.activeRequestID = nil
            self.startNextRequestIfNeeded()
        }
    }

    private func perform(_ request: PendingRequest) async throws -> Bool {
        try Task.checkCancellation()
        guard !isStopping else { throw CancellationError() }
        guard FileManager.default.fileExists(atPath: request.snapshot.localPath) else {
            throw LocalWallpaperApplyService.ApplyError.missingFile(request.snapshot.localPath)
        }

        let targetScreens = NSScreen.screens
        guard !targetScreens.isEmpty else {
            throw TransactionError.noConnectedDisplays
        }

        let rollbackSnapshot = lastSuccessfulSnapshot ?? currentWallpaperSnapshot(reason: "globalRollback")
        var options = request.snapshot.options(isGlobalTransaction: true)
        options.animatedTransition = request.animatedTransition

        do {
            let applied = try await LocalWallpaperApplyService.apply(
                localURL: request.snapshot.localURL,
                targetScreens: targetScreens,
                options: options
            )
            try Task.checkCancellation()
            guard !isStopping else { throw CancellationError() }
            guard applied else { throw TransactionError.applicationReturnedFalse }
            lastSuccessfulSnapshot = request.snapshot
            persistLastSuccessfulSnapshot()
            return true
        } catch {
            // Quit/caller cancellation is terminal. Rolling back here would
            // create new windows/players after the exit cleanup has started.
            if error is CancellationError || Task.isCancelled || isStopping { throw CancellationError() }
            guard let rollbackSnapshot,
                  rollbackSnapshot.localPath != request.snapshot.localPath,
                  FileManager.default.fileExists(atPath: rollbackSnapshot.localPath) else {
                throw error
            }
            do {
                let rolledBack = try await LocalWallpaperApplyService.apply(
                    localURL: rollbackSnapshot.localURL,
                    targetScreens: NSScreen.screens,
                    options: rollbackSnapshot.options(isGlobalTransaction: true)
                )
                try Task.checkCancellation()
                guard !isStopping else { throw CancellationError() }
                guard rolledBack else { throw TransactionError.applicationReturnedFalse }
            } catch let rollbackError {
                if rollbackError is CancellationError || Task.isCancelled || isStopping { throw CancellationError() }
                throw TransactionError.rollbackFailed(original: error, rollback: rollbackError)
            }
            throw error
        }
    }

    private func currentWallpaperSnapshot(reason: String) -> Snapshot? {
        guard let primary = NSScreen.screens.first,
              let currentURL = CurrentWallpaperService.shared.activeURL(for: primary.wallpaperScreenIdentifier),
              currentURL.isFileURL,
              FileManager.default.fileExists(atPath: currentURL.path) else {
            return nil
        }

        let standardized = currentURL.standardizedFileURL
        let enriched = enrichSnapshotMetadata(for: standardized)

        return Snapshot(
            localPath: standardized.path,
            muted: VideoWallpaperManager.shared.isMuted,
            sceneBakeItemID: enriched.sceneBakeItemID,
            bakedVideoPath: enriched.bakedVideoPath,
            requirePlaybackEndSupport: false,
            reason: reason
        )
    }

    /// When the live active path is a Workshop directory or baked companion,
    /// carry bake metadata so re-enable / reconnect can prefer the same
    /// baked video path the scheduler would have used.
    private func enrichSnapshotMetadata(for localURL: URL) -> (
        sceneBakeItemID: String?,
        bakedVideoPath: String?
    ) {
        var sceneBakeItemID: String?
        var bakedVideoPath: String?

        let path = localURL.path
        if let record = MediaLibraryService.shared.downloadedItems.first(where: { item in
            let candidate = item.localFileURL.standardizedFileURL.path
            return candidate == path
                || path.hasPrefix(candidate + "/")
                || candidate.hasPrefix(path + "/")
        }), let art = SceneOfflineBakeService.usableArtifact(from: record) {
            sceneBakeItemID = record.item.id
            if SceneOfflineBakeService.isUsableBakedVideo(at: URL(fileURLWithPath: art.videoPath)) {
                bakedVideoPath = art.videoPath
            }
        }

        return (sceneBakeItemID, bakedVideoPath)
    }

    private func persistLastSuccessfulSnapshot() {
        guard let lastSuccessfulSnapshot,
              let data = try? JSONEncoder().encode(lastSuccessfulSnapshot) else {
            WaifuXPreferences.shared.removeObject(forKey: Self.stateKey)
            return
        }
        WaifuXPreferences.shared.set(data, forKey: Self.stateKey)
    }
}
