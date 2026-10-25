import AppKit
import Foundation

// 回归：WallpaperSystemCacheJanitor 的两个已修缺陷。
//
// 工程没有 XCTest target（见 Rules/构建与测试约定），本文件按仓库惯例单独编译运行：
//   xcrun swiftc -swift-version 6 -parse-as-library \
//     Utilities/AppLogger.swift BackgroundAgent/BackgroundRuntimeRole.swift \
//     BackgroundAgent/WaifuXPreferences.swift BackgroundAgent/BackgroundAgentWire.swift \
//     Services/WallpaperSystemCacheJanitor.swift \
//     Tests/WallpaperCacheJanitorRegression.swift -o /tmp/janreg && /tmp/janreg
//
// 本测试只覆盖三个纯函数：sweep / isManagedCachePath / probeEmptyRoot，
// 它们都不碰 DesktopWallpaperSyncManager。后者只被 currentWallpaperPaths()（MainActor）引用，
// 而该函数在本测试里从未被调用（protectedPaths 一律显式传入），
// 故文件末尾放一个最小桩件顶替它——拖入真实实现会级联缺 32 个符号，得不偿失。
// ⚠️ 不要把真实 Services/DesktopWallpaperSyncManager.swift 一起编进本命令，会重复定义。

@main
struct WallpaperCacheJanitorRegression {
    struct Failure: Error { let message: String }

    static func main() {
        do {
            try protectedAerialVideosSurviveSweep()
            try crossedThresholdCleansBmpButKeepsVideos()
            try blockedRootIsRecordedNotSilenced()
            try genuinelyEmptyRootDoesNotPolluteBlocked()
            print("✓ WallpaperCacheJanitor 回归全部通过")
        } catch {
            print("✗ WallpaperCacheJanitor 回归失败: \(error)")
            exit(1)
        }
    }

    // MARK: - 用例

    /// 缺陷 1：retentionTarget(100MB) 小于单条航拍视频(200–700MB)，
    /// 旧白名单把 aerials/videos 当作可再生缓存，一旦触发就整批删除 → 系统重新全量下载。
    static func protectedAerialVideosSurviveSweep() throws {
        let root = try scratchDir("videos")
        let vids = root.appendingPathComponent("aerials/videos", isDirectory: true)
        let thumbs = root.appendingPathComponent("aerials/thumbnails", isDirectory: true)
        try FileManager.default.createDirectory(at: thumbs, withIntermediateDirectories: true)

        for i in 0..<6 { try write(vids.appendingPathComponent("Aerial_\(i).mov"), mb: 450) }
        for i in 0..<200 { try write(thumbs.appendingPathComponent("t\(i).jpg"), bytes: 60 * 1024) }

        let result = WallpaperSystemCacheJanitor.sweep(
            roots: [root], protectedPaths: [],
            triggerThreshold: 2 * 1024 * 1024 * 1024,   // 未越阈值：本用例只验白名单
            retentionTarget: 100 * 1024 * 1024, dryRun: false
        )
        // 先验白名单本身（最直接的守护），再验阈值行为
        let video = vids.appendingPathComponent("Aerial_0.mov")
        let thumb = thumbs.appendingPathComponent("t0.jpg")
        guard !WallpaperSystemCacheJanitor.isManagedCachePath(root: root, fileURL: video) else {
            throw Failure(message: "aerials/videos 仍被当作可清理缓存（会诱发航拍重下）")
        }
        guard WallpaperSystemCacheJanitor.isManagedCachePath(root: root, fileURL: thumb) else {
            throw Failure(message: "aerials/thumbnails 应继续参与水位回收")
        }
        // 白名单修好后，航拍视频不再计入水位 ⇒ 本用例不应触发
        guard !result.triggered else {
            throw Failure(message: "航拍视频被计入水位（deleted=\(result.deletedCount)），白名单未生效")
        }
        _ = result
    }

