import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import os

/// 一段 Range 下载的数据与元信息（抽帧服务与分段下载器共用）。
private struct PosterSegment {
    let data: Data
    /// 服务端 `Content-Range` 给出的**完整文件长度**
    let totalLength: Int64?
}

/// 封面抽帧失败原因。
enum DynamicWallpaperPosterError: LocalizedError {
    case rangeUnsupported
    case emptyPayload
    case frameUnavailable

    var errorDescription: String? {
        switch self {
        case .rangeUnsupported:
            return "封面抽帧：服务端不支持 Range 分段请求"
        case .emptyPayload:
            return "封面抽帧：分段数据为空"
        case .frameUnavailable:
            return "封面抽帧：无法从视频中取出可用帧"
        }
    }
}

/// 「动态桌面（DongTai）」视频封面（poster）本地生成服务。
///
/// ## 为什么必须本地生成
/// 旧阿里云 OSS 的 `?x-oss-process=video/snapshot,...` 截图接口随数据源迁移一并失效：
/// 新 CDN `cdn.dynamicwallpaperengine.com`（Cloudflare 前置的静态桶）会**完整忽略**该 query
/// ——2026-10-08 实测连强制回源（cache MISS）也返回原始 MP4（`content-type: video/mp4`、
/// 文件头 `ftypisom`、88MB），Kingfisher 拿到视频字节必然解码失败，封面永远空着；
/// 服务端也不再有截图资源（`WallpaperEngine/Screenshot/` 及全部子域路径实测 404）。
///
/// ## 做法
/// 1. 并行发两个 Range 请求：首段 `bytes=0-(HEAD-1)`、尾段后缀 `bytes=-TAIL`
///    （老条目 moov 在文件头、新条目 HandBrake 输出 moov 在文件尾，两段都取才能通用；
///    后缀 Range 不需要预先知道文件长度）；
/// 2. 按**真实偏移**写成稀疏文件——首段落 0、尾段落 `total-TAIL`、中间留空洞
///    （APFS 只分配实际写入的字节；实测 96MB 视频只占 2MB 磁盘）；
/// 3. `AVAssetImageGenerator` 抽帧：先 1s（规避黑首帧），失败退 0s；
///    两者都失败再拉宽首段重试一次（个别高码率视频首个关键帧落在 1MB 之后）；
/// 4. JPEG 编码后进内存 + 磁盘缓存（`Caches/WaifuX/DongtaiPosters`）。
///
/// ## 实测（本机 2026-10-08）
/// - 首段 1MB：1.35s / 尾段 512KB 同量级；本地抽帧 0.11～0.33s
/// - 抽样 8 个条目：首段 1MB + 尾段 512KB 覆盖 7/8，余下 1 个（96MB 高码率）加宽首段后成功
/// - 抽帧结果经 `maximumSize` 约束到 960pt，探索页卡片分辨率足够
actor DynamicWallpaperPosterService {
    static let shared = DynamicWallpaperPosterService()

    // MARK: - 参数

    /// 首段字节数：覆盖 mdat 起始与首个关键帧
    private static let headByteCount = 1_048_576
    /// 尾段字节数：覆盖 moov（实测 96MB 视频的 moov 约 25KB）
    private static let tailByteCount = 524_288
    /// 首帧更靠后的高码率视频：加宽首段（差量续传，不重复下载）后重试
    private static let extendedHeadByteCount = 4_194_304
    /// 抽帧输出长边
    private static let frameMaximumSize: CGFloat = 960
    /// 抽帧时间点候选：1s 规避黑首帧，0s 兜底
    private static let frameTimes: [Double] = [1.0, 0.0]
    /// 抽帧质量
    private static let jpegQuality: CGFloat = 0.85

    private static let logger = Logger(subsystem: "com.waifux.app", category: "DongtaiPoster")

    // MARK: - 状态

    private let memoryCache = NSCache<NSString, NSData>()
    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    /// 进行中的抽帧任务（同一视频并发只跑一次）
    private var inflight: [String: Task<Data, Error>] = [:]

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        cacheDirectory = caches
            .appendingPathComponent("WaifuX", isDirectory: true)
            .appendingPathComponent("DongtaiPosters", isDirectory: true)
        memoryCache.countLimit = 256
    }

    // MARK: - 对外入口

    /// 取（必要时生成）封面的 JPEG 数据。
    /// - Parameter videoURL: 视频的远程地址（CDN 上的 mp4）。
    func posterJPEG(for videoURL: URL) async throws -> Data {
        let key = Self.cacheKey(for: videoURL)

        if let cached = memoryCache.object(forKey: key as NSString) {
            return cached as Data
        }
        let diskURL = cacheDirectory.appendingPathComponent(key)
        if let disk = try? Data(contentsOf: diskURL), !disk.isEmpty {
            memoryCache.setObject(disk as NSData, forKey: key as NSString)
            return disk
        }
        if let running = inflight[key] {
            return try await running.value
        }

        let task = Task<Data, Error> { [weak self] in
            guard let self else { throw DynamicWallpaperPosterError.frameUnavailable }
            return try await self.generatePoster(for: videoURL)
        }
        inflight[key] = task

        do {
            let data = try await task.value
            inflight[key] = nil
            // 缓存写入留在 actor 内（NSCache 非 Sendable，不能跨隔离边界搬运）
            memoryCache.setObject(data as NSData, forKey: key as NSString)
            storeToDisk(data, at: diskURL)
            return data
        } catch {
            inflight[key] = nil
            throw error
        }
    }

    // MARK: - 生成流程

    private func generatePoster(for videoURL: URL) async throws -> Data {
        let tempURL = fileManager.temporaryDirectory
            .appendingPathComponent("waifux-dongtai-poster-\(UUID().uuidString).mp4")
        defer { try? fileManager.removeItem(at: tempURL) }

        // 首段 + 尾段并行；尾段失败不致命（老条目 moov 本就在头部）
        async let headSegment = Self.fetchSegment(
            videoURL: videoURL,
            rangeHeader: "bytes=0-\(Self.headByteCount - 1)",
            byteLimit: Self.headByteCount
        )
        async let tailSegment = Self.fetchSegment(
            videoURL: videoURL,
            rangeHeader: "bytes=-\(Self.tailByteCount)",
            byteLimit: Self.tailByteCount
        )

        let head = try await headSegment
        let tail = try? await tailSegment
        guard !head.data.isEmpty else { throw DynamicWallpaperPosterError.emptyPayload }

        let totalLength = head.totalLength ?? Int64(head.data.count)
        try Self.writeSparseFile(
            head: head.data,
            tail: tail?.data,
            totalLength: totalLength,
            to: tempURL
        )

        for seconds in Self.frameTimes {
            if let jpeg = await Self.extractJPEG(from: tempURL, seconds: seconds) {
                return jpeg
            }
        }

        // 首个关键帧落在首段之外（实测高码率 96MB 条目需要 4MB）：差量续传首段后重试
        let deltaStart = head.data.count
        if deltaStart < Self.extendedHeadByteCount,
           let delta = try? await Self.fetchSegment(
               videoURL: videoURL,
               rangeHeader: "bytes=\(deltaStart)-\(Self.extendedHeadByteCount - 1)",
               byteLimit: Self.extendedHeadByteCount - deltaStart
           ),
           !delta.data.isEmpty {
            var merged = head.data
            merged.append(delta.data)
            try Self.writeSparseFile(
                head: merged,
                tail: tail?.data,
                totalLength: head.totalLength ?? Int64(merged.count),
                to: tempURL
            )
            for seconds in Self.frameTimes {
                if let jpeg = await Self.extractJPEG(from: tempURL, seconds: seconds) {
                    return jpeg
                }
            }
        }

        Self.logger.warning("动态桌面封面抽帧失败 video=\(videoURL.lastPathComponent, privacy: .public)")
        throw DynamicWallpaperPosterError.frameUnavailable
    }

    private func storeToDisk(_ data: Data, at url: URL) {
        do {
            try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            // 落盘失败只影响下次启动的复用，不影响本次显示
            Self.logger.debug("动态桌面封面落盘失败: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Range 下载

    /// 单段 Range 下载：默认走系统代理设置，失败后直连重试一次。
    private static func fetchSegment(
        videoURL: URL,
        rangeHeader: String,
        byteLimit: Int
    ) async throws -> PosterSegment {
        do {
            return try await RangeSegmentFetcher(byteLimit: byteLimit)
                .run(url: videoURL, rangeHeader: rangeHeader, bypassSystemProxy: false)
        } catch {
            return try await RangeSegmentFetcher(byteLimit: byteLimit)
                .run(url: videoURL, rangeHeader: rangeHeader, bypassSystemProxy: true)
        }
    }

    // MARK: - 稀疏文件

    /// 把首段/尾段按真实偏移写进同一文件，中间留空洞。
    /// - 顺序关键：先写数据、最后 `truncate` 到总长，APFS 才把它当稀疏文件（不实占磁盘）。
    private static func writeSparseFile(
        head: Data,
        tail: Data?,
        totalLength: Int64,
        to url: URL
    ) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: head)

        if let tail, !tail.isEmpty, totalLength > 0 {
            let tailOffset = max(0, totalLength - Int64(tail.count))
            try handle.seek(toOffset: UInt64(tailOffset))
            try handle.write(contentsOf: tail)
        }

        let end = max(totalLength, Int64(head.count))
        try handle.truncate(atOffset: UInt64(end))
    }

    // MARK: - 抽帧

    /// 对本地（可能是稀疏的）MP4 抽一帧并编码为 JPEG。
    private static func extractJPEG(from fileURL: URL, seconds: Double) async -> Data? {
        let asset = AVURLAsset(url: fileURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: frameMaximumSize, height: frameMaximumSize)
        // 容忍度放宽：稀疏文件里精确位置可能不可达，取到附近的关键帧即可
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)

        guard let result = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)),
              let data = jpegData(from: result.image) else {
            return nil
        }
        return data
    }

    private static func jpegData(from cgImage: CGImage) -> Data? {
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            buffer as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination,
            cgImage,
            [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return buffer as Data
    }

    // MARK: - 缓存键

    private static func cacheKey(for videoURL: URL) -> String {
        let name = videoURL.lastPathComponent
        let stem = name.hasSuffix(".mp4") ? String(name.dropLast(4)) : name
        return stem.isEmpty ? UUID().uuidString + ".jpg" : stem + ".jpg"
    }
}

