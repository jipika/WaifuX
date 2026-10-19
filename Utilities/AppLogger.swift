import Foundation
import os.log

// MARK: - WaifuX 结构化日志系统
/// 统一日志输出：控制台（OSLog）+ 文件（ApplicationSupport/waifux.log）
/// 用途：排查用户端异常（卡死、加载中、滚动冻结等）
///
/// 使用方式：
///   AppLogger.info("API", "请求开始", ["url": url])
///   AppLogger.error("Download", "下载失败", ["error": error.localizedDescription])
// MARK: - 日志级别
enum AppLogLevel: String, CaseIterable {
    case debug = "DEBUG"
    case info  = "INFO"
    case warn  = "WARN"
    case error = "ERROR"

    var emoji: String {
        switch self {
        case .debug: return "🔍"
        case .info:  return "ℹ️"
        case .warn:  return "⚠️"
        case .error: return "❌"
        }
    }

    // os log type 映射
    func osLogType() -> OSLogType {
        switch self {
        case .debug: return .default
        case .info:  return .info
        case .warn:  return .default
        case .error: return .error
        }
    }
}

// MARK: - 模块分类（方便过滤）
enum AppLogModule: String, CaseIterable {
    case general     = "General"
    case api         = "API"
    case download    = "Download"
    case ui          = "UI"
    case grid        = "Grid"        // RecyclableGridView 相关
    case wallpaper   = "Wallpaper"
    case media       = "Media"
    case anime       = "Anime"
    case video       = "Video"
    case network     = "Network"
    case storage     = "Storage"
    case startup     = "Startup"
}

// MARK: - Logger 入口
final class AppLogger: @unchecked Sendable {

    /// 单例
    static let shared = AppLogger()

    // MARK: - 配置
    /// 最大保留文件大小（字节），超过后截断旧内容，默认 2MB
    private let maxLogFileSize: UInt64 = 2 * 1024 * 1024

    /// 文件路径
    private lazy var logFileURL: URL? = {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let waifuXDir = appSupport.appendingPathComponent("WaifuX", isDirectory: true)
        try? FileManager.default.createDirectory(at: waifuXDir, withIntermediateDirectories: true)
        return waifuXDir.appendingPathComponent("waifux.log")
    }()

    // os.log subsystem
    private static let subsystem = "com.waifux.app"
    private static let oslog = OSLog(subsystem: subsystem, category: "WaifuX")

    // 队列保证线程安全写入文件
    private let queue = DispatchQueue(label: "com.waifux.logger", qos: .utility)

    private init() {}

    // MARK: - 公开接口

    static func debug(_ module: AppLogModule = .general,
                      _ message: @autoclosure () -> String,
                      metadata: [String: Any]? = nil) {
        shared.log(.debug, module, message(), metadata)
    }

    static func info(_ module: AppLogModule = .general,
                     _ message: @autoclosure () -> String,
                     metadata: [String: Any]? = nil) {
        shared.log(.info, module, message(), metadata)
    }

    static func warn(_ module: AppLogModule = .general,
                     _ message: @autoclosure () -> String,
                     metadata: [String: Any]? = nil) {
        shared.log(.warn, module, message(), metadata)
    }

    static func error(_ module: AppLogModule = .general,
                      _ message: @autoclosure () -> String,
                      metadata: [String: Any]? = nil) {
        shared.log(.error, module, message(), metadata)
    }

    /// 节流日志：同一 `key` 在 `interval` 秒内只写一次。
    ///
    /// 用于「状态型 / 高频」打点（动画进出、窗口遮挡、前台激活、卡顿采样等）：
    /// 保留首条与语义，避免同一状态每秒刷一行。`key` 必须是固定枚举式字符串，
    /// 不要把路径/ID 等动态值拼进去，否则节流表会被撑爆。
    static func throttled(_ level: AppLogLevel = .debug,
                          _ module: AppLogModule = .general,
                          key: String,
                          interval: TimeInterval = 30,
                          _ message: @autoclosure () -> String,
                          metadata: [String: Any]? = nil) {
        guard shared.shouldWriteThrottled(key: key, interval: interval) else { return }
        shared.log(level, module, message(), metadata)
    }

    /// 判断某个固定 key 是否已过节流窗口；用于「先节流再执行昂贵操作」的场景
    /// （例如主线程卡顿采样会 spawn `/usr/bin/sample`，不能每次卡顿都跑）。
    static func shouldThrottle(key: String, interval: TimeInterval) -> Bool {
        shared.shouldWriteThrottled(key: key, interval: interval)
    }

