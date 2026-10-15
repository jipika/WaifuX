import AVFoundation
import Foundation
import CryptoKit

/// 视频预加载器
///
/// Wallsflow 等 CDN 会声明 `Accept-Ranges: bytes`，但对 Range 请求仍返回整文件 200，
/// AVFoundation 探测 duration/tracks 时会报 byte range length mismatch (-11850)。
/// 因此对受保护远程视频：整文件下载到本地缓存后再用 file URL 交给 AVPlayer。
actor VideoPreloaderActor {
    static let shared = VideoPreloaderActor()

    /// 缓存的 AVAsset 实例（本地 file URL 或可流式远程）
    private var cachedAssets: [URL: AVAsset] = [:]
    /// 远程 URL → 本地缓存文件
    private var localFileByRemote: [URL: URL] = [:]
    /// 正在进行的整文件下载（避免并发重复下同一 URL）
    private var inflightDownloads: [URL: Task<URL, Error>] = [:]

    private let maxCacheCount = 4
    private let fileManager = FileManager.default

    private var previewCacheDirectory: URL {
        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let dir = base.appendingPathComponent("WaifuX/WallsflowPreview", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 预加载视频（失败只打日志，不抛出）
    func preload(url: URL) {
        Task {
            do {
                _ = try await resolvePlayableURL(for: url)
            } catch {
                print("[VideoPreloader] 预加载失败: \(url.lastPathComponent), error: \(error)")
            }
        }
    }

    /// 解析可交给 AVPlayer 的 URL：本地直通；Wallsflow 等整文件落地后返回 file URL。
    func resolvePlayableURL(for url: URL) async throws -> URL {
        if url.isFileURL {
            return url
        }

        // 非 Wallsflow 受保护源：仍可尝试远程 asset（多数 CDN Range 正常）
        guard WallsflowService.isProtectedMediaURL(url) else {
            return url
        }

        if let existing = localFileByRemote[url],
           fileManager.fileExists(atPath: existing.path),
           !Self.looksCorrupt(at: existing) {
            return existing
        }

        if let inflight = inflightDownloads[url] {
            return try await inflight.value
        }

        let task = Task<URL, Error> {
            try await self.downloadProtectedMediaToCache(url)
        }
        inflightDownloads[url] = task
        defer { inflightDownloads[url] = nil }

        let local = try await task.value
        localFileByRemote[url] = local
        trimLocalCacheIfNeeded()
        return local
    }

    /// 获取缓存的 AVAsset（若有）
    func getCachedAsset(for url: URL) -> AVAsset? {
        if let asset = cachedAssets[url] { return asset }
        if let local = localFileByRemote[url] {
            return cachedAssets[local]
        }
        return nil
    }

    func clearCache() {
        cachedAssets.removeAll()
        // 不删磁盘预览缓存，避免反复下 70MB+；仅清内存索引
        localFileByRemote.removeAll()
        for (_, task) in inflightDownloads {
            task.cancel()
        }
        inflightDownloads.removeAll()
    }

    // MARK: - Private

    private func downloadProtectedMediaToCache(_ remoteURL: URL) async throws -> URL {
        let dest = localCacheURL(for: remoteURL)
        if fileManager.fileExists(atPath: dest.path), !Self.looksCorrupt(at: dest) {
            await rememberAsset(for: dest)
            print("[VideoPreloader] 命中预览缓存: \(dest.lastPathComponent)")
            return dest
        }

        let headers = WallsflowService.mediaRequestHeaders(for: remoteURL) ?? [:]
        print("[VideoPreloader] 整文件下载预览: \(remoteURL.lastPathComponent)")
        // 走 WallsflowService 的直连优先路径：CDN 与站点同样按出口 IP 下发 Cloudflare 挑战。
        let data = try await WallsflowService.shared.fetchMediaData(from: remoteURL, headers: headers)

        if Self.looksLikeHTML(data) {
            throw NetworkError.invalidResponse
        }
        // 正常 live wallpaper 远大于 64KB；过小几乎一定是坏响应
        guard data.count > 64_000 else {
            throw NetworkError.invalidResponse
        }

        // 写到临时文件再 atomic replace
        let tmp = dest.appendingPathExtension("download")
        try? fileManager.removeItem(at: tmp)
        try data.write(to: tmp, options: .atomic)
        if fileManager.fileExists(atPath: dest.path) {
            try? fileManager.removeItem(at: dest)
        }
        try fileManager.moveItem(at: tmp, to: dest)

        await rememberAsset(for: dest)
        print("[VideoPreloader] 预览落地完成: \(dest.lastPathComponent), size=\(data.count)")
        return dest
    }

    private func rememberAsset(for fileURL: URL) async {
        let asset = AVURLAsset(url: fileURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        do {
            let duration = try await asset.load(.duration)
            let tracks = try await asset.load(.tracks)
            if let videoTrack = tracks.first(where: { $0.mediaType == .video }) {
                _ = try await videoTrack.load(.naturalSize)
            }
            if cachedAssets.count >= maxCacheCount {
                cachedAssets.removeAll()
            }
            cachedAssets[fileURL] = asset
            print("[VideoPreloader] 预加载完成: \(fileURL.lastPathComponent), duration: \(duration.seconds)s, tracks: \(tracks.count)")
        } catch {
            // 文件已可用，asset 元数据失败不阻塞播放
            print("[VideoPreloader] asset 元数据加载失败(可仍播放): \(error)")
            cachedAssets[fileURL] = asset
        }
    }

    private func localCacheURL(for remoteURL: URL) -> URL {
        let digest = SHA256.hash(data: Data(remoteURL.absoluteString.utf8))
        let hex = digest.compactMap { String(format: "%02x", $0) }.joined()
        let prefix = String(hex.prefix(24))
        // 只认真实媒体扩展名；wallsflow 的预览 URL 是 .mp4 不受影响，
        // 防 CGI 端点名（index.php?do=download）混进缓存命名
        let raw = remoteURL.pathExtension.lowercased()
        let ext = ["mp4", "webm", "mov", "m4v"].contains(raw) ? raw : "mp4"
        return previewCacheDirectory.appendingPathComponent("\(prefix).\(ext)")
    }

    private func trimLocalCacheIfNeeded() {
        // 最多保留 6 个预览文件，按修改时间淘汰
        let dir = previewCacheDirectory
        guard let files = try? fileManager.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let mp4s = files.filter { !$0.pathExtension.lowercased().contains("download") }
        guard mp4s.count > 6 else { return }

        let ranked = mp4s.compactMap { url -> (URL, Date)? in
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return (url, date)
        }
        .sorted { $0.1 > $1.1 }

        for stale in ranked.dropFirst(6) {
            try? fileManager.removeItem(at: stale.0)
            localFileByRemote = localFileByRemote.filter { $0.value != stale.0 }
            cachedAssets[stale.0] = nil
        }
    }

    private static func looksLikeHTML(_ data: Data) -> Bool {
        guard let head = String(data: data.prefix(256), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() else { return false }
        return head.hasPrefix("<!doctype html")
            || head.hasPrefix("<html")
            || head.contains("<head")
    }

    private static func looksCorrupt(at url: URL) -> Bool {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        if size < 64_000 { return true }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return true }
        defer { try? handle.close() }
        let head = handle.readData(ofLength: 256)
        if looksLikeHTML(head) { return true }
        // ftyp box（任意体积 HTML 也可能非 ftyp）
        if head.count >= 8, head[4..<8] == Data("ftyp".utf8) {
            return false
        }
        return true
    }
}

/// 视频预加载器 - 外部调用接口
@MainActor
final class VideoPreloader: ObservableObject {
    static let shared = VideoPreloader()

    private init() {}

    /// 预加载视频
    func preload(url: URL) {
        Task {
            await VideoPreloaderActor.shared.preload(url: url)
        }
    }

    /// 解析可播放 URL（Wallsflow 会先整文件缓存）
    func resolvePlayableURL(for url: URL) async throws -> URL {
        try await VideoPreloaderActor.shared.resolvePlayableURL(for: url)
    }

    /// 获取缓存的 AVAsset
    func getCachedAsset(for url: URL) -> AVAsset? {
        nil
    }

    /// 清除内存缓存
    func clearCache() {
        Task {
            await VideoPreloaderActor.shared.clearCache()
        }
    }
}
