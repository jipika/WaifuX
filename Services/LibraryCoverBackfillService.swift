import Foundation

/// 「我的库」封面后台预热。
///
/// 历史条目（旧版烘焙、缓存被清理、迁移来的记录）第一次进库时没有磁盘封面，
/// 只能靠 cell 滚停后现场抽帧，整屏会连续解码多路视频。本服务在库页可见且空闲时，
/// 把当前列表里缺封面的条目按条补齐到本机 SSD 缓存，下次进库直接命中：
///
/// - 媒体：复用 `MediaItem.ensureFolderPreviewCache`（烘焙列表帧 / 视频抽帧 / 静图小图 / Workshop preview）
/// - 壁纸：只补静图 512 缩略图（GIF 保留原文件给 hover；视频不在壁纸列表封面链路里）
///
/// 约束（对齐库网格既有性能纪律）：
/// - 串行、逐条限速；每轮有「条数 + 时长」双上限，到点停轮，下次进库继续
/// - 滚动中暂停（`LibraryScrollHoverGate`）；低电量 / 可回收内存不足时停轮
/// - 页面离开即取消；已确认条目不再重复排队，且该集合跨进程落盘
///   （`~/Library/Caches/WaifuX/CoverBackfillCompleted.json`），重启 App 不再全量重跑
/// - 不发起任何网络请求，只处理本机已有文件与烘焙产物
@MainActor
final class LibraryCoverBackfillService {
    static let shared = LibraryCoverBackfillService()

    struct Candidate {
        enum Kind {
            case wallpaper
            case media
        }

        let id: String
        let kind: Kind
        let localFileURL: URL?
        let mediaItem: MediaItem?

        init(id: String, kind: Kind, localFileURL: URL?, mediaItem: MediaItem? = nil) {
            self.id = id
            self.kind = kind
            self.localFileURL = localFileURL
            self.mediaItem = mediaItem
        }
    }

    private var queue: [Candidate] = []
    private var queuedKeys: Set<String> = []
    /// 本进程内已处理过的条目（成功 / 结构性无法补 / 环境性失败），不再重复排队。
    private var completedKeys: Set<String> = []
    /// 已确认可跨进程跳过的条目（成功补齐 / 结构性无法补），落盘持久化。
    /// 环境性失败（源暂不可读、生成失败）只进 `completedKeys`，重启后重试。
    private var persistedKeys: Set<String> = []
    private var hasLoadedPersistedKeys = false
    private var unsavedPersistedCount = 0
    private var worker: Task<Void, Never>?
    /// 取消/重启代数：旧 worker 收尾时不得把新 worker 置空。
    private var generation: UInt = 0
    private var lastReason = ""

    /// 单轮上限：一次进库最多补这么多条，避免长时间占用 I/O。
    private let maxItemsPerRound = 600
    /// 单轮时长上限（秒）：与外置盘慢抽帧叠加时的硬止损。
    private let maxRoundDuration: TimeInterval = 90
    /// 每条之间的让位间隔：外置盘抽帧是 100ms 级，留出 I/O 与主线程空隙。
    private let itemSpacing: UInt64 = 120_000_000
    /// 滚动中的轮询间隔。
    private let scrollPollInterval: UInt64 = 250_000_000
    /// 低于该可回收内存就停轮，等下次进库继续。
    private let minReclaimableBytes: UInt64 = 256 * 1024 * 1024

    private init() {}

    var isRunning: Bool { worker != nil }
    var pendingCount: Int { queue.count }