    // MARK: - 节流表

    private let throttleLock = NSLock()
    private var throttleLastWrite: [String: Date] = [:]

    private func shouldWriteThrottled(key: String, interval: TimeInterval) -> Bool {
        let now = Date()
        throttleLock.lock()
        defer { throttleLock.unlock() }
        if let last = throttleLastWrite[key], now.timeIntervalSince(last) < interval {
            return false
        }
        if throttleLastWrite.count >= 256 {
            // 先清过期项（5 分钟未再触发），仍超出则只保留最近 64 个 key。
            let cutoff = now.addingTimeInterval(-300)
            throttleLastWrite = throttleLastWrite.filter { $0.value > cutoff }
            if throttleLastWrite.count >= 256 {
                let newest = throttleLastWrite.sorted { $0.value < $1.value }.suffix(64)
                throttleLastWrite = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
            }
        }
        throttleLastWrite[key] = now
        return true
    }

    /// 记录耗时操作（自动计算 duration）
    static func timing<T>(_ module: AppLogModule = .general,
                          _ label: String,
                          operation: () async throws -> T) async rethrows -> T {
        let start = Date()
        AppLogger.info(module, "\(label) 开始")
        defer {
            let elapsed = Date().timeIntervalSince(start)
            AppLogger.info(module, "\(label) 结束 耗时:\(String(format: "%.2f", elapsed))s")
        }
        return try await operation()
    }

    // MARK: - 核心写入

    private func log(_ level: AppLogLevel,
                     _ module: AppLogModule,
                     _ message: String,
                     _ metadata: [String: Any]?) {

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let metaStr = formatMetadata(metadata)
        let line = "\(timestamp) [\(level.rawValue)] [\(module.rawValue)] \(message)\(metaStr)"

#if DEBUG
        // 1. 控制台输出（带 emoji + 颜色）
        print("\(level.emoji) \(line)")

        // 2. os.log 输出（系统日志，可用 Console.app 查看）
        os_log("%{public}@", log: Self.oslog, type: level.osLogType(), line)
#endif

        // 3. 文件持久化：Release 模式下只保留 error 级别，用于排查用户问题
        #if !DEBUG
        guard level == .error else { return }
        #endif
        writeToFile(line)
    }

    // MARK: - 格式化元数据

    private func formatMetadata(_ metadata: [String: Any]?) -> String {
        guard let meta = metadata, !meta.isEmpty else { return "" }
        let parts = meta.map { key, val in "\(key)=\(val)" }
        return " | \(parts.joined(separator: ", "))"
    }

    // MARK: - 文件写入（带大小限制）

    /// 文件写入队列积压上限；日志 IO 异常卡住时丢弃新行，防止队列无限堆积
    /// 并把主线程日志调用拖死（实测出现过日志器整段停摆 15 分钟）。
    private let writeBacklogLimit = 2000
    private let writeBacklogLock = NSLock()
    private var pendingFileWrites = 0

