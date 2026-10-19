//  视频库（扩展侧）— 通过 Unix Socket 从主 App 获取视频信息
//
//  不再扫描共享容器中的视频文件。改为通过 Unix Socket IPC 向主 App 查询
//  视频列表和文件路径。主 App 管理视频文件，扩展只获取元数据和路径引用。

import Foundation
import os

// MARK: - 视频条目模型

struct VideoEntry: Codable, Sendable {
    let id: String
    var name: String
    var filename: String
    var duration: Double
    var fps: Double
    var resolution: CGSize
    var dateAdded: Date
    var variants: [VideoVariant]?
}

struct VideoVariant: Codable, Sendable {
    let filename: String
    let fps: Int
    let resolution: CGSize
}

// MARK: - VideoLibrary

final class VideoLibrary: Sendable {
    static let shared = VideoLibrary()

    private let lock = OSAllocatedUnfairLock(initialState: [VideoEntry]())

    private init() {}

    // MARK: - Public API

    /// 从主 App 获取视频列表（通过 Unix Socket）
    var entries: [VideoEntry] {
        lock.withLock { $0 }
    }

    /// 通过 ID 查找条目
    func entry(for id: String) -> VideoEntry? {
        lock.withLock { entries in
            entries.first { $0.id == id }
        }
    }

    /// 获取视频文件的 URL — 先在共享容器中查找（App 按需复制），
    /// 找不到时通过 Socket 向 App 查询路径。
    func videoURL(for entry: VideoEntry) -> URL {
        // 1. 先检查缓存
        if let cached = WallpaperState.shared.cachedVideoURL,
           FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }
        // 2. 在共享容器中查找（App 只复制当前选中的视频）
        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.waifux.app") {
            let url = container.appendingPathComponent("WallpaperVideos/\(entry.id)/\(entry.filename)")
            if FileManager.default.fileExists(atPath: url.path) {
                WallpaperState.shared.cachedVideoURL = url
                return url
            }
        }
        // 3. 没有找到视频文件（可能在 acquire 路径中同步请求了）
        return WallpaperState.shared.cachedVideoURL ?? URL(fileURLWithPath: "/tmp/placeholder.mp4")
    }

    /// 获取视频文件 URL（通过 ID）
    func videoURL(for id: String) -> URL? {
        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.waifux.app") {
            let videoDir = container.appendingPathComponent("WallpaperVideos")
            let candidates = ["\(id).mp4", "\(id).mov", "\(id).m4v"]
            for name in candidates {
                let url = videoDir.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: url.path) {
                    WallpaperState.shared.cachedVideoURL = url
                    return url
                }
            }
        }
        return nil
    }

    /// 根据策略选择最佳变体（简化版，无变体时返回原始 URL）
    func bestVariantURL(for id: String, policy: PlaybackPolicy) -> URL? {
        guard let entry = entry(for: id) else { return nil }
        guard let variants = entry.variants, !variants.isEmpty else {
            return videoURL(for: entry)
        }
        let sorted = variants.sorted { $0.fps > $1.fps }
        switch policy {
        case .paused: return videoURL(for: entry)
        case .full: _ = sorted.first!
        case .minimal: _ = sorted.last!
        case .reduced: _ = sorted[sorted.count / 2]
        }
        return videoURL(for: entry) // 简化：实际应用中需要 variantURL 逻辑
    }

    /// 从主 App 刷新视频列表（优先 Socket，回退文件扫描）
    func scan() {
        Task {
            // 优先通过 Socket 获取
            let socketVideos = await UnixSocketClient.shared.fetchVideos()
            if !socketVideos.isEmpty {
                let entries = socketVideos.map { info -> VideoEntry in
                    VideoEntry(
                        id: info.id,
                        name: info.name,
                        filename: URL(fileURLWithPath: info.videoPath).lastPathComponent,
                        duration: 0,
                        fps: 0,
                        resolution: .zero,
                        dateAdded: Date()
                    )
                }
                lock.withLock { $0 = entries }
                // 每次 prefs/commands 扫描都会走这里，结果稳定时无需重复记录。
                extLogThrottled(key: "videolib.socketScan", interval: 60,
                                "[VideoLibrary] 通过 Socket 获取到 \(entries.count) 个视频")
                return
            }

            // Socket 不可用（App 未运行等），回退文件扫描
            extLogThrottled(key: "videolib.socketUnavailable", interval: 600,
                            "[VideoLibrary] Socket 不可用，回退文件扫描")
            scanFiles()
        }
    }

    /// 回退方案：扫描共享容器中的视频文件
    private func scanFiles() {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.waifux.app") else { return }
        let videoDir = container.appendingPathComponent("WallpaperVideos")
        guard let files = try? FileManager.default.contentsOfDirectory(at: videoDir, includingPropertiesForKeys: nil) else {
            lock.withLock { $0 = [] }
            return
        }

        let entries = files
            .filter { ["mp4", "mov", "m4v"].contains($0.pathExtension.lowercased()) }
            .map { file -> VideoEntry in
                let id = file.deletingPathExtension().lastPathComponent
                return VideoEntry(
                    id: id,
                    name: id,
                    filename: file.lastPathComponent,
                    duration: 0,
                    fps: 0,
                    resolution: .zero,
                    dateAdded: Date()
                )
            }
            .sorted { $0.id < $1.id }

        lock.withLock { $0 = entries }
        extLog("[VideoLibrary] 文件扫描到 \(entries.count) 个视频")
    }

    /// 删除视频（通过 Socket 通知 App）
    func removeVideo(id: String) {
        lock.withLock { entries in
            entries.removeAll { $0.id == id }
        }
        extLog("[VideoLibrary] 已删除视频: \(id)")
    }
}

