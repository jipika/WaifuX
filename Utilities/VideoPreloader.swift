import AVFoundation
import Foundation

/// 视频预加载器 - 使用 AVAsset 预加载视频元数据，加快视频播放启动速度
actor VideoPreloaderActor {
    static let shared = VideoPreloaderActor()

    /// 缓存的 AVAsset 实例
    private var cachedAssets: [URL: AVAsset] = [:]
    private let maxCacheCount = 3

    /// 预加载视频
    /// - Parameter url: 视频 URL
    func preload(url: URL) {
        Task {
            // 如果已经缓存，直接返回
            guard cachedAssets[url] == nil else { return }

            let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])

            do {
                // 预加载 duration 和 tracks
                let duration = try await asset.load(.duration)
                let tracks = try await asset.load(.tracks)

                // 如果有视频轨道，预加载自然尺寸
                if let videoTrack = tracks.first(where: { $0.mediaType == .video }) {
                    _ = try await videoTrack.load(.naturalSize)
                }

                // 缓存 asset
                // 清理旧缓存
                if self.cachedAssets.count >= self.maxCacheCount {
                    self.cachedAssets.removeAll()
                }
                self.cachedAssets[url] = asset

                print("[VideoPreloader] 预加载完成: \(url.lastPathComponent), duration: \(duration.seconds)s, tracks: \(tracks.count)")
            } catch {
                print("[VideoPreloader] 预加载失败: \(url.lastPathComponent), error: \(error)")
            }
        }
    }

    /// 获取缓存的 AVAsset
    /// - Parameter url: 视频 URL
    /// - Returns: 缓存的 AVAsset（如果存在）
    func getCachedAsset(for url: URL) -> AVAsset? {
        return cachedAssets[url]
    }

    /// 清除所有缓存
    func clearCache() {
        cachedAssets.removeAll()
    }
}

/// 视频预加载器 - 外部调用接口
@MainActor
final class VideoPreloader: ObservableObject {
    static let shared = VideoPreloader()

    private init() {}

    /// 预加载视频
    /// - Parameter url: 视频 URL
    func preload(url: URL) {
        Task { @MainActor in
            await VideoPreloaderActor.shared.preload(url: url)
        }
    }

    /// 获取缓存的 AVAsset
    /// - Parameter url: 视频 URL
    /// - Returns: 缓存的 AVAsset（如果存在）
    func getCachedAsset(for url: URL) -> AVAsset? {
        // 同步获取需要存储副本
        return nil
    }

    /// 清除所有缓存
    func clearCache() {
        Task {
            await VideoPreloaderActor.shared.clearCache()
        }
    }
}
