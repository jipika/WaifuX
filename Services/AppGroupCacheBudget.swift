//  AppGroupCacheBudget.swift
//  WaifuX
//
//  App Group 共享容器的总量上限与淘汰算术（纯函数，无副作用）。
//
//  背景：锁屏扩展在沙盒里只能读共享容器，所以「当前桌面壁纸」必须有一份副本
//  落在容器内。跨卷（外置壁纸库 → 内置盘容器）无法 hard link，`linkItem` 必失败
//  并回退成真实的 `copyItem`，于是每换一次壁纸就多一份真副本。
//
//  旧逻辑用「本次进程生命周期内设过的 ID」当白名单（`deployedVideoIDs`），
//  对常驻 + 自动轮换的用户等于只增不减 —— 上千张壁纸轮换一圈就是几十 G。
//
//  这里改成语义化保护：只要还被 prefs / 显示器实例目录引用就绝不动，其余按
//  mtime 从旧到新淘汰，直到总量落回上限以内。本文件只做「算出该删谁」，
//  实际删除由调用方执行，便于单文件编译做回归断言。

import Foundation

/// 共享容器内一个候选淘汰项。`url` 与 `size` 由调用方枚举时填充。
struct AppGroupCacheEntry: Equatable {
    let url: URL
    let size: Int64
    let modifiedAt: Date

    var path: String { url.path }
}

/// 淘汰决策结果：先删 `evicted`（从旧到新排序），不足则不删。
struct AppGroupCacheEvictionPlan: Equatable {
    var evicted: [AppGroupCacheEntry] = []
    var keptBytes: Int64 = 0
    var evictedBytes: Int64 = 0

    var isEmpty: Bool { evicted.isEmpty }
}

enum AppGroupCacheBudget {
    /// 默认总量上限。容器里除视频副本外还有缩略图、静态图与扩展日志，
    /// 2 GiB 对「上千壁纸 + 自动轮换」足够放下当前 + 若干历史副本。
    static let defaultLimitBytes: Int64 = 2 * 1024 * 1024 * 1024

    /// 无论是否超限都至少保留的最近条目数。防止上限被单个大文件撑爆时
    /// 把「刚写进去的那一个」也当成超限候选删掉。
    static let minimumRetainedCount = 2

    /// 保底窗口的**字节**下限：最新的条目累计到这么多就停止扩大窗口。
    ///
    /// 只按「几个」保底对 24MB 级视频太弱（2 个 = 48MB，抖动就可能吃掉 2GiB
    /// 上限的一大截），因此按字节给窗口封顶：窗口在
    /// `minimumRetainedCount` 个 与 保底字节数 之间取小者，谁先满足算谁。
    static let retainedWindowBytes: Int64 = 256 * 1024 * 1024

    /// 依据上限推导保底窗口（字节）。窗口不超过上限的一半，
    /// 否则「保底」会挤掉可回收空间、让上限形同虚设。
    static func retainedWindowSize(limitBytes: Int64) -> Int64 {
        max(0, min(retainedWindowBytes, limitBytes / 2))
    }

    /// 计算淘汰计划。
    ///
    /// - Parameters:
    ///   - entries: 目录内全部候选（含受保护项；受保护项会被自动扣除）。
    ///   - protectedPaths: 绝不可删的绝对路径集合（prefs 引用、当前显示器实例缩略图等）。
    ///   - limitBytes: 总量上限，超过才淘汰。
    /// - Returns: 需要删除的条目（按 mtime 升序 = 最旧优先）。
    ///
    /// 语义：
    /// 1. 受保护项一律保留，且计入占用；
    /// 2. 可淘汰项按 mtime 降序（新→旧）排序，窗口 = 至少 `minimumRetainedCount` 个、
    ///    且不超过 `retainedWindowSize(limitBytes)` 字节，两者取先满足者；
    /// 3. 其后从最旧的开始删，直到「受保护 + 窗口 + 剩余」≤ 上限；
    /// 4. 已在上限内则返回空计划（零删除）。
    static func plan(
        entries: [AppGroupCacheEntry],
        protectedPaths: Set<String>,
        limitBytes: Int64
    ) -> AppGroupCacheEvictionPlan {
        let normalizedProtected = Set(protectedPaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })

        var protectedBytes: Int64 = 0
        var candidates: [AppGroupCacheEntry] = []
        for entry in entries {
            if normalizedProtected.contains(entry.url.standardizedFileURL.path) {
                protectedBytes += max(0, entry.size)
            } else {
                candidates.append(entry)
            }
        }

