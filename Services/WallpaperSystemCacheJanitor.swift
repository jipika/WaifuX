import Foundation
import AppKit

// MARK: - macOS 系统壁纸缓存清理器（Janitor）
///
/// 背景：开启「系统壁纸同步」后，每次 `setDesktopImageURL` 写入的静态壁纸都会被
/// 系统 wallpaper agent 解码成位图副本缓存在它的沙盒容器里：
///
///   `~/Library/Containers/com.apple.wallpaper.agent/Data/Library/Caches/com.apple.wallpaper.caches/`
///     ├── extension-com.apple.wallpaper.extension.image/     ← 自定义图片解码缓存（大头，4K BMP ≈ 24MB/张）
///     ├── extension-com.apple.wallpaper.extension.aerials/   ← 系统航空壁纸解码缓存
///     └── extension-com.waifux.app.wallpaperextension/       ← 本 App 锁屏扩展缓存（不参与清理）
///
/// 实测（macOS 26.6）：该缓存没有任何系统开关、也不会被系统自动回收，壁纸换得
/// 越多攒得越大（每换一次 +24~48MB）。本组件提供 LRU 式水位清理：
///
///   - 管理范围内缓存总体积 > `triggerThreshold`（2GB）时触发；
///   - 按文件修改时间**从旧到新**删除，直到剩余 ≤ `retentionTarget`（100MB）；
///   - 只删「内容寻址的可再生缓存」bmp，当前在用的桌面壁纸源文件永远保护；
///   - 触发时机：① 启动后错峰 90 秒；② 每次静态壁纸写入后（10 秒防抖 + 10 分钟节流）；
///     ③ 24 小时定时兜底（覆盖长期不换壁纸的场景）。全部在后台队列执行。
///
/// 另外顺带管理旧版 macOS 把航空壁纸视频下载缓存的
/// `~/Library/Application Support/com.apple.wallpaper/aerials/{videos,thumbnails}`（可再生下载缓存）。
/// `Store/Index.plist`（系统壁纸配置数据库）在任何情况下都不会被触碰。
@MainActor
final class WallpaperSystemCacheJanitor {

    static let shared = WallpaperSystemCacheJanitor()

    // MARK: - 水位参数

    /// 触发清理的缓存总体积阈值：2GB
    nonisolated static let triggerThreshold: UInt64 = 2 * 1024 * 1024 * 1024
    /// 清理后保留的最新文件目标体积：100MB（按 mtime 最新优先保留）
    nonisolated static let retentionTarget: UInt64 = 100 * 1024 * 1024
    /// 两次清理的最小间隔（防止换壁纸风暴期间反复扫描）
    static let minimumInterval: TimeInterval = 10 * 60

    // MARK: - 运行状态

    private var lastRunDate: Date?
    private var pendingWorkItem: DispatchWorkItem?
    private var dailySafetyNetTimer: Timer?
    private var sweepInFlight = false
    private let janitorQueue = DispatchQueue(label: "com.waifux.wallpaper-cache-janitor", qos: .utility)

    private init() {}

    // MARK: - 缓存根目录

    /// 参与水位管理的系统壁纸缓存根目录
    static func collectCacheRoots() -> [URL] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        var roots: [URL] = []

        // 主目标（macOS 14+）：wallpaper agent 容器内的内容寻址解码缓存
        let containerCache = home.appendingPathComponent(
            "Library/Containers/com.apple.wallpaper.agent/Data/Library/Caches/com.apple.wallpaper.caches",
            isDirectory: true
        )
        if isDirectory(containerCache) { roots.append(containerCache) }

        // 附加目标：旧版 aerial 视频下载缓存（仅 videos/thumbnails 子目录参与）
        let appSupportCache = home.appendingPathComponent(
            "Library/Application Support/com.apple.wallpaper",
            isDirectory: true
        )
        if isDirectory(appSupportCache) { roots.append(appSupportCache) }