// MARK: - 带响应校验与字节上限的分段下载

/// 只取指定 Range 的一段字节：
/// - 校验响应必须是 `206`（`200` 说明服务端忽略了 Range，会返回整包 → 立即取消，避免下载整段视频）；
/// - 顺带从 `Content-Range` 里取出完整文件长度；
/// - 累积到上限即主动取消（即使服务端多给了也不继续收）。
private final class RangeSegmentFetcher: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let byteLimit: Int
    private let lock = NSLock()
    private var buffer = Data()
    private var totalLength: Int64?
    private var continuation: CheckedContinuation<PosterSegment, Error>?
    private var finished = false
    private var session: URLSession?

    init(byteLimit: Int) {
        self.byteLimit = byteLimit
        super.init()
    }

    func run(url: URL, rangeHeader: String, bypassSystemProxy: Bool) async throws -> PosterSegment {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation

            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 25
            configuration.timeoutIntervalForResource = 50
            configuration.httpMaximumConnectionsPerHost = 4
            if bypassSystemProxy {
                // 空字典 = 不使用任何代理（nil 会继续跟随系统设置）
                configuration.connectionProxyDictionary = [:]
            }
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            self.session = session

            var request = URLRequest(url: url)
            request.setValue(rangeHeader, forHTTPHeaderField: "Range")
            let task = session.dataTask(with: request)
            task.resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 206 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            completionHandler(.cancel)
            finish(.failure(status == 200
                ? DynamicWallpaperPosterError.rangeUnsupported
                : DynamicWallpaperPosterError.emptyPayload))
            return
        }
        if let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
           let totalPart = contentRange.split(separator: "/").last,
           let total = Int64(totalPart), total > 0 {
            lock.lock(); totalLength = total; lock.unlock()
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        var reachedLimit = false
        if !finished {
            buffer.append(data)
            reachedLimit = buffer.count >= byteLimit
        }
        lock.unlock()

        if reachedLimit {
            dataTask.cancel()
            finish(.success(snapshot()))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, (error as? URLError)?.code != .cancelled {
            finish(.failure(error))
        } else {
            finish(.success(snapshot()))
        }
    }

    private func snapshot() -> PosterSegment {
        lock.lock()
        defer { lock.unlock() }
        var data = buffer
        if data.count > byteLimit {
            data = data.prefix(byteLimit)
        }
        return PosterSegment(data: data, totalLength: totalLength)
    }

    private func finish(_ result: Result<PosterSegment, Error>) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let session = self.session
        self.session = nil
        lock.unlock()

        session?.invalidateAndCancel()
        switch result {
        case .success(let segment):
            continuation?.resume(returning: segment)
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
    }
}
