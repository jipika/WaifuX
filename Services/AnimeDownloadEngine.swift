import Foundation
import Combine
import CommonCrypto
import CryptoKit
import Security

// 网络仅由 Swift 处理；ffmpeg 只允许读取本地文件。
enum AnimeDownloadError: LocalizedError {
    case cancelled, badResponse(Int), hlsUnsupported(String), ffmpegNotFound, ffmpegFailed(Int32), missingOutput
    case resolutionFailed, sourceUnavailable, unsafePath, persistenceFailed, verificationRequired

    var errorDescription: String? {
        switch self {
        case .cancelled: return t("下载已取消")
        case .badResponse(let code): return String(format: t("下载失败（HTTP %@）"), String(code))
        case .hlsUnsupported(let reason): return String(format: t("该视频流暂不支持下载（%@），可在线观看"), reason)
        case .ffmpegNotFound: return t("未找到内置 ffmpeg，无法合成视频")
        case .ffmpegFailed(let code): return String(format: t("视频合成失败（ffmpeg %@）"), String(code))
        case .missingOutput: return t("下载产物缺失")
        case .resolutionFailed: return t("无法重新解析剧集，请在详情页重试下载")
        case .sourceUnavailable: return t("下载源不可用，请重新安装规则后重试")
        case .unsafePath: return t("下载路径不安全或不可访问")
        case .persistenceFailed: return t("下载队列保存失败，请检查存储空间和权限")
        case .verificationRequired: return t("请打开站点完成验证后恢复下载")
        }
    }
}

@MainActor
final class AnimeDownloadEngine: ObservableObject {
    static let shared = AnimeDownloadEngine()

    struct TaskState: Identifiable, Equatable {
        let id: String
        let animeId: String
        var animeTitle: String
        var episodeName: String?
        var episodeNumber: Int
        var sourceName: String
        var progress: Double
        var downloadedBytes: Int64
        var totalBytes: Int64?
        var status: AnimeDownloadTaskStatus
        var errorMessage: String?
        var isCompleted: Bool { status == .completed }
    }

    @Published private(set) var tasks: [String: TaskState] = [:]
    @Published private(set) var persistenceError: String?
    /// 主程序可在启动时接入离线弹幕缓存。回调失败由调用方消化，不回滚已完成的视频。
    var onDownloadCompleted: (@MainActor (AnimeDownloadRecord) async -> Void)?
    var onNeedsVerification: (@MainActor (AnimeRule, AnimeDetail.AnimeEpisodeItem) -> Void)?

    private struct Context {
        let anime: AnimeSearchResult
        let source: AnimeRule
        let episode: AnimeDetail.AnimeEpisodeItem
        let videoURL: URL
        let isHLS: Bool
        let httpHeaders: [String: String]
    }
    private var descriptors: [String: AnimeDownloadTaskDescriptor] = [:]
    private var contexts: [String: Context] = [:]
    private var pendingEpisodes: [String: (AnimeSearchResult, AnimeRule, AnimeDetail.AnimeEpisodeItem)] = [:]
    private var aliases: [String: String] = [:]
    private var queue: [String] = []
    private var activeTaskId: String?
    private var activeDownloadTask: Task<Void, Never>?
    private var activeProcess: Process?
    private var activeExtractor: AnimeVideoExtractor?
    private var stopRequests: [String: AnimeDownloadTaskStatus] = [:]
    private var restored = false
    private var resumeAfterStop = Set<String>()

    init() {} // 独立实例用于隔离队列回归；生产调用仍使用 shared。

    var tasksSorted: [TaskState] {
        tasks.values.sorted {
            let left = descriptors[$0.id]?.createdAt ?? .distantPast
            let right = descriptors[$1.id]?.createdAt ?? .distantPast
            return left == right ? $0.id < $1.id : left < right
        }
    }

    var overallProgress: Double { progress(forAnime: nil) }

    func progress(forAnime animeId: String?) -> Double {
        let values = tasks.values.filter { (animeId == nil || $0.animeId == animeId) && $0.status != .cancelled }
        guard !values.isEmpty else { return 0 }
        return values.reduce(0) { $0 + min(1, max(0, $1.progress)) } / Double(values.count)
    }

    func task(for episodeId: String, sourceId: String) -> TaskState? {
        let identity = AnimeDownloadTaskDescriptor.identity(sourceID: sourceId, episodeID: episodeId)
        if let exact = tasks[identity] { return exact }
        let publicID = AnimeDownloadTaskDescriptor.safeIdentifier(episodeId)
        return descriptors.values.first { $0.sourceID == sourceId && $0.episodeID == publicID }.flatMap { tasks[$0.id] }
    }

    func isDownloading(episodeId: String, sourceId: String) -> Bool {
        task(for: episodeId, sourceId: sourceId)?.status.isActive == true
    }

    func isCancelRequested(_ recordID: String) -> Bool {
        stopRequests[resolvedID(recordID)] != nil
    }

    /// 延迟恢复；init 不读偏好。重启后全部未完成任务停在 paused，等待用户恢复。
    func restoreSavedTasks() {
        guard !restored else { return }
        restored = true
        guard let data = try? Data(contentsOf: Self.queueFileURL),
              let snapshot = try? JSONDecoder().decode(AnimeDownloadQueueSnapshot.self, from: data), snapshot.version == 1 else { return }
        for entry in snapshot.entries {
            let descriptor = entry.descriptor
            guard descriptor.id.count == 64, descriptor.id.allSatisfy({ $0.isHexDigit }) else { continue }
            descriptors[descriptor.id] = descriptor
            let status: AnimeDownloadTaskStatus = [.completed, .cancelled].contains(entry.status) ? entry.status : .paused
            tasks[descriptor.id] = TaskState(id: descriptor.id, animeId: descriptor.animeID, animeTitle: descriptor.animeTitle,
                episodeName: descriptor.episodeName, episodeNumber: descriptor.episodeNumber, sourceName: descriptor.sourceName,
                progress: entry.progress.isFinite ? min(1, max(0, entry.progress)) : 0,
                downloadedBytes: max(0, entry.downloadedBytes), totalBytes: entry.totalBytes, status: status, errorMessage: nil)
        }
        persistQueue()
    }