        return roots
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// 判断某个文件是否属于「可再生的系统壁纸缓存」。
    /// 白名单之外的一切（Store/Index.plist、manifest、第三方扩展目录、根目录散文件）一律不动。
    nonisolated static func isManagedCachePath(root: URL, fileURL: URL) -> Bool {
        let basePath = root.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        guard filePath.hasPrefix(basePath + "/") else { return false }
        let components = filePath.dropFirst(basePath.count + 1).split(separator: "/")
        guard components.count >= 2 else { return false } // 根目录散文件（Index.plist 等）永不清理

        let top = String(components[0])
        // agent 容器：各系统壁纸扩展的解码缓存目录（bmp 内容寻址缓存，可随时再生）
        if top.hasPrefix("extension-com.apple.wallpaper.extension.") { return true }
        // Application Support：仅 aerial 的视频/缩略图下载缓存（manifest 与 Store/ 不动）
        if top == "aerials", components.count >= 3 {
            let second = String(components[1])
            return second == "videos" || second == "thumbnails"
        }
        return false
    }

    // MARK: - 触发入口

    /// 每次静态壁纸写入成功后调用（10 秒防抖，10 分钟节流）
    func noteWallpaperChanged() {
        scheduleRun(delay: 10)
    }

    /// 应用启动后调用：错峰检查一次 + 挂 24h 定时兜底
    func noteAppLaunch() {
        startDailySafetyNet()
        scheduleRun(delay: 90)
    }