// MARK: - 查找函数

func findVideoURL(videoID: String? = nil) -> URL? {
    if videoID == nil,
       let cached = WallpaperState.shared.cachedVideoURL,
       FileManager.default.fileExists(atPath: cached.path) {
        return cached
    }

    if let videoID, !videoID.isEmpty {
        if let url = VideoLibrary.shared.videoURL(for: videoID),
           FileManager.default.fileExists(atPath: url.path) {
            WallpaperState.shared.cachedVideoURL = url
            return url
        }
        // 旧格式回退：平面目录
        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.waifux.app") {
            let videoDir = container.appendingPathComponent("WallpaperVideos")
            for name in ["\(videoID).mp4", "\(videoID).mov", "\(videoID).m4v"] {
                let url = videoDir.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: url.path) {
                    WallpaperState.shared.cachedVideoURL = url
                    return url
                }
            }
        }
        extLog("[VideoLibrary] ⚠️ 未找到 videoID=\(videoID) 的视频")
    }

    if let mirrored = currentMirroringSourceURL() {
        WallpaperState.shared.cachedVideoURL = mirrored
        return mirrored
    }

    if let first = VideoLibrary.shared.entries.first,
       let url = VideoLibrary.shared.videoURL(for: first.id),
       FileManager.default.fileExists(atPath: url.path) {
        WallpaperState.shared.cachedVideoURL = url
        return url
    }

    return nil
}

func findImageURL(sourceID: String? = nil) -> URL? {
    if sourceID == nil,
       let cached = WallpaperState.shared.cachedImageURL,
       FileManager.default.fileExists(atPath: cached.path) {
        return cached
    }

    if let sourceID, !sourceID.isEmpty {
        if let path = UnixSocketClient.shared.fetchVideoPathSync(for: sourceID) {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) {
                WallpaperState.shared.cachedImageURL = url
                return url
            }
        }
        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.waifux.app") {
            let imageDir = container.appendingPathComponent("WallpaperImages")
            for ext in ["jpg", "jpeg", "png", "heic", "webp", "tiff", "bmp"] {
                let url = imageDir.appendingPathComponent("\(sourceID).\(ext)")
                if FileManager.default.fileExists(atPath: url.path) {
                    WallpaperState.shared.cachedImageURL = url
                    return url
                }
            }
        }
    }

    if sourceID == nil,
       let mirrored = currentMirroringImageURL() {
        WallpaperState.shared.cachedImageURL = mirrored
        return mirrored
    }

    return nil
}

private func currentMirroringSourceURL() -> URL? {
    struct MirroringPrefs: Decodable {
        let currentVideoPath: String?
    }

    guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.waifux.app") else {
        return nil
    }
    let prefsURL = container.appendingPathComponent("waifux-wallpaper-prefs.json")
    guard let data = try? Data(contentsOf: prefsURL),
          let prefs = try? JSONDecoder().decode(MirroringPrefs.self, from: data),
          let path = prefs.currentVideoPath,
          !path.isEmpty else {
        return nil
    }

    let url = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: url.path) else {
        extLog("[VideoLibrary] ⚠️ prefs currentVideoPath 不存在: \(path)")
        return nil
    }
    return url
}

private func currentMirroringImageURL() -> URL? {
    struct MirroringPrefs: Decodable {
        let currentImagePath: String?
    }

    guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.waifux.app") else {
        return nil
    }
    let prefsURL = container.appendingPathComponent("waifux-wallpaper-prefs.json")
    guard let data = try? Data(contentsOf: prefsURL),
          let prefs = try? JSONDecoder().decode(MirroringPrefs.self, from: data),
          let path = prefs.currentImagePath,
          !path.isEmpty else {
        return nil
    }

    let url = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: url.path) else {
        extLog("[VideoLibrary] ⚠️ prefs currentImagePath 不存在: \(path)")
        return nil
    }
    return url
}
