import Foundation
import Combine
import CommonCrypto
import CryptoKit

// MARK: - 动漫下载引擎
//
// 任务态只在内存里维护（排队/进度），完成后写入 AnimeDownloadStore 的终态记录。
// 不做进程重启恢复：正在下载的集数在 App 退出后回到「未缓存」状态，可重新下载。
//
// 分流：
//  - mp4/webm 等直链 → URLSessionDownloadDelegate（原生断点续传 + 进度回调）
//  - m3u8 (HLS)      → 自解析播放列表：拉分片（6 路并发分批）→ AES-128 解密 → 本地拼接 .ts
//                      → 内置 ffmpeg `-c copy` 纯本地合流成 mp4。
//                      ⚠️ 内置 ffmpeg 是 --disable-network 构建，绝不能给它 http 输入；
//                      所有网络 I/O 都在 Swift 侧完成。
//
// 队列串行执行，同时只跑一个下载，避免多路 HLS 打爆网络。

enum AnimeDownloadError: LocalizedError {
    case cancelled
    case badResponse(Int)
    case hlsUnsupported(String)
    case ffmpegNotFound
    case ffmpegFailed(Int32)
    case missingOutput

    var errorDescription: String? {
        switch self {
        case .cancelled: return t("下载已取消")
        case .badResponse(let code): return String(format: t("下载失败（HTTP %@）"), String(describing: code))
        case .hlsUnsupported(let reason): return String(format: t("该视频流暂不支持下载（%@），可在线观看"), String(describing: reason))
        case .ffmpegNotFound: return t("未找到内置 ffmpeg，无法合成视频")
        case .ffmpegFailed(let code): return String(format: t("视频合成失败（ffmpeg %@）"), String(describing: code))
        case .missingOutput: return t("下载产物缺失")
        }
    }
}

@MainActor
final class AnimeDownloadEngine: ObservableObject {
    static let shared = AnimeDownloadEngine()

    struct TaskState: Identifiable, Equatable {
        let id: String // recordID: "\(ruleId)__\(episodeId)"
        let animeId: String
        var episodeName: String?
        var episodeNumber: Int
        var sourceName: String
        var progress: Double // 0...1
        var downloadedBytes: Int64
        var totalBytes: Int64?
        var isCompleted: Bool
        var errorMessage: String?
    }

    @Published private(set) var tasks: [String: TaskState] = [:]

    private var queue: [String] = []
    private var activeTaskId: String?
    private var cancellationFlags = Set<String>()
    private var activeProcess: Process?
    private var activeDownloadTask: Task<Void, Never>?

    // 上下文快照：enqueue 时存，runTask 时取
    private struct Context {
        let anime: AnimeSearchResult
        let source: AnimeRule
        let episode: AnimeDetail.AnimeEpisodeItem
        let videoURL: URL
        let isHLS: Bool
        let httpHeaders: [String: String]
    }
    private var contexts: [String: Context] = [:]

    private init() {}

    // MARK: - 查询

    func task(for episodeId: String, sourceId: String) -> TaskState? {
        tasks[AnimeDownloadRecord.recordID(ruleId: sourceId, episodeId: episodeId)]
    }

    func isDownloading(episodeId: String, sourceId: String) -> Bool {
        guard let state = task(for: episodeId, sourceId: sourceId) else { return false }
        return !state.isCompleted && state.errorMessage == nil
    }

    /// 只读取消查询（HLS 分片下载循环用；不消费 flag）
    func isCancelRequested(_ recordID: String) -> Bool {
        cancellationFlags.contains(recordID)
    }

    // MARK: - 入口