    private func writeToFile(_ line: String) {
        guard let url = logFileURL else { return }
        writeBacklogLock.lock()
        guard pendingFileWrites < writeBacklogLimit else {
            writeBacklogLock.unlock()
            return
        }
        pendingFileWrites += 1
        writeBacklogLock.unlock()
        queue.async { [weak self] in
            defer {
                if let self {
                    self.writeBacklogLock.lock()
                    self.pendingFileWrites -= 1
                    self.writeBacklogLock.unlock()
                }
            }
            guard let self else { return }

            if !FileManager.default.fileExists(atPath: url.path) {
                // 新建文件，写 UTF-8 BOM 方便文本编辑器识别
                let bomData = Data([0xEF, 0xBB, 0xBF])
                try? bomData.write(to: url, options: .atomic)
            }

            // 检查文件大小，超限则截断
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? UInt64, size > self.maxLogFileSize {
                do {
                    // 读取后半部分（保留最近日志）。
                    // 截断点必须回退到换行之后，否则会在文件头留下半个 UTF-8 汉字 /
                    // 半行，之后任何文本工具读取都会报非法字节。
                    var currentData = try Data(contentsOf: url)
                    if currentData.count > 3, currentData.prefix(3) == Data([0xEF, 0xBB, 0xBF]) {
                        currentData = currentData.dropFirst(3)
                    }
                    let keepRange = currentData.count / 2
                    var tail = currentData.subdata(in: keepRange..<currentData.count)
                    if let firstNewline = tail.firstIndex(of: 0x0A) {
                        tail = tail.subdata(in: tail.index(after: firstNewline)..<tail.endIndex)
                    }
                    // 保险：若切完仍不是合法 UTF-8，逐个换行往后找（最多 4 次）。
                    var attempts = 0
                    while !tail.isEmpty,
                          String(data: tail, encoding: .utf8) == nil,
                          attempts < 4 {
                        guard let next = tail.firstIndex(of: 0x0A) else { break }
                        tail = tail.subdata(in: tail.index(after: next)..<tail.endIndex)
                        attempts += 1
                    }
                    let headerStr = "--- LOG TRUNCATED at \(ISO8601DateFormatter().string(from: Date())) ---\n"
                    let headerData = (headerStr.data(using: .utf8) ?? Data()) + tail
                    try headerData.write(to: url, options: .atomic)
                } catch {
                    // 截断失败则直接清空重建
                    try? "".write(to: url, atomically: true, encoding: .utf8)
                }
            }

            let entry = line + "\n"
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                if let entryData = entry.data(using: .utf8) {
                    handle.write(entryData)
                }
                try? handle.close()
            } else {
                // 文件不存在，创建新文件
                try? entry.write(to: url, atomically: true, encoding: .utf8)
            }

#if DEBUG
            // Debug 模式下同步 flush 确保立即可见
            fflush(stderr)
#endif
        }
    }

    // MARK: - 公开查询接口

    /// 读取全部日志内容（字符串）
    static func readAllLogs() -> String {
        guard let url = shared.logFileURL else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// 读取最近 N 行日志
    static func recentLogs(lineCount: Int = 200) -> String {
        let all = readAllLogs()
        let lines = all.components(separatedBy: "\n").filter { !$0.isEmpty }
        let start = max(0, lines.count - lineCount)
        return Array(lines[start...]).joined(separator: "\n")
    }

    /// 搜索包含关键字的日志行
    static func searchLogs(keyword: String, limit: Int = 100) -> String {
        let all = readAllLogs()
        return all
            .components(separatedBy: "\n")
            .filter { $0.localizedCaseInsensitiveContains(keyword) }
            .suffix(limit)
            .joined(separator: "\n")
    }

    /// 清空日志文件
    static func clearLogs() {
        guard let url = shared.logFileURL else { return }
        try? "".write(to: url, atomically: true, encoding: .utf8)
        AppLogger.info(.general, "日志已清空")
    }

    /// 返回日志文件 URL（供外部访问/分享）
    static func logFileURL() -> URL? {
        return shared.logFileURL
    }

    // MARK: - 导出日志到桌面

    /// 把全部诊断日志聚合到桌面一个文件（App 运行日志、扩展、退出诊断、CLI、
    /// 扩展守护、烘焙失败现场），渲染器日志单独打一个 zip。
    ///
    /// 契约：任一来源缺失/不可读/为空时写入一行「[跳过] 原因」并继续，
    /// 绝不因为某一段缺失让整个导出失败。每段只保留尾部 N KiB。
    /// 无任何可读日志时返回 nil。
    static func exportLogToDesktop() throws -> URL? {
        let fm = FileManager.default
        let desktop = fm.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())

        var destination = desktop.appendingPathComponent("WaifuX-AllLogs-\(stamp).log")
        var sequence = 1
        while fm.fileExists(atPath: destination.path) {
            destination = desktop.appendingPathComponent("WaifuX-AllLogs-\(stamp)-\(sequence).log")
            sequence += 1
        }

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        var header = "WaifuX 诊断日志\n"
        header += "导出时间: \(Date())\n"
        header += "版本: \(version)\n"
        header += "系统: \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
        header += "说明: 以下为各日志来源的尾部片段；渲染器日志另存桌面 zip。\n"
        try header.write(to: destination, atomically: true, encoding: .utf8)

        var readableSegments = 0

        if let sourceURL = shared.logFileURL {
            readableSegments += appendLogSegment(
                "APP RUNTIME LOG", from: sourceURL, maxBytes: 1024 * 1024, to: destination
            )
        } else {
            appendSkipped("APP RUNTIME LOG", reason: "日志路径不可用", to: destination)
        }

        // 锁屏视频由独立的 Wallpaper Extension 播放。主 App 的日志没有
        // reader 循环、解码失败和 WallpaperAgent update，诊断时需要同一份导出。
        if let container = fm.containerURL(forSecurityApplicationGroupIdentifier: "group.com.waifux.app") {
            readableSegments += appendLogSegment(
                "WALLPAPER EXTENSION LOG",
                from: container.appendingPathComponent("waifux-extension.log"),
                maxBytes: 1024 * 1024,
                to: destination
            )
        } else {
            appendSkipped("WALLPAPER EXTENSION LOG", reason: "App Group 容器不可用", to: destination)
        }
        readableSegments += appendLogSegment(
            "WALLPAPER EXTENSION LOG (fallback)",
            from: URL(fileURLWithPath: "/tmp/waifux-extension.log"),
            maxBytes: 512 * 1024,
            to: destination
        )

        // 退出/信号诊断（崩溃、异常退出时才有内容）
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        readableSegments += appendLogSegment(
            "EXIT DIAGNOSTICS",
            from: appSupport?.appendingPathComponent("WaifuX/waifux-exit.log"),
            maxBytes: 256 * 1024,
            to: destination
        )

        // Web 壁纸 daemon（主 App 未启用沙盒，/tmp 可直接读取）
        readableSegments += appendLogSegment(
            "WEB RENDERER DAEMON",
            from: URL(fileURLWithPath: "/tmp/wallpaperengine-cli-debug.log"),
            maxBytes: 512 * 1024,
            to: destination
        )
        readableSegments += appendLogSegment(
            "WEB RENDERER DAEMON OUTPUT",
            from: URL(fileURLWithPath: "/tmp/wallpaperengine-cli-daemon.log"),
            maxBytes: 256 * 1024,
            to: destination
        )
        readableSegments += appendLogSegment(
            "WALLPAPER EXTENSION KEEPER",
            from: fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/WaifuXKeeper.log"),
            maxBytes: 256 * 1024,
            to: destination
        )

        // 最近的烘焙失败现场（按修改时间取前 3 份）
        if let tmpFiles = try? fm.contentsOfDirectory(
            at: fm.temporaryDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            let bakeLogs = tmpFiles
                .filter {
                    $0.lastPathComponent.hasPrefix("waifux-wallpaper-wgpu-bake-")
                        && $0.pathExtension == "log"
                }
                .sorted { lhs, rhs in
                    let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate ?? .distantPast
                    let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate ?? .distantPast
                    return left > right
                }
                .prefix(3)
            for (index, url) in bakeLogs.enumerated() {
                readableSegments += appendLogSegment(
                    "SCENE BAKE #\(index + 1) (\(url.lastPathComponent))",
                    from: url,
                    maxBytes: 256 * 1024,
                    to: destination
                )
            }
        }

        // wgpu 渲染器自身的 stdout/stderr 落在 Caches/com.waifux.wallpaperengine/renderer-logs
        // （每屏一个文件，GPU init 失败/panic/事件循环异常只在这里）。逐屏并入主文件，
        // 保证「全部日志」一次导出就是单个产物；wgpu 内部问题才能随导出送达。
        // 最多取 6 个文件（常见 1–3 屏，留出历史屏位），避免多屏时把导出文件撑大。
        // 测试钩子：WAIFUX_RENDERER_LOG_DIR 可把目录指到 fixture，生产环境不设置时走 Caches。
        let rendererLogs: URL?
        if let overridePath = getenv("WAIFUX_RENDERER_LOG_DIR"), strlen(overridePath) > 0 {
            rendererLogs = URL(fileURLWithPath: String(cString: overridePath), isDirectory: true)
        } else if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            rendererLogs = caches.appendingPathComponent(
                "com.waifux.wallpaperengine/renderer-logs", isDirectory: true)
        } else {
            rendererLogs = nil
        }
        if let rendererLogs,
           fm.fileExists(atPath: rendererLogs.path),
           let rendererFiles = try? fm.contentsOfDirectory(
               at: rendererLogs,
               includingPropertiesForKeys: nil,
               options: [.skipsHiddenFiles]
           ) {
            let logs = rendererFiles
                .filter { $0.pathExtension == "log" }
                // 优先取最近写过的屏（诊断价值最高）；同一时间戳再按 screen 数字稳定排序，
                // 避免字典序把 screen-10 排到 screen-2 前面。
                .sorted { lhs, rhs in
                    let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate ?? .distantPast
                    let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate ?? .distantPast
                    if left != right { return left > right }
                    return lhs.lastPathComponent.compare(rhs.lastPathComponent, options: .numeric) == .orderedAscending
                }
                .prefix(6)
            for url in logs {
                readableSegments += appendLogSegment(
                    "RENDERER \(url.lastPathComponent)",
                    from: url,
                    maxBytes: 512 * 1024,
                    to: destination
                )
            }
        }

        guard readableSegments > 0 else {
            try? fm.removeItem(at: destination)
            return nil
        }
        AppLogger.info(.general, "全部日志已导出到桌面", metadata: [
            "path": destination.path,
            "segments": String(readableSegments)
        ])
        return destination
    }

    /// 追加一段日志尾部；返回是否读取到内容。
    @discardableResult
    private static func appendLogSegment(_ title: String, from url: URL?, maxBytes: UInt64, to destination: URL) -> Int {
        guard let url else {
            appendSkipped(title, reason: "路径不可用", to: destination)
            return 0
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            appendSkipped(title, reason: "文件不存在", to: destination)
            return 0
        }
        guard let input = try? FileHandle(forReadingFrom: url) else {
            appendSkipped(title, reason: "不可读", to: destination)
            return 0
        }
        defer { try? input.close() }
        let end = input.seekToEndOfFile()
        guard end > 0 else {
            appendSkipped(title, reason: "空文件", to: destination)
            return 0
        }
        input.seek(toFileOffset: end > maxBytes ? end - maxBytes : 0)
        let data = input.readData(ofLength: Int(min(end, maxBytes)))
        guard !data.isEmpty, let output = try? FileHandle(forWritingTo: destination) else {
            appendSkipped(title, reason: "读取失败", to: destination)
            return 0
        }
        defer { try? output.close() }
        output.seekToEndOfFile()
        let segmentHeader = "\n--- \(title) (last \(maxBytes / 1024) KiB) ---\n来源: \(url.path)\n"
        output.write(Data(segmentHeader.utf8))
        output.write(Data(String(decoding: data, as: UTF8.self).utf8))
        return 1
    }

    private static func appendSkipped(_ title: String, reason: String, to destination: URL) {
        guard let output = try? FileHandle(forWritingTo: destination) else { return }
        defer { try? output.close() }
        output.seekToEndOfFile()
        output.write(Data("\n--- \(title) ---\n[跳过] \(reason)\n".utf8))
    }
}