    /// 保留调用方已解析的单集下载入口；排队期间仅在内存保留请求上下文。
    func enqueue(anime: AnimeSearchResult, source: AnimeRule, episode: AnimeDetail.AnimeEpisodeItem,
                 videoURL: URL, isHLS: Bool, httpHeaders: [String: String] = [:]) {
        restoreSavedTasks()
        let descriptor = AnimeDownloadTaskDescriptor(anime: anime, source: source, episode: episode)
        let id = descriptor.id
        guard tasks[id]?.status.isActive != true,
              !AnimeDownloadStore.shared.isDownloaded(episodeId: episode.id, sourceId: source.id) else { return }
        aliases[AnimeDownloadRecord.recordID(ruleId: source.id, episodeId: episode.id)] = id
        descriptors[id] = descriptor
        contexts[id] = Context(anime: anime, source: source, episode: episode, videoURL: videoURL, isHLS: isHLS, httpHeaders: httpHeaders)
        tasks[id] = TaskState(id: id, animeId: anime.id, animeTitle: anime.title, episodeName: episode.name,
            episodeNumber: episode.episodeNumber, sourceName: source.name, progress: 0, downloadedBytes: 0,
            totalBytes: nil, status: .queued, errorMessage: nil)
        if activeTaskId == id { resumeAfterStop.insert(id) } else { queue.append(id) }
        persistQueue()
        pumpQueue()
    }

    /// 立即入队，解析阶段也可暂停、取消和跨启动恢复。适合批量逐集提交。
    func enqueueEpisode(anime: AnimeSearchResult, source: AnimeRule, episode: AnimeDetail.AnimeEpisodeItem) {
        restoreSavedTasks()
        let descriptor = AnimeDownloadTaskDescriptor(anime: anime, source: source, episode: episode)
        let id = descriptor.id
        guard tasks[id]?.status.isActive != true,
              !AnimeDownloadStore.shared.isDownloaded(episodeId: episode.id, sourceId: source.id) else { return }
        descriptors[id] = descriptor
        // 原始页面只留在本次运行内存；持久化描述符使用去敏页面。
        pendingEpisodes[id] = (anime, source, episode)
        aliases[AnimeDownloadRecord.recordID(ruleId: source.id, episodeId: episode.id)] = id
        tasks[id] = TaskState(id: id, animeId: anime.id, animeTitle: anime.title, episodeName: episode.name,
            episodeNumber: episode.episodeNumber, sourceName: source.name, progress: 0, downloadedBytes: 0,
            totalBytes: nil, status: .queued, errorMessage: nil)
        if activeTaskId == id { resumeAfterStop.insert(id) } else { queue.append(id) }
        persistQueue()
        pumpQueue()
    }

    func pause(episodeId: String, sourceId: String) {
        if let state = task(for: episodeId, sourceId: sourceId) { pauseByRecordID(state.id) }
    }
    func resume(episodeId: String, sourceId: String) {
        if let state = task(for: episodeId, sourceId: sourceId) { resumeByRecordID(state.id) }
    }
    func cancel(episodeId: String, sourceId: String) {
        if let state = task(for: episodeId, sourceId: sourceId) { cancelByRecordID(state.id) }
    }

    func pauseByRecordID(_ recordID: String) {
        let id = resolvedID(recordID)
        guard tasks[id]?.status.isActive == true else { return }
        stop(id, status: .paused)
    }

    func cancelByRecordID(_ recordID: String) {
        let id = resolvedID(recordID)
        guard tasks[id] != nil, tasks[id]?.status != .completed else { return }
        stop(id, status: .cancelled)
        if activeTaskId != id { clearPartialFiles(id) }
    }

    func resumeByRecordID(_ recordID: String) {
        restoreSavedTasks()
        let id = resolvedID(recordID)
        guard tasks[id]?.status.canResume == true else { return }
        updateState(id) { $0.status = .queued; $0.errorMessage = nil }
        // 恢复和重试必须重新解析，禁止复用先前签名 URL / Cookie。
        contexts.removeValue(forKey: id)
        pendingEpisodes.removeValue(forKey: id)
        if activeTaskId == id { resumeAfterStop.insert(id) } else if !queue.contains(id) { queue.append(id) }
        persistQueue()
        pumpQueue()
    }

    func retryByRecordID(_ recordID: String) { resumeByRecordID(recordID) }

    func removeFinishedTask(_ recordID: String) {
        let id = resolvedID(recordID)
        guard let state = tasks[id], [.completed, .cancelled].contains(state.status) else { return }
        // The worker still owns cancellation cleanup and blocks the queue until it settles.
        tasks.removeValue(forKey: id)
        descriptors.removeValue(forKey: id)
        contexts.removeValue(forKey: id)
        persistQueue()
    }

    private func resolvedID(_ id: String) -> String { aliases[id] ?? (tasks[id] != nil ? id : AnimeDownloadTaskDescriptor.digest(id)) }

    private func stop(_ id: String, status: AnimeDownloadTaskStatus) {
        queue.removeAll { $0 == id }
        resumeAfterStop.remove(id)
        contexts.removeValue(forKey: id)
        pendingEpisodes.removeValue(forKey: id)
        updateState(id) { $0.status = status; $0.errorMessage = nil }
        if activeTaskId == id {
            stopRequests[id] = status
            activeDownloadTask?.cancel()
            activeExtractor?.cancel()
            activeProcess?.terminate()
        }
        persistQueue()
    }