    /// 发起一集下载。`videoURL` 由调用方（ViewModel）先解析出直链。
    /// `isHLS` 优先取 extractor 返回的 VideoSource.type，URL 形态判定只作兜底。
    func enqueue(
        anime: AnimeSearchResult,
        source: AnimeRule,
        episode: AnimeDetail.AnimeEpisodeItem,
        videoURL: URL,
        isHLS: Bool,
        httpHeaders: [String: String] = [:]
    ) {
        let recordID = AnimeDownloadRecord.recordID(ruleId: source.id, episodeId: episode.id)
        if tasks[recordID]?.errorMessage != nil { tasks.removeValue(forKey: recordID) }
        guard tasks[recordID] == nil else { return }
        guard !AnimeDownloadStore.shared.isDownloaded(episodeId: episode.id, sourceId: source.id) else { return }

        contexts[recordID] = Context(anime: anime, source: source, episode: episode, videoURL: videoURL, isHLS: isHLS, httpHeaders: httpHeaders)
        tasks[recordID] = TaskState(
            id: recordID,
            animeId: anime.id,
            episodeName: episode.name,
            episodeNumber: episode.episodeNumber,
            sourceName: source.name,
            progress: 0,
            downloadedBytes: 0,
            totalBytes: nil,
            isCompleted: false,
            errorMessage: nil
        )
        queue.append(recordID)
        pumpQueue()
    }

    func cancel(episodeId: String, sourceId: String) {
        cancelByRecordID(AnimeDownloadRecord.recordID(ruleId: sourceId, episodeId: episodeId))
    }

    func cancelByRecordID(_ recordID: String) {
        guard tasks[recordID] != nil else { return }
        queue.removeAll { $0 == recordID }
        if activeTaskId == recordID {
            cancellationFlags.insert(recordID)
            activeDownloadTask?.cancel()
            activeProcess?.terminate()
        } else {
            tasks.removeValue(forKey: recordID)
            contexts.removeValue(forKey: recordID)
        }
    }

    private func updateState(_ recordID: String, mutate: (inout TaskState) -> Void) {
        guard var state = tasks[recordID] else { return }
        mutate(&state)
        tasks[recordID] = state
    }

    private func pumpQueue() {
        guard activeTaskId == nil, !queue.isEmpty else { return }
        let next = queue.removeFirst()
        guard let context = contexts[next] else {
            contexts.removeValue(forKey: next)
            tasks.removeValue(forKey: next)
            pumpQueue()
            return
        }
        activeTaskId = next

        activeDownloadTask = Task { @MainActor [weak self] in
            await self?.runTask(context, recordID: next)
        }
    }

    // MARK: - 执行