    /// 入队当前列表的候选。重复调用安全：已确认/已在队列里的 id 会被跳过。
    func schedule(_ candidates: [Candidate], reason: String) {
        guard !BackgroundRuntimeRole.isIsolatedTest else { return }
        guard !candidates.isEmpty else { return }

        ensurePersistedKeysLoaded()
        lastReason = reason
        var added = 0
        var skippedNoLocal = 0
        for candidate in candidates {
            let key = Self.key(for: candidate)
            guard !completedKeys.contains(key), !queuedKeys.contains(key) else { continue }
            // 无本地文件的壁纸条目现在结构上补不了，不入队也不落盘：
            // 将来下载完成会带着 localFileURL 重新进来。
            if candidate.kind == .wallpaper, candidate.localFileURL?.isFileURL != true {
                skippedNoLocal += 1
                continue
            }
            queue.append(candidate)
            queuedKeys.insert(key)
            added += 1
        }

        if added > 0 || skippedNoLocal > 0 {
            AppLogger.debug(.general, "[CoverBackfill] enqueue", metadata: [
                "added": added,
                "pending": queue.count,
                "skippedNoLocal": skippedNoLocal,
                "known": completedKeys.count,
                "reason": reason,
            ])
        }
        guard !queue.isEmpty else { return }
        startIfNeeded()
    }

    /// 页面离开时取消；未处理完的队列保留，重新进库会从断点继续。
    func cancel(reason: String) {
        guard worker != nil || !queue.isEmpty else { return }
        generation &+= 1
        worker?.cancel()
        worker = nil
        flushPersistedKeys()
        AppLogger.debug(.general, "[CoverBackfill] cancel", metadata: [
            "pending": queue.count,
            "reason": reason,
        ])
    }

    // MARK: - Private

    private func startIfNeeded() {
        guard worker == nil, !queue.isEmpty else { return }
        generation &+= 1
        let currentGeneration = generation
        worker = Task { [weak self] in
            guard let self else { return }
            await self.drain()
            if self.generation == currentGeneration {
                self.worker = nil
            }
        }
    }

    private func drain() async {
        let startedAt = Date()
        var processed = 0

        while !queue.isEmpty {
            if Task.isCancelled { return }
            if processed >= maxItemsPerRound {
                flushPersistedKeys()
                AppLogger.debug(.general, "[CoverBackfill] paused(roundLimit)", metadata: [
                    "processed": processed,
                    "pending": queue.count,
                ])
                return
            }
            if Date().timeIntervalSince(startedAt) >= maxRoundDuration {
                flushPersistedKeys()
                AppLogger.debug(.general, "[CoverBackfill] paused(timeBudget)", metadata: [
                    "processed": processed,
                    "pending": queue.count,
                ])
                return
            }

            // 滚动中排队等待：滚停后再继续，避免和网格抢 I/O。
            while LibraryScrollHoverGate.shared.isScrolling {
                if Task.isCancelled { return }
                do {
                    try await Task.sleep(nanoseconds: scrollPollInterval)
                } catch {
                    return
                }
            }

            if ProcessInfo.processInfo.isLowPowerModeEnabled {
                flushPersistedKeys()
                AppLogger.debug(.general, "[CoverBackfill] paused(lowPower)", metadata: [
                    "pending": queue.count,
                ])
                return
            }
            if SystemMemoryPressure.approximateReclaimableBytes() < minReclaimableBytes {
                flushPersistedKeys()
                AppLogger.debug(.general, "[CoverBackfill] paused(memory)", metadata: [
                    "pending": queue.count,
                ])
                return
            }

            let candidate = queue.removeFirst()
            queuedKeys.remove(Self.key(for: candidate))
            let outcome = await process(candidate)
            if Task.isCancelled { return }

            let key = Self.key(for: candidate)
            completedKeys.insert(key)
            // 环境性失败不落盘：重启后（比如外置盘重新挂载）还能重试。
            if outcome != .softFailed {
                markPersisted(key)
            }
            processed += 1

            if processed % 12 == 0 {
                AppLogger.debug(.general, "[CoverBackfill] progress", metadata: [
                    "processed": processed,
                    "pending": queue.count,
                ])
            }

            do {
                try await Task.sleep(nanoseconds: itemSpacing)
            } catch {
                return
            }
        }

        flushPersistedKeys()
        let elapsedMS = Int(Date().timeIntervalSince(startedAt) * 1000)
        AppLogger.debug(.general, "[CoverBackfill] done", metadata: [
            "processed": processed,
            "elapsedMS": elapsedMS,
            "reason": lastReason,
        ])
    }

