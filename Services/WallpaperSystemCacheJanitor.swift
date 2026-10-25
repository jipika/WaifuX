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
/// 另外顺带管理旧版 macOS 把航空壁纸下载缓存的
/// `~/Library/Application Support/com.apple.wallpaper/aerials/thumbnails`（可再生缩略图）。
/// `aerials/videos` **不参与清理**：那是 200–700MB 一条的已下载素材，删掉会诱发系统重新全量下载。
/// `Store/Index.plist`（系统壁纸配置数据库）在任何情况下都不会被触碰。
///
/// ⚠️ 可达性前提：主目标位于 wallpaper agent 自己的容器里，受 TCC 保护。
/// 未授权时 `FileManager.enumerator(at:)` 会**静默返回 0 项**（不报错、不弹窗），
/// 旧代码因此把「读不到」当成「缓存很小」而永不清理。现在由 `probeEmptyRoot` 识别，
/// 走节流 ERROR 日志，并由 `inaccessibleRootsNow()` 驱动设置页的授权提示。
/// 执行者刻意是**主 App**（`scheduleRun`/`runIfNeeded` 的 isRemoteUI 阀门）：清理需要
/// 「完全磁盘访问权限」，而 Helper 藏在 Contents/Helpers/ 下、用户在隐私面板里既看不到
/// 也拖不进去，只有可见的 WaifuX 才让「请求授权」这件事成立。
/// 副作用：Helper 常驻期间（主 App 未启动）不再有清理兜底，缓存回收改由用户打开 App 触发。
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
    nonisolated static func collectCacheRoots() -> [URL] {
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

    nonisolated private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    // MARK: - 根目录可达性（TCC / 完全磁盘访问）

    /// 一个缓存根的可读状态。
    enum RootAccess: String, Sendable {
        /// 能枚举（无论是否为空）
        case readable
        /// 被 TCC 拒绝：枚举静默返回 0 项，且 `contentsOfDirectory` 抛 257（无权限）。
        /// Helper 没有「完全磁盘访问」时，`~/Library/Containers/…` 就是这个表现。
        case blocked
        /// 目录存在但拿不到可靠结论（其它错误码/竞态），按保守处理：不判 blocked、不清理该根。
        case unknown
    }

    /// 供 `enumerator(errorHandler:)` 回调累加用的线程安全计数器
    ///（该回调是 @Sendable 逃逸闭包，不能捕获局部 var，故用带锁的引用类型）。
    private final class RootScanErrors: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        func record() { lock.lock(); _count += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
    }

    /// 只在某个根「枚举不到任何条目」时调用，用来区分两种完全不同的情况：
    /// 「缓存真的是空的」与「被 TCC 拒绝访问」。
    ///
    /// 这是本组件的核心坑：`enumerator(at:)` 被 TCC 拒绝时**既不返回 nil 也不报错**，
    /// 而是静默给出一个 0 项的枚举器。旧代码因此把「读不到」当成「缓存很小、未达阈值」，
    /// 于是清理器自始至终没清过它设计要清的主目标——实测 agent 容器里的解码缓存恒不计入，
    /// `managedBytes` 恒等于另一个可读根（aerials/thumbnails）的精确字节数。
    nonisolated static func probeEmptyRoot(_ root: URL) -> RootAccess {
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: root.path)
            return .readable              // 列得出来 ⇒ 可读，此时的空是真实的空
        } catch {
            let ns = error as NSError
            if ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoPermissionError {
                return .blocked           // 257 = NSFileReadNoPermissionError：TCC 拦截的典型签名
            }
            return .unknown               // 其它错误/竞态：保守，不判 blocked、不动这个根
        }
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
        // Application Support：仅 aerial 的**缩略图**下载缓存（videos 已移出白名单，见下）
        if top == "aerials", components.count >= 3 {
            // ⚠️ 不删 aerials/videos：单个航拍视频 200–700MB，大于 retentionTarget(100MB)，
            // 一旦触发清理必然整批被删，系统随后会从 Apple 重新全量下载（同型事故见
            // tw93/Mole#577：第三方清理删掉该目录后用户在系统设置里触发大流量重下）。
            // 缩略图为 KB 级、可安全再生，继续参与水位回收。
            return String(components[1]) == "thumbnails"
        }
        return false
    }

    // MARK: - 触发入口

    /// 每次静态壁纸写入成功后调用（10 秒防抖，10 分钟节流）
    func noteWallpaperChanged() {
        scheduleRun(delay: 10)
    }

    /// 主 App 启动后调用：错峰检查一次 + 挂 24h 定时兜底。
    /// 执行者刻意限定在**主 App**：清理目标位于 wallpaper agent 的容器里，受 TCC 保护，
    /// 而 Helper 藏在 Contents/Helpers/ 下、用户在隐私面板里既看不到也拖不进去，
    /// 「请求授权」这件事只有落在可见的 WaifuX 上才成立。
    func noteAppLaunch() {
        guard BackgroundRuntimeRole.isRemoteUI, !BackgroundRuntimeRole.isIsolatedTest else { return }
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
        // Helper 侧调用（如定时轮换写入静态壁纸后）会在这里直接返回：
        // 清理统一由主 App 执行，避免两个进程各自维护节流状态却都拿不到授权。
        guard BackgroundRuntimeRole.isRemoteUI, !BackgroundRuntimeRole.isIsolatedTest else { return }
        // 系统壁纸同步关闭时不产生新的解码缓存，无需检查
        let syncEnabled = (WaifuXPreferences.shared.object(forKey: "system_wallpaper_sync_enabled") as? Bool) ?? true
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
        guard BackgroundRuntimeRole.isRemoteUI, !BackgroundRuntimeRole.isIsolatedTest,
              (WaifuXPreferences.shared.object(forKey: "system_wallpaper_sync_enabled") as? Bool) ?? true else { return }
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
        /// 被 TCC 拒绝、完全读不到的根（≠ 缓存为空）。非空时 managedBytes 是**低估值**，
        /// 不能再据它断言"未达阈值"。
        var blockedRoots: [String] = []
        /// 枚举中途出错、计数不可信的根（可能少计）。与 blockedRoots 同等保守对待。
        var degradedRoots: [String] = []
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
            let scanErrors = RootScanErrors()
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsPackageDescendants, .skipsHiddenFiles],
                errorHandler: { _, _ in
                    scanErrors.record()
                    return true            // 继续枚举，但本根计数已不可信
                }
            ) else {
                if probeEmptyRoot(root) == .blocked { result.blockedRoots.append(root.path) }
                continue
            }

            var entriesSeen = 0
            for case let fileURL as URL in enumerator {
                entriesSeen += 1
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

            // 计数不可信的两种情形都要判可达性，且顺序不能反：
            // 实测被 TCC 拒绝时 enumerator **同时**给出「0 项」和「一次 errorHandler 回调」，
            // 若先按 scanErrors 归入 degraded，就永远走不到 probeEmptyRoot，
            // 而设置页的授权提示只认 blocked ⇒ 恰好漏掉本案的主场景（权限类回归脚本已覆盖）。
            if entriesSeen == 0 || scanErrors.count > 0 {
                switch probeEmptyRoot(root) {
                case .blocked:
                    result.blockedRoots.append(root.path)
                case .readable:
                    // 真·空目录（列得出来且无报错）⇒ 不需要记
                    if scanErrors.count > 0 { result.degradedRoots.append(root.path) }
                case .unknown:
                    // 拿不到可靠结论就绝不能当成「缓存很小」，否则等于退回旧 bug
                    result.degradedRoots.append(root.path)
                }
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
        if !result.blockedRoots.isEmpty || !result.degradedRoots.isEmpty {
            // ⚠️ 这条必须存在：没有它，下面只会打「未达阈值」，运维与用户都无从知道
            // 清理器其实一直没看到大头（agent 容器的解码缓存）。
            // 用节流：这是「状态型」信号，每次 sweep 都会命中，6 小时一条足够（见日志预算约定）。
            AppLogger.throttled(.error, .wallpaper,
                                key: "wallpaper.cache.roots.blocked",
                                interval: 6 * 3600,
                                "系统壁纸缓存根不可达，阈值判断基于低估值", metadata: [
                                    "blockedRoots": result.blockedRoots.joined(separator: ", "),
                                    "degradedRoots": result.degradedRoots.joined(separator: ", "),
                                    "measuredBytes": Int(result.managedBytes),
                                    "threshold": Int(Self.triggerThreshold),
                                    "hint": "WaifuX 主程序需要「完全磁盘访问权限」才能枚举并清理 wallpaper agent 容器内的解码缓存"
                                ])
        }

        guard result.triggered else {
            // 存在不可达根时不打「未达阈值」——那个结论本身不可信，只会掩盖问题
            if result.blockedRoots.isEmpty && result.degradedRoots.isEmpty {
                AppLogger.debug(.wallpaper, "系统壁纸缓存未达清理阈值，跳过", metadata: [
                    "managedBytes": Int(result.managedBytes),
                    "threshold": Int(Self.triggerThreshold)
                ])
            }
            return
        }
        AppLogger.info(.wallpaper, "系统壁纸缓存水位清理完成", metadata: [
            "freedMB": Int(Double(result.freedBytes) / 1_048_576),
            "deleted": result.deletedCount,
            "protectedSkipped": result.protectedSkipped,
            "remainingMB": Int(Double(result.remainingBytes) / 1_048_576),
            "dryRun": result.dryRun,
            "blockedRoots": result.blockedRoots.count
        ])
    }


    /// 设置页用的同步探针：当前**读不到**的缓存根（缺「完全磁盘访问权限」时非空）。
    /// 清理已改由主 App 执行，所以这里直接探，不再依赖 Helper 写进来的跨进程键——
    /// 那会让提示滞后一整轮 sweep。只做目录级探测，不遍历文件内容。
    nonisolated static func inaccessibleRootsNow() -> [URL] {
        collectCacheRoots().filter { probeEmptyRoot($0) == .blocked }
    }
}