    private func runTask(_ context: Context, recordID: String) async {
        defer {
            activeTaskId = nil
            activeDownloadTask = nil
            activeProcess = nil
            contexts.removeValue(forKey: recordID)
            if cancellationFlags.remove(recordID) != nil { tasks.removeValue(forKey: recordID) }
            pumpQueue()
        }

        // 整个任务期间保留取消标记，避免合流阶段消费后被误判为成功。
        let isCancelled: @MainActor () -> Bool = { [weak self] in
            self?.cancellationFlags.contains(recordID) ?? true
        }

        do {
            let destinationURL: URL = context.isHLS
                ? try await downloadHLS(context: context, isCancelled: isCancelled)
                : try await downloadDirect(context: context, isCancelled: isCancelled)

            if isCancelled() { return }

            let attrs = try FileManager.default.attributesOfItem(atPath: destinationURL.path)
            let fileSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            guard fileSize > 0 else { throw AnimeDownloadError.missingOutput }

            let record = AnimeDownloadRecord(
                anime: context.anime,
                source: context.source,
                episode: context.episode,
                localFilePath: destinationURL.path,
                fileSizeBytes: fileSize,
                originalURL: context.videoURL.absoluteString
            )
            AnimeDownloadStore.shared.upsert(record)

            updateState(recordID) { state in
                state.progress = 1
                state.isCompleted = true
                state.totalBytes = fileSize
                state.downloadedBytes = fileSize
            }
            // 完成态在 UI 短暂展示后清理
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                guard let self, self.tasks[recordID]?.isCompleted == true else { return }
                self.tasks.removeValue(forKey: recordID)
            }
        } catch {
            if isCancelled() { return }
            updateState(recordID) { state in
                state.errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - 直链下载（delegate 驱动，断点续传 sidecar）

    private func downloadDirect(
        context: Context,
        isCancelled: @escaping @MainActor () -> Bool
    ) async throws -> URL {
        let recordID = AnimeDownloadRecord.recordID(ruleId: context.source.id, episodeId: context.episode.id)
        let destination = Self.fileURL(for: recordID, fileExtension: "mp4")
        let resumeDataURL = destination.appendingPathExtension("resume")

        let usedResumeData = FileManager.default.fileExists(atPath: resumeDataURL.path)

        let onProgress: @Sendable (Int64, Int64?) -> Void = { [weak self] written, expected in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updateState(recordID) { state in
                    state.downloadedBytes = written
                    state.totalBytes = expected
                    if let expected, expected > 0 {
                        state.progress = min(0.99, Double(written) / Double(expected))
                    }
                }
            }
        }

        let coordinator = DirectDownloadCoordinator(
            destination: destination,
            resumeDataURL: resumeDataURL,
            usedResumeData: usedResumeData,
            onProgress: onProgress
        )

        let session = URLSession(configuration: .ephemeral, delegate: coordinator, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let task: URLSessionDownloadTask
        if usedResumeData, let resumeData = try? Data(contentsOf: resumeDataURL) {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            var request = URLRequest(url: context.videoURL)
            request.timeoutInterval = 60
            request.allHTTPHeaderFields = context.httpHeaders
            task = session.downloadTask(with: request)
        }
        coordinator.setTask(task)
        task.resume()

        while !coordinator.isFinished {
            if isCancelled() {
                task.cancel()
                try? FileManager.default.removeItem(at: resumeDataURL)
                throw AnimeDownloadError.cancelled
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }

        if let error = coordinator.lastFailure {
            // 断点 sidecar 已在 coordinator 内按「续传失败则清除」策略处理
            throw error
        }
        guard FileManager.default.fileExists(atPath: destination.path) else {
            throw AnimeDownloadError.missingOutput
        }
        return destination
    }

    // MARK: - HLS (m3u8)：Swift 侧拉流拼接 + 本地 ffmpeg 合流

    private func downloadHLS(
        context: Context,
        isCancelled: @escaping @MainActor () -> Bool
    ) async throws -> URL {
        let recordID = AnimeDownloadRecord.recordID(ruleId: context.source.id, episodeId: context.episode.id)
        let destination = Self.fileURL(for: recordID, fileExtension: "mp4")
        let ffmpegURL = Self.locateFFmpeg()
        guard FileManager.default.isExecutableFile(atPath: ffmpegURL.path) else {
            throw AnimeDownloadError.ffmpegNotFound
        }

        let tsWork = destination.appendingPathExtension("ts")
        try? FileManager.default.removeItem(at: tsWork)
        FileManager.default.createFile(atPath: tsWork.path, contents: nil)

        defer { try? FileManager.default.removeItem(at: tsWork) }

        let onProgress: @Sendable (Double) -> Void = { [weak self] p in
            Task { @MainActor [weak self] in
                self?.updateState(recordID) { state in
                    state.progress = min(0.9, p)
                }
            }
        }
        let cancelCheck: @Sendable () async -> Bool = { [weak self] in
            await self?.isCancelRequested(recordID) ?? false
        }

        try await Self.runHLSDownload(
            playlistURL: context.videoURL,
            httpHeaders: context.httpHeaders,
            outputTS: tsWork,
            onProgress: onProgress,
            isCancelled: cancelCheck
        )
        if isCancelled() { throw AnimeDownloadError.cancelled }

        // 进度推进到合流阶段
        updateState(recordID) { $0.progress = 0.92 }

        // 本地合流：ts → mp4（-c copy，纯本地 I/O）
        let process = Process()
        process.executableURL = ffmpegURL
        process.arguments = [
            "-y",
            "-i", tsWork.path,
            "-c", "copy",
            "-movflags", "+faststart",
            destination.path
        ]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        self.activeProcess = process

        // 排空 stderr 防止管道写满阻塞 ffmpeg
        let drain = Task.detached(priority: .utility) {
            let handle = stderrPipe.fileHandleForReading
            while !Task.isCancelled {
                let data = handle.availableData
                if data.isEmpty { break }
            }
        }

        while process.isRunning {
            if isCancelled() {
                process.terminate()
                break
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        drain.cancel()

        if cancellationFlags.contains(recordID) {
            cancellationFlags.remove(recordID)
            tasks.removeValue(forKey: recordID)
            throw AnimeDownloadError.cancelled
        }
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: destination.path) else {
            if process.terminationStatus == 15 { // SIGTERM = 用户取消
                throw AnimeDownloadError.cancelled
            }
            throw AnimeDownloadError.ffmpegFailed(process.terminationStatus)
        }
        return destination
    }

    // MARK: - HLS 拉流实现（非隔离；全部网络 I/O 在此完成）

    private struct HLSSegment: Sendable {
        let url: URL
        let keyURL: URL?
        let iv: Data?
        let sequence: Int
        let byteRange: String?
        let initializationURL: URL?
        let initializationRange: String?
    }

    private nonisolated static func runHLSDownload(
        playlistURL: URL,
        httpHeaders: [String: String],
        outputTS: URL,
        onProgress: @escaping @Sendable (Double) -> Void,
        isCancelled: @escaping @Sendable () async -> Bool
    ) async throws {
        var baseURL = playlistURL
        var text = String(decoding: try await fetchSegment(playlistURL, headers: httpHeaders), as: UTF8.self)

        // 主播放列表 → 选最高 BANDWIDTH 变体（最多跟两层）
        var depth = 0
        while text.contains("#EXT-X-STREAM-INF"), depth < 2 {
            var best: (bandwidth: Int, uri: String)?
            let lines = text.components(separatedBy: .newlines)
            var i = 0
            while i < lines.count {
                let line = lines[i].trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("#EXT-X-STREAM-INF") {
                    let bandwidth = Int(attributeValue("BANDWIDTH", in: line) ?? "0") ?? 0
                    var j = i + 1
                    while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).hasPrefix("#") { j += 1 }
                    if j < lines.count {
                        let uri = lines[j].trimmingCharacters(in: .whitespaces)
                        if !uri.isEmpty, best == nil || bandwidth > best!.bandwidth {
                            best = (bandwidth, uri)
                        }
                        i = j
                    }
                }
                i += 1
            }
            guard let variant = best else {
                throw AnimeDownloadError.hlsUnsupported("主播放列表无可播放变体")
            }
            baseURL = URL(string: variant.uri, relativeTo: baseURL)?.absoluteURL ?? URL(string: variant.uri)!
            text = String(decoding: try await fetchSegment(baseURL, headers: httpHeaders), as: UTF8.self)
            depth += 1
        }

        guard text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") else {
            throw AnimeDownloadError.hlsUnsupported("服务器未返回有效播放列表")
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

        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                mediaSequence = Int(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)) ?? 0
            } else if line.hasPrefix("#EXT-X-KEY:") {
                let method = (attributeValue("METHOD", in: line) ?? "NONE").uppercased()
                if method == "NONE" {
                    currentKeyURL = nil
                    currentIV = nil
                } else if method == "AES-128" {
                    guard let uri = attributeValue("URI", in: line) else {
                        throw AnimeDownloadError.hlsUnsupported("AES-128 密钥地址缺失")
                    }
                    currentKeyURL = URL(string: uri, relativeTo: baseURL)?.absoluteURL
                    currentIV = attributeValue("IV", in: line).flatMap(hexData)
                } else {
                    throw AnimeDownloadError.hlsUnsupported("加密方式 \(method)")
                }
            } else if line.hasPrefix("#EXT-X-MAP:") {
                guard let uri = attributeValue("URI", in: line),
                      let url = URL(string: uri, relativeTo: baseURL)?.absoluteURL else {
                    throw AnimeDownloadError.hlsUnsupported("初始化分片地址缺失")
                }
                guard currentKeyURL == nil else {
                    throw AnimeDownloadError.hlsUnsupported("加密初始化分片")
                }
                initializationURL = url
                initializationRange = try attributeValue("BYTERANGE", in: line).map { try httpRange($0, previousEnd: 0).header }
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                pendingRange = String(line.dropFirst("#EXT-X-BYTERANGE:".count))
            } else if !line.hasPrefix("#") {
                guard let segURL = URL(string: line, relativeTo: baseURL)?.absoluteURL else { continue }
                var byteRange: String?
                if let pendingRange {
                    guard pendingRange.contains("@") || previousRangeURL == segURL else {
                        throw AnimeDownloadError.hlsUnsupported("分片范围缺少起点")
                    }
                    let parsed = try httpRange(pendingRange, previousEnd: rangeEnd)
                    byteRange = parsed.header
                    rangeEnd = parsed.end
                    previousRangeURL = segURL
                }
                pendingRange = nil
                segments.append(HLSSegment(
                    url: segURL,
                    keyURL: currentKeyURL,
                    iv: currentIV,
                    sequence: mediaSequence + segments.count,
                    byteRange: byteRange,
                    initializationURL: initializationURL,
                    initializationRange: initializationRange
                ))
            }
        }
        guard !segments.isEmpty else {
            throw AnimeDownloadError.hlsUnsupported("播放列表无分片")
        }

        // 预取全部 AES-128 密钥（后续分批下载时纯内存查表）
        var keyCache: [URL: Data] = [:]
        for keyURL in Set(segments.compactMap(\.keyURL)) {
            let key = try await fetchSegment(keyURL, headers: httpHeaders)
            guard key.count == 16 else {
                throw AnimeDownloadError.hlsUnsupported("AES-128 密钥长度异常")
            }
            keyCache[keyURL] = key
        }

        FileManager.default.createFile(atPath: outputTS.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputTS)
        defer { try? output.close() }

        var writtenInitialization: String?
        // 分批并发下载（6 路一批），批内按原序拼接，内存峰值 ≈ 6 × 单分片
        let batchSize = 6
        for batchStart in stride(from: 0, to: segments.count, by: batchSize) {
            if await isCancelled() { throw AnimeDownloadError.cancelled }
            let end = min(batchStart + batchSize, segments.count)
            let batch = Array(segments[batchStart..<end])

            // 把本批需要的密钥快照成 Sendable 元组，避免 group 闭包捕获整个 keyCache 字典
            let batchWork: [(offset: Int, url: URL, key: Data?, iv: Data?, sequence: Int, range: String?)] = batch.enumerated().map { offset, segment in
                (offset, segment.url, segment.keyURL.flatMap { keyCache[$0] }, segment.iv, segment.sequence, segment.byteRange)
            }

            let chunk: [Data] = try await withThrowingTaskGroup(of: (Int, Data).self) { group in
                for work in batchWork {
                    group.addTask {
                        var data = try await fetchSegment(work.url, headers: httpHeaders, range: work.range)
                        if let key = work.key {
                            let iv: Data
                            if let explicit = work.iv {
                                iv = explicit
                            } else {
                                // 隐式 IV = 16 字节大端 Media Sequence Number（高 8 字节补零）
                                var be = UInt64(work.sequence).bigEndian
                                iv = Data(repeating: 0, count: 8) + withUnsafeBytes(of: &be) { Data($0) }
                            }
                            guard let plain = decryptAES128CBC(data, key: key, iv: iv) else {
                                throw AnimeDownloadError.hlsUnsupported("分片解密失败")
                            }
                            data = plain
                        }
                        return (work.offset, data)
                    }
                }
                var out = [Data?](repeating: nil, count: batch.count)
                for try await (offset, data) in group {
                    out[offset] = data
                }
                return out.compactMap { $0 }
            }

            for (offset, data) in chunk.enumerated() {
                let segment = batch[offset]
                if let url = segment.initializationURL {
                    let identity = url.absoluteString + (segment.initializationRange ?? "")
                    if writtenInitialization != identity {
                        let initialization = try await fetchSegment(url, headers: httpHeaders, range: segment.initializationRange)
                        try output.write(contentsOf: initialization)
                        writtenInitialization = identity
                    }
                }
                try output.write(contentsOf: data)
            }
            onProgress(Double(end) / Double(segments.count) * 0.9)
        }
    }