// MARK: - repeatForever 动画存活追踪器（诊断后台 CPU 空转）
/// 可常驻的动画组件在 onAppear/onDisappear 进出注册表；
/// 心跳每 20s 检查一次，存活清单有变化才立即打点，无变化每 15 分钟提醒一次，
/// 用于对照 sample 定位常驻空转来源（避免心跳刷屏淹没真实错误）。
final class RepeatForeverAnimationTracker: @unchecked Sendable {
    static let shared = RepeatForeverAnimationTracker()

    private let lock = NSLock()
    private var alive: [String: Int] = [:]
    private var heartbeatTimer: Timer?
    private var lastHeartbeatSignature: String?
    private var lastHeartbeatReminderAt = Date()

    func enter(_ tag: String) {
        lock.lock()
        alive[tag, default: 0] += 1
        let count = alive[tag] ?? 0
        lock.unlock()
        // 动画进出是高频状态信号（骨架屏每次进出都会触发，实测成对刷了两千多行）。
        // 保留 error 级（Release 也落文件，崩溃/振荡排查需要），但按 tag 节流。
        AppLogger.throttled(.error, .general, key: "anim.enter.\(tag)", interval: 5,
                            "[AnimTracker] enter \(tag) | alive=\(count)")
    }

    func exit(_ tag: String) {
        lock.lock()
        let count = max(0, (alive[tag] ?? 1) - 1)
        if count == 0 { alive[tag] = nil } else { alive[tag] = count }
        lock.unlock()
        AppLogger.throttled(.error, .general, key: "anim.exit.\(tag)", interval: 5,
                            "[AnimTracker] exit \(tag) | alive=\(count)")
    }

    func startHeartbeat() {
        guard heartbeatTimer == nil else { return }
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            let snapshot = self.alive
            self.lock.unlock()
            let names = snapshot.map { "\($0.key)x\($0.value)" }.sorted().joined(separator: ",")
            let signature = snapshot.isEmpty ? "none" : names
            let now = Date()
            if signature != self.lastHeartbeatSignature {
                AppLogger.error(.general, "[AnimTracker] heartbeat alive=\(signature)")
                self.lastHeartbeatSignature = signature
                self.lastHeartbeatReminderAt = now
            } else if !snapshot.isEmpty,
                      now.timeIntervalSince(self.lastHeartbeatReminderAt) >= 900 {
                AppLogger.error(.general, "[AnimTracker] heartbeat unchanged ≥15m alive=\(signature)")
                self.lastHeartbeatReminderAt = now
            }
        }
    }
}