    /// 越过阈值时：只回收解码缓存，航拍视频必须原样存活。
    static func crossedThresholdCleansBmpButKeepsVideos() throws {
        let root = try scratchDir("crossed")
        let ext = root.appendingPathComponent("extension-com.apple.wallpaper.extension.image", isDirectory: true)
        let vids = root.appendingPathComponent("aerials/videos", isDirectory: true)
        try FileManager.default.createDirectory(at: vids, withIntermediateDirectories: true)

        for i in 0..<100 { try write(ext.appendingPathComponent("b\(i).bmp"), mb: 24, ageSeconds: 86_400) }
        for i in 0..<6 { try write(vids.appendingPathComponent("Aerial_\(i).mov"), mb: 450) }

        let result = WallpaperSystemCacheJanitor.sweep(
            roots: [root], protectedPaths: [],
            triggerThreshold: 2 * 1024 * 1024 * 1024,
            retentionTarget: 100 * 1024 * 1024, dryRun: false
        )
        guard result.triggered, result.deletedCount > 0 else {
            throw Failure(message: "2.4GB 解码缓存应触发清理，实际 deleted=\(result.deletedCount)")
        }
        let survivors = (try? FileManager.default.contentsOfDirectory(atPath: vids.path)) ?? []
        guard survivors.count == 6 else {
            throw Failure(message: "航拍视频被删：存活 \(survivors.count)/6")
        }
        let bmpLeft = (try? FileManager.default.contentsOfDirectory(atPath: ext.path))?.count ?? -1
        guard bmpLeft < 100 else { throw Failure(message: "解码缓存未被回收，剩余 \(bmpLeft)") }
    }

    /// 缺陷 2：agent 容器无「完全磁盘访问权限」时 enumerator 静默返回 0 项，
    /// 旧代码据此判「缓存很小、未达阈值」，清理器自始至终没清过主目标。
    static func blockedRootIsRecordedNotSilenced() throws {
        let root = try scratchDir("blocked")
        let inner = root.appendingPathComponent("extension-com.apple.wallpaper.extension.aerials", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try write(inner.appendingPathComponent("x.bmp"), mb: 24)

        // 拿掉权限，逼近 TCC 拒绝的可观察行为（0 项 + 一次 errorHandler 回调 + contentsOfDirectory 抛错）
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: inner.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: inner.path) }

        let access = WallpaperSystemCacheJanitor.probeEmptyRoot(inner)
        guard access == .blocked else { throw Failure(message: "无权限目录应判 blocked，实得 \(access.rawValue)") }

        let result = WallpaperSystemCacheJanitor.sweep(
            roots: [inner], protectedPaths: [],
            triggerThreshold: 1, retentionTarget: 0, dryRun: true
        )
        guard result.blockedRoots.contains(inner.path) else {
            throw Failure(message: "blocked 根必须进 SweepResult.blockedRoots，否则设置页无从提示授权")
        }
        guard !result.triggered else { throw Failure(message: "读不到的根不应触发删除") }
    }

    /// 真实的空目录不能被误判成 blocked（否则授权横幅会常驻）。
    static func genuinelyEmptyRootDoesNotPolluteBlocked() throws {
        let root = try scratchDir("trulyEmpty")
        let access = WallpaperSystemCacheJanitor.probeEmptyRoot(root)
        guard access == .readable else {
            throw Failure(message: "真空目录应判 readable，实得 \(access.rawValue)")
        }
        let result = WallpaperSystemCacheJanitor.sweep(
            roots: [root], protectedPaths: [],
            triggerThreshold: 2 * 1024 * 1024 * 1024, retentionTarget: 100 * 1024 * 1024, dryRun: true
        )
        guard result.blockedRoots.isEmpty, result.degradedRoots.isEmpty else {
            throw Failure(message: "真空目录不应进 blocked/degraded")
        }
    }

    // MARK: - 工具

    static func scratchDir(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("waifux-janitor-regression", isDirectory: true)
            .appendingPathComponent(name + "-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 稀疏文件：只占目录项与元数据，不真的写几十 GB
    static func write(_ file: URL, mb: Int = 0, bytes: Int = 0, ageSeconds: TimeInterval = 0) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(
            atPath: file.path, contents: bytes > 0 ? Data(count: bytes) : Data()) else {
            throw Failure(message: "造不出测试文件 \(file.lastPathComponent)")
        }
        if mb > 0 {
            let fd = open(file.path, O_WRONLY)
            guard fd >= 0 else { throw Failure(message: "open 失败 errno=\(errno) \(file.path)") }
            _ = ftruncate(fd, off_t(mb) * 1048576)
            close(fd)
        }
        if ageSeconds > 0 {
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: -ageSeconds)], ofItemAtPath: file.path)
        }
    }
}

// MARK: - 最小桩件（不被本测试覆盖，仅为满足链接）

/// 真实实现见 `Services/DesktopWallpaperSyncManager.swift`。
/// 本测试从不调用 `WallpaperSystemCacheJanitor.currentWallpaperPaths()`，
/// 因此这里只需满足符号引用；若将来测试要覆盖保护名单逻辑，必须改用真实实现。
final class DesktopWallpaperSyncManager: @unchecked Sendable {
    nonisolated(unsafe) static let shared = DesktopWallpaperSyncManager()
    func imageURL(for screen: NSScreen) -> URL? { nil }
}