    private enum ProcessOutcome {
        /// 结构上无法补（无本地文件 / 非静图 / 无条目），跨进程持久跳过。
        case structural
        /// 已补齐或命中已有缓存，跨进程持久跳过。
        case filled
        /// 环境性失败（源暂不可读、生成失败），仅本进程跳过，重启后重试。
        case softFailed
    }

    private func process(_ candidate: Candidate) async -> ProcessOutcome {
        switch candidate.kind {
        case .wallpaper:
            guard let local = candidate.localFileURL,
                  local.isFileURL,
                  LocalImageThumbnailCache.isRasterImageFile(local) else { return .structural }
            guard FileManager.default.isReadableFile(atPath: local.path) else { return .softFailed }
            let generated = await LocalImageThumbnailCache.shared.ensureThumbnail(forLocalFile: local)
            return generated == nil ? .softFailed : .filled

        case .media:
            guard let item = candidate.mediaItem else { return .structural }
            // 烘焙产物在外置盘时先探可读，避免拔盘场景把整批误标成永久完成。
            if let bakedPath = MediaLibraryService.shared
                .downloadRecord(for: item.id)?.sceneBakeArtifact?.videoPath,
               !bakedPath.isEmpty {
                guard FileManager.default.isReadableFile(atPath: bakedPath) else { return .softFailed }
            } else {
                // `ensureFolderPreviewCache` 对「无烘焙产物且无本地文件」直接返回 false，
                // 这是结构性失败，先在这里判掉。
                guard let local = candidate.localFileURL, local.isFileURL else { return .structural }
                guard FileManager.default.isReadableFile(atPath: local.path) else { return .softFailed }
            }
            // 返回 false = 命中已有缓存（或结构上无事可做，如 GIF），均视为已处理。
            _ = await item.ensureFolderPreviewCache(localFileURL: candidate.localFileURL)
            return .filled
        }
    }

    private static func key(for candidate: Candidate) -> String {
        switch candidate.kind {
        case .wallpaper: return "wallpaper:\(candidate.id)"
        case .media: return "media:\(candidate.id)"
        }
    }

    // MARK: - 已确认集合落盘

    /// 状态文件与 `LocalImageThumbnails` 同在 `~/Library/Caches/WaifuX`：
    /// 用户清掉该缓存目录时状态一并消失，下次自然重新预热（重跑一轮命中短路，代价小）。
    private static var stateFileURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WaifuX/CoverBackfillCompleted.json")
    }

    private func ensurePersistedKeysLoaded() {
        guard !hasLoadedPersistedKeys else { return }
        hasLoadedPersistedKeys = true
        guard let data = try? Data(contentsOf: Self.stateFileURL),
              let loaded = try? JSONDecoder().decode([String].self, from: data) else { return }
        persistedKeys.formUnion(loaded)
        completedKeys.formUnion(loaded)
    }

    private func markPersisted(_ key: String) {
        guard persistedKeys.insert(key).inserted else { return }
        unsavedPersistedCount += 1
        if unsavedPersistedCount >= 24 {
            flushPersistedKeys()
        }
    }

    private func flushPersistedKeys() {
        guard unsavedPersistedCount > 0 else { return }
        let url = Self.stateFileURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let payload = Array(persistedKeys).sorted()
        guard let data = try? JSONEncoder().encode(payload) else { return }
        do {
            try data.write(to: url, options: .atomic)
            unsavedPersistedCount = 0
        } catch {
            // 保留计数，等下一次 flush 重试；内存语义不受影响。
        }
    }
}