    private func updateState(_ id: String, mutate: (inout TaskState) -> Void) {
        guard var state = tasks[id] else { return }
        mutate(&state)
        tasks[id] = state
    }

    private func persistQueue() {
        let entries = tasksSorted.compactMap { state -> AnimeDownloadQueueSnapshot.Entry? in
            guard let descriptor = descriptors[state.id] else { return nil }
            return .init(descriptor: descriptor, status: state.status, progress: state.progress,
                         downloadedBytes: state.downloadedBytes, totalBytes: state.totalBytes)
        }
        do {
            let url = Self.queueFileURL
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(AnimeDownloadQueueSnapshot(version: 1, entries: entries)).write(to: url, options: .atomic)
            persistenceError = nil
        } catch { persistenceError = AnimeDownloadError.persistenceFailed.localizedDescription }
    }

    private static var queueFileURL: URL {
        #if DEBUG
        if let root = ProcessInfo.processInfo.environment["WAIFUX_ANIME_DOWNLOAD_TEST_ROOT"] {
            return URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent("tasks-v1.json")
        }
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WaifuX/AnimeDownloadQueue/tasks-v1.json")
    }

    private func pumpQueue() {
        guard activeTaskId == nil, !queue.isEmpty else { return }
        let id = queue.removeFirst()
        guard descriptors[id] != nil else { pumpQueue(); return }
        activeTaskId = id
        activeDownloadTask = Task { @MainActor [weak self] in await self?.runTask(recordID: id) }
    }

