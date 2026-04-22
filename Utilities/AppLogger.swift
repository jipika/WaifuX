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
                      _ message: String,
                      metadata: [String: Any]? = nil) {
        shared.log(.debug, module, message, metadata)
    }

    static func info(_ module: AppLogModule = .general,
                     _ message: String,
                     metadata: [String: Any]? = nil) {
        shared.log(.info, module, message, metadata)
    }

    static func warn(_ module: AppLogModule = .general,
                     _ message: String,
                     metadata: [String: Any]? = nil) {
        shared.log(.warn, module, message, metadata)
    }

    static func error(_ module: AppLogModule = .general,
                      _ message: String,
                      metadata: [String: Any]? = nil) {
        shared.log(.error, module, message, metadata)
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

    private func writeToFile(_ line: String) {
        guard let url = logFileURL else { return }
        queue.async { [weak self] in
            guard let self = self else { return }

            if !FileManager.default.fileExists(atPath: url.path) {
                // 新建文件，写 UTF-8 BOM 方便文本编辑器识别
                let bomData = Data([0xEF, 0xBB, 0xBF])
                try? bomData.write(to: url, options: .atomic)
            }

            // 检查文件大小，超限则截断
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? UInt64, size > self.maxLogFileSize {
                do {
                    // 读取后半部分（保留最近日志）
                    let currentData = try Data(contentsOf: url)
                    let keepRange = currentData.count / 2  // 保留后半段
                    let truncatedData = currentData.subdata(in: keepRange..<currentData.count)
                    let headerStr = "--- LOG TRUNCATED at \(ISO8601DateFormatter().string(from: Date())) ---\n"
                    let headerData = (headerStr.data(using: .utf8) ?? Data()) + truncatedData
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
}