        // 新的在前；同一时间戳按路径稳定排序，避免计划在不同枚举顺序下抖动。
        let ranked = candidates.sorted {
            if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt > $1.modifiedAt }
            return $0.path < $1.path
        }

        // 保底窗口：最新的若干项无条件保留。数量下限保证「刚写进去的」不被自己删掉，
        // 字节上限避免窗口随大文件无限膨胀。
        let windowBytes = retainedWindowSize(limitBytes: limitBytes)
        var retainedWindow: [AppGroupCacheEntry] = []
        var windowTotal: Int64 = 0
        for entry in ranked {
            let wouldExceedBytes = !retainedWindow.isEmpty && windowTotal + max(0, entry.size) > windowBytes
            if wouldExceedBytes && retainedWindow.count >= minimumRetainedCount { break }
            retainedWindow.append(entry)
            windowTotal += max(0, entry.size)
            if retainedWindow.count >= minimumRetainedCount && windowTotal >= windowBytes { break }
        }
        let evictable = ranked.dropFirst(retainedWindow.count)

        var plan = AppGroupCacheEvictionPlan()
        // 总量 = 受保护 + 保底窗口 + 尚未淘汰的可回收项。
        var keptBytes = protectedBytes + windowTotal
        keptBytes += evictable.reduce(Int64(0)) { $0 + max(0, $1.size) }

        // 超出上限时从最旧（evictable 尾部）开始删。
        if keptBytes > limitBytes {
            for entry in evictable.reversed() {
                if keptBytes <= limitBytes { break }
                keptBytes -= max(0, entry.size)
                plan.evicted.append(entry)
                plan.evictedBytes += max(0, entry.size)
            }
        }

        // evicted 目前是最旧→最新，保持该顺序方便调用方按序删除并打日志。
        plan.keptBytes = keptBytes
        return plan
    }

    /// 目录内容求和（递归，只累加普通文件；目录自身的 inode 大小不计入）。
    ///
    /// `contentsOfDirectory` 的 `.fileSizeKey` 对目录返回的是目录项大小
    /// （通常 64~4096 字节），直接累加会漏掉整棵子树 —— 设置页原先就踩了这个坑。
    static func recursiveSize(of directory: URL, fileManager: FileManager = .default) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        return total
    }

    // MARK: - 共享容器统计

    /// App Group 容器内各分区的字节占用。设置页用它显示「这个目录到底占了多少」。
    struct ContainerUsage: Equatable {
        var videos: Int64 = 0
        var images: Int64 = 0
        var thumbnails: Int64 = 0
        var extensionLog: Int64 = 0

        var total: Int64 { videos + images + thumbnails + extensionLog }
    }

    /// 分区名 → 相对容器根的路径。设置页与清理共用，避免两处漂移。
    static let videoDirectoryName = "WallpaperVideos"
    static let imageDirectoryName = "WallpaperImages"
    static let thumbnailDirectoryName = "WallpaperCache/thumbnails"
    static let extensionLogName = "waifux-extension.log"

    /// 缩略图上限：单独封顶，避免它挤掉视频副本的额度。
    ///
    /// 容器实测 204 张里 198 张是 `<videoID>.jpg` —— 命名只按 videoID 去重、
    /// 跨 ID 永不回收，所以它会随轮换一直涨。480×270 的 JPEG 约 30~60 KB，
    /// 384 MiB ≈ 数千张，足够覆盖上千张壁纸一轮。
    static let thumbnailLimitBytes: Int64 = 384 * 1024 * 1024

    /// 统计 App Group 容器的占用。
    ///
    /// 只统计我们真正会写入缓存的分区，不把 `Library/Preferences`（用户设置）
    /// 与 `socket/` 算成缓存 —— 那些不是可清理对象。
    static func usage(ofContainer container: URL, fileManager: FileManager = .default) -> ContainerUsage {
        var usage = ContainerUsage()
        usage.videos = recursiveSize(of: container.appendingPathComponent(videoDirectoryName, isDirectory: true),
                                     fileManager: fileManager)
        usage.images = recursiveSize(of: container.appendingPathComponent(imageDirectoryName, isDirectory: true),
                                     fileManager: fileManager)
        usage.thumbnails = recursiveSize(of: container.appendingPathComponent(thumbnailDirectoryName, isDirectory: true),
                                         fileManager: fileManager)
        let logURL = container.appendingPathComponent(extensionLogName)
        if let values = try? logURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
           values.isRegularFile == true {
            usage.extensionLog = Int64(values.fileSize ?? 0)
        }
        return usage
    }

    /// 把 prefs 里所有路径字段摊平成受保护集合。
    ///
    /// `PrefsFile` 是 `LockScreenWallpaperService` 的私有嵌套类型，这里用显式
    /// 参数接收已解出的值，避免把文件保护逻辑和 JSON 模型耦合在一起。
    static func protectedPaths(
        legacyVideoPath: String?,
        legacyImagePath: String?,
        perDisplayVideoPaths: [String: String]?,
        perDisplayImagePaths: [String: String]?,
        displayThumbnailPaths: [String] = []
    ) -> Set<String> {
        var result = Set<String>()
        for path in [legacyVideoPath, legacyImagePath] {
            if let path, !path.isEmpty {
                result.insert(URL(fileURLWithPath: path).standardizedFileURL.path)
            }
        }
        for map in [perDisplayVideoPaths, perDisplayImagePaths] {
            for (_, path) in map ?? [:] where !path.isEmpty {
                result.insert(URL(fileURLWithPath: path).standardizedFileURL.path)
            }
        }
        for path in displayThumbnailPaths where !path.isEmpty {
            result.insert(URL(fileURLWithPath: path).standardizedFileURL.path)
        }
        return result
    }

    /// 枚举目录内普通文件为候选条目。
    ///
    /// 大小一律取**磁盘占用**（`totalFileAllocatedSize`，回退 `fileSize`），与
    /// `recursiveSize(of:)` 同一口径 —— 两处若各用一套，上限判断与设置页显示就
    /// 会对不上（一个 1000 字节的文件实际占 4096）。
    static func entries(
        in directory: URL,
        fileManager: FileManager = .default,
        extensions: Set<String>? = nil
    ) -> [AppGroupCacheEntry] {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey, .contentModificationDateKey
        ]
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [AppGroupCacheEntry] = []
        for file in files {
            if let extensions, !extensions.contains(file.pathExtension.lowercased()) { continue }
            let values = try? file.resourceValues(forKeys: keys)
            guard values?.isRegularFile == true else { continue }
            result.append(AppGroupCacheEntry(
                url: file,
                size: Self.allocatedSize(of: values),
                modifiedAt: values?.contentModificationDate ?? .distantPast
            ))
        }
        return result
    }

    /// 单个文件的磁盘占用，与 `recursiveSize(of:)` 同口径。
    static func allocatedSize(of values: URLResourceValues?) -> Int64 {
        guard let values else { return 0 }
        return Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
    }
}