    private func resolveContext(_ descriptor: AnimeDownloadTaskDescriptor) async throws -> Context {
        let pending = pendingEpisodes[descriptor.id]
        let rules = await AnimeRuleStore.shared.loadAllRules()
        guard let source = rules.first(where: { $0.id.lowercased() == descriptor.sourceID.lowercased() }) ?? pending?.1 else { throw AnimeDownloadError.sourceUnavailable }
        try Task.checkCancellation()
        var episode = pending?.2 ?? descriptor.episodePageURL.map {
            AnimeDetail.AnimeEpisodeItem(id: descriptor.episodeID, name: descriptor.episodeName,
                episodeNumber: descriptor.episodeNumber, url: $0, thumbnailURL: nil)
        }
        if pending == nil, let detailURL = descriptor.detailPageURL {
            // 页面令牌和临时媒体地址不落盘，从现行详情重新取当前剧集页面。
            do {
                let roads = try await AnimeParser.shared.querychapterRoads(detailURL: detailURL, rule: source)
                let matches = roads.flatMap(\.episodes)
                episode = matches.first(where: { AnimeDownloadTaskDescriptor.safeIdentifier($0.id) == descriptor.episodeID })
                    ?? matches.first(where: { $0.episodeNumber == descriptor.episodeNumber && $0.name == descriptor.episodeName })
                    ?? episode
            } catch AnimeParserError.captchaRequired {
                if let episode { onNeedsVerification?(source, episode) }
                throw AnimeDownloadError.verificationRequired
            }
        }
        guard let episode else { throw AnimeDownloadError.resolutionFailed }
        let extractor = AnimeVideoExtractor()
        activeExtractor = extractor
        defer { extractor.cancel(); activeExtractor = nil }
        let result = await extractor.extractVideoSources(from: episode.url, rule: source)
        try Task.checkCancellation()
        if case .captcha = result {
            onNeedsVerification?(source, episode)
            throw AnimeDownloadError.verificationRequired
        }
        guard case .success(let sources) = result, let first = sources.first,
              let url = URL(string: first.url), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw AnimeDownloadError.resolutionFailed
        }
        let anime = pending?.0 ?? AnimeSearchResult(id: descriptor.animeID, title: descriptor.animeTitle, coverURL: nil,
            detailURL: descriptor.detailPageURL ?? "", sourceId: source.id, sourceName: source.name, latestEpisode: nil, rating: nil)
        return Context(anime: anime, source: source, episode: episode, videoURL: url,
            isHLS: first.type.lowercased().contains("m3u8") || Self.isHLSURL(url),
            httpHeaders: first.httpHeaders ?? AnimeVideoExtractor.requestHeaders(for: url, rule: source, pageURL: episode.url))
    }

    private func runTask(recordID id: String) async {
        defer {
            let stopped = stopRequests.removeValue(forKey: id)
            if stopped == .cancelled { clearPartialFiles(id) }
            activeTaskId = nil
            activeDownloadTask = nil
            activeProcess = nil
            activeExtractor = nil
            let restart = resumeAfterStop.remove(id) != nil
            if !restart {
                contexts.removeValue(forKey: id)
                pendingEpisodes.removeValue(forKey: id)
            }
            if restart { queue.append(id) }
            persistQueue()
            pumpQueue()
        }
        do {
            guard let descriptor = descriptors[id] else { return }
            try Task.checkCancellation()
            updateState(id) { $0.status = .resolving }
            let context: Context
            if let existing = contexts[id] { context = existing } else { context = try await resolveContext(descriptor) }
            try Task.checkCancellation()
            updateState(id) { $0.status = .downloading }
            persistQueue()
            let destination: URL
            if context.isHLS { destination = try await downloadHLS(context: context, id: id) }
            else { destination = try await downloadDirect(context: context, id: id) }
            try Task.checkCancellation()
            guard stopRequests[id] == nil else { throw AnimeDownloadError.cancelled }
            let attrs = try FileManager.default.attributesOfItem(atPath: destination.path)
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            guard size > 0 else { throw AnimeDownloadError.missingOutput }
            var record = AnimeDownloadRecord(anime: context.anime, source: context.source, episode: context.episode,
                localFilePath: destination.path, fileSizeBytes: size, originalURL: nil)
            record.taskIdentity = id
            AnimeDownloadStore.shared.upsert(record)
            updateState(id) { $0.progress = 1; $0.status = .completed; $0.totalBytes = size; $0.downloadedBytes = size }
            persistQueue()
            if let hook = onDownloadCompleted {
                // Hook 有自己的生命周期，暂停/取消下一任务不会中断已完成视频的弹幕缓存。
                Task { @MainActor in await hook(record) }
            }
        } catch {
            guard stopRequests[id] == nil else { return }
            let requiresVerification: Bool
            if case .some(.verificationRequired) = error as? AnimeDownloadError { requiresVerification = true }
            else { requiresVerification = false }
            updateState(id) {
                $0.status = requiresVerification ? .paused : .failed
                $0.errorMessage = (error as? AnimeDownloadError)?.localizedDescription ?? t("下载失败，请重新解析后重试")
            }
        }
    }

    private func downloadDirect(context: Context, id: String) async throws -> URL {
        let destination = try Self.fileURL(for: id, fileExtension: "mp4")
        let resumeURL = destination.appendingPathExtension("resume")
        let fingerprint = AnimeDownloadRequestFingerprint.make(url: context.videoURL, headers: context.httpHeaders)
        let vault = AnimeDownloadResumeVault(url: resumeURL, fingerprint: fingerprint)
        let resumeData = vault.load()
        let coordinator = DirectDownloadCoordinator(destination: destination, vault: vault, usedResumeData: resumeData != nil) { [weak self] written, expected in
            Task { @MainActor [weak self] in
                guard self?.tasks[id]?.status == .downloading else { return }
                self?.updateState(id) {
                    $0.downloadedBytes = written; $0.totalBytes = expected
                    if let expected, expected > 0 { $0.progress = min(0.99, Double(written) / Double(expected)) }
                }
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false // 请求头快照即有效 Cookie，避免共享 jar 改变续传身份。
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: coordinator, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: context.videoURL)
        request.timeoutInterval = 60
        request.allHTTPHeaderFields = context.httpHeaders
        request.httpShouldHandleCookies = false
        let task = resumeData.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: request)
        task.resume()
        do {
            try await withTaskCancellationHandler {
                while !coordinator.isFinished { try await Task.sleep(nanoseconds: 100_000_000) }
                if let error = coordinator.lastFailure { throw error }
                try Task.checkCancellation()
            } onCancel: { coordinator.cancel(task) }
        } catch {
            // 等待取消回调把断点写完；否则立即恢复会与旧会话的 sidecar 写入冲突。
            if Task.isCancelled {
                await withCheckedContinuation { continuation in coordinator.whenSettled { continuation.resume() } }
            }
            throw error
        }
        guard FileManager.default.fileExists(atPath: destination.path) else { throw AnimeDownloadError.missingOutput }
        return destination
    }

    private func downloadHLS(context: Context, id: String) async throws -> URL {
        let destination = try Self.fileURL(for: id, fileExtension: "mp4")
        let video = try Self.fileURL(for: id, fileExtension: "video.part")
        let audio = try Self.fileURL(for: id, fileExtension: "audio.part")
        let staging = try Self.fileURL(for: id, fileExtension: "mux.part.mp4")
        defer { for url in [video, audio, staging] { Self.removeOwnedFile(url) } }
        let plan = try await Self.resolveHLS(playlistURL: context.videoURL, httpHeaders: context.httpHeaders)
        let trackCount = plan.audio == nil ? 1.0 : 2.0
        try await Self.runHLSTrack(plan.video, httpHeaders: context.httpHeaders, output: video) { [weak self] progress in
            Task { @MainActor [weak self] in
                guard self?.tasks[id]?.status == .downloading else { return }
                self?.updateState(id) { $0.progress = progress * 0.9 / trackCount }
            }
        }
        if let playlist = plan.audio {
            try await Self.runHLSTrack(playlist, httpHeaders: context.httpHeaders, output: audio) { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard self?.tasks[id]?.status == .downloading else { return }
                    self?.updateState(id) { $0.progress = (1 + progress) * 0.9 / trackCount }
                }
            }
        }
        try Task.checkCancellation()
        updateState(id) { $0.status = .merging; $0.progress = 0.92 }
        let ffmpeg = Self.locateFFmpeg()
        guard FileManager.default.isExecutableFile(atPath: ffmpeg.path) else { throw AnimeDownloadError.ffmpegNotFound }
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = try Self.localMuxArguments(video: video, audio: plan.audio == nil ? nil : audio, destination: staging)
        process.standardError = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        activeProcess = process
        do {
            while process.isRunning { try await Task.sleep(nanoseconds: 100_000_000) }
            try Task.checkCancellation()
        } catch {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            throw error
        }
        guard process.terminationStatus == 0 else { throw AnimeDownloadError.ffmpegFailed(process.terminationStatus) }
        guard FileManager.default.fileExists(atPath: staging.path) else { throw AnimeDownloadError.missingOutput }
        Self.removeOwnedFile(destination)
        try FileManager.default.moveItem(at: staging, to: destination)
        return destination
    }

    nonisolated static func localMuxArguments(video: URL, audio: URL?, destination: URL) throws -> [String] {
        let urls = [video, destination] + (audio.map { [$0] } ?? [])
        guard urls.allSatisfy({ $0.isFileURL && $0.path.hasPrefix("/") }) else { throw AnimeDownloadError.unsafePath }
        var arguments = ["-nostdin", "-y", "-protocol_whitelist", "file", "-i", video.path]
        if let audio { arguments += ["-protocol_whitelist", "file", "-i", audio.path, "-map", "0:v:0", "-map", "1:a:0"] }
        arguments += ["-c", "copy", "-movflags", "+faststart", destination.path]
        return arguments
    }

    private func clearPartialFiles(_ id: String) {
        for ext in ["mp4", "mp4.resume", "video.part", "audio.part", "mux.part.mp4"] {
            if let url = try? Self.fileURL(for: id, fileExtension: ext) { Self.removeOwnedFile(url) }
        }
    }

    private static func fileURL(for id: String, fileExtension ext: String) throws -> URL {
        let folder = DownloadPathManager.shared.rootFolderURL.appendingPathComponent("Anime", isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(AnimeDownloadTaskDescriptor.digest(id) + "." + ext).standardizedFileURL
        guard file.deletingLastPathComponent().resolvingSymlinksInPath() == folder.resolvingSymlinksInPath(),
              !((try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false) else { throw AnimeDownloadError.unsafePath }
        return file
    }

    private nonisolated static func removeOwnedFile(_ url: URL) {
        guard url.isFileURL, !((try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false) else { return }
        try? FileManager.default.removeItem(at: url.standardizedFileURL)
    }

    static func isHLSURL(_ url: URL) -> Bool {
        let value = url.absoluteString.lowercased()
        return url.pathExtension.lowercased() == "m3u8" || value.contains("format=m3u8") || value.contains("type=m3u8") || url.path.lowercased().contains("/hls/")
    }

    /// 不允许 Homebrew/系统网络版 ffmpeg 兜底。打包脚本提供 --disable-network 的内置版本。
    static func locateFFmpeg() -> URL {
        if let root = Bundle.main.resourceURL {
            for relative in ["Resources/ffmpeg", "ffmpeg"] {
                let url = root.appendingPathComponent(relative)
                if FileManager.default.isExecutableFile(atPath: url.path) { return url }
            }
        }
        #if DEBUG
        let local = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/ffmpeg")
        if FileManager.default.isExecutableFile(atPath: local.path) { return local }
        #endif
        return URL(fileURLWithPath: "/nonexistent/waifux-bundled-ffmpeg")
    }

    // MARK: - HLS：每次获取同时保留 response.url；相对 URI 始终使用最终响应地址。

    struct HLSResource: Sendable {
        let data: Data
        let url: URL
        var text: String { String(decoding: data, as: UTF8.self) }
    }

    struct HLSPlan: Sendable {
        let video: HLSResource
        let audio: HLSResource?
    }

    private struct HLSSegment: Sendable {
        let url: URL
        let keyURL: URL?
        let iv: Data?
        let sequence: Int
        let byteRange: String?
        let initializationURL: URL?
        let initializationRange: String?
    }

    nonisolated static func resolveHLS(playlistURL: URL, httpHeaders: [String: String]) async throws -> HLSPlan {
        var resource = try await fetchResource(playlistURL, headers: httpHeaders)
        var audioURL: URL?
        var visited = Set<URL>()
        for _ in 0..<5 {
            try Task.checkCancellation()
            guard resource.text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") else {
                throw AnimeDownloadError.hlsUnsupported("服务器未返回有效播放列表")
            }
            guard visited.insert(resource.url).inserted else { throw AnimeDownloadError.hlsUnsupported("播放列表循环引用") }
            let lines = resource.text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            var best: (bandwidth: Int, uri: String, audioGroup: String?)?
            for index in lines.indices where lines[index].hasPrefix("#EXT-X-STREAM-INF:") {
                let bandwidth = Int(attributeValue("BANDWIDTH", in: lines[index]) ?? "0") ?? 0
                let uri = lines.dropFirst(index + 1).first(where: { !$0.isEmpty && !$0.hasPrefix("#") })
                if let uri, best == nil || bandwidth > best!.bandwidth {
                    best = (bandwidth, uri, attributeValue("AUDIO", in: lines[index]))
                }
            }
            guard let variant = best else {
                guard !resource.text.contains("#EXT-X-STREAM-INF:") else { throw AnimeDownloadError.hlsUnsupported("主播放列表无可播放变体") }
                var audio: HLSResource?
                if let audioURL {
                    // 音轨也可能经过重定向或一层 master；递归时独立保护深度与循环。
                    let audioPlan = try await resolveHLSAudio(playlistURL: audioURL, headers: httpHeaders)
                    audio = audioPlan
                }
                return HLSPlan(video: resource, audio: audio)
            }
            if let group = variant.audioGroup {
                let renditions = lines.filter {
                    $0.hasPrefix("#EXT-X-MEDIA:") && attributeValue("TYPE", in: $0)?.uppercased() == "AUDIO"
                        && attributeValue("GROUP-ID", in: $0) == group
                }
                guard !renditions.isEmpty else { throw AnimeDownloadError.hlsUnsupported("独立音轨组缺失") }
                let selected = renditions.first(where: { attributeValue("DEFAULT", in: $0)?.uppercased() == "YES" })
                    ?? renditions.first(where: { attributeValue("AUTOSELECT", in: $0)?.uppercased() == "YES" }) ?? renditions[0]
                // URI 缺省表示音频已复用在 variant 中，不新增输入。
                audioURL = try attributeValue("URI", in: selected).map { try remoteURL($0, relativeTo: resource.url) }
            }
            let next = try remoteURL(variant.uri, relativeTo: resource.url)
            resource = try await fetchResource(next, headers: httpHeaders)
        }
        throw AnimeDownloadError.hlsUnsupported("播放列表嵌套过深")
    }

    private nonisolated static func resolveHLSAudio(playlistURL: URL, headers: [String: String]) async throws -> HLSResource {
        var resource = try await fetchResource(playlistURL, headers: headers)
        var visited = Set<URL>()
        for _ in 0..<5 {
            guard resource.text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U"), visited.insert(resource.url).inserted else {
                throw AnimeDownloadError.hlsUnsupported("独立音轨播放列表无效或循环引用")
            }
            let lines = resource.text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard let index = lines.firstIndex(where: { $0.hasPrefix("#EXT-X-STREAM-INF:") }) else { return resource }
            guard let uri = lines.dropFirst(index + 1).first(where: { !$0.isEmpty && !$0.hasPrefix("#") }) else {
                throw AnimeDownloadError.hlsUnsupported("独立音轨无可播放变体")
            }
            resource = try await fetchResource(remoteURL(uri, relativeTo: resource.url), headers: headers)
        }
        throw AnimeDownloadError.hlsUnsupported("独立音轨嵌套过深")
    }

    nonisolated static func runHLSTrack(_ playlist: HLSResource, httpHeaders: [String: String], output outputURL: URL,
                                       onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let segments = try parseHLSSegments(playlist)
        var keyCache: [URL: Data] = [:]
        for keyURL in Set(segments.compactMap(\.keyURL)) {
            let key = try await fetchResource(keyURL, headers: httpHeaders).data
            guard key.count == 16 else { throw AnimeDownloadError.hlsUnsupported("AES-128 密钥长度异常") }
            keyCache[keyURL] = key
        }
        // 只接收本地调用方生成的临时文件路径，不接收播放列表中的本地路径。
        guard outputURL.isFileURL, !((try? outputURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false) else {
            throw AnimeDownloadError.unsafePath
        }
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil) else { throw AnimeDownloadError.unsafePath }
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        var writtenInitialization: String?
        for start in stride(from: 0, to: segments.count, by: 6) {
            try Task.checkCancellation()
            let end = min(start + 6, segments.count)
            let batch = Array(segments[start..<end])
            let keys = keyCache
            let chunks = try await withThrowingTaskGroup(of: (Int, Data).self) { group in
                for (offset, segment) in batch.enumerated() {
                    group.addTask {
                        var data = try await fetchResource(segment.url, headers: httpHeaders, range: segment.byteRange).data
                        if let keyURL = segment.keyURL, let key = keys[keyURL] {
                            var sequence = UInt64(segment.sequence).bigEndian
                            let iv = segment.iv ?? (Data(repeating: 0, count: 8) + withUnsafeBytes(of: &sequence) { Data($0) })
                            guard let plain = decryptAES128CBC(data, key: key, iv: iv) else { throw AnimeDownloadError.hlsUnsupported("分片解密失败") }
                            data = plain
                        }
                        return (offset, data)
                    }
                }
                var ordered = [Data?](repeating: nil, count: batch.count)
                for try await (offset, data) in group { ordered[offset] = data }
                return ordered.compactMap { $0 }
            }
            for (offset, data) in chunks.enumerated() {
                try Task.checkCancellation()
                let segment = batch[offset]
                if let url = segment.initializationURL {
                    let identity = url.absoluteString + (segment.initializationRange ?? "")
                    if writtenInitialization != identity {
                        let initialization = try await fetchResource(url, headers: httpHeaders, range: segment.initializationRange)
                        try output.write(contentsOf: initialization.data)
                        writtenInitialization = identity
                    }
                }
                try output.write(contentsOf: data)
            }
            onProgress(Double(end) / Double(segments.count))
        }
    }

    private nonisolated static func parseHLSSegments(_ playlist: HLSResource) throws -> [HLSSegment] {
        guard playlist.text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") else {
            throw AnimeDownloadError.hlsUnsupported("服务器未返回有效播放列表")
        }
        // 直播快照不能冒充完整缓存；低延迟部分列表和 delta playlist 明确报错。
        guard playlist.text.contains("#EXT-X-ENDLIST") else { throw AnimeDownloadError.hlsUnsupported("直播或未结束播放列表") }
        guard !playlist.text.contains("#EXT-X-SKIP:"), !playlist.text.contains("#EXT-X-GAP") else {
            throw AnimeDownloadError.hlsUnsupported("缺失或增量分片")
        }
        var pendingRange: String?
        var rangeEnd: Int64 = 0
        var previousRangeURL: URL?
        var initializationURL: URL?
        var initializationRange: String?
        var mediaSequence = 0
        var currentKeyURL: URL?
        var currentIV: Data?
        var segments: [HLSSegment] = []
        for raw in playlist.text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                guard let sequence = Int(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)), sequence >= 0 else {
                    throw AnimeDownloadError.hlsUnsupported("分片序号无效")
                }
                mediaSequence = sequence
            } else if line.hasPrefix("#EXT-X-KEY:") {
                let method = (attributeValue("METHOD", in: line) ?? "NONE").uppercased()
                if method == "NONE" { currentKeyURL = nil; currentIV = nil }
                else if method == "AES-128" {
                    guard (attributeValue("KEYFORMAT", in: line) ?? "identity") == "identity" else {
                        throw AnimeDownloadError.hlsUnsupported("非 identity 密钥格式")
                    }
                    guard let uri = attributeValue("URI", in: line) else { throw AnimeDownloadError.hlsUnsupported("AES-128 密钥地址缺失") }
                    currentKeyURL = try remoteURL(uri, relativeTo: playlist.url)
                    if let value = attributeValue("IV", in: line) {
                        guard let iv = hexData(value), iv.count == 16 else { throw AnimeDownloadError.hlsUnsupported("AES-128 IV 无效") }
                        currentIV = iv
                    } else { currentIV = nil }
                } else { throw AnimeDownloadError.hlsUnsupported("加密方式 \(method)") }
            } else if line.hasPrefix("#EXT-X-MAP:") {
                guard currentKeyURL == nil else { throw AnimeDownloadError.hlsUnsupported("加密初始化分片") }
                guard let uri = attributeValue("URI", in: line) else { throw AnimeDownloadError.hlsUnsupported("初始化分片地址缺失") }
                initializationURL = try remoteURL(uri, relativeTo: playlist.url)
                initializationRange = try attributeValue("BYTERANGE", in: line).map { try httpRange($0, previousEnd: 0).header }
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                pendingRange = String(line.dropFirst("#EXT-X-BYTERANGE:".count))
            } else if !line.hasPrefix("#") {
                let url = try remoteURL(line, relativeTo: playlist.url)
                var byteRange: String?
                if let pendingRange {
                    guard pendingRange.contains("@") || previousRangeURL == url else { throw AnimeDownloadError.hlsUnsupported("分片范围缺少起点") }
                    let parsed = try httpRange(pendingRange, previousEnd: rangeEnd)
                    byteRange = parsed.header; rangeEnd = parsed.end; previousRangeURL = url
                } else { previousRangeURL = nil; rangeEnd = 0 }
                pendingRange = nil
                guard segments.count < Int.max - mediaSequence else { throw AnimeDownloadError.hlsUnsupported("分片序号溢出") }
                segments.append(HLSSegment(url: url, keyURL: currentKeyURL, iv: currentIV, sequence: mediaSequence + segments.count,
                    byteRange: byteRange, initializationURL: initializationURL, initializationRange: initializationRange))
            }
        }
        guard !segments.isEmpty else { throw AnimeDownloadError.hlsUnsupported("播放列表无分片") }
        return segments
    }

    private nonisolated static func remoteURL(_ uri: String, relativeTo base: URL) throws -> URL {
        guard let url = URL(string: uri, relativeTo: base)?.absoluteURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            throw AnimeDownloadError.hlsUnsupported("分片或播放列表地址无效")
        }
        return url
    }

    private nonisolated static func httpRange(_ value: String, previousEnd: Int64) throws -> (header: String, end: Int64) {
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 2, let length = Int64(parts[0]), length > 0,
              let start = parts.count == 2 ? Int64(parts[1]) : previousEnd,
              start >= 0, length <= Int64.max - start else { throw AnimeDownloadError.hlsUnsupported("分片范围无效") }
        return ("bytes=\(start)-\(start + length - 1)", start + length)
    }

    nonisolated static func fetchResource(_ url: URL, headers: [String: String], range: String? = nil, attempts: Int = 3) async throws -> HLSResource {
        var lastError: Error = AnimeDownloadError.badResponse(-1)
        for attempt in 0..<max(1, attempts) {
            do {
                try Task.checkCancellation()
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
                request.allHTTPHeaderFields = headers
                request.httpShouldHandleCookies = false
                if let range { request.setValue(range, forHTTPHeaderField: "Range") }
                let configuration = URLSessionConfiguration.ephemeral
                configuration.httpShouldSetCookies = false
                configuration.urlCredentialStorage = nil
                let session = URLSession(configuration: configuration)
                defer { session.invalidateAndCancel() }
                let (data, response) = try await session.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(code) else { throw AnimeDownloadError.badResponse(code) }
                if let range {
                    guard code == 206, let contentRange = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range"),
                          contentRange.hasPrefix(range.replacingOccurrences(of: "bytes=", with: "bytes ") + "/") else {
                        throw AnimeDownloadError.hlsUnsupported("服务器未返回请求的分片范围")
                    }
                }
                guard !data.isEmpty else { throw AnimeDownloadError.missingOutput }
                guard let finalURL = response.url, ["http", "https"].contains(finalURL.scheme?.lowercased() ?? "") else {
                    throw AnimeDownloadError.hlsUnsupported("重定向地址无效")
                }
                return HLSResource(data: data, url: finalURL)
            } catch {
                if Task.isCancelled || error is CancellationError || (error as NSError).code == NSURLErrorCancelled { throw CancellationError() }
                lastError = error
                if attempt + 1 < attempts { try await Task.sleep(nanoseconds: 600_000_000) }
            }
        }
        throw lastError
    }

    private nonisolated static func decryptAES128CBC(_ data: Data, key: Data, iv: Data) -> Data? {
        guard key.count == kCCKeySizeAES128, iv.count == kCCBlockSizeAES128, !data.isEmpty else { return nil }
        var output = Data(count: data.count + kCCBlockSizeAES128)
        var outputLength = 0
        let outputCapacity = output.count
        let status = output.withUnsafeMutableBytes { outBuffer in
            data.withUnsafeBytes { inBuffer in
                key.withUnsafeBytes { keyBuffer in
                    iv.withUnsafeBytes { ivBuffer in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES128),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBuffer.baseAddress, key.count,
                            ivBuffer.baseAddress,
                            inBuffer.baseAddress, data.count,
                            outBuffer.baseAddress, outputCapacity, &outputLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return output.prefix(outputLength)
    }

    /// 精确匹配属性名，避免 BANDWIDTH 命中 AVERAGE-BANDWIDTH，URI 命中其它后缀。
    private nonisolated static func attributeValue(_ name: String, in tag: String) -> String? {
        guard let colon = tag.firstIndex(of: ":") else { return nil }
        var field = ""
        var quoted = false
        var attributes: [String] = []
        for character in tag[tag.index(after: colon)...] {
            if character == "\"" { quoted.toggle() }
            if character == "," && !quoted { attributes.append(field); field = "" }
            else { field.append(character) }
        }
        attributes.append(field)
        for attribute in attributes {
            guard let equals = attribute.firstIndex(of: "=") else { continue }
            let key = attribute[..<equals].trimmingCharacters(in: .whitespaces)
            guard key.caseInsensitiveCompare(name) == .orderedSame else { continue }
            var value = attribute[attribute.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\"") { value.removeFirst(); value.removeLast() }
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private nonisolated static func hexData(_ hex: String) -> Data? {
        var body = hex
        if body.hasPrefix("0x") || body.hasPrefix("0X") { body = String(body.dropFirst(2)) }
        guard !body.isEmpty, body.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(body.count / 2)
        var index = body.startIndex
        while index < body.endIndex {
            let next = body.index(index, offsetBy: 2)
            guard let byte = UInt8(body[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }

}

// MARK: - 加密断点封装

/// Foundation resumeData 包含原请求头和签名 URL，因此用 Keychain 密钥进行 AES-GCM 加密。
/// Keychain 不可用时放弃跨启动续传，不回退到明文。指纹变化先删除旧密文。
private final class AnimeDownloadResumeVault: @unchecked Sendable {
    private struct Envelope: Codable {
        let version: Int
        let fingerprint: String
        let sealed: Data
    }
    private let lock = NSLock()
    private let url: URL
    private let fingerprint: String
    private var enabled = true

    init(url: URL, fingerprint: String) { self.url = url; self.fingerprint = fingerprint }

    func load() -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard let bytes = try? Data(contentsOf: url) else { return nil }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: bytes), envelope.version == 1,
              envelope.fingerprint == fingerprint,
              let key = Self.key(create: false), let box = try? AES.GCM.SealedBox(combined: envelope.sealed),
              let plain = try? AES.GCM.open(box, using: key) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return plain
    }

    func save(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard enabled, let key = Self.key(create: true), let sealed = try? AES.GCM.seal(data, using: key).combined,
              let bytes = try? JSONEncoder().encode(Envelope(version: 1, fingerprint: fingerprint, sealed: sealed)) else { return }
        try? bytes.write(to: url, options: .atomic)
    }

    func clear(disable: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        if disable { enabled = false }
        try? FileManager.default.removeItem(at: url)
    }

    private static func key(create: Bool) -> SymmetricKey? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.waifux.app.anime-download-resume", kSecAttrAccount as String: "aes-gcm-v1"]
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        lookup[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var item: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &item)
        if status == errSecSuccess, let bytes = item as? Data, bytes.count == 32 { return SymmetricKey(data: bytes) }
        guard create, status == errSecItemNotFound else { return nil }
        var bytes = Data(count: 32)
        let result = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard result == errSecSuccess else { return nil }
        var insert = query
        insert[kSecValueData as String] = bytes
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else { return key(create: false) }
        return SymmetricKey(data: bytes)
    }
}

private final class DirectDownloadCoordinator: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let destination: URL
    private let vault: AnimeDownloadResumeVault
    private let usedResumeData: Bool
    private let onProgress: @Sendable (Int64, Int64?) -> Void
    private var finished = false
    private var failure: Error?
    private var lastProgressAt = Date.distantPast
    private var cancelled = false
    private var cancellationDataFinished = false
    private var settledCallbacks: [@Sendable () -> Void] = []

    init(destination: URL, vault: AnimeDownloadResumeVault, usedResumeData: Bool,
         onProgress: @escaping @Sendable (Int64, Int64?) -> Void) {
        self.destination = destination; self.vault = vault; self.usedResumeData = usedResumeData; self.onProgress = onProgress
    }

    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
    var lastFailure: Error? { lock.lock(); defer { lock.unlock() }; return failure }

    func cancel(_ task: URLSessionDownloadTask) {
        lock.lock()
        if finished { cancellationDataFinished = true; lock.unlock(); notifySettled(); return }
        cancelled = true
        lock.unlock()
        task.cancel { [self] data in
            if let data { vault.save(data) }
            lock.lock(); cancellationDataFinished = true; lock.unlock()
            notifySettled()
        }
    }

    func whenSettled(_ callback: @escaping @Sendable () -> Void) {
        lock.lock()
        if finished && (!cancelled || cancellationDataFinished) { lock.unlock(); callback(); return }
        settledCallbacks.append(callback)
        lock.unlock()
    }

    private func notifySettled() {
        lock.lock()
        guard finished && (!cancelled || cancellationDataFinished) else { lock.unlock(); return }
        let callbacks = settledCallbacks
        settledCallbacks.removeAll()
        lock.unlock()
        for callback in callbacks { callback() }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        lock.lock(); let stopped = cancelled; lock.unlock()
        guard !stopped else { return }
        guard let response = downloadTask.response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
              response.mimeType?.lowercased() != "text/html" else {
            lock.lock(); failure = AnimeDownloadError.badResponse((downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0); lock.unlock()
            return
        }
        do {
            // 目标由引擎哈希路径产生，并再次拒绝符号链接。
            guard !((try? destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false) else { throw AnimeDownloadError.unsafePath }
            let fm = FileManager.default
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination.standardizedFileURL) }
            try fm.copyItem(at: location, to: destination)
        } catch { lock.lock(); failure = error; lock.unlock() }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        lock.lock()
        let report = !cancelled && Date().timeIntervalSince(lastProgressAt) >= 0.25
        if report { lastProgressAt = .now }
        lock.unlock()
        if report { onProgress(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let existing = failure; let stopped = cancelled; lock.unlock()
        if existing != nil || (usedResumeData && error != nil && !stopped) { vault.clear(disable: true) }
        if let error {
            lock.lock(); if failure == nil { failure = error }; lock.unlock()
            if existing == nil, (!usedResumeData || stopped),
               let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data { vault.save(data) }
        } else if existing == nil { vault.clear(disable: true) }
        lock.lock(); finished = true; lock.unlock()
        notifySettled()
    }
}