    /// 24h 一次的定时兜底，覆盖「App 长期运行且用户不换壁纸」期间缓存仍增长的场景
    /// （如系统 aerial 自动轮换下载）。挂在主 RunLoop 上，1h 容差允许系统合并唤醒省电。
    private func startDailySafetyNet() {
        guard dailySafetyNetTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.runIfNeeded()
            }
        }
        timer.tolerance = 3600
        dailySafetyNetTimer = timer
    }

    private func scheduleRun(delay: TimeInterval) {
        // 系统壁纸同步关闭时不产生新的解码缓存，无需检查
        let syncEnabled = (UserDefaults.standard.object(forKey: "system_wallpaper_sync_enabled") as? Bool) ?? true
        guard syncEnabled else { return }
        if let last = lastRunDate, Date().timeIntervalSince(last) < Self.minimumInterval {
            return
        }
        pendingWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.runIfNeeded()
        }
        pendingWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func runIfNeeded() {
        guard !sweepInFlight else { return } // 上一次扫描还在跑：幂等跳过
        lastRunDate = Date()
        let roots = Self.collectCacheRoots()
        guard !roots.isEmpty else { return }
        let protected = Self.currentWallpaperPaths()

        sweepInFlight = true
        janitorQueue.async { [weak self] in
            let result = Self.sweep(
                roots: roots,
                protectedPaths: protected,
                triggerThreshold: Self.triggerThreshold,
                retentionTarget: Self.retentionTarget,
                dryRun: false
            )
            Task { @MainActor [weak self] in
                self?.sweepInFlight = false
                self?.log(result)
            }
        }
    }

    // MARK: - 保护名单（MainActor）

    /// 当前各屏正在使用的桌面壁纸路径。删除池永远跳过这些文件。
    static func currentWallpaperPaths() -> Set<String> {
        var paths = Set<String>()

        // 1. App 注册表（覆盖 WaifuX 设过的所有屏）
        for screen in NSScreen.screens {
            if let url = DesktopWallpaperSyncManager.shared.imageURL(for: screen), url.isFileURL {
                paths.insert(url.standardizedFileURL.resolvingSymlinksInPath().path)
            }
        }

        // 2. 兜底：系统当前桌面图（覆盖用户在系统设置里手动改的场景）
        for screen in NSScreen.screens {
            if let url = NSWorkspace.shared.desktopImageURL(for: screen), url.isFileURL {
                paths.insert(url.standardizedFileURL.resolvingSymlinksInPath().path)
            }
        }

        // 3. 兜底：系统航空壁纸当前引用（com.apple.wallpaper 域）。
        //    注意必须读 string 再用 URL(string:) 解析：url(forKey:) 会把 plist 里的
        //    "file:///..." 字符串误当作相对路径拼接 cwd，导致保护名单失效。
        let wallpaperDefaults = UserDefaults(suiteName: "com.apple.wallpaper")
        if let raw = wallpaperDefaults?.string(forKey: "SystemWallpaperURL") {
            if let url = URL(string: raw), url.isFileURL {
                paths.insert(url.standardizedFileURL.resolvingSymlinksInPath().path)
            } else if raw.hasPrefix("/") {
                paths.insert(URL(fileURLWithPath: raw).standardizedFileURL.resolvingSymlinksInPath().path)
            }
        }
        return paths
    }

    // MARK: - 清理核心（纯函数，nonisolated，可独立测试）

    struct SweepResult: Sendable {
        var managedBytes: UInt64 = 0      // 管理范围内文件总大小
        var freedBytes: UInt64 = 0        // 本次释放
        var deletedCount: Int = 0
        var protectedSkipped: Int = 0     // 命中保护名单跳过的文件数
        var triggered: Bool = false
        var dryRun: Bool = false
        var remainingBytes: UInt64 = 0    // 清理后管理范围内剩余
    }

    /// 扫描 → 阈值判断 → LRU 删除。`dryRun=true` 只统计不删除（供验证）。
    nonisolated static func sweep(
        roots: [URL],
        protectedPaths: Set<String>,
        triggerThreshold: UInt64,
        retentionTarget: UInt64,
        dryRun: Bool
    ) -> SweepResult {
        var result = SweepResult(dryRun: dryRun)
        let fm = FileManager.default

        // 1. 收集管理范围内的候选文件
        var candidates: [(url: URL, size: UInt64, mtime: Date)] = []
        for root in roots {
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsPackageDescendants, .skipsHiddenFiles]
            ) else { continue }

            for case let fileURL as URL in enumerator {
                guard isManagedCachePath(root: root, fileURL: fileURL) else { continue }
                let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
                guard values?.isRegularFile == true,
                      let size = values?.fileSize, size >= 1024, // 跳过 cacheVersion.db 等小索引文件
                      let mtime = values?.contentModificationDate else {
                    continue
                }
                candidates.append((fileURL, UInt64(size), mtime))
                result.managedBytes += UInt64(size)
            }
        }
        result.remainingBytes = result.managedBytes

        // 2. 未达触发阈值：不动
        guard result.managedBytes > triggerThreshold else { return result }
        result.triggered = true

        // 3. LRU：mtime 最旧的先删，直到剩余 ≤ retentionTarget（或无可删文件）
        candidates.sort { $0.mtime < $1.mtime }
        for entry in candidates {
            if result.remainingBytes <= retentionTarget { break }
            let path = entry.url.standardizedFileURL.resolvingSymlinksInPath().path
            if protectedPaths.contains(path) {
                result.protectedSkipped += 1
                continue
            }
            if !dryRun {
                do {
                    try fm.removeItem(at: entry.url)
                } catch {
                    AppLogger.warn(.wallpaper, "壁纸缓存清理：删除失败，跳过", metadata: [
                        "path": path,
                        "error": error.localizedDescription
                    ])
                    continue
                }
            }
            result.remainingBytes -= entry.size
            result.freedBytes += entry.size
            result.deletedCount += 1
        }
        return result
    }

    // MARK: - 结果日志（MainActor）

    private func log(_ result: SweepResult) {
        guard result.triggered else {
            AppLogger.debug(.wallpaper, "系统壁纸缓存未达清理阈值，跳过", metadata: [
                "managedBytes": Int(result.managedBytes),
                "threshold": Int(Self.triggerThreshold)
            ])
            return
        }
        AppLogger.info(.wallpaper, "系统壁纸缓存水位清理完成", metadata: [
            "freedMB": Int(Double(result.freedBytes) / 1_048_576),
            "deleted": result.deletedCount,
            "protectedSkipped": result.protectedSkipped,
            "remainingMB": Int(Double(result.remainingBytes) / 1_048_576),
            "dryRun": result.dryRun
        ])
    }
}