    private nonisolated static func httpRange(_ value: String, previousEnd: Int64) throws -> (header: String, end: Int64) {
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard let length = Int64(parts[0]), length > 0,
              parts.count <= 2,
              let start = parts.count == 2 ? Int64(parts[1]) : previousEnd,
              start >= 0, length <= Int64.max - start else {
            throw AnimeDownloadError.hlsUnsupported("分片范围无效")
        }
        return ("bytes=\(start)-\(start + length - 1)", start + length)
    }

    private nonisolated static func fetchSegment(_ url: URL, headers: [String: String], range: String? = nil, attempts: Int = 3) async throws -> Data {
        var lastError: Error = AnimeDownloadError.badResponse(-1)
        for attempt in 0..<max(1, attempts) {
            do {
                try Task.checkCancellation()
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
                request.allHTTPHeaderFields = headers
                if let range { request.setValue(range, forHTTPHeaderField: "Range") }
                let (data, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(code) else {
                    throw AnimeDownloadError.badResponse(code)
                }
                if let range {
                    guard code == 206, let contentRange = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range"),
                          contentRange.hasPrefix(range.replacingOccurrences(of: "bytes=", with: "bytes ") + "/") else {
                        throw AnimeDownloadError.hlsUnsupported("服务器未返回请求的分片范围")
                    }
                }
                guard !data.isEmpty else { throw AnimeDownloadError.missingOutput }
                return data
            } catch {
                if Task.isCancelled || error is CancellationError || (error as NSError).code == NSURLErrorCancelled { throw CancellationError() }
                lastError = error
                if attempt + 1 < attempts {
                    try? await Task.sleep(nanoseconds: 600_000_000)
                }
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

    /// 解析 HLS tag 属性：ATTRIBUTE=value（value 可带引号）
    private nonisolated static func attributeValue(_ name: String, in tag: String) -> String? {
        guard let range = tag.range(of: "\(name)=", options: .caseInsensitive) else { return nil }
        var rest = tag[range.upperBound...]
        if rest.hasPrefix("\"") {
            rest.removeFirst()
            guard let end = rest.firstIndex(of: "\"") else { return nil }
            return String(rest[..<end])
        }
        let end = rest.firstIndex(of: ",") ?? rest.endIndex
        let value = String(rest[..<end])
        return value.isEmpty ? nil : value
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

    // MARK: - 工具

    /// URL 形态兜底判定（优先用 extractor 的 VideoSource.type）
    static func isHLSURL(_ url: URL) -> Bool {
        let lower = url.absoluteString.lowercased()
        return lower.contains(".m3u8") || lower.contains("format=m3u8") || lower.contains("type=m3u8") || lower.contains("/hls/")
    }

    /// 定位内置 ffmpeg：包内 Resources（Contents/Resources/Resources/ffmpeg，与
    /// WaifuXApp.swift worker 路径策略一致）；Debug 源码运行时回退仓库 Resources/ffmpeg。
    static func locateFFmpeg() -> URL {
        let fm = FileManager.default
        if let resourceURL = Bundle.main.resourceURL {
            let nested = resourceURL.appendingPathComponent("Resources/ffmpeg")
            if fm.isExecutableFile(atPath: nested.path) { return nested }
            let flat = resourceURL.appendingPathComponent("ffmpeg")
            if fm.isExecutableFile(atPath: flat.path) { return flat }
        }
        #if DEBUG
        if #filePath.hasSuffix("/WallHaven/Services/AnimeDownloadEngine.swift") {
            let repo = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent() // Services
                .deletingLastPathComponent() // repo root
                .appendingPathComponent("Resources/ffmpeg")
            if fm.isExecutableFile(atPath: repo.path) { return repo }
        }
        #endif
        for path in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"] where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: "/usr/bin/ffmpeg")
    }

    private static func fileURL(for recordID: String, fileExtension: String) -> URL {
        let folder = animeDownloadsFolderURL
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // episodeId 通常就是 https://…；直接拼接会被解释成子目录，造成 Cocoa 4。
        let fileName = SHA256.hash(data: Data(recordID.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent("\(fileName).\(fileExtension)")
    }

    private static var animeDownloadsFolderURL: URL {
        DownloadPathManager.shared.rootFolderURL.appendingPathComponent("Anime", isDirectory: true)
    }
}

// MARK: - 直链下载协调器（URLSessionDownloadDelegate 桥接）

private final class DirectDownloadCoordinator: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let destination: URL
    private let resumeDataURL: URL
    private let usedResumeData: Bool
    private let onProgress: @Sendable (Int64, Int64?) -> Void

    private var finished = false
    private var failure: Error?
    private var lastProgressAt = Date.distantPast

    init(destination: URL, resumeDataURL: URL, usedResumeData: Bool, onProgress: @escaping @Sendable (Int64, Int64?) -> Void) {
        self.destination = destination
        self.resumeDataURL = resumeDataURL
        self.usedResumeData = usedResumeData
        self.onProgress = onProgress
    }

    var isFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return finished
    }

    var lastFailure: Error? {
        lock.lock(); defer { lock.unlock() }
        return failure
    }

    func setTask(_ task: URLSessionDownloadTask) {
        // task 引用由调用方持有；此处无状态要存（保留接口以便扩展）
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // DownloadDelegate 不会收到 URLSessionDataDelegate 的 didReceive response；
        // 必须在落盘前检查真实响应，否则 403/HTML 会被当成成功视频。
        guard let response = downloadTask.response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode),
              response.mimeType?.lowercased() != "text/html" else {
            lock.lock()
            failure = AnimeDownloadError.badResponse((downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0)
            lock.unlock()
            return
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try? fm.removeItem(at: destination)
        }
        do {
            // URLSession 临时目录与应用数据目录可能跨卷：copy 而非 move
            try fm.copyItem(at: location, to: destination)
            try? fm.removeItem(at: location)
        } catch {
            lock.lock()
            failure = error
            lock.unlock()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        lock.lock()
        let now = Date()
        let shouldReport = now.timeIntervalSince(lastProgressAt) >= 0.25
        if shouldReport { lastProgressAt = now }
        lock.unlock()
        guard shouldReport else { return }
        onProgress(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // finished 必须最后发布；主线程轮询看到完成时，failure 和 resume sidecar 已稳定。
        defer {
            lock.lock()
            finished = true
            lock.unlock()
        }
        lock.lock()
        let existingFailure = failure
        lock.unlock()

        if existingFailure != nil || (usedResumeData && error != nil) {
            try? FileManager.default.removeItem(at: resumeDataURL)
        }
        if let error {
            lock.lock()
            let hadFailure = existingFailure != nil
            if existingFailure == nil { failure = error }
            lock.unlock()

            // 网络中断 → 保存断点数据；已有响应级失败（如 404 以 .cancel 结束）或
            // 续传本身失败 → 不落 sidecar / 清 sidecar，防止坏断点被下次重试复用
            if let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                if usedResumeData || hadFailure {
                    try? FileManager.default.removeItem(at: resumeDataURL)
                } else {
                    try? resumeData.write(to: resumeDataURL)
                }
            }
        } else if existingFailure == nil {
            // 成功完成：清 sidecar
            try? FileManager.default.removeItem(at: resumeDataURL)
        }
    }
}
